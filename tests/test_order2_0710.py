"""Offline test of « Same platform order (test) » (0.7.10, MPFEVER_ORDER2, launcher/Options.cs, Core.cs GameLink.Launch,
ModCopies.WithOrder2 / MainForm.WarnOrder2, the native module's order fixes).

The user's friends' session of 2026-11-08 (AMD host, keviK, Sascha; 0.7.8): 16 reloads on "vehicles", always keviK's game alone,
buses standing in a modular street terminal a few centimetres apart. TPF3-MP's platform-order fixes (ported in 0.5.0: the
platform visit loop, the platform candidates' sort, the persons waiting for a path) are off unless MPFEVER_ORDER2 is set, read by
the native module when the game starts. Now a player can turn them on in the launcher's settings, for a test session:
  - a player's own setting, OFF by default (the user: no regression risk), given to the game's environment when on;
  - every game of a session needs it alike: each player's game says it in its hello, the host warns (log and chat) when a
    player's is not its own;
  - the problem reports say it (Settings changed: ORDER2=on).
Run: python tests/test_order2_0710.py
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
o = op[op.index('Key = "MPFEVER_ORDER2"') - 20:][:300]
check("DefaultOn = false" in o and 'OnValue = "1"' in o and "Native = true" in o and "Session = true" not in o,
      "a player's own setting, off by default, for the game's environment")
check("foreach (var kv in Options.NativeEnv()) psi.EnvironmentVariables[kv.Key] = kv.Value;" in core
      and core.index("Options.NativeEnv()") < core.index("proc = Process.Start(psi);"), "  given to the game's environment before it starts")
check("All.Where(o => o.Native && !o.Session && IsOn(o) && o.OnValue != \"\")" in op, "  only when on (off: the variable is not set, as before)")
check('GetEnvironmentVariableA("MPFEVER_ORDER2", 0, 0) == 0' in nat, "the native module's platform-order fixes read it at the game's start")
check('if (m.Kind == "hello") m.Payload = ModCopies.WithOrder2(m.Payload, Options.Order2On());' in mf, "a player's game says it with its hello")
check("if (from != null) WarnOrder2(m.From, m.Payload);" in mf, "  the host compares it with its own")
wo = mc[mc.index("        void WarnOrder2("):]
check("if (theirs == mine) return;" in wo and "Log.Err(text);" in wo and 'HostChat("msg", "MPFever", text);' in wo and "order2Warned.Add(" in wo,
      "  warned in the log and the chat, once per player and setting")
check("if (on != o.DefaultOn) c.Add(" in op, "the problem reports say it (Settings changed)")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
