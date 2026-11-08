"""Offline test: a player's problem report says who plays and whether the game runs, and names an unknown game build (0.7.7,
SessionLines / NoteFromHost in launcher/MainForm.cs, Reporter.GameBuild / BuildInLog in launcher/Reporter.cs).

The user's report (2026-11-07 23:43) and issue #135's (2026-11-08 00:46), both players' in a running game: "Players: -; game
running: no". A player's launcher has no lobby of its own (players, started are the host's): it now takes them from the host's
messages, the names they come with and the "started" of its "session" messages, cleared at every new session
(MPFEVER_REPORTCLIENT=0: as before). #135's game was a GOG copy, build 40393: "game build unknown build (6ab3eec7)"; the report
now adds the build the game's log names at its start and whether Steam installed the game (MPFEVER_REPORTBUILD=0: as before).
The launcher's self-test (RunReport077) runs SessionStarted, NotesPeer, HostRunningText and BuildInLog on real text.
Run: python tests/test_report077.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
rep = open(os.path.join(L, "Reporter.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


s = mf[mf.index("string SessionLines(bool joining)"):]
s = s[:s.index("\n        }\n")]
check('if (server == null && hostGame == null && (clients.Count > 0 || joining) && Environment.GetEnvironmentVariable("MPFEVER_REPORTCLIENT") != "0")' in s,
      "a player's report (not the host's, not a server's) takes the session from the host's messages")
check("lock (clientPeers) ready = clientPeers.OrderBy" in s and "running = HostRunningText(hostStartedSeen);" in s, "  the players and the game's state")
check('"; game running: " + running' in s, "  written in the same line as before")
n = mf[mf.index("void NoteFromHost(Msg m, string me)"):]
n = n[:n.index("\n        }\n")]
check("hostStartedSeen = s.Value ? 1 : 0" in n and "clientPeers.Add(BaseName(m.From));" in n, "NoteFromHost: started, and the names")
check("try { NoteFromHost(m, name); } catch { }" in mf, "  every message from the host goes through it")
sc = mf[mf.index("void StartClient(string name, string host, int port, bool launch"):]
check(sc.find("lock (clientPeers) clientPeers.Clear();") < sc.find("Client current = null;") and "hostStartedSeen = -1;" in sc[:800],
      "  cleared at every new session")
g = rep[rep.index("public static string GameBuild(string gameDir)"):]
g = g[:g.index("internal static string BuildInLog")]
check('if (known == "unknown build") { var n = BuildInLog(GameLog());' in g and 'if (GameInstall.NotSteamCopy(gameDir)) extra += ", NOT a Steam copy (GOG or another store)";' in g,
      "an unknown build: the build its log names, and whether Steam installed it")
check('Environment.GetEnvironmentVariable("MPFEVER_REPORTBUILD") != "0"' in g, "  MPFEVER_REPORTBUILD=0: as before")
check('Regex.Match(line, @"Starting up build version: (\\d+)")' in rep and "FileShare.ReadWrite | FileShare.Delete" in rep,
      "BuildInLog: the game's own line, read while the game writes its log")
check("ok &= RunReport077();" in st and "Reporter.BuildInLog(f) == \"40393\"" in st and "MainForm.SessionStarted(" in st,
      "the launcher's self-test runs them on real text")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
