"""Offline test: a build replayed in a pause has its cost difference booked during the pause (0.7.17, issue #191; REFUND.book and
REFUND.unbooked in mpfever_bridge.script.lua).

#191 (NightHawk2583 "pc" and liber, 19:21:48 - 19:36:02): liber's street was replayed on the host in a pause, 143 180 for liber
and 14 365 less there; the difference was booked only at the first step after the pause. Meanwhile the host's money was 157 545
above liber's, and the host's vehicle bought in that pause (pc:153) passed on the host and was refused on liber's game for lack of
money (1 954 868 against 1 982 604): a resync. REFUND.book runs through lupa with the game's API mocked:
  - in a pause (the same game time), a replay's difference is booked one update of the simulation after its proposal, not at once;
  - a replay of 5 proposals whose last comes later books what it adds, once: the sum is the difference exactly;
  - REFUND.unbooked no longer counts what is booked (no double count in the checks);
  - after the pause nothing is booked twice;
  - MPFEVER_REFUNDPAUSE=0: booked at the first step after it, as before.
Needs lupa (pip install lupa). Run: python tests/test_refundpause0717.py
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


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


a = src.index("local REFUND = { pending = {}")
b = src.index("function REFUND.book(st, now)")
b = src.index("\nend\n", b) + 5
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
BS = "\\"
C = { IO = { open = function() return nil end }, DIR = "x", appendFile = function() end }
LOGS = {}
log = function(t) LOGS[#LOGS + 1] = t end
STEP = 200
-- (0.8.1) never a global SIM: in the bridge, REFUND.book is written above "local SIM" and reads the tick through
-- REFUND.sim (the 0.7.17 test defined a global SIM and hid "attempt to index global 'SIM'")
SIMT = { ctTick = 0 }
BOOKED = {}
CO = { entityOf = function(reg, co) return 100 + co end }
api = { type = { JournalEntry = setmetatable({ new = function() return { category = {} } end, Construction = { STREET = 3 }, Type = { CONSTRUCTION = 1, OTHER = 2 } }, { __index = function() return nil end }),
                 Vec3f = { new = function() return {} end } },
  cmd = { makeJournalBookAssetCmd = function(ent, e) return { ent = ent, amount = e.amount } end,
          sendCommand = function(cmd, cb) BOOKED[#BOOKED + 1] = cmd.amount; if cb then cb() end end },
  engine = { util = { getPlayer = function() return 1 end } } }
''')
L.execute(src[a:b].replace("local REFUND = ", "REFUND = ", 1) + "\nREFUND.free = false")
L.execute("REFUND.sim = SIMT SIM = nil")


def run(code):
    return L.eval("(function() " + code + " end)()")


# a pause: game time 584600 stands; the replay's proposal at tick 10
r = run('''BOOKED = {} SIMT.ctTick = 10
ST = { co = { mode = "separate" }, rcost = { { at = 584600, uid = "liber#13:20", cost = 143180, co = 2, got = 0, n = 0, kind = "STREET" } } }
local rc = ST.rcost[1] rc.got = 128815 rc.n = 1 rc.tick = SIMT.ctTick
REFUND.book(ST, 584600)
local first = #BOOKED
SIMT.ctTick = 11 REFUND.book(ST, 584600)
return first .. ":" .. #BOOKED .. ":" .. tostring(BOOKED[1])''')
check(r == "0:1:-14365", "in a pause: booked one update after its proposal, -14 365 (not at once)", r)
r = run('''REFUND.list = ST.rcost return REFUND.unbooked("b2")''')
check(r == 0, "unbooked: what is booked is no longer counted", r)
r = run('''local rc = ST.rcost[1] rc.got = rc.got + 5000 rc.n = 2 rc.tick = SIMT.ctTick
SIMT.ctTick = 12 REFUND.book(ST, 584600) return #BOOKED .. ":" .. tostring(BOOKED[2])''')
check(r == "2:5000", "a later proposal of the same replay: what it adds, once", r)
r = run('''SIMT.ctTick = 13 REFUND.book(ST, 584600) SIMT.ctTick = 14 REFUND.book(ST, 584800)
return #BOOKED .. ":" .. tostring(ST.rcost)''')
check(r == "2:nil", "after the pause: nothing booked twice, the record gone", r)
r = run('''BOOKED = {} SIMT.ctTick = 20 ENV.MPFEVER_REFUNDPAUSE = "0"
ST = { co = { mode = "separate" }, rcost = { { at = 900, uid = "x", cost = 1000, co = 2, got = 900, n = 1, tick = 20 } } }
SIMT.ctTick = 25 REFUND.book(ST, 900) local inPause = #BOOKED
REFUND.book(ST, 1100) ENV = {}
return inPause .. ":" .. #BOOKED .. ":" .. tostring(BOOKED[1])''')
check(r == "0:1:-100", "MPFEVER_REFUNDPAUSE=0: at the first step after the pause, as before", r)
r = run('''BOOKED = {} SIMT.ctTick = 30
ST = { co = { mode = "separate" }, rcost = { { at = 1200, uid = "late", co = 2, got = 900, n = 1, tick = 30, late = true } } }
SIMT.ctTick = 32 REFUND.book(ST, 1200) return #BOOKED .. ":" .. #ST.rcost''')
check(r == "0:1", "the builder's cost not known yet: nothing booked, kept", r)

r = run('''return tostring(rawget(_G, "SIM"))''')
check(r == "nil", "(0.8.1) no global SIM in this test: REFUND.book ran without one", r)
check(re.search(r"local SIM = \{ subscribed = false \}\n(--[^\n]*\n)*REFUND\.sim = SIM\n", src) is not None,
      "(0.8.1) the bridge gives REFUND.sim right after declaring SIM")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
