"""Offline test of the mods' game script commands sent from the interface (0.7.1, Advanced Station Builder, G.installGsMods).

The user's dedicated server session of 2026-11-05: after every station of Advanced Station Builder (mod.io 6484902) the checks
found "conParams" apart 5 s later. The mod's game script (links.script, interface half) builds the station anew without the
setting that keeps it from snapping while it is placed (links.unmark), then joins its throats and puts up their signals, all
from its guiUpdate on the builder's game. MPFever's interface hook (mpfever_ui.script.lua) wraps the commands of the interface's
own state only: in the game scripts' interface state nothing was wrapped, the command went to the builder's engine alone (no
act in the client's out.log, "1 stations built anew without the marker: done" in its log, nothing on the server).
  - the bridge wraps the commands there (its own interface state); a mod's command is written to ui.log as an "act_req" (then
    stamped and applied by every game like the interface's commands), when mpfever_modauto.lua says this game sends it: the
    player's own job (within 15 s of their build), else the host's game, or the owner company's;
  - its callback is answered when the command is applied here, with the engine's verdict;
  - the game's own scripts' commands and MPFever's go to the engine as before, and outside a session everything does;
  - not installed when the interface's hook already watches this state, nor with MPFEVER_GSMODS=0.
Needs lupa (pip install lupa). Run: python tests/test_gsmods.py
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


bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
i = bridge.find("G.gsHook = function()")
j = bridge.find("\nend\n", bridge.find("G.gsAnswer = function(r)", i)) + 5
check(i > 0 and j > i, "G.installGsMods found")
code = bridge[i:j]
modauto = open(os.path.join(CONTENT, "mpfever_modauto.lua"), encoding="utf-8").read()

ASB = "@C:/Users/Public/mod.io/10640/mods/6484902/content/stations/advanced_station_builder/links.lua"
BASE = "@::/game_mechanics/towns/town_notification.script.lua"
MPF = "@E:/Steam/userdata/x/3493540/local/mods/mpfever_1/content/mpfever_bridge.script.lua"


def runtime(role="client", env=None, uiHooked=False, active=True, debuglib=True):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
    ENV = {}
    os.getenv = function(k) return ENV[k] end
    LINES, LOG, NATIVE = {}, {}, {}
    function log(s) LOG[#LOG + 1] = s end
    BS = "/"
    package.loaded["mpfever_local_activity"] = nil
    MODAUTO = (function() %s end)()
    function ug_require(p) if p == "mpfever_modauto.lua" then return MODAUTO end error("no " .. p) end
    ORIG = { }
    C = { ROLE = %s, ACTIVE = %s, NAME = "Knight-HD2", DIR = "D",
      FACTORIES = { "makeWorldBuildProposalCmd", "makeLineUpdateCmd", "makeGameSetSpeedCmd" },
      origCmds = function() return ORIG end,
      marshal = function(v) return v end,
      appendFile = function(path, line) LINES[#LINES + 1] = { path = path, line = line } return true end,
      line = function(kind, p) return { kind = kind, p = p } end }
    R = { CO = { mode = "%s" }, translateOut = function() end, ownerOf = function(e) return OWNERS and OWNERS[e] end }
    CO = { idOfEntity = function(reg, e) return e end }
    G = { myCo = 2, rev = {}, session = {} }
    local function factory(name) return function(...) return { cmd = name, args = { ... } } end end
    api = { cmd = { makeWorldBuildProposalCmd = factory("build"), makeLineUpdateCmd = factory("line"), makeGameSetSpeedCmd = factory("speed") } }
    api.cmd.sendCommand = function(cmd, cb) NATIVE[#NATIVE + 1] = cmd.cmd; if cb then cb("native", true) end end
    ORIG.sendCommand = api.cmd.sendCommand
    STACK = {}
    ''' % (modauto, '"%s"' % role if role else "nil", "true" if active else "false", "separate"))
    if not debuglib:
        L.execute("debug = nil")
    else:
        L.execute("debug = { getinfo = function(lv, what) local s = STACK[lv - 2] if not s then return nil end return { source = s, what = s == '=[C]' and 'C' or 'Lua' } end }")
    if uiHooked:
        L.execute("api.cmd.sendCommand = function(cmd, cb) NATIVE[#NATIVE + 1] = 'ui:' .. cmd.cmd end")
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute(code)
    L.execute("G.installGsMods()")
    return L


def send(L, stack, idle=2):
    L.execute("STACK = {}")
    for k, s in enumerate(stack):
        L.execute('STACK[%d] = "%s"' % (k + 1, s))
    if idle is None:
        L.execute('package.loaded["mpfever_local_activity"] = nil')
    else:
        L.execute('package.loaded["mpfever_local_activity"] = os.clock() - %d' % idle)
    L.execute("ANSWER = nil")
    L.execute('api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd({ constructionsToRemove = { 4711 } }, nil, true, false), function(a, ok) ANSWER = { a = a, ok = ok } end)')


L = runtime()
check(any("watched (2 factories)" in s for s in L.eval("LOG").values()), "installed: the factories wrapped (the speed left out)")
send(L, ["=[C]", ASB, ASB])
lines = L.eval("LINES")
check(len(lines) == 1 and lines[1].path == "D/ui.log" and lines[1].line.kind == "act_req", "Advanced Station Builder's build right after the player's: written to ui.log as an act_req")
p = lines[1].line.p if len(lines) else None
check(p is not None and p.fn == "makeWorldBuildProposalCmd" and str(p.tok).startswith("gsmod-") and p.id == 1, "its tok and number (%s)" % (p and p.tok))
check(len(L.eval("NATIVE")) == 0, "not sent to this game's engine alone")
check(L.eval("ANSWER") is None, "no answer yet: the mod waits until it is applied")
L.execute('G.gsAnswer({ tok = package.loaded["mpfever_gs_hook"].tok, id = 1, success = true })')
check(L.eval("ANSWER") is not None and L.eval("ANSWER.ok") is True, "answered when applied here, with the engine's verdict")
L.execute("ANSWER = nil")
L.execute('G.gsAnswer({ tok = package.loaded["mpfever_gs_hook"].tok, id = 1, success = true })')
check(L.eval("ANSWER") is None, "answered once")
L.execute('G.gsAnswer({ tok = "other", id = 2, success = false })')
check(L.eval("ANSWER") is None, "another game's result: nothing")

send(L, [BASE])
check(list(L.eval("NATIVE").values()) == ["build"] and L.eval("ANSWER.a") == "native", "the game's own script: to the engine as before")
n0 = len(L.eval("LINES"))
send(L, [MPF])
check(len(L.eval("NATIVE")) == 2 and len(L.eval("LINES")) == n0, "MPFever's own file alone: to the engine as before")
send(L, [ASB, MPF, MPF])
check(len(L.eval("LINES")) == n0 + 1, "a mod's callback called by MPFever (the next part of its job): shipped too")
L2 = runtime()
send(L2, [ASB], idle=60)
check(len(L2.eval("LINES")) == 0 and len(L2.eval("NATIVE")) == 0 and L2.eval("ANSWER") is None, "dropped on a client: neither shipped nor applied here")
L3 = runtime(role="host")
send(L3, [ASB], idle=60)
check(len(L3.eval("LINES")) == 1, "the host's game sends it")
L3.execute("G.session.resync = true")
send(L3, [ASB])
check(len(L3.eval("LINES")) == 1 and any("resynchronisation" in s for s in L3.eval("LOG").values()), "not sent during a resynchronisation")
L4 = runtime(role=None)
send(L4, [ASB])
check(len(L4.eval("LINES")) == 0 and len(L4.eval("NATIVE")) == 1, "no session: to the engine as before")
L5 = runtime(env={"MPFEVER_GSMODS": "0"})
send(L5, [ASB])
check(len(L5.eval("LINES")) == 0 and len(L5.eval("NATIVE")) == 1, "MPFEVER_GSMODS=0: as before")
L6 = runtime(uiHooked=True)
send(L6, [ASB])
check(len(L6.eval("LINES")) == 0 and list(L6.eval("NATIVE").values()) == ["ui:build"], "the interface's hook already in this state: left to it")
L7 = runtime(debuglib=False)
send(L7, [ASB])
check(len(L7.eval("NATIVE")) == 1 and any("no debug library" in s for s in L7.eval("LOG").values()), "no debug library: not watched, said in the log")

i = bridge.find("function G.reportResult(r)")
check("pcall(G.gsAnswer, r)" in bridge[i:i + 300], "every result goes by G.gsAnswer")
check("local okGs, errGs = pcall(G.installGsMods)" in bridge, "installed when the bridge's interface half starts")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
