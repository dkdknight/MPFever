"""Offline test (0.8.14, Discord 2026-11-14/15): one company per player, the vehicle manager also lists the depots the other
companies opened (U.depotOpenToMe and installSharedDepots in mpfever_ui.script.lua).

The game's vehicle manager lists only this company's depots (api.engine.getEntitiesWithComponent(VEHICLE_DEPOT,
{ requireOwnedByPlayer = me })): a depot another company set to open or to a toll could never be chosen to buy a vehicle there.
  - U.depotOpenToMe: another company's depot whose own setting is open or a toll: yes; private: no; "co" (its company's rule): that
    rule; no rule at all: open (as E.depotRule); the sharing rules off (host): yes; a gone company's: yes; this company's own: no;
    outside the companies mode: no;
  - the wrapper adds those depots to a list asked with requireOwnedByPlayer = this player, after this company's own, each once;
    any other call (another component, another player, no owner filter) is returned unchanged; MPFEVER_SHAREDDEPOTS=0: not installed.
Needs lupa. Run: python tests/test_shareddepots0814.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m1 = re.search(r"^U\.depotOpenToMe = function\(e\)\n.*?^end\n", src, re.S | re.M)
m2 = re.search(r"^local function installSharedDepots\(\)\n.*?^end\n", src, re.S | re.M)
check(m1 and m2, "U.depotOpenToMe and installSharedDepots found")
check("pcall(installSharedDepots)" in src, "installed with the other companies' tools (U.coMap)")
opts = open(os.path.join(HERE, "..", "launcher", "Options.cs"), encoding="utf-8").read()
check('Key = "MPFEVER_SHAREDDEPOTS", Session = true, DefaultOn = true, OffValue = "0"' in opts,
      "the host's session setting (lobby), on by default, off = MPFEVER_SHAREDDEPOTS=0 on every game")
if not (m1 and m2):
    sys.exit(1)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENV = {}
os = { getenv = function(k) return ENV[k] end }
LOGS = {}
function log(t) LOGS[#LOGS + 1] = t end
U = { coMap = { [10] = 1, [20] = 2, [30] = 3 }, myCo = 1 }
OWN = { [101] = 10, [102] = 10, [201] = 20, [202] = 20, [203] = 20, [301] = 30 }
KEY = { [201] = "D:a@1,1", [202] = "D:b@2,2", [203] = "D:c@3,3", [301] = "D:d@4,4", [101] = "D:e@5,5" }
function ownerOf(e) return OWN[e] end
U.pollRules = function() end
U.pollEco = function() end
U.rules = { depotCo = {}, gone = {} }
U.eco = { depots = {} }
U.depotInfo = function(e, owner) return KEY[e] and { key = KEY[e] } or nil end
api = { type = { ComponentType = { VEHICLE_DEPOT = 7, STATION = 8 } },
  engine = { util = { getPlayer = function() return 10 end }, system = { streetConnectorSystem = { getConstructionEntityForDepot = function() return -1 end } } } }
api.engine.getEntitiesWithComponent = function(ct, opts)
  local out = {}
  for _, e in ipairs({ 101, 102, 201, 202, 203, 301 }) do
    if not opts or not opts.requireOwnedByPlayer or OWN[e] == opts.requireOwnedByPlayer then out[#out + 1] = e end
  end
  return out
end
""" + m1.group(0) + m2.group(0).replace("local function installSharedDepots", "function installSharedDepots"))
g = L.globals()
ok = L.eval("function(e) return U.depotOpenToMe(e) end")

g.U.eco.depots["D:a@1,1"] = L.eval("{ rule = 'open' }")
g.U.eco.depots["D:b@2,2"] = L.eval("{ rule = 'private' }")
g.U.eco.depots["D:c@3,3"] = L.eval("{ rule = 'toll', toll = 500 }")
check(ok(201) is True, "another company's depot set to open: yes")
check(ok(202) is False, "set to private: no")
check(ok(203) is True, "a toll: yes (the toll is booked by the simulation)")
check(ok(301) is True, "no setting and no company rule: open, as E.depotRule")
g.U.rules.depotCo[3] = L.eval("{ rule = 'private' }")
check(ok(301) is False, "  its company's rule private: no")
g.U.eco.depots["D:d@4,4"] = L.eval("{ rule = 'co' }")
check(ok(301) is False, "  its own setting 'co' (its company's rule): private, no")
g.U.rules.gone[3] = True
check(ok(301) is True, "a gone company's depot: yes")
g.U.rules.gone[3] = None
g.U.rules.off = True
check(ok(202) is True, "the sharing rules off (host): every depot open")
g.U.rules.off = None
check(ok(101) is False, "this company's own depot: not listed twice")
g.U.coMap = None
check(ok(201) is False, "outside the companies mode: no")
g.U.coMap = L.eval("{ [10] = 1, [20] = 2, [30] = 3 }")

L.eval("installSharedDepots")()
get = L.eval("function(ct, o) local r = api.engine.getEntitiesWithComponent(ct, o) table.sort(r) return table.concat(r, ',') end")
mk = L.eval("function(p) return { requireOwnedByPlayer = p } end")
check(get(7, mk(10)) == "101,102,201,203", "the vehicle manager's list: this company's depots and the open ones of the others")
check(get(7, mk(20)) == "201,202,203", "another player's list: unchanged")
check(get(8, mk(10)) == "101,102", "another component: unchanged")
check(get(7, None) == "101,102,201,202,203,301", "no owner filter: unchanged")
g.U.coMap = None
check(get(7, mk(10)) == "101,102", "outside the companies mode: unchanged")

L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
L2.execute("""ENV = { MPFEVER_SHAREDDEPOTS = '0' } os = { getenv = function(k) return ENV[k] end } function log() end U = {}
api = { engine = { getEntitiesWithComponent = function() return {} end } } ORIG = api.engine.getEntitiesWithComponent
""" + m2.group(0).replace("local function installSharedDepots", "function installSharedDepots"))
L2.eval("installSharedDepots")()
check(L2.eval("api.engine.getEntitiesWithComponent == ORIG"), "MPFEVER_SHAREDDEPOTS=0: not installed")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
