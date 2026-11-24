/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1820: validation shared by the Windows host and native sanitizer tests.
 */
#include "validation.h"
#include <string.h>
#include <stdio.h>

bool sh_parse_launch_option(const char *text, uint32_t *option)
{
    if (!text || !*text || !option) return false;
    uint32_t value = 0;
    for (unsigned i = 0; text[i]; ++i) {
        if (i >= 10 || text[i] < '0' || text[i] > '9') return false;
        unsigned digit = (unsigned)(text[i] - '0');
        if (value > ((uint32_t)INT32_MAX - digit) / 10) return false;
        value = value * 10 + digit;
    }
    *option = value;
    return true;
}

bool sh_launch_option_missing(const void *payload, size_t size, uint32_t option)
{
    if (!payload || size != 524) return false;
    const char *detail = (const char *)payload + 12;
    const char *end = memchr(detail, 0, 512);
    if (!end) return false;
    char expected[80];
    int length = snprintf(expected, sizeof(expected), "entry for launch option %u not found", (unsigned)option);
    return length > 0 && (size_t)length < sizeof(expected) && strstr(detail, expected) != NULL;
}
bool sh_launch_arguments_valid(const char *arguments, size_t length)
{
    if (!arguments || length >= SH_LAUNCH_ARGUMENTS_CAPACITY) return false;
    bool quoted = false, in_token = false;
    unsigned tokens = 0, slashes = 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)arguments[i];
        if ((c < 32 && c != '\t') || c == 127) return false;
        if (c == '"' && !(slashes & 1)) quoted = !quoted;
        if (!quoted && (c == ' ' || c == '\t')) in_token = false;
        else if (!in_token) { ++tokens; in_token = true; }
        slashes = c == '\\' ? slashes + 1 : 0;
    }
    return !quoted && tokens <= SH_LAUNCH_ARGUMENTS_MAX_TOKENS;
}

bool sh_subscription_list_contains(const uint32_t *apps, int32_t count,
                                   size_t capacity, uint32_t requested)
{
    if (!apps || count <= 0 || (size_t)count >= capacity || !requested || requested == UINT32_MAX)
        return false;
    for (int32_t i = 0; i < count; ++i) if (apps[i] == requested) return true;
    return false;
}

bool sh_decode_launch_result(const void *payload, size_t size, uint64_t expected_game,
                             int32_t *error)
{
    uint64_t returned_game;
    if (!payload || !error || size != 524) return false;
    memcpy(&returned_game, payload, sizeof(returned_game));
    if (returned_game != expected_game) return false;
    memcpy(error, (const char *)payload+8, sizeof(*error));
    return true;
}

/* ml1970: Valve's client refuses a launch while the app, or an app owning one
 * of its shared depots, still needs content: 17 dependency not ready,
 * 19 update required, 20 still busy. Desktop Steam lets its client finish
 * that update and then starts the game; the host keeps Valve's client alive
 * and asks again. Every other result, including licence and connection
 * failures, still fails closed.
 */
bool sh_launch_error_waits_for_content(int32_t error)
{
    return error == 17 || error == 19 || error == 20;
}

/* ml2011: 22 invalid app config and 23 invalid depot config also come back when
 * Valve's client has not yet received the app's configuration from Steam after
 * signing in (a freshly started client begins with an empty app-info cache).
 * The host asks again for a bounded time; a genuinely broken configuration
 * still fails closed once the bound passes.
 */
bool sh_launch_error_waits_for_config(int32_t error)
{
    return error == 22 || error == 23;
}

/* ml2015: 35, another session is playing on this account. */
bool sh_launch_error_waits_for_session(int32_t error)
{
    return error == 35;
}

/* 10 s, 20 s, then every 30 s: the client schedules its update after the
 * first refusal, so later requests only confirm that it has finished.
 */
uint32_t sh_launch_retry_delay_ms(unsigned attempt)
{
    return attempt == 0 ? 10000 : attempt == 1 ? 20000 : 30000;
}

/* ml1990: Valve's client customizes CustomExecutable files per user. Its
 * RequestCustomBinaries returns an EResult and writes the number of per-file
 * jobs it started; each job then posts its own EResult for this AppID. Only
 * k_EResultOK (1) from every started job counts as success. Busy (10) means
 * the app is currently updating or running and may be asked again. Any
 * other result, including OK with zero jobs, fails closed: without prepared
 * binaries the protected executable cannot start.
 */
static bool decode_ceg(const void *payload, size_t size, size_t expected,
                       uint32_t appid, int32_t *result)
{
    uint32_t returned;
    if (!payload || !result || size != expected || !appid) return false;
    memcpy(&returned, (const char *)payload+4, sizeof(returned));
    if (returned != appid) return false;
    memcpy(result, payload, sizeof(*result));
    return true;
}

