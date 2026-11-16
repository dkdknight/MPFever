"""Offline test (0.8.16): every game's native fixes that change the simulation are compared with the host's.

#268 (0.8.4) told the session when a game's native module did not run at all. A module that runs with one fix missing (its
signature not found on that game's build, a switch set on one PC: the shared maintenance of 0.8.15 on one game only) made that
game drift with nothing said. Now:
  - the native module names each such fix once it is in place (Fx: the order fixes, clearsame, industrydemand, decisionsync,
    freshids, aircache, wear, sharedmaint) and writes the list to native_fx.txt after its fixes are in;
  - the mod sends it in its hello ("fx");
  - the host compares every game's with its own game's (MainForm.WarnNativeFx, NativeFxProblem), says the difference once per
    player in the chat; MPFEVER_NATIVEFXCHECK=0: not compared; an older mod without the list: nothing said;
  - the launcher's selftest checks NativeFxProblem (RunNativeFx0816).
Run: python tests/test_nativefx0816.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
R = lambda *p: open(os.path.join(HERE, "..", *p), encoding="utf-8-sig").read().replace("\r\n", "\n")
nat = R("native", "mpfever_native.cpp")
br = R("mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
mc = R("launcher", "ModCopies.cs")
mf = R("launcher", "MainForm.cs")
st = R("launcher", "SelfTest.cs")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


for k in ("if (ok) Fx(f.name);", 'if (ok) Fx("clearsame");', 'if (!off) Fx("industrydemand");', 'Fx("decisionsync");', 'Fx("freshids");',
          'if (ok) Fx("aircache");', 'if (ok) Fx("wear");', 'if (g_mtSplice) Fx("sharedmaint");'):
    check(k in nat, "native: " + k)
i = nat.find('WriteSessionFile("native_fx.txt", f.s, f.n);')
check(i > 0 and nat.find("InstallSharedMaint();") < i and nat.find("InstallVehicleWear();") < i, "native_fx.txt written after the fixes are in")
check('native_fx.txt", "rb")' in br and "nat = nat, fx = fx," in br, "the mod sends the list in its hello")
check("WarnNativeFx(m.From, m.Payload);" in mf, "the host compares on every hello")
check('"MPFEVER_NATIVEFXCHECK") == "0") return;' in mc, "MPFEVER_NATIVEFXCHECK=0: not compared")
check("if (fx == null || hostFx == null) return null;" in mc, "an older mod without the list: nothing said")
check("nativeFxWarned.Add(" in mc and 'HostChat("msg", "MPFever", t);' in mc, "said once per player and difference, in the chat")
check("ok &= RunNativeFx0816();" in st, "the launcher's selftest checks it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
