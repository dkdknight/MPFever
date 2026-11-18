"""Offline test of the 0.6.4 hold of queued actions (mpfever_bridge.script.lua: queueLocal and pacing).

In a 45-minute AI test at 4x (t1 of 2026-10-31) an action came with a margin of one step: the host's next clock moved the native
stop point on before the simulation had taken it, and the client applied it 4 steps late (a vehicle sent to its line late, then
vehicles, money and towns drifted apart). A queued action now holds the native stop point a step before its time until the
simulation's answer to its command comes.

queueLocal and pacing are taken from the real bridge file and run through lupa (Lua 5.2) on a mocked game. Cases:
  - an action queued with its answer pending: the native stop point (G.lastStopAt) stays a step before its time while the
    host's clock moves on; once answered, the stop point goes back to the barrier's;
  - with the usual margin (16 steps) the hold is past the barrier's stop point: nothing changes;
  - an answer that never comes: no longer held after 600 frames;
  - a paused action: not held this way (its own hold, G.holdAt);
  - MPFEVER_QHOLD=0: sent as before (toSim), never held.
Run: python tests/test_qhold.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 1000000
LOGS, SENT, TOSIM = {}, {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function gameTime() return NOW end
function leadLevel() return 0 end
function overshootReserve() return 9 end
function terrainLeadSteps() return 0 end
function toSim(name, a) TOSIM[#TOSIM + 1] = { name = name, a = a } end
O = { steps = nil,
  event = function(a, b, name, p) return { name = name, p = p } end,
  sendCommand = function(cmd, cb) SENT[#SENT + 1] = { cmd = cmd, cb = cb } end }
G = { frames = 1000, session = { started = true, speed = 4 }, peers = { host = { t = NOW, ah = 16 } }, window = 6,
  pstat = { frames = 0, barrier = 0, hold = 0 }, pendingPaused = {},
  nstopOk = function() return true end, ownHeldAt = function() return nil end }
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m_q = re.search(r"^local function queueLocal\(a\)\n.*?^end\n", src, re.S | re.M)
    m_p = re.search(r"^local function pacing\(\)\n.*?^end\n", src, re.S | re.M)
    if not (m_q and m_p):
        print("FAIL: queueLocal or pacing not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    # (0.8.18) the stop points' rounding to the speed (G.alignDown, MPFEVER_ALIGNBATCH) is off here: this test is about the
    # holds themselves, at their exact steps (tests/test_alignbatch0818.py covers the rounding)
    m_a = re.search(r"^G\.alignDown = function\(t, k\)\n.*?^end\n", src, re.S | re.M)
    L.execute("G.alignOn = false\n" + (m_a.group(0) if m_a else "G.alignDown = function(t) return t end\n"))
    # (0.9.0) the session's speed at a time (a speed change at a common step, G.speedNow): none here, the session's speed
    m_s = re.search(r"^G\.speedNow = function\(now\)\n.*?^end\n", src, re.S | re.M)
    L.execute(m_s.group(0) if m_s else "G.speedNow = function() return G.session.speed end\n")
    L.execute(m_q.group(0) + "\nQUEUE = queueLocal\n")
    L.execute(m_p.group(0) + "\nPACING = pacing\n")
    run = L.eval("function(code) return assert(load(code))() end")

    # the usual stop point: the host's clock + window 6 + reserve 9 steps
    base = run("PACING(); return G.lastStopAt")
    check("without a held action: the barrier's stop point (host's clock + 15 steps)", base == 1000000 + 15 * 200, base)

    # an action stamped 16 steps after the host's clock, arriving when the host's clock already moved on by 3 steps
    run("G.peers.host.t = NOW + 3 * STEP; QUEUE({ uid = 'Host:171', at = 1000000 + 16 * 200 })")
    check("queued with a command and an answer to wait for (not toSim)", run("return #SENT == 1 and #TOSIM == 0 and SENT[1].cmd.name == 'queue'"))
    held = run("PACING(); return G.lastStopAt")
    check("its answer pending: the stop point a step before its time, not the barrier's", held == 1000000 + 15 * 200, held)
    run("G.peers.host.t = NOW + 8 * STEP")
    held2 = run("PACING(); return G.lastStopAt")
    check("the host's clock moves on: still held", held2 == 1000000 + 15 * 200, held2)
    run("SENT[1].cb({}, true)")
    free = run("PACING(); return G.lastStopAt")
    check("answered: the barrier's stop point again", free == 1000000 + 23 * 200, free)

    # the usual margin: an action 16 steps past the current host clock holds nothing short of the barrier's stop point
    run("G.peers.host.t = NOW; QUEUE({ uid = 'Host:200', at = NOW + 16 * 200 })")
    usual = run("PACING(); return G.lastStopAt")
    check("with the usual margin: the stop point unchanged", usual == 1000000 + 15 * 200, usual)
    run("SENT[#SENT].cb({}, true)")

    # an answer that never comes
    run("G.peers.host.t = NOW + 5 * STEP; QUEUE({ uid = 'Host:300', at = NOW + 2 * 200 }); PACING()")
    stuck = run("return G.lastStopAt")
    check("no answer yet: held", stuck == 1000000 + 1 * 200, stuck)
    run("G.frames = G.frames + 601")
    gone = run("PACING(); return G.lastStopAt")
    check("no answer within 600 frames: no longer held", gone == 1000000 + 20 * 200, gone)
    check("and said once in the log", run("local n = 0 for _, l in ipairs(LOGS) do if l:find('Host:300', 1, true) and l:find('600 frames', 1, true) then n = n + 1 end end return n") == 1)

    # paused actions keep their own hold
    run("SENT = {}; QUEUE({ uid = 'Host:400', at = NOW + 2 * 200, paused = true })")
    check("a paused action: among the paused ones, not sent", run("return #SENT == 0 and #G.pendingPaused == 1"))

    # the switch
    run("ENV.MPFEVER_QHOLD = '0'; G.qHold = {}; G.peers.host.t = NOW; QUEUE({ uid = 'Host:500', at = NOW + 2 * 200 })")
    check("MPFEVER_QHOLD=0: sent to the simulation as before", run("return #TOSIM == 1 and TOSIM[1].name == 'queue' and #SENT == 0"))
    off = run("PACING(); return G.lastStopAt")
    check("MPFEVER_QHOLD=0: never held", off == 1000000 + 15 * 200, off)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
