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

(0.8.8) The Hub in the game's own style. The checks above (the page helpers, the module pages, the window's content) are those
of 0.8.7, unchanged, and run with the kit of MPFEVER_OLDHUB=1 (names starting with "MPFEVER_OLDHUB=1:"): the old drawing is
intact. The same parts are then checked in the new drawing ("game style:"):
  - the kit: the theme's colours and their fallbacks, K.panel (the game's nine-patch card and its contour), K.tint (the Finances
    table's backgrounds), a button's icon, the locate button, the money classes; nothing of it outside the Hub (the small window);
  - the headings (the game's ContentCard{ title } when its module loads, a title and a thin line by hand when it does not, or
    when it changed), the bars (builtin.ProgressBar, the rectangles of before when the game has none), the cards (a heading above
    its card, 8 pixels between two cards), « How does it work? »;
  - the window's content: the groups as North tabs, the group's pages in the game's List with their icons, the page's name in the
    window's title, the state and the size buttons at the right of the tabs; the head and the menu of before when the game no
    longer has the tabs or the list;
  - the choices (the sharing rules, an option's On / Off and its values, the speed) as the game's groups of toggle buttons, with
    the same requests as the buttons of before, and those buttons when the game has no such group.
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
PREFIX = ""
function check(name, cond, got)
  RESULTS[#RESULTS + 1] = { name = PREFIX .. name, ok = cond and true or false, got = tostring(got) }
end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function T(fr, en) return en end
function money(n) return "$" .. tostring(n) end
function sendLine(kind, p) end
ENV = {}
os.getenv = function(k) return ENV[k] end
-- the game's builtin module: each component says what it is and what it was given
builtin = setmetatable({ type = { Orientation = { Vertical = "V", Horizontal = "H" }, ScrollBarPolicy = { AlwaysOff = 0, AsNeeded = 1 },
  TabOrientation = { North = "N" } } }, {
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
  -- (a tab strip: its tabs, each one its indicator and its item)
  if n.p.tabs then return n.p.tabs end
  if n.p.indicator or n.p.item then return { n.p.indicator, n.p.item } end
  -- (a group of toggle buttons: the content of each)
  if n.p.buttons then local out = {} for _, b in ipairs(n.p.buttons) do out[#out + 1] = b.content end return out end
  return {}
end
function walk(n, fn) fn(n); for _, c in ipairs(kids(n)) do walk(c, fn) end end
function texts(n) local out = {} walk(n, function(x) if x.kind == "TextView" then out[#out + 1] = x.p.text end end) return table.concat(out, "|") end
function buttons(n) local out = {} walk(n, function(x) if x.kind == "Button" then out[#out + 1] = x end end) return out end
function labelOf(b) return texts(b.p.content) end
function sizeOf(n) local s = n.p and n.p.meta and n.p.meta.styleSheet return s and s.size end
function bgOf(n) local s = n.p and n.p.meta and n.p.meta.styleSheet return s and s.backgroundColor end
function styleOf(n) return n and n.p and n.p.meta and n.p.meta.styleSheet or {} end
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
-- ---- (0.8.8) the game's theme in the kit; the kit of MPFEVER_OLDHUB=1 (the variable is read once, when the kit is made)
ENV.MPFEVER_OLDHUB = "1"
KO = U.makeKit(builtin)
ENV.MPFEVER_OLDHUB = nil
check("kit: the new drawing by default, MPFEVER_OLDHUB=1 the old one", K.game == true and K.old == false and KO.game == false and KO.old == true)
U.hubDrawing = nil
check("kit: K.hub() only while the Hub draws a page", K.hub() == false and KO.hub() == false)
U.hubDrawing = true
check("kit: K.hub() while the Hub draws, never with MPFEVER_OLDHUB=1", K.hub() == true and KO.hub() == false)
check("kit: the colours' fallbacks are the game's theme (Error #CE2029, BaseMedium, Positive)", same(K.rgba("Error"), { 0.808, 0.125, 0.161, 1 })
  and same(K.rgba("BaseMedium"), { 0.1575, 0.18375, 0.21, 1 }) and same(K.color("Positive"), { 0.541, 0.725, 0.945, 1 }) and same(K.rgba("Info", 0.25), { 0.176, 0.408, 0.769, 0.25 }))
check("kit: K.tint, the Finances table's backgrounds", same(K.tint("head"), K.rgba("BaseDark")) and same(K.tint("odd"), K.rgba("BaseLight"))
  and same(K.tint("even"), K.rgba("BaseMedium")) and same(K.tint("mine"), K.rgba("AccentDark")) and same(K.tint("track"), K.rgba("BaseVeryDark")) and K.tint("nope") == nil)
local ps = K.style(K.panel("card", { size = { 400, -1 } }))
check("kit: K.panel, the game's card: its nine-patch surface in BaseMedium, its contour in BaseVeryLight, the padding 10 / 18",
  ps.backgroundImage1.fileName == "::/gui/entity_window/design/card_surface.tga" and ps.backgroundImage1.horizontal[2] == 6 and ps.backgroundImage1.vertical[4] == 32
  and same(ps.backgroundColor1, K.rgba("BaseMedium")) and ps.borderImage.fileName == "::/gui/entity_window/design/card_contour.tga" and ps.borderImage.horizontal[3] == 26
  and same(ps.borderColor, K.rgba("BaseVeryLight")) and ps.padding[1] == 10 and ps.padding[2] == 18 and ps.size.x == 400 and ps.backgroundColor == nil)
local pw = K.style(K.panel("warning", { padding = { 6, 10, 6, 10 } }))
check("kit: K.panel tinted, the status colour at alpha 0.25 as the game's info bubble; the fields given win", same(pw.backgroundColor1, K.rgba("Warning", 0.25))
  and same(pw.borderColor, K.rgba("Warning", 0.5)) and pw.padding[2] == 10 and same(K.style(K.panel("mine")).borderColor, K.rgba("AccentLight")))
local ib = K.btn("Accept", "tip", nil, true, nil, K.ICON_ACCEPT)
check("kit: K.btn with an icon, the game's icon-and-text button (an image, then the text)", ib.kind == "Button" and ib.p.meta.class == "primary" and ib.p.content.kind == "BoxLayout"
  and ib.p.content.p.children[1].kind == "ImageView" and ib.p.content.p.children[1].p.path == K.ICON_ACCEPT and sizeOf(ib.p.content.p.children[1]).x == 18
  and labelOf(ib) == "Accept")
check("kit: K.btn without an icon as before", K.btn("Go").p.content.kind == "TextView" and K.btn("Go", nil, nil, false, false).p.meta.enabled == false)
local lb = K.locate("Show", nil, function() end)
check("kit: K.locate, the game's locate icon alone, the text as its tooltip", lb.kind == "Button" and lb.p.content.kind == "ImageView" and lb.p.content.p.path == K.ICON_LOCATE
  and lb.p.meta.tooltip == "Show" and K.locate("Show", "There", nil).p.meta.tooltip == "There")
check("kit: K.iw, K.moneyCls in the Hub's new drawing", K.iw(2) == 44 and K.moneyCls("success") == "positive" and K.moneyCls("error") == "negative" and K.moneyCls("warning") == "warning")
local s2 = K.style { image = "a.tga", nine = { 1, 2, 3, 4 }, nineV = { 5, 6, 7, 8 }, border = "b.tga", borderWidth = { 1, 1, 1, 1 }, image2 = "c.tga", bg2 = K.color("Info") }
check("kit: K.style's new fields (a nine-patch with its own vertical cut, a border's image and width, a second layer); the old ones as before",
  s2.backgroundImage1.horizontal[1] == 1 and s2.backgroundImage1.vertical[1] == 5 and s2.borderImage.fileName == "b.tga" and s2.borderImage.vertical[4] == 8
  and s2.borderWidth[1] == 1 and s2.backgroundImage2.fileName == "c.tga" and same(s2.backgroundColor2, K.rgba("Info")) and s2.borderColor == nil
  and K.style({ image = "a.tga", nine = { 1, 2, 3, 4 } }).backgroundImage1.vertical[1] == 1 and K.style({ size = { 3, 4 } }).borderImage == nil)
check("kit: an icon that is not a square (the fold arrows, 17 x 12)", sizeOf(K.icon("x.tga", 17, 12)).y == 12 and sizeOf(K.icon("x.tga", 20)).y == 20)
check("MPFEVER_OLDHUB=1: no icon in a button, « Show » a text button, the status classes kept", KO.btn("Accept", nil, nil, true, nil, KO.ICON_ACCEPT).p.content.kind == "TextView"
  and KO.locate("Show", nil, nil).p.content.kind == "TextView" and KO.iw(2) == 0 and KO.moneyCls("success") == "success")
U.hubDrawing = nil
check("outside the Hub (the small window): no icon, « Show » a text button, the status classes kept", K.btn("Accept", nil, nil, true, nil, K.ICON_ACCEPT).p.content.kind == "TextView"
  and K.locate("Show", nil, nil).p.content.kind == "TextView" and K.iw(2) == 0 and K.moneyCls("success") == "success"
  and same(bgOf(K.card({ K.text("x") })), { 1, 1, 1, 0.06 }) and K.section("i", "T").p.children[1].kind == "ImageView")
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
-- (0.8.8) an icon of the game's for every page of the menu, the gear for a page of a later version
local noIcon = {}
for _, g in ipairs(U.HUB_GROUPS) do for _, id in ipairs(g.pages) do
  if type(U.HUB_ICON[id]) ~= "string" or not U.HUB_ICON[id]:match("^[%w_]*::/.+%.tga$") or U.hubIcon(id) ~= U.HUB_ICON[id] then noIcon[#noIcon + 1] = id end
end end
check("menu: every page has its icon, a page of a later version the settings' gear", #noIcon == 0 and U.hubIcon("f_later") == "::/gui/menu/icons/settings.tga", table.concat(noIcon, ","))
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
check("measures: two thirds of a 1920 x 1080 screen (the texts 40 narrower than the cards: the game's padding)", ms.W == 1286 and ms.H == 723 and ms.text == ms.inner - 40 and ms.pageW == ms.W - ms.side - 14, ms.W .. "x" .. ms.H)
U.oldHub = true
check("MPFEVER_OLDHUB=1: the measures of before (the texts 24 narrower)", U.hubMeasures().text == U.hubMeasures().inner - 24 and U.hubMeasures().W == 1286)
U.oldHub = false
U.hubScreenWH = nil; SCREEN = { x = 1280, y = 720 }
ms = U.hubMeasures()
check("measures: never under 900 x 520", ms.W == 900 and ms.H >= 520, ms.W .. "x" .. ms.H)
U.hubScreenWH = nil; SCREEN = { x = 3840, y = 2160 }; U.hubSize = 3
ms = U.hubMeasures()
check("measures: the large size of a 4K screen", ms.W == 3072 and ms.H == 1728, ms.W .. "x" .. ms.H)
U.hubScreenWH = nil; SCREEN = nil; U.hubSize = 2
ms = U.hubMeasures()
check("measures: 1920 x 1080 when the screen cannot be read", ms.W == 1286, ms.W)
-- ---- (0.8.8) the interface's unit: the 3D view is measured in pixels, the Hub in the interface's units (a 4K screen: 2 pixels
-- a unit; the Hub was 2572 units wide on a screen of 1920 and covered it all, "hub: 1 x 1 of the screen")
check("unit: a 4K screen never measured: 2 pixels a unit; a smaller one: 1", U.hubUnitOf(3840, 2054, nil) == 2 and U.hubUnitOf(1920, 1080, nil) == 1 and U.hubUnitOf(2560, 1440, nil) == 1)
check("unit: the one measured for that screen; another screen's or a senseless one is left",
	U.hubUnitOf(3840, 2054, "3840,2054,1.5") == 1.5 and U.hubUnitOf(3840, 2054, "2560,1440,1.5") == 2 and U.hubUnitOf(3840, 2054, "3840,2054,9") == 2)
local un, again = U.hubUnitFrom(1, 1, 2572, 1376, 3840, 2054, 1)
check("unit: a Hub cut by the screen (the whole of it): half as many units next, drawn again", un == 1.5 and again == true, un)
un, again = U.hubUnitFrom(0.67, 0.71, 1286, 688, 3840, 2054, 2)
check("unit: 1286 units on 0.67 of 3840 pixels: 2 pixels a unit, not drawn again", math.abs(un - 2) < 0.01 and again == false, un)
un, again = U.hubUnitFrom(0.335, 0.36, 1286, 688, 3840, 2054, 2)
check("unit: a 4K screen whose interface is not enlarged: 1 pixel a unit, drawn again", math.abs(un - 1) < 0.01 and again == true, un)
do
	local gs, cs, lp = api.gui.byId.getSize, api.gui.camera.getSize, U.loadPrefs
	api.gui.byId.getSize = function(id) error("no " .. id) end
	api.gui.camera.getSize = function() return { x = 3840, y = 2054 } end
	U.prefs = {}
	U.loadPrefs = function() return U.prefs end
	U.hubScreenWH = nil; U.hubSize = 2
	ms = U.hubMeasures()
	check("measures: a 4K screen read from the 3D view: 1286 units wide (2 pixels a unit), not 2572", ms.W == 1286 and U.hubUnitNow == 2, ms.W)
	U.prefs = { hubu = "3840,2054,1" }
	U.hubScreenWH = nil
	ms = U.hubMeasures()
	check("  measured at 1 pixel a unit for that screen: 2572", ms.W == 2572, ms.W)
	ENV.MPFEVER_HUBUNIT = "0"
	U.prefs = {}
	U.hubScreenWH = nil
	ms = U.hubMeasures()
	check("  MPFEVER_HUBUNIT=0: the pixels taken for units, as before", ms.W == 2572, ms.W)
	ENV.MPFEVER_HUBUNIT = nil
	api.gui.byId.getSize, api.gui.camera.getSize, U.loadPrefs = gs, cs, lp
	U.prefs = nil
	U.hubScreenWH = nil; SCREEN = nil
	ms = U.hubMeasures()
end
''')

# ---------------------------------------------------------------- MPFEVER_OLDHUB=1: the Hub's drawing of before 0.8.8, intact.
# The three parts below (the page helpers, the module pages, the window's content) are the checks of 0.8.7, unchanged, run with
# the kit made with MPFEVER_OLDHUB=1; the same parts for the new drawing come after them.
L.execute(r'''
KN, K = K, KO
U.oldHub = true
U.HUB_COLORS = U.HUB_COLORS_OLD
PREFIX = "MPFEVER_OLDHUB=1: "
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
L.execute('PREFIX = ""')
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
PREFIX = "MPFEVER_OLDHUB=1: "
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

# ================================================================ (0.8.8) the Hub in the game's own style: the new drawing
# (the kit made without MPFEVER_OLDHUB; the same helpers, pages and content as above, drawn with the game's cards, tables...)
L.execute(r'''
K = KN
U.oldHub = false
U.HUB_COLORS = U.HUB_COLORS_GAME
PREFIX = "game style: "
K.TEXT_W = 700
U.TABS.company = nil
local M0 = { ID = "stats" }
local st = { mode = "separate", opts = "stats=1", players = {} }
-- outside the Hub (the small window): the helpers as before, with the new kit too
local p = U.featU(K, st, M0)
check("plain (new kit): u.title the section with its icon, u.table rows of texts, u.card its texts", p.rich == false and p.title("X").p.children[1].kind == "ImageView"
  and texts(p.table({ { "a", "b" }, { "1", "2" } }, nil, true)) == "a|b|1|2" and texts(p.card("C", { p.text("x") })) == "C|x")
U.hubDrawing, U.hubMarks = true, {}
local u = U.featU(K, st, M0)
-- a card: the game's card, tinted
local c = u.card("Bob Co", { u.text("hello") }, { color = { 1, 0, 0 }, tint = "warning" })
local cs = styleOf(c)
check("u.card: the game's card of the page's width (text + 40: its padding 18 on each side), tinted as the game's info bubble", c.kind == "Component" and sizeOf(c).x == 740
  and cs.backgroundImage1.fileName == K.CARD_SURFACE and same(cs.backgroundColor1, K.rgba("Warning", 0.25)) and cs.borderImage.fileName == K.CARD_CONTOUR
  and cs.padding[1] == 10 and cs.padding[2] == 18 and cs.backgroundColor == nil and U.hubMarks[c] == "card", sizeOf(c).x)
check("u.card: its texts", texts(c) == "Bob Co|hello")
check("u.card plain: BaseMedium with the contour in BaseVeryLight", same(styleOf(u.card("X", {})).backgroundColor1, K.rgba("BaseMedium")) and same(styleOf(u.card("X", {})).borderColor, K.rgba("BaseVeryLight")))
-- a table: the Finances table's colours, 12 pixels around the cells
local btn = u.button("Go", function() end)
local tb = u.table({ { "#", "Company", "Value" }, { "1", "Bob", "$5" }, { "2", "Ann", btn } }, { 30, 300, 100 }, true,
  { highlight = function(i, line) return line[2] == "Ann" end })
local tr = tb.p.children
check("u.table: the head on BaseDark, the rows BaseLight / BaseMedium, this player's row in the accent", #tr == 3 and same(bgOf(tr[1]), K.tint("head")) and same(bgOf(tr[2]), K.tint("odd"))
  and same(bgOf(tr[3]), K.tint("mine")) and same(bgOf(u.table({ { "a" }, { "b" } }).p.children[2]), K.tint("even")))
local cw = {}
for i, cell in ipairs(tr[2].p.layout.p.children) do cw[i] = sizeOf(cell).x end
check("u.table: 12 pixels around the cells, the columns stretched to what is left", styleOf(tr[2]).padding[1] == 12 and styleOf(tr[2]).padding[2] == 12 and sizeOf(tr[2]).x == 700
  and cw[1] + cw[2] + cw[3] == 700 - 24 and tr[2].p.layout.p.children[2].p.layout.p.children[1].p.width == cw[2] - 12, table.concat(cw, ","))
check("u.table: a node in a cell", tr[3].p.layout.p.children[3].p.layout.p.children[1] == btn)
-- a figure: a darker box with the contour
local sb = u.stat("Value", "$5", nil, { width = 200 })
check("u.stat: a darker panel with the card's contour, the same widths", sizeOf(sb).x == 200 and same(styleOf(sb).backgroundColor1, K.rgba("BaseDark"))
  and styleOf(sb).borderImage.fileName == K.CARD_CONTOUR and styleOf(sb).padding[2] == 10 and texts(sb) == "Value|$5")
check("u.bar / u.card swatch: the status colours are the game's", same(U.hubRgba("error"), { 0.808, 0.125, 0.161, 1 }) and same(U.hubRgba("success"), { 0.298, 0.733, 0.09, 1 }))
U.hubDrawing, U.hubMarks = nil, nil
''')

# ---------------------------------------------------------------- the headings and the bars (the game's ContentCard and
# ProgressBar), and what is drawn when the game no longer has them
L.execute(extract(UI, r"^U\.helpFolded = U\.helpFolded or \{\}\nU\.helpCard = function\(K, rows, key, paragraphs\)\n.*?^end\n", "U.helpCard"))
L.execute(r'''
function nodesOf(n, kind) local out = {} walk(n, function(x) if x.kind == kind then out[#out + 1] = x end end) return out end
local st = { mode = "separate", opts = "stats=1", players = {} }
local M0 = { ID = "stats" }
U.hubDrawing, U.hubMarks = true, {}
-- no base module here (the tests have no ug_require): the heading drawn by hand, no error
local logs0 = #LOGS
local h = K.heading("Sync", 500)
check("heading, the game's module missing: the title in the headline font and a thin line under it, no error", h.kind == "BoxLayout" and h.p.children[1].kind == "TextView"
  and h.p.children[1].p.meta.class == "font-scale-headline" and h.p.children[1].p.width == 500 and sizeOf(h.p.children[3]).x == 500 and sizeOf(h.p.children[3]).y == 1
  and same(bgOf(h.p.children[3]), K.tint("line")) and texts(h) == "Sync")
local said = 0
for i = logs0 + 1, #LOGS do if LOGS[i]:find("content_card.tl not usable", 1, true) then said = said + 1 end end
K.heading("Again", 500)
check("heading: the missing module is said once in the log, and asked for once", said == 1 and #LOGS == logs0 + 1, #LOGS - logs0)
local sec = K.section("icon", "Players")
check("K.section in the Hub: the heading, as wide as the page's cards, without an icon", texts(sec) == "Players" and #nodesOf(sec, "ImageView") == 0 and sec.p.children[1].p.width == 740)
local u = U.featU(K, st, M0)
local t = u.title("Ranking")
check("u.title: the heading, marked as a title", texts(t) == "Ranking" and t.p.children[1].p.meta.class == "font-scale-headline" and U.hubMarks[t] == "title")
check("u.card: its title in the headline font", u.card("Bob", {}).p.layout.p.children[1].p.children[1].p.meta.class == "font-scale-headline")
-- the game's module there: its ContentCard with the title alone, in a box of the width
REQ = {}
ug_require = function(path)
  REQ[#REQ + 1] = path
  if path == "::/gui/main/content_card.tl" then return { ContentCard = function(p) return { kind = "ContentCard", p = p } end } end
  error("no " .. path)
end
local KB = U.makeKit(builtin)
local hb = KB.heading("Sync", 500)
local ccs = nodesOf(hb, "ContentCard")
check("heading, with the game's module: ContentCard{ title } alone (no callout, no game context), in a box of the width", hb.kind == "Component" and sizeOf(hb).x == 500
  and #ccs == 1 and ccs[1].p.title == "Sync" and next(ccs[1].p, "title") == nil and next(ccs[1].p) == "title" and REQ[1] == "::/gui/main/content_card.tl")
KB.heading("Two", 500)
check("heading: the module asked for once per kit", #REQ == 1, #REQ)
-- a game update that changed the module (no ContentCard in it, or one that fails): drawn by hand
ug_require = function(path) return { Other = true } end
local KC = U.makeKit(builtin)
check("heading, the module without its recipe: drawn by hand", KC.heading("X", 300).kind == "BoxLayout" and texts(KC.heading("X", 300)) == "X")
ug_require = function(path) return { ContentCard = function() error("changed") end } end
local KD = U.makeKit(builtin)
TRACK = {}
local hd = KD.heading("X", 300)
local seen = {}
walk(hd, function(x) seen[x] = true end)
local left = 0
for _, n in ipairs(TRACK) do if not seen[n] then left = left + 1 end end
TRACK = nil
check("heading, a recipe that fails: drawn by hand, no node left out", hd.kind == "BoxLayout" and texts(hd) == "X" and left == 0, left)
-- MPFEVER_HUBBASE=0 (read once, when the kit is made): none of the game's script modules is asked for
REQ = {}
ug_require = function(path) REQ[#REQ + 1] = path return { ContentCard = function(p) return { kind = "ContentCard", p = p } end } end
ENV.MPFEVER_HUBBASE = "0"
local KE = U.makeKit(builtin)
ENV.MPFEVER_HUBBASE = nil
check("MPFEVER_HUBBASE=0: the heading drawn by hand, the game's module never asked for", KE.heading("X", 300).kind == "BoxLayout" and texts(KE.heading("X", 300)) == "X" and #REQ == 0
  and KE.game == true and KE.noBase == true and K.noBase == false, #REQ)
ug_require = nil
-- the bars: the game's ProgressBar
K.TEXT_W = 700
u = U.featU(K, st, M0)
local bar = u.bar(0.25, { 0, 1, 0 }, "25 %", { lead = "Bob", leadW = 100, labelW = 60 })
local pb = bar.p.children[3]
check("u.bar: the game's ProgressBar at the fraction, of the room left, 20 high, in the colour", pb.kind == "ProgressBar" and pb.p.value == 0.25 and sizeOf(pb).x == 700 - 100 - 60 - 20
  and sizeOf(pb).y == 20 and same(styleOf(pb).color, { 0, 1, 0, 1 }) and pb.p.meta.class == "font-scale-annotation", sizeOf(pb) and sizeOf(pb).x)
check("u.bar: its texts beside it, at their widths", texts(bar) == "Bob|25 %" and bar.p.children[1].p.width == 100 and bar.p.children[5].p.width == 60)
check("u.bar: 0 and more than 1 kept in 0..1, a class's colour the game's", u.bar(-1, "info").p.children[1].p.value == 0 and u.bar(2, "info", nil, { width = 300 }).p.children[1].p.value == 1
  and sizeOf(u.bar(2, "info", nil, { width = 300 }).p.children[1]).x == 300 and same(styleOf(u.bar(1, "error").p.children[1]).color, { 0.808, 0.125, 0.161, 1 }))
U.coColors = { [7] = 3 }
check("u.bar: in a company's colour (its number)", same(styleOf(u.bar(1, 7, nil, { width = 50 }).p.children[1]).color, { 0.3, 0.2, 0.3, 1 }))
-- a game without that widget: the two rectangles of before, no error
rawset(builtin, "ProgressBar", false)
local ob = u.bar(0.25, { 0, 1, 0 }, "25 %", { lead = "Bob", leadW = 100, labelW = 60 })
local track = ob.p.children[3].p.layout.p.children[2]
check("u.bar, a game without ProgressBar: the track and its fill as before", #nodesOf(ob, "ProgressBar") == 0 and sizeOf(track).x == 520 and sizeOf(track).y == 14
  and same(bgOf(track), U.HUB_TINT.track) and sizeOf(track.p.layout.p.children[1]).x == 130 and texts(ob) == "Bob|25 %")
rawset(builtin, "ProgressBar", function() error("changed") end)
TRACK = {}
ob = u.bar(0.5, "info", nil, { width = 100 })
seen, left = {}, 0
walk(ob, function(x) seen[x] = true end)
for _, n in ipairs(TRACK) do if not seen[n] then left = left + 1 end end
TRACK = nil
check("u.bar, a ProgressBar that fails: the rectangles of before, no node left out", sizeOf(ob.p.children[1].p.layout.p.children[2]).x == 100 and left == 0, left)
rawset(builtin, "ProgressBar", nil)
-- U.hubCards: the heading above its card (the Finances window's way)
local marks = {}
local function mk(kind, t) local n = { kind = "TextView", p = { text = t } } if kind then marks[n] = kind end return n end
local intro, t1, a, g1, t2, cd, g2, t3 = mk(nil, "intro"), mk("title", "One"), mk(nil, "a"), mk("gap", ""), mk("title", "Two"), mk("card", "card"), mk("gap", ""), mk("title", "Help")
local pz = mk(nil, "p")
marks.tints = { [t3] = "info" }
local out = U.hubCards(K, { intro, t1, a, g1, t2, cd, g2, t3, pz }, marks, 740)
check("cards: the introduction as it is; a title stays above its card, which holds its rows only", out[1] == intro and sizeOf(out[2]).y == 8 and out[3] == t1 and sizeOf(out[4]).y == 4
  and out[5].kind == "Component" and texts(out[5]) == "a" and sizeOf(out[5]).x == 740 and styleOf(out[5]).backgroundImage1.fileName == K.CARD_SURFACE
  and same(styleOf(out[5]).backgroundColor1, K.rgba("BaseMedium")) and styleOf(out[5]).padding[2] == 18, #out)
check("cards: the gaps at a group's end after its card; a group that holds a card keeps it as it is", out[6] == g1 and out[7] == t2 and sizeOf(out[8]).y == 4 and out[9] == cd and out[10] == g2, #out)
check("cards: a card tinted for its title (the help: the info bubble's colour)", out[11] == t3 and texts(out[13]) == "p" and same(styleOf(out[13]).backgroundColor1, K.rgba("Info", 0.25)) and out[14] == nil, #out)
local lone = U.hubCards(K, { mk("title", "Folded") }, marks, 740)
check("cards: a title without rows, the heading alone", #lone == 1 and texts(lone[1]) == "Folded")
local one = U.hubCards(K, { mk(nil, "x"), mk(nil, "y") }, marks, 740)
check("cards: a page without a title, one card", #one == 1 and texts(one[1]) == "x|y" and styleOf(one[1]).borderImage.fileName == K.CARD_CONTOUR)
-- « How does it work? »: the info bubble's icon, folded by the game's arrow
U.hubMarks = {}
U.helpFolded = {}
local hr = {}
U.helpCard(K, hr, "t", { "one", "two" })
local hh = hr[2]
check("help: its head (the outlined « i », the title in the headline font, the fold arrow with its word as a tooltip), a title tinted info", U.hubMarks[hh] == "title"
  and U.hubMarks.tints[hh] == "info" and hh.p.children[1].p.path == K.ICON_INFO and hh.p.children[3].p.meta.class == "font-scale-headline" and texts(hh) == "How does it work?"
  and buttons(hh)[1].p.content.p.path == K.ICON_FOLD and buttons(hh)[1].p.meta.tooltip == "Hide" and sizeOf(buttons(hh)[1].p.content).y == 12 and texts({ kind = "BoxLayout", p = { children = hr } }):find("one|two", 1, true) ~= nil)
buttons(hh)[1].p.onClick()
hr = {}
U.helpCard(K, hr, "t", { "one", "two" })
check("help: a click folds it (the arrow down, « Show »), its texts gone", U.helpFolded.t == true and #hr == 2 and buttons(hr[2])[1].p.content.p.path == K.ICON_UNFOLD and buttons(hr[2])[1].p.meta.tooltip == "Show")
U.helpFolded = {}
U.hubDrawing, U.hubMarks = nil, nil
''')

# ---------------------------------------------------------------- the module pages in the Hub's new drawing
L.execute(r'''
FILES = {}
FILES["D/feat_territory_board.txt"] = table.concat({ "rule\t2\t5", "me\tclaim\t11\t0", "town\t13\tCité\t1\t20000\t21000", "town\t12\tBourg\t0\t15000\t16000",
  "terr\t2\tBob Co\tAville\t2\ton\t60\t0\t1000\t1100", "hc\t2\tBob Co\t50\t1000000" }, "\n")
local stT = { mode = "separate", opts = "handicap=1;territory=1", players = {} }
local hubT = page("f_territory", stT)
local tt = texts(hubT)
check("territories: every node it made is in its tree", LEFT == 0, LEFT)
check("territories: the same tables, the same buttons (View per town and territory, Claim for the free town)", tt:find("Town|State|", 1, true) ~= nil and tt:find("Cité|free", 1, true) ~= nil
  and tt:find("Bob Co|Aville|2 km|60 more month(s)", 1, true) ~= nil and (function() local v, c = 0, 0 for _, b in ipairs(buttons(hubT)) do
    if labelOf(b) == "View" then v = v + 1 elseif labelOf(b) == "Claim" then c = c + 1 end end return v == 3 and c == 1 end)(), tt)
CAM = {}
check("territories: View still moves the camera, Claim still asks", press(hubT, "View") and CAM[1] and CAM[1][1] == 20000 and CAM[1][3] == 1500 and press(hubT, "Claim"))
FILES["D/feat_tenders_list.txt"] = table.concat({ "month\t10", "me\t2", "co\t1\tAnn Co\t1\t0\t0", "co\t2\tBob Co\t2\t0\t0",
  "open\t1\tpax\t200\t3\t50000\tAville\tBourg\t\t10\t20\t30\t40", "prog\t1\t1\t50", "prog\t1\t2\t100" }, "\n")
local hubTd = page("f_tenders", { mode = "separate", opts = "tenders=1", players = {} })
check("tenders: every node in its tree", LEFT == 0, LEFT)
local pbs = nodesOf(hubTd, "ProgressBar")
check("tenders: a ProgressBar per company that started, at its progress; its two buttons and the help's fold arrow", #pbs == 2 and pbs[1].p.value + pbs[2].p.value == 0.75
  and texts(hubTd):find("50 %", 1, true) ~= nil and #buttons(hubTd) == 3, #buttons(hubTd))
FILES["D/feat_stock_stock.txt"] = table.concat({ "opt\t25\t0\t10\t5\t3\t2\t10", "me\t2\t-1",
  "co\t1\t0\t500000\t400000\t5000000\t0\t0\t0\t6\t4\t1\tAnn Co", "co\t2\t0\t300000\t300000\t3000000\t0\t0\t0\t8\t2\t2\tBob Co" }, "\n")
local hubS = page("f_stock", { mode = "separate", opts = "stock=1", players = {} })
local ts = texts(hubS)
check("stocks: every node in its tree", LEFT == 0, LEFT)
local mineCard = 0
walk(hubS, function(x) if same(styleOf(x).backgroundColor1, K.rgba("Info", 0.25)) and styleOf(x).backgroundImage1 then mineCard = mineCard + 1 end end)
check("stocks: each company's card with its figures and buttons, this player's tinted; the help at the end in the info bubble's colour (2 tinted cards)",
  ts:find("1. Ann Co|Value|$5000000|Share  +25 %|$500000|Dividend|$0|Your shares|0/10", 1, true) ~= nil and mineCard == 2 and press(hubS, "Buy 1 ($500000)")
  and ts:find("How does it work?|Every company has 10 shares. Their price", 1, true) ~= nil, mineCard)
FILES["D/feat_market_shares.txt"] = table.concat({ "me\t2", "month\t5", "co\t1\t0\tAnn Co", "co\t2\t0\tBob Co", "tot\t1\t600\t-1\t2\t0", "tot\t2\t400\t1000\t1\t1" }, "\n")
local hubMk = page("f_market", { mode = "separate", opts = "market=1", players = {} })
check("market: every node in its tree; the shares as ProgressBars; the totals' table", LEFT == 0 and #nodesOf(hubMk, "ProgressBar") == 4
  and texts(hubMk):find("Bob Co (you)|40 %|100 %", 1, true) ~= nil, #nodesOf(hubMk, "ProgressBar"))
FILES["D/feat_stats_main.txt"] = table.concat({ "host\t0", "me\t2", "mode\tseparate", "opts\t0\t1\t0\t0", "co\t1\t0.9,0.1,0.1\t0\t0\tAnn Co",
  "co\t2\t0.1,0.1,0.9\t0\t0\tBob Co", "last\t5", "m\t5\t2001\t6\t1:100,0,50;2:200,10,0" }, "\n")
local hubSt = page("f_stats", { mode = "separate", opts = "stats=1", players = {} })
check("ranking: every node in its tree", LEFT == 0, LEFT)
local sp = nodesOf(hubSt, "ProgressBar")
local mineS = 0
walk(hubSt, function(x) if same(bgOf(x), K.tint("mine")) then mineS = mineS + 1 end end)
check("ranking: the values as ProgressBars in the companies' colours, this player's row in the accent", #sp == 4 and same(styleOf(sp[1]).color, { 0.1, 0.1, 0.9, 1 })
  and same(styleOf(sp[2]).color, { 0.9, 0.1, 0.1, 1 }) and mineS == 1, #sp)
FILES = {}
local stAll = { mode = "separate", opts = allOn("separate"), players = {} }
local bad = {}
for _, tb in ipairs(U.featTabs(stAll)) do
  local _, rows = page(tb.key, stAll)
  local s = texts({ kind = "BoxLayout", p = { children = rows } })
  if s:find("could not be drawn", 1, true) then bad[#bad + 1] = tb.key end
  if LEFT > 0 then bad[#bad + 1] = tb.key .. " (" .. LEFT .. " node(s) left out)" end
end
check("every module's page draws in the new drawing without its file, no node left out", #bad == 0, table.concat(bad, ","))
''')

# ---------------------------------------------------------------- the Hub's window content in the new drawing: the groups as North
# tabs, the group's pages in a list, the page's name in the window's title, the state and the size at the right of the tabs
L.execute(r'''
U.HubWindow = true
U.hubScreenWH, SCREEN, U.hubSize = nil, { x = 1920, y = 1080 }, 2
U.TABS.session = function(K, st) return { K.muted("Host: Ann", K.TEXT_W), K.section("i", "Sync"), K.text("ok", nil, nil, K.TEXT_W), K.gap(1, 12),
  K.section("i", "Players"), K.text("Ann", nil, nil, K.TEXT_W) } end
U.TABS.rules = function(K, st) return { K.text("the rules", nil, nil, K.TEXT_W) } end
U.status = { mode = "separate", opts = "stats=1" }
local st = { mode = "separate", opts = "stats=1", players = {} }
U.hubPage, U.hubLastIn, U.tabReqHub = "session", nil, nil
SETPAGE, SIZED, OPENED = nil, nil, {}
U.setHubPage = function(p) SETPAGE = p end
U.setHubSize = function(d) SIZED = d end
local w0 = K.TEXT_W
-- (drawn with every node counted: none may be made and left out of the tree)
function content()
  TRACK = {}
  local n = U.hubContent(K, st, {}, {})
  local seen = {}
  walk(n, function(x) seen[x] = true end)
  LEFT = 0
  for _, x in ipairs(TRACK) do if not seen[x] then LEFT = LEFT + 1 end end
  TRACK = nil
  return n
end
local n = content()
local ms = U.hubMeasures()
check("content: the Hub's width, every node in its tree, the kit's measures given back", sizeOf(n).x == ms.W and LEFT == 0 and K.TEXT_W == w0 and U.hubDrawing == nil, LEFT)
local head, body = n.p.layout.p.children[1], n.p.layout.p.children[3]
local side, page = body.p.children[1], body.p.children[3]
check("content: the tabs' row, 8 pixels, then the list and the page", sizeOf(n.p.layout.p.children[2]).y == 8 and sizeOf(body.p.children[2]).x == 8 and page.kind == "ScrollArea"
  and sizeOf(page).x == ms.pageW and sizeOf(page).y == ms.bodyH and sizeOf(side).x == ms.side and sizeOf(side).y == ms.bodyH)
-- the groups: North tabs with empty items
local tw = nodesOf(head, "TabWidget")[1]
local tabNames = {}
for i, tc in ipairs(tw and tw.p.tabs or {}) do tabNames[i] = tc.p.value .. "=" .. tc.p.indicator.p.text .. "/" .. tc.p.indicator.p.meta.class .. "/" .. tc.p.item.kind end
check("content: the three groups as North tabs (the game's TabWidget, a header only), the page's group chosen", tw ~= nil and tw.p.orientation == "N" and tw.p.meta.class == "no-content"
  and tw.p.deselectAllowed == false and tw.p.value == "game"
  and table.concat(tabNames, " ") == "game=Game/font-scale-tab-widget-indicator/Component company=My company/font-scale-tab-widget-indicator/Component competition=Competition/font-scale-tab-widget-indicator/Component",
  table.concat(tabNames, " "))
tw.p.onValueChange("game")
check("content: the tab of the group shown asks nothing", SETPAGE == nil)
tw.p.onValueChange("competition")
check("content: another group's tab shows its first page", SETPAGE == "f_stats", SETPAGE)
-- at the right of the tabs: the state, smaller, larger, the quick view (icons, the texts as tooltips)
local hb = buttons(head)
check("content: the session's state beside the tabs", texts(head):find("In sync", 1, true) ~= nil and texts(head):find("Session", 1, true) == nil)
check("content: the size buttons and the quick view as icon buttons with their tooltips", #hb == 3 and hb[1].p.content.p.path == K.ICON_SMALLER and hb[1].p.meta.tooltip == "Smaller"
  and hb[2].p.content.p.path == K.ICON_LARGER and hb[2].p.meta.tooltip == "Larger" and hb[3].p.content.p.path == K.ICON_QUICK
  and hb[3].p.meta.tooltip == "Quick view  ·  The small window: the session and the chat" and hb[1].p.meta.enabled == true and hb[2].p.meta.enabled == true)
hb[1].p.onClick(); local s1 = SIZED; hb[2].p.onClick(); hb[3].p.onClick()
check("content: they still ask the same (smaller, larger, the small window)", s1 == -1 and SIZED == 1 and OPENED[1] == "win nil", tostring(OPENED[1]))
U.hubSize = 1
check("content: « Smaller » greyed at the smallest size, « Larger » at the largest", buttons(content().p.layout.p.children[1])[1].p.meta.enabled == false)
U.hubSize = 2
-- the group's pages: the game's List, an icon and the name each, the page shown chosen
local list = nodesOf(side, "List")[1]
local entries = {}
for i, e in ipairs(list and list.p.children or {}) do entries[i] = texts(e) .. "@" .. tostring(nodesOf(e, "ImageView")[1].p.path == U.hubIcon(({ "session", "chat", "game", "settings" })[i])) end
check("content: the group's pages in the game's List, each one its icon and its name", list ~= nil and table.concat(entries, " ") == "Session@true Chat@true Rules and options@true Settings@true"
  and list.p.selectionIndex == 1 and list.p.meta.localKey == "mpfever-hub-list-game", table.concat(entries, " "))
local e1, e2 = nodesOf(list.p.children[1], "TextView")[1], nodesOf(list.p.children[2], "TextView")[1]
check("content: the entries in the headline font, the chosen one in the accent, an icon of 24 pixels", e1.p.meta.class == "font-scale-headline" and e2.p.meta.class == "font-scale-headline"
  and same(styleOf(e1).color, K.rgba("AccentVeryLight")) and styleOf(e2).color == nil and sizeOf(nodesOf(list.p.children[1], "ImageView")[1]).x == 24)
check("content: the list in a darker panel with the card's contour", same(styleOf(side).backgroundColor1, K.rgba("BaseDark")) and styleOf(side).borderImage.fileName == K.CARD_CONTOUR)
SETPAGE = nil
list.p.onSelect(1); local sameSel = SETPAGE
list.p.onSelect(9); list.p.onSelect(0)
check("content: the chosen entry again, or no entry: nothing asked", sameSel == nil and SETPAGE == nil)
list.p.onSelect(3)
check("content: an entry asks its page", SETPAGE == "game", SETPAGE)
-- the page: its introduction, then a heading above each card, 8 pixels between two cards
local cards = page.p.content.p.layout.p.children
check("content: the page (its introduction, then a heading and its card per section, 8 pixels apart)", #cards == 9 and cards[1].p.text == "Host: Ann" and sizeOf(cards[2]).y == 8
  and texts(cards[3]) == "Sync" and sizeOf(cards[4]).y == 4 and cards[5].kind == "Component" and texts(cards[5]) == "ok" and sizeOf(cards[5]).x == ms.inner
  and styleOf(cards[5]).backgroundImage1.fileName == K.CARD_SURFACE and sizeOf(cards[6]).y == 8 and texts(cards[7]) == "Players" and texts(cards[9]) == "Ann", #cards)
check("content: the page's scroll area keeps its place under its key", page.p.meta.localKey == "mpfever-hub-page-session")
-- the window's title
check("title: the page's name in the window's title", U.hubTitle(st) == "MPFever – Session", U.hubTitle(st))
U.hubPage = "f_stats"
check("title: a game option's page", U.hubTitle(st) == "MPFever – Ranking", U.hubTitle(st))
U.oldHub = true
check("MPFEVER_OLDHUB=1: the window's title of before", U.hubTitle(st) == "MPFever Hub")
U.oldHub = false
-- a group's tab goes back to the page it showed last
U.hubPage = "rules"
local nr = content()
local twr = nodesOf(nr, "TabWidget")[1]
local lr = nodesOf(nr, "List")[1]
check("content, another group: its tab chosen, its pages in the list, every node in its tree", twr.p.value == "company" and lr.p.selectionIndex == 2 and lr.p.meta.localKey == "mpfever-hub-list-company"
  and texts(lr) == "Company|Sharing rules" and LEFT == 0 and texts(nr):find("the rules", 1, true) ~= nil, texts(lr))
U.hubPage = "session"
SETPAGE = nil
nodesOf(content(), "TabWidget")[1].p.onValueChange("company")
check("content: a group's tab goes back to the page it showed last in this session", SETPAGE == "rules", SETPAGE)
-- a page that fails; the chat
U.TABS.company = function() error("boom") end
U.hubPage = "company"
local nf = content()
check("content: a page that fails says so (and the window still draws)", texts(nf):find("This page could not be drawn", 1, true) ~= nil and K.TEXT_W == w0 and LEFT == 0)
U.hubPage = "chat"
local nc = content()
local chatBox = nc.p.layout.p.children[3].p.children[3]
check("content: the chat page without a scroll area, its lines in one of the game's cards", chatBox.kind == "Component" and chatBox.p.meta.localKey == "mpfever-hub-chat"
  and styleOf(chatBox.p.layout.p.children[1]).backgroundImage1.fileName == K.CARD_SURFACE and sizeOf(chatBox.p.layout.p.children[1]).x == ms.inner
  and texts(nc):find("hello", 1, true) ~= nil and LEFT == 0)
-- MPFEVER_WINTABS=buttons: the groups as buttons
U.hubPage = "session"
ENV.MPFEVER_WINTABS = "buttons"
local nb = content()
local gb = buttons(nb.p.layout.p.children[1].p.children[1])
check("MPFEVER_WINTABS=buttons: the groups as a row of buttons, the group shown in primary", #nodesOf(nb, "TabWidget") == 0 and #gb == 3 and labelOf(gb[1]) == "Game"
  and gb[1].p.meta.class == "primary" and gb[2].p.meta.class == "secondary" and LEFT == 0)
SETPAGE = nil
gb[1].p.onClick(); local g1 = SETPAGE; gb[3].p.onClick()
check("MPFEVER_WINTABS=buttons: a group's button shows its page", g1 == nil and SETPAGE == "f_stats", SETPAGE)
ENV.MPFEVER_WINTABS = nil
-- a game that no longer has the list (or the tabs): the head and the menu of before, the page still drawn, no error
for _, missing in ipairs({ "List", "TabWidget", "TabWidgetChild" }) do
  rawset(builtin, missing, false)
  U.hubNavMissing = nil
  local logs0 = #LOGS
  local no = content()
  local oh, obody = no.p.layout.p.children[1], no.p.layout.p.children[3]
  local primary = nil
  for _, b in ipairs(buttons(obody.p.children[1])) do if b.p.meta.class == "primary" then primary = labelOf(b) end end
  check("a game without " .. missing .. ": the head and the menu of before (every group, a button a page), no node left out, said in the log",
    texts(oh):find("Session|Game   ·   |In sync", 1, true) ~= nil and labelOf(buttons(oh)[3]) == "Quick view" and obody.p.children[1].kind == "ScrollArea"
    and texts(obody.p.children[1]):find("Game|Session|Chat|Rules and options|Settings|My company|Company|Sharing rules|Competition|Ranking", 1, true) ~= nil and primary == "Session"
    and #nodesOf(no, "List") == 0 and #nodesOf(no, "TabWidget") == 0 and LEFT == 0 and LOGS[#LOGS]:find("the menu of before", 1, true) ~= nil and #LOGS == logs0 + 1, LEFT)
  content()
  check("  said once", #LOGS == logs0 + 1)
  rawset(builtin, missing, nil)
end
-- MPFEVER_HUBNAV=0 (read once, when the kit is made): the head and the menu of before, the rest of the new drawing kept
ENV.MPFEVER_HUBNAV = "0"
local KV = U.makeKit(builtin)
ENV.MPFEVER_HUBNAV = nil
KV.TEXT_W = 700
local keepK = K
K = KV
local nv = content()
K = keepK
local vcards = nv.p.layout.p.children[3].p.children[3].p.content.p.layout.p.children
check("MPFEVER_HUBNAV=0: the head and the menu of before, the page still in the game's cards, every node in its tree", #nodesOf(nv, "List") == 0 and #nodesOf(nv, "TabWidget") == 0
  and texts(nv.p.layout.p.children[1]):find("Session|Game   ·   |In sync", 1, true) ~= nil and nv.p.layout.p.children[3].p.children[1].kind == "ScrollArea"
  and styleOf(vcards[5]).backgroundImage1.fileName == KV.CARD_SURFACE and LEFT == 0 and KV.noNav == true and K.noNav == false, LEFT)
''')

# ---------------------------------------------------------------- the choices: the game's groups of toggle buttons (the sharing
# rules, an option's On / Off and its parameters' values, the speed with the game bar's icons), and the buttons of before
L.execute(extract(UI, r"^U\.TOLLS = .*?^U\.ruleBlock = function\(K, rows, b\)\n.*?^end\n", "U.ruleBlock"))
L.execute(extract(UI, r"^U\.TABS\.session = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.session"))
L.execute(r'''
PREFIX = "choices: "
K.TEXT_W = 700
function made(fn)
  TRACK = {}
  local list = fn()
  local all = { kind = "BoxLayout", p = { children = list } }
  local seen = {}
  walk(all, function(x) seen[x] = true end)
  LEFT = 0
  for _, x in ipairs(TRACK) do if not seen[x] then LEFT = LEFT + 1 end end
  TRACK = nil
  return all
end
-- ---- K.choice
U.hubDrawing = nil
check("choice: nothing outside the Hub (the caller draws its buttons)", K.choice({ { label = "a" } }, 1, function() end, "k") == nil)
U.hubDrawing = true
check("choice: nothing with MPFEVER_OLDHUB=1", KO.choice({ { label = "a" } }, 1, function() end, "k") == nil)
local picked = {}
local g = K.choice({ { label = "Private", tip = "closed" }, { label = "Open" }, { label = "Toll" } }, 2, function(i) picked[#picked + 1] = i end, "rule-track")
check("choice: the game's ToggleButtonGroup, a button a choice, the chosen one given, one always chosen", g.kind == "ToggleButtonGroup" and #g.p.buttons == 3
  and g.p.selected == 2 and g.p.deselectAllowed == false and g.p.buttons[1].content.p.text == "Private" and g.p.buttons[1].meta.tooltip == "closed"
  and g.p.meta.localKey == "mpfever-choice-rule-track-1-3")
g.p.onValueChange(3, 1); g.p.onValueChange(2, 1); g.p.onValueChange(-1, 0); g.p.onValueChange(0); g.p.onValueChange(4)
check("choice: a click gives its place (the chosen one too: the caller decides), nothing for no place", table.concat(picked, ",") == "3,2", table.concat(picked, ","))
local gn = K.choice({ { icon = "a.tga", label = "II" }, { icon = "b.tga", label = "x1" } }, nil, function() end, "speed")
check("choice: none chosen (the group allows none then, as the game bar's speed), icons of 24 pixels", gn.p.selected == -1 and gn.p.deselectAllowed == true
  and gn.p.buttons[1].content.kind == "ImageView" and gn.p.buttons[1].content.p.path == "a.tga" and sizeOf(gn.p.buttons[1].content).x == 24)
picked = {}
local items = {}
for i = 1, 8 do items[i] = { label = "v" .. i } end
local gr = K.choice(items, 7, function(i) picked[#picked + 1] = i end, "p", 6)
local g1, g2 = gr.p.children[1], gr.p.children[3]
check("choice: rows of six at most, a group a row, the chosen one in its row only", gr.kind == "BoxLayout" and #g1.p.buttons == 6 and #g2.p.buttons == 2 and g1.p.selected == -1
  and g1.p.deselectAllowed == true and g2.p.selected == 1 and g2.p.deselectAllowed == false and g1.p.meta.localKey == "mpfever-choice-p-1-6" and g2.p.meta.localKey == "mpfever-choice-p-7-2")
g1.p.onValueChange(2, 1); g2.p.onValueChange(2, 1); g2.p.onValueChange(3, 1)
check("choice: a click in a row gives its place in the whole list", table.concat(picked, ",") == "2,8", table.concat(picked, ","))
rawset(builtin, "ToggleButtonGroup", false)
TRACK = {}
local none = K.choice({ { label = "a" }, { label = "b" } }, 1, function() end, "k")
check("choice, a game without ToggleButtonGroup: nothing, and nothing made", none == nil and #TRACK == 0, #TRACK)
TRACK = nil
rawset(builtin, "ToggleButtonGroup", nil)
-- ---- the sharing rules' block
SENT = {}
local function block(Kx, rule)
  return made(function()
    local rows = {}
    U.ruleBlock(Kx, rows, { kind = "track", icon = "i", title = "Your tracks", rule = rule, amount = 1000, amounts = U.TOLLS, amountLabel = "Toll: ",
      labels = { private = "Private", open = "Open", toll = "Toll" }, texts = { private = "closed", open = "free", toll = "paying" },
      send = function(r, amt) SENT[#SENT + 1] = r .. ":" .. tostring(amt) end })
    return rows
  end)
end
U.rulePending = nil
local rb = block(K, "open")
local tg = nodesOf(rb, "ToggleButtonGroup")[1]
check("rules: the three choices as a group of toggle buttons, the company's rule chosen, no button of before", tg ~= nil and texts(tg) == "Private|Open|Toll" and tg.p.selected == 2
  and #buttons(rb) == 0 and LEFT == 0 and texts(rb):find("free", 1, true) ~= nil, texts(rb))
tg.p.onValueChange(2, 1)
check("rules: the rule already chosen sends nothing", #SENT == 0)
tg.p.onValueChange(3, 1)
check("rules: another choice is sent with the amount", SENT[1] == "toll:1000", SENT[1])
rb = block(K, "open")
tg = nodesOf(rb, "ToggleButtonGroup")[1]
check("rules: the choice just made shows at once (until every game has it), with its amounts' list", tg.p.selected == 3 and texts(rb):find("Applying for every player", 1, true) ~= nil
  and #nodesOf(rb, "ComboBox") == 1 and LEFT == 0)
U.rulePending = nil
rawset(builtin, "ToggleButtonGroup", false)
rb = block(K, "open")
local prim = nil
for _, b in ipairs(buttons(rb)) do if b.p.meta.class == "primary" then prim = labelOf(b) end end
check("rules, a game without ToggleButtonGroup: the three buttons of before, the chosen one in primary", #buttons(rb) == 3 and prim == "Open" and LEFT == 0)
rawset(builtin, "ToggleButtonGroup", nil)
U.hubDrawing = nil
rb = block(K, "private")
check("rules, the small window: the three buttons of before", #buttons(rb) == 3 and #nodesOf(rb, "ToggleButtonGroup") == 0 and buttons(rb)[1].p.meta.class == "primary")
U.hubDrawing = true
rb = block(KO, "private")
check("MPFEVER_OLDHUB=1: rules, the three buttons of before", #buttons(rb) == 3 and #nodesOf(rb, "ToggleButtonGroup") == 0 and buttons(rb)[1].p.meta.class == "primary"
  and labelOf(buttons(rb)[1]) == "Private" and rb.p.children[2].p.children[1].kind == "ImageView")
-- ---- the game options: On / Off and the parameters' values
ASKED = {}
U.menuRequest = function(cmd, arg) ASKED[#ASKED + 1] = cmd .. " " .. tostring(arg) return true end
U.featAsked = nil
local stG = { mode = "separate", opts = "goal=1", host = true, me = "h", players = { { id = "h", role = "host" } } }
local og = made(function() local rows = {} U.featGameRows(K, stG, rows) return rows end)
local groups = nodesOf(og, "ToggleButtonGroup")
local onOffs, onGoal = 0, nil
for _, x in ipairs(groups) do if texts(x) == "On|Off" then onOffs = onOffs + 1; if x.p.meta.localKey == "mpfever-choice-opt-goal-1-2" then onGoal = x end end end
check("options: On / Off as a group of toggle buttons per option, the option's state chosen; no On / Off button left", onOffs > 3 and onGoal ~= nil and onGoal.p.selected == 1
  and LEFT == 0 and (function() for _, b in ipairs(buttons(og)) do if labelOf(b) == "On" or labelOf(b) == "Off" then return false end end return true end)(), onOffs)
local values = nil
for _, x in ipairs(groups) do if tostring(x.p.meta.localKey):find("mpfever-choice-opt-goal-", 1, true) and x ~= onGoal then values = values or x end end
check("options: an option's parameter as a group of its values, the value in force chosen", values ~= nil and #values.p.buttons >= 2 and values.p.selected >= 1, values and values.p.meta.localKey)
onGoal.p.onValueChange(1, 1)
check("options: the state already there asks nothing", #ASKED == 0)
onGoal.p.onValueChange(2, 1)
check("options: Off asks MPFever.exe as the button did", ASKED[1] == "opt goal=0", ASKED[1])
U.featAsked = nil
ASKED = {}
local other = values.p.selected == 1 and 2 or 1
values.p.onValueChange(values.p.selected, 1); local n0 = #ASKED
values.p.onValueChange(other, 1)
check("options: another value asks MPFever.exe (\"opt id.param=value\"), the value in force nothing", n0 == 0 and #ASKED == 1 and ASKED[1]:match("^opt goal%.%w+=.+$") ~= nil, ASKED[1])
U.featAsked = nil
local ogo = made(function() local rows = {} U.featGameRows(KO, stG, rows) return rows end)
local onB, offB = 0, 0
for _, b in ipairs(buttons(ogo)) do if labelOf(b) == "On" then onB = onB + 1 elseif labelOf(b) == "Off" then offB = offB + 1 end end
check("MPFEVER_OLDHUB=1: options, the On / Off buttons and the values' buttons of before", onB == onOffs and offB == onOffs and #nodesOf(ogo, "ToggleButtonGroup") == 0 and LEFT == 0, onB)
-- ---- the Session page: the speed with the game bar's icons, the icons of Kick / Ban and Accept / Refuse
SPEEDS, MENU = {}, {}
U.installed = true
U.setSpeed = function(v) SPEEDS[#SPEEDS + 1] = v end
U.menuRequest = function(cmd, arg) MENU[#MENU + 1] = cmd .. " " .. tostring(arg) return true end
U.resyncRows = function() end
U.pingName = function(k) return k end
U.reportLabel = function() return "Report" end
U.setCompact = function() end
function linkLine() return nil end
function playerCount(st) return #st.players end
function playerLine(pl) return pl.name, nil end
function requestInvite() end
function requestReport() end
ENV.MPFEVER_PINGS = "0"
local stS = { host = "Ann", me = "Ann", mode = "shared", started = "1", speed = "2", pubkick = "1", pending = "Zed#7",
  players = { { name = "Ann", role = "host" }, { name = "Bob", role = "player" } } }
stS.host = true
local sp = made(function() return U.TABS.session(K, stS, {}) end)
local sg = nodesOf(sp, "ToggleButtonGroup")[1]
local paths = {}
for i, b in ipairs(sg and sg.p.buttons or {}) do paths[i] = b.content.p.path end
check("session: the speed as the game bar's group (pause, play, x2, x4 icons), the session's speed chosen", sg ~= nil and table.concat(paths, ",") == table.concat({
  "::/gui/game_bar/icons/playback_pause.tga", "::/gui/game_bar/icons/playback_play.tga", "::/gui/game_bar/icons/playback_play_2.tga", "::/gui/game_bar/icons/playback_play_4.tga" }, ",")
  and sg.p.selected == 3 and sg.p.buttons[1].meta.tooltip == "Pause" and sg.p.buttons[3].meta.tooltip == "x2" and LEFT == 0, table.concat(paths, ","))
sg.p.onValueChange(3, 1); sg.p.onValueChange(1, 1); sg.p.onValueChange(4, 1)
check("session: a click asks its speed, the speed shown too (a request is always sent)", table.concat(SPEEDS, ",") == "2,0,4", table.concat(SPEEDS, ","))
stS.speed = "3"
local sg3 = nodesOf(made(function() return U.TABS.session(K, stS, {}) end), "ToggleButtonGroup")[1]
check("session: a speed that is none of the four, none chosen", sg3.p.selected == -1 and sg3.p.deselectAllowed == true)
stS.speed = "2"
local kick, ban, acc, ref, row
walk(sp, function(x) if x.kind == "BoxLayout" then for _, c in ipairs(x.p.children or {}) do if c.kind == "Button" and labelOf(c) == "Kick" then row = x end end end end)
for _, b in ipairs(buttons(sp)) do
  if labelOf(b) == "Kick" then kick = b elseif labelOf(b) == "Ban" then ban = b elseif labelOf(b) == "Accept" then acc = b elseif labelOf(b) == "Refuse" then ref = b end
end
check("session: Kick and Ban with their icons, the player's line 44 narrower for them", kick and ban and kick.p.content.p.children[1].p.path == K.ICON_KICK
  and ban.p.content.p.children[1].p.path == K.ICON_BAN and row.p.children[3].p.width == 700 - 206 - 44, row and row.p.children[3].p.width)
check("session: Accept (primary) and Refuse with the game's subsidy icons", acc and ref and acc.p.meta.class == "primary" and acc.p.content.p.children[1].p.path == K.ICON_ACCEPT
  and ref.p.meta.class == "secondary" and ref.p.content.p.children[1].p.path == K.ICON_REFUSE)
kick.p.onClick(); ban.p.onClick(); acc.p.onClick(); ref.p.onClick()
check("session: the same requests as before", table.concat(MENU, "|") == "kick Bob|ban Bob|admit Zed#7 1|admit Zed#7 0", table.concat(MENU, "|"))
-- the same page with MPFEVER_OLDHUB=1 and in the small window: the buttons of before
for _, case in ipairs({ { "MPFEVER_OLDHUB=1", KO, true }, { "the small window", K, nil } }) do
  U.hubDrawing = case[3]
  local so = made(function() return U.TABS.session(case[2], stS, {}) end)
  local labels, primary, krow = {}, nil, nil
  for _, b in ipairs(buttons(so)) do labels[#labels + 1] = labelOf(b); if b.p.meta.class == "primary" and labelOf(b):sub(1, 1) == "x" then primary = labelOf(b) end end
  walk(so, function(x) if x.kind == "BoxLayout" then for _, c in ipairs(x.p.children or {}) do if c.kind == "Button" and labelOf(c) == "Kick" then krow = x end end end end)
  -- (5 images: the three sections' icons and the two players')
  check(case[1] .. ": session, the speed buttons II x1 x2 x4 (the speed in primary), Kick / Ban / Accept / Refuse without an icon, the line's width",
    table.concat(labels, "|"):find("II|x1|x2|x4|Kick|Ban|Accept|Refuse", 1, true) ~= nil and primary == "x2" and #nodesOf(so, "ToggleButtonGroup") == 0
    and #nodesOf(so, "ImageView") == 5 and krow.p.children[3].p.width == 700 - 206 and LEFT == 0, table.concat(labels, "|") .. " " .. #nodesOf(so, "ImageView"))
end
U.hubDrawing = nil
ENV.MPFEVER_PINGS = nil
''')

# ---------------------------------------------------------------- the window's own pages (Company: the grid and a sheet, Auctions,
# Sharing rules, AI companies, Rules and options), the real ones, drawn by the Hub in the new drawing and with MPFEVER_OLDHUB=1:
# each one draws, makes no node it leaves out, and keeps its buttons' requests
for pat, what in [
    (r"^U\.swatch = function\(K, id, size\)\n.*?^end\n", "U.swatch"),
    (r"^U\.loanIn = .*?^U\.loanCard = function\(K, c, eco\)\n.*?^end\n", "U.loanCard"),
    (r"^U\.TABS\.company = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.company"),
    (r"^U\.AU_ICON = .*?^U\.TABS\.auction = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.auction"),
    (r"^U\.ruleWords = .*?^U\.hubTable = function\(K, lines, widths, opts\)\n.*?^end\n", "U.hubTable"),
    (r"^U\.TABS\.ai = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.ai"),
    (r"^U\.TABS\.rules = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.rules"),
    (r"^U\.START_MONEY = .*?^U\.TABS\.game = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.game"),
    (r"^U\.settingsRows = function\(K, rows\)\n.*?^end\n", "U.settingsRows"),
    (r"^U\.BANKRUPT_MONTHS = .*?^U\.TABS\.settings = function\(K, st, ctx\)\n.*?^end\n", "U.TABS.settings"),
]:
    L.execute(extract(UI, pat, what))
L.execute(r'''
U.oldMenus = function() return false end
U.coMap = { [101] = 1, [102] = 2, [103] = 3 }
U.myCo = 2
U.pollEco = function() end
U.pollAiJournal = function() end
U.eco = { members = { [1] = { "ann" }, [2] = { "bob" } }, chief = { [1] = "ann", [2] = "bob" }, gone = {}, debt = { [1] = 2 }, track = { [1] = { rule = "toll", toll = 500 } },
  fees = { [2] = { si = 100, se = 50, ti = 0, te = 20 } }, requests = { { key = "zed", to = 2, name = "Zed" } }, merges = { { from = 1, to = 2 } }, depots = {}, stops = {},
  depotco = {}, ai = { [3] = true }, road = {}, myKey = "bob", bankrupt = 12, start = 2000000, paid = { { from = 1, to = 2, amount = 70 } },
  loanOffers = { { id = 1, borrower = 1, lender = 2, amount = 1000, months = 12, rate = 10, turn = "lender" } }, loans = { { borrower = 1, lender = 2, rest = 500, monthly = 50 } },
  auction2 = { co = 1, seq = 4, left = 100, at = 100, mode = "assets", bids = 1, detail = { [1] = { lines = { "two stops" }, focus = 77 } },
    lots = { { idx = 1, kind = "line", label = "L1", vehicles = 2, reserve = 1000, best = 2000, bidder = 2, min = 2100 },
      { idx = 2, kind = "warehouse", label = "W", reserve = 500, best = 0, min = 500 } } } }
U.companyList = function() return { { id = 1, ent = 101, name = "Ann Co", bal = -5, rank = 2, lines = 1, veh = 2 }, { id = 2, ent = 102, name = "Bob Co", bal = 10, rank = 1, lines = 0, veh = 0 },
  { id = 3, ent = 103, name = "AI Co", bal = 3, lines = 0, veh = 0 } }, 10 end
U.coStats = function() return { stations = 1, depots = 1, byCarrier = { road = 2 }, earn = -5 } end
U.short = function(t) return t end
U.coLib = function() return { rgb = function(ix) return 0.1 * ix, 0.2, 0.3 end, PALETTE = { { 1, 0, 0 }, { 0, 1, 0 } } } end
U.coColors = { [1] = 1, [2] = 2 }
COSENT = {}
U.coSend = function(name, p) COSENT[#COSENT + 1] = name .. (p and p.accept ~= nil and (":" .. tostring(p.accept)) or "") return true end
function companyName(ent) return "Co" .. ent end
U.paidBy = function() return { [1] = { s = 1, t = 2, d = 3 } } end
U.aiCoName = function(id) return "Co#" .. id end
U.aiJournal = { { co = 3, x = 1, y = 2 } }
U.aiText = function() return "built a stop" end
U.aiFocus = function(x) FOCUS = "ai" end
U.coFigures = function() return "figures" end
U.shownSpeed = function() return 1 end
U.otherLinesAtMine = function() return { { sgName = "S", lineName = "L", co = "Ann Co", nv = 1, sg = 9 } } end
U.focusStationGroup = function(sg) FOCUS = "sg" .. sg end
U.focusLine = function() FOCUS = "line" end
U.give = function() end
U.loadPrefs = function() return {} end
U.dotsOn = function() return true end
C.SHARE_DEFAULT = 500
api.gui.camera.focusEntity = function(e) FOCUS = "entity" .. e end
U.menuRequest = function() return true end
U.status = { mode = "separate", opts = "stats=1", host = true }
local st = { mode = "separate", opts = "stats=1", host = true, me = "h", players = { { id = "h", role = "host" } } }
local ctx = { giveGen = { old = function() return 0 end }, amount = { old = function() return "" end, set = function() end } }
U.hubLastIn, U.tabReqHub, U.otherLinesOpen = nil, nil, true
function drawPage(Kx, id)
  U.hubPage = id
  TRACK = {}
  local n = U.hubContent(Kx, st, {}, ctx)
  local seen = {}
  walk(n, function(x) seen[x] = true end)
  LEFT = 0
  for _, x in ipairs(TRACK) do if not seen[x] then LEFT = LEFT + 1 end end
  TRACK = nil
  return n
end
function btn(n, label) for _, b in ipairs(buttons(n)) do if labelOf(b) == label then return b end end return nil end
function ibtn(n, path) local out = {} for _, b in ipairs(buttons(n)) do if b.p.content.kind == "ImageView" and b.p.content.p.path == path then out[#out + 1] = b end end return out end
function hasClass(n, text, cls)
  local found = false
  walk(n, function(x) if x.kind == "TextView" and tostring(x.p.text):find(text, 1, true) and tostring(x.p.meta and x.p.meta.class):find(cls, 1, true) then found = true end end)
  return found
end
for _, mode in ipairs({ "game", "old" }) do
  local Kx = mode == "game" and KN or KO
  local new = mode == "game"
  U.oldHub = not new
  U.HUB_COLORS = new and U.HUB_COLORS_GAME or U.HUB_COLORS_OLD
  PREFIX = new and "game style: " or "MPFEVER_OLDHUB=1: "
  -- the companies' grid
  U.coDetail, U.coSort = nil, "value"
  local n = drawPage(Kx, "company")
  local t = texts(n)
  check("companies: the page draws (the requests to answer, the grid), every node in its tree", t:find("could not be drawn", 1, true) == nil and LEFT == 0
    and t:find("Zed asks to join your company.", 1, true) ~= nil and t:find("3 company(ies)", 1, true) ~= nil and t:find("Bob Co", 1, true) ~= nil, LEFT)
  local sortG = nil
  for _, x in ipairs(nodesOf(n, "ToggleButtonGroup")) do if texts(x) == "Money|Rank|Lines" then sortG = x end end
  if new then
    check("companies: the sort as a group of toggle buttons, the sort in force chosen", sortG ~= nil and sortG.p.selected == 2 and btn(n, "Rank") == nil)
    sortG.p.onValueChange(1, 1)
    check("companies: a click sorts", U.coSort == "money")
    local acc = btn(n, "Accept")
    check("companies: Accept / Refuse with their icons", acc.p.content.kind == "BoxLayout" and acc.p.content.p.children[1].p.path == Kx.ICON_ACCEPT and btn(n, "Refuse").p.content.p.children[1].p.path == Kx.ICON_REFUSE)
    local mine = 0
    walk(n, function(x) if same(styleOf(x).borderColor, Kx.rgba("AccentLight")) and same(styleOf(x).backgroundColor1, Kx.rgba("AccentVeryDark")) then mine = mine + 1 end end)
    check("companies: this player's company on a card of the accent, the others on the game's card", mine == 1, mine)
  else
    check("companies: the sort's three buttons (the one in force in primary), Accept / Refuse as texts, the flat cards", sortG == nil and btn(n, "Rank").p.meta.class == "primary"
      and btn(n, "Money").p.meta.class == "secondary" and btn(n, "Accept").p.content.kind == "TextView"
      and (function() local m = 0 walk(n, function(x) if same(bgOf(x), { 0.25, 0.55, 0.85, 0.16 }) then m = m + 1 end end) return m end)() == 1)
    btn(n, "Money").p.onClick()
    check("companies: a click sorts", U.coSort == "money")
  end
  COSENT = {}
  btn(n, "Accept").p.onClick(); btn(n, "Refuse").p.onClick()
  check("companies: the answers still sent", COSENT[1] == "co_join_answer:true" and COSENT[2] == "co_join_answer:false", table.concat(COSENT, ","))
  btn(n, "Open the sheet").p.onClick()
  check("companies: « Open the sheet » opens a company's sheet", U.coDetail == 1 or U.coDetail == 3, U.coDetail)
  -- another company's sheet: the way back, its figures, the loan
  U.coDetail = 1
  n = drawPage(Kx, "company")
  t = texts(n)
  check("sheet: draws (figures, lines, rules, actions, the loan's offer to answer), every node in its tree", t:find("could not be drawn", 1, true) == nil and LEFT == 0
    and t:find("Ann Co", 1, true) ~= nil and t:find("It borrows $1000 from you", 1, true) ~= nil and t:find("It still owes you $500", 1, true) ~= nil and t:find("Give it:", 1, true) ~= nil, LEFT)
  if new then
    local back = btn(n, "All the companies")
    check("sheet: the way back with the game's back icon (no arrow in the text), the money owed in the colour of money", back ~= nil and back.p.content.p.children[1].p.path == Kx.ICON_BACK
      and hasClass(n, "It still owes you", "positive") and hasClass(n, "$-5", "negative"))
    back.p.onClick()
  else
    local back = nil
    for _, b in ipairs(buttons(n)) do if labelOf(b):find("All the companies", 1, true) then back = b end end
    check("sheet: the way back as before (its arrow in the text), the money owed in the status green", back ~= nil and labelOf(back) ~= "All the companies" and back.p.content.kind == "TextView"
      and hasClass(n, "It still owes you", "success"))
    back.p.onClick()
  end
  check("sheet: the way back goes back to the grid", U.coDetail == nil)
  -- this player's own sheet: the other companies' lines at its stations, with « Show »
  U.coDetail, FOCUS = 2, nil
  n = drawPage(Kx, "company")
  local shows = new and ibtn(n, Kx.ICON_LOCATE) or {}
  if not new then for _, b in ipairs(buttons(n)) do if labelOf(b) == "Show" and b.p.meta.tooltip == "Take the camera to the station" then shows[#shows + 1] = b end end end
  check("sheet (mine): « Show » at a station " .. (new and "as the game's locate icon, its text as the tooltip" or "as a text button") .. ", the same camera move",
    texts(n):find("could not be drawn", 1, true) == nil and LEFT == 0 and #shows == 1 and shows[1].p.meta.tooltip == "Take the camera to the station"
    and (shows[1].p.onClick() or FOCUS == "sg9"), #shows)
  U.coDetail = nil
  -- the auction
  U.auOpen = {}
  n = drawPage(Kx, "auction")
  t = texts(n)
  check("auction: draws (the clock, a lot per kind, the bids), every node in its tree", t:find("could not be drawn", 1, true) == nil and LEFT == 0 and t:find("Ends in ", 1, true) ~= nil
    and t:find("Line « L1 »", 1, true) ~= nil and t:find("Warehouse « W »", 1, true) ~= nil and t:find("You have the best bid.", 1, true) ~= nil and btn(n, "$1000") ~= nil, t)
  local lotIcons = {}
  walk(n, function(x) if x.kind == "ImageView" and (x.p.path == U.AU_ICON.line or (new and x.p.path == U.AU_ICON.warehouse)) then lotIcons[#lotIcons + 1] = x.p.path end end)
  FOCUS = nil
  if new then
    local loc = ibtn(n, Kx.ICON_LOCATE)
    check("auction: a lot's real small icon (a line, a warehouse), « Show » as the locate icon, the best bid held in the colour of money", #lotIcons == 2
      and U.AU_ICON.line == "::/gui/game_bar/icons/statistics_line_26.tga" and #loc == 1 and (loc[1].p.onClick() or FOCUS == "entity77") and hasClass(n, "Best bid: $2000 (you)", "positive"), #lotIcons)
  else
    check("auction: the icons and the « Show » button of before, the best bid held in the status green", U.AU_ICON.line == "::/gui/game_bar/icons/statistics_line_26.tga"
      and btn(n, "Show") ~= nil and (btn(n, "Show").p.onClick() or FOCUS == "entity77") and hasClass(n, "Best bid: $2000 (you)", "success"))
  end
  COSENT = {}
  btn(n, "$1000").p.onClick()
  check("auction: a bid still sent", COSENT[1] == "co_bid", COSENT[1])
  -- the sharing rules
  U.rulePending = nil
  n = drawPage(Kx, "rules")
  t = texts(n)
  check("rules: draws (this company's four rules, the others' table, the fees), every node in its tree", t:find("could not be drawn", 1, true) == nil and LEFT == 0
    and t:find("Your tracks", 1, true) ~= nil and t:find("Your depots", 1, true) ~= nil and t:find("Company|Tracks|Roads|Stops and stations|Depots", 1, true) ~= nil
    and t:find("Received|Paid", 1, true) ~= nil and t:find("toll $500", 1, true) ~= nil, t)
  local groups = nodesOf(n, "ToggleButtonGroup")
  local heads = 0
  walk(n, function(x) if same(bgOf(x), new and Kx.tint("head") or U.HUB_TINT.head) then heads = heads + 1 end end)
  if new then
    local posPaid = 0
    walk(n, function(x) if x.kind == "TextView" and (x.p.text == "$100" and same(styleOf(x).color, Kx.rgba("Positive")) or x.p.text == "$50" and same(styleOf(x).color, Kx.rgba("Negative"))) then posPaid = posPaid + 1 end end)
    check("rules: its four rules as groups of toggle buttons, the tables' heads on BaseDark, what was received and paid in the colours of money", #groups == 4 and heads == 3 and posPaid == 2, #groups .. " " .. heads .. " " .. posPaid)
    COSENT = {}
    groups[1].p.onValueChange(1, 1)
    check("rules: a choice still sent", COSENT[1] == "co_track_rule", COSENT[1])
  else
    check("rules: its rules as buttons, the tables' heads on their veil, as before", #groups == 0 and heads == 3 and btn(n, "Private") ~= nil and btn(n, "Open").p.meta.class == "primary")
    COSENT = {}
    btn(n, "Private").p.onClick()
    check("rules: a choice still sent", COSENT[1] == "co_track_rule", COSENT[1])
  end
  U.rulePending = nil
  -- the computer companies' journal, the game's rules and options
  FOCUS = nil
  n = drawPage(Kx, "ai")
  local aiShow = new and ibtn(n, Kx.ICON_LOCATE)[1] or btn(n, "Show")
  check("AI companies: draws, « Show » still moves the camera, every node in its tree", texts(n):find("built a stop", 1, true) ~= nil and LEFT == 0 and aiShow ~= nil
    and (aiShow.p.onClick() or FOCUS == "ai") and (not new or aiShow.p.meta.tooltip == "Show"))
  n = drawPage(Kx, "game")
  t = texts(n)
  check("rules and options: draws (the game's rules, the options with On / Off), every node in its tree", t:find("could not be drawn", 1, true) == nil and LEFT == 0
    and t:find("Game rules", 1, true) ~= nil and t:find("Start money of a new company", 1, true) ~= nil and t:find("Game options (0.6)", 1, true) ~= nil and t:find("On|Off", 1, true) ~= nil, LEFT)
  -- every page of this session's menu draws, in its group
  local bad = {}
  for _, id in ipairs(U.hubPages(st)) do
    if id ~= "chat" then
      local x = drawPage(Kx, id)
      if texts(x):find("could not be drawn", 1, true) or LEFT > 0 then bad[#bad + 1] = id .. "(" .. LEFT .. ")" end
    end
  end
  check("every page of the menu draws, no node left out", #bad == 0 and #U.hubPages(st) >= 8, table.concat(bad, ",") .. " / " .. table.concat(U.hubPages(st), ","))
end
U.oldHub = false
U.HUB_COLORS = U.HUB_COLORS_GAME
PREFIX = ""
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
