# Operations: Valve client, updates, security, troubleshooting

## Valve's Steam client and Madeira Dock (compatibility and risk)

Dock calls **internal interfaces of Valve's client library** by position in its method tables, so it only drives builds it has verified (identified by the SHA-256 of `steamclient64.dll`)
and refuses any other one (result 30, before any sign-in). This image pins:

| | |
|---|---|
| `steamclient64.dll` | January 2026 build, 25 546 904 bytes, SHA-256 `71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640` (PE timestamp 1769726215) |
| Package fetched from Valve | `https://client-update.akamai.steamstatic.com/bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da`, SHA-256 `8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62` (checked before use) |
| Madeira Dock | github.com/willfaust/madeira-dock, commit `67780ba92e60dbfac4fe80eaf2ce34b9ea1a1c60` (GPL-3.0-or-later), built in the image |

Dock never starts `steam.exe`, so the pinned client is **never updated by Steam itself**. Risks, stated plainly:
1. Valve could remove that archive from its server or change its authentication protocol. The server then stops with an explicit message (hash mismatch, download failure, or Dock's refusal in `srv/dock.log`). There is no second Steam implementation to fall back on:
   the remedy is a new Dock revision with a verified layout, and a new pinned hash here (`scripts/lib.sh`, `Dockerfile`).
2. Dock is a young third-party project, not endorsed by Valve. Overlay, cloud saves and achievements are not supported by it; the server does not use them.
3. The sign-in is the account owner's own, through Steam's authentication service; tokens are stored only in `secrets/steam.json`. Using unofficial tooling on a Steam account carries the usual risk of Valve's rules: use an account you accept that for.
4. One Steam account plays one game at a time: playing on that account elsewhere while the server runs can interrupt it (observed: a few minutes of both running was tolerated, no guarantee). A dedicated account (Family Sharing) is recommended.

## Update, roll back, back up

- Update: `docker compose pull && docker compose up -d`. Roll back: `MPFEVER_IMAGE=ghcr.io/dkdknight/mpfever-server-docker:<version>` in `.env`. The launcher package is replaced at each start; `.env` and the volumes stay.
- Players must run the MPFever client of the server's version (the launcher says "other version than the host's" otherwise).
- Back up the `mpfever-data` volume (saves, `srv/backups`, session). Never copy `secrets/steam.json` anywhere else; revoke it from your Steam account (Settings, Security, devices) if it leaks.
- Resetting: remove the volumes (`docker compose down -v`) to start from nothing; the game volume is rebuilt by `install-game`.

## Security

Runs as uid 1001, read-only root file system, all capabilities dropped, `no-new-privileges`, only the game port published, no graphical or remote-desktop interface.
The image holds no secret; `.env` holds the server password if you set one: keep it out of version control.

## Troubleshooting

`docker compose run --rm mpfever-server status` lists what is missing. Launcher log: `docker compose logs`, files `srv/launcher.out`, `srv/logs/`, Dock report `srv/dock.log` (stage names and numbers only; result codes in madeira-dock's README).
Exit code 20/21 Valve client download or hash, 30 game missing, 40/41 Steam session missing or expired, 42 savegame missing, 50 launcher failing repeatedly.
