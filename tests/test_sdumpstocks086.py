"""Offline test: the drift dump holds the cargo waiting in each stock, the industries' stock lists and the cargo on board by line
(0.8.6, #150; SDUMP.stocks in mod/mpfever_1/content/mpfever_bridge.script.lua).

#274 (Jakob and Peter, 2026-11-12 22:39): the drift began as one cargo item more on one game ("stocks" 22969/22970, then a cargo
item removed by the engine's StockListSystem on one game only). The dumps of both games were alike: they held no stock.
  - each stock with cargo: its holder's kind and place (a station, an industry, a town building), its stock number, its items;
  - each industry: the hash of its stock list component and its rules' state;
  - the cargo on board, by line;
  - a stock map key as a table {entity, stock} or with named fields;
  - MPFEVER_SDUMPSTOCKS=0: nothing;
  - the dump's world part calls it.
Needs lupa (pip install lupa). Run: python tests/test_sdumpstocks086.py
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
a = src.index("function SDUMP.stocks(dump)")
b = src.index("local function extendedParts(parts, checkN)")
code = src[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
SDUMP = {}
local function T(x, y) local t = {} for i = 1, 16 do t[i] = 0 end t[13] = x t[14] = y return t end
COMP = {
  [10] = { CONSTRUCTION = { fileName = "station/rail/modular_station.con", transf = T(100, 200), stations = { 11 }, industries = {}, townBuildings = {} } },
  [20] = { CONSTRUCTION = { fileName = "industries/farm/farm.con", transf = T(-50, 75), stations = {}, industries = { 21 }, townBuildings = {} } },
  [21] = { INDUSTRY = { stockList = 22 } },
  [22] = { STOCK_LIST = { thrownAwayCargo = 3, ruleDatas = { { progress = 0.25 } } } },
  [30] = { CONSTRUCTION = { fileName = "building/town/res_1.con", transf = T(5, 6), stations = {}, industries = {}, townBuildings = { 31 } } },
  [40] = { TRANSPORT_VEHICLE = { line = 41 } },
  [41] = { NAME = { name = "Bus 1" } },
}
api = { type = { ComponentType = { CONSTRUCTION = "CONSTRUCTION", INDUSTRY = "INDUSTRY", STOCK_LIST = "STOCK_LIST", TOWN_BUILDING = "TOWN_BUILDING",
  TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE", NAME = "NAME" } },
  engine = { getComponent = function(e, t) return COMP[e] and COMP[e][t] or nil end,
    system = { simEntityAtStockSystem = { getStock2SimEntityMap = function() return MAP end },
      simEntityAtVehicleSystem = { getVehicle2Cargo2SimEntitesMap = function() return { [40] = { [1] = { 1, 2 }, [3] = { 4 } } } end } } } }
MAP = { [{ 11, 0 }] = { 1, 2, 3 }, [{ entity = 21, stockId = 1 }] = { 7 }, [{ 31, 2 }] = { 8, 9 } }
R = { entitiesWith = function(k)
  local out = {} for e, c in pairs(COMP) do if c[k] then out[#out + 1] = e end end table.sort(out) return out end,
  matPos = function(t) return { x = t[13], y = t[14], z = 0 } end }
C = { dump = function(v) local s = "" for k, x in pairs(v) do s = s .. tostring(k) .. "=" .. tostring(x) .. " " end return s end,
  hashStr = function(h, s) return #s end }
''' + code)


def dump():
    L.execute("D = {}; SDUMP.stocks(D); table.sort(D)")
    return [L.eval("D[%d]" % i) for i in range(1, int(L.eval("#D")) + 1)]


d = dump()
txt = "\n".join(d)
check("~stock station modular_station.con@100,200 s0 = 3" in txt, "a station's stock: holder kind and place, stock, items", txt)
check("~stock industry farm.con@-50,75 s1 = 1" in txt, "a key with named fields (entity, stockId)", txt)
check("~stock townbuilding res_1.con@5,6 s2 = 2" in txt, "a town building's stock", txt)
check(any(l.startswith("~stocklist industry farm.con@-50,75 = #") and "thrown 3" in l and "rules" in l for l in d), "an industry's stock list (on the entity it names): hash, thrown away cargo, rules", txt)
check("~onboard Bus 1 = 3" in txt, "the cargo on board by line", txt)
L.execute('ENV.MPFEVER_SDUMPSTOCKS = "0"')
check(dump() == [], "MPFEVER_SDUMPSTOCKS=0: nothing")
w = src.index("local function extendedParts(parts, checkN)")
check("pcall(SDUMP.stocks, dump)" in src[w:w + 12000], "the dump's world part calls it")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
