"""Offline test: the host does not cut a player for silence while it sends it a game, nor right after (0.9.4, issue #449,
MPFEVER_HOSTSILENT; launcher/Core.cs Relay.SilenceLimit, Relay.SilenceSeconds, Relay.LinkLoop; MainForm.SendParts).

The bug (#449, yoyo's session, 2026-11-20): a resynchronisation sent Bence 54.6 MB of differences over four Steam connections,
from 16:26:50 to 16:27:06. The Steam relay was full ("Connection already has 2 MB pending" on the host, fragments dropped on
Bence's side) and nothing of Bence reached the host after about 16:26:55: at 16:27:11 "Bence#6: nothing received for 15 s, connection
cut". A player cut during a resynchronisation is not waited for: Bence came back 3 s later as a new player, his game was restarted
and loaded the whole 449 MB game, two more resynchronisations followed, about 15 minutes for everybody.
The client already gives a host 40 s through Steam (Client.SilentLimit, #115), the host gave a player 15 s whatever the route.
The fix: the host waits as long as the client does (40 s through Steam, 15 s direct), counts the silence from the end of the last
sending of a game to that player, and during one cuts only after 120 s. MPFEVER_HOSTSILENT=0: 15 s, as before.

Part 1 models the two functions as C# runs them (their bodies are checked word for word) on the timeline of #449: the bug with
the switch at 0, the fix, and a player who stays silent still cut. Part 2 checks the wiring (the link loop, SendParts, the
fields) and that the launcher's self-test runs the same timeline through the real functions (MPFever.exe --selftest).
Run: python tests/test_hostsilent094.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
core = open(os.path.join(ROOT, "launcher", "Core.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


# ---- part 1: the rules, as C# runs them
def silent_limit(steam):   # Client.SilentLimit, no MPFEVER_SILENTCUT
    return 40 if steam else 15


def silence_limit(steam, sending, on):
    if not on:
        return 15
    limit = silent_limit(steam)
    return max(limit, 120) if sending else limit


def silence_seconds(now, last_recv, sent_end, on):
    frm = sent_end if on and sent_end > last_recv else last_recv
    return (now - frm) // 1   # whole seconds (ticks / TicksPerSecond)


def cut_at(on, recv, sent_from, sent_end, back=None, steam=True, until=200):
    """The first second (from 16:26:00) the host's watchdog cuts the player, None if never before `until`. The player's last word
    reaches the host at `recv`, then again from `back` on (every 2 s); a game is sent to it from `sent_from` to `sent_end`."""
    last = recv
    for t in range(recv, until):
        if back is not None and t >= back and (t - back) % 2 == 0:
            last = t
        sending = sent_from <= t < sent_end
        end = sent_end if t >= sent_end else 0
        if silence_seconds(t, last, end, on) > silence_limit(steam, sending, on):
            return t
    return None


t = cut_at(False, 55, 50, 66)
check("bug reproduced (MPFEVER_HOSTSILENT=0): Bence cut at 16:27:11, 16 s after his last word, 5 s after the sending", t == 71, t)
t = cut_at(True, 55, 50, 66, back=80)
check("fix: not cut, Bence heard again at 16:27:20 once the relay has carried the sending", t is None, t)
t = cut_at(True, 55, 50, 66)
check("  a player who stays silent is still cut, 41 s after the sending (16:27:47)", t == 107, t)
t = cut_at(True, 55, 50, 66, steam=False)
check("  a direct connection: 15 s after the sending's end (16:27:22)", t == 82, t)
t = cut_at(True, 55, 50, 100000, until=400)
check("  a sending that never ends: cut after 120 s of silence", t == 55 + 121, t)
check("  no sending at all: 40 s through Steam, as the client gives the host", cut_at(True, 10, 0, 0) == 51)

m = re.search(r"internal static int SilenceLimit\(bool steam, bool sending, bool on\)\s*\{(.*?)\n        \}", core, re.S)
check("Relay.SilenceLimit found", m is not None)
if m:
    body = " ".join(m.group(1).split())
    check("  its body is the one modelled", body == "if (!on) return 15; int limit = Client.SilentLimit(steam); "
          "return sending ? Math.Max(limit, SendingSilence) : limit;", body)
m = re.search(r"internal static long SilenceSeconds\(long nowTicks, long lastRecvTicks, long sentEndTicks, bool on\)\s*\{(.*?)\n        \}", core, re.S)
check("Relay.SilenceSeconds found", m is not None)
if m:
    body = " ".join(m.group(1).split())
    check("  its body is the one modelled", body == "long from = on && sentEndTicks > lastRecvTicks ? sentEndTicks : lastRecvTicks; "
          "return (nowTicks - from) / TimeSpan.TicksPerSecond;", body)
check("  120 s during a sending", "internal const int SendingSilence = 120;" in core)
check("  MPFEVER_HOSTSILENT=0 switches it off", 'internal static bool HostSilentOn() => Environment.GetEnvironmentVariable("MPFEVER_HOSTSILENT") != "0";' in core)
check("Client.SilentLimit unchanged (40 s through Steam)", 'return steam && Environment.GetEnvironmentVariable("MPFEVER_STEAMSILENT") != "0" ? 40 : 15;' in core)

# ---- part 2: the wiring
i = core.index("        void LinkLoop()\n        {\n            var told = new Dictionary<Peer, KeyValuePair<long, DateTime>>();")
loop = core[i:core.index("foreach (var q in told.Keys", i)]
check("the host's link loop uses both rules",
      "int limit = SilenceLimit(q.SteamId != null, Volatile.Read(ref q.Sending) > 0, HostSilentOn());" in loop
      and "SilenceSeconds(now.Ticks, Interlocked.Read(ref q.LastRecvTicks), Interlocked.Read(ref q.SentEndTicks), HostSilentOn()) > limit" in loop)
check("  and says the seconds", '"{0}: nothing received for {1} s, connection cut", q.Name, limit' in loop)
check("  no 15 s left in it", "TicksPerSecond > 15" not in loop)
check("the player's fields", "public int Sending;" in core and "public long SentEndTicks;" in core)
i = mf.index("bool SendParts(Peer p, int id, int size, Func<int, Msg> part, out int linksUsed)")
sp = mf[i:mf.index("bool SendPartsCounted(", i)]
check("SendParts counts the sending and notes its end, whatever happens",
      "Interlocked.Increment(ref p.Sending);" in sp and sp.index("Interlocked.Increment(ref p.Sending);") < sp.index("try {")
      and "finally" in sp and sp.index("finally") < sp.index("Interlocked.Exchange(ref p.SentEndTicks, DateTime.UtcNow.Ticks);")
      < sp.index("Interlocked.Decrement(ref p.Sending);"))
check("  the game and the differences both go through it", mf.count("if (!SendParts(p, id,") == 2)
check("the launcher's self-test runs the timeline of #449 through the real functions",
      "Relay.SilenceSeconds(At449(71), recv449, sent449, false) > Relay.SilenceLimit(true, false, false)" in st
      and "Relay.SilenceSeconds(At449(71), recv449, sent449, true) <= Relay.SilenceLimit(true, false, true)" in st
      and "Relay.SilenceSeconds(At449(66 + 41), recv449, sent449, true) > Relay.SilenceLimit(true, false, true)" in st)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
