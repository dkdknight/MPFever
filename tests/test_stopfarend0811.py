"""Offline test (0.8.11, #261): a stop replayed on a segment whose end lies far from its node keeps that end when the builder's
segment had it too.

chris's stops of 2026-11-14 23:03 (#325, #327, #329) and #288: ends 2.7 m, 11.5 m and 11.9 m off their nodes, the same on the
builder's game (the copy's ends). replayStop took any end more than 2 m from its node for a bad read and used the node's position:
the street was laid on the ground again on the replaying games only (68 to 790 m3 aligned, trees taken away), a resync each time.
  - replayStop's builderEnd: an end farther than 2 m that is one of the builder's ends (plan.seg.comp position0/1, within 1 cm)
    is kept; MPFEVER_STOPENDSBUILDER=0: the node's position, as before;
  - the 2 m rule and MPFEVER_STOPNODEPOS=1 stay as they were;
  - autotest dstop: MPFEVER_DSTOPFAR=1 takes only segments with an end more than 2 m off its node.
Run: python tests/test_stopfarend0811.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local function replayStop(a, plan, variant)")
body = src[i:src.find("\nend\n", i)]
check(i > 0, "replayStop found")
b = body.find("local function builderEnd(q)")
check(b > 0, "builderEnd in replayStop")
be = body[b:b + 500]
check('os.getenv("MPFEVER_STOPENDSBUILDER") == "0" then return false end' in be, "  MPFEVER_STOPENDSBUILDER=0: as before")
check("{ sc.position0, sc.position1 }" in be, "  compared with the builder's two ends (either way round)")
check("< 0.01" in be, "  within 1 cm")
check(0 < body.find("local sc = plan.seg.comp or {}") < b, "  sc known before builderEnd")
s = body.find("local function segEnd(k)")
se = body[s:s + 1600]
check("math.abs(q.x - np.x) < 2 and math.abs(q.y - np.y) < 2 and math.abs(q.z - np.z) < 2 then return sVec(q) end" in se, "the 2 m rule kept")
check(se.find("< 2 and") < se.find("builderEnd(q)"), "  builder's end asked only past 2 m")
check("q.x == q.x and q.y == q.y and q.z == q.z and builderEnd(q)" in se, "  never a NaN end")
check('os.getenv("MPFEVER_STOPNODEPOS") ~= "1"' in se, "MPFEVER_STOPNODEPOS=1 still the nodes' positions")
check("its node's position" in se, "the node's position otherwise")
d = src.find("H.dstop = function(from, p)")
check('os.getenv("MPFEVER_DSTOPFAR") == "1"' in src[d:d + 3000], "dstop: MPFEVER_DSTOPFAR")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
