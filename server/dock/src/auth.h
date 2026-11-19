/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#ifndef MADEIRA_DOCK_AUTH_H
#define MADEIRA_DOCK_AUTH_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define DOCK_AUTH_MAX (24 + 64 + 8192)
struct dock_auth {
    uint64_t steam_id;
    uint32_t app_id;
    char account[65];
    char token[8193];
};
/* This envelope transports a credential, never an entitlement assertion.
 * Authentication and ownership still require Valve's online response. */
bool dock_auth_parse(const unsigned char *bytes, size_t size, struct dock_auth *out);
void dock_auth_clear(void *bytes, size_t size);
#ifdef _WIN32
/* Numeric operation/error only; never a path or credential payload. */
struct dock_auth_failure { int32_t stage; uint32_t error; };
enum { DOCK_AUTH_OPEN = 1, DOCK_AUTH_INFO, DOCK_AUTH_TYPE, DOCK_AUTH_SIZE,
       DOCK_AUTH_BOUNDS, DOCK_AUTH_READ, DOCK_AUTH_PARSE, DOCK_AUTH_CLOSE, DOCK_AUTH_PATH };
bool dock_auth_consume(const wchar_t *path, struct dock_auth *out);
bool dock_auth_consume_diagnostic(const wchar_t *path, struct dock_auth *out,
                                  struct dock_auth_failure *failure);
#endif
#endif
