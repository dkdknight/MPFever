"""Offline test (0.8.17, #399): a game script's build keeps the existing edge objects of a new segment by reference, and a form
that would leave stops or signals on a segment it removes is refused (R.translateOut in mpfever_refs.lua, switch
MPFEVER_GSMODOBJS; C.strandedObjects in mpfever_common.lua, switch MPFEVER_GSSTRAND).

#399 (Swen and domin, 2026-11-16 20:28): Swen's Auto Signals build (a signal path over 3 segments) gave a new segment the signal
already there, comp.objects {{129113, 2}}: Swen's id. On domin's game the first form failed on it (GetComponentDataIndex
asserted), the 'minimal' form (it drops comp.objects) was built, removed the segments with their stops, and domin's game crashed
on the stops left behind (TransportNetwork missing).
  - translateOut on A: a new segment's existing objects go as references, new ones (below 0) as they are; translateIn on B
    gives B's ids (6994 -> 9001); MPFEVER_GSMODOBJS=0: A's raw id on B (the bug: another entity, or none);
  - C.strandedObjects: a removed segment's objects that the build neither removes nor keeps make a form without the objects
    refused ('minimal', 'bare'); the 'full' form keeping them, or a build removing them, passes; MPFEVER_GSSTRAND=0: never
    refused (the bug: the stops stranded);
  - a tool's native build (removed segments with their comp): not concerned.
Needs lupa (pip install lupa). Run: python tests/test_gsmodobjs0817.py
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


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
NODES, EDGES, EO2EDGE = {}, {}, {}
api = {
  type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = {
    entityExists = function(e) return NODES[e] ~= nil or EDGES[e] ~= nil end,
    getComponent = function(e, ct)
      if ct == "BASE_NODE" and NODES[e] then return { position = NODES[e] } end
      if ct == "BASE_EDGE" and EDGES[e] then return EDGES[e] end
      return nil
    end,
    system = { streetSystem = {
      getNode2SegmentMap = function()
        local m = {}
        for n in pairs(NODES) do m[n] = {} end
        for s, c in pairs(EDGES) do table.insert(m[c.node0], s); table.insert(m[c.node1], s) end
        return m
      end,
      getEdgeForEdgeObject = function(o) return EO2EDGE[o] end,
    } },
    util = { getPlayer = function() return 1 end },
  },
}
'''
refs = open(os.path.join(CONTENT, "mpfever_refs.lua"), encoding="utf-8").read()
A = lupa.LuaRuntime(unpack_returned_tuples=True)
B = lupa.LuaRuntime(unpack_returned_tuples=True)
for g in (A, B):
    g.execute(MOCK)
    g.globals().R = g.execute(refs)
    g.execute('''
function ser(v)
  if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
  local t = {}
  for k, x in pairs(v) do t[#t + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
  table.sort(t)
  return "{" .. table.concat(t, ",") .. "}"
end''')
# the same street, other ids: A (AMD) 35440 -- 89792 -- 50121, object 6994; B (keviK) 70 -- 500 -- 71, object 9001
A.execute('''NODES = { [35440] = { x = 1579.3, y = 10579.5, z = 0.9 }, [50121] = { x = 1676.8, y = 10576.6, z = 1.2 } }
EDGES = { [89792] = { node0 = 35440, node1 = 50121, objects = { { 6994, 1 } } } }
EO2EDGE = { [6994] = 89792 }''')
B.execute('''NODES = { [70] = { x = 1579.3, y = 10579.5, z = 0.9 }, [71] = { x = 1676.8, y = 10576.6, z = 1.2 },
  [89792] = { x = 0, y = 0, z = 0 }, [35440] = { x = 5, y = 5, z = 0 } }
EDGES = { [500] = { node0 = 70, node1 = 71, objects = { { 9001, 1 } } } }
EO2EDGE = { [9001] = 500 }''')


ARGS = """{ n = 5, [1] = { constructionsToRemove = {}, streetProposal = {
  edgesToRemove = { 89792 }, nodesToRemove = {}, nodeConfigsToRemove = {}, edgeObjectsToRemove = {},
  edgesToAdd = { { entity = -1, comp = { node0 = 35440, node1 = 50121, type = 1, objects = { { 6994, 2 }, { -400000000, 1 } } } } },
  edgeObjectsToAdd = {}, nodesToAdd = {}, nodeConfigsToAdd = {} } }, [2] = {}, [3] = false, [4] = true, [5] = true }"""


def ship(env=""):
    return A.eval('(function() ENV = {' + env + '} local m = ' + ARGS + ' R.translateOut("makeWorldBuildProposalCmd", m, {}) ENV = {} return ser(m) end)()')


def arrive(text):
    miss = B.eval('(function(t) M = assert(load("return " .. t))() return #R.translateIn(M, {}) end)')(text)
    return miss, B.eval("M[1].streetProposal.edgesToAdd[1].comp.objects")


miss, objs = arrive(ship())
check(miss == 0, "B: every reference found", miss)
check(objs[1][1] == 9001 and objs[1][2] == 2, "B: the kept signal 6994 -> 9001 (its kind kept)", objs[1][1])
check(objs[2][1] == -400000000, "B: a new object's number kept")
miss, objs = arrive(ship('MPFEVER_GSMODOBJS = "0"'))
check(objs[1][1] == 6994, "MPFEVER_GSMODOBJS=0: A's id 6994 on B, as before (the bug: no such object there)", objs[1][1])

# C.strandedObjects, from the real mpfever_common.lua
import re
common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^function C\.strandedObjects\(st, variant\)\n.*?^end\n", common, re.S | re.M)
check(m is not None, "C.strandedObjects found")
check("local strand = C.strandedObjects(st, variant)" in common and common.index("local strand = C.strandedObjects(st, variant)") > common.index('if C.movesObjects(st) then error('), "  C.rebuildArgs refuses such a form, after the native-only check")
S = lupa.LuaRuntime(unpack_returned_tuples=True)
S.execute(MOCK)
S.execute("C = {}\n" + m.group(0))
S.execute("EDGES = { [500] = { node0 = 70, node1 = 71, objects = { { 9001, 1 } } }, [600] = { node0 = 71, node1 = 72, objects = {} } }")
run = S.eval("function(code) return assert(load(code))() end")
st = "{ edgesToRemove = { 500, 600 }, edgeObjectsToRemove = {}, edgesToAdd = { { comp = { objects = { { 9001, 2 } } } } } }"
check(run("return C.strandedObjects(%s, 'minimal')" % st) == "500:9001", "the 'minimal' form would strand signal 9001 of segment 500: refused")
check(run("return C.strandedObjects(%s, 'bare')" % st) == "500:9001", "the 'bare' form too")
check(run("return C.strandedObjects(%s, 'full')" % st) is None, "the 'full' form keeps it on the new segment: built")
st2 = "{ edgesToRemove = { 500 }, edgeObjectsToRemove = { 9001 }, edgesToAdd = {} }"
check(run("return C.strandedObjects(%s, 'minimal')" % st2) is None, "a build that removes the signal: built")
st3 = "{ edgesToRemove = { 600 }, edgeObjectsToRemove = {}, edgesToAdd = {} }"
check(run("return C.strandedObjects(%s, 'minimal')" % st3) is None, "a removed segment with nothing on it: built")
check(run("ENV.MPFEVER_GSSTRAND = '0'; local r = C.strandedObjects(%s, 'minimal'); ENV = {}; return r" % st) is None,
      "MPFEVER_GSSTRAND=0: never refused, as before (the bug: the signal stranded)")
check(run("return C.strandedObjects({ removedSegments = { { entity = 500, comp = { objects = { { 9001, 1 } } } } } }, 'minimal')") is None,
      "a tool's native build (no edgesToRemove): not concerned")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
