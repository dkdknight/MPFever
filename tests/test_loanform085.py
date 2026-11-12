"""Offline test: the loan form keeps what was typed and takes its grey examples for empty fields (0.8.5, #266,
MPFEVER_LOANFORMKEEP=0: as in 0.8.3).

#266 (Creeper, Akamari): "after I enter an amount and click on the next field it switches back to the default 1000000, and I
cannot see the credit Akamari asked": the card is drawn again on every refresh with value = "", so the fields showed their grey
examples again; and an empty field was no amount at all ("Enter an amount"): no ask ever left the form (no "asks company ... for
a loan" in either game's log). mpfever_ui.script.lua is read; U.loanTermsIn is run with lupa.
Run: python tests/test_loanform085.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(UI, encoding="utf-8").read().replace("\r\n", "\n")
card = src[src.index("U.loanCard = function(K, c, eco)"):]
card = card[:card.index("\nend\n")]
check("the fields show what was typed (U.loanIn), not an empty value", 'value = U.LOANFORM and tostring((U.loanIn[c2.id] or {})[key] or "") or ""' in card)
check("  the grey examples are the defaults used", 'U.LOAN_DEFAULTS = { a = "1000000", m = "12", r = "10" }' in src
      and 'field("a", "1000000"' in card and 'field("m", "12"' in card and 'field("r", "10"' in card)
check("  switch MPFEVER_LOANFORMKEEP=0", 'U.LOANFORM = os.getenv("MPFEVER_LOANFORMKEEP") ~= "0"' in src)
send = src[src.index("U.loanSend = function(name, param)"):]
send = send[:send.index("\nend\n")]
check("  the fields emptied once sent (not when the send failed)", "elseif U.LOANFORM then U.loanIn = {} end" in send)

try:
    import lupa.lua52 as lupa
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    pre = src[src.index("U.LOANFORM = os.getenv"):src.index("U.loanCard = function(K, c, eco)")]
    num = re.search(r"U\.loanNum = function\(v\)\n.*?\nend\n", src, re.S).group(0)
    L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end T = function(a, b) return b end U = { loanIn = {} }\n" + num)
    L.execute(pre)
    terms = L.eval("function(a, m, r) U.loanIn = { [2] = { a = a, m = m, r = r } } local t, why = U.loanTermsIn({ id = 2 }) if t then return t.amount .. '/' .. t.months .. '/' .. t.rate end return why end")
    check("#266: nothing typed: the grey examples, 1000000 over 12 months at 10 %", terms(None, None, None) == "1000000/12/10")
    check("  an amount typed, the rest empty", terms("2 500 000", "", None) == "2500000/12/10")
    check("  all typed", terms("500000", "24", "5") == "500000/24/5")
    check("  a wrong duration still refused", terms("500000", "500", "5") == "Duration: 1 to 120 months.")
    L.execute(pre.replace('os.getenv("MPFEVER_LOANFORMKEEP") ~= "0"', 'false'))
    check("  MPFEVER_LOANFORMKEEP=0: an empty amount refused, as in 0.8.3", terms(None, None, None) == "Enter an amount.")
except ImportError:
    print("lupa is not installed: the terms' cases not run")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
