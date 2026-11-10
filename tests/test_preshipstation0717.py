"""Offline test: a street edit at a construction's segment or node is shipped the usual way, not at the click (0.7.17, issue
#186; G.preTouchesCon and G.preship in mpfever_bridge.script.lua).

#186 (Erik, 20:33:52): a street edit next to his modular bus terminal went to beule at the click as one segment changed (its copy
0/0/1/1...); applied, the engine rebuilt the terminal too (4 nodes, 5 segments, modular_terminal.con), so Erik's capture was
"built here otherwise than shipped at the click" and the games were reloaded.
  - G.preTouchesCon: a removed segment of a construction, a node of a removed or added segment at a construction: that
    construction; a street away from any: nil; new nodes (negative) not asked; an engine error: nil;
  - G.preship: such a copy with no construction of its own goes the usual way (logged); MPFEVER_PRESHIPSTATIONEDIT=1: at the click.
Needs lupa (pip install lupa). Run: python tests/test_preshipstation0717.py
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
a = src.index("G.preTouchesCon = function(copy, con)")
b = src.index("\nend\n", a) + 5
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("G = {}\n" + src[a:b])
L.execute('''
EDGECON = { [390220] = 777 }
NODECON = { [5001] = 888 }
ASKED = {}
function con(kind, id) ASKED[#ASKED + 1] = kind .. id; if kind == "edge" then return EDGECON[id] or -1 end return NODECON[id] or -1 end
''')
r = L.eval('G.preTouchesCon({ proposal = { removedSegments = { { entity = 390220, comp = { node0 = 1, node1 = 2 } } } } }, con)')
check(r == 777, "a removed segment of a construction: that construction", r)
r = L.eval('G.preTouchesCon({ proposal = { removedSegments = { { entity = 10, comp = { node0 = 1, node1 = 5001 } } } } }, con)')
check(r == 888, "a removed segment ending at a construction's node", r)
r = L.eval('G.preTouchesCon({ proposal = { addedSegments = { { entity = -1, comp = { node0 = -2, node1 = 5001 } } } } }, con)')
check(r == 888, "a new segment ending at a construction's node", r)
r = L.eval('G.preTouchesCon({ proposal = { removedSegments = { { entity = 10, comp = { node0 = 1, node1 = 2 } } }, addedSegments = { { comp = { node0 = -1, node1 = 3 } } } } }, con)')
check(r is None, "a street away from any construction: nil", r)
check(L.eval('(function() for _, x in ipairs(ASKED) do if x:find("%-") then return false end end return true end)()'), "new nodes (negative) never asked")
r = L.eval('G.preTouchesCon({ proposal = { removedSegments = { { entity = 10 } } } }, function() error("engine") end)')
check(r is None, "an engine error: nil")
check(L.eval('G.preTouchesCon({ streetProposal = {} }, con)') is None, "no native proposal: nil")

p = src[src.index("G.preship = function(r)"):]
p = p[:p.index("\nend\n")]
check('os.getenv("MPFEVER_PRESHIPSTATIONEDIT") ~= "1" and #(r.copy.toAdd or {}) == 0 and #(r.copy.toRemove or {}) == 0' in p,
      "G.preship: a copy without constructions of its own; MPFEVER_PRESHIPSTATIONEDIT=1: as before")
check(p.index("G.preTouchesCon, r.copy") < p.index("local args = { n = 4, [1] = C.copy(r.copy)") and "shipped the usual way" in p,
      "  looked at before it is shipped, the usual way then")
c = p.index('os.getenv("MPFEVER_PRESHIPCLEANUP") ~= "1"')
check("if r.fn and bits and bits >= 32 and math.floor(bits / 4) % 2 == 1" in p and c < p.index("local args = { n = 4, [1] = C.copy(r.copy)"),
      "a script's build whose context cleans the street graph up: the usual way (MPFEVER_PRESHIPCLEANUP=1: at the click)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
