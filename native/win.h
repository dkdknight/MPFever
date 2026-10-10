// Minimal Win32 declarations: the machine has MSVC but no Windows SDK, so the DLL is built freestanding
// (no windows.h, no C runtime). Only what mpfever_native uses.
#pragma once
typedef unsigned __int64 size_t;
extern "C" void* _ReturnAddress();
#pragma intrinsic(_ReturnAddress)
extern "C" long _InterlockedExchange(long volatile*, long);
extern "C" long _InterlockedIncrement(long volatile*);
#pragma intrinsic(_InterlockedExchange, _InterlockedIncrement)

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
extern "C" __declspec(dllimport) wchar_t* WINAPI GetCommandLineW();
struct STARTUPINFOW_ { DWORD cb; u8 rest[100]; };
struct PROCESS_INFORMATION_ { HANDLE hProcess, hThread; DWORD pid, tid; };
extern "C" __declspec(dllimport) BOOL WINAPI CreateProcessW(const wchar_t*, wchar_t*, void*, void*, BOOL, DWORD, void*, const wchar_t*, STARTUPINFOW_*, PROCESS_INFORMATION_*);
extern "C" __declspec(dllimport) BOOL WINAPI TerminateProcess(HANDLE, u32);
extern "C" __declspec(dllimport) DWORD WINAPI GetModuleFileNameW(HMODULE, wchar_t*, DWORD);
