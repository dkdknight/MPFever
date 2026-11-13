"""Offline test: the mod's preRunScript and its research switch MPFEVER_NOANIMALS (0.8.6, #150; mod/mpfever_1/mod.json,
mod/mpfever_1/content/mpfever_prerun.script.lua).

Two games of a session at x4 (Test Gameplay, one company per player) parted at the same step every time: an animal put back on one
game only (AnimalMoveSystem); with both cameras at the same place they stayed in step. MPFEVER_NOANIMALS=1 spawns no animal
(baseConfig.animal.populationDensityMultiplier = 0), to tell whether the animals carry the drift.
  - mod.json names the script's preRunFn (the game's own form: <modId>::/<file>.script@<fn>), _content.json lists the file;
  - without the switch, nothing changes in the base configuration;
  - with it, the animals' density multiplier is 0;
  - never an error out of it (no os, no animal table: nothing).
Needs lupa (pip install lupa). Run: python tests/test_noanimals086.py
"""
import json, os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod", "mpfever_1")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


mj = json.load(open(os.path.join(MOD, "mod.json"), encoding="utf-8-sig"))
check(mj["preRunScript"]["fileName"] == "mpfever_1::/mpfever_prerun.script@preRunFn", "mod.json names the preRunFn", mj["preRunScript"])
cj = json.load(open(os.path.join(MOD, "_content.json"), encoding="utf-8-sig"))
check("mpfever_prerun.script.lua" in cj["files"], "_content.json lists the file")
src = open(os.path.join(MOD, "content", "mpfever_prerun.script.lua"), encoding="utf-8").read()
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; print = function() end; data = nil")
L.execute(src)
# (the game reads a ".script" resource through its global data(): without it, "function data() not defined" and "Could not init
# game", seen in game on 2026-11-13 with a file that returned a module table)
check(L.eval("type(data)") == "function", "the script defines the global data() the game calls")
L.execute("M = data()")
check(L.eval("type(M.preRunFn)") == "function", "data() gives preRunFn, the field mod.json names")
L.execute("BC = { animal = { populationDensityMultiplier = 1 } }; M.preRunFn({}, {}, {}, BC)")
check(L.eval("BC.animal.populationDensityMultiplier") == 1, "without the switch: nothing changes")
L.execute('ENV.MPFEVER_NOANIMALS = "1"; M.preRunFn({}, {}, {}, BC)')
check(L.eval("BC.animal.populationDensityMultiplier") == 0, "MPFEVER_NOANIMALS=1: no animal spawned (density x 0)")
L.execute("M.preRunFn({}, {}, {}, {}); M.preRunFn({}, {}, {}, nil)")
check(True, "no animal table, no configuration: no error")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
