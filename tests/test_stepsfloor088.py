"""Test of the false "stepsDigest" alarm after every resynchronisation (0.8.8: K.stepsDigestAt's floor, MPFEVER_STEPSFLOOR; the
native module's StepsWriter).

The session of 2026-11-14 (two PCs, Test Leawood): one real drift at 02:11 (check 411), a resynchronisation, the games loaded at
02:13:35 and standing until 02:13:43. The first check after it, 420 at 02:13:47, read "stepsDigest" 1380440891 on the host and
3824206710 on the other game: every game dumped its drift rings again, for nothing (drift_diff: alike). Those hashes were of
steps from BEFORE the load, the drift just repaired: the native module's file (native_steps.txt) still held the lines of the game
before, since its rings only start again at the first step after a load and the games made none yet. The same in Kasper's
reports (#285-#296: checks 400, 922, 974, 1208 right after each resynchronisation). Now:
  - the mod takes a window only when its 50 steps come after the first check's time of this script's state (made anew at every
    load): the checks of the first 70 steps after a load answer "absent" (never compared), as the native module's own rule says;
  - the native module empties native_steps.txt as soon as a load is counted, without waiting for the first step.
K.stepsDigestAt is taken from the real bridge and run through lupa; the native module is read.
Run: python tests/test_stepsfloor088.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
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


def state():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end STEP = 200 K = {} C = {}\n" + m.group(0))
    return L, L.eval("function(at, text) return K.stepsDigestAt(at, text) end")


# the file as the game before the load left it: the windows up to the pause at step 894760 (the drift: other hashes on each game)
OLD = "".join(f"{s} {1380440000 + s % 1000}\r\n" for s in range(894370, 894770, 10))
# the session of 2026-11-14: the games reloaded the save of step 894764, the first check at step 894786 (22 steps later)
L, f = state()
got = f(894786 * 200, OLD)
check("the first check after a load, the file still the game before's: absent, not that game's hash (was " + OLD.split("\r\n")[-2].split(" ")[1] + ")",
      got == "absent", got)
check("  the floor: the first check's step", L.eval("K.stepsFloor") == 894786)
got = f(894840 * 200, OLD)
check("a check 54 steps later, still the old file: absent (its window would hold steps of before the first check)", got == "absent", got)
NEW = "894790 0\r\n894800 0\r\n894810 0\r\n894820 0\r\n894830 0\r\n894840 489071137\r\n894850 489071200\r\n"
got = f(894860 * 200, NEW)
check("74 steps after the first check: the window 894791..894840 is after it: compared", got == "489071137", got)
got = f(894855 * 200, NEW)
check("69 steps after: its window (894781..894830) begins before the first check: absent", got == "absent", got)
got = f(894870 * 200, NEW)
check("later: compared as before", got == "489071200", got)

# a game loaded long ago: nothing changes
L, f = state()
L.execute("K.stepsFloor = 100000")
check("long after the load: the check's step less 20, rounded down to 10, as before", f(135640 * 200, "135620 444\r\n") == "444")
# the switch
L, f = state()
L.execute("ENVV.MPFEVER_STEPSFLOOR = '0'")
got = f(894786 * 200, OLD)
check("MPFEVER_STEPSFLOOR=0: the old file's hash, as before", got == "1380440760", got)
check("  and no floor kept", L.eval("K.stepsFloor") is None)
L, f = state()
check("no time: off, no floor taken from it", f(None, OLD) == "off" and L.eval("K.stepsFloor") is None)

nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
w = nat[nat.index("static DWORD WINAPI StepsWriter(void*)\n{"):]
w = w[:w.index("\n}\n")]
check("native: the file emptied as soon as a load is counted (not at the first step after it)",
      'if (!first && DriftLoadReset()) { WriteSessionFile("native_steps.txt", "", 0); last = g_winN; }' in w
      and w.index("long loads = g_ctlLoads;") < w.index("long n = g_winN;"))
check("  not at the process's first game, not with MPFEVER_DRIFTLOADRESET=0", "bool first = loadsW < 0;" in w and "DriftLoadReset()" in w)
check("  the lines of before are not written again (last = the count as it is)", "last = g_winN;" in w and "last = -2" not in w)
check("native: still written by the thread of its own only", "Sleep(250);" in w)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
