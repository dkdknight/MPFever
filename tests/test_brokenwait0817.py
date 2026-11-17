"""Offline test (0.8.17, #400): after an action this game could not apply, another player's build waits for the launcher's word
(refused everywhere, or a resynchronisation) instead of being left out (G.brokenWait, runNativeReplays and nativeHoldAt in
mpfever_bridge.script.lua, switch MPFEVER_BROKENWAIT).

A refusal makes a player's game leave the others' next builds out (G.brokenSkip, 0.6.7, #113: applied on a game that differs,
one crashed it), until the host's game reloads it. But since 0.7.7 the launcher may answer "refused on every game" (replay_alike:
nothing differs, no reload): the builds left out meanwhile were lost on that game only. Bence's second sale of the same vehicles
(#400, refused by every game) made YkeWoudstra's and Bence's games leave out what came in those seconds; with the launcher now
waiting up to 20 s for the reports (test_failclock0817.py), more would be lost.
replayFailed, G.brokenWait, G.brokenSkip and H.replay_alike are taken from the real bridge and run through lupa:
  - MPFEVER_BROKENWAIT=0: yoyo:41 left out, then "refused everywhere": never built here (the bug, reproduced);
  - now: yoyo:41 waits (kept in the queue, the game holding), then "refused everywhere": built at its step;
  - a resynchronisation instead: the wait ends with the reload (nothing applied on the differing game, as before);
  - no word within 25 s: left out as before; a company join never waits; the host's game never waits.
Needs lupa. Run: python tests/test_brokenwait0817.py
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


m1 = re.search(r"^local function replayFailed\(a, why\)\n.*?^end\n", src, re.S | re.M)
m2 = re.search(r"^G\.BROKEN_HOLD = .*?^function G\.brokenSkip\(a\)\n.*?^end\n", src, re.S | re.M)
m3 = re.search(r"^G\.brokenWaitOn = .*?^G\.brokenWait = function\(a\)\n.*?^end\n", src, re.S | re.M)
m4 = re.search(r"^H\.replay_alike = function\(from, p\)\n.*?^end\n", src, re.S | re.M)
check("the functions found", all((m1, m2, m3, m4)))
if not all((m1, m2, m3, m4)):
    sys.exit(1)
rq = src[src.index("local function runNativeReplays()"):]
rq = rq[:rq.index("\nend\n")]
check("the replays' queue keeps a build that waits for the word, before sending it",
      "elseif due and G.brokenWait(a) then" in rq and rq.index("elseif due and G.brokenWait(a) then") < rq.index("\t\telseif due then\n"))
hold = src[src.index("local function nativeHoldAt()"):]
hold = hold[:hold.index("\nend\n")]
check("the game holds where it is meanwhile", "if G.replayBroken and G.brokenHolding and G.frames - G.brokenHolding <= 2 then return now end" in hold)

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
CLOCK = 100
os.clock = function() return CLOCK end
LOGS, SENT = {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function send(kind, p) SENT[#SENT + 1] = kind end
G = { frames = 500 }
H = {}
C = { ROLE = "client" }
'''


def runtime(role="client", off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    if off:
        L.execute("ENV.MPFEVER_BROKENWAIT = '0'")
    L.execute(m1.group(0) + "\nREPLAYFAILED = replayFailed\n" + m2.group(0) + m3.group(0) + m4.group(0))
    L.execute('C.ROLE = "%s"' % role)
    # one frame of the queue for the build yoyo:41: waits, left out, or built (the order of runNativeReplays)
    L.execute('''function FRAME(a)
  G.frames = G.frames + 1
  if G.brokenWait(a) then return "waits" end
  if G.brokenSkip(a) then return "left out" end
  return "built"
end''')
    return L, L.eval("function(code) return assert(load(code))() end")


Y41 = "{ uid = 'yoyo:41', fn = 'makeWorldBuildProposalCmd', native = true, at = 32719000 }"

L, run = runtime(off=True)
run("REPLAYFAILED({ uid = 'Bence#6:6', at = 32718200 }, 'DESYNC unresolved: veh#125017')")
got = run("return FRAME(%s)" % Y41)
run("H.replay_alike('host', { uid = 'Bence#6:6' })")
check("MPFEVER_BROKENWAIT=0: yoyo:41 left out, then refused everywhere: never built on this game (the bug)", got == "left out", got)

L, run = runtime()
run("REPLAYFAILED({ uid = 'Bence#6:6', at = 32718200 }, 'DESYNC unresolved: veh#125017')")
f1 = run("return FRAME(%s)" % Y41)
run("CLOCK = CLOCK + 6")
f2 = run("return FRAME(%s)" % Y41)
check("now: yoyo:41 waits for the launcher's word (6 s later still)", f1 == "waits" and f2 == "waits", (f1, f2))
check("  the game holds meanwhile", run("return G.brokenHolding == G.frames"))
run("H.replay_alike('host', { uid = 'Bence#6:6' })")
f3 = run("return FRAME(%s)" % Y41)
check("  refused everywhere: built (at its step: the game held there)", f3 == "built", f3)

L, run = runtime()
run("REPLAYFAILED({ uid = 'Bence#6:6', at = 32718200 }, 'x')")
check("a company join never waits", run("return FRAME({ uid = 'Eric:1', fn = 'mpfCoJoin' })") == "built")
run("CLOCK = CLOCK + 26")
check("no word within 25 s: left out as before", run("return FRAME(%s)" % Y41) == "left out")

L, run = runtime(role="host")
run("REPLAYFAILED({ uid = 'Bence#6:6', at = 32718200 }, 'x')")
check("the host's game never waits", run("return FRAME(%s)" % Y41) == "built")

L, run = runtime()
run("G.session = { resync = false }; REPLAYFAILED({ uid = 'Bence#6:6', at = 32718200 }, 'x')")
check("(review) waiting while no word yet", run("return FRAME(%s)" % Y41) == "waits")
run("G.session.resync = true")
check("(review) the word is a resynchronisation: left out at once, the game goes on to its pause", run("return FRAME(%s)" % Y41) == "left out")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
