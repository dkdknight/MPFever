"""Offline test (0.8.17, #393): a kept drift also writes every segment's TICK_EPOCH by the places of its ends (SDUMP.epochs,
SDUMP.keepDrift in mpfever_bridge.script.lua, switch MPFEVER_EPOCHDUMP; Reporter.DriftDump / EarlierFile in launcher/Reporter.cs).

#393 (beule and Erik, 2026-11-16 18:39): "ages" apart from the first check after a load, 9308 segments on both games, and no dump
said which segments. The two games' files, sorted by place (entity ids may differ), compared line by line name them.
  - SDUMP.epochs (run through lupa on a small world): one line per segment, its ends in a fixed order, sorted, the stamp;
  - two games with the same streets under other ids give the same file but for the segment whose stamp differs;
  - called from SDUMP.keepDrift unless MPFEVER_EPOCHDUMP=0, and kept in the reports with the other drift dumps.
Needs lupa. Run: python tests/test_epochdump0817.py
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


m = re.search(r"^function SDUMP\.epochs\(slot, n\)\n.*?^end\n", src, re.S | re.M)
check("SDUMP.epochs found", m is not None)
if not m:
    sys.exit(1)
kd = src[src.index("function SDUMP.keepDrift(n, dump)"):]
kd = kd[:kd.index("\nend\n")]
check("called by SDUMP.keepDrift (MPFEVER_EPOCHDUMP=0: not)", 'if os.getenv("MPFEVER_EPOCHDUMP") ~= "0" then pcall(SDUMP.epochs, slot, n) end' in kd)
rep = open(os.path.join(HERE, "..", "launcher", "Reporter.cs"), encoding="utf-8-sig").read()
check("kept in the reports with the drift dumps", rep.count('n.StartsWith("sdump_epochs")') == 2)


def game(ids, stamp_b):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
FILES = {}
NL = "\n"; BS = "/"
C = { DIR = "d", IO = { open = function(p) local t = {} FILES[p] = t return { write = function(self, ...) for _, x in ipairs({ ... }) do t[#t + 1] = x end end, close = function() end } end } }
function gameTime() return 500 end
SDUMP = {}
NODES, EDGES, EPOCH = {}, {}, {}
R = { allEdges = function() local t = {} for e in pairs(EDGES) do t[#t + 1] = e end table.sort(t) return t end }
api = { type = { ComponentType = { BASE_EDGE = "E", BASE_NODE = "N", TICK_EPOCH = "T" } },
  engine = { getComponent = function(e, c)
    if c == "E" then return EDGES[e] end
    if c == "N" then return NODES[e] end
    if c == "T" then return EPOCH[e] end end } }
''' + m.group(0))
    a, b, n1, n2, n3 = ids
    L.execute(f"""NODES[{n1}] = {{ position = {{ x = 10, y = 20, z = 1 }} }}; NODES[{n2}] = {{ position = {{ x = 30, y = 20, z = 1 }} }}; NODES[{n3}] = {{ position = {{ x = 50, y = 20, z = 1 }} }}
EDGES[{a}] = {{ node0 = {n1}, node1 = {n2}, type = 0 }}; EDGES[{b}] = {{ node0 = {n3}, node1 = {n2}, type = 0 }}
EPOCH[{a}] = {{ time = 361948, commandIndex = 0, subIndex = 0 }}; EPOCH[{b}] = {{ time = {stamp_b}, commandIndex = 0, subIndex = 0 }}
SDUMP.epochs(1, 7)""")
    return [x for x in "".join(L.eval("table.concat(FILES['d/sdump_epochs_1.txt'], '')")).split("\n") if x]


A = game((437749, 440018, 422073, 428008, 429000), 361948)
B = game((5001, 5002, 71, 72, 73), 361948)
check("one line per segment after the header", len(A) == 3 and A[0].startswith("t = 500 check 7 segments 2"), A)
check("two games, the same streets under other ids: the same lines", A[1:] == B[1:], (A, B))
B2 = game((5001, 5002, 71, 72, 73), 383036)
diff = [x for x in B2[1:] if x not in A[1:]]
check("the segment whose stamp differs is the one line apart, named by its ends", len(diff) == 1 and "30.0,20.0,1.0 50.0,20.0,1.0" in diff[0] and "383036/0/0" in diff[0], diff)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
