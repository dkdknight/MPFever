"""Offline test (0.8.16, Discord: yöyö "can't change any traffic lights phase"): a junction's traffic light phases a player
changed are rebuilt from the shipped copy.

The junction window's change (the game's createTrafficLightProposal: the node's configuration with its new phases and
userModifiedTrafficLightStates) was shipped whole, but C.nodeConfigs rebuilt the node configurations with their lanes,
crosswalks and preference only: every game, the player's own too, built the junction with its phases as they were (autotest
tlphase: 27.09 s asked to 37, still 27.09 on both games, the action "OK"). Now, through lupa with a mocked api.type:
  - phases marked as changed by a player are rebuilt (type, every phase's locked lanes, duration, minimum, can skip) and the
    flag kept;
  - phases nobody changed (userModifiedTrafficLightStates false): left out as before (every other street replay unchanged);
  - the engine's own object (m.tlc, C.keptNodeConfigs) still comes first; MPFEVER_TLCSHIP=0: left out as before.
Needs lupa. Run: python tests/test_tlcship0816.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m = re.search(r"^function C\.nodeConfigs\(list\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "C.nodeConfigs found")
if not m:
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
C = {}
local function rec() return {} end
api = { type = {
  BaseNodeLaneConnectionAndEntity = { new = function() return { comp = { trafficLightConfig = "default" } } end },
  LaneConnection = { new = rec }, TrafficLightConfig = { new = function() return { kind = "tlc" } end },
  TrafficLightState = { new = function() return { kind = "state" } end } } }
""" + m.group(0))
run = L.eval("function(code) return assert(load(code))() end")
shipped = """{ { entity = 5780, comp = { laneConnections = {}, crosswalks = {}, trafficLightPreference = 0, userModifiedTrafficLightStates = %s,
  trafficLightConfig = { trafficLightType = -1, states = { { canSkip = true, duration = 37, minDuration = 1.5, lockedLanes = { 8, 9 } },
  { canSkip = false, duration = 6, minDuration = 1.5, lockedLanes = { 0 } } } } } } }"""
run("R = C.nodeConfigs(%s)" % (shipped % "true"))
check(run("return R[1].comp.trafficLightConfig.kind") == "tlc", "phases changed by a player: rebuilt")
check(run("return R[1].comp.trafficLightConfig.states[1].duration") == 37 and run("return R[1].comp.trafficLightConfig.states[2].duration") == 6,
      "  every phase's duration")
check(run("return table.concat(R[1].comp.trafficLightConfig.states[1].lockedLanes, ',')") == "8,9", "  its locked lanes")
check(run("return R[1].comp.trafficLightConfig.states[1].canSkip") is True and run("return R[1].comp.trafficLightConfig.states[2].canSkip") is False
      and run("return R[1].comp.trafficLightConfig.states[1].minDuration") == 1.5, "  can skip, minimum")
check(run("return R[1].comp.trafficLightConfig.trafficLightType") == -1, "  its type")
check(run("return R[1].comp.userModifiedTrafficLightStates") is True, "  the flag kept")
run("R = C.nodeConfigs(%s)" % (shipped % "false"))
check(run("return R[1].comp.trafficLightConfig") == "default", "phases nobody changed: left out as before")
run("R = C.nodeConfigs(%s)" % (shipped % "true").replace("entity = 5780,", "entity = 5780, tlc = 'engine',"))
check(run("return R[1].comp.trafficLightConfig") == "engine", "the engine's own object (C.keptNodeConfigs) first")
run('ENV.MPFEVER_TLCSHIP = "0"')
run("R = C.nodeConfigs(%s)" % (shipped % "true"))
check(run("return R[1].comp.trafficLightConfig") == "default", "MPFEVER_TLCSHIP=0: left out as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
