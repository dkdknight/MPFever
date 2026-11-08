"""Offline test: a player whose game build is not the host's is warned, like for the DLCs, never refused (0.7.7,
CheckHostBuild / BuildWarning / "buildcheck" in launcher/MainForm.cs, Reporter.BuildTag).

Issue #135 (tilwegener, 2026-11-08): a GOG copy, build 40393, played with a host on another build; the games reloaded every 3 to
5 minutes and the player thought building was broken. Two builds do not simulate the game alike. The user's choice: do not
block the players, warn them as for the DLCs:
  - the host tells its build in its lobby and its welcome ("gbuild": stamp|number|store, Reporter.BuildTag);
  - a player compares it with its own: a warning in its lobby, its join review (the page opens for it, as for the DLCs) and its
    reports; it tells its own build to the host (buildcheck), which shows the players' warnings in its lobby;
  - a dedicated server takes buildcheck from a player not in yet, like dlccheck;
  - never a refusal; MPFEVER_BUILDWARN=0: nothing, as before.
The launcher's self-test (RunReport077) runs BuildWarning.
Run: python tests/test_buildwarn077.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
# (0.7.9: the report's text moved to ReportShare.cs)
mf += open(os.path.join(L, "ReportShare.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
rep = open(os.path.join(L, "Reporter.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check(mf.count('",[\\"gbuild\\"]=" + LuaLit.Quote(Reporter.BuildTag(gameDir))') == 3, "the host tells its build: lobby and both welcomes")
check('CheckHostBuild(S("gbuild"), client, name);' in mf and 'CheckHostBuild(gbs0, client, name);' in mf, "a player compares it, from the lobby and the welcome")
c = mf[mf.index("void CheckHostBuild(string hostTag, Client client, string name)"):]
c = c[:c.index("\n        }\n")]
check('Environment.GetEnvironmentVariable("MPFEVER_BUILDWARN") == "0"' in c and 'Msg.Make("buildcheck"' in c, "  and tells its own (MPFEVER_BUILDWARN=0: nothing)")
check('["dlcWarn"] = (lobbyOpen || hostGame != null) ? HostDlcWarn() : PlayerDlcWarn(),' in mf, "shown in the lobby's warning box")
check("return mods && string.IsNullOrEmpty(PlayerDlcWarn());" in mf, "  the join review opens for it")
check('(PlayerDlcWarn() != "" ? " | " + PlayerDlcWarn() : "")' in mf, "  and the report says it")
h = mf[mf.index('case "buildcheck":'):]
h = h[:h.index("\n                    break;\n")]
check("BuildWarning(whoB, Reporter.BuildTag(gameDir), theirB)" in h and "BroadcastLobby();" in h, "the host keeps a player's, shows it in its lobby")
check('m.Kind != "dlccheck" && m.Kind != "buildcheck")' in mf, "  a dedicated server takes it before the player is in")
check("string b; lock (buildIssues) b = string.Join(\" \", buildIssues.Values);" in mf, "  with the DLC warnings")
check("refus" not in mf[mf.index("internal static string BuildWarning("):mf.index("internal static string BuildWarning(") + 1500].lower(),
      "never a refusal")
b = rep[rep.index("internal static string BuildTag(string gameDir)"):]
b = b[:b.index("\n        }\n")]
check('stamp.ToString("x8") + "|" + (known ?? BuildInLog(GameLog()) ?? "?") + "|" + (GameInstall.NotSteamCopy(gameDir) ? "other" : "steam")' in b,
      "BuildTag: the exe's stamp, its number, its store")
check("ok" if "MainForm.BuildWarning(null, \"6ad9ce10|40425|steam\", \"6ab3eec7|40393|other\")" in st else "", "the launcher's self-test runs BuildWarning")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
