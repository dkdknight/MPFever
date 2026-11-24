/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml2000: Valve's client performs custom-executable (CEG) preparation
 * through its own installed client service, which it demand-starts through
 * the Windows service manager. A Dock session runs only this host, so Wine's
 * service manager may not be running; desktop routes start it themselves.
 * This file starts only Wine's standard service manager and checks, read-only,
 * that Valve's service is registered; if not, it runs Valve's own service
 * installer as Valve's client would. Dock itself never creates, registers,
 * configures or starts any service, and logs only numeric results.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsvc.h>
#include <stdbool.h>
#include <wchar.h>
#include "scm.h"
#include "validation.h"

#define SH_SCM_START_MS 30000ULL
#define SH_SERVICE_STOP_MS 15000ULL
#define SH_SERVICE_CONTROL_RETRY_MS 1000ULL
#define SH_PROCESS_EXIT_MS 5000
#define SH_SERVICE_INSTALL_MS 60000

static const wchar_t steam_service[] = L"Steam Client Service";
/* Wine's include/wine/svcctl.idl SVCCTL_STARTED_EVENT: services.exe sets this
 * manual-reset event once its \pipe\svcctl RPC endpoint listens. wineboot
 * creates it before starting services.exe and waits for it the same way.
 */
static const wchar_t started_event_name[] = L"__wine_SvcctlStartedEvent";

/* The service manager this host started; NULL when it was already running. */
static HANDLE manager_process;

static DWORD start_manager(const struct sh_observer *o, SC_HANDLE *manager, const char *started_stage)
{
    wchar_t directory[MAX_PATH], path[MAX_PATH + 16];
    UINT length = GetSystemDirectoryW(directory, MAX_PATH);
    if (!length || length >= MAX_PATH) return ERROR_PATH_NOT_FOUND;
    wcscpy(path, directory);
    wcscat(path, L"\\services.exe");
    uint64_t begin = o->now_ms();
    HANDLE started = CreateEventW(NULL, TRUE, FALSE, started_event_name);
    /* An existing event means another launcher is already starting one:
     * never run a second service manager, only wait for that one.
     */
    bool other = started && GetLastError() == ERROR_ALREADY_EXISTS;
    HANDLE process = NULL;
    if (!other) {
        STARTUPINFOW startup = {0};
        PROCESS_INFORMATION info = {0};
        startup.cb = sizeof(startup);
        if (!CreateProcessW(path, NULL, NULL, NULL, FALSE, DETACHED_PROCESS, NULL,
                            directory, &startup, &info)) {
            DWORD error = GetLastError();
            if (started) CloseHandle(started);
            return error;
        }
        CloseHandle(info.hThread);
        manager_process = process = info.hProcess;
        o->event(started_stage, 1);
    }
    HANDLE handles[2];
    DWORD count = 0;
    if (started) handles[count++] = started;
    if (process) handles[count++] = process;
    /* Wine's services.exe sets the started event once its RPC endpoint
     * listens, but a manager that answers is started whether or not the
     * event reaches this waiter: on Madeira's iOS port it was seen never to
     * arrive while the new manager already answered other clients within a
     * second. So the wait runs in short slices and the manager is asked
     * between them; the event, the process's exit and the bound end it as
     * before.
     */
    while (count) {
        uint32_t left = sh_remaining_ms(o->now_ms(), begin, SH_SCM_START_MS);
        DWORD wait = WaitForMultipleObjects(count, handles, FALSE, sh_scm_poll_slice_ms(left));
        if (process && wait == WAIT_OBJECT_0 + count - 1) {
            if (started) CloseHandle(started);
            return ERROR_PROCESS_ABORTED;
        }
        if (wait == WAIT_OBJECT_0 || !left) break;
        if (wait == WAIT_FAILED) o->sleep_ms(sh_scm_poll_slice_ms(left));
        *manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        if (*manager) {
            if (started) CloseHandle(started);
            return 0;
        }
        DWORD error = GetLastError();
        if (!sh_scm_error_retryable(error)) {
            if (started) CloseHandle(started);
            return error;
        }
    }
    if (started) CloseHandle(started);
    for (;;) {
        *manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        if (*manager) return 0;
        DWORD error = GetLastError();
        if (!sh_scm_error_retryable(error)) return error;
        if (process && WaitForSingleObject(process, 0) == WAIT_OBJECT_0) return ERROR_PROCESS_ABORTED;
        if (!sh_remaining_ms(o->now_ms(), begin, SH_SCM_START_MS)) return ERROR_TIMEOUT;
        o->sleep_ms(100);
    }
}

