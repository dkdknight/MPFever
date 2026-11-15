# MPFever session server for Linux (tunnel mode)

Status: **works with two real games** (`MPFever.exe --autotest`, one host and one client through the server, also through a server on
a remote Linux VPS): `IN SYNC, desyncs 0, refused 0`. Host migration (`--migration`) works with three real games, see "Host migration".

## What it is

`server-linux/` is a small program (`mpfever-relay`, .NET, no game, a few MB of RAM) that players connect to. **The first player in hosts
through it**: that player's MPFever and game are the host exactly as before (the host's code in the launcher is unchanged), but its
connection to the players goes through the server instead of a port of its own. Everybody else joins the server's address like any host.
So: one stable address, nothing to open or forward on the host's router (useful behind CGNAT), and the server can run on any cheap VPS
because it simulates nothing.

## Using it

Server (Linux, or Windows: it is plain .NET):

```
mpfever-relay --port 28090 --password SECRET --max-players 8
```

`deploy`: copy the self-contained binary (`dotnet publish server-linux -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true`)
and run it under systemd. Open its TCP port on the server's firewall.

The host, in `mpfever_settings.txt` next to `MPFever.exe`:

```
server=my.server.example:28090
serverpw=SECRET
```

then hosts from the game's Multiplayer page as usual. The players join `my.server.example:28090` (and the password) as for any host. Without
`server=` nothing changes. Everybody needs the same MPFever version as the server (it refuses others, like the dedicated server does).

## How it works

The wire format is in the comment of `server-linux/SessionCore.cs`. In short: the host's launcher is one connection to the server
(`RemoteRelay`, `launcher/RemoteRelay.cs`, the same surface as `Relay` through the new `IRelay`). The server tells it which players
came in and left (`tun_join`, `tun_left`) and forwards what they send; the host's messages go back through it: to everybody, to everybody
but one (`!name:kind`, the host's `Broadcast(m, except)`) or to one player (`@name:kind`). A savegame sent to a player is a binary message
and goes through untouched. The server decides who may come in (version, password, places, one host at a time) and nothing else.

What it does not do: a player that drops is not waited for (the host's 60 s grace is not used through a server yet); the Steam
tunnelling (`steam:` addresses) and the router port mapping are off for a host that uses a server.

## Tests

- `mpfever-relay --selftest`: 65 checks, no game: admission, routing to and from the host, savegame-sized binary messages, kick, and the host's
  `RemoteRelay` against the server; also the migration below.
- `MPFever.exe --selftest` (unchanged, passes).
- With a game: `set MPFEVER_SERVER=127.0.0.1:28090` and `MPFever.exe --autotest <savegame>` with the server running (or reached through
  `ssh -L 28090:127.0.0.1:28090 vps`): two real games build roads and upgrade streets through the server; the verdict is `IN SYNC`.

## Host migration

`mpfever-relay --migration`: when the host leaves, a player that can take over does, instead of the session ending. No player has to
reconnect; they see the world stop and a resynchronisation (a loading screen) of about 25 s on the test save.

How it goes (`server-linux/Hosting.cs`; launcher: `OnTunHost`, `PromoteToHost` in `launcher/MainForm.cs`):

1. A launcher that has the takeover code says so when it joins (`mig` in its join). One that does not (an older MPFever) is never asked.
2. The host's connection ends. The server asks the oldest player that can take over (`tun_host { migrate, prev, epoch, token }`). The token
   is random (128 bits), made for this attempt and this player, and valid once.
3. The successor's launcher stops acting as a client (its game and its connection stay), sets the host state it knows (session started,
   the speed the host last set, the company mode), writes `role=host` in `identity.txt` and connects to the same server again as the host,
   showing the token. A connection that only has the successor's name is refused, so is a second use of the token.
4. The server makes it the host, announces every other player to it (`tun_join`) and then says the list is complete (`tun_players`).
5. The launcher tells every game that the old host and its own old name are gone (`peerleft`): a game that kept their last clock would wait
   for them for ever. It then starts the host's own resynchronisation: it pauses everybody, saves its game, reloads it (as the host: the role
   is read when a game loads) and sends the save to the others, as for any resynchronisation.

If the successor does not connect within `--migration-timeout` seconds or leaves, it is not asked again for this migration and the next
player is; when nobody is left, the session ends and every player is disconnected. If the new host's connection drops later, a new migration
starts. The server cannot know whether the new host has finished the resynchronisation: it only knows the successor is connected as the host.

