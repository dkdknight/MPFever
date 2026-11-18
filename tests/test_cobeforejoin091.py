"""Offline test: a client's actions are refused until its company is known here (0.9.0, MPFEVER_COBEFOREJOIN).

Test X1 (2026-11-18, "Test Mix 18", separate companies + 3 computer companies, scenario pmix,soak): the host corrected the client's
money at every other check, 38 times in 10 minutes (15,000, then 616 again and again), the same in X0 with the 0.9.0 fixes off.
The client's first stop (DSTOP stop 1, autotest build 100001) was made at 12:13:56, before its company's join (12:13:59, seen by its
interface at 12:14:00): the native module still made its tools act as the savegame's company, the host's. The stop was built there
for company 1 ("capture: owner references: company 1 x2") and shipped as the client's (co = G.myCo, 2 by then): the host booked its
15,000 and its upkeep to company 2, the client's game to company 1. In the run where the stop came after the join ("company 1 x1,
company 2 x1"), no correction at all.
The fix refuses a client's actions (tool builds, scripted builds, the interface's commands: G.resyncRefuse) while its company is
not known here (G.coUnknownHere); the autotest's dstop waits for the company.
The functions are taken from the real bridge and run through lupa (Lua 5.2).
Run: python tests/test_cobeforejoin091.py
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


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def func(src, head):
    i = src.index(head)
    j = src.index("\nend\n", i)
    return src[i:j + 5]


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    unknown = func(src, "G.coUnknownHere = function()")
    refuse = func(src, "G.resyncRefuse = function(what)")
    check("G.resyncRefuse asks G.coUnknownHere (tool builds, scripted builds, the interface's commands go through it)",
          "if G.coUnknownHere() then" in refuse)
    check("the tool's held build and the autotest's build are refused by it",
          'if id and G.resyncRefuse("native build " .. id) then' in src and 'if G.resyncRefuse("autotest build") then' in src)
    dstop = src[src.index("H.dstop = function(from, p)"):]
    dstop = dstop[:dstop.index("AUTO.running = true")]
    check("the autotest's dstop waits for this game's company before it starts (every 30 frames, a minute at most)",
          "if G.coUnknownHere() and (p.coWaits or 0) < 120 then" in dstop and "G.frames + 30" in dstop)

    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run("""
ENV = {}
os = { getenv = function(k) return ENV[k] end }
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
SENT = {}
send = function(k, p) SENT[#SENT + 1] = k end
pcall = pcall
G = { frames = 1000, cmode = "separate", session = { started = true }, myEnt = nil }
C = { ROLE = "client", T = function(fr, en) return en end }
CHAT = {}
G.featChat = function(t) CHAT[#CHAT + 1] = t end
""")
    run(unknown.replace("G.coUnknownHere = function()", "G.coUnknownHere = function()", 1))
    run(refuse)

    # the bug: before the fix, nothing stops the client's first stop while its company is not known here
    run("ENV.MPFEVER_COBEFOREJOIN = '1'")
    check("before (MPFEVER_COBEFOREJOIN=1): the client's stop made before its join goes through (built for the host's company)",
          run("return G.resyncRefuse('autotest build')") is False)
    run("ENV.MPFEVER_COBEFOREJOIN = nil")
    check("after: refused while this game's company is not known", run("return G.resyncRefuse('autotest build')") is True)
    check("  logged once per 5 s", run("G.resyncRefuse('native build 7'); return #LOG") == 1 and run("return G.coUnknownRefused") == 2)
    check("  the player told once in the chat (try again in a few seconds)", run("return #CHAT") == 1 and "not ready yet" in str(run("return CHAT[1]")))
    run("G.myEnt = 206551")
    check("its company known (the interface acts as it): allowed", run("return G.resyncRefuse('autotest build')") is False)
    run("G.myEnt = nil; C.ROLE = 'host'")
    check("the host (the savegame's company is its own): allowed", run("return G.resyncRefuse('autotest build')") is False)
    run("C.ROLE = 'client'; G.cmode = 'shared'")
    check("one company for everybody: allowed", run("return G.resyncRefuse('autotest build')") is False)
    run("G.cmode = 'separate'; G.session.started = false")
    check("no session yet: allowed (alone, the game as it is)", run("return G.resyncRefuse('autotest build')") is False)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
