# MPFever dedicated server in Docker (`mpfever-server`, experimental)

A dedicated server in a Linux container: the **real Transport Fever 3 simulation** (the Windows game, under Wine) in one Docker container. No GPU, no screen, no
Steam desktop. Players join it with the usual MPFever client, from Windows, exactly as they join the Windows dedicated server.

> **Status: experimental.** Validated end to end on the built image for short sessions on a small world with a real Windows client (see
> [What is validated](#what-is-validated)). Long runs, several clients and large worlds are not validated yet. It needs **your own** Transport Fever 3
> licence: the image contains no game file and no Valve file.

## Where it runs

"Linux" is the system inside the container. The host is any machine that runs Linux containers for x86-64:

| Host | |
|---|---|
| Linux x86-64 (server, VPS) | yes, the target |
| Windows with Docker Desktop (WSL2) | yes (give WSL2 at least 12 GB of RAM for the container: a Docker Desktop setting) |
| macOS Intel | probably, not tried |
| macOS Apple Silicon, other ARM hosts | no: the image is x86-64 and emulated Wine is far too slow |

## Dedicated server on Windows, in Docker, or relay

| | Dedicated server (Windows) | Dedicated server (Docker, this page) | Relay ([RELAY.md](RELAY.md)) |
|---|---|---|---|
| Download | `MPFever-<version>-server.zip` | Docker image `mpfever-server` | `Relay-MPFever-<version>-...` or its Docker image |
| Runs the game and the world | yes | yes (Windows game under Wine) | no: the hosting player's PC does |
| Needs | Windows, the game installed | an x86-64 host with Docker, about 12 GB of RAM, your game files once | nothing but the program |
| Steam | the desktop client | Valve's client library only (about 280 MB) | none |

## Quick start

You need an x86-64 host with Docker (Compose v2; a Linux server or VPS, or Windows with Docker Desktop), 12 GB of RAM or more for the container, about 1 core, a file system with sparse-file support
(ext4, xfs, btrfs), about 6 GB of disk, a Steam account that owns Transport Fever 3 with the Steam mobile app (to approve the sign-in once), a copy of the game
on a PC where it is installed, and a savegame (`.sav`) of the world to host. Use an account that is not played on at the same time as the server.

```
mkdir mpfever-server && cd mpfever-server
curl -fsSLO https://raw.githubusercontent.com/ampynjord/MPFever/feature/dedicated-server/server/compose.yaml
curl -fsSL  https://raw.githubusercontent.com/ampynjord/MPFever/feature/dedicated-server/server/.env.example -o .env
```

Edit `.env` (at least `WORLD`, the savegame's name without `.sav`). Then, once:

1. **Pull the image**: `docker compose pull`
2. **Import the game** from your own Steam library (read-only mount; the 3D data is left out, 66 GB become about 1 GB on disk):
   `docker compose run --rm -v "/path/to/Steam/steamapps:/src:ro" mpfever-server install-game /src`
   (`/path/to/Steam/steamapps` holds `common/Transport Fever 3` and `appmanifest_3493540.acf`.)
3. **Sign in to Steam**: `docker compose run --rm mpfever-server login`. A QR code appears in the terminal; approve it in the Steam mobile app. No password is typed or stored.
4. **Import your savegame** (the `.sav` and the files next to it): `docker compose run --rm -v "/path/to/saves:/in:ro" mpfever-server import-save /in/myworld.sav`
5. **Start**: `docker compose up -d`. It restarts by itself after a reboot or a crash. `docker compose logs -f` shows the server's log.

Players connect to `<host>:28090` (forward the TCP port on your router for the Internet). `docker compose stop` saves the world first. The very first start takes a few
minutes longer (Wine prefix, Valve client download) and the game restarts once by itself.

Commands for the administrator (the service is `mpfever-server`):

| | |
|---|---|
| `docker compose ps` / `logs -f` | state, health, log |
| `docker compose run --rm mpfever-server status` | what is missing (game, Steam session, savegame, sparse files, disk) |
| `docker compose exec mpfever-server /opt/mpfever/scripts/measure.sh` | memory (container, processes), CPU over 30 s, synchronisation |
| `docker compose run --rm mpfever-server login` | sign in again when the Steam session expires (about 7 months) |
| `docker compose run --rm -v "...:/in:ro" mpfever-server import-save /in/<world>.sav` | add or replace a savegame |

## Settings

Everything is in `.env` and takes effect with `docker compose up -d`, no rebuild. Only `WORLD` is required.

| Variable | Default | |
|---|---|---|
| `WORLD` | | the savegame to host (name without `.sav`) |
| `SERVER_NAME`, `MOTD` | `MPFever Server`, empty | name and welcome message |
| `PORT` | `28090` | TCP port |
| `PASSWORD`, `MAX_PLAYERS` | empty, `8` | |
| `COMPANY_MODE` | `shared` | `shared` or `separate` (one company per player) |
| `START_SPEED`, `PAUSE_WHEN_EMPTY`, `PLAYER_SPEED_CONTROL` | `1`, `false`, `true` | |
| `AUTOSAVE_MINUTES`, `BACKUPS` | `10`, `10` | autosave and copies kept in `srv/backups` |
| `PUBLIC`, `PUBLIC_ADDRESS` | `false`, empty | list the server in MPFever's public list |
| `MEM_LIMIT`, `CPUS` | `14g`, `2` | container limits (measured need: about 11 GB and 0.7 core for a small world) |
| `MPFEVER_IMAGE` | the published image | another image or a version tag (rollback) |

They are written to the server's `mpfever_server.properties` at every start (the game's other server options of SERVER.txt are the launcher's own).
Data live in two named volumes: `mpfever-data` (Wine prefix, Valve client, Steam session, saves, launcher logs and backups) and `mpfever-game` (the lite game install,
rebuilt at any time with `install-game`). Back up `mpfever-data`.

## How it works

| Part | What | Why |
|---|---|---|
| Game | `TransportFever3.exe` under Wine 11 (pinned package) on Ubuntu 24.04 | A native Linux game drifts from Windows clients (different C++ library, `std::` distributions inlined in the game): the same executable keeps the same simulation. No Proton, no DXVK: rendering is a no-op. |
| Launcher | `MPFever.exe --server --server-start headless` under Mono, with a Linux/Wine mode (`GameInstall.WineMode`, `MPFEVER_WINE=1`; `MPFEVER_STOPFILE` for a clean stop) | The same host logic, `winhttp.dll` module and mod as the players'. |
| Steam | Madeira Dock (`dockhost.exe`, built in the image from our copy in `server/dock/`, which we maintain; origin [willfaust/madeira-dock](https://github.com/willfaust/madeira-dock)) driving **Valve's own `steamclient64.dll`** | The game requires a running Valve client. Dock signs in with the owner's refresh token, asks Valve's client for the licence and has it start the game: no `steam.exe`, no web helper (about 280 MB instead of 2.7 GB). No Steamworks emulation, no DRM bypass: every decision is Valve's. |
| Rendering | Lavapipe (software Vulkan) and the layer `server/vklayer/` (`MPF_VKNULL=1`, `MPF_VKNULL_MODE=all`, `MPF_VKNULL_TRIM=1`), `MPFEVER_HEADLESS_NORENDER=1;MPFEVER_HEADLESS_FPS=10` | Draws, copies and render passes become no-ops; mapped GPU memory nobody reads is given back. A real GPU is used if the layer is off (`compose.gpu.yaml`, not validated). |
| Disk | the "lite" install (`server/scripts/mklite.py`) | The engine reads archives at fixed offsets, so archives keep their layout: textures, audio and blobs become file holes (sparse), images stay valid but empty. Generated from the host's own copy, never distributed. |
| Display | `Xvfb` only | The game closes without an X server. Nothing is exposed: no VNC, no remote desktop. |

The image is **versioned by the MPFever release** it carries (`0.9.1`, `0.9.1-2` for a rebuild) plus `experimental`: it is built from the latest official release's sources with the launcher
changes of the Linux server applied, so the players' official client can join. The image holds no secret, no Transport Fever 3 file and no Valve file; the Valve client library is
fetched from Valve at the first start (pinned build, hash-checked). Start (`server/scripts/entrypoint.sh run`): checks (disk, sparse support, RAM, game, session, savegame), first-start
Wine prefix, the launcher restarted when it exits (five failures within a minute stop the container with a message), `SIGTERM` writes the stop file: the world is saved, the game closed, then the container exits.

## Steam sign-in

`login` uses Steam's own authentication service (the QR flow of the Steam mobile app) and keeps a **refresh token** in `secrets/steam.json` of the data volume (mode 0600). At every game
start the token is handed to Dock as its one-use transfer file; it never appears on a command line, in the environment or in the image. When it expires the server stops with
a message (`login` again). Revoke it from your Steam account (Settings, Security) if it leaks.

## Madeira Dock and Valve's client: compatibility and risks

Dock calls internal interfaces of Valve's client library by position in its method tables, so it only drives builds it has verified (by the SHA-256 of `steamclient64.dll`) and refuses any
other (result 30, before any sign-in). The image pins the January 2026 build:

| | |
|---|---|
| `steamclient64.dll` | 25 546 904 bytes, SHA-256 `71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640` |
| Package fetched from Valve | `https://client-update.akamai.steamstatic.com/bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da`, SHA-256 `8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62` (checked before use) |
| Madeira Dock | `server/dock/`, imported unmodified from github.com/willfaust/madeira-dock commit `67780ba92e60dbfac4fe80eaf2ce34b9ea1a1c60` (GPL-3.0-or-later), maintained here; unit-tested and built in the image build |

Dock never starts `steam.exe`, so the pinned client is never updated by Steam. Valve could remove that archive or change its authentication protocol: the server then stops with an explicit message
(hash mismatch, download failure, or Dock's refusal in `srv/dock.log`). There is no second Steam implementation: the remedy is to add the new client build to our copy of Dock's layout table and to change the pin
(`server/dock/MAINTAINING.md` lists the steps; the pin is in `server/scripts/lib.sh`). Dock is not endorsed by Valve; overlay, cloud saves and achievements are not supported (the server does not use them).
One Steam account plays one game at a time: playing on it elsewhere while the server runs can interrupt it (a few minutes of both was tolerated, no guarantee): use a dedicated account.

## Update, roll back, security

- Update: `docker compose pull && docker compose up -d`. Roll back: `MPFEVER_IMAGE=ghcr.io/ampynjord/mpfever-server:<version>` in `.env`. The launcher package is replaced at each start; `.env` and the volumes stay.
  Players must run the MPFever client of the server's version.
- The container runs as uid 1001 with a read-only root file system, all capabilities dropped, `no-new-privileges`, only the game port published. `.env` holds the server password: keep it out of version control.
- Exit codes: 20/21 Valve client download or hash, 30 game missing, 40/41 Steam session missing or expired, 42 savegame missing, 50 launcher failing repeatedly. Reports: `docker compose logs`, `srv/launcher.out`,
  `srv/logs/`, and Dock's `srv/dock.log` (stage names and numbers only; result codes in `server/dock/README.upstream.md`).

## Measured

Small world, no GPU, one real Windows client:

| | |
|---|---|
| Container | about 10.6 to 11.8 GB: anonymous 9.5 GB, reclaimable page cache 1 to 2 GB, shared 0.7 GB |
| Game process | 10.0 GB (PSS); about 9 GB of it is the game's own heap; the Vulkan layer's trim returns about 0.7 GB |
| Dock | 256 MB (193 MB PSS), about 0 CPU; the rest: launcher 107 MB, Wine desktop 87 MB, Xvfb 23 MB |
| CPU | about 0.6 core at x0.98 game speed |
| Disk | 1.3 GB game (66 GB apparent), about 3 GB prefix and Valve client; image 3.5 GB |
| Sync with a real Windows client | join, resynchronisation 140 s, `IDENTICAL on 2 games`, 0 desynchronisations over about 6 minutes |

## What is validated

Run end to end on the built image with volumes created empty, a real account and a real Windows client: `install-game`, the QR `login`, the token hand-over to Dock (Steamworks without a Steam
desktop), first start, `import-save`, world load, a client joining and staying identical, `docker compose stop` (about 10 s, world saved), restart restoring the saved world, the healthcheck, the
read-only container.
**Not validated yet:** runs of 30 minutes or more, memory growth over time, several clients (a second Steam account is needed, or local test clients), large worlds, enforced CPU/memory limits,
stopping while a client has vanished, the GPU variant.

## Build and tests

`.github/workflows/dedicated-server.yml` runs the static checks (`server/tests/check.sh`: shell, Python tests, Compose, no secrets or binaries), runs Dock's unit tests, builds the package from the latest official release with the
Docker server's launcher changes, builds the image, smoke-tests it (unprivileged, no game or Valve file inside, explicit errors on empty volumes) and publishes only when a tag
`dedicated-server-v<version>` is pushed or the workflow is run by hand with "publish" ticked. Locally: put a package built by `build.bat` in `server/dist/MPFever-server.zip` and
`docker compose -f compose.yaml -f compose.build.yaml build` (`APT_MIRROR` can name another Ubuntu mirror).
