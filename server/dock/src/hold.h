/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#ifndef MADEIRA_STEAM_HOST_HOLD_H
#define MADEIRA_STEAM_HOST_HOLD_H
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include "probe.h"
/* ml2020: the game's own process tree, followed while the game runs so the
 * session can be held when Valve's client stops reporting the game as
 * running although the tree is still starting or showing something
 * (validation.h, sh_keep_alive_*). Dock only looks: it opens processes for
 * their image path and start time and enumerates windows; it never ends or
 * signals any of them.
 */
#define SH_HOLD_ENTRIES 256
#define SH_HOLD_POLL_MS 1000ULL
#define SH_HOLD_FORGET_MS 30000ULL
struct sh_hold_entry {
    uint32_t pid, parent;
    uint64_t born_ms, last_seen_ms;   /* observer clock; born from the process's own start time when known */
    bool windows_image;
};
struct sh_hold {
    struct sh_hold_entry entries[SH_HOLD_ENTRIES];
    unsigned count, holders, polls, dropped;
    uint64_t polled_at;
    bool holding;
    uint32_t self;
    const wchar_t *listed;            /* MADEIRA_DOCK_KEEP_ALIVE's image names, or NULL */
    wchar_t windows_dir[MAX_PATH];
};
void sh_hold_init(struct sh_hold *hold, const wchar_t *listed);
/* Called at any rate; at most once per SH_HOLD_POLL_MS it takes a process
 * snapshot, follows the tree and recomputes whether any member holds the
 * session. Returns that answer (the last one between polls). */
bool sh_hold_poll(struct sh_hold *hold, const struct sh_observer *o);
#endif
