"""Test of the removal of the three experimental settings (0.7.13, launcher/Options.cs, MainForm.cs, ModCopies.cs, SelfTest.cs,
lang.json, mod/mpfever_1/content/mpfever_bridge.script.lua, native/mpfever_native.cpp).

The host's « Other players' builds without waiting » (MPFEVER_NOWAIT) and « Several players building without stopping »
(MPFEVER_NOSTOP: NOWAIT + PRESHIP + LEADACK + HELDNOTPAUSED + ACTLEAD) and the player's « Same platform order (test) »
(MPFEVER_ORDER2) are gone from the settings: off on every game, a value kept in mpfever_settings.txt is ignored. Why: without
waiting, a game no longer stands at another player's build once its one command is handed to the engine; but a stop the engine
refuses is tried again a frame later (without the tool's pricing, with the street cleanup, by the engine's conversion), and that
retry is not held: the game has passed the build's step and the stop comes several steps late (r161, yoyo 2026-11-08: Bence#11:16
refused 3 times, then built by the engine's conversion "0 step(s) after its time", the games IDENTICAL after; without waiting
about 8 steps late, then a reload). The per-build stand was lower with NOSTOP (#150: 1927 ms -> 690 ms) but the session's was not
(the leads move it onto the other games), and ORDER2 brought nothing measurable. The code stays, dormant behind its variables:
MPFEVER_NOWAIT=1 / MPFEVER_NOSTOP=1 / MPFEVER_ORDER2=1 in the environment of every game: as before (tests).
  (a) Options.cs: none of the three, no Order2On; the native module's settings path kept as it was;
  (b) no word on ORDER2 in the hello, no host warning; the selftest checks the settings are gone;
  (c) lang.json: their seven texts gone, "on" and "off" kept (still used);
  (d) the bridge's switches (lupa): none set, all five parts off; NOSTOP=1 all on; NOSTOP=1 NOWAIT=0 all but NOWAIT; NOWAIT=1 alone;
  (e) why NOWAIT stays off (lupa): a refused stop tried again after its one command was handed is not held, while the default
      holds the game through the retry;
  (f) the native module: the platform-order fixes still off unless MPFEVER_ORDER2, the other order fixes as they were.
Needs lupa (Lua 5.2). Run: python tests/test_expopts0713.py
"""
import json
import os
import re
import sys

import lupa.lua52 as lupa

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


