"""Offline test of the towns' sensitivities to pollution, noise and traffic (0.6.9).

A player (2026-11-02): "on Very Hard my towns have no problem with fog and noise". MPFever set the towns' sensitivity to
pollution, noise and traffic congestion to 0 on every game, because these ratings once came from engine computations that
were not the same on every game. Stress test of 2026-11-02 (em1 shared on Test Knight 14, em2 separate on Test Gameplay with a
computer company, 40 min at x4 each): with the game's sensitivities, 0 desyncs, the ratings (0.72 to 0.97) identical on both
games. neutraliseEmissions is taken from the real bridge file and run through lupa (Lua 5.2). Cases:
  - by default: every town's sensitivities given back to the game's (resetTownRatingSensitivity), none set to 0;
  - MPFEVER_TOWNEMISSIONS=0: pollution, noise and traffic congestion set to 0 for every town, as before;
  - the bridge still calls it at load.
Run: python tests/test_townemissions.py
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
    m = re.search(r"^local function neutraliseEmissions\(\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: neutraliseEmissions not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
SENT = {}
api = { type = { ComponentType = { TOWN = "town" } },
  engine = { forEachEntityWithComponent = function(fn, ct) assert(ct == "town"); for _, t in ipairs({ 11, 12, 13 }) do fn(t) end end } }
O = { event = function(a, b, name, args) return { name = name, args = args } end,
  sendCommand = function(c) SENT[#SENT + 1] = c end }
log = function() end
""" + m.group(0) + "\nRUN = neutraliseEmissions\n")
    run = L.eval("function(code) return assert(load(code))() end")

    run("SENT = {}; RUN()")
    names = run("local t = {}; for _, c in ipairs(SENT) do t[#t + 1] = c.name .. ':' .. c.args.townEntity end; return table.concat(t, ',')")
    check("by default: the game's sensitivities given back to every town",
          names == "resetTownRatingSensitivity:11,resetTownRatingSensitivity:12,resetTownRatingSensitivity:13", names)

    run("ENV.MPFEVER_TOWNEMISSIONS = '0'; SENT = {}; RUN()")
    zero = run("local t = {}; for _, c in ipairs(SENT) do assert(c.name == 'setTownRatingSensitivity' and c.args.sensitivity == 0); t[#t + 1] = c.args.townEntity .. c.args.rating end; return table.concat(t, ',')")
    check("MPFEVER_TOWNEMISSIONS=0: pollution, noise and traffic set to 0 for every town, as before",
          zero == "11pollution,11noise,11traffic_congestion,12pollution,12noise,12traffic_congestion,13pollution,13noise,13traffic_congestion", zero)

    check("the bridge calls it at load", "pcall(neutraliseEmissions)" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
