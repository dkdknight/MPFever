"""Offline test of the builds and actions left out after a load (0.6.10, G.staleDrop in the bridge).

AMD and keviK's session of 2026-11-02: a minute after resynchronisation 4, the host's game saved "MPFever resync" and loaded it
again by itself (a quick save and load: no order from MPFever). Starting over, the bridge took it for resynchronisation 4's load and
read every message since that load: keviK's join and 3 roads, already in the savegame, were applied a second time, late ("LATE
native build keviK#1:2 for t=7544000 applied at 7561600", "every form refused"), and resynchronisation 5 followed. The first read
of in.log after a load now leaves out a build ("act", "nat_pending") stamped before the time of the savegame loaded. G.staleDrop
is taken from the real bridge and run through lupa (Lua 5.2). Cases:
  - an action or announced build stamped before the savegame's time: left out, logged;
  - stamped at that time or later (a normal resynchronisation's messages during the load): kept;
  - other kinds of messages (session, peerclock, hash...) and messages without a time: kept;
  - the reading of in.log calls it only on the first read after a load, and MPFEVER_STALEDROP=0 never sets it.
Run: python tests/test_staledrop.py
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
    src = open(BRIDGE, encoding="utf-8").read()
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

    T = 7561200
    check("keviK's road stamped t=7544000, savegame at 7561200: left out",
          run(f"return G.staleDrop('act', {{ uid = 'keviK#1:2', origin = 'keviK#1', at = 7544000, native = true }}, {T})") is True)
    check("and logged", "left out" in str(run("return LOG[#LOG]")) and "keviK#1:2" in str(run("return LOG[#LOG]")))
    check("its announcement (nat_pending) too",
          run(f"return G.staleDrop('nat_pending', {{ id = 145, origin = 'keviK#1', at = 7543600 }}, {T})") is True)
    check("keviK's join stamped t=7473200: left out",
          run(f"return G.staleDrop('act', {{ fn = 'mpfCoJoin', origin = 'keviK#1', at = 7473200 }}, {T})") is True)
    check("stamped at the savegame's time: kept (a normal resynchronisation)",
          run(f"return G.staleDrop('act', {{ origin = 'AMD', at = {T} }}, {T})") is False)
    check("the host's join after resynchronisation 4's load (t=7473200, savegame 7472400): kept",
          run("return G.staleDrop('act', { fn = 'mpfCoJoin', origin = 'AMD', at = 7473200 }, 7472400)") is False)
    check("other kinds: kept", run(f"return G.staleDrop('session', {{ at = 1 }}, {T})") is False
          and run(f"return G.staleDrop('peerclock', {{ t = 1 }}, {T})") is False)
    check("no time: kept", run(f"return G.staleDrop('act', {{ uid = 'x' }}, {T})") is False)
    check("counted", run("return G.staleDropped") == 3)

    check("the reading of in.log asks it only on the first read after the load",
          "G.staleNow, G.staleBefore = G.staleBefore, nil" in src
          and "if G.staleNow and G.staleDrop(kind, payload, G.staleNow) then h = nil end" in src
          and re.search(r"G\.staleDrop\(kind, payload, G\.staleNow\).*?G\.staleNow(?:, G\.staleLid)? = nil(?:, nil)?", src, re.S) is not None)
    check("set after the messages received during the load, unless MPFEVER_STALEDROP=0",
          re.search(r'bytes of messages received during the load are read.*?if os\.getenv\("MPFEVER_STALEDROP"\) ~= "0" then.*?G\.staleBefore = tL',
                    src, re.S) is not None)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
