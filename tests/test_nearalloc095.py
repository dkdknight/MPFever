"""Memory near the game's code (native/near_alloc.h, 0.9.5, #459), offline: the header is built with MSVC into a small DLL (as
tests/test_fastspan.py does) and asked for places near a stand-in "game image" laid in this process's own address space, with
the ranges around it reserved or left free by hand (VirtualAlloc MEM_RESERVE).

#459 (Flubi, 2026-11-21): the second start of his game found no free place in the band the native module searched (1 MB steps
from 256 MB to 1.75 GB below the image's start): every hook that needs one stayed off ("nat off"), the host's game drifted from
the other and the session resynchronised again and again.

Cases:
- the bug: that band taken (and the 256 MB just under the image): the first pass alone (MPFEVER_NEARSCAN=0, as up to 0.9.4)
  finds nothing;
- the fix: the same, with the scan: a place ABOVE the image, within 1.75 GB of its start, reachable with a rel32 from every byte
  of the image (and back);
- the space above taken too: the place just below the image (the 256 MB the first pass leaves out);
- everything taken: nothing, and no place outside the reach;
- nothing taken: exactly the first pass's place of before (256 MB below the start), scan or not;
- the band's description for the log: no free bytes, one allocation of 1.5 GB, reserved, private.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_nearalloc095.py
"""
import ctypes
import os
import pathlib
import subprocess
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


HARNESS = r'''
#include "win.h"
#include "near_alloc.h"
extern "C" __declspec(dllexport) u64 na_alloc(u64 base, u64 imageEnd, u64 size, int scan, int* how)
{ return (u64)NearAlloc(base, imageEnd, size, scan != 0, how); }
extern "C" __declspec(dllexport) void na_band(u64 base, u64* out)
{ NaBand b = NearBandInfo(base); out[0] = b.freeBytes; out[1] = b.allocations; out[2] = b.bigAt; out[3] = b.bigSize; out[4] = b.bigType; out[5] = b.bigState; }
'''

FAR, NEAR, IMG = 0x70000000, 0x10000000, 0x04000000     # the reach (1.75 GB), the first pass's start (256 MB), a 64 MB image
MEM_RESERVE, MEM_RELEASE, PAGE_NOACCESS = 0x2000, 0x8000, 0x01

k32 = ctypes.windll.kernel32 if os.name == "nt" else None
if k32:
    k32.VirtualAlloc.restype = ctypes.c_void_p
    k32.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
    k32.VirtualFree.restype = ctypes.c_int
    k32.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]


