"""Offline test: the game's company growth script is called with the steps only in a session (0.9.1, MPFEVER_GROWTHDT0).

Test N1 (2026-11-19, 0.9.1 kit, "Test Leawood", two games on one PC, the client held at random by MPFEVER_TESTHOLD=30, 58 min at
4x): "script:progression" differed at check 173 (the dumps: experience 25159 on the client, 25156 on the host), and was alike again
at check 174. The game's company growth script keeps, as the savegame company's experience, the highest world population it has
seen (company_growth.script.tl: "if numResidents > ... experience then ... experience = numResidents"), and it counts it at every
call of its update, whatever dt. The engine calls the scripts' update once per step with dt 0.2, in the middle of the step's
systems, and with dt 0 in a batch of no step: a game standing at a stop point counted the population as the step before had left
it, a moment the other game never looked at. Here the population grew past it before the next check; one that fell back would
have kept the difference (another rank on one game only, other ticket prices, other money). The same kind of call as the contracts'
(#425, MPFEVER_SUBDT0) and the landmarks' (#228, MPFEVER_LANDMARKDT0): its update is called with the steps only in a session.

Part 1 reproduces the difference with a model of the script (the same rule) on two games, one standing; part 2 runs the bridge's
real wrapper (taken from the file, through lupa); part 3 reads the game's own script when the game is installed next to the
repository (skipped on CI).
Run: python tests/test_growthdt0091.py
"""
import os, re, sys, zipfile

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
GAME_ZIP = os.path.join(HERE, "..", "..", "base", "content", "game_mechanics.zip")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


# A model of the game's company growth script (company_growth.script.tl's update: the experience is the highest population counted)
# and of a step: the systems before the scripts move the population, the scripts' update counts it (dt 0.2), the systems after them
# move it again. A batch of no step only calls the update, with dt 0: it counts the population the step before left.
MODEL = """
POP = 25150
function makeGame()
  local g = { state = { experience = 25150 } }
  g.script = {
    update = function(u, st, dt)
      if POP > st.experience then st.experience = POP end
    end,
  }
  return g
end
-- one step: before the scripts +2 people, after them +4 then (the next step) -3: the population counted at the scripts' call
-- is never the one the step leaves
function step(g, k)
  POPS[g] = POPS[g] or 25150
  POP = POPS[g] + 2
  g.script.update(nil, g.state, 0.2)
  POP = POP + 4
  POPS[g] = POP - 3 - (k % 2) * 3
  POP = POPS[g] + 3 + (k % 2) * 3
end
-- a batch of no step at the stop point: the update with dt 0 counts what the step before left
function stand(g)
  g.script.update(nil, g.state, 0)
end
POPS = {}
-- game A stands at its stop point after some steps (a slower player's clock), game B runs on
function play(a, b)
  for k = 1, 6 do
    step(a, k); if k == 3 then stand(a); stand(a) end
    step(b, k)
  end
  return a.state.experience, b.state.experience
end
"""


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r'\n(\t\tif k == "::/game_mechanics/company/company_growth\.script".*?\n\t\tend\n)', src, re.S)
    if not m:
        print("FAIL: the company growth script's wrapper not found in DET.wrapModEvents")
        return 1
    w = src[src.index("function DET.wrapModEvents()"):]
    w = w[:w.index("\nend\n")]
    check("in DET.wrapModEvents (every role, both company modes), MPFEVER_GROWTHDT0=1: as before",
          m.group(1) in w and 'os.getenv("MPFEVER_GROWTHDT0") ~= "1"' in m.group(1))

    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run(MODEL)

    # part 1: the bug, without the wrapper
    ea, eb = run("return play(makeGame(), makeGame())")
    check("before (the bug): the standing game counted a population the other never looked at, its experience is higher",
          ea > eb, (ea, eb))

    # part 2: the bridge's wrapper
    run("""
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
SIM = {}
C = { ROLE = "client" }
function wrapGame(g)
  game = { ["::/game_mechanics/company/company_growth.script"] = g.script,
           ["::/towns/towns.script"] = { update = function(u, st, dt) TOWNS = dt end } }
  for k, v in pairs(game) do
""" + m.group(1) + """
  end
end
""")
    run("POPS = {}; GA, GB = makeGame(), makeGame(); wrapGame(GA); wrapGame(GA); wrapGame(GB)")
    ea, eb = run("return play(GA, GB)")
    check("after: the same experience on both games", ea == eb, (ea, eb))
    check("  the standing game's two calls with dt 0 skipped and counted (wrapped once)", run("return SIM.growthDt0") == 2, run("return SIM.growthDt0"))
    run("game['::/towns/towns.script'].update(nil, nil, 0)")
    check("the game's other scripts: left as they are", run("return TOWNS") == 0)
    run("C.ROLE = 'solo'; G1 = makeGame(); wrapGame(G1); POP = 30000; G1.script.update(nil, G1.state, 0)")
    check("alone (no session): every call, as the game does", run("return G1.state.experience") == 30000)
    check("logged once a wrap", sum(1 for i in range(1, 10) if "company growth script" in str(run(f"return LOG[{i}]"))) == 3)

    # part 3: the game's own script (only with the game installed next to the repository)
    if os.path.isfile(GAME_ZIP):
        with zipfile.ZipFile(GAME_ZIP) as z:
            gs = z.read("game_mechanics/company/company_growth.script.tl").decode("utf-8", "replace")
            pg = z.read("game_mechanics/company/company_progression.gs.lua").decode("utf-8", "replace")
        up = gs[gs.index("update = function"):gs.index("handleEvent = function")]
        check("the game's update counts the world population at every call, whatever dt (no test of _dt)",
              "computeWorldPopulation()" in up and "_dt" in up.split("\n")[0] and up.count("_dt") == 1)
        check("  and keeps the highest one as the experience", "if numResidents > scriptState.companyState[companyEntity].experience then" in gs)
        check("the game's script is company_growth.script (its .gs points to it)", "company_growth.script@update" in pg)
    else:
        print("(the game's scripts not found next to the repository: part 3 skipped)")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
