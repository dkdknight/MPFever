// MPFever native module, Steam networking: MPFever's connections carried by Steam (P2P and the Steam Datagram Relay) inside
// the game, for players who cannot reach each other over TCP (no forwarded port).
//
// The game's own steam_api64.dll (Steamworks SDK 1.61, initialised and pumped by the game: no second SteamAPI_Init) gives
// ISteamNetworkingSockets. Each Steam connection is tunnelled to a loopback TCP connection that this module dials itself, so
// that MPFever.exe sees one more stream whose first line is "steamtun ..." and nothing else of its protocol changes:
// - the host's game listens on the Steam virtual ports 28090 (main link) and 28091 (bulk transfers) and dials MPFever.exe's
//   relay port (127.0.0.1) for every connection it accepts;
// - a player's game connects to the host's Steam ID and dials the one-shot listener MPFever.exe opened for that attempt.
// The bytes go through unchanged both ways: a Steam message is a slice of the stream (at most 256 KiB), never parsed. The
// game never listens on a socket (no firewall question) and MPFever.exe picks every loopback port (two games on one PC).
//
// Control, in the session folder: MPFever.exe appends commands to steamnet_cmd.txt ("<seq>\t<command>\t<arguments>", each
// line read once, by its offset); this module rewrites steamnet_status.txt every 500 ms (its last line "end=1"). Nothing
// happens on the network until a command asks for it, except Steam's relay network access, started with the game so that
// the relays' pings are known when the player hosts or joins.
//
// Every Steam call made by MPFever's code holds one lock (g_steamLock, shared with mpfever_native's SteamThread), and the
// game's SteamAPI_Shutdown is hooked (its import) so that no such call is under way when Steam goes away as the game closes.
// Anything unexpected (a missing export, a configuration value the library names differently, a layout check that fails)
// leaves Steam networking off with one line in native.log; the rest of the module works as before.
#include "win.h"

extern "C" void* memcpy(void*, const void*, size_t);
extern "C" void* memset(void*, int, size_t);
extern "C" int memcmp(const void*, const void*, size_t);
extern "C" void MpfLogText(const char* text, int n);           // (mpfever_native.cpp) one line of native.log
extern "C" void MpfSessionPath(char* out, const char* name);   // (mpfever_native.cpp) a file of the session folder

namespace {
// the same tiny text builder as mpfever_native.cpp's (this file is a translation unit of its own)
struct Buf {
    char s[1024];
    int n = 0;
    Buf& str(const char* t) { while (*t && n < 1000) s[n++] = *t++; return *this; }
    Buf& dec(i64 v) { if (v < 0) { s[n++] = '-'; v = -v; } char t[21]; int k = 0; do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k && n < 1000) s[n++] = t[--k]; return *this; }
    Buf& udec(u64 v) { char t[21]; int k = 0; do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k && n < 1000) s[n++] = t[--k]; return *this; }
    Buf& ch(char c) { if (n < 1000) s[n++] = c; return *this; }
    Buf& tenths(i64 v) { if (v < 0) { ch('-'); v = -v; } return dec(v / 10).ch('.').dec(v % 10); }   // 123 -> "12.3"
    Buf& q2(float q) { if (!(q >= 0)) return str("-1"); int c = (int)(q * 100.0f + 0.5f); return dec(c / 100).ch('.').ch((char)('0' + c / 10 % 10)).ch((char)('0' + c % 10)); }
    Buf& ip(u32 a, u16 port) { dec(a >> 24).ch('.').dec((a >> 16) & 255).ch('.').dec((a >> 8) & 255).ch('.').dec(a & 255); return port ? ch(':').dec(port) : *this; }
    // text from Steam or a file, on one line (control characters as spaces)
    Buf& text(const char* t, int max) { for (int i = 0; i < max && t[i] && n < 1000; i++) s[n++] = (t[i] >= 32 && t[i] < 127) ? t[i] : ' '; return *this; }
};
}
static void LogLine(Buf& b) { MpfLogText(b.s, b.n); }

