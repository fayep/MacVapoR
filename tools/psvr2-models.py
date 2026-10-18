#!/usr/bin/env python3
"""Converts the PlayStation VR2 Sense controller models from Sony's PlayStation VR2 App (free on
Steam, app 2580190) into the form OpenComposite's local render models take, for this machine only:
Sony's models can't be shipped.

Sony's models line up with the OpenXR grip exactly as the Quest 2's do (the openxr_grip component
is the same), and OpenComposite reports a Touch controller's pose in that Quest 2 frame, so the
parts are merged as they are: one triangulated OBJ in metres per hand, texture coordinates turned
to OpenVR's (v down from the top), and the texture as raw RGBA after an 8-byte size header.

Usage: psvr2-models.py [OUT_DIR]   (default ~/Library/Application Support/MacVapoR/rendermodels)
Then psvr2-models.py --link APPID... links each game prefix's OpenComposite folder to OUT_DIR.
"""

import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

STEAM = pathlib.Path.home() / "Library/Application Support/Steam"
APP = "PlayStation VR2 App/SteamVR_Plug-In/resources/rendermodels"
OUT = pathlib.Path.home() / "Library/Application Support/MacVapoR/rendermodels"

# PNG to raw RGBA, unpremultiplied, rows top first: ImageIO does the decoding.
RGBA_SWIFT = r"""
import CoreGraphics
import Foundation
import ImageIO
let args = CommandLine.arguments
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
    let a = Double(px[i + 3]) / 255
    for c in 0..<3 { px[i + c] = UInt8(min(255, (Double(px[i + c]) / a).rounded())) }
}
var header = [UInt32(w).littleEndian, UInt32(h).littleEndian]
var out = Data(bytes: &header, count: 8)
out.append(contentsOf: px)
try! out.write(to: URL(fileURLWithPath: args[2]))
"""


def steam_libraries():
    libraries = [STEAM / "steamapps"]
    vdf = STEAM / "steamapps/libraryfolders.vdf"
    if vdf.exists():
        for line in vdf.read_text(errors="replace").splitlines():
            parts = line.split('"')
            if len(parts) >= 4 and parts[1] == "path":
                libraries.append(pathlib.Path(parts[3]) / "steamapps")
    return libraries


def find_models():
    for lib in steam_libraries():
        d = lib / "common" / APP
        if d.is_dir():
            return d
    if (OUT / "sony-source/playstation_vr2_sense_right").is_dir():
        return OUT / "sony-source"   # the copy kept by an earlier run
    sys.exit("No PlayStation VR2 App found: install it from Steam (steam://install/2580190)")


def merge(model_dir, side):
    """One OBJ of every part with a mesh; their vertices are already in the model's frame."""
    name = f"playstation_vr2_sense_{side}"
    layout = json.loads((model_dir / name / f"{name}.json").read_text())
    out = ["# PlayStation VR2 Sense controller (%s), merged from Sony's model for OpenComposite" % side]
    base = [0, 0, 0]  # v, vt, vn counts so far
    for part in layout["components"].values():
        if "filename" not in part:
            continue
        counts = [0, 0, 0]
        for line in (model_dir / name / part["filename"]).read_text().splitlines():
            f = line.split()
            if not f:
                continue
            if f[0] == "v":
                out.append(line)
                counts[0] += 1
            elif f[0] == "vt":
                out.append("vt %s %.6f" % (f[1], 1 - float(f[2])))
                counts[1] += 1
            elif f[0] == "vn":
                out.append(line)
                counts[2] += 1
            elif f[0] == "f":
                corners = []
                for c in f[1:]:
                    idx = c.split("/")
                    if len(idx) != 3 or not all(idx):
                        sys.exit("%s: face corner %s lacks a texture coordinate or normal" % (part["filename"], c))
                    corners.append("/".join(str(int(i) + b) for i, b in zip(idx, base)))
                for i in range(1, len(corners) - 1):  # fan any polygon into triangles
                    out.append("f %s %s %s" % (corners[0], corners[i], corners[i + 1]))
        base = [b + c for b, c in zip(base, counts)]
    return "\n".join(out) + "\n", model_dir / name / f"{name}.png"


def convert(out_dir):
    models = find_models()
    out_dir.mkdir(parents=True, exist_ok=True)
    # A copy of Sony's files, so this runs again once the app is uninstalled.
    keep = OUT / "sony-source"
    if models != keep:
        for side in ("left", "right"):
            subprocess.run(["rsync", "-a", str(models / f"playstation_vr2_sense_{side}"), str(keep)], check=True)
    with tempfile.TemporaryDirectory() as tmp:
        swift = pathlib.Path(tmp) / "rgba.swift"
        swift.write_text(RGBA_SWIFT)
        for side in ("left", "right"):
            obj, png = merge(models, side)
            (out_dir / f"controller_{side}.obj").write_text(obj)
            subprocess.run(["swift", str(swift), str(png), str(out_dir / f"controller_{side}.rgba")], check=True)
            faces = obj.count("\nf ")
            print("controller_%s: %d triangles, texture from %s" % (side, faces, png.name))
    print("converted into", out_dir)


def link(appids, out_dir):
    """Each Windows user's %LOCALAPPDATA%\\OpenComposite\\rendermodels, in the prefix of each game,
    wherever its library is: a link to out_dir."""
    if not (out_dir / "controller_right.obj").exists():
        sys.exit("Convert first: no models in %s" % out_dir)
    for appid in appids:
        users = [u for lib in steam_libraries() for u in (lib / "compatdata" / appid / "pfx/drive_c/users").glob("*")
                 if u.name != "Public" and (u / "AppData/Local").is_dir()]
        if not users:
            print("%s: no prefix with a user folder" % appid)
        for user in users:
            target = user / "AppData/Local/OpenComposite/rendermodels"
            target.parent.mkdir(exist_ok=True)
            if target.is_symlink():
                target.unlink()
            if target.exists():
                print("%s (%s): %s exists and isn't a link; left alone" % (appid, user.name, target))
                continue
            target.symlink_to(out_dir)
            print("%s (%s): linked" % (appid, user.name))


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--link"]:
        link(args[1:], OUT)
    else:
        convert(pathlib.Path(args[0]) if args else OUT)
