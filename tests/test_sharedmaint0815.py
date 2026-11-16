"""Offline test of the shared maintenance's script side (0.8.15, Discord 2026-11-15: Chris P. Bacon and Getriebesand, the other
companies' vehicles were never maintained at an open depot): mpfever_eco.lua E.maintTable, E.maintSync, E.maintResolve,
E.maintTolls, the depot setting's entities (co_depot_rule) and E.tick, through lupa (Lua 5.2) with a mocked game API, as
tests/test_ai_bankrupt.py does.

The engine maintains a vehicle only at a depot of its own company; the native module (InstallSharedMaint) lets the depots another
company opened take every company's vehicles. That is a simulation rule: every game must use the same table at the same step, so
the table is made from the companies' registry alone (kept in the savegame) and handed to the module through os.getenv.
Cases:
  - the table: off outside the companies mode, with MPFEVER_SHAREDMAINT=0 or MPFEVER_SHAREDDEPOTS=0 (the host's session
    setting); everything open when the host turned the sharing rules off; each company's rule (open, toll = open, private);
    the depots with a setting of their own by their entities (sorted, a gone company's open); the same text whatever order
    the settings were made in;
  - the protocol: the module asked whether the table is the one in use ("\\1MPFMT <token>"), sent ("\\1MPFMD <token> <table>")
    only when it answers "send"; a new table, a new token; a refusal said once in the log;
  - the native module's parser and decision (MaintGetenv, MtOpen), made again here, read the script's table as meant;
  - the depot setting keeps its depot entities; every 50 steps they are checked and found again after a rebuild; a setting whose
    depot is gone is looked for again every 1500 steps only;
  - the month's toll: a vehicle of another company maintained at a toll depot pays its toll to the depot's company (summed per
    pair, booked for both, noted in the toll totals and "paid to" kind d); the depot's own vehicles, an open or private depot,
    the sharing rules off: nothing; no toll anywhere: no depot looked at;
  - E.tick charges it at a new month only, and checks the entities;
  - the bridge gives the table at every simulation step after the economy, and the autotest scenario maintshare exists.
Needs lupa (pip install lupa). Run: python tests/test_sharedmaint0815.py
"""
import os, re, sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
NATIVE = os.path.join(HERE, "..", "native", "mpfever_native.cpp")

