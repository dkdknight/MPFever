"""The same batches on every game (0.8.18, #150; native/batch_align.h, StepsForBatch in native/mpfever_native.cpp, G.alignDown in
mpfever_bridge.script.lua; switches MPFEVER_ALIGNBATCH, MPFEVER_ALIGNPARITY), offline.

The engine keeps two world states and makes each batch of steps on the other one, after copying into it the state it made the
batch before. Some data is not copied (the systems' entity lists, caches built from the old components, "previous" values taken at
the start of a batch): a step's result can depend on where the batches end and on which state makes them. A game held behind a
slower player's clock stands at its stop point (batches of no step, as many as it waits, each one flipping the states) and ends its
batches at its own stop points: the games part now and then (#150, "slight simulation drift", about once an hour between two PCs).

AlignBatch (built with MSVC into a small DLL, driven through ctypes) ends the batches at the multiples of the speed and keeps the
runs of still batches even; the mod rounds this game's own stop points (barrier, build lead's cap, queued action's hold) down to a
multiple of the speed, the shared ones (another player's action, the session's pause, this game's own build) stay exact.
  - the rule itself: ends at the multiples, the cuts, the still runs made even, parity off, sp 0/1, n > sp;
  - THE BUG, a model of two games: per-state data not copied (a cache rebuilt from the old values, as the aircraft's was) and a
    "previous" value taken at the start of each batch. Game A runs at its speed with the shared stops only; game B stands now and
    then (held by a slower player) and stops at its own barrier. Without the fix their worlds part; with AlignBatch and the stops
    rounded down, both make the same batches on the same states and their worlds stay alike at every step (many seeds);
  - parity off: the ends aligned but the still runs odd: the states differ and the model still parts (the parity rule is needed);
  - the module's wiring and the mod's rounding (lupa): G.alignDown, used for the barrier and the queued hold only.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_alignbatch0818.py
"""
import ctypes
import os
import pathlib
import random
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
fails = []


def check(what, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + what + (" -- " + str(detail) if detail and not cond else ""), flush=True)
    if not cond:
        fails.append(what)
    return cond


