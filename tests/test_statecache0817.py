"""Offline test (0.8.17, speed): the interface reads the simulation's state again only when it took over a new copy of the
simulation (G.stateCached in mpfever_bridge.script.lua, switch MPFEVER_STATECACHE).

state:get() copies the whole state into the interface at every frame: 90 kB and 1.2 to 2 ms in the autotest stationedit of
2026-11-17 (k9ue), 60 times a second, for a state that changes at the handshakes (about 5 times a second; GameTime.tickCount
changes with each new copy, in a pause too). G.stateCached is run through lupa with a fake state and tick:
  - MPFEVER_STATECACHE=0: a state:get() at every frame (as before);
  - now: one read per tick; the same tick reuses the frame before's copy, for 30 frames at most; a new tick reads again;
  - a failed read is never kept; without a tick (nil), a read at every frame;
  - with MPFEVER_GUIPROF=2 one kept copy in ten is compared with a new read (key order does not matter);
the bindings, the check and the results of a kept copy are not looked through again; and statically: nothing of the interface that gets the state (or its companies' registry) writes into it, so a kept copy is
the same as a new one.
Needs lupa. Run: python tests/test_statecache0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
common = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r"^G\.stateCacheOn = .*?\n(?=\n)", src, re.S | re.M)
check("G.stateCached, G.stateCanon and G.stateCacheCheck found", m is not None and "G.stateCached = function(state, gp)" in m.group(0)
      and "G.stateCacheCheck = function(state, cached)" in m.group(0))
ser = re.search(r"^function C\.ser\(v, depth\)\n.*?^end\n", common, re.S | re.M)
if not m or not ser:
    sys.exit(1)
body = src[src.index("G.guiUpdateBody = function(userParams, state, guiState)"):]
body = body[:body.index("\nend\n")]
check("the frame's state comes from G.stateCached", "local st = G.stateCached(state, gp)" in body and "return state:get() end)" not in body)

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
QUOTE, ESCAPED = '"', '["\\]'
local function escapeChar(c) return "\\" .. c end
C = { int = function(v) return string.format("%d", v) end }
''' + ser.group(0).replace("function C.ser", "function C.ser") + r'''
GETS, TICK, FAIL = 0, 100, false
STATE = { get = function(self) GETS = GETS + 1; if FAIL then error("no state") end return { n = GETS, q = { 1, 2 } } end }
'''


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK.replace("local function escapeChar", "escapeChar = nil\nlocal function escapeChar"))
    if off:
        L.execute("ENV.MPFEVER_STATECACHE = '0'")
    L.execute("G = { frames = 0 }\nG.simTick = function() return TICK end\n" + m.group(0))
    return L.eval("function(code) return assert(load(code))() end")


def frames(run, k, tick_every=None):
    for i in range(k):
        run("G.frames = G.frames + 1")
        if tick_every and i % tick_every == 0 and i > 0:
            run("TICK = TICK + 1")
        run("ST = G.stateCached(STATE, false)")


run = runtime(off=True)
frames(run, 60, tick_every=12)
check("MPFEVER_STATECACHE=0: a read at every frame (60 in 60 frames)", run("return GETS") == 60, run("return GETS"))

run = runtime()
frames(run, 60, tick_every=12)
got = run("return GETS")
check("now: one read per tick (5 ticks in 60 frames: 5 reads)", got == 5, got)
run("TICK = TICK + 1")
frames(run, 1)
check("a new tick: read again at once", run("return GETS") == 6 and run("return ST.n") == 6, run("return GETS"))
check("  G.stKept false for a new read", run("return G.stKept") is False)
frames(run, 29)
check("  the same tick: the kept copy for 29 more frames", run("return GETS") == 6)
check("  G.stKept true for the kept copy", run("return G.stKept") is True)
frames(run, 1)
check("  30 frames: read again", run("return GETS") == 7, run("return GETS"))
run("FAIL = true; TICK = TICK + 1")
frames(run, 1)
check("a failed read gives an empty state", run("return next(ST) == nil") is True)
run("FAIL = false")
frames(run, 1)
check("  and is never kept (read again at the next frame)", run("return GETS") == 9 and run("return ST.n") == 9, run("return GETS"))
run("G.simTick = function() return nil end")
before = run("return GETS")
frames(run, 5)
check("without a tick: a read at every frame", run("return GETS") == before + 5)
run("G.simTick = function() return TICK end; TICK = TICK + 1; G.frames = 1")
run("G.gpCheck = true; ST = G.stateCached(STATE, true)")
run("G.stcN, G.stcDiff = 0, 0; G.frames = 10; ST = G.stateCached(STATE, true)")
check("GUIPROF=2: a kept copy compared with a new read (frame 10)", run("return G.stcN") == 1 and run("return G.stcDiff") == 1)
# (the engine gives the same table at every state:get(), filled again: the check compares with the text taken at the read)
run("SAME = { n = 0 }; STATE2 = { get = function(self) SAME.n = SAME.n + 1; return SAME end }")
run("G.gpCheck = true; G.stcN, G.stcDiff = 0, 0; TICK = TICK + 1; G.frames = 20; ST = G.stateCached(STATE2, true)")
run("G.frames = 30; ST = G.stateCached(STATE2, true)")
check("GUIPROF=2 with the engine's one table: a change within one tick is seen (not compared with itself)", run("return G.stcN") == 1 and run("return G.stcDiff") == 1, (run("return G.stcN"), run("return G.stcDiff")))
check("  the comparison ignores the order of keys", run("return G.stateCanon({a=1,b={2,3},c='x'}) == G.stateCanon({c='x',b={2,3},a=1})") is True)

# the bindings, check and results of a kept copy were taken at the frame before: looked through only for a new copy
i = body.index("if not G.stKept then")
j = body.index("if st.townDiffs and G.tsWait then pcall(G.townDiffs, st) end")
blk = body[i:j]
check("bindings, check and results looked through only for a new copy (or with the switch off)",
      "G.rebind(key, e)" in blk and "st.hash.n ~= G.hashSent" in blk and "G.resultsSeen[key] = true" in blk)
check("  G.stKept set by G.stateCached: true for a kept copy only (never by the identity of a table: a test's state is one table)", "G.stKept = true" in m.group(0) and "G.stKept = false" in m.group(0))
check("  the towns' comparison still every frame (it follows G.tsWait too)", j > i and "G.townDiffs" not in blk)

# nothing of the interface writes into the state it gets
funcs = ["local function coGui(st)", "G.featGui = function(st)", "G.aiStep = function(st)", "local function shipNativeBuilds(st)",
         "G.pullPrune = function(st)", "G.townDiffs = function(st)", "G.coEco = function(st, reg, c)", "G.openNet = function(reg, me)",
         "G.hudShare = function(reg, me)", "function G.reportResult(r)"]
for f in funcs:
    i = src.find(f)
    if i < 0:
        check("found " + f, False)
        continue
    b = src[i:src.index("\nend\n", i)]
    w = re.findall(r"^\s*((?:st|reg|r)(?:\.\w+|\[[^\]]+\])+)\s*=[^=]", b, re.M)
    check(f"no write into the state in {f.split('(')[0].replace('local function ', '').replace(' = function', '')}", w == [], w)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
