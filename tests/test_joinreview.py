"""Offline test of 0.6.13's DLC and join changes (the user's requests of 2026-11-05):

1. Different DLCs: no second press of « Start the game » any more; the lobby shows the warning with the advice (the host can
   switch the DLCs off in the savegame's mods, the players can get the DLCs they lack, the game can still be started but may
   desynchronise). The session's DLCs are the savegame's when its mods are known (the host's menu wrote them, or a dedicated
   server read them from its world's savegame): a DLC the host switched off in the savegame no longer counts.
2. A player who joins a game already running (no lobby: a player's game started, a dedicated server) sees the game's mods and
   DLCs on its Multiplayer page first ("review"), gets what it lacks (Mod Hub install, the DLC's Steam page), then presses « Join
   the game »: only then does the host send it the game. The same mods and DLCs join at once; MPFEVER_JOINREVIEW=0 as before.
   A dedicated server now tells its world's mods and DLCs (before, none).
3. A DLC of the host's game this PC lacks no longer stops the load ("mods missing"): the game loads without it, as its own load
   screen lets a player do (MPFEVER_DLCDROP=0: as before).

Lua parts run through lupa (the real mpfever_auto.lua with a mocked game); the C# parts are text checks of the launcher (their
logic is checked by MPFever.exe --selftest: RunDlcs, RunSaveMods, RunServerConfig).
Run: python tests/test_joinreview.py
"""
import os, re, shutil, sys, tempfile

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CONTENT = os.path.join(ROOT, "mod", "mpfever_1", "content")

