"""Offline test: a player who arrives during a resynchronisation, before its game is saved, gets that one and no second whole
one right after (0.9.2, issue #440; MainForm.JoinOnce, SetJoinPending, ClearJoinPending).

The bug (#440, a dedicated server, 2026-11-19): berni1212 joined, "Resynchronisation #1 (new player)" started at 19:07:10; Andy
joined 9 s later, while the server was still saving: JoinDuringResync answered "pending" (no game to send yet), joinPending was
set. At 19:07:20 the resynchronisation listed its games, Andy among them: he was sent the game and loaded it. Once it was over
the server's loop saw joinPending and started "Resynchronisation #2 (new player)": every game reloaded again and berni1212
received the 118 MB a second time at 0.5 MB/s, 4.5 minutes more for everybody.
Now the names that set joinPending are kept; the resynchronisation that lists them takes them out, and clears joinPending
when nobody is left. A player not listed (still looking at the mods, or gone) still gets one of their own. MPFEVER_JOINONCE=0:
as before. The launcher's self-test checks JoinOnce itself.
Run: python tests/test_joinonce092.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


# the timeline of #440, by the rules (a model of the host's loop: pending -> a resynchronisation after the one under way)
def run(fix):
    pending, pend_for, resyncs = False, set(), 0
    # 19:07:10 berni1212's arrival: the loop starts resynchronisation 1 (joinPending cleared)
    resyncs += 1
    # 19:07:19 Andy's joinready, the game not saved yet: "pending"
    pending = True; pend_for.add("Andy#3")
    # 19:07:20 the resynchronisation lists its games
    listed = ["berni1212#1", "Andy#3"]
    if fix and pending and pend_for:
        pend_for -= set(listed)
        if not pend_for:
            pending = False
    # 19:11:57 it is over: the loop looks at joinPending
    if pending:
        resyncs += 1
    return resyncs


check(run(False) == 2, "the bug (rules of 0.9.1): two whole resynchronisations for one arrival during the first")
check(run(True) == 1, "the fix: one")

check("readonly HashSet<string> joinPendingFor = new HashSet<string>();" in mf
      and "void SetJoinPending(string name) { lock (joinPendingFor) { joinPending = true; if (name != null) joinPendingFor.Add(name); } }" in mf
      and "void ClearJoinPending() { lock (joinPendingFor) { joinPending = false; joinPendingFor.Clear(); } }" in mf,
      "the names that set joinPending kept with it, under one lock")
check(len(re.findall(r"\bjoinPending = true;", mf)) == 1, "every arrival sets it with its name (joinPending = true only in SetJoinPending)")
check(mf.count("SetJoinPending(") == 4, "  the three places (welcome, joinready during a resynchronisation, resync_have of another game) and its definition")
check(len(re.findall(r"\bjoinPending = false;", mf)) == 2, "  cleared with its names everywhere (ClearJoinPending), but in the helper and the JoinOnce case")

j = mf.index("if (JoinOnce(joinPending, joinPendingFor, all))")
check(mf.rfind("var all = relay?.PeerNames()", 0, j) > 0 and mf.index("var viaDelta = DeltaPeers(all);") > j,
      "the resynchronisation takes its listed games out, once they are listed and before they are sent the game")
check('Environment.GetEnvironmentVariable("MPFEVER_JOINONCE") != "0"' in mf[j - 400:j], "  MPFEVER_JOINONCE=0: as before")
jo = mf[mf.index("internal static bool JoinOnce("):]
jo = jo[:jo.index("\n        }\n")]
check("if (!pending || pendingFor.Count == 0) return false;" in jo and "pendingFor.RemoveWhere(n => l.Contains(n));" in jo
      and "return pendingFor.Count == 0;" in jo, "JoinOnce: nothing pending or no name -> as before; else true when nobody is left")
check("MainForm.JoinOnce(true, jp, new[] { \"berni1212#1\", \"Andy#3\" })" in st, "the launcher's self-test runs JoinOnce on #440's case")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
