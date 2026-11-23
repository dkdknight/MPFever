"""Offline test: a railroad crossing's type and a signal's one-way state changed from their windows (Transport Fever 3's build
40444) are replicated in a session (0.9.4, MPFEVER_WINREPLAY; U.winProps / U.winShip and the interface's sendCommand in
mod/mpfever_1/content/mpfever_ui.script.lua; C.winOf, C.winCommand, the act made from ui.log and executeActionOnce in
mod/mpfever_1/content/mpfever_bridge.script.lua).

The bug (autotest rcsig, 2026-11-19, then #444 #445): those windows make their build with
api.engine.util.proposal.makeRailroadCrossingProposal(crossing, type) / makeSignalTypeProposal(signal, oneWay) and send it with
makeWorldBuildProposalCmd. Shipped and rebuilt as any build, the crossing's new type was lost (the proposal's node2rcType) and the
signal's new object had no model: the old signal went and none came, on every game. 0.9.2 refused them in a session ("cannot be
changed in multiplayer yet").
The fix: the proposal is marked with what its window made it from; its build is shipped with that ("win" = { kind, ent, v }), and
every game makes the same proposal itself with the same function on its own world, then sends it with the shipped context and
flags (not rebuilt, not replayed as a tool's build, not checked by the 0.9.3 guard for objects without a model).

  part 1, the interface: the two functions' proposals marked with their entity and value (a signal's one-way state as 1/0), the
  build shipped with "win" (MPFEVER_WINREPLAY=0: refused as in 0.9.2, the bug kept);
  part 2, the bridge: "win" checked (kind, entity, value), copied into the act, never a tool's replay; the action made again by
  the window's own function with the shipped context and flags, its proposal this game's; a proposal that cannot be made here:
  refused with its reason; MPFEVER_WINREPLAY=0: nothing;
  part 3, the wiring of executeActionOnce: the window path before the shipped form's rebuild, the guard of 0.9.3 left out for it.
The autotest rcsig shows it in a game (both games: the crossing's new type, the signal one-way, in sync).
Needs lupa (pip install lupa). Run: python tests/test_winreplay094.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
br = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


# ---- part 1: the interface
w = ui[ui.index('U.winProps = setmetatable({}, { __mode = "k" })'):]
w = w[:w.index("-- (0.7.0) the debug factories are tagged too")]


def ui_runtime(env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; U = {}")
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute("""
    function isCallable(f) return type(f) == "function" end
    api = { engine = { util = { proposal = {
      makeRailroadCrossingProposal = function(ent, t) return { kind = "rc", ent = ent, t = t } end,
      makeSignalTypeProposal = function(ent, oneWay) return { kind = "sig", ent = ent, oneWay = oneWay } end } } } }""")
    L.execute(w)
    return L


L = ui_runtime()
L.execute("RC = api.engine.util.proposal.makeRailroadCrossingProposal(4711, 3); SG = api.engine.util.proposal.makeSignalTypeProposal(815, true); SG0 = api.engine.util.proposal.makeSignalTypeProposal(816, false)")
check("the crossing's proposal returned unchanged, marked with its crossing and type",
      L.eval("RC.t") == 3 and L.eval("U.winProps[RC].what") == "crossing" and L.eval("U.winProps[RC].ent") == 4711 and L.eval("U.winProps[RC].v") == 3)
check("the signal's: its signal and one-way state as 1 / 0",
      L.eval("U.winProps[SG].what") == "signal" and L.eval("U.winProps[SG].v") == 1 and L.eval("U.winProps[SG0].v") == 0)
check("shipped with { kind, ent, v }", L.eval("U.winShip(U.winProps[RC]).kind") == "crossing" and L.eval("U.winShip(U.winProps[SG]).ent") == 815
      and L.eval("U.winShip(U.winProps[SG]).v") == 1)
check("  nothing to ship without an entity or a value", L.eval("U.winShip({ what = 'signal' })") is None and L.eval("U.winShip(nil)") is None)
L0 = ui_runtime({"MPFEVER_WINREPLAY": "0"})
L0.execute("RC = api.engine.util.proposal.makeRailroadCrossingProposal(4711, 3)")
check("bug kept (MPFEVER_WINREPLAY=0): marked but not shipped, so refused as in 0.9.2", L0.eval("U.winProps[RC].what") == "crossing"
      and L0.eval("U.winShip(U.winProps[RC])") is None)
g = ui[ui.index("-- (0.9.2) a railroad crossing's or a signal's window build (see U.winProps)"):]
g = g[:g.index("-- notification events (popup sound, dismiss)")]
check("the interface's sendCommand: a marked build shipped with 'win', refused only when it cannot be (U.winShip nil)",
      "winMeta = okS and ship or nil" in g and "if what and not winMeta then" in g and "pcall(cb, nil, false, {})" in g)
check("  its act_req carries it", 'sendLine("act_req", { tok = U.tok, id = U.seq, fn = tag.name, args = margs, win = winMeta })' in ui)

# ---- part 2: the bridge
fns = br[br.index("C.winOf = function(x)"):br.index("local function buildCommand(fn, srcArgs, tries)")]


def br_runtime(env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; G = {}; SENT = {}")
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute("""
    api = { engine = { util = { proposal = {
      makeRailroadCrossingProposal = function(ent, t) if ent == 1 then return nil end return { kind = "rc", ent = ent, t = t, mine = true } end,
      makeSignalTypeProposal = function(ent, oneWay) return { kind = "sig", ent = ent, oneWay = oneWay, mine = true } end } } },
      cmd = { makeWorldBuildProposalCmd = function(p, ctx, a, b, c) return { p = p, ctx = ctx, flags = { a, b, c } } end } }
    C = { copy = function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end }
    C.rebuildArgs = function(fn, margs, opts)
      REBUILT = margs
      local args = {}
      for i = 1, margs.n do local m = margs[i] if type(m) == "table" and m.context then args[i] = "context of " .. m.context else args[i] = m end end
      return args, margs.n
    end""")
    L.execute(fns)
    return L


L = br_runtime()
check("'win' checked: a crossing or a signal, a whole entity and value", L.eval("C.winOf({ win = { kind = 'crossing', ent = 4711, v = 3 } }).ent") == 4711
      and L.eval("C.winOf({ win = { kind = 'bulldoze', ent = 1, v = 1 } })") is None and L.eval("C.winOf({ win = { kind = 'signal', ent = '1', v = 1 } })") is None
      and L.eval("C.winOf({})") is None and L.eval("C.winOf(nil)") is None)
L.execute("""A = { fn = "makeWorldBuildProposalCmd", win = { kind = "crossing", ent = 4711, v = 3 },
  args = { n = 5, { proposal = { shipped = true } }, { context = "the window's" }, false, true, true } }