MOCK = r'''
ENVOVR = {}
do
  local og = os.getenv
  os.getenv = function(k) local v = ENVOVR[k] if v ~= nil then if v == "" then return nil end return v end return og(k) end
end
TIME = 0
BAL = {}
BOOKS = {}
COMP = {}          -- COMP[entity][type] = component
DEPOTS = {}        -- the VEHICLE_DEPOT entities
CONS = {}          -- the CONSTRUCTION entities
MAINT = {}         -- MAINT[depot] = { vehicles }
DEPOTCON = {}      -- depot -> its construction
EACH = 0
api = {
  type = { JournalEntry = { new = function() return { category = {} } end,
      Type = { OTHER = 1, MAINTENANCE = 2, INCOME = 3 }, Maintenance = { VEHICLE_MAINTENANCE = 4, INFRASTRUCTURE = 5 },
      Carrier = { OTHER = 6 }, Construction = { DEPOT = 7 } },
    Vec3f = { new = function() return {} end },
    ComponentType = { PLAYER_OWNED = "po", NAME = "name", CONSTRUCTION = "con", VEHICLE_DEPOT = "depot", TRANSPORT_VEHICLE = "tv" } },
  util = { getDefaultMonthDuration = function() return 100000 end },
  cmd = { sendCommand = function() end,
    makeJournalBookAssetCmd = function(ent, e) BAL[ent] = (BAL[ent] or 0) + e.amount; BOOKS[#BOOKS + 1] = { ent = ent, e = e } return {} end },
  engine = {
    getComponent = function(e, t) return COMP[e] and COMP[e][t] or nil end,
    entityExists = function(e) return COMP[e] ~= nil end,
    forEachEntityWithComponent = function(fn, t)
      EACH = EACH + 1
      local l = t == "depot" and DEPOTS or (t == "con" and CONS or {})
      for _, e in ipairs(l) do fn(e) end
    end,
    util = { finance = { getPlayersBalance = function(p) return BAL[p] or 0 end } },
    system = {
      streetConnectorSystem = { getConstructionEntityForDepot = function(d) return DEPOTCON[d] or -1 end },
      transportVehicleSystem = { getVehiclesForMaintenanceStation = function(d) return MAINT[d] or {} end },
    } },
}
R = { allEdges = function() return {} end,
  entitiesWith = function(n) if n == "CONSTRUCTION" then return CONS end return {} end,
  ownerOf = function(e) local p = COMP[e] and COMP[e].po return p and p.player or nil end, sgKey = function(s) return "sg" .. s end,
  withoutAssets = function(l) return l end }
LOG = {}
ENV = { log = function(s) LOG[#LOG + 1] = s end, R = R, STEP = 200, gameTime = function() return TIME end, journalCarrier = function() return 1 end }
-- a depot: its construction (file and place: its key "D:<file>@x,y") with its depot entities, owned by a player
function depot(con, file, x, y, owner, ents)
  COMP[con] = { con = { fileName = file, transf = { [13] = x, [14] = y }, depots = ents }, po = { player = owner } }
  CONS[#CONS + 1] = con
  for _, d in ipairs(ents) do COMP[d] = { depot = {}, po = { player = owner } }; DEPOTS[#DEPOTS + 1] = d; DEPOTCON[d] = con end
end
function vehicle(v, owner) COMP[v] = { tv = {}, po = { player = owner } } end
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def world(env=None):
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    for k, v in (env or {}).items():
        L.execute('ENVOVR["%s"] = "%s"' % (k, v))
    CO = L.execute(open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read())
    L.globals().CO = CO
    L.execute("ENV.CO = CO")
    E = L.execute(open(os.path.join(CONTENT, "mpfever_eco.lua"), encoding="utf-8").read())
    L.globals().E = E
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    # the host's company (savegame's, entity 100) and bob's (entity 200); host depots 501/502 (one construction) and 503, bob's 601
    run('''
