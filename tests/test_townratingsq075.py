"""Offline test of the towns' noise and traffic ratings kept in steps (0.7.5, DET.installTownRatings).

2026-11-07 08:41, dedicated server (i9-9900KF, 16 threads) and a player (i9-13900KF, 32 threads), MPFever 0.7.4: a reload
"script:towns". The checks' dumps of both games differ in town 18 only:
  cachedRatings.noise.value              0.6701461792 (server)  0.6701197306 (player)
  cachedRatings.traffic_congestion.value 0.9849569798 (server)  0.9851356149 (player)
while all the other measures were identical (vehicles and their positions, persons, lines, streets, money). Noise comes from
the engine's emission grid, as pollution did in issue #126 (kept in steps of 1/64 since 0.7.1), and traffic from the engine's
traffic speed map: sums made on the engine's thread pool. Now:
  - town_util.getRatingNoise and town_util.getRatingTraffic (which the towns' script calls through town_util.GetRating) give
    their values in steps of 1/64, as getRatingPollution does;
  - the report's values fall on the same step on both games (43/64 and 63/64);
  - each has its switch: MPFEVER_NOISEQ / MPFEVER_TRAFFICQ = 0: the engine's value, as before; = <n>: steps of 1/n;
    MPFEVER_POLLUTIONQ still works alone;
  - wrapped once (a second install, a new game, does not wrap them twice); a missing function is said in the log.
Needs lupa (pip install lupa). Run: python tests/test_townratingsq075.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
i = bridge.find("DET.townQ = function(")
j = bridge.find("\nend\n", bridge.find("function DET.installTownRatings()", i)) + 5
check(i > 0 and j > i, "DET.installTownRatings found")
code = bridge[i:j]


def runtime(env=None, noise=True):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
    DET = {}; C = { ACTIVE = true }; LOG = {}; ENV = {}
    os.getenv = function(k) return ENV[k] end
    function log(s) LOG[#LOG + 1] = s end
    VALUE = 0.5
    TU = {}
    TU.getRatingPollution = function(entity, townState) return VALUE end
    if %s then TU.getRatingNoise = function(entity, townState) return VALUE end end
    TU.getRatingTraffic = function(entity, townState) return VALUE end
    -- as the game's GetRating: the module's field is read at each call
    TU.GetRating = function(key)
      if key == "pollution" then return { key = key, getRating = TU.getRatingPollution } end
      if key == "noise" then return { key = key, getRating = TU.getRatingNoise } end
      if key == "traffic_congestion" then return { key = key, getRating = TU.getRatingTraffic } end
    end
    function ug_require(path)
      if path == "/game_mechanics/towns/town_util.tl" then return TU end
      error("module not found: " .. path)
    end
    ''' % ("true" if noise else "false"))
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute(code)
    return L


L = runtime()
L.execute("DET.installTownRatings()")
rate = L.eval('function(key, v) VALUE = v return TU.GetRating(key).getRating(1, {}) end')
check(rate("noise", 0.6701461792) == 43 / 64 and rate("noise", 0.6701197306) == 43 / 64,
      "the report's noise values of town 18 give the same rating (43/64)")
check(rate("traffic_congestion", 0.9849569798) == 63 / 64 and rate("traffic_congestion", 0.9851356149) == 63 / 64,
      "the report's traffic values of town 18 give the same rating (63/64)")
check(rate("pollution", 0.7808833144) == 50 / 64, "pollution still in steps of 1/64 (issue #126)")
check(rate("noise", 1.0) == 1.0 and rate("traffic_congestion", 0.0) == 0.0, "1 and 0 kept")
line = L.eval("LOG[1]")
check("noise kept in steps of 1/64" in line and "traffic_congestion kept in steps of 1/64" in line
      and "pollution kept in steps of 1/64" in line and "not seen" not in line, "one log line for the three ratings: " + line)
L.execute("DET.townRatings = nil; DET.installTownRatings()")
check(rate("noise", 0.6701461792) == 43 / 64 and L.eval("TU.__mpfNoise ~= nil and TU.__mpfTraffic ~= nil"),
      "installed a second time (a new game): not wrapped twice")
check(L.eval('(function() VALUE = 0/0; local v = TU.getRatingTraffic(1, {}) return v ~= v end)()') is True,
      "not a number: left as it is")

L = runtime({"MPFEVER_NOISEQ": "0", "MPFEVER_TRAFFICQ": "0"})
L.execute("DET.installTownRatings()")
rate = L.eval('function(key, v) VALUE = v return TU.GetRating(key).getRating(1, {}) end')
check(rate("noise", 0.6701461792) == 0.6701461792 and rate("traffic_congestion", 0.9849569798) == 0.9849569798,
      "MPFEVER_NOISEQ=0 / MPFEVER_TRAFFICQ=0: the engine's values, as before")
check(rate("pollution", 0.7808833144) == 50 / 64 and "MPFEVER_NOISEQ=0" in L.eval("LOG[1]"),
      "pollution keeps its steps; the log says which switch")
L = runtime({"MPFEVER_TRAFFICQ": "16", "MPFEVER_POLLUTIONQ": "0"})
L.execute("DET.installTownRatings()")
rate = L.eval('function(key, v) VALUE = v return TU.GetRating(key).getRating(1, {}) end')
check(rate("traffic_congestion", 0.9849569798) == 1.0 and rate("traffic_congestion", 0.7) == 11 / 16,
      "MPFEVER_TRAFFICQ=16: steps of 1/16")
check(rate("pollution", 0.7808833144) == 0.7808833144 and rate("noise", 0.6701461792) == 43 / 64,
      "MPFEVER_POLLUTIONQ=0 alone: pollution as the engine computes it, noise still in steps")
L = runtime(noise=False)
L.execute("DET.installTownRatings()")
check("noise not found" in L.eval("LOG[1]") and "traffic_congestion kept in steps" in L.eval("LOG[1]"),
      "a rating function missing (another game version): said, the others still kept in steps")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
