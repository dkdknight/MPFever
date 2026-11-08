"""Test of #162's fix (0.7.12, mod/mpfever_1/content/mpfever_bridge.script.lua, executeActionOnce).

rasma's game, 2026-11-08 20:03: a game script mod of the host (MaZaDoX77) named its new station group "Avenue de la Scierie"
by the host's id, 215954 (action MaZaDoX77:238, tok "gsmod-..."); on rasma's game 215954 was a cargo item (SimCargo,
SimEntityAtStock), with no Name component, and the game stopped on "GetComponentDataIndex 'it != components.end()'" (Name).
Only the simulation's mods' commands (tok "mod") were checked. Now:
- a name, whoever gives it (a player, a game script, the simulation's mods), goes only on an entity that has a NAME here;
- a game script's colour only on one with a COLOR; the simulation's mods as before (a line update needs a line);
- a player's colour and every other command: as before;
- skipped with a reason that is no "DESYNC". MPFEVER_NAMEGUARD=0: as before.
Needs lupa for the Lua part. Run: python tests/test_nameguard0712.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


i = src.index("	local nameGuard = os.getenv(\"MPFEVER_NAMEGUARD\")")
blk = src[i:src.index("\n\tend\n", src.index("if (a.tok == \"mod\" or nameGuard)", i)) + 6]
check("DESYNC" not in blk and "return result" in blk, "skipped with a reason that is no DESYNC")
check(i < src.index("local okm, missing = pcall(missingEntities, a.fn, a.args or {})"), "  checked before the command is made")
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
ENTS = { [215954] = { SIM_CARGO = {} }, [300] = { STATION_GROUP = {}, NAME = {} }, [400] = { LINE = {}, NAME = {}, COLOR = {} } }
api = { type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = { getComponent = function(e, ct) return ENTS[e] and ENTS[e][ct] or nil end } }
function guard(a)
	local result = { success = false }
''' + blk + '''
	return nil
end
''')
    def g(fn, e, tok):
        return L.eval(f'guard({{ fn = "{fn}", args = {{ {e}, "x" }}, uid = "u", tok = {tok} }})')
    r = g("makeEntitySetNameCmd", 215954, '"gsmod-1794164304-MaZaDoX77"')
    check(r is not None and "name" in r["err"], "#162: a game script's name on a cargo item here: skipped", r and r["err"])
    check(g("makeEntitySetNameCmd", 215954, '"1794-123-rasma"') is not None, "  a player's name on an entity without a name here: skipped")
    check(g("makeEntitySetNameCmd", 300, '"gsmod-1"') is None, "a name on a station group (it has one): goes on")
    check(g("makeEntitySetNameCmd", 400, '"1794-123-rasma"') is None, "  a player's line name: goes on")
    check(g("makeEntitySetColorCmd", 215954, '"gsmod-1"') is not None, "a game script's colour on something without one: skipped")
    # (0.7.13, #168: a player's colour is checked too, see test_colorguard0713.py; MPFEVER_COLORANY=0: as in 0.7.12)
    L.execute('ENV.MPFEVER_COLORANY = "0"')
    check(g("makeEntitySetColorCmd", 215954, '"1794-123-rasma"') is None, "  a player's colour: as before (0.7.12, MPFEVER_COLORANY=0)")
    L.execute('ENV.MPFEVER_COLORANY = nil')
    check(g("makeEntitySetColorCmd", 400, '"gsmod-1"') is None, "  a game script's colour on a line: goes on")
    check(g("makeLineUpdateCmd", 215954, '"gsmod-1"') is None, "  other commands: as before")
    check(g("makeEntitySetNameCmd", 215954, '"mod"') is not None and g("makeLineUpdateCmd", 300, '"mod"') is not None,
          "the simulation's mods: as before (a name needs a name, a line update a line)")
    L.execute('ENV.MPFEVER_NAMEGUARD = "0"')
    check(g("makeEntitySetNameCmd", 215954, '"gsmod-1"') is None and g("makeEntitySetNameCmd", 215954, '"mod"') is not None,
          "MPFEVER_NAMEGUARD=0: the simulation's mods' commands only, as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