static bool Same(const char* a, const char* b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static int Len(const char* s) { int n = 0; while (s[n]) n++; return n; }
static void Copy(char* d, const char* s, int max) { int i = 0; for (; i < max - 1 && s[i]; i++) d[i] = s[i]; d[i] = 0; }
static bool Num(const char* s, u64* out)
{
    u64 v = 0; int i = 0;
    for (; s[i]; i++) { if (s[i] < '0' || s[i] > '9' || i >= 20) return false; v = v * 10 + (u64)(s[i] - '0'); }
    *out = v;
    return i > 0;
}
static bool IsHex(const char* s, int maxLen)
{
    int i = 0;
    for (; s[i]; i++) if (i >= maxLen || !((s[i] >= '0' && s[i] <= '9') || ((s[i] | 32) >= 'a' && (s[i] | 32) <= 'f'))) return false;
    return i > 0;
}
// "a.b.c.d:port" (or "a.b.c.d" when the port may be left out): the address in host order
static bool ParseAddr(const char* s, u32* ip, u16* port, bool needPort)
{
    u32 a = 0; int parts = 0; int i = 0;
    while (parts < 4) {
        u32 v = 0; int d = 0;
        while (s[i] >= '0' && s[i] <= '9' && d < 4) { v = v * 10 + (u32)(s[i] - '0'); i++; d++; }
        if (!d || v > 255) return false;
        a = (a << 8) | v; parts++;
        if (parts < 4) { if (s[i] != '.') return false; i++; }
    }
    u64 p = 0;
    if (s[i] == ':') { if (!Num(s + i + 1, &p) || p == 0 || p > 65535) return false; }
    else if (s[i] || needPort) return false;
    *ip = a; *port = (u16)p;
    return true;
}

static void* Alloc(u64 n) { return HeapAlloc(GetProcessHeap(), 0, n); }
static void Free(void* p) { if (p) HeapFree(GetProcessHeap(), 0, p); }

// ---------------------------------------------------------------- the library's functions (flat API: the interface first)

static struct Fns {
    void* (*socketsIface)();
    void* (*utilsIface)();
    void* (*findIface)(i32 user, const char* version);
    i32 (*getUser)();
    u32 (*listenP2P)(void* s, int vport, int n, const SnConfig* o);
    u32 (*connectP2P)(void* s, const SnIdentity* who, int vport, int n, const SnConfig* o);
    u32 (*listenIP)(void* s, const SnIPAddr* local, int n, const SnConfig* o);
    u32 (*connectIP)(void* s, const SnIPAddr* to, int n, const SnConfig* o);
    int (*accept)(void* s, u32 h);
    bool (*close)(void* s, u32 h, int reason, const char* why, bool linger);
    bool (*closeListen)(void* s, u32 l);
    void (*setName)(void* s, u32 h, const char* name);
    int (*send)(void* s, u32 h, const void* p, u32 n, int flags, i64* num);
    int (*receive)(void* s, u32 h, SnMessage** out, int max);
    bool (*info)(void* s, u32 h, SnConnInfo* out);
    int (*realTime)(void* s, u32 h, SnRealTime* out, int lanes, void* laneOut);
    void (*runCallbacks)(void* s);
    int (*initAuth)(void* s);
    int (*authStatus)(void* s, SnAuthStatus* out);
    void (*initRelay)(void* u);
    int (*relayStatus)(void* u, SnRelayStatus* out);
    bool (*setConnInt)(void* u, u32 h, int id, i32 v);
    bool (*setGlobalInt)(void* u, int id, i32 v);
    bool (*setGlobalFloat)(void* u, int id, float v);
    const char* (*cfgInfo)(void* u, int id, int* type, int* scope);
    int (*getCfg)(void* u, int id, int scope, i64 obj, int* type, void* out, u64* size);
    void (*setDebug)(void* u, int level, void (*fn)(int, const char*));
    void (*setSid)(SnIdentity* id, u64 sid);
    void (*setIPv4)(SnIPAddr* a, u32 ip, u16 port);
    void (*release)(SnMessage* m);
    bool (*hasFriend)(void* friends, u64 sid, int flags);
} F;

static struct Ws {
    int (WINAPI* startup)(u16, void*);
    SOCKET_ (WINAPI* socket)(int, int, int);
    int (WINAPI* connect)(SOCKET_, const sockaddr_in_*, int);
    int (WINAPI* send)(SOCKET_, const char*, int, int);
    int (WINAPI* recv)(SOCKET_, char*, int, int);
    int (WINAPI* closesocket)(SOCKET_);
    int (WINAPI* ioctlsocket)(SOCKET_, long, u32*);
    int (WINAPI* setsockopt)(SOCKET_, int, int, const char*, int);
    int (WINAPI* getsockopt)(SOCKET_, int, int, char*, int*);
    int (WINAPI* shutdown)(SOCKET_, int);
    int (WINAPI* poll)(WSAPOLLFD_*, u32, int);
    int (WINAPI* lastError)();
} W;

typedef void (*ShutdownF)();

// ---------------------------------------------------------------- state

static SRWLOCK_ g_steamLock;           // every Steam call of MPFever's code (this file, and SteamThread through MpfSteamEnter)
static SRWLOCK_ g_ringLock;            // the status-change ring (the callback may run on the game's thread, in SteamAPI_RunCallbacks)
static SRWLOCK_ g_statusLock;          // steamnet_status.txt (written by the loop, and by SteamThread when networking stops early)
static volatile long g_stop = 0;       // the game called SteamAPI_Shutdown: no Steam call any more, from anybody
static volatile long g_quit = 0;       // Steam networking turned off (the loop ends; rich presence and invitations go on)
static volatile long g_running = 0;    // the loop runs
static HMODULE g_sa = 0;
static void* g_sockets = 0;
static void* g_utils = 0;
static void* g_friends = 0;
static u64 g_mySid = 0;
static ShutdownF volatile g_origShutdown = 0;
static DWORD g_loopTid = 0;
static const char* volatile g_offWhy = 0;
static long g_debugLevel = 4;          // Steam's own messages logged from this level (4 warnings, 5 MPFEVER_STEAMNET_DEBUG=1)

enum { K_MAIN, K_BULK, K_TEST };
static const char* const KIND[] = { "main", "bulk", "test" };
static const int VPORT_MAIN = 28090, VPORT_BULK = 28091, VPORT_TEST = 28099;
static const u32 RING = 1u << 20;      // Steam -> loopback, per tunnel
static const u32 CHUNK = 256u << 10;   // loopback -> Steam: at most one Steam message (k_cbMaxSteamNetworkingSocketsMessageSizeSend is 512 KiB)

// settings (conf command): the defaults are the design's
static i32 g_rate[3] = { 1 << 20, 1 << 20, 1 << 20 };           // SendRateMin = SendRateMax at the start of a connection (header default 256K)
static i32 g_rateMaxBulk = 4 << 20, g_rateMaxFast = 32 << 20;   // the AIMD's ceilings (main: its own start rate; a LAN/local route: fast)
static i32 g_sendBuf[3] = { 1 << 20, 2 << 20, 1 << 20 };        // SendBufferSize: above it SendMessage says LimitExceeded, our backpressure
static i32 g_tmoInit = 30000;                                   // finding a relay route can take 10-20 s
static i32 g_tmoConn[3] = { 30000, 15000, 30000 };              // a short Wi-Fi blip does not close the main link
static i32 g_ice = -1;                                          // P2P_Transport_ICE_Enable: -1 = the player's Steam setting, 1 = relay only
static bool g_aimd = true;
static bool g_aimdIdle = true;   // (0.7.7) a main link is lowered only for its own data; MPFEVER_AIMDIDLE=0 / conf aimd_idle 0: as before

// configuration values used, checked by name against the library at the start (a self-check of the enumeration: an id the
// library names otherwise is never set; without the needed ones, Steam networking stays off)
struct CfgName { int id; const char* name; int type; bool needed; bool ok; };
static CfgName g_cfg[] = {
    { 201, "Callback_ConnectionStatusChanged", 5, true, false },
    { 24, "TimeoutInitial", 1, true, false },
    { 25, "TimeoutConnected", 1, true, false },
    { 9, "SendBufferSize", 1, true, false },
    { 10, "SendRateMin", 1, true, false },
    { 11, "SendRateMax", 1, true, false },
    { 47, "RecvBufferSize", 1, false, false },
    { 52, "IPLocalHost_AllowWithoutAuth", 1, false, false },
    { 104, "P2P_Transport_ICE_Enable", 1, false, false },
    { 4, "FakePacketLag_Send", 1, false, false },
    { 2, "FakePacketLoss_Send", 3, false, false },
    { 42, "FakeRateLimit_Send_Rate", 1, false, false },
};
static bool CfgOk(int id) { for (auto& c : g_cfg) if (c.id == id) return c.ok; return false; }

// ---------------------------------------------------------------- the status-change callback
// Set per object (option 201 on our listen sockets and connections, inherited by accepted connections), never globally: a
// global callback would replace another user's. Steam calls it inside ISteamNetworkingSockets::RunCallbacks (our loop calls it
// every cycle) or inside SteamAPI_RunCallbacks (the game's main thread): it only copies the event into a ring, no Steam call.

struct Ev { u32 conn, listen; i32 state, old, reason, idType; u64 sid; SnIPAddr ip; i32 flags; char debug[128]; };
static Ev g_ring[256];
static u32 g_ringHead = 0, g_ringN = 0;
static volatile long g_ringLost = 0, g_cbOurs = 0, g_cbOther = 0, g_polled = 0;

static void OnStatusChanged(SnStatusChanged* c)
{
    Ev e;
    e.conn = c->conn; e.listen = c->info.listen; e.state = c->info.state; e.old = c->oldState; e.reason = c->info.endReason;
    e.idType = c->info.remote.type; e.sid = c->info.remote.sid; e.ip = c->info.remote.ip; e.flags = c->info.flags;
    memcpy(e.debug, c->info.endDebug, 128); e.debug[127] = 0;
    AcquireSRWLockExclusive(&g_ringLock);
    if (g_ringN < 256) { g_ring[(g_ringHead + g_ringN) % 256] = e; g_ringN++; }
    else g_ringLost++;   // (the loop's GetConnectionInfo every 250 ms catches up on tracked connections)
    ReleaseSRWLockExclusive(&g_ringLock);
    _InterlockedIncrement(GetCurrentThreadId() == g_loopTid ? &g_cbOurs : &g_cbOther);
}

// Steam's own diagnostics, into native.log (thread-safe: LogLine only; at most 500 lines a game)
static volatile long g_dbgLines = 0;
static void OnSteamDebug(int type, const char* msg)
{
    long n = _InterlockedIncrement(&g_dbgLines);
    if (n > 501) return;
    Buf b;
    if (n == 501) b.str("steam networking: further messages of Steam's networking not logged");
    else b.str("steam networking says (").dec(type).str("): ").text(msg, 900);
    LogLine(b);
}

// ---------------------------------------------------------------- tunnels

enum { S_FREE, S_WAIT, S_DIAL, S_BRIDGE, S_DRAIN, S_CLOSED };
// S_WAIT: the Steam connection is being made (or was accepted); S_DIAL: Steam connected, the loopback connection is being
// made; S_BRIDGE: the bytes flow both ways; S_DRAIN: Steam closed, what it had delivered still goes to MPFever.exe;
// S_CLOSED: ended, kept 30 s for the status file (its code and reason)
static const char* const STATE[] = { "free", "connecting", "dialing", "connected", "closing", "closed" };
enum { R_OUT, R_IN, R_SOURCE, R_ECHO };   // a player's tunnel, a host's tunnel, the self-test's sender, its echo

struct Tunnel {
    int state, role, kind; bool ip;
    u32 h;                       // the Steam connection
    SOCKET_ s;                   // the loopback connection
    char id[40];                 // MPFever.exe's id of an outgoing tunnel, "in:<handle>" for an accepted one
    char peer[48];               // the remote: its Steam ID, or ip:a.b.c.d:port in IP mode
    u16 port;                    // the loopback port to dial
    char nonce[72];              // (a player's tunnel) MPFever.exe's nonce, written back in the first line
    int steamState;              // the last state seen (callback or poll)
    u64 stateAt;                 // when the tunnel's own state changed
    // Steam -> loopback: the messages received, copied into a ring that send() empties
    u8* down; u32 downHead, downLen; bool wantWrite;
    SnMessage* held[16]; int heldN, heldI; u32 heldOff; bool drained;
    // loopback -> Steam: one chunk read and not yet taken by Steam
    u8* up; u32 upN;
    short revents;
    // route and rate
    int flags, ping; float qr, ql; i32 pend, unacked, outBps, inBps;
    i32 rate; u64 aimdLogAt; int goodN;
    u64 bytesIn, bytesOut;
    int code; char why[128];
    // the self-test
    u64 total, sent, recvd, hashSent, hashRecv, rng, testStart, lastProgress;
};
static const int MAXT = 48;
static Tunnel g_t[MAXT];

// listen sockets (0 = none, k_HSteamListenSocket_Invalid)
static u32 g_lMain = 0, g_lBulk = 0, g_lIpMain = 0, g_lIpBulk = 0, g_lTest = 0;
static bool g_hosting = false, g_friendsOnly = false;
static u16 g_relayPort = 0;
static char g_secret[72];
static u64 g_listenCloseAt = 0, g_testListenCloseAt = 0;   // (unhost: the sockets close a little later, see Unhost)
// IP mode (tests on one PC: two games of one Steam account cannot reach each other by P2P)
static u32 g_ipListenIp = 0; static u16 g_ipListenPort = 0; static bool g_ipEcho = false;
static u32 g_ipToIp = 0; static u16 g_ipToPort = 0;
// the self-test
static int g_testState = 0;   // 0 none, 1 running, 2 passed, 3 failed
static const char* const TESTSTATE[] = { "none", "running", "ok", "fail" };
// the loop
static long g_loopHz = 0;
static char g_seq[48];
static int g_auth = 0, g_relay = 0;

static bool g_busy = false;          // bytes moved in this cycle (or wait to move): the loop turns again at once
static u64 Now() { return GetTickCount64(); }
// (0.6.7) the time since `at`, never negative: the loop reads `now` once at the top of a pass, and a state changed in that pass
// (Connected's SetState, from the callbacks run after it) gets a LATER Now(). `now - stateAt` then wrapped round as a u64 and the
// host's dial-back of a Steam connection failed at once, "the loopback port 28090 did not answer in 5 s": its launcher saw a
// loopback connection open and close with nothing in it, the player's join by Steam failed (session of 2026-11-01 00:49:30) and
// the port had to be forwarded by hand. Whenever a tick (15.6 ms) passed between the top of the pass and the callback
static u64 Since(u64 now, u64 at) { return now > at ? now - at : 0; }

static Tunnel* ByHandle(u32 h) { if (!h) return 0; for (auto& t : g_t) if (t.h == h && t.state != S_FREE && t.state != S_CLOSED) return &t; return 0; }
static Tunnel* ById(const char* id) { for (auto& t : g_t) if (t.state != S_FREE && t.state != S_CLOSED && Same(t.id, id)) return &t; return 0; }
static Tunnel* NewTunnel()
{
    Tunnel* t = 0;
    for (auto& x : g_t) if (x.state == S_FREE) { t = &x; break; }
    if (!t) for (auto& x : g_t) if (x.state == S_CLOSED && (!t || x.stateAt < t->stateAt)) t = &x;   // the oldest record goes
    if (!t) return 0;
    memset(t, 0, sizeof(*t));
    t->s = INVALID_SOCKET_; t->ping = -1; t->qr = t->ql = -1; t->stateAt = Now();
    return t;
}
static void SetState(Tunnel* t, int st) { t->state = st; t->stateAt = Now(); }
static bool IsOurListen(u32 l) { return l && (l == g_lMain || l == g_lBulk || l == g_lIpMain || l == g_lIpBulk || l == g_lTest); }

static void PeerText(char* out, int idType, u64 sid, const SnIPAddr& ip)
{
    Buf b;
    if (idType == 16) b.udec(sid);
    else if (idType == 1) b.str("ip:").ip(((u32)ip.ip[12] << 24) | ((u32)ip.ip[13] << 16) | ((u32)ip.ip[14] << 8) | ip.ip[15], ip.port);
    else b.str("unknown");
    b.s[b.n] = 0;
    Copy(out, b.s, 48);
}

static const char* RouteOf(int flags) { return (flags & 16) ? "relay" : (flags & 8) ? "lan" : "direct"; }

// options given to CreateListenSocket*/Connect* (16 bytes each: id, type, value)
static int Options(SnConfig* o, int kind, bool ip)
{
    int n = 0;
    auto put = [&](int id, int type) -> SnConfig& { SnConfig& c = o[n++]; c.id = id; c.type = type; c.v.l = 0; return c; };
    put(201, 5).v.p = (void*)&OnStatusChanged;
    put(24, 1).v.i = g_tmoInit;
    put(25, 1).v.i = g_tmoConn[kind];
    put(9, 1).v.i = g_sendBuf[kind];
    put(10, 1).v.i = g_rate[kind];
    put(11, 1).v.i = g_rate[kind];
    if (CfgOk(47)) put(47, 1).v.i = 8 << 20;      // above it, packets are dropped (the loop drains every cycle anyway)
    if (ip && CfgOk(52)) put(52, 1).v.i = 2;       // IP mode only: no authentication between two games of one PC
    if (g_ice != -1 && CfgOk(104)) put(104, 1).v.i = g_ice;
    return n;
}

static void ReleaseHeld(Tunnel* t)
{
    for (int i = t->heldI; i < t->heldN; i++) F.release(t->held[i]);
    t->heldN = t->heldI = 0; t->heldOff = 0;
}
// the tunnel's end (its Steam connection already closed by the caller): its resources go, its record stays 30 s
static void Finish(Tunnel* t, int code, const char* why)
{
    ReleaseHeld(t);
    if (t->s != INVALID_SOCKET_) { W.closesocket(t->s); t->s = INVALID_SOCKET_; }
    Free(t->down); Free(t->up); t->down = t->up = 0; t->downLen = t->upN = 0;
    if (why) { t->code = code; Copy(t->why, why, 128); }
    t->h = 0;
    SetState(t, S_CLOSED);
}
static void LogEnd(Tunnel* t, const char* what)
{
    Buf b; b.str("steam networking: ").str(t->id).str(" (").str(KIND[t->kind]).str(", ").str(t->peer).str(") ").str(what);
    if (t->code || t->why[0]) b.str(": ").dec(t->code).str(" ").text(t->why, 128);
    b.str(" (").udec(t->bytesOut).str(" bytes sent, ").udec(t->bytesIn).str(" received)");
    LogLine(b);
}

static void TestResult(bool ok, const char* why, Tunnel* t);

// ---------------------------------------------------------------- Steam -> loopback, loopback -> Steam

static u32 RingPut(Tunnel* t, const u8* p, u32 n)
{
    u32 room = RING - t->downLen;
    if (n > room) n = room;
    u32 at = (t->downHead + t->downLen) % RING, first = RING - at < n ? RING - at : n;
    memcpy(t->down + at, p, first);
    if (n > first) memcpy(t->down, p + first, n - first);
    t->downLen += n;
    return n;
}

// the messages Steam received (in order) into the ring, the ring into the loopback socket. false: the tunnel ended
static bool SteamToLoop(Tunnel* t)
{
    for (int guard = 0; guard < 64; guard++) {
        while (t->heldI < t->heldN) {
            SnMessage* m = t->held[t->heldI];
            u32 left = (u32)m->size - t->heldOff;
            u32 n = RingPut(t, (const u8*)m->data + t->heldOff, left);
            t->heldOff += n; t->bytesIn += n;
            if (n < left) break;   // the ring is full: the rest waits for the loopback socket
            F.release(m); t->heldI++; t->heldOff = 0;
        }
        if (t->heldI < t->heldN) break;
        t->heldN = t->heldI = 0;
        if (t->downLen == RING) break;
        int n = F.receive(g_sockets, t->h, t->held, 16);
        if (n <= 0) { t->drained = true; break; }
        t->heldN = n; g_busy = true;
    }
    t->wantWrite = false;
    while (t->downLen) {
        u32 first = RING - t->downHead < t->downLen ? RING - t->downHead : t->downLen;
        int r = W.send(t->s, (const char*)t->down + t->downHead, (int)first, 0);
        if (r > 0) { t->downHead = (t->downHead + (u32)r) % RING; t->downLen -= (u32)r; g_busy = true; continue; }
        if (W.lastError() == WSAEWOULDBLOCK_) { t->wantWrite = true; break; }
        // MPFever.exe went away: the Steam side is closed too
        if (t->h) F.close(g_sockets, t->h, 1000, "closed", true);
        Finish(t, 1000, "the loopback connection broke");
        LogEnd(t, "ended");
        return false;
    }
    return true;
}

// what MPFever.exe wrote, to Steam: one chunk at a time, kept while Steam's send buffer is full (SendMessage says
// LimitExceeded, 25), and the socket is not read meanwhile: TCP's own flow control then holds MPFever.exe back
static void LoopToSteam(Tunnel* t)
{
    for (int k = 0; k < 8; k++) {
        if (!t->upN) {
            int r = W.recv(t->s, (char*)t->up, (int)CHUNK, 0);
            if (r > 0) t->upN = (u32)r;
            else if (r < 0 && W.lastError() == WSAEWOULDBLOCK_) return;
            else {
                // MPFever.exe closed it (0) or it broke: Steam closes once what was sent is through (linger)
                F.close(g_sockets, t->h, 1000, "closed", true);
                Finish(t, 1000, r == 0 ? "closed by MPFever.exe" : "the loopback connection broke");
                LogEnd(t, "ended");
                return;
            }
        }
        // a read that emptied the socket ends a burst: no Nagle delay for it
        int res = F.send(g_sockets, t->h, t->up, t->upN, t->upN < CHUNK ? 9 : 8, 0);
        if (res == 1) { t->bytesOut += t->upN; t->upN = 0; g_busy = true; continue; }
        if (res == 25) { g_busy = true; return; }   // the send buffer is full: backpressure (tried again next cycle)
        if (res == 3 || res == 11) return;    // the connection is ending: its state change comes next
        Buf b; b.str("steam networking: ").str(t->id).str(": Steam refused a message (result ").dec(res).str(")"); LogLine(b);
        F.close(g_sockets, t->h, 1000, "send failed", false);
        Finish(t, 1000, "Steam refused a message");
        LogEnd(t, "ended");
        return;
    }
}

// ---------------------------------------------------------------- the self-test (selftest <MB>): a stream echoed back

static u64 Fnv(u64 h, const u8* p, u32 n) { for (u32 i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; } return h; }

static void PumpSource(Tunnel* t, u64 now)
{
    for (int k = 0; k < 8; k++) {
        if (!t->upN) {
            if (t->sent >= t->total) break;
            u64 left = t->total - t->sent;
            u32 n = left < CHUNK ? (u32)left : CHUNK;
            for (u32 i = 0; i < n; i += 8) {
                t->rng ^= t->rng << 13; t->rng ^= t->rng >> 7; t->rng ^= t->rng << 17;   // xorshift64
                u64 v = t->rng;
                for (u32 j = 0; j < 8 && i + j < n; j++) t->up[i + j] = (u8)(v >> (j * 8));
            }
            t->hashSent = Fnv(t->hashSent, t->up, n);
            t->upN = n;
        }
        int res = F.send(g_sockets, t->h, t->up, t->upN, t->upN < CHUNK ? 9 : 8, 0);
        if (res == 1) { t->sent += t->upN; t->bytesOut += t->upN; t->upN = 0; t->lastProgress = now; g_busy = true; continue; }
        if (res == 25) { g_busy = true; break; }
        if (res == 3 || res == 11) break;
        Buf b; b.str("Steam refused a message (result ").dec(res).str(")"); b.s[b.n] = 0;
        TestResult(false, b.s, t);
        return;
    }
    SnMessage* m[16];
    for (int guard = 0; guard < 64; guard++) {
        int n = F.receive(g_sockets, t->h, m, 16);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) { t->hashRecv = Fnv(t->hashRecv, (const u8*)m[i]->data, (u32)m[i]->size); t->recvd += (u32)m[i]->size; F.release(m[i]); }
        t->bytesIn = t->recvd; t->lastProgress = now; g_busy = true;
    }
    if (t->recvd >= t->total) TestResult(t->recvd == t->total && t->hashRecv == t->hashSent, "the echo differs from what was sent", t);
    else if (Since(now, t->lastProgress) > 30000) TestResult(false, "no progress for 30 s", t);
}

