"""Offline test of an upgrade whose new segments run the other way round (0.6.5, issue #107).

The upgrade tool sometimes lists its new segment with the old one's ends swapped (node0/node1). The replays build an upgrade
with the engine's replaceSegment, which keeps the old way round: a one-way street (a motorway, highway_new_large_barriers)
then ran one way on the builder's game and the other way on the others, and the vehicles took other roads from that build on
("vehicles" out of sync 33 s after the first such upgrade of Kev1505in's session, 2026-10-31; 5 road vehicles elsewhere at the
first dump). Such an upgrade gets no plan now: the tool's own proposal is replayed, the same way round everywhere.

upgradePlan is taken from the real bridge file and run through lupa (Lua 5.2) with mocks. Cases:
  - the same way round: a plan of one segment, as before;
  - the other way round: no plan ("segment reversed"), logged;
  - several segments, one of them reversed: no plan;
  - MPFEVER_UPGREV=0: a plan, as before.
Run: python tests/test_upgrev.py
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
G = {}
C = { hasReplaceMaps = function() return false end, laneSignature = function() return "" end, customLanes = function() return nil end,
      ser = function(v) return tostring(#v) end }
-- an upgrade of the segments given: { { old entity, n0, n1, reversed }, ... }
function UPGRADE(list)
  local added, removed = {}, {}
  for i, s in ipairs(list) do
    local e, n0, n1, rev = s[1], s[2], s[3], s[4]
    removed[#removed + 1] = { entity = e, type = 0, comp = { node0 = n0, node1 = n1, type = 0, typeIndex = -1, roadTemplate = "country_new_medium.lua" } }
    added[#added + 1] = { entity = -i, type = 0, comp = { node0 = rev and n1 or n0, node1 = rev and n0 or n1, type = 0, typeIndex = -1,
      roadTemplate = "highway_new_large_barriers.lua" }, playerOwned = { player = 7 } }
  end
  return { { proposal = { addedSegments = added, removedSegments = removed, addedNodes = {}, removedNodes = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {} }, toAdd = {}, toRemove = {} } }
end
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^local function upgradePlan\(margs, townAuto\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: upgradePlan not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0).replace("local function upgradePlan", "function upgradePlan", 1))
    run = L.eval("function(code) return assert(load(code))() end")

    got = run("local p = upgradePlan(UPGRADE({ { 55027, 10, 11 } })); return p and (#p .. ':' .. p[1].edge .. ':' .. tostring(p[1].n0)) or tostring(G.upgradeWhy)")
    check("the same way round: a plan of one segment, as before", got == "1:55027:10", got)
    got = run("G.upgradeWhy = nil; local p = upgradePlan(UPGRADE({ { 55027, 10, 11, true } })); return tostring(p) .. '/' .. tostring(G.upgradeWhy)")
    check("#107: the other way round: no plan (the tool's proposal instead)", got == "nil/segment reversed", got)
    check("the reversed segment is logged", any("55027 runs the other way round" in str(x) for x in L.eval("LOGS").values()))
    got = run("G.upgradeWhy = nil; local p = upgradePlan(UPGRADE({ { 1, 10, 11 }, { 2, 11, 12 }, { 3, 12, 13, true }, { 4, 13, 14 }, { 5, 14, 15 } })); return tostring(p) .. '/' .. tostring(G.upgradeWhy)")
    check("#107: five segments at once, one reversed: no plan", got == "nil/segment reversed", got)
    got = run("local p = upgradePlan(UPGRADE({ { 1, 10, 11 }, { 2, 11, 12 } })); return p and #p or tostring(G.upgradeWhy)")
    check("five segments the same way round: a plan", got == 2, got)
    run("ENV.MPFEVER_UPGREV = '0'")
    got = run("G.upgradeWhy = nil; local p = upgradePlan(UPGRADE({ { 55027, 10, 11, true } })); return p and (#p .. ':' .. p[1].edge .. ':' .. tostring(p[1].n0)) or tostring(G.upgradeWhy)")
    check("MPFEVER_UPGREV=0: a plan (the decorations' sides swapped only), as before", got == "1:55027:11", got)
    run("ENV.MPFEVER_UPGREV = nil")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
