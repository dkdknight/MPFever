"""Offline test (0.8.17, perf): the checks' interval grows with what a check costs on the slowest game (MainForm.HashInterval
in launcher/MainForm.cs, RunHashAdapt0817 in launcher/SelfTest.cs run by MPFever.exe --selftest in tests/run_all.py and
build.bat; switch MPFEVER_HASHADAPT).

The launcher asked for a check every 10 s whatever it cost. Each check holds every game's simulation for its time: in the
0.8.16 reports, 0.4 s at most checks of Andy's, yoyo's and Eric's maps (4 % of the time and a hitch every 10 s), 1.2 s of
Bence's (12 %). Now the mean of the last 7 checks' slowest cost times 40, between 10 and 20 s (2.5 % of the time up to
0.5 s a check; 20 s at most since the host's money values go with each check);
a small map stays at 10 s, games found apart bring the next check at 10 s as before.
  - the self-test: MPFEVER_HASHADAPT=0 every 10 s on Andy's map (the slowdown); now about 16 s; Bence's 20 s; a small map 10 s;
    games apart 10 s; no cost known 10 s;
  - the host's loop uses the interval (not in a pause: a paused check costs no simulation time);
  - each check's slowest cost is kept when every game answered; the games apart set the flag; a new session forgets the costs.
Run: python tests/test_hashadapt0817.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
hi = mf[mf.index("internal static double HashInterval("):]
hi = hi[:hi.index("\n        }\n")]
check("HashInterval: the switch MPFEVER_HASHADAPT=0 and games apart give 10 s", 'if (env == "0" || apart || recentCosts == null) return HashEverySeconds;' in hi)
check("  the mean of the costs times 40, between 10 and 20 s", "Math.Max(HashEverySeconds, Math.Min(HashMaxSeconds, l.Average() * HashCostFactor))" in hi
      and "const double HashMaxSeconds = 20, HashCostFactor = 40;" in mf and "const int HashCostWindow = 7;" in mf)
check("  read with the switch", 'Environment.GetEnvironmentVariable("MPFEVER_HASHADAPT")' in mf)
check("the host's loop uses it, not in a pause", "Now - lastHash > (paused ? HashEverySeconds : CurrentHashInterval())" in mf)
check("  no other place asks every 10 s", mf.count("Now - lastHash > HashEverySeconds") == 0)
sh = mf[mf.index("void OnSyncHash(Msg m)"):]
sh = sh[:sh.index("\n        }\n")]
check("each check's slowest cost kept once every game answered", "hashCostOf[n] = Math.Max(" in sh and "hashCostRecent.Enqueue(hashCostOf[n]);" in sh
      and "while (hashCostRecent.Count > HashCostWindow) hashCostRecent.Dequeue();" in sh)
check("games apart (a difference now or pending) or a forced drift dump set the flag (the review)", "hashApart = diffs.Count > 0 || pending.Count > 0 || worldDumpNext;" in sh)
check("  a check not compared (other turns, other times) brings the next at 10 s (the review)", sh.count("hashApart = true;") == 2
      and sh.index("hashApart = true;") < sh.index("var diffs = new List<string>();"))
for tag in ('AutoLine("sync: " + syncText + " (desyncs " + desyncs + ")");', 'AutoLine("soak over: " + syncText'):
    k = mf.index(tag)
    check("the soak's verdict after a check of its own (the review: checks up to 20 s apart): " + tag[:28], "RequestHash();" in mf[k - 200:k] and "Thread.Sleep(12000);" in mf[k - 200:k])
check("a new session forgets the costs", "lock (hashes) { hashCostRecent.Clear(); hashCostOf.Clear(); }" in mf)
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
check("the self-test runs it", "ok &= RunHashAdapt0817();" in st and "static bool RunHashAdapt0817()" in st)
check("  the slowdown with the switch off, the interval now", 'MainForm.HashInterval(andy, false, "0") == 10' in st and "a > 15.5 && a < 16.5" in st)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
