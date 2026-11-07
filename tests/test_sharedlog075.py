"""Offline test: a game closed normally beside another game on the same PC is not reported as crashed (0.7.5).

The user's test of 2026-10-29: two games of one Steam account on one PC (host Knight-HD, client Knight-HD2). The client
game, closed normally at 08:45:57 (its native module had just logged "the game closes Steam"), was reported as crashed:
the two games write ONE game log (stdout.txt in the account's crash_dump folder), whose last lines were the host's (still
running, "Normal shutdown" came at 08:46:22), and a dump the game writes at its load was there. The launcher now keeps the
game's exit code and whether another Transport Fever 3 ran beside it: code 0 with another game is no crash.
MPFEVER_SHAREDLOGOLD=1: as before. The launcher's self-test (RunSharedLog075) calls Reporter.CrashedSince itself.
Checked in the launcher's source.
Run: python tests/test_sharedlog075.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
REP = open(os.path.join(L, "Reporter.cs"), encoding="utf-8-sig").read()
CORE = open(os.path.join(L, "Core.cs"), encoding="utf-8-sig").read()
MAIN = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read()
SELF = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = REP.find("public static bool CrashedSince(DateTime since, string sessionDir = null, int? exitCode = null, bool otherGame = false)")
check(i > 0, "CrashedSince takes the exit code and whether another game ran")
body = REP[i:i + 1500]
early = body.find('if (otherGame && exitCode == 0 && Environment.GetEnvironmentVariable("MPFEVER_SHAREDLOGOLD") != "1")')
dump = body.find("bool dump = false;")
check(early > 0 and dump > early, "code 0 beside another game: no crash, decided before the dumps and the log are read")
check("return false;" in body[early:dump], "  and it answers no crash")
check("public static int OtherGamesRunning(int exceptPid)" in REP and 'GetProcessesByName("TransportFever3")' in REP, "the other games counted by their process")

check("public int? ExitCode { get; private set; }" in CORE and "public bool OtherGameSeen { get; private set; }" in CORE, "the game's link keeps its exit code and the other game")
a = CORE.find("if (Reporter.OtherGamesRunning(-1) > 0) OtherGameSeen = true;")
b = CORE.find("proc = Process.Start(psi);")
check(a > 0 and b > a, "another game already running when this one starts")
c = CORE.find("try { ExitCode = proc.ExitCode; } catch { ExitCode = null; }")
d = CORE.find("if (Reporter.OtherGamesRunning(proc.Id) > 0) OtherGameSeen = true;")
e = CORE.find("Exited?.Invoke();", d)
check(b < c < d < e, "at its exit: the code kept and the other games looked at before the launcher hears of it")

check("Reporter.CrashedSince(gameStartedAt, menuGame?.Dir, menuGame?.ExitCode, menuGame != null && menuGame.OtherGameSeen)" in MAIN, "the launcher passes both")
check('"Transport Fever 3 fermé (code {0}{1}).", "Transport Fever 3 closed (code {0}{1})."' in MAIN, "the launcher's log says the exit code")
check("ok &= RunSharedLog075();" in SELF and "static bool RunSharedLog075()" in SELF, "the launcher's self-test calls it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
