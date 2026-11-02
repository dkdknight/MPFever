"""Offline test of the computer companies' retries and loans (0.6.9, mpfever_ai.lua and the bridge's ai_loan).

The stress test of 2026-11-02 (Test Headless, 3 computer companies, 45 min at x4): every pair of towns was left within 2 minutes
(no street for a stop) and stayed left, the companies idle for the rest of the game; one of them, under its floor with no line,
took a loan of 59 million (the offer of the lowest monthly payment is the longest one, so the largest).
  - isLeft / leave: a pair or a town left is tried again two years later; a mark of before (true) counts from the first look;
    MPFEVER_AIPAIRRETRY=0: left for good;
  - every place that left a pair or a town uses them;
  - the loan asked says what the company needs (back to its reserve); the bridge takes the smallest offer that covers it, the
    largest when none does; MPFEVER_AILOANNEED=0: the lowest monthly payment, as before;
  - no stop street: the log says how many segments there were and how many were left out at a configured junction.
Needs lupa (pip install lupa). Run: python tests/test_ai_retry.py
"""
import os, re, sys

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker
import test_ai0514 as T0

check, failures = checker()
L, M = load()
run = L.eval("function(code) local f = assert(load(code)) return f() end")

print("a pair left, tried again")
run('TIME = 1000000; LST = {}; M.f.leave(E, LST, "1/2")')
check(run('return M.f.isLeft(E, LST, "1/2")') is True, "left just now: left")
check(run('return M.f.isLeft(E, LST, "3/4")') is False, "another pair: not left")
run('TIME = 1000000 + 2 * 1461000 - 1')
check(run('return M.f.isLeft(E, LST, "1/2")') is True, "still left just under two years later")
run('TIME = 1000000 + 2 * 1461000 + 1')
check(run('return M.f.isLeft(E, LST, "1/2")') is False and run('return LST["1/2"]') is None, "two years later: tried again, the mark gone")
run('TIME = 5000000; LST = { ["1/2"] = true }')
check(run('return M.f.isLeft(E, LST, "1/2")') is True and run('return LST["1/2"]') == 5000000, "a mark of before: left, counted from now")
run('TIME = 5000000 + 3 * 1461000')
check(run('return M.f.isLeft(E, LST, "1/2")') is False, "and tried again two years later")
run('ENV.MPFEVER_AIPAIRRETRY = "0"; TIME = 1000000; LST = {}; M.f.leave(E, LST, "1/2"); TIME = 99000000')
check(run('return LST["1/2"]') is True and run('return M.f.isLeft(E, LST, "1/2")') is True, "MPFEVER_AIPAIRRETRY=0: left for good")
run('ENV.MPFEVER_AIPAIRRETRY = nil')

src = open(os.path.join(T0.CONTENT, "mpfever_ai.lua"), encoding="utf-8").read()
check("A.pairFailed[pair.key] = true" not in src and src.count("leave(E, A.pairFailed, pair.key)") == 3, "the three places that leave a pair")
check("A.skipTown[town] = true" not in src and src.count("leave(E, A.skipTown, town)") == 2 and "isLeft(E, A.skipTown, town)" in src, "the towns left too")
check("not isLeft(E, A.pairFailed, key)" in src, "bestPair reads it")
check('free town segment(s) within 200 m' in src, "no stop street: the reason logged")

print("the loan asked")
check('loanArg.need = math.floor(math.max(RESERVE, low) - money)' in src and 'MPFEVER_AILOANNEED' in src, "the company says what it needs")

import lupa.lua52 as lupa
bridge = open(T0.BRIDGE, encoding="utf-8").read()
m_loan = re.search(r"^(\t+)elseif name == \"ai_loan\" then\n.*?(?=^\1elseif name == \"recolor\" then\n)", bridge, re.S | re.M)
check(m_loan is not None, "the bridge's ai_loan found")
B = lupa.LuaRuntime(unpack_returned_tuples=True)
B.execute(T0.MOCK)
B.execute(T0.BRIDGE_MOCK)
B.globals().CO = B.execute(open(os.path.join(T0.CONTENT, "mpfever_co.lua"), encoding="utf-8").read())
B.execute("function aiEvent(st, name, param)\n  local api = api2\n  if false then\n" + m_loan.group(0) + "  end\nend\n")
B.execute(r'''
function loanCase(param)
  local st = { co = CO.new("separate", 100, 2000000) }
  st.co.list[2] = { id = 2, key = "ai:1", name = "AI", color = 3, ent = 200 }
  st.co.loan = { [2] = { availableLoans = {
    { amount = 5000000, duration = 12, percentage = 0.05 },
    { amount = 70000000, duration = 288, percentage = 0.2 },
    { amount = 10000000, duration = 60, percentage = 0.1 },
    { amount = 2000000, duration = 24, percentage = 0.08 },
  }, obtainedLoans = {} } }
  LOANEV = {}
  param.mpfCo = 2
  aiEvent(st, "ai_loan", param)
  return table.concat(LOANEV, ",")
end
''')
brun = B.eval("function(code) local f = assert(load(code)) return f() end")
check(brun("return loanCase({ pick = 1, max = 1, need = 495000 })") == "Obtain 2 2000000", "needs 495 000: the smallest offer that covers it (2 million)")
check(brun("return loanCase({ pick = 1, max = 1, need = 6000000 })") == "Obtain 2 10000000", "needs 6 million: 10 million")
check(brun("return loanCase({ pick = 1, max = 1, need = 99000000 })") == "Obtain 2 70000000", "none covers it: the largest")
check(brun("return loanCase({ pick = 1, max = 1, need = 3000000 })") == "Obtain 2 5000000", "needs 3 million: 5 million, not the lowest payment (2 million)")
check(brun("return loanCase({ pick = 1, max = 1 })") == "Obtain 2 2000000", "no need given (MPFEVER_AILOANNEED=0): the lowest monthly payment, as before")

sys.exit(1 if failures else 0)
