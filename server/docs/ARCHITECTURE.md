# Architecture, decisions, measures

## The pieces

| Part | What | Why |
|---|---|---|
| Game | `TransportFever3.exe` (Windows) under **Wine 11** (pinned package) on Ubuntu 24.04 | A native Linux build of the game drifts from Windows clients (different C++ library, `std::` distributions inlined in the game): same executable = same simulation. Not Proton: no DXVK, rendering is a no-op. |
| Launcher | `MPFever.exe --server --server-start headless` under **Mono**, with a Linux/Wine mode (`launcher/Core.cs`: `GameInstall.WineMode`, `MPFEVER_WINE=1`; `Server.cs`: `MPFEVER_STOPFILE`) | Provides all the host logic and the same `winhttp.dll` native module and mod as the players'. Built by `build.bat` from the latest official release tag with this branch's launcher changes applied (CI). |
| Steam | **Madeira Dock** (`dockhost.exe`, built from source at a pinned commit) driving **Valve's own `steamclient64.dll`** | The game requires a running Valve client. Dock signs in with the account owner's refresh token, asks Valve's client for the licence and has it start the game: no `steam.exe`, no `steamwebhelper` (about 280 MB instead of 2.7 GB). No emulation of Steamworks, no DRM bypass: every decision is Valve's. |
| Rendering | Lavapipe (software Vulkan) + the layer `vklayer/` (`MPF_VKNULL=1`, `MPF_VKNULL_MODE=all`, `MPF_VKNULL_TRIM=1`) and `MPFEVER_HEADLESS_NORENDER=1;MPFEVER_HEADLESS_FPS=10` | Draws, copies and render passes become no-ops; mapped GPU memory nobody reads is given back. A real GPU is used if the layer is off (`compose.gpu.yaml`, not validated). |
| Disk | "Lite" game install (`scripts/mklite.py`) | The engine reads archives at fixed offsets, so archives keep their layout: textures, audio and blobs become file holes (sparse), images stay valid but empty. 66 GB become about 1 GB on disk. Generated from the host's own copy; never distributed. |
| Display | `Xvfb` only | The game closes without an X server. Nothing is exposed (no VNC, no noVNC). |

## Layers and data

- **Image** (versioned, immutable): Wine, Mono, launcher package, Dock, Vulkan layer, scripts. No secret, no TF3 file, no Valve file.
- **`/data` volume**: Wine prefix, Valve client (fetched from Valve, pinned hash), `secrets/steam.json`, saves (inside the Steam `userdata` of the prefix), `srv/` (launcher logs, backups).
- **`/game` volume**: the lite game install. **Configuration**: `.env` (environment), written to `mpfever_server.properties` at each start.
- **Sign-in**: `scripts/steam_session.py login` (Steam's `IAuthenticationService` QR flow, the same as the Steam mobile app's "sign in with QR") stores a refresh token;
  at each game start `feed` writes Dock's one-use transfer file (`MDOCK001`) with it. The token never appears on a command line, in the environment or in the image.
- **Start** (`scripts/entrypoint.sh run`): checks (disk, sparse support, RAM, game, session, save), first-start prefix creation (marker file, so a restart reinstalls nothing), pinned Valve client,
  launcher with restart-on-exit (5 quick failures in a minute stop the container with a message), `SIGTERM` writes the stop file: the world is saved, the game closed, then the container exits.

## Measured (small world, MPFever 0.9.2 package, no GPU, built image, fresh volumes)

| | |
|---|---|
| Container (cgroup, game running, no client) | about 10.6 to 11.8 GB: anonymous 9.5 GB, page cache 1 to 2 GB (reclaimable), shared 0.7 GB |
| Game process | RSS 10.1 GB, PSS 10.0 GB (the heap of about 9 GB is the game's own; the Vulkan layer's trim returns about 0.7 GB of mapped GPU memory) |
| Dock (`dockhost.exe`) | RSS 256 MB, PSS 193 MB; its CPU is 0.02 core |
| Other processes | launcher (Mono) 107 MB, Wine desktop 87 MB, Xvfb 23 MB, session feeder 20 MB, wineserver 15 MB |
| CPU | game 0.6 core at x0.98 game speed |
| Disk | game 1.3 GB on disk (66 GB apparent), prefix and Valve client about 3 GB |
| Image | 3.5 GB (Wine 11 with its i386 part 1.5 GB, Mesa/LLVM about 0.3 GB, Mono runtime subset); was 4.3 GB with `mono-complete` |
| Start | image to "game ready" about 2.5 minutes with a warm cache, plus about 1.5 minutes the very first time (prefix creation, Valve client download, one extra game start) |
| Sync with a real Windows client (0.9.2) | join, resynchronisation 140 s, then `IDENTICAL on 2 games`, 0 desynchronisations, 6 minutes observed |

`scripts/measure.sh` prints these figures from inside the container (`docker compose exec mpfever-server /opt/mpfever/scripts/measure.sh`).
Tried and dropped: `MADV_REMOVE` on the mapped GPU memory (no gain), a Wine without its i386 package (the launcher binaries ship in the package that depends on it), fewer or no Lavapipe threads (CPU worse).

## Validation status (honest)

Run end to end on the built image, on volumes created empty: `install-game` from a real Steam library (2 min), Steam QR `login` (real account, token kept 0600, valid until the printed date),
`import-save`, first start (Wine prefix, Valve client download with hash check), **token hand-over to Dock and Steamworks initialisation without any Steam desktop**, launch of Transport Fever 3 under Wine, MPFever server mode,
world load, a real Windows client joining with resynchronisation and identical checks, `docker compose stop` (9 s, exit 0, world saved at stop), restart restoring the saved world time, healthcheck healthy, read-only root and no capabilities.
**Not validated yet**: runs of 30 minutes or more; several clients (a Steam account plays one game at a time: a second account is needed); large worlds; forced CPU/memory minimums (limits are set, behaviour under pressure not tested);
the GPU variant; the published image (nothing is published); stopping while a client is connected and has vanished (the stop waits for it up to about 45 s, the timeouts allow it); the CI image job (see the pull request).

## Decisions not to redo

Native Linux game: abandoned (drift). Steam desktop under Wine: replaced by Dock (2.7 GB web helper floor; stubbing it crashes Steam). Aurelia (headless Steam CLI) downloads the game but cannot run TF3 without a Steam client.
A server without the game installed is impossible with the Steam build without circumventing the DRM (refused): the game comes from the host's own licence. `autoupdate=0` is mandatory (the official updater replaces the launcher and module).
