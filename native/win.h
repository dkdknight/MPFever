// Minimal Win32 declarations: the machine has MSVC but no Windows SDK, so the DLL is built freestanding
// (no windows.h, no C runtime). Only what mpfever_native uses.
#pragma once
typedef unsigned __int64 size_t;
extern "C" void* _ReturnAddress();
#pragma intrinsic(_ReturnAddress)
extern "C" long _InterlockedExchange(long volatile*, long);
extern "C" long _InterlockedIncrement(long volatile*);
extern "C" long _InterlockedCompareExchange(long volatile*, long, long);
extern "C" long _InterlockedDecrement(long volatile*);
#pragma intrinsic(_InterlockedExchange, _InterlockedIncrement, _InterlockedCompareExchange, _InterlockedDecrement)

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef long long i64;
typedef int i32;
typedef u64 uptr;
typedef int BOOL;
typedef unsigned long DWORD;
typedef void* HANDLE;
typedef void* HMODULE;

#define WINAPI __stdcall
#define DLL_PROCESS_ATTACH 1
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define PAGE_EXECUTE_READWRITE 0x40
#define GENERIC_WRITE 0x40000000
#define FILE_SHARE_READ 1
#define FILE_SHARE_WRITE 2
#define FILE_SHARE_DELETE 4
#define INVALID_FILE_SIZE 0xFFFFFFFFu
#define OPEN_ALWAYS 4
#define CREATE_ALWAYS 2
#define FILE_ATTRIBUTE_NORMAL 0x80
#define FILE_END 2
#define INVALID_HANDLE_VALUE ((HANDLE)(i64)-1)

struct SYSTEMTIME { u16 wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds; };
typedef DWORD (WINAPI* LPTHREAD_START_ROUTINE)(void*);

extern "C" {
__declspec(dllimport) HMODULE WINAPI GetModuleHandleW(const wchar_t*);
__declspec(dllimport) void* WINAPI VirtualAlloc(void*, u64, DWORD, DWORD);
__declspec(dllimport) BOOL WINAPI VirtualProtect(void*, u64, DWORD, DWORD*);
__declspec(dllimport) BOOL WINAPI FlushInstructionCache(HANDLE, const void*, u64);
__declspec(dllimport) HANDLE WINAPI GetCurrentProcess();
__declspec(dllimport) BOOL WINAPI QueryPerformanceCounter(i64*);
__declspec(dllimport) BOOL WINAPI QueryPerformanceFrequency(i64*);
__declspec(dllimport) DWORD WINAPI GetCurrentThreadId();
__declspec(dllimport) unsigned short WINAPI RtlCaptureStackBackTrace(DWORD skip, DWORD count, void** frames, DWORD* hash);
__declspec(dllimport) DWORD WINAPI TlsAlloc();
__declspec(dllimport) void* WINAPI TlsGetValue(DWORD index);
__declspec(dllimport) BOOL WINAPI TlsSetValue(DWORD index, void* value);
__declspec(dllimport) void WINAPI RaiseException(DWORD code, DWORD flags, DWORD nargs, const u64* args);
__declspec(dllimport) HANDLE WINAPI CreateThread(void*, u64, LPTHREAD_START_ROUTINE, void*, DWORD, DWORD*);
__declspec(dllimport) BOOL WINAPI CloseHandle(HANDLE);
__declspec(dllimport) DWORD WINAPI GetEnvironmentVariableA(const char*, char*, DWORD);
__declspec(dllimport) HANDLE WINAPI CreateFileA(const char*, DWORD, DWORD, void*, DWORD, DWORD, HANDLE);
__declspec(dllimport) BOOL WINAPI WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) DWORD WINAPI SetFilePointer(HANDLE, long, long*, DWORD);
__declspec(dllimport) void WINAPI GetLocalTime(SYSTEMTIME*);
__declspec(dllimport) BOOL WINAPI DisableThreadLibraryCalls(HMODULE);
__declspec(dllimport) void WINAPI Sleep(DWORD);
struct MEMORY_BASIC_INFORMATION { void* BaseAddress; void* AllocationBase; DWORD AllocationProtect; DWORD pad1; u64 RegionSize; DWORD State; DWORD Protect; DWORD Type; DWORD pad2; };
__declspec(dllimport) u64 WINAPI VirtualQuery(const void*, MEMORY_BASIC_INFORMATION*, u64);
__declspec(dllimport) void* WINAPI AddVectoredExceptionHandler(u32, long (WINAPI*)(void*));
__declspec(dllimport) BOOL WINAPI ReadFile(HANDLE, void*, DWORD, DWORD*, void*);
__declspec(dllimport) DWORD WINAPI GetFileSize(HANDLE, DWORD*);
__declspec(dllimport) DWORD WINAPI GetTickCount();
__declspec(dllimport) void* WINAPI HeapAlloc(HANDLE, DWORD, u64);
__declspec(dllimport) BOOL WINAPI HeapFree(HANDLE, DWORD, void*);
__declspec(dllimport) HANDLE WINAPI GetProcessHeap();
__declspec(dllimport) BOOL WINAPI DeleteFileA(const char*);
#define GENERIC_READ 0x80000000
#define OPEN_EXISTING 3
}

