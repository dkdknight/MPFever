-- MPFever: the commands that a mod's interface sends by itself (0.6.13).
--
-- Every command a game's interface sends goes through MPFever (mpfever_ui.script.lua): it is shipped and applied once on
-- every game at the same step. That is right for what the player asked for. But some mods send commands from their
-- interface by themselves (their guiUpdate, or a react.onStep / onStepTimer of their windows): a scan after a load, a timer
-- that renames the lines, a toll counted every 5 s, the decorations of a stop... Their interface runs on every game, so
-- every game sent the same command and it was applied once per player: two sets of decorations, the toll paid twice, the
-- lines renamed back and forth (Line Roles, Modern Bus Shelter, Road Lighting, Sydney Harbour Bridge, Organic Towns, PYT,
-- dévers, Optimized Traffic Lights, Smart Lanes, Auto Color Lines' first sweep, Blueprint, Just More Weather's clock).
--
-- Such an automatic command is now sent by one game only:
--  - with one company for everybody: the host's game;
--  - with one company per player: the game of the company that owns what the command changes (a line, a vehicle, a
--    company's money), else the host's.
-- Mods that finish a player's own job from their guiUpdate (Auto Signals adds the signals after this player placed one,
-- Parallel Tracks, Express & Local, Simply Relocate...) only do it on the game of that player: an automatic command within
-- M.WINDOW seconds of this player's own activity is sent as before, except for the mods known to act on what every game
-- sees (M.STRICT). The callback of a command not sent here is never called (the mod waits, as for a command in flight).
--
-- Pure decisions (tests/test_modauto.py runs them through lupa); the interface hook gives the facts.

local M = {}

-- seconds after this player's own action during which an automatic command still counts as theirs
M.WINDOW = 15

-- mods whose automatic commands act on the whole world (every game sees the same thing and would send the same command):
-- one game only, whatever this player did (patterns on the source file, lower case, "/" separators)
M.STRICT = {
	{ pat = "/line_role_renamer/", name = "Line Roles" },
	{ pat = "/mbs_lignes/", name = "Modern Bus Shelter" },
	{ pat = "/ksl_lights.script", name = "Road Lighting" },
	{ pat = "/shb_cleanup/", name = "Sydney Harbour Bridge" },
	{ pat = "/organic_towns/", name = "Organic Towns" },
	{ pat = "/pyt/pyt_toll", name = "PYT - Pay Your Tolls" },
	{ pat = "/pyt_mw/", name = "PYT - Mega Warehouse" },
	{ pat = "/blueprint/library", name = "Blueprint" },
	{ pat = "/gui/acl_picker", name = "Auto Color Lines" },
	{ pat = "/gui/otl.script", name = "Optimized Traffic Lights" },
	-- (Real Track Cant: its monthly bonus only; its cant is computed after this player's own track builds, on their game)
	{ pat = "/devers/devers_bonus", name = "Real Track Cant (bonus)" },
	{ pat = "/gui/rct/", name = "Just More Weather (clock)" },
}

-- a source file path as debug.getinfo gives it ("@C:/Users/Public/mod.io/10640/mods/6419266/content/...")
function M.norm(src)
	return tostring(src or ""):gsub("\\", "/"):lower()
end

-- is this a mod's file (not the game's own, not MPFever's)?
function M.isModSource(src)
	local s = M.norm(src)
	if s == "" or s:find("mpfever", 1, true) then return false end
	return s:find("/mods/", 1, true) ~= nil or s:find("/mod.io/", 1, true) ~= nil or s:find("/workshop/content/", 1, true) ~= nil
		or s:find("staging_area", 1, true) ~= nil
end

-- a short name for the logs: the mod's folder (its id, or its mod.io number) and the file
function M.label(src)
	local s = M.norm(src)
	local mod = s:match("/mods/([^/]+)/") or s:match("/workshop/content/%d+/([^/]+)/")
	local file = s:match("([^/]*)$") or s
	return mod and (mod .. ":" .. file) or file
end

-- the known mod (M.STRICT) of a list of source files, or nil
function M.strictOf(sources)
	for _, src in ipairs(sources or {}) do
		local s = M.norm(src)
		for _, k in ipairs(M.STRICT) do
			if s:find(k.pat, 1, true) then return k.name end
		end
	end
	return nil
end

-- Decide what to do with a command a mod's interface sends.
-- f: { auto = bool (sent by itself, not in answer to this player), mod = bool (from a mod's file), strict = name or nil,
--      role = "host"/"client"/other, separate = bool, owner = "mine"/"theirs"/nil (the company owning arg 1),
--      idle = seconds since this player's own last action (nil: none yet) }
-- returns "send" or "drop", and the reason
function M.decide(f)
	if not f.auto or not f.mod then return "send", "not automatic" end
	if f.role ~= "host" and f.role ~= "client" then return "send", "no session" end
	if not f.strict and f.idle ~= nil and f.idle <= M.WINDOW then return "send", "this player's own job" end
	if f.separate and f.owner == "mine" then return "send", "this player's company owns it" end
	if f.separate and f.owner == "theirs" then return "drop", "another company owns it: its game sends it" end
	if f.role == "host" then return "send", "the host's game sends it" end
	return "drop", "the host's game sends it"
end

return M
