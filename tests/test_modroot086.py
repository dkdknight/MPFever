"""Offline test: a mod's files at its own root count for the personal check (0.8.6, #280; Mods.Personal in launcher/Mods.cs,
RunModRoot086 in launcher/SelfTest.cs, run by MPFever.exe --selftest in tests/run_all.py and build.bat).

#280 (Alex and Logan, 2026-11-12): the host ran "Canadian Names" (spearin_names_canadian), a mod of TF2's layout: its name lists
at its root (names/canada_wp/canada_wp.names.lua), no content/ folder. MPFever read only content/, took it for an interface mod
(personal), and left it out of the player's game: that game crashed on the first name it looked for (ResTypeRep<NameDesc>::Get).
  - the root's files are read as content/'s: a names mod is "game resources (names/...)", not personal;
  - mod.json, and the images and texts at the root, stay inert (an interface mod with a preview and a readme stays personal);
  - MPFEVER_MODROOTFILES=0: outside content/ nothing counts, as before;
  - the self-test builds such a mod and checks the three.
Run: python tests/test_modroot086.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


m = open(os.path.join(L, "Mods.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
p = m[m.index("public static string Personal(string dir)"):]
p = p[:p.index("\n        }\n")]
check("outside content/: mod.lua still not personal", 'if (name == "mod.lua") return "mod.lua";' in p)
check("  switch MPFEVER_MODROOTFILES=0: skipped as before", 'GetEnvironmentVariable("MPFEVER_MODROOTFILES") == "0") continue;' in p)
check("  mod.json and the root's images and texts inert", 'if (name == "mod.json" || !rel.Contains("/") && InertExt.Contains(ext)) continue;' in p)
check("  the root's other files read as content/'s", "inner = rel;" in p and "else inner = rel.Substring(8);" in p)
check("  then the same checks (game resources, scripts)", p.index("inner = rel;") < p.index('if (ResourceDir.IsMatch("/" + inner)) return "game resources (" + inner + ")";'))
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
check("the self-test runs it", "ok &= RunModRoot086();" in st and "static bool RunModRoot086()" in st)
check("  a names mod at the root: game resources", 'why.StartsWith("game resources (names/")' in st)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
