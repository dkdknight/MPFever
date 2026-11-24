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
   (the project's image, `ghcr.io/dkdknight/mpfever-server`: this container holds your Steam token, so it should come from the project or from your own build. To build it yourself: `docker compose -f compose.yaml -f compose.build.yaml build`; another source is chosen with `MPFEVER_IMAGE` in `.env`, knowingly.)
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
| `SRV_BIND` | `0.0.0.0` | the host address the port is published on; `127.0.0.1` keeps it off the network (players join through Steam) |
| `SRV_PASSWORD`, `SRV_MAX_PLAYERS` | empty, `8` | |
| `SRV_COMPANY_MODE` | `shared` | `shared` or `separate` (one company per player) |
| `SRV_START_SPEED`, `SRV_PAUSE_WHEN_EMPTY`, `SRV_PLAYER_SPEED_CONTROL` | `1`, `false`, `true` | |
| `SRV_AUTOSAVE_MINUTES`, `SRV_BACKUPS` | `10`, `10` | autosave and copies kept in `srv/backups` |
| `SRV_PUBLIC`, `SRV_PUBLIC_ADDRESS` | `false`, empty | list the server in MPFever's public list; the list shows `SRV_PUBLIC_ADDRESS` (a name and port) or, empty, the IP address the announce came from: for a server on a home PC that players reach through Steam, give a placeholder (for example `steam-only.invalid:28090`) so that the list does not publish your IP address |
| `SRV_LOG_FORMAT` | `json` | `json` (one JSON object per line) or `text` |
| `SRV_UPDATE_CHECK` | `notify` | `notify` (new MPFever release announced in the log, never installed) or `off` |
| `SRV_GAME_LOG` | `info` | the game's and Dock's logs in the stream: `off`, `error`, `warn`, `info` or `debug` |
| `SRV_ADMIN_UI`, `SRV_ADMIN_PORT` | `off`, `8080` | the administration page (see Administering); it listens only when `on`, and `compose.admin.yaml` publishes it on 127.0.0.1 |
| `SRV_SHUTDOWN_WARNING` | `60` | seconds of warning in the players' chat before a stop or restart (`docker compose stop`, `mpfever-admin restart|stop`) when players are connected; at once when nobody is; `0`: no warning. Check who is connected first with `mpfever-admin status` |
| `SRV_STOP_GRACE` | `200` | seconds Docker waits at `docker compose stop` before killing the container. It must cover `SRV_SHUTDOWN_WARNING` plus 90 s for the final save: the server refuses to start with a longer warning, instead of cutting the save off. |
| `SRV_STEAM_MODE` | `online` | `offline` (experimental): the game starts through Valve's offline logon, so the account's game can run elsewhere at the same time (see "Steam: one licence...") |
| `SRV_RELAY`, `SRV_RELAY_HOST_KEY`, `SRV_RELAY_PASSWORD` | empty | host through an MPFever relay (optional): its address, the relay's `--host-key`, its password if it has one |
| `SRV_SPEED_VOTE` | `false` | `true`: the players' pause/play/speed requests are votes (more than half of the connected players within a minute; one player alone decides at once); the administrator can always use `mpfever-admin pause`, `resume` and `speed` |
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

The **game's and Dock's own logs** join the same stream (`component` `game` and `dock`; the game's lines keep their own time, its VERBOSE/MESSAGE/WARNING/ERROR levels become `debug`/`info`/`warn`/`error`). By default
`info` and above are shown (`SRV_GAME_LOG=off|error|warn|info|debug`; `debug` is very verbose, mainly at the start). What a server always says (no sound card to read the music, no mod.io or Paradox account) and the routine chatter of the game and of the MPFever mod (the world's "still" counter while paused, the "gui alive" frames, gamepad key assignments, mod content caches, graphics extensions...) is shipped at `debug` only, so the default `info` shows what the server does. The game's whole log is still kept in `srv/gamelogs` and in the support bundle. The files themselves stay in the data volume.

**What is kept for a bug report.** The launcher's session folder (`in.log`, `mod.log`, `native.log`, `mp_status.txt`, `companies.txt` ... the files that explain a desynchronisation) lives in the container's memory;
it is copied to the data volume (`srv/sessions/`) every 5 minutes, when the launcher exits and when the container stops (the last 5 are kept). The game rewrites its log at each start: the previous one is kept in
`srv/gamelogs/` (the last 5). **`mpfever-admin bundle`** makes one zip of it all in `/data/reports/` (the logs, the session files, the game's current and kept logs, Dock's log, the crash reports as text and json,
the versions and settings, the server's properties with every password, key and token blanked; never the secrets folder, the Steam transfer file, a savegame or a memory dump):

```
docker compose exec mpfever-server mpfever-admin bundle
docker compose cp mpfever-server:/data/reports/<the zip it names> .
```
What the server says is not all there is: the players' own logs stay on their PCs (their "Report a problem" button makes the zip).

## Updates

The server looks for a new MPFever release every 30 minutes (`SRV_UPDATE_CHECK=notify`, the default; `off` stops the check) and **announces it once in the log** (`level` `warn`: "MPFever 0.9.2 is published; this server does not install it"). It never installs it by itself:
the image is updated (`docker compose pull && docker compose up -d`), so the version of the launcher, the module, the mod and Dock stay one tested set. Players need the client of the server's version.

## Steam sign-in

`login` uses Steam's own authentication service (the QR flow of the Steam mobile app) and keeps a **refresh token** in `secrets/steam.json` of the data volume (mode 0600). At every game
start the token is handed to Dock as its one-use transfer file; it never appears on a command line, in the environment or in the image. When it expires the server stops with
a message (`login` again). Revoke it from your Steam account (Settings, Security) if it leaks.

## Steam: one licence, the server and the owner's own game together

Steam lets an account run Transport Fever 3 on one device at a time: signed in online, the server's game would end the owner's game on another PC ("another session is already playing"). `SRV_STEAM_MODE=offline`
(experimental, off by default: `online`) starts the game through **Valve's own offline logon**, the mechanism of desktop Steam's Offline Mode: Dock asks Valve's client whether the account may log on offline
(`CanLogonOffline`: it needs the *offline logon ticket* Steam issued to it during an earlier online start), then `LogOnOffline`, and the licence is answered from the client's own cache; the game starts through the same
`LaunchApp` call. Nothing is forged or bypassed: no ticket is stored, read or checked by Dock, and a refusal ends the start (Dock results 50, 51, 52 in `srv/dock.log`, see `server/dock/docs/OFFLINE.md`).

Measured on the PC that runs the server (2026-11-20, game build 40444): after an online start `session-offline-ready=1`; with `SRV_STEAM_MODE=offline` the log shows `session-offline-can=1`, `session-offline-logon-result=1`,
the game listed among 864 cached licences and `launch-game-running=1`, no `session-online` line, and the container holds no connection to Steam's servers; **Transport Fever 3 then started on the same PC with the same account
without the "another session" question**, and an MPFever client joined the server over TCP (and later through a relay) in sync.

What changes while offline: Steam networking is not available, so **players join by address (TCP) or through a relay, not "through Steam"** (the public list still announces the Steam ID, the join tries the address); the game's
Steam calls are answered by the client's cache. What is not known: how long Valve keeps the offline logon ticket valid (Valve's client decides; when it expires the start ends with result 50 and one online start renews it:
set `SRV_STEAM_MODE=online` for a start, then back), and nothing was run for days yet. Nothing changes by default.

## Behind a router that lets nothing in (a mobile box, CGNAT): the relay, optionally

The server listens itself by default. If nothing can reach it (a 4G/5G box, CGNAT, no router access) and Steam networking is not available (offline mode above), it can **host through an MPFever relay** instead
(see [RELAY.md](RELAY.md)): it connects *out* to the relay and the players join the relay's address. It is optional: with `SRV_RELAY` empty (the default) nothing changes.

```
SRV_RELAY=relay.example.org:28091          # the relay (host or host:port)
SRV_RELAY_HOST_KEY=<the relay's --host-key>   # only the holder of this key may host that relay
SRV_RELAY_PASSWORD=<its password>          # only if the relay has one
```

Start the relay with `--host-key KEY` (or `MPFEVER_RELAY_HOST_KEY`): players then need **no password** and nobody else can take the host's place (a relay without a host key gives the host to the first
comer). With the relay's `--list-url`, the relay announces the host to the public list from its own address and the list shows that address (the announce sends an empty `address`, so `SRV_PUBLIC_ADDRESS` is not used by it; the list only connects to an announced `host:port` when it resolves to the address the announce came from). If the relay cannot be reached the server tries again every 30 s; if the connection is lost while the world runs, the world is
saved and hosted again (the players come back by themselves). The server's session ends with its host: no player takes over (`--host-key` and `--migration` exclude each other).

**The public list.** The list shows a server it can reach or that has a Steam ID. Behind a relay with Steam offline, the **relay announces the server**: start the relay with `--list-url https://mpfever.knight-hd.fr`
(and `--host-key`) and the server appears with the relay's address, reachable, without Steam (see [RELAY.md](RELAY.md)); the server's launcher then does not announce by itself. Without a relay nothing changes: the server announces
itself, as before, and appears when its port is reachable or Steam is online. (The list service's own change, looking at an announced address, is a second way, for the day the deployed list has it.)

## Experimental: what to expect, and how it compares

**This is experimental.** It runs, it has been played with, and it can break: it relies on a Windows game under Wine and on Valve's private Steam client library (through Madeira Dock), neither of which is a supported setup. Do not host a save you cannot lose without keeping your own copies, and expect settings and behaviour to change between releases.

### Which one to use

| | Classic host | Relay (`mpfever-relay`) | Dedicated server, Windows (`--server`, [SERVER.txt](SERVER.txt)) | **Dedicated server, Docker (this)** |
|---|---|---|---|---|
| What runs the world | A player's own game, on that player's PC | A player's own game (the relay runs **no** game) | The full game on a PC of its own, hidden (no display) | The full game in a Linux container (Wine), no display, no GPU |
| World lives when the players leave | No (the host leaves, the session ends, unless migration, experimental) | No (same; optional migration and save on the relay, experimental) | Yes, paused while nobody is there, saved every 10 minutes | Yes, same server mode: paused while nobody is there, saved every 10 minutes, backups kept |
| Needs | The host's PC on and a reachable port or Steam | A cheap VPS; nothing to open on the host's side | A Windows PC with the game, Steam and a graphics card able to run the game | Docker (Linux, or Windows with Docker Desktop), 12 GB RAM minimum (16 GB for a 120 MB world), no GPU, **a Steam account that owns the game** |
| Steam licence | The player's own | The player's own | The PC's own Steam | The server's account must own the game; one *playing* session per account at a time (see the Steam offline mode below) |
| Status | Released | Works with real games; migration and saved copy experimental | Released | **Experimental** |

- The Docker server and the Windows dedicated server are the **same server mode of MPFever** (`MPFever.exe --server`, the same settings file, console and rules); the Docker one packages it for Linux hosts and removes the need for a Windows PC with a graphics card. It is not a different game server and not a rewrite: the world is still simulated by Transport Fever 3.
- A **relay is not a dedicated server**: it carries the connections, nobody simulates the world on it. A dedicated server can *optionally* use a relay (`SRV_RELAY`) when its network cannot receive connections (mobile box, CGNAT); otherwise the server needs no relay.
- Compared with a **classic host**, a dedicated server keeps the world up without anyone's PC, and no player's game is the authority.

### What has been tested

On a real Steam account, with real Windows clients, on Docker Desktop (Windows) and a built image:
- install, login, import, first start on empty volumes, restart restores the saved world, clean stop (the world is saved), healthcheck;
- one client at a time joins, resynchronises, `IDENTICAL on 2 games`, 0 desynchronisations; a 40-minute run on a real 122 MB world (16 GB, 2 CPUs) with 0 desynchronisations and no memory growth after warm-up;
- a public test server on a home PC behind a mobile box through a relay on a VPS, with Steam offline mode, while the owner played the same game on the same PC with the same account (2026-11-20): join, pause and resume, in sync, leave; mods installed from mod.io and the world loaded in sync with them;
- the 0.9.5 image published, pulled, and started with a world loaded (2026-11-23), without a client.

### What has not been tested (risks)

What is not validated here is left for the next pull request: this one is the experimental base, with its limits stated.

- **Several real clients at once**, runs of **several hours**, and a **player receiving the mods from the server** (unit and local level only).
- The **offline logon ticket's lifetime** (Steam offline mode): it is renewed by one online start; how long it lasts is unknown.
- A **second PC for the owner's game**, the **GPU variant** (`compose.gpu.yaml`), ARM hosts (not supported).
- **Valve changes its client** (Dock calls a private API): the server can stop working until the table in `server/dock/src/client_layout.c` is rebuilt (`server/dock/MAINTAINING.md`). The same goes for a game update (a new image, a new game import).
- Memory: 10.6 to 11.8 GB for a small world (see Measured); not for small hosts.
- The branch is large (the launcher changes are about 55 lines for the base, more for the mods, votes, relay host key and offline mode); a review is still needed, and it could be split.

## Roadmap of the dedicated server

Planned, in no promised order (none of it is done unless it says so):

- **Creating a world with no game session to click through.** Today a new world is made in the game's own *New Game* page on a PC and imported (`import-save`): there is no command line or script of the game that
  creates one. Goal: the server creates its world by itself from a few settings (map size, climate, seed, start year, difficulty, terrain and civilisation sliders), headless, so that a fresh container needs no PC with the game
  open. Decided: **as much as possible from the command line** (an engine or script interface of the game first, none is known yet); the game's graphical New Game flow, driven inside the container, only as a last
  resort. To be proven on a real start before anything is announced.
- **The optional administration page to reach every option of the dedicated server.** It exists (off by default, token, loopback port) with the console's commands. Goal: also read and change every setting of the server
  (the properties file: name, world, players, speed rules, votes, public list, relay, shutdown warning...), the game options of the world, the computer companies, the savegames and backups, the mods, the players (kick, ban)
  and the logs, with the changes that need a restart said as such and applied on request. Still off by default. Scope decided: the server's settings, the game options and the computer companies, the players
  (kick, ban), the savegames, backups and mods.
- **On hold for now (the owner's decision, 2026-11-20):** the items below and the split of this work into separate pull requests.
- **Remaining checks (not verified yet):** a player receiving the mods from the server, several clients at once, runs of several hours, the offline logon ticket's lifetime, a second PC for the owner's game, the GPU variant (Linux hosts only), and the server on a real run with the releases after 0.9.3 (0.9.5 and the 0.9.6 in progress: only started, not played with clients). `tests/test_ptpull0713.py` (random model) failed on the author's PC with "its process died twice" while its files are identical to `main`: cause not found.
- **Before a merge:** a review of the launcher changes, a first start by someone else, a decision on what to do when Valve changes its client, and a split into separate pull requests for the maintainer (the relay's image name is already #436; the rest of the dedicated server is one block).
- **Not planned:** a way around Steam's licence or sessions; Steam Workshop mods (Transport Fever 3 has none).

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

- Update: `docker compose pull && docker compose up -d`. Roll back: `MPFEVER_IMAGE=ghcr.io/dkdknight/mpfever-server:<version>` in `.env`. The launcher package is replaced at each start; `.env` and the volumes stay.
  Players must run the MPFever client of the server's version.
- The container runs as uid 1001 with a read-only root file system, all capabilities dropped, `no-new-privileges`, only the game port published. `.env` holds the server password: keep it out of version control.
- **A public server on a home PC.** What protects the PC: the game runs only inside the container (no host folder, no Docker socket, read-only root, no capability, `no-new-privileges`, at most 1024 processes, memory and CPU limits);
  `SRV_BIND=127.0.0.1` leaves nothing reachable from the network (players join through Steam, no router port is needed); `SRV_PUBLIC_ADDRESS` stops the public list from showing your IP address; the administration page stays off;
  secrets (Steam session, mod.io key) are in the data volume only. What remains: the game and MPFever speak to strangers (a flaw in them is the risk the container contains, not removes), and the container can still
  reach your network and the Internet outwards (Docker Desktop has no outbound filter): use a Steam account made for the server, without payment method or friends, and keep Docker Desktop and the image up to date.
- **Secrets and mods.** The game runs as the user that owns `/data/secrets` (Steam refresh token, mod.io key, admin token), and a Transport Fever 3 mod has Lua `io`: a mod is code that runs with the game's rights, so only
  install mods you trust (`SRV_MODS_SYNC=auto` installs mod updates by itself; set `off` to review them first). Two measures narrow what such a mod can reach: Wine's `Z:` drive points to a folder of links that leaves
  `/data/secrets` out (`SRV_WINE_RESTRICT_Z=0` restores the whole root, for debugging), and Dock's one-use transfer file (it holds the token) is written only while the game is not running, so it is not on disk during play.
  This is a narrowing, not a boundary: the game and the secrets are the same Unix user, so a mod using a path that does not go through `Z:` is not stopped by it. Running the secrets under another user is not done.
- The administration page refuses a request whose `Origin` is not its own `Host`; behind a reverse proxy that rewrites `Host` it accepts the forwarded `X-Forwarded-Host`, or an origin listed in `SRV_ADMIN_ORIGINS`
  (comma-separated, e.g. `https://admin.example.org`).
- Exit codes: 20/21 Valve client download or hash, 30 game missing, 40/41 Steam session missing or expired, 42 savegame missing, 50 launcher failing repeatedly, 60 another server already runs on the same data volume (only one instance is allowed). Reports: `docker compose logs`, `srv/launcher.out`,
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
- `release.yml` (Release build, started by hand): tick **`docker_server`** to also publish `ghcr.io/<owner>/mpfever-server:<version>` and `:experimental` (`docker_server_revision` = `2` gives `<version>-2` for a new image of the same MPFever version), built from that run's unsigned server archive
  and smoke-tested first (`docker` is the relay's image). Run it on the tag of a release to get the image of that release; the package's visibility is set on its page on GitHub.

Locally: put a package built by `build.bat` in `server/dist/MPFever-server.zip` and `docker compose -f compose.yaml -f compose.build.yaml build` (`APT_MIRROR` can name another Ubuntu mirror).
