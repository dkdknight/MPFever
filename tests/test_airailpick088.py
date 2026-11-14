"""Which railway a computer company builds first (0.8.8, mpfever_ai.lua: RL.pick, RL.need, RL.route's and RP.route's second
answer, RL.project, RP.project; MPFEVER_AIRAILPICK).

The tests of 2026-11-14 (three computer companies, 25 minutes at x4, twice): the Hard company's railway was the route of the
best score, grain over 12.1 km, 19.8 million for a company of 2 to 3 million: "railway ... waits for 19767380 (has 2000000)",
look after look, and no railway was ever built, while a route of 3 km costs half of it. Now the company takes the best route
among those it can pay at once, and when it can pay none, the cheapest one, which it will afford first.
MPFEVER_AIRAILPICK=0: the best score whatever its price, as before.
Offline, through lupa with the mocked game of tests/ai_mock.py.
Needs lupa (pip install lupa). Run: python tests/test_airailpick088.py
"""
import os
import sys

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker

check, failures = checker()
L, M = load()
run = L.eval("function(code) local f = assert(load(code)) return f() end")
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content", "mpfever_ai.lua"),
           encoding="utf-8").read().replace("\r\n", "\n")

print("RL.need")
check(run("return M.f.RL.need(0, 0)") == 3800000, "two stations and a depot: 3.8 million")
check(run("return M.f.RL.need(12100, 6500000)") == 3800000 + 12100 * 1.3 * 600 + 6500000, "the track by the metre (1.3 times the distance) and the train")

print("RL.pick")
run('''
ENV.MPFEVER_AIRAILPICK = nil
-- the session's routes: the best score is the long one
function routes() return {
  { id = "long", d = 12100, score = 12100 * 900 },
  { id = "mid", d = 6000, score = 6000 * 700 },
  { id = "short", d = 2600, score = 2600 * 400 },
  { id = "none", d = 3000, score = 3000 * 9000, notrain = true },   -- (the best score of all, and no train on sale for its cargo)
} end
function need(r) return r.notrain and math.huge or M.f.RL.need(r.d, 4000000) end
function pick(spare) local r = M.f.RL.pick(routes(), need, spare); return r and (r.id .. " " .. tostring(r.need)) end
''')
check(run("return pick(2000000)").startswith("short "), "2 million to spare, none can be paid: the cheapest one (the shortest wait): " + str(run("return pick(2000000)")))
check(run("return pick(10000000)").startswith("short "), "10 million: only the short one can be paid: that one")
check(run("return pick(13000000)").startswith("mid "), "13 million: the short and the middle one can be paid: the better of the two")
check(run("return pick(30000000)").startswith("long "), "30 million: all of them: the best score, as before")
check(run("local r = M.f.RL.pick(routes(), need, 30000000); return r.need") == 3800000 + 12100 * 1.3 * 600 + 4000000, "    its price noted on the route")
check(run("return pick(1e12)").startswith("long "), "a route with no train on sale is never taken for its score while another can be built")
check(run("local r = M.f.RL.pick({ { id = 'x', d = 3000, score = 5, notrain = true } }, need, 1e12); return r and r.id") == "x",
      "    alone: that one (the caller says there is no train, as before)")
check(run("return M.f.RL.pick({}, need, 1e12)") is None and run("return M.f.RL.pick(nil, need, 1e12)") is None, "no route: none")
run("ENV.MPFEVER_AIRAILPICK = '0'")
check(run("return pick(2000000)").startswith("none "), "MPFEVER_AIRAILPICK=0: the best score whatever its price, as before: " + str(run("return pick(2000000)")))
run("ENV.MPFEVER_AIRAILPICK = nil")

print("the code")
check("	return best, all\nend" in src[src.index("function RL.route(E, co, lines, stations)"):src.index("function RL.pick(routes, need, spare)")],
      "RL.route: every route found, besides the best (its first answer is unchanged)")
rp = src[src.index("function RP.route(E, towns, taken)"):]
check("	return best, all\nend" in rp[:rp.index("\nend\n") + 5], "RP.route: every pair found too")
pj = src[src.index("function RL.project(E, co, lines, money, begin)"):]
pj = pj[:pj.index("\nend\n")]
check("local r, routes = RL.route(E, co, lines, stations)" in pj and "r = RL.pick(routes, function(x) local t = trainOf(x.cargo); return t and RL.need(x.d, t.price) or math.huge end," in pj
      and "money - (A.loanCash or 0) - RESERVE) or r" in pj, "the freight railway: chosen by what the company can pay (its money less its loans' and its reserve)")
check("local need = RL.need(r.d, train.price)" in pj and "if money - (A.loanCash or 0) < RESERVE + need then" in pj, "    then only begun with the money for all of it, as before")
pp = src[src.index("function RP.project(E, co, lines, money, begin)"):]
pp = pp[:pp.index("\nend\n")]
check("r = RL.pick(routes, function(x) return RL.need(x.d, train.price) end, money - (A.loanCash or 0) - RESERVE) or r" in pp,
      "the passenger railway: the same")

if failures:
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1)
print("\nPASS")
