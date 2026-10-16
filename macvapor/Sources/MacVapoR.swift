// MacVapoR: installs the alvrxr OpenXR runtime and sets NotProton games up to show on an Apple
// Vision Pro through ALVR. The work per game is done by the bundled notproton-vr-setup.sh.

import AppKit
import SwiftUI

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appending(path: "Library/Application Support/MacVapoR")
    static let runtime = support.appending(path: "runtime")
    static let wineopenxr = support.appending(path: "wineopenxr")
    static let script = support.appending(path: "notproton-vr-setup.sh")
    static let version = support.appending(path: "version")
    static let openComposite = support.appending(path: "opencomposite/openvr_api.dll")
    static let session = home.appending(path: "Library/Application Support/alvrxr/session.json")
    static let activeRuntime = home.appending(path: ".config/openxr/1/active_runtime.json")
    static let runner = home.appending(path: "Library/Application Support/notproton/runners/current")
    static let steam = home.appending(path: "Library/Application Support/Steam")
    static let log = home.appending(path: "Library/Logs/alvrxr.log")

    // Code is in Contents/Library, data in Contents/Resources.
    static let bundledCode = Bundle.main.bundleURL.appending(path: "Contents/Library/MacVapoR")
    static let bundledData = Bundle.main.resourceURL!
}

struct Headset: Identifiable {
    let id: String
    let name: String
    var trusted: Bool
}

struct Game: Identifiable {
    enum Kind: String { case openXR = "OpenXR", openVR = "OpenVR", other = "" }
    let id: String
    let name: String
    let dir: URL
    let prefix: URL?
    let exes: [String]
    let kind: Kind
    var configured: Bool
}

@MainActor
final class Model: ObservableObject {
    @Published var installedVersion: String?
    @Published var headsets: [Headset] = []
    @Published var games: [Game] = []
    @Published var output = ""
    @Published var busy = false

    let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    var hasRunner: Bool { FileManager.default.fileExists(atPath: Paths.runner.path) }
    var hasOpenComposite: Bool { FileManager.default.fileExists(atPath: Paths.openComposite.path) }

    init() { refresh() }

    func refresh() {
        installedVersion = try? String(contentsOf: Paths.version, encoding: .utf8)
        loadHeadsets()
        games = GameScanner.scan()
    }

    // MARK: runtime

    func installRuntime() {
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: Paths.runtime)
            try? fm.removeItem(at: Paths.wineopenxr)
            try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try fm.copyItem(at: Paths.bundledCode.appending(path: "runtime"), to: Paths.runtime)
            // wineopenxr's layout, as the setup script and Wine expect it: the PE half is data,
            // the unix half is code.
            try fm.createDirectory(at: Paths.wineopenxr, withIntermediateDirectories: true)
            try fm.copyItem(at: Paths.bundledData.appending(path: "wineopenxr/x86_64-windows"),
                            to: Paths.wineopenxr.appending(path: "x86_64-windows"))
            try fm.copyItem(at: Paths.bundledData.appending(path: "wineopenxr/wineopenxr64.json"),
                            to: Paths.wineopenxr.appending(path: "wineopenxr64.json"))
            try fm.copyItem(at: Paths.bundledCode.appending(path: "wineopenxr/aarch64-unix"),
                            to: Paths.wineopenxr.appending(path: "aarch64-unix"))
            try? fm.removeItem(at: Paths.script)
            try fm.copyItem(at: Paths.bundledData.appending(path: "notproton-vr-setup.sh"), to: Paths.script)

