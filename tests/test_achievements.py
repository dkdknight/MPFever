"""Offline test of the achievements per company in one-company-per-player games (0.6.8, issue #95).

The game's achievements script keeps one state for the game and reads getPlayer() (the savegame's company in the simulation):
what concerns a company (income, the vehicles that reach a stop, the builds, the ranks, the contracts) counted for player 1
only, and each game unlocked its Steam achievements from that state. CO.installAchievements (mpfever_co.lua) gives every
other company a state of its own, kept by the game's own functions with getPlayer() swapped; each game's interface unlocks its
own company's.

mpfever_co.lua runs through lupa (Lua 5.2) with a stand-in for the game's achievements script (it records which company
getPlayer() answered and which state it was given). Cases:
  - update: the savegame's company on the real state, then each other company on its own state, as that company;
  - an event of a vehicle: the vehicle's company only; a build: the company getPlayer() answers during the build;
    a contract: its owner; a rank of another company (MPFever's progression): that company only, once per new rank;
    a world event (cargo delivered): every company;
  - the interface: this game's company's state (a game of player 2 sees its own count, not player 1's);
  - one company for everybody, or MPFEVER_ACHIEVEMENTS=0: the game's script as it is;
  - the bridge installs it in the simulation and in the interface.
Run: python tests/test_achievements.py
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
PLAYER = 100           -- getPlayer() before any swap: the savegame's company (simulation) or this game's (interface)
OWNERS = { [5001] = 200, [5002] = 100 }
CONTRACTS = { [77] = { mpfOwner = 3 } }
api = {
  type = { ComponentType = { PLAYER = "player", PLAYER_OWNED = "po", GAME_SCRIPT = "gs" } },
  engine = {
    util = { getPlayer = function() return PLAYER end },
    forEachEntityWithComponent = function(fn, ct) if ct == "player" then for _, e in ipairs({ 300, 100, 200 }) do fn(e) end end end,
    getComponent = function(e, ct)
      if ct == "po" and OWNERS[e] then return { player = OWNERS[e] } end
      if ct == "gs" then return { state = { proposedSubventions = {}, activeSubventions = { { uid = 77, mpfOwner = CONTRACTS[77].mpfOwner } }, completedSubventions = {}, failedSubventions = {} } } end
    end,
    system = { gameScriptSystem = { getEntityForGameScript = function() return 1 end } },
  },
}
CALLS = {}
-- a stand-in for the game's achievements script: counts per state, records who getPlayer() was
local function bump(state, field)
  local s = state:get() or { version = 4, n = 0, income = 0 }
  s[field] = (s[field] or 0) + 1
  state:set(s)
end
ACH = {
  update = function(u, state, dt)
    CALLS[#CALLS + 1] = "update:" .. api.engine.util.getPlayer()
    bump(state, "income")
  end,
  handleEvent = function(u, state, src, id, name, param)
    CALLS[#CALLS + 1] = id .. "/" .. name .. ":" .. api.engine.util.getPlayer()
    bump(state, id .. name)
  end,
  guiUpdate = function(u, state, guiState)
    local s = state:get()
    SEEN = s and s.income or -1
    guiState:set({ last = SEEN })
  end,
}
game = { ["::/game_mechanics/achievements/achievements.script"] = ACH }
REG = { mode = "separate", canon = 100, list = { { id = 1, ent = 100 }, { id = 2, ent = 200 }, { id = 3, ent = 300 } } }
PROG = { records = { { company = 2, level = 1 } } }
ENVT = { registry = function() return REG end, prog = function() return PROG end, log = function() end }
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("CO = (function() " + open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read() + " end)()")
    run = L.eval("function(code) return assert(load(code))() end")
    run("""STATE = { v = nil }
