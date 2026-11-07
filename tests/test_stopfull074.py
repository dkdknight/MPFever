"""0.7.4: every stop of a line lists every cargo type (load, maxLoad), as the game's line window makes a stop.

The engine crashed on every game when an auction sold a computer company's freight line (au1 to au6, 2026-11-07). The cause,
found with an in-game probe (stage "fown": the line, then its vehicles, given to another company, nothing else): the line's
unloading stop had empty load / maxLoad lists (the AI made it from api.type.Line.Stop.new()), and when the engine computes a
line again after its owner changed it reads, at every stop, the maxLoad of each cargo the line loads: past the end of the empty
list (crash in line_util code at 0x25c2451, a null pointer + 4 x 33, 33 = bricks). With the stops' lists filled first by a line
update (stage "fixown"), the same owner change ran on. The game itself makes every stop with every cargo type (gui
line_vehicle_mgmt/line_util.tl makeNewStop: load false, maxLoad 1, the passengers loaded at a passenger station).

Checks, with the real Lua code run on a fake engine:
  - mpfever_ai.lua M.fullStop: an empty stop gets 37 entries (load false, maxLoad 1); a bus stop that listed nothing loads the
    passengers; a full stop is left alone; a partial one keeps what it had; MPFEVER_AISTOPFULL=0 leaves everything as before;
  - the AI uses it on every new stop (bus lines, freight lines, their unloading stop too) and fills its old lines (M.fixStops);
  - mpfever_eco.lua E.fullLineStops: a line with a short stop is updated (makeLineUpdateCmd) with full lists, a full line is not,
    a freight line's empty stop loads nothing, a bus line's empty stop the passengers; MPFEVER_LINEFIX=0: nothing;
  - setOwner (every owner change: auction, sale between companies, merger, heir) fills a line's stops before its owner changes.
Run: python tests/test_stopfull074.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
ai = open(os.path.join(C, "mpfever_ai.lua"), encoding="utf-8").read()
eco = open(os.path.join(C, "mpfever_eco.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


L = lua52.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
local realGetenv = os.getenv
os.getenv = function(k) if ENV[k] ~= nil then return ENV[k] end return realGetenv(k) end
CARGOS = {}
for i = 0, 36 do CARGOS[i] = { name = "cargo" .. i } end
FAKE_E = { api = { res = { cargoTypeRep = { getAll = function() return CARGOS end, getPassengerCargoTypeId = function() return 0 end } } } }
function count(t) local n = 0; for _ in ipairs(t or {}) do n = n + 1 end; return n end
function trues(t) local o = {}; for k, v in ipairs(t or {}) do if v == true then o[#o + 1] = k end end; return table.concat(o, ",") end
''')

# ---------------------------------------------------------------- the AI's stops
a0 = ai.index("M.cargoCount = function(E)")
a1 = ai.index("-- (0.7.4) the lines a computer company made before")
M = L.execute("local M = {}\n" + ai[a0:a1] + "\nreturn M")
run = L.eval("function(M, src) return load(src)(M) end")
res = L.execute('''
local M = ...
local E = FAKE_E
local out = {}
local s = { stopConfig = { load = {}, maxLoad = {} } }
out.changed1 = M.fullStop(E, s, false)
out.n1, out.m1, out.t1 = count(s.stopConfig.load), count(s.stopConfig.maxLoad), trues(s.stopConfig.load)
out.max1 = s.stopConfig.maxLoad[37]
out.ud1 = s.stopConfig.__ud
local b = {}
out.changed2 = M.fullStop(E, b, true)
out.t2, out.n2 = trues(b.stopConfig.load), count(b.stopConfig.load)
local full = { stopConfig = { load = {}, maxLoad = {} } }
for k = 1, 37 do full.stopConfig.load[k] = (k == 34); full.stopConfig.maxLoad[k] = 0.5 end
local before = full.stopConfig
out.changed3 = M.fullStop(E, full, true)
out.same3 = full.stopConfig == before
local p = { stopConfig = { load = {}, maxLoad = {} } }
for k = 1, 10 do p.stopConfig.load[k] = (k == 5); p.stopConfig.maxLoad[k] = 0.25 end
out.changed4 = M.fullStop(E, p, true)
out.t4, out.n4, out.m4a, out.m4b = trues(p.stopConfig.load), count(p.stopConfig.load), p.stopConfig.maxLoad[3], p.stopConfig.maxLoad[20]
ENV.MPFEVER_AISTOPFULL = "0"
local o = { stopConfig = { load = {}, maxLoad = {} } }
out.changed5 = M.fullStop(E, o, false)
out.n5 = count(o.stopConfig.load)
ENV.MPFEVER_AISTOPFULL = nil
return out
''', M)
check(res.changed1 is True and res.n1 == 37 and res.m1 == 37 and res.t1 == "" and res.max1 == 1 and res.ud1 is True,
      "an empty (unloading) stop: 37 cargo types, none loaded, maxLoad 1")
check(res.changed2 is True and res.n2 == 37 and res.t2 == "1", "a bus stop that listed nothing: the passengers (cargo 0) loaded")
check(res.changed3 is False and res.same3 is True, "a full stop is left alone")
check(res.changed4 is True and res.n4 == 37 and res.t4 == "5" and res.m4a == 0.25 and res.m4b == 1, "a partial stop keeps its own settings, the rest added")
check(res.changed5 is False and res.n5 == 0, "MPFEVER_AISTOPFULL=0: as before")

fs = ai[ai.index("local function freightStop(E, road, stop0, loadCargo)"):ai.index("local function createFreightLine(E, co, f, extra)")]
check("M.fullStop(E, s, false)" in fs, "every freight stop goes through it (the unloading stop too)")
cl = ai[ai.index("local function createLine(E, co, groups, town, name)"):]
cl = cl[:cl.index('act(E, co.id, "makeLineCreateCmd"')]
check("M.fullStop(E, s, true)" in cl, "every bus stop goes through it")
tick = ai[ai.index("function M.tick(E, st)"):]
check("pcall(M.fixStops, E, known, act)" in tick and tick.index("M.fixStops") < tick.index("step(E)"),
      "the AI fills its lines made before (one line update per look)")
fx = ai[a1:ai.index("local function createLine(E, co, groups, town, name)")]
check('act(E, co.id, "makeLineUpdateCmd", { n = 2, [1] = l, [2] = m })' in fx and "A.stopsFixed[l] = true" in fx,
      "M.fixStops: a line update shipped as its other actions, once per line")

# ---------------------------------------------------------------- the owner change
e0 = eco.index("function E.fullLineStops(l)")
e1 = eco.index("local function setOwner(list, from, to)")
E = L.execute(r'''
local src = ...
SENT = {}
LINEC = {}
api = {
  res = { cargoTypeRep = { getAll = function() return CARGOS end, getPassengerCargoTypeId = function() return 0 end } },
  type = { ComponentType = { LINE = "LINE" },
           Line = { new = function(lc)
                      local c = { stops = {} }
                      for i, s in ipairs(lc.stops) do
                        local cfg = { load = {}, maxLoad = {}, forceUnload = s.stopConfig.forceUnload, destroyForConfigChange = s.stopConfig.destroyForConfigChange, destroyForRefresh = s.stopConfig.destroyForRefresh }
                        for k, v in ipairs(s.stopConfig.load) do cfg.load[k] = v end
                        for k, v in ipairs(s.stopConfig.maxLoad) do cfg.maxLoad[k] = v end
                        c.stops[i] = { stationGroup = s.stationGroup, stopConfig = cfg }
                      end
                      return c
                    end,
                    StopConfig = { new = function() return { load = {}, maxLoad = {} } end } } },
  engine = { getComponent = function(e, t) return LINEC[e] end },
  cmd = { makeLineUpdateCmd = function(l, d) return { fn = "update", l = l, d = d } end, sendCommand = function(c) SENT[#SENT + 1] = c end },
}
local E = {}
local f = load("local E, api = ...\n" .. src)
f(E, api)
return E
''', eco[e0:e1])
res = L.execute(r'''
local E = ...
local function stop(sg, n, on)
  local s = { stationGroup = sg, stopConfig = { load = {}, maxLoad = {}, forceUnload = false, destroyForConfigChange = true, destroyForRefresh = true } }
  for k = 1, n do s.stopConfig.load[k] = (k == on); s.stopConfig.maxLoad[k] = 1 end
  return s
end
local out = {}
-- a freight line: its loading stop full (bricks, 33), its unloading stop empty
LINEC[10] = { stops = { stop(1, 37, 34), stop(2, 0) } }
out.f = E.fullLineStops(10)
local c = SENT[1]
out.fsent = #SENT
out.fl = c and c.l
out.f1 = c and trues(c.d.stops[1].stopConfig.load)
out.f2n = c and count(c.d.stops[2].stopConfig.load)
out.f2m = c and count(c.d.stops[2].stopConfig.maxLoad)
out.f2t = c and trues(c.d.stops[2].stopConfig.load)
out.f2keep = c and c.d.stops[2].stopConfig.destroyForRefresh
-- a bus line that listed nothing anywhere
SENT = {}
LINEC[11] = { stops = { stop(3, 0), stop(4, 0) } }
out.b = E.fullLineStops(11)
out.bt = SENT[1] and trues(SENT[1].d.stops[2].stopConfig.load)
-- a full line: no update
SENT = {}
LINEC[12] = { stops = { stop(5, 37, 1), stop(6, 37, 1) } }
out.full = E.fullLineStops(12)
out.fullsent = #SENT
-- off
ENV.MPFEVER_LINEFIX = "0"
SENT = {}
out.off = E.fullLineStops(10)
out.offsent = #SENT
ENV.MPFEVER_LINEFIX = nil
return out
''', E)
check(res.f is True and res.fsent == 1 and res.fl == 10, "a freight line with an empty stop: one line update")
check(res.f1 == "34" and res.f2n == 37 and res.f2m == 37 and res.f2t == "" and res.f2keep is True,
      "its loading stop kept, its unloading stop given 37 entries, loading nothing, its other settings kept")
check(res.b is True and res.bt == "1", "a bus line's empty stops load the passengers")
check(res.full is False and res.fullsent == 0, "a full line: no update")
check(res.off is False and res.offsent == 0, "MPFEVER_LINEFIX=0: nothing")
so = eco[e1:eco.index("local function nameOf(e)")]
check("E.fullLineStops(e)" in so and so.index("E.fullLineStops(e)") < so.index("makeEntitySetPlayerCmd"),
      "setOwner fills a line's stops before its owner changes (auction, sale, merger, heir)")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