            if !fm.fileExists(atPath: Paths.session.path) {
                try fm.createDirectory(at: Paths.session.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: Paths.bundledData.appending(path: "session-template.json"), to: Paths.session)
            }
            try writeActiveRuntime()
            try bundleVersion.write(to: Paths.version, atomically: true, encoding: .utf8)
            output = "Runtime \(bundleVersion) installed."
        } catch {
            output = "Install failed: \(error.localizedDescription)"
        }
        refresh()
    }

    private func writeActiveRuntime() throws {
        let fm = FileManager.default
        let dir = Paths.activeRuntime.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Another runtime's manifest is kept beside ours rather than lost.
        if let old = try? String(contentsOf: Paths.activeRuntime, encoding: .utf8), !old.contains("libalvrxr.dylib") {
            try? old.write(to: dir.appending(path: "active_runtime.json.before-macvapor"), atomically: true, encoding: .utf8)
        }
        let lib = Paths.runtime.appending(path: "libalvrxr.dylib").path
        let manifest = """
            {
                "file_format_version": "1.0.0",
                "runtime": {
                    "name": "alvrxr",
                    "library_path": "\(lib)"
                }
            }

            """
        try manifest.write(to: Paths.activeRuntime, atomically: true, encoding: .utf8)
    }

    // MARK: headsets

    func loadHeadsets() {
        guard let data = try? Data(contentsOf: Paths.session),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clients = json["client_connections"] as? [String: [String: Any]] else {
            headsets = []
            return
        }
        headsets = clients.map { id, c in
            Headset(id: id, name: c["display_name"] as? String ?? id, trusted: c["trusted"] as? Bool ?? false)
        }.sorted { $0.id < $1.id }
    }

    func setTrusted(_ id: String, _ trusted: Bool) {
        guard let data = try? Data(contentsOf: Paths.session),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var clients = json["client_connections"] as? [String: [String: Any]],
              clients[id] != nil else { return }
        clients[id]?["trusted"] = trusted
        json["client_connections"] = clients
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: Paths.session, options: .atomic)
        }
        loadHeadsets()
    }

    // MARK: games

    func setUp(_ game: Game, exe: String, undo: Bool) {
        var env = ProcessInfo.processInfo.environment
        env["GFX"] = "dxmt"
        env["WOX"] = Paths.wineopenxr.path
        env["ALVRXR_LIB"] = Paths.runtime.appending(path: "libalvrxr.dylib").path
        if game.kind == .openVR && !undo {
            guard hasOpenComposite else {
                output = "\(game.name) uses OpenVR: download OpenComposite first."
                return
            }
            env["OC"] = Paths.openComposite.path
        }
        var args = [Paths.script.path]
        if undo { args.append("--undo") }
        args += [game.id, exe]
        busy = true
        output = ""
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let text: String
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let status = p.terminationStatus == 0 ? "" : "\n(failed, status \(p.terminationStatus))"
                text = String(decoding: data, as: UTF8.self) + status
            } catch {
                text = "Could not run the setup script: \(error.localizedDescription)"
            }
            await MainActor.run {
                self.output = text
                self.busy = false
                self.refresh()
            }
        }
    }

    // MARK: OpenComposite

    func downloadOpenComposite() {
        let url = URL(string: "https://znix.xyz/OpenComposite/download.php?arch=x64&branch=openxr")!
        busy = true
        output = "Downloading OpenComposite…"
        Task {
            do {
                let (file, _) = try await URLSession.shared.download(from: url)
                let data = try Data(contentsOf: file)
                guard OpenComposite.looksValid(data) else {
                    throw NSError(domain: "MacVapoR", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "the download is not a 64-bit OpenComposite DLL"])
                }
                let fm = FileManager.default
                try fm.createDirectory(at: Paths.openComposite.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: Paths.openComposite, options: .atomic)
                output = "OpenComposite downloaded (\(data.count / 1024) KB)."
            } catch {
                output = "OpenComposite download failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

enum OpenComposite {
    /// A 64-bit Windows DLL that implements OpenVR's compositor interface.
    static func looksValid(_ d: Data) -> Bool {
        guard d.count > 0x1000, d[0] == 0x4D, d[1] == 0x5A else { return false }
        let pe = Int(d[0x3C]) | Int(d[0x3D]) << 8 | Int(d[0x3E]) << 16 | Int(d[0x3F]) << 24
        guard pe + 6 < d.count, d[pe] == 0x50, d[pe + 1] == 0x45, d[pe + 4] == 0x64, d[pe + 5] == 0x86 else { return false }
        return d.range(of: Data("IVRCompositor_".utf8)) != nil
    }
}

enum GameScanner {
    // Executables that are never the game.
    static let notGames = ["unitycrashhandler", "unins", "vcredist", "dxsetup", "crashreport", "vconsole", "vrstartup"]

    static func libraries() -> [URL] {
        var libs = [Paths.steam]
        let vdf = Paths.steam.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("\"path\"") {
                let parts = line.split(separator: "\"")
                if parts.count >= 4 {
                    let url = URL(fileURLWithPath: String(parts[3]).replacingOccurrences(of: "\\\\", with: "\\"))
                    if !libs.contains(url) { libs.append(url) }
                }
            }
        }
        return libs
    }

    static func value(_ key: String, in acf: String) -> String? {
        for line in acf.split(separator: "\n") {
            let parts = line.split(separator: "\"")
            if parts.count >= 4, parts[1] == key { return String(parts[3]) }
        }
        return nil
    }

    static func scan() -> [Game] {
        let fm = FileManager.default
        var games: [Game] = []
        for lib in libraries() {
            let apps = lib.appending(path: "steamapps")
            guard let items = try? fm.contentsOfDirectory(atPath: apps.path) else { continue }
            for item in items where item.hasPrefix("appmanifest_") && item.hasSuffix(".acf") {
                guard let acf = try? String(contentsOf: apps.appending(path: item), encoding: .utf8),
                      let id = value("appid", in: acf), let name = value("name", in: acf),
                      let installdir = value("installdir", in: acf) else { continue }
                if id == "228980" || id == "250820" { continue }   // Steamworks redistributables, SteamVR
                let dir = apps.appending(path: "common/\(installdir)")
                var exes: [String] = []
                var kind = Game.Kind.other
                if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker {
                        if walker.level > 5 { walker.skipDescendants(); continue }
                        let file = url.lastPathComponent.lowercased()
                        if file == "openvr_api.dll" { kind = .openVR }
                        if file == "openxr_loader.dll" && kind == .other { kind = .openXR }
                        if file.hasSuffix(".exe") && !notGames.contains(where: { file.hasPrefix($0) }) {
                            exes.append(String(url.path.dropFirst(dir.path.count + 1)))
                        }
                    }
                }
                exes.sort { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
                let prefixes = [apps.appending(path: "compatdata/\(id)/pfx"),
                                Paths.steam.appending(path: "steamapps/compatdata/\(id)/pfx")]
                let prefix = prefixes.first { fm.fileExists(atPath: $0.appending(path: "system.reg").path) }
                let configured = prefix.map {
                    fm.fileExists(atPath: $0.appending(path: "drive_c/Program Files (x86)/Steam/aarch64-windows/wineopenxr.dll").path)
                } ?? false
                games.append(Game(id: id, name: name, dir: dir, prefix: prefix, exes: exes, kind: kind, configured: configured))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var vrOnly = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                runtimeSection
                headsetSection
                gamesSection
                if !model.output.isEmpty {
                    Text(model.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                }
            }
            .padding(20)
        }
        .disabled(model.busy)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            Button("Runtime Log", systemImage: "doc.text") { NSWorkspace.shared.open(Paths.log) }
        }
    }

    private var runtimeSection: some View {
        GroupBox("1. Runtime") {
            VStack(alignment: .leading, spacing: 8) {
                if !model.hasRunner {
                    Label("NotProton's CrossOver runner was not found. Install NotProton and run a game with it once.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    if let v = model.installedVersion {
                        Text(v == model.bundleVersion ? "alvrxr \(v) is installed." : "alvrxr \(v) is installed; this is \(model.bundleVersion).")
                    } else {
                        Text("Not installed.")
                    }
                    Spacer()
                    Button(model.installedVersion == model.bundleVersion ? "Reinstall" : "Install") { model.installRuntime() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var headsetSection: some View {
        GroupBox("2. Headsets") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open ALVR on the Vision Pro while a set-up game is running, and it shows up here. Trust it, then restart the game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.headsets.isEmpty {
                    Text("No headsets yet.")
                }
                ForEach(model.headsets) { h in
                    Toggle(isOn: Binding(get: { h.trusted }, set: { model.setTrusted(h.id, $0) })) {
                        HStack {
                            Text(h.name).bold()
                            Text(h.id).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var gamesSection: some View {
        GroupBox("3. Games") {
            VStack(alignment: .leading, spacing: 10) {
                Text("In NotProton, set the game's graphics to DXMT. Close the game before setting it up. Then open ALVR on the Vision Pro with the controllers awake, and launch the game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Toggle("VR games only", isOn: $vrOnly)
                    Spacer()
                    if model.hasOpenComposite {
                        Label("OpenComposite ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    Button(model.hasOpenComposite ? "Update OpenComposite" : "Download OpenComposite") {
                        model.downloadOpenComposite()
                    }
                }
                ForEach(model.games.filter { !vrOnly || $0.kind != .other }) { game in
                    GameRow(game: game)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct GameRow: View {
    @EnvironmentObject var model: Model
    let game: Game
    @State private var exe = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(game.name).bold()
                    if game.kind != .other {
                        Text(game.kind.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .background(.tint.opacity(0.2), in: .capsule)
                    }
                    if game.configured {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if game.prefix == nil {
                    Text("Launch it once with NotProton first.").font(.caption).foregroundStyle(.secondary)
                } else if !game.exes.isEmpty {
                    Picker("Executable", selection: $exe) {
                        ForEach(game.exes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            }
            Spacer()
            if game.configured {
                Button("Undo") { model.setUp(game, exe: exe, undo: true) }
            }
            Button(game.configured ? "Set Up Again" : "Set Up") { model.setUp(game, exe: exe, undo: false) }
                .disabled(game.prefix == nil || exe.isEmpty || model.installedVersion == nil)
        }
        .onAppear { if exe.isEmpty { exe = game.exes.first ?? "" } }
        Divider()
    }
}

@main
struct MacVapoRApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("MacVapoR") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
