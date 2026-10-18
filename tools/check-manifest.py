# check-manifest.py MANIFEST GAME_DIR: compare a Meta (Oculus) game folder with the SHA-256 values in its manifest.
import hashlib, json, os, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
root = sys.argv[2]
ok = bad = missing = nohash = 0
for name, info in m["files"].items():
    want = (info or {}).get("sha256")
    path = os.path.join(root, *name.split("\\"))
    if not os.path.isfile(path): missing += 1; continue
    if not want: nohash += 1; continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""): h.update(chunk)
    if h.hexdigest() == want.lower(): ok += 1
    else: bad += 1; print("MISMATCH", name)
print(f"{len(m['files'])} in manifest: {ok} match, {bad} differ, {missing} missing, {nohash} without a hash")
