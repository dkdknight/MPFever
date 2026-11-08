MPFever - Multiplayer for Transport Fever 3
Version 0.7.9
===========================================

MPFever lets several players play the same Transport Fever 3 world together, each one
in their own copy of the game, over the internet or a local network: either all in the SAME
company, or each player with their OWN company.

MPFever gets frequent updates. If something goes wrong, please send a report (see
"Reporting a problem" below): it decides what comes next.


WHAT WORKS
----------
- Two ways to play, chosen by the host in the multiplayer window when hosting:
  - "One company for everybody": all players manage the SAME company (shared money,
    vehicles, lines).
  - "One company per player" (STILL IN DEVELOPMENT: many bugs remain to be fixed; use it
    mainly to test it and help the development of the mod): every player has their own company on the same map: own
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
  - Rules for the others: every company sets, in the Rules tab of the MPFever window, a rule
    for its tracks, for its stations and stops and for its depots: private, open (free, the
    default), or with a toll (per passage, per stop, per vehicle bought or sent there). A
    station's or a depot's own window can give it a setting of its own. The other companies'
    lines may only stop at stations that are not private; each time one of their vehicles stops
    at a toll station, they pay the fee to the owner. The line windows show the fee next to the
    name of every other company's station.
  - Game rules: the host chooses them in the lobby ("Game settings...") and they are kept in
    the savegame: the start money of a new company (2 million by default; the host's company
    gets it too at the start of a new game), the sharing rules on or off (off: everything is
    open and free for every company) and the months in debt before a bankruptcy. The Game tab
    of the MPFever window shows them to everybody; the host can change them there.
