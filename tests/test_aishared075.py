"""Offline test of the computer companies and the other companies' stops (0.7.5, SH in mpfever_ai.lua).

The user, 2026-11-07: a computer company put its stops in towns where a player already had stops it could share; it should not
add stops to a town that has some, and decide for itself whether the shared stops are worth using, free or with a toll; with
closed stops, Easy stays out of the town, Normal stays out unless it has no other choice, Hard may build its own. Now:
  - SH.others lists the other companies' street stops (their company, their town); SH.use reads a stop's rule for this company
    (eco.stationRule): open = used, a toll up to the level's limit (Easy 0, Normal 150, Hard 400) = used, more = too dear, private
    = closed; a toll stop of a line it gave up for losing money = too dear from then on;
  - SH.pick makes a town's line of up to four of the usable stops, 300 m apart, chained; fewer than two: none;
  - SH.mayBuild: Hard builds its own stops in a town whose stops are closed to it, Normal only when no town free of the other
    companies' stops is left, Easy never;
  - in the town loop and the lines between two towns: no stop of its own in such a town; the line goes through the others' stops;
  - MPFEVER_AISHARED=0: its own stops everywhere, as before.
Needs lupa (pip install lupa). Run: python tests/test_aishared075.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ai.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local SH = { TOLL")
j = src.find("local function myDepots(E, ent)", i)
check(i > 0 and j > i, "the SH helpers found")
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function L(E, s) LOGS[#LOGS + 1] = s end
local function dist0(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
dist = dist0
LV = { name = "normal" }
OWNER = {}
function ownerOf(E, e) return OWNER[e] end
-- the world: edges with one stop each; stop entity -> group, town, company
EDGES = {}
STOPS = {}
function addStop(e, x, y, owner, co, group, town)
  EDGES[#EDGES + 1] = { e = 1000 + e, n0 = { x = x - 10, y = y, z = 0 }, n1 = { x = x + 10, y = y, z = 0 }, obj = e }
  OWNER[e] = owner
  STOPS[e] = { group = group, town = town, co = co }
end
RULES = {}
E = { G = { frames = 0, AI = {}, co = { list = {} } }, CO = { idOfEntity = function(reg, ent) return ({ [11] = 1, [22] = 2, [33] = 3 })[ent] end },
  R = { allEdges = function() local t = {} for _, x in ipairs(EDGES) do t[#t + 1] = x.e end return t end,
        sgKey = function(g) return "k" .. g end },
  C = { eco = function() return { stationRule = function(reg, key, co) local r = RULES[key] or { "open", 0 } return r[1], r[2], true end } end },
  api = { type = { ComponentType = { BASE_EDGE = 1, STATION = 2 } },
          engine = { getComponent = function(e, t)
              if t == 1 then for _, x in ipairs(EDGES) do if x.e == e then return { node0 = x.n0, node1 = x.n1, objects = { { x.obj, 1 } } } end end return nil end
              if t == 2 then return STOPS[e] and {} or nil end end,
            system = { stationGroupSystem = { getStationGroup = function(eo) return STOPS[eo].group end },
                       stationSystem = { getTown = function(eo) return STOPS[eo] and STOPS[eo].town or -1 end } } } },
  nodePosition = function(n) return n end }
''')
L.execute(src[i:j].replace("local SH = {", "SH = {", 1))
# town 500: company 1 (entity 11) has three stops, open; company 2 one stop with a toll of 100, one with 300; company 3 one private
L.execute('''
addStop(1, 0, 0, 11, 1, 101, 500); addStop(2, 400, 0, 11, 1, 102, 500); addStop(3, 800, 0, 11, 1, 103, 500)
addStop(4, 0, 600, 22, 2, 104, 600); RULES["k104"] = { "toll", 100 }
addStop(5, 600, 600, 22, 2, 105, 600); RULES["k105"] = { "toll", 300 }
addStop(6, 0, 2000, 33, 3, 106, 700); RULES["k106"] = { "private", 0 }
addStop(7, 50, 0, 99, nil, 107, 500)
''')
me = 44
n = L.eval("#SH.others(E, %d)" % me)
check(n == 6, "the other companies' stops listed, a stop of no company left out: %d" % n)
check(L.eval('(SH.use(E, { group = 101, co = 1 }))') == "use", "an open stop: used")
L.execute('LV.name = "normal"')
check(L.eval('(SH.use(E, { group = 104, co = 2 }))') == "use", "Normal: a toll of 100 worth paying")
check(L.eval('(SH.use(E, { group = 105, co = 2 }))') == "dear", "Normal: a toll of 300 too dear")
L.execute('LV.name = "easy"')
check(L.eval('(SH.use(E, { group = 104, co = 2 }))') == "dear", "Easy: any toll too dear")
L.execute('LV.name = "hard"')
check(L.eval('(SH.use(E, { group = 105, co = 2 }))') == "use", "Hard: a toll of 300 worth paying")
check(L.eval('(SH.use(E, { group = 106, co = 3 }))') == "closed", "a private stop: closed")
L.execute('E.G.AI.tollBad = { [104] = true }; LV.name = "normal"')
check(L.eval('(SH.use(E, { group = 104, co = 2 }))') == "dear", "a toll stop of a line given up for losing money: too dear")
L.execute('E.G.AI.tollBad = nil')

all_n, use_n = L.eval("(function() local a, u = SH.town(E, %d, 500) return #a, #u end)()" % me)
check((all_n, use_n) == (3, 3), "town 500: three stops of company 1, all usable")
chain = L.eval("(function() local c = SH.pick(select(2, SH.town(E, %d, 500)), { x = 400, y = 0 }) local t = {} for _, s in ipairs(c) do t[#t + 1] = s.group end return table.concat(t, ',') end)()" % me)
check(chain in ("101,102,103", "103,102,101"), "its line: the three stops chained from an end: " + str(chain))
L.execute('LV.name = "normal"')
use600 = L.eval("(function() local a, u = SH.town(E, %d, 600) return #a, #u end)()" % me)
check(use600 == (2, 1), "town 600 for Normal: two stops, one usable (the toll of 300 too dear)")
check(L.eval("SH.pick(select(2, SH.town(E, %d, 600)), { x = 0, y = 600 })" % me) is None, "one usable stop only: no line through them")
check(L.eval("SH.near(E, %d, 500, { x = 380, y = 20 })" % me)["group"] == 102, "a usable stop near a point: the nearest within 800 m")
check(L.eval("SH.near(E, %d, 500, { x = 2000, y = 2000 })" % me) is None, "none within 800 m: none")
check(L.eval("SH.near(E, %d, 500, { x = 790, y = 0 }, 'P1')" % me)["group"] == 103, "a point's stop chosen (103, the nearest)")
check(L.eval("SH.near(E, %d, 500, { x = 0, y = 0 }, 'P1')" % me)["group"] == 103, "and kept for that point while it may use it (not 101, nearer now): no second line")
L.execute('RULES["k103"] = { "private", 0 }; E.G.AI.othersCache = nil')
check(L.eval("SH.near(E, %d, 500, { x = 0, y = 0 }, 'P1')" % me)["group"] == 101, "a kept stop closed since: the nearest usable one instead")
L.execute('RULES["k103"] = nil; E.G.AI.othersCache = nil')

L.execute('LV.name = "easy"')
check(L.eval("SH.mayBuild(false)") is False and L.eval("SH.mayBuild(true)") is False, "Easy never builds its own in a town whose stops are closed to it")
L.execute('LV.name = "normal"')
check(L.eval("SH.mayBuild(true)") is False and L.eval("SH.mayBuild(false)") is True, "Normal: only when no free town is left")
L.execute('LV.name = "hard"')
check(L.eval("SH.mayBuild(true)") is True, "Hard: builds its own")
L.execute('ENV.MPFEVER_AISHARED = "0"')
check(L.eval("SH.on()") is False, "MPFEVER_AISHARED=0: off")

# selling the stops it no longer wants (0.7.5)
L.execute('''
E.G.featOpts = "stats=1;sales=1;contracts=0"
E.G.co.list = { { id = 1, key = "bob", ent = 11 }, { id = 2, key = "ann", ent = 22 }, { id = 3, key = "ai:2", ent = 33, ai = true } }
LINES = { { e = 900, owner = 22, stops = { 101, 102 } }, { e = 901, owner = 33, stops = { 101, 101, 101 } } }
E.R.entitiesWith = function(k) local t = {} for _, l in ipairs(LINES) do t[#t + 1] = l.e end return t end
local gc = E.api.engine.getComponent
E.api.type.ComponentType.LINE = 3
E.api.engine.getComponent = function(e, t)
  if t == 3 then for _, l in ipairs(LINES) do if l.e == e then local st = {} for k, g in ipairs(l.stops) do st[k] = { stationGroup = g } end return { stops = st } end end end
  return gc(e, t)
end
OWNER[900] = 22; OWNER[901] = 33
''')
check(L.eval("SH.salesOn(E)") is True, "the host's option sales on: read from its options")
L.execute('E.G.featOpts = "sales=0"')
check(L.eval("SH.salesOn(E)") is False, "sales off: nothing offered")
check(L.eval("SH.buyer(E, { ent = %d }, { group = 101, station = 1 })" % me) == 2,
      "the buyer: the player company whose lines stop there (company 2), never a computer company (company 3 stops there more)")
check(L.eval("SH.buyer(E, { ent = %d }, { group = 103, station = 3 })" % me) == 1,
      "no line stops there: the player company with the most stops in its town (company 1)")
check(L.eval("SH.player(E, 3)") is False and L.eval("SH.player(E, 1)") is True, "a computer company is no buyer")
L.execute('E.gameTime = function() return NOWT end; NOWT = 1000000; E.G.AI.sale = { ["k101"] = 1000000 - 100 }')
check(L.eval("SH.onSale(E, 101)") is True and L.eval("SH.onSale(E, 102)") is False, "a stop offered less than three months ago is on sale")
q = src.find("if A.deadGroups and period == 7200 and SH.on() and os.getenv(\"MPFEVER_AISELL\") ~= \"0\" and SH.sell(E, co, lines) then return true end")
d = src.find("if A.deadGroups and period == 7200 and os.getenv(\"MPFEVER_AIDEMOLISH\") == \"1\" then")
check(0 < q < d and "not onSale" in src[d:d + 1500], "offered before it is ever demolished; demolished (MPFEVER_AIDEMOLISH=1) only when its sale is over")
check('[3] = "f_trade_offer"' in src and "SH.act = act" in src, "the offer goes through the game option's event, as a player's")

# the integration
k = src.find("local ownTown, freeLeft = {}, false")
check(k > 0 and "if #all == 0 then freeLeft = true end" in src[k:k + 1200], "the town loop knows whether a free town is left")
t = src.find("local shared", k)
seg = src[t:t + 3000]
check("shared = shared or SH.pick(usable, tc)" in seg and "A.sharedTown[town] = gs" in seg and "goto continue" in seg and "SH.mayBuild(freeLeft)" in seg, "a town with the others' stops: their stops, or left, or its own by level")
check("elseif #usable > 0 then" in seg and seg.find("elseif #usable > 0 then") < seg.find("elseif not SH.mayBuild(freeLeft) then"),
      "a town with usable stops too few or too close for a town line: left, never its own stops beside them (test ai77)")
check("for _, s in ipairs(shared) do have[#have + 1] = { stop = s } end" in seg and "have, missing = townProject(E, co, town, stops)" in seg,
      "the line made of their stops, nothing to build; else the town's project as before")
p = src.find("local function pairProject(")
pair = src[p:src.find("\nend\n", p)]
check("elseif #usableT > 0 or not SH.mayBuild(true) then" in pair, "a pair's town with usable stops, none near the point: the pair left, never its own stops")
check('SH.near(E, co.ent, w.town, w.p.p, pair.key .. "@" .. w.town .. ":" .. w.p.use)' in pair and "SH.mayBuild(true)" in pair, "a line between two towns: the others' stop near each point, or the pair left by level")
check("if not (SH.on() and groups[#groups] == s.group) then groups[#groups + 1] = s.group end" in pair,
      "two points of a town served by the same shared stop: the stop once on the line (no A A B B)")
f = src.find("local function townFreightProject(")
fr = src[f:src.find("\nend\n", f)]
check('SH.near(E, co.ent, f.town, f.p, "freight@" .. f.key, 250)' in fr and "elseif #usableT > 0 or not SH.mayBuild(true) then" in fr
      and fr.find("SH.near(") < fr.find("stopNear(E, co, stops, f.p"), "a delivery to a town with the others' stops: their stop near the point, or left (test ai78)")
check("for _, s in ipairs(usable) do" in src[src.find("function SH.near("):src.find("function SH.near(") + 900] and "if d < maxD" in src,
      "the radius of a delivery's stop (250 m) and of a line's (800 m)")
g = src.find("-- (0.7.5, see SH: the other companies' toll stops of a line given up")
check(g > 0 and "A.tollBad[g] = true" in src[g:g + 900], "a toll line given up marks its toll stops too dear")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
