/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1820: native Windows milestone for a host of Valve's genuine client.
 * No Valve binaries are bundled with this program. Opt-in session mode calls
 * independently verified private methods only for an exact client SHA-256;
 * shutdown uses the versioned public SteamClient021 interface.
 * Export presence, engine construction and global-user construction
 * are separate observations; none establishes authentication or game ownership.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stddef.h>
#include <wchar.h>
#include "probe.h"
#include "session.h"
#include "scm.h"
#include "validation.h"

#define PATH_CAP 32768
static FILE *report;
static const struct dock_client_layout *client_layout;

static void event(const char *stage, int32_t value)
{
    const char *round = !strncmp(stage, "game-scm", 8) || !strncmp(stage, "launch-keep-alive", 17) ? "ml2020" :
        !strncmp(stage, "install-scm", 11) ? "ml2014" :
        !strncmp(stage, "ceg-scm", 7) || !strncmp(stage, "ceg-service-", 12) ? "ml2000" :
        !strncmp(stage, "ceg-", 4) ? "ml1990" :
        !strncmp(stage, "launch-update-", 14) ? "ml1970" :
        !strncmp(stage, "launch-config-", 14) ? "ml2011" :
        !strncmp(stage, "launch-session-", 15) ? "ml2015" :
        !strncmp(stage, "session-offline-", 16) ? "ml2016" :
        !strncmp(stage, "session-handoff-", 16) ? "ml1870" :
        !strcmp(stage, "session-client-adapter") ? "ml1860" : "ml1830";
    fprintf(stderr, "[steam-host] %s %s=%ld\n", round, stage, (long)value);
    fflush(stderr);
    if (report) {
        fprintf(report, "[steam-host] %s %s=%ld\n", round, stage, (long)value);
        fflush(report);
    }
}

static bool enabled(const wchar_t *name)
{
    wchar_t value[4];
    return GetEnvironmentVariableW(name, value, 4) == 1 && value[0] == L'1';
}

static bool client_directory(wchar_t *directory)
{
    DWORD count = GetEnvironmentVariableW(L"MADEIRA_STEAM_HOST_CLIENT_DIR", directory, PATH_CAP);
    if (count >= PATH_CAP) return false;
    if (!count) {
        DWORD bytes = PATH_CAP * sizeof(wchar_t);
        LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam",
                                     L"SteamPath", RRF_RT_REG_SZ, NULL, directory, &bytes);
        if (status != ERROR_SUCCESS)
            wcscpy(directory, L"C:\\Program Files (x86)\\Steam");
    }
    /* Only a local absolute DOS path, with space for the fixed DLL basename.
     * A relative path would let the selected game's working directory decide
     * which client library gets loaded.
     */
    size_t length = wcslen(directory);
    if (length < 3 || length + 32 >= PATH_CAP || directory[1] != L':' ||
        (directory[2] != L'\\' && directory[2] != L'/')) return false;
    if (!((directory[0] >= L'A' && directory[0] <= L'Z') ||
          (directory[0] >= L'a' && directory[0] <= L'z'))) return false;
    return true;
}

static bool no_other_client(void)
{
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W process = {0};
    process.dwSize = sizeof(process);
    bool clear = true;
    if (!Process32FirstW(snapshot, &process)) {
        CloseHandle(snapshot);
        return false;
    }
    do {
        if (process.th32ProcessID == GetCurrentProcessId()) continue;
        if (!_wcsicmp(process.szExeFile, L"steam.exe") ||
            !_wcsicmp(process.szExeFile, L"steamwebhelper.exe") ||
            !_wcsicmp(process.szExeFile, L"steamhost64.exe") ||
            !_wcsicmp(process.szExeFile, L"madeira-steamhost-probe.exe")) {
            clear = false;
            break;
        }
    } while (Process32NextW(snapshot, &process));
    if (clear && GetLastError() != ERROR_NO_MORE_FILES) clear = false;
    CloseHandle(snapshot);
    return clear;
}

