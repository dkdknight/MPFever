r"""Offline test: the mod is installed for a Steam account that never started Transport Fever 3 (0.7.17, issues #192 and #196;
GameInstall.InstallMod / LocalToMake / ActiveSteamUser in launcher/Core.cs).

#192 (gwenv, 22:22) and #196 (TurkeyPeck, 23:12): no "Mod installed in" in the launcher's log; the game stopped at once with
"Mod was not cached in filesystem: mpfever_1::/mpfever_auto.lua". The account's userdata/<id>/3493540/local folder did not exist
yet (the game made it only then, its crash dump is in it), and InstallMod skipped such accounts without a word.
  - the signed-in account's folder (HKCU\Software\Valve\Steam\ActiveProcess ActiveUser), or the only account's, is made first;
  - no install anywhere: an error says what to do;
  - MPFEVER_MKLOCAL=0: as before;
  - the launcher's self-test (RunInstall0717) runs LocalToMake on folders of its own.
Run: python tests/test_mklocal0717.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
core = open(os.path.join(L, "Core.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


im = core[core.index("public static int InstallMod()"):]
im = im[:im.index("\n        }\n")]
check('Environment.GetEnvironmentVariable("MPFEVER_MKLOCAL") != "0"' in im, "MPFEVER_MKLOCAL=0: as before")
check(im.index("LocalToMake(userdata, ActiveSteamUser())") < im.index("foreach (var u in Directory.GetDirectories(userdata))"),
      "the folder made before the accounts are looked at")
check("Directory.CreateDirectory(made)" in im, "  made")
check("if (n == 0 && mk) Log.Err(NoInstallText());" in im, "installed nowhere: said, with what to do")
a = core[core.index("public static string ActiveSteamUser()"):]
a = a[:a.index("\n        }\n")]
check(r'@"Software\Valve\Steam\ActiveProcess"' in a and '"ActiveUser"' in a, "the signed-in account from Steam's registry key")
t = core[core.index("public static string LocalToMake("):]
t = t[:t.index("\n        }\n")]
check("accounts.Count == 1" in t and "Path.Combine(acc, AppId, \"local\")" in t, "LocalToMake: the signed-in account, or the only one")
check("ok &= RunInstall0717();" in st and "GameInstall.LocalToMake(ud, null) == want" in st, "the launcher's self-test runs it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