bool sh_decode_ceg_job(const void *payload, size_t size, uint32_t appid, int32_t *result)
{
    return decode_ceg(payload, size, 8, appid, result);
}

bool sh_decode_ceg_reply(const void *payload, size_t size, uint32_t appid, int32_t *result)
{
    return decode_ceg(payload, size, 12, appid, result);
}

enum sh_ceg_step sh_ceg_request_step(int32_t result, uint32_t jobs, struct sh_ceg_progress *progress)
{
    if (!progress) return SH_CEG_FAIL;
    if (result == 10) return SH_CEG_RETRY;
    if (result != 1 || !jobs || jobs > SH_CEG_MAX_JOBS) {
        progress->failure = result == 1 ? 0 : result;
        return SH_CEG_FAIL;
    }
    *progress = (struct sh_ceg_progress){jobs, 0, 0};
    return SH_CEG_WAIT;
}

enum sh_ceg_step sh_ceg_record_job(struct sh_ceg_progress *progress, int32_t result)
{
    if (!progress || !progress->expected || progress->finished >= progress->expected)
        return SH_CEG_FAIL;
    if (result != 1) {
        progress->failure = result;
        return SH_CEG_FAIL;
    }
    return ++progress->finished == progress->expected ? SH_CEG_DONE : SH_CEG_WAIT;
}

/* ml2000: Wine's sechost reports a missing \pipe\svcctl listener as
 * RPC_S_SERVER_UNAVAILABLE (1722). Only that means "no service manager": any
 * other failure (for example access denied) is not fixed by starting one.
 * RPC_S_SERVER_TOO_BUSY (1723) can occur while a new manager is starting.
 */
bool sh_scm_error_means_absent(uint32_t error)
{
    return error == 1722;
}

bool sh_scm_error_retryable(uint32_t error)
{
    return error == 1722 || error == 1723;
}

int32_t sh_ceg_scm_result(bool manager_reachable, bool service_registered)
{
    if (!manager_reachable) return SH_CEG_SCM_UNAVAILABLE;
    return service_registered ? 0 : SH_CEG_SERVICE_UNREGISTERED;
}

uint32_t sh_remaining_ms(uint64_t now, uint64_t begin, uint64_t bound)
{
    uint64_t elapsed = now >= begin ? now - begin : 0;
    if (elapsed >= bound) return 0;
    uint64_t left = bound - elapsed;
    return left > UINT32_MAX - 1 ? UINT32_MAX - 1 : (uint32_t)left;
}

uint32_t sh_scm_poll_slice_ms(uint32_t left)
{
    return left < SH_SCM_POLL_MS ? left : SH_SCM_POLL_MS;
}

/* A service counts as stopped only when the manager reports it stopped and
 * its process is gone; a process that outlives the bound is ended by the host.
 */
enum sh_service_stop sh_service_stop_outcome(bool was_running, bool stopped_by_manager,
                                             bool process_gone, bool ended_by_host)
{
    if (!was_running) return SH_SERVICE_NOT_RUNNING;
    if (stopped_by_manager && process_gone) return SH_SERVICE_STOPPED;
    if (ended_by_host) return SH_SERVICE_ENDED_AFTER_BOUND;
    return SH_SERVICE_STOP_FAILED;
}

/* Never re-run the installer over an existing registration or when the
 * service manager answered with an unexpected error (fail closed as -5).
 */
bool sh_should_install_service(bool registered, bool missing, bool install_enabled)
{
    return install_enabled && !registered && missing;
}

int32_t sh_service_install_report(bool file_present, bool finished, uint32_t exit_code)
{
    if (!file_present) return SH_SERVICE_INSTALL_MISSING;
    if (!finished) return SH_SERVICE_INSTALL_TIMEOUT;
    return (int32_t)exit_code;
}

/* ml2014: the install batch's service manager. Never start a second manager:
 * only a definite "no listener" (1722) on the first open spawns one.
 */
bool sh_install_scm_should_spawn(bool enabled, uint32_t first_error)
{
    return enabled && sh_scm_error_means_absent(first_error);
}

enum sh_install_scm sh_install_scm_outcome(bool enabled, uint32_t first_error,
                                           bool spawned, bool reachable)
{
    if (!enabled) return SH_INSTALL_SCM_OFF;
    if (!first_error) return SH_INSTALL_SCM_ALREADY;
    if (!reachable) return SH_INSTALL_SCM_FAILED;
    return spawned ? SH_INSTALL_SCM_STARTED : SH_INSTALL_SCM_ALREADY;
}

