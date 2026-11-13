"""The 0.8.6 game option "cargo", a commodity market (#277, Akamari's idea; mod/mpfever_1/content/mpfever_feat_cargo.lua), offline:
the module loaded through lupa (Lua 5.2) with the options host's env mocked as docs/FEATURES-0.6.md describes it.

  - the option off: no state, no event, no money, no file;
  - the lobby's option: 3 parameters, defaults among the values, both company modes;
  - the prices: target from demand, deliveries and production (a cargo short goes up, one made far beyond the demand goes down,
    all served and as much made as asked: 100), the next price part of the way, whole, within 10..1000; the opening at 100;
  - the host's monthly rows (the measure replaced), sent again after 15 s while not applied, never by a client;
  - f_cargo_price from the host only, applied once a month;
  - buying (lot value x index / 100, the money to the market), the monthly limit, the lots held at most; selling at the price less
    2 %, the realised gain; one company per player (each by its number) and one for everybody (company 1);
  - determinism: two games with other entity numbers give the same state and the same books;
  - the window's view: the change, the demand served, the buttons with their amounts.
Run: python tests/test_feat_cargo.py
"""
import os, sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_cargo.lua"), encoding="utf-8").read()
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


GAME = r'''
local SRC, BASE, MODE = ...
M = assert(load(SRC, "mpfever_feat_cargo.lua"))()
OPTS = { cargo = false }
PARAMS = {}
MONTH = 100
REAL = 0
BOOKS, LOGS, SENT, WRITES = {}, {}, {}, {}
COS = { { id = 1, ent = BASE + 100 }, { id = 2, ent = BASE + 200 } }
function idOf(ent) for _, c in ipairs(COS) do if c.ent == ent then return c.id end end return -1 end
st = {}
env = {
  log = function(s) LOGS[#LOGS + 1] = s end,
  on = function(id) return OPTS[id] == true end,
  param = function(id, pid)
    local v = PARAMS[pid]
    if v ~= nil then return v end
    for _, o in ipairs(M.OPTIONS) do if o.id == id then for _, p in ipairs(o.params or {}) do if p.id == pid then return p.default end end end end
  end,
  state = function(s) s.feat = s.feat or {}; s.feat[M.ID] = s.feat[M.ID] or {}; return s.feat[M.ID] end,
  mode = MODE,
  month = function() return MONTH end,
  companies = function() if MODE == "separate" then return COS end return { COS[1] } end,
  book = function(ent, amount) assert(math.floor(amount) == amount); BOOKS[#BOOKS + 1] = idOf(ent) .. ":" .. string.format("%.0f", amount) end,
}
genv = { log = env.log, on = env.on, param = env.param, isHost = true, mode = MODE, myCo = 2,
  send = function(name, param) SENT[#SENT + 1] = { name = name, param = param } end,
  write = function(file, lines) WRITES[#WRITES + 1] = { file = file, lines = lines } end,
  realTime = function() return REAL end }
FIG = {}
M.measure = function() return FIG end
function ev(name, param, from, co) param = param or {}; param.mpfFrom, param.mpfCo = from, co; M.event(st, name, param, env) end
function S() return st.feat and st.feat.cargo end
'''


def game(base=0, mode="separate"):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.eval("function(code, src, base, mode) return assert(load(code))(src, base, mode) end")(GAME, SRC, base, mode)
    return L


def run(L, code):
    return L.eval("function(c) return assert(load(c))() end")(code)


WOOD, GRAIN = "::/cargos/wood/wood.cargo", "::/cargos/grain/grain.cargo"

print("the option off")
A = game()
run(A, 'M.month(st, env); ev("f_cargo_price", { month = 100, rows = "x|100|1|1|1|x" }, "Host", 1); ev("f_cargo_buy", { cargo = "x", n = 1 }, "Bob#1", 2); M.gui(st, genv)')
check(run(A, "return st.feat == nil and #BOOKS + #SENT + #WRITES == 0"), "nothing happens: no state, money, event or file")

print("the lobby's option")
check(run(A, "return M.OPTIONS[1].id == 'cargo' and M.OPTIONS[1].modes == 'both' and #M.OPTIONS[1].params == 3"), "option cargo, both modes, 3 parameters")
check(run(A, '''for _, p in ipairs(M.OPTIONS[1].params) do local f = false for _, v in ipairs(p.values) do if v == p.default then f = true end end
  if not f or type(p.label[1]) ~= "string" or type(p.label[2]) ~= "string" then return false end end return true'''), "defaults among the values, French and English")
check(run(A, 'for k in pairs(M.EVENTS) do if k:sub(1, 8) ~= "f_cargo_" then return false end end return true'), "events named f_cargo_*")

