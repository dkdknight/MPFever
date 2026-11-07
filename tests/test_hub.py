"""The MPFever Hub (0.6): the big window's menu and the richer page helpers, offline (lupa, Lua 5.2).

The window's real functions are taken from mod/mpfever_1/content/mpfever_ui.script.lua (the drawing kit U.makeKit, the tabs' rules
U.tabsFor..., the Hub's menu U.hubMenu..., the game options' helpers U.featOff..U.featTabRows with U.hubCards) and run over a mocked
game builtin module (each component a table { kind, p }) and api. Checked:
  - the kit's new boxes (K.box, K.rect, K.wbtn): their size, padding and background;
  - the page helpers in the Hub (u.rich): u.card (a box of the page's width, its title, a swatch in a company's colour), u.bar
    (a track and its fill at the fraction, in the colour), u.table (a head on a darker band, striped rows, this player's row on a
    blue band, the columns stretched to the page, a node in a cell), u.stat / u.stats, u.row (a text gets what the buttons leave);
  - outside the Hub (the small window of MPFEVER_HUB=0, the tests' kits): the helpers draw what they drew before (u.title a
    section, u.table rows of texts) and the new ones fall back to plain rows;
  - U.hubCards: a title starts a card, the rows before the first title stay, a group that holds a card keeps its title as a
    heading, the gaps at a group's ends go, a page without a title gets one card;
  - the Hub's menu per session: the co-op with nothing on, the co-op with options offered to the host, one company per player
    with and without computer companies, every option on (the pages in their groups, in order), a page no group names; the small
    window's tabs (the quick view, or every tab with MPFEVER_HUB=0); the Hub's measures from the screen;
  - the module pages drawn by the Hub (territories with their « View » buttons moving the camera, tenders' bars, the stocks'
    ranking, the market shares' bars) and by the plain window (no change).
Run: python tests/test_hub.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")


def read(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def extract(src, pattern, what):
    m = re.search(pattern, src, re.S | re.M)
    if not m:
        print(f"FAIL: {what} not found")
        sys.exit(1)
    return m.group(0)


UI = read("mpfever_ui.script.lua")
KIT = extract(UI, r"^U\.makeKit = function\(builtin\)\n.*?^end\n", "U.makeKit")
TABS = extract(UI, r"^U\.TAB_IDS = .*?^U\.tabLabel = function\(id\)\n.*?^end\n", "the tabs' rules")
HUB = extract(UI, r"^U\.hubOn = .*?^U\.hubMeasures = function\(\)\n.*?^end\n", "the Hub's menu")
FEAT = extract(UI, r"^U\.featOff = .*?^U\.featTabRows = function\(K, st, key\)\n.*?^end\n", "the window's game options")

L = lua52.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
RESULTS = {}
function check(name, cond, got)
  RESULTS[#RESULTS + 1] = { name = name, ok = cond and true or false, got = tostring(got) }
end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function T(fr, en) return en end
function money(n) return "$" .. tostring(n) end
function sendLine(kind, p) end
ENV = {}
os.getenv = function(k) return ENV[k] end
-- the game's builtin module: each component says what it is and what it was given
builtin = setmetatable({ type = { Orientation = { Vertical = "V", Horizontal = "H" }, ScrollBarPolicy = { AlwaysOff = 0, AsNeeded = 1 } } }, {
  __index = function(t, k) return function(p) local n = { kind = k, p = p } if TRACK then TRACK[#TRACK + 1] = n end return n end end })
CAM = {}
api = {
  type = { Vec4f = { new = function(a, b, c, d) return { a, b, c, d } end }, Vec2f = { new = function(x, y) return { x = x, y = y } end },
    Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end } },
  gui = { StyleSheet = { new = function() return {} end }, NinePatch = { new = function() return {} end },
    genericRep = { find = function() error("no colours here") end },
    byId = { getSize = function(id) if id == "GameUiWindowContainer" then return SCREEN end error("no " .. id) end },
    camera = { getSize = function() return { x = 1, y = 1 } end, focusPosition = function(p, d) CAM[#CAM + 1] = { p.x, p.y, d } end } },
  cmd = { sendCommand = function() end, makeScriptingSendEventCmd = function() return {} end },
}
SCREEN = { x = 1920, y = 1080 }
U = { isHost = function(st) return st and st.host == true end, winChanged = function() end, menuRequest = function() return true end }
C = { DIR = "D", BS = "/", NL = "\n", CR = "\r", TAB = "\t", Tf = function(fr, en, ...) local v, i = { ... }, 0 return (en:gsub("%%s", function() i = i + 1 return tostring(v[i]) end)) end,
  IO = { open = function(path) local s = FILES[path] if not s then return nil end return { read = function() return s end, close = function() end } end } }
FILES = {}
-- a component's children, whatever the kind
function kids(n)
  if type(n) ~= "table" or type(n.p) ~= "table" then return {} end
  if n.p.children then return n.p.children end
  if n.p.layout then return { n.p.layout } end
  if n.p.content then return { n.p.content } end
  if n.p.items then return n.p.items end
  return {}
end
function walk(n, fn) fn(n); for _, c in ipairs(kids(n)) do walk(c, fn) end end
function texts(n) local out = {} walk(n, function(x) if x.kind == "TextView" then out[#out + 1] = x.p.text end end) return table.concat(out, "|") end
function buttons(n) local out = {} walk(n, function(x) if x.kind == "Button" then out[#out + 1] = x end end) return out end
function labelOf(b) return texts(b.p.content) end
function sizeOf(n) local s = n.p and n.p.meta and n.p.meta.styleSheet return s and s.size end
function bgOf(n) local s = n.p and n.p.meta and n.p.meta.styleSheet return s and s.backgroundColor end
function same(a, b) if not (a and b) then return false end for i = 1, 4 do if math.abs((a[i] or 0) - (b[i] or 0)) > 1e-6 then return false end end return true end
''')
L.execute(KIT)
L.execute(r'''
K = U.makeKit(builtin)
local b = K.box({ K.text("a") }, { size = { 300, -1 }, padding = { 1, 2, 3, 4 }, background = { 1, 1, 1, 0.06 } })
check("kit: K.box, a component with its style around a vertical layout", b.kind == "Component" and sizeOf(b).x == 300 and b.p.meta.styleSheet.padding[2] == 2
  and same(bgOf(b), { 1, 1, 1, 0.06 }) and b.p.layout.kind == "BoxLayout" and b.p.layout.p.orientation == "V")
local r = K.rect(33.7, 14, { 1, 0, 0, 1 })
check("kit: K.rect, a rectangle of colour", sizeOf(r).x == 33 and sizeOf(r).y == 14 and same(bgOf(r), { 1, 0, 0, 1 }))
check("kit: K.wbtn, a button of a width", sizeOf(K.wbtn("x", nil, nil, true, 200)).x == 200)
''')
L.execute(TABS)
L.execute(HUB)
F = L.execute(read("mpfever_feat.lua"))
L.globals().F = F
for mid in ["journal", "stats", "market", "territory", "tenders", "perms", "trade", "stock", "public"]:
    L.globals()["SRC_" + mid] = read(f"mpfever_feat_{mid}.lua")
L.execute(r'''
F.loader = function(id) local s = _G["SRC_" .. id] if s then return assert(load(s, "=" .. id))() end return nil end
C.feat = function() return F end
''')
L.execute(FEAT)
L.execute(r'''
-- every option allowed in a mode, on
function allOn(mode)
  F.load(log)
  local t = {}
  for _, M in ipairs(F.mods) do for _, o in ipairs(M.OPTIONS) do
    if o.modes == nil or o.modes == "both" or o.modes == mode then t[#t + 1] = o.id .. "=1" end
  end end
  table.sort(t)
  return table.concat(t, ";")
end
U.newWindow = true
U.HubWindow = true
U.pollEco = function() end
function menuText(st)
  local out = {}
  for _, g in ipairs(U.hubMenu(st)) do out[#out + 1] = g.key .. ":" .. table.concat(g.pages, ",") end
  return table.concat(out, " ")
end
-- ---- the menu per session
U.eco = nil
local m = menuText({ mode = "shared", opts = "", players = {} })
check("menu, co-op, nothing on: the game's pages only", m == "game:session,chat,settings", m)
m = menuText({ mode = "shared", opts = "", host = true, me = "h", players = { { id = "h", role = "host" } } })
check("menu, co-op host with options to offer: Rules and options too", m == "game:session,chat,game,settings", m)
m = menuText({ mode = "separate", opts = "", players = {} })
check("menu, one company per player: Company and the sharing rules in My company", m == "game:session,chat,game,settings company:company,rules", m)
U.eco = { ai = { [3] = true } }
m = menuText({ mode = "separate", opts = "", players = {} })
check("menu, with computer companies: the AI page in Competition", m == "game:session,chat,game,settings company:company,rules competition:ai", m)
m = menuText({ mode = "separate", opts = allOn("separate"), players = {} })
check("menu, every option on: every page in its group, in order",
  m == "game:session,chat,game,f_public,settings company:company,rules,f_team,f_trade,f_stock competition:f_stats,f_market,f_tenders,f_territory,f_journal,ai", m)
U.eco = nil
m = menuText({ mode = "shared", opts = allOn("shared"), players = {} })
check("menu, co-op, every co-op option on: the team under My company (the company of everybody), no Company page",
  m == "game:session,chat,game,f_public,settings company:f_team competition:f_stats,f_journal", m)
local pages = table.concat(U.hubPages({ mode = "separate", opts = "stats=1", players = {} }), ",")
check("menu: the pages in order (the window scenario's list)", pages == "session,chat,game,settings,company,rules,f_stats", pages)
-- a page no group names: with the game's pages, before Settings
local tabsFor = U.tabsFor
U.tabsFor = function(st) local t = tabsFor(st) table.insert(t, #t, "f_later") return t end
m = menuText({ mode = "shared", opts = "", players = {} })
check("menu: a page of a later version with the game's, before Settings", m == "game:session,chat,f_later,settings", m)
U.tabsFor = tabsFor
check("menu: a page this session has not shows Session", U.hubValid("company", { mode = "shared", opts = "" }) == "session" and U.hubValid("chat", { mode = "shared", opts = "" }) == "chat")
U.status = { mode = "separate", opts = "stats=1" }
check("menu: the labels", U.hubLabel("game") == "Rules and options" and U.hubLabel("rules") == "Sharing rules" and U.hubLabel("f_market") == "Market shares"
  and U.hubLabel("f_stats") == "Ranking" and U.hubLabel("company") == "Company")
-- ---- the small window: a quick view with the Hub, every tab without it
local stS = { mode = "separate", opts = "stats=1", players = {} }
check("small window with the Hub: Session and Chat", table.concat(U.winTabs(stS), ",") == "session,chat" and U.validTab("company", stS) == "session")
U.hubOff = true
check("MPFEVER_HUB=0: no Hub, every tab as before", not U.hubOn() and table.concat(U.winTabs(stS), ",") == "session,chat,company,rules,game,f_stats,settings"
  and U.validTab("company", stS) == "company", table.concat(U.winTabs(stS), ","))
U.hubOff = false
U.HubWindow = nil
check("a Hub that could not be installed: every tab as before", table.concat(U.winTabs(stS), ",") == "session,chat,company,rules,game,f_stats,settings")
U.HubWindow = true
-- ---- the measures
U.hubSize = 2
local ms = U.hubMeasures()
check("measures: two thirds of a 1920 x 1080 screen", ms.W == 1286 and ms.H == 723 and ms.text == ms.inner - 24 and ms.pageW == ms.W - ms.side - 14, ms.W .. "x" .. ms.H)
U.hubScreenWH = nil; SCREEN = { x = 1280, y = 720 }
ms = U.hubMeasures()
check("measures: never under 900 x 520", ms.W == 900 and ms.H >= 520, ms.W .. "x" .. ms.H)
U.hubScreenWH = nil; SCREEN = { x = 3840, y = 2160 }; U.hubSize = 3
ms = U.hubMeasures()
check("measures: the large size of a 4K screen", ms.W == 3072 and ms.H == 1728, ms.W .. "x" .. ms.H)
U.hubScreenWH = nil; SCREEN = nil; U.hubSize = 2
ms = U.hubMeasures()
check("measures: 1920 x 1080 when the screen cannot be read", ms.W == 1286, ms.W)
''')

# ---------------------------------------------------------------- the page helpers
L.execute(r'''
K.TEXT_W = 700
local M0 = { ID = "stats" }
local st = { mode = "separate", opts = "stats=1", players = {} }
-- outside the Hub: as before
local p = U.featU(K, st, M0)
check("plain: not rich", p.rich == false)
check("plain: u.title is the section with its icon", p.title("X").kind == "BoxLayout" and texts(p.title("X")) == "X" and p.title("X").p.children[1].kind == "ImageView")
local pt = p.table({ { "a", "b" }, { "1", "2" } }, nil, true)
check("plain: u.table rows of texts, the head in title-4", pt.p.children[1].p.children[1].p.meta.class == "font-scale-title-4" and texts(pt) == "a|b|1|2")
check("plain: u.card the title and the children", texts(p.card("C", { p.text("x") })) == "C|x")
check("plain: u.bar its texts only, nil without", texts(p.bar(0.5, "success", "50 %", { lead = "Bob" })) == "Bob   50 %" and p.bar(0.5, "success") == nil)
check("plain: u.stat a line", texts(p.stat("Value", "$5")) == "Value: $5")
-- in the Hub
U.hubDrawing, U.hubMarks = true, {}
local u = U.featU(K, st, M0)
check("hub: rich", u.rich == true and u.marks == U.hubMarks)
local t = u.title("Ranking")
check("hub: u.title a title-4 text, marked", t.kind == "TextView" and t.p.meta.class == "font-scale-title-4" and U.hubMarks[t] == "title")
check("hub: u.gap marked", U.hubMarks[u.gap(6)] == "gap")
local c = u.card("Bob Co", { u.text("hello") }, { color = { 1, 0, 0 }, tint = "warning" })
check("hub: u.card a box of the page's width (text + 24), padded, tinted", c.kind == "Component" and sizeOf(c).x == 724 and same(bgOf(c), U.HUB_TINT.warning)
  and U.hubMarks[c] == "card", sizeOf(c).x)
local head = c.p.layout.p.children[1]
check("hub: u.card's title row: a swatch in the colour, then the title", head.kind == "BoxLayout" and same(bgOf(head.p.children[1].p.layout.p.children[2]), { 1, 0, 0, 1 })
  and texts(head) == "Bob Co" and texts(c) == "Bob Co|hello")
local bar = u.bar(0.25, { 0, 1, 0 }, "25 %", { lead = "Bob", leadW = 100, labelW = 60 })
local track = bar.p.children[3].p.layout.p.children[2]
local bw = 700 - 100 - 60 - 20
check("hub: u.bar a track of the room left", sizeOf(track).x == bw and same(bgOf(track), U.HUB_TINT.track), sizeOf(track).x)
local fill = track.p.layout.p.children[1]
check("hub: u.bar's fill at the fraction, in the colour", sizeOf(fill).x == math.floor(bw * 0.25 + 0.5) and same(bgOf(fill), { 0, 1, 0, 1 }), sizeOf(fill).x)
check("hub: u.bar's texts", texts(bar) == "Bob|25 %")
check("hub: u.bar empty at 0 (no fill), full at 1", #u.bar(0, "info").p.children[1].p.layout.p.children[2].p.layout.p.children == 0
  and sizeOf(u.bar(2, "info", nil, { width = 300 }).p.children[1].p.layout.p.children[2].p.layout.p.children[1]).x == 300)
check("hub: u.bar in a class's colour", same(bgOf(u.bar(1, "error", nil, { width = 50 }).p.children[1].p.layout.p.children[2].p.layout.p.children[1]), { 1, 0.38, 0.33, 1 }))
U.coColors = { [7] = 3 }
U.coLib = function() return { rgb = function(ix) return 0.1 * ix, 0.2, 0.3 end } end
check("hub: u.coColor a company's palette colour, nil for one not known", same(u.coColor(7), { 0.3, 0.2, 0.3, nil }) and u.coColor(8) == nil)
check("hub: u.bar in a company's colour (its number)", same(bgOf(u.bar(1, 7, nil, { width = 50 }).p.children[1].p.layout.p.children[2].p.layout.p.children[1]), { 0.3, 0.2, 0.3, 1 }))
local btn = u.button("Go", function() end)
local tb = u.table({ { "#", "Company", "Value" }, { "1", "Bob", "$5" }, { "2", "Ann", btn } }, { 30, 300, 100 }, true,
  { highlight = function(i, line) return line[2] == "Ann" end })
local tr = tb.p.children
check("hub: u.table a head and a row each", tb.kind == "BoxLayout" and #tr == 3)
check("hub: u.table's head on its band, muted", same(bgOf(tr[1]), U.HUB_TINT.head) and tr[1].p.layout.p.children[2].p.layout.p.children[1].p.text == "Company")
check("hub: u.table's rows striped, this player's on the blue band", same(bgOf(tr[2]), U.HUB_TINT.odd) and same(bgOf(tr[3]), U.HUB_TINT.mine))
local cw = {}
for i, cell in ipairs(tr[2].p.layout.p.children) do cw[i] = sizeOf(cell).x end
check("hub: u.table's columns stretched to the page (the last one takes the rest)", cw[1] + cw[2] + cw[3] == 700 - 16 and cw[2] > cw[1] * 9, table.concat(cw, ","))
check("hub: u.table's widths the same on every row", sizeOf(tr[3].p.layout.p.children[1]).x == cw[1] and sizeOf(tr[3].p.layout.p.children[3]).x == cw[3])
check("hub: u.table a node in a cell", tr[3].p.layout.p.children[3].p.layout.p.children[1] == btn)
local s = u.stats({ { "Value", "$5" }, { "Money", "$3", "success" } }, 200)
check("hub: u.stats the boxes side by side", s.p.children[1].kind == "BoxLayout" and texts(s) == "Value|$5|Money|$3" and sizeOf(s.p.children[1].p.children[1]).x == 200)
local row = u.row({ u.text("A long line"), u.button("Claim", function() end), u.button("View", function() end) })
local tw = row.p.children[1].p.width
check("hub: u.row gives a text what its buttons leave", tw == 700 - (34 + 8 * 5) - (34 + 8 * 4) - 12 and row.p.children[2].kind == "Component", tw)
check("hub: u.row of buttons only, as it is", #u.row({ u.button("a", nil), u.button("b", nil) }).p.children == 2)
-- U.hubCards
local marks = {}
local function mk(kind, t) local n = { kind = "TextView", p = { text = t } } if kind then marks[n] = kind end return n end
local intro, t1, a, g1, t2, cd, g2 = mk(nil, "intro"), mk("title", "One"), mk(nil, "a"), mk("gap", ""), mk("title", "Two"), mk("card", "card"), mk("gap", "")
local out = U.hubCards(K, { intro, t1, a, g1, t2, cd, g2 }, marks, 724)
check("cards: the introduction as it is, then a card per title", out[1] == intro and out[3].kind == "Component" and sizeOf(out[3]).x == 724 and texts(out[3]) == "One|a", #out)
check("cards: the gaps at a group's end after its card (no separator of its own then)", #out[3].p.layout.p.children == 3 and out[4] == g1 and out[5] == t2)
check("cards: a group that holds a card keeps its title as a heading", out[5] == t2 and out[7] == cd and out[8] == g2 and out[9] == nil, #out)
local one = U.hubCards(K, { mk(nil, "x"), mk(nil, "y") }, marks, 724)
check("cards: a page without a title, one card", #one == 1 and texts(one[1]) == "x|y")
U.hubDrawing, U.hubMarks = nil, nil
''')

# ---------------------------------------------------------------- the module pages in the Hub
L.execute(r'''
-- (a page drawn by the Hub; LEFT: the nodes it made that are not in its tree, none expected: the game's react makes each node in
-- its tree as it is asked for)
function page(key, st)
  U.hubDrawing, U.hubMarks = true, {}
  TRACK = {}
  local rows = U.featTabRows(K, st, key)
  local marks = U.hubMarks
  U.hubDrawing, U.hubMarks = nil, nil
  local all = { kind = "BoxLayout", p = { children = U.hubCards(K, rows, marks, 724) } }
  local seen = {}
  walk(all, function(x) seen[x] = true end)
  LEFT = 0
  for _, n in ipairs(TRACK) do if not seen[n] then LEFT = LEFT + 1 end end
  TRACK = nil
  return all, rows
end
function plain(key, st)
  local rows = U.featTabRows(K, st, key)
  return { kind = "BoxLayout", p = { children = rows } }
end
function press(n, label) for _, b in ipairs(buttons(n)) do if labelOf(b) == label then b.p.onClick() return true end end return false end
-- territories: the claim list with View and Claim, the others' territories with View
FILES["D/feat_territory_board.txt"] = table.concat({ "rule\t2\t5", "me\tclaim\t11\t0", "town\t13\tCité\t1\t20000\t21000", "town\t12\tBourg\t0\t15000\t16000",
  "terr\t2\tBob Co\tAville\t2\ton\t60\t0\t1000\t1100", "hc\t2\tBob Co\t50\t1000000" }, "\n")
local stT = { mode = "separate", opts = "handicap=1;territory=1", players = {} }
local hubT = page("f_territory", stT)
local tt = texts(hubT)
check("territories, Hub: every node it made is in its tree", LEFT == 0, LEFT)
check("territories, Hub: the claim list as a table", tt:find("Town|State|", 1, true) ~= nil and tt:find("Cité|free", 1, true) ~= nil
  and tt:find("Bourg|too close to another territory", 1, true) ~= nil, tt)
check("territories, Hub: the others' territories and the handicaps as tables", tt:find("Bob Co|Aville|2 km|60 more month(s)", 1, true) ~= nil
  and tt:find("Bob Co|50 %|+1 000 000", 1, true) ~= nil, tt)
local views = 0
for _, b in ipairs(buttons(hubT)) do if labelOf(b) == "View" then views = views + 1 end end
check("territories, Hub: a View button per town and per territory", views == 3, views)
CAM = {}
local bs = buttons(hubT)
local firstView
for _, b in ipairs(bs) do if labelOf(b) == "View" then firstView = firstView or b end end
firstView.p.onClick()
check("territories, Hub: View moves the camera to the town", CAM[1] and CAM[1][1] == 20000 and CAM[1][2] == 21000 and CAM[1][3] == 1500, CAM[1] and CAM[1][3])
local claimBtn
for _, b in ipairs(bs) do if labelOf(b) == "Claim" then claimBtn = b end end
check("territories, Hub: a Claim button for the free town only", claimBtn ~= nil and #(function() local l = {} for _, b in ipairs(bs) do if labelOf(b) == "Claim" then l[#l + 1] = b end end return l end)() == 1)
local pv = plain("f_territory", stT)
local nViewPlain = 0
for _, b in ipairs(buttons(pv)) do if labelOf(b) == "View" then nViewPlain = nViewPlain + 1 end end
check("territories, plain window: as before (Claim, no View)", nViewPlain == 0 and press(pv, "Claim"))
-- this company's territory: View over its circle, Give up
FILES["D/feat_territory_board.txt"] = table.concat({ "rule\t2\t5", "me\thas\t11\t1", "terr\t3\tMy Co\tCité\t2\tforever\t-1\t1\t20000\t21000" }, "\n")
local hubM = page("f_territory", stT)
check("territories, Hub (my territory): every node in its tree", LEFT == 0, LEFT)
CAM = {}
check("territories, Hub: my territory's card with View and Give up", texts(hubM):find("Your territory|View|Your territory: Cité", 1, true) ~= nil and press(hubM, "View") and press(hubM, "Give up"), texts(hubM))
check("territories, Hub: View takes in the territory's circle", CAM[1] and CAM[1][1] == 20000 and CAM[1][3] == 4400, CAM[1] and CAM[1][3])
-- tenders: each company's progress as a bar
FILES["D/feat_tenders_list.txt"] = table.concat({ "month\t10", "me\t2", "co\t1\tAnn Co\t1\t0\t0", "co\t2\tBob Co\t2\t0\t0",
  "open\t1\tpax\t200\t3\t50000\tAville\tBourg\t\t10\t20\t30\t40", "prog\t1\t1\t50", "prog\t1\t2\t100" }, "\n")
local hubTd = page("f_tenders", { mode = "separate", opts = "tenders=1", players = {} })
check("tenders, Hub: every node in its tree", LEFT == 0, LEFT)
local nb = 0
walk(hubTd, function(x) if x.kind == "Component" and sizeOf(x) and sizeOf(x).y == 14 and same(bgOf(x), U.HUB_TINT.track) then nb = nb + 1 end end)
check("tenders, Hub: a bar per company that started", nb == 2, nb)
check("tenders, Hub: the percentages and the Show buttons", texts(hubTd):find("50 %", 1, true) ~= nil and texts(hubTd):find("25 %", 1, true) ~= nil and #buttons(hubTd) == 2, texts(hubTd))
-- stocks: the ranking as a table, this company on its band, a card per company
FILES["D/feat_stock_stock.txt"] = table.concat({ "opt\t25\t0\t10\t5\t3\t2\t10", "me\t2\t-1",
  "co\t1\t0\t500000\t400000\t5000000\t0\t0\t0\t6\t4\t1\tAnn Co", "co\t2\t0\t300000\t300000\t3000000\t0\t0\t0\t8\t2\t2\tBob Co" }, "\n")
local hubS = page("f_stock", { mode = "separate", opts = "stock=1", players = {} })
local ts = texts(hubS)
check("stocks, Hub: every node in its tree", LEFT == 0, LEFT)
-- (0.7.4, the menus redone: each company shown once, a card with its figures and its buttons; 0.7.3's table and bars with the
-- window's old pages)
local _, nAnn = ts:gsub("Ann Co", "")
check("stocks, Hub: each company once, its card with its figures", nAnn == 1 and ts:find("1. Ann Co|Value|$5000000|Share  +25 %|$500000|Dividend|$0|Your shares|0/10", 1, true) ~= nil, ts)
local mineCard = 0
walk(hubS, function(x) if same(bgOf(x), U.HUB_TINT.info) then mineCard = mineCard + 1 end end)
check("stocks, Hub: this player's company on a card of its own colour", mineCard == 1, mineCard)
check("stocks, Hub: a card per company with its buttons", ts:find("1. Ann Co", 1, true) ~= nil and ts:find("2. Bob Co (you)", 1, true) ~= nil and press(hubS, "Buy 1 ($500000)"), ts)
check("stocks, Hub: How does it work? (its texts at the end of the page)", ts:find("Every company has 10 shares. Their price", 1, true) ~= nil, ts)
local keepOld = U.oldMenus
U.oldMenus = function() return true end
local hubSo = page("f_stock", { mode = "separate", opts = "stock=1", players = {} })
U.oldMenus = keepOld
local tso = texts(hubSo)
check("stocks, Hub, the old pages: the ranking table", tso:find("#|Company|Value|Share|Change|Dividend|You", 1, true) ~= nil and tso:find("1|Ann Co|", 1, true) ~= nil, tso)
local mine = 0
walk(hubSo, function(x) if same(bgOf(x), U.HUB_TINT.mine) then mine = mine + 1 end end)
check("stocks, Hub, the old pages: this player's company on a band of its own", mine == 1, mine)
-- market shares: the totals' table and the shares as bars
FILES["D/feat_market_shares.txt"] = table.concat({ "me\t2", "month\t5", "co\t1\t0\tAnn Co", "co\t2\t0\tBob Co", "tot\t1\t600\t-1\t2\t0", "tot\t2\t400\t1000\t1\t1" }, "\n")
local hubMk = page("f_market", { mode = "separate", opts = "market=1", players = {} })
check("market, Hub: every node in its tree", LEFT == 0, LEFT)
local nbm = 0
walk(hubMk, function(x) if x.kind == "Component" and sizeOf(x) and sizeOf(x).y == 14 and same(bgOf(x), U.HUB_TINT.track) then nbm = nbm + 1 end end)
check("market, Hub: the passengers' and the cargo's shares as bars", nbm == 4, nbm)
check("market, Hub: the totals' table", texts(hubMk):find("Bob Co (you)|40 %|100 %", 1, true) ~= nil, texts(hubMk))
-- the ranking: the table with this company's band, the values as bars in the companies' colours
FILES["D/feat_stats_main.txt"] = table.concat({ "host\t0", "me\t2", "mode\tseparate", "opts\t0\t1\t0\t0", "co\t1\t0.9,0.1,0.1\t0\t0\tAnn Co",
  "co\t2\t0.1,0.1,0.9\t0\t0\tBob Co", "last\t5", "m\t5\t2001\t6\t1:100,0,50;2:200,10,0" }, "\n")
local hubSt = page("f_stats", { mode = "separate", opts = "stats=1", players = {} })
check("ranking, Hub: every node in its tree", LEFT == 0, LEFT)
local fills = {}
walk(hubSt, function(x) if x.kind == "Component" and sizeOf(x) and sizeOf(x).y == 14 and same(bgOf(x), U.HUB_TINT.track) then
  local f = x.p.layout.p.children[1]
  fills[#fills + 1] = f and bgOf(f) or false
end end)
check("ranking, Hub: the values as bars in the companies' colours (and the history's)", #fills == 4 and same(fills[1], { 0.1, 0.1, 0.9, 1 }) and same(fills[2], { 0.9, 0.1, 0.1, 1 }), #fills)
local mineS = 0
walk(hubSt, function(x) if same(bgOf(x), U.HUB_TINT.mine) then mineS = mineS + 1 end end)
check("ranking, Hub: this player's company on its band", mineS == 1, mineS)
check("ranking, plain window: no bar", texts(plain("f_stats", { mode = "separate", opts = "stats=1", players = {} })):find("Bob Co (you)", 1, true) ~= nil)
-- every module's page draws in the Hub with its file missing (nothing written yet)
FILES = {}
local stAll = { mode = "separate", opts = allOn("separate"), players = {} }
local bad = {}
for _, tb in ipairs(U.featTabs(stAll)) do
  local _, rows = page(tb.key, stAll)
  local s = texts({ kind = "BoxLayout", p = { children = rows } })
  if s:find("could not be drawn", 1, true) then bad[#bad + 1] = tb.key end
  if LEFT > 0 then bad[#bad + 1] = tb.key .. " (" .. LEFT .. " node(s) left out)" end
end
check("every module's page draws in the Hub without its file", #bad == 0, table.concat(bad, ","))
''')

# ---------------------------------------------------------------- the window scenario: the Hub's pages (the bridge's H.wintabs and
# the window's U.pollTabReq / U.ackTabReq)
BRIDGE = read("mpfever_bridge.script.lua")
L.execute(extract(UI, r"^U\.pollTabReq = function\(\)\n.*?^end\n", "U.pollTabReq"))
L.execute(extract(UI, r"^U\.ackTabReq = function\(shown, result, nRows, pages\)\n.*?^end\n", "U.ackTabReq"))
L.execute(r'''
WRITTEN = {}
C.IO.open = function(path, mode)
  if mode == "wb" then return { write = function(_, s) WRITTEN[path] = s; FILES[path] = s end, close = function() end } end
  local s = FILES[path] if not s then return nil end
  return { read = function() return s end, close = function() end }
end
os.clock = function() return 100 end
U.SessionWindow, U.HubWindow = true, true
OPENED = {}
U.openHub = function(page) OPENED[#OPENED + 1] = "hub " .. tostring(page) return true end
U.openWindow = function(tab) OPENED[#OPENED + 1] = "win " .. tostring(tab) return true end
FILES["D/ui_tab_req.txt"] = "company\t1\n"
U.pollTabReq()
check("window: with the Hub, a tab the small window has not is asked of the Hub", OPENED[1] == "hub company" and U.tabReqHub == true, OPENED[1])
U.tabReqAt = nil
FILES["D/ui_tab_req.txt"] = "chat\t2\n"
U.pollTabReq()
check("window: Session and Chat stay the small window's", OPENED[2] == "win chat" and U.tabReqHub == nil, OPENED[2])
U.tabReqAt = nil
FILES["D/ui_tab_req.txt"] = "hub:\t3\n"
U.pollTabReq()
check("window: hub: opens the Hub on its first page", OPENED[3] == "hub session" and U.tabReqHub == true, OPENED[3])
U.ackTabReq("session", "ok", 12, "session,chat,f_stats")
check("window: the Hub's answer lists its pages", WRITTEN["D/ui_tab_shown.txt"] == "3\thub:\tsession\tok\t12\tsession,chat,f_stats\n", WRITTEN["D/ui_tab_shown.txt"])
U.HubWindow = nil
U.tabReqAt = nil
FILES["D/ui_tab_req.txt"] = "company\t4\n"
U.pollTabReq()
check("window: without the Hub, every tab is the small window's", OPENED[4] == "win company", OPENED[4])
''')
L.execute(r'''
H = {}
AUTO = { running = false, results = {}, points = {} }
G = { frames = 0, waits = {} }
TAB, NL, BS = "\t", "\n", "/"
C.ROLE = "host"
FILES, WRITTEN = {}, {}
FINISHED = nil
function autoFinish() AUTO.running = false; FINISHED = AUTO.results end
''')
L.execute(extract(BRIDGE, r"^H\.wintabs = function\(from, p\)\n.*?^end\n", "H.wintabs"))
L.execute(r'''
local function run() local w = G.waits; G.waits = {}; for _, x in ipairs(w) do x.fn() end end
local logs0 = #LOGS
H.wintabs("host", { role = "host" })
local asked = {}
for i = 1, 40 do
  local req = WRITTEN["D/ui_tab_req.txt"]
  local tab, seq = req:match("^([%w_:]+)\t(%d+)")
  if asked[#asked] ~= tab .. seq then
    asked[#asked + 1] = tab .. seq
    local shown = tab:match("^hub:(.*)$") or tab
    if shown == "" then shown = "session" end
    FILES["D/ui_tab_shown.txt"] = seq .. "\t" .. tab .. "\t" .. shown .. "\tok\t7" .. (tab:sub(1, 4) == "hub:" and "\tsession,company,f_stats" or "") .. "\n"
  end
  run()
  if FINISHED then break end
end
local r = table.concat(FINISHED or {}, "|")
check("scenario: the tabs, then the Hub opened with its pages", r:find("wintabs: settings drawn as settings, ok, 7 rows|hub: opened on session, 3 page(s): session,company,f_stats", 1, true) ~= nil, r)
check("scenario: every page of the Hub drawn in its turn", r:find("hub: session drawn, 7 rows|hub: company drawn, 7 rows|hub: f_stats drawn, 7 rows", 1, true) ~= nil, r)
local said = 0
for i = logs0 + 1, #LOGS do if LOGS[i]:find("AUTOTEST hub: f_stats drawn, 7 rows", 1, true) then said = said + 1 end end
check("scenario: AUTOTEST hub: <page> drawn, N rows in the log", said == 1, said)
ENV.MPFEVER_HUB = "0"
FINISHED = nil
H.wintabs("host", { role = "host" })
for i = 1, 20 do
  local req = WRITTEN["D/ui_tab_req.txt"]
  local tab, seq = req:match("^([%w_:]+)\t(%d+)")
  FILES["D/ui_tab_shown.txt"] = seq .. "\t" .. tab .. "\t" .. tab .. "\tok\t7\n"
  run()
  if FINISHED then break end
end
check("scenario, MPFEVER_HUB=0: the six tabs only", FINISHED and #FINISHED == 6, FINISHED and #FINISHED)
ENV.MPFEVER_HUB = nil
''')

# ---------------------------------------------------------------- the Hub's window content (U.hubContent)
L.execute(extract(UI, r"^U\.hubTip = function\(\)\n.*?^U\.hubContent = function\(K, st, chat, ctx\)\n.*?^end\n", "U.hubContent"))
L.execute(r'''
U.HubWindow = true
U.hubScreenWH, SCREEN, U.hubSize = nil, { x = 1920, y = 1080 }, 2
function syncLine() return "In sync", "success" end
U.TABS = U.TABS or {}
U.TABS.session = function(K, st) return { K.muted("Host: Ann", K.TEXT_W), K.section("i", "Sync"), K.text("ok", nil, nil, K.TEXT_W), K.gap(1, 8),
  K.section("i", "Players"), K.text("Ann", nil, nil, K.TEXT_W) } end
U.chatBody = function(K) return { K.text("hello") } end
U.status = { mode = "separate", opts = "stats=1" }
local st = { mode = "separate", opts = "stats=1", players = {} }
U.hubPage = "session"
local w0 = K.TEXT_W
local n = U.hubContent(K, st, {}, {})
local ms = U.hubMeasures()
check("content: the Hub's width", sizeOf(n).x == ms.W, sizeOf(n).x)
check("content: the kit's measures given back after drawing", K.TEXT_W == w0 and U.hubDrawing == nil)
local body = n.p.layout.p.children[3]
local side, page = body.p.children[1], body.p.children[3]
check("content: the menu, then the page, each a scroll area of the body's height", side.kind == "ScrollArea" and page.kind == "ScrollArea"
  and sizeOf(side).y == ms.bodyH and sizeOf(page).x == ms.pageW)
local labels, primary = {}, nil
for _, b in ipairs(buttons(side)) do labels[#labels + 1] = labelOf(b); if b.p.meta.class == "primary" then primary = labelOf(b) end end
check("content: the menu's groups and pages, the page shown in primary", texts(side):find("Game|Session|Chat|Rules and options|Settings|My company|Company|Sharing rules|Competition|Ranking", 1, true) ~= nil
  and primary == "Session", texts(side))
local cards = page.p.content.p.layout.p.children
check("content: the page in cards (its introduction, then a card per section)", #cards == 5 and cards[1].p.text == "Host: Ann" and cards[3].kind == "Component"
  and texts(cards[3]) == "Sync|ok" and texts(cards[5]) == "Players|Ann" and sizeOf(cards[3]).x == U.hubMeasures().inner, #cards)
check("content: the head (the page's name, its group, the sync)", texts(n.p.layout.p.children[1]):find("Session|Game   ·   |In sync", 1, true) ~= nil, texts(n.p.layout.p.children[1]))
local hb = buttons(n.p.layout.p.children[1])
check("content: the size buttons and the quick view", #hb == 3 and labelOf(hb[3]) == "Quick view")
-- a menu button shows its page; the page that fails says so
SETPAGE = nil
U.setHubPage = function(p) SETPAGE = p end
for _, b in ipairs(buttons(side)) do if labelOf(b) == "Ranking" then b.p.onClick() end end
check("content: a menu button asks its page", SETPAGE == "f_stats", SETPAGE)
U.TABS.company = function() error("boom") end
U.hubPage = "company"
local nf = U.hubContent(K, st, {}, {})
check("content: a page that fails says so (and the window still draws)", texts(nf):find("This page could not be drawn", 1, true) ~= nil and K.TEXT_W == w0)
U.hubPage = "chat"
local nc = U.hubContent(K, st, {}, {})
check("content: the chat page without a scroll area", nc.p.layout.p.children[3].p.children[3].kind == "Component" and texts(nc):find("hello", 1, true) ~= nil)
''')

failed = 0
for r in L.globals().RESULTS.values():
    print(f"{'ok  ' if r.ok else 'FAIL'} {r.name}" + ("" if r.ok else f" (got {r.got})"))
    failed += 0 if r.ok else 1
if failed:
    print(f"FAIL {failed} case(s)")
    sys.exit(1)
print("all cases passed")
sys.exit(0)