static void PumpEcho(Tunnel* t)
{
    for (int guard = 0; guard < 64; guard++) {
        if (t->heldI >= t->heldN) {
            t->heldN = t->heldI = 0;
            int n = F.receive(g_sockets, t->h, t->held, 1);
            if (n <= 0) return;
            t->heldN = 1;
        }
        SnMessage* m = t->held[0];
        int res = F.send(g_sockets, t->h, m->data, (u32)m->size, (u32)m->size < CHUNK ? 9 : 8, 0);
        g_busy = true;
        if (res != 1) return;   // full (kept for the next cycle), or the connection ends
        t->bytesIn += (u32)m->size; t->bytesOut += (u32)m->size;
        F.release(m); t->heldN = t->heldI = 0;
    }
}

static i64 ReadBack(u32 h, int id)
{
    i32 v = 0; int type = 0; u64 size = 4;
    int r = F.getCfg(g_utils, id, 4 /* connection */, (i64)h, &type, &v, &size);
    return (r == 1 || r == 2) ? v : -1;
}

static void TestResult(bool ok, const char* why, Tunnel* t)
{
    u64 ms = Now() - t->testStart; if (!ms) ms = 1;
    Buf b;
    if (ok) {
        b.str("steam networking: self-test passed: ").udec(t->total >> 20).str(" MB sent and echoed back intact in ").tenths((i64)(ms / 100))
         .str(" s (").tenths((i64)(t->total * 10000 / (ms * 1048576))).str(" MB/s each way, ").str(RouteOf(t->flags)).str(", ping ").dec(t->ping).str(" ms)");
    } else {
        b.str("steam networking: self-test FAILED after ").tenths((i64)(ms / 100)).str(" s: ").str(why).str(" (").udec(t->sent >> 20).str(" MB sent, ")
         .udec(t->recvd >> 20).str(" MB back)");
    }
    LogLine(b);
    if (t->h) {
        // the values Steam keeps for this connection: those the options and the AIMD set
        i64 rmin = ReadBack(t->h, 10), rmax = ReadBack(t->h, 11);
        Buf v; v.str("steam networking: self-test connection values read back: SendRateMin ").dec(rmin).str(", SendRateMax ").dec(rmax)
            .str(" (set ").dec(t->rate).str(rmin == t->rate && rmax == t->rate ? ", the same" : ", DIFFERENT").str("), SendBufferSize ").dec(ReadBack(t->h, 9))
            .str(" (set ").dec(g_sendBuf[K_TEST]).str("), TimeoutInitial ").dec(ReadBack(t->h, 24)).str(" (set ").dec(g_tmoInit)
            .str("), TimeoutConnected ").dec(ReadBack(t->h, 25)).str(" (set ").dec(g_tmoConn[K_TEST]).str(")");
        LogLine(v);
        F.close(g_sockets, t->h, 1000, ok ? "self-test done" : "self-test failed", true);
    }
    Buf c; c.str("steam networking: status callbacks so far: ").dec(g_cbOurs).str(" in our loop, ").dec(g_cbOther).str(" on another thread, ")
        .dec(g_polled).str(" states found by polling, ").dec(g_ringLost).str(" lost");
    LogLine(c);
    Finish(t, ok ? 0 : 1000, ok ? "self-test passed" : why);
    g_testState = ok ? 2 : 3;
    if (g_lTest) g_testListenCloseAt = Now() + 5000;   // (closing it at once would cut the echo's connection ungracefully)
}

// ---------------------------------------------------------------- connection states

static bool Dial(Tunnel* t)
{
    SOCKET_ s = W.socket(AF_INET_, SOCK_STREAM_, IPPROTO_TCP_);
    if (s == INVALID_SOCKET_) return false;
    int one = 1, buf = 256 << 10; u32 nb = 1;
    W.setsockopt(s, IPPROTO_TCP_, TCP_NODELAY_, (const char*)&one, 4);
    W.setsockopt(s, SOL_SOCKET_, SO_SNDBUF_, (const char*)&buf, 4);
    W.setsockopt(s, SOL_SOCKET_, SO_RCVBUF_, (const char*)&buf, 4);
    W.ioctlsocket(s, FIONBIO_, &nb);
    // non-blocking even on loopback: a port nobody listens on makes Windows retry for about 2 s
    sockaddr_in_ a; memset(&a, 0, sizeof(a));
    a.family = AF_INET_; a.port = (u16)((t->port >> 8) | (t->port << 8)); a.addr = 0x0100007F;   // 127.0.0.1
    if (W.connect(s, &a, sizeof(a)) != 0 && W.lastError() != WSAEWOULDBLOCK_) { W.closesocket(s); return false; }
    t->s = s;
    return true;
}

