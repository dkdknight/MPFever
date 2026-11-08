"""Offline test: the signals and stops a script builds are rebuilt on every game (0.7.7, C.scriptEdgeObjects and
C.rebuildProposal in mpfever_common.lua).

Since 0.7.1 a game script's interface commands are shipped as actions and every game, the builder's too, rebuilds them in the
script forms. A script's street proposal names an edge object's new segment by edgeEntity (its rank in edgesToAdd) and gives
its kind only through the placeholder it puts in that segment's objects (-400000000 - rank, SIGNAL 2, STOP_LEFT 0, STOP_RIGHT
1). The rebuild read the tool's form (segmentEntity, category) and set edgeEntity = nil: "The lua object can't be cast to
desired type" in all 10 forms, on every game. Auto Signals' extra signals (the user's PC, 2026-11-08 01:39, Knight-HD#2:135),
YkeWoudstra's in #133, the stops of a script tool (#127, torol#1:8), Advanced Station Builder's and Advanced Track Patterns'
signals, Bus Loops: never built in a session.
  - the real acts, rebuilt through lupa with a strict mock of SimpleStreetProposal.EdgeObject (the binding's error for a value
    of the wrong type): every form rebuilds;
  - each new segment lists the script's placeholder once with the script's own kind (signals 2, the stops' sides 0 and 1),
    the raw forms too (they keep the script's own: not given twice);
  - each signal keeps its segment, param, side, one way, model and its params (the mod's settings);
  - the form "full" keeps the segments' distance;
  - MPFEVER_SCRIPTEO=0: the old failure again;
  - a native tool's signal (Knight-HD#2:136 the same evening) rebuilds exactly as before, switch on or off.
Needs lupa (pip install lupa). Run: python tests/test_scripteo077.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
common = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
CAST = "The lua object can't be cast to desired type"
local function strict(fields)
  local data = {}
  return setmetatable({}, {
    __index = function(_, k) return data[k] end,
    __newindex = function(_, k, v)
      local ft = fields[k]
      if ft ~= nil and type(v) ~= ft then error(CAST, 0) end
      data[k] = v
    end,
    __pairs = function() return pairs(data) end,
  }), data
end
EO_DATA = {}
local function vec(x, y, z) return { x = x, y = y, z = z } end
api = {
  type = {
    SimpleProposal = { new = function() return { streetProposal = {}, constructionsToAdd = {}, constructionsToRemove = {}, old2new = {} } end,
      ConstructionEntity = { new = function() return {} end } },
    SegmentAndEntity = { new = function() return { entity = 0, type = 0, comp = { objects = {}, laneConfigs = {} }, streetEdge = {}, playerOwned = {} } end },
    NodeAndEntity = { new = function() return { entity = 0, comp = {} } end },
    BaseEdge = { new = function() return { objects = {}, laneConfigs = {} } end },
    BaseEdgeStreet = { new = function() return {} end },
    BaseNode = { new = function() return {} end },
    PlayerOwned = { new = function() return {} end },
    Context = { new = function() return {} end },
    LaneConfig = { new = function() return { transportModes = {} } end },
    Vec3f = { new = vec }, Vec2f = { new = function(x, y) return { x = x, y = y } end },
    Vec4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end },
    SimpleStreetProposal = { EdgeObject = { new = function()
      local o, d = strict({ edgeEntity = "number", param = "number", oneWay = "boolean", left = "boolean", model = "string",
        playerEntity = "number", name = "string" })
      EO_DATA[#EO_DATA + 1] = d
      return o
    end } },
    BaseNodeLaneConnectionAndEntity = { new = function() return { comp = {} } end },
    LaneConnection = { new = function() return {} end },
    ComponentType = { BASE_EDGE = 1, BASE_NODE_CONFIG = 2, BASE_NODE = 3 },
  },
  engine = { getComponent = function() return nil end, util = { getPlayer = function() return 89247 end } },
  res = { streetTemplateRep = { find = function() return 1 end,
    get = function() return { laneConfigs = { { speed = 27.7, width = 4, height = 0.53, forward = true, offset = 0, transportModes = {} } } } end } },
}
TRIES = {
  { v = "full" }, { v = "minimal" }, { v = "minimalNoOwner" }, { v = "bare" },
  { v = "full", ie = true, pi = false }, { v = "minimal", ie = true, pi = false },
  { v = "minimalNoOwner", ie = true, pi = false }, { v = "bare", ie = true, pi = false },
  { v = "full", raw = true }, { v = "minimal", raw = true, ie = true, pi = false },
}
function label(t) return t.v .. (t.raw and "/raw" or "") .. (t.ie ~= nil and "/ie" or "") end
-- every form of an act: "<form>: OK <segments> | <edge objects>" or "<form>: rebuild <error>", one line each
function runAll(src)
  local out = {}
  for _, t in ipairs(TRIES) do
    EO_DATA = {}
    local margs = C.deser(src)
    local ok, args = pcall(C.rebuildArgs, "makeWorldBuildProposalCmd", margs, { seed = 7919, variant = t.v, raw = t.raw })
    if not ok then
      out[#out + 1] = label(t) .. ": rebuild " .. tostring(args)
    else
      local ssp = args[1].streetProposal
      local parts = {}
      for i, e in ipairs(ssp.edgesToAdd or {}) do
        local ob = {}
        for _, p in ipairs(e.comp.objects or {}) do ob[#ob + 1] = tostring(p[1]) .. ":" .. tostring(p[2]) end
        parts[#parts + 1] = "e" .. tostring(e.entity) .. "{" .. table.concat(ob, ",") .. "}d=" .. tostring(e.comp.distance)
      end
      local eos = {}
      for i, d in ipairs(EO_DATA) do
        local pk = {}
        for k, v in pairs(d.params or {}) do pk[#pk + 1] = k .. "=" .. tostring(v) end
        table.sort(pk)
        eos[#eos + 1] = string.format("eo%d(edge=%s p=%.3f left=%s oneWay=%s model=%s params{%s})", i, tostring(d.edgeEntity), d.param or -1,
          tostring(d.left), tostring(d.oneWay), tostring(d.model), table.concat(pk, ","))
      end
      out[#out + 1] = label(t) .. ": OK edges " .. table.concat(parts, " ") .. " | " .. table.concat(eos, " ")
    end
  end
  return table.concat(out, "\n")
end
function loadAct(payload) A = C.deser(payload); return C.ser(A.args) end
'''

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(MOCK)
L.execute("C = (function() " + common + " end)()")


def act(name):
    line = open(os.path.join(HERE, "data", name), encoding="utf-8", errors="replace").read().strip().split("\n")[0]
    return L.eval("loadAct")(line.split("\t", 2)[2])


def run(src, env=None):
    L.execute("ENV = {}")
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    return L.eval("runAll")(src).split("\n")


print("Auto Signals' five signals (the user's PC, 2026-11-08 01:39)")
auto = act("scripteo_autosignals.txt")
lines = run(auto)
check(len(lines) == 10 and all(": OK " in l for l in lines), "every form rebuilds (" + str(sum(": OK " in l for l in lines)) + "/10)")
full = lines[0]
check(all(("e-%d{-%d:2}" % (i, 400000000 + i - 1)) in full for i in range(1, 6)),
      "  the form full: each new segment carries its signal's placeholder, kind 2, once")
raw = lines[8]
check(all(raw.count("-%d:2" % (400000000 + i - 1)) == 1 for i in range(1, 6)), "  the raw form: the script's own placeholders, not given twice")
check(all(("eo%d(edge=-%d " % (i, i)) in full for i in range(1, 6)), "  each signal on its own new segment")
check("left=false oneWay=true model=infrastructure/signal/signal_path_a.con" in full, "  its side, one way and model")
check("auto_signals_enabled=1" in full and "auto_signals_spacing=19" in full and "year=1933" in full, "  and the mod's settings in its params")
check("}d=5" in full, "  the form full keeps the segments' distance (5)")
old = run(auto, {"MPFEVER_SCRIPTEO": "0"})
check(all("rebuild The lua object can't be cast to desired type" in l for l in old), "MPFEVER_SCRIPTEO=0: the old failure in every form, as before")

print("a script tool's stops (#127, torol#1:8)")
stops = run(act("scripteo_scriptstops.txt"))
check(all(": OK " in l for l in stops), "every form rebuilds (" + str(sum(": OK " in l for l in stops)) + "/10)")
check(":0" in stops[0] and ":1" in stops[0] and ":2" not in stops[0].split(" | ")[0], "  the stops keep their sides (kinds 0 and 1), no signal kind")

print("a native tool's signal (Knight-HD#2:136): unchanged")
nat = act("scripteo_native_signal.txt")
on, off = run(nat), run(nat, {"MPFEVER_SCRIPTEO": "0"})
check(on == off, "the same rebuild in every form, switch on or off")
check(sum(": OK " in l for l in on) >= 1, "  and it rebuilds (" + str(sum(": OK " in l for l in on)) + "/10 forms)")

i = common.find("function C.rebuildProposal(m, opts)")
body = common[i:common.find("\nlocal function segmentFrom", i)]
check(body.find("C.scriptEdgeObjects(st)") < body.find("if not opts.raw then nodeMap, edgeMap = C.renumberStreet(st) end"),
      "taken over before the form renumbers the segments")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
