"""Offline test of the lighter sync checks of 0.7.5: the same values as before, with less work.

On a big world (Test Lag Rp, 5 874 constructions, 7 267 segments) a check held the simulation 0.28 to 0.41 s; "conParams"
alone 0.28 s, most of it hashing the same texts of the constructions' parameters again character by character. 0.7.5 keeps
the hashes of texts and of numbers with decimals (QH), hashes a construction's file name once (fileAt: C.hashStr goes on from
the hash of a text's start), reads each node once per check (a node ends two segments or more) and makes no closure per
segment or node.

mpfever_refs.lua of this tree and as it was before (tests/data/mpfever_refs_before_0.7.5.lua) run through lupa with the same
mocked world and the game's own C.hashStr (from mpfever_common.lua):
  - "conParams", "constructions", "edges", "nodeConfigs" (and every other part measured) give the same values as before;
  - again at a second check (the caches full), after the world changed (a parameter, a node moved), and with
    MPFEVER_QHCACHE=0;
  - with a hash function that does not go on from a text's start (fileAt is then not used): the same values as before;
  - the halves (R.hashHalves): "conParams" + "conParams2" and "edges" + "edges2" add up to the whole part, a change shows in
    its own half, the rotation has five turns ("owners" with "edges2"), the launcher keeps "edges2" a real difference;
  - the switch, the cache's limit and the profile diagnostic are there.
Run: python tests/test_hashcache075.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
REFS = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_refs.lua")
COMMON = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_common.lua")
BRIDGE = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = { MPFEVER_HASHOFF = "vehicles,townBuildings,persons,stations,lines,names,vehicleState,edgeObjects,ages" }
os.getenv = function(k) return ENV[k] end
local function lanes(list)
  local t = {}
  for i, modes in ipairs(list) do local tm = {}; for _, j in ipairs(modes) do tm[j] = true end; t[i] = { transportModes = tm } end
  return t
end
local function mat(x, y) local m = {}; for i = 1, 16 do m[i] = 0 end; m[13] = x; m[14] = y; m[15] = 0; return m end
NODES = { [1] = { x = 0, y = 0, z = 0 }, [2] = { x = 100.4, y = 5, z = 1 }, [3] = { x = -20, y = 300.6, z = 2 }, [4] = { x = 55.5, y = -7.25, z = 0 } }
CONFIGS = {
  [1] = { laneConnections = { 1, 2, 3 }, crosswalks = { 1 }, trafficLightPreference = 0, trafficLightConfig = { trafficLightType = 2 }, doubleSlipSwitch = false },
  [2] = { laneConnections = {}, crosswalks = {}, trafficLightPreference = 1, doubleSlipSwitch = true },
  [3] = { laneConnections = { 9 }, crosswalks = { 1, 2 }, trafficLightPreference = 2, trafficLightConfig = { trafficLightType = 0 }, doubleSlipSwitch = false },
  [4] = { laneConnections = { 4, 5 }, crosswalks = {}, trafficLightPreference = 0, trafficLightConfig = {}, doubleSlipSwitch = false },
}
EDGES = {
  [10] = { node0 = 1, node1 = 2, roadTemplate = "town_new_small", roadStyle = 1, roadType = 0, type = 0, typeIndex = -1, distance = 100,
           edgeDecorations = { { 7, true }, { 3, false } }, laneConfigs = lanes({ { 1 }, { 1, 4 } }) },
  [11] = { node0 = 3, node1 = 1, roadTemplate = "tram", roadStyle = 2, roadType = 1, type = 0, typeIndex = -1, distance = 300,
           edgeDecorations = {}, laneConfigs = lanes({ { 1, 2 }, { 2 } }) },
  [12] = { node0 = 2, node1 = 3, roadTemplate = "x", type = 1, typeIndex = 4, distance = 50, laneConfigs = lanes({ { 3 } }) },
  [13] = { node0 = 2, node1 = 99, roadTemplate = "missing node", type = 0, typeIndex = -1, distance = 1, laneConfigs = {} },
  [14] = { node0 = 4, node1 = 2, roadTemplate = "town_large", roadStyle = 0, roadType = 0, type = 0, typeIndex = -1, distance = 44.75,
           edgeDecorations = { { 1, true } }, laneConfigs = lanes({ { 0, 15 }, { 1 } }) },
}
local mods = { ["station/rail/modules/platform_passenger.module"] = { metadata = { length = 40.5, era = "b" }, variant = 0 },
               ["station/rail/modules/main_building_1_era_b.module"] = { metadata = { length = 40.5, era = "b" }, variant = 2 } }
CONS = {
  [100] = { fileName = "station/rail/modular_station/modular_station.con", transf = mat(10.4, 20.6), params = { modules = mods, seed = 12345, paramX = 0.1, name = "Gare" } },
  [101] = { fileName = "industry/coal_mine.con", transf = mat(-500.5, 33), params = { seed = 7, level = 2.5, modules = { [3] = { variant = 1 } } } },
  [102] = { fileName = "industry/coal_mine.con", transf = mat(800, 900.25), params = { seed = 9, level = 2.5, nan = 0/0, huge = 1e300, neg = -3.75 } },
  [103] = { fileName = "street/depot/bus_depot.con", transf = mat(1, 2), params = "not a table" },
  [104] = { fileName = "", transf = mat(5, 5), params = {} },
  [105] = { fileName = "mpfever_asset/tree.con", transf = mat(6, 6), params = { a = 1 } },
  [106] = { fileName = "station/rail/modular_station/modular_station.con", transf = mat(3000, -3000), params = { modules = mods, seed = 54321, paramX = 0.1, deep = { { { { { { { { { { { { 1 } } } } } } } } } } } } } },
}
api = {
  type = { ComponentType = { BASE_EDGE = "edge", BASE_NODE = "node", TICK_EPOCH = "epoch", CONSTRUCTION = "con", TOWN_BUILDING = "tb", BASE_NODE_CONFIG = "nc" } },
  engine = {
    entityExists = function(e) if e == 666 then error("boom") end return EDGES[e] ~= nil or NODES[e] ~= nil or CONS[e] ~= nil end,
    getComponent = function(e, ct)
      if ct == "edge" then
        local c = EDGES[e]
        if c and c.roadTemplate == "x" then return setmetatable({}, { __index = function(_, k) if k == "edgeDecorations" then error("no") end return c[k] end }) end
        return c
      end
      if ct == "node" then return NODES[e] and { position = NODES[e] } end
      if ct == "con" then return CONS[e] end
      if ct == "nc" then return CONFIGS[e] end
      return nil
    end,
    forEachEntityWithComponent = function(fn, ct)
      if ct == "con" then local ids = {}; for e in pairs(CONS) do ids[#ids + 1] = e end; table.sort(ids); for _, e in ipairs(ids) do fn(e) end end
    end,
    system = { streetSystem = { getEdgeObject2EdgeMap = function() return {} end } },
  },
}
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def hashstr_src():
    src = open(COMMON, encoding="utf-8").read()
    m = re.search(r"^function C\.hashStr\(h, s\)\n.*?^end\n", src, re.S | re.M)
    return m.group(0) if m else None


def load(src, hs):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("C = {}\n" + hs + "\nHSTR = C.hashStr")
    L.execute("R = (function() " + src + " end)()")
    L.execute("R.allEdges = function() return { 10, 11, 12, 13, 14 } end\nR.allNodes = function() return { 1, 2, 3, 4 } end\nR.tickEpochsOn = function() return true end")
    # a hash function that does not go on from a text's start (its seed is ignored)
    L.execute("function DJB(seed, s) local h = 5381 for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end return h end")
    return L


PARTS = ["conParams", "constructions", "edges", "nodeConfigs"]


def parts(L, fn="HSTR"):
    return L.eval("(function() local p = R.contentHash(" + fn + ", tostring); local t = {}; "
                  "for k, v in pairs(p) do t[#t + 1] = k .. '=' .. tostring(v) end; table.sort(t); return table.concat(t, ' ; ') end)()")


def main():
    hs = hashstr_src()
    check("C.hashStr found in mpfever_common.lua", hs is not None)
    if not hs:
        return 1
    now = open(REFS, encoding="utf-8").read()
    old = open(os.path.join(HERE, "data", "mpfever_refs_before_0.7.5.lua"), encoding="utf-8").read()
    A, B = load(old, hs), load(now, hs)

    pa, pb = parts(A), parts(B)
    check("every part as before (first check)", pa == pb, f"\n  before {pa}\n  now    {pb}")
    for p in PARTS:
        check(f"  {p} measured", (p + "=") in pb and "ERR" not in pb.split(p + "=")[1].split(" ;")[0], pb)
    check("every part as before (second check, caches full)", parts(A) == parts(B))

    for change in ["CONS[100].params.paramX = 0.2", "CONS[101].params.modules[3].variant = 2",
                   "NODES[2] = { x = 101.6, y = 5, z = 1 }", "CONFIGS[3].crosswalks = { 1 }",
                   "EDGES[14].laneConfigs[1].transportModes[15] = nil", "CONS[107] = { fileName = 'industry/coal_mine.con', transf = { [13] = 1, [14] = 1, [15] = 0 }, params = { seed = 1 } }"]:
        before_b = parts(B)
        A.execute(change)
        B.execute(change)
        pa, pb = parts(A), parts(B)
        check(f"after {change}: as before", pa == pb, f"\n  before {pa}\n  now    {pb}")
        check(f"  and the change is seen", pb != before_b)

    ENV_OFF = "ENV.MPFEVER_QHCACHE = '0'"
    B.execute(ENV_OFF)
    check("MPFEVER_QHCACHE=0: as before", parts(A) == parts(B))
    B.execute("ENV.MPFEVER_QHCACHE = nil")

    pa, pb = parts(A, "DJB"), parts(B, "DJB")
    check("a hash function that does not go on from a text's start: as before", pa == pb, f"\n  before {pa}\n  now    {pb}")
    check("and back to C.hashStr: as before", parts(A) == parts(B))

    # the halves (R.hashHalves): "conParams" + "conParams2" and "edges" + "edges2" together are the whole part
    def nacc(L, name):
        v = L.eval("(function() local p = R.contentHash(HSTR, tostring); return p['" + name + "'] end)()")
        n, acc = str(v).split("/")
        return int(n), int(acc)
    whole_c, whole_e = nacc(B, "conParams"), nacc(B, "edges")
    B.execute("R.hashHalves = true")
    c0, c1, e0, e1 = nacc(B, "conParams"), nacc(B, "conParams2"), nacc(B, "edges"), nacc(B, "edges2")
    # (the two brush assets, counted without a text, are in both halves)
    check("halves: the constructions' two halves are the whole part", c0[0] + c1[0] == whole_c[0] + 2 and (c0[1] + c1[1]) % 4294967296 == whole_c[1] and c0[0] > 0 and c1[0] > 0,
          f"{c0} {c1} {whole_c}")
    # (a segment with a missing node is counted, without a text, in both halves)
    check("halves: the segments' two halves are the whole part", e0[0] + e1[0] == whole_e[0] + 1 and (e0[1] + e1[1]) % 4294967296 == whole_e[1] and e0[0] > 1 and e1[0] > 1,
          f"{e0} {e1} {whole_e}")
    B.execute("CONS[101].params.level = 3.5")
    c0b, c1b = nacc(B, "conParams"), nacc(B, "conParams2")
    half = int(B.eval("(function() return (math.floor(-500.5 + 0.5) + math.floor(33 + 0.5)) % 2 end)()"))
    check("halves: a change shows in its own half only", (c0b != c0 and c1b == c1) if half == 0 else (c1b != c1 and c0b == c0), f"{c0}->{c0b} {c1}->{c1b}")
    B.execute("R.hashHalves = nil")
    check("halves off: one part each, no second half", "conParams2" not in parts(B) and "edges2" not in parts(B))
    bridge0 = open(BRIDGE, encoding="utf-8").read()
    check("the rotation of five turns with the halves", 'or R.hashHalves and { { "conParams" }, { "edges" }, { "constructions", "nodeConfigs", "ages" }, { "conParams2" }, { "edges2", "owners" } }' in bridge0)
    check("the owners take their turn with edges2 (only with the halves)", "local skipOwners = R.hashSkip and R.hashSkip.owners" in bridge0 and "if not skipOwners then pcall(function()" in bridge0)
    check("MPFEVER_HASHHALVES=0: whole parts", 'R.hashHalves = os.getenv("MPFEVER_HASHHALVES") ~= "0"' in bridge0)
    launcher = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read()
    check("the launcher: edges2 is never a local measure, as edges", '"edges", "edges2", "ages"' in launcher)

    # the cache's limit: past 200 000 entries it is emptied at the next check
    B.execute("for i = 1, 3 do R.contentHash(HSTR, tostring) end")
    check("the cache's limit is in the code", "if QH.n > 200000 then QH.fn = nil end" in now)
    check("the switch MPFEVER_QHCACHE", 'QH.on = os.getenv("MPFEVER_QHCACHE") ~= "0"' in now)
    check("no closure per segment", "local t = (function()" not in now)
    check("no closure per node for its traffic light", "pcall(function() tl = nc.trafficLightConfig.trafficLightType end)" not in now)
    bridge = open(BRIDGE, encoding="utf-8").read()
    check("the profile diagnostic (MPFEVER_HASHPROF=1)", 'os.getenv("MPFEVER_HASHPROF") == "1"' in bridge and "function R.hashProfile(" in now)
    check("each check's costs in the log (MPFEVER_HASHCOSTLOG=1)", 'os.getenv("MPFEVER_HASHCOSTLOG") == "1"' in bridge)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
