"""Offline test of a construction put on a street with stops (issue #109, resynchronisation 3: a tram depot on a street with 2
stops, "2 edge object(s) of the construction (an airport's signs) not replayed: resynchronisation", 0.6.4).

The tool takes the street's stops away and re-creates them on the new pieces of that street; the engine's conversion of the
construction does not have them. G.conStopsOk, isConstructionSegment and replayNativeConstruction are taken from the real bridge
file and run through lupa (Lua 5.2) with a mocked engine. Cases:
  - G.conStopsOk: stops on new street segments of the build: yes; an airport's signs on its runways (the construction's own
    segments), an object on a segment the build does not add, an object without model: no; MPFEVER_CONSTOPS=0: no;
  - replayNativeConstruction, a tram depot whose 2 stops the conversion lacks: one dry run of the stops (G.eoDryRun), then the
    construction built in ONE proposal with the engine's 2 stops (matched by rank, eoByRank), no resynchronisation asked;
  - the stops' dry run built instead of refused: a resynchronisation, nothing more built;
  - its conversion with another number of stops: the construction without them, then the resynchronisation of before;
  - MPFEVER_CONSTOPS=0: no dry run of the stops, the resynchronisation of before;
  - an airport whose conversion has its signs: no dry run of stops, built with the conversion's own objects (as before).
Run: python tests/test_constops.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
local function copy(v) if type(v) ~= "table" then return v end local t = {} for k, x in pairs(v) do t[k] = copy(x) end return t end
QUEUE = {}            -- the commands sent, each { cmd, cb }
REBUILT = {}          -- the options of every C.rebuildNativeWithConstruction
FAILED, LOGS, DRY = {}, {}, 0
CONV_EO = 0           -- edge objects in the engine's conversion of the construction
STOP_EO = 4           -- edge objects in the engine's conversion of the stops' dry run (twice the build's)
STOPS_BUILT = false   -- the stops' dry run built instead of refused
local function list(n, tag) local t = {} for i = 1, n do t[i] = { tag = tag, i = i } end return t end
api = {
  type = { Context = { new = function() return {} end } },
  engine = {
    util = { getPlayer = function() return 7 end,
      proposal = { makeSegmentsRemoveProposal = function(ids) return { proposal = { removedSegments = list(#ids, "seg"), removedNodes = list(1, "node") } } end } },
    system = { streetSystem = { getEdgeObject2EdgeMap = function() return {} end } },
  },
  cmd = { makeWorldBuildProposalCmd = function(p, ctx, a, b) return { kind = p.kind or "build", p = p } end },
}
C = { ser = function(v) return v end, deser = copy, errors = {},
  rebuildProposal = function(m, opts) return { kind = "conversion", constructionsToAdd = { {} } } end,
  rebuildNativeWithConstruction = function(m, conv, rm, opts) REBUILT[#REBUILT + 1] = opts return { kind = "build" } end }
R = { translateIn = function() return {} end, allEdges = function() return {} end }
G = { bind = {}, waits = {}, refundInto = function() end, frames = 0 }
G.eoDryRun = function(m) DRY = DRY + 1 return { kind = "stops dry run" }, #m.proposal.edgeObjectsToAdd end
function log(s) LOGS[#LOGS + 1] = s end
function shortErr(e) return tostring(e) end
function replayFailed(a, why) FAILED[#FAILED + 1] = why end
function logRefusal() end
function toSim() end
function replayTwoStep() return true end
function replaySend(cmd, cb) QUEUE[#QUEUE + 1] = { cmd = cmd, cb = cb } end
-- (the engine answers the commands one after the other: the conversion and the stops' dry run refused, the build built)
function answerAll()
  local n = 0
  while #QUEUE > 0 and n < 10 do
    n = n + 1
    local q = table.remove(QUEUE, 1)
    local kind = q.cmd.kind
    if kind == "conversion" then
      q.cb({ proposal = { toAdd = { { params = { modules = {}, seed = 1 } } }, proposal = { edgeObjectsToAdd = list(CONV_EO, "con") } } }, false)
    elseif kind == "stops dry run" then
      q.cb({ proposal = { proposal = { edgeObjectsToAdd = list(STOP_EO, "stop") } } }, STOPS_BUILT)
    else
      BUILT = (BUILT or 0) + 1
      q.cb({ proposal = { toAdd = { {} }, proposal = { addedNodes = {}, removedNodes = {}, addedSegments = {}, removedSegments = {} } } }, true)
    end
  end
end
function hasConstructionSegments(m) return true end
'''

# a tram depot put on a street with 2 stops: two new pieces of street (-1, -2) carry the re-created stops, -3 is the depot's
# own tram track (its template in /constructions/)
SETUP = r'''
local function seg(e, tpl)
  return { entity = e, comp = { node0 = 10, node1 = -5, roadTemplate = tpl, position0 = { x = 0, y = 0, z = 0 }, position1 = { x = 1, y = 0, z = 0 },
    tangent0 = { x = 1, y = 0, z = 0 }, tangent1 = { x = 1, y = 0, z = 0 } } }
end
function depot()
  return { toAdd = { { fileName = "::/depots/road/tram_depot/tram_depot.con", params = {} } }, toRemove = {},
    proposal = { addedSegments = { seg(-1, "::/streets/standard/town_medium.street_template"), seg(-2, "::/streets/standard/town_medium.street_template"),
      seg(-3, "::/constructions/depot/tram.street_template") }, addedNodes = { { entity = -5 } },
      removedSegments = { { entity = 63658 }, { entity = 73298 } }, removedNodes = { { entity = 56292 } },
      edgeObjectsToAdd = { { model = "::/station/street/stop.mdl", segmentEntity = -1 }, { model = "::/station/street/stop.mdl", segmentEntity = -2 } },
      edgeObjectsToRemove = { 900, 901 } } }
end
function airport()
  local m = depot()
  m.toAdd[1].fileName = "::/airports/airport.con"
  m.proposal.addedSegments = { seg(-1, "::/street/airport/runway.street_template"), seg(-2, "::/street/airport/taxiway.street_template") }
  return m
end
function replay(m)
  QUEUE, REBUILT, FAILED, LOGS, DRY, BUILT = {}, {}, {}, {}, 0, 0
  C.errors = {}
  local r = replayNativeConstruction({ uid = "hschi#1:24", args = { m } })
  answerAll()
  local o = REBUILT[1] or {}
  local wo = type(o.withObjects) == "table" and #o.withObjects or 0
  local first = type(o.withObjects) == "table" and o.withObjects[1] and o.withObjects[1].tag or "-"
  return string.format("dry %d built %d objects %d %s rank %s failed %s", DRY, BUILT, wo, first, tostring(o.eoByRank == true),
    #FAILED > 0 and table.concat(FAILED, "|") or "none")
end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m_seg = re.search(r"^local function isConstructionSegment\(sg\)\n.*?^end\n", src, re.S | re.M)
    m_ok = re.search(r"^G\.conStopsOk = function\(m\)\n.*?^end\n", src, re.S | re.M)
    m_rep = re.search(r"^local function replayNativeConstruction\(a\)\n.*?^end\n", src, re.S | re.M)
    if not (m_seg and m_ok and m_rep):
        print("FAIL: isConstructionSegment, G.conStopsOk or replayNativeConstruction not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m_seg.group(0).replace("local function isConstructionSegment", "function isConstructionSegment", 1))
    L.execute(m_ok.group(0))
    L.execute(m_rep.group(0).replace("local function replayNativeConstruction", "function replayNativeConstruction", 1))
    L.execute(SETUP)
    lua_run = L.eval("function(code) local f = assert(load(code)) return f() end")

    def run(code):
        try:
            return lua_run(code)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    print("G.conStopsOk")
    check("stops on new pieces of the street: yes", run("return G.conStopsOk(depot())") is True)
    check("an airport's signs on its runways: no", run("return G.conStopsOk(airport())") is False)
    check("an object on a segment the build does not add: no",
          run("local m = depot(); m.proposal.edgeObjectsToAdd[2].segmentEntity = 4711; return G.conStopsOk(m)") is False)
    check("an object on the depot's own track: no",
          run("local m = depot(); m.proposal.edgeObjectsToAdd[2].segmentEntity = -3; return G.conStopsOk(m)") is False)
    check("an object without model: no",
          run("local m = depot(); m.proposal.edgeObjectsToAdd[1].model = nil; return G.conStopsOk(m)") is False)
    check("no edge object: no", run("local m = depot(); m.proposal.edgeObjectsToAdd = {}; return G.conStopsOk(m)") is False)
    check("MPFEVER_CONSTOPS=0: no",
          run('ENV = { MPFEVER_CONSTOPS = "0" }; local r = G.conStopsOk(depot()); ENV = {}; return r') is False)

    print("replayNativeConstruction")
    got = run("CONV_EO, STOP_EO, STOPS_BUILT = 0, 4, false; return replay(depot())")
    check("a tram depot on a street with 2 stops: one dry run of the stops, ONE build with the engine's 2 stops, no reload",
          got == "dry 1 built 1 objects 2 stop rank true failed none", got)
    got = run("CONV_EO, STOP_EO, STOPS_BUILT = 0, 4, true; return replay(depot())")
    check("the stops' dry run built instead of refused: a reload, nothing more built",
          got == "dry 1 built 0 objects 0 - rank false failed edge object dry run built", got)
    got = run("CONV_EO, STOP_EO, STOPS_BUILT = 0, 3, false; return replay(depot())")
    check("the stops' conversion with another number: without them, the reload of before",
          got.startswith("dry 1 built 1 objects 0 - rank false failed construction edge objects"), got)
    got = run('ENV = { MPFEVER_CONSTOPS = "0" }; CONV_EO, STOP_EO, STOPS_BUILT = 0, 4, false; local r = replay(depot()); ENV = {}; return r')
    check("MPFEVER_CONSTOPS=0: no dry run of the stops, the reload of before",
          got.startswith("dry 0 built 1 objects 0 - rank false failed construction edge objects"), got)
    got = run("CONV_EO, STOP_EO, STOPS_BUILT = 2, 4, false; return replay(airport())")
    check("an airport whose conversion has its signs: built with them, as before",
          got == "dry 0 built 1 objects 2 con rank false failed none", got)

    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
