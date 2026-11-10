"""Offline test: a company's value counts its infrastructure (0.7.17, issue #190; mpfever_feat_stats.lua f_stats_assets,
M.assetsSend, the rows' ",a"; mpfever_feat_stock.lua M.fromStats).

#190 (Creeper and Akamari, one company per player): the value (statistics, stock market) was money - loans + the vehicles' resale
value: a company in debt for its railway was worth less than nothing, its tracks, stations and roads counted for nothing. The
game counts a company's assets (api.engine.util.headquarters.getCompaniesValue().totalAssets, its finance window's company value
is assets + balance - debt) for the local player only: each game now sends its own once a game month (f_stats_assets), the
simulation keeps it for the sender's company, the host puts it in the month's figures ("id:b,d,vv,a"), and the value is
b - d + a (b - d + vv without it, as before).
  - rows with and without ",a" (old savegames' months) read and written; the value with a, and as before without;
  - f_stats_assets: one company per player, the sender's company (mpfCo); one company for everybody, the host's only; a bad figure;
  - M.assetsSend: once per game month, not again unless it changed; a player's game in the shared mode sends nothing;
  - MPFEVER_STOCKASSETS=0: nothing sent; the stock market's M.fromStats takes the same value.
Needs lupa (pip install lupa). Run: python tests/test_stockassets0717.py
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


L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('ENV = {} os.getenv = function(k) return ENV[k] end api = nil ug_require = nil')
M = L.execute(open(os.path.join(CONTENT, "mpfever_feat_stats.lua"), encoding="utf-8").read())
L.globals().M = M
S = L.execute(open(os.path.join(CONTENT, "mpfever_feat_stock.lua"), encoding="utf-8").read())
L.globals().S = S
run = L.eval("function(code) return assert(load(code))() end")

check(run('return M.rowsText(M.parseRows("1:100,50,20;2:-5,0,0"))') == "1:100,50,20;2:-5,0,0", "rows without assets: as before")
check(run('return M.rowsText(M.parseRows("1:100,50,20,900;2:-5,0,0"))') == "1:100,50,20,900;2:-5,0,0", "rows with assets kept")
check(run('return M.value(M.parseRows("1:100,50,20")[1])') == 70, "value without assets: money - loans + vehicles")
check(run('return M.value(M.parseRows("1:100,500,20,900")[1])') == 500, "value with assets: money - loans + assets (#190)")
check(run('return M.parseRows("1:100,50,20,x") == nil'), "a bad figure: the rows refused")

L.execute('''
SENT = {}
function mkenv(mode, host)
  return { mode = mode, isHost = host, on = function(id) return id == "stats" end, param = function() return nil end,
    state = function(st) st.feat = st.feat or {}; st.feat.stats = st.feat.stats or {}; return st.feat.stats end,
    log = function() end, realTime = function() return CLOCK end, send = function(n, p) SENT[#SENT + 1] = { n = n, p = p } end }
end
CLOCK = 100
''')
check(run('''local st = {} M.event(st, "f_stats_assets", { a = 123456, mpfFrom = "Erik#1", mpfCo = 2 }, mkenv("separate", false))
return st.feat.stats.assets["2"]''') == 123456, "separate: the sender's company keeps its assets")
check(run('''local st = {} M.event(st, "f_stats_assets", { a = 9, mpfFrom = "Erik#1" }, mkenv("separate", false))
return st.feat.stats.assets == nil''') is True, "separate: no company stamped: refused")
check(run('''local st = {} M.event(st, "f_stats_assets", { a = 9, mpfFrom = "Erik#1", mpfCo = 2 }, mkenv("shared", false))
M.event(st, "f_stats_assets", { a = 77, mpfFrom = "Host" }, mkenv("shared", false))
return st.feat.stats.assets["1"] .. "/" .. tostring(st.feat.stats.assets["2"])''') == "77/nil", "shared: the host's word only, for company 1")
check(run('''local st = {} M.event(st, "f_stats_assets", { a = "x", mpfFrom = "Host", mpfCo = 1 }, mkenv("separate", true))
return st.feat.stats.assets == nil''') is True, "a figure that is no number: refused")

# the send, once a month
L.execute('''api = { engine = { util = { headquarters = { getCompaniesValue = function() return { totalAssets = ASSETS } end } } } }
ASSETS = 5000000''')
n = run('''SENT = {} M.g = {} local st = {} local s = { due = 10 } local env = mkenv("separate", false)
M.assetsSend(st, s, env) CLOCK = CLOCK + 30 M.assetsSend(st, s, env)
s.due = 11 CLOCK = CLOCK + 30 M.assetsSend(st, s, env)
ASSETS = 6000000 s.due = 12 CLOCK = CLOCK + 30 M.assetsSend(st, s, env)
return #SENT .. ":" .. tostring(SENT[1] and SENT[1].p.a) .. ":" .. tostring(SENT[2] and SENT[2].p.a)''')
check(n == "2:5000000:6000000", "sent once a month, again only when it changed", n)
check(run('''SENT = {} M.g = {} M.assetsSend({}, { due = 3 }, mkenv("shared", false)) return #SENT''') == 0, "shared: a player's game sends nothing")
check(run('''SENT = {} M.g = {} ENV.MPFEVER_STOCKASSETS = "0" M.assetsSend({}, { due = 3 }, mkenv("separate", false)) ENV = {} return #SENT''') == 0,
      "MPFEVER_STOCKASSETS=0: nothing sent")

# the stock market reads the same value
v = run('''local st = { feat = { stats = { m = { "7|1900|3|1:100,500,20,900;2:10,0,30" } } } }
local f = S.fromStats(st, 7) return f[1].v .. "/" .. f[2].v .. "/" .. f[1].c''')
check(v == "500/40/100", "stock market: the statistics' value with assets, and as before without", v)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
