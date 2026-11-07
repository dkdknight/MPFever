"""An unnamed station's lot names its town (0.7.5, E.townOfStation in mpfever_eco.lua, the Auctions page, the lot's detail and
the news).

A computer company's truck stops have no name: at an auction they read « Unnamed station (lot N) », which says nothing of where
they are. The lot keeps the town of its first station the engine knows (api.engine.system.stationSystem.getTown, the same on
every game; always kept in the simulation: a switch there would differ from PC to PC) and reads « Unnamed station in <town>
(lot N) ». MPFEVER_LOTTOWN=0 (the interface only): its number only, as 0.7.4.
Needs lupa (pip install lupa). Run: python tests/test_lottown075.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
eco = open(os.path.join(CONTENT, "mpfever_eco.lua"), encoding="utf-8").read()
ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read()
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = eco.find("function E.townOfStation(sg)")
j = eco.find("\nend\n", i) + 5
check(i > 0, "E.townOfStation found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
E = {}
api = { type = { ComponentType = { STATION_GROUP = 1, NAME = 2 } }, engine = { system = { stationSystem = {} } } }
GROUPS = { [10] = { stations = { 11, 12 } }, [20] = { stations = { 21 } }, [30] = { stations = {} } }
TOWNS = { [11] = -1, [12] = 500, [21] = 600 }
NAMES = { [500] = "Lyon", [600] = "" }
api.engine.getComponent = function(e, t)
  if t == 1 then return GROUPS[e] end
  if t == 2 then return NAMES[e] and { name = NAMES[e] } or nil end
end
api.engine.system.stationSystem.getTown = function(st) return TOWNS[st] end
''')
L.execute(eco[i:j])
check(L.eval("E.townOfStation(10)") == "Lyon", "the first station with a town gives its name (Lyon)")
check(L.eval("E.townOfStation(20)") is None, "a town without a name: none")
check(L.eval("E.townOfStation(30)") is None and L.eval("E.townOfStation(99)") is None, "no station, no group: none, no error")

lots = eco[eco.find("function E.lotsOf(env, c)"):]
lots = lots[:lots.find("\nend\n")]
check('if lot.label == "" then lot.town = E.townOfStation(sg) end' in lots, "only an unnamed station's lot keeps a town")
check('os.getenv("MPFEVER_LOTTOWN")' not in eco, "no switch in the simulation (each PC has its own)")
check(eco.count("town = lot.town") == 2, "the news of a lot sold or not sold keep it too")

k = ui.find("U.auLotTitle = function(lot)")
title = ui[k:ui.find("\nend\n", k)]
check('C.Tf("Gare sans nom à %s (lot %s)", "Unnamed station in %s (lot %s)", lot.town, lot.idx or "?")' in title
      and 'os.getenv("MPFEVER_LOTTOWN") ~= "0"' in title, "the Auctions page: « Unnamed station in <town> (lot N) », MPFEVER_LOTTOWN=0: as before")
check(bridge.count('"Unnamed station in %s (lot %s)"') == 2, "the lot's detail and the news say it the same way")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
