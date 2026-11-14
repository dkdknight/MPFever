"""Test of #150's aircraft fix (0.8.8, native/mpfever_native.cpp: AirCacheRefresh, InstallAirCache; MPFEVER_AIRCACHE).

The slow drift between different PCs with nobody building: its first difference was always an aircraft. Measured with the fine
diagnostic on two PCs (2026-11-14, "Test Leawood", check 411: aircraft 279989 taxiing, its thrust parting at step 178252400),
then read in the game's code (re notes of that night): AircraftMoveSystem keeps each aircraft's highest thrust, top speed and
mass in an entry it makes again only when the aircraft's Aircraft or MovePathAircraft component changes; the highest thrust
falls with the maintenance state; the engine's two world states make that entry at different moments (the one that simulates
at the step, the other when the batch is copied to it, from older figures), so a step's thrust depended on which state made it,
that is on how a game's steps are cut into batches, which differs between two PCs. Every aircraft's entry is now made again at
the start of every step in the state that makes it. MPFEVER_AIRCACHE=0: as before.

The native module cannot run here: this checks the source (the place, the guards, the order, the switch) and that the
signature is the one of the game's function when the game is installed here. In game: the autotests on "Test Leawood" (its
log line, the games in sync) and the two-PC test.
Run: python tests/test_aircache088.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def body(head):
    b = nat[nat.index(head):]
    return b[:b.index("\n}\n")]


r = body("static void AirCacheRefresh(SavedRegs* r)\n{")
check("u64 sys = r->rcx, engine = r->rdx;" in r and "long n = (long)(i32)r->r8;" in r, "the update's arguments: the system, the engine, its aircraft")
check("*(u64*)(vt + 0x60) != g_airUpdate" in r, "only for the system whose update this is (its vtable's own slot)")
check("EntityFn build = *(EntityFn*)(vt + 0x20), erase = *(EntityFn*)(vt + 0x28);" in r, "the system's own two functions (vfunc4 makes the entry, vfunc5 takes it away)")
check("erase(sys, engine, ids[i]); build(sys, engine, ids[i]);" in r, "each aircraft: its entry taken away, then made again (as the engine does for a change of its component)")
check(r.index("for (long i = 0; i < n; i++) ids[i] = *(u32*)(list + (u64)i * 16);") < r.index("erase(sys, engine, ids[i])"),
      "the entities read first (16-byte entries), nothing of the list read while the entries are made")
check("n <= 0 || n > 65536" in r and "Readable((void*)list, (u64)n * 16)" in r, "nothing with no aircraft, an unreadable list or a count out of range")
check('"aircraft figures: made again at every step, "' in r, "said once in native.log, with the number of aircraft")

i = body("static void InstallAirCache()\n{")
check('GetEnvironmentVariableA("MPFEVER_AIRCACHE", v, 3) > 0 && v[0] == \'0\'' in i and i.index("MPFEVER_AIRCACHE") < i.index("FindSigRva("),
      "MPFEVER_AIRCACHE=0: nothing installed, as before")
m = re.search(r'FindSigRva\("([0-9A-F? ]+)"\)', i)
check(m is not None, "found by its signature")
sig = m.group(1) if m else ""
check("Splice(mem, at, 6, AirCacheRefresh)" in i, "spliced at the function's entry (the six bytes of its first four pushes)")
check(sig.startswith("40 53 56 57 41 54 "), "    those six bytes are pushes (no branch, nothing relative): they can be moved", sig[:20])
check("g_airUpdate = 0;" in i and "NOT found" in i, "not found: nothing installed, said (a slow drift stays possible)")
init = nat[nat.rindex("InstallNoGameAutosave();"):]
check(init.index("InstallAirCache();") < 200, "installed with the other hooks of a known game build")

# the signature against the game's own file, when it is here: one place, the update of AircraftMoveSystem's vtable
exe = os.path.join(ROOT, "..", "TransportFever3.exe")
if os.path.exists(exe) and sig:
    data = open(exe, "rb").read()
    rx = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in sig.split())
    hits = [mm.start() for mm in re.finditer(rx, data, re.S)]
    check(len(hits) == 1, "the signature is found once in this PC's TransportFever3.exe", len(hits))
else:
    print("     (no TransportFever3.exe beside the repository: the signature is not checked against the game)")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
