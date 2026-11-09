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

# (the review of the fix) game_time.gs's answer also delays its automatic sky by 60 s times the engine's speed, which differs
# between games for a moment around a speed change or a pause: game_time.gs reads the speed as 1 (DET.installSkySpeed)
i = src.index("DET.installSkySpeed = function()")
sk = src[i:src.index("\nend\n", i) + 5]
check("pcall(DET.installSkySpeed)" in src[src.index("	installRandom()\n	pcall(DET.installModCmds)"):][:200],
      "installed in the simulation's update, with the deterministic random numbers")
check('os.getenv("MPFEVER_SKYSPEED") == "0"' in sk and 'package.loaded["mpfever_skyspeed"]' in sk, "MPFEVER_SKYSPEED=0: as before; once per Lua state")
if lupa:
    def runtime():
        R = lupa.LuaRuntime(unpack_returned_tuples=True)
        R.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
log = function(s) end
DET = {}
SPEED = 4
api = { type = { ComponentType = { GAME_SPEED = "GAME_SPEED", GAME_TIME = "GAME_TIME" } },
  engine = { getComponent = function(e, ct) if ct == "GAME_SPEED" then return { speedup = SPEED, millisPerDay = 2000 } end return { gameTime = 5 } end } }
''' + sk + '''
-- game_time.script.tl's handler, as the game loads it (its chunk named after its file), and another script
local handler = load("return function() local g = api.engine.getComponent(0, api.type.ComponentType.GAME_SPEED); return 60005 * (g.speedup > 0 and g.speedup or 1), g.millisPerDay end", "@res/game_mechanics/game_time/game_time.script.lua")()
local other = load("return function() return api.engine.getComponent(0, api.type.ComponentType.GAME_SPEED).speedup end", "@res/mods/x/other.script.lua")()
function delay() local d, m = handler(); return d, m end
function otherSpeed() return other() end
''')
        return R
    R = runtime()
    R.execute("DET.installSkySpeed(); DET.installSkySpeed()")
    d, m = R.eval("delay()")
    check(d == 60005 and m == 2000, "game_time.gs at x4: its delay 60 s (speed read as 1), the rest of the component unchanged", (d, m))
    R.execute("SPEED = 0")
    check(R.eval("delay()")[0] == 60005, "  a game standing at 0 at the same step: the same delay")
    R.execute("SPEED = 4")
    check(R.eval("otherSpeed()") == 4, "another script: the engine's speed, as before")
    check(R.eval("api.engine.getComponent(0, 'GAME_TIME').gameTime") == 5, "  any other component: unchanged")
    R.execute("local w = api.engine.getComponent; DET.installSkySpeed(); assert(api.engine.getComponent == w)")
    check(True, "  installed once (the bridge calls it at every step)")
    R = runtime()
    R.execute('ENV.MPFEVER_SKYSPEED = "0"; DET.installSkySpeed()')
    check(R.eval("delay()")[0] == 4 * 60005, "MPFEVER_SKYSPEED=0: the engine's speed, as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
