# MPFever – Multiplayer for Transport Fever 3 (experimental)

**Build your transport empire together.** MPFever adds cooperative multiplayer to Transport Fever 3: you and your friends play the same world, in one shared company or each with your own company, each in your own game, over the internet or a local network.

> ⚠️ **Experimental version (0.1.1).** It works, but expect bugs, short pauses and the occasional crash. Back up your savegames, and please send feedback: it decides what comes next.

## Features

- **Co-op in one shared company, or one company per player.** The host chooses when hosting: either shared money, vehicles, lines and infrastructure, or every player has their own company (own money, roads, stations, vehicles, lines and colour) on the same map. A player finds their company again after a reconnection (it belongs to their Steam account); every company has its own loans and contracts, the windows show who owns what, and a company can share its stations with the others for a fee per stop.
- **Real-time sync of what you build.** Roads and tracks (including joins in the middle of a road and upgrades), bus and tram stops, stations, depots, buildings, the bulldozer and terrain editing (raising / lowering the ground). Vehicle purchases, lines, vehicle assignments, game speed and pause too.
- **Host authority.** Every 10 seconds the games compare their state:
  - money, loans, company progress, contracts, towns and industries;
  - cargo in buildings and vehicles;
  - vehicles and roads.

  Money is corrected automatically. Any other lasting difference triggers an **automatic resync**: a short pause, the host's game is sent to everyone, all games reload it, and play resumes (about 20 s).
- **Built into the game.** No extra buttons in the game interface. A small launcher window handles hosting, joining and speed.
- **Direct IP connection.** Use port forwarding or a virtual LAN (Radmin VPN, ZeroTier, Tailscale…).
- **In the 13 languages of the game.** The launcher and the in-game window follow the language of Transport Fever 3 (it can also be chosen in the launcher).

## Known limitations (0.1)

- Separate companies: the Company window's actions only work for the host's company for now; the level of the savegame's company is shared. Ground paint is not copied yet.
- All players must load the same savegame file. The host shares it for now; automatic transfer is planned.
- No joining a session that is already running, and no Steam invites yet.
- Vehicles may drift slightly after road building; the automatic resync fixes it.
- Tested with 2 players. Windows only.
- Made for the current Steam version of the game (build 40408).

## Open source and transparent

The full source code is public (link below), with the steps to build it yourself. MPFever copies a small `winhttp.dll` into the game folder, which the game loads by itself, the same way well-known mod loaders work. It passes the game's network calls unchanged to Windows and stays inactive in normal solo games. MPFever only connects to the address you enter.

**Source code:** https://github.com/dkdknight/MPFever

## Installation

1. Extract the archive anywhere.
2. Run **MPFever.exe** once. It finds the game through Steam, installs the mod and enables it for new games.
3. Follow **INSTALL.txt** to prepare a shared savegame, set up the network and start your first session.

The mod does nothing in normal solo games. It only activates when the game is started through MPFever.exe.

## Roadmap

- **0.2 – Stability and easier start:** automatic savegame transfer when joining, any savegame, fewer resyncs, reconnection, 3–8 players.
- **0.3 – Playing with friends:** Steam invites, joining a running game, player list and chat in the game UI, host permissions.
- **0.4 – Separate companies** on the same map, with competition and rankings.
- **0.5 – Mixed modes:** shared and separate companies in the same game.
- **Later – Persistent worlds:** dedicated server, drop-in/drop-out, larger player counts.

## Feedback and bug reports

Describe what you did and what happened, and attach the newest `logs\launcher-….log` next to MPFever.exe and the `%TEMP%\mpfever` session folders. Details are in README.txt.
