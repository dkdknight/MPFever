# Exact client adapters — ml1860

"Private" below means Valve's undocumented client interfaces. These are
compatibility adapters for genuine Valve libraries, not replacements for the
libraries or their authentication/DRM.
An unrecognized SHA-256 or mismatched method address fails closed. Interface
names and PE timestamps alone never authorize private calls.

The previously supported September build has SHA-256
`caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee`.
ml1860 also supports the owner's device's exact January build:
`71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640`,
PE timestamp 1769726215. `MADEIRA_DOCK_CLIENT_202601=0` disables this adapter.
`[steam-host] ml1860 session-client-adapter=202601` identifies selection;
it is not authentication or entitlement evidence.

## Provenance and independent inspection

Fetched from Valve on 2026-09-24 via HTTPS:
`https://client-update.akamai.steamstatic.com/steam_client_win32`.
The returned manifest reports version 1769731672 and names
`bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da`, downloaded
from the same host. Archive SHA-256 matches its manifest:
`8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62`.
Its steamclient64.dll matches the device report byte fingerprint exactly.
Windows Authenticode verification reports Valid, signer Valve Corp.
Downloaded files and analysis output stay ignored in `.build/client-jan2026`.
No Valve DLLs or archives are included in the app/repository distribution.

RTTI gives offset-zero vtables CSteamClient at RVA 0x12ec718,
IClientUserMap at 0x12b8938, IClientAppManagerMap at 0x12c0278.
All 14 called private methods are pinned in `src/client_layout.c`. User and
manager method names were independently checked via their RIP-relative IPC
strings, including LogOn, SetLoginToken, BIsSubscribedApp, GetSubscribedApps,
LaunchApp and GetAppInstallDir. Slots are unchanged between these two builds.

Disassembly comparison of the called wrappers (through their first return)
retains identical argument registers/stack widths and return widths. Engine
user/manager wrappers have identical normalized instructions. Differences in
the others are equivalent signed-negative cleanup tests and reordered loads
before the same underlying call; manager IPC type constants vary by build.
Those constants are implemented by Valve's own matching library, not Dock.
GetAPICallResult still forwards the same buffer/size/callback/failure args.
This inspection is bounded ABI evidence, not full behavioral compatibility.
The launch callback remains strictly checked for ID 1270027, 524 bytes, the
requested GameID and success. Do not loosen it if a future device test fails.

Reproduce the independent RTTI/table checks with Python (no DLL execution):

```
python tools/check-client-layout.py PATH_TO_OFFICIAL_STEAMCLIENT64_DLL
```

Portable sanitizer tests reject unknown/partial/changed fingerprints and
mismatched method pointers. A native Windows probe using the isolated official
January DLL verified all session pointers, with login/launch disabled, and
exited 0. Disabling the January adapter reproduces rejection 30. This does not prove native-token authentication or iOS game launch.
The original supported September table is also checked for regression.

## Device result motivating the change

Log 60 / ml1850 got past the earlier native stale-image crash, loaded both
interfaces, then returned session-unsupported-client=1 / probe-result=30.
It never reached authentication. The apparent infinite wait was separately a
public runtime notification gap on normal Wine exit. ml1860 fixes the common
exit wrapper and exports a bounded whitelist of Dock report fields, including
this adapter revision and fingerprint, in the normal Madeira log.

## ml1990 — custom executable (CEG) preparation

Both pinned builds add one called method, independently identified in each:
IClientUserMap slot 71 wrapper, September RVA `0x84e8b0`, January RVA
`0x82a8c0`. Slot 70 is GetCustomBinariesState (`0x769b60` / `0x74cc60`;
not called). Each wrapper names "RequestCustomBinaries" through a
RIP-relative LEA and serializes IPC function ID `0x08711e2c` and fencepost
`0x08b15ab0`; `tools/check-client-layout.py` now verifies slot, RVA, name
and function ID. Slot 70's wrapper fails that name check (January negative control).

Wrapper ABI (both builds, identical instructions except call targets):
rcx this, edx u32 AppID, r8b bool, r9b bool, one stack argument serialized
as 8 bytes; it reads one response byte (must be 11) and a 4-byte result,
returning 55 (k_EResultRemoteCallFailed) on IPC failure. The server
dispatcher (`cmp eax,0x8711e2c`) calls the user object's slot 71 with the
same five values. That implementation (`0x9b0860` Jan / `0x9e0d40` Sep)
immediately writes `0` through the fifth value, so it is a `uint32 *`
(the older 32-bit reference lists it as bytes4), then returns: 2 unknown
or uninstalled app, 10 app busy (updating/running flags), 1 with no
CustomExecutable entries, 9 no install folder, else 1 and the count of
per-file jobs started or already in progress. OpenSteamworks reference
lists the older build as `RequestCustomBinaries(AppId_t, bool, bool, uint)`.

First bool: skip DRM-identifier extraction and force a refresh. With zero
identifiers the job reports success without downloading, so Dock passes
false. Second bool: job flag 0x10, which ends the job with Busy (10) after a
server Busy reply instead of Valve's own retry loop; Dock passes false and
bounds the total wait itself (5 minutes).

Completion: CDRM::OnDRMDownloadJobFinish posts callback **1020025**
(`0xf9079`), 8 bytes: int32 EResult, uint32 AppID, once per job (source file
clientjobrequestcustombinary.cpp; strings "OnDRMDownloadJobFinish: %u (%s)").
Each server reply also posts 1020024 (`0xf9078`), 12 bytes: EResult, AppID,
bool. Identical IDs/sizes in both builds. The launch-time runtime DRM path
posts 1020025 with the same layout (Timeout 16) after a 0x8000DEAD report.

LaunchApp does not itself request custom binaries: the only callers of the
per-file request (`0x4f2a50` Jan) are this IClientUser method and the running
game's legacy DRM IPC fix-up. Hence the explicit request before LaunchApp.
Extraction reads PE resources (STEAM_SPLIT_GUID/STEAM_GUIDD/STEAM_MINSTANCE)
in process. The file list comes from the app manifest's CheckGuid entries.
Delivery of 1020025 to a global-user pipe and server success remain unproven
at runtime: this is static evidence only.

## Offline logon (see OFFLINE.md)

Both pinned builds add three called methods on IClientUserMap, at the same
slots in each: 5 `GetLogonState` (September RVA `0x77e460`, January
`0x7612c0`, IPC function `0xb3679023`), 214 `CanLogonOffline` (`0x73cbb0` /
`0x720330`, `0xe391b9f0`) and 215 `LogOnOffline` (`0x8415d0` / `0x81dad0`,
`0x706f013f`). `tools/check-client-layout.py` verifies slot, RVA, the method
name each wrapper references through a RIP-relative LEA, and the function ID.

Wrapper ABI, identical in both builds apart from call targets and the known
signed-negative cleanup test: slots 5 and 214 take only `this` and read back a
4-byte result; slot 215 takes `this` and one byte (dl, serialized as 1 byte)
and reads back a 4-byte result. Neighbouring slots 216
`ValidateOfflineLogonTicket` and 217 `BGetOfflineLogonTicket` are not called:
Dock never handles the ticket itself.
