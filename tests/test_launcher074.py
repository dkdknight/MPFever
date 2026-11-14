"""Offline test of the launcher's small changes of 0.7.4 (asked by the user, 2026-11-07):

  L1. The game no longer starts by itself when MPFever opens: the player sets MPFever up first, then clicks « Start Transport
      Fever 3 »; a box on the main page makes it start by itself next time (autolaunch=1, off for everybody at first). A
      Steam invitation and « Start Transport Fever 3 again » (--launch) start it at once (MPFEVER_AUTOLAUNCH=1: always).
  L2. The mod put into the game ran on the window's thread: Windows said "not responding" for those seconds. It runs beside
      the window now, a moving bar and a text saying to wait (MPFEVER_INITSYNC=1: as before).
  L3. The host's copies made by a resynchronisation (« MPFever resync ») were hidden from the Multiplayer page and players
      asked where the game they had just played was: a box shows them, with what they are (MPFEVER_MENU_RESYNC=1: shown).
  L4. The in-game MPFever window shows the percent of the host's game a joining or reloading player has received
      (MPFEVER_SENDPCT=0: not counted).
The decisions (LaunchAtStart, PartsPct) are run by the launcher's self-test; this checks that they are used where they must be.
Run: python tests/test_launcher074.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
main = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read()
selftest = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
menu = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_menu.lua"), encoding="utf-8").read()
ui = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_ui.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


fin = main[main.index("void InitFinish()"):main.index("/// <summary>(0.6.5, #111) MPFever.exe copied alone")]
check("if (!modMissing && LaunchAtStart(AutoLaunchSetting(), JoinAtStart != null, Program.Args)) { ShowLaunchControls(); StartMenuMode(); return; }" in fin
      and "waitingLaunch = true;" in fin, "L1. the game starts at once only when asked, else it waits for the player's click")
check('internal static bool AutoLaunchSetting() => LoadSettings().TryGetValue("autolaunch", out var v) && v == "1";' in main,
      "L1. the box is off until ticked (autolaunch=1)")
check('SaveSetting("autolaunch", autoLaunchBox.Checked ? "1" : "0")' in main and "launchBtn.Click += (s, e) => LaunchFromButton();" in main,
      "L1. the box saves its choice, the button starts the game")
again = main[main.index("void StartAgain(bool updated)"):main.index("void StartAgain(bool updated)") + 1500]
check('"--updated --launch" : "--launch"' in again, "L1. Start Transport Fever 3 again (--launch) starts the game at once")
init = main[main.index("        void Init()"):main.index("bool InitFindGame()")]
check('if (!autotest && !ServerMode && Environment.GetEnvironmentVariable("MPFEVER_INITSYNC") != "1")' in init
      and "try { InitInstall(); }" in init and 'Name = "Mod install"' in init and "installing = true;" in init,
      "L2. the mod is put into the game beside the window (not for the autotests nor a server)")
check("busyBar.Visible = player && installing;" in main and "launchBtn.Enabled = !installing;" in main,
      "L2. a moving bar meanwhile, the start button waits for it")
check("GameInstall.InstallMod()" in main[main.index("void InitInstall()"):main.index("void InitFinish()")]
      and "WarnNativeMissing();" in fin, "L2. the files in the background, the warnings back on the window")
ls = menu[menu.index("local function listSaves()"):menu.index("-- The mods of a savegame (MPFever left out)")]
check('not name:find("^MPFever resync")' not in ls and 'local function isResyncSave(name)' in menu,
      "L3. the resynchronisations' copies are listed (the Host tab filters them)")
check("(showResync:old() or not isResyncSave(s.saveName))" in menu and "builtin.CheckBox{" in menu
      and "onValueChange = function(v) showResync:set(v == 1) end" in menu, "L3. a box shows them, off by default")
check("SendPctOf(id)" in main and "Tick();" in main and 'Environment.GetEnvironmentVariable("MPFEVER_SENDPCT") != "0"' in main,
      "L4. the host counts the parts sent to each player and puts the percent in the players' status")
check("pct = tonumber(f[6] or \"\")" in ui and 'C.Tf("reçoit la partie de l\'hôte : %s %", "receiving the host\'s game: %s %", pl.pct)' in ui,
      "L4. the in-game window reads it and shows it")
# the in-game window's parser, run on old and new lines (a status of 0.7.3 has five fields)
try:
    import lupa.lua52 as lupa
    m = re.search(r"\t\tif k == \"p\" then\n(.*?)\n\t\telseif k then", ui, re.S)
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("C = { TAB = string.char(9) } st = { players = {} }")
    parse = L.eval("function(v) st = { players = {} } " + m.group(1) + " return st.players[1] end")
    a = parse("Ann#2\tAnn\tjoining\t0\t\t45")
    b = parse("Host\tHost\tok\t0\thost")
    c = parse("Bob#3\tBob\tloading\t0\t\t")
    check(a.state == "joining" and a.pct == 45 and a.role == "" and b.role == "host" and b.pct is None and c.pct is None,
          "L4. the players' lines read with and without the percent")
except ImportError:
    print("lupa is not installed: the parser is not run")
# (the screenshot of 2026-11-07: with the launch button and its box, the speed controls pushed x2 and x4 out of the bar; there
# is no game to speed up yet, they are hidden while the game waits for its launch)
check("speedLabel = new Label {" in main and "bool speed = !(player && (waitingLaunch || installing) && !gameClosed);" in main
      and "pauseBtn.Visible = x1Btn.Visible = x2Btn.Visible = x4Btn.Visible = speed;" in main,
      "L1. the speed controls hidden while the game waits for its launch")
check("ok &= RunServerJoin074();" in selftest and "MainForm.LaunchAtStart(" in selftest and "MainForm.PartsPct(" in selftest,
      "the launcher's self-test runs the decisions")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
