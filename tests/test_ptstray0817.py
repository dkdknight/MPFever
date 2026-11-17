"""Offline test (0.8.17, #405): a build that has a turn of a pause but is applied as an ordinary build has its turn passed over,
not waited for (G.ptStray, G.ptTicket and the native replays' queue in mpfever_bridge.script.lua, switch MPFEVER_PTSTRAY).

Flubi's game (host) and lulei's, 2026-11-16 21:11: lulei's bulldozer (native build 138) made as a short pause began took turn 3;
released at its turn it landed 2 steps late, after the pause, and was shipped as an ordinary build (lulei#1:58). The host applied it
as one: turn 3 never done there. At 21:23 the next pause's turns 4 and 5 (lulei's line edits) waited for it: the host stood 60 s,
then "paused build turn 3 never applied here in 30 s: skipped (desync risk)".
G.ptTicket, G.ptStray, G.ptMayGo, G.ptDone, G.ptKey and G.ptAdvance are taken from the real bridge and run through lupa:
  - MPFEVER_PTSTRAY=0: turn 4 waits for turn 3 (the bug, reproduced: 30 s, then skipped);
  - now: lulei#1:58 (natId 138) applied as an ordinary build passes turn 3 over: turns 4 and 5 go at once;
  - a turn given after its build was applied as an ordinary one: passed over too;
  - a turn already done, or another player's build of the same number: nothing changes.
Needs lupa. Run: python tests/test_ptstray0817.py
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


parts = []
for pat in (r"^G\.pt = \{.*?\n", r"^G\.ptKey = function.*?\n", r"^G\.ptTicket = function\(origin, id, seq\)\n.*?^end\n",
            r"^G\.ptStrayOn = function.*?\n", r"^G\.ptStray = function\(origin, natId\)\n.*?^end\n",
            r"^G\.ptAdvance = function\(\)\n.*?^end\n", r"^G\.ptMayGo = function\(seq\)\n.*?^end\n", r"^G\.ptDone = function\(seq\)\n.*?^end\n"):
    m = re.search(pat, src, re.S | re.M)
    check("found: " + pat[:24], m is not None)
    if m:
        parts.append(m.group(0))
q = src[src.index("local function runNativeReplays()"):]
q = q[:q.index("\nend\n")]
check("the replays' queue passes a stray turn over", "if not seq and a.natId ~= nil and a.fn ~= \"mpfCoJoin\" then pcall(G.ptStray, a.origin, a.natId) end" in q)
if fails:
    sys.exit(1)


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nLOGS = {}\nfunction log(s) LOGS[#LOGS + 1] = s end\nG = { frames = 1000 }\n" + "\n".join(parts))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_PTSTRAY = '0'")
    # the tickets after resynchronisation 2: the two joins, then lulei's build 138 of the short pause
    run("G.ptTicket('lulei#1', 'co1', 1); G.ptTicket('Flubi', 'co1', 2); G.ptTicket('lulei#1', 138, 3); G.ptDone(1); G.ptDone(2)")
    return run


run = runtime(off=True)
run("if G.ptStray then G.ptStray('lulei#1', 138) end")      # (does nothing with the switch off)
run("G.ptTicket('lulei#1', 'a115@5530000', 4); G.ptTicket('lulei#1', 'a116@5530000', 5)")
check("MPFEVER_PTSTRAY=0: turn 4 waits for turn 3 (the bug)", run("return G.ptMayGo(4)") is False)
run("G.frames = G.frames + 1801")
check("  ... 30 s, then turn 3 skipped (desync risk)", run("return G.ptMayGo(4)") is True and "never applied here in 30 s" in (run("return LOGS[#LOGS]") or ""))

run = runtime()
run("G.ptStray('lulei#1', 138)")                              # lulei#1:58 (natId 138) applied as an ordinary build
run("G.ptTicket('lulei#1', 'a115@5530000', 4); G.ptTicket('lulei#1', 'a116@5530000', 5)")
check("now: lulei#1:58 applied as an ordinary build passes turn 3 over: turn 4 goes at once", run("return G.ptMayGo(4)") is True)
run("G.ptDone(4)")
check("  and turn 5 after it", run("return G.ptMayGo(5)") is True)

run = runtime()
run("G.pt.of = {}; G.ptStray('lulei#1', 140)")               # applied first, its turn given after
run("G.ptTicket('lulei#1', 140, 3); G.ptTicket('lulei#1', 'a1', 4)")
check("a turn given after its build was applied as an ordinary one: passed over", run("return G.ptMayGo(4)") is True)

run = runtime()
run("G.ptDone(3); G.ptStray('lulei#1', 138)")
check("a turn already done: nothing changes", run("return next(G.pt.skip) == nil"))
run = runtime()
run("G.ptStray('Flubi', 138)")
check("another player's build of the same number: nothing changes (turn 3 still waited for)", run("return G.ptMayGo(4)") is False)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
