"""Offline test (0.8.14): the signals and stops on a construction's own TRACKS are replayed with the construction (G.conStopsOk,
G.conTrackObjOk in mpfever_bridge.script.lua).

The reports of 2026-11-15: a rail depot laid over a signalled track (Holzi#1:137, Holzi#1:44) and modular station edits with signals
on the station's tracks (From-Hellscream:235) were rebuilt without them ("construction edge objects (airport signs)": the engine's
conversion of the construction has none), a resynchronisation each; on the host the builder's next signal on that track crashed
the game before it ('it != components.end()', #364, #381).
  - G.conTrackObjOk: a track segment (type 1) of a construction, not an airport's or airfield's: true; a street or an airport
    runway: false; MPFEVER_CONEDGEOBJ=0: false;
  - G.conStopsOk: objects on a construction's own track now accepted (the dry run converts them, as the stops of a cut street,
    #109); an airport's sign on its runway still not; a street segment that is not the construction's: as before;
    MPFEVER_CONEDGEOBJ=0: the construction's tracks refused, as 0.6.4 to 0.8.13.
Needs lupa. Run: python tests/test_contrackobj0814.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m0 = re.search(r"^local function isConstructionSegment\(sg\)\n.*?^end\n", src, re.S | re.M)
m1 = re.search(r"^G\.conTrackObjOk = function\(sg\)\n.*?^end\n", src, re.S | re.M)
m2 = re.search(r"^G\.conStopsOk = function\(m\)\n.*?^end\n", src, re.S | re.M)
check(m0 and m1 and m2, "isConstructionSegment, G.conTrackObjOk, G.conStopsOk found")
if not (m0 and m1 and m2):
    sys.exit(1)
check("G.conStopsOk(m) then" in src and "local okd, dry2, n = pcall(G.eoDryRun, m)" in src, "replayNativeConstruction still asks G.conStopsOk before its dry run")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
G = {}
ENV = {}
os = { getenv = function(k) return ENV[k] end }
""" + m0.group(0).replace("local function isConstructionSegment", "function isConstructionSegment") + m1.group(0) + m2.group(0) + """
local v = { x = 0, y = 0, z = 0 }
function seg(id, typ, tpl) return { entity = id, type = typ, comp = { roadTemplate = tpl, position0 = v, position1 = v, tangent0 = v, tangent1 = v } } end
function build(segs, objs)
  local eo = {}
  for i, s in ipairs(objs) do eo[i] = { model = "infrastructure/signal/signal_path_a.con", segmentEntity = s } end
  return { toAdd = { { fileName = "x.con" } }, proposal = { addedSegments = segs, edgeObjectsToAdd = eo } }
end
DEPOT = "/res/config/street/track/rail_depot.street_template"
STATION = "/res/config/street/track/simple/simple.street_template"
RUNWAY = "/res/config/street/airport/runway.street_template"
TOWN = "/res/config/street/town_medium.street_template"
""")
ok = L.eval("function(...) return G.conTrackObjOk(...) end")
seg = L.eval("seg")
stops = L.eval("function(segs, objs) return G.conStopsOk(build(segs, objs)) end")
tbl = L.eval("function(...) return {...} end")
g = L.globals()

check(ok(seg(-1, 1, g.DEPOT)) is True, "a rail depot's own track: accepted")
check(ok(seg(-1, 1, g.STATION)) is True, "a modular station's own track: accepted")
check(ok(seg(-1, 0, g.RUNWAY)) is False, "an airport's runway: not (the engine converts its signs)")
check(ok(seg(-1, 1, "/res/config/street/airfield/x.street_template")) is False, "an airfield's: not")
check(ok(seg(-1, 0, g.TOWN)) is False, "a street: not a track")

check(stops(tbl(seg(-1, 1, g.DEPOT)), tbl(-1)) is True, "Holzi#1:137: a signal on the depot's own track: the dry run")
check(stops(tbl(seg(-1, 1, g.STATION), seg(-2, 1, g.STATION)), tbl(-1, -2)) is True, "From-Hellscream:235: two signals on the station's tracks: the dry run")
check(stops(tbl(seg(-1, 0, g.RUNWAY)), tbl(-1)) is False, "an airport's sign on its runway: as before (not this way)")
check(stops(tbl(seg(-1, 0, g.TOWN)), tbl(-1)) is True, "a stop on the street the construction cuts (#109): as before")
check(stops(tbl(seg(-1, 1, g.DEPOT), seg(-2, 0, g.RUNWAY)), tbl(-1, -2)) is False, "one object on a runway among them: not this way")
g.ENV.MPFEVER_CONEDGEOBJ = "0"
check(stops(tbl(seg(-1, 1, g.DEPOT)), tbl(-1)) is False, "MPFEVER_CONEDGEOBJ=0: the depot's track refused, as 0.6.4 to 0.8.13")
check(stops(tbl(seg(-1, 0, g.TOWN)), tbl(-1)) is True, "  (the cut street's stops unchanged)")
g.ENV.MPFEVER_CONEDGEOBJ = None
g.ENV.MPFEVER_CONSTOPS = "0"
check(stops(tbl(seg(-1, 1, g.DEPOT)), tbl(-1)) is False, "MPFEVER_CONSTOPS=0: never, as before")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
