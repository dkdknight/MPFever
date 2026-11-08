"""Offline test: TF3's own autosave is off in a session, and a player's own game hosting saves the session's world at a pause
of every game instead (0.7.7, InstallNoGameAutosave / GameAutosaveGate in native/mpfever_native.cpp, HostAutosaveTick /
HostAutosave in launcher/Server.cs, GameInstall.GameAutosaveMinutes in launcher/Core.cs).

TF3 saves on its own every N minutes of real time, on every PC by its own clock: CGameUI's frame adds the frame's time to
[ui+0xe38] while the game runs and calls UI::CGameUI::AutoSave once it passes the interval, unless [ui+0x1170] says not to. In a
session that save stalled one game alone 2.4 to 4 s in the middle of a run, the others waiting at the barrier, and twice in
four the vehicles drifted within a minute after it (the user's server 2026-11-07 22:40 and 2026-11-08 01:39). Now:
  - while a session runs in a game (holding on, the mod's heartbeat fresh), the time counted is set back to 0 just before the
    game's test, on every PC: the game never saves on its own then; outside a session, as always (MPFEVER_GAMEAUTOSAVE=1:
    kept in sessions too);
  - a player's own game hosting (a dedicated server has its own autosave) saves the world every N minutes (the host's TF3
    option, 10 without it), at a pause of every game, under "autosave_<world>_MPFever 1" and "... 2" in turn, never under the
    savegame played; nothing when nothing happened; resumed only when nobody paused meanwhile (MPFEVER_HOSTAUTOSAVE=<min>).
The game's code is checked when the game is installed next to MPFever (the signature found once, the stolen instruction whole).
The launcher's self-test (RunReport077) checks the names and the switch.
Run: python tests/test_gameautosave077.py
"""
import os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
srv = open(os.path.join(ROOT, "launcher", "Server.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
core = open(os.path.join(ROOT, "launcher", "Core.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


SIG = "80 BE 70 11 00 00 00 75 ?? 48 3B 86 38 0E 00 00 7D ?? 48 8B CE E8"
inst = nat[nat.index("static void InstallNoGameAutosave()"):]
inst = inst[:inst.index("\n}\n")]
check('FindSigRva("' + SIG + '")' in inst, "the site found by its bytes, with the offsets 0x1170 and 0xe38 in them (FindSigRva: exactly once)")
check("Splice(mem, at, 7, GameAutosaveGate)" in inst, "  the 7-byte test stolen, run after the gate (its flags for the jump that follows)")
check('GetEnvironmentVariableA("MPFEVER_GAMEAUTOSAVE", v, 3) > 0 && v[0] == \'1\'' in inst, "  MPFEVER_GAMEAUTOSAVE=1: the game's own autosave kept")
check("NOT found (the game still saves on its own in a session)" in inst, "  not found: nothing changed, and the log says it")
g = nat[nat.index("static void GameAutosaveGate(SavedRegs* r)"):]
g = g[:g.index("\n}\n")]
check(g.startswith("static void GameAutosaveGate(SavedRegs* r)\n{\n    if (!g_enabled) return;"), "the gate: nothing outside a session (holding off)")
check('KeptHandle(g_gasAliveFile, "bridge_alive.txt")' in g and "if (!g_gasAliveAt || now - g_gasAliveAt > 10000) return;" in g,
      "  nor without the mod's heartbeat for 10 s (its own file handle: no race with the other readers)")
check("i64* counted = (i64*)(ui + 0xe38);" in g and g.rstrip().endswith("*counted = 0;"), "  the time counted set back to 0: the game's test never passes")
check("u8* ui = (u8*)r->rsi;" in g and "i64 interval = (i64)r->rax;" in g, "  the game UI in rsi, the interval in rax (computed just before)")
ins = nat[nat.index("    PatchSaveCleanup();\n    InstallNoGameAutosave();"):][:200]
check(bool(ins), "installed at start, after the saves' clean-up patch")

exe = os.path.join(ROOT, "..", "TransportFever3.exe")
if os.path.exists(exe):
    d = open(exe, "rb").read()
    pat = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in SIG.split())
    hits = [m.start() for m in re.finditer(pat, d, re.S)]
    check(len(hits) == 1, f"the installed game: the signature found exactly once ({len(hits)})")
    if len(hits) == 1:
        h = hits[0]
        check(d[h:h + 7] == bytes.fromhex("80BE701100000000")[:7] and d[h + 7] == 0x75, "  the stolen bytes are one whole instruction (cmp byte [rsi+0x1170],0), then the jne")
        rel = struct.unpack_from("<i", d, h + 22)[0]
        check(d[h + 21] == 0xE8 and rel < 0, "  the call of AutoSave right after (backwards in the code)")
else:
    print("(the game is not installed next to MPFever: its code not checked)")

t = srv[srv.index("void HostAutosaveTick()"):]
t = t[:t.index("\n        }\n")]
check("if (server != null || !started || hostGame == null) { hostAutosaveAt = -1; return; }" in t, "the host's autosave: a player's own game only (a server has its own), from the session's start")
check("int minutes = HostAutosaveMinutes(autotest);" in t and "if (minutes <= 0) return;" in t, "  every N minutes, 0: never")
check("Interlocked.CompareExchange(ref hostAutosaveBusy, 1, 0) != 0" in t, "  one at a time")
a = srv[srv.index("void HostAutosave()"):]
a = a[:a.index("\n        }\n\n")]
check("Monitor.TryEnter(worldGate" in a and "finally { Monitor.Exit(worldGate); }" in a, "  never together with a resynchronisation")
check("if (acts == hostSavedActs && clock == hostSavedClock) return;" in a, "  nothing saved when nothing happened")
check(a.index("Pause(T(\"sauvegarde automatique\", \"autosave\"))") < a.index("c.T >= at && c.Sp == 0") < a.index('Msg.Make("resync_save"'),
      "  every game paused, the host's stopped at the pause, then its save")
check("string name = HostAutosaveName(lobbySave, ++hostAutosaveN);" in a, "  under the autosave names, never the savegame played")
check("ours = pauseAt.HasValue && pauseAt.Value == at;" in a and "if (wasRunning && ours && !resyncing && started) SetSpeed(prevSpeed," in a,
      "  resumed only when the pause is still its own (a player who paused meanwhile keeps the pause)")
n = srv[srv.index("internal static string HostAutosaveName(string world, int n)"):][:300]
check('return "autosave_" + w + "_MPFever " + (n % 2 == 0 ? 2 : 1);' in n, "  two names in turn: the last two kept")
m = srv[srv.index("internal static int HostAutosaveMinutes(bool autotest)"):][:600]
check('GetEnvironmentVariable("MPFEVER_HOSTAUTOSAVE")' in m and 'GetEnvironmentVariable("MPFEVER_GAMEAUTOSAVE") == "1" || autotest) return 0;' in m
      and "return GameInstall.GameAutosaveMinutes() ?? 10;" in m, "  MPFEVER_HOSTAUTOSAVE; none when the game's own is kept or in an autotest; else the game's option, 10")
check(r'@"autosaveIntervalMinutes\s*=\s*(\d+)"' in core, "the game's option read from its settings.lua")
check("HostAutosaveTick();   // (0.7.7" in mf[mf.index("void HostLoop(int gen)"):][:2000], "the host loop runs it")
check("MainForm.HostAutosaveName(" in st and "MainForm.HostAutosaveMinutes(" in st, "the launcher's self-test checks the names and the switch")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
