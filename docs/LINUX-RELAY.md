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

`mpfever-relay --migration`: when the host leaves, the next player in (the oldest) takes over instead of the session ending. No player has
to reconnect; they see the world stop and a resynchronisation (a loading screen) of about 25 s on the test save.

How it goes (tested with three real games on one PC, `launcher/MainForm.cs`: `OnTunHost`, `PromoteToHost`):

1. The server tells the successor (`tun_host { migrate = true, prev }`) and waits for it.
2. The successor's launcher stops acting as a client (its game and its connection stay), sets the host state it knows (session started, the
   speed the host last set, the company mode), writes `role=host` in `identity.txt` and connects to the same server again as the host.
   The server takes that second connection of the same name for the successor and announces the other players to it.
3. It tells every game that the old host and its own old name are gone (`peerleft`): a game that kept their last clock would wait for them
   for ever (the first runs of the test did exactly that).
4. It starts the host's own resynchronisation: it pauses everybody, saves its game, reloads it (as the host: the role is read when a game
   loads) and sends the save to the others, as for any resynchronisation.

Not covered: a successor that fails (the session ends), a second migration right after, players joining during a migration (they wait,
the server announces them to the new host), Steam invitations (off through a server). The test: `MPFEVER_SERVER=127.0.0.1:28090
MPFEVER_NOLOCALCLIENT=1 MPFEVER_CLIENT2=1 MPFEVER_SCENARIO=migrate MPFever.exe --autotest <save>` for the host, then two
`MPFever.exe --autoclient 127.0.0.1:28090 <save> <name>` for the players, against `mpfever-relay --migration`.

---

## Why a tunnel, and what it is not

- The host is more than a role: `MainForm` keeps the session's state (players, clocks, speed and pause, company mode, lobby, hashes,
  resync bookkeeping) and the host's game is the reference for the world and produces the savegames. A program with no game cannot be
  that, so the server does not try: it only carries the messages and decides who may come in and who hosts. The host's code stays in a
  player's launcher, unchanged.
- It is **not** a dedicated server that runs the world with nobody playing (`MPFever.exe --server` does that, with the game on a Windows
  machine). Running the game on Linux would need MPFever's native module (`winhttp.dll`, Windows only) on the Linux build of the game.
- The role of a game (`host` or `client`) is read when the game loads (`identity.txt`, `C.ROLE` in the mod), which is why a successor
  reloads its game as the host instead of switching on the fly.

## Known limits

- A player that drops is not waited for (the host's 60 s grace is not used through a server yet); Steam invitations and the router port
  mapping are off for a host that uses a server.
- A host that goes back to the main menu less than 2 minutes after its last load keeps its session (the existing rule of
  `OnMenuRequest("menu")`); closing the game ends it and triggers the takeover.
- Players that join while a migration is under way wait; the server announces them to the new host.
- Tested with three real games on one PC and with two PCs (a Windows host, a player on Linux/Proton) through a VPS, in both directions.
