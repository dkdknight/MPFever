// MPFever native companion for Transport Fever 3 (loaded into the game by MPFever.exe).
//
// v1: diagnostics. Inline hooks on engine functions log who calls them (return addresses found on the stack, as
// RVAs) to <MPFEVER_DIR>\native.log. Everything is keyed to one exact game build: on any other build the DLL
// stays inert. Built freestanding (no Windows SDK / C runtime on the build machine): see win.h.
#include "win.h"

extern "C" int _fltused = 0;

extern "C" void* memcpy(void*, const void*, size_t);
extern "C" void* memset(void*, int, size_t);
extern "C" int memcmp(const void*, const void*, size_t);
#pragma function(memcpy)
#pragma function(memset)
#pragma function(memcmp)
extern "C" void* memcpy(void* d, const void* s, size_t n) { u8* a = (u8*)d; const u8* b = (const u8*)s; while (n--) *a++ = *b++; return d; }
extern "C" void* memset(void* d, int v, size_t n) { u8* a = (u8*)d; while (n--) *a++ = (u8)v; return d; }
extern "C" int memcmp(const void* x, const void* y, size_t n) { const u8* a = (const u8*)x; const u8* b = (const u8*)y; for (; n; n--, a++, b++) if (*a != *b) return *a < *b ? -1 : 1; return 0; }

static const u32 EXPECTED_TIMESTAMP = 0x6ab69fe5;   // TransportFever3.exe build 40408

static uptr g_base = 0, g_textStart = 0, g_textEnd = 0;
static HANDLE g_log = 0;
static volatile long g_logLock = 0;

// ------------------------------------------------------------------ tiny text builder

struct Buf {
    char s[1024];
    int n = 0;
    Buf& str(const char* t) { while (*t && n < 1000) s[n++] = *t++; return *this; }
    Buf& hex(u64 v) { char t[17]; int k = 0; do { int d = (int)(v & 15); t[k++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v >>= 4; } while (v && k < 16); while (k && n < 1000) s[n++] = t[--k]; return *this; }
    Buf& dec(i64 v) { if (v < 0) { s[n++] = '-'; v = -v; } char t[21]; int k = 0; do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k && n < 1000) s[n++] = t[--k]; return *this; }
    Buf& dec2(int v) { s[n++] = (char)('0' + v / 10 % 10); s[n++] = (char)('0' + v % 10); return *this; }
};

static void LogLine(Buf& b)
{
    if (!g_log) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    Buf line;
    line.dec2(t.wHour).str(":").dec2(t.wMinute).str(":").dec2(t.wSecond).str(" ");
    for (int i = 0; i < b.n && line.n < 1010; i++) line.s[line.n++] = b.s[i];
    line.s[line.n++] = '\r';
    line.s[line.n++] = '\n';
    while (_InterlockedExchange(&g_logLock, 1)) Sleep(0);
    DWORD w;
    SetFilePointer(g_log, 0, 0, FILE_END);
    WriteFile(g_log, line.s, (DWORD)line.n, &w, 0);
    _InterlockedExchange(&g_logLock, 0);
}

// ------------------------------------------------------------------ inline hooks

struct Hook {
    const char* name;
    u32 rva;
    int steal;                 // whole instructions, no RIP-relative operand (checked offline with capstone)
    const u8* expect;          // first bytes expected at the target (build check)
    int expectLen;
    void* tramp;
    volatile long calls;
};

static void WriteAbsJump(u8* at, uptr to)
{
    at[0] = 0xFF; at[1] = 0x25; at[2] = at[3] = at[4] = at[5] = 0;
    *(uptr*)(at + 6) = to;
}

static bool IsCallBefore(uptr ret)
{
    if (ret < g_textStart + 8 || ret >= g_textEnd) return false;
    const u8* p = (const u8*)ret;
    if (p[-5] == 0xE8) return true;
    if (p[-6] == 0xFF && p[-5] == 0x15) return true;
    if (p[-2] == 0xFF && (p[-1] & 0x38) == 0x10) return true;
    if (p[-3] == 0xFF && (p[-2] & 0x38) == 0x10) return true;
    if (p[-3] == 0x41 && p[-2] == 0xFF && (p[-1] & 0x38) == 0x10) return true;
    if (p[-6] == 0xFF && (p[-5] & 0x38) == 0x10) return true;
    if (p[-7] == 0xFF && (p[-6] & 0x38) == 0x10) return true;
    return false;
}

// called from the relay thunk with the hooked function's stack pointer at entry
extern "C" void OnHookEntry(Hook* h, uptr* entryRsp)
{
    long n = _InterlockedIncrement(&h->calls);
    if (n > 40) return;
    Buf b;
    b.str(h->name).str(" #").dec(n).str(" from");
    int found = 0;
    for (int i = 0; i < 0x400 && found < 12; i++) {
        uptr v = entryRsp[i];
        if (v >= g_textStart && v < g_textEnd && IsCallBefore(v)) {
            b.str(" ").hex(v - g_base);
            found++;
        }
    }
    LogLine(b);
}

// Relay thunk: saves the argument registers, calls OnHookEntry(hook, rsp at entry), restores, jumps to the trampoline.
static void* MakeRelay(Hook* h)
{
    u8* c = (u8*)VirtualAlloc(0, 256, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!c) return 0;
    int i = 0;
    static const u8 pre[] = {
        0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x50, 0x41, 0x52, 0x41, 0x53,   // push rcx rdx r8 r9 rax r10 r11
        0x48, 0x83, 0xEC, 0x60,                                             // sub rsp, 0x60
        0xF3, 0x0F, 0x7F, 0x44, 0x24, 0x20, 0xF3, 0x0F, 0x7F, 0x4C, 0x24, 0x30, // movdqu [rsp+20],xmm0 / [rsp+30],xmm1
        0xF3, 0x0F, 0x7F, 0x54, 0x24, 0x40, 0xF3, 0x0F, 0x7F, 0x5C, 0x24, 0x50, // movdqu [rsp+40],xmm2 / [rsp+50],xmm3
        0x48, 0x8D, 0x94, 0x24, 0x98, 0x00, 0x00, 0x00,                     // lea rdx, [rsp+0x60+7*8]
    };
    for (u8 x : pre) c[i++] = x;
    c[i++] = 0x48; c[i++] = 0xB9; *(u64*)(c + i) = (u64)h; i += 8;                 // mov rcx, hook
    c[i++] = 0x48; c[i++] = 0xB8; *(u64*)(c + i) = (u64)&OnHookEntry; i += 8;      // mov rax, OnHookEntry
    c[i++] = 0xFF; c[i++] = 0xD0;                                                  // call rax
    static const u8 post[] = {
        0xF3, 0x0F, 0x6F, 0x44, 0x24, 0x20, 0xF3, 0x0F, 0x6F, 0x4C, 0x24, 0x30,
        0xF3, 0x0F, 0x6F, 0x54, 0x24, 0x40, 0xF3, 0x0F, 0x6F, 0x5C, 0x24, 0x50,
        0x48, 0x83, 0xC4, 0x60,                                             // add rsp, 0x60
        0x41, 0x5B, 0x41, 0x5A, 0x58, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59,   // pop r11 r10 rax r9 r8 rdx rcx
    };
    for (u8 x : post) c[i++] = x;
    WriteAbsJump(c + i, (uptr)h->tramp); i += 14;
    FlushInstructionCache(GetCurrentProcess(), c, i);
    return c;
}

static bool Install(Hook* h)
{
    u8* target = (u8*)(g_base + h->rva);
    Buf b;
    if (h->expect && memcmp(target, h->expect, h->expectLen) != 0) {
        b.str("hook ").str(h->name).str(": unexpected bytes, not installed");
        LogLine(b);
        return false;
    }
    u8* tramp = (u8*)VirtualAlloc(0, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) return false;
    memcpy(tramp, target, h->steal);
    WriteAbsJump(tramp + h->steal, (uptr)target + h->steal);
    FlushInstructionCache(GetCurrentProcess(), tramp, h->steal + 14);
    h->tramp = tramp;
    void* relay = MakeRelay(h);
    if (!relay) return false;
    DWORD old;
    if (!VirtualProtect(target, h->steal, PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[32];
    WriteAbsJump(patch, (uptr)relay);
    for (int k = 14; k < h->steal; k++) patch[k] = 0xCC;
    memcpy(target, patch, h->steal);
    VirtualProtect(target, h->steal, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, h->steal);
    b.str("hook ").str(h->name).str(" installed at ").hex(h->rva);
    LogLine(b);
    return true;
}

// ------------------------------------------------------------------ targets (build 40408)

static const u8 P_5F4920[] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };
static const u8 P_609F50[] = { 0x48, 0x89, 0x5C, 0x24, 0x08 };
static const u8 P_A1C370[] = { 0x48, 0x89, 0x5C, 0x24, 0x10 };
static const u8 P_A1C540[] = { 0x4C, 0x8B, 0xDC };
static const u8 P_A1D2C0[] = { 0x48, 0x8B, 0xC4 };
static const u8 P_A1ED10[] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };
static const u8 P_A3C180[] = { 0x40, 0x55 };

static Hook g_hooks[] = {
    { "notPossible_5f4920", 0x5f4920, 14, P_5F4920, 5 },
    { "notPossible_CheckGraph_609f50", 0x609f50, 14, P_609F50, 5 },
    { "notPossible_a1c370", 0xa1c370, 15, P_A1C370, 5 },
    { "notPossible_a1c540", 0xa1c540, 19, P_A1C540, 3 },
    { "notPossible_ParallelShapes_a1d2c0", 0xa1d2c0, 14, P_A1D2C0, 3 },
    { "notPossible_ConstructionData_a1ed10", 0xa1ed10, 14, P_A1ED10, 5 },
    { "notPossible_a3c180", 0xa3c180, 21, P_A3C180, 2 },
};

// ------------------------------------------------------------------ breakpoint sites
// A one-byte int3 on an instruction; the vectored handler logs the call chain and emulates the instruction.
// Only "lea r64, [rip + disp32]" (7 bytes, REX.W 8D modrm 00 reg 101) is emulated.

struct Site {
    const char* name;
    u32 rva;
    u8 orig;
    volatile long hits;
};

#include "sites_gen.h"
static Site g_sites[] = {
    { "notPossible@5f4c0b", 0x5f4c0b }, { "notPossible@609fe5", 0x609fe5 }, { "notPossible@60a05f", 0x60a05f },
    { "notPossible@60a0de", 0x60a0de }, { "notPossible@a1c427", 0xa1c427 }, { "notPossible@a1c4c8", 0xa1c4c8 },
    { "notPossible@a1c670", 0xa1c670 }, { "notPossible@a1dfee", 0xa1dfee }, { "notPossible@a1f12e", 0xa1f12e },
    { "notPossible@a3ccad", 0xa3ccad },
};

static void LogStack(const char* what, long n, uptr* rsp)
{
    Buf b;
    b.str(what).str(" #").dec(n).str(" stack");
    int found = 0;
    for (int i = 0; i < 0x600 && found < 14; i++) {
        uptr v = rsp[i];
        if (v >= g_textStart && v < g_textEnd && IsCallBefore(v)) {
            b.str(" ").hex(v - g_base);
            found++;
        }
    }
    LogLine(b);
}

static Site g_mapSites[sizeof(MAPGET_SITES) / sizeof(MAPGET_SITES[0])];

static long WINAPI OnException(void* info)
{
    u8* rec = *(u8**)info;              // EXCEPTION_RECORD*
    u8* ctx = *((u8**)info + 1);        // CONTEXT*
    if (*(u32*)rec != 0x80000003u) return 0;
    uptr addr = *(uptr*)(rec + 0x10);
    Site* found = 0;
    for (auto& s : g_sites) if (addr == g_base + s.rva) found = &s;
    if (!found) for (auto& s : g_mapSites) if (s.rva && addr == g_base + s.rva) found = &s;
    if (found) {
        Site& s = *found;
        uptr at = g_base + s.rva;
        long n = _InterlockedIncrement(&s.hits);
        if (n <= 30) { Buf w; w.str("site ").hex(s.rva); LogLine(w); LogStack(s.name, n, *(uptr**)(ctx + 0x98)); }
        // emulate lea r64, [rip + disp32]
        const u8* p = (const u8*)at;
        int reg = ((p[2] >> 3) & 7) | ((s.orig & 4) ? 8 : 0);
        i64 disp = *(const int*)(p + 3);
        uptr value = at + 7 + disp;
        static const int regOff[16] = { 0x78, 0x80, 0x88, 0x90, 0x98, 0xA0, 0xA8, 0xB0, 0xB8, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0 };
        *(uptr*)(ctx + regOff[reg]) = value;
        *(uptr*)(ctx + 0xF8) = at + 7;
        return -1;   // EXCEPTION_CONTINUE_EXECUTION
    }
    return 0;
}


static void ArmSite(Site& s)
{
    u8* at = (u8*)(g_base + s.rva);
    if (!((at[0] == 0x48 || at[0] == 0x4C) && at[1] == 0x8D && (at[2] & 0xC7) == 0x05)) return;
    s.orig = at[0];
    DWORD old;
    VirtualProtect(at, 1, PAGE_EXECUTE_READWRITE, &old);
    at[0] = 0xCC;
    VirtualProtect(at, 1, old, &old);
    FlushInstructionCache(GetCurrentProcess(), at, 1);
}

static void ArmMapSites()
{
    AddVectoredExceptionHandler(1, OnException);
    int n = (int)(sizeof(MAPGET_SITES) / sizeof(MAPGET_SITES[0]));
    for (int i = 0; i < n; i++) {
        g_mapSites[i].name = "mapGetFailed";
        g_mapSites[i].rva = MAPGET_SITES[i];
        ArmSite(g_mapSites[i]);
    }
    Buf b; b.str("map assertion sites armed: ").dec(n); LogLine(b);
}

static void ArmSites()
{
    AddVectoredExceptionHandler(1, OnException);
    for (auto& s : g_sites) {
        u8* at = (u8*)(g_base + s.rva);
        if (!((at[0] == 0x48 || at[0] == 0x4C) && at[1] == 0x8D && (at[2] & 0xC7) == 0x05)) {
            Buf b; b.str("site ").str(s.name).str(": not a lea, skipped"); LogLine(b);
            continue;
        }
        s.orig = at[0];
        DWORD old;
        VirtualProtect(at, 1, PAGE_EXECUTE_READWRITE, &old);
        at[0] = 0xCC;
        VirtualProtect(at, 1, old, &old);
        FlushInstructionCache(GetCurrentProcess(), at, 1);
    }
    Buf b; b.str("breakpoint sites armed"); LogLine(b);
}

// ------------------------------------------------------------------ deferral of native builds (v3)
// A build issued by a UI tool (street, stop, construction, bulldozer...) is held at CommandList::Add instead of being
// queued; the mod announces it to every game and, at the agreed game time, asks for its release: the held command is
// then queued exactly as the tool would have queued it. Control: <dir>\native_ctl.txt ("enable 1", "release <n>"),
// events: <dir>\native_events.log ("deferred <id>").

static u32 RVA_ADD = 0x9d29c0;             // CommandList::Add(list, out, cmd, done, progress)
static u32 RVA_CMD_MOVE = 0x9cedb0;        // Command move constructor (dst, src)
static u32 RVA_CMD_DTOR = 0x9ceff0;        // Command destructor
static u32 RVA_HANDLE_DTOR = 0x30393d0;    // destructor of Add's out handle
static const u8 P_ADD[] = { 0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8D, 0x6C, 0x24, 0x98 };

