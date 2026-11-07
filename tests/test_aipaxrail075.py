"""The computer companies' passenger trains (0.7.5, mpfever_ai.lua: RP), offline through lupa (Lua 5.2) with the mocked game of
tests/ai_mock.py. The user, 2026-11-07: give the computer companies what they cannot do yet.
  - the passenger station's modules are the ones the game's own template makes (modular_station.script's createTemplateFn,
    templateIndex 0: passengers, through, one track; run on the game's file on 2026-11-07, its result kept here: 2 and 3
    platforms, eras a/b/c, simple track before 1930, main and side buildings, stairs and roofs); with the game's file on this
    PC (base/content/stations/rail.zip) the template is run again and compared too;
  - RP.isPax tells a passenger station from a cargo one (RL.stationParams); the freight railway (RL.underway) leaves the
    passenger stations out, RL.manage counts a passenger line's waiting passengers;
  - the pair of towns: the biggest pair RP.MIN to RP.MAX apart (not one too close nor too far), not a town with a passenger
    station near its centre, not a pair left before;
  - experimental, off by default (the track's plan between two towns took the planner over 2 s, tests px1/px2):
    MPFEVER_AIPAXRAIL=1: every level, =hard: the Hard level only, MPFEVER_AIRAIL=0: never; at most 3 pairs left a session;
  - the step: the passenger railway after the cargo railway and its trains, a new one only when no railway of cargo is under
    way or waits for its money; the stations near a town by RL.corridor with RP.place; both stops of its line load the
    passengers (freightStop with the passengers' cargo).
Needs lupa (pip install lupa). Run: python tests/test_aipaxrail075.py
"""
import os, sys, zipfile

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker

HERE = os.path.dirname(os.path.abspath(__file__))
AI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ai.lua")
check, failures = checker()

MS = "/stations/rail/modular_station/"
TRK = "/trainstation___/infrastructure/track/"


