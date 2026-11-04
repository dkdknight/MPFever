"""Offline test of the builder's lead check with the other game's clock as it is now (0.6.12, the final stress test of
2026-11-04: both games building at once, builds released at once landed 1 to 3 steps late on the other game, a desync).

G.buildLeadState compared the other game's clock as it sent it, 0.1 to 0.5 s old at 4x (2 to 10 steps): it now adds what that
game may have run since (5 steps a second at 1x, times the speed, one step more). G.buildLeadState runs through lupa (Lua 5.2)
with the rest of the lead mocked.
Cases: a fresh clock far enough behind: released at once; the same clock 0.3 s old at 4x: held the usual way; a clock fresh but
close: held; MPFEVER_LEADAGE=0: the clock as sent, as before.
Run: python tests/test_leadage.py
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


def runtime(env):
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^G\.buildLeadState = function\(\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        return None
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {} os.getenv = function(k) return ENV[k] end CLOCK = 100 os.clock = function() return CLOCK end")
    for k, v in env.items():
        L.execute(f'ENV.{k} = "{v}"')
    L.execute("""
STEP = 200
NOW = 1000000
G = { buildLead = true, session = { started = true, speed = 4 }, frames = 1000, replayOut = 0, nativeQueue = {}, natWait = {}, peers = {} }
G.leadYields = function() return false end
G.leadDue = function() return nil end
leadLevel = function() return 2 end
gameTime = function() return NOW end
terrainLeadSteps = function() return 20 end
overshootReserve = function() return 9 end
""" + m.group(0))
    return L.eval("function(code) return assert(load(code))() end")


def main():
    run = runtime({})
    check("G.buildLeadState found", run is not None)
    if run is None:
        return 1
    # 15 steps behind (needs 11)
    got = run("G.peers.c = { t = NOW - 15 * STEP, bl = 2, at = CLOCK }; return tostring(G.buildLeadState())")
    check("a fresh clock 15 steps behind: released at once", got == "true", got)
    got = run("G.peers.c = { t = NOW - 15 * STEP, bl = 2, at = CLOCK - 0.3 }; local ok, why = G.buildLeadState(); return tostring(ok) .. ' ' .. tostring(why)")
    check("the same clock 0.3 s old at 4x (6 steps more, one for the frame): held the usual way", got.startswith("false") and "steps behind (needs 11" in got, got)
    got = run("G.peers.c = { t = NOW - 9 * STEP, bl = 2, at = CLOCK }; return tostring(G.buildLeadState())")
    check("a fresh clock only 9 steps behind: held", got == "false", got)
    run = runtime({"MPFEVER_LEADAGE": "0"})
    got = run("G.peers.c = { t = NOW - 15 * STEP, bl = 2, at = CLOCK - 0.3 }; return tostring(G.buildLeadState())")
    check("MPFEVER_LEADAGE=0: the clock as sent, as before (released)", got == "true", got)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