static void Connected(Tunnel* t)
{
    SnConnInfo ci; memset(&ci, 0, sizeof(ci));
    if (F.info(g_sockets, t->h, &ci)) t->flags = ci.flags;
    SnRealTime rt; memset(&rt, 0, sizeof(rt));
    if (F.realTime(g_sockets, t->h, &rt, 0, 0) == 1) t->ping = rt.ping;
    t->rate = g_rate[t->kind];
    { Buf b; b.str("steam networking: ").str(t->id).str(" (").str(KIND[t->kind]).str(") connected ").str(t->role == R_OUT || t->role == R_SOURCE ? "to " : "from ")
        .str(t->peer).str(", ").str(RouteOf(t->flags)).str(", ping ").dec(t->ping).str(" ms"); LogLine(b); }
    if (t->role == R_SOURCE) { t->testStart = t->lastProgress = Now(); SetState(t, S_BRIDGE); return; }
    if (t->role == R_ECHO) { SetState(t, S_BRIDGE); return; }
    if (t->role == R_IN) t->port = g_relayPort;
    t->down = (u8*)Alloc(RING); t->up = (u8*)Alloc(CHUNK);
    if (!t->down || !t->up || !t->port || !Dial(t)) {
        F.close(g_sockets, t->h, 1002, "dial failed", false);
        Finish(t, 1002, !t->port ? "no loopback port to dial" : "the loopback connection could not be made");
        LogEnd(t, "ended");
        return;
    }
    SetState(t, S_DIAL);
}

// the loopback connection made (or not): the first line, then the bytes
static void DialCheck(Tunnel* t, u64 now)
{
    short ev = t->revents; t->revents = 0;
    int err = 0;
    if (ev & (POLLERR_ | POLLHUP_ | POLLNVAL_)) err = -1;
    else if (ev & POLLWRNORM_) { int len = 4; if (W.getsockopt(t->s, SOL_SOCKET_, SO_ERROR_, (char*)&err, &len) != 0) err = -1; }
    else if (Since(now, t->stateAt) > 5000) err = -2;
    else return;
    if (err) {
        F.close(g_sockets, t->h, 1002, "dial failed", false);
        Buf w; w.str("the loopback port ").dec(t->port).str(err == -2 ? " did not answer in 5 s" : " refused the connection"); w.s[w.n] = 0;
        Finish(t, 1002, w.s);
        LogEnd(t, "ended");
        return;
    }
    // "steamtun\t<who>\t{...}\n", a line of MPFever's own protocol (kind, from, Lua table): the host's relay checks the session
    // secret, a player's client its nonce
    Buf b;
    if (t->role == R_IN) b.str("steamtun\t").str(t->peer).str("\t{[\"k\"]=\"").str(g_secret).str("\",[\"kind\"]=\"").str(KIND[t->kind]).str("\",");
    else b.str("steamtun\t").str(t->id).str("\t{[\"n\"]=\"").str(t->nonce).str("\",");
    b.str("[\"route\"]=\"").str(RouteOf(t->flags)).str("\",[\"ping\"]=").dec(t->ping).str("}\n");
    RingPut(t, (const u8*)b.s, (u32)b.n);
    SetState(t, S_BRIDGE);
    Buf l; l.str("steam networking: ").str(t->id).str(" tunnelled to the loopback port ").dec(t->port); LogLine(l);
}

static void SteamClosed(Tunnel* t, int st)
{
    { Buf b; b.str("steam networking: ").str(t->id).str(st == 4 ? " closed by the other side: " : " lost: ").dec(t->code).str(" ").text(t->why, 128); LogLine(b); }
    if (t->role == R_SOURCE) { TestResult(false, "the connection closed", t); return; }
    if (t->state == S_BRIDGE && t->role != R_ECHO) { t->drained = false; SetState(t, S_DRAIN); return; }   // what was received still goes on
    F.close(g_sockets, t->h, 0, 0, false);
    Finish(t, t->code, 0);
    LogEnd(t, "ended");
}

static void OnState(Tunnel* t, int st, int reason, const char* debug)
{
    if (st == t->steamState) return;
    t->steamState = st;
    if (st == 3) { if (t->state == S_WAIT) Connected(t); }
    else if (st == 4 || st == 5 || st == 0 || st < 0) {
        if (t->state == S_DRAIN) return;
        t->code = reason; Copy(t->why, debug ? debug : "", 128);
        SteamClosed(t, st);
    }
}

// a connection to one of our listen sockets
static void Incoming(const Ev& e)
{
    int kind = K_MAIN; bool ip = false, test = false;
    if (e.listen == g_lBulk) kind = K_BULK;
    else if (e.listen == g_lIpMain) ip = true;
    else if (e.listen == g_lIpBulk) { ip = true; kind = K_BULK; }
    else if (e.listen == g_lTest) { test = true; kind = K_TEST; }
    bool echo = test || (ip && g_ipEcho);
    if (echo) kind = K_TEST;
    char peer[48]; PeerText(peer, e.idType, e.sid, e.ip);
    const char* refuse = 0; int code = 1004;
    if (!echo && !g_hosting) refuse = "not hosting";
    else if (!echo && !ip && g_friendsOnly && !(e.idType == 16 && F.hasFriend(g_friends, e.sid, 4 /* k_EFriendFlagImmediate */))) { refuse = "not a friend"; code = 1001; }
    Tunnel* t = refuse ? 0 : NewTunnel();
    if (!refuse && !t) refuse = "too many connections";
    if (refuse) {
        F.close(g_sockets, e.conn, code, refuse, false);
        Buf b; b.str("steam networking: connection from ").str(peer).str(" refused: ").str(refuse); LogLine(b);
        return;
    }
    // the current settings (conf) on the connection itself: the listen socket's were those of its creation
    F.setConnInt(g_utils, e.conn, 10, g_rate[kind]); F.setConnInt(g_utils, e.conn, 11, g_rate[kind]);
    F.setConnInt(g_utils, e.conn, 9, g_sendBuf[kind]); F.setConnInt(g_utils, e.conn, 25, g_tmoConn[kind]);
    int r = F.accept(g_sockets, e.conn);
    if (r != 1) {
        F.close(g_sockets, e.conn, 0, 0, false);
        Buf b; b.str("steam networking: connection from ").str(peer).str(" could not be accepted (result ").dec(r).str(")"); LogLine(b);
        return;
    }
    t->role = echo ? R_ECHO : R_IN; t->kind = kind; t->ip = ip; t->h = e.conn; t->steamState = 1;
    Copy(t->peer, peer, 48);
    { Buf b; b.str("in:").udec(e.conn); b.s[b.n] = 0; Copy(t->id, b.s, 40); }
    SetState(t, S_WAIT);
    { Buf n; n.str("MPFever ").str(KIND[kind]).str(" ").str(peer); n.s[n.n] = 0; F.setName(g_sockets, e.conn, n.s); }
    Buf b; b.str("steam networking: connection from ").str(peer).str(" accepted as ").str(t->id).str(" (").str(KIND[kind]).str(echo ? ", echo" : "").str(")"); LogLine(b);
}

static void DrainEvents()
{
    static Ev evs[256];
    u32 n = 0;
    AcquireSRWLockExclusive(&g_ringLock);
    while (g_ringN) { evs[n++] = g_ring[g_ringHead]; g_ringHead = (g_ringHead + 1) % 256; g_ringN--; }
    ReleaseSRWLockExclusive(&g_ringLock);
    for (u32 i = 0; i < n; i++) {
        const Ev& e = evs[i];
        Tunnel* t = ByHandle(e.conn);
        if (t) { OnState(t, e.state, e.reason, e.debug); continue; }
        if (!IsOurListen(e.listen)) continue;   // (a connection of ours already let go: its last states)
        if (e.state == 1) Incoming(e);
        else if (e.state == 4 || e.state == 5) F.close(g_sockets, e.conn, 0, 0, false);   // gone before it was accepted: freed
    }
}

// a safety net for lost events: the state of every tracked connection, every 250 ms
static void PollInfo()
{
    for (auto& t : g_t) {
        if (!t.h || t.state == S_FREE || t.state == S_CLOSED) continue;
        SnConnInfo ci;
        if (!F.info(g_sockets, t.h, &ci)) { _InterlockedIncrement(&g_polled); OnState(&t, 0, t.code, "the connection is gone"); continue; }
        if (ci.state != t.steamState) { _InterlockedIncrement(&g_polled); ci.endDebug[127] = 0; OnState(&t, ci.state, ci.endReason, ci.endDebug); }
    }
}

static void Pump(Tunnel* t, u64 now)
{
    switch (t->state) {
    case S_DIAL: g_busy = true; DialCheck(t, now); break;
    case S_BRIDGE:
        if (t->role == R_SOURCE) PumpSource(t, now);
        else if (t->role == R_ECHO) PumpEcho(t);
        else if (SteamToLoop(t)) LoopToSteam(t);
        break;
    case S_DRAIN:
        // the rest Steam had received, then the loopback side closes (MPFever.exe sees the end of its stream)
        g_busy = true;
        if (!SteamToLoop(t)) break;
        if ((t->drained && t->heldN == 0 && t->downLen == 0) || Since(now, t->stateAt) > 10000) {
            if (t->s != INVALID_SOCKET_) W.shutdown(t->s, SD_SEND_);
            F.close(g_sockets, t->h, 0, 0, false);
            Finish(t, t->code, 0);
            LogEnd(t, "ended");
        }
        break;
    }
}

// ---------------------------------------------------------------- rate control (AIMD, every second, on the sending side)
// On a relay, raising one connection's rate made things worse in FeverLink3's measure, parallel connections scaled almost
// linearly: a connection keeps its rate while the peer receives well (quality seen from the remote side), loses 30 % when
// fewer than 90 % of its packets arrive, and gains 15 % while data waits and nearly everything arrives, up to a ceiling
// (main: its start rate, bulk 4 MiB/s, a LAN or local route 32 MiB/s).

static void Aimd(Tunnel* t, const SnRealTime& rt, u64 now)
{
    if (!g_aimd || t->state != S_BRIDGE || t->rate <= 0) return;
    i32 ceil = (t->flags & 8) ? g_rateMaxFast : t->kind == K_BULK ? g_rateMaxBulk : g_rate[t->kind];
    i64 r = t->rate;
    float q = rt.qRemote;
    // (0.7.7) a main (or test) link with nothing of its own waiting is not lowered: its remote quality then says how the
    // relay does with the other links (a savegame on the bulk links, #133/#126), and the link stayed at 256 KB/s for
    // 5 to 7 minutes, when the next big acts came. Nearly everything arriving for 3 refreshes (3 s) gives its start rate
    // back, even idle. The bulk links: as before
    bool idle = g_aimdIdle && t->kind != K_BULK;
    bool restore = false;
    if (q >= 0 && q < 0.90f) { t->goodN = 0; if (!idle || rt.pendRel > (16 << 10)) r = r * 7 / 10; }
    else if (rt.pendRel > (64 << 10) && q > 0.98f) r = r * 115 / 100;
    if (idle && q >= 0.98f) { if (++t->goodN >= 3 && r < g_rate[t->kind]) { r = g_rate[t->kind]; restore = true; } }
    else if (q < 0.98f) t->goodN = 0;
    if (r < (256 << 10)) r = 256 << 10;
    if (r > ceil) r = ceil;
    if (r == t->rate) return;
    F.setConnInt(g_utils, t->h, 10, (i32)r);
    F.setConnInt(g_utils, t->h, 11, (i32)r);
    bool down = r < t->rate;
    t->rate = (i32)r;
    if (down || restore || Since(now, t->aimdLogAt) >= 10000) {
        t->aimdLogAt = now;
        Buf b; b.str("steam networking: ").str(t->id).str(" rate ").str(down ? "lowered" : restore ? "restored" : "raised").str(" to ").dec(ReadBack(t->h, 11)).str(" bytes/s (quality ")
            .q2(q).str(", ").dec(rt.pendRel).str(" bytes waiting)");
        LogLine(b);
    }
}

