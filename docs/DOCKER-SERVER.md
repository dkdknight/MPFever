# MPFever dedicated server in Docker (`mpfever-server`, experimental)

A dedicated server in a Linux container: the **real Transport Fever 3 simulation** (the Windows game, under Wine) in one Docker container. No GPU, no screen, no
Steam desktop. Players join it with the usual MPFever client, from Windows, exactly as they join the Windows dedicated server.

> **Status: experimental.** Validated end to end on the built image for short sessions on a small world with a real Windows client (see
> [What is validated](#what-is-validated)). Long runs, several clients and large worlds are not validated yet. It needs **your own** Transport Fever 3
> licence: the image contains no game file and no Valve file.

## Where it runs

Docker is the only supported way: the image pins Wine, Mono and the rest, runs the server unprivileged and starts it with one command. Another OCI engine (Podman, Kubernetes) should work but is not tried;
running the pieces directly on a Linux host (the Dockerfile is the recipe) is neither scripted nor supported.

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

Edit `.env` (at least `SRV_WORLD`, the savegame's name without `.sav`). Then, once:

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
| `docker compose exec mpfever-server mpfever-admin <command>` | a console command of the server (`help`, `status`, `say`, `kick`, `save`, ...) |
| `docker compose exec mpfever-server /opt/mpfever/scripts/measure.sh` | memory (container, processes), CPU over 30 s, synchronisation |
| `docker compose run --rm mpfever-server login` | sign in again when the Steam session expires (about 7 months) |
| `docker compose run --rm -v "...:/in:ro" mpfever-server import-save /in/<world>.sav` | add or replace a savegame |

## Settings

Everything is in `.env` and takes effect with `docker compose up -d`, no rebuild. Only `SRV_WORLD` is required. The `SRV_` prefix keeps the names apart from the variables of the machine
the command runs on: a shell variable wins over `.env` (Windows defines `PUBLIC`, which once listed a server publicly by mistake).

| Variable | Default | |
|---|---|---|
| `SRV_WORLD` | | the savegame to host (name without `.sav`) |
| `SRV_SERVER_NAME`, `SRV_MOTD` | `MPFever Server`, empty | name and welcome message |
| `SRV_PORT` | `28090` | TCP port |
| `SRV_PASSWORD`, `SRV_MAX_PLAYERS` | empty, `8` | |
| `SRV_COMPANY_MODE` | `shared` | `shared` or `separate` (one company per player) |
| `SRV_START_SPEED`, `SRV_PAUSE_WHEN_EMPTY`, `SRV_PLAYER_SPEED_CONTROL` | `1`, `false`, `true` | |
| `SRV_AUTOSAVE_MINUTES`, `SRV_BACKUPS` | `10`, `10` | autosave and copies kept in `srv/backups` |
| `SRV_PUBLIC`, `SRV_PUBLIC_ADDRESS` | `false`, empty | list the server in MPFever's public list |
| `SRV_LOG_FORMAT` | `json` | `json` (one JSON object per line) or `text` |
| `SRV_UPDATE_CHECK` | `notify` | `notify` (new MPFever release announced in the log, never installed) or `off` |
| `SRV_GAME_LOG` | `warn` | the game's and Dock's logs in the stream: `off`, `error`, `warn`, `info` or `debug` |
| `SRV_ADMIN_UI`, `SRV_ADMIN_PORT` | `off`, `8080` | the administration page (see Administering); it listens only when `on`, and `compose.admin.yaml` publishes it on 127.0.0.1 |
| `SRV_MODS_SYNC` | `auto` | `auto` (the world's mod.io mods are installed or updated at every start, when `mods login` was done) or `off` |
| `SRV_MEM_LIMIT`, `SRV_CPUS` | `16g`, `2` | container limits: about 12 GB and 1 CPU for the small world (minimum), 16 GB and 2 CPUs for a world of 120 MB; the CPU also sets how fast it starts and resynchronises |
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

The image is **versioned by the MPFever version** it is built from (`ghcr.io/<owner>/mpfever-server:<version>`) plus `experimental`: it is built by the Release build workflow from the release's own server
archive (run it on the release's tag), so the players' client of that version can join; the version the server and the players run must be the same. The image holds no secret, no Transport Fever 3 file and no Valve file; the Valve client library is
fetched from Valve at the first start (pinned build, hash-checked). Start (`server/scripts/entrypoint.sh run`): checks (disk, sparse support, RAM, game, session, savegame), first-start
Wine prefix, the launcher restarted when it exits (five failures within a minute stop the container with a message), `SIGTERM` writes the stop file: the world is saved, the game closed, then the container exits.

## Administering the server

The launcher of the image is the server's brain (`MPFever.exe --server`, the same program as the Windows dedicated server): hosting, synchronisation, saves, the console. The container only wraps it (Wine, Steam through Dock, scripts).
The console commands of the server window work from outside with **`mpfever-admin`**:

```
docker compose exec mpfever-server mpfever-admin help        # the list of commands
docker compose exec mpfever-server mpfever-admin status      # players, speed, synchronisation, last save
docker compose exec mpfever-server mpfever-admin say "Restart in 5 minutes"
docker compose exec mpfever-server mpfever-admin kick <player>
docker compose exec mpfever-server mpfever-admin save
```

It hands the command to the launcher (a file in `/data/run/cmd`), waits for it to run and prints what the server logged for it. Everything the Windows server's console does is reachable this way (see the server's `SERVER.txt`).
The administration page uses the same channel (next section).

### The administration page (off by default)

`SRV_ADMIN_UI=on` starts a small page (status, save, pause/resume, speed, resync, restart, a message to every player, kick, the live log) that hands the same console commands to the launcher. Nothing listens
unless it is on. `compose.admin.yaml` publishes its port on **this machine's `127.0.0.1` only** (`docker compose -f compose.yaml -f compose.admin.yaml up -d`, port `SRV_ADMIN_PORT`, 8080 by default); from another machine, use an SSH
tunnel or a reverse proxy that adds TLS (the page is plain HTTP). Every call needs the token made at the first start in `secrets/admin-token` (mode 0600; `mpfever-admin token` prints it). Only the verbs
`status list say save pause resume speed kick resync restart` are accepted (never `stop`), one line each; every command and every refused call is in the log (component `admin-ui`). The page is one file of
the image (`scripts/webadmin.py`, standard library only, no external resource, strict content policy).

## Mods

A world that uses mods needs them on the server and on every player's PC, in the same version. The server installs the world's **mod.io** mods itself:

```
docker compose run --rm mpfever-server mods login        # once: the API path and key of mod.io.com/me/access (typed, never put in a file or the image)
docker compose run --rm mpfever-server mods list <world>   # the mods the world's savegame uses, and where they come from
docker compose run --rm mpfever-server mods sync <world>   # installs or updates them (the same at every server start, see below)
docker compose run --rm mpfever-server mods status         # what is installed
```

`login` checks the key against mod.io and keeps it in `secrets/modio.json` of the data volume (mode 0600). Each mod is downloaded (size and hash checked) into **two copies**: the game runs from a
**reduced copy** (`/data/modio`: every file keeps its path and size, the textures, models, sounds and other files a headless server never reads are left empty, as in the lite game install), and the
**full copy** stays in `/data/mods/full` for the players.

Mods that are **not** on mod.io (the ones in the game's `local/mods` folder of your PC) are imported from a folder you mount into the container:

```
docker compose run --rm -v "C:\Users\me\...\local\mods:/import:ro" mpfever-server mods import /import     # a mods folder, or one mod's folder
```

Each mod (a folder with `mod.lua`) gets the same two copies: reduced for the game (`local/mods` of the server's profile), full for the players; importing again updates it. `mods list <world>` shows for each mod of
a world whether this server has it. The game has no Steam Workshop for Transport Fever 3 (mods come from mod.io or are local), so nothing else needs importing.

- **At every start** (`SRV_MODS_SYNC=auto`, the default; `off` skips it): the world's mods are checked against mod.io and the newer versions installed, so mods follow the server's updates. A mod.io outage
  never stops the server: the installed copies are used.
- **A player who joins without a mod** is offered it by the server, at once, in the full version (the launcher's mod sending, as a host's PC does for local mods): the player's MPFever shows the offer and,
  once accepted, installs the mod in the player's own mods folder. A mod is code, so a player who does not accept it is never sent it. A player whose copy is another version is told to update it.
- The game's mod.io library only reports the mods its signed-in user is subscribed to. A server has no mod.io account, so `mods sync` writes a local user record subscribed to the installed mods
  (`AppData/Local/mod.io/10640/<Steam account>/user.json` of the Wine prefix); nothing is sent to mod.io from it. The game also cannot use an existing `Z:` folder as mod.io's root (Wine error 4390), so the
  root is reached as `C:\modio` (a link to `/data/modio`).

## Logs

`docker compose logs` shows every component on one stream, **one JSON object per line**: `{"ts":"2026-11-19T15:46:34.409Z","level":"info","component":"launcher","msg":"WinClient#1 joined the session"}`
(`ts` in UTC; `level` `debug`, `info`, `warn` or `error`; `component` `entrypoint` for this container's scripts, `launcher` for MPFever). `SRV_LOG_FORMAT=text` gives plain lines instead. The files are in the data volume
(`srv/logs/launcher-*.log`, `srv/launcher.out`, Dock's `srv/dock.log`); the Docker log rotates (20 MB, 5 files). Any JSON log collector (Loki, Elasticsearch, `jq`) reads the stream as it is.

The **game's and Dock's own logs** join the same stream (`component` `game` and `dock`; the game's lines keep their own time, its VERBOSE/MESSAGE/WARNING/ERROR levels become `debug`/`info`/`warn`/`error`). By default only
`warn` and above are shown, `SRV_GAME_LOG=off|error|warn|info|debug` changes that (`debug` is very verbose, mainly at the start). The files themselves stay in the data volume.

## Updates

The server looks for a new MPFever release every 30 minutes (`SRV_UPDATE_CHECK=notify`, the default; `off` stops the check) and **announces it once in the log** (`level` `warn`: "MPFever 0.9.2 is published; this server does not install it"). It never installs it by itself:
the image is updated (`docker compose pull && docker compose up -d`), so the version of the launcher, the module, the mod and Dock stay one tested set. Players need the client of the server's version.

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

**MPFever 0.9.2 and Transport Fever 3 build 40444** (2026-11-19): the image built from this branch with the 0.9.2 version, `install-game` run again from the updated Steam library, the existing world loaded: "IN SYNC", game build 40444, no error. A client of 0.9.2 joining it was not run yet.

Run end to end on the built image with volumes created empty, a real account and a real Windows client: `install-game`, the QR `login`, the token hand-over to Dock (Steamworks without a Steam
desktop), first start, `import-save`, world load, a client joining and staying identical, `docker compose stop` (about 10 s, world saved), restart restoring the saved world, the healthcheck, the
read-only container. Then a longer run:

| Run | Result |
|---|---|
| A real world of 122 MB (1.6 times the small one), 16 GB and 2 CPUs, 40 minutes, no client at the end | 0 desynchronisations, 0 errors, no out-of-memory kill. Game memory (PSS) climbs from 11.2 GB to 12.5 GB in the first 18 minutes of simulation, then stays flat (12.54 GB): a warm-up, not a leak. About 1.1 CPU while it simulates, game speed about x1.0 outside saves and resynchronisations. Container 14.9 GB including 2.7 GB of reclaimable cache: **16 GB is the minimum for this size**, 14 GB (the default) is not enough |
| The small world, **12 GB and 1 CPU** (the minimum limits) | runs: container peak 11.6 GB of 12 GB, no out-of-memory kill, 0 desynchronisations. Start takes 5 min 17 s (2 min 40 with 2 CPUs); a client's resynchronisation 285 s (96 to 140 s with 2 CPUs) |
| `docker compose stop` while a client has vanished (killed abruptly) | 71 s, exit code 0, the world saved: the stop waits up to about 60 s for the lost client, inside the 90 s script and 120 s Compose timeouts |

**Known limits found by these runs**
- **Worlds that use mods:** a real 595 MB world with 15 mod.io mods runs (`mods sync`, then start: "IN SYNC", no missing mod). Not yet run: a player joining and receiving the mods (the launcher's sending path is tested at the unit level only), mods from the Steam Workshop or local ones, and the long-run memory of such a world. A client whose own game had personal mods stayed stuck on "loading" for 10 minutes on the 122 MB world (the server resumed without it after 616 s).
- **Public list and Steam join:** with `SRV_PUBLIC=true` (or a stray host variable, see Settings) the server is announced to MPFever's public list with its Steam ID, and anyone can join through Steam; a
  stranger did so during the first long run. Keep `SRV_PUBLIC=false` and set `SRV_PASSWORD` for a private server.

**Not validated yet:** several clients at once (local test clients, or a second Steam account), a player receiving the mods from the server, runs of several hours. **The GPU variant** (`compose.gpu.yaml`, Intel/AMD through `/dev/dri` on a
Linux host) was not run; on Docker Desktop with WSL2 it cannot work as written (the container gets `/dev/dxg` and no WSL driver libraries): software rendering is the supported mode there.

## Build, tests, publication

The project's two workflows cover it, like the relay's image:

- `ci.yml`, on every push and pull request: **`docker-server-checks`** (`server/tests/check.sh`: shell and shellcheck, Python tests, Madeira Dock's unit tests, Compose files, no secrets, no
  binaries) and **`docker-server`**, which builds the image from the commit's server archive (the `build` job) and smoke-tests it (`server/tests/smoke.sh`: unprivileged, no game or Valve file
  inside, pinned runtimes, explicit errors on empty volumes). Nothing is pushed.
- `release.yml` (Release build, started by hand): tick **`docker_server`** to also publish `ghcr.io/<owner>/mpfever-server:<version>` and `:experimental`, built from that run's unsigned server archive
  and smoke-tested first (`docker` is the relay's image). Run it on the tag of a release to get the image of that release; the package's visibility is set on its page on GitHub.

Locally: put a package built by `build.bat` in `server/dist/MPFever-server.zip` and `docker compose -f compose.yaml -f compose.build.yaml build` (`APT_MIRROR` can name another Ubuntu mirror).
