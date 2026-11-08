"""Test of #156's fix (0.7.11): a custom entity's move, state or removal on an entity that is not one on this game is skipped
(mod/mpfever_1/content/mpfever_bridge.script.lua, executeActionOnce; C.CUSTOM_ENTITY_FNS in mpfever_common.lua).

Julian's game, 2026-11-08 18:07: the host's L-Signalsystem mod made a preview object (makeCustomEntityCreateCmd, id 135865 on
the host), moved it (makeCustomEntityUpdateTransformationCmd) and took it away; the commands name the host's id. On Julian's
game that id was no custom entity; the engine applied the move all the same (an entity missing in both of its states passes
its check: revision 0 against 0) and stopped on "Engine.h:323 ecs::Engine::GetComponentDataIndex 'it != components.end()'"
(BoundingVolume). Now such a command on an entity that does not exist here, or has no BOUNDING_VOLUME, is skipped with a
reason that is no "DESYNC" (it would have been refused, or stopped the game); one on a real custom entity goes on as before.
MPFEVER_CUSTOMGUARD=0: as before. Needs lupa for the Lua part. Run: python tests/test_customguard0711.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
com = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


check("C.CUSTOM_ENTITY_FNS = { makeCustomEntityUpdateTransformationCmd = true, makeCustomEntityUpdateStateCmd = true, makeCustomEntityDestroyCmd = true }" in com,
      "the custom entity's move, state and removal (not its creation)")
i = src.index("if C.CUSTOM_ENTITY_FNS[a.fn] and type(a.args) == \"table\"")
blk = src[i:src.index("\n\tend\n", i) + 6]
check('os.getenv("MPFEVER_CUSTOMGUARD") ~= "0"' in blk, "MPFEVER_CUSTOMGUARD=0: as before")
check("DESYNC" not in blk and "return result" in blk, "  skipped with a reason that is no DESYNC (no reload for it)")
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
LOGS = {}
log = function(s) LOGS[#LOGS + 1] = s end
C = { CUSTOM_ENTITY_FNS = { makeCustomEntityUpdateTransformationCmd = true, makeCustomEntityUpdateStateCmd = true, makeCustomEntityDestroyCmd = true } }
ENTS = { [10] = { BOUNDING_VOLUME = {} }, [11] = { NAME = {} } }
api = { type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = { entityExists = function(e) return ENTS[e] ~= nil end, getComponent = function(e, ct) return ENTS[e] and ENTS[e][ct] or nil end } }
function guard(a)
	local result = { success = false }
''' + blk + '''
	return nil
end
''')
    r = L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 135865 }, uid = "marcu:362" })')
    check(r is not None and "is not one here" in r["err"], "a move of an entity that is not here: skipped", r and r["err"])
    r = L.eval('guard({ fn = "makeCustomEntityDestroyCmd", args = { 11 }, uid = "x:1" })')
    check(r is not None, "  a removal of an entity that is no custom entity here (no BOUNDING_VOLUME): skipped")
    check(L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 10 }, uid = "x:2" })') is None, "a real custom entity: goes on")
    check(L.eval('guard({ fn = "makeCustomEntityCreateCmd", args = { 5985 }, uid = "x:3" })') is None, "  a creation: goes on")
    check(L.eval('guard({ fn = "makeVehicleSellCmd", args = { 135865 }, uid = "x:4" })') is None, "  other commands: their own checks, as before")
    L.execute('ENV.MPFEVER_CUSTOMGUARD = "0"')
    check(L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 135865 }, uid = "x:5" })') is None, "MPFEVER_CUSTOMGUARD=0: as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
