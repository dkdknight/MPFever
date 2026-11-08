"""The world's part of the diagnostic dump falls at the same check on every game (0.7.7, extendedParts in
mpfever_bridge.script.lua).

The user's server and PC, 2026-11-08 00:00: a resynchronisation on "vehicles" alone. The dump's world part (every vehicle, by its
line and where it is) is written in one dump of six; counted by each game's own dumps, it fell at t=42066200 on the player's
game and 42105800 on the server's (a pause makes more dumps on one game): no two files of the same moment, the vehicle that
moved otherwise first could not be told. Now the check's number chooses it (the launcher's, the same on every game, which also
chooses the parts each check hashes); a dump without a number (the determinism run) still counts its own.
MPFEVER_SDUMPWORLDN=0: each game's own count, as before.
Run: python tests/test_sdumpworldn077.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local function extendedParts(parts, checkN)")
j = src.find("\nend\n", i)
ext = src[i:j]
check(i > 0, "extendedParts takes the check's number")
a = ext.find("local worldTurn = SDUMP.n % 6 == 0")
b = ext.find('if type(checkN) == "number" and os.getenv("MPFEVER_SDUMPWORLDN") ~= "0" then worldTurn = checkN % 6 == 0 end')
c = ext.find('local world = dump and (SDUMP.all or worldTurn or forced or os.getenv("MPFEVER_SDUMPWORLD") == "1")')
check(0 < a < b < c, "one check of six by its number; none given or MPFEVER_SDUMPWORLDN=0: the dump's own count, as before")
h = src.find("local function simHash(terrainSig, reg, n, buildIds, at)")
check(h > 0 and "pcall(extendedParts, parts, n)" in src[h:h + 9000], "simHash passes its check's number")
# the checks of the simulation and of a paused game pass the launcher's number (a.n), the determinism run none
check("simHash(terrainSigAt(st, now), st.co, a.n, st.buildIds, now)" in src and "simHash(G.simTerrainSig, G.co, a.n, G.simBuildIds, now)" in src,
      "the running and the paused checks give the launcher's number")
check(src.count("pcall(extendedParts") == 1 and src.count("extendedParts(") == 1, "called from simHash only")
# what each game writes does not change the check
parts_lines = [l for l in ext.splitlines() if re.search(r"\bparts[\[.]", l)]
check(all("worldTurn" not in l and "checkN" not in l for l in parts_lines), "no part of the check depends on it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
