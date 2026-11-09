"""Test of the night fix of 2026-11-09 (0.7.13, mod/mpfever_1/content/mpfever_bridge.script.lua executeActionOnce, C.notColourable
in mpfever_common.lua).

The night's game test (autotest pauseorder, 03:23) showed "action Host:4 makeEntitySetColorCmd SKIPPED, mod command on entity
108802, which is not something with a colour here" for a vehicle bought a moment before: the engine applies a vehicle's colour,
but a vehicle's Color component is not one the scripts can read (api.engine.getComponent(v, COLOR) gives nothing), so the colour
check of 0.7.12 (game scripts, #162) and 0.7.13 (every colour, #168) skipped every vehicle's colour. A colour from a player or a game
script is now skipped only on what has surely no colour here: missing, a node, a segment, a construction, a building, a person, an
animal, a town, an industry, cargo (#168's track segments, #162's cargo item). MPFEVER_COLORNEG=0: the Color component asked, as
before. The simulation's mods (tok "mod") keep their 0.7.1 check. Needs lupa. Run: python tests/test_colourneg0713.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
com = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


i = com.index("C.COLOUR_NOT = {")
nce = com[i:com.index("\n\treturn nil\nend\n", i) + len("\n\treturn nil\nend\n")]
check('"BASE_NODE", "BASE_EDGE", "CONSTRUCTION"' in nce and '"SIM_CARGO"' in nce and "TRANSPORT_VEHICLE" not in nce and '"LINE"' not in nce,
      "surely without a colour: nodes, segments, constructions... cargo; never a vehicle or a line")
i = src.index("	local nameGuard = os.getenv(\"MPFEVER_NAMEGUARD\")")
blk = src[i:src.index("\n\tend\n", src.index("elseif (a.tok == \"mod\" or nameGuard)", i)) + 6]
check('os.getenv("MPFEVER_COLORNEG") ~= "0"' in blk and "C.notColourable(a.args[1])" in blk, "MPFEVER_COLORNEG=0: as before")
check("DESYNC" not in blk, "  skipped with a reason that is no DESYNC")
po = src[src.index("H.pauseorder = function"):]
check("G.stampFloor = math.max(G.stampFloor or 0, gameTime() + 40 * STEP)" in po[:6000],
      "the autotest pauseorder stamps its colours beyond the pause point, as the tool lead of #168 did")
try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed: the Lua part skipped")
if lupa:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
log = function(s) end
-- a vehicle as the scripts see it: no readable Color component (the engine still colours it)
ENTS = { [108805] = { TRANSPORT_VEHICLE = {}, NAME = {} }, [400] = { LINE = {}, COLOR = {}, NAME = {} },
  [186664] = { BASE_EDGE = {} }, [186667] = { BASE_NODE = {} }, [215954] = { SIM_CARGO = {} }, [300] = { STATION_GROUP = {}, NAME = {} } }
api = { type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = { entityExists = function(e) return ENTS[e] ~= nil end, getComponent = function(e, ct) return ENTS[e] and ENTS[e][ct] or nil end } }
C = {}
''' + nce + '''
function guard(a)
	local result = { success = false }
''' + blk + '''
	return nil
end
''')

    def g(e, tok, fn="makeEntitySetColorCmd"):
        return L.eval(f'guard({{ fn = "{fn}", args = {{ {e}, "x" }}, uid = "u", tok = {tok} }})')
    P = '"1794171956-997000-Philipp"'
    check(g(108805, P) is None, "a player's colour on a vehicle (no readable Color component): goes on (it was skipped)")
    check(g(108805, '"gsmod-1"') is None, "  a game script's colour on a vehicle: goes on")
    check(g(400, P) is None, "  on a line: goes on")
    r = g(186664, P)
    check(r is not None and "base_edge" in r["err"], "#168: a colour on a track segment here: skipped", r and r["err"])
    check(g(186667, P) is not None, "  on a node: skipped")
    check(g(999999, P) is not None, "  on an entity that is not here: skipped")
    check(g(215954, '"gsmod-1"') is not None, "#162: a game script's colour on a cargo item: skipped")
    check(g(300, P, "makeEntitySetNameCmd") is None and g(215954, P, "makeEntitySetNameCmd") is not None,
          "names: as in 0.7.12 (the Name component asked: a station has one, a cargo item none)")
    check(g(108805, '"mod"') is not None, "the simulation's mods: their 0.7.1 check, as before")
    L.execute('ENV.MPFEVER_COLORNEG = "0"')
    check(g(108805, P) is not None and g(400, P) is None, "MPFEVER_COLORNEG=0: the Color component asked, as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