// return addresses of the Add calls made by UI tools right after make_cmd BuildProposal (build 40408)
static const u32 UI_SITES_40408[] = {
    0x4d45af,   // UI::Bulldozer::Apply
    0x51c11c,   // UI::ConstructionBuilder::MousePressed
    0x5290b4,   // tool (unnamed)
    0x538a85, 0x5391e9, 0x53936d,   // UI::LaneModifier::Apply
    0x543b2a,   // UI::ModuleBuilder::MousePressed
    // 0x549bea (a tool near the terrain tools) is NOT held: holding the terrain edit made the game crash in UI::TerrainModifier
    0x589ed4,   // UI::StreetBuilder::UpdateEngine
    0x5954ed,   // UI::StreetTerminalBuilder (stops, signals, waypoints)
    0x5bfcad,   // UI::TrackModifier::Build
    0x289f944, 0x28a0191,   // entity window builtins
};
// build 40420 (same functions, same offsets inside them, found again with the call graph)
static const u32 UI_SITES_40420[] = {
    0x4d396f,   // UI::Bulldozer::Apply
    0x51b56c,   // UI::ConstructionBuilder::MousePressed
    0x528504,   // tool (unnamed)
    0x537ee5, 0x538649, 0x5387cd,   // UI::LaneModifier::Apply
    0x542eba,   // UI::ModuleBuilder::MousePressed
    0x5891b4,   // UI::StreetBuilder::UpdateEngine
    0x5948dd,   // UI::StreetTerminalBuilder (stops, signals, waypoints)
    0x5bf08d,   // UI::TrackModifier::Build
    0x28a3024, 0x28a3871,   // entity window builtins
};
static const u32* UI_ADD_SITES = UI_SITES_40408;
static int UI_ADD_N = (int)(sizeof(UI_SITES_40408) / sizeof(UI_SITES_40408[0]));

// The engine functions the native module hooks, per game build (TransportFever3.exe's link timestamp). Any other build:
// the hooks stay off (the main menu page and the script pool patch are found by their code instead, see below).
struct BuildAddrs {
    u32 stamp;
    u32 add, move, dtor, handleDtor, apply, swap, sync, preIter, lua, pool, loopRet;
    const u32* sites; int nSites;
};
static const BuildAddrs BUILDS[] = {
    { 0x6ab69fe5, 0x9d29c0, 0x9cedb0, 0x9ceff0, 0x30393d0, 0x9e1c10, 0x9d2d20, 0x11f650, 0x157860, 0x2fbdf70, 0xaaec2c, 0x11eb9b, UI_SITES_40408, (int)(sizeof(UI_SITES_40408) / sizeof(UI_SITES_40408[0])) },   // 40408
    { 0x6ac50427, 0x9d4040, 0x9d0430, 0x9d0670, 0x3040c90, 0x9e33b0, 0x9d43a0, 0x11f690, 0x1578a0, 0x2fc58c0, 0xab00fc, 0x11ebdb, UI_SITES_40420, (int)(sizeof(UI_SITES_40420) / sizeof(UI_SITES_40420[0])) },   // 40420
};
static bool SelectBuild(u32 stamp);
static u32 g_knownLua = 0, g_knownPool = 0;

typedef void* (*AddFn)(void* list, void* out, void* cmd, void* done, void* progress);
static AddFn g_addOrig = 0;

struct Held {
    void* list;
    alignas(16) u8 cmd[0x40];
    alignas(16) u8 done[0x40];
    alignas(16) u8 progress[0x10];
    u32 site;
    int id;
};
static Held* g_held[64];
static int g_heldHead = 0, g_heldTail = 0, g_nextId = 0;
static bool g_enabled = false;
static int g_released = 0;          // releases performed
static int g_releaseTarget = 0;     // releases asked by the mod
static DWORD g_lastCtl = 0;
static char g_dir[300];
static int g_dirLen = 0;
static long g_inRelease = 0;
static volatile long g_dropHeld = 0;  // a game was loaded: the builds still held belong to the previous one
static int g_dropTarget = 0;          // the releases asked for until then
static int g_dropId = 0;              // the last build held until then
static int g_deferNextTarget = 0, g_deferNextDone = 0;   // test mode: defer the mod's own next commands

static void PathOf(char* out, const char* name)
{
    int k = 0;
    for (int i = 0; i < g_dirLen; i++) out[k++] = g_dir[i];
    out[k++] = '\\';
    for (int i = 0; name[i]; i++) out[k++] = name[i];
    out[k] = 0;
}

static void AppendEvent(Buf& b)
{
    char path[400];
    PathOf(path, "native_events.log");
    HANDLE f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    b.s[b.n++] = '\n';
    DWORD w;
    SetFilePointer(f, 0, 0, FILE_END);
    WriteFile(f, b.s, (DWORD)b.n, &w, 0);
    CloseHandle(f);
}

