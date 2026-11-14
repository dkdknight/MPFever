"""Offline test (0.8.9): the launcher asks Windows to keep its 1 ms timer (FineTimer in launcher/MainForm.cs).

2026-11-14 10:19: the self-test measured 15.4 to 17.5 ms per Thread.Sleep(5) with the 1 ms timer asked, in MPFever.exe only (the
same request from another program: 5.7 ms), the released 0.8.8 too: Windows 11 left MPFever's timer request unheeded (its power
throttling of the timer resolution). Every Thread.Sleep(5) of the links between the game and the network then lasts a timer tick.
With ProcessPowerThrottling's IGNORE_TIMER_RESOLUTION turned off for the process: 5.7 ms again.
  - FineTimer.KeepResolution: SetProcessInformation(process, ProcessPowerThrottling = 4) with Version 1, ControlMask 4
    (PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION) and StateMask 0 (not ignored); MPFEVER_TIMERKEEP=0 asks nothing;
  - FineTimer.Begin asks it before timeBeginPeriod, only when the timer is wanted (MPFEVER_TIMER1MS=0: neither);
  - the self-test checks the switch and measures the timer (launcher/SelfTest.cs, RunFineTimer).
Run: python tests/test_timerkeep089.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "launcher", "MainForm.cs")
SELF = os.path.join(HERE, "..", "launcher", "SelfTest.cs")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def main():
    src = open(MAIN, encoding="utf-8-sig").read().replace("\r\n", "\n")
    i = src.find("static class FineTimer")
    body = src[i:src.find("\n    }\n", i)]
    check(i > 0, "FineTimer found")
    k = body.find("internal static bool KeepResolution()")
    check(k > 0, "FineTimer.KeepResolution")
    kb = body[k:k + 700]
    check('GetEnvironmentVariable("MPFEVER_TIMERKEEP") == "0") return false' in kb, "  MPFEVER_TIMERKEEP=0: nothing asked")
    check(re.search(r"Version = 1, ControlMask = 4, StateMask = 0", kb) is not None, "  timer resolution throttling turned off (control 4, state 0)")
    check("SetProcessInformation(GetCurrentProcess(), 4, ref s" in kb, "  for this process, ProcessPowerThrottling (4)")
    check("catch { return false; }" in kb, "  never throws (older Windows)")
    b = body.find("public static bool Begin()")
    bb = body[b:b + 300]
    w, kr, tb = bb.find("if (!Wanted()) return false;"), bb.find("KeepResolution();"), bb.find("timeBeginPeriod(1)")
    check(0 < w < kr < tb, "Begin: asked once the timer is wanted, before timeBeginPeriod")

    st = open(SELF, encoding="utf-8-sig").read()
    check('Check(!FineTimer.KeepResolution(), "timer: MPFEVER_TIMERKEEP=0 does not ask Windows to keep it");' in st, "self-test: the switch checked")
    check("Check(avg < 10, \"timer: Thread.Sleep(5) lasts" in st, "self-test: the timer still measured")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
