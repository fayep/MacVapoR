#!/usr/bin/env python3
"""Names and totals a vaporprobe profile.

Each sample is a call stack of x86 addresses. An address in a module is named from the module's
debug symbols (a PDB beside it or in the cache, else fetched from the symbol servers below, else
its export table); one in code Mono compiled is named as the C# method the profile recorded for
it. Prints where the time goes (self: in that function; total: in it or what it called) and,
with --folded, writes the stacks for a flame graph (speedscope.app or flamegraph.pl).

Usage: report.py PROFILE --prefix PFX [--top 40] [--folded out.txt] [--thread TID|all] [--from S] [--to S]
  PFX: the game's Wine prefix (the folder holding drive_c), so C:\\ paths can be read.
  --from, --to: only samples that many seconds into the profile, to leave out loading.
"""

import argparse
import bisect
import collections
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request

SERVERS = ["http://symbolserver.unity3d.com", "https://msdl.microsoft.com/download/symbols"]
CACHE = pathlib.Path.home() / "Library/Caches/vaporprobe/symbols"
LLVM = pathlib.Path("/opt/homebrew/opt/llvm/bin")


def read_profile(path):
    modules, mono, samples = [], [], []
    main, start, now = None, None, 0.0
    for line in open(path, errors="replace"):
        f = line.rstrip("\n").split(" ", 3)
        if f[0] == "s":
            parts = line.split()
            samples.append((parts[1], [int(x, 16) for x in parts[2:]], now))
        elif f[0] == "t":   # once a second: the tick count in ms, before that second's samples
            tick = int(f[1])
            start = tick if start is None else start
            now = (tick - start) / 1000
        elif f[0] == "module":
            modules.append((int(f[1], 16), int(f[2], 16), f[3]))
        elif f[0] == "mono":
            mono.append((int(f[1], 16), int(f[2], 16), f[3]))
        elif f[0] == "main":
            main = f[1]
    return modules, sorted(mono), samples, main


def mac_path(win, prefix):
    if win[1:3] == ":\\":
        drive, rest = win[0].upper(), win[3:].replace("\\", "/")
        if drive == "Z":
            return pathlib.Path("/" + rest)
        if prefix:
            return pathlib.Path(prefix) / ("drive_" + drive.lower()) / rest
    return None


