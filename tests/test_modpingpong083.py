"""Offline test: two mods renaming the same vehicle in turn are no longer shipped every turn (0.8.3, #232, MPFEVER_MODPINGPONG).

Florian's session of 2026-11-11 (report #232/#234/#235): Liniennamen (ln.script) named each bus "Bus 11" and Betriebshof
(bh.script) named it back "Bus 11 ... ~1~Hainichen ZOB", every 2 s of game time: 72000 names shipped in 75 minutes for 147
vehicles, every one an action for every game. G.modSkip (0.7.1, #128) ships another value always. Now a value that comes back
right after another one 6 times within a minute is muted for 10 minutes of game time. G.modSkip0, G.modPingPong and G.modSkip
are taken from the real bridge (G.modSkip unchanged, G.modPingPong after it) and run through lupa (Lua 5.2).
Run: python tests/test_modpingpong083.py
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
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^G\.modSlots = \{\}\n.*?^G\.modPingPong = function\(p, now\)\n.*?^end\n", src, re.S | re.M)
if not m:
    print("FAIL: G.modSkip / G.modPingPong not found in the bridge")
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENVV = {}
local realgetenv = os.getenv
os.getenv = function(k) return ENVV[k] end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
G = {}
C = { ser = function(t) local o = {} for i = 1, 3 do o[i] = tostring(t[i]) end return table.concat(o, "|") end }
NAMES = {}
nameOf = function(e) return NAMES[e] end
-- the host: a mod asks, the name is applied at once if shipped (the worst case for the old rule: the name always differs)
function run(seq, dt)
  local shipped, t = 0, 1000000
  for i, v in ipairs(seq) do
    local p = { fn = "makeEntitySetNameCmd", args = { n = 2, 64468, v }, mod = (i % 2 == 0) and "bh.script.lua" or "ln.script.lua" }
    if not (G.modSkip(p, t, nameOf) or G.modPingPong(p, t)) then shipped = shipped + 1; NAMES[64468] = v end
    t = t + dt
  end
  return shipped
end
""" + m.group(0))
run = L.eval("function(code) return assert(load(code))() end")

# Florian's case: "Bus 11" and "Bus 11 ... Hainichen ZOB" in turn every 2 s, 75 minutes of game time (2250 turns)
n = run("local s = {} for i = 1, 2250 do s[i] = (i % 2 == 0) and 'Bus 11 ~1~Hainichen ZOB' or 'Bus 11' end return run(s, 2000)")
check("two mods in turn every 2 s for 75 minutes: shipped a few dozen times, not 2250", n < 120, n)
check("  said in the log", any("two values in turn" in str(v) for v in L.eval("LOG").values()))

# a vehicle whose destination name goes back and forth between its two terminals every 100 s: every change shipped
run("G.modSlots, G.modPing, NAMES = {}, {}, {}")
n = run("local s = {} for i = 1, 400 do s[i] = (math.floor(i / 50) % 2 == 0) and 'Bus 3 ~Am Markt' or 'Bus 3 ~Bahnhof' end return run(s, 2000)")
check("a name going back and forth between two terminals every 100 s: every change shipped (its 9 names)", n == 9, n)

# the old rule kept: the same name asked again is not shipped again
run("G.modSlots, G.modPing, NAMES = {}, {}, {}")
n = run("local s = {} for i = 1, 100 do s[i] = 'Bus 5' end return run(s, 2000)")
check("the same name asked again and again: shipped once (0.7.1)", n == 1, n)

# MPFEVER_MODPINGPONG=0: every turn, as before
run("G.modSlots, G.modPing, NAMES = {}, {}, {} ENVV.MPFEVER_MODPINGPONG = '0'")
n = run("local s = {} for i = 1, 300 do s[i] = (i % 2 == 0) and 'A' or 'B' end return run(s, 2000)")
check("MPFEVER_MODPINGPONG=0: every turn shipped, as before (300)", n == 300, n)

check("the host's mod commands go through G.modSkip, then G.modPingPong", "elseif G.modSkip(p, gameTime()," in src and "			or G.modPingPong(p, gameTime()) then" in src)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
