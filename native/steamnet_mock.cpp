// A stand-in for steam_api64.dll's networking functions, linked with the real mpf_steamnet.cpp into out\steamnet_mock.dll
// (steamnet_test_build.bat) so that steamnet_test.py can check the Steam core without the game: commands, status file,
// dial-back and first lines, bytes both ways, backpressure, closes, the self-test, IP mode, the shutdown hook, fail-closed.
// Connections stay in the process (P2P by virtual port, IP by port); a connection delivers at its SendRateMax, refuses a
// message above its SendBufferSize (LimitExceeded, 25), and status callbacks run inside RunCallbacks, as Steam's can.

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

#define EXP extern "C" __declspec(dllexport)

static char g_dir[300]; static int g_dirLen = 0;
static HANDLE g_log = 0; static volatile long g_logLock = 0;
extern "C" void MpfSessionPath(char* out, const char* name)
{
    int k = 0; for (int i = 0; i < g_dirLen; i++) out[k++] = g_dir[i];
    out[k++] = '\\'; for (int i = 0; name[i]; i++) out[k++] = name[i]; out[k] = 0;
}
extern "C" void MpfLogText(const char* t, int n)
{
    if (!g_log) return;
    char line[1100]; int k = 0;
    SYSTEMTIME st; GetLocalTime(&st);
    line[k++] = (char)('0' + st.wMinute / 10); line[k++] = (char)('0' + st.wMinute % 10); line[k++] = ':';
    line[k++] = (char)('0' + st.wSecond / 10); line[k++] = (char)('0' + st.wSecond % 10); line[k++] = '.';
    line[k++] = (char)('0' + st.wMilliseconds / 100); line[k++] = (char)('0' + st.wMilliseconds / 10 % 10); line[k++] = (char)('0' + st.wMilliseconds % 10); line[k++] = ' ';
    for (int i = 0; i < n && k < 1090; i++) line[k++] = t[i];
    line[k++] = '\r'; line[k++] = '\n';
    while (_InterlockedExchange(&g_logLock, 1)) Sleep(0);
    DWORD w; SetFilePointer(g_log, 0, 0, FILE_END); WriteFile(g_log, line, (DWORD)k, &w, 0);
    _InterlockedExchange(&g_logLock, 0);
}
static void Log(const char* s) { int n = 0; while (s[n]) n++; MpfLogText(s, n); }

// ---------------------------------------------------------------- model
typedef void (*Cb)(SnStatusChanged*);
struct MMsg { MMsg* next; u32 n; u8* data; };
struct MConn {
    bool used, freed; u32 h, peer, listen; int state; Cb cb; int reason; char dbg[128];
    i32 rate, sendBuf, tmoInit, tmoConn; bool ip; u64 sid; int flags;
    MMsg *outHead, *outTail; u64 outBytes; i64 budget; u64 lastAt;
    MMsg *inHead, *inTail;
};
struct MListen { bool used; u32 h; int vport; bool ip; u16 port; SnConfig opt[16]; int nOpt; };
struct MEv { u32 h; int state, old, reason; char dbg[128]; };
static MConn g_c[512]; static MListen g_l[32]; static u32 g_nextH = 100;
static MEv g_ev[8192]; static int g_evN = 0;
static u64 g_mySid = 0;
static void (*g_dbg)(int, const char*) = 0;
static volatile long g_shutdownCalled = 0;
static long g_dropNext = 0;   // test: the next SendMessage calls fail with a hard error