// reads native_ctl.txt: "enable 0|1" and "release <n>" lines (the last value of each wins)
static volatile long g_tinWant = 0, g_tinLoaded = 0;      // terrain edit sent by the mod, to be injected: id asked / id loaded
static void TerrainLoadIn(long id);
static void* g_slot = 0;
static long g_iter = 0;
static long g_iterlogDone = 0;
static volatile long g_setPlayer = 0;
static volatile long g_localPlayer = 0;
static long g_localTok = 0;          // token of the control line applied last (the file keeps old lines: only a new token counts)
static void ApplyLocalPlayer(const char* why);
// The other companies' player entities. The engine empties the positions (the money shown above the buildings) of the LOCAL player's
// account only, at the start of every simulation iteration (the pre-iteration function ends in the call below); those of the other
// accounts would pile up for ever on this machine, so the same call is made for them ("setothers <token> <entity>..." in the control file).
static volatile long g_others[8];
static volatile long g_nOthers = 0;
static long g_othersTok = 0;
// The savegame's own company ("setcanon <token> <entity>"): the interface's tools build for it whatever company this machine plays
// (see OwnerFix), so its entity is looked for in the builds they issue.
static volatile long g_canon = 0;
static volatile long g_mainTid = 0;        // the game's main thread (its interface), see PatchPlayerReads
static volatile i64 g_pickCount[8][3];     // per redirected reading: [0] on the interface's thread, [1] the simulation's, [2] another
static volatile long g_simTid = 0;         // the simulation thread (seen in its pre-iteration)
static long g_canonTok = 0;
typedef void (*ClearPosF)(void* world, u32 player);
static ClearPosF g_clearPos = 0;
static bool g_preIterOn = false;
static u32* g_hits[600];
static int g_nhits = 0;
static volatile long g_probeIdx = 0, g_probeApplied = 0;
static u32 g_probeSaved = 0;
static void ReadControl()
{
    char path[400];
    PathOf(path, "native_ctl.txt");
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[16384];
    DWORD size = GetFileSize(f, 0), got = 0;
    if (size > sizeof(buf) - 1) { SetFilePointer(f, (long)(size - (sizeof(buf) - 1)), 0, 0); size = sizeof(buf) - 1; }
    ReadFile(f, buf, size, &got, 0);
    CloseHandle(f);
    buf[got] = 0;
    long wantLocal = 0, wantTok = 0; bool haveLocal = false;
    long wantOthers[8]; int nWantOthers = 0; long othersTok = 0; bool haveOthers = false;
    long wantCanon = 0, canonTok = 0; bool haveCanon = false;
    for (DWORD i = 0; i < got; ) {
        DWORD j = i;
        while (j < got && buf[j] != '\n') j++;
        const char* l = buf + i;
        int len = (int)(j - i);
        int v = 0;
        if (len >= 8 && memcmp(l, "enable ", 7) == 0) g_enabled = l[7] == '1';
        else if (len >= 11 && memcmp(l, "defernext ", 10) == 0) {
            for (int k = 10; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > g_deferNextTarget) g_deferNextTarget = v;
        }
        else if (len >= 10 && memcmp(l, "setlocal ", 9) == 0) {
            // "setlocal <entity> <token>": the last such line of the file wins
            int k = 9;
            for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            long tok = 0;
            for (k++; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
            wantLocal = v; wantTok = tok; haveLocal = true;
        }
        else if (len >= 11 && memcmp(l, "setothers ", 10) == 0) {
            // "setothers <token> <entity>...": the last such line of the file wins
            int k = 10;
            long tok = 0;
            for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
            nWantOthers = 0;
            while (k < len && nWantOthers < 8) {
                while (k < len && (l[k] < '0' || l[k] > '9')) k++;
                long e = 0; bool any = false;
                for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) { e = e * 10 + (l[k] - '0'); any = true; }
                if (any) wantOthers[nWantOthers++] = e;
            }
            othersTok = tok; haveOthers = true;
        }
        else if (len >= 10 && memcmp(l, "setcanon ", 9) == 0) {
            int k = 9;
            long tok = 0, e = 0;
            for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
            for (k++; k < len && l[k] >= '0' && l[k] <= '9'; k++) e = e * 10 + (l[k] - '0');
            wantCanon = e; canonTok = tok; haveCanon = true;
        }
        else if (len >= 11 && memcmp(l, "setplayer ", 10) == 0) {
            for (int k = 10; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            g_setPlayer = v;
        }
        else if (len >= 9 && memcmp(l, "iterlog ", 8) == 0) {
            for (int k = 8; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v != g_iterlogDone) { g_iterlogDone = v; Buf b; b.str("iterlog ").dec(v).str(" iter ").dec(g_iter); LogLine(b); Buf e; e.str("iter ").dec(v).str(" ").dec(g_iter); AppendEvent(e); }
        }
        else if (len >= 7 && memcmp(l, "probe ", 6) == 0) {
            for (int k = 6; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            g_probeIdx = v;
        }
        else if (len >= 5 && memcmp(l, "tin ", 4) == 0) {
            for (int k = 4; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            g_tinWant = v;
        }
        else if (len >= 9 && memcmp(l, "release ", 8) == 0) {
            for (int k = 8; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > g_releaseTarget) g_releaseTarget = v;
        }
        i = j + 1;
    }
    { long want = g_tinWant; if (want && _InterlockedExchange(&g_tinLoaded, want) != want) TerrainLoadIn(want); }
    // (written into the game state by the simulation thread only, at its next iteration: from here, the state known last may be the
    // one of a game just unloaded, freed memory - writing there corrupted the heap and crashed the game after a resynchronisation)
    if (haveLocal && wantTok != g_localTok) { g_localTok = wantTok; g_localPlayer = wantLocal; }
    if (haveCanon && canonTok != g_canonTok) {
        g_canonTok = canonTok; g_canon = wantCanon;
        static long shownC = 0;
        if (shownC++ < 10) { Buf b; b.str("savegame company ").dec(wantCanon); LogLine(b); }
    }
    if (haveOthers && othersTok != g_othersTok) {
        g_othersTok = othersTok;
        g_nOthers = 0;
        for (int i = 0; i < nWantOthers; i++) g_others[i] = wantOthers[i];
        g_nOthers = nWantOthers;
        static long shownO = 0;
        if (shownO++ < 10) { Buf b; b.str("other companies: "); for (int i = 0; i < nWantOthers; i++) b.dec(wantOthers[i]).str(" "); LogLine(b); }
    }
    if (g_probeIdx != g_probeApplied) {
        // restore the previous candidate, then patch the new one (1-based; 0 = nothing patched)
        if (g_probeApplied > 0 && g_probeApplied <= g_nhits) *g_hits[g_probeApplied - 1] = g_probeSaved;
        g_probeApplied = g_probeIdx;
        if (g_probeIdx > 0 && g_probeIdx <= g_nhits) {
            u64 ad = (u64)g_hits[g_probeIdx - 1];
            u64 eng = g_slot ? *(u64*)((u8*)g_slot + 0x18) : 0;
            Buf b; b.str("probe ").dec(g_probeIdx).str(" addr ").hex(ad).str(" slot ").hex((u64)g_slot).str(" slot-delta ").hex(ad - (u64)g_slot).str(" engine ").hex(eng).str(" engine-delta ").hex(ad - eng); LogLine(b);
        }
        if (g_probeIdx > 0 && g_probeIdx <= g_nhits && g_setPlayer) { g_probeSaved = *g_hits[g_probeIdx - 1]; *g_hits[g_probeIdx - 1] = (u32)g_setPlayer; }
    }
}

typedef void* (*MoveF)(void* self, void* where);
typedef void (*DelF)(void* self, bool dealloc);

static void MoveFunction(u8* dst, u8* src)
{
    // MSVC std::function: impl pointer at +0x38; impl vtable: _Copy, _Move, _Do_call, _Target_type, _Delete_this
    u8* impl = *(u8**)(src + 0x38);
    memset(dst, 0, 0x40);
    if (!impl) return;
    if (impl == src) {
        void** vt = *(void***)impl;
        void* moved = ((MoveF)vt[1])(impl, dst);
        *(void**)(dst + 0x38) = moved;
        ((DelF)vt[4])(impl, false);
    } else {
        *(void**)(dst + 0x38) = impl;
    }
    *(void**)(src + 0x38) = 0;
}

static bool IsUiSite(u32 rva)
{
    for (int i = 0; i < UI_ADD_N; i++) if (UI_ADD_SITES[i] == rva) return true;
    return false;
}

// ---------------------------------------------------------------- timing probe (MPFEVER_TIMING=1)
// How long a command takes from the interface thread to the simulation thread: CommandList::Add and the simulation
// thread's "Apply Command" task are stamped with the performance counter (microseconds since the first stamp).
static volatile long g_timing = 0;
static i64 g_qpf = 0, g_qp0 = 0;
static i64 NowUs()
{
    i64 c = 0;
    QueryPerformanceCounter(&c);
    if (!g_qp0) g_qp0 = c;
    return (c - g_qp0) * 1000000 / g_qpf;
}
static void TimingLine(const char* tag, u64 a, u64 b)
{
    Buf l;
    l.str("tm ").dec(NowUs()).str(" ").str(tag).str(" thr=").dec(GetCurrentThreadId()).str(" ").hex(a).str(" ").hex(b);
    LogLine(l);
}

typedef u64 (*ApplyF)(void*, void*);
static ApplyF g_applyOrig = 0;
// GameState::Replicate(this = source, destination, flag): copies the world and the local-player word from one state to the other
// (logged, to learn which state the interface's tools read the player from)
typedef u64 (*ReplF)(void*, void*, u64);
static ReplF g_replOrig = 0;
static const u8 P_REPL[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x50 };
static u32 RVA_REPL = 0, RVA_REPL_LOOP = 0;
static const u8 P_APPLY[] = { 0x48, 0x89, 0x5C, 0x24, 0x18, 0x48, 0x89, 0x74, 0x24, 0x20, 0x55, 0x57, 0x41, 0x54 };
static u32 RVA_LOOP_RET = 0x11eb9b;   // return address of RunGameSimLoop's call of Apply
static u32 RVA_APPLY = 0x9e1c10;     // "Simulation Thread: Apply Command" (the commands a simulation iteration applies)
typedef u64 (*SyncF)(void*, void*);
static SyncF g_syncOrig = 0;
static const u8 P_SYNC[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56 };
static u32 RVA_SYNC = 0x11f650;      // CGame::Sync: the main thread waits for / receives the simulation thread's frame
extern "C" u64 SyncDetour(void* a, void* b)
{
    TimingLine("sync-begin", (u64)a, (u64)b);
    u64 r = g_syncOrig(a, b);
    TimingLine("sync-end", r, 0);
    return r;
}
typedef u64 (*SwapF)(void*, void*);
static SwapF g_swapOrig = 0;
static const u8 P_SWAP[] = { 0x48, 0x89, 0x7C, 0x24, 0x18, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x20, 0x4C, 0x8B, 0xF1 };
static u32 RVA_SWAP = 0x9d2d20;      // CommandList::Swap
extern "C" u64 SwapDetour(void* a, void* b)
{
    TimingLine("swap", (u64)a, (u64)b);
    return g_swapOrig(a, b);
}

typedef void (*Dtor0)(void*);
typedef void* (*MoveCtor0)(void*, void*);
static volatile long g_gateMs = 0;
// Injection spike (MPFEVER_DEFER_ITERS=K): every command the simulation thread is about to apply is moved aside and
// applied again, in order, at the start of the iteration K iterations later (RunGameSimLoop calls 0x157860 once per
// iteration, right before it walks the command vector).
typedef u64 (*PreIterF)(void*);
static PreIterF g_preIterOrig = 0;
static const u8 P_PREITER[] = { 0x48, 0x8B, 0x49, 0x08, 0x8B, 0x91, 0x0C, 0x02, 0x00, 0x00, 0x48, 0x8B, 0x49, 0x18 };
static u32 RVA_PREITER = 0x157860;
static volatile long g_deferIters = 0;
static i64 g_deferAfterUs = 50000000;
struct Deferred { void* cmd; long due; long queued; bool exact; };
static Deferred g_def[256];
static unsigned g_defHead = 0, g_defTail = 0;
// Start of every simulation iteration: the positions of the other companies are emptied like the local one's. A game state seen
// for the first time is a game that has just been loaded: the entity ids given for the previous one mean nothing there (the mod
// gives them again once it knows its companies).
static void* g_preSeen[16]; static int g_nPreSeen = 0;
static void ClearOthersIn(u8* gs, bool learn)
{
    if (!gs) return;
    bool known = false;
    for (int i = 0; i < g_nPreSeen; i++) if (g_preSeen[i] == gs) known = true;
    if (!known) {
        if (!learn) return;
        if (g_nPreSeen < 16) g_preSeen[g_nPreSeen++] = gs; else g_preSeen[0] = gs;
        if (g_nOthers) { Buf b; b.str("other companies dropped: a new game state ").hex((u64)gs); LogLine(b); g_nOthers = 0; }
        if (g_heldHead != g_heldTail) { g_dropTarget = g_releaseTarget; g_dropId = g_nextId; g_dropHeld = 1; }
        return;
    }
    long n = g_nOthers;
    if (n <= 0 || !g_clearPos) return;
    void* world = *(void**)(gs + 0x18);
    // (the word holds the savegame's company, which the engine empties itself at the start of the iteration; this machine plays
    // g_localPlayer, whose positions the interface must show)
    u32 word = *(u32*)(gs + 0x20c);
    u32 mine = g_localPlayer ? (u32)g_localPlayer : word;
    if (!world) return;
    u32 list[10]; int k = 0;
    for (long i = 0; i < n && i < 8; i++) if (g_others[i]) list[k++] = (u32)g_others[i];
    list[k++] = mine;
    list[k++] = word;
    for (int i = 0; i < k; i++) {
        u32 e = list[i];
        bool dup = false;
        for (int j = 0; j < i; j++) if (list[j] == e) dup = true;
        if (dup || !e) continue;
        // start of an iteration (learn): every company but the word's (the engine's own call follows); before the copy for the
        // interface: every company but this machine's
        if (learn ? e == word : e == mine) continue;
        g_clearPos(world, e);
        static long shown = 0;
        if (shown++ < 4) { Buf b; b.str("positions of company ").dec(e).str(" emptied (this machine plays ").dec(mine).str(", word ").dec(word).str(", learn ").dec(learn ? 1 : 0).str(")"); LogLine(b); }
    }
}

// ---- diagnostic (MPFEVER_WATCH20C=1): which code of the simulation thread reads the local-player word (+0x20c of the game
// states)? Hardware data breakpoints (debug registers of the simulation thread, armed through an exception of our own) on the
// word of every game state seen; each new reading instruction is logged once with its call chain.
static long g_watch = -1;
static u64 g_watchAddr[4];
static int g_watchN = 0;
static u64 g_watchSeen[256];
static int g_watchSeenN = 0;
static long g_watchArmedFor = -1;
static long WINAPI WatchException(void* info)
{
    u8* rec = *(u8**)info;
    u8* ctx = *((u8**)info + 1);
    u32 code = *(u32*)rec;
    if (code == 0xE0575443u) {                  // our own arming exception
        u64 dr7 = 0;
        for (int i = 0; i < g_watchN && i < 4; i++) {
            *(u64*)(ctx + 0x48 + 8 * i) = g_watchAddr[i];
            dr7 |= (1ull << (2 * i)) | (3ull << (16 + 4 * i)) | (3ull << (18 + 4 * i));
        }
        *(u64*)(ctx + 0x70) = dr7;
        *(u64*)(ctx + 0x68) = 0;
        *(u32*)(ctx + 0x30) |= 0x00100010u;      // CONTEXT_DEBUG_REGISTERS: the new registers are applied when it continues
        return -1;
    }
    if (code != 0x80000004u) return 0;          // single step / hardware breakpoint
    u64 dr6 = *(u64*)(ctx + 0x68);
    if (!(dr6 & 0xF)) return 0;
    *(u64*)(ctx + 0x68) = 0;
    u64 rip = *(u64*)(ctx + 0xF8);
    if (rip >= g_textStart && rip < g_textEnd) {
        bool seen = false;
        for (int i = 0; i < g_watchSeenN; i++) if (g_watchSeen[i] == rip) seen = true;
        if (!seen && g_watchSeenN < 256) {
            g_watchSeen[g_watchSeenN++] = rip;
            Buf b; b.str("watch20c: access before ").hex(rip - g_base).str(" thread ").dec(GetCurrentThreadId());
            LogLine(b);
            LogStack("watch20c", g_watchSeenN, *(uptr**)(ctx + 0x98));
        }
    }
    return -1;
}

// every thread of the game (not only the simulation thread): debug registers set from outside, thread suspended
typedef HANDLE (WINAPI* SnapF)(DWORD, DWORD);
typedef BOOL (WINAPI* T32F)(HANDLE, void*);
typedef HANDLE (WINAPI* OpenThreadF)(DWORD, BOOL, DWORD);
typedef DWORD (WINAPI* SuspF)(HANDLE);
typedef BOOL (WINAPI* CtxF)(HANDLE, void*);
typedef DWORD (WINAPI* PidF)();
static DWORD WINAPI WatchAllThreads(void*)
{
    Sleep(1500);
    // (MPFEVER_WATCH20C=2: every 5 s, every thread but the interface's, the threads started since included)
    char wv[4] = {};
    GetEnvironmentVariableA("MPFEVER_WATCH20C", wv, 3);
    bool again = wv[0] == '2';
    bool mainOnly = wv[0] == '3';       // (MPFEVER_WATCH20C=3: the interface's thread only)
    for (int round = 0; ; round++) {
    HMODULE k = GetModuleHandleW(L"kernel32.dll");
    auto snap = (SnapF)GetProcAddress(k, "CreateToolhelp32Snapshot");
    auto first = (T32F)GetProcAddress(k, "Thread32First");
    auto next = (T32F)GetProcAddress(k, "Thread32Next");
    auto openT = (OpenThreadF)GetProcAddress(k, "OpenThread");
    auto susp = (SuspF)GetProcAddress(k, "SuspendThread");
    auto res = (SuspF)GetProcAddress(k, "ResumeThread");
    auto getc = (CtxF)GetProcAddress(k, "GetThreadContext");
    auto setc = (CtxF)GetProcAddress(k, "SetThreadContext");
    auto pid = (PidF)GetProcAddress(k, "GetCurrentProcessId");
    if (!snap || !first || !next || !openT || !susp || !res || !getc || !setc || !pid) return 0;
    HANDLE h = snap(4, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    u32 te[7] = { 28 };
    static u8 ctxbuf[0x4D0 + 32];
    u8* ctx = (u8*)(((uptr)ctxbuf + 15) & ~(uptr)15);
    DWORD me = GetCurrentThreadId(), mypid = pid();
    int n = 0;
    if (first(h, te)) do {
        if (te[3] != mypid || te[2] == me) continue;
        if (again && (long)te[2] == g_mainTid) continue;
        if (mainOnly && (long)te[2] != g_mainTid) continue;
        HANDLE t = openT(0x0002 | 0x0008 | 0x0010, 0, te[2]);
        if (!t) continue;
        if (susp(t) != (DWORD)-1) {
            for (int i = 0; i < 0x4D0; i++) ctx[i] = 0;
            *(u32*)(ctx + 0x30) = 0x00100010u;
            if (getc(t, ctx)) {
                u64 dr7 = 0;
                for (int i = 0; i < g_watchN && i < 4; i++) {
                    *(u64*)(ctx + 0x48 + 8 * i) = g_watchAddr[i];
                    dr7 |= (1ull << (2 * i)) | (3ull << (16 + 4 * i)) | (3ull << (18 + 4 * i));
                }
                *(u64*)(ctx + 0x70) = dr7;
                *(u32*)(ctx + 0x30) = 0x00100010u;
                if (setc(t, ctx)) n++;
            }
            res(t);
        }
        CloseHandle(t);
    } while (next(h, te));
    CloseHandle(h);
    if (round == 0) { Buf b; b.str("watch20c: armed on ").dec(n).str(" thread(s), ").dec(g_watchN).str(" word(s)"); LogLine(b); }
    if (!again) return 0;
    Sleep(5000);
    }
}

static void WatchAdd(u8* gs)
{
    if (g_watch != 1 || !gs) return;
    u64 addr = (u64)(gs + 0x20c);
    for (int i = 0; i < g_watchN; i++) if (g_watchAddr[i] == addr) return;
    if (g_watchN >= 2) return;
    g_watchAddr[g_watchN++] = addr;
    if (g_watchN == 2) { HANDLE t = CreateThread(0, 0, WatchAllThreads, 0, 0, 0); if (t) CloseHandle(t); }
}

static void WatchArm(u8* gs)
{
    if (g_watch < 0) {
        char v[4];
        g_watch = GetEnvironmentVariableA("MPFEVER_WATCH20C", v, 3) > 0 ? 1 : 0;
        if (g_watch) AddVectoredExceptionHandler(1, WatchException);
    }
    if (!g_watch || !gs) return;
    u64 addr = (u64)(gs + 0x20c);
    bool known = false;
    for (int i = 0; i < g_watchN; i++) if (g_watchAddr[i] == addr) known = true;
    if (!known && g_watchN < 2) { g_watchAddr[g_watchN++] = addr; g_watchArmedFor = -1; }
    if (g_watchArmedFor != g_watchN) {
        g_watchArmedFor = g_watchN;
        RaiseException(0xE0575443u, 0, 0, 0);
        Buf b; b.str("watch20c: armed on ").dec(g_watchN).str(" game state(s), thread ").dec(GetCurrentThreadId()); LogLine(b);
    }
}

extern "C" u64 PreIterDetour(void* a)
{
    g_iter++;
    g_simTid = (long)GetCurrentThreadId();
    if (g_iter == 1) { Buf t; t.str("simulation thread ").dec(GetCurrentThreadId()).str(", interface thread ").dec(g_mainTid); LogLine(t); }
    ClearOthersIn(a ? *(u8**)((u8*)a + 8) : 0, true);
    if (a && *(u8**)((u8*)a + 8)) { g_slot = *(void**)((u8*)a + 8); ApplyLocalPlayer("iteration"); }
    WatchArm(a ? *(u8**)((u8*)a + 8) : 0);
    // commands moved aside (exact-iteration builds, or the MPFEVER_DEFER_ITERS test) whose iteration has come, in queue order
    for (unsigned i = g_defHead; i != g_defTail; i++) {
        Deferred& d = g_def[i % 256];
        if (!d.cmd || d.due > g_iter) continue;
        void* c = d.cmd;
        d.cmd = 0;
        if (g_timing) TimingLine("deferred-apply", (u64)g_iter, (u64)(g_iter - d.queued));
        g_applyOrig(g_slot, c);
        ((Dtor0)(g_base + RVA_CMD_DTOR))(c);
        HeapFree(GetProcessHeap(), 0, c);
    }
    while (g_defHead != g_defTail && !g_def[g_defHead % 256].cmd) g_defHead++;
    return g_preIterOrig(a);
}

// Command audit: how many commands of each kind this game's simulation applied (kind = byte at +0x9b8 of the command's payload,
// the dispatcher's index), written to the log every 10 seconds. Comparing two games' counts shows kinds of commands that were
// applied in one and never in the other, that is actions the mod does not replicate.
static u32 g_kcLoop[128], g_kcDir[128], g_kcSeen[128];
static DWORD g_auditTick = 0;
static void AuditFlush(bool force)
{
    DWORD now = GetTickCount();
    if (!force && now - g_auditTick < 10000) return;
    g_auditTick = now;
    for (int k = 0; k < 128; k++) {
        u32 tot = g_kcLoop[k] + g_kcDir[k];
        if (tot == g_kcSeen[k]) continue;
        g_kcSeen[k] = tot;
        Buf l; l.str("audit kind ").dec(k).str(" loop ").dec(g_kcLoop[k]).str(" direct ").dec(g_kcDir[k]);
        LogLine(l);
    }
    {
        Buf l; l.str("player readings (interface/simulation/other):");
        for (int i = 0; i < 5; i++) l.str(" ").dec((long)g_pickCount[i][0]).str("/").dec((long)g_pickCount[i][1]).str("/").dec((long)g_pickCount[i][2]);
        LogLine(l);
    }
}

// ---------------------------------------------------------------- terrain edits
// A terrain tool commits a WorldBuildProposal whose edit is a grid of {height, base} float cells on 4 m squares (the layout
// is Grid = { int x0, y0, w, h; vector<cell> }). A script can create a grid of any size but
// cannot write its cells. So: the game that edits the ground copies the cells when its simulation applies the command
// (TerrainCapture: a file of text, announced in native_events.log), the mod ships them to the other games, and there the mod
// sends an empty grid of the same size; as that script command enters the command list (TerrainInject) the cells are copied
// into it. Both games then apply the same cells.
static volatile long g_tLock = 0;
static void TLock() { while (_InterlockedExchange(&g_tLock, 1)) Sleep(0); }
static void TUnlock() { _InterlockedExchange(&g_tLock, 0); }

static bool Readable(const void* p, u64 n)
{
    u64 a = (u64)p, end = a + n;
    while (a < end) {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery((void*)a, &mi, sizeof(mi))) return false;
        if (mi.State != 0x1000 || (mi.Protect & 0x101) || mi.Protect == 0) return false;
        a = (u64)mi.BaseAddress + mi.RegionSize;
    }
    return true;
}

static u64 Fnv64(const u8* p, u64 n)
{
    u64 h = 1469598103934665603ull;
    for (u64 i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

static u64 PutV(u8* d, u64 o, u64 v) { while (v >= 128) { d[o++] = (u8)(v | 128); v >>= 7; } d[o++] = (u8)v; return o; }
static bool GetV(const u8* s, u64 n, u64* i, u64* v)
{
    u64 r = 0; int sh = 0;
    while (*i < n && sh < 64) { u8 c = s[(*i)++]; r |= (u64)(c & 127) << sh; if (!(c & 128)) { *v = r; return true; } sh += 7; }
    return false;
}

// LZ packing: varint size, then { varint literal count, literals, varint match length (0 = end), varint distance }.
// d must hold n + n/8 + 32 bytes.
static u64 LzPack(const u8* s, u64 n, u8* d)
{
    u32* ht = (u32*)HeapAlloc(GetProcessHeap(), 8, (1u << 16) * 4);
    u64 o = PutV(d, 0, n), litStart = 0, i = 0;
    while (ht && i + 4 <= n) {
        u32 x = *(const u32*)(s + i);
        u32 h = (x * 2654435761u) >> 16;
        u32 cand = ht[h];
        ht[h] = (u32)i + 1;
        if (cand) {
            u64 c = cand - 1, len = 0;
            while (i + len < n && s[c + len] == s[i + len]) len++;
            if (len >= 6) {
                o = PutV(d, o, i - litStart);
                for (u64 k = litStart; k < i; k++) d[o++] = s[k];
                o = PutV(d, o, len);
                o = PutV(d, o, i - c);
                i += len;
                litStart = i;
                continue;
            }
        }
        i++;
    }
    o = PutV(d, o, n - litStart);
    for (u64 k = litStart; k < n; k++) d[o++] = s[k];
    o = PutV(d, o, 0);
    if (ht) HeapFree(GetProcessHeap(), 0, ht);
    return o;
}

static bool LzUnpack(const u8* s, u64 n, u8** out, u64* outN)
{
    u64 i = 0, total = 0, o = 0;
    if (!GetV(s, n, &i, &total) || total > (1ull << 31)) return false;
    u8* d = (u8*)HeapAlloc(GetProcessHeap(), 0, total + 8);
    if (!d) return false;
    for (;;) {
        u64 lit = 0, ml = 0, dist = 0;
        if (!GetV(s, n, &i, &lit) || lit > n - i || lit > total - o) break;
        for (u64 k = 0; k < lit; k++) d[o++] = s[i++];
        if (!GetV(s, n, &i, &ml)) break;
        if (ml == 0) {
            if (o != total) break;
            *out = d; *outN = o;
            return true;
        }
        if (!GetV(s, n, &i, &dist) || dist == 0 || dist > o || ml > total - o) break;
        for (u64 k = 0; k < ml; k++, o++) d[o] = d[o - dist];
    }
    HeapFree(GetProcessHeap(), 0, d);
    return false;
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static u64 B64Enc(const u8* p, u64 n, char* out)
{
    u64 o = 0;
    for (u64 i = 0; i < n; i += 3) {
        u32 v = (u32)p[i] << 16;
        if (i + 1 < n) v |= (u32)p[i + 1] << 8;
        if (i + 2 < n) v |= p[i + 2];
        out[o++] = B64[(v >> 18) & 63];
        out[o++] = B64[(v >> 12) & 63];
        out[o++] = i + 1 < n ? B64[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < n ? B64[v & 63] : '=';
    }
    return o;
}
static bool B64Dec(const char* s, u64 n, u8* out, u64* outN)    // out must hold n / 4 * 3 + 3 bytes
{
    u64 o = 0; u32 acc = 0; int bits = 0;
    for (u64 i = 0; i < n; i++) {
        char c = s[i]; int v;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
        else if (c >= '0' && c <= '9') v = c - '0' + 52;
        else if (c == '+') v = 62;
        else if (c == '/') v = 63;
        else if (c == '=') break;
        else if (c == '\r' || c == '\n' || c == ' ') continue;
        else return false;
        acc = (acc << 6) | (u32)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; out[o++] = (u8)(acc >> bits); }
    }
    *outN = o;
    return true;
}

// a Grid<T> inside the command's payload: { i32 x0, y0, w, h; T* begin, *end, *capacity }
struct GridHit { u32 off; i32 x0, y0, w, h; u32 elem; u8* cells; u64 bytes; };
static int FindGrids(const u8* pay, GridHit* out, int max)
{
    int n = 0;
    for (u32 off = 0; off + 0x28 <= 0x9b8 && n < max; off += 8) {
        const i32* hd = (const i32*)(pay + off);
        i32 w = hd[2], h = hd[3];
        if (w <= 0 || h <= 0 || w > 16384 || h > 16384) continue;
        u64 b = *(const u64*)(pay + off + 0x10), e = *(const u64*)(pay + off + 0x18), c = *(const u64*)(pay + off + 0x20);
        if (!b || e <= b || c < e || ((b | e) & 3)) continue;
        u64 bytes = e - b, cells = (u64)w * (u64)h;
        u32 elem = 0;
        static const u32 sizes[] = { 8, 1, 2, 4, 12, 16 };
        for (u32 sz : sizes) if (bytes == cells * sz) { elem = sz; break; }
        if (!elem || !Readable((void*)b, bytes)) continue;
        out[n].off = off; out[n].x0 = hd[0]; out[n].y0 = hd[1]; out[n].w = w; out[n].h = h;
        out[n].elem = elem; out[n].cells = (u8*)b; out[n].bytes = bytes;
        n++;
    }
    return n;
}

static void NameFile(char* out, const char* a, long id)
{
    Buf nb; nb.str(a).dec(id).str(".txt");
    nb.s[nb.n] = 0;
    PathOf(out, nb.s);
}

static bool WriteWhole(const char* path, const void* data, u64 n)
{
    HANDLE f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return false;
    bool ok = true;
    const u8* p = (const u8*)data;
    while (n && ok) {
        DWORD chunk = n > (1u << 24) ? (1u << 24) : (DWORD)n, w = 0;
        ok = WriteFile(f, p, chunk, &w, 0) && w == chunk;
        p += chunk; n -= chunk;
    }
    CloseHandle(f);
    return ok;
}

static long g_tSeq = 0;
static u64 g_tRing[8];                     // checksums of the cells injected here, until the command carrying them is applied
static int g_tRingN = 0;
static long g_tPattern = -1;               // MPFEVER_TERRAIN_PATTERN=1 (test): scripted edits get uneven cells
struct TIn { long ready; long id; i32 x0, y0, w, h; u8* raw; u64 fnv; };
static TIn g_tin;

// the originator, when its simulation applies a command that carries height cells
static void TerrainCapture(u8* pay)
{
    GridHit hits[8];
    int n = FindGrids(pay, hits, 8);
    GridHit* hg = 0;
    int extra = 0;
    for (int i = 0; i < n; i++) { if (hits[i].elem == 8 && !hg) hg = &hits[i]; else extra++; }
    if (!hg) {
        // diagnostic (ground paint, tree brush...): a command with grids but no height cells
        static long shown = 0;
        if (n > 0 && shown < 40) {
            shown++;
            Buf b; b.str("terrain: command without height cells, ").dec(n).str(" grid(s):");
            for (int i = 0; i < n && i < 4; i++) b.str(" [+").hex(hits[i].off).str(" ").dec(hits[i].x0).str(",").dec(hits[i].y0).str(" ").dec(hits[i].w).str("x").dec(hits[i].h).str(" elem ").dec(hits[i].elem).str("]");
            LogLine(b);
        }
        return;
    }
    if (hg->bytes > (24ull << 20)) {      // 3 million cells: copying it would stall the game; the mod falls back to a reload
        Buf b; b.str("terrain: edit of ").dec(hg->w).str("x").dec(hg->h).str(" cells is too large to copy"); LogLine(b);
        return;
    }
    u64 fnv = Fnv64(hg->cells, hg->bytes);
    TLock();
    for (int i = 0; i < g_tRingN; i++) if (g_tRing[i] == fnv) {      // the replay of an edit shipped by another game
        g_tRing[i] = g_tRing[--g_tRingN];
        TUnlock();
        Buf b; b.str("terrain: replayed edit applied (").dec(hg->w).str("x").dec(hg->h).str(" cells)"); LogLine(b);
        return;
    }
    TUnlock();
    long id = _InterlockedIncrement(&g_tSeq);
    u64 rawN = 32 + hg->bytes;
    u8* raw = (u8*)HeapAlloc(GetProcessHeap(), 0, rawN);
    u8* pk = (u8*)HeapAlloc(GetProcessHeap(), 0, rawN + rawN / 8 + 64);
    char* txt = (char*)HeapAlloc(GetProcessHeap(), 0, (rawN + rawN / 8 + 64) / 3 * 4 + 16);
    bool ok = false;
    u64 txtN = 0;
    if (raw && pk && txt) {
        memcpy(raw, "MPT1", 4);
        *(u32*)(raw + 4) = 0;
        *(i32*)(raw + 8) = hg->x0; *(i32*)(raw + 12) = hg->y0; *(i32*)(raw + 16) = hg->w; *(i32*)(raw + 20) = hg->h;
        *(u64*)(raw + 24) = fnv;
        memcpy(raw + 32, hg->cells, hg->bytes);
        u64 pn = LzPack(raw, rawN, pk);
        u8* back = 0; u64 backN = 0;
        // check the packing before anything is shipped
        if (LzUnpack(pk, pn, &back, &backN) && backN == rawN && memcmp(back, raw, rawN) == 0) {
            txtN = B64Enc(pk, pn, txt);
            char path[400];
            NameFile(path, "terrain_out_", id);
            ok = WriteWhole(path, txt, txtN);
            if (id > 12) { NameFile(path, "terrain_out_", id - 12); DeleteFileA(path); }
        }
        if (back) HeapFree(GetProcessHeap(), 0, back);
    }
    if (raw) HeapFree(GetProcessHeap(), 0, raw);
    if (pk) HeapFree(GetProcessHeap(), 0, pk);
    if (txt) HeapFree(GetProcessHeap(), 0, txt);
    Buf b;
    b.str("terrain: edit ").dec(id).str(" ").dec(hg->w).str("x").dec(hg->h).str(" cells at ").dec(hg->x0).str(",").dec(hg->y0)
     .str(" (payload +").hex(hg->off).str(", ").dec(hg->bytes).str(" bytes, ").dec(txtN).str(" as text, ").dec(extra).str(" other grid(s)) ")
     .str(ok ? "captured" : "NOT captured");
    LogLine(b);
    if (ok) {
        Buf e;
        e.str("terrain ").dec(id).str(" ").dec(hg->x0).str(" ").dec(hg->y0).str(" ").dec(hg->w).str(" ").dec(hg->h).str(" ").dec(txtN)
         .str(" ").hex(fnv).str(" ").dec(extra);
        AppendEvent(e);
    }
}

// another game's edit, ready to be injected: the mod wrote terrain_in_<id>.txt and asked with "tin <id>"
static void TerrainLoadIn(long id)
{
    char path[400];
    NameFile(path, "terrain_in_", id);
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    bool ok = false;
    u8* raw = 0;
    u64 rawN = 0;
    if (f != INVALID_HANDLE_VALUE) {
        DWORD size = GetFileSize(f, 0), got = 0;
        char* txt = (char*)HeapAlloc(GetProcessHeap(), 0, (u64)size + 8);
        u8* pk = (u8*)HeapAlloc(GetProcessHeap(), 0, (u64)size / 4 * 3 + 16);
        if (txt && pk && ReadFile(f, txt, size, &got, 0) && got == size) {
            u64 pn = 0;
            if (B64Dec(txt, size, pk, &pn) && LzUnpack(pk, pn, &raw, &rawN) && rawN >= 32 && memcmp(raw, "MPT1", 4) == 0) {
                i32 w = *(i32*)(raw + 16), h = *(i32*)(raw + 20);
                u64 bytes = (u64)w * (u64)h * 8;
                ok = w > 0 && h > 0 && rawN == 32 + bytes && Fnv64(raw + 32, bytes) == *(u64*)(raw + 24);
            }
        }
        if (txt) HeapFree(GetProcessHeap(), 0, txt);
        if (pk) HeapFree(GetProcessHeap(), 0, pk);
        CloseHandle(f);
        DeleteFileA(path);
    }
    Buf b;
    if (ok) {
        TLock();
        u8* old = g_tin.raw;
        g_tin.id = id; g_tin.x0 = *(i32*)(raw + 8); g_tin.y0 = *(i32*)(raw + 12); g_tin.w = *(i32*)(raw + 16); g_tin.h = *(i32*)(raw + 20);
        g_tin.fnv = *(u64*)(raw + 24); g_tin.raw = raw; g_tin.ready = 1;
        TUnlock();
        if (old) HeapFree(GetProcessHeap(), 0, old);
        b.str("terrain: edit ").dec(id).str(" received, ").dec(g_tin.w).str("x").dec(g_tin.h).str(" cells at ").dec(g_tin.x0).str(",").dec(g_tin.y0).str(": ready to inject");
        Buf e; e.str("terrain_in ").dec(id).str(" ready"); AppendEvent(e);
    } else {
        if (raw) HeapFree(GetProcessHeap(), 0, raw);
        b.str("terrain: edit ").dec(id).str(" could not be read");
        Buf e; e.str("terrain_in ").dec(id).str(" failed"); AppendEvent(e);
    }
    LogLine(b);
}

// a script command entering the command list: when it carries an empty grid of the size of the received edit, the cells go in
static void TerrainInject(void* cmd)
{
    u8* pay = cmd ? *(u8**)cmd : 0;
    if (!pay || !Readable(pay, 0x9c0) || *(u8*)(pay + 0x9b8) != 52) return;
    GridHit hits[8];
    int n = FindGrids(pay, hits, 8);
    for (int i = 0; i < n; i++) {
        GridHit& g = hits[i];
        if (g.elem != 8) continue;
        TLock();
        if (g_tin.ready && g.x0 == g_tin.x0 && g.y0 == g_tin.y0 && g.w == g_tin.w && g.h == g_tin.h && g.bytes == (u64)g.w * (u64)g.h * 8) {
            memcpy(g.cells, g_tin.raw + 32, g.bytes);
            g_tin.ready = 0;
            if (g_tRingN >= 8) { for (int k = 1; k < 8; k++) g_tRing[k - 1] = g_tRing[k]; g_tRingN = 7; }
            g_tRing[g_tRingN++] = g_tin.fnv;
            long id = g_tin.id;
            TUnlock();
            Buf b; b.str("terrain: edit ").dec(id).str(" injected into the command (").dec(g.w).str("x").dec(g.h).str(" cells)"); LogLine(b);
            Buf e; e.str("terrain_in ").dec(id).str(" injected"); AppendEvent(e);
            return;
        }
        TUnlock();
    }
}

// test mode: a scripted edit has a flat grid; give its cells a pattern so that the copy can be checked cell by cell
static void TerrainPattern(void* cmd)
{
    u8* pay = cmd ? *(u8**)cmd : 0;
    if (!pay || !Readable(pay, 0x9c0) || *(u8*)(pay + 0x9b8) != 52) return;
    GridHit hits[8];
    int n = FindGrids(pay, hits, 8);
    for (int i = 0; i < n; i++) {
        if (hits[i].elem != 8) continue;
        float* c = (float*)hits[i].cells;
        u64 cells = hits[i].bytes / 8;
        for (u64 k = 0; k < cells; k++) c[2 * k] += (float)(((k * 2654435761ull) >> 12) & 1023) * 0.002f;     // noise: it does not pack
        Buf b; b.str("terrain: test pattern written into ").dec(cells).str(" cells"); LogLine(b);
        return;
    }
}

// diagnostic (MPFEVER_PAYLOAD_DUMP=1): the payload of the first world-build commands as hex, to find where the Context flags are
static volatile long g_dumpOn = 0, g_dumpN = 0;
static void DumpPayload(const u8* pay, const char* tag)
{
    long n = _InterlockedIncrement(&g_dumpN);
    if (n > 60) return;
    static const char hx[] = "0123456789abcdef";
    char* txt = (char*)HeapAlloc(GetProcessHeap(), 0, 0x9c0 * 2 + 64);
    if (!txt) return;
    u64 o = 0;
    for (u32 i = 0; i < 0x9c0; i++) { txt[o++] = hx[pay[i] >> 4]; txt[o++] = hx[pay[i] & 15]; }
    txt[o++] = '\n';
    char path[400];
    Buf nb; nb.str("payload_").dec(n).str("_").str(tag).str(".txt"); nb.s[nb.n] = 0;
    PathOf(path, nb.s);
    WriteWhole(path, txt, o);
    HeapFree(GetProcessHeap(), 0, txt);
}

// Writes the machine's company (player entity) into the game state's local-player word. The word is read by the interface and the
// native tools (they act as that player), and re-written whenever a loaded game replaced the state object.
// The simulation must run every game with the same company in that word (else a game playing another company simulates
// differently: a road vehicle of the savegame company drove faster on the client, the money followed): the word keeps the
// savegame's company (g_canon) and the interface's readings of it are redirected to this machine's company (PatchPlayerReads).
static long g_split = -1;
static bool SplitWord()
{
    if (g_split < 0) { char v[4]; g_split = GetEnvironmentVariableA("MPFEVER_NOSPLIT", v, 3) > 0 ? 0 : 1; }
    return g_split && g_canon && g_localPlayer && g_canon != g_localPlayer;
}

static void ApplyLocalPlayer(const char* why)
{
    // The engine has more than one game-state object calling Apply (two were seen next to each other at the start of a game): the
    // word is written into every one, at the moment it applies a command (so it is alive). A state never seen before while a
    // value is set is a game that has just been loaded (resynchronisation): the entity ids of the previous one mean nothing
    // there until the mod asks again (it does, every few seconds).
    static void* seen[16]; static int nseen = 0;
    bool known = false;
    for (int i = 0; i < nseen; i++) if (seen[i] == g_slot) known = true;
    if (!known) {
        if (nseen < 16) seen[nseen++] = g_slot; else seen[0] = g_slot;
        if (g_localPlayer) {
            Buf b; b.str("local player ").dec(g_localPlayer).str(" dropped: a new game state ").hex((u64)g_slot); LogLine(b);
            g_localPlayer = 0;
            return;
        }
    }
    long want = g_localPlayer;
    if (!want || !g_slot) return;
    if (SplitWord()) want = g_canon;
    volatile u32* w = (volatile u32*)((u8*)g_slot + 0x20c);
    u32 cur = *w;
    if (cur == (u32)want) return;
    *w = (u32)want;
    static long shown = 0;
    if (shown++ >= 40) return;
    Buf b; b.str("local player ").dec(cur).str(" -> ").dec(want).str(" (").str(why).str(", state ").hex((u64)g_slot).str(")"); LogLine(b);
}

extern "C" u64 ReplDetour(void* src, void* dst, u64 flag)
{
    u32 before = dst ? *(u32*)((u8*)dst + 0x20c) : 0;
    // end of a simulation iteration: the positions the other companies earned during it are emptied before the state is copied for
    // the interface, so that it never shows the money popups of the companies this machine does not play
    static long replClear = -1;
    if (replClear < 0) { char v[4]; replClear = GetEnvironmentVariableA("MPFEVER_NOREPLCLEAR", v, 3) > 0 ? 0 : 1; }
    if (replClear && (u32)((uptr)_ReturnAddress() - g_base) == RVA_REPL_LOOP) ClearOthersIn((u8*)src, false);
    WatchAdd((u8*)src); WatchAdd((u8*)dst);
    u64 r = g_replOrig(src, dst, flag);
    static long n = 0;
    if (n < 80) {
        n++;
        Buf b; b.str("replicate ").hex((u64)src).str(" (word ").dec(src ? *(u32*)((u8*)src + 0x20c) : 0).str(") -> ").hex((u64)dst)
            .str(" (word ").dec(before).str(" -> ").dec(dst ? *(u32*)((u8*)dst + 0x20c) : 0).str(") from ").hex((u32)((uptr)_ReturnAddress() - g_base))
            .str(", Apply states ").hex((u64)g_slot);
        LogLine(b);
    }
    return r;
}

extern "C" u64 ApplyDetour(void* a, void* b)
{
    g_slot = a;
    ApplyLocalPlayer("apply");
    u8* pay = *(u8**)b;
    bool inLoop = (u32)((uptr)_ReturnAddress() - g_base) == RVA_LOOP_RET;    // the loop of RunGameSimLoop (the other callers apply one command at once)
    u32 kind = pay ? *(u8*)(pay + 0x9b8) : 255;
    if (kind < 128) { if (inLoop) g_kcLoop[kind]++; else g_kcDir[kind]++; }
    AuditFlush(false);
    if (kind == 52) TerrainCapture(pay);
    if (!g_timing) return g_applyOrig(a, b);
    if (g_gateMs) Sleep((DWORD)g_gateMs);       // test: does blocking here slow the simulation step by step?
    {
        static long lastShown = -2;
        long cur = *(long*)((u8*)a + 0x208);
        if (cur != lastShown) { lastShown = cur; TimingLine("world-entity", (u64)cur, (u64)a); }
        Buf l; l.str("tm ").dec(NowUs()).str(" cmd-kind ").dec(kind).str(inLoop ? " loop" : " direct").str(" iter ").dec(g_iter); LogLine(l);
    }
    if (inLoop && g_deferIters > 0 && NowUs() > g_deferAfterUs && g_defTail - g_defHead < 250) {
        void* buf = HeapAlloc(GetProcessHeap(), 8, 0x40);
        if (buf) {
            ((MoveCtor0)(g_base + RVA_CMD_MOVE))(buf, b);
            Deferred& d = g_def[g_defTail % 256];
            d.cmd = buf; d.queued = g_iter; d.due = g_iter + g_deferIters; d.exact = false;
            g_defTail++;
            return 0;
        }
    }
    u64 r = g_applyOrig(a, b);
    TimingLine("apply-end", r, 0);
    return r;
}

typedef void (*Dtor)(void*);
typedef void* (*MoveCtor)(void*, void*);

static void ReleaseOne()
{
    if (g_heldHead == g_heldTail) return;
    Held* h = g_held[g_heldHead % 64];
    g_heldHead++;
    alignas(16) u8 out[0x10];
    memset(out, 0, sizeof(out));
    g_addOrig(h->list, out, h->cmd, h->done, h->progress);
    ((Dtor)(g_base + RVA_HANDLE_DTOR))(out);
    ((Dtor)(g_base + RVA_CMD_DTOR))(h->cmd);
    if (g_timing) TimingLine("release", h->id, 0);
    Buf b; b.str("released build ").dec(h->id).str(" (tool site ").hex(h->site).str(")"); LogLine(b);
}

static bool Writable(const void* p, u64 n)
{
    u64 a = (u64)p, end = a + n;
    while (a < end) {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery((void*)a, &mi, sizeof(mi))) return false;
        if (mi.State != 0x1000 || (mi.Protect & 0x101) || !(mi.Protect & 0xCC)) return false;     // not guarded / no access; writable
        a = (u64)mi.BaseAddress + mi.RegionSize;
    }
    return true;
}

// The interface's construction tools issue their builds for the savegame's company (its entity is written everywhere in the command:
// the context's player at +0x36c, the owner of each new construction, street segment, stop...), whatever company this machine
// plays. A machine playing another company has the savegame company's entity replaced by its own in the command held at the tool's
// Add: it then builds, pays and owns for its own company. Only the command's own vectors (begin/end/capacity triples stored in the
// first 0x9c0 bytes) are visited, and only words equal to the savegame company's entity change. Returns the number of words changed.
static int OwnerFix(u8* pay, u32 from, u32 to, int* inVectors)
{
    int n = 0, nv = 0;
    u32* cp = (u32*)(pay + 0x36c);
    if (*cp == from) { *cp = to; n++; }
    for (int o = 0; o + 24 <= 0x9c0; o += 8) {
        u64 b = *(u64*)(pay + o), e = *(u64*)(pay + o + 8), c = *(u64*)(pay + o + 16);
        if (b < 0x10000 || b > 0x00007fffffffffffull || e <= b || c < e) continue;
        if (((e - b) & 3) || (e - b) > (32u << 20) || (c - b) > (64u << 20)) continue;
        if (!Writable((void*)b, e - b)) continue;
        for (u32* q = (u32*)b; q < (u32*)e; q++) if (*q == from) { *q = to; n++; nv++; }
    }
    if (inVectors) *inVectors = nv;
    return n;
}

extern "C" void* AddDetour(void* list, void* out, void* cmd, void* done, void* progress)
{
    { static long once = 0; if (_InterlockedIncrement(&once) == 1) { Buf t; t.str("commands added from thread ").dec(GetCurrentThreadId()); LogLine(t); } }
    u32 caller = (u32)((uptr)_ReturnAddress() - g_base);
    if (g_timing) TimingLine("add", caller, g_released);
    if (!g_inRelease) ReadControl();
    if (g_tin.ready) TerrainInject(cmd);
    else if (g_tPattern > 0) TerrainPattern(cmd);
    {   // which Context flags the tools build with (found by comparing commands that differ by one flag): logged once per caller and set of flags
        u8* pay = cmd ? *(u8**)cmd : 0;
        if (pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52) {
            u32 bits = (pay[0x358] ? 1u : 0) | (pay[0x360] ? 2u : 0) | (pay[0x362] ? 4u : 0) | (pay[0x3d1] ? 8u : 0) | (pay[0x3d2] ? 16u : 0);
            u64 key = ((u64)caller << 8) | bits;
            static u64 seen[64];
            static volatile long nseen = 0;
            bool fresh = true;
            long n = nseen;
            for (long k = 0; k < n && k < 64; k++) if (seen[k] == key) { fresh = false; break; }
            if (fresh && n < 64) {
                seen[n] = key;
                nseen = n + 1;
                Buf b; b.str("build context from ").hex(caller).str(": gatherBuildings ").dec(bits & 1).str(" terrainAlignment ").dec((bits >> 1) & 1)
                    .str(" cleanupStreetGraph ").dec((bits >> 2) & 1).str(" ignoreErrors ").dec((bits >> 3) & 1).str(" playerInitiated ").dec((bits >> 4) & 1);
                LogLine(b);
            }
        }
    }
    if (g_dumpOn) { u8* pay = cmd ? *(u8**)cmd : 0; if (pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52) { char t[16]; Buf tb; tb.str("c").hex(caller); for (int i = 0; i < tb.n && i < 15; i++) t[i] = tb.s[i]; t[tb.n < 15 ? tb.n : 15] = 0; DumpPayload(pay, t); } }
    if (IsUiSite(caller)) {
        u8* pay = cmd ? *(u8**)cmd : 0;
        if (pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52) {
            u32 ctxBefore = *(u32*)(pay + 0x36c);
            int nv = 0, n = 0;
            bool fix = g_canon && g_localPlayer && g_canon != g_localPlayer;
            if (fix) n = OwnerFix(pay, (u32)g_canon, (u32)g_localPlayer, &nv);
            static long shown = 0;
            if (shown++ < 60) {
                Buf b; b.str("tool build from ").hex(caller).str(": context player ").dec(ctxBefore).str(", this machine plays ").dec(g_localPlayer)
                    .str(", savegame company ").dec(g_canon);
                if (fix) b.str(": ").dec(n).str(" owner word(s) changed, ").dec(nv).str(" of them in vectors");
                LogLine(b);
            }
        }
    }
    bool testDefer = false;
    // (test mode removed: the Lua sendCommand path reads the command back through Add's out handle, which a deferral
    // leaves empty; only the UI tool sites, which merely destroy that handle, can be held)
    if (IsUiSite(caller) || testDefer) {
        if ((g_enabled || testDefer) && g_heldTail - g_heldHead < 60) {
            Held* h = (Held*)HeapAlloc(GetProcessHeap(), 8, sizeof(Held));
            if (h) {
                h->list = list;
                h->site = caller;
                h->id = ++g_nextId;
                ((MoveCtor)(g_base + RVA_CMD_MOVE))(h->cmd, cmd);
                MoveFunction(h->done, (u8*)done);
                memcpy(h->progress, progress, 0x10);
                memset(progress, 0, 0x10);
                memset(out, 0, 0x10);
                g_held[g_heldTail % 64] = h;
                g_heldTail++;
                Buf b; b.str("deferred build ").dec(h->id).str(" from tool site ").hex(caller); LogLine(b);
                Buf e; e.str("deferred ").dec(h->id); AppendEvent(e);
                return out;
            }
        }
        return g_addOrig(list, out, cmd, done, progress);
    }
    // any other command (the mod's own commands included): the moment to release what the mod asked for
    if (g_heldHead != g_heldTail && !g_inRelease) {
        // Builds held for a game that has been unloaded since (resynchronisation) are never released: their command list and the
        // objects they point at are gone (releasing one crashed the game). They are left alone (not destroyed either) and count as
        // released, as the mod, restarted with the new game, never asks for them.
        if (g_dropHeld) {
            int n = 0;
            while (g_heldHead != g_heldTail && g_held[g_heldHead % 64]->id <= g_dropId) { g_heldHead++; n++; }
            g_dropHeld = 0;
            // (the new game's mod continues the count of the releases asked for: those of the previous game are done)
            if (g_released < g_dropTarget) g_released = g_dropTarget;
            Buf b; b.str("held build(s) of the previous game dropped: ").dec(n); LogLine(b);
        }
        if (g_heldHead != g_heldTail && g_released < g_releaseTarget) {
            (void)list;
            g_inRelease = 1;
            while (g_released < g_releaseTarget && g_heldHead != g_heldTail) { ReleaseOne(); g_released++; }
            g_inRelease = 0;
        }
    }
    return g_addOrig(list, out, cmd, done, progress);
}

static bool InstallDetour(u32 rva, const u8* expect, int steal, void* detour, void** origOut)
{
    u8* target = (u8*)(g_base + rva);
    if (memcmp(target, expect, steal) != 0) {
        Buf b; b.str("detour at ").hex(rva).str(": unexpected bytes, not installed"); LogLine(b);
        return false;
    }
    u8* tramp = (u8*)VirtualAlloc(0, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) return false;
    memcpy(tramp, target, steal);
    WriteAbsJump(tramp + steal, (uptr)target + steal);
    FlushInstructionCache(GetCurrentProcess(), tramp, steal + 14);
    *origOut = tramp;
    DWORD old;
    if (!VirtualProtect(target, steal, PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[32];
    WriteAbsJump(patch, (uptr)detour);
    for (int k = 14; k < steal; k++) patch[k] = 0xCC;
    memcpy(target, patch, steal);
    VirtualProtect(target, steal, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, steal);
    Buf b; b.str("detour installed at ").hex(rva); LogLine(b);
    return true;
}

// ---------------------------------------------------------------- serial pool (MPFEVER_SERIAL=rva,rva,...)
// Some simulation systems hand their work to the engine's thread pool, and the result then depends on which worker
// finishes first (the games drift apart). The task submission functions listed in MPFEVER_SERIAL are redirected to a
// pool of the engine's own kind with ONE worker: their tasks run one after the other, in submission order, while every
// other system, the renderer and the loaders keep all the processor's cores.
static const u32 RVA_POOL_CTOR = 0x3055a10;    // ThreadPool::ThreadPool(this, const std::string& name, int threads, bool)
static const u8 P_ENQ[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x18, 0x48, 0x89, 0x7C, 0x24, 0x20 };
static void* volatile g_serialPool = 0;

struct MsvcString { char buf[16]; u64 size; u64 cap; };
typedef void* (*PoolCtor)(void* self, MsvcString* name, int threads, bool flag);

static void* MakeSerialPool()
{
    u8* mem = (u8*)HeapAlloc(GetProcessHeap(), 8 /* HEAP_ZERO_MEMORY */, 0xe0 + 64);
    if (!mem) return 0;
    mem = (u8*)(((uptr)mem + 31) & ~(uptr)31);
    MsvcString name;
    memset(&name, 0, sizeof(name));
    const char* n = "MPFever Serial";
    int k = 0;
    while (n[k]) { name.buf[k] = n[k]; k++; }
    name.size = (u64)k;
    name.cap = 15;
    ((PoolCtor)(g_base + RVA_POOL_CTOR))(mem, &name, 1, true);
    return mem;
}

// the pool is made on the first redirected submission (the engine is running by then)
static volatile long g_poolLock = 0;
extern "C" void* EnsureSerialPool()
{
    if (g_serialPool) return g_serialPool;
    while (_InterlockedExchange(&g_poolLock, 1)) Sleep(0);
    if (!g_serialPool) {
        g_serialPool = MakeSerialPool();
        Buf b; b.str("serial pool created at ").hex((uptr)g_serialPool); LogLine(b);
    }
    _InterlockedExchange(&g_poolLock, 0);
    return g_serialPool;
}

static bool SerializeSite(u32 rva)
{
    u8* target = (u8*)(g_base + rva);
    Buf b;
    if (memcmp(target, P_ENQ, sizeof(P_ENQ)) != 0) { b.str("serial site ").hex(rva).str(": unexpected bytes, skipped"); LogLine(b); return false; }
    u8* c = (u8*)VirtualAlloc(0, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!c) return false;
    int i = 0;
    static const u8 pre[] = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28 };   // push rcx rdx r8 r9 / sub rsp,28
    for (u8 x : pre) c[i++] = x;
    c[i++] = 0x48; c[i++] = 0xB8; *(u64*)(c + i) = (u64)&EnsureSerialPool; i += 8;           // mov rax, EnsureSerialPool
    c[i++] = 0xFF; c[i++] = 0xD0;                                                             // call rax
    static const u8 post[] = { 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59,   // add rsp,28 / pop r9 r8 rdx rcx
                               0x48, 0x85, 0xC0, 0x74, 0x03, 0x48, 0x89, 0xC1 };             // test rax,rax / jz +3 / mov rcx,rax
    for (u8 x : post) c[i++] = x;
    memcpy(c + i, P_ENQ, sizeof(P_ENQ)); i += sizeof(P_ENQ);                      // the instructions replaced below
    WriteAbsJump(c + i, (uptr)target + sizeof(P_ENQ)); i += 14;
    FlushInstructionCache(GetCurrentProcess(), c, i);
    DWORD old;
    if (!VirtualProtect(target, sizeof(P_ENQ), PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[16];
    WriteAbsJump(patch, (uptr)c);
    patch[14] = 0xCC;
    memcpy(target, patch, sizeof(P_ENQ));
    VirtualProtect(target, sizeof(P_ENQ), old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof(P_ENQ));
    b.str("serial site ").hex(rva).str(" redirected");
    LogLine(b);
    return true;
}

static void SetupSerial()
{
    char v[2048] = {};
    DWORD n = GetEnvironmentVariableA("MPFEVER_SERIAL", v, sizeof(v) - 1);
    if (n == 0 || n >= sizeof(v) - 1) return;
    u32 cur = 0; bool any = false;
    for (DWORD i = 0; i <= n; i++) {
        char ch = v[i];
        int d = (ch >= '0' && ch <= '9') ? ch - '0' : (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10 : (ch >= 'A' && ch <= 'F') ? ch - 'A' + 10 : -1;
        if (d >= 0 && !(ch == 'x' || ch == 'X')) { cur = cur * 16 + d; any = true; }
        else if (ch == 'x' || ch == 'X') { cur = 0; any = false; }
        else { if (any) SerializeSite(cur); cur = 0; any = false; }
    }
}

static bool g_scriptPoolPatched = false;
static u32 g_simPoolA = 0, g_simPoolB = 0;
static u32 g_threads = 0;
typedef void (WINAPI* GetSystemInfoF)(void*);
static GetSystemInfoF g_realGetSystemInfo = 0;

// ---------------------------------------------------------------- Steam invitations
// MPFever.exe writes steam_ctl.txt (one command, rewritten each time): "<seq> presence <connect>" makes the player
// joinable from the Steam friends list (rich presence "connect"), "<seq> invite <connect>" opens Steam's invite dialog,
// "<seq> clear" removes the presence. A friend who accepts while the game runs: Steam's GameRichPresenceJoinRequested
// callback (337) writes steam_join.txt for MPFever.exe. A friend whose game is closed: Steam starts the game with the
// connect string on its command line (see ColdJoin).
typedef void* (*SteamIfaceF)();
typedef bool (*SetRichPresenceF)(void* self, const char* key, const char* value);
typedef void (*ClearRichPresenceF)(void* self);
typedef void (*InviteConnectF)(void* self, const char* connect);
typedef void (*RegisterCallbackF)(void* cb, int id);

extern "C" char __ImageBase;

class JoinCallback {
public:
    // same virtual layout as Steam's CCallbackBase (Run overloads, then GetCallbackSizeBytes)
    virtual void Run(void* param);
    virtual void Run(void* param, bool ioFailure, u64 call);
    virtual int GetCallbackSizeBytes();
    u8 flags;
    int id;
};

static void WriteSessionFile(const char* name, const char* text, int len)
{
    char path[400];
    PathOf(path, name);
    HANDLE f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, 2 /* CREATE_ALWAYS */, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD w;
    WriteFile(f, text, (DWORD)len, &w, 0);
    CloseHandle(f);
}

void JoinCallback::Run(void* param)
{
    // GameRichPresenceJoinRequested_t { CSteamID friend; char connect[256]; }
    const char* connect = (const char*)param + 8;
    int n = 0;
    while (n < 255 && connect[n]) n++;
    static long seq = 0;
    Buf b;
    b.dec(GetTickCount()).str("-").dec(_InterlockedIncrement(&seq)).str("\t");
    for (int i = 0; i < n; i++) b.s[b.n++] = connect[i];
    b.s[b.n++] = '\n';
    WriteSessionFile("steam_join.txt", b.s, b.n);
    Buf l; l.str("steam: join requested by a friend"); LogLine(l);
}
void JoinCallback::Run(void* param, bool, u64) { Run(param); }
int JoinCallback::GetCallbackSizeBytes() { return 8 + 256; }

static JoinCallback g_joinCb;


// Exploration (MPFEVER_SCANPLAYER=n): which memory holds the local player's entity id? Lists the 4-byte aligned words equal to n
// in the writable memory, flagging those inside the game's own image.
static DWORD WINAPI ScanThread(void* arg)
{
    u32 want = (u32)(uptr)arg;
    char dl[16]; DWORD dn = GetEnvironmentVariableA("MPFEVER_SCAN_DELAY_S", dl, 15); long delay = 50;
    if (dn) { delay = 0; for (DWORD i = 0; i < dn && dl[i] >= '0' && dl[i] <= '9'; i++) delay = delay * 10 + (dl[i] - '0'); }
    Sleep((DWORD)delay * 1000);
    u8* p = 0; int found = 0, inImage = 0;
    u64 imgLo = g_base, imgHi = g_base + 0x4000000;
    for (;;) {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery(p, &mi, sizeof(mi))) break;
        bool rw = mi.State == 0x1000 && (mi.Protect == 0x04 || mi.Protect == 0x40) ;
        if (rw && mi.RegionSize < 0x40000000) {
            u32* q = (u32*)mi.BaseAddress;
            u64 n = mi.RegionSize / 4;
            for (u64 k = 0; k < n; k++) {
                if (q[k] == want) {
                    found++;
                    if (g_nhits < 600) g_hits[g_nhits++] = &q[k];
                    u64 a = (u64)&q[k];
                    bool img = a >= imgLo && a < imgHi;
                    if (img) inImage++;
                    if (found <= 60 || img) {
                        Buf b; b.str("scan hit ").hex(a).str(img ? " IMAGE rva " : " heap region ").hex(img ? a - g_base : (u64)mi.BaseAddress).str(" size ").hex(mi.RegionSize); LogLine(b);
                    }
                }
            }
        }
        p = (u8*)mi.BaseAddress + mi.RegionSize;
    }
    Buf b; b.str("scan done: ").dec(found).str(" hits, ").dec(inImage).str(" in the image"); LogLine(b);
    return 0;
}

static DWORD WINAPI SteamThread(void*)
{
    HMODULE sa = 0;
    void* friends = 0;
    for (int i = 0; i < 600 && !friends; i++) {   // the game initialises Steam during its start
        Sleep(500);
        if (!sa) sa = GetModuleHandleW(L"steam_api64.dll");
        if (!sa) continue;
        auto get = (SteamIfaceF)GetProcAddress(sa, "SteamAPI_SteamFriends_v017");
        if (get) friends = get();
    }
    if (!friends) { Buf b; b.str("steam: friends interface not available, invitations off"); LogLine(b); return 0; }
    auto setRp = (SetRichPresenceF)GetProcAddress(sa, "SteamAPI_ISteamFriends_SetRichPresence");
    auto clearRp = (ClearRichPresenceF)GetProcAddress(sa, "SteamAPI_ISteamFriends_ClearRichPresence");
    auto invite = (InviteConnectF)GetProcAddress(sa, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString");
    auto reg = (RegisterCallbackF)GetProcAddress(sa, "SteamAPI_RegisterCallback");
    if (reg) reg(&g_joinCb, 337);
    { Buf b; b.str("steam: invitations ready").str(reg ? "" : " (no join callback)"); LogLine(b); }
    // the player's Steam account (steam_id.txt): the mod knows a player by it, whatever name the player types
    {
        typedef u64 (*GetSteamIdF)(void* self);
        auto getUser = (SteamIfaceF)GetProcAddress(sa, "SteamAPI_SteamUser_v023");
        auto getId = (GetSteamIdF)GetProcAddress(sa, "SteamAPI_ISteamUser_GetSteamID");
        void* user = getUser ? getUser() : 0;
        u64 sid = (user && getId) ? getId(user) : 0;
        if (sid) {
            Buf b; b.dec(sid).str("\n");
            WriteSessionFile("steam_id.txt", b.s, b.n);
        }
        Buf l; l.str("steam: account ").str(sid ? "known" : "unknown"); LogLine(l);
    }
    char last[64] = {};
    static char buf[1024];
    for (;;) {
        Sleep(250);
        char path[400];
        PathOf(path, "steam_ctl.txt");
        HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | 4, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (f == INVALID_HANDLE_VALUE) continue;
        DWORD got = 0;
        ReadFile(f, buf, sizeof(buf) - 1, &got, 0);
        CloseHandle(f);
        buf[got] = 0;
        while (got && (buf[got - 1] == '\n' || buf[got - 1] == '\r')) buf[--got] = 0;
        // "<seq> <command> [argument]"
        int a = 0;
        while (buf[a] && buf[a] != ' ') a++;
        if (!buf[a] || a >= 63) continue;
        buf[a] = 0;
        if (!memcmp(buf, last, a + 1)) continue;
        memcpy(last, buf, a + 1);
        char* cmd = buf + a + 1;
        int c = 0;
        while (cmd[c] && cmd[c] != ' ') c++;
        char* arg = cmd[c] ? cmd + c + 1 : cmd + c;
        cmd[c] = 0;
        Buf l; l.str("steam: ").str(cmd).str(" ").str(arg); LogLine(l);
        if (!memcmp(cmd, "presence", 9) && setRp) { setRp(friends, "connect", arg); setRp(friends, "status", "MPFever"); }
        else if (!memcmp(cmd, "invite", 7) && invite) invite(friends, arg);
        else if (!memcmp(cmd, "clear", 6) && clearRp) clearRp(friends);
    }
}

// Started by Steam from an invitation ("+mpfever_connect <address>" on the command line) without MPFever: MPFever.exe,
// whose path the launcher wrote next to this module (mpfever_path.txt), is started with --join, and this game quits
// (MPFever starts its own).
static bool ColdJoin()
{
    const wchar_t* cl = GetCommandLineW();
    const wchar_t* key = L"+mpfever_connect";
    const wchar_t* at = 0;
    for (const wchar_t* p = cl; *p && !at; p++) {
        int k = 0;
        while (key[k] && p[k] == key[k]) k++;
        if (!key[k]) at = p + k;
    }
    if (!at) return false;
    while (*at == ' ' || *at == '"') at++;
    wchar_t addr[128];
    int n = 0;
    while (at[n] && at[n] != ' ' && at[n] != '"' && n < 127) { addr[n] = at[n]; n++; }
    addr[n] = 0;
    // MPFever.exe path: mpfever_path.txt next to this module (UTF-16 written by the launcher)
    wchar_t mod[300];
    DWORD ml = GetModuleFileNameW((HMODULE)&__ImageBase, mod, 260);
    while (ml && mod[ml - 1] != '\\') ml--;
    const wchar_t* fname = L"mpfever_path.txt";
    for (int k = 0; fname[k]; k++) mod[ml++] = fname[k];
    mod[ml] = 0;
    char modA[300];
    for (DWORD k = 0; k <= ml; k++) modA[k] = (char)mod[k];   // ASCII-only paths only for CreateFileA
    HANDLE f = CreateFileA(modA, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return false;
    static wchar_t exe[300];
    DWORD got = 0;
    ReadFile(f, exe, sizeof(exe) - 2, &got, 0);
    CloseHandle(f);
    int el = (int)(got / 2);
    if (el && exe[0] == 0xFEFF) { for (int k = 1; k < el; k++) exe[k - 1] = exe[k]; el--; }
    while (el && (exe[el - 1] == '\n' || exe[el - 1] == '\r')) el--;
    exe[el] = 0;
    if (!el) return false;
    static wchar_t cmd[600];
    int k = 0;
    cmd[k++] = '"';
    for (int i = 0; exe[i]; i++) cmd[k++] = exe[i];
    const wchar_t* mid = L"\" --join ";
    for (int i = 0; mid[i]; i++) cmd[k++] = mid[i];
    for (int i = 0; addr[i]; i++) cmd[k++] = addr[i];
    cmd[k] = 0;
    STARTUPINFOW_ si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION_ pi = {};
    if (!CreateProcessW(0, cmd, 0, 0, 0, 0, 0, 0, &si, &pi)) return false;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    TerminateProcess(GetCurrentProcess(), 0);
    return true;
}


static bool SelectBuild(u32 stamp)
{
    for (const BuildAddrs& b : BUILDS) {
        if (b.stamp != stamp) continue;
        RVA_ADD = b.add; RVA_CMD_MOVE = b.move; RVA_CMD_DTOR = b.dtor; RVA_HANDLE_DTOR = b.handleDtor; RVA_APPLY = b.apply;
        RVA_SWAP = b.swap; RVA_SYNC = b.sync; RVA_PREITER = b.preIter; RVA_LOOP_RET = b.loopRet;
        RVA_REPL = (stamp == 0x6ac50427) ? 0x255e60 : 0;      // build 40420 only
        RVA_REPL_LOOP = (stamp == 0x6ac50427) ? 0x11ea9f : 0;      // return address of the simulation loop's call
        UI_ADD_SITES = b.sites; UI_ADD_N = b.nSites;
        g_knownLua = b.lua; g_knownPool = b.pool;
        return true;
    }
    return false;
}

// Finds a code pattern in the game's .text (the whole section); returns its address if it occurs exactly once.
static u8* FindUnique(uptr base, const u8* pat, int len, u32 hintRva = 0)
{
    if (hintRva && memcmp((u8*)(base + hintRva), pat, len) == 0) return (u8*)(base + hintRva);
    auto dos = (IMAGE_DOS_HEADER_*)base;
    u8* ntp = (u8*)(base + dos->e_lfanew);
    auto fh = (IMAGE_FILE_HEADER_*)(ntp + 4);
    auto sec = (IMAGE_SECTION_HEADER_*)(ntp + 4 + sizeof(IMAGE_FILE_HEADER_) + fh->SizeOfOptionalHeader);
    for (int i = 0; i < fh->NumberOfSections; i++) {
        if (!(sec[i].Name[0] == '.' && sec[i].Name[1] == 't' && sec[i].Name[2] == 'e' && sec[i].Name[3] == 'x')) continue;
        u8* start = (u8*)(base + sec[i].VirtualAddress);
        u64 size = sec[i].VirtualSize;
        u8* found = 0;
        int count = 0;
        for (u64 k = 0; k + len <= size; k++) {
            if (start[k] != pat[0]) continue;
            if (memcmp(start + k, pat, len) == 0) { if (!found) found = start + k; count++; if (count > 1) return 0; }
        }
        return count == 1 ? found : 0;
    }
    return 0;
}

// ---------------------------------------------------------------- the local player, for the interface only
// In the companies mode the word at game state +0x20c is this machine's company (the interface and its tools act as it). The game's
// scripts also run in the simulation, on other threads, and ask the engine for "the player" there too: api.engine.util.getPlayer
// (binding 0x24f0970) and another binding that passes it on (0x24da690). There, every game must get the SAME company (the
// savegame's, g_canon), else each game's simulation follows another company and the games drift apart (a passenger, a payment...).
// Both readings are redirected to a stub: on any thread but the main (interface) thread, and once the canon is known, the canon.

static u8* EmitImm64(u8* p, u64 v) { *(u64*)p = v; return p + 8; }

static bool PatchPlayerRead(u32 siteRva, const u8* expect, int expectLen, int siteLen, u8* stub, int stubLen)
{
    u8* site = (u8*)(g_base + siteRva);
    if (memcmp(site, expect, expectLen) != 0) { Buf b; b.str("player read at ").hex(siteRva).str(": unexpected code, left alone"); LogLine(b); return false; }
    DWORD old;
    if (!VirtualProtect(site, siteLen, PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[32];
    patch[0] = 0xFF; patch[1] = 0x25; *(u32*)(patch + 2) = 0; *(u64*)(patch + 6) = (u64)stub;
    for (int k = 14; k < siteLen; k++) patch[k] = 0x90;
    memcpy(site, patch, siteLen);
    VirtualProtect(site, siteLen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, siteLen);
    (void)stubLen;
    return true;
}

// After the word's value is read into a register: r11d = the main thread ? this machine's company : the canon (when known), into
// the register (dstMov = the bytes of "mov <reg>,r11d"). Uses r10 and r11 only (free at every site below).
static int g_pickSite = 0;
// simByThread: the simulation thread gets the canon, every other thread this machine's company (api.engine.util.getPlayer: the
// interface's Lua also runs on threads other than the main one); else the main thread gets this machine's company, the others the canon.
static u8* EmitPick(u8* p, const u8* dstMov, int dstLen, bool simByThread = false)
{
    {   // count the readings per thread kind (logged with the audit)
        volatile i64* c = g_pickCount[g_pickSite & 7];
        g_pickSite++;
        *p++ = 0x65; *p++ = 0x44; *p++ = 0x8B; *p++ = 0x1C; *p++ = 0x25; *p++ = 0x48; *p++ = 0; *p++ = 0; *p++ = 0;   // mov r11d,gs:[48h]
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_mainTid);              // mov r10,&mainTid
        *p++ = 0x45; *p++ = 0x3B; *p++ = 0x1A;                                     // cmp r11d,[r10]
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&c[0]);                    // mov r10,&main
        *p++ = 0x74; *p++ = 0x23;                                                  // je INC
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_simTid);               // mov r10,&simTid
        *p++ = 0x45; *p++ = 0x3B; *p++ = 0x1A;                                     // cmp r11d,[r10]
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&c[1]);                    // mov r10,&sim
        *p++ = 0x74; *p++ = 0x0A;                                                  // je INC
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&c[2]);                    // mov r10,&other
        *p++ = 0xF0; *p++ = 0x49; *p++ = 0xFF; *p++ = 0x02;                        // INC: lock inc qword [r10]
    }
    *p++ = 0x65; *p++ = 0x44; *p++ = 0x8B; *p++ = 0x1C; *p++ = 0x25; *p++ = 0x48; *p++ = 0; *p++ = 0; *p++ = 0;   // mov r11d,gs:[48h]
    if (simByThread) {
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_simTid);               // mov r10,&simTid
        *p++ = 0x45; *p++ = 0x3B; *p++ = 0x1A;                                     // cmp r11d,[r10]
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_canon);                // mov r10,&canon
        *p++ = 0x74; *p++ = 0x0A;                                                  // je L0 (the simulation: the canon)
    } else {
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_mainTid);              // mov r10,&mainTid
        *p++ = 0x45; *p++ = 0x3B; *p++ = 0x1A;                                     // cmp r11d,[r10]
        *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_canon);                // mov r10,&canon
        *p++ = 0x75; *p++ = 0x0A;                                                  // jne L0 (another thread: the canon)
    }
    *p++ = 0x49; *p++ = 0xBA; p = EmitImm64(p, (u64)&g_localPlayer);              // mov r10,&localPlayer
    *p++ = 0x45; *p++ = 0x8B; *p++ = 0x1A;                                         // L0: mov r11d,[r10]
    *p++ = 0x45; *p++ = 0x85; *p++ = 0xDB;                                         // test r11d,r11d
    *p++ = 0x74; *p++ = (u8)dstLen;                                                // je L1 (not known: the word as read)
    for (int i = 0; i < dstLen; i++) *p++ = dstMov[i];                             // mov <reg>,r11d
    return p;                                                                      // L1:
}
static u8* EmitBack(u8* p, u8* back)
{
    *p++ = 0x49; *p++ = 0xBB; p = EmitImm64(p, (u64)back);                        // mov r11,back
    *p++ = 0x41; *p++ = 0xFF; *p++ = 0xE3;                                         // jmp r11
    return p;
}

static void PatchPlayerReads()
{
    if (RVA_REPL != 0x255e60) return;       // build 40420 only (the sites were found there)
    u8* page = (u8*)VirtualAlloc(0, 4096, 0x3000 /* MEM_COMMIT|MEM_RESERVE */, 0x40 /* PAGE_EXECUTE_READWRITE */);
    if (!page) return;
    int done = 0;
    static const u8 TO_EDX[] = { 0x44, 0x89, 0xDA }, TO_EAX[] = { 0x44, 0x89, 0xD8 }, TO_EBX[] = { 0x44, 0x89, 0xDB }, TO_R8D[] = { 0x45, 0x89, 0xD8 };
    // A: api.engine.util.getPlayer: movsxd rdx,[rax+20Ch] / mov rcx,rbx / call lua_pushinteger, then back at +15
    {
        const u32 rva = 0x24f0a18;
        static const u8 expect[] = { 0x48, 0x63, 0x90, 0x0C, 0x02, 0x00, 0x00, 0x48, 0x8B, 0xCB, 0xE8 };
        u8* site = (u8*)(g_base + rva);
        u64 push = (u64)(site + 15 + *(i32*)(site + 11));
        u8* p = page;
        *p++ = 0x8B; *p++ = 0x90; *p++ = 0x0C; *p++ = 0x02; *p++ = 0x00; *p++ = 0x00;  // mov edx,[rax+20Ch]
        p = EmitPick(p, TO_EDX, 3, true);
        *p++ = 0x48; *p++ = 0x63; *p++ = 0xD2;                                         // movsxd rdx,edx
        *p++ = 0x48; *p++ = 0x8B; *p++ = 0xCB;                                         // mov rcx,rbx
        *p++ = 0x49; *p++ = 0xBB; p = EmitImm64(p, push);                             // mov r11,lua_pushinteger
        *p++ = 0x41; *p++ = 0xFF; *p++ = 0xD3;                                         // call r11
        p = EmitBack(p, site + 15);
        if (PatchPlayerRead(rva, expect, (int)sizeof(expect), 15, page, (int)(p - page))) done++;
    }
    // B: the other binding: mov eax,[rax+20Ch] / mov [rsp+20h],eax / mov r9,[rdx+180h], then back at +17
    {
        const u32 rva = 0x24da741;
        static const u8 expect[] = { 0x8B, 0x80, 0x0C, 0x02, 0x00, 0x00, 0x89, 0x44, 0x24, 0x20, 0x4C, 0x8B, 0x8A, 0x80, 0x01, 0x00, 0x00 };
        u8* site = (u8*)(g_base + rva);
        u8* stub = page + 256;
        u8* p = stub;
        *p++ = 0x8B; *p++ = 0x80; *p++ = 0x0C; *p++ = 0x02; *p++ = 0x00; *p++ = 0x00;  // mov eax,[rax+20Ch]
        p = EmitPick(p, TO_EAX, 3);
        *p++ = 0x89; *p++ = 0x44; *p++ = 0x24; *p++ = 0x20;                            // mov [rsp+20h],eax
        *p++ = 0x4C; *p++ = 0x8B; *p++ = 0x8A; *p++ = 0x80; *p++ = 0x01; *p++ = 0x00; *p++ = 0x00;   // mov r9,[rdx+180h]
        p = EmitBack(p, site + 17);
        if (PatchPlayerRead(rva, expect, (int)sizeof(expect), 17, stub, (int)(p - stub))) done++;
    }
    // C: a job of the engine's worker threads (function 0x67b790) that takes the local player along with its data:
    // mov eax,[rax+20Ch] / mov [rbp-48h],r14 / mov [rbp-40h],rbx / mov [rbp-38h],eax, then back at +17
    {
        const u32 rva = 0x67b955;
        static const u8 expect[] = { 0x8B, 0x80, 0x0C, 0x02, 0x00, 0x00, 0x4C, 0x89, 0x75, 0xB8, 0x48, 0x89, 0x5D, 0xC0, 0x89, 0x45, 0xC8 };
        u8* site = (u8*)(g_base + rva);
        u8* stub = page + 512;
        u8* p = stub;
        *p++ = 0x8B; *p++ = 0x80; *p++ = 0x0C; *p++ = 0x02; *p++ = 0x00; *p++ = 0x00;  // mov eax,[rax+20Ch]
        p = EmitPick(p, TO_EAX, 3);
        *p++ = 0x4C; *p++ = 0x89; *p++ = 0x75; *p++ = 0xB8;                            // mov [rbp-48h],r14
        *p++ = 0x48; *p++ = 0x89; *p++ = 0x5D; *p++ = 0xC0;                            // mov [rbp-40h],rbx
        *p++ = 0x89; *p++ = 0x45; *p++ = 0xC8;                                         // mov [rbp-38h],eax
        p = EmitBack(p, site + 17);
        if (PatchPlayerRead(rva, expect, (int)sizeof(expect), 17, stub, (int)(p - stub))) done++;
    }
    // D: the interface (main thread), function 0x8690be: mov ebx,[r13+20Ch] / lea rax,[rip+X], then back at +14
    {
        const u32 rva = 0x86917c;
        static const u8 expect[] = { 0x41, 0x8B, 0x9D, 0x0C, 0x02, 0x00, 0x00, 0x48, 0x8D, 0x05 };
        u8* site = (u8*)(g_base + rva);
        u64 target = (u64)(site + 14 + *(i32*)(site + 10));
        u8* stub = page + 768;
        u8* p = stub;
        *p++ = 0x41; *p++ = 0x8B; *p++ = 0x9D; *p++ = 0x0C; *p++ = 0x02; *p++ = 0x00; *p++ = 0x00;   // mov ebx,[r13+20Ch]
        p = EmitPick(p, TO_EBX, 3);
        *p++ = 0x48; *p++ = 0xB8; p = EmitImm64(p, target);                           // mov rax,X
        p = EmitBack(p, site + 14);
        if (PatchPlayerRead(rva, expect, (int)sizeof(expect), 14, stub, (int)(p - stub))) done++;
    }
    // E: the interface (main thread), function 0x24e7cb0: mov r8d,[rax+20Ch] / mov rdx,rax / lea rcx,[rsp+20h], then back at +15
    {
        const u32 rva = 0x24e7d66;
        static const u8 expect[] = { 0x44, 0x8B, 0x80, 0x0C, 0x02, 0x00, 0x00, 0x48, 0x8B, 0xD0, 0x48, 0x8D, 0x4C, 0x24, 0x20 };
        u8* site = (u8*)(g_base + rva);
        u8* stub = page + 1024;
        u8* p = stub;
        *p++ = 0x44; *p++ = 0x8B; *p++ = 0x80; *p++ = 0x0C; *p++ = 0x02; *p++ = 0x00; *p++ = 0x00;   // mov r8d,[rax+20Ch]
        p = EmitPick(p, TO_R8D, 3);
        *p++ = 0x48; *p++ = 0x8B; *p++ = 0xD0;                                         // mov rdx,rax
        *p++ = 0x48; *p++ = 0x8D; *p++ = 0x4C; *p++ = 0x24; *p++ = 0x20;               // lea rcx,[rsp+20h]
        p = EmitBack(p, site + 15);
        if (PatchPlayerRead(rva, expect, (int)sizeof(expect), 15, stub, (int)(p - stub))) done++;
    }
    FlushInstructionCache(GetCurrentProcess(), page, 4096);
    Buf b; b.str("local player: ").dec(done).str(" engine reading(s) redirected (interface thread ").dec(g_mainTid).str(": this machine's company; other threads: the savegame's)"); LogLine(b);
}

static DWORD WINAPI Init(void*)
{
    g_base = (uptr)GetModuleHandleW(0);
    auto dos = (IMAGE_DOS_HEADER_*)g_base;
    u8* ntp = (u8*)(g_base + dos->e_lfanew);
    auto fh = (IMAGE_FILE_HEADER_*)(ntp + 4);
    auto sec = (IMAGE_SECTION_HEADER_*)(ntp + 4 + sizeof(IMAGE_FILE_HEADER_) + fh->SizeOfOptionalHeader);
    for (int i = 0; i < fh->NumberOfSections; i++) {
        if (sec[i].Name[0] == '.' && sec[i].Name[1] == 't' && sec[i].Name[2] == 'e' && sec[i].Name[3] == 'x') {
            g_textStart = g_base + sec[i].VirtualAddress;
            g_textEnd = g_textStart + sec[i].VirtualSize;
        }
    }
    char dir[300] = {};
    DWORD dl = GetEnvironmentVariableA("MPFEVER_DIR", dir, 260);
    // loaded by every start of the game (winhttp.dll slot): without an MPFever session it does nothing at all, except
    // when Steam started the game from an MPFever invitation
    if (dl == 0 || dl >= 260) { ColdJoin(); return 0; }
    {
        const char* tail = "\\native.log";
        int k = 0;
        while (tail[k]) { dir[dl + k] = tail[k]; k++; }
        dir[dl + k] = 0;
        for (DWORD q = 0; q < dl; q++) g_dir[q] = dir[q];
        g_dirLen = (int)dl;
        g_log = CreateFileA(dir, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
        if (g_log == INVALID_HANDLE_VALUE) g_log = 0;
    }
    Buf b;
    b.str("mpfever_native v3 loaded, base ").hex(g_base).str(", build stamp ").hex(fh->TimeDateStamp);
    LogLine(b);
    { Buf t; t.str(g_scriptPoolPatched ? "game scripts: own pool, one worker" : "game scripts: pool NOT patched"); LogLine(t); }
    if (g_simPoolA || g_simPoolB) { Buf t; t.str("pool sizes forced: ").hex(g_simPoolA).str(",").hex(g_simPoolB); LogLine(t); }
    if (g_threads) { Buf t; t.str("engine told it has ").hex(g_threads).str(" processor(s)").str(g_realGetSystemInfo ? "" : " (GetSystemInfo not patched)"); LogLine(t); }
    if (!SelectBuild(fh->TimeDateStamp)) {
        Buf w; w.str("unknown game build: hooks off"); LogLine(w);
        return 0;
    }
    InstallDetour(RVA_ADD, P_ADD, sizeof(P_ADD), (void*)&AddDetour, (void**)&g_addOrig);
    InstallDetour(RVA_APPLY, P_APPLY, sizeof(P_APPLY), (void*)&ApplyDetour, (void**)&g_applyOrig);
    {
        // the pre-iteration function ends in a jump to the engine's ClearPositions(world, player): found from that jump
        u8* tp = (u8*)(g_base + RVA_PREITER);
        if (memcmp(tp, P_PREITER, sizeof(P_PREITER)) == 0 && tp[sizeof(P_PREITER)] == 0xE9) {
            g_clearPos = (ClearPosF)(tp + sizeof(P_PREITER) + 5 + *(int*)(tp + sizeof(P_PREITER) + 1));
            Buf t; t.str("ClearPositions found at ").hex((u64)g_clearPos - g_base); LogLine(t);
        }
        if (InstallDetour(RVA_PREITER, P_PREITER, sizeof(P_PREITER), (void*)&PreIterDetour, (void**)&g_preIterOrig)) g_preIterOn = true;
        if (RVA_REPL) InstallDetour(RVA_REPL, P_REPL, sizeof(P_REPL), (void*)&ReplDetour, (void**)&g_replOrig);
    }
    PatchPlayerReads();
    { char v[4]; if (GetEnvironmentVariableA("MPFEVER_TIMING", v, 3) > 0) {
        QueryPerformanceFrequency(&g_qpf);
        if (g_qpf > 0) {
            NowUs();
            _InterlockedExchange(&g_timing, 1);
            InstallDetour(RVA_SYNC, P_SYNC, sizeof(P_SYNC), (void*)&SyncDetour, (void**)&g_syncOrig);
            InstallDetour(RVA_SWAP, P_SWAP, sizeof(P_SWAP), (void*)&SwapDetour, (void**)&g_swapOrig);
            { char gv[16]; DWORD gn = GetEnvironmentVariableA("MPFEVER_GATE_MS", gv, 15); long g = 0; for (DWORD i = 0; i < gn && gv[i] >= '0' && gv[i] <= '9'; i++) g = g * 10 + (gv[i] - '0'); g_gateMs = g; }
            { char gv[16]; DWORD gn = GetEnvironmentVariableA("MPFEVER_DEFER_ITERS", gv, 15); long g = 0; for (DWORD i = 0; i < gn && gv[i] >= '0' && gv[i] <= '9'; i++) g = g * 10 + (gv[i] - '0'); g_deferIters = g; }
            { char gv[16]; DWORD gn = GetEnvironmentVariableA("MPFEVER_DEFER_AFTER_S", gv, 15); if (gn) { long g = 0; for (DWORD i = 0; i < gn && gv[i] >= '0' && gv[i] <= '9'; i++) g = g * 10 + (gv[i] - '0'); g_deferAfterUs = (i64)g * 1000000; } }
            Buf t; t.str("timing probe on, gate ").dec(g_gateMs).str(" ms, defer ").dec(g_deferIters).str(" iterations"); LogLine(t);
        }
    } }
    { char v[4]; if (GetEnvironmentVariableA("MPFEVER_PAYLOAD_DUMP", v, 3) > 0) { g_dumpOn = 1; Buf t; t.str("payload dump on"); LogLine(t); } }
    { char v[4]; if (GetEnvironmentVariableA("MPFEVER_TERRAIN_PATTERN", v, 3) > 0) { g_tPattern = 1; Buf t; t.str("terrain test pattern on"); LogLine(t); } }
    { char sv[16]; DWORD sn = GetEnvironmentVariableA("MPFEVER_SCANPLAYER", sv, 15); if (sn) { u32 v = 0; for (DWORD i = 0; i < sn && sv[i] >= '0' && sv[i] <= '9'; i++) v = v * 10 + (sv[i] - '0'); HANDLE sc = CreateThread(0, 0, ScanThread, (void*)(uptr)v, 0, 0); if (sc) CloseHandle(sc); } }
    { HANDLE st = CreateThread(0, 0, SteamThread, 0, 0, 0); if (st) CloseHandle(st); }
    SetupSerial();
    // ArmMapSites();   (diagnostic: map lookup failures, see sites_gen.h)
    { char v[4]; if (GetEnvironmentVariableA("MPFEVER_SITES", v, 3) > 0) ArmSites(); }   // diagnostic: which check says "not possible"
    return 0;
}

// ---------------------------------------------------------------- engine thread count (MPFEVER_THREADS=n)
// The engine spreads parts of the simulation (traffic, persons) over a thread pool sized from the processor count;
// the result then depends on thread timing and two games drift apart. With MPFEVER_THREADS set, the game is told it
// has n processors (msvcp140 _Thrd_hardware_concurrency and GetSystemInfo, patched in the game's import table at
// load time, before the engine creates its pool).

extern "C" u32 HardwareConcurrency() { return g_threads; }
extern "C" void WINAPI GetSystemInfoHook(void* si)
{
    g_realGetSystemInfo(si);
    *(DWORD*)((u8*)si + 32) = g_threads;   // SYSTEM_INFO.dwNumberOfProcessors
}

static bool SameNoCase(const char* a, const char* b)
{
    for (; *a && *b; a++, b++) {
        char x = *a, y = *b;
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return false;
    }
    return *a == *b;
}

static void* PatchImport(uptr base, const char* dll, const char* fn, void* repl)
{
    auto dos = (IMAGE_DOS_HEADER_*)base;
    u8* opt = (u8*)(base + dos->e_lfanew) + 4 + sizeof(IMAGE_FILE_HEADER_);
    u32 impRva = *(u32*)(opt + 112 + 8);   // PE32+ DataDirectory[1] (imports)
    if (!impRva) return 0;
    for (u32* d = (u32*)(base + impRva); d[3]; d += 5) {
        if (!SameNoCase((const char*)(base + d[3]), dll)) continue;
        u64* names = (u64*)(base + (d[0] ? d[0] : d[4]));
        u64* iat = (u64*)(base + d[4]);
        for (int i = 0; names[i]; i++) {
            if (names[i] >> 63) continue;   // by ordinal
            if (!SameNoCase((const char*)(base + (u32)names[i] + 2), fn)) continue;
            void* old = (void*)iat[i];
            DWORD prot;
            VirtualProtect(&iat[i], 8, 4 /* PAGE_READWRITE */, &prot);
            iat[i] = (u64)repl;
            VirtualProtect(&iat[i], 8, prot, &prot);
            return old;
        }
    }
    return 0;
}

static void LimitThreads()
{
    char v[16] = {};
    DWORD n = GetEnvironmentVariableA("MPFEVER_THREADS", v, 15);
    if (n == 0 || n >= 15) return;
    u32 t = 0;
    for (DWORD i = 0; i < n && v[i] >= '0' && v[i] <= '9'; i++) t = t * 10 + (v[i] - '0');
    if (t == 0) return;
    g_threads = t;
    uptr base = (uptr)GetModuleHandleW(0);
    PatchImport(base, "msvcp140.dll", "_Thrd_hardware_concurrency", (void*)&HardwareConcurrency);
    void* real = PatchImport(base, "kernel32.dll", "GetSystemInfo", (void*)&GetSystemInfoHook);
    if (real) g_realGetSystemInfo = (GetSystemInfoF)real;
}

// ---------------------------------------------------------------- simulation pools size (MPFEVER_SIMPOOL=a,b)
// Two of the engine's pools are sized round(0.55 * cores + 0.75) by static initialisers (0x1b3c0 -> [0x4054fa8],
// 0x1b410 -> [0x4054fa4]). MPFEVER_SIMPOOL patches those initialisers (in DllMain, before the game's own static
// initialisation runs) to fixed sizes; the processor count, the main pool and everything else stay untouched.
static void PatchPoolInit(uptr base, u32 fnRva, u32 globalRva, u32 value)
{
    u8* f = (u8*)(base + fnRva);
    if (f[0] != 0x48 || f[1] != 0x83 || f[2] != 0xEC || f[3] != 0x28) return;   // sub rsp, 28h
    u8 code[16];
    int i = 0;
    i32 rel = (i32)((i64)(base + globalRva) - (i64)(base + fnRva + 10));
    code[i++] = 0xC7; code[i++] = 0x05; *(i32*)(code + i) = rel; i += 4; *(u32*)(code + i) = value; i += 4;   // mov dword [rip+rel], value
    code[i++] = 0xC3;                                                                                       // ret
    DWORD prot;
    VirtualProtect(f, 16, PAGE_EXECUTE_READWRITE, &prot);
    memcpy(f, code, i);
    VirtualProtect(f, 16, prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), f, 16);
}
static void SetupSimPools()
{
    char v[32] = {};
    DWORD n = GetEnvironmentVariableA("MPFEVER_SIMPOOL", v, 31);
    if (n == 0 || n >= 31) return;
    u32 a = 0, b = 0; DWORD i = 0;
    for (; i < n && v[i] >= '0' && v[i] <= '9'; i++) a = a * 10 + (v[i] - '0');
    if (i < n && v[i] == ',') for (i++; i < n && v[i] >= '0' && v[i] <= '9'; i++) b = b * 10 + (v[i] - '0');
    uptr base = (uptr)GetModuleHandleW(0);
    if (a) { PatchPoolInit(base, 0x1b3c0, 0x4054fa8, a); g_simPoolA = a; }
    if (b) { PatchPoolInit(base, 0x1b410, 0x4054fa4, b); g_simPoolB = b; }
}

// ---------------------------------------------------------------- game scripts run one after the other
// The game scripts (Lua: towns, loans, industries...) are updated on a thread pool. On processors with fewer than 8
// threads the engine gives them their own pool of max(1, threads/2) workers; with 8 threads or more they share the
// general pool and run in parallel, in an order that depends on thread timing, so two games drift apart. Patched here
// (before the pool is made): the dedicated pool always exists, with one worker. Only the scripts' update is serial;
// the simulation systems, the renderer and the loaders keep every core.
static void PatchScriptPool(uptr base)
{
    static const u8 expect[] = { 0x83, 0xF8, 0x08, 0x0F, 0x8D, 0x25, 0x01, 0x00, 0x00,     // cmp eax,8 / jge (shared pool)
                                 0xC7, 0x44, 0x24, 0x20, 0x01, 0x00, 0x00, 0x00,           // mov [rsp+20h],1
                                 0xE8 };                                                   // call hardware_concurrency
    u8* p = FindUnique(base, expect, (int)sizeof(expect), g_knownPool);
    if (!p) return;
    DWORD prot;
    VirtualProtect(p, 32, PAGE_EXECUTE_READWRITE, &prot);
    for (int k = 3; k < 9; k++) p[k] = 0x90;                    // never the shared pool
    u8* c = p + 17;                                              // threads/2 -> 0, so max(1, ...) = 1 worker
    c[0] = 0x31; c[1] = 0xC0; c[2] = 0x0F; c[3] = 0x1F; c[4] = 0x00;   // xor eax,eax / nop
    VirtualProtect(p, 32, prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), p, 32);
    g_scriptPoolPatched = true;
}

// ---------------------------------------------------------------- multiplayer page in the game's main menu
// The main menu's UI runs in its own Lua state, which no mod file reaches (mods are only mounted in a game). lua_load is
// wrapped: when the engine loads gui/menu/main_menu.tl, one statement is put in front of its source that loads
// mpfever_1::/mpfever_menu.lua, which adds the multiplayer page through the UI's own recipe replacement table.
typedef const char* (*LuaReader)(void* L, void* ud, size_t* size);
typedef int (*LuaLoadF)(void* L, LuaReader reader, void* data, const char* chunkname, const char* mode);
static u32 RVA_LUA_LOAD = 0x2fbdf70;
static const u8 P_LUA_LOAD[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x56, 0x48, 0x83, 0xEC, 0x50, 0x49, 0x8B, 0xD9, 0x48, 0x8B, 0xF1 };
static LuaLoadF g_luaLoadOrig = 0;
static const char MENU_PREFIX[] = "do local ok, e = pcall(require, \"mpfever_1::/mpfever_menu.lua\") if not ok then print(\"[MPFEVER-MENU] \" .. tostring(e)) end end ";
static volatile long g_menuInjected = 0;

struct MenuReader { LuaReader reader; void* data; int stage; const char* held; size_t heldSize; };

extern "C" const char* MenuReaderFn(void* L, void* ud, size_t* size)
{
    MenuReader* m = (MenuReader*)ud;
    if (m->stage == 0) {
        size_t n = 0;
        const char* blk = m->reader(L, m->data, &n);
        if (!blk || n == 0 || blk[0] == 0x1B) { m->stage = 2; *size = n; return blk; }   // empty or precompiled: untouched
        m->held = blk; m->heldSize = n; m->stage = 1;
        *size = sizeof(MENU_PREFIX) - 1;
        return MENU_PREFIX;
    }
    if (m->stage == 1) { m->stage = 2; *size = m->heldSize; return m->held; }
    return m->reader(L, m->data, size);
}

static bool EndsWith(const char* s, const char* tail)
{
    int a = 0, b = 0;
    while (s[a]) a++;
    while (tail[b]) b++;
    return a >= b && memcmp(s + a - b, tail, b) == 0;
}

extern "C" int LuaLoadDetour(void* L, LuaReader reader, void* data, const char* chunkname, const char* mode)
{
    if (chunkname && EndsWith(chunkname, "gui/menu/main_menu.tl")) {
        MenuReader m = { reader, data, 0, 0, 0 };
        int r = g_luaLoadOrig(L, MenuReaderFn, &m, chunkname, mode);
        if (_InterlockedIncrement(&g_menuInjected) == 1) { Buf b; b.str("main menu: multiplayer page added (").str(chunkname).str(")"); LogLine(b); }
        return r;
    }
    return g_luaLoadOrig(L, reader, data, chunkname, mode);
}

extern "C" BOOL WINAPI DllMain(HMODULE inst, DWORD reason, void*)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        g_mainTid = (long)GetCurrentThreadId();      // the game loads this module on its main thread, the interface's
        char d[8];
        if (GetEnvironmentVariableA("MPFEVER_CANONALL", d, 3) > 0) g_mainTid = 1;   // diagnostic: the canon on every thread
        if (GetEnvironmentVariableA("MPFEVER_DIR", d, 1) > 0) {
            g_base = (uptr)GetModuleHandleW(0);
            auto dos = (IMAGE_DOS_HEADER_*)g_base;
            auto fh = (IMAGE_FILE_HEADER_*)((u8*)(g_base + dos->e_lfanew) + 4);
            SelectBuild(fh->TimeDateStamp);
            LimitThreads(); SetupSimPools(); PatchScriptPool((uptr)GetModuleHandleW(0));
            u8* ll = FindUnique(g_base, P_LUA_LOAD, (int)sizeof(P_LUA_LOAD), g_knownLua);
            if (ll) { RVA_LUA_LOAD = (u32)((uptr)ll - g_base); InstallDetour(RVA_LUA_LOAD, P_LUA_LOAD, sizeof(P_LUA_LOAD), (void*)&LuaLoadDetour, (void**)&g_luaLoadOrig); }
        }
        HANDLE t = CreateThread(0, 0, Init, 0, 0, 0);
        if (t) CloseHandle(t);
    }
    return 1;
}