op = read("launcher", "Options.cs")
core = read("launcher", "Core.cs")
mf = read("launcher", "MainForm.cs")
mc = read("launcher", "ModCopies.cs")
st = read("launcher", "SelfTest.cs")
lang = json.loads(read("launcher", "lang.json"))["texts"]
src = read("mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
nat = read("native", "mpfever_native.cpp")

# ---------------------------------------------------------------- (a) Options.cs
for k in ("MPFEVER_NOWAIT", "MPFEVER_NOSTOP", "MPFEVER_ORDER2"):
    check('Key = "%s"' % k not in op, "(a) %s is no setting of the launcher any more" % k)
check("Order2On" not in op and "Native = true" not in op, "(a) no \"Same platform order (test)\": nothing of this player's for the native module")
check("All.Where(o => o.Native && !o.Session && IsOn(o) && o.OnValue != \"\")" in op
      and "foreach (var kv in Options.NativeEnv()) psi.EnvironmentVariables[kv.Key] = kv.Value;" in core,
      "(a) the native module's settings path (Options.NativeEnv) kept as it was")
keys = re.findall(r'Key = "([^"]+)"', op) + re.findall(r'Fix\("(MPFEVER_[A-Z0-9_]+)"', op)
want = ["MPFEVER_BUILDLEAD", "MPFEVER_NOREFUND", "MPFEVER_REPLACEFREE", "MPFEVER_PREVIEWS", "MPFEVER_SMOOTH", "MPFEVER_ADAPTAHEAD",
        "MPFEVER_STEPLOG", "autoupdate", "upnp", "automods", "lookupip", "MPFEVER_JUNCTIONCON", "MPFEVER_TOWNNATIVE",
        "MPFEVER_TOWNUPGRADE", "MPFEVER_STOPCLEANUP", "MPFEVER_CONBYFILE", "MPFEVER_EDITFORMS", "MPFEVER_REPLAYUNUSED",
        "MPFEVER_RANK1OWN", "MPFEVER_MODHOST", "MPFEVER_MODEVENTS"]
check(keys == want, "(a) every other setting kept, in its order", ", ".join(k for k in keys if k not in want) or "")
check('new Opt { Key = "MPFEVER_BUILDLEAD", Session = true, DefaultOn = true, OnValue = "1",' in op
      and 'new Opt { Key = "MPFEVER_NOREFUND", Session = true, DefaultOn = true, OffValue = "1",' in op,
      "(a) the session settings next to them unchanged")
check("MPFEVER_NOWAIT=1 / MPFEVER_NOSTOP=1 in the environment of" in op and "MPFEVER_ORDER2=1 in the environment of every game" in op,
      "(a) the code says how to have them back for a test")

# ---------------------------------------------------------------- (b) the hello, the host's warning, the selftest
for name, text in (("ModCopies.cs", mc), ("MainForm.cs", mf)):
    check("WithOrder2(" not in text and "WarnOrder2(" not in text and "Order2On(" not in text, "(b) %s: no ORDER2 word in the hello, no warning" % name)
hello = mf[mf.index('                if (m.Kind == "hello") { g.InGame = true;'):][:700]   # (0.7.13: the game's memory logged aside, see test_resyncspeed0713.py)
check("\n                lock (waiting)\n" in hello, "(b) a player's hello goes on to the host as its game wrote it")
hh = mf[mf.index('                case "hello":\n                    lock (players) players.Add(m.From);'):][:300]
check("                    WarnModVersion(m.From, m.Payload);\n                    // (0.7.4, MODRETRY" in hh, "(b) the host looks at the mod version only")
rs = st[st.index("        static bool RunExpOpts0713()"):]
rs = rs[:rs.index("\n        }\n")]
check(re.search(r"ok &= RunDeadDirect0713\(\);(\s+ok &= Run\w+\(\);)*\s+ok &= RunExpOpts0713\(\);", st) is not None, "(b) the selftest runs its check, after RunDeadDirect0713")
check('"the experimental settings are gone (0.7.13)"' in rs and "Options.All.Any(o => gone.Contains(o.Key))" in rs
      and "Options.SessionPayload()" in rs and "!Options.NativeEnv().Any()" in rs and "Options.ModFile()" in rs,
      "(b) selftest: not in Options.All, nor in the host's payload, the mod's settings.txt or the game's environment")
check('"MPFEVER_NOWAIT", "MPFEVER_NOSTOP", "MPFEVER_ORDER2"' in rs, "(b) selftest: the three of them")
check("WithOrder2" not in st, "(b) the 0.7.10 selftest of the hello's word gone with it")

# ---------------------------------------------------------------- (c) lang.json
gone = ["Other players' builds without waiting (experimental)",
        "Your game no longer stops at every build of another player to wait for the engine's answer: it is applied at the same moment, without a pause.",
        "Several players building without stopping (experimental)",
        "When several players build at once, the games no longer stop to wait for each other's builds: each one goes at the click and every game checks at its time that nothing changed where it is made. Includes the no-wait setting.",
        "Same platform order (test)",
        "A test against vehicles drifting apart in stations: the vehicles pick their platform or terminal in the same order on every game. Every player of the game must turn it on, the host too, then start the game again.",
        "« Same platform order (test) »: {0} has it {1}, the host has it {2}. Every player needs the same setting (the launcher's settings, then start the game again), or the games desync."]
check(not any(k in lang for k in gone), "(c) their seven texts gone from lang.json", ", ".join(k[:30] for k in gone if k in lang))
check("on" in lang and "off" in lang and 'T("désactivée", "off")' in read("launcher", "Server.cs"), "(c) \"on\" and \"off\" kept (still used)")

# ---------------------------------------------------------------- (d) the bridge's switches, run in lupa
fi = src.index("G.nostopOn = false\nG.featureOn = function(name)")
fj = src.index("-- ================================================================== no wait for the answer (0.8, MPFEVER_NOWAIT=1)")
feat = src[fi:fj]
ra = src.index("local function resumeAfterLoad(state)")
ri = src.index('G.nostopOn = os.getenv("MPFEVER_NOSTOP") == "1"', ra)
rj = src.index('G.actLeadOn = G.featureOn("MPFEVER_ACTLEAD")', ra)
reads = src[ri:src.index("\n", rj)]
check(ri - ra < 1600 and rj > ri, "(d) the switches read at every start of a session, near the top of resumeAfterLoad")
check('G.nostopOn = os.getenv("MPFEVER_NOSTOP") == "1"' in reads and "return G.nostopOn == true" in feat,
      "(d) MPFEVER_NOSTOP read from the environment only (no setting of the launcher writes it any more)")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = {}\n" + feat)
L.execute("function readAll()\n" + reads + "\nend")
PARTS = ["gateWanted", "preshipWanted", "leadAckOn", "heldNotPausedOn", "actLeadOn"]


def parts(env):
    L.execute("ENV = {}")
    for k, v in env.items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute("readAll()")
    g = L.globals().G
    return {p: g[p] for p in PARTS}


r = parts({})
check(all(v is False for v in r.values()), "(d) none set (the default, every game since 0.7.13): all five parts off", r)
check(L.eval("G.nostopOn") is False, "(d)   and NOSTOP off")
r = parts({"MPFEVER_NOSTOP": "1"})
check(all(v is True for v in r.values()), "(d) MPFEVER_NOSTOP=1: the five parts on, as the host's setting did", r)
r = parts({"MPFEVER_NOSTOP": "1", "MPFEVER_NOWAIT": "0"})
check(r["gateWanted"] is False and all(r[p] is True for p in PARTS[1:]), "(d) MPFEVER_NOSTOP=1 MPFEVER_NOWAIT=0: all but NOWAIT", r)
r = parts({"MPFEVER_NOWAIT": "1"})
check(r["gateWanted"] is True and all(r[p] is False for p in PARTS[1:]), "(d) MPFEVER_NOWAIT=1 alone: NOWAIT only, as the host's setting did", r)
r = parts({"MPFEVER_NOSTOP": "", "MPFEVER_NOWAIT": "", "MPFEVER_PRESHIP": "0"})
check(all(v is False for v in r.values()), "(d) empty values (an old settings.txt's unset lines): all off", r)

# ---------------------------------------------------------------- (e) why NOWAIT stays off: a refused stop's retry is not held
i = src.index("-- ================================================================== no wait for the answer (0.8, MPFEVER_NOWAIT=1)")
j = src.index("-- ================================================================== native deferral (with mpfever_native.dll)")
nw = src[i:j]
m_hold = re.search(r"^local function nativeHoldAt\(\)\n.*?^end\n", src, re.S | re.M)
check(m_hold is not None, "(e) nativeHoldAt found")
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
L2.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 100000
LOGS = {}
function gameTime() return NOW end
function overshootReserve() return 2 end
function log(s) LOGS[#LOGS + 1] = s end
C = { ACTIVE = true }
O = { steps = true }
K = { JOIN_GATHER = 60 }
G = { frames = 5000, natRelease = {}, natWait = {}, nativeQueue = {}, simStill = function() return true end, joinTurn = function() return true end }
''')
L2.execute(nw)
L2.execute(m_hold.group(0).replace("local function nativeHoldAt", "function nativeHoldAt", 1))
run = L2.eval("function(code) local f = assert(load(code)) return f() end")
check(run("return G.gateOn()") is False, "(e) the gate off as the file loads")
# a street stop of another player, at its step t=100000: one command (G.gateSingle), handed to the engine
L2.execute("G.gateWanted = true; G.gateCur = { at = NOW, uid = 'Bence#11:16' }; G.gateSingle(); G.gateCur.handed = 1")
check(run("return G.gateHolds()") is False, "(e) NOWAIT: its one command handed, nothing holds the game for it")
# the engine refuses it: the retry goes a frame later (replayStop: G.waits at G.frames + 1, G.gateLate)
L2.execute("G.gateLate('a refused stop, tried again')")
check(run("return G.gateHolds()") is False, "(e) NOWAIT: the refused stop's retry is not held either")
check(sum("a refused stop, tried again after the build's step" in str(s) for s in L2.globals().LOGS.values()) == 1,
      "(e)   it is only logged (\"after the build's step\")")
# the answer just came back (replayQuiet: three frames after it), the retry is due
L2.execute("G.replayOut = 0; G.replayQuiet = G.frames + 3; G.replayAt = NOW")
got = run("return tostring(nativeHoldAt())")
check(got == "nil", "(e) NOWAIT: the game is not held while the retry is due: it runs past the stop's step", got)
L2.execute("G.gateWanted = false")
check(run("return G.gateHolds()") is None, "(e) default (no NOWAIT): no gate, nativeHoldAt's replay-busy branch decides")
got = run("return tostring(nativeHoldAt())")
check(got == "100000", "(e) default: the game held at the stop's step through its retry", got)
rst = src[src.index("local function replayStop(a, plan, variant)"):]
rst = rst[:rst.index("\nend\n")]
check(rst.count('pcall(G.gateLate, "a refused stop, tried again")\n\t\t\tG.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayStop(a, plan, variant) end }') == 2
      and 'pcall(G.gateLate, "a refused stop, tried by the engine\'s conversion")\n\t\t\t\tG.waits[#G.waits + 1] = { at = G.frames + 1, fn = function()' in rst,
      "(e) replayStop's three retries (pricing, street cleanup, the engine's conversion) go a frame later, with G.gateLate")
check("pcall(G.gateSingle)\n\treplaySend(cmd, function(res, success)" in rst, "(e)   after its one command marked single (G.gateSingle)")
hold = m_hold.group(0) if m_hold else ""
check("elseif gh == nil and ((G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0)" in hold
      and "if G.replayAt and G.replayAt > now and G.replayAt <= now + 8 * STEP then return G.replayAt end\n\t\treturn now" in hold,
      "(e) nativeHoldAt: without a gate, a replay under way (or just answered) holds the game")
check("G.gateWanted = false\n" in nw and 'G.gateWanted = G.featureOn("MPFEVER_NOWAIT")' in reads, "(e) NOWAIT off unless MPFEVER_NOWAIT=1 (or NOSTOP=1)")

# ---------------------------------------------------------------- (f) the native module
check('if (i >= 6 && i <= 9 && i != 8 && GetEnvironmentVariableA("MPFEVER_ORDER2", 0, 0) == 0) layout = false;' in nat,
      "(f) the platform visit, candidates and needs-path fixes (6, 7, 9): off unless MPFEVER_ORDER2 in the game's environment")
check('if (i == 8) layout = layout && fieldAt && at + f.offset == fieldAt + 0xba && GetEnvironmentVariableA("MPFEVER_NOTOWNFIELD", 0, 0) == 0;' in nat
      and 'if (i == 10) layout = layout && getUpd && g_applyTls != 0xFFFFFFFFu && GetEnvironmentVariableA("MPFEVER_NOTICKEPOCH", 0, 0) == 0;' in nat
      and 'if (i == 11) layout = layout && GetEnvironmentVariableA("MPFEVER_NOFREEMIN", 0, 0) == 0;' in nat,
      "(f) the order fixes that are on (town field, tick epochs, free-id queue) kept by their numbers")
check("0.7.13:" in nat[nat.index("(three of the four ported in 0.5.0, OFF unless MPFEVER_ORDER2=1"):][:800], "(f) the native comment says the setting is gone")
check(all(ord(c) < 128 for c in nat), "(f) the native source stays ASCII")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