/* Read-only registration check; *missing is true only for "does not exist". */
static bool service_registered(const struct sh_observer *o, SC_HANDLE manager, bool *missing)
{
    SC_HANDLE service = OpenServiceW(manager, steam_service, SERVICE_QUERY_STATUS);
    bool registered = service != NULL;
    DWORD error = registered ? 0 : GetLastError();
    *missing = error == ERROR_SERVICE_DOES_NOT_EXIST;
    o->event("ceg-service-registered", registered);
    if (!registered && !*missing) o->event("ceg-scm-error", (int32_t)error);
    if (service) CloseServiceHandle(service);
    return registered;
}

/* ml2000: when Valve's service is not registered, run Valve's own service
 * installer exactly as Valve's client does when it finds the service missing
 * (static inspection of both pinned client builds: GetModuleFileName of the
 * Steam process, "%s\bin\SteamService.exe", ShellExecuteEx "open" with
 * "/install", working directory the Steam folder, then wait). Dock's process
 * is not in the Steam folder, so the folder of the loaded genuine client DLL
 * is used; Valve's install-script launcher uses the same bin\SteamService.exe
 * under the Steam install folder. Valve's binary registers Valve's service;
 * Dock writes no service keys and creates no service. Returns the installer's
 * exit code, -1 on timeout (installer ended) or -2 if the file is missing.
 */
static int32_t install_client_service(const struct sh_observer *o, HMODULE client)
{
    static wchar_t folder[32768], path[32768 + 32], command[32768 + 48];
    DWORD length = GetModuleFileNameW(client, folder, 32768);
    if (!client || !length || length >= 32768) return sh_service_install_report(false, false, 0);
    wchar_t *slash = wcsrchr(folder, L'\\');
    if (!slash || slash == folder) return sh_service_install_report(false, false, 0);
    *slash = 0;
    wcscpy(path, folder);
    wcscat(path, L"\\bin\\SteamService.exe");
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY))
        return sh_service_install_report(false, false, 0);
    wcscpy(command, L"\"");
    wcscat(command, path);
    wcscat(command, L"\" /install");
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION info = {0};
    startup.cb = sizeof(startup);
    if (!CreateProcessW(path, command, NULL, NULL, FALSE, DETACHED_PROCESS, NULL, folder,
                        &startup, &info)) {
        o->event("ceg-scm-error", (int32_t)GetLastError());
        return sh_service_install_report(true, true, (uint32_t)-3);
    }
    CloseHandle(info.hThread);
    bool finished = WaitForSingleObject(info.hProcess, SH_SERVICE_INSTALL_MS) == WAIT_OBJECT_0;
    DWORD code = 0;
    if (!finished) {
        /* A stuck installer would keep the app's session alive; fail closed. */
        if (TerminateProcess(info.hProcess, 1)) WaitForSingleObject(info.hProcess, SH_PROCESS_EXIT_MS);
    } else if (!GetExitCodeProcess(info.hProcess, &code)) code = (DWORD)-3;
    CloseHandle(info.hProcess);
    return sh_service_install_report(true, finished, code);
}

static bool wide_flag(const wchar_t *name, wchar_t expected)
{
    wchar_t value[4] = {0};
    return GetEnvironmentVariableW(name, value, 4) == 1 && value[0] == expected;
}

int32_t sh_ceg_scm_prepare(const struct sh_observer *o, HMODULE client)
{
    SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    DWORD error = manager ? 0 : GetLastError();
    if (!manager && !manager_process && sh_scm_error_means_absent(error))
        error = start_manager(o, &manager, "ceg-scm-started");
    o->event("ceg-scm", manager != NULL);
    if (!manager) {
        o->event("ceg-scm-error", (int32_t)error);
        return sh_ceg_scm_result(false, false);
    }
    bool missing = false;
    bool registered = service_registered(o, manager, &missing);
    /* MADEIRA_DOCK_CEG_SERVICE_INSTALL=0 keeps the fail-fast -5. */
    if (sh_should_install_service(registered, missing,
                                  !wide_flag(L"MADEIRA_DOCK_CEG_SERVICE_INSTALL", L'0'))) {
        o->event("ceg-service-install", install_client_service(o, client));
        registered = service_registered(o, manager, &missing);
    }
    CloseServiceHandle(manager);
    return sh_ceg_scm_result(true, registered);
}

