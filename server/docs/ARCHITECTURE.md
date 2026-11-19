# Architecture, decisions, measures

## The pieces

| Part | What | Why |
|---|---|---|
| Game | `TransportFever3.exe` (Windows) under **Wine 11** (pinned package) on Ubuntu 24.04 | A native Linux build of the game drifts from Windows clients (different C++ library, `std::` distributions inlined in the game): same executable = same simulation. Not Proton: no DXVK, rendering is a no-op. |
| Launcher | `MPFever.exe --server --server-start headless` under **Mono**, with a Linux/Wine mode (`launcher/Core.cs`: `GameInstall.WineMode`, `MPFEVER_WINE=1`; `Server.cs`: `MPFEVER_STOPFILE`) | Provides all the host logic and the same `winhttp.dll` native module and mod as the players'. Built from this repository by `build.bat`. |
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

## Measured (small world, MPFever 0.9.0 package, no GPU, one real Windows client)

| | |
|---|---|
| Game RAM | 10.1 to 10.3 GB (11.0 to 11.2 GB before the GPU-memory trim); heap of about 9 GB is the game's own |
| Steam side (Dock + Valve service) | about 280 MB (Steam desktop under Wine: 2.7 GB) |
| CPU | about 0.7 core at x0.98 game speed |
| Disk | about 0.9 GB game + about 3 GB prefix and client |
| Sync with a real Windows client | `IDENTICAL on 2 games`, 0 desynchronisations, runs of 3 to 13 minutes |

## Validation status (honest)

Validated on the maintainer's machine with the earlier hand-prepared volumes: Dock sign-in with the cached Steam session, licence check, launch, restart after a game crash, cold start of the container, synchronisation
with a real Windows 0.9.0 client for short runs (join, resynchronisation, identical checks).
**Not validated yet**: first start on an empty volume with `install-game`, `login` (QR) and the token transfer to Dock; `import-save`; graceful stop through the stop file; runs of 30 minutes or more;
several clients (a Steam account plays one game at a time: a second account is needed); large worlds; forced CPU/memory minimums; a full image rebuild (the image was last assembled on top of an older Wine layer);
the GPU variant; the published image (nothing is published until the checklist of the pull request is done).

## Decisions not to redo

Native Linux game: abandoned (drift). Steam desktop under Wine: replaced by Dock (2.7 GB web helper floor; stubbing it crashes Steam). Aurelia (headless Steam CLI) downloads the game but cannot run TF3 without a Steam client.
A server without the game installed is impossible with the Steam build without circumventing the DRM (refused): the game comes from the host's own licence. `autoupdate=0` is mandatory (the official updater replaces the launcher and module).
