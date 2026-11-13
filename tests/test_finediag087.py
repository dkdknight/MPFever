"""Offline test: the fine drift diagnostic of the 0.8.7 diagnostic build (mod/mpfever_1/content/mpfever_finediag.lua, the bridge's
update, tools/finediag_diff.py; switch MPFEVER_FINEDIAG=1, off by default).

  - at every step: every aircraft's moving state (MOVE_PATH_AIRCRAFT, AIRCRAFT), every number exact; the animals' sums; the
    persons and cargo every 25 steps; in a ring;
  - when the mod keeps a drift (native_drift.txt changes), the ring is written to finediag_<check>.txt;
  - two games' files compared by the tool: the first step that differs, the aircraft and the number;
  - the bridge loads nothing of it without MPFEVER_FINEDIAG=1; the module is in _content.json.
Needs lupa (pip install lupa). Run: python tests/test_finediag087.py
"""
import io, json, os, sys, contextlib

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CONTENT = os.path.join(ROOT, "mod", "mpfever_1", "content")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import finediag_diff

fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


mod = open(os.path.join(CONTENT, "mpfever_finediag.lua"), encoding="utf-8").read()
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")

GAME = r'''
FILES = {}
LOGS = {}
T = 1000
SKEW = SKEW or 0
local function vec(x, y, z) return { x = x, y = y, z = z } end
CT = { MOVE_PATH_AIRCRAFT = 1, AIRCRAFT = 2, ANIMAL = 3, MOVE_PATH = 4, SIM_ENTITY_MOVING = 5, SIM_ENTITY_AT_VEHICLE = 6,
  SIM_ENTITY_AT_TERMINAL = 7, SIM_ENTITY_AT_BUILDING = 8, SIM_ENTITY_IDLE = 9, SIM_PERSON_AT_VEHICLE = 10, SIM_PERSON = 11, SIM_CARGO = 12 }
local byName = {}
for k, v in pairs(CT) do byName[v] = k end
ENTS = { MOVE_PATH_AIRCRAFT = { 701, 702 }, AIRCRAFT = { 701, 702 }, ANIMAL = { 900, 901, 902 }, SIM_PERSON = { 5, 6 }, SIM_ENTITY_MOVING = { 5 } }
api = { type = { ComponentType = CT }, engine = {} }
function api.engine.getComponent(e, ct)
  local step = (T - 1000) / 200
  if ct == CT.MOVE_PATH_AIRCRAFT then
    local sp = 50 + e + step * 0.5
    if e == 702 and step >= 30 then sp = sp + SKEW end
    return { speed = sp, speed0 = sp - 0.5, brakeDecel = 1.5, pathPos = { edgeIndex = 3, pos = step * 2.25, pos01 = 0.25 },
      pathPos0 = { edgeIndex = 3, pos = step * 2, pos01 = 0.2 }, state = 0, pathState = 1,
      aircraftState = { flightState = 2, cruiseAlt = 900, gear = false, dyn = { a = 1.25, v = sp } },
      path0 = { edges = { 1, 2, 3 }, endOffset = 0 }, path2 = { edges = {}, endOffset = 0 }, path1 = {} }
  elseif ct == CT.AIRCRAFT then
    return { pathIndex = 0, reservedFrom = -1, reservedTo = -1, reservedTakeOffRunway = false }
  elseif ct == CT.ANIMAL then
    return { worldPosition = vec(e + step, e * 2, 3), targetCoord = vec(1, 2), movementSpeed = 0.75, movementType = 1 }
  elseif ct == CT.SIM_PERSON then
    return { walkSpeed = 1.25, modelIdPerson = e }
  elseif ct == CT.SIM_ENTITY_MOVING then
    return { expectedArrivalTime = 4000 + step, lineStop0 = 1, lineStop1 = 2 }
  end
  return nil
end
local R = { entitiesWith = function(name) local r = {} for i, e in ipairs(ENTS[name] or {}) do r[i] = e end return r end }
local IO = { open = function(path, mode)
  if mode == "rb" then
    if FILES[path] == nil then return nil end
    local s = FILES[path]
    return { read = function() return s end, close = function() end }
  end
  local buf = {}
  return { write = function(_, ...) for _, x in ipairs({ ... }) do buf[#buf + 1] = tostring(x) end end,
    close = function() FILES[path] = table.concat(buf) end }
end }
E = { api = api, log = function(s) LOGS[#LOGS + 1] = s end, gameTime = function() return T end,
  C = { IO = IO, DIR = "D", marshal = function(v) return v end }, R = R, BS = "/", NL = "\n" }
'''


