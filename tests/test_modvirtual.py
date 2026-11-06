"""Offline test of the mods' files named by their game path (0.7.2, Advanced Station Builder for real).

The user's dedicated server session of 2026-11-06 with 0.7.1 and the real Advanced Station Builder (mod.io 6484902): 17 desyncs
and 5 reloads, "conParams" and "ages" apart after every station, the client always one or two builds ahead of the server, and
not one command of the mod shipped (only Parallel Tracks'). The mod's game script loads its builds with
ug_require("advanced_station_builder::/stations/advanced_station_builder/links.lua"): debug.getinfo gives that game path as the
file's source, with no "/mods/" in it, so mpfever_modauto.lua did not take it for a mod's file and the command went to the
builder's engine alone. 0.7.1 had been checked with a test mod loaded from its folder on the disk.
  - a game path with a mod before "::/" is a mod's file; the base game's ("::/...") and MPFever's are not;
  - MPFEVER_MODVIRTUAL=0: the disk paths only, as before;
  - the game scripts' hook ships such a command;
  - with one company per player, a build is the company's it is made for (the Context's player, its first construction's
    playerEntity, else the owner of what it takes away): this player's own one is sent even long after their last build,
    another company's is left to that company's game (MPFEVER_GSOWNER=0: as before).
Needs lupa (pip install lupa). Run: python tests/test_modvirtual.py
"""
import os, sys

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


modauto = open(os.path.join(CONTENT, "mpfever_modauto.lua"), encoding="utf-8").read()
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
i = bridge.find("G.gsHook = function()")
j = bridge.find("\nend\n", bridge.find("G.gsAnswer = function(r)", i)) + 5
check(i > 0 and j > i, "the game scripts' hook found")
code = bridge[i:j]

ASB = "@advanced_station_builder::/stations/advanced_station_builder/links.lua"
ASB_TL = "@advanced_station_builder::/stations/advanced_station_builder/links.script.tl"
BASE = "@::/game_mechanics/towns/town_notification.script.lua"
MPF_V = "@mpfever_1::/mpfever_modauto.lua"
DISK = "@C:/Users/Public/mod.io/10640/mods/6419266/content/gui/x.lua"


