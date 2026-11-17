"""Offline test (0.8.17, diagnostic MPFEVER_GUIPROF=1): the interface half's time by part, in the "gui alive" lines
(G.gpMark / G.guiUpdateBody in mpfever_bridge.script.lua).

The "gui alive" lines said the bridge's interface half took about 1 ms a frame (k9 autotests, 2026-11-17), not where. With the
switch, every part of a frame (in.log, the simulation's state, companies, shipping, native builds, replays, pacing, bindings,
waits...) is timed and logged as "prof <part>=<ms a frame>". Off (the default), nothing is measured and the line is as before.
G.gpMark is run through lupa with a fake clock; the body's marks are checked in the real bridge.
Needs lupa. Run: python tests/test_guiprof0817.py
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


check("off unless MPFEVER_GUIPROF=1 (or 2: with the state cache's comparison)", 'G.gpOn = os.getenv("MPFEVER_GUIPROF") == "1" or os.getenv("MPFEVER_GUIPROF") == "2"' in src
      and 'G.gpCheck = os.getenv("MPFEVER_GUIPROF") == "2"' in src)
m = re.search(r"^G\.gpMark = function\(name\)\n.*?^end\n", src, re.S | re.M)
check("G.gpMark found", m is not None)
if m:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("NOW = 10.0\nos.clock = function() return NOW end\nG = {}\n" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    run("G.gpLast = os.clock(); NOW = 10.002; G.gpMark('inlog'); NOW = 10.005; G.gpMark('stateget'); NOW = 10.006; G.gpMark('inlog')")
    a, b = run("return G.gpT.inlog, G.gpT.stateget")
    check("each part gets the time since the mark before", abs(a - 0.003) < 1e-9 and abs(b - 0.003) < 1e-9, (a, b))
body = src[src.index("G.guiUpdateBody = function(userParams, state, guiState)"):]
body = body[:body.index("\nend\n")]
marks = re.findall(r'if gp then G\.gpMark\("(\w+)"\) end', body)
check("the frame's parts are marked in order", marks == ["ticks", "stand", "head", "inlog", "still", "stateget", "prune", "cogui", "featai", "ship", "native", "paused", "replays", "pacing", "bind", "waits"], marks)
check("every mark behind the switch (nothing measured when off)", body.count("G.gpMark(") == len(marks))
check("logged in the gui alive line only with the switch, then reset", '(gp and G.gpT and (function()' in body and "G.gpT = nil" in body)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
