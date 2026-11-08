"""Offline test of #153's fix (0.7.11): one install of MPFever's files at a time on a PC (launcher/MainForm.cs, InitInstall).

janik, 2026-11-08 17:52:24: MPFever started twice at the same moment (every line of the launcher's log twice); both copied the
mod into the same folder at once, two files were refused ("access denied"), and the game stopped on the half-copied mod
("Mod was not cached in filesystem: mpfever_1::/mpfever_auto.lua"). Now InitInstall takes a named mutex of the PC's session
("Local\\MPFever.Install") around the whole install (the native module, the mod, its activation): the second MPFever waits for
the first one's install, 60 s at most, then installs as usual; an abandoned mutex (a launcher killed while installing) is
taken; MPFEVER_INSTALLLOCK=0: no lock, as before. Run: python tests/test_installlock0711.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


ii = mf[mf.index("        void InitInstall()"):]
ii = ii[:ii.index("        void InitInstallLocked()")]
check('new System.Threading.Mutex(false, @"Local\\MPFever.Install")' in ii, "a named mutex of the PC's session")
check("gate.WaitOne(TimeSpan.FromSeconds(60))" in ii and "catch (System.Threading.AbandonedMutexException) { held = true; }" in ii,
      "  waited for 60 s at most; an abandoned one is taken")
check("try { InitInstallLocked(); }" in ii and "finally { if (held) try { gate.ReleaseMutex(); } catch { } gate?.Dispose(); }" in ii,
      "  the whole install inside it, released whatever happens")
check('Environment.GetEnvironmentVariable("MPFEVER_INSTALLLOCK") != "0"' in ii, "MPFEVER_INSTALLLOCK=0: no lock, as before")
lk = mf[mf.index("        void InitInstallLocked()"):]
lk = lk[:lk.index("\n        }\n")]
check("GameInstall.InstallNative(gameDir)" in lk and "GameInstall.InstallMod()" in lk and "GameInstall.EnsureModActive()" in lk,
      "the native module, the mod and its activation all inside the lock")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
