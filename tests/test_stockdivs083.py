"""Offline test: the stock market's overview shows the dividends paid and their balance (0.8.3, Akamari's suggestion).

The stock option kept, for each company, the dividends it paid to its holders (S.paid) and those it received (S.got), and wrote
both to the window's file ("divs" lines); the window showed the received ones only. Now this company's portfolio has paid and
balance (received less paid), shown in the overview's text and in its boxes (both pages). Interface only: nothing the games
compute changes. mpfever_feat_stock.lua is read; the portfolio's lines run through lupa (Lua 5.2).
Run: python tests/test_stockdivs083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
STOCK = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_stock.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(STOCK, encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"\n(\tv\.portfolio = \{ value = 0, got = .*?\n\tv\.portfolio\.balance = .*?\n)", src)
check("the portfolio's lines found", m is not None)
if m:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    f = L.eval("function(me, got, paid) local v = { me = me, divs = { [me] = { got = got, paid = paid } } }\n" + m.group(1) + " return v.portfolio.got, v.portfolio.paid, v.portfolio.balance end")
    check("received 12000, paid 30000: balance -18000", tuple(f(3, 12000, 30000)) == (12000, 30000, -18000))
    g = L.eval("function() local v = { me = 5, divs = {} }\n" + m.group(1) + " return v.portfolio.got, v.portfolio.paid, v.portfolio.balance end")
    check("a company with no dividends yet: 0, 0, 0", tuple(g()) == (0, 0, 0))
check("the overview's text: received, paid and balance",
      '"Your portfolio: %s. Dividends received: %s, paid: %s, balance: %s."' in src
      and "money(v.portfolio.value), money(v.portfolio.got), money(v.portfolio.paid), money(v.portfolio.balance)" in src)
check("the boxes of both pages: paid and balance after received",
      src.count('{ T("Dividendes versés", "Dividends paid"), money(v.portfolio.paid) }, { T("Bilan des dividendes", "Dividend balance"), money(v.portfolio.balance) }') == 2)
check("the window's file still has both figures per company (\"divs\" lines)", '"divs", k, math.floor(num(S.paid and S.paid[k]) or 0)' in src)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
