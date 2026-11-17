# MPFever session server for Linux (tunnel mode)

Status: **works with two real games** (`MPFever.exe --autotest`, one host and one client through the server, also through a server on
a remote Linux VPS): `IN SYNC, desyncs 0, refused 0`. Experimental host migration has been tested with three real games.

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

then hosts from the game's Multiplayer page as usual. The players join `my.server.example:28090` and enter the password as for any host.
Without `server=` the player hosts directly. The Windows dedicated server listens directly and uses its own admission settings.

## Relay protocol

The relay protocol number is `1` (`RelayProtocol.Number`). The hosting and joining launchers send it as `rp` when they join.
The relay refuses a missing or different number with reason `relay`. Launchers and the relay can come from different
MPFever releases if they speak the same relay protocol. The host applies its usual MPFever version rule using the version
in `tun_join`. The guest still checks the host's version in `welcome`.

Raise the relay protocol number when an incompatible change affects the message format, admission, reconnection, or a
`tun_*` message. An MPFever release by itself requires no change to the relay protocol number.

## How it works

The wire format is in the comment of `server-linux/SessionCore.cs`. In short: the host's launcher is one connection to the server
(`RemoteRelay`, `launcher/RemoteRelay.cs`, the same surface as `Relay` through the new `IRelay`). The server tells it which players
came in and left (`tun_join`, `tun_left`) and forwards what they send; the host's messages go back through it: to everybody, to everybody
but one (`!name:kind`, the host's `Broadcast(m, except)`) or to one player (`@name:kind`). A savegame sent to a player is a binary message
and goes through untouched. The relay checks the relay protocol, password, available places and the host role. The host applies its own
admission rules and can send a refusal through the relay.

| Message | Fields | Purpose |
| --- | --- | --- |
| `tun_join` | `name`, `addr`, `v` | Tells the host the guest's name, address and MPFever version. The relay keeps the password. |
| `tun_left` | `name` | Tells the host a guest has left. |
| `tun_host` | `you`, `epoch`, `migrate`, `prev`, `token` | Assigns the host role or asks a player to take it over. |
| `tun_players` | `n` | Marks the end of the guest announcements after a takeover. |
| `tun_kick` | `name`, `payload` | Sends a host's refusal or kick to a guest and disconnects it. |

The relay waits for a dropped guest for up to `--grace` seconds. Steam tunnelling (`steam:` addresses) and router
port mapping are off for a host that uses a relay.

## Tests

- `mpfever-relay --selftest`: admission, routing to and from the host, savegame-sized binary messages, kick, and the host's
  `RemoteRelay` against the server; also the migration below.
- `MPFever.exe --selftest` (unchanged, passes).
- With a game: `set MPFEVER_SERVER=127.0.0.1:28090` and `MPFever.exe --autotest <savegame>` with the server running (or reached through
  `ssh -L 28090:127.0.0.1:28090 vps`): two real games build roads and upgrade streets through the server; the verdict is `IN SYNC`.

## Host migration (experimental)

Host migration is experimental and off by default. Enable it with `mpfever-relay --migration`. When a successor
takes over, the remaining players stay connected and see a resynchronisation. The loading screen took about 25 s on the test save.

How it goes (`server-linux/Hosting.cs`; launcher: `OnTunHost`, `PromoteToHost` in `launcher/MainForm.cs`):

1. The relay only considers players that advertised takeover support in their join (`mig`).
2. The host's connection ends. The server asks the oldest player that can take over (`tun_host { migrate, prev, epoch, token }`). The token
   is random (128 bits), made for this attempt and this player, and valid once.
3. The successor's launcher stops acting as a client (its game and its connection stay), sets the host state it knows (session started,
   the speed the host last set, the company mode), writes `role=host` in `identity.txt` and connects to the same server again as the host,
   showing the token. A connection that only has the successor's name is refused, so is a second use of the token.
4. The server makes it the host, announces every other player to it (`tun_join`) and then says the list is complete (`tun_players`).
5. The launcher tells every game that the old host and its own old name are gone (`peerleft`): a game that kept their last clock would wait
   for them for ever. It then starts the host's own resynchronisation: it pauses everybody, saves its game, reloads it (as the host: the role
   is read when a game loads) and sends the save to the others, as for any resynchronisation.

