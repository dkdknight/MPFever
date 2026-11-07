"""Offline test of the 0.7.4 fixes for a player joining a dedicated server (the user's server, 2026-11-06 23:13-23:20, dickj):

  1. RESYNCLEFT: a player gone during a resynchronisation was waited for until its end (600 s, every game frozen): relay.Left
     removed it from the games waited for only in the lobby. Now a player not back within 20 s is no longer waited for
     (MainForm.DropDeparted, checked by MPFever.exe --selftest; MPFEVER_RESYNCLEFT=0: as before).
  2. RECONNECTOLD: a connection replaced by a newer one started a reconnection of its own, which replaced the newer one... a new
     connection every 5 s for two minutes. Now a superseded connection does not reconnect, one reconnection at a time
     (MPFEVER_RECONNECTOLD=1: as before).
  3. BUSYCUT: a player's MPFever handling a message (putting the host's 82 MB game together) read nothing for more than 15 s and
     cut itself: no silence cut while a message is handled, the silence counts from its end (MPFEVER_BUSYCUT=1: as before).
  4. MODRETRY: a dedicated server whose world needs a published mod the game does not see yet (mod.io updating it) gave up at
     once; it starts its game again after 30 s, three times (MPFEVER_MODRETRY=0: as before).
The logic of 1, 3 and 4 is run by the launcher's self-test; this checks that the launcher uses it where it must.
Run: python tests/test_serverjoin074.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
main = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read()
core = open(os.path.join(L, "Core.cs"), encoding="utf-8-sig").read()
selftest = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
changelog = open(os.path.join(HERE, "..", "docs", "CHANGELOG.txt"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


left = main[main.index("relay.Left += p =>"):main.index("relay.Grace = SessionLink.Grace;")]
check('if (!lobbyStarting && resyncing && Environment.GetEnvironmentVariable("MPFEVER_RESYNCLEFT") != "0")' in left
      and "DropDeparted(resyncWaiting, gone, r?.PeerNames() ?? new string[0])" in left and "Thread.Sleep(ResyncLeftSeconds * 1000)" in left,
      "1. a player gone during a resynchronisation: dropped from the games waited for after 20 s unless back")
check("internal const int ResyncLeftSeconds = 20;" in main, "1. 20 s to come back")
closed = main[main.index("client.Closed += () =>"):main.index('Name = "Reconnect" }.Start();')]
check('bool superseded = current != null && current != client;' in closed and "if (!oldWay && superseded)" in closed
      and closed.index("bool superseded") < closed.index("if (current == client) current = null;"),
      "2. a superseded connection (read before current is cleared) does not reconnect")
check("Interlocked.CompareExchange(ref reconnecting, 1, 0) != 0" in closed and "Interlocked.Exchange(ref reconnecting, 0);" in closed,
      "2. one reconnection at a time")
check('Environment.GetEnvironmentVariable("MPFEVER_RECONNECTOLD") == "1"' in closed, "2. MPFEVER_RECONNECTOLD=1: as before")
read = core[core.index("void ReadLoop()"):core.index("static int connections;")]
check("Interlocked.Exchange(ref handlingSince, DateTime.UtcNow.Ticks);" in read and "try { Received?.Invoke(m); }" in read
      and "Interlocked.Exchange(ref lastRecvTicks, DateTime.UtcNow.Ticks);" in read.split("try { Received?.Invoke(m); }")[1],
      "3. the message handled is marked, the silence counts from the end of its handling")
loop = core[core.index("void LinkLoop()", core.index("static int connections;")):]
check("if (BusyHolds(Interlocked.Read(ref handlingSince))) continue;" in loop[:3000], "3. no silence cut while a message is handled")
cmm = main[main.index("void CheckMissingMods()"):main.index("/// <summary>Writes the state shown by the game's MPFever window.</summary>")]
check("if (ServerModRetry(ServerMode, anyLocal, serverModRetries))" in cmm and "restartRequested = true; menuGame.Kill();" in cmm
      and cmm.index("ServerModRetry(") < cmm.index("EndSession("), "4. a server tries its world again before ending the session")
check("if (m.From == hostName) serverModRetries = 0;" in main, "4. the tries counted again once the world is loaded")
check("ok &= RunServerJoin074();" in selftest, "the launcher's self-test runs the logic")
top = changelog.split("\n0.7.3 - ")[0]
check(all(k in top for k in ("MPFEVER_RESYNCLEFT", "MPFEVER_RECONNECTOLD", "MPFEVER_BUSYCUT", "MPFEVER_MODRETRY")), "the changelog of 0.7.4 names the four switches")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