static bool query_state(SC_HANDLE service, SERVICE_STATUS_PROCESS *status)
{
    DWORD needed = 0;
    return QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, (BYTE *)status,
                                sizeof(*status), &needed);
}

/* Stop Valve's client service only through the service manager. A service
 * process that outlives the bound would keep the app's session alive, so the
 * process this host's manager started for it is then ended.
 */
static enum sh_service_stop stop_client_service(const struct sh_observer *o)
{
    SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (!manager) return SH_SERVICE_STOP_FAILED;
    SC_HANDLE service = OpenServiceW(manager, steam_service, SERVICE_STOP | SERVICE_QUERY_STATUS);
    if (!service) {
        DWORD error = GetLastError();
        CloseServiceHandle(manager);
        return error == ERROR_SERVICE_DOES_NOT_EXIST ? SH_SERVICE_NOT_RUNNING : SH_SERVICE_STOP_FAILED;
    }
    SERVICE_STATUS_PROCESS status = {0};
    bool known = query_state(service, &status);
    bool running = !known || status.dwCurrentState != SERVICE_STOPPED;
    HANDLE process = NULL;
    if (known && running && status.dwProcessId)
        process = OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE, FALSE, status.dwProcessId);
    bool stopped = !running, gone = false, ended = false;
    uint64_t begin = o->now_ms(), control_at = 0;
    bool controlled = false;
    while (running && !stopped && sh_remaining_ms(o->now_ms(), begin, SH_SERVICE_STOP_MS)) {
        if (query_state(service, &status) && status.dwCurrentState == SERVICE_STOPPED) {
            stopped = true;
            break;
        }
        /* A start- or stop-pending service may refuse the control; ask again. */
        if (status.dwCurrentState != SERVICE_STOP_PENDING &&
            (!controlled || o->now_ms() - control_at >= SH_SERVICE_CONTROL_RETRY_MS)) {
            SERVICE_STATUS ignored;
            if (!ControlService(service, SERVICE_CONTROL_STOP, &ignored) &&
                GetLastError() == ERROR_SERVICE_NOT_ACTIVE) {
                stopped = true;
                break;
            }
            controlled = true;
            control_at = o->now_ms();
        }
        o->sleep_ms(100);
    }
    if (process) {
        uint32_t left = sh_remaining_ms(o->now_ms(), begin, SH_SERVICE_STOP_MS);
        gone = WaitForSingleObject(process, left < 1000 ? 1000 : left) == WAIT_OBJECT_0;
        if (!gone && TerminateProcess(process, 1))
            ended = WaitForSingleObject(process, SH_PROCESS_EXIT_MS) == WAIT_OBJECT_0;
        CloseHandle(process);
    } else gone = stopped;
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return sh_service_stop_outcome(running, stopped, gone, ended);
}

void sh_ceg_scm_release(const struct sh_observer *o)
{
    if (!manager_process) return;
    bool alive = WaitForSingleObject(manager_process, 0) != WAIT_OBJECT_0;
    o->event("ceg-service-stop", alive ? stop_client_service(o) : SH_SERVICE_STOP_FAILED);
    bool ended = !alive;
    if (alive && TerminateProcess(manager_process, 0))
        ended = WaitForSingleObject(manager_process, SH_PROCESS_EXIT_MS) == WAIT_OBJECT_0;
    o->event("ceg-scm-stopped", ended);
    CloseHandle(manager_process);
    manager_process = NULL;
}

/* ml2014: `dockhost.exe --start-services`. Madeira's one-time-install batch
 * runs this before a game's installers: Windows installers expect a service
 * manager, and a Dock session otherwise starts none before this host. Only
 * Wine's standard services.exe is started (the same bounded start as above),
 * and only when no manager answers. It is left running: a Wine system process
 * that ends with the session. The later host run finds it already running,
 * so it does not own it and never stops it. MADEIRA_DOCK_INSTALL_SCM=0: no-op.
 */
