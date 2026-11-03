"""Offline test of the player a construction's replay is converted for (0.6.10, G.conOwner in the bridge).

Tests nr2 to nr7 of 2026-11-03 (Test Gameplay, its rules one company per player): the host's player edited a station of company
2, a company no player plays. The engine kept the station's owner on the host's game (an edit keeps it; the proposal names the
host's player) and booked the edit there; the other game's replay was converted by the engine for the replaying company (the
context's player), company 1: owners and money apart at every check (0.6.9 as well). An edit is now converted for the owner of
the construction it replaces. G.conOwner is taken from the real bridge and run through lupa (Lua 5.2) with mocks.
Cases:
  - an edit (the same construction file taken away and added) of company 2's station: converted for company 2's player, logged;
  - a new construction in place of another one (another file), an edit of the context's own station, an owner that is no
    player here, nothing taken away: left alone;
  - MPFEVER_CONOWNER=0: left alone;
  - the native construction replay calls it on its context.
Run: python tests/test_conowner.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"^G\.conOwner = function\(a, m, ctx\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: G.conOwner not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
G = {}
PLAYERS = { [31434] = true, [46534] = true }
-- constructions: id -> { file, owner }
CONS = { [700] = { "::/stations/rail/modular_station/modular_station.con", 46534 }, [701] = { "::/depots/road/road_depot.con", 46534 },
  [702] = { "::/stations/rail/modular_station/modular_station.con", 31434 }, [703] = { "::/stations/rail/modular_station/modular_station.con", 999 } }
api = { type = { ComponentType = { PLAYER = 'player', CONSTRUCTION = 'con', PLAYER_OWNED = 'po' } }, engine = { getComponent = function(e, ct)
  if ct == 'player' then return PLAYERS[e] and {} or nil end
  local c = CONS[e]
  if ct == 'con' then return c and { fileName = c[1]:gsub("^::/", "") } or nil end
  if ct == 'po' then return c and { player = c[2] } or nil end
end } }
STATION = "::/stations/rail/modular_station/modular_station.con"
function OWNER(rm, file) local ctx = { player = 31434 }; M = { toRemove = { rm }, toAdd = { { fileName = file or STATION, playerEntity = 31434 } } }; G.conOwner({ uid = 'Host:3' }, M, ctx); return ctx.player end
""" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    check("an edit of company 2's station by company 1: converted for company 2's player", run("return OWNER(700)") == 46534)
    check("and built for it (the construction's own player, which the conversion and the build take)", run("return M.toAdd[1].playerEntity") == 46534)
    check("and logged", "an edit, built for the owner of what it replaces, 46534" in str(run("return LOG[#LOG]")))
    check("a new construction in place of another company's (another file): left alone", run("return OWNER(701)") == 31434)
    check("an edit of its own station: left alone", run("return OWNER(702)") == 31434)
    check("an owner that is no player here: left alone", run("return OWNER(703)") == 31434)
    check("nothing taken away (a new construction): left alone",
          run("local ctx = { player = 31434 }; G.conOwner({}, { toRemove = {}, toAdd = { { fileName = STATION, playerEntity = 31434 } } }, ctx); return ctx.player") == 31434)
    check("MPFEVER_CONOWNER=0: left alone", run("ENV.MPFEVER_CONOWNER = '0'; local x = OWNER(700); ENV.MPFEVER_CONOWNER = nil; return x") == 31434)
    check("the native construction replay calls it on its context", "ctx.player = api.engine.util.getPlayer()\n\tpcall(G.conOwner, a, m, ctx)" in src)
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
