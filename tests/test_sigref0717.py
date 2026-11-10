"""Offline test: the signature of a build never holds a memory address (0.7.17, issues #186 and #193; C.buildSig in
mpfever_common.lua).

#186 (beule:27) and #193 (BaumEdePiep:114, 21:57:34): a build shipped at the click was compared with its capture, whose node
configuration named a node the build took away by its id only ({ k = "node", id = n }, no position). The signature wrote
"table: 0000029E33A15690" for it, the copy (read at the click) "2219,489": "built here otherwise than shipped at the click" and
a resynchronisation, though both games built the same thing.
  - a reference without position takes the position seen for that id before (the copy), so both signatures are alike;
  - a reference never seen gives "#id", never a memory address;
  - a node id the engine cannot read gives "#id";
  - MPFEVER_SIGREF=0: as before (the address).
Needs lupa (pip install lupa). Run: python tests/test_sigref0717.py
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


src = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = src.index("function C.buildSig(m)")
b = src.index("\nend\n", a) + 5
code = src[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
POS = { [2219] = { x = 2219.2, y = 489.4 } }
api = { type = { ComponentType = { BASE_NODE = 1 } }, engine = { getComponent = function(e, t)
  local p = POS[e]; if not p then error("no node") end; return { position = p } end } }
C = {}
''' + code)

def sig(entity):
    L.execute("ENT = " + entity)
    return L.eval('C.buildSig({ proposal = { nodeConfigsToAdd = { { entity = ENT, comp = { doubleSlipSwitch = false } } } } })')

copy = sig("2219")
L.execute("POS[2219] = nil")  # the build took the node away
cap = sig('{ k = "node", id = 2219 }')
check("2219,489" in copy, "the copy gives the node's position", copy)
check(cap == copy, "the capture's reference without position gives the same signature", cap + " / " + copy)
check("table:" not in cap, "no memory address", cap)
fresh = sig('{ k = "node", id = 777 }')
check("#777" in fresh and "table:" not in fresh, "a reference never seen: #id", fresh)
gone = sig("888")
check("#888" in gone, "a node the engine cannot read: #id", gone)
withp = sig('{ k = "node", id = 5, p = { x = 10, y = 20 } }')
check("10,20" in withp, "a reference with its position: the position", withp)
L.execute('ENV.MPFEVER_SIGREF = "0"')
old = sig('{ k = "node", id = 999 }')
check("table:" in old, "MPFEVER_SIGREF=0: as before", old)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
