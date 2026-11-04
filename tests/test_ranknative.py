"""Offline test: a company's passengers count in its rank (0.6.12, #125, #115).

The game gives a town's happiness statistics (api.engine.util.town.getTownHappinessStats) as a native object, not a Lua
table. PG.measure read them as tables only: no passenger of any line was ever counted, and companies that carry passengers
only (buses and trains) kept a score of 0 and rank 1 for good; a company carrying cargo to towns scored with its cargo only.

PG.measure and PG.tally run through lupa (Lua 5.2) with a mocked engine whose statistics objects answer "userdata" to type(),
as the game's do. Cases: passengers of two companies' lines in a town give both a score; cargo still counts; an entry of the
"Other" line (no line entity) is left aside; MPFEVER_RANKNATIVE=0: tables only, as before (no passenger, score 0).
Run: python tests/test_ranknative.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
FILE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_progression.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
-- the game's statistics objects: type() says "userdata"
local realType = type
NATIVE = setmetatable({}, { __mode = "k" })
type = function(x) if realType(x) == "table" and NATIVE[x] then return "userdata" end return realType(x) end
local function native(t) NATIVE[t] = true return t end
OWN = { [501] = 101, [502] = 102, [503] = 101 }      -- line -> player entity
api = {
  type = { ComponentType = { PLAYER_OWNED = "po" } },
  util = { getDefaultYearDuration = function() return 730000 end },
  engine = {
    getComponent = function(e, ct) if OWN[e] then return { player = OWN[e] } end return nil end,
    system = { townBuildingSystem = { getTown2personCapacitiesMap = function() return { [7] = { 1000, 0, 0 } } end } },
    util = { town = {
      getTownDeliveriesStats = function(town, interval, perLine, perCargo) return CARGO end,
      getTownHappinessStats = function(town, n)
        return native({ travellingInside = native({ 0, 0 }),
          travellingTo = native({ resident = native({ 0, 60 }), nonResident = native({ 0, 20 }) }),
          travellingFrom = native({ resident = native({ 0, 30 }), nonResident = native({ 0, 10 }) }),
          byLine = { { 501, native({ resident = native({ 2, 40 }), nonResident = native({ 0, 20 }) }) },
                     { 502, native({ resident = native({ 1, 30 }), nonResident = native({ 0, 10 }) }) },
                     { -1, native({ resident = native({ 0, 5 }), nonResident = native({ 0, 0 }) }) } } })
      end } },
  },
}
CARGO = {}
GAME = {
  levelFor = function(x) return math.floor(x / 100) + 1 end,
  own = function(entity) return { experience = 0, level = 1, potentialLevel = 1 } end,
  sensitivity = function() return 0 end,
  townStates = function() return { [7] = { cachedRatings = { urban_care = { value = 1 } } } } end,
}
REG = { mode = "separate", list = { { id = 1, ent = 101 }, { id = 2, ent = 102 } } }
'''


def main():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("PG = (function() " + open(FILE, encoding="utf-8").read() + " end)()")
    run = L.eval("function(code) return assert(load(code))() end")
    got = run("""
      local towns = PG.measure(api, REG, GAME)
      local c = towns[1].carried
      return (c[1] and c[1].passengers or 0) .. " " .. (c[2] and c[2].passengers or 0) .. " " .. (c[1] and c[1].unhappy or 0)""")
    check("#125: the passengers of each company's lines are counted (native statistics)", got == "60 40 2", got)
    got = run("""
      local prog = PG.ensure({})
      for i = 1, 30 do PG.tally(prog, REG, PG.measure(api, REG, GAME), GAME) end
      local s = PG.tally(prog, REG, PG.measure(api, REG, GAME), GAME)
      return string.format("%.0f %.0f", s[1], s[2])""")
    check("#125: both passenger companies score (population 1000 shared 60/40)", got == "600 400", got)
    got = run("""
      CARGO = { [503] = { [-1] = { 0, 50 } } }
      local towns = PG.measure(api, REG, GAME)
      CARGO = {}
      return tostring(towns[1].carried[1].cargo)""")
    check("cargo still counts", got == "50", got)
    L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    L2.execute(MOCK + 'ENV.MPFEVER_RANKNATIVE = "0"')
    L2.execute("PG = (function() " + open(FILE, encoding="utf-8").read() + " end)()")
    run2 = L2.eval("function(code) return assert(load(code))() end")
    got = run2("""
      local towns = PG.measure(api, REG, GAME)
      local c = towns[1].carried
      return tostring((c[1] and c[1].passengers) or 0) .. " " .. tostring((c[2] and c[2].passengers) or 0)""")
    check("MPFEVER_RANKNATIVE=0: tables only, as before (no passenger counted)", got == "0 0", got)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
