// The engine's entity lists in the two world states (0.8.18, #150): the decisions of mpfever_native.cpp's FamCheck (see "the
// systems' entity lists" there), kept apart so that tests/test_famorder0818.py builds them with a stand-in for the game's memory.
//
// An ecs::Engine (GameState+0x18) keeps its families at +0x18 (begin) / +0x20 (end): a std::vector of pointers to
// ecs::ComponentGroupFamilyN<C1..CN> objects, the lists of the entities that have components C1..CN. A family's list is a
// std::vector at +8 (begin) / +0x10 (end) of entries {u32 entity, i32 index of its C1 ... CN}: 4 * (N + 1) bytes. Its vtable's
// slot 2 adds an entity at the end (push_back), slot 3 removes one: the LAST entry is moved into its place (swap and pop). The
// systems run over their family's list in its order (AnimalMoveSystem draws its random numbers per run of 128 entries, seeded
// with the run's first index: an animal's draws depend on its place in the list). ComponentGroupFamilyNoListN keep no list.
//
// Before including: win.h (its types).
#pragma once

// the size of a family's entries from its RTTI type name (".?AV?$ComponentGroupFamily3@UAnimal@component@ecs@@..."):
// 4 * (N + 1) bytes; 0 for another class (ComponentGroupFamilyNoListN, another name), or a name not ended within max bytes
static inline u32 FoEntrySize(const char* name, int max)
{
    static const char K[] = "ComponentGroupFamily";
    for (int i = 0; i < max && name[i]; i++) {
        int j = 0;
        while (K[j] && i + j < max && name[i + j] == K[j]) j++;
        if (K[j]) continue;
        if (i + j + 1 >= max) return 0;
        char c = name[i + j];
        if (c < '1' || c > '9' || name[i + j + 1] != '@') return 0;
        return 4u * (u32)(c - '0' + 1);
    }
    return 0;
}

// the first entry where two lists of n entries of es bytes differ (n when they are alike)
static inline u64 FoFirstDiff(const u8* x, const u8* y, u64 n, u32 es)
{
    u64 bytes = n * es, i = 0;
    while (i + 8 <= bytes && *(const u64*)(x + i) == *(const u64*)(y + i)) i += 8;
    while (i < bytes && x[i] == y[i]) i++;
    return i >= bytes ? n : i / es;
}

// the first entry whose ENTITY differs (n when the two lists hold the same entities in the same order, whatever their
// components' places)
static inline u64 FoFirstEntDiff(const u8* x, const u8* y, u64 n, u32 es)
{
    for (u64 i = 0; i < n; i++) if (*(const u32*)(x + i * es) != *(const u32*)(y + i * es)) return i;
    return n;
}

static inline void FoSortU32(u32* a, u64 n)
{
    // (heapsort: no C runtime in the module)
    if (n < 2) return;
    for (u64 s = n / 2; s-- > 0;) {
        u64 r = s;
        for (;;) {
            u64 c = 2 * r + 1;
            if (c >= n) break;
            if (c + 1 < n && a[c + 1] > a[c]) c++;
            if (a[r] >= a[c]) break;
            u32 t = a[r]; a[r] = a[c]; a[c] = t; r = c;
        }
    }
    for (u64 e = n - 1; e > 0; e--) {
        u32 t = a[0]; a[0] = a[e]; a[e] = t;
        u64 r = 0;
        for (;;) {
            u64 c = 2 * r + 1;
            if (c >= e) break;
            if (c + 1 < e && a[c + 1] > a[c]) c++;
            if (a[r] >= a[c]) break;
            t = a[r]; a[r] = a[c]; a[c] = t; r = c;
        }
    }
}

// the entries k..n-1 of both lists hold the same entities, each once (the lists then differ in their order only): sx and sy
// receive n - k entities each (scratch)
static inline bool FoSameSet(const u8* x, const u8* y, u64 k, u64 n, u32 es, u32* sx, u32* sy)
{
    if (k > n) return false;
    u64 m = n - k;
    for (u64 i = 0; i < m; i++) { sx[i] = *(const u32*)(x + (k + i) * es); sy[i] = *(const u32*)(y + (k + i) * es); }
    FoSortU32(sx, m);
    FoSortU32(sy, m);
    for (u64 i = 0; i < m; i++) if (sx[i] != sy[i]) return false;
    for (u64 i = 1; i < m; i++) if (sx[i] == sx[i - 1]) return false;
    return true;
}

// the family's own calls that make the list y alike to x from entry k on (x and y: n entries, the same entities from k):
// remove y's entries from its last down to k (each the last one then: a plain pop, nothing moves), then add x's entries k..n-1
// in their order (each at the end). rem and add receive n - k entities each.
static inline void FoPlan(const u8* x, const u8* y, u64 k, u64 n, u32 es, u32* rem, u32* add)
{
    for (u64 i = 0; i < n - k; i++) {
        rem[i] = *(const u32*)(y + (n - 1 - i) * es);
        add[i] = *(const u32*)(x + (k + i) * es);
    }
}
