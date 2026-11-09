"""Offline test of « Same platform order (test) » (0.7.10, MPFEVER_ORDER2, launcher/Options.cs, Core.cs GameLink.Launch,
the native module's order fixes), REMOVED from the settings in 0.7.13.

The user's friends' session of 2026-11-08 (AMD host, keviK, Sascha; 0.7.8): 16 reloads on "vehicles", always keviK's game alone,
buses standing in a modular street terminal a few centimetres apart. TPF3-MP's platform-order fixes (ported in 0.5.0: the
platform visit loop, the platform candidates' sort, the persons waiting for a path) are off unless MPFEVER_ORDER2 is set, read by
the native module when the game starts. 0.7.10 let a player turn them on in the launcher's settings, for a test session (its
game said it in its hello, the host warned when a player's was not its own). 0.7.13: no measured benefit (every game, the host's
too, loads the same save at a resync; #150 drifted at the same rate with it mixed and with it off on both), and a player with it
and another without drift apart by design: the setting is gone, with the hello's word and the host's warning. Now:
  - no « Same platform order (test) » in the launcher's settings, no Order2On, nothing added to a game's hello, no warning;
  - the native module still reads MPFEVER_ORDER2 at the game's start: =1 in the environment of every game, as before (tests);
  - the launcher's path for a player's settings the native module reads (Options.NativeEnv) is kept, with nothing in it.
See also tests/test_expopts0713.py. Run: python tests/test_order2_0710.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8").read().replace("\r\n", "\n")


fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


op = read("launcher", "Options.cs")
core = read("launcher", "Core.cs")
mf = read("launcher", "MainForm.cs")
mc = read("launcher", "ModCopies.cs")
nat = read("native", "mpfever_native.cpp")
check('Key = "MPFEVER_ORDER2"' not in op and "Order2On" not in op and "Native = true" not in op,
      "no longer a player's setting (0.7.13): nothing of this player's goes to the game's environment for it")
check("foreach (var kv in Options.NativeEnv()) psi.EnvironmentVariables[kv.Key] = kv.Value;" in core
      and core.index("Options.NativeEnv()") < core.index("proc = Process.Start(psi);"), "  the path for such settings kept, before the game starts")
check("All.Where(o => o.Native && !o.Session && IsOn(o) && o.OnValue != \"\")" in op, "  only a setting on (none left: the variable is not set, as by default)")
check('if (i >= 6 && i <= 9 && i != 8 && GetEnvironmentVariableA("MPFEVER_ORDER2", 0, 0) == 0) layout = false;' in nat,
      "the native module's platform-order fixes: off unless MPFEVER_ORDER2 is in the game's environment (tests: as before)")
check("WithOrder2(" not in mf and "Order2On(" not in mf and "WithOrder2(" not in mc,
      "a player's game no longer adds the setting to its hello")
check("WarnOrder2(" not in mf and "WarnOrder2(" not in mc and "order2Warned" not in mc, "  and the host no longer compares it")
hello = mf[mf.index('                if (m.Kind == "hello") { g.InGame = true;'):][:700]   # (0.7.13: the game's memory logged aside, see test_resyncspeed0713.py)
check("\n                lock (waiting)\n" in hello and "order2" not in hello, "  the hello goes on to the host as the game wrote it")
check("if (on != o.DefaultOn) c.Add(" in op, "the problem reports still say the settings not at their default (Settings changed)")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