def run_game(skew, steps=60, drift_at=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("SKEW = " + repr(skew) + "\n" + GAME)
    M = L.execute(mod)
    L.globals().M = M
    L.execute("FD = M.init(E)")
    for i in range(steps):
        if drift_at is not None and i == drift_at:
            L.execute('FILES["D/native_drift.txt"] = "57\\n"')
        L.execute("M.step(FD); M.step(FD); T = T + 200")   # (twice at one game time: noted once)
    return L


A = run_game(0.0, drift_at=40)
B = run_game(1e-9, drift_at=40)
fa = A.eval('FILES["D/finediag_57.txt"]')
fb = B.eval('FILES["D/finediag_57.txt"]')
check(fa is not None and fb is not None, "the ring written to finediag_<check>.txt when the mod keeps a drift")
check(A.eval("FD.count") == 60, "one entry a step, a step noted once even when update runs twice at one game time", A.eval("FD.count"))
logs = "\n".join(A.eval("LOGS")[i] for i in range(1, len(A.eval("LOGS")) + 1))
check("fine diagnostic: on" in logs and "finediag_57.txt written" in logs, "said in the log", logs[:200])
check("A 701 speed=751 " in fa and "pathPos0.pos01=0.20000000000000001" in fa and "aircraftState.dyn.v=751" in fa and "ac.reservedTo=-1" in fa, "every aircraft's numbers, nested ones too, exact (%.17g)")
check("N 3 " in fa and "\na 900 " in fa, "the animals' sums and each one's numbers")
check("P SIM_ENTITY_MOVING 1 " in fa and "SIM_PERSON 2 " in fa, "the persons and cargo by state")
check(fa.count("\nP ") == 2, "  at the first step, then every 25 steps (MPFEVER_FINEDIAG_PERSONS): twice in the 48 steps written", fa.count("\nP "))

tmp = os.path.join(HERE, "_finediag_tmp")
os.makedirs(tmp, exist_ok=True)
pa, pb = os.path.join(tmp, "a.txt"), os.path.join(tmp, "b.txt")
open(pa, "w", encoding="utf-8").write(fa)
open(pb, "w", encoding="utf-8").write(fb)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    res = finediag_diff.compare(pa, pb)
text = buf.getvalue()
check(res is not None and res[0] == str(1000 + 30 * 200), "the tool: the first step that differs (the 31st)", res)
check(res is not None and res[1] == ["A702"], "  the aircraft that differs, and nothing else at that step", res and res[1])
check("speed:" in text and "speed0:" in text and "aircraftState.dyn.v:" in text, "  its numbers that differ, both values", text[-400:])
same = run_game(0.0, drift_at=40).eval('FILES["D/finediag_57.txt"]')
open(pb, "w", encoding="utf-8").write(same)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    res2 = finediag_diff.compare(pa, pb)
check(res2 is None and "no difference" in buf.getvalue(), "two alike games: no difference")
for p in (pa, pb):
    os.remove(p)
os.rmdir(tmp)

# without a new drift request: nothing written
C = run_game(0.0, drift_at=None)
check(C.eval('FILES["D/finediag_57.txt"]') is None, "no drift kept: no file")

# the bridge: loaded only with MPFEVER_FINEDIAG=1
i = bridge.index("the fine drift diagnostic: every aircraft's moving state")
seg = bridge[i:i + 1500]
check('if os.getenv("MPFEVER_FINEDIAG") == "1" then' in seg and seg.index('os.getenv("MPFEVER_FINEDIAG") == "1"') < seg.index("ug_require"),
      "the bridge: the module loaded only with MPFEVER_FINEDIAG=1")
check("SIM.fine = false" in seg, "  without it: never asked again")
content = json.load(open(os.path.join(ROOT, "mod", "mpfever_1", "_content.json"), encoding="utf-8"))
check("mpfever_finediag.lua" in content["files"], "the module listed in _content.json (the game loads it)")
native = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read()
check("FpuDiag" in native and 'GetEnvironmentVariableA("MPFEVER_FPUDIAG"' in native, "native: every thread's floating-point control, only with the switch")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
