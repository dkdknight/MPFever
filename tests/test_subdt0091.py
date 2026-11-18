"""Offline test: the game's contracts script (subventions) is called with the steps only in a session (0.9.1, #425, MPFEVER_SUBDT0).

Report #425 (2026-11-18, Flubi host and lulei, 0.8.17, separate companies): "script:subventions" differed at check 139 (resync 2)
while every simulation step was alike. lulei's game stood almost all the time (it waited for Flubi's clock), and a line was changed
just before (a replayed makeLineUpdateCmd).
The game's contracts script ends a contract in its update, at the game time of that call (subventions.script.tl:
"v.completedTime = currentGameTime", for every call, dt 0 too). A contract "connect two towns" is reached by a line's event
(deliver_passengers: OnStartedLineUsage sets lineEntity). A game standing at the step of the replayed change got the update with dt 0
at once and completed the contract at that step; the game that ran on completed it in the next step's update: other completion
times, other rewards' steps, "script:subventions" differed. Known since 0.5.10 (tests 522 and 525, "completed one step sooner on the
standing game"); STANDSKIP (all the scripts' update skipped in a stand, the bridge's too) made things worse and stays off.
The fix wraps the contracts script's update alone, as the landmarks script's (0.8.3, #228): dt 0 is skipped in a session.

Part 1 reproduces the difference with a model of the game's script (the same completion rule) on two games, one standing; part 2
runs the bridge's real wrapper (taken from the file, through lupa); part 3 reads the game's own script when the game is installed
next to the repository (skipped on CI).
Run: python tests/test_subdt0091.py
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


# A model of the game's contracts script: the event of a line marks the contract reached (deliver_passengers' handleEvent), the
# update completes a reached contract at the game time of the call (subventions.script.tl's update, whatever dt).
MODEL = """
NOW = 0
function makeGame()
  local g = { state = { active = { { uid = 7, reached = false } }, completed = {} } }
  g.script = {
    handleEvent = function(u, st, src, id, name, param)
      if name == "OnStartedLineUsage" then for _, v in ipairs(st.active) do v.reached = true end end
    end,
    update = function(u, st, dt)
      local i = 1
      while i <= #st.active do
        local v = st.active[i]
        if v.reached then v.completedTime = NOW; table.insert(st.completed, v); table.remove(st.active, i) else i = i + 1 end
      end
    end,
  }
  return g
end
-- a step of 200 ms: the step's work (here the line's event when asked), then the scripts' update with dt 0.2
function step(g, withEvent)
  if withEvent then g.script.handleEvent(nil, g.state, "", "SimPersonSystem", "OnStartedLineUsage", {}) end
  NOW = NOW + 200
  g.script.update(nil, g.state, 0.2)
end
-- a batch of no step (the game stands at its stop point): the action of the step is applied there, its event goes out, and the
-- engine calls the scripts' update with dt 0
function stand(g, withEvent)
  if withEvent then g.script.handleEvent(nil, g.state, "", "SimPersonSystem", "OnStartedLineUsage", {}) end
  g.script.update(nil, g.state, 0)
end
-- the replayed line change at T = 1000: game A stands there (its event at once, then dt 0), game B runs on through it
function play(a, b)
  NOW = 1000; stand(a, true); stand(a, false); step(a, false)
  NOW = 1000; step(b, true)
  return a.state.completed[1] and a.state.completed[1].completedTime, b.state.completed[1] and b.state.completed[1].completedTime
end
"""


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r'\n(\t\tif k == "::/game_mechanics/subventions/subventions\.script".*?\n\t\tend\n)', src, re.S)
    if not m:
        print("FAIL: the contracts script's wrapper not found in DET.wrapModEvents")
        return 1
    w = src[src.index("function DET.wrapModEvents()"):]
    w = w[:w.index("\nend\n")]
    check("in DET.wrapModEvents (every role, both company modes), MPFEVER_SUBDT0=1: as before",
          m.group(1) in w and 'os.getenv("MPFEVER_SUBDT0") ~= "1"' in m.group(1))

    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run(MODEL)

    # part 1: the bug, without the wrapper
    ta, tb = run("return play(makeGame(), makeGame())")
    check("before (the bug): the standing game completes the contract at the line change's step, the other one step later",
          ta == 1000 and tb == 1200, (ta, tb))

    # part 2: the bridge's wrapper
    run("""
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
SIM = {}
C = { ROLE = "client" }
function wrapGame(g)
  game = { ["::/game_mechanics/subventions/subventions.script"] = g.script,
           ["::/towns/towns.script"] = { update = function(u, st, dt) TOWNS = dt end } }
  for k, v in pairs(game) do
""" + m.group(1) + """
  end
end
""")
    run("GA, GB = makeGame(), makeGame(); wrapGame(GA); wrapGame(GA); wrapGame(GB)")
    ta, tb = run("return play(GA, GB)")
    check("after: both games complete the contract at the same step (the first step's update)", ta == 1200 and tb == 1200, (ta, tb))
    check("  the standing game's two calls with dt 0 skipped and counted (wrapped once)", run("return SIM.subDt0") == 2, run("return SIM.subDt0"))
    run("game['::/towns/towns.script'].update(nil, nil, 0)")
    check("the game's other scripts: left as they are", run("return TOWNS") == 0)
    run("C.ROLE = 'solo'; G1 = makeGame(); wrapGame(G1); G1.script.handleEvent(nil, G1.state, '', '', 'OnStartedLineUsage', {}); NOW = 5000; G1.script.update(nil, G1.state, 0)")
    check("alone (no session): every call, as the game does", run("return G1.state.completed[1] and G1.state.completed[1].completedTime") == 5000)
    check("logged once a wrap", sum(1 for i in range(1, 10) if "contracts script" in str(run(f"return LOG[{i}]"))) == 3)

    # part 3: the game's own script (only with the game installed next to the repository)
    if os.path.isfile(GAME_ZIP):
        with zipfile.ZipFile(GAME_ZIP) as z:
            sub = z.read("game_mechanics/subventions/subventions.script.tl").decode("utf-8", "replace")
            dp = z.read("game_mechanics/subventions/deliver_passengers/deliver_passengers.script.tl").decode("utf-8", "replace")
        up = sub[sub.index("update = function"):sub.index("handleEvent = function")]
        check("the game's update completes a contract at the call's game time, dt 0 too (only the new offers need dt > 0)",
              "v.completedTime = currentGameTime" in up and up.count("dt > 0.0") == 1 and "trySpawnRandom" in up[up.index("dt > 0.0"):])
        check("deliver_passengers: a line's event marks the contract reached", "OnStartedLineUsage" in dp and "s.lineEntity = " in dp)
    else:
        print("(the game's scripts not found next to the repository: part 3 skipped)")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
