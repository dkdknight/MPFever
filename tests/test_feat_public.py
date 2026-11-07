"""Offline test of mod/mpfever_1/content/mpfever_feat_public.lua (0.6, the public games' options, note 09) and of its integration.

The module alone: it loads without the game's API, declares its options as docs/FEATURES-0.6.md asks (ids, French and English
texts, modes, every option off by default, each parameter's default among its values, the values' labels through T(fr, en)), and
has no simulation code (no event, tick, gui...: the public games are MPFever.exe's and the list's work, see launcher/PublicGames.cs,
its self-test, and tests/test_serverlist.py); only its window tab (M.TAB, M.ui).

Integrated (the real files):
  - the options host (mpfever_feat.lua) lists it, offers its four options in both company modes, keeps them in the canon (a
    parameter's default left out), calls nothing of it in the simulation, and shows its tab only while one of them is on;
  - the MPFever window (the real U.featView ... U.featTabRows of mpfever_ui.script.lua, with u.status and u.exe): the "Public
    game" tab of the host from its own lines of mp_status.txt (the list's state, the IP and co-op warnings, the arrivals with
    Accept and Refuse, the ban list with Remove, Steam friends only), its buttons' requests to MPFever.exe; the players' tab;
    no tab with all off; the autotest's tab request "f_public" taken (U.pollTabReq);
  - the bridge's autotest scenario (the real H.pubtest and H.wintabs): the game's options said, the two tabs asked in turn;
  - MPFever.exe (text checks of the C#): the public options read from the lobby's string (GameOptions(), no field of their own),
    the option ids and parameters it reads are declared, every status line and lobby key the Lua reads is written, every request
    the lobby and the window send is taken, the autotest scenario pubtest is run.
Run: python tests/test_feat_public.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CONTENT = os.path.join(ROOT, "mod", "mpfever_1", "content")
MOD = os.path.join(CONTENT, "mpfever_feat_public.lua")
CS = os.path.join(ROOT, "launcher", "PublicGames.cs")
MAINFORM = os.path.join(ROOT, "launcher", "MainForm.cs")

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def extract(src, pattern, what):
    m = re.search(pattern, src, re.S | re.M)
    if not m:
        print(f"FAIL: {what} not found")
        sys.exit(1)
    return m.group(0)


def module_alone():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    # (no api, no game: as the lobby and the tests load the modules)
    L.execute("api = nil; game = nil")
    M = L.execute(read(MOD))
    check("loads without the game's API", M is not None)
    check("module id", M["ID"] == "public", M["ID"])
    keys = sorted(str(k) for k in M.keys())
    # (0.7.4: and its page's « How does it work? », HELP)
    check("options and a window tab only (no simulation code)", keys == ["HELP", "ID", "OPTIONS", "TAB", "ui"], keys)
    check("its tab", M["TAB"]["id"] == "public" and M["TAB"]["title"][1] and M["TAB"]["title"][2])
    T = L.eval("function(fr, en) return '[' .. en .. ']' end")
    ids = []
    for _, o in sorted(M["OPTIONS"].items()):
        oid = o["id"]
        ids.append(oid)
        check(f"{oid}: id", re.fullmatch(r"[a-z_]+", oid or "") is not None)
        check(f"{oid}: title and description in French and English",
              all(o[k] is not None and o[k][1] and o[k][2] and o[k][1] != o[k][2] for k in ("title", "desc")))
        check(f"{oid}: modes", o["modes"] == "both", o["modes"])
        check(f"{oid}: off by default", o["default"] is None)
        for _, p in sorted((o["params"] or L.table()).items()):
            values = list(p["values"].values())
            check(f"{oid}.{p['id']}: default among the values", p["default"] in values, f"{p['default']} in {values}")
            check(f"{oid}.{p['id']}: label in French and English", p["label"][1] and p["label"][2])
            if p["show"] is not None:
                shown = [p["show"](v, T) for v in values]
                check(f"{oid}.{p['id']}: values shown through T", all(isinstance(s, str) and s.startswith("[") for s in shown), shown)
    check("the four options of note 09", ids == ["public", "join_bans", "join_approve", "join_steamfriends"], ids)
    pub = M["OPTIONS"][1]
    params = {p["id"]: p for _, p in pub["params"].items()}
    check("public: 8 players at most by default (I7)", list(params["max"]["values"].values())[-1] == 8 and params["max"]["default"] == 8)
    check("public: no arrival during the game by default (I2)", params["late"]["default"] == 0)
    check("public: the IP address not shown by default (I3)", params["ip"]["default"] == 0)
    return ids, set(params)


def integrated():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
RESULTS = {}
function check(name, cond, got) RESULTS[#RESULTS + 1] = { name = name, ok = cond and true or false, got = tostring(got) } end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function T(fr, en) return en end
''')
    L.globals().PUBSRC = read(MOD)
    F = L.execute(read(os.path.join(CONTENT, "mpfever_feat.lua")))
    L.globals().F = F
    # ---- the options host
    L.execute(r'''
local listed = false
for _, id in ipairs(F.MODULES) do if id == "public" then listed = true end end
check("options host: public in its list of modules", listed)
F.loader = function(id) if id == "public" then return load(PUBSRC, "=public")() end return nil end
F.load(log)
check("options host: the module loaded", #F.mods == 1 and F.byId.public ~= nil)
for _, mode in ipairs({ "shared", "separate" }) do
  local ids = {}
  for _, e in ipairs(F.offered(mode)) do ids[#ids + 1] = e.opt.id end
  check("options host: the four options offered (" .. mode .. ")", table.concat(ids, ",") == "public,join_bans,join_approve,join_steamfriends", table.concat(ids, ","))
end
local c = F.canon("public=1;public.max=8;public.late=1;public.ip=1;join_bans=1;join_approve=0;bogus=1", "shared")
check("options host: the canon (on, declared, a parameter's default left out)", c == "join_bans=1;public=1;public.ip=1;public.late=1", c)
check("options host: parameters typed", F.param(F.parse("public=1;public.max=3"), "public", "max") == 3 and F.param({}, "public", "late") == 0)
-- nothing of it in the simulation: no hook, even with every option on
local st = {}
local B = { log = log, STEP = 200, gameTime = function() return 0 end, month = function() return 1 end, date = function() return nil end,
  money = function() return 0 end, book = function() return true end, companies = function() return {} end,
  isHost = true, me = "host", mode = "shared", send = function() return true end, chat = function() return true end, write = function() return true end }
F.simEvent(st, "f_opts", { s = "public=1;join_bans=1;join_approve=1;join_steamfriends=1", mode = "shared", mpfFrom = "host" }, B)
check("options host: its options come into the game (f_opts)", st.optsText == "join_approve=1;join_bans=1;join_steamfriends=1;public=1", st.optsText)
local n0 = #LOGS
F.simTick(st, B); F.simAction(st, { fn = "x" }, true, B); F.gui(st, B, 10)
check("options host: no simulation hook of it, nothing logged", not F.hearsGameEvents(st.optsText) and not F.wantsAllow(st.optsText) and #LOGS == n0 and st.feat == nil)
check("options host: no tab while off", #F.tabs({}) == 0 and #F.tabs(F.parse("")) == 0)
for _, id in ipairs({ "public", "join_bans", "join_approve", "join_steamfriends" }) do
  local t = F.tabs(F.parse(id .. "=1"))
  check("options host: its tab while " .. id .. " is on", #t == 1 and t[1].key == "f_public")
end
''')

    # ---- the window (the real functions)
    ui = read(os.path.join(CONTENT, "mpfever_ui.script.lua"))
    win_src = extract(ui, r"^U\.featOff = .*?^U\.featTabRows = function\(K, st, key\)\n.*?^end\n", "the window's game options")
    poll_src = extract(ui, r"^U\.pollTabReq = function\(\)\n.*?^end\n", "U.pollTabReq")
    L.execute(r'''
U = { isHost = function(st) return st and st.host == true end, winChanged = function() end }
REQS = {}
U.menuRequest = function(cmd, arg) REQS[#REQS + 1] = cmd .. " " .. tostring(arg) return true end
function sendLine() end
function money(n) return tostring(n) end
FILEDATA = {}
C = { feat = function() return F end, DIR = "D", BS = "/", NL = "\n", CR = "\r", TAB = "\t",
  Tf = function(fr, en, ...) local v, i = { ... }, 0 return (en:gsub("%%s", function() i = i + 1 return tostring(v[i]) end)) end,
  IO = { open = function(path) local s = FILEDATA[path] if not s then return nil end
    return { read = function() return s end, close = function() end } end } }
os.getenv = function() return nil end
K = { TEXT_W = 556, ICON_SETTINGS = "i" }
function K.text(t, class, cls, w) return { kind = "text", t = tostring(t), cls = cls } end
function K.muted(t, w) return { kind = "muted", t = tostring(t) } end
function K.section(icon, t) return { kind = "section", t = t } end
function K.gap() return { kind = "gap" } end
function K.row(c) return { kind = "row", c = c } end
function K.col(c) return { kind = "col", c = c } end
function K.btn(label, tip, fn, primary, enabled) return { kind = "btn", t = label, fn = fn, primary = primary } end
-- every text of a tab's rows, and its buttons by label
function flat(rows)
  local texts, btns = {}, {}
  local function walk(n)
    if type(n) ~= "table" then return end
    if n.kind == "btn" then btns[#btns + 1] = n
    elseif n.t then texts[#texts + 1] = (n.cls and ("[" .. n.cls .. "] ") or "") .. n.t end
    for _, c in ipairs(n.c or {}) do walk(c) end
  end
  for _, r in ipairs(rows) do walk(r) end
  return table.concat(texts, "\n"), btns
end
function has(s, sub) return s:find(sub, 1, true) ~= nil end
''')
    L.execute(win_src)
    L.execute(poll_src)
    L.execute(r'''
U.featAsked = nil
-- the host, everything on, the co-op, its own lines of mp_status.txt
local stH = { mode = "shared", host = true, opts = "join_approve=1;join_bans=1;public=1;public.ip=1;public.max=4",
  pub = "listed", pubname = "Ann's game", pubip = "203.0.113.5", pending = "Bob#2,Cid#3", pubkick = "1", bans = "Troll|2026-10-30" }
local tabs = U.featTabs(stH)
check("window: the Public game tab while an option is on", #tabs == 1 and tabs[1].key == "f_public")
local text, btns = flat(U.featTabRows(K, stH, "f_public"))
check("window, host: the list's state", has(text, "[success] The game is in the public list."), text)
check("window, host: its name and places", has(text, "Game name: Ann's game") and has(text, "Players at most: 4") and has(text, "Arrivals during the game: no"), text)
check("window, host: the IP warning with the address", has(text, "[warning] Your IP address (203.0.113.5) is shown to everybody"), text)
check("window, host: the co-op's warning", has(text, "a stranger will be able to build, demolish and spend"), text)
check("window, host: each arrival waiting", has(text, "Bob wants to join the game") and has(text, "Cid wants to join the game") and not has(text, "Bob#2"), text)
check("window, host: the banned players", has(text, "Banned players (1)") and has(text, "Troll   ·   2026-10-30"), text)
local labels = {}
for _, b in ipairs(btns) do labels[#labels + 1] = b.t end
check("window, host: Accept, Refuse for each arrival, Remove for each ban", table.concat(labels, ",") == "Accept,Refuse,Accept,Refuse,Remove", table.concat(labels, ","))
REQS = {}
btns[1].fn(); btns[4].fn(); btns[5].fn()
check("window, host: the buttons' requests to MPFever.exe", table.concat(REQS, "|") == "admit Bob#2 1|admit Cid#3 0|unban Troll", table.concat(REQS, "|"))
-- one company per player: no co-op warning; the list's other states
local stS = { mode = "separate", host = true, opts = "public=1;public.late=1", pub = "!old" }
text = flat(U.featTabRows(K, stS, "f_public"))
check("window, host: no co-op warning with one company per player", not has(text, "a stranger will be able") and has(text, "Arrivals during the game: yes"), text)
check("window, host: an older list said", has(text, "[warning] The public list does not take players' games yet"), text)
stS.pub = "!too many games"
text = flat(U.featTabRows(K, stS, "f_public"))
check("window, host: the list's error said", has(text, "(too many games)"), text)
stS.pub = "ended"
text = flat(U.featTabRows(K, stS, "f_public"))
check("window, host: out of the list once the game runs", has(text, "no longer in the public list"), text)
-- approval on, nobody waits; Steam friends only
text = flat(U.featTabRows(K, { mode = "shared", host = true, opts = "join_approve=1;join_steamfriends=1", pubfriends = "1" }, "f_public"))
check("window, host: nobody waiting", has(text, "Arrivals") and has(text, "Nobody is waiting."), text)
check("window, host: Steam friends only in force", has(text, "Steam: only your Steam friends can join through Steam."), text)
text = flat(U.featTabRows(K, { mode = "shared", host = true, opts = "join_steamfriends=1;public=1" }, "f_public"))
check("window, host: Steam friends only not in force in a public game", has(text, "Steam: everybody can join through Steam"), text)
-- a player: what the options mean, no button, none of the host's lines
local textP, btnsP = flat(U.featTabRows(K, { mode = "shared", opts = "join_approve=1;join_bans=1;public=1", pending = "Bob#2" }, "f_public"))
check("window, player: told, no button", has(textP, "This game is public") and has(textP, "accepts or refuses every arrival") and has(textP, "kick or ban") and #btnsP == 0
  and not has(textP, "Bob"), textP)
-- all off: no tab, and the tab asked says so
check("window: no tab with all off", #U.featTabs({ mode = "shared", host = true, opts = "" }) == 0)
check("window: the tab gone once off", flat(U.featTabRows(K, { mode = "shared", host = true, opts = "" }, "f_public")) == "This option is no longer on.")
-- the autotest's tab request of a module's tab
U.SessionWindow = true
OPENED = nil
U.openWindow = function(tab) OPENED = tab return true end
FILEDATA["D/ui_tab_req.txt"] = "f_public\t1\n"
U.pollTabReq()
check("window: the autotest's request of the f_public tab taken", OPENED == "f_public" and U.tabReqTab == "f_public", OPENED)
''')

    # ---- the bridge's autotest scenario (the real H.pubtest and H.wintabs)
    bridge = read(os.path.join(CONTENT, "mpfever_bridge.script.lua"))
    wintabs_src = extract(bridge, r"^H\.wintabs = function\(from, p\)\n.*?^end\n", "H.wintabs")
    pubtest_src = extract(bridge, r"^H\.pubtest = function\(from, p\)\n.*?^end\n", "H.pubtest")
    L.execute(r'''
H = {}
AUTO = { running = false, results = {}, points = {} }
G = { frames = 0, waits = {}, featSt = { optsText = "join_approve=1;join_bans=1;public=1;public.max=3" } }
TAB, NL, BS = "\t", "\n", "/"
WRITTEN = {}
C = { ROLE = "host", DIR = "D", IO = { open = function(path, mode)
  if mode == "wb" then return { write = function(_, s) WRITTEN[path] = s end, close = function() end } end
  local s = FILEDATA[path] if not s then return nil end
  return { read = function() return s end, close = function() end } end } }
FILEDATA = {}
FINISHED = nil
function autoFinish() AUTO.running = false; FINISHED = AUTO.results end
''')
    L.execute(wintabs_src)
    L.execute(pubtest_src)
    L.execute(r'''
H.pubtest("host", { role = "client" })
check("bridge: pubtest left to the other game", not AUTO.running and WRITTEN["D/ui_tab_req.txt"] == nil)
H.pubtest("host", { role = "host" })
check("bridge: pubtest says the game's options", AUTO.running and AUTO.results[1] == "pubtest: the game's options join_approve=1;join_bans=1;public=1;public.max=3 (public on)", AUTO.results[1])
check("bridge: pubtest asks the Public game tab first", WRITTEN["D/ui_tab_req.txt"] == "f_public\t1\n", WRITTEN["D/ui_tab_req.txt"])
-- the window answers each request; the scenario goes on to the Session tab, then ends
local function run() local w = G.waits; G.waits = {}; for _, x in ipairs(w) do x.fn() end end
FILEDATA["D/ui_tab_shown.txt"] = "1\tf_public\tf_public\tok\t12\n"
run()
check("bridge: the Public game tab's answer noted", AUTO.results[2] == "wintabs: f_public drawn as f_public, ok, 12 rows", AUTO.results[2])
run()
check("bridge: then the Session tab asked", WRITTEN["D/ui_tab_req.txt"] == "session\t2\n", WRITTEN["D/ui_tab_req.txt"])
FILEDATA["D/ui_tab_shown.txt"] = "2\tsession\tsession\tok\t20\n"
run(); run()
check("bridge: pubtest finished with its three lines", FINISHED ~= nil and #FINISHED == 3 and FINISHED[3] == "wintabs: session drawn as session, ok, 20 rows", FINISHED and #FINISHED)
G.featSt = { optsText = "" }
AUTO.running = false
H.pubtest("host", { role = "host" })
check("bridge: pubtest says when the options did not come", AUTO.results[1]:find("(PUBLIC NOT ON)", 1, true) ~= nil, AUTO.results[1])
''')
    for r in L.globals().RESULTS.values():
        check(r.name, r.ok, r.got)


def launcher_checks(ids, params):
    cs = read(CS)
    mf = read(MAINFORM)
    # the ids MPFever.exe reads (PublicGate.On / Param) are the declared ones
    used = set(re.findall(r'(?:On|Param)\("([a-z_]+)"', cs))
    check("MPFever.exe reads the declared options only", used and used <= set(ids), sorted(used))
    used_params = set(re.findall(r'Param\("public", "([a-z_]+)"\)', cs))
    check("MPFever.exe reads the declared parameters only", used_params and used_params <= params, sorted(used_params))
    # one string of the options: the lobby's (GameOptions), kept until mpfever_settings.txt is written again
    check("MPFever.exe: the public options read from the lobby's string", re.search(r"g\.Options = \(\) => .*GameOptions\(\);", cs) is not None)
    check("MPFever.exe: no options field of their own", re.search(r"\bstring gameOptions\b|\bOptOn\(|\bOptParam\(", mf) is None)
    save = extract(mf, r"internal static void SaveSetting\(string k, string v\)\n.*?^        \}\n", "SaveSetting")
    # (kept in memory, see KeptGameOptions: a settings write of the options changes them there; a failed read never turns them off)
    check("MPFever.exe: a settings write of the options keeps them in memory", 'if (k == "gameopts") gameOptsKept =' in save)
    # the host's own status lines the window reads are written
    mod = read(MOD)
    ui = read(os.path.join(CONTENT, "mpfever_ui.script.lua"))
    read_keys = set(re.findall(r'status\("([a-z]+)"\)', mod)) | set(re.findall(r'st\.(pubkick|pending)\b', ui))
    host_status = extract(cs, r"string PublicHostStatus\(\)\n.*?^        \}\n", "PublicHostStatus")
    written = set(re.findall(r'"([a-z]+)=', host_status))
    check("status: every line the window reads is written by MPFever.exe", read_keys and read_keys <= written, sorted(read_keys - written))
    # the lobby's keys
    menu = read(os.path.join(CONTENT, "mpfever_menu.lua"))
    menu_keys = set(re.findall(r'st\.(pub(?:Name|Ip|Kick)?|pending|bans)\b', menu))
    ms = extract(cs, r"void PublicMenuState\(IDictionary<string, string> ms\)\n.*?^        \}\n", "PublicMenuState")
    ms_keys = set(re.findall(r'ms\["([A-Za-z]+)"\]', ms))
    check("lobby: every key it reads is written by MPFever.exe", menu_keys and menu_keys <= ms_keys, sorted(menu_keys - ms_keys))
    # the requests of the lobby, the window and the tab are taken (and none is the options host's "opt")
    req = extract(cs, r"bool PublicMenuRequest\(string cmd, string arg\)\n.*?^        \}\n", "PublicMenuRequest")
    taken = set(re.findall(r'cmd != "([a-z]+)"', req))
    sent = set(re.findall(r'u\.exe\("([a-z]+)"', mod)) | set(re.findall(r'U\.menuRequest\("(admit|kick|ban|unban|pubname)"', ui)) \
        | set(re.findall(r'request\("(admit|kick|ban|unban|pubname)"', menu))
    check("requests: every one the lobby, the window and the tab send is taken", sent and sent <= taken, sorted(sent - taken))
    check("requests: none of them is the options host's", "opt" not in taken)
    # the autotest scenario
    check("autotest: MPFever.exe runs the scenario pubtest", 'scenario == "pubtest"' in mf and "void RunPubTest()" in cs)


def main():
    ids, params = module_alone()
    integrated()
    launcher_checks(ids, params)
    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
