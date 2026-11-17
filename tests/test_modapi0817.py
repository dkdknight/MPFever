"""Offline test of MPFever's public API for other mods (0.8.17, mod/mpfever_1/content/mpfever_api.lua, docs/MOD-API.md).

Until now each mod that drifted got its own rule in MPFever (its file pattern in mpfever_modauto.lua's M.STRICT...), and a rule
made for one mod could catch another. Mods can now ask MPFever themselves, through package.loaded["mpfever"]: whether a session
runs, the company mode, the company of a player entity, and in the interface half whether this game is the host's, its own
company, and which game should send a command the mod sends by itself (mp.shouldSend). A mod that declares
mp.declare{ autoCommands = "self" } gets its automatic commands sent as it sends them, none of MPFever's rules for mods.

Part 1 runs mpfever_api.lua through lupa (Lua 5.2) with a fake game: outside a session, a client and the host with one company
for everybody and with one company per player, the simulation half (the interface's questions answer nil there), a declaration
from a mod's file (mod.io, Workshop, local, a game path "<id>::/"), MPFEVER_MODAPI=0, a second install in the same state.
Part 2 runs mpfever_modauto.lua's decision with a declared mod. Part 3 checks the wiring in the bridge and the interface hook.
Run: python tests/test_modapi0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
API = os.path.join(CONTENT, "mpfever_api.lua")
MODAUTO = os.path.join(CONTENT, "mpfever_modauto.lua")
BRIDGE = os.path.join(CONTENT, "mpfever_bridge.script.lua")
UI = os.path.join(CONTENT, "mpfever_ui.script.lua")
DOC = os.path.join(HERE, "..", "docs", "MOD-API.md")

MODIO = "@C:/Users/Public/mod.io/10640/mods/6419266/content/res/scripts/my_mod.lua"
MODIO_OTHER = "@C:/Users/Public/mod.io/10640/mods/6416560/content/auto_signals/auto_signals.script.lua"
WORKSHOP = "@D:/Steam/steamapps/workshop/content/3493540/123456/content/res/x.lua"
LOCAL = "@E:/Steam/userdata/1/3493540/local/mods/line_tools_1/content/gui/a.lua"
VIRTUAL = "line_tools::/gui/a.lua"
GAME = "@H:/SteamLibrary/steamapps/common/Transport Fever 3/base/content/gui/main/react.lua"

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


L = lupa.LuaRuntime(unpack_returned_tuples=True)
ev = L.eval("function(code) local f = assert(load(code)) return f() end")
L.globals().A = L.execute(open(API, encoding="utf-8").read())
L.globals().MA = L.execute(open(MODAUTO, encoding="utf-8").read())

# a fake game: its facts in F, changed by the cases; the logs kept
ev("""
F = { role = 'solo', server = false, mode = nil, myCo = nil, player = 900,
      cos = { [900] = 1, [901] = 2, [902] = 3 }, owner = { [5000] = 900, [5001] = 901, [5002] = 902 } }
