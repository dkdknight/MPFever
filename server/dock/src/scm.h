/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#ifndef MADEIRA_STEAM_HOST_SCM_H
#define MADEIRA_STEAM_HOST_SCM_H
#include <windows.h>
#include <stdbool.h>
#include "probe.h"
/* ml2000: make Wine's service manager reachable for Valve's client and check
 * (read-only) that Valve's own client service is registered. If it is not,
 * run Valve's own bin\SteamService.exe /install from the folder of the loaded
 * genuine client (as Valve's client does), then check again. Returns 0 or the
 * ceg-result failure code (-4 unreachable, -5 not registered). Dock itself
 * never writes service registration or starts a service.
 */
int32_t sh_ceg_scm_prepare(const struct sh_observer *o, HMODULE client);
/* Host exit: only if this host started the service manager, stop Valve's
 * client service (bounded) and end that service manager. Otherwise no-op.
 */
void sh_ceg_scm_release(const struct sh_observer *o);
/* ml2014: `dockhost.exe --start-services` (Madeira's one-time-install batch):
 * make Wine's service manager reachable, starting services.exe only when none
 * answers, and leave it running for the session. Returns enum sh_install_scm
 * (validation.h). MADEIRA_DOCK_INSTALL_SCM=0: no-op (off).
 */
int32_t sh_install_scm_start(const struct sh_observer *o);
/* ml2020: the game session's own service manager (launch.c). How many
 * services another program installed in this prefix with automatic start
 * outside the Windows folder (validation.h, sh_service_is_foreign_autostart):
 * read-only registry enumeration, bounded; -1 when the key cannot be read.
 */
int32_t sh_game_scm_foreign_services(void);
/* The --start-services start (sh_install_scm_start), on a worker thread
 * waited for at most SH_GAME_SCM_STEP_MS: a manager that never answers must
 * not keep the game from starting. On a timeout *timed_out is set and the
 * worker is left to its blocked call (it reports nothing). Returns enum
 * sh_install_scm (validation.h), SH_INSTALL_SCM_FAILED on a timeout.
 */
#define SH_GAME_SCM_STEP_MS 20000
int32_t sh_game_scm_start(const struct sh_observer *o, bool *timed_out);
#endif