// IMAGE headers (only the fields read)
struct IMAGE_DOS_HEADER_ { u16 e_magic; u16 pad[29]; long e_lfanew; };
struct IMAGE_FILE_HEADER_ { u16 Machine, NumberOfSections; u32 TimeDateStamp, PointerToSymbolTable, NumberOfSymbols; u16 SizeOfOptionalHeader, Characteristics; };
struct IMAGE_SECTION_HEADER_ { u8 Name[8]; u32 VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData, PointerToRelocations, PointerToLinenumbers; u16 NumberOfRelocations, NumberOfLinenumbers; u32 Characteristics; };
extern "C" __declspec(dllimport) HMODULE WINAPI LoadLibraryW(const wchar_t*);
extern "C" __declspec(dllimport) u32 WINAPI GetSystemDirectoryW(wchar_t*, u32);
extern "C" __declspec(dllimport) void* WINAPI GetProcAddress(HMODULE, const char*);
extern "C" __declspec(dllimport) u32 WINAPI GetLastError();
extern "C" __declspec(dllimport) void WINAPI SetLastError(u32);
extern "C" __declspec(dllimport) wchar_t* WINAPI GetCommandLineW();
struct STARTUPINFOW_ { DWORD cb; u8 rest[100]; };
struct PROCESS_INFORMATION_ { HANDLE hProcess, hThread; DWORD pid, tid; };
extern "C" __declspec(dllimport) BOOL WINAPI CreateProcessW(const wchar_t*, wchar_t*, void*, void*, BOOL, DWORD, void*, const wchar_t*, STARTUPINFOW_*, PROCESS_INFORMATION_*);
extern "C" __declspec(dllimport) BOOL WINAPI TerminateProcess(HANDLE, u32);
extern "C" __declspec(dllimport) DWORD WINAPI GetModuleFileNameW(HMODULE, wchar_t*, DWORD);

// ---------------------------------------------------------------- for mpf_steamnet.cpp (Steam networking)
// slim reader/writer locks (one SRWLOCK starts as all zeros), a tick count that does not wrap, the status file's truncation
struct SRWLOCK_ { void* p; };
extern "C" {
__declspec(dllimport) void WINAPI AcquireSRWLockExclusive(SRWLOCK_*);
__declspec(dllimport) void WINAPI ReleaseSRWLockExclusive(SRWLOCK_*);
__declspec(dllimport) u8 WINAPI TryAcquireSRWLockExclusive(SRWLOCK_*);
__declspec(dllimport) u64 WINAPI GetTickCount64();
__declspec(dllimport) BOOL WINAPI SetEndOfFile(HANDLE);
__declspec(dllimport) DWORD WINAPI GetCurrentProcessId();
}

// Winsock: its functions are taken from ws2_32.dll at run time (the game imports it, so it is always loaded; the module only
// links kernel32). Only the types and values mpf_steamnet uses.
typedef u64 SOCKET_;
#define INVALID_SOCKET_ (~(SOCKET_)0)
struct sockaddr_in_ { u16 family; u16 port; u32 addr; u8 zero[8]; };   // port and address in network order
struct WSAPOLLFD_ { SOCKET_ fd; short events; short revents; };
#define AF_INET_ 2
#define SOCK_STREAM_ 1
#define IPPROTO_TCP_ 6
#define TCP_NODELAY_ 1
#define SOL_SOCKET_ 0xffff
#define SO_SNDBUF_ 0x1001
#define SO_RCVBUF_ 0x1002
#define SO_ERROR_ 0x1007
#define FIONBIO_ ((long)0x8004667Eu)
#define SD_SEND_ 1
#define POLLRDNORM_ 0x0100
#define POLLWRNORM_ 0x0010
#define POLLERR_ 0x0001
#define POLLHUP_ 0x0002
#define POLLNVAL_ 0x0004
#define WSAEWOULDBLOCK_ 10035
static_assert(sizeof(sockaddr_in_) == 16 && sizeof(WSAPOLLFD_) == 16, "Winsock layouts");