def pe_info(path):
    """Preferred image base, CodeView (pdb name, id), exports {rva: name}."""
    b = path.read_bytes()
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    base = struct.unpack_from("<Q", b, opt + 24)[0] if magic == 0x20B else struct.unpack_from("<I", b, opt + 28)[0]
    dirs = opt + (112 if magic == 0x20B else 96)
    secs = opt + struct.unpack_from("<H", b, pe + 20)[0]

    def off(rva):
        for i in range(nsec):
            # IMAGE_SECTION_HEADER: VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData
            vsize, va, rawsize, raw = struct.unpack_from("<IIII", b, secs + 40 * i + 8)
            if va <= rva < va + max(vsize, rawsize):
                return rva - va + raw
        return None

    exports = {}
    erva, esize = struct.unpack_from("<II", b, dirs)
    if erva and off(erva) is not None:
        e = off(erva)
        nfun, nnames, afun, aname, aord = struct.unpack_from("<IIIII", b, e + 20)
        funcs = [struct.unpack_from("<I", b, off(afun) + 4 * i)[0] for i in range(nfun)]
        for i in range(nnames):
            nrva = struct.unpack_from("<I", b, off(aname) + 4 * i)[0]
            o = struct.unpack_from("<H", b, off(aord) + 2 * i)[0]
            name = b[off(nrva):b.index(b"\0", off(nrva))].decode(errors="replace")
            if o < len(funcs) and not (erva <= funcs[o] < erva + esize):
                exports[funcs[o]] = name
    cv = None
    drva, dsize = struct.unpack_from("<II", b, dirs + 6 * 8)
    if drva and off(drva) is not None:
        for i in range(dsize // 28):
            typ, size, _, raw = struct.unpack_from("<IIII", b, off(drva) + 28 * i + 12)
            if typ == 2 and b[raw:raw + 4] == b"RSDS":
                a, c, d = struct.unpack_from("<IHH", b, raw + 4)
                age = struct.unpack_from("<I", b, raw + 20)[0]
                name = b[raw + 24:b.index(b"\0", raw + 24)].decode(errors="replace").replace("\\", "/").split("/")[-1]
                cv = (name, "%08X%04X%04X%s%X" % (a, c, d, b[raw + 12:raw + 20].hex().upper(), age))
    return base, cv, exports


def find_pdb(module_path, cv):
    if not cv or not cv[0]:
        return None
    name, ident = cv
    beside = module_path.with_name(name)
    if beside.exists():
        return beside
    cached = CACHE / name / ident / name
    if cached.exists():
        return cached
    if (CACHE / name / ident / "missing").exists():
        return None
    cached.parent.mkdir(parents=True, exist_ok=True)
    for server in SERVERS:
        for fname in (name, name[:-1] + "_"):
            try:
                with urllib.request.urlopen("%s/%s/%s/%s" % (server, name, ident, fname), timeout=60) as r:
                    data = r.read()
            except Exception:
                continue
            if fname.endswith("_"):
                with tempfile.TemporaryDirectory() as t:
                    p = pathlib.Path(t) / fname
                    p.write_bytes(data)
                    subprocess.run(["tar", "-xf", str(p), "-C", t], check=True)
                    shutil.move(str(pathlib.Path(t) / name), cached)
            else:
                cached.write_bytes(data)
            print("symbols: %s from %s" % (name, server), file=sys.stderr)
            return cached
    (CACHE / name / ident / "missing").touch()
    return None


def symbolize(module_path, pdb, base, load, addrs):
    """{address: function name} through llvm-symbolizer, at the module's preferred base."""
    cmd = [str(LLVM / "llvm-symbolizer"), "--obj", str(module_path), "--output-style=JSON", "--no-inlines",
           "--functions=short"]
    if pdb:
        cmd += ["--pdb", str(pdb)]
    va = {a: a - load + base for a in addrs}
    r = subprocess.run(cmd, input="\n".join(hex(v) for v in va.values()), capture_output=True, text=True)
    names = {}
    for a, line in zip(va, r.stdout.splitlines()):
        try:
            sym = json.loads(line)["Symbol"][0]["FunctionName"]
        except (ValueError, KeyError, IndexError):
            sym = ""
        if sym and sym != "??":
            names[a] = sym
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("profile")
    ap.add_argument("--prefix", help="the Wine prefix holding drive_c")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--folded", help="write folded stacks here")
    ap.add_argument("--thread", default="main", help="main, all, or a thread ID (hex)")
    ap.add_argument("--from", dest="t0", type=float, default=0, help="seconds into the profile")
    ap.add_argument("--to", dest="t1", type=float, default=1e9, help="seconds into the profile")
    a = ap.parse_args()

    modules, mono, samples, main_tid = read_profile(a.profile)
    want = main_tid if a.thread == "main" else None if a.thread == "all" else a.thread
    span = max((s[2] for s in samples), default=0)
    samples = [(t, pcs) for t, pcs, at in samples if (want is None or t == want) and a.t0 <= at < a.t1]
    if not samples:
        sys.exit("no samples for thread %s" % a.thread)

    def module_of(pc):
        for m in modules:
            if m[0] <= pc < m[0] + m[1]:
                return m
        return None

    mono_starts = [m[0] for m in mono]

    def mono_of(pc):
        i = bisect.bisect_right(mono_starts, pc) - 1
        if i >= 0 and pc < mono[i][0] + mono[i][1]:
            return mono[i][2]
        return None

    # Name every distinct address, a module at a time.
    by_module = collections.defaultdict(set)
    for _, pcs in samples:
        for pc in pcs:
            m = module_of(pc)
            if m:
                by_module[m].add(pc)
    names = {}
    for m, pcs in by_module.items():
        short = m[2].replace("\\", "/").split("/")[-1]
        path = mac_path(m[2], a.prefix)
        found = {}
        if path and path.exists():
            try:
                base, cv, exports = pe_info(path)
                found = symbolize(path, find_pdb(path, cv), base, m[0], pcs)
                if exports:
                    rvas = sorted(exports)
                    for pc in pcs:
                        if pc not in found:
                            i = bisect.bisect_right(rvas, pc - m[0]) - 1
                            if i >= 0:
                                found[pc] = "%s+0x%x" % (exports[rvas[i]], pc - m[0] - rvas[i])
            except Exception as e:
                print("%s: %s" % (short, e), file=sys.stderr)
        for pc in pcs:
            names[pc] = "%s!%s" % (short, found.get(pc) or hex(pc - m[0]))

    def name(pc):
        if pc in names:
            return names[pc]
        c = mono_of(pc)
        if c:
            return "C# " + c
        return "?jit %x" % (pc & ~0xFFFF)

    def category(pc):
        m = module_of(pc)
        if m:
            return m[2].replace("\\", "/").split("/")[-1]
        return "C# (Mono JIT)" if mono_of(pc) else "unknown code"

    self_, total, cats, folded = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    for _, pcs in samples:
        frames = [name(pc) for pc in pcs]
        self_[frames[0]] += 1
        cats[category(pcs[0])] += 1
        for f in set(frames):
            total[f] += 1
        folded[";".join(reversed(frames))] += 1
    n = len(samples)

    print("%d samples (%s), %.0f to %.0f s of %.0f s\n" % (n, "main thread" if a.thread == "main" else a.thread,
                                                         a.t0, min(a.t1, span), span))
    print("where the time is, by module (self):")
    for k, v in cats.most_common(15):
        print("  %5.1f%%  %s" % (100 * v / n, k))
    print("\nself: in the function itself")
    for k, v in self_.most_common(a.top):
        print("  %5.1f%%  %s" % (100 * v / n, k[:160]))
    print("\ntotal: in the function or what it calls")
    for k, v in total.most_common(a.top):
        print("  %5.1f%%  %s" % (100 * v / n, k[:160]))
    if a.folded:
        with open(a.folded, "w") as f:
            for k, v in folded.items():
                f.write("%s %d\n" % (k.replace(" ", "_"), v))
        print("\nfolded stacks: %s" % a.folded)


if __name__ == "__main__":
    main()
