"""Offline test (0.8.16, #385): a game running a native module older than its mod is told, and the host says it to everyone.

CowboyPilot's session (#385, 0.8.15, one company per player): MPFever updated itself while the game was open; the game's
winhttp.dll could not be replaced ("close Transport Fever 3, then restart MPFever", in the launcher's log only) and the host's
game went on with the old native module: no shared maintenance there, while FlungPooPanda's game had it, so the vehicles drifted
every 3 minutes (5 resyncs). Now:
  - the native module knows its release's version (MPF_VERSION from build.bat) and writes it first in native_fx.txt;
  - the mod reads it; a running module ("on") with another version, or none (a module before 0.8.16), is old: said in this
    game's chat and sent in the hello (natold, natver); MPFEVER_NATVERCHECK=0: not checked;
  - the host says it in the session's chat, once per player (MainForm.NativeOldProblem, launcher selftest).
Run: python tests/test_natold0816.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
R = lambda *p: open(os.path.join(HERE, "..", *p), encoding="utf-8-sig").read().replace("\r\n", "\n")
nat, nb = R("native", "mpfever_native.cpp"), R("native", "build.bat")
br, mc, st = R("mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), R("launcher", "ModCopies.cs"), R("launcher", "SelfTest.cs")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check('/DMPF_VERSION=\\"%VERSION%\\"' in nb, "build.bat gives the module its release's version")
check('f.str("version=").str(MPF_VERSION);' in nat, "the module writes its version first in native_fx.txt")
check('natver = t:match("^version=([^%s]+)")' in br, "the mod reads it")
check('local natold = nat == "on" and natver ~= C.MODVERSION and os.getenv("MPFEVER_NATVERCHECK") ~= "0"' in br,
      "a running module of another version (or none) is old; MPFEVER_NATVERCHECK=0: not checked")
check("pcall(G.featChat, C.T(\"Ce jeu tourne avec l'ancien module natif" in br, "  said in this game's chat")
check("natver = natver, natold = natold or nil })" in br, "  and sent in the hello")
check('h.TryGetValue("natold", out var old) && old is bool ob && ob' in mc and 'nativeFxWarned.Add("old|"' in mc, "the host says it once per player")
check('MainForm.NativeOldProblem("Cowboy", null)' in st, "the launcher's selftest checks the text")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
