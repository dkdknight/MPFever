"""Offline test: the computer companies' plans taken in slices (0.8.7; RL.inTime, RL.active, M.slicing in
mod/mpfever_1/content/mpfever_ai.lua, the step's coroutine in the bridge, switch MPFEVER_AISLICE).

A passenger railway between two towns (written in 0.7.5, off by default): the way of its track through the towns' streets took
the planner more than RL.BUDGET (2 s), the host's game held meanwhile (tests px1 and px2 of 2026-11-07), and the plan was left.
  - in the bridge's coroutine (M.slicing on), RL.inTime gives the frame back (coroutine.yield) after RL.SLICE s of work and the
    plan goes on when resumed;
  - its limit is then RL.SLICED s of work in all, the time between slices not counted (RL.spent); RL.active() is the clock
    without the time stood aside (RP.place's limit);
  - out of a coroutine (or with slicing off), the old limit: RL.BUDGET s of wall time, then the plan is left;
  - the bridge resumes a step under way before any new one, logs the longest frame of each minute, MPFEVER_AISLICE=0: in one go.
Needs lupa (pip install lupa). Run: python tests/test_aislice087.py
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


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


ai = open(os.path.join(CONTENT, "mpfever_ai.lua"), encoding="utf-8").read().replace("\r\n", "\n")
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = ai.index("RL.BUDGET = tonumber(")
b = ai.index("local function L(E, s)")
block = ai[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
# a fake clock the test moves by hand
L.execute('''
NOW = 0
os.clock = function() return NOW end
os.getenv = function() return nil end
RL = {}
''' + block)
check(L.eval("RL.SLICE") == 0.02 and L.eval("RL.SLICED") == 20, "a slice of 20 ms, 20 s of work in all")

# a plan in a coroutine, slicing on: yields after a slice of work, resumes, goes on
L.execute('''
RL.sliceOn = true
RL.deadline = NOW + RL.BUDGET
RL.spent, RL.sliceAt = 0, NOW
YIELDS = 0
CO = coroutine.create(function()
  for i = 1, 300 do NOW = NOW + 0.01; RL.inTime() end
  return "done"
end)
local st, r
repeat
  st, r = coroutine.resume(CO)
  if coroutine.status(CO) == "suspended" then YIELDS = YIELDS + 1; NOW = NOW + 0.5 end
until coroutine.status(CO) == "dead"
RESULT = r
''')
check(L.eval("RESULT") == "done", "a 3 s plan in slices goes to its end (more than RL.BUDGET of wall time, never left)", L.eval("RESULT"))
check(L.eval("YIELDS") >= 100, "  the frame given back after every slice", L.eval("YIELDS"))
check(abs(L.eval("RL.spent") - 3.0) < 0.2, "  RL.spent counts the work only, not the time between slices", L.eval("RL.spent"))
check(L.eval("RL.away") > 40, "  RL.away counts the time stood aside", L.eval("RL.away"))

# more than RL.SLICED s of work: left
L.execute('''
RL.SLICED = 1
RL.deadline = NOW + RL.BUDGET
RL.spent, RL.sliceAt = 0, NOW
CO2 = coroutine.create(function() for i = 1, 300 do NOW = NOW + 0.01; RL.inTime() end return "done" end)
repeat OK2, R2 = coroutine.resume(CO2) until coroutine.status(CO2) == "dead"
''')
check(L.eval("OK2") is False and "more than 1 s of work" in str(L.eval("R2")), "more than RL.SLICED s of work: the plan is left", L.eval("R2"))

# out of a coroutine: the old wall-clock limit
L.execute('''
RL.sliceOn = true
RL.deadline = NOW + 2
OK3, R3 = pcall(function() for i = 1, 300 do NOW = NOW + 0.01; RL.inTime() end return "done" end)
''')
check(L.eval("OK3") is False and "longer than 2 s" in str(L.eval("R3")), "out of a coroutine: RL.BUDGET s of wall time, as before", L.eval("R3"))
L.execute('''
RL.sliceOn = false
RL.deadline = NOW + 100
CO4 = coroutine.create(function() for i = 1, 300 do NOW = NOW + 0.01; RL.inTime() end return "done" end)
Y4 = 0
repeat local s = coroutine.resume(CO4); if coroutine.status(CO4) == "suspended" then Y4 = Y4 + 1 end until coroutine.status(CO4) == "dead"
''')
check(L.eval("Y4") == 0, "slicing off: never gives the frame back")

# RL.yield: any long look gives the frame back in slices, never an error, nothing out of the coroutine
L.execute('''
RL.sliceOn = true
RL.deadline = NOW - 100
RL.sliceAt = NOW
COY = coroutine.create(function() for i = 1, 500 do NOW = NOW + 0.01; RL.yield() end return "done" end)
YY = 0
repeat OKY, RY = coroutine.resume(COY); if coroutine.status(COY) == "suspended" then YY = YY + 1 end until coroutine.status(COY) == "dead"
OKY2, RY2 = pcall(function() for i = 1, 500 do NOW = NOW + 0.01; RL.yield() end return "done" end)
RL.allOff = true
COZ = coroutine.create(function() for i = 1, 500 do NOW = NOW + 0.01; RL.yield() end return "done" end)
YZ = 0
repeat local s = coroutine.resume(COZ); if coroutine.status(COZ) == "suspended" then YZ = YZ + 1 end until coroutine.status(COZ) == "dead"
RL.allOff = false
''')
check(L.eval("OKY") is True and L.eval("RY") == "done" and L.eval("YY") >= 200, "RL.yield: a 5 s look goes to its end in slices, no limit, no error", f"{L.eval('RY')} {L.eval('YY')}")
check(L.eval("OKY2") is True and L.eval("RY2") == "done", "  out of a coroutine: nothing (no yield, no error)", L.eval("RY2"))
check(L.eval("YZ") == 0, "  MPFEVER_AISLICEALL=0: never gives the frame back")
check('RL.allOff = os.getenv("MPFEVER_AISLICEALL") == "0"' in ai, "  the switch MPFEVER_AISLICEALL")
for head, name in [('for _, e in ipairs(R.entitiesWith("INDUSTRY")) do\n\t\tRL.yield()', "the industries read"),
                   ("for _, q in ipairs(prod and inds or {}) do\n\t\t\t\t\tRL.yield()", "the truck routes between industries"),
                   ("for _, t in ipairs(townsBySize(E)) do\n\t\tRL.yield()", "the towns' deliveries"),
                   ("for _, ind in ipairs(inds) do\n\t\t\t\t\t\tRL.yield()", "  their producers"),
                   ("for _, b in ipairs(T.tbMap[town] or {}) do\n\t\t\tRL.yield()", "the towns' buildings")]:
    check(head in ai, "  a slice at the head of the loop of " + name)

check("function M.slicing(on) RL.sliceOn = on == true; RL.sliceAt = os.clock() end" in ai, "M.slicing: the bridge says when the step runs in its coroutine")
check("local t0 = RL.active()" in ai and "if RL.active() - t0 > RP.PLACE then return fallback end" in ai, "RP.place: its limit on the work's time")
r = bridge[bridge.index("if G.aiMod and G.aiMod.tick then"):]
r = r[:r.index("\nend\n")]
check('if G.aiMod.slicing and (sl == "1" or (sl ~= "0" and G.aiMod.slicingWanted and G.aiMod.slicingWanted())) then' in r,
      "the bridge: in slices only while a plan needs it, MPFEVER_AISLICE=1 always, =0 never")
check('function M.slicingWanted() local v = os.getenv("MPFEVER_AIPAXRAIL"); return v == "1" or v == "hard" end' in ai,
      "  needed by the passenger railway only (off by default: the step in one go, as in 0.8.6)")
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
sw = ai[ai.index("function M.slicingWanted()"):]
sw = sw[:sw.index("\n")]
for val, want in [(None, False), ("1", True), ("hard", True), ("0", False)]:
    L2.execute("M = {}; ENVV = " + ("nil" if val is None else '"' + val + '"') + "; os.getenv = function() return ENVV end\n" + sw)
    check(L2.eval("M.slicingWanted()") == want, f"  MPFEVER_AIPAXRAIL={val}: slices {want}")
check(r.index('coroutine.status(G.aiCo) == "suspended"') < r.index("coroutine.create("), "  a step under way resumed before any new one")
check("longest frame of the last minute" in r, "  the longest frame of each minute logged")
g = r.index("AI step under way left")
check(r.index("not S0.resync and S0.pauseAt == nil") < g < r.index('if G.aiCo and coroutine.status(G.aiCo) == "suspended" then\n\t\t\t\tokt'),
      "  a step under way left (not resumed) when the session paused, resynchronises or stopped meanwhile")
check("pcall(G.aiMod.tick, G.aiEnv(), st)" in r, "  the old call kept for the switch")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
