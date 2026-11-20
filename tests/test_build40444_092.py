"""Test: MPFever finds every place of its native module again in Transport Fever 3's build 40444 (the game update of
2026-11-19, Steam link timestamp 6af6fd97), and still in 40425 (0.9.2).

The bug (reports #437 to #440, every one on 40444): MPFever 0.9.1 found its 100 signatures, but its native.log said
"interface tools 9/12, player word readings 55/59", "game autosave: its test NOT found" and "tools' company: ... bulldozer OFF".
In 40444 Urban Games changed UI::LaneModifier::Apply (5019 -> 5219 bytes: its three CommandList::Add calls, two readings of
the local-player word), CGameUI grew (the autosave test reads +0x1188 and +0xe40 instead of +0x1170 and +0xe38, a reading of the
word now goes to edi instead of ebx), an entity window's builtin got another stack frame, and so did the bulldozer's step
(lea rbp,[rax-0xf08], 0xed8 before). So in separate companies the lane modifier's and the bulldozer's builds were the savegame's
company's, the lane modifier's builds were not held as a player's, and the game saved on its own in every session again.
The launcher also called 40444 "unknown build" and told every player in the chat that MPFever was not adapted to it.

The fixes, each with its switch:
  - native/mpfever_sigs.txt: seven more places, found again in 40444 by the call graph (the 45 Add calls of the two builds pair
    up one for one) and the functions' readings of +0x20C, signatures by tools/mksigs.py (each once in 40444, never in 40425);
    tools/mksigs.py make keeps them;
  - the autosave test: its signature leaves the offsets out, the counter's offset is read from the test's own cmp
    (MPFEVER_GASFIXED=1: 40425's signature and offset);
  - the bulldozer's step: slot 5 of the vtable its constructor stores, when its signature finds nothing (MPFEVER_BULLVT=0: off);
  - stops and signals at the click (0.8.9): read on 40444 too, its build command and proposal copies are the same code
    (MPFEVER_EO40444=0: 40425 only);
  - the launcher: 40444 among the known builds, named in the report header (Steam).

Without the game: the code and the files. With the game installed next to MPFever (the user's PC; not on GitHub's CI) the
executable is read: on 40444 the signatures of 0.9.1 miss exactly those places (the bug), those of 0.9.2 find every one (the
fix). MPFEVER_OLDEXE=<a 40425 TransportFever3.exe> (the GOG copy, say) checks that the new lines never match there.
Run: python tests/test_build40444_092.py
"""
import os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


nat = read("native", "mpfever_native.cpp")
sigs = read("native", "mpfever_sigs.txt").split("\n")
mk = read("tools", "mksigs.py")
mf = read("launcher", "MainForm.cs")
rep = read("launcher", "Reporter.cs")

NEW_LINES = [
    "uisite 0 48 8D 4D 80 E8 ?? ?? ?? ?? 90 48 8B 8D 58 01 00 00",
    "uisite 0 48 8D 4C 24 58 E8 ?? ?? ?? ?? 90 E9 ?? ?? ?? ?? 48 98",
    "uisite 0 48 8D 4C 24 58 E8 ?? ?? ?? ?? 90 48 8B 4D 70",
    "site20c 20 8 0 7 0 44 8B 80 0C 02 00 00 48 8D 95 B0 02 00 00",
    "site20c 20 8 0 7 0 44 8B 80 0C 02 00 00 48 8D 94 24 A0 04 00 00",
    "site20c 20 7 0 6 0 8B B8 0C 02 00 00 B9 E0 06 00 00 E8",
    "site20c 4 1 0 6 0 8B 88 0C 02 00 00 89 4C 24 78 48 8D 54 24 78",
]
mark = next((i for i, l in enumerate(sigs) if l.startswith("# (0.9.2) build 40444")), None)
check(mark is not None, "mpfever_sigs.txt: a block for build 40444")
block = [l for l in sigs[mark:] if l.strip() and not l.startswith("#")] if mark is not None else []
check(block == NEW_LINES, "  its seven places: LaneModifier::Apply's three Add calls, four readings of the local-player word")
old_lines = [l for l in sigs[:mark] if l.strip() and not l.startswith("#")] if mark is not None else []
check(len(old_lines) == 100, "  the 100 places of before kept above it (40425 and the GOG/Epic copies still read them): %d" % len(old_lines))
check('l.startswith("# (0.9.2) build 40444")' in mk and "lines += [l for l in kept[at:] if l.strip()]" in mk,
      "tools/mksigs.py make keeps the block (the 40420 executable has none of those places)")

