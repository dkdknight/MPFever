"""The 0.6 game option "tenders" (mod/mpfever_1/content/mpfever_feat_tenders.lua), offline: two simulated games (the host's, in
French, and a client's, in English, whose entity ids differ) run the module's real code with the env of docs/FEATURES-0.6.md
(env.on, env.param, env.state, env.book, env.send, ...) over a mocked game API (towns, lines, passengers, cargo, industries).

Cases: the option off (no state, no event, no money, no file), the co-op mode, the host's tender and its resend, events from a
player who is not the host, duplicates, the counting of passengers (both ways, other towns, a line that does not serve both, a
bankrupt company, an entry without its system), of cargo to an industry (each leg of a chain) and to a town, the same state on
both games, the winner and its bonus (a subsidy, once), the tie rules, a computer company winning, a company gone, the
rhythm and the two tenders at most, expiry (and a host's look that came too early), a place gone (cancel), the history kept to
20, the option switched off and on again, a savegame reload (plain data, nothing announced again), the window's file, rows
and camera button, the chat notices in each game's language, the options' texts.
Integrated (stage 2): the module behind the real options host (mpfever_feat.lua) and the bridge's real hooks (extracted from
mpfever_bridge.script.lua: SIM.featBridge's SUBSIDY booking, the top of update, handleEvent's game events with M.GAME_EVENTS and
M.hearsNow, G.featGui's f_opts, G.featChat in each language, the window's file, G.featRequest, the autotest scenario H.tenders,
MPFEVER_FEAT=0), and the window's real U.featTabRows drawing the tab from that file.
Needs lupa (pip install lupa). Run: python tests/test_feat_tenders.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_PATH = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_tenders.lua")
SRC = open(SRC_PATH, encoding="utf-8").read()

# The mocked game (one per Lua runtime): its entity ids start at OFF, so that the two games' ids differ (game 2's entity of the
# host's Bville is its own Aville: the hint of an event must not be taken blindly).
HARNESS = r'''
TIME, MONTH, REAL = 0, 23400, 0
MODE = "separate"
ENVV = {}
LOG, BOOKS, SENT, CHAT, FILES, WRITES = {}, {}, {}, {}, {}, 0
BAL = {}
FOCUS = nil
os.getenv = function(k) return ENVV[k] end

CT = { TOWN = "TOWN", NAME = "NAME", BOUNDING_VOLUME = "BV", INDUSTRY = "IND", STOCK_LIST = "SL", PLAYER_OWNED = "PO",
  SIM_ENTITY_AT_VEHICLE = "SEAV", SIM_ENTITY_AT_TERMINAL = "SEAT", LINE = "LINE", STATION_GROUP = "SG", SIM_CARGO = "SC",
  SIM_PERSON = "SP", TOWN_BUILDING = "TB" }
COMP, NAMES, STATION_TOWN, CAPS, SUPPLY, DELIVERED, CONNECTED = {}, {}, {}, {}, {}, {}, {}
CARGO = { ["passengers.lua"] = 0, ["iron_ore.lua"] = 1, ["coal.lua"] = 2, ["logs.lua"] = 3, ["food.lua"] = 4 }
CARGO_NAME = {}
for n, id in pairs(CARGO) do CARGO_NAME[id] = n end
CARGO_LABEL = { [0] = "Passengers", "Iron ore", "Coal", "Logs", "Food" }

function add(e, t, c) COMP[t] = COMP[t] or {}; COMP[t][e] = c end
function bv(x, y) return { bbox = { min = { x = x - 100, y = y - 100 }, max = { x = x + 100, y = y + 100 } } } end

api = {
  type = { ComponentType = CT, Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end } },
  engine = {
    getComponent = function(e, t)
      if t == nil then error("Error decoding argument #3: The lua object can't be cast to desired type") end
      return COMP[t] and COMP[t][e] or nil
    end,
    -- (the engine's order is not the ids': backwards here)
    forEachEntityWithComponent = function(fn, t)
      local ks = {}
      for e in pairs(COMP[t] or {}) do ks[#ks + 1] = e end
      table.sort(ks, function(a, b) return a > b end)
      for _, e in ipairs(ks) do fn(e) end
    end,
    util = {
      getEntityName = function(e) return NAMES[e] end,
      town = { isLineStoppingInTown = function(l, town)
        local line = COMP.LINE[l]
        if not line then error("not a line") end
        for _, s in ipairs(line.stops) do
          local sg = COMP.SG[s.stationGroup]
          if sg and STATION_TOWN[sg.stations[1]] == town then return true end
        end
        return false
      end },
      stock = { getCargoTypeDeliveredPerYear = function(sl, c) return DELIVERED[sl .. ":" .. c] or 0 end },
    },
    system = {
      stationSystem = { getTown = function(s) return STATION_TOWN[s] end },
      townBuildingSystem = { getTown2personCapacitiesMap = function() return CAPS end,
        getCargoSupplyAndLimit = function(t) return SUPPLY[t] or {} end },
    },
  },
  res = { cargoTypeRep = { find = function(n) return CARGO[n] or -1 end, getName = function(id) return CARGO_NAME[id] end,
    get = function(id) return { name = CARGO_LABEL[id] } end } },
  gui = { camera = { focusPosition = function(p, d) FOCUS = { x = p.x, y = p.y, d = d } end } },
}

function ug_require(path)
  if path == "/game_mechanics/subventions/subvention_util.tl" then
    return { areTownsConnected = function(a, b) return (CONNECTED[a .. "|" .. b] or CONNECTED[b .. "|" .. a]) and 999 or nil end }
  elseif path == "::/gui/main/cargo_util.tl" then
    return { hasLineVehicleWithCapacity = function(l, c) return true end, getPassengerCargoTypeId = function() return 0 end }
  elseif path == "/game_mechanics/finance/finances_util.tl" then
    return { scaleWithInflation = function(x) return math.floor(x * 1.5) end }
  end
  error("module not found: " .. path)
end

TOWN, SGOF, LINE, STOCK, COENT = {}, {}, {}, {}, {}
SIMN = 0

local function industry(ie, sl, name, x, y, stock)
  add(ie, "IND", { stockList = sl }); add(sl, "SL", stock); NAMES[sl] = name; add(sl, "BV", bv(x, y))
end

function setup(off, host, me, myco, fr)
  OFF, HOST, ME, MYCO, FR = off, host, me, myco, fr
  -- towns: only Aville and Bville are 2 to 15 km apart
  local towns = { { "A", "Aville", 0, 0, { 1000, 500, 500 } }, { "B", "Bville", 6000, 0, { 800, 400, 300 } },
    { "C", "Cville", 40000, 0, { 300, 100, 100 } }, { "D", "Dville", 0, 30000, { 200, 50, 50 } } }
  for i, t in ipairs(towns) do
    local e = off + i
    TOWN[t[1]] = e
    add(e, "TOWN", {}); add(e, "BV", bv(t[3], t[4])); NAMES[e] = t[2]; CAPS[e] = t[5]
    local sg, s = off + 200 + i, off + 300 + i
    add(sg, "SG", { stations = { s } }); STATION_TOWN[s] = e; SGOF[t[1]] = sg
  end
  -- the companies: 1 the host's, 2 Bob's, 3 a computer company, 4 Carl's (bankrupt)
  for id = 1, 4 do COENT[id] = off + 900 + id end
  local lines = { { "L1", 2, { "A", "B" } }, { "L2", 3, { "A", "B", "C" } }, { "L3", 1, { "A", "C" } }, { "L4", 4, { "A", "B" } },
    { "L5", 2, { "C", "A" } }, { "L6", 1, { "A", "B" } } }
  for i, l in ipairs(lines) do
    local e = off + 100 + i
    LINE[l[1]] = e
    local stops = {}
    for k, t in ipairs(l[3]) do stops[k] = { stationGroup = SGOF[t] } end
    add(e, "LINE", { stops = stops }); add(e, "PO", { player = COENT[l[2]] })
  end
  -- a steel mill that needs iron ore and coal; an iron mine and a farm that produced, a forest that never did
  STOCK.mill, STOCK.mine, STOCK.farm, STOCK.forest = off + 61, off + 63, off + 65, off + 67
  industry(off + 60, off + 61, "Aville Steel Mill", 3000, 500, { stocks = { { cargoType = 1 }, { cargoType = 2 } },
    rules = { { input = { { 1, 1 } }, output = { [5] = 1 } } }, ruleDatas = { { applyHistory = {} } } })
  industry(off + 62, off + 63, "Cville Iron Mine", 39000, 1000, { stocks = {}, rules = { { input = {}, output = { [1] = 2 } } },
    ruleDatas = { { applyHistory = { 1 } } } })
  industry(off + 64, off + 65, "Dville Farm", 1000, 29000, { stocks = {}, rules = { { input = {}, output = { [4] = 1 } } },
    ruleDatas = { { applyHistory = { 1 } } } })
  industry(off + 66, off + 67, "Bville Forest", 7000, 1000, { stocks = {}, rules = { { input = {}, output = { [3] = 1 } } },
    ruleDatas = { { applyHistory = {} } } })
  -- town buildings: one of Bville (which needs food, gets some logs), one of Aville
  STOCK.tbB, STOCK.tbA = off + 701, off + 702
  add(off + 701, "TB", { town = TOWN.B }); add(off + 702, "TB", { town = TOWN.A })
  SUPPLY[TOWN.B] = { [4] = { 0, 30, 0 }, [3] = { 5, 30, 0 } }
  st = { opts = {}, co = { mode = "separate", list = {
    { id = 1, key = "host", name = "Host Co", color = 1, ent = COENT[1] },
    { id = 2, key = "bob", name = "Bob Co", color = 2, ent = COENT[2] },
    { id = 3, key = "ai:1", name = "Robot Rail", color = 7, ent = COENT[3] },
    { id = 4, key = "carl", name = "Carl Co", color = 3, ent = COENT[4], gone = "bankrupt" } } } }
end

-- the options as the options host reads them (st.opts), the defaults from the module's OPTIONS
local function default(id, pid)
  for _, o in ipairs(M.OPTIONS) do
    if o.id == id then for _, p in ipairs(o.params or {}) do if p.id == pid then return p.default end end end
  end
  return nil
end
local function on(id) return st.opts[id] == true end
local function param(id, pid) local v = st.opts[id .. "." .. pid]; if v == nil then return default(id, pid) end return v end

function simEnv()
  return {
    log = function(s) LOG[#LOG + 1] = s end, gameTime = function() return TIME end, STEP = 200,
    on = on, param = param,
    state = function(s) s.feat = s.feat or {}; s.feat.tenders = s.feat.tenders or {}; return s.feat.tenders end,
    mode = MODE, co = MODE == "separate" and st.co or nil,
    -- (the contract's list; the registry, env.co, tells which companies are gone)
    companies = function()
      local out = {}
      for _, c in ipairs(st.co.list) do out[#out + 1] = { id = c.id, ent = c.ent, name = c.name, ai = c.key:sub(1, 3) == "ai:", members = {} } end
      return out
    end,
    money = function(ent) return BAL[ent] or 0 end,
    book = function(ent, amount, cat) BAL[ent] = (BAL[ent] or 0) + amount; BOOKS[#BOOKS + 1] = { ent = ent, amount = amount, cat = cat } end,
    R = {}, every = function(n) return math.floor(TIME / 200) % n == 0 end, month = function() return MONTH end,
  }
end

function guiEnv()
  return {
    log = function(s) LOG[#LOG + 1] = s end, on = on, param = param, isHost = HOST, me = ME, myCo = MYCO,
    send = function(name, p) SENT[#SENT + 1] = { name = name, param = p } end,
    chat = function(t) CHAT[#CHAT + 1] = t end,
    write = function(file, lines) FILES[file] = lines; WRITES = WRITES + 1 end,
    realTime = function() return REAL end,
    T = function(fr, en) if FR then return fr end return en end,
  }
end

-- plain data only (what a savegame keeps): numbers (finite), strings, booleans, tables with string or number keys, each table
-- once (no cycle, nothing shared); keys sorted, so that two equal states give the same text
function ser(v, seen)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("a number that is not finite") end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  if t ~= "table" then error("not plain data: " .. t) end
  seen = seen or {}
  if seen[v] then error("a table twice (a cycle or a shared table)") end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do
    if type(k) ~= "string" and type(k) ~= "number" then error("a key of type " .. type(k)) end
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) if type(a) ~= type(b) then return type(a) == "number" end return a < b end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. ser(k, seen) .. "]=" .. ser(v[k], seen) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function deser(s) return assert(load("return " .. s))() end
function feat() return st.feat and ser(st.feat) or "nil" end
function S() return st.feat and st.feat.tenders end

function tick() return M.tick(st, simEnv()) end
function month() return M.month(st, simEnv()) end
function gui() return M.gui(st, guiEnv()) end
function apply(name, s, from)
  local p = deser(s)
  p.mpfFrom = from
  return M.event(st, name, p, simEnv())
end
function takeSent()
  local out = {}
  for i, x in ipairs(SENT) do out[i] = x.name .. "\t" .. ser(x.param) end
  SENT = {}
  return table.concat(out, "\n")
end

-- passengers at the end of their ride: { line, from town, to town, "cargo" for a cargo sim entity }
function paxParam(spec)
  local param = {}
  for _, x in ipairs(spec) do
    SIMN = SIMN + 1
    local sim = OFF + 5000 + SIMN
    local l = LINE[x[1]]
    local i0, i1
    for k, s in ipairs(COMP.LINE[l].stops) do
      if s.stationGroup == SGOF[x[2]] then i0 = k - 1 end
      if s.stationGroup == SGOF[x[3]] then i1 = k - 1 end
    end
    add(sim, "SEAV", { line = l, lineStop0 = i0, lineStop1 = i1 })
    if x[4] == "cargo" then add(sim, "SC", { cargoType = 1 }) else add(sim, "SP", {}) end
    param[#param + 1] = { vehicleEntity = OFF + 6000, lineEntity = l, simEntity = sim, basePrice = 10, distance = 5000 }
  end
  return param
end
function pax(spec, sys) return M.onGameEvent(st, sys, "OnCalcTicketPrice", paxParam(spec), simEnv(), "") end

-- cargo delivered: { line, cargo, stock list ("mill", "tbB"...) }
function cargoParam(spec)
  local param = {}
  for _, x in ipairs(spec) do
    SIMN = SIMN + 1
    local sim = OFF + 5000 + SIMN
    add(sim, "SC", { cargoType = CARGO[x[2]] })
    param[#param + 1] = { vehicleEntity = OFF + 6000, lineEntity = LINE[x[1]], simEntity = sim, stockListEntity = STOCK[x[3]],
      basePrice = 10, distance = 5000 }
  end
  return param
end
function cargo(spec, sys) return M.onGameEvent(st, sys, "OnCalcTicketPrice", cargoParam(spec), simEnv(), "") end

function balance(id) return BAL[COENT[id]] or 0 end
function prog(id, co) for _, t in ipairs(S().open) do if t.id == id then return t.prog[tostring(co)] or 0 end end return -1 end
function reached(id, co) for _, t in ipairs(S().open) do if t.id == id then return t.reached[tostring(co)] end end return -1 end
function logHas(s) for _, l in ipairs(LOG) do if l:find(s, 1, true) then return true end end return false end
function chatText() return table.concat(CHAT, "\n") end
function fileText() return FILES[M.FILE] and table.concat(FILES[M.FILE], "\n") or "" end
'''

failures = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        failures.append(what)


class Game:
    def __init__(self, off, host, me, myco, fr):
        self.L = lua52.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(HARNESS)
        self.M = self.L.execute(SRC)
        self.L.globals().M = self.M
        self.g = self.L.globals()
        self.g.setup(off, host, me, myco, fr)

    def run(self, code):
        return self.L.execute(code)


SYS_PAX, SYS_CARGO = "SimEntityAtVehicleSystem", "TransportVehicleSystem"


def lua_list(rows):
    """Python rows -> Lua table constructor text."""
    def item(x):
        if isinstance(x, (list, tuple)):
            return "{" + ",".join(item(y) for y in x) + "}"
        if isinstance(x, str):
            return '"' + x + '"'
        return str(x)
    return item(rows)


# ------------------------------------------------------------------------------------------------ integrated (the real hooks)
# The module behind the real options host (mpfever_feat.lua: its loader, env, dispatch) and the bridge's real hooks, extracted
# from mpfever_bridge.script.lua: SIM.featBridge (its book: a SUBSIDY entry), SIM.featTick / featEvent / featHearing /
# featGameEvent, the top of update (SIM.featOn, featHears, featText), handleEvent's branch of the game's own events, G.featBridge
# (its T, its files), G.featChat, G.featGui (f_opts from the host's game), G.featRequest and the autotest scenario H.tenders. The
# window's tab is drawn by the real U.featTabRows of mpfever_ui.script.lua.
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")


def read_content(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def extract(src, pattern, what):
    m = re.search(pattern, src, re.S | re.M)
    if not m:
        raise SystemExit(f"FAIL: {what} not found")
    return m.group(0)


BRIDGE = read_content("mpfever_bridge.script.lua")
BRIDGE_PARTS = [
    extract(BRIDGE, r"^SIM\.featBridge = function\(\)\n.*?^end\n", "SIM.featBridge"),
    extract(BRIDGE, r"^SIM\.featTick = function\(state\)\n.*?^end\n", "SIM.featTick"),
    extract(BRIDGE, r"^SIM\.featEvent = function\(st, name, param\)\n.*?^end\n", "SIM.featEvent"),
    extract(BRIDGE, r"^SIM\.featHearing = function\(text, st\)\n.*?^end\n", "SIM.featHearing"),
    extract(BRIDGE, r"^SIM\.featGameEvent = function\(state, src, id, name, param\)\n.*?^end\n", "SIM.featGameEvent"),
    extract(BRIDGE, r"^G\.featBridge = function\(\)\n.*?^end\n", "G.featBridge"),
    extract(BRIDGE, r"^G\.featChat = function\(text\)\n.*?^end\n", "G.featChat"),
    extract(BRIDGE, r"^G\.featGui = function\(st\)\n.*?^end\n", "G.featGui"),
    extract(BRIDGE, r"^G\.featRequest = function\(p\)\n.*?^end\n", "G.featRequest"),
    extract(BRIDGE, r"^H\.tenders = function\(from, p\)\n.*?^end\n", "H.tenders"),
    # (the top of update: whether an option is on, a module hears the game's events, and the options' text)
    "function updateTop()\n  local st0 = state:get()\n"
    + extract(BRIDGE, r"^\t\tSIM\.featOn = K\.FEAT .*?\n\t\tSIM\.featText = [^\n]*\n", "update: SIM.featOn ... SIM.featText")
    + "  if SIM.featOn then pcall(SIM.featTick, state) end\nend\n",
    # (handleEvent: the game's own events, every id but MPFever's)
    "function engineEvent(src, id, name, param)\n"
    + extract(BRIDGE, r"^\tif id ~= \"mpfever\" then\n.*?^\tend\n", "handleEvent: the game's own events")
    + "end\n",
]
FEAT_SRC = read_content("mpfever_feat.lua")

INTEG = r'''
K = { FEAT = true }
STEP, R, BS, NL, TAB = 200, {}, "/", "\n", "\t"
CO = { members = function(c) return {} end }
MONTHD = 5000
TIME = 23400 * MONTHD
api.util = { getDefaultMonthDuration = function() return MONTHD end }
api.engine.util.finance = { getPlayersBalance = function(e) return BAL[e] or 0 end }
api.engine.util.getCalendarDate = function(t) return { year = 1900, month = 1, day = 1 } end
api.type.JournalEntry = { new = function() return { category = {} } end, Type = { OTHER = 9, SUBSIDY = 7 } }
JOURNAL, DISK, OUT = {}, {}, {}
GETS, SETS = 0, 0
function coBook(ent, e) JOURNAL[#JOURNAL + 1] = { ent = ent, amount = e.amount, type = e.category.type, time = e.time }; BAL[ent] = (BAL[ent] or 0) + e.amount end
function log(s) LOG[#LOG + 1] = tostring(s) end
function gameTime() return TIME end
os.clock = function() return REAL end
C = { ROLE = HOST and "host" or "client", T = function(fr, en) if FR then return fr end return en end, DIR = "D",
  appendFile = function(path, text) DISK[path] = (DISK[path] or "") .. text return true end,
  IO = { open = function(path, mode)
    if mode == "wb" then
      local buf = {}
      return { write = function(self, s) buf[#buf + 1] = s end, close = function() DISK[path] = table.concat(buf) end }
    end
    if DISK[path] == nil then return nil end
    return { read = function() return DISK[path] end, close = function() end }
  end } }
C.feat = function() return F end
G = { frames = 1000, session = { started = true, resync = false }, connected = true, cmode = "separate", me = ME, myCo = MYCO, waits = {}, featOpts = "" }
G.coEvent = function(name, param) if G.session.resync then return false end OUT[#OUT + 1] = { name = name, param = ser(param) } end
SIM, H = {}, {}
AUTO = { running = false, results = {}, points = {} }
DONE = nil
function autoFinish() AUTO.running = false; DONE = table.concat(AUTO.results, "\n") end
state = { get = function() GETS = GETS + 1 return st end, set = function(self, t) SETS = SETS + 1; st = t end }
function gui(dt) REAL = REAL + (dt or 2); G.frames = G.frames + 120; G.featGui(st) end
function takeOut() local out = {} for i, x in ipairs(OUT) do out[i] = x.name .. "\t" .. x.param end OUT = {} return table.concat(out, "\n") end
-- an event every game applies (the bridge's executeActionOnce adds its sender; handleEvent saves the state after it)
function applyF(name, s, from, co) local p = deser(s); p.mpfFrom = from; p.mpfCo = co; SIM.featEvent(st, name, p); state:set(st) end
function runWaits()
  for _ = 1, 400 do
    G.frames = G.frames + 60
    local due = nil
    for i, w in ipairs(G.waits) do if w.at <= G.frames then due = i break end end
    if due then local w = table.remove(G.waits, due); w.fn() end
    if DONE then return end
  end
end
function chatText() return DISK["D/chat.txt"] or "" end
function tenders() return st.feat and st.feat.tenders end
'''


class IGame:
    def __init__(self, off, host, me, myco, fr):
        self.L = lua52.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(HARNESS)
        g = self.g = self.L.globals()
        g.setup(off, host, me, myco, fr)
        g.REAL = 0
        self.L.execute(INTEG)
        g.F = self.L.execute(FEAT_SRC)
        g.TSRC = SRC
        self.L.execute('F.loader = function(id) if id == "tenders" then return load(TSRC, "=tenders")() end return nil end; F.load(log); M = F.byId.tenders')
        for part in BRIDGE_PARTS:
            self.L.execute(part)

    def run(self, code):
        return self.L.execute(code)


def integrated():
    print("integrated: the options host, the bridge's hooks, the scenario and the window")
    h = IGame(0, True, "Host", 1, True)      # the host's game, in French
    c = IGame(1, False, "Bob", 2, False)     # Bob's game (company 2), in English, other entity ids
    games = [h, c]

    def deliver(sender=h, frm="Host", co=1):
        out = sender.g.takeOut()
        sent = [l.split("\t", 1) for l in out.split("\n") if l]
        for name, s in sent:
            for g in games:
                g.g.applyF(name, s, frm, co)
        return [n for n, _ in sent]

    def pax(g, rows, sys=SYS_PAX, name="OnCalcTicketPrice"):
        g.run(f'engineEvent("", "{sys}", "{name}", paxParam({lua_list(rows)}))')

    # every option off: nothing at all
    for g in games:
        g.run('updateTop()')
        gets = g.run('return GETS')
        pax(g, [["L1", "A", "B"]])
        g.run('gui(); gui()')
        check(g.run('return SIM.featOn') is False and g.run('return GETS') == gets and g.run('return st.feat == nil and #OUT == 0 and #JOURNAL == 0 and next(DISK) == nil'),
              "all off: no game event read, no state, no event, no money, no file")
    check(h.run('return F.wantsGameEvent("", "OnCalcTicketPrice")') is False, "all off: no module wants a game event")

    # the scenario switches the option on, as the host's lobby would
    h.run('ENVV.MPFEVER_TDGOAL = "2"; ENVV.MPFEVER_TDWAIT = "5"; H.tenders("Host", { role = "host" })')
    check(h.run('return AUTO.running and G.featOpts == "tenders=1;tenders.freq=3"'), "scenario (host): the session's options ask for the tenders")
    h.run('gui()')
    sent = deliver()
    check(sent == ["f_opts"], f"the host's game sends f_opts: {sent}")
    check(all(g.run('return st.optsText == "tenders=1;tenders.freq=3" and st.optsMode == "separate"') for g in games), "both games apply the options")
    for g in games:
        g.run('updateTop()')
    check(all(g.run('return SIM.featOn == true and SIM.featHears == false and SIM.featText == st.optsText') for g in games),
          "update: the option on, but no tender open: the game's events not heard (M.hearsNow)")
    for g in games:
        gets = g.run('return GETS')
        pax(g, [["L1", "A", "B"]])
        check(g.run('return GETS') == gets, "no tender open: a ticket price event does not even read the state")
    check(all(g.run('return tenders() ~= nil and tenders().month == 23400 and #tenders().open == 0') for g in games), "the simulation's tick keeps the month (env.every, env.month of the bridge)")

    # the host publishes tender 1
    c.run('gui()')
    check(c.run('return #OUT') == 0, "the client's game decides nothing")
    h.run('gui()')
    sent = deliver()
    check(sent == ["f_tenders_new"], f"the host's game publishes: {sent}")
    check(all(g.run('local t = tenders().open[1]; return tenders().seq == 1 and t.kind == "pax" and t.goal == 2 and t.a.name == "Aville" and t.b.name == "Bville"') for g in games),
          "tender 1 open on both games: passengers Aville - Bville, goal 2 (MPFEVER_TDGOAL)")
    check(h.g.logHas("feat tenders: the host proposes tender 1"), "logged: the host's proposal")
    for g in games:
        g.run('updateTop()')
    check(all(g.run('return SIM.featHears == true') for g in games), "a tender open: the next step's update hears the game's events")
    for g in games:
        g.run('gui()')
    check("Nouvel appel d'offres n°1" in h.g.chatText() and "New tender #1: Carry 2 passengers between Aville and Bville" in c.g.chatText(),
          "the chat notice through G.featChat, in each game's language (env.T = the bridge's C.T)")
    check(all(g.run('return DISK["D/feat_tenders_list.txt"] ~= nil') for g in games) and "open\t1\tpax\t2\t" in c.run('return DISK["D/feat_tenders_list.txt"]'),
          "the window's file feat_tenders_list.txt (env.write(\"list\")) on both games")

    # counting through the bridge's handleEvent branch
    for g in games:
        gets = g.run('return GETS')
        pax(g, [["L1", "A", "B"]], SYS_PAX, "OnStartedLineUsage")
        check(g.run('return GETS') == gets, "another game event (not in M.GAME_EVENTS): the state is not even read")
        pax(g, [["L1", "A", "B"], ["L2", "A", "C"]])
        check(g.run('return GETS') == gets + 1, "the ticket price event: the state read once")
        pax(g, [["L1", "B", "A"], ["L4", "A", "B"]])
    check(all(g.run('local t = tenders().open[1]; return t.prog["2"] == 2 and t.prog["3"] == nil and t.prog["4"] == nil and t.reached["2"] == TIME') for g in games),
          "counted on both games: Bob's company 2 (both ways), not A-C, not the bankrupt company")
    check(c.g.logHas("feat tenders: ticket price event id SimEntityAtVehicleSystem") and c.g.logHas("feat tenders: tender 1 (pax) counts for company 2")
          and c.g.logHas("feat tenders: company 2 reached the goal of tender 1"), "logged: the engine's event, the first count, the goal reached")
    check(all(g.run('local n = 0 for _ in pairs(SIM.featB) do n = n + 1 end return n > 0') for g in games), "the env made of SIM.featBridge")

    # the winner and the bonus, a subsidy
    h.run('gui()')
    sent = deliver()
    check(sent == ["f_tenders_win"], f"the host names the winner: {sent}")
    prize = h.run('return tenders().done[1].prize')
    for g, name in ((h, "host"), (c, "client")):
        got = g.run('local j = JOURNAL[1]; return #JOURNAL, j and j.ent == COENT[2], j and j.amount, j and j.type, j and j.time')
        check(tuple(got) == (1, True, prize, 7, -1), f"{name}: one journal entry to Bob's company, the bonus, type SUBSIDY, time -1: {got}")
    check(h.g.logHas("booked to player entity 902 (subsidy)") and h.g.logHas("feat tenders: bonus " + str(prize)), "logged: the bonus booked as a subsidy")
    for g in games:
        g.run('gui()')
    check("Bob Co wins tender #1" in c.g.chatText() and "Bob Co remporte l'appel d'offres n°1" in h.g.chatText(), "the win told on both games")
    check(h.run('return F.byId.tenders.signature(st)') == c.run('return F.byId.tenders.signature(st)') == "1,1:won:2", "the same signature on both games")

    # the scenario's results
    h.run('runWaits()')
    res = h.run('return DONE') or ""
    check("tender 1 published after" in res and "signature 1,1:won:2" in res and "window file feat_tenders_list.txt:" in res
          and "MISSING" not in res and "chat notice of a tender: yes" in res, "scenario (host): its results\n      " + res.replace("\n", "\n      "))
    c.run('H.tenders("Host", { role = "client" })')
    res = c.run('return DONE') or ""
    check("signature 1,1:won:2" in res and "chat notice of a tender: yes" in res and "options 'tenders=1;tenders.freq=3' (separate)" in res,
          "scenario (client): what its game holds\n      " + res.replace("\n", "\n      "))
    co = IGame(2, True, "Host", 1, False)
    co.run('G.cmode = "shared"; H.tenders("Host", { role = "host" })')
    check("one company per player" in (co.run('return DONE') or ""), "scenario: the co-op says it needs one company per player")

    # the window's request through the bridge
    c.run('FOCUS = nil; G.featRequest({ m = "tenders", kind = "focus", payload = "1:b" })')
    check(c.run('return FOCUS and FOCUS.x == 6000 and FOCUS.y == 0'), "a request of the window (feat_req) moves the camera to Bville")

    # MPFEVER_FEAT=0: nothing, even with the options in the state
    for g in games:
        g.run('K.FEAT = false; updateTop()')
        gets = g.run('return GETS')
        pax(g, [["L1", "A", "B"]])
        check(g.run('return SIM.featOn == false and GETS') == gets, "MPFEVER_FEAT=0: the game's events never reach the modules")

    # the window: the real U.featTabRows over the client's file
    ui = read_content("mpfever_ui.script.lua")
    win_src = extract(ui, r"^U\.featOff = .*?^U\.featTabRows = function\(K, st, key\)\n.*?^end\n", "the window's game options")
    W = lua52.LuaRuntime(unpack_returned_tuples=True)
    W.globals().FILEDATA = W.table_from({"D/feat_tenders_list.txt": c.run('return DISK["D/feat_tenders_list.txt"]')})
    W.globals().TSRC = SRC
    W.execute(r'''
LOGS = {}
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function T(fr, en) return en end
U = { isHost = function(st) return st and st.host == true end, winChanged = function() end }
LINES = {}
function sendLine(kind, p) LINES[#LINES + 1] = kind .. " " .. tostring(p.m) .. " " .. tostring(p.kind) .. " " .. tostring(p.payload) end
function money(n) return tostring(n) end
C = { DIR = "D", BS = "/", NL = "\n", CR = "\r", Tf = function(fr, en) return en end,
  IO = { open = function(path) local s = FILEDATA[path] if not s then return nil end
    return { read = function() return s end, close = function() end } end } }
os.getenv = function() return nil end
FOCUS = nil
api = { cmd = { sendCommand = function() end, makeScriptingSendEventCmd = function() return {} end },
  type = { Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end } },
  gui = { camera = { focusPosition = function(p, d) FOCUS = { x = p.x, y = p.y, d = d } end } } }
K = { TEXT_W = 556, ICON_SETTINGS = "i" }
function K.text(t, class, cls, w) return { kind = "text", t = tostring(t), cls = cls } end
function K.muted(t, w) return { kind = "muted", t = tostring(t) } end
function K.section(icon, t) return { kind = "section", t = t } end
function K.gap() return { kind = "gap" } end
function K.row(c) return { kind = "row", c = c } end
function K.col(c) return { kind = "col", c = c } end
function K.btn(label, tip, fn, primary, enabled) return { kind = "btn", t = label, fn = fn } end
''')
    F2 = W.execute(FEAT_SRC)
    W.globals().F = F2
    W.execute('F.loader = function(id) if id == "tenders" then return load(TSRC, "=tenders")() end return nil end; C.feat = function() return F end')
    W.execute(win_src)
    shown = W.execute(r'''
local stS = { mode = "separate", opts = "tenders=1;tenders.freq=3" }
local tabs = U.featTabs(stS)
local rows = U.featTabRows(K, stS, "f_tenders")
local out = {}
for _, r in ipairs(rows) do out[#out + 1] = r.kind .. ":" .. tostring(r.t) .. (r.cls and ("[" .. r.cls .. "]") or "") end
SHOWN = rows
return #tabs .. "|" .. tostring(tabs[1] and tabs[1].key) .. "\n" .. table.concat(out, "\n")
''')
    check(shown.startswith("1|f_tenders"), "window: the Tenders tab while the option is on")
    check("muted:The first company to reach the goal" in shown and "section:Tender #1" not in shown, "window: the rule; tender 1 closed, no card")
    check("section:Closed" in shown and "muted:#1, Carry 2 passengers between Aville and Bville, without a transfer: won by Bob Co (you) ($" in shown
          and "section:Tenders won" in shown and "text:Bob Co (you): 1" in shown, "window: the history and the tenders won, drawn with u.add\n      " + shown.replace("\n", "\n      "))
    check("window: the tab failed" not in "\n".join(W.globals().LOGS.values()), "window: the tab drew without an error")
    # a card with a Show button (a tender open in the file)
    W.globals().FILEDATA["D/feat_tenders_list.txt"] = "v\t1\nmonth\t23400\nme\t2\nco\t2\tBob Co\t2\t0\t0\nopen\t5\tpax\t10\t12\t300000\tAville\tBville\t\t0\t0\t6000\t0\nprog\t5\t2\t4"
    shown = W.execute(r'''
local rows = U.featTabRows(K, { mode = "separate", opts = "tenders=1" }, "f_tenders")
local out, btn = {}, nil
for _, r in ipairs(rows) do
  out[#out + 1] = r.kind .. ":" .. tostring(r.t) .. (r.cls and ("[" .. r.cls .. "]") or "")
  if r.kind == "btn" and r.t == "Show Bville" then btn = r end
end
if btn then btn.fn() end
return table.concat(out, "\n")
''')
    check("section:Tender #5" in shown and "text:Bob Co (you): 4 / 10  (40 %)[success]" in shown and "btn:Show Aville" in shown,
          "window: a card, this player's progress in green, Show buttons\n      " + shown.replace("\n", "\n      "))
    check(W.execute('return FOCUS and FOCUS.x == 6000 and FOCUS.y == 0') and len(W.globals().LINES) == 0, "window: Show moves the window's own camera")


def main():
    print("the module")
    bare = lua52.LuaRuntime(unpack_returned_tuples=True)
    M0 = bare.execute(SRC)
    check(M0.ID == "tenders", "it loads without the game's API (the lobby and the tests require it)")
    o = M0.OPTIONS[1]
    check(o.id == "tenders" and o.modes == "separate" and len(list(M0.OPTIONS.values())) == 1, "one option, \"tenders\", in the separate mode only (B3)")
    params = {p.id: p for p in o.params.values()}
    check(set(params) == {"freq", "prize"}, "its parameters: the frequency and the bonus level (B5)")
    T_fr = bare.eval("function(fr, en) return fr end")
    T_en = bare.eval("function(fr, en) return en end")
    for p in params.values():
        vals = list(p["values"].values())   # (p.values would be the lupa table's own method)
        check(p.default in vals, f"{p.id}: its default {p.default} is one of its values {vals}")
        check(all(p.show(v, T_fr) and p.show(v, T_en) and p.show(v, T_fr) != p.show(v, T_en) for v in vals if v != 100),
              f"{p.id}: every value has a French and an English label")
    check(all(isinstance(o.title[i], str) and isinstance(o.desc[i], str) for i in (1, 2)), "its title and description in French and English")
    bad = []
    for k, v in M0.TEXTS.items():
        if not (isinstance(v[1], str) and isinstance(v[2], str)) or v[1].count("%s") != v[2].count("%s"):
            bad.append(k)
    check(not bad, "every text in French and English, with the same %s in both" + (f": {bad}" if bad else ""))
    events = set(M0.EVENTS.keys())
    check(events and all(e.startswith("f_tenders") for e in events), f"its events start with f_tenders: {sorted(events)}")
    code = re.sub(r"(?m)--.*$", "", SRC)
    check(not re.search(r"math\.random|os\.clock|os\.time|io\.open|io\.lines", code), "no random, clock or file in the module")
    # (0.9.2: MPFEVER_TENDERLINES, the switch of W.connected's lines on build 40444, read by the host's choice only)
    check(sorted(re.findall(r"os\.getenv\(\"(\w+)\"\)", code)) == ["MPFEVER_TDGOAL", "MPFEVER_TENDERLINES"], "os.getenv only for the host's test goal and its town test's switch")

    g1 = Game(0, True, "Host", 1, True)       # the host's game, in French
    g2 = Game(1, False, "Bob", 2, False)      # a client's game (Bob, company 2), in English, other entity ids
    games = [g1, g2]

    def both(code):
        return [g.run(code) for g in games]

    def same(what):
        a, b = g1.g.feat(), g2.g.feat()
        check(a == b, f"the same state on both games: {what}")

    def deliver(sender=g1, frm="Host"):
        """the events sent by a game's GUI half, applied by both games at the same step"""
        out = sender.g.takeSent()
        sent = [l.split("\t", 1) for l in out.split("\n") if l]
        for name, s in sent:
            for g in games:
                g.g.apply(name, s, frm)
        return sent

    def host_event(name, lua_param, frm="Host"):
        for g in games:
            g.run(f'apply("{name}", ser({lua_param}), "{frm}")')

    # ------------------------------------------------------------------------------------------------ off
    print("the option off: nothing at all")
    for g in games:
        g.run('tick(); month()')
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B"]])), SYS_PAX)
        g.g.cargo(g.L.eval(lua_list([["L5", "iron_ore.lua", "mill"]])), SYS_CARGO)
        g.run('apply("f_tenders_new", ser({ id = 1, kind = "town", a = { name = "Bville", x = 6000, y = 0 }, cargo = "food.lua", goal = 5, deadline = MONTH + 10, prize = 10 }), "Host")')
        for r in (1, 20, 40):
            g.run(f'REAL = {r}; gui()')
    check(all(g.run('return st.feat == nil') for g in games), "no state")
    check(all(g.run('return #SENT == 0 and #BOOKS == 0 and #CHAT == 0 and WRITES == 0') for g in games), "no event, no money, no notice, no file")
    check(g1.g.logHas("ignored: the option is off"), "a late event of the host is only logged")

    print("the co-op mode: nothing at all")
    for g in games:
        g.run('st.opts.tenders = true; MODE = "shared"; st.co.mode = "shared"; tick(); month()')
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B"]])), SYS_PAX)
        g.run('apply("f_tenders_new", ser({ id = 1, kind = "town", a = { name = "Bville", x = 6000, y = 0 }, cargo = "food.lua", goal = 5, deadline = MONTH + 10, prize = 10 }), "Host"); REAL = 60; gui()')
    check(all(g.run('return st.feat == nil and #SENT == 0 and #BOOKS == 0 and WRITES == 0') for g in games), "no state, no event, no money, no file")
    both('MODE = "separate"; st.co.mode = "separate"')

    # ------------------------------------------------------------------------------------------------ the first tender
    print("the option on: the host publishes")
    both('REAL = 70; gui()')
    check(all(g.run('return st.feat == nil and #SENT == 0') for g in games), "no state before the simulation's first look at the month: nothing sent")
    both('TIME = 0; tick()')
    check(all(g.run('return S() ~= nil and S().month == 23400 and #S().open == 0') for g in games), "the simulation keeps the month in the state")
    pick = g1.run('local p = M.pick.pax(S(), M.rng(5), 23400); return p.goal, p.deadline, p.a.name, p.b.name')
    check(tuple(pick) == (440, 23424, "Aville", "Bville"), f"passengers: the two towns 2 to 15 km apart, the goal from their size, 18 months + 1 per km: {pick}")
    g1.run('ENVV.MPFEVER_TDGOAL = "6"')
    first_look = [g.run('return ser(st)') for g in games]
    g2.run('REAL = 80; gui()')
    check(g2.run('return #SENT == 0') and "month\t23400" in g2.g.fileText(), "a client decides nothing; its window's file is written")
    g1.run('REAL = 80; gui()')
    check([g.run('return ser(st)') for g in games] == first_look, "the GUI half reads the state only (its first look, the host's decision)")
    n_sent, first = g1.run('return #SENT, SENT[1] and SENT[1].name')
    t1 = first == "f_tenders_new" and g1.run('local p = SENT[1].param; return p.id, p.kind, p.a.name, p.b.name, p.goal, p.deadline, p.prize, p.a.e, p.b.e')
    check(n_sent == 1 and t1 and t1[:6] == (1, "pax", "Aville", "Bville", 6, 23424), f"the host sends tender 1, passengers Aville - Bville (MPFEVER_TDGOAL=6): {t1}")
    check(t1 and t1[6] > 0 and t1[6] % 10000 == 0 and t1[7] == 1 and t1[8] == 2, f"its bonus (inflation, rounded) and the host's entities as hints: {t1 and t1[6:]}")
    prize1 = t1[6]
    g1.run('REAL = 81; gui()')
    check(g1.run('return #SENT') == 1, "not sent twice while the state did not take it")
    deliver()
    check(all(g.run('return S().seq == 1 and #S().open == 1 and S().next == 23406 and S().open[1].at == 23400') for g in games), "both games opened it; the next one in 6 months (the default)")
    same("tender 1 open")
    g1.run('REAL = 100; gui()')
    check(g1.run('return #SENT') == 0 and g1.run('return #M._g.pending') == 0, "taken: no resend, nothing pending")

    print("refusals")
    host_event("f_tenders_new", '{ id = 1, kind = "town", a = { name = "Bville", x = 6000, y = 0 }, cargo = "food.lua", goal = 5, deadline = MONTH + 10, prize = 10 }')
    check(all(g.run('return #S().open == 1 and S().open[1].kind == "pax"') for g in games) and g2.g.logHas("the last one published is 1"), "the same tender twice: refused")
    host_event("f_tenders_win", '{ id = 1, co = 2 }', "Bob#1")
    check(all(g.run('return #S().open == 1 and #BOOKS == 0') for g in games) and g2.g.logHas("only the host decides"), "a win sent by a player who is not the host: refused, no money")
    host_event("f_tenders_new", '{ id = 2, kind = "pax", a = { name = "Aville", x = 0, y = 0 }, b = { name = "Aville", x = 0, y = 0 }, goal = 5, deadline = MONTH + 10, prize = 10 }')
    check(all(g.run('return #S().open == 1 and S().seq == 1') for g in games), "a tender between a town and itself: refused")
    host_event("f_tenders_new", '{ id = 2, kind = "ind", a = { name = "Aville Steel Mill", x = 3000, y = 500 }, goal = 5, deadline = MONTH - 1, prize = 10 }')
    check(all(g.run('return #S().open == 1 and S().seq == 1') for g in games), "a tender without its cargo, or already past its date: refused")

    print("notices in each game's language")
    both('REAL = 101; gui()')
    check("New tender #1: Carry 6 passengers between Aville and Bville, without a transfer, within 24 months" in g2.g.chatText(), "the client tells it in English: " + g2.g.chatText())
    check("Nouvel appel d'offres n°1 : Transporter 6 voyageurs entre Aville et Bville" in g1.g.chatText(), "the host's game in French: " + g1.g.chatText())
    both('REAL = 102; gui()')
    check(all(g.run('return #CHAT') == 1 for g in games), "told once")

    # ------------------------------------------------------------------------------------------------ counting
    print("passengers counted")
    for g in games:
        g.run('TIME = 1000')
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B"], ["L1", "A", "B"], ["L1", "B", "A"], ["L2", "A", "B"], ["L2", "A", "C"],
                                    ["L3", "A", "C"], ["L4", "A", "B"]])), SYS_PAX)
        # (an entry without the engine's system: a person counts, a cargo sim entity does not)
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B", "cargo"], ["L1", "B", "A"]])), None)
        g.g.cargo(g.L.eval(lua_list([["L1", "iron_ore.lua", "mill"]])), SYS_CARGO)
    for g, name in ((g1, "host"), (g2, "client")):
        got = g.run('return prog(1, 2), prog(1, 3), prog(1, 1), prog(1, 4)')
        check(tuple(got) == (4, 1, 0, 0), f"{name}: Bob 4 (both ways), the computer company 1, not A-C, not a line missing B, not the bankrupt company: {got}")
    same("after the first passengers")
    check(all(g.run('return next(S().open[1].reached) == nil') for g in games), "nobody at the goal yet")

    print("a savegame reload")
    state_text = g1.g.feat()
    g1b = Game(0, True, "Host", 1, True)
    ok_plain = True
    try:
        g1b.L.globals().ARG = g1.run('return ser(st)')
    except Exception as e:  # noqa: BLE001 (any error of ser: not plain data)
        ok_plain = False
        print("    " + str(e))
    check(ok_plain, "the state is plain data (no function, no userdata, no cycle, nothing shared)")
    g1b.run('st = deser(ARG); REAL = 500; gui()')
    check(g1b.g.feat() == state_text and g1b.run('return #CHAT') == 0, "reloaded: the same state, nothing announced again")
    for g in (g1, g2, g1b):
        g.run('TIME = 1500')
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B"]])), SYS_PAX)
    check(g1b.g.feat() == g1.g.feat() == g2.g.feat(), "the reloaded game finds the towns again and counts the same")
    g1b.run('REAL = 520; gui()')
    check(g1b.run('return #SENT') == 0, "nobody at the goal: the reloaded host sends nothing")

    print("the winner")
    for g in games:
        g.run('TIME = 2000')
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B"]])), SYS_PAX)
        g.run('TIME = 2200')
        g.g.pax(g.L.eval(lua_list([["L2", "B", "A"]] * 5)), SYS_PAX)
    check(all(tuple(g.run('return prog(1, 2), reached(1, 2), prog(1, 3), reached(1, 3)')) == (6, 2000, 6, 2200) for g in games),
          "Bob reached 6 at 2000, the computer company at 2200, on both games")
    same("both at the goal")
    before = [g.run('return ser(st)') for g in games]
    g2.run('REAL = 200; gui()')
    check(g2.run('return #SENT') == 0, "the client's game does not decide")
    g1.run('REAL = 200; gui()')
    check(g1.run('return #SENT == 1 and SENT[1].name == "f_tenders_win" and SENT[1].param.id == 1 and SENT[1].param.co == 2'), "the host names Bob's company, the first at the goal")
    check([g.run('return ser(st)') for g in games] == before, "the GUI half leaves the state as it was")
    g1.run('REAL = 205; gui()')
    check(g1.run('return #SENT') == 1, "not sent again within 15 s")
    g1.run('REAL = 216; gui()')
    check(g1.run('return #SENT') == 2, "sent again after 15 s while the state did not take it (a resynchronisation)")
    deliver()
    for g, name in ((g1, "host"), (g2, "client")):
        got = g.run('return balance(2), #BOOKS, BOOKS[1] and BOOKS[1].cat, balance(3), M.wins(st, 2), M.wins(st, 3), #S().open, S().done[1].status, S().done[1].winner')
        check(tuple(got) == (prize1, 1, "subsidy", 0, 1, 0, 0, "won", 2), f"{name}: the bonus once, to Bob's company, as a subsidy; won once: {got}")
    check(g2.g.logHas("refused: it is not open"), "the second send of the win: refused")
    same("tender 1 won")
    check(g1.M.signature(g1.g.st) == g2.M.signature(g2.g.st) == "1,1:won:2", "the same signature on both games")
    both('REAL = 230; gui()')
    check(all(g.run('return #SENT') == 0 for g in games), "nothing more to send (the next tender in 6 months)")
    check("Bob Co wins tender #1 and gets $" in g2.g.chatText() and "Bob Co remporte l'appel d'offres n°1" in g1.g.chatText(), "the winner told on every game, in its language")

    print("the tie rules")
    cos = 'local cos = { { id = 1 }, { id = 2 }, { id = 3, ai = true }, { id = 4 } }'
    cases = [
        ('{ goal = 5, prog = { ["2"] = 5, ["3"] = 7 }, reached = { ["2"] = 300, ["3"] = 200 } }', 3, "the first at the goal wins"),
        ('{ goal = 5, prog = { ["2"] = 5, ["3"] = 7 }, reached = { ["2"] = 200, ["3"] = 200 } }', 3, "at the same time: the most carried"),
        ('{ goal = 5, prog = { ["2"] = 7, ["3"] = 7 }, reached = { ["2"] = 200, ["3"] = 200 } }', 2, "the same again: the smallest number"),
        ('{ goal = 5, prog = { ["1"] = 4, ["3"] = 5 }, reached = { ["3"] = 900 } }', 3, "a computer company can win (B4)"),
        ('{ goal = 5, prog = { ["1"] = 4, ["2"] = 3 }, reached = {} }', None, "nobody at the goal: no winner"),
    ]
    for t, want, what in cases:
        check(g1.run(f'{cos}; return M.winner({t}, cos)') == want, what)
    check(g1.run('local cos = { { id = 2, gone = true }, { id = 3 } }; return M.winner({ goal = 5, prog = { ["2"] = 9, ["3"] = 5 }, reached = { ["2"] = 1, ["3"] = 5 } }, cos)') == 3,
          "a company gone (bankrupt, merged) cannot win")
    g4 = Game(0, True, "Host", 1, False)
    g4.run('st.opts.tenders = true; tick(); S().seq = 1; S().next = MONTH + 6;'
           ' S().open[1] = { id = 1, kind = "pax", a = { name = "Aville", x = 0, y = 0, e = 1 }, b = { name = "Bville", x = 6000, y = 0, e = 2 },'
           ' goal = 5, prize = 100, deadline = MONTH + 20, at = MONTH, prog = { ["4"] = 9, ["2"] = 6 }, reached = { ["4"] = 100, ["2"] = 200 } }'
           ' local env = guiEnv(); env.companies = simEnv().companies; REAL = 10; M.gui(st, env)')
    check(g4.run('return #SENT == 1 and SENT[1].param.co == 2'), "the host's list without the gone flag: the registry still tells the bankrupt company out")

    # ------------------------------------------------------------------------------------------------ rhythm, cargo, 2 at most
    print("the rhythm and two tenders at most")
    both('MONTH = 23405; month(); REAL = 300; gui()')
    check(g1.run('return #SENT') == 0, "before its month: no new tender")
    both('MONTH = 23406; month(); REAL = 310; gui()')
    t2 = g1.run('local p = SENT[1] and SENT[1].param; return p and p.id, p and p.kind, p and p.a.name, p and p.cargo, p and p.a.e, p and p.goal')
    check(tuple(t2) == (2, "ind", "Aville Steel Mill", "iron_ore.lua", 61, 6), f"tender 2 (the kinds in turn): iron ore to the steel mill, the coal nobody produces left out: {t2}")
    deliver()
    host_event("f_tenders_new", '{ id = 3, kind = "town", a = { name = "Bville", x = 6000, y = 0, e = 2 }, cargo = "food.lua", goal = 4, deadline = MONTH + 100, prize = 1000000 }')
    host_event("f_tenders_new", '{ id = 4, kind = "pax", a = { name = "Aville", x = 0, y = 0 }, b = { name = "Bville", x = 6000, y = 0 }, goal = 4, deadline = MONTH + 100, prize = 1000000 }')
    check(all(g.run('return #S().open == 2 and S().seq == 3') for g in games) and g1.g.logHas("2 are open"), "a third tender while two are open: refused")
    both('MONTH = 23412; month(); REAL = 320; gui()')
    check(g1.run('return #SENT') == 0, "its month came, but two are open: the host waits")
    same("tenders 2 and 3 open")

    print("cargo counted")
    for g in games:
        g.run('TIME = 3000')
        g.g.cargo(g.L.eval(lua_list([["L5", "iron_ore.lua", "mill"]] * 3 + [["L6", "iron_ore.lua", "mill"]] * 2 + [
            ["L6", "coal.lua", "mill"], ["L5", "iron_ore.lua", "forest"], ["L5", "food.lua", "tbB"], ["L5", "food.lua", "tbB"],
            ["L1", "food.lua", "tbA"], ["L1", "logs.lua", "tbB"], ["L4", "food.lua", "tbB"]])), SYS_CARGO)
        g.g.pax(g.L.eval(lua_list([["L1", "A", "B"]])), SYS_PAX)
    for g, name in ((g1, "host"), (g2, "client")):
        got = g.run('return prog(2, 2), prog(2, 1), prog(3, 2), prog(3, 1), prog(3, 4)')
        check(tuple(got) == (3, 2, 2, 0, 0), f"{name}: each leg to the mill counts for its company (B6), not coal, not elsewhere; food to Bville only, not the bankrupt company's: {got}")
    same("after the cargo")

    print("the window")
    both('REAL = 330; gui()')
    text = g2.g.fileText()
    check("open\t2\tind\t6\t" in text and "open\t3\ttown\t4\t" in text and "prog\t2\t2\t3" in text and "prog\t3\t2\t2" in text
          and "done\t1\tpax\twon\t2\t" in text and "wins\t2\t1" in text and "Iron ore" in text, "its file: the open tenders, the progress, the history, the wins")
    rows = g2.run('local rows = M.view(FILES[M.FILE], function(fr, en) return en end); local out = {} for i, r in ipairs(rows) do out[i] = r.kind .. "|" .. r.text .. "|" .. tostring(r.payload) end return table.concat(out, "\\n")')
    check("title|Tender #2|nil" in rows and "text|Deliver 6 Iron ore to Aville Steel Mill|nil" in rows, "a card per tender: its number and what to do")
    check(rows.index("progress|Bob Co (you): 3 / 6") < rows.index("progress|Host Co: 2 / 6"), "this player's company first")
    check("button|Show Bville|3:a" in rows and "muted|#1, Carry 6 passengers between Aville and Bville, without a transfer: won by Bob Co (you) (" in rows,
          "a Show button per place; the history")
    check(g2.run('return M.request("focus", "3:a", st, guiEnv())') and g2.run('return FOCUS.x == 6000 and FOCUS.y == 0'), "Show: the camera on Bville")
    shown = g2.run('FOCUS = nil; local out = {} local u = { T = function(fr, en) return en end, read = function(f) return FILES[f] end,'
                   ' text = function(s) out[#out + 1] = "t:" .. s end, title = function(s) out[#out + 1] = "h:" .. s end,'
                   ' muted = function(s) out[#out + 1] = "m:" .. s end, button = function(s, fn) out[#out + 1] = "b:" .. s; if s == "Show Bville" then fn() end end,'
                   ' request = function(k, p) out[#out + 1] = "r:" .. k .. ":" .. p end }'
                   ' M.ui(u) return table.concat(out, "\\n")')
    check("h:Tender #3" in shown and "b:Show Bville" in shown and "r:focus" not in shown, "the tab: titles, texts, buttons")
    check(g2.run('return FOCUS.x == 6000 and FOCUS.y == 0 and FOCUS.d == 600'), "its Show button moves the window's camera itself")
    shown = g2.run('local cam = api.gui; api.gui = nil; local out = {} local u = { T = function(fr, en) return en end, read = function(f) return FILES[f] end,'
                   ' text = function(s, cls) out[#out + 1] = "t:" .. s .. (cls and ("[" .. cls .. "]") or "") end, title = function(s) out[#out + 1] = "h:" .. s end,'
                   ' muted = function(s) out[#out + 1] = "m:" .. s end, button = function(s, fn) out[#out + 1] = "b:" .. s; if s == "Show Bville" then fn() end end,'
                   ' request = function(k, p) out[#out + 1] = "r:" .. k .. ":" .. p end }'
                   ' M.ui(u) api.gui = cam return table.concat(out, "\\n")')
    check("r:focus:3:a" in shown, "without a camera there: the button asks this game's module (u.request)")
    check("t:Bob Co (you): 3 / 6  (50 %)[success]" in shown and "t:Host Co: 2 / 6  (33 %)" in shown, "the progress: this player's in green, a percentage")

    print("the option switched off, then on again")
    both('st.opts.tenders = false; TIME = 3100')
    writes = [g.run('return WRITES') for g in games]
    for g in games:
        g.g.cargo(g.L.eval(lua_list([["L5", "iron_ore.lua", "mill"]])), SYS_CARGO)
        g.run('apply("f_tenders_expire", ser({ id = 2 }), "Host"); REAL = 400; gui()')
    check(all(g.run('return prog(2, 2) == 3 and #S().open == 2 and #SENT == 0') for g in games)
          and [g.run('return WRITES') for g in games] == writes, "off: no counting, no event applied, nothing sent, no file")
    for g in games:
        g.run('st.opts.tenders = true')
        g.g.cargo(g.L.eval(lua_list([["L5", "iron_ore.lua", "mill"]])), SYS_CARGO)
    check(all(g.run('return prog(2, 2) == 4') for g in games), "on again: it counts again")
    same("on again")

    print("the date")
    d2 = g1.run('return S().open[1].deadline')
    both(f'MONTH = {d2 - 1}; month()')
    host_event("f_tenders_expire", '{ id = 2 }')
    check(all(g.run('return #S().open == 2') for g in games) and g1.g.logHas("not expired yet"), "an expiry before the date: refused on every game")
    g1.run('REAL = 500; gui()')
    check(g1.run('return #SENT') == 0, "the host waits for the date")
    both(f'MONTH = {d2}; month()')
    g1.run('CONNECTED[TOWN.A .. "|" .. TOWN.B] = true; REAL = 510; gui()')
    check(g1.run('return #SENT == 1 and SENT[1].name == "f_tenders_expire" and SENT[1].param.id == 2'), "the date passed: the host expires it")
    books = [g.run('return #BOOKS') for g in games]
    deliver()
    check(all(g.run('return #S().open == 1 and S().done[2].id == 2 and S().done[2].status == "expired"') for g in games)
          and [g.run('return #BOOKS') for g in games] == books, "expired on both games, no money")
    g2.run('REAL = 511; gui()')
    check("Tender #2 expired without a winner." in g2.g.chatText(), "the expiry told")

    print("a place gone")
    g1.run('REAL = 520; gui()')
    t4 = g1.run('local p = SENT[1] and SENT[1].param; return p and p.id, p and p.kind, p and p.a.name')
    check(tuple(t4) == (4, "ind", "Aville Steel Mill"), f"tender 4: Aville and Bville already linked by a line, the next kind: {t4}")
    deliver()
    g1.run('REAL = 521; gui()')
    for g in games:
        g.run('COMP.IND[OFF + 60] = nil; COMP.SL[OFF + 61] = nil; NAMES[OFF + 61] = nil; TIME = 4000')
        g.g.cargo(g.L.eval(lua_list([["L5", "iron_ore.lua", "mill"]])), SYS_CARGO)
    check(all(g.run('return prog(4, 2) == 0') for g in games) and g2.g.logHas("Aville Steel Mill not found on this game"), "its industry closed: nothing counted, logged")
    g1.run('REAL = 540; gui()')
    check(g1.run('return #SENT') == 0, "the host looks for gone places every 30 s only")
    g1.run('REAL = 552; gui()')
    check(g1.run('return #SENT == 1 and SENT[1].name == "f_tenders_cancel" and SENT[1].param.why == "Aville Steel Mill"'), "the host cancels it")
    deliver()
    check(all(g.run('return #S().open == 1 and S().done[3].status == "cancelled" and S().done[3].why == "Aville Steel Mill"') for g in games), "cancelled on both games")
    same("tender 4 cancelled")

    print("a company gone, a computer company")
    host_event("f_tenders_win", '{ id = 3, co = 4 }')
    host_event("f_tenders_win", '{ id = 3, co = 9 }')
    check(all(g.run('return #S().open == 1 and balance(4) == 0') for g in games), "no win for a bankrupt company or one that does not exist")
    host_event("f_tenders_win", '{ id = 3, co = 3 }')
    check(all(g.run('return balance(3) == 1000000 and M.wins(st, 3) == 1 and #S().open == 0') for g in games), "the computer company wins tender 3 (B4)")
    same("the end")
    check(g1.M.signature(g1.g.st) == g2.M.signature(g2.g.st), "the same signature: " + str(g1.M.signature(g1.g.st)))
    check(g1.run('return balance(2)') == g2.run('return balance(2)') and g1.run('return balance(3)') == g2.run('return balance(3)'),
          "the same money on both games, company by company")

    print("the history and the rhythm parameter")
    g3 = Game(0, True, "Host", 1, False)
    g3.run('st.opts.tenders = true; st.opts["tenders.freq"] = "x"; tick()')
    for k in range(1, 26):
        g3.run(f'apply("f_tenders_new", ser({{ id = {k}, kind = "town", a = {{ name = "Bville", x = 6000, y = 0 }}, cargo = "food.lua", goal = 5, deadline = MONTH + 1, prize = 10 }}), "Host")')
        if k == 1:
            check(g3.run('return S().next == MONTH + 6'), "a frequency that is not one of its values: the default (6 months)")
        g3.run(f'MONTH = MONTH + 1; month(); apply("f_tenders_expire", ser({{ id = {k} }}), "Host")')
    check(g3.run('return #S().done == 20 and S().done[1].id == 6 and S().seq == 25'), "the last 20 closed tenders kept")
    g3.run('st.opts["tenders.freq"] = 3; apply("f_tenders_new", ser({ id = 26, kind = "town", a = { name = "Bville", x = 6000, y = 0 }, cargo = "food.lua", goal = 5, deadline = MONTH + 1, prize = 10 }), "Host")')
    check(g3.run('return S().next == MONTH + 3'), "frequent: every 3 months")

    integrated()

    print()
    if failures:
        print(f"FAIL {len(failures)} check(s)")
        return 1
    print("PASS all checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
