-- MPFever companies: the registry of the "one company per player" mode.
--
-- The registry is plain data kept in the simulation half's state (so it is saved with the game and every game agrees on it):
--   reg = { mode = "separate", canon = <entity>, start = <money of a new company>, list = { company... } }
--   company = { id = n, key = "<player>" ("" while nobody has claimed it), name = "...", color = <palette index>, ent = <entity> }
-- Only `ent` (the player entity of the company IN THIS GAME) is local to a machine: entity ids can differ between games, so
-- every message carries the company id (1, 2, 3...) and each game maps it to its own entity.
-- Company 1 is the company of the savegame (the host's); a new player gets a new company the first time its name is seen, and
-- finds it again under the same name after a reconnection (or a later session on the same savegame).
-- A dedicated server (MPFever.exe --server) plays no company: it announces itself with an empty key and leaves company 1 to the
-- player its settings name as the owner (reg.owner, the player's key), or to nobody.
--
-- Mixed modes (0.5.0): a company has players, its members ({ key, sid }...; the first registries had one, its `key`), one of
-- them its chief (`chief`: the player who created it, or whom the others left it to). A player asks to join another company
-- and its chief accepts; a player leaves its company (it gets a new one); two chiefs merge their companies. A company can be
-- gone (`gone` = "bankrupt", "merged", "empty"): its player entity stays in the game, nobody plays it any more. See
-- mpfever_eco.lua for the events that change all this.

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
	for _, c in ipairs(reg.list) do if c.key == key and not c.gone then return c end end
	return nil
end

-- the players of a company: its members, or the one player of a company of the first registries (its key)
function CO.members(c)
	if not c then return {} end
	if type(c.members) == "table" then return c.members end
	if type(c.key) == "string" and c.key ~= "" then return { { key = c.key, sid = c.sid } } end
	return {}
end

-- (the members' list written into the company, before it changes)
function CO.ensureMembers(c)
	if type(c.members) ~= "table" then c.members = CO.members(c) end
	if not c.chief and c.members[1] then c.chief = c.members[1].key end
	return c.members
end

function CO.chief(c)
	if not c then return nil end
	if c.chief then return c.chief end
	local m = CO.members(c)[1]
	return m and m.key or nil
end

-- the company a player plays now (by its key), nil when none (gone companies left out)
function CO.memberOf(reg, key)
	if not reg or type(key) ~= "string" or key == "" then return nil end
	for _, c in ipairs(reg.list) do
		if not c.gone then
			for _, m in ipairs(CO.members(c)) do if m.key == key then return c end end
		end
	end
	return nil
end

function CO.addMember(c, key, sid)
	local list = CO.ensureMembers(c)
	for _, m in ipairs(list) do if m.key == key then return end end
	list[#list + 1] = { key = key, sid = sid }
	if c.left then c.left[key] = nil end
	if not c.chief then c.chief = key end
end

-- takes a player out of its company; its chief role goes to the next member. Returns the member's entry (with its sid)
function CO.removeMember(c, key)
	local list = CO.ensureMembers(c)
	local out = nil
	for i, m in ipairs(list) do if m.key == key then out = table.remove(list, i) break end end
	if c.chief == key then c.chief = list[1] and list[1].key or nil end
	if c.key == key and list[1] then c.key = list[1].key end
	return out
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

-- whether a palette index is free (no company but `except` has it)
function CO.colorFree(reg, ix, except)
	ix = tonumber(ix)
	if not ix or ix < 1 or ix > #CO.PALETTE or ix ~= math.floor(ix) then return false end
	for _, c in ipairs(reg.list) do if c.color == ix and c.id ~= except then return false end end
	return true
end

local function freeColor(reg)
	for i = 1, #CO.PALETTE do
		local used = false
		for _, c in ipairs(reg.list) do if c.color == i then used = true end end
		if not used then return i end
	end
	return (#reg.list % #CO.PALETTE) + 1
end

-- ------------------------------------------------------------------------------------- one Steam account, two players
-- Two games of one PC share a Steam account (every test setup, the autotests included). Their players are then told apart by
-- their names only: a Steam account is "shared" once two different names announced it at the same game time, which is what the
-- announcements of a session's start and of a resynchronisation are (stamped at the session's paused time, the same on every
-- game). The mark is kept with the registry for good. CO.match then never finds a company through that account (else a player
-- who left a company took the company of the other game's player, still in it, and never asked for a new one), and CO.join never
-- renames a member through it. MPFEVER_COSHAREDSID=0: as before (nothing marked, and marks already saved are ignored).
-- (the list holds the accounts as strings: a number that long would lose its last digits as a key of a saved table)
function CO.sharedSid(reg, sid)
	if sid == nil or not reg or type(reg.sharedSid) ~= "table" or os.getenv("MPFEVER_COSHAREDSID") == "0" then return false end
	local s = tostring(sid)
	for _, x in ipairs(reg.sharedSid) do if tostring(x) == s then return true end end
	return false
end

-- A player's announcement (key, Steam account, the act's game time), noted by the simulation before CO.join, on every game in
-- the order it applies the joins: the marks are the same everywhere once the announcements of one time are all applied. Returns
-- true when the account is marked shared now.
function CO.noteAnnounce(reg, key, sid, at)
	if not reg or os.getenv("MPFEVER_COSHAREDSID") == "0" then return false end
	if type(key) ~= "string" or key == "" or sid == nil or type(at) ~= "number" then return false end
	local s = tostring(sid)
	-- (only the announcements of one game time are kept: the next time starts a new list)
	if not (type(reg.announced) == "table" and reg.announced.at == at and type(reg.announced.list) == "table") then
		reg.announced = { at = at, list = {} }
	end
	local list = reg.announced.list
	local marked, known = false, false
	for _, x in ipairs(list) do
		if x.key == key then known = true
		elseif x.sid == s and not CO.sharedSid(reg, s) then
			reg.sharedSid = type(reg.sharedSid) == "table" and reg.sharedSid or {}
			reg.sharedSid[#reg.sharedSid + 1] = s
			marked = true
		end
	end
	if not known then list[#list + 1] = { key = key, sid = s } end
	return marked
end

-- A member written twice in one company: the later entries are dropped, the first one is kept (the chief names a key that is
-- still there). The registries saved by 0.5.1 on one PC have them (the old rename of CO.join gave the other game's member this
-- player's name). This runs in the simulation at every join, on every game: the same registry everywhere. Returns how many.
function CO.dropDuplicates(reg)
	local n = 0
	for _, c in ipairs(reg and reg.list or {}) do
		if type(c.members) == "table" then
			local seen, keep = {}, {}
			for _, m in ipairs(c.members) do
				local k = tostring(m.key)
				if seen[k] then n = n + 1 else seen[k] = true; keep[#keep + 1] = m end
			end
			if #keep < #c.members then c.members = keep end
		end
	end
	return n
end

-- The company of a player, known by its Steam account (`sid`, nil when unknown) and by its name (`key`):
--  1. the company of that name, unless it belongs to another Steam account;
--  2. else (not for the host) the company of that Steam account other than the savegame's (the player changed its name), when there
--     is exactly one, and when that account is not shared by two games of one PC (see CO.sharedSid);
-- nil when the player has no company yet.
function CO.match(reg, key, sid, isHost)
	if not reg then return nil end
	-- (a dedicated server: its game shows the savegame's company, which it never claims)
	if isHost and key == "" then return reg.list[1] end
	-- (a member of a company: gone companies, bankrupt or merged, have no members any more)
	for _, c in ipairs(reg.list) do
		if not c.gone and key ~= "" then
			for _, m in ipairs(CO.members(c)) do
				if m.key == key and (sid == nil or m.sid == nil or m.sid == sid) then return c end
			end
		end
	end
	-- (the host plays the savegame's company: CO.join gives it company 1)
	if isHost then return nil end
	-- the owner named by a dedicated server takes the savegame's company while nobody has it
	local first = reg.list[1]
	if first and not first.gone and #CO.members(first) == 0 and type(reg.owner) == "string" and reg.owner ~= "" and key == reg.owner then return first end
	if sid and not CO.sharedSid(reg, sid) then
		local found, n = nil, 0
		for _, c in ipairs(reg.list) do
			if not c.gone and c.id ~= 1 then
				for _, m in ipairs(CO.members(c)) do
					if m.sid == sid then found = found or c; n = n + 1 end
				end
			end
		end
		if n == 1 then return found end
	end
	return nil
end

-- A player is placed: its company (kept from an earlier visit, see CO.match), the savegame's company when it is the host, or a new
-- one. Returns the company, whether it is new (its player entity must be created), the colour it took (the host's company, see
-- below) and how many members found twice were dropped (CO.dropDuplicates).
-- The company of a known player keeps its members as they are: only the player's Steam account is written in when it was unknown.
-- A member takes the player's name only when the player was found through its Steam account (CO.match, step 2: the same player
-- under a new name, the only member with that account). Before, every other member with the player's account took its name, even
-- when the player was found under its own name: on one PC (two games, one Steam account) the host's announcement after a
-- resynchronisation renamed the client's member of the host's company (joined or merged into) to the host's name, and the client
-- then got a new company, its player entity created on one game only (another resynchronisation followed). The result also
-- depended on the order the games applied the two announcements, which differs between the host and a client.
-- MPFEVER_COSIDRENAME=1: as before (the old rename, and no duplicate dropped).
function CO.join(reg, key, name, isHost, newName, sid, color)
	local old = os.getenv("MPFEVER_COSIDRENAME") == "1"
	local dropped = old and 0 or CO.dropDuplicates(reg)
	local mine = CO.match(reg, key, sid, isHost)
	-- (a dedicated server: nothing to claim)
	if mine and key == "" then return mine, false, nil, dropped end
	if mine then
		if type(mine.members) == "table" and old then
			-- (a new name for a known account: the company follows it)
			for _, m in ipairs(mine.members) do
				if m.key ~= key and sid and m.sid == sid then
					if mine.chief == m.key then mine.chief = key end
					if mine.key == m.key then mine.key = key end
					m.key = key
				end
				if m.key == key and sid and not m.sid then m.sid = sid end
			end
		elseif type(mine.members) == "table" then
			local own = nil
			for _, m in ipairs(mine.members) do if m.key == key then own = m break end end
			if own then
				if sid and not own.sid then own.sid = sid end
			elseif sid and not CO.sharedSid(reg, sid) then
				-- (a new name for a known account: the company follows it, when exactly one member has that account)
				local hit, n = nil, 0
				for _, m in ipairs(mine.members) do if m.sid == sid then hit = hit or m; n = n + 1 end end
				if n == 1 then
					if mine.chief == hit.key then mine.chief = key end
					if mine.key == hit.key then mine.key = key end
					hit.key = key
				end
			end
		else
			if mine.key ~= key then mine.key = key end
			if sid and not mine.sid then mine.sid = sid end
		end
		return mine, false, nil, dropped
	end
	local first = reg.list[1]
	-- the savegame's own company belongs to whoever hosts it, unless it is gone (bankrupt, merged), the host left it, or
	-- other players kept it (mixed modes: the host then gets a new company, as anybody)
	local claim = isHost and first and not first.gone and not (first.left and first.left[key])
		and (type(first.members) ~= "table" or #first.members == 0)
	if claim then
		first.key = key
		first.sid = sid
		if type(first.members) == "table" then first.members = { { key = key, sid = sid } }; first.chief = key end
		-- (the colour the host picked in the menu, the first time it claims the savegame's company)
		local recolor = nil
		if color and color ~= first.color and not first.colorPicked and CO.colorFree(reg, color, first.id) then
			first.color = tonumber(color); first.colorPicked = true; recolor = first.color
		end
		return first, false, recolor, dropped
	end
	-- (a name another account already has: the new company's key carries the account, so that both are told apart)
	local k = key
	if CO.byKey(reg, k) then k = key .. "@" .. tostring(sid or #reg.list + 1) end
	local c = { id = #reg.list + 1, key = k, name = newName or name, color = CO.colorFree(reg, color) and tonumber(color) or freeColor(reg), sid = sid,
		members = { { key = key, sid = sid } }, chief = key }
	reg.list[#reg.list + 1] = c
	return c, true, nil, dropped
end

-- what the state check compares: the same on every game (entities left out)
function CO.signature(reg)
	if not reg then return "none" end
	local t = { reg.mode or "?" }
	for _, c in ipairs(reg.list) do
		local s = c.id .. ":" .. tostring(c.key) .. ":" .. tostring(c.name) .. ":" .. tostring(c.color)
		-- (mixed modes: its players and whether it is gone, when there is something to say)
		if type(c.members) == "table" then
			local ks = {}
			for _, m in ipairs(c.members) do ks[#ks + 1] = tostring(m.key) end
			s = s .. ":" .. table.concat(ks, ",") .. ":" .. tostring(c.chief)
		end
		if c.gone then s = s .. ":" .. tostring(c.gone) end
		t[#t + 1] = s
	end
	return table.concat(t, "|")
end

-- ---------------------------------------------------------------------------------------------------------------- game modules
-- The game's own scripts (shared by every company) are adjusted where they would mix the companies up. They run in the game's Lua
-- states; this is called in each one that needs it (the module tables are shared by the state, so it is done once per state).
-- `req(name)` returns a game module by its file name (company_util.tl...), `logf` writes a line of the log.

-- Level, experience and permits of a company: the game keeps them for the savegame's company only. With a rank of its own
-- (mpfever_progression.lua, `viewOf(entity)` answers { experience, level, potentialLevel } for a company of the registry)
-- each company shows that one, on top of the savegame company's other fields; else every company of the registry reads the
-- savegame company's. `canonOf(entity)` answers the savegame company's entity when `entity` is one of the registry, else nil.
function CO.patchProgression(req, canonOf, logf, viewOf)
	if CO.progPatched then return true end
	local M = req("company_progression_util.tl")
	if not (M and M.getCompanyProgressionState) then return false end
	local orig = M.getCompanyProgressionState
	M.getCompanyProgressionState = function(entity, ...)
		local base = orig(canonOf(entity) or entity, ...)
		if viewOf then
			local ok, v = pcall(viewOf, entity)
			if ok and type(v) == "table" then
				local out = {}
				if type(base) == "table" then for k, x in pairs(base) do out[k] = x end end
				for k, x in pairs(v) do out[k] = x end
				return out
			end
		end
		return base
	end
	CO.progPatched = true
	if logf then logf(viewOf and "companies: each company shows its own rank (the savegame company's progression otherwise)" or "companies: other companies read the savegame company's progression") end
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

-- ------------------------------------------------------------------------------------------------ company window per company
-- The company window's actions (prospection, marketing campaign, greening an industry) send a "Companies" event naming the
-- company by its player entity in the sender's game; MPFever adds the company number (mpfOwner) and each game puts its own entity
-- of that company back. The companies script also runs the pending prospections of getPlayer() only (the savegame's company in the
-- simulation): it now runs them for every company, one call per company, the results merged for its postUpdate.
local COMPANIES = "::/game_mechanics/company/company.script"

function CO.installCompanyActions(env)
	if type(game) ~= "table" then return false end
	local cs = game[COMPANIES]
	if type(cs) ~= "table" or cs.__mpfCo then return cs ~= nil end
	cs.__mpfCo = true
	local oh = cs.handleEvent
	if type(oh) == "function" then
		cs.handleEvent = function(u, state, src, id, name, param, ...)
			if id == "Companies" and type(param) == "table" and param.mpfCo and activeReg(env) then
				local ent = ownerEntity(env, param.mpfCo)
				if not ent then return nil end
				param.companyEntity = ent
			end
			return oh(u, state, src, id, name, param, ...)
		end
	end
	local ou = cs.update
	if type(ou) == "function" then
		cs.update = function(u, state, dt, ...)
			local reg = activeReg(env)
			if not reg then return ou(u, state, dt, ...) end
			local util = api.engine.util
			local prev = util.getPlayer
			local merged
			-- (the engine's players, not the registry's entities: each game learns a new company's entity at its own moment,
			-- the players exist from the same step on every game)
			local players = {}
			pcall(function()
				api.engine.forEachEntityWithComponent(function(e) players[#players + 1] = e end, api.type.ComponentType.PLAYER)
			end)
			table.sort(players)
			if #players == 0 then return ou(u, state, dt, ...) end
			for _, pe in ipairs(players) do
				do
					local ent = pe
					util.getPlayer = function() return ent end
					local ok, r = pcall(ou, u, state, dt, ...)
					util.getPlayer = prev
					if not ok then error(r, 0) end
					if type(r) == "table" and type(r.companyProspectionsToExecute) == "table" then
						merged = merged or { companyProspectionsToExecute = {} }
						for _, x in ipairs(r.companyProspectionsToExecute) do
							merged.companyProspectionsToExecute[#merged.companyProspectionsToExecute + 1] = x
						end
					end
				end
			end
			return merged
		end
	end
	if env.log then env.log("companies: the company window's actions follow their company") end
	return true
end

-- ------------------------------------------------------------------------------------------------ achievements per company
-- (0.6.8, #95) The game's achievements script keeps one state for the game: what concerns a company (income, the vehicles that
-- reach a stop, the builds, the ranks, the contracts) was read for getPlayer() only, the savegame's company in the simulation,
-- and each game unlocks its player's Steam achievements from that state: "achievements only count for player 1". The other
-- companies now have a state of their own (in the savegame company's, field mpfOthers, by player entity), kept by the game's own
-- script with getPlayer() swapped, the same on every game; the world's events (cargo, passengers, towns, landmarks) count for
-- every company; and each game's interface unlocks its own company's. MPFEVER_ACHIEVEMENTS=0: as before
local ACHIEVEMENTS = "::/game_mechanics/achievements/achievements.script"
CO.ACH_ON = os.getenv("MPFEVER_ACHIEVEMENTS") ~= "0"

-- a state object of the game's script for one company's achievements (kept in store[key])
local function achState(store, key)
	return {
		get = function(_) return store[key] end,
		set = function(_, v) store[key] = v end,
		hasEventSubscriptions = function(_) return true end,
		subscribeToEvent = function(_) end,
	}
end

-- the engine's players but the savegame's company, sorted (every game the same)
local function achOthers(reg)
	local players = {}
	pcall(function()
		api.engine.forEachEntityWithComponent(function(e) if e ~= reg.canon then players[#players + 1] = e end end, api.type.ComponentType.PLAYER)
	end)
	table.sort(players)
	return players
end

-- runs fn (one call of the game's script) as company `pe` (getPlayer() answers it), on its own state
local function achAs(state, pe, fn)
	local s = state:get()
	if type(s) ~= "table" then return end
	s.mpfOthers = s.mpfOthers or {}
	local util = api.engine.util
	local prev = util.getPlayer
	util.getPlayer = function() return pe end
	local ok, err = pcall(fn, achState(s.mpfOthers, tostring(pe)))
	util.getPlayer = prev
	state:set(s)
	-- (never the game's script's failure: a company's achievements are only skipped, said once)
	if not ok and not CO.achFailed then CO.achFailed = true; print("[MPFEVER] companies: achievements of company " .. tostring(pe) .. " skipped: " .. tostring(err)) end
end

-- the company an event of the achievements concerns: a player entity, false for every company, nil for the savegame's
CO.achTarget = function(env, id, name, param)
	if id == "TransportVehicleSystem" and name == "OnArriveAtStop" then
		local v = type(param) == "table" and param.vehicleEntity or nil
		local ok, po = pcall(api.engine.getComponent, v, api.type.ComponentType.PLAYER_OWNED)
		return (ok and po and type(po.player) == "number" and po.player >= 0) and po.player or nil
	end
	if id == "apply_command" then
		-- (the company that builds: getPlayer() answers it during a build, see the bridge's replays)
		local ok, pe = pcall(api.engine.util.getPlayer)
		return ok and pe or nil
	end
	if id == "Companies" and name == "OnLevelUp" then
		return type(param) == "table" and param.mpfPlayer or nil
	end
	if id == "Subvention" then
		local uid = type(param) == "table" and param.uid or nil
		local info = uid ~= nil and contractIndex()[uid] or nil
		return info and ownerEntity(env, info.owner or 1) or nil
	end
	return false
end

function CO.installAchievements(env)
	if not CO.ACH_ON or type(game) ~= "table" then return false end
	local as = game[ACHIEVEMENTS]
	if type(as) ~= "table" or as.__mpfCo then return as ~= nil end
	as.__mpfCo = true
	local ou, oh, og = as.update, as.handleEvent, as.guiUpdate
	if type(ou) == "function" then
		as.update = function(u, state, dt, ...)
			local r = ou(u, state, dt, ...)
			local reg = activeReg(env)
			if reg and reg.canon then
				local prog = env.prog and env.prog() or nil
				for _, pe in ipairs(achOthers(reg)) do
					achAs(state, pe, function(ps)
						ou(u, ps, dt)
						-- (its ranks, taken in MPFever's own progression: the game's company growth tells the achievements of
						-- the savegame's company only; the first look takes the rank as it is)
						local mine = ps:get()
						local co = CO.idOfEntity(reg, pe)
						local level = nil
						for _, rec in ipairs((type(prog) == "table" and prog.records) or {}) do if rec.company == co then level = tonumber(rec.level) end end
						if type(mine) == "table" and level then
							local seen = tonumber(mine.mpfRank)
							mine.mpfRank = level
							if seen and level > seen and type(oh) == "function" then
								for l = seen + 1, level do oh(u, ps, "", "Companies", "OnLevelUp", { rank = l }) end
							end
						end
					end)
				end
			end
			return r
		end
	end
	if type(oh) == "function" then
		as.handleEvent = function(u, state, src, id, name, param, ...)
			local reg = activeReg(env)
			if not (reg and reg.canon) then return oh(u, state, src, id, name, param, ...) end
			local t = CO.achTarget(env, id, name, param)
			if t == nil or t == reg.canon then return oh(u, state, src, id, name, param, ...) end
			if t == false then
				local r = oh(u, state, src, id, name, param, ...)
				for _, pe in ipairs(achOthers(reg)) do achAs(state, pe, function(ps) oh(u, ps, src, id, name, param) end) end
				return r
			end
			achAs(state, t, function(ps) oh(u, ps, src, id, name, param) end)
			return nil
		end
	end
	if type(og) == "function" then
		-- (this game's interface: its own company's achievements; its own state of what it last saw, per company)
		local gui = {}
		as.guiUpdate = function(u, state, guiState, ...)
			local reg = activeReg(env)
			local me = nil
			pcall(function() me = api.engine.util.getPlayer() end)
			if not (reg and reg.canon) or me == nil or me == reg.canon then return og(u, state, guiState, ...) end
			local s = state:get()
			local mine = type(s) == "table" and type(s.mpfOthers) == "table" and s.mpfOthers[tostring(me)] or nil
			if type(mine) ~= "table" then return nil end
			gui[me] = gui[me] or {}
			return og(u, { get = function(_) return mine end }, achState(gui[me], "v"), ...)
		end
	end
	if env.log then env.log("companies: the achievements count for every company") end
	return true
end

return CO
