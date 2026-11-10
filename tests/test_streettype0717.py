"""Offline test: a street changed to another type is replayed as its builder built it (0.7.17, issue #191; replayNativeStreet,
G.replayMergedUpgrade and G.mergeSegMap in mpfever_bridge.script.lua, C.rebuildNativeWithConstruction in mpfever_common.lua).

#191 (NightHawk2583 and liber, 22:05-22:12, four resyncs): liber changed streets to country_old_medium.
  A. 11 segments and the node they met at: "the engine's removal (13 segments) differs from the tool's (11)", the replay gave up.
     Now, when the engine's removal holds all of the tool's segments and more, the tool's only are removed (rmOnly), with the
     tool's removed nodes; MPFEVER_RMDIFFOK=0: as before.
  B. 5 then 2 segments: "merged upgrade: command Unknown exception" (GetLaneOffset 4 >= 4: a lane connection named a new segment
     of another template), then one segment after the other, the ground levelled otherwise (al 2658/1567). Now the tool's new
     segments are matched to the merged ones by their nodes (G.mergeSegMap), then the tool's junctions as before, then the
     engine's own, before the way of before; MPFEVER_MERGERETRY=0: as before.
Needs lupa (pip install lupa). Run: python tests/test_streettype0717.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


br = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
co = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")

# A: static
ns = br[br.index("local function replayNativeStreet(a)"):]
ns = ns[:ns.index("\nend\n")]
check('os.getenv("MPFEVER_RMDIFFOK") ~= "0"' in ns, "A: MPFEVER_RMDIFFOK=0: as before")
check("if nSeg > #rmIds and #rmIds > 0 and nNodes >= 0" in ns and "if not has[e] then all = false end" in ns,
      "A: only when the engine's removal holds every segment of the tool's, and more")
check("(nSeg ~= #rmIds and not rmOnly) or nNodes < 0" in ns and 'gaveUp("removal differs")' in ns, "A: otherwise given up as before")
check("variant.rmOnly = rmOnly" in ns and "variant.toolNodes = toolNodes or (rmOnly ~= nil)" in ns, "A: the tool's segments and nodes only")
rb = co[co.index("function C.rebuildNativeWithConstruction("):]
check("if opts.rmOnly[sg.entity] then keep[#keep + 1] = sg end" in rb and "sp.removedSegments = keep" in rb,
      "A: the rebuild keeps the tool's removed segments only")

# A: the filter itself, run
blk = rb[rb.index("local ok1, e1 = pcall(function()"):]
blk = blk[:blk.index("\n\t\tend)\n") + 7]
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("function run(opts) local sp = {} local rsp = { removedSegments = { {entity=1},{entity=2},{entity=3},{entity=9} } } local C = { errors = {} }\n"
          + blk + "\n return sp, ok1 end")
sp, ok1 = L.eval("run")(L.eval("{ rmOnly = { [1] = true, [3] = true } }"))
check(ok1 and len(sp.removedSegments) == 2 and sp.removedSegments[2].entity == 3, "A: run: 4 segments of the engine, the tool's 2 kept")
sp, ok1 = L.eval("run")(L.eval("{}"))
check(ok1 and len(sp.removedSegments) == 4, "A: run: without rmOnly, the engine's list as before")

# B: G.mergeSegMap run
a = br.index("G.mergeSegMap = function(st, added)")
b = br.index("\nend\n", a) + 5
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
L2.execute("G = {}\n" + br[a:b])
L2.execute('''
function seg(n0, n1) return { comp = { node0 = n0, node1 = n1 } } end
-- the plan's order: (10,11) (11,12); the tool listed (11,12) as -1 and (10,11) as -2
ADDED = { seg(10, 11), seg(11, 12) }
ST = { addedSegments = { { entity = -1, comp = { node0 = 11, node1 = 12 } }, { entity = -2, comp = { node0 = 10, node1 = 11 } } },
       nodeConfigsToAdd = { { entity = 11, comp = { laneConnections = { { segment0 = -1, lane0 = 3, segment1 = -2, lane1 = 0 }, { segment0 = 500, lane0 = 1, segment1 = -1, lane1 = 2 } }, crosswalks = { 1 } } } } }
''')
out = L2.eval("G.mergeSegMap(ST, ADDED)")
check(out is not None, "B: the tool's other order is matched")
if out is not None:
    l1 = out[1].comp.laneConnections[1]
    l2 = out[1].comp.laneConnections[2]
    check(l1.segment0 == -2 and l1.segment1 == -1 and l2.segment0 == 500 and l2.segment1 == -2,
          "B: lane connections renumbered as here, existing segments kept", f"{l1.segment0},{l1.segment1},{l2.segment0},{l2.segment1}")
    check(out[1].entity == 11 and out[1].comp.crosswalks[1] == 1, "B: the node and its other fields kept")
    check(L2.eval("ST.nodeConfigsToAdd[1].comp.laneConnections[1].segment0") == -1, "B: the capture itself unchanged")
L2.execute("ST.addedSegments[1].entity = -2; ST.addedSegments[2].entity = -1; ST.addedSegments[1].comp = { node0 = 10, node1 = 11 }; ST.addedSegments[2].comp = { node0 = 11, node1 = 12 }")
L2.execute("ST.addedSegments[1].entity = -1; ST.addedSegments[2].entity = -2")
check(L2.eval("G.mergeSegMap(ST, ADDED)") is None, "B: the same order: nothing changed (nil)")
L2.execute("ST.addedSegments[2].comp = { node0 = 77, node1 = 78 }")
check(L2.eval("G.mergeSegMap(ST, ADDED)") is None, "B: a segment not matched: nil (the way of before)")

mu = br[br.index("G.replayMergedUpgrade = function(a, plan, probe)"):]
mu = mu[:mu.index("\nend\n")]
check('os.getenv("MPFEVER_MERGERETRY") ~= "0"' in mu, "B: MPFEVER_MERGERETRY=0: as before")
check('tries = { "matched", "tool", "engine" }' in mu and 'tries = { "tool", "engine" }' in mu and 'local tries = { "tool" }' in mu,
      "B: matched, then the tool's, then the engine's junctions")
check('if how ~= "engine"' in mu and "if not cmd then return false end" in mu, "B: none made: the way of before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
