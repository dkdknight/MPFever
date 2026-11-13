"""Offline test: the stock market's sale at the month's price, and no pump between friends (0.8.6, #277; M.sellAtPrice, M.checkSell,
buy, sell and the month's prices in mod/mpfever_1/content/mpfever_feat_stock.lua).

#277 (Akamari and Creeper, 2026-11-13 00:04): Akamari's company held 3 shares of Creeper's, bought at the floor (1 593 036 for
the 3). The price was 7 443 729: selling one gave 520 392 (at most the average price paid, less 2 %). Buying one at 7 443 729 and
selling it at once gave 2 778 546 (the new average): Creeper's company kept 4.7 million at each round. The window's help already
said "Selling a share gives you its price of the moment". The user's choice: the month's price less 2 %, paid by the company, and
the money a company got from its shares (less what it paid back) left out of its price, so that buying a friend's shares never
raises their price.
  - a sale gives the month's price less 2 %, paid by the company whose share it is; the old rule with MPFEVER_STOCKSELLPRICE=0;
  - buying and selling at once loses the 2 %, nothing more, nothing less;
  - the money of a purchase does not raise the next month's price; the old rule did (the pump);
  - a company's own shares (buy-backs, sold to the market) do not count;
  - the company pays back only within its money of the month;
  - the window's sell button shows what the sale gives.
Needs lupa (pip install lupa). Run: python tests/test_stocksell086.py
"""
import os, re, sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_stock.lua")
SRC = open(MODULE, encoding="utf-8").read()
# the one-game harness of tests/test_feat_stock.py (the module with the options host's env mocked)
t = open(os.path.join(HERE, "test_feat_stock.py"), encoding="utf-8").read()
GAME = t[t.index("GAME = r'''") + len("GAME = r'''"):]
GAME = GAME[:GAME.index("'''")]
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def game():
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.eval("function(code, src, base, shuffle) return assert(load(code))(src, base, shuffle) end")(GAME, SRC, 0, False)
    return L


def run(L, code):
    return L.eval("function(c) return assert(load(c))() end")(code)


P = 7443729          # Creeper's price
V = P * 10           # its value
SETUP = '''OPTS.stock = true; env.mode = "separate"; st.co.mode = "separate"; MONTH = 100
M.month(st, env)
ev("f_stock_price", { month = 100, rows = "1,%d,0,30000000;2,20000000,0,20000000", age = 30 }, "Host", 1)
local s = S()
s.hold = { ["1"] = { ["2"] = 3 } }
s.cost = { ["1"] = { ["2"] = 1593036 } }
s["until"]["1"] = 0; s["until"]["2"] = 0
BOOKS = {}''' % V


def sold(L):
    return run(L, 'local s = S(); return s.hold["1"]["2"]')


os.environ.pop("MPFEVER_STOCKSELLPRICE", None)
A = game()
run(A, SETUP)
check(run(A, 'return price(1)') == P, "the month's price", run(A, 'return price(1)'))
run(A, 'ev("f_stock_sell", { co = 1, n = 1 }, "Akamari#1", 2)')
want = P * 98 // 100
check(run(A, "return BOOKS[1]") == "1:-%d" % want and run(A, "return BOOKS[2]") == "2:%d" % want,
      "a sale gives the month's price less 2 %%, paid by the company (%d)" % want, str([run(A, "return BOOKS[1]"), run(A, "return BOOKS[2]")]))
# buying one again and selling it at once: the 2 % only
run(A, 'BOOKS = {}; ev("f_stock_buy", { co = 1, n = 1 }, "Akamari#1", 2); ev("f_stock_sell", { co = 1, n = 1 }, "Akamari#1", 2)')
b = [run(A, "return BOOKS[%d]" % i) for i in range(1, 5)]
check(b == ["2:-%d" % P, "1:%d" % P, "1:-%d" % want, "2:%d" % want], "buy and sell at once: the 2 %% only (%d)" % (P - want), str(b))
check(run(A, 'return S().raised["1"]') == -want + P - want, "the company's money from its shares kept apart (raised: paid back less got)", run(A, 'return S().raised["1"]'))
# the pump: 2 shares bought (a new month's limit), the host measures the money in next month: the price does not rise
run(A, 'BOOKS = {}; S().bought = nil; S().raised = nil; ev("f_stock_buy", { co = 1, n = 2 }, "Akamari#1", 2)')
check(run(A, 'return S().raised["1"]') == 2 * P, "  two shares bought: their money kept apart", run(A, 'return S().raised and S().raised["1"]'))
raised = run(A, 'return S().raised["1"]')
run(A, 'MONTH = 101; M.month(st, env); ev("f_stock_price", { month = 101, rows = "1,%d,0,30000000;2,20000000,0,20000000", age = 31 }, "Host", 1)' % (V + raised))
check(run(A, 'return price(1)') == P, "the money of the purchases does not raise the price (no pump)", run(A, 'return price(1)'))
# own shares: a buy-back and a sale to the market do not count
r0 = run(A, 'return S().raised["1"]')
run(A, 'S().bought = nil; ev("f_stock_buy", { co = 1, n = 1 }, "Creeper", 1); ev("f_stock_sell", { co = 1, n = 1 }, "Creeper", 1)')
check(run(A, 'return S().raised["1"]') == r0, "a company's own shares do not count")
# within the company's money of the month
run(A, 'S().cash["1"] = 1000; S().out = nil')
check(run(A, 'local ok, why = M.checkSell(S(), st.co, 2, 1, 1); return ok == false and why') == "the company cannot buy them back this month",
      "paid back only within the company's money of the month")

# the old rule
os.environ["MPFEVER_STOCKSELLPRICE"] = "0"
B = game()
run(B, SETUP)
run(B, 'ev("f_stock_sell", { co = 1, n = 1 }, "Akamari#1", 2)')
check(run(B, "return BOOKS[2]") == "2:%d" % (1593036 // 3 * 98 // 100), "MPFEVER_STOCKSELLPRICE=0: at most the average price paid, as before", run(B, "return BOOKS[2]"))
run(B, 'BOOKS = {}; S().bought = nil; ev("f_stock_buy", { co = 1, n = 2 }, "Akamari#1", 2)')
run(B, 'MONTH = 101; M.month(st, env); ev("f_stock_price", { month = 101, rows = "1,%d,0,30000000;2,20000000,0,20000000", age = 31 }, "Host", 1)' % (V + 2 * P))
check(run(B, 'return price(1)') == (V + 2 * P) // 10, "  and the price on the whole value (the pump)", run(B, 'return price(1)'))
check(run(B, 'return S().raised == nil'), "  no raised money kept")
os.environ.pop("MPFEVER_STOCKSELLPRICE", None)

src = SRC.replace("\r\n", "\n")
check(src.count('u.button(r.sell.proceeds and fmt(T("Vendre 1 (%s)", "Sell 1 (%s)"), money(r.sell.proceeds))') == 3, "the three windows' sell buttons show what the sale gives")
check("row.sell = { n = 1, proceeds = math.floor(each * M.SPREAD / 100) }" in src, "  computed as the sale is")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
