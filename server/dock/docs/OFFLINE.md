# Offline start

Steam's own client can log an account on without a connection. It does this
with an *offline logon ticket*: during an online logon the client asks Steam
for one and stores it (`Offline.GetOfflineLogonTicket`; the client's settings
`bEnableOfflineLogonTicket` and `bRequireOfflineLogonTicket` both default to
on), and a later offline logon is only accepted with a valid ticket. Desktop
Steam's "Offline Mode" is this mechanism.

Dock uses it as it is. It does not store, read, copy or check the ticket and
does not decide anything about ownership:

1. **Online starts are unchanged.** After Valve's client has confirmed the
   game's licence, Dock asks it `CanLogonOffline` and reports the answer as
   `session-offline-ready` (again after the game ends, since the client fetches
   the ticket on its own schedule). The launcher uses that to show whether a
   game has been "saved for offline play".
2. **An offline start** (`MADEIRA_DOCK_OFFLINE=1`, set by the launcher when the
   device has no network) submits the sign-in as usual, then asks
   `CanLogonOffline`. Only if Valve's client answers yes does Dock call
   `LogOnOffline`, wait for the client to load its cached licences, ask the same
   `BIsSubscribedApp` / `GetSubscribedApps` questions as online, and start the
   game through the same `LaunchApp` call. DRM, tickets and the game's own Steam
   API calls are answered by Valve's client from its own cache, exactly as in
   desktop Steam's Offline Mode.
3. **Fallback.** An online start whose connection fails (a
   `SteamServerConnectFailure` callback, 20 s without signing in) asks
   `CanLogonOffline` once per failed connection and switches to the offline
   start if the client says yes. A client that says no keeps waiting as before.

A refusal ends the session with its own code and never starts the game:

| Code | Meaning |
| --- | --- |
| 50 | Valve's client cannot log this account on offline: no valid offline logon ticket. Start the game once while online. |
| 51 | Valve's client refused the offline logon. |
| 52 | Logged on offline, but the client's cached licences did not list the game within 60 s. |

Report fields (numbers only): `session-offline-abi`, `session-offline-requested`,
`session-offline-can`, `session-offline-logon-result`, `session-offline-logon-retry`,
`session-offline-logon-state`, `session-offline-callback-id`, `session-offline-entitled`,
`session-offline-listed`, `session-offline-timeout-state`, `session-offline-fallback`,
`session-offline-ready`.

`MADEIRA_DOCK_OFFLINE_LOGON=0` removes the feature: the three methods are not
looked up, an offline request ends with 50, and nothing else changes.

## What is and is not known

The three methods are pinned per client build like every other private call
(`docs/CLIENT_LAYOUTS.md`): `IClientUser` slot 5 `GetLogonState`, 214
`CanLogonOffline`, 215 `LogOnOffline`, identified by the method name and IPC
function id each wrapper carries. Their wrappers take no argument (5, 214) and
one bool (215) and return 32 bits.

Not established by inspection: the meaning of `LogOnOffline`'s bool (Dock asks
with `false` and, only on refusal, once with `true`, and reports which was
accepted), the values `GetLogonState` takes offline (reported, not interpreted),
and how long Steam's offline logon ticket stays valid (Valve's client enforces
that itself; when it expires the answer is 50 and an online start renews it).

## Device result

2026-10-04, iPhone 18,3 / iOS 27.0, January client (adapter 202601), no network
path: `session-offline-can=1`, `session-offline-logon-result=1` (accepted with
`false`, no retry), `session-offline-logon-state=0` and unchanged (the state
does not signal an offline logon, so nothing waits on it),
`session-offline-entitled=1`, `session-offline-listed=1` with 1584 cached
subscriptions one second after the logon, `launch-client-error=0`, the game's
window 8 s after the host started. The account had signed in online earlier
through the one-use token handoff, so that handoff leaves Valve's client able
to log on offline. Not yet exercised on a device: a refusal (50, 51, 52), the
connection-failure fallback, the September client, and a game with per-user
executables.
