"""Test of #161's experimental fix (0.7.13, mod/mpfever_1/content/mpfever_bridge.script.lua: G.stopLanesChange,
G.nativeStopWanted, H.bridgestopprobe). Off by default: MPFEVER_NATIVESTOPLANES=1 turns it on.

yoyo:24 (yoyo's game, 2026-11-08 16:15Z): a bus stop put with the stop tool on a Roads Plus one-way tram street without
sidewalks. The tool replaced the segment of one 5.5 m lane by a copy with a 5 m platform lane on each side (tests/data/
stop_lanes_yoyo24.lua, from the report). A stop on a street on the ground is replayed by replayStop's script proposal, whose wider
segment the engine laid on the ground again on YkeWoudstra's game: 57.430 / 2062.063 of terrain alignment against the builder's
0 / 0, "TOWN STATS DIFFER", a resynchronisation. With the switch, such a stop goes to the tool's own native proposal
(G.replayNativeStop, as on a bridge). The real functions run through lupa:
  - stopPlan of the real act, then G.stopLanesChange: the lanes changed (3 against 1); the same lanes, or the same the other way
    round (count and summed width): no change; anything that cannot be read: no change;
  - G.nativeStopWanted: the yoyo:24 stop native only with MPFEVER_NATIVESTOPLANES=1; unchanged otherwise (bridges, signals,
    MPFEVER_NATIVESTOP=0, a stop placed again after a street, nothing added or removed);
  - H.bridgestopprobe: MPFEVER_PROBE_NOSIDEWALK=1 picks the street segments on the ground without a sidewalk instead of the
    bridges; MPFEVER_PROBE_LANES=platforms gives the new segment a 5 m platform lane on each side; without them, as before.
Needs lupa. Run: python tests/test_nativestoplanes0713.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
FIXTURE = open(os.path.join(ROOT, "tests", "data", "stop_lanes_yoyo24.lua"), encoding="utf-8").read()
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


def grab(pattern, name):
    m = re.search(pattern, src, re.S | re.M)
    check(m is not None, name + " found")
    return m.group(0) if m else ""


try:
    import lupa.lua52 as lupa
except ImportError:
    print("FAIL lupa is not installed (pip install lupa): this test needs it")
    sys.exit(1)

SP = grab(r"^local function stopPlan\(margs\)\n.*?^end\n", "stopPlan")
SLC = grab(r"^G\.stopLanesChange = function\(plan\)\n.*?^end\n", "G.stopLanesChange")
NSW = grab(r"^G\.nativeStopWanted = function\(a, plan\)\n.*?^end\n", "G.nativeStopWanted")
PROBE = grab(r"^H\.bridgestopprobe = function\(from, p\)\n.*?^end\n", "H.bridgestopprobe")
check('if os.getenv("MPFEVER_NATIVESTOPLANES") == "1" and G.stopLanesChange(plan) then return true end' in NSW,
      "off by default: only MPFEVER_NATIVESTOPLANES=1 turns it on")
i_lanes, i_sig, i_bridge = NSW.find("G.stopLanesChange(plan)"), NSW.find("if plan.segType == 1 then"), NSW.find("local okc, c = pcall(")
check(0 <= i_sig < i_lanes < i_bridge, "after the signals' rule, before the bridges' one")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
function logged(pat) local n = 0 for _, l in ipairs(LOGS) do if l:find(pat, 1, true) then n = n + 1 end end return n end
SEGS, STREET = {}, {}
api = { type = { ComponentType = { BASE_EDGE = "BASE_EDGE", BASE_EDGE_STREET = "BASE_EDGE_STREET" } },
	engine = { getComponent = function(e, ct)
		if ct == "BASE_EDGE" then return SEGS[e] end
		if ct == "BASE_EDGE_STREET" then return STREET[e] end
		return nil
	end } }
G = {}
function copy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = copy(v) end return o end
''')
L.execute(SP.replace("local function stopPlan", "function stopPlan", 1))
L.execute(SLC + NSW)
L.execute("ACT = load([==[" + FIXTURE + "]==])()")
run = L.eval("function(code) local f = assert(load(code)) return f() end")

print("yoyo:24")
L.execute(r'''
function yoyo24(liveLanes, liveType)
	local rm = ACT.proposal.removedSegments[1]
	SEGS = { [rm.entity] = { type = liveType or 0, typeIndex = -1, node0 = rm.comp.node0, node1 = rm.comp.node1, objects = {},
		laneConfigs = liveLanes or copy(rm.comp.laneConfigs) } }
	local plan = stopPlan({ { proposal = copy(ACT.proposal) } })
	return plan, { uid = ACT.uid, args = { { proposal = copy(ACT.proposal) } }, ts = ACT.ts, ctx = ACT.ctx }
end
''')
check(run("local plan = yoyo24(); return plan.E == 368306 and #plan.objs == 1 and plan.segType == 0 and #plan.seg.comp.laneConfigs == 3") is True,
      "the act's stop plan: one stop on segment 368306, the tool's copy with 3 lanes")
check(run("return G.stopLanesChange((yoyo24()))") is True, "its lanes change here: 1 lane of 5.5 m, 3 lanes of 15.5 m in the tool's copy")
check(run("local plan, a = yoyo24(); return G.nativeStopWanted(a, plan)") is False, "by default: replayStop, as before")
check(run('ENV.MPFEVER_NATIVESTOPLANES = "0"; local plan, a = yoyo24(); local r = G.nativeStopWanted(a, plan); ENV = {}; return r') is False,
      "MPFEVER_NATIVESTOPLANES=0: replayStop, as before")
check(run('ENV.MPFEVER_NATIVESTOPLANES = "1"; local plan, a = yoyo24(); local r = G.nativeStopWanted(a, plan); ENV = {}; return r') is True,
      "MPFEVER_NATIVESTOPLANES=1: the tool's own native proposal (G.replayNativeStop)")
check(run('ENV = { MPFEVER_NATIVESTOPLANES = "1", MPFEVER_NATIVESTOP = "0" }; local plan, a = yoyo24(); local r = G.nativeStopWanted(a, plan); ENV = {}; return r') is False,
      "    MPFEVER_NATIVESTOP=0 still wins: replayStop for every stop")

print("no change of lanes")
check(run("local add = ACT.proposal.addedSegments[1].comp.laneConfigs; return G.stopLanesChange((yoyo24(copy(add))))") is False,
      "the same 3 lanes here (yoyo:1, the stop put again on that segment): no change")
check(run('ENV.MPFEVER_NATIVESTOPLANES = "1"; local add = ACT.proposal.addedSegments[1].comp.laneConfigs; local plan, a = yoyo24(copy(add)); local r = G.nativeStopWanted(a, plan); ENV = {}; return r') is False,
      "    so replayStop even with MPFEVER_NATIVESTOPLANES=1, as before")
L.execute(r'''
function asym(liveOrder, newOrder)
	local function lanes(ws) local l = {} for i, w in ipairs(ws) do l[i] = { width = w, forward = true, transportModes = { [0] = false } } end return l end
	local plan = yoyo24(lanes(liveOrder))
	plan.seg.comp.laneConfigs = lanes(newOrder)
	return G.stopLanesChange(plan)
end
''')
check(run("return asym({ 3.5, 5, 2 }, { 2, 5, 3.5 })") is False, "the same lanes, the segment the other way round here: no change")
check(run("return asym({ 3.5, 5, 2 }, { 3.5, 5, 2.5 })") is True, "    one lane wider: a change")
check(run("return asym({ 3.5, 5 }, { 3.5, 5, 0 })") is True, "    one lane more: a change")
check(run("local plan = yoyo24(); SEGS = {}; return G.stopLanesChange(plan)") is False, "the segment not here: no change")
check(run("local plan = yoyo24(); SEGS[368306].laneConfigs = nil; return G.stopLanesChange(plan)") is False, "its lanes unreadable: no change")
check(run("local plan = yoyo24(); plan.seg.comp.laneConfigs[2].width = nil; return G.stopLanesChange(plan)") is False, "a lane of the copy without a width: no change")
check(run("local plan = yoyo24(); plan.seg.comp.laneConfigs = {}; return G.stopLanesChange(plan)") is False, "the copy without lanes: no change")
check(run("return G.stopLanesChange(nil) == false and G.stopLanesChange({ E = 1 }) == false") is True, "no plan, no copy: no change")

print("the other stops, unchanged")
for env in ('{}', '{ MPFEVER_NATIVESTOPLANES = "1" }'):
    tag = "" if env == "{}" else " (MPFEVER_NATIVESTOPLANES=1)"
    check(run(f"ENV = {env}; local plan, a = yoyo24(nil, 1); local r = G.nativeStopWanted(a, plan); ENV = {{}}; return r") is True, "a stop on a bridge: native" + tag)
    check(run(f"ENV = {env}; local plan, a = yoyo24(); plan.segType = 1; local r = G.nativeStopWanted(a, plan); ENV = {{}}; return r") is True, "a signal: native" + tag)
    check(run(f"ENV = {env}; local plan, a = yoyo24(); plan.after = true; local r = G.nativeStopWanted(a, plan); ENV = {{}}; return r") is False,
          "a stop placed again after a street: replayStop" + tag)
    check(run(f"ENV = {env}; local plan, a = yoyo24(); plan.objs = {{}}; local r = G.nativeStopWanted(a, plan); ENV = {{}}; return r") is False,
          "nothing added or removed: replayStop" + tag)
    check(run(f"ENV = {env}; local plan, a = yoyo24(); a.args = nil; local r = G.nativeStopWanted(a, plan); ENV = {{}}; return r") is False,
          "no act's proposal: replayStop" + tag)

print("H.bridgestopprobe")
L.execute(r'''
C = { ROLE = "host", marshal = function(x) return copy(x) end }
AUTO = {}
R = { allEdges = function() return { 10, 11, 12, 13 } end, ownerOf = function() return -1 end }
function nodePosition(n) return { x = n, y = 0, z = 0 } end
function shortErr(e) return tostring(e) end
function autoFinish() FINISHED = true end
PLANS = {}
function replayStop(a, plan) PLANS[#PLANS + 1] = plan end
api.engine.system = { streetConnectorSystem = { getConstructionEntityForEdge = function() return -1 end } }
function lane(w, ped) return { width = w, forward = true, offset = 0, speed = 10, height = ped and 0.1 or 0, transportModes = { [0] = ped, [5] = not ped } } end
function probe(env)
	ENV, PLANS, LOGS, FINISHED = env, {}, {}, nil
	G.waits, G.frames = {}, 0
	AUTO = {}
	-- 10: a one-way tram street without sidewalks; 11: a street with sidewalks; 12: a street bridge; 13: a track
	SEGS = {
		[10] = { type = 0, typeIndex = -1, node0 = 1, node1 = 2, roadTemplate = "a/tram_new_electrified_one_way.street_template", objects = {}, laneConfigs = { lane(5.5, false) } },
		[11] = { type = 0, typeIndex = -1, node0 = 2, node1 = 3, roadTemplate = "a/town_new_medium.street_template", objects = {}, laneConfigs = { lane(3, true), lane(5, false), lane(3, true) } },
		[12] = { type = 1, typeIndex = 0, node0 = 3, node1 = 4, roadTemplate = "a/town_new_medium.street_template", objects = {}, laneConfigs = { lane(3, true), lane(5, false), lane(3, true) } },
		[13] = { type = 0, typeIndex = -1, node0 = 5, node1 = 6, roadTemplate = "a/standard.track", objects = {}, laneConfigs = { lane(4, false) } } }
	STREET = { [10] = {}, [11] = {}, [12] = {} }
	H.bridgestopprobe(nil, { role = "host" })
	local out = {}
	for _, p in ipairs(PLANS) do
		local w = {}
		for _, l in ipairs(p.seg.comp.laneConfigs or {}) do w[#w + 1] = tostring(l.width) .. (l.transportModes[0] and "p" or "") end
		out[#out + 1] = p.E .. ":" .. table.concat(w, "/")
	end
	ENV = {}
	return table.concat(out, ",")
end
''')
L.execute("H = {}\n" + PROBE)
got = run("return probe({})")
check(got == "12:", "without the switches: the bridge segment, the copy's lanes left to the segment's own (as before)", got)
check(run('return logged("1 bridge or tunnel street segment(s), 1 at an end") == 1') is True, "    said as before")
got = run('return probe({ MPFEVER_PROBE_NOSIDEWALK = "1" })')
check(got == "10:", "MPFEVER_PROBE_NOSIDEWALK=1: the street on the ground without a sidewalk only", got)
check(run('return logged("1 street segment(s) without a sidewalk") == 1') is True, "    said")
got = run('return probe({ MPFEVER_PROBE_NOSIDEWALK = "1", MPFEVER_PROBE_LANES = "platforms" })')
check(got == "10:5p/5.5/5p", "MPFEVER_PROBE_LANES=platforms: a 5 m platform lane on each side, as the stop tool gave yoyo:24", got)
check(run('return PLANS[1].seg.comp.laneConfigs[1].height == 0.1 and PLANS[1].seg.comp.laneConfigs[2].transportModes[5] == true and PLANS[1].probeOnly == true') is True,
      "    platforms 0.1 m high, the segment's own lane kept between them, nothing built")
check(run('return logged("lanes change true") == 1') is True, "    the probe says the switch would replay it natively")
got = run('return probe({ MPFEVER_PROBE_LANES = "platforms" })')
check(got == "12:5p/3p/5/3p/5p", "    on a bridge too, when asked", got)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
