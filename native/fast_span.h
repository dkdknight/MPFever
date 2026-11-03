// The faster bitmap span (0.6.10): the decisions of mpfever_native.cpp's span fill detour (see "the faster bitmap span"
// there), kept apart so that tests/test_fastspan.py builds them and runs them beside the game's own bytes. After TPF3-MP's
// "fast-bitmap-span" (Juliansgith/Transport-Fever-3-Multiplayer-Mod, MIT: crates/tpf3mp-hook/src/fastbitmap.rs, commit
// add4a87, 2026-10-29; made again here).
//
// The game's function (rcx the rasterizable, edx x, r8d y, r9d count): start = y * width (+0x10) + x and end = start + count
// in 32 bits, nothing when start >= end; else bits [start, end) of the std::vector<uint32_t> at [[rcx+8]] set one at a time
// (bit i: bit i & 31 of word i >> 5), and false. Here the same bits are set a whole word at a time; a span starting below bit 0
// goes to the game's own loop (whatever it does there). The answer is false either way.
//
// Before including: win.h (its types).
#pragma once

typedef u8 (*FsOrigF)(u64, i32, i32, i32);

// bits [start, start + count) of the words at bits
static void FsSetBits(u32* bits, u64 start, u64 count)
{
    u64 end = start + count, i = start;
    if (i & 31) {
        u64 to = (i | 31) + 1;
        if (to > end) to = end;
        u64 len = to - i;
        u32 ones = len >= 32 ? 0xFFFFFFFFu : ((1u << len) - 1);
        bits[i >> 5] |= ones << (i & 31);
        i = to;
    }
    while (end - i >= 32) { bits[i >> 5] = 0xFFFFFFFFu; i += 32; }
    if (i < end) bits[i >> 5] |= (1u << (end - i)) - 1;
}

// the span fill: the game's answer and bits, a span below bit 0 handed to orig
static u8 FsFill(u64 self, i32 x, i32 y, i32 count, FsOrigF orig, volatile long* fast, volatile long* handed)
{
    i32 width = *(const i32*)(self + 0x10);
    i32 start = (i32)((u32)y * (u32)width + (u32)x);
    i32 end = (i32)((u32)start + (u32)count);
    if (start >= end) return 0;
    if (start < 0) {
        if (handed) (*handed)++;
        return orig(self, x, y, count);
    }
    u64 vec = *(const u64*)(self + 8);
    u32* bits = *(u32* const*)vec;
    FsSetBits(bits, (u64)start, (u64)(u32)(end - start));
    if (fast) (*fast)++;
    return 0;
}
