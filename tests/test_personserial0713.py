"""Offline test of the persons and the land vehicles in one piece (0.7.13, issues #150/#166/#170; ON by default since 0.8.3, the 0.8.2
reports' drifts beginning in the moves, MPFEVER_PERSONSERIAL=0 / MPFEVER_VEHSERIAL=0: in chunks as before;
InstallPersonSerial, SerialLoops and SerialPathAt in native/mpfever_native.cpp).

#150, #166 and #170 drifted with no action, one to six game minutes after a load, the gigantic worlds most, a passenger or a bus
first (r166: one bus left a stop later on one game alone). The persons' moves (PersonMoveSystem, two loops), their boarding
(SimPersonAtVehicle), their leaving the buildings (SimEntityAtBuilding) and four loops of the land vehicles are handed to the
engine's thread pool in chunks, as the animals' moves were before 0.5.12. The native module can set each loop's chunk size
("mov r9d, chunk" right before the call of the pool's loop) larger than any count, the animals' patch, so that the pool's loop
takes its own one-thread path: MPFEVER_PERSONSERIAL=1 (the persons' four loops), MPFEVER_VEHSERIAL=1 (the vehicles' four), unset
by default until a test with two games proves it. Cases:
  - the module: the eight signatures, the imm32 at +2 written with 0x7FFFFFFF, only after the call's target was checked (the
    count against the chunk size "cmp r8d, r9d / jle" and the pool's size against 1 "sar rax, 4 / cmp eax, 1 / je", both to the
    same place, inside the game's code); a place not found or another function leaves its loop alone and is named in the log
    line; each switch read as "0" only (0.8.3: unset = in one piece; a line either way); called right after the animals' block, which is as it
    was; nothing in the launcher sets them;
  - the game (build 40425, read-only, pefile): each signature found exactly once in .text, its chunk size the one expected
    (persons 0x200, 0x80, 0x40, 0x100; vehicles 0x100, 0x40, 0x40, 0x100), its call to the start of a function (.pdata) whose
    head has both tests jumping to its one-thread path, which calls the loop's body once for the whole count (r8d = 0, r9d = the
    count, or a body that takes the whole count itself), and which names "ThreadPool::LoopImpl" (a lea rip-relative); the
    module's own test (SerialPathAt, in Python here) says yes to the eight and to the animals' loop, and only to the pool's
    loops; the eight patched bytes are in no other signature of the module (its later searches still find theirs). Another
    build or no game here: said, not checked;
  - the in-game A/B test's events (tools/recplay_drift_big.txt, MPFEVER_SCENARIO=recplay): x4, four runs of 15 minutes with a
    check after each, no action, only events the launcher's recplay knows.
Run: python tests/test_personserial0713.py
"""
import bisect
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
NATIVE = os.path.join(ROOT, "native", "mpfever_native.cpp")
SIGS = os.path.join(ROOT, "native", "mpfever_sigs.txt")
GAME = os.path.join(ROOT, "..", "TransportFever3.exe")
BUILD_40425 = 0x6ad9ce10

PERSONS = [
    ("person moves 512", "41 B9 00 02 00 00 44 8B C6 49 8B D7 48 8B C8 E8", 0x200, 0xaf2f98),
    ("person moves 128", "41 B9 80 00 00 00 44 8B C6 48 8D 54 24 50 48 8B C8 C5 F8 77 E8", 0x80, 0xaf2f4a),
    ("persons at vehicles", "41 B9 40 00 00 00 44 8B C5 48 8D 54 24 40 48 8B C8 C5 F8 77 E8", 0x40, 0xb23ae3),
    ("persons at buildings", "41 B9 00 01 00 00 45 8B C6 48 8D 55 E7 48 8B C8 E8", 0x100, 0xb0bfed),
]
VEHICLES = [
    ("land vehicles 1", "41 B9 00 01 00 00 44 8B C3 48 8D 95 10 13 00 00 C5 F8 77 E8", 0x100, 0xac8f6e),
    ("land vehicles 2", "41 B9 40 00 00 00 45 8B C6 48 8D 95 40 01 00 00 49 8B CA C5 F8 77 E8", 0x40, 0xac90d3),
    ("land vehicles 3", "41 B9 40 00 00 00 44 8B C3 48 8D 95 40 01 00 00 49 8B CA C5 F8 77 E8", 0x40, 0xac8e3d),
    ("land vehicles 4", "41 B9 00 01 00 00 44 8B C3 48 8D 95 40 01 00 00 C5 F8 77 E8", 0x100, 0xac8ae5),
]
ANIMALS = "41 B9 80 00 00 00 44 8B C7 48 8D 55 F0 C5 F8 77 E8"

fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def body_of(src, head):
    m = re.search("^" + re.escape(head) + r"\n\{\n.*?^\}\n", src, re.S | re.M)
    return m.group(0) if m else ""


def source_checks():
    src = open(NATIVE, encoding="utf-8").read().replace("\r\n", "\n")
    for group, loops in (("PERSON_LOOPS", PERSONS), ("VEHICLE_LOOPS", VEHICLES)):
        m = re.search(r"static const SerialLoop " + group + r"\[\] = \{\n(.*?)\n\};", src, re.S)
        check(m is not None, f"the module's {group}")
        rows = re.findall(r'\{ "([^"]+)", "([0-9A-F ]+)" \}', m.group(1) if m else "")
        check(rows == [(n, s) for n, s, _, _ in loops], f"  its four loops, by these signatures exactly", rows)
    sl = body_of(src, "static int SerialLoops(const SerialLoop* loops, int n, Buf& miss)")
    check(sl != "", "SerialLoops")
    check("u32 at = FindSigRva(loops[i].sig);" in sl and "if (at && SerialPathAt(at, len)) {" in sl,
          "  each place by its signature, written only after its call was checked")
    check("u8* imm = (u8*)(g_base + at + 2);" in sl and "*(u32*)imm = 0x7FFFFFFFu;" in sl
          and sl.index("VirtualProtect(imm, 4, PAGE_EXECUTE_READWRITE, &old)") < sl.index("*(u32*)imm = 0x7FFFFFFFu;")
          < sl.index("FlushInstructionCache(GetCurrentProcess(), imm, 4);"), "  the chunk size (imm32 at +2) set to 0x7FFFFFFF, as the animals'")
    check('.str(at ? " (another function)" : " (not found)")' in sl, "  a loop left in chunks is named, with why")
    sp = body_of(src, "static bool SerialPathAt(u32 at, int n)")
    check(sp != "", "SerialPathAt")
    check("if (call[0] != 0xE8" in sp and "if (f < g_textStart || f + 0x90 > g_textEnd) return false;" in sp,
          "  the signature's last byte a call, to a place inside the game's code")
    check("p[k] == 0x45 && p[k + 1] == 0x3B && p[k + 2] == 0xC1 && p[k + 3] == 0x0F && p[k + 4] == 0x8E" in sp,
          "  the count against the chunk size (cmp r8d, r9d / jle)")
    check("p[k] == 0x48 && p[k + 1] == 0xC1 && p[k + 2] == 0xF8 && p[k + 3] == 0x04 && p[k + 4] == 0x83" in sp
          and "&& p[k + 5] == 0xF8 && p[k + 6] == 0x01 && p[k + 7] == 0x0F && p[k + 8] == 0x84" in sp,
          "  the pool's size against 1 (sar rax, 4 / cmp eax, 1 / je)")
    check("return ja == jb;" in sp, "  both to the same place (its one-thread path)")
    ip = body_of(src, "static void InstallPersonSerial()")
    check(ip != "", "InstallPersonSerial")
    # (0.8.3: on by default, the 0.8.2 reports' drifts began in the moves; =0 in chunks as before)
    check('if (!(GetEnvironmentVariableA("MPFEVER_PERSONSERIAL", v, 3) > 0 && v[0] == \'0\'))' in ip
          and 'if (!(GetEnvironmentVariableA("MPFEVER_VEHSERIAL", v, 3) > 0 && v[0] == \'0\'))' in ip,
          "  on unless MPFEVER_PERSONSERIAL=0 / MPFEVER_VEHSERIAL=0 (0.8.3; off: in chunks, as before)")
    check(ip.count("LogLine(a);") == 4 and ip.index("LogLine(a);") > ip.index("MPFEVER_PERSONSERIAL")
          and '"persons moved in chunks (MPFEVER_PERSONSERIAL=0)"' in ip and '"vehicles moved in chunks (MPFEVER_VEHSERIAL=0)"' in ip,
          "  a log line either way")
    check("\"persons moved in one piece on the simulation's thread (\"" in ip and "\"vehicles moved in one piece on the simulation's thread (\"" in ip
          and '.dec(k).str(" of ").dec(np).str(" loops")' in ip and '"; in chunks: "' in ip, "  'persons/vehicles moved in one piece ... (k of 4 loops)'")
    check(ip.count("miss.s[miss.n] = 0;") == 2, "  (the names' text ended before it is copied)")
    of = body_of(src, "static void InstallOrderFixes()")
    a = of.find("Buf a; a.str(ok ? \"animals moved in one piece on the simulation's thread\" : \"animals: the pool's chunk size was not found (moved in chunks)\"); LogLine(a);")
    b = of.find("    InstallPersonSerial();\n")
    c = of.find("int moved = 0;")
    check(0 < a < b < c, "called right after the animals' block, in the same install")
    check(src.count("InstallPersonSerial();") == 1, "  once")
    check('if (GetEnvironmentVariableA("MPFEVER_NOANIMALSERIAL", 0, 0) == 0) {\n        u32 at = FindSigRva("' + ANIMALS + '");' in of,
          "the animals' block as it was")
    launcher = "".join(open(os.path.join(ROOT, "launcher", f), encoding="utf-8-sig").read() for f in os.listdir(os.path.join(ROOT, "launcher")) if f.endswith(".cs"))
    check("MPFEVER_PERSONSERIAL" not in launcher and "MPFEVER_VEHSERIAL" not in launcher, "nothing in the launcher sets them (test switches)")
    return src


