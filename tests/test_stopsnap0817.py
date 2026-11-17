"""Offline test (0.8.17, #406): the replay of a stop reads what it needs of the segment before its dry run, never in the dry run's
callback (G.replayNativeStop in mpfever_bridge.script.lua, switch MPFEVER_STOPSNAP).

alexg's game crashed at 00:09:28 (access violation at TransportFever3.exe+0x2ffd19b, the getter of a component's field) on
Havoc181:1424, a stop on track segment 150586: build() read c.roadTemplate in the dry run's callback, frames after getComponent gave
c, a view into the engine's storage of segments; meanwhile an industry of the game had added its streets and the storage moved.
G.replayNativeStop is taken from the real bridge and run through lupa with the engine mocked: the segment's component is a view
that turns invalid ("freed") once the frame of the call is over (any read then raises, as the game's read crashed).
  - MPFEVER_STOPSNAP=0: the callback reads the freed view (the crash, reproduced);
  - now: nothing of the view is read after the dry run is sent, the build's command is made and sent, priced as before;
  - the same with a segment carrying stops already (the dry run without the removal).
Needs lupa. Run: python tests/test_stopsnap0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r"^G\.replayNativeStop = function\(a, plan\)\n.*?^end\n", src, re.S | re.M)
check("G.replayNativeStop found", m is not None)
if not m:
    sys.exit(1)

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG, SENT, FAILED, ASBEFORE = {}, {}, {}, {}
FREED = false
OBJN = 0
function log(s) LOG[#LOG + 1] = s end
function shortErr(e) return tostring(e) end
function toSim() end
function sContext() return {} end
function logRefusal() end
function replayStop() ASBEFORE[#ASBEFORE + 1] = "replayStop" end
function replayFailed(a, why) FAILED[#FAILED + 1] = why end
function replaySend(cmd, cb) SENT[#SENT + 1] = { cmd = cmd, cb = cb } end
C = { copy = function(t) return t end, errors = {},
      rebuildNativeWithConstruction = function(m, x, rm, variant) return { variant = variant } end }
R = { translateIn = function() return {} end }
local view = { type = 1, typeIndex = -1, roadTemplate = "standard.lua", node0 = 1, node1 = 2 }
local function makeView()
  local objs = {}
  for i = 1, OBJN do objs[i] = { 100 + i, 1 } end
  view.objects = objs
  return setmetatable({}, { __index = function(_, k)
    if FREED then error("read of a freed component view (" .. tostring(k) .. "): the game crashes here") end
    return view[k] end })
end
api = { type = { ComponentType = { BASE_EDGE = 5 } },
  engine = { getComponent = function(e, t) return makeView() end,
             util = { proposal = { makeSegmentsRemoveProposal = function(l)
               return { proposal = { removedSegments = { l[1] }, removedNodes = {} } } end } } },
  cmd = { makeWorldBuildProposalCmd = function(P, ctx, ign, pi, free) return { P = P, free = free } end } }
G = { waits = {} }
G.nowOrNext = function(f) f() end
G.stopObjsDiffer = function() return nil end
G.missingEdgeModel = function() return nil end
G.streetSignalDry = function() return false end
G.toolCosts = function() return true end
G.toolIgnoresErrors = function() return false end
G.stopNoTown = function() return false end
G.eoCount = function() return 7 end
G.gateSingle = function() end
G.eoCheckHold = function() end
G.groundProbe = function() end
G.eoDryRun = function(m, opts) DRYOPTS = opts return { dry = true }, nil, 1 end
'''


def run_case(off, objn):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_STOPSNAP = '0'")
    run(f"OBJN = {objn}")
    # G.eoDryRun returns (dry, n): the mock gives 2 values after the pcall's ok
    run("G.eoDryRun = function(m, opts) DRYOPTS = opts return { dry = true }, 1 end")
    run("""A = { uid = 'Havoc181:1424', args = { { proposal = { removedNodes = {} } } } }
PLAN = { E = 150586, objs = { 1 }, removeIdx = {}, seg = { comp = { roadTemplate = 'standard.lua', node0 = 1, node1 = 2 } } }
G.replayNativeStop(A, PLAN)""")
    sent_dry = run("return #SENT == 1 and SENT[1].cmd.dry == true")
    removeE = run("return DRYOPTS and DRYOPTS.removeE ~= nil")
    # the frame is over: the industry adds its streets, the view is freed; the dry run's answer comes (refused, two objects)
    run("FREED = true")
    okcb = run("""local ok, err = pcall(SENT[1].cb, { proposal = { proposal = { edgeObjectsToAdd = { 'o1', 'o2' } } } }, false)
return ok and 'ok' or tostring(err)""")
    built = run("return #SENT == 2 and SENT[2].cmd.P ~= nil")
    free = run("return #SENT == 2 and SENT[2].cmd.free == true")
    return sent_dry, removeE, okcb, built, free


sent_dry, removeE, okcb, built, free = run_case(True, 0)
check("MPFEVER_STOPSNAP=0: the dry run sent", sent_dry)
check("MPFEVER_STOPSNAP=0: the callback reads the freed view (the crash of #406)", okcb != "ok" and "freed component" in str(okcb), okcb)
sent_dry, removeE, okcb, built, free = run_case(False, 0)
check("now: the dry run sent, with the removal of the empty segment", sent_dry and removeE)
check("now: the callback reads nothing of the freed view", okcb == "ok", okcb)
check("now: the build's command made and sent, priced like the tool's (the same street template)", built and free)
sent_dry, removeE, okcb, built, free = run_case(False, 2)
check("a segment carrying stops already: the dry run without the removal", sent_dry and not removeE)
check("  and the build sent, nothing of the view read late", okcb == "ok" and built, okcb)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