static bool identify_client(HANDLE file)
{
    IMAGE_DOS_HEADER dos;
    IMAGE_FILE_HEADER header;
    DWORD read = 0, signature = 0;
    LARGE_INTEGER length, offset;
    if (!GetFileSizeEx(file, &length) || length.QuadPart < 64 ||
        !ReadFile(file, &dos, sizeof(dos), &read, NULL) || read != sizeof(dos) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < (LONG)sizeof(dos) ||
        (LONGLONG)dos.e_lfanew + 4 + (LONGLONG)sizeof(header) > length.QuadPart)
        return false;
    offset.QuadPart = dos.e_lfanew;
    if (!SetFilePointerEx(file, offset, NULL, FILE_BEGIN) ||
        !ReadFile(file, &signature, 4, &read, NULL) || read != 4 || signature != IMAGE_NT_SIGNATURE ||
        !ReadFile(file, &header, sizeof(header), &read, NULL) || read != sizeof(header))
        return false;
    event("client-machine", header.Machine);
    event("client-pe-timestamp", (int32_t)header.TimeDateStamp);
#ifdef _WIN64
    if (header.Machine != IMAGE_FILE_MACHINE_AMD64) return false;
#else
    if (header.Machine != IMAGE_FILE_MACHINE_I386) return false;
#endif
    if (!(header.Characteristics & IMAGE_FILE_DLL)) return false;

    /* SHA-256 identifies the exact file for subsequent ABI research. It is
     * not an Authenticode check and is not proof that a file came from Valve.
     * The open handle disallows writes/deletes while this probe uses the DLL.
     */
    HCRYPTPROV provider = 0;
    HCRYPTHASH hash = 0;
    unsigned char buffer[32768], digest[32];
    char hex[65];
    DWORD size = sizeof(digest);
    bool ok = false;
    offset.QuadPart = 0;
    if (!SetFilePointerEx(file, offset, NULL, FILE_BEGIN) ||
        !CryptAcquireContextW(&provider, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) ||
        !CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash)) goto done;
    for (;;) {
        if (!ReadFile(file, buffer, sizeof(buffer), &read, NULL)) goto done;
        if (!read) break;
        if (!CryptHashData(hash, buffer, read, 0)) goto done;
    }
    if (!CryptGetHashParam(hash, HP_HASHVAL, digest, &size, 0) || size != 32) goto done;
    for (unsigned i = 0; i < 32; ++i) sprintf(hex + i * 2, "%02x", digest[i]);
    client_layout = dock_client_layout(hex);
    if (client_layout && client_layout->revision == 202601) {
        const char *compat = getenv("MADEIRA_DOCK_CLIENT_202601");
        if (compat && !strcmp(compat, "0")) client_layout = NULL;
    }
    event("session-client-adapter", client_layout ? client_layout->revision : 0);
    fprintf(stderr, "[steam-host] ml1820 client-sha256=%s\n", hex);
    fflush(stderr);
    if (report) {
        fprintf(report, "[steam-host] ml1820 client-sha256=%s\n", hex);
        fflush(report);
    }
    ok = true;
done:
    if (hash) CryptDestroyHash(hash);
    if (provider) CryptReleaseContext(provider, 0);
    return ok;
}

static FARPROC symbol(HMODULE module, const char *name)
{
    FARPROC address = GetProcAddress(module, name);
    event(name, address != NULL);
    return address;
}

static uint64_t now_ms(void) { return GetTickCount64(); }
/* Alertable: the host's own overlapped completions (and any user APC) run
 * during the poll pause instead of waiting for a later blocking wait. */
static void sleep_ms(uint32_t ms) { SleepEx(ms, TRUE); }
static const struct sh_observer host_observer = {now_ms, sleep_ms, event};

/* BShutdownIfAllPipesClosed is slot 23 in the public SteamClient021 ABI,
 * including GetISteamGameSearch and the reserved RunFrame slot. Verified
 * against ValveSoftware/Proton steamworks_sdk_162/isteamclient.h. Never apply
 * this layout to CLIENTENGINE_INTERFACE_VERSION005 or an arbitrary version.
 */
typedef bool (__thiscall *sh_shutdown_fn)(void *client);
static bool shutdown_client(void *client)
{
    void **methods = *(void ***)client;
    return ((sh_shutdown_fn)methods[23])(client);
}

#define SH_INSTALL_SCM_STEP_MS 20000   /* ml2015 */
static volatile int32_t install_scm_outcome;

static DWORD WINAPI install_scm_worker(void *unused)
{
    (void)unused;
    install_scm_outcome = sh_install_scm_start(&host_observer);
    return 0;
}