| State | After a takeover | Code |
| --- | --- | --- |
| World | The successor saves and reloads its current world as host and sends that save to the other players. This includes companies present in the save. | `PromoteToHost`, `Resync` |
| Running state, speed, company mode | The successor marks the session started, uses the last positive speed it received (default 1), and uses the received shared or separate mode when known. Scheduled pauses and the old host's resync state are reset. | `hostSessionSpeed`, `hostCompanyMode`, `pauseAt`, `SessionPayload` |
| Connected players and Steam invitations | The relay re-announces the guests. The successor refreshes Steam presence with the same relay address when Steam is enabled for the menu game. | `tun_join`, `tun_players`, `InviteConnect` |
| Lobby rules and AI configuration | The old lobby's starting money, bankruptcy delay, sharing rules, auctions and AI setup are not transferred. The successor computes its own session payload. | `StartMoney`, `BankruptMonths`, `ShareRules`, `AuctionRule`, `lobbyAi`, `AiPayload` |
| Game and launcher options | The successor computes the settings it advertises from its own launcher state. This includes the launcher settings for waiting and stopping where enabled. | `GameOptions`, `Options.SessionPayload`, `MPFEVER_NOWAIT`, `MPFEVER_NOSTOP` |
| Autosaves, public games, reports and chat | No transfer of the old host's autosave schedule or files, public listing, approvals and ban list, report requests, or chat backlog for new arrivals. | `HostAutosaveTick`, `PublicGames.cs`, `ReportShare.cs`, `chatLog` |
| Mods and DLCs | The save carries its own world content. The successor uses the information it built locally as a guest and does not receive the old host's mod/DLC bookkeeping. | `lobbyMods`, `lobbyModsKnown`, `lastHostDlcs`, `SessionDlcs` |

Guests keep their last seen chat ID (`lastChatId`). Since the successor uses its own chat counter (`chatId`), guests may skip
new chat messages until that counter exceeds the last ID they saw.

If the successor does not connect within `--migration-timeout` seconds or leaves, it is not asked again for this migration and the next
player is; when nobody is left, the session ends and every player is disconnected. If the new host's connection drops later, a new migration
starts.

Each transition is decided under one lock and only if the state is the one the caller saw (`Migrate(prev, fromEpoch)`): a late timer, or two
events at once, cannot ask a second player while a host is there nor end a healthy session. This was a real race, reproduced with a test seam
before it was fixed.

**What the server does not know:** whether the new host has finished its resynchronisation. It is deliberately not a phase of the server:
a host that is connected but slow cannot be told from one that is busy loading a save of 150 MB, so a "resynchronising" timeout would
replace a working host. The failure that can be told, a connection that drops, already starts the next migration. Confirming the
resynchronisation (a message from the new host when it is done, and a policy for a host that never says it) would need a new message in the
launcher and a decision about how long a resynchronisation may take; left for a later change.

On the launcher side, if `tun_players` does not arrive within 15 s (a server older than this message), the takeover goes on, as the first
version did: a player announced later is a new arrival for the host's code, which sends it the host's game by itself.

The test: `MPFEVER_SERVER=127.0.0.1:28090 MPFEVER_NOLOCALCLIENT=1 MPFEVER_CLIENT2=1 MPFEVER_SCENARIO=migrate MPFever.exe --autotest <save>`
for the host, then two `MPFever.exe --autoclient 127.0.0.1:28090 <save> <name>` for the players, against `mpfever-relay --migration`.

## Keeping the save on the server (experimental)

Off by default. With `--checkpoint-dir DIR --checkpoint-owner-key KEY` the server keeps the **latest complete save** of the session on disk, so
the game can go on later even when nobody is connected and the last host is away. Add `--resume-without-host RECOVERYKEY` to let a second
player, who has that key, fetch the save and host from it.

- **Sending.** A host that has `server=` and `serverkey=KEY` in `mpfever_settings.txt` sends the session's autosave to the server after each
  one (every N minutes, see the host's autosave setting). The server checks the size and the SHA-256, writes the file next to the old one and
  replaces the old one only when the new one is complete: an interrupted or corrupt upload leaves the previous save in place. A host whose
  PC crashes loses only what happened since the last autosave. There is no extra send when the host leaves normally yet.
- **Resuming.** A player with `server=` and `serverkey=` (the owner key or the recovery key) gets a button, "Resume the server's saved game
  (experimental)". It fetches the save into the game's savegames as "MPFever relay save" (nothing hosts yet on the server: it connects as
  the host for that, then leaves). The player then clicks "Host a game" and loads that save as usual. The world is paused while nobody plays,
  and the new host needs the mods and DLCs the save uses.
- **Who may do what.** The server's password lets a player join, nothing more. Storing needs the owner key or the recovery key; reading needs
  one of them too, and reading with the recovery key works only with `--resume-without-host`. The recovery key is meant for a trusted
  friend who may also host, so it can store the save it goes on with. Keys are compared in constant time.
- **Limits.** One save (the latest), at most 1 GB, written to `--checkpoint-dir` only (two servers cannot share a directory: it is locked).
  The server does not read the save. Messages `tun_checkpoint`, `tun_checkpoint_bin` (host to server) and `tun_checkpoint_reply` (server to
  host) are the server's own and a player's are dropped. Tested by `mpfever-relay --selftest` (storage, protocol, and the launcher's side
  against the server); not yet tested with a real game.

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

- **Before a player is let in:** the Linux relay opts in to a 64 KB line limit and rejects binary messages. A connection that has not joined within
  15 s is cut; no more than 64 connections (`--max-connections`) are accepted at once; a `join` that cannot be read is refused (the Relay lets
  a player in when its admission check throws: this one refuses).
- **Passwords:** compared in constant time; 5 wrong ones from an address refuse that address for 5 minutes, even with the right one (the table
  of addresses is purged as entries expire and never holds more than 10 000).
