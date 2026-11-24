# Madeira Dock

Madeira Dock is a small headless host for **Valve's own Steam client**. It lets
[Madeira](https://github.com/willfaust/Madeira) (Windows games on iPhone and iPad, through Wine)
start a game the signed-in user owns, with Steam's real sign-in, Steam's real licence check and the
game's original DRM, without running Steam's desktop interface.

It is one Windows program, `dockhost.exe`, about 2,000 lines of C.

**Licence:** GPL-3.0-or-later with the Madeira Converter Exception, Copyright 2026 125hz
(`LICENSE`, `COPYING`, `LICENSE-EXCEPTION.md`). Not affiliated with or endorsed by Valve.

## In one paragraph

On a PC, `steam.exe` loads Valve's client library (`steamclient64.dll`), signs in, checks the
account's licences and starts games; a second set of processes draws the window and the store.
Dock does the first half only. It loads the same unmodified Valve library, hands it the user's
own Steam sign-in, asks it whether the account owns the game, and asks it to start the game with
Valve's own launch function. Every decision (is this sign-in valid, does this account own this
game, may it start now) is made by Valve's library talking to Valve's servers. Dock has no code
that answers any of those questions itself, and no path that starts a game when Valve's answer is
no.

## Why it exists

Steam's desktop interface (the client window and its Chromium web helper) needs more memory than
a phone can spare next to a running game. The part of Steam a game actually needs while it runs is
the client library: it confirms the licence, serves the Steamworks API the game calls, and
handles the DRM wrapper or per-user executable the game ships with. Dock hosts that part and
nothing else.

## What it does, in order

1. **Refuses to run beside another Steam.** If `steam.exe`, `steamwebhelper.exe` or another host
   is running, or another Dock holds its mutex, it stops (`main.c`, `no_other_client`).
2. **Identifies Valve's client file.** It opens `steamclient64.dll` in the Steam folder with
   writes and deletes denied, checks it is a 64-bit DLL and computes its SHA-256. Only builds
   whose hash is in `src/client_layout.c` are driven; any other build stops here with result 30
   (see "Supported client builds").
3. **Loads it as Windows would for Steam.** `LoadLibraryExW` from the Steam folder with the
   search path limited to that folder and `system32`. Nothing is patched, hooked or replaced.
4. **Creates a Steam user and pipe** with the library's exported functions
   (`Steam_CreateGlobalUser`, `Steam_BGetCallback`, ...), and obtains the client engine with
   `CreateInterface`.
5. **Signs in with the user's own sign-in.** Madeira's sign-in screen (QR code, or password with
   Steam Guard) is answered by Steam's own authentication service; the resulting token is kept in
   the iOS Keychain. For a launch, Madeira passes it to Dock once (see "Credentials"), and Dock
   gives it to the client's own `SetLoginToken` and calls the client's own `LogOn`. Valve's
   servers accept or reject it.
6. **Waits until Valve's client says it is signed in and online** (`Steam_BLoggedOn`,
   `BLoggedOn` and `BConnected` must all hold). With no network (`MADEIRA_DOCK_OFFLINE=1`), or
   when the connection fails and the client allows it, Dock instead asks the client for its own
   offline logon (`CanLogonOffline`, `LogOnOffline`; `docs/OFFLINE.md`); the steps below are the
   same, answered by the client from its own cache.
7. **Asks Valve's client whether the account owns the game.** The requested App ID must be in
   the client's own list of the account's subscribed apps (`GetSubscribedApps`). If it is not
   there within 90 seconds, Dock stops with result 34 or 35 and nothing is started.
8. **Checks it is the game the user asked for.** The install folder Valve's client resolves for
   the App ID must equal the folder Madeira expects.
9. **If the game ships per-user executables (CEG),** asks the client to prepare them
   (`RequestCustomBinaries`), as desktop Steam does before a launch. Valve's client requests
   them from Valve with this account's licence. A failure stops the launch (result 49).
10. **Announces itself as the running Steam client**, the way `steam.exe` does: its process id
    and the signed-in account id in Steam's `ActiveProcess` registry values. Games find the
    client through these. The previous values are restored on exit.
11. **Asks Valve's client to start the game**: `IClientAppManager::LaunchApp` with the original
    launch entry key selected by Madeira, including nonzero and sparse keys. Valve's client
    applies its own launch checks and returns its own result; a
    refusal (for example "no licence", "another session is playing", "update required") is
    reported as Valve gave it, and the game is not started.