// Steamworks SDK 1.61 structures (the game's steam_api64.dll is that SDK's, byte for byte): steamnetworkingtypes.h and
// isteamnetworkingsockets.h, pack 8 except the identity and the IP address (pack 1). The offsets were checked against the SDK's
// own headers compiled with the same compiler; the asserts keep them.
#pragma pack(push, 1)
struct SnIPAddr { u8 ip[16]; u16 port; };                                         // SteamNetworkingIPAddr (IPv4 as ::ffff:a.b.c.d)
struct SnIdentity { i32 type; i32 size; union { u64 sid; SnIPAddr ip; u32 raw[32]; }; };   // SteamNetworkingIdentity (16 = SteamID)
#pragma pack(pop)
struct SnConfig { i32 id; i32 type; union { i32 i; i64 l; float f; const char* s; void* p; } v; };   // SteamNetworkingConfigValue_t
struct SnMessage {                                                                 // SteamNetworkingMessage_t
    void* data; i32 size; u32 conn; SnIdentity peer; i64 connUser; i64 usecRecv; i64 num;
    void (*freeData)(SnMessage*); void (*release)(SnMessage*); i32 channel; i32 flags; i64 user; u16 lane; u16 pad;
};
struct SnConnInfo {                                                                // SteamNetConnectionInfo_t
    SnIdentity remote; i64 user; u32 listen; SnIPAddr addr; u16 pad; u32 popRemote, popRelay;
    i32 state, endReason; char endDebug[128]; char desc[128]; i32 flags; u32 rsv[63];
};
struct SnStatusChanged { u32 conn; SnConnInfo info; i32 oldState; };               // SteamNetConnectionStatusChangedCallback_t (1221)
struct SnRealTime {                                                                // SteamNetConnectionRealTimeStatus_t
    i32 state, ping; float qLocal, qRemote, outPps, outBps, inPps, inBps;
    i32 sendRate, pendUnrel, pendRel, sentUnacked; i64 queueUsec; u32 rsv[16];
};
struct SnAuthStatus { i32 avail; char debug[256]; };                               // SteamNetAuthenticationStatus_t
struct SnRelayStatus { i32 avail, pinging, availConfig, availRelay; char debug[256]; };   // SteamRelayNetworkStatus_t
static_assert(sizeof(SnIPAddr) == 18 && sizeof(SnIdentity) == 136 && sizeof(SnConfig) == 16, "Steam identity / config layouts");
static_assert(sizeof(SnMessage) == 216 && __builtin_offsetof(SnMessage, peer) == 16 && __builtin_offsetof(SnMessage, release) == 184, "Steam message layout");
static_assert(sizeof(SnConnInfo) == 696 && __builtin_offsetof(SnConnInfo, listen) == 144 && __builtin_offsetof(SnConnInfo, addr) == 148
    && __builtin_offsetof(SnConnInfo, state) == 176 && __builtin_offsetof(SnConnInfo, endReason) == 180
    && __builtin_offsetof(SnConnInfo, endDebug) == 184 && __builtin_offsetof(SnConnInfo, flags) == 440, "Steam connection info layout");
static_assert(sizeof(SnStatusChanged) == 712 && __builtin_offsetof(SnStatusChanged, info) == 8 && __builtin_offsetof(SnStatusChanged, oldState) == 704, "Steam status callback layout");
static_assert(sizeof(SnRealTime) == 120 && __builtin_offsetof(SnRealTime, qRemote) == 12 && __builtin_offsetof(SnRealTime, pendRel) == 40
    && __builtin_offsetof(SnRealTime, queueUsec) == 48, "Steam real-time status layout");
static_assert(sizeof(SnAuthStatus) == 260 && sizeof(SnRelayStatus) == 272, "Steam availability layouts");
