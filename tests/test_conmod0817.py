"""Offline test (0.8.17, #400): a player's construction of a mod built with its street goes the way of the tool's own proposal
(isTransportConstruction / hasConstructionSegments in mpfever_bridge.script.lua, switch MPFEVER_CONMOD).

yoyo's light rail station of the mod Ultimate Light Rail ("mrnickert_ultimate_metro::/light_rail_station.con") came with a new tram
street to it (yoyo:40, +nodes 1 +segments 1 +constructions 1). Its file has no "/stations/": the script forms rebuilt it and the
engine refused every one ("Construction Not Possible", nothing in the way), the two-step replay built the street and refused the
station: a resynchronisation and both desyncs of the session.
The three functions are taken from the real bridge and run through lupa:
  - MPFEVER_CONMOD=0: yoyo:40 not taken for a construction with its street (the bug: the script forms);
  - now: taken (the engine's conversion of the construction, as for the base game's stations);
  - a construction whose file says "station" (any folder): taken;
  - a town building put back by a street build (playerEntity -1): not taken;
  - a mod's construction without a new segment: not taken (nothing changes for it);
  - the base game's stations, depots, junctions: taken as before.
Needs lupa. Run: python tests/test_conmod0817.py
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


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


a = src.index("local function isConstructionSegment(sg)")
b = src.index("-- an existing station (or depot...) rebuilt with other tracks or modules")
chunk = src[a:b]
check("the functions found", "local function isTransportConstruction(ce)" in chunk and "local function hasConstructionSegments(m)" in chunk)


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = {}\n" + ("ENV.MPFEVER_CONMOD = '0'\n" if off else "") + chunk + "\nHAS = hasConstructionSegments\n")
    return L.eval("function(code) return assert(load(code))() end")


YOYO40 = """{ toAdd = { { fileName = 'mrnickert_ultimate_metro::/light_rail_station.con', playerEntity = { __ref = true, k = 'player', co = 1 }, params = {} } },
  toRemove = {}, proposal = { addedSegments = { { entity = -1, comp = { roadTemplate = 'tram_new.street_template', type = 0 } } }, addedNodes = { {} } } }"""

run = runtime(off=True)
check("MPFEVER_CONMOD=0: yoyo:40 not taken for a construction with its street (the bug)", run("return HAS(%s)" % YOYO40) is False)
run = runtime()
check("now: yoyo:40 taken (the tool's proposal with the engine's conversion)", run("return HAS(%s)" % YOYO40) is True)
check("a construction whose file says station, in any folder, of a player",
      run("""return HAS({ toAdd = { { fileName = 'some_mod::/x/my_bus_Station.con', playerEntity = 5 } },
  proposal = { addedSegments = { { comp = { roadTemplate = 'standard.street_template' } } } } })""") is True)
check("a town building put back by a street build (playerEntity -1): not taken",
      run("""return HAS({ toAdd = { { fileName = 'some_mod::/buildings/house.con', playerEntity = -1 } },
  proposal = { addedSegments = { { comp = { roadTemplate = 'standard.street_template' } } } } })""") is False)
check("a mod's construction without a new segment: not taken",
      run("""return HAS({ toAdd = { { fileName = 'mrnickert_ultimate_metro::/light_rail_station.con', playerEntity = 5 } },
  proposal = { addedSegments = {} } })""") is False)
check("a base game's asset (no mod, no station) with a street: not taken, as before",
      run("""return HAS({ toAdd = { { fileName = '::/assets/fence.con', playerEntity = 5 } },
  proposal = { addedSegments = { { comp = { roadTemplate = 'standard.street_template' } } } } })""") is False)
for f in ("::/stations/rail/modular_station.con", "::/depots/road/road_depot/road_depot.con", "::/infrastructure/street_construction/roundabout.con"):
    check(f"the base game's {f.split('/')[-1]}: taken as before",
          run("""return HAS({ toAdd = { { fileName = '%s', playerEntity = 5 } },
  proposal = { addedSegments = { { comp = { roadTemplate = 'standard.street_template' } } } } })""" % f) is True)

check("(review) a mod's station put in a town (it takes town buildings away): taken as new",
      run("""return HAS({ toAdd = { { fileName = 'mrnickert_ultimate_metro::/light_rail_station.con', playerEntity = 5 } },
  toRemove = { { __ref = true, k = 'con', id = 67950, f = '::/buildings/b/r2/4x4_04/b_res_l2_4x4_04.con' } },
  proposal = { addedSegments = { { comp = { roadTemplate = 'tram_new.street_template' } } } } })""") is True)
check("(review) the edit of a mod's station standing (it takes that station away): not taken, its way of before",
      run("""return HAS({ toAdd = { { fileName = 'mrnickert_ultimate_metro::/light_rail_station.con', playerEntity = 5 } },
  toRemove = { { __ref = true, k = 'con', id = 500, f = 'mrnickert_ultimate_metro::/light_rail_station.con' } },
  proposal = { addedSegments = { { comp = { roadTemplate = 'tram_new.street_template' } } } } })""") is False)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
