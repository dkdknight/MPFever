"""Offline test: an industry bulldozed is taken away on the replaying games too (0.8.3, #230 #242 #245, MPFEVER_INDREMOVE).

On 2026-11-11 three games crashed when another player bulldozed an industry (Orgaanic and RobyPrivat: a farm, twice; CalvinPigeon
and Fjerreiro: a quarry, twice): the capture was the industry's entrance street, the node at its end and the industry; the replay
(removalPlan + engineReplay) removed the street with the engine's segment removal and added the constructions of
R.removedConstructions, which kept the player-owned ones only. The industry stayed connected to the removed node: assertion
AreAllNodesEmpty (TransportNetworkSystem.cpp:635), the game closed. The industries of a removal are now in that list too.
mpfever_refs.lua is run through lupa with a mocked game API.
Run: python tests/test_indremove083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content")
L = lua52.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENVV = {}
os = { getenv = function(k) return ENVV[k] end, clock = function() return 0 end }
W = {}
api = {
  type = { ComponentType = { CONSTRUCTION = "con", PLAYER_OWNED = "po", STATION_GROUP = "sg" } },
  engine = {
    entityExists = function(e) return W[e] ~= nil end,
    getComponent = function(e, ct) local c = W[e]; return c and c[ct] or nil end,
    system = { streetConnectorSystem = {
      getConstructionEntityForSubconstruction = function() return -1 end,
      getConstructionEntityForStation = function() return -1 end } },
  },
}
W[217835] = { con = { fileName = "industry/farm/farm.con" } }           -- a farm of the map (nobody's)
W[300] = { con = { fileName = "industry/quarry.con" } }                -- a quarry
W[400] = { con = { fileName = "station/rail/modular_station/modular_station.con" }, po = { player = 7 } }  -- a station of a player
W[500] = { con = { fileName = "building/era_a/res_1_1x1_01.con" } }     -- a town building (nobody's)
W[600] = { con = { fileName = "asset/landmark/x.con" } }                -- nobody's, no industry
W[358713] = { be = {} }                                                -- a segment, no construction
''')


class Component:
    """The engine's components are userdata in the game, not Lua tables (the first version of the fix read c.fileName only from a
    table: it found no industry in game, the autotest conbulldoze said "industries 0"). A Python object is a userdata in lupa."""
    def __init__(self, f):
        self.fileName = f


W = L.eval("W")
for e in (217835, 300, 400, 500, 600):
    W[e]["con"] = Component(W[e]["con"]["fileName"])
R = L.execute(open(os.path.join(here, "mpfever_refs.lua"), encoding="utf-8").read())
L.globals().R = R
fails = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        fails.append(what)


def removed(lst):
    t = L.execute("return function(l) local m = { { toRemove = {} } } for i = 1, #l do m[1].toRemove[i] = l[i] end"
                  " local o = R.removedConstructions(m) table.sort(o) return table.concat(o, ',') end")
    return t(L.table_from(lst))


check(removed([217835]) == "217835", "#230: the farm bulldozed with its entrance street: removed with it")
check(removed([300]) == "300", "#242: the quarry: removed with it")
check(removed([400]) == "400", "a player's station (issue #15): removed with it, as before")
check(removed([500]) == "", "a town building: left to every game's own removal, as before")
check(removed([600]) == "", "nobody's construction that is no industry: as before")
check(removed([217835, 400, 500, 358713, -1]) == "400,217835", "a mixed list: the industry and the station only")
L.execute("ENVV.MPFEVER_INDREMOVE = '0'")
check(removed([217835]) == "", "MPFEVER_INDREMOVE=0: the industry left out, as before")
L.execute("ENVV.MPFEVER_INDREMOVE = nil")

# the bridge's removal replay still hands R.removedConstructions to engineReplay
src = open(os.path.join(here, "mpfever_bridge.script.lua"), encoding="utf-8").read()
check(len(re.findall(r"makeSegmentsRemoveProposal\(removal0?\)\s*\n\s*end, R\.removedConstructions\(probe\)\)", src)) == 2,
      "the bridge's two removal replays add R.removedConstructions to the engine's segment removal")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
