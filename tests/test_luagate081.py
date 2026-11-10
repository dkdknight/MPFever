"""Offline test: Lua errors in the games' logs fail an autotest (0.8.1, LUAERRGATE; launcher/MainForm.cs, tests/check_game_logs.py).

The regression of 0.7.17 ("attempt to index global 'SIM'" in REFUND.book, #200/#201/#208) was logged 190 times in one autotest
of 2026-11-10 that was judged "in sync", so it shipped. Now:
  - the launcher's autotest ends with "lua: clean" or "lua: FAILED (n ...)" and the first error lines of each game;
  - tests/check_game_logs.py does the same on any folder (autotest sessions, players' reports);
  - the engine's own messages (deferred action failed, bad argument in probes) are not counted;
  - MPFEVER_LUAERRGATE=0: not looked at.
Run: python tests/test_luagate081.py
"""
import os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_game_logs  # noqa: E402

mf = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


fin = mf[mf.index('AutoLine("sessions: "'):]
fin = fin[:fin.index("autotest_result.txt")]
check('MPFEVER_LUAERRGATE") != "0"' in fin and "LuaErrorLines(g.Dir, 3, out int n)" in fin and '"lua: clean"' in fin and '"lua: FAILED ("' in fin,
      "the autotest's verdict says the games' Lua errors")
check('@"attempt to (index|call|perform arithmetic|compare|concatenate|get length)|simulation apply failed"' in mf
      and check_game_logs.PATTERN.pattern == "attempt to (index|call|perform arithmetic|compare|concatenate|get length)|simulation apply failed",
      "  the launcher and the script use the same rule")
check("ok &= RunLuaGate081();" in st, "  the launcher's self-test runs it")

d = tempfile.mkdtemp()
try:
    os.makedirs(os.path.join(d, "s"))
    with open(os.path.join(d, "s", "mod.log"), "w") as f:
        f.write("18:43:06 simulation apply failed: [string \"C:/x/mpfever_bridge.script.lua\"]:460: attempt to index global 'SIM' (a nil value)\n")
        f.write("18:43:07 engine: post build t=1\n")
    with open(os.path.join(d, "s", "ui.log"), "w") as f:
        f.write("deferred action failed: Invalid entity\nSTOPALIGNPROBE no proposal data (bad argument #2 to 'makeProposalData')\n")
    res = check_game_logs.scan([d])
    check(len(res) == 1 and sum(len(v) for v in res.values()) == 1, "the script finds the 0.7.17 error and not the engine's messages")
    os.remove(os.path.join(d, "s", "mod.log"))
    check(check_game_logs.scan([d]) == {}, "  clean logs: nothing")
finally:
    shutil.rmtree(d, ignore_errors=True)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