static void RefreshRt(bool aimd, u64 now)
{
    for (auto& t : g_t) {
        if (!t.h || (t.state != S_BRIDGE && t.state != S_DRAIN)) continue;
        SnRealTime rt;
        if (F.realTime(g_sockets, t.h, &rt, 0, 0) != 1) continue;
        t.ping = rt.ping; t.qr = rt.qRemote; t.ql = rt.qLocal; t.pend = rt.pendRel; t.unacked = rt.sentUnacked;
        t.outBps = (i32)rt.outBps; t.inBps = (i32)rt.inBps;
        if (aimd) Aimd(&t, rt, now);
    }
}

// ---------------------------------------------------------------- the status file

static HANDLE g_statusFile = 0;
static char g_status[32768];
static int g_statusN = 0;
static void StatusAdd(Buf& b) { if (g_statusN + b.n + 8 < (int)sizeof(g_status)) { memcpy(g_status + g_statusN, b.s, b.n); g_statusN += b.n; } }

static void WriteStatus(const char* text, int n)
{
    AcquireSRWLockExclusive(&g_statusLock);
    if (!g_statusFile) {
        // kept open (rewritten in place, then cut): MPFever.exe reads it with FileShare.ReadWrite; no FILE_SHARE_DELETE, so that a
        // deletion fails instead of leaving this handle on a file nobody sees
        char path[400]; MpfSessionPath(path, "steamnet_status.txt");
        g_statusFile = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
        if (g_statusFile == INVALID_HANDLE_VALUE) g_statusFile = 0;   // (tried again at the next write)
    }
    if (g_statusFile) {
        DWORD w;
        SetFilePointer(g_statusFile, 0, 0, 0);
        WriteFile(g_statusFile, text, (DWORD)n, &w, 0);
        SetEndOfFile(g_statusFile);
    }
    ReleaseSRWLockExclusive(&g_statusLock);
}
static void StatusOff(const char* why)
{
    Buf b; b.str("ready=-1 pid=").dec(GetCurrentProcessId()).str(" why=").text(why, 200).str("\nend=1\n");
    WriteStatus(b.s, b.n);
}

static const char* AvailText(int a)
{
    switch (a) { case 100: return "ready"; case 3: return "starting"; case 2: return "waiting"; case 1: return "not tried"; case -10: return "retrying";
                 case -100: return "lost"; case -101: return "failed"; case -102: return "cannot try"; }
    return "unknown";
}

static void BuildStatus()
{
    SnAuthStatus as; memset(&as, 0, sizeof(as));
    SnRelayStatus rs; memset(&rs, 0, sizeof(rs));
    int auth = F.authStatus(g_sockets, &as), relay = F.relayStatus(g_utils, &rs);
    static int logged = 0;
    if ((auth != g_auth || relay != g_relay) && logged < 40) {
        logged++;
        Buf b; b.str("steam networking: authentication ").str(AvailText(auth)).str(", relay network ").str(AvailText(relay));
        if (auth < 0 && as.debug[0]) b.str(" (").text(as.debug, 200).str(")");
        if (relay < 0 && rs.debug[0]) b.str(" (").text(rs.debug, 200).str(")");
        LogLine(b);
    }
    g_auth = auth; g_relay = relay;
    g_statusN = 0;
    Buf h;
    h.str("ready=1 sid=").udec(g_mySid).str(" auth=").dec(auth).str(" relay=").dec(relay).str(" listen=").str(g_lMain || g_lBulk ? "28090,28091" : "-")
     .str(" loop_hz=").dec(g_loopHz).str(" pid=").dec(GetCurrentProcessId()).str(" seq=").text(g_seq[0] ? g_seq : "-", 47).str(" iplisten=");
    if (g_lIpMain) h.ip(g_ipListenIp, g_ipListenPort).str(g_ipEcho ? ",echo" : ""); else h.str("-");
    h.str(" ipto="); if (g_ipToPort) h.ip(g_ipToIp, g_ipToPort); else h.str("-");
    h.str(" selftest=").str(TESTSTATE[g_testState]).str("\n");
    StatusAdd(h);
    for (auto& t : g_t) {
        if (t.state == S_FREE) continue;
        Buf l;
        l.str("t=").str(t.id).str(" kind=").str(KIND[t.kind]).str(" state=").str(STATE[t.state]).str(" peer=").str(t.peer[0] ? t.peer : "-")
         .str(" route=").str(t.state == S_WAIT || (t.state == S_CLOSED && !t.flags) ? "-" : RouteOf(t.flags)).str(" ping=").dec(t.ping)
         .str(" qr=").q2(t.qr).str(" ql=").q2(t.ql).str(" rate=").dec(t.rate).str(" outBps=").dec(t.outBps).str(" inBps=").dec(t.inBps)
         .str(" pend=").dec(t.pend).str(" unacked=").dec(t.unacked).str(" code=").dec(t.code).str(" why=").text(t.why, 128).str("\n");
        StatusAdd(l);
    }
    Buf e; e.str("end=1\n"); StatusAdd(e);
}

// ---------------------------------------------------------------- commands (steamnet_cmd.txt)
// One command a line, "<seq>\t<command>\t<arguments>" (spaces or tabs; the seq is any word, echoed as seq= in the status file;
// a line may leave it out). MPFever.exe only appends, after it saw ready=1 and this game's pid= in the status file: what the
// file held when the game started belongs to an earlier game and is skipped.
//   host <relay port> <secret hex, up to 64> [1|friends]   listen on the virtual ports 28090 (main) and 28091 (bulk); each
//                              accepted connection is dialled to 127.0.0.1:<relay port> with "steamtun\t<steam id>\t{["k"]=
//                              "<secret>",["kind"]="main|bulk",["route"]="relay|direct|lan",["ping"]=<ms>}\n" first
//   unhost                     the host's tunnels closed (linger), its listen sockets 3 s later
//   connect <id> <steam id> <virtual port> <loopback port> <nonce hex> main|bulk   a player's tunnel: once Steam connected,
//                              dialled to 127.0.0.1:<loopback port> with "steamtun\t<id>\t{["n"]="<nonce>",["route"]=...,
//                              ["ping"]=<ms>}\n" first; a connect with the id of an open tunnel replaces it
//   close <id>                 a tunnel closed (linger), either side's id ("in:<handle>" for the host's)
//   conf <key> <value>         rate_main, rate_bulk (bytes/s at a connection's start, also applied at once), rate_max (bulk
//                              ceiling), rate_fast (LAN ceiling), buf (send buffer), tmo_init, tmo_conn (ms), aimd 0|1, ice
//                              -1|0|1|... (P2P_Transport_ICE_Enable), debug <level>, fake_lag <ms>, fake_loss <percent>,
//                              fake_rate <bytes/s> (the last three global to the process), drop <id>|all (a cut, for tests)
//   selftest <MB>              a stream to this game's own Steam ID (or to the ipmode connect address), echoed and checked
//   ipmode listen <port>|<ip:port> [echo]   UDP listen sockets (127.0.0.1 by default) for main and, at the next port, bulk:
//                              their connections work as the P2P ones (or are echoed back, for another game's self-test)
//   ipmode connect <ip:port>   later connects and self-tests go there (bulk to the next port) instead of P2P
//   ipmode off
// The status file (rewritten every 500 ms, read up to its line "end=1"):
//   ready=1 sid=<id> auth=<n> relay=<n> listen=28090,28091|- loop_hz=<n> pid=<n> seq=<last> iplisten=<ip:port>[,echo]|-
//     ipto=<ip:port>|- selftest=none|running|ok|fail          (ready=0 pid=<n> while starting, ready=-1 pid=<n> why=<text>: off)
//   t=<id> kind=main|bulk|test state=connecting|dialing|connected|closing|closed peer=<steam id>|ip:<a.b.c.d:port>|-
//     route=relay|direct|lan|- ping=<ms> qr=<0.00-1.00|-1> ql=<...> rate=<bytes/s> outBps=<n> inBps=<n> pend=<bytes>
//     unacked=<bytes> code=<end reason> why=<text to the end of the line>    (closed tunnels stay listed 30 s)

static HANDLE g_cmdFile = 0;
static DWORD g_cmdMissedAt = 0;
static u64 g_cmdOffset = 0;

static HANDLE CmdHandle()
{
    // kept open, as mpfever_native's KeptFile: an open of a file just written waits for the antivirus
    if (g_cmdFile && g_cmdFile != INVALID_HANDLE_VALUE) return g_cmdFile;
    DWORD now = GetTickCount();
    if (g_cmdFile == INVALID_HANDLE_VALUE && now - g_cmdMissedAt < 500) return INVALID_HANDLE_VALUE;
    char path[400]; MpfSessionPath(path, "steamnet_cmd.txt");
    g_cmdFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (g_cmdFile == INVALID_HANDLE_VALUE) g_cmdMissedAt = now;
    return g_cmdFile;
}

static int OpenListen(u32* l, int kind, bool ip, u32 addr, u16 port)
{
    if (*l) return 1;
    SnConfig o[12]; int n = Options(o, kind, ip);
    if (ip) { SnIPAddr a; F.setIPv4(&a, addr, port); *l = F.listenIP(g_sockets, &a, n, o); }
    else *l = F.listenP2P(g_sockets, port, n, o);
    return *l ? 1 : 0;
}
static void CloseListen(u32* l) { if (*l) { F.closeListen(g_sockets, *l); *l = 0; } }

static void CloseTunnel(Tunnel* t, int code, const char* why, bool linger)
{
    if (t->role == R_SOURCE && g_testState == 1) { TestResult(false, why, t); return; }
    if (t->h) F.close(g_sockets, t->h, code, why, linger);
    Finish(t, code, why);
    LogEnd(t, "closed");
}

static void Host(char** a, int n)
{
    u64 port = 0;
    if (n < 3 || !Num(a[1], &port) || port == 0 || port > 65535 || !IsHex(a[2], 64)) { Buf b; b.str("steam networking: host: expected <relay port> <secret> [friendsOnly]"); LogLine(b); return; }
    g_relayPort = (u16)port; Copy(g_secret, a[2], sizeof(g_secret));
    g_friendsOnly = n > 3 && (Same(a[3], "1") || Same(a[3], "friends") || Same(a[3], "friendsonly"));
    g_hosting = true; g_listenCloseAt = 0;
    int ok = OpenListen(&g_lMain, K_MAIN, false, 0, (u16)VPORT_MAIN) + OpenListen(&g_lBulk, K_BULK, false, 0, (u16)VPORT_BULK);
    if (g_ipListenPort && !g_ipEcho) { OpenListen(&g_lIpMain, K_MAIN, true, g_ipListenIp, g_ipListenPort); OpenListen(&g_lIpBulk, K_BULK, true, g_ipListenIp, (u16)(g_ipListenPort + 1)); }
    Buf b; b.str("steam networking: hosting: ").str(ok == 2 ? "listening on the Steam virtual ports 28090 and 28091" : "the Steam listen sockets could NOT all be made")
        .str(", accepted connections go to the loopback port ").dec(g_relayPort).str(g_friendsOnly ? ", friends only" : "");
    LogLine(b);
}

