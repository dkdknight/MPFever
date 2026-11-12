"""Offline test: a computer company's long-term freight line no longer waits for its buses' growth (0.8.3, MPFEVER_AILTALWAYS).

The user's choice for the AI: "finish the freight by truck". A test of 10 minutes at x4 (Test Gameplay, Normal, money 1.7 to 2.4
million) opened three bus lines and not one truck: the freight waited the whole time for the company's growth (mayExpand: its bus
lines "still filling"). The long-term freight line (0.6, ltProject) is an investment of its own, budgeted, one at a time, judged
on its trend, which never holds the others' growth: it now waits only for its own budget. mpfever_ai.lua is read.
Run: python tests/test_ailtalways083.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ai.lua")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(AI, encoding="utf-8").read().replace("\r\n", "\n")
check("the long-term freight line is tried while the growth waits (MPFEVER_AILTALWAYS=0: only while it may grow)",
      '\tif (grow or os.getenv("MPFEVER_AILTALWAYS") ~= "0") and ltProject(E, co, stops, lines, vehicles, money) == true then return end\n' in src)
check("  the old line is gone", "\tif grow and ltProject(E, co, stops, lines, vehicles, money) == true then return end\n" not in src)
lt = src[src.index("local function ltProject(E, co, stops, lines, vehicles, money)"):]
lt = lt[:lt.index("\nend\n")]
check("  ltProject keeps its own guards: one at a time (pending, investing), its cooldown, the bootstrap lines, its budget and a truck besides the reserve",
      "if A.ltPending then return false end" in lt and 'if lt.state == "invest" then return false end' in lt
      and "if A.ltNextAt and now < A.ltNextAt" in lt and "if #lines < (LV.bootstrap or 0) then return false end" in lt
      and "if not budget or spare < RESERVE + truck + budget then" in lt)
check("  the other freight (plenty of money) still waits for the growth", "if os.getenv(\"MPFEVER_AIFREIGHT\") ~= \"0\" and grow and freightRich then" in src)

# (0.8.3, the same test) a long-term line that earned back all it cost is paid (deliveries in lumps: two good samples in a row
# seldom come), MPFEVER_AILTPAIDNET=0: as before
try:
    import lupa.lua52 as lupa
    m = re.search(r"^local function ltJudge\(lt, now, P, trend\)\n.*?^end\n", src, re.S | re.M)
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end\n" + m.group(0).replace("local function ltJudge", "function ltJudge"))
    judge = L.eval("""function(spent, env)
      ENVV.MPFEVER_AILTPAIDNET = env
      local lt = { born = 0, budget = 362013, spent = spent, prod0 = 72, proofFrom = 0,
        samples = { { bal = -17055, prod = 72, ratio = 0.36 }, { bal = -23481, prod = 72, ratio = 0.12 }, { bal = 321727, prod = 72, ratio = 12.4 }, { bal = -33059, prod = 72, ratio = -0.09 }, { bal = -29058, prod = 72, ratio = 0.01 } } }
      return (ltJudge(lt, 10000000, { horizon = 99999999, proof = 1000, grow = 1.25 }, true))
    end""")
    check("the grain line of the test (earned 192057 more than it cost, lumps): paid, no longer ended", judge(-192057, None) == "paid")
    check("  a line still costing (spent 40536): judged as before (no growth, no better result: end)", judge(40536, None) == "end")
    check("  MPFEVER_AILTPAIDNET=0: ended as before", judge(-192057, "0") == "end")
except ImportError:
    print("lupa is not installed: the verdict's cases not run")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
