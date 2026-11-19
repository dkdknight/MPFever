"""Offline test: the update the engine makes as it loads a game makes no step (0.9.1, #426, native/load_step.h, MPFEVER_LOADSTEP).

Report #426 (2026-11-18, 0.9.0, separate companies, host Wretched with dujuk and chris, "Mp3 samstag kohle" loaded at t=12647800,
step 63239): dujuk's game parted from the first step of the session; the host's and chris's stayed alike. The drift rings and the
native logs show why:
  - as a game is loaded, the engine copies it into a fresh state and runs one update of it at once, outside the simulation loop
    (on the loading thread, or on the new simulation thread before the loop's first iteration). That update asks the steps function
    for its steps like every batch: the savegame's speed, unless a stop point holds the game there;
  - the host had been in the main menu for more than 10 s ("stop point: no sign of life from the mod's script for 10 s, its stop
    point is left alone"), chris's game was the first of its process (no stop file yet): both made step 63239 in that update, and
    the entity a game script made in that step was made "off the simulation thread" (the host's native.log: "entity added off the
    simulation thread in its engine: 115753 thread 2 caller 9e0298"), with the free-id queue's id;
  - dujuk's game was held by the stop point of its session before ("the simulation is at step 63239, past its stop point 38538: it
    stands there"): it made step 63239 later, in the loop, and the same entity got a fresh id ("fresh id: a command's new entity
    gets 324810 (the queue's head 115753 ...) at step 63240");
  - from then on dujuk's count was one ahead: "fresh id ... gets 324811 ... at step 63242" where the host and chris gave 324810
    (same queue head 290219, 138 waiting): every vehicle and line made by a command had another id on dujuk's game.
The fix: that update makes no step on any game (StepsForBatch answers 0 while a load was seen and the loop has not made an
iteration since); every game makes its first steps after a load in the loop, on the simulation's thread, with the same rules.

Part 1 models the three games with the module's rules (fresh ids only for a command applied on the simulation's thread in the
loop) and the real load_step.h (built with MSVC into a small DLL, driven through ctypes): with MPFEVER_LOADSTEP=1 it gives the
report's ids, with the fix the same ids on every game. Part 2 checks the module's wiring.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_loadstep091.py
"""
import ctypes
import os
import pathlib
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
#include "load_step.h"
extern "C" __declspec(dllexport) void* ls_new() { static LoadStep pool[64]; static int k = 0; LoadStep* s = &pool[k++ % 64]; *s = LoadStep(); return s; }
extern "C" __declspec(dllexport) void ls_seen(void* s) { LoadStepSeen((LoadStep*)s); }
extern "C" __declspec(dllexport) void ls_iter(void* s) { LoadStepIter((LoadStep*)s); }
extern "C" __declspec(dllexport) unsigned ls_steps(void* s, unsigned sp, int on) { return LoadStepSteps((LoadStep*)s, sp, on); }
extern "C" __declspec(dllexport) unsigned long long ls_count(void* s, int which) {
    LoadStep* l = (LoadStep*)s; return which == 0 ? l->loads : which == 1 ? l->held : (unsigned long long)l->pending; }
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
    check("load_step.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.ls_new.restype = ctypes.c_void_p
    for f in (lib.ls_seen, lib.ls_iter):
        f.argtypes = [ctypes.c_void_p]
    lib.ls_steps.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int]
    lib.ls_steps.restype = ctypes.c_uint
    lib.ls_count.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.ls_count.restype = ctypes.c_ulonglong
    return lib


# ---------------------------------------------------------------- the rule
def rule_tests(lib):
    s = lib.ls_new()
    check("no load seen: a batch makes the steps it is given", lib.ls_steps(s, 4, 1) == 4)
    lib.ls_seen(s)
    check("a load seen: its update makes no step (4 at 4x)", lib.ls_steps(s, 4, 1) == 0)
    check("  counted as held", lib.ls_count(s, 1) == 1 and lib.ls_count(s, 0) == 1)
    check("  a paused savegame (speed 0): 0, not counted as held", lib.ls_steps(s, 0, 1) == 0 and lib.ls_count(s, 1) == 1)
    lib.ls_iter(s)
    check("the loop's first iteration: its batches make their steps", lib.ls_steps(s, 4, 1) == 4 and lib.ls_count(s, 2) == 0)
    check("  and the ones after", lib.ls_steps(s, 1, 1) == 1)
    o = lib.ls_new()
    lib.ls_seen(o)
    check("MPFEVER_LOADSTEP=1 (off): the update at a load makes its steps, as before", lib.ls_steps(o, 4, 0) == 4)


# ---------------------------------------------------------------- THE BUG: the three games of report #426
COUNT0, HEAD0 = 324810, 115753      # the savegame's fresh-id count, the free-id queue's head (dujuk's native.log at step 63240)


