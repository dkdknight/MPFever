"""Offline test: the autotests run with the players' default session settings (0.8.6, MPFEVER_TESTDEFAULTS=0 off).

2026-11-12: every autotest and the manual tests of that evening ran without « Responsive builds » (MPFEVER_BUILDLEAD): the
autotests write no settings.txt (Options.Disabled), the mod reads BUILDLEAD on "1" only, and nothing set it; every player has it on
by default (600 BUILDLEAD lines in Kasper's game of #261). launcher/Options.cs and Core.cs are read.
Run: python tests/test_testdefaults086.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


def read(n):
    return open(os.path.join(HERE, "..", "launcher", n), encoding="utf-8-sig").read().replace("\r\n", "\n")


op, core = read("Options.cs"), read("Core.cs")
t = op[op.index("public static IEnumerable<KeyValuePair<string, string>> TestDefaults()"):]
t = t[:t.index("\n        }\n")]
check("only in the autotests (Options.Disabled), MPFEVER_TESTDEFAULTS=0: not", 'if (!Disabled || Environment.GetEnvironmentVariable("MPFEVER_TESTDEFAULTS") == "0") yield break;' in t)
check("  the session settings of the mod only", "All.Where(x => x.Session && !x.Launcher)" in t)
check("  a variable set in the launcher's environment still decides", "if (Environment.GetEnvironmentVariable(o.Key) != null) continue;" in t)
check("  the players' default (DefaultOn) value; none when that value is empty (the mod's own default then)", "Value(o, o.DefaultOn)" in t and "string.IsNullOrEmpty(v)" in t)
check("BUILDLEAD is a session setting on by default with OnValue 1 (so the tests now get it)",
      'new Opt { Key = "MPFEVER_BUILDLEAD", Session = true, DefaultOn = true, OnValue = "1",' in op)
i, j = core.find("foreach (var kv in Options.TestDefaults())"), core.find('var roleEnv = Environment.GetEnvironmentVariable("MPFEVER_ENV_"')
check("Core: given to every game, before MPFEVER_ENV_HOST / _CLIENT (those still win)", 0 < i < j)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
