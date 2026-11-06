"""Offline test of the towns' pollution rating kept in steps (0.7.1, issue #126, DET.installTownRatings).

Issue #126 (Dimi and HolderLord, 0.6.11/0.7.0): 11 reloads in one session, all "script:towns". The checks' dumps of both games
differ in one value only: towns.townStates.N.cachedRatings.pollution.value, for 2 towns of 21 (0.7808833144 on the host,
0.7808838594 on the client: the engine's emission grid sums come out a little different on PCs of 32 and 24 threads). Pollution
stays on (it is part of the game and the players asked for it back in 0.6.9):
  - town_util.getRatingPollution (which the towns' script calls through town_util.GetRating) gives its value in steps of 1/64;
  - the values of the two games in the report fall on the same step; two values 4.4e-6 apart fall on either side of a step
    about once in 3600 computations;
  - installed once, in a session only, from the simulation's update; MPFEVER_POLLUTIONQ=0: the engine's value, as before;
    MPFEVER_POLLUTIONQ=<n>: steps of 1/n.
Needs lupa (pip install lupa). Run: python tests/test_pollutionq.py
"""
import os, random, sys

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
i = bridge.find("DET.townQ = function()")
j = bridge.find("\nend\n", bridge.find("function DET.installTownRatings()", i)) + 5
check(i > 0 and j > i, "DET.installTownRatings found")
code = bridge[i:j]


def runtime(env=None, active=True, reachable=True):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
    DET = {}; C = { ACTIVE = %s }; LOG = {}; ENV = {}
    os.getenv = function(k) return ENV[k] end
    function log(s) LOG[#LOG + 1] = s end
    VALUE = 0.5
    TU = {}
    TU.getRatingPollution = function(entity, townState) return VALUE end
    TU.GetRating = function(key) if key == "pollution" then return { key = "pollution", getRating = TU.getRatingPollution } end end
    REACH = %s
    function ug_require(path)
      if REACH and path == "/game_mechanics/towns/town_util.tl" then return TU end
      error("module not found: " .. path)
    end
    ''' % ("true" if active else "false", "true" if reachable else "false"))
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute(code)
    return L


L = runtime()
L.execute("DET.installTownRatings()")
rate = L.eval('function(v) VALUE = v return TU.GetRating("pollution").getRating(1, {}) end')
check(rate(0.7808833144) == 50 / 64 and rate(0.7808838594) == 50 / 64, "the report's two values of town 12 give the same rating (50/64)")
check(rate(0.8847128345) == rate(0.884713107), "and those of town 20")
check(rate(1.0) == 1.0 and rate(0.0) == 0.0, "1 and 0 kept")
check(rate(0.5 + 1 / 128 - 1e-9) == 0.5 and rate(0.5 + 1 / 128 + 1e-9) == 0.5 + 1 / 64, "rounded to the nearest step")
check("steps of 1/64" in L.eval("LOG[1]") and "not seen" not in L.eval("LOG[1]"), "a log line, the ratings list uses it")
L.execute("DET.townRatings = nil; DET.installTownRatings()")
check(rate(0.7808833144) == 50 / 64 and L.eval("TU.__mpfPollution ~= nil"), "installed a second time (a new game): not wrapped twice")
check(L.eval('(function() VALUE = 0/0; local v = TU.getRatingPollution(1, {}) return v ~= v end)()') is True, "not a number: left as it is")

# how often two values 4.4e-6 apart fall on either side of a step
random.seed(126)
apart = 0
N = 200000
q = 64
for _ in range(N):
    v = random.random()
    if int(v * q + 0.5) != int((v + 4.4e-6) * q + 0.5):
        apart += 1
check(apart / N < 1 / 2000, "two games 4.4e-6 apart: on either side of a step %d times in %d" % (apart, N))

L = runtime({"MPFEVER_POLLUTIONQ": "0"})
L.execute("DET.installTownRatings()")
check(L.eval('(function() VALUE = 0.7808833144 return TU.GetRating("pollution").getRating(1, {}) end)()') == 0.7808833144,
      "MPFEVER_POLLUTIONQ=0: the engine's value")
L = runtime({"MPFEVER_POLLUTIONQ": "16"})
L.execute("DET.installTownRatings()")
check(L.eval('(function() VALUE = 0.7808833144 return TU.GetRating("pollution").getRating(1, {}) end)()') == 12 / 16,
      "MPFEVER_POLLUTIONQ=16: steps of 1/16")
L = runtime(active=False)
L.execute("DET.installTownRatings()")
check(L.eval('(function() VALUE = 0.7808833144 return TU.GetRating("pollution").getRating(1, {}) end)()') == 0.7808833144
      and L.eval("DET.townRatings") is None, "alone (no session): the game's value, tried again later")
L = runtime(reachable=False)
L.execute("DET.installTownRatings()")
check("not reachable" in L.eval("LOG[1]"), "the towns' module not reachable: said in the log")

i = bridge.find("local function update(userParams, state, dt)")
check("pcall(DET.installTownRatings)" in bridge[i:i + 4000], "installed from the simulation's update")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
