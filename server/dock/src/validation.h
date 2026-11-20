/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#ifndef MADEIRA_STEAM_HOST_VALIDATION_H
#define MADEIRA_STEAM_HOST_VALIDATION_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>
/* Extra LaunchApp arguments are one bounded UTF-8 string, never a shell command.
 * The Swift library profile enforces the same byte/quote/token/control bounds. */
#define SH_LAUNCH_ARGUMENTS_CAPACITY 4096u
#define SH_LAUNCH_ARGUMENTS_MAX_TOKENS 64u
bool sh_launch_arguments_valid(const char *arguments, size_t length);
bool sh_subscription_list_contains(const uint32_t *apps, int32_t count,
                                   size_t capacity, uint32_t requested);
bool sh_decode_launch_result(const void *payload, size_t size, uint64_t expected_game,
                             int32_t *error);
/* ml1970: Valve's launch refusals that mean "content is still being prepared". */
bool sh_launch_error_waits_for_content(int32_t error);
uint32_t sh_launch_retry_delay_ms(unsigned attempt);
bool sh_launch_error_waits_for_config(int32_t error);
bool sh_launch_error_waits_for_session(int32_t error);
/* Decimal config.launch key, bounded to the numeric report range. */
bool sh_parse_launch_option(const char *text, uint32_t *option);
/* Recognize only the client's bounded missing-entry diagnostic; never log it. */
bool sh_launch_option_missing(const void *payload, size_t size, uint32_t option);

/* ml1990: Valve custom-executable (CEG) preparation. Callback 1020025 is
 * posted once per per-file job: int32 EResult, uint32 AppID (8 bytes).
 * Callback 1020024 reports each server reply: EResult, AppID, bool (12).
 */
#define SH_CEG_JOB_FINISHED 1020025
#define SH_CEG_SERVER_REPLY 1020024
#define SH_CEG_MAX_JOBS 4096u
enum sh_ceg_step { SH_CEG_WAIT, SH_CEG_RETRY, SH_CEG_DONE, SH_CEG_FAIL };
struct sh_ceg_progress { uint32_t expected, finished; int32_t failure; };
bool sh_decode_ceg_job(const void *payload, size_t size, uint32_t appid, int32_t *result);
bool sh_decode_ceg_reply(const void *payload, size_t size, uint32_t appid, int32_t *result);
enum sh_ceg_step sh_ceg_request_step(int32_t result, uint32_t jobs, struct sh_ceg_progress *progress);
enum sh_ceg_step sh_ceg_record_job(struct sh_ceg_progress *progress, int32_t result);

/* ml2000: Wine's service manager, which Valve's client needs to reach its own
 * client service for CEG work. ceg-result -4: the service manager could not
 * be reached; -5: Valve's client service is not registered in this prefix.
 */
#define SH_CEG_SCM_UNAVAILABLE (-4)
#define SH_CEG_SERVICE_UNREGISTERED (-5)
enum sh_service_stop { SH_SERVICE_STOP_FAILED = -1, SH_SERVICE_NOT_RUNNING = 0,
                       SH_SERVICE_STOPPED = 1, SH_SERVICE_ENDED_AFTER_BOUND = 2 };
/* True only for "no service manager is listening" (so one may be started). */
bool sh_scm_error_means_absent(uint32_t error);
/* True while a just-started service manager may still be coming up. */
bool sh_scm_error_retryable(uint32_t error);
/* 0 ready, otherwise the ceg-result failure code above. */
int32_t sh_ceg_scm_result(bool manager_reachable, bool service_registered);
/* Milliseconds left of a bound (0 when elapsed; clock regressions count as 0 elapsed). */
uint32_t sh_remaining_ms(uint64_t now, uint64_t begin, uint64_t bound);
/* How long a manager start waits before asking the manager again: the time left, at most
 * SH_SCM_POLL_MS. */
#define SH_SCM_POLL_MS 250u
uint32_t sh_scm_poll_slice_ms(uint32_t left);
enum sh_service_stop sh_service_stop_outcome(bool was_running, bool stopped_by_manager,
                                             bool process_gone, bool ended_by_host);
/* Run Valve's service installer only for a definitely missing service. */
bool sh_should_install_service(bool registered, bool missing, bool install_enabled);
/* ceg-service-install value: installer exit code, -1 timeout, -2 file missing
 * (-3, set by the caller, means the installer process could not be started).
 */
