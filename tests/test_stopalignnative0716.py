"""Offline test: a street stop whose script form would shape the ground here otherwise than the stop tool did on its builder's game
is replayed as a script's build, which the towns ignore (0.7.16, issues #177-#180; G.stopTownDiff and replayStop in
mpfever_bridge.script.lua).

#177-#180 (JohnMenssing's game on the map Mittellandkanal, 2026-11-09): every resynchronisation followed one of the host's bus
stops. The other game replayed it in the script form (accepted by the engine's verdict), which re-laid the town street and
aligned its terrain there only: "TOWN STATS DIFFER" ar 0.000/0.416, al 0.000/0.084, ar 0.000/0.195 (the builder's stop tool: 0),
3 stops of 4, the host's game reloaded after each.
  - G.stopTownDiff, run through lupa: the terrain alignment added/removed and the trees/rocks taken away read from the dry run's
    proposal data (api.engine.util.town, as the towns' script), compared with the builder's numbers (a.ts) within
    SIM.townClose's margin (0.05, or 1e-5 of big volumes); nil when they agree, "al 0.000/0.416" when not; unreadable or not
    shipped values left out;
  - replayStop: read on the form the engine accepts, before the refusal branch and the send; on a street whose builder left the
    towns alike (its numbers all 0, G.stopNoTown) and whose replay would not, the form is made again at once as a script's
    build (not initiated by a player: the towns ignore it, as the stops on bridges since 0.5.x). Not the engine's conversion of
    the tool's build: John's six stops gave the same numbers by it (every form aligns alike, only the tool's own build does
    not). Decided once (plan.noTown), not for the stops placed again after a street build (plan.after); a builder whose own
    build moved ground: as before. MPFEVER_STOPNOTOWN=0: as in 0.7.15;
  - the autotest replayfile announces each act's builder numbers, so a game that replays real acts compares its own.
Needs lupa (pip install lupa). Run: python tests/test_stopalignnative0716.py
"""
import os, sys

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


src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = src.index("G.stopTownDiff = function(a, pd)")
fn = src[i:src.index("\nend\n", i) + 5]
i2 = src.index("G.stopDryVerdict = function(sp, ctx)")
verdict = src[i2:src.index("\nend\n", i2) + 5]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
G = {}
C = { ser = function() return "" end, marshal = function(x) return x end }
ALIGN = {}
REMOVAL = {}
api = { engine = { util = {
    proposal = { makeProposalData = function(sp, ctx) return PD end },
    town = {} } } }
