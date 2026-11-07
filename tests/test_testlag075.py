"""The test-only network delay of a player's connection (0.7.5, launcher/Core.cs, Client.TestLagMs).

Two games on one PC answer each other within a few ms, so the pacing of a real server (the other game's clocks arriving late)
could not be tried: the half speed of the user's server (2026-11-07) never showed on one PC. MPFEVER_TESTLAGMS=<ms> (1 to 2000)
holds this player's session messages, to the host and from it, that long each, in their order, on a thread of their own. It is
for tests only: without the variable nothing is held, the connection is as before.
Run: python tests/test_testlag075.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "launcher", "Core.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check('Environment.GetEnvironmentVariable("MPFEVER_TESTLAGMS")' in src and "tlag > 0 && tlag <= 2000 ? tlag : 0" in src,
      "read from MPFEVER_TESTLAGMS, 1 to 2000 ms, else 0")
i = src.find("public void Send(Msg m)")
send = src[i:src.find("void SendNow(Msg m)", i)]
check("if (TestLagMs > 0 && !SessionLink.IsControl(m.Kind)) { Later(() => SendNow(m)); return; }" in send and "SendNow(m);" in send,
      "a message to the host held only with the variable (and never the link's own control messages)")
r = src.find("// (tests, see TestLagMs: handed on later, in order)")
check(r > 0 and "if (TestLagMs > 0 && !SessionLink.IsControl(m.Kind) && !m.IsBinary)" in src[r - 200:r], "a message from the host held only with the variable (not a file's binary parts)")
check("try { Received?.Invoke(m); }" in src[r:r + 800], "otherwise handed on at once, as before")
l = src.find("void Later(Action a)")
later = src[l:src.find("public void Send(Msg m)", l)]
check("Queue<KeyValuePair<long, Action>>" in src and "lagQ.Dequeue()" in later and "Environment.TickCount + TestLagMs" in later,
      "one queue, in order, each held the same time")
check("IsBackground = true" in later and "while (!stop)" in later, "its thread stops with the connection")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
