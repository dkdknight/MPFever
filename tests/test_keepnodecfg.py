"""Offline test of the junction configurations put back on a stop's copy of a street segment (0.6.9, C.keptNodeConfigs).

Stress test of 2026-11-02 on Test Knight 14: a stop put by a script's build (the dstop scenario, and the computer companies' stops)
on a street segment next to a junction with traffic lights removed the junction's configuration without putting it back, as the
stop tool does: the building game asserted (ecs::Engine::GetComponentDataIndex, "it != components.end()", node 58155, component
BaseNodeConfig) and stood with its error window open, every time, with 0.6.7 as well. The computer companies left those streets
out (stopSegments), so they often found no street for a stop.
  - C.keptNodeConfigs moves the old segment's lane connections onto the copy (both ends, the other segments kept), copies the
    rest of the configuration, skips a node with none, takes a node -> id table for a segment split in two;
  - the dstop scenario and the companies' stops put them back (MPFEVER_KEEPNODECFG=0: removed only, as before);
  - the companies no longer leave the streets next to traffic lights out, unless MPFEVER_KEEPNODECFG=0 or MPFEVER_AISTOPLIGHTS=1.
Needs lupa (pip install lupa). Run: python tests/test_keepnodecfg.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read()
m = re.search(r"^function C\.keptNodeConfigs\(.*?^end\n", common, re.S | re.M)
check(m is not None, "C.keptNodeConfigs found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("C = {}\n" + (m.group(0) if m else ""))
L.execute('''
CFG = {
  [58155] = { trafficLightPreference = 2, crosswalks = { 900, 901 }, laneConnections = {
      { segment0 = 44079, lane0 = 1, segment1 = 500, lane1 = 2, withRoad = true },
      { segment0 = 501, lane0 = 0, segment1 = 44079, lane1 = 3, withRoad = true, withTram = true },
      { segment0 = 500, lane0 = 1, segment1 = 501, lane1 = 1, withRoad = true } } },
  [60000] = { laneConnections = { { segment0 = 44079, lane0 = 0, segment1 = 44079, lane1 = 1 } } },
}
GET = function(nd) return CFG[nd] end
''')
out = L.eval("C.keptNodeConfigs({ 58155, 60000, 70000 }, 44079, -1, GET)")
check(len(out) == 2, "one configuration per configured node, none for a node without")
a = out[1]
check(a.entity == 58155, "the node kept")
lc = a.comp.laneConnections
check(lc[1].segment0 == -1 and lc[1].segment1 == 500 and lc[1].lane0 == 1 and lc[1].lane1 == 2, "a connection from the old segment moved onto the copy")
check(lc[2].segment1 == -1 and lc[2].segment0 == 501 and lc[2].withTram is True, "a connection to the old segment moved too (tram kept)")
check(lc[3].segment0 == 500 and lc[3].segment1 == 501, "the other segments' connections kept")
check(a.comp.trafficLightPreference == 2 and a.comp.crosswalks[1] == 900, "the rest of the configuration kept")
check(L.eval("CFG[58155].laneConnections[1].segment0") == 44079, "the read configuration not changed")
b = out[2]
check(b.comp.laneConnections[1].segment0 == -1 and b.comp.laneConnections[1].segment1 == -1, "both ends of a loop moved")
split = L.eval("C.keptNodeConfigs({ 58155, 60000 }, 44079, { [58155] = -4, [60000] = -5 }, GET)")
check(split[1].comp.laneConnections[1].segment0 == -4 and split[2].comp.laneConnections[1].segment0 == -5, "a segment split in two: each end its half")
check(len(L.eval("C.keptNodeConfigs({ 58155 }, 44079, { [1] = -4 }, GET)")) == 0, "no id for the node: nothing put back")

print("the forms tried")
m2 = re.search(r"^function C\.stopWithNodeConfigs\(.*?^end\n", common, re.S | re.M)
m3 = re.search(r"^function C\.nodeConfigs\(.*?^end\n", common, re.S | re.M)
check(m2 is not None and m3 is not None, "C.stopWithNodeConfigs and C.nodeConfigs found")
F = lupa.LuaRuntime(unpack_returned_tuples=True)
F.execute('''
C = {}
local function ud() return setmetatable({}, { __newindex = function(t, k, v) if k == "trafficLightConfig" and type(v) ~= "userdata" and FAKE_UD ~= v then error("not a TrafficLightConfig") end rawset(t, k, v) end }) end
api = { type = { BaseNodeLaneConnectionAndEntity = { new = function() return { comp = ud() } end }, LaneConnection = { new = function() return {} end },
  ComponentType = { BASE_NODE_CONFIG = "cfg" } },
  engine = { getComponent = function(nd, ct) return RAW[nd] end } }
FAKE_UD = { phases = 3 }
RAW = { [58155] = { trafficLightConfig = FAKE_UD, crosswalks = { 900 }, laneConnections = { { segment0 = 44079, lane0 = 1, segment1 = 500, lane1 = 2 } } } }
C.marshal = function(c) return { crosswalks = c.crosswalks, laneConnections = c.laneConnections, trafficLightPreference = 2 } end
''' + m.group(0) + m2.group(0) + m3.group(0))
# (0.6.9 final: the phases never put back, the other games' replays cannot carry them)
cmd, tried = F.eval('C.stopWithNodeConfigs({}, {}, { 58155 }, 44079, function(sp) if sp.streetProposal.nodeConfigsToAdd[1].comp.trafficLightConfig then error("phases") end if #sp.streetProposal.nodeConfigsToAdd[1].comp.crosswalks > 0 then error("Unknown exception") end return "CMD" end)')
check(cmd == "CMD" and tried.startswith("no phases ") and "Unknown exception; neither OK" in tried, "without the phases first, then without the crosswalks too (" + str(tried) + ")")
cmd, tried = F.eval('C.stopWithNodeConfigs({}, {}, { 58155 }, 44079, function(sp) return sp.streetProposal.nodeConfigsToAdd[1].comp.trafficLightConfig == nil and sp.streetProposal.nodeConfigsToAdd[1].comp.laneConnections[1].segment0 == -1 and "CMD" or nil end)')
check(cmd == "CMD" and tried == "no phases OK", "no phases put back, the copy's id in the connections")
cmd, tried = F.eval('C.stopWithNodeConfigs({}, {}, { 58155 }, 44079, function(sp) error("Unknown exception") end)')
check(cmd is None and tried.count("Unknown exception") == 2, "no form taken: nothing (the stop is not built)")
F.execute('os.getenv = function(k) if k == "MPFEVER_STOPTLC" then return "1" end end')
cmd, tried = F.eval('C.stopWithNodeConfigs({}, {}, { 58155 }, 44079, function(sp) return sp.streetProposal.nodeConfigsToAdd[1].comp.trafficLightConfig == FAKE_UD and "CMD" or nil end)')
check(cmd == "CMD" and tried == "full OK", "MPFEVER_STOPTLC=1: the full form first, the engine's phases put as they are")

bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
i = bridge.find("H.dstop = function")
ds = bridge[i:bridge.find("\nend\n", i)]
check("C.stopWithNodeConfigs(sp, ssp, ncr, E," in ds and 'os.getenv("MPFEVER_KEEPNODECFG") ~= "0"' in ds and "stop left out" in ds, "the dstop scenario puts them back (a stop left out when no form is taken)")

ai = open(os.path.join(CONTENT, "mpfever_ai.lua"), encoding="utf-8").read()
i = ai.find("local function buildStop(")
bs = ai[i:ai.find("\nend\n", i)]
check("C.stopWithNodeConfigs(sp, ssp, ncr, seg," in bs and "keepNodeCfg()" in bs and "not built\"); return false end" in bs, "the companies' stops put them back (not built when no form is taken)")
check('local function keepNodeCfg() return os.getenv("MPFEVER_KEEPNODECFG") ~= "0" end' in ai, "MPFEVER_KEEPNODECFG=0 switches it off")
check('if os.getenv("MPFEVER_AISTOPLIGHTS") == "1" or keepNodeCfg() then return segs end' in ai, "the streets next to traffic lights used again")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
