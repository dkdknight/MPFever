"""Offline test of an upgrade of one town street segment that moves town buildings (0.6.7).

An autotest on #109's world (2026-11-01, test v6, one company for everybody) went out of sync after the client upgraded one
town street segment to a large town street: the engine took 5 town buildings away and put 1 back. The host replayed it with
replaceSegment, which aligned the terrain otherwise than the tool (1055.9 on the builder's game, 1079.0 on the host's):
"town stats differ", a reload. Several segments were already replayed as the tool's own proposal; one segment now is too.

G.townOneNative is taken from the real bridge file and run through lupa (Lua 5.2). Cases:
  - one segment, town buildings moved by the engine (a.townAuto): the tool's proposal;
  - one segment without town buildings, two segments, no plan: not this way (as before);
  - MPFEVER_TOWNONE=0 or MPFEVER_TOWNNATIVE=0: replaceSegment, as before;
  - the bridge asks it before replayUpgrade, and replays the native street proposal then.
Run: python tests/test_townone.py
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
    m = re.search(r"^G\.townOneNative = function\(a, plan\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: G.townOneNative not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = {}\n" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")

    check("one segment, town buildings moved: the tool's proposal", run("return G.townOneNative({ townAuto = true }, { { edge = 32010 } })") is True)
    check("one segment, no town building moved: replaceSegment", run("return G.townOneNative({}, { { edge = 1 } })") is False)
    check("two segments: not this way (the merged upgrade first)", run("return G.townOneNative({ townAuto = true }, { { edge = 1 }, { edge = 2 } })") is False)
    check("no plan: not this way", run("return G.townOneNative({ townAuto = true }, nil)") is False)
    run("ENV.MPFEVER_TOWNONE = '0'")
    check("MPFEVER_TOWNONE=0: replaceSegment, as before", run("return G.townOneNative({ townAuto = true }, { { edge = 1 } })") is False)
    run("ENV.MPFEVER_TOWNONE = nil; ENV.MPFEVER_TOWNNATIVE = '0'")
    check("MPFEVER_TOWNNATIVE=0: replaceSegment", run("return G.townOneNative({ townAuto = true }, { { edge = 1 } })") is False)

    i_ask = src.find("if G.townOneNative(a, plan) then")
    i_upg = src.find("if plan then return replayUpgrade(a, plan, 1) end")
    check("the bridge asks it just before replayUpgrade", 0 < i_ask < i_upg and i_upg - i_ask < 400, (i_ask, i_upg))
    check("and replays the native street proposal then", "return replayNativeStreet(a)" in src[i_ask:i_upg])

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
