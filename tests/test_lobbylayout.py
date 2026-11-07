"""The lobby in sections of 0.6.3 (mpfever_menu.lua, lobbyColumn), offline (lupa, Lua 5.2).

A lobby with one company per player put everything in one small scroll area up to 0.6.2 (the rules panel, the computer
companies' start money there and their level and colour further down, the mods, labels of every width). Its left column is now
the picture with the player's colour and a short view of the game beside it, then a row of tabs (Rules, Computers, Game options,
Mods) and the chosen section under it. The real lobbyColumn (with the real featChoices, featView, featCount and the real options
host mpfever_feat.lua) is run with the game's UI components mocked (each makes a plain table). Checked:
  - the tabs: which show (Computers for the host or when there are some, Game options when the mode offers some, Mods when the
    savegame has some, with the alert icon when some are to fix), their counts, the first one lit by default (Mods for a player
    who lacks some), a tab no longer there falls back to Rules, a click asks for its section;
  - each section a table: every label in a column of one width, every long text wrapped to a width inside the column;
  - the host's buttons send the same requests as the lobby of 0.6.2: startmoney, share, bankrupt, ailevel, aicolor (the colours
    taken greyed), aimoney, aidel, aiadd; the options' button opens their page; without the page (MPFEVER_LOBBYOPTSPAGE=0) the
    host's switches of the 0.6.2 panel (featSection) in the section;
  - a player sees the same, read only: no button but the tabs and « See the options », the values as text;
  - the menu's switch MPFEVER_LOBBYOLD=1 (the 0.6.2 column), the tab's state hook at the recipe's top level.
Run: python tests/test_lobbylayout.py
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
failures = []


def check(cond, name, got=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        failures.append(name)


def read(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


menu = read("mpfever_menu.lua")
pieces = {
    "choices": r"^\tlocal UTF8_START = .*?^\tlocal function featChoices\(list, w\)\n.*?^\tend\n",
    "view": r"^\tlocal function featView\(st\)\n.*?^\tend\n",
    "count": r"^\tlocal function featCount\(fv\)\n.*?^\tend\n",
    "column": r"^\tlocal LOBBYOLD = .*?^\tlocal function lobbyColumn\(c\)\n.*?^\tend\n",
}
found = {}
for k, pat in pieces.items():
    mm = re.search(pat, menu, re.S | re.M)
    if not mm:
        print(f"FAIL: {k} not found in mpfever_menu.lua")
        sys.exit(1)
    found[k] = mm.group(0)

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
function log() end
H, V = "H", "V"
SIDE_W, PIC_W, PIC_H, LOBBY_H = 960, 416, 234, 656
OPTSPAGE = true
PALETTE = {}
for i = 1, 12 do PALETTE[i] = { i / 12, 0.5, 0.5 } end
function style(t) return t end
function text(t, class, w) return { kind = "text", t = tostring(t), class = class, w = w } end
function icon(path, size) return { kind = "icon", path = path, size = size } end
function box(dir, c, class, st) return { kind = "box", dir = dir, c = c, st = st } end
function gap(w, h) return { kind = "gap", w = w, h = h } end
function hfill() return { kind = "fill" } end
function vfill() return { kind = "vfill" } end
function button(label, fn, opts) return { kind = "btn", t = tostring(label), fn = fn, primary = opts and opts.primary or false, icon = opts and opts.icon } end
function colorRow(cur, pick, note, compact, taken) return { kind = "colorrow", cur = cur } end
function SavePicture(p) return { kind = "picture", save = p.save } end
SECTIONS = {}
function featSection(panel, w, fv, playerName, players) SECTIONS[#SECTIONS + 1] = w; panel[#panel + 1] = { kind = "featsection" } end
builtin = { type = { ScrollBarPolicy = { AlwaysOff = 0, AsNeeded = 1 } },
  ScrollArea = function(p) return { kind = "scroll", c = { p.content }, size = p.meta.styleSheet.size } end,
  Button = function(p) return { kind = "rawbtn", fn = p.onClick, enabled = p.meta.enabled ~= false, tooltip = p.meta.tooltip, c = { p.content } } end,
  Component = function(p) return { kind = "comp" } end }
REQ = {}
function request(cmd, arg, who) REQ[#REQ + 1] = cmd .. " " .. tostring(arg) end
''')
L.execute(found["choices"].replace("local function featChoices", "function featChoices", 1) + found["view"].replace("local function featView", "function featView", 1)
          + found["count"].replace("local function featCount", "function featCount", 1))
L.execute(found["column"] + "\nLOBBYCOLUMN = lobbyColumn\nLABEL_W = LOBBY_LABEL_W\nOLDSWITCH = LOBBYOLD\n")
run = L.eval("function(code) local f = assert(load(code)) return f() end")
run(r'''
function walk(n, f) if type(n) ~= "table" then return end f(n) for _, x in ipairs(n.c or {}) do walk(x, f) end end
function fmt(n)
  if n >= 1000000 then return (string.format("%g", n / 1000000)) .. " M" end
  if n >= 1000 then return (string.format("%g", n / 1000)) .. " k" end
  return tostring(n)
end
AIS = { { n = 1, ix = 7, lv = 3, money = -1, name = "Regional Transport" }, { n = 2, ix = 3, lv = 1, money = 5000000, name = "" } }
function column(o)
  REQ, SECTIONS = {}, {}
  ASKED, OPENED = nil, false
  local st = { cmode = "separate", opts = o.opts or "journal=1;goal=1;stock=0" }
  COL = LOBBYCOLUMN{ host = o.host, st = st, ais = o.ais or AIS, players = { "Host", "Bob" }, mine = 1, taken = { [1] = true, [5] = true, [7] = true, [3] = true },
    pickColor = function() end, playerName = function() return "Host" end, lobbySave = nil,
    modsBox = (not o.nomods) and { kind = "mods" } or nil, mods = (not o.nomods) and { n = 5, blocking = o.blocking or 0 } or nil, modsFirst = o.modsFirst,
    rules = { start = 2000000, share = true, months = 12, fmt = fmt, summary = "Start: 2 M  ·  Sharing on  ·  Bankruptcy: 12 months" },
    section = o.section, setSection = function(id) ASKED = id end, openOpts = function() OPENED = true end }
  TABS = {}
  for _, b in ipairs(COL[3].c) do if b.kind == "btn" then TABS[#TABS + 1] = b end end
  BODY = COL[5].c[1]
end
function tabs() local o = {} for _, b in ipairs(TABS) do o[#o + 1] = b.t .. (b.primary and "*" or "") .. (b.icon and "!" or "") end return table.concat(o, " | ") end
function tab(label) for _, b in ipairs(TABS) do if b.t:find(label, 1, true) == 1 then return b end end end
function btns(kind) local o = {} walk(BODY, function(n) if n.kind == (kind or "btn") then o[#o + 1] = n end end) return o end
function btn(label, k) k = k or 1 for _, b in ipairs(btns()) do if b.t == label then k = k - 1 if k == 0 then return b end end end end
function texts() local o = {} walk(BODY, function(n) if n.kind == "text" then o[#o + 1] = n.t end end) return o end
function has(s) for _, t in ipairs(texts()) do if t == s then return true end end return false end
-- the rows of a section: boxes H whose first child is the label's box (a box V of a fixed width holding one text)
function labelWidths()
  local ws, seen = {}, {}
  walk(BODY, function(n)
    if n.kind == "box" and n.dir == H and n.c[1] and n.c[1].kind == "box" and n.c[1].dir == V and n.c[1].st and n.c[1].st.size
      and #n.c[1].c == 1 and n.c[1].c[1].kind == "text" then
      local w = n.c[1].st.size[1]
      if not seen[w] then seen[w] = true; ws[#ws + 1] = w end
    end
  end)
  table.sort(ws)
  return table.concat(ws, ",")
end
function rowCount()
  local n = 0
  walk(BODY, function(x) if x.kind == "box" and x.dir == H and x.c[1] and x.c[1].kind == "box" and x.c[1].st and x.c[1].st.size and x.c[1].st.size[1] == LABEL_W then n = n + 1 end end)
  return n
end
-- every long text of the whole column wrapped to a width that fits in it
function unwrapped()
  local bad = {}
  for _, top in ipairs(COL) do
    walk(top, function(n) if n.kind == "text" and #n.t > 24 and not (n.w and n.w <= SIDE_W - 20) then bad[#bad + 1] = n.t:sub(1, 40) end end)
  end
  return table.concat(bad, " / ")
end
''')

print("the host's lobby")
run('column{ host = true }')
n_on = run('return #FEAT.summary(FEAT.parse(FEAT.canon("journal=1;goal=1;stock=0", "separate")), "separate", T)')
got = run("return tabs()")
check(got == f"Rules* | Computers (2) | Game options ({n_on}) | Mods (5)", "the four tabs, Rules lit first", got)
check(run("return COL[1].c[1].kind == 'picture' and COL[1].c[3].c[1].kind == 'colorrow'") is True, "beside the picture: the player's colour first")
check(run('local ok = false walk(COL[1], function(n) if n.kind == "text" and n.t:find("Sharing on", 1, true) then ok = true end end) return ok') is True,
      "beside the picture: the rules in one line")
check(run("return COL[5].kind == 'scroll' and COL[5].size[2] == LOBBY_H - PIC_H - 12 - 40 - 8") is True, "the section in a scroll area filling the column")
# (0.7.4: the auction's kind and its minutes, two rows more)
check(run("return rowCount()") == 5, "Rules: five rows (start money, sharing, bankruptcy, the auction's kind and minutes)", run("return rowCount()"))
check(run("return labelWidths()") == str(run("return LABEL_W")), "Rules: one width of label column", run("return labelWidths()"))
check(run('return btn("2 M").primary and btn("On").primary and btn("12 months").primary and not btn("5 M").primary') is True,
      "Rules: the current values lit")
run('btn("5 M").fn(); btn("Off").fn(); btn("24 months").fn(); btn("Never").fn(); btn("0").fn()')
got = run('return table.concat(REQ, " ; ")')
check(got == "startmoney 5000000 ; share 0 ; bankrupt 24 ; bankrupt 0 ; startmoney 0", "Rules: the same requests as 0.6.2's panel", got)
check(run("return unwrapped()") == "", "every long text wrapped in the column", run("return unwrapped()"))
run('tab("Computers").fn()')
check(run("return ASKED") == "ai", "a tab's click asks for its section")

print("the host's computer companies")
run('column{ host = true, section = "ai" }')
check(run("return tabs()").startswith("Rules | Computers (2)*"), "Computers lit", run("return tabs()"))
check(run("return labelWidths()") == str(run("return LABEL_W")), "one width of label column", run("return labelWidths()"))
check(run("return rowCount()") == 6, "level, colour, start money: three rows each", run("return rowCount()"))
check(run('return has("Regional Transport") and has("Computer 2")') is True, "each by its name (« Computer n » without one)")
check(run('return btn("Hard").primary and btn("Easy", 2).primary and btn("As the players").primary and btn("5 M", 2).primary') is True,
      "each one's level and start money lit")
raw = run('local o = {} for _, b in ipairs(btns("rawbtn")) do o[#o + 1] = b end return #o')
check(raw == 2 * 13, "per company: 12 colours and its remove button", raw)
# (per company: its remove button, then its 12 colours)
check(run('local b = btns("rawbtn") return b[1].tooltip == "Remove" and (not b[2].enabled) and b[3].enabled and b[8].enabled and not b[6].enabled') is True,
      "the colours of the others greyed, its own not")
run('btn("Hard").fn(); btn("Normal", 2).fn(); btns("rawbtn")[3].fn(); btn("As the players").fn(); btn("20 M", 2).fn();'
    'btns("rawbtn")[1].fn(); btn("Add a computer company").fn()')
got = run('return table.concat(REQ, " ; ")')
check(got == "ailevel 1:3 ; ailevel 2:2 ; aicolor 1:2 ; aimoney 1:-1 ; aimoney 2:20000000 ; aidel 1 ; aiadd ",
      "the same requests as 0.6.2's lobby", got)
check(run("return unwrapped()") == "", "every long text wrapped in the column", run("return unwrapped()"))
ais8 = "{" + ",".join(f"{{ n = {i}, ix = {i}, lv = 2, money = -1, name = '' }}" for i in range(1, 9)) + "}"
run(f'column{{ host = true, section = "ai", ais = {ais8} }}')
check(run('return btn("Add a computer company") == nil') is True, "eight already: no « Add »")

print("the game options")
run('column{ host = true, section = "opts" }')
check(run(f'return btn("Game options ({n_on} on)") ~= nil') is True, "the host's button of their page with the number on")
run(f'btn("Game options ({n_on} on)").fn()')
check(run("return OPENED") is True, "it opens the page of the game options")
check(run('local n = 0 for _, s in ipairs(FEAT.summary(FEAT.parse(FEAT.canon("journal=1;goal=1;stock=0", "separate")), "separate", T)) do if has(s.title) then n = n + 1 end end return n') == n_on,
      "one row per option on, by its title")
check(run("return labelWidths()") == str(run("return LABEL_W")), "one width of label column", run("return labelWidths()"))
check(run("return unwrapped()") == "", "every long text wrapped in the column", run("return unwrapped()"))
run('OPTSPAGE = false; column{ host = true, section = "opts" }; OPTSPAGE = true')
check(run("return #SECTIONS") == 1 and run(f'return btn("Game options ({n_on} on)") == nil') is True,
      "MPFEVER_LOBBYOPTSPAGE=0: the host's switches of 0.6.2 (featSection) in the section, no page button")
run('OPTSPAGE = false; column{ host = false, section = "opts" }; OPTSPAGE = true')
check(run("return #SECTIONS") == 0, "MPFEVER_LOBBYOPTSPAGE=0: a player reads the options on, no switch")
run('column{ host = true, section = "opts", opts = "" }')
check(run('return has("No game option on.   ·   Off by default. For every player; kept in the savegame.")') is True, "none on: said so")

print("the mods")
run('column{ host = true, section = "mods", blocking = 2 }')
check(run("return BODY.c[1].kind") == "mods", "the savegame's mods in their section")
check(run("return tabs()").endswith("Mods (5)*!"), "lit, with the alert icon when some are to fix", run("return tabs()"))
run('column{ host = true, nomods = true, section = "mods" }')
check(run("return tabs()") == f"Rules* | Computers (2) | Game options ({n_on})", "no mods: no tab, back to Rules", run("return tabs()"))

print("a player's lobby (read only)")
run('column{ host = false }')
check(run("return tabs()") == f"Rules* | Computers (2) | Game options ({n_on}) | Mods (5)", "the same tabs", run("return tabs()"))
check(run("return #btns()") == 0 and run('return #btns("rawbtn")') == 0, "Rules: no button")
check(run('return has("2 M") and has("On") and has("12 months")') is True, "Rules: the values as text")
check(run("return labelWidths()") == str(run("return LABEL_W")), "Rules: one width of label column", run("return labelWidths()"))
run('column{ host = false, section = "ai" }')
check(run("return #btns()") == 0 and run('return #btns("rawbtn")') == 0, "Computers: no button")
check(run('return has("Level: Hard   ·   Start: As the players") and has("Level: Easy   ·   Start: 5 M")') is True,
      "Computers: each one's level and start money as text")
run('column{ host = false, section = "opts" }')
check(run('local b = btns() return #b == 1 and b[1].t == "See the options"') is True, "Game options: only « See the options »")
run('column{ host = false, ais = {} }')
check(run("return tabs()") == f"Rules* | Game options ({n_on}) | Mods (5)", "no computer company: no tab", run("return tabs()"))
run('column{ host = false, ais = {}, section = "ai" }')
check(run("return tabs()").startswith("Rules*"), "a tab no longer there: back to Rules")
run('column{ host = false, modsFirst = true, blocking = 1 }')
check(run("return tabs()").endswith("Mods (5)*!"), "a player who lacks mods: the Mods tab first")
check(run("return unwrapped()") == "", "every long text wrapped in the column", run("return unwrapped()"))

print("the menu's code")
check(run("return OLDSWITCH") is False, "MPFEVER_LOBBYOLD unset: the lobby in sections")
check(re.search(r'^\tlocal LOBBYOLD = os\.getenv\("MPFEVER_LOBBYOLD"\) == "1"$', menu, re.M) is not None, "MPFEVER_LOBBYOLD=1: the switch is read")
check(re.search(r"^\t\t\tif separate and rulesView and not LOBBYOLD then\n\t\t\t\t-- .*\n\t\t\t\tleftCol = lobbyColumn\{", menu, re.M) is not None
      and "\t\t\telseif separate then\n" in menu, "the column of 0.6.2 kept behind the switch")
check(re.search(r"^\t\tlocal section = react\.useState\(nil\)$", menu, re.M) is not None, "the tab's state hook at the recipe's top level")
check(len(re.findall(r"(?<!function )featSection\(", menu)) == 3 and "if not OPTSPAGE and c.host then\n\t\t\t\tfeatSection(s," in menu,
      "the 0.6 switches in a section only without the page of the options")
check(chr(92) not in menu, "no backslash in the menu's file (see its top)")

if failures:
    print(f"FAIL {len(failures)} case(s): " + "; ".join(failures))
    sys.exit(1)
print("all passed")
sys.exit(0)
