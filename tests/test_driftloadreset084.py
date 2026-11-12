"""Offline test: the drift diagnostic's rings start again after a load (0.8.4, #255-#261, MPFEVER_DRIFTLOADRESET=0 off).

Kasper + Eier (0.8.3, 8 resynchronisations in 1 h 30): right after every resynchronisation the launcher logged "stepsDigest: the
simulation's steps differ" (the games reload the save of the paused time T and go on at the next step numbers, so the 50 steps'
window ran on into the steps of the drift before the load); that false alarm used up the run's forced dump, and the rings of the
later drifts began with the steps before the load (drift_diff named step 428168, the paused builds of 17:45, for the drift of
18:28). native/mpfever_native.cpp is read; the ring logic is replayed in Python.
Run: python tests/test_driftloadreset084.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NAT = os.path.join(HERE, "..", "native", "mpfever_native.cpp")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(NAT, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
m = re.search(r"static void DriftStep\(void\* engine\)\n\{\n(.*?)\n\}\n", src, re.S)
check("DriftStep found", m is not None)
body = m.group(1) if m else ""
i_reset = body.find("if (loads != loadsSeen)")
i_rec = body.find("long i = g_dStepN++")
check("the load test comes before the step is recorded", 0 <= i_reset < i_rec)
blk = body[i_reset:i_rec]
check("  reads the loads' counter (DropAtLoad's g_ctlLoads)", "long loads = g_ctlLoads;" in body)
check("  both rings and the steps' windows emptied", all(s in blk for s in ("g_dStepN = 0", "g_dOpN = 0", "g_winN = 0")))
check("  the step's counters emptied (the load's own entities left out)", "g_stepAdds = g_stepRems = g_stepSet = 0;" in blk)
check("  nothing recorded for the step that straddles the load (return)", "return;" in blk)
check("  not at the first game of the process (the first value is only noted)", "bool first = loadsSeen < 0;" in blk and "!first &&" in blk)
check("  switch MPFEVER_DRIFTLOADRESET=0", 'GetEnvironmentVariableA("MPFEVER_DRIFTLOADRESET"' in src and "DriftLoadReset()" in blk)
check("DropAtLoad still counts the loads", re.search(r"static void DropAtLoad\(\)\n\{.*?_InterlockedIncrement\(&g_ctlLoads\);", src, re.S) is not None)


# the window of StepsWindow, replayed: 50 steps in a row, from the newest back, in the steps ring
def window(ring, made):
    want, got = made, 0
    for s in reversed(ring[-50:]):
        if s != want:
            break
        got += 1
        want -= 1
    return got == 50


def run(reset):
    ring, out = [], {}
    for s in range(1000, 1100):           # before the load: steps up to 1099, paused at the time of step 1100
        ring.append(s)
    # the load of the save of that time: the steps go on at 1100 (the same numbers on every game)
    if reset:
        ring = []
    for s in range(1100, 1200):
        ring.append(s)
        if s % 10 == 0:
            out[s] = window(ring, s)
    return out


before, after = run(False), run(True)
check("as before: the window of step 1110 spans the load (steps of the drift before mixed in)", before[1110] is True)
check("with the reset: no window over the load (1100..1140 'absent'), whole again from 1150", all(not after[s] for s in range(1100, 1150, 10)) and after[1150])

# (0.8.4) the first drift since the load kept apart (mod: sdump_drift_first.txt; native: that check's rings never removed)
BR = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
br = open(BR, encoding="utf-8").read().replace("\r\n", "\n")
kd = br[br.index("function SDUMP.keepDrift(n, dump)"):]
kd = kd[:kd.index("\nend\n")]
check("mod: the first drift since the load written once to sdump_drift_first.txt", "sdump_drift_first.txt" in kd and "if not SDUMP.firstKept" in kd and "SDUMP.firstKept = true" in kd)
check("  switch MPFEVER_DRIFTFIRST=0", 'os.getenv("MPFEVER_DRIFTFIRST") ~= "0"' in kd)
dp = src[src.index("static void DriftPoll()\n{"):]
dp = dp[:dp.index("\n}\n")]
check("native: the first check kept since the last load is never removed by the rotation", "if (old > 0 && old == g_driftFirst) old = 0;" in dp and "firstLoads != g_ctlLoads" in dp)
check("  switch MPFEVER_DRIFTFIRST=0 (read in InstallDriftDiag)", 'GetEnvironmentVariableA("MPFEVER_DRIFTFIRST"' in src and "g_driftFirstOn" in dp)


def rotation(checks, keep_first):
    kept, first, removed = [0, 0, 0], 0, []
    for v in checks:
        old = kept[0]
        kept = kept[1:] + [v]
        if keep_first and first == 0:
            first = v
        if old > 0 and old == first:
            old = 0
        if old > 0:
            removed.append(old)
    return removed


check("  replayed: drifts at checks 17, 25, 27, 29, 31: the first (17) stays", 17 not in rotation([17, 25, 27, 29, 31], True) and 17 in rotation([17, 25, 27, 29, 31], False))


print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
