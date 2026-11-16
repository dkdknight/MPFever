"""Offline test (0.8.14, #372): a build whose copy takes town buildings away is shipped the usual way, not at the click
(G.preTownBuildings and G.preship in mpfever_bridge.script.lua).

Erik's modular harbour on beule's server, 2026-11-15 20:01: its copy took 3 town buildings away; at the build's step Erik's engine
refused its own tool's command ("Apply: invalid entity: 223560", one of them, which the town had rebuilt meanwhile) while beule's
game built the harbour from the copy: "copy built here, refused by its builder", a resynchronisation.
  - G.preTownBuildings: the first town building (file under buildings/) of toRemove, numbers or shipped references; nil for an
    industry, a station or nothing;
  - G.preship asks it before shipping (MPFEVER_PRESHIPTOWN=1: at the click, as before), and logs why.
Needs lupa for the run part. Run: python tests/test_pretown0814.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


a = src.find("G.preTownBuildings = function(m)")
fn = src[a:src.find("\nend\n", a) + 5]
check(a > 0, "G.preTownBuildings found")
p = src.find("G.preship = function(r)")
body = src[p:src.find("\nend\n", p)]
k = body.find("pcall(G.preTownBuildings, r.copy)")
check(k > 0, "G.preship asks it")
check('os.getenv("MPFEVER_PRESHIPTOWN") ~= "1"' in body[k - 200:k], "  MPFEVER_PRESHIPTOWN=1: at the click, as before")
check("shipped the usual way\")\n\t\t\treturn false" in body[k:k + 400], "  the usual way otherwise")
check(k < body.find('send("act", a)'), "  before the copy is sent")

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed: the run part skipped")
    print("all ok" if not fails else "FAILED: %d" % len(fails))
    sys.exit(1 if fails else 0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
G = {}
FILES = { [223560] = "::/buildings/a/r1/1x1_01/a_res_l1_1x1_01.con", [384362] = "buildings/a/r1/1x2_01/a_res_l1_1x2_01.con",
  [500] = "::/industries/farm/farm.con", [600] = "station/rail/modular_station/modular_station.con" }
api = { type = { ComponentType = { CONSTRUCTION = 1 } }, engine = { getComponent = function(e, t)
  if FILES[e] then return { fileName = FILES[e] } end return nil end } }
""")
L.execute(fn)
f = L.eval("function(t) return G.preTownBuildings(t) end")
tb = L.eval("function(...) return {...} end")
check(f(L.eval("{ toRemove = { 600, 223560, 384362 } }")) == 223560, "Erik#1:257: town buildings taken away (the first named)")
check(f(L.eval("{ toRemove = { { id = 384362, __ref = true, k = 'con' } } }")) == 384362, "  as shipped references too")
check(f(L.eval("{ toRemove = { 600 } }")) is None, "a station's edit: at the click as before")
check(f(L.eval("{ toRemove = { 500 } }")) is None, "an industry: not a town building")
check(f(L.eval("{ toRemove = {} }")) is None and f(L.eval("{}")) is None, "nothing taken away: nil")
check(f(L.eval("{ toRemove = { 999 } }")) is None, "an entity gone already: nil (the engine decides)")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
