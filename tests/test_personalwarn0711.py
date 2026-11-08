"""Offline test of #151's warning (0.7.11, launcher/MainForm.cs, the menu's "modpersonal" request).

tsuhr (2026-11-08) took 9 of the host's mods for personal, vehicle and aircraft packs among them; the game loaded the host's
game without them and stopped right after on a model it could not find (the game's own code, UI::CMenuUI::StartGame, model id
-1). Taking for personal a mod of objects (kind "assets") that the host's game uses now says so plainly: the game may crash,
install it instead. Other mods (interface, scripts) taken for personal: as before. MPFEVER_PERSONALWARN=0: not said.
Run: python tests/test_personalwarn0711.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


mp = mf[mf.index('else if (cmd == "modpersonal" || cmd == "modmine")'):][:3500]
check('if (cmd == "modpersonal" && on && Environment.GetEnvironmentVariable("MPFEVER_PERSONALWARN") != "0")' in mp,
      "only when a mod is taken for personal (MPFEVER_PERSONALWARN=0: not said)")
check("Mods.Parse(lobbyMods).FirstOrDefault(x => string.Equals(x.Id, id, StringComparison.OrdinalIgnoreCase))" in mp
      and "me.Kind == Mods.Assets" in mp, "  a mod of objects the host's game uses (its list), not the others")
check(mp.index("SavePersonalMods();") < mp.index("MPFEVER_PERSONALWARN"), "  the choice itself kept as before (a warning, never a refusal)")
check("Install it rather than take it for personal." in mp, "  says to install it")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
