/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#include "auth.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

static void put(unsigned char *p, uint64_t value, unsigned n)
{ for (unsigned i = 0; i < n; ++i) p[i] = (unsigned char)(value >> (8 * i)); }

int main(void)
{
    unsigned char bytes[DOCK_AUTH_MAX + 1] = "MDOCK001";
    struct dock_auth auth;
    put(bytes + 8, UINT64_C(76561197960265729), 8);
    put(bytes + 16, 123, 4); put(bytes + 20, 4, 2); put(bytes + 22, 5, 2);
    memcpy(bytes + 24, "usera.b-c", 9);
    assert(dock_auth_parse(bytes, 33, &auth));
    assert(auth.app_id == 123 && auth.steam_id == UINT64_C(76561197960265729));
    assert(!strcmp(auth.account, "user") && !strcmp(auth.token, "a.b-c"));
#ifdef _WIN32
    wchar_t folder[MAX_PATH], path[MAX_PATH];
    assert(GetTempPathW(MAX_PATH, folder) && GetTempFileNameW(folder, L"mdt", 0, path));
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, TRUNCATE_EXISTING, 0, NULL);
    assert(file != INVALID_HANDLE_VALUE);
    DWORD written;
    struct dock_auth_failure failure;
    assert(WriteFile(file, bytes, 33, &written, NULL) && written == 33);
    assert(!dock_auth_consume_diagnostic(path, &auth, &failure));
    assert(failure.stage == DOCK_AUTH_OPEN && failure.error == ERROR_SHARING_VIOLATION);
    assert(CloseHandle(file));
    assert(dock_auth_consume_diagnostic(path, &auth, &failure));
    assert(!failure.stage && !failure.error);
    assert(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES);
    assert(!dock_auth_consume_diagnostic(path, &auth, &failure));
    assert(failure.stage == DOCK_AUTH_OPEN && failure.error == ERROR_FILE_NOT_FOUND);
    assert(GetTempFileNameW(folder, L"mdt", 0, path));
    assert(!dock_auth_consume_diagnostic(path, &auth, &failure));
    assert(failure.stage == DOCK_AUTH_BOUNDS && !failure.error);
    assert(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES);
    assert(GetTempFileNameW(folder, L"mdt", 0, path));
    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, TRUNCATE_EXISTING, 0, NULL);
    assert(file != INVALID_HANDLE_VALUE);
    bytes[0] = 'X';
    assert(WriteFile(file, bytes, 33, &written, NULL) && written == 33);
    assert(CloseHandle(file));
    assert(!dock_auth_consume_diagnostic(path, &auth, &failure));
    assert(failure.stage == DOCK_AUTH_PARSE && !failure.error);
    assert(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES);
    bytes[0] = 'M';
#endif
    for (size_t size = 0; size < 33; ++size) assert(!dock_auth_parse(bytes, size, &auth));
    assert(!dock_auth_parse(bytes, 34, &auth));
    assert(!dock_auth_parse(bytes, sizeof(bytes), &auth));
    assert(!dock_auth_parse(NULL, 33, &auth));
    assert(!dock_auth_parse(bytes, 33, NULL));
    for (unsigned i = 0; i < 8; ++i) {
        bytes[i] ^= 0x80; assert(!dock_auth_parse(bytes, 33, &auth)); bytes[i] ^= 0x80;
    }
    for (unsigned i = 24; i < 33; ++i) {
        unsigned char saved = bytes[i]; bytes[i] = 0;
        assert(!dock_auth_parse(bytes, 33, &auth)); bytes[i] = saved;
    }
    put(bytes + 16, 0, 4); assert(!dock_auth_parse(bytes, 33, &auth));
    put(bytes + 16, UINT32_MAX, 4); assert(!dock_auth_parse(bytes, 33, &auth));
    put(bytes + 16, 123, 4);
    put(bytes + 8, UINT64_C(76561197960265728), 8); assert(!dock_auth_parse(bytes, 33, &auth));
    put(bytes + 8, UINT64_C(76561197960265729), 8);
    put(bytes + 20, 65, 2); assert(!dock_auth_parse(bytes, 94, &auth));
    put(bytes + 20, 64, 2); put(bytes + 22, 8192, 2);
    memset(bytes + 24, 'a', 64 + 8192);
    assert(dock_auth_parse(bytes, DOCK_AUTH_MAX, &auth));
    put(bytes + 22, 8193, 2); assert(!dock_auth_parse(bytes, sizeof(bytes), &auth));
    const unsigned char *cleared = (const unsigned char *)&auth;
    for (size_t i = 0; i < sizeof(auth); ++i) assert(cleared[i] == 0);
    /* Arbitrary malformed envelopes must stay bounded under ASan/UBSan. */
    uint32_t seed = 1234;
    for (unsigned n = 0; n < 2000; ++n) {
        seed = seed * 1664525u + 1013904223u;
        size_t size = seed % sizeof(bytes);
        for (size_t i = 0; i < size; ++i) { seed = seed * 1664525u + 1013904223u; bytes[i] = (unsigned char)(seed >> 24); }
        assert(!dock_auth_parse(bytes, size, &auth));
    }
    puts("dock: handoff bounds, truncation, account/app binding, clearing and 2000 malformed inputs passed");
    return 0;
}