HARNESS = r'''
#include "batch_align.h"
extern "C" __declspec(dllexport) void* ba_new() { static BatchAlign pool[64]; static int k = 0; BatchAlign* a = &pool[k++ % 64]; *a = BatchAlign(); return a; }
extern "C" __declspec(dllexport) unsigned ba_step(void* a, unsigned S, unsigned sp, unsigned n, int parity) { return AlignBatch((BatchAlign*)a, S, sp, n, parity); }
extern "C" __declspec(dllexport) unsigned long long ba_count(void* a, int which) {
    BatchAlign* b = (BatchAlign*)a;
    return which == 0 ? b->batches : which == 1 ? b->stills : which == 2 ? b->parityAdds : which == 3 ? b->blockCuts : b->stillRun; }
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
        p = subprocess.run(s, cwd=tmp, env=env, capture_output=True, text=True, errors="replace")
        if p.returncode != 0:
            check("build: " + pathlib.Path(s[0]).name, False)
            print(p.stdout + p.stderr)
            return None
    check("batch_align.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.ba_new.restype = ctypes.c_void_p
    lib.ba_step.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_int]
    lib.ba_step.restype = ctypes.c_uint
    lib.ba_count.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.ba_count.restype = ctypes.c_ulonglong
    return lib


# ---------------------------------------------------------------- the rule
def rule_tests(lib):
    a = lib.ba_new()
    check("a whole batch at a multiple of the speed is left whole", lib.ba_step(a, 1000, 4, 4, 1) == 4)
    check("a batch after a cut one ends at the next multiple (1002: 2 steps)", lib.ba_step(a, 1002, 4, 4, 1) == 2)
    check("the stop point's cut is kept when it is shorter (1004, n 1)", lib.ba_step(a, 1004, 4, 1, 1) == 1)
    check("then back to the multiple (1005: 3 steps)", lib.ba_step(a, 1005, 4, 4, 1) == 3)
    check("cuts counted", lib.ba_count(a, 3) == 2)
    b = lib.ba_new()
    check("one still batch (n 0)", lib.ba_step(b, 1008, 4, 0, 1) == 0)
    check("after an odd run of still batches the game stands one batch more", lib.ba_step(b, 1008, 4, 4, 1) == 0)
    check("then runs (an even run: 2)", lib.ba_step(b, 1008, 4, 4, 1) == 4)
    check("one still batch added", lib.ba_count(b, 2) == 1)
    lib.ba_step(b, 1012, 4, 0, 1); lib.ba_step(b, 1012, 4, 0, 1)
    check("after an even run it runs at once", lib.ba_step(b, 1012, 4, 4, 1) == 4)
    c = lib.ba_new()
    lib.ba_step(c, 1016, 0, 0, 1)
    check("a paused batch (speed 0) counts as a still one, the unpause evens the run", lib.ba_step(c, 1016, 4, 4, 1) == 0 and lib.ba_step(c, 1016, 4, 4, 1) == 4)
    d = lib.ba_new()
    lib.ba_step(d, 1020, 4, 0, 0)
    check("parity off: the run is left odd", lib.ba_step(d, 1020, 4, 4, 0) == 4)
    e = lib.ba_new()
    check("at 1x every batch is one step (nothing to align)", all(lib.ba_step(e, s, 1, 1, 1) == 1 for s in range(1001, 1010)))
    check("n above the speed is cut to the speed (and to the multiple)", lib.ba_step(e, 1010, 4, 9, 1) == 2)
    check("2x: ends at the even steps", lib.ba_step(e, 1013, 2, 2, 1) == 1 and lib.ba_step(e, 1014, 2, 2, 1) == 2)


# ---------------------------------------------------------------- THE BUG: two games, per-state data not copied
M = (1 << 61) - 1


class Engine:
    """A world value W (copied between the states), each state's own cache (NOT copied: rebuilt from the OLD value when the copy
    replays the change records, as the aircraft's maximum thrust was) and a value taken at the start of each batch (as the
    "previous" positions). A step's result depends on the three."""

    def __init__(self, w0):
        self.W = [w0, w0]
        self.cache = [w0 % 97, w0 % 97]
        self.changed = [False, False]   # the state's last batch changed something (its change records are not empty)
        self.cur = 0             # the state that made the last batch
        self.step = 0
        self.trace = []          # (first step, steps, state) of every batch with steps

    def batch(self, n):
        dst = 1 - self.cur
        # Replicate: the change records of the state that made the last batch are replayed into the copy, whose own cache is
        # rebuilt from its OLD value then (before the bulk copy); a batch with no step leaves no record
        if self.changed[self.cur]:
            self.cache[dst] = (self.cache[dst] * 31 + self.W[dst]) % 97
        self.W[dst] = self.W[self.cur]
        self.cur = dst
        self.changed[dst] = n > 0
        prev = self.W[dst]                  # taken at the start of the batch
        for _ in range(n):
            self.step += 1
            w = self.W[dst]
            self.W[dst] = (w * 6364136223846793005 + self.cache[dst] * 1442695040888963407 + prev) % M
        if n:
            self.trace.append((self.step - n, n, dst))

    def world(self):
        return self.W[self.cur]


def run_game(lib, align, parity, holds, seed, total=2400, speed=4, builds=(), soft_every=0):
    """One game: up to step `total` at `speed`, the shared stops at `builds` (exact), and, when `holds`, stands of 1 to 5 batches now
    and then and its own barrier stop points (soft: rounded down to the speed when `align`)."""
    rnd = random.Random(seed)
    eng = Engine(123456789)
    a = lib.ba_new()
    worlds = {}
    soft = None
    stand = 0
    guard = 0
    while eng.step < total and guard < 100000:
        guard += 1
        S = eng.step
        # this game's own barrier (a slower player's clock + a reserve): moves on, sometimes in the middle of a block
        if holds and (soft is None or S >= soft) and rnd.random() < 0.3:
            soft = S + rnd.randint(1, 9)
        exact = min([b for b in builds if b > S] + [total])
        stop = exact
        if holds and soft is not None:
            sa = soft - soft % speed if align else soft
            stop = min(stop, max(sa, S))
        n = max(0, min(speed, stop - S))
        if holds and stand == 0 and rnd.random() < 0.15:
            stand = rnd.randint(1, 5)
        if stand > 0:
            stand -= 1
            n = 0
        if holds and soft is not None and S >= (soft - soft % speed if align else soft):
            soft = None if rnd.random() < 0.5 else soft    # (the slower player's clock moves)
            n = 0
        if align:
            n = lib.ba_step(a, S, speed, n, 1 if parity else 0)
        eng.batch(n)
        worlds[eng.step] = eng.world()
    return eng, worlds


def model_tests(lib):
    parted_old, alike_new, same_batches = 0, 0, 0
    parted_noparity = 0
    seeds = range(40)
    for seed in seeds:
        builds = sorted(random.Random(seed * 7 + 1).sample(range(50, 2400), 12))
        a_old, wa_old = run_game(lib, False, True, False, seed, builds=builds)
        b_old, wb_old = run_game(lib, False, True, True, seed + 1000, builds=builds)
        if any(wa_old[s] != wb_old[s] for s in wa_old if s in wb_old):
            parted_old += 1
        a_new, wa_new = run_game(lib, True, True, False, seed, builds=builds)
        b_new, wb_new = run_game(lib, True, True, True, seed + 1000, builds=builds)
        common = [s for s in wa_new if s in wb_new]
        if all(wa_new[s] == wb_new[s] for s in common) and a_new.world() == b_new.world():
            alike_new += 1
        if a_new.trace == b_new.trace:
            same_batches += 1
        a_np, wa_np = run_game(lib, True, False, False, seed, builds=builds)
        b_np, wb_np = run_game(lib, True, False, True, seed + 1000, builds=builds)
        if any(wa_np[s] != wb_np[s] for s in wa_np if s in wb_np):
            parted_noparity += 1
    n = len(seeds)
    check(f"THE BUG: without the fix a held game parts from the other ({parted_old}/{n} seeds)", parted_old >= n * 0.9, parted_old)
    check(f"with AlignBatch both games make the same batches on the same states ({same_batches}/{n})", same_batches == n, same_batches)
    check(f"with AlignBatch their worlds stay alike at every step ({alike_new}/{n})", alike_new == n, alike_new)
    check(f"parity off (ends aligned, odd still runs): still parts ({parted_noparity}/{n}): the parity rule is needed",
          parted_noparity >= n * 0.9, parted_noparity)
    # one game alone, held or not, ends the same: the fix changes no result, only where the batches end
    a1, w1 = run_game(lib, True, True, False, 5, builds=(100, 776))
    a2, w2 = run_game(lib, False, True, False, 5, builds=(100, 776))
    check("a game never held, its stop points at multiples, makes the same batches and world with or without the fix", a1.trace == a2.trace and w1 == w2)


# ---------------------------------------------------------------- wiring
def wiring_tests():
    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8", errors="replace")
    body = src[src.index('extern "C" u32 StepsForBatch'):]
    body = body[:body.index("\nstatic void InstallNativeStop")]
    check("StepsForBatch calls AlignBatch after the stop point and the hold test", body.index("TestHold(S, sp, n)") < body.index("AlignBatch(&g_align, S, sp, n, g_alignParity)"))
    check("only for the speed's batches (the old exact steps left as asked)", "g_alignOn == 1 && asked <= speed" in body)
    check("switches MPFEVER_ALIGNBATCH and MPFEVER_ALIGNPARITY", 'GetEnvironmentVariableA("MPFEVER_ALIGNBATCH"' in src and 'GetEnvironmentVariableA("MPFEVER_ALIGNPARITY"' in src)
    check("in the fixes list (native_fx.txt) the host compares", 'Fx("alignbatch")' in src and 'Fx("alignparity")' in src)
    check("counted in the minute's line", '"; aligned batches "' in src)
    early = body[:body.index("u32 n = sp;")]
    check("every batch counted from the load on, also before the session (no stop point yet): still runs alike on every game",
          "if (sp == 0) { g_align.stillRun++; g_align.stills++; } else g_align.stillRun = 0;" in early)
    check("a load (the step back, or more than 64 on) starts the count again", "S1 < g_alignLastS || S1 > g_alignLastS + 64" in early and "alignLoads != g_ctlLoads" in early and "g_align.stillRun = 0;" in early)
    check("the test switch MPFEVER_TESTHOLD (one game stands now and then)", 'GetEnvironmentVariableA("MPFEVER_TESTHOLD"' in src)
    check("MPFEVER_TESTSPLIT with aligned batches cuts the steps left as a stop point would (the speed kept for the alignment)",
          "if (g_alignOn == 1) splitCut = 1 + (S0 * 7 + S0 / 3) % sp;" in body and "if (splitCut && n > splitCut) n = splitCut;" in body
          and body.index("if (splitCut && n > splitCut) n = splitCut;") < body.index("AlignBatch(&g_align, S, sp, n, g_alignParity)"))
    check("AlignInit first in StepsForBatch (the split test reads the switch)", body.index("if (g_alignOn < 0) AlignInit();") < body.index("u32 splitCut = 0;"))
    lua = (ROOT / "mod" / "mpfever_1" / "content" / "mpfever_bridge.script.lua").read_text(encoding="utf-8", errors="replace")
    pace = lua[lua.index("local function pacing()"):]
    pace = pace[:pace.index("\nend\n")]
    check("the mod: the queued hold rounded down", "q = G.alignDown(q, spdNow)" in pace)
    check("the mod: the barrier's soft stop rounded down", "local soft = G.alignDown(barrier + overshootReserve() * STEP, spdNow)" in pace)
    check("the mod: the shared stops (pause, holds, own released build) left exact", "G.alignDown(s.pauseAt" not in pace and "G.alignDown(G.holdAt" not in pace and "G.alignDown(rh" not in pace)
    try:
        import lupa
    except ImportError:
        check("lupa installed (pip install lupa)", False)
        return
    m = re.search(r"G\.alignOn = (.*?)\nG\.alignDown = (function\(t, k\).*?\nend)\n", lua, re.S)
    if not check("G.alignDown found", m is not None):
        return
    for on in (True, False):
        L = lupa.LuaRuntime(unpack_returned_tuples=True)
        L.execute("G = {}; STEP = 200; G.alignOn = " + ("true" if on else "false") + "\nG.alignDown = " + m.group(2))
        f = L.eval("G.alignDown")
        if on:
            check("alignDown: 1003 steps at 4x -> 1000", f(1003 * 200, 4) == 1000 * 200)
            check("alignDown: a multiple stays", f(1004 * 200, 4) == 1004 * 200)
            check("alignDown: 2x -> even", f(1003 * 200, 2) == 1002 * 200)
            check("alignDown: 1x and paused unchanged", f(1003 * 200, 1) == 1003 * 200 and f(1003 * 200, 0) == 1003 * 200)
            check("alignDown: none stays none", f(None, 4) is None)
        else:
            check("MPFEVER_ALIGNBATCH=0: the stop points as before", f(1003 * 200, 4) == 1003 * 200)
    check("the switch read from the environment", 'G.alignOn = os.getenv("MPFEVER_ALIGNBATCH") ~= "0"' in lua)


def main():
    wiring_tests()
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as t:
        lib = build(pathlib.Path(t))
        if lib:
            rule_tests(lib)
            model_tests(lib)
    print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
