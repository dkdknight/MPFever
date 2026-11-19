# MPFever relay (`mpfever-relay`): hosting without opening a port

The relay is a small program, for Linux or Windows, that runs **no game**. Players connect to it, the first player in hosts through it, and
everybody else joins the relay's address. Nobody has to open a port, and the address never changes.

Status: **works with real games** (`MPFever.exe --autotest`: one host and one client through the relay, also through a relay on a remote
Linux VPS; two PCs, a Windows host and a player on Linux/Proton, in both directions): `IN SYNC, desyncs 0, refused 0`. Host migration and
keeping the save on the relay are **experimental and off by default**.

Contents: [What it is](#what-it-is) · [Relay or dedicated server](#relay-or-dedicated-server) · [Quick start](#quick-start) ·
[Settings](#settings) · [Relay protocol](#relay-protocol) · [How it works](#how-it-works) · [Host migration](#host-migration-experimental) ·
[Keeping the save](#keeping-the-save-on-the-relay-experimental) · [Security](#security) · [Large worlds](#how-long-a-large-world-takes-to-reach-a-player) ·
[Known limits](#known-limits) · [Deploying](#deploying) (systemd, [Docker](#with-docker-optional), [Windows](#on-windows)) · [Tests](#tests)

## What it is

`relay/` holds `mpfever-relay`: a small program (.NET, no game, a few MB of RAM) that players connect to. **The first player in hosts
through it**: that player's MPFever and game are the host exactly as before (the host's code in the launcher is unchanged), but its
connection to the players goes through the relay instead of a port of its own. Everybody else joins the relay's address like any host.

You get:

- one stable address for everybody;
- nothing to open or forward on the host's router (useful behind CGNAT or a provider that shares one address between customers);
- a relay that can run on any cheap VPS, a Raspberry Pi or a spare PC, because it simulates nothing.

Optionally (both experimental, both off by default): the next player can **take over the hosting** when the host leaves
([migration](#host-migration-experimental)), and the relay can **keep the latest save** of the session so the game can go on later
([keeping the save](#keeping-the-save-on-the-relay-experimental)).

## Relay or dedicated server

They are two different things:

| | Dedicated server | Relay |
|---|---|---|
| Download | `MPFever-<version>-server.zip` | `Relay-MPFever-<version>-linux-x64.tar.gz`, `Relay-MPFever-<version>-win-x64.zip`, or the Docker image |
| Runs on | Windows, with Transport Fever 3 installed | Linux (x64, arm64 with Docker) or Windows, nothing else installed |
| Runs the game and the world | **Yes** (`MPFever.exe --server`) | **No**: the hosting player's PC and game run the world |
| The world goes on when nobody plays | Yes | No, unless migration or the kept save are used |
| Needs an open port | On the server | On the relay only, never on the host |
| Public server list, autosaves, restarts | Yes | No |

Use the dedicated server when a Windows PC can run the game all the time. Use the relay when the host has no port to open, when you want a
stable address, or when you want a cheap always-on meeting point on a small machine. The relay is not a Linux dedicated server; that one now exists
(experimental): the Windows game under Wine in a Docker container, see [LINUX-SERVER.md](LINUX-SERVER.md).

## Quick start

1. **Run the relay** on a machine the players can reach (a VPS, say), with a password:

   ```
   mpfever-relay --port 28090 --password SECRET --max-players 8
   ```

   Open its TCP port (28090 here) in the firewall. See [Deploying](#deploying) for the archives, systemd, Docker and Windows.

2. **The host** (the player who starts the session) adds two lines to `mpfever_settings.txt`, next to `MPFever.exe`:

   ```
   relay=my.relay.example:28090
   relaypw=SECRET
   ```

   or fills the launcher's **Relay** window (the "Relay..." button of the Settings window), which writes the same lines. The player
   then hosts from the game's Multiplayer page as usual.

3. **The other players** join `my.relay.example:28090` from the Multiplayer page and enter the password, as for any host.

Without `relay=` a player hosts directly, as before. The Windows dedicated server listens directly and keeps its own admission settings.

## Settings

### The relay's options

| Option | Default | Meaning |
|---|---|---|
| `--port N` | 28090 | TCP port to listen on (1 to 65535). |
| `--password SECRET`, `--password-file FILE` | none | Password to join, or to host (the file form reads it from a file). **Set one on a relay reachable from the Internet**: without it anybody may join or host, and the relay says so in its log. |
| `--listen ADDRESS` | every address | Listen on that address only: the address of a VPN (Tailscale, WireGuard) or of a LAN, so that nothing else can reach the relay. |
| `--max-players N` | 8 | Connected players at most, the host included (1 to 64). |
| `--name TEXT` | `MPFever Relay` | The name the relay gives itself. |
| `--max-connections N` | 64 | Connections accepted at once, let in or not (0: no limit, not for a public relay). |
| `--grace SECONDS` | 60 | How long a guest that drops is waited for (0: not waited for, max 3600). |
| `--migration` | off | **Experimental.** Let a player take over when the host leaves. |
| `--migration-timeout SECONDS` | 120 | How long a successor has to connect as the host before the next one is asked (5 to 3600). |
| `--checkpoint-dir DIR` | none | **Experimental.** Keep the latest complete save of the session in `DIR`. Needs `--checkpoint-owner-key`. |
| `--checkpoint-owner-key KEY`, `--checkpoint-owner-key-file FILE` | none | The key that lets the usual host store and read that save. It must differ from the password. |
| `--resume-without-host KEY`, `--resume-without-host-file FILE` | none | **Experimental.** A recovery key: a trusted player who shows it may read the save and host from it when nobody hosts. Needs `--checkpoint-dir`. It must differ from the owner key and from the password. |
| `--selftest` | | Run the relay's own checks (no game) and exit. |
| `-h`, `--help` | | Print the options and the relay protocol number. |

### Secrets from the environment

The password and the two keys can be given by the environment, so that they stay out of the command line (`ps`, `docker inspect`):

| Variable | Same as |
|---|---|
| `MPFEVER_RELAY_PASSWORD` | `--password` |
| `MPFEVER_RELAY_CHECKPOINT_OWNER_KEY` | `--checkpoint-owner-key` |
| `MPFEVER_RELAY_RESUME_WITHOUT_HOST` | `--resume-without-host` |

Each variable also exists with `_FILE` added (`MPFEVER_RELAY_PASSWORD_FILE=/run/secrets/relay_password`): the secret is read from that file (its last line break is dropped), as Docker and Compose secrets or a systemd credential give it. The same exists as options: `--password-file`, `--checkpoint-owner-key-file` and `--resume-without-host-file`. A secret file that cannot be read or is empty stops the relay, and the message never says what the file holds.

An option given on the command line wins over the variable, and the variable over its file.

### The launcher's side

In `mpfever_settings.txt` next to `MPFever.exe` (or in the **Relay** window of the Settings window, which writes these lines):

| Line | Meaning |
|---|---|
| `relay=host[:port]` | The relay this player hosts through. Without it the player hosts directly. (`MPFEVER_RELAY=host:port` does the same for a test run.) |
| `relaypw=SECRET` | The relay's password. (`MPFEVER_RELAYPW` gives it to a `--autoclient` test player.) |
| `relaykey=KEY` | The owner key or the recovery key, for [keeping the save](#keeping-the-save-on-the-relay-experimental). (`MPFEVER_RELAYKEY`.) |
| `takeover=0` | This PC is never asked to take over as the host when the host leaves ([host migration](#host-migration-experimental)). It is a box of the Settings window, in the expert settings (tick "Show the expert settings"), part "Relay": "Take over hosting if the host leaves", on by default. |
| `handover=0` | When this PC is the host and leaves, no player takes over: the session ends with it, even on a relay that allows migration. It is a box of the Settings window, in the expert settings, part "Relay": "Let a player take over if I leave", on by default. |

The first versions wrote `server=`, `serverpw=` and `serverkey=`: they are still read while the new names are not set, and the Relay window empties them when it saves.
The relay program's own variables (`MPFEVER_RELAY_PASSWORD` and the others, see [Settings](#secrets-from-the-environment)) are another thing: they are for `mpfever-relay`, not for the launcher.

Other things the launcher has for the relay: `MPFever.exe --fetch-save [name]` (fetch the kept save without a window) and
`MPFever.exe --relaysettings` (the Relay window alone, to look at it).

## Relay protocol

The relay protocol number is `1` (`RelayProtocol.Number`). The hosting and joining launchers send it as `rp` when they join. The relay
refuses a missing or different number with reason `relay`. Launchers and the relay can come from different MPFever releases if they speak the
same relay protocol. The host applies its usual MPFever version rule using the version in `tun_join`, and a guest still checks the host's
version in `welcome`.

Raise the relay protocol number when an incompatible change affects the message format, admission, reconnection, or a `tun_*` message.
An MPFever release by itself requires no change to the relay protocol number.

## How it works

The wire format is in the comment of `relay/SessionCore.cs`. In short: the host's launcher is one connection to the relay
(`RemoteRelay`, `launcher/RemoteRelay.cs`, the same surface as `Relay` through `IRelay`). The relay tells it which players came in and left
(`tun_join`, `tun_left`) and forwards what they send; the host's messages go back through it: to everybody, to everybody but one
(`!name:kind`, the host's `Broadcast(m, except)`) or to one player (`@name:kind`). A savegame sent to a player is a binary message and goes
through untouched. The relay checks the relay protocol, the password, the available places and the host role. The host applies its own
admission rules and can send a refusal through the relay.

The relay's own messages all have a kind that starts with `tun_`:

| Message | Direction | Fields | Purpose |
| --- | --- | --- | --- |
| `tun_join` | relay to host | `name`, `addr`, `v` | Tells the host a guest's name, address and MPFever version. The relay keeps the password. |
| `tun_left` | relay to host | `name` | Tells the host a guest has left. |
| `tun_host` | relay to a player | `you`, `epoch`, `migrate`, `prev`, `token` | Assigns the host role, or asks a player to take it over. |
| `tun_players` | relay to host | `n` | Marks the end of the guest announcements after a takeover. |
| `tun_kick` | host to relay | `name`, `payload` | Sends a host's refusal or kick to a guest and disconnects it. |
| `tun_checkpoint`, `tun_checkpoint_bin` | host to relay | see [Keeping the save](#keeping-the-save-on-the-relay-experimental) | Store or read the kept save. |
| `tun_checkpoint_reply` | relay to host | `id`, `status`, ... | The answer to a `tun_checkpoint*`. |

A player can never send a `tun_*` message, nor a routing prefix (`@`, `!`) in front of one: the relay drops them, and the host's launcher
ignores a player's `tun_*` too.

The relay waits for a dropped guest for up to `--grace` seconds. Steam tunnelling (`steam:` addresses) and router port mapping are off for a
host that uses a relay.

## Host migration (experimental)

Host migration is experimental and off by default. Enable it with `mpfever-relay --migration`. When a successor takes over, the remaining
players stay connected and see a resynchronisation. The loading screen took about 25 s on the test save.

How it goes (`relay/Hosting.cs`; launcher: `OnTunHost`, `PromoteToHost` in `launcher/MainForm.cs`):

1. The relay only considers players that advertised takeover support in their join (`mig`; the launcher says it unless `takeover=0`). A host that
   asked for the session to end with it (`nomig` in its join, `handover=0`) is not replaced: the session ends when it leaves.
2. The host's connection ends. The relay asks the oldest player that can take over (`tun_host { migrate, prev, epoch, token }`). The token
   is random (128 bits), made for this attempt and this player, and valid once.
3. The successor's launcher stops acting as a client (its game and its connection stay), sets the host state it knows (session started,
   the speed the host last set, the company mode, the rules and the chat the host had sent it), writes `role=host` in `identity.txt` and connects to the same relay again as the host,
   showing the token. A connection that only has the successor's name is refused, so is a second use of the token.
4. The relay makes it the host, announces every other player to it (`tun_join`) and then says the list is complete (`tun_players`).
5. The launcher tells every game that the old host and its own old name are gone (`peerleft`): a game that kept their last clock would wait
   for them for ever. It then starts the host's own resynchronisation: it pauses everybody, saves its game, reloads it (as the host: the role
   is read when a game loads) and sends the save to the others, as for any resynchronisation.

| State | After a takeover | Code |
| --- | --- | --- |
| World | The successor saves and reloads its current world as host and sends that save to the other players. This includes companies present in the save. | `PromoteToHost`, `Resync` |
| Running state, speed, company mode | The successor marks the session started, uses the last positive speed it received (default 1), and uses the received shared or separate mode when known. Scheduled pauses and the old host's resync state are reset. | `hostSessionSpeed`, `hostCompanyMode`, `pauseAt`, `SessionPayload` |
| Connected players and Steam invitations | The relay re-announces the guests. The successor refreshes Steam presence with the same relay address when Steam is enabled for the menu game. | `tun_join`, `tun_players`, `InviteConnect` |
| Lobby rules and computer companies | **Kept.** The host sends its rules to every player as they change (`hoststate`, only when it hosts through a relay): the start money, the bankruptcy delay, the sharing rules, the auction, the computer companies. The successor goes on with them instead of its own settings, so a company that had six months before bankruptcy still has six. | `HostRules`, `HostState.cs` |
| Game options of the session | **Kept.** The session's game options (the ones the host chose for everybody) go in the same message. The successor's own launcher settings are not applied to the session: they stay its own (smooth pacing, slow PC mode, detailed logs...). | `GameOptions`, `HostRules` |
| Autosave interval and chat | **Kept.** The successor autosaves at the interval the host had (the minutes the host used) and keeps the last 50 chat messages and their numbers, so a player that joins later gets the chat so far and nobody skips a message. The old host's autosave **files** stay on its PC. | `HostAutosaveMinutes`, `KeepChat`, `InheritFromHost` |
| Public game, approvals and bans | **Kept** (the options of the public games come with the session options). The name of the public game is kept. The players the old host had let in are not asked again by a host that approves every arrival (the relay announces each of them to the new host as an arrival). The **names** the old host had banned (no address, no Steam id) are refused by the new host for this session: its window lists them with the day "session", the host can Unban them, and they are never written to its own `mpfever_bans.txt`. | `PublicGate.InheritFromHost`, `HostRules` |
| Reports being collected | **Not kept, nothing to keep.** A report that was being gathered at the change (25 s without news, 2 minutes at most) ends by itself without the old host's part; ask again: the new host answers like any host. An arrival that was waiting for the old host's answer is refused when its wait ends and joins again. | `ReportShare.cs`, `PublicGames.cs` |
| Mods and DLCs | The save carries its own world content. The successor uses the information it built locally as a guest and does not receive the old host's mod/DLC bookkeeping. | `lobbyMods`, `lobbyModsKnown`, `lastHostDlcs`, `SessionDlcs` |

**What the players see.** The new host's launcher says "Host change: the session's rules, options, computer companies and chat are kept." and its log
lists the values it kept (rules, options, autosave interval, chat, players let in, names banned). Nothing has to be set up: the rules travel with the session. Only the host's own PC sends them, and only through a
relay, so a host that listens itself, and a dedicated server, send and change nothing. A value that is not valid is ignored (the successor's own
is used then) and a player cannot send these messages (they are the host's only, like the savegame).

**What the players read.** When the new host is there, its launcher puts a line in the game's chat (the place of MPFever's other notices): who left, who
hosts now, that the rules are kept and that the game is about to resynchronise. A player that joins later finds it with the chat so far.

**Choosing who may take over.** Two boxes in the launcher's Settings window, both on by default, so nothing has to be set up. They are in the expert settings (tick **"Show the expert settings"**, part **"Relay"**):

- **"Take over hosting if the host leaves"** (`takeover=0` in `mpfever_settings.txt`): says whether *this PC* may be asked when somebody else
  hosts. Untick it on a slow PC or a weak connection: the relay then asks the next player.
- **"Let a player take over if I leave"** (`handover=0`): for *this PC as the host*. Unticked, the session ends with it: the host's launcher says
  so in its join (`nomig`) and the relay disconnects the players instead of asking one. A relay older than this option ignores the field and
  migrates as usual.

If the successor does not connect within `--migration-timeout` seconds or leaves, it is not asked again for this migration and the next
player is; when nobody is left, the session ends and every player is disconnected. If the new host's connection drops later, a new migration
starts.

Each transition is decided under one lock and only if the state is the one the caller saw (`Migrate(prev, fromEpoch)`): a late timer, or two
events at once, cannot ask a second player while a host is there nor end a healthy session. This was a real race, reproduced with a test seam
before it was fixed.

**What the relay does not know:** whether the new host has finished its resynchronisation. It is deliberately not a phase of the relay: a host
that is connected but slow cannot be told from one that is busy loading a save of 150 MB, so a "resynchronising" timeout would replace a
working host. The failure that can be told, a connection that drops, already starts the next migration. Confirming the resynchronisation (a
message from the new host when it is done, and a policy for a host that never says it) would need a new message in the launcher and a decision
about how long a resynchronisation may take; left for a later change.

On the launcher side, if `tun_players` does not arrive within 15 s (a relay older than this message), the takeover goes on, as the first
version did: a player announced later is a new arrival for the host's code, which sends it the host's game by itself.

Tested with real games on the 0.8.17 launcher and mod, through a relay on a remote VPS with a password (`--migration`): the host left, the
relay asked the oldest player, which became the host; both players ended `sync=ok`, `desyncs=0`, with one resynchronisation.

The test: `MPFEVER_RELAY=127.0.0.1:28090 MPFEVER_NOLOCALCLIENT=1 MPFEVER_CLIENT2=1 MPFEVER_SCENARIO=migrate MPFever.exe --autotest <save>`
for the host, then two `MPFever.exe --autoclient 127.0.0.1:28090 <save> <name>` for the players, against `mpfever-relay --migration`.

## Keeping the save on the relay (experimental)

Off by default. With `--checkpoint-dir DIR --checkpoint-owner-key KEY` the relay keeps the **latest complete save** of the session on disk, so
the game can go on later even when nobody is connected and the last host is away. Add `--resume-without-host RECOVERYKEY` to let a second
player, who has that key, fetch the save and host from it.

This is not the dedicated server's "the world keeps running": the world is **paused** while nobody plays, and a player has to host it again
from the kept save.

- **Sending.** A host that has `relay=` and `relaykey=KEY` in `mpfever_settings.txt` sends the session's autosave to the relay after each
  one (every N minutes, see the host's autosave setting). The relay checks the size and the SHA-256, writes the file next to the old one and
  replaces the old one only when the new one is complete: an interrupted or corrupt upload leaves the previous save in place. When the host
  closes its launcher it makes one last autosave and sends it (40 s at most), so a normal departure loses nothing. A host whose PC crashes
  loses only what happened since the last autosave.
- **Resuming.** A player with `relay=` and `relaykey=` (the owner key or the recovery key) opens the **Relay** window (Settings,
  "Relay...") and clicks "Resume the relay's saved game" (it saves the three fields first). The launcher fetches the save into the
  game's savegames as "MPFever relay save" (`MPFever.exe --fetch-save` does the same without a window); as nothing hosts yet on the relay, it
  connects as the host for that, then leaves. The player then clicks "Host a game" and loads that save as usual. The new host needs the mods
  and DLCs the save uses.
- **Who may do what.** The relay's password lets a player join, nothing more. Storing needs the owner key or the recovery key; reading needs
  one of them too, and reading with the recovery key works only with `--resume-without-host`. The recovery key is meant for a trusted friend
  who may also host, so it can store the save it goes on with. Keys are compared in constant time.
- **Limits.** One save (the latest), at most 1 GB, written to `--checkpoint-dir` only (two relays cannot share a directory: it is locked). The
  relay does not read the save. Without `--checkpoint-dir` the relay keeps nothing and answers `empty` at once, and a launcher with a
  `relaykey=` logs that the relay keeps no save.
- **The messages.** `tun_checkpoint` (a table with `id`, `op` and `key`) and `tun_checkpoint_bin` (a binary part) go from the host to
  the relay; `tun_checkpoint_reply` comes back. The operations are `begin` (size and SHA-256), `commit`, `open`, `read` (an offset) and
  `loaded`. Parts are 1 MB. A reply `status` is one of `upload`, `part`, `saved`, `download`, `ready`, `empty`, `denied`, `invalid`, `changed`
  or `io`. A player's messages of these kinds are dropped like any `tun_*`.
- **Tested** by `mpfever-relay --selftest` (storage, protocol, and the launcher's side against the relay) and with real games on one PC: the
  host's autosave and its last save at close reach the relay byte for byte, the relay keeps them across a restart, `MPFever.exe --fetch-save`
  gets them back (also with the recovery key), and a game hosted from the fetched save and joined by a second game stayed in sync (`IN SYNC`,
  0 desyncs, 0 refused; a game hosted from the save fetched with the recovery key ended `SYNC ~` with a slight drift on money, which the same
  save gives with no relay at all), on the 0.8.17 launcher and mod, through a relay on a remote VPS with a password. The button of the Relay
  window was clicked in the running launcher and fetched the save, byte for byte. A host that closes its launcher during a resynchronisation
  sends nothing (the relay keeps what it had, same size and date). **Not
  tested** between two PCs.

### Setting up the keys

1. Make one key per role, long and random (they are typed in a file or a window, not remembered), for instance `openssl rand -hex 16` on
   Linux or `[guid]::NewGuid().ToString('N')` in PowerShell. The owner key is for the player who usually hosts; the recovery key is for a
   trusted friend who may resume the game when the owner is away. Do not reuse the relay's password.
2. Start the relay with a directory for the save, which the relay's user must be able to write (with the systemd unit of
   [Deploying](#deploying), add `ReadWritePaths=/var/lib/mpfever-relay`, and create that directory owned by that user):

   ```
   mpfever-relay --port 28090 --password SECRET --checkpoint-dir /var/lib/mpfever-relay \
                 --checkpoint-owner-key OWNERKEY --resume-without-host RECOVERYKEY
   ```

3. Each player enters the relay's address, its password and its key in the launcher's **Relay** window, or as `relay=`, `relaypw=` and
   `relaykey=` in `mpfever_settings.txt`. The window also has the "Resume the relay's saved game" button.

## Why a tunnel, and what it is not

- The host is more than a role: `MainForm` keeps the session's state (players, clocks, speed and pause, company mode, lobby, hashes, resync
  bookkeeping) and the host's game is the reference for the world and produces the savegames. A program with no game cannot be that, so the
  relay does not try: it only carries the messages and decides who may come in and who hosts. The host's code stays in a player's launcher,
  unchanged.
- It is **not** a dedicated server that runs the world with nobody playing (`MPFever.exe --server` does that, with the game on a Windows
  machine). Running the game on Linux would need MPFever's native module (`winhttp.dll`, Windows only) on the Linux build of the game.
- The role of a game (`host` or `client`) is read when the game loads (`identity.txt`, `C.ROLE` in the mod), which is why a successor reloads
  its game as the host instead of switching on the fly.

## Security

The relay may be reachable from the Internet, so what a connection can do before it is let in, and what a player can do to the others, is
limited on purpose (each point has a test in `mpfever-relay --selftest`):

- **Before a player is let in:** the relay opts in to a 64 KB line limit and rejects binary messages. A connection that has not joined within
  15 s is cut; no more than 64 connections (`--max-connections`) are accepted at once; a `join` that cannot be read is refused (the Relay lets
  a player in when its admission check throws: this one refuses).
- **Passwords and keys:** compared in constant time (after a SHA-256 of both sides, so the length does not show); 5 wrong ones from an address
  refuse that address for 5 minutes, even with the right one (the table of addresses is purged as entries expire and never holds more than
  10 000). The wrong keys of the kept save count in that same table, so that a key cannot be guessed once the password is known.
- **Settings** are checked at start (`--port`, `--max-players`, `--max-connections`, `--grace`, `--migration-timeout`); `--max-connections 0`
  (no limit) and no `--password` are allowed but the relay says so in its log. A key equal to the password (every player knows it) or to the
  other key is refused; a password shorter than 8 characters or a key shorter than 16 is said in the log (`openssl rand -hex 16` makes one).
- **The relay's own messages** (kinds that start with `tun_`) cannot be sent by a player: they are dropped, and so are the routing prefixes
  `@name:` and `!name:` in front of one (otherwise `@Victim#3:tun_host` would be delivered to Victim as a real `tun_host`). Otherwise a player
  could make the host forget another player (`tun_left`), believe in a player that is not there (`tun_join`) or give the host role away
  (`tun_host`). The host's launcher ignores a player's `tun_*` as well.
- **The host role:** only the first player that asks, or the successor with its one-time token, can be the host.
- **The text parser** (`LuaLit`, shared with the launcher) no longer loops on text that starts nothing known and no longer follows nested
  tables without a limit (a line of braces overflowed the stack, which cannot be caught). This also protects a launcher that hosts itself.
- A binary message announced and never sent no longer reserves its size in memory on the relay (past 1 MB it is kept as it arrives; the
  launcher's own reader is unchanged unless the relay opts in).
- **The kept save:** only a host connection can store or read it, and only with the owner key or the recovery key (constant-time compare); one
  upload at a time, size and SHA-256 checked, the previous save replaced only by a complete one; the directory is locked against a second
  relay; every path is fixed inside `--checkpoint-dir`. The launcher checks the SHA-256 of what it fetches and writes it under a fixed name.
  On Linux the directory is created with mode 700 and its files with 600 (the relay says so in its log when an existing directory is readable by
  other accounts): the save is a whole world.
- **Secrets:** the password and the keys can come from the environment or from files instead of the command line (`ps` and `docker inspect` show
  nothing). They are never written to the relay's log. In the launcher the password and the key are written in `mpfever_settings.txt`
  protected by Windows (DPAPI, this Windows account on this PC: `relaypw=dpapi:...`), so a copy of the file does not give them away; a value
  typed by hand is read as it is, and one that cannot be opened (another PC or account) is empty again: the player enters it in the Relay window.
  The launcher leaves `relaypw=`, `relaykey=` and the same words in the old names or in environment variables out of the reports it makes.
  `--listen` keeps the relay off every other network: with the address of a VPN, only its members can even connect.

**Not done: encryption.** The protocol is plain TCP, as it always was: the password, the keys and the session are readable on the way. Adding
TLS means a change on every player's side (the launcher's `Client`) and a certificate, which is a compatibility decision for the maintainer.
Until then: use a password, prefer a private network (Tailscale, WireGuard) between the players and the relay (with `--listen` on its address, the
relay is not on the Internet at all), or put a TLS tunnel (stunnel, `ssh -L`) in front: through a tunnel on the same machine every player looks
like the same address to the relay, so the wrong-password count then applies to all of them together. The relay's `--password` is a shared secret for a group of friends, not an account system. The keys of the kept save travel
the same way as the password.

## How long a large world takes to reach a player

Through the relay the host sends **one copy of the world per player, over its single connection to the relay** (64 KB binary parts, one
thread per player), and the relay forwards each copy to its player. The parallel Steam connections that a host listening itself can use
(`steam:` addresses) are not available, so the host's upload decides, not the relay:

    time for every player to have the world  ~=  players x size / the host's upload speed      (if the relay's link is as fast)

- **What the relay itself costs, measured.** Host and players on one PC (loopback), 300 MB sent in 64 KB parts through `mpfever-relay`
  (Windows, .NET 9, a 32-thread CPU; a throw-away benchmark that sends the world to each player from its own thread, as `SendSave` does):

  | Players | Time for all of them to receive 300 MB | Rate per player | Total through the relay |
  | --- | --- | --- | --- |
  | 1 | 0.2 s | about 1300 MB/s | about 1300 MB/s |
  | 2 | 0.8 s | about 370 MB/s | about 740 MB/s |
  | 4 | 1.4 s | about 210 MB/s | about 860 MB/s |

  So the relay's own work (reading and forwarding the parts) is far above what an Internet connection gives: on a real connection the limit is
  the host's upload (and the relay's and the player's links), never the relay's processing. These are the relay's limits on one machine, **not**
  a measure of a connection over the Internet, which depends on the host's, the relay's and the player's links.
- **What to expect on a connection** (calculated from the formula above, for a host's upload speed; not measured):

  | Host upload | 300 MB world, 1 player | 300 MB world, 3 players | 300 MB world sent as differences (9 to 15 %, about 45 MB), 3 players |
  | --- | --- | --- | --- |
  | 20 Mbit/s (2.5 MB/s) | about 2 min | about 6 min | about 54 s |
  | 100 Mbit/s (12.5 MB/s) | about 24 s | about 72 s | about 11 s |
  | 500 Mbit/s (62.5 MB/s) | about 5 s | about 14 s | about 2 s |

  A player that already has the host's last game gets the differences only (`SaveDelta`, the host's choice, see `DeltaPeers`); a new player, or one
  that kept nothing, gets the whole world. The 9 to 15 % are the figures of the launcher's own measurements of `SaveDelta`, not of the relay.
  The same copy per player is sent when a host listens itself, except that the Steam connections can be added there; hosting through a relay
  adds one hop and the relay's bandwidth to the path, so choose a relay whose link is not slower than the host's upload.

## Known limits

- A guest that drops is waited for (`--grace`, 60 s: its launcher goes on with its link, the host is not told); the **host** is not: when its
  connection drops a migration starts at once. A short cut of the host therefore costs a resynchronisation. Reconnecting the host with its
  link would need `RemoteRelay` to reconnect and the relay to wait for it; left for later.
- **Steam invitations work through the relay:** the host's invitation names the relay's address (`+mpfever_connect host:port`), a new host
  after a takeover sets it again, and the address does not change when the host does. The friend's game joins that address; a relay that has a
  password asks the friend for it on the Multiplayer page, as for any join (the password is not put in the invitation: it would be visible to
  every Steam friend of the host). Joining through the host's own Steam connection (`steam:`) and the router port mapping are off for a host that
  uses a relay.
- A host that goes back to the main menu less than 2 minutes after its last load keeps its session (the existing rule of
  `OnMenuRequest("menu")`); closing the game ends it and triggers the takeover.
- Players that join while a migration is under way wait; the relay announces them to the new host.
- The resynchronisation after a takeover is started by one launcher: `resyncing` is set in many places of the launcher without a lock, as it
  was before this change; the takeover checks it once, after the relay has said the list of players is complete.
- No public list: players need the relay's address. The dedicated server is the one that lists itself in the **Public servers** tab.
- Not tested between two PCs: the kept save. The arm64 image builds and passes `--selftest` (under emulation); it has not run on an ARM machine.
- A player that joins a session already running, in the autotest (a third game started about 25 s after the second), ends `DESYNCHRONISED`;
  the same test without a relay does too, so it is not the relay's doing.

## Deploying

Download `Relay-MPFever-<version>-linux-x64.tar.gz` from the [release assets](https://github.com/dkdknight/MPFever/releases/latest) once
attached (the Release build workflow produces it, with its SHA-256 on the run's page). The archive holds a folder `MPFever-Relay` with the
`mpfever-relay` program and this guide. The code-signing policy covers the Windows release files of the game; the relay programs (Linux and
Windows) are unsigned. On Linux, check the download against that SHA-256 and unpack it:

```sh
sha256sum Relay-MPFever-<version>-linux-x64.tar.gz
tar -xzf Relay-MPFever-<version>-linux-x64.tar.gz
```

To build from source, run `dotnet publish relay -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true`.
The relay writes nothing to disk, unless `--checkpoint-dir` is set ("Keeping the save on the relay"): then it also needs write access to
that directory (with the unit below, add `ReadWritePaths=/var/lib/mpfever-relay`). An example systemd service follows.

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

### With Docker (optional)

Not needed: the program above runs as it is. If you prefer a container (a VPS that only has Docker, an ARM machine such as a Raspberry Pi), the
repository has a `relay/Dockerfile` and a `relay/compose.yaml`. The image holds only the relay (self-contained, no shell, not
root, about 40 MB); it is not the dedicated server and runs no game. It is a Linux image (x64, or arm64 with `buildx`): on Windows, Docker
Desktop runs it in a Linux virtual machine, or use the Windows archive below. There is no Windows image. From the root of the repository:

```sh
docker build -f relay/Dockerfile -t mpfever-relay .
docker run -d --name mpfever-relay --restart unless-stopped -p 28090:28090 \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -e MPFEVER_RELAY_PASSWORD=SECRET mpfever-relay --max-players 6
```

or, with Compose (it stops if the password is not set):

```sh
MPFEVER_RELAY_PASSWORD=SECRET docker compose -f relay/compose.yaml up -d --build
```

**A published image.** The Release build workflow can also push the image to the GitHub container registry, only when "docker" is ticked at
its start (off by default): `ghcr.io/<owner>/mpfever-relay-docker`, tagged with the version and `latest`, for x64 and arm64, self-tested once pushed.
When the project has published it, nothing has to be built: `docker pull ghcr.io/<owner>/mpfever-relay-docker:<version>`, then the same `docker run`
with that name instead of `mpfever-relay`. The package's visibility is set on its page on GitHub (on the test fork it came out public, like the repository, and could be pulled without signing in).

The password and the keys come from the environment (see [Settings](#secrets-from-the-environment)). The other options are the arguments of
the container (`mpfever-relay --help` lists them). To keep the session's save, mount a volume on `/data` and add `--checkpoint-dir /data` (the
example in `compose.yaml` shows it). For arm64: `docker buildx build --platform linux/arm64 ...`. Open the TCP port in the firewall as above;
Docker publishes it itself, past the host's `ufw`, so check what is really reachable.

What is tested: the image builds, `--selftest` passes inside it (read-only, no capabilities), and it starts with the password from the
environment and a mounted save directory. A host and a client played through the container (read-only, no capabilities, not root) and ended
`SYNCHRONE`, 0 desyncs; the kept save was written to the volume and, after a restart of the container, `--fetch-save` returned it byte for
byte. The arm64 image builds and passes `--selftest` under emulation. Not tested: an ARM machine, and Compose beyond its configuration.

### On Windows

The relay is the same program: the Release build workflow also produces `Relay-MPFever-<version>-win-x64.zip`, a folder `MPFever-Relay` with
`mpfever-relay.exe` and this guide (self-contained, nothing to install; unsigned, so SmartScreen may ask for confirmation). To build it
from source, run `dotnet publish relay -c Release -r win-x64 --self-contained -p:PublishSingleFile=true`.

Tested: the archive's `mpfever-relay.exe` passes `--selftest`, and a host and a client played through it on one PC (with `--migration` and
the kept save): `SYNCHRONE`, 0 desyncs; after a restart of the relay, `--fetch-save` returned the kept save byte for byte.

```powershell
# check the download against the SHA-256 given with the release, then unpack it
(Get-FileHash Relay-MPFever-<version>-win-x64.zip -Algorithm SHA256).Hash
Expand-Archive Relay-MPFever-<version>-win-x64.zip -DestinationPath C:\
cd C:\MPFever-Relay

# run it (options are the same as on Linux)
.\mpfever-relay.exe --port 28090 --password SECRET
```

To start it with the PC, create a scheduled task that runs it at start-up under an account of its own (Task Scheduler, "Run whether user is
logged on or not", with the same arguments). Allow it through the Windows firewall for the port of `--port`:

```powershell
New-NetFirewallRule -DisplayName "MPFever relay" -Direction Inbound -Protocol TCP -LocalPort 28090 -Action Allow -Program "C:\MPFever-Relay\mpfever-relay.exe"
```

This is not the Windows dedicated server (`MPFever.exe --server`), which runs the game itself so the world goes on without a host: the relay only
forwards what the hosting player's game does. Use the dedicated server when a Windows PC can run the game all the time.

## Tests

- `mpfever-relay --selftest`: admission, routing to and from the host, savegame-sized binary messages, kick, the host's `RemoteRelay` against
  the relay, the migration, the kept save (storage, protocol, the launcher's side) and the secrets from the environment.
- `MPFever.exe --selftest` (unchanged, passes).
- In CI (`.github/workflows/ci.yml`): `linux-relay`, `windows-relay` and `docker-relay` build the relay, run its self-test (the Docker one
  inside the container, read-only and without capabilities) and keep the binary.
- With a game: `set MPFEVER_RELAY=127.0.0.1:28090` and `MPFever.exe --autotest <savegame>` with the relay running (or reached through
  `ssh -L 28090:127.0.0.1:28090 vps`): two real games build roads and upgrade streets through the relay; the verdict is `IN SYNC`.
