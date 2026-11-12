"""Offline test: a signal on a street goes the old way, and a removal by rank on a segment whose objects differ is not built
(0.8.4, issue #253, MPFEVER_STREETSIGDRY / MPFEVER_STOPOBJCHECK).

#253 (leinl host, marce): marce put "Deutsche Signale" signals (tf3_signale_de_1, category 2) on streets; on leinl's game the
engine BUILT the dry run of their conversion (G.eoDryRun, made to be refused) 5 times of 5, a resynchronisation each time, and
13 s after the last one marce removed a signal: the replay's removal by rank took another object and the game stopped
("GetComponentDataIndex", entity 56766). mpfever_bridge.script.lua is read; the two functions are run with lupa.
Run: python tests/test_stopobjcheck084.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BR = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(BR, encoding="utf-8").read().replace("\r\n", "\n")

# stopPlan keeps the kinds of the builder's objects
sp = src[src.index("local function stopPlan(margs)"):]
sp = sp[:sp.index("\nend\n")]
check("stopPlan keeps the kinds of the builder's segment's objects (oldKinds)",
      "oldKinds[k] = (type(o) == \"table\") and o[2] or false" in sp and "oldKinds = oldKinds }" in sp)

# the native path: the check first, then a street signal goes the old way, before the dry run
ns = src[src.index("G.replayNativeStop = function(a, plan)"):]
ns = ns[:ns.index("\nend\n")]
i_c = ns.index("if not c then return asBefore(")
i_d = ns.index("local differ = G.stopObjsDiffer(plan, c)")
i_s = ns.index('if G.streetSignalDry(plan, c) then return asBefore("a signal on a street (the engine builds its dry run)") end')
i_dry = ns.index("pcall(G.eoDryRun, m,")
check("replayNativeStop: the objects checked after the segment is read, then a street signal, both before the dry run", i_c < i_d < i_s < i_dry)
check("  objects that differ: not built, the replay fails (resynchronisation)",
      'return replayFailed(a, "native stop: the segment\'s objects differ")' in ns)

# the script path (replayStop) is checked too
check("the script path checks the objects before replayStop",
      'local differ = c0 and G.stopObjsDiffer(plan, c0)' in src and 'return replayFailed(a, "stop: the segment\'s objects differ")' in src)

try:
    import lupa.lua52 as lupa
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    f1 = re.search(r"^G\.stopObjsDiffer = function\(plan, c\)\n.*?^end\n", src, re.S | re.M).group(0)
    f2 = re.search(r"^G\.streetSignalDry = function\(plan, c\)\n.*?^end\n", src, re.S | re.M).group(0)
    L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end G = {}\n" + f1 + f2)
    differ = L.eval("""function(oldKinds, here, removeIdx, env)
      ENVV.MPFEVER_STOPOBJCHECK = env
      local plan = { oldKinds = oldKinds, removeIdx = removeIdx }
      local c = { objects = here }
      return G.stopObjsDiffer(plan, c)
    end""")
    T = L.table
    check("the builder's segment and this one carry the same signal: removed as before",
          differ(T(2), T(T(56000, 2)), T(True), None) is None)
    check("one object more here (#253: the conversion built twice): not built",
          differ(T(2), T(T(56000, 2), T(56766, 2)), T(True), None) is not None)
    check("another kind at the rank (a stop instead of a signal): not built",
          differ(T(2), T(T(56000, 1)), T(True), None) is not None)
    check("nothing removed (a new stop only): no check", differ(T(), T(T(1, 1)), T(), None) is None)
    check("MPFEVER_STOPOBJCHECK=0: as before", differ(T(2), T(T(1, 2), T(2, 2)), T(True), "0") is None)
    sig = L.eval("""function(segType, cat, env)
      ENVV.MPFEVER_STREETSIGDRY = env
      return G.streetSignalDry({ objs = { { category = cat } } }, { type = segType })
    end""")
    check("a signal (category 2) on a street (type 0): the old way", sig(0, 2, None) is True)
    check("  a stop (category 0) on a street: the dry run as before", sig(0, 0, None) is False)
    check("  a signal on a track (type 1): as before", sig(1, 2, None) is False)
    check("  MPFEVER_STREETSIGDRY=1: the dry run as before", sig(0, 2, "1") is False)
except ImportError:
    print("lupa is not installed: the functions' cases not run")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
