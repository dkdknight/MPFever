MPFever - Multiplayer for Transport Fever 3
Version 0.3.4-experimental
===========================================

MPFever lets several players play the same Transport Fever 3 world together, each one
in their own copy of the game, over the internet or a local network: either all in the SAME
company, or each player with their OWN company.

THIS IS AN EXPERIMENTAL VERSION. Expect bugs, pauses and the occasional crash. Keep
backups of the savegames you play with, and please send feedback (see "Reporting a
problem" below).


WHAT WORKS
----------
- Two ways to play, chosen by the host in the multiplayer window when hosting:
  - "One company for everybody": all players manage the SAME company (shared money,
    vehicles, lines).
  - "One company per player": every player has their own company on the same map: own
    money, own roads, stations, depots, vehicles and lines, each company with its own
    colour (the lines a company creates take its colour, a little darker for each new
    one). The host plays the company of the savegame, every other player gets a new company
    with a starting capital (2,000,000 by default; write  companystart=1000000  in
    mpfever_settings.txt, next to MPFever.exe, to change it) the first time it is seen. The
    company belongs to the player's STEAM ACCOUNT (and name): after a reconnection, a
    resynchronisation, or in a later session on the same savegame, the player finds their
    company again, with everything they built, even if they changed their name. While a
    player is away, nobody else owns their company. The company name is the one of the
    player's company in the game (editable in the company window).
  - Every window of a station, depot, vehicle, line or building says on its first line which
    company owns it ("Owner: ..."; "(you)" for your own).
  - Contracts (subsidies): the offers are the same for everybody; a contract belongs to the
    company that accepts it (only its own vehicles count for it, the reward goes to it) and
    each player only sees their own contracts and the offers they did not decline.
  - Loans: every company has its own loans (offers, loans taken, monthly payments).
  - Shared stations: a company can share one of its stations or stops with the others for a
    fee per stop. In the station's window, its owner sets the fee with the - and + buttons
    (0 = not shared). The other companies' lines may only stop at stations that are shared;
    each time one of their vehicles stops there, they pay the fee to the owner.
- Start from the game itself: MPFever.exe starts Transport Fever 3, and a
  "MULTIJOUEUR / MPFever" button in the main menu opens the multiplayer window.
  - Host: pick one of your savegames (any of them, even one made without MPFever: the mod
    adds no content to the game, it only synchronises). If the game uses other mods that
    add content (vehicles, buildings...), every player must have the same ones installed.
  - Join: type the host's IP address. The host's game is received and loaded
    automatically (no file to send). Joining a session already running works.
  - Steam invitations: friends can join from your Steam friends list.
- Everything a player builds or changes appears in the other games at the same moment:
  roads (all road types, with trees and other decorations), tracks, tram tracks laid on
  roads, rail signals, noise barriers, bus and tram stops, stations, depots (also those
  built against a street), buildings, terrain edits, trees and plants of the brush (new,
  see the limits), the bulldozer, vehicle purchases, lines and vehicle assignments, game
  speed and pause. The dust cloud of a construction going up is shown on every game.
- The host is the authority: every 10 seconds the games compare their state (money,
  loans, company, contracts, towns, industries, cargo in buildings and vehicles,
  vehicles, roads, road decorations...).
  - Money differences are corrected automatically.
  - Any other lasting difference triggers an automatic RESYNCHRONISATION: the game
    pauses, the host's game is saved and sent to every player, everybody reloads it,
    and the game resumes (about 20 seconds).
  - A build one game cannot reproduce makes the host resynchronise at once.
- If the connection is lost, the player's MPFever reconnects by itself (for 5 minutes).
- The mod is built into the game: the only addition to the game interface is the
  MPFever button in the main menu.


KNOWN LIMITATIONS
-----------------
- Separate companies: the level (rank, permits) of the savegame's company is shared by all the
  companies; the company actions of the Company window (market campaigns, greening, industry
  prospecting) only work for the host's company for now (the other players' requests are
  ignored); there is no money transfer between companies yet. Depots cannot be shared.
- Each build waits about 1 to 2 seconds before it appears: the games apply every
  construction at the same game time, which needs a safety margin.
- When a road upgrade moves several town buildings, the town may place one extra
  building differently on each game; the automatic resynchronisation then corrects it
  after a few seconds.
- Terrain editing (raising / lowering the ground) is copied to the other games: the game
  where you edit sends the new ground, the others apply it at the same game time (or a
  step later when they were already past it). If the copy fails the host's game is
  reloaded for everybody (automatic resynchronisation).
- Trees and plants of the brush are copied (since 0.3.3). Ground PAINT (textures) is not copied
  yet: each game keeps its own paint (it does not cause a resynchronisation).
- Tested with 2 players. More players should work but are untested.
- No player list or chat in the game yet.
- Windows only. Made for the current Steam version of Transport Fever 3 (builds 40408 and 40420).
  After a game update, the mod still runs but synchronisation may be worse until
  MPFever is updated.
- Without port forwarding on the host's box, players need a virtual LAN (Radmin VPN,
  ZeroTier, Tailscale) or Steam invitations will not reach the host.


WHAT MPFEVER CHANGES ON YOUR PC
-------------------------------
- It copies winhttp.dll into the game folder. The game loads it by itself at startup,
  the same way well-known mod loaders work. This small module passes every network
  call of the game unchanged to Windows' own winhttp.dll, and only does something when
  the game was started by MPFever.exe: in a normal solo game it is inactive. It lets
  MPFever synchronise the game's own construction tools precisely.
- It writes a file steam_appid.txt in the game folder (so that the game can be started
  directly, several times on one PC).
- It adds the mod to the game's default mod list in settings.lua (a backup is kept as
  settings.lua.bak_mpfever).
- It installs the mod files in your Transport Fever 3 user mods folder.
MPFever connects to the address you type (or the one of the Steam invitation you accept).
The only other connection: when you host, it asks api.ipify.org (a public service that
answers with your public IP address, nothing else is sent) so that the address given to
Steam invitations works from the internet. Write  lookupip=0  in mpfever_settings.txt (next to
MPFever.exe) to disable this; invitations then carry your local address.

UNINSTALL: delete winhttp.dll and steam_appid.txt from the game folder, delete the
folder mods\mpfever_1 in your Transport Fever 3 user folder, and delete the MPFever
folder. The full source code is public (see the mod page).


REPORTING A PROBLEM
-------------------
Please describe what you did, what you expected and what happened, and attach:
1. the newest file from the "logs" folder next to MPFever.exe (launcher-....log);
2. the folders %TEMP%\mpfever\Hote-... or Client-... of that session (zip them);
3. if the game crashed: the newest files of
   C:\Program Files (x86)\Steam\userdata\<your id>\3493540\local\crash_dump\

See INSTALL.txt to get started and ROADMAP.txt for what comes next.