st = { co = CO.new("separate", 100, 2000000) }
CO.join(st.co, "host", "Host", true, "Host Co", "s1", 1)
local b = CO.join(st.co, "bob", "Bob", false, "Bob Co", "s2", 2); b.ent = 200
depot(5000, "depot/bus_era_a.con", 10, 20, 100, { 501, 502 })
depot(5030, "depot/train_era_a.con", 30, 40, 100, { 503 })
depot(6000, "depot/bus_era_a.con", 50, 60, 200, { 601 })
E.env = ENV
''')
    return L, run


# ---- the native module's reading of the table, made again from mpfever_native.cpp's MaintGetenv / MtOpen
def native_parse(text):
    t = [int(x) for x in text.split()]
    on, default, nco = t[0], t[1], t[2]
    co = [(t[3 + 2 * i], t[4 + 2 * i]) for i in range(nco)]
    k = 3 + 2 * nco
    ndep = t[k]
    dep = [(t[k + 1 + 2 * i], t[k + 2 + 2 * i]) for i in range(ndep)]
    assert len(t) == k + 1 + 2 * ndep, "the table has the counts it says"
    assert all(dep[i][0] < dep[i + 1][0] for i in range(len(dep) - 1)), "depots sorted, each once"
    return on, default, co, dep


def native_open(text, depot, owner):
    on, default, co, dep = native_parse(text)
    if not on:
        return None   # the engine's own rule
    for d, o in dep:
        if d == depot:
            return o != 0
    for p, o in co:
        if p == owner:
            return o != 0
    return default != 0


def main():
    src = open(os.path.join(CONTENT, "mpfever_eco.lua"), encoding="utf-8").read()
    for fn in ("E.maintTable", "E.maintSync", "E.maintResolve", "E.maintTolls", "E.depotEntsOf"):
        check(fn + " exists", ("function " + fn + "(") in src)

    print("-- the table")
    L, run = world()
    check("on by default", run("return E.SHARED_MAINT") is True)
    check("every company open by default (savegame's 100, bob's 200), no depot of its own setting",
          run("return E.maintTable(st.co)") == "1 1 2 100 1 200 1 0", run("return E.maintTable(st.co)"))
    run('st.co.mode = "shared"')
    check("outside the companies mode: off", run("return E.maintTable(st.co)") == "0 1 0 0")
    run('st.co.mode = "separate"')
    check("no registry: off", run("return E.maintTable(nil)") == "0 1 0 0")
    run('st.co.depotCo = { ["2"] = { rule = "private", toll = 0 } }')
    check("bob's rule private: his depots keep his vehicles only", run("return E.maintTable(st.co)") == "1 1 2 100 1 200 0 0", run("return E.maintTable(st.co)"))
    run('st.co.depotCo = { ["2"] = { rule = "toll", toll = 500 } }')
    check("a toll is open", run("return E.maintTable(st.co)") == "1 1 2 100 1 200 1 0")
    run('st.co.rules = { share = false }; st.co.depotCo = { ["2"] = { rule = "private", toll = 0 } }')
    check("the host turned the sharing rules off: every depot open", run("return E.maintTable(st.co)") == "1 1 0 0")
    run('st.co.rules = nil; st.co.depotCo = nil')
    run('st.co.depots = { ["D:depot/bus_era_a.con@10,20"] = { rule = "private", toll = 0, co = 1, ents = { 502, 501 } }, '
        '["D:depot/train_era_a.con@30,40"] = { rule = "toll", toll = 300, co = 1, ents = { 503 } } }')
    t1 = run("return E.maintTable(st.co)")
    check("the depots with their own setting by their entities, sorted (private 501 502, toll 503)", t1 == "1 1 2 100 1 200 1 3 501 0 502 0 503 1", t1)
    run('local d = st.co.depots; st.co.depots = {}; st.co.depots["D:depot/train_era_a.con@30,40"] = d["D:depot/train_era_a.con@30,40"]; '
        'st.co.depots["D:depot/bus_era_a.con@10,20"] = d["D:depot/bus_era_a.con@10,20"]')
    check("the same text whatever order the settings were made in", run("return E.maintTable(st.co)") == t1)
    run('CO.find(st.co, 1).gone = "bankrupt"')
    check("a gone company's private depot is open (as E.depotRule)", run("return E.maintTable(st.co)").endswith("3 501 1 502 1 503 1"), run("return E.maintTable(st.co)"))
    run('CO.find(st.co, 1).gone = nil')
    check("the native module reads it: the host's private depot 501 keeps bob's vehicles out", native_open(t1, 501, 100) is False)
    check("  its toll depot 503 takes them", native_open(t1, 503, 100) is True)
    check("  bob's depot 601 (his rule: open) takes the host's", native_open(t1, 601, 200) is True)
    check("  off: the engine's own rule", native_open("0 1 0 0", 601, 200) is None)
    check("  a company not in the table: the default", native_open("1 1 0 0", 601, 999) is True and native_open("1 0 0 0", 601, 999) is False)
    for env in ({"MPFEVER_SHAREDMAINT": "0"}, {"MPFEVER_SHAREDDEPOTS": "0"}):
        L2, run2 = world(env)
        check(list(env)[0] + "=0: off", run2("return E.maintTable(st.co)") == "0 1 0 0", run2("return E.maintTable(st.co)"))

    print("-- the protocol with the native module")
    L, run = world()
    run('''