int main(int argc, char **argv)
{
    static wchar_t directory[PATH_CAP], path[PATH_CAP];
    HANDLE mutex = NULL, file = INVALID_HANDLE_VALUE;
    void *public_client = NULL;
    int result = 20;

    /* ml2014: Madeira's one-time-install batch runs this before a game's
     * installers. No Steam client is loaded; the one stdout line ("services
     * started|already|failed|off") goes to the batch's result file. Exit 0
     * always: installers run either way.
     */
    if (argc == 2 && !strcmp(argv[1], "--start-services")) {
        /* ml2015: a service manager that never answered its RPC pipe left
         * OpenSCManager blocked, and the batch (and the game) waited forever.
         * The step runs on a worker thread for at most SH_INSTALL_SCM_STEP_MS;
         * then it reports "services timeout" and this process ends at once
         * (the blocked call may hold loader or RPC locks, so no exit cleanup).
         */
        HANDLE worker = CreateThread(NULL, 0, install_scm_worker, NULL, 0, NULL);
        if (!worker) {
            printf("services %s\n", sh_install_scm_word(sh_install_scm_start(&host_observer)));
            fflush(stdout);
            return 0;
        }
        if (WaitForSingleObject(worker, SH_INSTALL_SCM_STEP_MS) != WAIT_OBJECT_0) {
            printf("services timeout\n");
            fflush(stdout);
            TerminateProcess(GetCurrentProcess(), 0);
        }
        CloseHandle(worker);
        printf("services %s\n", sh_install_scm_word(install_scm_outcome));
        fflush(stdout);
        return 0;
    }

    if (!enabled(L"MADEIRA_STEAM_HOST_PROBE")) {
        event("disabled-set-MADEIRA_STEAM_HOST_PROBE", 0);
        return 2;
    }
    /* This log is separate from Steam's own logs and contains no tokens,
     * usernames, SteamIDs, paths, environment dump, or callback payloads.
     */
    DWORD log_length = GetEnvironmentVariableW(L"MADEIRA_STEAM_HOST_LOG", path, PATH_CAP);
    if (!log_length) wcscpy(path, L"C:\\madeira-steamhost-probe.txt");
    if (log_length < PATH_CAP) report = _wfopen(path, L"w");
    event("probe-start-bits", (int32_t)(sizeof(void *) * 8));
    mutex = CreateMutexW(NULL, FALSE, L"Local\\MadeiraSteamHostProbe");
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        event("another-probe-or-mutex-error", 1);
        goto done;
    }
    if (!client_directory(directory)) {
        event("invalid-client-directory", 1);
        goto done;
    }
    if (!no_other_client()) {
        event("another-client-or-process-query-error", 1);
        goto done;
    }
    wcscpy(path, directory);
#ifdef _WIN64
    wcscat(path, L"\\steamclient64.dll");
#else
    wcscat(path, L"\\steamclient.dll");
#endif
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE || !identify_client(file)) {
        event("client-file-or-identity-error", (int32_t)GetLastError());
        goto done;
    }
    if (!SetCurrentDirectoryW(directory)) {
        event("client-working-directory-error", (int32_t)GetLastError());
        goto done;
    }
    /* Restrict dependency search to the client directory and system32. No
     * fallback to a current-directory LoadLibrary or to a renamed client DLL.
     */
    event("load-client-begin", 0);
    HMODULE module = LoadLibraryExW(path, NULL,
                                   LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) {
        event("load-client-error", (int32_t)GetLastError());
        goto done;
    }
    struct sh_api api = {
        (int32_t (SH_CALL *)(int32_t *))symbol(module, "Steam_CreateGlobalUser"),
        (void (SH_CALL *)(int32_t, int32_t))symbol(module, "Steam_ReleaseUser"),
        (bool (SH_CALL *)(int32_t))symbol(module, "Steam_BReleaseSteamPipe"),
        (bool (SH_CALL *)(int32_t, struct sh_callback *))symbol(module, "Steam_BGetCallback"),
        (void (SH_CALL *)(int32_t))symbol(module, "Steam_FreeLastCallback"),
        (bool (SH_CALL *)(int32_t, int32_t))symbol(module, "Steam_BLoggedOn")
    };
    void *(SH_CALL *factory)(const char *, int *) =
        (void *(SH_CALL *)(const char *, int *))symbol(module, "CreateInterface");
    if (!factory || !api.create_global_user || !api.release_user || !api.release_pipe ||
        !api.get_callback || !api.free_callback || !api.logged_on) goto done;
    int factory_result = -1;
    public_client = factory("SteamClient021", &factory_result);
    event("public-client021-present", public_client != NULL);
    if (!public_client) goto done;
    event("engine-factory-begin", 0);
    void *engine = factory("CLIENTENGINE_INTERFACE_VERSION005", &factory_result);
    event("engine005-present", engine != NULL);
    event("engine-factory-result", factory_result);
    if (!engine) goto done;

    if (enabled(L"MADEIRA_STEAM_HOST_SESSION")) {
        result = sh_session(module, engine, &api, &host_observer, client_layout);
    } else if (enabled(L"MADEIRA_STEAM_HOST_BOOTSTRAP")) {
        result = sh_probe_bootstrap(&api, &host_observer);
    } else {
        event("bootstrap-disabled", 1);
        result = SH_OK;
    }
    /* Never unload an initialized client DLL while its internal workers may
     * still be alive. The guest process owns it until process/session teardown.
     * Full engine shutdown and repeated sessions need separate device evidence.
     */
done:
    if (public_client) {
        event("shutdown-begin", 0);
        bool stopped = shutdown_client(public_client);
        event("shutdown-complete", stopped ? 1 : 0);
        if (!stopped && result == SH_OK) result = SH_RELEASE_FAILED;
    }
    /* ml2000: after Valve's client has shut down, end the service manager
     * this host started for CEG (no-op when it was already running), so a
     * leftover service process cannot keep the app's session alive.
     */
    sh_ceg_scm_release(&host_observer);
    if (!enabled(L"MADEIRA_STEAM_HOST_SESSION"))
        event("ownership-unchecked-game-launch-disabled", 1);
    event("probe-result", result);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (mutex) CloseHandle(mutex);
    if (report) fclose(report);
    return result;
}
