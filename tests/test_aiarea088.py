"""The computer companies' area by level (0.8.8, mpfever_ai.lua: M.AREA, M.areaPick, M.areaTownOf, areaOf, inArea; the user's
rule of 2026-11-14): Easy works in 3 towns close to one another, Normal in 6, Hard on the whole map. The area is the company's
home town (the town of its oldest station, or, while it has none, the town it would take first) and the towns nearest to it;
its town lines (townsForLines), its passenger railway (RP.towns) and its freight (bestFreight, bestTownFreight, RL.route: an
industry belongs to the area when the town nearest to it does) stay there. What it runs elsewhere is kept. MPFEVER_AIAREA=0:
the whole map for every level, as before. Offline, through lupa with the mocked game of tests/ai_mock.py.
Needs lupa (pip install lupa). Run: python tests/test_aiarea088.py
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

print("the rule")
check(run("return M.AREA.easy") == 3 and run("return M.AREA.normal") == 6 and run("return M.AREA.hard") is None,
      "Easy 3 towns, Normal 6, Hard the whole map")

print("M.areaPick, M.areaTownOf (pure)")
run('''
PTS = {}
-- ten towns on a line, 2 km apart: town 10+i at x = 2000 * i
for i = 0, 9 do PTS[#PTS + 1] = { e = 10 + i, pos = { x = 2000 * i, y = 0 } } end
function names(set) local t = {} for e in pairs(set) do t[#t + 1] = e end table.sort(t) return table.concat(t, ",") end
''')
check(run("local s, o = M.areaPick(PTS, 14, 3); return names(s) .. ' / ' .. table.concat(o, ',')") == "13,14,15 / 14,13,15",
      "three towns: the home and the two nearest (the smaller id first at the same distance)")
check(run("local s = M.areaPick(PTS, 10, 3); return names(s)") == "10,11,12", "a home at the edge of the map: the nearest two on its side")
check(run("local s = M.areaPick(PTS, 14, 6); return names(s)") == "11,12,13,14,15,16", "six towns: the home and the five nearest (of two at the same distance, the smaller id)")
check(run("local s = M.areaPick(PTS, 14, 20); return names(s)") == "10,11,12,13,14,15,16,17,18,19", "fewer towns than the area: all of them")
check(run("return M.areaPick(PTS, 99, 3)") is None, "a home that is no town: no area")
check(run("return M.areaTownOf(PTS, { x = 8900, y = 300 })") == 14, "a place: its nearest town")
check(run("return M.areaTownOf(PTS, { x = 9000, y = 0 })") == 14, "    half way between two: the smaller id")
check(run("return M.areaTownOf({}, { x = 0, y = 0 })") is None, "    no town: none")

WORLD = '''
LINES, VEH, CONS, ACTS, LOG, INDCACHE = {}, {}, {}, {}, {}, {}
G.AI = {}
G.frames = 400000
ENV.MPFEVER_AIAREA = nil
TOWNLIST, TOWNCAP, CENTRE = {}, {}, {}
for i = 0, 9 do
  local t = 10 + i
  TOWNLIST[#TOWNLIST + 1] = t
  -- (the biggest town far from the home: town 19)
  TOWNCAP[t] = { 300 + 100 * i, 0, 0 }
  CENTRE[t] = { x = 2000 * i, y = 0, z = 0 }
end
STATIONS = {}
api.engine.system.stationSystem.getStations = function(t) return STATIONS[t] or {} end
function towns(list) local t = {} for i, x in ipairs(list) do t[i] = x.e end return table.concat(t, ",") end
'''

print("the company's area (areaOf) and its towns (townsForLines)")
run(WORLD)
run("M.p.set(1, 700000, 150000)")      # Easy
check(run("return M.f.areaOf(E, 700)") is None, "Easy, no station yet, no town named: no area yet")
got = run("return towns(M.f.townsForLines(E, 700))")
check(got == "19,18,17", "Easy with no station: its home is the town it would take first (the biggest), its lines stay in its 3 towns: " + str(got))
check(run("return G.AI.areaHome") == 19, "    the home kept")
check(run("local a = M.f.areaOf(E, 700); return a and names(a.towns)") == "17,18,19", "    the area: the home and its two neighbours")
check(run("local n = 0 for _, l in ipairs(LOG) do if tostring(l):find('area (easy, 3 towns)', 1, true) then n = n + 1 end end return n") == 1,
      "    said once in the log")
run(WORLD)
run("M.p.set(1, 700000, 150000); STATIONS[13] = { 5002 }; STATIONS[16] = { 5001, 5003 }; OWN[5001] = 700; OWN[5002] = 700; OWN[5003] = 999")
got = run("return towns(M.f.townsForLines(E, 700))")
check(sorted(got.split(",")) == ["15", "16", "17"], "its oldest station (the smallest id, 5001 in town 16) names its home: towns 15, 16, 17: " + str(got))
check(run("return G.AI.areaHome") == 16, "    found again from its stations (a game reloaded)")
run(WORLD)
run("M.p.set(1, 700000, 150000); STATIONS[13] = { 5002 }; OWN[5002] = 999")
check(run("return towns(M.f.townsForLines(E, 700))") == "19,18,17", "another company's station names no home")
run(WORLD)
run("M.p.set(2, 400000, 150000); STATIONS[14] = { 5001 }; OWN[5001] = 700")
got = run("return towns(M.f.townsForLines(E, 700))")
check(got == "16,15,14,13,12,11", "Normal: 6 towns around its home, the biggest first: " + str(got))
run(WORLD)
run("M.p.set(3, 350000, 150000); STATIONS[14] = { 5001 }; OWN[5001] = 700")
got = run("return towns(M.f.townsForLines(E, 700))")
check(got == "19,18,17,16,15,14,13,12,11,10" and run("return M.f.areaOf(E, 700)") is None, "Hard: the whole map, no area: " + str(got))
run(WORLD)
run("M.p.set(1, 700000, 150000); ENV.MPFEVER_AIAREA = '0'; STATIONS[14] = { 5001 }; OWN[5001] = 700")
got = run("return towns(M.f.townsForLines(E, 700))")
check(got == "19,18,17,16,15,14,13,12,11,10" and run("return M.f.areaOf(E, 700)") is None,
      "MPFEVER_AIAREA=0: the whole map for Easy too, as before: " + str(got))
run("ENV.MPFEVER_AIAREA = nil")

print("two companies starting at once (M.homePick)")
check(run("return M.homePick({ 19, 18, 17, 16 }, {})") == 19, "alone: the first town of its list")
check(run("return M.homePick({ 19, 18, 17, 16 }, { { home = 19, towns = { [19] = true, [18] = true, [17] = true } } })") == 16,
      "another company's area holds its first three: the first town outside it")
check(run("return M.homePick({ 19, 18 }, { { home = 19, towns = { [19] = true, [18] = true } } })") == 18,
      "every town in another one's area: the first that is no other one's home")
check(run("return M.homePick({ 19 }, { { home = 19, towns = { [19] = true } } })") == 19, "    no other town at all: the first")
check(run("return M.homePick({ 19, 18 }, { { home = nil, towns = nil } })") == 19, "a company with no area (Hard) takes nothing")
check(run("return M.homePick({}, {})") is None, "no town: none")
run(WORLD)
# (the session of 2026-11-14: Easy and Normal both took Weiden; here the second company's state sees the first one's area)
run('''
M.p.set(1, 700000, 150000)
FIRST = G.AI
G.AIS = { FIRST }
T1 = towns(M.f.townsForLines(E, 700))
SECOND = {}
G.AIS = { FIRST, SECOND }
G.AI = SECOND
M.p.set(2, 400000, 150000)
T2 = towns(M.f.townsForLines(E, 701))
''')
check(run("return T1") == "19,18,17" and run("return FIRST.areaHome") == 19, "the first company (Easy): at home in the best town, 19")
check(run("return SECOND.areaHome") == 16, "the second (Normal): its home is the best town outside the first one's area: " + str(run("return SECOND.areaHome")))
got = run("return T2")
check(sorted(got.split(",")) == ["13", "14", "15", "16", "17", "18"], "    its six towns around it (areas may touch, the homes differ): " + str(got))
run("G.AI = FIRST; G.AIS = nil")

print("inArea")
run(WORLD)
run("M.p.set(1, 700000, 150000); STATIONS[14] = { 5001 }; OWN[5001] = 700; AR = M.f.areaOf(E, 700)")
check(run("return M.f.inArea(AR, { x = 8000, y = 2500 })") is True, "a place whose nearest town is in the area: in")
check(run("return M.f.inArea(AR, { x = 12100, y = 0 })") is False, "a place nearer to a town outside: out")
check(run("return M.f.inArea(nil, { x = 99999, y = 0 })") is True, "no area: everywhere")

print("the freight and the passenger railway (the code)")
check("it.out = not inArea(A.areaNow, it.pos) or nil" in src, "industries(): one outside the area is marked (no new route from or to it)")
for fn, cond in (("bestFreight", "if not others[p.road.group] and not p.out then"),
                 ("bestFreight", "if q.e ~= p.e and not q.out and not others[q.road.group]"),
                 ("bestTownFreight", "if t.size >= 300 and (not A.areaNow or A.areaNow.towns[t.e]) then"),
                 ("bestTownFreight", "if not ind.out and not others[ind.road.group]"),
                 ("RL.route", "if not near and not a.out and not others[a.road.group]"),
                 ("RL.route", "if b.e ~= a.e and not b.out and not others[b.road.group] and takes(E, b, c) then"),
                 ("RP.towns", "if t.size >= RP.POP and (not ar or ar.towns[t.e]) then")):
    check(cond in src, fn + ": the area")
st = src[src.index("local function step(E)"):]
check(st.index("A.areaNow = areaOf(E, co.ent)") < st.index('ph(E, "freightProject")'), "the step reads the area before its projects")
check('os.getenv("MPFEVER_AIAREA") == "0"' in src, "MPFEVER_AIAREA=0: as before")
check("A.indCache = nil" in src[src.index("local function areaOf(E, ent, first)"):src.index("local function inArea(ar, p)")],
      "the industries read before the area was known are read again with it")

if failures:
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1)
print("\nPASS")
