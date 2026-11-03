"""Offline test of the dots of their company's colour over the other companies' vehicles (0.6.10, U.dotsTick in the interface).

A Discord suggestion of 2026-11-01: in a game with one company per player, whose bus is this? Every second, the vehicles of another
company near the camera get the game's short-lived HUD image tinted with their company's colour. U.dotsTick is taken from the
real interface script and run through lupa (Lua 5.2) with a mocked game. Cases:
  - the other company's vehicles near the camera get a dot of that company's colour, not this game's own;
  - the farthest beyond U.DOTS_RANGE: none; at most U.DOTS_MAX, the nearest;
  - one round per U.DOTS_EVERY seconds;
  - nothing with one company, with the camera high above the ground, with "dots=0" in the preferences or MPFEVER_DOTS=0;
  - the Settings tab has the switch, kept in the preferences across launches.
Run: python tests/test_dots.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(UI, encoding="utf-8").read()
    m = re.search(r"^U\.DOTS_EVERY, .*?^U\.dotsTick = function\(\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: U.dotsTick not found in the interface script")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
NOW = 100
os.clock = function() return NOW end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
PREFS = {}
U = { loadPrefs = function() return PREFS end, myCo = 1, coMap = { [500] = 1, [600] = 2 }, coColors = { [1] = 3, [2] = 7 } }
ug_require = function(n) return { rgb = function(ix) return ix / 10, 0, 0 end } end
-- vehicles: id -> { owner player, x, y }
VEH = {}
OWNED = function(v) return VEH[v] and VEH[v][1] end
ownerOf = function(v) return OWNED(v) end
SPAWNS = {}
CAM = { x = 0, y = 0, h = 300 }
api = {
  type = { ComponentType = { TRANSPORT_VEHICLE = 'tv' }, Vec4f = { new = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }, Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end } },
  gui = {
    camera = { getCenter = function() return { x = CAM.x, y = CAM.y, z = 0 } end, getHeightAboveTerrain = function() return CAM.h end },
    spawnEphemeralHudImage = function(icon, e, col, pos, dur, fi, fo) SPAWNS[#SPAWNS + 1] = { e = e, r = col.r, dur = dur, z = pos and pos.z, icon = icon } end,
  },
  engine = {
    forEachEntityWithComponent = function(fn, ct) local ids = {} for v in pairs(VEH) do ids[#ids + 1] = v end table.sort(ids) for _, v in ipairs(ids) do fn(v) end end,
    util = { vehicle = { getPosition = function(v) return { x = VEH[v][2], y = VEH[v][3], z = 0 } end } },
  },
}
""" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")

    run("VEH = { [11] = { 600, 100, 0 }, [12] = { 500, 50, 0 }, [13] = { 600, 9000, 0 } }; SPAWNS = {}; U.dotsTick()")
    check("the other company's vehicle near the camera: one dot", run("return #SPAWNS") == 1 and run("return SPAWNS[1].e") == 11)
    check("of that company's colour (index 7)", abs(run("return SPAWNS[1].r") - 0.7) < 1e-9)
    check("lasting until the next round", run("return SPAWNS[1].dur") >= run("return U.DOTS_EVERY"))
    check("above the vehicle", run("return SPAWNS[1].z") == run("return U.DOTS_LIFT"))
    check("MPFever's own disc (the game's grey icons are opaque)", run("return SPAWNS[1].icon") == "mpfever_1::/mpfever_dot.tga")
    check("logged once", any("dots of their company's colour" in str(x) for x in run("return LOG").values()))
    run("SPAWNS = {}; NOW = 100.1; U.dotsTick()")
    check("one round per U.DOTS_EVERY", run("return #SPAWNS") == 0)
    run("NOW = 100.3; U.dotsTick()")
    check("the next round: again", run("return #SPAWNS") == 1)

    run("VEH = {}; for i = 1, 300 do VEH[1000 + i] = { 600, i * 3, 0 } end; SPAWNS = {}; NOW = 110; U.dotsTick()")
    check("at most U.DOTS_MAX dots", run("return #SPAWNS") == run("return U.DOTS_MAX"))
    check("the nearest ones", run("local m = 0 for _, s in ipairs(SPAWNS) do if s.e > m then m = s.e end end return m") == 1000 + run("return U.DOTS_MAX"))

    run("VEH = { [11] = { 600, 100, 0 } }; SPAWNS = {}; NOW = 120; CAM.h = 5000; U.dotsTick()")
    check("camera high above the ground: none", run("return #SPAWNS") == 0)
    run("CAM.h = 300; SPAWNS = {}; NOW = 130; PREFS.dots = '0'; U.dotsTick()")
    check("dots=0 in the preferences: none", run("return #SPAWNS") == 0)
    run("PREFS.dots = nil; SPAWNS = {}; NOW = 140; ENV.MPFEVER_DOTS = '0'; U.dotsTick()")
    check("MPFEVER_DOTS=0: none", run("return #SPAWNS") == 0)
    run("ENV.MPFEVER_DOTS = nil; SPAWNS = {}; NOW = 150; U.coMap = { [500] = 1 }; U.dotOwner = nil; U.dotsTick()")
    check("one company: none", run("return #SPAWNS") == 0)
    run("U.coMap = { [500] = 1, [600] = 2 }; SPAWNS = {}; NOW = 160; U.dotsTick()")
    check("(two again: the dot is back)", run("return #SPAWNS") == 1)

    check("the Settings tab has the switch", "A dot of their colour over the other companies' vehicles" in src and "p.dots = v == 1 and \"1\" or \"0\"; U.saveGlobalPrefs()" in src)
    check("kept across launches", 'aichat = true, dots = true' in src and '"dots=" .. tostring(p.dots or "1")' in src)
    check("called from the interface's tick", "pcall(U.dotsTick)" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
