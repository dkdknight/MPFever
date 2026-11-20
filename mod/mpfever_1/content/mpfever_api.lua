-- MPFever: the public API for other mods (0.8.17, API version 1). The guide for mod authors: docs/MOD-API.md.
--
-- MPFever puts one table in package.loaded["mpfever"] of every Lua state where it runs: the simulation's game scripts, the
-- game scripts' interface half (guiUpdate, guiHandleEvent) and the interface (windows, react plugins). A mod reads it with
--     local mp = package.loaded["mpfever"]
-- and goes on as before when it is nil (MPFever not installed, or an older version). Nothing of it ever raises an error.
--
-- What it tells:
--   mp.apiVersion, mp.version, mp.half ("simulation" or "interface")
--   mp.inSession()         true in a multiplayer session (the same on every game: may be used in the simulation)
--   mp.companyMode()       "shared" (one company for everybody) or "separate" (one per player), nil outside a session
--   mp.companyOf(e)        the company number (1, 2, 3... the same on every game) of a player entity, or nil
--   mp.playerEntityOf(n)   this game's player entity of company n, or nil (entity ids can differ between games)
--   interface half only (nil in the simulation, where every game must decide the same thing):
--   mp.isHost()            this game is the host's (or the dedicated server's)
--   mp.isDedicatedServer() this game is a dedicated server's (it plays no company)
--   mp.myCompany()         the company number of this game's player
--   mp.shouldSend(e)       the game that should send a command a mod sends by itself about entity e (a line, a vehicle, a
--                          construction...): the game of the company owning it with one company per player, else the host's;
--                          true outside a session
--   mp.declare(opts)       { autoCommands = "self", id = "<mod id>" }: this mod decides itself which game sends its
--                          automatic interface commands (with mp.shouldSend): MPFever sends every one of them as it is sent,
--                          without its own rules for mods' automatic commands (mpfever_modauto.lua). Made from the mod's own
--                          file (its folder is taken from the caller), in each Lua state that sends such commands.
--
-- Pure functions over an environment (tests/test_modapi0817.py runs them through lupa); the bridge and the interface hook give
-- the facts. MPFEVER_MODAPI=0: no table, no declaration (as before).

local A = {}

A.API_VERSION = 1

