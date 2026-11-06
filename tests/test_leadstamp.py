"""Offline test of the stamp ahead of every game's clock (0.7.2, MPFEVER_LEADSTAMP=0: as before).

The two-builder stress test with computer companies of 2026-11-06 (Test Gameplay, one company per player, x4): the client led
(a tool in hand), so it ran ahead of the host by the lead's steps; the host's held build was stamped from the host's clock alone,
16 steps ahead, behind the client's clock: "MARGIN nat_pending -18 steps", "LATE native build Host:11 ... 18 step(s) late", the
"ages" apart and the games reloaded (with and without MPFEVER_NOWAIT; worse with it, the leader ran further ahead). stampFor is
taken from the real bridge file and run through lupa:
  - no other game: this game's clock plus the stamp distance, as before;
  - another game ahead (a leader): ahead of its clock, as it is now (aged by the session's speed), by the stamp distance;
  - a game behind: changes nothing; a clock heard more than 2 s ago: ignored (a game gone quiet would push every stamp away);
  - MPFEVER_LEADSTAMP=0: as before.
Run: python tests/test_leadstamp.py
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
m = re.search(r"^local function stampFor\(t\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "stampFor found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
CLOCK = 100.0
os.clock = function() return CLOCK end
STEP = 200
G = { ahead = 16, stampFloor = 0, peers = {}, session = { speed = 4 } }
''')
L.execute(m.group(0).replace("local function stampFor", "function stampFor", 1))
run = L.eval("function(code) local f = assert(load(code)) return f() end")
NOW = 25690000
check(run("return stampFor(%d)" % NOW) == NOW + 16 * 200, "no other game: this game's clock plus the stamp distance")
# the leader 20 steps ahead, its clock heard 0.11 s ago at x4 (aged by floor(0.11*5*4)+1 = 3 steps)
L.execute("G.peers = { Client = { t = %d, at = CLOCK - 0.11 } }" % (NOW + 20 * 200))
got = run("return stampFor(%d)" % NOW)
check(got == NOW + (20 + 3 + 16) * 200, "a leader 20 steps ahead: its clock as it is now plus the stamp distance", got)
L.execute("G.peers = { Client = { t = %d, at = CLOCK - 0.1 } }" % (NOW - 10 * 200))
check(run("return stampFor(%d)" % NOW) == NOW + 16 * 200, "a game behind: changes nothing")
L.execute("G.peers = { Client = { t = %d, at = CLOCK - 5 } }" % (NOW + 20 * 200))
check(run("return stampFor(%d)" % NOW) == NOW + 16 * 200, "a clock heard 5 s ago: ignored")
L.execute('G.peers = { Client = { t = %d, at = CLOCK - 0.1 } }; ENV["MPFEVER_LEADSTAMP"] = "0"' % (NOW + 20 * 200))
check(run("return stampFor(%d)" % NOW) == NOW + 16 * 200, "MPFEVER_LEADSTAMP=0: as before")
L.execute('ENV["MPFEVER_LEADSTAMP"] = nil; G.stampFloor = %d' % (NOW + 100 * 200))
check(run("return stampFor(%d)" % NOW) == NOW + 100 * 200, "the stamp floor still holds")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
