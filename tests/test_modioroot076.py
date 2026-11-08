r"""Offline test: the launcher finds the Mod Hub mods where mod.io's settings keep them (0.7.6, Mods.ModioStorages, after TPF3-MP
1.5.0, MIT).

mod.io keeps a game's downloads in %PUBLIC%\mod.io unless "RootLocalStoragePath" in a user's settings
(%LOCALAPPDATA%\mod.io\10640\<user>\user.json) or in mod.io's own (%LOCALAPPDATA%\mod.io\globalsettings.json) moves them;
mod.io's support tells players to do so to keep their mods on another drive. MPFever looked in the default folder only: such a
player's Mod Hub mods were "not installed" (the mods check, the host's mods sent, the server's world).
  - Mods.ModioStorages, run by the launcher's self-test (RunServer076): a user's folder, then mod.io's settings, then the default,
    each once; an empty or relative one moves nothing; MPFEVER_MODIOROOT=0: the default only, as before;
  - the scan of the installed mods looks in every one of them; only "RootLocalStoragePath" is read of a user.json (it also holds
    the user's mod.io login).
Run: python tests/test_modioroot076.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
mods = open(os.path.join(L, "Mods.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
selftest = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


scan = mods[mods.index("static Dictionary<string, string> Scan()"):]
check('foreach (var modio in ModioStorages(lad, pub, Environment.GetEnvironmentVariable("MPFEVER_MODIOROOT") == "0"))' in scan[:4000],
      "the scan looks in every folder mod.io keeps the mods in")
ms = mods[mods.index("internal static List<string> ModioStorages("):mods.index("static Dictionary<string, string> Scan()")]
check(ms.index('"10640"') < ms.index('"globalsettings.json"') < ms.index(r'Add(Path.Combine(pub ?? @"C:\Users\Public", "mod.io"));'),
      "a user's settings, then mod.io's, then the default")
check('new Regex("\\"RootLocalStoragePath\\"' in ms, "only RootLocalStoragePath read")
check("Path.IsPathRooted(v)" in ms, "a relative folder moves nothing")
check("mod.io: a user's folder, then mod.io's settings, then the default" in selftest and "mod.io: MPFEVER_MODIOROOT=0, the default only, as before" in selftest,
      "the launcher's self-test runs it on real files")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
