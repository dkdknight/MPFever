"""Offline test of how long a game waits for a build another game announced (0.6.9, expireNativeWaits in the bridge).

Test fz1 of 2026-11-02 (one company per player, Test Gameplay, two computer companies): the host announced its road build for
t=25696000, then, busy with a build the game refused, shipped it 18 s later. The client had stopped waiting after 1800 frames,
12 s with the test's small windows ("never arrived: no longer holding (desync risk)"), went on, and applied the build 6 steps
late: the segment's age, the towns and the vehicles apart, a reload. A wait now lasts 1800 frames and at least 60 s of real
time. expireNativeWaits is taken from the real bridge and run through lupa (Lua 5.2) with a mocked clock. Cases:
  - past 1800 frames but within 60 s: still waited for;
  - past both: given up (logged);
  - a build that arrived: never given up;
  - MPFEVER_NATWAITSECONDS=0: the frames only, as before; another number: those seconds;
  - the wait's start is recorded with the real time.
Run: python tests/test_natwait.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^local function expireNativeWaits\(\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: expireNativeWaits not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
NOW = 0
os.clock = function() return NOW end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
G = { frames = 0, natWait = {} }
""" + m.group(0) + "\nEXPIRE = expireNativeWaits\n")
    run = L.eval("function(code) return assert(load(code))() end")

    run("G.natWait = { { origin = 'Host', at = 25696000, since = 0, sinceT = 0 } }; G.frames = 1900; NOW = 12; EXPIRE()")
    check("1900 frames but 12 s: still waited for", run("return #G.natWait") == 1)
    run("NOW = 61; EXPIRE()")
    check("past 1800 frames and 60 s: given up", run("return #G.natWait") == 0)
    check("and logged", "never arrived" in str(run("return LOG[#LOG]")))
    run("G.natWait = { { origin = 'Host', at = 1, since = 0, sinceT = 0, arrived = true } }; G.frames = 99999; NOW = 9999; EXPIRE()")
    check("a build that arrived: never given up", run("return #G.natWait") == 1)
    run("ENV.MPFEVER_NATWAITSECONDS = '0'; G.natWait = { { origin = 'Host', at = 2, since = 0, sinceT = 0 } }; G.frames = 1900; NOW = 12; EXPIRE()")
    check("MPFEVER_NATWAITSECONDS=0: 1800 frames only, as before", run("return #G.natWait") == 0)
    run("ENV.MPFEVER_NATWAITSECONDS = '20'; G.natWait = { { origin = 'Host', at = 3, since = 0, sinceT = 0 } }; G.frames = 1900; NOW = 12; EXPIRE()")
    check("another number: those seconds (12 of 20: waited)", run("return #G.natWait") == 1)
    run("NOW = 21; EXPIRE()")
    check("(21 of 20: given up)", run("return #G.natWait") == 0)
    run("ENV.MPFEVER_NATWAITSECONDS = nil; G.natWait = { { origin = 'Host', at = 4, since = 0, sinceT = 0 } }; G.frames = 100; NOW = 500; EXPIRE()")
    check("within 1800 frames: waited, however long", run("return #G.natWait") == 1)

    check("the wait records the real time it started", "since = G.frames, sinceT = os.clock()," in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
