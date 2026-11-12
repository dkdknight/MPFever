"""Offline test: a player's first load in a session leaves out the builds already in the savegame (0.8.3, MPFEVER_STALEJOIN).

Report #225 (2026-11-11, dedicated server, Knight-HD and LauchusMaximus, separate companies): LauchusMaximus joined, the host
saved resynchronisation 3 at t=72953000. His game started from the main menu (a game of its own: started.txt empty) and read
everything his launcher had received since he joined, so it built Knight-HD#2:64 (13 streets, stamped 72943400) "48 step(s) late"
and Knight-HD#2:65 (a street, stamped 72953000 and built by the host before it saved) a second time: 14 segments with new entity
ids on his game only. The 0.8.2 drift diagnostic showed his free-id queue apart from his very first step (364765), then the
people, the vehicles and the ages differed, and resynchronisation 4 followed.
G.staleDrop (0.6.10) only ran after a resynchronisation's load over an existing session. Now the first load in a session also sets
it, and a build stamped at the savegame's very time is left out when its builder made it before that resynchronisation's load (its
lt is older) and not in the pause after it; the hold announced for it goes too. G.staleDrop is taken from the real bridge and run
through lupa (Lua 5.2).
Run: python tests/test_stalejoin083.py
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


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"^G\.staleDrop = function\(kind, p, before\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: G.staleDrop not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
G = {}
""" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")

    T = 72953000
    # the first load in the session: resynchronisation 3, the holds announced before it
    run(f"""G.staleLid = 3
G.natWait = {{ {{ origin = 'Knight-HD#2', id = 97, at = {T} }}, {{ origin = 'MPFeverOpenforall', id = 5, at = {T} }} }}""")
    check("Knight-HD#2:64, stamped 72943400 (before the savegame): left out",
          run("return G.staleDrop('act', { uid = 'Knight-HD#2:64', origin = 'Knight-HD#2', at = 72943400, native = true, natId = 96, lt = 2 }, %d)" % T) is True)
    check("its announcement (BUILDLEAD, nat_pending at 72942600): left out",
          run("return G.staleDrop('nat_pending', { id = 96, origin = 'Knight-HD#2', at = 72942600, lead = true }, %d)" % T) is True)
    check("the server's scripting event stamped 72945200: left out",
          run("return G.staleDrop('act', { uid = 'MPFeverOpenforall:80', origin = 'MPFeverOpenforall', at = 72945200, fn = 'makeScriptingSendEventCmd' }, %d)" % T) is True)
    check("Knight-HD#2:65 at the savegame's time, made before resynchronisation 3's load (lt 2): left out",
          run("return G.staleDrop('act', { uid = 'Knight-HD#2:65', origin = 'Knight-HD#2', at = %d, native = true, natId = 97, lt = 2, pre = true }, %d)" % (T, T)) is True)
    check("  and its hold (nat_pending 97) goes with it, the other builder's stays",
          run("return #G.natWait") == 1 and run("return G.natWait[1].origin") == "MPFeverOpenforall")
    check("the joins in the pause after the load (paused, at the savegame's time): kept",
          run("return G.staleDrop('act', { uid = 'Knight-HD#2:1', fn = 'mpfCoJoin', origin = 'Knight-HD#2', at = %d, paused = true, native = true }, %d)" % (T, T)) is False)
    check("a build made after this resynchronisation's load (lt 3): kept",
          run("return G.staleDrop('act', { uid = 'Knight-HD#2:66', origin = 'Knight-HD#2', at = %d, native = true, lt = 3 }, %d)" % (T, T)) is False)
    check("a build of no lt at that time: kept",
          run("return G.staleDrop('act', { uid = 'x', origin = 'MPFeverOpenforall', at = %d }, %d)" % (T, T)) is False)
    check("later than the savegame: kept",
          run("return G.staleDrop('act', { uid = 'y', origin = 'Knight-HD#2', at = %d, lt = 2 }, %d)" % (T + 200, T)) is False)
    # after a resynchronisation's load over an existing session (no G.staleLid): as in 0.6.10, the savegame's time is kept
    run("G.staleLid = nil")
    check("over an existing session, stamped at the savegame's time: kept as before",
          run("return G.staleDrop('act', { uid = 'z', origin = 'Knight-HD#2', at = %d, lt = 2 }, %d)" % (T, T)) is False)

    fresh = src[src.index('if fileSize("started.txt") == 0 then'):]
    fresh = fresh[:fresh.index("\n\t\treturn\n")]
    check("the first load in a session sets it (MPFEVER_STALEJOIN=0 or MPFEVER_STALEDROP=0: as before)",
          'os.getenv("MPFEVER_STALEJOIN") ~= "0"' in fresh and 'os.getenv("MPFEVER_STALEDROP") ~= "0"' in fresh
          and "G.staleBefore, G.staleLid = G.loadT, G.loadId" in fresh)
    check("  only for a load ordered by MPFever (its resynchronisation's number)", "if G.loadId and " in fresh)
    check("  for the first read of in.log only", "G.staleNow, G.staleLid = nil, nil" in src
          and "G.staleNow, G.staleBefore = G.staleBefore, nil" in src)
    check("  G.loadT is read before", src.index("pcall(function() G.loadT = gameTime() end)") < src.index('if fileSize("started.txt") == 0 then'))

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
