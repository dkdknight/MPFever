"""Offline test of #467 (0.9.6, mod/mpfever_1/content/mpfever_common.lua C.removeOnce and C.noteGone, called by
mpfever_bridge.script.lua executeActionOnce; switch MPFEVER_REMOVEONCE).

#467 (2026-11-21 20:54, Julian host with Kappador, 0.9.5): the mod Dévers (devers_1) demolishes its render constructions from its
script. MPFever ships such a command for a later step; the mod saw the constructions still there meanwhile and asked again: four
demolitions of the same four devers_render.con (Julian:81 to Julian:84) were applied at t=49844200 in one update of the
simulation, and the game stopped on the second ("SimEntityUpdateHelper.cpp:2013", the same entity twice in removedTnEntities).
Now a build whose constructions to remove an earlier build at this game time already takes away leaves them out, and is refused
on every game when nothing else is left in it (the same builds in the same order on every game: the same decision everywhere).

The engine is modelled as it behaves: it stops when one update removes the same construction twice. Repro with the switch off,
fix with it on, from #467's four actions.
Needs lupa (pip install lupa). Run: python tests/test_removeonce096.py
"""
import os
import sys

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


def read(n):
    return open(os.path.join(CONTENT, n), encoding="utf-8").read().replace("\r\n", "\n")


common, bridge = read("mpfever_common.lua"), read("mpfever_bridge.script.lua")
a = common.index("-- (0.7.15, #174) the segments and nodes a build takes away")
b = common.index("-- (0.6.9) what a script's copy of a segment keeps of it")
block = common[a:b]

SETUP = r'''
C = {}
ENV = {}
os.getenv = function(k) return ENV[k] end
'''

# the engine's update: each build's removals are queued for the end of the update; the same construction twice stops the game
APPLY = r'''
function UPDATE(actions)
  local gone, removed, applied, refused = {}, {}, {}, {}
  for i, m in ipairs(actions) do
    local okR, n, left = pcall(C.removeOnce, m, gone)
    if okR and n > 0 and not left then
      refused[#refused + 1] = i
    else
      for _, e in ipairs(m.constructionsToRemove or m.toRemove or {}) do
        if removed[e] then error("SimEntityUpdateHelper.cpp:2013: entity " .. e .. " twice in removedTnEntities") end
        removed[e] = true
      end
      applied[#applied + 1] = i
      C.noteGone(m, gone)
    end
  end
  return #applied, #refused
end
-- #467: Julian:81..84 at t=49844200, each the same four devers_render.con
function DEVERS() local t = {} for i = 1, 4 do t[i] = { constructionsToRemove = { 9001, 9002, 9003, 9004 }, constructionsToAdd = {}, streetProposal = { edgesToAdd = {}, edgesToRemove = {} } } end return t end
'''


def runtime():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(SETUP + block + APPLY)
    return L


L = runtime()
L.execute('ENV.MPFEVER_REMOVEONCE = "0"')
ok = L.eval("(pcall(UPDATE, DEVERS()))")
err = L.eval("select(2, pcall(UPDATE, DEVERS()))")
check(ok is False and "twice in removedTnEntities" in str(err), "repro #467: four demolitions of the same constructions in one update stop the game", err)

L = runtime()
applied, refused = L.eval("UPDATE(DEVERS())")
check(applied == 1 and refused == 3, "fix: the first is applied, the three others refused (nothing left in them)", f"{applied}/{refused}")

# partial: a build demolishing one gone construction and one other: the gone one left out, the other kept
L.execute('''
GONE = { [9001] = true }
M = { constructionsToRemove = { 9001, 9005 } }
N, LEFT = C.removeOnce(M, GONE)
''')
check(L.eval("N") == 1 and L.eval("LEFT") is True and L.eval("#M.constructionsToRemove") == 1 and L.eval("M.constructionsToRemove[1]") == 9005,
      "a build with another construction to demolish: the gone one left out, the other kept")
L.execute('''
M2 = { constructionsToRemove = { 9001 }, constructionsToAdd = { { fileName = "x.con" } } }
N2, LEFT2 = C.removeOnce(M2, GONE)
''')
check(L.eval("N2") == 1 and L.eval("LEFT2") is True and L.eval("#M2.constructionsToRemove") == 0, "a build that also adds something: kept, without the gone demolition")
L.execute('''
M3 = { constructionsToRemove = { 9001 }, streetProposal = { edgesToAdd = { { entity = -1 } } } }
N3, LEFT3 = C.removeOnce(M3, GONE)
''')
check(L.eval("LEFT3") is True, "  a street part counts as something left")
L.execute('''
M4 = { constructionsToRemove = { 9001, 9006 }, old2new = { [9006] = 1 }, constructionsToAdd = { { fileName = "y.con" } } }
N4, LEFT4 = C.removeOnce(M4, GONE)
''')
check(L.eval("N4") == 0 and L.eval("LEFT4") is True and L.eval("#M4.constructionsToRemove") == 2, "a replacement mapped by rank (old2new): left as it is")
L.execute('''
M5 = { toRemove = { 9001 }, proposal = { addedSegments = {}, removedSegments = {} } }
N5, LEFT5 = C.removeOnce(M5, GONE)
''')
check(L.eval("N5") == 1 and L.eval("LEFT5") is False, "a tool's build (toRemove) with nothing else: refused too")
check(L.eval("(C.removeOnce({ constructionsToRemove = { 7 } }, GONE))") == 0, "nothing gone: untouched")
L.execute('G2 = C.noteGone({ constructionsToRemove = { 77 }, streetProposal = { edgesToRemove = { 55 } } }, {})')
check(L.eval("G2[77]") is True and L.eval("G2[55]") is True, "C.noteGone notes the demolished constructions too (and the segments, as before)")
L.execute('ENV.MPFEVER_REMOVEONCE = "0"; G3 = C.noteGone({ constructionsToRemove = { 78 } }, {})')
check(L.eval("G3[78]") is None and L.eval("(C.removeOnce({ constructionsToRemove = { 9001 } }, GONE))") == 0, "MPFEVER_REMOVEONCE=0: as before")

# the bridge
s = bridge[bridge.index("local function executeActionOnce(a, sendCommand, useCallback, bind, done)"):]
s = s[:s.index("\nexecuteAction = function(")]
check("pcall(C.removeOnce, a.args[1], stepGone)" in s, "executeActionOnce calls C.removeOnce with this update's set")
check(s.index("pcall(C.removeOnce, a.args[1], stepGone)") < s.index("buildCommand(a.fn, C.ser(a.args or {})"), "  before the command is made (a stripped build is built stripped)")
check(s.index("pcall(C.removeOnce, a.args[1], stepGone)") > s.index("local okt, unresolved = pcall(R.translateIn"), "  after the references are this game's ids")
check("refused on every game: \" .. result.err" in s[s.index("pcall(C.removeOnce"):][:900], "  nothing left: refused (its replay count given back by the callers, as for any refused build)")
check("pcall(C.noteGone, a.args[1], stepGone)" in s, "  what each build demolishes noted for the next ones (C.noteGone)")
check('if C.makesProposal(a.fn) and not r.success and st.replay and st.replay.at == now and st.replay.n > 0 then' in bridge
      and 'if not r.success then pcall(toSim, "replay_unused", {}) end' in bridge, "the callers give the replay count back for a refused build (simulation and pause)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