int32_t sh_install_scm_start(const struct sh_observer *o)
{
    bool enabled = !wide_flag(L"MADEIRA_DOCK_INSTALL_SCM", L'0');
    SC_HANDLE manager = NULL;
    DWORD first = 0, error = 0;
    if (enabled) {
        manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        first = error = manager ? 0 : GetLastError();
        if (!manager && sh_install_scm_should_spawn(enabled, first))
            error = start_manager(o, &manager, "install-scm-started");
    }
    bool spawned = manager_process != NULL;
    enum sh_install_scm outcome = sh_install_scm_outcome(enabled, first, spawned, manager != NULL);
    if (outcome == SH_INSTALL_SCM_FAILED) o->event("install-scm-error", (int32_t)error);
    if (manager) CloseServiceHandle(manager);
    if (manager_process) {
        /* A manager this call started but that never answered is not left
         * behind half-started; a working one stays for the session.
         */
        if (outcome == SH_INSTALL_SCM_FAILED && WaitForSingleObject(manager_process, 0) != WAIT_OBJECT_0 &&
            TerminateProcess(manager_process, 0))
            WaitForSingleObject(manager_process, SH_PROCESS_EXIT_MS);
        CloseHandle(manager_process);
        manager_process = NULL;
    }
    o->event("install-scm", outcome);
    return outcome;
}

/* ml2020: the game session's service manager (scm.h). */
int32_t sh_game_scm_foreign_services(void)
{
    wchar_t windows[MAX_PATH];
    UINT length = GetWindowsDirectoryW(windows, MAX_PATH);
    if (!length || length >= MAX_PATH) wcscpy(windows, L"C:\\windows");
    HKEY services = NULL;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"System\\CurrentControlSet\\Services", 0,
                      KEY_READ, &services) != ERROR_SUCCESS) return -1;
    int32_t foreign = 0;
    static wchar_t image[8192], expanded[8192];
    for (DWORD index = 0; index < 4096; ++index) {
        wchar_t name[256];
        DWORD name_length = 256;
        LSTATUS status = RegEnumKeyExW(services, index, name, &name_length, NULL, NULL, NULL, NULL);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) continue;
        HKEY service = NULL;
        if (RegOpenKeyExW(services, name, 0, KEY_QUERY_VALUE, &service) != ERROR_SUCCESS) continue;
        DWORD type = 0, start = 0, size = sizeof(DWORD), kind = 0;
        bool known = RegQueryValueExW(service, L"Type", NULL, &kind, (BYTE *)&type, &size) == ERROR_SUCCESS &&
                     kind == REG_DWORD && size == sizeof(DWORD);
        size = sizeof(DWORD);
        known = known && RegQueryValueExW(service, L"Start", NULL, &kind, (BYTE *)&start, &size) == ERROR_SUCCESS &&
                kind == REG_DWORD && size == sizeof(DWORD);
        /* Only automatic Win32 services need the image read at all. */
        if (known && (type & 0x30u) && start == 2) {
            size = sizeof(image) - sizeof(wchar_t);
            const wchar_t *path = NULL;
            if (RegQueryValueExW(service, L"ImagePath", NULL, &kind, (BYTE *)image, &size) == ERROR_SUCCESS &&
                (kind == REG_SZ || kind == REG_EXPAND_SZ) && size >= sizeof(wchar_t)) {
                image[size / sizeof(wchar_t)] = 0;
                path = image;
                if (kind == REG_EXPAND_SZ) {
                    DWORD got = ExpandEnvironmentStringsW(image, expanded, 8192);
                    if (got && got < 8192) path = expanded;
                }
            }
            if (sh_service_is_foreign_autostart(type, start, path, windows)) foreign++;
        }
        RegCloseKey(service);
    }
    RegCloseKey(services);
    return foreign;
}

struct game_scm_work { const struct sh_observer *o; volatile LONG outcome; };

/* The worker's events would interleave with the host's after a timeout, so
 * it reports nothing; the host reports the outcome. */
static void quiet_event(const char *stage, int32_t value) { (void)stage; (void)value; }

static DWORD WINAPI game_scm_worker(void *parameter)
{
    struct game_scm_work *work = parameter;
    struct sh_observer quiet = {work->o->now_ms, work->o->sleep_ms, quiet_event};
    InterlockedExchange(&work->outcome, sh_install_scm_start(&quiet));
    return 0;
}

int32_t sh_game_scm_start(const struct sh_observer *o, bool *timed_out)
{
    /* Static: a timed-out worker may still write to it after this returns. */
    static struct game_scm_work work;
    *timed_out = false;
    work.o = o;
    InterlockedExchange(&work.outcome, SH_INSTALL_SCM_FAILED);
    HANDLE worker = CreateThread(NULL, 0, game_scm_worker, &work, 0, NULL);
    if (!worker) return sh_install_scm_start(o);
    if (WaitForSingleObject(worker, SH_GAME_SCM_STEP_MS) != WAIT_OBJECT_0) *timed_out = true;
    CloseHandle(worker);
    return *timed_out ? SH_INSTALL_SCM_FAILED : InterlockedCompareExchange(&work.outcome, 0, 0);
}