const char *sh_install_scm_word(int32_t outcome)
{
    switch (outcome) {
    case SH_INSTALL_SCM_OFF: return "off";
    case SH_INSTALL_SCM_ALREADY: return "already";
    case SH_INSTALL_SCM_STARTED: return "started";
    default: return "failed";
    }
}

/* ml2020: the game session's service manager and the hold (validation.h). */
static wchar_t sh_wide_lower(wchar_t c)
{
    return (c >= L'A' && c <= L'Z') ? (wchar_t)(c + (L'a' - L'A')) : c;
}

/* Case-insensitive, ASCII letters only (image names and Windows paths). */
static bool sh_wide_prefix(const wchar_t *text, const wchar_t *prefix)
{
    if (!text || !prefix) return false;
    for (; *prefix; ++text, ++prefix)
        if (sh_wide_lower(*text) != sh_wide_lower(*prefix)) return false;
    return true;
}

static bool sh_wide_separator(wchar_t c)
{
    return c == L'\\' || c == L'/';
}

enum sh_game_scm_mode sh_game_scm_mode(const wchar_t *value)
{
    if (!value) return SH_GAME_SCM_AUTO;
    if (value[0] == L'0' && !value[1]) return SH_GAME_SCM_OFF;
    if (value[0] == L'1' && !value[1]) return SH_GAME_SCM_ON;
    return SH_GAME_SCM_AUTO;
}

bool sh_path_in_folder(const wchar_t *path, const wchar_t *folder)
{
    if (!path || !folder || !*folder) return false;
    size_t length = wcslen(folder);
    while (length && sh_wide_separator(folder[length - 1])) --length;
    if (!length) return false;
    for (size_t i = 0; i < length; ++i) {
        wchar_t a = sh_wide_lower(path[i]), b = sh_wide_lower(folder[i]);
        if (sh_wide_separator(a) && sh_wide_separator(b)) continue;
        if (a != b) return false;
    }
    return sh_wide_separator(path[length]);
}

bool sh_image_is_windows(const wchar_t *image, const wchar_t *windows_dir)
{
    if (!image) return false;
    /* Registry forms: a quoted path, an NT prefix, or a path relative to the
     * Windows folder. The arguments after the image do not matter here. */
    while (*image == L'"' || *image == L' ') ++image;
    if (sh_wide_prefix(image, L"\\??\\")) image += 4;
    if (sh_wide_prefix(image, L"%SystemRoot%") || sh_wide_prefix(image, L"\\SystemRoot") ||
        sh_wide_prefix(image, L"System32\\") || sh_wide_prefix(image, L"SysWOW64\\") ||
        sh_wide_prefix(image, L"%windir%")) return true;
    return sh_path_in_folder(image, windows_dir);
}

bool sh_service_is_foreign_autostart(uint32_t type, uint32_t start, const wchar_t *image,
                                     const wchar_t *windows_dir)
{
    /* SERVICE_WIN32_*; SERVICE_AUTO_START or SERVICE_DEMAND_START: a program
     * that registered a demand-start service starts it itself through the
     * manager, so it needs one as much as an automatic one does. */
    if (!(type & 0x30u) || (start != 2 && start != 3)) return false;
    if (!image) return false;
    while (*image == L'"' || *image == L' ') ++image;
    if (!*image) return false;
    return !sh_image_is_windows(image, windows_dir);
}

bool sh_game_scm_wanted(enum sh_game_scm_mode mode, unsigned foreign_autostart)
{
    if (mode == SH_GAME_SCM_OFF) return false;
    if (mode == SH_GAME_SCM_ON) return true;
    return foreign_autostart > 0;
}

enum sh_keep_alive_mode sh_keep_alive_mode(const wchar_t *value)
{
    if (value && value[0] == L'0' && !value[1]) return SH_KEEP_ALIVE_OFF;
    return SH_KEEP_ALIVE_AUTO;
}

bool sh_keep_alive_listed(const wchar_t *list, const wchar_t *name)
{
    if (!list || !name || !*name) return false;
    size_t length = wcslen(name);
    const wchar_t *entry = list;
    for (;;) {
        while (*entry == L' ' || *entry == L';') ++entry;
        if (!*entry) return false;
        const wchar_t *end = entry;
        while (*end && *end != L';') ++end;
        const wchar_t *stop = end;
        while (stop > entry && stop[-1] == L' ') --stop;
        if ((size_t)(stop - entry) == length) {
            size_t i = 0;
            while (i < length && sh_wide_lower(entry[i]) == sh_wide_lower(name[i])) ++i;
            if (i == length) return true;
        }
        if (!*end) return false;
        entry = end + 1;
    }
}

bool sh_keep_alive_holds(bool windows_image, bool visible_window, uint64_t age_ms, uint64_t young_ms)
{
    if (windows_image) return false;
    return visible_window || age_ms < young_ms;
}
