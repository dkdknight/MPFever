"""Offline test (0.8.17, #395): after a load, a checkpoint stamped before the savegame's time is left out, and the host's values
of it are never applied (G.staleDrop kind "hash", G.staleAuth and the reading of in.log in mpfever_bridge.script.lua, switch
MPFEVER_STALEHASH).

mandy, kicked and invited again (local_user's session, 2026-11-16 19:04), loaded resynchronisation 3's save (t=12223400); her game
read the paused checkpoint n=1 of her connection before (t=12208000), took it after the load ("paused action nil ... applied at
12223400 (desync risk)"), and the host's values of that checkpoint set her money to that older moment's (-10 327 / -6 889); the
host's checkpoint 4 put it back.
G.staleDrop and G.staleAuth are taken from the real bridge and run through lupa:
  - MPFEVER_STALEHASH=0: checkpoint 1 (t=12208000) kept (the bug, reproduced);
  - now: left out, said; the host's values of checkpoint 1 not applied (once), those of checkpoint 4 applied;
  - a checkpoint at the savegame's very time, or later: kept;
  - the reading of in.log asks G.staleAuth for every "auth" message.
Needs lupa. Run: python tests/test_stalehash0817.py
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


m1 = re.search(r"^G\.staleDrop = function\(kind, p, before\)\n.*?^end\n", src, re.S | re.M)
m2 = re.search(r"^G\.staleAuth = function\(p\)\n.*?^end\n", src, re.S | re.M)
check("G.staleDrop and G.staleAuth found", bool(m1 and m2))
if not (m1 and m2):
    sys.exit(1)
check("the reading of in.log asks G.staleAuth for an auth message", 'if h and kind == "auth" and G.staleAuth(payload) then h = nil end' in src)


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nLOGS = {}\nfunction log(s) LOGS[#LOGS + 1] = s end\nG = {}\n" + m1.group(0) + m2.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_STALEHASH = '0'")
    return run


T = 12223400
run = runtime(off=True)
check("MPFEVER_STALEHASH=0: checkpoint 1 (t=12208000) kept after the load (the bug)",
      run("return G.staleDrop('hash', { n = 1, at = 12208000, paused = true }, %d)" % T) is False)
run = runtime()
check("now: checkpoint 1 (t=12208000) left out", run("return G.staleDrop('hash', { n = 1, at = 12208000, paused = true }, %d)" % T) is True)
check("  and said", any("checkpoint 1 for t=12208000 left out" in x for x in run("return LOGS").values()))
check("the host's values of checkpoint 1: not applied", run("return G.staleAuth({ n = 1, ptd = 0 })") is True)
check("  only once (a later number 1 of a new session is applied)", run("return G.staleAuth({ n = 1, ptd = 0 })") is False)
check("the host's values of checkpoint 4: applied", run("return G.staleAuth({ n = 4, ptd = 0 })") is False)
check("a checkpoint at the savegame's very time: kept", run("return G.staleDrop('hash', { n = 2, at = %d, paused = true }, %d)" % (T, T)) is False)
check("a later checkpoint: kept", run("return G.staleDrop('hash', { n = 3, at = %d }, %d)" % (T + 2000, T)) is False)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
