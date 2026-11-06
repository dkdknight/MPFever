"""Offline test of "no wait for the answer" (0.8 work, MPFEVER_NOWAIT=1, a session setting of the host).

Another player's build is replayed at its step: the replay goes to the engine as the simulation comes to that step, and the
engine applies it at the start of the next batch, at that step. This game then stood there until the engine's answer came back,
a handshake later: about 0.4 s for every build of every other player (the "LAG" lines, "443 ms of replay, 1 command(s)"; 85 % of
the replays are one command; a replay of the user's 2026-11-03 session: 109 replays, median 447 ms, 70 s stood per game in
13 minutes). The interface and the engine's handshake (CGame::Sync) run on the same thread, so a command sent in this frame is
in the next swap whatever the stop point does meanwhile: once the replay's build is handed to the engine, nothing has to hold the
game at the step. The bridge's functions are taken from the real file and run through lupa (Lua 5.2) with a mocked state:
  - G.gateHolds: no replay under way: nil; its build not handed yet (a construction's conversion, refused on purpose, under
    way): its step; handed: false; a replay of several commands (G.gateGroup): its step until it is done;
  - replaySend: the replay's build counts as handed, a dry run (G.gateDryNext) does not; both are sent at once, as before;
  - nativeHoldAt: a replay whose build is in the engine's hands no longer holds the game where it is; one not handed yet holds
    at its step, not at the game's time; without the setting: as before;
  - runNativeReplays marks every native replay but terrain edits, assets, company joins and paused builds;
  - the replays that end with one command call G.gateSingle; those made of several call G.gateGroup; a refused form's next
    one is logged (G.gateLate).
(0.8 research, kept out: holding a replay's Lua command in the native module and adding it again at the swap crashed the game,
a command destructor called on nothing; the tools' builds are the only ones the module can hold.)
Run: python tests/test_nowait.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
OPTIONS = os.path.join(HERE, "..", "launcher", "Options.cs")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
i = src.index("-- ================================================================== no wait for the answer (0.8, MPFEVER_NOWAIT=1)")
j = src.index("-- ================================================================== native deferral (with mpfever_native.dll)")
nw_code = src[i:j]
m_send = re.search(r"^local function replaySend\(cmd, cb, noGate\)\n.*?^end\n", src, re.S | re.M)
m_hold = re.search(r"^local function nativeHoldAt\(\)\n.*?^end\n", src, re.S | re.M)
check(m_send is not None and m_hold is not None, "replaySend and nativeHoldAt found")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 100000
LOGS, SENT = {}, {}
function gameTime() return NOW end
function overshootReserve() return 2 end
function log(s) LOGS[#LOGS + 1] = s end
function buildEffects() end
function toSim() end
function withActor(who, f, ...) return f(...) end
C = { ACTIVE = true }
O = { steps = true, sendCommand = function(cmd, cb) SENT[#SENT + 1] = cmd end }
K = { JOIN_GATHER = 60 }
G = { frames = 5000, natRelease = {}, natWait = {}, nativeQueue = {}, simStill = function() return true end, joinTurn = function() return true end }
'''
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(MOCK)
L.execute(nw_code)
L.execute(m_send.group(0).replace("local function replaySend", "function replaySend", 1))
L.execute(m_hold.group(0).replace("local function nativeHoldAt", "function nativeHoldAt", 1))
run = L.eval("function(code) local f = assert(load(code)) return f() end")

check(run("return G.gateOn()") is False, "off unless the host's setting says so")
L.execute("G.gateWanted = true")
check(run("return G.gateHolds()") is None, "no replay under way: nothing to hold")
L.execute("G.gateCur = { at = 102000, uid = 'B#1:4' }")
check(run("return G.gateHolds()") == 102000, "a replay whose build is not handed yet (its conversion under way): held at its step")
L.execute("G.gateDryNext = true; replaySend('dry', function() end)")
check(run("return (G.gateCur.handed or 0)") == 0 and list(L.globals().SENT.values()) == ["dry"], "a dry run is sent at once and is not the replay's build")
L.execute("replaySend('build', function() end)")
check(run("return G.gateCur.handed") == 1 and list(L.globals().SENT.values()) == ["dry", "build"], "the replay's build: sent as before, counted as handed")
check(run("return G.gateHolds()") == 102000, "a replay not known to end with that command: held at its step until its answers, as before")
L.execute("G.gateSingle()")
check(run("return G.gateHolds()") is False, "its last command (G.gateSingle) handed: nothing holds the game for it")
L.execute("G.replayOut = 1; G.replayQuiet = G.frames + 3")
got = run("return tostring(nativeHoldAt())")
check(got == "nil", "its answer not back yet: the game is not held where it is any more", got)
L.execute("G.gateCur.handed = 0")
got = run("return tostring(nativeHoldAt())")
check(got == "102000", "not handed yet: held at the replay's step, not at the game's time", got)
L.execute("G.gateCur.handed = 1; G.gateGroup('a stop replay')")
check(run("return G.gateHolds()") == 102000, "a replay of several commands: held at its step until it is done")
check(any("stays at t=102000" in str(s) for s in L.globals().LOGS.values()), "and the log says so")
L.execute("G.gateCur = { at = 102000, uid = 'B#1:5', handed = 1, single = true }; G.gateLate('a refused form'); G.gateLate('again')")
check(sum("after the build's step" in str(s) for s in L.globals().LOGS.values()) == 1, "a follow-up after the step: logged once")
L.execute("G.replayOut = 0; G.replayQuiet = 0; G.gateCur = { at = 98000, uid = 'B#1:9', handed = 2, group = 'a stop replay' }")
got = run("return tostring(nativeHoldAt())")
check(got == "nil", "a replay of several commands done (its answers back): it no longer holds the game at its past step", got)
L.execute("G.replayOut = 1; G.replayQuiet = G.frames + 3")
L.execute("G.gateCur = nil")
got = run("return tostring(nativeHoldAt())")
check(got == "100000", "no such replay: a replay in the engine's hands holds the game where it is, as before", got)
L.execute("G.gateWanted = false; G.gateCur = { at = 102000, handed = 1, single = true }")
got = run("return tostring(nativeHoldAt())")
check(got == "100000", "setting off: as before, even with a replay marked", got)

check('local nw = G.gateOn() and a.native and not a.paused and not seq and a.fn ~= "terrainEdit" and a.fn ~= "assetBuild" and a.fn ~= "mpfCoJoin"' in src,
      "runNativeReplays: every native replay but terrain edits, assets, company joins and paused builds")
# (the real sessions' logs, 2026-11-06: 1970 replays by the script forms, every one built with its FIRST form, and 10 with every
# form refused (reloaded anyway); 322 stop replays, none tried again: a replay ends with one command or fails)
check(src.count("pcall(G.gateSingle)") == 8 and src.count("if not (a.stopsAfter and #a.stopsAfter > 0) then pcall(G.gateSingle) end") == 2
      and "if #plan == 1 then pcall(G.gateSingle) end" in src,
      "the replays that end with one command: forms and native streets (not when stops follow), removals and replacements, constructions, stops, native stops, one-segment and merged upgrades")
for fn, mark in [("replayUpgrade", 'pcall(G.gateGroup, "a street upgrade of "'), ("placeStopsAfter", 'pcall(G.gateGroup, "stops placed again after the street")'),
                 ("replayTwoStep", 'pcall(G.gateGroup, "a build in two steps")')]:
    check(mark in src, "%s keeps the game at the step until it is done" % fn)
check(src.count("G.gateDryNext = true; replaySend(dry") == 4 and src.count("G.gateDryNext = true; replaySend(dry2") == 1, "the four dry runs are marked")
check('pcall(G.gateLate, "a refused form, the next one tried")' in src, "a refused form's next one is logged")
check('G.gateWanted = os.getenv("MPFEVER_NOWAIT") == "1"' in src[src.index("local function resumeAfterLoad(state)"):][:900], "the setting is read at every start, the first one too")
check('name:sub(1, 6) == "replay"' not in src and "gateSend" not in src, "no command is held by the native module (that crashed the game)")
opt = open(OPTIONS, encoding="utf-8").read()
check('Key = "MPFEVER_NOWAIT", Session = true, DefaultOn = false' in opt, "a session setting of the host, off by default")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
