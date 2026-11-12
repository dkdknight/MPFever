"""Offline test: a speed request repeated frame after frame is not sent again once another player changed the speed
(0.8.4, issue #252, MPFEVER_SPEEDREPEAT).

#252 (jmm15 host, tybjo): tybjo's game asked for the pause once a second for two minutes (99 requests), so every speed jmm15
set was paused again within a second (28 times). mpfever_ui.script.lua is read; U.speedRepeatHeld is run with lupa.
Run: python tests/test_speedrepeat084.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(UI, encoding="utf-8").read().replace("\r\n", "\n")
w = src[src.index('if tag.name == "makeGameSetSpeedCmd" then'):]
w = w[:w.index("\n\t\tend\n")]
check("the speed wrapper asks U.speedRepeatHeld first, answers the interface and sends nothing when it holds",
      w.index("U.speedRepeatHeld(tag.args[1], now)") < w.index('sendLine("speed_req"')
      and "if cb then pcall(cb, nil, true, {}) end\n\t\t\t\treturn\n\t\t\tend" in w)
check("  the once-a-second resend is kept for a request the session has not taken yet",
      "if tag.args[1] ~= U.lastSpeedReq or now - (U.lastSpeedAt or -10) > 1 then" in w)

try:
    import lupa.lua52 as lupa
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    f = re.search(r"^U\.speedRepeatHeld = function\(v, now\)\n.*?^end\n", src, re.S | re.M).group(0)
    L.execute("ENVV = {} os.getenv = function(k) return ENVV[k] end U = {} LOGS = {} log = function(s) LOGS[#LOGS + 1] = s end\n" + f)
    held = L.eval("function(v, now, speed) U.status = { speed = speed } return U.speedRepeatHeld(v, now) end")
    reset = L.eval("function(env) ENVV.MPFEVER_SPEEDREPEAT = env for k in pairs(U) do if k ~= 'speedRepeatHeld' then U[k] = nil end end LOGS = {} end")

    # #252: pause clicked, taken by the session, then the host sets x1 while the interface keeps asking for 0 every frame
    reset(None)
    # frames every 0.02 s: the session still at x1 (0.00-0.10), paused (0.12-0.50), the host's x1 (0.52-1.00)
    r = {}
    for k in range(0, 51):
        t = k * 0.02
        r[k] = held(0, t, "1" if t < 0.11 or t > 0.51 else "0")
    check("#252: the click and the stream before the session took it are sent (as before)", all(r[k] is False for k in range(0, 6)))
    check("  the session took it (speed 0): still not held", all(r[k] is False for k in range(6, 26)))
    check("  the host set x1, the stream goes on: held", all(r[k] is True for k in range(26, 51)))
    logs = list(L.eval("LOGS").values())
    check("  logged once, with where it came from", len(logs) == 1 and "keeps asking for speed 0 while another player set 1" in logs[0] and "from:" in logs[0])

    # a real click after a gap is sent again
    check("a new click (the same speed after a gap of 0.5 s) is sent", held(0, 2.00, "1") is False)
    # another speed is never held
    reset(None)
    held(0, 0.0, "0"); held(0, 0.02, "0")
    check("another speed (x2) is sent", held(2, 0.04, "0") is False)

    # a stream the session never took (the host has not answered yet): sent once a second as before
    reset(None)
    r = [held(0, t / 50.0, "1") for t in range(0, 100)]
    check("a request the session never took: never held (the once-a-second resend goes on)", not any(x is True for x in r))

    # the switch
    reset("0")
    held(0, 0.0, "0"); held(0, 0.02, "0")
    check("MPFEVER_SPEEDREPEAT=0: never held", held(0, 0.04, "1") is False and held(0, 0.06, "1") is False)
except ImportError:
    print("lupa is not installed: the function's cases not run")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
