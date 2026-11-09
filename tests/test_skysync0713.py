"""Test of issue #172's "script:gametime" resynchronisation (0.7.13, mod/mpfever_1/content/mpfever_bridge.script.lua
executeActionOnce).

CowboyPilot's session, 2026-11-08 15:47: MrWhiskey1 then CowboyPilot moved the calendar's clouds slider. The slider
(gui/game_bar/game_bar_widgets.tl) sets that player's sky only (api.gui.rendering.setEnvironment) and sends the event
"CloudCoverage"/"OnManualCloudCoverageChanged"; game_time.gs answers it on every game with that game's own cloud coverage as its
target (game_time.script.tl: cloudCoverageTarget = worldComponent.cloudCoverage). MrWhiskey1's game alone differed after his
two events, all three after CowboyPilot's thirty, and the host reloaded the game. The slider's value travels with the event: every
game sets it first (makeGameSetCloudCoverageCmd), then applies the event; the same for the time of day's slider
("GameTime"/"OnManualGameTimeChanged", makeGameSetTimeOfDayCmd). MPFEVER_SKYSYNC=0: the event alone, as before.
Needs lupa. Run: python tests/test_skysync0713.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


ex = src[src.index("local function executeActionOnce(a, sendCommand, useCallback, bind, done)"):]
i = ex.index("	if a.fn == \"makeScriptingSendEventCmd\" and type(a.args) == \"table\" and os.getenv(\"MPFEVER_SKYSYNC\") ~= \"0\" then")
blk = ex[i:ex.index("\n\tend\n", ex.index("if sky then", i)) + 6]
j = ex.index("	local isBuild = a.fn == \"makeWorldBuildProposalCmd\"")
check(i < j and ex.index("local okm, missing = pcall(missingEntities", 0) < i,
      "the slider's value is set after the action's checks, just before its own command")
check("makeGameSetCloudCoverageCmd" in blk and "makeGameSetTimeOfDayCmd" in blk and "sendCommand(sky())" in blk,
      "  with the command the action is sent with (the simulation's, or the pause's)")
check("H.skysync = function(from, p)" in src and "api.gui.rendering.setEnvironment(e)" in src,
      "autotest skysync: the slider's two steps, as a player's action")
try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed: the Lua part skipped")
if lupa:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
log = function(s) end
SENT = {}
api = { cmd = {
  makeGameSetCloudCoverageCmd = function(v) return { "cloud", v } end,
  makeGameSetTimeOfDayCmd = function(v) return { "time", v } end } }
function run(a)
	SENT = {}
	local sendCommand = function(c) SENT[#SENT + 1] = c end
''' + blk + '''
	return SENT
end
''')

    def run(args):
        r = L.eval('run({ fn = "makeScriptingSendEventCmd", uid = "CowboyPilot:52", args = ' + args + ' })')
        return [tuple(r[k][i] for i in (1, 2)) for k in sorted(r.keys())]
    got = run('{ "", "CloudCoverage", "OnManualCloudCoverageChanged", 0.62 }')
    check(got == [("cloud", 0.62)], "#172: the clouds' slider: the value set on this game first", got)
    got = run('{ "", "CloudCoverage", "OnManualCloudCoverageChanged", 1.4 }')
    check(got == [("cloud", 1)], "  a value past the slider's end: kept within 0..1", got)
    got = run('{ "", "GameTime", "OnManualGameTimeChanged", 45296.6 }')
    check(got == [("time", 45297)], "the time of day's slider: the time set first, in whole seconds", got)
    got = run('{ "", "GameTime", "OnManualGameTimeChanged", 86400 }')
    check(got == [("time", 0)], "  midnight at the slider's end: 0", got)
    check(run('{ "", "GameTime", "SkipPhase", {} }') == [] and run('{ "", "CloudCoverage", "SetMode", { weatherMode = "Dynamic" } }') == [],
          "the other calendar events (skip, mode): nothing more")
    check(run('{ "mpfever", "mpfever", "co_month", { month = 36 } }') == [], "any other event: nothing more")
    L.execute('ENV.MPFEVER_SKYSYNC = "0"')
    check(run('{ "", "CloudCoverage", "OnManualCloudCoverageChanged", 0.62 }') == [], "MPFEVER_SKYSYNC=0: the event alone, as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
