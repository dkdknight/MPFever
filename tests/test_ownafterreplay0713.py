"""Test of #161/#166's fix (0.7.13, mod/mpfever_1/content/mpfever_bridge.script.lua: runNativeRelease, G.ownWaitsReplay).

yoyo's game, 2026-11-08 19:59:33Z: yoyo's held build 11 and YkeWoudstra's (YkeWoudstra#11:62) were announced for the same step,
t=10880600. yoyo ranks after YkeWoudstra, so G.sameStepWait kept build 11 back while YkeWoudstra's announcement was there; but
nativeArrived drops the announcement as soon as the replay's first command is sent ("REPLAY SEND ... [frame 39926]"). That replay
was a signal by the engine's conversion: two commands, a dry run and then the build. Build 11 was released on the next frame
(39927), between them, and the simulation took it for the replay ("taken as a replay" twice): never shipped ("native build 11
produced nothing"), its town statistics counted into YkeWoudstra's ("TOWN STATS DIFFER ... (2 proposal(s) here)"), a
resynchronisation; Bence#11:160 on YkeWoudstra's game the same way (#161). Now a held build is not released while a replay is in
the engine's hands (its command not answered, the frames after the answer, the stops placed again after a street); it goes once
the replay is applied. MPFEVER_OWNAFTERREPLAY=0: as before. The real functions run through lupa:
  - releaseOne, runNativeRelease, G.sameStepWait, G.ownWaitsReplay, replaySend and G.eoCheckHold, case by case and frame by
    frame: the commands reach the engine in the order dry run, build, own build (with the switch at 0: dry run, own build,
    build, the order of #166); BUILDLEAD unchanged; a paused build waits by its own branch as before, and now for the stops
    placed again after a street too (G.stopsAfterBusy: that branch released it between the street and its stops);
  - replayTwoStep (a station replayed in two steps: the street part alone, then the construction 3 frames after its answer),
    frame by frame: the frames after the street part's answer ended in the very frame the construction's command is sent, and
    the own build, released earlier in that frame, went between the two parts; now street part, construction, own build, held
    or paused (with the switch at 0: as before);
  - SIM.townClose's reason, with the number of proposals added up here (MPFEVER_TOWNWHYN=0: as before);
  - the autotest H.samestep: deferredSend's hook (a build held for the chosen step, once), the rank and the step on each game.
Needs lupa. Run: python tests/test_ownafterreplay0713.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
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
RS = grab(r"^local function replaySend\(cmd, cb, noGate\)\n.*?^end\n", "replaySend")
EOC = grab(r"^G\.eoCheckHold = function\(\)\n.*?^end\n", "G.eoCheckHold")
TK = grab(r"^SIM\.TOWNKEYS = [^\n]*\n", "SIM.TOWNKEYS")
TC = grab(r"^SIM\.townClose = function\(st, rc\)\n.*?^end\n", "SIM.townClose")
DS = grab(r"^local function deferredSend\(cmd, cb, proposal, still\)\n.*?^end\n", "deferredSend")
SS = grab(r"^H\.samestep = function\(from, p\)\n.*?^end\n", "H.samestep")
SSA = grab(r"^H\.samestep_at = function\(from, p\)\n.*?^end\n", "H.samestep_at")
TWO = grab(r"^function replayTwoStep\(a\)\n.*?^end\n", "replayTwoStep")

print("the code")
line = [l for l in RUN.split("\n") if l.startswith("\t\telseif ((now >= r.at and (gameSpeed() == 0")]
check(len(line) == 1 and line[0].endswith("and not G.sameStepWait(r.at, G.me) and not G.ownWaitsReplay(r) then"),
      "the release of a held build (not paused, not BUILDLEAD) checks G.ownWaitsReplay last")
check("\t\t\tlocal busy = (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or (G.stopsAfterBusy ~= nil and os.getenv(\"MPFEVER_OWNAFTERREPLAY\") ~= \"0\")\n" in RUN,
      "the paused branch keeps its own rule, the stops placed again after a street added (not with MPFEVER_OWNAFTERREPLAY=0)")
check('\t\t\tif os.getenv("MPFEVER_OWNAFTERREPLAY") ~= "0" then G.replayQuiet = math.max(G.replayQuiet or 0, G.frames + 4) end\n'
      '\t\t\tG.waits[#G.waits + 1] = { at = G.frames + 3, fn = buildConstruction }\n' in TWO,
      "replayTwoStep: the frames after the street part's answer last past the construction's command (not with MPFEVER_OWNAFTERREPLAY=0)")
check('os.getenv("MPFEVER_OWNAFTERREPLAY") == "0"' in OWN, "MPFEVER_OWNAFTERREPLAY=0: as before")
check('os.getenv("MPFEVER_TOWNWHYN") == "0"' in TC, "MPFEVER_TOWNWHYN=0: the reason as before")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, CMDS, SENT, ANSWERS = {}, {}, {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function logged(pat) local n = 0 for _, l in ipairs(LOGS) do if l:find(pat, 1, true) then n = n + 1 end end return n end
STEP = 200
NOW, SPEED = 10880600, 0
function gameTime() return NOW end
function gameSpeed() return SPEED end
function expireShipIds() end
function nativeCtl(s) CMDS[#CMDS + 1] = s end
function toSim(k, p) end
function buildEffects() end
function withActor(who, f, ...) return f(...) end
-- the engine: a command is answered ANSWER_DELAY frames after it was sent (a dry run is refused, as G.eoDryRun's is; so is
-- a street part with its construction in the two-step case, see race2)
ANSWER_DELAY = 2
REFUSED = { dry = true, together = true }
O = { event = function() return "nop" end,
	sendCommand = function(cmd, cb)
		if cmd ~= "nop" then CMDS[#CMDS + 1] = cmd end
		if cb then ANSWERS[#ANSWERS + 1] = { at = G.frames + ANSWER_DELAY, cb = cb, ok = not REFUSED[cmd] } end
	end }
function answer()
	local keep, due = {}, {}
	for _, a in ipairs(ANSWERS) do if a.at <= G.frames then due[#due + 1] = a else keep[#keep + 1] = a end end
	ANSWERS = keep
	for _, a in ipairs(due) do a.cb({}, a.ok) end
end
function newG()
	G = { frames = 39900, natRelease = {}, natWait = {}, natReleased = 0, natShipIds = {}, pt = { of = {} }, session = {}, me = "yoyo",
		eoHoldOwn = true, replayOut = 0, replayQuiet = 0, waits = {} }
	G.ptKey = function(o, id) return tostring(o) .. "#" .. tostring(id) end
	G.ptMayGo = function(seq) return true end
	G.ptDone = function() end
	G.restale = function() return false end
	G.nstopStanding = function() return false end
	G.nstopWillStand = function() return false end
	G.simTick = function() return 1 end
	G.preCleanAt = function() end
	G.gateOn = function() return false end
	LOGS, CMDS, SENT, ANSWERS = {}, {}, {}, {}
	ENV = {}
	NOW, SPEED = 10880600, 0
end
newG()
''')
L.execute(REL.replace("local function releaseOne", "function releaseOne", 1))
L.execute(RUN.replace("local function runNativeRelease", "function runNativeRelease", 1))
L.execute(RS.replace("local function replaySend", "function replaySend", 1))
GF = SSW + OWN + EOC


def fresh():
    L.execute("newG()")
    L.execute(GF)


run = L.eval("function(code) local f = assert(load(code)) return f() end")

print("case by case")
fresh()
run('G.natRelease = { { id = 11, at = NOW } }; G.natWait = { { origin = "YkeWoudstra#11", at = NOW, id = 98 } }; runNativeRelease()')
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "(1) the other's build ranked first is announced for this step: held (G.sameStepWait, as before)")
run("G.natWait = {}; G.replayOut = 1; runNativeRelease(); runNativeRelease()")
check(run("return #G.natRelease == 1 and G.natRelease[1].id == 11 and #CMDS == 0") is True,
      "(2) its announcement dropped as its replay is sent (nativeArrived), its command not answered: still held")
check(run('return logged("native build 11 for t=10880600 waits: a replay is in the engine\'s hands")') == 1, "    said once", run("return LOGS[1]"))
run("G.replayOut = 0; G.replayQuiet = G.frames + 3; G.eoHoldOwn = false; runNativeRelease()")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "(3) answered, the frames after the answer: held (MPFEVER_EOCHECKHOLD=0 too)")
run("G.frames = G.replayQuiet; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 11" and logged("native build 11 released at t=10880600") == 1') is True,
      "(4) the replay applied: released at its step")
fresh()
run("G.natRelease = { { id = 12, at = NOW } }; G.stopsAfterBusy = G.frames; runNativeRelease()")
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "(5) stops placed again after a street (G.stopsAfterBusy): held")
run("G.stopsAfterBusy = nil; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 12"') is True, "    done: released")
fresh()
run('ENV.MPFEVER_OWNAFTERREPLAY = "0"; G.natRelease = { { id = 11, at = NOW } }; G.replayOut = 1; runNativeRelease()')
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 11"') is True, "(6) MPFEVER_OWNAFTERREPLAY=0: released at once, as before")
check(run('return logged("OWN BUILD 11 released while a replay is in the engine\'s hands") == 1 and logged("waits: a replay") == 0') is True,
      "    and said (the race of #166)")
fresh()
run("G.natRelease = { { id = 13, at = NOW, lead = true } }; G.replayOut = 1; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 13" and logged("at once (BUILDLEAD)") == 1') is True,
      "(7) a build released at once (BUILDLEAD): unchanged")
fresh()
run('G.natRelease = { { id = 14, at = NOW, paused = true } }; G.pt.of["yoyo#14"] = 5; G.replayOut = 1; runNativeRelease()')
check(run("return #G.natRelease == 1 and #CMDS == 0") is True, "(8) a paused build: held by its own rule while a replay is out (unchanged)")
run("G.replayOut = 0; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 14" and logged("waits: a replay") == 0') is True, "    then released in its turn, as before")
fresh()
run('G.natRelease = { { id = 18, at = NOW, paused = true } }; G.pt.of["yoyo#18"] = 6; G.stopsAfterBusy = G.frames; runNativeRelease(); runNativeRelease()')
check(run("return #G.natRelease == 1 and #CMDS == 0") is True,
      "(8b) a paused build in its turn while the stops of a street replayed before it are placed again (G.stopsAfterBusy): held")
run("G.stopsAfterBusy = nil; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 18" and logged("native build 18: turn 6") == 1') is True,
      "    the stops placed: released in its turn")
fresh()
run('ENV.MPFEVER_OWNAFTERREPLAY = "0"; G.natRelease = { { id = 18, at = NOW, paused = true } }; G.pt.of["yoyo#18"] = 6; G.stopsAfterBusy = G.frames; runNativeRelease()')
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 18"') is True, "    MPFEVER_OWNAFTERREPLAY=0: released at once, as before")
fresh()
run("G.natRelease = { { id = 15, at = NOW } }; G.replayOut = 0; G.replayQuiet = 0; runNativeRelease()")
check(run('return #G.natRelease == 0 and CMDS[1] == "releaseid 15" and logged("waits") == 0') is True, "    no replay in hand: released at once, as before")
check(run("return G.ownWaitsReplay({ id = 16, at = NOW })") is False, "    G.ownWaitsReplay: no replay, no wait")
fresh()
run("SPEED = 1; G.natRelease = { { id = 17, at = NOW + 400 } }; G.replayOut = 1; runNativeRelease()")
check(run("return #G.natRelease == 1 and #CMDS == 0 and logged(\"waits\") == 0") is True, "    a build not due yet: held as before, nothing said")

print("frame by frame (#166)")
L.execute(r'''
function race()
	-- yoyo's build 11 held for this step; YkeWoudstra's (ranked first) announced for it too; its replay, a signal by the engine's
	-- conversion, arrives at the second frame (runNativeReplays, after runNativeRelease in the same frame)
	G.natRelease = { { id = 11, at = NOW } }
	G.natWait = { { origin = "YkeWoudstra#11", at = NOW, id = 98 } }
	for f = 1, 40 do
		G.frames = G.frames + 1
		answer()
		runNativeRelease()
		if f == 2 then
			G.natWait = {}
			replaySend("dry", function(res, ok)
				-- (G.replayNativeStop: the build made of the dry run's answer, then the count of the stops)
				replaySend("build", function() G.eoCheckHold() end)
			end)
		end
	end
	return table.concat(CMDS, ",")
end
''')
fresh()
got = run("return race()")
check(got == "dry,build,releaseid 11", "the own build reaches the engine after the replay's two commands", got)
check(run('return #G.natRelease == 0 and logged("native build 11 released at t=10880600") == 1 and logged("waits: a replay") == 1') is True,
      "    released at the same step, the wait said once")
fresh()
run("G.eoHoldOwn = false")
got = run("return race()")
check(got == "dry,build,releaseid 11", "    MPFEVER_EOCHECKHOLD=0 too", got)
fresh()
run('ENV.MPFEVER_OWNAFTERREPLAY = "0"')
got = run("return race()")
check(got == "dry,releaseid 11,build", "MPFEVER_OWNAFTERREPLAY=0: between them, as in #166", got)
fresh()
run("ANSWER_DELAY = 1")
got = run("local r = race(); ANSWER_DELAY = 2; return r")
check(got == "dry,build,releaseid 11", "    an engine answering on the next frame: the same order", got)

print("frame by frame, a construction replayed in two steps")
L.execute(r'''
local function cp(t) if type(t) ~= "table" then return t end local r = {} for k, v in pairs(t) do r[k] = cp(v) end return r end
function twoStepStubs()
	STREET_FORMS = { { v = "minimal", ctx = "terrainNoCleanup" } }
	-- (the engine's commands named by what they were made of: the street part with the construction, alone, the construction)
	C = { copy = cp, ser = function() return "" end, marshal = function() return {} end,
		rebuildArgs = function(fn, args, opts) return { opts.noStreet and "construction" or (#(args[1].toAdd or {}) > 0 and "together" or "street") }, 1 end }
	R = { translateIn = function() return {} end, allEdges = function() return {} end }
	api = { cmd = { make = function(tag) return tag end } }
	function editsConstruction() return false end
	function isConstructionSegment() return false end
	function shortErr(e) return tostring(e) end
	function replayFailed(a, why) FAILED = why end
	function logRefusal() end
	FAILED = nil
	G.gateGroup = function() end
	G.ownTracksRemoved = function() return false end
	G.bind = {}
end
function race2(paused)
	-- yoyo's build 11 held for this step (paused: its turn after YkeWoudstra's); YkeWoudstra's (ranked first), a station,
	-- announced for it too; its replay comes at the second frame (runNativeReplays, after runNativeRelease in the same frame) and
	-- is made in two steps: the street part with the construction (refused), the street part alone, the construction
	twoStepStubs()
	G.natRelease = { { id = 11, at = NOW, paused = paused } }
	MAYGO = not paused
	G.ptMayGo = function() return MAYGO end
	if paused then G.pt.of["yoyo#11"] = 5 else G.natWait = { { origin = "YkeWoudstra#11", at = NOW, id = 98 } } end
	local a = { uid = "YkeWoudstra#11:62", fn = "make", args = { { toAdd = { { fileName = "station.con" } }, toRemove = {},
		proposal = { addedSegments = {}, addedNodes = {}, removedSegments = {} } } } }
	for f = 1, 40 do
		G.frames = G.frames + 1
		answer()
		runNativeRelease()
		if f == 2 then
			-- (its announcement dropped as it is sent, see nativeArrived; a paused replay's turn done, see runNativeReplays)
			G.natWait = {}
			MAYGO = true
			replayTwoStep(a)
		end
		-- (G.waits last, as guiUpdate runs them)
		local current = G.waits
		G.waits = {}
		for _, w in ipairs(current) do if G.frames >= w.at then w.fn() else G.waits[#G.waits + 1] = w end end
	end
	return table.concat(CMDS, ",")
end
''')
L.execute(TWO)
fresh()
got = run("return race2(false)")
check(got == "together,street,construction,releaseid 11", "the own build reaches the engine after the construction, the second part", got)
check(run('return FAILED == nil and logged("two steps: street part BUILT") == 1 and logged("two steps: construction BUILT") == 1 '
          'and #G.natRelease == 0 and logged("native build 11 released at t=10880600") == 1') is True,
      "    both parts built, the own build released at its step")
fresh()
run("G.eoHoldOwn = false")
got = run("return race2(false)")
check(got == "together,street,construction,releaseid 11", "    MPFEVER_EOCHECKHOLD=0 too", got)
fresh()
got = run("return race2(true)")
check(got == "together,street,construction,releaseid 11", "    a paused build in its turn: the same order", got)
fresh()
run('ENV.MPFEVER_OWNAFTERREPLAY = "0"')
got = run("return race2(false)")
check(got == "together,releaseid 11,street,construction", "MPFEVER_OWNAFTERREPLAY=0: released while the replay is out, as before", got)
fresh()
run('ENV.MPFEVER_OWNAFTERREPLAY = "0"')
got = run("return race2(true)")
check(got == "together,street,releaseid 11,construction", "    paused: between the two parts, as before", got)

print("SIM.townClose's reason")
L.execute("SIM = {}\n" + TK + TC)
L.execute(r'''
function townWhy(n)
	local st = {}
	SIM.townClose(st, { n = n, uid = "YkeWoudstra#11:62", tok = "k", at = 10880600,
		exp = { al = 0, ar = 0, tr = 0, rk = 0, ba = 0, br = 0, tv = 0 },
		got = { al = 4.287, ar = 152.744, tr = 3.225, rk = 0, ba = 0, br = 0, tv = 0 } })
	return st.townDiffs and st.townDiffs[1].why
end
''')
fresh()
got = run("return townWhy(2)")
check(got == "town stats differ (builder/here, 2 proposal(s)): al 0.000/4.287, ar 0.000/152.744, tr 0.000/3.225",
      "the number of proposals added up here in the reason (2: a build of this game taken for the replay)", got)
check(run('return logged("TOWN STATS DIFFER for build YkeWoudstra#11:62 (2 proposal(s) here): al 0.000/4.287")') == 1, "    the log line as before")
run('ENV.MPFEVER_TOWNWHYN = "0"')
got = run("return townWhy(2)")
check(got == "town stats differ (builder/here): al 0.000/4.287, ar 0.000/152.744, tr 0.000/3.225", "MPFEVER_TOWNWHYN=0: as before", got)
run("ENV = {}")
check(run("local st = {}; SIM.townClose(st, { n = 1, uid = 'u', exp = { al = 1 }, got = { al = 1 } }); return st.townDiffs == nil") is True,
      "    alike: nothing asked for, as before")

print("the autotest H.samestep")
L.execute(r'''
function stampFor(t) return t end
function pausedStamp(t) return t + 1 end
function markPending() end
function send(k, p) SENT[#SENT + 1] = { k = k, p = p } end
function stillOk() return true end
C = { refundList = function() return {} end, compactProposal = function() return {} end, ROLE = "host" }
api = { gui = { construction = { getRefundableEntities = function() return {} end } } }
function dsG()
	G.resyncRefuse = function() return false end
	G.autoBuildSeq = 0
	G.buildLead = false
	G.wbpOf = setmetatable({}, { __mode = "k" })
	NOW = 1000000
end
''')
L.execute(DS.replace("local function deferredSend", "function deferredSend", 1))
fresh()
run("dsG(); G.autoStampAt = 1030000; deferredSend('road', nil)")
check(run('return G.natRelease[1].at == 1030000 and SENT[1].k == "nat_pending" and SENT[1].p.at == 1030000 and G.autoStampAt == nil') is True,
      "deferredSend: the build held for the step chosen (announced for it), taken once")
run("deferredSend('road2', nil)")
check(run("return G.natRelease[2].at == 1000200 and SENT[2].p.at == 1000200") is True, "    the next build: stamped as before")
run("G.autoStampAt = 900000; deferredSend('road3', nil)")
check(run("return G.natRelease[3].at == 1000200 and G.autoStampAt == nil") is True, "    a step already passed: stamped as before")
run("G.session.pauseAt = 1000000; G.autoStampAt = 1030000; deferredSend('road4', nil)")
check(run("return G.natRelease[4].at == 1000001 and G.autoStampAt == nil") is True, "    in a pause: stamped as before")

L.execute(r'''
AUTO = { running = false }
H = {}
function H.dsignal(from, p) DONE = "signal@" .. tostring(G.autoStampAt) end
function runScenario(p) DONE = "road@" .. tostring(G.autoStampAt) end
function autoFinish() end
function wait(n)
	for i = 1, n do
		G.frames = G.frames + 1
		local w = G.waits
		G.waits = {}
		for _, x in ipairs(w) do if x.at <= G.frames then x.fn() else G.waits[#G.waits + 1] = x end end
	end
end
''')
L.execute(SS + SSA)
fresh()
run('C.ROLE = "host"; G.me = "yoyo"; G.peers = { YkeWoudstra = {} }; NOW = 1234567; DONE = nil; H.samestep(nil, { role = "host" })')
check(run('return DONE == "road@1260000" and SENT[1].k == "samestep_at" and SENT[1].p.at == 1260000 and G.autoStampAt == nil') is True,
      "the host ranked second: a road held for T (3 periods of 50 steps ahead), T sent", run("return DONE"))
check(run('return logged("SAMESTEP T=1260000 rank=2") == 1') is True, "    said")
fresh()
run('C.ROLE = "client"; G.me = "YkeWoudstra"; G.peers = { yoyo = {} }; NOW = 1236000; DONE = nil; H.samestep(nil, { role = "client" }); wait(5)')
check(run("return DONE == nil") is True, "the client waits for the host's T")
run("H.samestep_at(nil, { at = 1260000 }); wait(2)")
check(run('return DONE == "signal@1260000" and logged("SAMESTEP T=1260000 rank=1") == 1 and G.autoStampAt == nil') is True,
      "    then, ranked first, a signal held for the host's T", run("return DONE"))
fresh()
run('C.ROLE = "client"; G.me = "YkeWoudstra"; G.peers = { yoyo = {} }; NOW = 1236000; DONE = nil; H.samestep(nil, { role = "client" }); wait(620)')
check(run('return DONE == "signal@1260000" and logged("computed here") == 1') is True, "    no T from the host in 10 s: computed here", run("return DONE"))
fresh()
run('C.ROLE = "host"; G.me = "Bence"; G.peers = { yoyo = {} }; AUTO.running = true; DONE = nil; H.samestep(nil, { role = "host" }); AUTO.running = false')
check(run("return DONE == nil and #SENT == 0") is True, "    another scenario running: nothing")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