# the autosave test
inst = nat[nat.index("static void InstallNoGameAutosave()"):]
inst = inst[:inst.index("\n}\n")]
check('FindSigRva("80 BE ?? ?? 00 00 00 75 ?? 48 3B 86 ?? ?? 00 00 7D ?? 48 8B CE E8")' in inst,
      "the autosave test found without its offsets")
check("u32 off = *(u32*)(g_base + at + 12);" in inst and "g_gasCountedOff = off;" in inst and "(i64*)(ui + g_gasCountedOff)" in nat,
      "  the time counted at the offset the test reads")
check('GetEnvironmentVariableA("MPFEVER_GASFIXED", v, 3) > 0 && v[0] == \'1\'' in inst
      and 'FindSigRva("80 BE 70 11 00 00 00 75 ?? 48 3B 86 38 0E 00 00 7D ?? 48 8B CE E8")' in inst,
      "  MPFEVER_GASFIXED=1: 40425's signature and offset, as before")

# the bulldozer
tc = nat[nat.index("static u32 BulldozerStepByVtable(u32 store)"):]
bv = tc[:tc.index("\n}\n")]
tc = tc[tc.index("static void InstallToolCompany()"):]
tc = tc[:tc.index("\n}\n")]
check("if (!step && i == 5 && bullVt) step = BulldozerStepByVtable(FindSigRva(t.store));" in tc,
      "the bulldozer's step from its vtable, only when its signature finds nothing")
check("uptr fn = *(const uptr*)(vt + 5 * 8);" in bv and "{ 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x20 }" in bv
      and "if (q[0] != 0x48 || q[1] != 0x8D || q[2] != 0x05) return 0;" in bv,
      "  slot 5 of the vtable the constructor's lea names, starting with the 7 bytes the splice moves")
check('GetEnvironmentVariableA("MPFEVER_BULLVT", v, 3) == 1 && v[0] == \'0\') bullVt = false;' in tc, "  MPFEVER_BULLVT=0: the signature only")

# stops and signals at the click
check("(g_buildStamp == 0x6ad9ce10u || (eo44 && g_buildStamp == 0x6af6fd97u))" in nat
      and 'GetEnvironmentVariableA("MPFEVER_EO40444", v, 3) == 1 && v[0] == \'0\'' in nat,
      "stops and signals at the click read on 40444 too (MPFEVER_EO40444=0: 40425 only)")

# the launcher
check('KnownBuilds = { "40408", "40420", "40423", "40425", "40444" }' in mf, "the launcher knows 40444 (no warning in the chat)")
check('stamp == 0x6af6fd97 ? "40444" : stamp == 0x6ad9ce10 ? "40425"' in rep and 'stamp == 0x6af6fd97 ? "40444" : stamp == 0x6ad9ce10 || stamp == 0x6ad9e27e ? "40425"' in rep,
      "  the report header and the build tag name it")
check('case "6af6fd97": case "6ad9ce10":' in rep, "  Steam's executable")


