"""Offline test (0.8.17, #407): a player's first load leaves out a build of the pause made before that load (G.staleDrop in
mpfever_bridge.script.lua, switch MPFEVER_STALEPAUSED).

Til, the host, put a signal as resynchronisation 2's pause began: Til:15, a build of that pause, stamped at its time t=86439200
(lt 1: made before that load); his game applied it, then saved at the same time. Eric, joining, read it and built it a second
time ("NATIVE REPLAY Til:15: paused build, turn 1", stops 554 -> 554, money -45 000): its new segment took the id the host had
given an animal, the ids stayed apart and the vehicles drifted (resynchronisation 3). G.staleDrop kept every build of a pause.
G.staleDrop is taken from the real bridge and run through lupa:
  - MPFEVER_STALEPAUSED=0: Til:15 kept (the bug, reproduced);
  - now: left out, its hold and its turn of the pause with it;
  - a join of the pause after the load (paused, at the savegame's time): kept, with or without an lt;
  - a build of the pause made after the load (lt of that load): kept;
  - a build of the pause stamped later than the savegame: kept.
Needs lupa. Run: python tests/test_stalepaused0817.py
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


m = re.search(r"^G\.staleDrop = function\(kind, p, before\)\n.*?^end\n", src, re.S | re.M)
check("G.staleDrop found", m is not None)
if not m:
    sys.exit(1)
T = 86439200


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {}
os = { getenv = function(k) return ENV[k] end }
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
G = { pt = { next = 2, done = 0, of = { ["Til:15"] = 1 }, skip = {} } }
G.ptKey = function(o, id) return tostring(o) .. ":" .. tostring(id) end
""" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_STALEPAUSED = '0'")
    # Eric's first load: resynchronisation 2's savegame, at T
    run(f"G.staleLid = 2; G.natWait = {{ {{ origin = 'Til', id = 15, at = {T} }} }}")
    return run


TIL15 = "{ uid = 'Til:15', origin = 'Til', at = %d, native = true, natId = 15, lt = 1, paused = true }" % T

run = runtime(off=True)
check("MPFEVER_STALEPAUSED=0: Til:15 (a build of the pause, made before the load) kept: built a second time (the bug)",
      run("return G.staleDrop('act', %s, %d)" % (TIL15, T)) is False)

run = runtime()
check("now: Til:15 left out (the savegame has it)", run("return G.staleDrop('act', %s, %d)" % (TIL15, T)) is True)
check("  its hold goes with it", run("return #G.natWait") == 0)
check("  and its turn of the pause is not waited for", run("return G.pt.skip[1] == true"))
check("  its announcement (nat_pending, paused, lt 1) left out too",
      run("return G.staleDrop('nat_pending', { id = 15, origin = 'Til', at = %d, lt = 1, paused = true }, %d)" % (T, T)) is True)
check("a join of the pause after the load: kept (no lt)",
      run("return G.staleDrop('act', { uid = 'Eric:1', fn = 'mpfCoJoin', origin = 'Eric', at = %d, paused = true, native = true }, %d)" % (T, T)) is False)
check("a join of the pause with an older lt: kept all the same",
      run("return G.staleDrop('act', { uid = 'Kai:1', fn = 'mpfCoJoin', origin = 'Kai', at = %d, paused = true, native = true, lt = 1 }, %d)" % (T, T)) is False)
check("a build of the pause made after the load (lt 2): kept",
      run("return G.staleDrop('act', { uid = 'Til:16', origin = 'Til', at = %d, native = true, natId = 16, lt = 2, paused = true }, %d)" % (T, T)) is False)
check("a build of the pause stamped after the savegame: kept",
      run("return G.staleDrop('act', { uid = 'Til:17', origin = 'Til', at = %d, native = true, lt = 1, paused = true }, %d)" % (T + 200, T)) is False)
check("a build not of a pause, made before the load, at the savegame's time: left out as in 0.8.3",
      run("return G.staleDrop('act', { uid = 'Eric:9', origin = 'Eric', at = %d, native = true, lt = 1 }, %d)" % (T, T)) is True)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
