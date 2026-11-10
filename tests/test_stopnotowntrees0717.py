"""Offline test: a street stop whose replay would take trees or rocks away on this game only is not hidden from the towns
(0.7.17, issue #194 / #150; G.stopTownDiff and replayStop in mpfever_bridge.script.lua).

#194 (keviK's stop, 21:15:05): the replay on AMD's and Sascha's games would align ground AND take trees away ("al 0.000/127.088,
ar 0.000/310.929, tr 0.000/0.895"); 0.7.16 (MPFEVER_STOPNOTOWN, #177-#180) hid it from the towns. The games then went on with
other entities: keviK's buildIds differed 9 s later, its people one minute later (#150), and nothing said so.
  - G.stopTownDiff returns its text and whether trees or rocks (tr, rk) differ;
  - replayStop: trees or rocks differing: logged, replayed as before 0.7.16 (not hidden); ground only: hidden as in 0.7.16;
  - MPFEVER_STOPNOTOWNTREES=0: hidden as in 0.7.16.
Needs lupa (pip install lupa). Run: python tests/test_stopnotowntrees0717.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


a = src.index("G.stopTownDiff = function(a, pd)")
b = src.index("\nend\n", a) + 5
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''G = {}
ALIGN, REMOVAL = {}, {}
api = { engine = { util = { town = {
  getTerrainAlignmentImpact = function() return ALIGN end, getAutoRemovalEntityImpact = function() return REMOVAL end } } } }
''' + src[a:b])
f = L.eval("function() local d, e = G.stopTownDiff({ ts = { al = 0, ar = 0, tr = 0, rk = 0 } }, {}) return tostring(d) .. '|' .. tostring(e) end")
L.execute("ALIGN = { [1] = { 127.088, 310.929 } }; REMOVAL = { [1] = { 0.895, 0 } }")
r = f()
check(r.startswith("al 0.000/127.088") and "tr 0.000/0.895" in r and r.endswith("|true"), "#194's stop: ground and trees, trees flagged", r)
L.execute("ALIGN = { [1] = { 0, 0.416 } }; REMOVAL = {}")
r = f()
check(r == "ar 0.000/0.416|false", "#177's stop: ground only, not flagged", r)

rst = src[src.index("local function replayStop(a, plan, variant)"):]
rst = rst[:rst.index("\nend\n")]
k = rst.index("local okD, diff, ents = pcall(G.stopTownDiff, a, pd)")
blk = rst[k:rst.index("if okV and crit then", k)]
t = blk.index('if okD and diff and ents and os.getenv("MPFEVER_STOPNOTOWNTREES") ~= "0" then')
h = blk.index("elseif okD and diff then")
check(t < h and "plan.noTown = true" not in blk[t:h] and "replayStop" not in blk[t:h], "trees differing: logged, not hidden, the replay goes on as before")
check("plan.noTown = true" in blk[h:] and "return replayStop(a, plan, variant)" in blk[h:], "ground only: hidden as in 0.7.16")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