class Game:
    """One game after the load of the same savegame (step 63239, t=12647800). The module's rule for a command's new entity (a
    vehicle or a line a game script or the loop's command makes): a fresh id (the count) when the command is applied on the
    simulation's thread (sim), else the free-id queue's head. The steps of the load's update are made outside the loop."""

    def __init__(self, name, lib, on, held_by_stop_point, alive):
        self.name, self.lib, self.on = name, lib, on
        self.count = COUNT0
        self.queue = [HEAD0, 290219]
        self.step = 63239
        self.made = []          # (step, entity id, how)
        self.held_by_stop_point = held_by_stop_point   # a stop point of the session before is alive and holds the game
        self.alive = alive
        self.ls = lib.ls_new()

    def command_entity(self, sim):
        if sim:
            e = self.count
            self.count += 1
            return e, "fresh"
        return self.queue.pop(0), "queue"

    def make_steps(self, n, sim):
        for _ in range(n):
            # the game script's build of step 63239 (a construction rebuilt, its new entity through CustomEntityCreate: 9e0298)
            if self.step == 63239:
                self.made.append((self.step,) + self.command_entity(sim))
            self.step += 1
            # the session's first command entity (the host's and chris's "324810 at step 63242")
            if self.step == 63242:
                self.made.append((self.step,) + self.command_entity(True))

    def load(self, speed):
        self.lib.ls_seen(self.ls)              # ReplDetour: a game is being loaded
        # StepsForBatch for the load's update: the fix first, then the module's stop point (alive and past it: none), or no
        # session / no sign of life: the speed's steps
        n = self.lib.ls_steps(self.ls, speed, 1 if self.on else 0)
        if n and self.held_by_stop_point and self.alive:
            n = 0
        self.make_steps(n, sim=False)          # the load's update: not on the simulation's thread

    def loop(self, steps):
        self.lib.ls_iter(self.ls)              # PreIterDetour
        n = self.lib.ls_steps(self.ls, 1, 1 if self.on else 0)
        self.make_steps(min(n, steps), sim=True)
        for _ in range(steps - 1):
            self.lib.ls_iter(self.ls)
            self.make_steps(self.lib.ls_steps(self.ls, 1, 1 if self.on else 0), sim=True)


def three_games(lib, on):
    host = Game("host", lib, on, held_by_stop_point=False, alive=False)     # 10 s and more in the main menu: stop point left alone
    chris = Game("chris", lib, on, held_by_stop_point=False, alive=False)   # the first game of its process: no stop file
    dujuk = Game("dujuk", lib, on, held_by_stop_point=True, alive=True)     # held by its session before's stop point (38538)
    for g in (host, chris, dujuk):
        g.load(speed=1)
        g.loop(steps=63243 - g.step)
    return host, chris, dujuk


def model_tests(lib):
    host, chris, dujuk = three_games(lib, on=False)
    at = lambda g, s: [m for m in g.made if m[0] == s]
    check("before (MPFEVER_LOADSTEP=1, the report): the host's and chris's step 63239 made at the load, its entity the queue's 115753",
          at(host, 63239) == [(63239, 115753, "queue")] and at(chris, 63239) == [(63239, 115753, "queue")], (host.made, chris.made))
    check("  dujuk's made in the loop, its entity the fresh 324810", at(dujuk, 63239) == [(63239, 324810, "fresh")], dujuk.made)
    check("  then at step 63242 the host and chris give 324810, dujuk 324811: the ids part (the drift)",
          at(host, 63242)[0][1] == 324810 and at(chris, 63242)[0][1] == 324810 and at(dujuk, 63242)[0][1] == 324811,
          (at(host, 63242), at(dujuk, 63242)))
    host, chris, dujuk = three_games(lib, on=True)
    check("after: every game makes step 63239 in the loop, the same entities and ids on the three",
          host.made == chris.made == dujuk.made and at(host, 63239) == [(63239, 324810, "fresh")], (host.made, chris.made, dujuk.made))
    check("  every game at the same step and count", host.step == chris.step == dujuk.step == 63243 and host.count == chris.count == dujuk.count)
    check("  the hold counted on every game whose load's update had steps to make (the savegame at 1x: the three)",
          lib.ls_count(host.ls, 1) == 1 and lib.ls_count(chris.ls, 1) == 1 and lib.ls_count(dujuk.ls, 1) == 1)


# ---------------------------------------------------------------- the module's wiring
def wiring_tests():
    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8")
    pre = src[src.index('extern "C" u64 PreIterDetour(void* a)'):]
    pre = pre[:pre.index("\n}\n") if "\n}\n" in pre else pre.index("\r\n}\r\n")]
    check("PreIterDetour ends the hold at the loop's iteration", "LoadStepIter(&g_loadStep);" in pre)
    repl = src[src.index('extern "C" u64 ReplDetour(void* src, void* dst, u64 flag)'):]
    load = repl[repl.index("before == 0xFFFFFFFFu"):repl.index("u64 r = g_replOrig(src, dst, flag);")]
    check("ReplDetour: the hold starts at a load (the first copy into a fresh state), whatever MPFEVER_LOADKEEPLOCAL",
          "LoadStepSeen(&g_loadStep);" in load and load.index("LoadStepSeen") < load.index("if (!LoadKeepLocal()) DropAtLoad();"))
    sfb = src[src.index('extern "C" u32 StepsForBatch(void* time, u32 speed, u32 asked)'):]
    sfb = sfb[:sfb.index("static void InstallNativeStop()")]
    i_hold = sfb.find("if (g_loadStepOn && g_loadStep.pending) {")
    i_early = sfb.find("if (g_stopSeq < 0 || !g_getUpdRva || !time || !StopAlive()) {")
    check("StepsForBatch: the load's update answered 0 before the 'no session / no sign of life' answer (the speed)",
          i_hold > 0 and i_early > i_hold)
    block = sfb[i_hold:i_early]
    check("  counted as a batch of no step for the aligned batches", "AlignBatch(&g_align, 0, sp, 0, g_alignParity);" in block and "return 0;" in block)
    check("  after the aligned batches' load reset (the still batches counted from the load)",
          sfb.find("the still batches counted from here") < i_hold)
    check("MPFEVER_LOADSTEP=1 switches it off; in the fixes list the host compares (loadstep)",
          'GetEnvironmentVariableA("MPFEVER_LOADSTEP", e, 3) == 1 && e[0] == \'1\') ? 0 : 1' in src and 'Fx("loadstep")' in src)


def main():
    wiring_tests()
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        lib = build(pathlib.Path(td))
        if lib is not None:
            rule_tests(lib)
            model_tests(lib)
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