-- (0.9.3, #448) the game's interface state has no rawget: A.declaredOf failed there ("attempt to call global 'rawget'"), so the
-- interface's check of every command a mod sends by itself failed, and each such command left from every game (none of
-- mpfever_modauto.lua's rules). The API's own tables have no metatable: a plain read is the same there.
-- MPFEVER_APIRAWGET=0: as before (the check fails in that state)
local rawget = rawget
if rawget == nil then
	local off = false
	pcall(function() off = os.getenv("MPFEVER_APIRAWGET") == "0" end)
	if not off then rawget = function(t, k) return t[k] end end
end

-- a source file path as debug.getinfo gives it, lower case, "/" separators, without the leading "@"
local function norm(src)
	return (tostring(src or ""):gsub("\\", "/"):lower():gsub("^[@=]", ""))
end
A.norm = norm

-- The root of the mod a source file belongs to: "<id>::/" for a file loaded by its game path, else its folder on the disk
-- (".../mods/<folder>/", ".../workshop/content/<app>/<folder>/", ".../staging_area/<folder>/"), or nil (the game's own).
function A.rootOf(src)
	local s = norm(src)
	if s == "" then return nil end
	local v = s:match("^([^:/]+)::/")
	if v and v ~= "" then return v .. "::/" end
	for _, pat in ipairs({ "^(.-/workshop/content/%d+/[^/]+/)", "^(.-/mods/[^/]+/)", "^(.-/staging_area/[^/]+/)" }) do
		local r = s:match(pat)
		if r then return r end
	end
	return nil
end

-- the mod's id named in a root ("<id>::/") or its folder's name, without a "_<version>" suffix
local function idOfRoot(root)
	if not root then return nil end
	local v = root:match("^([^:/]+)::/$")
	if v then return (v:gsub("_%d+$", "")) end
	local f = root:match("/([^/]+)/$")
	return f and (f:gsub("_%d+$", "")) or nil
end
A.idOfRoot = idOfRoot

-- the declaration covering one of these source files (a mod's files on the stack of a command), or nil
function A.declaredOf(mp, sources)
	local d = type(mp) == "table" and rawget(mp, "_declared") or nil
	if type(d) ~= "table" or #d == 0 then return nil end
	for _, src in ipairs(sources or {}) do
		local root = A.rootOf(src)
		if root then
			local id = idOfRoot(root)
			for _, k in ipairs(d) do
				if k.root == root or (k.id and id and k.id == id) then return k end
			end
		end
	end
	return nil
end

-- env: {
--   half = "simulation" | "interface", version = "0.8.17",
--   role = function() -> "host" | "client" | other (no session), server = function() -> bool,
--   mode = function() -> "separate" | other, companyOf = function(e) -> n | nil, entityOf = function(n) -> e | nil,
--   myCompany = function() -> n | nil (interface), ownerCompany = function(e) -> n | nil (the company owning entity e),
--   gamePlayer = function() -> this game's player entity (one company for everybody),
--   getinfo = debug.getinfo (the declaring mod's file: the caller of mp.declare), log = function(text) }
function A.make(env)
	local mp = { apiVersion = A.API_VERSION, version = env.version, half = env.half, _declared = {} }
	local said = {}
	local function say(key, text)
		if said[key] then return end
		said[key] = true
		if env.log then pcall(env.log, text) end
	end
	local function safe(f, ...)
		local ok, v = pcall(f, ...)
		if ok then return v end
		say("err:" .. tostring(v), "mod API: " .. tostring(v))
		return nil
	end
	local function role() return safe(env.role) end
	local function inSession() local r = role(); return r == "host" or r == "client" end
	local function separate() return inSession() and safe(env.mode) == "separate" end
	local function interfaceOnly(name)
		if env.half == "interface" then return true end
		say("sim:" .. name, "mod API: mp." .. name .. "() asked in the simulation: nil (each game would decide something else)")
		return false
	end

	function mp.inSession() return inSession() end

	function mp.companyMode()
		if not inSession() then return nil end
		return separate() and "separate" or "shared"
	end

	function mp.companyOf(e)
		if type(e) ~= "number" then return nil end
		if separate() then return safe(env.companyOf, e) end
		local gp = env.gamePlayer and safe(env.gamePlayer) or nil
		if gp ~= nil and gp == e then return 1 end
		return nil
	end

	function mp.playerEntityOf(n)
		if type(n) ~= "number" then return nil end
		if separate() then return safe(env.entityOf, n) end
		if n == 1 and env.gamePlayer then return safe(env.gamePlayer) end
		return nil
	end

	function mp.isHost()
		if not interfaceOnly("isHost") then return nil end
		return role() == "host"
	end

	function mp.isDedicatedServer()
		if not interfaceOnly("isDedicatedServer") then return nil end
		return inSession() and safe(env.server) == true
	end

	function mp.myCompany()
		if not interfaceOnly("myCompany") then return nil end
		if not separate() then return inSession() and 1 or nil end
		return env.myCompany and safe(env.myCompany) or nil
	end

	function mp.shouldSend(e)
		if not interfaceOnly("shouldSend") then return nil end
		if not inSession() then return true end
		if separate() and type(e) == "number" and env.ownerCompany then
			local co = safe(env.ownerCompany, e)
			local mine = env.myCompany and safe(env.myCompany) or nil
			if co ~= nil and mine ~= nil then return co == mine end
		end
		return role() == "host"
	end

	function mp.declare(opts)
		if type(opts) ~= "table" then return false end
		local src = nil
		-- (the first Lua function above this one: a call in a tail position leaves no frame of its own)
		if env.getinfo then
			for lv = 2, 8 do
				local okI, info = pcall(env.getinfo, lv, "S")
				if not okI or type(info) ~= "table" then break end
				if info.what ~= "C" and info.what ~= "tail" and A.rootOf(info.source) then src = info.source; break end
			end
		end
		local root = A.rootOf(src)
		local id = type(opts.id) == "string" and opts.id ~= "" and opts.id:lower():gsub("_%d+$", "") or nil
		if not root and not id then
			say("decl:none", "mod API: a declaration from no mod's file (" .. tostring(src) .. "), ignored")
			return false
		end
		if opts.autoCommands ~= "self" then return false end
		for _, k in ipairs(mp._declared) do
			if (root and k.root == root) or (id and k.id == id) then return true end
		end
		mp._declared[#mp._declared + 1] = { root = root, id = id or idOfRoot(root), autoCommands = "self" }
		if env.log then pcall(env.log, "mod API: " .. tostring(id or idOfRoot(root)) .. " decides itself which game sends its automatic commands (" .. env.half .. ")") end
		return true
	end

	return mp
end

-- Put the table in this state's package.loaded["mpfever"] (once per state: a later call keeps the declarations made). Returns it,
-- or nil when MPFEVER_MODAPI=0.
function A.install(env, getenv)
	local off = false
	pcall(function() off = (getenv or os.getenv)("MPFEVER_MODAPI") == "0" end)
	if off then return nil end
	local mp = A.make(env)
	-- (a bridge loaded again in the same state, a new game: the same table, which a mod may hold, with this bridge's facts; the
	-- declarations made are kept)
	local cur = package.loaded["mpfever"]
	if type(cur) == "table" and rawget(cur, "apiVersion") == A.API_VERSION and rawget(cur, "half") == env.half then
		for k, v in pairs(mp) do if k ~= "_declared" then cur[k] = v end end
		mp._declared = cur._declared
		-- (the new functions read the kept declarations through this table)
		return cur
	end
	package.loaded["mpfever"] = mp
	if env.log then pcall(env.log, "mod API " .. A.API_VERSION .. ": package.loaded[\"mpfever\"] ready (" .. env.half .. ")") end
	return mp
end

return A
