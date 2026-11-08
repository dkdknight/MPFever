"""Test of #156's and #158's fixes (0.7.11): a mod's custom entity command on an entity that is no custom entity on this game is
not sent (mod/mpfever_1/content/mpfever_bridge.script.lua: executeActionOnce for the replayed ones, DET.installModCmds for a
mod's own game script; C.notCustomEntity and C.CUSTOM_ENTITY_FNS in mpfever_common.lua).

#156, Julian's game, 2026-11-08 18:07: the host's L-Signalsystem mod made a preview object (makeCustomEntityCreateCmd, id 135865 on
the host), moved it (makeCustomEntityUpdateTransformationCmd) and took it away; the commands name the host's id. On Julian's
game that id was no custom entity; the engine applied the move all the same (an entity missing in both of its states passes
its check: revision 0 against 0) and stopped on "Engine.h:323 ecs::Engine::GetComponentDataIndex 'it != components.end()'"
(BoundingVolume).
#158, the same game at 18:33: the preview's id, 138059, was a node of Julian's tracks there (BaseNode, BoundingVolume...); the
mod's game script, hearing of the preview (its event "l_vorschau", es = {138059, 138058}), moved it on every game: the game
stopped again (GetComponentDataIndex, OctreeSystemNode of entity 138059).
Now such a command, on an entity that is missing here, or is a node, a segment, a construction... (C.CUSTOM_NOT), or (replayed
ones) has no bounding volume, is not sent, with a reason that is no "DESYNC"; one on a real custom entity goes on as before.
MPFEVER_CUSTOMGUARD=0: as before. Needs lupa for the Lua part. Run: python tests/test_customguard0711.py
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


check("C.CUSTOM_ENTITY_FNS = { makeCustomEntityUpdateTransformationCmd = true, makeCustomEntityUpdateStateCmd = true, makeCustomEntityDestroyCmd = true }" in com,
      "the custom entity's move, state and removal (not its creation)")
fns = com[com.index("C.CUSTOM_ENTITY_FNS = {"):]
fns = fns[:fns.index("\n")] + "\n"
i = com.index("C.CUSTOM_NOT = {")
nce = com[i:com.index("\n\treturn nil\nend\n", i) + len("\n\treturn nil\nend\n")]
check('"BASE_NODE", "BASE_EDGE", "CONSTRUCTION"' in nce, "  a node, a segment, a construction... is no custom entity")
i = src.index("if C.CUSTOM_ENTITY_FNS[a.fn] and type(a.args) == \"table\"")
blk = src[i:src.index("\n\tend\n", i) + 6]
check('os.getenv("MPFEVER_CUSTOMGUARD") ~= "0"' in blk and "C.notCustomEntity(a.args[1], true)" in blk, "replayed: MPFEVER_CUSTOMGUARD=0 as before; strict")
check("DESYNC" not in blk and "return result" in blk, "  skipped with a reason that is no DESYNC (no reload for it)")
check(i < src.index("local okm, missing = pcall(missingEntities, a.fn, a.args or {})"), "  checked before the command is made")
i = src.index("DET.mod = { hostOnly")
END = 'log("mod commands intercepted in the simulation (" .. C.ROLE .. ")")\nend\n'
mc = src[i:src.index(END, i) + len(END)]
check("local why = C.notCustomEntity(ct.e)" in mc and mc.index("local why = C.notCustomEntity(ct.e)") < mc.index("local tag = cmd ~= nil and tags[cmd] or nil"),
      "a mod's own game script: checked before the rest of the simulation's mod commands")
try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed: the Lua part skipped")

MOCK = '''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
log = function(s) LOGS[#LOGS + 1] = s end
C = { ACTIVE = true, ROLE = "client" }
ENTS = { [10] = { BOUNDING_VOLUME = {} }, [11] = { NAME = {} },
  [138059] = { BASE_NODE = {}, BASE_NODE_CONFIG = {}, TRANSPORT_NETWORK = {}, BOUNDING_VOLUME = {} },
  [200] = { CONSTRUCTION = {}, BOUNDING_VOLUME = {} } }
api = { type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = { entityExists = function(e) return ENTS[e] ~= nil end,
    getComponent = function(e, ct) assert(ct ~= nil); return ENTS[e] and ENTS[e][ct] or nil end } }
'''
if lupa:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK + fns + nce + '''
function guard(a)
	local result = { success = false }
''' + blk + '''
	return nil
end
''')
    r = L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 135865 }, uid = "marcu:362" })')
    check(r is not None and "not here" in r["err"], "#156: a move of an entity that is not here: skipped", r and r["err"])
    r = L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 138059 }, uid = "marcu:148" })')
    check(r is not None and "base_node" in r["err"], "#158: a move of an id that is a track node here: skipped", r and r["err"])
    r = L.eval('guard({ fn = "makeCustomEntityDestroyCmd", args = { 11 }, uid = "x:1" })')
    check(r is not None, "  a removal of an entity that has no bounding volume here: skipped")
    check(L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 10 }, uid = "x:2" })') is None, "a real custom entity: goes on")
    check(L.eval('guard({ fn = "makeCustomEntityCreateCmd", args = { 5985 }, uid = "x:3" })') is None, "  a creation: goes on")
    check(L.eval('guard({ fn = "makeVehicleSellCmd", args = { 135865 }, uid = "x:4" })') is None, "  other commands: their own checks, as before")
    L.execute('ENV.MPFEVER_CUSTOMGUARD = "0"')
    check(L.eval('guard({ fn = "makeCustomEntityUpdateTransformationCmd", args = { 135865 }, uid = "x:5" })') is None, "MPFEVER_CUSTOMGUARD=0: as before")

    def sim(env=None, role="client"):
        S = lupa.LuaRuntime(unpack_returned_tuples=True)
        S.execute(MOCK + fns + nce + '''
DET = {}
SENT = {}
CBS = {}
local function factory(name) return function(...) return { fn = name, args = { ... } } end end
api.cmd = { makeCustomEntityUpdateTransformationCmd = factory("makeCustomEntityUpdateTransformationCmd"),
  makeCustomEntityUpdateStateCmd = factory("makeCustomEntityUpdateStateCmd"), makeCustomEntityDestroyCmd = factory("makeCustomEntityDestroyCmd"),
  makeCustomEntityCreateCmd = factory("makeCustomEntityCreateCmd"), makeVehicleSellCmd = factory("makeVehicleSellCmd"),
  sendCommand = function(cmd, cb) SENT[#SENT + 1] = cmd.fn .. ":" .. tostring(cmd.args[1]) end }
function modSends(name, e) api.cmd.sendCommand(api.cmd[name](e, {}), function(res, ok) CBS[#CBS + 1] = ok end) end
''' + (f'ENV.MPFEVER_CUSTOMGUARD = "{env}"\n' if env else "") + f'C.ROLE = {repr(role) if role else "nil"}\n' + mc + "\nDET.installModCmds()\n")
        for e in (138059, 135865, 10):
            S.execute(f'modSends("makeCustomEntityUpdateTransformationCmd", {e})')
        S.execute('modSends("makeCustomEntityCreateCmd", 5985)')
        S.execute('modSends("makeVehicleSellCmd", 138059)')
        return list(S.eval("SENT").values()), list(S.eval("CBS").values()), list(S.eval("LOGS").values())

    sent, cbs, logs = sim()
    check("makeCustomEntityUpdateTransformationCmd:138059" not in sent, "#158: the mod's script moving a track node of this game: not sent", sent)
    check("makeCustomEntityUpdateTransformationCmd:135865" not in sent, "  nor an entity that is not here")
    check(cbs[:2] == [False, False], "  its callback told it was not done", cbs)
    check(any("not sent: a base_node here" in s for s in logs), "  said in the log")
    check("makeCustomEntityUpdateTransformationCmd:10" in sent, "a real custom entity: sent")
    check("makeCustomEntityCreateCmd:5985" in sent and "makeVehicleSellCmd:138059" in sent, "  other commands: sent as before")
    sent, _, _ = sim(env="0")
    check("makeCustomEntityUpdateTransformationCmd:138059" in sent, "MPFEVER_CUSTOMGUARD=0: sent as before")
    sent, _, _ = sim(role="solo")
    check("makeCustomEntityUpdateTransformationCmd:138059" in sent, "  out of a session: sent as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
