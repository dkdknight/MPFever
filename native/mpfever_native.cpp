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

// the winhttp relay could not reach the system's winhttp.dll (winhttp_proxy.cpp): the game's internet requests, its Mod Hub
// among them, fail too (issue #83)
extern "C" void MpfProxyFailed(const char* what, u32 err)
{
    static long shown = 0;
    if (_InterlockedIncrement(&shown) > 8) return;
    Buf b; b.str("winhttp relay: ").str(what).str(" failed, error ").dec(err).str(" (the game's internet requests fail too)"); LogLine(b);
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
#include "sites20c.h"
enum { RULE_COUNT = 0, RULE_SIM = 1, RULE_UI = 2, RULE_NOTSIM = 3, RULE_SIMTHREAD = 4, RULE_UIOBJ = 0x10 };
static const int NSITES = (int)(sizeof(SITES20C) / sizeof(SITES20C[0]));
// the readings hooked: those of build 40420 (sites20c.h), or on a build known by its signatures only, those found again
static Site20c g_s20dyn[96];
static u8 g_rule20dyn[96];
static const Site20c* g_s20 = SITES20C;
static int g_n20 = NSITES;
static bool g_s20FromSigs = false;
static volatile i64 g_siteCount[64][4];    // per site: interface, simulation, other thread; [3] interface-object readings moved
static u8 g_siteRule[64];

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
static int g_releaseTarget = 0;     // releases asked by the mod (by count: older mods)
static long g_releaseUpTo = 0;      // held builds asked by the mod, by id: every held build up to this id goes (issue #18: a count went
                                    // one off after a build was dropped, and every later build was released at once)
static DWORD g_lastCtl = 0;
static char g_dir[300];
static int g_dirLen = 0;
static long g_inRelease = 0;
static volatile long g_dropHeld = 0;  // a game was loaded: the builds still held belong to the previous one
static int g_dropTarget = 0;          // the releases asked for until then
static int g_dropId = 0;              // the last build held until then
// builds the mod asks to drop (dropid N: made during a resynchronisation, see the bridge's pollNativeEvents): never released,
// their command destroyed when they come to the head of the queue
static volatile long g_dropIds[16];
static volatile long g_nDropIds = 0;
static bool IsDropped(int id) { for (long i = 0; i < g_nDropIds && i < 16; i++) if (g_dropIds[i] == id) return true; return false; }
// (0.7.7) held builds the mod asks to refuse (failid N: another player's build changed what it was computed on since the click,
// and every game, its builder's too, replays the tool's copy instead): given to the engine in their turn like a released one, so
// that the tool gets its answer, and refused at Apply exactly as the engine refuses a command naming an entity that is gone
// (Apply 0x9e84b0 in 40425: "Apply: invalid entity", the element's success byte +0x30 set to 0, nothing dispatched). A dropped
// command never answered its tool, which stayed busy until the next reload (#91). The payload is matched once, within 60 s.
static volatile long g_failIds[16];
static volatile long g_nFailIds = 0;
static bool IsFailed(int id) { for (long i = 0; i < g_nFailIds && i < 16; i++) if (g_failIds[i] == id) return true; return false; }
struct FailPay { u8* volatile pay; u64 at; int id; };
static FailPay g_failPay[16];
static volatile long g_failPayN = 0, g_failRefused = 0;
static bool g_failOn = true;
static u64 g_enabledAt = 0;           // when holding was turned on (GetTickCount64)
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
// the game state of the command a thread applies (ApplyDetour), in a TLS slot of Windows' (the module has no CRT, so no
// __declspec(thread)); 0xFFFFFFFF: no slot, the tick epochs fix stays off
static DWORD g_applyTls = 0xFFFFFFFFu;
static inline u8* ApplyingState() { return g_applyTls == 0xFFFFFFFFu ? 0 : (u8*)TlsGetValue(g_applyTls); }
static inline void SetApplyingState(u8* gs) { if (g_applyTls != 0xFFFFFFFFu) TlsSetValue(g_applyTls, gs); }
static long g_iter = 0;
static volatile long g_cmdTid = 0;   // the simulation thread while it applies the loop's commands (see "fresh ids")
static long g_cmdKind = 0;           // (what it applies then: 1 the loop's commands or the iteration's builds)
static volatile long g_scriptTid = 0;   // the simulation thread while it applies a script's command (counted only, see "fresh ids")
static u32 RVA_SCRIPT_APPLY_RET = 0, RVA_SINK_APPLY_RET = 0;   // where Apply returns to in the scripts' and CGame's command sinks
static volatile long g_applySite[4][2];   // the commands applied: [loop, script, CGame's sink, other][simulation thread, other]
static long g_iterlogDone = 0;
static volatile long g_setPlayer = 0;
static volatile long g_localPlayer = 0;
static long g_localTok = 0;          // token of the control line applied last (the file keeps old lines: only a new token counts)
static void ApplyLocalPlayer(const char* why);
// The other companies' player entities. The engine empties the positions (the money shown above the buildings) of the LOCAL player's
// account only, at the start of every simulation iteration (the pre-iteration function ends in the call below); those of the other
// accounts would pile up for ever on this machine, so the same call is made for them ("setothers <token> <entity>..." in the control file).
static volatile long g_others[32];      // (32 companies at most; 8 before 0.5.0)
static volatile long g_nOthers = 0;
static long g_othersTok = 0;
// The savegame's own company ("setcanon <token> <entity>"): the interface's tools build for it whatever company this machine plays
// (see OwnerFix), so its entity is looked for in the builds they issue.
static volatile long g_canon = 0;
static volatile long g_mainTid = 0;        // the game's main thread (its interface), see PatchPlayerReads
static volatile i64 g_pickCount[8][3];     // per redirected reading: [0] on the interface's thread, [1] the simulation's, [2] another
static volatile u64 g_gsWord[2];           // addresses of the local-player word of the two game states (seen in Replicate)
// The players of the game before (this machine's and the savegame's, dropped with a new game) and the word the interface's game
// state holds now (copied at the end of each iteration, 0 until the first one of a new game). An interface object that outlives a
// game load keeps the player it copied: after a session of companies, an entity that is something else in the next game, and the
// engine closed it (UI::CSelector, 2026-10-28). Read there, that player becomes the interface's word. MPFEVER_STALEUI=0: as read.
static volatile long g_stalePlayer[2] = { 0, 0 };
static volatile long g_uiWord = 0;
static volatile i64 g_staleFixed = 0;
static void NoteStale(int k, long v) { if (v) g_stalePlayer[k] = v; g_uiWord = 0; }
static volatile long g_simTid = 0;         // the simulation thread (seen in its pre-iteration)
static bool g_luaSeedFixed = false;           // Lua's string hash seed made constant (PatchLuaSeed)
static bool g_entWatch = false;            // MPFEVER_ENTWATCH: entity additions/removals counted (EntFlush)
static void EntFlush();
// What the simulation thread reads as the player: the savegame's company, or, while a build is applied, the company in the build's
// context (the engine checks that company's money, not the savegame's: a player could not build when the host was out of money)
static volatile long g_simPlayer = 0;
static volatile long g_moneyFixed = 0;
static volatile long g_trim = 1000, g_paceWrites = 0, g_paceOff = 0;   // smooth pacing (see SyncCallWrap)      // money checks of the tools moved to this machine's company (see MoneyCheckDetour)
static long g_canonTok = 0;
typedef void (*ClearPosF)(void* world, u32 player);
static ClearPosF g_clearPos = 0;
static bool g_preIterOn = false;
static u32* g_hits[600];
static int g_nhits = 0;
static volatile long g_probeIdx = 0, g_probeApplied = 0;
static u32 g_probeSaved = 0;
// The stations the other companies share (one company per player): the map's icon manager leaves out every entity that belongs to
// another company (HudIconManager's octree traversal compares its PlayerOwned with the local player), so the line tool showed
// the shared stations nowhere although they can be picked. Their entities (station groups, stations, constructions) are listed by
// the mod in hud_share.txt ("hudshare <token>" in the control file: read again for a new token); HudShareSplice lets them through.
static i32 g_hudShare[2][4096];
static volatile long g_hudShareN[2] = { 0, 0 };
static volatile long g_hudShareCur = 0;
static long g_hudShareTok = 0;
static volatile long g_hudShareLet = 0;
static void LoadHudShare()
{
    char path[400];
    PathOf(path, "hud_share.txt");
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[65536];
    DWORD got = 0;
    ReadFile(f, buf, sizeof(buf) - 1, &got, 0);
    CloseHandle(f);
    long next = 1 - g_hudShareCur;
    long n = 0;
    // (0.5.2: a list longer than the table, or than the buffer, is said in the log: the stations past it stayed hidden silently)
    bool truncated = got >= sizeof(buf) - 1;
    for (DWORD k = 0; k < got; ) {
        while (k < got && (buf[k] < '0' || buf[k] > '9')) k++;
        if (k >= got) break;
        if (n >= 4096) { truncated = true; break; }
        long v = 0;
        while (k < got && buf[k] >= '0' && buf[k] <= '9') v = v * 10 + (buf[k++] - '0');
        g_hudShare[next][n++] = (i32)v;
    }
    // (sorted by the mod; kept sorted here for the binary search all the same)
    for (long i = 1; i < n; i++) { i32 x = g_hudShare[next][i]; long j = i - 1; while (j >= 0 && g_hudShare[next][j] > x) { g_hudShare[next][j + 1] = g_hudShare[next][j]; j--; } g_hudShare[next][j + 1] = x; }
    g_hudShareN[next] = n;
    _InterlockedExchange(&g_hudShareCur, next);
    static long shown = 0;
    if (shown++ < 20 || truncated) { Buf b; b.str("shared stations shown on the map: ").dec(n).str(" entities").str(truncated ? " (TRUNCATED: the list is longer)" : ""); LogLine(b); }
}

// Open tracks (one company per player, 0.5.0): the tracks a company opened to the others (its rule "open" or "toll", or a gone
// company's) are listed by the mod in open_net.txt, their segments and nodes as this game's entities ("opennet <token>" in the
// control file); the builders' owner filter (IsOwnedByOtherPlayer, see IsOwnedDetour) lets the other companies connect to them.
// 0.5.2: tracks are open when their company set nothing, so the list holds every other company's tracks in every companies game:
// room for 131072 entities (32768 before) and the file read in a buffer that holds them, and a list cut short is said in the log
// (before, it was cut silently, and a number cut in the middle of the buffer made the list unsorted, so ignored as a whole).
#define OPEN_NET_MAX 131072
static i32 g_openNet[2][OPEN_NET_MAX];
static volatile long g_openNetN[2] = { 0, 0 };
static volatile long g_openNetCur = 0;
static long g_openNetTok = 0;
static volatile long g_openLet = 0;
static void LoadOpenNet()
{
    char path[400];
    PathOf(path, "open_net.txt");
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[OPEN_NET_MAX * 12];
    DWORD got = 0;
    ReadFile(f, buf, sizeof(buf) - 1, &got, 0);
    CloseHandle(f);
    long next = 1 - g_openNetCur;
    long n = 0;
    bool truncated = got >= sizeof(buf) - 1;
    // (a buffer filled up may end in the middle of a number: that last one is left out)
    if (truncated) while (got > 0 && buf[got - 1] >= '0' && buf[got - 1] <= '9') got--;
    for (DWORD k = 0; k < got; ) {
        while (k < got && (buf[k] < '0' || buf[k] > '9')) k++;
        if (k >= got) break;
        if (n >= OPEN_NET_MAX) { truncated = true; break; }
        long v = 0;
        while (k < got && buf[k] >= '0' && buf[k] <= '9') v = v * 10 + (buf[k++] - '0');
        g_openNet[next][n++] = (i32)v;
    }
    // (sorted by the mod; checked here, for the binary search)
    bool sorted = true;
    for (long i = 1; i < n; i++) if (g_openNet[next][i - 1] > g_openNet[next][i]) sorted = false;
    if (!sorted) n = 0;
    g_openNetN[next] = n;
    _InterlockedExchange(&g_openNetCur, next);
    static long shown = 0;
    if (shown++ < 20 || truncated) { Buf b; b.str("open tracks of the other companies: ").dec(n).str(" entities").str(sorted ? "" : " (NOT SORTED: ignored)").str(truncated ? " (TRUNCATED: the list is longer)" : ""); LogLine(b); }
}
static bool InOpenNet(i32 e)
{
    long cur = g_openNetCur;
    long lo = 0, hi = g_openNetN[cur] - 1;
    const i32* a = g_openNet[cur];
    while (lo <= hi) {
        long mid = (lo + hi) >> 1;
        if (a[mid] == e) return true;
        if (a[mid] < e) lo = mid + 1; else hi = mid - 1;
    }
    return false;
}

// a file the mod writes and the module reads again and again, kept open: an open of a file just written waits for the
// antivirus (about 9 ms with Windows Defender), through the kept handle the read takes microseconds. The mod only appends to
// these files or rewrites them, it never deletes them. (A missing file is looked for again at most twice a second.)
struct KeptFile { HANDLE h; DWORD missedAt; };
static HANDLE KeptHandle(KeptFile& k, const char* name)
{
    if (k.h && k.h != INVALID_HANDLE_VALUE) return k.h;
    DWORD now = GetTickCount();
    if (k.h == INVALID_HANDLE_VALUE && now - k.missedAt < 500) return INVALID_HANDLE_VALUE;
    char path[400];
    PathOf(path, name);
    k.h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (k.h == INVALID_HANDLE_VALUE) k.missedAt = now;
    return k.h;
}

static KeptFile g_ctlFile = { 0, 0 };
// (0.7.13, #171) The player lines of the control file written before the game now running began to load are the game before's
// (ctl_players.h): g_ctlOldEnd is where the file ended then (DropAtLoad), g_ctlLoads counts the loads. The module reads the
// file only when a command is added: a client cut from its host (a command every 15 s) left its last lines unread, and the
// next game, loaded from the main menu, took them after the drop at its load: the interface read the player of this machine's
// company of the game before and the engine closed the game (MrWhiskey1 joining again, 2026-11-08 15:40:34). Left out now;
// the bridge says them again for the new game with a new token within 30 frames. MPFEVER_CTLSTALE=1: taken, as before
#include "ctl_players.h"
static volatile long g_ctlOldEnd = 0, g_ctlLoads = 0, g_ctlOldSaid = 0;
// (the logs of the player lines taken, setlocal, setcanon and setothers: at most 10 of each in a process, and 3 more after every
// load, see DropAtLoad; the caps, used up in the game's first seconds, hid the lines taken at #171's load)
static long g_ctlShown[3] = { 0, 0, 0 };
static bool CtlStaleKeep()
{
    static long v = -1;
    if (v < 0) { char e[4]; v = (GetEnvironmentVariableA("MPFEVER_CTLSTALE", e, 3) == 1 && e[0] == '1') ? 1 : 0; }
    return v == 1;
}
// the control file's size now (through the kept handle when it is open; 0 when there is no file)
static DWORD CtlFileSizeNow()
{
    HANDLE h = g_ctlFile.h;
    if (h && h != INVALID_HANDLE_VALUE) { DWORD s = GetFileSize(h, 0); return s == INVALID_FILE_SIZE ? 0 : s; }
    char path[400];
    PathOf(path, "native_ctl.txt");
    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD s = GetFileSize(h, 0);
    CloseHandle(h);
    return s == INVALID_FILE_SIZE ? 0 : s;
}
static void ReadControl()
{
    HANDLE f = KeptHandle(g_ctlFile, "native_ctl.txt");
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[16384];
    // ((0.7.13) the mark of the load of the game now running, read before the file's size: see g_ctlOldEnd)
    long loads0 = g_ctlLoads, mark = g_ctlOldEnd;
    DWORD size = GetFileSize(f, 0), got = 0;
    if (size == INVALID_FILE_SIZE) return;
    unsigned oldEnd = (unsigned)mark;
    DWORD bufOff = CtlWindow(size, (unsigned)(sizeof(buf) - 1), &oldEnd);
    if (mark && !oldEnd) _InterlockedCompareExchange(&g_ctlOldEnd, 0, mark);   // (the file written anew: nothing in it is old)
    SetFilePointer(f, (long)bufOff, 0, 0);
    if (size > sizeof(buf) - 1) size = sizeof(buf) - 1;
    ReadFile(f, buf, size, &got, 0);
    buf[got] = 0;
    // ((0.7.13, #171) the player lines, read by ctl_players.h: those of the game before left out, MPFEVER_CTLSTALE=1: taken)
    bool takeOld = CtlStaleKeep();
    CtlPlayers pk;
    CtlPickInit(&pk);
    long hudTok = 0, openTok = 0;
    for (DWORD i = 0; i < got; ) {
        DWORD j = i;
        while (j < got && buf[j] != '\n') j++;
        const char* l = buf + i;
        int len = (int)(j - i);
        int v = 0;
        if (len >= 8 && memcmp(l, "enable ", 7) == 0) { bool was = g_enabled; g_enabled = l[7] == '1'; if (g_enabled && !was) g_enabledAt = GetTickCount64(); }
        else if (len >= 11 && memcmp(l, "defernext ", 10) == 0) {
            for (int k = 10; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > g_deferNextTarget) g_deferNextTarget = v;
        }
        // "setlocal <entity> <token>", "setothers <token> <entity>...", "setcanon <token> <entity>" (ctl_players.h)
        else if (CtlPickLine(l, len, CtlLineOld(bufOff, j, oldEnd), takeOld, &pk)) {}
        else if (len >= 10 && memcmp(l, "hudshare ", 9) == 0) {
            long tok = 0;
            for (int k = 9; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
            hudTok = tok;
        }
        else if (len >= 9 && memcmp(l, "opennet ", 8) == 0) {
            long tok = 0;
            for (int k = 8; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
            openTok = tok;
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
        else if (len >= 8 && memcmp(l, "dropid ", 7) == 0) {
            for (int k = 7; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > 0 && !IsDropped((int)v)) { long n = g_nDropIds; g_dropIds[n % 16] = v; if (n < 16) g_nDropIds = n + 1; }
        }
        else if (len >= 8 && memcmp(l, "failid ", 7) == 0 && g_failOn) {
            for (int k = 7; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > 0 && !IsFailed((int)v)) { long n = g_nFailIds; g_failIds[n % 16] = v; if (n < 16) g_nFailIds = n + 1; }
        }
        else if (len >= 11 && memcmp(l, "releaseid ", 10) == 0) {
            for (int k = 10; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > g_releaseUpTo) g_releaseUpTo = v;
        }
        i = j + 1;
    }
    { long want = g_tinWant; if (want && _InterlockedExchange(&g_tinLoaded, want) != want) TerrainLoadIn(want); }
    // ((0.7.13, #171) a game began to load while the file was read: every line read is the game before's)
    if (!takeOld && g_ctlLoads != loads0) { pk.haveLocal = false; pk.haveCanon = false; pk.haveOthers = false; }
    if (pk.nOld && !takeOld && g_ctlOldSaid != loads0) {
        g_ctlOldSaid = loads0;
        Buf b; b.str("control file: ").dec(pk.nOld).str(" player line(s) of the game before left out after the load (the last: local player ").dec(pk.oldLocal).str(")")
            .str(pk.oldLocalTok && pk.oldLocalTok != g_localTok ? ", the last one never read before the load: taken until 0.7.12" : "");
        LogLine(b);
    }
    // (written into the game state by the simulation thread only, at its next iteration: from here, the state known last may be the
    // one of a game just unloaded, freed memory - writing there corrupted the heap and crashed the game after a resynchronisation)
    if (pk.haveLocal && pk.localTok != g_localTok) {
        g_localTok = pk.localTok; g_localPlayer = pk.local;
        // ((0.7.13) a line taken was never logged: a few after each load, see g_ctlShown; always one written before the load)
        if (g_ctlShown[0]++ < 10 || pk.localOld) {
            Buf b; b.str("local player ").dec(pk.local).str(" from the control file (token ").dec(pk.localTok).str(")")
                .str(pk.localOld ? ", a line written before this game's load (MPFEVER_CTLSTALE=1)" : "");
            LogLine(b);
        }
    }
    if (hudTok && hudTok != g_hudShareTok) { g_hudShareTok = hudTok; LoadHudShare(); }
    if (openTok && openTok != g_openNetTok) { g_openNetTok = openTok; LoadOpenNet(); }
    if (pk.haveCanon && pk.canonTok != g_canonTok) {
        g_canonTok = pk.canonTok; g_canon = pk.canon;
        if (g_ctlShown[1]++ < 10) { Buf b; b.str("savegame company ").dec(pk.canon); LogLine(b); }
    }
    if (pk.haveOthers && pk.othersTok != g_othersTok) {
        g_othersTok = pk.othersTok;
        g_nOthers = 0;
        for (int i = 0; i < pk.nOthers; i++) g_others[i] = pk.others[i];
        g_nOthers = pk.nOthers;
        if (g_ctlShown[2]++ < 10) { Buf b; b.str("other companies: "); for (int i = 0; i < pk.nOthers; i++) b.dec(pk.others[i]).str(" "); LogLine(b); }
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
    // (the frequency was read only with MPFEVER_TIMING: a division by 0 hung both games under MPFEVER_BATCHLOG, tests 601 and 638)
    if (!g_qpf) QueryPerformanceFrequency(&g_qpf);
    if (!g_qp0) g_qp0 = c;
    return g_qpf ? (c - g_qp0) * 1000000 / g_qpf : 0;
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
// Line routes on the map (UI::LineViewer, issue C:11 of the 0.3.6 tests): the viewers build their list of lines with
// 0x7f5c60(..., player, ...), the player being kept in the viewer since it was made, while the game loaded. Then this machine's
// company was not known yet: every viewer shows the savegame's company's lines, and a client's own routes flashed and vanished.
// The savegame's company asked for is replaced by this machine's (a machine playing the savegame's company changes nothing).
typedef void* (*LinesF)(void*, void*, void*, void*, void*, u32, void*, void*);
static LinesF g_linesOrig = 0;
static const u8 P_LINES[] = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x10, 0x48, 0x89, 0x70, 0x18, 0x48, 0x89, 0x78, 0x20, 0x55 };
static u32 RVA_LINES = 0x7f5c60;
static volatile long g_linesShown = 0;
typedef u64 (*SwapF)(void*, void*);
static SwapF g_swapOrig = 0;
static const u8 P_SWAP[] = { 0x48, 0x89, 0x7C, 0x24, 0x18, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x20, 0x4C, 0x8B, 0xF1 };
static u32 RVA_SWAP = 0x9d2d20;      // CommandList::Swap
extern "C" void* LinesDetour(void* out, void* a2, void* a3, void* a4, void* a5, u32 player, void* a7, void* a8)
{
    u32 canon = (u32)g_canon, mine = (u32)g_localPlayer;
    u32 asked = player;
    { static volatile long seen = 0; if (_InterlockedIncrement(&seen) <= 2) { Buf b; b.str("line viewer: lines of company ").dec(player).str(" asked"); LogLine(b); } }
    if (canon && mine && canon != mine && player == canon) {
        player = mine;
        if (_InterlockedIncrement(&g_linesShown) <= 3) { Buf b; b.str("line routes: the viewer asks for company ").dec(canon).str(", shown for ").dec(mine); LogLine(b); }
    }
    // (0.6.12, the line routes gone after a resynchronisation and back for an instant every few seconds, Discord 2026-11-03)
    // every change of what the viewers ask and get, with the companies known then (300 lines at most)
    {
        static volatile long lastKey = -1, changes = 0;
        long key = (long)(((u64)asked * 2654435761u) ^ ((u64)player * 40503u) ^ ((u64)canon << 7) ^ ((u64)mine << 3));
        if (key != lastKey) {
            lastKey = key;
            if (_InterlockedIncrement(&changes) <= 300) {
                Buf b; b.str("line viewer: asks ").dec(asked).str(", given ").dec(player).str(" (savegame company ").dec(canon).str(", this machine ").dec(mine).str(")");
                LogLine(b);
            }
        }
    }
    return g_linesOrig(out, a2, a3, a4, a5, player, a7, a8);
}

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
static void* g_preSeen[16]; static int g_nPreSeen = 0, g_preNext = 0;
// (0.8.6, #150) The same account changes on every game (MPFEVER_CLEARSAME=0: as before). ClearPositions (0xcd6110 on 40425)
// empties a vector of the company's ecs::component::Account (the money shown above the buildings) AND tells the world's engine
// the component changed: its listeners, the entity's change counter and the change log that the copy for the interface replays
// into the state the simulation runs next. Before the copy, the native module emptied every company but THIS machine's: the
// host emptied the client's account, the client the host's, so the two games' simulation states took other changes at every
// iteration (a soak of two games of one company per player parted at an animal's octree node, 6 runs of 10; 0 of 10 with this). Now every game makes
// the same calls in the same order at both places (every company, the smallest entity first, this machine's and the savegame's
// included), and this machine's figures are put back right after its own call (the clear only moves the vector's end to its
// start: ClearPosSeen notes the end inside that call, the end is set back after it), so the interface still shows this machine's
// popups only. g_clearSame: -1 not installed, 0 off, 1 on (ClearPositions spliced at +0x8e, where it holds the component).
static volatile long g_clearSame = -1;
static volatile long g_keepEnt = 0, g_keepTid = 0;
static u8* volatile g_keepVec = 0;
static u64 g_keepBegin = 0, g_keepEnd = 0;
static volatile long g_clearSameKept = 0, g_clearSameMissed = 0, g_clearSameFull = 0, g_clearSameBytes = 0;
static void ClearOthersIn(u8* gs, bool learn)
{
    if (!gs) return;
    bool known = false;
    for (int i = 0; i < g_nPreSeen; i++) if (g_preSeen[i] == gs) known = true;
    if (!known) {
        if (!learn) return;
        // (in turn: replacing always the same entry made the two states of a game evict each other once the table was full,
        // after 8 loads, and every iteration looked like a new game: held builds were dropped, issue #18)
        g_preSeen[g_preNext % 16] = gs; g_preNext++;
        if (g_nPreSeen < 16) g_nPreSeen++;
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
    u32 list[34]; int k = 0;
    for (long i = 0; i < n && i < 32; i++) if (g_others[i]) list[k++] = (u32)g_others[i];
    list[k++] = mine;
    list[k++] = word;
    if (g_clearSame == 1) {
        // every company once, the smallest entity first: the same set and order on every game
        u32 s[34]; int m = 0;
        for (int i = 0; i < k; i++) {
            u32 e = list[i];
            bool dup = !e;
            for (int j = 0; j < m && !dup; j++) if (s[j] == e) dup = true;
            if (!dup) s[m++] = e;
        }
        for (int i = 1; i < m; i++) { u32 x = s[i]; int j = i - 1; while (j >= 0 && s[j] > x) { s[j + 1] = s[j]; j--; } s[j + 1] = x; }
        for (int i = 0; i < m; i++) {
            u32 e = s[i];
            // (before the copy for the interface: this machine's figures are put back after its call)
            bool keep = !learn && e == mine;
            if (keep) { g_keepVec = 0; g_keepTid = (long)GetCurrentThreadId(); g_keepEnt = (long)e; }
            g_clearPos(world, e);
            if (keep) {
                g_keepEnt = 0;
                u8* c = g_keepVec;
                g_keepVec = 0;
                if (c && *(u64*)c == g_keepBegin && *(u64*)(c + 8) == g_keepBegin && g_keepEnd >= g_keepBegin) {
                    *(u64*)(c + 8) = g_keepEnd;
                    _InterlockedIncrement(&g_clearSameKept);
                    // (figures there to show: counted, with the largest, to see in native.log that the popups still reach the interface)
                    if (g_keepEnd > g_keepBegin) {
                        g_clearSameFull++;
                        if ((long)(g_keepEnd - g_keepBegin) > g_clearSameBytes) g_clearSameBytes = (long)(g_keepEnd - g_keepBegin);
                    }
                }
                else _InterlockedIncrement(&g_clearSameMissed);
            }
            static long shownSame = 0;
            if (shownSame < 6) { shownSame++; Buf b; b.str("positions of company ").dec(e).str(" emptied, the same on every game (this machine plays ").dec(mine).str(keep ? ", its figures put back" : "").str(", word ").dec(word).str(", learn ").dec(learn ? 1 : 0).str(")"); LogLine(b); }
        }
        return;
    }
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

// (0.8.7 diagnostic build, MPFEVER_FPUDIAG=1 or MPFEVER_FINEDIAG=1) The floating-point control of EVERY thread of the game, not only
// the simulation's (the drift diagnostic says that one, 0x1f80 on both PCs of #284): the thread pools' workers compute other systems,
// and a driver or an overlay that sets flush-to-zero, denormals-are-zero or another rounding on some threads of one PC would make
// that PC compute other numbers. Each thread: its name, the module that started it, MXCSR (SSE) and the x87 control word, read
// from its context (the thread suspended for that read only). At 30 s, then every 60 s, the threads whose values changed. With
// it, the DLLs loaded in the game that are not Windows' own (overlays, drivers' hooks): once, at 30 s.
typedef long (WINAPI* NtQitF)(HANDLE, int, void*, u32, u32*);
typedef long (WINAPI* GetDescF)(HANDLE, wchar_t**);
typedef void* (WINAPI* LocalFreeF)(void*);
typedef BOOL (WINAPI* ModFromAddrF)(DWORD, const char*, HMODULE*);
typedef DWORD (WINAPI* ModNameF)(HMODULE, char*, DWORD);
typedef BOOL (WINAPI* EnumModsF)(HANDLE, HMODULE*, DWORD, DWORD*);
struct FpuRow { DWORD tid; u32 mx; u16 cw; u8 seen; };
static FpuRow g_fpuRows[512];
static int g_fpuN = 0;

static void FpuModuleOf(Buf& b, uptr addr, ModFromAddrF fromAddr, ModNameF nameOf)
{
    HMODULE m = 0;
    if (addr && fromAddr && fromAddr(0x4 | 0x2, (const char*)addr, &m) && m) {
        char p[300] = {};
        DWORD n = nameOf ? nameOf(m, p, 299) : 0;
        int s = 0;
        for (DWORD i = 0; i < n; i++) if (p[i] == '\\' || p[i] == '/') s = (int)i + 1;
        b.str(p + s).str("+").hex(addr - (uptr)m);
    } else b.str("?").hex(addr);
}

static DWORD WINAPI FpuDiag(void*)
{
    Sleep(30000);
    HMODULE k = GetModuleHandleW(L"kernel32.dll");
    HMODULE nt = GetModuleHandleW(L"ntdll.dll");
    auto snap = (SnapF)GetProcAddress(k, "CreateToolhelp32Snapshot");
    auto first = (T32F)GetProcAddress(k, "Thread32First");
    auto next = (T32F)GetProcAddress(k, "Thread32Next");
    auto openT = (OpenThreadF)GetProcAddress(k, "OpenThread");
    auto susp = (SuspF)GetProcAddress(k, "SuspendThread");
    auto res = (SuspF)GetProcAddress(k, "ResumeThread");
    auto getc = (CtxF)GetProcAddress(k, "GetThreadContext");
    auto pid = (PidF)GetProcAddress(k, "GetCurrentProcessId");
    auto qit = nt ? (NtQitF)GetProcAddress(nt, "NtQueryInformationThread") : 0;
    auto desc = (GetDescF)GetProcAddress(k, "GetThreadDescription");
    auto lfree = (LocalFreeF)GetProcAddress(k, "LocalFree");
    auto fromAddr = (ModFromAddrF)GetProcAddress(k, "GetModuleHandleExA");
    auto nameOf = (ModNameF)GetProcAddress(k, "GetModuleFileNameA");
    auto enumMods = (EnumModsF)GetProcAddress(k, "K32EnumProcessModules");
    if (!snap || !first || !next || !openT || !susp || !res || !getc || !pid) { Buf b; b.str("fpu diagnostic: functions missing"); LogLine(b); return 0; }
    // (the DLLs that are not Windows' own, once)
    if (enumMods && nameOf) {
        static HMODULE mods[1024];
        DWORD need = 0;
        if (enumMods(GetCurrentProcess(), mods, sizeof(mods), &need)) {
            int nm = (int)(need / sizeof(HMODULE)); if (nm > 1024) nm = 1024;
            int sys = 0;
            Buf b; b.str("fpu diagnostic: DLLs in the game that are not Windows' own:");
            for (int i = 0; i < nm; i++) {
                char p[300] = {};
                DWORD n = nameOf(mods[i], p, 299);
                bool win = false;
                for (DWORD j = 0; j + 9 < n; j++) {
                    char c0 = p[j], c1 = p[j + 1], c2 = p[j + 2];
                    if ((c0 == '\\') && (c1 == 'W' || c1 == 'w') && (c2 == 'I' || c2 == 'i') && (p[j + 3] == 'N' || p[j + 3] == 'n') && (p[j + 4] == 'D' || p[j + 4] == 'd') && (p[j + 8] == 'S' || p[j + 8] == 's') && p[j + 9] == '\\') { win = true; break; }
                }
                if (win) { sys++; continue; }
                int s = 0;
                for (DWORD j = 0; j < n; j++) if (p[j] == '\\' || p[j] == '/') s = (int)j + 1;
                if (b.n > 900) { LogLine(b); b.n = 0; b.str("fpu diagnostic: (more)"); }
                b.str(" ").str(p + s);
            }
            b.str(" (and ").dec(sys).str(" of Windows)");
            LogLine(b);
        }
    }
    static u8 ctxbuf[0x4D0 + 32];
    u8* ctx = (u8*)(((uptr)ctxbuf + 15) & ~(uptr)15);
    DWORD me = GetCurrentThreadId(), mypid = pid();
    for (int round = 0; ; round++) {
        HANDLE h = snap(4, 0);
        if (h == INVALID_HANDLE_VALUE) { Sleep(60000); continue; }
        u32 te[7] = { 28 };
        int total = 0, changed = 0, odd = 0;
        for (int i = 0; i < g_fpuN; i++) g_fpuRows[i].seen = 0;
        if (first(h, te)) do {
            if (te[3] != mypid || te[2] == me) continue;
            HANDLE t = openT(0x0002 | 0x0008 | 0x0040, 0, te[2]);
            if (!t) continue;
            u32 mx = 0xFFFFFFFFu; u16 cw = 0xFFFF;
            if (susp(t) != (DWORD)-1) {
                for (int i = 0; i < 0x4D0; i++) ctx[i] = 0;
                *(u32*)(ctx + 0x30) = 0x00100009u;      // (CONTEXT_CONTROL | CONTEXT_FLOATING_POINT)
                if (getc(t, ctx)) { mx = *(u32*)(ctx + 0x34); cw = *(u16*)(ctx + 0x100); }
                res(t);
            }
            total++;
            if (mx != 0xFFFFFFFFu && ((mx & 0xFFC0u) != 0x1F80u || cw != 0x027F)) odd++;
            int r = -1;
            for (int i = 0; i < g_fpuN; i++) if (g_fpuRows[i].tid == te[2]) { r = i; break; }
            bool isNew = r < 0;
            if (isNew && g_fpuN < 512) { r = g_fpuN++; g_fpuRows[r].tid = te[2]; g_fpuRows[r].mx = 0xFFFFFFFFu; g_fpuRows[r].cw = 0xFFFF; }
            if (r >= 0) {
                g_fpuRows[r].seen = 1;
                bool ch = (g_fpuRows[r].mx & 0xFFC0u) != (mx & 0xFFC0u) || g_fpuRows[r].cw != cw;
                if (round == 0 || ch) {
                    if (!isNew) changed++;
                    Buf b;
                    b.str("fpu diagnostic: thread ").dec(te[2]).str(round == 0 ? "" : (isNew ? " (new)" : " (CHANGED)"));
                    if (desc && lfree) {
                        wchar_t* w = 0;
                        if (desc(t, &w) >= 0 && w) {
                            b.str(" \"");
                            for (int i = 0; w[i] && i < 40; i++) { char c = (char)(w[i] < 128 ? w[i] : '?'); b.s[b.n++] = c; }
                            b.str("\"");
                            lfree(w);
                        }
                    }
                    uptr start = 0;
                    if (qit) qit(t, 9, &start, sizeof(start), 0);
                    b.str(" started by "); FpuModuleOf(b, start, fromAddr, nameOf);
                    b.str(" MXCSR ").hex(mx & 0xFFC0u).str(" x87 ").hex(cw);
                    LogLine(b);
                }
                g_fpuRows[r].mx = mx; g_fpuRows[r].cw = cw;
            }
            CloseHandle(t);
        } while (next(h, te));
        CloseHandle(h);
        Buf b; b.str("fpu diagnostic: round ").dec(round).str(", ").dec(total).str(" thread(s), ").dec(odd).str(" not at the default (MXCSR 1f80, x87 27f), ").dec(changed).str(" changed since the last round");
        if (round == 0 || changed || odd) LogLine(b);
        Sleep(60000);
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

static int g_freeqLog = -1;       // (MPFEVER_FREEQLOG, see FreeqLine)
static bool g_freeqExact = false; // (its lines written before the steps that are multiples of 50, see InstallStepSnap)
static void FreeqLine(u8* gs);
// Diagnostic (MPFEVER_BATCHLOG=1, tests): which batch handed by CGame::Sync each command added by the main thread lands in, and
// at which step: "bl sync" (a batch handed, the step the simulation stands at), "bl iter" (an iteration of the simulation loop
// begins), "bl apply" (a command the loop applies), "bl add" (a command added). For builds applied at an exact step without
// stopping the simulation (see docs on non-blocking builds).
static int g_batchLog = -1;
static volatile long g_batchN = 0;
static volatile long g_batchStep = -1;     // (the step the simulation thread saw last: never read from the interface's thread, where
                                           // the game time's getter hung both games, test 601)
static u32 StepOf(u8* gs);
static bool BatchLog() { if (g_batchLog < 0) g_batchLog = GetEnvironmentVariableA("MPFEVER_BATCHLOG", 0, 0) > 0 ? 1 : 0; return g_batchLog > 0; }

static void DriftPoll();   // (0.8.2, the drift diagnostic, see InstallDriftDiag)
extern "C" u64 PreIterDetour(void* a)
{
    g_iter++;
    g_simTid = (long)GetCurrentThreadId();
    if (g_entWatch) { static long it = 0; if (++it % 250 == 0) EntFlush(); }
    if (g_iter == 1) { Buf t; t.str("simulation thread ").dec(GetCurrentThreadId()).str(", interface thread ").dec(g_mainTid); LogLine(t); }
    ClearOthersIn(a ? *(u8**)((u8*)a + 8) : 0, true);
    if (a && *(u8**)((u8*)a + 8)) { g_slot = *(void**)((u8*)a + 8); ApplyLocalPlayer("iteration"); }
    if (g_freeqLog < 0) g_freeqLog = GetEnvironmentVariableA("MPFEVER_FREEQLOG", 0, 0) > 0 ? 1 : 0;
    if (g_freeqLog) FreeqLine(a ? *(u8**)((u8*)a + 8) : 0);
    if (BatchLog()) { g_batchStep = (long)StepOf(a ? *(u8**)((u8*)a + 8) : 0); Buf l; l.str("bl iter ").dec(g_iter).str(" step ").dec(g_batchStep).str(" batch ").dec(g_batchN).str(" us ").dec(NowUs()); LogLine(l); }
    WatchArm(a ? *(u8**)((u8*)a + 8) : 0);
    DriftPoll();
    // commands moved aside (exact-iteration builds, or the MPFEVER_DEFER_ITERS test) whose iteration has come, in queue order
    for (unsigned i = g_defHead; i != g_defTail; i++) {
        Deferred& d = g_def[i % 256];
        if (!d.cmd || d.due > g_iter) continue;
        void* c = d.cmd;
        d.cmd = 0;
        if (g_timing) TimingLine("deferred-apply", (u64)g_iter, (u64)(g_iter - d.queued));
        u8* prevState = ApplyingState();
        SetApplyingState((u8*)g_slot);
        long prevCmd = g_cmdTid, prevKind = g_cmdKind;
        g_cmdTid = g_simTid; g_cmdKind = 1;
        g_applyOrig(g_slot, c);
        g_cmdTid = prevCmd; g_cmdKind = prevKind;
        SetApplyingState(prevState);
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
// Entities (diagnostic of the desyncs): the engine hands out the numbers of removed entities again, oldest first. Who adds and
// removes entities in which engine: [engine slot][thread kind] (0 interface, 1 simulation, 2 other); engine slot 0 = the
// simulation's engine (game state +0x18), 1 = any other. The first additions/removals off the simulation thread in the
// simulation's engine are logged with their caller.
static volatile long g_entAdd[2][3], g_entRem[2][3];
static volatile long g_entOffLogged = 0;
static long EntKind()
{
    long t = (long)GetCurrentThreadId();
    return t == g_simTid ? 1 : (t == g_mainTid ? 0 : 2);
}
static void EntFlush()
{
    for (int e = 0; e < 2; e++) {
        long a = g_entAdd[e][0] + g_entAdd[e][1] + g_entAdd[e][2], r = g_entRem[e][0] + g_entRem[e][1] + g_entRem[e][2];
        if (a + r == 0) continue;
        Buf l; l.str(e == 0 ? "entities of the simulation's engine" : "entities of other engines")
            .str(": added interface/simulation/other ").dec(g_entAdd[e][0]).str("/").dec(g_entAdd[e][1]).str("/").dec(g_entAdd[e][2])
            .str(", removed ").dec(g_entRem[e][0]).str("/").dec(g_entRem[e][1]).str("/").dec(g_entRem[e][2]);
        LogLine(l);
    }
}

static void LogOrderCounts();
static void AuditFlush(bool force)
{
    DWORD now = GetTickCount();
    if (!force && now - g_auditTick < 10000) return;
    g_auditTick = now;
    { static int n = 0; if (force || ++n % 6 == 0) LogOrderCounts(); }
    for (int k = 0; k < 128; k++) {
        u32 tot = g_kcLoop[k] + g_kcDir[k];
        if (tot == g_kcSeen[k]) continue;
        g_kcSeen[k] = tot;
        Buf l; l.str("audit kind ").dec(k).str(" loop ").dec(g_kcLoop[k]).str(" direct ").dec(g_kcDir[k]);
        LogLine(l);
    }
    for (int i = 0; i < g_n20 && i < 64; i++) {
        i64 m = g_siteCount[i][0], s = g_siteCount[i][1], o = g_siteCount[i][2], u = g_siteCount[i][3];
        if (m + s + o == 0) continue;
        Buf l; l.str("word read at ").hex(g_s20[i].rva).str(" rule ").dec(g_siteRule[i]).str(": interface ").dec((long)m).str(" simulation ").dec((long)s).str(" other ").dec((long)o);
        if (u) l.str(" interface object ").dec((long)u);
        LogLine(l);
    }
    if (g_moneyFixed) { Buf l; l.str("money checks of the tools for this machine's company: ").dec(g_moneyFixed); LogLine(l); }
    if (g_staleFixed) { Buf l; l.str("interface objects' players of the game before read as this game's: ").dec((long)g_staleFixed).str(" (").dec(g_stalePlayer[0]).str("/").dec(g_stalePlayer[1]).str(" -> ").dec(g_uiWord).str(")"); LogLine(l); }
    if (g_paceWrites || g_trim != 1000) { Buf l; l.str("smooth pacing: batch interval scaled ").dec(g_paceWrites).str(" time(s), factor now ").dec(g_trim).str("/1000").str(g_paceOff ? " (OFF: layout not as expected)" : ""); LogLine(l); }
    EntFlush();
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
    // (0.8.8, #298) One company per player: the terrain tools' command is the only tool's command that reaches the engine with the
    // savegame's company as its context player (+0x36c): the other tools' builds are held at CommandList::Add and get this
    // machine's company there (OwnerFix), the terrain tools cannot be held (see UI_SITES). The edit was paid by the savegame's
    // company on its maker's game and by the maker's company on every other game (their replay names it): chris's eleven edits of
    // 2026-11-14 01:34 took 2.4 M from company 1 on chris's game only, until the host's figures put it right 30 s later, and a
    // purchase of company 1 in between would have been refused there alone. An edit made here (not a replay: those are told
    // apart just above) whose context player is the savegame's company gets this machine's, before the engine applies it.
    // MPFEVER_TERRAINOWNER=0: as before.
    {
        static int on = -1;
        if (on < 0) { char v[4] = {}; on = (GetEnvironmentVariableA("MPFEVER_TERRAINOWNER", v, 3) > 0 && v[0] == '0') ? 0 : 1; }
        long canon = g_canon, local = g_localPlayer;
        if (on && canon && local && canon != local && *(u32*)(pay + 0x36c) == (u32)canon) {
            *(u32*)(pay + 0x36c) = (u32)local;
            static long shown = 0;
            if (shown++ < 20) { Buf b; b.str("terrain: this machine's edit paid by its company ").dec(local).str(" (the command named the savegame's, ").dec(canon).str(")"); LogLine(b); }
        }
    }
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
    if (g_split < 0) { char v[4]; g_split = GetEnvironmentVariableA("MPFEVER_SPLIT", v, 3) > 0 ? 1 : 0; }    // (diagnostic since the readings are hooked)
    return g_split && g_canon && g_localPlayer && g_canon != g_localPlayer;
}

// The savegame's company belongs to the game it was said for: dropped with a new game until the mod says it again (it does every
// few seconds in a session with companies; in a game without companies it never does, and the readings stay as read)
static void DropCanon(const char* why)
{
    long c = _InterlockedExchange(&g_canon, 0);
    NoteStale(1, c);
    if (c) { Buf b; b.str("savegame company ").dec(c).str(" dropped: ").str(why); LogLine(b); }
}

// The game states this machine's player was written into, with the control token of that value (see ApplyLocalPlayer)
#include "state_seen.h"
static bool SeenFirst()
{
    static long v = -1;
    if (v < 0) { char e[4]; v = GetEnvironmentVariableA("MPFEVER_SEENFIRST", e, 3) > 0 ? 1 : 0; }
    return v == 1;
}
static void* g_doneSlot[SEEN_MAX]; static long g_doneTok[SEEN_MAX]; static int g_nDone = 0, g_doneNext = 0;
static void NoteWritten(void* slot)
{
    int di = -1;
    for (int i = 0; i < g_nDone; i++) if (g_doneSlot[i] == slot) di = i;
    // (0.6.12: the oldest place once full, see state_seen.h)
    if (di < 0) { di = SeenPlace(&g_nDone, &g_doneNext, SeenFirst()); g_doneSlot[di] = slot; }
    g_doneTok[di] = g_localTok;
}
// A game loaded in the same process can get its game state at the address of the previous one: no new state to notice. The word,
// written once for the current token, then holds the savegame's player again (the engine copies it from one state to the other,
// so it never changes by itself): this machine's player (and the other companies') belong to the previous game. Written there,
// the interface read the account of a player entity that no longer exists, and the engine closed the game (a player who joined
// again). Dropped until the mod says them again.
static bool ReloadedAt(void* slot, u32 cur, u32 want)
{
    if (!slot || !g_localPlayer || cur == want) return false;
    for (int i = 0; i < g_nDone; i++) {
        if (g_doneSlot[i] != slot || g_doneTok[i] != g_localTok) continue;
        Buf b; b.str("local player ").dec(g_localPlayer).str(" dropped: the game state ").hex((u64)slot).str(" holds ").dec(cur).str(" again (a game was loaded)"); LogLine(b);
        NoteStale(0, g_localPlayer);
        g_localPlayer = 0;
        g_nOthers = 0;
        g_nDone = 0; g_doneNext = 0;
        DropCanon("a game was loaded");
        return true;
    }
    return false;
}

static void ApplyLocalPlayer(const char* why)
{
    // The engine has more than one game-state object calling Apply (two were seen next to each other at the start of a game): the
    // word is written into every one, at the moment it applies a command (so it is alive). A state never seen before while a
    // value is set is a game that has just been loaded (resynchronisation): the entity ids of the previous one mean nothing
    // there until the mod asks again (it does, every few seconds).
    static void* seen[SEEN_MAX]; static int nseen = 0, seenNext = 0;
    bool known = false;
    for (int i = 0; i < nseen; i++) if (seen[i] == g_slot) known = true;
    if (!known) {
        // (0.6.12: the oldest place once full. Always the first one before: after about eight games loaded in this process the two
        // states of the engine took it in turn and this machine's player was forgotten at every batch, see state_seen.h)
        seen[SeenPlace(&nseen, &seenNext, SeenFirst())] = g_slot;
        // the savegame's company too: the simulation's readings of the word are redirected to it (PatchPlayerReads), and a new
        // game after a session of companies read the company of the game before, an entity that is something else there (a
        // group of trees): the game's scripts failed and the engine closed the game when it booked money on it (issue #88)
        DropCanon("a new game state");
        if (g_localPlayer) {
            Buf b; b.str("local player ").dec(g_localPlayer).str(" dropped: a new game state ").hex((u64)g_slot); LogLine(b);
            NoteStale(0, g_localPlayer);
            g_localPlayer = 0;
            return;
        }
    }
    long want = g_localPlayer;
    if (!want || !g_slot) return;
    if (SplitWord()) want = g_canon;
    volatile u32* w = (volatile u32*)((u8*)g_slot + 0x20c);
    u32 cur = *w;
    // A game loaded in the same process can get its game state at the address of the previous one: not a new state above. The
    // word, written once for the current token, then holds the savegame's player again (the engine copies it from one state to
    // the other, so it never changes by itself): the value belongs to the previous game. Writing it there made the interface read
    // the account of a player entity that no longer exists, and the engine closed the game (a player who joined again).
    if (ReloadedAt(g_slot, cur, (u32)want)) return;
    if (cur == (u32)want) return;
    NoteWritten(g_slot);
    *w = (u32)want;
    static long shown = 0;
    if (shown++ >= 40) return;
    Buf b; b.str("local player ").dec(cur).str(" -> ").dec(want).str(" (").str(why).str(", state ").hex((u64)g_slot).str(")"); LogLine(b);
}

static bool LoadKeepLocal()
{
    static long v = -1;
    if (v < 0) { char e[4]; v = (GetEnvironmentVariableA("MPFEVER_LOADKEEPLOCAL", e, 3) == 1 && e[0] == '1') ? 1 : 0; }
    return v == 1;
}
// a game is being loaded (its first copy into a fresh state, see ReplDetour): this machine's company, the savegame's and the
// others' of the game before are forgotten until the mod says them again
static void DropAtLoad()
{
    // (0.7.13, #171) the player lines already in the control file are the game before's (see g_ctlOldEnd): marked before this
    // machine's company is dropped, so that a reading of the file that starts after the drop goes by the mark (marked with
    // MPFEVER_CTLSTALE=1 too, for the log: the lines are taken there, as before)
    g_ctlOldEnd = (long)CtlFileSizeNow();
    _InterlockedIncrement(&g_ctlLoads);
    for (int k = 0; k < 3; k++) if (g_ctlShown[k] > 7) g_ctlShown[k] = 7;
    long lp = _InterlockedExchange(&g_localPlayer, 0);
    if (lp) { NoteStale(0, lp); Buf b; b.str("local player ").dec(lp).str(" dropped: a game is being loaded"); LogLine(b); }
    if (g_nOthers) { Buf b; b.str("other companies dropped: a game is being loaded"); LogLine(b); }
    g_nOthers = 0;
    g_nDone = 0; g_doneNext = 0;
    DropCanon("a game is being loaded");
}

static void DecisionCopy(void* src, void* dst);
static bool g_replOn = false;
extern "C" u64 ReplDetour(void* src, void* dst, u64 flag)
{
    u32 before = dst ? *(u32*)((u8*)dst + 0x20c) : 0;
    // end of a simulation iteration: the positions the other companies earned during it are emptied before the state is copied for
    // the interface, so that it never shows the money popups of the companies this machine does not play
    static long replClear = -1;
    if (replClear < 0) { char v[4]; replClear = GetEnvironmentVariableA("MPFEVER_NOREPLCLEAR", v, 3) > 0 ? 0 : 1; }
    // (the end of an iteration of a game just loaded comes before any command it applies: the values of the previous game go first)
    if (src && g_localPlayer && !SplitWord()) ReloadedAt(src, *(u32*)((u8*)src + 0x20c), (u32)g_localPlayer);
    if (replClear && (u32)((uptr)_ReturnAddress() - g_base) == RVA_REPL_LOOP) ClearOthersIn((u8*)src, false);
    WatchAdd((u8*)src); WatchAdd((u8*)dst);
    if (src && dst && (u32)((uptr)_ReturnAddress() - g_base) == RVA_REPL_LOOP) { g_gsWord[0] = (u64)src + 0x20c; g_gsWord[1] = (u64)dst + 0x20c; }
    // (a game being loaded: its first copy goes into a fresh state, before its interface and tools are made and seconds before its
    // first iteration; the interface word of the game before is forgotten there, not at that iteration, see g_stalePlayer)
    if (dst && before == 0xFFFFFFFFu && (u32)((uptr)_ReturnAddress() - g_base) != RVA_REPL_LOOP) {
        g_uiWord = 0;
        // (0.7.5) and this machine's company, the savegame's and the other companies' with it: they belong to the game before.
        // Kept until the first iteration of the new one (see ApplyLocalPlayer), the interface read this machine's company of the
        // game before while it made itself, and the money popups' HUD item keeps the player it is made for: a client that played
        // one company per player, then joined a session of one company for everybody without closing the game, crashed at its
        // first popup right after the load ("it != components.end()" from UI::CSelector, 0x789bf0 reading the popups' positions
        // of player 108734, the user's crash of 2026-10-28, autotests ts2, ts3 and ts4 of 2026-11-07). The mod says them again
        // within seconds in a session of companies. MPFEVER_LOADKEEPLOCAL=1: kept, as before
        if (!LoadKeepLocal()) DropAtLoad();
    }
    u64 r = g_replOrig(src, dst, flag);
    if (dst && (u32)((uptr)_ReturnAddress() - g_base) == RVA_REPL_LOOP) g_uiWord = (long)*(u32*)((u8*)dst + 0x20c);
    // (the platform-decision flags of the state just simulated, into the one about to be)
    if ((u32)((uptr)_ReturnAddress() - g_base) == RVA_REPL_LOOP) DecisionCopy(src, dst);
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

static u64 ApplyBody(void* a, void* b, bool inLoop);
extern "C" u64 ApplyDetour(void* a, void* b)
{
    // (read here, where the engine's call returns to: the loop of RunGameSimLoop, or a caller applying one command at once)
    bool inLoop = (u32)((uptr)_ReturnAddress() - g_base) == RVA_LOOP_RET;
    u8* prev = ApplyingState();
    SetApplyingState((u8*)a);
    // (the loop's commands, applied alike on every game: their new entities take fresh ids, see "fresh ids". The commands the
    // simulation's scripts send, MPFever's actions among them, are only counted: given fresh ids, their copies in the other
    // game state did not get the same ids, the engine stopped the game ("entity == c.entity", test n4 of 2026-11-02). The other
    // commands applied at once, through CGame's own sink or on another thread, a preview of this machine's tools among them, not)
    u32 ret = (u32)((uptr)_ReturnAddress() - g_base);
    bool sim = (long)GetCurrentThreadId() == g_simTid;
    bool script = ret && ret == RVA_SCRIPT_APPLY_RET;
    _InterlockedIncrement(&g_applySite[inLoop ? 0 : script ? 1 : (ret && ret == RVA_SINK_APPLY_RET) ? 2 : 3][sim ? 0 : 1]);
    long prevCmd = g_cmdTid, prevKind = g_cmdKind, prevScript = g_scriptTid;
    // (MPFEVER_FRESHSCRIPT=0: the loop's commands only)
    static int freshScript = -1;
    if (freshScript < 0) { char v[4] = {}; freshScript = GetEnvironmentVariableA("MPFEVER_FRESHSCRIPT", v, 3) > 0 && v[0] == '0' ? 0 : 1; }
    g_cmdTid = sim && (inLoop || (script && freshScript)) ? g_simTid : 0;
    g_cmdKind = 1;
    g_scriptTid = sim && script ? g_simTid : 0;
    u64 r = ApplyBody(a, b, inLoop);
    g_cmdTid = prevCmd; g_cmdKind = prevKind; g_scriptTid = prevScript;
    SetApplyingState(prev);
    return r;
}

static u64 ApplyBody(void* a, void* b, bool inLoop)
{
    g_slot = a;
    ApplyLocalPlayer("apply");
    u8* pay = *(u8**)b;
    u32 kind = pay ? *(u8*)(pay + 0x9b8) : 255;
    if (kind == 52 && g_failPayN > 0) {
        u64 now = GetTickCount64();
        for (int i = 0; i < 16; i++) {
            FailPay& f = g_failPay[i];
            if (!f.pay) continue;
            if (now - f.at > 60000) { f.pay = 0; _InterlockedDecrement(&g_failPayN); continue; }
            if (f.pay != pay) continue;
            int id = f.id;
            f.pay = 0; _InterlockedDecrement(&g_failPayN); _InterlockedIncrement(&g_failRefused);
            ((u8*)b)[0x30] = 0;
            Buf l; l.str("held build ").dec(id).str(" refused on purpose at its turn (replayed here as on the other games), ").str(inLoop ? "in the loop" : "direct"); LogLine(l);
            return 0;
        }
    }
    if (kind < 128) { if (inLoop) g_kcLoop[kind]++; else g_kcDir[kind]++; }
    AuditFlush(false);
    if (kind == 52) TerrainCapture(pay);
    if (inLoop && BatchLog()) { Buf l; l.str("bl apply kind ").dec(kind).str(" step ").dec(g_batchStep).str(" iter ").dec(g_iter).str(" batch ").dec(g_batchN); LogLine(l); }
    long ctxPlayer = 0;
    static int noCtx = -1;      // diagnostic MPFEVER_NOCTXPLAYER: the simulation reads the savegame's company during builds too
    if (noCtx < 0) noCtx = GetEnvironmentVariableA("MPFEVER_NOCTXPLAYER", 0, 0) > 0 ? 1 : 0;
    if (kind == 52 && !noCtx && g_canon && (long)GetCurrentThreadId() == g_simTid) {
        long cp = *(long*)(pay + 0x36c);
        bool known = cp == g_canon || cp == g_localPlayer;
        for (long i = 0; i < g_nOthers && i < 32; i++) if (cp == g_others[i]) known = true;
        if (known && cp != g_canon) ctxPlayer = cp;
        // a preview of this machine's tools (applied directly, never by the loop) still names the savegame's company: its money
        // check is for this machine's company
        if (!inLoop && cp == g_canon && g_localPlayer && g_localPlayer != g_canon) ctxPlayer = g_localPlayer;
    }
    if (ctxPlayer) {
        g_simPlayer = ctxPlayer;
        u64 r = g_applyOrig(a, b);
        g_simPlayer = 0;
        return r;
    }
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

// a held build the mod asked to refuse (failid): given to the engine like a released one, its payload noted for ApplyBody
static void FailOne()
{
    if (g_heldHead == g_heldTail) return;
    Held* h = g_held[g_heldHead % 64];
    u8* pay = *(u8**)h->cmd;
    bool noted = false;
    if (pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52) {
        for (int i = 0; i < 16 && !noted; i++) {
            if (g_failPay[i].pay) continue;
            g_failPay[i].at = GetTickCount64(); g_failPay[i].id = h->id; g_failPay[i].pay = pay;
            _InterlockedIncrement(&g_failPayN); noted = true;
        }
    }
    Buf b; b.str("held build ").dec(h->id).str(noted ? " to be refused at its turn" : " could NOT be marked to refuse (released as it is)"); LogLine(b);
    ReleaseOne();
}

// a held build the mod dropped: its command is destroyed, never given to the engine (its callback is never called)
static void DropOne()
{
    if (g_heldHead == g_heldTail) return;
    Held* h = g_held[g_heldHead % 64];
    g_heldHead++;
    ((Dtor)(g_base + RVA_CMD_DTOR))(h->cmd);
    Buf b; b.str("held build ").dec(h->id).str(" dropped (made during a resynchronisation)"); LogLine(b);
}

// The mod's script releases the builds held here; it rewrites bridge_alive.txt every 2 s while holding is on. A game loaded with
// MPFever disabled while a lobby was open (holding still on, no script to release anything) kept every build held: nothing could
// be built. After a minute without the heartbeat (MPFEVER_ALIVE_STALE=<seconds>), the builds held go to the engine and the next
// ones are not held, until the heartbeat comes back. Checked only while builds are held or one is about to be.
static KeptFile g_aliveFile = { 0, 0 };
static u64 g_aliveAt = 0;
static char g_aliveLast[24];
static int g_aliveLastN = -1;
static bool g_bridgeGone = false;
static bool BridgeGone()
{
    static u64 staleMs = 0;
    if (!staleMs) { char v[16] = {}; DWORD n = GetEnvironmentVariableA("MPFEVER_ALIVE_STALE", v, sizeof(v) - 1); u64 s = 0; for (DWORD k = 0; k < n && v[k] >= '0' && v[k] <= '9'; k++) s = s * 10 + (v[k] - '0'); staleMs = (s > 0 ? s : 60) * 1000; }
    u64 now = GetTickCount64();
    HANDLE f = KeptHandle(g_aliveFile, "bridge_alive.txt");
    if (f != INVALID_HANDLE_VALUE) {
        char b[24]; DWORD got = 0;
        SetFilePointer(f, 0, 0, 0);
        if (ReadFile(f, b, sizeof(b), &got, 0) && got > 0 && ((int)got != g_aliveLastN || memcmp(b, g_aliveLast, got) != 0)) {
            memcpy(g_aliveLast, b, got); g_aliveLastN = (int)got; g_aliveAt = now;
        }
    }
    u64 last = g_aliveAt > g_enabledAt ? g_aliveAt : g_enabledAt;
    bool gone = last && now - last > staleMs;
    if (gone != g_bridgeGone) {
        g_bridgeGone = gone;
        Buf b;
        if (gone) b.str("no word from the mod's script for ").dec((int)((now - last) / 1000)).str(" s (MPFever disabled in this game?): builds no longer held, ").dec(g_heldTail - g_heldHead).str(" held build(s) go to the engine");
        else b.str("the mod's script is back: builds held again");
        LogLine(b);
    }
    return gone;
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
    if (BatchLog()) { u8* pay = cmd ? *(u8**)cmd : 0; u32 k = pay && Readable(pay + 0x9b8, 1) ? *(u8*)(pay + 0x9b8) : 255; if (k != 27) { Buf l; l.str("bl add kind ").dec(k).str(" from ").hex(caller).str(" batch ").dec(g_batchN).str(" us ").dec(NowUs()); LogLine(l); } }
    if (!g_inRelease) ReadControl();
    if (g_tin.ready) TerrainInject(cmd);
    else if (g_tPattern > 0) TerrainPattern(cmd);
    {   // (diagnostic, MPFEVER_PAYDUMP: the vectors of a build command, offset and size, to find where the constructions are)
        static long pd = -1;
        if (pd < 0) pd = GetEnvironmentVariableA("MPFEVER_PAYDUMP", 0, 0) > 0 ? 1 : 0;
        u8* pay = cmd ? *(u8**)cmd : 0;
        if (pd && pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52) {
            Buf b; b.str("payload of a build from ").hex(caller).str(":");
            for (int o = 0; o + 24 <= 0x9c0; o += 8) {
                u64 vb = *(u64*)(pay + o), ve = *(u64*)(pay + o + 8), vc = *(u64*)(pay + o + 16);
                if (vb < 0x10000 || vb > 0x00007fffffffffffull || ve <= vb || vc < ve || (ve - vb) > (32u << 20)) continue;
                b.str(" +").hex(o).str("=").dec((long)(ve - vb));
                if (b.n > 900) break;
            }
            LogLine(b);
        }
    }
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
    {   // Refunds (issue #61, found by Steelworm): a Context's refund time-out (float at +0x364, then the refund factor 0.75 at
        // +0x368 and the size of refundableEntities at +0x380) is the game's bulldozeRefundTimeOut (60 s) in a tool's command
        // but 0 in a script's, and with 0 the engine ignores the list. The replays carry their builder's list (G.refundInto):
        // a script's world-build command whose Context holds entries gets the tools' time-out, learned from a tool's command.
        // MPFEVER_REFUNDTIMEOUT=0 turns it off. Offsets of build 40420.
        static float refundTimeOut = 60.0f;
        static int refundOn = -1;
        if (refundOn < 0) { char v[4]; refundOn = (GetEnvironmentVariableA("MPFEVER_REFUNDTIMEOUT", v, 3) > 0 && v[0] == '0') ? 0 : 1; }
        u8* pay = cmd ? *(u8**)cmd : 0;
        if (refundOn && pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52) {
            float* to = (float*)(pay + 0x364);
            u64 nRefund = *(u64*)(pay + 0x380);
            if (IsUiSite(caller)) {
                if (*to > 0.0f && *to < 100000.0f) refundTimeOut = *to;
            } else if (*to == 0.0f && nRefund > 0 && nRefund < 100000) {
                *to = refundTimeOut;
                static long shownR = 0;
                if (shownR++ < 20) { Buf b; b.str("refund time-out ").dec((int)refundTimeOut).str(" s given to a script's build with ").dec((int)nRefund).str(" refundable entities"); LogLine(b); }
            }
        }
    }
    {   // Replayed stops and signals (issue #62): a segment a build replaces costs a script's command a quarter of its price (the
        // engine charges the new segment minus the Context's refund factor, +0x368, 0.75, times the replaced one's price), where the
        // tools' commands pay nothing for it. The factor is not in the Context a script can write, so the bridge marks the command of a
        // replayed stop or signal of a tool (doDust, +0x9b0, set together with playerInitiated, +0x3d2: the game's own scripts and no
        // other build of this mod do that, see G.toolCosts; a mod's own GUI command that did would be priced so too, on every game):
        // its refund factor becomes 1.0 (a segment replaced by one of the same price is free, a dearer one pays the difference) and
        // doDust is cleared again (the stop tool's own command has it off). The factor also weighs the refunds of removed segments that
        // replace nothing; the replays marked remove none. Offsets of build 40420. MPFEVER_REPLACEFREE=0 turns it off.
        static int replaceFree = -1;
        if (replaceFree < 0) { char v[16] = {}; DWORD n = GetEnvironmentVariableA("MPFEVER_REPLACEFREE", v, sizeof(v)); replaceFree = (n == 1 && v[0] == '0') ? 0 : 1; }
        u8* pay = cmd ? *(u8**)cmd : 0;
        if (replaceFree && !IsUiSite(caller) && pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52 && pay[0x9b0] && pay[0x3d2]) {
            *(float*)(pay + 0x368) = 1.0f;
            pay[0x9b0] = 0;
            static long shownF = 0;
            if (shownF++ < 20) { Buf b; b.str("replaced segment free (refund factor 1.0) on a marked stop or signal build (doDust)"); LogLine(b); }
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
        // (holding on but the mod's script silent: what is held goes first, in its order, then this build, none held)
        if (g_enabled && !testDefer && !g_inRelease && BridgeGone()) {
            // (those of a game unloaded since are left alone, as below: their command list is gone)
            if (g_dropHeld) {
                while (g_heldHead != g_heldTail && g_held[g_heldHead % 64]->id <= g_dropId) g_heldHead++;
                g_dropHeld = 0;
                if (g_released < g_dropTarget) g_released = g_dropTarget;
            }
            g_inRelease = 1;
            while (g_heldHead != g_heldTail) { if (g_nDropIds > 0 && IsDropped(g_held[g_heldHead % 64]->id)) DropOne(); else if (g_nFailIds > 0 && IsFailed(g_held[g_heldHead % 64]->id)) FailOne(); else ReleaseOne(); g_released++; }
            g_inRelease = 0;
            return g_addOrig(list, out, cmd, done, progress);
        }
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
                // (with the tool's Context flags: the other games rebuild it with the same ones, issue #20; 8: ignoreErrors, which a
                // signal's own window sends its changes with)
                u32 cbits = 0;
                {
                    u8* pay = *(u8**)h->cmd;
                    if (pay && Readable(pay, 0x9c0) && *(u8*)(pay + 0x9b8) == 52)
                        cbits = (pay[0x358] ? 1u : 0) | (pay[0x360] ? 2u : 0) | (pay[0x362] ? 4u : 0) | (pay[0x3d1] ? 8u : 0) | 32u;
                }
                Buf b; b.str("deferred build ").dec(h->id).str(" from tool site ").hex(caller).str(" context ").dec(cbits); LogLine(b);
                Buf e; e.str("deferred ").dec(h->id).str(" ").dec(cbits); AppendEvent(e);
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
        while (g_nDropIds > 0 && g_heldHead != g_heldTail && IsDropped(g_held[g_heldHead % 64]->id)) DropOne();
        if (g_releaseUpTo > 0) {
            // by id: what the mod asks for is exactly the builds it announced (a dropped one is simply not there any more)
            if (g_heldHead != g_heldTail && g_held[g_heldHead % 64]->id <= g_releaseUpTo) {
                g_inRelease = 1;
                while (g_heldHead != g_heldTail && g_held[g_heldHead % 64]->id <= g_releaseUpTo) {
                    if (g_nDropIds > 0 && IsDropped(g_held[g_heldHead % 64]->id)) DropOne(); else if (g_nFailIds > 0 && IsFailed(g_held[g_heldHead % 64]->id)) FailOne(); else ReleaseOne();
                    g_released++;
                }
                g_inRelease = 0;
            }
        }
        else if (g_heldHead != g_heldTail && g_released < g_releaseTarget) {
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
static int g_mathPatched = 0;          // (see PatchMath)
static bool g_mathOther = false;
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

// Steam networking (mpf_steamnet.cpp): one lock for every Steam call of the module, SteamThread's too, and none once the game
// closes Steam (its SteamAPI_Shutdown import is pointed at MpfSteamShutdownHook, which waits for the lock)
extern "C" bool MpfSteamEnter();
extern "C" void MpfSteamLeave();
extern "C" bool MpfSteamNetStart(HMODULE sa, u64 sid, void* friends);
extern "C" void MpfSteamShutdownHook();
extern "C" void MpfSteamNetSetShutdown(void* original);
static void* PatchImport(uptr base, const char* dll, const char* fn, void* repl);
// (for mpf_steamnet.cpp, a translation unit of its own: native.log and the session folder)
extern "C" void MpfLogText(const char* text, int n) { Buf b; for (int i = 0; i < n && b.n < 1000; i++) b.s[b.n++] = text[i]; LogLine(b); }
extern "C" void MpfSessionPath(char* out, const char* name) { PathOf(out, name); }

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
    if (reg && MpfSteamEnter()) { reg(&g_joinCb, 337); MpfSteamLeave(); }
    { Buf b; b.str("steam: invitations ready").str(reg ? "" : " (no join callback)"); LogLine(b); }
    // the player's Steam account (steam_id.txt): the mod knows a player by it, whatever name the player types
    u64 sid = 0;
    {
        typedef u64 (*GetSteamIdF)(void* self);
        auto getUser = (SteamIfaceF)GetProcAddress(sa, "SteamAPI_SteamUser_v023");
        auto getId = (GetSteamIdF)GetProcAddress(sa, "SteamAPI_ISteamUser_GetSteamID");
        if (MpfSteamEnter()) { void* user = getUser ? getUser() : 0; sid = (user && getId) ? getId(user) : 0; MpfSteamLeave(); }
        if (sid) {
            Buf b; b.dec(sid).str("\n");
            WriteSessionFile("steam_id.txt", b.s, b.n);
        }
        Buf l; l.str("steam: account ").str(sid ? "known" : "unknown"); LogLine(l);
    }
    // MPFever's connections over Steam (mpf_steamnet.cpp), then the game's SteamAPI_Shutdown made to wait for them
    if (MpfSteamNetStart(sa, sid, friends)) MpfSteamNetSetShutdown(PatchImport(g_base, "steam_api64.dll", "SteamAPI_Shutdown", (void*)&MpfSteamShutdownHook));
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
        if (!MpfSteamEnter()) continue;   // (the game closes Steam)
        if (!memcmp(cmd, "presence", 9) && setRp) { setRp(friends, "connect", arg); setRp(friends, "status", "MPFever"); }
        else if (!memcmp(cmd, "invite", 7) && invite) invite(friends, arg);
        else if (!memcmp(cmd, "clear", 6) && clearRp) clearRp(friends);
        MpfSteamLeave();
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


// the simulation's calls of CGameTime's tickCount getter (build 40420; found again by their signatures on another build)
static u32 g_simCalls[16] = { 0x900170, 0x90edc0, 0x96ad13, 0xa38dda, 0xa7db6d, 0xac2dd3, 0x2698385 };
static int g_nSimCalls = 7;
static u32 g_uiDyn[32];
static u32 RVA_LUA_MAKESEED_SIG = 0;     // makeseed found by its signature
static u32 RVA_MONEYCHECK = 0xccfbd0;                                  // the tools' money check (build 40420, see MoneyCheckDetour)
static u32 RVA_ADDENTITY = 0x2bb8940, RVA_REMOVEENTITY = 0x2bbc700;     // ecs::Engine::AddEntity / RemoveEntity (build 40420)
// the readings of the local-player word that PatchPlayerReads redirects (build 40420; 0 when not found on another build)
static u32 g_playerRva[5] = { 0x24f0a18, 0x24da741, 0x67b955, 0x86917c, 0x24e7d66 };

static int HexVal(char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }

// a signature ("48 8B ?? ..."): its rva when it is found once in the code, else 0
static u32 FindSigRva(const char* sig)
{
    u8 pat[96]; bool any[96]; int n = 0;
    for (const char* q = sig; *q && n < 96; ) {
        while (*q == ' ') q++;
        if (!*q) break;
        if (q[0] == '?') { any[n] = true; pat[n++] = 0; q += 2; continue; }
        any[n] = false; pat[n++] = (u8)(HexVal(q[0]) * 16 + HexVal(q[1])); q += 2;
    }
    auto dos = (IMAGE_DOS_HEADER_*)g_base;
    u8* ntp = (u8*)(g_base + dos->e_lfanew);
    auto fh = (IMAGE_FILE_HEADER_*)(ntp + 4);
    auto sec = (IMAGE_SECTION_HEADER_*)(ntp + 4 + sizeof(IMAGE_FILE_HEADER_) + fh->SizeOfOptionalHeader);
    u32 found = 0; int count = 0;
    for (int i = 0; i < fh->NumberOfSections; i++) {
        if (!(sec[i].Name[0] == '.' && sec[i].Name[1] == 't' && sec[i].Name[2] == 'e' && sec[i].Name[3] == 'x')) continue;
        u8* start = (u8*)(g_base + sec[i].VirtualAddress);
        u64 size = sec[i].VirtualSize;
        for (u64 k = 0; k + n <= size; k++) {
            if (start[k] != pat[0]) continue;
            int j = 1;
            while (j < n && (any[j] || start[k + j] == pat[j])) j++;
            if (j == n) { if (!count) found = (u32)(sec[i].VirtualAddress + k); count++; }
        }
    }
    return count == 1 ? found : 0;
}

// ---------------------------------------------------------------- targets by signature (a game build this module does not know)
// The known builds (BUILDS) name every engine place by its address. On another build (a game update) each place is found
// again by its signature: mpfever_sigs.txt, made by tools/mksigs.py from the last known build and shipped with MPFever (the
// launcher gives its path in MPFEVER_SIGS). A place counts only when its signature matches exactly once in the game's code;
// each feature needs all of its places and stays off without them (fail closed), the others still work. A few signatures
// are built in, used when the file has none for their place: the determinism fixes that matter most (Lua's string hash
// seed) and TPF3-MP's for the batch interval (profiles/tf3_build40420_steam_windows/hooks.toml, MIT).
// MPFEVER_SIGTEST=1 resolves by signature on a known build too (to check the file: native.log says what it found where).

struct SigPlace { char key[16]; int off; u8 pat[128]; u8 any[128]; int n; int rule, dst, base, len; u32 rva; int hits; };
static SigPlace* g_sigs = 0;
static int g_nSigs = 0;
static bool g_bySig = false;           // this build's places come from their signatures
static bool g_layout = false;          // the places of build 40420's separate-companies features (the word's readings, tools...)
static char g_sigReport[2048];
static int g_sigReportN = 0;
static void SigNote(const char* t) { while (*t && g_sigReportN < (int)sizeof(g_sigReport) - 2) g_sigReport[g_sigReportN++] = *t++; }
static void SigNoteDec(long v) { Buf b; b.dec(v); b.s[b.n] = 0; SigNote(b.s); }

static const char* const BUILTIN_SIGS[] = {
    "makeseed 0 40 53 48 83 EC 50 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 44 24 48 48 8B D9 33 C9",
    "lua 0 48 89 5C 24 10 56 48 83 EC 50 49 8B D9 48 8B F1",
    "scriptpool 0 83 F8 08 0F 8D ?? ?? ?? ?? C7 44 24 20 01 00 00 00 E8",
    "preIter 0 48 8B 49 08 8B 91 0C 02 00 00 48 8B 49 18 E9",
    "sync 0 48 89 5C 24 10 55 56 57 41 54 41 55 41 56 41 57 48 83 EC 40 4C 8B F2 48 8B D9",
    "cgameStep 0 40 53 48 83 EC 20 48 8B 81 F0 01 00 00 48 8B D9",
    "syncCall 20 48 63 BA 18 02 00 00 48 8B CB 48 03 BA A8 01 00 00 48 8B D6 E8 ?? ?? ?? ?? 84 C0 74",
};

// one line: "<key> <offset> <signature>" or "site20c <rule> <dst> <base> <len> <offset> <signature>"
static bool SigParse(const char* l, int len, SigPlace& p)
{
    memset(&p, 0, sizeof(p));
    int i = 0, k = 0;
    while (i < len && l[i] == ' ') i++;
    while (i < len && l[i] != ' ' && k < 15) p.key[k++] = l[i++];
    if (!k || p.key[0] == '#') return false;
    auto num = [&](int& out) { while (i < len && l[i] == ' ') i++; int v = 0; bool any = false; while (i < len && l[i] >= '0' && l[i] <= '9') { v = v * 10 + (l[i++] - '0'); any = true; } out = v; return any; };
    bool site = memcmp(p.key, "site20c", 8) == 0;
    if (site && !(num(p.rule) && num(p.dst) && num(p.base) && num(p.len))) return false;
    if (!num(p.off)) return false;
    while (i < len && p.n < 128) {
        while (i < len && l[i] == ' ') i++;
        if (i + 1 >= len) break;
        char a = l[i], b = l[i + 1];
        if (a == '?') { p.any[p.n] = 1; p.pat[p.n++] = 0; }
        else if (((a >= '0' && a <= '9') || ((a | 32) >= 'a' && (a | 32) <= 'f')) && ((b >= '0' && b <= '9') || ((b | 32) >= 'a' && (b | 32) <= 'f'))) { p.any[p.n] = 0; p.pat[p.n++] = (u8)(HexVal(a) * 16 + HexVal(b)); }
        else return false;
        i += 2;
    }
    return p.n >= 4 && !p.any[0];
}

static bool SigHave(const char* key)
{
    for (int i = 0; i < g_nSigs; i++) if (memcmp(g_sigs[i].key, key, 16) == 0) return true;
    return false;
}

static void LoadSigs()
{
    if (g_sigs) return;
    g_sigs = (SigPlace*)HeapAlloc(GetProcessHeap(), 8 /* HEAP_ZERO_MEMORY */, sizeof(SigPlace) * 512);
    if (!g_sigs) return;
    char path[400] = {};
    DWORD pl = GetEnvironmentVariableA("MPFEVER_SIGS", path, 390);
    if (pl > 0 && pl < 390) {
        HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (f != INVALID_HANDLE_VALUE) {
            DWORD size = GetFileSize(f, 0), got = 0;
            char* buf = (char*)HeapAlloc(GetProcessHeap(), 0, size + 1);
            if (buf && size < (8u << 20) && ReadFile(f, buf, size, &got, 0)) {
                for (DWORD i = 0; i < got && g_nSigs < 500; ) {
                    DWORD j = i;
                    while (j < got && buf[j] != '\n' && buf[j] != '\r') j++;
                    if (SigParse(buf + i, (int)(j - i), g_sigs[g_nSigs])) g_nSigs++;
                    i = j + 1;
                }
            }
            CloseHandle(f);
            SigNote("signatures from "); SigNote(path); SigNote(": "); SigNoteDec(g_nSigs); SigNote("; ");
        } else { SigNote("no signature file ("); SigNote(path); SigNote("); "); }
    } else SigNote("no signature file (MPFEVER_SIGS not set); ");
    for (const char* b : BUILTIN_SIGS) {
        SigPlace p;
        int n = 0; while (b[n]) n++;
        if (g_nSigs < 512 && SigParse(b, n, p) && !SigHave(p.key)) g_sigs[g_nSigs++] = p;
    }
}

// every signature in one pass over .text (buckets by their first two bytes)
static void SigScan()
{
    auto dos = (IMAGE_DOS_HEADER_*)g_base;
    u8* ntp = (u8*)(g_base + dos->e_lfanew);
    auto fh = (IMAGE_FILE_HEADER_*)(ntp + 4);
    auto sec = (IMAGE_SECTION_HEADER_*)(ntp + 4 + sizeof(IMAGE_FILE_HEADER_) + fh->SizeOfOptionalHeader);
    static int head[65536];
    static int next[512];
    for (int i = 0; i < 65536; i++) head[i] = -1;
    int wild2 = -1;     // (second byte a wildcard: bucketed apart, tried at every position of its first byte)
    for (int i = g_nSigs - 1; i >= 0; i--) {
        SigPlace& p = g_sigs[i];
        if (p.any[1]) { next[i] = wild2; wild2 = i; continue; }
        int h = p.pat[0] | (p.pat[1] << 8);
        next[i] = head[h]; head[h] = i;
    }
    for (int si = 0; si < fh->NumberOfSections; si++) {
        if (!(sec[si].Name[0] == '.' && sec[si].Name[1] == 't' && sec[si].Name[2] == 'e' && sec[si].Name[3] == 'x')) continue;
        u8* t = (u8*)(g_base + sec[si].VirtualAddress);
        u64 size = sec[si].VirtualSize;
        for (u64 k = 0; k + 1 < size; k++) {
            for (int pass = 0; pass < 2; pass++) {
                for (int i = pass ? wild2 : head[t[k] | (t[k + 1] << 8)]; i >= 0; i = next[i]) {
                    SigPlace& p = g_sigs[i];
                    if (pass && p.pat[0] != t[k]) continue;
                    if (k + p.n > size) continue;
                    int j = 1;
                    while (j < p.n && (p.any[j] || t[k + j] == p.pat[j])) j++;
                    if (j == p.n) { if (!p.hits) p.rva = (u32)(sec[si].VirtualAddress + k + p.off); p.hits++; }
                }
            }
        }
    }
}

// the place of the nth signature of a key, 0 when it is missing or not unique
static u32 SigRva(const char* key, int nth = 0)
{
    char k16[16] = {};
    for (int i = 0; key[i] && i < 15; i++) k16[i] = key[i];
    for (int i = 0; i < g_nSigs; i++) {
        if (memcmp(g_sigs[i].key, k16, 16) != 0) continue;
        if (nth-- > 0) continue;
        return g_sigs[i].hits == 1 ? g_sigs[i].rva : 0;
    }
    return 0;
}

static void SigCount(const char* key, int* found, int* total)
{
    char k16[16] = {};
    for (int i = 0; key[i] && i < 15; i++) k16[i] = key[i];
    *found = *total = 0;
    for (int i = 0; i < g_nSigs; i++) if (memcmp(g_sigs[i].key, k16, 16) == 0) { (*total)++; if (g_sigs[i].hits == 1) (*found)++; }
}

static bool ResolveBySignatures();
static bool SelectBuild(u32 stamp)
{
    static int done = 0;     // (called from DllMain and again from Init: resolved once)
    static bool result = false;
    if (done) return result;
    done = 1;
    bool sigTest = GetEnvironmentVariableA("MPFEVER_SIGTEST", 0, 0) > 0;
    for (const BuildAddrs& b : BUILDS) {
        if (b.stamp != stamp || sigTest) continue;
        g_layout = (stamp == 0x6ac50427);     // build 40420
        RVA_ADD = b.add; RVA_CMD_MOVE = b.move; RVA_CMD_DTOR = b.dtor; RVA_HANDLE_DTOR = b.handleDtor; RVA_APPLY = b.apply;
        RVA_SWAP = b.swap; RVA_SYNC = b.sync; RVA_PREITER = b.preIter; RVA_LOOP_RET = b.loopRet;
        RVA_REPL = (stamp == 0x6ac50427) ? 0x255e60 : 0;      // build 40420 only
        RVA_REPL_LOOP = (stamp == 0x6ac50427) ? 0x11ea9f : 0;      // return address of the simulation loop's call
        UI_ADD_SITES = b.sites; UI_ADD_N = b.nSites;
        g_knownLua = b.lua; g_knownPool = b.pool;
        result = true;
        return true;
    }
    result = ResolveBySignatures();
    return result;
}

// A build this module does not know: every place from its signature (see "targets by signature"). The deferral of native
// builds needs all of its places; without them the hooks stay off as before. The separate companies' places (build 40420's
// layout) are used only when the core and the game-state copy are all found.
static bool ResolveBySignatures()
{
    g_bySig = true;
    LoadSigs();
    if (!g_sigs) return false;
    SigScan();
    const char* core[] = { "add", "move", "dtor", "handleDtor", "apply", "loopRet", "preIter" };
    bool ok = true;
    SigNote("missing:");
    for (const char* k : core) if (!SigRva(k)) { ok = false; SigNote(" "); SigNote(k); }
    int f, t, tUi;
    SigCount("uisite", &f, &tUi);
    int nUi = 0;
    for (int i = 0; i < tUi && nUi < 32; i++) { u32 r = SigRva("uisite", i); if (r) g_uiDyn[nUi++] = r; }
    if (!nUi) { ok = false; SigNote(" uisite"); }
    if (ok) {
        RVA_ADD = SigRva("add"); RVA_CMD_MOVE = SigRva("move"); RVA_CMD_DTOR = SigRva("dtor"); RVA_HANDLE_DTOR = SigRva("handleDtor");
        RVA_APPLY = SigRva("apply"); RVA_LOOP_RET = SigRva("loopRet"); RVA_PREITER = SigRva("preIter");
        RVA_SWAP = SigRva("swap"); RVA_SYNC = SigRva("sync");
        UI_ADD_SITES = g_uiDyn; UI_ADD_N = nUi;
    }
    g_knownLua = SigRva("lua");
    g_knownPool = SigRva("scriptpool");
    RVA_LUA_MAKESEED_SIG = SigRva("makeseed");
    // separate companies (build 40420's layout)
    RVA_REPL = SigRva("repl"); RVA_REPL_LOOP = SigRva("replLoop");
    g_layout = ok && RVA_REPL && RVA_REPL_LOOP;
    if (!RVA_REPL || !RVA_REPL_LOOP) SigNote(" repl");
    RVA_LINES = SigRva("lines"); RVA_MONEYCHECK = SigRva("moneycheck");
    RVA_ADDENTITY = SigRva("addEntity"); RVA_REMOVEENTITY = SigRva("removeEntity");
    const char* pk[5] = { "playerA", "playerB", "playerC", "playerD", "playerE" };
    for (int i = 0; i < 5; i++) { g_playerRva[i] = SigRva(pk[i]); if (!g_playerRva[i]) { SigNote(" "); SigNote(pk[i]); } }
    SigCount("simcall", &f, &t);
    g_nSimCalls = 0;
    for (int i = 0; i < t && g_nSimCalls < 16; i++) { u32 r = SigRva("simcall", i); if (r) g_simCalls[g_nSimCalls++] = r; }
    // the readings of the local-player word: each with the bytes found there (they are part of its signature)
    int n20 = 0, all20 = 0;
    for (int i = 0; i < g_nSigs && n20 < 96; i++) {
        SigPlace& p = g_sigs[i];
        if (memcmp(p.key, "site20c", 8) != 0) continue;
        all20++;
        if (p.hits != 1 || p.len < 6 || p.len > 8) continue;
        // (the place must be a "mov r32,[r64+20Ch]" (8B) or "movsxd r64,[r64+20Ch]" (63): a modrm with a 32-bit displacement
        // (and the SIB byte 24 for rsp and r12), then 0C 02 00 00)
        const u8* q = (const u8*)(g_base + p.rva);
        bool plain = (q[p.len - 6] == 0x8B || q[p.len - 6] == 0x63) && (q[p.len - 5] & 0xC0) == 0x80 && (q[p.len - 5] & 7) != 4;
        bool sib = p.len >= 7 && (q[p.len - 7] == 0x8B || q[p.len - 7] == 0x63) && (q[p.len - 6] & 0xC7) == 0x84 && q[p.len - 5] == 0x24;
        if (!(plain || sib) || q[p.len - 4] != 0x0C || q[p.len - 3] != 0x02 || q[p.len - 2] || q[p.len - 1]) continue;
        Site20c& s = g_s20dyn[n20];
        s.rva = p.rva; s.len = (u8)p.len; s.dst = (u8)p.dst; s.base = (u8)p.base;
        memcpy(s.bytes, (u8*)(g_base + p.rva), p.len);
        g_rule20dyn[n20] = (u8)p.rule;
        n20++;
    }
    g_s20 = g_s20dyn; g_n20 = n20; g_s20FromSigs = true;
    SigNote(ok ? "; core found" : "; core NOT found");
    SigNote(", interface tools "); SigNoteDec(nUi); SigNote("/"); SigNoteDec(tUi);
    SigNote(", player word readings "); SigNoteDec(n20); SigNote("/"); SigNoteDec(all20);
    SigNote(", seed calls "); SigNoteDec(g_nSimCalls);
    SigNote(g_layout ? ", separate companies' places found" : ", separate companies' places NOT found");
    return ok;
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
    if (!siteRva) { Buf b; b.str("player read: not found by its signature, left alone"); LogLine(b); return false; }
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
    if (!g_layout) return;                  // build 40420's layout (the sites were found there)
    u8* page = (u8*)VirtualAlloc(0, 4096, 0x3000 /* MEM_COMMIT|MEM_RESERVE */, 0x40 /* PAGE_EXECUTE_READWRITE */);
    if (!page) return;
    int done = 0;
    static const u8 TO_EDX[] = { 0x44, 0x89, 0xDA }, TO_EAX[] = { 0x44, 0x89, 0xD8 }, TO_EBX[] = { 0x44, 0x89, 0xDB }, TO_R8D[] = { 0x45, 0x89, 0xD8 };
    // A: api.engine.util.getPlayer: movsxd rdx,[rax+20Ch] / mov rcx,rbx / call lua_pushinteger, then back at +15
    {
        const u32 rva = g_playerRva[0];
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
        const u32 rva = g_playerRva[1];
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
        const u32 rva = g_playerRva[2];
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
        const u32 rva = g_playerRva[3];
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
        const u32 rva = g_playerRva[4];
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

// ---------------------------------------------------------------- every reading of the local-player word (build 40420)
// Each 'mov reg,[base+20Ch]' of the game (sites20c.h) jumps to a stub: the original reading, then, when the address is the word of
// one of the two game states, a count per thread kind (interface / simulation / other) and, by the site's rule, another value:
// RULE_SIM: the simulation and the other threads get the savegame's company (canon); RULE_UI: the interface's thread gets this
// machine's company. A site whose bytes differ (already patched, other build) is left alone.

struct Asm {
    u8* p;
    void b(u8 x) { *p++ = x; }
    void bn(const u8* x, int n) { for (int i = 0; i < n; i++) *p++ = x[i]; }
    void imm64(u64 v) { *(u64*)p = v; p += 8; }
    u8* jcc32(u8 cc) { *p++ = 0x0F; *p++ = cc; p += 4; return p; }     // returns the end (for patching)
    u8* jmp32() { *p++ = 0xE9; p += 4; return p; }
    static void at(u8* end, u8* target) { *(i32*)(end - 4) = (i32)(target - end); }
};

static u8* AllocNear(u64 size)
{
    // within +-2 GB of the game's code (the sites jump there with a rel32)
    for (u64 d = 0x10000000; d < 0x70000000; d += 0x100000) {
        u8* want = (u8*)((g_base > d ? g_base - d : 0) & ~0xFFFFull);
        if (!want) break;
        u8* m = (u8*)VirtualAlloc(want, size, 0x3000, 0x40);
        if (m) return m;
    }
    return 0;
}

static int RuleOf(u32 rva)
{
    static char v[2048];
    DWORD n = GetEnvironmentVariableA("MPFEVER_SITERULES", v, sizeof(v) - 1);    // diagnostic: "rva:rule,rva:rule" (hex rva)
    if (n > 0 && n < sizeof(v)) {
        v[n] = 0;
        for (DWORD i = 0; i < n; ) {
            u32 r = 0; int k = 0;
            while (i < n && v[i] != ':' ) { char c = v[i++]; r = r * 16 + (u32)(c <= '9' ? c - '0' : (c | 32) - 'a' + 10); }
            i++;
            while (i < n && v[i] != ',') k = k * 10 + (v[i++] - '0');
            i++;
            if (r == rva) return k;
        }
    }
    // The word holds this machine's company: the interface, its tools, money checks, windows and the jobs that prepare what it
    // shows (worker threads: map icons, the player's lines) read it. Read on the simulation thread (0x14f835, 0xa14ff, the bindings
    // 0x24da741 / 0x24dc73f: a game playing another company simulated differently) it gets the savegame's company - except the
    // copy between the two game states.
    if (rva == 0x255ed9) return RULE_COUNT;
    // interface code that may read the word of an object of the interface's own (not one of the two game states): the tools'
    // factory (every tool is made for the player read there), the windows, the tools themselves, and the line viewer (0x29f9f14:
    // the routes drawn on the map are those of the player read there; the client saw its own lines' routes flash and vanish)
    static const u32 uiObj[] = { 0x648f18, 0x65b1f4, 0x529da2, 0x52a01d, 0x537734, 0x53aa67, 0x6568f6, 0x656a31, 0x7354e0, 0x86917c, 0x67b955,
                                 0x29f9f14 };
    for (u32 u : uiObj) if (u == rva) return RULE_SIMTHREAD | RULE_UIOBJ;
    return RULE_SIMTHREAD;
}

// The engine's money check of the interface's tools (can <player> pay <cost>?, build 40420). Every tool keeps the player it was
// made for: the savegame's company, the tools being made when the game loads. A machine playing another company then could not
// build as soon as the savegame's company was out of money (and could while its own was): off the simulation thread, the
// savegame's company is replaced by this machine's.
static const u8 P_MONEYCHECK[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0xDA, 0x49, 0x8B, 0xF9 };
typedef u64 (*MoneyCheckF)(void* world, void* ctx, u32 player, i64 cost);
static MoneyCheckF g_moneyOrig = 0;
extern "C" u64 MoneyCheckDetour(void* world, void* ctx, u32 player, i64 cost)
{
    if (g_canon && g_localPlayer && g_localPlayer != g_canon && player == (u32)g_canon && (long)GetCurrentThreadId() != g_simTid) {
        player = (u32)g_localPlayer;
        g_moneyFixed++;
    }
    return g_moneyOrig(world, ctx, player, cost);
}

static const u8 P_ADDENTITY[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18 };
static const u8 P_REMOVEENTITY[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x44, 0x88, 0x44, 0x24, 0x18, 0x55, 0x56, 0x57, 0x41, 0x54 };
typedef int* (*AddEntityF)(void* engine, int* out);
typedef void (*RemoveEntityF)(void* engine, int entity, u8 flag);
static AddEntityF g_addEntOrig = 0;
static RemoveEntityF g_remEntOrig = 0;

// MPFEVER_ENTLOG: every addition/removal in order (entseq.txt in the session folder: "<iteration> <+|-><entity> <caller
// rva> <engine: 0 the simulation's, 1 another (the interface's copy, which follows at its own pace)> <thread kind>")
static bool g_entLog = false;
static HANDLE g_entFile = INVALID_HANDLE_VALUE;
static void EntSeq(char op, int entity, void* ret, int engine, long kind)
{
    if (g_entFile == INVALID_HANDLE_VALUE) return;
    char o[2] = { op, 0 };
    Buf l; l.dec((long)g_iter).str(" ").str(o).dec(entity).str(" ").hex((u64)((uptr)ret - g_base)).str(" ").dec(engine).str(" ").dec(kind);
    // (the simulation step, read on the simulation's thread only, and the callers further up inside the game: which of its systems
    // made the addition or removal, and at which step)
    if (engine == 0) {
        u32 step = kind == 1 ? StepOf((u8*)g_slot) : 0xFFFFFFFFu;
        l.str(" @").dec((long)step);
        // (a recursion, the octree's descent, written once)
        void* fr[48]; unsigned short n = RtlCaptureStackBackTrace(2, 48, fr, 0);
        l.str(" ");
        int k = 0;
        uptr prev = 0;
        for (unsigned short i = 0; i < n && k < 16; i++) {
            uptr a = (uptr)fr[i];
            if (a < g_base || a - g_base > 0x8000000 || a == prev) continue;
            prev = a;
            l.str(k ? "," : "").hex((u64)(a - g_base)); k++;
        }
    }
    l.str("\r\n");
    DWORD w; WriteFile(g_entFile, l.s, (DWORD)l.n, &w, 0);
}

static int EntEngine(void* engine)
{
    // (0.6.9: the game state read only while it is there: a resynchronisation's load frees it while the load's threads make
    // entities, and the diagnostic stopped the host's game there, test fin1 of 2026-11-02, winhttp.dll+0x1ad2b)
    void* gs = g_slot;
    return (gs && Readable((u8*)gs + 0x18, 8) && engine == *(void**)((u8*)gs + 0x18)) ? 0 : 1;
}

static void EntOff(const char* what, int entity, void* ret)
{
    if (g_entOffLogged >= 60) return;
    g_entOffLogged++;
    Buf l; l.str("entity ").str(what).str(" off the simulation thread in its engine: ").dec(entity).str(" thread ").dec(EntKind())
        .str(" caller ").hex((u64)((uptr)ret - g_base));
    LogLine(l);
}

static volatile long g_addCallerTid = 0;   // (the thread and the caller of AddEntity seen through this detour, see FreshAdd)
static volatile u32 g_addCaller = 0;
static bool g_driftOn;
static void DriftOp(int entity, bool add, void* ret);
extern "C" int* AddEntityDetour(void* engine, int* out)
{
    g_addCaller = (u32)((uptr)_ReturnAddress() - g_base);
    g_addCallerTid = (long)GetCurrentThreadId();
    int* r = g_addEntOrig(engine, out);
    g_addCallerTid = 0;
    int e = EntEngine(engine);
    long k = EntKind();
    _InterlockedIncrement(&g_entAdd[e][k]);
    if (e == 0 && k != 1 && g_simTid) EntOff("added", r ? *r : -1, _ReturnAddress());
    if (g_entLog && r) EntSeq('+', *r, _ReturnAddress(), e, k);
    if (g_driftOn && r && e == 0 && k == 1) DriftOp(*r, true, _ReturnAddress());
    return r;
}

extern "C" void RemoveEntityDetour(void* engine, int entity, u8 flag)
{
    int e = EntEngine(engine);
    long k = EntKind();
    _InterlockedIncrement(&g_entRem[e][k]);
    if (e == 0 && k != 1 && g_simTid) EntOff("removed", entity, _ReturnAddress());
    if (g_entLog) EntSeq('-', entity, _ReturnAddress(), e, k);
    if (g_driftOn && e == 0 && k == 1) DriftOp(entity, false, _ReturnAddress());
    g_remEntOrig(engine, entity, flag);
}

// ---------------------------------------------------------------- order fixes (ported from TPF3-MP, MIT)
// Ported from Juliansgith's TPF3-MP (github.com/Juliansgith/Transport-Fever-3-Multiplayer-Mod, MIT; docs/HOOKS.md "The order
// fixes", "The person-order fixes", investigation/TPF3_TRAIN_PRIORITY_2026-09-30.md), whose person-order fixes come from
// silver2127's TPF2 Multiplayer. Batches the simulation reads in an order that is the engine's history (node lists, removal
// order), not the world's state, are sorted by entity id right before the engine reads them, so that two games with the
// same world decide the same way. The sorts change what the simulation decides: every game of a session runs them (the
// native module is the same everywhere); MPFEVER_NOORDER=1 turns them all off, and must then be set on every game.
// Each site is found by its bytes (TPF3-MP's signatures for build 40420) and left alone when they differ.

struct SavedRegs { u64 r15, r14, r13, r12, r11, r10, r9, r8, rdi, rsi, rbp, rbx, rdx, rcx, rax, rflags; };
static inline u64 OrigRsp(const SavedRegs* r) { return (u64)r + sizeof(SavedRegs); }
typedef void (*SpliceFn)(SavedRegs*);
static volatile long g_orderSorts[16], g_orderReorders[16], g_orderRefused[16];

static void SortIds(i32* a, u64 n, int which)
{
    _InterlockedIncrement(&g_orderSorts[which]);
    if (n < 2) return;
    bool sorted = true;
    for (u64 i = 1; i < n; i++) if (a[i - 1] > a[i]) { sorted = false; break; }
    if (sorted) return;
    _InterlockedIncrement(&g_orderReorders[which]);
    u64 gap = 1;
    while (gap < n / 3) gap = gap * 3 + 1;
    for (; gap > 0; gap /= 3)
        for (u64 i = gap; i < n; i++) { i32 v = a[i]; u64 j = i; while (j >= gap && a[j - gap] > v) { a[j] = a[j - gap]; j -= gap; } a[j] = v; }
}

// a std::vector<Entity> (begin, end, capacity) at vec: sorted in place when it is one
static void SortEntityVector(u64 vec, int which)
{
    if (!vec || !Readable((void*)vec, 24)) { _InterlockedIncrement(&g_orderRefused[which]); return; }
    u64 b = *(u64*)vec, e = *(u64*)(vec + 8), c = *(u64*)(vec + 16);
    if (b == 0 && e == 0) return;
    if (e < b || c < e || (b & 3) || ((e - b) & 3) || (e - b) > (64u << 20) || !Writable((void*)b, e - b)) { _InterlockedIncrement(&g_orderRefused[which]); return; }
    SortIds((i32*)b, (e - b) / 4, which);
}

// 0: each modification's freed ids join the engine's FIFO free-id queue in entity order (the ids new entities get)
static void FixFreedIds(SavedRegs* r) { if (Readable((void*)r->r12, 8)) SortEntityVector(*(u64*)r->r12, 0); }

// 11: the free-id queue kept in id order (0.5.4). The engine gives a new entity the id at the head of a FIFO queue (a
// std::deque<int> at engine+0xd8: map +0xe0, map size +0xe8, offset +0xf0, size +0xf8, four ids per block) and each
// modification appends the ids it freed. A replay that freed or reused ids in another order than the builder's tool (a dry run
// the engine refuses, a stop rebuilt in two modifications) left the queue in another order on that game only: every entity made
// afterwards got another id (sessions of 2026-10-25: a stop replayed, then the next vehicle bought was 350772 on one game and
// 353349 on the other; towns and vehicles drifted and the games reloaded). Sorted after every append, the queue gives the smallest
// free id: two games with the same free ids give the same ids, whatever order they freed them in. About two appends per step.
static i32* g_fqBuf = 0;
static u64 g_fqCap = 0;
static SRWLOCK_ g_fqLock = { 0 };      // (the simulation's engine and the interface's copy may append at the same time)
static void SortFreeQueue(u8* q)
{
    const int W = 11;
    if (!Readable(q, 0x28)) { _InterlockedIncrement(&g_orderRefused[W]); return; }
    u64 map = *(u64*)(q + 8), ms = *(u64*)(q + 0x10), off = *(u64*)(q + 0x18), n = *(u64*)(q + 0x20);
    _InterlockedIncrement(&g_orderSorts[W]);
    if (n < 2) return;
    if (!map || !ms || (ms & (ms - 1)) || n > ms * 4 || n > (32u << 20) || !Readable((void*)map, ms * 8)) { _InterlockedIncrement(&g_orderRefused[W]); return; }
    u64 mask = ms - 1;
    if (n > g_fqCap) {
        u64 cap = n + n / 2 + 1024;
        i32* nb = (i32*)HeapAlloc(GetProcessHeap(), 0, cap * 4);
        if (!nb) { _InterlockedIncrement(&g_orderRefused[W]); return; }
        if (g_fqBuf) HeapFree(GetProcessHeap(), 0, g_fqBuf);
        g_fqBuf = nb; g_fqCap = cap;
    }
    i32* a = g_fqBuf;
    bool sorted = true;
    for (u64 i = 0; i < n; i++) {
        u64 j = off + i;
        i32* blk = *(i32**)(map + ((j >> 2) & mask) * 8);
        if (!blk || ((u64)blk & 3)) { _InterlockedIncrement(&g_orderRefused[W]); return; }
        a[i] = blk[j & 3];
        if (i && a[i - 1] > a[i]) sorted = false;
    }
    if (sorted) return;
    _InterlockedIncrement(&g_orderReorders[W]);
    u64 gap = 1;
    while (gap < n / 3) gap = gap * 3 + 1;
    for (; gap > 0; gap /= 3)
        for (u64 i = gap; i < n; i++) { i32 v = a[i]; u64 j = i; while (j >= gap && a[j - gap] > v) { a[j] = a[j - gap]; j -= gap; } a[j] = v; }
    for (u64 i = 0; i < n; i++) { u64 j = off + i; (*(i32**)(map + ((j >> 2) & mask) * 8))[j & 3] = a[i]; }
}
static void FixFreeQueue(SavedRegs* r)
{
    AcquireSRWLockExclusive(&g_fqLock);
    SortFreeQueue((u8*)r->r13 + 0xd8);
    ReleaseSRWLockExclusive(&g_fqLock);
}

// 1: the vehicles that want track, before the engine's seeded shuffle and priority sort decide who reserves first: entries
// {int node index, float} of [rbp-0x20]..[rbp-0x18], sorted by their vehicle's entity id, read as the engine's own loop does
static i32 LandKey(u64 records, u64 entry) { return *(i32*)(records + (u64)(i32)(entry & 0xFFFFFFFF) * 20); }
static void FixLandVehicles(SavedRegs* r)
{
    u64 rbp = r->rbp;
    if (!Readable((void*)(rbp - 0x80), 0x70)) { _InterlockedIncrement(&g_orderRefused[1]); return; }
    u64 b = *(u64*)(rbp - 0x20), e = *(u64*)(rbp - 0x18), self = *(u64*)(rbp - 0x80);
    if (b == e) return;
    if (e < b || ((e - b) & 7) || (e - b) > (8u << 20) || !Writable((void*)b, e - b) || !Readable((void*)(self + 8), 8)) { _InterlockedIncrement(&g_orderRefused[1]); return; }
    u64 holder = *(u64*)(self + 8);
    if (!Readable((void*)holder, 16)) { _InterlockedIncrement(&g_orderRefused[1]); return; }
    u64 rb = *(u64*)holder, re = *(u64*)(holder + 8);
    u64 n = (e - b) / 8, nrec = re > rb ? (re - rb) / 20 : 0;
    u64* ent = (u64*)b;
    for (u64 i = 0; i < n; i++) { i32 idx = *(i32*)(ent + i); if (idx < 0 || (u64)idx >= nrec) { _InterlockedIncrement(&g_orderRefused[1]); return; } }
    if (!Readable((void*)rb, nrec * 20)) { _InterlockedIncrement(&g_orderRefused[1]); return; }
    _InterlockedIncrement(&g_orderSorts[1]);
    bool sorted = true;
    for (u64 i = 1; i < n; i++) if (LandKey(rb, ent[i - 1]) > LandKey(rb, ent[i])) { sorted = false; break; }
    if (sorted) return;
    _InterlockedIncrement(&g_orderReorders[1]);
    for (u64 i = 1; i < n; i++) { u64 v = ent[i]; i32 kv = LandKey(rb, v); u64 j = i; while (j > 0 && LandKey(rb, ent[j - 1]) > kv) { ent[j] = ent[j - 1]; j--; } ent[j] = v; }
}
// 2: the PersonCapacity candidates (a vector at [rsp+0x70], in rbx) before their capacities are summed for one draw
static void FixCandidates(SavedRegs* r) { if (r->rbx == OrigRsp(r) + 0x70) SortEntityVector(r->rbx, 2); else _InterlockedIncrement(&g_orderRefused[2]); }
// 3: the persons and cargo leaving buildings (two vectors at [rbp+7], [rbp+0x1f]) before they are signalled
static void FixDepartures(SavedRegs* r) { SortEntityVector(r->rbp + 7, 3); SortEntityVector(r->rbp + 0x1f, 3); }
// 4: the persons arriving on foot ([rbp-0x78]) before their stay draws
static void FixArrivals(SavedRegs* r) { SortEntityVector(r->rbp - 0x78, 4); }
// 5: the vehicles at a line stop (the vector the getter returned, in rax) before the boarding loop
static void FixVehiclesAtStop(SavedRegs* r) { SortEntityVector(r->rax, 5); }

// 13: the road edges' entries (TPF3-MP's road-entry-order, docs/HOOKS.md "Road edge entries"; 0.5.14). transport::EdgeUseManager
// keeps, per road edge, 20-byte entries {int entity, int component, float back, float front, bool forward} of the persons and
// vehicles on it, in the order they were appended: Add (a person, from PersonMoveSystem) and AddRange (a vehicle on each edge of
// its path, from LandVehicleMoveSystem) push them back, nothing reorders them, and the nearest-occupant searches take the first
// of two at the same place. Appended in another order on another game (the history differs, or the callbacks came otherwise),
// the vehicles queued at a stop took other places: friends' session of 2026-10-29, trucks of one line queued at a freight stop
// 0.2 m apart on the two games, then "vehicles" drifted and the games reloaded (twice in 4 h). Both appenders are detoured whole
// and the edges they appended to are then kept in entity order: one sorted list after each append, whatever order they came
// in. The lists are found as the engine's GetOrAddEdgeData finds them: the manager's data, its entity-to-slot index [+0]..[+8]
// (ints), its slots [+0x18]..[+0x20] (72 bytes each), a slot's edges [slot]..[slot+8] (32 bytes each), the entries vector at
// edge+8; every bound is checked, a shape that does not fit leaves that edge alone (counted as refused). MPFEVER_NOROADORDER=1
// on every game: the engine's order, as before.
typedef u64 (*RoadFn9)(u64, u64, u64, u64, u64, u64, u64, u64, u64);
static RoadFn9 g_roadAddOrig = 0, g_roadAddRangeOrig = 0;
static volatile long g_roadOn = 0;
static const int ROAD_W = 13;
// the entries vector (&begin) of the edge an EdgeId (int entity, int index, int direction) names, or 0
static u64 RoadEntriesOf(u64 data, u64 edgeId)
{
    if (!Readable((void*)edgeId, 8) || !Readable((void*)data, 0x28)) return 0;
    i32 ent = *(i32*)edgeId, idx = *(i32*)(edgeId + 4);
    if (ent < 0 || idx < 0) return 0;
    u64 so = *(u64*)data, se = *(u64*)(data + 8);
    if (se < so || (u64)ent >= (se - so) / 4 || !Readable((void*)(so + (u64)ent * 4), 4)) return 0;
    i32 slot = *(i32*)(so + (u64)ent * 4);
    if (slot < 0) return 0;
    u64 sl = *(u64*)(data + 0x18), sle = *(u64*)(data + 0x20);
    if (sle < sl || (sle - sl) % 72 || (u64)slot >= (sle - sl) / 72) return 0;
    u64 at = sl + (u64)slot * 72;
    if (!Readable((void*)at, 16)) return 0;
    u64 eb = *(u64*)at, ee = *(u64*)(at + 8);
    if (ee < eb || (ee - eb) % 32 || (u64)idx >= (ee - eb) / 32) return 0;
    u64 vec = eb + (u64)idx * 32 + 8;
    return Readable((void*)vec, 16) ? vec : 0;
}
// the entries of one edge put in entity order, in place (insertion: a kept list is out of order only in its appended last entry)
static void RoadSortEdge(u64 data, u64 edgeId)
{
    _InterlockedIncrement(&g_orderSorts[ROAD_W]);
    u64 vec = RoadEntriesOf(data, edgeId);
    if (!vec) { _InterlockedIncrement(&g_orderRefused[ROAD_W]); return; }
    u64 b = *(u64*)vec, e = *(u64*)(vec + 8);
    if (b == e) return;
    if (e < b || (e - b) % 20 || (e - b) / 20 > 65536 || !Writable((void*)b, e - b)) { _InterlockedIncrement(&g_orderRefused[ROAD_W]); return; }
    u64 n = (e - b) / 20;
    u8* p = (u8*)b;
    bool sorted = true;
    for (u64 i = 1; i < n; i++) if (*(i32*)(p + (i - 1) * 20) > *(i32*)(p + i * 20)) { sorted = false; break; }
    if (sorted) return;
    _InterlockedIncrement(&g_orderReorders[ROAD_W]);
    u8 t[20];
    for (u64 i = 1; i < n; i++) {
        i32 k = *(i32*)(p + i * 20);
        if (*(i32*)(p + (i - 1) * 20) <= k) continue;
        memcpy(t, p + i * 20, 20);
        u64 j = i;
        while (j > 0 && *(i32*)(p + (j - 1) * 20) > k) { memcpy(p + j * 20, p + (j - 1) * 20, 20); j--; }
        memcpy(p + j * 20, t, 20);
    }
}
// Add(this = the manager, &edgeId, entity, component, {back, front}): the manager's data at [this+0x18]
static u64 RoadAdd(u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6, u64 a7, u64 a8, u64 a9)
{
    u64 r = g_roadAddOrig(a1, a2, a3, a4, a5, a6, a7, a8, a9);
    if (g_roadOn && Readable((void*)(a1 + 0x18), 8)) RoadSortEdge(*(u64*)(a1 + 0x18), a2);
    return r;
}
// AddRange(this = the data, entity, component, &path (12-byte EdgeIds), current, {back, front}, from, to, manager): the edges
// path[from..to]; the manager's [+0x18] must name the data it was given
static u64 RoadAddRange(u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6, u64 a7, u64 a8, u64 a9)
{
    u64 r = g_roadAddRangeOrig(a1, a2, a3, a4, a5, a6, a7, a8, a9);
    if (!g_roadOn) return r;
    i32 from = (i32)(u32)a7, to = (i32)(u32)a8;
    if (!Readable((void*)(a9 + 0x18), 8) || *(u64*)(a9 + 0x18) != a1 || !Readable((void*)a4, 16)) { _InterlockedIncrement(&g_orderRefused[ROAD_W]); return r; }
    u64 pb = *(u64*)a4, pe = *(u64*)(a4 + 8);
    if (pe < pb || (pe - pb) % 12 || from < 0 || to < from || (u64)to >= (pe - pb) / 12 || (pe - pb) / 12 > (1u << 20)) { _InterlockedIncrement(&g_orderRefused[ROAD_W]); return r; }
    for (i32 i = from; i <= to; i++) RoadSortEdge(a1, pb + (u64)i * 12);
    return r;
}
// a whole-function detour: the function's first 14 bytes (whole instructions, checked against `pro`, no rip-relative one) run
// from a copy followed by a jump back; the function starts with a jump to `hook`
static void* DetourWhole(u8*& mem, u32 rva, const u8* pro, int len, void* hook)
{
    u8* f = (u8*)(g_base + rva);
    if (len < 14 || len > 32 || memcmp(f, pro, len) != 0) return 0;
    Asm a{ mem };
    u8* tramp = a.p;
    a.bn(f, len);
    a.b(0xFF); a.b(0x25); a.b(0); a.b(0); a.b(0); a.b(0); a.imm64((u64)(f + len));
    mem = (u8*)(((u64)a.p + 15) & ~15ull);
    DWORD old;
    if (!VirtualProtect(f, len, PAGE_EXECUTE_READWRITE, &old)) return 0;
    u8 patch[32];
    patch[0] = 0xFF; patch[1] = 0x25; *(u32*)(patch + 2) = 0; *(u64*)(patch + 6) = (u64)hook;
    for (int k = 14; k < len; k++) patch[k] = 0x90;
    memcpy(f, patch, len);
    VirtualProtect(f, len, old, &old);
    FlushInstructionCache(GetCurrentProcess(), f, len);
    return tramp;
}
static bool InstallRoadOrder(u8*& mem)
{
    if (GetEnvironmentVariableA("MPFEVER_NOROADORDER", 0, 0) > 0) return false;
    // (TPF3-MP's signatures for build 40425; both appenders or neither: one list kept and the other not is no order)
    u32 add = FindSigRva("48 89 5C 24 18 48 89 74 24 20 55 57 41 56 48 8D 6C 24 C0 48 81 EC 40 01 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 38");
    u32 rng = FindSigRva("48 8B C4 48 89 58 10 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 08 FF FF FF 48 81 EC C0 01 00 00 C5 F8 29 70 B8 C5 F8 29 78 A8 C5 78 29 40 98 C5 78 29 48 88 C5 78 29 90 78 FF FF FF C5 78 29 98 68 FF FF FF 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 58");
    if (!add || !rng) return false;
    // (0.5.14) the layout the sort relies on, read in the functions' bodies, not only their prologues: entries of 20 bytes (the
    // search loop and the push_back of Add, the push_back of AddRange), slots of 72 bytes and edges of 32 (the edge-data getter
    // AddRange calls). Another game build with the same prologues and another layout: the order stays off, as in 0.5.13, instead
    // of moving 20-byte blocks over other entries. (All read on 40425, stamp 6ad9ce10.)
    {
        const u8* fa = (const u8*)(g_base + add);
        const u8* fr = (const u8*)(g_base + rng);
        static const u8 push20[] = { 0x48, 0x83, 0x41, 0x08, 0x14 };                            // add qword [rcx+8], 20
        static const u8 find20[] = { 0x39, 0x18, 0x74 };                                        // cmp [rax], ebx; je
        static const u8 next20[] = { 0x48, 0x83, 0xC0, 0x14 };                                  // add rax, 20
        static const u8 s72[] = { 0x48, 0x8D, 0x0C, 0xC0, 0x48, 0x8B, 0x47, 0x18 };             // slot = [data+0x18] + idx*72
        static const u8 s32[] = { 0x48, 0xC1, 0xFE, 0x05 };                                     // edges of 32 bytes
        bool lay = memcmp(fa + 0x12d, push20, 5) == 0 && memcmp(fr + 0x179, push20, 5) == 0
            && memcmp(fa + 0xf0, find20, 3) == 0 && memcmp(fa + 0xf4, next20, 4) == 0 && fr[0x108] == 0xE8;
        if (lay) {
            // (the call's target inside the game's code before it is read: on another build the E8 may be no call, and a target
            // read outside the image crashed the game at its start)
            const u8* g = fr + 0x108 + 5 + *(const i32*)(fr + 0x109);
            lay = (uptr)g >= g_textStart && (uptr)g + 0x87 <= g_textEnd
                && memcmp(g + 0x6d, s72, 8) == 0 && memcmp(g + 0x83, s32, 4) == 0;
        }
        if (!lay) return false;
    }
    static const u8 proAdd[] = { 0x48, 0x89, 0x5C, 0x24, 0x18, 0x48, 0x89, 0x74, 0x24, 0x20, 0x55, 0x57, 0x41, 0x56 };
    static const u8 proRng[] = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x10, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55 };
    void* t1 = DetourWhole(mem, add, proAdd, (int)sizeof(proAdd), (void*)RoadAdd);
    if (!t1) return false;
    g_roadAddOrig = (RoadFn9)t1;
    void* t2 = DetourWhole(mem, rng, proRng, (int)sizeof(proRng), (void*)RoadAddRange);
    if (!t2) return false;     // (Add then only forwards: g_roadOn stays 0)
    g_roadAddRangeOrig = (RoadFn9)t2;
    g_roadOn = 1;
    return true;
}

// 12 (diagnostic, with the entity log MPFEVER_ENTLOG only): the animals' moves of ecs::AnimalMoveSystem's update (vfunc 12),
// right after its thread pool's loop: 28-byte records {index in the system's list, new place} at [rsp+0x68] (begin, end), the
// time step spilled at [rbp-0x30], the count of animals in edi. Every update goes to animupd.txt ("u <step> <animals> <dt bits>
// <moves> iter <n>") and each step's moves to animoves.txt as a hash of their records ("<step> <moves> <hash>"): the first step
// whose hash differs between two games shows where the animals parted (sessions of 2026-10-28, see "animals in one piece" below).
static void LogAnimalMoves(SavedRegs* r)
{
    u64 sp = OrigRsp(r);
    if (!g_entLog || !Readable((void*)(sp + 0x68), 16)) return;
    u64 b = *(u64*)(sp + 0x68), e = *(u64*)(sp + 0x70);
    u64 n = (e >= b && !((e - b) % 28) && (e - b) < (64u << 20)) ? (e - b) / 28 : 0;
    static HANDLE uf = INVALID_HANDLE_VALUE, mf = INVALID_HANDLE_VALUE;
    if (uf == INVALID_HANDLE_VALUE) { char path[400]; PathOf(path, "animupd.txt"); uf = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0); }
    if (uf != INVALID_HANDLE_VALUE && Readable((void*)(r->rbp - 0x30), 4)) {
        Buf l; l.str("u ").dec((long)StepOf((u8*)g_slot)).str(" ").dec((long)(u32)r->rdi).str(" ").hex((u64)*(u32*)(r->rbp - 0x30))
            .str(" ").dec((long)n).str(" iter ").dec(g_iter).str("\r\n");
        DWORD w; WriteFile(uf, l.s, (DWORD)l.n, &w, 0);
    }
    if (!n || !Readable((void*)b, n * 28)) return;
    if (mf == INVALID_HANDLE_VALUE) { char path[400]; PathOf(path, "animoves.txt"); mf = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0); }
    if (mf == INVALID_HANDLE_VALUE) return;
    u64 h = 0xcbf29ce484222325ull;
    for (u64 q = 0; q < n * 28; q++) { h ^= ((u8*)b)[q]; h *= 0x100000001b3ull; }
    Buf l; l.dec((long)StepOf((u8*)g_slot)).str(" ").dec((long)n).str(" ").hex(h).str("\r\n");
    DWORD w; WriteFile(mf, l.s, (DWORD)l.n, &w, 0);
}

// 6: the platform choice (TPF3-MP's platform-order, visit site). ecs::TransportVehicleSystem::Update2 walks its node list,
// 8-byte {entity, TransportVehicle index} records ([[r13+8]], as many as its int argument spilled at [rbp+0x5b0]), with rsi
// 0, 8, 16... and reloads the list's begin into rdi every iteration; each en-route vehicle asks FindNextFreeTerminal for a
// platform, and what it takes is seen by the vehicles asked after it. The list is the engine's add/remove history (another
// order in a loaded world than in a running one): rdi is pointed at a copy sorted by entity id, made at the first iteration.
// The engine's list is never written, and rdi is set anew after the loop.
struct VisitSlot { u32 tid; u64 list, count, cap; u64* sorted; bool active; };
static VisitSlot g_visit[8];
static VisitSlot* VisitOf()
{
    u32 tid = GetCurrentThreadId();
    for (int i = 0; i < 8; i++) if (g_visit[i].tid == tid) return &g_visit[i];
    for (int i = 0; i < 8; i++) if (_InterlockedCompareExchange((volatile long*)&g_visit[i].tid, (long)tid, 0) == 0) return &g_visit[i];
    return 0;
}
static void FixPlatformVisit(SavedRegs* r)
{
    VisitSlot* v = VisitOf();
    if (!v) { _InterlockedIncrement(&g_orderRefused[6]); return; }
    if (r->rsi == 0) {
        v->active = false;
        _InterlockedIncrement(&g_orderSorts[6]);
        u64 holder = r->rax, begin = r->rdi;
        if (!Readable((void*)(r->rbp + 0x5b0), 4) || !Readable((void*)holder, 16)) { _InterlockedIncrement(&g_orderRefused[6]); return; }
        i32 cnt = *(i32*)(r->rbp + 0x5b0);
        u64 end = *(u64*)(holder + 8);
        if (cnt < 0 || cnt > (1 << 20) || *(u64*)holder != begin || end < begin || end - begin != (u64)cnt * 8) { _InterlockedIncrement(&g_orderRefused[6]); return; }
        u64 n = (u64)cnt;
        if (n < 2 || !Readable((void*)begin, n * 8)) return;
        const u64* rec = (const u64*)begin;
        bool sorted = true;
        for (u64 i = 1; i < n; i++) if ((i32)(u32)rec[i - 1] >= (i32)(u32)rec[i]) { sorted = false; break; }
        if (sorted) return;
        if (v->cap < n) {
            u64 cap = n + n / 2 + 16;
            u64* p = (u64*)HeapAlloc(GetProcessHeap(), 0, cap * 8);
            if (!p) { _InterlockedIncrement(&g_orderRefused[6]); return; }
            if (v->sorted) HeapFree(GetProcessHeap(), 0, v->sorted);
            v->sorted = p; v->cap = cap;
        }
        u64* s = v->sorted;
        for (u64 i = 0; i < n; i++) s[i] = rec[i];
        u64 gap = 1;
        while (gap < n / 3) gap = gap * 3 + 1;
        for (; gap > 0; gap /= 3)
            for (u64 i = gap; i < n; i++) { u64 x = s[i]; i32 k = (i32)(u32)x; u64 j = i; while (j >= gap && (i32)(u32)s[j - gap] > k) { s[j] = s[j - gap]; j -= gap; } s[j] = x; }
        for (u64 i = 1; i < n; i++) if ((u32)s[i - 1] == (u32)s[i]) { _InterlockedIncrement(&g_orderRefused[6]); return; }   // two records of one entity
        _InterlockedIncrement(&g_orderReorders[6]);
        v->list = begin; v->count = n; v->active = true;
    }
    if (!v->active) return;
    if (r->rsi / 8 >= v->count || r->rdi != v->list) { v->active = false; _InterlockedIncrement(&g_orderRefused[6]); return; }
    r->rdi = (u64)v->sorted;
}

// 7: the platform choice, candidate site: FindNextFreeTerminal std::sorts its 12-byte candidate terminals [r13, r14) by a
// cost compared as floats only; equal costs keep an order that depends on the input's. They are first put in one order (by
// their second, third, then first word), so equal costs break the same way in every game.
static inline bool CandLess(const u32* a, const u32* b)
{
    if (a[1] != b[1]) return a[1] < b[1];
    if (a[2] != b[2]) return a[2] < b[2];
    return a[0] < b[0];
}
static void FixPlatformCandidates(SavedRegs* r)
{
    u64 b = r->r13, e = r->r14;
    _InterlockedIncrement(&g_orderSorts[7]);
    if (e < b || (e - b) % 12) { _InterlockedIncrement(&g_orderRefused[7]); return; }
    u64 n = (e - b) / 12;
    if (n < 2) return;
    if (n > 4096 || !Writable((void*)b, e - b)) { _InterlockedIncrement(&g_orderRefused[7]); return; }
    u32* c = (u32*)b;
    bool sorted = true;
    for (u64 i = 1; i < n; i++) if (CandLess(c + 3 * i, c + 3 * (i - 1))) { sorted = false; break; }
    if (sorted) return;
    _InterlockedIncrement(&g_orderReorders[7]);
    for (u64 i = 1; i < n; i++) {
        u32 x0 = c[3 * i], x1 = c[3 * i + 1], x2 = c[3 * i + 2];
        u32 x[3] = { x0, x1, x2 };
        u64 j = i;
        while (j > 0 && CandLess(x, c + 3 * (j - 1))) { c[3 * j] = c[3 * j - 3]; c[3 * j + 1] = c[3 * j - 2]; c[3 * j + 2] = c[3 * j - 1]; j--; }
        c[3 * j] = x0; c[3 * j + 1] = x1; c[3 * j + 2] = x2;
    }
}

// 8: the town street field (TPF3-MP's town-field-cache). When a town builds a street, the street's end is bent towards the
// town's street field, read by StreetField::At, which keeps its answers in a std::map keyed by the point's 50 m cell (not
// saved) and answers a later point of the same cell with the first point's answer. Which points asked before (in this game
// since it was loaded) decides the angle: a loaded world (a player who joined, a resync) and a running one differ. The
// lookup's end test (cmp byte [r9+0x19],0: the found node's nil flag) is given the map's head (r10, nil set), so every call
// computes the answer at the point asked; the engine's own insert runs as before.
static void FixTownField(SavedRegs* r)
{
    _InterlockedIncrement(&g_orderSorts[8]);
    u64 head = r->r10;
    if (!head || !Readable((void*)(head + 0x19), 1) || *(u8*)(head + 0x19) == 0) { _InterlockedIncrement(&g_orderRefused[8]); return; }
    if (r->r9 != head) { _InterlockedIncrement(&g_orderReorders[8]); r->r9 = head; }
}

// 9: the persons waiting for a path (TPF3-MP's person-needs-path-order, TF2's idle). ecs::SimEntityNeedsPathSystem::Update
// builds one input per entry of its list ([[r13+0x10]], a vector<Entity> in insertion order) and PathFactory::Compute seeds a
// generator per chunk from the step and the chunk's start: each trip follows the person's place in the list. The outputs are
// matched back by position in the same call, so the list is sorted in place before its first read. The list is copy-on-
// write, shared with the replicated engine's copy: when shared, a private copy is taken first through the engine's own getter.
typedef u64 (*CowGetter)(u64 sharedPtr);
static u32 g_needsPathGetter = 0;
static void FixNeedsPath(SavedRegs* r)
{
    u64 sys = r->r13;
    if (!g_needsPathGetter || !Readable((void*)(sys + 0x10), 16)) { _InterlockedIncrement(&g_orderRefused[9]); return; }
    u64 control = *(u64*)(sys + 0x18);
    if (!control || !Readable((void*)(control + 8), 4)) { _InterlockedIncrement(&g_orderRefused[9]); return; }
    i32 uses = *(i32*)(control + 8);
    if (uses < 1) { _InterlockedIncrement(&g_orderRefused[9]); return; }
    u64 data = *(u64*)(sys + 0x10);
    if (!data || !Readable((void*)data, 24)) { _InterlockedIncrement(&g_orderRefused[9]); return; }
    u64 b = *(u64*)data, e = *(u64*)(data + 8);
    if (e < b) { _InterlockedIncrement(&g_orderRefused[9]); return; }
    if (e - b < 8) { _InterlockedIncrement(&g_orderSorts[9]); return; }   // fewer than two: nothing to order (and no copy)
    if (uses > 1) {
        ((CowGetter)(g_base + g_needsPathGetter))(sys + 0x10);
        data = *(u64*)(sys + 0x10);
    }
    SortEntityVector(data, 9);
}

// 10: the TickEpoch of the street and track segments (time, commandIndex, subIndex: "the last time an entity was modified or
// added"). street_util::AddToEngine gives each new segment of a build its component; the engine fills commandIndex (a per-frame
// counter of the builds applied) and subIndex (its place in the build) when commandIndex is still -1, and keeps the time the
// proposal's segment carries: the street tool's GameTime.tickCount on the builder's game (the frames it was open, paused ones
// too), 0 on the games that replay the build from its segments, the old segment's when the tool replaced one. The towns' parcels
// compare those (parcel_util: the older segment keeps the parcel, then the lower commandIndex, subIndex and entity id), so the
// same street had another age on every game and towns grew differently next to it. Seen in the savegames of the two games of
// 2026-10-25, in the same pause: 275 of 1380 segments differed (the host's tool times against 0, commandIndex 2230 against 0,
// and subIndex 33 against 12: a replay does not group the segments as the tool does). Every segment added to the world's
// engine (by a command, or by a town in the simulation step) now gets the step it is added at (updateCount, the same on every
// game) and commandIndex and subIndex 0: segments of one step are ordered by their entity ids, which every game gives alike. cmp word [rdi+0x31c],0 (whether the engine stamps it) finds it stamped.
static u32 g_getUpdRva = 0;                         // GameTime's updateCount getter, called with the state's time (state+0x28)
static volatile long g_tickLogged = 0;
// Diagnostic (MPFEVER_FREEQLOG=1, tests): the free-id queue of the simulation's engine at the first step past every 50, by the
// step's number (GameTime.updateCount, the same on every game): "freeq step <s> size <n> sum <sum of ids> head <next id>". Two
// games in step give the same line; the first step where they differ is within 50 steps of the action that shifted the ids
// (entities made or removed on one game only), long before the vehicles or the towns drift. Compared by tools/freeq_diff.py.
static u32 g_freeqLast = 0xFFFFFFFFu;
static u32 StepOf(u8* gs)
{
    if (!gs || !g_getUpdRva || !Readable(gs + 0x18, 0x18)) return 0xFFFFFFFFu;
    u64 time = *(u64*)(gs + 0x28);
    if (!time || !Readable((void*)time, 0x18)) return 0xFFFFFFFFu;
    return ((u32(*)(u64))(g_base + g_getUpdRva))(time);
}
static void FreeqWrite(u8* eng, u32 step);
static void FreeqLine(u8* gs)
{
    if (g_freeqExact || !gs || !g_getUpdRva || !Readable(gs + 0x18, 0x18)) return;
    u64 time = *(u64*)(gs + 0x28);
    u8* eng = *(u8**)(gs + 0x18);
    if (!time || !eng || !Readable((void*)time, 0x18)) return;
    u32 step = ((u32(*)(u64))(g_base + g_getUpdRva))(time);
    // (each 50-step mark passed: above 1x one iteration makes several steps, so the exact multiples are seldom met; the step written
    // is the real one, the comparison takes the steps both games wrote)
    if (g_freeqLast != 0xFFFFFFFFu && step / 50 == g_freeqLast / 50) return;
    g_freeqLast = step;
    FreeqWrite(eng, step);
}
// (0.6.8) before every step that is a multiple of 50, from the steps' wrapper (InstallStepSnap): every game writes the same steps
static void FreeqStep(void* engine)
{
    u8* gs = (u8*)g_slot;
    if (!gs || !g_getUpdRva || !Readable(gs + 0x18, 0x18) || *(void**)(gs + 0x18) != engine) return;
    u32 step = StepOf(gs);
    if (step == 0xFFFFFFFFu || step % 50 || step == g_freeqLast) return;
    g_freeqLast = step;
    FreeqWrite((u8*)engine, step);
}
// "freeq step <s> size <n> sum <sum> head <id> hash <ids' hash> count <entities ever made>": the queue's ids in its order (sorted,
// see "free id queue") and the size of the engine's entity table, the id a new entity gets when the queue is empty
static void FreeqWrite(u8* eng, u32 step)
{
    u8* q = eng + 0xd8;
    if (!Readable(q, 0x28)) return;
    AcquireSRWLockExclusive(&g_fqLock);
    u64 map = *(u64*)(q + 8), ms = *(u64*)(q + 0x10), off = *(u64*)(q + 0x18), n = *(u64*)(q + 0x20);
    u64 sum = 0; i32 head = -1; bool ok = true;
    u32 hash = 2166136261u;
    if (n && (!map || !ms || (ms & (ms - 1)) || n > ms * 4 || n > (32u << 20) || !Readable((void*)map, ms * 8))) ok = false;
    for (u64 i = 0; ok && i < n; i++) {
        u64 j = off + i;
        i32* blk = *(i32**)(map + ((j >> 2) & (ms - 1)) * 8);
        if (!blk || ((u64)blk & 3)) { ok = false; break; }
        i32 v = blk[j & 3];
        if (i == 0) head = v;
        sum += (u32)v;
        hash = (hash ^ (u32)v) * 16777619u;
    }
    ReleaseSRWLockExclusive(&g_fqLock);
    u64 eb = Readable(eng + 0x90, 16) ? *(u64*)(eng + 0x90) : 0, ee = eb ? *(u64*)(eng + 0x98) : 0;
    Buf b; b.str("freeq step ").dec((long)step);
    if (ok) b.str(" size ").dec((long)n).str(" sum ").dec((long)(sum & 0x7fffffff)).str(" head ").dec(head).str(" hash ").hex(hash)
        .str(" count ").dec(ee >= eb ? (long)((ee - eb) / 24) : -1);
    else b.str(" unreadable");
    LogLine(b);
}

static void FixTickEpoch(SavedRegs* r)
{
    _InterlockedIncrement(&g_orderSorts[10]);
    u8* gs = ApplyingState();
    // (the towns lay their streets in the simulation step itself, outside any command: on the simulation thread, the step's
    // game state; their commandIndex was the frame's count of builds, which another game batching its steps otherwise has
    // another of)
    if (!gs && g_simTid && GetCurrentThreadId() == (DWORD)g_simTid) gs = (u8*)g_slot;
    u64 rec = r->rdi;
    if (!gs || !g_getUpdRva || !Readable(gs + 0x18, 0x18) || r->rsi != *(u64*)(gs + 0x18) || !Writable((void*)(rec + 0x318), 8)) {
        _InterlockedIncrement(&g_orderRefused[10]);
        // (diagnostic: which segments are left to the engine's own stamping: outside a command, in which engine, on which thread)
        static volatile long shown = 0;
        if (shown < 12) {
            _InterlockedIncrement(&shown);
            void* world = g_slot && Readable((u8*)g_slot + 0x18, 8) ? *(void**)((u8*)g_slot + 0x18) : 0;
            Buf b; b.str("tick epoch: segment ").dec(*(i32*)rec).str(" left to the engine (").str(gs ? "in a command, another engine" : "outside a command")
                .str(r->rsi == (u64)world ? ", the world's engine" : ", not the world's engine").str(", thread ").dec((long)GetCurrentThreadId())
                .str(GetCurrentThreadId() == (DWORD)g_simTid ? " (simulation)" : "").str(", it carries ").dec((long)*(u32*)(rec + 0x318)).str("/").dec((long)(short)*(u16*)(rec + 0x31c)).str(")");
            LogLine(b);
        }
        return;
    }
    u64 time = *(u64*)(gs + 0x28);
    if (!time || !Readable((void*)time, 0x18)) { _InterlockedIncrement(&g_orderRefused[10]); return; }
    u32 step = ((u32(*)(u64))(g_base + g_getUpdRva))(time);
    u32 was = *(u32*)(rec + 0x318);
    u16 wasCmd = *(u16*)(rec + 0x31c);
    if (was != step || wasCmd != 0xFFFF) _InterlockedIncrement(&g_orderReorders[10]);
    if (g_tickLogged < 6) {
        _InterlockedIncrement(&g_tickLogged);
        Buf b; b.str("tick epoch: segment ").dec(*(i32*)rec).str(" added at step ").dec((long)step).str(" (it carried ").dec((long)was).str("/")
            .dec((long)(short)wasCmd).str(")"); LogLine(b);
    }
    *(u32*)(rec + 0x318) = step;
    *(u16*)(rec + 0x31c) = 0;
    *(u16*)(rec + 0x31e) = 0;
}

// A mid-function splice: steal whole instructions at the site (no branch, call or rip-relative operand, nothing jumping
// inside them), jump to a stub that saves every register and xmm0-5, calls fn with the saved registers, restores them,
// runs the stolen bytes and jumps back.
static bool Splice(u8*& mem, u32 rva, int steal, SpliceFn fn)
{
    u8* site = (u8*)(g_base + rva);
    Asm a{ mem };
    a.b(0x9C);                                                     // pushfq
    { const u8 t_[] = { 0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x57, 0x41, 0x50, 0x41, 0x51, 0x41, 0x52, 0x41, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57 }; a.bn(t_, (int)sizeof(t_)); }
    // mov rcx,rsp; mov rbx,rsp; and rsp,-16; sub rsp,0x80
    { const u8 t_[] = { 0x48, 0x89, 0xE1, 0x48, 0x89, 0xE3, 0x48, 0x83, 0xE4, 0xF0, 0x48, 0x81, 0xEC, 0x80, 0x00, 0x00, 0x00 }; a.bn(t_, (int)sizeof(t_)); }
    for (int x = 0; x < 6; x++) { const u8 t_[] = { 0xF3, 0x0F, 0x7F, (u8)(0x44 | (x << 3)), 0x24, (u8)(0x20 + 16 * x) }; a.bn(t_, 6); }      // movdqu [rsp+..],xmmN
    a.b(0x48); a.b(0xB8); a.imm64((u64)fn);                        // mov rax,fn
    a.b(0xFF); a.b(0xD0);                                          // call rax
    for (int x = 0; x < 6; x++) { const u8 t_[] = { 0xF3, 0x0F, 0x6F, (u8)(0x44 | (x << 3)), 0x24, (u8)(0x20 + 16 * x) }; a.bn(t_, 6); }      // movdqu xmmN,[rsp+..]
    // mov rsp,rbx; pop r15..r8, rdi, rsi, rbp, rbx, rdx, rcx, rax; popfq
    { const u8 t_[] = { 0x48, 0x89, 0xDC, 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x41, 0x5B, 0x41, 0x5A, 0x41, 0x59, 0x41, 0x58, 0x5F, 0x5E, 0x5D, 0x5B, 0x5A, 0x59, 0x58, 0x9D }; a.bn(t_, (int)sizeof(t_)); }
    a.bn(site, steal);                                             // the stolen instructions
    a.b(0xFF); a.b(0x25); a.b(0); a.b(0); a.b(0); a.b(0); a.imm64((u64)(site + steal));   // jmp back
    u8* stub = mem;
    mem = (u8*)(((u64)a.p + 15) & ~15ull);
    DWORD old;
    if (!VirtualProtect(site, steal, PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[16];
    patch[0] = 0xE9; *(i32*)(patch + 1) = (i32)(stub - (site + 5));
    for (int k = 5; k < steal; k++) patch[k] = 0x90;
    memcpy(site, patch, steal);
    VirtualProtect(site, steal, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, steal);
    return true;
}

// ---------------------------------------------------------------- drift diagnostic (0.8.2, MPFEVER_DRIFTDIAG)
// The people drift of #150, reproduced on 2026-11-11 (two PCs, "Test Leawood", no input): every new person and rebuilt town
// building took another entity id on each game, after an entity existed on one game only for a moment; the entity log of test C
// (MPFEVER_ENTLOG, 90 MB an hour) showed the first such entity (an aircraft's octree node, step 880451), long before the people
// differed. That log is too heavy for the players' games. Here, by default, at a cost of a few counters:
//   - every entity the simulation's engine adds or removes on its thread goes into a ring in memory (the last 131072: id, step,
//     the engine system whose update made it, its caller), nothing written while the game runs;
//   - every step's digest goes into a second ring (the last 16384 steps): the free-id queue (size, sum, hash) and the step's
//     additions and removals (counts and an order-free hash of their ids);
//   - the engine system running is known from its update loop (ecs::Engine::Update, "mov rcx,[rdi] / mov rdx,rsi" before each
//     system's call), by its class name (RTTI, the same on Steam, GOG and Epic copies);
//   - when the mod's check finds a lasting difference (its first forced check, on every game at the same check), the mod writes
//     native_drift.txt and both rings are written to drift_<check>_steps.txt / drift_<check>_ops.txt by a thread of their own
//     (the last 3 kept), with the report's files. tools/drift_diff.py compares two games' files: the first step that differs,
//     its operations, and the system that made them.
// Read only: nothing the simulation decides changes, a game with it and another without stay alike. MPFEVER_DRIFTDIAG=0: off.

static bool g_entDetours = false;                 // (AddEntity/RemoveEntity hooked, shared with MPFEVER_ENTWATCH)
static volatile u32 g_diagStep = 0;
static volatile long g_curSys = 0;                // index into g_sysVt / g_sysName (0: no system's update under way)
struct DiagOp { u32 step; i32 id; u16 sys; u16 add; u32 caller; };
struct DiagStep { u32 step; u32 qsize; u64 qsum; u32 qhash; u32 adds; u32 rems; u32 setHash; u32 pad; };
static const long DIAG_OPS = 1 << 17, DIAG_STEPS = 1 << 14;
static DiagOp* g_dOps = 0;
static volatile long g_dOpN = 0;
static DiagStep* g_dSteps = 0;
static volatile long g_dStepN = 0;
static u32 g_stepAdds = 0, g_stepRems = 0, g_stepSet = 0;
static u64 g_sysVt[256];
static char g_sysName[256][48];
static volatile long g_sysN = 1;
static long g_driftLast = 0;
static long g_driftKept[3] = { 0, 0, 0 };
static long g_driftPoll = 0;
static long g_driftFirst = 0;                     // (0.8.4) the first check kept since the last load (never removed, see DriftPoll)
static bool g_driftFirstOn = true;                // (MPFEVER_DRIFTFIRST=0: false, set in InstallDriftDiag)

static inline u32 MixId(i32 id, u32 add) { u32 x = (u32)id * 2654435761u ^ (add ? 0x9e3779b9u : 0x7f4a7c15u); x ^= x >> 15; x *= 2246822519u; x ^= x >> 13; return x; }

// a system's class name from its vtable (MSVC x64 RTTI: the complete object locator before the vtable, its type descriptor's name)
static void SysClassName(u64 vt, char* out, int cap)
{
    out[0] = '?'; out[1] = 0;
    if (!Readable((void*)(vt - 8), 8)) return;
    u64 col = *(u64*)(vt - 8);
    if (!Readable((void*)col, 24) || *(u32*)col != 1) return;
    u8* td = (u8*)(g_base + *(u32*)(col + 12));
    if (!Readable(td + 16, 4)) return;
    const char* n = (const char*)(td + 16);
    if (n[0] == '.' && n[1] == '?' && n[2] == 'A' && (n[3] == 'V' || n[3] == 'U')) n += 4;
    int k = 0;
    for (int i = 0; k < cap - 1 && i < 120 && Readable(n + i, 1) && n[i]; i++) {
        if (n[i] == '@' && n[i + 1] == '@') break;
        out[k++] = n[i] == '@' ? '.' : n[i];
    }
    out[k] = 0;
}

static long SysIndex(u64 vt)
{
    long n = g_sysN;
    for (long i = 1; i < n; i++) if (g_sysVt[i] == vt) return i;
    if (n >= 256) return 0;
    g_sysVt[n] = vt;
    SysClassName(vt, g_sysName[n], (int)sizeof(g_sysName[n]));
    g_sysN = n + 1;
    return n;
}

// ecs::Engine::Update's loop, before each system's update call: rdi points to the system's slot in the engine's list
static void DiagSystem(SavedRegs* r)
{
    if ((long)GetCurrentThreadId() != g_simTid) return;
    u64 slot = r->rdi;
    if (!Readable((void*)slot, 8)) return;
    u64 sys = *(u64*)slot;
    if (!sys || !Readable((void*)sys, 8)) return;
    g_curSys = SysIndex(*(u64*)sys);
}
// (after the loop: the next additions come from elsewhere, commands, notifications)
static void DiagSystemsDone(SavedRegs*) { if ((long)GetCurrentThreadId() == g_simTid) g_curSys = 0; }

// the simulation's engine on its thread only (the interface's copy follows at its own pace and makes the same entities later)
static void DriftOp(int entity, bool add, void* ret)
{
    if (!g_dOps) return;
    long i = g_dOpN++ & (DIAG_OPS - 1);
    DiagOp& o = g_dOps[i];
    o.step = g_diagStep; o.id = entity; o.sys = (u16)g_curSys; o.add = add ? 1 : 0; o.caller = (u32)((uptr)ret - g_base);
    if (add) g_stepAdds++; else g_stepRems++;
    g_stepSet += MixId(entity, add ? 1 : 0);
}

static bool QueueDigest(u8* eng, u32* size, u64* sum, u32* hash)
{
    u8* q = eng + 0xd8;
    *size = 0; *sum = 0; *hash = 2166136261u;
    if (!Readable(q, 0x28)) return false;
    AcquireSRWLockExclusive(&g_fqLock);
    u64 map = *(u64*)(q + 8), ms = *(u64*)(q + 0x10), off = *(u64*)(q + 0x18), n = *(u64*)(q + 0x20);
    bool ok = true;
    if (n && (!map || !ms || (ms & (ms - 1)) || n > ms * 4 || n > (32u << 20) || !Readable((void*)map, ms * 8))) ok = false;
    for (u64 i = 0; ok && i < n && i < 65536; i++) {
        u64 j = off + i;
        i32* blk = *(i32**)(map + ((j >> 2) & (ms - 1)) * 8);
        if (!blk || ((u64)blk & 3)) { ok = false; break; }
        i32 v = blk[j & 3];
        *sum += (u32)v;
        *hash = (*hash ^ (u32)v) * 16777619u;
    }
    ReleaseSRWLockExclusive(&g_fqLock);
    *size = (u32)n;
    return ok;
}

// (0.8.3) The steps' digests, every game's, in the mod's checks: a drift is caught within seconds, while the rings above still
// hold the step it began at. In the players' reports of 0.8.2 the forced check came minutes after the entities parted (people,
// towns), and the operations ring (131072, about 3000 steps of a big map with three players) no longer held that step: "older than
// the rings" (#238, #241). Every 10 steps the simulation's thread reduces the digests of the last 50 steps (made since the last load
// and in a row) to one hash; a thread of its own writes the last 40 of them to native_steps.txt ("<step> <hash>"), the mod puts the
// one for its check's step into the check ("stepsDigest", a diagnostic part: never a reason to reload) and the launcher asks every
// game for its rings at the first check where it differs. MPFEVER_STEPSDIGEST=0: none (native_steps.txt not written).
struct StepsWin { u32 step; u32 hash; };
static StepsWin g_win[64];
static volatile long g_winN = 0;
static bool g_winOn = false;
static inline u32 StepHash(const DiagStep& s)
{
    u32 h = 2166136261u;
    u32 v[7] = { s.qsize, (u32)s.qsum, (u32)(s.qsum >> 32), s.qhash, s.adds, s.rems, s.setHash };
    for (int i = 0; i < 7; i++) { h = (h ^ v[i]) * 16777619u; h ^= h >> 13; }
    return h;
}
static void StepsWindow(u32 made)
{
    if (!g_winOn || !g_dSteps || made % 10 != 0) return;
    long end = g_dStepN;
    u32 h = 0x811c9dc5u, want = made, got = 0;
    // (from the newest back: the steps made, one after the other; a load (its steps start again lower or jump) ends the window)
    for (long k = 1; k <= 50 && k <= end && k <= DIAG_STEPS; k++) {
        const DiagStep& s = g_dSteps[(end - k) & (DIAG_STEPS - 1)];
        if (s.step != want) break;
        h = (h * 1000003u) ^ StepHash(s);
        got++;
        if (want == 0) break;
        want--;
    }
    long i = g_winN & 63;
    g_win[i].step = made;
    g_win[i].hash = got == 50 ? (h ? h : 1) : 0;
    _InterlockedIncrement(&g_winN);
}
static bool DriftLoadReset();
static DWORD WINAPI StepsWriter(void*)
{
    long last = -1;
    long loadsW = -1;
    for (;;) {
        Sleep(250);
        // (0.8.8) a game loaded: the file's lines are those of the game before, and the rings only start again at the first step
        // after the load (DriftStep). A resynchronisation's games stand still for seconds after their load, and the first check
        // read the hash of a step from before it: "stepsDigest" differed after every resynchronisation (the drift it had just
        // repaired), and every game dumped its rings for nothing. The file is emptied as soon as the load is counted.
        // MPFEVER_DRIFTLOADRESET=0: as before
        long loads = g_ctlLoads;
        if (loads != loadsW) {
            bool first = loadsW < 0;
            loadsW = loads;
            if (!first && DriftLoadReset()) { WriteSessionFile("native_steps.txt", "", 0); last = g_winN; }
        }
        long n = g_winN;
        if (n == last) continue;
        last = n;
        Buf b;
        long from = n > 40 ? n - 40 : 0;   // (40 lines fit the buffer; the slots written next are not among them)
        for (long k = from; k < n; k++) {
            const StepsWin& w = g_win[k & 63];
            b.dec((i64)w.step).str(" ").dec((i64)w.hash).str("\r\n");
        }
        WriteSessionFile("native_steps.txt", b.s, b.n);
    }
}

static bool DriftLoadReset()
{
    static long v = -1;
    if (v < 0) { char e[4]; v = (GetEnvironmentVariableA("MPFEVER_DRIFTLOADRESET", e, 3) == 1 && e[0] == '0') ? 0 : 1; }
    return v == 1;
}

// before every step of the simulation's engine (the steps' wrapper, see InstallStepSnap): the step just made, then the next one
static void DriftStep(void* engine)
{
    if (!g_dSteps) return;
    u8* gs = (u8*)g_slot;
    if (!gs || !Readable(gs + 0x18, 0x18) || *(void**)(gs + 0x18) != engine) return;
    u32 step = StepOf(gs);
    if (step == 0xFFFFFFFFu) return;
    // (0.8.4) a game loaded since the last step (a resynchronisation: DropAtLoad counts the loads): the rings start again empty. The
    // games paused at the same time T reload the save of T and go on at the next step numbers, so the steps before the load ran on
    // into those after it: "stepsDigest" differed right after every resynchronisation (#255-#261: the first 50 steps' window held
    // the drift before), that false alarm used up the run's one forced dump, and the rings of a later drift began with the steps of
    // the drift before (drift_diff named a step from before the load). The entities the load itself made go too. MPFEVER_DRIFTLOADRESET=0:
    // as before (one ring across the loads)
    static long loadsSeen = -1;
    long loads = g_ctlLoads;
    if (loads != loadsSeen) {
        bool first = loadsSeen < 0;
        loadsSeen = loads;
        if (!first && DriftLoadReset()) {
            g_dStepN = 0; g_dOpN = 0; g_winN = 0;
            g_stepAdds = g_stepRems = g_stepSet = 0;
            g_diagStep = step;
            Buf b; b.str("drift diagnostic: the rings start again after a load (step ").dec((i64)step).str(")"); LogLine(b);
            return;
        }
    }
    // (0.8.6, #150) the floating-point control of the simulation's thread (MXCSR: rounding, flush-to-zero, denormals-are-zero, the
    // exception masks; its flag bits 0-5 left out), said at the first step and whenever it changes: #274 drifted between an AMD and an
    // Intel PC on the same Windows build, and the game's code has no rsqrt/rcp; a driver or a library that changes these on one PC
    // would show here. MPFEVER_FPLOG=0: not said
    {
        static u32 lastCsr = 0xFFFFFFFFu;
        static long fpOn = -1;
        if (fpOn < 0) { char e[4]; fpOn = (GetEnvironmentVariableA("MPFEVER_FPLOG", e, 3) == 1 && e[0] == '0') ? 0 : 1; }
        if (fpOn) {
            u32 c = _mm_getcsr() & 0xFFC0u;
            if (c != lastCsr) {
                lastCsr = c;
                Buf b; b.str("floating-point control of the simulation's thread: MXCSR ").hex(c).str(" at step ").dec((i64)step); LogLine(b);
            }
        }
    }
    long i = g_dStepN++ & (DIAG_STEPS - 1);
    DiagStep& d = g_dSteps[i];
    d.step = g_diagStep; d.adds = g_stepAdds; d.rems = g_stepRems; d.setHash = g_stepSet; d.pad = 0;
    QueueDigest((u8*)engine, &d.qsize, &d.qsum, &d.qhash);
    g_stepAdds = g_stepRems = g_stepSet = 0;
    g_diagStep = step;
    StepsWindow(d.step);
}

struct DriftDump { long check; DiagOp* ops; long nOps, opEnd; DiagStep* steps; long nSteps, stepEnd; long sysN; char (*names)[48]; };
static DWORD WINAPI DriftWriter(void* p)
{
    DriftDump* d = (DriftDump*)p;
    char path[400], nm[64];
    Buf f; f.str("drift_").dec(d->check).str("_steps.txt");
    int k = 0; for (; k < f.n && k < 63; k++) nm[k] = f.s[k]; nm[k] = 0;
    PathOf(path, nm);
    HANDLE h = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h != INVALID_HANDLE_VALUE) {
        Buf l; l.str("drift diagnostic of check ").dec(d->check).str(": the last ").dec(d->nSteps).str(" steps of the simulation's engine\r\n")
            .str("step <s> queue <size> <sum> <hash> adds <n> rems <n> set <order-free hash of the step's additions and removals>\r\n");
        DWORD w; WriteFile(h, l.s, (DWORD)l.n, &w, 0);
        for (long i = 0; i < d->nSteps; i++) {
            const DiagStep& s = d->steps[(d->stepEnd - d->nSteps + i) & (DIAG_STEPS - 1)];
            Buf b; b.str("step ").dec((i64)s.step).str(" queue ").dec((i64)s.qsize).str(" ").dec((i64)s.qsum).str(" ").dec((i64)s.qhash)
                .str(" adds ").dec((i64)s.adds).str(" rems ").dec((i64)s.rems).str(" set ").dec((i64)s.setHash).str("\r\n");
            WriteFile(h, b.s, (DWORD)b.n, &w, 0);
        }
        CloseHandle(h);
    }
    Buf g; g.str("drift_").dec(d->check).str("_ops.txt");
    for (k = 0; k < g.n && k < 63; k++) nm[k] = g.s[k]; nm[k] = 0;
    PathOf(path, nm);
    h = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h != INVALID_HANDLE_VALUE) {
        Buf l; l.str("drift diagnostic of check ").dec(d->check).str(": the last ").dec(d->nOps).str(" entities the simulation's engine added (+) or removed (-)\r\n")
            .str("<step> <+|-><entity> <engine system whose update made it, - for none> <caller rva>\r\n");
        DWORD w; WriteFile(h, l.s, (DWORD)l.n, &w, 0);
        static char chunk[1 << 16];
        int cn = 0;
        for (long i = 0; i < d->nOps; i++) {
            const DiagOp& o = d->ops[(d->opEnd - d->nOps + i) & (DIAG_OPS - 1)];
            Buf b; b.dec((i64)o.step).str(o.add ? " +" : " -").dec((i64)o.id).str(" ").str(o.sys && o.sys < d->sysN ? d->names[o.sys] : "-").str(" ").hex(o.caller).str("\r\n");
            if (cn + b.n > (int)sizeof(chunk)) { WriteFile(h, chunk, (DWORD)cn, &w, 0); cn = 0; }
            memcpy(chunk + cn, b.s, b.n); cn += b.n;
        }
        if (cn) WriteFile(h, chunk, (DWORD)cn, &w, 0);
        CloseHandle(h);
    }
    Buf done; done.str("drift diagnostic: check ").dec(d->check).str(" written (").dec(d->nSteps).str(" steps, ").dec(d->nOps).str(" entity operations)"); LogLine(done);
    HeapFree(GetProcessHeap(), 0, d->ops); HeapFree(GetProcessHeap(), 0, d->steps); HeapFree(GetProcessHeap(), 0, d->names); HeapFree(GetProcessHeap(), 0, d);
    return 0;
}

// the mod's request (native_drift.txt: the check's number), polled on the simulation's thread every 32 iterations; the rings
// copied there at once, written by a thread of their own
static void DriftPoll()
{
    if (!g_driftOn || (++g_driftPoll & 31)) return;
    char path[400];
    PathOf(path, "native_drift.txt");
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    char b[24]; DWORD got = 0;
    ReadFile(f, b, sizeof(b) - 1, &got, 0);
    CloseHandle(f);
    long v = 0;
    for (DWORD i = 0; i < got && b[i] >= '0' && b[i] <= '9'; i++) v = v * 10 + (b[i] - '0');
    if (v <= 0 || v == g_driftLast) return;
    g_driftLast = v;
    DriftDump* d = (DriftDump*)HeapAlloc(GetProcessHeap(), 0, sizeof(DriftDump));
    if (!d) return;
    d->check = v;
    d->opEnd = g_dOpN; d->nOps = d->opEnd < DIAG_OPS ? d->opEnd : DIAG_OPS;
    d->stepEnd = g_dStepN; d->nSteps = d->stepEnd < DIAG_STEPS ? d->stepEnd : DIAG_STEPS;
    d->sysN = g_sysN;
    d->ops = (DiagOp*)HeapAlloc(GetProcessHeap(), 0, sizeof(DiagOp) * DIAG_OPS);
    d->steps = (DiagStep*)HeapAlloc(GetProcessHeap(), 0, sizeof(DiagStep) * DIAG_STEPS);
    d->names = (char(*)[48])HeapAlloc(GetProcessHeap(), 0, sizeof(g_sysName));
    if (!d->ops || !d->steps || !d->names) { Buf l; l.str("drift diagnostic: no memory for check ").dec(v); LogLine(l); return; }
    memcpy(d->ops, g_dOps, sizeof(DiagOp) * DIAG_OPS);
    memcpy(d->steps, g_dSteps, sizeof(DiagStep) * DIAG_STEPS);
    memcpy(d->names, g_sysName, sizeof(g_sysName));
    // (the files of the check before the last three removed: a long session keeps three drifts)
    long old = g_driftKept[0];
    g_driftKept[0] = g_driftKept[1]; g_driftKept[1] = g_driftKept[2]; g_driftKept[2] = v;
    // (0.8.4) the first check kept since the last load is never removed (the mod keeps its dump as sdump_drift_first.txt): a session
    // that drifted again and again kept only its last three, and the first drift was gone from the reports. MPFEVER_DRIFTFIRST=0: as before
    static long firstLoads = -1;
    if (g_driftFirstOn && firstLoads != g_ctlLoads) { firstLoads = g_ctlLoads; g_driftFirst = v; }
    if (old > 0 && old == g_driftFirst) old = 0;
    if (old > 0) {
        for (int w = 0; w < 2; w++) {
            Buf o; o.str("drift_").dec(old).str(w ? "_ops.txt" : "_steps.txt");
            char nm[64]; int k = 0; for (; k < o.n && k < 63; k++) nm[k] = o.s[k]; nm[k] = 0;
            PathOf(path, nm); DeleteFileA(path);
        }
    }
    HANDLE t = CreateThread(0, 0, DriftWriter, d, 0, 0);
    if (t) CloseHandle(t); else { Buf l; l.str("drift diagnostic: writer not started"); LogLine(l); }
}

// called before InstallStepSnap: the rings, the entity hooks and the system loop's two splices
static void InstallDriftDiag()
{
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_DRIFTDIAG", v, 3) > 0 && v[0] == '0') { Buf b; b.str("drift diagnostic: off (MPFEVER_DRIFTDIAG=0)"); LogLine(b); return; }
    if (!g_layout || !RVA_ADDENTITY || !RVA_REMOVEENTITY) { Buf b; b.str("drift diagnostic: off (the entity functions not found)"); LogLine(b); return; }
    u32 loop = FindSigRva("48 8B 0F 48 8B D6 C5 F8 28 DE 4C 8B C0 4C 8B 09 41 FF 51 58 48 83 C7 08 49 3B FE");
    static const u8 tail[] = { 0x75, 0x8C, 0x48, 0x8B, 0x5C, 0x24, 0x68, 0x48, 0x8B, 0x6C, 0x24, 0x70 };
    if (!loop || memcmp((void*)(g_base + loop + 27), tail, sizeof(tail)) != 0) { Buf b; b.str("drift diagnostic: off (the engine's system loop not found)"); LogLine(b); return; }
    g_dOps = (DiagOp*)HeapAlloc(GetProcessHeap(), 8, sizeof(DiagOp) * DIAG_OPS);
    g_dSteps = (DiagStep*)HeapAlloc(GetProcessHeap(), 8, sizeof(DiagStep) * DIAG_STEPS);
    u8* mem = AllocNear(0x200);
    if (!g_dOps || !g_dSteps || !mem) { Buf b; b.str("drift diagnostic: off (no memory)"); LogLine(b); return; }
    if (!Splice(mem, loop, 6, DiagSystem) || !Splice(mem, loop + 29, 5, DiagSystemsDone)) { Buf b; b.str("drift diagnostic: off (the system loop not spliced)"); LogLine(b); return; }
    InstallDetour(RVA_ADDENTITY, P_ADDENTITY, sizeof(P_ADDENTITY), (void*)&AddEntityDetour, (void**)&g_addEntOrig);
    InstallDetour(RVA_REMOVEENTITY, P_REMOVEENTITY, sizeof(P_REMOVEENTITY), (void*)&RemoveEntityDetour, (void**)&g_remEntOrig);
    g_entDetours = true;
    g_driftOn = true;
    { char df[4] = {}; if (GetEnvironmentVariableA("MPFEVER_DRIFTFIRST", df, 3) == 1 && df[0] == '0') g_driftFirstOn = false; }
    {
        char sd[4] = {};
        if (!(GetEnvironmentVariableA("MPFEVER_STEPSDIGEST", sd, 3) > 0 && sd[0] == '0')) {
            HANDLE t = CreateThread(0, 0, StepsWriter, 0, 0, 0);
            if (t) { CloseHandle(t); g_winOn = true; }
        }
        Buf sb; sb.str(g_winOn ? "steps' digests: every 10 steps, written to native_steps.txt (MPFEVER_STEPSDIGEST)" : "steps' digests: off"); LogLine(sb);
    }
    Buf b; b.str("drift diagnostic: on (entity operations ring ").dec(DIAG_OPS).str(", steps ring ").dec(DIAG_STEPS).str(", system loop at ").hex(loop).str(")"); LogLine(b);
}

struct OrderFix { const char* name; const char* sig; int offset; int steal; SpliceFn fn; };
static const OrderFix ORDER_FIXES[] = {
    { "freed ids", "49 8D 8D D8 00 00 00 4D 8B 0C 24 49 8B 41 08 48 89 44 24 20 4D 8B 09 4D 8B 85 F8 00 00 00 48 8D 55 87 E8", 0, 7, FixFreedIds },
    { "land vehicles", "45 0F 44 C4 41 BE 40 00 00 00 49 C7 C3 FF FF FF FF 0F 1F 80 00 00 00 00 4D 8D 76 FF 49 D1 EB 49 81 FB FD FF FF 7F 77 F0 4C 8B 6D E0 48 8B 75 E8 4C 3B EE", 40, 8, FixLandVehicles },
    { "destination candidates", "C7 44 24 60 01 00 00 00 E8 ?? ?? ?? ?? 4C 8B D0 48 8B 54 24 78 48 8B 4C 24 70 48 2B D1 48 C1 FA 02", 0, 8, FixCandidates },
    { "departures", "48 8B C8 E8 ?? ?? ?? ?? 48 8B 4D 07 48 3B 4D 0F 74 1A 48 8B 47 30", 8, 8, FixDepartures },
    { "arrivals", "E8 ?? ?? ?? ?? 48 8B 45 90 48 39 45 88 74 17 49 8B 4F 68 48 85 C9 74 0E", 5, 8, FixArrivals },
    { "vehicles at stop", "49 8B 4F 28 E8 ?? ?? ?? ?? 48 89 84 24 48 02 00 00 41 8B 7F 50 48 8B 4C 24 58", 9, 8, FixVehiclesAtStop },
    // TPF3-MP's signatures of build 40423 (the same bytes in 40420); 0.4.6
    { "platform visit", "49 8B 45 08 48 8B 38 49 8B 4D 10 48 63 44 3E 04 48 69 D8 E8 01 00 00", 7, 9, FixPlatformVisit },
    { "platform candidates", "49 8B CE 49 2B CD 48 8B C7 48 F7 E9 48 D1 FA 4C 8B C2 49 C1 E8 3F 4C 03 C2 4C 8D 4D F0 49 8B D6 49 8B CD E8", 0, 6, FixPlatformCandidates },
    { "town street field", "80 79 19 00 74 D6 41 80 79 19 00 75 35 41 3B 69 1C 75 0A 41 3B 71 20 75 04 32 D2 EB 04 41 0F 4D D3 84 D2 78 1D 4D 3B CA 74 18", 6, 5, FixTownField },
    { "needs path", "49 8B 45 10 48 8B 50 08 48 2B 10 48 C1 FA 02 4C 8D 45 30 48 8D 4D E0 E8", 0, 8, FixNeedsPath },
    // build 40425; 0.5.3
    { "tick epochs", "66 83 BF 1C 03 00 00 00 7D 1B 0F B7 05 ?? ?? ?? ?? 66 89 87 1C 03 00 00 0F B7 C5 66 89 87 1E 03 00 00 66 FF C5", 0, 8, FixTickEpoch },
    // 0.5.4: right after the freed ids were appended to the queue (the call of "freed ids" above)
    { "free id queue", "E8 ?? ?? ?? ?? 49 8B 14 24 4D 89 3C 24 48 85 D2 74 08 49 8B CC E8", 5, 8, FixFreeQueue },
    // build 40425 (diagnostic): right after the animals' thread-pool loop (the call), "mov rdi, [rsp+0x68]" stolen
    { "animal moves log", "E8 ?? ?? ?? ?? 4C 8B 65 90 48 8B 7C 24 68 4C 8B 74 24 70 49 3B FE", 9, 5, LogAnimalMoves },
};
static const int ORDER_N = (int)(sizeof(ORDER_FIXES) / sizeof(ORDER_FIXES[0]));

// The persons and the land vehicles in one piece (0.7.13, #150, #166, #170: games drifted apart with no action, one to six game
// minutes after a load, on the gigantic worlds most (184 and 274 MB), a passenger or a bus first: r166, one bus left a stop later
// on one game alone, every action and every other vehicle alike) a test, OFF by default until a test with two games proves it.
// The persons' moves (PersonMoveSystem, two loops), their boarding (SimPersonAtVehicle) and their leaving the buildings
// (SimEntityAtBuilding) are handed to the engine's thread pool in chunks, as the animals' moves were (see "the animals in one
// piece" in InstallOrderFixes): a walker's crossing test reads the segments' users that other chunks change at the same time,
// and each chunk's random draws are seeded by where the chunk starts. The same patch as the animals': each loop's chunk size
// ("mov r9d, chunk" right before the call of the pool's loop) set larger than any count, so that the pool's loop takes its own
// one-thread path. Each place is found by its signature (unique in the game's code), and the call it ends with is checked: to a
// function of the game's code that compares the count with the chunk size ("cmp r8d, r9d / jle") and the pool's size with 1
// ("sar rax, 4 / cmp eax, 1 / je"), both jumps to the same place (its one-thread path). A place not found, or another function,
// leaves its loop in chunks (logged). It changes the persons' (the vehicles') random draws: every game of a session needs the
// same setting. MPFEVER_PERSONSERIAL=1 (the persons' four loops), MPFEVER_VEHSERIAL=1 (the land vehicles' four loops), on
// every game; unset: in chunks, as before
// (0.8.3) KEPT OFF: on by default for a few hours (A/B on "Test Drift Big", x3.83 vs x3.81), but that map is empty (no transport,
// never played). On played games, two games at x4 for 5 minutes (2026-11-12): "Test Leawood" x1.79 in chunks / x1.35 in one piece
// (-25%), "Test Lag Rp" x2.55 / x2.36 (-7%). Too costly by default
struct SerialLoop { const char* name; const char* sig; };
static const SerialLoop PERSON_LOOPS[] = {
    { "person moves 512", "41 B9 00 02 00 00 44 8B C6 49 8B D7 48 8B C8 E8" },
    { "person moves 128", "41 B9 80 00 00 00 44 8B C6 48 8D 54 24 50 48 8B C8 C5 F8 77 E8" },
    { "persons at vehicles", "41 B9 40 00 00 00 44 8B C5 48 8D 54 24 40 48 8B C8 C5 F8 77 E8" },
    { "persons at buildings", "41 B9 00 01 00 00 45 8B C6 48 8D 55 E7 48 8B C8 E8" },
};
static const SerialLoop VEHICLE_LOOPS[] = {
    { "land vehicles 1", "41 B9 00 01 00 00 44 8B C3 48 8D 95 10 13 00 00 C5 F8 77 E8" },
    { "land vehicles 2", "41 B9 40 00 00 00 45 8B C6 48 8D 95 40 01 00 00 49 8B CA C5 F8 77 E8" },
    { "land vehicles 3", "41 B9 40 00 00 00 44 8B C3 48 8D 95 40 01 00 00 49 8B CA C5 F8 77 E8" },
    { "land vehicles 4", "41 B9 00 01 00 00 44 8B C3 48 8D 95 40 01 00 00 C5 F8 77 E8" },
};

// (0.7.13) whether the call a loop's signature ends with (its last byte, E8) goes to the pool's loop with its one-thread path
static bool SerialPathAt(u32 at, int n)
{
    u8* call = (u8*)(g_base + at + n - 1);
    if (call[0] != 0xE8 || (uptr)(call + 5) > g_textEnd) return false;
    uptr f = (uptr)((i64)(uptr)(call + 5) + *(i32*)(call + 1));
    if (f < g_textStart || f + 0x90 > g_textEnd) return false;
    const u8* p = (const u8*)f;
    int a = -1, b = -1;
    for (int k = 0; k + 13 <= 0x90; k++) {
        if (a < 0 && p[k] == 0x45 && p[k + 1] == 0x3B && p[k + 2] == 0xC1 && p[k + 3] == 0x0F && p[k + 4] == 0x8E) a = k;
        if (a >= 0 && k > a && p[k] == 0x48 && p[k + 1] == 0xC1 && p[k + 2] == 0xF8 && p[k + 3] == 0x04 && p[k + 4] == 0x83
            && p[k + 5] == 0xF8 && p[k + 6] == 0x01 && p[k + 7] == 0x0F && p[k + 8] == 0x84) { b = k; break; }
    }
    if (a < 0 || b < 0) return false;
    uptr ja = f + a + 9 + (i64)*(const i32*)(p + a + 5);      // jle: the count not above the chunk size
    uptr jb = f + b + 13 + (i64)*(const i32*)(p + b + 9);     // je: a pool of one thread
    return ja == jb;
}

// (0.7.13) the loops of one group in one piece: how many of n, the names of those left in chunks in miss
static int SerialLoops(const SerialLoop* loops, int n, Buf& miss)
{
    int done = 0;
    for (int i = 0; i < n; i++) {
        int len = 0;
        for (const char* q = loops[i].sig; *q; q++) if (*q != ' ' && (q == loops[i].sig || q[-1] == ' ')) len++;
        u32 at = FindSigRva(loops[i].sig);
        bool ok = false;
        if (at && SerialPathAt(at, len)) {
            u8* imm = (u8*)(g_base + at + 2);
            DWORD old;
            if (VirtualProtect(imm, 4, PAGE_EXECUTE_READWRITE, &old)) {
                *(u32*)imm = 0x7FFFFFFFu;
                VirtualProtect(imm, 4, old, &old);
                FlushInstructionCache(GetCurrentProcess(), imm, 4);
                ok = true;
            }
        }
        if (ok) done++;
        else miss.str(miss.n ? ", " : "").str(loops[i].name).str(at ? " (another function)" : " (not found)");
    }
    return done;
}

static void InstallPersonSerial()
{
    const int np = (int)(sizeof(PERSON_LOOPS) / sizeof(PERSON_LOOPS[0])), nv = (int)(sizeof(VEHICLE_LOOPS) / sizeof(VEHICLE_LOOPS[0]));
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_PERSONSERIAL", v, 3) > 0 && v[0] == '1') {
        Buf miss;
        int k = SerialLoops(PERSON_LOOPS, np, miss);
        miss.s[miss.n] = 0;
        Buf a; a.str("persons moved in one piece on the simulation's thread (").dec(k).str(" of ").dec(np).str(" loops").str(miss.n ? "; in chunks: " : "").str(miss.n ? miss.s : "").str(")");
        LogLine(a);
    }
    v[0] = 0;
    if (GetEnvironmentVariableA("MPFEVER_VEHSERIAL", v, 3) > 0 && v[0] == '1') {
        Buf miss;
        int k = SerialLoops(VEHICLE_LOOPS, nv, miss);
        miss.s[miss.n] = 0;
        Buf a; a.str("vehicles moved in one piece on the simulation's thread (").dec(k).str(" of ").dec(nv).str(" loops").str(miss.n ? "; in chunks: " : "").str(miss.n ? miss.s : "").str(")");
        LogLine(a);
    }
}

static void InstallOrderFixes()
{
    if (GetEnvironmentVariableA("MPFEVER_NOORDER", 0, 0) > 0) { Buf b; b.str("order fixes: off (MPFEVER_NOORDER)"); LogLine(b); return; }
    u8* mem = AllocNear(0x2000);
    if (!mem) { Buf b; b.str("order fixes: no memory near the game's code"); LogLine(b); return; }
    // the land vehicles' sort reads the records the way the engine's reservation loop does: refused unless that loop is there
    bool recordsOk = FindSigRva("4C 8B 45 80 49 8B 50 08 49 63 45 00 48 8D 0C 80 48 8B 02 4C 8D 24 88 49 8B 50 18") != 0;
    // the town street field's site lies 0xba into StreetField::At, whose miss path its jne reaches
    u32 fieldAt = FindSigRva("40 55 56 41 54 41 55 41 56 41 57 48 81 EC 98 00 00 00 C4 C1 7A 10 00 C5 FA 5E 0D ?? ?? ?? ?? C5 F2 58 15 ?? ?? ?? ?? 4C 8B 51 18");
    // the needs-path list's copy-on-write getter, called the way EntityToBeRemoved calls it (its head checked), and the
    // results loop that reads the list again by position
    u32 getCall = FindSigRva("48 8D 4F 10 E8 ?? ?? ?? ?? 48 8B F8 4C 8B 40 08 48 8B 10 49 3B D0 74 40");
    if (getCall) {
        u32 g = (u32)(getCall + 9 + *(i32*)(g_base + getCall + 5));
        static const u8 head[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0xD9,
            0x48, 0x8B, 0x41, 0x08, 0x48, 0x85, 0xC0, 0x0F, 0x84, 0xA7, 0x00, 0x00, 0x00, 0x83, 0x78, 0x08, 0x01, 0x0F, 0x8E, 0x9D, 0x00, 0x00, 0x00 };
        if (memcmp((void*)(g_base + g), head, sizeof(head)) == 0) g_needsPathGetter = g;
    }
    // GameTime's getters: tickCount (+0x3c) and updateCount (+0x40)
    u32 getTick = FindSigRva("48 83 EC 28 48 8B 41 10 48 8B 49 08 8B 10 E8 ?? ?? ?? ?? 8B 40 3C 48 83 C4 28 C3");
    u32 getUpd = FindSigRva("48 83 EC 28 48 8B 41 10 48 8B 49 08 8B 10 E8 ?? ?? ?? ?? 8B 40 40 48 83 C4 28 C3");
    g_getUpdRva = getUpd;
    if (g_applyTls == 0xFFFFFFFFu) g_applyTls = TlsAlloc();
    bool tickOn = false;
    Buf b; b.str("order fixes (from TPF3-MP):");
    for (int i = 0; i < ORDER_N; i++) {
        const OrderFix& f = ORDER_FIXES[i];
        u32 at = FindSigRva(f.sig);
        bool layout = true;
        if (i == 1) layout = recordsOk;
        // (three of the four ported in 0.5.0, OFF unless MPFEVER_ORDER2=1: 40 minutes at x4 on a large map stayed in sync
        // without them, as with them; nothing they would fix was ever seen in MPFever's sessions. Kept for a diagnosis. 0.7.13:
        // "Same platform order (test)", the 0.7.10 launcher setting that set it, is gone: no measured benefit, and every game,
        // the host's too, loads the same save at a resync (no game keeps running while the others load, TPF3-MP's case); the
        // variable in the environment of every game only, for tests. The
        // town street field is on since 0.5.3: a game that answered one point of a cell differently answered every later point
        // of it differently, which made a small difference between the games a lasting one)
        if (i >= 6 && i <= 9 && i != 8 && GetEnvironmentVariableA("MPFEVER_ORDER2", 0, 0) == 0) layout = false;
        if (i == 8) layout = layout && fieldAt && at + f.offset == fieldAt + 0xba && GetEnvironmentVariableA("MPFEVER_NOTOWNFIELD", 0, 0) == 0;
        // (the segments' ages: the stolen compare is the one the stamping follows, and the step comes from GameTime's getter)
        if (i == 10) layout = layout && getUpd && g_applyTls != 0xFFFFFFFFu && GetEnvironmentVariableA("MPFEVER_NOTICKEPOCH", 0, 0) == 0;
        if (i == 6 || i == 7) layout = layout && GetEnvironmentVariableA("MPFEVER_NOPLATFORMORDER", 0, 0) == 0;
        // (the free-id queue: right after the freed ids' append, r13 the engine; MPFEVER_NOFREEMIN=1 on every game: FIFO as before)
        // (its signature is unique in the game's code; the "freed ids" one cannot be searched again here, its site is spliced already)
        if (i == 11) layout = layout && GetEnvironmentVariableA("MPFEVER_NOFREEMIN", 0, 0) == 0;
        // (the animals' moves log: with the entity log only)
        if (i == 12) layout = layout && GetEnvironmentVariableA("MPFEVER_ENTLOG", 0, 0) > 0;
        if (i == 9) {
            static const u8 ctx[] = { 0x49, 0x8B, 0x45, 0x10, 0x48, 0x8B, 0x08, 0x42, 0x8B, 0x1C, 0xA1 };
            layout = layout && g_needsPathGetter && at && memcmp((void*)(g_base + at + 0x1ad), ctx, sizeof(ctx)) == 0
                && GetEnvironmentVariableA("MPFEVER_NONEEDSPATH", 0, 0) == 0;
        }
        bool ok = at && layout && Splice(mem, at + f.offset, f.steal, f.fn);
        if (i == 10) tickOn = ok;
        b.str(" ").str(f.name).str(ok ? " on" : " OFF").str(i + 1 < ORDER_N ? "," : "");
    }
    b.str(", road entries").str(InstallRoadOrder(mem) ? " on" : " OFF");
    LogLine(b);
    // (the mod compares the segments' ages only where they are stamped: its check "ages")
    // (0.7.7: and whether it refuses a held build on purpose, failid; MPFEVER_FAILID=0: not, the mod keeps its old ways)
    { char fv[4] = {}; if (GetEnvironmentVariableA("MPFEVER_FAILID", fv, 3) > 0 && fv[0] == '0') g_failOn = false; }
    WriteSessionFile("native_state.txt", tickOn ? (g_failOn ? "tickepochs=1\nfailid=1\n" : "tickepochs=1\nfailid=0\n") : (g_failOn ? "tickepochs=0\nfailid=1\n" : "tickepochs=0\nfailid=0\n"), 22);
    // Test MPFEVER_NOANIMALMOVE=1 (on every game): the animals stand still, ecs::AnimalMoveSystem's update returns at once (its
    // entry found from a unique sequence 0x36 bytes in, its prologue checked). Tells whether the towns' drifts start with them.
    if (GetEnvironmentVariableA("MPFEVER_NOANIMALMOVE", 0, 0) > 0) {
        u32 in = FindSigRva("C5 F8 28 FB 41 8B F8 4C 8B FA 48 8B F1 48 89 4D A0 48 8B 49 28 E8");
        static const u8 pro[] = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x20, 0x55, 0x56, 0x57 };
        u8* f = in ? (u8*)(g_base + in - 0x36) : 0;
        bool ok = false;
        if (f && memcmp(f, pro, sizeof(pro)) == 0) {
            DWORD old;
            if (VirtualProtect(f, 1, PAGE_EXECUTE_READWRITE, &old)) {
                f[0] = 0xC3;
                VirtualProtect(f, 1, old, &old);
                FlushInstructionCache(GetCurrentProcess(), f, 1);
                ok = true;
            }
        }
        Buf a; a.str(ok ? "animals stand still (MPFEVER_NOANIMALMOVE)" : "animals: their update was not found (MPFEVER_NOANIMALMOVE)"); LogLine(a);
    }
    // The animals in one piece (0.5.12): their moves computed on the simulation's thread. The engine hands them to its thread pool in
    // chunks of 128 ("mov r9d, 0x80" before the pool's loop); each animal writes its model instance and then asks the octree about
    // the others, which other threads are writing at the same time, and the chunks' random draws are seeded by where each chunk
    // starts, which depends on the PC's threads. An animal then took another step on one game: the octree's nodes, which are
    // entities, were made and freed otherwise, every entity made afterwards (a person, a town building) got another id, and the
    // towns drifted some minutes later (sessions of 2026-10-28: 8 of 15 long sessions drifted, 0 of 8 with this; moves and
    // entities the same from start to end). With a chunk size larger than any count the pool's loop takes its own one-thread path
    // (the one it takes on a one-thread PC): the same draws and the same answers on every game. MPFEVER_NOANIMALSERIAL=1 on every
    // game: in chunks as before.
    if (GetEnvironmentVariableA("MPFEVER_NOANIMALSERIAL", 0, 0) == 0) {
        u32 at = FindSigRva("41 B9 80 00 00 00 44 8B C7 48 8D 55 F0 C5 F8 77 E8");
        bool ok = false;
        if (at) {
            u8* imm = (u8*)(g_base + at + 2);
            DWORD old;
            if (VirtualProtect(imm, 4, PAGE_EXECUTE_READWRITE, &old)) {
                *(u32*)imm = 0x7FFFFFFFu;
                VirtualProtect(imm, 4, old, &old);
                FlushInstructionCache(GetCurrentProcess(), imm, 4);
                ok = true;
            }
        }
        Buf a; a.str(ok ? "animals moved in one piece on the simulation's thread" : "animals: the pool's chunk size was not found (moved in chunks)"); LogLine(a);
    }
    // (0.7.13) the persons' and the land vehicles' loops too, each with its own test switch (see InstallPersonSerial)
    InstallPersonSerial();
    // the simulation's seeds from GameTime.tickCount (the land vehicles' shuffle, a vehicle variant pick, town and street
    // development...): tickCount also counts the frames a game stands still, a different number on every game of a session;
    // those calls now read updateCount (the simulation step, the same everywhere). TPF3-MP's "paused-tick" fix does the same by
    // not counting the paused frames; this keeps tickCount itself as it is (the mod's stillness checks read it). The two calls
    // from the interface's tools (0x577e0b, 0x5a51f1) are left as they are (the street tool's is the segments' time, which the
    // tick epochs fix above replaces when the build is applied).
    int moved = 0;
    if (getTick && getUpd) {
        for (int ci = 0; ci < g_nSimCalls; ci++) {
            u32 c = g_simCalls[ci];
            if (!c) continue;
            u8* site = (u8*)(g_base + c);
            if (site[0] != 0xE8 || (u32)(c + 5 + *(i32*)(site + 1)) != getTick) continue;
            DWORD old;
            if (!VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &old)) continue;
            *(i32*)(site + 1) = (i32)(getUpd - (c + 5));
            VirtualProtect(site, 5, old, &old);
            FlushInstructionCache(GetCurrentProcess(), site, 5);
            moved++;
        }
    }
    Buf t; t.str("simulation seeds from the step count instead of tickCount: ").dec(moved).str(" of ").dec(g_nSimCalls).str(" calls"); LogLine(t);
}

// A save changed the world of the game that saved: the GameSave command removes, before it writes the file, the TerrainTileBrush
// component of every terrain tile whose ground textures are all empty (the component's storage, the tiles' revisions and the
// terrain's brush counters change). The games of a session save at other moments (autosaves count real time, a player saves
// by hand), so their worlds differed after a save. The call is left out: the components stay (they hold nothing, a game saved
// without the mod drops them at its next save), and saving changes nothing in the world. MPFEVER_SAVECLEANUP=1 keeps it.
static void PatchSaveCleanup()
{
    if (GetEnvironmentVariableA("MPFEVER_SAVECLEANUP", 0, 0) > 0) { Buf b; b.str("saves: the game's tile clean-up kept (MPFEVER_SAVECLEANUP)"); LogLine(b); return; }
    u32 at = FindSigRva("49 8B 44 24 08 48 8B 50 10 48 8B 48 18 E8 ?? ?? ?? ?? 49 8B 44 24 10");
    u8* site = at ? (u8*)(g_base + at + 13) : 0;
    DWORD old;
    bool ok = site && site[0] == 0xE8 && VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &old);
    if (ok) {
        static const u8 nop5[] = { 0x0F, 0x1F, 0x44, 0x00, 0x00 };
        memcpy(site, nop5, 5);
        VirtualProtect(site, 5, old, &old);
        FlushInstructionCache(GetCurrentProcess(), site, 5);
    }
    Buf b; b.str(ok ? "saves: no change to the world (the tile clean-up of the GameSave command left out)" : "saves: the tile clean-up NOT found (a save changes the world of the game that saves)"); LogLine(b);
}

// ---------------------------------------------------------------- the game's own autosave, off in a session (0.7.7)
// TF3 saves on its own every N minutes of real time (its options: autosaveIntervalMinutes), on every PC by its own clock:
// CGameUI's frame (vfunc 0x65ecd0 in 40425) adds the frame's time to [ui+0xe38] while the game runs, and calls
// UI::CGameUI::AutoSave (0x65a150) once it passes the interval, unless the byte [ui+0x1170] says not to. In a session that save
// stalled one game alone for 2.4 to 4 s in the middle of a run, the others waiting at the barrier, and twice in four the
// vehicles drifted within a minute after it (the user's server 2026-11-07 22:40 and 2026-11-08 01:39, 1.7 to 2.8 s before the
// session's own pause). While an MPFever session runs in this game (holding on, the mod's heartbeat fresh), the time counted
// is set back to 0 before the test: the game never saves on its own then, on no PC; MPFever.exe saves the host's world at a
// pause of every game instead (HostAutosave). Outside a session: the game's own test, as always. The site is found by its
// bytes (the offsets 0x1170 and 0xe38 in them), once in the code, else nothing is changed. MPFEVER_GAMEAUTOSAVE=1: the
// game's own autosave kept.
static KeptFile g_gasAliveFile = { 0, 0 };
static char g_gasLast[24];
static int g_gasN = -1;
static u64 g_gasAliveAt = 0, g_gasRead = 0;
static volatile long g_gasSkipped = 0;
static bool g_gasLogged = false;
static void GameAutosaveGate(SavedRegs* r)
{
    if (!g_enabled) return;
    u64 now = GetTickCount64();
    if (now - g_gasRead >= 1000) {
        g_gasRead = now;
        HANDLE f = KeptHandle(g_gasAliveFile, "bridge_alive.txt");
        if (f != INVALID_HANDLE_VALUE) {
            char b[24]; DWORD got = 0;
            SetFilePointer(f, 0, 0, 0);
            if (ReadFile(f, b, sizeof(b), &got, 0) && got > 0 && ((int)got != g_gasN || memcmp(b, g_gasLast, got) != 0)) {
                memcpy(g_gasLast, b, got); g_gasN = (int)got; g_gasAliveAt = now;
            }
        }
    }
    if (!g_gasAliveAt || now - g_gasAliveAt > 10000) return;
    u8* ui = (u8*)r->rsi;
    i64 interval = (i64)r->rax;      // (the interval in microseconds, computed just before the test)
    i64* counted = (i64*)(ui + 0xe38);
    if (interval > 0 && *counted >= interval) {
        _InterlockedIncrement(&g_gasSkipped);
        if (!g_gasLogged) {
            g_gasLogged = true;
            Buf b; b.str("game autosave: due after ").dec((long)(interval / 60000000)).str(" min, skipped in the session (the host's world is saved at a pause of every game)"); LogLine(b);
        }
    }
    *counted = 0;
}

// ---------------------------------------------------------------- (0.7.11, #152) the module builder's construction gone
// Pascal's game, 2026-11-08 17:48: a station open in the module editor (UI::ModuleBuilder) while janik's build was replayed
// there; the build removed the station, and the tool's next read stopped the game: "Assertion `m_entity.GetId() < 0 ||
// (EntityExists(m_entity) && HasComponent(m_entity, Construction))' failed" (ModuleBuilder.cpp:268). The tool keeps its
// construction at +0x118 and the game state at +0xc0 (the engine at [gs+0x18]); four of its functions read it, then ask the
// engine (EntityExists, HasComponent with the Construction type) and stop the game when it is gone. Those four reads are
// spliced: a construction that no longer exists, or whose id is now another entity's, is set to -1, the tool's own "no
// construction" state, which every one of those checks accepts (the player picks the station again). A construction that
// exists is left alone: nothing changes then. MPFEVER_MBGUARD=0: not hooked.
typedef bool (*MbExistsFn)(u64 engine, i32 id);
typedef bool (*MbHasFn)(u64 engine, i32 id, const void* typeIndex);
static MbExistsFn g_mbExists = 0;
static MbHasFn g_mbHas = 0;
static u64 g_mbConType = 0;            // the type_info of ecs::component::Construction, as the game passes it (a pointer to it)
static volatile long g_mbCleared = 0;
static void ModuleBuilderGuard(SavedRegs* r)
{
    u64 self = r->rcx;
    if (!g_mbExists || !g_mbHas || !self || !Readable((void*)(self + 0xc0), 8) || !Readable((void*)(self + 0x118), 4)) return;
    i32 id = *(i32*)(self + 0x118);
    if (id < 0) return;
    u64 gs = *(u64*)(self + 0xc0);
    if (!gs || !Readable((void*)(gs + 0x18), 8)) return;
    u64 eng = *(u64*)(gs + 0x18);
    if (!eng) return;
    if (g_mbExists(eng, id) && g_mbHas(eng, id, &g_mbConType)) return;
    *(i32*)(self + 0x118) = -1;
    long n = _InterlockedIncrement(&g_mbCleared);
    if (n <= 12) {
        Buf b; b.str("module builder: its construction ").dec((long)id).str(" is gone (another player's build removed or replaced it): the tool lets it go instead of the game stopping");
        LogLine(b);
    }
}

static void InstallModuleBuilderGuard()
{
    if (GetEnvironmentVariableA("MPFEVER_MBGUARD", 0, 0) > 0) {
        char v[4] = {};
        GetEnvironmentVariableA("MPFEVER_MBGUARD", v, 3);
        if (v[0] == '0') { Buf b; b.str("module builder guard: off (MPFEVER_MBGUARD=0)"); LogLine(b); return; }
    }
    // { signature, offset of the stolen read in it, stolen bytes }; each one's "call EntityExists" is its E8
    struct Site { const char* sig; int off; int steal; };
    static const Site sites[] = {
        { "4C 8B F1 8B 91 18 01 00 00 85 D2 78 ?? 48 8B 81 C0 00 00 00 48 8B 48 18 E8", 3, 6 },
        { "48 8D B9 18 01 00 00 8B 17 85 D2 78 ?? 48 8B 81 C0 00 00 00 48 8B 48 18 E8", 0, 7 },
        { "48 8B FA 48 8B D9 8B 91 18 01 00 00 85 D2 78 ?? 48 8B 81 C0 00 00 00 48 8B 48 18 E8", 6, 6 },
        { "8B 91 18 01 00 00 48 8D 99 C0 00 00 00 48 89 9C 24 80 00 00 00 85 D2 78 ?? 48 8B 03 48 8B 48 18 E8", 0, 6 },
    };
    static const int e8At[] = { 24, 24, 27, 32 };
    u32 at[4] = {};
    u64 exists = 0;
    const char* miss = 0;
    for (int i = 0; i < 4 && !miss; i++) {
        at[i] = FindSigRva(sites[i].sig);
        if (!at[i]) { miss = "a module builder site not found"; break; }
        const u8* call = (const u8*)(g_base + at[i] + e8At[i]);
        if (call[0] != 0xE8) { miss = "a module builder site is not the shape expected"; break; }
        u64 t = (u64)(call + 5 + *(const i32*)(call + 1));
        if (exists && t != exists) miss = "the module builder sites call different functions";
        exists = t;
    }
    // HasComponent and the Construction type, from the fourth site: "lea rax,[type]" at +0x34, "call HasComponent" at +0x51
    if (!miss) {
        const u8* p = (const u8*)(g_base + at[3]);
        if (p[0x34] != 0x48 || p[0x35] != 0x8D || p[0x36] != 0x05 || p[0x51] != 0xE8) miss = "HasComponent's call not found";
        else {
            g_mbConType = (u64)(p + 0x34 + 7 + *(const i32*)(p + 0x37));
            g_mbHas = (MbHasFn)(p + 0x51 + 5 + *(const i32*)(p + 0x52));
            g_mbExists = (MbExistsFn)exists;
            if ((u64)g_mbHas < g_textStart || (u64)g_mbHas >= g_textEnd || exists < g_textStart || exists >= g_textEnd) miss = "the engine's functions are outside the game's code";
        }
    }
    u8* mem = miss ? 0 : AllocNear(0x400);
    if (!miss && !mem) miss = "no memory near the game's code";
    int done = 0;
    for (int i = 0; i < 4 && !miss; i++) if (Splice(mem, at[i] + sites[i].off, sites[i].steal, ModuleBuilderGuard)) done++;
    Buf b;
    if (miss) b.str("module builder guard: OFF (").str(miss).str(")");
    else b.str("module builder guard: ").dec(done).str(" of 4 reads of its construction checked (a construction removed by another player's build is let go)");
    LogLine(b);
}

// (0.8.6, #150, see g_clearSame) inside ClearPositions, right after it found the account's component (rax; the player in ebx):
// the vector's begin and end are noted when the native module asked for this machine's figures to be kept (on its own thread)
static void ClearPosSeen(SavedRegs* r)
{
    long want = g_keepEnt;
    if (!want || (u32)r->rbx != (u32)want || (long)GetCurrentThreadId() != g_keepTid) return;
    u8* c = (u8*)r->rax;
    if (!c || !Readable(c, 0x20) || !c[0x18]) return;
    g_keepBegin = *(u64*)c;
    g_keepEnd = *(u64*)(c + 8);
    g_keepVec = c;
}

static void InstallClearSame()
{
    char v[4] = {};
    Buf b;
    if (GetEnvironmentVariableA("MPFEVER_CLEARSAME", v, 3) > 0 && v[0] == '0') {
        g_clearSame = 0; b.str("account changes: this machine's company kept out of the clear before the copy, as before 0.8.6 (MPFEVER_CLEARSAME=0)"); LogLine(b); return;
    }
    // ClearPositions as on 40425: "mov rdi,rax / mov [rsp+0x30],rax" at +0x8e (the component), then "cmp byte [rdi+0x18],0 / je /
    // mov rax,[rdi] / cmp rax,[rdi+8] / je / mov [rdi+8],rax" at +0xb2 (the clear moves the end to the begin, nothing else)
    static const u8 site[] = { 0x48, 0x8B, 0xF8, 0x48, 0x89, 0x44, 0x24, 0x30 };
    static const u8 clr[] = { 0x80, 0x7F, 0x18, 0x00, 0x74, 0x3D, 0x48, 0x8B, 0x07, 0x48, 0x3B, 0x47, 0x08, 0x74, 0x04, 0x48, 0x89, 0x47, 0x08 };
    u8* f = (u8*)g_clearPos;
    bool shape = f && Readable(f, 0xd8) && memcmp(f + 0x8e, site, sizeof(site)) == 0 && memcmp(f + 0xb2, clr, sizeof(clr)) == 0;
    u8* mem = shape ? AllocNear(0x100) : 0;
    bool ok = mem && Splice(mem, (u32)((u64)f + 0x8e - g_base), (int)sizeof(site), ClearPosSeen);
    g_clearSame = ok ? 1 : 0;
    if (ok) b.str("account changes: the same on every game (every company emptied in one order, this machine's figures put back), ClearPositions at ").hex((u64)f - g_base);
    else b.str("account changes: ClearPositions ").str(f ? (shape ? "not spliced" : "of another shape") : "not found").str(": this machine's company kept out of the clear, as before");
    LogLine(b);
}

// ---------------------------------------------------------------- the aircraft's cached figures (0.8.8, #150)
// The slow drift between different PCs with nobody building (#150, #255, #274, #284, the two-PC tests of 2026-11-11 and
// 2026-11-14 on "Test Leawood"): its first difference was always an aircraft. Measured on 2026-11-14 with the fine diagnostic,
// then read in the game's code:
//   - AircraftMoveSystem keeps, for each aircraft, figures it computes once (its mass with its load, its highest thrust, its top
//     speed): the entity2data entry made by the system's vfunc4 (0xa87730 on 40425). The highest thrust and the top speed fall
//     with the vehicle's maintenance state, by steps of a fifth (0x269bd40);
//   - that entry is made again only when the aircraft's Aircraft or MovePathAircraft component is said changed (vfunc8 erases it,
//     vfunc9 makes it), never when its maintenance state or its load changes;
//   - the engine keeps two world states and makes each batch of steps on the other one. A change of the Aircraft component (its
//     reservation moves on at every segment of the taxiway) makes the entry again at that step in the state that simulates, and
//     in the other state only when the batch is copied to it, from that state's own older figures (the change records are
//     replayed before the components are copied). The two states can hold another highest thrust for the same aircraft, one
//     maintenance step apart (0.95 and 0.90 of the model's, aircraft 279989 of the test), and a step's thrust depends on which
//     state makes it, that is on how the steps are cut into batches;
//   - the batches differ between two PCs: a game held by its stop points behind a slower one makes batches of one step where the
//     other makes four. The aircraft's speed parts by a few 1e-5 m/s, then its place, the animals near it, the ids, the people.
// Every aircraft's entry is now made again at the start of every step, in the state that makes the step (the system's own
// vfunc5 then vfunc4, the pair the engine runs for a change of the Aircraft component: the reservations are given back and
// taken again as they were): the figures are those of the step's own components on every game, whatever the batches.
// At the entry of AircraftMoveSystem::Update2 (rcx: the system, rdx: the engine, r8d: its aircraft, xmm3: the step's time);
// its entities are 16-byte entries {entity, index of its Aircraft, index of its MovePathAircraft} at [[system+8]].
// MPFEVER_AIRCACHE=0: as before (on every game of a session: a game with it and one without drift apart).
static u64 g_airUpdate = 0;            // AircraftMoveSystem::Update2 (address), found by its signature
static volatile long g_airSteps = 0, g_airMade = 0, g_airOdd = 0;
static void AirCacheRefresh(SavedRegs* r)
{
    u64 sys = r->rcx, engine = r->rdx;
    long n = (long)(i32)r->r8;
    if (!sys || !engine || n <= 0 || n > 65536 || !Readable((void*)sys, 0x10)) return;
    // (the system whose vfunc12 this is: its vfunc4 and vfunc5 are the ones called)
    u64 vt = *(u64*)sys;
    if (!vt || !Readable((void*)vt, 0x68) || *(u64*)(vt + 0x60) != g_airUpdate) { _InterlockedIncrement(&g_airOdd); return; }
    u64 vec = *(u64*)(sys + 8);
    if (!vec || !Readable((void*)vec, 8)) { _InterlockedIncrement(&g_airOdd); return; }
    u64 list = *(u64*)vec;
    if (!list || !Readable((void*)list, (u64)n * 16)) { _InterlockedIncrement(&g_airOdd); return; }
    typedef void (*EntityFn)(u64, u64, u32);
    EntityFn build = *(EntityFn*)(vt + 0x20), erase = *(EntityFn*)(vt + 0x28);
    // (the entities read first: nothing of the list is read while the entries are made)
    u32 small[256];
    u32* ids = n <= 256 ? small : (u32*)HeapAlloc(GetProcessHeap(), 0, (u64)n * 4);
    if (!ids) return;
    for (long i = 0; i < n; i++) ids[i] = *(u32*)(list + (u64)i * 16);
    for (long i = 0; i < n; i++) { erase(sys, engine, ids[i]); build(sys, engine, ids[i]); }
    if (ids != small) HeapFree(GetProcessHeap(), 0, ids);
    g_airMade += n;      // (the simulation's thread only)
    if (_InterlockedIncrement(&g_airSteps) == 1) {
        Buf b; b.str("aircraft figures: made again at every step, ").dec(n).str(" aircraft at the first one (thread ").dec((long)GetCurrentThreadId()).str(")"); LogLine(b);
    }
}
static void InstallAirCache()
{
    char v[4] = {};
    Buf b;
    if (GetEnvironmentVariableA("MPFEVER_AIRCACHE", v, 3) > 0 && v[0] == '0') { b.str("aircraft figures: kept between the changes of their components, as before 0.8.8 (MPFEVER_AIRCACHE=0)"); LogLine(b); return; }
    // AircraftMoveSystem::Update2 on 40425: "push rbx/rsi/rdi/r12/r13/r14/r15 / mov eax,0x1260 / call __chkstk / sub rsp,rax /
    // vmovaps [rsp+0x1250],xmm6"; the six bytes of its first four pushes are taken
    u32 at = FindSigRva("40 53 56 57 41 54 41 55 41 56 41 57 B8 60 12 00 00 E8 ?? ?? ?? ?? 48 2B E0 C5 F8 29 B4 24 50 12 00 00");
    u8* mem = at ? AllocNear(0x100) : 0;
    g_airUpdate = at ? g_base + at : 0;
    bool ok = mem && Splice(mem, at, 6, AirCacheRefresh);
    if (ok) b.str("aircraft figures: made again at every step (AircraftMoveSystem's update at ").hex(at).str("): the same on every game whatever its batches");
    else { g_airUpdate = 0; b.str("aircraft figures: AircraftMoveSystem's update NOT found: kept between the changes of their components, as before (a slow drift between PCs stays possible)"); }
    LogLine(b);
}

static void InstallNoGameAutosave()
{
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_GAMEAUTOSAVE", v, 3) > 0 && v[0] == '1') { Buf b; b.str("game autosave: kept in sessions (MPFEVER_GAMEAUTOSAVE=1)"); LogLine(b); return; }
    u32 at = FindSigRva("80 BE 70 11 00 00 00 75 ?? 48 3B 86 38 0E 00 00 7D ?? 48 8B CE E8");
    u8* mem = at ? AllocNear(0x100) : 0;
    bool ok = mem && Splice(mem, at, 7, GameAutosaveGate);
    Buf b;
    if (ok) b.str("game autosave: off in sessions (the test at ").hex(at).str(")");
    else b.str("game autosave: its test NOT found (the game still saves on its own in a session)");
    LogLine(b);
}

// ---------------------------------------------------------------- one industry-demand history (0.6, ported from TPF3-MP, MIT)
// Ported from TPF3-MP's "Shared industry-demand history" (pull request #192 of Juliansgith/Transport-Fever-3-Multiplayer-Mod,
// "Stabilize industry spawning and reloads", 2026-10-29: docs/HOOKS.md, crates/tpf3mp-hook/src/industry_shared.rs, signature
// of profiles/tf3_build40425_steam_windows/hooks.toml "industry schedule"). The engine keeps two game states and runs each
// batch of steps on the other one: CGame::Sync hands the state just simulated to the interface and flips them, and the
// simulation loop copies the world into the next one (GameState::Replicate) before its batch. The industries' demand
// scheduler, a lambda that the setup of each game state's industries subscribes to the game time's interval step (every 12 s
// of game time, 60 steps), compares the towns' and the world's demand with what it saw last and gives five spawn attempts to
// every change; one attempt is spent at each interval while some are due. What it saw and the attempts due are its
// IndustryChainSpawnState, one per game state and not part of the world (never copied): a change was counted once in each
// state, and the attempts came out of the state whose batch the interval fell in. Which one that is follows how a game's
// batches were cut (a stop point's stands, pauses, saves, the speed: 60 steps make 15 batches at 4x), different on every game
// of a session: new industries came at other steps, or on one game only (TPF3-MP's two games read 3 and 4 attempts due at
// one interval, then resynchronised). Every active call is now given one history for the world (industry_demand.h): the
// first active call's own, kept by one more reference until the next world. The game's code still compares the demand,
// spends the attempts and places the industries. The histories of a world are known from its setup (right after their
// make_shared), so a history made for anything else is left alone, and the one kept is let go as the game's shared_ptr would.
// With one history a demand change gives five attempts, as on a game whose intervals all fall on one state (the game alone
// gives five to ten, by how its batches fell). The layout is read in the code before anything is patched: the captures'
// history at +0x20 and its control block at +0x28, the attempts at +0x68, the engine's flag at +0x1f8, the make_shared of
// 0x80 bytes with its vtable, the std::function that calls the scheduler with the captures at +8. Another game build: off,
// as in 0.5.14. MPFEVER_INDUSTRYDEMAND=0 on every game: as before. MPFEVER_INDUSTRYLOG=1 (diagnostic): each active call in
// native.log, "industry demand: t=<game time> due <before> -> <after>", the same lines on every game when in step.
static bool IdReadable(const void* p, u64 n) { return Readable(p, n); }
#include "industry_demand.h"
static IndDemand g_ind;
typedef u64 (*IndSchedF)(u64, u64);
static IndSchedF g_indSchedOrig = 0;
static bool g_indLog = false;

// the setup of a game state's industries, right after the history's make_shared: rcx is its control block (0 if none)
static void IndMade(SavedRegs* r) { IdMade(&g_ind, r->rcx); }

// the scheduler (the lambda's operator(): rcx its captures, rdx the interval's game time)
static u64 IndSchedule(u64 cap, u64 time)
{
    u64 copy[6];
    int active = 0;
    long kept = g_ind.kept_n, refused = g_ind.refused;
    u64 use = IdPick(&g_ind, cap, copy, &active);
    if (g_ind.kept_n != kept && g_ind.kept_n <= 20) {
        Buf b; b.str("industry demand: the world's history kept (control block ").hex(g_ind.kept).str(", ").dec(g_ind.madeN)
            .str(" made since the start, ").dec(g_ind.released).str(" let go), game time ").dec((i64)time);
        LogLine(b);
    }
    if (g_ind.refused != refused && refused == 0) {
        Buf b; b.str("industry demand: REFUSED (").str(g_ind.why ? g_ind.why : "?").str("), the game's two histories from now on"); LogLine(b);
    }
    if (!g_indLog) return g_indSchedOrig(use, time);
    if (!active && !g_ind.on) { const char* why = ""; active = IdFlag(cap, &why) == 1; }
    u64 st = active ? ((const u64*)use)[4] : 0;
    bool rd = st && Readable((void*)(st + 0x68), 4);
    long before = rd ? *(volatile long*)(st + 0x68) : -1;
    u64 r = g_indSchedOrig(use, time);
    if (active) {
        long after = rd ? *(volatile long*)(st + 0x68) : -1;
        Buf b; b.str("industry demand: t=").dec((i64)time).str(" due ").dec(before).str(" -> ").dec(after); LogLine(b);
    }
    return r;
}

static void InstallIndustryDemand()
{
    char v[4] = {};
    bool off = GetEnvironmentVariableA("MPFEVER_INDUSTRYDEMAND", v, 3) > 0 && v[0] == '0';
    v[0] = 0;
    g_indLog = GetEnvironmentVariableA("MPFEVER_INDUSTRYLOG", v, 3) > 0 && v[0] == '1';
    if (off && !g_indLog) { Buf b; b.str("industry demand: the game's two histories (MPFEVER_INDUSTRYDEMAND=0)"); LogLine(b); return; }
    // (TPF3-MP's signature of the scheduler, build 40425; the setup's from its prologue and first loads)
    u32 sched = FindSigRva("48 89 5C 24 10 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 10 FE FF FF 48 81 EC F0 02 00 00 4C 8B F9 4C 8B 41 08 49 8B 40 18 80 B8 F8 01 00 00 00");
    u32 setup = FindSigRva("40 55 53 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 98 FD FF FF 48 81 EC 68 03 00 00 49 8B F9 4D 8B F0 48 8B F2 4C 8B E9 4C 8B 61 10");
    const char* miss = !sched ? "the scheduler not found" : (!setup && !off ? "the industries' setup not found" : 0);
    u64 vt = 0, ivt = 0;
    if (!miss) {
        // the scheduler: the history's address from the captures' +0x20 (lea rsi,[r15+20h]), its attempts at +0x68 (cmp, dec, add 5)
        const u8* s = (const u8*)(g_base + sched);
        static const u8 hist[] = { 0x49, 0x8D, 0x77, 0x20 };
        static const u8 cmp68[] = { 0x44, 0x39, 0x60, 0x68 };
        static const u8 dec68[] = { 0x48, 0x8B, 0x06, 0xFF, 0x48, 0x68 };
        static const u8 add5[] = { 0x48, 0x8B, 0x06, 0x83, 0x40, 0x68, 0x05 };
        if (memcmp(s + 0xc1, hist, 4) || memcmp(s + 0xdc, cmp68, 4) || memcmp(s + 0x1f1, dec68, 6) || memcmp(s + 0x44d, add5, 7)) miss = "the scheduler's layout differs";
    }
    if (!miss && !off) {
        // the setup: make_shared of 0x80 bytes (counts 1 and 1, then the control block's vtable), the history at the block's
        // +0x10 and the block stored as the captures' last two words, the lambda's std::function vtable, the six captures
        // copied to its +8 (four, then the history and its block at +0x28)
        const u8* m = (const u8*)(g_base + setup);
        static const u8 alloc80[] = { 0xB9, 0x80, 0x00, 0x00, 0x00, 0xE8 };
        static const u8 counts[] = { 0xC7, 0x40, 0x08, 0x01, 0x00, 0x00, 0x00, 0xC7, 0x40, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x48, 0x8D, 0x05 };
        static const u8 store[] = { 0x48, 0x8D, 0x41, 0x10, 0x48, 0x89, 0x45, 0x88, 0x48, 0x89, 0x4D, 0x90, 0x48, 0x8D, 0x05 };
        static const u8 impl[] = { 0x48, 0x89, 0x45, 0x58, 0xC5, 0xFC, 0x10, 0x44, 0x24, 0x68, 0xC5, 0xFC, 0x11, 0x45, 0x60, 0xC5, 0xFA, 0x6F, 0x45, 0x88,
            0xC5, 0xFA, 0x7F, 0x85, 0x80, 0x00, 0x00, 0x00 };
        if (memcmp(m + 0x7aa, alloc80, 6) || memcmp(m + 0x7cb, counts, 17) || memcmp(m + 0x81e, store, 15) || memcmp(m + 0x831, impl, 28)) miss = "the setup's layout differs";
        else {
            vt = (u64)(m + 0x7d9 + 7 + *(const i32*)(m + 0x7dc));
            ivt = (u64)(m + 0x82a + 7 + *(const i32*)(m + 0x82d));
            // (the vtables read only inside the game's image, their functions inside its code: the block's _Destroy and
            // _Delete_this, and the std::function's call, "mov rdx,[rdx] / add rcx,8 / jmp scheduler")
            bool in = vt > g_textEnd && vt - g_base < 0x8000000 && ivt > g_textEnd && ivt - g_base < 0x8000000 && Readable((void*)vt, 16) && Readable((void*)ivt, 24);
            u64 d0 = in ? ((u64*)vt)[0] : 0, d1 = in ? ((u64*)vt)[1] : 0, call = in ? ((u64*)ivt)[2] : 0;
            static const u8 thunk[] = { 0x48, 0x8B, 0x12, 0x48, 0x83, 0xC1, 0x08, 0xE9 };
            in = in && d0 >= g_textStart && d0 < g_textEnd && d1 >= g_textStart && d1 < g_textEnd && call >= g_textStart && call + 12 <= g_textEnd
                && memcmp((void*)call, thunk, 8) == 0 && call + 12 + *(const i32*)(call + 8) == g_base + sched;
            if (!in) miss = "the history's vtable or the scheduler's std::function differs";
            else { g_ind.vtable = vt; g_ind.destroy = d0; g_ind.del = d1; }
        }
    }
    u8* mem = miss ? 0 : AllocNear(0x400);
    if (!miss && !mem) miss = "no memory near the game's code";
    // (the setup first: a scheduler hooked without it would find no history of the world and change nothing)
    if (!miss && !off && !Splice(mem, setup + 0x822, 8, IndMade)) miss = "the setup not hooked";
    static const u8 pro[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57 };
    void* t = miss ? 0 : DetourWhole(mem, sched, pro, (int)sizeof(pro), (void*)IndSchedule);
    if (!miss && !t) miss = "the scheduler not hooked";
    Buf b;
    if (miss) { b.str("industry demand: OFF (").str(miss).str("), the game's two histories"); LogLine(b); return; }
    g_indSchedOrig = (IndSchedF)t;
    g_ind.on = off ? 0 : 1;
    if (off) b.str("industry demand: the game's two histories (MPFEVER_INDUSTRYDEMAND=0), each active call logged (MPFEVER_INDUSTRYLOG)");
    else b.str("industry demand (from TPF3-MP): one history for the two game states, scheduler at ").hex(sched).str(", histories made at ").hex(setup + 0x822)
        .str(g_indLog ? ", each active call logged (MPFEVER_INDUSTRYLOG)" : "");
    LogLine(b);
}

// ---------------------------------------------------------------- the platform-decision flag (0.6.8, after TPF3-MP)
// After TPF3-MP's "The platform-decision flag" (Juliansgith/Transport-Fever-3-Multiplayer-Mod, MIT: docs/HOOKS.md, branch
// fix/decision-flag-desync of 2026-10-01; the idea only, made again here for build 40425). ecs::TransportVehicleSystem::Update2
// asks FindNextFreeTerminal for an en-route land vehicle only while byte +0x70 of its MovePath is set (40425: the read at
// 0xb91843, right after the call of MovePath's getter 0x52be40 with the engine and the vehicle). The engine keeps two game
// states and runs each iteration on the other one; the simulation loop copies the state just simulated into the next
// (GameState::Replicate), but that byte does not come across: a vehicle's flag is set and cleared in the state that ran the
// step where it changed, and the other state reads its old value until it writes its own. Which state runs a given step
// follows how each game's batches were cut, so a bus asked for a platform on one game and drove on on the other, with no
// action (TPF3-MP's save split at step 3300 on every run, and not with the copy). Right after the loop's Replicate(source,
// destination), each transport vehicle's flag is copied from the source's MovePath into the destination's where they differ:
// the state about to run holds what the last step left, whichever state ran it. The vehicles are the system's node list
// ({entity, index} records at [[system+8]], as many as the loop's count at [rbp+0x5b0]), taken at the decision read once per
// iteration on the simulation thread. Each MovePath comes from the game's own getter, checked to be the call before the read
// and to name MovePath's type descriptor, called only for an entity inside the engine's per-entity table (+0xc0, 16 bytes
// each: the getter does not check). The engine the system is given must be the game state's +0x18 (else nothing is copied).
// When Replicate copies the byte itself (another build), nothing differs and nothing is written. MPFEVER_DECISIONSYNC=1 on
// every game: the copy (off by default since 0.6.8, see InstallDecisionSync). The counters are in the "order fixes:" line, "decision flags
// <copies>/<flags copied>/<lists taken>/<refused>/<reads off the simulation thread>".
#include "decision_flags.h"
static MovePathF g_dsGet = 0;
static bool g_dsOn = false;
static i32* g_dsEnt = 0;
static u64 g_dsN = 0, g_dsCap = 0;
static long g_dsIter = -1;
static volatile long g_dsSyncs = 0, g_dsCopied = 0, g_dsNotes = 0, g_dsRefused = 0, g_dsOther = 0;

// the decision read (r13 the system, rbp the loop's frame, [rsp+0x70] the engine): the vehicles, once per iteration
static void DecisionNote(SavedRegs* r)
{
    if (!g_dsOn) return;
    if (GetCurrentThreadId() != (DWORD)g_simTid) { _InterlockedIncrement(&g_dsOther); return; }
    if (g_dsIter == g_iter) return;
    g_dsIter = g_iter;
    u64 sp = OrigRsp(r), sys = r->r13;
    u8* gs = (u8*)g_slot;
    if (!gs || !Readable(gs + 0x18, 8) || !Readable((void*)(sp + 0x70), 8) || !Readable((void*)(r->rbp + 0x5b0), 4) || !Readable((void*)(sys + 8), 8)) { _InterlockedIncrement(&g_dsRefused); return; }
    if (*(u64*)(sp + 0x70) != *(u64*)(gs + 0x18)) {
        if (_InterlockedIncrement(&g_dsRefused) == 1) { Buf b; b.str("decision flags: the system's engine ").hex(*(u64*)(sp + 0x70)).str(" is not the game state's ").hex(*(u64*)(gs + 0x18)).str(": not copied"); LogLine(b); }
        return;
    }
    u64 holder = *(u64*)(sys + 8);
    if (!holder || !Readable((void*)holder, 16)) { _InterlockedIncrement(&g_dsRefused); return; }
    u64 b = *(u64*)holder, e = *(u64*)(holder + 8);
    i32 cnt = *(i32*)(r->rbp + 0x5b0);
    if (e < b || ((e - b) & 7) || cnt < 0 || cnt > (1 << 20) || (u64)cnt != (e - b) / 8 || (cnt && !Readable((void*)b, e - b))) { _InterlockedIncrement(&g_dsRefused); return; }
    u64 n = (u64)cnt;
    if (n > g_dsCap) {
        u64 cap = n + n / 2 + 64;
        i32* p = (i32*)HeapAlloc(GetProcessHeap(), 0, cap * 4);
        if (!p) { _InterlockedIncrement(&g_dsRefused); return; }
        if (g_dsEnt) HeapFree(GetProcessHeap(), 0, g_dsEnt);
        g_dsEnt = p; g_dsCap = cap;
    }
    for (u64 i = 0; i < n; i++) g_dsEnt[i] = (i32)(u32)((const u64*)b)[i];
    g_dsN = n;
    _InterlockedIncrement(&g_dsNotes);
}

// right after the simulation loop's Replicate(source, destination): the flags of the source's vehicles into the destination's
static void DecisionCopy(void* src, void* dst)
{
    if (!g_dsOn || !src || !dst || src == dst || !g_dsN) return;
    if (GetCurrentThreadId() != (DWORD)g_simTid) return;
    if (!Readable((u8*)src + 0x18, 8) || !Readable((u8*)dst + 0x18, 8)) { _InterlockedIncrement(&g_dsRefused); return; }
    u64 a = *(u64*)((u8*)src + 0x18), z = *(u64*)((u8*)dst + 0x18);
    if (!a || !z || a == z || !Readable((void*)(a + 0xc0), 16) || !Readable((void*)(z + 0xc0), 16)) { _InterlockedIncrement(&g_dsRefused); return; }
    long copied = DsCopyFlags(a, z, g_dsEnt, g_dsN, g_dsGet);
    _InterlockedIncrement(&g_dsSyncs);
    long before = g_dsCopied;     // (the simulation thread alone writes it)
    g_dsCopied = before + copied;
    if (copied && before == 0) {
        Buf b; b.str("decision flags: first copy, ").dec(copied).str(" of ").dec((long)g_dsN).str(" vehicles' flags differed between the two game states (iteration ").dec(g_iter).str(")");
        LogLine(b);
    }
}

static void InstallDecisionSync()
{
    char v[4] = {};
    // (0.6.8: off unless asked: on build 40425 the engine's Replicate copies the byte itself, 0 differences in every test; kept
    // for a game build where it does not. MPFEVER_DECISIONSYNC=1 on every game: on)
    if (!(GetEnvironmentVariableA("MPFEVER_DECISIONSYNC", v, 3) > 0 && v[0] == '1')) { Buf b; b.str("decision flags: each game state keeps its own (MPFEVER_DECISIONSYNC=1 copies them)"); LogLine(b); return; }
    const char* miss = (!g_replOn || !RVA_REPL_LOOP) ? "the simulation loop's Replicate not hooked" : (!g_preIterOn ? "the iterations not hooked" : 0);
    // the read, "movzx eax, byte [rax+70h] / test al,al / jmp", after "mov rcx,[rsp+70h] / je / call getter / test rax,rax / je"
    u32 at = miss ? 0 : FindSigRva("48 8B 4C 24 70 74 ?? E8 ?? ?? ?? ?? 48 85 C0 0F 84 ?? ?? ?? ?? 0F B6 40 70 84 C0 EB ?? E8");
    if (!miss && !at) miss = "the decision read not found";
    u64 getter = 0;
    if (!miss) {
        const u8* call = (const u8*)(g_base + at + 7);
        getter = (u64)(call + 5 + *(const i32*)(call + 1));
        // the getter: "mov [rsp+10h],rbx / mov [rsp+18h],rsi / push rdi / sub rsp,30h / movsxd rbx,edx / lea rax,[type descriptor]"
        static const u8 head[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x30, 0x48, 0x63, 0xDA, 0x48, 0x8D, 0x05 };
        static const char name[] = ".?AUMovePath@component@ecs@@";
        if (getter < g_textStart || getter + 32 > g_textEnd || memcmp((void*)getter, head, sizeof(head)) != 0) miss = "the MovePath getter is not the shape expected";
        else {
            u64 desc = getter + sizeof(head) + 4 + *(const i32*)(getter + sizeof(head));
            if (!Readable((void*)(desc + 0x10), sizeof(name)) || memcmp((void*)(desc + 0x10), name, sizeof(name)) != 0) miss = "the getter is not MovePath's";
        }
    }
    u8* mem = miss ? 0 : AllocNear(0x100);
    if (!miss && !mem) miss = "no memory near the game's code";
    // (the movzx and the test stolen: the short jmp after them stays where it is)
    if (!miss && !Splice(mem, at + 21, 6, DecisionNote)) miss = "the decision read not hooked";
    Buf b;
    if (miss) { b.str("decision flags: OFF (").str(miss).str("), each game state keeps its own"); LogLine(b); return; }
    g_dsGet = (MovePathF)getter;
    g_dsOn = true;
    b.str("decision flags (after TPF3-MP): each vehicle's platform-decision flag copied after the simulation loop's Replicate, read at ").hex(at + 21)
        .str(", MovePath's getter at ").hex((u32)(getter - g_base));
    LogLine(b);
}

// ---------------------------------------------------------------- fresh ids for the commands' new entities (0.6.8)
// ecs::Engine::AddEntity (40425: 0x2bc0260) gives a new entity the head of the engine's free-id queue (the std::deque<int> at
// +0xd8, kept in id order by "free id queue" above) and, while the queue is empty, the count of entities the engine ever had
// (+0x90, 24 bytes each). The ids join the queue when a modification ends (Engine::EndModification 0x2bc8a50 -> 0x2bc17c0,
// site 0 above). Two games of a session sometimes have, for some 50 to 150 steps, one other id in their queue (same size, same
// head otherwise: 11 of 981 windows in the 0.6.4.1 reports): an entity of the simulation, a person or a piece of cargo, freed a
// few steps apart. A command applied in that window took another id on each game (a vehicle bought: 84704 on the host, 62904 on
// the client, 2026-11-01 23:54; the ids of the 37 other results of that session alike), and the games parted from there: the
// order fixes sort the vehicles by id, the towns followed. The commands of the simulation loop (the native builds), applied at
// the same step on every game, now make their entities with a fresh id, the count, whatever the queue holds: the queue's
// size at AddEntity's test (r8, "mov r8,[rdi+0F8h]" just before) is read as 0 for them. Every game makes the same commands at
// the same step, with the same count, so their entities get the same ids. The other entities (the simulation's own) still
// take the queue's ids, and an id freed by a command goes back to the queue as before. A copy of a state (Engine::Replicate
// replays the source's records, 0x2bc0ee0, and checks every id it gets again: "cmp [rsp+50h],[rbx+4]") passes the queue over
// in the same way when the id recorded is its count (fresh_ids.h). The commands the simulation's scripts send (MPFever's actions:
// the bridge applies the players' purchases and lines with sendCommand from the simulation's game script, which CGame's
// scripts' sink applies at once, Apply returning to 0x120514 on 40425) are NOT given fresh ids: given them (0.6.8 test build
// dist068c), the other state's replay took other ids and the engine stopped both games ("entity == c.entity",
// ecs::Replicator::Apply, Engine.cpp:138); their entities are counted and the first ones logged ("script command entity: ...").
// The other commands applied at once (CGame's own sink, or another thread: a preview of this machine's tools) are left alone;
// where each command came from is counted. A loaded game starts from the save's count and queue on every game (a resynchronisation reloads the
// host too). MPFEVER_FRESHIDS=0 on every game: the queue's ids for the commands too, as before. Counters in the "order fixes:"
// line, "fresh ids <loop's commands' entities>/<copies>/<refused>, script entities <n>" and "applied <loop>
// <scripts> <CGame's sink> <other>", each "<on the simulation thread>/<on another>"; the first few in native.log.
#include "fresh_ids.h"
static bool g_freshOn = false;
static volatile long g_freshReplayTid = 0;
static volatile long g_freshCmd = 0, g_freshReplay = 0, g_freshOther = 0, g_freshScript = 0, g_freshSkip = 0;
static u32 g_freshSite[2] = { 0xFFFFFFFFu, 0xFFFFFFFFu };   // AddEntity's returns in CustomEntityCreate and LineCreate
// (0.7.7) A vehicle bought (or replaced at a depot) is not made by its command: the vehicles' system makes it at a later step,
// outside any command (the user's server and PC, 2026-11-07 23:41, an AI truck: 118852 on one game, 111350 on the other;
// MPFEVER_ENTLOG of a purchase, 2026-11-08: "-79058" freed by another system in that step, then "+79058" the vehicle, the head of
// the queue). Its id was the queue's head at that moment, which two games had different for a few steps: the order fixes then
// sorted the vehicles otherwise and the towns followed. It gets a fresh id too. The chain on 40425: AddEntity returning to
// 26a8250 (a wrapper at 26a8000), called from 26a8850 (26a8480), called from 9deb11 (the vehicles' system); found by
// signature. Only on the simulated state's engine, on the simulation thread. MPFEVER_FRESHBUY=0: the queue's id, as before.
static u32 g_buySite[3] = { 0, 0, 0 };
static bool g_freshBuy = false;
static volatile long g_freshBuyN = 0;
static void InstallFreshBuy();

// the callers' return addresses g_buySite[1] then g_buySite[2] above sp (AddEntity's own return checked by the caller)
static bool BuyChain(u64 sp)
{
    const u64 a = g_base + g_buySite[1], b = g_base + g_buySite[2];
    if (!Readable((void*)sp, 0x800)) return false;
    const u64* q = (const u64*)sp;
    int i = 0;
    for (; i < 0x100; i++) if (q[i] == a) break;
    if (i >= 0x100) return false;
    for (int j = i + 1; j < 0x100; j++) if (q[j] == b) return true;
    return false;
}

// Engine::Replicate's replay of an "entity added" record (rdi the copy's engine, rbx the record: the id at +4)
static void FreshReplay(SavedRegs* r)
{
    if (!g_freshOn) return;
    // (no Readable here, once per entity a copy makes: the game reads the record and the engine right after)
    if (FiReplayFresh((const u8*)r->rdi, *(i32*)(r->rbx + 4))) g_freshReplayTid = (long)GetCurrentThreadId();
}

// AddEntity's test of the queue's size (rdi the engine, r8 the size): 0 for a command's entity, or a copy's fresh one
static void FreshAdd(SavedRegs* r)
{
    if (!g_freshOn) return;
    long tid = (long)GetCurrentThreadId();
    if (g_freshReplayTid == tid) {
        g_freshReplayTid = 0;
        if (r->r8) { r->r8 = 0; _InterlockedIncrement(&g_freshReplay); }
        return;
    }
    // (0.7.7) a vehicle bought, made by the vehicles' system (see g_buySite)
    if (g_freshBuy && r->r8 && tid == g_simTid) {
        u64 sp = OrigRsp(r);
        u64 ret0 = *(u64*)(sp + 0x58);
        if (g_addCallerTid == tid && (ret0 < g_textStart || ret0 >= g_textEnd)) ret0 = g_base + g_addCaller;
        if (ret0 == g_base + g_buySite[0] && BuyChain(sp + 0x60)) {
            u8* gs = (u8*)g_slot;
            if (gs && Readable(gs + 0x18, 8) && *(u64*)(gs + 0x18) == r->rdi) {
                long n = _InterlockedIncrement(&g_freshBuyN);
                if (n <= 12) {
                    Buf b; b.str("fresh id: a vehicle bought gets ").dec((long)FiCount((const u8*)r->rdi)).str(" (")
                        .dec((long)r->r8).str(" waiting in the queue) at step ").dec((long)StepOf(gs));
                    LogLine(b);
                }
                r->r8 = 0;
                return;
            }
        }
    }
    if (g_scriptTid == tid && g_cmdTid != tid) {
        // (a script's command: its entities keep the queue's ids, counted; the first ones in native.log, with whether the state
        // it is applied on is the one the simulation runs)
        long k = _InterlockedIncrement(&g_freshScript);
        if (k <= 16) {
            u8* as = ApplyingState();
            Buf b; b.str("script command entity: AddEntity on ").str(as && Readable(as + 0x18, 8) && *(u64*)(as + 0x18) == r->rdi ? "its state's engine" : "another engine")
                .str(", the state ").str(as == (u8*)g_slot ? "the simulation's" : "NOT the simulation's").str(", count ").dec((long)FiCount((const u8*)r->rdi))
                .str(", ").dec((long)r->r8).str(" waiting, step ").dec((long)StepOf(as ? as : (u8*)g_slot));
            LogLine(b);
        }
        return;
    }
    if (g_cmdTid != tid || !r->r8) return;
    // (the entity the command makes itself, AddEntity called from the command's code: a vehicle (CustomEntityCreate) or a line
    // (LineCreate); the return address is above AddEntity's three pushes and its 0x40 bytes. The entities the engine's systems
    // make for it meanwhile (the octree's nodes, the vehicle's parts, through the generic wrapper) keep the queue's ids: a copy of
    // the state makes those itself again, not from the records, with the queue's head (test x2 of 2026-11-02: a command that
    // gave them fresh ids left the copy one entity short, then "entity == c.entity")
    u32 ret = (u32)(*(u64*)(OrigRsp(r) + 0x58) - g_base);
    // (called through the entity watch's detour, MPFEVER_ENTWATCH: its caller)
    if (g_addCallerTid == tid && (*(u64*)(OrigRsp(r) + 0x58) < g_textStart || *(u64*)(OrigRsp(r) + 0x58) >= g_textEnd)) ret = g_addCaller;
    if (ret != g_freshSite[0] && ret != g_freshSite[1]) { _InterlockedIncrement(&g_freshSkip); return; }
    u8* gs = ApplyingState();
    if (!gs || !Readable(gs + 0x18, 8) || *(u64*)(gs + 0x18) != r->rdi) { _InterlockedIncrement(&g_freshOther); return; }
    long n = _InterlockedIncrement(&g_freshCmd);
    if (n <= 12) {
        const u8* eng = (const u8*)r->rdi;
        u64 map = *(const u64*)(eng + 0xe0), ms = *(const u64*)(eng + 0xe8), off = *(const u64*)(eng + 0xf0);
        i32 head = -1;
        if (map && ms && !(ms & (ms - 1)) && Readable((void*)map, ms * 8)) {
            i32* blk = *(i32**)(map + ((off >> 2) & (ms - 1)) * 8);
            if (blk && Readable(blk, 16)) head = blk[off & 3];
        }
        Buf b; b.str("fresh id: a command's new entity gets ").dec((long)FiCount(eng)).str(" (the queue's head ").dec(head).str(", ").dec((long)r->r8)
            .str(" waiting) at step ").dec((long)StepOf(gs));
        LogLine(b);
    }
    r->r8 = 0;
}

static void InstallFreshIds()
{
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_FRESHIDS", v, 3) > 0 && v[0] == '0') { Buf b; b.str("fresh ids: the commands' entities take the queue's ids (MPFEVER_FRESHIDS=0)"); LogLine(b); return; }
    const char* miss = !RVA_ADDENTITY ? "AddEntity not found" : (g_applyTls == 0xFFFFFFFFu ? "the applying state unknown (no order fixes)" : 0);
    u32 rep = 0;
    if (!miss) {
        // AddEntity: "mov rdi,rcx" (+0x1b), "mov r8,[rdi+0F8h] / xor ebx,ebx / test r8,r8 / jne" (+0x4e), "lea r10,[rdi+90h]" (+0x60)
        const u8* ae = (const u8*)(g_base + RVA_ADDENTITY);
        static const u8 mov[] = { 0x48, 0x8B, 0xF9 };
        static const u8 test[] = { 0x4C, 0x8B, 0x87, 0xF8, 0x00, 0x00, 0x00, 0x33, 0xDB, 0x4D, 0x85, 0xC0, 0x0F, 0x85 };
        static const u8 lea[] = { 0x4C, 0x8D, 0x97, 0x90, 0x00, 0x00, 0x00 };
        if (memcmp(ae + 0x1b, mov, 3) || memcmp(ae + 0x4e, test, sizeof(test)) || memcmp(ae + 0x60, lea, sizeof(lea))) miss = "AddEntity's layout differs";
    }
    if (!miss) {
        // the replay: "lea rdx,[rsp+50h] / mov rcx,rdi / call AddEntity / mov eax,[rbx+4] / cmp [rsp+50h],eax / jne"
        rep = FindSigRva("48 8D 54 24 50 48 8B CF E8 ?? ?? ?? ?? 8B 43 04 39 44 24 50 0F 85");
        if (!rep) miss = "the copy's replay not found";
        else {
            const u8* c = (const u8*)(g_base + rep + 8);
            if ((u64)(c + 5 + *(const i32*)(c + 1)) != g_base + RVA_ADDENTITY) miss = "the copy's replay calls another function";
        }
    }
    if (!miss) {
        // the commands the scripts send (lua::State's sendCommand, a lambda of CGame's constructor): with no list of the thread to
        // put them in, applied at once on the game's current state, "mov rax,[rbp+8] / mov rcx,[rax+1F0h] / movsxd rax,[rcx+98h] /
        // mov rdx,rbx / mov rcx,[rcx+rax*8+78h] / call Apply / mov rcx,[rsi+38h]"; CGame's own sink, the same with other registers
        // (counted only). The return of the scripts' call, and the list test before it (the thread's list at gs:[58h] +10h)
        u32 sc = FindSigRva("48 8B 45 08 48 8B 88 F0 01 00 00 48 63 81 98 00 00 00 48 8B D3 48 8B 4C C1 78 E8 ?? ?? ?? ?? 48 8B 4E 38");
        u32 sk = FindSigRva("48 8B 4B 08 48 8B 91 F0 01 00 00 48 63 8A 98 00 00 00 48 8B 4C CA 78 48 8B D0 E8 ?? ?? ?? ?? 48 8B 4F 38");
        static const u8 tls[] = { 0x65, 0x48, 0x8B, 0x0C, 0x25, 0x58, 0x00, 0x00, 0x00, 0xBF, 0x10, 0x00, 0x00, 0x00 };
        const u8* c = sc ? (const u8*)(g_base + sc + 26) : 0;
        // (counted only: not found, they count as "other")
        if (sc && (u64)(c + 5 + *(const i32*)(c + 1)) == g_base + RVA_APPLY && memcmp((void*)(g_base + sc - 0x47), tls, sizeof(tls)) == 0)
            RVA_SCRIPT_APPLY_RET = sc + 31;
        const u8* k = sk ? (const u8*)(g_base + sk + 26) : 0;
        if (k && (u64)(k + 5 + *(const i32*)(k + 1)) == g_base + RVA_APPLY) RVA_SINK_APPLY_RET = sk + 31;
    }
    if (!miss) {
        // the commands' own AddEntity calls: CustomEntityCreate's (a vehicle bought) "mov [rsp+30h],rbx / lea rdx,[rsp+38h] /
        // mov rcx,rbx / call AddEntity / mov ebx,[rsp+38h]", LineCreate's "mov [rbp-39h],rbx / lea rdx,[rbp-31h] / mov rcx,rbx /
        // call AddEntity / mov ebx,[rbp-31h]"
        u32 v = FindSigRva("48 89 5C 24 30 48 8D 54 24 38 48 8B CB E8 ?? ?? ?? ?? 8B 5C 24 38 89 5C 24");
        u32 l = FindSigRva("48 89 5D C7 48 8D 55 CF 48 8B CB E8 ?? ?? ?? ?? 8B 5D CF 4D 8D 47 28");
        const u8* cv = v ? (const u8*)(g_base + v + 13) : 0;
        const u8* cl = l ? (const u8*)(g_base + l + 11) : 0;
        if (!cv || !cl || (u64)(cv + 5 + *(const i32*)(cv + 1)) != g_base + RVA_ADDENTITY || (u64)(cl + 5 + *(const i32*)(cl + 1)) != g_base + RVA_ADDENTITY)
            miss = "the vehicles' and lines' AddEntity calls not found";
        else { g_freshSite[0] = v + 18; g_freshSite[1] = l + 16; }
    }
    u8* mem = miss ? 0 : AllocNear(0x200);
    if (!miss && !mem) miss = "no memory near the game's code";
    // (the replay first: an AddEntity hooked without it would give a copy other ids than its source, which the engine refuses)
    if (!miss && !Splice(mem, rep, 8, FreshReplay)) miss = "the copy's replay not hooked";
    if (!miss && !Splice(mem, RVA_ADDENTITY + 0x55, 5, FreshAdd)) miss = "AddEntity not hooked";
    Buf b;
    if (miss) { b.str("fresh ids: OFF (").str(miss).str("), the commands' entities take the queue's ids"); LogLine(b); return; }
    g_freshOn = true;
    b.str("fresh ids: the vehicles and lines that commands make (AddEntity returning to ").hex(g_freshSite[0]).str(" or ").hex(g_freshSite[1])
        .str(", the loop's commands and the scripts', Apply returning to ").hex(RVA_SCRIPT_APPLY_RET).str(") get fresh ids, AddEntity at ").hex(RVA_ADDENTITY)
        .str(", the copy's replay at ").hex(rep);
    LogLine(b);
    InstallFreshBuy();
}

// (0.7.7) the vehicles bought: the three calls of their chain, each found once and checked (see g_buySite)
static void InstallFreshBuy()
{
    Buf b;
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_FRESHBUY", v, 3) > 0 && v[0] == '0') { b.str("fresh ids: the vehicles bought take the queue's ids (MPFEVER_FRESHBUY=0)"); LogLine(b); return; }
    // the wrapper's AddEntity call "lea rdx,[rsp+40h] / mov rcx,r15 / vzeroupper / call AddEntity / mov edx,[rsp+40h] / mov [r12],edx"
    u32 s0 = FindSigRva("48 8D 54 24 40 49 8B CF C5 F8 77 E8 ?? ?? ?? ?? 8B 54 24 40 41 89 14 24");
    // its caller's call "mov r9d,ebx / mov r8d,r15d / mov rdx,r13 / lea rcx,[rsp+48h] / call / mov [rbp-60h],r13 / mov edi,[rsp+48h]"
    u32 s1 = FindSigRva("44 8B CB 45 8B C7 49 8B D5 48 8D 4C 24 48 E8 ?? ?? ?? ?? 4C 89 6D A0 8B 7C 24 48");
    // the vehicles' system's call "mov [rsp+28h],r15 / mov [rsp+20h],rsi / mov r9,rax / lea rcx,[rsp+70h] / call / mov eax,[rax] / mov [r12+50h],eax"
    u32 s2 = FindSigRva("4C 89 7C 24 28 48 89 74 24 20 4C 8B C8 48 8D 4C 24 70 E8 ?? ?? ?? ?? 8B 00 41 89 44 24 50");
    const char* miss = (!s0 || !s1 || !s2) ? "a call of the chain not found" : 0;
    auto target = [](u32 callRva) -> u64 { const u8* c = (const u8*)(g_base + callRva); return (u64)(c + 5 + *(const i32*)(c + 1)) - g_base; };
    if (!miss) {
        u64 t0 = target(s0 + 11), t1 = target(s1 + 14), t2 = target(s2 + 18);
        // AddEntity; the second call goes to the function the first is in, the third to the function the second is in
        if (t0 != RVA_ADDENTITY) miss = "the wrapper calls another function";
        else if (!(t1 <= s0 && s0 - t1 < 0x1000)) miss = "the wrapper's caller calls another function";
        else if (!(t2 <= s1 && s1 - t2 < 0x1000)) miss = "the vehicles' system calls another function";
    }
    if (miss) { b.str("fresh ids: the vehicles bought take the queue's ids (").str(miss).str(")"); LogLine(b); return; }
    g_buySite[0] = s0 + 16; g_buySite[1] = s1 + 19; g_buySite[2] = s2 + 23;
    g_freshBuy = true;
    b.str("fresh ids: the vehicles bought too (AddEntity returning to ").hex(g_buySite[0]).str(" from ").hex(g_buySite[1]).str(" from ").hex(g_buySite[2]).str(")");
    LogLine(b);
}

// ---------------------------------------------------------------- the tools' company (ported from TPF3-MP, MIT)
// Ported from TPF3-MP's "The tools' player" (docs/HOOKS.md, crates/tpf3mp-hook/src/toolplayer.rs, signatures of
// profiles/tf3_build40420_steam_windows/hooks.toml). UI::CGameUI's constructor reads the save's player once and hands each
// tool a copy. The builds themselves are given the player's company by OwnerFix, but the tools also use their copy to decide
// what is "the player's own": the street tool snapped only to the ends of the company's own roads, and the bulldozer would
// not offer the company's own roads, stops and buildings (its filter's owner list held the save's company: issue #47). At the
// start of each tool's Step (main thread), a field still holding the savegame company gets this machine's company. Only
// with separate companies, once this machine's company is known and differs from the savegame's.

static u32 g_bullVtable = 0;           // the bulldozer filter's vtable (rva), checked before its list is written
static volatile long g_toolWrites = 0;

static void ToolField(u64 obj, u32 off)
{
    long canon = g_canon, local = g_localPlayer;
    if (!canon || !local || canon == local || !Writable((void*)(obj + off), 4)) return;
    if (*(i32*)(obj + off) == canon) { *(i32*)(obj + off) = (i32)local; _InterlockedIncrement(&g_toolWrites); }
}
// a std::vector<Entity> at vec: its savegame-company entries get this machine's company
static void ToolList(u64 vec)
{
    long canon = g_canon, local = g_localPlayer;
    if (!canon || !local || canon == local || !Readable((void*)vec, 24)) return;
    u64 b = *(u64*)vec, e = *(u64*)(vec + 8);
    if (b == e || e < b || ((e - b) & 3) || (e - b) > 4096 || !Writable((void*)b, e - b)) return;
    for (i32* q = (i32*)b; q < (i32*)e; q++) if (*q == canon) { *q = (i32)local; _InterlockedIncrement(&g_toolWrites); }
}
static void ToolStreetBuilder(SavedRegs* r) { ToolField(r->rcx, 0xc0); }
static void ToolTrackModifier(SavedRegs* r) { ToolField(r->rcx, 0xa0); }
static void ToolConstructionBuilder(SavedRegs* r) { ToolField(r->rcx, 0xa0); }
static void ToolStreetTerminalBuilder(SavedRegs* r) { ToolField(r->rcx, 0xa0); }
static void ToolModuleBuilder(SavedRegs* r) { ToolField(r->rcx, 0xa8); }
static void ToolBulldozer(SavedRegs* r)
{
    u64 self = r->rcx;
    ToolField(self, 0x28);                 // its own player: the proposals it makes
    ToolList(self + 0xa8);                 // its owner list: every query it makes
    if (!Readable((void*)(self + 0xc0), 8)) return;
    u64 f = *(u64*)(self + 0xc0);          // its BulldozerFilter, when the vtable is the one its constructor puts
    if (g_bullVtable && f && Readable((void*)f, 0x28) && *(u64*)f == g_base + g_bullVtable) ToolList(f + 0x10);
}

// HudIconManager's owner filter (see g_hudShare): `lea rdx,[rax+rcx*4]; test rdx,rdx; je keep; cmp [rdx],r12d; jne skip` with the
// entity in ebx and the local player in r12d. For an entity of a shared station, r12 takes the entity's owner, so the comparison
// keeps it (r12 is read again before its next use).
static void HudShareSplice(SavedRegs* r)
{
    long cur = g_hudShareCur;
    long n = g_hudShareN[cur];
    if (n <= 0) return;
    i32* owner = (i32*)(r->rax + r->rcx * 4);
    if (!owner || !r->rax) return;
    i32 o = *owner;
    if (o == (i32)r->r12 || o < 0) return;
    i32 e = (i32)r->rbx;
    const i32* a = g_hudShare[cur];
    long lo = 0, hi = n - 1;
    while (lo <= hi) {
        long mid = (lo + hi) >> 1;
        if (a[mid] == e) { r->r12 = (r->r12 & 0xFFFFFFFF00000000ull) | (u32)o; _InterlockedIncrement(&g_hudShareLet); return; }
        if (a[mid] < e) lo = mid + 1; else hi = mid - 1;
    }
}

static void InstallHudShare()
{
    if (GetEnvironmentVariableA("MPFEVER_NOHUDSHARE", 0, 0) > 0) { Buf b; b.str("shared stations on the map: off (MPFEVER_NOHUDSHARE)"); LogLine(b); return; }
    u32 at = FindSigRva("48 8D 14 88 48 85 D2 74 05 44 39 22 75 2D 4C 8B B4 24 B8 00 00 00");
    u8* mem = at ? AllocNear(0x400) : 0;
    bool ok = mem && Splice(mem, at, 7, HudShareSplice);
    Buf b; b.str("shared stations on the map: ").str(ok ? "icon filter hooked at " : "OFF (the icon filter was not found)");
    if (ok) b.hex(at);
    LogLine(b);
}

// The stop tool on another company's road (one company per player): when it looks for the segment under the cursor, the engine
// drops every segment whose PlayerOwned is not the tool's player (IsOwnedByOtherPlayer, 40420 0x6101d0 / 40423 0x6110b0, called
// from MyFindSnapPointNew on the segment, its nodes and their neighbours), so a player could put no stop on the roads and bridges
// another player built (the "Place Along Road" hint only). The snap search gets player -1 (no owner filter, as for the towns'
// roads); ebx keeps the tool's player for the terminal proposal, its cost and the money check. The splice is just after
// `mov ebx,[rbp+1BE0h]; mov [rsp+28h],ebx` (the 6th argument of the snap wrapper) and steals `mov [rsp+20h],r8; mov r9,[rax+78h]`.
static volatile long g_stopSnapLet = 0;
static void StopSnapAnyOwner(SavedRegs* r)
{
    if (g_nOthers <= 0 && !(g_canon && g_localPlayer && g_canon != g_localPlayer)) return;
    i32* player = (i32*)(OrigRsp(r) + 0x28);
    if (*player >= 0) { *player = -1; _InterlockedIncrement(&g_stopSnapLet); }
}
static void InstallStopSnap()
{
    if (GetEnvironmentVariableA("MPFEVER_NOSTOPSNAP", 0, 0) > 0) { Buf b; b.str("stops on other companies' roads: off (MPFEVER_NOSTOPSNAP)"); LogLine(b); return; }
    u32 at = FindSigRva("8B 9D E0 1B 00 00 89 5C 24 28 4C 89 44 24 20 4C 8B 48 78 4C 8D 85 B8 00 00 00 48 8D 95 A0 00 00 00 49 8B CE E8");
    u8* mem = at ? AllocNear(0x200) : 0;
    bool ok = mem && Splice(mem, at + 10, 9, StopSnapAnyOwner);
    Buf b; b.str("stops on other companies' roads: ").str(ok ? "the stop tool's snap hooked at " : "OFF (the stop tool's snap call was not found)");
    if (ok) b.hex(at + 10);
    LogLine(b);
}

// The builders' and the stop tool's owner filter (40420 0x6101d0, 40423 0x6110b0): bool IsOwnedByOtherPlayer(engine, player,
// entity) = the entity's PlayerOwned is another player's. For the segments and nodes of the open tracks (see LoadOpenNet) it
// answers no: the track and street builders snap to them, so another company can connect its tracks. MPFEVER_NOOPENNET=1: off.
typedef bool (*IsOwnedF)(void* engine, i32 player, i32 entity);
static IsOwnedF g_isOwnedOrig = 0;
static bool IsOwnedDetour(void* engine, i32 player, i32 entity)
{
    // (the interface's thread only, where the tools look for what to snap to: the list differs between machines, and every
    // decision of the simulation must stay the engine's own, the same on every game)
    if (g_mainTid && (long)GetCurrentThreadId() == g_mainTid && g_openNetN[g_openNetCur] > 0 && InOpenNet(entity)) { _InterlockedIncrement(&g_openLet); return false; }
    return g_isOwnedOrig(engine, player, entity);
}
static void InstallOpenNet()
{
    if (GetEnvironmentVariableA("MPFEVER_NOOPENNET", 0, 0) > 0) { Buf b; b.str("open tracks: off (MPFEVER_NOOPENNET)"); LogLine(b); return; }
    static const u8 P_ISOWNED[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18 };
    u32 at = FindSigRva("48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 30 49 63 F8 8B DA 48 8B E9 85 D2 0F 88 ?? ?? ?? ?? 48 8D 05 ?? ?? ?? ?? 48 83 C1 48 4C 8D 44 24 58");
    bool ok = at && InstallDetour(at, P_ISOWNED, sizeof(P_ISOWNED), (void*)&IsOwnedDetour, (void**)&g_isOwnedOrig);
    Buf b; b.str("open tracks: ").str(ok ? "the builders' owner filter hooked at " : "OFF (the owner filter was not found)");
    if (ok) b.hex(at);
    LogLine(b);
}

// (0.6.9) the vehicles' wear. The engine's maintenance update (TransportVehicleSystem, build 40425 at 0xb837f0) wears a
// vehicle's parts only when its PlayerOwned owner is the system's player ([system+0x2c], the savegame's company): with one
// company per player, the other companies' vehicles never wore (156 of them at 100 % for years, stress test of 2026-11-02 on
// Test Gameplay, probe m3: the savegame company's trains and trams wore, the other company's buses, trucks, trains, ships and
// planes never did; their maintenance stations repaired them all the same). The owner comparison's jne is taken out: every
// vehicle with an owner wears, the same way on every game (a simulation rule; MPFEVER_ALLWEAR=0: as before)
// ---------------------------------------------------------------- the faster bitmap span (0.6.10, after TPF3-MP, MIT)
// After TPF3-MP's "fast-bitmap-span" (Juliansgith/Transport-Fever-3-Multiplayer-Mod, MIT: crates/tpf3mp-hook/src/fastbitmap.rs,
// commit add4a87 of 2026-10-29; the idea and its signature, made again here). When an industry appears, the game connects it to
// the roads ("Connect industry", 0.9 to 1.1 s on a big world, every game frozen meanwhile); 61 % of it went into one 78-byte
// function, the span fill of a BitmapRasterizable (40425: 0x91a560, slot 1 of its vtable), which sets a span's bits one at a time
// with bts. fast_span.h sets the same bits a whole word at a time (TPF3-MP: 0.4 s): the bitmap ends exactly as the game's loop
// leaves it, so a game with it and one without build the same roads. A span starting below bit 0 is handed to the game's loop.
// The signature is the whole function, entry to ret: another build's leaves the game's own. MPFEVER_FASTSPAN=0: the game's own.
#include "fast_span.h"
static FsOrigF g_spanOrig = 0;
static volatile long g_spanFast = 0, g_spanHanded = 0;
static u8 SpanFill(u64 self, i32 x, i32 y, i32 count) { return FsFill(self, x, y, count, g_spanOrig, &g_spanFast, &g_spanHanded); }

static void InstallFastSpan()
{
    { char v[4] = {}; if (GetEnvironmentVariableA("MPFEVER_FASTSPAN", v, 3) > 0 && v[0] == '0') { Buf b; b.str("bitmap span: the game's own (MPFEVER_FASTSPAN=0)"); LogLine(b); return; } }
    u32 at = FindSigRva("44 0F AF 41 10 4C 8B D9 44 03 C2 43 8D 04 08 44 3B C0 7D 37 49 63 C0 45 8B D1 66 0F 1F 44 00 00 49 8B 4B 08 4C 8B C0 49 C1 E8 05 48 8B 11 42 8B 0C 82 4E 8D 0C 82 48 8B D0 83 E2 1F 48 FF C0 0F AB D1 41 89 09 49 83 EA 01 75 D5 32 C0 C3");
    // (imul r8d,[rcx+10h] / mov r11,rcx / add r8d,edx / lea eax,[r8+r9]: 15 bytes that run anywhere, copied into the trampoline)
    static const u8 pro[] = { 0x44, 0x0F, 0xAF, 0x41, 0x10, 0x4C, 0x8B, 0xD9, 0x44, 0x03, 0xC2, 0x43, 0x8D, 0x04, 0x08 };
    u8* mem = at ? AllocNear(0x100) : 0;
    void* t = mem ? DetourWhole(mem, at, pro, (int)sizeof(pro), (void*)SpanFill) : 0;
    Buf b;
    if (!t) { b.str("bitmap span: the game's own (").str(at ? "not hooked" : "not found").str(")"); LogLine(b); return; }
    g_spanOrig = (FsOrigF)t;
    b.str("bitmap span (from TPF3-MP): filled a word at a time, at ").hex(at);
    LogLine(b);
}

// ---------------------------------------------------------------- faster saves (0.7.6, after TPF3-MP, MIT)
// After TPF3-MP's "faster saves" (Juliansgith/Transport-Fever-3-Multiplayer-Mod, MIT: crates/tpf3mp-hook/src/savefast.rs and
// profiles/tf3_build40425_steam_windows/savefast.rs, verified there 2026-10-28; itself after silver2127's Big Maps for TPF2). The
// game compresses a savegame with zstd at level 3 through a 128-byte stream buffer: most of a save's time on a big world. Two
// instructions of the save writer's PushCompressor (40425: 0x32deb0) are rewritten in place: the level loaded from the constant it
// shares with the reader (mov eax,[rip+x]) becomes 1 (mov eax,1; nop), the buffer (mov r8d,80h) 64 KiB. A savegame is still a
// standard zstd frame of the same bytes, loaded by any game with or without it (the reader keeps its constant); TPF3-MP measured
// 4.4-4.6 s instead of 7.2-7.4 s for a 150 MB world, files about 6.5 % larger. MPFever saves at every resynchronisation, every
// autosave of a server and when a player joins, every game stopped meanwhile. Each site is checked byte for byte (its signature is
// unique in the game) and patched alone. Off by default (see below): MPFEVER_FASTSAVE=1
static void InstallFastSave()
{
    // (0.7.6, measured on Test Lag Rp, two games on one PC, the host's resynchronisation save: the game's own 6.4 s for 114.8 MB;
    // level 1 and the buffer 5.3 s for 124.7 MB; the buffer alone 6.5 s, 114.8 MB. The second gained is lost again sending 10 MB
    // more to a player over the Internet (5.4 MB/s on the user's server): OFF by default. MPFEVER_FASTSAVE=1: both; =level: the
    // level only; =buffer: the buffer only)
    char fs[16] = {};
    if (GetEnvironmentVariableA("MPFEVER_FASTSAVE", fs, 15) == 0 || fs[0] == '0') { Buf b; b.str("faster saves: the game's own (MPFEVER_FASTSAVE=1 to try them)"); LogLine(b); return; }
    bool doLevel = fs[0] != 'b', doBuffer = fs[0] != 'l';
    auto patch = [](u32 at, const u8* expect, const u8* put, int n) -> bool {
        if (!at) return false;
        u8* site = (u8*)(g_base + at);
        for (int i = 0; i < n; i++) if (site[i] != expect[i]) return false;
        DWORD old;
        if (!VirtualProtect(site, n, PAGE_EXECUTE_READWRITE, &old)) return false;
        for (int i = 0; i < n; i++) site[i] = put[i];
        VirtualProtect(site, n, old, &old);
        FlushInstructionCache(GetCurrentProcess(), site, n);
        return true;
    };
    // mov eax,[rip+disp] / mov [r11+10h],eax / lea rax,[r11-78h]: the level (the displacement is read, not assumed)
    u32 lv = FindSigRva("8B 05 ?? ?? ?? ?? 41 89 43 10 49 8D 43 88");
    u8 lvWas[6] = { 0x8B, 0x05, 0, 0, 0, 0 };
    if (lv) for (int i = 2; i < 6; i++) lvWas[i] = *(u8*)(g_base + lv + i);
    // the level's constant must hold 3, the game's (else another build's code: left alone)
    bool three = lv && *(i32*)(g_base + lv + 6 + *(i32*)(g_base + lv + 2)) == 3;
    static const u8 lvPut[6] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0x90 };
    bool okL = doLevel && three && patch(lv, lvWas, lvPut, 6);
    // mov r9,rbx / mov r8d,80h / lea rdx,[rsp+30h] / mov rcx,rax / call (the compressor's stream): the buffer
    u32 bf = FindSigRva("4C 8B CB 41 B8 80 00 00 00 48 8D 54 24 30 48 8B C8 E8 E9 B5 FE FF");
    static const u8 bfWas[6] = { 0x41, 0xB8, 0x80, 0x00, 0x00, 0x00 }, bfPut[6] = { 0x41, 0xB8, 0x00, 0x00, 0x01, 0x00 };
    bool okB = doBuffer && bf && patch(bf + 3, bfWas, bfPut, 6);
    Buf b;
    b.str("faster saves (from TPF3-MP): ").str(okL ? "zstd level 1" : "the game's zstd level").str(okL ? "" : (lv ? (three ? " (not patched)" : " (its constant is not 3)") : " (not found)"))
        .str(", ").str(okB ? "a 64 KiB buffer" : "the game's 128-byte buffer").str(okB ? "" : (bf ? " (not patched)" : " (not found)"));
    if (okL) b.str(" at ").hex(lv);
    if (okB) b.str(", ").hex(bf + 3);
    LogLine(b);
}

static void InstallVehicleWear()
{
    { char v[4] = {}; if (GetEnvironmentVariableA("MPFEVER_ALLWEAR", v, 3) > 0 && v[0] == '0') { Buf b; b.str("vehicle wear: the savegame's company only (MPFEVER_ALLWEAR=0)"); LogLine(b); return; } }
    // call getComponent(PlayerOwned); mov r14,[rsp+40h]; test rax,rax; je no; mov ecx,[r14+2Ch]; cmp [rax],ecx; jne no; mov byte [rsp+32h],1
    u32 at = FindSigRva("E8 ?? ?? ?? ?? 4C 8B 74 24 40 48 85 C0 74 14 41 8B 4E 2C 39 08 75 0C C6 44 24 32 01 EB 0A");
    bool ok = false;
    if (at) {
        u8* site = (u8*)(g_base + at + 21);
        DWORD old;
        if (site[0] == 0x75 && site[1] == 0x0C && VirtualProtect(site, 2, PAGE_EXECUTE_READWRITE, &old)) {
            site[0] = 0x90; site[1] = 0x90;
            VirtualProtect(site, 2, old, &old);
            FlushInstructionCache(GetCurrentProcess(), site, 2);
            ok = true;
        }
    }
    Buf b; b.str("vehicle wear: ").str(ok ? "every company's vehicles (owner filter taken out at " : "the savegame's company only (the owner filter was not found)");
    if (ok) b.hex(at + 21).str(")");
    LogLine(b);
}

static void InstallToolCompany()
{
    if (GetEnvironmentVariableA("MPFEVER_NOTOOLCO", 0, 0) > 0) { Buf b; b.str("tools' company: off (MPFEVER_NOTOOLCO)"); LogLine(b); return; }
    u8* mem = AllocNear(0x1000);
    if (!mem) return;
    // every field's offset is the one its constructor's code stores (the signatures include the stores)
    struct Tool { const char* name; const char* step; int steal; const char* store; SpliceFn fn; };
    static const Tool tools[] = {
        { "street and track builder", "48 89 5C 24 18 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 E0 CC FF FF", 5,
          "48 8B 85 10 01 00 00 48 89 86 B0 00 00 00 48 8B 85 18 01 00 00 48 89 86 B8 00 00 00 8B 85 28 01 00 00 89 86 C0 00 00 00", ToolStreetBuilder },
        { "track modifiers", "48 89 5C 24 20 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 50 CC FF FF", 5,
          "48 8B 85 20 03 00 00 49 89 86 98 00 00 00 8B 85 30 03 00 00 41 89 86 A0 00 00 00", ToolTrackModifier },
        { "construction builder", "48 89 5C 24 18 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 C0 D5 FF FF", 5,
          "49 89 B6 90 00 00 00 48 8B 85 E0 02 00 00 49 89 86 98 00 00 00 8B 85 F0 02 00 00 41 89 86 A0 00 00 00", ToolConstructionBuilder },
        { "stop, signal and waypoint builder", "40 53 56 57 41 54 41 55 41 56 41 57 B8 80 14 00 00", 6,
          "49 89 BE 88 00 00 00 49 89 B6 90 00 00 00 48 8B 85 C0 01 00 00 49 89 86 98 00 00 00 8B 85 D0 01 00 00 41 89 86 A0 00 00 00", ToolStreetTerminalBuilder },
        { "module builder", "40 53 56 57 41 54 41 55 41 56 41 57 B8 A0 10 00 00", 6,
          "48 8B 85 C8 02 00 00 48 89 87 98 00 00 00 49 8B 04 24 33 C9 49 89 0C 24 48 89 87 A0 00 00 00 8B 85 E0 02 00 00 89 87 A8 00 00 00", ToolModuleBuilder },
        { "bulldozer", "48 8B C4 48 89 58 20 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 28 F1 FF FF", 7,
          "48 8D 05 ?? ?? ?? ?? 49 89 06 49 89 76 20 41 89 5E 28 48 8B 85 C8 01 00 00", ToolBulldozer },
    };
    u32 filter = FindSigRva("48 8D 05 ?? ?? ?? ?? 48 89 03 48 89 73 08 48 89 7B 10 48 89 7B 18 48 89 7B 20 66 C7 43 28 00 00 EB 03 48 8B DF 48 89 5D D8 49 89 9E C0 00 00 00");
    bool ownerList = FindSigRva("49 89 BE 98 00 00 00 49 89 BE A0 00 00 00 4D 8D BE A8 00 00 00 49 89 3F 49 89 7F 08 49 89 7F 10") != 0;
    if (filter) g_bullVtable = (u32)(filter + 7 + *(i32*)(g_base + filter + 3));
    Buf b; b.str("tools' company (from TPF3-MP):");
    for (int i = 0; i < (int)(sizeof(tools) / sizeof(tools[0])); i++) {
        const Tool& t = tools[i];
        u32 step = FindSigRva(t.step);
        bool ok = step && FindSigRva(t.store) && !(i == 5 && (!filter || !ownerList)) && Splice(mem, step, t.steal, t.fn);
        b.str(" ").str(t.name).str(ok ? " on" : " OFF").str(i + 1 < (int)(sizeof(tools) / sizeof(tools[0])) ? "," : "");
    }
    LogLine(b);
}

// the order fixes' counters, at most once a minute in native.log: sorts made, of them reordered, refused
static void LogOrderCounts()
{
    Buf b; b.str("order fixes:");
    for (int i = 0; i < ORDER_N; i++) b.str(" ").str(ORDER_FIXES[i].name).str(" ").dec(g_orderSorts[i]).str("/").dec(g_orderReorders[i]).str("/").dec(g_orderRefused[i]);
    b.str(" road entries ").dec(g_orderSorts[ROAD_W]).str("/").dec(g_orderReorders[ROAD_W]).str("/").dec(g_orderRefused[ROAD_W]);
    b.str("; tools' company written ").dec(g_toolWrites).str(" time(s); shared station icons let through ").dec(g_hudShareLet).str("; stop tool snaps on any owner ").dec(g_stopSnapLet).str("; open tracks let through ").dec(g_openLet);
    // (the industries' demand scheduler: calls given the kept history / on the kept one's own state / of a history not of the
    // world (left alone) / refused; histories kept and let go)
    b.str("; industry demand ").dec(g_ind.shared).str("/").dec(g_ind.own).str("/").dec(g_ind.other).str("/").dec(g_ind.refused)
        .str(", kept ").dec(g_ind.kept_n).str(", let go ").dec(g_ind.released);
    // (the platform-decision flags: copies after the loop's Replicate / flags that differed and were copied / vehicle lists
    // taken / refused / decision reads off the simulation thread)
    b.str("; decision flags ").dec(g_dsSyncs).str("/").dec(g_dsCopied).str("/").dec(g_dsNotes).str("/").dec(g_dsRefused).str("/").dec(g_dsOther);
    // (0.8.6, #150: the same account changes on every game, this machine's figures put back / not found)
    if (g_clearSame == 1) b.str("; own figures put back ").dec(g_clearSameKept).str("/").dec(g_clearSameMissed).str(" (with figures ").dec(g_clearSameFull).str(", largest ").dec(g_clearSameBytes).str(" bytes)");
    // (the commands' new entities given a fresh id / the same in a copy of the state / refused, another engine)
    // (the scripts' commands' entities: counted, the queue's ids)
    b.str("; fresh ids ").dec(g_freshCmd).str("/").dec(g_freshReplay).str("/").dec(g_freshOther).str(", left to the queue ").dec(g_freshSkip)
        .str(", script entities ").dec(g_freshScript).str(", vehicles bought ").dec(g_freshBuyN);
    // (the commands applied, by where from: the loop, the scripts' sink, CGame's sink, another place; on the simulation thread
    // and on another)
    b.str("; applied ");
    for (int i = 0; i < 4; i++) b.str(i ? " " : "").dec(g_applySite[i][0]).str("/").dec(g_applySite[i][1]);
    LogLine(b);
}

static void HookWordReads()
{
    if (!g_layout) return;
    u8* mem = AllocNear(0x10000);
    if (!mem) { Buf e; e.str("player word: no memory near the game's code, readings not hooked"); LogLine(e); return; }
    u8* stubs = mem;
    int done = 0;
    bool staleUi = true;
    { char v[4] = {}; if (GetEnvironmentVariableA("MPFEVER_STALEUI", v, 3) == 1 && v[0] == '0') staleUi = false; }
    for (int i = 0; i < g_n20 && i < 64; i++) {
        const Site20c& s = g_s20[i];
        u8* site = (u8*)(g_base + s.rva);
        if (memcmp(site, s.bytes, s.len) != 0) continue;
        g_siteRule[i] = g_s20FromSigs ? g_rule20dyn[i] : (u8)RuleOf(s.rva);
        Asm a{ stubs };
        a.b(0x9C);                                   // pushfq
        { const u8 t_[] = { 0x41, 0x52, 0x41, 0x53 }; a.bn(t_, (int)sizeof(t_)); }            // push r10 / push r11
        // lea r11,[base+20Ch]
        a.b((u8)(0x4C | (s.base >= 8 ? 1 : 0))); a.b(0x8D); a.b((u8)(0x98 | (s.base & 7)));
        if ((s.base & 7) == 4) a.b(0x24);
        { const u8 t_[] = { 0x0C, 0x02, 0x00, 0x00 }; a.bn(t_, (int)sizeof(t_)); }
        for (int k = 0; k < s.len; k++) a.b(s.bytes[k]);    // the original reading
        a.b(0x49); a.b(0xBA); a.imm64((u64)&g_gsWord);     // mov r10,&gsWord
        { const u8 t_[] = { 0x4D, 0x3B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                        // cmp r11,[r10]
        u8* jAct = a.jcc32(0x84);                          // je ACT
        { const u8 t_[] = { 0x4D, 0x3B, 0x5A, 0x08 }; a.bn(t_, (int)sizeof(t_)); }                  // cmp r11,[r10+8]
        u8* jUnm = a.jcc32(0x85);                          // jne UNMATCHED
        u8* act = a.p; Asm::at(jAct, act);
        { const u8 t_[] = { 0x65, 0x44, 0x8B, 0x1C, 0x25, 0x48, 0, 0, 0 }; a.bn(t_, (int)sizeof(t_)); }    // mov r11d,gs:[48h]
        a.b(0x49); a.b(0xBA); a.imm64((u64)&g_mainTid);    // mov r10,&mainTid
        { const u8 t_[] = { 0x45, 0x3B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                        // cmp r11d,[r10]
        u8* jMain = a.jcc32(0x84);
        a.b(0x49); a.b(0xBA); a.imm64((u64)&g_simTid);     // mov r10,&simTid
        { const u8 t_[] = { 0x45, 0x3B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                        // cmp r11d,[r10]
        u8* jSim = a.jcc32(0x84);
        u8* ends[3] = {};
        u8* labels[3] = {};
        int rule = g_siteRule[i] & 0x0F;
        bool uiObj = (g_siteRule[i] & RULE_UIOBJ) != 0;
        for (int kind = 2; kind >= 0; kind--) {            // other, sim, main
            labels[kind] = a.p;
            a.b(0x49); a.b(0xBA); a.imm64((u64)&g_siteCount[i][kind]);   // mov r10,&count
            { const u8 t_[] = { 0xF0, 0x49, 0xFF, 0x02 }; a.bn(t_, (int)sizeof(t_)); }                            // lock inc qword [r10]
            volatile long* tgt = 0;
            if (rule == RULE_SIM && kind != 0) tgt = &g_canon;
            if (rule == RULE_NOTSIM && kind == 1) tgt = &g_canon;
            if (rule == RULE_UI && kind == 0) tgt = &g_localPlayer;
            if (rule == RULE_NOTSIM && kind != 1) tgt = &g_localPlayer;
            if (rule == RULE_SIMTHREAD && kind == 1) {
                // the build's company while one is applied, else the savegame's
                a.b(0x49); a.b(0xBA); a.imm64((u64)&g_simPlayer);   // mov r10,&simPlayer
                { const u8 t_[] = { 0x45, 0x8B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                  // mov r11d,[r10]
                { const u8 t_[] = { 0x45, 0x85, 0xDB }; a.bn(t_, (int)sizeof(t_)); }                  // test r11d,r11d
                { const u8 t_[] = { 0x75, 0x0D }; a.bn(t_, (int)sizeof(t_)); }                        // jne +13 (to the mov dst)
                tgt = &g_canon;
            }
            if (tgt) {
                a.b(0x49); a.b(0xBA); a.imm64((u64)tgt);    // mov r10,&target
                { const u8 t_[] = { 0x45, 0x8B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                  // mov r11d,[r10]
                { const u8 t_[] = { 0x45, 0x85, 0xDB }; a.bn(t_, (int)sizeof(t_)); }                  // test r11d,r11d
                { const u8 t_[] = { 0x74, 0x03 }; a.bn(t_, (int)sizeof(t_)); }                        // je +3 (unknown: as read)
                if (s.dst < 8) { const u8 t_[] = { 0x44, 0x89, (u8)(0xD8 | s.dst) }; a.bn(t_, (int)sizeof(t_)); } else { const u8 t_[] = { 0x45, 0x89, (u8)(0xD8 | (s.dst - 8)) }; a.bn(t_, (int)sizeof(t_)); }   // mov dst,r11d
            }
            ends[kind] = a.jmp32();                          // jmp DONE
        }
        Asm::at(jMain, labels[0]);
        Asm::at(jSim, labels[1]);
        // UNMATCHED: the word of an object of the interface's own (the tools' factory makes every tool for the player it reads
        // there, the savegame's company): off the simulation thread, the savegame's company read there becomes this machine's
        Asm::at(jUnm, a.p);
        u8* jUnmDone[12] = {};
        int nUnm = 0;
        if (uiObj) {
            const u8 cmpDstR10[] = { (u8)(0x41 | (s.dst >= 8 ? 4 : 0)), 0x3B, (u8)(((s.dst & 7) << 3) | 2) };    // cmp dst,[r10]
            const u8 movDstR11[] = { (u8)(s.dst < 8 ? 0x44 : 0x45), 0x89, (u8)(0xD8 | (s.dst & 7)) };           // mov dst,r11d
            { const u8 t_[] = { 0x65, 0x44, 0x8B, 0x1C, 0x25, 0x48, 0, 0, 0 }; a.bn(t_, (int)sizeof(t_)); }    // mov r11d,gs:[48h]
            a.b(0x49); a.b(0xBA); a.imm64((u64)&g_simTid);     // mov r10,&simTid
            { const u8 t_[] = { 0x45, 0x3B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                        // cmp r11d,[r10]
            jUnmDone[nUnm++] = a.jcc32(0x84);                  // je DONE
            a.b(0x49); a.b(0xBA); a.imm64((u64)&g_canon);      // mov r10,&canon
            a.bn(cmpDstR10, 3);                                // cmp dst,[r10]
            u8* jStale = a.jcc32(0x85);                        // jne STALE
            a.b(0x49); a.b(0xBA); a.imm64((u64)&g_localPlayer); // mov r10,&localPlayer
            { const u8 t_[] = { 0x45, 0x8B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                        // mov r11d,[r10]
            { const u8 t_[] = { 0x45, 0x85, 0xDB }; a.bn(t_, (int)sizeof(t_)); }                        // test r11d,r11d
            jUnmDone[nUnm++] = a.jcc32(0x84);                  // je DONE
            a.bn(movDstR11, 3);                                // mov dst,r11d
            a.b(0x49); a.b(0xBA); a.imm64((u64)&g_siteCount[i][3]);   // mov r10,&count
            { const u8 t_[] = { 0xF0, 0x49, 0xFF, 0x02 }; a.bn(t_, (int)sizeof(t_)); }                  // lock inc qword [r10]
            jUnmDone[nUnm++] = a.jmp32();                      // jmp DONE
            // STALE: a player of the game before (see g_stalePlayer), not this machine's in this one: the interface's word now
            Asm::at(jStale, a.p);
            if (staleUi) {
                u8* jHit[2] = {};
                for (int k = 0; k < 2; k++) {
                    a.b(0x49); a.b(0xBA); a.imm64((u64)&g_stalePlayer[k]);   // mov r10,&stale[k]
                    { const u8 t_[] = { 0x45, 0x8B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                // mov r11d,[r10]
                    { const u8 t_[] = { 0x45, 0x85, 0xDB }; a.bn(t_, (int)sizeof(t_)); }                // test r11d,r11d
                    u8* jNone = a.jcc32(0x84);                 // je NEXT
                    a.b((u8)(0x41 | (s.dst >= 8 ? 4 : 0))); a.b(0x3B); a.b((u8)(0xC3 | ((s.dst & 7) << 3)));   // cmp dst,r11d
                    jHit[k] = a.jcc32(0x84);                   // je HIT
                    Asm::at(jNone, a.p);
                }
                jUnmDone[nUnm++] = a.jmp32();                  // jmp DONE
                for (int k = 0; k < 2; k++) Asm::at(jHit[k], a.p);
                a.b(0x49); a.b(0xBA); a.imm64((u64)&g_localPlayer); // mov r10,&localPlayer
                a.bn(cmpDstR10, 3);                            // cmp dst,[r10]
                jUnmDone[nUnm++] = a.jcc32(0x84);              // je DONE (this machine's company in this game too)
                a.b(0x49); a.b(0xBA); a.imm64((u64)&g_uiWord); // mov r10,&uiWord
                { const u8 t_[] = { 0x45, 0x8B, 0x1A }; a.bn(t_, (int)sizeof(t_)); }                    // mov r11d,[r10]
                { const u8 t_[] = { 0x45, 0x85, 0xDB }; a.bn(t_, (int)sizeof(t_)); }                    // test r11d,r11d
                jUnmDone[nUnm++] = a.jcc32(0x84);              // je DONE (no iteration of this game yet)
                a.bn(movDstR11, 3);                            // mov dst,r11d
                a.b(0x49); a.b(0xBA); a.imm64((u64)&g_staleFixed);   // mov r10,&staleFixed
                { const u8 t_[] = { 0xF0, 0x49, 0xFF, 0x02 }; a.bn(t_, (int)sizeof(t_)); }              // lock inc qword [r10]
            }
        }
        u8* doneL = a.p;
        for (int k = 0; k < nUnm; k++) Asm::at(jUnmDone[k], doneL);
        for (int kind = 0; kind < 3; kind++) Asm::at(ends[kind], doneL);
        { const u8 t_[] = { 0x41, 0x5B, 0x41, 0x5A }; a.bn(t_, (int)sizeof(t_)); }            // pop r11 / pop r10
        a.b(0x9D);                                   // popfq
        { const u8 t_[] = { 0xFF, 0x25, 0, 0, 0, 0 }; a.bn(t_, (int)sizeof(t_)); } a.imm64((u64)(site + s.len));   // jmp [rip] back
        // the site: jmp rel32 to the stub
        i64 rel = (i64)(stubs - (site + 5));
        if (rel > 0x7FFFFFFF || rel < -0x7FFFFFFFll) break;
        DWORD old;
        if (!VirtualProtect(site, s.len, PAGE_EXECUTE_READWRITE, &old)) continue;
        u8 patch[8];
        patch[0] = 0xE9; *(i32*)(patch + 1) = (i32)rel;
        for (int k = 5; k < s.len; k++) patch[k] = 0x90;
        memcpy(site, patch, s.len);
        VirtualProtect(site, s.len, old, &old);
        FlushInstructionCache(GetCurrentProcess(), site, s.len);
        stubs = a.p;
        stubs = (u8*)(((uptr)stubs + 15) & ~(uptr)15);
        done++;
    }
    FlushInstructionCache(GetCurrentProcess(), mem, 0x10000);
    Buf b; b.str("player word: ").dec(done).str(" of ").dec(g_n20).str(" readings hooked").str(g_s20FromSigs ? " (found by their signatures)" : ""); LogLine(b);
}

// ---------------------------------------------------------------- smooth pacing: the batch interval (ported from TPF3-MP, MIT)
// The main thread's CGame::Step calls CGame::Sync every guiFrameTime microseconds (m_data = [CGame+0x1f0], guiFrameTime the
// i32 at m_data+0x218, set by Sync from the engine's own estimate, 200-400 ms): each call hands the simulation thread its next
// batch (one update at 1x, four at 4x) and the renderer interpolates across the batch. Lockstep with a barrier used to make
// a game that came up to the slowest player's clock stand still until that clock moved, then run at full speed again: vehicles
// moved, stopped, moved (issue #47, a dedicated server on the same PC). The mod (G.smoothPace in the bridge) now writes a factor
// in native_pace.txt ("<permille> <sequence>"): right after each Sync that returned true, guiFrameTime is scaled by it, so a
// game close to the barrier shows its batches a little longer (runs a little slower) and one behind a little shorter, and
// nobody needs to stop. Only real time between batches changes: every game still runs the same steps (TPF3-MP's "The batch
// interval", docs/HOOKS.md; signature of the call from its profile of build 40420). Writing guiFrameTime anywhere but right
// after a true Sync moved TPF2's render clock back; the layout is checked before every write and any surprise turns it off.
// A factor not refreshed for 5 s goes back to 1 (a mod that stopped). MPFEVER_SMOOTH=0 (in the bridge) leaves it at 1.
typedef u64 (*SyncCallF)(void*, void*);
static void* g_syncTarget = 0;
static long g_trimSeq = -1;
static DWORD g_trimSeqAt = 0, g_paceReadAt = 0;
static KeptFile g_paceFile = { 0, 0 };
static void ReadPace()
{
    HANDLE f = KeptHandle(g_paceFile, "native_pace.txt");
    DWORD now = GetTickCount();
    if (f != INVALID_HANDLE_VALUE) {
        char buf[64] = {};
        DWORD got = 0;
        SetFilePointer(f, 0, 0, 0);
        ReadFile(f, buf, 63, &got, 0);
        long v = 0, seq = 0; DWORD i = 0;
        while (i < got && buf[i] >= '0' && buf[i] <= '9') v = v * 10 + (buf[i++] - '0');
        while (i < got && buf[i] == ' ') i++;
        while (i < got && buf[i] >= '0' && buf[i] <= '9') seq = seq * 10 + (buf[i++] - '0');
        if (seq != g_trimSeq) { g_trimSeq = seq; g_trimSeqAt = now; }
        // (0.6.12: down to 100, the "fast stand" of the bridge: while this game stands at a step for another player's build and
        // its replay is at the engine, the batches carry no step and only the exchange of commands goes faster, see G.smoothPace)
        if (v >= 100 && v <= 2500) g_trim = v;
    }
    if (g_trim != 1000 && now - g_trimSeqAt > 5000) g_trim = 1000;
}
extern "C" u64 SyncCallWrap(void* cgame, void* fn)
{
    u64 r = ((SyncCallF)g_syncTarget)(cgame, fn);
    if (r & 0xFF) {
        long n = _InterlockedIncrement(&g_batchN);
        if (BatchLog()) { Buf l; l.str("bl sync ").dec(n).str(" last step seen ").dec(g_batchStep).str(" us ").dec(NowUs()); LogLine(l); }
    }
    if (!(r & 0xFF) || g_paceOff) return r;
    DWORD now = GetTickCount();
    // (a fast stand is asked for one replay: read at every batch while the factor is below 1, every 250 ms otherwise)
    if (now - g_paceReadAt >= 250 || g_trim < 1000) { g_paceReadAt = now; ReadPace(); }
    long trim = g_trim;
    if (trim == 1000) return r;
    u8* cg = (u8*)cgame;
    if (!cg || !Readable(cg + 0x1f0, 8)) { g_paceOff = 1; return r; }
    u8* m = *(u8**)(cg + 0x1f0);
    if (!m || ((uptr)m & 7) || !Readable(m + 0x1a0, 16) || !Writable(m + 0x218, 4)) { g_paceOff = 1; return r; }
    i64 total = *(i64*)(m + 0x1a0), last = *(i64*)(m + 0x1a8);
    i32 v = *(i32*)(m + 0x218);
    if (total < last || v < 20000 || v > 2000000) return r;     // (not the layout expected: left alone this time)
    i64 nv = (i64)v * trim / 1000;
    if (nv < 20000) nv = 20000;
    if (nv > 2000000) nv = 2000000;
    *(i32*)(m + 0x218) = (i32)nv;
    _InterlockedIncrement(&g_paceWrites);
    return r;
}

static void InstallSmoothPacing()
{
    // CGame::Step's call of CGame::Sync: "movsxd rdi,[rdx+218h] / mov rcx,rbx / add rdi,[rdx+1A8h] / mov rdx,rsi / call Sync"
    u32 at = FindSigRva("48 63 BA 18 02 00 00 48 8B CB 48 03 BA A8 01 00 00 48 8B D6 E8 ?? ?? ?? ?? 84 C0 74");
    if (!at) { Buf b; b.str("smooth pacing: off (CGame::Step's call of Sync not found)"); LogLine(b); return; }
    u8* site = (u8*)(g_base + at + 20);
    u8* target = site + 5 + *(i32*)(site + 1);
    if (site[0] != 0xE8 || (RVA_SYNC && target != (u8*)(g_base + RVA_SYNC))) { Buf b; b.str("smooth pacing: off (the call at ").hex(at + 20).str(" is not CGame::Sync's)"); LogLine(b); return; }
    u8* thunk = AllocNear(64);
    if (!thunk) { Buf b; b.str("smooth pacing: off (no memory near the game's code)"); LogLine(b); return; }
    g_syncTarget = target;
    WriteAbsJump(thunk, (uptr)&SyncCallWrap);
    FlushInstructionCache(GetCurrentProcess(), thunk, 14);
    DWORD old;
    if (!VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &old)) return;
    *(i32*)(site + 1) = (i32)(thunk - (site + 5));
    VirtualProtect(site, 5, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, 5);
    Buf b; b.str("smooth pacing: CGame::Sync's call at ").hex(at + 20).str(" redirected (batch interval scaled by native_pace.txt)"); LogLine(b);
}

// ---------------------------------------------------------------- native stop point (0.5.10)
// Builds of other players are applied at the step they were made at. To be at that step exactly, the mod used to pause the game a
// little before it and ask the engine for the exact steps left (GamePerformSimulationSteps), each request a handshake round trip:
// every build of another player slowed or stopped the game for one to three seconds. The number of steps a batch of the
// simulation makes is the game speed (the GameTime component's speed, read once per batch by the steps function, 0x1593e0 on
// build 40425: max(speed, the exact steps asked for), one step of 200 ms each). That reading and the max are replaced by a thunk
// that calls StepsForBatch(time, speed, exact steps asked for), whose answer is the batch's number of steps: the mod writes
// its next stop point in native_stop.txt ("<step> <sequence>", the step being the game time / 200, the updateCount of the
// engine; -1: none), and a batch never runs past it: it makes the steps left up to it, then none while the stop point stays
// there (as a paused game does). The game stands exactly at the step, at once, with no request; the mod then sends the build,
// which the engine applies at the start of the next batch, still at that step, and moves its stop point on. Batches split
// differently change nothing in the simulation (the games already run different batch sizes near their stop points).
// native_stop_state.txt tells the mod what the latest batch did: "<sequence> <step at its start> <steps made> <stop point>".
// MPFEVER_STOPPOINT=0 leaves the engine alone.
typedef u32 (*SpeedGetF)(void*);
static SpeedGetF g_speedGet = 0;
static KeptFile g_stopFile = { 0, 0 };
static long g_stopAt = -1, g_stopSeq = -1;
static HANDLE g_stopState = 0;
static u32 g_stopLastS = 0xFFFFFFFFu, g_stopLastN = 0xFFFFFFFFu;
static long g_stopLastSeq = -2, g_stopClamps = 0;
// (a stop point is kept only while the mod's script says it is alive: bridge_alive.txt, rewritten every 2 s. A game loaded with
// MPFever disabled after a session, in the same process, would else stand at the session's last stop point)
static KeptFile g_stopAlive = { 0, 0 };
static char g_stopAliveLast[24];
static int g_stopAliveN = -1;
static u64 g_stopAliveAt = 0, g_stopAliveRead = 0;
static bool g_stopIgnored = false;
static bool StopAlive()
{
    u64 now = GetTickCount64();
    if (now - g_stopAliveRead >= 500) {
        g_stopAliveRead = now;
        HANDLE f = KeptHandle(g_stopAlive, "bridge_alive.txt");
        if (f != INVALID_HANDLE_VALUE) {
            char b[24]; DWORD got = 0;
            SetFilePointer(f, 0, 0, 0);
            if (ReadFile(f, b, sizeof(b), &got, 0) && got > 0 && ((int)got != g_stopAliveN || memcmp(b, g_stopAliveLast, got) != 0)) {
                memcpy(g_stopAliveLast, b, got); g_stopAliveN = (int)got; g_stopAliveAt = now;
            }
        }
    }
    bool alive = g_stopAliveAt && now - g_stopAliveAt < 10000;
    if (alive == g_stopIgnored) {
        g_stopIgnored = !alive;
        Buf l; l.str(alive ? "stop point: the mod's script is alive, its stop points are kept" : "stop point: no sign of life from the mod's script for 10 s, its stop point is left alone"); LogLine(l);
    }
    return alive;
}
static void ReadStop()
{
    HANDLE f = KeptHandle(g_stopFile, "native_stop.txt");
    if (f == INVALID_HANDLE_VALUE) return;
    char buf[64] = {};
    DWORD got = 0;
    SetFilePointer(f, 0, 0, 0);
    if (!ReadFile(f, buf, 63, &got, 0) || got == 0) return;
    DWORD i = 0;
    bool neg = false;
    if (buf[i] == '-') { neg = true; i++; }
    long v = 0, seq = 0;
    DWORD d0 = i;
    while (i < got && buf[i] >= '0' && buf[i] <= '9') v = v * 10 + (buf[i++] - '0');
    if (i == d0 || i >= got || buf[i] != ' ') return;      // (a file being written: the last value stays)
    i++;
    DWORD s0 = i;
    while (i < got && buf[i] >= '0' && buf[i] <= '9') seq = seq * 10 + (buf[i++] - '0');
    if (i == s0 || i >= got || (buf[i] != '\n' && buf[i] != '\r')) return;
    g_stopAt = neg ? -1 : v;
    g_stopSeq = seq;
}
static void WriteStopState(u32 S, u32 n)
{
    if (S == g_stopLastS && n == g_stopLastN && g_stopSeq == g_stopLastSeq) return;
    g_stopLastS = S; g_stopLastN = n; g_stopLastSeq = g_stopSeq;
    if (!g_stopState) {
        char path[400];
        PathOf(path, "native_stop_state.txt");
        g_stopState = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    }
    if (g_stopState == INVALID_HANDLE_VALUE) return;
    Buf b; b.dec(g_stopSeq).str(" ").dec((long)S).str(" ").dec((long)n).str(" ").dec(g_stopAt).str("\n");
    DWORD w;
    SetFilePointer(g_stopState, 0, 0, 0);
    WriteFile(g_stopState, b.s, (DWORD)b.n, &w, 0);
    SetEndOfFile(g_stopState);
}
// Test (MPFEVER_TESTSPLIT=1): the batches above 1x are cut into other sizes (1 to the speed, by the step's number), as another
// game's would be near its stop points: do the games' scripts (the engine's events reach them per batch?) then drift apart?
// (only once the game has stood still once: the batch the engine makes right after loading, at the savegame's speed, is left whole,
// else the two games did not start at the same time)
static int g_testSplit = -1;
static bool g_splitArmed = false;
static bool g_standSkipOn = false;     // (the thunk's path for a stand was installed, see InstallNativeStop)
static volatile long g_stepInBatch = 0; // (the steps made in the batch under way, see InstallStepSnap)
extern "C" u32 StepsForBatch(void* time, u32 speed, u32 asked)
{
    u32 sp = speed > asked ? speed : asked;
    g_stepInBatch = 0;
    if (g_testSplit < 0) { g_testSplit = GetEnvironmentVariableA("MPFEVER_TESTSPLIT", 0, 0) > 0 ? 1 : 0; if (g_testSplit) { Buf l; l.str("stop point: TEST batches split (MPFEVER_TESTSPLIT)"); LogLine(l); } }
    if (g_testSplit && sp == 0) g_splitArmed = true;
    if (g_testSplit && g_splitArmed && sp > 1 && asked <= speed && g_getUpdRva && time) {
        u32 S0 = ((u32(*)(u64))(g_base + g_getUpdRva))((u64)time);
        sp = 1 + (S0 * 7 + S0 / 3) % sp;
    }
    ReadStop();
    if (g_stopSeq < 0 || !g_getUpdRva || !time || !StopAlive()) return sp;
    u32 S = ((u32(*)(u64))(g_base + g_getUpdRva))((u64)time);
    u32 n = sp;
    if (g_stopAt >= 0) {
        if ((long)S >= g_stopAt) n = 0;
        else if ((long)(S + sp) > g_stopAt) n = (u32)(g_stopAt - (long)S);
    }
    // A batch with no step because of the stop point (the game runs at a speed): StepsForBatch answers ~0, and the thunk skips the
    // still batch's update of the game's scripts (the engine calls them with a duration of 0 when a batch makes no step). A game
    // standing at its stop point ran its scripts at that time and another game did not: a contract that reached its goal there
    // was completed one step sooner on the standing game (tests 522 and 525 of 2026-10-27, "script:subventions"). The engine's own
    // work of that batch (0xbb28a0 with 0) still runs. OFF at first since 2026-10-27 evening (MPFEVER_STANDSKIP=1: on): with it,
    // 4 of about 17 tests drifted (towns, vehicles), none of 14 without; the call probably does more than the scripts.
    static int standSkip = -1;
    if (standSkip < 0) { char sv[4] = {}; standSkip = (GetEnvironmentVariableA("MPFEVER_STANDSKIP", sv, 3) > 0 && sv[0] == '1') ? 1 : 0; }
    if (n == 0 && sp > 0 && standSkip && g_standSkipOn) { WriteStopState(S, 0); return 0xFFFFFFFFu; }
    if (n != sp && sp > 0 && asked > speed) { Buf l; l.str("stop point: exact steps asked for (").dec((long)asked).str(") cut at the stop point"); LogLine(l); }
    if (n != sp && sp > 0) {
        long c = _InterlockedIncrement(&g_stopClamps);
        if (c <= 40 || c % 500 == 0) { Buf l; l.str("stop point: batch at step ").dec((long)S).str(" makes ").dec((long)n).str(" step(s) instead of ").dec((long)sp).str(" (stop point ").dec(g_stopAt).str(", ").dec(c).str(" so far)"); LogLine(l); }
    }
    if (g_stopAt >= 0 && (long)S > g_stopAt && g_stopLastS != S) { Buf l; l.str("stop point: the simulation is at step ").dec((long)S).str(", past its stop point ").dec(g_stopAt).str(": it stands there until the stop point moves past it (a game that must stay behind a leading one, or a stop point written late)"); LogLine(l); }
    WriteStopState(S, n);
    return n;
}
static void InstallNativeStop()
{
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_STOPPOINT", v, 3) > 0 && v[0] == '0') { Buf b; b.str("stop point: off (MPFEVER_STOPPOINT=0)"); LogLine(b); return; }
    // the steps function's reading of the speed: "mov rcx,[rbp+8] / mov rcx,[rcx+28h] / call speed / cmp eax,ebx / mov r12d,eax /
    // cmovl r12d,ebx / test r12d,r12d / jne" (ebx: the exact steps asked for, taken from their counter just before)
    u32 at = FindSigRva("48 8B 4D 08 48 8B 49 28 E8 ?? ?? ?? ?? 3B C3 44 8B E0 44 0F 4C E3 45 85 E4 75");
    if (!at) { Buf b; b.str("stop point: off (the steps function's speed reading not found)"); LogLine(b); return; }
    u8* site = (u8*)(g_base + at + 8);
    u8* target = site + 5 + *(i32*)(site + 1);
    // (the getter: "sub rsp,28h / mov rax,[rcx+10h] / mov rcx,[rcx+8] / mov edx,[rax] / call / mov eax,[rax+4]")
    static const u8 GETTER[] = { 0x48, 0x83, 0xEC, 0x28, 0x48, 0x8B, 0x41, 0x10, 0x48, 0x8B, 0x49, 0x08, 0x8B, 0x10, 0xE8 };
    if (site[0] != 0xE8 || memcmp(target, GETTER, sizeof(GETTER)) != 0 || target[19] != 0x8B || target[20] != 0x40 || target[21] != 0x04) { Buf b; b.str("stop point: off (the call at ").hex(at + 8).str(" is not the speed getter expected)"); LogLine(b); return; }
    u8* t = AllocNear(128);
    if (!t) { Buf b; b.str("stop point: off (no memory near the game's code)"); LogLine(b); return; }
    g_speedGet = (SpeedGetF)target;
    // The 14 bytes "call speed / cmp eax,ebx / mov r12d,eax / cmovl r12d,ebx" become a jump to this thunk (rsp is 16-aligned there):
    //   sub rsp,30h / mov [rsp+28h],rcx / mov rax,getter / call rax / mov edx,eax / mov r8d,ebx / mov rcx,[rsp+28h] /
    //   mov rax,StepsForBatch / call rax / add rsp,30h / mov r12d,eax / jmp back
    static const u8 A[] = { 0x48, 0x83, 0xEC, 0x30, 0x48, 0x89, 0x4C, 0x24, 0x28, 0x48, 0xB8 };
    static const u8 B[] = { 0xFF, 0xD0, 0x89, 0xC2, 0x41, 0x89, 0xD8, 0x48, 0x8B, 0x4C, 0x24, 0x28, 0x48, 0xB8 };
    //   cmp eax,-1 / je stand / ... ; stand: the still batch's own engine call (copied: "mov rcx,[rbp+8] / xor r8d,r8d /
    //   mov edx,[rcx+208h] / mov rcx,[rcx+18h] / call 0xbb28a0"), not its scripts' update, then the jump to the function's end
    static const u8 C[] = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x30, 0x83, 0xF8, 0xFF, 0x74, 0x11, 0x44, 0x8B, 0xE0, 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 };
    static const u8 STILL[] = { 0x45, 0x85, 0xE4, 0x75, 0x00, 0x48, 0x8B, 0x4D, 0x08, 0x45, 0x33, 0xC0, 0x8B, 0x91, 0x08, 0x02, 0x00, 0x00, 0x48, 0x8B, 0x49, 0x18, 0xE8 };
    u8* still = site + 14;
    bool stillOk = true;
    for (int i = 0; i < (int)sizeof(STILL); i++) if (i != 4 && still[i] != STILL[i]) stillOk = false;
    u8* stillCall = still + 22;                                   // the call of 0xbb28a0
    u8* stillJmp = still + 0x37;                                  // "jmp" to the function's end after the scripts' update
    if (stillOk && (stillJmp[0] != 0xE9 || stillJmp[-3] != 0xFF || stillJmp[-2] != 0x50 || stillJmp[-1] != 0x58)) stillOk = false;
    int k = 0;
    for (u8 x : A) t[k++] = x;
    *(u64*)(t + k) = (u64)target; k += 8;
    for (u8 x : B) t[k++] = x;
    *(u64*)(t + k) = (u64)&StepsForBatch; k += 8;
    for (u8 x : C) t[k++] = x;
    *(u64*)(t + k) = (u64)(site + 14); k += 8;
    if (stillOk) {
        for (int i = 5; i < 22; i++) t[k++] = still[i];
        t[k++] = 0x48; t[k++] = 0xB8; *(u64*)(t + k) = (u64)(stillCall + 5 + *(i32*)(stillCall + 1)); k += 8;
        t[k++] = 0xFF; t[k++] = 0xD0;
        t[k++] = 0xFF; t[k++] = 0x25; t[k++] = 0; t[k++] = 0; t[k++] = 0; t[k++] = 0;
        *(u64*)(t + k) = (u64)(stillJmp + 5 + *(i32*)(stillJmp + 1)); k += 8;
        g_standSkipOn = true;
    } else {
        // (the still batch not as expected: a stand never asks for the skip, the code after "je" is never reached)
        t[k++] = 0xCC;
    }
    FlushInstructionCache(GetCurrentProcess(), t, k);
    DWORD old;
    if (!VirtualProtect(site, 14, PAGE_EXECUTE_READWRITE, &old)) return;
    for (int i = 5; i < 14; i++) site[i] = 0x90;
    site[0] = 0xE9;
    *(i32*)(site + 1) = (i32)(t - (site + 5));
    VirtualProtect(site, 14, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, 14);
    // (a stop point of the game before: none until the mod writes one)
    char path[400];
    PathOf(path, "native_stop.txt");
    DeleteFileA(path);
    Buf b; b.str("stop point: the steps function's number of steps at ").hex(at + 8).str(" decided here (stop points of native_stop.txt)").str(g_standSkipOn ? "; a stand skips the scripts' update" : "; the still batch not as expected, a stand runs the scripts as before"); LogLine(b);
}

// Test (MPFEVER_STEPSNAP=1): the steps function, once per batch before its steps, copies the "current" values of a few
// components into their "previous" ones (0x159660 on build 40425, called with the engine). Two games whose batches are cut
// differently then see other "previous" values during their steps; a game whose batches were split at random (MPFEVER_TESTSPLIT)
// drifted from the other within 3 minutes, without any action (test 630). Here that copy is made again before every step after
// the first of a batch, as if every batch made one step: do the games then stay alike whatever their batches?
typedef u64 (*EngStepF)(void*, u32, u64);
typedef void (*StepSnapF)(void*);
static EngStepF g_engStep = 0;
static StepSnapF g_snap = 0;
static volatile long g_snapExtra = 0;
extern "C" u64 StepWithSnap(void* engine, u32 world, u64 dt)
{
    if (g_stepInBatch++ > 0 && g_snap) { g_snap(engine); _InterlockedIncrement(&g_snapExtra); }
    if (g_freeqExact) FreeqStep(engine);
    if (g_driftOn) DriftStep(engine);
    return g_engStep(engine, world, dt);
}
static void InstallStepSnap()
{
    // (also with MPFEVER_FREEQLOG, 0.6.8: the free-id queue written before each step that is a multiple of 50, the same steps on
    // every game whatever their batches)
    bool snapTest = GetEnvironmentVariableA("MPFEVER_STEPSNAP", 0, 0) > 0, freeq = GetEnvironmentVariableA("MPFEVER_FREEQLOG", 0, 0) > 0;
    if (!snapTest && !freeq && !g_driftOn) return;
    // the steps function's prologue: "... mov rcx,[rcx+18h] / call snapshot"; its loop: "mov rcx,[rbp+8] / mov r8,r14 /
    // mov edx,[rcx+208h] / mov rcx,[rcx+18h] / call step"
    u32 a = FindSigRva("48 8B 49 08 48 89 5C 24 60 4C 89 64 24 40 4C 89 6C 24 38 48 8B 49 18 E8");
    u32 b = FindSigRva("48 8B 4D 08 4D 8B C6 8B 91 08 02 00 00 48 8B 49 18 E8");
    if (!a || !b) { Buf l; l.str("step snapshot: off (not found)"); LogLine(l); return; }
    u8* snapCall = (u8*)(g_base + a + 23);
    u8* site = (u8*)(g_base + b + 17);
    if (snapTest) g_snap = (StepSnapF)(snapCall + 5 + *(i32*)(snapCall + 1));
    u8* target = site + 5 + *(i32*)(site + 1);
    u8* thunk = AllocNear(64);
    if (!thunk) return;
    g_engStep = (EngStepF)target;
    WriteAbsJump(thunk, (uptr)&StepWithSnap);
    FlushInstructionCache(GetCurrentProcess(), thunk, 14);
    DWORD old;
    if (!VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &old)) return;
    *(i32*)(site + 1) = (i32)(thunk - (site + 5));
    VirtualProtect(site, 5, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, 5);
    g_freeqExact = freeq;
    Buf l;
    if (snapTest) l.str("step snapshot: TEST the batch's copy of previous values made before every step (MPFEVER_STEPSNAP)");
    if (freeq) l.str(snapTest ? "; " : "").str("free-id queue logged before every step that is a multiple of 50 (MPFEVER_FREEQLOG)");
    if (g_driftOn) l.str(snapTest || freeq ? "; " : "").str("drift diagnostic: every step's digest kept (MPFEVER_DRIFTDIAG)");
    LogLine(l);
}

// ---------------------------------------------------------------- dedicated server without display (MPFEVER_HEADLESS=1)
// The game of a server started "without display" simulates the world and runs the mod's scripts as always, but nobody looks
// at it: its window is made hidden (and never full screen), the 3D world is not drawn (CRenderer::Render returns at once: the
// terrain, the buildings, the vehicles, shadows, water...), its sound is silent (every OpenAL gain at 0), and its frames are
// paced by a sleep: the main loop's own limiter (in CCore::UpdateTime) only waits until 4 ms have passed since the last frame,
// with a busy loop; the drawing's wait for the screen held the loop before. The interface's frame (its light 2D pass, the
// frame's begin and end) still runs, which keeps the graphics device's per-frame work as it is.
// MPFEVER_HEADLESS_FPS: frames per second at most (default 60). MPFEVER_HEADLESS_NOUPDATE=1 (an experiment): the renderer's
// per-frame preparation (CRenderer::NewUpdate: levels of detail, culling) is skipped too.
static bool g_headless = false;
static void* PatchImport(uptr base, const char* dll, const char* fn, void* repl);
typedef void* (*SdlCreateWindowF)(const char* title, int x, int y, int w, int h, u32 flags);
typedef void (*AlListenerfF)(int param, float value);
typedef void (*AlSourcefF)(u32 source, int param, float value);
typedef void (*AlSourcePlayF)(u32 source);
static SdlCreateWindowF g_sdlCreateWindow = 0;
static AlListenerfF g_alListenerf = 0;
static AlSourcefF g_alSourcef = 0;
static AlSourcePlayF g_alSourcePlay = 0;
static const int AL_GAIN_ = 0x100A;

extern "C" void* SdlCreateWindowHeadless(const char* title, int x, int y, int w, int h, u32 flags)
{
    // SDL_WINDOW_HIDDEN, and neither SDL_WINDOW_FULLSCREEN nor SDL_WINDOW_FULLSCREEN_DESKTOP (0x1, 0x1001)
    return g_sdlCreateWindow(title, x, y, w, h, (flags | 0x8) & ~0x1001u);
}
extern "C" int SdlSetWindowFullscreenHeadless(void*, u32) { return 0; }
extern "C" void AlListenerfHeadless(int param, float value) { g_alListenerf(param, param == AL_GAIN_ ? 0.0f : value); }
extern "C" void AlSourcefHeadless(u32 source, int param, float value) { g_alSourcef(source, param, param == AL_GAIN_ ? 0.0f : value); }
extern "C" void AlSourcePlayHeadless(u32 source)
{
    // (a source whose gain the game never set plays at 1, and so does the listener)
    if (g_alListenerf) g_alListenerf(AL_GAIN_, 0.0f);
    if (g_alSourcef) g_alSourcef(source, AL_GAIN_, 0.0f);
    g_alSourcePlay(source);
}
extern "C" void HeadlessYield() { Sleep(1); }

// in DllMain, before the game creates its window and opens its sound device: their imports
static void SetupHeadlessImports()
{
    char v[4];
    if (GetEnvironmentVariableA("MPFEVER_HEADLESS", v, 3) == 0 || v[0] != '1') return;
    g_headless = true;
    uptr base = (uptr)GetModuleHandleW(0);
    g_sdlCreateWindow = (SdlCreateWindowF)PatchImport(base, "SDL2.dll", "SDL_CreateWindow", (void*)&SdlCreateWindowHeadless);
    PatchImport(base, "SDL2.dll", "SDL_SetWindowFullscreen", (void*)&SdlSetWindowFullscreenHeadless);
    g_alListenerf = (AlListenerfF)PatchImport(base, "OpenAL32.dll", "alListenerf", (void*)&AlListenerfHeadless);
    g_alSourcef = (AlSourcefF)PatchImport(base, "OpenAL32.dll", "alSourcef", (void*)&AlSourcefHeadless);
    g_alSourcePlay = (AlSourcePlayF)PatchImport(base, "OpenAL32.dll", "alSourcePlay", (void*)&AlSourcePlayHeadless);
}

// (0.7.0, MPFEVER_HIDEDLC=1) the game without its DLCs: the DLCs (the Deluxe upgrade pack, the pre-order pack) are folders
// of the game's "dlcs" that it lists at its start (KERNEL32 FindFirstFileW from its own code) and activates in every game;
// their animals, people and vehicles make a world other than a player's without them (the reports of 2026-11-02 and
// 2026-11-04). With the switch, the listing of that folder finds nothing and the files under it are not there: this game
// runs as on a PC without DLCs. Read once, in DllMain, before the game lists its mods.
typedef HANDLE (WINAPI* FindFirstFileWF)(const wchar_t* name, void* data);
typedef DWORD (WINAPI* GetFileAttributesWF)(const wchar_t* name);
typedef BOOL (WINAPI* GetFileAttributesExWF)(const wchar_t* name, int level, void* info);
typedef HANDLE (WINAPI* FindFirstFileExWF)(const wchar_t* name, int level, void* data, int op, void* filter, DWORD flags);
static FindFirstFileWF g_findFirstFileW = 0;
static FindFirstFileExWF g_findFirstFileExW = 0, g_findFirstFileExWCrt = 0;
static GetFileAttributesExWF g_getFileAttributesExW2 = 0;
typedef HANDLE (WINAPI* CreateFileWF)(const wchar_t* name, DWORD access, DWORD share, void* sa, DWORD disp, DWORD flags, HANDLE tmpl);
static CreateFileWF g_createFileW[4] = {};
static wchar_t g_dlcFirst[200];   // the first path refused (said in native.log)
static GetFileAttributesWF g_getFileAttributesW = 0;
static GetFileAttributesExWF g_getFileAttributesExW = 0;
static volatile long g_dlcHidden = 0;
// a path with a "dlcs" part (between separators, the last part included), whatever the case
static bool InDlcsRaw(const wchar_t* p);
static bool InDlcs(const wchar_t* p)
{
    bool r = InDlcsRaw(p);
    if (r && !g_dlcFirst[0]) { int i = 0; for (; p[i] && i < 199; i++) g_dlcFirst[i] = p[i]; g_dlcFirst[i] = 0; }
    return r;
}
static bool InDlcsRaw(const wchar_t* p)
{
    if (!p) return false;
    int i = 0;
    for (;;) {
        // at the start of a part
        int j = i;
        while (p[j] && p[j] != L'\\' && p[j] != L'/') j++;
        if (j - i == 4) {
            wchar_t a = p[i] | 0x20, b = p[i + 1] | 0x20, c = p[i + 2] | 0x20, d = p[i + 3] | 0x20;
            if (a == L'd' && b == L'l' && c == L'c' && d == L's') return true;
        }
        if (!p[j]) return false;
        i = j + 1;
    }
}
extern "C" HANDLE WINAPI FindFirstFileWHide(const wchar_t* name, void* data)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(2); return INVALID_HANDLE_VALUE; }   // ERROR_FILE_NOT_FOUND
    return g_findFirstFileW(name, data);
}
extern "C" DWORD WINAPI GetFileAttributesWHide(const wchar_t* name)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(2); return (DWORD)0xFFFFFFFF; }   // INVALID_FILE_ATTRIBUTES
    return g_getFileAttributesW(name);
}
extern "C" BOOL WINAPI GetFileAttributesExWHide(const wchar_t* name, int level, void* info)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(2); return 0; }
    return g_getFileAttributesExW(name, level, info);
}
// (the C++ library's directory listing and file status, std::filesystem in MSVCP140.dll, which the game's mod list uses)
extern "C" HANDLE WINAPI FindFirstFileExWHide(const wchar_t* name, int level, void* data, int op, void* filter, DWORD flags)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(2); return INVALID_HANDLE_VALUE; }
    return g_findFirstFileExW(name, level, data, op, filter, flags);
}
extern "C" BOOL WINAPI GetFileAttributesExWHide2(const wchar_t* name, int level, void* info)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(2); return 0; }
    return g_getFileAttributesExW2(name, level, info);
}
// (files opened by path: the exe's own, the C++ library's and the C runtime's)
template <int K> HANDLE WINAPI CreateFileWHide(const wchar_t* name, DWORD access, DWORD share, void* sa, DWORD disp, DWORD flags, HANDLE tmpl)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(3); return INVALID_HANDLE_VALUE; }   // ERROR_PATH_NOT_FOUND
    return g_createFileW[K](name, access, share, sa, disp, flags, tmpl);
}
extern "C" HANDLE WINAPI FindFirstFileExWHideCrt(const wchar_t* name, int level, void* data, int op, void* filter, DWORD flags)
{
    if (InDlcs(name)) { _InterlockedIncrement(&g_dlcHidden); SetLastError(2); return INVALID_HANDLE_VALUE; }
    return g_findFirstFileExWCrt(name, level, data, op, filter, flags);
}
static void SetupHideDlc()
{
    char v[4];
    if (GetEnvironmentVariableA("MPFEVER_HIDEDLC", v, 3) == 0 || v[0] != '1') return;
    uptr base = (uptr)GetModuleHandleW(0);
    g_findFirstFileW = (FindFirstFileWF)PatchImport(base, "KERNEL32.dll", "FindFirstFileW", (void*)&FindFirstFileWHide);
    g_getFileAttributesW = (GetFileAttributesWF)PatchImport(base, "KERNEL32.dll", "GetFileAttributesW", (void*)&GetFileAttributesWHide);
    g_getFileAttributesExW = (GetFileAttributesExWF)PatchImport(base, "KERNEL32.dll", "GetFileAttributesExW", (void*)&GetFileAttributesExWHide);
    g_createFileW[0] = (CreateFileWF)PatchImport(base, "KERNEL32.dll", "CreateFileW", (void*)&CreateFileWHide<0>);
    uptr crt = (uptr)GetModuleHandleW(L"ucrtbase.dll");
    if (crt) {
        g_createFileW[1] = (CreateFileWF)PatchImport(crt, "api-ms-win-core-file-l1-1-0.dll", "CreateFileW", (void*)&CreateFileWHide<1>);
        if (!g_createFileW[1]) g_createFileW[1] = (CreateFileWF)PatchImport(crt, "KERNEL32.dll", "CreateFileW", (void*)&CreateFileWHide<1>);
        // (_wfindfirst, which the game imports from the C runtime)
        g_findFirstFileExWCrt = (FindFirstFileExWF)PatchImport(crt, "api-ms-win-core-file-l1-1-0.dll", "FindFirstFileExW", (void*)&FindFirstFileExWHideCrt);
    }
    uptr cpp = (uptr)GetModuleHandleW(L"msvcp140.dll");
    if (cpp) {
        g_findFirstFileExW = (FindFirstFileExWF)PatchImport(cpp, "KERNEL32.dll", "FindFirstFileExW", (void*)&FindFirstFileExWHide);
        g_getFileAttributesExW2 = (GetFileAttributesExWF)PatchImport(cpp, "KERNEL32.dll", "GetFileAttributesExW", (void*)&GetFileAttributesExWHide2);
        g_createFileW[2] = (CreateFileWF)PatchImport(cpp, "KERNEL32.dll", "CreateFileW", (void*)&CreateFileWHide<2>);
    }
}
// (said in native.log by Init, once the log is open)
static void LogHideDlc()
{
    char v[4];
    if (GetEnvironmentVariableA("MPFEVER_HIDEDLC", v, 3) == 0 || v[0] != '1') return;
    Buf b; b.str("DLCs hidden from the game (MPFEVER_HIDEDLC=1): ").str(g_findFirstFileW ? "listing hooked" : "listing NOT hooked").str(g_findFirstFileExW ? ", C++ library hooked" : ", C++ library NOT hooked")
        .str(g_createFileW[0] ? ", opens hooked" : ", opens NOT hooked").str(g_createFileW[1] ? " (C runtime too)" : "")
        .str(", ").dec((i64)g_dlcHidden).str(" reads refused so far");
    if (g_dlcFirst[0]) { b.str(", the first: "); for (int i = 0; g_dlcFirst[i] && b.n < 900; i++) b.s[b.n++] = (char)(g_dlcFirst[i] < 128 ? g_dlcFirst[i] : '?'); }
    LogLine(b);
}

static DWORD WINAPI HideDlcLater(void*) { Sleep(60000); LogHideDlc(); return 0; }

// a void function of the game made to return at once (its first byte a "ret")
static bool SkipFunction(const char* what, const char* sig)
{
    u32 at = FindSigRva(sig);
    Buf b;
    if (!at) { b.str("without display: ").str(what).str(" not found: still done"); LogLine(b); return false; }
    u8* p = (u8*)(g_base + at);
    DWORD old;
    if (!VirtualProtect(p, 1, PAGE_EXECUTE_READWRITE, &old)) return false;
    *p = 0xC3;
    VirtualProtect(p, 1, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 1);
    b.str("without display: ").str(what).str(" at ").hex(at).str(" skipped");
    LogLine(b);
    return true;
}

// in Init (the game's code runs no frame yet): the drawing skipped, the frames paced
static void InstallHeadless()
{
    if (!g_headless) return;
    {
        Buf b; b.str("without display (dedicated server): window ").str(g_sdlCreateWindow ? "hidden" : "NOT hidden (SDL_CreateWindow not imported)")
            .str(", sound ").str(g_alSourcePlay ? "silent" : "NOT silent (OpenAL not imported)");
        LogLine(b);
    }
    SkipFunction("CRenderer::Render (the 3D world)", "48 8B C4 55 53 56 57 41 54 41 55 41 56 41 57 48 8D A8 A8 F3 FF FF");
    { char v[4]; if (GetEnvironmentVariableA("MPFEVER_HEADLESS_NOUPDATE", v, 3) > 0 && v[0] == '1')
        SkipFunction("CRenderer::NewUpdate (the renderer's preparation)", "48 89 5C 24 10 48 89 74 24 18 57 41 54 41 55 41 56 41 57 B8 80 14 00 00"); }
    // CCore::UpdateTime's wait for the next frame: "mov rax,rbx / sub rax,[r15] / cmp rax,0FA0h / jge ... / call _Thrd_yield":
    // its 4000 us become the frame time asked for, and the yield a 1 ms sleep
    u32 fps = 60;
    { char v[8] = {}; DWORD n = GetEnvironmentVariableA("MPFEVER_HEADLESS_FPS", v, 7); if (n > 0 && n < 7) { u32 f = 0; for (DWORD i = 0; i < n && v[i] >= '0' && v[i] <= '9'; i++) f = f * 10 + (v[i] - '0'); if (f >= 5 && f <= 250) fps = f; } }
    u32 at = FindSigRva("48 8B C3 49 2B 07 48 3D A0 0F 00 00 0F 8D ?? ?? ?? ?? E8");
    u8* thunk = at ? AllocNear(16) : 0;
    if (!thunk) { Buf b; b.str("without display: the frame limiter not found, the frames are not paced"); LogLine(b); return; }
    WriteAbsJump(thunk, (uptr)&HeadlessYield);
    FlushInstructionCache(GetCurrentProcess(), thunk, 14);
    u8* p = (u8*)(g_base + at);
    DWORD old;
    if (!VirtualProtect(p, 23, PAGE_EXECUTE_READWRITE, &old)) return;
    *(u32*)(p + 8) = 1000000 / fps;
    *(i32*)(p + 19) = (i32)(thunk - (p + 23));
    VirtualProtect(p, 23, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 23);
    Buf b; b.str("without display: frames paced at ").dec(fps).str(" per second at most (limiter at ").hex(at).str(")"); LogLine(b);
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
    // (0.8.7 diagnostic build: every thread's floating-point control, see FpuDiag; MPFEVER_FPUDIAG=1 or MPFEVER_FINEDIAG=1)
    {
        char e1[4] = {}, e2[4] = {};
        GetEnvironmentVariableA("MPFEVER_FPUDIAG", e1, 3);
        GetEnvironmentVariableA("MPFEVER_FINEDIAG", e2, 3);
        if (e1[0] == '1' || e2[0] == '1') { HANDLE ft = CreateThread(0, 0, FpuDiag, 0, 0, 0); if (ft) CloseHandle(ft); }
    }
    { Buf t; t.str(g_scriptPoolPatched ? "game scripts: own pool, one worker" : "game scripts: pool NOT patched"); LogLine(t); }
    if (g_simPoolA || g_simPoolB) { Buf t; t.str("pool sizes forced: ").hex(g_simPoolA).str(",").hex(g_simPoolB); LogLine(t); }
    { Buf t; t.str(g_mathOther ? "mathematics: another C runtime's (MPFEVER_MATHDLL), functions " : (g_mathPatched ? "mathematics: MPFever's own, functions " : "mathematics: Windows' (not replaced), functions ")).hex(g_mathPatched); LogLine(t); }
    LogHideDlc();
    if (g_findFirstFileW) { HANDLE th = CreateThread(0, 0, HideDlcLater, 0, 0, 0); if (th) CloseHandle(th); }
    if (g_threads) { Buf t; t.str("engine told it has ").hex(g_threads).str(" processor(s)").str(g_realGetSystemInfo ? "" : " (GetSystemInfo not patched)"); LogLine(t); }
    InstallHeadless();
    bool known = SelectBuild(fh->TimeDateStamp);
    if (g_sigReportN) { g_sigReport[g_sigReportN] = 0; Buf w; w.str("game build ").hex(fh->TimeDateStamp).str(": ").str(g_sigReport); LogLine(w); }
    if (!known) {
        Buf w; w.str(g_bySig ? "unknown game build, its places not all found by their signatures: hooks off" : "unknown game build: hooks off"); LogLine(w);
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
        if (g_clearPos) InstallClearSame();
        if (InstallDetour(RVA_PREITER, P_PREITER, sizeof(P_PREITER), (void*)&PreIterDetour, (void**)&g_preIterOrig)) g_preIterOn = true;
        if (RVA_REPL) g_replOn = InstallDetour(RVA_REPL, P_REPL, sizeof(P_REPL), (void*)&ReplDetour, (void**)&g_replOrig);
    }
    InstallSmoothPacing();
    InstallNativeStop();
    InstallDriftDiag();
    InstallStepSnap();
    HookWordReads();
    // (found by their own signatures, on any build where those match exactly once)
    InstallOrderFixes();
    InstallIndustryDemand();
    InstallDecisionSync();
    InstallFreshIds();
    PatchSaveCleanup();
    InstallNoGameAutosave();
    InstallAirCache();
    InstallModuleBuilderGuard();
    if (g_layout) InstallToolCompany();
    if (g_layout) InstallHudShare();
    if (g_layout) InstallStopSnap();
    if (g_layout) InstallOpenNet();
    InstallVehicleWear();
    InstallFastSpan();
    InstallFastSave();
    { Buf b; b.str(g_luaSeedFixed ? "Lua string hash seed: fixed (same table order on every game)" : "Lua string hash seed: NOT fixed"); LogLine(b); }
    if (g_layout && RVA_MONEYCHECK) InstallDetour(RVA_MONEYCHECK, P_MONEYCHECK, sizeof(P_MONEYCHECK), (void*)&MoneyCheckDetour, (void**)&g_moneyOrig);
    if (g_layout && RVA_LINES) InstallDetour(RVA_LINES, P_LINES, sizeof(P_LINES), (void*)&LinesDetour, (void**)&g_linesOrig);
    if (g_layout && RVA_ADDENTITY && RVA_REMOVEENTITY && GetEnvironmentVariableA("MPFEVER_ENTWATCH", 0, 0) > 0) {
        // ((0.8.2) hooked already by the drift diagnostic, see InstallDriftDiag)
        if (!g_entDetours) {
            InstallDetour(RVA_ADDENTITY, P_ADDENTITY, sizeof(P_ADDENTITY), (void*)&AddEntityDetour, (void**)&g_addEntOrig);
            InstallDetour(RVA_REMOVEENTITY, P_REMOVEENTITY, sizeof(P_REMOVEENTITY), (void*)&RemoveEntityDetour, (void**)&g_remEntOrig);
            g_entDetours = true;
        }
        g_entWatch = true;
        if (GetEnvironmentVariableA("MPFEVER_ENTLOG", 0, 0) > 0) {
            char path[400];
            PathOf(path, "entseq.txt");
            g_entFile = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
            g_entLog = g_entFile != INVALID_HANDLE_VALUE;
        }
    }
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

// ---------------------------------------------------------------- the same mathematics on every Windows
// The game imports sin, exp, pow... from Windows' C runtime (api-ms-win-crt-math), whose results differ in their last digits
// from one Windows to the other (builds 22621 and 26100: pow, atan2, asin, acos, sinh, cosh, exp2, log2f...): two players on
// two Windows drifted apart in their towns whatever MPFever did. The imports are pointed at MPFever's own functions
// (mpf_math.cpp), the same code on every PC. MPFEVER_MATH=0: Windows' as before. MPFEVER_MATHDLL=<file> (tests): the functions of
// another copy of ucrtbase.dll instead (to play one game with another Windows' mathematics).
struct MpfMathEntry { const char* name; void* fn; };
extern "C" const MpfMathEntry g_mpfMath[];
static void PatchMath(uptr base)
{
    char v[8];
    if (GetEnvironmentVariableA("MPFEVER_MATH", v, 7) > 0 && v[0] == '0') return;
    HMODULE other = 0;
    char pa[300];
    DWORD n = GetEnvironmentVariableA("MPFEVER_MATHDLL", pa, 299);
    if (n > 0 && n < 299) {
        wchar_t path[300];
        for (DWORD i = 0; i <= n; i++) path[i] = (wchar_t)(unsigned char)pa[i];   // (a test path: ASCII)
        other = LoadLibraryW(path);
    }
    for (int i = 0; g_mpfMath[i].name; i++) {
        void* fn = g_mpfMath[i].fn;
        if (other) { fn = (void*)GetProcAddress(other, g_mpfMath[i].name); if (!fn) continue; }
        if (PatchImport(base, "api-ms-win-crt-math-l1-1-0.dll", g_mpfMath[i].name, fn)) g_mathPatched++;
    }
    g_mathOther = other != 0;
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
    // (another build: the jump's distance may differ)
    if (!p) { u32 r = g_knownPool ? g_knownPool : FindSigRva("83 F8 08 0F 8D ?? ?? ?? ?? C7 44 24 20 01 00 00 00 E8"); if (r) p = (u8*)(base + r); }
    if (!p || p[0] != 0x83 || p[1] != 0xF8 || p[2] != 0x08 || p[3] != 0x0F || p[4] != 0x8D || p[17] != 0xE8) return;
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
// base/init.lua's require pushes the path on _ug_filePathRequireStack before loading it and only pops it when the file ran
// to its end: a failed load left mpfever_1:: on the stack, and the game's own "::/gui/..." requires then looked in our mod
// and the menu crashed. The prefix puts the stack (and _currentModIdTr) back as they were when our file fails.
static const char MENU_PREFIX[] = "do local s, m = _ug_filePathRequireStack, _currentModIdTr local n = s and #s local ok, e = pcall(require, \"mpfever_1::/mpfever_menu.lua\") if not ok then if s then for i = #s, n + 1, -1 do s[i] = nil end end _currentModIdTr = m print(\"[MPFEVER-MENU] \" .. tostring(e)) end end ";
static volatile long g_menuInjected = 0;
// the same for the in-game pause menu (gui/main/pause_menu.tl, in a game's UI state): mpfever_1::/mpfever_pause.lua catches
// the id of its main page as it is registered, so that mpfever_ui.script.lua can put MPFever's card beside it
static const char PAUSE_PREFIX[] = "do local s, m = _ug_filePathRequireStack, _currentModIdTr local n = s and #s local ok, e = pcall(require, \"mpfever_1::/mpfever_pause.lua\") if not ok then if s then for i = #s, n + 1, -1 do s[i] = nil end end _currentModIdTr = m print(\"[MPFEVER-PAUSE] \" .. tostring(e)) end end ";
static volatile long g_pauseInjected = 0;

struct MenuReader { LuaReader reader; void* data; int stage; const char* held; size_t heldSize; const char* prefix; size_t prefixSize; };

extern "C" const char* MenuReaderFn(void* L, void* ud, size_t* size)
{
    MenuReader* m = (MenuReader*)ud;
    if (m->stage == 0) {
        size_t n = 0;
        const char* blk = m->reader(L, m->data, &n);
        if (!blk || n == 0 || blk[0] == 0x1B) { m->stage = 2; *size = n; return blk; }   // empty or precompiled: untouched
        m->held = blk; m->heldSize = n; m->stage = 1;
        *size = m->prefixSize;
        return m->prefix;
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
        MenuReader m = { reader, data, 0, 0, 0, MENU_PREFIX, sizeof(MENU_PREFIX) - 1 };
        int r = g_luaLoadOrig(L, MenuReaderFn, &m, chunkname, mode);
        if (_InterlockedIncrement(&g_menuInjected) == 1) { Buf b; b.str("main menu: multiplayer page added (").str(chunkname).str(")"); LogLine(b); }
        return r;
    }
    if (chunkname && EndsWith(chunkname, "gui/main/pause_menu.tl")) {
        MenuReader m = { reader, data, 0, 0, 0, PAUSE_PREFIX, sizeof(PAUSE_PREFIX) - 1 };
        int r = g_luaLoadOrig(L, MenuReaderFn, &m, chunkname, mode);
        if (_InterlockedIncrement(&g_pauseInjected) == 1) { Buf b; b.str("pause menu: MPFever card hook added (").str(chunkname).str(")"); LogLine(b); }
        return r;
    }
    return g_luaLoadOrig(L, reader, data, chunkname, mode);
}

// Lua 5.2.2 (the game's) seeds the hash of its strings with the time and memory addresses (makeseed, lstate.c), for every
// Lua state: the order in which pairs() walks a table with string keys then differs from one game to the other, and so
// does every decision a game script or a construction script takes in such a loop (towns, industries, the lanes of a
// new industry were numbered differently on two games). makeseed is made to return one constant (MPFEVER_LUASEED=0: not).
static const u32 RVA_LUA_MAKESEED = 0x2fc8fe0;     // build 40420, only caller lua_newstate (g->seed = makeseed(L))
static const u8 P_LUA_MAKESEED[] = { 0x40, 0x53, 0x48, 0x83, 0xEC, 0x50, 0x48, 0x8B, 0x05, 0x4B, 0x4A, 0xD2, 0x00, 0x48, 0x33, 0xC4,
                                     0x48, 0x89, 0x44, 0x24, 0x48, 0x48, 0x8B, 0xD9, 0x33, 0xC9 };
static void PatchLuaSeed(uptr base)
{
    char v[4] = {};
    if (GetEnvironmentVariableA("MPFEVER_LUASEED", v, 3) > 0 && v[0] == '0') return;
    u8* f = (u8*)(base + RVA_LUA_MAKESEED);
    if (memcmp(f, P_LUA_MAKESEED, sizeof(P_LUA_MAKESEED)) != 0) {
        // another build: found by its signature (the same code, but for the distance to the security cookie at +9)
        u32 r = RVA_LUA_MAKESEED_SIG ? RVA_LUA_MAKESEED_SIG : FindSigRva("40 53 48 83 EC 50 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 44 24 48 48 8B D9 33 C9");
        if (!r) return;
        f = (u8*)(base + r);
        for (int i = 0; i < (int)sizeof(P_LUA_MAKESEED); i++) if ((i < 9 || i > 12) && f[i] != P_LUA_MAKESEED[i]) return;
    }
    const u8 code[] = { 0xB8, 0x56, 0x46, 0x50, 0x4D, 0xC3 };    // mov eax, 'MPFV' ; ret
    DWORD prot;
    if (!VirtualProtect(f, sizeof(code), PAGE_EXECUTE_READWRITE, &prot)) return;
    memcpy(f, code, sizeof(code));
    VirtualProtect(f, sizeof(code), prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), f, sizeof(code));
    g_luaSeedFixed = true;
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
            PatchMath(g_base);
            PatchLuaSeed(g_base);
            SetupHeadlessImports();
            SetupHideDlc();
            u8* ll = FindUnique(g_base, P_LUA_LOAD, (int)sizeof(P_LUA_LOAD), g_knownLua);
            if (ll) { RVA_LUA_LOAD = (u32)((uptr)ll - g_base); InstallDetour(RVA_LUA_LOAD, P_LUA_LOAD, sizeof(P_LUA_LOAD), (void*)&LuaLoadDetour, (void**)&g_luaLoadOrig); }
        }
        HANDLE t = CreateThread(0, 0, Init, 0, 0, 0);
        if (t) CloseHandle(t);
    }
    return 1;
}
