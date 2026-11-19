/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1810: exported-API bootstrap experiment for an installed Steam client.
 * This is a diagnostic host, not a game launcher or an ownership authority.
 */
#ifndef MADEIRA_STEAM_HOST_PROBE_H
#define MADEIRA_STEAM_HOST_PROBE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef _WIN32
#define SH_CALL __cdecl
#else
#define SH_CALL
#endif

/* Native Windows callback layout (default packing: 8). No payload is decoded
 * or logged: callbacks may contain account information and authentication data.
 * The handle and callback layout are described by OpenSteamworks; see README.
 */
struct sh_callback {
    int32_t user;
    int32_t id;
    void *data;
    int32_t size;
};

struct sh_api {
    int32_t (SH_CALL *create_global_user)(int32_t *pipe);
    void (SH_CALL *release_user)(int32_t pipe, int32_t user);
    bool (SH_CALL *release_pipe)(int32_t pipe);
    bool (SH_CALL *get_callback)(int32_t pipe, struct sh_callback *callback);
    void (SH_CALL *free_callback)(int32_t pipe);
    bool (SH_CALL *logged_on)(int32_t user, int32_t pipe);
};

struct sh_observer {
    uint64_t (*now_ms)(void);
    void (*sleep_ms)(uint32_t milliseconds);
    void (*event)(const char *stage, int32_t value);
};

enum sh_result {
    SH_OK = 0,                 /* bootstrap only; never authorization */
    SH_BAD_API = 10,
    SH_CREATE_FAILED = 11,
    SH_CALLBACK_INVALID = 12,
    SH_RELEASE_FAILED = 13
};

/* All Steam calls execute on one thread. This never logs on, logs off,
 * revokes credentials, publishes ActiveProcess, or starts a game.
 */
int sh_probe_bootstrap(const struct sh_api *api, const struct sh_observer *observer);

#endif
