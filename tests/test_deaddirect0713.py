"""Test of #164/#165's fix (0.7.13, launcher/Core.cs, Client.Connect / Client.ReadLoop / NetAddr.WithoutDead).

Hansen (host) and ChristianHansen, 2026-11-08 21:17-21:26: the host behind CGNAT and a router that answers its own public
address from inside. The player's direct connection to the host's address "connected" at once but nothing of the host came
through it; the Steam tunnel opened at the same time (and working) was let go for it ("closed before joining the session, Steam
tunnel open, no join request"), the connection was lost after 19 s, again and again.
Now a direct address through which nothing of the host came, the player not leaving (Dispose sets stop first), is left out of
the next joins of this run while Steam can carry the session; without Steam, every address is tried as before.
MPFEVER_DEADDIRECT=0: as before. NetAddr.WithoutDead itself runs in the selftest (SelfTest.RunDeadDirect0713).
Run: python tests/test_deaddirect0713.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
core = open(os.path.join(ROOT, "launcher", "Core.cs"), encoding="utf-8").read().replace("\r\n", "\n")
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check('internal static bool DeadDirectOn() => Environment.GetEnvironmentVariable("MPFEVER_DEADDIRECT") != "0";' in core, "MPFEVER_DEADDIRECT=0: as before")
con = core[core.index("public void Connect(string host, int port, string name"):]
con = con[:con.index("/// <summary>The first address of the list that answers")]
i_trysteam = con.index("else\n            {\n                // (0.7.13, see deadDirect)")
check(con.index("if (!trySteam)") < i_trysteam, "only when Steam can carry the session (without Steam every address is tried)")
check("plain = NetAddr.WithoutDead(plain, port, deadDirect, dropped);" in con, "  the dead addresses left out of the direct attempts")
check(con.index("usedDirect = viaSteam ? null : used;") < con.index("new Thread(ReadLoop)") and con.index("gotAny = false;") < con.index("new Thread(ReadLoop)"),
      "the address used and 'nothing yet' set before the reading starts")
rl = core[core.index("        void ReadLoop()\n"):]
rl = rl[:rl.index("static readonly HashSet<string> deadDirect")]
check(rl.index("gotAny = true;") < rl.index('if (m.Kind == "~ack")'), "anything of the host counts (its acks too)")
check("bool leftHere = stop;" in rl and rl.index("bool leftHere = stop;") < rl.index("stop = true;\n            // (0.7.13"),
      "  the player leaving (Dispose sets stop first) marks nothing")
check("if (!gotAny && !leftHere && usedDirect != null && DeadDirectOn())" in rl and "deadDirect.Add(usedDirect)" in rl,
      "a direct connection cut before anything came: its address marked")
check("ok &= RunDeadDirect0713();" in st and "NetAddr.WithoutDead(" in st[st.index("static bool RunDeadDirect0713()"):], "the selftest runs NetAddr.WithoutDead")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
