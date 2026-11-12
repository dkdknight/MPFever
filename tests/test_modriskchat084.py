"""Offline test: a player's game that runs without (or with) mods taken for personal by hand tells every player in the chat
(0.8.4, issues #233 #251, the user's choice: warn everybody, MPFEVER_MODRISKCHAT).

#233/#251 (Flubixx host, Richard): from 18:35 Richard's game ran without "DB Class 430" (a vehicle mod with a game script; the
lobby's personal mods: "drop db_class_430_neu"), the host's with it: the games drifted apart, and nobody was told but the
player who took the mod for personal. A mod found personal by its files (Mods.Personal: the interface only) is left out
without a word, as before. launcher/Mods.cs and MainForm.cs are read.
Run: python tests/test_modriskchat084.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
mods = open(os.path.join(HERE, "..", "launcher", "Mods.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
mf = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


rp = mods[mods.index("public static List<string> RiskyPlan(string hostList)"):]
rp = rp[:rp.index("\n        }\n")]
check('Environment.GetEnvironmentVariable("MPFEVER_MODRISKCHAT") == "0") return r;' in rp, "MPFEVER_MODRISKCHAT=0: nothing told, as before")
check("bool personal = e.P != \"\" || Forced.Contains(e.Id);\n                if (!personal || IsMine(e.Id)) continue;" in rp,
      "  the host's mods this game leaves out: the same rule as LoadPlan's drops")
check('if (e.P == "forced" || (e.P == "" && Forced.Contains(e.Id))) r.Add("-" + e.Name);' in rp,
      "  told when taken for personal by hand (by the host: forced, or by this player); the host's auto ones (interface only) not")
check('IsMine(id) && Forced.Contains(id) && Info(id).Item3 != "") r.Add("+" + id);' in rp,
      "  this player's own added mods: told only when taken by hand and not found personal by their files")
lp = mods[mods.index("public static string LoadPlan(string hostList)"):]
lp = lp[:lp.index("\n        }\n")]
check('if (personal && !IsMine(e.Id)) lines.Add("drop\\t" + e.Id);' in lp, "LoadPlan itself is unchanged (the drops)")

blk = mf[mf.index("var risky = Mods.RiskyPlan(lobbyMods);"):]
blk = blk[:blk.index("catch (Exception e) { Log.W(\"load_mods: \" + e.Message); }")]
check("if (risky.Count > 0 && riskKey != riskyAnnounced)" in blk and "riskyAnnounced = riskKey;" in blk,
      "the chat warning once per list (the loads of a resynchronisation do not repeat it)")
check('clients.FirstOrDefault()?.Send(Msg.Make("chat", game.Name, "{[\\"text\\"]=" + LuaLit.Quote(warn) + "}"))' in blk,
      "  sent as a chat message: the host numbers it and sends it to every player")
check("this game runs WITHOUT {0} (mods taken for personal by hand)" in blk and "this game runs WITH {0} too" in blk
      and "this game runs WITHOUT {0} and WITH {1} too" in blk, "  the three texts (without, with, both)")
check("joinPending = false; riskyAnnounced = \"\";" in mf, "the told list is forgotten when the session ends")
check(mf.index("var plan = Mods.LoadPlan(lobbyMods);") < mf.index("var risky = Mods.RiskyPlan(lobbyMods);"),
      "told after the load plan is written (the same load)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
