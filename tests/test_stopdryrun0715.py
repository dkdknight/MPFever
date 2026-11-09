"""Offline test: a street stop's replay asks the engine's verdict on each form before it sends it, and goes without waiting again
(0.7.15, NOWAIT v3; G.stopDryVerdict and replayStop in mpfever_bridge.script.lua).

0.7.14 (NOWAIT v2) kept the wait for the street stops: a stop the engine refused in its first form was tried again (without the
tool's pricing, with the street cleanup, by the engine's conversion of the tool's build) when its answer came, a frame later;
without the wait that next try came after the stop's step on the replaying games only (r161, a reload). The field logs: 3 of
736 such stops refused once, "Kollision" (AMD/Sascha, #148) and "Construction Not Possible" (Bence, #161), which a proposal's
data shows before anything is built.
  - G.stopDryVerdict, run through lupa: the error state's critical flag and its messages; MPFEVER_STOPDRYFAKE=n (tests): the
    first n verdicts "refused";
  - replayStop asks it before the form goes: a form it would refuse is not sent, the next one is made at once (pricing, cleanup,
    the engine's conversion, in the order the answers led to), every form at the stop's step;
  - then the stop is marked single (no wait), unless MPFEVER_STOPDRYRUN=0 or MPFEVER_NOWAITSTOPS=0 (as in 0.7.14);
  - an answer that still says no goes the way it went (the retries on the next frame stay).
Needs lupa (pip install lupa). Run: python tests/test_stopdryrun0715.py
"""
import os, sys

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


src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = src.index("G.stopDryVerdict = function(sp, ctx)")
fn = src[i:src.index("\nend\n", i) + 5]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
G = {}
C = { ser = function(t) local o = {} for _, v in ipairs(t) do o[#o + 1] = tostring(v) end return "{" .. table.concat(o, ",") .. "}" end,
      marshal = function(x) return x end }
PD = nil
api = { engine = { util = { proposal = { makeProposalData = function(sp, ctx) CALLED = (CALLED or 0) + 1 return PD end } } } }
''' + fn)
run = L.eval("function(code) return assert(load(code))() end")

print("the engine's verdict")
run("PD = { errorState = { critical = true, messages = { 'Kollision' } } }")
check(run("local c, m = G.stopDryVerdict({}, {}) return tostring(c) .. '|' .. m") == "true|{Kollision}", "critical: refused, with its messages (#148's \"Kollision\")")
run("PD = { errorState = { critical = false, messages = { 'some warning' } } }")
check(run("local c, m = G.stopDryVerdict({}, {}) return tostring(c) .. '|' .. m") == "false|", "not critical: built (a warning is no refusal)")
run("PD = {}")
check(run("local c = G.stopDryVerdict({}, {}) return c") is False, "no error state: built")
run("ENV.MPFEVER_STOPDRYFAKE = '2'; CALLED = 0; PD = { errorState = { critical = false } }")
check(run("local a = G.stopDryVerdict({}, {}) local b = G.stopDryVerdict({}, {}) local c = G.stopDryVerdict({}, {}) return tostring(a) .. tostring(b) .. tostring(c) .. CALLED") == "truetruefalse1",
      "MPFEVER_STOPDRYFAKE=2 (tests): the first two verdicts \"refused\", then the engine's")

print("replayStop")
rst = src[src.index("local function replayStop(a, plan, variant)"):]
rst = rst[:rst.index("\nend\n")]
a = rst.index('local dryRun = os.getenv("MPFEVER_STOPDRYRUN") ~= "0" and not plan.probeOnly')
b = rst.index("local okV, crit, msgs = pcall(G.stopDryVerdict, sp, sContext(not plan.after and a or nil, plan.cleanup))")
c1 = rst.index("plan.plainCosts = true", b)
c2 = rst.index("plan.cleanup = true", c1)
c3 = rst.index("local okN, errN = pcall(G.replayNativeStop, a, plan)", c2)
d = rst.index('local before = stopCount()')
e = rst.index('if nws == "1" or (dryRun and nws ~= "0") then pcall(G.gateSingle) end')
f = rst.index("replaySend(cmd, function(res, success)")
check(rst.index("local okf, cmd = pcall(function()") < a < b < d < e < f,
      "asked once the form's command is made, before the stop counts and the send")
check(b < c1 < c2 < c3 < d, "a refusal foreseen: without the tool's pricing, then with the street cleanup, then the engine's conversion (the answers' order)")
blk = rst[b:d]
check(blk.count("return replayStop(a, plan, variant)") == 2 and "if okN then return end" in blk,
      "  each next form made at once (no frame waited), the conversion instead of the last form when it goes")
check("MPFEVER_STOPNATIVERETRY" in blk and "not plan.nativeTried" in blk, "  the conversion only once, MPFEVER_STOPNATIVERETRY=0 as before")
check('if os.getenv("MPFEVER_STOPDRYRUN") ~= "0"' not in rst and "MPFEVER_STOPDRYRUN=0: every form sent, the stops wait, as in 0.7.14" in rst,
      "MPFEVER_STOPDRYRUN=0: no verdict asked, the stops wait as in 0.7.14")
check("not plan.probeOnly" in rst[a:b], "not for a probe (H.bridgestopprobe: nothing sent)")
after = rst[f:]
check('G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayStop(a, plan, variant) end }' in after
      and 'pcall(G.gateLate, "a refused stop, tried again")' in after,
      "an answer that still says no: tried again on the next frame, as before (logged late)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
