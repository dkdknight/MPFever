"""Offline test of the mods' automatic interface commands (0.6.13, mod/mpfever_1/content/mpfever_modauto.lua).

Some mods send commands from their interface by themselves (their guiUpdate, a react.onStep of their windows): every game
sent the same command and it was applied once per player (two sets of a stop's decorations with Modern Bus Shelter, the
toll paid twice with PYT, the lines renamed back and forth by Line Roles...). Such a command now goes from one game only:
the host's, or with one company per player the game of the company that owns what it changes. Within 15 s of this
player's own action it is still sent (Auto Signals finishes the player's own signal), except for the mods known to act on
the whole world.

Part 1 runs mpfever_modauto.lua's decisions. Part 2 takes the interface's code (mpfever_ui.script.lua, from "mods'
automatic commands" to install) and runs it through lupa (Lua 5.2) with functions loaded under a mod's file name: a mod's
guiUpdate called "by the engine" (from Python, a C caller), the same command from a click (a game file in between), from
react.onStep, from a callback of an automatic command.
Run: python tests/test_modauto.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
MODAUTO = os.path.join(CONTENT, "mpfever_modauto.lua")
UI = os.path.join(CONTENT, "mpfever_ui.script.lua")

MODSRC = "@C:/Users/Public/mod.io/10640/mods/6419266/content/line_role_renamer/auto_scan.lua"
SIGSRC = "@C:/Users/Public/mod.io/10640/mods/6416560/content/auto_signals/auto_signals.script.lua"
GAMESRC = "@H:/SteamLibrary/steamapps/common/Transport Fever 3/base/content/gui/main/react.lua"


def main():
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    MA = L.execute(open(MODAUTO, encoding="utf-8").read())
    L.globals().MA = MA
    ev = L.eval("function(code) local f = assert(load(code)) return f() end")

    # ---- part 1: the decisions
    check("a mod.io file is a mod's", ev("return MA.isModSource('" + MODSRC + "')") is True)
    check("a Workshop file is a mod's", ev("return MA.isModSource('@D:/Steam/steamapps/workshop/content/3493540/123/content/x.lua')") is True)
    check("a local mod is a mod's", ev("return MA.isModSource('@E:/Steam/userdata/1/3493540/local/mods/aln_1/content/a.lua')") is True)
    check("the game's own file is not", ev("return MA.isModSource('" + GAMESRC + "')") is False)
    check("MPFever's own file is not", ev("return MA.isModSource('@C:/x/mods/mpfever_1/content/mpfever_ui.script.lua')") is False)
    check("Line Roles is a known world-wide mod", ev("return MA.strictOf({'" + MODSRC + "'})") == "Line Roles")
    check("Auto Signals is not", ev("return MA.strictOf({'" + SIGSRC + "'})") is None)

    def decide(f):
        return ev("local v, w = MA.decide(" + f + ") return v")

    check("a click is sent", decide("{ auto = false, mod = true, role = 'client' }") == "send")
    check("the game's own automatic command is sent", decide("{ auto = true, mod = false, role = 'client' }") == "send")
    check("no session: sent", decide("{ auto = true, mod = true, role = 'solo' }") == "send")
    check("automatic, shared, host: sent", decide("{ auto = true, mod = true, role = 'host' }") == "send")
    check("automatic, shared, client: not sent", decide("{ auto = true, mod = true, role = 'client' }") == "drop")
    check("automatic within 15 s of this player's action: sent (Auto Signals)",
          decide("{ auto = true, mod = true, role = 'client', idle = 3 }") == "send")
    check("automatic 20 s after: not sent", decide("{ auto = true, mod = true, role = 'client', idle = 20 }") == "drop")
    check("a world-wide mod, even right after an action: not sent",
          decide("{ auto = true, mod = true, role = 'client', idle = 1, strict = 'Line Roles' }") == "drop")
    check("one company per player, the client's own line: sent",
          decide("{ auto = true, mod = true, role = 'client', separate = true, owner = 'mine', strict = 'Line Roles' }") == "send")
    check("one company per player, another company's line on the host: not sent",
          decide("{ auto = true, mod = true, role = 'host', separate = true, owner = 'theirs', strict = 'Line Roles' }") == "drop")
    check("one company per player, nothing owned (decorations): the host's",
          decide("{ auto = true, mod = true, role = 'client', separate = true, strict = 'Modern Bus Shelter' }") == "drop"
          and decide("{ auto = true, mod = true, role = 'host', separate = true, strict = 'Modern Bus Shelter' }") == "send")

    # ---- part 2: the interface's code with a real Lua stack
    src = open(UI, encoding="utf-8").read()
    m = re.search(r"^-- -+ mods' automatic commands.*?(?=^local function install\(\))", src, re.S | re.M)
    if not m:
        print("FAIL: the mods' automatic commands block was not found in mpfever_ui.script.lua")
        return 1
    block = m.group(0)
    # (the module is given, not required)
    block = re.sub(r"^local okMA, MA = .*?\nif not \(okMA and type\(MA\) == \"table\"\) then MA = nil end\n", "", block, count=1, flags=re.S | re.M)
    mock = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
C = { ACTIVE = true, ROLE = "client" }
U = { stats = {}, status = { mode = "shared" } }
NOW = 1000
os.clock = function() return NOW end
OWNERS = {}
api = { engine = { getComponent = function(e) return OWNERS[e] and { player = OWNERS[e] } or nil end },
  type = { ComponentType = { PLAYER_OWNED = 1 } } }
'''
    L.execute(mock)
    L.execute(block)
    # the "send" hook: what the interface's sendCommand asks (U.autoVerdict), called from the mod's code
    L.execute(r'''
SENT = {}
function sendHook(tag)
  local ok, v, why, f = pcall(U.autoVerdict, tag)
  if not ok then SENT[#SENT + 1] = "ERR " .. tostring(v) return end
  SENT[#SENT + 1] = v
  -- (as the interface: a command of the game's own windows is this player's action, a mod's is not)
  if f and not f.auto and not f.mod then U.lastLocal = os.clock() end
end
''')
    modchunk = r'''
local M = {}
function M.guiUpdate(userParams, state, guiState) sendHook({ name = "makeEntitySetNameCmd", args = { 5, "x", n = 2 } }) end
function M.click() sendHook({ name = "makeEntitySetNameCmd", args = { 5, "x", n = 2 } }) end
function M.cb() sendHook({ name = "makeEntitySetColorCmd", args = { 5, n = 1 } }) end
return M
'''
    modfn = L.eval("function(code, name) return assert(load(code, name))() end")
    mod = modfn(modchunk, MODSRC)
    sig = modfn(modchunk, SIGSRC)
    # the game's react: calls a click handler, and runs onStep callbacks through the wrapper MPFever puts on react.onStep
    react = modfn(r'''
local R = {}
function R.dispatchClick(h) h() end
function R.onStep(fn) STEPFN = fn end
function R.runStep() STEPFN() end
return R
''', GAMESRC)
    L.globals().react = react
    # (the wrapper of the interface's start, taken from the same file)
    wrap = re.search(r"-- \(0\.6\.13\) what runs from react\.onStep.*?\n\tend\n", src, re.S)
    if not wrap:
        print("FAIL: the react.onStep wrapper was not found in mpfever_ui.script.lua")
        return 1
    L.execute("local okR = true\n" + wrap.group(0).replace("\n\t", "\n"))
    last = lambda: L.eval("SENT[#SENT]")

    L.execute("U.lastLocal = nil; NOW = 1000")
    mod.guiUpdate(None, None, None)
    check("Line Roles' guiUpdate on a client (shared): not sent", last() == "drop", last())
    react.dispatchClick(mod.click)
    check("the same command from a click: sent", last() == "send", last())
    L.execute("NOW = 1002")
    mod.guiUpdate(None, None, None)
    check("Line Roles right after the click: still not sent (world-wide mod)", last() == "drop", last())
    sig.guiUpdate(None, None, None)
    check("a mod's own command (a click in its window) opens no window for the automatic ones", last() == "drop", last())
    gamewin = modfn("local M = {} function M.build() sendHook({ name = 'makeVehicleBuyCmd', args = { 1, n = 1 } }) end return M", GAMESRC)
    gamewin.build()
    sig.guiUpdate(None, None, None)
    check("Auto Signals' guiUpdate right after this player's action in the game's own window: sent", last() == "send", last())
    L.execute("NOW = 1030")
    sig.guiUpdate(None, None, None)
    check("Auto Signals' guiUpdate 30 s after: not sent", last() == "drop", last())
    L.execute("package.loaded['mpfever_local_activity'] = 1025")
    sig.guiUpdate(None, None, None)
    check("... 5 s after this player's tool build (the bridge's stamp): sent", last() == "send", last())
    L.execute("package.loaded['mpfever_local_activity'] = nil; NOW = 1100")
    react.onStep(mod.click)
    react.runStep()
    check("a mod's command from react.onStep: automatic, not sent", last() == "drop", last())
    check("the onStep depth is back to 0", L.eval("U.autoDepth") == 0, L.eval("U.autoDepth"))
    L.execute("U.cbAuto = true")
    react.dispatchClick(mod.cb)
    check("from the callback of an automatic command: automatic", last() == "drop", last())
    L.execute("U.cbAuto = false")
    react.runStep()
    check("from the callback of a player's command, even in a step: sent", last() == "send", last())
    L.execute("U.cbAuto = nil; C.ROLE = 'host'; NOW = 2000")
    mod.guiUpdate(None, None, None)
    check("on the host: sent", last() == "send", last())
    L.execute("C.ROLE = 'client'; U.status = { mode = 'separate' }; U.myCo = 7; U.coMap = { [70] = 7, [80] = 8 }; OWNERS = { [5] = 70 }")
    mod.guiUpdate(None, None, None)
    check("one company per player: the client's own line is renamed from its game", last() == "send", last())
    L.execute("OWNERS = { [5] = 80 }; C.ROLE = 'host'")
    mod.guiUpdate(None, None, None)
    check("... another company's line is not renamed from the host's game", last() == "drop", last())
    # (a debug command is refused when a mod sends it: U.fromMod names the mod from the stack)
    L.execute("FROM = nil; function askFrom() FROM = U.fromMod() end")
    modfn("local M = {} function M.f() askFrom() end return M", "@C:/Users/Public/mod.io/10640/mods/6415745/content/jmw/paralysie_habitants.lua").f()
    check("a debug command from a mod: the mod is named (refused in a session)", L.eval("FROM") == "6415745:paralysie_habitants.lua", L.eval("FROM"))
    modfn("local M = {} function M.f() askFrom() end return M", GAMESRC).f()
    check("from the game's own files: no mod (sent as before)", L.eval("FROM") is None, L.eval("FROM"))
    check("the interface refuses a mod's debug command in a session",
          re.search(r"if tag\.debug then.*?if okD and fromMod and \(C\.ROLE == \"host\" or C\.ROLE == \"client\"\) then.*?return\s+end", src, re.S) is not None)
    L.execute("ENV = { MPFEVER_MODAUTO = '0' }")
    L.execute("U2 = U; U = { stats = {} }")
    L.execute(block)
    check("MPFEVER_MODAUTO=0: off", L.eval("U.modAutoOn") is False)

    print("PASS" if not fails else f"FAIL ({len(fails)})")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
