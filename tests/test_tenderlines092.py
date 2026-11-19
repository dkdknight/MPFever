"""Offline test: the tenders' test of two towns already linked by a passenger line looks at every direct line on build 40444
(0.9.2, MPFEVER_TENDERLINES; W.connected in mod/mpfever_1/content/mpfever_feat_tenders.lua).

Build 40444 (2026-11-19) marks subvention_util.areTownsConnected deprecated ("use getLinesConnectingTowns"), and the game's own
passenger offer now looks at every direct passenger line between the two towns. The tenders kept the first line found: two
towns linked by a second line with vehicles, the first having none, were offered a passenger tender. Now every line is looked
at when the game has getLinesConnectingTowns; on 40425 (no such function) as before.
mpfever_feat_tenders.lua is run through lupa (Lua 5.2) with a mocked ug_require.
Run: python tests/test_tenderlines092.py
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


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


# towns 1 and 2: lines 301 (no vehicle) and 302 (vehicles), in that order; towns 3 and 4: line 303 (no vehicle) only
MOCK = """
HASVEH = { [301] = false, [302] = true, [303] = false }
LINES = { ["1|2"] = { 301, 302 }, ["3|4"] = { 303 } }
NEW = true
function ug_require(path)
  if path == "/game_mechanics/subventions/subvention_util.tl" then
    local su = { areTownsConnected = function(a, b) local l = LINES[a .. "|" .. b] return l and l[1] or nil end }
    if NEW then su.getLinesConnectingTowns = function(a, b) return LINES[a .. "|" .. b] or {} end end
    return su
  elseif path == "::/gui/main/cargo_util.tl" then
    return { hasLineVehicleWithCapacity = function(l, c) return HASVEH[l] == true end, getPassengerCargoTypeId = function() return 0 end }
  end
  error("module not found: " .. path)
end
"""


def load(env=None):
    if env is None:
        os.environ.pop("MPFEVER_TENDERLINES", None)
    else:
        os.environ["MPFEVER_TENDERLINES"] = env
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run(MOCK)
    L.globals().M = L.execute(open(os.path.join(CONTENT, "mpfever_feat_tenders.lua"), encoding="utf-8").read())
    return run


run = load("0")
check("the bug (MPFEVER_TENDERLINES=0, as before): towns linked by a second line with vehicles read as not linked",
      run("return M.world.connected(1, 2)") is False)
run = load()
check("the fix (40444): every direct line looked at, linked", run("return M.world.connected(1, 2)") is True)
check("  a pair whose only line has no vehicle: not linked", run("return M.world.connected(3, 4)") is False)
check("  no line: not linked", run("return M.world.connected(5, 6)") is False)
run("NEW = false")
check("40425 (no getLinesConnectingTowns): the first line, as before", run("return M.world.connected(1, 2)") is False)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
