"""Offline test of the faster saves (0.7.6, InstallFastSave in native/mpfever_native.cpp, after TPF3-MP's savefast, MIT).

The game compresses a savegame with zstd at level 3 through a 128-byte buffer: most of a save's time on a big world, and MPFever
saves at every resynchronisation, every autosave of a server and every arrival of a player, every game stopped meanwhile
(the user's server, 2026-11-07: an autosave held the world 10 s). With MPFEVER_FASTSAVE=1, two instructions of the save writer's PushCompressor are
rewritten: the level 1 (mov eax,1; nop instead of the load of the constant the reader shares), a 64 KiB buffer. A savegame is
still a standard zstd frame, loaded by any game.
  - with the game on this PC (TransportFever3.exe, build 40425): each signature is found once in the code, at the places TPF3-MP
    verified (0x32dec4, 0x32e024), the level's constant holds 3 and the bytes there are the ones the native module expects;
  - the native module checks each site byte for byte, the constant at 3, and patches each alone;
  - OFF by default: measured on Test Lag Rp (2026-11-07, the host's resynchronisation save, two games on one PC), the game's own
    6.4 s for 114.8 MB, level 1 with the buffer 5.3 s for 124.7 MB, the buffer alone 6.5 s for 114.8 MB: the second gained is
    lost again sending 10 MB more over the Internet (5.4 MB/s on the user's server). MPFEVER_FASTSAVE=1 (or =level, =buffer).
Run: python tests/test_fastsave076.py
"""
import os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


nat = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
i = nat.find("static void InstallFastSave()")
body = nat[i:nat.find("\n}\n", i)]
LV = "8B 05 ?? ?? ?? ?? 41 89 43 10 49 8D 43 88"
BF = "4C 8B CB 41 B8 80 00 00 00 48 8D 54 24 30 48 8B C8 E8 E9 B5 FE FF"
check(i > 0 and 'FindSigRva("' + LV + '")' in body and 'FindSigRva("' + BF + '")' in body, "the two signatures (TPF3-MP's, build 40425)")
check("== 3" in body and "bool okL = doLevel && three && patch(lv, lvWas, lvPut, 6);" in body, "the level patched only when its constant holds 3")
check("{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0x90 }" in body and "{ 0x41, 0xB8, 0x00, 0x00, 0x01, 0x00 }" in body, "mov eax,1; nop and mov r8d,10000h")
check("if (site[i] != expect[i]) return false;" in body, "each site checked byte for byte before it is written")
check('GetEnvironmentVariableA("MPFEVER_FASTSAVE", fs, 15) == 0 || fs[0] == \'0\'' in body, "OFF by default (the game's own), MPFEVER_FASTSAVE=1 to try them")
check("bool doLevel = fs[0] != 'b', doBuffer = fs[0] != 'l';" in body, "  =level / =buffer: one of the two (the measures)")
check("    InstallFastSave();" in nat, "installed with the other patches")

exe = os.path.join(HERE, "..", "..", "TransportFever3.exe")
if not os.path.exists(exe):
    print("(the game is not on this PC: its code not looked at)")
else:
    d = open(exe, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    secs = []
    for k in range(nsec):
        o = pe + 24 + opt + 40 * k
        vs, va, rs, ro = struct.unpack_from("<IIII", d, o + 8)
        secs.append((d[o:o + 8].rstrip(b"\0"), va, vs, ro, rs))

    def off(r):
        for _, va, vs, ro, rs in secs:
            if va <= r < va + max(vs, rs):
                return ro + (r - va)

    def find(sig):
        pat = b"".join(b"." if p == "??" else re.escape(bytes([int(p, 16)])) for p in sig.split())
        return [va + mm.start() for n, va, vs, ro, rs in secs if n.startswith(b".tex") for mm in re.finditer(pat, d[ro:ro + rs], re.S)]

    lv, bf = find(LV), find(BF)
    check(lv == [0x32dec4], "the game: the level's load found once, at 0x32dec4 (" + ",".join(hex(x) for x in lv) + ")")
    check(bf == [0x32e021], "the game: the buffer's found once, its mov at 0x32e024 (" + ",".join(hex(x + 3) for x in bf) + ")")
    if len(lv) == 1:
        o = off(lv[0])
        c = lv[0] + 6 + struct.unpack_from("<i", d, o + 2)[0]
        check(struct.unpack_from("<i", d, off(c))[0] == 3, "the game: its constant holds 3 (" + hex(c) + ")")
    if len(bf) == 1:
        check(d[off(bf[0]) + 3:off(bf[0]) + 9] == bytes([0x41, 0xB8, 0x80, 0, 0, 0]), "the game: mov r8d,80h there")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
