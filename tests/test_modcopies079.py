"""Offline test of issue #136's fix (0.7.9): another copy of MPFever's mod in the game's folders, and the mod's version said by
the game (launcher/ModCopies.cs, MainForm.InitInstall/InitFinish/OnHostMessage, mod/.../mpfever_common.lua and the bridge's
"hello").

#136: the host had once unpacked MPFever into the game's mods\\release folder; the game took that old mod (before 0.7.5) in place
of the one its MPFever 0.7.8 installed, the two games ran two versions of the mod and parted after every resynchronisation
(19 in half an hour). Checked here, the code's side (MPFever.exe --selftest runs the search, the move and the texts on real
folders, see SelfTest.RunReport079):
  - before the game starts, the copies are looked for (not in the autotests) and offered to be moved out (a server: at once);
  - the mod's version is the release's (tests/check_repo.py compares it too) and goes in the game's "hello";
  - the host warns, log and chat, for every game whose mod is not its MPFever's, once per game and version;
  - MPFEVER_STALEMODS=0 and MPFEVER_MODVERCHECK=0 turn them off.
Run: python tests/test_modcopies079.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8").read().replace("\r\n", "\n")


fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


mc = read("launcher", "ModCopies.cs")
mf = read("launcher", "MainForm.cs")
common = read("mod", "mpfever_1", "content", "mpfever_common.lua")
bridge = read("mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
version = re.search(r'public const string Version = "([^"]+)"', mf).group(1)

init = mf[mf.index("        void InitInstall()"):]
init = init[:init.index("\n        }\n")]
check("GameInstall.InstallMod();" in init and "if (!autotest) FindStaleMods();" in init
      and init.index("GameInstall.InstallMod();") < init.index("FindStaleMods();"), "the copies looked for once the mod is installed (not in the autotests)")
fin = mf[mf.index("        void InitFinish()"):]
fin = fin[:fin.index("if (ServerMode)")]
check("OfferStaleMods();" in fin, "  offered to be moved out on the window's thread, before the game starts")
check('Environment.GetEnvironmentVariable("MPFEVER_STALEMODS") == "0"' in mc and "bool move = ServerMode;" in mc
      and "MessageBoxButtons.YesNo" in mc, "  the player asked (a dedicated server: at once); MPFEVER_STALEMODS=0: none")
check('"old-mod-copies"' in mc and "Directory.Move(copy, dst)" in mc and "GameInstall.CopyDir(copy, dst);" in mc and "where-it-was.txt" in mc,
      "  moved next to MPFever.exe (copied then deleted from another disk), with where it was")
check('Path.Combine(gameDir, "mods")' in mc and '"staging_area"' in mc and "!Same(d, src)" in mc,
      "  the game's mods folder and the players' staging_area; a copy the same as this MPFever's left alone")
m = re.search(r'^C\.MODVERSION = "([^"]+)"', common, re.M)
check(m is not None and m.group(1) == version, f"the mod's version is MPFever's ({version})")
check("mv = C.MODVERSION" in bridge and 'send("hello", {' in bridge, "  said in the game's hello")
hello = mf[mf.index('                case "hello":\n                    lock (players) players.Add(m.From);'):][:300]
check("WarnModVersion(m.From, m.Payload);" in hello, "the host looks at every game's hello, its own too")
wm = mc[mc.index("        void WarnModVersion("):]
check('Environment.GetEnvironmentVariable("MPFEVER_MODVERCHECK") == "0"' in wm and "modVersionWarned.Add(" in wm
      and "Log.Err(text);" in wm and 'HostChat("msg", "MPFever", text);' in wm, "  warned in the log and the chat, once per game and version; MPFEVER_MODVERCHECK=0: not")
check('if (!string.IsNullOrEmpty(mv) && mv == mine) return null;' in mc,
      "  a mod that says no version (before 0.7.9) is warned about")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
