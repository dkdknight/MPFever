# MPFever server list

A small service that keeps the public list of MPFever dedicated servers. It runs on a Windows PC that stays on (a home server,
a VPS). Dedicated servers whose `mpfever_server.properties` says `public=true` appear in it, and players see them in the
**Servers** tab of MPFever's multiplayer page.

The list is not stored on disk (only the problem reports are, see below): it lives in memory, every server announces itself every 30 seconds and leaves the list
when it stops or after 90 seconds without news.

## Install

1. Build it (`build.bat` of MPFever builds it too) or take `MPFeverServerList.exe` from `serverlist\bin\Release`.
2. Copy `MPFeverServerList.exe`, `install-service.bat` and `uninstall-service.bat` into a folder of that PC.
3. Optional: a `port.txt` file next to them with another port (default **28100**).
4. Right click `install-service.bat` → **Run as administrator**. The service starts now and with Windows, the Windows
   firewall lets the port in, and Windows restarts the service if it ever stops.
5. On the router, forward **TCP 28100** to that PC (not needed behind a reverse proxy, see below).
6. Check it from another PC: `http://<public address>:28100/api/servers` shows `{"servers":[...]}`.

## Behind a reverse proxy (HTTPS, Cloudflare)

MPFever's own list runs behind Caddy and Cloudflare, at `https://mpfever.knight-hd.fr`. With Caddy, on the PC of the service:

```
mpfever.knight-hd.fr {
	reverse_proxy localhost:28100
}
```

The connections then come from the proxy. When the proxy is on the same PC or network (a loopback or private address), the
service lists a server with the address of `X-Forwarded-For` (its last address, the one the proxy saw: Caddy and nginx set or
add it), and when that address is one of Cloudflare's, with Cloudflare's `CF-Connecting-IP`. Port 28100 then does not need to
be open on the router. Cloudflare proxies only some ports (80 and 443 among them): use the proxy's port, not 28100, in the
address.

To try it without installing anything: run `MPFeverServerList.exe` (or `MPFeverServerList.exe 28100`) in a console;
Ctrl+C stops it. The log is `serverlist.log` next to the exe (2 MB at most, one old copy kept).

## Turning it on in MPFever

MPFever uses `https://mpfever.knight-hd.fr` (`MainForm.DefaultServerList`): players need nothing. Another list can be named in
`mpfever_settings.txt` next to `MPFever.exe`, and `serverlist=0` turns the list off:

```
serverlist=http://your-address:28100
```

A dedicated server appears in the list when its `mpfever_server.properties` has `public=true` (the default).
`public-address=` gives the address players should use (a domain name, `name:port`); empty, the list uses the public IP its
announces come from and the server's `port`.

## Problem reports (0.7.9)

MPFever 0.7.9 sends its problem reports here (the zip of every player's logs of the session): `POST /api/report` keeps the zip
in `reports\` next to the exe (60 days) and `GET /r/<id>.zip` gives it back (32 random hex digits: only the link leads to it).
Limits: 32 MB a report, 3 every 10 minutes and 10 a day from one address, 100 a day in all.

With a GitHub key, the service opens the GitHub issue itself, in the name of the key's account: players need no GitHub
account, and the key stays on this PC. Make a **fine-grained personal access token** on GitHub (Settings > Developer settings >
Personal access tokens > Fine-grained tokens): repository access **only dkdknight/MPFever**, permission **Issues: Read and
write**, nothing else. Put it alone in `github_token.txt` next to `MPFeverServerList.exe` (or in the environment variable
`MPFEVER_GITHUB_TOKEN`) and restart the service. Without it, the service only keeps the zip and MPFever opens a new issue with
its link for the player to send. Optional: `github_repo.txt` (another repository, `owner/name`), `public_url.txt` (the
address the links start with, default `https://mpfever.knight-hd.fr`).

Behind Caddy, nothing to change: the reports go through the same `reverse_proxy`. Cloudflare's free plan takes uploads up to
100 MB.

## API

| Request | Body | Answer |
|---|---|---|
| `GET /api/servers` | | `{"servers":[{id, name, address, steam, reachable, version, build, mode, world, motd, players, max, password}]}` |
| `GET /api/games` (v2) | | `{"v":2,"games":[{...the same fields..., kind, state, host, lang, joinPlaying}]}` |
| `POST /api/announce` | `{name, port, version, build, mode, world, motd, players, max, password, steam, address, token}` | `{"ok":true, id, token, every}` |
| `POST /api/announce` (v2, a player's game) | `{"kind":"game", name, port, version, build, mode, world, host, lang, state, players, max, password, joinPlaying, showAddress, steam, address, token}` | `{"ok":true, id, token, every}` |
| `POST /api/remove` | `{id, token}` | `{"ok":true}` |
| `POST /api/report` (0.7.9) | 4-byte length (little-endian), that much JSON `{title, body, issue?}`, then the zip | `{"ok":true, file, issue, note?}` |
| `GET /r/<id>.zip` (0.7.9) | | the report's zip |
| `GET /api/health` | | `{"ok":true, servers, games, "v":2}` |

- The first announce gets an `id` and a `token`; later announces send the `token` back, and only it can remove the entry.
- The service tries a TCP connection to the server's port before listing it (again every 5 minutes, or at every announce while
  it does not answer). A server that gave its Steam id is listed even when its port is closed: players then join it through
  Steam.
- Limits: 8 KiB per request, one announce per server every 10 s, 4 servers per IP address, 2000 servers. Text fields lose their
  control characters and are cut (name 40, world 60, motd 140 characters).
- Plain HTTP: nothing secret goes through it. For HTTPS, put it behind a reverse proxy (see above).

### Version 2: the players' own games (MPFever 0.6)

A player who hosts a game from the game's main menu can make its lobby public (the lobby's game option « Public game », off by
default). Its MPFever announces it with `"kind":"game"` every 30 s while the lobby is open (and while the game runs, when the
host lets players join then), and removes it when the game starts or the lobby closes.

- A game is found by its host's **Steam id**, not by its address: two players behind the same shared address (a carrier's CGNAT)
  with the game's usual port are two games. While a game lives, its Steam id is refused from another address. One announce
  every 10 s per game and address, **8 games per IP address**.
- Its address is **neither probed nor listed** unless its host chose to show it (`showAddress`; then it is probed like a server's
  port). Players join it through Steam. Without a Steam id, a game must show its address.
- `GET /api/servers` is unchanged: the dedicated servers only, with the same fields, so MPFever 0.5.x never sees a player's
  game. `GET /api/games` lists everything with `kind` (`server` or `game`), `state` (a game's: `lobby` or `playing`), `host`,
  `lang` and `joinPlaying`.
- MPFever 0.6 announces a game only to a list whose `/api/health` says `"v":2`, and reads `/api/games` (`/api/servers` when the
  list has no such route). **Update the service before publishing MPFever 0.6.**
- No moderation of the names in v1. `MPFeverServerList.exe <port> --loopback` listens on 127.0.0.1 only (the offline test,
  `tests/test_serverlist.py`).