def modautoRuntime(env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end")
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute("MA = (function() %s end)()" % modauto)
    return L


L = modautoRuntime()
isMod = L.eval("MA.isModSource")
check(isMod(ASB) is True, "Advanced Station Builder's links.lua by its game path: a mod's file")
check(isMod(ASB_TL) is True, "its game script (links.script.tl) too")
check(isMod(BASE) is False, "the base game's own file (no mod before ::/): not a mod's")
check(isMod(MPF_V) is False, "MPFever's own file by its game path: not a mod's")
check(isMod(DISK) is True, "a mod's file by its place on the disk: still a mod's")
check(isMod("=[C]") is False and isMod("") is False, "C functions and empty names: not a mod's")
check(L.eval("MA.label")(ASB) == "advanced_station_builder:links.lua", "its label names the mod (%s)" % L.eval("MA.label")(ASB))
check(L.eval("MA.strictOf({ \"%s\" })" % ASB) is None, "not one of the strict mods")
L0 = modautoRuntime({"MPFEVER_MODVIRTUAL": "0"})
check(L0.eval("MA.isModSource")(ASB) is False and L0.eval("MA.isModSource")(DISK) is True, "MPFEVER_MODVIRTUAL=0: the disk paths only, as before")


def hookRuntime(role="client", separate=False, env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
    ENV = {}
    os.getenv = function(k) return ENV[k] end
    LINES, LOG, NATIVE = {}, {}, {}
    function log(s) LOG[#LOG + 1] = s end
    BS = "/"
    package.loaded["mpfever_local_activity"] = nil
    ''')
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute('''
    MODAUTO = (function() %s end)()
    function ug_require(p) if p == "mpfever_modauto.lua" then return MODAUTO end error("no " .. p) end
    ORIG = { }
    C = { ROLE = "%s", ACTIVE = true, NAME = "Client", DIR = "D",
      FACTORIES = { "makeWorldBuildProposalCmd" },
      origCmds = function() return ORIG end,
      marshal = function(v) return v end,
      appendFile = function(path, line) LINES[#LINES + 1] = { path = path, line = line } return true end,
      line = function(kind, p) return { kind = kind, p = p } end }
    -- companies 1 (the host's, player entity 101) and 2 (this game's, player entity 102); entity 900 is company 1's station
    R = { CO = { mode = "%s", list = { { id = 1, ent = 101 }, { id = 2, ent = 102 } } }, translateOut = function() end,
          ownerOf = function(e) if e == 900 then return 101 elseif e == 901 then return 102 end return nil end }
    CO = { idOfEntity = function(reg, e) for _, c in ipairs(reg.list) do if c.ent == e then return c.id end end return nil end }
    G = { myCo = 2, rev = {}, session = {} }
    api = { cmd = { makeWorldBuildProposalCmd = function(...) return { cmd = "build", args = { ... } } end } }
    api.cmd.sendCommand = function(cmd, cb) NATIVE[#NATIVE + 1] = cmd.cmd; if cb then cb("native", true) end end
    ORIG.sendCommand = api.cmd.sendCommand
    STACK = {}
    debug = { getinfo = function(lv, what) local s = STACK[lv - 2] if not s then return nil end return { source = s, what = s == '=[C]' and 'C' or 'Lua' } end }
    ''' % (modauto, role, "separate" if separate else "shared"))
    L.execute(code)
    L.execute("G.installGsMods()")
    return L


def send(L, stack, proposal, context="nil", idle=2):
    L.execute("STACK = {}")
    for k, s in enumerate(stack):
        L.execute('STACK[%d] = "%s"' % (k + 1, s))
    if idle is None:
        L.execute('package.loaded["mpfever_local_activity"] = nil')
    else:
        L.execute('package.loaded["mpfever_local_activity"] = os.clock() - %d' % idle)
    L.execute("api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(%s, %s, true, false), function() end)" % (proposal, context))
    return len(L.eval("LINES")), len(L.eval("NATIVE"))


# the real case: links.unmark called from the mod's guiUpdate, MPFever's frames not on the stack (the game calls the script)
UNMARK = "{ constructionsToAdd = { { playerEntity = 102 } }, constructionsToRemove = { 901 } }"
L = hookRuntime()
check(send(L, [ASB, ASB_TL], UNMARK) == (1, 0), "the mod's station rebuild (links.unmark) right after the player's build: shipped, not applied here alone")
check(any("advanced_station_builder:links.lua" in s for s in L.eval("LOG").values()), "the log names the mod")
Lv = hookRuntime(env={"MPFEVER_MODVIRTUAL": "0"})
check(send(Lv, [ASB, ASB_TL], UNMARK) == (0, 1), "MPFEVER_MODVIRTUAL=0: to this game's engine alone, as in the server session")
check(send(hookRuntime(), [BASE], UNMARK) == (0, 1), "the base game's script: to the engine as before")

# one company per player: whose build it is
Ls = hookRuntime(separate=True)
check(send(Ls, [ASB], UNMARK, idle=300) == (1, 0), "one company per player: a rebuild made for this game's company, long after its build: shipped")
JOIN = "{ streetProposal = {} }"
check(send(Ls, [ASB], JOIN, context="{ player = 102 }", idle=300) == (2, 0), "the throats' tracks with this game's player in the Context: shipped")
check(send(Ls, [ASB], JOIN, context="{ player = 101 }", idle=300) == (2, 0), "another company's build, long after this player's build: left to its game")
check(send(Ls, [ASB], "{ constructionsToRemove = { 900 } }", idle=300) == (2, 0), "taking away another company's station: left to its game")
check(send(Ls, [ASB], "{ constructionsToRemove = { 901 } }", idle=300) == (3, 0), "taking away this company's station: shipped")
Lo = hookRuntime(separate=True, env={"MPFEVER_GSOWNER": "0"})
check(send(Lo, [ASB], UNMARK, idle=300) == (0, 0), "MPFEVER_GSOWNER=0: only the time since the player's build decides, as before (dropped on a client)")

check("pcall(G.asbTest)" in bridge and 'os.getenv("MPFEVER_ASBTEST") ~= "1"' in bridge, "the in-game test (MPFEVER_ASBTEST=1) runs only when asked")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
