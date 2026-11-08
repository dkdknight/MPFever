"""Offline test of the host's mod commands (0.7.1, issue #128: Improved Destination Displays, G.modSkip, executeActionOnce).

Issue #128 (Flubi, 0.7.0): with about 200 vehicles the game got slower and slower. The mod Improved Destination Displays names
every vehicle after its destination: each 2 s of game time it reads every vehicle's name and sends makeEntitySetNameCmd when the
name differs. MPFever ships the host's mod commands to every game (DET.installModCmds), but every game skipped them unless the
entity was a line: the name never changed, the mod sent it again 2 s later, without end (206000 commands for 60 vehicles in one
session, 176 different names, 118000 actions, logs above 100 MB, the game at half its speed).
  - a mod's name goes on any entity that has a name here, a colour on any entity with a colour, a line update still needs a line
    (MPFEVER_MODANYTARGET=0: lines only, as before);
  - the host leaves out a name the entity already has (in its simulation and before shipping), the same command again within
    10 s of game time, and the same command a 4th time when it changed nothing (one log line); another value is always shipped
    (MPFEVER_MODDEDUP=0: every command shipped, as before);
  - a fake renaming mod, 200 vehicles, one hour of game time: names applied -> one command per change; names refused -> at most
    3 commands per vehicle and value, then quiet.
Needs lupa (pip install lupa). Run: python tests/test_moddedup.py
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


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read()
i = bridge.find("G.modSlots = {}\nG.modSkip = function(p, now, nameOf)")
check(i > 0, "G.modSkip found")
body = bridge[i:bridge.index("\nend\n", i) + 5]
ser = re.search(r"^function C\.int\(.*?^end\n", common, re.S | re.M).group(0) + \
    re.search(r"^function C\.ser\(.*?^end\n", common, re.S | re.M).group(0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
C = {}
G = {}
ENV = {}
LOG = {}
os.getenv = function(k) return ENV[k] end
function log(s) LOG[#LOG + 1] = s end
local QUOTE, BS = '"', "\\\\"
local ESCAPED = "[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. QUOTE .. BS .. BS .. "]"
local function escapeChar(c) return string.format("\\\\%03d", c:byte()) end
''' + ser + body)
L.execute('''
NAMES = {}
function nameOf(e) return NAMES[e] end
function req(e, name, mod) return { fn = "makeEntitySetNameCmd", args = { e, name, n = 2 }, mod = mod or "destination_displays.script.tl" } end
''')
skip = L.eval("function(e, name, now) return G.modSkip(req(e, name), now, nameOf) end")

L.execute('NAMES[1] = "RV0001||Kapellenweg"')
check(skip(1, "RV0001||Kapellenweg", 1000) is True, "a name the entity already has: left out")
check(skip(1, "RV0001||Bahnhof", 2000) is False, "a new name: shipped")
check(skip(1, "RV0001||Bahnhof", 4000) is True, "the same name 2 s later (still on its way): left out")
check(skip(1, "RV0001||Bahnhof", 11000) is True, "and 9 s later")
check(skip(1, "RV0001||Bahnhof", 12500) is False, "10 s later and still not applied: shipped again (1 change for nothing)")
check(skip(1, "RV0001||Bahnhof", 23000) is False, "again 10 s later (2)")
n0 = len(L.eval("LOG"))
check(skip(1, "RV0001||Bahnhof", 34000) is True, "a 3rd time for nothing: no longer shipped")
check(len(L.eval("LOG")) == n0 + 1 and "changed nothing 3 times" in L.eval("LOG")[n0 + 1], "one log line")
check(skip(1, "RV0001||Bahnhof", 90000) is True and len(L.eval("LOG")) == n0 + 1, "quiet afterwards")
check(skip(1, "RV0001||Kapellenweg", 91000) is True, "the name it has: left out")
check(skip(1, "RV0001||Markt", 92000) is False, "another name: shipped again")
L.execute('NAMES[1] = "RV0001||Markt"')
check(skip(1, "RV0001||Kapellenweg", 94000) is False, "back to the first terminal: shipped")
L.execute('NAMES[1] = "RV0001||Kapellenweg"')
check(skip(1, "RV0001||Markt", 96000) is False, "and to the second again: shipped (a vehicle going back and forth)")
check(skip(2, "X", 96000) is False and skip(3, "X", 96000) is False, "each entity has its own slot")
other = L.eval('function(now) return G.modSkip({ fn = "makeEntitySetColorCmd", args = { 7, { x = 1, y = 0, z = 0 }, n = 2 }, mod = "m" }, now, nameOf) end')
check(other(1000) is False and other(3000) is True and other(12000) is False, "a colour: the same in flight left out, shipped again after 10 s")
check(L.eval('G.modSkip({ fn = "makeLineUpdateCmd", args = { "x" } }, 0, nameOf)') is False, "no entity: shipped as it is")
L.execute('ENV.MPFEVER_MODDEDUP = "0"')
check(skip(1, "RV0001||Kapellenweg", 99000) is False, "MPFEVER_MODDEDUP=0: everything shipped")
L.execute('ENV.MPFEVER_MODDEDUP = nil')

print("a fake renaming mod: 200 vehicles, one hour of game time")


def run(applied):
    L.execute('G.modSlots = {}; NAMES = {}; LOG = {}; for v = 1, 200 do NAMES[v] = "Bus " .. v end')
    return L.eval('''function(applied)
      local shipped, inflight, changes = 0, {}, 0
      for t = 0, 3600000, 2000 do
        -- the commands shipped earlier are applied 400 ms later on every game (when applied)
        for v, c in pairs(inflight) do if applied and c.t + 400 <= t then NAMES[v] = c.name end end
        if applied then inflight = {} end
        for v = 1, 200 do
          -- the mod: the destination changes every 5 minutes (a terminal of two), named when it differs
          local dest = (math.floor((t + v * 1000) / 300000) % 2 == 0) and "Bahnhof" or "Markt"
          local wanted = "RV" .. v .. "||" .. dest
          if NAMES[v] ~= wanted then
            if t > 0 and not inflight[v] and (applied) then changes = changes + 1 end
            if not G.modSkip(req(v, wanted), t, nameOf) then shipped = shipped + 1; inflight[v] = { t = t, name = wanted } end
          end
        end
      end
      return shipped
    end''')(applied)


shipped_ok = run(True)
check(shipped_ok <= 200 * 13, "names applied: about one command per change (%d for 200 vehicles x 12 changes)" % shipped_ok)
shipped_bad = run(False)
check(shipped_bad <= 200 * 13 * 3, "names refused everywhere: at most 3 per vehicle and value (%d; before: %d)" % (shipped_bad, 200 * 1800))

print("the other games apply the names")
# (0.7.12, #162: the same check covers a name from anyone and a game script's colour too, see test_nameguard0712.py)
i = bridge.find('if (a.tok == "mod" or nameGuard) and type(a.args) == "table" then')
seg = bridge[i:i + 1200]
check("api.type.ComponentType.NAME" in seg and "api.type.ComponentType.COLOR" in seg and 'need, what = api.type.ComponentType.LINE, "a line"' in seg,
      "a name on anything with a name, a colour on anything with a colour, a line update on a line")
check('os.getenv("MPFEVER_MODANYTARGET") ~= "0"' in seg, "MPFEVER_MODANYTARGET=0: lines only")
i = bridge.find("api.cmd.sendCommand = function(cmd, cb, ...)")
seg = bridge[i:i + 3000]
check('tag.name == "makeEntitySetNameCmd"' in seg and "nc.name == tag.args[2]" in seg and "pcall(cb, nil, true, {})" in seg,
      "the host's simulation leaves out a name the entity already has")
check("elseif G.modSkip(p, gameTime(), function(x)" in bridge, "the interface half leaves out what G.modSkip says")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