static MConn* C(u32 h) { for (auto& c : g_c) if (c.used && !c.freed && c.h == h) return &c; return 0; }
static MConn* NewC() { for (auto& c : g_c) if (!c.used) { memset(&c, 0, sizeof(c)); c.used = true; c.h = g_nextH++; c.rate = 256 << 10; c.sendBuf = 512 << 10; c.lastAt = GetTickCount64(); return &c; } return 0; }
static void Post(MConn* c, int st)
{
    int old = c->state; c->state = st;
    if (c->cb && g_evN < 8192) { MEv& e = g_ev[g_evN++]; e.h = c->h; e.state = st; e.old = old; e.reason = c->reason; memcpy(e.dbg, c->dbg, 128); }
}
static void Apply(MConn* c, int n, const SnConfig* o)
{
    for (int i = 0; i < n; i++) {
        switch (o[i].id) {
        case 201: c->cb = (Cb)o[i].v.p; break;
        case 10: case 11: c->rate = o[i].v.i; break;
        case 9: c->sendBuf = o[i].v.i; break;
        case 24: c->tmoInit = o[i].v.i; break;
        case 25: c->tmoConn = o[i].v.i; break;
        }
    }
}
static void FreeQ(MMsg*& head, MMsg*& tail) { while (head) { MMsg* n = head->next; HeapFree(GetProcessHeap(), 0, head); head = n; } tail = 0; }
static void Push(MConn* to, MMsg* m) { m->next = 0; if (to->inTail) to->inTail->next = m; else to->inHead = m; to->inTail = m; }
static void Deliver(MConn* c, bool all)
{
    u64 now = GetTickCount64();
    i64 add = (i64)c->rate * (i64)(now - c->lastAt) / 1000; c->lastAt = now;
    c->budget += add; if (c->budget > c->rate / 4 + (512 << 10)) c->budget = c->rate / 4 + (512 << 10);
    MConn* p = c->peer ? C(c->peer) : 0;
    while (c->outHead && (all || c->budget >= (i64)c->outHead->n)) {
        MMsg* m = c->outHead; c->outHead = m->next; if (!c->outHead) c->outTail = 0;
        c->outBytes -= m->n; c->budget -= m->n;
        if (p) Push(p, m); else HeapFree(GetProcessHeap(), 0, m);
    }
}

static int g_sock = 1, g_utils = 2;
EXP void* SteamAPI_SteamNetworkingSockets_SteamAPI_v012() { return &g_sock; }
EXP void* SteamAPI_SteamNetworkingUtils_SteamAPI_v004() { return &g_utils; }
EXP void* SteamInternal_FindOrCreateUserInterface(i32, const char*) { return 0; }
EXP i32 SteamAPI_GetHSteamUser() { return 1; }

