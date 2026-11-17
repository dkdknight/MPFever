"""Offline test (0.8.17, #400): a refused action's reports are waited for until every silent game has run past its time, not
5 s (replayFailed in mpfever_bridge.script.lua sends the action's time; FailedAt, FailWaitDecided and the "replay_failed" wait in
launcher/MainForm.cs; RunFailClock0817 in launcher/SelfTest.cs, run by MPFever.exe --selftest in tests/run_all.py and build.bat;
switch MPFEVER_FAILCLOCK).

#400 (yoyo, YkeWoudstra, Bence, 2026-11-16 20:36:51): Bence#6:6 sold again the vehicles Bence#6:5 had sold (the line window's
list, then the line deleted); every game refused it alike ("DESYNC unresolved"), but the reports came 0, 4.4 and 6.5 s apart
(YkeWoudstra's game 4 to 6 s behind the host's, which led): after 5 s the launcher reloaded every game for nothing.
  - the report carries the action's time (at);
  - with it, the launcher waits until each game that has not reported is 8 steps past that time (its reports and its clocks
    come in order), 20 s at most; a game that ran past it silently built it: the games differ, reloaded as before;
  - without it (an older version) or MPFEVER_FAILCLOCK=0: 5 s, as before (the self-test shows YkeWoudstra still waited for at
    the moment the 5 s rule gave up);
  - MPFEVER_FAILWAIT=0: 1.5 s, as before 0.7.17.
Run: python tests/test_failclock0817.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


b = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
rf = b[b.index("local function replayFailed(a, why)"):]
rf = rf[:rf.index("\nend\n")]
check("the report of a refusal carries the action's time", 'send, "replay_failed", { uid = tostring(a.uid), why = tostring(why):sub(1, 120), at = okA and at or nil })' in rf)
m = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
w = m[m.index('case "replay_failed":'):]
w = w[:w.index('case "save_done":')]
check("the launcher reads it", "long? fat = FailedAt(m.Payload);" in w)
check("  switch MPFEVER_FAILCLOCK=0: as before", 'Environment.GetEnvironmentVariable("MPFEVER_FAILCLOCK") != "0"' in w)
check("  waits by the clocks (20 s at most), else 5 s as before", "(byClock ? fw < FailWaitClockTicks : fw < FailWaitTicks)" in w)
check("  stops waiting once every silent game ran past it", "if (FailWaitDecided(fat.Value, who, all.Select(BaseName), ct, FailClockSlack)) break;" in w)
check("  MPFEVER_FAILWAIT=0 still 1.5 s", 'Environment.GetEnvironmentVariable("MPFEVER_FAILWAIT") != "0"' in w)
check("8 steps of slack, 74 looks after 1.5 s", "internal const long FailClockSlack = 8 * 200;" in m and "internal const int FailWaitClockTicks = 74;" in m)
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
check("the self-test runs it", "ok &= RunFailClock0817();" in st and "static bool RunFailClock0817()" in st)
check("  #400's figures: YkeWoudstra still waited for at 11 steps behind", "still waited for (it reported 6.5 s later)" in st)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
