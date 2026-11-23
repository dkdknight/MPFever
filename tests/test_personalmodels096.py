"""Offline test of #471 (0.9.6, launcher/Mods.cs WorldResources / WithWorld / MayLeaveOut, LoadPlan, RiskyPlan, Compare,
Describe; launcher/MainForm.cs "modpersonal"; mod/mpfever_1/content/mpfever_menu.lua).

#471 (2026-11-22, fritz client of privat5990, 0.9.5): fritz took all 13 of the host's mods for personal (the menu's "Play without
it"), vehicle packs among them. His game loaded the host's game without them; when the host bought a vehicle of one of them, his
game stopped: "ResTypeRep<ModelAsset,int>::Get ... 4539 >= 4537" (the host's game knew 4968 models). MPFever only warned
("it may desynchronise the game"; 0.7.11 for kind assets). Now a host's mod whose things its world uses (models, a train's
configuration, constructions...) is never left out of a player's game: the host says so in its list (a 9th field "res"), the
launcher refuses to take it for personal and ignores an older choice, the menu shows no "play without it" for it; from a host
before 0.9.6 (no 9th field), kinds assets and load count. MPFEVER_PERSONALMODELS=0: as before.

Part 1 models the load plan with #471's list (the host's list as fritz's game had it in session_mods.txt): the old rule leaves the
vehicle packs out (the crash), the new one keeps them needed (the join stops at "missing mods" instead). Part 2 checks the sources.
The launcher's self-test (RunPersonalModels096) runs the real code on mods made on the spot.
Run: python tests/test_personalmodels096.py
"""
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


# ---- part 1: #471's list. id, kind (field 5), personal (field 6) as fritz's game had it; res: whether the folder holds models
# (the four vehicle and cargo packs below do; Auto Road Upgrade is a script)
HOST = [
    ("unlocker_achivements", "assets", "auto", "0"),
    ("diesimufreunde_auto_road_upgrade", "sim", "", "0"),
    ("mr_sia_uh60", "load", "", "1"),
    ("mvgfan_dlh_a220", "assets", "", "1"),
    ("ra_fs_gr640", "assets", "", "1"),
    ("mcmw_cont_asset", "load", "", "1"),
    ("mw_trailer_addon", "load", "", "1"),
]
FORCED = {h[0] for h in HOST if h[2] == ""}  # fritz took every one for personal by hand
INSTALLED = set()  # none of them installed on fritz's PC


def with_world(kind, res):
    return res == "1" or (res == "" and kind in ("assets", "load"))


def load_plan(new_rule, send_res=True):
    drops = []
    for mid, kind, p, res in HOST:
        res = res if send_res else ""
        personal = p != "" or mid in FORCED
        if new_rule:
            personal = personal and (p == "auto" or not with_world(kind, res))
        if personal and mid not in INSTALLED:
            drops.append(mid)
    return drops


old = load_plan(False)
new = load_plan(True)
models_dropped_old = [m for m in old if dict((h[0], h[3]) for h in HOST)[m] == "1"]
check(len(models_dropped_old) == 5, "repro #471: the old rule leaves 5 packs with models out of fritz's game (the host's vehicles crash it)")
check(not [m for m in new if dict((h[0], h[3]) for h in HOST)[m] == "1"], "fix: none of them is left out any more (needed: 'missing mods' before the load)")
check("diesimufreunde_auto_road_upgrade" in new and "unlocker_achivements" in new, "  the script and the host's interface mod still may be (as before)")
old_host = load_plan(True, send_res=False)
check(not [m for m in old_host if m in ("mvgfan_dlh_a220", "ra_fs_gr640", "mr_sia_uh60", "mcmw_cont_asset", "mw_trailer_addon")],
      "  a host before 0.9.6 (no res field): kinds assets and load kept as well")

# ---- part 2: the sources
mods = read("launcher", "Mods.cs")
mf = read("launcher", "MainForm.cs")
menu = read("mod", "mpfever_1", "content", "mpfever_menu.lua")
st = read("launcher", "SelfTest.cs")

check("public static string WorldResources(string dir)" in mods, "Mods.WorldResources: the first file the world can use")
wr = mods[mods.index("public static string WorldResources(string dir)"):][:2600]
check('"archives\\"\\\\s*:' in wr or "archives of content" in wr, "  archives of content count (fails closed)")
check("InertExt.Contains(ext)" in wr and "WorldLua(name)" in wr and "WorldResDir.IsMatch" in wr, "  images and texts never, Lua by its name or folder, any other file counts")
check('e.Res == "1" || (e.Res == "" && (e.Kind == Assets || e.Kind == Load))' in mods, "Mods.WithWorld: the host's word, else kinds assets/load")
check('e.P == "auto" || Environment.GetEnvironmentVariable("MPFEVER_PERSONALMODELS") == "0" || !WithWorld(e)' in mods, "Mods.MayLeaveOut, switch MPFEVER_PERSONALMODELS=0")
lp = mods[mods.index("public static string LoadPlan(string hostList)"):][:1200]
check('bool personal = (e.P != "" || Forced.Contains(e.Id)) && MayLeaveOut(e);' in lp, "LoadPlan: such a mod never dropped")
rp = mods[mods.index("public static List<string> RiskyPlan(string hostList)"):][:1200]
check('bool personal = (e.P != "" || Forced.Contains(e.Id)) && MayLeaveOut(e);' in rp, "RiskyPlan: the same rule")
cp = mods[mods.index("public static Check Compare(string hostList, bool isHost)"):][:2800]
check("bool leaveOut = MayLeaveOut(e);" in cp and 'Forced.Contains(e.Id) && leaveOut ? "mine"' in cp, "Compare: needed here (counted missing), not 'mine'")
check('fix, leaveOut ? "0" : "1"));' in cp, "  the menu's 12th field: no 'play without it'")
ds = mods[mods.index("public static string Describe(string list)"):][:1600]
check('WorldResources(dir) != "" ? "1" : "0"' in ds and "p, hub, size, res);" in ds, "Describe: the host sends the 9th field")
check('Res = f.Length > 8 ? f[8].Trim() : ""' in mods, "Parse: the 9th field read (empty from an older host)")
mp = mf[mf.index('else if (cmd == "modpersonal" || cmd == "modmine")'):][:4000]
check('if (hm != null && !Mods.MayLeaveOut(hm))' in mp and mp.index("!Mods.MayLeaveOut(hm)") < mp.index("Mods.Forced.Add(id)"),
      "MainForm: taking such a mod for personal refused before it is kept")
text = "{0} adds vehicles, buildings or objects the host's game uses: MPFever cannot leave it out, your game would crash as soon as one of them is used. Install it."
check(text in mp, "  the player told why")
lang = json.load(open(os.path.join(ROOT, "launcher", "lang.json"), encoding="utf-8-sig"))["texts"]
codes = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
check(text in lang and all("{0}" in lang[text].get(c, "") for c in codes), "  in every language, with its place")
check('needed = f[12] or ""' in menu and 'not isHost and m.needed ~= "1" then' in menu, "menu: no 'play without it' for such a mod")
check("ok &= RunPersonalModels096();" in st and "static bool RunPersonalModels096()" in st, "launcher self-test RunPersonalModels096 registered")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
