"""Offline test of the node configuration guard (0.7.1, issue #127, C.cfgGuard).

Issue #127 (Malle355, 0.6.12): a client's builds made during a pause reached the host all at once at the unpause and were
rebuilt from their capture. Build #7 only changed junction configurations (nodeConfigsToRemove {79338}, nodeConfigsToAdd
{79344, 79338}); node 79344 had no configuration on the client's game but had one on the host's: the engine added a second
one, ecs::Engine::AddComponent asserted (component exists) in the simulation thread and the host crashed.
  - C.cfgGuard puts every existing node that is configured here already, and that the build does not remove, in the list of
    configurations the build removes (replaced, as the native tools do), never twice, never a new node (negative id) nor a
    node the build removes; MPFEVER_CFGREPLACE=0: the list as it was;
  - the rebuild (fallback forms), the native forms, the upgrade replays (one segment and merged) and the stop replays use it.
Needs lupa (pip install lupa). Run: python tests/test_cfgguard.py
"""
import os, re, sys

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


common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read()
m = re.search(r"^function C\.cfgGuard\(.*?^end\n", common, re.S | re.M)
check(m is not None, "C.cfgGuard found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
C = {}
ENV = {}
os.getenv = function(k) return ENV[k] end
HAS = { [79344] = true, [79338] = true, [500] = true }
api = { type = { ComponentType = { BASE_NODE_CONFIG = "cfg" } },
  engine = { getComponent = function(n, ct) if ct == "cfg" and HAS[n] then return { laneConnections = {} } end return nil end } }
''' + (m.group(0) if m else ""))
L.execute("function lst(t) local o = {} for i, v in ipairs(t) do o[i] = tostring(v) end return table.concat(o, ',') end")

# the scenario of issue #127
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 79344 }, { entity = 79338 } }, { 79338 }) return lst(rm), n end)()")
check(r == "79338,79344" and n == 1, "#127: the configured node 79344 is replaced, 79338 not put twice (" + r + ")")
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 79344 } }, nil) return lst(rm), n end)()")
check(r == "79344" and n == 1, "no remove list: one made")
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 700 }, { entity = -3 } }, {}) return lst(rm), n end)()")
check(r == "" and n == 0, "a node without a configuration here, and a new node, left as they are")
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 500 }, { entity = 79344 } }, {}, function(e) return e == 500 end) return lst(rm), n end)()")
check(r == "79344" and n == 1, "a node the build removes is skipped")
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 79344 }, { entity = 79344 } }, {}) return lst(rm), n end)()")
check(r == "79344" and n == 1, "a node listed twice is put once")
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 79344 } }, {}, nil, function(e) error('no') end) return lst(rm), n end)()")
check(r == "" and n == 0, "an error reading the node: left as it is")
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 79344 } }, {}, nil, function(e) return false end) return lst(rm), n end)()")
check(r == "" and n == 0, "has() given: used instead of the engine")
r = L.eval("(function() local t = { 1 } local rm = C.cfgGuard({ { entity = 79344 } }, t) return rm == t end)()")
check(r is True, "the list is completed in place")
L.execute('ENV.MPFEVER_CFGREPLACE = "0"')
r, n = L.eval("(function() local rm, n = C.cfgGuard({ { entity = 79344 } }, { 79338 }) return lst(rm), n end)()")
check(r == "79338" and n == 0, "MPFEVER_CFGREPLACE=0: as before")

print("the places that add configurations")
i = common.find("local onlyConfigs = #nodes == 0")
check(i > 0 and "C.cfgGuard(st.nodeConfigsToAdd, cfgKeep," in common[i:i + 2000] and "cfgKeep = keep" in common[i - 3000:i],
      "the rebuild (raw forms, configurations only) replaces")
i = common.find("local cfgRemove = {}")
check(i > 0 and "C.cfgGuard(st.nodeConfigsToAdd, cfgRemove," in common[i:i + 1200], "the native forms replace")
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
check("ncr = C.cfgGuard(step.nc, ncr)" in bridge, "the upgrade replay replaces")
check("ncr = C.cfgGuard(st.nodeConfigsToAdd, ncr)" in bridge, "the merged upgrade replay replaces")
check("if variant < 3 then ncr = C.cfgGuard(plan.nodeConfigs, ncr) end" in bridge, "the stop replay replaces")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
