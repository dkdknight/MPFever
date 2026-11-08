"""Offline test: a stop refused on one game while its builder built it says what was in the way, and is tried once more by the
engine's own conversion of the tool's build before the games are reloaded (0.7.7, replayStop's refusal and G.collisionShort /
G.logRefusal in mod/mpfever_1/content/mpfever_bridge.script.lua).

#133 resync 3: a two-sided street stop placed by the host was refused "Botsing" (collision) on Yke's game only, and the host's
game was reloaded. Only the host's log was in the report: what collided could not be told. A street stop is replayed by a
script form (its segment replaced by a copy carrying the stop), which can collide where the tool's own build, made with the
engine's replacement maps, did not. Now:
  - the refusal logs the engine's collision information, and the reason sent to the host names what was in the way (a town
    building, a vehicle, a construction... with its owner) and how many steps late the replay was;
  - built on its builder's game (its town statistics came with it), refused here in every script form: tried once more by the
    engine's conversion of the tool's own build (G.replayNativeStop, used for stops on bridges and for signals), and only then
    the games are reloaded (its own refusal falls back to the script forms, which then send the refusal);
  - MPFEVER_STOPNATIVERETRY=0: as before.
Needs lupa for G.collisionShort (pip install lupa). Run: python tests/test_stopretry077.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


rs = src[src.index("local function replayStop(a, plan, variant)"):]
rs = rs[:rs.index("\nend\n")]
ref = rs[rs.index("		if not success then\n			-- (0.7.7, #133 resync 3"):]
check("pcall(G.logRefusal, a, res)" in ref and "inWay = G.collisionShort(res)" in ref, "the refusal: the engine's collision information logged, and what was in the way")
check('if type(a.ts) == "table" and not plan.nativeTried and type(plan.E) == "number" and os.getenv("MPFEVER_STOPNATIVERETRY") ~= "0" then' in ref,
      "built by its builder (its statistics came), not tried natively yet: one more try (MPFEVER_STOPNATIVERETRY=0: none)")
check("plan.nativeTried = true" in ref and "pcall(G.replayNativeStop, a, plan)" in ref and ref.index("plan.nativeTried = true") < ref.index("pcall(G.replayNativeStop, a, plan)"),
      "  by the engine's conversion of the tool's build, once (its own refusal goes back to the script forms, which then report it)")
check(ref.index("return\n\t\t\tend\n\t\t\tpcall(send, \"replay_failed\"") > 0 and 'why = ("stop refused " .. why .. inWay' in ref,
      "  the refusal sent only after it, with what was in the way")
check("G.logRefusal = logRefusal" in src and src.index("G.logRefusal = logRefusal") > src.index("local function logRefusal(a, res)"),
      "the refusal logger reachable from replayStop (defined after it)")
nat = src[src.index("G.replayNativeStop = function(a, plan)"):][:600]
check("return G.nowOrNext(function() replayStop(a, plan) end)" in nat, "the engine's conversion, when it cannot be made or is refused: back to the script forms")

try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed (pip install lupa): the Lua part skipped")
if lupa:
    m = re.search(r"^G\.collisionShort = function\(res\)\n.*?^end\n", src, re.S | re.M)
    check(m is not None, "G.collisionShort found")
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
G = {}
COMPS = { [123] = { TOWN_BUILDING = {}, PLAYER_OWNED = { player = -1 } }, [456] = { TRANSPORT_VEHICLE = {}, PLAYER_OWNED = { player = 7 } }, [789] = { CONSTRUCTION = {} } }
api = { type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = { getComponent = function(e, ct) return COMPS[e] and COMPS[e][ct] or nil end } }
''' + m.group(0))
    got = L.eval('G.collisionShort({ resultProposalData = { collisionInfo = { collisionEntities = { { entity = 123 }, { entity = 456 }, { entity = 123 } }, buildingEntities = { 789 } } } })')
    check(got == " [in the way: town building 123 (owner -1), vehicle 456 (owner 7), construction 789]", "what was in the way: each entity once, its kind and owner", got)
    check(L.eval("G.collisionShort({ resultProposalData = { collisionInfo = { collisionEntities = {}, buildingEntities = {} } } })") == "", "  nothing in the way: nothing added")
    check(L.eval("G.collisionShort(nil)") == "", "  no result: nothing added")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
