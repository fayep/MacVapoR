#!/usr/bin/env python3 -I
"""Adds or updates a non-Steam game in Steam's library and maps it to a compatibility tool.

    steam_shortcut.py --steam DIR --user ID --appid N --name NAME --exe PATH --start-dir DIR
                      [--icon PNG] [--launch-options TEXT] [--tool notproton] [--vr]

Steam must not be running: it rewrites both files when it quits. The app ID (top bit set) names
the shortcut's prefix in steamapps/compatdata; Steam keeps the one stored with the shortcut, so
the caller picks it, and the same ID updates the same shortcut.
"""
import argparse, os, re, struct, subprocess, sys


def load_vdf(data):
    pos = 0

    def cstr():
        nonlocal pos
        end = data.index(b"\0", pos)
        s = data[pos:end].decode("utf-8")
        pos = end + 1
        return s

    def obj():
        nonlocal pos
        d = {}
        while True:
            kind = data[pos]
            pos += 1
            if kind == 8:
                return d
            key = cstr()
            if kind == 0:
                d[key] = obj()
            elif kind == 1:
                d[key] = cstr()
            elif kind == 2:
                d[key] = ("u32", struct.unpack_from("<I", data, pos)[0])
                pos += 4
            else:
                raise ValueError("unknown VDF field type %d" % kind)

    return obj()


def dump_vdf(d):
    out = bytearray()

    def obj(d):
        for k, v in d.items():
            if isinstance(v, dict):
                out.extend(b"\0" + k.encode() + b"\0")
                obj(v)
            elif isinstance(v, tuple):
                out.extend(b"\2" + k.encode() + b"\0" + struct.pack("<I", v[1]))
            else:
                out.extend(b"\1" + k.encode() + b"\0" + v.encode() + b"\0")
        out.append(8)

    obj(d)
    return bytes(out)


def write_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def set_shortcut(path, a):
    exe = '"%s"' % a.exe
    appid = a.appid
    raw = open(path, "rb").read() if os.path.exists(path) else b"\0shortcuts\0\b\b"
    d = load_vdf(raw)
    assert dump_vdf(d) == raw, "shortcuts.vdf has a layout this tool doesn't write back unchanged"
    shortcuts = d.setdefault("shortcuts", {})
    entry = next((s for s in shortcuts.values() if s.get("appid", ("", 0))[1] == appid), None)
    if entry is None:
        entry = {"appid": ("u32", appid), "appname": "", "Exe": "", "StartDir": "", "icon": "", "ShortcutPath": "",
                 "LaunchOptions": "", "IsHidden": ("u32", 0), "AllowDesktopConfig": ("u32", 1),
                 "AllowOverlay": ("u32", 1), "OpenVR": ("u32", 0), "Devkit": ("u32", 0), "DevkitGameID": "",
                 "DevkitOverrideAppID": ("u32", 0), "LastPlayTime": ("u32", 0), "FlatpakAppID": "", "sortas": "",
                 "tags": {}}
        shortcuts[str(len(shortcuts))] = entry
    entry["appname"] = a.name
    entry["Exe"] = exe
    # Unquoted: Steam hands StartDir to the tool as STEAM_COMPAT_INSTALL_PATH with any quotes kept,
    # and NotProton compares the target against it to choose its game launch path.
    entry["StartDir"] = a.start_dir.rstrip("/") + "/"
    entry["icon"] = a.icon or ""
    entry["LaunchOptions"] = a.launch_options or ""
    if a.vr:
        entry["OpenVR"] = ("u32", 1)   # Steam's "Include in VR Library"
    if os.path.exists(path):
        backup = path + ".before-steam_shortcut"
        if not os.path.exists(backup):
            write_atomic(backup, raw)
    write_atomic(path, dump_vdf(d))
    return appid


def set_compat_tool(path, appid, tool):
    text = open(path, encoding="utf-8").read()
    m = re.search(r'\n(\t*)"CompatToolMapping"\n\t*\{\n', text)
    if not m:
        raise SystemExit("no CompatToolMapping in %s; choose a compatibility tool for any game in Steam once" % path)
    ind = m.group(1) + "\t"
    # From the newline before the first entry, so that entry is found too.
    if re.search(r'\n\t*"%d"\n\t*\{\n\t*"name"' % appid, text[m.end() - 1:m.end() + 200000]):
        block = re.compile(r'(\n\t*"%d"\n\t*\{\n\t*"name"\t\t")[^"]*(")' % appid)
        text = block.sub(lambda x: x.group(1) + tool + x.group(2), text, count=1)
    else:
        entry = ('%s"%d"\n%s{\n%s\t"name"\t\t"%s"\n%s\t"config"\t\t""\n%s\t"priority"\t\t"250"\n%s}\n'
                 % (ind, appid, ind, ind, tool, ind, ind, ind))
        text = text[:m.end()] + entry + text[m.end():]
    write_atomic(path, text.encode("utf-8"))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--steam", required=True)
    p.add_argument("--user", required=True)
    p.add_argument("--appid", required=True, type=int)
    p.add_argument("--name", required=True)
    p.add_argument("--exe", required=True)
    p.add_argument("--start-dir", required=True)
    p.add_argument("--icon")
    p.add_argument("--launch-options")
    p.add_argument("--tool", default="notproton")
    p.add_argument("--vr", action="store_true")
    a = p.parse_args()
    if not 0x80000000 <= a.appid <= 0xFFFFFFFF:
        sys.exit("a shortcut's app ID has its top bit set")
    if subprocess.run(["pgrep", "-x", "steam_osx"], capture_output=True).returncode == 0:
        sys.exit("quit Steam first: it rewrites its library files when it quits")
    appid = set_shortcut(os.path.join(a.steam, "userdata", a.user, "config", "shortcuts.vdf"), a)
    set_compat_tool(os.path.join(a.steam, "config", "config.vdf"), appid, a.tool)


if __name__ == "__main__":
    main()
