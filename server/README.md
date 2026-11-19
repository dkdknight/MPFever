# MPFever dedicated server for Linux (experimental)

Docker packaging of the Linux dedicated server: Dockerfile, Compose files, entrypoint and administration commands, Vulkan layer, tests.
**The guide (install, settings, how it works, risks, validation status) is [docs/LINUX-SERVER.md](../docs/LINUX-SERVER.md).**

| Path | |
|---|---|
| `compose.yaml`, `.env.example` | what a user needs: `docker compose up -d` |
| `compose.build.yaml`, `compose.gpu.yaml` | local build; optional GPU (not validated) |
| `Dockerfile` | multi-stage image (Madeira Dock and the Vulkan layer built from source, Wine and Mono pinned) |
| `scripts/` | `entrypoint.sh` (run, login, install-game, import-save, status), `steam_session.py` (QR sign-in, token hand-over to Dock), `mklite.py` (lite game install), `healthcheck.sh`, `measure.sh` |
| `vklayer/` | the Vulkan layer that makes drawing a no-op |
| `config/settings.lua` | the game's minimal profile (lowest graphics) |
| `tests/` | `check.sh` (static checks run by CI), unit tests |
