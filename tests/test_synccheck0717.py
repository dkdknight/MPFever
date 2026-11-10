"""Offline test: a sync check of games at different game times is not compared, and a refused build's reports are waited for
up to 5 s (0.7.17, issues #188 and #193; OnSyncHash and "replay_failed" in launcher/MainForm.cs).

#188 (olihf and Tezla, 19:17:28): "OUT OF SYNC #148" (money, towns, stocks, vehicles... and time 27534600 / 27535800): the two
games had sent their checks 6 steps apart, one had applied a build the other had not yet. Nothing had parted.
#193 (BaumEdePiep, 20:43): a vehicle sold twice; the three games refused the second sale alike, but their reports came 19.0,
21.0 and 21.7 s, and after the 1.5 s waited only one had come: every game reloaded for nothing.
  - OnSyncHash: DifferentTimes(got) before any comparison, logged, not compared; after 3 in a row compared again; switch;
  - replay_failed: after the 1.5 s, looked at every 0.25 s for FailWaitTicks (5 s in all) until refused everywhere; switch;
  - #184 #189: a player's report wrote "Sync: —" (only the host compares): "checked by the host" (MPFEVER_REPORTSYNC=0: "—");
  - the launcher's self-test (RunSync0717) runs DifferentTimes and FailWaitTicks.
Run: python tests/test_synccheck0717.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


h = mf[mf.index("void OnSyncHash(Msg m)"):]
h = h[:h.index("var names = got.Keys.OrderBy(k => k).ToList();")]
check('Environment.GetEnvironmentVariable("MPFEVER_TIMECHECK") != "0" && DifferentTimes(got)' in h, "MPFEVER_TIMECHECK=0: compared as before")
check("timeSkips = timesDiffer ? timeSkips + 1 : 0;" in h and "if (timesDiffer && timeSkips <= 3)" in h, "not compared, 3 times in a row at most")
check(h.index("DifferentTimes(got)") < h.index("lastSyncAt = Now;"), "  before any comparison")
d = mf[mf.index("internal static bool DifferentTimes("):]
d = d[:d.index("\n        }\n")]
check('TryGetValue("time"' in d and "times.Count > 1" in d, "DifferentTimes: the games' time parts")
c = mf[mf.index('case "replay_failed":'):]
c = c[:c.index('case "save_done":')]
check('Environment.GetEnvironmentVariable("MPFEVER_FAILWAIT") != "0"' in c, "MPFEVER_FAILWAIT=0: 1.5 s as before")
w = c[c.index("bool everywhere = RefusedEverywhere("):]
check(w.index("Thread.Sleep(250);") < w.index("if (everywhere)") and "fw < FailWaitTicks && !everywhere" in w,
      "the reports looked at again every 0.25 s until refused everywhere")
check(c.index("Thread.Sleep(1500);") < c.index("bool everywhere"), "  after the first 1.5 s, as before")
check("internal const int FailWaitTicks = 14;" in mf, "5 s in all")
rs = open(os.path.join(L, "ReportShare.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
check("ReportSyncText(syncText, server == null && hostGame == null && clients.Count > 0)" in rs
      and 'Environment.GetEnvironmentVariable("MPFEVER_REPORTSYNC") != "0"' in rs, "#184: a player's report says the host checks (MPFEVER_REPORTSYNC=0: as before)")
check("ok &= RunSync0717();" in st and "MainForm.DifferentTimes(diff)" in st, "the launcher's self-test runs them")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
