"""Offline test of where a computer company puts a garage (0.6.9, garagePlaces in mpfever_ai.lua).

Stress test of 2026-11-02: a stop put by a script next to a junction with a configuration of its own (traffic lights, crosswalks,
lane connections) removed that configuration without putting it back, and the engine asserted (it != components.end(),
BaseNodeConfig). The stops now put it back; a garage's build removes it the same way and its native replay cannot carry the
traffic light phases, so a garage is no longer put on a segment next to such a junction.
garagePlaces is taken from the real mpfever_ai.lua and run through lupa (Lua 5.2) with a mocked dry run. Cases:
  - the first segment ends at a configured junction: the garage goes to the next one;
  - both segments next to configured junctions: no place;
  - MPFEVER_AIGARAGECFG=0: the first segment taken, as before;
  - a segment with no configured end: taken.
Needs lupa (pip install lupa). Run: python tests/test_aigaragecfg.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
AI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ai.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(AI, encoding="utf-8").read()
    m = re.search(r"^local function garagePlaces\(E, co, p, maxD\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: garagePlaces not found in mpfever_ai.lua")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
CFG = {}            -- node -> a BASE_NODE_CONFIG
SEGS = {}           -- the street segments near the point, in order
EDGE = {}           -- segment -> BASE_EDGE
local function vec(...) return {} end
api = { type = {
    ComponentType = { BASE_EDGE = "edge", BASE_NODE_CONFIG = "cfg" },
    Vec4f = { new = vec }, Mat4f = { new = vec },
    SimpleProposal = { new = function() return {} end, ConstructionEntity = { new = function() return {} end } } },
  engine = { getComponent = function(e, ct)
      if ct == "edge" then return EDGE[e] end
      if ct == "cfg" then return CFG[e] end
    end,
    util = { proposal = { makeProposalData = function() return { errorState = { critical = false, messages = {} }, costs = 650000 } end } } } }
E = { api = api, groundZ = function(x, y, z) return z end }
function territoryCheck() return nil end
function streetSegmentsNear() return SEGS end
function currentYear() return 1950 end
function context() return {} end
CTX_STOP = 1
GARAGE_FILE = "::/depots/road/road_depot/road_depot.con"
local function seg(e, n0, n1, x0)
  EDGE[e] = { node0 = n0, node1 = n1, tangent0 = { x = 100, y = 0 } }
  return { e = e, a = { x = x0, y = 0, z = 0 }, b = { x = x0 + 100, y = 0, z = 0 } }
end
SEGS = { seg(501, 11, 12, 0), seg(502, 12, 13, 100) }
''' + m.group(0) + "\nPLACES = garagePlaces\n")
    run = L.eval("function(code) return assert(load(code))() end")

    run("CFG = { [11] = { laneConnections = {} } }")
    check("the first segment next to a configured junction: the next one", run("local o = PLACES(E, { ent = 9 }, {}, 900) return o[1] and o[1].seg") == 502)
    run("CFG = { [11] = {}, [13] = {} }")
    check("both next to configured junctions: no place", run("return #PLACES(E, { ent = 9 }, {}, 900)") == 0)
    run("ENV.MPFEVER_AIGARAGECFG = '0'")
    check("MPFEVER_AIGARAGECFG=0: the first segment taken, as before", run("local o = PLACES(E, { ent = 9 }, {}, 900) return o[1] and o[1].seg") == 501)
    run("ENV.MPFEVER_AIGARAGECFG = nil; CFG = {}")
    check("no configured end: the first segment taken", run("local o = PLACES(E, { ent = 9 }, {}, 900) return o[1] and o[1].seg") == 501)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
