"""Test of #168's fix (0.7.13, mod/mpfever_1/content/mpfever_bridge.script.lua, executeActionOnce).

lukas' game, 2026-11-08 22:28: Philipp's colours for 8 vehicles he had just bought (Philipp#1:109-116, stamped t=38916200)
came after lukas paused at t=38914200; Philipp sold the 8 in the pause (Philipp#1:117, applied at once), lukas' paused builds took
the freed ids (segments 186664, 186666...), and the colours went on track segments: "Assertion HasComponent(cmd.entity,
typeid(ecs::component::Color)) failed" (apply_command.cpp:1157). In 0.7.12 only a game script's colour was checked.
Now every colour, whoever gives it, goes only on an entity with a COLOR here; else skipped (no DESYNC). MPFEVER_COLORANY=0: game
scripts' colours only, as in 0.7.12. Needs lupa. Run: python tests/test_colorguard0713.py
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
check('os.getenv("MPFEVER_COLORANY") ~= "0"' in blk, "MPFEVER_COLORANY=0: as in 0.7.12")
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
ENTS = { [186664] = { BASE_EDGE = {} }, [186700] = { TRANSPORT_VEHICLE = {}, COLOR = {}, NAME = {} }, [400] = { LINE = {}, COLOR = {}, NAME = {} } }
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
    r = g("makeEntitySetColorCmd", 186664, '"1794171956-997000-Philipp"')
    check(r is not None and "colour" in r["err"] and "DESYNC" not in r["err"], "#168: a player's colour on a track segment here: skipped", r and r["err"])
    check(g("makeEntitySetColorCmd", 186700, '"1794171956-997000-Philipp"') is None, "a player's colour on a vehicle: goes on")
    check(g("makeEntitySetColorCmd", 400, '"1794171956-997000-Philipp"') is None, "  on a line: goes on")
    check(g("makeEntitySetColorCmd", 186664, '"gsmod-1"') is not None, "  a game script's colour: checked as in 0.7.12")
    check(g("makeVehicleSellCmd", 186664, '"1794171956-997000-Philipp"') is None, "  other commands: as before")
    L.execute('ENV.MPFEVER_COLORANY = "0"')
    check(g("makeEntitySetColorCmd", 186664, '"1794171956-997000-Philipp"') is None and g("makeEntitySetColorCmd", 186664, '"gsmod-1"') is not None,
          "MPFEVER_COLORANY=0: game scripts' colours only, as in 0.7.12")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
