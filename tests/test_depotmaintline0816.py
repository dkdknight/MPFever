"""Offline test (0.8.16): a depot's window says how many vehicles of the other companies it maintains.

0.8.15's shared maintenance worked with nothing to see in the game: a player could not tell that his open depot maintained the
others' vehicles, nor what a toll was charged for. Now:
  - U.depotInfo gives the depot's entities and its company's player;
  - U.depotMaintOthers counts the vehicles each of them maintains (getVehiclesForMaintenanceStation) whose owner is another
    player; vehicles without an owner, and the depot's own company's, are not counted;
  - the window shows "Maintains N vehicle(s) of other companies." when N > 0 (MPFEVER_DEPOTMAINTLINE=0: not shown);
  - the toll's label says it is charged per purchase and per month for each vehicle maintained there; both texts translated.
Needs lupa. Run: python tests/test_depotmaintline0816.py
"""
import json, os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
lang = json.load(open(os.path.join(HERE, "..", "launcher", "lang.json"), encoding="utf-8-sig"))["texts"]
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m = re.search(r"^U\.depotMaintOthers = function\(ents, owner\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "U.depotMaintOthers found")
check("ents = ents, owner = owner }" in src, "U.depotInfo gives the depot's entities and owner")
check("depotEnts = depot and depot.ents or nil, depotOwner = depot and depot.owner or nil," in src, "  passed to the window")
check('os.getenv("MPFEVER_DEPOTMAINTLINE") ~= "0"' in src, "MPFEVER_DEPOTMAINTLINE=0: not shown")
check('"Maintains %d vehicle(s) of other companies."' in src and "if type(mn) == \"number\" and mn > 0 then" in src, "the line, only when some are maintained")
for k in ("Maintains %d vehicle(s) of other companies.", "Open, a toll of %s per vehicle bought here and per month for each vehicle maintained here"):
    check(k in src and k in lang and len(lang[k]) == 11, "translated in 11 languages: " + k[:40])
if m:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
U = {}
OWN = { [1] = 100, [2] = 200, [3] = 200, [4] = 300 }
MAINT = { [501] = { 1, 2, 3 }, [502] = { 4, 9 } }
api = { type = { ComponentType = { PLAYER_OWNED = "po" } }, engine = {
  getComponent = function(e, t) local o = OWN[e] if o then return { player = o } end return nil end,
  system = { transportVehicleSystem = { getVehiclesForMaintenanceStation = function(d) return MAINT[d] or {} end } } } }
""" + m.group(0))
    f = L.eval("function(e, o) return U.depotMaintOthers(e, o) end")
    check(f(L.eval("{ 501, 502 }"), 100) == 3, "the others' vehicles counted (2 of 200, 1 of 300; its own and one without owner not)")
    check(f(L.eval("{ 503 }"), 100) == 0, "a depot that maintains none: 0")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
