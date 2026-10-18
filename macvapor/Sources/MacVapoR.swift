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
    static let audioHelper = support.appending(path: "MacVapoR Audio.app")
    static let audioPermission = support.appending(path: "audio-permission")
    static let version = support.appending(path: "version")
    static let openComposite = support.appending(path: "opencomposite/openvr_api.dll")
    static let session = home.appending(path: "Library/Application Support/alvrxr/session.json")
    static let height = home.appending(path: "Library/Application Support/alvrxr/height.json")
    static let activeRuntime = home.appending(path: ".config/openxr/1/active_runtime.json")
    static let runner = home.appending(path: "Library/Application Support/notproton/runners/current")
    static let steam = home.appending(path: "Library/Application Support/Steam")
    static let log = home.appending(path: "Library/Logs/alvrxr.log")
    static let builtInScenes = runtime.appending(path: "scenes")
    static let userScenes = support.appending(path: "scenes")
    static let homeChoice = support.appending(path: "home.json")
    static let homeAgentLabel = "com.zippysoft.macvapor.home"
    static let homeAgent = home.appending(path: "Library/LaunchAgents/\(homeAgentLabel).plist")
    static let homeLog = home.appending(path: "Library/Logs/vapord.log")

    // Code is in Contents/Library, data in Contents/Resources.
    static let bundledCode = Bundle.main.bundleURL.appending(path: "Contents/Library/MacVapoR")
    static let bundledData = Bundle.main.resourceURL!
    static let bundledAudioHelper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/MacVapoR Audio.app")
}

struct Headset: Identifiable {
    let id: String
    let name: String
    var trusted: Bool
}

/// A home scene: a folder with a scene.json (see home/SCENES.md).
struct HomeScene: Identifiable {
    let id: String
    let name: String
    let about: String
    let userMade: Bool
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
    /// CX_GRAPHICS_BACKEND from the game's launch options, which NotProton's Compatibility
    /// page writes; nil when none is set.
    let graphics: String?
}

@MainActor
final class Model: ObservableObject {
    @Published var installedVersion: String?
    @Published var headsets: [Headset] = []
    /// nil: the real floor (ALVR's LocalFloor); otherwise a fixed eye height in metres (Local).
    @Published var seatedEyeHeight: Double?
    @Published var games: [Game] = []
    @Published var output = ""
    @Published var busy = false
    /// Whether MacVapoR Audio may record games' audio: nil while checking.
    @Published var audioAllowed: Bool?
    @Published var audioChecking = false
    @Published var scenes: [HomeScene] = []
    @Published var chosenScene = "vaporwave"
    @Published var homeEnabled = false

    let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    var hasRunner: Bool { FileManager.default.fileExists(atPath: Paths.runner.path) }
    var hasOpenComposite: Bool { FileManager.default.fileExists(atPath: Paths.openComposite.path) }