def build(tmp):
    from test_industrydemand import msvc_env
    found = msvc_env()
    if not check("Visual Studio's C++ tools found (vswhere)", found is not None):
        return None
    bin_, env = found
    (tmp / "harness.cpp").write_text(HARNESS, encoding="utf-8")
    steps = [
        [str(bin_ / "lib.exe"), "/nologo", "/def:" + str(NATIVE / "kernel32.def"), "/out:" + str(tmp / "kernel32.lib"), "/machine:x64"],
        [str(bin_ / "cl.exe"), "/nologo", "/c", "/WX", "/O2", "/GS-", "/Zl", "/EHs-c-", "/GR-", "/std:c++17", "/I", str(NATIVE),
         str(tmp / "harness.cpp"), "/Fo:" + str(tmp / "harness.obj")],
        [str(bin_ / "link.exe"), "/nologo", "/WX", "/DLL", "/NODEFAULTLIB", "/NOENTRY", "/OUT:" + str(tmp / "harness.dll"),
         str(tmp / "harness.obj"), str(tmp / "kernel32.lib")],
    ]
    for s in steps:
        p = subprocess.run(s, cwd=tmp, env=env, capture_output=True, text=True)
        if p.returncode != 0:
            check("build: " + pathlib.Path(s[0]).name, False)
            print(p.stdout + p.stderr)
            return None
    check("near_alloc.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.na_alloc.argtypes = [ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    lib.na_alloc.restype = ctypes.c_uint64
    lib.na_band.argtypes = [ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
    return lib


class Space:
    """A free span of this process's address space: [base - FAR, base + FAR) around a stand-in image [base, base + IMG)."""
    def __init__(self):
        total = 2 * FAR + 0x10000000
        x = k32.VirtualAlloc(None, total, MEM_RESERVE, PAGE_NOACCESS)
        if not x:
            raise RuntimeError("no free span of 3.75 GB in this process")
        k32.VirtualFree(x, 0, MEM_RELEASE)
        self.base = x + FAR + 0x08000000
        self.held = {}

    def take(self, name, lo, hi):
        a = k32.VirtualAlloc(lo, hi - lo, MEM_RESERVE, PAGE_NOACCESS)
        if a != lo:
            raise RuntimeError(f"could not reserve {name} at {lo:#x}")
        self.held[name] = lo

    def give(self, name):
        k32.VirtualFree(self.held.pop(name), 0, MEM_RELEASE)

    def clear(self):
        for n in list(self.held):
            self.give(n)


def ask(lib, sp, scan, size=0x400):
    how = ctypes.c_int(-1)
    m = lib.na_alloc(sp.base, sp.base + IMG, size, scan, ctypes.byref(how))
    return m, how.value


def reachable(sp, m, size):
    # a rel32 from every byte of the image to every byte of the place, and back
    lo, hi = sp.base, sp.base + IMG
    return all(abs(a - b) < 0x7FFFFFF0 for a in (lo, hi) for b in (m, m + size))


def main():
    if os.name != "nt":
        print("Windows only: test skipped")
        return 0
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf_nearalloc_"))
    lib = build(tmp)
    if not lib:
        return 1
    sp = Space()
    b = sp.base
    try:
        sp.take("image", b, b + IMG)

        # the bug (#459): the band below taken, and the 256 MB just under the image
        sp.take("band", b - FAR, b - NEAR)
        sp.take("under", b - NEAR, b)
        m, how = ask(lib, sp, 0)
        check("bug: the band below taken, the first pass alone (as up to 0.9.4): no place (the hooks stay off)", m == 0 and how == 0)

        # the fix: above the image
        m, how = ask(lib, sp, 1)
        check("fix: a place found above the image", m != 0 and how == 2)
        check("  after the image's end, within 1.75 GB of its start", b + IMG <= m < b + FAR)
        check("  reachable with a rel32 from every byte of the image, and back", reachable(sp, m, 0x400))
        if m:
            k32.VirtualFree(m, 0, MEM_RELEASE)

        # above taken too: just below the image
        sp.take("above", b + IMG, b + FAR)
        sp.give("under")
        sp.take("under1", b - NEAR, b - NEAR + 0x100000)     # (the first pass's first place, 256 MB below, still taken)
        m, how = ask(lib, sp, 1)
        check("fix: the space above taken too: a place just below the image", m != 0 and how == 3)
        check("  within the 256 MB under the image", b - NEAR <= m < b and reachable(sp, m, 0x400))
        if m:
            k32.VirtualFree(m, 0, MEM_RELEASE)

        # everything taken: nothing (and never a place out of reach)
        sp.give("under1")
        sp.take("under", b - NEAR, b)
        m, how = ask(lib, sp, 1)
        check("everything within reach taken: nothing", m == 0 and how == 0)

        # the band's description for the log
        out = (ctypes.c_uint64 * 6)()
        lib.na_band(b, out)
        check("band for the log: no free byte, one allocation of 1.5 GB, reserved, private",
              out[0] == 0 and out[1] == 1 and out[3] == FAR - NEAR and out[4] == 0x20000 and out[5] == 0x2000 and out[2] == b - FAR)

        # nothing taken: the place of before, scan or not
        sp.clear()
        sp.take("image", b, b + IMG)
        m0, h0 = ask(lib, sp, 0)
        if m0:
            k32.VirtualFree(m0, 0, MEM_RELEASE)
        m1, h1 = ask(lib, sp, 1)
        if m1:
            k32.VirtualFree(m1, 0, MEM_RELEASE)
        check("nothing taken: the first pass's place of before (256 MB below), scan or not", m0 == m1 == b - NEAR and h0 == h1 == 1)
        lib.na_band(b, out)
        check("band for the log when free: all 1.5 GB free, no allocation", out[0] == FAR - NEAR and out[1] == 0)
    finally:
        sp.clear()

    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8")
    al = src[src.index("static u8* AllocNear(u64 size)"):]
    al = al[:al.index("\n}\n")]
    check("AllocNear goes through near_alloc.h", '#include "near_alloc.h"' in src and "NearAlloc(g_base, imageEnd, size, scan == 1, &how)" in al)
    check("MPFEVER_NEARSCAN=0: the first pass alone", 'GetEnvironmentVariableA("MPFEVER_NEARSCAN"' in al and "scan = (n == 1 && v[0] == '0') ? 0 : 1;" in al)
    check("the image's end read from SizeOfImage", "OptionalHeader.SizeOfImage" in al)
    check("said once in native.log when the band has nothing", "g_nearSaid" in al and "none in the band 256 MB to 1.75 GB below it" in al)
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
