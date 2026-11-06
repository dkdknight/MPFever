"""Offline test of the lead acknowledged (0.7.3, MPFEVER_LEADACK, on with the host's MPFEVER_NOSTOP=1; off by default).

The two-builder stress test with computer companies of 2026-11-06 (Test Gameplay, one company per player, x4): a game that
leads (a tool in hand) ran ahead of the other by the lead's steps at once, while the other still stamped its actions from its
own clock by its stamp distance only (16 steps at 4x): it adds the lead's steps once it knows of the lead. A line the host made
as the client started to lead landed 19 steps late on the client ("MARGIN ... -19 steps", LATE, ages apart, the games reloaded).
Now the leader runs no further past the other game's clock than that game's stamp distance as sent with that clock, less the
overshoot and one step. G.leadRoom is taken from the real bridge file and run through lupa:
  - the other game does not follow yet (it stamps 16 steps ahead): the leader stays within 6 steps of its clock, as without a lead;
  - it follows (its stamps have the lead in them, 36 steps): the leader takes its whole lead;
  - never short of the usual barrier; no clock: as before.
A model of two games then checks the rule that matters: whatever the moment the lead starts and however late the clocks come,
no action of the follower lands behind the leader's clock with the cap (and some do without it, as in the stress test).
Run: python tests/test_leadack.py
"""
import os, random, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
m = re.search(r"^G\.leadRoom = function\(name, pc, limit\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "G.leadRoom found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
STEP = 200
SPD = 4
function overshootReserve() return 2 * SPD + 1 end
G = { window = SPD + 2, frames = 1 }
''')
L.execute(m.group(0))
run = L.eval("function(code) local f = assert(load(code)) return f() end")
T = 25000000
LEAD = (6 + 20) * 200                       # window + terrainLeadSteps at 4x
got = run("return G.leadRoom('Host', { t = %d, ah = 16 }, %d)" % (T, T + LEAD))
check(got == T + 6 * 200, "the other game does not follow yet (stamps 16 ahead): no further than 6 steps past its clock", (got - T) / 200)
check(any("LEADACK: this game leads, Host stamps its actions 16 steps ahead" in x for x in L.eval("LOGS").values()), "said once in the log")
got = run("return G.leadRoom('Host', { t = %d, ah = 36 }, %d)" % (T, T + LEAD))
check(got == T + LEAD, "it follows (its stamps have the lead in them): the whole lead", (got - T) / 200)
check(any("LEADACK: Host follows (stamp distance 36)" in x for x in L.eval("LOGS").values()), "said in the log")
got = run("return G.leadRoom('Host', { t = %d, ah = 3 }, %d)" % (T, T + LEAD))
check(got == T + 6 * 200, "never short of the usual barrier (the window)", (got - T) / 200)
got = run("return G.leadRoom('Host', { t = %d }, %d)" % (T, T + LEAD))
check(got == T + LEAD, "no stamp distance known: as before")
check("if G.leadAckOn then limit = G.leadRoom(pname, pc, limit) end" in src and "for pname, pc in pairs(G.peers) do" in src,
      "pacing: the leader's limit, only with the setting")
check('G.leadAckOn = G.featureOn("MPFEVER_LEADACK")' in src, "on with the host's setting (or MPFEVER_LEADACK=1)")
check("G.stampFloor = math.max(G.stampFloor, t + G.ahead * STEP)" in src, "a game never stamps short of the distance it sent")


# ---- a model of two games at 4x (one step a tick): B leads from a random moment; A stands now and then (a replay, a hold) and
# makes actions; A's messages reach B in order, 0 to 3 ticks later; A hears of the lead 1 to 4 ticks after it starts
def model(cap, seed):
    rnd = random.Random(seed)
    window, reserve, lead = 6, 9, 20
    base = window + reserve + 1                  # A's stamp distance without a lead (16 at 4x)
    tA, tB, late = 0, 0, 0
    msgs = []                                    # (tick it reaches B, kind, data), in the order sent
    known = (0, base)                            # A's clock and stamp distance as B knows them
    lead_start = rnd.randint(40, 160)
    hears = lead_start + rnd.randint(1, 4)
    floor, stand = 0, 0
    for tick in range(300):
        b_leads = tick >= lead_start
        a_knows = tick >= hears
        ah = base + (lead if a_knows else 0)
        if rnd.random() < 0.25:
            msgs.append([max(tick + rnd.randint(0, 3), msgs[-1][0] if msgs else 0), "act", max(tA + ah, floor)])
        floor = max(floor, tA + ah)
        msgs.append([max(tick + rnd.randint(0, 3), msgs[-1][0] if msgs else 0), "clock", (tA, ah)])
        while msgs and msgs[0][0] <= tick:
            _, kind, data = msgs.pop(0)
            if kind == "act":
                if data < tB:
                    late += 1
            else:
                known = data
        ka, kah = known
        limit = ka + window + (lead if b_leads else 0)
        if b_leads and cap:
            limit = min(limit, ka + max(window, kah - reserve - 1))
        tB = min(tB + 1, limit + reserve)        # B may overshoot its limit by its reserve
        if stand > 0:
            stand -= 1
        elif rnd.random() < 0.08:
            stand = rnd.randint(2, 8)
        else:
            lim_a = tB - lead if a_knows else tB + window
            if tA + 1 <= lim_a:
                tA += 1
    return late


lates_cap = sum(model(True, s) for s in range(300))
lates_old = sum(model(False, s) for s in range(300))
check(lates_cap == 0, "model: with the cap, no action of the follower lands late on the leader (300 runs)", lates_cap)
check(lates_old > 0, "model: without it some do, as in the stress test", lates_old)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
