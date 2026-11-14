r"""Offline test: the game is not started when it could not find MPFever's mod (0.8.8, issue #294; GameInstall.ModReachable /
ModsDirs in launcher/Core.cs, MainForm.ModMissingStop).

#294 (2026-11-14 00:52, an 11 KB report): MPFever.exe was started without its files: "MPFever.exe is not in a release folder
(no mod\mpfever_1)", "winhttp.dll missing next to MPFever.exe", "Mod or Steam not found, mod installation skipped". The game was
started all the same with "--script mpfever_1::/mpfever_auto.lua", answered "File not found (unknown mod)" and closed 12 s
later ("Ungraceful exit"): for the player, a crash with nothing said.
  - no mod folder beside MPFever.exe and no copy of the mod in the game's folders: the game is not started; the log and a
    message say what to do (extract the whole archive, check the antivirus);
  - at the automatic start and at the « Start Transport Fever 3 » button, which stays;
  - a copy already in the game (an older install) or the mod folder there: started as before;
  - MPFEVER_NOMODSTOP=0: as before; autotests, servers and --dev are not concerned;
  - the launcher's self-test (RunModStop088) runs ModReachable on folders of its own.
Run: python tests/test_modstop088.py
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


def body(src, head):
    b = src[src.index(head):]
    return b[:b.index("\n        }\n")]


r = body(core, "public static bool ModReachable(string modSource, IEnumerable<string> modsDirs)")
check("if (!string.IsNullOrEmpty(modSource)) return true;" in r, "the mod folder beside MPFever.exe: reachable (installed at every start)")
check('File.Exists(Path.Combine(d, "mpfever_1", "mod.json"))' in r and r.rstrip().endswith("return false;"),
      "else a copy with its mod.json in one of the game's mods folders; none: not reachable")
d = body(core, "public static List<string> ModsDirs(string gameDir)")
check('Path.Combine(gameDir, "mods", "release")' in d and 'Path.Combine(u, AppId, "local", "mods")' in d,
      "the folders looked at: the game's mods\\release, each Steam account's local\\mods (where InstallMod puts it)")

m = body(mf, "bool ModMissingStop()")
check('Environment.GetEnvironmentVariable("MPFEVER_NOMODSTOP") == "0"' in m, "MPFEVER_NOMODSTOP=0: as before")
check("GameInstall.ModReachable(GameInstall.FindModSource(), GameInstall.ModsDirs(gameDir))" in m, "asks ModReachable with this MPFever's mod folder")
check("bool reachable = true;" in m and "catch { }" in m, "  an error while looking: started as before")
check("Log.Err(text);" in m and "MessageBox.Show(this, text" in m and "Extract the whole MPFever archive into a new folder" in m,
      "said in the log and in a message, with what to do")
b = body(mf, "void LaunchFromButton()")
check(b.index("if (ModMissingStop()) return;") < b.index("waitingLaunch = false;"), "the button: nothing started, the button stays")
f = body(mf, "void InitFinish()")
check("bool modMissing = ModMissingStop();" in f and "if (!modMissing && LaunchAtStart(" in f, "the automatic start: not without the mod")
check(f.index("if (MenuModeDefault && !autotest)") < f.index("bool modMissing = ModMissingStop();") < f.index("if (autotest)"),
      "  only the players' start (autotests, servers and --dev unchanged)")
check("ok &= RunModStop088();" in st and "GameInstall.ModReachable(null, dirs)" in st, "the launcher's self-test runs it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
