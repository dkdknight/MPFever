# MPFever – Multiplayer for Transport Fever 3

**Build your transport empire together.** MPFever adds multiplayer to Transport Fever 3. You and your friends play the same world, each in your own game, over the internet or a local network. You can share one company or each run your own.

> MPFever gets frequent updates. Please send feedback and reports: they decide what comes next.

## Features

- **Co-op in one shared company, or one company per player.** The host chooses when hosting.
  - Shared company: shared money, vehicles, lines and infrastructure.
  - One company per player: own money, roads, stations, vehicles, lines and colour, on the same map.
    - A player finds their company again after a reconnection: it belongs to their Steam account.
    - Every company has its own loans and contracts.
    - The windows show who owns what.
    - Tracks, stations and depots are open to the other companies by default; each company can make them private or charge a toll.

  The "one company per player" mode is still in development and many bugs remain: use it mainly to test it and help the development of the mod.
- **Real-time sync of what you build.** Every game applies it at the same game time:
  - roads and tracks, including joins in the middle of a road and upgrades;
  - bus and tram stops, stations, depots, buildings;
  - the bulldozer, terrain editing and trees;
  - vehicle purchases, lines, vehicle assignments, game speed and pause.
- **Games that stay identical.** Since 0.3.4 the main cause of desyncs is fixed: the game's own scripts now take their decisions in the same order on every PC.
- **Host authority.** Every 10 seconds the games compare their state:
  - money, loans, company progress, contracts, towns and industries;
  - cargo in buildings and vehicles;
  - vehicles and roads.

  Money is corrected automatically. Any other lasting difference triggers an **automatic resync**: a short pause, the host's game is sent to everyone, all games reload it, and play resumes (about 20 s).
- **Easy start, with a lobby.** Open a lobby with any savegame from the multiplayer button of the main menu. Friends join it by IP address or through a Steam invitation, and the host starts the game when everybody is there: every game loads it at the same time. Joining a game already running works too. The host's game is sent to the players automatically.
- **Chat and MPFever window in the game.** An icon in the bottom bar shows the sync state (green, yellow, red) and the unread messages; a click opens the MPFever window, which also opens by itself at the start of a session. Its tabs:
  - Session: the players and their connection, the sync state, the game speed, Steam invites and, for the host, a Resynchronise button;
  - Chat;
  - Company and Rules (one company per player only);
  - Settings.
- **Built into the game.** MPFever only adds a button in the main menu, an icon in the bottom bar and two cards in the pause menu.
- **In the 13 languages of the game.** The launcher and the in-game windows follow the language of Transport Fever 3. The language can also be chosen in the launcher.

## Known limitations

- Separate companies:
  - the Company window's actions only work for the host's company for now;
  - the level of the savegame's company is shared;
  - there is no money transfer between companies.
- Ground paint is not copied yet.
- Each build appears after about 1 to 2 seconds: every game applies it at the same game time.
- Tested with 2 players. Windows only.
- Made for the current Steam version of the game (builds 40420, 40423 and 40425).

## Open source and transparent

The full source code is public (link below), with the steps to build it yourself.

MPFever copies a small `winhttp.dll` into the game folder, which the game loads by itself, the same way well-known mod loaders work. It passes the game's network calls unchanged to Windows and stays inactive in normal solo games. MPFever only connects to the address you enter.

**Source code:** https://github.com/dkdknight/MPFever

## Installation

1. Extract the archive anywhere.
2. Run **MPFever.exe**. It finds the game through Steam, installs the mod and starts the game.
3. In the main menu, click the multiplayer button to host one of your savegames or join a friend. **INSTALL.txt** explains the network setup.

The mod does nothing in normal solo games. It only activates when the game is started through MPFever.exe.

## Roadmap

- **0.4 – Separate companies, complete:** Company window actions for every company, money transfers, competition and rankings.
- **0.5 – Mixed modes:** shared and separate companies in the same game, joining and merging companies.
- **Later – Persistent worlds:** dedicated server, drop-in/drop-out, larger player counts.

## Credits

- **dkdknight** – author and maintainer.
- **SlikerDev** – the launcher's design, MPFever in the 13 languages of the game, the in-game MPFever window and the chat.
- Thanks to every tester who reported a problem with their logs.

## Community

Find players, get help and follow the development on the [MPFever Discord](https://discord.gg/DfMxFUQZCR).

## Feedback and bug reports

Describe what you did and what happened, and attach:

- the newest `logs\launcher-….log`, next to MPFever.exe;
- the `%TEMP%\mpfever` session folders.

Details are in README.txt.

## Support

Enjoying MPFever? Support the project or thank its author on [Ko-fi](https://ko-fi.com/knighthd).
