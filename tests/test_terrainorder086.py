"""Offline test: a terrain edit and the builds of its step in one order on every game (0.8.6, #272; G.buildsPendingAt,
G.terrainEarlyOf, G.terrainWaitsBuilds, G.terrainEarlyFirst and their hooks in mod/mpfever_1/content/mpfever_bridge.script.lua).

#272 (yoyo, Bence, 2026-11-12 22:04:04): yoyo's held build and Bence's terrain edit were both for t=19676400. yoyo's game applied
its build, then the edit; Bence's game, standing at that step for the build (Bence led with the terrain tool), had the edit first.
The games took other free ids from there (drift step 98381) and drifted apart 20 minutes later. Reproduced by the autotest
MPFEVER_SCENARIO=terrainlead with MPFEVER_TERRAINLEAD_ATHOLD=1 (the leader edits while standing at the other's build).
  - the usual order: the builds announced for a step, then the terrain edits of that step: an edit waits while a build of its
    step is announced and not applied (another player's or this game's own held one), or one is in the engine's hands;
  - not in a pause (turns), not forever (15 s);
  - an edit made on its builder before builds of its step ("early", the list of their players) goes at once, and those builds
    wait for it (this game's own held build too); one of them already applied here: "TERRAIN ORDER ... the games differ";
  - the builder names those builds as it ships the edit; MPFEVER_TERRAINORDER=0: as before (no wait, no list).
Needs lupa (pip install lupa). Run: python tests/test_terrainorder086.py
"""
import os, sys

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


src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = src.index("G.terrainOrderOn = function()")
b = src.index("-- (0.7.13, #161 #166: two players' held builds announced for the same step.")
code = src[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
log = function(s) LOGS[#LOGS + 1] = s end
G = { me = "Bence", natWait = {}, natRelease = {}, nativeQueue = {}, session = {}, frames = 100 }
''' + code)

T = 19676400
# yoyo's game: its own held build at T, Bence's ordinary edit for T: waits for the build
L.execute('G.me = "yoyo"; G.natRelease = { { id = 89, at = %d } }; G.natWait = {}' % T)
L.execute('E = { fn = "terrainEdit", at = %d, uid = "Bence#1:64" }' % T)
check(L.eval("G.terrainWaitsBuilds(E)") is True, "an edit waits for this game's own held build of its step")
L.execute('G.natRelease = {}')
check(L.eval("G.terrainWaitsBuilds(E)") is False, "  and goes once it is released")
L.execute('G.natWait = { { origin = "Akamari#1", at = %d } }' % T)
check(L.eval("G.terrainWaitsBuilds(E)") is True, "an edit waits for another player's announced build of its step")
L.execute('G.natWait = {}; G.replayAt = %d; G.replayOut = 1' % T)
check(L.eval("G.terrainWaitsBuilds(E)") is True, "  and while that build is in the engine's hands")
L.execute('G.replayOut = 0; G.replayQuiet = 0')
check(L.eval("G.terrainWaitsBuilds(E)") is False, "  then goes")
L.execute('G.natWait = { { origin = "Akamari#1", at = %d } }; E.orderWait = nil; G.frames = 100' % (T + 200))
check(L.eval("G.terrainWaitsBuilds(E)") is False, "a build of another step: no wait")
L.execute('G.natWait = { { origin = "Akamari#1", at = %d } }; G.frames = 100; E.orderWait = nil' % T)
L.eval("G.terrainWaitsBuilds(E)")
L.execute('G.frames = 1100')
check(L.eval("G.terrainWaitsBuilds(E)") is False, "not forever: 15 s at most")
L.execute('E2 = { fn = "terrainEdit", at = %d, uid = "x", paused = true }; G.session.pauseAt = %d; G.natRelease = { { id = 89, at = %d } }' % (T, T - 200, T))
check(L.eval("G.terrainWaitsBuilds(E2)") is False, "in a real pause of the session: the pause's turns")
L.execute('G.session.pauseAt = nil; E2.orderWait = nil; G.frames = 100')
check(L.eval("G.terrainWaitsBuilds(E2)") is True, "an edit marked paused because its game stood at a held build (Bence's): ordered")
L.execute('G.natRelease = {}')

# Bence (the builder) ships an edit made while standing at yoyo's build of T: it names yoyo
L.execute('G.me = "Bence"; G.natWait = { { origin = "yoyo", at = %d } }; G.natRelease = {}' % T)
early = L.eval("G.terrainEarlyOf(%d)" % T)
check(early is not None and early[1] == "yoyo", "the builder names the builds still to come at that step (early)")
L.execute('G.natWait = {}')
check(L.eval("G.terrainEarlyOf(%d)" % T) is None, "  none when nothing is still to come")

# yoyo receives the early edit before releasing its own build: the edit goes, its build waits for it
L.execute('G.me = "yoyo"; G.natRelease = { { id = 89, at = %d } }; G.natWait = {}' % T)
L.execute('EE = { fn = "terrainEdit", at = %d, uid = "Bence#1:64", early = { "yoyo" } }; G.nativeQueue = { EE }' % T)
check(L.eval("G.terrainWaitsBuilds(EE)") is False, "an early edit goes at once")
check(L.eval('G.terrainEarlyFirst(%d, "yoyo")' % T) is True, "  this game's own build of that step waits for it")
check(L.eval('G.terrainEarlyFirst(%d, "Akamari#1")' % T) is False, "  a build of a player it does not name does not")
L.execute('G.nativeQueue = {}; G.terrainBusy = { a = EE }')
check(L.eval('G.terrainEarlyFirst(%d, "yoyo")' % T) is True, "  nor before the edit is applied (being replayed)")
L.execute('G.terrainBusy = nil')
check(L.eval('G.terrainEarlyFirst(%d, "yoyo")' % T) is False, "  then it goes")
# the build already applied when the early edit comes: said
L.execute('G.natRelease = {}; LOGS = {}; EE.earlyChecked = nil')
L.eval("G.terrainWaitsBuilds(EE)")
check(any("TERRAIN ORDER" in (L.eval("LOGS[%d]" % i) or "") for i in range(1, int(L.eval("#LOGS")) + 1)), "a build already applied: TERRAIN ORDER said")

L.execute('ENV.MPFEVER_TERRAINORDER = "0"; G.natRelease = { { id = 89, at = %d } }; E.orderWait = nil' % T)
check(L.eval("G.terrainWaitsBuilds(E)") is False and L.eval("G.terrainEarlyOf(%d)" % T) is None and L.eval('G.terrainEarlyFirst(%d, "yoyo")' % T) is False,
      "MPFEVER_TERRAINORDER=0: as before")

check('or (a.fn == "terrainEdit" and not seq and G.terrainWaitsBuilds and G.terrainWaitsBuilds(a))' in src and 'or (a.native and a.fn ~= "terrainEdit" and not seq and G.terrainEarlyFirst and G.terrainEarlyFirst(a.at, a.origin))' in src,
      "the replay queue uses them")
check("and not (not r.paused and G.terrainEarlyFirst and G.terrainEarlyFirst(r.at, G.me)) and not G.sameStepWait(r.at, G.me) and not G.ownWaitsReplay(r) then" in src, "this game's own held build waits for an early edit")
i = src.index('local a = { fn = "terrainEdit", args = { x0 = d.x0')
check("local early = G.terrainEarlyOf(o.at)" in src[i:i + 1400] and "a.early = early" in src[i:i + 1400], "the builder names them as it ships the edit")
check("if not (G.session.pauseAt ~= nil and o.at >= G.session.pauseAt) then" in src[i:i + 1400], "  also when its game stood at that build (marked paused), not in a real pause")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
