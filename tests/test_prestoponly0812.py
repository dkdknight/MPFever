"""Offline test (0.8.12): only a stop or signal put on unchanged segments is shipped at the click with zero town numbers.

0.8.9 shipped at the click every copy carrying an edge object, saying it moves no ground (true for the stop and signal tools only).
The 0.8.11 reports of 2026-11-15: all 9 builds not reproduced were such copies - a track laid or changed with a signal (Peter:73
+8/-4 segments, Eier#1:26), a segment demolished with its signal (Eier#1:30), a station demolished with its stops (marcu#6:18):
"town stats differ (builder 0 / here ...)".
  - G.preStopOnly(copy): true for edge objects added or removed with as many segments put back as taken away, no node added or
    removed, no construction; false otherwise;
  - G.preship ships the others the usual way (MPFEVER_PRESHIPSTOPALL=1: at the click, as 0.8.9-0.8.11).
Needs lupa for the run part. Run: python tests/test_prestoponly0812.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


a = src.find("G.preStopOnly = function(m)")
fn = src[a:src.find("\nend\n", a) + 5]
check(a > 0, "G.preStopOnly found")
p = src.find("G.preship = function(r)")
body = src[p:src.find("\nend\n", p)]
k = body.find("not G.preStopOnly(r.copy)")
check(k > 0, "G.preship asks it")
check('os.getenv("MPFEVER_PRESHIPSTOPALL") ~= "1"' in body[k - 300:k], "  MPFEVER_PRESHIPSTOPALL=1: as before")
check("shipped the usual way\")\n\t\treturn false" in body[k:k + 400], "  the usual way otherwise")
check(k < body.find("r.preTs = { al = 0"), "  before the zero town numbers are given")

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed: the run part skipped")
    print("all ok" if not fails else "FAILED: %d" % len(fails))
    sys.exit(1 if fails else 0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("G = {}")
L.execute(fn)
L.execute("""
function cp(an, rn, as, rs, eoa, eor, con)
  local function n(k) local t = {} for i = 1, k do t[i] = { entity = i } end return t end
  return { toAdd = n(con or 0), toRemove = {}, proposal = { addedNodes = n(an), removedNodes = n(rn), addedSegments = n(as),
    removedSegments = n(rs), edgeObjectsToAdd = n(eoa), edgeObjectsToRemove = n(eor) } }
end
""")
f = L.eval("function(...) return G.preStopOnly(cp(...)) end")
check(f(0, 0, 1, 1, 1, 0, 0) is True, "a stop on a street (chris#1:33: +1/-1 segment, 1 object): at the click")
check(f(0, 0, 1, 1, 0, 1, 0) is True, "a stop taken away with the stop tool: at the click")
check(f(0, 0, 2, 2, 2, 0, 0) is True, "two stops on two segments: at the click")
check(f(5, 2, 8, 4, 1, 0, 0) is False, "Peter:73, a track with a signal (+5/-2 nodes, +8/-4 segments): the usual way")
check(f(0, 1, 1, 3, 1, 0, 0) is False, "Eier#1:26, a track changed with a signal: the usual way")
check(f(0, 1, 0, 1, 0, 1, 0) is False, "Eier#1:30, a segment demolished with its signal: the usual way")
check(f(0, 0, 1, 1, 1, 0, 1) is False, "with a construction: the usual way")
check(f(0, 0, 1, 1, 0, 0, 0) is False, "no object at all: not this case")
L.execute("G.x = cp(0,0,1,1,1,0,0); G.x.toAdd = {}; G.x.toRemove = { { entity = 9 } }")
check(L.eval("G.preStopOnly(G.x)") is False, "marcu#6:18 kind, a construction taken away: the usual way")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
