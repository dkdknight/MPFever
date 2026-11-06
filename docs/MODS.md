# MPFever and mods

Every player of a session needs **the same mods, in the same version** as the host. MPFever checks it:

- In a lobby, the multiplayer page lists the mods of the host's savegame. The ones to fix come first, in red:
  - **missing**: not installed on your PC (MPFever installs it from the game's Mod Hub);
  - **other version than the host's**: installed, but its files differ from the host's (update it, or ask the host to);
  - **incompatible**: known to break a session.
- In the host's lobby, a player whose mods differ shows as « (different mods) ».
- A player with a missing mod or another version cannot load the host's game. The page says which mods to install or update.

The version is compared from the mod's files (their paths, sizes and the contents of its scripts), found where the game installs mods: mod.io (`C:\Users\Public\mod.io`), the Steam Workshop and your own mods folder. A mod whose folder MPFever cannot find is not compared; the game still says whether it is installed.

**The game's DLCs are not mods but count the same way** (0.6.9): the Deluxe edition's upgrade pack and the pre-order pack put their animals, people and vehicles in the world of the PC that owns them only. Every player needs the same DLCs; the lobby shows a red warning when they differ.

> **TPF3-MP is incompatible with MPFever.** It is another multiplayer mod: turn it off in the mods of the savegame (when loading it) before hosting or joining with MPFever.

## Most mods just work

Vehicles, wagons, trams, buildings, stations, depots, bridges, streets, tracks, assets, maps, sounds and interface mods change nothing by themselves: they work as long as everybody has the same version.

A mod with a **script** can act on the game by itself. In November 2026 we read the scripts of the **83 most downloaded script mods on mod.io** (and of a few others seen in reports) to see what each one does in a session. The list below says what we found. "Checked by reading" means we read its code, not that we played with it for hours; the mods marked **seen working** were also played in sessions.

## The mods we checked

### Work in multiplayer

| Mod | Notes |
|---|---|
| Auto Line Namer | **Seen working** ([Discussion #118](https://github.com/dkdknight/MPFever/discussions/118)). Since 0.4.0 only the host's game renames, and the names apply on every game at the same step ([#58](https://github.com/dkdknight/MPFever/issues/58)). With one company per player, it names the lines of the savegame's first company only. |
| Auto Color Lines | Same as Auto Line Namer for colours. Since 0.7.0 its first sweep of the existing lines (option 3) is sent by one game only. |
| Auto Assign Terminals | Same mechanism for the terminals. If you edit a line while it is being updated, your edit may be undone (on every game alike, no desync). |
| Visual Auto Namer, Improved Destination Displays | Same mechanism (names from the host's game). |
| Auto Signals | **Seen working**. Adds signals after you place one: only on your game, and the other games replay them. |
| Automatic Signal Spacing, Automatisches Gleisvorfeld | Same as Auto Signals. |
| Parallel Tracks, Parallel Roads | **Seen working** (Parallel Tracks). The parallel track is built by your game and replayed by the others. |
| Auto Bridges, Express & Local Rail Stations | Same. Express & Local: a station placed during a long pause (more than 10 s before the game runs again) may get no track fans. |
| Auto Track Connector | Works. With one company per player the new track belongs to the savegame's first company. Two players using the tool at the same moment share one selection (the mod keeps only one). |
| Overpass Builder, Move It, Roadform, MZ Gleisset 3.0, Undo! | **Seen working** (Overpass Builder). Tools: their builds are replayed on every game. Undo!, one company per player: undoing a town house's demolition is paid by the savegame's first company. |
| Road&Rail Station Expander, Underground Cargo Station, Industry Tram Access, Bus And Truck Bay | Window or tool edits, replayed on every game. |
| Advanced Station Configuration Tool | Since 0.7.0 widening a station (it changes the station's file) is replayed as such; before, the other games kept the narrow station. |
| Simply Relocate | Since 0.7.0 its move (the building replaced by another file) is replayed as such; before, the move stopped halfway. Its "pick up" mode may still be refused on the other games when you place the building long after picking it up. |
| No Collision (Build Anyway) | Its builds are replayed with the same settings (errors ignored). To confirm in a session. |
| Auto City Bus Lines, Town Transit Planner | Every step is a click: works, a little slower (each stop waits for the others' games). Town Transit Planner's undo list is the host's after a reload. |
| Doubleclick To Edit, Easy Terminal Assignment, Where's the Problem? (Line Diagnostics), Timetables, Real Financial Statements, Supply Chain Manager, Better Minimap, Train Auto Horn, Dark UI, Track & Road Build Info | Interface, or game logic that is the same on every game. |
| Export Hub, Station CAPACITY, No Terraforming Reputation Loss, Industry Evolution, Realistic Seat Capacity, Vehicle Capacity Multiplier, All Available from 1900, Large Map Sizes, More Simulation Speeds | Game logic decided the same way on every game, or data changed at load. Industry Evolution, one company per player: the tasks are paid by the savegame's first company. |
| Station and vehicle mods with scripts (Rail Vehicle Assets, CRH EMU Maintenance Depot, Seaplane & Land-Water Hub, Land Fish Farm, Elevated Curved Train Station, Curved Railway Station, Bigger Stations, All Stations...) | Their construction scripts give the same result on every game. |
| cmf BB 27000 / BB 60000 packs, SNCF signals | The same on every game. With one company per player, the rebuilt locomotive assets belong to the savegame's first company. |

### Made compatible in 0.7.0 (to confirm in your sessions)

These mods sent commands **from their interface by themselves** (a timer, a scan after a load). Each player's game sent the same command, and it was applied once per player: two sets of decorations, a toll paid twice, lines renamed back and forth. Since 0.7.0 such a command goes from **one game only**: the host's, or with one company per player the game of the company that owns the line or vehicle it changes.

| Mod | Before 0.7.0 |
|---|---|
| Line Roles (Auto Rename & Colors) | Every game renamed and recoloured the lines and their vehicles every 10 s (with one company for everybody). |
| Modern Bus Shelter | Every game added its own decorations to each stop. |
| Road Lighting | Every game sent the same lamp fixes after a load. |
| Sydney Harbour Bridge | Every game removed the pieces of a bulldozed bridge (the others' removals could crash the game). |
| Optimized Traffic Lights | Every game re-timed every optimized light after a load, each with its own traffic counts. |
| Smart Lanes | The map pass, the bus lights and the automatic re-timing ran on every game. A pass right after your own build may still be sent by two games. |
| PYT - Pay Your Tolls | The tolls were paid once per player. |
| PYT - Mega Warehouse | The camps were rebuilt and the cargo binned once per player. |
| Blueprint | Players' different libraries replaced each other for ever. The host's library is now the session's. |
| dévers | The monthly bonus was paid once per player. |
| Cargo & Passenger Station Range | During "apply to all", each game rebuilt its stations at other steps. |
| Just More Weather | Its people's life rhythm and snow paralysis changed people on one game only (debug commands): they are off in a session. Its clock is set by the host's game. |
| Organic Towns | Every game created its own towns and buildings. Now one game does. Its growth steps that use the game's town development command are skipped in a session (that command develops towns differently on every PC). |

### Made compatible in 0.7.1 (to confirm in your sessions)

| Mod | Before 0.7.1 |
|---|---|
| Advanced Station Builder | After each station it builds the station anew (so that tracks can be joined to it by hand), then joins its throats and puts up their signals, from its game script's interface. Those builds were made on the builder's game only: the other games kept the station as first placed, and the checks reloaded the game a few seconds after every station. They are now shipped to every game like a player's build. |
| Improved Destination Displays | Its vehicle names were refused on every game, so it sent them again every 2 s for ever: the game got slower and slower with many vehicles ([#128](https://github.com/dkdknight/MPFever/issues/128)). The names now apply, and a name a vehicle already has is no longer sent. With one company per player, it names the vehicles of the host's company only. |

### To check, or to avoid

| Mod | Status |
|---|---|
| Town Zoning | **To check.** It fills free plots with the game's town size command. If that command picks houses at random as the town development command does, the games' towns would differ. |
| Shopping Mall and Auto Dealership | **To check.** With its default efficiency, the production is drawn at random when the mall is built: the same on every game, but maybe not after a player joins (if the game draws it again at load). |
| Industry Upgrades | **Works, but** the deliveries of its last 2 seconds are lost on a player's game at a resynchronisation, and an order can then complete at another moment there. |
| Wind turbine assets (ingo) | Visual only: the rotor model can differ between games. |
| Auto Road Upgrade | **Avoid in multiplayer.** Its script upgrades streets by itself, on each game at its own moments ([#119](https://github.com/dkdknight/MPFever/issues/119)). It is no longer listed on mod.io. |
| TPF3-MP | **Incompatible.** Another multiplayer mod: turn it off in the savegame's mods. |
| No costs (the game's own mod) | Works since 0.6.7. |

Something wrong with a mod in this list, or a mod missing? Tell us in the [issues](https://github.com/dkdknight/MPFever/issues) or on [Discord](https://discord.gg/DfMxFUQZCR).

## What MPFever shows in the lobby

| Shown as | Meaning |
|---|---|
| *(nothing)* | Models, vehicles, buildings, streets, interface, or game data changed at load. No risk known, as long as everybody has the same version. |
| **made compatible** (green) | A mod that used to break sessions; MPFever makes it work. |
| **untested script** (orange) | The mod has a script that acts on the game by itself. It may work, or make the games drift apart: MPFever then reloads the host's game for everybody. |
| **incompatible** (red) | Known to break a session. Turn it off for multiplayer. |

## How MPFever handles mods' scripts

- **Line names, colours and line updates sent by a mod's simulation script** are taken from the host's game only and applied on every game at the same step, like a player's command. The other games drop their own (0.4.0). Expert setting: « Mods' line names, colours and terminals sent by the host only ».
- **A build replayed for another player** is announced to the mods' scripts as not made by a player on that game, so a mod that answers a player's build (adds signals, fences...) does it once, on the builder's game (0.4.0). Expert setting: « Replayed builds shown to mods as made elsewhere ».
- **A command a mod's interface sends by itself** (from its guiUpdate, or from a window's step) goes from one game only: the host's, or the game of the company that owns what it changes. A command sent within 15 s of your own action is still sent by your game, for the mods that finish your own job (Auto Signals adds the signals after you placed one); the mods known to act on the whole world (the list above) never do (0.7.0, `MPFEVER_MODAUTO=0` to turn it off).
- **A command a mod's game script sends from its interface half** (the guiUpdate or guiHandleEvent of a `.gs.lua` script, which runs in another state than the windows) was applied on that game alone. It now follows the same rule as above and is shipped to every game; its callback is answered once it is applied (0.7.1, `MPFEVER_GSMODS=0` to turn it off).
- **A mod's names and colours** go on any entity that has one (a vehicle, a station), not only on lines; a name an entity already has is not sent again, nor the same command while it is on its way, nor a command that changed nothing three times (0.7.1, `MPFEVER_MODANYTARGET=0`, `MPFEVER_MODDEDUP=0`).
- **A mod's debug command** (a person's state, a stock's cargo...) is refused in a session: the engine applies it on one game only (0.7.0).
- **A mod's game script is called at the game's steps only** in a session: the engine also calls it with a time of 0 while a game waits, as many times as that game draws frames (0.7.0, `MPFEVER_MODDT0=1` to turn it off).
- **A construction edited into another file** by a mod's window is replayed with that file (0.7.0, `MPFEVER_REPLACEFILE=0`).

## Mod authors

A few things help your mod work in multiplayer:

- Decide on the game time (`api.engine.getComponent(world, GAME_TIME)`) rather than `os.time` / `os.clock`, which differ on every PC.
- Send world changes from the simulation (`update` / `handleEvent`) when they follow the game, and from the interface only when a player asks for them. A timer in `guiUpdate` runs on every player's PC.
- With one company per player, `api.engine.util.getPlayer()` in the simulation is the savegame's first company on every PC: use the owner of the entity (`PLAYER_OWNED`) instead.
- Avoid the debug commands (`api.cmd.debug`) for game logic.

Get in touch through the [issues](https://github.com/dkdknight/MPFever/issues).
