"""Test of #159's fix (0.7.12, launcher/Mods.cs, Mods.TopModId and Mods.Scan).

Domenik (2026-11-08): MPFever said "the mod mw_basis is installed twice: the game runs the copy in local\\mods\\mw_br189" and
"these mods do not have the same version as the host: ModWerkstatt Base Mod", the host's game not loaded. A mod was known by the
first "modId" of its mod.json, and BR189's mod.json names ModWerkstatt's Base Mod ("mw_basis") first, in its "dependencies".
A mod is now known by the "modId" of the mod.json's top level. MPFEVER_MODIDTOP=0: the first one, as before.
The C# function itself is run by the launcher's selftest (SelfTest.RunModIdTop0712, MPFever.exe --selftest in run_all.py);
this test checks that the scan uses it and that the selftest covers the cases. Run: python tests/test_modidtop0712.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
mods = open(os.path.join(ROOT, "launcher", "Mods.cs"), encoding="utf-8").read().replace("\r\n", "\n")
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


scan = mods[mods.index("static Dictionary<string, string> Scan()"):]
scan = scan[:scan.index("return map;")]
check("if (File.Exists(mj)) id = TopModId(File.ReadAllText(mj));" in scan and "ModIdRx.Match" not in scan,
      "the mods' scan knows a mod by its top level's modId")
check("id = id ?? Path.GetFileName(d);" in scan, "  none there: the folder's name, as before")
fn = mods[mods.index("internal static string TopModId(string json)"):]
fn = fn[:fn.index("static int JsonStrEnd")]
check('Environment.GetEnvironmentVariable("MPFEVER_MODIDTOP") == "0"' in fn and "ModIdRx.Match(json)" in fn, "MPFEVER_MODIDTOP=0: the first one, as before")
check("depth == 1" in fn and "JsonStrEnd" in fn, "  the top level only, texts read whole (a brace or a key inside a text counts for nothing)")
check("ok &= RunModIdTop0712();" in st, "the selftest runs the function")
t = st[st.index("static bool RunModIdTop0712()"):]
t = t[:t.index("return ok;")]
check('"mw_br189"' in t and '"mw_basis"' in t and "MPFEVER_MODIDTOP" in t, "  with BR189's mod.json (its dependency first) and the switch")
check(t.count("C(") >= 7, "  and the other cases (id only, the game's mods, a text, none at the top level, no JSON)")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
