"""Offline test: a mod of the game's world is never taken for an interface (personal) mod (0.8.17, #402 #403; Mods.Personal and
Mods.WorldLua in launcher/Mods.cs, RunPersonalWorld0817 in launcher/SelfTest.cs, run by MPFever.exe --selftest in
tests/run_all.py and build.bat).

#403 (BeunHaas34 and P0WeRZz, 2026-11-16): "Narrow One-Way Tram Track" (griese_narrow_single_tram) is one street template,
content/infrastructure/griese_single_tram/narrow.street_template.lua, and its images. "infrastructure" was not among the folders of
game resources and a street template is plain Lua: the host's launcher took it for an interface mod, P0WeRZz's game left it out,
the host's tram street upgrade was refused there (ResTypeRep<StreetTemplate>::Get, index -1) and the games were reloaded.
  - the game's other content folders count (infrastructure, depots, stations, buildings, ...: base/content of build 40425);
  - a Lua file named as a resource of the world ("<name>.<kind>.lua": street_template, con, module, mat...) counts, whatever its
    folder; plain Lua, .res.lua (checked as before), .css.lua, .gres.lua, .lang.lua and .script.lua (judged by what it does, as
    before: zhenya's interface scripts are gui/*.script.lua) do not;
  - MPFEVER_PERSONALWORLD=0: as before (the self-test shows the tram mod taken for personal then: the bug);
  - the self-test builds the tram mod, a construction in a folder of its own, and an interface mod that stays personal.
On the PC of 2026-11-17: 105 installed mods, the same verdicts with and without the switch (no other mod changes side).
Run: python tests/test_personalworld0817.py
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
check("the switch MPFEVER_PERSONALWORLD", 'GetEnvironmentVariable("MPFEVER_PERSONALWORLD") != "0"' in p)
check("the game's other content folders", 'WorldDir.IsMatch("/" + inner)) return "game resources (" + inner + ")";' in p)
check("  infrastructure among them", "(infrastructure|" in m)
check("a Lua resource of the world", 'if (ext == ".lua" && WorldLua(name)) return "a resource of the game\'s world (" + inner + ")";' in p)
check("  before the Lua content checks", p.index("WorldLua(name)") < p.index('if (name.EndsWith(".gs.lua"))'))
w = m[m.index("public static bool WorldLua(string fileName)"):]
w = w[:w.index("\n        }\n")]
check("  only the world's kinds by name (the review: a library's dotted name stays the interface's)", "return WorldKinds.Contains(kind);" in w and '"street_template"' in m and '"con"' in m)
check("  the game's folders not for an image or a text (the review)", "if (!InertExt.Contains(ext) && WorldDir.IsMatch" in p)
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
check("the self-test runs it", "ok &= RunPersonalWorld0817();" in st and "static bool RunPersonalWorld0817()" in st)
check("  the tram mod of #403 is shared", 'why.StartsWith("game resources (infrastructure/")' in st)
check("  and personal with the switch off (the bug)", 'Check(Mods.Personal(dir) == "", "MPFEVER_PERSONALWORLD=0: taken for personal as before (the bug)");' in st)
check("  an interface mod stays personal", "stays personal (" in st and "dut.script.lua" in st)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
