"""Offline test of the companies' ranks below the game's first threshold, and of the game's own rank notification (0.6.5, #110).

One company per player. The game's levelFor answers 0 below its first threshold (the world's population when the game began):
a company that had taken rank 1 was told "company 3 has reached rank 0, not 3" (six times in #109's logs). And the game's own
"rank reached" notification is the savegame company's (the host's), shown on every player's game: its button asked that rank
for the local company ("only the host gets ranks", #110, #95).

PG.tally (mpfever_progression.lua) and N.foreignRank (mpfever_ui.script.lua) run through lupa (Lua 5.2) with mocks. Cases:
  - levelFor 0: the rank reached is 1, never below the rank taken; MPFEVER_RANKFLOOR=0: 0, as before;
  - a rank notification of another company, with several companies: dismissed; of this company, or with one company, or
    another type: shown; the entity as a number or as { entity = }; MPFEVER_RANKNOTIF=0: shown, as before.
Run: python tests/test_rankfloor.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LEVEL = 0
GAME = {
  levelFor = function(x) return LEVEL end,
  own = function(entity) return { experience = 0, level = 1, potentialLevel = 1 } end,
  sensitivity = function() return 0 end,
}
REG = { mode = "separate", list = { { id = 1, ent = 101 }, { id = 3, ent = 103 } } }
function TOWNS() return { { town = 7, population = 1000, state = { cachedRatings = { urban_care = { value = 1 } } }, carried = { [3] = { cargo = 50, late = 0, passengers = 0, unhappy = 0 } } } } end
function REC(prog, id) for _, r in ipairs(prog.records) do if r.company == id then return r end end end
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("PG = (function() " + open(os.path.join(CONTENT, "mpfever_progression.lua"), encoding="utf-8").read() + " end)()")
    run = L.eval("function(code) return assert(load(code))() end")

    got = run("local prog = PG.ensure({}); PG.tally(prog, REG, TOWNS(), GAME); local r = REC(prog, 3); return r.potential .. '/' .. select(2, PG.take(prog, REG, 3, 3))")
    check("#110: levelFor 0: rank 1 reached (not 0), rank 3 still refused with the right number", got == "1/company 3 has reached rank 1, not 3", got)
    got = run("local prog = PG.ensure({ records = { { company = 3, experience = 0, potential = 2, level = 2 } } }); PG.tally(prog, REG, TOWNS(), GAME); return REC(prog, 3).potential")
    check("never below the rank taken (2)", got == 2, got)
    got = run("LEVEL = 4; local prog = PG.ensure({}); PG.tally(prog, REG, TOWNS(), GAME); LEVEL = 0; return REC(prog, 3).potential")
    check("a rank reached above: as the game says", got == 4, got)
    run("ENV.MPFEVER_RANKFLOOR = '0'")
    got = run("local prog = PG.ensure({}); PG.tally(prog, REG, TOWNS(), GAME); return REC(prog, 3).potential")
    check("MPFEVER_RANKFLOOR=0: 0, as before", got == 0, got)
    run("ENV.MPFEVER_RANKFLOOR = nil")

    ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read()
    m = re.search(r"^function N\.foreignRank\(n, me, many\)\n.*?^end\n", ui, re.S | re.M)
    check("N.foreignRank found in the interface script, used by N.tick", m is not None and "N.foreignRank(entry.notification, me, many)" in ui)
    if m:
        L.execute("N = {}\n" + m.group(0))
        T = "'::/game_mechanics/company/company_notification_rank_up.script'"
        got = run("return N.foreignRank({ type = " + T + ", params = { companyEntity = 47396, rank = 2 } }, 51200, true)")
        check("#110: the host company's rank notification on another player's game: dismissed", got is True, got)
        got = run("return N.foreignRank({ type = " + T + ", params = { companyEntity = { entity = 47396 }, rank = 2 } }, 51200, true)")
        check("the entity given as a table: dismissed too", got is True, got)
        got = run("return N.foreignRank({ type = " + T + ", params = { companyEntity = 47396, rank = 2 } }, 47396, true)")
        check("this company's own: shown", got is False, got)
        got = run("return N.foreignRank({ type = " + T + ", params = { companyEntity = 47396, rank = 2 } }, 51200, false)")
        check("one company for everybody: shown", got is False, got)
        got = run("return N.foreignRank({ type = 'game_mechanics/notifications/types/industry_spawn.script', params = { companyEntity = 47396 } }, 51200, true)")
        check("another type of notification: shown", got is False, got)
        got = run("return N.foreignRank({ type = " + T + ", params = {} }, 51200, true)")
        check("no company in it: shown", got is False, got)
        run("ENV.MPFEVER_RANKNOTIF = '0'")
        got = run("return N.foreignRank({ type = " + T + ", params = { companyEntity = 47396, rank = 2 } }, 51200, true)")
        check("MPFEVER_RANKNOTIF=0: shown, as before", got is False, got)
        run("ENV.MPFEVER_RANKNOTIF = nil")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
