"""Offline test: a resynchronisation waits for the players who are joining (0.7.3, MPFEVER_WAITJOINERS=0: as before).

The user's dedicated server, 2026-11-06 20:44 and 20:46: Roman checked the mods and joined ("il rejoint la partie"), a
resynchronisation started for him, the host's game was sent to Knight-HD2 (already playing) and to Roman, but the launcher only
waited for the games already in the session (players: the games that said "hello" in the server's world). It was done in 35 s,
the game still on its way to Roman was cancelled half sent, he never loaded it and left; the same again at his next try. Now the
players the game is sent to who are not playing yet are waited for too, until their game says it is ready (or the 600 s limit).
Checked in the launcher's source (the rule sits in the middle of the resynchronisation, between the list of players and the wait).
Run: python tests/test_waitjoiners.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = SRC.index("void ResyncLocked(string reason)")
body = SRC[i:SRC.index("void SendSave(int id, byte[] bytes", i)]
a = body.find("lock (reviewing) all = all.Where(n => !reviewing.Contains(n)).ToArray();")
b = body.find('string[] joining; lock (players) joining = all.Where(n => !players.Contains(n)).ToArray();')
c = body.find("lock (resyncWaiting) foreach (var n in joining) resyncWaiting.Add(n);")
d = body.find("bool back = WaitUntil(() => { lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);")
check(a > 0 and b > a, "the joining players are those the game is sent to who are not playing yet")
check(c > b and d > c, "they are added to the players waited for, before the wait")
check('Environment.GetEnvironmentVariable("MPFEVER_WAITJOINERS") != "0"' in body, "MPFEVER_WAITJOINERS=0: as before")
h = SRC.index('case "hello":')
check("resyncWaiting.RemoveWhere(w => w == m.From || BaseName(w) == BaseName(m.From));" in SRC[h:h + 1500],
      "a joining player's game saying it is ready ends its wait (by its name without the number)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
