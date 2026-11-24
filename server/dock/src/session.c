/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1820: opt-in native Windows authentication experiment. All login and
 * entitlement decisions belong to Valve's unmodified client. No credential
 * extraction, token fabrication, or API replacement is performed here.
 */
#include "session.h"
#include "launch.h"
#include "validation.h"
#include "auth.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef _WIN64
typedef void *(__thiscall *get_user_fn)(void *, int32_t, int32_t);
typedef bool (__thiscall *query_fn)(void *);
typedef bool (__thiscall *cached_fn)(void *, const char *);
typedef bool (__thiscall *select_fn)(void *, const char *, bool);
typedef int32_t (__thiscall *logon_fn)(void *, uint64_t);
typedef void (__thiscall *token_fn)(void *, const char *, const char *);
typedef bool (__thiscall *subscribed_fn)(void *, uint32_t);
typedef int32_t (__thiscall *subscriptions_fn)(void *, uint32_t *, int32_t, bool);

/* Each layout has an exact SHA-256 gate and independently inspected methods.
 * Unsupported versions fail closed before any private call. */
static bool method_is(HMODULE module, void *object, unsigned slot, uintptr_t rva)
{
    return dock_method_is((uintptr_t)module, object, slot, rva);
}

static bool enabled(const char *name)
{
    const char *s = getenv(name);
    return s && !strcmp(s, "1");
}

typedef int32_t (__thiscall *state_fn)(void *);
typedef int32_t (__thiscall *can_offline_fn)(void *);
typedef int32_t (__thiscall *logon_offline_fn)(void *, bool);

/* Offline start.
 *
 * Nothing here decides ownership or lets a game start by itself. Valve's client
 * is asked whether this account may log on offline (CanLogonOffline: it needs the
 * offline logon ticket Steam issued to it during an earlier online logon, which
 * the client requests and stores on its own), is told to do so (LogOnOffline),
 * and is then asked the same licence question as online, which it answers from
 * what it cached itself. The game is started through the same LaunchApp call. A
 * client that says no at any step ends the session with its own code:
 *   50  the client cannot log this account on offline (start once online first)
 *   51  the client refused the offline logon
 *   52  logged on offline, but the client's cache does not list the game
 * There is no path from a refusal to a started game. */
static int offline_session(HMODULE module, void *engine, void *client_user, const struct sh_api *api,
                           const struct sh_observer *o, int32_t pipe, int32_t user, uint64_t id,
                           uint32_t app, const struct dock_client_layout *layout, bool use_list)
{
    void **v = *(void ***)client_user;
    int32_t can = ((can_offline_fn)v[214])(client_user);
    o->event("session-offline-can", can);
    if (can != 1) return 50;
    /* The wrapper takes one bool whose meaning the interface does not name; the
     * client is asked with false first and, only if it refuses, once with true.
     * Which one it accepted is reported. */
    int32_t started = ((logon_offline_fn)v[215])(client_user, false);
    o->event("session-offline-logon-result", started);
    if (started != 1) {
        started = ((logon_offline_fn)v[215])(client_user, true);
        o->event("session-offline-logon-retry", started);
    }
    if (started != 1) return 51;

    uint64_t begin = o->now_ms(), last_list = 0;
    int32_t last_state = -1;
    unsigned logged_callbacks = 0;
    for (unsigned tick = 0; tick < 3000 && o->now_ms() - begin < 60000; ++tick) {
        for (unsigned batch = 0; batch < 64; ++batch) {
            struct sh_callback cb = {0};
            if (!api->get_callback(pipe, &cb)) break;
            bool valid = cb.id > 0 && cb.size >= 0 && (!cb.size || cb.data);
            if (logged_callbacks++ < 16) o->event("session-offline-callback-id", cb.id);
            api->free_callback(pipe);
            if (!valid) return SH_CALLBACK_INVALID;
        }
        int32_t state = ((state_fn)v[5])(client_user);
        if (state != last_state) {
            o->event("session-offline-logon-state", state);
            last_state = state;
        }
        uint64_t now = o->now_ms();
        /* The client loads its cached licences after the offline logon; give it a
         * second before the first question, then ask once a second. */
        if (now - begin >= 1000 && now - last_list >= 1000) {
            bool entitled = ((subscribed_fn)v[181])(client_user, app);
            bool listed = false;
            int32_t count = -1;
            if (entitled || use_list) {
                uint32_t *apps = calloc(65536, sizeof(uint32_t));
                if (!apps) return 36;
                count = ((subscriptions_fn)v[182])(client_user, apps, 65536, true);
                if (count < 0 || count >= 65536) { free(apps); return 36; }
                listed = sh_subscription_list_contains(apps, count, 65536, app);
                free(apps);
            }
            last_list = now;
            if (entitled || listed) {
                o->event("session-offline-entitled", entitled);
                o->event("session-offline-listed", listed);
                o->event("session-subscription-count", count);
                if (!listed) return 35;
                if (!enabled("MADEIRA_STEAM_HOST_LAUNCH")) return 0;
                return sh_launch(module, engine, client_user, api, o, pipe, user, id, app, layout);
            }
        }
        o->sleep_ms(20);
    }
    o->event("session-offline-timeout-state", last_state);
    return 52;
}

