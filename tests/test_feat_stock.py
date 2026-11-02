"""The 0.6 game option "stock" (mod/mpfever_1/content/mpfever_feat_stock.lua), offline: the module is loaded through lupa
(Lua 5.2) with the options host's env mocked as docs/FEATURES-0.6.md describes it (env.on, env.param, env.state, env.mode,
env.co, env.book, env.month, env.send, env.write, env.chat, env.isHost, env.myCo, env.realTime...), plus env.coMerge (the
merge of companies the takeover asks the integration for).

Cases: the option off and the shared mode (no state, no event, no money, no file); the host's monthly prices (host only, sent
again after 15 s, refused from a client, applied once); purchases (money to the company bought, D5), the monthly limit,
the float, the protection (24 months for a new company, up to the game's 24th month at the opening); buy-backs (money to the
market, no dividend); dividends (rate of the month's result, never more than the company's money); sales (at most what was
paid, less 2 %, within the company's money); takeovers (premium, holders paid, the rest to the market, the merge called with
the members released, a computer company retired, refused when the host does not allow it); companies gone (bankrupt:
shares cancelled; merged: holders paid back; holdings follow the company it went into); determinism (the same events on two
games with other entity numbers and another table order give the same state and the same money); a savegame reload in the
middle (plain data, no function, no cycle); the interface's half (requests, the window's file, the tab).
Integration, with the real files and the game's API mocked: mpfever_eco.lua's merge (E.merge unchanged without opts, E.coMerge
with the members released and "taken", the savegame's company keeping the money of its game loans, MPFEVER_STOCKMERGE=0), then
the real options host, the bridge's real helpers (SIM.featBridge and its coMerge, SIM.featTick, SIM.featEvent, G.featBridge,
G.featChat, G.featRequest, G.coNewsText) and mpfever_ai.lua's retired check: f_opts, the host's monthly prices, purchases from
the window's requests, a computer company taken over and retired; and the window's real tab code (U.featU, U.featTabRows).
Run: python tests/test_feat_stock.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_stock.lua")
SRC = open(MODULE, encoding="utf-8").read()

failures = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        failures.append(what)


# One game: the module, a registry (company ids 1..5, this game's entities base+id*100), the options, the books (by company
# id: the entities differ between games), the merges asked, the events sent, the files written and the chat.
GAME = r'''
local SRC, BASE, SHUFFLE = ...
api = nil
M = assert(load(SRC, "mpfever_feat_stock.lua"))()
OPTS = { stock = false }
PARAMS = {}
MONTH = 100
REAL = 0
BOOKS, LOGS, MERGES, SENT, WRITES, CHATS = {}, {}, {}, {}, {}, {}
BAL = {}
local function co(id, k, name, extra)
  local c = { id = id, key = k, name = name, color = id, ent = BASE + id * 100, members = { { key = k } }, chief = k }
  for a, b in pairs(extra or {}) do c[a] = b end
  return c
end
st = { co = { mode = "separate", canon = BASE + 100, start = 2000000, rules = { start = 2000000 },
  list = { co(1, "host", "Host Co"), co(2, "bob", "Bob Co"), co(3, "carl", "Carl Co"), co(4, "ai:1", "Robot Co") } } }
-- (another table order on this game: keys put in and taken out again change the order pairs() gives)
if SHUFFLE then
  local junk = {}
  for i = 1, 50 do junk["k" .. i] = i end
  for i = 1, 50, 2 do junk["k" .. i] = nil end
end
function idOf(ent) for _, c in ipairs(st.co.list) do if c.ent == ent then return c.id end end return -1 end
function addCompany(id, k, name) st.co.list[#st.co.list + 1] = co(id, k, name) end
function setGone(id, how, into) for _, c in ipairs(st.co.list) do if c.id == id then c.gone = how; c.mergedInto = into; c.members = {} end end end
env = {
  log = function(s) LOGS[#LOGS + 1] = s end, gameTime = function() return MONTH * 1000 end, STEP = 200,
  on = function(id) return OPTS[id] == true end,
  param = function(id, pid)
    local v = PARAMS[pid]
    if v ~= nil then return v end
    for _, o in ipairs(M.OPTIONS) do if o.id == id then for _, p in ipairs(o.params or {}) do if p.id == pid then return p.default end end end end
    return nil
  end,
  state = function(s) s.feat = s.feat or {}; s.feat[M.ID] = s.feat[M.ID] or {}; return s.feat[M.ID] end,
  mode = "separate",
  month = function() return MONTH end,
  every = function() return false end,
  book = function(ent, amount)
    assert(math.floor(amount) == amount, "a whole amount")
    BOOKS[#BOOKS + 1] = idOf(ent) .. ":" .. string.format("%.0f", amount)
    BAL[ent] = (BAL[ent] or 0) + amount
  end,
  money = function(ent) return BAL[ent] or 0 end,
  coMerge = function(from, into, opts)
    MERGES[#MERGES + 1] = from .. ">" .. into .. ":" .. tostring(opts and opts.members) .. ":" .. tostring(opts and opts.gone)
    for _, c in ipairs(st.co.list) do
      if c.id == from then c.gone = opts.gone; c.mergedInto = into; c.formerMembers = { c.key }; c.members = {}; c.chief = nil end
    end
    return true
  end,
}
env.co = st.co
-- the GUI half's env (this game's player: company MYCO)
genv = {
  log = function(s) LOGS[#LOGS + 1] = s end,
  on = env.on, param = env.param, isHost = false, me = "Host", myCo = 1,
  send = function(name, param) SENT[#SENT + 1] = { name = name, param = param } end,
  chat = function(t) CHATS[#CHATS + 1] = t end,
  write = function(file, lines) WRITES[#WRITES + 1] = { file = file, text = table.concat(lines, "\n") } end,
  realTime = function() return REAL end,
}
-- the host's measure, replaced (the integration's figures): FIG[id] = { v, r, c }
FIG = {}
AGE = 30
M.exists = function() return true end
M.scan = function() return {} end
M.clock = function() return 0, 0 end
M.measure = function(c) return FIG[c.id] end
M.age = function() return AGE end
BALANCE = 1e12
M.balanceOf = function() return BALANCE end
-- an event of company `co` sent by `from`
function ev(name, param, from, co)
  param = param or {}
  param.mpfFrom, param.mpfCo = from, co
  M.event(st, name, param, env)
end
function S() return st.feat and st.feat.stock end
function hold(t, h) local s = S(); return s and s.hold and s.hold[tostring(t)] and s.hold[tostring(t)][tostring(h)] or 0 end
function price(t) local s = S(); return s and s.price and s.price[tostring(t)] end
function lastLog() return LOGS[#LOGS] or "" end
function nbooks() return #BOOKS end
function book(i) return BOOKS[i] end
-- the state as text: sorted, plain data only, every table once (no cycle, no table shared by two places)
function ser(v, seen)
  seen = seen or {}
  local t = type(v)
  if t == "table" then
    assert(not seen[v], "a table found twice (cycle or shared)")
    seen[v] = true
    local keys = {}
    for k in pairs(v) do
      assert(type(k) == "string" or type(k) == "number", "key of type " .. type(k))
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return (type(a) .. tostring(a)) < (type(b) .. tostring(b)) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = "[" .. ser(k, seen) .. "]=" .. ser(v[k], seen) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  elseif t == "number" then return string.format("%.17g", v)
  elseif t == "boolean" then return tostring(v)
  end
  error("not plain data: " .. t)
end
function reload()
  st.feat.stock = assert(load("return " .. ser(st.feat.stock)))()
end
'''


def new_game(base, shuffle=False):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    loader = L.eval("function(code, src, base, shuffle) return assert(load(code))(src, base, shuffle) end")
    loader(GAME, SRC, base, shuffle)
    return L


def run(L, code):
    return L.eval("function(c) return assert(load(c))() end")(code)


# ---------------------------------------------------------------------------------------------------------------- off
print("the option off: nothing happens")
A = new_game(0)
run(A, '''
M.month(st, env)
ev("f_stock_price", { month = 100, rows = "1,5000000,0,5000000" }, "Host", 1)
ev("f_stock_buy", { co = 2, n = 1 }, "Bob#1", 2)
ev("f_stock_sell", { co = 1, n = 1 }, "Bob#1", 2)
genv.isHost = true; REAL = 100
M.gui(st, genv)
local ok = M.request("buy", { co = 2, n = 1 }, st, genv)
''')
check(run(A, "return st.feat == nil"), "no state")
check(run(A, "return #BOOKS + #SENT + #WRITES + #CHATS + #MERGES") == 0, "no money, no event, no file, no chat")

print("the shared mode: nothing happens either")
run(A, '''OPTS.stock = true; env.mode = "shared"; st.co.mode = "shared"
M.month(st, env)
ev("f_stock_price", { month = 100, rows = "1,5000000,0,5000000" }, "Host", 1)
M.gui(st, genv)''')
check(run(A, "return st.feat == nil and #BOOKS + #SENT + #WRITES + #CHATS == 0"), "no state, money, event or file in the shared mode")

print("the options of the lobby")
check(run(A, "return M.ID") == "stock" and run(A, "return M.OPTIONS[1].id") == "stock", "module stock, option stock")
check(run(A, "return M.OPTIONS[1].modes") == "separate", "separate mode only")
check(run(A, '''local ok = true
for _, p in ipairs(M.OPTIONS[1].params) do
  local found = false
  for _, v in ipairs(p.values) do if v == p.default then found = true end end
  ok = ok and found and type(p.label[1]) == "string" and type(p.label[2]) == "string" and type(p.show(p.default, function(fr, en) return en end)) == "string"
end
return ok and #M.OPTIONS[1].params == 3 and M.OPTIONS[1].title[1] == "Bourse" and M.OPTIONS[1].desc[2] ~= nil'''), "3 parameters, defaults among the values, French and English")
check(run(A, '''local d = {} for _, p in ipairs(M.OPTIONS[1].params) do d[p.id] = p.default end
return d.premium == 25 and d.ai_buyable == 1 and d.dividend == 25'''), "defaults: premium 25 %, computer companies can be taken over, dividends 25 %")
check(run(A, 'for k in pairs(M.EVENTS) do if k:sub(1, 8) ~= "f_stock_" then return false end end return true'), "events named f_stock_*")


# ------------------------------------------------------------------------------------------------- one scripted session
# The same session is played on two games (other entities, other table order); game A also saves and loads its state in the
# middle. Returns nothing: the checks run on game A, the comparison after.
def session(G, label, do_checks, do_reload):
    c = check if do_checks else (lambda cond, what: None)
    run(G, 'OPTS.stock = true; env.mode = "separate"; st.co.mode = "separate"; MONTH = 100')
    # month 100: the host's figures, the opening
    run(G, "M.month(st, env)")
    c(run(G, "return S().due") == 100, label + "a new month asks for its prices (state created)")
    run(G, '''FIG = { [1] = { v = 5000000, r = 0, c = 5000000 }, [2] = { v = 2000000, r = 0, c = 2000000 },
      [3] = { v = 50000, r = 0, c = 50000 }, [4] = { v = 1000000, r = 0, c = 1000000 } }''')
    # (the host's interface: nothing until the companies have been known 5 s, then once, again after 15 s)
    run(G, "genv.isHost = true; REAL = 0; M.sentFor = nil; M.sentAt = nil; M.triedAt = nil; M.seenAt = nil; M.gui(st, genv)")
    c(run(G, "return #SENT") == 0, label + "the host waits until it can read the companies")
    run(G, "REAL = 6; M.gui(st, genv)")
    c(run(G, "return #SENT == 1 and SENT[1].name == 'f_stock_price' and SENT[1].param.month == 100"), label + "the host sends the month's prices")
    c(run(G, "return SENT[1].param.rows") == "1,5000000,0,5000000;2,2000000,0,2000000;3,50000,0,50000;4,1000000,0,1000000", label + "rows id,value,result,cash")
    run(G, "REAL = 9; M.gui(st, genv)")
    c(run(G, "return #SENT") == 1, label + "not sent again before 15 s")
    run(G, "REAL = 22; M.gui(st, genv)")
    c(run(G, "return #SENT") == 2, label + "sent again after 15 s while not applied")
    run(G, "genv.isHost = false; REAL = 60; M.gui(st, genv)")
    c(run(G, "return #SENT") == 2, label + "a client's game never sends prices")
    rows = run(G, "return SENT[1].param.rows")
    run(G, "AGE = 30")
    ev = "ev('f_stock_price', { month = 100, rows = %r, age = AGE }, %r, %d)"
    run(G, ev % (rows, "Bob#1", 2))
    c(run(G, "return S().month") is None, label + "prices from a client: refused")
    run(G, ev % (rows, "Host", 1))
    c(run(G, "return S().month") == 100, label + "prices from the host: applied")
    c(run(G, "return price(1)") == 500000 and run(G, "return price(2)") == 200000, label + "price = value / 10")
    c(run(G, "return price(3)") == 10000, label + "never below the floor (start money / 200)")
    c(run(G, "return S()['until']['1']") == 100, label + "the opening in a game older than 24 months: not protected")
    run(G, ev % (rows, "Host", 1))
    c(run(G, "return #BOOKS") == 0, label + "the same month again: refused, no dividend twice")
    c(run(G, "return S().news[1].kind") == "open", label + "the opening is told")

    # purchases of month 100
    run(G, "ev('f_stock_buy', { co = 1, n = 1 }, 'Bob#1', 2)")
    c(run(G, "return hold(1, 2)") == 1, label + "Bob's company buys 1 share of company 1")
    c(run(G, "return BOOKS[1] == '2:-500000' and BOOKS[2] == '1:500000'"), label + "the money goes to the company bought (D5)")
    run(G, "ev('f_stock_buy', { co = 1, n = 2 }, 'Bob#1', 2)")
    c(run(G, "return hold(1, 2)") == 1 and "monthly limit" in run(G, "return lastLog()"), label + "no more than 2 shares a month of one company")
    run(G, "ev('f_stock_buy', { co = 1, n = 1 }, 'Bob#1', 2)")
    c(run(G, "return hold(1, 2)") == 2, label + "the second share of the month")
    run(G, "ev('f_stock_buy', { co = 3, n = 1 }, 'Bob#1', 2)")
    c(run(G, "return hold(3, 2)") == 1, label + "a share at the floor price")
    run(G, "ev('f_stock_buy', { co = 1, n = 2 }, 'Host', 1)")
    c(run(G, "return hold(1, 1)") == 2 and run(G, "return BOOKS[#BOOKS]") == "1:-1000000", label + "a buy-back: the money goes to the market")
    run(G, "ev('f_stock_buy', { co = 4, n = 3 }, 'Carl#2', 3)")
    c(run(G, "return hold(4, 3)") == 0, label + "3 shares at once: refused")
    run(G, "ev('f_stock_buy', { co = 4, n = 2 }, 'Carl#2', 3)")
    c(run(G, "return hold(4, 3)") == 2, label + "Carl's company buys 2 shares of the computer company")
    run(G, "ev('f_stock_buy', { co = 2, n = 1 }, 'Host', 4)")
    c(run(G, "return hold(2, 4)") == 1, label + "the computer company holds a share of Bob's company")
    run(G, "ev('f_stock_buy', { co = 9, n = 1 }, 'Bob#1', 2)")
    c("no such company" in run(G, "return lastLog()"), label + "no such company: refused")
    run(G, "ev('f_stock_buy', { co = 2, n = 1 }, 'Bob#1', 2)")
    c(run(G, "return hold(2, 2)") == 1, label + "Bob's company buys back one of its own")

    if do_reload:
        run(G, "reload()")
        c(True, label + "the state saved and loaded again (plain data, no cycle)")

    # month 101: dividends, the new company, the protection
    run(G, "addCompany(5, 'dan', 'Dan Co'); MONTH = 101; M.month(st, env)")
    run(G, '''FIG[1] = { v = 5100000, r = 400000, c = 3000000 }; FIG[3] = { v = 50000, r = -5000, c = 0 }
      FIG[4] = { v = 1000000, r = 1000000, c = 30000 }; FIG[5] = { v = 2000000, r = 0, c = 2000000 }''')
    n0 = run(G, "return #BOOKS")
    run(G, "genv.isHost = true; REAL = 200; M.seenAt = nil; M.gui(st, genv); REAL = 206; M.gui(st, genv)")
    rows101 = run(G, "return SENT[#SENT].param.rows")
    c(run(G, "return SENT[#SENT].param.month") == 101 and "5,2000000" in rows101, label + "the next month's prices, the new company with them")
    run(G, ev.replace("month = 100", "month = 101") % (rows101, "Host", 1))
    c(run(G, "return price(1)") == 510000, label + "the new price")
    # company 1: d = 400000 * 25 % / 10 = 10000 a share; Bob holds 2 (its own 2 pay nothing)
    new = [run(G, "return book(%d)" % i) for i in range(n0 + 1, run(G, "return nbooks()") + 1)]
    c("1:-20000" in new and "2:20000" in new, label + "dividends: 10000 a share to the other holders only (%s)" % new)
    # company 4: 25000 a share, 2 held by Carl, but only 30000 of money: 15000 a share
    c("4:-30000" in new and "3:30000" in new, label + "dividends never more than the company's money")
    c(not any(b.startswith("3:-") for b in new), label + "a company with a loss pays no dividend")
    c(run(G, "return S()['until']['5']") == 125, label + "a new company is protected for 24 months")
    run(G, "ev('f_stock_buy', { co = 5, n = 1 }, 'Bob#1', 2)")
    c(run(G, "return hold(5, 2)") == 0 and "protected" in run(G, "return lastLog()"), label + "nobody else buys a protected company's shares")
    run(G, "ev('f_stock_buy', { co = 5, n = 1 }, 'Dan#3', 5)")
    c(run(G, "return hold(5, 5)") == 1, label + "a protected company buys its own back")
    run(G, "ev('f_stock_buy', { co = 1, n = 1 }, 'Carl#2', 3)")
    c(run(G, "return hold(1, 3)") == 1, label + "the month's purchases start again")

    # month 102: sales, Bob's share of the computer company
    run(G, "MONTH = 102; M.month(st, env)")
    run(G, "FIG[1] = { v = 5200000, r = 0, c = 3000000 }; FIG[4] = { v = 1000000, r = 0, c = 1000000 }")
    run(G, "REAL = 300; M.seenAt = nil; M.gui(st, genv); REAL = 306; M.gui(st, genv)")
    run(G, ev.replace("month = 100", "month = 102") % (run(G, "return SENT[#SENT].param.rows"), "Host", 1))
    c(run(G, "return price(1)") == 520000, label + "month 102 priced")
    n0 = run(G, "return #BOOKS")
    run(G, "ev('f_stock_sell', { co = 1, n = 1 }, 'Bob#1', 2)")
    new = [run(G, "return book(%d)" % i) for i in range(n0 + 1, run(G, "return nbooks()") + 1)]
    c(new == ["1:-490000", "2:490000"], label + "a sale: at most what was paid (500000), less 2 %%, paid by the company (%s)" % new)
    c(run(G, "return hold(1, 2)") == 1 and run(G, "return S().cost['1']['2']") == 500000, label + "the holding and its cost go down")
    run(G, "ev('f_stock_sell', { co = 3, n = 1 }, 'Bob#1', 2)")
    c(run(G, "return hold(3, 2)") == 1 and "cannot buy them back" in run(G, "return lastLog()"), label + "no sale beyond the company's money")
    n0 = run(G, "return #BOOKS")
    run(G, "ev('f_stock_sell', { co = 1, n = 1 }, 'Host', 1)")
    new = [run(G, "return book(%d)" % i) for i in range(n0 + 1, run(G, "return nbooks()") + 1)]
    c(new == ["1:490000"], label + "its own share sold to the market (%s)" % new)
    run(G, "ev('f_stock_sell', { co = 1, n = 5 }, 'Bob#1', 2)")
    c(run(G, "return hold(1, 2)") == 1, label + "more than it holds: refused")
    run(G, "ev('f_stock_buy', { co = 4, n = 1 }, 'Bob#1', 2)")
    run(G, "ev('f_stock_buy', { co = 4, n = 2 }, 'Carl#2', 3)")
    c(run(G, "return hold(4, 3)") == 4, label + "Carl's company holds 4 of the computer company")
    c(run(G, "return S().news[#S().news].kind") == "cross", label + "crossing 3 shares is told")

    # month 103: the takeover of the computer company
    run(G, "MONTH = 103; M.month(st, env)")
    run(G, "REAL = 400; M.seenAt = nil; M.gui(st, genv); REAL = 406; M.gui(st, genv)")
    run(G, ev.replace("month = 100", "month = 103") % (run(G, "return SENT[#SENT].param.rows"), "Host", 1))
    run(G, "ev('f_stock_buy', { co = 4, n = 1 }, 'Carl#2', 3)")
    c(run(G, "return hold(4, 3)") == 5, label + "5 of 10: half, no takeover yet")
    run(G, "ev('f_stock_buy', { co = 4, n = 1 }, 'Carl#2', 3)")
    c(run(G, "return hold(4, 3)") == 5 and "not confirmed" in run(G, "return lastLog()"), label + "beyond half without the takeover asked: refused")
    run(G, "PARAMS.ai_buyable = 0; ev('f_stock_buy', { co = 4, n = 1, takeover = true }, 'Carl#2', 3); PARAMS.ai_buyable = nil")
    c(run(G, "return hold(4, 3)") == 5 and "cannot be taken over" in run(G, "return lastLog()"), label + "computer companies not for takeover: refused")
    # unit = 100000 * 125 % = 125000; 5 shares Carl does not hold: 625000; Bob holds 1 of them
    run(G, "ev('f_stock_buy', { co = 4, n = 1, takeover = true, max = 600000 }, 'Carl#2', 3)")
    c(run(G, "return hold(4, 3)") == 5 and "more than the" in run(G, "return lastLog()"), label + "costs more than accepted: refused")
    n0 = run(G, "return #BOOKS")
    run(G, "ev('f_stock_buy', { co = 4, n = 1, takeover = true, max = 625000 }, 'Carl#2', 3)")
    new = [run(G, "return book(%d)" % i) for i in range(n0 + 1, run(G, "return nbooks()") + 1)]
    c(new == ["3:-625000", "2:125000"], label + "takeover: the buyer pays the rest with the premium, the holders get theirs (%s)" % new)
    c(run(G, "return MERGES[1]") == "4>3:release:taken", label + "the merge is asked: everything to the buyer, the members released")
    c(run(G, "return M.retired(st, 'ai:1')") is True, label + "the computer company is retired")
    c(run(G, "return price(4) == nil and S().hold['4'] == nil"), label + "its shares are gone")
    c(run(G, "return hold(2, 3)") == 1 and run(G, "return hold(2, 4)") == 0, label + "the shares it held are the buyer's")
    c(run(G, "return S().news[#S().news].kind") == "takeover", label + "the takeover is told")

    # month 104: companies gone (Bob's merges into Dan's; then Dan's goes bankrupt)
    run(G, "setGone(2, 'merged', 5)")
    n0 = run(G, "return #BOOKS")
    run(G, "MONTH = 104; M.month(st, env)")
    run(G, "REAL = 500; M.seenAt = nil; M.gui(st, genv); REAL = 506; M.gui(st, genv)")
    run(G, ev.replace("month = 100", "month = 104") % (run(G, "return SENT[#SENT].param.rows"), "Host", 1))
    new = [run(G, "return book(%d)" % i) for i in range(n0 + 1, run(G, "return nbooks()") + 1)]
    # Carl held 1 of Bob's (from the computer company, cost 200000): paid back by Dan's company at most what was paid
    c("5:-200000" in new and "3:200000" in new, label + "a company merged: its holders are paid back by the company it went into (%s)" % new)
    c(run(G, "return hold(1, 5)") == 1 and run(G, "return hold(1, 2)") == 0, label + "the shares a merged company held follow it")
    c(run(G, "return hold(3, 5)") == 1, label + "(all of them)")
    run(G, "setGone(5, 'bankrupt')")
    run(G, "ev('f_stock_buy', { co = 1, n = 1 }, 'Carl#2', 3)")
    c(run(G, "return hold(1, 5)") == 0 and run(G, "return hold(3, 5)") == 0, label + "a bankrupt company's holdings go back to the market")
    c(run(G, "return S().news[#S().news].kind") == "cancel", label + "the cancelled shares are told")

    # month 105: a human company taken over (its players get a new company: the members are released)
    run(G, "MONTH = 105; M.month(st, env)")
    run(G, "REAL = 600; M.seenAt = nil; M.gui(st, genv); REAL = 606; M.gui(st, genv)")
    run(G, ev.replace("month = 100", "month = 105") % (run(G, "return SENT[#SENT].param.rows"), "Host", 1))
    for m in (105, 106):
        if m == 106:
            run(G, "MONTH = 106; M.month(st, env)")
            run(G, "REAL = 700; M.seenAt = nil; M.gui(st, genv); REAL = 706; M.gui(st, genv)")
            run(G, ev.replace("month = 100", "month = 106") % (run(G, "return SENT[#SENT].param.rows"), "Host", 1))
        run(G, "ev('f_stock_buy', { co = 1, n = 2 }, 'Carl#2', 3)")
    c(run(G, "return hold(1, 3)") == 4, label + "Carl's company holds 4 of company 1")


A = new_game(0)
session(A, "", True, True)
B = new_game(5000, shuffle=True)
session(B, "", False, False)

print("determinism")
check(run(A, "return ser(st.feat.stock)") == run(B, "return ser(st.feat.stock)"), "the same state on both games (other entities, other order, one reload)")
check(run(A, "return table.concat(BOOKS, ' ')") == run(B, "return table.concat(BOOKS, ' ')"), "the same money moves, in the same order")
check(run(A, "return table.concat(MERGES, ' ')") == run(B, "return table.concat(MERGES, ' ')"), "the same merges")
check(run(A, "local ok = pcall(ser, st.feat.stock) return ok") is True, "the state is plain data, no function, no cycle")

# ------------------------------------------------------------------------------------- a human company taken over
print("a player's company taken over")
run(A, '''MONTH = 107; M.month(st, env)
REAL = 800; M.seenAt = nil; genv.isHost = true; M.gui(st, genv); REAL = 806; M.gui(st, genv)''')
run(A, "ev('f_stock_price', { month = 107, rows = SENT[#SENT].param.rows, age = 30 }, 'Host', 1)")
# company 1 holds 1 own share (bought back 2, sold 1); Carl holds 4: 4 + 1 = 5, then the 6th share is the takeover
run(A, "ev('f_stock_buy', { co = 1, n = 1 }, 'Carl#2', 3)")
check(run(A, "return hold(1, 3)") == 5, "5 of 10")
p1 = run(A, "return price(1)")
unit = p1 * 125 // 100
n0 = run(A, "return #BOOKS")
run(A, "ev('f_stock_buy', { co = 1, n = 1, takeover = true }, 'Carl#2', 3)")
new = [run(A, "return book(%d)" % i) for i in range(n0 + 1, run(A, "return nbooks()") + 1)]
check(new == ["3:-%d" % (unit * 5)], "the buyer pays the 5 other shares with the premium; its own and the market's go to the market (%s)" % new)
check(run(A, "return MERGES[#MERGES]") == "1>3:release:taken", "the merge with the members released: its players get a new company (D2)")
check(run(A, "return M.retired(st, 'host')") is False, "a player's company is not retired")
n0 = run(A, "return #BOOKS")
run(A, "ev('f_stock_buy', { co = 3, n = 1 }, 'Host', 1)")
check(run(A, "return #BOOKS") == n0 and "no company" in run(A, "return lastLog()"), "a company taken over buys nothing any more")
run(A, "ev('f_stock_sell', { co = 1, n = 1 }, 'Dan#3', 5)")
check(run(A, "return #BOOKS") == n0 and "no company" in run(A, "return lastLog()"), "a bankrupt company sells nothing")

# ---------------------------------------------------------------------------------------------- protection at the opening
print("the protection at the opening of a young game")
Y = new_game(0)
run(Y, '''OPTS.stock = true; M.month(st, env)
ev("f_stock_price", { month = 100, rows = "1,5000000,0,5000000;2,2000000,0,2000000", age = 10 }, "Host", 1)''')
check(run(Y, "return S()['until']['1']") == 114, "a game 10 months old: protected 14 more months")
run(Y, "ev('f_stock_buy', { co = 1, n = 1 }, 'Bob#1', 2)")
check(run(Y, "return hold(1, 2)") == 0, "nobody buys during the protection")
run(Y, "ev('f_stock_buy', { co = 1, n = 1, takeover = true }, 'Bob#1', 2)")
check(run(Y, "return hold(1, 2)") == 0, "(neither as a takeover)")
run(Y, "env.coMerge = nil")
run(Y, '''for m = 101, 114 do MONTH = m; M.month(st, env); ev("f_stock_price", { month = m, rows = "1,5000000,0,5000000;2,2000000,0,2000000" }, "Host", 1) end''')
run(Y, "ev('f_stock_buy', { co = 1, n = 2 }, 'Bob#1', 2)")
check(run(Y, "return hold(1, 2)") == 2, "after the protection: for sale")
run(Y, '''for m = 115, 117 do MONTH = m; M.month(st, env); ev("f_stock_price", { month = m, rows = "1,5000000,0,5000000;2,2000000,0,2000000" }, "Host", 1); ev('f_stock_buy', { co = 1, n = 1 }, 'Bob#1', 2) end''')
check(run(Y, "return hold(1, 2)") == 5, "up to half")
run(Y, "MONTH = 118; M.month(st, env); ev('f_stock_price', { month = 118, rows = '1,5000000,0,5000000;2,2000000,0,2000000' }, 'Host', 1)")
run(Y, "ev('f_stock_buy', { co = 1, n = 1, takeover = true }, 'Bob#1', 2)")
check(run(Y, "return hold(1, 2)") == 5 and "no merge" in run(Y, "return lastLog()"), "no merge given by the integration: no takeover, nothing paid")
check(run(Y, "return #BOOKS") == 2 * 4 and run(Y, "return BOOKS[#BOOKS]") == "1:500000", "(only the 4 purchases moved money: 2 books each)")
run(Y, "ev('f_stock_price', { month = 120, rows = '1,5000000,0,5000000' }, 'Host', 1)")
check(run(Y, "return S().month") == 118, "a month not begun on this game: refused")

# ------------------------------------------------------------------------------------------------- the interface's half
print("the interface: requests of the window")
run(A, "SENT = {}; CHATS = {}; genv.myCo = 5")
run(A, "M.request('buy', { co = 1, n = 1 }, st, genv)")
check(run(A, "return #SENT") == 0 and run(A, "return #CHATS") == 1, "a player without a company: refused here, told in the chat")
G2 = new_game(0)
run(G2, '''OPTS.stock = true; M.month(st, env)
ev("f_stock_price", { month = 100, rows = "1,5000000,0,5000000;2,2000000,0,2000000;4,1000000,0,1000000", age = 30 }, "Host", 1)
genv.myCo = 2; SENT = {}; CHATS = {}''')
run(G2, "BALANCE = 100000; M.request('buy', { co = 1, n = 1 }, st, genv)")
check(run(G2, "return #SENT") == 0 and run(G2, "return CHATS[#CHATS]") == "Not enough money.", "not enough money: refused here, nothing sent")
run(G2, "BALANCE = 1e9; M.request('buy', { co = 1, n = 1 }, st, genv)")
check(run(G2, "return #SENT == 1 and SENT[1].name == 'f_stock_buy' and SENT[1].param.co == 1 and SENT[1].param.n == 1 and SENT[1].param.takeover == nil"),
      "a purchase: f_stock_buy sent")
run(G2, "M.request('buy', { co = 3, n = 1 }, st, genv)")
check(run(G2, "return #SENT") == 1 and "next month" in run(G2, "return CHATS[#CHATS]"), "a company not listed yet: refused here")
run(G2, "M.request('sell', { co = 1, n = 1 }, st, genv)")
check(run(G2, "return #SENT") == 1, "a sale of shares it does not hold: refused here")
run(G2, '''ev("f_stock_buy", { co = 4, n = 2 }, "Bob#1", 2)
MONTH = 101; M.month(st, env); ev("f_stock_price", { month = 101, rows = "1,5000000,0,5000000;2,2000000,0,2000000;4,1000000,0,1000000" }, "Host", 1)
ev("f_stock_buy", { co = 4, n = 2 }, "Bob#1", 2)
MONTH = 102; M.month(st, env); ev("f_stock_price", { month = 102, rows = "1,5000000,0,5000000;2,2000000,0,2000000;4,1000000,0,1000000" }, "Host", 1)
ev("f_stock_buy", { co = 4, n = 1 }, "Bob#1", 2)
SENT = {}''')
check(run(G2, "return hold(4, 2)") == 5, "(5 shares of the computer company)")
run(G2, "M.request('buy', { co = 4, n = 1 }, st, genv)")
check(run(G2, "return #SENT") == 0 and "Take over" in run(G2, "return CHATS[#CHATS]"), "beyond half with Buy: refused here, the Take over button is told")
run(G2, "M.request('takeover', { co = 4, n = 1, max = 625000 }, st, genv)")
check(run(G2, "return #SENT == 1 and SENT[1].param.takeover == true and SENT[1].param.max == 625000"), "a takeover: sent with the cost accepted")
run(G2, "SENT = {}; M.request('sell', { co = 4, n = 1 }, st, genv)")
check(run(G2, "return #SENT == 1 and SENT[1].name == 'f_stock_sell'"), "a sale: f_stock_sell sent")

print("the interface: stock.txt and the tab")
run(G2, "WRITES = {}; genv.isHost = false; REAL = 1000; M.gui(st, genv)")
txt = run(G2, "return WRITES[#WRITES] and WRITES[#WRITES].file == 'stock' and WRITES[#WRITES].text")
check(bool(txt) and "\nme\t2\t200" in txt and "co\t4\t1\t100000" in txt and "hold\t4\t2\t5\t" in txt, "the window's file 'stock': options, this game's company, the companies, the holdings")
view = run(G2, '''local lines = {} for l in (WRITES[#WRITES].text .. "\\n"):gmatch("([^\\n]*)\\n") do lines[#lines + 1] = l end
V = M.view(lines, function(fr, en) return en end, 1e9) return V''')
check(run(G2, "return V.rows[1].id") == 1 and run(G2, "return V.rows[1].rank") == 1, "the ranking by value (D7)")
check(run(G2, "for _, r in ipairs(V.rows) do if r.id == 4 then return r.takeover ~= nil and r.takeover.total == 625000 and r.takeover.allowed end end"), "the computer company: Take over for 625000")
check(run(G2, "for _, r in ipairs(V.rows) do if r.id == 1 then return r.buy ~= nil and r.buy.cost == 500000 end end"), "company 1: Buy 1 for 500000")
check(run(G2, "for _, r in ipairs(V.rows) do if r.id == 3 then return r.status == 'Listed next month.' end end"), "a company not listed: Listed next month")
run(G2, '''REQS = {}
U = { T = function(fr, en) return en end, read = function() return lines_ end,
  text = function(s) return { t = "text", s = s } end, muted = function(s) return { t = "muted", s = s } end,
  button = function(label, fn, primary, enabled) return { t = "button", s = label, fn = fn, enabled = enabled } end,
  row = function(ch) return { t = "row", ch = ch } end, request = function(kind, p) REQS[#REQS + 1] = { kind = kind, p = p } end }
lines_ = {} for l in (WRITES[#WRITES].text .. "\\n"):gmatch("([^\\n]*)\\n") do lines_[#lines_ + 1] = l end
OUT = M.ui(U)
TAKE = nil
for _, w in ipairs(OUT) do if w.t == "row" then for _, b in ipairs(w.ch) do if b.s:find("Take over", 1, true) then TAKE = b end end end end''')
check(run(G2, "return #OUT > 5"), "the tab draws")
check(run(G2, "return TAKE ~= nil"), "the tab has a Take over button")
run(G2, "TAKE.fn()")
check(run(G2, "return #REQS") == 0, "the first click only arms the takeover")
run(G2, "TAKE.fn()")
check(run(G2, "return #REQS == 1 and REQS[1].kind == 'takeover' and REQS[1].p.max == 625000"), "the second click asks for it")

print("the news in every game's chat")
run(G2, "CHATS = {}; M.newsSeen = nil; M.gui(st, genv)")
check(run(G2, "return #CHATS") == 0, "the news there at the load are not told again")
run(G2, "ev('f_stock_buy', { co = 1, n = 2 }, 'Bob#1', 2); ev('f_stock_buy', { co = 1, n = 1 }, 'Host', 4)")
run(G2, "MONTH = 103; M.month(st, env); ev('f_stock_price', { month = 103, rows = '1,5000000,0,5000000;2,2000000,0,2000000;4,1000000,0,1000000' }, 'Host', 1)")
run(G2, "ev('f_stock_buy', { co = 1, n = 1 }, 'Bob#1', 2)")
run(G2, "M.gui(st, genv)")
check(run(G2, "return #CHATS") == 1 and "holds 3 of the 10 shares" in run(G2, "return CHATS[1]"), "crossing 3 shares told in the chat")

print("the statistics' measure, when there is one")
# (the format of mpfever_feat_stats.lua: "mi|year|month|id:b,d,vv;...")
run(G2, '''st.feat.stats = { m = { "102|1925|3|1:1,0,0", "103|1925|4|1:3000000,500000,700000;2:1000000,0,0" } }
F = M.fromStats(st, 103)''')
check(run(G2, "return F[1].v == 3200000 and F[1].c == 3000000 and F[2].v == 1000000 and F[2].c == 1000000"), "money - loans + vehicles, from the statistics' last month")
check(run(G2, "return M.fromStats(st, 104) == nil"), "another month: not used")
rows = run(G2, '''FIG = { [1] = { v = 1, r = 77, c = 2 }, [2] = { v = 3, r = 5, c = 4 } }
M.seenAt = { [100] = -100, [200] = -100, [300] = -100, [400] = -100 }
M.loggedFor = nil
return M.rowsFor(st, genv, 103)''')
check(rows == "1,3200000,77,3000000;2,1000000,5,1000000", "the rows: the statistics' value and money, the host's result of the lines (%s)" % rows)
check("feat stock: month 103 company 1: value 3200000" in run(G2, "return table.concat(LOGS, ' | ')") and "(statistics' figures)" in run(G2, "return table.concat(LOGS, ' | ')"),
      "the host's figures logged once a month (feat stock: ...)")
run(G2, "st.feat.stats = nil; FIG = {} return true")

print("the host's own measure (the game's API mocked)")
D = new_game(0)
D.globals().SRC_FOR_TEST = SRC
run(D, '''api = {
  type = { ComponentType = { PLAYER_OWNED = "po", TRANSPORT_VEHICLE = "tv", LINE = "line", ACCOUNT = "acc", GAME_TIME = "gt" } },
  util = { getDefaultMonthDuration = function() return 120000 end },
  engine = {
    util = { getWorld = function() return 1 end,
      finance = { getPlayersBalance = function(e) return ({ [100] = 1000000, [200] = 50000 })[e] end,
        calculateBalance = function(list, t0, t1, only) CB = { #list, t0, t1, only } return 7000 * #list end },
      vehicle = { getDepreciatedValue = function(v) return v * 10 end } },
    entityExists = function() return true end,
    getComponent = function(e, ct)
      if ct == "gt" then return { gameTime = 3000000 } end
      if ct == "acc" then return { loan = (e == 100) and 300000 or 0 } end
      if ct == "po" then return ({ [11] = { player = 100 }, [12] = { player = 100 }, [13] = { player = 200 }, [21] = { player = 100 } })[e] end
    end,
    forEachEntityWithComponent = function(fn, ct)
      if ct == "tv" then for _, v in ipairs({ 11, 12, 13 }) do fn(v) end end
      if ct == "line" then fn(21) end
    end,
  },
}
M2 = assert(load(SRC_FOR_TEST, "m"))()
M2.seenAt = { [100] = -10, [200] = -10, [300] = -10, [400] = -10 }
ROWS = M2.rowsFor(st, { realTime = function() return 0 end }, 100)''')
check(run(D, "return ROWS") == "1,700230,7000,1000000;2,50130,0,50000", "value = money - loan + resale of the vehicles, result of the lines over a month (%s)" % run(D, "return ROWS"))
check(run(D, "return CB[2] == 3000000 - 120000 and CB[3] == 3000000 and CB[4] == true"), "the lines' result over the last month (maintenance and income only)")
check(run(D, "return M2.age()") == 25, "the game's age in months")
# (0.6.8) the game's lines have no PLAYER_OWNED component: the line system gives a company's lines ("the dividend doesn't work":
# every result was 0, no dividend was ever paid)
run(D, '''api.engine.system = { lineSystem = { getLinesForPlayer = function(e) return ({ [200] = { 32, 31 } })[e] or {} end } }
M2.seenAt = { [100] = -10, [200] = -10, [300] = -10, [400] = -10 }
ROWS2 = M2.rowsFor(st, { realTime = function() return 0 end }, 101)''')
check(run(D, "return ROWS2") == "1,700230,7000,1000000;2,50130,14000,50000",
      "0.6.8: a company whose lines have no owner component: their result from the line system (%s)" % run(D, "return ROWS2"))
run(D, '''local g = os.getenv
os.getenv = function(k) if k == "MPFEVER_STOCKLINES" then return "0" end return g(k) end
M2.seenAt = { [100] = -10, [200] = -10, [300] = -10, [400] = -10 }
ROWS3 = M2.rowsFor(st, { realTime = function() return 0 end }, 102)
os.getenv = g''')
check(run(D, "return ROWS3") == "1,700230,7000,1000000;2,50130,0,50000", "MPFEVER_STOCKLINES=0: the scan's lines only, as before (%s)" % run(D, "return ROWS3"))

print("the texts")
text = run(G2, "return M.newsText(st, genv, { kind = 'takeover', co = 4, by = 2, total = 625000, premium = 25 })")
check("(premium 25 %)" in text and "%%" not in text, "a percentage reads 25 %% (%s)" % text)
check("Takeover premium: 25 %." in run(G2, "return V.optText"), "the options' line of the tab")
# every text of the module in the 11 other languages (launcher/lang.json), with the same %s: the scan of tests/test_lang.py, on this module only, plus the lobby's texts of M.OPTIONS and M.TAB
import json
import re
sys.path.insert(0, HERE)
import test_lang  # noqa: E402
body = re.sub(r"(?m)^\s*--.*$", "", SRC)
texts = []
for m in re.finditer(r"(?<![\w.])(?:C\.)?(?:T|Tf)\(", body):
    en = test_lang.two_literals(body, m.end(), test_lang.lua_literal, "\"'")
    if en is not None and en not in texts:
        texts.append(en)
lobby = run(G2, '''local t = {}
local o = M.OPTIONS[1]
t[#t + 1] = o.title[2]; t[#t + 1] = o.desc[2]
for _, p in ipairs(o.params) do t[#t + 1] = p.label[2] end
t[#t + 1] = M.TAB.title[2]
return table.concat(t, "\\n")''').split("\n")
known = json.loads((test_lang.LANG_FILE).read_text(encoding="utf-8-sig"))["texts"]
missing = [t for t in texts + lobby if not all((known.get(t) or {}).get(c) for c in test_lang.LANGUAGES)]
broken = [t for t in texts + lobby if t in known and any(test_lang.placeholders(known[t].get(c) or t) != test_lang.placeholders(t) for c in test_lang.LANGUAGES)]
check(len(texts) > 30 and not missing, "%d texts (and %d of the lobby) in the 11 languages%s" % (len(texts), len(lobby), (": missing " + repr(missing)) if missing else ""))
check(not broken, "the translations keep their %s" + ((": " + repr(broken)) if broken else ""))

# ------------------------------------------------------------------------------------------- integration (the real files)
# The real options host (mpfever_feat.lua), the real merge of companies (mpfever_eco.lua E.merge / E.coMerge, mpfever_co.lua),
# the bridge's real helpers (SIM.featBridge with its coMerge, SIM.featTick, SIM.featEvent, G.featBridge, G.featChat,
# G.featRequest, G.coNewsText) and the window's real tab code (U.featU, U.featTabRows), with the game's API mocked: the market
# opens, a company buys a computer company's shares month after month and takes it over through env.coMerge; the AI module's
# real check then keeps that computer company from announcing itself again.
import re as _re

CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")


def _read(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def _extract(src, pattern, what):
    m = _re.search(pattern, src, _re.S | _re.M)
    if not m:
        check(False, what + " found in the file")
        return ""
    return m.group(0)


print("integration: the merge of companies (mpfever_eco.lua)")
ECO_MOCK = r'''
OWNER, BAL, LOAN, CMDS, LOGS = {}, {}, {}, {}, {}
ENTS = {}
api = {
  type = { ComponentType = { PLAYER_OWNED = "po", ACCOUNT = "acc", NAME = "name" },
    JournalEntry = { new = function() return { category = {} } end, Type = { OTHER = "other", LOAN = "loan" } },
    Vec3f = { new = function() return {} end } },
  engine = {
    util = { finance = { getPlayersBalance = function(e) return BAL[e] end } },
    system = { lineSystem = { getLinesForPlayer = function() return {} end } },
    forEachEntityWithComponent = function(fn, ct) for _, e in ipairs(ENTS) do fn(e) end end,
    getComponent = function(e, ct)
      if ct == "po" then return OWNER[e] and { player = OWNER[e] } or nil end
      if ct == "acc" then return { loan = LOAN[e] or 0, balance = BAL[e] } end
      return nil
    end,
  },
  cmd = {
    makeEntitySetPlayerCmd = function(e, to) return { "owner", e, to } end,
    makeJournalBookAssetCmd = function(ent, je) return { "book", ent, je.amount } end,
    sendCommand = function(c)
      CMDS[#CMDS + 1] = c[1] .. " " .. tostring(c[2]) .. " " .. tostring(c[3])
      if c[1] == "owner" then OWNER[c[2]] = c[3] end
      if c[1] == "book" then BAL[c[2]] = (BAL[c[2]] or 0) + c[3] end
    end,
  },
}
ENV = { log = function(s) LOGS[#LOGS + 1] = s end, CO = CO, R = {}, STEP = 200, gameTime = function() return 1000 end }
function registry()
  return { mode = "separate", canon = 1001, start = 2000000, list = {
    { id = 1, key = "host", name = "", color = 1, ent = 1001, members = { { key = "host" } }, chief = "host" },
    { id = 2, key = "bob", name = "Bob Co", color = 2, ent = 1002, members = { { key = "bob" }, { key = "eve" } }, chief = "bob" },
    { id = 4, key = "ai:1", name = "Robot Co", color = 4, ent = 1004, members = { { key = "ai:1" } }, chief = "ai:1" } },
    mergeOffers = { { from = 4, to = 1 }, { from = 2, to = 1 } }, requests = {}, news = {} }
end
function world()
  OWNER, BAL, LOAN, CMDS = { [5001] = 1004, [5002] = 1004, [5003] = 1002, [5004] = 1001 }, { [1001] = 1000000, [1002] = 500000, [1004] = 300000 }, { [1001] = 300000 }, {}
  ENTS = { 5001, 5002, 5003, 5004 }
end
function find(reg, id) for _, c in ipairs(reg.list) do if c.id == id then return c end end end
function keys(c) local t = {} for _, m in ipairs(c.members or {}) do t[#t + 1] = m.key end return table.concat(t, ",") end
'''


def eco_runtime(env_merge=None):
    R = lua52.LuaRuntime(unpack_returned_tuples=True)
    if env_merge is not None:
        R.execute("local real = os.getenv; os.getenv = function(k) if k == 'MPFEVER_STOCKMERGE' then return %r end return real(k) end" % env_merge)
    R.globals().CO = R.execute(_read("mpfever_co.lua"))
    R.globals().E = R.execute(_read("mpfever_eco.lua"))
    R.execute(ECO_MOCK)
    return R


R = eco_runtime()
# the merge of 0.5.14 (co_merge_answer): unchanged
r = run(R, '''world(); st = { co = registry() }
local a, b = find(st.co, 2), find(st.co, 1)
E.env = ENV
E.merge(st, a, b, ENV)
return table.concat({ a.gone, tostring(a.mergedInto), tostring(a.takenBy), tostring(a.formerMembers), keys(a), keys(b), tostring(b.chief),
  st.co.news[#st.co.news].kind, tostring(OWNER[5003]), tostring(BAL[1002]), tostring(BAL[1001]) }, "|")''')
check(r == "merged|1|nil|nil||host,bob,eve|host|merged|1001|0|1500000", "E.merge without opts: as in 0.5.14 (players, entities and money go into the company, 'merged') (%s)" % r)
# the merge a game option asks for: the stock market's takeover of a computer company
r = run(R, '''world(); st = { co = registry() }
local ok, why = E.coMerge(st, 4, 2, ENV, { members = "release", gone = "taken" })
local a, b = find(st.co, 4), find(st.co, 2)
return table.concat({ tostring(ok), a.gone, tostring(a.mergedInto), tostring(a.takenBy), table.concat(a.formerMembers, ","), keys(a), tostring(a.chief), keys(b),
  st.co.news[#st.co.news].kind, tostring(OWNER[5001]), tostring(OWNER[5002]), tostring(BAL[1004]), tostring(BAL[1002]), tostring(#st.co.mergeOffers), tostring(st.co.mergeOffers[1].from) }, "|")''')
check(r == "true|taken|2|2|ai:1||nil|bob,eve|taken|1002|1002|0|800000|1|2",
      "E.coMerge (release, taken): its entities and money to the buyer, its players released (formerMembers), not put into the buyer, its offers gone (%s)" % r)
# the savegame's company taken over: its game loans stay with it, with the money to pay them back
r = run(R, '''world(); st = { co = registry() }
local ok = E.coMerge(st, 1, 2, ENV, { members = "release", gone = "taken" })
return table.concat({ tostring(ok), tostring(BAL[1001]), tostring(BAL[1002]), table.concat(find(st.co, 1).formerMembers, ",") }, "|")''')
check(r == "true|300000|1200000|host", "the savegame's company taken over: it keeps the money of its game loans (300000), the rest to the buyer (%s)" % r)
r = run(R, '''world(); st = { co = registry() }
local a = { E.coMerge(st, 4, 4, ENV, {}) }
local b = { E.coMerge(st, 9, 2, ENV, {}) }
find(st.co, 2).gone = "bankrupt"
local c = { E.coMerge(st, 4, 2, ENV, {}) }
local st2 = { co = registry() }; st2.co.mode = "shared"
local d = { E.coMerge(st2, 4, 2, ENV, {}) }
return tostring(a[1]) .. tostring(b[1]) .. tostring(c[1]) .. tostring(d[1]) .. "|" .. tostring(find(st.co, 4).gone) .. "|" .. #CMDS''')
check(r == "falsefalsefalsefalse|nil|0", "E.coMerge refuses itself, an unknown or gone company and the co-op, and does nothing then (%s)" % r)
R0 = eco_runtime("0")
r = run(R0, '''world(); st = { co = registry() }
local ok, why = E.coMerge(st, 4, 2, ENV, { members = "release", gone = "taken" })
return tostring(ok) .. "|" .. tostring(why) .. "|" .. tostring(find(st.co, 4).gone) .. "|" .. #CMDS''')
check(r == "false|MPFEVER_STOCKMERGE=0|nil|0", "MPFEVER_STOCKMERGE=0: no merge for an option (%s)" % r)
r = run(R0, '''world(); st = { co = registry() }
E.env = ENV
E.merge(st, find(st.co, 2), find(st.co, 1), ENV)
return find(st.co, 2).gone .. "|" .. keys(find(st.co, 1))''')
check(r == "merged|host,bob,eve", "MPFEVER_STOCKMERGE=0: the players' merge unchanged")

print("integration: the options host, the bridge's helpers and the stock market, end to end")
bridge_src = _read("mpfever_bridge.script.lua")
parts = [
    _extract(bridge_src, r"^SIM\.featBridge = function\(\)\n.*?^end\n", "SIM.featBridge"),
    _extract(bridge_src, r"^SIM\.featTick = function\(state\)\n.*?^end\n", "SIM.featTick"),
    _extract(bridge_src, r"^SIM\.featEvent = function\(st, name, param\)\n.*?^end\n", "SIM.featEvent"),
    _extract(bridge_src, r"^G\.featBridge = function\(\)\n.*?^end\n", "G.featBridge"),
    _extract(bridge_src, r"^G\.featChat = function\(text\)\n.*?^end\n", "G.featChat"),
    _extract(bridge_src, r"^G\.featRequest = function\(p\)\n.*?^end\n", "G.featRequest"),
    _extract(bridge_src, r"^G\.coNewsText = function\(reg, n\)\n.*?^end\n", "G.coNewsText"),
]
ai_retired = _extract(_read("mpfever_ai.lua"), r"^function M\.retiredBy\(st, key\)\n.*?^end\n", "mpfever_ai.lua's M.retiredBy")
X = eco_runtime()
X.globals().F = X.execute(_read("mpfever_feat.lua"))
X.globals().STOCK_SRC = SRC
X.execute(r'''
FAKECLOCK = 100
os.clock = function() return FAKECLOCK end
os.time = function() return 0 end
F.loader = function(id) if id == "stock" then return assert(load(STOCK_SRC, "=mpfever_feat_stock.lua"))() end return nil end
-- the game: its time, the month's length, the vehicles and lines (none), the existence of entities
NOW, MONTHMS = 30 * 60000, 60000
api.util = { getDefaultMonthDuration = function() return MONTHMS end }
api.type.ComponentType.GAME_TIME, api.type.ComponentType.TRANSPORT_VEHICLE, api.type.ComponentType.LINE = "gt", "tv", "line"
api.engine.util.getWorld = function() return 1 end
api.engine.entityExists = function() return true end
local get = api.engine.getComponent
api.engine.getComponent = function(e, ct) if ct == "gt" then return { gameTime = NOW } end return get(e, ct) end
local each = api.engine.forEachEntityWithComponent
api.engine.forEachEntityWithComponent = function(fn, ct) if ct == "tv" or ct == "line" then return end return each(fn, ct) end
-- the bridge's globals the helpers use
log = function(s) LOGS[#LOGS + 1] = s end
function gameTime() return NOW end
STEP, R, TAB, NL, BS = 200, {}, "\t", "\n", "/"
BOOKED = {}
function coBook(ent, e) BOOKED[#BOOKED + 1] = ent .. ":" .. e.amount; BAL[ent] = (BAL[ent] or 0) + e.amount end
FILES, CHATFILE, SENT = {}, {}, {}
C = { ROLE = "host", DIR = "D", T = function(fr, en) return en end, Tf = function(fr, en, ...) local v, i = { ... }, 0 return (en:gsub("%%s", function() i = i + 1 return tostring(v[i]) end)) end,
  feat = function() return F end, eco = function() return E end,
  IO = { open = function(path) return { write = function(_, t) FILES[path] = t end, close = function() end } end },
  appendFile = function(path, t) CHATFILE[#CHATFILE + 1] = t return true end }
SIM = { ecoEnv = function() return ENV end }
G = { me = "host", myCo = 1, cmode = "separate", co = nil }
-- (an event sent: the lockstep delivers it to every game's simulation with the sender's name and company, as executeActionOnce)
G.coEvent = function(name, param) SENT[#SENT + 1] = { name = name, param = param, from = G.me, co = G.myCo } end
G.coName = function(reg, id) local c = reg and find(reg, id) return c and c.name ~= "" and c.name or ("#" .. tostring(id)) end
''')
for p in parts:
    X.execute(p)
X.execute("AIM = {}\n" + ai_retired.replace("function M.retiredBy", "function AIM.retiredBy"))
r = run(X, r'''
world()
BAL[1004] = 3000000; BAL[1002] = 50000000
st = { co = registry() }
G.co, G.featSt = st.co, st
STATE = { get = function() return st end, set = function() end }
-- (every event sent, applied in order by the simulation, as the bridge's handleEvent does)
function deliver()
  local list = SENT
  SENT = {}
  for _, e in ipairs(list) do
    local p = {}
    for k, v in pairs(e.param) do p[k] = v end
    p.mpfFrom = e.from == "host" and "host" or (e.from .. "#1")
    p.mpfCo = e.co
    SIM.featEvent(st, e.name, p)
  end
end
function as(who, co) G.me, G.myCo = who, co; C.ROLE = who == "host" and "host" or "client" end
-- the host's gui, about once a second (the real clock of the module mocked)
function gui() FAKECLOCK = FAKECLOCK + 3; F.gui(st, G.featBridge(), FAKECLOCK) end
-- (a company is read once its entity has been known for 5 s: three looks, 3 s apart)
function nextMonth() NOW = NOW + MONTHMS; SIM.featTick(STATE); as("host", 1); gui(); gui(); gui(); deliver() end
-- the option on, as the host's f_opts
SIM.featEvent(st, "f_opts", { s = "stock=1;stock.premium=50", mode = "separate", mpfFrom = "host" })
SIM.featTick(STATE)
return tostring(st.optsText) .. "|" .. tostring(st.featMonth)''')
check(r == "stock=1;stock.premium=50|30", "the options on (f_opts), the first month not counted (%s)" % r)
r = run(X, r'''
local S0 = st.feat and st.feat.stock
nextMonth()
local S = st.feat.stock
local text = FILES["D/feat_stock_stock.txt"] or ""
return tostring(S0) .. "|" .. tostring(S.month) .. "|" .. tostring(S.price["4"]) .. "|" .. tostring(S.price["1"]) .. "|" .. tostring(S["until"]["4"]) .. "|"
  .. tostring(text:find("co\t4\t1\t", 1, true) ~= nil) .. "|" .. #CHATFILE .. "|" .. tostring(CHATFILE[1] and CHATFILE[1]:find("The stock market opens: 3 companies", 1, true) ~= nil)''')
check(r == "nil|31|300000|70000|31|true|0|nil",
      "the next month: the host measures and sends the prices, every game prices (value / 10), the window's file written (%s)" % r)
r = run(X, r'''gui() return #CHATFILE .. "|" .. tostring(CHATFILE[1]:find("The stock market opens: 3 companies", 1, true) ~= nil)''')
check(r == "1|true", "the opening told in this game's chat (G.featChat)")
r = run(X, r'''
-- Bob (company 2) buys the computer company's shares through the window's request, 2 a month, up to 5
as("bob", 2); G.featRequest({ m = "stock", kind = "buy", payload = { co = 4, n = 2 } }); deliver()
as("bob", 2); G.featRequest({ m = "stock", kind = "buy", payload = { co = 4, n = 1 } }); deliver()
local h1 = st.feat.stock.hold["4"]["2"]
nextMonth()
as("bob", 2); G.featRequest({ m = "stock", kind = "buy", payload = { co = 4, n = 2 } }); deliver()
nextMonth()
as("bob", 2); G.featRequest({ m = "stock", kind = "buy", payload = { co = 4, n = 1 } }); deliver()
as("bob", 2); G.featRequest({ m = "stock", kind = "buy", payload = { co = 4, n = 1 } }); deliver()
return h1 .. "|" .. st.feat.stock.hold["4"]["2"] .. "|" .. #BOOKED .. "|" .. BOOKED[1] .. "|" .. BOOKED[2]''')
check(r == "2|5|6|1002:-600000|1004:600000",
      "purchases through the window (G.featRequest -> M.request -> f_stock_buy): the monthly limit, the money to the company bought, through coBook (%s)" % r)
r = run(X, r'''
nextMonth()
local P = st.feat.stock.price["4"]
local total = math.floor(P * 150 / 100) * 5
local before = BAL[1002]
local robot = BAL[1004]
as("bob", 2); G.featRequest({ m = "stock", kind = "takeover", payload = { co = 4, n = 1, max = total } }); deliver()
local c4 = find(st.co, 4)
return table.concat({ tostring(c4.gone), tostring(c4.takenBy), table.concat(c4.formerMembers or {}, ","), tostring(OWNER[5001]), tostring(OWNER[5002]),
  tostring(BAL[1004]), tostring(BAL[1002] == before - total + robot), tostring(st.feat.stock.retired["ai:1"]), tostring(st.feat.stock.price["4"]),
  tostring(AIM.retiredBy(st, "ai:1")), tostring(AIM.retiredBy(st, "ai:2")), st.co.news[#st.co.news].kind, tostring(G.coNewsText(st.co, st.co.news[#st.co.news])) }, "|")''')
check(r == "taken|2|ai:1|1002|1002|0|true|true|nil|true|false|taken|nil",
      "the takeover (premium 50 %%): env.coMerge -> E.coMerge, its entities and money to the buyer, the computer company retired (mpfever_ai.lua), "
      "the bridge's chat says nothing of the merge (%s)" % r)
r = run(X, r'''CHATFILE = {}; as("host", 1); gui()
local said = table.concat(CHATFILE, " ")
return tostring(said:find("Bob Co takes over Robot Co", 1, true) ~= nil) .. "|" .. #CHATFILE''')
check(r == "true|1", "the takeover told once, by the stock market, in this game's chat (%s)" % r)
r = run(X, r'''local n = #BOOKED
as("bob", 2); G.featRequest({ m = "stock", kind = "buy", payload = { co = 4, n = 1 } }); deliver()
return #BOOKED - n .. "|" .. #SENT''')
check(r == "0|0", "a company taken over: nothing more to buy, refused on the buyer's game, nothing sent (%s)" % r)
TABTEXT = run(X, 'as("bob", 2); gui(); return FILES["D/feat_stock_stock.txt"]')

print("integration: the window's tab (mpfever_ui.script.lua)")
ui_src = _read("mpfever_ui.script.lua")
win = _extract(ui_src, r"^U\.featOff = .*?^U\.featTabRows = function\(K, st, key\)\n.*?^end\n", "the window's game options")
W = lua52.LuaRuntime(unpack_returned_tuples=True)
W.globals().FEAT_SRC = _read("mpfever_feat.lua")
W.globals().STOCK_SRC = SRC
W.globals().TABTEXT = TABTEXT or ""
W.execute(r'''
F = assert(load(FEAT_SRC, "=mpfever_feat.lua"))()
F.loader = function(id) if id == "stock" then return assert(load(STOCK_SRC, "=mpfever_feat_stock.lua"))() end return nil end
CLOCK = 10
os.clock = function() return CLOCK end
U = { isHost = function() return false end, winChanged = function() end, menuRequest = function() return true end }
LINES = {}
function sendLine(kind, p) LINES[#LINES + 1] = kind .. " " .. tostring(p.m) .. " " .. tostring(p.kind) .. " " .. tostring(p.payload and p.payload.co) end
function money(n) return "$" .. tostring(n) end
function T(fr, en) return en end
function log() end
FILEDATA = { ["D/feat_stock_stock.txt"] = TABTEXT }
C = { feat = function() return F end, DIR = "D", BS = "/", NL = "\n", CR = "\r", Tf = function(fr, en) return en end,
  IO = { open = function(path) local s = FILEDATA[path] if not s then return nil end
    return { read = function() return s end, close = function() end } end } }
api = {}
K = { TEXT_W = 556, ICON_SETTINGS = "i" }
function K.text(t) return { kind = "text", t = tostring(t) } end
function K.muted(t) return { kind = "muted", t = tostring(t) } end
function K.section(icon, t) return { kind = "section", t = t } end
function K.gap() return { kind = "gap" } end
function K.row(c) return { kind = "row", c = c } end
function K.col(c) return { kind = "col", c = c } end
function K.btn(label, tip, fn, primary, enabled) return { kind = "btn", t = label, fn = fn, primary = primary, enabled = enabled } end
''')
W.execute(win)
r = run(W, r'''
local stW = { mode = "separate", opts = "stock=1;stock.premium=50", me = "bob" }
local tabs = U.featTabs(stW)
ROWS = U.featTabRows(K, stW, "f_stock")
local sections, buys, texts = 0, {}, {}
for _, n in ipairs(ROWS) do
  if n.kind == "section" then sections = sections + 1 end
  if n.kind == "text" then texts[#texts + 1] = n.t end
  if n.kind == "row" then for _, b in ipairs(n.c) do if b.kind == "btn" then buys[#buys + 1] = b end end end
end
BUY1 = nil
for _, b in ipairs(buys) do if b.t:find("Buy 1 (", 1, true) and not BUY1 then BUY1 = b end end
return table.concat({ #tabs, tabs[1] and tabs[1].key or "-", sections, tostring(texts[1] and texts[1]:find("Your portfolio", 1, true) ~= nil), #buys > 0 and "buttons" or "none",
  tostring(BUY1 and BUY1.enabled), tostring(BUY1 and BUY1.primary) }, "|")''')
check(r == "1|f_stock|2|true|buttons|true|false", "the Stocks tab: drawn once (2 titles, no row twice), the portfolio, Buy buttons enabled (%s)" % r)
r = run(W, r'''BUY1.fn() return LINES[1]''')
check(r == "feat_req stock buy 1", "a button: the request to this game's module (ui.log feat_req) (%s)" % r)

print("PASS" if not failures else "FAIL: %d check(s): %s" % (len(failures), "; ".join(failures)))
sys.exit(1 if failures else 0)
