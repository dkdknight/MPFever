"""Offline test of the held builds not taken for builds of a pause (0.7.3, MPFEVER_HELDNOTPAUSED, on with the host's
MPFEVER_NOSTOP=1; off by default).

A held build is captured when its game stands at its time, and the simulation half takes that stop for a pause: the capture
came marked "paused" though the session was not. The other games then never sent its replay as the simulation came to its
time, and stood there until the engine's answer (no MPFEVER_NOWAIT for a paused build): the two-builder stress test of
2026-11-06, the diagnostic MPFEVER_STANDLOG: "GATE Host:4: false (on true, native true, paused true, seq nil ...)", 0.4 to
0.6 s stood for every build. G.reallyPaused is taken from the real bridge file and run through lupa:
  - not marked paused: no;
  - marked paused, the session running and no turn of a pause: no (with the setting), yes (without it, as before);
  - marked paused with its turn of a pause, or the session paused here: yes.
Run: python tests/test_heldnotpaused.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
m = re.search(r"^G\.reallyPaused = function\(a, seq\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "G.reallyPaused found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("G = { heldNotPausedOn = true, session = {} }")
L.execute(m.group(0))
run = L.eval("function(code) local f = assert(load(code)) return f() end")
check(run("return G.reallyPaused({ paused = nil }, nil)") is False, "not marked paused: no")
check(run("return G.reallyPaused({ paused = true }, nil)") is False, "marked paused by its game's hold, the session running, no turn: no")
check(run("return G.reallyPaused({ paused = true }, 7)") is True, "with its turn of a pause: yes")
check(run("return G.reallyPaused({ paused = true, pseq = 3 }, nil)") is True, "shipped with its turn: yes")
check(run("G.session.pauseAt = 100; local r = G.reallyPaused({ paused = true }, nil); G.session.pauseAt = nil; return r") is True, "the session paused here: yes")
check(run("G.heldNotPausedOn = false; local r = G.reallyPaused({ paused = true }, nil); G.heldNotPausedOn = true; return r") is True,
      "without the setting (the default): marked paused is paused, as before")
check("local due = a.at <= now or (a.native and not G.reallyPaused(a, seq) and" in src, "sent as the simulation comes to its time")
check("local nw = G.gateOn() and a.native and not G.reallyPaused(a, seq) and not seq and" in src, "no wait for the answer")
check('G.heldNotPausedOn = G.featureOn("MPFEVER_HELDNOTPAUSED")' in src, "on with the host's setting")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