int sh_session(HMODULE module, void *engine, const struct sh_api *api,
               const struct sh_observer *o, const struct dock_client_layout *layout)
{
    int result = 30;
    struct dock_auth auth = {0};
    int32_t pipe = 0, user = 0;
    if (!layout || !method_is(module, engine, 8, layout->engine_user)) {
        o->event("session-unsupported-client", 1);
        return result;
    }
    user = api->create_global_user(&pipe);
    if (user <= 0 || pipe <= 0) goto done;
    void *client_user = ((get_user_fn)(*(void ***)engine)[8])(engine, user, pipe);
    if (!client_user) goto done;
    o->event("session-user-vtable-rva", (int32_t)((uintptr_t)*(void **)client_user - (uintptr_t)module));
    const struct { unsigned slot; uintptr_t rva; } methods[] = {
        {1, layout->logon}, {4, layout->logged_on}, {6, layout->connected},
        {49, layout->cached}, {50, layout->select_account}, {56, layout->token},
        {181, layout->subscribed}, {182, layout->subscriptions}
    };
    for (unsigned i = 0; i < sizeof(methods)/sizeof(methods[0]); ++i) {
        if (!method_is(module, client_user, methods[i].slot, methods[i].rva)) {
            o->event("session-user-method-mismatch", (int32_t)methods[i].slot);
            goto done;
        }
    }
    o->event("session-private-abi-verified", 1);
    /* Offline logon needs three more methods. A client where they do not check out
     * (or MADEIRA_DOCK_OFFLINE_LOGON=0) simply has no offline start; the online
     * path above is unaffected. */
    const char *offline_setting = getenv("MADEIRA_DOCK_OFFLINE_LOGON");
    bool offline_abi = !(offline_setting && !strcmp(offline_setting, "0")) &&
        method_is(module, client_user, 5, layout->logon_state) &&
        method_is(module, client_user, 214, layout->can_offline) &&
        method_is(module, client_user, 215, layout->logon_offline);
    o->event("session-offline-abi", offline_abi);
    if (!enabled("MADEIRA_STEAM_HOST_LOGIN")) {
        o->event("session-login-disabled", 1);
        result = 0;
        goto done;
    }
    /* Account identifiers are passed by the local launcher without printing
     * them. These are not credentials; cached secrets stay inside Valve code.
     * Never call InvalidateCredentials/DestroyCachedCredentials on this path.
     */
    const char *name = getenv("MADEIRA_STEAM_HOST_ACCOUNT");
    const char *id_text = getenv("MADEIRA_STEAM_HOST_STEAMID");
    const char *app_text = getenv("MADEIRA_STEAM_HOST_APPID");
    char *end = NULL;
    uint64_t id = id_text ? strtoull(id_text, &end, 10) : 0;
    wchar_t handoff[32768];
    DWORD handoff_size = GetEnvironmentVariableW(L"MADEIRA_DOCK_AUTH_FILE", handoff, 32768);
    bool native_auth = handoff_size > 0;
    if (native_auth) {
        struct dock_auth_failure failure = {DOCK_AUTH_PATH, 0};
        if (handoff_size >= 32768 || !dock_auth_consume_diagnostic(handoff, &auth, &failure)) {
            const char *diagnostics = getenv("MADEIRA_DOCK_HANDOFF_DIAGNOSTICS");
            if (!diagnostics || strcmp(diagnostics, "0")) {
                o->event("session-handoff-stage", failure.stage);
                o->event("session-handoff-error", (int32_t)failure.error);
            }
            o->event("session-native-handoff-invalid", 1);
            result = 37; goto done;
        }
        name = auth.account; id = auth.steam_id;
    }
    if (!name || !*name || strlen(name) > 64 || !id || (!native_auth && (!end || *end)) ||
        (id >> 56) != 1 || ((id >> 52) & 15) != 1) {
        o->event("session-account-input-invalid", 1);
        goto done;
    }
    end = NULL;
    unsigned long app = app_text ? strtoul(app_text, &end, 10) : 0;
    if (!app || app == UINT32_MAX || !end || *end) {
        o->event("session-app-input-invalid", 1);
        goto done;
    }
    if (native_auth && app != auth.app_id) {
        o->event("session-native-handoff-app-mismatch", 1);
        result = 37; goto done;
    }
    void **v = *(void ***)client_user;
    if (native_auth) {
        ((token_fn)v[56])(client_user, auth.token, auth.account);
        dock_auth_clear(auth.token, sizeof(auth.token));
        o->event("session-native-token-submitted", 1);
    } else {
        bool cached = ((cached_fn)v[49])(client_user, name);
        o->event("session-cached-credentials-available", cached);
        if (!cached) { result = 31; goto done; }
        bool selected = ((select_fn)v[50])(client_user, name, false);
        o->event("session-cached-account-selected", selected);
        if (!selected) { result = 32; goto done; }
    }
    /* MADEIRA_DOCK_LIST_ENTITLEMENT=0: only the single-app query decides, as before. */
    const char *list_setting = getenv("MADEIRA_DOCK_LIST_ENTITLEMENT");
    bool use_list = !(list_setting && !strcmp(list_setting, "0"));
    /* MADEIRA_DOCK_OFFLINE=1: the launcher found no network. Valve's client is
     * asked for an offline logon straight away instead of waiting out a
     * connection that cannot happen. */
    if (enabled("MADEIRA_DOCK_OFFLINE")) {
        o->event("session-offline-requested", 1);
        if (!offline_abi) { result = 50; goto done; }
        result = offline_session(module, engine, client_user, api, o, pipe, user, id,
                                 (uint32_t)app, layout, use_list);
        goto done;
    }
    int32_t started = ((logon_fn)v[1])(client_user, id);
    o->event("session-logon-start-result", started);
    if (started != 1) { result = 33; goto done; }

    uint64_t begin = o->now_ms(), online_at = 0, last_probe = 0, last_list = 0, offline_since = 0;
    bool was_online = false, offline_reported = false;
    unsigned logged_callbacks = 0, online_callbacks = 0, blips = 0, lost = 0, connect_failures = 0;
    /* How long after sign-in before ownership is first asked. The answer is only
     * ever taken when it is yes, so asking early costs nothing: this used to be a
     * fixed 5 s in which a client that already had the licence list sat idle.
     * MADEIRA_DOCK_LICENCE_WAIT_MS sets it (0..30000). */
    uint64_t licence_wait = 500;
    const char *wait_setting = getenv("MADEIRA_DOCK_LICENCE_WAIT_MS");
    uint32_t value;
    if (sh_parse_launch_option(wait_setting, &value) && value <= 30000) licence_wait = value;
    result = 34;
    for (unsigned tick = 0; tick < 4500 && o->now_ms() - begin < 90000; ++tick) {
        for (unsigned batch = 0; batch < 64; ++batch) {
            struct sh_callback cb = {0};
            if (!api->get_callback(pipe, &cb)) break;
            bool valid = cb.id > 0 && cb.size >= 0 && (!cb.size || cb.data);
            if (logged_callbacks++ < 16) o->event("session-callback-id", cb.id);
            /* Which callback types arrive once signed in (numbers only): tells a
             * licence list that never came from one that came and did not list
             * the app. */
            else if (was_online && online_callbacks < 32) {
                o->event("session-online-callback-id", cb.id);
                ++online_callbacks;
            }
            if (valid && (cb.id == 102 || cb.id == 103) && cb.size >= 4) {
                int32_t error;
                memcpy(&error, cb.data, 4);
                o->event("session-connection-result", error);
                if (cb.id == 102) ++connect_failures;
            }
            api->free_callback(pipe);
            if (!valid) { result = SH_CALLBACK_INVALID; goto done; }
        }
        /* The network went away without the launcher noticing: the client has
         * reported a failed connection, 20 s have passed and it never signed in.
         * If Valve's client says the account may log on offline, do that instead
         * of waiting out the 90 s. A client that says no keeps waiting as before. */
        if (offline_abi && !was_online && connect_failures && o->now_ms() - begin >= 20000) {
            int32_t can = ((can_offline_fn)v[214])(client_user);
            o->event("session-offline-fallback", can);
            if (can == 1) {
                result = offline_session(module, engine, client_user, api, o, pipe, user, id,
                                         (uint32_t)app, layout, use_list);
                goto done;
            }
            connect_failures = 0;   /* ask again only after another failed connection */
        }
        bool signed_in = api->logged_on(user, pipe) &&
            ((query_fn)v[4])(client_user) && ((query_fn)v[6])(client_user);
        uint64_t now = o->now_ms();
        /* A momentary "not signed in" answer (the client between two of its own
         * ticks, or an in-process answer that did not arrive in time) used to
         * restart the 5 s licence wait, so a client that blipped every few
         * seconds was never asked at all. Signed out now means signed out for a
         * whole second; shorter blips are counted and reported (durations in ms). */
        if (signed_in) {
            if (offline_since) {
                if (++blips <= 8) o->event("session-online-blip", (int32_t)(now - offline_since));
                offline_since = 0;
            }
            if (!was_online) {
                was_online = true;
                online_at = now;
                o->event("session-authenticated-online", 1);
            }
        } else if (was_online) {
            if (!offline_since) offline_since = now;
            else if (now - offline_since >= 1000) {
                was_online = false;
                online_at = 0;
                offline_since = 0;
                ++lost;
                o->event("session-authenticated-online", 0);
            }
        }
        /* Allow the real licence/app-info callbacks to arrive after logon.
         * A true subscription is required; timeout never permits launch.
         */
        if (was_online && !offline_since && now - online_at >= licence_wait) {
            bool entitled = ((subscribed_fn)v[181])(client_user, (uint32_t)app);
            if (!entitled && now - last_probe >= 10000) {
                /* Not yet, every 10 s: how many apps the account's licences give the
                 * client so far, and whether it owns app 0 (the client itself, which
                 * every account has). 0 and false mean the ownership map is not built
                 * yet; a count without the requested app means the licences arrived
                 * without it. Counts only, no App IDs. */
                uint32_t *probe = calloc(65536, sizeof(uint32_t));
                if (probe) {
                    o->event("session-online-subscription-count",
                             ((subscriptions_fn)v[182])(client_user, probe, 65536, true));
                    free(probe);
                }
                o->event("session-online-app-zero-query", ((subscribed_fn)v[181])(client_user, 0));
                last_probe = now;
            }
            /* The list of the account's subscribed apps is Valve's client's other
             * answer to the same question. On one platform the single-app query
             * stayed false for the whole wait while this list held the app the
             * whole time. Unless MADEIRA_DOCK_LIST_ENTITLEMENT=0, an app in that
             * list counts as owned (once a second while the query says no); the
             * client's own launch path still decides for itself. */
            if (entitled || (use_list && now - last_list >= 250)) {
                uint32_t *apps = calloc(65536, sizeof(uint32_t));
                if (!apps) { result = 36; break; }
                int32_t count = ((subscriptions_fn)v[182])(client_user, apps, 65536, true);
                bool listed = false;
                if (count < 0 || count >= 65536) {
                    free(apps); result = 36; break;
                }
                listed = sh_subscription_list_contains(apps, count, 65536, (uint32_t)app);
                free(apps);
                last_list = now;
                if (entitled || listed) {
                    o->event("session-requested-app-entitled", entitled);
                    o->event("session-subscription-count", count);
                    o->event("session-requested-app-listed", listed);
                    if (!entitled) o->event("session-entitlement-source", 182);
                    o->event("session-app-zero-query", ((subscribed_fn)v[181])(client_user, 0));
                    o->event("session-invalid-app-query", ((subscribed_fn)v[181])(client_user, UINT32_MAX));
                    result = listed ? 0 : 35;
                    /* For the launcher's "saved for offline play" mark: whether
                     * Valve's client now holds what it needs to log this account
                     * on without a connection (1 = yes). Asked when the licence is
                     * confirmed and again after the game, since the client fetches
                     * its offline logon ticket on its own schedule. */
                    if (!result && offline_abi) {
                        int32_t ready = ((can_offline_fn)v[214])(client_user);
                        o->event("session-offline-ready", ready);
                        offline_reported = ready == 1;
                    }
                    if (!result && enabled("MADEIRA_STEAM_HOST_LAUNCH")) {
                        result = sh_launch(module, engine, client_user, api, o, pipe, user, id, (uint32_t)app, layout);
                        if (offline_abi && !offline_reported)
                            o->event("session-offline-ready", ((can_offline_fn)v[214])(client_user));
                    }
                    break;
                }
            }
        }
        o->sleep_ms(20);
    }
    if (blips) o->event("session-online-blips", (int32_t)blips);
    if (lost) o->event("session-online-lost", (int32_t)lost);
    /* Timed out while signed in: report how many apps the account's licences
     * give Valve's client (a count, no App IDs) and whether the requested one
     * is among them. 0 means the licence list never arrived or was never
     * processed; a count without the app means it arrived without this game. */
    if (result == 34 && was_online) {
        uint32_t *apps = calloc(65536, sizeof(uint32_t));
        if (apps) {
            int32_t count = ((subscriptions_fn)v[182])(client_user, apps, 65536, true);
            o->event("session-timeout-subscription-count", count);
            if (count >= 0 && count < 65536)
                o->event("session-timeout-app-listed",
                         sh_subscription_list_contains(apps, count, 65536, (uint32_t)app));
            free(apps);
        }
        o->event("session-timeout-still-online", api->logged_on(user, pipe) &&
                 ((query_fn)v[4])(client_user) && ((query_fn)v[6])(client_user));
    }
done:
    dock_auth_clear(&auth, sizeof(auth));
    o->event("session-auth-test-result", result);
    if (pipe > 0 && user > 0) api->release_user(pipe, user);
    if (pipe > 0 && !api->release_pipe(pipe) && !result) result = SH_RELEASE_FAILED;
    return result;
}
#else
int sh_session(HMODULE module, void *engine, const struct sh_api *api,
               const struct sh_observer *o, const struct dock_client_layout *layout)
{
    (void)module; (void)engine; (void)api; (void)layout;
    o->event("session-requires-64-bit-host", 1);
    return 30;
}
#endif
