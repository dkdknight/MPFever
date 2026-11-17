"""Offline test: the mod's installation never leaves half a mod, and a failed one is said and stops the start (0.8.17, #401;
GameInstall.InstallCopy / InstallMod in launcher/Core.cs, ModMissingStop in launcher/MainForm.cs, RunSafeInstall0817 in
launcher/SelfTest.cs run by MPFever.exe --selftest in tests/run_all.py and build.bat; switches MPFEVER_SAFEINSTALL, MPFEVER_INSTALLSTOP).

#401 (lgeru, 2026-11-16 21:31): the disk was full. The launcher deleted the mod's copy in local\\mods, the new copy stopped halfway
("not enough space on the disk", said only in the launcher's log), and the game started with half a mod: "File was not cached in
filesystem: mpfever_1::/mpfever_auto.lua", the game closed.
  - the mod is copied beside the mods folder (local\\mpfever_1.install, not in mods\\: the game would take it for a mod), then put
    in place of the old copy only once whole; a failed copy leaves the old one whole and no half copy;
  - every account's copy is tried, a failure is said as an error and kept (GameInstall.InstallFailed);
  - the game is not started then, the player is told to free some space;
  - MPFEVER_SAFEINSTALL=0 / MPFEVER_INSTALLSTOP=0: as before (the self-test shows the old copy gone with the switch off).
Run: python tests/test_safeinstall0817.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


core = open(os.path.join(L, "Core.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
im = core[core.index("public static int InstallMod()"):]
im = im[:im.index("\n        }\n")]
check("each account's copy through InstallCopy, beside the mods folder", 'InstallCopy(src, dst, Path.Combine(local, "mpfever_1.install"));' in im)
check("  the game's mods\\release too (GOG, Wine)", 'InstallCopy(src, dst, Path.Combine(g, "mpfever_1.install"));' in im)
check("  a failure said as an error, the next account still tried; the start stopped for the signed-in account or when none got it (review)", "InstallFailed = e.Message;" in im and "continue;" in im and "ActiveSteamUser()" in im and "if (n == 0 && anyFailed != null && InstallFailed == null) InstallFailed = anyFailed;" in im and "if (notSteam) InstallFailed = e.Message;" in im)
check("  the delete-then-copy is gone from InstallMod", "Directory.Delete(dst, true);" not in im)
ic = core[core.index("internal static void InstallCopy(string src, string dst, string tmp)"):]
ic = ic[:ic.index("\n        }\n")]
check("InstallCopy: copied whole first, then swapped", ic.index("CopyDir(src, tmp);") < ic.index("Retry(() => Directory.Move(tmp, dst))"))
check("  the old copy back when the swap fails; a name of its own for it, a few tries (review)", "Directory.Move(old, dst);" in ic and "DateTime.UtcNow.Ticks" in ic and "void Retry(Action act)" in ic)
check("  switch MPFEVER_SAFEINSTALL=0: as before", 'Environment.GetEnvironmentVariable("MPFEVER_SAFEINSTALL") == "0"' in ic)
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
ms = mf[mf.index("bool ModMissingStop()"):]
ms = ms[:ms.index("\n        }\n")]
check("a failed installation stops the start, with a message", "var failed = GameInstall.InstallFailed;" in ms and "MessageBox.Show(this, why" in ms)
check("  switch MPFEVER_INSTALLSTOP=0: started as before", 'Environment.GetEnvironmentVariable("MPFEVER_INSTALLSTOP") != "0"' in ms)
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
check("the self-test runs it", "ok &= RunSafeInstall0817();" in st and "static bool RunSafeInstall0817()" in st)
check("  a failed copy keeps the old one; with the switch off it is gone (the bug)", "the old copy kept whole" in st and "nothing whole left (the bug)" in st)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