static void Unhost()
{
    g_hosting = false;
    int n = 0;
    for (auto& t : g_t) if (t.state != S_FREE && t.state != S_CLOSED && t.role == R_IN) { CloseTunnel(&t, 1000, "host stopped", true); n++; }
    // closing a listen socket cuts its connections ungracefully, lingering ones too: a little later (new ones are refused)
    g_listenCloseAt = Now() + 3000;
    Buf b; b.str("steam networking: hosting stopped, ").dec(n).str(" connection(s) closed"); LogLine(b);
}

static void Connect(char** a, int n)
{
    // connect <cid> <sid64> <vport> <localPort> <nonceHex> main|bulk
    u64 sid = 0, vport = 0, lport = 0;
    bool kindOk = n > 6 && (Same(a[6], "main") || Same(a[6], "bulk"));
    if (n < 7 || Len(a[1]) > 32 || !Num(a[3], &vport) || vport > 65535 || !Num(a[4], &lport) || lport == 0 || lport > 65535 || !IsHex(a[5], 64) || !kindOk) {
        Buf b; b.str("steam networking: connect: expected <id> <steam id> <virtual port> <loopback port> <nonce> main|bulk"); LogLine(b); return;
    }
    int kind = Same(a[6], "bulk") ? K_BULK : K_MAIN;
    bool ip = g_ipToPort != 0;
    if (!ip && (!Num(a[2], &sid) || ((sid >> 52) & 0xF) != 1 || (sid >> 56) != 1)) {
        Buf b; b.str("steam networking: connect ").str(a[1]).str(": ").text(a[2], 30).str(" is not a player's Steam ID"); LogLine(b); return;
    }
    if (Tunnel* old = ById(a[1])) CloseTunnel(old, 1000, "replaced", false);
    for (auto& x : g_t) if (x.state == S_CLOSED && Same(x.id, a[1])) x.state = S_FREE;   // (one status line per id)
    Tunnel* t = NewTunnel();
    if (!t) { Buf b; b.str("steam networking: connect ").str(a[1]).str(": too many connections"); LogLine(b); return; }
    t->role = R_OUT; t->kind = kind; t->ip = ip; t->port = (u16)lport;
    Copy(t->id, a[1], 40); Copy(t->nonce, a[5], sizeof(t->nonce));
    SnConfig o[12]; int no = Options(o, kind, ip);
    if (ip) {
        u16 p = (u16)(g_ipToPort + (kind == K_BULK ? 1 : 0));
        SnIPAddr to; F.setIPv4(&to, g_ipToIp, p);
        t->h = F.connectIP(g_sockets, &to, no, o);
        Buf pb; pb.str("ip:").ip(g_ipToIp, p); pb.s[pb.n] = 0; Copy(t->peer, pb.s, 48);
    } else {
        SnIdentity who; memset(&who, 0, sizeof(who)); F.setSid(&who, sid);
        t->h = F.connectP2P(g_sockets, &who, (int)vport, no, o);
        Buf pb; pb.udec(sid); pb.s[pb.n] = 0; Copy(t->peer, pb.s, 48);
    }
    if (!t->h) { Finish(t, -1, "Steam did not make the connection"); LogEnd(t, "failed"); return; }
    t->steamState = 1; t->rate = g_rate[kind];
    SetState(t, S_WAIT);
    { Buf nm; nm.str("MPFever ").str(KIND[kind]).str(" ").str(t->id); nm.s[nm.n] = 0; F.setName(g_sockets, t->h, nm.s); }
    Buf b; b.str("steam networking: ").str(t->id).str(" connecting to ").str(t->peer);
    if (!ip) b.str(" (virtual port ").udec(vport).str(", ").str(KIND[kind]).str(")"); else b.str(" (").str(KIND[kind]).str(")");
    b.str(", loopback port ").udec(lport);
    LogLine(b);
}

static void SelfTest(char** a, int n)
{
    u64 mb = 0;
    if (n < 2 || !Num(a[1], &mb) || mb == 0 || mb > 4096) { Buf b; b.str("steam networking: selftest: expected <MB> (1 to 4096)"); LogLine(b); return; }
    for (auto& t : g_t) if (t.state != S_FREE && t.state != S_CLOSED && t.role == R_SOURCE) { Buf b; b.str("steam networking: a self-test already runs"); LogLine(b); return; }
    for (auto& x : g_t) if (x.state == S_CLOSED && x.role == R_SOURCE) x.state = S_FREE;
    Tunnel* t = NewTunnel();
    if (!t) { Buf b; b.str("steam networking: selftest: too many connections"); LogLine(b); return; }
    t->role = R_SOURCE; t->kind = K_TEST; t->total = mb << 20; t->rng = (Now() << 1) | 1; t->hashSent = t->hashRecv = 0xcbf29ce484222325ull;
    Copy(t->id, "selftest", 40);
    t->up = (u8*)Alloc(CHUNK);
    SnConfig o[12];
    bool ip = g_ipToPort != 0;
    if (ip) {
        // over IP to another game's "ipmode listen <port> echo"
        int no = Options(o, K_TEST, true);
        SnIPAddr to; F.setIPv4(&to, g_ipToIp, g_ipToPort);
        t->h = t->up ? F.connectIP(g_sockets, &to, no, o) : 0;
        Buf pb; pb.str("ip:").ip(g_ipToIp, g_ipToPort); pb.s[pb.n] = 0; Copy(t->peer, pb.s, 48);
        t->ip = true;
    } else {
        // P2P to this game's own Steam ID: Steam carries it inside the process, through its own listen socket
        g_testListenCloseAt = 0;
        OpenListen(&g_lTest, K_TEST, false, 0, (u16)VPORT_TEST);
        int no = Options(o, K_TEST, false);
        SnIdentity me; memset(&me, 0, sizeof(me)); F.setSid(&me, g_mySid);
        t->h = (t->up && g_lTest) ? F.connectP2P(g_sockets, &me, VPORT_TEST, no, o) : 0;
        Buf pb; pb.udec(g_mySid); pb.s[pb.n] = 0; Copy(t->peer, pb.s, 48);
    }
    if (!t->h) { Finish(t, -1, "Steam did not make the connection"); g_testState = 3; LogEnd(t, "failed"); return; }
    t->steamState = 1; t->rate = g_rate[K_TEST]; t->testStart = t->lastProgress = Now();
    SetState(t, S_WAIT);
    g_testState = 1;
    Buf b; b.str("steam networking: self-test: ").udec(mb).str(" MB to ").str(ip ? t->peer : "this game's own Steam ID").str(", echoed back and checked");
    LogLine(b);
}

static void Conf(char** a, int n)
{
    if (n < 3) { Buf b; b.str("steam networking: conf: expected <key> <value>"); LogLine(b); return; }
    const char* k = a[1]; const char* v = a[2];
    u64 x = 0; bool num = Num(v, &x);
    bool neg = v[0] == '-' && Num(v + 1, &x);
    bool done = true;
    auto live = [&](int id, int kind, i32 val) { for (auto& t : g_t) if (t.h && t.state != S_FREE && t.state != S_CLOSED && (kind < 0 || t.kind == kind)) F.setConnInt(g_utils, t.h, id, val); };
    if (Same(k, "rate_main") && num && x >= 16384 && x <= (256u << 20)) { g_rate[K_MAIN] = g_rate[K_TEST] = (i32)x; for (auto& t : g_t) if (t.h && t.kind != K_BULK && t.state != S_CLOSED) t.rate = (i32)x; live(10, K_MAIN, (i32)x); live(11, K_MAIN, (i32)x); live(10, K_TEST, (i32)x); live(11, K_TEST, (i32)x); }
    else if (Same(k, "rate_bulk") && num && x >= 16384 && x <= (256u << 20)) { g_rate[K_BULK] = (i32)x; for (auto& t : g_t) if (t.h && t.kind == K_BULK && t.state != S_CLOSED) t.rate = (i32)x; live(10, K_BULK, (i32)x); live(11, K_BULK, (i32)x); }
    else if (Same(k, "rate_max") && num && x >= 16384 && x <= (256u << 20)) g_rateMaxBulk = (i32)x;
    else if (Same(k, "rate_fast") && num && x >= 16384 && x <= (256u << 20)) g_rateMaxFast = (i32)x;
    else if (Same(k, "buf") && num && x >= (512u << 10) && x <= (64u << 20)) { g_sendBuf[0] = g_sendBuf[1] = g_sendBuf[2] = (i32)x; live(9, -1, (i32)x); }
    else if (Same(k, "tmo_init") && num && x >= 1000 && x <= 300000) g_tmoInit = (i32)x;
    else if (Same(k, "tmo_conn") && num && x >= 1000 && x <= 300000) { g_tmoConn[0] = g_tmoConn[1] = g_tmoConn[2] = (i32)x; live(25, -1, (i32)x); }
    else if (Same(k, "aimd") && num) g_aimd = x != 0;
    else if (Same(k, "aimd_idle") && num) g_aimdIdle = x != 0;
    else if (Same(k, "ice") && (num || neg) && CfgOk(104)) g_ice = neg ? -(i32)x : (i32)x;
    else if (Same(k, "debug") && num && x <= 8) { g_debugLevel = (long)x; F.setDebug(g_utils, (int)x, x ? &OnSteamDebug : 0); }
    else if (Same(k, "fake_lag") && num && x <= 10000 && CfgOk(4)) F.setGlobalInt(g_utils, 4, (i32)x);
    else if (Same(k, "fake_rate") && num && x <= (1u << 30) && CfgOk(42)) F.setGlobalInt(g_utils, 42, (i32)x);
    else if (Same(k, "fake_loss") && CfgOk(2)) {
        // a percentage, 0 to 100, with decimals ("0.5")
        float f = 0, scale = 0; bool ok = v[0] != 0;
        for (int i = 0; v[i]; i++) {
            if (v[i] == '.' && scale == 0) scale = 1;
            else if (v[i] >= '0' && v[i] <= '9') { if (scale == 0) f = f * 10 + (float)(v[i] - '0'); else { scale /= 10; f += scale * (float)(v[i] - '0'); } }
            else ok = false;
        }
        if (ok && f <= 100) F.setGlobalFloat(g_utils, 2, f); else done = false;
    }
    else if (Same(k, "drop")) {
        // a cut, for the tests: the Steam connection closes at once (no linger), MPFever.exe sees its stream end
        int c = 0;
        for (auto& t : g_t) if (t.state != S_FREE && t.state != S_CLOSED && t.role <= R_IN && (Same(v, "all") || Same(v, t.id))) { CloseTunnel(&t, 1000, "dropped by the test command", false); c++; }
        Buf b; b.str("steam networking: ").dec(c).str(" connection(s) dropped"); LogLine(b);
        return;
    }
    else done = false;
    Buf b; b.str("steam networking: conf ").text(k, 30).str(" ").text(v, 30).str(done ? "" : ": unknown key or value out of range, ignored"); LogLine(b);
}

