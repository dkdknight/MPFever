"""Offline test (0.8.17, autotest "stops"): the stop scenario never picks a segment at a junction with traffic lights
(runStopMatrix in mpfever_bridge.script.lua, switch MPFEVER_STOPLIGHTS).

k8sp (2026-11-17 04:00): the client's own test build, the form replacePosCfgObj on segment 50378, took the configuration of
its nodes away and added none; node 48531 had traffic lights, the engine looked for its configuration and the game closed
("it != components.end()", BaseNodeConfig, ecs::Engine::GetComponentDataIndex). A test's own proposal: a player's tool never
sends that form. The segment list of runStopMatrix is run through lupa with a mocked engine:
  - MPFEVER_STOPLIGHTS=1: the segment at the traffic lights is picked (the bug, as before);
  - now: it is left out; the other town segments without objects stay in the list, in their order.
Needs lupa. Run: python tests/test_stoplights0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


a = src.index("local function runStopMatrix(p)")
body = src[a:]
b = body.index("\tlocal forms = nil\n")
chunk = body[body.index("\tlocal list = {}\n"):b]
check("the segment list of runStopMatrix found", "BASE_NODE_TRAFFIC_LIGHT" in chunk and "MPFEVER_STOPLIGHTS" in chunk)

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
local EDGES = {
  [10] = { type = 0, roadTemplate = "town_medium.street_template", objects = {}, node0 = 1, node1 = 2 },
  [50378] = { type = 0, roadTemplate = "town_large.street_template", objects = {}, node0 = 48531, node1 = 3 },
  [11] = { type = 0, roadTemplate = "town_small.street_template", objects = { { 5, 0 } }, node0 = 4, node1 = 5 },
  [12] = { type = 0, roadTemplate = "standard.street_template", objects = {}, node0 = 6, node1 = 7 },
  [13] = { type = 0, roadTemplate = "town_small.street_template", objects = {}, node0 = 8, node1 = 48531 },
  [14] = { type = 0, roadTemplate = "town_small.street_template", objects = {}, node0 = 9, node1 = 10 },
}
local LIGHTS = { [48531] = true }
R = { allEdges = function() return { 10, 50378, 11, 12, 13, 14 } end }
api = { type = { ComponentType = { BASE_EDGE = "edge", BASE_NODE_TRAFFIC_LIGHT = "light" } },
        engine = { getComponent = function(e, t)
          if t == "edge" then return EDGES[e] end
          if t == "light" then if LIGHTS[e] then return {} end return nil end
        end } }
function LIST()
'''


def picked(off):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK + chunk + "\treturn list\nend\n")
    if off:
        L.execute("ENV.MPFEVER_STOPLIGHTS = '1'")
    return list(L.eval("LIST()").values())


got = picked(True)
check("MPFEVER_STOPLIGHTS=1: the segment at the traffic lights picked (the bug)", got == [10, 50378, 13, 14], got)
got = picked(False)
check("now: the segments at the traffic lights left out, the others in their order", got == [10, 14], got)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