function STATE:get() return self.v end
function STATE:set(x) self.v = x end
function STATE:hasEventSubscriptions() return true end
function STATE:subscribeToEvent() end""")
    check("installed", run("return CO.installAchievements(ENVT)") is True)
    check("installed once", run("return CO.installAchievements(ENVT)") is True and run("return ACH.update ~= nil"))

    run("CALLS = {}; ACH.update(nil, STATE, 1)")
    check("update: the savegame's company on the real state, then the others as themselves, in entity order",
          run("return table.concat(CALLS, ' ')") == "update:100 update:200 update:300", run("return table.concat(CALLS, ' ')"))
    check("each other company has its own state", run("return STATE.v.income .. '/' .. STATE.v.mpfOthers['200'].income .. '/' .. STATE.v.mpfOthers['300'].income") == "1/1/1")
    check("getPlayer() is given back", run("return api.engine.util.getPlayer()") == 100)

    run("CALLS = {}; ACH.handleEvent(nil, STATE, '', 'TransportVehicleSystem', 'OnArriveAtStop', { vehicleEntity = 5001 })")
    check("a vehicle of company 2 at a stop: company 2 only, as itself",
          run("return table.concat(CALLS, ' ')") == "TransportVehicleSystem/OnArriveAtStop:200" and run("return STATE.v.TransportVehicleSystemOnArriveAtStop == nil and STATE.v.mpfOthers['200'].TransportVehicleSystemOnArriveAtStop == 1"))
    run("CALLS = {}; ACH.handleEvent(nil, STATE, '', 'TransportVehicleSystem', 'OnArriveAtStop', { vehicleEntity = 5002 })")
    check("a vehicle of the savegame's company: its state", run("return STATE.v.TransportVehicleSystemOnArriveAtStop") == 1)
    run("CALLS = {}; PLAYER = 300; ACH.handleEvent(nil, STATE, '', 'apply_command', 'onPostBuildProposal', {}); PLAYER = 100")
    check("a build: the company that builds", run("return table.concat(CALLS, ' ')") == "apply_command/onPostBuildProposal:300")
    run("CALLS = {}; ACH.handleEvent(nil, STATE, '', 'Subvention', 'OnCompleted', { uid = 77 })")
    check("a contract completed: its owner", run("return table.concat(CALLS, ' ')") == "Subvention/OnCompleted:300", run("return table.concat(CALLS, ' ')"))
    run("CALLS = {}; ACH.handleEvent(nil, STATE, '', 'SimCargoSystem', 'OnToArriveAtDestination', { entities = {} })")
    check("cargo delivered (the world's): every company", run("return table.concat(CALLS, ' ')") == "SimCargoSystem/OnToArriveAtDestination:100 SimCargoSystem/OnToArriveAtDestination:200 SimCargoSystem/OnToArriveAtDestination:300")

    run("CALLS = {}; PROG.records[1].level = 3; ACH.update(nil, STATE, 1)")
    got = run("local t = {} for _, c in ipairs(CALLS) do if c:find('Companies') then t[#t + 1] = c end end return table.concat(t, ' ')")
    check("company 2 took ranks 2 and 3 (MPFever's progression): two rank-ups, for company 2 only", got == "Companies/OnLevelUp:200 Companies/OnLevelUp:200", got)
    run("CALLS = {}; ACH.update(nil, STATE, 1)")
    check("not again", "Companies" not in run("return table.concat(CALLS, ' ')"))

    run("PLAYER = 200; SEEN = nil; ACH.guiUpdate(nil, { get = function() return STATE.v end }, STATE); PLAYER = 100")
    check("the interface of player 2: its own company's state", run("return SEEN") == run("return STATE.v.mpfOthers['200'].income"))
    run("SEEN = nil; ACH.guiUpdate(nil, { get = function() return STATE.v end }, { get = function() end, set = function() end })")
    check("the interface of the savegame's company: the real state", run("return SEEN") == run("return STATE.v.income"))

    run("REG.mode = 'shared'; CALLS = {}; ACH.update(nil, STATE, 1); ACH.handleEvent(nil, STATE, '', 'TransportVehicleSystem', 'OnArriveAtStop', { vehicleEntity = 5001 })")
    check("one company for everybody: the game's script as it is", run("return table.concat(CALLS, ' ')") == "update:100 TransportVehicleSystem/OnArriveAtStop:100", run("return table.concat(CALLS, ' ')"))
    L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    L2.execute(MOCK)
    L2.execute("ENV.MPFEVER_ACHIEVEMENTS = '0'\nCO = (function() " + open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read() + " end)()")
    check("MPFEVER_ACHIEVEMENTS=0: not installed, as before", L2.eval("CO.installAchievements(ENVT)") is False)

    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
    check("the bridge installs it in the simulation", "CO.installAchievements(SIM.achEnv)" in bridge and "prog = function() return SIM.prog end" in bridge)
    check("and in the interface", "pcall(CO.installAchievements, G.achEnv)" in bridge)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
