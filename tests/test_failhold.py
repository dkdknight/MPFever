"""Offline test of the guard after a build this game could not reproduce (0.6.7, issue #113).

HolderLord's game rebuilt a station extension without its two signals and asked for a resynchronisation; a second later it
applied the host's next build on that state and the engine asserted. A player's game that sent replay_failed now leaves out
the others' builds (G.brokenSkip) until the host's game reloads it, at most G.BROKEN_HOLD seconds.

replayFailed and G.brokenSkip are taken from the real bridge file and run through lupa (Lua 5.2) with mocks. Cases:
  - a player's game: after replay_failed, the next build is left out (logged), a company join is not;
  - after G.BROKEN_HOLD seconds without a resynchronisation, builds are applied again;
  - the host's game: never left out (its game is the one reloaded everywhere);
  - MPFEVER_FAILHOLD=0: never left out, as before.
Run: python tests/test_failhold.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
CLOCK = 100
os.clock = function() return CLOCK end
LOGS, SENT = {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function send(kind, p) SENT[#SENT + 1] = kind end
G = {}
C = { ROLE = "client" }
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m1 = re.search(r"^local function replayFailed\(a, why\)\n.*?^end\n", src, re.S | re.M)
    m2 = re.search(r"^G\.BROKEN_HOLD = .*?^function G\.brokenSkip\(a\)\n.*?^end\n", src, re.S | re.M)
    check("functions found in the bridge", m1 is not None and m2 is not None)
    if not (m1 and m2):
        sys.exit(1)
    check("the dispatch asks G.brokenSkip", "local skip = G.brokenSkip(a) or G.lateSkip(a, now)" in src)

    def run(role, env=None):
        L = lupa.LuaRuntime()
        L.execute(MOCK)
        L.execute(m1.group(0) + "\nREPLAYFAILED = replayFailed\n" + m2.group(0))
        L.execute('C.ROLE = "%s"' % role)
        for k, v in (env or {}).items():
            L.execute('ENV["%s"] = "%s"' % (k, v))
        return L

    L = run("client")
    skip = L.eval('function(fn) return G.brokenSkip({ uid = "Dimi:103", fn = fn }) end')
    check("client, before any failure: built", skip("makeWorldBuildProposalCmd") is False)
    L.execute('REPLAYFAILED({ uid = "Dimi:102" }, "construction edge objects (airport signs)")')
    check("client: replay_failed still sent", L.eval('SENT[1]') == "replay_failed")
    check("client, after the failure: left out", skip("makeWorldBuildProposalCmd") is True)
    check("client: logged with the failed build", "differs since Dimi:102" in (L.eval('LOGS[#LOGS]') or ""), L.eval('LOGS[#LOGS]'))
    check("client: a company join is not left out", skip("mpfCoJoin") is False)
    L.execute('REPLAYFAILED({ uid = "Dimi:104" }, "other")')
    check("client: the first failure is kept", L.eval('G.replayBroken.uid') == "Dimi:102")
    L.execute('CLOCK = CLOCK + G.BROKEN_HOLD + 1')
    check("client, no resync after the hold: built again", skip("makeWorldBuildProposalCmd") is False)
    check("client: the hold is over", L.eval('G.replayBroken') is None)

    L = run("host")
    L.execute('REPLAYFAILED({ uid = "Knight:5" }, "x")')
    check("host: never left out", L.eval('G.brokenSkip({ uid = "Knight:6", fn = "makeWorldBuildProposalCmd" })') is False)

    L = run("client", {"MPFEVER_FAILHOLD": "0"})
    L.execute('REPLAYFAILED({ uid = "Dimi:102" }, "x")')
    check("MPFEVER_FAILHOLD=0: built as before", L.eval('G.brokenSkip({ uid = "Dimi:103", fn = "makeWorldBuildProposalCmd" })') is False)

    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    sys.exit(1 if fails else 0)


main()