12. **Stays up while the game runs**, pumping the client's callbacks, so the game's
    `steam_api64.dll` talks to a live, signed-in client exactly as it would on a PC. The game,
    its Steamworks calls and its DRM (SteamStub wrapper, CEG, the game's own checks) run
    unmodified.
13. **Holds the session while the game's own programs are still starting or showing something.**
    Valve's client stops reporting the game as running when the program it started exits, which
    some games' launchers do while they restart themselves or before they start the game. Dock
    follows the game's process tree while it runs (`src/hold.c`: the host's descendants, Windows'
    own images and their children excepted, plus any image named in `MADEIRA_DOCK_KEEP_ALIVE`),
    only looking: process snapshots, image paths, start times and visible windows. After the
    report ends, the session is held while a member still shows a window or is younger than 60 s
    (`launch-keep-alive`, then `launch-keep-alive-held=<seconds>` at the end); a launcher left in
    the background after the game ends holds nothing. `MADEIRA_DOCK_KEEP_ALIVE=0` ends the
    session 3 s after the report as before.
14. **Shuts the client down** when the game has ended, with the public `SteamClient021` shutdown
    call, releases the user and pipe, and exits with a numeric result.

## What it does not do

- **No emulation.** There is no replacement `steam_api`, `steamclient` or Steamworks
  implementation here. The game loads Valve's files.
- **No DRM removal or bypass.** Dock does not unwrap, patch or modify any executable, does not
  create or alter CEG binaries, and does not forge tickets, licences or ownership.
- **No start without Valve's yes.** Dock keeps no cached "owned" flag and has no fallback of its
  own: a failed sign-in, a missing licence or a refused launch ends the run. An offline start is
  Valve's client's own offline logon (`docs/OFFLINE.md`), which the client allows only with the
  offline logon ticket Steam issued to it during an earlier online logon; it then answers the
  licence question from its own cache, as desktop Steam's Offline Mode does.
- **No game installs.** Dock starts games that are already installed in the user's prefix with
  their Steam app manifest. Dock itself downloads nothing; Valve's client may update a game's
  content before starting it, as it does on a PC.
- **No Valve files in this repository or in Madeira's app bundle.** Madeira downloads Valve's
  client packages from Valve's own update servers on the user's device and verifies them against
  pinned sizes and SHA-256 sums.
- **No game-specific code.** There are no game names, App IDs or per-game fixes in the source.
- **No account data in logs.** The report contains stage names and numbers only: no token,
  account name, SteamID, path, App ID list or callback payload.
- **No interaction with anti-cheat.** Dock has no code that touches VAC or any third-party
  anti-cheat.

## What decides whether a game starts

| Question | Who answers | How Dock asks |
|---|---|---|
| Is this sign-in valid? | Valve's servers, through Valve's client | `SetLoginToken`, `LogOn`, then `BLoggedOn` and `BConnected` |
| Offline: may this account sign in without a connection? | Valve's client, from the offline logon ticket Steam issued to it | `CanLogonOffline`, then `LogOnOffline` (`docs/OFFLINE.md`) |
| Does this account own the game? | Valve's client, from the account's licences | `GetSubscribedApps` (and `BIsSubscribedApp`, reported but never sufficient alone) |
| May it start now? | Valve's client | `LaunchApp` and its asynchronous result |
| Is the copy genuine and licensed to this user? | The game's own DRM, against the running client | not asked by Dock: it happens between the game and Valve's client |

Dock's own checks are all additional refusals (wrong client build, wrong install folder,
malformed sign-in transfer, another Steam already running). None of them can turn a "no" from
Valve into a start.

## Credentials

- Dock never sees a password. Madeira's sign-in produces a Steam refresh token for the user's
  own account; Madeira keeps it in the iOS Keychain.
- For one launch, Madeira writes a **one-use transfer file** in its protected app storage and
  passes only the file's path to Dock (`MADEIRA_DOCK_AUTH_FILE`). The token is never put on a
  command line or in an environment variable.
- Dock opens the file exclusively with delete-on-close, so it is gone before sign-in starts;
  refuses directories, links and anything outside the size bounds; parses it; hands the token to
  the client's `SetLoginToken`; and overwrites its own copies. Madeira also deletes any
  unconsumed file after a failed launch, at sign-out and at the next app start.
