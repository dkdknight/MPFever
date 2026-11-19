"""Offline test: with one company per player, a passenger contract is reached only by its company's lines (0.9.2,
MPFEVER_CONTRACTLINE; CO's wrapContractType in mod/mpfever_1/content/mpfever_co.lua).

A passenger contract (deliver_passengers) is reached when a trip between its two towns starts on a direct line
(OnStartedLineUsage): its lineEntity is that line, and its 2x income goes to that line's tickets. MPFever kept the ticket
events to the contract's company's lines, not the trips: any company's line reached any company's contract, which then
waited for tickets of a line that was not its company's. Build 40444 (2026-11-19) also keeps the first line found once the
contract is completed ("if not state.acceptedTime or state.completedTime then return"): a contract reached by another
company's line never paid its company. The trips on other companies' lines are now left out of the event.
mpfever_co.lua is run through lupa (Lua 5.2) with a mocked game API; the contract type is the game's 40444 logic.
Run: python tests/test_contractline092.py
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


# two companies (entities 11 and 22); line 101 is company 1's, line 202 company 2's; passengers 501 rides line 101, 502 line
# 202 (502 waits at a terminal: SIM_ENTITY_AT_TERMINAL); one passenger contract between the towns, accepted by company 2
GAME = """
PATH = "::/game_mechanics/subventions/deliver_passengers/deliver_passengers.script"
REF = PATH .. "@deliver_passengers"
LINEOF = { [501] = { v = 101 }, [502] = { t = 202 } }
api = {
  res = { genericRep = {
    getAllOfType = function(t) return t == "subvention" and { 7 } or {} end,
    get = function(id) return { data = { scriptFile = REF } } end } },
  engine = { getComponent = function(e, ct)
    if ct == 1 then return { player = (e == 101 and 11 or 22) } end
    if ct == 2 then return LINEOF[e] and LINEOF[e].v and { line = LINEOF[e].v } or nil end
    if ct == 3 then return LINEOF[e] and LINEOF[e].t and { line = LINEOF[e].t } or nil end
  end },
  type = { ComponentType = { PLAYER_OWNED = 1, SIM_ENTITY_AT_VEHICLE = 2, SIM_ENTITY_AT_TERMINAL = 3 } },
}
-- the type's script as build 40444 has it: a trip reaches an accepted contract not completed yet, the line kept
function loadType()
  game[PATH] = { deliver_passengers = {
    handleEvent = function(src, id, name, param, s)
      if name ~= "OnStartedLineUsage" then return end
      if not s.acceptedTime or s.completedTime then return end
      for _, el in ipairs(param.entities) do
        local sv = api.engine.getComponent(el[1], 2)
        local line = sv and sv.line or api.engine.getComponent(el[1], 3).line
        s.lineEntity = line
      end
    end } }
end
loaderHelper = { useFn = function(self, ref) if ref:sub(1, #REF) == REF and game[PATH] == nil then loadType() end end }
ug_require = function() error("not here") end
game = { ["::/game_mechanics/subventions/subventions.script"] = { handleEvent = function() end } }
REG = { mode = "separate", list = { { id = 1, ent = 11 }, { id = 2, ent = 22 } } }
LOG = {}
CONTRACT = { uid = 5, mpfOwner = 2, acceptedTime = 100 }
function trip(...)
  local ents = {}
  for _, p in ipairs({ ... }) do ents[#ents + 1] = { p, 0 } end
  return game[PATH].deliver_passengers.handleEvent("", "SimPersonSystem", "OnStartedLineUsage", { entities = ents }, CONTRACT)
end
"""


def make(co_src, env=None):
    if env is not None:
        os.environ["MPFEVER_CONTRACTLINE"] = env
    else:
        os.environ.pop("MPFEVER_CONTRACTLINE", None)
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run(GAME)
    L.globals().CO = L.execute(co_src)
    run("""ENV = { log = function(s) LOG[#LOG + 1] = s end, registry = function() return REG end, localCo = function() return 2 end, preload = true }
CO.installContracts(ENV)""")
    return run


def main():
    co_src = open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read()

    run = make(co_src, "0")
    run("trip(501)")
    check("the bug (MPFEVER_CONTRACTLINE=0, as before): company 1's line reaches company 2's contract", run("return CONTRACT.lineEntity") == 101,
          run("return CONTRACT.lineEntity"))
    run("CONTRACT.completedTime = 200; trip(502)")
    check("  and on 40444 it stays that line once completed: company 2 never gets the income", run("return CONTRACT.lineEntity") == 101)

    run = make(co_src)
    run("trip(501)")
    check("the fix: another company's line does not reach it", run("return CONTRACT.lineEntity") is None, run("return CONTRACT.lineEntity"))
    run("trip(501, 502)")
    check("  a trip on its own company's line does (another company's in the same event left out)", run("return CONTRACT.lineEntity") == 202,
          run("return CONTRACT.lineEntity"))
    run("CONTRACT.lineEntity = nil; trip(502)")
    check("  every trip on its own lines: the event as the game sent it", run("return CONTRACT.lineEntity") == 202)
    run("CONTRACT.mpfOwner = 1; CONTRACT.lineEntity = nil; trip(501)")
    check("  company 1's contract: reached by company 1's line", run("return CONTRACT.lineEntity") == 101)
    check("the line found as the game's script finds it (SIM_ENTITY_AT_VEHICLE, else SIM_ENTITY_AT_TERMINAL)",
          run("return CO.simLine(501)") == 101 and run("return CO.simLine(502)") == 202 and run("return CO.simLine(999)") is None)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