print("the prices")
t = lambda d, l, p: run(A, "return M.target(%s, %s, %s)" % (d, l, p))
check(abs(t(1000, 1000, 1000) - 100) < 1e-9, "all served, as much made as asked: 100")
check(abs(t(1000, 250, 1000) - 200) < 1e-9, "a quarter served: 200 (short: up)")
check(abs(t(1000, 0, 1000) - 200) < 1e-9, "nothing served: at most 4x short (200)")
check(abs(t(1000, 1000, 4000) - 50) < 1e-9, "four times the demand made: 50 (down)")
check(abs(t(0, 0, 500) - 50) < 1e-9, "made but asked by nobody: 50")
check(abs(t(1000, 1000, 250) - 100) < 1e-9, "all served though little is made: 100 (only a surplus lowers it)")
check(abs(t(1000, 250, 250) - 200) < 1e-9, "short and little made: 200 at most")
check(run(A, "return M.nextPrice(100, 200, 33)") == 133 and run(A, "return M.nextPrice(100, 50, 50)") == 75, "part of the way, whole")
check(run(A, "return M.nextPrice(12, 0, 100)") == 10 and run(A, "return M.nextPrice(990, 5000, 100)") == 1000, "within 10..1000")

print("the host's rows")
run(A, 'OPTS.cargo = true; M.month(st, env)')
run(A, 'FIG = { ["%s"] = { label = "Wood", dem = 1000, del = 250, prod = 1000 }, ["%s"] = { label = "Grain", dem = 800, del = 800, prod = 3200 }, ["x"] = { label = "None", dem = 0, del = 0, prod = 0 } }' % (WOOD, GRAIN))
run(A, "REAL = 10; M.gui(st, genv)")
check(run(A, "return #SENT == 1 and SENT[1].name == 'f_cargo_price' and SENT[1].param.month == 100"), "the host sends the month's prices")
rows = run(A, "return SENT[1].param.rows")
check(rows == "%s|100|800|800|3200|Grain;%s|100|1000|250|1000|Wood" % (GRAIN, WOOD), "sorted rows, the opening at 100, nothing for a cargo nobody makes or asks for", rows)
run(A, "REAL = 15; M.gui(st, genv)")
check(run(A, "return #SENT") == 1, "not again before 15 s")
run(A, "REAL = 26; M.gui(st, genv)")
check(run(A, "return #SENT") == 2, "again after 15 s while not applied")
run(A, "genv.isHost = false; REAL = 60; M.gui(st, genv)")
check(run(A, "return #SENT") == 2, "a client's game never sends prices")
run(A, 'genv.isHost = true; ev("f_cargo_price", { month = 100, rows = %r }, "Bob#1", 2)' % rows)
check(run(A, "return S().month") is None, "prices from a player: refused")
run(A, 'ev("f_cargo_price", { month = 100, rows = %r }, "Host", 1)' % rows)
check(run(A, "return S().month") == 100 and run(A, 'return S().price["%s"]' % WOOD) == 100, "prices from the host: applied")
run(A, 'ev("f_cargo_price", { month = 100, rows = %r }, "Host", 1)' % rows.replace("|100|", "|500|"))
check(run(A, 'return S().price["%s"]' % WOOD) == 100, "the same month again: refused")
# next month: wood short moves up a third of the way, grain abundant down
run(A, "MONTH = 101; M.month(st, env); SENT = {}; REAL = 100; M.sentFor = nil; M.gui(st, genv)")
rows2 = run(A, "return SENT[1] and SENT[1].param.rows")
check(rows2 is not None and ("%s|133|" % WOOD) in rows2 and ("%s|84|" % GRAIN) in rows2, "next month: short wood up (133), abundant grain down (84)", rows2)