# ---- the executables, when there
def text_of(path):
    d = open(path, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    stamp = struct.unpack_from("<I", d, pe + 8)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    sec = pe + 24 + opt
    for i in range(nsec):
        s = sec + 40 * i
        if d[s:s + 5] == b".text":
            va, raw, rsz = struct.unpack_from("<I", d, s + 12)[0], struct.unpack_from("<I", d, s + 20)[0], struct.unpack_from("<I", d, s + 16)[0]
            return stamp, va, d[raw:raw + rsz], d
    raise ValueError("no .text")


def hits(text, sig, limit=2):
    toks = sig.split()
    pat = [None if t == "??" else int(t, 16) for t in toks]
    # the longest run of fixed bytes is looked for, the rest compared
    best, cur, start = (0, 0), 0, 0
    for i, b in enumerate(pat + [None]):
        if b is None:
            if cur > best[1]: best = (start, cur)
            cur = 0
        else:
            if cur == 0: start = i
            cur += 1
    lit = bytes(pat[best[0]:best[0] + best[1]])
    out, k = [], text.find(lit)
    while k >= 0:
        s = k - best[0]
        if s >= 0 and s + len(pat) <= len(text) and all(p is None or text[s + j] == p for j, p in enumerate(pat)):
            out.append(s)
            if len(out) >= limit: break
        k = text.find(lit, k + 1)
    return out


def sig_of(line):
    p = line.split()
    return p[0], (" ".join(p[6:]) if p[0] == "site20c" else " ".join(p[2:]))


def found(text, lines):
    res = {}
    for l in lines:
        k, s = sig_of(l)
        res.setdefault(k, []).append(len(hits(text, s)) == 1)
    return res


exe = os.path.join(ROOT, "..", "TransportFever3.exe")
if os.path.exists(exe):
    stamp, va, text, img = text_of(exe)
    print("(the installed game: stamp %08x)" % stamp)
    if stamp == 0x6af6fd97:
        before = found(text, old_lines)
        miss_ui = before["uisite"].count(False); miss_20 = before["site20c"].count(False)
        other = sum(v.count(False) for k, v in before.items() if k not in ("uisite", "site20c"))
        check(miss_ui == 3 and miss_20 == 4 and other == 0,
              "the bug: 0.9.1's signatures miss 3 interface tools and 4 readings on 40444, nothing else (%d, %d, %d)" % (miss_ui, miss_20, other))
        after = found(text, old_lines + block)
        check(after["uisite"].count(True) == 12 and after["site20c"].count(True) == 59,
              "the fix: 12 interface tools and 59 readings found, as on 40425 (%d, %d)" % (after["uisite"].count(True), after["site20c"].count(True)))
        check(all(after[k][0] for k in after if k not in ("uisite", "site20c", "simcall")) and all(after.get("simcall", [True])),
              "  every other place found once")
        check(not hits(text, "80 BE 70 11 00 00 00 75 ?? 48 3B 86 38 0E 00 00 7D ?? 48 8B CE E8"), "the bug: 40425's autosave signature finds nothing")
        h = hits(text, "80 BE ?? ?? 00 00 00 75 ?? 48 3B 86 ?? ?? 00 00 7D ?? 48 8B CE E8")
        check(len(h) == 1 and struct.unpack_from("<I", text, h[0] + 12)[0] == 0xe40, "the fix: the test found once, its counter at +0xe40")
        step = "48 8B C4 48 89 58 20 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 28 F1 FF FF"
        store = "48 8D 05 ?? ?? ?? ?? 49 89 06 49 89 76 20 41 89 5E 28 48 8B 85 C8 01 00 00"
        check(not hits(text, step), "the bug: the bulldozer's step signature finds nothing")
        s = hits(text, store)
        ok = len(s) == 1
        if ok:
            rva = va + s[0]
            vt = rva + 7 + struct.unpack_from("<i", text, s[0] + 3)[0]
            base = struct.unpack_from("<Q", img, struct.unpack_from("<I", img, 0x3c)[0] + 24 + 24)[0]
            # (the vtable's slot, read through the file: .rdata's raw offset from its section header)
            pe = struct.unpack_from("<I", img, 0x3c)[0]
            nsec = struct.unpack_from("<H", img, pe + 6)[0]; opt = struct.unpack_from("<H", img, pe + 20)[0]
            slot = None
            for i in range(nsec):
                sh = pe + 24 + opt + 40 * i
                sva, ssz, sraw = struct.unpack_from("<I", img, sh + 12)[0], struct.unpack_from("<I", img, sh + 8)[0], struct.unpack_from("<I", img, sh + 20)[0]
                if sva <= vt + 40 < sva + ssz:
                    slot = struct.unpack_from("<Q", img, sraw + vt + 40 - sva)[0] - base
            ok = slot is not None and text[slot - va:slot - va + 7] == bytes.fromhex("488BC448895820")
            print("    (the bulldozer's step at %#x)" % (slot or 0))
        check(ok, "the fix: slot 5 of the bulldozer's vtable is its step (mov rax,rsp; mov [rax+20h],rbx)")
    else:
        print("(not build 40444: its checks left out)")
        after = found(text, old_lines + block)
        check(after["uisite"].count(True) >= 12 and after["site20c"].count(True) >= 59, "the installed build: every interface tool and reading found")
else:
    print("(the game is not installed next to MPFever: its code not checked)")

old = os.environ.get("MPFEVER_OLDEXE")
if old and os.path.exists(old):
    stamp, va, text, img = text_of(old)
    print("(MPFEVER_OLDEXE: stamp %08x)" % stamp)
    check(not any(hits(text, sig_of(l)[1]) for l in block), "  the 40444 lines never match in that build")
    f = found(text, old_lines)
    check(f["uisite"].count(True) == 12 and f["site20c"].count(True) == 59, "  its own places all found as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