static void IpMode(char** a, int n)
{
    u32 ip = 0; u16 port = 0;
    if (n >= 3 && Same(a[1], "listen")) {
        u64 p = 0;
        if (Num(a[2], &p) && p > 0 && p < 65535) { ip = 0x7F000001; port = (u16)p; }   // 127.0.0.1: no firewall prompt
        else if (!ParseAddr(a[2], &ip, &port, true) || port == 65535) { Buf b; b.str("steam networking: ipmode listen: expected <port> or <ip:port> [echo]"); LogLine(b); return; }
        CloseListen(&g_lIpMain); CloseListen(&g_lIpBulk);
        g_ipListenIp = ip; g_ipListenPort = port; g_ipEcho = n > 3 && Same(a[3], "echo");
        int ok = OpenListen(&g_lIpMain, g_ipEcho ? K_TEST : K_MAIN, true, ip, port);
        if (!g_ipEcho) ok += OpenListen(&g_lIpBulk, K_BULK, true, ip, (u16)(port + 1)); else ok++;
        Buf b; b.str("steam networking: IP mode: ").str(ok == 2 ? "listening on UDP " : "could NOT listen on UDP ").ip(ip, port);
        b.str(g_ipEcho ? " (connections are echoed back: the other game's self-test)" : " (main) and the next port (bulk), connections go to the relay port as P2P ones");
        LogLine(b);
    } else if (n >= 3 && Same(a[1], "connect")) {
        if (!ParseAddr(a[2], &ip, &port, true) || port == 65535) { Buf b; b.str("steam networking: ipmode connect: expected <ip:port>"); LogLine(b); return; }
        g_ipToIp = ip; g_ipToPort = port;
        Buf b; b.str("steam networking: IP mode: connections and self-tests go to UDP ").ip(ip, port).str(" (bulk links to the next port)"); LogLine(b);
    } else if (n >= 2 && Same(a[1], "off")) {
        CloseListen(&g_lIpMain); CloseListen(&g_lIpBulk);
        g_ipListenPort = 0; g_ipToPort = 0; g_ipEcho = false;
        Buf b; b.str("steam networking: IP mode off"); LogLine(b);
    } else { Buf b; b.str("steam networking: ipmode: expected listen <port> [echo], connect <ip:port> or off"); LogLine(b); }
}

static bool IsCommand(const char* c)
{
    static const char* const NAMES[] = { "host", "unhost", "connect", "close", "conf", "selftest", "ipmode" };
    for (auto x : NAMES) if (Same(c, x)) return true;
    return false;
}

static void CommandLine(char* l, int len)
{
    while (len && (l[len - 1] == '\r' || l[len - 1] == ' ' || l[len - 1] == '\t')) l[--len] = 0;
    char* a[12]; int n = 0;
    for (int i = 0; i < len && n < 12; ) {
        while (i < len && (l[i] == ' ' || l[i] == '\t')) l[i++] = 0;
        if (i >= len) break;
        a[n++] = l + i;
        while (i < len && l[i] != ' ' && l[i] != '\t') i++;
    }
    if (!n) return;
    // "<seq>\t<command>\t<arguments>" (the sequence is echoed in the status file); a line without one is taken too
    if (!IsCommand(a[0])) { Copy(g_seq, a[0], sizeof(g_seq)); for (int i = 1; i < n; i++) a[i - 1] = a[i]; n--; }
    if (!n) { Buf b; b.str("steam networking: a command line without a command: ").text(g_seq, 40); LogLine(b); return; }
    char** c = a;
    if (Same(c[0], "host")) Host(c, n);
    else if (Same(c[0], "unhost")) Unhost();
    else if (Same(c[0], "connect")) Connect(c, n);
    else if (Same(c[0], "close")) {
        Tunnel* t = n > 1 ? ById(c[1]) : 0;
        if (t) CloseTunnel(t, 1000, "closed by MPFever.exe", true);
        else { Buf b; b.str("steam networking: close: no connection ").text(n > 1 ? c[1] : "", 40); LogLine(b); }
    }
    else if (Same(c[0], "conf")) Conf(c, n);
    else if (Same(c[0], "selftest")) SelfTest(c, n);
    else if (Same(c[0], "ipmode")) IpMode(c, n);
    else { Buf b; b.str("steam networking: unknown command ").text(c[0], 40); LogLine(b); }
}

static void TailCommands()
{
    HANDLE f = CmdHandle();
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[16384];
    static int have = 0;
    DWORD size = GetFileSize(f, 0);
    if (size == INVALID_FILE_SIZE) return;
    if (size < g_cmdOffset) { g_cmdOffset = 0; have = 0; Buf b; b.str("steam networking: steamnet_cmd.txt got shorter: read again from its start"); LogLine(b); }
    for (int guard = 0; guard < 16 && size > g_cmdOffset; guard++) {
        if (have >= (int)sizeof(buf) - 1) have = 0;   // a line longer than the buffer: dropped
        DWORD want = (DWORD)(size - g_cmdOffset), room = (DWORD)(sizeof(buf) - 1 - have), got = 0;
        if (want > room) want = room;
        SetFilePointer(f, (long)g_cmdOffset, 0, 0);
        if (!ReadFile(f, buf + have, want, &got, 0) || !got) break;
        g_cmdOffset += got; have += (int)got;
        int start = 0;
        for (int i = 0; i < have; i++) if (buf[i] == '\n') { buf[i] = 0; CommandLine(buf + start, i - start); start = i + 1; }
        for (int i = start; i < have; i++) buf[i - start] = buf[i];   // a line still being written waits
        have -= start;
    }
}

// ---------------------------------------------------------------- the loop

static void Housekeeping(u64 now)
{
    if (g_listenCloseAt && now >= g_listenCloseAt) { g_listenCloseAt = 0; if (!g_hosting) { CloseListen(&g_lMain); CloseListen(&g_lBulk); if (!g_ipEcho) { CloseListen(&g_lIpMain); CloseListen(&g_lIpBulk); } } }
    if (g_testListenCloseAt && now >= g_testListenCloseAt) { g_testListenCloseAt = 0; CloseListen(&g_lTest); }
    for (auto& t : g_t) if (t.state == S_CLOSED && Since(now, t.stateAt) > 30000) t.state = S_FREE;
}

static DWORD WINAPI SteamNetThread(void*)
{
    g_loopTid = GetCurrentThreadId();
    static WSAPOLLFD_ fds[MAXT];
    static Tunnel* fdT[MAXT];
    u64 lastCmd = 0, lastInfo = 0, lastStatus = 0, hzAt = Now(); long cycles = 0; int turn = 0;
    for (;;) {
        if (g_stop || g_quit) break;
        AcquireSRWLockExclusive(&g_steamLock);
        if (g_stop || g_quit) { ReleaseSRWLockExclusive(&g_steamLock); break; }
        if (!F.getUser()) { ReleaseSRWLockExclusive(&g_steamLock); Sleep(200); continue; }   // (Steam not there: nothing to call)
        u64 now = Now();
        g_busy = false;
        F.runCallbacks(g_sockets);
        DrainEvents();
        if (now - lastCmd >= 20) { lastCmd = now; TailCommands(); }
        if (now - lastInfo >= 250) { lastInfo = now; PollInfo(); }
        for (auto& t : g_t) Pump(&t, now);
        Housekeeping(now);
        bool status = now - lastStatus >= 500;
        if (status) { lastStatus = now; RefreshRt((++turn & 1) == 0, now); BuildStatus(); }
        // the loopback sockets to wait on: only for what can go on (an always-writable socket would make a busy loop)
        int nf = 0; bool active = false;
        for (auto& t : g_t) {
            if (t.state == S_FREE || t.state == S_CLOSED) continue;
            active = true; t.revents = 0;
            if (t.s == INVALID_SOCKET_) continue;
            short ev = 0;
            if (t.state == S_DIAL) ev = POLLWRNORM_;
            else { if (t.state == S_BRIDGE && !t.upN) ev |= POLLRDNORM_; if (t.wantWrite) ev |= POLLWRNORM_; }
            if (!ev) continue;
            fds[nf].fd = t.s; fds[nf].events = ev; fds[nf].revents = 0; fdT[nf++] = &t;
        }
        bool listening = g_lMain || g_lBulk || g_lIpMain || g_lIpBulk || g_lTest;
        ReleaseSRWLockExclusive(&g_steamLock);
        if (status) WriteStatus(g_status, g_statusN);
        cycles++;
        if (now - hzAt >= 1000) { g_loopHz = (long)(cycles * 1000 / (i64)(now - hzAt)); cycles = 0; hzAt = now; }
        // Steam has nothing to wait on: while bytes move the loop turns every millisecond (the system timer's resolution in fact),
        // with idle tunnels every 4 ms (what Steam received waits at most that long), else less often
        int wait = g_busy ? 1 : active ? 4 : listening ? 20 : 200;
        if (nf) { if (W.poll(fds, (u32)nf, wait) > 0) for (int i = 0; i < nf; i++) fdT[i]->revents = fds[i].revents; }
        else Sleep((DWORD)wait);
    }
    _InterlockedExchange(&g_running, 0);
    if (g_quit && !g_stop) StatusOff(g_offWhy ? g_offWhy : "turned off");
    Buf b; b.str(g_stop ? "steam networking: stopped (the game closes Steam)" : "steam networking: stopped"); LogLine(b);
    return 0;
}

// ---------------------------------------------------------------- start, lock, shutdown (called by mpfever_native.cpp)

static bool Off(const char* why)
{
    g_offWhy = why;
    Buf b; b.str("steam networking: off: ").str(why); LogLine(b);
    StatusOff(why);
    return false;
}

// Steam calls of SteamThread (rich presence, invitations): under the same lock, none once the game closes Steam
extern "C" bool MpfSteamEnter()
{
    if (g_stop) return false;
    AcquireSRWLockExclusive(&g_steamLock);
    if (g_stop) { ReleaseSRWLockExclusive(&g_steamLock); return false; }
    return true;
}
extern "C" void MpfSteamLeave() { ReleaseSRWLockExclusive(&g_steamLock); }

