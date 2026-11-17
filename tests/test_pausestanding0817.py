"""Offline test: a resynchronisation's pause asked while the session stands stays where the games stand (0.8.17, #395;
MainForm.PauseStamp / Pause in launcher/MainForm.cs, RunPauseStanding0817 in launcher/SelfTest.cs run by MPFever.exe --selftest
in tests/run_all.py and build.bat; switch MPFEVER_PAUSESTANDING).

local_user's session (2026-11-16 19:02): the session stood at its start (speed 0, every game at the pause 12208000) when mandy
joined; the resynchronisation's pause went to a future stamp (12209200) that no standing game could reach, the launcher waited
120 s and gave up ("the games did not stop"): mandy had to be invited again.
  - Pause uses PauseStamp: a standing session (speed 0, a pause already) keeps its pause; a running one, or no pause yet, the
    future stamp as before; MPFEVER_PAUSESTANDING=0: the future stamp always (the self-test shows the stamp no game reaches);
  - the resynchronisation still waits for every clock at the pause and at speed 0.
Run: python tests/test_pausestanding0817.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


m = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
p = m[m.index("        void Pause(string who)"):]
p = p[:p.index("\n        }\n")]
check("Pause asks PauseStamp (switch MPFEVER_PAUSESTANDING)", "at = PauseStamp(at, cur, sp, RoundUpToStep(MaxClock()), Environment.GetEnvironmentVariable(\"MPFEVER_PAUSESTANDING\") != \"0\");" in p)
ps = m[m.index("internal static long PauseStamp("):]
ps = ps[:ps.index("\n        }\n")]
check("PauseStamp: a standing session keeps its pause", "if (!on || speed != 0 || !currentPause.HasValue) return future;" in ps and "return currentPause.Value;" in ps)
r = m[m.index("void ResyncLocked(string reason)"):]
check("the resynchronisation still waits for every clock at the pause, at speed 0", "clocks.Values.All(c => c.T >= at && c.Sp == 0)" in r)
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
check("the self-test runs it", "ok &= RunPauseStanding0817();" in st and "static bool RunPauseStanding0817()" in st)
check("  with #395's figures, the bug with the switch off", "MainForm.PauseStamp(12209200, 12208000, 0, 12208000, false) == 12209200" in st)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