static u32 Listen(int vport, bool ip, u16 port, int n, const SnConfig* o)
{
    for (auto& l : g_l) if (!l.used) {
        memset(&l, 0, sizeof(l)); l.used = true; l.h = g_nextH++; l.vport = vport; l.ip = ip; l.port = port;
        l.nOpt = n > 16 ? 16 : n; memcpy(l.opt, o, sizeof(SnConfig) * l.nOpt);
        return l.h;
    }
    return 0;
}
EXP u32 SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(void*, int vport, int n, const SnConfig* o) { return Listen(vport, false, 0, n, o); }
EXP u32 SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP(void*, const SnIPAddr* a, int n, const SnConfig* o) { return Listen(0, true, a->port, n, o); }
static u32 Connect(bool ip, int vport, u16 port, u64 sid, int n, const SnConfig* o)
{
    MConn* c = NewC(); if (!c) return 0;
    Apply(c, n, o); c->ip = ip; c->sid = ip ? 0 : g_mySid; c->flags = ip ? 8 : 12;
    Post(c, 1);
    MListen* L = 0;
    for (auto& l : g_l) if (l.used && l.ip == ip && (ip ? l.port == port : (l.vport == vport && sid == g_mySid))) L = &l;
    if (!L) { c->reason = 5003; memcpy(c->dbg, "mock: nobody listens there", 27); Post(c, 5); return c->h; }
    MConn* s = NewC(); if (!s) return 0;
    Apply(s, L->nOpt, L->opt); s->ip = ip; s->sid = g_mySid; s->flags = c->flags; s->listen = L->h;
    s->peer = c->h; c->peer = s->h;
    Post(s, 1);
    return c->h;
}
EXP u32 SteamAPI_ISteamNetworkingSockets_ConnectP2P(void*, const SnIdentity* who, int vport, int n, const SnConfig* o) { return Connect(false, vport, 0, who->sid, n, o); }
EXP u32 SteamAPI_ISteamNetworkingSockets_ConnectByIPAddress(void*, const SnIPAddr* a, int n, const SnConfig* o) { return Connect(true, 0, a->port, 0, n, o); }
EXP int SteamAPI_ISteamNetworkingSockets_AcceptConnection(void*, u32 h)
{
    MConn* s = C(h); if (!s) return 8;
    if (s->state != 1 || !s->listen) return 11;
    MConn* c = C(s->peer);
    Post(s, 3);
    if (c) { Post(c, 2); Post(c, 3); }
    return 1;
}
EXP bool SteamAPI_ISteamNetworkingSockets_CloseConnection(void*, u32 h, int reason, const char* dbg, bool linger)
{
    MConn* c = C(h); if (!c) return false;
    MConn* p = c->peer ? C(c->peer) : 0;
    if (linger) Deliver(c, true); else FreeQ(c->outHead, c->outTail);
    if (p && p->state >= 1 && p->state <= 3) {
        p->reason = reason ? reason : 1000; memset(p->dbg, 0, 128);
        if (dbg) { int i = 0; for (; i < 127 && dbg[i]; i++) p->dbg[i] = dbg[i]; }
        Post(p, 4);
    }
    FreeQ(c->inHead, c->inTail);
    c->freed = true; c->used = false;
    return true;
}
EXP bool SteamAPI_ISteamNetworkingSockets_CloseListenSocket(void*, u32 l)
{
    for (auto& L : g_l) if (L.used && L.h == l) {
        L.used = false;
        for (auto& c : g_c) if (c.used && !c.freed && c.listen == l) {
            MConn* p = c.peer ? C(c.peer) : 0;
            if (p && p->state >= 1 && p->state <= 3) { p->reason = 4001; memcpy(p->dbg, "mock: listen socket closed", 27); Post(p, 5); }
            FreeQ(c.inHead, c.inTail); FreeQ(c.outHead, c.outTail); c.freed = true; c.used = false;
        }
        return true;
    }
    return false;
}
EXP void SteamAPI_ISteamNetworkingSockets_SetConnectionName(void*, u32, const char*) {}
EXP int SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(void*, u32 h, const void* p, u32 n, int flags, i64*)
{
    MConn* c = C(h); if (!c) return 8;
    if (c->state == 4 || c->state == 5) return 3;
    if (c->state != 3) return 11;
    if (n > (512u << 10) || !(flags & 8)) return 8;
    if (g_dropNext > 0) { g_dropNext--; return 2; }
    if (c->outBytes + n > (u64)c->sendBuf) return 25;
    MMsg* m = (MMsg*)HeapAlloc(GetProcessHeap(), 0, sizeof(MMsg) + n);
    m->n = n; m->data = (u8*)(m + 1); memcpy(m->data, p, n); m->next = 0;
    if (c->outTail) c->outTail->next = m; else c->outHead = m;
    c->outTail = m; c->outBytes += n;
    return 1;
}
struct MsgBlock { SnMessage m; MMsg* q; };
static void MockRelease(SnMessage* m) { MsgBlock* b = (MsgBlock*)m; HeapFree(GetProcessHeap(), 0, b->q); HeapFree(GetProcessHeap(), 0, b); }
EXP int SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(void*, u32 h, SnMessage** out, int max)
{
    MConn* c = C(h); if (!c) return -1;
    int k = 0;
    while (k < max && c->inHead) {
        MMsg* q = c->inHead; c->inHead = q->next; if (!c->inHead) c->inTail = 0;
        MsgBlock* b = (MsgBlock*)HeapAlloc(GetProcessHeap(), 0, sizeof(MsgBlock)); memset(b, 0, sizeof(*b));
        b->q = q; b->m.data = q->data; b->m.size = (i32)q->n; b->m.conn = h; b->m.release = &MockRelease;
        out[k++] = &b->m;
    }
    return k;
}
static void Fill(MConn* c, SnConnInfo* i, int state)
{
    memset(i, 0, sizeof(*i));
    if (c->ip) { i->remote.type = 1; i->remote.size = 18; i->remote.ip.ip[10] = 0xff; i->remote.ip.ip[11] = 0xff; i->remote.ip.ip[12] = 127; i->remote.ip.ip[15] = 1; i->remote.ip.port = 55555; }
    else { i->remote.type = 16; i->remote.size = 8; i->remote.sid = c->sid; }
    i->listen = c->listen; i->state = state; i->endReason = c->reason; memcpy(i->endDebug, c->dbg, 128); i->flags = c->flags;
}
EXP bool SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(void*, u32 h, SnConnInfo* out) { MConn* c = C(h); if (!c) return false; Fill(c, out, c->state); return true; }
// test (0.7.7, the rate control): every connection's remote quality and bytes waiting, as a relay would report them (q < 0: real)
static float g_fakeQ = -1; static i32 g_fakePend = 0;
EXP void TestQuality(int qPercent, int pend) { g_fakeQ = qPercent < 0 ? -1.0f : qPercent / 100.0f; g_fakePend = pend; }
EXP int SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus(void*, u32 h, SnRealTime* rt, int, void*)
{
    MConn* c = C(h); if (!c) return 8;
    memset(rt, 0, sizeof(*rt));
    rt->state = c->state; rt->ping = 1; rt->qLocal = rt->qRemote = 1.0f; rt->sendRate = c->rate; rt->pendRel = (i32)c->outBytes;
    if (g_fakeQ >= 0) { rt->qRemote = g_fakeQ; if (g_fakePend > rt->pendRel) rt->pendRel = g_fakePend; }
    return 1;
}
EXP void SteamAPI_ISteamNetworkingSockets_RunCallbacks(void*)
{
    for (auto& c : g_c) if (c.used && !c.freed) Deliver(&c, false);
    static MEv evs[8192];
    int n = g_evN; memcpy(evs, g_ev, sizeof(MEv) * n); g_evN = 0;
    for (int i = 0; i < n; i++) {
        MConn* c = C(evs[i].h); if (!c || !c->cb) continue;
        static SnStatusChanged s;
        Fill(c, &s.info, evs[i].state);
        s.conn = c->h; s.info.endReason = evs[i].reason; memcpy(s.info.endDebug, evs[i].dbg, 128); s.oldState = evs[i].old;
        c->cb(&s);
    }
}
EXP int SteamAPI_ISteamNetworkingSockets_InitAuthentication(void*) { return 100; }
EXP int SteamAPI_ISteamNetworkingSockets_GetAuthenticationStatus(void*, SnAuthStatus* s) { if (s) { memset(s, 0, sizeof(*s)); s->avail = 100; } return 100; }
EXP void SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(void*) {}
EXP int SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(void*, SnRelayStatus* s) { if (s) { memset(s, 0, sizeof(*s)); s->avail = 100; } return 100; }
EXP bool SteamAPI_ISteamNetworkingUtils_SetConnectionConfigValueInt32(void*, u32 h, int id, i32 v)
{
    MConn* c = C(h); if (!c) return false;
    if (id == 10 || id == 11) c->rate = v; else if (id == 9) c->sendBuf = v; else if (id == 25) c->tmoConn = v;
    return true;
}
EXP bool SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32(void*, int id, i32 v)
{
    char t[80] = "mock: global int "; int k = 17; k += (id >= 10) ? (t[k] = (char)('0' + id / 10), 1) : 0; t[k++] = (char)('0' + id % 10); t[k++] = '=';
    char d[12]; int m = 0; u32 x = (u32)v; do { d[m++] = (char)('0' + x % 10); x /= 10; } while (x); while (m) t[k++] = d[--m]; t[k] = 0; Log(t);
    return true;
}
EXP bool SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueFloat(void*, int id, float v)
{
    int c = (int)(v * 100.0f + 0.5f);
    char t[80] = "mock: global float "; int k = 19; t[k++] = (char)('0' + id % 10); t[k++] = '='; t[k++] = (char)('0' + c / 1000 % 10); t[k++] = (char)('0' + c / 100 % 10); t[k++] = '.';
    t[k++] = (char)('0' + c / 10 % 10); t[k++] = (char)('0' + c % 10); t[k] = 0; Log(t);
    return true;
}
struct NameT { int id; const char* name; int type; };
static const NameT NAMES[] = {
    { 201, "Callback_ConnectionStatusChanged", 5 }, { 24, "TimeoutInitial", 1 }, { 25, "TimeoutConnected", 1 }, { 9, "SendBufferSize", 1 },
    { 10, "SendRateMin", 1 }, { 11, "SendRateMax", 1 }, { 47, "RecvBufferSize", 1 }, { 52, "IPLocalHost_AllowWithoutAuth", 1 },
    { 104, "P2P_Transport_ICE_Enable", 1 }, { 4, "FakePacketLag_Send", 1 }, { 2, "FakePacketLoss_Send", 3 }, { 42, "FakeRateLimit_Send_Rate", 1 } };
