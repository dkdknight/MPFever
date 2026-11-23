"""Offline test of #475/#476 (0.9.6, mod/mpfever_1/content/mpfever_common.lua C.focusUnsafe / C.installFocusGuard, called by
mpfever_bridge.script.lua (the game scripts' interface state) and mpfever_ui.script.lua (the windows' state); switch
MPFEVER_FOCUSGUARD).

#475/#476 (2026-11-22, ger4l client of User, 0.9.5, one company per player, about 40 mods): ger4l's game stopped twice and
User's once within six minutes, each time on a click on one of the game's notification popups: notification_popups.tl:140 ->
notification_util.tl:450 api.gui.camera.focusEntity -> util.cpp:195 GetBoundingSphereFromBVAndMI, "Assertion
'!mil.fatInstances.empty()' failed". The camera was sent to an entity whose model list has no full model. Now the camera is not
sent to such an entity (the selection still goes), and the log says which, once each; any other entity as before.

The game's camera is modelled as the engine behaves: it stops (a Lua error here) on an entity whose model list has no full
model. Repro: without the guard (MPFEVER_FOCUSGUARD=0) a click on such an entity stops the game. Fix: with it, nothing stops.
Needs lupa (pip install lupa). Run: python tests/test_focusguard096.py
"""
import os
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def read(n):
    return open(os.path.join(CONTENT, n), encoding="utf-8").read().replace("\r\n", "\n")


common, bridge, ui = read("mpfever_common.lua"), read("mpfever_bridge.script.lua"), read("mpfever_ui.script.lua")
a = common.index("-- (0.9.6, #475 #476) Whether the game would stop")
b = common.index("-- one protocol line: kind TAB from TAB payload")
block = common[a:b]

SETUP = r'''
C = {}
ENV = {}
os.getenv = function(k) return ENV[k] end
package.loaded["mpfever_focus_guard"] = nil
FOCUSED, LOGGED = {}, {}
local function vec(n) return { size = function() return n end } end
-- entities: 10 a model list without full models (thin ones only: a group of trees), 11 a vehicle with its models,
-- 12 no model list at all (a line), 13 a model list read as a table only, empty
COMP = {
  [10] = { MIL = { fatInstances_native = vec(0), thinInstances_native = vec(40) }, NAME = { name = "Forest" } },
  [11] = { MIL = { fatInstances_native = vec(3) }, NAME = { name = "Bus 1" }, TV = {} },
  [12] = { LINE = {} },
  [13] = { MIL = { fatInstances = {} }, CON = {} },
}
api = {
  type = { ComponentType = { MODEL_INSTANCE_LIST = "MIL", NAME = "NAME", TRANSPORT_VEHICLE = "TV", CONSTRUCTION = "CON",
    TOWN_BUILDING = "TB", STATION = "ST", SIM_BUILDING = "SB", BASE_EDGE = "BE", LINE = "LINE", TOWN = "TOWN" } },
  engine = { getComponent = function(e, k) local c = COMP[e]; return c and c[k] or nil end },
  gui = { camera = {} },
}
-- the game's camera: it stops on a model list without a full model (GetBoundingSphereFromBVAndMI's assertion)
api.gui.camera.focusEntity = function(e)
  local c = COMP[e]
  local mil = c and c.MIL
  if mil then
    local n = mil.fatInstances_native and mil.fatInstances_native:size() or #mil.fatInstances
    if n == 0 then error("Assertion '!mil.fatInstances.empty()' failed") end
  end
  FOCUSED[#FOCUSED + 1] = e
end
-- notification_util.tl's onClick: the camera first, then the selection
function CLICK(e)
  local ok, err = pcall(function() api.gui.camera.focusEntity(e) end)
  return ok, tostring(err)
end
function say(s) LOGGED[#LOGGED + 1] = s end
'''


def runtime():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(SETUP + block)
    return L


# ---- repro: the guard off, a click on the forest stops the game
L = runtime()
L.execute('ENV.MPFEVER_FOCUSGUARD = "0"')
check(L.eval("C.installFocusGuard(say)") == "off (MPFEVER_FOCUSGUARD=0)", "MPFEVER_FOCUSGUARD=0: not installed")
ok, err = L.eval("CLICK(10)")
check(not ok and "fatInstances" in err, "repro #475: the camera sent to a model list without a full model stops the game", err)

# ---- fix
L = runtime()
check(L.eval("C.installFocusGuard(say)") == "on", "installed")
check(L.eval("C.focusUnsafe(10)") is True and L.eval("C.focusUnsafe(13)") is True, "a model list without full models is unsafe (native vector or table)")
check(L.eval("C.focusUnsafe(11)") is False and L.eval("C.focusUnsafe(12)") is False and L.eval("C.focusUnsafe(99)") is False,
      "  a vehicle with its models, an entity without a model list, an unknown one: safe")
ok, err = L.eval("CLICK(10)")
check(ok, "fix: the click on that entity no longer stops the game", err)
check(L.eval("#FOCUSED") == 0, "  the camera is not sent there")
check(L.eval("#LOGGED") == 1 and "entity 10" in L.eval("LOGGED[1]") and "'Forest'" in L.eval("LOGGED[1]"), "  the log says which entity, with its name", L.eval("LOGGED[1]"))
L.eval("CLICK(10)")
check(L.eval("#LOGGED") == 1, "  once each")
ok, _ = L.eval("CLICK(13)")
check(ok and L.eval("#FOCUSED") == 0 and "CONSTRUCTION" in L.eval("LOGGED[2]"), "  an empty table read the same way, its kind in the log")
ok, _ = L.eval("CLICK(11)")
check(ok and L.eval("FOCUSED[1]") == 11, "any other entity: the camera goes there as before")
ok, _ = L.eval("CLICK(12)")
check(ok and L.eval("FOCUSED[2]") == 12, "  an entity without a model list too")
check(L.eval("C.installFocusGuard(say)") == "on (already)", "installed once per state (never wrapped twice)")
L.execute("COMP[10] = nil")
check(L.eval("select(1, CLICK(10))") and L.eval("FOCUSED[3]") == 10, "  the wrapper calls the game's own function, not itself")
L.execute("api.gui.camera = nil")
check(L.eval("C.installFocusGuard(say)") == "no camera in this state", "a state without a camera: nothing done")

# ---- the sources
check("pcall(C.installFocusGuard, log)" in bridge and bridge.index("pcall(C.installFocusGuard, log)") > bridge.index("local okGs, errGs = pcall(G.installGsMods)"),
      "the bridge installs it in the game scripts' interface state (the notification popups')")
check("pcall(C.installFocusGuard, log)" in ui and 'log("camera guard (windows): "' in ui, "the windows' state too")
check('os.getenv("MPFEVER_FOCUSGUARD") == "0"' in block, "switch MPFEVER_FOCUSGUARD=0")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
