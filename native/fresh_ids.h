// Fresh ids for the commands' new entities (0.6.8): the decisions of mpfever_native.cpp's AddEntity and replay splices (see
// "fresh ids" there), kept apart so that tests/test_freshids.py builds them with a stand-in for the game's memory.
//
// An engine's entities: a std::vector of 24-byte entries at +0x90 (begin) and +0x98 (end), one per entity it ever had (a new id
// past them is their count), and the free-id queue, a std::deque<int> at +0xd8 whose size is at +0xf8. ecs::Engine::AddEntity
// takes the queue's head while the queue is not empty, the count otherwise.
//
// Before including: win.h (its types).
#pragma once

// the engine's entity count (the id AddEntity gives when the queue is empty), or -1
static inline i64 FiCount(const u8* eng)
{
    u64 b = *(const u64*)(eng + 0x90), e = *(const u64*)(eng + 0x98);
    if (!b || e < b || (e - b) % 24) return -1;
    return (i64)((e - b) / 24);
}

// a copy of a state replays an "entity added" record (the id the source gave): the queue is to be passed over when the source
// gave a fresh id, the count, and the copy's queue is not empty (its head would be another id: the engine's check of the
// replayed id fails)
static inline bool FiReplayFresh(const u8* eng, i32 want)
{
    i64 n = FiCount(eng);
    return n >= 0 && want == n && *(const u64*)(eng + 0xf8) != 0;
}
