"""The native module's lists of game states (native/state_seen.h, 0.6.12), offline: the header is built with MSVC into a small
DLL (as native/build.bat builds the module: freestanding, /WX) and driven through ctypes.

The engine runs its batches on two game states by turns, and every game loaded in a process (the session's start, every
resynchronisation) brings two new ones. A list of 16 states whose new states always took the first place once full made the
two states of the ninth game take that place in turn: each was "a new game state" at every batch, and the native module forgot
this machine's player at every batch (the line routes on the map shown for an instant every few seconds after a
resynchronisation, Discord 2026-11-03).

Cases: a state not in a full list takes the oldest place; after 20 games loaded, the two states of the last one are new once
each, then known at every batch; MPFEVER_SEENFIRST's way (the first place) gives the old behaviour: new at every batch.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_stateseen.py
"""
import ctypes
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
fails = []


def check(what, cond):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)
    return cond


# a list as ApplyLocalPlayer keeps it, and a run of games: each loads two states, then runs `batches` batches on them by turns;
# returns how many times a state of the last game was taken for a new one during its batches
HARNESS = r'''
#include "state_seen.h"
static void* g_seen[SEEN_MAX]; static int g_n = 0, g_next = 0;
static bool Known(void* p) { for (int i = 0; i < g_n; i++) if (g_seen[i] == p) return true; return false; }
static bool See(void* p, bool first) { if (Known(p)) return false; g_seen[SeenPlace(&g_n, &g_next, first)] = p; return true; }
extern "C" __declspec(dllexport) int ss_run(int games, int batches, int first)
{
    g_n = 0; g_next = 0;
    int lastNew = 0;
    for (int g = 0; g < games; g++) {
        void* a = (void*)(unsigned long long)(0x1000 + g * 0x20);
        void* b = (void*)(unsigned long long)(0x1010 + g * 0x20);
        int news = 0;
        for (int k = 0; k < batches; k++) news += See((k & 1) ? b : a, first != 0) ? 1 : 0;
        lastNew = news;
    }
    return lastNew;
}
extern "C" __declspec(dllexport) int ss_place(int n, int next, int first, int* nOut, int* nextOut)
{
    int i = SeenPlace(&n, &next, first != 0);
    *nOut = n; *nextOut = next;
    return i;
}
'''


def msvc_env():
    vswhere = os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Microsoft Visual Studio", "Installer", "vswhere.exe")
    if not os.path.isfile(vswhere):
        return None
    p = subprocess.run([vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                        "-property", "installationPath"], capture_output=True, text=True)
    vs = (p.stdout or "").strip().splitlines()
    if not vs:
        return None
    ver = (pathlib.Path(vs[0]) / "VC" / "Auxiliary" / "Build" / "Microsoft.VCToolsVersion.default.txt").read_text().strip()
    vc = pathlib.Path(vs[0]) / "VC" / "Tools" / "MSVC" / ver
    bin_ = vc / "bin" / "Hostx64" / "x64"
    return bin_, dict(os.environ, PATH=str(bin_) + os.pathsep + os.environ.get("PATH", ""),
                      INCLUDE=str(vc / "include"), LIB=str(vc / "lib" / "x64"))


def build(tmp):
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
    check("state_seen.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.ss_run.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lib.ss_place.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    return lib


def main():
    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8")
    check("ApplyLocalPlayer takes a state's place from SeenPlace", "seen[SeenPlace(&nseen, &seenNext, SeenFirst())] = g_slot;" in src)
    check("NoteWritten too", "di = SeenPlace(&g_nDone, &g_doneNext, SeenFirst());" in src)
    check("MPFEVER_SEENFIRST read", '"MPFEVER_SEENFIRST"' in src)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf-seen-"))
    try:
        lib = build(tmp)
        if lib is None:
            return 1
        n, nx = ctypes.c_int(), ctypes.c_int()
        check("a list not full: the next place", lib.ss_place(5, 0, 0, ctypes.byref(n), ctypes.byref(nx)) == 5 and n.value == 6)
        i1 = lib.ss_place(16, 0, 0, ctypes.byref(n), ctypes.byref(nx))
        i2 = lib.ss_place(16, nx.value, 0, ctypes.byref(n), ctypes.byref(nx))
        check("a full list: the oldest place, in turn (0 then 1)", i1 == 0 and i2 == 1 and n.value == 16)
        check("MPFEVER_SEENFIRST's way: always the first place", lib.ss_place(16, 7, 1, ctypes.byref(n), ctypes.byref(nx)) == 0)
        check("the session's first games: two new states each, then known", lib.ss_run(3, 400, 0) == 2)
        check("after 20 games loaded in one process: the last game's two states are new once each, then known", lib.ss_run(20, 400, 0) == 2)
        check("(as before, the first place: after 9 games, new at every batch, the player forgotten at every batch)", lib.ss_run(9, 400, 1) == 400)
        check("(as before, 8 games still fit)", lib.ss_run(8, 400, 1) == 2)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
