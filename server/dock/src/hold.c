/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml2020: follow the game's process tree and decide whether it still holds
 * the session (hold.h). Only observation: snapshots, limited process queries
 * and window enumeration; nothing is created, ended or signalled.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>
#include "hold.h"
#include "validation.h"

void sh_hold_init(struct sh_hold *hold, const wchar_t *listed)
{
    memset(hold, 0, sizeof(*hold));
    hold->self = GetCurrentProcessId();
    hold->listed = listed && *listed ? listed : NULL;
    UINT length = GetWindowsDirectoryW(hold->windows_dir, MAX_PATH);
    if (!length || length >= MAX_PATH) wcscpy(hold->windows_dir, L"C:\\windows");
}

static struct sh_hold_entry *find_entry(struct sh_hold *hold, uint32_t pid)
{
    for (unsigned i = 0; i < hold->count; ++i)
        if (hold->entries[i].pid == pid) return &hold->entries[i];
    return NULL;
}

/* A member's child joins; a Windows image's child (a service, rpcss, a
 * console host) does not: those belong to Windows, not to the game. */
static bool parent_is_member(struct sh_hold *hold, uint32_t parent)
{
    if (parent == hold->self) return true;
    const struct sh_hold_entry *entry = find_entry(hold, parent);
    return entry && !entry->windows_image;
}

/* The image path and start time of a process this host may query; both are
 * optional (a process may be gone, or refuse): then the name decides and
 * the first sighting counts as its birth. */
static void describe(struct sh_hold *hold, uint32_t pid, const wchar_t *name, uint64_t now,
                     struct sh_hold_entry *entry)
{
    entry->pid = pid;
    entry->born_ms = now;
    entry->last_seen_ms = now;
    entry->windows_image = false;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) process = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pid);
    static wchar_t path[32768];
    DWORD length = 32768;
    if (process && QueryFullProcessImageNameW(process, 0, path, &length) && length && length < 32768)
        entry->windows_image = sh_image_is_windows(path, hold->windows_dir);
    else if (name)
        entry->windows_image = sh_image_is_windows(name, hold->windows_dir);
    FILETIME created, exited, kernel, user, current;
    if (process && GetProcessTimes(process, &created, &exited, &kernel, &user)) {
        GetSystemTimeAsFileTime(&current);
        uint64_t born = ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
        uint64_t at = ((uint64_t)current.dwHighDateTime << 32) | current.dwLowDateTime;
        if (at > born) {
            uint64_t age = (at - born) / 10000ULL;
            entry->born_ms = age < now ? now - age : 0;
        }
    }
    if (process) CloseHandle(process);
}

struct window_scan { uint32_t *pids; unsigned count, capacity; };

static BOOL CALLBACK on_window(HWND window, LPARAM parameter)
{
    struct window_scan *scan = (struct window_scan *)parameter;
    if (!IsWindowVisible(window)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (!pid) return TRUE;
    for (unsigned i = 0; i < scan->count; ++i) if (scan->pids[i] == pid) return TRUE;
    if (scan->count < scan->capacity) scan->pids[scan->count++] = pid;
    return TRUE;
}

bool sh_hold_poll(struct sh_hold *hold, const struct sh_observer *o)
{
    uint64_t now = o->now_ms();
    if (hold->polls && now - hold->polled_at < SH_HOLD_POLL_MS) return hold->holding;
    hold->polled_at = now;
    hold->polls++;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return hold->holding;
    PROCESSENTRY32W process = {0};
    process.dwSize = sizeof(process);
    /* Two passes over one snapshot: a child listed before its parent joins
     * in the second. Deeper chains join at the next poll. */
    for (unsigned pass = 0; pass < 2; ++pass) {
        if (!Process32FirstW(snapshot, &process)) break;
        do {
            uint32_t pid = process.th32ProcessID, parent = process.th32ParentProcessID;
            if (!pid || pid == hold->self) continue;
            struct sh_hold_entry *entry = find_entry(hold, pid);
            if (entry) {
                entry->last_seen_ms = now;
                entry->parent = parent;
                continue;
            }
            if (!parent_is_member(hold, parent) && !sh_keep_alive_listed(hold->listed, process.szExeFile)) continue;
            if (hold->count >= SH_HOLD_ENTRIES) {
                hold->dropped++;
                continue;
            }
            entry = &hold->entries[hold->count++];
            describe(hold, pid, process.szExeFile, now, entry);
            entry->parent = parent;
        } while (Process32NextW(snapshot, &process));
    }
    CloseHandle(snapshot);
    uint32_t visible[SH_HOLD_ENTRIES];
    struct window_scan scan = {visible, 0, SH_HOLD_ENTRIES};
    EnumWindows(on_window, (LPARAM)&scan);
    unsigned holders = 0, kept = 0;
    for (unsigned i = 0; i < hold->count; ++i) {
        struct sh_hold_entry *entry = &hold->entries[i];
        bool alive = entry->last_seen_ms == now;
        if (!alive && now - entry->last_seen_ms >= SH_HOLD_FORGET_MS) continue;   /* gone for good; forget it */
        hold->entries[kept++] = *entry;
        if (!alive) continue;
        bool window = false;
        for (unsigned k = 0; k < scan.count && !window; ++k) window = scan.pids[k] == entry->pid;
        if (sh_keep_alive_holds(entry->windows_image, window, now - entry->born_ms, SH_KEEP_ALIVE_YOUNG_MS)) holders++;
    }
    hold->count = kept;
    hold->holders = holders;
    hold->holding = holders > 0;
    return hold->holding;
}
