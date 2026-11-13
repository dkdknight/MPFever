"""The lobby's page of the 0.6 game options (mpfever_menu.lua, featPage), offline (lupa, Lua 5.2).

The page's real code (from "local OPTSPAGE" to the end of featPage) is taken from the file and run with the real options host
(mpfever_feat.lua) and the real feature modules, the game's UI components mocked (each makes a plain table). Checked:
  - the cards in their groups and in order: Co-op, Competition, Trade between players, Public game (join_* there too), an option
    of no group under Other; only the options the session's mode offers (shared: no trade group, competition = stats);
  - two or three columns as the width allows (one on a narrow page);
  - the host: On / Off on every card, the parameters only while the option is on (and a `when` parameter only when its condition
    holds: the game goal's tenders won), one row per player but the host for a perPlayer parameter, the same requests as the
    settings panel ("opt id=1", "opt id.param=v", "opt id.param_<player>=v");
  - a player: read only (no button but « Back to the lobby »), whether each option is on, the values as text;
  - each card's icon is the game's picture chosen for it (and the file is in the game's gui.zip when the game is here);
  - the menu's switches: MPFEVER_LOBBYOPTSPAGE=0 keeps the options in the settings panel, MPFEVER_MENU_OPTSPAGE=1 opens the page,
    the page's state hook at the top of the recipe.
Run: python tests/test_lobbyoptspage.py
"""
import os
import pathlib
import re
import sys
import zipfile

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
failures = []


