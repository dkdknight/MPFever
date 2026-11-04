# MPFever – Research notes: game state, determinism and desyncs

This file records what we learned about Transport Fever 3 while building MPFever. It covers how the game keeps its state, why games drifted apart, what has to be synchronised, and where the work stands. It is for contributors; players only need [README.txt](README.txt).

Game build studied: **40425** (Steam; 40420 and 40423 are also supported). Addresses are RVAs of `TransportFever3.exe`. Sections 2 to 5 were written on 40420 (a few addresses are of 40408, marked so); section 6 names the build of each address. They change with every game update, so `native/mpfever_native.cpp` checks the bytes before patching anything, and since 0.3.15 it finds each place again by its signature on a build it does not know (`native/mpfever_sigs.txt`).

Last update: 2026-11-04 (MPFever 0.6.12).

---

## 1. How MPFever keeps games together

MPFever is a **lockstep** mod. Every player runs the full game, and only the players' **inputs** travel:

- construction tool commands;
- vehicle purchases;
- lines and settings.

Each game applies those inputs at the same simulation step. The world itself (towns, industries, people, cargo, money flows) is never sent. Each game computes it again.

This only works if the engine is **deterministic**: the same savegame plus the same inputs at the same steps must give the same world on every PC. When it is not, games drift apart (a *desync*). The host then compares state hashes and, if needed, reloads its own savegame on every client (a *resync*).

The main question of this research was therefore: **what in the engine is not deterministic, and what does that mean for what must be synced?**

---

## 2. What we learned about the engine

### Threads and timing

- **Main thread.** `CGame::Sync` (0x11f650 on 40408, 0x11f690 on 40420, 0x11f6a0 on 40425) runs every 200 ms, whatever the game speed. It swaps the command list: commands added by the interface reach the simulation only at that swap, so any command round trip seen from Lua takes 0.25 to 0.5 s.
- **Simulation thread.** `CGame::RunGameSimLoop` (0x11e210 on 40408) runs one iteration per simulation **step** (200 ms of game time). Before each step it applies the queued commands ("Simulation Thread: Apply Command", 0x9e1c10 on 40408, 0x9e33b0 on 40420).
- **Command kinds.** Commands carry a kind byte:
  - 52 = WorldBuildProposal (every construction tool);
  - 42 = VehicleBuy;
  - 57 = PerformSimulationSteps;
  - 27 = ScriptingSendEvent.

  Kind 52 also covers previews: those are applied "directly", outside the loop.
- **Two game-state objects.** The engine keeps two game-state objects and copies one into the other at every iteration (`GameState::Replicate`, 0x255e60). The interface reads one copy while the simulation writes the other.
- **ECS.** All world data lives in an entity–component system.
  - `ecs::Engine::AddEntity` is at 0x2bb8940 and `RemoveEntity` at 0x2bbc700.
  - Freed entity ids are reused first-in first-out (a deque at engine+0xd8..0xf8). Otherwise a new id equals the size of the entity table. Since 0.5.4 MPFever keeps that queue sorted, and since 0.6.8 a vehicle or line made by a command gets a new id (see 6.1).
  - During play, every add and every remove happens on the simulation thread. So entity ids stay identical across games only as long as every add and remove happens in the same order.

### The "local player"

- The game state holds one word at **+0x20C**: the player (company) this PC plays.
- In co-op mode it is the same on every PC.
- In separate-companies mode each PC wants its own company there, but 59 places in the exe read that word, some of them on the simulation thread. A game playing another company then simulated differently.
- The native module now hooks every one of those 59 reads (`native/sites20c.h`):
  - the simulation thread always reads the savegame's company (the *canon*);
  - the interface (tools, windows, money checks) reads the player's own company.
- **Money checks.** The engine never refuses a build for lack of money: the check is made by the tool in the interface (0xccfbd0). It is redirected to the player's own company.

### Lua

- The game's scripts run in Lua **5.2.2** (towns, industries, construction scripts, game mechanics).
- They run inside the simulation, on the simulation thread.
- See section 3: this turned out to be the main cause of desyncs.

---

## 3. The main cause of desyncs (found 2026-10-11)

**Lua 5.2.2 seeds its string hash randomly in every process.**

- `lua_newstate` calls `makeseed` (0x2fc8fe0), which mixes `_time64()` with a few memory addresses.
- The result is stored in the Lua state (`g->seed`) and used to hash every string.
- So the order in which `pairs()` walks a table with string keys **differs on every PC and every launch**.

The game's scripts walk such tables and act in that order. As a result:

1. towns pick different buildings to grow, upgrade or remove;
2. a new industry placed by the game gets its internal lanes numbered differently;
3. entity ids are then reused in a different order;
4. people, cars, cargo, pollution, happiness and money drift apart.

