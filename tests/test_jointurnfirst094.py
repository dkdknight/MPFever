"""Offline test: at a session's start, a paused action whose turn comes before a company join is not held by the checkpoint that
waits for that join (0.9.4, issues #437 #438, MPFEVER_JOINTURNFIRST; runPausedActions, G.turnBeforeJoins and G.pullHold in
mod/mpfever_1/content/mpfever_bridge.script.lua).

The bug (magnu's and williamcolberg's sessions of 2026-11-19, one company per player, 18 s lost at every start): the host's
paused turns were 1 = magnu's company join, 2 = magnu's options event (f_opts, at t=0), 3 = williamcolberg's company join.
Checkpoint 1 (t=0) waits while a company join is under way here (MPFEVER_COHASHWAIT), and every paused action after it waited too:
turn 2 waited for the checkpoint, the checkpoint for williamcolberg's join, the join for turn 2. Nothing moved until turn 2 was
skipped, on every game: "paused build turn 2 never applied here in 30 s: skipped (desync risk)" (host 19:00:18, client 20:30:11).
The fix: an action whose turn comes before every join due here goes past that checkpoint (and the actions its player made before
it, applied in its turn); the checkpoint still waits for the join, then is taken.

The real runPausedActions and the turn functions are run through lupa, frame after frame, with the join applied by a model of
the native queue (in its turn, as G.joinTurn and G.ptMayGo let it):
  part 1, the bug (MPFEVER_JOINTURNFIRST=0): turn 2 skipped after 1800 frames, the start held all that time;
  part 2, the fix: turn 2 applied in the first frame, then the join, then the checkpoint, in that order; nothing skipped;
  part 3, what stays: an action whose turn comes after the join's still waits for the checkpoint; the checkpoint itself waits for
  the join; with a join being applied (G.coBusy) or one with no turn yet, nothing goes past; the actions pulled before turn 2
  carry its turn.
Needs lupa (pip install lupa). Run: python tests/test_jointurnfirst094.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
B = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def block(start, end_pat="\nend\n"):
    i = B.index(start)
    return B[i:B.index(end_pat, i) + len(end_pat)]


rpa = block("local function runPausedActions()").replace("local function runPausedActions()", "function runPausedActions()", 1)
pt = "".join(block(s) for s in ("G.ptAdvance = function()", "G.ptMayGo = function(seq)", "G.ptDone = function(seq)",
                                "G.joinTurn = function(a)", "G.turnBeforeJoins = function(turn, now)"))
check("runPausedActions, the turns and G.turnBeforeJoins found", "G.turnBeforeJoins(turn or a.pullTurn, now)" in rpa and "joinOnly" in rpa)

PRELUDE = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG, APPLIED, SENT = {}, {}, {}
function log(s) LOG[#LOG + 1] = s end
G = { frames = 0, pt = { next = 4, done = 1, of = {}, skip = {}, seen = true }, ptOn = true, joinTurns = true, actTurns = true,
  pendingPaused = {}, nativeQueue = {}, session = {}, me = "magnu", pullAdd = {}, featOn = false }
G.ptKey = function(origin, id) return tostring(origin) .. ":" .. tostring(id) end
G.joinTurnId = function(a) return "co" .. tostring(a.oseq) end
G.actTurnId = function(a) return "a" .. tostring(a.oseq) .. "@" .. tostring(a.at) end
G.actTurn = function(a)
  if not a.paused or a.kind == "hash" or a.fn == "mpfCoJoin" or a.oseq == nil then return nil end
  return G.pt.of[G.ptKey(a.origin, G.actTurnId(a))] or false
end
G.pullHold = function(a, now) return false end
G.saveBusyNow = function() return false end
G.nstopOk = function() return false end
function nativeHoldAt() return nil end
function gameTime() return 0 end
function gameSpeed() return 0 end
function toSim() end
function before(x, y) if x.at ~= y.at then return x.at < y.at end return (x.order or 0) < (y.order or 0) end
function send(kind, p) SENT[#SENT + 1] = kind; if kind == "sync_hash" then APPLIED[#APPLIED + 1] = "checkpoint " .. p.n end end
function authValues() return {} end
function simHash() return {} end
function coIsLoanEvent() return false end
function withActor(ent, fn, ...) return fn(...) end
function PL() return nil end
function executeAction(a, sendCommand, paused, bind, done) APPLIED[#APPLIED + 1] = tostring(a.uid); done({ uid = a.uid, fn = a.fn, success = true }) end
function toSimCo(a) end
O = { sendCommand = function() end }
K = { nameSyncOn = function() return false end }
SDUMP = {}
R = {}
H = {}
C = { DIR = "D", makesProposal = function() return false end, appendFile = function() end, line = function() return "" end, buyNote = function() return "" end }
BS, NL = "/", "\n"
'''


def runtime(env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(PRELUDE)
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute(pt)
    L.execute(rpa)
    L.execute(r'''
    G.reportResult = function() end
    G.resultsSeen = {}
    G.isWorldAct = function() return false end
    -- the start of magnu's session: turn 1 (magnu's join) applied, turn 2 = magnu's options event at t=0, turn 3 = williamcolberg's
    -- join, due at t=0 and waiting in the native queue; checkpoint 1 at t=0 before the event in the paused list
    G.pt.of["magnu:co2"], G.pt.of["magnu:a3@0"], G.pt.of["williamcolberg#6:co1"] = 1, 2, 3
    HASH = { kind = "hash", n = 1, at = 0, paused = true, order = 1 }
    OPTS = { uid = "magnu:3", origin = "magnu", oseq = 3, at = 0, paused = true, fn = "makeScriptingSendEventCmd", order = 2 }
    JOIN = { uid = "williamcolberg#6:1", origin = "williamcolberg#6", oseq = 1, at = 0, paused = true, fn = "mpfCoJoin", recvFrame = 0 }
    G.pendingPaused = { HASH, OPTS }
    G.nativeQueue = { JOIN }
    -- the native queue's join, in its turn (as the bridge's join path lets it: G.joinTurn, G.ptMayGo)
    function JOINSTEP()
      local q = G.nativeQueue[1]
      if q and q.fn == "mpfCoJoin" then
        local t = G.joinTurn(q)
        if type(t) == "number" and G.ptMayGo(t) then
          table.remove(G.nativeQueue, 1); G.ptDone(t); APPLIED[#APPLIED + 1] = "join " .. q.uid
        end
      end
    end
    function FRAMES(n)
      for i = 1, n do
        G.frames = G.frames + 1
        runPausedActions()
        JOINSTEP()
        if #G.pendingPaused == 0 and #G.nativeQueue == 0 then return G.frames end
      end
      return G.frames
    end''')
    return L


def order(L):
    return list(L.eval("APPLIED").values())


def logged(L, s):
    return any(s in x for x in L.eval("LOG").values())


# ---- part 1: the bug
L = runtime({"MPFEVER_JOINTURNFIRST": "0"})
f = L.eval("FRAMES(3000)")
check("bug reproduced (MPFEVER_JOINTURNFIRST=0): turn 2 skipped after 30 s (1800 frames), as in #437/#438",
      logged(L, "paused build turn 2 never applied here in 30 s: skipped (desync risk)") and f > 1800, f)
check("  the checkpoint waited for the join, the join for turn 2", logged(L, "checkpoint 1 waits for a company join under way here"))
check("  and the join went before the options event it should follow", order(L).index("join williamcolberg#6:1") < order(L).index("magnu:3")
      if "magnu:3" in order(L) else False, order(L))

# ---- part 2: the fix
L = runtime()
f = L.eval("FRAMES(3000)")
check("fix: everything applied within a few frames (not 1800)", f <= 5, f)
check("  in the turns' order: the options event (turn 2), the join (turn 3), then the checkpoint",
      order(L) == ["magnu:3", "join williamcolberg#6:1", "checkpoint 1"], order(L))
check("  nothing skipped", not logged(L, "never applied here in 30 s"))

# ---- part 3: what stays
L = runtime()
L.execute('G.pt.of["magnu:a3@0"] = 4; G.pt.of["williamcolberg#6:co1"] = 2; G.pt.of["x:co9"] = nil')
L.execute("FRAMES(3)")
check("an action whose turn comes after the join's: still waits for the checkpoint (join, checkpoint, then it)",
      order(L) == ["join williamcolberg#6:1", "checkpoint 1"] or order(L)[:2] == ["join williamcolberg#6:1", "checkpoint 1"], order(L))
L = runtime()
L.execute("FRAMES(2)")
check("the checkpoint itself never goes before the join", order(L).index("checkpoint 1") > order(L).index("join williamcolberg#6:1"))
L = runtime()
L.execute("G.coBusy = { id = 2 }")
check("a join being applied here (G.coBusy): nothing goes past", L.eval("G.turnBeforeJoins(2, 0)") is False)
L.execute("G.coBusy = nil; G.pt.of['williamcolberg#6:co1'] = nil")
check("a due join with no turn yet: nothing goes past", L.eval("G.turnBeforeJoins(2, 0)") is False)
L.execute("G.pt.of['williamcolberg#6:co1'] = 3")
check("  with its turn 3: turn 2 goes past, turn 3 or 5 do not",
      L.eval("G.turnBeforeJoins(2, 0)") is True and L.eval("G.turnBeforeJoins(3, 0)") is False and L.eval("G.turnBeforeJoins(5, 0)") is False)
check("  no join at all: nothing to go past (false)", L.eval("(function() G.nativeQueue = {} return G.turnBeforeJoins(2, 0) end)()") is False)
check("  no turn (nil): false", L.eval("G.turnBeforeJoins(nil, 0)") is False)

ph = block("G.pullHold = function(a, now)")
check("the actions pulled before a paused action carry its turn (pullTurn), and the loop reads it",
      "c.pullTurn = okT and type(turnA) == \"number\" and turnA or nil" in ph and "turn or a.pullTurn" in rpa)
check("a purchase or a street build held in this frame holds the rest as before (joinOnly cleared)",
      re.search(r"creating = true\n\t+joinOnly = false", rpa) is not None)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
