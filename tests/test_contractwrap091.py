"""Offline test: every type of contract is loaded and wrapped at the first update after a load (0.9.1, MPFEVER_CONTRACTWRAP).

With one company per player, a contract counts only the deliveries of its company's lines: MPFever wraps each type of contract
(CO.installContracts, wrapContractType). The game loads a type's script when it first needs it: an offer of that type, or the first
event or update of a contract of it after a load. The bridge wrapped the types every 50 of its updates (SIM.ctTick % 50), a count
of the engine's calls that a standing game makes more of (dt 0 calls): a type loaded in the middle of a batch (a delivery's event)
counted the deliveries of every company's lines until then, on one game for longer than on another (the deliver_cargo type was
wrapped at 10:34:11 on Flubi's game, 10:34:27 on lulei's, #425). Since 0.9.1 the contracts script's update is also skipped at dt 0
(#425): after a load, the types of the running contracts are loaded at their first event, in a batch.
Now every type is loaded and wrapped at the bridge's first update, before any step (env.preload); the bridge calls it at every
update. MPFEVER_CONTRACTWRAP=0: as before.
mpfever_co.lua is run through lupa (Lua 5.2) with a mocked game API.
Run: python tests/test_contractwrap091.py
"""
import os, re, sys

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


# a game: two companies (entities 11 and 22), lines 101 (company 1) and 202 (company 2), one contract of type deliver_cargo
# accepted by company 2; the type's script is in the game's files, loaded by loaderHelper:useFn
GAME = """
PATH = "::/game_mechanics/subventions/deliver_cargo/deliver_cargo.script"
REF = PATH .. "@deliver_cargo"
api = {
  res = { genericRep = {
    getAllOfType = function(t) return t == "subvention" and { 7 } or {} end,
    get = function(id) return { data = { scriptFile = REF } } end } },
  engine = { getComponent = function(e, ct) return { player = (e == 101 and 11 or 22) } end },
  type = { ComponentType = { PLAYER_OWNED = 1 } },
}
LOADS = 0
-- the type's script as the game has it (deliver_cargo.script.tl: a delivery counts while the contract is accepted)
function loadType()
  LOADS = LOADS + 1
  game[PATH] = { deliver_cargo = {
    handleEvent = function(src, id, name, param, s)
      for i = 1, #param do s.delivered = (s.delivered or 0) + 1 end
    end } }
end
loaderHelper = { useFn = function(self, ref) if ref:sub(1, #REF) == REF and game[PATH] == nil then loadType() end end }
ug_require = function() error("not here") end
game = { ["::/game_mechanics/subventions/subventions.script"] = { handleEvent = function() end } }
REG = { mode = "separate", list = { { id = 1, ent = 11 }, { id = 2, ent = 22 } } }
LOG = {}
CONTRACT = { uid = 5, mpfOwner = 2, delivered = 0 }
-- a delivery event reaches the contract through the contracts script (the game's util.useFn loads the type when needed)
function deliver(line)
  loaderHelper:useFn(REF .. ".handleEvent")
  game[PATH].deliver_cargo.handleEvent("", "TransportVehicleSystem", "OnCalcTicketPrice", { { lineEntity = line } }, CONTRACT)
end
"""


def game_run(co_src, preload, every):
    """A load, then batches: the bridge's update installs the contracts (every update, or every 50th); in the first batch a
    delivery by company 1's line (101) reaches company 2's contract. Returns the contract's count of deliveries."""
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run(GAME)
    L.globals().CO = L.execute(co_src)
    run(f"""
ENV = {{ log = function(s) LOG[#LOG + 1] = s end, registry = function() return REG end, localCo = function() return 2 end,
        preload = {str(preload).lower()} }}
TICK = 0
function bridgeUpdate()
  TICK = TICK + 1
  if {str(every).lower()} or TICK % 50 == 1 then CO.installContracts(ENV) end
end
""")
    # the first update after the load, then 3 batches of steps with an update each; the delivery in the second batch
    run("bridgeUpdate()")
    run("bridgeUpdate()")
    run("deliver(101)")
    run("bridgeUpdate()")
    run("bridgeUpdate()")
    return run("return CONTRACT.delivered"), run("return LOADS"), run


def main():
    co_src = open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read()
    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")

    check("the bridge installs the contracts at every update, every 50 only with MPFEVER_CONTRACTWRAP=0",
          'local cwOld = os.getenv("MPFEVER_CONTRACTWRAP") == "0"' in bridge
          and '(not cwOld or SIM.ctTick % 50 == 1)' in bridge and "preload = not cwOld" in bridge)

    # before: the type loaded by the delivery itself, wrapped later: company 1's delivery counted for company 2's contract
    d, loads, _ = game_run(co_src, preload=False, every=False)
    check("before (as the game loads it, wrapped every 50 updates): another company's delivery counted (the bug)", d == 1 and loads == 1, (d, loads))
    # a game that wrapped it in time (the type already loaded, a game standing more): not counted -> the two games differ
    # after: loaded and wrapped at the first update
    d, loads, run = game_run(co_src, preload=True, every=True)
    check("after: the type loaded at the first update and wrapped before the delivery: not counted", d == 0 and loads == 1, (d, loads))
    check("  logged: loaded at once, then wrapped", any("loaded at once" in str(run(f"return LOG[{i}]")) for i in range(1, 6))
          and any("follow their company" in str(run(f"return LOG[{i}]")) for i in range(1, 6)))
    run("deliver(202)")
    check("  its own company's delivery still counted", run("return CONTRACT.delivered") == 1)
    n0 = run("return #LOG")
    run("CO.installContracts(ENV); CO.installContracts(ENV)")
    check("  at every update after that: nothing again (the list of types read once, each type wrapped once)",
          run("return #LOG") == n0 and run("return LOADS") == 1)
    # the engine's second simulation state: its own `game` table, the same CO module (CO.contractRefs kept): wrapped there too
    run("GAME1 = game; game = { ['::/game_mechanics/subventions/subventions.script'] = { handleEvent = function() end } }; CONTRACT = { uid = 5, mpfOwner = 2, delivered = 0 }")
    run("CO.installContracts(ENV); deliver(101)")
    check("the second simulation state (its own game table): its type loaded and wrapped as well, the other company's delivery not counted",
          run("return CONTRACT.delivered") == 0 and run("return LOADS") == 2, (run("return CONTRACT.delivered"), run("return LOADS")))
    # a type the loader cannot load: tried once per state, never at every update
    run("game = { ['::/game_mechanics/subventions/subventions.script'] = { handleEvent = function() end } }; FAILS = 0; loaderHelper = { useFn = function() FAILS = FAILS + 1; error('no such script') end }")
    n1 = run("return #LOG")
    run("for i = 1, 20 do CO.installContracts(ENV) end")
    tries = sum(1 for i in range(n1 + 1, run("return #LOG") + 1) if "loaded at once" in str(run(f"return LOG[{i}]")))
    check("a type that cannot be loaded: tried once, logged once (not at every update)", run("return FAILS") == 1 and tries == 1, (run("return FAILS"), tries))

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