// The game's SteamAPI_Shutdown (its import pointed here): our loop stops, our connections and listen sockets close (the peers
// see "closed" at once instead of a 30 s timeout), then the real one
extern "C" void MpfSteamShutdownHook()
{
    _InterlockedExchange(&g_stop, 1);
    bool locked = false;
    for (int i = 0; i < 1000 && !(locked = TryAcquireSRWLockExclusive(&g_steamLock) != 0); i++) Sleep(1);
    int n = 0;
    if (locked) {
        if (g_running || g_sockets) {
            for (auto& t : g_t) if (t.h && t.state != S_FREE && t.state != S_CLOSED) { F.close(g_sockets, t.h, 1003, "game closed", false); t.h = 0; n++; }
            u32* ls[] = { &g_lMain, &g_lBulk, &g_lIpMain, &g_lIpBulk, &g_lTest };
            for (u32* l : ls) if (*l) { F.closeListen(g_sockets, *l); *l = 0; }
        }
        ReleaseSRWLockExclusive(&g_steamLock);
        if (n) Sleep(100);   // (the close messages are sent by Steam's own thread)
    }
    Buf b; b.str("steam networking: the game closes Steam: ").dec(n).str(" connection(s) closed").str(locked ? "" : " (the lock was not free after 1 s)"); LogLine(b);
    ShutdownF orig = g_origShutdown;
    if (!orig && g_sa) orig = (ShutdownF)GetProcAddress(g_sa, "SteamAPI_Shutdown");
    if (orig) orig();
}

// the original SteamAPI_Shutdown, found in the game's imports (0: not found, then no safe shutdown: networking off)
extern "C" void MpfSteamNetSetShutdown(void* original)
{
    if (original) { g_origShutdown = (ShutdownF)original; return; }
    if (g_running) { g_offWhy = "the game's import of SteamAPI_Shutdown was not found (no safe shutdown)"; _InterlockedExchange(&g_quit, 1); Buf b; b.str("steam networking: off: ").str(g_offWhy); LogLine(b); }
}

static bool Resolve(HMODULE m, void** slots[], const char* const names[], int n, const char* dll)
{
    for (int i = 0; i < n; i++) {
        *slots[i] = GetProcAddress(m, names[i]);
        if (!*slots[i]) { Buf b; b.str(dll).str(" has no ").str(names[i]); b.s[b.n] = 0; static char why[160]; Copy(why, b.s, sizeof(why)); return Off(why); }
    }
    return true;
}

// Called by SteamThread once the game's Steam is up (its Friends interface found): the interfaces, the checks, then the loop's
// thread. true: Steam networking runs.
extern "C" bool MpfSteamNetStart(HMODULE sa, u64 sid, void* friends)
{
    char v[8];
    if (GetEnvironmentVariableA("MPFEVER_STEAMNET", v, 7) > 0 && v[0] == '0') return Off("MPFEVER_STEAMNET=0");
    { Buf b; b.str("ready=0 pid=").dec(GetCurrentProcessId()).str("\nend=1\n"); WriteStatus(b.s, b.n); }
    if (!sa || !sid) return Off("the player's Steam account is not known");
    g_sa = sa; g_friends = friends; g_mySid = sid;
    {
        void** slots[] = {
            (void**)&F.socketsIface, (void**)&F.utilsIface, (void**)&F.findIface, (void**)&F.getUser, (void**)&F.listenP2P, (void**)&F.connectP2P,
            (void**)&F.listenIP, (void**)&F.connectIP, (void**)&F.accept, (void**)&F.close, (void**)&F.closeListen, (void**)&F.setName,
            (void**)&F.send, (void**)&F.receive, (void**)&F.info, (void**)&F.realTime, (void**)&F.runCallbacks, (void**)&F.initAuth,
            (void**)&F.authStatus, (void**)&F.initRelay, (void**)&F.relayStatus, (void**)&F.setConnInt, (void**)&F.setGlobalInt,
            (void**)&F.setGlobalFloat, (void**)&F.cfgInfo, (void**)&F.getCfg, (void**)&F.setDebug, (void**)&F.setSid, (void**)&F.setIPv4,
            (void**)&F.release, (void**)&F.hasFriend };
        static const char* const names[] = {
            "SteamAPI_SteamNetworkingSockets_SteamAPI_v012", "SteamAPI_SteamNetworkingUtils_SteamAPI_v004", "SteamInternal_FindOrCreateUserInterface",
            "SteamAPI_GetHSteamUser", "SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P", "SteamAPI_ISteamNetworkingSockets_ConnectP2P",
            "SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP", "SteamAPI_ISteamNetworkingSockets_ConnectByIPAddress",
            "SteamAPI_ISteamNetworkingSockets_AcceptConnection", "SteamAPI_ISteamNetworkingSockets_CloseConnection",
            "SteamAPI_ISteamNetworkingSockets_CloseListenSocket", "SteamAPI_ISteamNetworkingSockets_SetConnectionName",
            "SteamAPI_ISteamNetworkingSockets_SendMessageToConnection", "SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection",
            "SteamAPI_ISteamNetworkingSockets_GetConnectionInfo", "SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus",
            "SteamAPI_ISteamNetworkingSockets_RunCallbacks", "SteamAPI_ISteamNetworkingSockets_InitAuthentication",
            "SteamAPI_ISteamNetworkingSockets_GetAuthenticationStatus", "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess",
            "SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus", "SteamAPI_ISteamNetworkingUtils_SetConnectionConfigValueInt32",
            "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32", "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueFloat",
            "SteamAPI_ISteamNetworkingUtils_GetConfigValueInfo", "SteamAPI_ISteamNetworkingUtils_GetConfigValue",
            "SteamAPI_ISteamNetworkingUtils_SetDebugOutputFunction", "SteamAPI_SteamNetworkingIdentity_SetSteamID64",
            "SteamAPI_SteamNetworkingIPAddr_SetIPv4", "SteamAPI_SteamNetworkingMessage_t_Release", "SteamAPI_ISteamFriends_HasFriend" };
        static_assert(sizeof(names) / sizeof(names[0]) == sizeof(Fns) / sizeof(void*) && sizeof(slots) / sizeof(slots[0]) == sizeof(Fns) / sizeof(void*), "one name per function");
        if (!Resolve(sa, slots, names, (int)(sizeof(names) / sizeof(names[0])), "steam_api64.dll")) return false;
    }
    {
        // Winsock: the game's (always loaded, the game imports it)
        HMODULE ws = GetModuleHandleW(L"ws2_32.dll");
        if (!ws) ws = LoadLibraryW(L"ws2_32.dll");
        if (!ws) return Off("ws2_32.dll not loaded");
        void** slots[] = { (void**)&W.startup, (void**)&W.socket, (void**)&W.connect, (void**)&W.send, (void**)&W.recv, (void**)&W.closesocket,
                           (void**)&W.ioctlsocket, (void**)&W.setsockopt, (void**)&W.getsockopt, (void**)&W.shutdown, (void**)&W.poll, (void**)&W.lastError };
        static const char* const names[] = { "WSAStartup", "socket", "connect", "send", "recv", "closesocket", "ioctlsocket", "setsockopt", "getsockopt",
                                             "shutdown", "WSAPoll", "WSAGetLastError" };
        static_assert(sizeof(names) / sizeof(names[0]) == sizeof(Ws) / sizeof(void*) && sizeof(slots) / sizeof(slots[0]) == sizeof(Ws) / sizeof(void*), "one name per function");
        if (!Resolve(ws, slots, names, (int)(sizeof(names) / sizeof(names[0])), "ws2_32.dll")) return false;
        static u8 wsa[512];
        if (W.startup(0x0202, wsa) != 0) return Off("WSAStartup failed");
    }
    {
        // the layouts this file relies on, checked in the library itself: the identity SetSteamID64 writes, the address SetIPv4
        // writes, and Release's jump through the message's m_pfnRelease (jmp [rcx+0xB8]: the message layout of SDK 1.61)
        SnIdentity id; memset(&id, 0, sizeof(id)); F.setSid(&id, 76561197960265729ull);
        if (id.type != 16 || id.size != 8 || id.sid != 76561197960265729ull) return Off("SteamNetworkingIdentity is not laid out as expected");
        SnIPAddr a; memset(&a, 0xEE, sizeof(a)); F.setIPv4(&a, 0x7F000001, 28090);
        static const u8 v4[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };
        if (memcmp(a.ip, v4, 16) != 0 || a.port != 28090) return Off("SteamNetworkingIPAddr is not laid out as expected");
        static const u8 rel[] = { 0x48, 0xFF, 0xA1, 0xB8, 0x00, 0x00, 0x00 };
        if (memcmp((const void*)F.release, rel, sizeof(rel)) != 0) return Off("SteamNetworkingMessage_t_Release is not the one of SDK 1.61");
    }
    if (!MpfSteamEnter()) return Off("the game closes Steam");
    const char* why = 0;
    g_sockets = F.socketsIface();
    if (!g_sockets && F.getUser()) g_sockets = F.findIface(F.getUser(), "SteamNetworkingSockets012");
    g_utils = F.utilsIface();
    if (!g_utils && F.getUser()) g_utils = F.findIface(F.getUser(), "SteamNetworkingUtils004");
    if (!g_sockets || !g_utils) why = "the networking interfaces (SteamNetworkingSockets012, SteamNetworkingUtils004) are not available";
    static char badName[160];
    for (int i = 0; !why && i < (int)(sizeof(g_cfg) / sizeof(g_cfg[0])); i++) {
        CfgName& c = g_cfg[i];
        int type = 0, scope = 0;
        const char* name = F.cfgInfo(g_utils, c.id, &type, &scope);
        c.ok = name && Same(name, c.name) && type == c.type;
        if (c.ok) continue;
        Buf b; b.str("configuration value ").dec(c.id).str(" is ").str(name ? "called " : "unknown").text(name ? name : "", 60).str(" (type ").dec(type)
            .str("), expected ").str(c.name).str(" (type ").dec(c.type).str(")");
        b.s[b.n] = 0;
        if (c.needed) { Copy(badName, b.s, sizeof(badName)); why = badName; }
        else { Buf w; w.str("steam networking: ").str(b.s).str(": never set"); LogLine(w); }
    }
    int auth = 0;
    if (!why) {
        char dv[4];
        if (GetEnvironmentVariableA("MPFEVER_STEAMNET_DEBUG", dv, 3) > 0 && dv[0] == '1') g_debugLevel = 5;
        if (GetEnvironmentVariableA("MPFEVER_AIMDIDLE", dv, 3) > 0 && dv[0] == '0') g_aimdIdle = false;
        F.setDebug(g_utils, (int)g_debugLevel, &OnSteamDebug);
        F.initRelay(g_utils);           // relay pings measured from now: ready before the player hosts or joins
        auth = F.initAuth(g_sockets);   // the certificate P2P connections need
    }
    MpfSteamLeave();
    if (why) return Off(why);
    // commands of an earlier game in this session folder are not this game's: read from the end the file has now (MPFever.exe
    // writes after it saw ready=1 with this game's pid in the status file)
    { HANDLE f = CmdHandle(); if (f != INVALID_HANDLE_VALUE) { DWORD sz = GetFileSize(f, 0); if (sz != INVALID_FILE_SIZE) g_cmdOffset = sz; } }
    _InterlockedExchange(&g_running, 1);
    HANDLE th = CreateThread(0, 0, SteamNetThread, 0, 0, 0);
    if (!th) { _InterlockedExchange(&g_running, 0); return Off("its thread could not start"); }
    CloseHandle(th);
    Buf b; b.str("steam networking: ready (Steam ID ").udec(sid).str("), authentication ").str(AvailText(auth));
    if (g_cmdOffset) b.str(", ").udec(g_cmdOffset).str(" bytes of earlier commands skipped");
    LogLine(b);
    return true;
}
