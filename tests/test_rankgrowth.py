"""Offline test of the companies' experience from the towns' growth (0.7.1, issue #125 reopened, PG.grow).

#125 (HolderLord, 0.7.0, one company per player): the host's company reached rank 5 while the client's stayed at rank 1, its bar
moving by 1 or 2 % an hour (6237 against 1497 experience, base population 3427, world 11368). The game's own experience is the
world's population and begins at the game's start population (the first rank); the companies' experience was their score (a
part of the world's population) and only the savegame's company began at the base. Now:
  - every company begins at the base population, as the game begins one;
  - each town's growth is credited to the companies by their share of what was carried for it; one company alone gets exactly
    the game's own experience (the world's population); a town nobody serves: its growth goes to every company alike;
  - a savegame of an earlier MPFever: the world's growth since the start is shared out by the companies' scores the first time
    (#125's numbers: the client's company goes from rank 1 to about the host's), the higher experience kept;
  - a company that comes later begins at the base; experience never goes down when a town shrinks;
  - the same numbers whatever the order of the towns; MPFEVER_RANKGROWTH=0: the scores, as before.
Run: python tests/test_rankgrowth.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
FILE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_progression.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
BASE = 3427
OWN = 3427
-- the game's thresholds, roughly: one rank per 15 % above the base
GAME = {
  levelFor = function(x) if x < BASE then return 0 end return math.floor(math.log(x / BASE) / math.log(1.15)) + 1 end,
  own = function(entity) return { experience = OWN, level = 1, potentialLevel = 1 } end,
  sensitivity = function() return 0 end,
  base = function() return BASE end,
}
REG = { mode = "separate", list = { { id = 1, ent = 101 }, { id = 2, ent = 102 } } }
-- towns: { { town, population, cargo of company 1, cargo of company 2 }, ... }
function TOWNS(list)
  local out = {}
  for _, x in ipairs(list) do
    local carried = {}
    if x[3] > 0 then carried[1] = { cargo = x[3], late = 0, passengers = 0, unhappy = 0 } end
    if x[4] > 0 then carried[2] = { cargo = x[4], late = 0, passengers = 0, unhappy = 0 } end
    out[#out + 1] = { town = x[1], population = x[2], state = { cachedRatings = { urban_care = { value = 1 } } }, carried = carried }
  end
  return out
end
function REC(prog, id) for _, r in ipairs(prog.records) do if r.company == id then return r end end end
function EXP(prog, id) local r = REC(prog, id) return r and r.experience end
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("PG = (function() " + open(FILE, encoding="utf-8").read() + " end)()")
    run = L.eval("function(code) return assert(load(code))() end")

    got = run("""
      local prog = PG.ensure({})
      local r1 = {}
      PG.tally(prog, REG, TOWNS({ { 7, 2000, 0, 0 }, { 8, 1427, 0, 0 } }), GAME)
      r1[#r1 + 1] = EXP(prog, 1) .. "/" .. EXP(prog, 2)
      -- company 1 alone serves town 7, which grows by 600; town 8 nobody serves grows by 100
      PG.tally(prog, REG, TOWNS({ { 7, 2600, 100, 0 }, { 8, 1527, 0, 0 } }), GAME)
      r1[#r1 + 1] = EXP(prog, 1) .. "/" .. EXP(prog, 2)
      -- both serve town 7 half and half, it grows by 1000
      PG.tally(prog, REG, TOWNS({ { 7, 3600, 50, 50 }, { 8, 1527, 0, 0 } }), GAME)
      r1[#r1 + 1] = EXP(prog, 1) .. "/" .. EXP(prog, 2)
      return table.concat(r1, " ")""")
    check("a new game: both begin at the base; growth by share; a town nobody serves to both alike",
          got == "3427/3427 4077/3477 4577/3977", got)

    got = run("""
      REG1 = { mode = "separate", list = { { id = 1, ent = 101 }, { id = 2, ent = 102 } } }
      local prog = PG.ensure({})
      PG.tally(prog, REG1, TOWNS({ { 7, 3427, 0, 0 } }), GAME)
      for i, pop in ipairs({ 4000, 5000, 8000, 12000 }) do
        PG.tally(prog, REG1, TOWNS({ { 7, pop, 100, 0 } }), GAME)
      end
      return EXP(prog, 1) .. " " .. EXP(prog, 2)""")
    check("one company carrying everything gets the world's population, as the game's own experience",
          got == "12000 3427", got)

    got = run("""
      local prog = PG.ensure({})
      PG.tally(prog, REG, TOWNS({ { 7, 5000, 0, 100 } }), GAME)
      PG.tally(prog, REG, TOWNS({ { 7, 6000, 0, 100 } }), GAME)
      local a = EXP(prog, 2)
      PG.tally(prog, REG, TOWNS({ { 7, 5200, 0, 100 } }), GAME)
      local b = EXP(prog, 2)
      PG.tally(prog, REG, TOWNS({ { 7, 6500, 0, 100 } }), GAME)
      return a .. " " .. b .. " " .. EXP(prog, 2) .. " " .. string.format("%.0f", REC(prog, 2).credit)""")
    check("a town that shrinks: experience kept, the credit goes down and must be earned back",
          got.startswith("") and got.split()[0] == got.split()[1] and int(got.split()[2]) > int(got.split()[1]), got)

    # #125's numbers: a 0.7.0 savegame, company 1 at 6237 (rank 5 taken), company 2 at 1497
    got = run("""
      local prog = PG.ensure({ records = { { company = 1, experience = 6237, potential = 5, level = 5, base = 3427 },
        { company = 2, experience = 1497, potential = 1, level = 1 } } })
      -- the world now: 11368 residents; company 1 carries about two thirds, company 2 one third
      local towns = TOWNS({ { 7, 6000, 200, 100 }, { 8, 5368, 200, 100 } })
      PG.tally(prog, REG, towns, GAME)
      local r1, r2 = REC(prog, 1), REC(prog, 2)
      return r1.experience .. " " .. r2.experience .. " " .. r1.potential .. " " .. r2.potential""")
    e1, e2, p1, p2 = (int(x) for x in got.split())
    check("#125: the client's company moves up to about the host's rank (%s)" % got,
          e1 >= 6237 and e2 > 5000 and p2 >= 4 and p1 >= 5, got)

    got = run("""
      REG3 = { mode = "separate", list = { { id = 1, ent = 101 }, { id = 2, ent = 102 } } }
      local prog = PG.ensure({})
      PG.tally(prog, REG3, TOWNS({ { 7, 4000, 100, 0 } }), GAME)
      PG.tally(prog, REG3, TOWNS({ { 7, 4500, 100, 0 } }), GAME)
      REG3.list[3] = { id = 3, ent = 103 }
      PG.tally(prog, REG3, TOWNS({ { 7, 5000, 50, 0 }, { 9, 300, 0, 0 } }), GAME)
      return EXP(prog, 3) .. " " .. EXP(prog, 1)""")
    check("a company that comes later begins at the base", got.split()[0] == "3427" and int(got.split()[1]) > 4000, got)

    got = run("""
      local function go(order)
        local prog = PG.ensure({})
        local a = { { 7, 2000, 30, 70 }, { 8, 1500, 10, 0 }, { 9, 900, 0, 5 } }
        local b = { { 7, 2333, 30, 70 }, { 8, 1777, 10, 0 }, { 9, 1201, 0, 5 } }
        if order then table.sort(a, function(x, y) return x[1] > y[1] end); table.sort(b, function(x, y) return x[1] > y[1] end) end
        PG.tally(prog, REG, TOWNS(a), GAME)
        PG.tally(prog, REG, TOWNS(b), GAME)
        return string.format("%.9f/%.9f", REC(prog, 1).credit, REC(prog, 2).credit)
      end
      return go(false) .. " " .. go(true)""")
    a, b = got.split()
    check("the same numbers whatever the order of the towns", a == b, got)

    run("ENV.MPFEVER_RANKGROWTH = '0'")
    got = run("""
      local prog = PG.ensure({})
      PG.tally(prog, REG, TOWNS({ { 7, 2000, 0, 100 } }), GAME)
      return tostring(EXP(prog, 2)) .. " " .. tostring(prog.growth)""")
    check("MPFEVER_RANKGROWTH=0: the score, as before", got == "2000 nil", got)

    src = open(FILE, encoding="utf-8").read()
    check("the game's base population read from company_util", "function game.base() return out.company.getBasePopulation() end" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
