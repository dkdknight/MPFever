"""Offline test: a build that replaces segments and whose stop or signal cannot be rebuilt is refused on every game (0.9.3,
issues #444 #445, MPFEVER_EOGUARD; mod/mpfever_1/content/mpfever_bridge.script.lua, executeActionOnce).

The bug (#444, alex's game, 2026-11-19 21:24:43, separate companies): Angelo (MPFever 0.9.1 on Transport Fever 3's build 40444)
made a signal one-way from its window. The window's build names the signal without a model; every game rebuilt it with the note
"edge object 1 without model (not replicated)": the segment 75635 and its signal removed, a new one without it (Angelo#11:5).
Angelo#11:6 changed it again, and every game stopped on the engine's assertion "it != components.end()" (Entity 56613, component
type index 40). #445: alex started the same session again with 0.9.2, the old action of the stream was replayed, the same crash.
0.9.2 refuses those windows at their maker; an old action replayed still went through.
The fix: such a build (an edge object without a model, segments replaced) is refused on every game; every game rebuilds the
same shipped form, so every game refuses it, and the games stay equal. MPFEVER_EOGUARD=0: rebuilt without them, as before.

Part 1 runs the guard taken from the bridge through lupa (Lua 5.2): the case of #444 refused, as before with the switch at 0
(the bug), not refused without a lost object or without a replaced segment. Part 2 checks the note it reads is the rebuild's own
(mpfever_common.lua) and that the guard comes after the rebuild and before the command is sent.
Run: python tests/test_eoguard093.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


i = src.index('\t\tif os.getenv("MPFEVER_EOGUARD") ~= "0" then')
guard = src[i:src.index("\t\t-- (0.7.7, issue #133)", i)]


def run(errors, removed, switch_off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; LOGS = {}; function log(t) LOGS[#LOGS + 1] = t end")
    if switch_off:
        L.execute("ENV.MPFEVER_EOGUARD = '0'")
    L.execute("C = { errors = {} }")
    for e in errors:
        L.execute("C.errors[#C.errors + 1] = %r" % e)
    segs = ", ".join("{ entity = %d }" % (75635 + k) for k in range(removed))
    L.execute("A = { uid = 'Angelo#11:5', fn = 'makeWorldBuildProposalCmd', args = { { proposal = { addedSegments = { {} }, removedSegments = { %s } } } } }" % segs)
    f = L.execute("return function(a) local result = { success = false }\n" + guard + "\nreturn nil end")
    r = f(L.eval("A"))
    return (r is not None and r["err"]) or None, list(L.eval("LOGS").values())


NOTE = "edge object 1 without model (not replicated)"
err, logs = run(["node configs given again: 2", NOTE], 1, switch_off=True)
check("bug reproduced (switch at 0): Angelo#11:5 rebuilt without its signal, not refused", err is None)
err, logs = run(["node configs given again: 2", NOTE], 1)
check("fix: refused on every game", err is not None and "cannot be rebuilt" in err and "1 segment(s) it replaces" in err, err)
check("  said", any("Angelo#11:5 makeWorldBuildProposalCmd refused on every game" in t for t in logs), logs)
err, _ = run(["node configs given again: 2"], 1)
check("a build whose signals are all rebuilt: not refused", err is None)
err, _ = run([NOTE], 0)
check("a new segment with an object without model (nothing replaced): not refused", err is None)
err, _ = run([NOTE, "edge object 2 without model (not replicated)"], 2)
check("two objects lost on two segments: refused", err is not None and "its 2 stop(s) or signal(s)" in err, err)

check("the note read is the rebuild's own", '"edge object " .. i .. " without model (not replicated)"' in common)
ex = src[src.index("local function executeActionOnce(a, sendCommand, useCallback, bind, done)"):]
g = ex.index('if os.getenv("MPFEVER_EOGUARD") ~= "0" then')
check("the guard comes after the build's rebuild", ex.index("buildCommand(a.fn, C.ser(a.args or {})") < g
      and ex.index('if #C.errors > 0 then log("  notes: "') < g)
check("  and before its rebuilt form is announced and the command sent", g < ex.index("C.rebuiltSig, type(a.args)"))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
