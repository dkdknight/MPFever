"""Offline test: a player's mods taken for personal by hand that change the game are told to every player in the lobby, before the
start (0.8.6, #276; launcher/MainForm.cs SetHostMods, the host's "modcheck" handler, OnPlayerRiskyMods; launcher/Mods.cs RiskyPlan).

#276 (leinl and marce, 2026-11-12): marce ran "Deutsche Signale" (tf3_signale_de_1) taken for personal by hand, the host did not.
The games drifted apart within 23 s, a resynchronisation every 3 to 5 minutes; the only warning was a chat line at the load. The
user's rule: only the mods found personal by their files (the interface alone, Mods.Personal) stay silent; every other personal mod
is told to every player.
  - a player sends its risky personal mods (Mods.RiskyPlan) with its lobby check ("modcheck" risky);
  - the host tells every player in the chat (HostChat) and its log, once per player and list, an empty list says nothing;
  - the three texts (with, without, both) in English and in every language of lang.json;
  - Mods.RiskyPlan keeps the mods found personal by their files silent ("auto"), and tells those taken by hand ("forced");
  - switch MPFEVER_MODRISKLOBBY=0: not sent (the chat at the load only, as before).
Run: python tests/test_modrisklobby086.py
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


def read(n):
    return open(os.path.join(L, n), encoding="utf-8-sig").read().replace("\r\n", "\n")


mf, mods = read("MainForm.cs"), read("Mods.cs")
s = mf[mf.index("void SetHostMods(string mods, Client client, string name)"):]
s = s[:s.index("\n        }\n")]
check("a player sends its risky personal mods with its lobby check", 'string.Join(",", Mods.RiskyPlan(mods))' in s and '",[\\"risky\\"]=" + LuaLit.Quote(riskyLobby)' in s)
check("  switch MPFEVER_MODRISKLOBBY=0", 'GetEnvironmentVariable("MPFEVER_MODRISKLOBBY") != "0"' in s)
h = mf[mf.index('case "modcheck":'):]
h = h[:h.index('case "buildcheck":')]
check("the host's modcheck handler reads them and tells everybody", 'h.TryGetValue("risky"' in h and "OnPlayerRiskyMods(BaseName(from.Name), risky);" in h)
o = mf[mf.index("void OnPlayerRiskyMods(string who, string risky)"):]
o = o[:o.index("\n        }\n")]
check("  once per player and list (riskyTold), nothing for an empty list", "riskyTold.TryGetValue(who, out var was) && was == risky" in o and 'if (risky == "") return;' in o)
check("  in the chat (HostChat) and the host's log", 'HostChat("msg", "MPFever", text)' in o and "Log.Err(text)" in o)
texts = [
    "{0} plays WITH {1}, taken for personal by hand: this mod changes the game, the games will desync. Everybody needs the same mods (or {0} takes it out of their personal mods).",
    "{0} will play WITHOUT {1}, taken for personal by hand: this mod changes the game, the games will desync. Everybody needs the same mods.",
    "{0} will play WITHOUT {1} and WITH {2}, taken for personal by hand: these mods change the game, the games will desync. Everybody needs the same mods.",
]
lang = json.load(open(os.path.join(L, "lang.json"), encoding="utf-8-sig"))["texts"]
codes = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
for t in texts:
    check("  text: " + t[:40], t in o)
    check("    in every language, with its places", t in lang and all("{0}" in lang[t].get(c, "") and "{1}" in lang[t].get(c, "") for c in codes))
r = mods[mods.index("public static List<string> RiskyPlan(string hostList)"):]
r = r[:r.index("\n        }\n")]
check("RiskyPlan: the host's forced ones left out here are told, its auto ones (interface only) are not", 'if (e.P == "forced" || (e.P == "" && Forced.Contains(e.Id))) r.Add("-" + e.Name);' in r)
check("  this player's own: only those taken by hand that are not interface-only", 'IsMine(id) && Forced.Contains(id) && Info(id).Item3 != ""' in r)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
