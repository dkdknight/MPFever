"""Offline test of the names of other languages (issue #97, 0.5.14): the host's game sends the names of stations, lines and
vehicles that are new or changed since its last check, the other games take them.

mpfever_refs.lua is loaded whole through lupa (Lua 5.2) with a mocked world; K.nameSyncOn, H.namesync and G.nameTick are
taken from the real bridge file. Cases:
  - R.nameChanges: no baseline (nil), what changed since the last check (sorted, kind and name), nothing changed (nil), at
    most R.NAMESYNC_MAX names per check (the rest with the next check), an id that names another kind now;
  - R.nameSeed (review fix of 0.5.14): the baseline set at the load, so a name given between the load and the first check is
    sent by that check (before, the first check only set the baseline: such a name was never sent);
  - the names part of R.contentHash fills R.nameCollect (what the bridge's check hands to R.nameChanges);
  - K.nameSyncOn: the host's game only, MPFEVER_NAMESYNC=0 off;
  - H.namesync: ignored on the host's game and with MPFEVER_NAMESYNC=0, entries checked (kind, name length, entity);
  - G.nameTick: a name taken through the engine when it differs, nothing sent when it is the same, an entity not there yet
    waits until its time is out, at most 60 entries a call.
Run: python tests/test_namesync.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
BRIDGE = os.path.join(CONTENT, "mpfever_bridge.script.lua")
REFS = os.path.join(CONTENT, "mpfever_refs.lua")

MOCK = r'''
ENV = {}
local realGetenv = os.getenv
os.getenv = function(k) return ENV[k] end
NAMES, KIND = {}, {}     -- entity -> its name, entity -> its component (STATION_GROUP, LINE, TRANSPORT_VEHICLE)
SENT, LOGS = {}, {}
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
  cmd = { makeEntitySetNameCmd = function(e, nm) return { kind = "name", e = e, nm = nm } end },
}
function log(s) LOGS[#LOGS + 1] = s end
O = { sendCommand = function(c) SENT[#SENT + 1] = c; NAMES[c.e] = c.nm end }
C = { ROLE = "client", ser = function(v) return string.format("%q", tostring(v)) end }
G, H, K = { frames = 0 }, {}, {}
'''


def main():
    bridge = open(BRIDGE, encoding="utf-8").read()
    refs = open(REFS, encoding="utf-8").read()
    m_on = re.search(r"^function K\.nameSyncOn\(\).*\n", bridge, re.M)
    m_q = re.search(r"^G\.nameQueue = \{\}\n.*?^G\.nameTick = function\(\)\n.*?^end\n", bridge, re.S | re.M)
    if not (m_on and m_q):
        print("FAIL: K.nameSyncOn or H.namesync/G.nameTick not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.globals().R = L.execute(refs)
    L.execute(m_on.group(0))
    L.execute(m_q.group(0))
    lua_run = L.eval("function(code) local f = assert(load(code)) return f() end")

    def run(code):
        # (a Lua error is a result too: the case that gets it fails, the others still run)
        try:
            return lua_run(code)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    def changes(code=""):
        # (a check of the host's game: every name read, then what changed since the last check, as "e:kind:name ...")
        return run(code + r'''
local col = {}
for _, k in ipairs({ "STATION_GROUP", "LINE", "TRANSPORT_VEHICLE" }) do
  for _, e in ipairs(R.entitiesWith(k)) do col[e] = { k = k, nm = R.nameOf(e) } end
end
local list = R.nameChanges(col)
if not list then return "nil" end
local t = {}
for _, v in ipairs(list) do t[#t + 1] = v.e .. ":" .. v.k .. ":" .. v.nm end
return table.concat(t, " ")
''')

    run(r'''
KIND = { [10] = "STATION_GROUP", [11] = "STATION_GROUP", [20] = "LINE", [30] = "TRANSPORT_VEHICLE" }
NAMES = { [10] = "Ingolstadt Fishing Grounds West", [11] = "Ingolstadt Station", [20] = "Bus line 1", [30] = "Bus 1" }
R.namesPrev = nil
''')
    print("R.nameChanges")
    check("no baseline: nothing sent (the first look sets it)", changes() == "nil")
    check("nothing changed since: nil", changes() == "nil")
    got = changes('NAMES[20] = "Linie 1"; NAMES[10] = "Ingolstadt Fischzucht"; KIND[40] = "LINE"; NAMES[40] = "Bus line 2"')
    check("renamed and new, sorted by entity", got == "10:STATION_GROUP:Ingolstadt Fischzucht 20:LINE:Linie 1 40:LINE:Bus line 2", got)
    check("sent once only", changes() == "nil")
    got = changes('KIND[40] = "TRANSPORT_VEHICLE"')
    check("an id that names another kind now is sent again", got == "40:TRANSPORT_VEHICLE:Bus line 2", got)
    got = changes('R.NAMESYNC_MAX = 2; NAMES[10] = "a"; NAMES[11] = "b"; NAMES[20] = "c"')
    check("at most R.NAMESYNC_MAX names a check", got == "10:STATION_GROUP:a 11:STATION_GROUP:b", got)
    got = changes()
    check("the rest with the next check", got == "20:LINE:c", got)
    run("R.NAMESYNC_MAX = 400")

    # (review fix of 0.5.14: the baseline of a load, R.nameSeed, called by the simulation's first step after a load and by the
    # interface's resumeAfterLoad on the host's game)
    print("R.nameSeed: a name given between the load and the first check")
    run(r'''
R.namesPrev = nil
KIND = { [10] = "STATION_GROUP", [20] = "LINE", [30] = "TRANSPORT_VEHICLE" }
NAMES = { [10] = "Halle", [20] = "Linie 1", [30] = "Bus 1" }
''')
    ok_seed = run("return type(R.nameSeed) == 'function' and pcall(R.nameSeed)") is True
    check("R.nameSeed sets the baseline of the loaded savegame", ok_seed)
    got = changes('NAMES[30] = "Autobus 1"')
    check("the first check sends the name given since the load", got == "30:TRANSPORT_VEHICLE:Autobus 1", got)
    check("and nothing more", changes() == "nil")
    # the bridge calls R.nameSeed at the load (on the other games, 0.6.11: only the names its first check counts)
    check("the bridge sets the baseline at the simulation's first step after a load",
          re.search(r"if not SIM\.loadChecked then\n\s*SIM\.loadChecked = true\n(\s*--[^\n]*\n)*(\s*R\.namesStore = st\n)?\s*pcall\(R\.nameSeed, not K\.nameSyncOn\(\)\)", bridge) is not None)
    check("and in the interface's resumeAfterLoad",
          re.search(r"^local function resumeAfterLoad\(state\)\n(\t--[^\n]*\n)*\tpcall\(R\.nameSeed, not K\.nameSyncOn\(\)\)", bridge, re.M) is not None)

    print("R.contentHash: the names part fills R.nameCollect")
    got = run(r'''
R.hashSkip = setmetatable({}, { __index = function(_, k) return k ~= "names" end })
R.nameCollect = {}
local parts = R.contentHash(function(seed, s) local h = seed for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end return h end, tostring)
R.hashSkip = nil
local col = R.nameCollect
R.nameCollect = nil
local t = {}
for _, e in ipairs({ 10, 20, 30 }) do t[#t + 1] = e .. ":" .. tostring(col[e] and col[e].k) .. ":" .. tostring(col[e] and col[e].nm) end
return tostring(parts.names) .. " " .. table.concat(t, " ")
''')
    check("every name read is collected with its kind", got.split(" ", 1)[1] == "10:STATION_GROUP:Halle 20:LINE:Linie 1 30:TRANSPORT_VEHICLE:Autobus 1", got)
    check("the names part still counts them", got.startswith("3/"), got)

    print("K.nameSyncOn")
    check("the host's game sends", run('C.ROLE = "host"; ENV = {}; return K.nameSyncOn()') is True)
    check("another game does not", run('C.ROLE = "client"; return K.nameSyncOn()') is False)
    check("MPFEVER_NAMESYNC=0: off", run('C.ROLE = "host"; ENV = { MPFEVER_NAMESYNC = "0" }; return K.nameSyncOn()') is False)

    print("H.namesync and G.nameTick")
    run(r'''
ENV = {}
KIND = { [10] = "STATION_GROUP", [20] = "LINE", [30] = "TRANSPORT_VEHICLE" }
NAMES = { [10] = "Ingolstadt Fischzucht", [20] = "Linie 1", [30] = "Bus 1" }
LIST = { list = {
  { e = 10, k = "STATION_GROUP", nm = "Ingolstadt Fishing Grounds West" },
  { e = 20, k = "LINE", nm = "Linie 1" },
  { e = 50, k = "TRANSPORT_VEHICLE", nm = "Bus 2" },
  { e = 30, k = "CONSTRUCTION", nm = "x" },
  { e = 30, k = "TRANSPORT_VEHICLE", nm = string.rep("x", 201) },
  { e = "y", k = "LINE", nm = "z" },
} }
function queued() local n = 0 for _ in pairs(G.nameQueue) do n = n + 1 end return n end
''')
    check("the host's game takes none", run('C.ROLE = "host"; G.nameQueue = {}; H.namesync("Client#1", LIST); return queued()') == 0)
    check("MPFEVER_NAMESYNC=0: none", run('C.ROLE = "client"; ENV = { MPFEVER_NAMESYNC = "0" }; H.namesync("Host", LIST); ENV = {}; return queued()') == 0)
    check("no list: nothing", run('H.namesync("Host", { list = "x" }); H.namesync("Host", nil); return queued()') == 0)
    check("another game queues the valid entries (a stranger kind, a long name, no entity left out)",
          run('G.frames = 100; H.namesync("Host", LIST); return queued()') == 3)
    got = run(r'''
SENT = {}
G.nameTick()
local t = {}
for _, c in ipairs(SENT) do t[#t + 1] = c.e .. "=" .. c.nm end
return #SENT .. " " .. table.concat(t, ",") .. " left " .. queued() .. " name10 " .. NAMES[10]
''')
    check("a name that differs is taken through the engine, the same one sends nothing, an entity not there yet waits", got ==
          "1 10=Ingolstadt Fishing Grounds West left 1 name10 Ingolstadt Fishing Grounds West", got)
    got = run('SENT = {}; KIND[50] = "TRANSPORT_VEHICLE"; NAMES[50] = "Autobus 2"; G.frames = 1000; G.nameTick(); return #SENT .. " " .. NAMES[50] .. " left " .. queued()')
    check("taken once the entity is there", got == "1 Bus 2 left 0", got)
    got = run('SENT = {}; H.namesync("Host", { list = { { e = 60, k = "LINE", nm = "L" } } }); G.frames = 1000 + 1801; G.nameTick(); return #SENT .. " left " .. queued()')
    check("an entity that never comes is dropped after its time", got == "0 left 0", got)
    got = run(r'''
SENT = {}
local list = {}
for i = 1, 70 do KIND[1000 + i] = "LINE"; NAMES[1000 + i] = "old"; list[i] = { e = 1000 + i, k = "LINE", nm = "new" } end
H.namesync("Host", { list = list })
G.nameTick()
local first = #SENT
G.nameTick()
return first .. " then " .. #SENT .. " left " .. queued()
''')
    check("at most 60 entries a call", got == "60 then 70 left 0", got)

    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
