"""The faster bitmap span (native/fast_span.h, 0.6.10, after TPF3-MP's fast-bitmap-span, MIT), offline: the header is built
with MSVC into a small DLL (as tests/test_industrydemand.py does) and run beside the game's own 78 bytes (build 40425, copied
into executable memory), on the same bitmaps: every span leaves the same bits and the same answer (false). Cases: thousands
of random spans (start, count, widths, rows), spans within one word, across words, whole words, empty and negative counts;
a span starting below bit 0 is handed to the game's code (counted, never filled here). With the game installed, the signature
the native module looks for is found exactly once in TransportFever3.exe (another build is only reported).
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_fastspan.py
"""
import ctypes
import os
import pathlib
import random
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
fails = []


def check(what, cond):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)
    return cond


ORIGINAL = bytes.fromhex(
    "44 0F AF 41 10 4C 8B D9 44 03 C2 43 8D 04 08 44 3B C0 7D 37 49 63 C0 45 8B D1 66 0F 1F 44 00 00 49 8B 4B 08 4C 8B C0"
    " 49 C1 E8 05 48 8B 11 42 8B 0C 82 4E 8D 0C 82 48 8B D0 83 E2 1F 48 FF C0 0F AB D1 41 89 09 49 83 EA 01 75 D5 32 C0 C3")

HARNESS = r'''
#include "win.h"
#include "fast_span.h"
static volatile long fastN = 0, handedN = 0;
static u8 Handed(u64, i32, i32, i32) { return 7; }
extern "C" __declspec(dllexport) u8 fs_fill(u64 self, i32 x, i32 y, i32 count) { return FsFill(self, x, y, count, Handed, &fastN, &handedN); }
extern "C" __declspec(dllexport) long fs_fast() { return fastN; }
extern "C" __declspec(dllexport) long fs_handed() { return handedN; }
'''


def build(tmp):
    import subprocess
    from test_industrydemand import msvc_env
    found = msvc_env()
    if not check("Visual Studio's C++ tools found (vswhere)", found is not None):
        return None
    bin_, env = found
    (tmp / "harness.cpp").write_text(HARNESS, encoding="utf-8")
    steps = [
        [str(bin_ / "cl.exe"), "/nologo", "/c", "/WX", "/O2", "/GS-", "/Zl", "/EHs-c-", "/GR-", "/std:c++17", "/I", str(NATIVE),
         str(tmp / "harness.cpp"), "/Fo:" + str(tmp / "harness.obj")],
        [str(bin_ / "link.exe"), "/nologo", "/WX", "/DLL", "/NODEFAULTLIB", "/NOENTRY", "/OUT:" + str(tmp / "harness.dll"),
         str(tmp / "harness.obj")],
    ]
    for s in steps:
        p = subprocess.run(s, cwd=tmp, env=env, capture_output=True, text=True)
        if p.returncode != 0:
            check("build: " + pathlib.Path(s[0]).name, False)
            print(p.stdout + p.stderr)
            return None
    check("fast_span.h built (cl /WX, link)", True)
    return ctypes.CDLL(str(tmp / "harness.dll"))


FN = ctypes.CFUNCTYPE(ctypes.c_uint8, ctypes.c_uint64, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32)


def game_code():
    k32 = ctypes.windll.kernel32
    k32.VirtualAlloc.restype = ctypes.c_void_p
    k32.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
    mem = k32.VirtualAlloc(None, 4096, 0x3000, 0x40)
    ctypes.memmove(mem, ORIGINAL, len(ORIGINAL))
    return FN(mem)


class Raster:
    """a BitmapRasterizable's stand-in: the bitmap's vector pointer at +8, the width at +0x10"""
    def __init__(self, width, words):
        self.words = (ctypes.c_uint32 * words)()
        self.vec = (ctypes.c_uint64 * 3)(ctypes.addressof(self.words), 0, 0)
        self.obj = (ctypes.c_uint64 * 4)(0, ctypes.addressof(self.vec), width & 0xFFFFFFFF, 0)

    @property
    def addr(self):
        return ctypes.addressof(self.obj)

    def bits(self):
        return bytes(self.words)


def main():
    if os.name != "nt":
        print("Windows only: test skipped")
        return 0
    # (the DLL stays loaded until the end: the folder is left for the system to clean, as in test_industrydemand.py)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf_fastspan_"))
    if True:
        lib = build(tmp)
        if not lib:
            return 1
        lib.fs_fill.argtypes = [ctypes.c_uint64, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32]
        lib.fs_fill.restype = ctypes.c_uint8
        orig = game_code()
        rnd = random.Random(7919)
        same, answers = True, True
        cases = [(64, 0, 0, 1), (64, 3, 0, 5), (64, 31, 0, 1), (64, 31, 0, 2), (64, 0, 0, 32), (64, 0, 0, 64), (64, 5, 1, 59),
                 (100, 7, 3, 250), (64, 0, 0, 0), (64, 10, 0, -3), (37, 36, 2, 1)]
        for _ in range(4000):
            w = rnd.choice([1, 7, 31, 32, 33, 64, 100, 257])
            rows = rnd.randint(1, 40)
            x = rnd.randint(0, w - 1)
            y = rnd.randint(0, rows - 1)
            c = rnd.choice([rnd.randint(-5, 3), rnd.randint(0, 40), rnd.randint(0, (rows - y) * w - x)])
            cases.append((w, x, y, c))
        for (w, x, y, c) in cases:
            start = (y * w + x)
            if start + max(c, 0) > 200000:
                continue
            nwords = (start + max(c, 0)) // 32 + 4
            a, b = Raster(w, nwords), Raster(w, nwords)
            seed = rnd.getrandbits(32)
            for i in range(nwords):          # the bitmap's bits before: the same random ones in both
                v = (seed * (i + 1) * 2654435761) & 0xFFFFFFFF
                a.words[i] = v
                b.words[i] = v
            ra = orig(a.addr, x, y, c)
            rb = lib.fs_fill(b.addr, x, y, c)
            if a.bits() != b.bits():
                same = False
                print("  differs:", w, x, y, c)
                break
            if ra != rb:
                answers = False
        check(f"{len(cases)} spans: the same bits as the game's own loop", same)
        check("the same answer (false)", answers)
        n0 = lib.fs_handed()
        r = Raster(10, 8)
        check("a span starting below bit 0: handed to the game's code", lib.fs_fill(r.addr, -5, 0, 3) == 7 and lib.fs_handed() == n0 + 1)
        check("and not filled here", r.bits() == bytes(32))
        check("spans filled by words counted", lib.fs_fast() > 1000)

    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8")
    sig = ORIGINAL.hex(" ").upper()
    check("the native module looks for the whole function", sig in src)
    check("MPFEVER_FASTSPAN=0: the game's own", 'GetEnvironmentVariableA("MPFEVER_FASTSPAN"' in src and "InstallFastSpan();" in src)
    exe = ROOT.parent / "TransportFever3.exe"
    if exe.exists():
        data = exe.read_bytes()
        n = data.count(ORIGINAL)
        if n == 1:
            check("TransportFever3.exe: the signature found once", True)
        else:
            print(f"(TransportFever3.exe: the signature found {n} time(s): another build, the module leaves the game's own)")
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
