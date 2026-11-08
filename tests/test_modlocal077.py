"""Offline test: a mod installed twice is looked at where the game runs it from (0.7.7, Mods.Scan / DuplicateLocal / DiffersName
in launcher/Mods.cs).

The user's PC, 2026-11-07/08 (repc2343, r0241c): the game logged "Multiple (2) mods with same id found spy_industry_evolution,
the one from .../local/mods/spy_industry_evolution/ has been selected" (also Auto Line Namer, Auto Assign Terminals, Auto Color
Lines...). MPFever scanned the Mod Hub's folders first and kept the first copy of each id: it fingerprinted the Mod Hub's
Industry Evolution while the game ran an older local copy (9 files apart), the server ran the Mod Hub's, and no warning came.
That mod rebuilds factories and sets stocks: other code on two games makes industries, cargo and vehicles drift.
  - the player's own folders (local\\mods, local\\staging_area) are scanned first, as the game takes them; MPFEVER_MODLOCALFIRST=0:
    after the Mod Hub's, as before;
  - a local copy that hides a Mod Hub one is remembered, logged once ("installed twice: the game runs the copy in ...");
  - the "not the same version as the host's" message names that local copy (DiffersName).
The launcher's self-test (RunReport077) runs DiffersName.
Run: python tests/test_modlocal077.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "launcher", "Mods.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


scan = src[src.index("static Dictionary<string, string> Scan()"):]
scan = scan[:scan.index("\n        }\n")]
a = scan.find('bool localFirst = Environment.GetEnvironmentVariable("MPFEVER_MODLOCALFIRST") != "0";')
b = scan.find("if (localFirst) roots.AddRange(local);")
c = scan.find("foreach (var modio in ModioStorages(")
d = scan.find("if (!localFirst) roots.AddRange(local);")
check(0 < a < b < c < d, "the player's own folders first (MPFEVER_MODLOCALFIRST=0: after the Mod Hub's, as before)")
check("local.AddRange(LocalRoots(Path.GetDirectoryName(s)))" in scan, "  local\\mods and staging_area, as LocalRoots gives them")
check("if (!map.ContainsKey(id)) map[id] = d;" in scan and "dupLocal[id] = map[id];" in scan, "the first copy kept per id; a local one hiding another remembered")
dl = src[src.index("public static string DuplicateLocal(string id)"):]
dl = dl[:dl.index("\n        }\n")]
check("if (dupSaid.Add(id))" in dl and "Log.Warn(" in dl, "  logged once")
check("c.Differs.Add(DiffersName(e.Name, DuplicateLocal(e.Id)));" in src, "the other-version message names the local copy")
check('Mods.DiffersName("Industry Evolution",' in st, "the launcher's self-test runs DiffersName")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
