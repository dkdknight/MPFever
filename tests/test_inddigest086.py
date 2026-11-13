"""Offline test: "industriesDigest", a diagnostic part of the checks (0.8.6, #150; K.industriesDigest and simHash in
mod/mpfever_1/content/mpfever_bridge.script.lua, DiagnosticParts / NeverLocalParts in launcher/MainForm.cs).

#274: the drift began as one cargo item more on one game ("stocks" 22969/22970, then a removal by the engine's StockListSystem on
one game only), seen in the checks only through "stocks" and "vehicles". The industries' production state (each stock list's
rules' and stocks' runtime data, the cargo thrown away) is now a digest of its own:
  - the same industries in another order: the same digest (an order-free sum);
  - one industry's rule data otherwise: another digest;
  - logged only, never a reason to reload, never "a local measure" (MainForm's diagnostic parts);
  - MPFEVER_INDDIGEST=0: not measured.
Needs lupa (pip install lupa). Run: python tests/test_inddigest086.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = src.index("K.industriesDigest = function()")
b = src.index("\nend\n", a) + 5
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
K = {}
ORDER = { 1, 2, 3 }
SL = { [1] = { ruleDatas = { { t = 1.25 } }, stockDatas = { { f = 0.5 } }, thrownAwayCargo = 0 },
       [2] = { ruleDatas = { { t = 2.5 } }, stockDatas = {}, thrownAwayCargo = 3 },
       [3] = nil }
R = { entitiesWith = function(k) return ORDER end }
IND = {}
api = { type = { ComponentType = { STOCK_LIST = 1, INDUSTRY = 2 } }, engine = { getComponent = function(e, t) if t == 2 then return IND[e] end return SL[e] end } }
C = { dump = function(v) local s = "" for k, x in pairs(v) do if type(x) == "table" then for k2, y in pairs(x) do s = s .. k2 .. "=" .. tostring(y) .. ";" end else s = s .. tostring(x) end end return s end,
  hashStr = function(h, s) local x = 7 for i = 1, #s do x = (x * 31 + s:byte(i)) % 4294967296 end return x end }
''' + src[a:b])
d1 = L.eval("K.industriesDigest()")
check(d1.startswith("2/"), "two industries with a stock list counted", d1)
L.execute("ORDER = { 3, 2, 1 }")
check(L.eval("K.industriesDigest()") == d1, "another order: the same digest")
L.execute("SL[2].ruleDatas[1].t = 2.5000001")
check(L.eval("K.industriesDigest()") != d1, "one industry's rule data otherwise: another digest")
L.execute("SL[2].ruleDatas[1].t = 2.5; SL[12] = SL[2]; SL[2] = nil; IND[2] = { stockList = 12, level = 1, upgradeProgress = 0.25, closureTimeStamp = -1 }")
d2 = L.eval("K.industriesDigest()")
check(d2.startswith("2/"), "the stock list on the entity the industry names (industry.stockList)", d2)
L.execute("IND[2].upgradeProgress = 0.2500001")
check(L.eval("K.industriesDigest()") != d2, "the industry's upgrade progress counts too")
L.execute('ENV.MPFEVER_INDDIGEST = "0"')
check(L.eval("K.industriesDigest()") is None, "MPFEVER_INDDIGEST=0: not measured")
check("pcall(function() parts.industriesDigest = K.industriesDigest() end)" in src, "simHash measures it")
mf = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read()
check('DiagnosticParts = new HashSet<string> { "buildIds", "personsDigest", "stepsDigest", "industriesDigest" };' in mf, "a diagnostic part: logged, never a reason to reload")
check('"personsDigest", "stepsDigest", "industriesDigest" };' in mf.split("NeverLocalParts")[1][:400], "never a local measure")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
