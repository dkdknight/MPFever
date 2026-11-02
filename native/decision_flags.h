// The platform-decision flags of the two game states (0.6.8): the copy of mpfever_native.cpp's Replicate detour (see "the
// platform-decision flag" there), kept apart so that tests/test_decisionflags.py builds it with a stand-in for the game's
// memory. After TPF3-MP's decision-sync (MIT), made again here.
//
// An engine's per-entity table is a std::vector of 16-byte component masks at +0xc0 (begin) and +0xc8 (end), one per entity
// the engine ever had; MovePath's getter reads an entity's mask there without checking the entity against it. The flag is
// byte +0x70 of a vehicle's MovePath.
//
// Before including: win.h (its types).
#pragma once

typedef u64 (*MovePathF)(u64 engine, i32 entity);

// an entity inside the engine's per-entity table
static inline bool DsEntityIn(u64 eng, i32 ent)
{
    u64 b = *(u64*)(eng + 0xc0), e = *(u64*)(eng + 0xc8);
    return ent >= 0 && b && e >= b && (u64)ent < (e - b) / 16;
}

// each listed vehicle's flag from engine a's MovePath into engine z's, where both have one and they differ: the number copied
static long DsCopyFlags(u64 a, u64 z, const i32* ent, u64 n, MovePathF get)
{
    long copied = 0;
    for (u64 i = 0; i < n; i++) {
        i32 e = ent[i];
        if (!DsEntityIn(a, e) || !DsEntityIn(z, e)) continue;
        u64 from = get(a, e), to = get(z, e);
        if (!from || !to || from == to) continue;
        u8 v = *(volatile u8*)(from + 0x70);
        if (*(volatile u8*)(to + 0x70) != v) { *(volatile u8*)(to + 0x70) = v; copied++; }
    }
    return copied;
}