def check(cond, name, got=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        failures.append(name)


def read(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


menu = read("mpfever_menu.lua")
m = re.search(r"^\tlocal OPTSPAGE = .*?^\tlocal function featPage\(fv, o\)\n.*?^\tend\n", menu, re.S | re.M)
c = re.search(r"^\tlocal function featCount\(fv\)\n.*?^\tend\n", menu, re.S | re.M)
if not (m and c):
    print("FAIL: the lobby's page of the game options (OPTSPAGE ... featPage) or featCount not found in mpfever_menu.lua")
    sys.exit(1)

L = lua52.LuaRuntime(unpack_returned_tuples=True)
mods = {}
for name in os.listdir(CONTENT):
    mm = re.match(r"^mpfever_feat_([a-z]+)\.lua$", name)
    if mm:
        mods[mm.group(1)] = read(name)
L.globals().SRC_F = read("mpfever_feat.lua")
L.globals().SRC_MODS = L.table_from(mods)
L.execute(r'''
F = assert(load(SRC_F, "=feat"))()
F.loader = function(id) local s = SRC_MODS[id]; if s then return assert(load(s, "=" .. id))() end return nil end
F.load(function() end)
FEAT = F
function T(fr, en) return en end
H, V = "H", "V"
CARD_SURFACE = { card = true }
function style(t) return t end
function text(t, class, w) return { kind = "text", t = tostring(t), class = class, w = w } end
function icon(path, size) return { kind = "icon", path = path, size = size } end
function box(dir, c, class, st) return { kind = "box", dir = dir, c = c, st = st } end
function gap(w, h) return { kind = "gap", w = w, h = h } end
function hfill() return { kind = "fill" } end
function vfill() return { kind = "vfill" } end
function button(label, fn, opts) return { kind = "btn", t = tostring(label), fn = fn, primary = opts and opts.primary or false } end
builtin = { type = { ScrollBarPolicy = { AlwaysOff = 0, AsNeeded = 1 } },
  ScrollArea = function(p) return { kind = "scroll", c = { p.content }, size = p.meta.styleSheet.size } end }
REQ = {}
function request(cmd, arg, who) REQ[#REQ + 1] = cmd .. " " .. tostring(arg) end
''')
L.execute(c.group(0).replace("local function featCount", "function featCount", 1))
L.execute(m.group(0) + "\nFEATPAGE = featPage\nICONS = FEAT_ICONS\nICON_OTHER = FEAT_ICON_OTHER\nPAGEMODE = OPTSPAGE\n")
run = L.eval("function(code) local f = assert(load(code)) return f() end")
run(r'''
function walk(n, f) if type(n) ~= "table" then return end f(n) for _, x in ipairs(n.c or {}) do walk(x, f) end end
TITLE2ID = {}
for _, mode in ipairs({ "shared", "separate" }) do for _, e in ipairs(F.offered(mode)) do TITLE2ID[F.text(e.opt.title or e.opt.id, T)] = e.opt.id end end
TITLE2ID["Zed"] = "zzz"; TITLE2ID["Join extra"] = "join_extra"
function page(mode, opts, host, width, extra)
  REQ = {}
  BACKED = false
  local fv = { mode = mode, offered = F.offered(mode), map = F.parse(F.canon(opts, mode)) }
  for _, e in ipairs(extra or {}) do fv.offered[#fv.offered + 1] = e end
  P = FEATPAGE(fv, { host = host, playerName = function() return "Host" end, players = { "Host", "Bob", "Carl (France)" },
    width = width or 1614, height = 656, onBack = function() BACKED = true end })
  -- the groups: their titles, their cards (id, title, icon, texts, buttons) and the number of cards of each row
  local scroll
  walk(P, function(n) if n.kind == "scroll" then scroll = n end end)
  G = {}
  for _, it in ipairs(scroll.c[1].c) do
    if it.kind == "text" and it.class == "font-scale-title-3" then
      G[#G + 1] = { title = it.t, cards = {}, rows = {} }
    elseif it.kind == "box" and it.dir == H then
      local g, n = G[#G], 0
      for _, x0 in ipairs(it.c) do
        -- (each card sits at the top of a column box of its own, see featPage)
        local x = x0
        if x0.kind == "box" and x0.dir == V and x0.c and x0.c[1] and x0.c[1].kind == "box" then x = x0.c[1] end
        if x.kind == "box" and x.st and x.st.image1 == CARD_SURFACE then
          n = n + 1
          local r = { texts = {}, buttons = {}, icons = {} }
          walk(x, function(y)
            if y.kind == "text" then r.texts[#r.texts + 1] = y.t
            elseif y.kind == "btn" then r.buttons[#r.buttons + 1] = y
            elseif y.kind == "icon" then r.icons[#r.icons + 1] = y.path end
          end)
          r.title = r.texts[1]
          r.id = TITLE2ID[r.title] or ("?" .. tostring(r.title))
          g.cards[#g.cards + 1] = r
          CARD[r.id] = r
        end
      end
      g.rows[#g.rows + 1] = n
    end
  end
end
CARD = {}
function groups()
  local o = {}
  for _, g in ipairs(G) do
    local ids = {}
    for _, r in ipairs(g.cards) do ids[#ids + 1] = r.id end
    o[#o + 1] = g.title .. "=" .. table.concat(ids, ",")
  end
  return table.concat(o, " | ")
end
function rows() local o = {} for _, g in ipairs(G) do o[#o + 1] = table.concat(g.rows, ",") end return table.concat(o, " | ") end
function has(id, s) for _, t in ipairs(CARD[id].texts) do if t == s then return true end end return false end
function hasPart(id, s) for _, t in ipairs(CARD[id].texts) do if t:find(s, 1, true) then return true end end return false end
function btn(id, label, k)
  k = k or 1
  for _, b in ipairs(CARD[id].buttons) do if b.t == label then k = k - 1; if k == 0 then return b end end end
  return nil
end
function nButtons() local n = 0 for _, g in ipairs(G) do for _, r in ipairs(g.cards) do n = n + #r.buttons end end return n end
function label(id, pid) for _, e in ipairs(F.offered("separate")) do if e.opt.id == id then for _, p in ipairs(e.params) do if p.id == pid then return F.text(p.label, T) end end end end end
function enc(key) return F.playerPid("money", key) end
''')

print("the host's page, one company per player")
OPTS = 'journal=1;goal=1;handicap=1;handicap." .. enc("bob") .. "=150;stock=0'
run(f'page("separate", "{OPTS}", true)')
check(run("return PAGEMODE") is True, "the page is on by default (MPFEVER_LOBBYOPTSPAGE unset)")
got = run("return groups()")
check(got == "Co-op=journal,builtby,playerview,perms,plans | Competition=goal,stats,yearly,market,territory,handicap,tenders"
      " | Trade between players=sales,contracts,stock,cargo | Public game=public,join_bans,join_approve,join_steamfriends",
      "the four groups, their cards in order", got)
check(run('local n = 0 for _, g in ipairs(G) do n = n + #g.cards end return n == #F.offered("separate")') is True,
      "one card per option the mode offers")
check(run("return rows()") == "3,2 | 3,3,1 | 3,1 | 3,1", "three columns on the lobby's width (0.8.6: the commodity market in the trade group)", run("return rows()"))
check(run('return #CARD.journal.buttons >= 2 and btn("journal", "On").primary and not btn("journal", "Off").primary') is True,
      "a card on: its On button lit")
check(run('return btn("stock", "Off").primary and not btn("stock", "On").primary and btn("builtby", "Off").primary') is True,
      "a card off: its Off button lit")
check(run('local ok = true for _, g in ipairs(G) do for _, r in ipairs(g.cards) do ok = ok and btn(r.id, "On") ~= nil and btn(r.id, "Off") ~= nil end end return ok') is True,
      "every card has its On / Off switch")
check(run('return has("journal", label("journal", "details")) and btn("journal", "yes") ~= nil and btn("journal", "no").primary') is True,
      "an option on: its parameters with their values as buttons, the current one lit")
check(run('return not has("stock", label("stock", "premium")) and not has("public", "Players at most") and #CARD.stock.buttons == 2') is True,
      "an option off: no parameter")
check(run('return has("goal", label("goal", "criterion")) and has("goal", label("goal", "years")) and not has("goal", label("goal", "wins"))') is True,
      "the goal's tenders won hidden while the criterion is not the tenders (`when`)")
check(run('return has("handicap", "Bob") and has("handicap", "Carl") and not has("handicap", "Host")') is True,
      "a perPlayer parameter: one row per player but the host")
check(run('return btn("handicap", "150 %", 2).primary and btn("handicap", "100 %", 3).primary and btn("handicap", "100 %", 1).primary') is True,
      "each player's row shows its own value, else the parameter's")
run('btn("stock", "On").fn(); btn("goal", "30 years").fn(); btn("handicap", "75 %", 3).fn(); btn("journal", "Off").fn()')
got = run('return table.concat(REQ, " ; ")')
check(got == "opt stock=1 ; opt goal.years=30 ; opt handicap." + run('return enc("carl")') + "=75 ; opt journal=0",
      "the clicks ask MPFever.exe as the settings panel did", got)
check(run('local ok = true for id, r in pairs(CARD) do ok = ok and r.icons[1] == ICONS[id] and ICONS[id] ~= nil end return ok') is True,
      "each card's icon is the one chosen for its option")
run('local b; walk(P, function(n) if n.kind == "btn" and n.t == "Back to the lobby" then b = n end end); b.fn()')
check(run("return BACKED") is True, "« Back to the lobby » closes the page")
check(run('local t; walk(P, function(n) if n.kind == "text" and n.t:find("Game options: 3 on", 1, true) then t = n end end) return t ~= nil') is True,
      "the page's title line counts the options on")
run(f'page("separate", "goal=1;goal.criterion=tenders", true)')
check(run('return has("goal", label("goal", "wins"))') is True, "the tenders won shown with the tenders criterion")

print("columns")
run(f'page("separate", "", true, 1000)')
check(run("return rows()") == "2,2,1 | 2,2,2,1 | 2,2 | 2,2", "two on a narrower page", run("return rows()"))
run(f'page("separate", "", true, 500)')
check(run("return rows()") == "1,1,1,1,1 | 1,1,1,1,1,1,1 | 1,1,1,1 | 1,1,1,1", "one on a narrow one", run("return rows()"))

print("the co-op")
run('page("shared", "journal=1;goal=1;stock=1", true)')
got = run("return groups()")
check(got == "Co-op=journal,builtby,playerview,perms,plans | Competition=stats | Trade between players=cargo | Public game=public,join_bans,join_approve,join_steamfriends",
      "only the options of the mode: the trade group with the commodity market alone (0.8.6, both modes), the competition's stats alone", got)

print("an option of no group, a join_ one")
run('page("separate", "", true, 1614, { { M = {}, opt = { id = "join_extra", title = { "Join extra", "Join extra" } }, params = {} },'
    ' { M = {}, opt = { id = "zzz", title = { "Zed", "Zed" } }, params = {} } })')
got = run("return groups()")
check(got.endswith("Public game=public,join_bans,join_approve,join_steamfriends,join_extra | Other=zzz"),
      "join_* under Public game, the others under Other", got)
check(run("return CARD.zzz.icons[1] == ICON_OTHER") is True, "an option without its own icon: the settings icon")

print("a player's page (read only)")
run(f'page("separate", "{OPTS}", false)')
check(run("return nButtons()") == 0, "no button in the cards", run("return nButtons()"))
check(run('local n = 0; walk(P, function(x) if x.kind == "btn" then n = n + 1 end end) return n') == 1, "only « Back to the lobby »")
check(run('return has("journal", "On") and has("stock", "Off") and has("journal", label("journal", "details") .. ": no")') is True,
      "whether each option is on, the values as text")
check(run('return has("handicap", "   Bob: 150 %") and has("handicap", "   Carl: 100 %") and not hasPart("handicap", "Host")') is True,
      "each player's own value (the parameter's when it has none), not the host's")
check(run('return not hasPart("stock", label("stock", "premium"))') is True, "no parameter of an option off")

print("the icons in the game's files")
gui = None
for p in pathlib.Path(HERE).resolve().parents:
    z = p / "base" / "content" / "gui.zip"
    if z.is_file():
        gui = z
        break
icons = run('local o = {} for _, p in pairs(ICONS) do o[#o + 1] = p end o[#o + 1] = ICON_OTHER return table.concat(o, "\\n")').split("\n")
icons.append("::/gui/menu/icons/back.tga")
if gui:
    names = set(zipfile.ZipFile(gui).namelist())
    missing = [p for p in icons if p[3:] not in names and p[3:].replace(".tga", "@2x.tga") not in names]
    check(not missing, f"every icon is in {gui.name} (plain or @2x)", missing)
else:
    print("  (the game's gui.zip is not here: the icons' files are not looked at)")
check(all(re.match(r"^::/gui/[a-z_/-]+[a-z0-9_-]*\.tga$", p) for p in icons), "every icon is a ::/gui/... .tga path")

print("the menu's switches")
check(re.search(r'^\tlocal OPTSPAGE = os\.getenv\("MPFEVER_LOBBYOPTSPAGE"\) ~= "0"$', menu, re.M) is not None,
      "MPFEVER_LOBBYOPTSPAGE=0: no page")
check(re.search(r'^\t\tlocal optsPage = react\.useState\(os\.getenv\("MPFEVER_MENU_OPTSPAGE"\) == "1"\)$', menu, re.M) is not None,
      "the page's state hook at the recipe's top level, MPFEVER_MENU_OPTSPAGE=1 opens it")
calls = [mm.start() for mm in re.finditer(r"(?<!function )featSection\(panel", menu)]
check(len(calls) == 2 and all("not OPTSPAGE" in menu[max(0, i - 600):i] for i in calls),
      "the settings panels show the 0.6 options only without the page")
check(chr(92) not in menu, "no backslash in the menu's file (see its top)")
check(menu.count("featPage(pageFv,") == 1 and "local pageFv = OPTSPAGE and optsPage:old()" in menu,
      "the lobby shows the page only with the switch on and the page asked")

if failures:
    print(f"FAIL {len(failures)} case(s): " + "; ".join(failures))
    sys.exit(1)
print("all passed")
sys.exit(0)
