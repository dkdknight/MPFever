"""Offline test of how long a client waits for a silent host before it cuts the connection (0.6.8, issue #115).

A player joined through Steam a world of 96 MB that grew to 357 MB: the client cut the connection again and again, "nothing
received from the host for 15 s", while the host's game came down and a few minutes after each reload (30 minutes to join).
The Steam tunnel lives in the host's game, which can stay busy longer than 15 s with such a world: through Steam the client
now waits 40 s, a direct connection still 15 s.

Client.SilentLimit (launcher/Core.cs) is read from the source and its rules checked:
  - 15 s for a direct connection, 40 s through Steam; MPFEVER_STEAMSILENT=0: 15 s through Steam too, as before;
  - MPFEVER_SILENTCUT=s: s seconds either way;
  - the link loop uses it (the client's route known from the connection made) and says the number of seconds.
Run: python tests/test_silentcut.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "..", "launcher", "Core.cs")

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def limit(src, steam, env):
    # a reading of SilentLimit's two lines, as C# runs them
    s = env.get("MPFEVER_SILENTCUT")
    if s is not None and s.isdigit() and int(s) > 0:
        return int(s)
    return 40 if steam and env.get("MPFEVER_STEAMSILENT") != "0" else 15


def main():
    src = open(CORE, encoding="utf-8").read()
    m = re.search(r"internal static int SilentLimit\(bool steam\)\s*\{(.*?)\n        \}", src, re.S)
    check("Client.SilentLimit found", m is not None)
    if not m:
        return 1
    body = m.group(1)
    check("MPFEVER_SILENTCUT read first", 'GetEnvironmentVariable("MPFEVER_SILENTCUT")' in body and "s > 0) return s;" in body)
    check("40 s through Steam, else 15 s; MPFEVER_STEAMSILENT=0 switches it off",
          'return steam && Environment.GetEnvironmentVariable("MPFEVER_STEAMSILENT") != "0" ? 40 : 15;' in body)
    check("a direct connection: 15 s", limit(body, False, {}) == 15)
    check("through Steam: 40 s", limit(body, True, {}) == 40)
    check("MPFEVER_STEAMSILENT=0: 15 s through Steam, as before", limit(body, True, {"MPFEVER_STEAMSILENT": "0"}) == 15)
    check("MPFEVER_SILENTCUT=25: 25 s", limit(body, False, {"MPFEVER_SILENTCUT": "25"}) == 25)

    check("the route is known from the connection made", 'viaSteam = used != null && used.StartsWith("steam:", StringComparison.Ordinal);' in src)
    check("the link loop uses it", "int silent = SilentLimit(viaSteam);" in src and "/ TimeSpan.TicksPerSecond > silent)" in src)
    check("and says the number of seconds", '"Client: nothing received from the host for {0} s, connection cut", silent' in src)
    check("no 15 s cut left in the link loop", "TimeSpan.TicksPerSecond > 15)" not in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
