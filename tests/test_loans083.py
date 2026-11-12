"""Offline test: loans between companies (0.8.3, Zoey's suggestion and the owner's rules, mpfever_eco.lua: E.loanEvent, E.loanMonth,
MPFEVER_LOANS).

The owner's rules (2026-11-12): the BORROWER asks (the amount, over how many months, the interest it offers); the lender may
make a counter-offer, and so on in turn. Here: in % of the amount for the whole loan, paid back in equal parts at each new month of
the game (co_month, every game at the same step). Chiefs only; the lender must have the money; a borrower gone bankrupt: the
lender loses the rest; a lender gone: the borrower keeps it. mpfever_co.lua and mpfever_eco.lua run through lupa (Lua 5.2) with a
mocked engine (balances booked by makeJournalBookAssetCmd).
Run: python tests/test_loans083.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content")

MOCK = r'''
ENVOVR = {}
do
  local og = os.getenv
  os.getenv = function(k) local v = ENVOVR[k] if v ~= nil then return v end return og(k) end
end
TIME = 0
BAL = {}
api = {
  type = { JournalEntry = { new = function() return { category = {} } end, Type = { OTHER = 1 } }, Vec3f = { new = function() return {} end },
    ComponentType = { PLAYER_OWNED = "po", NAME = "name" } },
  util = { getDefaultMonthDuration = function() return 1000 end },
  cmd = { sendCommand = function() end, makeJournalBookAssetCmd = function(ent, e) BAL[ent] = (BAL[ent] or 0) + e.amount return {} end,
    makeEntitySetPlayerCmd = function() return {} end },
  engine = { getComponent = function() return nil end, entityExists = function() return false end,
    forEachEntityWithComponent = function() end,
    util = { finance = { getPlayersBalance = function(p) return BAL[p] or 0 end } }, system = {} },
}
R = { allEdges = function() return {} end, entitiesWith = function() return {} end, ownerOf = function() return nil end, sgKey = function(s) return "sg" .. s end,
  withoutAssets = function(l) return l end }
LOG = {}
ENV = { log = function(s) LOG[#LOG + 1] = s end, R = R, STEP = 200, gameTime = function() return TIME end, journalCarrier = function() return 1 end }
'''

fails = []


def check(cond, what, got=""):
    print(("  ok    " if cond else "  FAIL  ") + what + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(what)


def world(env=None):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    for k, v in (env or {}).items():
        L.execute('ENVOVR["%s"] = "%s"' % (k, v))
    CO = L.execute(open(os.path.join(here, "mpfever_co.lua"), encoding="utf-8").read())
    L.globals().CO = CO
    L.execute("ENV.CO = CO")
    E = L.execute(open(os.path.join(here, "mpfever_eco.lua"), encoding="utf-8").read())
    L.globals().E = E
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    run('''
st = { co = CO.new("separate", 100, 2000000) }
CO.join(st.co, "host", "Host", true, "Host Co", "s1", 1)
local b = CO.join(st.co, "bob", "Bob", false, "Bob Co", "s2", 2); b.ent = 200
CO.join(st.co, "carl", "Carl", false, "Bob Co", "s3", 2)
BAL[100] = 2000000; BAL[200] = 0
TIME = 0; E.tick(st, ENV)
function ev(name, p, from, co) p.mpfFrom = from; p.mpfCo = co; E.event(st, name, p, ENV) end
function month() TIME = TIME + 1000; E.tick(st, ENV); E.event(st, "co_month", { month = st.co.month, debt = {}, mpfFrom = "Host" }, ENV) end
function news() local n = st.co.news or {} return n[#n] and n[#n].kind or "" end
''')
    return L, run


L, run = world()
run("ev('co_loan_ask', { to = 1, amount = 1000000, months = 10, rate = 10 }, 'Bob#1', 2)")
check(run("return #st.co.loanOffers") == 1 and run("return st.co.loanOffers[1].turn") == "lender" and run("return news()") == "loan_ask",
      "the borrower's chief asks: an offer, the lender's turn, said in the chat")
run("ev('co_loan_answer', { id = st.co.loanOffers[1].id, accept = true }, 'Bob#1', 2)")
check(run("return #st.co.loans") == 0 and run("return #st.co.loanOffers") == 1, "the borrower cannot accept its own ask (not its turn)")
run("ev('co_loan_counter', { id = st.co.loanOffers[1].id, amount = 800000, months = 8, rate = 12 }, 'Host', 1)")
check(run("return st.co.loanOffers[1].amount") == 800000 and run("return st.co.loanOffers[1].turn") == "borrower" and run("return news()") == "loan_counter",
      "the lender's counter-offer: the new terms, the borrower's turn")
run("ev('co_loan_answer', { id = st.co.loanOffers[1].id, accept = true }, 'Carl#2', 2)")
check(run("return #st.co.loans") == 0, "a member that is not the chief cannot answer")
run("ev('co_loan_answer', { id = st.co.loanOffers[1].id, accept = true }, 'Bob#1', 2)")
check(run("return #st.co.loans") == 1 and run("return #st.co.loanOffers") == 0, "the borrower accepts the counter-offer: a loan")
check(run("return BAL[100]") == 1200000 and run("return BAL[200]") == 800000, "  the lender pays the amount at once", (run("return BAL[100]"), run("return BAL[200]")))
check(run("return st.co.loans[1].total") == 896000 and run("return st.co.loans[1].monthly") == 112000, "  896000 to pay back (12 %), 112000 a month")
run("month()")
check(run("return BAL[200]") == 688000 and run("return BAL[100]") == 1312000 and run("return st.co.loans[1].rest") == 784000, "a new month: one part paid back")
run("for i = 1, 7 do month() end")
check(run("return #st.co.loans") == 0 and run("return news()") == "loan_done", "after 8 months: paid back, the loan ends, said in the chat")
check(run("return BAL[100]") == 2096000 and run("return BAL[200]") == -96000, "  the lender has its interest, the borrower paid it (in debt)")
run("month()")
check(run("return BAL[100]") == 2096000, "  nothing more afterwards")

# the lender has not got the money
L, run = world()
run("ev('co_loan_ask', { to = 1, amount = 5000000, months = 5, rate = 0 }, 'Bob#1', 2)")
run("ev('co_loan_answer', { id = st.co.loanOffers[1].id, accept = true }, 'Host', 1)")
check(run("return #st.co.loans") == 0 and run("return news()") == "loan_nomoney" and run("return BAL[100]") == 2000000,
      "the lender has not got the amount: no loan, said, nothing booked")
# refused, withdrawn, terms
run("ev('co_loan_ask', { to = 1, amount = 100000, months = 5, rate = 5 }, 'Bob#1', 2)")
run("ev('co_loan_answer', { id = st.co.loanOffers[1].id, accept = false }, 'Host', 1)")
check(run("return #st.co.loanOffers") == 0 and run("return news()") == "loan_refused", "the lender refuses: no offer left, said")
run("ev('co_loan_ask', { to = 1, amount = 100000, months = 5, rate = 5 }, 'Bob#1', 2)")
run("ev('co_loan_cancel', { id = st.co.loanOffers[1].id }, 'Bob#1', 2)")
check(run("return #st.co.loanOffers") == 0, "the borrower withdraws its ask")
for terms, what in (("months = 0, rate = 5", "0 months"), ("months = 121, rate = 5", "121 months"), ("months = 5, rate = 101", "101 %"), ("months = 5, rate = -1", "-1 %")):
    run("ev('co_loan_ask', { to = 1, amount = 100000, %s }, 'Bob#1', 2)" % terms)
    check(run("return #(st.co.loanOffers or {})") == 0, "terms refused: " + what)
run("ev('co_loan_ask', { to = 2, amount = 100000, months = 5, rate = 5 }, 'Bob#1', 2)")
check(run("return #(st.co.loanOffers or {})") == 0, "a company cannot borrow from itself")

# a borrower gone bankrupt: the lender loses the rest
L, run = world()
run("ev('co_loan_ask', { to = 1, amount = 600000, months = 6, rate = 0 }, 'Bob#1', 2)")
run("ev('co_loan_answer', { id = st.co.loanOffers[1].id, accept = true }, 'Host', 1)")
run("month()")
run("CO.find(st.co, 2).gone = 'bankrupt'")
run("month()")
check(run("return #st.co.loans") == 0 and run("return news()") == "loan_lost" and run("return BAL[100]") == 1500000,
      "the borrower gone bankrupt: the loan ends, the lender loses the rest, said")

# MPFEVER_LOANS=0
L, run = world({"MPFEVER_LOANS": "0"})
run("ev('co_loan_ask', { to = 1, amount = 100000, months = 5, rate = 5 }, 'Bob#1', 2)")
check(run("return #(st.co.loanOffers or {})") == 0, "MPFEVER_LOANS=0: no loan asked")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
