"""Offline test (0.8.11, #316): a build that names what another held build of the same game names is not shipped at the click.

From-Hellscream's three roads, 2026-11-14 21:27: held while the game gave way to Sascha's demolition, shipped at the click, all
released at t=15037800. The second named segments and nodes of the first (113870, 113872, 114346, 201142), computed by the tool
without it; the engine built it otherwise than its copy: "built otherwise than shipped at the click", a resynchronisation.
  - G.prePendingOverlap(r, refs): the id of another held build of this game (G.natRelease) released no later whose references share
    an entity with refs; a held build shipped the usual way (no references kept) counts too; nil otherwise;
  - G.preship ships such a build the usual way (its capture once built); MPFEVER_PREPENDING=0: as before.
Needs lupa. Run: python tests/test_prepending0811.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


a = src.find("G.prePendingOverlap = function(r, refs)")
fn = src[a:src.find("\nend\n", a) + 5]
check(a > 0, "G.prePendingOverlap found")
p = src.find("G.preship = function(r)")
body = src[p:src.find("\nend\n", p)]
k = body.find("pcall(G.prePendingOverlap, r, refs)")
check(k > 0, "G.preship asks it")
check(body.find("local refs = G.preRefsOf(args)") < k < body.find('send("act", a)'), "  after the references are read, before anything is sent")
check('os.getenv("MPFEVER_PREPENDING") ~= "0"' in body, "  MPFEVER_PREPENDING=0: as before")
check("shipped the usual way\")\n\t\t\treturn false" in body[k:k + 400], "  the usual way then")

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
function refs(...) local t = {} for _, id in ipairs({...}) do t[#t + 1] = { ref = { id = id, __ref = true } } end return t end
r196 = { id = 85, at = 15037800, preshipped = "From-Hellscream:196", preRefs = refs(113870, 113872, 114341, 114346, 201142), copy = {} }
r197 = { id = 86, at = 15037800, copy = {} }
r198 = { id = 87, at = 15037800, copy = {} }
""")
f = L.eval("function(r, rs) return G.prePendingOverlap(r, rs) end")
L.execute("G.natRelease = { r196, r197 }")
check(f(L.eval("r197"), L.eval("refs(113870, 113872, 114346, 133304, 201141, 201142, 97262)")) == 85, "#316: 197 names what 196 names: 196")
check(f(L.eval("r197"), L.eval("refs(1, 2, 3)")) is None, "a build naming nothing of the held one: none (shipped at the click)")
check(f(L.eval("r197"), L.eval("{}")) is None, "no references: none")
L.execute("G.natRelease = { r197 }")
check(f(L.eval("r197"), L.eval("refs(113870)")) is None, "itself alone: none")
L.execute("r196.at = 15037900; G.natRelease = { r196, r197 }")
check(f(L.eval("r197"), L.eval("refs(113870)")) is None, "a held build released later: none")
L.execute("r196.at = 15037800; G.natRelease = { { id = 84, at = 15037800, copy = {} }, r197 }")
check(f(L.eval("r197"), L.eval("refs(5)")) == 84, "a held build shipped the usual way (no references kept): counts")
L.execute("G.natRelease = { { id = 84, at = 15037800 }, r197 }")
check(f(L.eval("r197"), L.eval("refs(5)")) is None, "  not without its copy (nothing held to build)")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
