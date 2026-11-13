"""Offline test: the same account changes on every game (0.8.6, #150; ClearOthersIn, ClearPosSeen and InstallClearSame in
native/mpfever_native.cpp, switch MPFEVER_CLEARSAME).

ClearPositions (0xcd6110 on build 40425) empties a vector of a company's ecs::component::Account (the money shown above the
buildings) and tells the world's engine that component changed (listeners, the entity's change counter, the change log the copy for
the interface replays into the state the simulation runs next). Before the copy, the native module emptied every company but THIS
machine's: the host emptied the client's account and the client the host's, other changes in each game's simulation state at every
iteration (two games of one company per player parted at an animal's octree node, step 135926 of "Test Gameplay", 6 runs of 10; 0 of 10 with this).
  - the calls: every company once, the smallest entity first, at the start of an iteration and before the copy, the same on every
    game (a model of the C++ below, run for the host and the client of the drifting session);
  - this machine's figures put back after its own call: the clear only moves the vector's end to its begin (ClearPositions'
    bytes checked before the splice), ClearPosSeen notes begin and end inside the call, on the native module's own thread only;
  - put back only when the vector is still the one seen (begin unchanged, end at begin);
  - MPFEVER_CLEARSAME=0, or ClearPositions of another shape: as before (every company but this machine's, the word left to the
    engine at the start of an iteration);
  - counted in the minute's "order fixes" line.
Run: python tests/test_clearsame086.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
N = os.path.join(HERE, "..", "native")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(os.path.join(N, "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
f = src[src.index("static void ClearOthersIn(u8* gs, bool learn)"):]
f = f[:f.index("\n}\n")]
same = f[f.index("if (g_clearSame == 1) {"):f.index("        return;\n    }\n    for (int i = 0; i < k; i++) {")]


# a model of the C++: the calls one game makes (entity, kept) at one place
def calls(others, mine, word, learn, clear_same):
    lst = [e for e in others if e] + [mine, word]
    out = []
    if clear_same:
        s = []
        for e in lst:
            if e and e not in s:
                s.append(e)
        s.sort()
        for e in s:
            out.append((e, (not learn) and e == mine))
        return out
    seen = []
    for e in lst:
        if not e or e in seen:
            continue
        seen.append(e)
        if (e == word) if learn else (e == mine):
            continue
        out.append((e, False))
    return out


# the drifting session (native.log of 2026-11-13 04:02): host plays 31434 (the savegame's company), client 108734, an AI 46534;
# at the end of an iteration the client's state holds its own company in the word
H = dict(others=[46534, 108734], mine=31434)
Cl = dict(others=[31434, 46534], mine=108734)
for learn, wordH, wordC in ((True, 31434, 31434), (False, 31434, 108734)):
    old_h = [e for e, _ in calls(H["others"], H["mine"], wordH, learn, False)]
    old_c = [e for e, _ in calls(Cl["others"], Cl["mine"], wordC, learn, False)]
    new_h = [e for e, _ in calls(H["others"], H["mine"], wordH, learn, True)]
    new_c = [e for e, _ in calls(Cl["others"], Cl["mine"], wordC, learn, True)]
    where = "start of an iteration" if learn else "before the copy"
    if not learn:
        check(f"before (the drift): {where}, the host and the client changed other accounts", old_h != old_c)
    check(f"now: {where}, the same calls in the same order on both games {new_h}", new_h == new_c == sorted(set(new_h)))
    check(f"now: {where}, every company once", sorted(new_h) == [31434, 46534, 108734])
kept_h = [e for e, k in calls(H["others"], H["mine"], 31434, False, True) if k]
kept_c = [e for e, k in calls(Cl["others"], Cl["mine"], 108734, False, True) if k]
check("before the copy, each game puts back its own company's figures only", kept_h == [31434] and kept_c == [108734])
check("at the start of an iteration, nothing is put back", not [e for e, k in calls(H["others"], H["mine"], 31434, True, True) if k])

# the C++ itself
check("the C++ dedups and sorts (insertion sort, the smallest entity first)", "if (!dup) s[m++] = e;" in same and "while (j >= 0 && s[j] > x)" in same)
check("  keeps only this machine's company, before the copy", "bool keep = !learn && e == mine;" in same)
check("  puts the end back only on the vector seen, still emptied", "if (c && *(u64*)c == g_keepBegin && *(u64*)(c + 8) == g_keepBegin && g_keepEnd >= g_keepBegin) {" in same and "*(u64*)(c + 8) = g_keepEnd;" in same)
check("  the old path kept below it", "if (learn ? e == word : e == mine) continue;" in f[f.index("        return;\n    }\n    for (int i = 0; i < k; i++) {"):])
seen = src[src.index("static void ClearPosSeen(SavedRegs* r)"):]
seen = seen[:seen.index("\n}\n")]
check("ClearPosSeen: on the native module's own thread, for the company asked, the component in rax, engaged", "(long)GetCurrentThreadId() != g_keepTid" in seen and "(u32)r->rbx != (u32)want" in seen and "u8* c = (u8*)r->rax;" in seen and "!c[0x18]" in seen)
inst = src[src.index("static void InstallClearSame()"):]
inst = inst[:inst.index("\n}\n")]
check("InstallClearSame: switch MPFEVER_CLEARSAME=0", 'GetEnvironmentVariableA("MPFEVER_CLEARSAME", v, 3) > 0 && v[0] == \'0\'' in inst)
check("  ClearPositions' bytes checked (the component at +0x8e, the clear end = begin at +0xb2) before the splice",
      "0x48, 0x8B, 0xF8, 0x48, 0x89, 0x44, 0x24, 0x30" in inst and "0x48, 0x89, 0x47, 0x08" in inst
      and "memcmp(f + 0x8e, site, sizeof(site)) == 0 && memcmp(f + 0xb2, clr, sizeof(clr)) == 0" in inst)
check("  spliced at +0x8e (8 bytes, no branch)", "Splice(mem, (u32)((u64)f + 0x8e - g_base), (int)sizeof(site), ClearPosSeen)" in inst)
check("  off (as before) when not spliced", "g_clearSame = ok ? 1 : 0;" in inst)
check("installed once ClearPositions is found, before the pre-iteration detour", "if (g_clearPos) InstallClearSame();\n        if (InstallDetour(RVA_PREITER" in src)
check("counted in the minute's line", '"; own figures put back "' in src)
check("  with the figures put back that were not empty (the popups still reach the interface) and the largest",
      "if (g_keepEnd > g_keepBegin) {" in same and "g_clearSameFull++;" in same and '.str(" (with figures ").dec(g_clearSameFull)' in src)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