- **Settings** are checked at start (`--port`, `--max-players`, `--max-connections`, `--grace`, `--migration-timeout`); `--max-connections 0`
  (no limit) and no `--password` are allowed but the server says so in its log.
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

## How long a large world takes to reach a player

Through the relay the host sends **one copy of the world per player, over its single connection to the server** (64 KB binary parts, one
thread per player), and the server forwards each copy to its player. The parallel Steam connections that a host listening itself can use
(`steam:` addresses) are not available, so the host's upload decides, not the server:

    time for every player to have the world  ~=  players x size / the host's upload speed      (if the server's link is as fast)

- **What the relay itself costs, measured.** Host and players on one PC (loopback), 300 MB sent in 64 KB parts through `mpfever-relay`
  (Windows, .NET 9, a 32-thread CPU; a throw-away benchmark that sends the world to each player from its own thread, as `SendSave` does):

  | Players | Time for all of them to receive 300 MB | Rate per player | Total through the relay |
  | --- | --- | --- | --- |
  | 1 | 0.2 s | about 1300 MB/s | about 1300 MB/s |
  | 2 | 0.8 s | about 370 MB/s | about 740 MB/s |
  | 4 | 1.4 s | about 210 MB/s | about 860 MB/s |

  So the server's own work (reading and forwarding the parts) is far above what an Internet connection gives: on a real connection the limit is
  the host's upload (and the server's and the player's links), never the relay's processing. These are the relay's limits on one machine, **not**
  a measure of a connection over the Internet, which depends on the host's, the server's and the player's links.
- **What to expect on a connection** (calculated from the formula above, for a host's upload speed; not measured):

  | Host upload | 300 MB world, 1 player | 300 MB world, 3 players | 300 MB world sent as differences (9 to 15 %, about 45 MB), 3 players |
  | --- | --- | --- | --- |
  | 20 Mbit/s (2.5 MB/s) | about 2 min | about 6 min | about 54 s |
  | 100 Mbit/s (12.5 MB/s) | about 24 s | about 72 s | about 11 s |
  | 500 Mbit/s (62.5 MB/s) | about 5 s | about 14 s | about 2 s |

  A player that already has the host's last game gets the differences only (`SaveDelta`, the host's choice, see `DeltaPeers`); a new player, or one
  that kept nothing, gets the whole world. The 9 to 15 % are the figures of the launcher's own measurements of `SaveDelta`, not of the relay.
  The same copy per player is sent when a host listens itself, except that the Steam connections can be added there; hosting through a server
  adds one hop and the server's bandwidth to the path, so choose a server whose link is not slower than the host's upload.

## Known limits

- A guest that drops is waited for (`--grace`, 60 s: its launcher goes on with its link, the host is not told); the **host** is not: when its
  connection drops a migration starts at once. A short cut of the host therefore costs a resynchronisation. Reconnecting the host with its
  link would need `RemoteRelay` to reconnect and the server to wait for it; left for later.
- **Steam invitations work through the server:** the host's invitation names the server's address (`+mpfever_connect host:port`), a new host
  after a takeover sets it again, and the address does not change when the host does. The friend's game joins that address; a server that has a
  password asks the friend for it on the Multiplayer page, as for any join (the password is not put in the invitation: it would be visible to
  every Steam friend of the host). Joining through the host's own Steam connection (`steam:`) and the router port mapping are off for a host that
  uses a server.
- A host that goes back to the main menu less than 2 minutes after its last load keeps its session (the existing rule of
  `OnMenuRequest("menu")`); closing the game ends it and triggers the takeover.
- Players that join while a migration is under way wait; the server announces them to the new host.
- The resynchronisation after a takeover is started by one launcher: `resyncing` is set in many places of the launcher without a lock, as it
  was before this change; the takeover checks it once, after the server has said the list of players is complete.
- Tested with three real games on one PC and with two PCs (a Windows host, a player on Linux/Proton) through a VPS, in both directions.

## Deploying

Download `mpfever-relay` and `mpfever-relay.sha256` from the [release assets](https://github.com/dkdknight/MPFever/releases/latest)
once attached. The Release build workflow produces both in the `mpfever-relay-linux-x64` artifact. The code-signing policy covers the Windows
release files. The Linux relay is unsigned. On Linux, check the download and make the binary executable from the directory containing both files.

```sh
sha256sum -c mpfever-relay.sha256
chmod +x mpfever-relay
```

To build from source, run `dotnet publish server-linux -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true`.
The server writes nothing to disk. An example systemd service follows.

```
[Service]
User=mpfever
EnvironmentFile=/etc/default/mpfever-relay      # MPFEVER_RELAY_OPTS=--port 28090 --password SECRET
ExecStart=/opt/mpfever-relay/mpfever-relay $MPFEVER_RELAY_OPTS
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Environment=DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp
```

Open the TCP port configured with `--port` in the firewall. Use launchers that speak the relay protocol number printed by
`mpfever-relay --help`.
