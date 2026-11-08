"""The checks' diagnostic dump weighs less (0.7.5, extendedParts in mpfever_bridge.script.lua).

The user's server, 2026-11-07: every check (every 10 s) held the simulation 0.15 to 0.3 s ("expensive checksum" lines), a hitch
the players felt. Part of it is the diagnostic dump written at each check (sdump_ring_*.txt, the files that showed the noise
and traffic drift of that morning): the game scripts' states, and the world's (vehicles, lines, names, stations, and a loop
over every construction of the map). The world's part now goes in one dump of six, once a minute (by the dump's own counter: the dumps are
not part of the check, each game writes its own), the game scripts' states in every one; the dump's cost is measured apart
("dump=" in the "hash costs" lines). MPFEVER_SDUMPWORLD=1: the world in every dump, as before; MPFEVER_SDUMP=all: every dump
whole (tests).
Run: python tests/test_sdumpworld075.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local function extendedParts(parts")
j = src.find("\nend\n", i)
ext = src[i:j]
check(i > 0, "extendedParts found")
flat = ext.find("flatten(c.state, name, dump, 0)")
world = ext.find('local world = dump and (SDUMP.all or worldTurn or forced or os.getenv("MPFEVER_SDUMPWORLD") == "1")')
veh = ext.find('for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do')
cons = ext.find('for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do')
check(0 < flat < world, "the game scripts' states dumped at every check, before the world's choice")
check("if dump and world then" in ext[world:veh] and world < veh < cons, "the vehicles and the constructions only in the world's dumps")
write = ext.find('sdump_ring_')
check(ext.rfind("if dump then", 0, write) > cons, "every dump still sorted and written (the ring of 12)")
check("SDUMP.n = SDUMP.n + 1" in ext[cons:write], "the dump's own counter still counts the ring (0.7.7: the check's number chooses the world's turn, see test_sdumpworldn077.py)")
check("K.dumpCost = tDump + os.clock() - tWorld" in ext, "the dump's cost measured")
h = src.find("local function simHash(")
check("if K.dumpCost then costs.dump = K.dumpCost; K.dumpCost = nil end" in src[h:h + 9000], "and shown with the check's costs")
# what the check compares does not depend on the dump
parts_lines = [l for l in ext.splitlines() if "parts[" in l or "parts." in l]
check(all("world" not in l and "dump" not in l for l in parts_lines), "no part of the check depends on the dump")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
