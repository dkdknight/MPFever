"""Offline test (0.8.17, #397 #398 #405): a released own build keeps the native stop point at its time until the simulation has
taken its command list (G.relHold and pacing in mpfever_bridge.script.lua, switch MPFEVER_RELHOLD).

Andy's build 111 for t=78435800 was released as the simulation was about to stand there; the stop point moved on at once, the
simulation's next batch came before the handshake that carried the command list and made its 4 steps, and the build landed at
t=78436600: the copy shipped at the click no longer matched, every game was reloaded (2026-11-16 20:15, and berni's 45, lulei's 138).

pacing and G.relHold are taken from the real bridge and run through lupa on a model of the engine: the interface hands its command
list to the simulation at a handshake (every 12 frames, the interface's copy of tickCount moves then), the simulation makes a batch
every 3 frames (4 steps at 4x, never past the native stop point) and applies the commands it holds at the start of a batch.
  - MPFEVER_RELHOLD=0 (as before): the build lands a batch late (the bug, reproduced), in every phase of the handshake;
  - now: it lands exactly at its time, in every phase of the handshake;
  - the stop point is let go at the first handshake after the release (no longer than needed);
  - a build released at once (BUILDLEAD) and a game already past the build's time: never held;
  - no handshake for 60 frames: given up, said once in the log.
Needs lupa. Run: python tests/test_relhold0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 1000000
TICK = 1
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
function gameTime() return NOW end
function leadLevel() return 0 end
function overshootReserve() return 9 end
function terrainLeadSteps() return 0 end
function toSim() end
O = { steps = nil }
G = { frames = 1000, session = { started = true, speed = 4 }, peers = { host = { t = NOW + 40 * STEP, ah = 16 } }, window = 6,
  pstat = { frames = 0, barrier = 0, hold = 0 }, pendingPaused = {}, natShipIds = {},
  nstopOk = function() return true end, ownHeldAt = function() return nil end,
  simTick = function() return TICK end }
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m_p = re.search(r"^local function pacing\(\)\n.*?^end\n", src, re.S | re.M)
    m_r = re.search(r"^G\.relHoldOn = function.*?^G\.relHold = function\(now\)\n.*?^end\n", src, re.S | re.M)
    check("pacing and G.relHold found in the bridge", bool(m_p and m_r))
    if not (m_p and m_r):
        return 1
    check("pacing asks G.relHold for its stop point", "G.relHold(now)" in m_p.group(0))
    check("the release notes the handshake counter (relTick)", "relTick = G.simTick()" in src)

    def runtime():
        L = lupa.LuaRuntime(unpack_returned_tuples=True)
        L.execute(MOCK)
        # (0.8.18) the stop points' rounding to the speed (G.alignDown, MPFEVER_ALIGNBATCH) is off here: this test is about the
        # holds themselves, at their exact steps (tests/test_alignbatch0818.py covers the rounding)
        m_a = re.search(r"^G\.alignDown = function\(t, k\)\n.*?^end\n", src, re.S | re.M)
        L.execute("G.alignOn = false\n" + (m_a.group(0) if m_a else "G.alignDown = function(t) return t end\n"))
        # (0.9.0) the session's speed at a time (a speed change at a common step, G.speedNow): none here, the session's speed
        m_s = re.search(r"^G\.speedNow = function\(now\)\n.*?^end\n", src, re.S | re.M)
        L.execute(m_s.group(0) if m_s else "G.speedNow = function() return G.session.speed end\n")
        L.execute(m_r.group(0))
        L.execute(m_p.group(0) + "\nPACING = pacing\n")
        return L, L.eval("function(code) return assert(load(code))() end")

    def model(relhold, phase, lead=False):
        """frames: a handshake every 12 frames (offset `phase`), a batch every 3 frames; the build is held for t = L by the
        interface's own hold (G.holdAt) until it is released while the simulation's batch heading to L is under way. Returns the
        landing time minus L in steps, and the frames the stop point stayed at L after the release."""
        L, run = runtime()
        if not relhold:
            run("ENV.MPFEVER_RELHOLD = '0'")
        g = L.globals()
        T = 1000000
        Lt = T + 8 * 200
        run(f"NOW = {T}; G.holdAt = {Lt}")
        sim_t, pending, inbox, landed = T, [], [], None
        released = None
        held_frames = 0
        for f in range(0, 200):
            run("G.frames = G.frames + 1")
            if (f + phase) % 12 == 0:                       # handshake: the list goes to the simulation, the copy comes back
                inbox += pending
                pending = []
                run("TICK = TICK + 1")
                run(f"NOW = {sim_t}")                       # the interface sees the simulation's clock at a handshake only
            # the release: the simulation's latest batch ends at L (the native module's answer, G.nstopWillStand), whatever
            # clock the interface's copy still shows
            if released is None and sim_t >= Lt:
                released = f
                run("G.holdAt = nil")
                run(f"G.natShipIds[#G.natShipIds + 1] = {{ id = 111, at = {Lt}, frame = G.frames, lead = {'true' if lead else 'false'}, relTick = G.simTick() }}")
                pending.append("build 111")
            stop = run("PACING(); return G.lastStopAt")
            if released is not None and stop == Lt and landed is None:
                held_frames += 1
            if f % 3 == 0:                                  # a batch: commands first, then steps up to the stop point
                if inbox and landed is None:
                    landed = sim_t
                    inbox = []
                    run("G.natShipIds = {}")                 # shipped: no longer in the list
                n = 4
                if stop is not None:
                    n = max(0, min(4, (stop - sim_t) // 200))
                sim_t += n * 200
            if landed is not None and f > (released or 0) + 30:
                break
        return (None if landed is None else (landed - Lt) // 200), held_frames, L

    late_before = [model(False, ph)[0] for ph in range(12)]
    check("MPFEVER_RELHOLD=0: the build lands late in some phase of the handshake (the bug)", any(x and x > 0 for x in late_before), late_before)
    late_now = [model(True, ph)[0] for ph in range(12)]
    check("now: the build lands exactly at its time in every phase of the handshake", all(x == 0 for x in late_now), late_now)
    held = [model(True, ph)[1] for ph in range(12)]
    check("the stop point is held at most one handshake (12 frames) after the release", max(held) <= 13, held)

    # a build released at once (BUILDLEAD): never held
    L, run = runtime()
    run("G.natShipIds = { { id = 5, at = NOW + 2 * STEP, frame = G.frames, lead = true, relTick = TICK } }")
    s = run("PACING(); return G.lastStopAt")
    check("BUILDLEAD (released at once): the barrier's stop point", s == 1000000 + 55 * 200, s)

    # already past its time: not held
    run("G.natShipIds = { { id = 6, at = NOW - STEP, frame = G.frames, relTick = TICK } }")
    s = run("PACING(); return G.lastStopAt")
    check("a game past the build's time: not held", s == 1000000 + 55 * 200, s)

    # no handshake for 60 frames: given up, said once
    run("G.natShipIds = { { id = 7, at = NOW + 2 * STEP, frame = G.frames, relTick = TICK } }")
    s = run("PACING(); return G.lastStopAt")
    check("released, no handshake yet: held at its time", s == 1000000 + 2 * 200, s)
    run("G.frames = G.frames + 61")
    s = run("PACING(); PACING(); return G.lastStopAt")
    check("no handshake within 60 frames: given up", s == 1000000 + 55 * 200, s)
    n = run("local n = 0 for _, l in ipairs(LOGS) do if l:find('no handshake seen 60 frames', 1, true) then n = n + 1 end end return n")
    check("and said once", n == 1, n)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