MOCK = r'''
ENV = ENV or {}
os.getenv = function(k) return ENV[k] end
LOADS, DETAILS = {}, {}
print = function() end
api = { type = {
  SavegameId = { new = function() return {} end },
  SaveGameDetails = { new = function(info) return { info = info } end },
  ModId = { new = function() return {} end },
} }
-- the host's game: MPFever, the Deluxe pack (a DLC), and one mod
INFO = { mods = { { name = "mpfever_1" }, { name = "urbangames_deluxe_upgrade_pack" }, { name = "auto_signals_1" } },
  metadata = { gameModDescs = {
    { modId = { name = "urbangames_deluxe_upgrade_pack" }, name = "Deluxe", modSource = "DLC" },
    { modId = { name = "auto_signals_1" }, name = "Auto Signals", modSource = "mod.io" },
  } } }
HAVE = { mpfever_1 = true, auto_signals_1 = true }
app = {
  SaveGameNamespace = { getSavegame = function() return "ns" end },
  findAllSavegames = function() return { { saveName = "MPFever resync Host", path = "p/a.sav", timestamp = 2 } } end,
  getSavegameInfo = function(id) return { isCompleted = function() return true end, get = function() return { info = INFO } end } end,
  loadGame = function(id, editor, details)
    LOADS[#LOADS + 1] = id.saveGameName
    local names = {}
    if details and details.mods then for _, m in ipairs(details.mods) do names[#names + 1] = m.name end end
    DETAILS[#DETAILS + 1] = details and details.mods and table.concat(names, ",") or "(the savegame's)"
  end,
  getUserProfile = function() return { getModRep = function() return { exists = function(self, m) return HAVE[m.name] == true end } end } end,
  isWaitForStartReadyGame = function() return false end,
}
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


def lua_loads(tmp, env, have):
    """the main menu loads the host's game received: (loads, details, missing_mods.txt, auto.log)"""
    for n in os.listdir(tmp):
        os.remove(os.path.join(tmp, n))
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = { MPFEVER_DIR = [[" + tmp + "]] }")
    for k, v in env.items():
        L.execute(f'ENV.{k} = "{v}"')
    L.execute(MOCK)
    L.execute("HAVE = { " + ", ".join(f"{k} = true" for k in have) + " }")
    L.execute("package.loaded.mpfever_auto_embed = true")
    A = L.execute(open(os.path.join(CONTENT, "mpfever_auto.lua"), encoding="utf-8").read())
    with open(os.path.join(tmp, "menu_state.txt"), "w", encoding="utf-8", newline="") as f:
        f.write("phase=loading\nload=MPFever resync Host\nloadSeq=r1-1\nend=1\n")
    tick = L.eval("function(a) return a.menuTick() end")
    for _ in range(4):
        tick(A)
    loads = list(L.eval("LOADS").values())
    details = list(L.eval("DETAILS").values())
    mm = os.path.join(tmp, "missing_mods.txt")
    missing = open(mm, encoding="utf-8").read() if os.path.exists(mm) else ""
    lg = os.path.join(tmp, "auto.log")
    log = open(lg, encoding="utf-8").read() if os.path.exists(lg) else ""
    return loads, details, missing, log


def loader():
    tmp = tempfile.mkdtemp(prefix="mpf_joinreview_")
    try:
        loads, details, missing, log = lua_loads(tmp, {}, ["mpfever_1", "auto_signals_1"])
        check("a DLC of the host's game this PC lacks: the game loads (no 'mods missing')", loads == ["MPFever resync Host"] and missing == "", (loads, missing))
        check("and without that DLC", details == ["mpfever_1,auto_signals_1"], details)
        check("the log says so", "DLC urbangames_deluxe_upgrade_pack of the host's game not on this PC" in log, log[-300:])
        loads, details, missing, log = lua_loads(tmp, {}, ["mpfever_1", "auto_signals_1", "urbangames_deluxe_upgrade_pack"])
        check("this PC has the DLC: loaded with the savegame's own mods", loads == ["MPFever resync Host"] and details == ["(the savegame's)"], (loads, details))
        loads, details, missing, log = lua_loads(tmp, {}, ["mpfever_1"])
        check("a mod (not a DLC) missing: still not loaded, the mod named", loads == [] and "auto_signals_1" in missing and "urbangames_deluxe" not in missing, (loads, missing))
        loads, details, missing, log = lua_loads(tmp, {"MPFEVER_DLCDROP": "0"}, ["mpfever_1", "auto_signals_1"])
        check("MPFEVER_DLCDROP=0: a missing DLC stops the load, as before", loads == [] and "urbangames_deluxe_upgrade_pack" in missing, (loads, missing))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def launcher():
    form = read("launcher", "MainForm.cs")
    mods = read("launcher", "Mods.cs")
    server = read("launcher", "Server.cs")
    st = read("launcher", "SelfTest.cs")
    # 1. no second press, the advice
    check("no second press of « Start the game »", "DlcStartAllowed" not in form and "DlcStartAllowed" not in mods and "dlcAskedAt" not in form)
    check("the start says the different DLCs in the log and goes on",
          re.search(r'if \(dw != ""\) Log\.Warn\(T\("Lancement avec des DLC différents : ".*?\n\s*new Thread\(StartLobbyGame\)', form, re.S) is not None)
    check("the advice: switch them off in the savegame, or get them; the game can still be started",
          "désactiver ces DLC dans les mods de la sauvegarde" in mods and "acquérir les DLC qui leur manquent" in mods and "La partie peut tout de même être lancée" in mods)
    check("the host's and the player's warnings carry it once", "Mods.DlcWarningText(dlcIssues.Values.ToList())" in form and "dlcWarn = Mods.DlcWarningText(parts);" in form)
    check("the session's DLCs: the savegame's when known, MPFEVER_SAVEDLCS=0 the installed ones",
          'Mods.SaveDlcs(lobbyMods, lobbyModsKnown) ?? Mods.InstalledDlcs()' in form and 'MPFEVER_SAVEDLCS' in form and "lobbyModsKnown = File.Exists(f);" in form)
    check("told in the lobby, the welcomes and the players' check", form.count('[\\"dlcs\\"]=" + LuaLit.Quote(SessionDlcs())') == 3 and "Mods.DlcWarning(who, SessionDlcs(), theirs)" in form)
    # 2. the join review, host side
    check("host: a game running asks the review in its welcome", "bool review = menuMode && !lobbyOpen && JoinReviewOn;" in form and '(review ? ",[\\"review\\"]=true" : "")' in form)
    check("host: the player waits in the review, no game sent", re.search(r"else if \(review\)\s*\{\s*lock \(reviewing\) reviewing\.Add\(p\.Name\);", form) is not None)
    check("host: joinready sends it the game", re.search(r'case "joinready":.*?reviewing\.Remove\(from\.Name\).*?joinPending = true;', form, re.S) is not None)
    check("host: a resynchronisation meanwhile skips it", "all = all.Where(n => !reviewing.Contains(n)).ToArray();" in form)
    # (found in game, 2026-11-05: a dedicated server dropped every message of a player whose game had not loaded its world yet)
    check("server: the player's word and DLCs taken before its game loads", 'm.Kind != "joinready" && m.Kind != "dlccheck"' in form)
    check("host: gone, or the session ended: forgotten", "lock (reviewing) reviewing.Remove(p.Name);" in form and "lock (reviewing) reviewing.Clear();" in form)
    check("MPFEVER_JOINREVIEW=0: as before", 'Environment.GetEnvironmentVariable("MPFEVER_JOINREVIEW") != "0"' in form)
    # the player's side
    check("player: nothing to look at (same mods and DLCs) or accepted already: joins at once",
          "if (review && !JoinReviewClear() && reviewAccepted != key)" in form and "else send(false);" in form)
    check("player: else the review page, resync_have held until « Join the game »",
          'menuPhase = "review";' in form and 'reviewSend = () => { reviewAccepted = key; send(true); };' in form and 'else if (cmd == "joinready")' in form)
    check("player: the connection's « connected » does not hide the review", 'if (!clientCancelled && menuPhase != "review")' in form)
    check("player: a mod missing, in another version or incompatible, or other DLCs, is something to look at",
          "c.Missing.Count == 0 && c.Differs.Count == 0 && c.Bad.Count == 0" in form and "string.IsNullOrEmpty(dlcWarn)" in form)
    check("player: the DLC list for the page, and a DLC's Steam page", '["dlcList"] = (lobbyOpen || hostGame != null) ? "" : dlcListView,' in form
          and 'else if (cmd == "dlcstore")' in form and "Mods.DlcStoreUrl(arg" in form)
    check("the Deluxe upgrade's store page", '"steam://store/3979620"' in mods)
    # a dedicated server tells its world's mods
    check("server: its world's mods and DLCs from its savegame", "SaveInfo.Mods(GameInstall.FindSave(server.World))" in server and "lobbyModsKnown = true;" in server
          and 'MPFEVER_SERVERMODS' in server)
    check("server: its status names a player looking", "regarde les mods et DLC avant de rejoindre" in server)
    check("self-test runs the new checks", "ok &= RunSaveMods();" in st and "ok &= RunServerConfig();" in st)


def menu():
    m = read("mod", "mpfever_1", "content", "mpfever_menu.lua")
    check("menu: the review's title", 'review = T("Avant de rejoindre la partie", "Before joining the game"),' in m)
    check("menu: « Join the game » asks joinready", 'st.phase == "review" and not isHost' in m and 'request("joinready", "", playerName())' in m)
    check("menu: the DLC list with the Steam page of a DLC to get", '(st.dlcList or "") ~= ""' in m and 'request("dlcstore", dlcId, playerName())' in m
          and 'state == "host"' in m)
    check("menu: the page opens itself once for the review", 'local review = phase == "review" and not reviewShown:get()' in m and 'if phase == "review" then reviewShown:set(true) end' in m)
    check("menu: a player's mods list without the DLCs (no Mod Hub advice for them)", 'if m.source ~= "DLC" then kept[#kept + 1] = m end' in m)
    # the C# status keys the menu reads
    form = read("launcher", "MainForm.cs")
    check("the status carries what the menu reads", '["dlcList"]' in form and '["dlcWarn"]' in form)


def main():
    loader()
    launcher()
    menu()
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
