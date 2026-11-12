"""Offline test: a bankrupt company's warehouses are lots of its auction (0.8.3, a player's report, MPFEVER_LOTWAREHOUSE).

"The warehouses were not sold again": E.lotsOf listed the lines, stations and depots only, so a company's warehouses stayed with it
and went to its heir with what was left. Each warehouse it owns is now a lot of its own (kind "warehouse", key W:<file>@x,y), sold
(it changes hands) or, unsold, demolished as a depot is. mpfever_co.lua and mpfever_eco.lua run through lupa (Lua 5.2) with a
mocked engine.
Run: python tests/test_lotwarehouse083.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content")

MOCK = r'''
ENVOVR = {}
do
  local og = os.getenv
  os.getenv = function(k) local v = ENVOVR[k] if v ~= nil then return v end return og(k) end
end
TIME = 0
BAL = {}
OWN = { [501] = 200, [502] = 100, [503] = 200 }
CONS = {
  [501] = { fileName = "warehouses/warehouse.con", transf = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 120,340,5,1 }, depots = {} },
  [502] = { fileName = "warehouses/warehouse.con", transf = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 900,900,5,1 }, depots = {} },
  [503] = { fileName = "depot/train_depot_era_a.con", transf = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 10,10,5,1 }, depots = { 7001 } },
}
api = {
  type = { JournalEntry = { new = function() return { category = {} } end, Type = { OTHER = 1 } }, Vec3f = { new = function() return {} end },
    ComponentType = { PLAYER_OWNED = "po", NAME = "name", CONSTRUCTION = "con" } },
  util = { getDefaultMonthDuration = function() return 1000 end },
  cmd = { sendCommand = function() end, makeJournalBookAssetCmd = function(ent, e) BAL[ent] = (BAL[ent] or 0) + e.amount return {} end,
    makeEntitySetPlayerCmd = function(e, p) OWN[e] = p return {} end },
  engine = {
    getComponent = function(e, ct)
      if ct == "con" then return CONS[e] end
      if ct == "po" then return OWN[e] and { player = OWN[e] } or nil end
      if ct == "name" then return { name = "W" .. tostring(e) } end
      return nil
    end,
    entityExists = function(e) return CONS[e] ~= nil end,
    forEachEntityWithComponent = function() end,
    util = { finance = { getPlayersBalance = function(p) return BAL[p] or 0 end } },
    system = { lineSystem = { getLinesForPlayer = function() return {} end }, transportVehicleSystem = { getDepotVehicles = function() return {} end } } },
}
R = { allEdges = function() return {} end, entitiesWith = function(k) if k == "CONSTRUCTION" then return { 501, 502, 503 } end return {} end,
  ownerOf = function(e) return OWN[e] end, sgKey = function(s) return "sg" .. s end, withoutAssets = function(l) return l end }
LOG = {}
ENV = { log = function(s) LOG[#LOG + 1] = s end, R = R, STEP = 200, gameTime = function() return TIME end, journalCarrier = function() return 1 end }
'''

fails = []


def check(cond, what, got=""):
    print(("  ok    " if cond else "  FAIL  ") + what + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(what)


def world(env=None):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    for k, v in (env or {}).items():
        L.execute('ENVOVR["%s"] = "%s"' % (k, v))
    CO = L.execute(open(os.path.join(here, "mpfever_co.lua"), encoding="utf-8").read())
    L.globals().CO = CO
    L.execute("ENV.CO = CO")
    E = L.execute(open(os.path.join(here, "mpfever_eco.lua"), encoding="utf-8").read())
    L.globals().E = E
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    run('''
st = { co = CO.new("separate", 100, 2000000) }
CO.join(st.co, "host", "Host", true, "Host Co", "s1", 1)
local b = CO.join(st.co, "bob", "Bob", false, "Bob Co", "s2", 2); b.ent = 200
TIME = 0; E.tick(st, ENV)
function lots() local l = E.lotsOf(ENV, CO.find(st.co, 2)) local o = {} for _, x in ipairs(l) do o[#o + 1] = x.kind .. "=" .. x.key .. "/" .. tostring(x.reserve) end return table.concat(o, ";") end
''')
    return L, run


L, run = world()
got = run("return lots()")
check(got == "depot=D:depot/train_depot_era_a.con@10,10/50000;warehouse=W:warehouses/warehouse.con@120,340/50000", "the bankrupt company's warehouse is a lot of its own (after its depot)", got)
check("900,900" not in got, "  not another company's warehouse")
run("local l = E.lotsOf(ENV, CO.find(st.co, 2)) for _, x in ipairs(l) do if x.kind == 'warehouse' then WL = x end end")
n = run("return (E.transferLot(ENV, CO.find(st.co, 2), CO.find(st.co, 1), WL))")
check(run("return OWN[501]") == 100 and n == 1, "sold: the warehouse changes hands", (run("return OWN[501]"), n))
L, run = world({"MPFEVER_LOTWAREHOUSE": "0"})
check("warehouse" not in run("return lots()"), "MPFEVER_LOTWAREHOUSE=0: no warehouse lot, as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
