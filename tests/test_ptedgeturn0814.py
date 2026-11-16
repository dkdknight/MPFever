"""Offline test (0.8.14, #337): a build made as the pause begins goes only in its turn (runNativeRelease in
mpfever_bridge.script.lua).

Peter's bulldozer of 2026-11-15 10:46:16 (host, NOSTOP on): made as the pause began (G.pauseEdge), turn 2, stamped at the pause's
time while the clock was still before it; the branch "the simulation about to stand at its time" (G.nstopWillStand) released it
early without marking turn 2 done, Peter's builds of turns 3 and 4 waited 30 s, turn 2 was skipped ("never applied here in 30 s"),
and the games applied the builds in other orders (Jakob's game could not reproduce Peter:93).
  - a paused build (a turn) before its time: kept, not released by that branch, no turn marked;
  - at its time: released by the turn branch, its turn marked done (G.ptDone);
  - a build that is not of a pause, before its time with the simulation about to stand there: released early, as before;
  - MPFEVER_PTEDGETURN=0: released early as before (0.8.8 to 0.8.13).
Needs lupa. Run: python tests/test_ptedgeturn0814.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m = re.search(r"^local function runNativeRelease\(\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "runNativeRelease found")
if not m:
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENV = {}
os = { getenv = function(k) return ENV[k] end }
NOW, SPEED = 900, 4
RELEASED, DONE = {}, {}
G = { me = "Peter", frames = 100, replayOut = 0, ptOn = true, ptAfterPause = true, pt = { of = { ["Peter:140"] = 2 } } }
G.ptKey = function(o, id) return tostring(o) .. ":" .. tostring(id) end
G.ptMayGo = function(seq) return true end
G.ptDone = function(seq) DONE[#DONE + 1] = seq end
G.restale = function() return false end
G.nstopWillStand = function() return true end
G.nstopStanding = function() return true end
G.sameStepWait = function() return false end
G.ownWaitsReplay = function() return false end
G.pullBuildLog = function() end
function expireShipIds() end
function gameTime() return NOW end
function gameSpeed() return SPEED end
function releaseOne(r, at) RELEASED[#RELEASED + 1] = r.id .. "@" .. at end
function log() end
""" + m.group(0).replace("local function runNativeRelease", "function runNativeRelease"))
g = L.globals()


def run(now, rel, env=None):
    g.NOW = now
    g.RELEASED = L.eval("{}")
    g.DONE = L.eval("{}")
    g.ENV = L.eval("{}")
    if env:
        for k, v in env.items():
            g.ENV[k] = v
    g.G.natRelease = L.eval("function(t) return { t } end")(L.table_from(rel))
    L.eval("runNativeRelease")()
    return list(g.RELEASED.values()), list(g.DONE.values()), len(g.G.natRelease)


r, d, kept = run(900, {"id": 140, "at": 1000, "paused": True})
check(r == [] and d == [] and kept == 1, "a build of the pause before its time: kept (not released early, no turn marked)")
r, d, kept = run(1000, {"id": 140, "at": 1000, "paused": True})
check(r == ["140@1000"] and d == [2] and kept == 0, "at its time: released in its turn, turn 2 marked done")
r, d, kept = run(900, {"id": 77, "at": 1000})
check(r == ["77@1000"] and kept == 0, "a build that is not of a pause: released early as before (NOSTOP)")
r, d, kept = run(900, {"id": 140, "at": 1000, "paused": True}, {"MPFEVER_PTEDGETURN": "0"})
check(r == ["140@1000"] and d == [], "MPFEVER_PTEDGETURN=0: released early, no turn marked, as 0.8.8 to 0.8.13")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
