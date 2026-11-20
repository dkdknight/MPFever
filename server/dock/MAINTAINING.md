# Madeira Dock in MPFever: our copy and how we maintain it

`dockhost.exe` is a small Windows program (about 2,000 lines of C) that loads **Valve's own, unmodified `steamclient64.dll`**, signs in with the account owner's refresh
token, asks Valve's client whether the account owns the game and has Valve's client start it. It is what lets the dedicated server run without Steam's desktop client.
It contains no Steamworks implementation, no ticket or licence logic of its own, and no DRM bypass: every decision (valid sign-in, ownership, permission to start) is Valve's;
Dock has no path that starts the game when Valve says no (see `README.upstream.md`, "What it does not do").

## Origin and licence

Imported unmodified from [willfaust/madeira-dock](https://github.com/willfaust/madeira-dock), commit `67780ba92e60dbfac4fe80eaf2ce34b9ea1a1c60` (2026-10-28),
Copyright 2026 125hz, GPL-3.0-or-later with the Madeira Converter Exception (`LICENSE`, `COPYING`, `LICENSE-EXCEPTION.md`). MPFever is GPL-3.0, so the code can live here;
the licence files, `THIRD-PARTY-NOTICES.md` and `notices/` stay with it, and the image carries them in `/opt/mpfever/licenses/madeira-dock/`.
Not included: the author's Madeira app, its Swift/iOS parts, his agent notes and development history (`docs/HISTORY.md`, `docs/HANDOFF.md`). This copy is maintained here from now on;
changes made after the import are listed at the end of this file (none yet).

## What is here

| | |
|---|---|
| `src/` | the program (`main.c`, `session.c` sign-in and licence, `launch.c`, `auth.c` the transfer file, `client_layout.c` the supported client builds, `scm.c`, `hold.c`, ...) |
| `tests/`, `check.sh` | unit tests of the pure logic (synthetic data, no Steam): `bash server/dock/check.sh` |
| `build.sh` | the build the image uses (MinGW-w64, static, `-Wall -Wextra -Werror`): `bash server/dock/build.sh` |
| `tools/check-client-layout.py` | checks a `steamclient64.dll` against the layout table without running it |
| `docs/CLIENT_LAYOUTS.md`, `docs/OFFLINE.md` | where each supported client build came from and how its methods were identified; offline logon |
| `README.upstream.md` | the author's README (variables, result codes, credentials) |

The server drives Dock through environment variables set by `server/scripts/entrypoint.sh` and by the launcher (`MPFEVER_DOCK`, see `launcher/Core.cs`).

## The one thing to maintain: the supported Valve client builds

Dock calls **private interfaces** of Valve's client by position in its method tables, so `src/client_layout.c` lists the exact `steamclient64.dll` builds it may drive (by SHA-256) with the address of every
method it calls; any other build is refused (result 30) before any sign-in. The image pins one build (`CLIENT_*` in `server/scripts/lib.sh`: January 2026, SHA-256 `71b391fe...`). When
Valve ships a client that breaks it, or removes the pinned archive:

1. Get the new client package from Valve's update server (`https://client-update.akamai.steamstatic.com/steam_client_win32` names the current package; the archive is `bins_win32.zip.<hash>` on the same host)
   and extract `steamclient64.dll`. Check Valve's signature (Windows Authenticode: signer Valve Corp).
2. `python tools/check-client-layout.py <steamclient64.dll>` identifies the vtables (RTTI) and the 14 called methods; compare with the table (`docs/CLIENT_LAYOUTS.md` explains the method).
3. Add the build to `src/client_layout.c` (its SHA-256, PE timestamp and method addresses) and a case to `tests/test-client_layout.c` (the known build is accepted, a changed byte is rejected).
4. `bash server/dock/check.sh`, then a real test: `docker compose run ... login`, a start, `launch-game-running=1` in `srv/dock.log`, a client joining.
5. Update the pin (`CLIENT_URL`, `CLIENT_ZIP_SHA256`, `CLIENT_DLL_SHA256` in `server/scripts/lib.sh`) and the table in `docs/DOCKER-SERVER.md`, add the entry below, publish a new image.

Never loosen Dock's checks (the launch callback must stay strictly checked: id, size, game id, success). Never add a path that starts the game without Valve's answer.

## Changes since the import

None.