def pe_view(path):
    """(.text bytes, its rva, the functions' (begin, end) from .pdata, the build stamp, read section by name)"""
    data = open(path, "rb").read()
    try:
        import pefile
        pe = pefile.PE(data=data, fast_load=True)
        stamp = pe.FILE_HEADER.TimeDateStamp
        secs = {s.Name.rstrip(b"\0").decode("ascii", "replace"): (s.VirtualAddress, s.Misc_VirtualSize, s.PointerToRawData, s.SizeOfRawData) for s in pe.sections}
        exc = pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
        exc = (exc.VirtualAddress, exc.Size)
    except ImportError:
        # (without pefile: the same fields read from the headers)
        lfanew = struct.unpack_from("<I", data, 0x3c)[0]
        stamp = struct.unpack_from("<I", data, lfanew + 8)[0]
        nsec, optsize = struct.unpack_from("<H", data, lfanew + 6)[0], struct.unpack_from("<H", data, lfanew + 20)[0]
        opt = lfanew + 24
        exc = struct.unpack_from("<II", data, opt + 112 + 3 * 8)
        secs = {}
        for i in range(nsec):
            o = opt + optsize + 40 * i
            name = data[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
            vsize, va, rsize, raw = struct.unpack_from("<IIII", data, o + 8)
            secs[name] = (va, vsize, raw, rsize)

    def section(name):
        va, vsize, raw, rsize = secs[name]
        return va, data[raw:raw + min(vsize, rsize)]

    tva, text = section(".text")
    rva_r, rdata = section(".rdata")
    pva, pdata = section(".pdata")
    pd = pdata[exc[0] - pva:][:exc[1]]
    funcs = sorted((b, e) for b, e, _ in struct.iter_unpack("<III", pd[:len(pd) // 12 * 12]) if b)
    return stamp, tva, text, rva_r, rdata, funcs


def serial_path_at(text, tva, at, n):
    """SerialPathAt of the module, in Python: the call's target when it has the one-thread path, else None"""
    k0 = at - tva + n - 1
    if text[k0] != 0xE8:
        return None
    f = at + n - 1 + 5 + struct.unpack_from("<i", text, k0 + 1)[0]
    if f < tva or f + 0x90 > tva + len(text):
        return None
    p = text[f - tva:f - tva + 0x90]
    a = b = -1
    for k in range(0, 0x90 - 13 + 1):
        if a < 0 and p[k:k + 5] == bytes([0x45, 0x3B, 0xC1, 0x0F, 0x8E]):
            a = k
        if a >= 0 and k > a and p[k:k + 9] == bytes([0x48, 0xC1, 0xF8, 0x04, 0x83, 0xF8, 0x01, 0x0F, 0x84]):
            b = k
            break
    if a < 0 or b < 0:
        return None
    ja = f + a + 9 + struct.unpack_from("<i", p, a + 5)[0]
    jb = f + b + 13 + struct.unpack_from("<i", p, b + 9)[0]
    return (f, ja) if ja == jb else None


def pattern(sig):
    return b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in sig.split())


def game_checks(src):
    if not os.path.exists(GAME):
        print("(the game is not installed here: its bytes not checked)")
        return
    stamp, tva, text, rva_r, rdata, funcs = pe_view(GAME)
    if stamp != BUILD_40425:
        print(f"(another game build, stamp {stamp:#x}: its bytes not checked; the module checks each place itself)")
        return
    starts = [f[0] for f in funcs]

    def func_of(rva):
        i = bisect.bisect_right(starts, rva) - 1
        return funcs[i] if i >= 0 and funcs[i][0] <= rva < funcs[i][1] else None

    names = []
    for m in re.finditer(re.escape(b"ThreadPool::LoopImpl"), rdata):
        s = m.start()
        while s > 0 and rdata[s - 1] != 0:
            s -= 1
        names.append(rva_r + s)
    check(len(names) >= 1, "the game: the text 'ThreadPool::LoopImpl' is there")

    def names_loopimpl(fn):
        if not fn:
            return False
        fb = text[fn[0] - tva:fn[1] - tva]
        for j in range(len(fb) - 7):
            if fb[j] in (0x48, 0x4C) and fb[j + 1] == 0x8D and (fb[j + 2] & 0xC7) == 0x05:
                if fn[0] + j + 7 + struct.unpack_from("<i", fb, j + 3)[0] in names:
                    return True
        return False

    sites = []
    for name, sig, chunk, rva in PERSONS + VEHICLES:
        n = len(sig.split())
        hits = [tva + m.start() for m in re.finditer(pattern(sig), text, re.S)]
        check(hits == [rva], f"the game: {name}: its signature once in .text, at {rva:#x}", [hex(h) for h in hits])
        if hits != [rva]:
            continue
        sites.append((name, rva))
        imm = struct.unpack_from("<I", text, rva - tva + 2)[0]
        check(text[rva - tva:rva - tva + 2] == bytes([0x41, 0xB9]) and imm == chunk, f"  mov r9d, {chunk:#x} (its chunk size)", hex(imm))
        sp = serial_path_at(text, tva, rva, n)
        check(sp is not None, "  its call to a loop with the one-thread path (both tests to the same place)")
        if sp is None:
            continue
        f, path = sp
        fn = func_of(f)
        check(fn is not None and fn[0] == f, "  the call goes to the start of a function (.pdata)", fn)
        # the one-thread path: the loop's body called once, for the whole count (mov r9d, r8d / xor r8d, r8d ... call), or a body
        # that takes the whole count itself (mov rcx, r10 / call: land vehicles 1)
        q = text[path - tva:path - tva + 24]
        whole = q[:6] == bytes([0x45, 0x8B, 0xC8, 0x45, 0x33, 0xC0]) and 0xE8 in q[6:20]
        check(whole or q[:4] == bytes([0x49, 0x8B, 0xCA, 0xE8]), "  its one-thread path calls the loop's body once, for the whole count", q.hex())
        check(names_loopimpl(fn), "  the function names 'ThreadPool::LoopImpl' (lea rip-relative)")
    # the module's test: yes to the animals' loop, no to the calls of other functions
    a_hits = [tva + m.start() for m in re.finditer(pattern(ANIMALS), text, re.S)]
    check(len(a_hits) == 1 and serial_path_at(text, tva, a_hits[0], len(ANIMALS.split())) is not None,
          "the module's test says yes to the animals' loop too (the same pool loop, patched since 0.5.12)")
    calls = []
    lo, hi = 0xaf0000, 0xb30000
    for m in re.finditer(re.escape(bytes([0xE8])), text[lo - tva:hi - tva]):
        at = lo + m.start()
        tgt = at + 5 + struct.unpack_from("<i", text, at - tva + 1)[0]
        fn = func_of(tgt)
        if fn and fn[0] == tgt:
            calls.append(at)
    yes = [c for c in calls if serial_path_at(text, tva, c, 1) is not None]
    check(len(calls) - len(yes) > 100 and all(names_loopimpl(func_of(serial_path_at(text, tva, c, 1)[0])) for c in yes),
          "  and to the pool's loops only: no to the calls of other functions near the persons' systems", (len(calls), len(yes)))
    # the patched bytes are in no other signature of the module: its later searches still find theirs
    sigs = set(re.findall(r'"((?:[0-9A-F?]{2} ){3,}[0-9A-F?]{2})"', src))
    for line in open(SIGS, encoding="utf-8"):
        m = re.search(r"((?:[0-9A-F?]{2} )+[0-9A-F?]{2})\s*$", line.strip())
        if m and not line.startswith("#"):
            sigs.add(m.group(1))
    mine = set(s for _, s, _, _ in PERSONS + VEHICLES) | {ANIMALS}
    overlap = []
    for s in sigs - mine:
        if len(s.split()) < 4:
            continue
        for m in re.finditer(pattern(s), text, re.S):
            lo, hi = tva + m.start(), tva + m.end()
            for name, rva in sites:
                if lo < rva + 6 and hi > rva + 2:
                    overlap.append((name, hex(lo), s[:40]))
    check(len(sigs) > 100 and overlap == [], "the eight chunk sizes are in no other signature of the module", overlap)


def kit_checks():
    """the game test's events (tools/recplay_drift_big.txt): events the launcher's recplay knows, four checks of 15 minutes at x4"""
    mf = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
    rp = mf[mf.index("void RecPlayEvents(string[] lines, Func<string, bool> appliedEverywhere)"):]
    rp = rp[:rp.index("\n        }\n")]
    known = set(re.findall(r'case "([a-z]+)":', rp))
    path = os.path.join(ROOT, "tools", "recplay_drift_big.txt")
    check(os.path.exists(path), "the game test's events: tools/recplay_drift_big.txt")
    if not os.path.exists(path):
        return
    ev = [l.split("\t") for l in open(path, encoding="utf-8").read().splitlines() if l and not l.startswith("#")]
    check(len(known) >= 8 and all(e[0] in known for e in ev), "  every event one the launcher's recplay knows", [e[0] for e in ev if e[0] not in known])
    check(["speed", "4"] in ev and ev.count(["run", "900"]) == 4 and ev.count(["hash"]) == 4 and ev.index(["speed", "4"]) < ev.index(["run", "900"]),
          "  x4, four times 15 minutes with a check after each, no action", ev)
    check(not any(e[0] in ("msg", "waitact") for e in ev), "  (no action at all)")


def main():
    src = source_checks()
    kit_checks()
    game_checks(src)
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
