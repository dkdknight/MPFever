"""Offline test: a game script's build (Undo!, Town Transit Planner...) names the existing street by references, not by the
sending game's ids (0.7.17, issue #194; R.translateOut / the "eo" references in mpfever_refs.lua).

#194 (AMD, Sascha and keviK, 21:25): Undo! undid AMD's new bus stop with a script build "edgesToRemove {89792}", node0 35440,
edgeObjectsToRemove {6994}: AMD's ids. On keviK's and Sascha's games, whose ids had parted (#150), 89792 was another segment or
none: every form refused, 47 stations against 48, a resync.
mpfever_refs.lua is loaded whole through lupa for two games with the same street under other ids. Cases:
  - translateOut on A: edgesToRemove, nodesToRemove, nodeConfigsToRemove, edgeObjectsToRemove, constructionsToRemove, the new
    segments' node0/node1 and an edge object's edgeEntity become references; new ones (negative) are kept;
  - translateIn on B gives B's ids for all of them (segment 89792 -> 500, node 35440 -> 70, object 6994 -> 9001);
  - MPFEVER_GSMODIDS=0: A's raw ids, as before;
  - a tool's native build (proposal, not streetProposal) is translated as before.
Needs lupa (pip install lupa). Run: python tests/test_gsmodids0717.py
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

ARGS = '''{ n = 5, [1] = { constructionsToRemove = {}, streetProposal = {
  edgesToRemove = { 89792 }, nodesToRemove = {}, nodeConfigsToRemove = { 35440, 50121 }, edgeObjectsToRemove = { 6994 },
  edgesToAdd = { { entity = -1, comp = { node0 = 35440, node1 = 50121, type = 0 } } },
  edgeObjectsToAdd = { { edgeEntity = -1, left = true }, { edgeEntity = 89792 } },
  nodesToAdd = {}, nodeConfigsToAdd = {} } }, [2] = {}, [3] = false, [4] = true, [5] = true }'''


def ship(env=""):
    return A.eval('(function() ENV = {' + env + '} local m = ' + ARGS + ' R.translateOut("makeWorldBuildProposalCmd", m, {}) ENV = {} return ser(m) end)()')


text = ship()
check("__ref" in text and "89792" in text, "A: the street goes as references (with A's id inside)")
miss = B.eval('(function(t) M = assert(load("return " .. t))() return #R.translateIn(M, {}) end)')(text)
check(miss == 0, "B: every reference found", miss)
sp = B.eval("M[1].streetProposal")
check(sp.edgesToRemove[1] == 500, "B: segment 89792 -> 500", sp.edgesToRemove[1])
check(sp.nodeConfigsToRemove[1] == 70 and sp.nodeConfigsToRemove[2] == 71, "B: nodes 35440, 50121 -> 70, 71")
check(sp.edgeObjectsToRemove[1] == 9001, "B: stop 6994 -> 9001", sp.edgeObjectsToRemove[1])
check(sp.edgesToAdd[1].comp.node0 == 70 and sp.edgesToAdd[1].comp.node1 == 71 and sp.edgesToAdd[1].entity == -1,
      "B: the new segment's nodes found, its own number kept")
check(sp.edgeObjectsToAdd[1].edgeEntity == -1 and sp.edgeObjectsToAdd[2].edgeEntity == 500, "B: edge objects' segments")
raw = ship('MPFEVER_GSMODIDS = "0"')
check("__ref" not in raw and "89792" in raw, "MPFEVER_GSMODIDS=0: A's raw ids, as before")
nat = A.eval('''(function() local m = { n = 4, [1] = { proposal = { removedSegments = { { entity = 89792, comp = { node0 = 35440, node1 = 50121 } } } } } }
  R.translateOut("makeWorldBuildProposalCmd", m, {}) return type(m[1].proposal.removedSegments[1].entity) end)()''')
check(nat == "table", "a tool's native build: translated as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
