"""Offline test of a computer company's build checked again when it is released (0.6.4.1, the crash of test o2 on 2026-10-31).

A computer company's stop is made from the interface's view of the world and goes to the engine some steps later. A stop built on
a segment that another stop had just replaced was rebuilt without that stop: the engine asserted ('it != components.end()', Engine.h
323) on the simulation thread and the host's game stopped. Now each stop build carries a check (the segment still there, the same
ends, still no object), run by the bridge's deferredSend just before the build goes to the engine.

  - buildStop (mpfever_ai.lua, through tests/ai_mock.py): its check is true for the segment as it was; a string when the segment
    is gone, has other ends, or carries an object now;
  - stillOk (mpfever_bridge.script.lua, through lupa): a true check sends the build; a string does not, the others are told (the
    build cancelled as a refused one) and the company hears a refusal; a check that fails to run sends it; MPFEVER_AISTILL=0 sends it;
  - deferredSend calls stillOk before both of its sends (held and BUILDLEAD);
  - stopSegments: no stop on a segment that ends at a junction with traffic lights or a configuration (the crashes of test o2);
    MPFEVER_AISTOPLIGHTS=1: as before.
Needs lupa (pip install lupa). Run: python tests/test_aistill.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker, CONTENT

check, failures = checker()

print("buildStop's check")
L, M = load()
run = L.eval("function(code) local f = assert(load(code)) return f() end")
run('G.AI = {}; G.natCtx = {}; MONEY[700] = 3000000; M.p.set(2, 600000, 150000)')
run('function edge(n0, objs) return { node0 = n0, node1 = 42, tangent0 = {}, tangent1 = {}, type = 0, typeIndex = -1, roadTemplate = "t", laneConfigs = {}, objects = objs or {} } end')
run('setComp(60, "BASE_EDGE", edge(41))')
check(run('return M.f.buildStop(E, CO1, 60, "x")') is True, "the stop is built")
check(run('return type(LASTSTILL) == "function"') is True, "it goes with a check")
check(run('return LASTSTILL()') is True, "the segment as it was: true")
run('setComp(60, "BASE_EDGE", edge(41, { { 900, 1 } }))')
got = run('return LASTSTILL()')
check(isinstance(got, str) and "object" in got, "a stop on it since: not sent (" + str(got) + ")")
run('setComp(60, "BASE_EDGE", edge(43))')
got = run('return LASTSTILL()')
check(isinstance(got, str) and "another segment" in got, "other ends (the id names another segment now): not sent (" + str(got) + ")")
run('COMP[60] = nil')
got = run('return LASTSTILL()')
check(isinstance(got, str) and "no longer exists" in got, "the segment gone: not sent (" + str(got) + ")")

print("the segments a stop may take")
run('setComp(61, "BASE_EDGE", { node0 = 81, node1 = 82 }); setComp(62, "BASE_EDGE", { node0 = 82, node1 = 83 }); setComp(63, "BASE_EDGE", { node0 = 84, node1 = 85 })')
run('setComp(83, "BASE_NODE_TRAFFIC_LIGHT", {}); setComp(84, "BASE_NODE_CONFIG", {}); setComp(64, "BASE_EDGE", { node0 = 86, node1 = 87 })')
got = run('local t = {} for _, s in ipairs(M.f.stopSegments(E, CO1, { { e = 61 }, { e = 62 }, { e = 63 }, { e = 64 } })) do t[#t + 1] = s.e end return table.concat(t, ",")')
check(got == "61,64", "segments ending at a junction with traffic lights or a configuration: left out (" + str(got) + ")")
got = run('ENV = { MPFEVER_AISTOPLIGHTS = "1" }; local n = #M.f.stopSegments(E, CO1, { { e = 62 } }); ENV = {}; return n')
check(got == 1, "MPFEVER_AISTOPLIGHTS=1: taken, as before")
src_ai = open(os.path.join(CONTENT, "mpfever_ai.lua"), encoding="utf-8").read()
check(src_ai.count("stopSegments(E, co, streetSegmentsNear(") == 2, "both places that pick a stop's segment use it")

print("the bridge")
src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
m = re.search(r"^local function stillOk\(id, still, cb\)\n.*?^end\n", src, re.S | re.M)
d = re.search(r"^local function deferredSend\(cmd, cb, proposal, still\)\n.*?^end\n", src, re.S | re.M)
check(m is not None and d is not None, "stillOk and deferredSend(cmd, cb, proposal, still) found")
if d:
    body = d.group(0)
    check(body.count("if stillOk(id, still, cb) then O.sendCommand(cmd,") == 2, "deferredSend checks before both of its sends")
if m:
    B = lupa.LuaRuntime(unpack_returned_tuples=True)
    B.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, CANCELLED, HEARD = {}, {}, {}
function log(s) LOGS[#LOGS + 1] = s end
G = { natShipIds = { { id = 100004 }, { id = 100005 } } }
G.leadRefused = function(e, why) CANCELLED[#CANCELLED + 1] = e.id end
function cb(res, ok) HEARD[#HEARD + 1] = tostring(res) .. "/" .. tostring(ok) end
''')
    B.execute(m.group(0).replace("local function stillOk", "function stillOk", 1))
    brun = B.eval("function(code) local f = assert(load(code)) return f() end")
    check(brun('return stillOk(100004, function() return true end, cb)') is True and brun('return #CANCELLED') == 0, "a true check: sent")
    check(brun('return stillOk(100004, nil, cb)') is True, "no check: sent")
    check(brun('return stillOk(100004, function() return "segment 60 carries 1 object(s) now" end, cb)') is False,
          "a reason: not sent")
    check(brun('return CANCELLED[1] == 100004 and HEARD[1] == "nil/false"') is True, "the others told (cancelled), the company hears a refusal")
    check(brun('CANCELLED = {}; return stillOk(100005, function() error("boom") end, cb)') is True and brun('return #CANCELLED') == 0,
          "a check that fails to run: sent")
    check(brun('ENV = { MPFEVER_AISTILL = "0" }; local r = stillOk(100005, function() return "x" end, cb); ENV = {}; return r') is True,
          "MPFEVER_AISTILL=0: sent, as before")

if failures:
    print(f"FAIL {len(failures)} case(s)")
    sys.exit(1)
print("all cases passed")
