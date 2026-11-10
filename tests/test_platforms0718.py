"""Offline test: the test hooks for the GOG and Epic copies of the game (0.7.18; GameLink.Launch, GameInstall.EpicLaunchArgs /
EpicAppName in launcher/Core.cs, StartLocalTest and AutoTest in launcher/MainForm.cs).

The Epic copy, started directly, asks the Epic launcher to start it again (EOS), without MPFever's arguments and settings; with
the portal's arguments "-EpicPortal -epicapp=<AppName>" (no account, no token) it stays the process MPFever started (tried by
hand on 2026-11-10). The tests of Steam + GOG + Epic games on one PC run each game from its own copy.
  - MPFEVER_GAMEDIR_<NAME> (letters and digits of the game's name, upper case): that game's own copy, only when it holds
    TransportFever3.exe; unset: the launcher's copy, as always;
  - the Epic arguments only next to an EOS SDK (never for a Steam or GOG copy); MPFEVER_EPICARGS=0: none;
  - MPFEVER_CLIENT2=1: a third game "Client2" in the autotest, which then waits for three games;
  - the launcher's self-test (RunPlatforms0718) runs EpicLaunchArgs;
  - (0.8.0) the copy chosen first, the Epic copy found by the Epic launcher's manifests, several copies asked once, the store
    in the reports (PlatformOf).
Run: python tests/test_platforms0718.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
core = open(os.path.join(L, "Core.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


la = core[core.index("public void Launch(string gameDir)"):]
la = la[:la.index("\n        }\n")]
check('"MPFEVER_GAMEDIR_" + new string((Name ?? "").Where(char.IsLetterOrDigit)' in la
      and 'File.Exists(Path.Combine(ownDir, "TransportFever3.exe"))) gameDir = ownDir;' in la, "MPFEVER_GAMEDIR_<NAME>: only a folder with the game")
check(la.index("gameDir = ownDir") < la.index('var exe = Path.Combine(gameDir, "TransportFever3.exe");'), "  before the game's path is made")
check("var epic = GameInstall.EpicLaunchArgs(gameDir);" in la and 'psi.Arguments += " " + epic;' in la, "the Epic arguments added to MPFever's")
ea = core[core.index("public static string EpicLaunchArgs("):]
ea = ea[:ea.index("\n        }\n")]
check('"EOSSDK-Win64-Shipping.dll"' in ea and 'MPFEVER_EPICARGS' in ea and '"^[A-Za-z0-9]+$"' in ea, "  only next to the EOS SDK, an AppName of letters and digits")
sl = mf[mf.index("void StartLocalTest()"):]
sl = sl[:sl.index("\n        }\n")]
check('Environment.GetEnvironmentVariable("MPFEVER_CLIENT2") == "1"' in sl and 'StartClient("Client2", "127.0.0.1"' in sl, "MPFEVER_CLIENT2=1: a third game")
check('int want = Environment.GetEnvironmentVariable("MPFEVER_CLIENT2") == "1" ? 3 : 2;' in mf, "  the autotest waits for three games then")
check("ok &= RunPlatforms0718();" in st, "the launcher's self-test runs EpicLaunchArgs")
# (0.8.0) the copies of the game
fg = core[core.index("public static string FindGameDir()"):]
fg = fg[:fg.index("\n        }\n")]
check(fg.index('MPFEVER_CHOSENFIRST') < fg.index("// 1. launcher placed inside the game folder"), "0.8.0: the chosen copy first (MPFEVER_CHOSENFIRST=0: as before)")
check("foreach (var p in EpicDirs())" in fg and fg.index("GogDirs()") < fg.index("EpicDirs()"), "  the Epic copy found, after GOG")
ig = mf[mf.index("bool InitFindGame()"):]
ig = ig[:ig.index("\n        }\n")]
check('MPFEVER_ASKCOPY' in ig and "copies.Count > 1" in ig and "!autotest && !ServerMode" in ig, "  several copies, none chosen: asked once (never in the autotests or on a server)")
op = open(os.path.join(L, "Options.cs"), encoding="utf-8-sig").read()
check("MainForm.ChooseCopy(GameInstall.AllCopies(), this)" in op, "  changed in the settings")
rs = open(os.path.join(L, "ReportShare.cs"), encoding="utf-8-sig").read()
check("GameInstall.PlatformOf(gameDir)" in rs, "  the store in the reports' header")
check('GameInstall.PlatformOf(dir) == "Epic"' in st and "GameInstall.FindGameDir() == gog" in st,"  the self-test runs PlatformOf and FindGameDir")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
