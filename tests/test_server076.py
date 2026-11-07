"""Offline test of the 0.7.6 fixes for the dedicated server (the user's server, 2026-11-07 20:02-20:10, 0.7.5):

  1. RESYNCLEFTNAME: chris joined (a resynchronisation), left while the game was on its way (chris#10), came back 17 s later
     as chris#12 (so chris#10 stayed waited for) and left again: relay.Left looked for "chris#12" in the games waited for, found
     nothing and never dropped chris#10: every game stood 600 s. Now a player gone is found there under any of its connections'
     names (MainForm.WaitedFor; MPFEVER_RESYNCLEFTNAME=0: this name only, as before).
  2. JOINMIDRESYNC: chris#12 finished its look at the mods and DLCs (20:03:16) while the game was being sent to the others: it
     got nothing, and nothing was left to do for it afterwards. Now it gets the game being sent and is waited for in the place of
     its old connection; once that wait is over, a resynchronisation of its own afterwards (MainForm.JoinDuringResync;
     MPFEVER_JOINMIDRESYNC=0: as before).
  3. STOPRESYNC: "restart" (20:07:59) and "stop" (20:09:28) only wrote their message: the world's save waited behind the stuck
     resynchronisation, up to 600 s, and said nothing; the server was closed by hand and started again from an older save. A stop
     or a restart now cuts a resynchronisation short (it waits for nobody any more, ends within seconds), says so, then saves
     (MPFEVER_STOPRESYNC=0: as before). The console's "resync" says a resynchronisation is under way instead of "no player to
     resynchronise" (MPFEVER_RESYNCMSGOLD=1: as before).
The logic is run by the launcher's self-test (MPFever.exe --selftest, RunServer076); this checks that the launcher uses it.
Run: python tests/test_server076.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
main = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
server = open(os.path.join(L, "Server.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
selftest = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


left = main[main.index("relay.Left += p =>"):main.index("relay.Grace = SessionLink.Grace;")]
check('waited = WaitedFor(resyncWaiting, p.Name, Environment.GetEnvironmentVariable("MPFEVER_RESYNCLEFTNAME") == "0");' in left,
      "1. a player gone: its wait found under any of its connections' names")
check("internal static bool WaitedFor(HashSet<string> waiting, string name, bool exact)" in main, "1. MainForm.WaitedFor")
jr = main[main.index('case "joinready":'):main.index('case "resync_have":')]
check('JoinDuringResync(resyncing, bytesNow != null, resyncSending, resyncBytesId, saveCancel,' in jr
      and 'Environment.GetEnvironmentVariable("MPFEVER_JOINMIDRESYNC") == "0"' in jr, "2. a player joining during a resynchronisation: decided by JoinDuringResync")
check('if (jd == "pending") joinPending = true;' in jr and "SendSave(resyncBytesId, bytesNow," in jr
      and "resyncWaiting.RemoveWhere(w => BaseName(w) == BaseName(from.Name)); resyncWaiting.Add(from.Name);" in jr,
      "2. it gets the game being sent, waited for in the place of its old connection")
rl = main[main.index("void ResyncLocked(string reason)"):main.index("void SendSave(int id, byte[] bytes, string sha, IEnumerable<string> names)")]
check(rl.index("resyncAbort = false;") < rl.index("Pause(T(\"resynchronisation\""), "3. each resynchronisation starts uncut")
check("bool back = WaitUntil(() => { if (resyncAbort) return true; lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);" in rl,
      "3. its wait for the players ends when the server stops or restarts")
rw = server[server.index("void RestartWorld()"):server.index("void StopServer(bool closeWindow)")]
ss = server[server.index("void StopServer(bool closeWindow)"):server.index("double updateEmptySince")]
check(rw.index('CutResyncShort(T("redémarrage", "restart"));') < rw.index("SaveWorld("), "3. restart: the resynchronisation cut short, then the save")
check(ss.index('CutResyncShort(T("arrêt", "stop"));') < ss.index("SaveWorld("), "3. stop: the resynchronisation cut short, then the save")
cr = server[server.index("void CutResyncShort(string why)"):]
check('StopCutsResync(resyncing, Environment.GetEnvironmentVariable("MPFEVER_STOPRESYNC") == "0")' in cr[:400] and "resyncAbort = true;" in cr[:500],
      "3. MPFEVER_STOPRESYNC=0: as before")
con = server[server.index('case "resync":'):server.index('case "restart": case "reload":')]
check(con.index("Une resynchronisation est déjà en cours.") < con.index("Pas de joueur à resynchroniser."), "3. the console says a resynchronisation is under way")
check("ok &= RunServer076();" in selftest and "static bool RunServer076()" in selftest, "the launcher's self-test runs the logic")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
