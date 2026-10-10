-- MPFever companies: the registry of the "one company per player" mode.
--
-- The registry is plain data kept in the simulation half's state (so it is saved with the game and every game agrees on it):
--   reg = { mode = "separate", canon = <entity>, start = <money of a new company>, list = { company... } }
--   company = { id = n, key = "<player>" ("" while nobody has claimed it), name = "...", color = <palette index>, ent = <entity> }
-- Only `ent` (the player entity of the company IN THIS GAME) is local to a machine: entity ids can differ between games, so
-- every message carries the company id (1, 2, 3...) and each game maps it to its own entity.
-- Company 1 is the company of the savegame (the host's); a new player gets a new company the first time its name is seen, and
-- finds it again under the same name after a reconnection (or a later session on the same savegame).

local CO = {}

-- distinct colours (r, g, b in 0..1); the n-th company takes the first one nobody uses
CO.PALETTE = {
	{ 0.86, 0.20, 0.20 }, { 0.20, 0.45, 0.90 }, { 0.20, 0.72, 0.30 }, { 0.98, 0.62, 0.10 },
	{ 0.62, 0.30, 0.82 }, { 0.10, 0.75, 0.80 }, { 0.95, 0.88, 0.15 }, { 0.95, 0.45, 0.70 },
	{ 0.55, 0.35, 0.18 }, { 0.55, 0.85, 0.15 }, { 0.15, 0.30, 0.55 }, { 0.62, 0.62, 0.62 },
}

function CO.rgb(index)
	local p = CO.PALETTE[((index or 1) - 1) % #CO.PALETTE + 1]
	return p[1], p[2], p[3]
end

function CO.new(mode, canon, start)
	return { mode = mode, canon = canon, start = start or 2000000,
		list = { { id = 1, key = "", name = "", color = 1, ent = canon } } }
end

function CO.find(reg, id)
	for _, c in ipairs(reg and reg.list or {}) do if c.id == id then return c end end
	return nil
end

function CO.byKey(reg, key)
	if type(key) ~= "string" or key == "" then return nil end
	for _, c in ipairs(reg.list) do if c.key == key then return c end end
	return nil
end

function CO.entityOf(reg, id)
	local c = CO.find(reg, id)
	return c and c.ent or nil
end

function CO.idOfEntity(reg, e)
	if type(e) ~= "number" then return nil end
	for _, c in ipairs(reg and reg.list or {}) do if c.ent == e then return c.id end end
	return nil
end

local function freeColor(reg)
	for i = 1, #CO.PALETTE do
		local used = false
		for _, c in ipairs(reg.list) do if c.color == i then used = true end end
		if not used then return i end
	end
	return (#reg.list % #CO.PALETTE) + 1
end

-- The company of a player, known by its Steam account (`sid`, nil when unknown) and by its name (`key`):
--  1. the company of that name, unless it belongs to another Steam account;
--  2. else (not for the host) the company of that Steam account other than the savegame's (the player changed its name), when there
--     is exactly one (two games of one PC share the account: a test setup);
-- nil when the player has no company yet.
function CO.match(reg, key, sid, isHost)
	if not reg then return nil end
	for _, c in ipairs(reg.list) do
		if c.key == key and key ~= "" and (sid == nil or c.sid == nil or c.sid == sid) then return c end
	end
	-- (the host plays the savegame's company: CO.join gives it company 1)
	if isHost then return nil end
	if sid then
		local found, n = nil, 0
		for _, c in ipairs(reg.list) do
			if c.sid == sid and c.id ~= 1 then found = found or c; n = n + 1 end
		end
		if n == 1 then return found end
	end
	return nil
end

-- A player is placed: its company (kept from an earlier visit, see CO.match), the savegame's company when it is the host, or a new
-- one. Returns the company and whether it is new (its player entity must be created).
function CO.join(reg, key, name, isHost, newName, sid)
	local mine = CO.match(reg, key, sid, isHost)
	if mine then
		-- (a new name for a known account: the company follows it)
		if mine.key ~= key then mine.key = key end
		if sid and not mine.sid then mine.sid = sid end
		return mine, false
	end
	local first = reg.list[1]
	if isHost then
		-- the savegame's own company belongs to whoever hosts it
		first.key = key
		first.sid = sid
		return first, false
	end
	-- (a name another account already has: the new company's key carries the account, so that both are told apart)
	local k = key
	if CO.byKey(reg, k) then k = key .. "@" .. tostring(sid or #reg.list + 1) end
	local c = { id = #reg.list + 1, key = k, name = newName or name, color = freeColor(reg), sid = sid }
	reg.list[#reg.list + 1] = c
	return c, true
end

-- what the state check compares: the same on every game (entities left out)
function CO.signature(reg)
	if not reg then return "none" end
	local t = { reg.mode or "?" }
	for _, c in ipairs(reg.list) do t[#t + 1] = c.id .. ":" .. tostring(c.key) .. ":" .. tostring(c.name) .. ":" .. tostring(c.color) end
	return table.concat(t, "|")
end

-- ---------------------------------------------------------------------------------------------------------------- game modules
-- The game's own scripts (shared by every company) are adjusted where they would mix the companies up. They run in the game's Lua
-- states; this is called in each one that needs it (the module tables are shared by the state, so it is done once per state).
-- `req(name)` returns a game module by its file name (company_util.tl...), `logf` writes a line of the log.

-- Level, experience and permits of a company: the game keeps them for the savegame's company only, so every company of the
-- registry reads that one. `canonOf(entity)` answers the savegame company's entity when `entity` is one of the registry, else nil.
function CO.patchProgression(req, canonOf, logf)
	if CO.progPatched then return true end
	local M = req("company_progression_util.tl")
	if not (M and M.getCompanyProgressionState) then return false end
	local orig = M.getCompanyProgressionState
	M.getCompanyProgressionState = function(entity)
		return orig(canonOf(entity) or entity)
	end
	CO.progPatched = true
	if logf then logf("companies: other companies read the savegame company's progression") end
	return true
end

-- The permits of a type of construction ("Already built": the headquarters, the landmarks...) are counted by the game over every
-- construction of the world. Each company has its own: only what the company acting here owns is counted (a construction that
-- belongs to nobody counts for all, as before).
function CO.patchPermits(req, logf)
	if CO.permitsPatched then return true end
	local cu, cm = req("company_util.tl"), req("company_metadata.tl")
	if not (cu and cm and cu.getConstructionDisableCacheData and cu.countUsedConstructionPermits and cm.getKey) then return false end
	local function mine(entity)
		local ok, po = pcall(api.engine.getComponent, entity, api.type.ComponentType.PLAYER_OWNED)
		if not (ok and po) then return true end
		local owner = po.player
		return owner == nil or owner == api.engine.util.getPlayer()
	end
	local origCache = cu.getConstructionDisableCacheData
	cu.getConstructionDisableCacheData = function(allDefs)
		local result = origCache(allDefs)
		if type(result) ~= "table" then return result end
		local data = {}
		local function bump(key)
			local e = data[key]
			if e then e.numBuilt = e.numBuilt + 1 else data[key] = { numBuilt = 1 } end
		end
		local ok = pcall(api.engine.system.streetConnectorSystem.forEachConstructionWithMetadata, cm.getKey(), true, true,
			function(entity, construction, _)
				if not mine(entity) or construction.fileName == nil then return end
				bump(construction.fileName)
				local inst = cm.constructionInstance and cm.constructionInstance.get(construction.persistentMetadata)
				if inst and inst.permitKey then bump(inst.permitKey) end
			end)
		if ok then result.data = data end
		return result
	end
	cu.countUsedConstructionPermits = function(_)
		local used = {}
		pcall(api.engine.system.streetConnectorSystem.forEachConstructionWithMetadata, cm.getKey(), true, false,
			function(entity, construction, constructionId)
				if not mine(entity) then return end
				local okm, meta = pcall(function() return api.res.constructionRep.get(constructionId).metadata end)
				if not (okm and meta) then return end
				local key = cu.getActualPermitKey(construction.fileName, meta)
				if key then used[key] = 1 + (used[key] or 0) end
			end)
		return used
	end
	CO.permitsPatched = true
	if logf then logf("companies: the permits (headquarters, landmarks...) are counted per company") end
	return true
end

-- ------------------------------------------------------------------------------------------------------- contracts per company
-- The game keeps ONE list of contracts (subventions script). In the companies mode, each contract the players accept belongs to the
-- company that accepted it (`mpfOwner` written into the contract when the acceptance arrives; the offers stay common, a declined
-- offer is only hidden from the company that declined it, `mpfDeclined`):
--  * its deliveries are counted only for the lines of its company, its reward (money, the higher income of its lines) goes to it;
--  * the contract cards of a game show the offers and that game's company's own contracts only.
-- The game's script functions live in the global table `game` (by file name, see the game's util.useFn) and are looked up at every
-- call: they are wrapped there, in every simulation state of this script. env = { log, registry() (the companies registry of the
-- simulation), localCo() (this machine's company number, nil while unknown) }.
local SUBVENTIONS = "::/game_mechanics/subventions/subventions.script"
local NOTIFICATIONS = "::/game_mechanics/notifications/notifications.script"
local CARD_TYPE = "::/game_mechanics/notifications/types/subvention_notification.script"
local FAILED_TYPE = "::/game_mechanics/notifications/types/subvention.script"

local function activeReg(env)
	local reg = env.registry()
	return (reg and reg.mode == "separate" and #reg.list > 1) and reg or nil
end

local function ownerEntity(env, co)
	local reg = activeReg(env)
	local c = reg and CO.find(reg, co or 1)
	return c and c.ent or nil
end

local function lineOwner(line)
	local ok, po = pcall(api.engine.getComponent, line, api.type.ComponentType.PLAYER_OWNED)
	return (ok and po) and po.player or nil
end

-- the contracts of the game's script state, by uid: { owner = company, declined = {company = true}, status = 1..4 }
local function contractIndex()
	local idx = {}
	pcall(function()
		local e = api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/subventions/subventions.gs")
		local st = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT).state
		for status, list in ipairs({ st.proposedSubventions, st.activeSubventions, st.completedSubventions, st.failedSubventions }) do
			for _, v in ipairs(list or {}) do
				if v.uid ~= nil then idx[v.uid] = { owner = v.mpfOwner or 1, declined = v.mpfDeclined, status = status } end
			end
		end
	end)
	return idx
end

local function visibleTo(info, me)
	if not info then return true end
	if info.status == 1 then return not (info.declined and info.declined[tostring(me)]) end
	return (info.owner or 1) == me
end

local function wrapContractType(env, t, name)
	if t.__mpfCo then return end
	t.__mpfCo = true
	local oh = t.handleEvent
	if type(oh) == "function" then
		t.handleEvent = function(src, id, ename, param, s, ...)
			if ename == "OnCalcTicketPrice" and param ~= nil then
				local ent = ownerEntity(env, s and s.mpfOwner or 1)
				if ent then
					local n = #param
					local sub, map = {}, {}
					for i = 1, n do
						local p = param[i]
						local okl, lo = pcall(function() return lineOwner(p.lineEntity) end)
						if okl and lo == ent then sub[#sub + 1] = p; map[#sub] = i end
					end
					if #sub < n then
						-- deliveries by other companies' lines are not this contract's
						local r = oh(src, id, ename, sub, s, ...)
						if type(r) ~= "table" then return r end
						local out, any = {}, false
						for k, v in pairs(r) do if map[k] then out[map[k]] = v; any = true end end
						return any and out or nil
					end
				end
			end
			return oh(src, id, ename, param, s, ...)
		end
	end
	-- the money of an accepted, completed or failed contract is booked to getPlayer(): its company's
	for _, fname in ipairs({ "onAccept", "onComplete", "onFailure" }) do
		local of = t[fname]
		if type(of) == "function" then
			t[fname] = function(s, ...)
				local ent = ownerEntity(env, s and s.mpfOwner)
				if not ent then return of(s, ...) end
				local util = api.engine.util
				local prev = util.getPlayer
				util.getPlayer = function() return ent end
				local ok, r = pcall(of, s, ...)
				util.getPlayer = prev
				if not ok then error(r, 0) end
				return r
			end
		end
	end
	if env.log then env.log("companies: contracts of type " .. tostring(name) .. " follow their company") end
end

function CO.installContracts(env)
	if type(game) ~= "table" then return false end
	local sub = game[SUBVENTIONS]
	if type(sub) == "table" and type(sub.handleEvent) == "function" and not sub.__mpfCo then
		sub.__mpfCo = true
		local oh = sub.handleEvent
		sub.handleEvent = function(u, state, src, id, name, param, ...)
			if id == "Subvention" and type(param) == "table" and param.mpfCo and activeReg(env) then
				if name == "onAccept" then
					-- the contract becomes the accepting company's before the game's script moves it to the active ones
					local st = state:get()
					for _, v in ipairs(st.proposedSubventions or {}) do if v.uid == param.uid then v.mpfOwner = param.mpfCo end end
					state:set(st)
				elseif name == "onDecline" then
					-- declined by one company only: the others keep the offer
					local st = state:get()
					for _, v in ipairs(st.proposedSubventions or {}) do
						if v.uid == param.uid then
							v.mpfDeclined = v.mpfDeclined or {}
							v.mpfDeclined[tostring(param.mpfCo)] = true
						end
					end
					state:set(st)
					return nil
				end
			end
			return oh(u, state, src, id, name, param, ...)
		end
		if env.log then env.log("companies: contracts are accepted per company") end
	end
	-- every type of contract (the game's and the mods')
	pcall(function()
		for _, rid in ipairs(api.res.genericRep.getAllOfType("subvention")) do
			local gr = api.res.genericRep.get(rid)
			local ref = gr and gr.data and gr.data.scriptFile
			local path, fname = tostring(ref or ""):match("^([^@]+)@(.+)$")
			local m = path and game[path]
			local t = (type(m) == "table" and fname) and m[fname] or nil
			if type(t) == "table" then wrapContractType(env, t, fname) end
		end
	end)
	-- notifications (this game's own: what its player sees): the cards of the contracts of the other companies are left out
	local okn, nu = pcall(ug_require, "::/game_mechanics/notifications/notification_util.tl")
	if okn and type(nu) == "table" and type(nu.updatePersistentNotifications) == "function" and not nu.__mpfCo then
		nu.__mpfCo = true
		local oup = nu.updatePersistentNotifications
		nu.updatePersistentNotifications = function(nstate, historyByType, update, ...)
			if type(update) == "table" and update.type == CARD_TYPE and activeReg(env) then
				local me = env.localCo()
				if me then
					local idx = contractIndex()
					local keep = {}
					for _, ep in ipairs(update.entitiesAndParam or {}) do
						local p = type(ep) == "table" and ep.param or nil
						if not (p and p.uid ~= nil) or visibleTo(idx[p.uid], me) then keep[#keep + 1] = ep end
					end
					update.entitiesAndParam = keep
				end
			end
			return oup(nstate, historyByType, update, ...)
		end
	end
	local nt = game[NOTIFICATIONS]
	if type(nt) == "table" and type(nt.handleEvent) == "function" and not nt.__mpfCo then
		nt.__mpfCo = true
		local oh = nt.handleEvent
		nt.handleEvent = function(u, state, src, id, name, param, ...)
			if id == "Notifications" and name == "add" and type(param) == "table" and param.type == FAILED_TYPE and activeReg(env) then
				local me = env.localCo()
				local uid = type(param.params) == "table" and param.params.uid or nil
				if me and uid ~= nil then
					local info = contractIndex()[uid]
					if info and (info.owner or 1) ~= me then return nil end
				end
			end
			return oh(u, state, src, id, name, param, ...)
		end
	end
	return true
end

return CO
