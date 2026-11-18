"""A speed changed while the session runs takes effect at a common step (0.9.0, #150; SpeedChangeStep in launcher/MainForm.cs,
G.speedNow and pacing in mpfever_bridge.script.lua, switch MPFEVER_SPEEDAT), offline.

Every game used to take a new speed when the host's message reached it, each at its own step: around a speed change the games
cut their steps into other batches (x2 then x4 at another step), which the aligned batches (0.8.18) cannot make alike. The host
now gives the step it takes effect at, a multiple of 4 steps a little ahead of the fastest game, as for a pause: every game runs at
the speed before up to that step, stands there (an exact stop point every game shares), then goes on at the new speed.
  - the launcher: speedAt/speedFrom in the session message (SpeedChangeStep; the launcher's self-test checks its steps);
  - the mod (lupa): before speedAt the speed asked is the old one and the stop point is speedAt; at speedAt the new one, no stop;
    from a pause, or without speedAt, the session's speed as before.
Run: python tests/test_speedat090.py
"""
import os
import re
import sys

try:
    import lupa
except ImportError:
    print("FAIL: lupa missing (pip install lupa)")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond, got=""):
    print(("PASS " if cond else "FAIL ") + name + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)
    return cond


mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8").read()
check("SpeedChangeStep: at once from a pause, from speed 0, the same speed or the switch off",
      "if (!on || pausedAt.HasValue || oldSpeed <= 0 || oldSpeed == newSpeed) return null;" in mf)
check("SpeedChangeStep: a multiple of 4 steps at or past the future stamp", "long quad = 4 * Step;" in mf and "return (future + quad - 1) / quad * quad;" in mf)
check("SetSpeed sets speedAt and speedFrom from the speed before", "speedAt = SpeedChangeStep(SpeedAtOn, speed, ns, pauseAt, future);" in mf and "speedFrom = speed;" in mf)
check("a pause clears speedAt", "lock (sessionGate) { pauseAt = at; speedAt = null; }" in mf)
check("the session message carries them (not while paused)", 'speedAt.HasValue && !pauseAt.HasValue ? ",[\\"speedAt\\"]=" + speedAt.Value + ",[\\"speedFrom\\"]=" + speedFrom' in mf)
check("the switch MPFEVER_SPEEDAT", 'Environment.GetEnvironmentVariable("MPFEVER_SPEEDAT") != "0"' in mf)
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8").read()
check("the launcher's self-test checks SpeedChangeStep", "ok &= RunSpeedAt090();" in st)

src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
check("the mod reads speedAt and speedFrom from the session", "G.session.speedAt = tonumber(p.speedAt)" in src and "G.session.speedFrom = tonumber(p.speedFrom)" in src)
m_p = re.search(r"^local function pacing\(\)\n.*?^end\n", src, re.S | re.M)
m_s = re.search(r"^G\.speedNow = function\(now\)\n.*?^end\n", src, re.S | re.M)
m_a = re.search(r"^G\.alignDown = function\(t, k\)\n.*?^end\n", src, re.S | re.M)
if not check("pacing, G.speedNow and G.alignDown found", m_p and m_s and m_a):
    sys.exit(1)

MOCK = r'''
os.getenv = function(k) return nil end
STEP = 200
NOW = 1000000
function log(s) end
function gameTime() return NOW end
function leadLevel() return 0 end
function overshootReserve() return 9 end
function terrainLeadSteps() return 0 end
function toSim() end
O = { steps = nil }
G = { frames = 1000, session = { started = true, speed = 4 }, peers = { host = { t = NOW + 200 * STEP, ah = 16 } }, window = 6,
  pstat = { frames = 0, barrier = 0, hold = 0 }, pendingPaused = {},
  nstopOk = function() return true end, ownHeldAt = function() return nil end }
'''
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(MOCK)
L.execute("G.alignOn = true\n" + m_a.group(0))
L.execute(m_s.group(0))
L.execute(m_p.group(0) + "\nPACING = pacing\n")
run = L.eval("function(code) return assert(load(code))() end")

base = run("G.session.speedAt = nil; G.session.speedFrom = nil; return PACING()")
check("no speed change: the session's speed (4)", base == 4, base)
sp = run("G.session.speedAt = NOW + 12 * STEP; G.session.speedFrom = 2; return PACING()")
stop = run("return G.lastStopAt")
check("before the change's step: the speed before (2)", sp == 2, sp)
check("  and the stop point is the change's step (every game stands there)", stop == 1000000 + 12 * 200, stop)
sp = run("NOW = G.session.speedAt; return PACING()")
stop = run("return G.lastStopAt")
check("at the change's step: the new speed (4)", sp == 4, sp)
check("  and no stop point there any more", stop != run("return G.session.speedAt"), stop)
sp = run("NOW = G.session.speedAt + 3 * STEP; return PACING()")
check("after it: the new speed", sp == 4, sp)
sp = run("NOW = 1000000; G.session.speedAt = NOW + 12 * STEP; G.session.pauseAt = NOW; return PACING()")
check("paused: the pause wins (speed 0)", sp == 0, sp)

print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
