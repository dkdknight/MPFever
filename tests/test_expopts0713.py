"""(0.7.14: « without waiting » and « without stopping » are back, on by default, see tests/test_nostopdefault0714.py;
what this test still checks is the platform order's removal.)
Test of the removal of the three experimental settings (0.7.13, launcher/Options.cs, MainForm.cs, ModCopies.cs, SelfTest.cs,
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
  (f) the native module: the platform-order fixes still off unless MPFEVER_ORDER2, the other order fixes as they were;
  (g) (a hardening of the review) in a launcher session settings.txt writes MPFEVER_NOWAIT= and MPFEVER_NOSTOP= (an empty value:
      the mod's os.getenv gives nil), as the two settings' « off » did before 0.7.13: a MPFEVER_NOWAIT=1 / MPFEVER_NOSTOP=1 left in
      one PC's environment cannot turn them on for that game alone (it would replay the others' builds otherwise than the other
      games); the autotests (Options.Disabled: no settings.txt) keep reading their environment; MPFEVER_EXPBLOCK=0 in the
      launcher's environment: not written. Run in lupa with the mod's own os.getenv wrapper (mpfever_common.lua).
Needs lupa (Lua 5.2). Run: python tests/test_expopts0713.py
"""
import json
import os
import re
import sys


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
for k in ("MPFEVER_ORDER2",):
    check('Key = "%s"' % k not in op, "(a) %s is no setting of the launcher any more" % k)
# (0.7.14: « without waiting » and « without stopping » are back, on by default: tests/test_nostopdefault0714.py)
check("Order2On" not in op and "Native = true" not in op, "(a) no \"Same platform order (test)\": nothing of this player's for the native module")
check("All.Where(o => o.Native && !o.Session && IsOn(o) && o.OnValue != \"\")" in op
      and "foreach (var kv in Options.NativeEnv()) psi.EnvironmentVariables[kv.Key] = kv.Value;" in core,
      "(a) the native module's settings path (Options.NativeEnv) kept as it was")
keys = re.findall(r'Key = "([^"]+)"', op) + re.findall(r'Fix\("(MPFEVER_[A-Z0-9_]+)"', op)
want = ["MPFEVER_BUILDLEAD", "MPFEVER_NOWAIT", "MPFEVER_NOSTOP", "MPFEVER_NOREFUND", "MPFEVER_REPLACEFREE", "MPFEVER_PREVIEWS", "MPFEVER_SMOOTH", "MPFEVER_ADAPTAHEAD",
        "MPFEVER_STEPLOG", "autoupdate", "upnp", "automods", "lookupip", "MPFEVER_JUNCTIONCON", "MPFEVER_TOWNNATIVE",
        "MPFEVER_TOWNUPGRADE", "MPFEVER_STOPCLEANUP", "MPFEVER_CONBYFILE", "MPFEVER_EDITFORMS", "MPFEVER_REPLAYUNUSED",
        "MPFEVER_RANK1OWN", "MPFEVER_MODHOST", "MPFEVER_MODEVENTS"]
check(keys == want, "(a) every other setting kept, in its order", ", ".join(k for k in keys if k not in want) or "")
check('new Opt { Key = "MPFEVER_BUILDLEAD", Session = true, DefaultOn = true, OnValue = "1",' in op
      and 'new Opt { Key = "MPFEVER_NOREFUND", Session = true, DefaultOn = true, OffValue = "1",' in op,
      "(a) the session settings next to them unchanged")
check("MPFEVER_ORDER2=1 in the environment of every game" in op, "(a) the code says how to have it back for a test")

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
check('"the platform order setting is gone (0.7.13)"' in rs and "Options.All.Any(o => o.Key == \"MPFEVER_ORDER2\")" in rs
      and "!Options.NativeEnv().Any()" in rs and "Options.ModFile()" in rs,
      "(b) selftest: ORDER2 not in Options.All, nor in the mod's settings.txt or the game's environment")
check("WithOrder2" not in st, "(b) the 0.7.10 selftest of the hello's word gone with it")
check('!mod.Contains("MPFEVER_ORDER2=")' in rs, "(b) selftest: ORDER2 not in the mod's settings.txt")

# ---------------------------------------------------------------- (c) lang.json
gone = ["Same platform order (test)",
        "A test against vehicles drifting apart in stations: the vehicles pick their platform or terminal in the same order on every game. Every player of the game must turn it on, the host too, then start the game again.",
        "« Same platform order (test) »: {0} has it {1}, the host has it {2}. Every player needs the same setting (the launcher's settings, then start the game again), or the games desync."]
check(not any(k in lang for k in gone), "(c) its three texts gone from lang.json", ", ".join(k[:30] for k in gone if k in lang))
check("on" in lang and "off" in lang and 'T("désactivée", "off")' in read("launcher", "Server.cs"), "(c) \"on\" and \"off\" kept (still used)")

# (d) and (e), the bridge's switches with NOWAIT/NOSTOP off: gone in 0.7.14, see tests/test_nostopdefault0714.py

# ---------------------------------------------------------------- (f) the native module
check('if (i >= 6 && i <= 9 && i != 8 && GetEnvironmentVariableA("MPFEVER_ORDER2", 0, 0) == 0) layout = false;' in nat,
      "(f) the platform visit, candidates and needs-path fixes (6, 7, 9): off unless MPFEVER_ORDER2 in the game's environment")
check('if (i == 8) layout = layout && fieldAt && at + f.offset == fieldAt + 0xba && GetEnvironmentVariableA("MPFEVER_NOTOWNFIELD", 0, 0) == 0;' in nat
      and 'if (i == 10) layout = layout && getUpd && g_applyTls != 0xFFFFFFFFu && GetEnvironmentVariableA("MPFEVER_NOTICKEPOCH", 0, 0) == 0;' in nat
      and 'if (i == 11) layout = layout && GetEnvironmentVariableA("MPFEVER_NOFREEMIN", 0, 0) == 0;' in nat,
      "(f) the order fixes that are on (town field, tick epochs, free-id queue) kept by their numbers")
check("0.7.13:" in nat[nat.index("(three of the four ported in 0.5.0, OFF unless MPFEVER_ORDER2=1"):][:800], "(f) the native comment says the setting is gone")
check(all(ord(c) < 128 for c in nat), "(f) the native source stays ASCII")

# (g), settings.txt writing NOWAIT/NOSTOP unset: gone in 0.7.14 (they are settings again, "0" or "1"), see
# tests/test_nostopdefault0714.py

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
