"""Offline test of the smooth pacing's room (0.7.5, G.smoothPace in mpfever_bridge.script.lua).

The user's dedicated server and a player, 2026-11-07 (MPFever 0.7.4): the game ran at x2.0 to x2.5 when x4 was asked, x0.72 at
x1, all game long; the pacing factor (native_pace.txt, the batch interval scaled) sat at 2.00 on BOTH games; on one PC the x4
soak of the night ran at x3.05. The factor counted the room left before the barrier: the other game's last clock plus 6 steps
at 4x (G.window = speed + 2), and slowed down under a batch and a half of it. That clock arrives a few steps old, so two games in
step were always under a batch and a half from it, and both ran their batches twice as long. The room is now counted to where
this game really stops (the native stop point: the barrier and its overshoot reserve, 2 x speed + 1 steps):
  - two games in step, the other's clock 2 to 5 steps old: no slowing down (factor 1) at 1x, 2x and 4x;
  - a game really ahead, close to its stop point: still slowed down, up to 2;
  - MPFEVER_PACEBARRIER=1: counted to the barrier, as before (the factor goes up to 2 for the same games in step).
Needs lupa (pip install lupa). Run: python tests/test_pace075.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local function overshootReserve()")
j = src.find("\nend\n", i) + 5
k = src.find("G.smooth = { on =")
m = src.find("\nend\n", src.find("G.smoothPace = function(sp)", k)) + 5
check(i > 0 and k > 0 and m > k, "overshootReserve and G.smoothPace found")
code = src[i:j] + "\n" + src[k:m]


def runtime(env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
    ENV = {}
    os.getenv = function(k) return ENV[k] end
    STEP = 200; NL = "\\n"; BS = "/"
    NOW = 0
    function gameTime() return NOW end
    function log(s) end
    WRITTEN = {}
    C = { DIR = "d", IO = { open = function(p) return { write = function(_, s) WRITTEN[#WRITTEN + 1] = s end, close = function() end } end } }
    G = { session = { started = true, speed = 4 }, frames = 0 }
    ''')
    for kk, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (kk, v))
    L.execute(code)
    return L


def factor(L, speed, lag_steps, ahead_steps=0, frames=400):
    """two games in step: this game's clock NOW, the barrier = the other's clock (lag_steps old, ahead_steps behind) + window"""
    L.execute("G.session.speed = %d; G.smooth.trim = 1; G.smooth.written = 1" % speed)
    window = speed + 2
    for f in range(frames):
        L.execute("NOW = %d; G.frames = %d; G.lastBarrier = NOW - %d * STEP + %d * STEP; G.smoothPace(%d)"
                  % (100000 + f * 200 * speed, f, lag_steps + ahead_steps, window, speed))
    return L.eval("G.smooth.trim")


L = runtime()
# (a step is 200 ms of game time: at 1x 5 steps a second, at 4x 20; the other's clock 100 to 400 ms old)
for sp in (1, 2, 4):
    for ms in (100, 250, 400):
        lag = ms / 1000 * 5 * sp
        t = factor(L, sp, lag)
        check(t == 1, "x%d, the other's clock %d ms old, games in step: no slowing down (factor %.2f)" % (sp, ms, t))
t = factor(L, 4, 4, ahead_steps=8)
check(t > 1.5, "x4, this game 8 steps ahead of the other: slowed down (factor %.2f)" % t)
t = factor(L, 1, 1, ahead_steps=4)
check(t > 1.5, "x1, this game 4 steps ahead of the other: slowed down (factor %.2f)" % t)
t = factor(L, 4, 4, ahead_steps=30)
check(1.99 < t <= 2, "never more than 2 (half speed): %.3f" % t)

L = runtime({"MPFEVER_PACEBARRIER": "1"})
t = factor(L, 4, 4)
check(t > 1.9, "MPFEVER_PACEBARRIER=1: counted to the barrier, the same games in step at half speed, as 0.7.4 (factor %.2f)" % t)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
