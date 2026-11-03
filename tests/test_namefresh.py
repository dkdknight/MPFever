"""Offline test of the names part of the checks (0.6.11, issue #121): a station, line or vehicle counts there once it was there at
the game's previous check, or at its load.

Issue #121 (an English and a German game): every purchase made the names part differ for one check, "slight simulation drift
(names)", because a new vehicle has the default name of its game's language ("Strassenfahrzeug 1" on Balle's game, "Road Vehicle
225" on the host's) until the host's names of that check arrive; meanwhile the lines and vehicles were not compared (the
launcher leaves them out while the names differ). mpfever_refs.lua is loaded whole through lupa (Lua 5.2) with a mocked world,
as in test_namesync.py. Cases:
  - two games, the same savegame loaded (R.nameSeed): the first check counts the loaded names on both;
  - a vehicle bought before the next check, named in each game's language: that check is equal, and counts it not;
  - the host's name taken before the check after: equal, and counted then;
  - a name the host's game never sent (a real difference): different from the check after on;
  - a vehicle sold: out of the count at once, on both;
  - R.nameSeed(true) (a game that sends no names) sets what the first check counts, not the names baseline;
  - MPFEVER_NAMEFRESH=0: every name counted, the new vehicle's check differs, as before.
Run: python tests/test_namefresh.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
REFS = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_refs.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
NAMES, KIND = {}, {}
local function sorted(ct) local r = {} for e, k in pairs(KIND) do if k == ct then r[#r + 1] = e end end table.sort(r) return r end
api = {
  type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = {
    entityExists = function(e) return KIND[e] ~= nil end,
    getComponent = function(e, ct)
      if ct == "NAME" then return KIND[e] and { name = NAMES[e] or "" } or nil end
      if KIND[e] == ct then return {} end
      return nil
    end,
    forEachEntityWithComponent = function(fn, ct) for _, e in ipairs(sorted(ct)) do fn(e) end end,
    system = { lineSystem = { getLines = function() return sorted("LINE") end } },
  },
}
function log(s) end
'''

# (one game: its own copy of the refs module and of its world)
def game(L_src):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.globals().R = L.execute(L_src)
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    return run


CHECK = r'''
R.hashSkip = setmetatable({}, { __index = function(_, k) return k ~= "names" end })
local parts = R.contentHash(function(seed, s) local h = seed for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end return h end, tostring)
R.hashSkip = nil
return tostring(parts.names)
'''

WORLD = r'''
KIND = { [10] = "STATION_GROUP", [20] = "LINE", [30] = "TRANSPORT_VEHICLE" }
NAMES = { [10] = "Halle", [20] = "Linie 1", [30] = "Bus 1" }
'''


def main():
    src = open(REFS, encoding="utf-8").read()
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
        if not cond:
            fails.append(name)

    host, other = game(src), game(src)
    for g in (host, other):
        g(WORLD)
    host("R.nameSeed(false)")
    other("R.nameSeed(true)")
    h1, o1 = host(CHECK), other(CHECK)
    check("the first check after the load: the loaded names, on both", h1 == o1 and h1.startswith("3/"), f"{h1} | {o1}")
    check("R.nameSeed(true) leaves the names baseline alone", other("return R.namesPrev == nil") is True)
    check("R.nameSeed(false) sets it", host("return R.namesPrev ~= nil") is True)
    # a vehicle bought between two checks, named in each game's language
    host('KIND[31] = "TRANSPORT_VEHICLE"; NAMES[31] = "Road Vehicle 225"')
    other('KIND[31] = "TRANSPORT_VEHICLE"; NAMES[31] = "Strassenfahrzeug 1"')
    h2, o2 = host(CHECK), other(CHECK)
    check("the check after a purchase is equal (the new vehicle not counted yet)", h2 == o2 and h2.startswith("3/"), f"{h2} | {o2}")
    # the host's names of that check reach the other game
    other('NAMES[31] = "Road Vehicle 225"')
    h3, o3 = host(CHECK), other(CHECK)
    check("the check after: equal, the vehicle counted", h3 == o3 and h3.startswith("4/"), f"{h3} | {o3}")
    # a real difference: a name the other game never took
    other('NAMES[30] = "Autobus 1"')
    h4, o4 = host(CHECK), other(CHECK)
    check("a name that differs for good: the part differs", h4 != o4, f"{h4} | {o4}")
    other('NAMES[30] = "Bus 1"')
    # a vehicle sold
    for g in (host, other):
        g("KIND[31] = nil; NAMES[31] = nil")
    h5, o5 = host(CHECK), other(CHECK)
    check("a vehicle sold: out of the count at once, on both", h5 == o5 and h5.startswith("3/"), f"{h5} | {o5}")

    # MPFEVER_NAMEFRESH=0: every name counted, as before
    host, other = game(src), game(src)
    for g in (host, other):
        g(WORLD + 'ENV = { MPFEVER_NAMEFRESH = "0" }')
        g("R.nameSeed(false)")
        g(CHECK)
    host('KIND[31] = "TRANSPORT_VEHICLE"; NAMES[31] = "Road Vehicle 225"')
    other('KIND[31] = "TRANSPORT_VEHICLE"; NAMES[31] = "Strassenfahrzeug 1"')
    h6, o6 = host(CHECK), other(CHECK)
    check("MPFEVER_NAMEFRESH=0: the check after a purchase differs, as before", h6 != o6 and h6.startswith("4/"), f"{h6} | {o6}")

    # the bridge seeds every game at a load (the host's names baseline too)
    bridge = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
    check("the bridge seeds every game at a load, twice (simulation and interface)", bridge.count("pcall(R.nameSeed, not K.nameSyncOn())") == 2)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