-- (the game's functions are not all Lua functions: callable objects here, as the first version of 0.7.16 read nothing in the
-- game when it asked type(fn) == "function")
local function callable(f) return setmetatable({}, { __call = function(_, ...) return f(...) end }) end
api.engine.util.town.getTerrainAlignmentImpact = callable(function(pd) if ALIGN == "error" then error("no") end return ALIGN end)
api.engine.util.town.getAutoRemovalEntityImpact = callable(function(pd) return REMOVAL end)
''' + fn + verdict)
run = L.eval("function(code) return assert(load(code))() end")

print("the dry run's numbers against the builder's")
zero = "{ al = 0, ar = 0, tr = 0, rk = 0, ba = 0, br = 0, tv = 0 }"
run("ALIGN = { [7] = { 0, 0.416 } }; REMOVAL = {}")
check(run(f"return G.stopTownDiff({{ ts = {zero} }}, {{}})") == "ar 0.000/0.416",
      "#177-#180's first stop: the builder aligned nothing, the script form here 0.416 removed: \"ar 0.000/0.416\"")
run("ALIGN = { [3] = { 0.03, 0.02 }, [9] = { 0.017, 0.027 } }")
check(run("return G.stopTownDiff({ ts = { al = 0.047, ar = 0.047 } }, {})") is None,
      "summed over the towns, the same as the builder's within the margin (al 0.047 both, the stop that matched): nil")
run("ALIGN = { [1] = { 0.04, 0 } }")
check(run(f"return G.stopTownDiff({{ ts = {zero} }}, {{}})") is None, "0.04 against 0: within SIM.townClose's 0.05, nil")
run("ALIGN = { [1] = { 100000, 0 } }")
check(run("return G.stopTownDiff({ ts = { al = 100000.5, ar = 0 } }, {})") is None, "a big volume: 1e-5 of it as margin")
run("ALIGN = {}; REMOVAL = { [2] = { 3, 0 } }")
check(run(f"return G.stopTownDiff({{ ts = {zero} }}, {{}})") == "tr 0.000/3.000", "trees taken away here only: \"tr 0.000/3.000\"")
run("ALIGN = 'error'; REMOVAL = {}")
check(run(f"return G.stopTownDiff({{ ts = {zero} }}, {{}})") is None, "the alignment not readable here: left out (nil)")
run("ALIGN = { [1] = { 0, 1 } }")
check(run("return G.stopTownDiff({ ts = { al = 0 } }, {})") is None, "a number the builder did not ship (ar): left out")
check(run("return G.stopTownDiff({}, {})") is None and run("return G.stopTownDiff({ ts = {} }, nil)") is None,
      "no builder numbers or no proposal data: nil")
run("PD = { errorState = { critical = false } }")
check(run("local c, m, pd = G.stopDryVerdict({}, {}) return pd == PD") is True, "G.stopDryVerdict hands its proposal data back")

print("replayStop")
rst = src[src.index("local function replayStop(a, plan, variant)"):]
rst = rst[:rst.index("\nend\n")]
b = rst.index("local okV, crit, msgs, pd = pcall(G.stopDryVerdict, sp, sContext(not plan.after and a or nil, plan.cleanup))")
k = rst.index("local okD, diff = pcall(G.stopTownDiff, a, pd)")
r = rst.index("if okV and crit then", k)
d = rst.index("local before = stopCount()")
f = rst.index("replaySend(cmd, function(res, success)")
check(b < k < r < d < f, "read after the engine's verdict, before the refusal branch, the stop counts and the send")
cond = rst[rst.rindex("if okV and not crit", 0, k):k]
for part, name in [("not crit", "only for a form the engine accepts (a refusal takes its own way)"),
                   ("not plan.after", "not for the stops placed again after a street build"),
                   ("not plan.noTown", "decided once (the form made again is not read again)"),
                   ('type(a.ts) == "table"', "only with the builder's numbers"),
                   ('os.getenv("MPFEVER_STOPNOTOWN") ~= "0"', "MPFEVER_STOPNOTOWN=0: as in 0.7.15"),
                   ("c.type or 0) == 0", "a street (a bridge or a tunnel has its own way since 0.5.x)"),
                   ("G.stopNoTown(a)", "only when the builder's build left the towns alike (its numbers all 0)")]:
    check(part in cond, "  " + name)
blk = rst[k:r]
check("plan.noTown = true" in blk and "return replayStop(a, plan, variant)" in blk and "G.replayNativeStop" not in blk,
      "  numbers that differ: the form made again at once, as a script's build (no conversion: every form aligns alike)")
pil = rst[rst.index("local pi = "):]
pil = pil[:pil.index("\n")].strip()
check("or plan.noTown) and G.stopNoTown(a))" in pil, "the form made again is not initiated by a player (the towns ignore it)")
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
f2 = L2.eval("function(ctype, noTown, zero) local a = {} local c = { type = ctype } local plan = { noTown = noTown } "
             "local G = { stopNoTown = function() return zero end } " + pil + " return pi end")
check(f2(0, True, True) is False, "  a street, numbers that differ, the builder's all 0: not a player's build")
check(f2(0, None, True) is True, "  a street whose numbers agree: a player's build, as before")
check(f2(0, True, False) is True, "  a builder whose build moved ground: a player's build, as before")
check(f2(1, None, True) is False, "  a bridge whose builder left the towns alike: as since 0.5.x")

print("autotest replayfile")
rf = src[src.index("local function runReplayFile(p)"):]
rf = rf[:rf.index("\nend\n")]
check('if type(a.ts) == "table" and os.getenv("MPFEVER_ALIGNCHECK") ~= "0" then pcall(G.townExpect, a) end' in rf
      and rf.index("pcall(G.townExpect, a)") < rf.index("pcall(replayNative, a, 1)"),
      "each act's builder numbers announced before its replay (compared like a peer's)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
