"""Offline test of the mods' game script updates called with the steps only (0.7.0).

The engine calls the game scripts' update once per step with dt 0.2, and with dt 0 in a batch of no step (a game standing
at a stop point, a pause): how many of those calls a game makes depends on its frames. A mod that works at every call
(Cargo & Passenger Station Range rebuilds two stations per call during an "apply to all") did more of its work on one game
than on another. In a session a mod's update is now called with the steps only; the game's own scripts are left alone.

DET.wrapModEvents is taken from the real bridge file and run through lupa (Lua 5.2) with a mocked `game` table. Cases: a
mod's update with dt 0 is skipped in a session and runs with dt 0.2; alone (no session) it runs as before; the game's own
script ("::/...") is not wrapped; MPFEVER_MODDT0=1: every call, as before; the mod's events are still watched.
Run: python tests/test_moddt0.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
function gameTime() return 1000 end
C = { ACTIVE = true, ROLE = "host" }
SIM = {}
DET = {}
function fresh()
  CALLS = { mod = 0, base = 0 }
  game = {
    ["station_range_1::/live_range.script"] = { update = function(u, st, dt) CALLS.mod = CALLS.mod + 1 end,
      handleEvent = function() end },
    ["::/game_mechanics/towns/towns.script"] = { update = function(u, st, dt) CALLS.base = CALLS.base + 1 end },
  }
end
function run(dts)
  for _, dt in ipairs(dts) do
    for _, v in pairs(game) do v.update(nil, nil, dt) end
  end
  return CALLS.mod .. "/" .. CALLS.base
end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^function DET\.wrapModEvents\(\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: DET.wrapModEvents not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0))
    ev = L.eval("function(code) local f = assert(load(code)) return f() end")
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    got = ev("ENV = {}; C.ROLE = 'host'; fresh(); DET.wrapModEvents(); return run({ 0, 0, 0.2, 0, 0.2 })")
    check("in a session: the mod's update runs at the 2 steps only, the game's own at all 5 calls", got == "2/5", got)
    check("the mod's events are still watched", ev("return game['station_range_1::/live_range.script'].__mpfEv") is True)
    got = ev("ENV = {}; C.ROLE = 'client'; fresh(); DET.wrapModEvents(); return run({ 0, 0.2 })")
    check("on a client too", got == "1/2", got)
    got = ev("ENV = {}; C.ROLE = 'solo'; fresh(); DET.wrapModEvents(); return run({ 0, 0, 0.2 })")
    check("alone: every call, as always", got == "3/3", got)
    got = ev("ENV = { MPFEVER_MODDT0 = '1' }; C.ROLE = 'host'; fresh(); DET.wrapModEvents(); return run({ 0, 0, 0.2 })")
    check("MPFEVER_MODDT0=1: every call, as before", got == "3/3", got)
    got = ev("ENV = {}; C.ROLE = 'host'; fresh(); DET.wrapModEvents(); DET.wrapModEvents(); return run({ 0, 0.2 })")
    check("wrapped once (the bridge calls it again every 50 updates)", got == "1/2", got)

    print("PASS" if not fails else f"FAIL ({len(fails)})")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
