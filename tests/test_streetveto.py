"""Offline test of the tools' builds on another company's street that is not shared (0.6.8).

One company per player: a station or depot put on another company's street made its pieces the builder's (the game's own
rule): "the street no longer belongs to me" (2026-11-01). The user's rule: a street of another company that is not shared
(its road rule private) cannot be built on, and the tool says why; a shared one can.

G.streetVeto is taken from the real bridge file and run through lupa (Lua 5.2) with mocks. Cases:
  - a proposal that takes away a private street of another company: turned down, the company named in the reason;
  - the same street shared (road rule open): no answer (built on);
  - this company's own street, a town street (no owner), a track (no street component): no answer;
  - a proposal the game already refuses, another event, one company for everybody: no answer;
  - MPFEVER_STREETVETO=0: no answer, as before;
  - the bridge's guiHandleEvent returns its answer.
Run: python tests/test_streetveto.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
G = { myCo = 2 }
-- companies: 1 (entity 100, roads private), 2 (entity 200, this player), 3 (entity 300, roads open)
REG = { mode = "separate", list = { { id = 1, ent = 100, name = "AMD" }, { id = 2, ent = 200, name = "keviK" }, { id = 3, ent = 300, name = "Theo" } },
        road = { ["1"] = { rule = "private" }, ["3"] = { rule = "open" } } }
R = { CO = REG, ownerOf = function(e) return OWNER[e] end }
OWNER = { [11] = 100, [12] = 200, [13] = 300, [15] = 100 }
STREET = { [11] = true, [12] = true, [13] = true, [14] = true }
CO = { idOfEntity = function(reg, e) for _, c in ipairs(reg.list) do if c.ent == e then return c.id end end end,
       find = function(reg, id) for _, c in ipairs(reg.list) do if c.id == id then return c end end end }
E = { roadRule = function(reg, c) return reg.road[tostring(c.id)] or { rule = "open" } end }
C = { eco = function() return E end, Tf = function(fr, en, ...) return string.format(en, ...) end }
api = { type = { ComponentType = { BASE_EDGE_STREET = "street" } },
        engine = { getComponent = function(e, ct) if ct == "street" and STREET[e] then return {} end return nil end } }
function PARAM(edges, critical)
  local removed = {}
  for i, e in ipairs(edges) do removed[i] = { entity = e } end
  return { { proposal = { removedSegments = removed } }, { errorState = { critical = critical or false } } }
end
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^G\.streetVeto = function\(id, name, param\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: G.streetVeto not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    why = "local r = G.streetVeto('constructionBuilder', 'builder.proposalCreate', PARAM(%s)); return r and next(r.errorMessages) or 'none'"

    got = run(why % "{ 11 }")
    check("a private street of another company: turned down, the company named", got == "This street belongs to AMD and is not shared: you cannot build on it.", got)
    check("and the tool still draws it (skipRender false)", run("return G.streetVeto('x', 'builder.proposalCreate', PARAM({ 11 })).skipRender") is False)
    check("among other segments too", run(why % "{ 12, 14, 11 }") != "none")
    check("a shared street of another company: built on", run(why % "{ 13 }") == "none")
    check("this company's own street: built on", run(why % "{ 12 }") == "none")
    check("a town street (no owner): built on", run(why % "{ 14 }") == "none")
    check("a track of another company (no street): left to the tracks' rules", run(why % "{ 15 }") == "none")
    check("a proposal the game already refuses: left alone", run("return tostring(G.streetVeto('x', 'builder.proposalCreate', PARAM({ 11 }, true)))") == "nil")
    check("another event (the build applied): no answer", run("return tostring(G.streetVeto('x', 'builder.proposalApply', PARAM({ 11 })))") == "nil")
    run("REG.mode = 'shared'")
    check("one company for everybody: no answer", run(why % "{ 11 }") == "none")
    run("REG.mode = 'separate'; ENV.MPFEVER_STREETVETO = '0'")
    check("MPFEVER_STREETVETO=0: no answer, as before", run(why % "{ 11 }") == "none")
    run("ENV.MPFEVER_STREETVETO = nil")
    check("the bridge's guiHandleEvent returns its answer", "local okS, rs = pcall(G.streetVeto, id, name, param)" in src and "if okS and rs ~= nil then return rs end" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
