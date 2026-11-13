"""Offline test: the Finances window's « Bank account / Company value » chart shows the player's own company (0.8.6, #190;
mod/mpfever_1/content/mpfever_valuechart.lua, U.valueChart in mpfever_ui.script.lua, switch MPFEVER_VALUECHART).

#190 (Creeper and Akamari, 0.7.16): with one company per player, the game's chart read the world's logbook series
"companyBalance" and "companyTotalValue", written by the engine for the savegame's company only: every other player saw the
host's history, with their own figures as the last point.
  - each new point of the world's "companyBalance" -> this game's company's bank account and value noted at its time, kept in a
    file per savegame (the first point's time) and company; a point later than the game's time is dropped;
  - getChart asked for exactly those two series, on a game whose company is not the savegame's: this company's history (the
    same fields the game's chart reads, the world chart's x markers, round y markers, an equals method); setLastValue writes
    its last point; anything else (another chart, the savegame's company, one company for everybody, no point yet, an error):
    the game's own answer;
  - MPFEVER_VALUECHART=0: nothing wrapped;
  - the interface installs it at its first tick and looks for a new point every 300 ticks.
Needs lupa (pip install lupa). Run: python tests/test_valuechart086.py
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


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(os.path.join(CONTENT, "mpfever_valuechart.lua"), encoding="utf-8").read()
ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
FILES = {}
IO = { open = function(path, mode)
  if mode == "rb" then
    if not FILES[path] then return nil end
    return { read = function() return FILES[path] end, close = function() end }
  end
  return { write = function(_, s) FILES[path] = s end, close = function() end }
end }
LOG = {}
-- the world's series: first point at 1000, last point LAST; the game's chart answer is marked
LAST = 5000
PLAYER = 31
REALCALLS = 0
NOW = 5000
api = { type = { ComponentType = { GAME_TIME = "GT", LOG_BOOK = "LB" } },
  engine = {
  getComponent = function(e, t)
    if t == "GT" then return { gameTime = NOW } end
    if t == "LB" then return { name2log = { companyBalance = { times = { 1000, 2000 }, values = { 1, 2 } } } } end
  end,
  util = {
  getCalendarDate = function(t) return { year = 1900 + math.floor(t / 12000), month = math.floor(t / 1000) % 12 + 1, day = 1 } end,
  getWorld = function() return 1 end,
  getPlayer = function() return PLAYER end,
  headquarters = { getCompaniesValue = function() return { balance = BAL, totalAssets = 900, debt = 100 } end },
  logbook = { getChart = function(e, names) REALCALLS = REALCALLS + 1
    return { game = true, series = { { { 1000, 3000, LAST }, { 1, 2, 3 } } }, xMarkers = { 1000, 3000, 5000 }, yMarkers = { 0, 10 } } end },
  chart = { setLastValue = function(c, i, v) c.gameSet = v end },
} } }
BAL = 500
''')
L.execute("VC = (function() " + src + " end)()")

# pure functions
L.execute('PTS = VC.parse("3000 10 20\\n1000 5 7\\nbad line\\n")')
check(L.eval("#PTS") == 2 and L.eval("PTS[1][1]") == 1000, "parse: numbers only, in time order")
check(L.eval("VC.format(PTS)") == "1000 5 7\n3000 10 20\n", "format: one line per point")
L.execute("P2 = VC.add(PTS, 2000, 1, 2)")
check(L.eval("#P2") == 2 and L.eval("P2[2][1]") == 2000, "add: a later point (an older save of the game) dropped")
m = L.eval("VC.niceMarkers(-130, 870, 5)")
ms = [m[i] for i in range(1, len(m) + 1)]
check(ms[0] <= -130 and ms[-1] >= 870 and len(ms) <= 12, "niceMarkers cover the range", ms)
check(L.eval('VC.isBalanceChart({ "companyBalance", "companyTotalValue" })') is True, "the balance chart's two series recognised")
check(L.eval('VC.isBalanceChart({ "companyBalance" })') is False and L.eval('VC.isBalanceChart({ "itemsTransported1" })') is False, "  no other chart")

# in game: install, poll, chart
L.execute('''
U = { coMap = { [31] = 1, [77] = 2 }, myCo = 2, canon = 31 }
local function mine() for e, id in pairs(U.coMap) do if id == U.myCo then return e end end end
VC.install({ log = function(s) LOG[#LOG + 1] = s end, io = IO, dir = "D", mine = mine,
  canon = function() return U.canon end, separate = function() return U.coMap ~= nil and U.myCo ~= nil end })
''')
check(L.eval("api.engine.util.logbook.getChart({},{}) ~= nil") is True, "installed (getChart wrapped)")
# the host (its company is the savegame's): the game's own chart
L.execute("PLAYER = 31; U.myCo = 1; R1 = api.engine.util.logbook.getChart(1, { 'companyBalance', 'companyTotalValue' })")
check(L.eval("R1.game") is True, "the savegame's company: the game's own chart")
# a client, no point yet: the game's own
L.execute("PLAYER = 77; U.myCo = 2; R2 = api.engine.util.logbook.getChart(1, { 'companyBalance', 'companyTotalValue' })")
check(L.eval("R2.game") is True, "a client with no point yet: the game's own chart")
# a point noted
L.execute("VC.poll()")
check(L.eval('FILES["D\\\\mpfever_value_1000_1_2_77.txt"]') == "5000 500 1300\n", "a point noted at the game's time: balance, assets + balance - debt",
      L.eval('FILES["D\\\\mpfever_value_1000_1_2_77.txt"]'))
L.execute("NOW = 6000; BAL = 700; VC.poll(); VC.poll()")
check(L.eval('FILES["D\\\\mpfever_value_1000_1_2_77.txt"]') == "5000 500 1300\n6000 700 1500\n", "  one point per new game month (twice in a month: once)")
L.execute("R3 = api.engine.util.logbook.getChart(1, { 'companyBalance', 'companyTotalValue' })")
check(L.eval("R3.mpf") is True and L.eval("R3.game") is None, "a client with points: its own company's chart")
check(L.eval("R3.series[1][2][1]") == 500 and L.eval("R3.series[2][2][2]") == 1500, "  its bank account and its value")
check(L.eval("R3.xMarkers[3]") == 5000, "  the world chart's x markers")
L.execute("api.engine.util.chart.setLastValue(R3, 0, 999)")
check(L.eval("R3.series[1][2][2]") == 999 and L.eval("R3.gameSet") is None, "setLastValue writes its last point")
check(L.eval("R3:equals(R3)") is True, "  equals")
L.execute("R4 = api.engine.util.logbook.getChart(1, { 'itemsTransported3' })")
check(L.eval("R4.game") is True, "another chart: the game's own")
L.execute("U.coMap = nil; R5 = api.engine.util.logbook.getChart(1, { 'companyBalance', 'companyTotalValue' })")
check(L.eval("R5.game") is True, "one company for everybody: the game's own")
L.execute("U.coMap = { [31] = 1, [77] = 2 }; NOW = 4000; R6 = api.engine.util.logbook.getChart(1, { 'companyBalance', 'companyTotalValue' })")
check(L.eval("R6.mpf") is None, "points all later than the game's time (an older save): the game's own")

# the switch
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
L2.execute('ENV = { MPFEVER_VALUECHART = "0" }; os.getenv = function(k) return ENV[k] end; ORIG = function() end; api = { engine = { util = { logbook = { getChart = ORIG } } } }')
L2.execute("VC = (function() " + src + " end)(); VC.install({ log = function() end })")
check(L2.eval("api.engine.util.logbook.getChart == ORIG") is True, "MPFEVER_VALUECHART=0: nothing wrapped")

check("pcall(U.valueChart)" in ui and "U.vcTicks % 300 == 1" in ui, "the interface installs it and looks for a point every 300 ticks")

# the interface's state (seen in game 2026-11-13: "no logbook interface here"): api.engine.util.logbook is the engine's own object,
# not a Lua table whose fields can be written: a table in its place answers getChart and hands every other name to the object
L3 = lupa.LuaRuntime(unpack_returned_tuples=True)
L3.execute('''
ENV = {}; os.getenv = function(k) return ENV[k] end
local function ro(fns) return setmetatable({}, { __index = fns, __newindex = function() error("read only") end }) end
REAL = function() return "game" end
LB = ro({ getChart = REAL, getLogValueMostRecent = function() return 42 end })
CH = ro({ setLastValue = function() return "gameSet" end })
api = { engine = { util = { logbook = LB, chart = CH } } }
LOG = {}
''')
L3.execute("VC = (function() " + src + " end)(); VC.install({ log = function(s) LOG[#LOG + 1] = s end, separate = function() return false end })")
check(L3.eval("api.engine.util.logbook ~= LB") is True and L3.eval("api.engine.util.logbook.getChart ~= REAL") is True, "an engine object: a table in its place answers getChart")
check(L3.eval("api.engine.util.logbook.getLogValueMostRecent()") == 42, "  every other name goes to the engine's object")
check(L3.eval("api.engine.util.logbook.getChart(1, { 'x' })") == "game", "  another chart: the game's answer")
check(L3.eval("api.engine.util.chart.setLastValue({}, 0, 1)") == "gameSet", "  setLastValue of the game's charts: the game's")
check("proxy" in L3.eval("LOG[#LOG]"), "  said in the log", L3.eval("LOG[#LOG]"))

check(L.eval("VC.keyOf({ 0, 2000 }, { 2000000, -150, 7 })") == "0_2000000_m150_7", "the savegame's key: the first time and the first values (0 in every game alone)")
check(L.eval("VC.keyOf({}, {})") is None, "  none without entries")
print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
