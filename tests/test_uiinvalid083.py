"""Offline test: a window's step that reads an entity another player's build took away no longer ends the game (0.8.3, #224,
MPFEVER_UIINVALID).

Report #224 (2026-11-11, Ren, one company for everybody): pc demolished a road depot while Ren's management window listed it. The
game's window (ManagerWindowContent, gui/line_vehicle_mgmt/manager_window.tl) reads each depot of its list with getComponent and
no check; the engine's "Invalid entity" went up through MPFever's react.onStep wrapper (mpfever_ui.script.lua), the interface's
root failed and the game closed. In a session such an error of a step is now left for that frame and logged.
The wrapper and U.swallowInvalid are taken from the real interface script and run through lupa (Lua 5.2).
Run: python tests/test_uiinvalid083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(UI, encoding="utf-8").read().replace("\r\n", "\n")
sw = re.search(r"\n(\tU\.swallowInvalid = function\(err\)\n.*?\n\tend\n)", src, re.S)
wr = re.search(r"\n(\t\tpcall\(function\(\)\n\t\t\tfor _, name in ipairs\(\{ \"onStep\", \"onStepTimer\" \}\) do\n.*?\n\t\t\tU\.reactWrapped = true\n\t\tend\)\n)", src, re.S)
if not sw or not wr:
    print("FAIL: U.swallowInvalid or the react.onStep wrapper not found in the interface script")
    sys.exit(1)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENVV = {}
os.getenv = function(k) return ENVV[k] end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
C = { ROLE = "client" }
U = { autoDepth = 0 }
STEPS = {}
react = { onStep = function(fn) STEPS[#STEPS + 1] = fn end, onStepTimer = function(fn) STEPS[#STEPS + 1] = fn end }
""" + sw.group(1) + wr.group(1) + """
function step(err)
  STEPS = {}
  react.onStep(function() if err then error(err) end return 1 end)
  local ok, e = pcall(STEPS[1])
  return ok, tostring(e)
end
""")
step = L.eval("step")

ok, err = step("Invalid entity")
check("#224: in a session, a step's \"Invalid entity\" is left for that frame (no error up to the game)", ok is True)
check("  said in ui_mod.log", "taken away by another player's build" in str(L.eval("LOG[1]")))
ok, err = step("attempt to index a nil value")
check("any other error of a step: raised, as before", ok is False and "nil value" in str(err))
check("a step without error: as before", step(None)[0] is True)
check("  and wrapped once (U.reactWrapped)", L.eval("U.reactWrapped") is True)
L.execute("C.ROLE = 'solo'")
check("alone (no session): raised, as the game does", step("Invalid entity")[0] is False)
L.execute("C.ROLE = 'host' ENVV.MPFEVER_UIINVALID = '0'")
check("MPFEVER_UIINVALID=0: raised, as before", step("Invalid entity")[0] is False)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