#define SH_SERVICE_INSTALL_TIMEOUT (-1)
#define SH_SERVICE_INSTALL_MISSING (-2)
int32_t sh_service_install_report(bool file_present, bool finished, uint32_t exit_code);

/* ml2014: `dockhost.exe --start-services`, run by Madeira's one-time-install
 * batch before the game's installers. Outcome of making Wine's service
 * manager reachable: off (MADEIRA_DOCK_INSTALL_SCM=0), already running
 * (reachable at once, or started by another launcher), started by this call,
 * or failed. The printed word is the one Madeira's batch result expects.
 */
enum sh_install_scm { SH_INSTALL_SCM_FAILED = -1, SH_INSTALL_SCM_OFF = 0,
                      SH_INSTALL_SCM_ALREADY = 1, SH_INSTALL_SCM_STARTED = 2 };
/* Spawn services.exe only when enabled and the first open said "absent". */
bool sh_install_scm_should_spawn(bool enabled, uint32_t first_error);
/* first_error 0: reachable at once; spawned: this call created services.exe. */
enum sh_install_scm sh_install_scm_outcome(bool enabled, uint32_t first_error,
                                           bool spawned, bool reachable);
/* "started", "already", "off"; "failed" for any other value. */
const char *sh_install_scm_word(int32_t outcome);

/* ml2020: a game session's own service manager and the hold while a game's
 * launcher restarts (launch.c, hold.c). Pure decisions; the Windows calls
 * stay in the host files so the native sanitizer tests cover these.
 *
 * MADEIRA_DOCK_GAME_SCM: "0" never starts a service manager for the game
 * session, "1" always does; unset (or any other value) starts one only when
 * a program installed an automatic-start Windows service of its own in this
 * prefix, which only a running service manager can start.
 */
enum sh_game_scm_mode { SH_GAME_SCM_OFF = 0, SH_GAME_SCM_ON = 1, SH_GAME_SCM_AUTO = 2 };
enum sh_game_scm_mode sh_game_scm_mode(const wchar_t *value);
/* A service entry under System\CurrentControlSet\Services that Windows
 * a program may start and that is not part of Windows: a Win32 service
 * (type 0x10 or 0x20) with start type 2 (automatic) or 3 (on demand, which
 * the program that registered it starts itself) whose image is neither
 * under the Windows folder nor given relative to it (%SystemRoot%,
 * \SystemRoot, System32\, SysWOW64\). Wine's own services all fail this
 * test; a launcher's own service passes it.
 */
bool sh_service_is_foreign_autostart(uint32_t type, uint32_t start, const wchar_t *image,
                                     const wchar_t *windows_dir);
bool sh_game_scm_wanted(enum sh_game_scm_mode mode, unsigned foreign_autostart);

/* MADEIRA_DOCK_KEEP_ALIVE: "0" ends the session as before, 3 s after Valve's
 * client stops reporting the game as running. Unset, empty or a `;`-separated
 * list of image file names: the end is postponed while a process of the
 * game's own tree (descended from this host, Windows images and their
 * children excepted) or with a listed image name still shows a window or is
 * younger than SH_KEEP_ALIVE_YOUNG_MS. A launcher that restarts itself is
 * young; the game it then starts shows a window; a launcher left behind in
 * the background after the game ends is neither, so the session ends.
 */
#define SH_KEEP_ALIVE_YOUNG_MS 60000ULL
enum sh_keep_alive_mode { SH_KEEP_ALIVE_OFF = 0, SH_KEEP_ALIVE_AUTO = 1 };
enum sh_keep_alive_mode sh_keep_alive_mode(const wchar_t *value);
/* `name` (an image file name) is one of the `;`-separated entries, no case. */
bool sh_keep_alive_listed(const wchar_t *list, const wchar_t *name);
/* `path` lies inside `folder` (no case; a separator must follow the folder). */
bool sh_path_in_folder(const wchar_t *path, const wchar_t *folder);
/* `image` is Windows' own: inside windows_dir, or given relative to it. */
bool sh_image_is_windows(const wchar_t *image, const wchar_t *windows_dir);
/* One tracked process holds the session while it is not a Windows image and
 * either shows a window or is younger than young_ms. */
bool sh_keep_alive_holds(bool windows_image, bool visible_window, uint64_t age_ms, uint64_t young_ms);
#endif
