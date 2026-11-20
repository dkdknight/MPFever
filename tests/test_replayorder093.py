"""Offline test: the next builds wait for a replay's answer while the engine makes no handshake (a save), issue #447 (0.9.3,
MPFEVER_REPLAYORDER; mod/mpfever_1/content/mpfever_bridge.script.lua, G.replayPendingBusy / G.replayQueueBusy / nativeHoldAt).

The bug (#447, yoyo's game, 2026-11-19 22:19:42): YkeWoudstra#6:1, a paused track with two signals, sent its dry run while the
game was saving (« The COOP game.sav », 11.2 s, no handshake of the engine meanwhile: "STILL: tickCount changed in 0 of 120
frames"). After 600 frames nativeHoldAt said "replay without engine answer for 600 frames: hold released" and set G.replayOut to
0, so the queue's wait (meant for 20 s) ended too. YkeWoudstra#6:2 came a second later, named the new tracks of #6:1 (not built
yet here) and was "SKIPPED, unresolved"; #6:1 was built after it. Edges 13519 on yoyo's game, 13522 on YkeWoudstra's:
OUT OF SYNC, a 5-minute resynchronisation ("build not reproduced").
The fix: a replay's command is counted until its answer (G.replayPend); while the engine makes no handshake since it was sent, the
hold is kept and the queue, the player's own paused builds and the paused actions in their turn wait. An engine that runs and
does not answer: given up after 25 handshakes (it made far more by the 600 frames: as before), after 3600 frames in any case,
after 600 frames when tickCount cannot be read (as before).

The functions are taken from the real bridge and run through lupa (Lua 5.2) on the timeline of #447 (60 frames a second):
  part 1, MPFEVER_REPLAYORDER=0: the bug (the hold released at frame 601 and the queue free while the dry run is unanswered);
  part 2, the fix: held through the 11 s save, the queue busy, then free 3 frames after the answer;
  part 3, an engine that runs (a handshake every 12 frames) and never answers: given up after 25 handshakes, the hold released
  at frame 601 as before;
  part 4, no tickCount: released at frame 601, as before; part 5, frozen for a minute: given up at 3600 frames;
  part 6, the wiring (replaySend, the queue, the own builds, the paused actions).
Run: python tests/test_replayorder093.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

BRIDGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


i = src.index("G.REPLAY_PEND_SHAKES = 25")
block = src[i:src.index("G.ownWaitsReplay = function(r)")]
k = src.index("\tif (G.replayOut or 0) > 0 and G.frames - (G.replaySince or 0) > 600 then")
release = src[k:src.index("\t-- (stops and signals placed again after a build", k)]


def world(env):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; LOGS = {}; function log(t) LOGS[#LOGS + 1] = t end")
    for key, val in env.items():
        L.execute(f"ENV['{key}'] = '{val}'")
    L.execute("G = { frames = 0, replayOut = 0 }; TICK = 1000; G.simTick = function() return TICK end")
    L.execute(block)
    L.execute("function HOLD_RELEASE()\n" + release + "\nend")
    # a replay's command handed to the engine, as replaySend does; its answer, as its callback does
    L.execute("""
      function SEND() G.replayOut = (G.replayOut or 0) + 1; G.replaySince = G.frames; G.replayPendSent() end
      function ANSWER() G.replayOut = math.max(0, (G.replayOut or 1) - 1); G.replayPendAnswered(); G.replayQuiet = G.frames + 3 end
      function FRAMES(n, every) for f = 1, n do G.frames = G.frames + 1; if every and G.frames % every == 0 then TICK = TICK + 1 end
        if G.replayPend.n > 0 then G.replayPendSample() end
        HOLD_RELEASE() end end
      function LOGGED(p) for _, t in ipairs(LOGS) do if t:find(p, 1, true) then return true end end return false end
    """)
    return L


def ev(L, code):
    return L.eval(code)


# ---- part 1: the bug, MPFEVER_REPLAYORDER=0
L = world({"MPFEVER_REPLAYORDER": "0"})
L.execute("SEND(); FRAMES(601)")
check("bug reproduced (switch at 0): the hold released at frame 601 while the save runs",
      ev(L, "G.replayOut") == 0 and ev(L, "LOGGED('hold released')"))
check("  the queue free: the next build goes before the dry run's answer (YkeWoudstra#6:2 SKIPPED, unresolved)",
      ev(L, "G.replayQueueBusy()") is False)

# ---- part 2: the fix, the same timeline
L = world({})
L.execute("SEND(); FRAMES(601)")
check("fix: frame 601, no handshake since the dry run (a save): the hold kept", ev(L, "G.replayOut") == 1)
check("  said once", ev(L, "LOGGED('the engine made 0 handshake(s) since (a save makes none): still held')"))
check("  the queue waits", ev(L, "G.replayQueueBusy()") is True)
L.execute("FRAMES(1300)")
check("  frame 1901 (past the queue's own 1200 frames): still waiting", ev(L, "G.replayQueueBusy()") is True and ev(L, "G.replayOut") == 1)
check("  the player's own paused build waits too", ev(L, "G.replayPendingBusy()") is True)
L.execute("TICK = TICK + 1; ANSWER()")
check("the save over, the answer in: the queue waits only the 3 frames after it", ev(L, "G.replayQueueBusy()") is True)
L.execute("FRAMES(3)")
check("  then the next build goes, after the first one", ev(L, "G.replayQueueBusy()") is False)
check("  said", ev(L, "LOGGED('replay order: the answer came')"))

# ---- part 3: an engine that runs and never answers: as before
L = world({})
L.execute("SEND(); FRAMES(600, 12)")
check("an engine that runs (50 handshakes by frame 600) and does not answer: given up", ev(L, "G.replayPendingBusy()") is False)
L.execute("FRAMES(1, 12)")
check("  the hold released at frame 601, as before", ev(L, "G.replayOut") == 0 and ev(L, "LOGGED('hold released')"))
check("  nothing more said than before (given up silently at 25 handshakes, frame 300)",
      not ev(L, "LOGGED('replay order:')"))

# ---- part 4: tickCount not readable: as before
L = world({})
L.execute("G.simTick = function() return nil end; SEND(); FRAMES(601)")
check("no tickCount: released at frame 601, as before", ev(L, "G.replayOut") == 0 and ev(L, "G.replayQueueBusy()") is False)

# ---- part 5: frozen for a minute
L = world({})
L.execute("SEND(); FRAMES(3599)")
check("frozen 3599 frames: still held", ev(L, "G.replayOut") == 1)
L.execute("FRAMES(2)")
check("  3600 frames: given up, released", ev(L, "G.replayOut") == 0 and ev(L, "G.replayQueueBusy()") is False)
check("  said (desync risk)", ev(L, "LOGGED('the next builds go on (desync risk)')"))

# ---- part 6: the wiring
rs = src[src.index("local function replaySend(cmd, cb, noGate)"):src.index("-- engine verdicts arrive in callbacks")]
check("replaySend counts the command", "pcall(G.replayPendSent)" in rs and rs.index("G.replayOut = (G.replayOut or 0) + 1") < rs.index("pcall(G.replayPendSent)"))
check("  its answer uncounts it", "pcall(G.replayPendAnswered)" in rs and rs.index("O.sendCommand(cmd, function(...)") < rs.index("pcall(G.replayPendAnswered)"))
rn = src[src.index("local function runNativeReplays()"):]
rn = rn[:rn.index("\nend\n")]
check("the queue of the other players' builds uses G.replayQueueBusy", "local function replayBusy() return G.replayQueueBusy() end" in rn)
ow = src[src.index("G.ownWaitsReplay = function(r)"):]
ow = ow[:ow.index("\nend\n")]
check("the player's own builds wait for it", "G.replayPendingBusy()" in ow.split("\n")[1])
check("the paused actions in their turn wait for it",
      "local busy = (turn or a.pullOf) and ((G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or G.stopsAfterBusy ~= nil or (G.replayPendingBusy ~= nil and G.replayPendingBusy()))" in src)
gu = src[src.index("G.guiUpdateBody = function(userParams, state, guiState)"):]
gu = gu[:gu.index("local gp = G.gpOn")]
check("every frame counts the engine's handshakes while a command is out", "if G.replayPend and G.replayPend.n > 0 then pcall(G.replayPendSample) end" in gu)
check("the hold's release asks it first", "if G.replayPendingBusy ~= nil and G.replayPendingBusy() then" in release and release.index("if G.replayPendingBusy ~= nil and G.replayPendingBusy() then") < release.index("G.replayOut = 0"))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