static int g_renameId = 0;   // test: this id gets another name (the core must refuse to start when it is a needed one)
EXP void TestRename(int id) { g_renameId = id; }
EXP const char* SteamAPI_ISteamNetworkingUtils_GetConfigValueInfo(void*, int id, int* type, int* scope)
{
    for (auto& n : NAMES) if (n.id == id) { if (type) *type = n.type; if (scope) *scope = (id == 2 || id == 4 || id == 42) ? 1 : 4; return id == g_renameId ? "SomethingElse" : n.name; }
    return 0;
}
EXP int SteamAPI_ISteamNetworkingUtils_GetConfigValue(void*, int id, int scope, i64 obj, int* type, void* out, u64* size)
{
    MConn* c = scope == 4 ? C((u32)obj) : 0; if (!c) return -2;
    i32 v = id == 10 || id == 11 ? c->rate : id == 9 ? c->sendBuf : id == 24 ? c->tmoInit : id == 25 ? c->tmoConn : -1;
    if (v == -1) return -1;
    *type = 1; *(i32*)out = v; *size = 4;
    return 1;
}
EXP void SteamAPI_ISteamNetworkingUtils_SetDebugOutputFunction(void*, int level, void (*fn)(int, const char*)) { g_dbg = fn; if (fn && level >= 4) fn(4, "mock: debug output reaches the log"); }
EXP void SteamAPI_SteamNetworkingIdentity_SetSteamID64(SnIdentity* id, u64 sid) { id->type = 16; id->size = 8; id->sid = sid; }
EXP void SteamAPI_SteamNetworkingIPAddr_SetIPv4(SnIPAddr* a, u32 ip, u16 port)
{
    memset(a->ip, 0, 10); a->ip[10] = a->ip[11] = 0xff; a->ip[12] = (u8)(ip >> 24); a->ip[13] = (u8)(ip >> 16); a->ip[14] = (u8)(ip >> 8); a->ip[15] = (u8)ip; a->port = port;
}
static int g_noFriends = 0;
EXP void TestNoFriends(int v) { g_noFriends = v; }
EXP bool SteamAPI_ISteamFriends_HasFriend(void*, u64, int flags) { return !g_noFriends && flags == 4; }
EXP void SteamAPI_Shutdown() { _InterlockedExchange(&g_shutdownCalled, 1); Log("mock: SteamAPI_Shutdown called"); }
// (SteamAPI_SteamNetworkingMessage_t_Release: steamnet_mock_asm.asm, the same bytes as SDK 1.61's)

