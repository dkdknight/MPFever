"""Offline test: a full disk no longer cuts the players without end, and the session folders are cleaned (0.9.4, issue #455,
MPFEVER_DISKFULL / MPFEVER_SESSIONCLEAN; launcher/Core.cs SessionDisk, Relay.ReadLoop, Client.ReadLoop; launcher/MainForm.cs
StartSessionClean, DropDeltaBase, OnDiskFull; launcher/SelfTest.cs RunSessionDisk094).

The bug (#455 and Discord "MPFever.exe stop working", flubixx's and John's session of 2026-11-21): the host's disk C: was full.
MPFever writes its session files in %TEMP%\\mpfever, never removed them, and kept there a copy of the game (delta_base.sav, 80 MB
and more) for every game hosted. The copy of the game failed at the start, then every message of John failed in the host's
handler (written for the host's game): the relay ended John's connection for it, John came back and sent his messages again,
they failed again, cut and back every half second without end, and the host's game said "no answer from MPFever.exe".
The fix: a full disk is said (the log, a dialog once), the player stays connected (the message that could not be written is
lost: the checks resynchronise once there is room); at its start the launcher removes the game copies of the session folders no
game wrote in for 6 hours and the folders no game wrote in for 7 days; the host's copy goes at the end of its session.

Part 1 checks the code (the rules, the two read loops, the wiring); part 2 checks that the launcher's self-test runs the bug and
the fix over a real relay and real folders (MPFever.exe --selftest, run by build.bat and the CI: RunSessionDisk094).
Run: python tests/test_sessiondisk094.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def src(name):
    return open(os.path.join(ROOT, "launcher", name), encoding="utf-8-sig").read().replace("\r\n", "\n")


core, mf, st = src("Core.cs"), src("MainForm.cs"), src("SelfTest.cs")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


# ---- part 1: the code
i = core.find("static class SessionDisk")
sd = core[i:core.find("sealed class GameLink", i)]
check("SessionDisk found (Core.cs, shared with the Linux relay)", i > 0 and len(sd) > 500)
check("  a full disk: Windows' 112 and 39, Linux's text, an IOException inside another",
      "code == 112 || code == 39" in sd and "No space left on device" in sd and "x = x.InnerException" in sd and "x is IOException" in sd)
check("  switches MPFEVER_DISKFULL and MPFEVER_SESSIONCLEAN, off only with 0",
      'GetEnvironmentVariable("MPFEVER_DISKFULL") != "0"' in sd and 'GetEnvironmentVariable("MPFEVER_SESSIONCLEAN") != "0"' in sd)
check("  6 hours for the game copies, 7 days for a folder", "TimeSpan.FromHours(6)" in sd and "TimeSpan.FromDays(7)" in sd)
check("  said at most every 30 s, the disk and the folder named", "30 * TimeSpan.TicksPerSecond" in sd and "Path.GetPathRoot" in sd and "Said?.Invoke(text)" in sd)
clean = sd[sd.find("public static (int dirs, int files, long bytes) Clean("):]
check("  the cleaning looks at folders only, by the last write of any of their files",
      "Directory.GetDirectories(root)" in clean and "SearchOption.AllDirectories" in clean and "f.LastWriteTimeUtc > last" in clean)
check("  only *.sav files of an idle folder removed, a whole folder only past the longer idle",
      '".sav"' in clean and clean.find("idle >= folderIdle") < clean.find("idle >= savIdle"))

loops = [m.start() for m in re.finditer(r"void ReadLoop\(", core)]
check("the two read loops (the host's relay, the client)", len(loops) == 2)
host_loop = core[loops[0]:loops[0] + 6000]
client_loop = core[loops[1]:loops[1] + 9000]
pat = "catch (Exception e) when (SessionDisk.FullOn && SessionDisk.IsFull(e))"
check("  the host's relay: a full disk in its handler keeps the player (said, the message lost)",
      "try { Received?.Invoke(p, m); }" in host_loop and pat in host_loop and "SessionDisk.Full(e, p.Name" in host_loop)
check("  the client: the same", "try { Received?.Invoke(m); }" in client_loop and pat in client_loop)
check("  any other failure still ends the connection as before", "catch (Exception e) { if (!stop && In(p)) Log.W(" in host_loop)

check("the launcher cleans the session folders as it starts, beside the window",
      "StartSessionClean();" in mf[mf.find("void InitInstall()"):mf.find("void InitInstall()") + 200]
      and "SessionDisk.Clean(GameLink.SessionRoot()" in mf and 'Name = "Session folders"' in mf)
es = mf[mf.find("void EndSession("):mf.find("void EndSession(") + 4000]
check("the host's copy of the game removed when its session ends", "DropDeltaBase();" in es)
d = mf[mf.find("void DropDeltaBase()"):mf.find("void DropDeltaBase()") + 500]
check("  (and forgotten: no next resynchronisation reads it)", "deltaBasePath = null; deltaBaseSha = null;" in d)
check("a full disk said in a dialog once (not for autotests nor a server)",
      "SessionDisk.Said += OnDiskFull;" in mf and "if (autotest || ServerMode || diskFullShown) return;" in mf)

# ---- part 2: the self-test runs it
check("the self-test runs RunSessionDisk094", "ok &= RunSessionDisk094();" in st)
t = st[st.find("static bool RunSessionDisk094()"):]
t = t[:t.find("\n        }\n") + 10]
check("  the bug: MPFEVER_DISKFULL=0, the first failure ends the connection", 'Run("0"' in t and "bug reproduced" in t)
check("  the fix: 4 messages, 2 failing on a full disk, the player kept", "h1 == 4" in t and "cuts1 == 0" in t)
check("  the folders: in use, idle 8 hours, 8 days, a long session, files beside", all(s in t for s in (
    "a folder in use: untouched", "a folder idle for 8 hours", "removed whole", "a session that runs", "files beside the folders")))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
