"""Offline test of the station edit that takes ALL its own tracks away (issue #97 "build not reproduced: conversion built",
0.5.14) and of its review fixes.

G.ownTracksRemoved, G.replayByReplace and the first lines of replayNativeConstruction (the route between the engine's
replacement and the conversion) are taken from the real bridge file and run through lupa (Lua 5.2) with a mocked engine.
Cases:
  - G.ownTracksRemoved answers two things: whether the edit takes away own tracks of the construction it replaces, and
    whether it takes them ALL away (review fix: only that case, issue #97, goes to the engine's replacement; an edit that
    keeps some, issue #90, is replayed by the conversion as in 0.5.13);
  - the route: all own tracks gone -> G.replayByReplace; some -> the conversion; MPFEVER_EDITREPLACE=0 -> the conversion;
  - G.replayByReplace builds the engine's replacement only when it takes away exactly what the tool took away. The engine's
    lists hold its own objects (userdata, read by their .entity field): the first version read them as numbers, every such
    edit was refused and the games reloaded (review fix). Here the engine's elements are Python objects, userdata in Lua;
  - G.replayByReplace refuses (nothing built, a reload asked) when the removals differ, another construction is replaced, or
    the build adds or removes more than one construction.
Run: python tests/test_owntracks.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")


class EngineObj:
    """An object of the engine's proposal (userdata in Lua): an entity read by its field."""
    def __init__(self, entity):
        self.entity = entity


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
CONS = {}          -- construction entity -> { fileName, frozenEdges }
LOGS, FAILED, SENT = {}, {}, {}
ENGINE_P = nil     -- what createProposalReplaceConstruction gives
local function copy(v) if type(v) ~= "table" then return v end local t = {} for k, x in pairs(v) do t[k] = copy(x) end return t end
api = {
  type = { ComponentType = { CONSTRUCTION = "con" }, Context = { new = function() return {} end } },
  engine = {
    getComponent = function(e, ct) if ct == "con" then return CONS[e] end return nil end,
    util = { getPlayer = function() return 7 end,
      proposal = { createProposalReplaceConstruction = function(old, params) CALLED = { old = old, params = params } return ENGINE_P end } },
  },
  cmd = { makeWorldBuildProposalCmd = function(p, ctx, a, b) return { kind = "build", p = p, ctx = ctx } end },
}
C = { ser = function(v) return v end, deser = copy, copy = copy, plain = copy, marshal = function(v) return v end }
R = { translateIn = function(args, bind) return MISSING or {} end }
G = { bind = {}, refundInto = function(ctx) end }
function log(s) LOGS[#LOGS + 1] = s end
function shortErr(e) return tostring(e) end
function replayFailed(a, why) FAILED[#FAILED + 1] = why end
function logRefusal() end
function toSim() end
function replaySend(cmd, cb) SENT[#SENT + 1] = cmd end
function hasConstructionSegments(m) return HASCONSEGS == true end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m_own = re.search(r"^G\.ownTracksRemoved = function\(m\)\n.*?^end\n", src, re.S | re.M)
    m_rep = re.search(r"^G\.replayByReplace = function\(a\)\n.*?^end\n", src, re.S | re.M)
    # (the route: replayNativeConstruction's first lines, up to its call of G.replayByReplace; the conversion after them)
    m_route = re.search(r"^local function replayNativeConstruction\(a\)\n(.*?G\.replayByReplace\(a\) end\n)", src, re.S | re.M)
    m_mark = re.search(r"a\.ownTracksAll = select\(2, G\.ownTracksRemoved\(m1\)\) == true", src)
    if not (m_own and m_rep and m_route):
        print("FAIL: G.ownTracksRemoved, G.replayByReplace or the route of replayNativeConstruction not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m_own.group(0))
    L.execute(m_rep.group(0))
    L.execute("function route(a)\n" + m_route.group(1) + "return 'conversion'\nend\n")
    L.execute("G.replayByReplace = (function(real) REAL_REPLACE = real return function(a) return 'replacement' end end)(G.replayByReplace)")
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

    # a modular street station (entity 500) with its own tracks 101 and 102
    run(r'''
CONS[500] = { fileName = "station/street/modular_street_station.con", frozenEdges = { 101, 102 } }
function edit(removed, toRemove, toAdd)
  local segs = {}
  for i, e in ipairs(removed) do segs[i] = { entity = e } end
  return { toRemove = toRemove or { { entity = 500 } }, toAdd = toAdd or { { fileName = "station/street/modular_street_station.con", params = { modules = 2 } } },
    proposal = { removedSegments = segs, removedNodes = { { entity = 201 }, { entity = 202 } }, addedSegments = {}, addedNodes = {} } }
end
function two(m) local a, b = G.ownTracksRemoved(m) return tostring(a) .. "/" .. tostring(b) end
''')
    print("G.ownTracksRemoved")
    check("all own tracks taken away: true, all", run("return two(edit({ 101, 102 }))") == "true/true")
    check("one of two (issue #90): true, not all", run("return two(edit({ 101 }))") == "true/false")
    check("all, with a street segment of the town too", run("return two(edit({ 101, 300, 102 }))") == "true/true")
    check("no own track: false", run("return two(edit({ 300 }))").startswith("false"))
    check("a construction given by its plain id", run("return two(edit({ 101, 102 }, { 500 }))") == "true/true")
    check("nothing added (a bulldozer: its own removal)", run("return two(edit({ 101, 102 }, nil, {}))").startswith("false"))
    check("the replay marks all or some (replayNative)", m_mark is not None)

    print("the route of replayNativeConstruction")
    check("all own tracks gone: the engine's replacement",
          run("HASCONSEGS = false; ENV = {}; return route({ args = { {} }, ownTracks = true, ownTracksAll = true })") == "replacement")
    check("some own tracks gone (issue #90): the conversion, as in 0.5.13",
          run("return route({ args = { {} }, ownTracks = true, ownTracksAll = false })") == "conversion")
    check("MPFEVER_EDITREPLACE=0: the conversion",
          run('ENV = { MPFEVER_EDITREPLACE = "0" }; local r = route({ args = { {} }, ownTracks = true, ownTracksAll = true }); ENV = {}; return r') == "conversion")
    check("a build with segments of its own: the conversion",
          run("HASCONSEGS = true; local r = route({ args = { {} }, ownTracks = true, ownTracksAll = true }); HASCONSEGS = false; return r") == "conversion")

    print("G.replayByReplace")
    L.globals().Obj = EngineObj
    run(r'''
function engineP(removedSegs, removedNodes, nAdd)
  local function objs(list) local t = {} for i, e in ipairs(list) do t[i] = Obj(e) end return t end
  return { proposal = { removedSegments = objs(removedSegs), removedNodes = objs(removedNodes), addedSegments = {}, addedNodes = {} },
    toAdd = nAdd == 0 and {} or { {} } }
end
function replace(m, P)
  ENGINE_P = P
  FAILED, SENT, CALLED = {}, {}, nil
  local r = REAL_REPLACE({ uid = "harry:5", args = { m } })
  return tostring(r) .. " built " .. #SENT .. " failed " .. #FAILED
end
''')
    got = run("return replace(edit({ 101, 102 }), engineP({ 102, 101 }, { 202, 201 }))")
    check("the same tracks and nodes taken away (the engine's objects are userdata): built", got == "true built 1 failed 0", got)
    check("the replacement of the old station with the tool's parameters",
          run("return CALLED and CALLED.old == 500 and CALLED.params.modules == 2") is True)
    got = run("return replace(edit({ 101, 102 }), engineP({ 101 }, { 201, 202 }))")
    check("the engine takes away less: refused, nothing built", got == "true built 0 failed 1", got)
    got = run("return replace(edit({ 101, 102 }), engineP({ 101, 102 }, { 201 }))")
    check("other nodes taken away: refused", got == "true built 0 failed 1", got)
    got = run("return replace(edit({ 101, 102 }), engineP({ 101, 102 }, { 201, 202 }, 0))")
    check("the engine adds no construction: refused", got == "true built 0 failed 1", got)
    got = run('return replace(edit({ 101, 102 }, nil, { { fileName = "station/rail/other.con" } }), engineP({ 101, 102 }, { 201, 202 }))')
    check("another construction file: refused", got == "true built 0 failed 1", got)
    got = run('return replace(edit({ 101, 102 }, { { entity = 500 }, { entity = 501 } }), engineP({ 101, 102 }, { 201, 202 }))')
    check("two constructions taken away: refused", got == "true built 0 failed 1", got)
    got = run('MISSING = { "ref:1" }; local r = replace(edit({ 101, 102 }), engineP({ 101, 102 }, { 201, 202 })); MISSING = nil; return r')
    check("an entity that cannot be found here: refused", got == "true built 0 failed 1", got)
    got = run("ENGINE_P = nil; return replace(edit({ 101, 102 }), nil)")
    check("no proposal from the engine: refused", got == "true built 0 failed 1", got)

    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