- The transfer names one App ID. A transfer for another App ID is rejected (result 37).
- A missing, locked or malformed transfer fails the run. It never falls back to another login.
- Format `MDOCK001`: 8 magic bytes; little-endian u64 SteamID, u32 App ID, u16 account length,
  u16 token length; then the account name (1 to 64 bytes) and the token (1 to 8192 bytes); no
  trailing data. It carries a credential, never a claim of ownership.
- Valve's client may keep its own session cache inside the user's Wine prefix, as it does on a
  PC. Dock does not read or write it.

There is also a developer mode for testing on a Windows PC that asks an installed client to sign
in with **its own** cached account (`MADEIRA_STEAM_HOST_ACCOUNT`, `_STEAMID`, `_APPID`). Dock
passes the account name to the client and never reads the client's credential files. Madeira
always clears these variables; the app only uses the transfer file.

## Supported client builds

The functions Dock calls for sign-in, licence and launch are **not a public Valve SDK**. They are
internal interfaces of the client library (`IClientEngine`, `IClientUser`, `IClientAppManager`),
called by their position in the library's own method tables. That is fragile, so Dock is strict:

- It drives only client builds listed in `src/client_layout.c`, identified by the SHA-256 of
  `steamclient64.dll`. Two builds are listed (revisions 202601 and 202609).
- Before each internal call it checks that the method table entry is exactly the address
  recorded for that build. A mismatch stops the run.
- An unknown build **fails closed** with result 30 before any sign-in. Dock never guesses a
  layout.

`docs/CLIENT_LAYOUTS.md` records where each build came from (Valve's update servers, with the
manifest and archive hashes), that its Authenticode signature is Valve's, and how each method
was identified. `tools/check-client-layout.py` re-checks a client file against the table.

Only the shutdown call uses a public interface (`SteamClient021`, slot 23), checked against
Valve's public Steamworks header.

## Services

Valve's client prepares CEG executables through its own Windows service. A Dock session starts
only this host, so Wine's service manager may not be running yet. `src/scm.c`:

- starts Wine's standard `services.exe` if no service manager answers, and ends it again at exit
  if Dock started it;
- checks, read-only, that Valve's client service is registered; if it is not, runs Valve's own
  `bin\SteamService.exe /install`, which is what Valve's client does when it finds the service
  missing.

Dock itself never creates, registers, configures or starts a service. At exit it stops Valve's
client service through the service manager, so that nothing outlives the session.

