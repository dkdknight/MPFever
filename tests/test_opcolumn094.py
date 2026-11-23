"""Offline test: the Ranking tab shows each company's operating result of the year so far (0.9.4, Ansgar's idea in Discord
#suggestions "Better tracking of income", MPFEVER_OPCOLUMN; M.operating, M.rowsText, M.parseRows, M.view and the Hub's ranking
in mod/mpfever_1/content/mpfever_feat_stats.lua).

Ansgar: the ranking's value (money - loans + the vehicles' resale value) favours the companies that keep their money; a company
that builds a lot ranks low however well its lines earn. The host now also reads, at the start of every game month, each
company's revenue minus its running and upkeep costs since the start of the year, from the game's finance table (the
"transport" lines of every carrier, this year's column): its constructions and vehicle purchases, loans, interest and "other"
lines do not count. The column "Operating" shows it beside the others (sortable on the Hub's page); the ranking stays by value.

  part 1, before (MPFEVER_OPCOLUMN=0, as 0.9.3): no figure, the column shows "–";
  part 2, the figure: the transport lines of every carrier summed (revenue and costs), investments and other lines left out, the
  last (this year's) column only; no table from the game: nil;
  part 3, the month's text: "/op" after a row, read back; a month of an earlier version (no "/op", with or without the assets)
  still read, without it; a figure too big refused as the others;
  part 4, the tab: the column and its explanation, "–" for a month measured without it, the Hub's page sortable by it.
Needs lupa (pip install lupa). Run: python tests/test_opcolumn094.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_stats.lua")
SRC = open(MODULE, encoding="utf-8").read()
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def runtime(env=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end")
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute("api = nil; ug_require = nil")
    L.globals().M = L.execute(SRC)
    # the game's finance table of a company, as computeFinanceTable gives it (2 years asked: this year's column is the last)
    L.execute(r'''
    api = { type = { ChartConfig = { new = function() return {} end } }, engine = { util = { finance = {} } } }
    TABLES = {
      [101] = { transport = { [1] = { inc = { 9000, 50000 }, veh = { -1000, -12000 }, infra = { -500, -3000 } },
                              [2] = { inc = { 0, 20000 }, veh = { 0, -4000 } } },
                investment = { build = { -7000, -900000 }, buy = { 0, -250000 } }, other = { x = { 0, 77 } } },
      [102] = { transport = {}, investment = { build = { 0, -5000 } } },
    }
    api.engine.util.finance.computeFinanceTable = function(ent, cfg)
      local t = TABLES[ent]
      if not t then error("no account") end
      local fd = {}
      function fd:foreach_carrier(f) for c in pairs(t.transport) do f(c) end end
      function fd:foreach_transport(f, c) for k, v in pairs(t.transport[c] or {}) do f(k, v) end end
      function fd:foreach_investment(f) for k, v in pairs(t.investment or {}) do f(k, v) end end
      function fd:foreach_other(f) for k, v in pairs(t.other or {}) do f(k, v) end end
      return fd
    end''')
    return L


# ---- part 1: before
L = runtime({"MPFEVER_OPCOLUMN": "0"})
check("before (MPFEVER_OPCOLUMN=0, as 0.9.3): no operating figure for a company", L.eval("M.operating(101)") is None)

# ---- part 2: the figure
L = runtime()
check("the operating result: this year's revenue minus running and upkeep costs, every carrier (50000-12000-3000+20000-4000)",
      L.eval("M.operating(101)") == 51000, L.eval("M.operating(101)"))
check("  constructions, vehicle purchases and other lines left out (not -1150000 nor +77)", L.eval("M.operating(101)") == 51000)
check("  a company with no transport line: 0", L.eval("M.operating(102)") == 0, L.eval("M.operating(102)"))
check("  no table from the game (an entity with no account): nil, no error", L.eval("M.operating(999)") is None)
check("  no entity: nil", L.eval("M.operating(nil)") is None)

# ---- part 3: the month's text
L.execute('ROWS = { { id = 1, b = 1000, d = 0, vv = 50, op = -2500 }, { id = 2, b = -5, d = 10, vv = 0, a = 70, op = 51000 }, { id = 3, b = 7, d = 0, vv = 1 } }')
txt = L.eval("M.rowsText(ROWS)")
check("the month's text carries it after a row ('/op')", txt == "1:1000,0,50/-2500;2:-5,10,0,70/51000;3:7,0,1", txt)
L.execute("BACK = M.parseRows(M.rowsText(ROWS))")
check("  read back: each row's figure (none for a row without it)",
      L.eval("BACK[1].op") == -2500 and L.eval("BACK[2].op") == 51000 and L.eval("BACK[2].a") == 70 and L.eval("BACK[3].op") is None)
check("a month of an earlier version (no '/op'): still read, without it",
      L.eval('(function() local r = M.parseRows("1:1000,0,50;2:-5,10,0,70") return r and #r == 2 and r[1].op == nil and r[2].a == 70 end)()') is True)
check("a figure too big: the month refused, as for the others", L.eval('M.parseRows("1:1,0,0/9999999999999999")') is None)
check("  a broken text refused", L.eval('M.parseRows("1:1,0,0/x")') is None and L.eval('M.parseRows("1:1,0,0//5")') is None)

# ---- part 4: the tab
src = SRC
v = src[src.index('local head = { "#", tr(T, TX.colCo)'):]
v = v[:v.index('add("muted", tr(T, TX.opExplained))') + 40]
check("the tab's table: the column 'Operating' after the vehicles, '–' for a month measured without it, its explanation",
      'tr(T, TX.colOp) }' in v and 'x.r.op and M.fmt(x.r.op) or "–"' in v and "TX.opExplained" in v)
check("  the texts in French and English", L.eval("M.TX.colOp[1]") == "Exploitation" and L.eval("M.TX.colOp[2]") == "Operating"
      and "upkeep" in L.eval("M.TX.opExplained[2]") and "entretien" in L.eval("M.TX.opExplained[1]"))
r = src[src.index("local function rankingNode(t)"):]
r = r[:r.index("return nil\n\tend")]
check("the Hub's page: the column sortable by a click (key 'op'), a loss in red",
      'head(tr(T, TX.colOp), "op")' in r and 'key == "op"' in r and 'op = r.op' in r and 'x.op < 0 and "error"' in r)
check("  its widths: one more column, the tenders' too", "{ 30, 140, 90, 90, 70, 80, 90, 60 }" in r and "{ 30, 160, 95, 95, 80, 80, 95 }" in r)
check("the host's monthly measure reads it for every company", "local op = M.operating(c.ent)" in src and "op = op and clamp(op) or nil" in src)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
