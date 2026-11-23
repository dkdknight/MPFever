"""Offline test of #470 (0.9.6, mod/mpfever_1/content/mpfever_bridge.script.lua DET.random with an event's context,
DET.wrapEventDraws, DET.inCtx; switch MPFEVER_DETEVENT).

#470 (Hansen's session, 2026-11-21, 0.9.5, one company for everybody): ChristianHansen took loans in a pause (Obtain, Repay,
Obtain at one game time); the loans' state (script:loan) differed and the games reloaded, twice. Reproduced in game on 2026-11-23
by the autotest loanseq (MPFEVER_PAUSED=1, then soak): script:loan apart, 22 checks. The game's loan script draws a loan's delay
in the callback of the journal command its Obtain event sends; the simulation runs in two Lua states, taken in turn from one batch
to the next, each with its own counts of draws, and in a pause the game time stays the same: the second loan's delay was the
place's first draw on one game (both delays 96789070 on the host) and its second on the other (96538587 on the client). Now the
draws of that script's event and of its commands' callbacks are counted from the event alone.

The model: the real installRandom/DET code in two Lua states per game; the loan script's Obtain as the game writes it (a
journal command whose callback draws cooldownUntil). Game A handles both Obtains in one state, game B in its two states.
Needs lupa (pip install lupa). Run: python tests/test_detevent096.py
"""
import os
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = bridge.index("local DET = {}\nlocal function installRandom()")
b = bridge.index("-- (0.7.13, #172, the review of the night's fix) game_time.gs's answer")
block = bridge[a:b]

PRE = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGGED = {}
function log(s) LOGGED[#LOGGED + 1] = s end
T = 96007600
function gameTime() return T end
C = { ACTIVE = true }
DEFERRED = {}
api = { cmd = {} }
-- the engine: a command's callback comes later (as in the game), when FLUSH() runs
api.cmd.sendCommand = function(cmd, cb) if cb then DEFERRED[#DEFERRED + 1] = cb end end
api.cmd.makeJournalBookAssetCmd = function() return {} end
game = {}
'''

# the game's loan script (finance/loan.script.tl), Obtain only, with its draw in the callback
LOAN = r'''
local loanScript = {
  handleEvent = function(u, state, src, id, name, loans)
    if id == "Loan" and name == "Obtain" then
      local tbl = state.tbl
      api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(), function(data, success)
        tbl.cooldowns[#tbl.cooldowns + 1] = gameTime() + math.random(2629800 * 4, 2629800 * 8)
      end)
    end
  end,
}
return loanScript
'''

POST = r'''
DETG = DET
installRandom()
game["::/game_mechanics/finance/loan.script"] = assert(load(LOANSRC, "=loan.script.lua"))()
DET.wrapEventDraws()
STATE = { tbl = { cooldowns = {} } }
function OBTAIN() game["::/game_mechanics/finance/loan.script"].handleEvent({}, STATE, "", "Loan", "Obtain", {}) end
function FLUSH() local l = DEFERRED; DEFERRED = {}; for _, cb in ipairs(l) do cb({}, true) end end
function LAST() return STATE.tbl.cooldowns[#STATE.tbl.cooldowns] end
'''


def state(on):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.globals().LOANSRC = LOAN
    L.execute(PRE)
    if not on:
        L.execute('ENV.MPFEVER_DETEVENT = "0"')
    L.execute(block + POST)
    return L


def game_draws(on, same_state):
    """Two Obtains at one game time (a pause): their delays as this game draws them."""
    X, Y = state(on), state(on)
    X.eval("OBTAIN()")
    X.eval("FLUSH()")
    d1 = X.eval("LAST()")
    second = X if same_state else Y
    second.eval("OBTAIN()")
    second.eval("FLUSH()")
    return d1, second.eval("LAST()")


# ---- repro: as before, game A (both in one state) and game B (one in each) draw the second delay differently
a1, a2 = game_draws(False, True)
b1, b2 = game_draws(False, False)
check(a1 == b1, "as before: the first loan's delay alike", f"{a1} {b1}")
check(a2 != b2, "repro #470: the second loan's delay differs between the two games (its place's 2nd draw on one, 1st on the other)", f"{a2} {b2}")
check(b1 == b2, "  on game B both delays are the same draw, as the host's 96789070 twice in the autotest", f"{b1} {b2}")

# ---- fix
a1, a2 = game_draws(True, True)
b1, b2 = game_draws(True, False)
check(a1 == b1 and a2 == b2, "fix: both games draw both delays alike, whatever state runs them", f"A {a1} {a2} / B {b1} {b2}")
lo, hi = 96007600 + 2629800 * 4, 96007600 + 2629800 * 8
check(lo <= a2 <= hi and lo <= a1 <= hi, "  the delays stay 4 to 8 months", f"{a1} {a2}")

# the wrapper keeps the game's own sendCommand afterwards and says what it did
L = state(True)
check(L.eval("api.cmd.sendCommand ~= nil") and L.eval("#DEFERRED") == 0, "the game's sendCommand given back after the event")
L.execute("SC0 = api.cmd.sendCommand")
L.eval("OBTAIN()")
check(L.eval("api.cmd.sendCommand == SC0"), "  the same function as before the event")
check(any("counted from each event" in str(L.eval(f"LOGGED[{i}]")) for i in range(1, L.eval("#LOGGED") + 1)), "  logged once per state")
L.execute("DETG.wrapEventDraws()")
check(sum("counted from each event" in str(L.eval(f"LOGGED[{i}]")) for i in range(1, L.eval("#LOGGED") + 1)) == 1, "  wrapped once per state")
# an error in the event still comes out, and the context is left
L.execute('''game["::/game_mechanics/finance/loan.script"].__boom = true''')
L.execute('''
local s = game["::/game_mechanics/finance/loan.script"]
local h = s.handleEvent
ERR = select(2, pcall(function() DETG.inCtx("x", function() error("boom") end) end))
''')
check("boom" in str(L.eval("ERR")) and L.eval("DETG.ctxCounts") is None, "an error inside the context comes out, the context left")
# outside any event: the place's counts as before
check(L.eval("DETG.ctxCounts") is None, "outside an event: the counts per place, as before")

# the sources
check("DET.EVENT_SCRIPTS = { [\"::/game_mechanics/finance/loan.script\"] = true }" in bridge, "only the game's loan script")
check('os.getenv("MPFEVER_DETEVENT") == "0"' in bridge, "switch MPFEVER_DETEVENT=0")
check("pcall(DET.wrapModEvents); pcall(DET.wrapEventDraws)" in bridge, "installed with the other wrappers of the game's scripts, in every simulation state")
check("H.loanseq = function(from, p)" in bridge, "the autotest loanseq that reproduced it is in the bridge")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
