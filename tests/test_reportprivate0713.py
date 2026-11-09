"""Offline test: a report never carries the game's crash dump nor the session's chat (0.7.13, launcher/Reporter.cs).

Cowboy Pilot, 2026-11-09: the text files of a report are cleaned (public IP addresses, Windows and PC names, Steam numbers,
e-mails), but the game's crash dump (*.dmp) went in as it was. A dump is the game's memory: the one of issue #172's report held a
public address and a Steam number, which no clean-up of text can reach. The session's chat (chat.txt) is the players' own words.
Both are left out now (report.txt says so), from this PC's report and from the other players' reports put in it (an older MPFever
still sends them); the report no longer waits 15 s for a dump it does not send. MPFEVER_REPORTDUMP=1 / MPFEVER_REPORTCHAT=1:
put in, as before. MPFever.exe --selftest runs Reporter.Private and AddPlayers (SelfTest.RunReportPrivate0713).
Run: python tests/test_reportprivate0713.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "launcher", "Reporter.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.index("public static bool Private(string name)")
body = src[i:src.index("\n        }\n", i)]
check('EndsWith(".dmp", StringComparison.OrdinalIgnoreCase)) return Environment.GetEnvironmentVariable("MPFEVER_REPORTDUMP") != "1"' in body,
      "a crash dump is private (MPFEVER_REPORTDUMP=1: sent, as before)")
check('Equals("chat.txt", StringComparison.OrdinalIgnoreCase)) return Environment.GetEnvironmentVariable("MPFEVER_REPORTCHAT") != "1"' in body,
      "the session's chat is private (MPFEVER_REPORTCHAT=1: sent, as before)")
a = src.index("            void Add(string path, string name)")
check("if (Private(name))" in src[a:a + 700], "  every file of this PC's report goes through it (sessions, logs, the dump)")
p = src.index("public static void AddPlayers(")
check("if (Private(name)) continue;" in src[p:p + 1500], "  and every file of another player's report")
check('if (dmp != null && (!Private(dmp) || withSummary) && Environment.GetEnvironmentVariable("MPFEVER_DUMPWAIT") != "0") WaitWritten(dmp, 15);' in src
      and 'bool withSummary = dmp != null && Private(dmp) && Environment.GetEnvironmentVariable("MPFEVER_CRASHSUMMARY") != "0"' in src,
      "no 15 s wait for a dump that is neither sent nor summed up (0.7.15: its summary waits for it)")
check('"Left out (too large, unreadable or private):"' in src and "never sent: it holds addresses and account numbers" in src,
      "report.txt says what was left out and why")
check("ok &= RunReportPrivate0713();" in st and "static bool RunReportPrivate0713()" in st, "the selftest runs it in the launcher's code")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