- Start from the game itself: MPFever.exe starts Transport Fever 3, and a
  "MULTIJOUEUR / MPFever" button in the main menu opens the multiplayer window.
  - Host: pick one of your savegames (any of them, even one made without MPFever: the mod
    adds no content to the game, it only synchronises) and open the lobby. If the game uses
    other mods, every player must have the same ones installed: the lobby lists them and
    shows each player those missing on their PC.
  - Mods: MPFever is not made for other mods yet. Mods that only add content (vehicles,
    buildings...) usually work. Mods that change the game by themselves (rename lines,
    assign terminals, change colours...) do it on each game separately and break the
    synchronisation: play without them. Mod authors who want their mod to work with
    MPFever are welcome to get in touch (GitHub issues).
  - Lobby: the players join it in the main menu and see who is there. The host starts the
    game when everybody is there: every game loads the host's savegame at the same time.
  - Join: type the host's IP address. The host's game is received and loaded
    automatically (no file to send). Joining a session already running works too.
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
- Dedicated server (NEW, in development): a PC of its own can run the world for everybody,
  without the PC of one of the players (MPFever.exe of the server's archive), with display or
  without (the game runs hidden and draws nothing). The world waits while nobody is
  connected, is saved every 10 minutes and survives a crash of the game. Players join its
  address as they join a host, with its password if it has one.
  It comes as a separate archive, MPFever-<version>-server.zip (see SERVER.txt in it).
- MPFever icon in the game's bottom bar, left of Earnings: green when the games are in sync,
  yellow during a reload or while a player joins, red when something is wrong (link lost,
  games out of sync), with the number of unread chat messages. A click opens the window.
- MPFever window in the game: it opens by itself when the session starts and after each
  reload (closed by you, it stays closed for the session), or from the bar icon or the
  MPFever card of the pause menu. Its tabs: Session (the players and their link, the sync
  state, the game speed, Steam invites, Report a problem, for the host a Resynchronise
  button, and signals on the map: "Here", "Watch out" or "Build here", then a click on the
  map shows a circle in the signal's colour, with your colour in its middle, there for 12 s on
  every player's game), Chat,
  Company, Rules and Game (one company per player only), Settings.
- Chat in the game: the Chat tab (or the "Chat" card of the pause menu); new messages show
  for a few seconds at the left of the screen.
- The mod is built into the game: the only additions to the game interface are the
  MPFever button in the main menu, the icon in the bottom bar and the MPFever and Chat cards
  in the pause menu.
- Since 0.3.4 the games stay identical much longer: the main cause of the desyncs (the
  game's own scripts did not take their decisions in the same order on every PC) is fixed.
  Resynchronisations should now be rare.


KNOWN LIMITATIONS
-----------------
- One company per player: each company has its own rank (from what it carries for the towns),
  its own Company window actions, money gifts and shared stations, depots and tracks; the
  game's achievements still count for the savegame's company only. The map shows the routes of
  your own company's lines.
- Every player should have the same DLCs: the Deluxe upgrade pack and the pre-order pack put
  their animals, people and vehicles in the world of the PC that owns them only. The lobby warns
  and says what to do: the host can switch the DLCs off in the savegame's mods (when loading
  it), or the players can get them. Joining a game already running, the Multiplayer page shows
  its mods and DLCs first, then « Join the game ».
- The tutorial is not supported: its missions are validated on each game separately, so the
  games diverge (a unique building made by one player blocks the other's task). Play a game
  without the tutorial.
- With "Responsive builds" (on at first) your builds show at once on your game; the other
  games apply each of them at the same game time and stop for it a moment: about half a
  second for a road or a module, about a second for a module of a very big station. Without
  it, each build waits 1 to 2 seconds before it appears. When two players change
  the same place within those seconds, the build made second is computed again on every
  game (if it no longer fits the place, it is left out everywhere: make it again). With one
  company per player, this can still lead to an automatic resynchronisation.
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
- Windows only. Made for the current Steam version of Transport Fever 3 (builds 40420, 40423 and 40425).
  After a game update, the mod still runs but synchronisation may be worse until
  MPFever is updated.
- The host's port is opened on its router by itself (UPnP, else NAT-PMP) while a session
  runs, and closed again afterwards: the launcher's log says whether it worked. When the
  router has no public address of its own (CGNAT: the log says so), nobody outside can
  reach the host over IPv4: use IPv6, a dedicated server elsewhere, or a virtual LAN
  (Radmin VPN, ZeroTier, Tailscale, Porthole). Write  upnp=0  in mpfever_settings.txt to
  leave the router alone.
- IPv6: the host also accepts players over IPv6, and Steam invitations carry its IPv6
  address as well. A host behind DS-Lite (no public IPv4 address of its own, as on many
  cable connections) is reached that way when the joining player has IPv6 too and the
  host opens TCP port 28090 for IPv6 on its router. To join by hand, type the address
  in brackets: [2a02:...]:28090. Write  ipv6=0  in mpfever_settings.txt to leave it out
  of invitations.


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
The only other connections:
- At startup, before the game starts, and every 30 minutes, it asks GitHub
  (api.github.com) for the newest MPFever release. A newer one is installed by itself:
  at startup at once (downloaded from github.com/dkdknight/MPFever/releases, checked,
  MPFever's files replaced, your mpfever_settings.txt and logs kept, MPFever started
  again); found later, when you close the game; a dedicated server installs it and
  restarts once nobody is connected. Every player needs the same version, so everybody
  gets it this way. Write  autoupdate=ask  in mpfever_settings.txt (next to MPFever.exe)
  to be asked first, or  autoupdate=0  to disable the check.
- When the host's router supports UPnP or NAT-PMP, it asks the router to open the
  session's port, and to close it again afterwards (upnp=0 to disable).
- When you host, it asks api.ipify.org (a public service that answers with your public IP
  address, nothing else is sent) so that the address given to Steam invitations works from
  the internet. Write  lookupip=0  in mpfever_settings.txt (next to MPFever.exe) to disable
  this; invitations then carry your local address.

UNINSTALL: delete winhttp.dll and steam_appid.txt from the game folder, delete the
folder mods\mpfever_1 in your Transport Fever 3 user folder, and delete the MPFever
folder. The full source code is public (see the mod page).


REPORTING A PROBLEM
-------------------
The easiest: "Report a problem (logs)" in the MPFever window of the game (pause menu), or
"Report a problem" in the launcher window. MPFever puts every log into a zip file (folder
"reports" next to MPFever.exe), shows it in the Explorer and opens a new GitHub issue with
its text filled in: describe what you did and when, drag the zip into the issue, send.
After a crash of the game MPFever offers it by itself. The other players can send theirs
the same way. The game rewrites its own log at every start: MPFever keeps a copy (in the
session folder when the game closes, and logs\stdout-previous.txt before it starts it).
By hand, attach:
1. the newest file from the "logs" folder next to MPFever.exe (launcher-....log);
2. the folders %TEMP%\mpfever\Host-... or Client-... of that session (zip them);
3. if the game crashed: the newest files of
   C:\Program Files (x86)\Steam\userdata\<your id>\3493540\local\crash_dump\

CREDITS
-------
- dkdknight: author and maintainer.
- SlikerDev: the launcher's design, MPFever in the 13 languages of the game, the in-game
  MPFever window, the in-game chat and the fee list of the station windows.
- Thanks to every tester who reported a problem with their logs.


See INSTALL.txt to get started and ROADMAP.txt for what comes next.

Players, help and news: join the MPFever Discord: https://discord.gg/DfMxFUQZCR
Feedback and ideas: https://github.com/dkdknight/MPFever/discussions
Enjoying MPFever? Support the project or thank its author on Ko-fi: https://ko-fi.com/knighthd
