/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1830: bounded, single-use native credential handoff. */
#include "auth.h"
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

void dock_auth_clear(void *bytes, size_t size)
{
    volatile unsigned char *p = bytes;
    while (size--) *p++ = 0;
}

static uint64_t little(const unsigned char *p, unsigned count)
{
    uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i) value |= (uint64_t)p[i] << (8 * i);
    return value;
}

bool dock_auth_parse(const unsigned char *bytes, size_t size, struct dock_auth *out)
{
    if (!out) return false;
    dock_auth_clear(out, sizeof(*out));
    if (!bytes || size < 24 || size > DOCK_AUTH_MAX || memcmp(bytes, "MDOCK001", 8)) return false;
    uint64_t id = little(bytes + 8, 8);
    uint32_t app = (uint32_t)little(bytes + 16, 4);
    size_t name_size = (size_t)little(bytes + 20, 2), token_size = (size_t)little(bytes + 22, 2);
    if ((id >> 56) != 1 || ((id >> 52) & 15) != 1 ||
        ((id >> 32) & 0xfffff) != 1 || !(uint32_t)id || !app || app == UINT32_MAX ||
        !name_size || name_size > 64 || !token_size || token_size > 8192 ||
        size != 24 + name_size + token_size) return false;
    for (size_t i = 24; i < 24 + name_size; ++i)
        if (bytes[i] < 33 || bytes[i] > 126) return false;
    for (size_t i = 24 + name_size; i < size; ++i) {
        unsigned char c = bytes[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')) return false;
    }
    out->steam_id = id;
    out->app_id = app;
    memcpy(out->account, bytes + 24, name_size);
    memcpy(out->token, bytes + 24 + name_size, token_size);
    return true;
}

#ifdef _WIN32
bool dock_auth_consume_diagnostic(const wchar_t *path, struct dock_auth *out,
                                  struct dock_auth_failure *failure)
{
    unsigned char bytes[DOCK_AUTH_MAX];
    DWORD read = 0;
    LARGE_INTEGER size;
    bool ok = false;
    *failure = (struct dock_auth_failure){0};
    dock_auth_clear(out, sizeof(*out));
    /* Exclusive open and delete-on-close: the file is gone before login.
     * Reparse points are not followed. iOS also deletes any unconsumed file
     * after launch failure, session exit, sign-out, and the next app start. */
    HANDLE file = CreateFileW(path, GENERIC_READ | DELETE, 0, NULL, OPEN_EXISTING,
                             FILE_FLAG_DELETE_ON_CLOSE | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        *failure = (struct dock_auth_failure){DOCK_AUTH_OPEN, GetLastError()};
        return false;
    }
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(file, &info))
        *failure = (struct dock_auth_failure){DOCK_AUTH_INFO, GetLastError()};
    else if (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
        failure->stage = DOCK_AUTH_TYPE;
    else if (!GetFileSizeEx(file, &size))
        *failure = (struct dock_auth_failure){DOCK_AUTH_SIZE, GetLastError()};
    else if (size.QuadPart < 24 || size.QuadPart > DOCK_AUTH_MAX)
        failure->stage = DOCK_AUTH_BOUNDS;
    else if (!ReadFile(file, bytes, (DWORD)size.QuadPart, &read, NULL))
        *failure = (struct dock_auth_failure){DOCK_AUTH_READ, GetLastError()};
    else if (read != size.QuadPart)
        failure->stage = DOCK_AUTH_READ;
    else if (!(ok = dock_auth_parse(bytes, read, out)))
        failure->stage = DOCK_AUTH_PARSE;
    if (!CloseHandle(file)) {
        if (!failure->stage) *failure = (struct dock_auth_failure){DOCK_AUTH_CLOSE, GetLastError()};
        ok = false;
    }
    dock_auth_clear(bytes, sizeof(bytes));
    if (!ok) dock_auth_clear(out, sizeof(*out));
    return ok;
}
bool dock_auth_consume(const wchar_t *path, struct dock_auth *out)
{
    struct dock_auth_failure failure;
    return dock_auth_consume_diagnostic(path, out, &failure);
}
#endif
