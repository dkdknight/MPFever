"""Test of #296's fix (0.8.8, mod/mpfever_1/content/mpfever_bridge.script.lua: runNativeRelease, G.ptAfterPause).

Kasper (host) + Eier, 2026-11-14 00:55: three builds in the pause of a session save, all at t=122318400, turns given by the
host: Eier#1:322 (5), Kasper:215 (6), Eier#1:323 (7). The host applied 5, 6, 7. Eier's game still held its own build 713
(turn 7) when the pause ended (speed 2 again, the game standing at the build's step): runNativeRelease left the pause's branch
(gameSpeed() == 0) for the usual one, which ranks the builds of one step by their players' names ("Eier#1" before "Kasper") and
released 713 before Kasper's turn 6, whose data came 9 s after its announcement. The two builds got each other's ids, the towns
drifted, a resynchronisation. Now a build made in a pause keeps its turn until it goes, whatever the speed since.
MPFEVER_PTAFTERPAUSE=0: as before. The real functions run through lupa (releaseOne, runNativeRelease, G.sameStepWait,
G.ownWaitsReplay, G.ptMayGo, G.ptAdvance, G.ptDone).
Needs lupa. Run: python tests/test_ptafterpause088.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def grab(pattern, name):
    m = re.search(pattern, src, re.S | re.M)
    check(m is not None, name + " found")
    return m.group(0) if m else ""


try:
    import lupa.lua52 as lupa
except ImportError:
    print("FAIL lupa is not installed (pip install lupa): this test needs it")
    sys.exit(1)

REL = grab(r"^local function releaseOne\(r, at, how\)\n.*?^end\n", "releaseOne")
RUN = grab(r"^local function runNativeRelease\(\)\n.*?^end\n", "runNativeRelease")
SSW = grab(r"^G\.sameStepWait = function\(at, origin\)\n.*?^end\n", "G.sameStepWait")
OWN = grab(r"^G\.ownWaitsReplay = function\(r\)\n.*?^end\n", "G.ownWaitsReplay")
ADV = grab(r"^G\.ptAdvance = function\(\)\n.*?^end\n", "G.ptAdvance")
MAY = grab(r"^G\.ptMayGo = function\(seq\)\n.*?^end\n", "G.ptMayGo")
DONE = grab(r"^G\.ptDone = function\(seq\)\n.*?^end\n", "G.ptDone")

print("the code")
check('G.ptAfterPause = os.getenv("MPFEVER_PTAFTERPAUSE") ~= "0"\n' in src, "MPFEVER_PTAFTERPAUSE=0: as before")
check("\t\telseif now >= r.at and r.paused and (gameSpeed() == 0 or G.ptAfterPause) then\n" in RUN,
      "the pause's branch: also once the pause is over")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, CMDS = {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function logged(pat) local n = 0 for _, l in ipairs(LOGS) do if l:find(pat, 1, true) then n = n + 1 end end return n end
STEP = 200
NOW, SPEED = 122318400, 0
function gameTime() return NOW end
function gameSpeed() return SPEED end
function expireShipIds() end
function nativeCtl(s) CMDS[#CMDS + 1] = s end
function toSim(k, p) end
O = { event = function() return "nop" end, sendCommand = function(cmd, cb) if cmd ~= "nop" then CMDS[#CMDS + 1] = cmd end end }
function newG(after)
	G = { frames = 132135, natRelease = {}, natWait = {}, natReleased = 0, natShipIds = {}, session = { pauseAt = 122318400 }, me = "Eier#1",
		eoHoldOwn = true, replayOut = 0, replayQuiet = 0, waits = {}, pt = { next = 8, done = 5, of = {}, skip = {}, seen = true },
		ptAfterPause = after }
	G.ptKey = function(o, id) return tostring(o) .. ":" .. tostring(id) end
	G.restale = function() return false end
	-- (the game stands at the build's step: its own held build and the host's announcement hold it there)
	G.nstopStanding = function() return true end
	G.nstopWillStand = function() return false end
	G.simTick = function() return 1 end
	G.preCleanAt = function() end
	G.gateOn = function() return false end
	G.pullBuildLog = function() end
	LOGS, CMDS = {}, {}
	ENV = {}
	NOW, SPEED = 122318400, 0
end
-- Eier's game at 00:55:04: its build 713 held in the pause, turn 7; Kasper's build (turn 6) announced for the same time, its
-- data not here yet; turn 5 (Eier's own 712) applied
function scene()
	G.natRelease = { { id = 713, at = NOW, paused = true, frame0 = G.frames } }
	G.pt.of["Eier#1:713"] = 7
	G.pt.of["Kasper:344"] = 6
	G.natWait = { { origin = "Kasper", at = NOW, id = 344 } }
end
''')
L.execute(REL.replace("local function releaseOne", "function releaseOne", 1))
L.execute(RUN.replace("local function runNativeRelease", "function runNativeRelease", 1))
GF = SSW + OWN + ADV + MAY + DONE
run = L.eval("function(code) local f = assert(load(code)) return f() end")


def fresh(after):
    L.execute("newG(%s)" % ("true" if after else "false"))
    L.execute(GF)
    L.execute("scene()")


print("Eier's game, frame by frame")
fresh(True)
run("for i = 1, 60 do G.frames = G.frames + 1; runNativeRelease() end")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "in the pause: its build waits for turn 6 (as before)")
# the save ends: the session's pause is over, the game still stands at the build's step
run("SPEED = 2; G.session.pauseAt = nil; for i = 1, 20 do G.frames = G.frames + 1; runNativeRelease() end")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "the pause over, turn 6 not applied here yet: still held (#296)", run("return table.concat(CMDS, ',')"))
# Kasper's data comes: the replays' queue applies turn 6 (G.ptDone), its announcement dropped
run("G.natWait = {}; G.ptDone(6); G.frames = G.frames + 1; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 713" and logged("native build 713: turn 7") == 1') is True,
      "turn 6 applied: released in its turn, at its step", run("return table.concat(LOGS, ' | ')"))
check(run("return G.pt.done") == 7, "    its turn done")

print("as before")
fresh(False)
run("for i = 1, 60 do G.frames = G.frames + 1; runNativeRelease() end")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "MPFEVER_PTAFTERPAUSE=0, in the pause: waits for its turn")
run("SPEED = 2; G.session.pauseAt = nil; G.frames = G.frames + 1; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 713" and logged(": turn ") == 0') is True,
      "    the pause over: released by the rank of the names, before turn 6 (the order of #296)")
fresh(True)
run("G.pt.of['Eier#1:713'] = nil; SPEED = 2; G.session.pauseAt = nil; for i = 1, 600 do G.frames = G.frames + 1; runNativeRelease() end")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "no turn from the host yet, the pause over: waits for it (10 s at most)")
run("G.frames = G.frames + 2; runNativeRelease()")
check(run('return #G.natRelease == 0 and logged("no turn from the host in 10 s, released now") == 1') is True, "    none in 10 s: released, said (as in a pause)")
fresh(True)
run("G.natRelease = { { id = 714, at = NOW } }; G.natWait = {}; SPEED = 2; G.session.pauseAt = nil; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 714" and logged(": turn ") == 0') is True,
      "a build not made in a pause: the usual branch, unchanged")
fresh(True)
run("G.natRelease = { { id = 715, at = NOW + 400, paused = true } }; G.pt.of['Eier#1:715'] = 6; G.natWait = {}; SPEED = 2; G.session.pauseAt = nil; runNativeRelease()")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "a paused build not due yet: held, as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
