# MPFever dedicated server for Linux (experimental)

A server that runs the **real Transport Fever 3 simulation** in one Docker container: the Windows game under Wine, started through
[Madeira Dock](https://github.com/willfaust/madeira-dock) and Valve's own Steam client library. No GPU, no screen, no Steam desktop.
Players join it with the usual MPFever client (same version) from Windows.

> **Status: experimental.** It works for short sessions on a small world with a real Windows client (see "Validation" in
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). It needs **your own** Transport Fever 3 licence: the image contains no game file and no Valve file.

## What you need

- A Linux x86-64 host or VPS (Docker with Compose v2), **12 GB of RAM or more** free for the container, about 1 core, **a file system with sparse-file
  support** (ext4, xfs, btrfs) and about 6 GB of disk. No GPU.
- A Steam account that **owns Transport Fever 3**, with the Steam mobile app (to approve the sign-in once). Use an account that is not played on
  at the same time as the server (one Steam account plays one game at a time).
- A copy of the game on a PC where it is installed (to build the small "lite" install), and a savegame (`.sav`) of the world to host.

## Install

```
mkdir mpfever-server && cd mpfever-server
curl -fsSLO https://raw.githubusercontent.com/dkdknight/MPFever/main/server/compose.yaml
curl -fsSL  https://raw.githubusercontent.com/dkdknight/MPFever/main/server/.env.example -o .env
```

Edit `.env` (at least `WORLD`, the savegame's name without `.sav`). Then, once:

1. **Pull the image**: `docker compose pull`
2. **Import the game** from your own Steam library (read-only mount; the 3D data is left out, 66 GB become about 1 GB on disk):
   ```
   docker compose run --rm -v "/path/to/Steam/steamapps:/src:ro" mpfever-server install-game /src
   ```
   (`/path/to/Steam/steamapps` is the library folder that holds `common/Transport Fever 3` and `appmanifest_3493540.acf`.)
3. **Sign in to Steam** (QR code in the terminal, approve it in the Steam mobile app; no password is typed or stored):
   ```
   docker compose run --rm mpfever-server login
   ```
   Only a Steam refresh token is kept, in the `mpfever-data` volume (`secrets/steam.json`, mode 0600). It is valid for several months; when it expires the
   server says so and you run `login` again.
4. **Import your savegame** (the `.sav` and the files next to it with the same name):
   ```
   docker compose run --rm -v "/path/to/saves:/in:ro" mpfever-server import-save /in/myworld.sav
   ```
5. **Start**: `docker compose up -d`. It restarts by itself after a reboot or a crash. `docker compose logs -f` shows the server's log.

Check at any time what is missing: `docker compose run --rm mpfever-server status`.
Players connect to `<host>:28090` (forward the TCP port on your router for the Internet). Stop with `docker compose stop` (the world is saved first).

## Configuration

All settings are in `.env` and take effect with `docker compose up -d`, no rebuild. The game's save files and the launcher's backups (`srv/backups`, `backups=` in `.env`)
live in the `mpfever-data` volume: back it up (`docker run --rm -v mpfever-data:/d -v "$PWD":/b ubuntu tar czf /b/mpfever-data.tgz -C /d .`). The game volume `mpfever-game` can be rebuilt
with `install-game` at any time. Server console commands (`save`, `kick`, ...) are those of `MPFever.exe --server` (see the server's `SERVER.txt`).

## Update and roll back

Images are tagged by version (`ghcr.io/dkdknight/mpfever-server:<version>`) and `experimental`. Update: `docker compose pull && docker compose up -d`. Roll back: set
`MPFEVER_IMAGE=ghcr.io/dkdknight/mpfever-server:<previous version>` in `.env` and `docker compose up -d`; the data volume is untouched. Players need the MPFever client of the server's version.
See [docs/OPERATIONS.md](docs/OPERATIONS.md) for backups, Valve updates, security and troubleshooting.

## Build it yourself

`build.bat` at the repository root builds the launcher and package (`release/MPFever-<version>-server.zip`); copy it to `server/dist/MPFever-server.zip` and run
`docker compose -f compose.yaml -f compose.build.yaml build`. The same steps run in CI (`.github/workflows/dedicated-server.yml`).

## Licence

GPL-3.0-or-later like MPFever. The image contains Madeira Dock (GPL-3.0-or-later, built from source at a pinned commit, licence texts in `/opt/mpfever/licenses`), Wine (LGPL), Mono, Mesa.
Transport Fever 3 and Steam belong to their owners and are never redistributed here.