print("buying and selling (one company per player)")
run(A, 'BOOKS = {}; ev("f_cargo_buy", { cargo = "%s", n = 2 }, "Bob#1", 2)' % WOOD)
check(run(A, "return BOOKS[1]") == "2:-100000", "2 lots of wood at 100: 2 x 50 000 to the market", run(A, "return BOOKS[1]"))
run(A, 'PARAMS.limit = 5; ev("f_cargo_buy", { cargo = "%s", n = 4 }, "Bob#1", 2)' % WOOD)
check(run(A, "return #BOOKS") == 1 and "monthly limit" in run(A, "return LOGS[#LOGS]"), "the month's limit (5)")
run(A, 'ev("f_cargo_buy", { cargo = "%s", n = 1 }, "Host", 1)' % WOOD)
check(run(A, "return BOOKS[2]") == "1:-50000", "another company buys for itself", run(A, "return BOOKS[2]"))
run(A, 'ev("f_cargo_price", { month = 101, rows = %r }, "Host", 1)' % rows2)
run(A, 'BOOKS = {}; ev("f_cargo_sell", { cargo = "%s", n = 1 }, "Bob#1", 2)' % WOOD)
check(run(A, "return BOOKS[1]") == "2:65170", "sold at 133 less 2 %: 66 500 x 0.98 = 65 170", run(A, "return BOOKS[1]"))
check(run(A, 'return S().gain["2"]') == 65170 - 50000, "the realised gain", run(A, 'return S().gain["2"]'))
run(A, 'ev("f_cargo_sell", { cargo = "%s", n = 5 }, "Bob#1", 2)' % WOOD)
check(run(A, "return #BOOKS") == 1, "more lots than held: refused")
run(A, 'ev("f_cargo_buy", { cargo = "nothing", n = 1 }, "Bob#1", 2)')
check(run(A, "return #BOOKS") == 1, "a cargo without price: refused")
run(A, 'PARAMS.limit = 20; S().hold["%s"] = { ["2"] = 99 }; ev("f_cargo_buy", { cargo = "%s", n = 2 }, "Bob#1", 2)' % (WOOD, WOOD))
check(run(A, "return #BOOKS") == 1, "100 lots of one cargo at most")

print("one company for everybody")
B = game(0, "shared")
run(B, 'OPTS.cargo = true; M.month(st, env); ev("f_cargo_price", { month = 100, rows = %r }, "Host", nil)' % rows)
run(B, 'ev("f_cargo_buy", { cargo = "%s", n = 1 }, "Bob#1", nil)' % WOOD)
check(run(B, "return BOOKS[1]") == "1:-50000", "the company (1) trades", run(B, "return BOOKS[1]"))

print("determinism")
def session(L):
    run(L, 'OPTS.cargo = true; M.month(st, env); ev("f_cargo_price", { month = 100, rows = %r }, "Host", 1)' % rows)
    run(L, 'ev("f_cargo_buy", { cargo = "%s", n = 3 }, "Bob#1", 2); ev("f_cargo_buy", { cargo = "%s", n = 2 }, "Host", 1)' % (WOOD, GRAIN))
    run(L, 'MONTH = 101; M.month(st, env); ev("f_cargo_price", { month = 101, rows = %r }, "Host", 1)' % rows2)
    run(L, 'ev("f_cargo_sell", { cargo = "%s", n = 2 }, "Bob#1", 2); ev("f_cargo_sell", { cargo = "%s", n = 1 }, "Host", 1)' % (WOOD, GRAIN))
    return run(L, "return table.concat(BOOKS, ' ')"), run(L, '''local s = S(); local t = {} for _, f in ipairs({ "%s", "%s" }) do
      for _, k in ipairs({ "1", "2" }) do t[#t + 1] = f .. k .. "=" .. tostring(s.hold[f] and s.hold[f][k]) .. "/" .. tostring(s.cost[f] and s.cost[f][k]) end end
      return table.concat(t, ";") .. tostring(s.gain and s.gain["1"]) .. tostring(s.gain and s.gain["2"])''' % (WOOD, GRAIN))
X, Y = session(game(0)), session(game(7000))
check(X == Y, "two games with other entities: the same books and state", str(X) + " / " + str(Y))

print("the window")
run(A, 'genv.myCo = 2; WRITES = {}; M.gui(st, genv)')
lines = run(A, "local L = {} for i, l in ipairs(WRITES[#WRITES].lines) do L[i] = l end return table.concat(L, '\\n')")
check(lines.startswith("opt\t50000\t33\t20\t101\t100") and ("\nme\t2\t15170") in lines, "the file: options, this company and its gain", lines[:80])
V = run(A, '''local L = {} for i, l in ipairs(WRITES[#WRITES].lines) do L[i] = l end local v = M.view(L, nil)
  local w = nil for _, c in ipairs(v.cargos) do if c.label == "Wood" then w = c end end
  return v.open, w.price, w.change, w.served, w.made, w.held, w.buy and w.buy.cost, w.sell and w.sell.proceeds, v.cargos[1].label''')
check(V[0] is True and V[1] == 133 and V[2] == 33.0 and V[3] == 25 and V[4] == 100, "open; wood 133 (+33 %), demand served 25 %, made 100 % of it", str(V))
check(V[5] == 99 and V[6] == 66500 and V[7] == 65170 and V[8] == "Grain", "held, the buy and sell buttons' amounts, sorted by name", str(V))

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
