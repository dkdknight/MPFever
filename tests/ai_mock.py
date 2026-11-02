"""A mocked game for the offline tests of the computer companies (tests/test_ai_*.py): mpfever_ai.lua loaded through lupa
(Lua 5.2) with the parts of the game's API and of the bridge's environment it reads, as plain Lua tables the tests fill in.

    from ai_mock import load
    L, M = load()            # L: the Lua runtime, M: the module (M.f its functions, M.p its pure rules)

The world (Lua globals): TIME (game time, ms), MONEY[ent], OWN[entity] = owner, LINES (line entities), STOPS[line] = { station
groups }, VEH (vehicle entities), VLINE[vehicle] = line, RUN[vehicle] = running costs a year, LBAL[line] = a line's balance over
two months (calculateBalance scales it to the window asked), USE[line] = seats used (0..1), WAIT[line] = cargo waiting at its
first stop, PROD[stockList] = produced a year, MOST[stockList] = most a year, COMP[entity][componentType] = any other component.
What the module does: ACTS (its commands, { fn, args, co }), SENT (its messages to the other games), BUILDS (its builds through
the bridge's deferredSend, with their Context), DRY (the dry runs asked, makeProposalData), LOG (its log lines).
The environment switches: ENV[name] = value (os.getenv reads it first).
"""
import os

import lupa.lua52 as lua52

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")

