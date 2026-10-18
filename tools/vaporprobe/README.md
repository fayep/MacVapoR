# vaporprobe

A sampling profiler for a Windows game under Wine (x86-64, including under FEX), and a way to tell
the game it has fewer CPUs. Built as `version.dll`, which most games load; put beside the game's
exe, it's used only when the game runs with `WINEDLLOVERRIDES=version=n,b`.

    tools/vaporprobe/build.sh                   # out/vaporprobe/version.dll, with mingw-w64

| Variable | |
| --- | --- |
| `VAPOR_CPUS=N` | the game is told it has N CPUs. Engines size their thread pools from this, and under Wine every wake-up of a pool thread can cost a wineserver round trip. |
| `VAPOR_PROFILE=Z:\path\to\file` | samples x86 call stacks into that file |
| `VAPOR_PROFILE_HZ=1000` | samples a second, per thread |
| `VAPOR_PROFILE_THREADS=all` | every thread, not only the game's first |
| `VAPOR_PROFILE_MONO=0` | leave Mono alone |

While a thread is suspended, nothing that takes a lock is called: module code is unwound from the
module's own unwind tables, and code outside modules (a JIT's) by frame pointer. A Mono game's
C# methods are named by Mono itself, through a JIT profiler callback, as it compiles them.

    tools/vaporprobe/report.py PROFILE --prefix PFX [--from 60] [--folded out.txt]

names the frames (debug symbols beside the module or fetched from Unity's and Microsoft's symbol
servers, else exports) and totals them; `--folded` writes stacks for a flame graph. Symbols
from a public PDB name only public functions, so a frame shown as `name+0x1991c` is somewhere
after `name`, not in it.
