"""Offline test: an old copy of a mod in the player's own mods folder (0.8.1, MODOLDCOPY and MODFPSTAMP; launcher/Mods.cs,
launcher/MainForm.cs, launcher/Core.cs, mod/mpfever_1/content/mpfever_menu.lua).

The user's PC, 2026-11-10, joining his dedicated server: "other version than the host's" for Industry Evolution and Auto Line
Namer whatever the player did. They had old copies in local\\mods (2026-10-22/23) beside the Mod Hub's, up to date; the game takes
the local copy, so downloading the mod again (the Mod Hub's copy) changed nothing. Players reported the same.
  - the lobby says which copy is the cause ("hub": the Mod Hub's copy is the host's version; "local": the local copy is not)
    and offers « Move the old copy out » (command modoldcopy): moved, whole, to local\\mpfever-old-mods\\<date>\\, where the game
    never looks, with where-it-was.txt; the mod then says "restart the game" until the launcher starts a game;
  - the host's (or server's) own old copy is said in its log;
  - a file replaced in a mod's folder (the host's files copied over) changes its version at once: the stamp reads the files'
    count, sizes and dates, not the folder's date (MODFPSTAMP);
  - MPFEVER_MODOLDCOPY=0 / MPFEVER_MODFPSTAMP=0: as before;
  - the launcher's self-test (RunOldCopy081) moves a copy and replaces a file.
Run: python tests/test_modoldcopy081.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")


def read(*p):
    return open(os.path.join(*p), encoding="utf-8-sig").read().replace("\r\n", "\n")


mods = read(L, "Mods.cs")
mf = read(L, "MainForm.cs")
core = read(L, "Core.cs")
st = read(L, "SelfTest.cs")
menu = read(HERE, "..", "mod", "mpfever_1", "content", "mpfever_menu.lua")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def body(s, start):
    b = s[s.index(start):]
    return b[:b.index("\n        }\n")]


sc = body(mods, "static Dictionary<string, string> Scan()")
check("cl.Add(d);" in sc and "lock (copiesGate) { copies = allCopies; localRoots = local; }" in sc, "every copy of each mod and the local roots kept by the scan")
of = body(mods, "public static string OldCopyFix(")
check('MPFEVER_MODOLDCOPY") == "0"' in of and "LocalCopy(id) == null" in of and 'FingerprintOf(o) == hostFp) return "hub";' in of and 'return "local";' in of,
      "OldCopyFix: hub when another copy is the host's version, local otherwise, off with MODOLDCOPY=0")
cmp = body(mods, "public static Check Compare(")
check('here = "restart"' in cmp and cmp.index('here = "restart"') < cmp.index('here = "notfound"'), "a copy moved out: restart, before notfound")
check("c.Differs.Add(F(" in cmp[cmp.index('here = "restart"') - 200:cmp.index('here = "restart"') + 300], "  and it blocks the load (Differs)")
check('OldCopyFix(e.Id, e.Fp) : ""' in cmp and "e.Hub, e.Size, fix));" in cmp, "the fix sent to the menu as the 11th field")
mo = body(mods, "internal static string MoveOut(string d)")
check('"mpfever-old-mods"' in mo and "Directory.Move(full, to);" in mo and "where-it-was.txt" in mo and "CopyDir" not in mo,
      "moved by a rename only (never half moved), next to the mods folder")
ml = body(mods, "public static string MoveLocalCopy(string id)")
check("var d = LocalCopy(id);" in ml and "throw" in ml and "MovedOut.Add(id)" in ml and "Rescan();" in ml, "only a copy in the player's own mods is moved")
info = body(mods, "static Tuple<string, string, string> Info(string id)")
check("string key = Stamp(d);" in info and "GetLastWriteTimeUtc(d).Ticks" not in info, "MODFPSTAMP: the version cache keyed by the files")
stp = body(mods, "internal static string Stamp(string d)")
check('MPFEVER_MODFPSTAMP") == "0"' in stp and "EnumerateFiles" in stp and "f.LastWriteTimeUtc.Ticks" in stp and "f.Length" in stp, "  count, sizes and dates of the files")
check("if (!BuiltIn(e)) DuplicateLocal(e.Id);" in body(mods, "public static string Describe("), "the host's own old copy said in its log")
la = core[core.index("public void Launch(string gameDir)"):]
check("Mods.MovedOut.Clear();" in la[:400], "a new game: no restart needed any more")
cm = mf[mf.index('else if (cmd == "modoldcopy")'):]
cm = cm[:cm.index('else if (cmd == "modpersonal"')]
check("Mods.MoveLocalCopy(id)" in cm and 'MPFEVER_MODOLDCOPY") == "0"' in cm and "SetHostMods(hm" in cm, "the menu's command modoldcopy moves it and compares again")
check("fix = f[11]" in menu, "menu: the 11th field read")
check('request("modoldcopy", id, playerName())' in menu and 'm.state == "differs" and m.fix ~= "" and not isHost' in menu, "menu: « Move the old copy out » for a player")
check('elseif m.here == "restart" then m.state = "restart"' in menu and 'm.state == "restart" or m.state == "bad") and 1' in menu, "menu: restart listed among the mods to fix")
check("ok &= RunOldCopy081();" in st, "the launcher's self-test runs MoveOut and Stamp")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
