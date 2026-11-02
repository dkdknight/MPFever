"""Offline test of the sync checks' lighter computation (0.6.8): the same values as before, a lighter heaviest check.

On a big world the heaviest sync check held the simulation 0.26 s (a hitch every 30 s, 2026-11-01): the segments and their
ages in one group, and two new closures for every engine read. The reads now call the engine's functions through pcall
directly, the segments' readers are made once per check, and the segments are checked alone (their ages with the
constructions and the nodes).

mpfever_refs.lua of this tree and of the last release before the change (git) run through lupa with the same mocked world:
  - the "edges" and "ages" parts give the same values as before (decorations both sides, tram lanes, a swapped segment,
    a segment whose decorations cannot be read, a node that does not exist);
  - comp() answers as before for a missing entity, a failing read, a component;
  - the rotation: three groups, the segments alone; MPFEVER_HASHGROUPS=0: the groups of before.
Run: python tests/test_hashcost.py
"""
import os, re, subprocess, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
REFS = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_refs.lua")
BRIDGE = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
BEFORE = "697835f"   # main before the change (0.6.8's first commit)

MOCK = r'''
ENV = { MPFEVER_HASHOFF = "constructions,vehicles,townBuildings,persons,stations,lines,names,vehicleState,nodeConfigs,conParams,edgeObjects,extended" }
os.getenv = function(k) return ENV[k] end
local function lanes(list)
  local t = {}
  for i, modes in ipairs(list) do local tm = {}; for _, j in ipairs(modes) do tm[j] = true end; t[i] = { transportModes = tm } end
  return t
end
NODES = { [1] = { x = 0, y = 0, z = 0 }, [2] = { x = 100.4, y = 5, z = 1 }, [3] = { x = -20, y = 300.6, z = 2 } }
EDGES = {
  [10] = { node0 = 1, node1 = 2, roadTemplate = "town_new_small", roadStyle = 1, roadType = 0, type = 0, typeIndex = -1, distance = 100,
           edgeDecorations = { { 7, true }, { 3, false } }, laneConfigs = lanes({ { 1 }, { 1, 4 } }) },
  [11] = { node0 = 3, node1 = 1, roadTemplate = "tram", roadStyle = 2, roadType = 1, type = 0, typeIndex = -1, distance = 300,
           edgeDecorations = {}, laneConfigs = lanes({ { 1, 2 }, { 2 } }) },
  [12] = { node0 = 2, node1 = 3, roadTemplate = "x", type = 1, typeIndex = 4, distance = 50, laneConfigs = lanes({ { 3 } }) },
  [13] = { node0 = 2, node1 = 99, roadTemplate = "missing node", type = 0, typeIndex = -1, distance = 1, laneConfigs = {} },
}
EPOCH = { [10] = { time = 5, commandIndex = 1, subIndex = 0 }, [11] = { time = 9, commandIndex = 0, subIndex = 2 } }
api = {
  type = { ComponentType = { BASE_EDGE = "edge", BASE_NODE = "node", TICK_EPOCH = "epoch" } },
  engine = {
    entityExists = function(e) if e == 666 then error("boom") end return EDGES[e] ~= nil or NODES[e] ~= nil end,
    getComponent = function(e, ct)
      if ct == "edge" then
        local c = EDGES[e]
        if c and c.roadTemplate == "x" then return setmetatable({}, { __index = function(_, k) if k == "edgeDecorations" then error("no") end return c[k] end }) end
        return c
      end
      if ct == "node" then return NODES[e] and { position = NODES[e] } end
      if ct == "epoch" then return EPOCH[e] end
    end,
    forEachEntityWithComponent = function(fn, ct) end,
  },
}
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def load(src):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("R = (function() " + src + " end)()")
    L.execute("R.allEdges = function() return { 10, 11, 12, 13 } end\nR.allNodes = function() return { 1, 2, 3 } end\nR.tickEpochsOn = function() return true end")
    L.execute("function HS(seed, s) local h = 5381 for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end return h end")
    return L


def main():
    now = open(REFS, encoding="utf-8").read()
    try:
        old = subprocess.run(["git", "show", BEFORE + ":mod/mpfever_1/content/mpfever_refs.lua"], cwd=ROOT, capture_output=True, check=True).stdout.decode("utf-8")
    except Exception as e:
        print("git show failed (%s): test skipped" % e)
        return 0
    A, B = load(old), load(now)
    ha = A.eval("(function() local p = R.contentHash(HS, tostring) return (p.edges or '?') .. ' ' .. (p.ages or '?') end)()")
    hb = B.eval("(function() local p = R.contentHash(HS, tostring) return (p.edges or '?') .. ' ' .. (p.ages or '?') end)()")
    check("the segments' and ages' values are those of before", ha == hb and "?" not in hb, f"{ha} / {hb}")
    B.execute("EDGES[10].edgeDecorations[1][2] = false")
    hc = B.eval("(function() return R.contentHash(HS, tostring).edges end)()")
    check("and still tell a decoration on the other side", hc != hb.split(" ")[0])

    m = re.search(r"^local function comp\(e, name\)\n.*?^end\n", now, re.S | re.M)
    check("comp() found", m is not None)
    if m:
        C = lupa.LuaRuntime(unpack_returned_tuples=True)
        C.execute(MOCK)
        C.execute("local CT = function(n) return api.type.ComponentType[n] end\n" + m.group(0) + "\nCOMP = comp")
        check("comp(): a missing entity", C.eval("COMP(77, 'BASE_EDGE')") is None)
        check("comp(): a failing read", C.eval("COMP(666, 'BASE_EDGE')") is None)
        check("comp(): a negative id", C.eval("COMP(-1, 'BASE_EDGE')") is None)
        check("comp(): a component", C.eval("COMP(10, 'BASE_EDGE').roadTemplate") == "town_new_small")
        check("no closure made for the engine's reads", "pcall(function() return api.engine.entityExists(e) end)" not in now)

    bridge = open(BRIDGE, encoding="utf-8").read()
    check("the rotation: the segments alone", 'or { { "conParams" }, { "edges" }, { "constructions", "nodeConfigs", "ages" } }' in bridge)
    check("MPFEVER_HASHGROUPS=0: the groups of before", 'os.getenv("MPFEVER_HASHGROUPS") == "0" and { { "conParams" }, { "edges", "ages" }, { "constructions", "nodeConfigs" } }' in bridge)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
