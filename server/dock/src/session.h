/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#ifndef MADEIRA_STEAM_HOST_SESSION_H
#define MADEIRA_STEAM_HOST_SESSION_H
#include <windows.h>
#include "probe.h"
#include "client_layout.h"
int sh_session(HMODULE module, void *engine, const struct sh_api *api,
               const struct sh_observer *observer, const struct dock_client_layout *layout);
#endif
