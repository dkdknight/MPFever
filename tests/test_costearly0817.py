"""Offline test (0.8.17, #398): a builder's cost that comes before the replay of its copy is kept for it (the simulation's
"replay_cost" / "replay_cost_set" messages and REFUND.book in mpfever_bridge.script.lua, switch MPFEVER_COSTEARLY).

The dedicated server, behind the other games, got berni1212's confirmations of #3:98 and #3:104 (built by its builder as its copy,
with its cost) before it replayed them: the cost found no record and was lost; the replay's record came after without a cost,
waited 50 steps and was dropped without a word. The server's company 3 kept 15 584 its builder had paid (414 399 against 398 815
for the replay), money corrections followed.
The two message branches and REFUND.book are taken from the real bridge and run through lupa:
  - MPFEVER_COSTEARLY=0 (as before): the cost first, then the replay: nothing booked (the bug, reproduced), now said in the log;
  - now: the cost first, then the replay: the difference booked, as when the cost comes after the replay;
  - the usual order (replay, then cost): unchanged;
  - kept costs are bounded (64) and dropped after 600 steps; a replay with its own cost ignores them.
Needs lupa. Run: python tests/test_costearly0817.py
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


a = src.index('\t\telseif name == "replay_cost" then\n')
b = src.index('\t\telseif name == "replay_stats" then\n')
branch = src[a:b]
m_b = re.search(r"^function REFUND\.book\(st, now\)\n.*?^end\n", src, re.S | re.M)
check("the message branches and REFUND.book found", bool(branch and m_b))
if not m_b:
    sys.exit(1)

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 5000000
LOGS, BOOKED = {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function gameTime() return NOW end
REFUND = { pending = {}, CHECKED = true }
REFUND.freeBuilds = function() return false end
REFUND.key = function(co, c) return "b" .. tostring(c) end
CO = { entityOf = function(reg, c) return 1000 + c end }
api = { type = { JournalEntry = { new = function() return { category = {} } end, Construction = { DEPOT = 5 }, Type = { CONSTRUCTION = 1, OTHER = 2 } },
                 Vec3f = { new = function() return {} end } },
        cmd = { makeJournalBookAssetCmd = function(ent, entry) return { ent = ent, amount = entry.amount } end,
                sendCommand = function(cmd, cb) BOOKED[#BOOKED + 1] = cmd.amount end },
        engine = { util = { getPlayer = function() return 1 end } } }
function HANDLE(name, param, st)
  if false then
''' + branch + r'''
  end
end
'''


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m_b.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_COSTEARLY = '0'")
    run("ST = { co = { mode = 'separate' } }")
    return run


def scenario(run, cost_first):
    # the copy of berni1212#3:104 replayed here (late: a copy shipped at the click, its builder's cost comes with its confirmation)
    if cost_first:
        run("HANDLE('replay_cost_set', { uid = 'berni1212#3:104', cost = 414399, at = 78432000 }, ST)")
    run("HANDLE('replay_cost', { uid = 'berni1212#3:104', co = 3, kind = 'DEPOT', late = true, at = 78432000 }, ST)")
    # the replay here cost 398 815 (one proposal), counted by the capture
    run("local rc = ST.rcost[#ST.rcost]; rc.got = 398815; rc.n = 1")
    if not cost_first:
        run("HANDLE('replay_cost_set', { uid = 'berni1212#3:104', cost = 414399, at = 78432000 }, ST)")
    # the steps go by: booked at the next step after its time, or dropped after 50
    for k in range(1, 60):
        run(f"NOW = NOW + STEP; REFUND.book(ST, NOW)")
    return list(run("local t = {} for i, v in ipairs(BOOKED) do t[i] = v end return t").values())


run = runtime(off=True)
got = scenario(run, cost_first=True)
check("MPFEVER_COSTEARLY=0, the cost before the replay: nothing booked (the bug)", got == [], got)
said = run("for _, l in ipairs(LOGS) do if l:find('never came', 1, true) then return true end end return false")
check("... and now said in the log", said)

run = runtime()
got = scenario(run, cost_first=True)
check("now, the cost before the replay: the difference booked (-15584)", got == [-15584], got)

run = runtime()
got = scenario(run, cost_first=False)
check("the usual order (replay, then cost): booked as before", got == [-15584], got)

run = runtime(off=True)
got = scenario(run, cost_first=False)
check("the usual order with the switch off: the same", got == [-15584], got)

# bounds
run = runtime()
run("for i = 1, 80 do HANDLE('replay_cost_set', { uid = 'x:' .. i, cost = i }, ST) end")
n = run("local n = 0 for _ in pairs(ST.rcostEarly) do n = n + 1 end return n")
check("at most 64 kept", n == 64, n)
run("NOW = NOW + 601 * STEP; HANDLE('replay_cost_set', { uid = 'y:1', cost = 1 }, ST)")
n = run("local n = 0 for _ in pairs(ST.rcostEarly) do n = n + 1 end return n")
check("dropped after 600 steps", n == 1, n)
run("HANDLE('replay_cost', { uid = 'y:1', cost = 77, co = 3 }, ST)")
check("a replay with its own cost keeps it", run("return ST.rcost[#ST.rcost].cost") == 77)
# (the review: a uid that comes back after a load, with another copy's time, never takes the old cost; nor one older than 600 steps)
run = runtime()
run("HANDLE('replay_cost_set', { uid = 'b#3:98', cost = 5000, at = 100 }, ST)")
run("HANDLE('replay_cost', { uid = 'b#3:98', co = 3, late = true, at = 900000 }, ST)")
check("(review) the same uid, another copy's time: the old cost not taken", run("return ST.rcost[#ST.rcost].cost") is None)
run = runtime()
run("HANDLE('replay_cost_set', { uid = 'b#3:99', cost = 5000, at = 200 }, ST)")
run("NOW = NOW + 601 * STEP; HANDLE('replay_cost', { uid = 'b#3:99', co = 3, late = true, at = 200 }, ST)")
check("(review) a cost kept more than 600 steps: not taken", run("return ST.rcost[#ST.rcost].cost") is None)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
