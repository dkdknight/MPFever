"""Offline test: the steps' digests in the checks (0.8.3, MPFEVER_STEPSDIGEST, MPFEVER_STEPSDUMP).

In the players' reports of 0.8.2 the drift rings were asked for minutes after the games parted (people, towns): the entity
operations ring (131072, about 3000 steps of a big map with three players) no longer held the step where it began ("older than the
rings", #238 #241). Now the native module reduces every 10 steps the digests of the last 50 steps to one hash (native_steps.txt),
the mod puts the one of its check's step into the check ("stepsDigest"), and the launcher, which never reloads for it (a
diagnostic part), asks every game for its rings at the first check where it differs.
K.stepsDigestAt is taken from the real bridge and run through lupa (Lua 5.2); the native module and the launcher are read.
Run: python tests/test_stepsdigest083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


bridge = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^K\.stepsDigestAt = function\(at, text\)\n.*?^end\n", bridge, re.S | re.M)
if not m:
    print("FAIL: K.stepsDigestAt not found in the bridge")
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end STEP = 200 K = {} C = {}\n" + m.group(0))
f = L.eval("function(at, text) return K.stepsDigestAt(at, text) end")

FILE = "135590 111\r\n135600 222\r\n135610 0\r\n135620 444\r\n"
# a check at t = 135640 * 200: step 135640 - 20 = 135620
check("the check's step less 20, rounded down to 10: its hash", f(135640 * 200, FILE) == "444")
check("  rounded down (step 135625 -> 135600 + ...)", f(135625 * 200, FILE) == "222")   # 135605 -> 135600
check("not 50 steps in a row there yet (hash 0): absent, not compared", f(135630 * 200, FILE) == "absent")
check("that step not in the file: absent", f(140000 * 200, FILE) == "absent")
check("no time: off", f(None, FILE) == "off")
L.execute("ENVV.MPFEVER_STEPSDIGEST = '0'")
check("MPFEVER_STEPSDIGEST=0: off", f(135640 * 200, FILE) == "off")
check("the part is in every check (simHash)", "parts.stepsDigest = K.stepsDigestAt(tonumber(at))" in bridge)

nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read()
check("native: the window reduced in DriftStep, on the simulation's thread", "StepsWindow(d.step);" in nat)
check("native: written by a thread of its own, every 250 ms when it changed", "CreateThread(0, 0, StepsWriter" in nat and "Sleep(250);" in nat)
check("native: a window of 50 steps in a row since the load, else 0", re.search(r"g_win\[i\]\.hash = got == 50 \? \(h \? h : 1\) : 0;", nat) is not None
      and "if (s.step != want) break;" in nat)
check("native: MPFEVER_STEPSDIGEST=0 starts no thread", 'GetEnvironmentVariableA("MPFEVER_STEPSDIGEST"' in nat)
check("native: no more than 40 lines (the 1000-character buffer)", "long from = n > 40 ? n - 40 : 0;" in nat)

mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read()
check("launcher: a diagnostic part, never a reason to reload",
      re.search(r'DiagnosticParts = new HashSet<string> \{[^}]*"stepsDigest"', mf) is not None)
check("launcher: never a local measure", re.search(r'NeverLocalParts = new HashSet<string> \{[^}]*"stepsDigest"', mf) is not None)
check("launcher: the rings asked for once per run at its first difference",
      re.search(r'if \(!stepsDumped && diag\.Any\(d => DiffKey\(d\) == "stepsDigest"\)[^\n]*\n\s*\{\s*\n\s*stepsDumped = true;\s*\n\s*worldDumpNext = true;', mf) is not None)
check("launcher: a reload starts a new run (session start, after a resynchronisation)", mf.count("stepsDumped = false;") == 2)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