This is exactly the "towns grow differently" report (issue #7). It was the main cause on that save; the causes found in real sessions since then are in section 6.

**Fix.** At load time, `PatchLuaSeed` in the native module replaces `makeseed` with `mov eax, 'MPFV'; ret`, before the engine creates any Lua state.

- Every game now uses the same seed, so every table is walked in the same order.
- Set `MPFEVER_LUASEED=0` to disable the patch for tests.
- The patch is only applied when the expected bytes are found, so another game build is left alone.

**Results on the savegame of a report (a test save):**

| Test | Before | After |
|---|---|---|
| Two games, no input, compared every few hundred steps | the 32-part hash differs after 1600–1900 steps; the full census differs after 100–400 steps | identical for 5400 steps (18 min of game time), 3 runs out of 3; all 116 714 entity adds and removes in the same order |
| 10-minute session at x4 | towns drift | 61 checks out of 61 identical |
| Separate companies: buy, line, road, stop, resync | drift | in sync, 0 desyncs, 0 refused actions |

### Causes ruled out on the way

- **Wall clock and pauses.** Pauses of 60 s of real time between steps changed nothing.
- **Processor count and thread scheduling.** No effect on that save once the seed was fixed; MPFever never limits CPU cores. (Corrected later: the animals' moves on the thread pool do depend on thread timing and on the PC's pool size; fixed in 0.5.12, see 6.1.)
- **The interface reading game data.** Heavy reads by the census did not change the simulation once the seed was fixed.
- **Money.** Already corrected by the host, and not a cause of divergence.

### Terrain edits and timing (found 2026-10-11, fixed in 0.3.5)

A real game showed the towns drifting right after a client's terrain edit, then a client crash when the host demolished a street bus terminal.

- **The crash** is an engine assertion in `ecs::TransportNetworkSystem::EntityToBeRemoved`, `AreAllNodesEmpty` (0xb6fd30). Decompiled, it does not check vehicles: every node of the removed entity's transport network must have no port left, i.e. no other entity may still be connected to it. With different towns, something of the client's town was still connected to the terminal; the host's removal plan did not include it.
- **The drift.** The terrain tool (`UI::TerrainModifier`) cannot be held like the other tools: it reads back the handle of its command, which a held command leaves empty (that crashed in 0.2.8). So the edit is applied at once at its author's game time, and another game that is already a few steps further applies it late (2 steps in the report). Every terrain edit lowers the reputation of the nearest town, so the towns took that change at different steps.
- **Fix.** The construction menu builds a terrain tool's action through `construction_react_util.getActionParams`; MPFever watches it in the interface. While a player has a terrain tool in hand (or made an edit in the last minute), that game leads: the others stay behind it by twice the overshoot reserve, and get every edit before its time. If two players use one, the more recent user leads.
- **Exact stops, two older imprecisions found on the way.** Approaching an action's time, a game could run on at speed when the action waited just past the barrier. It also asked for its exact steps while the simulation was still running: the interface sees the simulation clock only at the 200 ms handshake, so a clock still for 12 frames proves nothing. Both are fixed: exact steps whenever an action is near, and a stopped simulation means 0.45 s of real time without its clock moving.
- **Checked.** Twelve edits in a row by the host and by the client at x4 all land at the same step on the other game; every check is identical.

### Stops on a street cut by a road (found 2026-10-11, fixed in 0.3.5)

A client crashed (access violation in `ecs::CatchmentAreaSystem::EndModification` → `station_util::GetTerminalPersonEdges`) when the host built a road across a street where the client had put a pair of bus stops.

- **Stop replay.** The stop tool removes the node configurations of the segment's two junctions and puts new ones back (`nodeConfigsToAdd`); the replay removed them and never put any back. Right after each pair of stops, the host had 4 fewer node configurations than the client (`nodeConfigs` part of the check). Fixed: the replay adds the tool's configurations. Replaying the report's two stops on its savegame now gives exactly the client's value.
- **Road across a street with stops.** The tool's native proposal moves the existing stops (edge objects) onto the new segments.
  - A script proposal (`SimpleProposal`) cannot do that. Without the objects, the stops stay on the removed segment and the game crashes in their catchment area.
  - With them, the engine asserts while adding a component the stop already has (`Find(components, compTypeIndex) == components.end()`).
  - A rebuilt native proposal is refused (`lc.segment0 not found`) or, given the node configurations, hangs the game.

  The fix is to rebuild it exactly as a construction placed against a street is rebuilt (`replayNativeStreet`). The removed segments and nodes come from the engine's own removal proposal (`makeSegmentsRemoveProposal`), not from the capture. The tool's node configurations and id maps are added on top (`C.rebuildNativeWithConstruction` with no construction). Checked with the client's road of a later report: the same number of new segments, all the stops kept. If even that is refused, the build is reported as not reproduced and the host's game is reloaded; the script forms are never tried (`C.movesObjects`). Reloading was the first fix, but every such road a player built then vanished.

### Line routes on the map (2026-10-11, fixed in 0.3.7, to confirm in a real game)

`UI::LineViewer::Update` (0x7f7180) draws the lines of one player, looked up in a per-player table (0xad3840), the player being a field of the viewer (+0x28). The viewer is made in 0x29f9d50, whose read of the player word at 0x29f9f14 takes it from an object of the interface's own (not one of the two game states), holding the savegame's company. On a client playing another company, the routes of its own lines flashed and vanished. 0x29f9f14 is now a "UI object" site like the tool factory: off the simulation thread, the savegame's company read there becomes the player's. Each company should see the routes of its own lines only, as in a solo game. A real game showed that this is not enough: the client's routes still flash and vanish. The cause (2026-10-12): the viewer is made **while the game loads**, before MPFever knows the client's company, and it keeps the player it was given. Both line viewers (0x7f7180 reads its player at +0x28, 0x7ff620 at +0x30) build their list of lines with 0x7f5c60(..., player, ...), which asks 0xad3840 for that player's lines. The native module now has a detour on 0x7f5c60: when the savegame's company is asked for on a machine that plays another one, it asks for that machine's company. It cannot be checked by the autotests (no line window is open there). A player's report of 2026-11-04 says a selected vehicle's line route is not drawn again after a resync and flashes about every 5 s: still open (see 7).

### Replays that differ from the tool's build (found 2026-10-12, fixed in 0.3.7)

- **Bulldozed street station (#15).** A pure removal is replayed with the engine's own `makeSegmentsRemoveProposal`, which removes the entrance street but not the station: the station stayed connected to a removed node (`AreAllNodesEmpty` assert). The player's constructions of the tool's `toRemove` (owned by a company) are now added to that proposal's `toRemove`.
- **Signals (#16).** `replayStop` rebuilt the segment with `type 0 / typeIndex -1` and no `distance`: a tunnel became track dug in the ground. The segment's own type, index, distance and decorations are kept.
- **Bulldozer settings (#20).** The tool's `Context` flags are read by the native module from the held command (payload +0x358 gatherBuildings, +0x360 terrain alignment, +0x362 cleanup) and shipped with the build (`deferred <id> <bits>`, bit 32 = known).
- **A road joined to a street with stops (0.3.6 tests).** The street tool takes the stops away (`edgeObjectsToRemove`) and places them again on the new pieces (`edgeObjectsToAdd`, placeholders `-400000000 - k` in the new segment's objects). A script proposal cannot do both in one build: with the placeholders the engine refuses ("Construction impossible"), without them it asserts (`CalcNodeIndex`, fatal). In a script proposal an edge object names its segment by its **rank** in `edgesToAdd` (-1, -2...): the native id (-10) makes the factory throw. The replay builds the street without the stops, then places them again with a stop build on the new segment, found by the positions of its ends.

### Held builds and loads (found 2026-10-12, fixed in 0.3.7)

The native module takes a game state it has never seen for a new game and drops the builds it holds. Its table of known states (16 entries) always replaced entry 0 once full: after 8 loads the two states of one game evicted each other, every iteration looked like a new game, a held build was dropped, and the release count stayed one off (every later build was released at once, #18). The table is now filled in turn, and the mod releases builds by id (`releaseid N`) instead of by count.

---

## 4. Tools built for this research

All of them are off by default and switched on by environment variables of `MPFever.exe --autotest`.

| Tool | Switch | What it does |
|---|---|---|
| Determinism test | `MPFEVER_SCENARIO=det`, `MPFEVER_DET_SCHEDULE=0,20,100,...`, `MPFEVER_DET_PAUSE=s` | Both games load the same savegame paused. They run exactly N steps, then their hashes are compared. This repeats for each value of the schedule. |
| Full census | `MPFEVER_CENSUS=1` (or a list of component types), `MPFEVER_CENSUS_FROM=n`; also the `census` scenario | Dumps every component of every entity (about 60 component types) to `census_<tag>.txt` in the session folder. The transport network is summarised (a full dump took 26 min). Render-only components are left out. |
| Entity watch | `MPFEVER_ENTWATCH=1`, `MPFEVER_ENTLOG=1` | Hooks AddEntity and RemoveEntity, counts them per thread and can write the full sequence (`entseq.txt`) to compare between games. |
| Word-read counters | always on, reported in `native.log` | Counts the readings of the local-player word per site and per thread. |
| Static analysis | (offline) | `re/retool.py` (pefile and capstone) and a Ghidra headless project, used to decompile the engine functions named here. |

A census comparison script (host vs client, per component type, first differing fields) was used alongside. It will be added to `tests/` once cleaned up. The tools added since 0.3.5 (session replay, free-id log, entity log with call stacks, diagnostic build) are in 6.15.

---

## 5. What must be synchronised

### Co-op (one company for everybody)

With the seed fixed (and the engine fixes of section 6), **only the players' inputs need to be synced**. Everything else follows from them:

| Data | How it stays the same |
|---|---|
| Roads, tracks, stations, depots, buildings, bulldozing | The construction command is replayed at the same step (kind 52, native replay) |
| Vehicles, lines, assignments, line settings | The action is replayed at the same step |
| Game speed, pause | Set by the host for every game |
| Towns (growth, buildings, happiness), industries (production, new industries), stocks | Computed by the game: deterministic since the seed fix |
| People, cars, cargo, routes | Computed by the game: deterministic |
| Pollution and noise (emission grid), traffic | Computed by the game: deterministic. Replayed segments get their builder's emitter since 0.5.7. MPFever set the towns' sensitivity to pollution, noise and congestion to 0 until 0.6.9; the game's own values are back since |
| Money | Computed by the game, and corrected by the host as a safety net; a replay's cost difference is booked on the builder's company (0.3.15) |
| Names of new stations, lines, vehicles | In each game's language: the host's names are sent to every game (0.5.14), a corrected part of the checks (0.6.1) |
| Terrain | Copied cell by cell by the native module (tools whose replay is not exact) |
| Ground paint | **Not synced yet** (cosmetic, no effect on the simulation) |

The state hash and resync stay as a safety net: a player's own mods, a different game build or a lost message can still break determinism.

### Separate companies (one company per player)

The world is shared. What differs is **who owns what** and **who pays**. Census component types:

| Category | Components / data | Rule |
|---|---|---|
| **Per company** (one per player, the same in every game) | `PLAYER` and its `ACCOUNT` (money, loans), `LOG_BOOK` (income and costs), `PLAYER_OWNED` on stations, depots, edges, vehicles and lines, `COLOR`, `NAME` of the company | Created by an action (company join) at the same step everywhere; every action carries its company; money is checked per company by the host |
| **Owned objects** | `LINE`, `TRANSPORT_VEHICLE`, `VEHICLE_DEPOT`, `STATION`, `STATION_GROUP`, `MAINTENANCE_COST` | Built or bought with the owner the player chose; maintenance charged to that owner |
| **Shared world** | `TOWN`, `TOWN_BUILDING`, `INDUSTRY`, `STOCK_LIST`, `SIM_PERSON*`, `SIM_CARGO`, `SIM_ENTITY_*`, `MOVE_PATH`, `LAND_VEHICLE`, `EMISSION_GRID`, `BASE_EDGE`/`BASE_NODE` of the street network, `TRANSPORT_NETWORK`, `WORLD`, `GAME_TIME`, `GAME_SPEED` | Computed by the game, the same as in co-op |
| **Game scripts that assume one company** | loans, contracts (subventions), company growth, achievements, notifications | On the simulation side they see the canon company only. Loans are reimplemented per company in MPFever. Contracts run per company since 0.3.3 (the script's handlers are wrapped with the owner as player), the company window's actions since 0.4.4, ranks since 0.3.15, achievements since 0.6.8 (not verified in a game). See 6.9. |
| **Interface only** (may differ per PC, must never reach the simulation) | the local-player word (+0x20C) as the interface sees it, tool owner, money check, windows, money popups (account positions of other companies) | Redirected by the native module; cleared before the interface copy |
| **MPFever data** | shared station fees (`shares.txt`), company list (`companies.txt`) | Replayed as actions; part of the hash |

### Known remaining differences (no effect observed)

- **`BASE_NODE_CONFIG` crosswalk order.** On about 50 junctions the crosswalk lists hold the same elements in a different order. This comes from the C++ side, probably a container keyed by pointers. No effect on traffic was observed, and the hash compares counts only. A census of 2026-10-27 shows it on about 40 junctions right after a load, then stable.
- **`GAME_TIME.tickCount`** (offset 4) counts rendered frames, not steps, so it differs from one PC to another. Corrected: the simulation does use it. Some of its seeds came from it (they use the step count since 0.3.14) and the tools stamped it into each segment's age (TickEpoch, fixed in 0.5.3). See 6.1 and 6.2.
- **One rare divergence.** Seen once, around step 1200 of a long census run (ids of pollution emitters, tiny float differences in town pollution). Not reproduced since. The animals' moves found later (6.1) change octree node ids and so later ids: a possible explanation, not proven.

---

## 6. Discoveries since 0.3.5

What was found from 2026-10-11 (0.3.5) to 2026-11-04 (0.6.12), by topic. Each entry gives when it was found, the version that fixed it and, when there is one, the `MPFEVER_*` switch that brings back the old behaviour (set it on every game). Addresses are of build 40425 unless another build is named. [CHANGELOG.txt](CHANGELOG.txt) tells each fix in full; since 2026-10-30 every fix has its own test in `tests/`.

### 6.1 Desync causes: entity ids and engine order

The ids of new entities are the most fragile part of the world. When two games give one new entity two different ids, it sorts differently in every list kept in id order. Vehicles, persons and towns then drift apart minutes later. Most causes below end that way.

- **Replacement maps (2026-10-13, 0.3.9).** A real tool's proposal can replace segments in ways that do not follow the geometry (a line split at other points, a junction node moved about 3 m). It then carries six maps (`new2oldSegments`, `old2newSegments`, `new2oldNodes`, `old2newNodes`...). Replays without them made the engine treat the replaced parts as new: other costs, other entity adds and removes, so the free-id queues parted. The capture now ships the maps, and such builds are replayed as a native proposal (`replayNativeStreet`). The engine fills the maps itself for simple geometric replacements, which is why the early tests passed.
- **Engine order fixes (2026-10-18, 0.3.14, ported from TPF3-MP, MIT; the person orders come from silver2127's TPF2 Multiplayer).** The native module sorts by entity id six batches that the simulation reads in the engine's history order: the ids a modification frees before they join the queue, the vehicles waiting for track before the seeded shuffle, the persons and cargo leaving buildings, the persons arriving on foot, the destination candidates, and the vehicles at a line stop. `MPFEVER_NOORDER=1`.
- **tickCount seeds (0.3.14).** Some simulation seeds came from `GAME_TIME.tickCount`: the shuffle above, a vehicle variant pick, town and street development. tickCount also counts the frames a game stands still. These seeds now use the step count.
- **More order fixes (2026-10-24, 0.5.0, from TPF3-MP).** The platform visit order and candidates, and the persons' "needs path" order. A 40-minute soak at x4 stayed in sync without them, so they are off by default (`MPFEVER_ORDER2=1`). The town street field fix of the same set is on since 0.5.3 (6.2).
- **Free-id queue order (2026-10-25, 0.5.4).**
  - The free ids are a `std::deque<int>` at engine+0xd8. `AddEntity` (0x2bc0260) pops the front; the only append is at 0x2bc1a23.
  - A replay that freed or reused ids in another order than the tool (a stop placed again, a refused dry run) left the queue in another order: the next vehicle was 350772 on one game and 353349 on the other.
  - The native module sorts the queue after each append, so the engine gives the smallest free id. `MPFEVER_NOFREEMIN=1`.
  - Side effect (2026-10-28): a freed id can be reused two steps later. A computer company's demolished stop had its id taken by an octree node two steps later, and the interface's log book asserted on both games. Computer companies keep their stops since then (`MPFEVER_AIDEMOLISH=1` demolishes them). A quarantine for recently freed ids is an idea, not done.
- **Fresh ids for vehicles and lines (2026-11-02, 0.6.8, #109).**
  - For a few steps now and then, the two games' free-id sets differed (the engine had freed another object of its own). A vehicle bought or a line created then got another id (84704 against 62904).
  - Now, when `AddEntity` is called from `CustomEntityCreate` (return 0x9e0298) or `LineCreate` (0x9e24bb), it gives a new id, never a freed one. `MPFEVER_FRESHIDS=0`, `MPFEVER_FRESHSCRIPT=0`.
  - Helper entities (octree nodes, parts) keep queue ids: giving them fresh ids crashed both games (`entity == c.entity` in `ecs::Replicator::Apply`).
  - Not proven between two PCs. A later two-PC report still had 2 results out of 98 with split ids, so the size of the entity table itself had parted there: an entity made on one PC only. Open.
- **Animals moved on the thread pool (2026-10-28, 0.5.12).**
  - `ecs::AnimalMoveSystem` (0xa960e0) moves the animals in chunks of 128 on `ThreadPool::LoopImpl` (0xa931a0). Each animal writes its model, then queries the octree while other threads are writing it.
  - Each chunk's mt19937 is seeded from the chunk's start and the step, and the number of chunks is capped at the pool's size, which depends on the PC.
  - Octree nodes are entities, so one different move gave every later entity (persons, town buildings) another id, and `script:towns` drifted 10 to 20 minutes into a session.
  - The native module changes the chunk size (`mov r9d,0x80` to 0x7FFFFFFF), so the engine takes its own one-thread path. Cost: about 8 % of simulation speed at x4 with 1222 animals. `MPFEVER_NOANIMALSERIAL=1`.
  - A first theory (results merged in thread-completion order) was wrong: the pool merges in chunk order. Frozen animals (tests only) also kept the games in sync.
- **Road entry order (2026-10-30, 0.5.14, ported from TPF3-MP's road-entry-order, MIT).** Each road edge keeps its vehicles and persons in arrival order (`EdgeUseManager::Add` 0x2569150, `AddRange` 0x2567480). Trucks queued at a stop take their places from it, and on two games they stood 0.2 m apart. The lists are now kept in entity order. `MPFEVER_NOROADORDER=1`.
- **Industry demand history (2026-10-30, 0.6.0, found and fixed first by TPF3-MP, MIT, ported).** The industries' demand scheduler (the planner lambda of `OnIntervalStep`, 0x1513f0) keeps one history per game-state buffer. Which one an interval reads depends on how each game's batches were cut (stands, pauses, saves, speed), so new industries spawned at other steps or on one game only. Every game now gives the scheduler one history for the world. `MPFEVER_INDUSTRYDEMAND=0`, log `MPFEVER_INDUSTRYLOG=1`. Not settled: one 90-minute test drifted with it, one without it did not; later runs with it were in sync.
- **Platform decision flag (2026-11-02, checked only).** TPF3-MP copies a vehicle's "ask for a platform" byte (MovePath +0x70) between the two game states. Build 40425 already copies it (0 differences in every test), so it is off (`MPFEVER_DECISIONSYNC=1`).

### 6.2 Desync causes: time, ages, mathematics, saves

- **Segment ages, TickEpoch (2026-10-25, 0.5.3).** Every street and track segment has a `TICK_EPOCH` {time, commandIndex, subIndex}. It can be read from Lua but is not in the tealdef. The towns' parcels compare it (`parcel_util`, 0x91e670: the older segment keeps the parcel). The tool stamped the GUI's tickCount on the builder's game, Lua replays got 0, and a build in a pause took a counter that grows during the pause: 275 of 1380 segments differed in a test save. A splice at `street_util::AddToEngine` (0x2603af4) now gives every new segment the step it is added at, town streets included. `MPFEVER_NOTICKEPOCH=1`; hash part `ages`. This was also the town drift of 0.3.12 with the builder leading at x2/x4 (it comes back with tick epochs off), so "responsive builds" work at every speed since 0.5.9.
- **Town street field cache (on since 0.5.3).** `StreetField::At` answers every point of a 50 m square with the answer for the first point asked there since the load. So whatever one game's tools asked changed its towns' street angles. It is now computed for each point. `MPFEVER_NOTOWNFIELD=1`.
- **Windows mathematics (2026-10-24, 0.5.1).** `ucrtbase.dll` gives other last bits on different Windows builds (22621 against 26100: 392 of 200 000 `pow` results, plus `atan2`, `asin`, `acos`, `sinh`, `cosh`, `exp2`, `log2f`...). The game imports these functions, and Lua's `^` is `pow`. The native module points 30 imports at its own functions (`native/mpf_math.cpp`, fdlibm/musl algorithms, within one or two units in the last place). `MPFEVER_MATH=0`; `MPFEVER_MATHDLL=<ucrtbase copy>` gives one game another Windows' math. A 25-minute test with two different ucrtbase copies stayed in sync on a world without mods: a precaution, not the main cause.
- **Save clean-up (2026-10-25, 0.5.3).** The game's save handler (0x9e1d0c) calls 0xbb11f0, which removes empty `TerrainTileBrush` components from the world of the game that saves. Games save at different moments (autosaves), so the call is NOP'd. `MPFEVER_SAVECLEANUP=1`.
- **Script draws per call site (0.3.16, #51).** MPFever's deterministic `math.random` counted all the draws of one game time together. Something drew at every frame of a pause, so later draws differed between games. Each call site (file and line) now counts its own draws.
- **Batches of no step (2026-10-27, 0.5.10).** The game scripts' update runs once per step with dt 0.2, and with dt 0 in a batch of no step. A game standing at a stop point made such calls while the others ran on, and a subsidy was completed one step sooner there. The native stop point removed most of these stands. Skipping the call (`MPFEVER_STANDSKIP=1`) made things worse (4 of 17 tests drifted) and stays off.

### 6.3 Desync causes: late and reordered actions

A build applied even a few steps late on one game is enough for people, towns and vehicles to drift within minutes (proven in 0.3.8 with the same build held and not held).

- **Engine stalls (2026-10-26, 0.5.6).** A step can take 10 to 13 s on a big map (lane modifier builds, industry extensions). The interface saw no handshake, took its exact-steps request for lost and asked again: 3 steps asked 5 times ran 15 steps, and the held builds landed 4 to 8 steps late. A request is now given up only once the engine is proven idle since it, else after 30 s.
- **Replay sent too soon (0.5.6).** A replay sent while the engine was still finishing a step landed one step late, with no warning (34 of 147 replays of one session were sent that way). It now waits until the engine is seen still or the exact steps end at its time. `MPFEVER_SENDSTILL=0`.
- **Paused turns (0.5.1 for builds, 0.5.6 for every action).** In a pause every build has the same game time. Each game applied its own at once and the others' when they arrived. The host now hands out turns, and every game applies paused builds, actions (line edits, purchases, mod commands) and company joins in that one order. `MPFEVER_PAUSEDORDER=0`, `MPFEVER_ACTTURNS=0`, `MPFEVER_JOINTURNS=0`. A check in a pause compares only games at the same turn (`MPFEVER_TURNCHECK=0`).
- **Same step (2026-10-26, 0.5.7).** Builds of two players stamped with one step were applied with each game's own first. They now go in player order. `MPFEVER_SAMESTEP=0`.
- **Two players at one place (0.5.7, removed in 0.5.12, #91).**
  - A tool computes its build at the click, and the build is then held about 2 s; another player's build landing meanwhile changed the place.
  - From 0.5.7 such held builds were dropped and replayed on every game. But a tool marks itself busy when it builds (the stop tool sets tool+0x2c8 before `Add`, function 0x595150), and only the engine's answer frees it. That answer cannot be made up (the engine asserts on a build it never applied), so the tools went dead.
  - Since 0.5.12 builds are applied as their tool computed them (`MPFEVER_RESTALE=1`: the 0.5.11 way), and a real clash reloads the host's game. A rare variant was seen: another player's industry extensions landing between a click and its release.
- **Slow captures (0.3.12, PR #43).** A street through a town takes seconds to capture (1.7 s, 28 town buildings). It counted as refused 150 frames after its release, so the others stopped holding for it and built it a step late. It now counts as refused only after 4 handshakes with the simulation as well, and never while a capture waits to be shipped.
- **A margin of one step (2026-10-31, 0.6.4).** An action that reached a game with one step to spare could be applied 4 steps late: the host's next clock moved the native stop point on before the simulation took the queued event. A queued action now holds the stop point one step before its time until the simulation answers. `MPFEVER_QHOLD=0`.
- **Waiting for an announced build (2026-11-02, 0.6.9).** The wait was 1800 frames: 30 s at 60 fps, only 12 s at 150 fps. A slow builder's build then landed 6 steps late. The wait now also lasts at least 60 s of real time. `MPFEVER_NATWAITSECONDS`.
- **A late build after a newer one (2026-10-30, 0.5.14, #96).** A late build is no longer built when this game has built something at a later step since: the two would land in another order, and a late street replacement made the engine assert. The host's game is reloaded instead. `MPFEVER_LATERESYNC=0`.
- **Company joins (0.5.14).** The host created a joining company a few steps late, so its entities got other ids. A join now holds the games until the company exists everywhere (`MPFEVER_JOINHOLD=0`). The A/B test did not reproduce the old difference: unproven.
- **Old messages after a load (2026-11-03, 0.6.10).** A player's own quick save and load was taken for a resync's load, and every message since was applied again. Builds and actions stamped before the loaded save's time are now left out. `MPFEVER_STALEDROP=0`.
- **"Slow PC mode" did the opposite (2026-10-31, 0.6.2, #104).** `MPFEVER_ADAPTAHEAD=1` shortened the stamp distance (7 to 10 steps instead of 16 at x4). It now adds a third.
- **Vehicles bought together (0.3.10, #35, #36).** The purchase script also runs while game time stands still, so a standing game made several purchases at one step that a running game made a step apart. Now one purchase per step, kept in the saved state (`MPFEVER_OLDBUY=1`). In a pause, the actions after a purchase or a line creation wait for its answer (`MPFEVER_OLDPAUSED=1`).

### 6.4 Desync causes: builds never shipped, or applied twice

- **Replay counts (0.3.6, 0.3.21, 0.5.1, 0.5.13).** A game counts the replays it expects at a game time, and takes its player's next native build at that time for one of them. A count that is never used therefore turns the player's own build into "a replay": never shipped, built on its own game only. Causes found: actions that make no build were counted (0.3.6, #12); refused station dry runs (0.3.21, #64); paused window actions that fail (0.5.1, `MPFEVER_PAUSEDUNUSED=0`); the industry window's "extend" (2026-10-28, 0.5.13). `makeCreateIndustryExtendProposalCmd` only computes the proposal it shows and builds nothing; players had clicked it about 160 times in one session (`MPFEVER_EXTENDCOUNT=1`).
- **Build signatures in a pause (2026-10-30, 0.6.1, #102).** A captured build identical to the action just applied is the engine applying it twice (a double slip switch, 0.3.8), so it is not shipped. The signature held counts only, so in a pause any construction made after another player's one matched. It now holds each construction's file and place, and a match is used once. `MPFEVER_SIGCON=0`.
- **Builds during a resync (0.5.0, #81).** A build made on a game that had already loaded the host's save stayed on that game only. Every game now refuses its player's builds while a resync runs. `MPFEVER_RESYNCBUILDS=1`.
- **Already built (0.5.1).** A construction built during a resync's pause was in the save and was also replayed: two headquarters. A construction stamped before the save that already stands at its place is not built again. `MPFEVER_ALREADYBUILT=0`.
- **Saved actions past their time (0.5.2, #84).** A save could keep a session's action past its time; it was applied at every load (a vehicle sale crashed the game). Such actions are dropped. `MPFEVER_KEEPSTALE=1`.
- **A save made during a build (0.5.1).** A resync save made in the frame a build was applied crashed both games later (`count <= cap`). The save now waits for builds under way (10 s at most). `MPFEVER_SAVEQUIET=0`.
- **Actions that reach the wrong entity (0.3.16, 0.5.6, 0.5.14).** What an action creates is known on every game by a key. The key was the action's uid alone, and the uid counter restarts at every load while the keys stay in the save: an old line's update reached a new line and every game crashed (#53). The key is now the uid plus the stamp. A vehicle command naming an entity that is not a vehicle on a game asserted there; it is skipped (`MPFEVER_ARGKIND=0`). Lists of vehicles travel as references, like single vehicles (`MPFEVER_REFLISTS=0`).

### 6.5 Desync causes: one game has what the other has not

- **DLCs (2026-11-02, 0.6.9).** The Deluxe edition's upgrade pack and the pre-order pack activate themselves on the PCs that own them. Their animals, people, vehicles and landmarks then exist in that world only, and the games make other entities. It was the main cause of #109 (one player without the packs, the others with both). The launcher compares the DLCs, and the lobby shows a red warning; the host can still start. `MPFEVER_DLCS` overrides the list in tests.
- **Game languages (0.5.14 to 0.6.11; #97, #101, #102, #105, #121).** Each game names new stations, lines and vehicles in its own language, and the subsidies' script keeps each title translated. A name changes nothing in the simulation, but the checks compared them. Now: the host's names go to every game and `names` is a corrected part (`MPFEVER_NAMESYNC=0`, `MPFEVER_NAMESCHECK=1`); subsidy titles are left out of the hash (`MPFEVER_SUBNAMES=1`); `lines` and `vehicleState` are not compared while names differ; and a new entity's name counts only from the check after it was first seen (`MPFEVER_NAMEFRESH=0`).
- **Mods that decide by the clock (2026-10-22, 0.4.0).** Line mods (Auto Line Namer, Auto Color Lines, Auto Assign Terminals) decide in their simulation update from `os.time`/`os.clock`. Their commands now come from the host's game only and are applied everywhere at one step (`MPFEVER_MODHOST=0`). Replays were also announced to the scripts as player builds, so a mod that answers a player's build (Auto Signals) acted on every game; the mods' scripts are now told that a replay was not made by a player there (`MPFEVER_MODEVENTS=0`). Mods whose scripts build by themselves (Real Track Cant, #96) are not supported.
- **Another game build or a missing native module.** Two game builds drift apart by themselves; the players are told since 0.4.4. A game with an old or missing `winhttp.dll` measures nothing (`ages` "off"): since 0.6.5 a part a game does not measure is not compared (#111, `MPFEVER_UNMEASURED=0`), and the launcher warns before the game starts.

### 6.6 Engine facts

- **Game builds.** 40408 (the first one studied), 40420 (2026-10-09), 40423 (2026-10-22), 40425 (stamp 0x6ad9ce10, known since 0.5.1). Since 0.3.15 each native place is found by a signature that must match exactly once (`native/mpfever_sigs.txt`, made by `tools/mksigs.py`). A feature stays off if one of its places is missing. Structure offsets are still those of 40420. In 0.4.1 we found the signature file had never been shipped: on 40423 every hook was off, and the games drifted after a few builds.
- **Batches and the native stop point (0.5.10).** A command added between swap n and swap n+1 is applied at the start of batch n+1 (`MPFEVER_BATCHLOG=1`). The steps function (0x1593e0) reads the game speed to size each batch. The native stop point clamps that batch to a step the mod writes in `native_stop.txt`: a game runs at speed up to the step and stops exactly there, with no extra handshake (`MPFEVER_STOPPOINT=0`). The barrier keeps a reserve for the overshoot: held exactly at the barrier, two games ran at half speed at x4.
- **Command payload (40420).**
  - The kind byte is at payload+0x9b8: 12 GameAddPlayer, 21 JournalBookAsset, 27 ScriptingSendEvent, 42 VehicleBuy, 52 WorldBuildProposal, 57 PerformSimulationSteps.
  - Context fields: player +0x36c, gatherBuildings +0x358, checkTerrainAlignment +0x360, cleanupStreetGraph +0x362, refund time-out +0x364, cost mode +0x3d0, ignoreErrors +0x3d1, playerInitiated +0x3d2.
  - Proposal fields (from the Lua binding at 0x22c5200): terrainAlignSkipEdges 0x1e8, segmentTags 0x228, toRemove 0x240, toAdd 0x258 (stride 0xE48, player +0xE38), old2new 0x270, parcelsToRemove 0x2b0, terrain 0x2d8.
- **Game scripts' thread pool (found 2026-10-04).** The `GameScriptSystem` pool getter gives the scripts a pool of their own only when the PC has fewer than 8 hardware threads; otherwise they run in parallel on the shared pool, which is not deterministic. The native module patches it to a pool of its own with one worker (found by pattern). Limiting the game's cores was tried and rejected.
- **Money popups.** The pre-iteration function ends with `ClearPositions(world, player)` (0xccfdb0 on 40420) for the local player only. MPFever clears the other companies' account positions itself (0.3.1).
- **Vehicle wear (2026-11-02, 0.6.9).** The maintenance update (`TransportVehicleSystem`, 0xb837f0) wears a vehicle only if its owner equals [system+0x2c], the savegame's company; repair applies to all. The other companies' vehicles stayed at 100 % for years. The `jne` at 0xb839ba is NOP'd. `MPFEVER_ALLWEAR=0`. Part layout: purchaseTime +0x30, maintenanceChange +0x38, maintenanceState +0x3c, stride 0x60.
- **Owner filters in the interface.**
  - The map's icon manager (`HudIconManager::PreemptiveOctreeTraversal`, 0x67b790 on 40420, worker 0x674570) skips entities of another owner; MPFever lets shared stations through (0.4.4, `MPFEVER_NOHUDSHARE=1`).
  - The stop tool's snap drops segments of another player (`IsOwnedByOtherPlayer`, 0x6110b0 on 40423; fixed in 0.5.0, `MPFEVER_NOSTOPSNAP=1`). The street and track builders have filters of their own (0x5f9fb0, 0x5fa3fd, 0x5fd500 on 40420).
  - The tools get the savegame's player once, when the interface is made (StreetBuilder +0xc0, TrackModifier +0xa0); fixed in 0.3.14 (`MPFEVER_NOTOOLCO=1`).
- **Speed clamp (0.4.5).** The game's speed buttons ask for min(speed, estimated maximum) again at every frame. The lockstep's waits brought the estimate down to 1, so x2 and x3 fell back to x1. The estimate is not applied in a session. `MPFEVER_SPEEDCLAMP=1`.
- **Industry connection (0.6.10, after TPF3-MP, MIT).** When an industry appears, the game connects it to the roads: 0.9 to 1.1 s on a big world, with every game frozen. Most of that is `BitmapRasterizable::Fill` (0x91a560), which sets bits one at a time. The native module fills whole words and gets the same bitmap. `MPFEVER_FASTSPAN=0`.
- **Station group expiry.** A deleted stop's icon stays about 80 s at x1 in the game without MPFever too: an empty station group expires 20 game days (of 4000 ms) later.
- **Engine problems without MPFever.** A script that bulldozes a dead-end street with `makeSegmentsRemoveProposal` can assert `AreAllNodesEmpty` (TransportNetworkSystem.cpp:635). `makeTownDevelopAtCmd` is seeded from the C library's `rand()`, which is seeded by the clock, so MPFever refuses it in a session (0.3.14).
- **Income.** In `economy/cargo_income.script`, a fare is incomeFactor x difficulty x straight-line distance (plus 8x the climb); passengers also x (0.5 + the vehicle's price factor). There is no time or speed factor, so short town lines earn little.
- **Saves and dumps.** A `.sav` is one zstd frame. The game writes `c0000025` crash dumps by itself at loads, Steam events and quit; MPFever counts a crash only when the log has no "Normal shutdown" (0.5.0).
- **Without display (0.5.8).** The game uses SDL2 and Vulkan. Skipping `CRenderer::Render` (0x304640), muting OpenAL and pacing `CCore::UpdateTime` (0x27441c0, which busy-spins up to 250 fps) with a sleep gives a hidden server game. A graphics card is still needed (Vulkan 1.1).
- **Steam client.** The growing freezes seen in October 2026 came from the Steam client (Remote Play connections; Steam's `steamui.txt` logs "SteamUI thread frame stalled"), not from MPFever.

### 6.7 Script API facts

- `api.engine.getComponent` results point into the engine's storage. Kept across frames, they go stale when that storage grows (a vehicle bought), and reading them crashed the game. Copy what must outlive the frame.
- There is no `BASE_EDGE_TRACK` component: a track is a `BASE_EDGE` without `BASE_EDGE_STREET` (until 0.5.1 no company could connect to another's open tracks because of this).
- `api.engine` refuses new members ("no writable member"); replacing existing ones works.
- `LaneConfig.transportModes` reads are 0-based, but writes are shifted by one (measured once at load).
- `SimpleStreetProposal.EdgeObject` has an undocumented writable `params` field that the engine keeps (a signal's settings). The emitter type is `api.type.EmissionEmitter`. `NodeAndEntity` has no emitter field, so a new node of a replay has none.
- A converted construction's `params` are not writable. `api.engine.util.proposal.createProposalReplaceConstruction(old, params)` replaces a construction the way the engine does.
- In a script proposal an edge object names its segment by its rank in `edgesToAdd` (-1, -2...); a native placeholder id makes the factory throw.
- An engine assertion inside a Lua command factory shows as "Unknown exception" and writes a crash dump without stopping the game.
- `makeVehicleSellCmd` takes a list; `makeEntitySetPlayerCmd(entity, player)` changes an owner. A new `Line.Stop` has an empty `stopConfig.load`: a freight line loads nothing until `load[cargoId+1]` is set.
- The game's `require` (base `init.lua`) pushes a file's path on its require stack before loading it and pops it only when the file ran to its end. A mod file that fails stays on the stack, and the game's own `::/gui/...` files are then looked for in the mod's folder: the game crashes at start (0.3.13, MPFever's menu files restore the stack).
- The game's GUI Lua forbids new globals. `app.restart()` (a change of the game's language) stops the `--script` application script (#103). `SaveGameInfo.path` is always empty (#80); `app.getUserDataFolder()` gives the folder. Lua cannot open paths with non-English letters (#59): the session folder uses the 8.3 short path.
- The game's town script ignores every build that is not player-initiated: `town_util.getProposalStats(proposal, data, playerInitiated)` returns no town statistics when the flag is false (no reputation effect of its trees, terrain or buildings). A replay must pass the tool's flag (MPFever's replay forms keep the captured `true`).
- `town_util.getTownState(townsState, town)` fills missing fields of a town's state in place, among them an idle marketing campaign (`marketingInitiatedTimestamp = 0`, `marketingParams = { durationMs = 0, lineCostFactor = 0.5 }`); the town's next update (`applyEventDecay`, every 120 steps per town) drops an idle campaign again. Any code path that touches a town (a build's town statistics) therefore changes the script state's shape without changing what it means: MPFever hashes an idle campaign as none (0.6.12, the 20:37 `script:towns` reload, `MPFEVER_MARKETINGHASH=0`).
- The game's town window asks `getTownHappinessStats(town, 5)` (`town_util.NumLinesForHappinessStats`); its own happiness rating asks it with 0 lines.
- The company window greys its Company tab while the company's progression experience is 0 (`game_mechanics/company/company.tl`); MPFever shows at least 1 (0.6.12, #125, `MPFEVER_RANKTAB=0`).
- Lua's limit of 200 locals in a main chunk: the game allows 7 fewer top-level locals than lupa's lua52 (calibrated 2026-10-16). `tests/test_locals.py` keeps at least 12 free in every file of the mod.

### 6.8 Replays: how each kind of build is reproduced

The rule since 0.4.0: replay a build as the tool's own native proposal whenever possible. Script forms (`SimpleProposal`) are the fallback. A build that cannot be reproduced reloads the host's game at once instead of drifting.

- **Native construction replay (2026-10-06).** A construction against a street cannot be a script proposal: its entrance edge's free node is moved onto the street junction. The replay sends the construction twice in a dry run. It collides with itself and is refused, but the result carries the engine's converted native proposal. The removals come from `makeSegmentsRemoveProposal`, the street part is rebuilt from the capture, and the converted construction's `frozenNodes` are rewritten to the tool's indices (0.3.3). Never send a native proposal with the converted construction but without its street part: the factory hangs the game.
- **Stations, depots, airports, harbours (0.3.13 to 0.6.4).**
  - They are recognised by their construction file, whatever their tracks (#65, #67, 0.3.21), and replayed natively; so are stations with electrified tracks (`simple_catenary`, #46) and road junctions (`street_construction/*.con`, #72, 0.3.23).
  - An airport's signs come from the dry run's converted objects (#50, `MPFEVER_CONEO=0`). A construction's own segment is never rebuilt alone: that left the construction with removed segments and crashed the game when it was selected (#49).
  - An edit that removes station tracks with no new segment goes native (#90, 0.5.12, `MPFEVER_OWNTRACKS=0`). An edit that removes all of them uses the engine's replacement of the station (#97, 0.5.14, `MPFEVER_EDITREPLACE=0`).
  - A construction on a street with stops takes the stops from a dry run, in one build (#109, 0.6.4, `MPFEVER_CONSTOPS=0`).
- **Industries (0.4.0).** A build that reshaped an industry (a road through a farm's field) was rebuilt as a new industry, whose field slots filled themselves: 20 fields came back ("Collision"). It now uses `createProposalReplaceConstruction` with the tool's parameters (`MPFEVER_REPLACECON=0`). A build with two constructions keeps both (`MPFEVER_ALLCONS=0`), and an empty captured frozen-node list stays empty (`MPFEVER_FROZENGUESS=1`).
- **Roads.** A plain road of the tool is replayed natively (0.4.0, `MPFEVER_NATIVEROAD=0`: by script forms it cost a quarter less with the slope tool), without a second street clean-up (0.4.3: the engine merged one more node, `MPFEVER_STREETCLEANUP=1`). Tram tracks added to a street also change the crossings' node configurations, which `replaceSegment` ignores: such a change is replayed from the tool's proposal (0.3.19).
- **Town streets.**
  - The tool's town buildings and old2new map are left out, and every engine gathers the same buildings again (0.3.9).
  - An upgrade of several segments is one merged proposal with the tool's junctions and trees (0.4.5, `MPFEVER_UPGRADEMERGE=0`, `MPFEVER_UPGNC=0`, `MPFEVER_TOWNREMOVE=1`).
  - A single-segment upgrade that moves houses is the tool's own build, because `replaceSegment` levels the ground otherwise (0.6.7, `MPFEVER_TOWNONE=0`). A one-way upgrade whose new segments run the other way round is the tool's proposal too (#107, 0.6.5, `MPFEVER_UPGREV=0`).
  - Upgrades made in a script's context (`checkTerrainAlignment=false`) align the terrain differently from the tool, so a mod that upgrades streets by script desynchronises (test of 0.6.11).
- **Stops (0.3.14 to 0.6.9).**
  - The replay keeps the segment exactly: its own ends, not its nodes' positions (an end can sit up to 0.55 m off its node; `MPFEVER_STOPNODEPOS=1`), the builder's way round (`MPFEVER_STOPREVERSE=0`), the tool's flags with no clean-up (0.3.21), and its owner (0.3.14).
  - Stops on bridges and in tunnels are replayed natively (0.5.1, `MPFEVER_NATIVESTOP=0`); the engine still gives that replay a terrain alignment the tool does not have.
  - Script stops (computer companies, autotests) now put the junctions' configurations back, without the traffic-light phases (0.6.9, `MPFEVER_KEEPNODECFG=0`, `MPFEVER_STOPTLC=1`); before, the engine asserted on the junction.
- **Edge objects.**
  - Signals and stops re-created by a track or street build are now one build with the engine's own objects (0.5.1, `MPFEVER_EOINLINE=0`), counted 10 frames later with nothing built in between (`MPFEVER_EOCHECKHOLD=0`).
  - Signals get their builder's parameters (one way, year; 0.5.7, `MPFEVER_EOPARAMS=0`): 20 one-way signals had made 2063 parts of the track network differ. Every replayed segment gets its emitter (`MPFEVER_EMITTERS=0`).
  - A signal on any track is the signal tool's own proposal (`MPFEVER_NATIVESIGNAL=0`); a signal window's build keeps its "ignore errors" (context bit 8).
- **Lines (0.3.8, #27).** A line's waypoints are rebuilt, and their track travels as a reference (a raw entity id named something else on the other game).
- **Trees (2026-10-25, 0.5.1).** A forest group of the map (thin instances) can be removed only by a native `api.type.Proposal` with `toRemove={group}`; every script form failed. The bulldozer on one tree is replayed as one build: the group removed and its other trees built again (`MPFEVER_TREEONEBUILD=0`).
- **Houses and window edits (0.5.1).** Town buildings bulldozed by a player were taken for a street through a town (`MPFEVER_HOUSEBULLDOZE=0`). Window edits (Drive-in Warehouses) use the engine's replacement (`MPFEVER_UIEDIT=0`).
- **Town statistics with every build (0.5.1).** Each build ships its terrain alignment, trees and rocks removed, terrain brush and new tunnels. A replay whose towns count otherwise asks for a resync at once ("TOWN STATS DIFFER", `MPFEVER_ALIGNCHECK=0`).
- **After a failed replay (0.6.7, #113).** A game that could not reproduce a build leaves out the others' next builds until the host reloads it (45 s at most), instead of building them on a world that is already different. `MPFEVER_FAILHOLD=0`.

### 6.9 One company per player

- **The player word.** The 0.3.4 split (section 2) holds; on 40423 four reading sites needed new signatures (0.4.2). The native module must forget its companies at every new game state. A rejoin that reused the old state's address kept the old player (0.4.4). The canon company was kept into a new game and crashed it 30 s in (#88, 0.5.12). An interface object kept its own copy of the word across a load (0.5.13, `MPFEVER_STALEUI=0`): never reproduced, unproven. Its two lists of 16 game states always gave a new state the first place once full: after about eight games loaded in one process (two states each), the engine's two states took that place in turn, each was "new" at every batch, and the local player was forgotten at every batch until the mod said it again every 400 frames (line routes shown for an instant every few seconds after a resync, tools building for the savegame's company). A new state now takes the oldest place (0.6.12, `native/state_seen.h`, `MPFEVER_SEENFIRST=1`).
- **The game's company functions follow the local word.** `getCompaniesValue`, transported data and the world logs read +0x20c. So values for every company are measured by the host and sent stamped (the 0.6 game options).
- **Game scripts per company.** Contracts since 0.3.3: the game scripts live in the global `game[path]` table, and the `subventions` handlers are wrapped with the owner as player. The company window's actions since 0.4.4 (`MPFEVER_NOCOACTIONS=1`). Achievements since 0.6.8 (`MPFEVER_ACHIEVEMENTS=0`, not verified in a game).
- **Ranks (0.3.15 to 0.6.5).**
  - A company's score is the sum over the towns of population x its share of what was carried x its rating there, taken four times a game month (after TPF3-MP's progression, MIT); experience is the highest score.
  - Company 1 first followed the game's own experience (#63, 0.3.21), which is the world's population and grows with every company's work. Since 0.6.4 it keeps its start and adds its own score (`MPFEVER_RANK1BASE=0`).
  - A rank is never below 1, nor below a rank already taken (`MPFEVER_RANKFLOOR=0`). The game's own "rank reached" notice belongs to the savegame's company and is dismissed on the other games (`MPFEVER_RANKNOTIF=0`).
  - #125 (found 2026-11-04, fixed in 0.6.12): `getTownHappinessStats` returns a native object (userdata), and the ranks read it as a Lua table only: no passenger was ever counted, and companies carrying passengers only scored 0 for good (`MPFEVER_RANKNATIVE=0`: as before). The deliveries statistics are a plain table. Read engine results through field access, never through `type(x) == "table"` tests.
  - Open: the scale (shares keep the other companies below the game's thresholds).
- **Owners of builds.**
  - The builder's engine applies its tool's build natively with the canon company in the command; the native module replaces it in the held command (0.3.1). A capture names the company it is for (0.6.10, `MPFEVER_SHIPCO=0`).
  - An edit of another company's station is replayed for its owner (0.6.10, `MPFEVER_CONOWNER=0`). An upgraded segment gets the tool's owner (#104, 0.6.2, `MPFEVER_UPGOWNER=0`).
  - A station on another company's shared street gives the new street pieces back to that company (0.6.10, `MPFEVER_KEEPSTREETOWNER=0`); a private street cannot be built on (0.6.8, `MPFEVER_STREETVETO=0`).
- **Sharing.** Tracks, stations, stops and depots are open by default (0.5.1, `MPFEVER_OPENDEFAULT=0`), roads too (0.6.2, `MPFEVER_ROADRULE=0`). What belongs to another company is refused the same way on every game (0.3.15, after TPF3-MP's mayTouch, MIT; `MPFEVER_NOOWNERGUARD=1`).
- **One Steam account for two games.** Tests run two games on one PC with one Steam account, so matching a company by Steam id must not take that shared account for one player (0.5.1).

### 6.10 Money and refunds

- **Refund booking (0.3.15, #46, #47).** What a native build cost its builder is shipped with it. Each replaying game books the difference on the builder's company at its next step (`MPFEVER_NOREFUND=1`). Since 0.5.0 the difference goes in the build's own finance line (`MPFEVER_REFUNDOTHER=1`). Nothing is booked with the "No costs" mod (0.6.7, `MPFEVER_NOCOSTREFUND=1`). A resync reloads the game, and the game forgets what can be refunded: a build demolished soon after a resync is not refunded.
- **Refunds of script builds.** The tool's `Context.refundableEntities` has no effect on a scripted removal (0.3.14). A script context's refund time-out (+0x364) is now set like the tools' (#61, 0.3.21, `MPFEVER_REFUNDTIMEOUT=0`), and a replayed stop or signal gets the tool's refund factor (#62, PR #70, 0.3.22, `MPFEVER_REPLACEFREE=0`). Still unexplained: the stop tool charges a fixed multiple of what a replay pays (6x on one save); the booking evens it out.
- **Double booking in a pause (found 2026-11-03, fixed in 0.6.12).** The replays of a pause are booked at the first step after it. The checkpoints of the pause compared the money without these differences: the host corrected the replaying game, and the booking after the pause added the same amount again (exactly the money gap of a local desync). The differences not booked yet now count as booked in the checks and the corrections (`REFUND.heldOf`), and 256 of them are kept instead of 8 (`MPFEVER_REFUNDCHECK=0`).

### 6.11 Performance

- **Builds kept in the simulation's state (0.5.3, 0.5.4, #82).** The simulation kept its last 50 builds in full (4.6 MB), and `state:get()` copies the whole state several times a frame. A build is now dropped once it is shipped, and a game without a lobby keeps none ("solo"). Measured on a test save: the simulation went from x1.4 to x3.7; a 31-module station edited 6 times had fallen from 78 to 43 fps before.
- **The antivirus on file opens (0.5.3).** Each open of a file another process had just written cost about 9 ms of Windows Defender. The exchange files now stay open.
- **Hash cost.** The heavy parts of the check take turns (0.3.8); since 0.6.8 the segments are a group of their own (a 0.26 s hitch on a big world before; `MPFEVER_HASHGROUPS=0`).
- **Big station edits (#25, #54; open).** References are indexed once per action (0.3.8, about 500 times fewer reads), and the launcher's log no longer copies the text at each value (0.3.16: 31 s to 0.06 s). Still open (2026-11-03): one big station edit is a 2.3 MB action (528 segments, 526 nodes), the whole construction is replayed on every game, and each edit holds the games several seconds.
- **Smooth pacing (0.3.15, after TPF3-MP's batch interval, MIT).** Near the barrier the native module scales the engine's batch interval (`guiFrameTime`), so a game slows down instead of stopping. `MPFEVER_SMOOTH=0`.
- **What a big edit costs in Lua (measured 2026-11-04).** Writing the 2.3 MB action as text takes about 0.17 s and reading it 0.03 s (Lua 5.2); each `C.deser(C.ser(...))` copy of it costs about 0.2 s, and the capture and the replay make several. Every replayed build now writes one `LAG` line: how long the game stood at its time, waiting for its data and then for its replay (0.6.12, `MPFEVER_LAGLINE=0`).
- **Where a remote build's time goes (measured 2026-11-04 on the user's test).** The frame rate stays at 55-60 fps for a whole session: what players feel as "slower and slower" is game time spent standing at other players' builds. A tool's build is held 16 steps at 4x (7 at 1x) on the builder's game unless the builder leads; once released, the engine applies it 4 steps (22 to 70 frames) later; the capture then ships it; the others stand at its step until it arrives and is replayed (one engine round trip of 0.25-0.5 s per command; a station edit takes two: the engine's conversion of the construction, refused on purpose, then the build). Small warehouse modules (7 KB) still arrived about 2 s after their announce.
- **The module tool has no tool events (40425).** The module tool of a station's or warehouse's window builds from its own native site (`543cea` on 40425; streets/tracks `4d479f` is the bulldozer's, `5bfe9d` the upgrade tool's, `51c3ac` the construction tool's) and sends no `builder.*` event, so it never got the builder's lead. Since 0.6.12 a build held with no lead tool in hand starts the lead, and the upgrade tool (`streetTrackModifier`) is a lead tool (`MPFEVER_LEADHELD=0`, `MPFEVER_LEADTOOLS=0`).
- **The 1 ms timer (0.6.12).** The launcher asks `timeBeginPeriod(1)`: its `Thread.Sleep(5)` polls lasted 15.6 ms each before (`MPFEVER_TIMER1MS=0`).
- **Leads not tried yet.** Faster save compression (zstd level 1, TPF3-MP); the engine's conversion of a station asked as soon as its build arrives, before the game reaches its step (one round trip less at the stand; it would keep the command result's native `Proposal` across frames, which may point into freed engine memory as `getComponent` results do: not tried); a native injection of replays at their step (no stand at all, see engine-sim-loop notes: the command element left empty crashed it in 0.2.7).

### 6.12 Mods, DLCs and the native module's file

- **Mods in the lobby (0.3.20 to 0.6.7).** The lobby reads each mod's fingerprint and kind (content, interface, data at load, game script); a player with another version cannot load the host's game. Personal (interface-only) mods may differ (0.5.0). Missing mods are installed through the game's Mod Hub (`api.modhub.subscribeModAsync`, as TPF3-MP's lobby does, MIT). A local mod is sent only by the host and only after both players agree (0.5.0; since 0.5.13 only accepted ids from the host, `MPFEVER_HOSTONLY=0`). The game's `staging_area` holds local mods too (0.6.7). Asking the Mod Hub id of a mod that is not installed makes the engine assert slowly (#92).
- **The winhttp.dll proxy (0.5.3, #83).** The proxy exported only the 14 functions the game imports. `cryptnet.dll` delay-imports more WinHTTP functions for certificate revocation fetches and bound to the proxy (error 127), so mod.io's TLS failed on PCs that needed such a fetch. All 88 exports are forwarded now.
- **Smart App Control (0.6.4).** It blocks the unsigned `winhttp.dll` ("Bad Image ... 0xc0e90002"), and MPFever warns. Code signing by SignPath Foundation is prepared (0.6.6); the archives stay unsigned until the project is accepted.
- **Copies not installed by Steam (0.6.3).** A GOG copy reads mods from `mods\release`; joining through Steam is not possible there.

### 6.13 Networking and sessions

- **Steam P2P (0.5.3).**
  - The host's game listens on Steam (`native/mpf_steamnet.cpp`: Steam's peer-to-peer connections and its Datagram Relay, through the game's own `steam_api`), so no port has to be opened.
  - A player tries Steam and TCP at once and keeps a direct link when there is one. Through Steam it opens 4 more bulk tunnels for the save (Steam limits each connection's rate). Checked between two accounts: resync deltas of 23 to 29 MB in 3 to 18 s.
  - Fixed since: an elapsed time that wrapped round as unsigned gave up the link (0.6.7); the host's game can stay busy longer than 15 s with big saves, so a client waits 40 s through Steam (0.6.8, #115).
- **Resume (0.5.3).** Messages are numbered and acknowledged at both ends; a player who drops for less than 60 s gets what it missed, with no reload. `TcpClient.Close` does not wake a blocked read: shut the socket down first.
- **Save transfer (0.5.0).** Binary parts, one sender per player. On a resync, a delta of the decompressed save (content-defined chunks: 9 to 15 % of the save). A save copied by hand is recognised by its SHA-256. The parts already received survive a reconnection (0.4.0, #60).
- **Router ports (0.6.7).** UPnP is tried from every network adapter and on every WAN service, then PCP and NAT-PMP. Error 718 (MPFever's own mapping left by a crash) is removed and asked again.
- **Host-only messages (0.5.13).** The host no longer passes on the messages only it may send (save, mods, lobby, settings, session).

### 6.14 Computer companies: game facts

- A road maintenance station (`road_maint_station`) has no exit: a bus sent there froze the simulation. Industries have their own street stations, so freight needs no station of its own; small street stops only unload. A straight script road across town blocks is always refused, but a dry run works.
- A modular rail station's tracks run along its local Y axis; a rail depot's exit is a free end of its tracks; a bridge needs a concrete `typeIndex` from `bridgeTypeRep.getAll()`. A garage built on a slope near an industry crashed both games (fixed in 0.5.13 with a level-ground check).

### 6.15 Tools

| Tool | Switch | Use |
|---|---|---|
| Session replay | `tools/recplay.py`, autotest `recplay` | Replays a real session's actions, pauses, speeds and saves on two games, from one of its saves (0.5.3). Actions must be stamped again (running: at or after the future stamp; paused: at the latest clock), and a pause must never be set ahead of a pending action. |
| Action replay | `MPFEVER_SCENARIO=replayfile` | Replays the `act` lines of a player's `in.log` on a copy of the save; `MPFEVER_REPLAYBOTH=1` replays on both games and compares. |
| Free-id log | `MPFEVER_FREEQLOG=1`, `tools/freeq_diff.py` | The free-id queue every 50 steps; gives the first step where two games differ, long before vehicles or towns drift (0.5.9). |
| Entity log | `MPFEVER_ENTWATCH=1 MPFEVER_ENTLOG=1` | Each add and remove with its engine (0 = simulation, 1 = the interface's copy), its step and the game's call stack (0.5.12). Compare engine 0 only. |
| State dumps | `MPFEVER_SDUMP=1` or `all`, `MPFEVER_SDUMP_PERSONS=1` | Game script states, vehicles, lines, names, constructions and persons at each check (`sdump_ring_*.txt`). |
| Census | `MPFEVER_CENSUS=IDS`, `MPFEVER_CENSUS=TICK_EPOCH` | Fast entity id sets; segment ages. |
| Build lines | always on | "build ids" (the ids of each build's segments and nodes) and "build stats" (cost, terrain, removals): they must match across games. |
| Diagnostic build | `diag.txt` next to MPFever.exe | Turns on FREEQLOG, SDUMP=all and STEPLOG in every game a player starts (0.6.4.1). |
| Other logs | `MPFEVER_STEPLOG`, `MPFEVER_BATCHLOG`, `MPFEVER_INDUSTRYLOG`, `MPFEVER_EDGEDUMP` | Exact steps, engine batches, industry scheduler, edges at each check. |
| One game only | `MPFEVER_ENV_HOST`, `MPFEVER_ENV_CLIENT`, `MPFEVER_TOGETHER=1` | Set a switch on one game for an A/B test; make both games act at once. |
| Test gate | `tests/run_all.py`, `tests/check_repo.py` | Every test that needs no game, run by build.bat and by CI on GitHub (0.5.2). |

Test harness lessons:

- Games started from a script's shell are started again by Steam (a "custom arguments" dialog): start test campaigns through `explorer.exe`.
- A test that seems to hang is often an engine assertion with its dialog open: look in the game's `crash_dump` folder first, and check that the interface clock still advances.
- A savegame name with accents hangs the autotest's loader.
- Loading a save renumbers the free-id queue: ids from a loaded save never compare with those of a running world.

---

## 7. Progress and next steps

Done:

- [x] Lockstep of every construction tool, vehicles and lines (0.1 – 0.2)
- [x] Terrain copy, resync from the host's savegame, join while running (0.2)
- [x] Separate companies: registry, per-company money, loans, owners, shared stations with fees (0.3.0 – 0.3.4)
- [x] Simulation and interface split for the local-player word (59 hooked reads) (0.3.4)
- [x] **Main desync cause found and fixed: the Lua string hash seed** (0.3.4)
- [x] Full-state census and entity watch, to find any future divergence quickly (0.3.4)
- [x] In-game MPFever window: players, link and sync state, opened from the pause menu (0.3.4, thanks to SlikerDev)
- [x] Terrain edits at the same step everywhere (terrain tool lead), exact stops at x4 (0.3.5)
- [x] In-game chat (0.3.5, thanks to SlikerDev)
- [x] Lobby in the main menu, then the multiplayer page (0.3.8, 0.3.18)
- [x] Replacement maps; native replays of streets, stations, junctions, industries and town upgrades (0.3.9 – 0.4.5)
- [x] Engine order fixes and smooth pacing from TPF3-MP; native places found by signature after a game update (0.3.14 – 0.3.15)
- [x] Refunds booked like the builder's; ranks, contracts and company actions per company; "one company per player" no longer experimental (0.3.15 – 0.4.4)
- [x] Dedicated server (0.3.12, thanks to SlikerDev), without display (0.5.8), public server list (0.5.9)
- [x] Mods: lobby check, line mods from the host, personal mods, missing mods installed (0.3.20 – 0.5.0)
- [x] Companies: mixed modes, bankruptcy, tolls, open sharing rules (0.5.0 – 0.5.1)
- [x] Paused builds and actions in one order everywhere (0.5.1, 0.5.6)
- [x] The same mathematics on every Windows (0.5.1)
- [x] Segment ages (TickEpoch), town street field, no save clean-up (0.5.3)
- [x] Join through Steam with no port to open, resume after short drops, save deltas (0.5.0 – 0.5.3)
- [x] Free-id queue sorted (0.5.4); fresh ids for vehicles and lines (0.6.8)
- [x] Builds no longer late after engine stalls (0.5.6); native stop point (0.5.10)
- [x] Signal parameters and segment emitters replayed (0.5.7)
- [x] Animals moved in one piece (0.5.12)
- [x] Computer companies, experimental: buses, freight, railways, never bankrupt (0.5.12 – 0.6.4)
- [x] Road entry order, industry demand history (0.5.14, 0.6.0)
- [x] Players in different game languages (0.5.14 – 0.6.11)
- [x] Game rules and game options chosen in the lobby, kept in the savegame (0.5.14, 0.6.0)
- [x] DLC check, vehicle wear for every company, the game's town sensitivities back (0.6.9)
- [x] Tests: `tests/run_all.py` in build.bat and CI (0.5.2), one test per fix (2026-10-30)
- [x] Found that the simulation reads `GAME_TIME.tickCount` (seeds fixed in 0.3.14, segment ages in 0.5.3)
- [x] A lighter continuous check: groups in turn (0.3.8, 0.6.8), `ages` and `buildIds` lanes (0.5.3)
- [x] Per company: contracts (0.3.3), ranks (0.3.15), the company window's actions (0.4.4), achievements (0.6.8, not verified in a game)

Next:

- [ ] Cross-PC sessions still resync now and then with no action to explain it: an entity is made on one PC only (#109, after the DLC and fresh-id fixes). Needs a session with `diag.txt` on both PCs, then `tools/freeq_diff.py`.
- [ ] Station module lag: a big station edit is a 2.3 MB action, the whole construction is replayed on every game, and each module holds the games for seconds. Goal: as smooth as solo (a short delay for one's own build is acceptable if nobody freezes).
- [ ] `script:towns` desync after paused builds (local session of 2026-11-03: three maintenance stations built in a pause, one replay 25 % cheaper and its "build ids" line missing on both games; refunds booked twice in that pause).
- [ ] Rail station edits and track bursts (#126): resyncs after them, "SEGMENT COUNT DIFFERS" twice, "replay refused here" logged for builds that are still built. Needs the host's report.
- [ ] Ranks: every company's score 0 on some players' saves (#125, cause not found); the rank scale with several companies is a design choice still to make.
- [ ] Separate companies: a client's line routes vanish after a resync and flash every ~5 s (report of 2026-11-04; the 0x7f5c60 detour of 0.3.7 is the lead).
- [ ] Stops on bridges: the native stop replay still gets a terrain alignment the tool does not have.
- [ ] Signals on an extended station's own tracks are not rebuilt (#113): resync.
- [ ] The stop tool's price is a multiple of its replay's (booked, not explained).
- [ ] The crash fix of a separate session followed by a shared one in the same game run (0.5.13) is not proven by a test.
- [ ] Industry demand fix: confirm with a long A/B test.
- [ ] A quarantine for recently freed ids (the sorted queue reuses an id at once).
- [ ] Explain the crosswalk order, and fix it if it ever matters
- [ ] Mods whose scripts build by themselves (Real Track Cant)
- [ ] Ground paint