CMD = C.winCommand(A)""")
check("the crossing's build made again here: the window's own function with its crossing and type, this game's proposal",
      L.eval("CMD.p.kind") == "rc" and L.eval("CMD.p.ent") == 4711 and L.eval("CMD.p.t") == 3 and L.eval("CMD.p.mine") is True)
check("  the shipped context and flags (false, true, true), the shipped proposal not rebuilt",
      L.eval("CMD.ctx") == "context of the window's" and list(L.eval("CMD.flags").values()) == [False, True, True] and L.eval("REBUILT[1]") is False)
L.execute("""B = { fn = "makeWorldBuildProposalCmd", win = { kind = "signal", ent = 815, v = 1 }, args = { n = 5, {}, { context = "x" }, false, false, true } }
CMDS = C.winCommand(B)
B0 = { fn = "makeWorldBuildProposalCmd", win = { kind = "signal", ent = 816, v = 0 }, args = { n = 5, {}, { context = "x" }, false, false, true } }
CMDS0 = C.winCommand(B0)""")
check("the signal's: one-way true for 1, false for 0", L.eval("CMDS.p.kind") == "sig" and L.eval("CMDS.p.oneWay") is True and L.eval("CMDS0.p.oneWay") is False)
r = L.eval("(function() local ok, e = pcall(C.winCommand, { fn = 'makeWorldBuildProposalCmd', win = { kind = 'crossing', ent = 1, v = 0 }, args = { n = 1 } }) return tostring(ok) .. ' ' .. tostring(e) end)()")
check("a proposal that cannot be made here: an error with its reason (the action refused, said in mod.log)", r.startswith("false") and "could not be made here" in r, r)
L0 = br_runtime({"MPFEVER_WINREPLAY": "0"})
check("MPFEVER_WINREPLAY=0: no window build in the bridge either", L0.eval("C.winOf({ win = { kind = 'crossing', ent = 4711, v = 3 } })") is None)

act = br[br.index('elseif p and kind == "act_req" then'):]
act = act[:act.index("send(\"act\", a)")]
check("the act made from ui.log carries 'win'", "local win = C.winOf and C.winOf(p)" in act and "if win then a.win = win end" in act)
ue = br[br.index("G.uiEdit = function(p)"):]
ue = ue[:ue.index("\nend\n")]
uo = br[br.index("G.uiObjBuild = function(p)"):]
uo = uo[:uo.index("\nend\n")]
check("  never replayed as a tool's build: G.uiEdit and G.uiObjBuild leave it out (on its maker and on every receiver, H.act)",
      "C.winOf and C.winOf(p) then return false end" in ue and "C.winOf and C.winOf(p) then return false end" in uo)

# ---- part 3: executeActionOnce
ex = br[br.index("local function executeActionOnce(a, sendCommand, useCallback, bind, done)"):]
ex = ex[:ex.index("-- (0.7.13, #148: a purchase the buying company could not pay")]
bc = br[br.index("local function buildCommand(fn, srcArgs, tries)"):]
bc = bc[:bc.index("\nend\n")]
check("executeActionOnce: a window build made by C.winCommand (buildCommand's window path) instead of the shipped form's rebuild",
      "local winBuild = isBuild and C.winOf(a) ~= nil" in ex and "winBuild and { { win = a } } or (isBuild and BUILD_TRIES" in ex
      and "pcall(C.winCommand, winAct)" in bc and bc.index("pcall(C.winCommand, winAct)") < bc.index("for _, t in ipairs(tries) do"))
check("  the rebuild's notes and the 0.9.3 guard (objects without a model) left out for it", "if winBuild then" in ex and "elseif isBuild then" in ex
      and ex.index("elseif isBuild then") < ex.index('os.getenv("MPFEVER_EOGUARD") ~= "0"'))
check("  said in mod.log", "made here as its window made it" in ex)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
