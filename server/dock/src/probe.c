/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#include "probe.h"
#include <stddef.h>

_Static_assert(offsetof(struct sh_callback, data) == 8, "callback payload offset");
_Static_assert(sizeof(struct sh_callback) == (sizeof(void *) == 8 ? 24 : 16),
               "Windows callback packing");

int sh_probe_bootstrap(const struct sh_api *api, const struct sh_observer *o)
{
    int32_t pipe = 0, user;
    int result = SH_OK, callbacks = 0;
    uint64_t start;

    if (!api || !o || !api->create_global_user || !api->release_user ||
        !api->release_pipe || !api->get_callback || !api->free_callback ||
        !api->logged_on || !o->now_ms || !o->sleep_ms || !o->event)
        return SH_BAD_API;

    o->event("create-global-user-begin", 0);
    user = api->create_global_user(&pipe);
    if (user <= 0 || pipe <= 0) {
        o->event("create-global-user-failed", 0);
        /* A failed creation may still allocate a pipe. Release only handles
         * returned by this call; never attach to another client's global user.
         */
        result = SH_CREATE_FAILED;
        goto cleanup;
    }
    o->event("global-user-created", 1);
    o->event("logged-on-not-ownership", api->logged_on(user, pipe) ? 1 : 0);

    start = o->now_ms();
    /* Bound both time and iteration count. A busy callback queue must not
     * starve the deadline; a stalled clock must not cause an endless probe.
     * These limits cannot interrupt a blocked call inside Valve's DLL.
     */
    for (unsigned tick = 0; tick < 250 && o->now_ms() - start < 5000; ++tick) {
        for (unsigned batch = 0; batch < 64; ++batch) {
            struct sh_callback msg = {0};
            if (!api->get_callback(pipe, &msg)) break;
            ++callbacks;
            /* Release each borrowed buffer exactly once, including malformed
             * callbacks. Do not dereference its payload or infer a licence.
             */
            bool valid = msg.id > 0 && msg.size >= 0 && (!msg.size || msg.data);
            if (callbacks <= 8) o->event("callback-id", msg.id);
            api->free_callback(pipe);
            if (!valid) {
                result = SH_CALLBACK_INVALID;
                goto cleanup;
            }
        }
        o->sleep_ms(20);
    }
    o->event("callback-count", callbacks);
    o->event("logged-on-not-ownership", api->logged_on(user, pipe) ? 1 : 0);

cleanup:
    o->event("release-begin", 0);
    if (pipe > 0 && user > 0) api->release_user(pipe, user);
    if (pipe > 0 && !api->release_pipe(pipe) && result == SH_OK)
        result = SH_RELEASE_FAILED;
    o->event("bootstrap-result", result);
    return result;
}
