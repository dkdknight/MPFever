/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * Host-native fake-API tests. No Steam binaries, accounts or network are used.
 * Exercise handle cleanup, a permanently busy callback queue, and invalid data.
 */
#include "probe.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int scenario, creates, releases, pipe_releases, borrowed, freed, events;
static int sleeps, state_reads;
static uint64_t clock_ms;

static int32_t create_user(int32_t *pipe)
{
    ++creates;
    *pipe = scenario == 1 ? 0 : 7;
    return scenario <= 2 ? 0 : 8;
}
static void release_user(int32_t pipe, int32_t user)
{
    assert(pipe == 7 && user == 8 && borrowed == freed);
    assert(pipe_releases == 0);
    ++releases;
}
static bool release_pipe(int32_t pipe)
{
    assert(pipe == 7);
    if (scenario > 2) assert(releases == 1);
    ++pipe_releases;
    return scenario != 7;
}
static bool get_callback(int32_t pipe, struct sh_callback *msg)
{
    assert(pipe == 7 && borrowed == freed);
    if (scenario == 3 || scenario == 7) return false;
    msg->user = 8;
    msg->id = 101;
    /* Deliberately invalid-to-read address: payloads must never be inspected. */
    msg->data = (void *)(uintptr_t)1;
    msg->size = 4;
    if (scenario == 5) msg->size = -1;
    if (scenario == 8) msg->data = NULL;
    ++borrowed;
    return true;
}
static void free_callback(int32_t pipe)
{
    assert(pipe == 7 && borrowed == freed + 1);
    ++freed;
}
static bool logged_on(int32_t user, int32_t pipe)
{
    assert(user == 8 && pipe == 7);
    ++state_reads;
    return scenario == 6;
}
static uint64_t now_ms(void) { return clock_ms; }
static void sleep_ms(uint32_t ms)
{
    assert(ms == 20);
    ++sleeps;
    if (scenario != 6) clock_ms += ms;
}
static void event(const char *stage, int32_t value)
{
    assert(stage && strlen(stage) < 64);
    (void)value;
    ++events;
}

int main(void)
{
    const struct sh_api api = {create_user, release_user, release_pipe,
                               get_callback, free_callback, logged_on};
    const struct sh_observer observer = {now_ms, sleep_ms, event};
    struct sh_api missing = api;
    missing.free_callback = NULL;
    assert(sh_probe_bootstrap(NULL, &observer) == SH_BAD_API);
    assert(sh_probe_bootstrap(&api, NULL) == SH_BAD_API);
    assert(sh_probe_bootstrap(&missing, &observer) == SH_BAD_API);
    assert(creates == 0);

    for (scenario = 1; scenario <= 8; ++scenario) {
        creates = releases = pipe_releases = borrowed = freed = events = 0;
        sleeps = state_reads = 0;
        clock_ms = 0;
        int result = sh_probe_bootstrap(&api, &observer);
        assert(creates == 1 && borrowed == freed);
        assert(releases == (scenario > 2 ? 1 : 0));
        assert(pipe_releases == (scenario > 1 ? 1 : 0));
        assert(events <= 16);
        if (scenario <= 2) {
            assert(result == SH_CREATE_FAILED && sleeps == 0 && state_reads == 0);
        } else if (scenario == 5 || scenario == 8) {
            assert(result == SH_CALLBACK_INVALID && borrowed == 1 && sleeps == 0);
        } else {
            assert(result == (scenario == 7 ? SH_RELEASE_FAILED : SH_OK));
            assert(sleeps == 250 && state_reads == 2);
        }
        if (scenario == 4 || scenario == 6) assert(borrowed == 16000);
        if (scenario == 6) assert(clock_ms == 0); /* stalled clock stays bounded */
    }
    puts("steam-host: 11 bootstrap lifecycle and failure scenarios passed");
    return 0;
}