The test: `MPFEVER_SERVER=127.0.0.1:28090 MPFEVER_NOLOCALCLIENT=1 MPFEVER_CLIENT2=1 MPFEVER_SCENARIO=migrate MPFever.exe --autotest <save>`
for the host, then two `MPFever.exe --autoclient 127.0.0.1:28090 <save> <name>` for the players, against `mpfever-relay --migration`.

## Why a tunnel, and what it is not

- The host is more than a role: `MainForm` keeps the session's state (players, clocks, speed and pause, company mode, lobby, hashes,
  resync bookkeeping) and the host's game is the reference for the world and produces the savegames. A program with no game cannot be
  that, so the server does not try: it only carries the messages and decides who may come in and who hosts. The host's code stays in a
  player's launcher, unchanged.
- It is **not** a dedicated server that runs the world with nobody playing (`MPFever.exe --server` does that, with the game on a Windows
  machine). Running the game on Linux would need MPFever's native module (`winhttp.dll`, Windows only) on the Linux build of the game.
- The role of a game (`host` or `client`) is read when the game loads (`identity.txt`, `C.ROLE` in the mod), which is why a successor
  reloads its game as the host instead of switching on the fly.

## Security

The server may be reachable from the Internet, so what a connection can do before it is let in, and what a player can do to the others, is
limited on purpose (each point has a test in `mpfever-relay --selftest`):

- **Before a player is let in:** a line longer than 64 KB, or any binary message, ends the connection; a connection that has not joined within
  15 s is cut; no more than 64 connections (`--max-connections`) are accepted at once; a `join` that cannot be read is refused (the Relay lets
  a player in when its admission check throws: this one refuses).
- **Passwords:** compared in constant time; 5 wrong ones from an address refuse that address for 5 minutes, even with the right one.
- **The server's own messages** (kinds that start with `tun_`) cannot be sent by a player: they are dropped. Otherwise a player could make the
  host forget another player (`tun_left`), believe in a player that is not there (`tun_join`) or give the host role away (`tun_host`).
- **The host role:** only the first player that asks, or the successor with its one-time token, can be the host.
- **The text parser** (`LuaLit`, shared with the launcher) no longer loops on text that starts nothing known and no longer follows nested
  tables without a limit (a line of braces overflowed the stack, which cannot be caught). This also protects a launcher that hosts itself.
- A savegame part announced and never sent no longer reserves its size in memory (past 1 MB it is kept as it arrives).

**Not done: encryption.** The protocol is plain TCP, as it always was: the password and the session are readable on the way. Adding TLS means
a change on every player's side (the launcher's `Client`) and a certificate, which is a compatibility decision for the maintainer. Until then:
use a password, prefer a private network (Tailscale, WireGuard) between the players and the server, or put a TLS tunnel (stunnel, ssh -L)
in front. The server's `--password` is a shared secret for a group of friends, not an account system.

## Known limits

- A guest that drops is waited for (`--grace`, 60 s: its launcher goes on with its link, the host is not told); the **host** is not: when its
  connection drops a migration starts at once. A short cut of the host therefore costs a resynchronisation. Reconnecting the host with its
  link would need `RemoteRelay` to reconnect and the server to wait for it; left for later.
- Steam invitations and the router port mapping are off for a host that uses a server.
- A host that goes back to the main menu less than 2 minutes after its last load keeps its session (the existing rule of
  `OnMenuRequest("menu")`); closing the game ends it and triggers the takeover.
- Players that join while a migration is under way wait; the server announces them to the new host.
- The resynchronisation after a takeover is started by one launcher: `resyncing` is set in many places of the launcher without a lock, as it
  was before this change; the takeover checks it once, after the server has said the list of players is complete.
- Tested with three real games on one PC and with two PCs (a Windows host, a player on Linux/Proton) through a VPS, in both directions.

## Deploying

Build: `dotnet publish server-linux -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true`. A systemd unit that keeps it small
and contained (the server writes nothing to disk):

```
[Service]
User=mpfever
EnvironmentFile=/etc/default/mpfever-relay      # MPFEVER_RELAY_OPTS=--port 28090 --password SECRET --migration
ExecStart=/opt/mpfever-relay/mpfever-relay $MPFEVER_RELAY_OPTS
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Environment=DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp
```

Open the TCP port of `--port` in the firewall. Every player needs the same MPFever version as the server (it says so when it refuses one).
