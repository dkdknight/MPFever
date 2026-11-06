"""Offline test of the gate (0.8 work, MPFEVER_GATE=1): another player's build replayed without standing at its step.

Before, a replay went to the engine once this game stood at the build's step, and the game went on when the engine had answered:
about 0.4 s for every build of every other player (the "LAG" lines; 85 % of the replays are one command, whose stand was exactly
that round trip). With the gate the replay goes to the engine as soon as it is ready, while the game is still before the step;
the native module (GateRelease in mpfever_native.cpp) holds it and gives it to the engine at the swap after the batch that ended
at the step.
Part 1, the bridge's functions taken from the real file and run through lupa (Lua 5.2) with a mocked state:
  - G.gateHolds: no gated replay: nil; its build not handed to the module yet (a construction's conversion under way): its
    step; handed: false (the module keeps the game from passing it); a replay of several commands (G.gateGroup): its step;
  - G.gateAhead: only a native build of another player, not paused, not a terrain edit / company join / asset, before its time;
  - toSim: a replay's own events ("replaying"...) go through the gate at its step, every other event at once;
  - replaySend: a gated replay writes "gate <token> <step>" in native_ctl.txt just before its command; a dry run (marked
    G.gateDryNext) goes at once;
  - nativeHoldAt: a gated replay handed to the module does not hold the game where it is any more; one not handed yet holds at
    its step, not at the game's time.
Part 2, a model of the native rule (batches of random sizes, commands gated for random steps): a gated command is always
applied at the first step of a batch that starts exactly at its step, and the clamp never lets a batch run past a held one.
Run: python tests/test_gate.py
"""
import os, random, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
NATIVE = os.path.join(HERE, "..", "native", "mpfever_native.cpp")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
i = src.index("-- ================================================================== the gate (0.8, MPFEVER_GATE=1)")
j = src.index("-- ================================================================== native deferral (with mpfever_native.dll)")
gate_code = src[i:j]
m_tosim = re.search(r"^local function toSim\(name, param\)\n.*?^end\n", src, re.S | re.M)
m_send = re.search(r"^local function replaySend\(cmd, cb, noGate\)\n.*?^end\n", src, re.S | re.M)
m_hold = re.search(r"^local function nativeHoldAt\(\)\n.*?^end\n", src, re.S | re.M)
check(m_tosim is not None and m_send is not None and m_hold is not None, "toSim, replaySend and nativeHoldAt found")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 100000
NL = "\n"
BS = "/"
LOGS, CTL, SENT = {}, {}, {}
function gameTime() return NOW end
function overshootReserve() return 2 end
function log(s) LOGS[#LOGS + 1] = s end
function buildEffects() end
function withActor(who, f, ...) return f(...) end
C = { ACTIVE = true, DIR = "D", appendFile = function(path, line) CTL[#CTL + 1] = line; return true end }
O = { steps = true, sendCommand = function(cmd, cb) SENT[#SENT + 1] = cmd; if cb then PENDING = cb end end,
      event = function(a, b, name, p) return "event:" .. name end }
K = { JOIN_GATHER = 60 }
G = { frames = 5000, natRelease = {}, natWait = {}, nativeQueue = {}, simStill = function() return true end, joinTurn = function() return true end }
'''

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(MOCK)
L.execute('ENV["MPFEVER_GATE"] = "1"')
L.execute(gate_code)
L.execute(m_tosim.group(0).replace("local function toSim", "function toSim", 1))
L.execute(m_send.group(0).replace("local function replaySend", "function replaySend", 1))
L.execute(m_hold.group(0).replace("local function nativeHoldAt", "function nativeHoldAt", 1))
run = L.eval("function(code) local f = assert(load(code)) return f() end")
G = L.globals().G

check(run("return G.gateOn()") is False, "the native module silent: the gate stays off")
L.execute("G.gateCap = true")
check(run("return G.gateOn()") is True, "MPFEVER_GATE=1 and the module's word: on")
check(run("return G.gateHolds()") is None, "no gated replay: nothing to hold")
L.execute("G.gateCur = { at = 102000, uid = 'B#1:4' }")
check(run("return G.gateHolds()") == 102000, "a gated replay whose build is not held yet (a conversion under way): its step")
L.execute("G.gateCur.handed = 1")
check(run("return G.gateHolds()") is False, "handed to the module: nothing held here, the module keeps the game from passing the step")
L.execute("G.gateGroup('a stop replay')")
check(run("return G.gateHolds()") == 102000, "a replay of several commands: its step, until it is done")
check(any("stays at t=102000" in str(s) for s in L.globals().LOGS.values()), "and the log says so")

check(run("return G.gateAhead({ native = true, at = 102000, fn = 'nativeBuild' }, NOW, nil)") is True, "a native build of another player before its time: ahead")
check(run("return G.gateAhead({ native = true, at = 102000, paused = true }, NOW, nil)") is False, "a paused build: in its turn, not ahead")
check(run("return G.gateAhead({ native = true, at = 102000 }, NOW, 3)") is False, "one with a turn: not ahead")
check(run("return G.gateAhead({ native = true, at = 102000, fn = 'terrainEdit' }, NOW, nil)") is False, "a terrain edit: not ahead")
check(run("return G.gateAhead({ native = true, at = 102000, fn = 'mpfCoJoin' }, NOW, nil)") is False, "a company join: not ahead")
check(run("return G.gateAhead({ native = true, at = 100000 }, NOW, nil)") is False, "a build due now: the usual way")
check(run("return G.gateAhead({ at = 102000, fn = 'makeVehicleBuyCmd' }, NOW, nil)") is False, "a queued action (applied by the simulation itself): not ahead")

# toSim and replaySend
L.execute("G.gateCur = { at = 102000, uid = 'B#1:5' }; CTL, SENT = {}, {}")
L.execute("toSim('replaying', { tok = 'x' }); toSim('out_shipped', { n = 3 })")
ctl, sent = list(L.globals().CTL.values()), list(L.globals().SENT.values())
check(len(ctl) == 1 and re.match(r"^gate \d+ 510\n$", ctl[0]) is not None, "toSim('replaying') during a gated replay: a gate line for step 510 (t=102000)", ctl)
check(sent == ["event:replaying", "event:out_shipped"], "both events sent, the other one at once", sent)
L.execute("CTL, SENT = {}, {}; G.gateDryNext = true; replaySend('dry', function() end)")
check(len(L.globals().CTL) == 0 and list(L.globals().SENT.values()) == ["dry"], "a dry run (conversion refused on purpose): at once, no gate line")
check(run("return (G.gateCur.handed or 0)") == 0, "and it is not the replay's build")
L.execute("CTL, SENT = {}, {}; replaySend('build', function() end)")
ctl = list(L.globals().CTL.values())
check(len(ctl) == 1 and ctl[0].endswith(" 510\n") and list(L.globals().SENT.values()) == ["build"], "the replay's build: its gate line, then the command", ctl)
check(run("return G.gateCur.handed") == 1, "and it counts as handed")
L.execute("CTL, SENT = {}, {}; G.gateCur = nil; replaySend('other', function() end); toSim('replaying', {})")
check(len(L.globals().CTL) == 0, "no gated replay: replaySend and toSim as before, no gate line")
L.execute("G.gateWanted = false; G.gateCur = { at = 102000 }; CTL = {}; replaySend('x', function() end)")
check(len(L.globals().CTL) == 0, "MPFEVER_GATE off: never a gate line")
L.execute("G.gateWanted = true")

# nativeHoldAt
L.execute("G.replayOut = 1; G.replayQuiet = 0; G.gateCur = { at = 102000, uid = 'B#1:6', handed = 1 }")
got = run("return tostring(nativeHoldAt())")
check(got == "nil", "a gated replay handed to the module and in the engine's hands: no hold where the game is", got)
L.execute("G.gateCur.handed = 0")
got = run("return tostring(nativeHoldAt())")
check(got == "102000", "not handed yet: held at its step, not at the game's time", got)
L.execute("G.gateCur = nil")
got = run("return tostring(nativeHoldAt())")
check(got == "100000", "without the gate: a replay in the engine's hands holds the game where it is, as before", got)

# Part 2: the native rule, modelled
def simulate(seed):
    rnd = random.Random(seed)
    step, applied, held, problems = 0, [], [], []
    gb = (0, 0)                        # the latest batch: (first step, steps)
    for frame in range(400):
        # the interface gates commands for steps ahead (as the bridge does: never for a step the game passed, it holds it there)
        # (in any order: a later replay may even be gated for an earlier step)
        if rnd.random() < 0.3:
            held.append(step + rnd.randint(1, 12))
        # swap: the held commands whose step the latest batch ended at go to the engine (GateRelease)
        E = gb[0] + gb[1]
        given = [h for h in held if h <= E]
        held = [h for h in held if h > E]
        # batch: the given commands are applied at its first step; steps clamped at the oldest held one (StepsForBatch)
        for g in given:
            if g != step:
                problems.append((g, step))
            applied.append(g)
        speed = rnd.choice([0, 1, 1, 2, 4, 4])
        n = speed
        if held:
            gm = min(held)
            if step >= gm:
                n = 0
            elif step + n > gm:
                n = gm - step
        gb = (step, n)
        step += n
    return problems, len(applied)


bad, total = [], 0
for sd in range(50):
    pr, n = simulate(sd)
    bad += pr
    total += n
check(not bad and total > 1000, "model: every gated command applied at its own step (%d commands, 50 runs of random batches)" % total, bad[:3])

nat = open(NATIVE, encoding="utf-8").read()
check("GateRelease();" in nat and "long gm = g_gateMin;" in nat and "GateHold(list, out, cmd, done, progress, caller)" in nat,
      "the native module: release at the swap, clamp in StepsForBatch, hold at Add")
check('GetEnvironmentVariableA("MPFEVER_GATE"' in nat and 'e.str("gatecap 1")' in nat, "the native gate only with MPFEVER_GATE=1, and it says so to the bridge")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
