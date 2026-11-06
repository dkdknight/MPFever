"""Offline test: a report waits for the game's crash dump to be written (0.7.4, MPFEVER_DUMPWAIT=0: as before).

Issue #130 (2026-11-06): the report made right after a crash carried the game's .dmp with 0 bytes: the game was still
writing it. The report now waits until the file is not empty and keeps its size for a second (15 s at most).
Checked in the launcher's source.
Run: python tests/test_dumpwait.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "launcher", "Reporter.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = SRC.find("public static void WaitWritten(string path, int seconds)")
check(i > 0, "a wait for a file being written")
body = SRC[i:i + 700]
check("if (len > 0 && len == last) return;" in body, "done when not empty and the same size twice, a second apart")
check("DateTime.UtcNow.AddSeconds(seconds)" in body, "never longer than asked")
a = SRC.find('if (dmp != null && Environment.GetEnvironmentVariable("MPFEVER_DUMPWAIT") != "0") WaitWritten(dmp, 15);')
b = SRC.find('Add(dmp, "game/" + Path.GetFileName(dmp));')
check(a > 0 and b > a, "the dump is waited for before it is added to the report (15 s at most)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
