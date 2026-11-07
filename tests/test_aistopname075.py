"""A computer company's new stops get a name (0.7.5, buildStop in mpfever_ai.lua).

A computer company built its street stops with an empty name: in the game, at an auction ("Unnamed station (lot N)") and in a
player's line window they had none. A stop is now named after its town and the company ("Lingen Transports Régionaux"): its
key is "<town>:<point>" (the town lines and the lines between two towns build their stops that way). The name travels in the
build, so every game gets it. MPFEVER_AISTOPNAME=0: none, as before.
Run: python tests/test_aistopname075.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ai.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local function buildStop(E, co, seg, n)")
body = src[i:src.find("\nend\n", i)]
check(i > 0, "buildStop found")
check('eo.name = ""' in body and 'os.getenv("MPFEVER_AISTOPNAME") ~= "0"' in body, "an empty name only with MPFEVER_AISTOPNAME=0")
check('tostring(n):match("^(%d+):")' in body and "townName(E, tw)" in body and "AINAME" in body, "its town's name and the company's")
check(body.find("eo.name = townName") < body.find("ssp.edgeObjectsToAdd = { eo }"), "set before the stop goes into the build")
t = src.find("local function townName(E, t)")
check(0 < t < i, "townName is known there")
for call in ('buildStop(E, co, s.e, key)', 'buildStop(E, co, s.e, town .. ":" .. w.use)'):
    check(call in src, "a caller names its stop by its town: " + call)
k = src.find("local function stopNear(E, co, stops, p, key)")
check(k > 0 and 'stopNear(E, co, stops, w.p.p, w.town .. ":" .. w.p.use)' in src, "the lines between two towns give the town too")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