LOGS = {}
function ENV(half)
  return {
    half = half, version = '0.8.17', log = function(t) LOGS[#LOGS + 1] = t end, getinfo = debug.getinfo,
    role = function() return F.role end, server = function() return F.server end, mode = function() return F.mode end,
    companyOf = function(e) return F.cos[e] end,
    entityOf = function(n) for e, c in pairs(F.cos) do if c == n then return e end end return nil end,
    myCompany = function() return F.myCo end,
    ownerCompany = function(e) return F.cos[e] or F.cos[F.owner[e] or -1] end,
    gamePlayer = function() return F.player end,
  }
end
-- a function "of a mod's file": made by load() under that chunk name, it calls mp.declare(opts)
function DECLARE_FROM(mp, chunk, opts)
  local f = assert(load('local mp, o = ...; local r = mp.declare(o); return r', chunk))
  return f(mp, opts)
end
return true
""")


def lua(code):
    return ev(code)


def setf(**kw):
    for k, v in kw.items():
        lua(f"F.{k} = {v}")


# ---- part 1: the table
lua("package.loaded['mpfever'] = nil")
ui = lua("return A.install(ENV('interface'), function() return nil end)")
check("installed in package.loaded['mpfever']", lua("return package.loaded['mpfever'] ~= nil and package.loaded['mpfever'].apiVersion == 1"))
check("  its version and half", lua("local m = package.loaded['mpfever'] return m.version == '0.8.17' and m.half == 'interface'"))
check("  said in the log", lua("for _, t in ipairs(LOGS) do if t:find('ready (interface)', 1, true) then return true end end return false"))

setf(role="'solo'")
check("no session: inSession false, companyMode nil", lua("local m = package.loaded.mpfever return m.inSession() == false and m.companyMode() == nil"))
check("no session: shouldSend true (a mod does as without MPFever)", lua("return package.loaded.mpfever.shouldSend(5001) == true"))
check("no session: isHost false, myCompany nil", lua("local m = package.loaded.mpfever return m.isHost() == false and m.myCompany() == nil"))

setf(role="'client'", mode="'shared'", myCo="nil")
check("client, one company: inSession, 'shared'", lua("local m = package.loaded.mpfever return m.inSession() and m.companyMode() == 'shared'"))
check("  not the host; its company 1", lua("local m = package.loaded.mpfever return m.isHost() == false and m.myCompany() == 1"))
check("  shouldSend false (the host's game sends)", lua("return package.loaded.mpfever.shouldSend(5001) == false"))
check("  the game's player is company 1, another entity none", lua("local m = package.loaded.mpfever return m.companyOf(900) == 1 and m.companyOf(901) == nil and m.playerEntityOf(1) == 900"))
setf(role="'host'")
check("host, one company: isHost, shouldSend true", lua("local m = package.loaded.mpfever return m.isHost() and m.shouldSend(5001) == true"))
check("  not a dedicated server", lua("return package.loaded.mpfever.isDedicatedServer() == false"))
setf(server="true")
check("  a dedicated server's game", lua("return package.loaded.mpfever.isDedicatedServer() == true"))
setf(server="false")

setf(role="'client'", mode="'separate'", myCo="2")
check("client, one company per player: 'separate', its company 2", lua("local m = package.loaded.mpfever return m.companyMode() == 'separate' and m.myCompany() == 2"))
check("  companyOf / playerEntityOf from the registry", lua("local m = package.loaded.mpfever return m.companyOf(902) == 3 and m.playerEntityOf(3) == 902 and m.companyOf(77) == nil"))
check("  shouldSend: its company's line yes, another's no", lua("local m = package.loaded.mpfever return m.shouldSend(5001) == true and m.shouldSend(5002) == false"))
check("  shouldSend: a player entity itself", lua("local m = package.loaded.mpfever return m.shouldSend(901) == true and m.shouldSend(900) == false"))
check("  shouldSend: nothing owned / no entity -> the host's game", lua("local m = package.loaded.mpfever return m.shouldSend(7777) == false and m.shouldSend(nil) == false"))
setf(role="'host'", myCo="1")
check("host, one company per player: another company's line not from here", lua("local m = package.loaded.mpfever return m.shouldSend(5001) == false and m.shouldSend(5000) == true and m.shouldSend(7777) == true"))
check("bad arguments never raise", lua("local m = package.loaded.mpfever return m.companyOf('x') == nil and m.playerEntityOf({}) == nil and m.declare(nil) == false"))
lua("F.cos = setmetatable({}, { __index = function() error('engine gone') end })")
check("an error of the game's facts is caught (nil), logged once",
      lua("local m = package.loaded.mpfever local a, b = m.companyOf(900), m.companyOf(901) "
          "local n = 0 for _, t in ipairs(LOGS) do if t:find('engine gone', 1, true) then n = n + 1 end end return a == nil and b == nil and n == 1"))
lua("F.cos = { [900] = 1, [901] = 2, [902] = 3 }")

# the simulation half
lua("SIMT = A.make(ENV('simulation'))")
setf(role="'client'", mode="'separate'", myCo="2")
check("simulation: inSession / companyMode / companyOf answered (the same on every game)",
      lua("return SIMT.inSession() == true and SIMT.companyMode() == 'separate' and SIMT.companyOf(902) == 3"))
check("simulation: isHost, isDedicatedServer, myCompany, shouldSend answer nil",
      lua("return SIMT.isHost() == nil and SIMT.isDedicatedServer() == nil and SIMT.myCompany() == nil and SIMT.shouldSend(5001) == nil"))
check("  and say it once in the log", lua("local n = 0 for _, t in ipairs(LOGS) do if t:find('isHost() asked in the simulation', 1, true) then n = n + 1 end end SIMT.isHost() return n == 1"))

# the roots of mods' files
check("rootOf: mod.io", lua(f"return A.rootOf('{MODIO}')") == "c:/users/public/mod.io/10640/mods/6419266/")
check("rootOf: Workshop", lua(f"return A.rootOf('{WORKSHOP}')") == "d:/steam/steamapps/workshop/content/3493540/123456/")
check("rootOf: local mod", lua(f"return A.rootOf('{LOCAL}')") == "e:/steam/userdata/1/3493540/local/mods/line_tools_1/")
check("rootOf: a game path", lua(f"return A.rootOf('{VIRTUAL}')") == "line_tools::/")
check("rootOf: the game's own file none", lua(f"return A.rootOf('{GAME}')") is None)
check("rootOf: backslashes", lua("return A.rootOf([[@C:\\Users\\Public\\mod.io\\10640\\mods\\6419266\\content\\a.lua]])") == "c:/users/public/mod.io/10640/mods/6419266/")

# declarations
check("declare from a mod's file", lua(f"return DECLARE_FROM(package.loaded.mpfever, '{MODIO}', {{ autoCommands = 'self' }})") is True)
check("  its commands are covered", lua(f"return A.declaredOf(package.loaded.mpfever, {{ '{MODIO.replace('my_mod', 'other_file')}' }}) ~= nil"))
check("  another mod's are not", lua(f"return A.declaredOf(package.loaded.mpfever, {{ '{MODIO_OTHER}' }}) == nil"))
check("  the first of the stack that is declared counts", lua(f"return A.declaredOf(package.loaded.mpfever, {{ '{MODIO_OTHER}', '{MODIO}' }}) ~= nil"))
check("  declaring twice keeps one", lua(f"DECLARE_FROM(package.loaded.mpfever, '{MODIO}', {{ autoCommands = 'self' }}) return #package.loaded.mpfever._declared") == 1)
check("declare with an id covers its game path and its local folder",
      lua(f"return DECLARE_FROM(package.loaded.mpfever, '{LOCAL}', {{ autoCommands = 'self', id = 'line_tools' }}) and "
          f"A.declaredOf(package.loaded.mpfever, {{ '{VIRTUAL}' }}) ~= nil and A.declaredOf(package.loaded.mpfever, {{ '{LOCAL}' }}) ~= nil"))
check("a declaration in a tail call (no frame of the mod): ignored, not wrongly given to another file",
      lua(f"local f = assert(load('local mp, o = ...; return mp.declare(o)', '{MODIO_OTHER}')) return f(package.loaded.mpfever, {{ autoCommands = 'self' }})") is False
      and lua(f"return A.declaredOf(package.loaded.mpfever, {{ '{MODIO_OTHER}' }}) == nil"))
check("a declaration from the game's own file is ignored", lua(f"return DECLARE_FROM(package.loaded.mpfever, '{GAME}', {{ autoCommands = 'self' }})") is False)
check("an unknown option declares nothing", lua(f"return DECLARE_FROM(package.loaded.mpfever, '{WORKSHOP}', {{ autoCommands = 'maybe' }})") is False
      and lua(f"return A.declaredOf(package.loaded.mpfever, {{ '{WORKSHOP}' }}) == nil"))

# a second install in the same state (a new game, the bridge loaded again): the same table, its declarations kept
lua("HELD = package.loaded.mpfever")
lua("F2 = ENV('interface'); F2.version = '0.8.17b'; A.install(F2, function() return nil end)")
check("installed again: the same table (a mod holding it sees the new facts)", lua("return package.loaded.mpfever == HELD and HELD.version == '0.8.17b'"))
check("  the declarations kept", lua(f"return A.declaredOf(HELD, {{ '{MODIO}' }}) ~= nil"))
check("  a declaration made after it lands in that table", lua(f"DECLARE_FROM(HELD, '{WORKSHOP}', {{ autoCommands = 'self' }}) return A.declaredOf(HELD, {{ '{WORKSHOP}' }}) ~= nil"))
check("MPFEVER_MODAPI=0: no table", lua("package.loaded.mpfever = nil return A.install(ENV('interface'), function(n) if n == 'MPFEVER_MODAPI' then return '0' end end) == nil and package.loaded.mpfever == nil"))

# ---- part 2: the decision for a declared mod
def decide(f):
    return lua("local v, w = MA.decide(" + f + ") return v .. '|' .. w")


check("declared: sent from a client although the host's game would send it",
      decide("{ auto = true, mod = true, role = 'client', declared = true }").startswith("send|the mod decides itself"))
check("declared: a known world-wide mod's rule not applied either",
      decide("{ auto = true, mod = true, role = 'client', strict = 'Line Roles', declared = true }").startswith("send|"))
check("declared: another company's line sent as the mod sends it",
      decide("{ auto = true, mod = true, role = 'client', separate = true, owner = 'theirs', declared = true }").startswith("send|"))
check("not declared: as before (the host's game sends it)", decide("{ auto = true, mod = true, role = 'client' }").startswith("drop|"))
check("no session: as before", decide("{ auto = true, mod = true, role = 'solo', declared = true }") == "send|no session")

# ---- part 3: the wiring
bridge = open(BRIDGE, encoding="utf-8").read()
uis = open(UI, encoding="utf-8").read()
check("bridge: the simulation half installs it at its first step, before the session check",
      re.search(r"local function update\(userParams, state, dt\)\n\tif SIM\.api == nil then pcall\(SIM\.installApi\) end\n\tif not C\.ACTIVE then return end", bridge) is not None)
check("bridge: the interface half installs it at its first frame",
      re.search(r"G\.guiUpdateBody = function\(userParams, state, guiState\)\n\tif G\.api == nil then pcall\(G\.installApi\) end\n\tif not C\.ACTIVE then return end", bridge) is not None
      and "G.guiUpdateBody(userParams, state, guiState)" in bridge)  # (0.8.17: the body behind the measuring guiUpdate)
check("bridge: halves 'simulation' and 'interface'", 'half = "simulation"' in bridge and 'half = "interface"' in bridge)
check("bridge: the game scripts' verdict reads the declarations", "facts.declared = SIM.MPAPI.declaredOf(G.api, mods) ~= nil" in bridge)
check("interface hook: installed at doReplace, before the session check",
      re.search(r"M\.doReplace = function\(replacementApi\)\n(\t[^\n]*\n){1,3}\tlocal okA, errA = pcall\(U\.installApi\)\n(\t[^\n]*\n)\tif not C\.ACTIVE then return end", uis) is not None)
check("interface hook: the automatic commands' verdict reads the declarations", "facts.declared = MPAPI.declaredOf(U.api, sf.mods) ~= nil" in uis)
check("interface hook: the module loaded before the verdict that uses it", uis.find("local okAPI, MPAPI") < uis.find("U.autoVerdict = function"))
check("the guide docs/MOD-API.md exists and names every function",
      os.path.exists(DOC) and all(n in open(DOC, encoding="utf-8").read() for n in
                                  ["inSession", "companyMode", "companyOf", "playerEntityOf", "isHost", "isDedicatedServer", "myCompany", "shouldSend", "declare"]))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
