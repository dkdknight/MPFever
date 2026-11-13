"""Offline test: two demolitions at the same step are told apart (0.8.6, issue #278; C.buildSig, C.sigRemoved and C.sigSame in
mpfever_common.lua, the capture's comparison in mpfever_bridge.script.lua).

#278 (Creeper and Akamari, 2026-11-13 00:20:26): both bulldozed a construction at t=31625000. The host replayed Akamari's
demolition, then captured its own: both signatures read "one construction removed", the host took its own for the engine's second
application of the replay ("the same as the action just applied here: not shipped"), and kept one construction less than the other
game (owners c1 45/46, constructions 3282/3283, a resynchronisation).
  - two demolitions of different constructions: other signatures, never the same build;
  - the same demolition, from the shipped reference and from the local capture's reference: the same build;
  - a removal whose construction is not known on one side ("?", a reference by key only) matches any (as before);
  - an older signature without the removals' part compares by its counts, as before;
  - an entity id that the engine still knows gives its file and place;
  - MPFEVER_SIGRM=0: no "|rm|" part, the signatures as before (the two demolitions alike again);
  - the capture's comparison uses C.sigSame.
Needs lupa (pip install lupa). Run: python tests/test_sigrm086.py
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
b = src.index("function C.rebuiltSig(m, cfgs)")
code = src[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
CONS = { [4242] = { fileName = "depots/road/road_maint_station.con", transf = { 0,0,0,0, 0,0,0,0, 0,0,0,0, -154.2, -6860.4, 3, 1 } } }
api = { type = { ComponentType = { BASE_NODE = 1, CONSTRUCTION = 2 } }, engine = { getComponent = function(e, t)
  if t == 2 then return CONS[e] end; error("no node") end } }
C = {}
''' + code)


def sig(rm):
    return L.eval('C.buildSig({ proposal = {}, toRemove = { ' + rm + ' } })')


def same(x, y):
    L.globals().X, L.globals().Y = x, y
    return L.eval("C.sigSame(X, Y)")


akamari = sig('{ __ref = true, k = "con", id = 9, f = "depots/road/road_maint_station.con", p = { x = -154.2, y = -6860.4, z = 3 } }')
creeper = sig('{ __ref = true, k = "con", id = 77, f = "industries/farm/farm.con", p = { x = 512.0, y = 88.0, z = 1 } }')
check("road_maint_station.con@-154,-6860" in akamari, "the removed construction's file and place are in the signature", akamari)
check(not same(akamari, creeper), "two demolitions of different constructions: not the same build", akamari + " / " + creeper)
local_ref = sig('{ __ref = true, k = "con", id = 31, f = "depots/road/road_maint_station.con", p = { x = -154.4, y = -6860.1, z = 3 } }')
check(same(akamari, local_ref), "the same demolition from the shipped and the local reference: the same build", local_ref)
bykey = sig('{ __ref = true, key = "Jakob#1:12", id = 5, k = "con" }')
check("|rm|?" in bykey, "a reference by key only gives ?", bykey)
check(same(akamari, bykey) and same(bykey, creeper), "? matches any removal (as before)")
older = akamari.split("/|rm|")[0]
check(same(older, creeper) and same(akamari, older), "a signature without the removals' part compares by its counts")
entity = sig("4242")
check(same(entity, akamari) and "road_maint_station.con@-154,-6860" in entity, "an entity id the engine knows: its file and place", entity)
gone = sig("999")
check("|rm|?" in gone, "an entity the engine does not know: ?", gone)
two = sig('{ k = "con", f = "a.con", p = { x = 1, y = 2 } }, { k = "con", f = "b.con", p = { x = 3, y = 4 } }')
one = sig('{ k = "con", f = "a.con", p = { x = 1, y = 2 } }')
check(not same(two, one), "another count of removals: not the same build")
check(not same(sig("") if False else L.eval('C.buildSig({ proposal = { addedNodes = { 1 } }, toRemove = { { k = "con", f = "a.con", p = { x = 1, y = 2 } } } })'), one),
      "other street counts: not the same build")
L.execute('ENV.MPFEVER_SIGRM = "0"')
oa, oc = sig('{ k = "con", f = "a.con", p = { x = 1, y = 2 } }'), sig('{ k = "con", f = "b.con", p = { x = 3, y = 4 } }')
check(oa == oc and "|rm|" not in oa, "MPFEVER_SIGRM=0: as before (counts only)", oa + " / " + oc)

bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
i = bridge.index("the same as the action just applied here (the engine applies it again): not shipped")
check("C.sigSame(s, sig)" in bridge[i - 600:i], "the capture's comparison uses C.sigSame")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
