"""Offline test: the auction's clock follows the simulation (0.8.3, a player's suggestion, MPFEVER_AUCTIONREAL).

"The functions added to the game (the auction...) keep going while the simulation is paused": the auction of a bankrupt company
ran on the host's real time (os.time), so it ended during a pause. Its clock is now the game's time in seconds (G.auClock): it
stops while the session is paused and goes 4 times faster at x4; the window's countdown between two updates goes down at the
session's speed. G.auClock is taken from the real bridge and run through lupa (Lua 5.2); the rest is read.
Run: python tests/test_auclock083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


br = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^G\.auClock = function\(\)\n.*?^end\n", br, re.S | re.M)
if not m:
    print("FAIL: G.auClock not found")
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENVV = {} T = 0 os.getenv = function(k) return ENVV[k] end os.time = function() return 1700000000 end "
          "gameTime = function() return T end G = {}\n" + m.group(0))
clock = L.eval("function(t) T = t return G.auClock() end")
check("the game's time in seconds", clock(25668400) == 25668)
check("  a pause (the game's time stands): the clock stands", clock(25668400) == clock(25668400))
check("  x4: 4 game seconds a real second (the time it is given)", clock(25672400) - clock(25668400) == 4)
L.execute("ENVV.MPFEVER_AUCTIONREAL = '1'")
check("MPFEVER_AUCTIONREAL=1: the host's real time, as before", clock(25668400) == 1700000000)

check("the bridge's auction (eco.txt's time left, the host's close) reads G.auClock",
      "\tlocal au = reg.auction\n\t-- (when this game saw the lot open: the time left it shows)\n\tlocal nowT = G.auClock and G.auClock() or os.time()\n" in br)
check("  no os.time() left in that function's clock", "local nowT = os.time()" not in br)
check("the window's countdown goes down at the session's speed (0 while paused)",
      "auRate = tonumber(U.shownSpeed and U.shownSpeed()) or 1" in ui
      and "local left = math.max(0, au.left - math.floor((os.clock() - (au.at or os.clock())) * auRate))" in ui)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