// ---------------------------------------------------------------- test entry points
extern "C" bool MpfSteamNetStart(HMODULE sa, u64 sid, void* friends);
extern "C" void MpfSteamShutdownHook();
extern "C" void MpfSteamNetSetShutdown(void* original);
extern "C" char __ImageBase;
static int g_friends = 3;
EXP int TestStart(u64 sid, const char* dir, int hook)
{
    g_mySid = sid;
    int i = 0; for (; dir[i] && i < 290; i++) g_dir[i] = dir[i]; g_dir[i] = 0; g_dirLen = i;
    char p[400]; MpfSessionPath(p, "native.log");
    g_log = CreateFileA(p, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    bool ok = MpfSteamNetStart((HMODULE)&__ImageBase, sid, &g_friends);
    if (ok && hook) MpfSteamNetSetShutdown(hook == 1 ? (void*)&SteamAPI_Shutdown : 0);
    return ok ? 1 : 0;
}
EXP void TestShutdown() { MpfSteamShutdownHook(); }
EXP int TestShutdownCalled() { return g_shutdownCalled; }
EXP void TestFailSends(int n) { g_dropNext = n; }
EXP int TestOpenConns() { int n = 0; for (auto& c : g_c) if (c.used && !c.freed) n++; return n; }
extern "C" BOOL WINAPI MockMain(HMODULE, DWORD, void*) { return 1; }
