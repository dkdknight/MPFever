// Memory near the game's code (0.9.5, #459): the decisions of mpfever_native.cpp's AllocNear, kept apart so that
// tests/test_nearalloc095.py builds them and runs them against reserved address ranges.
//
// The native module's stubs are reached from the game's code with a rel32 jump (and jump back the same way), so their memory
// must lie within +-2 GB of the game's image. Since 0.6 the module took the first place it could, in steps of 1 MB, from
// 256 MB to 1.75 GB BELOW the image's start, and nothing else. On 2026-11-21 Flubi's second start of the game (30 s after his
// first, whose module found a place there) found none in that whole band: every hook that needs one stayed off (order fixes,
// fresh ids, player word, stop point, smooth pacing, the module builder guard, industry demand...), his game said "nat off",
// the host's game drifted from his friend's and the session resynchronised again and again. Something of his game's process
// had taken the band below its image.
//
// Now the first pass is unchanged (same places, same order: a game that found one before finds the same one); when it finds
// nothing, the free regions (VirtualQuery) are searched: ABOVE the image (from its end up to 1.75 GB after its start), then the
// 256 MB just below it that the first pass leaves out. A place found there is as near as the first pass's (within 1.75 GB of
// every byte of the image). scan = false: the first pass alone, as before (MPFEVER_NEARSCAN=0).
//
// Before including: win.h (its types, VirtualAlloc, VirtualQuery).
#pragma once

static const uptr NA_FAR = 0x70000000;      // the farthest place from the image's start, below or above (1.75 GB)
static const uptr NA_NEAR = 0x10000000;     // the first pass starts this far below the image's start (256 MB)

// the first free, 64 KB-aligned place of [lo, hi) where VirtualAlloc gives size bytes (executable), or 0
static u8* NaTryRange(uptr lo, uptr hi, u64 size)
{
    uptr a = (lo + 0xFFFF) & ~(uptr)0xFFFF;
    int regions = 0;
    while (a < hi && regions++ < 100000) {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery((void*)a, &mi, sizeof(mi))) break;
        uptr re = (uptr)mi.BaseAddress + mi.RegionSize;
        if (re <= a) break;
        if (mi.State == 0x10000 /* MEM_FREE */) {
            int tries = 0;
            for (uptr s = (a + 0xFFFF) & ~(uptr)0xFFFF; s + size <= re && s + size <= hi && tries < 16; s += 0x10000, tries++) {
                u8* m = (u8*)VirtualAlloc((void*)s, size, 0x3000 /* MEM_COMMIT|MEM_RESERVE */, 0x40 /* PAGE_EXECUTE_READWRITE */);
                if (m) return m;
            }
        }
        a = (re + 0xFFFF) & ~(uptr)0xFFFF;
    }
    return 0;
}

// size bytes of executable memory within reach of the image [base, imageEnd); *how: 1 the first pass (below, as before),
// 2 above the image, 3 just below it, 0 none
static u8* NearAlloc(uptr base, uptr imageEnd, u64 size, bool scan, int* how)
{
    *how = 0;
    for (u64 d = NA_NEAR; d < NA_FAR; d += 0x100000) {
        u8* want = (u8*)((base > d ? base - d : 0) & ~0xFFFFull);
        if (!want) break;
        u8* m = (u8*)VirtualAlloc(want, size, 0x3000, 0x40);
        if (m) { *how = 1; return m; }
    }
    if (!scan) return 0;
    if (imageEnd < base) imageEnd = base;
    u8* m = NaTryRange(imageEnd, base + NA_FAR, size);
    if (m) { *how = 2; return m; }
    m = NaTryRange(base > NA_NEAR ? base - NA_NEAR : 0x10000, base, size);
    if (m) { *how = 3; return m; }
    return 0;
}

// what the first pass's band holds (for the log): free bytes, the allocations met, and the largest one (the part of it in the
// band: its start, size, type 0x1000000 an image, 0x40000 a mapped file, 0x20000 private memory; state 0x2000 reserved only,
// 0x1000 committed)
struct NaBand { u64 freeBytes; u32 allocations; u32 bigType; uptr bigAt; u64 bigSize; u32 bigState; u32 pad; };
static NaBand NearBandInfo(uptr base)
{
    NaBand r = { 0, 0, 0, 0, 0, 0, 0 };
    uptr lo = base > NA_FAR ? base - NA_FAR : 0x10000, hi = base > NA_NEAR ? base - NA_NEAR : 0;
    uptr a = lo, curAlloc = 0, curAt = 0;
    u64 curSize = 0;
    int regions = 0;
    while (a < hi && regions++ < 100000) {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery((void*)a, &mi, sizeof(mi))) break;
        uptr rb = (uptr)mi.BaseAddress, re = rb + mi.RegionSize;
        if (re <= a) break;
        uptr s = rb < lo ? lo : rb, e = re > hi ? hi : re;
        if (mi.State == 0x10000) { r.freeBytes += e - s; curAlloc = 0; }
        else {
            if ((uptr)mi.AllocationBase != curAlloc || !curAlloc) { curAlloc = (uptr)mi.AllocationBase; curAt = s; curSize = 0; r.allocations++; }
            curSize += e - s;
            if (curSize > r.bigSize) { r.bigAt = curAt; r.bigSize = curSize; r.bigType = mi.Type; r.bigState = mi.State; }
        }
        a = re;
    }
    return r;
}
