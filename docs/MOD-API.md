# Making a mod work with MPFever

MPFever plays Transport Fever 3 in multiplayer. It works in **lockstep**:

- every player's PC runs the whole simulation;
- only the players' actions travel between them;
- every action is applied on every PC at the same simulation step.

As long as every PC gets the same actions at the same step, the worlds stay identical. If one PC does something the others don't, the worlds drift apart. MPFever notices it within seconds and reloads every PC from the host's world (a "resync").

Most mods need nothing at all:

- **Content mods** (vehicles, buildings, stations, tracks, maps...) just work. The lobby checks that every player has the same mods.
- **Script mods** are watched for the usual problems, and MPFever has rules for many of them (see [MODS.md](MODS.md)).

These rules guess what a mod means from the outside, though, and a guess can be wrong. Since **MPFever 0.8.17**, a mod can ask MPFever directly and say what it does. This page explains how.

## The rules of thumb

1. **Decide on the game, not on the PC.**
   - Use the game time (`api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)`), not `os.time` / `os.clock`.
   - Don't use your own random numbers outside the simulation.
2. **Change the world from the simulation** (`update`, `handleEvent` of your game script) when the change follows the game.
   - MPFever runs the simulation identically on every PC, so such a change happens everywhere at the same step.
3. **From the interface, send a command only when the player asks for it** (a click, a tool).
   - MPFever ships it, and every PC applies it once.
   - A command your interface sends **by itself** (a timer in `guiUpdate`, a `react.onStep`) would be sent by every PC. That's what the API below is for.
4. **With one company per player, use the owner of an entity, not "the player".**
   - In the simulation, `api.engine.util.getPlayer()` is the same company on every PC (the savegame's first one).
   - Read the entity's `PLAYER_OWNED` component instead.
5. **Avoid `api.cmd.debug` for game logic.** It changes one PC's world only, and MPFever refuses it in a session.

## The API

MPFever puts a table in `package.loaded["mpfever"]` of every Lua state where it runs:

- the simulation (`update`, `handleEvent`);
- the interface half of game scripts (`guiUpdate`, `guiHandleEvent`);
- the interface (windows, react plugins).

Always read it at the moment you need it, and do as before when it is `nil` (MPFever not installed, or older than 0.8.17):

```lua
local function mpfever()
    local ok, mp = pcall(function() return package.loaded["mpfever"] end)
    return ok and type(mp) == "table" and mp.apiVersion and mp or nil
end
```

None of its functions ever raises an error.

### Everywhere (same answer on every PC: safe in the simulation)

| Function | Returns |
|---|---|
| `mp.apiVersion` | `1` (raised only if something changes in a way old mods must know) |
| `mp.version` | MPFever's version, e.g. `"0.8.17"` |
| `mp.half` | `"simulation"` or `"interface"` |
| `mp.inSession()` | `true` in a multiplayer session, `false` in a single-player game |
| `mp.companyMode()` | `"shared"` (one company for everybody), `"separate"` (one company per player), `nil` outside a session |
| `mp.companyOf(playerEntity)` | the company's number (`1`, `2`, `3`... the same on every PC), or `nil` |
| `mp.playerEntityOf(number)` | **this PC's** player entity of that company, or `nil` (entity ids can differ between PCs) |

To send a company's number in a message or keep it in your state, use `companyOf`. Turn it back into an entity on each PC with `playerEntityOf`.

### Interface only

In the simulation these functions return `nil`, because each PC would answer differently and the worlds would drift.

| Function | Returns |
|---|---|
| `mp.isHost()` | `true` on the host's PC (or the dedicated server's) |
| `mp.isDedicatedServer()` | `true` on a dedicated server (it plays no company) |
| `mp.myCompany()` | the company number of this PC's player (`1` with one company for everybody) |
| `mp.shouldSend(entity)` | `true` on the one PC that should send a command your mod sends by itself about `entity` (a line, a vehicle, a station, a player...). See below. |
| `mp.declare{ autoCommands = "self", id = "my_mod" }` | tells MPFever your mod decides itself which PC sends its automatic commands. See below. |

### Which PC sends `mp.shouldSend(entity)`

It returns `true` on exactly one PC:

- outside a session: always (your mod does as without MPFever);
- with one company per player: the PC of the company that owns `entity` (an entity with no owner, or `nil`: the host's PC);
- with one company for everybody: the host's PC.

If nobody plays the owner's company at the moment, no PC sends.

## Commands your interface sends by itself

This is the most common problem. Say your mod renames lines every 10 seconds from `guiUpdate`:

- every PC sends the rename, and MPFever applies each one, so the lines are renamed once per player;
- worse, each PC computes the new name from its own state.

MPFever's own rules already send such a command from one PC only. But a rule is a guess: it uses the command's first argument and a 15-second window after the player's own action.

With the API you decide yourself, and MPFever leaves your commands alone:

```lua
-- in your game script's guiInit, or when your interface file loads
local mp = mpfever()
if mp and mp.declare then mp.declare{ autoCommands = "self", id = "my_line_renamer" } end

-- in guiUpdate
local function renameLater(lineId, name)
    local mp = mpfever()
    if mp and mp.shouldSend and not mp.shouldSend(lineId) then return end  -- another PC sends it
    api.cmd.sendCommand(api.cmd.makeEntitySetNameCmd(lineId, name), function() end)
end
```

The command is still shipped by MPFever and applied on every PC at the same step: you only choose **who** sends it.

About `mp.declare`:

- Call it **from your mod's own file**: MPFever finds your mod's folder from the caller. Don't write it as `return mp.declare{...}`: a tail call leaves no trace of your file.
- Pass your mod's id (`id`, the name in your `"<id>::/..."` paths) if your files are also loaded by their game path.
- Call it in each Lua state that sends such commands: once in your game script's interface half, and once in your interface windows if they send commands too. Calling it again is harmless.
- It only covers commands your interface sends **by itself**. What the player clicks is shipped as always.

## Commands from the simulation

Your game script's `update` / `handleEvent` run identically on every PC. You don't need to choose anything: send the command from every PC as you would in single player, and MPFever makes sure it is applied once, at the same step everywhere.

Don't use `mp.isHost()` there. It returns `nil` in the simulation on purpose.

## Testing

- Play a session with two PCs (or two copies of the game: see MPFever's README) and your mod on both. Do what your mod does, then wait for a minute.
- If the worlds drift, MPFever says "resynchronisation" in the chat. The players' report (the « Report a problem » button) names the first thing that differed.
- MPFever logs your declaration in its session folder (`ui_mod.log` for windows, `mod.log` for game scripts): `mod API: <your mod> decides itself which game sends its automatic commands`.

Questions, or a mod that still drifts: [open an issue](https://github.com/dkdknight/MPFever/issues) or ask on the [Discord](https://discord.gg/DfMxFUQZCR) (`#help`).
