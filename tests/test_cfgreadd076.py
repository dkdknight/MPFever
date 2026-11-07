"""Offline test: a script form of a build gives back the node configurations the tool gave (0.7.6, issue #131,
C.readdedConfigs and C.rebuildProposal in mpfever_common.lua).

Issue #131 (juliu, host, 0.7.4, 2026-11-07 19:09): a tram tunnel's type changed from its window during a pause. The window's
build (createBridgeOrTunnelProposal) replaced its 2 segments, removed the configurations of their 3 nodes and gave them again.
Held in the pause, it was rebuilt in the script form "full", which kept the removals and gave nothing back: node 35603, the
traffic-light junction at the tunnel's end, was left without a configuration and the host's game crashed at once
("it != components.end()", BaseNodeConfig, Entity 35603).
  - C.readdedConfigs (run here through lupa on the real build, tests/data/issue131_tunnel.lua): the configurations of the nodes
    whose configuration is removed are given again, the new segments numbered as the form numbers them (C.renumberStreet: a
    tool numbers nodes, segments and objects in one sequence), the existing segments as they are; none for a node the build
    removes, a new node, a node whose configuration stays; one naming a new segment the form does not have is left (counted);
  - C.nodeConfigs makes them (the junction's traffic lights preference, crosswalks, lane connections kept);
  - C.rebuildProposal gives them in the other forms when it removes configurations, MPFEVER_CFGREADD=0: none, as before;
  - the autotest scenario cfgjunction (bridge) sends such a build, from the game's own replaceSegment, as a window does.
Needs lupa (pip install lupa). Run: python tests/test_cfgreadd076.py
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


common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fns = {}
for name in ("readdedConfigs", "renumberStreet", "nodeConfigs"):
    m = re.search(r"^function C\." + name + r"\(.*?^end\n", common, re.S | re.M)
    check(m is not None, "C." + name + " found")
    if not m:
        sys.exit(1)
    fns[name] = m.group(0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
C = {}
api = { type = { BaseNodeLaneConnectionAndEntity = { new = function() return { comp = {} } end },
  LaneConnection = { new = function() return {} end } } }
''' + fns["readdedConfigs"] + fns["renumberStreet"] + fns["nodeConfigs"])
data = open(os.path.join(HERE, "data", "issue131_tunnel.lua"), encoding="utf-8").read()
L.execute("D = (function() " + data + " end)()")
L.execute('''
function cfgOf(list, e) for _, c in ipairs(list) do if c.entity == e then return c end end end
function segs(c) local o = {} for _, l in ipairs(c.comp.laneConnections) do o[#o + 1] = l.segment0 .. ">" .. l.segment1 end return table.concat(o, ",") end
''')

print("issue #131: the tunnel window's build")
L.execute('''
ST = { edgesToAdd = {}, nodeConfigsToAdd = D.nodeConfigsToAdd }
for i, s in ipairs(D.addedSegments) do ST.edgesToAdd[i] = { entity = s.entity, comp = { node0 = s.node0, node1 = s.node1 } } end
NM, EM = C.renumberStreet(ST)
PUT, LEFT = C.readdedConfigs(D.nodeConfigsToAdd, { 35565, 35436, 35603 }, EM, {})
''')
check(L.eval("#PUT") == 3 and L.eval("LEFT") == 0, "the 3 nodes whose configuration the form removes get theirs again")
j = L.eval("cfgOf(PUT, 35603)")
check(j is not None, "  the traffic-light junction 35603 among them (the node of the crash)")
check(j is not None and j.comp.trafficLightPreference == 2 and j.comp.crosswalks[1] == 45602 and j.comp.crosswalks[2] == 35549,
      "  its traffic lights preference and crosswalks kept")
check(j is not None and "45602>-2" in L.eval("segs(cfgOf(PUT, 35603))") and "45602>35549" in L.eval("segs(cfgOf(PUT, 35603))"),
      "  its lane connections: to the new segment -2 and between the junction's other streets")
check(L.eval("segs(cfgOf(PUT, 35436))") == "-1>-2,-2>-1", "the node between the two new segments: -1 and -2")
check(L.eval("D.nodeConfigsToAdd[1].comp.laneConnections[1].segment1") == -1 and L.eval("PUT[1] ~= D.nodeConfigsToAdd[1]"),
      "copies: the build's own list not changed")
L.execute("MADE = C.nodeConfigs(PUT)")
mj = L.eval("(function() for _, o in ipairs(MADE) do if o.entity == 35603 then return o end end end)()")
check(L.eval("#MADE") == 3 and mj is not None and mj.comp.trafficLightPreference == 2 and len(list(mj.comp.laneConnections.values())) == 8,
      "C.nodeConfigs makes them (the junction's 8 lane connections)")

print("the form's own numbers")
L.execute('''
ST2 = { nodesToAdd = { { entity = -1 } }, edgesToAdd = { { entity = -3, comp = { node0 = 10, node1 = -1 } }, { entity = -7, comp = { node0 = -1, node1 = 20 } } } }
NM2, EM2 = C.renumberStreet(ST2)
LIST2 = {
  { entity = 10, comp = { laneConnections = { { segment0 = 500, lane0 = 0, segment1 = -3, lane1 = 1 } } } },
  { entity = 20, comp = { laneConnections = { { segment0 = -7, lane0 = 0, segment1 = 501, lane1 = 1 } } } },
  { entity = -1, comp = { laneConnections = { { segment0 = -3, lane0 = 0, segment1 = -7, lane1 = 0 } } } },
  { entity = 30, comp = { laneConnections = { { segment0 = 600, lane0 = 0, segment1 = 601, lane1 = 0 } } } },
  { entity = 40, comp = { laneConnections = { { segment0 = -9, lane0 = 0, segment1 = 700, lane1 = 0 } } } },
  { entity = 50, comp = { laneConnections = {} } },
}
PUT2, LEFT2 = C.readdedConfigs(LIST2, { 10, 20, 40, 50 }, EM2, { [50] = true })
''')
check(L.eval("segs(cfgOf(PUT2, 10))") == "500>-1" and L.eval("segs(cfgOf(PUT2, 20))") == "-2>501",
      "a tool's numbers (-3, -7: one sequence with its nodes) become the form's (-1, -2)")
check(L.eval("cfgOf(PUT2, -1)") is None, "a new node: none (it had no configuration to remove)")
check(L.eval("cfgOf(PUT2, 30)") is None, "a node whose configuration stays: none")
check(L.eval("cfgOf(PUT2, 40)") is None and L.eval("LEFT2") == 1, "one naming a new segment the form does not have: left, counted")
check(L.eval("cfgOf(PUT2, 50)") is None, "a node the build removes: none")
check(L.eval("(function() local p, l = C.readdedConfigs(nil, nil, nil, nil) return #p + l end)()") == 0, "nothing given: nothing")

print("the rebuild")
i = common.find("function C.rebuildProposal(m, opts)")
body = common[i:common.find("\nlocal function segmentFrom", i)]
check("local nodeMap, edgeMap = {}, {}" in body and "if not opts.raw then nodeMap, edgeMap = C.renumberStreet(st) end" in body,
      "the form keeps the numbers it gave its new segments")
a = body.find("if (opts.raw or onlyConfigs) and #(st.nodeConfigsToAdd or {}) > 0 then")
b = body.find('elseif not onlyConfigs and #cfgKeep > 0 and #(st.nodeConfigsToAdd or {}) > 0 and os.getenv("MPFEVER_CFGREADD") ~= "0" then')
c = body.find("local put, left = C.readdedConfigs(st.nodeConfigsToAdd, cfgKeep, edgeMap, gone)")
d = body.find("ssp.nodeConfigsToAdd = C.nodeConfigs(put)")
check(0 < a < b < c < d, "the other forms give them when they remove configurations (MPFEVER_CFGREADD=0: none, as before)")
check(body.find("cfgKeep = keep") < b, "  after the list of the configurations removed here")

bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
k = bridge.find("H.cfgjunction = function(from, p)")
sc = bridge[k:k + 3000]
check(k > 0 and "api.engine.util.proposal.replaceSegment(s)" in sc and 'uiRequest("makeWorldBuildProposalCmd"' in sc
      and "BASE_NODE_TRAFFIC_LIGHT" in sc, "the autotest scenario cfgjunction: the game's own build beside a junction with traffic lights")
check(bridge.find("local function uiRequest(fn, margs)") < k, "  (uiRequest defined before it)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
