"""Offline test: a removal of tracks the tool joined again is replayed as the tool's native proposal (0.8.4, issue #221,
MPFEVER_TRACKMERGENATIVE=1, off by default: the cases below run with it on).

#221 (LPEM host, ls_pa): LPEM bulldozed 20 tracks with signals (-5 +1 segments, the pieces left joined again); replayed by the
engine's own removal, the ground was put back otherwise on ls_pa's game (terrain alignment removed 141.750 / 99.417): a
resynchronisation. mpfever_bridge.script.lua is read; G.trackMergeNative is run with lupa.
Run: python tests/test_trackmerge084.py
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
i0 = src.index("local removal0 = (#(stp.edgeObjectsToAdd or {}) == 0) and removalPlan(probe) or nil")
blk0 = src[i0:i0 + 600]
check("the stops' removal path: a tracks' join goes to the native street proposal before the engine's removal",
      blk0.index("if removal0 and G.trackMergeNative(probe) then") < blk0.index("return replayNativeStreet(a)") < blk0.index("if removal0 then"))
i1 = src.index("local removal = (#missing == 0) and removalPlan(probe) or nil")
blk1 = src[i1:i1 + 600]
check("the plain removal path too",
      blk1.index("if removal and G.trackMergeNative(probe) then") < blk1.index("return replayNativeStreet(a)") < blk1.index("if removal then"))
check("the in-game scenario H.trackmerge exists (a junction of three tracks, one removed, held and replayed)",
      "H.trackmerge = function(from, p)" in src and "makeSegmentsRemoveProposal({ e })" in src[src.index("H.trackmerge = function(from, p)"):])

try:
    import lupa.lua52 as lupa
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    f = re.search(r"^G\.trackMergeNative = function\(probe\)\n.*?^end\n", src, re.S | re.M).group(0)
    L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end G = {}\n" + f)
    tm = L.eval("""function(addTypes, nRemoved, env, senv)
      ENVV.MPFEVER_TRACKMERGENATIVE = env == nil and "1" or env
      ENVV.MPFEVER_STREETMERGENATIVE = senv
      local added, removed = {}, {}
      for i, t in ipairs(addTypes) do added[i] = { type = t } end
      for i = 1, nRemoved do removed[i] = { type = 1 } end
      return G.trackMergeNative({ { proposal = { addedSegments = added, removedSegments = removed } } })
    end""")
    T = L.table
    check("#221: -5 +1 tracks: the native proposal", tm(T(1), 5, None) is True)
    check("  a junction's track removed (-3 +1): the native proposal", tm(T(1), 3, None) is True)
    check("  a pure removal (nothing joined, -2 +0): the engine's removal as before", tm(T(), 2, None) is False)
    check("  streets joined again (type 0): as before", tm(T(0), 3, None) is False)
    check("  a street and a track: as before", tm(T(0, 1), 5, None) is False)
    check("  as many added as removed (no removal): as before", tm(T(1, 1), 2, None) is False)
    check("  off by default (unset: as before) until a test with the real bulldozer", tm(T(1), 5, "") is False)
    # (0.8.4, #255-#261) streets the tool joined again: Eier's -8 +2, then IsNodeLocked on the next street (MPFEVER_STREETMERGENATIVE=1)
    check("#261: streets joined again (-8 +2), MPFEVER_STREETMERGENATIVE=1: the native proposal", tm(T(0, 0), 8, "", "1") is True)
    check("  streets with the track switch only: as before", tm(T(0, 0), 8, "1", None) is False)
    check("  tracks with the street switch only: as before", tm(T(1), 5, "", "1") is False)
    check("  a street and a track, both switches: as before", tm(T(0, 1), 5, "1", "1") is False)
    check("  a pure street removal (-2 +0), street switch: the engine's removal", tm(T(), 2, "", "1") is False)
    check("  streets: off by default", tm(T(0, 0), 8, "", None) is False)
except ImportError:
    print("lupa is not installed: the function's cases not run")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
