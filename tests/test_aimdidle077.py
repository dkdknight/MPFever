"""Offline test: the Steam core's rate control no longer lowers a main link that has nothing of its own waiting, and gives its
start rate back once nearly everything arrives (0.7.7, Aimd in native/mpf_steamnet.cpp).

A main link's remote quality, while it sends almost nothing, tells how the relay does with the other links (a savegame on the
bulk links during a join or a resync). Aimd lowered it by 30 % per second on that quality alone, down to 256 KB/s, and raised it
only while 64 KB waited: the link stayed at the floor for 5 to 7 minutes (#133 22:08-22:15, #126 19:56-20:01), and the next
big station acts (600-838 KB each) crawled over it. Now, for the main and test links:
  - lowered only when more than 16 KB of its own waits (real congestion), as before then;
  - 3 refreshes (3 s) with a quality of 0.98 or more give its start rate back, even idle ("rate restored" in native.log);
  - the bulk links: unchanged; MPFEVER_AIMDIDLE=0 or "conf aimd_idle 0": the old rule.
native/steamnet_test.py mock runs it against the stand-in for Steam (TestQuality: a relay's quality and bytes waiting): quality
0.5 idle keeps the rate, quality 0.5 with 200 KB waiting lowers it, then quality 1.0 restores it, and aimd_idle 0 lowers again.
This test checks the code and that the mock case is there (the mock needs the C++ build: native/steamnet_test_build.bat).
Run: python tests/test_aimdidle077.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
N = os.path.join(HERE, "..", "native")
core = open(os.path.join(N, "mpf_steamnet.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
mock = open(os.path.join(N, "steamnet_mock.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
mt = open(os.path.join(N, "steamnet_test.py"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


a = core[core.index("static void Aimd(Tunnel* t, const SnRealTime& rt, u64 now)"):]
a = a[:a.index("\n}\n")]
check("bool idle = g_aimdIdle && t->kind != K_BULK;" in a, "the new rule for the main and test links only, behind the switch")
check("if (q >= 0 && q < 0.90f) { t->goodN = 0; if (!idle || rt.pendRel > (16 << 10)) r = r * 7 / 10; }" in a,
      "  a bad quality lowers a main link only with more than 16 KB of its own waiting (the bulk links: always, as before)")
check("else if (rt.pendRel > (64 << 10) && q > 0.98f) r = r * 115 / 100;" in a, "  the 15 % raise with data waiting: unchanged")
check("if (idle && q >= 0.98f) { if (++t->goodN >= 3 && r < g_rate[t->kind]) { r = g_rate[t->kind]; restore = true; } }" in a
      and "else if (q < 0.98f) t->goodN = 0;" in a, "  3 good refreshes in a row: its start rate back, even idle")
check(a.index("restore = true") < a.index("if (r < (256 << 10)) r = 256 << 10;") < a.index("if (r > ceil) r = ceil;"),
      "  the floor and the ceiling still bound it")
check('restore ? "restored"' in a and "if (down || restore ||" in a, "  a restore is logged at once")
check("int goodN;" in core and "memset(t, 0, sizeof(*t));" in core, "the count lives in the tunnel, zero when it starts")
check('Same(k, "aimd_idle") && num) g_aimdIdle = x != 0;' in core, "conf aimd_idle 0/1")
check('GetEnvironmentVariableA("MPFEVER_AIMDIDLE", dv, 3) > 0 && dv[0] == \'0\') g_aimdIdle = false;' in core, "MPFEVER_AIMDIDLE=0: as before")
check("EXP void TestQuality(int qPercent, int pend)" in mock and "if (g_fakeQ >= 0) { rt->qRemote = g_fakeQ;" in mock,
      "the stand-in for Steam reports a chosen quality and bytes waiting")
for what in ("quality 0.50, nothing waiting: the main link keeps", "quality 0.50 with 200 KB waiting: lowered, as before",
             "then everything arriving, nothing waiting: its start rate back", "conf aimd_idle 0: lowered with nothing waiting, as before"):
    check(what in mt, "steamnet_test.py mock: " + what)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