MOCK = r'''
ENV = {}
do
  local og = os.getenv
  os.getenv = function(k) local v = ENV[k] if v ~= nil then return v end return og(k) end
end
TIME = 1000000
MONEY, OWN, STOPS, VLINE, RUN, LBAL, USE, WAIT, PROD, MOST, COMP = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
LINES, VEH, CONS, INDS = {}, {}, {}, {}
ACTS, SENT, BUILDS, DRY, LOG = {}, {}, {}, {}, {}
DRYRESULT = nil     -- function(proposal, ctx) -> the ProposalData of a dry run
PURCHASE = {}       -- vehicle -> purchase time

local CT = setmetatable({}, { __index = function(t, k) return k end })

function comp(e, ct) return COMP[e] and COMP[e][ct] end
function setComp(e, ct, v) COMP[e] = COMP[e] or {}; COMP[e][ct] = v end

local function new(t) return function() local o = {} for k, v in pairs(t or {}) do o[k] = v end return o end end

api = {
  type = {
    ComponentType = CT,
    enum = { LandUseType = { RESIDENTIAL = 0, COMMERCIAL = 1, INDUSTRIAL = 2 }, TransportMode = { TRUCK = 4, BUS = 3 },
      StockListType = { InputStock = 0, OutputStock = 1 } },
    Context = { new = new() },
    SimpleProposal = { new = function() return { streetProposal = {}, constructionsToAdd = {} } end,
      ConstructionEntity = { new = new() } },
    SegmentAndEntity = { new = function() return { comp = {}, streetEdge = {} } end },
    NodeAndEntity = { new = function() return { comp = {} } end },
    SimpleStreetProposal = { EdgeObject = { new = new() } },
    Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
    Vec4f = { new = function(x, y, z, w) return { x, y, z, w } end },
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
    Mat4f = { new = function(a, b, c, d) return { a, b, c, d } end },
    Line = { new = function() return { stops = {}, vehicleInfo = { transportModes = {} } } end,
      Stop = { new = function() return { loadMode = 0, minWaitingTime = 0, maxWaitingTime = 0 } end } },
  },
  util = { getDefaultYearDuration = function() return 1461000 end, getDefaultMonthDuration = function() return 121750 end },
  res = {
    modelRep = { getAll = function() return { [11] = "::/vehicle/bus/old.mdl", [12] = "::/vehicle/truck/old.mdl" } end,
      get = function(id)
        local cap = { capacity = 20, cargoTypeSet = "any" }
        return { metadata = { availability = { yearFrom = 1900, yearTo = 0 }, cost = { price = id == 12 and 150000 or 120000 },
          transportVehicle = { compartments = { { loadConfigs = { { cargoEntry = cap } } } } } } }
      end },
    cargoTypeRep = { getName = function(id) return "cargo" .. tostring(id) end, hasCargoType = function(set, c) return set == "any" or (type(set) == "table" and set[c] == true) end,
      getAll = function() return { [0] = "passengers", [1] = "a", [2] = "b", [3] = "c", [4] = "d", [5] = "e" } end,
      get = function(id) return { category = "cat" .. tostring(id) } end },
    economyRep = { find = function() return 1 end, get = function() return { cargoCategories = TOWNCAT or {} } end },
    getBaseConfig = function() return { economyId = "temperate" } end,
  },
  cmd = {
    makeWorldBuildProposalCmd = function(p, ctx, ignore, player, dust) return { kind = "build", proposal = p, ctx = ctx } end,
  },
  engine = {
    getComponent = function(e, ct)
      if ct == "ACCOUNT" then return MONEY[e] and { balance = MONEY[e] } or nil end
      if ct == "NAME" then return { name = "E" .. tostring(e) } end
      if ct == "TRANSPORT_VEHICLE" then
        if VLINE[e] == nil then return nil end
        return { line = VLINE[e], depot = 900, transportVehicleConfig = { vehicles = { { purchaseTime = PURCHASE[e] or 0 } } } }
      end
      if ct == "LINE" then
        local s = {}
        for i, g in ipairs(STOPS[e] or {}) do s[i] = { stationGroup = g } end
        return { stops = s, vehicleInfo = { transportModes = {} } }
      end
      return comp(e, ct)
    end,
    util = {
      getWorld = function() return 1 end,
      finance = { calculateBalance = function(list, t0, t1)
        local s = 0
        for _, l in ipairs(list) do s = s + (LBAL[l] or 0) * (t1 - t0) / 240000 end
        return math.floor(s)
      end, getPlayersBalance = function(p) return MONEY[p] or 0 end },
      vehicle = { getRunningCost = function(v) return RUN[v] or 0 end },
      line = { getLineProblems = function() return {} end,
        getLineCapacityUsages = function(l) return USE[l] and { [1] = { used = USE[l] * 100, capacity = 100 } } or {} end },
      stock = {
        getCargoProducedPerYear = function(sl, c) return PROD[sl] or 0 end,
        getCargoMaxProductionPerYear = function(sl, c) return MOST[sl] or 0 end,
        getCargoTypeShippedPerYear = function() return 0 end,
      },
      pathfinding = { findPathNodeToNode = function() return { 1 } end },
      proposal = { makeProposalData = function(p, ctx) DRY[#DRY + 1] = { p = p, ctx = ctx } return DRYRESULT and DRYRESULT(p, ctx) or nil end },
      town = { getTownDistrictCenter = function(t, u) return CENTRE and CENTRE[t] or nil end },
      octree = { findTransportNetworkNodesInCircle = function() return { 1 } end },
    },
    system = {
      simEntityAtTerminalSystem = { getLineStopSimEntitiesCount = function(l) return WAIT[l] or 0 end },
      streetSystem = { getNode2SegmentMap = function() return SEGMAP or {} end },
      streetConnectorSystem = { getConstructionEntityForDepot = function(d) return DEPOTCON and DEPOTCON[d] or -1 end,
        getConstructionEntityForEdge = function() return -1 end },
      townBuildingSystem = { getTown2personCapacitiesMap = function() return TOWNCAP or {} end, getTown2BuildingMap = function() return TOWNBUILDINGS or {} end,
        getCargoSupplyAndLimit = function(t, u) return SUPPLY and SUPPLY[t] and SUPPLY[t][u] or {} end },
      catchmentAreaSystem = { getStationCatchables = function(st) if CATCHFAIL then error("no catchment") end return CATCH and CATCH[st] or {} end },
      stationSystem = { getStations = function() return {} end },
    },
  },
}

R = {
  entitiesWith = function(k)
    if k == "LINE" then return LINES end
    if k == "TRANSPORT_VEHICLE" then return VEH end
    if k == "CONSTRUCTION" then return CONS end
    if k == "INDUSTRY" then return INDS end
    if k == "TOWN" then return TOWNLIST or {} end
    return {}
  end,
  allEdges = function() return EDGES or {} end,
  ownerOf = function(e) return OWN[e] end,
  translateOut = function() end,
}

G = { AI = {}, AIT = {}, AIS = {}, frames = 100000, me = "host", oseq = 0, nativeQueue = {}, autoBuildSeq = 0, rev = {} }
E = {
  G = G, R = R, api = api, STEP = 200, BS = "/",
  C = { LANGCODE = "en", DIR = "", marshal = function(x) return x end, ser = function(x) return tostring(x) end,
    appendFile = function(path, line) end,
    line = function(kind, t) ACTS[#ACTS + 1] = t; return "" end,
    eco = function() return nil end, templateLanes = function() return { "lanes" } end, newOf = function() return {} end },
  CO = { byKey = function() return nil end, idOfEntity = function() return nil end, colorFree = function() return false end, PALETTE = {} },
  log = function(s) LOG[#LOG + 1] = s end,
  send = function(name, a) SENT[#SENT + 1] = { name = name, a = a } end,
  gameTime = function() return TIME end,
  stampFor = function(t) return t end,
  deferredSend = function(cmd, cb, proposal, still) BUILDS[#BUILDS + 1] = cmd; G.autoBuildSeq = G.autoBuildSeq + 1; LASTCB = cb; LASTSTILL = still end,
  nodePosition = function(n) return NODES and NODES[n] or nil end,
  groundZ = function(x, y, z) return z or 0 end,
  vec = function(v) return v end,
}

-- a company of the registry, a line with its stops and vehicles, a garage open to all near the origin
CO1 = { id = 2, ent = 700 }
function addLine(l, groups, nveh, opts)
  opts = opts or {}
  LINES[#LINES + 1] = l
  OWN[l] = opts.owner or CO1.ent
  STOPS[l] = groups
  LBAL[l] = opts.bal or 0
  USE[l] = opts.use
  WAIT[l] = opts.wait
  local vs = {}
  for k = 1, nveh do
    local v = l * 10 + k
    VEH[#VEH + 1] = v
    OWN[v] = opts.owner or CO1.ent
    VLINE[v] = l
    RUN[v] = opts.run or 120000
    PURCHASE[v] = opts.bought
    vs[#vs + 1] = v
  end
  return vs
end
function linesList()
  local out = {}
  for _, l in ipairs(LINES) do if OWN[l] == CO1.ent then out[#out + 1] = { e = l, groups = STOPS[l] } end end
  return out
end
function vehiclesList()
  local out = {}
  for _, v in ipairs(VEH) do if OWN[v] == CO1.ent then out[#out + 1] = { e = v, line = VLINE[v] or -1 } end end
  return out
end
function addGarage(con, depot, x, y)
  CONS[#CONS + 1] = con
  setComp(con, "CONSTRUCTION", { depots = { depot }, fileName = "::/depots/road/road_depot/road_depot.con", frozenEdges = { con + 1 },
    transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, 0, 1 }, stations = {}, subconstructions = {}, townBuildings = {} })
  setComp(depot, "VEHICLE_DEPOT", { outNodes = { 1 } })
  setComp(con + 1, "BASE_EDGE", { node0 = con + 2, node1 = con + 3 })
  SEGMAP = SEGMAP or {}
  SEGMAP[con + 2] = { 1, 2 }
  DEPOTCON = DEPOTCON or {}
  DEPOTCON[depot] = con
end
-- an industry as the module's industries() reads it (kept in its cache: no station to build here)
function addIndustry(e, t)
  t.e = e
  t.road = t.road or { group = e + 1, list = { { station = 0, terminal = 0, node = e + 2 } } }
  t.outputs = t.outputs or {}
  t.inputs = t.inputs or {}
  t.inputSets = t.inputSets or {}
  t.stockList = t.stockList or (e + 3)
  t.pos = t.pos or { x = 0, y = 0, z = 0 }
  INDCACHE[#INDCACHE + 1] = t
  return t
end
INDCACHE = {}
function useIndustries() G.AI.indCache = { frame = G.frames, list = INDCACHE } end
function acts(fn) local n = 0 for _, a in ipairs(ACTS) do if a.fn == fn then n = n + 1 end end return n end
function lastAct(fn) local r for _, a in ipairs(ACTS) do if a.fn == fn then r = a end end return r end
function logHas(s) for _, l in ipairs(LOG) do if tostring(l):find(s, 1, true) then return true end end return false end
'''


def load():
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    # (the common module's helpers the module calls, the real ones: C.keepSegmentLook, 0.6.9)
    common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read()
    import re
    m = re.search(r"^function C\.keepSegmentLook\(cc, c, rev\)\n.*?^end\n", common, re.S | re.M)
    if m:
        L.execute("do local C = E.C\n" + m.group(0) + "end")
    src = open(os.path.join(CONTENT, "mpfever_ai.lua"), encoding="utf-8").read()
    M = L.execute(src)
    L.globals().M = M
    return L, M


def checker():
    failures = []

    def check(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond:
            failures.append(what)
    return check, failures
