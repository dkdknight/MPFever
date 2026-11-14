"""Test of #150's aircraft fix (0.8.8, native/mpfever_native.cpp: AirPre, AirPost, AirUpdateWrap, InstallAirCache;
MPFEVER_AIRCACHE, MPFEVER_AIRPOS0).

The slow drift between different PCs with nobody building: its first difference was always an aircraft. Measured with the fine
diagnostic on two PCs (2026-11-14, "Test Leawood", check 411: aircraft 279989 taxiing, its thrust parting at step 178252400),
then read in the game's code (re notes of that night): AircraftMoveSystem keeps each aircraft's highest thrust, top speed and
mass in an entry it makes again only when the aircraft's Aircraft or MovePathAircraft component changes; the highest thrust
falls with the maintenance state; the engine's two world states make that entry at different moments (the one that simulates
at the step, the other when the batch is copied to it, from older figures), so a step's thrust depended on which state made it,
that is on how a game's steps are cut into batches, which differs between two PCs.
  - every aircraft's entry is made again at the start of every step in the state that makes it (the system's own vfunc5 then
    vfunc4, the pair the engine runs for a change of the Aircraft component);
  - pathPos0, the aircraft's place at the start of the BATCH, which the update reads at two changes of path, is the place at
    the start of the STEP for the time of the update, and the batch's value is put back after it unless the engine wrote
    another one (the picture between two batches is unchanged). MPFEVER_AIRPOS0=0: left alone;
  - MPFEVER_AIRCACHE=0: nothing installed, as before.

The native module cannot run here: this checks the source (the place, the guards, the order, the switches) and that the
signature is the one of the game's function when the game is installed here, with its vtable's slot found once. In game: the
autotests on "Test Leawood" (its log lines, the games in sync, the aircraft landing and taking off) and the two-PC test.
Run: python tests/test_aircache088.py
"""
import os
import re
import struct
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


print("the entries made again")
r = body("static void AirPre(u64 sys, u64 engine, long n)\n{")
check("EntityFn build = *(EntityFn*)(vt + 0x20), erase = *(EntityFn*)(vt + 0x28);" in r, "the system's own two functions (vfunc4 makes the entry, vfunc5 takes it away)")
check("erase(sys, engine, ids[i]); build(sys, engine, ids[i]);" in r, "each aircraft: its entry taken away, then made again (as the engine does for a change of its component)")
check(r.index("for (long i = 0; i < n; i++) ids[i] = *(u32*)(list + (u64)i * 16);") < r.index("erase(sys, engine, ids[i])"),
      "the entities read first (16-byte entries), nothing of the list read while the entries are made")
check("n <= 0 || n > 65536" in r and "AirLists(sys, n, &list, &mpa)" in r, "nothing with no aircraft, an unreadable list or a count out of range")
check('"aircraft figures: made again at every step, "' in r, "said once in native.log, with the number of aircraft")
w = body("static u64 AirUpdateWrap(u64 sys, u64 engine, i64 n, float dt)\n{")
check(w.index("AirPre(sys, engine, (long)(i32)n);") < w.index("u64 r = g_airOrig(sys, engine, n, dt);") < w.index("AirPost(sys, (long)(i32)n);")
      and "return r;" in w, "around the game's own update: before it, the update with its own arguments, after it")

print("the place at the start of the batch")
check(r.index("erase(sys, engine, ids[i])") < r.index("memcpy(c + 0x74, c + 0x68, 12);"), "after the entries (they do not read it)")
check("if (!g_airPos0On || n > 512) return;" in r, "MPFEVER_AIRPOS0=0: left alone (and above 512 aircraft)")
check("!c[0x80]" in r and "memcpy(e.batch, c + 0x74, 12);" in r and "memcpy(e.step, c + 0x74, 12);" in r,
      "only where it has a value; the batch's value kept aside, the step's noted")
p = body("static void AirPost(u64 sys, long n)\n{")
check("if (memcmp(c + 0x74, e.step, 12) == 0) { memcpy(c + 0x74, e.batch, 12);" in p,
      "after the update: the batch's value put back where the step's is still there (the picture between two batches unchanged)")
check("else g_airPos0Kept++;" in p, "    another value there: the engine's own (a change of path), kept")
check("*(u32*)(list + (u64)i * 16) != e.ent || *(i32*)(list + (u64)i * 16 + 8) != e.idx" in p, "    only the same aircraft at the same component")
check("g_airPos0N = 0;" in p and "g_airPos0N = 0;" in r, "nothing kept from one update to the next")

print("the installation")
i = body("static void InstallAirCache()\n{")
check('GetEnvironmentVariableA("MPFEVER_AIRCACHE", v, 3) > 0 && v[0] == \'0\'' in i and i.index("MPFEVER_AIRCACHE") < i.index("FindSigRva("),
      "MPFEVER_AIRCACHE=0: nothing installed, as before")
m = re.search(r'FindSigRva\("([0-9A-F? ]+)"\)', i)
check(m is not None, "the update found by its signature")
sig = m.group(1) if m else ""
check("if (*(u64*)q == target) { slots++; slot = q; }" in i and "bool shape = slots == 1" in i, "its vtable's slot: the one place outside the code that holds its address")
check("f4 >= g_textStart && f4 < g_textEnd && f5 >= g_textStart && f5 < g_textEnd" in i, "    with the entry's maker and eraser at slots 4 and 5, both in the code")
check("*(u64*)slot = (u64)&AirUpdateWrap;" in i and i.index("g_airOrig = (AirUpdateF)target;") < i.index("*(u64*)slot = (u64)&AirUpdateWrap;"),
      "the slot calls the wrapper (the game's update noted first)")
check("NOT found" in i and "a slow drift between PCs stays possible" in i, "not found: nothing installed, said")
init = nat[nat.rindex("InstallNoGameAutosave();"):]
check(init.index("InstallAirCache();") < 200, "installed with the other hooks of a known game build")

# the signature against the game's own file, when it is here
exe = os.path.join(ROOT, "..", "TransportFever3.exe")
if os.path.exists(exe) and sig:
    data = open(exe, "rb").read()
    rx = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in sig.split())
    hits = [mm.start() for mm in re.finditer(rx, data, re.S)]
    check(len(hits) == 1, "the signature is found once in this PC's TransportFever3.exe", len(hits))
    if len(hits) == 1:
        # the function's address as the game loads it (the image base and the sections from the file's headers)
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        opt = struct.unpack_from("<H", data, pe + 20)[0]
        base = struct.unpack_from("<Q", data, pe + 24 + 24)[0]
        secs = []
        for k in range(nsec):
            o = pe + 24 + opt + 40 * k
            name = data[o:o + 8].rstrip(b"\0")
            vsize, va, rsize, raw = struct.unpack_from("<IIII", data, o + 8)
            secs.append((name, va, vsize, raw, rsize))
        rva = next(va + hits[0] - raw for name, va, vsize, raw, rsize in secs if raw <= hits[0] < raw + rsize)
        target = struct.pack("<Q", base + rva)
        n = 0
        for name, va, vsize, raw, rsize in secs:
            if name.startswith(b".tex"):
                continue
            blob = data[raw:raw + min(vsize, rsize)]
            n += sum(1 for k in range(0, len(blob) - 7, 8) if blob[k:k + 8] == target)
        check(n == 1, "    and its address once outside the code: its vtable's slot", n)
else:
    print("     (no TransportFever3.exe beside the repository: the signature is not checked against the game)")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
