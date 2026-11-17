"""Offline test (0.8.17, #394): a script's street build of a pause waits for the engine's answer to the one before it, and is
looked at (C.staleNodeConfig, #174) on the world as it is then (runPausedActions in mpfever_bridge.script.lua, switch
MPFEVER_PAUSEDBUILDSEQ).

AndisPC's town transit mod (hluki's session, 2026-11-16 18:36) replaced street pieces one after the other in a pause: each build
made once the one before was applied on his game, the engine giving the freed number of a removed piece to the new piece, and the
next build's node configurations naming it (AndisPC#1:13 takes 239735 away and makes a new 239735; AndisPC#1:14's configuration of
node 239721 names 239735). Replayed in one frame, :14 was looked at before :13 was applied: "taken away by an earlier build at
this time", 9 builds refused on every game, then the games drifted.
C.staleNodeConfig is taken from the real mpfever_common.lua and run through lupa:
  - in one frame (as before, MPFEVER_PAUSEDBUILDSEQ=0): :14 refused (the bug, reproduced);
  - one after the other (now): :14 looked at once :13 is applied: the new 239735 ends at node 239721: built;
  - #174's own case stays refused: the configuration names a piece taken away and not made again (no longer at its node);
  - the paused actions' loop holds the next action while such a build waits for its answer (as a purchase).
Needs lupa. Run: python tests/test_pausedbuildseq0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
C_SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
B_SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m1 = re.search(r"^function C\.staleNodeConfig\(m, gone, touches\)\n.*?^end\n", C_SRC, re.S | re.M)
m2 = re.search(r"^function C\.noteGone\(m, gone\)\n.*?^end\n", C_SRC, re.S | re.M)
check("C.staleNodeConfig and C.noteGone found", bool(m1 and m2))
if not (m1 and m2):
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("C = {}\n" + m1.group(0) + m2.group(0) + r'''
-- the world: segment -> its two nodes
W = { [239735] = { 239721, 239800 } }
function TOUCH(seg, node) local e = W[seg] return e ~= nil and (e[1] == node or e[2] == node) end
B13 = { streetProposal = { edgesToRemove = { 239735 }, edgesToAdd = { { entity = -1 } }, nodeConfigsToAdd = {} } }
B14 = { streetProposal = { edgesToRemove = { 239740 }, edgesToAdd = { { entity = -1 } },
  nodeConfigsToAdd = { { entity = 239721, comp = { laneConnections = { { segment0 = 239735, segment1 = 239740 } } } } } } }
function APPLY13() W[239735] = { 239721, 239900 } end   -- the engine gives the freed number 239735 to :13's new piece
''')
run = L.eval("function(code) return assert(load(code))() end")

# one frame: :13 noted gone, :14 looked at before :13 is applied
r = run("local gone = {} C.noteGone(B13, gone) local s = C.staleNodeConfig(B14, gone, TOUCH) return s and s.why or 'ok'")
check("in one frame (as before): AndisPC#1:14 refused, 'taken away by an earlier build at this time' (the bug)", "earlier build" in str(r), r)
# one after the other: :13 applied, a new frame (a new set), :14 looked at on the world
r = run("APPLY13() local gone = {} local s = C.staleNodeConfig(B14, gone, TOUCH) return s and s.why or 'ok'")
check("one after the other (now): :14 looked at once :13 is applied: built", r == "ok", r)
# #174's case: the piece taken away, not made again
r = run("W[309652] = nil local B = { streetProposal = { edgesToRemove = { 1 }, nodeConfigsToAdd = { { entity = 249149, comp = { laneConnections = { { segment0 = 309652, segment1 = 1 } } } } } } } local s = C.staleNodeConfig(B, {}, TOUCH) return s and s.why or 'ok'")
check("#174: a configuration naming a piece taken away and not made again: refused as before", "no longer at that node" in str(r), r)

p = B_SRC[B_SRC.index("local function runPausedActions()"):]
p = p[:p.index("\nend\n")]
check("the paused actions' loop: a script's street build waits for its answer, as a purchase",
      "type(a.args[1].streetProposal) == \"table\" and os.getenv(\"MPFEVER_PAUSEDBUILDSEQ\") ~= \"0\" then creates = true end" in p
      and p.index("MPFEVER_PAUSEDBUILDSEQ") < p.index("G.pausedCreating = { uid = a.uid, frame = G.frames }"))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