    init() {
        refresh()
        checkAudioPermission()
        // A check that failed is checked again when MacVapoR comes forward: the permission may
        // have been given meanwhile, or the check may have missed it.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if self.audioAllowed == false && !self.audioChecking { self.checkAudioPermission() }
            }
        }
    }

    // MARK: game audio

    /// MacVapoR Audio taps briefly, which makes macOS ask the first time, and reports back. It is
    /// opened through Launch Services so that the permission is its own, as when games use it.
    func checkAudioPermission() {
        guard FileManager.default.fileExists(atPath: Paths.audioHelper.path) else { return }
        audioChecking = true
        audioAllowed = nil
        try? FileManager.default.removeItem(at: Paths.audioPermission)
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-W", "-g", "-n", "-a", Paths.audioHelper.path, "--args", "--check", Paths.audioPermission.path]
            try? p.run()
            p.waitUntilExit()
            let result = try? String(contentsOf: Paths.audioPermission, encoding: .utf8)
            await MainActor.run {
                self.audioAllowed = result == "allowed"
                self.audioChecking = false
            }
        }
    }

    func refresh() {
        installedVersion = try? String(contentsOf: Paths.version, encoding: .utf8)
        loadHeadsets()
        games = GameScanner.scan()
        loadScenes()
    }

    // MARK: runtime

    func installRuntime() {
        do {
            let fm = FileManager.default
            // The home scene runs from the runtime folder: stopped while that's replaced.
            let firstInstall = installedVersion == nil
            let homeWasOn = FileManager.default.fileExists(atPath: Paths.homeAgent.path)
            Self.launchctl(["bootout", "gui/\(getuid())/\(Paths.homeAgentLabel)"])
            try? fm.removeItem(at: Paths.runtime)
            try? fm.removeItem(at: Paths.wineopenxr)
            try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try fm.copyItem(at: Paths.bundledCode.appending(path: "runtime"), to: Paths.runtime)
            try fm.copyItem(at: Paths.bundledData.appending(path: "scenes"), to: Paths.builtInScenes)
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
            try? fm.removeItem(at: Paths.audioHelper)
            try fm.copyItem(at: Paths.bundledAudioHelper, to: Paths.audioHelper)

            if !fm.fileExists(atPath: Paths.session.path) {
                try fm.createDirectory(at: Paths.session.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: Paths.bundledData.appending(path: "session-template.json"), to: Paths.session)
            }
            try writeActiveRuntime()
            try bundleVersion.write(to: Paths.version, atomically: true, encoding: .utf8)
            Self.clearQuarantine(Paths.support)
            output = "Runtime \(bundleVersion) installed."
            if firstInstall || homeWasOn { try setHomeEnabled(true) }
            checkAudioPermission()
        } catch {
            output = "Install failed: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Copies out of an app that came from a download keep its quarantine flag, and the setup
    /// script's cp carries it into every game's prefix. These files are part of the notarized
    /// app, so they are installed as trusted, the way an installer would.
    static func clearQuarantine(_ dir: URL) {
        let fm = FileManager.default
        var paths = [dir.path]
        if let walker = fm.enumerator(atPath: dir.path) {
            for case let rel as String in walker { paths.append(dir.appending(path: rel).path) }
        }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
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

    // MARK: home scene

    func loadScenes() {
        let fm = FileManager.default
        var found: [String: HomeScene] = [:]
        // The user's own last, so one with a built-in scene's folder name takes its place.
        for (root, userMade) in [(Paths.builtInScenes, false), (Paths.userScenes, true)] {
            for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                guard let data = try? Data(contentsOf: root.appending(path: "\(dir)/scene.json")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                found[dir] = HomeScene(id: dir, name: json["name"] as? String ?? dir, about: json["about"] as? String ?? "",
                                       userMade: userMade)
            }
        }
        scenes = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let choice = (try? Data(contentsOf: Paths.homeChoice))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["scene"] as? String }
        chosenScene = choice ?? "vaporwave"
        homeEnabled = fm.fileExists(atPath: Paths.homeAgent.path)
    }

    /// The home scene notices the change itself, within a second.
    func chooseScene(_ id: String) {
        try? JSONSerialization.data(withJSONObject: ["scene": id], options: .prettyPrinted).write(to: Paths.homeChoice, options: .atomic)
        loadScenes()
    }

    /// The home scene runs under launchd: started at login, and again each time it exits, which it
    /// does whenever a game takes the headset.
    func setHomeEnabled(_ on: Bool) throws {
        let fm = FileManager.default
        let target = "gui/\(getuid())"
        Self.launchctl(["bootout", "\(target)/\(Paths.homeAgentLabel)"])
        if on {
            let plist: [String: Any] = [
                "Label": Paths.homeAgentLabel,
                "ProgramArguments": [Paths.runtime.appending(path: "vapord").path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": 2,
                "ProcessType": "Interactive",
                "StandardErrorPath": Paths.homeLog.path,
            ]
            try fm.createDirectory(at: Paths.homeAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: Paths.homeAgent)
            Self.launchctl(["bootstrap", target, Paths.homeAgent.path])
        } else {
            try? fm.removeItem(at: Paths.homeAgent)
        }
        loadScenes()
    }

    func openScenesFolder() {
        try? FileManager.default.createDirectory(at: Paths.userScenes, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.userScenes)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: headsets

    func loadHeadsets() {
        guard let data = try? Data(contentsOf: Paths.session),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            headsets = []
            return
        }
        seatedEyeHeight = (try? Data(contentsOf: Paths.height))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["eye_height"] as? Double }
        guard let clients = json["client_connections"] as? [String: [String: Any]] else {
            headsets = []
            return
        }
        headsets = clients.map { id, c in
            Headset(id: id, name: c["display_name"] as? String ?? id, trusted: c["trusted"] as? Bool ?? false)
        }.sorted { $0.id < $1.id }
    }

    /// The real floor for standing play, or the eyes put at a fixed height for seated play. The
    /// runtime applies it, from height.json, when a game starts: ALVR's own recentering does not
    /// run with the visionOS client, so ALVR is left on the real floor.
    func setSeatedEyeHeight(_ height: Double?) {
        if let height {
            try? JSONSerialization.data(withJSONObject: ["eye_height": height]).write(to: Paths.height, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: Paths.height)
        }
        guard let data = try? Data(contentsOf: Paths.session),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var settings = json["session_settings"] as? [String: Any],
              var headset = settings["headset"] as? [String: Any],
              var mode = headset["position_recentering_mode"] as? [String: Any] else { return }
        mode["variant"] = "LocalFloor"
        headset["position_recentering_mode"] = mode
        settings["headset"] = headset
        json["session_settings"] = settings
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: Paths.session, options: .atomic)
        }
        loadHeadsets()
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
                Model.clearQuarantine(Paths.openComposite.deletingLastPathComponent())
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
    static let notGames = ["unitycrashhandler", "unins", "vcredist", "dxsetup", "crashreport", "vconsole", "vrstartup",
                           "unrealcefsubprocess", "ue4prereqsetup", "ueprereqsetup"]

    static func libraries() -> [URL] {
        var libs = [Paths.steam]
        let vdf = Paths.steam.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("\"path\"") {
                let parts = line.split(separator: "\"")
                if parts.count >= 4 {
                    // Steam lists its own library here too; compare paths, as URLs differ by a trailing slash.
                    let url = URL(fileURLWithPath: String(parts[3]).replacingOccurrences(of: "\\\\", with: "\\"))
                    if !libs.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                        libs.append(url)
                    }
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

    /// Launch options per app ID from the most recently used Steam account's localconfig.vdf:
    /// UserLocalConfigStore > Software > Valve > Steam > apps > <appid> > LaunchOptions.
    static func launchOptions() -> [String: String] {
        let fm = FileManager.default
        let userdata = Paths.steam.appending(path: "userdata")
        let configs = ((try? fm.contentsOfDirectory(atPath: userdata.path)) ?? []).map {
            userdata.appending(path: "\($0)/config/localconfig.vdf")
        }.filter { fm.fileExists(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }
        guard let newest = configs.max(by: { modified($0) < modified($1) }),
              let text = try? String(contentsOf: newest, encoding: .utf8) else { return [:] }
        var path: [String] = []
        var pending: String?
        var options: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                path.append(pending ?? "")
                pending = nil
            } else if line == "}" {
                _ = path.popLast()
            } else {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                if parts.count >= 5 {
                    let key = String(parts[1]), value = String(parts[3])
                    if key == "LaunchOptions", path.count >= 2, path[path.count - 2].lowercased() == "apps" {
                        options[path[path.count - 1]] = value
                    }
                } else if parts.count >= 3 {
                    pending = String(parts[1])
                }
            }
        }
        return options
    }

    static func graphics(in options: String?) -> String? {
        guard let options else { return nil }
        for word in options.split(separator: " ") where word.hasPrefix("CX_GRAPHICS_BACKEND=") {
            return String(word.dropFirst("CX_GRAPHICS_BACKEND=".count))
        }
        return nil
    }

    static func scan() -> [Game] {
        let fm = FileManager.default
        var games: [Game] = []
        let options = launchOptions()
        for lib in libraries() {
            let apps = lib.appending(path: "steamapps")
            guard let items = try? fm.contentsOfDirectory(atPath: apps.path) else { continue }
            for item in items where item.hasPrefix("appmanifest_") && item.hasSuffix(".acf") {
                guard let acf = try? String(contentsOf: apps.appending(path: item), encoding: .utf8),
                      let id = value("appid", in: acf), let name = value("name", in: acf),
                      let installdir = value("installdir", in: acf) else { continue }
                if id == "228980" || id == "250820" { continue }   // Steamworks redistributables, SteamVR
                if games.contains(where: { $0.id == id }) { continue }
                let dir = apps.appending(path: "common/\(installdir)")
                var exes: [String] = []
                var kind = Game.Kind.other
                if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker {
                        // Unreal keeps openvr_api.dll seven levels down, in Engine/Binaries/ThirdParty/OpenVR/....
                        if walker.level > 8 { walker.skipDescendants(); continue }
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
                games.append(Game(id: id, name: name, dir: dir, prefix: prefix, exes: exes, kind: kind,
                                  configured: configured, graphics: graphics(in: options[id])))
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
                homeSection
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
                audioStatus
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

    @ViewBuilder private var audioStatus: some View {
        if model.installedVersion == nil {
            EmptyView()
        } else if model.audioChecking {
            Label("Game audio: checking. If macOS asks whether MacVapoR Audio may record audio, allow it.",
                  systemImage: "speaker.wave.2")
                .foregroundStyle(.secondary)
        } else if model.audioAllowed == true {
            Label("Game audio: allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if model.audioAllowed == false {
            HStack {
                Label("Game audio is not allowed: turn on MacVapoR Audio under Screen & System Audio Recording.",
                      systemImage: "speaker.slash")
                    .foregroundStyle(.orange)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                Button("Check Again") { model.checkAudioPermission() }
            }
        }
    }

    private var homeSection: some View {
        GroupBox("Home Scene") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shown in the headset while no game is running: your hands or controllers, and a ball to throw.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show a home scene between games", isOn: Binding(get: { model.homeEnabled }, set: { on in
                    do { try model.setHomeEnabled(on) } catch { model.output = "Home scene: \(error.localizedDescription)" }
                }))
                .disabled(model.installedVersion == nil)
                if model.homeEnabled {
                    Picker("Scene", selection: Binding(get: { model.chosenScene }, set: { model.chooseScene($0) })) {
                        ForEach(model.scenes) { scene in
                            Text(scene.userMade ? "\(scene.name) (yours)" : scene.name).tag(scene.id)
                        }
                    }
                    .frame(maxWidth: 320)
                    if let scene = model.scenes.first(where: { $0.id == model.chosenScene }), !scene.about.isEmpty {
                        Text(scene.about).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open Scenes Folder") { model.openScenesFolder() }
                        Button("Home Scene Log") { NSWorkspace.shared.open(Paths.homeLog) }
                        Spacer()
                    }
                    Text("To make your own, copy a scene from runtime/scenes into the scenes folder and change it; see SCENES.md beside them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Picker("Height", selection: Binding(get: { model.seatedEyeHeight == nil ? 0 : 1 },
                                                    set: { model.setSeatedEyeHeight($0 == 0 ? nil : 1.5) })) {
                    Text("Real floor (standing)").tag(0)
                    Text("Seated: fixed eye height").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if let height = model.seatedEyeHeight {
                    HStack {
                        Slider(value: Binding(get: { height }, set: { model.setSeatedEyeHeight(($0 * 20).rounded() / 20) }),
                               in: 1.0...2.0)
                            .frame(maxWidth: 300)
                        Text(String(format: "%.2f m", height)).monospacedDigit()
                    }
                }
                Text("Takes effect the next time a game starts.").font(.caption).foregroundStyle(.secondary)
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
                if game.kind != .other {
                    if game.graphics?.lowercased() == "dxmt" {
                        Label("DXMT", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Graphics is \(game.graphics ?? "NotProton's default"): choose DXMT on its Compatibility page in NotProton",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
