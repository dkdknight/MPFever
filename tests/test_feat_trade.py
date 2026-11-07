"""The 0.6 trade options (mod/mpfever_1/content/mpfever_feat_trade.lua), offline: sales between companies and supply contracts,
with the options host's env mocked as docs/FEATURES-0.6.md describes it and the module's world reads (M.rt) replaced by a small
world of lots, stations and vehicles. Two games are simulated (two Lua states, different entity ids, the same registry), the
same events applied to both in the same order.

Cases: both options off (no state, no event, no money, no file), the "shared" mode, the module's declarations; sales (only a
chief sells and answers, computer companies and unknown lots refused, a line goes with its stations, money both ways, a second
answer, an offer that changed, a refusal, a cancel, the expiry, a company gone, the limit of open offers, no transfer
available); contracts (the checks of an offer, signing, the measure of what is unloaded, the host's figures sent by the host's
GUI only, a client's figures refused, the first month without a penalty, pro rata and penalty, a month paid once, cancel at the
month's end, the end after its months, a company gone, a station lost, the expiry); determinism (the same state and money on
both games although their measures differ); the saved state is plain data and a reloaded game goes on the same; the window's
file, view, requests and chat news.

Integrated (the real files over a mocked game API, two games with different entity ids): mpfever_feat.lua loading the module,
the bridge's SIM.featBridge (lots, transferLot, book, month), G.featBridge (send, write, T, lots) and G.featRequest,
mpfever_eco.lua's E.lotsOf and E.transferLot, the module's own world reads (M.rt) and the window's U.featU / U.featTabRows: all
off does nothing; a line sold with the seller's stations of its stops and their own tracks (a third company's station stays, the
stations' own settings go, money both ways); a depot with its truck; a line changed since its offer refused; a supply contract
measured (the tick says when it changed the state) and paid from the host's figures; the tab drawn, its look and Accept buttons
through G.featRequest (a member who is not the chief sends nothing); and the auction's sale unchanged (E.transferLot without
options moves the line and its vehicles only, as before).
Needs lupa (pip install lupa). Run: python tests/test_feat_trade.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_trade.lua"), encoding="utf-8").read()

# One game: its registry (the same companies, its own player entities: OFF), a world of lots and stations found by their keys
# (the same on every game), vehicles scripted step by step, the options host's env for the simulation (ENV) and the GUI (GENV).
SETUP = r'''
LOG, BOOKS, SENT, CHAT, FILES, TRANSFERS = {}, {}, {}, {}, {}, {}
OPTS, MODE, STEPNO, MONTH, CLOCK, LANG = {}, "separate", 0, 24000, 0, "en"
BAL = {}
st = { co = { mode = "separate", list = {
  { id = 1, key = "host", name = "Host Co", ent = 100 + OFF, members = { { key = "host" } }, chief = "host" },
  { id = 2, key = "bob", name = "Bob Co", ent = 200 + OFF, members = { { key = "bob" }, { key = "dan" } }, chief = "bob" },
  { id = 3, key = "carl", name = "Carl Co", ent = 300 + OFF, members = { { key = "carl" } }, chief = "carl" },
  { id = 4, key = "ai:1", name = "Computer One", ent = 400 + OFF, members = { { key = "ai:1" } }, chief = "ai:1" },
  { id = 5, key = "eve", name = "Eve Co", ent = 500 + OFF, members = { { key = "eve" } }, chief = "eve" },
} } }
for _, c in ipairs(st.co.list) do BAL[c.ent] = 1000000 end
WORLD = { lots = {
  { kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", label = "Coal", vehicles = 3, reserve = 150000, owner = 1, stations = { "c:mine@1,1#0", "c:mill@5,5#0" } },
  { kind = "station", key = "c:mine@1,1#0", label = "Mine", reserve = 100000, owner = 1 },
  { kind = "depot", key = "D:truck@9,9", label = "Garage", reserve = 50000, owner = 1 },
  { kind = "station", key = "c:port@2,2#0", label = "Port", reserve = 100000, owner = 1 },
  { kind = "station", key = "c:mill@5,5#0", label = "Mill", reserve = 100000, owner = 2 },
  { kind = "station", key = "c:yard;x=1%@3,3#0", label = "Yard", reserve = 100000, owner = 3 },
  { kind = "station", key = "c:ai@7,7#0", label = "Computer stop", reserve = 100000, owner = 4 },
  { kind = "station", key = "c:eve@8,8#0", label = "Eve stop", reserve = 100000, owner = 5 },
} }
for i = 1, 11 do WORLD.lots[#WORLD.lots + 1] = { kind = "depot", key = "D:extra@" .. i, label = "Depot " .. i, reserve = 50000, owner = 1 } end
function lotOf(kind, key) for _, l in ipairs(WORLD.lots) do if l.kind == kind and l.key == key then return l end end end
CARGO = { COAL = 3, IRON_ORE = 4, PASSENGERS = 0 }
LABELS = { COAL = "Coal", IRON_ORE = "Iron ore" }
WATCH, VSTATE, WATCHCALLS = {}, {}, 0

M.rt.lots = function(env, s, c)
  local out = {}
  for _, l in ipairs(WORLD.lots) do
    if l.owner == c.id then out[#out + 1] = { kind = l.kind, key = l.key, label = l.label, vehicles = l.vehicles or 0, reserve = l.reserve } end
  end
  table.sort(out, function(a, b) return a.kind .. a.key < b.kind .. b.key end)
  return out
end
M.rt.station = function(env, s, c, key)
  local l = lotOf("station", key)
  if c and l and l.owner == c.id then return 5000 + OFF, l.label end
  return nil
end
M.rt.stations = function(env, s, ids)
  local out = {}
  for _, id in pairs(ids) do
    for _, l in ipairs(WORLD.lots) do
      if l.kind == "station" and l.owner == id then out[id] = out[id] or {}; table.insert(out[id], { key = l.key, label = l.label }) end
    end
  end
  return out
end
M.rt.cargoId = function(name) return CARGO[name] end
M.rt.isPassengers = function(id) return id == 0 end
M.rt.cargoLabel = function(name) return LABELS[name] or tostring(name) end
M.rt.cargos = function() return { { name = "COAL", label = "Coal" }, { name = "IRON_ORE", label = "Iron ore" } } end
M.rt.coName = function(s, c) if not c then return "?" end return c.name end
M.rt.watch = function(env, s, c, reg) WATCHCALLS = WATCHCALLS + 1; return WATCH[c.id] or {} end
M.rt.vehicle = function(v) local x = VSTATE[v] or {} return x.state or "other", x.idx end
M.rt.load = function(v, cid) return (VSTATE[v] or {}).load or 0 end

ENV = { log = function(s) LOG[#LOG + 1] = s end, STEP = 200, gameTime = function() return STEPNO * 200 end,
  on = function(id) return OPTS[id] == true end, param = function() return nil end,
  state = function(s) s.feat = s.feat or {}; s.feat.trade = s.feat.trade or {}; return s.feat.trade end,
  money = function(ent) return BAL[ent] or 0 end,
  book = function(ent, amount, kind) BAL[ent] = (BAL[ent] or 0) + amount; BOOKS[#BOOKS + 1] = { ent = ent, amount = amount, kind = kind } end,
  every = function(n) return STEPNO % n == 0 end, month = function() return MONTH end, R = {} }
ENV.transferLot = function(fromId, toId, lot)
  TRANSFERS[#TRANSFERS + 1] = { from = fromId, to = toId, kind = lot.kind, key = lot.key, withStations = lot.withStations }
  local l = lotOf(lot.kind, lot.key)
  if not (l and l.owner == fromId) then return 0 end
  local n = 1 + (l.vehicles or 0)
  l.owner = toId
  if lot.withStations then
    for _, k in ipairs(l.stations or {}) do
      local s = lotOf("station", k)
      if s and s.owner == fromId then s.owner = toId; n = n + 1 end
    end
  end
  return n
end
TRANSFER = ENV.transferLot
function sync() ENV.mode = MODE; ENV.co = MODE == "separate" and st.co or nil end
function ev(name, param) sync(); return M.event(st, name, param, ENV) end
function step(n) for i = 1, (n or 1) do STEPNO = STEPNO + 1; sync(); M.tick(st, ENV) end end
function newMonth() MONTH = MONTH + 1; sync(); M.month(st, ENV) end
GENV = { log = ENV.log, on = ENV.on, param = ENV.param, isHost = true, me = "Host", myCo = 1,
  send = function(n, p) SENT[#SENT + 1] = { name = n, param = p } end, chat = function(t) CHAT[#CHAT + 1] = t end,
  write = function(f, lines) FILES[f] = lines end, realTime = function() return CLOCK end,
  T = function(fr, en) if LANG == "fr" then return fr end return en end }
function gui(isHost, me, myCo) GENV.isHost, GENV.me, GENV.myCo = isHost, me, myCo; M.gui(st, GENV) end
function S() return st.feat and st.feat.trade end
function co(id) for _, c in ipairs(st.co.list) do if c.id == id then return c end end end
-- the money of each company by its number (the entities differ between games)
function money() local t = {} for _, c in ipairs(st.co.list) do t[#t + 1] = c.id .. ":" .. tostring(BAL[c.ent]) end return table.concat(t, " ") end
-- a vehicle of this game (its local id): state, stop index, load
function veh(n, state, idx, load) VSTATE[9000 + OFF + n] = { state = state, idx = idx, load = load } end
function watch(id, list) local w = {} for _, n in ipairs(list) do w[#w + 1] = { v = 9000 + OFF + n, at = { [1] = true } } end WATCH[id] = w end
-- the state as text, sorted, without `skip` at the top level (this game's measure, "here")
function ser(t, skip)
  if type(t) ~= "table" then return type(t) == "string" and string.format("%q", t) or tostring(t) end
  local keys = {}
  for k in pairs(t) do if not (skip and skip[k]) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(t[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
function shared() local s = S() return s and ser(s, { here = true }) or "nil" end
-- plain data: no function, userdata, thread or metatable, no table reached twice (no cycle, nothing shared)
function plain(t, seen, path)
  seen = seen or {}
  path = path or "state"
  local ty = type(t)
  if ty == "function" or ty == "userdata" or ty == "thread" then return path .. " is a " .. ty end
  if ty ~= "table" then return nil end
  if seen[t] then return path .. " reached twice" end
  seen[t] = true
  if getmetatable(t) ~= nil then return path .. " has a metatable" end
  for k, v in pairs(t) do
    if type(k) ~= "string" and type(k) ~= "number" then return path .. " has a key of type " .. type(k) end
    local e = plain(v, seen, path .. "." .. tostring(k))
    if e then return e end
  end
  return nil
end
function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
function logHas(s) for _, l in ipairs(LOG) do if l:find(s, 1, true) then return true end end return false end
'''

failures = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        failures.append(what)


def new_game(off):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    # (the module loads without the game's API: the lobby and the tests require it)
    M = L.execute(SRC)
    g = L.globals()
    g.M = M
    g.OFF = off
    L.execute(SETUP)
    return L


A = new_game(0)
B = new_game(1000)


def run(L, code):
    return L.execute(code)


def both(code):
    ra, rb = run(A, code), run(B, code)
    return ra, rb


def same(what):
    sa, sb = run(A, "return shared()"), run(B, "return shared()")
    ma, mb = run(A, "return money()"), run(B, "return money()")
    check(sa == sb and ma == mb, "the two games agree: " + what + ("" if sa == sb else "\n          A " + sa + "\n          B " + sb)
          + ("" if ma == mb else "\n          money A " + ma + " / B " + mb))


print("the module's declarations")
check(run(A, "return M.ID") == "trade", "M.ID is 'trade'")
check(run(A, 'local ok = true for _, o in ipairs(M.OPTIONS) do ok = ok and o.id:match("^[a-z_]+$") ~= nil and o.modes == "separate" and #o.title == 2 and #o.desc == 2 end return ok and #M.OPTIONS == 2 and M.OPTIONS[1].id == "sales" and M.OPTIONS[2].id == "contracts"') is True,
      "two options, 'sales' and 'contracts', separate mode only, French and English")
check(run(A, 'local ok = true for k in pairs(M.EVENTS) do ok = ok and k:sub(1, 8) == "f_trade_" end return ok') is True, "every event starts with f_trade_")
check(run(A, 'return M.TAB.id == "trade" and #M.TAB.title == 2') is True, "the window's tab")
check(run(A, 'local ok = true for _, p in pairs(M.TX) do ok = ok and type(p[1]) == "string" and type(p[2]) == "string" and select(2, p[1]:gsub("%%s", "")) == select(2, p[2]:gsub("%%s", "")) end return ok') is True,
      "every text has French and English, with as many %s")

print("both options off")
both('''
ev("f_trade_offer", { to = 2, kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", price = 5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_answer", { id = 1, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })
ev("f_trade_ct_offer", { to = 2, role = "supply", station = "c:mill@5,5#0", cargo = "COAL", per = 10, price = 5, penalty = 0, months = 3, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_pay", { month = 23999, ct = {}, mpfFrom = "Host" })
step(60); newMonth(); gui(true, "Host", 1); gui(false, "Bob#1", 2)
''')
check(run(A, "return st.feat == nil and #BOOKS == 0 and #SENT == 0 and #CHAT == 0 and next(FILES) == nil and #TRANSFERS == 0 and WATCHCALLS == 0") is True,
      "no state, no money, no event, no chat, no file, no transfer, no look at the world")

print("the shared mode")
both('MODE = "shared"; st.co.mode = "shared"; OPTS.sales = true; OPTS.contracts = true')
both('''
ev("f_trade_offer", { to = 2, kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", price = 5, mpfCo = 1, mpfFrom = "Host" })
step(60); newMonth(); gui(true, "Host", 1)
''')
check(run(A, "return st.feat == nil and #BOOKS == 0 and #SENT == 0 and next(FILES) == nil") is True, "options on in the shared mode: nothing")
both('MODE = "separate"; st.co.mode = "separate"; OPTS.contracts = false')

print("sales: refusals")
both('''
ev("f_trade_offer", { to = 3, kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", price = 5, mpfCo = 2, mpfFrom = "Dan#2" })
ev("f_trade_offer", { to = 4, kind = "depot", key = "D:truck@9,9", price = 5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 1, kind = "depot", key = "D:truck@9,9", price = 5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 2, kind = "depot", key = "D:nowhere", price = 5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 2, kind = "track", key = "D:truck@9,9", price = 5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 2, kind = "depot", key = "D:truck@9,9", price = -5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 2, kind = "depot", key = "D:truck@9,9", price = 1.5, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 2, kind = "depot", key = "D:truck@9,9", price = 2e10, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_offer", { to = 2, kind = "station", key = "c:mill@5,5#0", price = 5, mpfCo = 1, mpfFrom = "Host" })
''')
check(run(A, "return st.feat == nil") is True, "a member who is not the chief, a computer company buying, itself, an unknown lot, a "
      "track, a bad price, another company's station: refused, nothing written")
check(run(A, 'return logHas("not the chief") and logHas("buyer 4") and logHas("has no such depot") and logHas("price -5")') is True,
      "each refusal says why in the log")

print("sales: an offer, the answers")
both('ev("f_trade_offer", { to = 2, kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", price = 500000, mpfCo = 1, mpfFrom = "Host" })')
check(run(A, "return #S().offers == 1 and S().offers[1].id == 1 and S().offers[1].nveh == 3 and S().offers[1].label == 'Coal'") is True, "the host's line is offered to company 2")
check(run(A, "return S().news[#S().news].kind") == "offer", "a news of the offer")
both('''
ev("f_trade_answer", { id = 1, accept = true, mpfCo = 3, mpfFrom = "Carl#3" })
ev("f_trade_answer", { id = 1, accept = true, mpfCo = 2, mpfFrom = "Dan#2" })
ev("f_trade_answer", { id = 1, accept = true, mpfCo = 1, mpfFrom = "Host" })
''')
check(run(A, "return #S().offers == 1 and #BOOKS == 0 and #TRANSFERS == 0") is True, "another company, a member who is not the chief, the seller: cannot answer")
both('ev("f_trade_answer", { id = 1, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })')
check(run(A, "return #S().offers == 0 and #TRANSFERS == 1 and TRANSFERS[1].withStations == true and TRANSFERS[1].from == 1 and TRANSFERS[1].to == 2") is True,
      "the buyer's chief accepts: the line changes hands with its stations (E5)")
check(run(A, 'return lotOf("line", "L:Coal|c:mine@1,1#0;c:mill@5,5#0").owner == 2 and lotOf("station", "c:mine@1,1#0").owner == 2') is True,
      "the line and the seller's station it stops at are company 2's")
check(run(A, "return money()") == "1:1500000 2:500000 3:1000000 4:1000000 5:1000000", "the buyer paid the seller 500 000")
check(run(A, 'return BOOKS[1].kind == "acquisition" and BOOKS[2].kind == "acquisition"') is True, "booked as an acquisition")
same("after a sale")
both('ev("f_trade_answer", { id = 1, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })')
check(run(A, "return #BOOKS == 2 and #TRANSFERS == 1") is True, "a second answer to the same offer does nothing")

print("sales: cancel, refusal, an offer that changed")
both('''
ev("f_trade_offer", { to = 3, kind = "depot", key = "D:truck@9,9", price = 50000, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_cancel", { id = 2, mpfCo = 3, mpfFrom = "Carl#3" })
''')
check(run(A, "return #S().offers") == 1, "only the seller's chief takes an offer back")
both('ev("f_trade_cancel", { id = 2, mpfCo = 1, mpfFrom = "Host" })')
check(run(A, "return #S().offers == 0 and S().news[#S().news].kind == 'cancelled'") is True, "the seller takes its offer back")
both('''
ev("f_trade_offer", { to = 3, kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", price = 100, mpfCo = 2, mpfFrom = "Bob#1" })
ev("f_trade_answer", { id = 3, accept = false, mpfCo = 3, mpfFrom = "Carl#3" })
''')
check(run(A, "return #S().offers == 0 and #BOOKS == 2 and S().news[#S().news].kind == 'refused'") is True, "a refusal: the offer goes, no money")
both('''
ev("f_trade_offer", { to = 3, kind = "line", key = "L:Coal|c:mine@1,1#0;c:mill@5,5#0", price = 100, mpfCo = 2, mpfFrom = "Bob#1" })
lotOf("line", "L:Coal|c:mine@1,1#0;c:mill@5,5#0").vehicles = 4
ev("f_trade_answer", { id = 4, accept = true, mpfCo = 3, mpfFrom = "Carl#3" })
''')
check(run(A, 'return #S().offers == 0 and #BOOKS == 2 and #TRANSFERS == 1 and S().news[#S().news].kind == "changed" and lotOf("line", "L:Coal|c:mine@1,1#0;c:mill@5,5#0").owner == 2') is True,
      "a line whose vehicles changed since the offer: refused, nothing moves")
same("after the refusals")

print("sales: the offer replaced, the limit, the expiry, a company gone, no transfer")
both('''
for i = 1, 10 do ev("f_trade_offer", { to = 3, kind = "depot", key = "D:extra@" .. i, price = 1000, mpfCo = 1, mpfFrom = "Host" }) end
ev("f_trade_offer", { to = 3, kind = "depot", key = "D:extra@11", price = 1000, mpfCo = 1, mpfFrom = "Host" })
''')
check(run(A, "return #S().offers") == 10, "at most 10 open offers per company")
both('ev("f_trade_offer", { to = 5, kind = "depot", key = "D:extra@3", price = 2000, mpfCo = 1, mpfFrom = "Host" })')
check(run(A, 'local n, o = 0, nil for _, x in ipairs(S().offers) do if x.key == "D:extra@3" then n = n + 1; o = x end end return #S().offers == 10 and n == 1 and o.to == 5 and o.price == 2000') is True,
      "the same lot offered again: the new offer replaces the old one")
both('co(3).gone = "bankrupt"; ev("f_trade_answer", { id = 5, accept = true, mpfCo = 3, mpfFrom = "Carl#3" })')
check(run(A, "return #BOOKS == 2") is True, "a bankrupt company cannot buy")
both('newMonth()')
check(run(A, 'local ok = true for _, o in ipairs(S().offers) do ok = ok and o.to ~= 3 end return ok and #S().offers == 1') is True,
      "at the month's turn, the offers to the bankrupt company go")
both('co(3).gone = nil; newMonth()')
check(run(A, "return #S().offers == 0 and S().news[#S().news].kind == 'expired'") is True, "an offer not answered for two months expires")
both('''
ENV.transferLot = nil
ev("f_trade_offer", { to = 5, kind = "depot", key = "D:extra@1", price = 1000, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_answer", { id = S().seq, accept = true, mpfCo = 5, mpfFrom = "Eve#4" })
ENV.transferLot = TRANSFER
''')
check(run(A, 'return #BOOKS == 2 and logHas("no transfer of assets") and S().news[#S().news].kind == "failed"') is True,
      "no transfer available (outside the game, no mpfever_eco.lua): refused, no money")
same("after the sales")

print("contracts: checks of an offer")
both('OPTS.contracts = true; OPTS.sales = false')
both('ev("f_trade_offer", { to = 5, kind = "depot", key = "D:extra@1", price = 1000, mpfCo = 1, mpfFrom = "Host" })')
check(run(A, 'return logHas("the sales are off") and #S().offers == 0') is True, "the sales off: an offer of sale is refused")
CT = 'ev("f_trade_ct_offer", { to = %s, role = "%s", station = "%s", cargo = "%s", per = %s, price = %s, penalty = %s, months = %s, mpfCo = %s, mpfFrom = "%s" })'
seq0 = run(A, "return S().seq")
both("\n".join([
    CT % (2, "supply", "c:mill@5,5#0", "PASSENGERS", 100, 20, 5, 3, 1, "Host"),
    CT % (2, "supply", "c:mill@5,5#0", "STEEL", 100, 20, 5, 3, 1, "Host"),
    CT % (2, "supply", "c:eve@8,8#0", "COAL", 100, 20, 5, 3, 3, "Carl#3"),
    CT % (2, "pay", "c:mill@5,5#0", "COAL", 100, 20, 5, 3, 1, "Host"),
    CT % (2, "supply", "c:mill@5,5#0", "COAL", 0, 20, 5, 3, 1, "Host"),
    CT % (2, "supply", "c:mill@5,5#0", "COAL", 100, 0, 5, 3, 1, "Host"),
    CT % (2, "supply", "c:mill@5,5#0", "COAL", 100, 20, -1, 3, 1, "Host"),
    CT % (2, "supply", "c:mill@5,5#0", "COAL", 100, 20, 5, 5, 1, "Host"),
    CT % (4, "pay", "c:ai@7,7#0", "COAL", 100, 20, 5, 3, 1, "Host"),
    CT % (2, "supply", "c:mill@5,5#0", "COAL", 100, 20, 5, 3, 2, "Dan#2"),
    CT % (2, "sell", "c:mill@5,5#0", "COAL", 100, 20, 5, 3, 1, "Host"),
]))
check(run(A, "return S().seq") == seq0 and run(A, "return #S().ct") == 0,
      "passengers, an unknown cargo, a station not the payer's, units, price, penalty or months out of range, a computer company, "
      "a member who is not the chief, a bad role: refused")

print("contracts: signing and the measure")
both(CT % (2, "supply", "c:mill@5,5#0", "COAL", 100, 20, 5, 3, 1, "Host"))
cid = run(A, "return S().ct[1].id")
check(run(A, 'local c = S().ct[1] return c.state == "offer" and c.supplier == 1 and c.payer == 2 and c.label == "Mill" and c.by == 1') is True,
      "the host offers to deliver 100 coal a month at company 2's station Mill")
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 1, mpfFrom = "Host" })' % cid)
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 2, mpfFrom = "Dan#2" })' % cid)
check(run(A, "return S().ct[1].state") == "offer", "the proposer, or a member who is not the chief, cannot sign")
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })' % cid)
check(run(A, "return S().ct[1].state == 'active' and S().ct[1].start == MONTH") is True, "company 2's chief signs: running from this month")
# the vehicles: on game A, truck 1 unloads all (100), truck 2 loads again before it emptied (counts 80: the known error), truck 3
# goes through without standing (nothing); on game B the same trucks are a step late and truck 2 is counted 70
both('watch(%d, { 1, 2, 3 })' % cid)
run(A, '''
veh(1, "en_route", 1, 100); veh(2, "en_route", 1, 100); veh(3, "en_route", 1, 50); step()
veh(1, "at_terminal", 1, 60); veh(2, "at_terminal", 1, 50); veh(3, "en_route", 2, 50); step()
veh(1, "at_terminal", 1, 0); veh(2, "at_terminal", 1, 20); step()
veh(1, "en_route", 2, 0); veh(2, "en_route", 2, 20); step()
''')
run(B, '''
veh(1, "en_route", 1, 100); veh(2, "en_route", 1, 100); veh(3, "en_route", 1, 50); step(); step()
veh(1, "at_terminal", 1, 0); veh(2, "at_terminal", 1, 30); veh(3, "en_route", 2, 50); step()
veh(1, "en_route", 2, 0); veh(2, "en_route", 2, 30); step()
''')
check(run(A, 'return S().here.cur["%d"]' % cid) == 180, "game A measured 100 + 80 + 0 = 180")
check(run(B, 'return S().here.cur["%d"]' % cid) == 170, "game B measured 170 (its vehicles' own steps)")
check(run(A, "return count(S().here.trk)") == 0, "nothing followed once the trucks left")
same("the measures differ, the state does not")

print("contracts: the host's figures, the first month")
both('newMonth()')
check(run(A, 'return S().here.last["%d"] == 180 and S().here.lastMon == MONTH - 1 and S().due == MONTH - 1 and next(S().here.cur) == nil' % cid) is True,
      "at the month's turn the month's count is kept, a new one starts")
run(B, 'gui(false, "Bob#1", 2)')
check(run(B, "return #SENT") == 0, "a client's GUI sends no figures")
run(A, 'gui(true, "Host", 1)')
check(run(A, 'return #SENT == 1 and SENT[1].name == "f_trade_pay" and SENT[1].param.month == MONTH - 1 and SENT[1].param.ct[1].n == 180 and SENT[1].param.ct[1].lost == nil') is True,
      "the host's GUI sends its own figures of the month over")
run(A, 'gui(true, "Host", 1)')
check(run(A, "return #SENT") == 1, "sent once (again only after 10 s when the games did not take it)")
PAY = 'ev("f_trade_pay", { month = %d, ct = { { id = %d, n = %d } }, mpfFrom = "%s" })'
due = run(A, "return S().due")
both(PAY % (due, cid, 180, "Bob#1"))
check(run(A, 'return logHas("not the host") and S().paidMon == nil') is True, "figures from a client are refused")
before = run(A, "return money()")
both(PAY % (due, cid, 180, "Host"))
check(run(A, "return money()") == "1:1502000 2:498000 3:1000000 4:1000000 5:1000000",
      "the month of the signature: 100 (the most a month) x 20 paid, no penalty")
check(run(A, 'local c = S().ct[1] return c.done == 0 and c.paid == 2000 and c.last == 100 and S().paidMon == %d' % due) is True, "not counted in the contract's months")
check(run(B, "return money()") == run(A, "return money()"), "game B pays the host's figures, not its own 170")
both(PAY % (due, cid, 180, "Host"))
check(run(A, 'return logHas("already paid") and S().ct[1].paid == 2000') is True, "a month is paid once")
both(PAY % (due + 5, cid, 10, "Host"))
check(run(A, 'return logHas("not over") and S().ct[1].paid == 2000') is True, "a month not over yet is refused")
same("after the first month")

print("contracts: a month not met, cancel, end")
both('newMonth(); ev("f_trade_pay", { month = MONTH - 1, ct = { { id = %d, n = 40 } }, mpfFrom = "Host" })' % cid)
check(run(A, "return money()") == "1:1502500 2:497500 3:1000000 4:1000000 5:1000000",
      "40 of 100: 800 paid, and the supplier pays 60 x 5 = 300 of penalty (E2)")
check(run(A, 'local c = S().ct[1] return c.done == 1 and c.pen == 300 and S().news[#S().news].kind == "ct_paid"') is True, "one month done, the penalty counted")
both('ev("f_trade_ct_cancel", { id = %d, mpfCo = 3, mpfFrom = "Carl#3" })' % cid)
check(run(A, "return S().ct[1].state") == "active", "a company outside the contract cannot cancel it")
both('ev("f_trade_ct_cancel", { id = %d, mpfCo = 2, mpfFrom = "Bob#1" })' % cid)
check(run(A, "return S().ct[1].state") == "ending", "the payer's chief cancels: it ends with this month")
both('newMonth(); ev("f_trade_pay", { month = MONTH - 1, ct = { { id = %d, n = 100 } }, mpfFrom = "Host" })' % cid)
check(run(A, 'return #S().ct == 0 and S().news[#S().news].kind == "ct_end" and S().news[#S().news].why == "cancelled"') is True,
      "paid for its last month, then over")
check(run(A, "return money()") == "1:1504500 2:495500 3:1000000 4:1000000 5:1000000", "its last month paid in full")
same("after a cancelled contract")

print("contracts: completed, a company gone, a station lost, the expiry")
both(CT % (1, "pay", "c:mill@5,5#0", "COAL", 10, 1, 0, 3, 2, "Bob#1"))
c2 = run(A, "return S().seq")
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 1, mpfFrom = "Host" })' % c2)
for _ in range(4):
    both('newMonth(); ev("f_trade_pay", { month = MONTH - 1, ct = { { id = %d, n = 10 } }, mpfFrom = "Host" })' % c2)
check(run(A, 'return #S().ct == 0 and S().news[#S().news].why == "done"') is True, "a contract of 3 months ends after its 3 months (the first one apart)")
both(CT % (2, "supply", "c:mill@5,5#0", "IRON_ORE", 10, 1, 1, 0, 1, "Host"))
c3 = run(A, "return S().seq")
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })' % c3)
m0 = run(A, "return money()")
both('co(2).gone = "merged"; newMonth()')
check(run(A, 'return #S().ct == 0 and S().news[#S().news].why == "gone"') is True, "a company merged into another: its contract ends at the month's turn")
check(run(A, "return money()") == m0, "with no payment")
both('co(2).gone = nil')
both(CT % (2, "supply", "c:mill@5,5#0", "COAL", 10, 1, 7, 0, 1, "Host"))
c4 = run(A, "return S().seq")
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })' % c4)
# (its first month paid, then the payer's station goes to another company: a month with a penalty otherwise)
both('newMonth(); ev("f_trade_pay", { month = MONTH - 1, ct = { { id = %d, n = 10 } }, mpfFrom = "Host" })' % c4)
both('lotOf("station", "c:mill@5,5#0").owner = 3; newMonth()')
run(A, 'SENT = {}; CLOCK = CLOCK + 100; gui(true, "Host", 1)')
check(run(A, 'return #SENT == 1 and SENT[1].param.ct[1].lost == true') is True, "the host's GUI tells a station that is no longer the payer's")
pay = run(A, "return SENT[1].param")
m0 = run(A, "return money()")
both('ev("f_trade_pay", { month = %d, ct = { { id = %d, n = 0, lost = true } }, mpfFrom = "Host" })' % (pay.month, c4))
check(run(A, 'return #S().ct == 0 and S().news[#S().news].why == "lost"') is True, "the contract ends")
check(run(A, "return money()") == m0, "without a penalty")
both('lotOf("station", "c:mill@5,5#0").owner = 2')
both(CT % (2, "supply", "c:mill@5,5#0", "COAL", 10, 1, 0, 0, 1, "Host"))
both('newMonth(); newMonth()')
check(run(A, 'return #S().ct == 0 and S().news[#S().news].kind == "ct_expired"') is True, "a contract offer not answered for two months expires")
both('OPTS.contracts = false; ' + CT % (2, "supply", "c:mill@5,5#0", "COAL", 10, 1, 0, 0, 1, "Host"))
check(run(A, 'return logHas("the supply contracts are off") and #S().ct == 0') is True, "the contracts off: refused")
same("after the contracts")
check(run(A, "return plain(S())") is None, "the saved state is plain data: " + str(run(A, "return plain(S())")))

print("a savegame reloaded")
both('OPTS.contracts = true; OPTS.sales = true')
both(CT % (2, "supply", "c:mill@5,5#0", "COAL", 50, 3, 2, 6, 1, "Host"))
c5 = run(A, "return S().seq")
both('ev("f_trade_ct_answer", { id = %d, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })' % c5)
both('ev("f_trade_offer", { to = 5, kind = "depot", key = "D:extra@2", price = 777, mpfCo = 1, mpfFrom = "Host" })')
# game C: game A's savegame (its state through text, as a savegame keeps it), a fresh Lua state
C = new_game(0)
C.globals().TEXT = run(A, "return ser(st)")
C.globals().MONTH = run(A, "return MONTH")
C.globals().STEPNO = run(A, "return STEPNO")
run(C, 'st = load("return " .. TEXT)(); BAL = {}; for _, c in ipairs(st.co.list) do BAL[c.ent] = 0 end')
run(A, 'BAL = {}; for _, c in ipairs(st.co.list) do BAL[c.ent] = 0 end')
check(run(C, "return shared()") == run(A, "return shared()"), "the reloaded state is the same")
for L in (A, C):
    run(L, '''
OPTS.contracts = true; OPTS.sales = true
newMonth(); ev("f_trade_pay", { month = MONTH - 1, ct = { { id = %d, n = 50 } }, mpfFrom = "Host" })
newMonth(); ev("f_trade_pay", { month = MONTH - 1, ct = { { id = %d, n = 20 } }, mpfFrom = "Host" })
ev("f_trade_offer", { to = 5, kind = "depot", key = "D:extra@4", price = 5, mpfCo = 1, mpfFrom = "Host" })
''' % (c5, c5))
check(run(C, "return shared()") == run(A, "return shared()") and run(C, "return money()") == run(A, "return money()"),
      "the reloaded game goes on as the game that saved it")

print("the window")
run(A, 'CHAT = {}; SENT = {}; FILES = {}; M.g.seen = nil')
run(A, 'gui(false, "Bob#1", 2)')
check(run(A, "return #CHAT") == 0, "the first look in a GUI tells nothing of the past")
run(A, 'ev("f_trade_offer", { to = 2, kind = "depot", key = "D:extra@5", price = 4000, mpfCo = 1, mpfFrom = "Host" })')
run(A, 'gui(false, "Bob#1", 2)')
check(run(A, "return CHAT[1]") == "Host Co offers depot « Depot 5 » to Bob Co for $4 000.", "the news in this game's chat: " + str(run(A, "return CHAT[1]")))
run(A, 'LANG = "fr"; ev("f_trade_cancel", { id = S().seq, mpfCo = 1, mpfFrom = "Host" }); gui(false, "Bob#1", 2); LANG = "en"')
check(run(A, "return CHAT[2]") == "Host Co retire son offre : le dépôt « Depot 5 ».", "in French for a French player")
run(A, 'CHAT = {}; ev("f_trade_offer", { to = 2, kind = "depot", key = "D:extra@7", price = 900, mpfCo = 1, mpfFrom = "Host" }); gui(false, "Carl#3", 3)')
check(run(A, "return #CHAT") == 0, "a third company is not told of an offer between two others")
run(A, 'ev("f_trade_answer", { id = S().seq, accept = true, mpfCo = 2, mpfFrom = "Bob#1" }); gui(false, "Carl#3", 3)')
check(run(A, "return CHAT[1]") == "Sold: depot « Depot 7 », from Host Co to Bob Co for $900.", "a sale done is told to everybody: " + str(run(A, "return CHAT[1]")))
run(A, 'ev("f_trade_offer", { to = 2, kind = "depot", key = "D:extra@6", price = 4000, mpfCo = 1, mpfFrom = "Host" }); CLOCK = CLOCK + 100; gui(false, "Bob#1", 2)')
check(run(A, 'for _, l in ipairs(FILES[M.FILE]) do if l:sub(1, 4) == "lot\\t" or l:sub(1, 3) == "st\\t" then return false end end return true') is True,
      "nobody looks at the tab: the map's assets and stations are not read")
run(A, 'M.request("look", "", st, GENV); gui(false, "Bob#1", 2)')
lines = run(A, 'return FILES[M.FILE]')
check(lines is not None and run(A, 'return FILES[M.FILE][1]') == "me\t2\t1\t1\t1", "the window's file: company 2, its chief, both options")
VIEW = '''
local m = M.parse(FILES[M.FILE])
local rows = M.view(m, GENV.T, {})
local out = {}
for _, r in ipairs(rows) do
  local t = {}
  for _, it in ipairs(r) do t[#t + 1] = it.text or ("[" .. it.button .. (it.off and " off" or "") .. "]") end
  out[#out + 1] = table.concat(t, " ")
end
return table.concat(out, "\\n")
'''
view = run(A, VIEW)
check("Host Co offers you depot « Depot 5 »" not in view and "Host Co offers you depot « Depot 6 » for $4 000. [Accept] [Refuse]" in view,
      "the offer received, with its buttons")
check("Sell: pick an asset of your company." in view and "[Sell…]" in view, "the chief may sell its assets")
check("New contract:" in view and "[Offer the contract]" in view and "Station of Bob Co" not in view and "Station of Host Co: Port" in view,
      "the contract form: delivering at the other company's station")
run(A, 'gui(false, "Dan#2", 2)')
view = run(A, VIEW)
check("Only the company's chief can sell, buy or sign a contract." in view and "[Accept off]" in view and "New contract:" not in view,
      "a member who is not the chief: told so, the buttons greyed out")
run(A, 'SENT = {}; CHAT = {}; GENV.myCo, GENV.me = 2, "Dan#2"')
check(run(A, 'return M.request("answer", M.encode({ id = S().seq, accept = true }), st, GENV)') is False and run(A, "return #SENT == 0 and #CHAT == 1") is True,
      "his request is not sent, the chat tells why")
run(A, 'GENV.me = "Bob#1"')
check(run(A, 'return M.request("answer", M.encode({ id = S().seq, accept = true }), st, GENV)') is True
      and run(A, 'return SENT[1].name == "f_trade_answer" and SENT[1].param.id == S().seq and SENT[1].param.accept == true') is True,
      "the chief's answer is sent as the module's event")
check(run(A, 'local k = "L:A;B=C%|c:x@1,1#0\\tz" local t = M.decode(M.encode({ key = k, price = 5, ok = true })) return t.key == k and t.price == "5" and t.ok == "1"') is True,
      "a request's payload keeps keys with ';', '=', '%' and tabs")
# M.ui with helpers that record the widgets; pressing a button of the view (the chief's file again)
run(A, '''
gui(false, "Bob#1", 2)
UIW, REQ = {}, {}
U = { T = GENV.T, read = function(f) return FILES[f] end, request = function(k, p) REQ[#REQ + 1] = { k = k, p = p } end,
  text = function(s) return { text = s } end, title = function(s) return { text = s } end,
  button = function(l, fn, primary, enabled) return { button = l, fn = fn, on = enabled } end,
  row = function(ws) return { row = ws } end, add = function(n) if n.row then UIW[#UIW + 1] = n.row end end }
M.ui(U)
for _, r in ipairs(UIW) do for _, w in ipairs(r) do if w.button == "Accept" and w.on then w.fn() break end end end
''')
check(run(A, 'return #REQ == 2 and REQ[1].k == "look" and REQ[2].k == "answer" and M.decode(REQ[2].p).accept == "1"') is True,
      "the tab drawn tells it is looked at, its Accept button asks the module")
run(A, '''
UIW = {}
M.form = {}
M.ui(U)
for _, r in ipairs(UIW) do for _, w in ipairs(r) do if w.button == "Sell…" and w.on then w.fn() break end end end
UIW = {}
M.ui(U)
''')
check(run(A, 'return M.form.lot ~= nil and M.form.price ~= nil') is True, "Sell… picks the asset in the form")
check(run(A, 'local n = 0 for _, r in ipairs(UIW) do for _, w in ipairs(r) do if w.button == "Offer" then n = n + 1 end end end return n') == 1,
      "then the form shows the buyer, the price and Offer")

print("both options switched off again")
both('OPTS.sales = false; OPTS.contracts = false; SENT = {}; CHAT = {}; FILES = {}')
before = run(A, "return shared()"), run(A, "return money()")
both('step(60); newMonth(); gui(true, "Host", 1)')
check((run(A, "return shared()"), run(A, "return money()")) == before and run(A, "return #SENT == 0 and #CHAT == 0 and next(FILES) == nil") is True,
      "a game with trade switched off: nothing changes, nothing is sent or written")

# ---------------------------------------------------------------------------------------------------------------------------------
# Integrated: the real options host (mpfever_feat.lua) loading the real module, the bridge's real helpers (SIM.featBridge,
# G.featBridge, G.featRequest), mpfever_eco.lua's real E.lotsOf / E.transferLot, mpfever_co.lua, the module's own world reads
# (M.rt, not replaced here) and the window's real U.featU / U.featTabRows, over a mocked game API. Two games (their entity ids
# differ), the same events.
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")


def read(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def extract(src, pattern, what):
    import re
    m = re.search(pattern, src, re.S | re.M)
    if not m:
        print(f"FAIL: {what} not found")
        sys.exit(1)
    return m.group(0)


BRIDGE = read("mpfever_bridge.script.lua")
UI = read("mpfever_ui.script.lua")
SIMB_SRC = extract(BRIDGE, r"^SIM\.featBridge = function\(\)\n.*?^end\n", "SIM.featBridge")
GUIB_SRC = extract(BRIDGE, r"^G\.featBridge = function\(\)\n.*?^end\n", "G.featBridge")
GREQ_SRC = extract(BRIDGE, r"^G\.featRequest = function\(p\)\n.*?^end\n", "G.featRequest")
WIN_SRC = extract(UI, r"^U\.featOff = .*?^U\.featTabRows = function\(K, st, key\)\n.*?^end\n", "the window's game options")

# The world of one game (OFF: its entity ids). Company 1 (the host) owns the line "Coal" (Mine, Mill, and Carl's Port), its two
# trucks, the stations Mine and Mill (their buildings, own tracks and a node) and the depot Garage (a truck in it); company 3 owns
# Port; company 1 also has the line "Ore" (Port, Mill), whose truck delivers at Mill.
WORLD2 = r'''
local function e(n) return n + OFF end
P1, P2, P3 = e(100), e(200), e(300)
OWN, BAL, NAMES, CMDS, LOGS, EVENTS, CHATS, FILEDATA = {}, {}, {}, {}, {}, {}, {}, {}
SG = { [e(10)] = { e(11) }, [e(20)] = { e(21) }, [e(30)] = { e(31) } }
CONOF = { [e(11)] = e(12), [e(21)] = e(22), [e(31)] = e(32) }
CONS = { [e(12)] = { frozenEdges = { e(13), e(14) }, frozenNodes = { e(15) }, depots = {} },
  [e(22)] = { frozenEdges = { e(23) }, frozenNodes = {}, depots = {} },
  [e(32)] = { frozenEdges = { e(33) }, frozenNodes = {}, depots = {} },
  [e(50)] = { frozenEdges = { e(52) }, frozenNodes = {}, depots = { e(51) }, fileName = "depot/truck.con",
    transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 900, 900, 0, 1 } } }
LINES = { [e(40)] = { stops = { e(10), e(20), e(30) }, vehicles = { e(41), e(42) } }, [e(60)] = { stops = { e(30), e(20) }, vehicles = { e(61) } } }
DEPOTVEH = { [e(51)] = { e(53) } }
TV, LOAD = {}, {}
NAMES[e(10)], NAMES[e(20)], NAMES[e(30)], NAMES[e(40)], NAMES[e(60)], NAMES[e(50)] = "Mine", "Mill", "Port", "Coal", "Ore", "Garage"
NAMES[P1], NAMES[P2], NAMES[P3] = "Host Co", "Bob Co", "Carl Co"
for _, n in ipairs({ 10, 11, 12, 13, 14, 15, 20, 21, 22, 23, 40, 41, 42, 50, 51, 52, 53, 60, 61 }) do OWN[e(n)] = P1 end
for _, n in ipairs({ 30, 31, 32, 33 }) do OWN[e(n)] = P3 end
BAL[P1], BAL[P2], BAL[P3] = 1000000, 1000000, 1000000
NOW = 0
local function keys(t) local out = {} for k in pairs(t) do out[#out + 1] = k end table.sort(out) return out end
CARGO = { COAL = 3, PASSENGERS = 0 }
api = {
  type = {
    JournalEntry = { new = function() return { category = {} } end, Type = { OTHER = 1, ACQUISITION = 3, MAINTENANCE = 4, INCOME = 5 } },
    Vec3f = { new = function() return {} end },
    ComponentType = { PLAYER_OWNED = "po", NAME = "name", LINE = "line", CONSTRUCTION = "con", STATION_GROUP = "sg",
      TRANSPORT_VEHICLE = "tv" },
    enum = { TransportVehicleState = { IN_DEPOT = 0, EN_ROUTE = 1, AT_TERMINAL = 2 } },
  },
  util = { getDefaultMonthDuration = function() return 20000 end },
  res = { cargoTypeRep = {
    find = function(n) return CARGO[n] or -1 end, getPassengerCargoTypeId = function() return 0 end,
    get = function(id) for n, i in pairs(CARGO) do if i == id then return { name = n:sub(1, 1) .. n:sub(2):lower() } end end end,
    getName = function(id) for n, i in pairs(CARGO) do if i == id then return n end end end,
    getAll = function() return { [0] = {}, [3] = {} } end } },
  cmd = {
    sendCommand = function(c) CMDS[#CMDS + 1] = c end,
    makeEntitySetPlayerCmd = function(x, p) OWN[x] = p; return { kind = "owner", e = x, p = p } end,
    makeJournalBookAssetCmd = function(ent, je) BAL[ent] = (BAL[ent] or 0) + je.amount; return { kind = "book" } end,
  },
  engine = {
    getComponent = function(x, ct)
      if ct == "po" then return OWN[x] and { player = OWN[x] } or nil end
      if ct == "name" then return { name = NAMES[x] or ("E" .. x) } end
      if ct == "line" then
        local l = LINES[x]
        if not l then return nil end
        local s = {}
        for i, sg in ipairs(l.stops) do s[i] = { stationGroup = sg } end
        return { stops = s }
      end
      if ct == "con" then return CONS[x] end
      if ct == "sg" then return SG[x] and { stations = SG[x] } or nil end
      if ct == "tv" then return TV[x] end
      return nil
    end,
    util = { finance = { getPlayersBalance = function(p) return BAL[p] or 0 end } },
    system = {
      lineSystem = { getLinesForPlayer = function(p) local r = {} for _, l in ipairs(keys(LINES)) do if OWN[l] == p then r[#r + 1] = l end end return r end },
      transportVehicleSystem = { getLineVehicles = function(l) return LINES[l] and LINES[l].vehicles or {} end,
        getDepotVehicles = function(d) return DEPOTVEH[d] or {} end, getVehiclesForPlayer = function() return {} end },
      streetConnectorSystem = { getConstructionEntityForStation = function(s) return CONOF[s] or -1 end,
        getConstructionEntityForDepot = function(d) return e(50) end },
      simEntityAtVehicleSystem = { getVehicleSimEntitiesCountForCargoType = function(v, cid) return LOAD[v] or 0 end },
    },
  },
}
R = { allEdges = function() return {} end, withoutAssets = function(l) return l end,
  entitiesWith = function(name)
    if name == "STATION_GROUP" then return keys(SG) end
    if name == "CONSTRUCTION" then return keys(CONS) end
    if name == "LINE" then return keys(LINES) end
    return {}
  end,
  sgKey = function(sg) return "sg:" .. tostring(NAMES[sg]) end, ownerOf = function(x) return OWN[x] end }
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function logHas(s) for _, l in ipairs(LOGS) do if l:find(s, 1, true) then return true end end return false end
function gameTime() return NOW end
STEP = 200
BS = "/"
TAB, NL = "\t", "\n"
function coBook(ent, je) BAL[ent] = (BAL[ent] or 0) + je.amount end
function T(fr, en) if LANG == "fr" then return fr end return en end
C = { ROLE = "host", DIR = "D", BS = "/", NL = "\n", CR = "\r", T = T, Tf = function(fr, en) return en end,
  IO = { open = function(path, mode)
    if mode == "wb" then local buf = {} return { write = function(_, s) buf[#buf + 1] = s end, close = function() FILEDATA[path] = table.concat(buf) end } end
    local s = FILEDATA[path]
    if not s then return nil end
    return { read = function() return s end, close = function() end }
  end } }
C.eco = function() return E end
C.feat = function() return F end
SIM = { ecoEnv = function() return ECOENV end }
G = { me = "Host", myCo = 1, cmode = "separate" }
G.coEvent = function(name, param) EVENTS[#EVENTS + 1] = { name = name, param = param } end
G.featChat = function(t) CHATS[#CHATS + 1] = t return true end
-- (the window)
U = { isHost = function(s) return s and s.host == true end, winChanged = function() end }
LINESENT = {}
function sendLine(kind, p) LINESENT[#LINESENT + 1] = { kind = kind, p = p } end
function money(n) return tostring(n) end
K = { TEXT_W = 556, ICON_SETTINGS = "i" }
function K.text(t, class, cls, w) return { kind = "text", t = tostring(t), cls = cls } end
function K.muted(t) return { kind = "muted", t = tostring(t) } end
function K.section(icon, t) return { kind = "section", t = t } end
function K.gap() return { kind = "gap" } end
function K.row(c) return { kind = "row", c = c } end
function K.col(c) return { kind = "col", c = c } end
function K.btn(label, tip, fn, primary, enabled) return { kind = "btn", t = label, fn = fn, enabled = enabled ~= false } end
'''

SETUP2 = r'''
st = { co = { mode = "separate", canon = P1, list = {
  { id = 1, key = "host", name = "Host Co", ent = P1, members = { { key = "host" } }, chief = "host" },
  { id = 2, key = "bob", name = "Bob Co", ent = P2, members = { { key = "bob" } }, chief = "bob" },
  { id = 3, key = "carl", name = "Carl Co", ent = P3, members = { { key = "carl" } }, chief = "carl" },
}, stationRule = { ["sg:Mine"] = { rule = "toll", fee = 500, co = 1 }, ["sg:Port"] = { rule = "toll", fee = 300, co = 3 } },
  vstop = { ["1"] = 0 } } }
ECOENV = { log = log, CO = CO, R = R, STEP = 200, gameTime = gameTime }
F.loader = function(id) if id == "trade" then return assert(load(TRADESRC, "=trade"))() end return nil end
F.load(log)
TR = F.byId.trade
B = SIM.featBridge()
GB = G.featBridge()
function ev(name, param) F.simEvent(st, name, param, B) end
function steps(n) local ch = false for i = 1, (n or 1) do NOW = NOW + 200; if F.simTick(st, B) then ch = true end end return ch end
function S() return st.feat and st.feat.trade end
function owners(list) local t = {} for _, n in ipairs(list) do t[#t + 1] = tostring(OWN[n + OFF] and (OWN[n + OFF] - OFF)) end return table.concat(t, " ") end
function moneyOf() return (BAL[P1] - 1000000) .. " " .. (BAL[P2] - 1000000) .. " " .. (BAL[P3] - 1000000) end
GUINOW = 100
function gui(me, myCo) G.me, G.myCo = me, myCo; GUINOW = GUINOW + 2; F.gui(st, G.featBridge(), GUINOW) end
function file() return FILEDATA["D/feat_trade_trade.txt"] end
'''


def game2(off):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.globals().OFF = off
    L.execute(WORLD2)
    g = L.globals()
    g.CO = L.execute(read("mpfever_co.lua"))
    g.E = L.execute(read("mpfever_eco.lua"))
    g.F = L.execute(read("mpfever_feat.lua"))
    g.TRADESRC = SRC
    L.execute(SIMB_SRC)
    L.execute(GUIB_SRC)
    L.execute(GREQ_SRC)
    L.execute(WIN_SRC)
    L.execute(SETUP2)
    return L


A2, B2 = game2(0), game2(5000)


def both2(code):
    return run(A2, code), run(B2, code)


def same2(what):
    sa, sb = run(A2, 'return ser(S() or {}, { here = true })'), run(B2, 'return ser(S() or {}, { here = true })')
    ma, mb = run(A2, "return moneyOf()"), run(B2, "return moneyOf()")
    check(sa == sb and ma == mb, "integrated, the two games agree: " + what + ("" if sa == sb else "\n          A " + sa + "\n          B " + sb)
          + ("" if ma == mb else "\n          money A " + ma + " / B " + mb))


for L2 in (A2, B2):
    L2.execute(r'''
function ser(t, skip)
  if type(t) ~= "table" then return type(t) == "string" and string.format("%q", t) or tostring(t) end
  local keys = {}
  for k in pairs(t) do if not (skip and skip[k]) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(t[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
''')

print("integrated: all options off")
both2('''
ev("f_trade_offer", { to = 2, kind = "depot", key = "D:depot/truck.con@900,900", price = 5, mpfCo = 1, mpfFrom = "Host" })
CH0 = steps(200)
gui("Host", 1)
''')
check(run(A2, 'return st.feat == nil and CH0 == false and #CMDS == 0 and #EVENTS == 0 and next(FILEDATA) == nil and moneyOf() == "0 0 0"') is True,
      "no state, no command, no event, no file, no money: " + str(run(A2, "return logHas('are off')")))

print("integrated: the host's options, the lots through the bridge")
both2('ev("f_opts", { s = "contracts=1;sales=1", mode = "separate", mpfFrom = "Host" })')
check(run(A2, 'return st.optsText') == "contracts=1;sales=1", "the host's f_opts switches both options on")
lots_a = run(A2, 'local t = {} for _, l in ipairs(B.lots(st, 1)) do t[#t + 1] = l.kind .. "=" .. l.key .. "/" .. tostring(l.vehicles or "") end return table.concat(t, " ")')
lots_b = run(B2, 'local t = {} for _, l in ipairs(B.lots(st, 1)) do t[#t + 1] = l.kind .. "=" .. l.key .. "/" .. tostring(l.vehicles or "") end return table.concat(t, " ")')
check(lots_a == lots_b and "line=L:Coal|sg:Mine;sg:Mill;sg:Port/2" in lots_a and "depot=D:depot/truck.con@900,900/" in lots_a and "station=sg:Mine/" in lots_a,
      "SIM.featBridge.lots: mpfever_eco.lua's lots, the same keys on both games: " + lots_a)
check(run(A2, 'return F.simEnv(TR, st, B).lots(1)[1].key == B.lots(st, 1)[1].key and F.guiEnv(TR, st, GB).lots(1) ~= nil and F.guiEnv(TR, st, GB).T("a", "b") == "b"') is True,
      "the modules' env: lots in both halves, T in the interface half")

print("integrated: a line sold with its stations and their own tracks")
both2('ev("f_trade_offer", { to = 2, kind = "line", key = "L:Coal|sg:Mine;sg:Mill;sg:Port", price = 250000, mpfCo = 1, mpfFrom = "Host" })')
check(run(A2, 'return #S().offers == 1 and S().offers[1].nveh == 2') is True, "the offer is kept, the line has 2 vehicles")
both2('ev("f_trade_answer", { id = 1, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })')
check(run(A2, 'return owners({ 40, 41, 42 })') == "200 200 200", "the line and its trucks are company 2's")
check(run(A2, 'return owners({ 10, 11, 12, 13, 14, 15, 20, 21, 22, 23 })') == "200 200 200 200 200 200 200 200 200 200",
      "the seller's stations of its stops, their buildings, own tracks and node are company 2's: " + run(A2, 'return owners({ 10, 11, 12, 13, 14, 15, 20, 21, 22, 23 })'))
check(run(A2, 'return owners({ 30, 31, 32, 33, 50, 51, 52, 53, 60, 61 })') == "300 300 300 300 100 100 100 100 100 100",
      "a third company's station on the line, the depot and the other line stay where they were")
check(run(A2, 'return moneyOf()') == "250000 -250000 0", "the buyer paid the seller 250 000 (through the bridge's book)")
check(run(A2, 'return st.co.stationRule["sg:Mine"] == nil and st.co.stationRule["sg:Port"] ~= nil and st.co.vstop == nil') is True,
      "the stations sold lose their own setting (as an auction's lot), a third company's keeps its own; the stops read afresh")
check(run(A2, 'return logHas("2 station(s) of its stops, 4 own track(s) and node(s): 13 change hands")') is True,
      "mpfever_eco.lua logs what changed hands")
same2("after the line's sale (their entity ids differ)")

print("integrated: a depot sold with the truck in it, a refusal of a lot that changed")
both2('''
ev("f_trade_offer", { to = 3, kind = "depot", key = "D:depot/truck.con@900,900", price = 40000, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_answer", { id = S().seq, accept = true, mpfCo = 3, mpfFrom = "Carl#2" })
''')
check(run(A2, 'return owners({ 50, 51, 52, 53 })') == "300 300 300 300" and run(A2, 'return moneyOf()') == "290000 -250000 -40000",
      "the depot, its truck and its own track are company 3's; 40 000 paid")
both2('''
ev("f_trade_offer", { to = 2, kind = "line", key = "L:Ore|sg:Port;sg:Mill", price = 1000, mpfCo = 1, mpfFrom = "Host" })
LINES[60 + OFF].vehicles[2] = 62 + OFF; OWN[62 + OFF] = P1
ev("f_trade_answer", { id = S().seq, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })
LINES[60 + OFF].vehicles[2] = nil; OWN[62 + OFF] = nil
''')
check(run(A2, 'return owners({ 60, 61 })') == "100 100" and run(A2, 'return S().news[#S().news].kind') == "changed" and run(A2, 'return moneyOf()') == "290000 -250000 -40000",
      "a line that got a truck since its offer: refused, nothing moves")
same2("after the depot and the refusal")

print("integrated: a supply contract, the measure, the host's figures")
both2('''
ev("f_trade_ct_offer", { to = 2, role = "supply", station = "sg:Mill", cargo = "COAL", per = 50, price = 10, penalty = 2, months = 3, mpfCo = 1, mpfFrom = "Host" })
ev("f_trade_ct_answer", { id = S().seq, accept = true, mpfCo = 2, mpfFrom = "Bob#1" })
''')
check(run(A2, 'return S().ct[1].state == "active" and S().ct[1].label == "Mill" and S().ct[1].payer == 2') is True,
      "company 1 delivers coal at Mill, which company 2 bought: signed (the module's own station read, M.rt.station)")
# (the Ore line's truck: stop index 1 of its line is Mill)
both2('steps(1); TV[61 + OFF] = { state = 1, stopIndex = 1 }; LOAD[61 + OFF] = 40; CH1 = steps(1); CH2 = steps(1)')
check(run(A2, 'return CH1 == true and CH2 == false and S().here.trk ~= nil') is True,
      "the tick says when it changed the measure (a truck followed), and not when nothing changed (the state is saved only then)")
both2('TV[61 + OFF] = { state = 2, stopIndex = 1 }; LOAD[61 + OFF] = 10; steps(1); TV[61 + OFF] = { state = 1, stopIndex = 0 }; CH3 = steps(1)')
check(run(A2, 'return CH3 == true and S().here.cur[tostring(S().ct[1].id)]') == 30, "the truck unloaded 30 at Mill: counted (M.rt.watch, vehicle, load)")
check(run(A2, 'return logHas("feat trade: contract") and logHas("vehicle(s) of company 1") and logHas("having unloaded 30 COAL")') is True,
      "the measure's log lines for the in-game check")
both2('NOW = 59800; steps(2)')
check(run(A2, 'return S().due == 2 and S().here.last[tostring(S().ct[1].id)] == 30') is True, "the month's turn: month 2 is due, its count kept")
run(B2, 'EVENTS = {}; C.ROLE = "client"; gui("Bob#1", 2)')
check(run(B2, 'local n = 0 for _, x in ipairs(EVENTS) do if x.name == "f_trade_pay" then n = n + 1 end end return n') == 0, "a client's game sends no figures")
run(A2, 'EVENTS = {}; gui("Host", 1)')
pay = run(A2, 'for _, x in ipairs(EVENTS) do if x.name == "f_trade_pay" then return ser(x.param) end end')
check(pay is not None, "the host's game sends its figures through G.coEvent (G.featBridge.send): " + str(pay))
for L2 in (A2, B2):
    L2.globals().PAYTXT = pay
check(run(A2, 'local p = load("return " .. PAYTXT)() return p.month == 2 and p.ct[1].n == 30 and p.ct[1].lost == nil') is True, "its figures: month 2, 30 delivered")
both2('local p = load("return " .. PAYTXT)(); p.mpfFrom = "Host"; ev("f_trade_pay", p)')
check(run(A2, 'return moneyOf()') == "290300 -250300 -40000", "the month of the signature: 30 x 10 paid, no penalty")
same2("after the contract's first month")

print("integrated: the window (U.featTabRows, the real tab), its buttons through G.featRequest")
both2('ev("f_trade_offer", { to = 1, kind = "station", key = "sg:Mine", price = 0, mpfCo = 2, mpfFrom = "Bob#1" })')
run(A2, '''
STS = { mode = "separate", opts = "contracts=1;sales=1" }
CHATS = {}
gui("Host", 1)
ROWS = U.featTabRows(K, STS, "f_trade")
''')
check(run(A2, 'return file() ~= nil and file():find("me\\t1\\t1\\t1\\t1", 1, true) == 1') is True, "the interface half writes feat_trade_trade.txt (G.featBridge.write)")
check(run(A2, 'return #LINESENT == 1 and LINESENT[1].kind == "feat_req" and LINESENT[1].p.m == "trade" and LINESENT[1].p.kind == "look"') is True,
      "drawing the tab asks the module to look at the world (ui.log feat_req)")
run(A2, 'G.featSt = st; G.featRequest(LINESENT[1].p); gui("Host", 1); ROWS = U.featTabRows(K, STS, "f_trade")')
check(run(A2, 'return file():find("\\nlot\\tdepot", 1, true) == nil and file():find("\\nlot\\tline\\tL:Ore", 1, true) ~= nil') is True,
      "after the look, its lots are in the file (the depot sold is not)")
txt = run(A2, '''
local out = {}
local function walk(n)
  if n.kind == "row" then local t = {} for _, c in ipairs(n.c) do t[#t + 1] = "[" .. tostring(c.t) .. (c.enabled and "" or " off") .. "]" end out[#out + 1] = table.concat(t, " ")
  elseif n.t then out[#out + 1] = n.t end
end
for _, n in ipairs(ROWS) do walk(n) end
return table.concat(out, "\\n")
''')
check("Bob Co offers you station « Mine » for $0." in txt and "[Accept] [Refuse]" in txt and "Sales between companies" in txt and "Supply contracts" in txt,
      "the tab shows the offer received, its buttons, the sections")
check("[Sell…]" in txt and "[Cancel the contract]" in txt, "the chief's sell buttons, the running contract's cancel")
check("Contract of Host Co for Bob Co: 30/50 Coal delivered, $300 paid." in txt and "30 last month" in txt,
      "the month paid in the news: the units delivered (not the news's number)")
run(A2, '''
LINESENT, EVENTS = {}, {}
for _, n in ipairs(ROWS) do if n.kind == "row" then for _, c in ipairs(n.c) do if c.t == "Accept" then c.fn() end end end end
for _, l in ipairs(LINESENT) do G.featRequest(l.p) end
''')
ans = run(A2, 'for _, x in ipairs(EVENTS) do if x.name == "f_trade_answer" then return x.param end end')
check(ans is not None and ans.accept is True and ans.id == run(A2, 'return S().offers[1].id'),
      "Accept: the window's request, G.featRequest, the module's chief check, then the event sent (G.coEvent)")
run(A2, 'LINESENT, EVENTS, CHATS = {}, {}, {}; G.me, G.myCo = "Dan#3", 2')
run(A2, 'for _, n in ipairs(ROWS) do if n.kind == "row" then for _, c in ipairs(n.c) do if c.t == "Accept" then c.fn() end end end end for _, l in ipairs(LINESENT) do G.featRequest(l.p) end')
check(run(A2, 'return #EVENTS == 0 and #CHATS == 1') is True, "a player who is not the chief: nothing sent, told why in this game's chat")
run(A2, 'G.me, G.myCo = "Host", 1')

print("integrated: the auction's sale is the same as before (E.transferLot without options)")
run(A2, '''
for _, n in ipairs({ 10, 11, 12, 13, 14, 15, 20, 21, 22, 23, 40, 41, 42 }) do OWN[n + OFF] = P1 end
st.co.stationRule["sg:Mine"] = { rule = "toll", fee = 500, co = 1 }
st.co.vstop = { ["1"] = 0 }
E.env = ECOENV
local n = E.transferLot(ECOENV, st.co.list[1], st.co.list[2], { kind = "line", key = "L:Coal|sg:Mine;sg:Mill;sg:Port", label = "Coal" })
TRN = n
''')
check(run(A2, 'return TRN == 3 and owners({ 40, 41, 42 }) == "200 200 200" and owners({ 10, 11, 12, 13, 20, 23 }) == "100 100 100 100 100 100"') is True,
      "without options: the line and its vehicles only, as the auction sold them (no station, no own track)")
check(run(A2, 'return st.co.stationRule["sg:Mine"] ~= nil and st.co.vstop ~= nil') is True, "and nothing of the registry touched")
run(A2, '''
for _, n in ipairs({ 40, 41, 42 }) do OWN[n + OFF] = P1 end
st.co.list[1].gone = nil
-- (0.7.4: the auction of 0.7.3, one lot after the other: the host's rule "serial")
st.co.rules = st.co.rules or {}
st.co.rules.auction = "serial:5"
E.bankrupt(st, st.co.list[1], ECOENV, 1)
E.event(st, "co_bid", { seq = st.co.auction.seq, lot = 1, amount = 100000, mpfCo = 2, mpfFrom = "Bob#1" }, ECOENV)
BEFORE = BAL[P2]
E.event(st, "co_lot_close", { seq = st.co.auction.seq, lot = 1, mpfFrom = "Host" }, ECOENV)
''')
check(run(A2, 'return owners({ 40, 41, 42, 10, 13 }) == "200 200 200 100 100" and BAL[P2] == BEFORE - 100000') is True,
      "an auction's lot sold: the line and its vehicles change hands, the bid booked, as before")

print("sales: a computer company sells a station it no longer uses (0.7.5)")
C = new_game(0)
run(C, '''
OPTS.sales = true
ev("f_trade_offer", { to = 1, kind = "station", key = "c:ai@7,7#0", price = 15000, mpfCo = 4, mpfFrom = "Host" })
''')
check(run(C, 'local o = S() and S().offers[1] return o ~= nil and o.from == 4 and o.to == 1 and o.kind == "station" and o.price == 15000') is True,
      "the computer company's offer (sent by the host's game, it has no chief) is open for company 1")
run(C, '''
ev("f_trade_answer", { id = 1, accept = true, mpfCo = 1, mpfFrom = "Host" })
''')
check(run(C, 'return #S().offers == 0 and #TRANSFERS == 1 and TRANSFERS[1].from == 4 and TRANSFERS[1].to == 1 and TRANSFERS[1].key == "c:ai@7,7#0"') is True,
      "company 1's chief accepts: the station goes from the computer company to company 1")
check(run(C, 'local paid, got = 0, 0 for _, b in ipairs(BOOKS) do if b.amount == -15000 then paid = paid + 1 end if b.amount == 15000 then got = got + 1 end end return paid == 1 and got == 1') is True,
      "the buyer paid 15 000, the computer company got it")
run(C, '''
ev("f_trade_offer", { to = 4, kind = "depot", key = "D:truck@9,9", price = 5, mpfCo = 1, mpfFrom = "Host" })
''')
check(run(C, 'return #S().offers == 0 and logHas("buyer 4")') is True, "a computer company still never buys")

if failures:
    print(f"FAIL {len(failures)} case(s):")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("all cases passed")
sys.exit(0)
