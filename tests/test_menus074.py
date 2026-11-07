"""0.7.4: the MPFever window's pages redone (the evening plan's 2b to 2f), and what goes back to 0.7.3's pages.

  - Settings: « Use the window's old pages (MPFever 0.7.3) », kept across launches (oldmenus=1), or MPFEVER_OLDMENUS=1: every
    page below draws as in 0.7.3;
  - « How does it work? » at the end of every page (U.helpCard, folded by a click; the options' pages: u.help or M.HELP);
  - Sharing rules: the other companies' rules in a table (a row a company, its rules in colour), earnings and fees in tables;
  - Trade: two tabs (sales, supply contracts), the offers as cards, a sale in three steps with the price typed in a field (no
    more ±100 k buttons), the contracts in a table and a form of lists and fields; the same requests as before (run below with a
    fake kit: the price typed is the price offered);
  - Ranking: a podium, each company's change over a month, sorted by a click on a column's head; the companies' names as the
    other pages show them (the host's first company showed as "Company 1");
  - Stock market: each company once, a card with its figures and its buttons (0.7.3: a table, bars and a card);
  - Competition (market shares): sorted by a click on a column's head;
  - Company: a computer company is "computer" on its card, takes nobody in and does not merge (its chief never answers);
  - the computer companies' journal: a cargo's name, not its file's path; the auction's test buttons by company number.
Run: python tests/test_menus074.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.path.join(HERE, "..", "mod", "mpfever_1", "content")


def read(name):
    return open(os.path.join(C, name), encoding="utf-8").read()


ui = read("mpfever_ui.script.lua")
trade = read("mpfever_feat_trade.lua")
stats = read("mpfever_feat_stats.lua")
stock = read("mpfever_feat_stock.lua")
market = read("mpfever_feat_market.lua")
fails = []


def check(cond, name, got=None):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond or got is None else "   got: " + str(got)[:300]))
    if not cond:
        fails.append(name)


# ---------------------------------------------------------------- the old pages, the help
check('if os.getenv("MPFEVER_OLDMENUS") == "1" then return true end' in ui and 'p.oldmenus == "1"' in ui
      and 'oldmenus = true' in ui and '(p.oldmenus == "1" and ("oldmenus=1" .. C.NL) or "")' in ui,
      "the old pages: MPFEVER_OLDMENUS=1 or the setting oldmenus=1, kept across launches")
check('T("Utiliser les anciennes pages de la fenêtre (MPFever 0.7.3)", "Use the window\'s old pages (MPFever 0.7.3)")' in ui
      and 'p.oldmenus = v == 1 and "1" or "0"; U.saveGlobalPrefs()' in ui, "Settings: the box for the old pages")
check("U.helpCard = function(K, rows, key, paragraphs)" in ui and "U.helpFolded[key] = not folded" in ui
      and 'if inHub then U.hubMarks[head] = "title" end' in ui, "« How does it work? »: folded by a click, a card of its own in the Hub")
for key in ("rules", "company", "game", "ai", "auction"):
    check(f'U.helpCard(K, rows, "{key}", {{' in ui, f"« How does it work? » on the {key} page")
check("u.help = function(key, paragraphs)" in ui and "type(tb.M.HELP) == \"table\"" in ui and "not u.helpDone" in ui,
      "the options' pages: u.help, or M.HELP put at the end of the page")
for name, src in (("trade", trade), ("stats", stats), ("stock", stock), ("market", market)):
    check("u.help" in src, f"« How does it work? » on the {name} page")
for m in ("tenders", "territory", "journal", "perms", "public"):
    check("M.HELP = {" in read(f"mpfever_feat_{m}.lua"), f"« How does it work? » on the {m} page (M.HELP)")
check("u.choice = function(items, value, onValue, width)" in ui and 'made[n] = { kind = "choice"' in ui
      and 'made[n] = { kind = "input"' in ui, "the options' kit: a list to pick from, a field's width counted in its row")

# ---------------------------------------------------------------- sharing rules
rules = ui[ui.index("U.TABS.rules = function(K, st, ctx)"):]
rules = rules[:rules.index("\nU.settingsRows = function")]
check("if #others > 0 and not U.oldMenus() then" in rules and "U.hubTable(K, lines, { 32, 17, 17, 17, 17 })" in rules
      and "cls = U.ruleClass(tr.rule)" in rules, "the other companies' rules: a table, the rules in colour")
check("if fe and not U.oldMenus() then" in rules and 'T("Reçu d\'elle", "Received from it")' in rules and "gotFrom[p.from]" in rules,
      "earnings and fees: tables, received from and paid to each company")
check("U.hubTable = function(K, lines, widths, opts)" in ui and "U.ruleClass = function(rule)" in ui, "the table of the window's own pages")

# ---------------------------------------------------------------- trade, run with a fake kit
check("function M.uiRich(u, m, T)" in trade and "if u.rich and not u.oldMenus and u.choice and u.help and u.input and u.table and u.card then" in trade,
      "trade: the Hub's page unless the old pages are asked")
check("±100" not in trade[trade.index("function M.uiRich"):trade.index("function M.ui(u)")] and
      'u.input(tr(Y.price_field), function(v) f.price = digits(v) end, "sale_price", 260)' in trade,
      "trade: the price typed in a field")
try:
    import lupa.lua52 as lua52
except ImportError:
    lua52 = None
if lua52 is None:
    print("lupa is not installed (pip install lupa): the run of the trade page is skipped")
    fails.append("lupa missing")
else:
    L = lua52.LuaRuntime(unpack_returned_tuples=True)
    M = L.execute("package.loaded['mpfever_common.lua'] = nil; local f = load(...); return f()", trade)
    res = L.execute(r'''
local M = ...
local T = function(fr, en) return en end
local REQ, NODES, INPUTS, BTNS = {}, {}, {}, {}
local function node(kind, t) local n = { kind = kind, t = t }; NODES[#NODES + 1] = n; return n end
local u = { rich = true, oldMenus = false, T = T, W = 600 }
u.add = function(n) return n end
u.text = function(t) return node("text", t) end
u.muted = function(t) return node("muted", t) end
u.title = function(t) return node("title", t) end
u.gap = function() return node("gap") end
u.row = function(c) return node("row", c) end
u.card = function(t, c) return node("card", t) end
u.table = function(lines) return node("table", lines) end
u.choice = function(items, v, fn) return node("choice", items) end
u.input = function(ph, fn, key) INPUTS[key] = fn; return node("input", key) end
u.button = function(label, fn, primary, enabled) local b = node("button", label); b.fn = fn; b.on = enabled ~= false; BTNS[#BTNS + 1] = b; return b end
u.coColor = function() return nil end
u.help = function() node("help") end
u.request = function(kind, payload) REQ[#REQ + 1] = { kind = kind, payload = payload } end
u.read = function() return {
  "me\t1\t1\t1\t1", "co\t1\tAnn Co\t1", "co\t2\tBob Co\t1",
  "lot\tline\tL:Coal\tCoal\t2\t50000", "lot\tstation\tsg:Mine\tMine\t0\t100000",
  "st\t2\tsg:Mill\tMill", "cargo\tcoal\tCoal",
} end
local function press(label) for i = #BTNS, 1, -1 do if BTNS[i].t == label and BTNS[i].on then BTNS[i].fn(); return true end end return false end
local function draw() NODES, BTNS = {}, {}; M.ui(u) end
local out = {}
draw()
out.tabs = press("Sales") and press("Supply contracts")
M.form.tab = "sales"
draw()
local labels = {}
for _, b in ipairs(BTNS) do labels[#labels + 1] = b.t end
out.labels = table.concat(labels, ",")
out.pick = press("Pick")
draw()
out.chosen = false
for _, n in ipairs(NODES) do if n.kind == "text" and tostring(n.t):find("You sell ", 1, true) then out.chosen = true end end
INPUTS.sale_price("1 234 567 $")
draw()
REQ = {}
out.propose = press("Offer")
out.req = REQ[1] and REQ[1].kind
out.payload = REQ[1] and REQ[1].payload
-- the contracts' form
M.form.tab = "contracts"
draw()
local tables, choices = 0, 0
for _, n in ipairs(NODES) do if n.kind == "table" then tables = tables + 1 end if n.kind == "choice" then choices = choices + 1 end end
out.ctTable, out.ctChoices = tables, choices
INPUTS.ct_per("250"); INPUTS.ct_price("75"); INPUTS.ct_pen("5")
draw()
REQ = {}
out.ctPropose = press("Offer the contract")
out.ctReq = REQ[1] and REQ[1].kind
out.ctPayload = REQ[1] and REQ[1].payload
-- the old pages asked: M.view's rows (its ±100 k buttons)
u.oldMenus = true
NODES, BTNS = {}, {}
local rows = M.ui(u)
local old = false
for _, b in ipairs(BTNS) do if b.t == "Sell…" then old = true end end
out.old = old
return out
''', M)
    check(res.tabs is True, "trade: the two tabs")
    check(res.pick is True and res.chosen is True, "trade: step 1, the asset picked", res.labels)
    check(res.propose is True and res.req == "offer" and "price=1234567" in str(res.payload) and "to=2" in str(res.payload),
          "trade: the price typed (digits only) is the price offered, to the buyer", res.payload)
    check(res.ctTable >= 1 and res.ctChoices >= 2, "trade: the contract form in a table, the lists to pick from", (res.ctTable, res.ctChoices))
    check(res.ctPropose is True and res.ctReq == "ct_offer" and "per=250" in str(res.ctPayload) and "price=75" in str(res.ctPayload)
          and "penalty=5" in str(res.ctPayload), "trade: the contract's fields typed are the contract offered", res.ctPayload)
    check(res.old is True, "trade: the old pages asked: 0.7.3's rows")

# ---------------------------------------------------------------- ranking, stock, market, companies
check("local function rankingNode(t)" in stats and 'tostring(i) .. ". " .. coLabel(md, x.id, T)' in stats and "M.sel.sort" in stats
      and 'string.format("%+.1f %%", x.trend)' in stats, "ranking: a podium, the change over a month, sorted by a column")
check("▲" not in stats and "▼" not in stats and "▼" not in market, "no arrow the game's font has not (they showed as boxes)")
check('os.getenv("MPFEVER_STATSNAMES") ~= "0"' in stats and 'n:sub(1, 1) ~= "#"' in stats, "ranking: the companies' names as elsewhere")
check("function M.uiCards(u, v, myBal, now)" in stock and "if u.rich and u.card and u.stats and u.add and not u.oldMenus then return M.uiCards" in stock,
      "stock market: a card a company (each one once)")
check("M.sortCol" in market and "head[k] = u.button(b.headers[k]" in market, "market shares: sorted by a column")
check('local isAiCo = eco.ai and eco.ai[c.id]' in ui and "if amChief and not isAiCo then" in ui
      and '((eco.ai and eco.ai[c.id]) and T("ordinateur", "computer")' in ui, "company: a computer company is a computer, no join, no merger")
check("c.earn = api.engine.util.finance.calculateEarnings(ent)" in ui and "settled and os.getenv(\"MPFEVER_COSHEETMORE\") ~= \"0\"" in ui
      and 'C.Tf("Véhicules : %s", "Vehicles: %s"' in ui, "company sheet: vehicles by kind and the year's result, read for a settled company only")
check("U.cargoLabel = function(id)" in ui and "local function cargo(id) return U.cargoLabel(id) end" in ui,
      "the computer companies' journal: the cargo's name")
check("table.sort(byId, function(a, b) return a.id < b.id end)" in ui, "the auction's test buttons by company number (the balances change)")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
