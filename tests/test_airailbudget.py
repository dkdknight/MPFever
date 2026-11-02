"""Offline test of the time a computer company's railway plan may take (0.6.9, RL.corridor / RL.inTime in mpfever_ai.lua).

Test fz1 of 2026-11-02 (Test Gameplay, two computer companies; 0.6.8's st2 as well): the plan of an 8.9 km railway held the
host's game 17 s ("slowest step of the last minute: 17.355 s"); the other game stopped waiting for the host's builds and
applied them late, a desync. A plan now has RL.BUDGET s (2): past it, the plan is left (the railway is not begun), the game
goes on. The module is loaded through the mocked game (tests/ai_mock.py) with a clock the test moves. Cases:
  - a plan within the budget: its result as before, the deadline cleared;
  - a plan past it: an error that says so (RL.corridor's caller logs it and leaves the railway), the deadline cleared;
  - MPFEVER_AIRAILBUDGET=0: no limit, as before;
  - the checks sit in the slow parts: the world's segments, the search, the ways tried.
Needs lupa (pip install lupa). Run: python tests/test_airailbudget.py
"""
import os, sys

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker, CONTENT

check, failures = checker()
L, M = load()
run = L.eval("function(code) local f = assert(load(code)) return f() end")
run("CLOCK = 0; os.clock = function() return CLOCK end; RL = M.f.RL")

run("RL.corridorIn = function() CLOCK = CLOCK + 1; RL.inTime(); return true, nil end")
check(run("CLOCK = 0; RL.BUDGET = 2; return (RL.corridor())") is True and run("return RL.deadline") is None,
      "a plan within the budget: its result, the deadline cleared")
run("RL.corridorIn = function() CLOCK = CLOCK + 5; RL.inTime(); return true end")
okc, err = run("CLOCK = 0; RL.BUDGET = 2; return pcall(RL.corridor)")
check(okc is False and "longer than 2 s" in str(err) and run("return RL.deadline") is None,
      "a plan past it: left, saying so, the deadline cleared (" + str(err) + ")")
okc = run("CLOCK = 0; RL.BUDGET = 0; local ok, r = pcall(RL.corridor) return ok and r == true")
check(okc is True, "MPFEVER_AIRAILBUDGET=0 (budget 0): no limit, as before")
check(run("RL.deadline = nil; CLOCK = 99; RL.inTime(); return true") is True, "outside a corridor plan: never stopped")

src = open(os.path.join(CONTENT, "mpfever_ai.lua"), encoding="utf-8").read()
check('RL.BUDGET = tonumber(os.getenv("MPFEVER_AIRAILBUDGET") or "") or 2' in src, "2 s by default, MPFEVER_AIRAILBUDGET")
check("if k % 64 == 0 then RL.inTime() end" in src, "checked while the world's segments are read")
check("if visits % 1000 == 0 then RL.inTime() end" in src, "checked in the search")
check("\t\tRL.inTime()\n\t\tlocal sp, _, refused = RL.trackProposal(E, co, -9001" in src.replace("\r\n", "\n"), "checked before each way tried")

sys.exit(1 if failures else 0)