`dockhost.exe --start-services` is a separate mode used before a game's one-time installers
(runtime setups from the game's Steam install script). It loads no Steam client: it only makes
Wine's service manager reachable, prints one line and exits.

A game session gets the same bounded start before the launch when the game needs it
(`src/launch.c`, `src/scm.c`): some launchers install an automatic-start Windows service of their
own, and without a service manager every start of it fails (RPC error 1722). With
`MADEIRA_DOCK_GAME_SCM` unset, Dock counts, read-only, the Win32 services registered in the prefix
with automatic or on-demand start whose image lies outside the Windows folder (`game-scm-services`;
Wine's own services never count) and starts the manager only when there is at least one; `1`
always starts it and `0`
never does. The step waits at most 20 s (`game-scm=<2 started, 1 already running, 0 off, -1
failed>` or `game-scm-timeout=1`) and never decides whether the game launches. The manager it
starts stays for the session, as after `--start-services`.

## Limits

- **Windows program, 64-bit session.** The 32-bit build supports only the bootstrap test.
- **Launch entries from Steam's configuration.** Bounded user arguments are passed to the selected entry.
- **One Steam session.** While Dock runs it is the account's Steam client; Madeira closes its own
  Steam connection first, because a second sign-in of the same account would replace this one.
- **Not crash-safe.** If the host is killed, the `ActiveProcess` values it wrote are not
  restored until the next run or the next real Steam start.
- **Not everything is validated.** Sign-in, the licence check and game starts have been run on
  Windows and on devices; CEG preparation has had less testing. Overlay, cloud saves,
  achievements, multiplayer, family sharing, revoked or refunded licences and connection loss
  during play have not been tested systematically. Setting up Steam's overlay is known to fail
  under Dock; nothing is patched to hide that.
- **A client update needs a new verified layout.** Until then Dock refuses the new build.

## Extra launch arguments

`MADEIRA_STEAM_HOST_ARGUMENTS` adds bounded UTF-8 arguments to Valve's own
`LaunchApp` user-arguments parameter. It is supplied on the first request and
on retries alongside the selected original Steam launch entry key. It never
enters the installer command and only its byte count is logged. Unbalanced
quotes, control characters, more than 64 tokens or 4095 bytes fail closed;
missing input preserves Valve's normal arguments. The app exports the value
from the selected library profile before starting this host. The client still
checks authentication, subscription and the original game DRM.

## Running it

Dock is started by Madeira, not by hand. Everything is passed in the environment, and every stage
is opt-in: with no variables set, `dockhost.exe` does nothing and exits with 2.

| Variable | Meaning |
|---|---|
| `MADEIRA_STEAM_HOST_PROBE=1` | Master switch. Without it nothing is loaded. |
| `MADEIRA_STEAM_HOST_SESSION=1` | Use the verified internal interfaces (needs a supported build). |
| `MADEIRA_STEAM_HOST_LOGIN=1` | Sign in. |
| `MADEIRA_STEAM_HOST_LAUNCH=1` | Start the game after sign-in and the licence check. |
| `MADEIRA_STEAM_HOST_BOOTSTRAP=1` | Without `SESSION`: load the client, create and release a user, for five seconds. No sign-in. |
| `MADEIRA_DOCK_AUTH_FILE` | Path of the one-use sign-in transfer. |
| `MADEIRA_STEAM_HOST_APPID` | The game to start. |
| `MADEIRA_STEAM_HOST_LAUNCH_OPTION` | Original numeric `config.launch` key, from 0 to 2147483647. Absent means 0 for older launchers; malformed input fails closed. |
| `MADEIRA_STEAM_HOST_EXPECTED_INSTALL` | The install folder the client must resolve for it. |
| `MADEIRA_STEAM_HOST_CLIENT_DIR` | Steam folder (default: the registry's `SteamPath`). Must be an absolute local path. |
| `MADEIRA_STEAM_HOST_LOG` | Report file. |
| `MADEIRA_STEAM_HOST_CEG=1` | The game ships CEG executables: prepare them first. |
| `MADEIRA_DOCK_OFFLINE=1` | The launcher found no network: ask Valve's client for an offline logon straight away (`docs/OFFLINE.md`). |

Switches that turn a behaviour off (all default on): `MADEIRA_DOCK_CEG=0`,
`MADEIRA_DOCK_CEG_SCM=0`, `MADEIRA_DOCK_CEG_SERVICE_INSTALL=0`, `MADEIRA_DOCK_CONTENT_WAIT=0`,
`MADEIRA_DOCK_CONFIG_WAIT=0`, `MADEIRA_DOCK_SESSION_WAIT=0`, `MADEIRA_DOCK_LIST_ENTITLEMENT=0`,
`MADEIRA_DOCK_CLIENT_202601=0`, `MADEIRA_DOCK_HANDOFF_DIAGNOSTICS=0`,
`MADEIRA_DOCK_INSTALL_SCM=0`, `MADEIRA_DOCK_OFFLINE_LOGON=0` (no offline start, and no
`session-offline-*` question), `MADEIRA_DOCK_KEEP_ALIVE=0` (no hold after the running report
ends; a `;`-separated list of image names instead adds those programs to the game's tree). The
three waits only ask Valve's client again for a bounded time when it answers "content is still
installing", "the game's configuration has not arrived yet" or "another session is playing"; they
never turn a refusal into a launch. `MADEIRA_DOCK_GAME_SCM` is three-way: `0` never starts a
service manager for the game session, `1` always does, unset starts one only when the prefix
registers a startable (automatic or on-demand) service outside Windows (see "Services"). Madeira
also sets `1` for a game whose own Steam install script recorded a non-Microsoft program, since a
launcher registers its service only on its first run, through the manager.

The selected launch key is reused on every retry and reported as numeric
`launch-option-index`. Invalid input reports `launch-option-invalid=1`. An error 22 whose
bounded detail explicitly identifies the requested launch entry as missing reports
`launch-option-missing` and stops instead of waiting for configuration. The detail is never
logged; other configuration waits and the sign-in and licence checks are unchanged.

### Result codes

| Code | Meaning |
|---|---|
| 0 | The stage that was asked for completed (after a launch: the game ran and ended). |
| 2 | Not enabled. |
| 10 to 13 | Bootstrap test: bad exports, user creation failed; any mode: malformed callback, release failed. |
| 20 | Stopped before a session: another Steam or Dock is running, bad Steam folder, client file unreadable, not loadable or missing its exports. |
| 30 | Unsupported client build, or a method address did not match. |
| 31, 32 | Developer mode: the client has no cached sign-in for the account, or could not select it. |
| 33 | The client did not start a sign-in. |
| 34 | Not signed in, or licence not confirmed, within 90 seconds. |
| 35, 36 | The game is not in the account's licence list; the list could not be read. |
| 37 | The sign-in transfer was missing, malformed or for another App ID. |
| 40 | Launch interfaces did not match the supported build. |
| 41 | The client's install folder for the game is not the expected one. |
| 42, 47 | Steam's discovery registry values could not be written, or could not be restored. |
| 43 | The client did not accept the launch request. |
| 44, 45 | No launch result in time; Valve's client refused the launch (its reason is reported as `launch-client-error`). |
| 46 | The game ran, but the launch result was missing or rejected. |
| 48 | The client was still installing content the game needs when the wait ended. |
| 49 | CEG preparation failed. |
| 50 | Offline: Valve's client cannot log this account on offline (no valid offline logon ticket), or this client build has no verified offline logon. |
| 51 | Offline: Valve's client refused the offline logon. |
| 54 | Extra launch arguments are malformed or too long. |
| 52 | Offline: signed in offline, but the client's cached licences did not list the game within 60 seconds. |

The report (`[steam-host] <round> <stage>=<number>` lines) is documented field by field in
Madeira's `docs/MADEIRA_DOCK.md`.

## Build and test

```sh
bash tools/check.sh          # unit tests with ASan and UBSan (host clang)
bash tools/build.sh          # x86-64 and i686 dockhost with llvm-mingw, static, stripped
bash tools/build.sh --stage  # also copy the x64 EXE and dock-notices.txt into ../Madeira
python3 tools/check-privacy.py [--history|--self-test]
```

- The tests cover the transfer parser and its bounds, the client-layout table, callback
  handling, licence-list bounds, launch-result decoding and the service-manager decisions. They
  use synthetic data and do not contact Steam.
- `tools/test-invalid-handoff.ps1` runs the real host on Windows with a malformed transfer and
  checks that it fails before sign-in and that the file is gone.
- `tools/check-privacy.py` fails on personal paths, email addresses, token-like strings, private
  keys, real-looking SteamIDs and Steam login-cache files, in the tree or in history.

Never commit tokens, passwords, Steam login caches, account names, real SteamIDs, personal paths,
logs, Valve binaries, games or build output.

## Repository layout

| Path | Contents |
|---|---|
| `src/main.c` | Entry point: gates, client identification and loading, shutdown, `--start-services`. |
| `src/session.c` | Sign-in, the wait for online state, the offline logon, the licence check. |
| `src/launch.c` | Install-folder check, CEG request, discovery values, `LaunchApp`, the game-running loop. |
| `src/auth.c` | The one-use sign-in transfer: parse, consume, clear. |
| `src/client_layout.c` | The supported client builds and their method addresses. |
| `src/scm.c` | Wine's service manager and Valve's service installer. |
| `src/probe.c`, `src/validation.c` | The bootstrap test and the pure decision functions the tests cover. |
| `tests/`, `tools/` | Unit tests; build, check, privacy and layout scripts. |
| `docs/CLIENT_LAYOUTS.md` | Provenance and verification of each supported client build. |
| `docs/HANDOFF.md`, `docs/HISTORY.md` | Development notes and the round-by-round history. |
| `notices/`, `THIRD-PARTY-NOTICES.md` | Toolchain runtime notices and research references. |

## Provenance

The implementation is independent. No code from a Steam emulator, from another project's host or
from Valve is included. Interface layouts were researched with
[OpenSteamworks](https://github.com/OpenSteamClient/OpenSteamworks) (MIT, used as a reference
only) and confirmed by inspecting the exact client files Dock supports; the public shutdown slot
was checked against Valve's Steamworks header as distributed with Proton. Details are in
`THIRD-PARTY-NOTICES.md`.

## Relationship to Valve

Steam and the Steam client are Valve's. This project is not affiliated with, authorised by or
endorsed by Valve, and it uses interfaces Valve has not published and may change at any time.
Its purpose is narrow: to let the owner of a game play their own licensed copy on their own
device, with Valve's client performing the sign-in, the licence check and the launch, and with
the game's protection left exactly as shipped.

Questions or concerns, including from Valve or from a game's rights holder, are welcome in the
[issue tracker](https://github.com/125hz/madeira-dock/issues).