CALLS = {}
NATIVE = nil
function fake(name)
  CALLS[#CALLS + 1] = name
  local kind, rest = name:match("^\\1MPFM(%u) (.*)$")
  if kind == "T" then return (NATIVE ~= rest) and "send" or nil end
  if kind == "D" then NATIVE = rest:match("^(%d+) "); TABLE = rest:match("^%d+ (.*)$") return "ok" end
  return nil
end
''')
    a1 = run("return E.maintSync(st.co, fake)")
    check("first step: asked, then the table given", a1 == "ok" and run("return #CALLS") == 2 and run("return CALLS[2]:sub(1, 6)") == "\x01MPFMD", run("return #CALLS"))
    check("  the table given is E.maintTable's", run("return TABLE") == run("return E.maintTable(st.co)"))
    run("E.maintSync(st.co, fake); E.maintSync(st.co, fake)")
    check("the next steps: asked only", run("return #CALLS") == 4 and run("return CALLS[4]:sub(1, 6)") == "\x01MPFMT")
    tok1 = run("return E.mtTok")
    run('st.co.depotCo = { ["2"] = { rule = "private", toll = 0 } }')
    run("E.maintSync(st.co, fake)")
    check("a rule changed: a new token, the table given again", run("return E.mtTok") != tok1 and run("return #CALLS") == 6
          and run("return TABLE") == "1 1 2 100 1 200 0 0", run("return TABLE"))
    run("NATIVE = nil")
    run("E.maintSync(st.co, fake)")
    check("a game loaded (the module forgot it): given again", run("return #CALLS") == 8)
    run('function refusing(name) if name:sub(1, 6) == "\\1MPFMT" then return "send" end return "bad" end')
    run("LOG = {}; ENV.log = function(s) LOG[#LOG + 1] = s end; E.maintSync(st.co, refusing); E.maintSync(st.co, refusing)")
    check("a refusal is said once in the log", run("local n = 0 for _, l in ipairs(LOG) do if l:find('refused the table', 1, true) then n = n + 1 end end return n") == 1)
    run("CALLS = {}; NATIVE = 'x'")
    check("no native module (getenv says nothing): asked only, no error", run("return E.maintSync(st.co, function() return nil end)") is None)

    print("-- the depot setting's entities")
    L, run = world()
    run('E.event(st, "co_depot_rule", { key = "D:depot/bus_era_a.con@10,20", rule = "private", mpfCo = 1, mpfFrom = "Host" }, ENV)')
    check("co_depot_rule keeps the depot's entities with its setting", run('return table.concat(st.co.depots["D:depot/bus_era_a.con@10,20"].ents, ",")') == "501,502",
          run('return tostring(st.co.depots["D:depot/bus_era_a.con@10,20"] and st.co.depots["D:depot/bus_era_a.con@10,20"].ents)'))
    check("  and the table has them", run("return E.maintTable(st.co)").endswith("2 501 0 502 0"))
    check("not a step of the check (every 50): nothing", run("return E.maintResolve(st.co, 51)") is False)
    run("EACH = 0")
    check("its entities still there: nothing changed, no depot looked for", run("return E.maintResolve(st.co, 100)") is False and run("return EACH") == 0)
    # the depot rebuilt: its entities gone, new ones at the same place
    run('COMP[501] = nil; COMP[502] = nil; DEPOTS = { 503, 601 }; depot(5001, "depot/bus_era_a.con", 10, 20, 100, { 701 })')
    check("rebuilt: found again at the next check", run("return E.maintResolve(st.co, 150)") is True
          and run('return table.concat(st.co.depots["D:depot/bus_era_a.con@10,20"].ents, ",")') == "701")
    run('COMP[701] = nil; DEPOTS = { 503, 601 }')
    check("removed: no entity left", run("return E.maintResolve(st.co, 200)") is True and run('return #st.co.depots["D:depot/bus_era_a.con@10,20"].ents') == 0)
    run("EACH = 0")
    check("  not looked for again before 1500 steps", run("return E.maintResolve(st.co, 250)") is False and run("return EACH") == 0)
    run("E.maintResolve(st.co, 1500)")
    check("  looked for again at step 1500", run("return EACH") == 1)
    run('st.co.depots["D:depot/train_era_a.con@30,40"] = { rule = "open", toll = 0, co = 1 }')
    check("a setting of an earlier version (no entities): found at the next check", run("return E.maintResolve(st.co, 1550)") is True
          and run('return table.concat(st.co.depots["D:depot/train_era_a.con@30,40"].ents, ",")') == "503")
    L2, run2 = world({"MPFEVER_SHAREDMAINT": "0"})
    run2('E.event(st, "co_depot_rule", { key = "D:depot/bus_era_a.con@10,20", rule = "private", mpfCo = 1, mpfFrom = "Host" }, ENV)')
    check("MPFEVER_SHAREDMAINT=0: the setting as before (no entities)", run2('return st.co.depots["D:depot/bus_era_a.con@10,20"].ents') is None)

    print("-- the month's toll")
    L, run = world()
    run('vehicle(9001, 200); vehicle(9002, 100); vehicle(9003, 200); vehicle(9004, 200)')
    run('MAINT[501] = { 9003, 9001, 9002 }; MAINT[503] = { 9004 }')
    run("EACH = 0")
    check("no toll anywhere: nothing, no depot looked at", run("return E.maintTolls(st, ENV)") is False and run("return EACH") == 0)
    run('st.co.depotCo = { ["1"] = { rule = "toll", toll = 777 } }')
    check("the host's depots at a toll: charged", run("return E.maintTolls(st, ENV)") is True)
    check("  bob pays 3 x 777 (two vehicles at 501, one at 503; the host's own vehicle free)", run("return BAL[200]") == -2331, run("return BAL[200]"))
    check("  the host gets it", run("return BAL[100]") == 2331)
    check("  booked once per pair (two entries)", run("return #BOOKS") == 2)
    check("  as vehicle maintenance for bob", run("return BOOKS[1].e.category.type == api.type.JournalEntry.Type.MAINTENANCE and BOOKS[1].e.category.maintenance == api.type.JournalEntry.Maintenance.VEHICLE_MAINTENANCE") is True)
    check("  revenue for the host", run("return BOOKS[2].e.category.type == api.type.JournalEntry.Type.INCOME") is True)
    check("  the toll totals and 'paid to' (kind d)", run("return st.co.tollIncome['1'] .. '/' .. st.co.tollExpense['2'] .. '/' .. st.co.paidTo['2>1:d']") == "2331/2331/2331")
    run('BAL = {}; BOOKS = {}; st.co.depots = { ["D:depot/train_era_a.con@30,40"] = { rule = "open", toll = 0, co = 1, ents = { 503 } } }')
    run("E.maintTolls(st, ENV)")
    check("a depot of its own setting open: free (only 501's two)", run("return BAL[200]") == -1554, run("return BAL[200]"))
    run('BAL = {}; st.co.rules = { share = false }')
    check("the sharing rules off: nothing", run("return E.maintTolls(st, ENV)") is False and run("return BAL[200]") is None)
    run('st.co.rules = nil; BAL = {}; st.co.depotCo = { ["1"] = { rule = "private", toll = 777 } }; st.co.depots = nil')
    check("private: nothing", run("return E.maintTolls(st, ENV)") is False)

    print("-- E.tick")
    L, run = world()
    run('vehicle(9001, 200); MAINT[501] = { 9001 }; st.co.depotCo = { ["1"] = { rule = "toll", toll = 100 } }')
    run("TIME = 0; E.tick(st, ENV)")
    run("TIME = 50000; E.tick(st, ENV)")
    check("no toll before the next month", run("return BAL[200]") is None)
    run("TIME = 100000; E.tick(st, ENV)")
    check("the new month: charged once", run("return BAL[200]") == -100, run("return BAL[200]"))
    run("TIME = 100200; E.tick(st, ENV)")
    check("  and not again in that month", run("return BAL[200]") == -100)
    run('st.co.depots = { ["D:depot/train_era_a.con@30,40"] = { rule = "open", toll = 0, co = 1 } }')
    check("E.tick checks the depots' entities (step 1000)", run("TIME = 200000; return E.tick(st, ENV)") is True
          and run('return table.concat(st.co.depots["D:depot/train_era_a.con@30,40"].ents or {}, ",")') == "503")

    print("-- the bridge and the native module")
    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
    m = re.search(r"^local function update\(userParams, state, dt\)\n.*?^end\n", bridge, re.S | re.M)
    body = m.group(0) if m else ""
    check("the simulation's update gives the table at every step", "eco.maintSync(st.co)" in body)
    check("  after the economy's tick of that step", body.find("C.eco().tick(st, SIM.ecoEnv())") < body.find("eco.maintSync(st.co)"))
    check("the autotest scenario maintshare", "H.maintshare = function(from, p)" in bridge)
    nat = open(NATIVE, encoding="utf-8").read()
    check("the native module reads the same names (\\1MPFM T/D)", "name[0] == 1 && name[1] == 'M' && name[2] == 'P' && name[3] == 'F' && name[4] == 'M'" in nat
          and "s[0] == 'T' && s[1] == ' '" in nat and "s[0] == 'D' && s[1] == ' '" in nat)
    check("  and answers \"send\" / \"ok\" as the script expects", 'return same ? 0 : (char*)"send";' in nat and 'return (char*)"ok";' in nat)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
