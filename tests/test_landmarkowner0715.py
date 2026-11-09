"""Offline test: a landmark built again at its next level keeps its owner in one-company-per-player games (0.7.15,
Getriebesand on Discord, 2026-11-09; CO.keepReplacedOwner and CO.installLandmarks in mpfever_co.lua).

"When you level up, you gain the ability to build structures like an amphitheater. Only the host is able to delete these
(even if the structure belongs to me)." The game's landmarks script (base/content/landmarks/landmarks.script.tl, build 40425)
builds a landmark again at every level its deliveries reach:
    ce.playerEntity = api.engine.util.getPlayer()
    proposal.constructionsToAdd = { ce }; proposal.constructionsToRemove = { entity }
    api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false))
In the simulation getPlayer() is the savegame's company (the host's): from its first level on, a player's landmark was the
host's company's on every game, and only the host could bulldoze it.

mpfever_co.lua runs through lupa (Lua 5.2) with a stand-in for that script (the same lines). Cases:
  - a player's landmark (owner 200) at its next level: built again for 200, not for the savegame's company (100);
  - the host's own landmark: unchanged; a proposal that is not one construction for another: unchanged;
  - the game's command factory is given back after the script's update, also when the script fails;
  - one company for everybody, or MPFEVER_LANDMARKOWNER=0: the game's script as it is;
  - the bridge installs it in the simulation, at every step, in the separate mode.
Run: python tests/test_landmarkowner0715.py
"""
import os, sys

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
PLAYER = 100           -- getPlayer() in the simulation: the savegame's company
OWNERS = { [7001] = 200, [7002] = 100 }
SENT = {}
api = {
  type = { ComponentType = { PLAYER_OWNED = "po" },
    SimpleProposal = { new = function() return { constructionsToAdd = {}, constructionsToRemove = {} } end,
      ConstructionEntity = { new = function() return {} end } } },
  engine = {
    util = { getPlayer = function() return PLAYER end },
    getComponent = function(e, ct) if ct == "po" and OWNERS[e] then return { player = OWNERS[e] } end end,
  },
  cmd = {
    makeWorldBuildProposalCmd = function(p, ctx, a, b) return { proposal = p } end,
    sendCommand = function(c) SENT[#SENT + 1] = c end,
  },
}
FACTORY = api.cmd.makeWorldBuildProposalCmd
-- a stand-in for the game's landmarks script: the landmark NEXT built again at its next level (the game's own lines)
NEXT = 7001
FAIL = false
LM = {
  update = function(u, state, dt)
    if FAIL then error("script failed") end
    local entity = NEXT
    local proposal = api.type.SimpleProposal.new()
    local ce = api.type.SimpleProposal.ConstructionEntity.new()
    ce.fileName = "landmarks/arena/amphitheater.con"
    ce.params = { seed = 1, level = 2 }
    ce.playerEntity = api.engine.util.getPlayer()
    proposal.constructionsToAdd = { ce }
    proposal.constructionsToRemove = { entity }
    proposal.old2new = { [entity] = 0 }
    local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false)
    api.cmd.sendCommand(cmd)
  end,
}
game = { ["::/landmarks/landmarks.script"] = LM }
REG = { mode = "separate", canon = 100, list = { { id = 1, ent = 100 }, { id = 2, ent = 200 } } }
LOGS = {}
ENVT = { registry = function() return REG end, log = function(t) LOGS[#LOGS + 1] = t end }
function owner(i) local c = SENT[i] return c and c.proposal.constructionsToAdd[1].playerEntity end
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def load(env_lines=""):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(env_lines + "\nCO = (function() " + open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read() + " end)()")
    return L, L.eval("function(code) return assert(load(code))() end")


def main():
    L, run = load()
    check("installed", run("return CO.installLandmarks(ENVT)") is True)
    check("installed once (the game's update wrapped once)", run("return CO.installLandmarks(ENVT)") is True and run("return LM.__mpfCo") is True)

    run("SENT = {}; NEXT = 7001; LM.update(nil, {}, 1)")
    check("a player's landmark (owner 200) at its next level: built again for 200, not for the savegame's company",
          run("return owner(1)") == 200, run("return tostring(owner(1))"))
    check("  said in mod.log", any("keeps its owner" in str(v) for v in L.eval("LOGS").values()))
    check("the game's command factory given back after the update", run("return api.cmd.makeWorldBuildProposalCmd == FACTORY") is True)
    check("getPlayer() not touched", run("return api.engine.util.getPlayer()") == 100)

    run("SENT = {}; NEXT = 7002; LM.update(nil, {}, 1)")
    check("the host's own landmark: for the savegame's company, as before", run("return owner(1)") == 100)
    run("SENT = {}; NEXT = 7003; LM.update(nil, {}, 1)")
    check("a landmark without an owner here: as the game builds it", run("return owner(1)") == 100)

    check("a proposal that is not one construction for another: unchanged",
          run("local p = { constructionsToAdd = { { playerEntity = 100 } }, constructionsToRemove = {} } return CO.keepReplacedOwner(p) == false and p.constructionsToAdd[1].playerEntity == 100") is True)
    check("two constructions for two: unchanged",
          run("local p = { constructionsToAdd = { { playerEntity = 100 }, { playerEntity = 100 } }, constructionsToRemove = { 7001, 7002 } } return CO.keepReplacedOwner(p)") is False)

    run("FAIL = true")
    ok_err = run("local ok = pcall(LM.update, nil, {}, 1) return ok")
    check("the script failing: its error goes on, the factory given back", ok_err is False and run("return api.cmd.makeWorldBuildProposalCmd == FACTORY") is True)
    run("FAIL = false")

    run("REG.mode = 'shared'; SENT = {}; NEXT = 7001; LM.update(nil, {}, 1)")
    check("one company for everybody: the game's script as it is", run("return owner(1)") == 100)

    L2, run2 = load("ENV.MPFEVER_LANDMARKOWNER = '0'")
    check("MPFEVER_LANDMARKOWNER=0: not installed, as before", run2("return CO.installLandmarks(ENVT)") is False and run2("return LM.__mpfCo") is None)

    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
    i = bridge.find("CO.installCompanyActions(SIM.coActEnv)")
    j = bridge.find("CO.installLandmarks(SIM.lmEnv)")
    check("the bridge installs it in the simulation at every step, in the separate mode (beside the company window's actions)",
          0 < i < j < i + 600 and 'SIM.coRegistry.mode == "separate" and CO.installLandmarks then' in bridge[i:j])

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