def game_station(year, n):
    """The game's template's result (2026-11-07) for a passenger station of one track: n = 2 (3 platforms) or 3 (4)."""
    era = "c" if year >= 1990 else "b" if year >= 1950 else "a"
    track = TRK + ("standard/standard" if year >= 1930 else "simple/simple") + ".street_template"
    s, e = -(n // 2), -(-n // 2)
    out = {}
    if n == 2:
        out[3400000] = MS + f"main_building_1_era_{era}.module"
    else:
        out[3400005] = MS + f"side_building_1_era_{era}.module"
        out[3400020] = MS + f"main_building_1_era_{era}.module"
        out[3400035] = MS + f"side_building_1_era_{era}.module"
    for j in range(s, e + 1):
        out[7400000 + 10 * j] = MS + f"platform_passenger_era_{era}.module"
        out[8401000 + 10 * j] = track
        out[10400000 + 10 * j] = MS + f"platform_passenger_roof_era_{era}.module"
    out[10800000] = MS + f"addon_platform_passenger_stairs_era_{era}.module"
    return out


def live_template():
    """The game's createTemplateFn, when the game is on this PC (not on the CI)."""
    z = os.path.join(HERE, "..", "..", "base", "content", "stations", "rail.zip")
    if not os.path.exists(z):
        return None
    try:
        src = zipfile.ZipFile(z).read("rail/modular_station/modular_station.script.lua").decode("utf-8")
    except Exception:
        return None
    import lupa.lua52 as l
    L = l.LuaRuntime()
    L.execute("require = function() return setmetatable({}, {__index=function() return function() end end}) end; ug_require = require")
    d = L.eval("function(s) local f, e = load(s, 'ms'); if not f then error(e) end; f(); return data() end")(src)
    mk = L.eval("function(y, l) return { templateIndex = 0, length = l, tracks = 1, year = y, catenary = 1, trackType = y >= 1930 and 2 or 1 } end")
    return lambda y, n: {int(k): v for k, v in d.createTemplateFn(L.table(), mk(y, n)).items()}


def main():
    L, M = load()
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    RP, RL = M.f.RP, M.f.RL
    src = open(AI, encoding="utf-8").read()

    print("station modules")
    live = live_template()
    for year in (1925, 1972, 1995):
        for n in (2, 3):
            p = RP.stationParams(year, n)
            got = {int(k): str(v.name).replace("::", "", 1) for k, v in p.modules.items()}
            exp = game_station(year, n)
            check(got == exp, f"{year}, {n + 1} platforms: the game's template's modules" + ("" if got == exp else f" (got {sorted(got.items())})"))
            if live:
                g2 = live(year, n)
                check(got == g2, f"  and the game's own template on this PC says the same")
            check(p.tracks == 1 and p.length == n and p.catenary == 1 and p.trackType == (2 if year >= 1930 else 1), f"{year}: its parameters")
    check(RP.isPax(L.eval("function(p) return { params = p } end")(RP.stationParams(1972, 3))), "a passenger station is one")
    check(not RP.isPax(L.eval("function(p) return { params = p } end")(RL.stationParams(1972, 3))), "a cargo station is not")
    check(not RP.isPax(L.eval("{ params = 'x' }")) and not RP.isPax(L.eval("{}")), "nor a construction without modules")

    print("towns")
    run('''
      TP = function(e, x, y, size) return { e = e, town = true, pos = { x = x, y = y, z = 0 }, size = size } end
      TOWNS = { TP(1, 0, 0, 3000), TP(2, 5000, 0, 2500), TP(3, 1500, 0, 2800), TP(4, 0, 20000, 2900), TP(5, -6000, 0, 900) }
      E.G.AI.paxTried = nil
    ''')
    r = run("return M.f.RP.route(E, TOWNS, {})")
    check(r is not None and {r["from"].e, r.to.e} == {1, 2}, "the biggest pair in reach: 1 and 2 (3 is 1.5 km away, 4 is 20 km away)" + " " + str(r and (r["from"].e, r.to.e)))
    r = run("return M.f.RP.route(E, TOWNS, { [2] = true })")
    check(r is not None and {r["from"].e, r.to.e} == {3, 5}, "a town with a passenger station near its centre is left: 3 and 5 (7.5 km, before 1 and 5, 6 km)" + " " + str(r and (r["from"].e, r.to.e)))
    run("E.G.AI.paxTried = { ['1-2'] = true }")
    r = run("return M.f.RP.route(E, TOWNS, {})")
    check(r is not None and {r["from"].e, r.to.e} != {1, 2}, "a pair left before is not tried again" + " " + str(r and (r["from"].e, r.to.e)))
    run("E.G.AI.paxTried = nil")
    check(run("return M.f.RP.route(E, { TP(1, 0, 0, 3000), TP(3, 1500, 0, 2800) }, {})") is None, "no pair in reach: none")

    print("levels")
    def on(level, env=None, rail=None):
        run(f"ENV.MPFEVER_AIPAXRAIL = {repr(env) if env else 'nil'}; ENV.MPFEVER_AIRAIL = {repr(rail) if rail else 'nil'}")
        M.p.set(level)
        v = RP.on()
        run("ENV.MPFEVER_AIPAXRAIL = nil; ENV.MPFEVER_AIRAIL = nil")
        return v
    check(not on(3) and not on(2) and not on(1), "experimental: off by default, every level (the track's plan between two towns takes too long, px1/px2)")
    check(on(1, "1") and on(2, "1") and on(3, "1"), "MPFEVER_AIPAXRAIL=1: every level")
    check(on(3, "hard") and not on(2, "hard"), "MPFEVER_AIPAXRAIL=hard: the Hard level only")
    check(not on(3, "1", "0"), "MPFEVER_AIRAIL=0: never")
    check("if (A.paxFailed or 0) >= RP.FAILS then return false end" in src, "at most RP.FAILS pairs left in a session, then none tried")
    M.p.set(2)

    print("the step")
    i = src.find("local r = RL.project(E, co, myLines(E, co.ent, true), money, begin)")
    j = src.find("if RL.manage(E, co, money) == true then return end", i)
    k = src.find("local rp = RP.project(E, co, myLines(E, co.ent, true), money, begin and r ~= \"wait\" and not A.rail)", j)
    check(0 < i < j < k, "after the cargo railway and its trains; a new one only when no cargo railway is under way or waits")
    u = src[src.find("function RL.underway(E, co, lines)"):]
    u = u[:u.find("\nend\n")]
    check("if not RP.isPax(s.c) then keep[#keep + 1] = s end" in u, "the cargo railway leaves the passenger stations out")
    mg = src[src.find("function RL.manage(E, co, money)"):]
    check("if cargo == nil and RP.isPaxGroup(E, l.groups[1]) then" in mg[:mg.find("\nend\n")], "RL.manage counts a passenger line's waiting passengers")
    pj2 = src[src.find("function RP.project(E, co, lines, money, begin)"):src.find("function RP.finish(E, co, sa, sb, money)")]
    a1 = pj2.find("P.pa = RP.place(E, co, r.from, a, \"A\")")
    a2 = pj2.find("P.pb = RP.place(E, co, r.to, a + math.pi, \"B\")")
    a3 = pj2.find("pcall(RL.corridor, E, co, r.from, r.to, a, function(_, _, town) return found[town.e] end)")
    check(0 < a1 < a2 < a3 and "place = place or RL.stationPlace" in src,
          "its plan in three looks: the first station's place, the second's, the track's way with them (RL.corridor); the cargo's as before")
    check("if os.clock() - t0 > RP.PLACE then return fallback end" in src, "  each place found within RP.PLACE s (the first plan held the host's game over 2 s, px1)")
    check("RP.buildStation(E, co, r.from, a, \"A\", P.pa)" in pj2 and "if A.paxBegun[r.key] > 2 then RP.leave(E, r.key" in pj2,
          "  the first station built where its plan found it; a pair whose first station never came after two asks is left")
    pj = src[src.find("function RP.project(E, co, lines, money, begin)"):]
    check("if A.paxLookAt and E.G.frames < A.paxLookAt then return false end" in pj[:600], "one look every RP.LOOK frames (each reads every construction of the map)")
    lv = src[src.find("function RP.leave(E, key, why)"):]
    check("A.paxNextAt = E.G.frames + 3600" in lv[:500], "a pair left: the next one a minute later (each plan holds the host's game a little)")
    fin = src[src.find("function RP.finish(E, co, sa, sb, money)"):]
    check("template.stops = { freightStop(E, sa.term, stop0, pid), freightStop(E, sb.term, stop0, pid) }" in fin, "both stops of its line load the passengers")
    check("RL.buyTrain(E, co, depot.depot, t, pid, depot.pos)" in fin and "local t = RL.train(E, pid)" in fin, "its train: coaches for the passengers")

    print(f"\n{len(failures)} failure(s)" if failures else "\nall passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
