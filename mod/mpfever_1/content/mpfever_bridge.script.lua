-- MPFever bridge (v0.8), game script.
--
-- Lockstep "with a barrier": every game runs its own simulation at the session speed, but never runs past the clock
-- of the slowest other player. So when a player acts at game time T, no other game has passed T yet, and each of them
-- applies the action exactly at T, in its simulation script (update is called once per simulation step).
--
-- Player actions:
--  * native construction tools (roads, tracks, stops, stations, depots, bulldozer...): they apply natively, as in solo.
--    The simulation half sees them in the engine event onPreBuildProposal, at the exact step, and ships the proposal;
--    the other games rebuild it at that same game time;
--  * commands issued from Lua windows (vehicle purchase, lines...): held by the UI hook (ui.log), stamped here two
--    steps ahead and applied by every game at that stamp, the originator included.
-- Entity ids are never shipped raw (they differ between games): see mpfever_refs.lua.
-- Without MPFEVER_DIR (game not started by MPFever.exe) the mod does nothing.

local okC, C = pcall(ug_require, "mpfever_common.lua")
if not okC then C = ug_require("mpfever_1::/mpfever_common.lua") end
local log = C.logger("", "mod.log")
local okR, R = pcall(ug_require, "mpfever_refs.lua")
if not okR then R = ug_require("mpfever_1::/mpfever_refs.lua") end
local okCO, CO = pcall(ug_require, "mpfever_co.lua")
if not okCO then CO = ug_require("mpfever_1::/mpfever_co.lua") end
-- companies: the registry of this state (set from the simulation state / the GUI mirror) maps company numbers and player entities
R.coEntity = function(id) return R.CO and CO.entityOf(R.CO, id) or nil end
R.coIdOf = function(e) return R.CO and CO.idOfEntity(R.CO, e) or nil end
local BS, NL, CR, TAB = C.BS, C.NL, C.CR, C.TAB

local STEP = 200          -- game time units per simulation step
local STAMP_AHEAD = 3     -- steps between an action and its application on every game (barrier slack + 1)

local function gameTime()
	local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
	return gt.gameTime
end

local function gameSpeed()
	local gs = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED)
	return gs and gs.speedup or 0
end

-- order-independent hash of a plain Lua value (game script states): tables are hashed as a sum over their entries,
-- so that the iteration order (which differs between Lua states) does not matter
local function valueHash(v, d)
	local t = type(v)
	if t == "number" then
		if v ~= v then return 1 end
		if math.floor(v) == v and math.abs(v) < 1e15 then return C.hashStr(7, string.format("%d", v)) end
		return C.hashStr(7, string.format("%.6g", v))
	elseif t == "string" then
		return C.hashStr(11, v)
	elseif t == "boolean" then
		return v and 3 or 5
	elseif t == "table" then
		if d > 14 then return 13 end
		local acc = 17
		for k, x in pairs(v) do
			-- local counters, not game state: entity revisions (bumped by each game's own component writes) and the
			-- interface clock of the mission script
			if k ~= "revision" and k ~= "guiTimeSeconds" then
				acc = (acc + C.hashStr(valueHash(k, d + 1), tostring(valueHash(x, d + 1)))) % 4294967296
			end
		end
		return acc
	end
	return 19
end

-- game mechanics written as game scripts (their whole state lives in the savegame and must be equal everywhere)
local GAME_SCRIPTS = {
	company = "::/game_mechanics/company/company.gs",
	progression = "::game_mechanics/company/company_progression.gs",
	loan = "::/game_mechanics/finance/loan.gs",
	subventions = "::/game_mechanics/subventions/subventions.gs",
	mission = "::mission/mission.gs",
	gametime = "::/game_mechanics/game_time/game_time.gs",
	industries = "::/game_mechanics/industries/industries.gs",
	towns = "::/game_mechanics/towns/town.gs",
	towncargo = "::/game_mechanics/towns/town_cargo.gs",
	celebrations = "::/game_mechanics/celebrations/celebrations.gs",
}

-- multiset of counts (entity ids differ between games: only the amounts are compared)
local function countsHash(counts)
	local n, total, acc = 0, 0, 0
	for _, c in ipairs(counts) do
		n = n + 1
		total = total + c
		acc = (acc + C.hashStr(23, string.format("%d", c))) % 4294967296
	end
	return n .. "/" .. total .. "/" .. acc
end

-- diagnostic (MPFEVER_SDUMP set): every value of the game script states, one "path = value" per line, sorted, so
-- that two games' files at the same game time can be compared line by line
local SDUMP = os.getenv("MPFEVER_SDUMP")
local sdumps = 0
local function flatten(v, path, out, d)
	if type(v) == "table" and d < 16 then
		for k, x in pairs(v) do flatten(x, path .. "." .. tostring(k), out, d + 1) end
	else
		out[#out + 1] = path .. " = " .. (type(v) == "number" and string.format("%.10g", v) or tostring(v))
	end
end

local function extendedParts(parts)
	local dump = SDUMP and sdumps < 40 and {}
	for name, res in pairs(GAME_SCRIPTS) do
		local ok, v = pcall(function()
			local e = api.engine.system.gameScriptSystem.getEntityForGameScript(res)
			if not e or e < 0 then return "absent" end
			local c = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT)
			if not c then return "absent" end
			if dump then flatten(c.state, name, dump, 0) end
			return tostring(valueHash(c.state, 0))
		end)
		if ok and v ~= "absent" then parts["script:" .. name] = v end
	end
	if dump then
		sdumps = sdumps + 1
		table.sort(dump)
		pcall(function()
			local f = C.IO.open(C.DIR .. BS .. "sdump_" .. string.format("%012d", gameTime()) .. ".txt", "wb")
			f:write(table.concat(dump, NL), NL)
			f:close()
		end)
	end
	-- cargo waiting in buildings (industries, warehouses, stations)
	pcall(function()
		local counts = {}
		for _, list in pairs(api.engine.system.simEntityAtStockSystem.getStock2SimEntityMap() or {}) do counts[#counts + 1] = #list end
		parts.stocks = countsHash(counts)
	end)
	-- cargo and passengers on board of vehicles
	pcall(function()
		local counts = {}
		for _, byCargo in pairs(api.engine.system.simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap() or {}) do
			local n = 0
			for _, list in pairs(byCargo) do n = n + #list end
			counts[#counts + 1] = n
		end
		parts.onboard = countsHash(counts)
	end)
	pcall(function()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		parts.timeOfDay = gt.timeOfDaySec
	end)
end

-- values the host imposes on the other games (corrected at every checkpoint)
local function authValues(reg)
	if reg and reg.mode == "separate" then
		-- one balance and one loan per company (flat numbers: the launcher forwards the host's top-level numbers)
		local t = {}
		for _, c in ipairs(reg.list) do
			local okc, acc = pcall(function() return api.engine.getComponent(c.ent, api.type.ComponentType.ACCOUNT) end)
			if okc and acc then t["b" .. c.id] = acc.balance; t["l" .. c.id] = acc.loan end
		end
		return t
	end
	local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
	return { balance = acc.balance, loan = acc.loan }
end

-- a client brings its money to the host's value at checkpoint n: the difference measured at the same game time
local function correctMoney(own, host, n, sendCommand, reg)
	if reg and reg.mode == "separate" then
		if not own then return end
		for _, c in ipairs(reg.list) do
			local hb, ob = host["b" .. c.id], own["b" .. c.id]
			if c.ent and type(hb) == "number" and type(ob) == "number" and hb ~= ob then
				local entry = api.type.JournalEntry.new()
				entry.amount = math.floor(hb - ob + 0.5)
				entry.time = -1
				entry.category.type = api.type.JournalEntry.Type.OTHER
				sendCommand(api.cmd.makeJournalBookAssetCmd(c.ent, entry))
				log("host authority: money of company " .. c.id .. " corrected by " .. entry.amount .. " (checkpoint " .. tostring(n) .. ")")
			end
		end
		return
	end
	if not own or type(host.balance) ~= "number" or type(own.balance) ~= "number" then return end
	local delta = host.balance - own.balance
	if delta == 0 then return end
	local entry = api.type.JournalEntry.new()
	entry.amount = math.floor(delta + 0.5)
	entry.time = -1
	entry.category.type = api.type.JournalEntry.Type.OTHER
	sendCommand(api.cmd.makeJournalBookAssetCmd(api.engine.util.getPlayer(), entry))
	log("host authority: money corrected by " .. entry.amount .. " (checkpoint " .. tostring(n) .. ")")
end

local hashShown = false
local hashCostsShown = 0
local function simHash(terrainSig, reg)
	local tStart = os.clock()
	local parts = R.contentHash(C.hashStr, C.dump)
	-- diagnostic (MPFEVER_VDUMP set): every vehicle and every company's money at each checkpoint, to diff two games
	if os.getenv("MPFEVER_VDUMP") then
		pcall(function()
			local t = { "== t=" .. tostring(gameTime()) }
			for _, e in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
				local tv = api.engine.getComponent(e, api.type.ComponentType.TRANSPORT_VEHICLE)
				local mp = api.engine.getComponent(e, api.type.ComponentType.MOVE_PATH)
				local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
				local nm = api.engine.getComponent(e, api.type.ComponentType.NAME)
				t[#t + 1] = string.format("%s owner=%s line=%s stop=%s state=%s | %s", nm and tostring(nm.name) or tostring(e), po and tostring(po.player) or "-",
					tostring(tv and tv.line), tostring(tv and tv.stopIndex), tostring(tv and tv.state), mp and C.dump(mp.dyn) or "depot")
			end
			pcall(function()
				for _, c in ipairs(reg and reg.list or {}) do
					local acc = api.engine.getComponent(c.ent, api.type.ComponentType.ACCOUNT)
					t[#t + 1] = "account " .. tostring(c.id) .. " " .. tostring(acc and acc.balance)
				end
			end)
			C.appendFile(C.DIR .. BS .. "vdump.txt", table.concat(t, NL) .. NL)
		end)
	end
	local costs = {}
	for k, v in pairs(R.partCost or {}) do costs[k] = v end
	local tMark = os.clock()
	if reg and reg.mode == "separate" then
		parts.companies = CO.signature(reg)
		-- who owns what: roads, constructions and vehicles counted per company (0 = nobody's)
		pcall(function()
			local cnt = {}
			local function tally(kind, list)
				for _, e in ipairs(list) do
					local okc, po = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED) end)
					local id = (okc and po) and (CO.idOfEntity(reg, po.player) or -1) or 0
					cnt[kind .. id] = (cnt[kind .. id] or 0) + 1
				end
			end
			tally("e", R.allEdges())
			tally("c", R.withoutAssets(R.entitiesWith("CONSTRUCTION")))
			tally("v", R.entitiesWith("TRANSPORT_VEHICLE"))
			local keys = {}
			for k, v in pairs(cnt) do keys[#keys + 1] = k .. "=" .. v end
			table.sort(keys)
			parts.owners = table.concat(keys, " ")
		end)
		-- the loans of the companies other than the savegame's (the savegame company's are in script:loan)
		pcall(function()
			local t = {}
			for _, c in ipairs(reg.list) do
				local lt = reg.loan and reg.loan[c.id]
				if lt then
					local sum = 0
					for _, l in ipairs(lt.obtainedLoans or {}) do sum = sum + (l.amount or 0) * 7 + (l.timesPaid or 0) end
					t[#t + 1] = c.id .. ":" .. #(lt.obtainedLoans or {}) .. "/" .. tostring(lt.freeId) .. "/" .. sum
				end
			end
			parts.loans = table.concat(t, " ")
		end)
	end
	costs.companyParts = os.clock() - tMark
	-- the terrain edits applied so far (the sum of their cells' checksums, kept in the simulation state)
	parts.terrain = tostring(terrainSig or 0)
	tMark = os.clock()
	local okx, errx = pcall(extendedParts, parts)
	if not okx then parts.extended = "ERR " .. tostring(errx):sub(1, 80) end
	costs.extended = os.clock() - tMark
	if hashCostsShown < 3 then
		hashCostsShown = hashCostsShown + 1
		local t = {}
		for k, v in pairs(costs) do t[#t + 1] = string.format("%s=%.3f", k, v) end
		table.sort(t)
		log(string.format("hash costs (%.3f s): ", os.clock() - tStart) .. table.concat(t, " "))
	end
	if not hashShown then
		hashShown = true
		local t = {}
		for k, v in pairs(parts) do t[#t + 1] = k .. "=" .. tostring(v) end
		table.sort(t)
		log("hash parts: " .. table.concat(t, " ; "))
		for k, v in pairs(R.loopErrors) do log("cannot list " .. k .. ": " .. v) end
	end
	local ok, t = pcall(gameTime)
	parts.time = ok and t or "?"
	if R.ncDump then
		pcall(function()
			table.sort(R.ncDump)
			local f = C.IO.open(C.DIR .. BS .. "nc_" .. string.format("%012d", t) .. ".txt", "wb")
			f:write(table.concat(R.ncDump, NL), NL)
			f:close()
		end)
		R.ncDump = nil
	end
	local okm, money = pcall(function()
		if reg and reg.mode == "separate" then
			local t = {}
			for _, c in ipairs(reg.list) do
				local acc = api.engine.getComponent(c.ent, api.type.ComponentType.ACCOUNT)
				t[#t + 1] = c.id .. ":" .. acc.balance .. "/" .. acc.loan
			end
			return table.concat(t, "|")
		end
		local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
		return acc.balance .. "/" .. acc.loan
	end)
	parts.money = okm and money or "?"
	if reg and reg.mode == "separate" then log("companies check at t=" .. tostring(parts.time) .. ": owners {" .. tostring(parts.owners) .. "} money " .. tostring(parts.money)) end
	-- debugging (MPFEVER_CONDUMP=1): every construction at each checkpoint, to find the first action that differs
	if os.getenv("MPFEVER_CONDUMP") then
		pcall(function()
			local lines = {}
			for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
				local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
				local pp = c and c.transf and R.matPos(c.transf)
				if pp then lines[#lines + 1] = string.format("%s %.1f,%.1f #%d", tostring(c.fileName):match("[^/]+$"), pp.x, pp.y, e) end
			end
			table.sort(lines)
			local f = C.IO.open(C.DIR .. BS .. "con_" .. tostring(parts.time) .. ".txt", "wb")
			if f then f:write(table.concat(lines, NL) .. NL); f:close() end
		end)
	end
	return parts
end

-- deterministic order of actions applied at the same time
local function before(x, y)
	if x.at ~= y.at then return x.at < y.at end
	if (x.origin or "") ~= (y.origin or "") then return (x.origin or "") < (y.origin or "") end
	return (x.oseq or 0) < (y.oseq or 0)
end

local SIM = { subscribed = false }

-- ================================================================== action execution

local ENTITY_ARGS = {
	makeVehicleBuyCmd = { 1, 2 }, makeVehicleSellCmd = { 1 }, makeVehicleSetLineCmd = { 1, 2 }, makeVehicleSendToDepotCmd = { 1 },
	makeVehicleReverseCmd = { 1 }, makeVehicleReplaceCmd = { 1 }, makeVehicleSetStoppedByUserCmd = { 1 },
	makeLineUpdateCmd = { 1 }, makeLineDestroyCmd = { 1 }, makeLineCreateCmd = { 3 }, makeEntitySetNameCmd = { 1 }, makeEntitySetColorCmd = { 1 },
}

local function missingEntities(fn, margs)
	local missing = {}
	local function check(e, what)
		if type(e) == "number" and e >= 0 then
			local ok, exists = pcall(function() return api.engine.entityExists(e) end)
			if ok and exists == false then missing[#missing + 1] = what .. "=" .. e end
		end
	end
	for _, i in ipairs(ENTITY_ARGS[fn] or {}) do check(margs[i], "arg" .. i) end
	if fn == "makeLineCreateCmd" or fn == "makeLineUpdateCmd" then
		local line = margs[fn == "makeLineCreateCmd" and 4 or 2]
		if type(line) == "table" then
			for k, stop in ipairs(line.stops or {}) do
				if type(stop) == "table" then check(stop.stationGroup, "stop" .. k .. ".stationGroup") end
			end
		end
	end
	return missing
end

-- Ways to rebuild a captured build, tried in this order; a factory failure has no side effect, so the same sequence
-- gives the same outcome on every machine. ie/pi: the ignoreErrors and playerInitiated flags given to the factory
-- (the game's own scripts pass true/false; the native tools true... as captured).
local BUILD_TRIES = {
	{ v = "full" }, { v = "minimal" }, { v = "minimalNoOwner" }, { v = "bare" },
	{ v = "full", ie = true, pi = false }, { v = "minimal", ie = true, pi = false },
	{ v = "minimalNoOwner", ie = true, pi = false }, { v = "bare", ie = true, pi = false },
	{ v = "full", raw = true }, { v = "minimal", raw = true, ie = true, pi = false },
}

local function shortErr(e)
	local m = tostring(e)
	m = m:match("^[^" .. NL .. "]*") or m
	m = m:gsub("^.*%.lua" .. string.char(34) .. "%]:%d+: ", "")
	return m:sub(1, 90)
end

local function tryLabel(t)
	return t.v .. (t.raw and "/raw" or "") .. (t.ie ~= nil and "/ie" or "")
end

-- returns the command (or nil), the label of the combination that worked, the failures
local function buildCommand(fn, srcArgs, tries)
	local errs = {}
	for _, t in ipairs(tries) do
		local margs = C.deser(srcArgs)
		if t.ie ~= nil then margs[3] = t.ie; margs[4] = t.pi end
		local okr, args, n = pcall(C.rebuildArgs, fn, margs, { seed = 7919, variant = t.v, raw = t.raw })
		if not okr then
			errs[#errs + 1] = tryLabel(t) .. ": rebuild " .. shortErr(args)
		else
			local okc, c = pcall(function() return api.cmd[fn](table.unpack(args, 1, n)) end)
			if okc and c then return c, tryLabel(t), errs end
			errs[#errs + 1] = tryLabel(t) .. ": " .. shortErr(c)
		end
	end
	return nil, nil, errs
end

-- Executes one replicated action. Returns a result record (for the originator's UI and the bindings).
-- done (optional, with useCallback): called with the result once the engine has answered (or at once on failure)
local function executeAction(a, sendCommand, useCallback, bind, done)
	local result = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = false }
	-- companies mode: a new line takes its company's colour (a little darker for each line the company already has), so that the
	-- lines of each company can be told apart on the map and in the line lists
	if a.fn == "makeLineCreateCmd" and a.co and R.CO and type(a.args) == "table" then
		pcall(function()
			local c = CO.find(R.CO, a.co)
			if not c then return end
			local r, g, b = CO.rgb(c.color)
			local n = 0
			if c.ent then n = #api.engine.system.lineSystem.getLinesForPlayer(c.ent) end
			local f = 1 - 0.12 * (n % 4)
			a.args[2] = { __vec = true, x = r * f, y = g * f, z = b * f }
		end)
	end
	-- companies mode: the game's loan and company scripts work for ONE company (the savegame's: they ask getPlayer() when the event
	-- reaches them, a moment after this call), so their events from another company are not applied instead of being booked on
	-- somebody else's account
	-- contracts: the company accepting or declining an offer travels with the event (see CO.installContracts); the same for the
	-- MPFever events of the interface (sharing a station)
	if a.fn == "makeScriptingSendEventCmd" and a.co and R.CO and R.CO.mode == "separate" and type(a.args) == "table"
		and (a.args[2] == "Subvention" or a.args[2] == "mpfever") and type(a.args[4]) == "table" then
		a.args[4].mpfCo = a.co
	end
	if a.fn == "makeScriptingSendEventCmd" and a.co and R.CO and R.CO.canon and a.co ~= CO.idOfEntity(R.CO, R.CO.canon)
		and type(a.args) == "table" and (a.args[2] == "Loan" or a.args[2] == "Company" or a.args[2] == "Companies") then
		result.err = "not available to this company yet (" .. tostring(a.args[2]) .. "." .. tostring(a.args[3]) .. ")"
		log("action " .. tostring(a.uid) .. " " .. result.err .. ": ignored on every game")
		return result
	end
	local okt, unresolved = pcall(R.translateIn, a.args or {}, bind or {})
	if not okt then
		result.err = "references: " .. tostring(unresolved)
		log("action " .. tostring(a.uid) .. " reference resolution failed: " .. tostring(unresolved))
		return result
	end
	if #unresolved > 0 then
		result.err = "DESYNC unresolved: " .. table.concat(unresolved, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	local okm, missing = pcall(missingEntities, a.fn, a.args or {})
	if okm and #missing > 0 then
		result.err = "DESYNC missing entities: " .. table.concat(missing, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	-- companies mode: a line stops only at its company's stations and at the stations another company shares
	if (a.fn == "makeLineCreateCmd" or a.fn == "makeLineUpdateCmd") and a.co and R.CO and R.CO.mode == "separate" and type(a.args) == "table" then
		local line = a.args[a.fn == "makeLineCreateCmd" and 4 or 2]
		local blocked = nil
		pcall(function()
			for _, stop in ipairs(type(line) == "table" and line.stops or {}) do
				local sg = type(stop) == "table" and stop.stationGroup
				if type(sg) == "number" and sg >= 0 then
					local owner = CO.idOfEntity(R.CO, R.ownerOf(sg))
					if owner and owner ~= a.co and not (R.CO.shares and R.CO.shares[R.sgKey(sg)]) then blocked = sg break end
				end
			end
		end)
		if blocked then
			result.err = "station " .. tostring(blocked) .. " belongs to another company and is not shared"
			log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " refused on every game: " .. result.err)
			return result
		end
	end
	local isBuild = a.fn == "makeWorldBuildProposalCmd"
	local cmd, label, errs = buildCommand(a.fn, C.ser(a.args or {}), isBuild and BUILD_TRIES or { { v = "full" } })
	if not cmd then
		result.err = table.concat(errs, " | ")
		log("BUILD NOT REPLAYABLE " .. tostring(a.uid) .. " " .. tostring(a.fn) .. ": " .. result.err)
		return result
	end
	if isBuild then
		pcall(function()
			local src = a.args[1].proposal or {}
			local seg = (src.addedSegments or {})[1]
			local shipped = seg and seg.comp and seg.comp.roadTemplate
			local margs = C.deser(C.ser(a.args))
			local args = C.rebuildArgs(a.fn, margs, { seed = 7919, variant = label:match("^[^/]+"), raw = label:find("/raw") ~= nil })
			local ssp = args[1].streetProposal
			local e = ssp.edgesToAdd[1]
			log("  debug: shipped segments=" .. #(src.addedSegments or {}) .. " removed=" .. #(src.removedSegments or {}) .. " template=" .. tostring(shipped)
				.. " | rebuilt add=" .. #ssp.edgesToAdd .. " remove=" .. #ssp.edgesToRemove .. " nodes=" .. #ssp.nodesToAdd
				.. (e and (" e.id=" .. tostring(e.entity) .. " n0=" .. tostring(e.comp.node0) .. " n1=" .. tostring(e.comp.node1) .. " tmpl=" .. tostring(e.comp.roadTemplate) .. " lanes=" .. tostring(#e.comp.laneConfigs)) or "")
				.. " removeIds=" .. C.ser(ssp.edgesToRemove))
		end)
		log("action " .. tostring(a.uid) .. " rebuilt as '" .. label .. "'" .. (#errs > 0 and (" after " .. #errs .. " refused form(s)") or ""))
		if #C.errors > 0 then log("  notes: " .. table.concat(C.errors, " ; "):sub(1, 300)) end
	end
	local createdKey = (a.fn == "makeLineCreateCmd" and "L" or ((a.fn == "makeVehicleBuyCmd" or a.fn == "makeVehicleReplaceCmd") and "V" or nil))
	local oks, errs
	if useCallback then
		oks, errs = pcall(sendCommand, cmd, function(data, ok, resultEntities)
			result.success = ok
			if isBuild then
				local why = ""
				if not ok then pcall(function() why = " " .. C.ser(C.marshal(data.resultProposalData.errorState.messages)) end) end
				log("action " .. tostring(a.uid) .. " applied by the engine: " .. (ok and "BUILT" or ("REFUSED" .. why)))
			end
			result.data = C.marshal(data)
			result.entities = C.marshal(resultEntities)
			local first = nil
			pcall(function() first = resultEntities[1][1] end)
			if ok and createdKey and type(first) == "number" then result.created = { key = createdKey .. a.uid, e = first } end
			result.answered = true
			if done and result.returned then done(result) end
		end)
	else
		-- simulation state: no callbacks; the command runs at once; created entities are found by difference
		local watch = createdKey == "L" and "LINE" or (createdKey == "V" and "TRANSPORT_VEHICLE" or nil)
		local function list()
			local r = {}
			if watch == "LINE" then
				for _, e in ipairs(api.engine.system.lineSystem.getLines()) do r[e] = true end
			else
				for _, e in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do r[e] = true end
			end
			return r
		end
		local beforeSet = nil
		if watch then
			local okl, l = pcall(list)
			if okl then beforeSet = l else log("creation watch failed: " .. tostring(l)) end
		end
		oks, errs = pcall(sendCommand, cmd)
		if oks then
			result.success = true
			local data = {}
			if beforeSet then
				local created = nil
				local okl, after = pcall(list)
				if okl then
					for e, _ in pairs(after) do
						if not beforeSet[e] and (created == nil or e > created) then created = e end
					end
				end
				if created then
					if watch == "TRANSPORT_VEHICLE" then data.resultVehicleEntity = created else data.resultEntity = created end
					result.entities = { { created, 0 } }
					result.created = { key = createdKey .. a.uid, e = created }
				else
					-- the engine may create it during the next step: watch for it
					local seen = {}
					for e, _ in pairs(beforeSet) do seen[#seen + 1] = e end
					result.watch = { kind = watch, key = createdKey .. a.uid, before = seen, steps = 0 }
				end
			end
			result.data = data
		end
	end
	if not oks then
		result.err = "send: " .. tostring(errs)
		log("SEND FAILED " .. tostring(a.uid) .. ": " .. tostring(errs))
		if done then done(result) end
		return result
	end
	if useCallback and done then
		-- the verdict comes in the callback (logged and reported there)
		result.returned = true
		if result.answered then done(result) end
		return result
	end
	log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " at t=" .. tostring(gameTime()) .. " -> " .. (result.success and "OK" or "REFUSED"))
	return result
end

local function reverseOf(bind)
	local rev = {}
	for k, e in pairs(bind or {}) do rev[e] = k end
	return rev
end

-- ================================================================== simulation half (engine state)


-- ================================================================== companies (simulation half)
-- Mode "one company per player". The game's own scripts (loans, company level, ticket prices, notifications...) call
-- api.engine.util.getPlayer() and keep the state of ONE company. Each game's interface acts as its own company (the native module
-- writes it into the engine's local-player word), so the simulation of every game must see the SAME player, whatever its
-- interface plays: the savegame's company ("canon"), or the company of the action being replayed (SIM.actor, set around the
-- replay). The replacement is installed in every simulation Lua state that runs this script; it is never installed in the shared
-- mode, where nothing changes.
local function installSimPlayer(st)
	local reg = st and st.co
	if not (reg and reg.canon) then return end
	SIM.canon = reg.canon
	local util = api.engine.util
	if SIM.wrapper and util.getPlayer == SIM.wrapper then return end
	SIM.wrapper = function()
		if SIM.actor then return SIM.actor end
		return SIM.canon
	end
	util.getPlayer = SIM.wrapper
	log("companies: getPlayer() fixed to the savegame's company " .. tostring(reg.canon) .. " in this simulation state")
end

-- ---- loans of the companies other than the savegame's
-- The game's loan script keeps ONE list of loans and books them on getPlayer(): it works for the savegame's company only. Every
-- other company keeps its own list in the companies registry (st.co.loan[company]) and is served here, with the game's own loan
-- rules (loan_util): taking and repaying a loan (events of the player's loan window), and the monthly payments.
local function loanMods()
	if SIM.loanMods == nil then
		local ok1, lu = pcall(ug_require, "/game_mechanics/finance/loan_util.tl")
		local ok2, mu = pcall(ug_require, "/scripts/mathutil.lua")
		SIM.loanMods = (ok1 and ok2 and type(lu) == "table" and type(mu) == "table") and { lu = lu, mu = mu } or false
		if not SIM.loanMods then log("companies: the loan modules are not reachable (loans of the other companies are ignored)") end
	end
	return SIM.loanMods or nil
end

local function coLoanTable(st, co)
	local M = loanMods()
	if not M then return nil end
	st.co.loan = st.co.loan or {}
	local t = st.co.loan[co]
	if not t then
		t = { availableLoans = M.lu.createAvailableLoans(), obtainedLoans = {}, freeId = 0 }
		st.co.loan[co] = t
	end
	return t
end

local function coBook(ent, entry)
	api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(ent, entry, api.type.Vec3f.new(0, 0, 0)))
end

local function coLoanEvent(st, co, name, loans)
	local M = loanMods()
	local c = st.co and CO.find(st.co, co)
	if not (M and c and c.ent) then return false end
	local lt = coLoanTable(st, co)
	local availed = type(loans) == "table" and loans[1] or nil
	local obtained = type(loans) == "table" and loans[2] or nil
	if type(obtained) ~= "table" then return false end
	if name == "Obtain" then
		if #lt.obtainedLoans >= M.lu.maximalObtainableLoans then return false end
		coBook(c.ent, M.lu.makeLoan(obtained.amount, -1))
		local now = gameTime()
		local fresh = {}
		for _, loan in ipairs(lt.availableLoans) do
			local nl = loan
			if type(availed) == "table" and availed.type == loan.type then
				nl = { type = loan.type, cooldownUntil = now + math.random(api.util.getDefaultMonthDuration() * 4, api.util.getDefaultMonthDuration() * 8) }
			end
			fresh[#fresh + 1] = nl
		end
		lt.availableLoans = fresh
		lt.obtainedLoans[#lt.obtainedLoans + 1] = M.lu.createNewObtainedLoan(obtained, lt.freeId)
		lt.freeId = lt.freeId + 1
		log("companies: company " .. co .. " took a loan of " .. tostring(obtained.amount))
		return true
	elseif name == "Repay" then
		local idx = nil
		for i, loan in ipairs(lt.obtainedLoans) do if loan.id == obtained.id then idx = i; break end end
		if not idx then return false end
		local amount = M.lu.getFullLoanAndInterestPayBack(obtained)
		coBook(c.ent, M.lu.makeLoan(-amount, -1))
		table.remove(lt.obtainedLoans, idx)
		log("companies: company " .. co .. " repaid a loan")
		return true
	end
	return false
end

-- every simulation step: the offers renew themselves, the monthly payments of the loans taken are booked. Returns whether the state changed.
local function coLoanUpdate(st, dt)
	local reg = st.co
	if not (reg and reg.mode == "separate" and dt and dt > 0) then return false end
	local M = loanMods()
	if not M then return false end
	local now = gameTime()
	local changed = false
	for _, c in ipairs(reg.list) do
		if c.ent and c.ent ~= reg.canon and api.engine.util.finance.getPlayersBalance(c.ent) ~= nil then
			if not (st.co.loan and st.co.loan[c.id]) then changed = true end
			local lt = coLoanTable(st, c.id)
			local fresh = {}
			for _, loan in ipairs(lt.availableLoans) do
				local nl = loan
				if loan.birthDay ~= nil and (loan.birthDay + api.util.getDefaultYearDuration() / 2 <= now) or (loan.cooldownUntil and loan.cooldownUntil < now) then
					local t = loan.type
					if t == "Small" then nl = M.lu.createSmallLoan()
					elseif t == "Medium" then nl = M.lu.createMediumLoan()
					elseif t == "Large" then nl = M.lu.createLargeLoan()
					elseif t == "ExtraLarge" then nl = M.lu.createExtraLargeLoan() end
					if nl ~= loan then changed = true end
				end
				fresh[#fresh + 1] = nl
			end
			lt.availableLoans = fresh
			local done = {}
			for i, loan in ipairs(lt.obtainedLoans) do
				local months = M.mu.round(loan.duration / api.util.getDefaultMonthDuration())
				local step = loan.duration / months
				if loan.lastPayDay + step <= now then
					loan.timesPaid = loan.timesPaid + 1
					loan.lastPayDay = now
					local ml, mi, le, ie = M.lu.getMonthlyLoanAndInterestWithErrors(loan.amount, loan.duration, loan.percentage)
					if loan.timesPaid == months then
						coBook(c.ent, M.lu.makeLoan(-(ml + le), -1))
						coBook(c.ent, M.lu.makeInterest(-(mi + ie), -1))
					else
						coBook(c.ent, M.lu.makeLoan(-ml, -1))
						coBook(c.ent, M.lu.makeInterest(-mi, -1))
					end
					changed = true
				end
				if loan.timesPaid == months then done[#done + 1] = i end
			end
			for k = #done, 1, -1 do table.remove(lt.obtainedLoans, done[k]); changed = true end
		end
	end
	return changed
end

-- an event of the loan window sent by a company other than the savegame's
local function coIsLoanEvent(st, a)
	return a.fn == "makeScriptingSendEventCmd" and a.co and st.co and st.co.canon and a.co ~= CO.idOfEntity(st.co, st.co.canon)
		and type(a.args) == "table" and a.args[2] == "Loan"
end

local function coApply(st, a)
	local p = a.args or {}
	if coIsLoanEvent(st, a) then
		local ok, err = pcall(coLoanEvent, st, a.co, a.args[3], a.args[4])
		if not ok then log("companies: loan event failed: " .. tostring(err)) end
		return
	end
	if a.fn ~= "mpfCoJoin" or p.mode ~= "separate" then return end
	if not st.co then
		st.co = CO.new("separate", api.engine.util.getPlayer(), tonumber(p.start))
		local r, g, b = CO.rgb(1)
		pcall(function() api.cmd.sendCommand(api.cmd.makeEntitySetColorCmd(st.co.canon, api.type.Vec3f.new(r, g, b))) end)
		log("companies: registry created, the savegame's company is player entity " .. tostring(st.co.canon))
	end
	local c, isNew = CO.join(st.co, tostring(p.key), tostring(p.name), p.host == true, p.cname, p.sid)
	log("companies: player '" .. tostring(p.key) .. "' plays company " .. c.id .. (isNew and " (new)" or " (known)"))
	installSimPlayer(st)
end

local function simApplyDue(state)
	local st = state:get() or {}
	R.CO = st.co
	local now = gameTime()
	local changed = false
	local q = st.q or {}
	if #q > 0 then
		table.sort(q, before)
		local keep, bought = {}, false
		st.results = st.results or {}
		st.bind = st.bind or {}
		for _, a in ipairs(q) do
			if a.at <= now and not (a.fn == "makeVehicleBuyCmd" and bought) then
				changed = true
				if a.kind == "hash" then
					local c0 = os.clock()
					local okA, auth = pcall(authValues, st.co)
					st.hash = { n = a.n, parts = simHash(st.terrainSig, st.co), cost = os.clock() - c0, auth = okA and auth or nil }
					st.authOwn = st.authOwn or {}
					st.authOwn[#st.authOwn + 1] = { n = a.n, auth = okA and auth or nil }
					while #st.authOwn > 10 do table.remove(st.authOwn, 1) end
				elseif a.fn == "mpfCoJoin" then
					local okc, errc = pcall(coApply, st, a)
					if not okc then log("companies: " .. tostring(a.fn) .. " failed: " .. tostring(errc)) end
				elseif coIsLoanEvent(st, a) then
					local okc, errc = pcall(coApply, st, a)
					if not okc then log("companies: loan event failed: " .. tostring(errc)) end
					st.results = st.results or {}
					st.results[#st.results + 1] = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = true, at = now }
					while #st.results > 40 do table.remove(st.results, 1) end
				else
					if a.at < now then
						log("LATE action " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)")
						st.late = (st.late or 0) + 1
					end
					if a.fn == "makeVehicleBuyCmd" then bought = true end
					-- mark the replay so that onPreBuildProposal does not ship it again
					st.replay = { at = now, n = ((st.replay and st.replay.at == now) and st.replay.n or 0) + 1 }
					state:set(st)
					SIM.actor = (st.co and a.co) and CO.entityOf(st.co, a.co) or nil
					local okx, r = pcall(executeAction, a, api.cmd.sendCommand, false, st.bind)
					SIM.actor = nil
					if not okx then error(r) end
					st = state:get() or st
					r.at = now
					if r.created then st.bind = st.bind or {}; st.bind[r.created.key] = r.created.e end
					if r.watch then
						st.watches = st.watches or {}
						st.watches[#st.watches + 1] = r
					else
						st.results = st.results or {}
						st.results[#st.results + 1] = r
						while #st.results > 40 do table.remove(st.results, 1) end
					end
				end
			else
				keep[#keep + 1] = a
			end
		end
		st.q = keep
	end
	-- entities created one or more steps after their command (vehicle purchases)
	if st.watches and #st.watches > 0 then
		local keepW = {}
		for _, r in ipairs(st.watches) do
			local w = r.watch
			w.steps = w.steps + 1
			local seen = {}
			for _, e in ipairs(w.before) do seen[e] = true end
			local created = nil
			pcall(function()
				local function consider(e) if not seen[e] and (created == nil or e > created) then created = e end end
				if w.kind == "LINE" then
					for _, e in ipairs(api.engine.system.lineSystem.getLines()) do consider(e) end
				else
					for _, e in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do consider(e) end
				end
			end)
			if created or w.steps >= 10 then
				r.watch = nil
				if created then
					r.created = { key = w.key, e = created }
					r.entities = { { created, 0 } }
					r.data = (w.kind == "LINE") and { resultEntity = created } or { resultVehicleEntity = created }
					st.bind = st.bind or {}
					st.bind[w.key] = created
				else
					r.success = false
					r.err = "created entity not found"
				end
				log("action " .. tostring(r.uid) .. " result after " .. w.steps .. " step(s): " .. (created and ("entity " .. created) or "nothing created"))
				st.results = st.results or {}
				st.results[#st.results + 1] = r
			else
				keepW[#keepW + 1] = r
			end
		end
		st.watches = keepW
		changed = true
	end
	if st.co then installSimPlayer(st) end
	if st.pauseAt and now >= st.pauseAt and not st.pausedAt then
		st.pausedAt = now
		api.cmd.sendCommand(api.cmd.makeGameSetSpeedCmd(0))
		changed = true
	end
	if changed then state:set(st) end
end

-- Deterministic math.random for the game mechanics: the n-th draw of a simulation step depends only on the game time
-- and n, whatever happened before (another script drawing first, the generator state of the process...).
local detRandom
local function installRandom()
	if detRandom and math.random == detRandom then return end
	local lastT, n = -1, 0
	detRandom = function(m, k)
		local okT, t = pcall(gameTime)
		t = okT and t or 0
		if t ~= lastT then lastT, n = t, 0 end
		n = n + 1
		local h = (t % 4294967296 + n * 2654435769) % 4294967296
		for _ = 1, 3 do
			-- 32-bit multiply in doubles (exact: each partial product stays below 2^53), then fold the high bits down
			local hi, lo = math.floor(h / 65536), h % 65536
			h = ((hi * 2246822519) % 65536 * 65536 + lo * 2246822519) % 4294967296
			h = (h + math.floor(h / 8192)) % 4294967296
		end
		local x = h / 4294967296
		if m == nil then return x end
		if k == nil then m, k = 1, m end
		return m + math.floor(x * (k - m + 1))
	end
	math.random = detRandom
	log("deterministic math.random installed")
end

-- (probe) how the game's scripts are reached: the global table `game` keeps every script module by its file name
local function contractProbe()
	if SIM.probeDone then return end
	SIM.probeDone = true
	local okg = type(game) == "table"
	local keys = {}
	if okg then
		for k, v in pairs(game) do
			if type(k) == "string" and (k:find("subvention", 1, true) or k:find("notification", 1, true) or k:find("mpfever", 1, true)) then
				local sub = {}
				if type(v) == "table" then for k2, v2 in pairs(v) do sub[#sub + 1] = tostring(k2) .. ":" .. type(v2) end end
				table.sort(sub)
				keys[#keys + 1] = k .. "{" .. table.concat(sub, ","):sub(1, 200) .. "}"
			end
		end
	end
	table.sort(keys)
	log("PROBE game table " .. tostring(okg) .. ": " .. table.concat(keys, " | "):sub(1, 3000))
	if not okg then return end
	local sub = game["::/game_mechanics/subventions/subventions.script"]
	if type(sub) == "table" and type(sub.handleEvent) == "function" and not sub.__mpfProbe then
		sub.__mpfProbe = true
		local oh, ou = sub.handleEvent, sub.update
		sub.handleEvent = function(u, st, src, id, name, param, ...)
			if id == "Subvention" or name == "OnCalcTicketPrice" then
				SIM.subEv = (SIM.subEv or 0) + 1
				if SIM.subEv <= 12 or SIM.subEv % 200 == 0 then log("PROBE subventions handleEvent " .. tostring(id) .. "/" .. tostring(name) .. " #" .. SIM.subEv .. " param " .. C.ser(C.marshal(param)):sub(1, 200)) end
			end
			return oh(u, st, src, id, name, param, ...)
		end
		sub.update = function(...)
			SIM.subUp = (SIM.subUp or 0) + 1
			if SIM.subUp == 1 or SIM.subUp % 600 == 0 then log("PROBE subventions update #" .. SIM.subUp) end
			return ou(...)
		end
		log("PROBE subventions script wrapped")
	end
	for _, path in ipairs({ "::/game_mechanics/subventions/deliver_cargo/deliver_cargo.script", "::/game_mechanics/subventions/deliver_passengers/deliver_passengers.script",
		"::/game_mechanics/subventions/deliver_cargo_town/deliver_cargo_town.script", "::/game_mechanics/subventions/deliver_workers/deliver_workers.script" }) do
		local m = game[path]
		local name = path:match("([^/]+)%.script$")
		local t = type(m) == "table" and m[name]
		if type(t) == "table" and type(t.handleEvent) == "function" and not t.__mpfProbe then
			t.__mpfProbe = true
			local oh = t.handleEvent
			t.handleEvent = function(src, id, ename, param, s, ...)
				SIM.typeEv = (SIM.typeEv or 0) + 1
				if SIM.typeEv <= 6 or SIM.typeEv % 200 == 0 then log("PROBE " .. name .. " handleEvent " .. tostring(id) .. "/" .. tostring(ename) .. " #" .. SIM.typeEv .. " uid " .. tostring(s and s.uid) .. " owner " .. tostring(s and s.mpfOwner)) end
				return oh(src, id, ename, param, s, ...)
			end
			log("PROBE " .. name .. " wrapped")
		end
	end
end

-- Shared stations: the vehicles of a company stopping at a station another company shares pay the fee set by its owner (per stop),
-- booked to both companies. Every few steps: the lines using such stations (recomputed now and then), their vehicles' next stop
-- (a vehicle whose next stop moved on has left the stops in between).
local function chargeShares(st, dt)
	local reg = st.co
	if not (reg and reg.mode == "separate" and reg.shares and next(reg.shares) ~= nil and dt and dt > 0) then return false end
	-- (on the game time, not on a counter: the simulation may run this script in several Lua states, each with its own counters,
	-- and every game must book the fees at the same steps)
	local stepNo = math.floor(gameTime() / STEP + 0.5)
	if stepNo % 5 ~= 0 then return false end
	SIM.sgKeys = SIM.sgKeys or {}
	do
		local list = {}
		for _, line in ipairs(R.entitiesWith("LINE")) do
			local lc = api.engine.getComponent(line, api.type.ComponentType.LINE)
			local lineCo = CO.idOfEntity(reg, R.ownerOf(line))
			if lc and lineCo then
				local stops, n = {}, #lc.stops
				for i = 1, n do
					local sg = lc.stops[i].stationGroup
					local key = SIM.sgKeys[sg]
					if not key then key = R.sgKey(sg); SIM.sgKeys[sg] = key end
					local fee = reg.shares[key]
					local ownerCo = fee and CO.idOfEntity(reg, R.ownerOf(sg)) or nil
					if fee and ownerCo and ownerCo ~= lineCo then stops[i - 1] = { co = ownerCo, fee = fee } end
				end
				if next(stops) ~= nil then list[#list + 1] = { line = line, co = lineCo, n = n, stops = stops } end
			end
		end
		SIM.shareLines = list
	end
	if #SIM.shareLines == 0 then return false end
	reg.vstop = reg.vstop or {}
	local owed = {}
	for _, l in ipairs(SIM.shareLines) do
		local okv, vehicles = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, l.line)
		for _, v in ipairs(okv and vehicles or {}) do
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			local idx = tv and tv.stopIndex
			if type(idx) == "number" and l.n > 0 then
				local k = tostring(v)
				local last = reg.vstop[k]
				if last ~= nil and last ~= idx then
					-- the stops left since the last look: last, last+1, ... idx-1
					local s, guard = last, 0
					while s ~= idx and guard < l.n do
						local f = l.stops[s]
						if f then owed[#owed + 1] = { from = l.co, to = f.co, fee = f.fee } end
						s = (s + 1) % l.n
						guard = guard + 1
					end
				end
				reg.vstop[k] = idx
			end
		end
	end
	if #owed == 0 then return true end
	local sums = {}
	reg.shareIncome = reg.shareIncome or {}
	for _, o in ipairs(owed) do
		sums[o.from] = (sums[o.from] or 0) - o.fee
		sums[o.to] = (sums[o.to] or 0) + o.fee
		reg.shareIncome[tostring(o.to)] = (reg.shareIncome[tostring(o.to)] or 0) + o.fee
	end
	for co, amount in pairs(sums) do
		local c = CO.find(reg, co)
		if c and c.ent and amount ~= 0 then
			local entry = api.type.JournalEntry.new()
			entry.amount = amount
			entry.time = -1
			entry.category.type = api.type.JournalEntry.Type.OTHER
			api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(c.ent, entry, api.type.Vec3f.new(0, 0, 0)))
		end
	end
	SIM.shareLogged = (SIM.shareLogged or 0) + 1
	if SIM.shareLogged <= 20 then log("companies: station fees: " .. #owed .. " stop(s) at shared stations paid") end
	return true
end

-- this machine's company number (companies.txt, written by the GUI half), for what its player sees (contract cards)
local function simLocalCo()
	local now = os.clock()
	if SIM.localCoAt == nil or now - SIM.localCoAt > 2 then
		SIM.localCoAt = now
		pcall(function()
			local f = C.IO.open(C.DIR .. BS .. "companies.txt", "rb")
			if f then
				local me = (f:read("*a") or ""):match("^me" .. TAB .. "(%d+)")
				f:close()
				SIM.localCo = tonumber(me)
				if SIM.localCo == 0 then SIM.localCo = nil end
			end
		end)
	end
	return SIM.localCo
end

local function update(userParams, state, dt)
	if not C.ACTIVE then return end
	pcall(function()
		local st0 = state:get()
		SIM.coRegistry = st0 and st0.co or nil
		-- (again from time to time: the game loads the script of a type of contract when it first needs it)
		SIM.ctTick = (SIM.ctTick or 0) + 1
		if SIM.coRegistry and SIM.coRegistry.mode == "separate" and SIM.ctTick % 50 == 1 then
			CO.installContracts({ log = log, registry = function() return SIM.coRegistry end, localCo = simLocalCo })
		end
	end)
	if os.getenv("MPFEVER_CPROBE") then local okp, errp = pcall(contractProbe) if not okp then log("PROBE failed: " .. tostring(errp)) end end
	-- The game mechanics scripts (contracts, loans, weather, industries, towns...) draw random numbers from the Lua
	-- generator, which is not part of the savegame and differs between games: reseeded from the game time at every
	-- simulation step, every game draws the same numbers.
	pcall(function() math.randomseed(gameTime()) end)
	installRandom()
	if not SIM.subscribed then
		SIM.subscribed = true
		pcall(function() state:subscribeToAllEvents() end)
	end
	local ok, err = pcall(simApplyDue, state)
	if not ok then log("simulation apply failed: " .. tostring(err)) end
	local okl, errl = pcall(function()
		local st = state:get()
		if st and st.co and st.co.mode == "separate" and #st.co.list > 1 then
			SIM.loanCalls = (SIM.loanCalls or 0) + 1
			if SIM.loanCalls == 1 or SIM.loanCalls == 60 or SIM.loanCalls == 300 then
				local c2 = st.co.list[2]
				local bal = nil
				pcall(function() bal = api.engine.util.finance.getPlayersBalance(c2.ent) end)
				log("companies: loans of the other companies: update runs, dt " .. tostring(dt) .. " (" .. type(dt) .. "), company 2 entity " .. tostring(c2.ent) .. " balance " .. tostring(bal))
			end
			local ch1 = coLoanUpdate(st, dt)
			local okF, ch2 = pcall(chargeShares, st, dt)
			if not okF then log("companies: station fees failed: " .. tostring(ch2)); ch2 = false end
			if ch1 or ch2 then state:set(st) end
		end
	end)
	if not okl then log("companies: loans failed: " .. tostring(errl)) end
end

-- A native build by this machine's player, announced by the engine just BEFORE it is applied (onPreBuildProposal).
-- The proposal is captured and stamped STAMP_AHEAD steps later, then emptied so that the engine applies nothing now
-- (strict mode: every game, this one included, builds it at the stamp). onPostBuildProposal tells whether emptying
-- worked; if the engine applied it anyway, this game keeps its native build and only the others replay it.
-- Street proposal experiments: which part of a script street proposal does the factory reject? Factories only (no
-- command is sent). Run once per game on the first captured road, before the native apply.
local function streetExperiments(compact, proposal)
	local st = compact.proposal or {}
	local seg = nil
	for _, sg in ipairs(st.addedSegments or {}) do
		if type(sg) == "table" and type(sg.comp) == "table" and sg.comp.roadTemplate then seg = sg; break end
	end
	if not seg then return end
	local c = seg.comp
	local function V(m) return api.type.Vec3f.new(m.x, m.y, m.z) end
	local p0, p1 = c.position0, c.position1
	if not (p0 and p1 and c.tangent0 and c.tangent1) then return end
	local existingEdge = nil
	for _, r in ipairs(st.removedSegments or {}) do
		if type(r) == "table" and type(r.entity) == "number" and r.entity >= 0 then existingEdge = r.entity; break end
	end
	local out = {}
	local function try(name, fn)
		local ok, res = pcall(fn)
		out[#out + 1] = name .. "=" .. (ok and (res and "OK" or "nil") or shortErr(res))
	end
	local factory = api.cmd.makeWorldBuildProposalCmd
	local function nodes(sp, how)
		local n0 = api.type.NodeAndEntity.new()
		n0.entity = -1
		n0.comp.position = V(p0)
		local n1 = api.type.NodeAndEntity.new()
		n1.entity = -2
		n1.comp.position = V(p1)
		if how == "table" then
			sp.streetProposal.nodesToAdd = { n0, n1 }
		else
			sp.streetProposal.nodesToAdd[1] = n0
			sp.streetProposal.nodesToAdd[2] = n1
		end
	end
	local function edge(opts)
		local e = api.type.SegmentAndEntity.new()
		e.entity = opts.eid or -1
		e.comp.node0 = -1
		e.comp.node1 = -2
		e.comp.tangent0 = V(c.tangent0)
		e.comp.tangent1 = V(c.tangent1)
		e.comp.type = 0
		e.comp.typeIndex = -1
		e.type = 0
		if opts.street then e.streetEdge = api.type.BaseEdgeStreet.new() end
		if opts.template then
			e.comp.roadTemplate = c.roadTemplate
			e.comp.roadStyle = c.roadStyle
		end
		if opts.roadType then e.comp.roadType = c.roadType end
		if opts.owner then
			local po = C.newOf("PlayerOwned")
			po.player = api.engine.util.getPlayer()
			e.playerOwned = po
		end
		return e
	end
	local function simple(opts)
		local sp = api.type.SimpleProposal.new()
		nodes(sp, opts.how)
		if opts.edge ~= false then
			local e = edge(opts)
			if opts.how == "table" then sp.streetProposal.edgesToAdd = { e } else sp.streetProposal.edgesToAdd[1] = e end
		end
		return factory(sp, nil, true, false)
	end
	try("empty", function() return factory(api.type.SimpleProposal.new(), nil, true, false) end)
	try("nodesOnly", function() return simple({ edge = false }) end)
	try("nodesOnlyTable", function() return simple({ edge = false, how = "table" }) end)
	try("edgeBare", function() return simple({}) end)
	try("edgeBareId3", function() return simple({ eid = -3 }) end)
	try("edgeStreet", function() return simple({ street = true }) end)
	try("edgeTemplate", function() return simple({ template = true }) end)
	try("edgeStreetTemplate", function() return simple({ street = true, template = true }) end)
	try("edgeStreetTemplateType", function() return simple({ street = true, template = true, roadType = true }) end)
	try("edgeAllOwner", function() return simple({ street = true, template = true, roadType = true, owner = true }) end)
	try("edgeAllTable", function() return simple({ street = true, template = true, roadType = true, how = "table" }) end)
	try("edgeAllIgnoreFalse", function()
		local sp = api.type.SimpleProposal.new()
		nodes(sp)
		sp.streetProposal.edgesToAdd[1] = edge({ street = true, template = true, roadType = true })
		return factory(sp, nil, false, true)
	end)
	if existingEdge then
		try("removeOnly", function()
			local sp = api.type.SimpleProposal.new()
			sp.streetProposal.edgesToRemove[1] = existingEdge
			return factory(sp, nil, true, false)
		end)
		try("replaceSegment", function()
			local P = api.engine.util.proposal.replaceSegment(existingEdge)
			if P == nil then return nil end
			C.appendFile(C.DIR .. BS .. "raw_builds.txt", "==== replaceSegment(" .. existingEdge .. ")" .. NL .. C.dump(P):sub(1, 20000) .. NL)
			return factory(P, nil, true, false)
		end)
		try("replaceSegmentWritable", function()
			local P = api.engine.util.proposal.replaceSegment(existingEdge)
			local sg = P.proposal.addedSegments[1]
			sg.comp.tangent0 = V(c.tangent0)
			return factory(P, nil, true, false)
		end)
	end
	try("proposalNew", function() return factory(api.type.Proposal.new(), nil, true, false) end)
	try("segmentsRemoveProposal", function()
		if not existingEdge then return nil end
		return factory(api.engine.util.proposal.makeSegmentsRemoveProposal({ existingEdge }), nil, true, false)
	end)
	log("street experiments: " .. table.concat(out, " ; "))
end

local function captureNativeBuild(state, param)
	local st = state:get() or {}
	R.CO = st.co
	local now = gameTime()
	if st.replay and st.replay.at == now and st.replay.n > 0 then
		st.replay.n = st.replay.n - 1     -- our own replay of a shipped action
		state:set(st)
		return
	end
	local proposal, playerInitiated = nil, nil
	pcall(function() proposal, playerInitiated = param[1], param[4] end)
	if proposal == nil or playerInitiated == false then return end
	-- A terrain modification (raising / lowering the ground) alone: a script cannot read its height cells nor write them, so
	-- the native module copies them (terrain_out_<n>.txt, announced in native_events.log) when the engine applies the
	-- command; the other games get them back through an empty grid of the same size (replayTerrain). The terrain tools cannot
	-- be held like the others: the edit is made here at once and the others make it at the same game time when they can.
	local okt, terrainOnly = pcall(function()
		local g = proposal.terrain and proposal.terrain.baseHeightMod
		if not g or (g.width or 0) * (g.height or 0) <= 0 then return false end
		if #proposal.toAdd > 0 or #proposal.toRemove > 0 then return false end
		local sp = proposal.proposal
		for _, k in ipairs({ "nodesToAdd", "nodesToRemove", "edgesToAdd", "edgesToRemove", "edgeObjectsToAdd", "edgeObjectsToRemove" }) do
			local v = sp[k]
			if v ~= nil and #v > 0 then return false end
		end
		return true
	end)
	if okt and terrainOnly then
		local dims = nil
		pcall(function()
			local g = proposal.terrain.baseHeightMod
			dims = { x0 = g.x0, y0 = g.y0, w = g.width, h = g.height }
		end)
		log("terrain modification at t=" .. now .. (dims and (": " .. dims.w .. "x" .. dims.h .. " cells at " .. dims.x0 .. "," .. dims.y0) or ""))
		st.terrainEdits = (st.terrainEdits or 0) + 1
		st.out = st.out or {}
		st.outSeq = (st.outSeq or 0) + 1
		st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
			fn = "terrainEdit", args = dims or {}, terrain = true, captured = now }
		while #st.out > 50 do table.remove(st.out, 1) end
		state:set(st)
		return
	end
	pcall(function()
		local g = proposal.terrain and proposal.terrain.baseHeightMod
		if g and (g.width or 0) * (g.height or 0) > 0 then
			log("WARNING: a build at t=" .. now .. " carries " .. g.width .. "x" .. g.height .. " terrain cells besides other content: the cells are not copied to the other games")
		end
	end)
	-- A build with nothing in it that a script can see (a stroke of the ground painter: its material grids are native only): there
	-- is nothing to rebuild on the other games, and shipping it would only make them replay an empty build (refused: a reload).
	local okE, isEmpty = pcall(function()
		if #proposal.toAdd > 0 or #proposal.toRemove > 0 or #proposal.parcelsToRemove > 0 then return false end
		local sp = proposal.proposal
		for _, k in ipairs({ "addedNodes", "removedNodes", "addedSegments", "removedSegments", "edgeObjectsToAdd", "edgeObjectsToRemove", "nodeConfigsToAdd", "nodeConfigsToRemove" }) do
			local v = sp[k]
			if v ~= nil and #v > 0 then return false end
		end
		return true
	end)
	if okE and isEmpty then
		st.emptyBuilds = (st.emptyBuilds or 0) + 1
		if st.emptyBuilds <= 5 then log("build at t=" .. now .. " has nothing a script can see (ground paint?): not shipped to the other games (they do not get the paint)") end
		state:set(st)
		return
	end
	-- Trees, plants and rocks placed with the brush: constructions without a file, their models listed in the proposal. A script
	-- cannot make that kind of construction: the other games build the same models (same places) with the mod's own construction
	-- (mpfever_asset.con, see replayAssets).
	local okA, assets = pcall(function()
		local n = #proposal.toAdd
		if n == 0 then return nil end
		local list = {}
		for i = 1, n do
			local ce = proposal.toAdd[i]
			if tostring(ce.fileName) ~= "" then return nil end
			local models = {}
			local con = ce.construction
			for s = 1, #con.subconstructions do
				local ms = con.subconstructions[s].models
				for k = 1, #ms do
					local m = ms[k]
					local id = m.id
					if type(id) == "number" then id = api.res.modelRep.getName(id) end
					local t, tf = {}, m.transf
					for q = 1, 16 do t[q] = tf[q] end
					models[#models + 1] = { id = tostring(id), transf = t }
				end
			end
			list[#list + 1] = { transf = C.marshal(ce.transf), models = models, player = ce.playerEntity }
		end
		return list
	end)
	if not okA then
		-- constructions without a file that could not be read (a brush build of an unknown kind): not shipped (a difference of
		-- decoration only, the others would refuse to rebuild it)
		local blank = false
		pcall(function() blank = #proposal.toAdd > 0 and tostring(proposal.toAdd[1].fileName) == "" end)
		if (st.assetErr or 0) < 3 then
			st.assetErr = (st.assetErr or 0) + 1
			log("asset capture failed (" .. tostring(assets):sub(1, 160) .. ")" .. (blank and ": not shipped" or ""))
			pcall(function() C.appendFile(C.DIR .. BS .. "raw_builds.txt", "==== asset capture failed t=" .. now .. NL .. C.dump(proposal):sub(1, 40000) .. NL) end)
		end
		if blank then state:set(st) return end
	end
	if okA and assets and #assets > 0 then
		local removed = {}
		pcall(function()
			for i = 1, #proposal.toRemove do
				local d = R.describe("con", proposal.toRemove[i])
				if d then d.__ref = true; removed[#removed + 1] = d end
			end
		end)
		for _, as in ipairs(assets) do
			if type(as.player) == "number" and as.player >= 0 then
				local co = R.CO and CO.idOfEntity(R.CO, as.player) or nil
				as.player = co and { __ref = true, k = "player", id = as.player, co = co } or nil
			else
				as.player = nil
			end
		end
		local nm = 0
		for _, as in ipairs(assets) do nm = nm + #as.models end
		st.assetBuilds = (st.assetBuilds or 0) + 1
		-- (the first ones in full, for a bug report)
		if st.assetBuilds <= 2 then
			pcall(function() C.appendFile(C.DIR .. BS .. "raw_builds.txt", "==== assets t=" .. now .. NL .. C.dump(proposal):sub(1, 40000) .. NL) end)
		end
		if st.assetBuilds <= 10 then log("assets placed at t=" .. now .. ": " .. #assets .. " construction(s), " .. nm .. " model(s) (" .. tostring(assets[1].models[1] and assets[1].models[1].id) .. "...), " .. #removed .. " removed") end
		st.out = st.out or {}
		st.outSeq = (st.outSeq or 0) + 1
		st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
			fn = "assetBuild", args = { assets = assets, toRemove = removed }, captured = now }
		while #st.out > 50 do table.remove(st.out, 1) end
		state:set(st)
		return
	end
	-- diagnostic for the asset (tree) brush: its constructions have no file, their models are listed in the proposal
	pcall(function()
		local n = #proposal.toAdd
		local firstBlank = nil
		for i = 1, n do if tostring(proposal.toAdd[i].fileName) == "" then firstBlank = i; break end end
		if not firstBlank or (st.dynLogged or 0) >= 4 then return end
		st.dynLogged = (st.dynLogged or 0) + 1
		st.dynDiag = now
		local ce = proposal.toAdd[firstBlank]
		local con = ce.construction
		local nsub, nmod, firstModel = 0, 0, "?"
		pcall(function()
			nsub = #con.subconstructions
			for _, sc in ipairs(con.subconstructions) do
				nmod = nmod + #sc.models
				if firstModel == "?" and sc.models[1] then firstModel = tostring(sc.models[1].id) end
			end
		end)
		local pd = ""
		pcall(function() pd = C.dump(con.params):sub(1, 200) end)
		log("asset construction(s) at t=" .. now .. ": " .. n .. " without a file; first: construction.fileName '" .. tostring(con and con.fileName) .. "', desc.fileName '"
			.. tostring(ce.desc and ce.desc.fileName) .. "', " .. nsub .. " subconstruction(s), " .. nmod .. " model(s), first model " .. firstModel .. ", params " .. pd)
	end)
	local c0 = os.clock()
	log("capture: start t=" .. now)
	local okc, compact = pcall(C.compactProposal, proposal)
	log("capture: compact " .. string.format("%.3f", os.clock() - c0) .. " s, " .. #C.ser(compact or {}) .. " bytes")
	if not okc then
		log("native build capture failed at t=" .. now .. ": " .. tostring(compact) .. " (desync)")
		return
	end
	st.rawLogged = (st.rawLogged or 0) + 1
	if st.rawLogged <= 6 then
		C.appendFile(C.DIR .. BS .. "raw_builds.txt", "==== t=" .. now .. NL .. C.dump(proposal):sub(1, 60000) .. NL
			.. "---- compact" .. NL .. C.ser(compact) .. NL)
	end
	local args = { n = 4, [1] = compact, [2] = { __player = true }, [3] = false, [4] = true }
	local okt, errt = pcall(R.translateOut, "makeWorldBuildProposalCmd", args, reverseOf(st.bind))
	if not okt then log("reference translation failed: " .. tostring(errt)) end
	if false and not st.experimented and #((compact.proposal or {}).addedSegments or {}) > 0 then
		st.experimented = true
		local oke, erre = pcall(streetExperiments, compact, proposal)
		if not oke then log("street experiments failed: " .. tostring(erre)) end
	end
	log("capture: translated " .. string.format("%.3f", os.clock() - c0) .. " s")
	if R.CO and R.CO.mode == "separate" then
		-- who the captured build says it is for (companies mode): a company number per owner reference
		local tally, seen = {}, 0
		local function walk(t, depth)
			if type(t) ~= "table" or depth > 7 or seen > 20000 then return end
			seen = seen + 1
			if t.k == "player" and t.co then tally[t.co] = (tally[t.co] or 0) + 1 end
			for _, v in pairs(t) do if type(v) == "table" then walk(v, depth + 1) end end
		end
		pcall(walk, args, 0)
		local parts = {}
		for co, n in pairs(tally) do parts[#parts + 1] = "company " .. co .. " x" .. n end
		table.sort(parts)
		log("capture: owner references: " .. (#parts > 0 and table.concat(parts, ", ") or "none"))
	end
	-- self-check: can this build be rebuilt from what is shipped? (factories only, nothing is applied)
	st.selfChecks = (st.selfChecks or 0) + 1
	if false and st.selfChecks <= 12 then
		local oks, errs = pcall(function()
			local margs = C.deser(C.ser(args))
			local missing = R.translateIn(margs, st.bind or {})
			local cmd, label, fails = buildCommand("makeWorldBuildProposalCmd", C.ser(margs), BUILD_TRIES)
			local nObj = #((compact.proposal or {}).edgeObjectsToAdd or {})
			log("self-check build t=" .. now .. " (" .. #(compact.toAdd or {}) .. " construction(s), "
				.. #((compact.proposal or {}).addedSegments or {}) .. " segment(s), " .. nObj .. " stop(s)): "
				.. (cmd and ("replayable as '" .. label .. "'") or "NOT replayable")
				.. (#missing > 0 and (" ; unresolved here: " .. table.concat(missing, ",")) or ""))
			if #fails > 0 then log("  refused: " .. table.concat(fails, " | "):sub(1, 1500)) end
			if #C.errors > 0 then log("  notes: " .. table.concat(C.errors, " ; "):sub(1, 300)) end
		end)
		if not oks then log("self-check failed: " .. tostring(errs)) end
		if st.selfChecks <= 3 then
			local okn, errn = pcall(function()
				local c2 = api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false)
				log("  probe: the captured native proposal itself " .. (c2 and "OK" or "nil"))
			end)
			if not okn then log("  probe failed: " .. shortErr(errn)) end
		end
	end
	st.out = st.out or {}
	st.outSeq = (st.outSeq or 0) + 1
	-- applied natively here at "now": the other games apply it at the same game time
	log("capture: checked " .. string.format("%.3f", os.clock() - c0) .. " s")
	local hasObjects = #((compact.proposal or {}).edgeObjectsToAdd or {}) > 0
	st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
		fn = "makeWorldBuildProposalCmd", args = args, captured = now, ready = not hasObjects }
	st.lastCapture = hasObjects and { n = st.outSeq, at = now } or nil
	while #st.out > 50 do table.remove(st.out, 1) end
	state:set(st)
end

-- After the native apply of a captured build with stops: read what the engine created (model, position on the edge)
local function enrichAfterBuild(state, param)
	local st = state:get() or {}
	local lc = st.lastCapture
	if not lc or lc.at ~= gameTime() then return end
	st.lastCapture = nil
	local o = nil
	for _, x in ipairs(st.out or {}) do if x.n == lc.n then o = x end end
	if not o then state:set(st); return end
	o.ready = true
	local compact = o.args and o.args[1]
	local list = compact and compact.proposal and compact.proposal.edgeObjectsToAdd or {}
	local EO = api.type.ComponentType.EDGE_OBJECT
	local function edgeObject(e)
		if type(e) ~= "number" or e < 0 then return nil end
		local ok, c = pcall(function() return api.engine.getComponent(e, EO) end)
		return ok and c or nil
	end
	-- candidates: the proposal's own result entities, then every result entity that is an edge object
	local fromProposal, results = {}, {}
	pcall(function()
		local eo = param[1].proposal.edgeObjectsToAdd
		for i = 1, #eo do fromProposal[i] = eo[i].resultEntity end
	end)
	pcall(function()
		local res = param[3]
		for i = 1, #res do
			local e = res[i]
			if type(e) ~= "number" then pcall(function() e = e[1] end) end
			if edgeObject(e) then results[#results + 1] = e end
		end
	end)
	local found = 0
	for i, entry in ipairs(list) do
		local e = edgeObject(fromProposal[i]) and fromProposal[i] or results[i]
		local c = edgeObject(e)
		if c then
			entry.model = c.edgeObjectConstruction
			entry.param = c.param
			entry.params = C.marshal(c.params)
			found = found + 1
			log("stop captured: model=" .. tostring(entry.model) .. " param=" .. tostring(entry.param) .. " left=" .. tostring(entry.left))
		end
	end
	if found < #list then
		log("stop details: " .. found .. "/" .. #list .. " found (proposal ids " .. C.ser(fromProposal) .. ", result edge objects " .. C.ser(results) .. ")")
	end
	state:set(st)
end

local function handleEvent(userParams, state, src, id, name, param)
	if not C.ACTIVE then return end
	if id == "apply_command" and name == "onPostBuildProposal" then
		log("engine: post build t=" .. tostring(gameTime()))
		if os.getenv("MPFEVER_CONDUMP") then
			pcall(function()
				local lines = {}
				for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
					local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
					local pp = c and c.transf and R.matPos(c.transf)
					if pp then lines[#lines + 1] = string.format("%s %.1f,%.1f #%d", tostring(c.fileName):match("[^/]+$"), pp.x, pp.y, e) end
				end
				table.sort(lines)
				local f = C.IO.open(C.DIR .. BS .. "conb_" .. tostring(gameTime()) .. ".txt", "wb")
				if f then f:write(table.concat(lines, NL) .. NL); f:close() end
			end)
		end
		local ok, err = pcall(enrichAfterBuild, state, param)
		if not ok then log("onPostBuildProposal failed: " .. tostring(err)) end
		pcall(function()
			local st = state:get() or {}
			if st.dynDiag ~= gameTime() then return end
			st.dynDiag = nil
			state:set(st)
			local res = param[3]
			local shown = 0
			for i = 1, #res do
				local e = res[i]
				if type(e) ~= "number" then pcall(function() e = e[1] end) end
				local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
				if okc and c and shown < 3 then
					shown = shown + 1
					local pd = ""
					pcall(function() pd = C.dump(c.params):sub(1, 160) end)
					log("asset construction entity " .. tostring(e) .. ": fileName '" .. tostring(c.fileName) .. "' params " .. pd .. " transf " .. tostring(R.matPos(c.transf) and R.matPos(c.transf).x))
				end
			end
		end)
		return
	end
	if id == "apply_command" and name == "onPreBuildProposal" then
		local ok, err = pcall(captureNativeBuild, state, param)
		if not ok then log("onPreBuildProposal capture failed: " .. tostring(err)) end
		return
	end

	if id ~= "mpfever" then return end
	local ok, err = pcall(function()
		local st = state:get() or {}
		if name == "queue" then
			st.q = st.q or {}
			st.q[#st.q + 1] = param
		elseif name == "pause_at" then
			st.pauseAt = param.at
			st.pausedAt = nil
		elseif name == "resume" then
			st.pauseAt = nil
			st.pausedAt = nil
		elseif name == "bind" then
			st.bind = st.bind or {}
			st.bind[param.key] = param.e
		elseif name == "co_apply" then
			pcall(coApply, st, param)
		elseif name == "share" then
			-- a company shares one of its stations with the others (fee per stop of another company's vehicle), or stops sharing it
			local reg = st.co
			if reg and reg.mode == "separate" and type(param.key) == "string" then
				local okS, errS = pcall(function()
					local found = nil
					for _, sg in ipairs(R.entitiesWith("STATION_GROUP")) do
						if R.sgKey(sg) == param.key then found = sg break end
					end
					local owner = found and CO.idOfEntity(reg, R.ownerOf(found)) or nil
					if owner and owner == param.mpfCo then
						reg.shares = reg.shares or {}
						local fee = math.floor(tonumber(param.fee) or 0)
						reg.shares[param.key] = (fee > 0) and fee or nil
						SIM.shareLinesAt = nil
						log("companies: company " .. owner .. (fee > 0 and (" shares its station " .. param.key .. " for " .. fee .. " per stop") or (" stops sharing its station " .. param.key)))
					else
						log("companies: share of " .. tostring(param.key) .. " refused (owner " .. tostring(owner) .. ", asked by " .. tostring(param.mpfCo) .. ")")
					end
				end)
				if not okS then log("companies: share failed: " .. tostring(errS)) end
			end
		elseif name == "co_set" then
			local c = st.co and CO.find(st.co, param.id)
			if c then c.ent = param.ent; log("companies: company " .. c.id .. " is player entity " .. tostring(param.ent) .. " here") end
		elseif name == "terrain_note" then
			st.terrainSig = ((st.terrainSig or 0) + (tonumber(param.v) or 0)) % 4294967296
		elseif name == "replaying" then
			st.replay = { at = gameTime(), n = ((st.replay and st.replay.at == gameTime()) and st.replay.n or 0) + 1 }
		elseif name == "auth" then
			for _, o in ipairs(st.authOwn or {}) do
				if o.n == param.n then correctMoney(o.auth, param, param.n, api.cmd.sendCommand, st.co) end
			end
		end
		state:set(st)
	end)
	if not ok then log("simulation event " .. tostring(name) .. " failed: " .. tostring(err)) end
end

-- ================================================================== GUI half (persistent, every frame)

local O = {}
local G = {
	inOff = 0, uiOff = 0, frames = 0, started = false, me = C.NAME, connected = false,
	session = { speed = 0, pauseAt = nil, started = false },
	peers = {},                -- other players' clocks (barrier)
	oseq = 0, outSent = 0, lastClock = -1,
	hashSent = -1, resultsSeen = {}, lastSet = -1,
	waits = {}, pendingPaused = {}, holdAt = nil, bind = {}, rev = {},
	ahead = 3, stampFloor = 0,    -- steps ahead of this game's stamps; no stamp below what others were allowed
}

-- Companies: the company whose action this game is replaying (G.actor, a player entity). The GUI's getPlayer() answers it while it is
-- set (see coGui); the continuations of a replay (command answers, deferred steps) run under the same company.
local WAITS_MT = { __newindex = function(t, k, v)
	if type(v) == "table" and v.actor == nil then v.actor = G.actor end
	rawset(t, k, v)
end }
setmetatable(G.waits, WAITS_MT)

local function withActor(ent, fn, ...)
	local prev = G.actor
	G.actor = ent
	local ok, r1, r2 = pcall(fn, ...)
	G.actor = prev
	if not ok then error(r1, 0) end
	return r1, r2
end

-- the player entity of the company that made an action (nil in the shared mode)
local function PL(a)
	if a and a.co and G.co then return CO.entityOf(G.co, a.co) end
	return nil
end

local function send(kind, payload)
	if not C.appendFile(C.DIR .. BS .. "out.log", C.line(kind, payload)) then log("cannot write out.log") end
end

local function readLines(fileName, offKey)
	local f = C.IO.open(C.DIR .. BS .. fileName, "rb")
	if not f then return {} end
	local size = f:seek("end")
	local lines = {}
	if size < G[offKey] then G[offKey] = 0 end
	if size > G[offKey] then
		f:seek("set", G[offKey])
		local chunk = f:read(size - G[offKey]) or ""
		local last, pos = nil, 1
		while true do
			local i = chunk:find(NL, pos, true)
			if not i then break end
			last = i
			local line = chunk:sub(pos, i - 1)
			if line:sub(-1) == CR then line = line:sub(1, -2) end
			if #line > 0 then lines[#lines + 1] = line end
			pos = i + 1
		end
		if last then G[offKey] = G[offKey] + last end
	end
	f:close()
	return lines
end

local function parseLine(line)
	local kind, from, payload = line:match("^([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "(.*)$")
	return kind, from, payload
end

local function toSim(name, param)
	O.sendCommand(O.event("mpfever", "mpfever", name, param))
end

local function setSpeed(sp)
	if sp ~= G.lastSet then
		G.lastSet = sp
		O.sendCommand(O.setSpeed(sp))
	end
end

-- queue an action on this game: simulation queue, or applied between steps while the session is paused
-- the game time at which an action issued now is applied everywhere
local function stampFor(t)
	return math.max(t + G.ahead * STEP, G.stampFloor)
end

-- stamp of an action issued while the session is paused: the games may have stopped a batch apart (a speed change
-- takes a frame), so the stamp is the latest of their times; the others catch up to it (pacing) before applying it
local function pausedStamp(now)
	local t = now
	for _, pc in pairs(G.peers) do if type(pc.t) == "number" and pc.t > t then t = pc.t end end
	return t
end

local function queueLocal(a)
	if a.paused then
		G.pendingPaused[#G.pendingPaused + 1] = a
	else
		toSim("queue", a)
	end
end

-- the speed this game may run at: session speed, never past the slowest other player (barrier), stop points
G.pstat = { frames = 0, barrier = 0, hold = 0 }
local function pacing()
	local now = gameTime()
	local s = G.session
	if not s.started then return 0 end
	local stopAt = s.pauseAt
	-- paused, but an action stamped later (another game stopped further): catch up to it, one step at a time
	local catchUp = s.pauseAt ~= nil and G.holdAt ~= nil and G.holdAt > s.pauseAt and now < G.holdAt
	if catchUp then stopAt = G.holdAt
	elseif G.holdAt and (stopAt == nil or G.holdAt < stopAt) then stopAt = G.holdAt end
	local barrier = nil
	for _, pc in pairs(G.peers) do
		-- window (see G.ahead): a game that overshoots this limit by its reserve is still before the time stamped on
		-- the peer's next action
		local limit = pc.t + (G.window or 3) * STEP
		if barrier == nil or limit < barrier then barrier = limit end
	end
	if barrier and (stopAt == nil or barrier < stopAt) then stopAt = barrier end
	local want = s.speed
	if s.pauseAt == nil and G.holdAt then want = math.max(1, want) end
	if catchUp then want = 1 end
	-- statistics (logged with "gui alive"): frames slowed down by the other players' clocks, or by held actions
	local ps = G.pstat
	ps.frames = ps.frames + 1
	local function slowed(r)
		if r < want and s.pauseAt == nil then
			if stopAt == barrier then ps.barrier = ps.barrier + 1 else ps.hold = ps.hold + 1 end
		end
		return r
	end
	G.wantSteps = nil
	if stopAt then
		if now >= stopAt then return slowed(0) end
		-- near a stop point, running at a speed would overshoot it (N steps per frame, a speed change takes a frame):
		-- the game pauses and the engine performs exactly the steps left
		-- (only for real stop points: the barrier keeps a reserve for the overshoot and moves all the time)
		if O.steps and stopAt ~= barrier and stopAt - now <= 2 * math.max(1, want) * STEP then
			G.wantSteps = math.floor((stopAt - now) / STEP)
			return slowed(0)
		end
		if want > 1 and stopAt - now < want * STEP then return slowed(1) end   -- do not overshoot a stop point inside a batch
	end
	return want
end

local H = {}

H.welcome = function(from, p)
	if p.you then G.me = p.you end
	G.connected = true
	log("connected to session as " .. tostring(G.me) .. " (" .. tostring(p.role) .. ")")
end

H.chat = function(from, p) log("chat " .. tostring(from) .. ": " .. tostring(p.text)) end

H.session = function(from, p)
	if p.cmode ~= nil then G.cmode = p.cmode; G.coStart = p.cstart end
	G.session.started = p.started == true
	G.session.speed = p.speed or 0
	if p.pauseAt ~= G.session.pauseAt then
		G.session.pauseAt = p.pauseAt
		if p.pauseAt then toSim("pause_at", { at = p.pauseAt }) else toSim("resume", {}) end
	end
end

H.peerclock = function(from, p)
	if p.name and p.name ~= G.me then G.peers[p.name] = { t = p.t, ah = p.ah } end
end

H.peerleft = function(from, p)
	if p.name then G.peers[p.name] = nil end
end

-- native builds of other players: replayed here (callbacks give the engine's verdict), as soon as this game has
-- reached their time
G.nativeQueue = {}
local nativeReceived
-- how far ahead of this game an announced action still is when it arrives (steps): the margin the stamp distance leaves
-- The stamp distance (G.ahead) is the safe worst case. It is shortened (never below 60%) when the margins really left on
-- the announcements this game receives show that the games stay well within it, and given back for good the first time an
-- action arrives late.
G.consumed = {}
local function adaptAhead(base)
	-- (opt-in, MPFEVER_ADAPTAHEAD=1: on a loaded PC builds already arrive up to 3 steps late with the full distance, so it is
	-- not shortened by default)
	if not os.getenv("MPFEVER_ADAPTAHEAD") or G.aheadLocked or #G.consumed < 8 then return base end
	local mx = 0
	for _, c in ipairs(G.consumed) do mx = math.max(mx, c) end
	return math.max(math.ceil(base * 0.6), math.min(base, math.ceil(mx * 1.5) + 4))
end

local function logMargin(kind, at, origin)
	local ok, now = pcall(gameTime)
	if ok and type(at) == "number" then
		local m = (at - now) / STEP
		-- what the stamp's distance lost on the way: the other game's lead and the network
		local pa = origin and G.peers[origin] and G.peers[origin].ah
		if pa and (kind == "nat_pending" or kind == "act") then
			table.insert(G.consumed, pa + (kind == "nat_pending" and 1 or 0) - m)
			if #G.consumed > 12 then table.remove(G.consumed, 1) end
		end
		G.minMargin = math.min(G.minMargin or 99, m)
		log("MARGIN " .. kind .. " " .. m .. " steps (smallest so far " .. G.minMargin .. ", stamp distance " .. tostring(G.ahead) .. ", speed " .. tostring(G.session.speed) .. ") [frame " .. G.frames .. "]")
	end
end

H.act = function(from, p)
	logMargin(p.native and "act(native)" or "act", p.at, p.origin)
	p.recvFrame = G.frames
	if p.native then
		G.nativeQueue[#G.nativeQueue + 1] = p
		if nativeReceived then pcall(nativeReceived, p) end
	else
		queueLocal(p)
	end
end

-- Replays of other players' builds: the engine applies a command a frame later (verdict in the callback). Until it
-- has, this game stays where it is (nativeHoldAt): resuming at once would let it run steps before the build lands.
-- The dust cloud of a construction going up is an effect of the interface, not of the simulation: only the game whose
-- tool issued the build shows it. The games that replay the build show it too.
local function buildEffects(res, success)
	if not success then return end
	local ok, err = pcall(function()
		local P = res.proposal
		if P == nil then return end
		local n = #P.toAdd
		for k = 1, math.min(n, 4) do
			local ce = P.toAdd[k]
			-- a box around the construction (its real size is not read: a puff the size of a small building)
			api.gui.rendering.spawnDust(api.type.Vec3f.new(-10, -10, 0), api.type.Vec3f.new(10, 10, 6), ce.transf)
		end
		G.dustCount = (G.dustCount or 0) + n
		if n > 0 and G.dustCount <= 8 then log("build effects: dust shown for " .. n .. " replayed construction(s)") end
	end)
	if not ok and not G.dustFailed then
		G.dustFailed = true
		log("build effects: no dust for replayed builds (" .. tostring(err):sub(1, 160) .. ")")
	end
end

local function replaySend(cmd, cb)
	G.replayOut = (G.replayOut or 0) + 1
	G.replaySince = G.frames
	local who = G.actor
	O.sendCommand(cmd, function(...)
		G.replayOut = math.max(0, (G.replayOut or 1) - 1)
		G.replayQuiet = G.frames + 3   -- room for a follow-up command (next segment, next form)
		pcall(buildEffects, ...)
		if cb then return withActor(who, cb, ...) end
	end)
end

-- engine verdicts arrive in callbacks: a refused native replay is retried with the next form, in a fixed order
local REPLAY_FORMS = {
	-- the tool's proposal is already cleaned up: cleaning it again can split a curved segment (one more segment here)
	{ v = "minimal", raw = true, ctx = "terrainNoCleanup" },
	{ v = "minimal", raw = true, ctx = "terrain" }, { v = "minimal", raw = true, ctx = "plain" },
	{ v = "minimalNoOwner", raw = true, ctx = "terrain" }, { v = "minimal", raw = true, ctx = "nil" },
	{ v = "minimal", ctx = "terrain" }, { v = "full", raw = true, ctx = "terrain" },
}
if os.getenv("MPFEVER_FORM1") then REPLAY_FORMS[1].ctx = os.getenv("MPFEVER_FORM1") end

-- A pure upgrade (every added segment replaces a removed one between the same nodes, nothing else): the engine's
-- replaceSegment builds it exactly as the upgrade tool does.
local function upgradePlan(margs)
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return nil end
	if #(st.addedNodes or {}) > 0 or #(st.removedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return nil end
	-- a stop removed with the bulldozer looks like an upgrade, but replaceSegment would keep the stop
	if #(st.edgeObjectsToRemove or {}) > 0 then return nil end
	-- constructions: only town buildings the engine moved for the new street (nobody's, -1); every game's own
	-- replaceSegment moves them the same way (a rebuilt proposal could not make them town buildings again)
	local tAdd, tRem = margs[1].toAdd or {}, margs[1].toRemove or {}
	-- buildings moved for the new street: the engine picks their new places at random, so every game would put them
	-- elsewhere (the town then grows differently): they are rebuilt exactly as the originator's engine placed them
	if #tAdd > 0 or #tRem > 0 then return nil end
	local added, removed = st.addedSegments or {}, st.removedSegments or {}
	if #added == 0 or #added ~= #removed then return nil end
	local plan = {}
	for _, ad in ipairs(added) do
		local c = ad.comp or {}
		local match, decorations = nil, nil
		local customLanes = C.customLanes(ad)
		for _, rm in ipairs(removed) do
			local rc = rm.comp or {}
			if (rc.node0 == c.node0 and rc.node1 == c.node1) or (rc.node0 == c.node1 and rc.node1 == c.node0) then
				match = rm.entity
				-- more than a new template (a bridge, a different track...): replaceSegment would not make it
				if c.type ~= rc.type or c.typeIndex ~= rc.typeIndex or c.roadType ~= rc.roadType or ad.type ~= rm.type then return nil end
				-- (the decorations, a noise barrier for instance, are put on the engine's upgrade proposal below)
				if C.ser(c.edgeDecorations or {}) ~= C.ser(rc.edgeDecorations or {}) then decorations = c.edgeDecorations or {} end
			end
		end
		if type(match) ~= "number" or match < 0 then return nil end
		plan[#plan + 1] = { edge = match, template = c.roadTemplate, decorations = decorations, lanes = customLanes, n0 = c.node0 }
	end
	return plan
end

local function replayUpgrade(a, plan, i)
	local step = plan[i]
	if not step then return end
	local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(step.edge, step.template) end)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": no proposal " .. tostring(P))
		return replayUpgrade(a, plan, i + 1)
	end
	if step.decorations or step.lanes then
		-- the engine's upgrade proposal with what the template does not give: the originator's decorations (noise
		-- barrier...) and lanes (tram tracks on a road) on the new segment
		local okd, errd = pcall(function()
			local sp = P.proposal
			local list = sp.addedSegments
			local seg = list[1]
			local cmp = seg.comp
			if step.decorations then
				-- a decoration has a side (left of the segment's direction): when this game's segment runs the other way
				-- round than the originator's, the side is the opposite one
				local deco = C.plain(step.decorations)
				local be = api.engine.getComponent(step.edge, api.type.ComponentType.BASE_EDGE)
				if be and type(step.n0) == "number" and be.node0 ~= step.n0 then
					for _, d in ipairs(deco) do if type(d) == "table" then d[2] = not d[2] end end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " segment " .. step.edge .. " runs the other way round: decoration sides swapped")
				end
				cmp.edgeDecorations = deco
			end
			if step.lanes then cmp.laneConfigs = C.rebuildLanes(step.lanes) end
			seg.comp = cmp
			list[1] = seg
			sp.addedSegments = list
			P.proposal = sp
		end)
		if not okd then log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": decorations/lanes not applied (" .. shortErr(errd) .. ")") end
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = true
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	toSim("replaying", {})
	replaySend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of segment " .. step.edge .. " to " .. tostring(step.template) .. ": " .. (success and "BUILT" or ("refused " .. why)))
		pcall(function()
			local at = {}
			for k = 1, #res.proposal.toAdd do
				local ce = res.proposal.toAdd[k]
				local t = ce.transf
				at[#at + 1] = tostring(ce.fileName):match("[^/]+$") .. "@" .. string.format("%.1f,%.1f", t[13] or 0, t[14] or 0)
			end
			if #at > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " engine's own constructions: " .. table.concat(at, " ") .. "; removed " .. #res.proposal.toRemove) end
		end)
		G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayUpgrade(a, plan, i + 1) end }
	end)
end

-- A pure removal (bulldozer): the engine's own removal proposal
local function removalPlan(margs)
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return nil end
	if #(st.addedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return nil end
	-- buildings demolished with the road (toRemove) are recomputed by every game's own removal proposal
	if #(margs[1].toAdd or {}) > 0 then return nil end
	-- segments the engine merged after the removal are re-added between surviving nodes: the bulldozed segments are
	-- the removed ones touching none of those ends (every game's engine redoes the same merge)
	local ends = {}
	for _, ad in ipairs(st.addedSegments or {}) do
		local c = ad.comp or {}
		if type(c.node0) ~= "number" or c.node0 < 0 or type(c.node1) ~= "number" or c.node1 < 0 then return nil end
		ends[c.node0] = true
		ends[c.node1] = true
	end
	local list = {}
	for _, rm in ipairs(st.removedSegments or {}) do
		if type(rm.entity) ~= "number" or rm.entity < 0 then return nil end
		local c = rm.comp or {}
		if not (ends[c.node0] or ends[c.node1]) then list[#list + 1] = rm.entity end
	end
	if #list == 0 then return nil end
	return list
end

local function engineReplay(a, what, makeP)
	local okp, P = pcall(makeP)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": no proposal " .. tostring(P))
		return
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = true
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	toSim("replaying", {})
	replaySend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": " .. (success and "BUILT" or ("refused " .. why)))
	end)
end

-- A stop placed on an existing street (the stop tool): rebuilt as the street tool would, from this game's segment
local function sVec(q) return api.type.Vec3f.new(q.x, q.y, q.z) end
local function sNodePos(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and { x = c.position.x, y = c.position.y, z = c.position.z } or nil
end
local function sContext()
	local c = api.type.Context.new()
	c.checkTerrainAlignment = false
	c.cleanupStreetGraph = true
	c.gatherBuildings = false
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	return c
end

local function stopPlan(margs)
	local st = margs[1].proposal
	if #(st.addedNodes or {}) > 0 or #(st.addedSegments or {}) ~= 1 or #(st.removedSegments or {}) ~= 1 then
		return nil, "not a single segment replacement"
	end
	local ad, rm = st.addedSegments[1], st.removedSegments[1]
	local E = rm.entity
	if type(E) ~= "number" or E < 0 then return nil, "segment unresolved" end
	local objs = {}
	for i, o in ipairs(st.edgeObjectsToAdd or {}) do
		if type(o.model) ~= "string" then return nil, "stop " .. i .. " without model" end
		objs[#objs + 1] = o
	end
	-- removed stops (bulldozer): their ids differ between games, their rank on the segment does not
	local gone, removeIdx = {}, {}
	for _, id in ipairs(st.edgeObjectsToRemove or {}) do gone[id] = true end
	for k, o in ipairs((rm.comp or {}).objects or {}) do
		if type(o) == "table" and gone[o[1]] then removeIdx[k] = true end
	end
	return { E = E, seg = ad, objs = objs, removeIdx = removeIdx, nodeConfigs = st.nodeConfigsToAdd or {}, segType = rm.type }
end

local function replayStop(a, plan, variant)
	variant = variant or 1
	local c = api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE)
	if not c then log("NATIVE REPLAY " .. tostring(a.uid) .. ": stop segment missing"); return end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = (type(plan.segType) == "number") and plan.segType or 0   -- 1: a track (a signal)
	local cc = e.comp
	local sc = plan.seg.comp or {}
	cc.node0 = c.node0; cc.node1 = c.node1
	cc.tangent0 = sVec(c.tangent0); cc.tangent1 = sVec(c.tangent1)
	cc.position0 = sVec(sNodePos(c.node0)); cc.position1 = sVec(sNodePos(c.node1))
	cc.type = 0; cc.typeIndex = -1
	cc.roadTemplate = sc.roadTemplate or c.roadTemplate
	cc.roadStyle = sc.roadStyle or c.roadStyle
	cc.roadType = c.roadType
	-- lanes as the stop tool computed them: on a street without sidewalks it adds the platform lanes, without which
	-- the engine accepts the build but silently drops the stop
	local capLanes = sc.laneConfigs
	if type(capLanes) == "table" and #capLanes > 0 then
		cc.laneConfigs = C.rebuildLanes(capLanes)
	else
		cc.laneConfigs = c.laneConfigs
	end
	-- objects: the stops already on this segment, then the new ones (placeholders, side)
	local list, removeIds = {}, {}
	for i = 1, #c.objects do
		if plan.removeIdx and plan.removeIdx[i] then removeIds[#removeIds + 1] = c.objects[i][1]
		else list[#list + 1] = { c.objects[i][1], c.objects[i][2] } end
	end
	-- the kind of each new object on the segment: a stop on the left (0) or the right (1), or a signal (2)
	for k, o in ipairs(plan.objs) do list[#list + 1] = { -400000000 - (k - 1), (o.category == 2) and 2 or (o.left and 0 or 1) } end
	cc.objects = list
	e.comp = cc
	local se = e.streetEdge
	se.precedenceNode0 = (plan.seg.streetEdge and plan.seg.streetEdge.precedenceNode0) or 2
	se.precedenceNode1 = (plan.seg.streetEdge and plan.seg.streetEdge.precedenceNode1) or 2
	e.streetEdge = se
	local eos = {}
	for k, o in ipairs(plan.objs) do
		local eo = api.type.SimpleStreetProposal.EdgeObject.new()
		eo.edgeEntity = -1
		eo.param = o.param or 0.5
		eo.oneWay = o.oneWay == true
		eo.left = o.left == true
		-- (variant 2, for what the stop tool does not place: the model name as the capture has it)
		eo.model = (variant == 2) and o.model or (o.model:gsub("^::/", ""))
		eo.playerEntity = api.engine.util.getPlayer()
		pcall(function() eo.name = o.name or "" end)
		eos[k] = eo
	end
	local ncr = {}
	for _, n in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = n end
	end
	ssp.edgesToRemove = { plan.E }
	ssp.edgesToAdd = { e }
	ssp.edgeObjectsToAdd = eos
	if #removeIds > 0 then ssp.edgeObjectsToRemove = removeIds end
	if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
	sp.streetProposal = ssp
	local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, sContext(), false, true) end)
	if not okf or not cmd then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: factory (variant " .. variant .. ") " .. shortErr(cmd))
		if variant < 2 then return replayStop(a, plan, variant + 1) end
		return
	end
	local function stopCount()
		local n = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
		return n
	end
	local before = stopCount()
	toSim("replaying", {})
	replaySend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop on segment " .. plan.E .. ": " .. (success and "BUILT" or ("refused " .. why)))
		if success then
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local after = stopCount()
				local expected = before + #plan.objs - #removeIds
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stops on the map " .. before .. " -> " .. after .. ((after == expected) and "" or (" (EXPECTED " .. expected .. ")")))
			end }
		end
	end)
end

-- A construction placed against a street (depot, station): the tool's proposal also splits the street for it. The
-- engine refuses it rebuilt as one SimpleProposal ("Construction impossible"; without the street part: "Collision"),
-- and the native proposal type refuses the removed segments we rebuild ("Unknown exception"). So it is replayed in two
-- steps, in the order the engine needs: the street part alone (the forms that rebuild roads), then the construction
-- alone on the street that is now cut.
-- why the engine refused a build: error state, colliding entities and what they are
local function logRefusal(a, res)
	pcall(function()
		local rpd = res.resultProposalData
		log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: errorState " .. C.ser(C.marshal(rpd.errorState)):sub(1, 400))
		pcall(function() log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: collisionInfo " .. C.ser(C.marshal(rpd.collisionInfo)):sub(1, 500)) end)
		pcall(function()
			local ent = rpd.collisionInfo.collisionEntities[1].entity
			local have = {}
			for _, name in ipairs({ "BASE_EDGE", "BASE_NODE", "CONSTRUCTION", "TOWN_BUILDING", "STATION", "MODEL_INSTANCE_LIST", "NAME", "PLAYER_OWNED",
				"VEHICLE_DEPOT", "SUBCONSTRUCTION", "EDGE_OBJECT", "INDUSTRY", "WAREHOUSE" }) do
				local okc, c = pcall(function() return api.engine.getComponent(ent, api.type.ComponentType[name]) end)
				if okc and c then have[#have + 1] = name end
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: colliding entity " .. tostring(ent) .. " components {" .. table.concat(have, ",") .. "}")
			pcall(function()
				local be = api.engine.getComponent(ent, api.type.ComponentType.BASE_EDGE)
				if be then
					local function pos(n) local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) return c and string.format("(%.1f %.1f %.1f)", c.position.x, c.position.y, c.position.z) or "?" end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: edge " .. ent .. " " .. be.node0 .. pos(be.node0) .. " -> " .. be.node1 .. pos(be.node1) .. " " .. tostring(be.roadTemplate))
				end
			end)
			local okt, tf = pcall(function() return api.engine.getComponent(ent, api.type.ComponentType.CONSTRUCTION) end)
			if okt and tf then log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: construction " .. tostring(tf.fileName)) end
		end)
	end)
end

-- a build this game could not reproduce: the host reloads its game for everybody at once (without waiting for the
-- next checkpoints to notice the difference)
local function replayFailed(a, why)
	pcall(send, "replay_failed", { uid = tostring(a.uid), why = tostring(why):sub(1, 120) })
end

-- the street segments a construction brings with it (the entrance of a depot or of a street station, the paths of a
-- rail station): they belong to the construction, whose own script makes them
local function isConstructionSegment(sg)
	local tpl = tostring(sg and sg.comp and sg.comp.roadTemplate or "")
	return tpl:find("/constructions/", 1, true) ~= nil or tpl:find("simple.street_template", 1, true) ~= nil
end

local function hasConstructionSegments(m)
	if type(m) ~= "table" or #(m.toAdd or {}) == 0 or type(m.proposal) ~= "table" then return false end
	for _, sg in ipairs(m.proposal.addedSegments or {}) do if isConstructionSegment(sg) then return true end end
	return false
end

local STREET_FORMS = {
	{ v = "minimal", raw = true, ctx = "terrainNoCleanup" }, { v = "minimal", raw = true, ctx = "terrain" },
	{ v = "minimal", raw = true, ctx = "plain" }, { v = "full", raw = true, ctx = "terrain" },
}

-- Construction against a street, rebuilt as the tool's own native proposal (see C.rebuildNativeWithConstruction): the
-- engine converts the construction for us (the converted proposal comes back with the result of a command that is
-- refused on purpose: the same construction twice at the same place collides with itself, nothing is built).
local replayTwoStep
-- (diagnostic, MPFEVER_DEPOTEXP=1) which part of a rebuilt native construction proposal the command factory refuses; factories only,
-- nothing is sent to the engine
local function depotExperiments(a, m, conv, rm, ctx)
	local out = {}
	local function try(name, build)
		log("DEPOTEXP " .. tostring(a.uid) .. " trying " .. name)
		C.errors = {}
		local okb, P = pcall(build)
		if not okb then out[#out + 1] = name .. "=build " .. shortErr(P) return end
		local ok, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true) end)
		out[#out + 1] = name .. "=" .. ((ok and cmd) and "OK" or shortErr(cmd)) .. (#C.errors > 0 and (" [" .. table.concat(C.errors, ";"):sub(1, 120) .. "]") or "")
	end
	local st = m.proposal
	local function base(opts) return C.rebuildNativeWithConstruction(m, conv, rm, opts) end
	try("full", function() return base() end)
	out[#out + 1] = "frozen " .. tostring(C.frozenHow)
	try("keepFrozen", function() return base({ keepFrozen = true }) end)
	try("noConfigsNoMaps", function() return base({ noConfigs = true, noMaps = true }) end)
	try("streetOnly", function()
		local P = api.type.Proposal.new()
		local sp = P.proposal
		local nodes, edges = {}, {}
		for i, n in ipairs(st.addedNodes or {}) do nodes[i] = C.rebuild("NodeAndEntity", n, "n" .. i) end
		for i, sg in ipairs(st.addedSegments or {}) do edges[i] = C.rebuild("SegmentAndEntity", sg, "s" .. i) end
		for i, e in ipairs(edges) do local c = e.comp c.laneConfigs = C.rebuildLanes(st.addedSegments[i].comp.laneConfigs) e.comp = c end
		sp.addedNodes = nodes sp.addedSegments = edges P.proposal = sp
		return P
	end)
	-- the segment rebuilt with the minimal fields, with and without its owner
	for _, v in ipairs({ { "minimalSeg", false }, { "minimalSegNoOwner", true } }) do
		try(v[1], function()
			local P = api.type.Proposal.new()
			local l = {} l[1] = conv.toAdd[1] P.toAdd = l
			local sp = P.proposal
			local nodes, edges = {}, {}
			for i, n in ipairs(st.addedNodes or {}) do nodes[i] = C.rebuild("NodeAndEntity", n, "n" .. i) end
			for i, sg in ipairs(st.addedSegments or {}) do
				local e = C.minimalSegment(sg, v[2], false)
				local c = e.comp c.laneConfigs = C.rebuildLanes(sg.comp.laneConfigs) e.comp = c
				edges[i] = e
			end
			sp.addedNodes = nodes sp.addedSegments = edges P.proposal = sp
			return P
		end)
	end
	-- the existing junction as a new node at the same place (what a split does)
	try("junctionAsNewNode", function()
		local P = api.type.Proposal.new()
		local l = {} l[1] = conv.toAdd[1] P.toAdd = l
		local sp = P.proposal
		local nodes, edges = {}, {}
		for i, n in ipairs(st.addedNodes or {}) do nodes[i] = C.rebuild("NodeAndEntity", n, "n" .. i) end
		local extra = {}
		for i, sg in ipairs(st.addedSegments or {}) do
			local c = C.deser(C.ser(sg))
			for _, k in ipairs({ "node0", "node1" }) do
				if type(c.comp[k]) == "number" and c.comp[k] >= 0 then
					local q = api.engine.getComponent(c.comp[k], api.type.ComponentType.BASE_NODE).position
					local ne = api.type.NodeAndEntity.new() ne.entity = -50 - #extra ne.comp.position = api.type.Vec3f.new(q.x, q.y, q.z)
					extra[#extra + 1] = ne
					c.comp[k] = ne.entity
				end
			end
			local e = C.rebuild("SegmentAndEntity", c, "s" .. i)
			local cc = e.comp cc.laneConfigs = C.rebuildLanes(sg.comp.laneConfigs) e.comp = cc
			edges[i] = e
		end
		for _, ne in ipairs(extra) do nodes[#nodes + 1] = ne end
		sp.addedNodes = nodes sp.addedSegments = edges P.proposal = sp
		return P
	end)
	-- the converted construction's own street part (what the engine generated for it)
	pcall(function()
		local cp = conv.proposal
		out[#out + 1] = "conv street: +nodes " .. #cp.addedNodes .. " +segments " .. #cp.addedSegments .. " frozen " .. C.ser(C.marshal(conv.toAdd[1].frozenNodes)) .. "/" .. C.ser(C.marshal(conv.toAdd[1].frozenEdges))
	end)
	log("DEPOTEXP " .. tostring(a.uid) .. ": " .. table.concat(out, " ; "))
end

local function replayNativeConstruction(a)
	local m0 = a.args[1]
	if not hasConstructionSegments(m0) then return false end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: unresolved " .. table.concat(miss, ",")) return false end
	local m = cArgs[1]
	-- the engine's conversion of the construction (twice: guaranteed collision, so that nothing is built)
	local spCon = C.rebuildProposal(m, { noStreet = true, seed = 7919 })
	local cons = {}
	do
		local one = spCon.constructionsToAdd
		cons[1] = one[1]
		local two = C.rebuildProposal(m, { noStreet = true, seed = 7919 }).constructionsToAdd
		cons[2] = two[1]
		spCon.constructionsToAdd = cons
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = false
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	local okc, dry = pcall(function() return api.cmd.makeWorldBuildProposalCmd(spCon, ctx, false, true) end)
	if not okc or not dry then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: conversion command " .. shortErr(dry)) return false end
	toSim("replaying", {})
	local edgesBefore = #R.allEdges()
	replaySend(dry, function(res, success)
		if success then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the conversion command was built instead of refused (desync)")
			replayFailed(a, "conversion built")
			return
		end
		local conv = res.proposal
		local okn, nconv = pcall(function() return #conv.toAdd end)
		if not okn or nconv < 1 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: no converted construction in the result (" .. tostring(nconv) .. ")") replayFailed(a, "no converted construction") return end
		-- the removed segments as the engine's own removal proposal makes them
		local rmIds = {}
		for _, sg in ipairs(m.proposal.removedSegments or {}) do if type(sg.entity) == "number" then rmIds[#rmIds + 1] = sg.entity end end
		local okr, rm = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal(rmIds) end)
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: removal proposal " .. shortErr(rm)) rm = nil end
		-- the engine's removal must be the tool's removal (same number of segments and nodes), else nothing is built
		local function ids(list, field)
			local t = {}
			pcall(function() for i = 1, #list do t[#t + 1] = tostring(field and list[i][field] or list[i]) end end)
			return table.concat(t, ",")
		end
		local capNodes = {}
		for _, nd in ipairs(m.proposal.removedNodes or {}) do capNodes[#capNodes + 1] = tostring(nd.entity) end
		local engSeg, engNodes = "?", "?"
		local nSeg, nNodes = -1, -1
		pcall(function() nSeg = #rm.proposal.removedSegments engSeg = ids(rm.proposal.removedSegments, "entity") end)
		pcall(function() nNodes = #rm.proposal.removedNodes engNodes = ids(rm.proposal.removedNodes, "entity") end)
		log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: removal segments tool {" .. table.concat((function() local t = {} for i, v in ipairs(rmIds) do t[i] = tostring(v) end return t end)(), ",") .. "} engine {" .. engSeg .. "}; nodes tool {" .. table.concat(capNodes, ",") .. "} engine {" .. engNodes .. "}")
		-- (same segments, other nodes: the engine also removes the free end of a dead-end street the tool kept, because the
		-- construction's entrance joins it there; the tool's removed nodes are then written instead of the engine's)
		local toolNodes = nSeg == #rmIds and nNodes ~= #capNodes and nNodes >= 0
		if nSeg ~= #rmIds or nNodes < 0 then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the engine's removal differs from the tool's (desync)")
			replayFailed(a, "removal differs")
			return
		end
		if toolNodes then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the tool's removed nodes are kept (the engine's removal has other nodes)") end
		C.errors = {}
		local okp, P = pcall(C.rebuildNativeWithConstruction, m, conv, rm, { toolNodes = toolNodes })
		if not okp or not P then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: not rebuilt (" .. shortErr(P) .. ")") replayFailed(a, "native rebuild") return end
		do
			local notes = {}
			for _, e in ipairs(C.errors) do if not tostring(e):find("no writable member 'params'", 1, true) then notes[#notes + 1] = e end end
			if #notes > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: rebuild notes " .. table.concat(notes, "; ")) end
		end
		local ctx2 = api.type.Context.new()
		ctx2.checkTerrainAlignment = true
		ctx2.cleanupStreetGraph = false
		ctx2.gatherBuildings = true
		ctx2.gatherFields = true
		ctx2.player = api.engine.util.getPlayer()
		local okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx2, false, true) end)
		if (not okk or not cmd) and os.getenv("MPFEVER_DEPOTEXP") then
			local oke, erre = pcall(depotExperiments, a, m, conv, rm, ctx2)
			if not oke then log("DEPOTEXP failed: " .. tostring(erre)) end
		end
		if not okk or not cmd then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: command " .. shortErr(cmd))
			-- the engine's own node configurations and id maps are recomputed when the proposal does not carry them
			for vi, variant in ipairs({ { noConfigs = true }, { noConfigs = true, noMaps = true } }) do
				if okk and cmd then break end
				C.errors = {}
				variant.toolNodes = toolNodes
				local okp2, P2 = pcall(C.rebuildNativeWithConstruction, m, conv, rm, variant)
				if okp2 and P2 then
					okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P2, ctx2, false, true) end)
					log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: second try " .. vi .. " (" .. (variant.noMaps and "without node configurations and id maps" or "without node configurations") .. "): " .. ((okk and cmd) and "command made" or shortErr(cmd)))
				end
			end
		end
		if not okk or not cmd then
			-- (the street part and the construction in two steps, see replayTwoStep)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: trying the two-step replay")
			if not replayTwoStep(a) then replayFailed(a, "native command") end
			return
		end
		toSim("replaying", {})
		replaySend(cmd, function(res2, success2)
			if not success2 then
				local why = ""
				pcall(function() why = C.ser(C.marshal(res2.resultProposalData.errorState.messages)) end)
				log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: refused " .. why .. " (desync)")
				logRefusal(a, res2)
				replayFailed(a, "native construction refused " .. why)
				return
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction BUILT")
			pcall(function()
				local st = res2.proposal.proposal
				log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments .. " +constructions " .. #res2.proposal.toAdd)
			end)
			local expected = #(m.proposal.addedSegments or {}) - #(m.proposal.removedSegments or {})
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local got = #R.allEdges() - edgesBefore
				log("NATIVE REPLAY " .. tostring(a.uid) .. " edges here " .. got .. ", originator " .. expected .. (got == expected and "" or " SEGMENT COUNT DIFFERS"))
			end }
		end)
	end)
	return true
end

function replayTwoStep(a)
	local m0 = a.args[1]
	if type(m0) ~= "table" or #(m0.toAdd or {}) == 0 or type(m0.proposal) ~= "table" then return false end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: unresolved " .. table.concat(miss, ",")) return false end

	local function buildConstruction()
		local okr, args, n = pcall(C.rebuildArgs, a.fn, C.deser(C.ser(cArgs)), { seed = 7919, variant = "minimal", raw = true, ctx = "terrainNoCleanup", noStreet = true })
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction not rebuilt (" .. shortErr(args) .. ")") replayFailed(a, "construction not rebuilt") return end
		args[3] = true args[4] = false   -- (non-critical collision with its own street connection: ignored)
		local okk, cmd2 = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
		if not okk or not cmd2 then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction command " .. shortErr(cmd2)) replayFailed(a, "construction command") return end
		toSim("replaying", {})
		replaySend(cmd2, function(res2, success2)
			local why = ""
			if not success2 then pcall(function() why = C.ser(C.marshal(res2.resultProposalData.errorState.messages)) end) end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction " .. (success2 and "BUILT" or ("refused " .. why .. " (desync)")))
			if success2 then pcall(function()
				local st2 = res2.proposal.proposal
				log("NATIVE REPLAY " .. tostring(a.uid) .. " construction engine applied: +nodes " .. #st2.addedNodes .. " -nodes " .. #st2.removedNodes .. " +segments " .. #st2.addedSegments .. " -segments " .. #st2.removedSegments .. " +constructions " .. #res2.proposal.toAdd)
			end) end
			if not success2 then logRefusal(a, res2) replayFailed(a, "construction refused " .. why) end
		end)
	end

	-- the street part without the construction's own entrance (see above); `together`: with the construction in the same
	-- proposal (the engine then connects the construction's free node to the street node itself)
	local edgesBefore = #R.allEdges()
	local function streetStep(k, together)
		local form = STREET_FORMS[k]
		if not form then
			if together then return streetStep(1, false) end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street part refused by every form (desync)")
			replayFailed(a, "street part refused")
			return
		end
		local sArgs = C.deser(C.ser(cArgs))
		if not together then
			sArgs[1].toAdd = {}
			sArgs[1].toRemove = {}
		end
		local dropped = {}
		pcall(function()
			local st = sArgs[1].proposal
			local keepSeg, usedNode = {}, {}
			for _, sg in ipairs(st.addedSegments or {}) do
				if isConstructionSegment(sg) then dropped[#dropped + 1] = sg.entity else keepSeg[#keepSeg + 1] = sg end
			end
			if #dropped > 0 then
				for _, sg in ipairs(keepSeg) do usedNode[sg.comp.node0] = true usedNode[sg.comp.node1] = true end
				local keepNodes = {}
				for _, nd in ipairs(st.addedNodes or {}) do if usedNode[nd.entity] then keepNodes[#keepNodes + 1] = nd end end
				st.addedSegments = keepSeg
				st.addedNodes = keepNodes
				-- (the lane connections this tool computed around the entrance are left to the engine: sending them back
				-- makes the command factory throw)
				st.nodeConfigsToAdd = {}
			end
		end)
		local label = (together and "with the construction, " or "") .. form.v .. "/" .. form.ctx
		local okr, args, n = pcall(C.rebuildArgs, a.fn, sArgs, { seed = 7919, variant = form.v, ctx = form.ctx, raw = form.raw })
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " rebuild " .. shortErr(args)) return streetStep(k + 1, together) end
		-- with the construction: the collisions the engine reports are the construction against its own street connection
		-- (non-critical errors): the build goes on, as the game's own scripts do (ignoreErrors = true)
		if together then args[3] = true args[4] = false end
		local okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
		if not okc or not cmd then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " command " .. shortErr(cmd)) return streetStep(k + 1, together) end
		toSim("replaying", {})
		replaySend(cmd, function(res, success)
			if not success then
				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " refused " .. why)
				logRefusal(a, res)
				G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() streetStep(k + 1, together) end }
				return
			end
			if together then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " BUILT street part and construction together with " .. label)
				pcall(function()
					local st = res.proposal.proposal
					log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments .. " +constructions " .. #res.proposal.toAdd)
				end)
				local expected = #(m0.proposal.addedSegments or {}) - #(m0.proposal.removedSegments or {})
				G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
					local got = #R.allEdges() - edgesBefore
					log("NATIVE REPLAY " .. tostring(a.uid) .. " edges here " .. got .. ", originator " .. expected .. (got == expected and "" or " SEGMENT COUNT DIFFERS"))
				end }
				return
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street part BUILT with " .. label)
			G.waits[#G.waits + 1] = { at = G.frames + 3, fn = buildConstruction }
		end)
	end
	streetStep(1, true)
	return true
end

local function replayNative(a, formIndex)
	if formIndex == 1 then
		pcall(function()
			local m = a.args[1]
			local st = m.proposal or {}
			log("NATIVE REPLAY " .. tostring(a.uid) .. " shape: +nodes " .. #(st.addedNodes or {}) .. " -nodes " .. #(st.removedNodes or {})
				.. " +segments " .. #(st.addedSegments or {}) .. " -segments " .. #(st.removedSegments or {}) .. " stops " .. #(st.edgeObjectsToAdd or {})
				.. " +constructions " .. #(m.toAdd or {}) .. " -constructions " .. #(m.toRemove or {}))
			-- what exactly is built (for bug reports: station models, underground segments, heights)
			local names, zmin, zmax, kinds = {}, nil, nil, {}
			for _, ce in ipairs(m.toAdd or {}) do names[#names + 1] = tostring(ce.fileName) end
			for _, nd in ipairs(st.addedNodes or {}) do
				local z = nd.comp and nd.comp.position and nd.comp.position.z
				if type(z) == "number" then zmin = math.min(zmin or z, z) zmax = math.max(zmax or z, z) end
			end
			for _, sg in ipairs(st.addedSegments or {}) do
				kinds[#kinds + 1] = tostring(sg.comp and sg.comp.type) .. "/" .. tostring(sg.comp and sg.comp.typeIndex)
			end
			do
				local at = {}
				for _, ce in ipairs(m.toAdd or {}) do
					local t = ce.transf
					at[#at + 1] = tostring(ce.fileName):match("[^/]+$") .. "@" .. string.format("%.1f,%.1f", t and t[13] or 0, t and t[14] or 0)
				end
				if #at > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " originator's constructions: " .. table.concat(at, " ") .. "; removed " .. #(m.toRemove or {})) end
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " detail: constructions {" .. table.concat(names, ", ") .. "} node heights " ..
				tostring(zmin) .. ".." .. tostring(zmax) .. " segment type/index {" .. table.concat(kinds, ", ") .. "}")
		end)
		local probe = C.deser(C.ser(a.args))
		local missing = R.translateIn(probe, G.bind)
		local plan = (#missing == 0) and upgradePlan(probe) or nil
		if plan then return replayUpgrade(a, plan, 1) end
		-- stops: the stop tool replaces one existing segment between the same nodes and adds edge objects
		local stp = probe[1] and probe[1].proposal
		if stp and (#(stp.edgeObjectsToAdd or {}) > 0 or #(stp.edgeObjectsToRemove or {}) > 0) then
			if #missing > 0 then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " (stop) SKIPPED, unresolved: " .. table.concat(missing, ","))
				return
			end
			local okp, plan = pcall(function() return stopPlan(probe) end)
			if okp and plan then return replayStop(a, plan) end
			-- a street with stops on it taken away with the bulldozer: the engine's own removal proposal removes the stops with it
			local removal0 = (#(stp.edgeObjectsToAdd or {}) == 0) and removalPlan(probe) or nil
			if removal0 then
				return engineReplay(a, "removal (stops included) of " .. table.concat(removal0, ","), function()
					return api.engine.util.proposal.makeSegmentsRemoveProposal(removal0)
				end)
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": stop not replicable (" .. tostring(plan) .. ")")
			return
		end
		-- a construction with its street connection: not replayable as one rebuilt proposal (see replayTwoStep)
		if hasConstructionSegments(a.args[1]) then
			if replayNativeConstruction(a) then return end
			if replayTwoStep(a) then return end
		end
		local removal = (#missing == 0) and removalPlan(probe) or nil
		if removal then
			return engineReplay(a, "removal of " .. table.concat(removal, ","), function()
				return api.engine.util.proposal.makeSegmentsRemoveProposal(removal)
			end)
		end
	end
	local form = REPLAY_FORMS[formIndex]
	if not form then
		if replayTwoStep(a) then return end
		log("NATIVE REPLAY " .. tostring(a.uid) .. ": every form refused (desync)")
		replayFailed(a, "every form refused")
		return
	end
	local margs = C.deser(C.ser(a.args))
	local missing = R.translateIn(margs, G.bind)
	if #missing > 0 then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " SKIPPED, unresolved: " .. table.concat(missing, ","))
		replayFailed(a, "unresolved references")
		return
	end
	if form.ie ~= nil then margs[3] = form.ie end
	if form.pi ~= nil then margs[4] = form.pi end
	local okr, args, n = pcall(C.rebuildArgs, a.fn, margs, { seed = 7919, variant = form.v, ctx = form.ctx, raw = form.raw })
	local label = form.v .. (form.raw and "/raw" or "") .. "/" .. form.ctx .. (form.ie and "/ie" or "") .. (form.pi == false and "/pi0" or "")
	if not okr then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": rebuild " .. shortErr(args))
		return replayNative(a, formIndex + 1)
	end
	local okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
	if not okc or not cmd then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": factory " .. shortErr(cmd))
		return replayNative(a, formIndex + 1)
	end
	toSim("replaying", {})
	local expected = nil
	pcall(function()
		local st = a.args[1].proposal
		expected = #(st.addedSegments or {}) - #(st.removedSegments or {})
	end)
	local edgesBefore = #R.allEdges()
	replaySend(cmd, function(res, success)
		if success then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " BUILT with form " .. label)
			pcall(function()
				local st = res.proposal.proposal
				log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes
					.. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments)
				if expected and #st.addedSegments - #st.removedSegments ~= expected then
					local d = {}
					for i = 1, #st.addedNodes do
						local q = st.addedNodes[i].comp.position
						d[#d + 1] = "node " .. st.addedNodes[i].entity .. string.format(" (%.1f %.1f %.1f)", q.x, q.y, q.z)
					end
					for i = 1, #st.addedSegments do
						local s = st.addedSegments[i]
						d[#d + 1] = "seg " .. s.entity .. " " .. s.comp.node0 .. "-" .. s.comp.node1 .. " " .. tostring(s.comp.roadTemplate):match("[^/]+$")
					end
					for i = 1, #st.removedSegments do d[#d + 1] = "rm " .. st.removedSegments[i].entity end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " engine detail: " .. table.concat(d, "; "))
					local o = {}
					local ost = a.args[1].proposal
					for _, n in ipairs(ost.addedNodes or {}) do
						local q = n.comp and n.comp.position or {}
						o[#o + 1] = "node " .. tostring(n.entity) .. string.format(" (%.1f %.1f %.1f)", q.x or 0, q.y or 0, q.z or 0)
					end
					for _, s in ipairs(ost.addedSegments or {}) do
						o[#o + 1] = "seg " .. tostring(s.entity) .. " " .. C.ser(s.comp.node0) .. "-" .. C.ser(s.comp.node1)
					end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " originator detail: " .. table.concat(o, "; "))
				end
			end)
			G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function()
				local got = #R.allEdges() - edgesBefore
				if expected and got ~= expected then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " SEGMENT COUNT DIFFERS: originator " .. expected .. ", here " .. got)
				end
			end }
		else
			local why = ""
			pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": refused " .. why)
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayNative(a, formIndex + 1) end }
		end
	end)
end

-- ================================================================== native deferral (with mpfever_native.dll)
-- The DLL holds a build issued by a UI tool and reports it in native_events.log. This game announces it to the others
-- (nat_pending: "a build of mine happens at T"), every game holds at T, this game releases the held command at T (its
-- simulation applies it then, the capture ships it), the others apply it while held at T: same step everywhere.
G.natOff = 0
G.natRelease = {}       -- this game's held builds: { id, at }
G.natWait = {}          -- builds announced by others: { origin, at, since }
G.natReleased = 0
G.natEnabled = false

local function nativeCtl(line)
	C.appendFile(C.DIR .. BS .. "native_ctl.txt", line .. NL)
end

-- Players announcing themselves at the same game time (every game announces itself again after a reload) must be taken in the same
-- order everywhere (a new company gets the next number): an announcement is kept this many frames, so that those of the others arrive
-- too, then they are taken in a fixed order (see before)
local JOIN_GATHER = 120
-- The engine has really stopped: its speed is 0 AND its clock has not moved for a while (the speed component reads 0 while the
-- simulation thread still finishes the steps it had started)
G.simStill = function()
	return gameSpeed() == 0 and G.frames - (G.clockMovedAt or 0) >= 12
end

local function nativeHoldAt()
	local m = nil
	local now = gameTime()
	-- A game running at speed passes a stop point by what it simulates before the speed change reaches the engine (up to a few
	-- steps at x4): a build would then land a step late here. So the game first stops a little BEFORE the build's time, then
	-- the engine performs exactly the steps left (exact once stopped, see pacing).
	local early = 2 * math.max(1, math.min(4, G.session.speed or 1))
	local stopped = G.simStill()
	local function approach(at)
		local e = at - early * STEP
		if now < e or not stopped then return e end   -- (inside the margin while still running: stop where it is)
		return at
	end
	for _, r in ipairs(G.natRelease) do local t = approach(r.at) if m == nil or t < m then m = t end end
	for _, w in ipairs(G.natWait) do local t = approach(w.at) if m == nil or t < m then m = t end end
	-- other players' builds already received: this game must stop exactly at their time
	if (G.replayOut or 0) > 0 and G.frames - (G.replaySince or 0) > 600 then
		log("replay without engine answer for 600 frames: hold released")
		G.replayOut = 0
	end
	if (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or G.terrainBusy or G.coBusy then return now end
	-- (a player joining waits until the others announced at the same time have arrived too, see runNativeReplays)
	for _, a in ipairs(G.nativeQueue or {}) do
		if a.fn == "mpfCoJoin" and a.at <= now and G.frames - (a.recvFrame or 0) < JOIN_GATHER then return now end
	end
	for _, a in ipairs(G.nativeQueue or {}) do
		if a.at > now then local t = approach(a.at) if m == nil or t < m then m = t end end
	end
	return m
end

H.nat_pending = function(from, p)
	if p.origin == G.me then return end
	logMargin("nat_pending", p.at, p.origin)
	G.natWait[#G.natWait + 1] = { origin = p.origin, id = p.id, at = p.at, since = G.frames }
	log("native build of " .. tostring(p.origin) .. " announced for t=" .. tostring(p.at) .. ": holding there")
end

-- While the build waits for its game time (about two seconds), a translucent circle on the ground where the player
-- clicked shows that it is on its way (no interface element: the world's own zone drawing). Removed once shipped.
G.pendingMarks = {}
local function markPending(id, at)
	local ok, err = pcall(function()
		local pos = at
		if not pos then
			local m = api.gui.mouse
			if not (m and m.hasTerrainPosition and m.hasTerrainPosition()) then return end
			pos = m.getTerrainPosition()
		end
		api.gui.mission.setZoneCircle("mpfever_pending_" .. id, api.type.Vec2f.new(pos.x, pos.y), 14, true,
			api.type.Vec4f.new(1.0, 0.75, 0.1, 0.45), false, false)
		G.pendingMarks[id] = G.frames
	end)
	if not ok then log("pending mark failed: " .. tostring(err)) end
end

local function refreshPendingMarks()
	if next(G.pendingMarks) == nil then return end
	local live = {}
	for _, r in ipairs(G.natRelease) do live[r.id] = true end
	for _, e in ipairs(G.natShipIds or {}) do live[e.id] = true end
	for id, since in pairs(G.pendingMarks) do
		if not live[id] or G.frames - since > 900 then
			pcall(api.gui.mission.removeZone, "mpfever_pending_" .. id)
			G.pendingMarks[id] = nil
		end
	end
end

-- terrain edits: the cells the DLL copied when the engine applied an edit here (to ship), and the verdicts on the ones
-- received (injected into the empty grid the replay sends)
G.terrainBlobs = {}
G.terrainIn = {}
G.lastBlobId = 0
-- the ground under a patch of cells (a diagnostic: the same sum in two games means the same ground)
G.terrainSum = function(x0, y0, w, h)
	local sum, n = 0, 0
	for i = 0, math.min(w, 24) - 1 do
		for j = 0, math.min(h, 24) - 1 do
			local z = nil
			pcall(function() z = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new((x0 + i + 0.5) * 4, (y0 + j + 0.5) * 4)) end)
			if type(z) == "number" then sum = sum + z; n = n + 1 end
		end
	end
	return string.format("%.3f over %d points", sum, n)
end
local function pollNativeEvents()
	refreshPendingMarks()
	for _, line in ipairs(readLines("native_events.log", "natOff")) do
		local tid, tx0, ty0, tw, th, tlen, tfnv, textra = line:match("^terrain (%d+) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d+) (%x+) (%d+)")
		if tid then
			G.terrainBlobs[#G.terrainBlobs + 1] = { id = tonumber(tid), x0 = tonumber(tx0), y0 = tonumber(ty0), w = tonumber(tw),
				h = tonumber(th), len = tonumber(tlen), fnv = tfnv, extra = tonumber(textra), frame = G.frames }
			while #G.terrainBlobs > 12 do table.remove(G.terrainBlobs, 1) end
		end
		local rid, rst = line:match("^terrain_in (%d+) (%a+)")
		if rid then G.terrainIn[tonumber(rid)] = rst end
		local id = tonumber(line:match("^deferred (%d+)"))
		if id then
			markPending(id)
			local now = gameTime()
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt
			local at = paused and pausedStamp(now) or (stampFor(now) + STEP)
			G.natRelease[#G.natRelease + 1] = { id = id, at = at }
			send("nat_pending", { origin = G.me, at = at, id = id })
			log("native build " .. id .. " held by the DLL, released at t=" .. at .. " (now " .. now .. ") [frame " .. G.frames .. "]")
		end
	end
end

-- autotest: a scripted build follows the tools' path (announced, every game holds at its time, then it is sent)
G.autoBuildSeq = 0
local function deferredSend(cmd, cb)
	local now = gameTime()
	G.autoBuildSeq = G.autoBuildSeq + 1
	local id = 100000 + G.autoBuildSeq
	local at = stampFor(now) + STEP
	G.natRelease[#G.natRelease + 1] = { id = id, at = at, fn = function() O.sendCommand(cmd, cb) end }
	markPending(id, { x = 0, y = 0 })
	log("pending mark drawn for autotest build " .. id)
	send("nat_pending", { origin = G.me, at = at, id = id })
end

-- A released build the engine refused is never shipped: the others, who hold for it, are told at once (they would
-- wait half a minute), and its id must not be taken by the next build that is shipped.
local function cancelNativeBuild(entry, why)
	send("nat_cancel", { origin = G.me, id = entry.id })
	log("native build " .. tostring(entry.id) .. " produced nothing (" .. why .. "): the others stop holding for it")
end

local function expireShipIds()
	local keep = {}
	for _, e in ipairs(G.natShipIds or {}) do
		if G.frames - e.frame > 150 then cancelNativeBuild(e, "refused or not built") else keep[#keep + 1] = e end
	end
	G.natShipIds = keep
end

H.nat_cancel = function(from, p)
	if p.origin == G.me then return end
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if w.origin == p.origin and w.id == p.id and not w.arrived then
			log("native build of " .. tostring(w.origin) .. " for t=" .. tostring(w.at) .. " cancelled by its originator: no longer holding")
		else
			keep[#keep + 1] = w
		end
	end
	G.natWait = keep
end

-- the held build goes to the engine; it is built at game time `at` (the time the game is at now, or the one the steps
-- queued just before it end at)
local function releaseOne(r, at, how)
	G.natReleased = G.natReleased + 1
	G.natShipIds = G.natShipIds or {}
	G.natShipIds[#G.natShipIds + 1] = { id = r.id, at = at, frame = G.frames, combined = how ~= nil }
	if r.fn then
		-- a scripted build (autotest) deferred like the tools' ones: sent now, at its announced time
		G.natReleased = G.natReleased - 1
		pcall(r.fn)
	else
		nativeCtl("release " .. G.natReleased)
		-- any command reaching CommandList::Add lets the DLL release the held build just before it
		O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
	end
	log("native build " .. r.id .. " released at t=" .. at .. (how or "") .. (at > r.at and (" (" .. ((at - r.at) / STEP) .. " step(s) late)") or "") .. " [frame " .. G.frames .. "]")
end

local function runNativeRelease()
	expireShipIds()
	if #G.natRelease == 0 then return end
	local now = gameTime()
	local keep = {}
	for _, r in ipairs(G.natRelease) do
		if now >= r.at and gameSpeed() == 0 then
			releaseOne(r, now)
		else
			keep[#keep + 1] = r
		end
	end
	G.natRelease = keep
end

local function expireNativeWaits()
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if not w.arrived and G.frames - w.since > 1800 then
			log("NATIVE build of " .. tostring(w.origin) .. " for t=" .. tostring(w.at) .. " never arrived: no longer holding (desync risk)")
		else
			keep[#keep + 1] = w
		end
	end
	G.natWait = keep
end

local function matchesWait(w, a)
	if w.origin ~= a.origin then return false end
	if a.natId ~= nil and w.id ~= nil then return w.id == a.natId end
	return w.at == a.at
end

-- the data of an announced build is here: hold at its real time (the capture may come a step after the announce)
nativeReceived = function(a)
	for _, w in ipairs(G.natWait) do
		if matchesWait(w, a) then w.at = a.at; w.arrived = true end
	end
end

local function nativeArrived(a)
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if not matchesWait(w, a) then keep[#keep + 1] = w end
	end
	G.natWait = keep
end

-- Another game's terrain edit, in two phases so that a failure never reaches the engine: (1) the cells go to the DLL (a file and
-- a control line, read when the next command enters the command list: a nop event is sent for that) and the DLL says "ready";
-- (2) only then a command with an empty grid of the same size goes to the engine, and the DLL copies the cells into it as it
-- enters the command list ("injected"). An empty grid applied by itself would flatten the ground it covers.
local function terrainFail(a, why)
	G.terrainBusy = nil
	log("TERRAIN REPLAY " .. tostring(a.uid) .. ": " .. why)
	replayFailed(a, why)
end

local function replayTerrain(a)
	local t = a.args or {}
	if type(t.blob) ~= "string" or type(t.w) ~= "number" or type(t.h) ~= "number" then
		return terrainFail(a, "no cells received")
	end
	G.terrainInSeq = (G.terrainInSeq or 0) + 1
	local okT, tm = pcall(os.time)
	local id = ((okT and tm or 0) % 100000) * 1000 + G.terrainInSeq % 1000
	local f = C.IO.open(C.DIR .. BS .. "terrain_in_" .. id .. ".txt", "wb")
	if not f then return terrainFail(a, "cannot write the cells") end
	f:write(t.blob)
	f:close()
	G.terrainBusy = { id = id, frame = G.frames, a = a, phase = "load" }
	nativeCtl("tin " .. id)
	O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))     -- the DLL reads the control line when this command enters the list
end

local function sendTerrainCarrier(busy)
	local a, id = busy.a, busy.id
	local t = a.args
	local okc, cmd = pcall(function()
		local prop = api.type.Proposal.new()
		prop.terrain.baseHeightMod = api.type.GridVec2f.new(t.x0, t.y0, t.w, t.h)
		local ctx = api.type.Context.new()
		ctx.player = api.engine.util.getPlayer()
		return api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true)
	end)
	if not okc or not cmd then return terrainFail(a, "command not made (" .. shortErr(cmd) .. ")") end
	busy.phase = "inject"
	busy.frame = G.frames
	toSim("replaying", {})
	toSim("terrain_note", { v = tonumber(tostring(t.fnv):sub(-8), 16) or 0 })
	local hx, hy = (t.x0 + math.floor(t.w / 2)) * 4 + 2, (t.y0 + math.floor(t.h / 2)) * 4 + 2
	local h0 = nil
	pcall(function() h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(hx, hy)) end)
	replaySend(cmd, function(res, success)
		local h1 = nil
		pcall(function() h1 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(hx, hy)) end)
		log("TERRAIN REPLAY " .. tostring(a.uid) .. (success and " applied" or " REFUSED") .. " (" .. t.w .. "x" .. t.h .. " cells at " .. t.x0 .. ","
			.. t.y0 .. "; DLL: " .. tostring(G.terrainIn[id]) .. "; height at the centre " .. tostring(h0) .. " -> " .. tostring(h1) .. ")")
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
			log("TERRAIN REPLAY " .. tostring(a.uid) .. ": ground now sum " .. tostring(G.terrainSum(t.x0, t.y0, t.w, t.h)))
		end }
		if not success then replayFailed(a, "terrain refused") end
	end)
end

-- every frame: moves the edit being replayed from one phase to the next
local function pumpTerrain()
	local busy = G.terrainBusy
	if not busy then return end
	local st = G.terrainIn[busy.id]
	local age = G.frames - busy.frame
	if busy.phase == "load" then
		if st == "ready" then sendTerrainCarrier(busy)
		elseif st == "failed" then terrainFail(busy.a, "the native module could not read the cells")
		elseif age > 180 then terrainFail(busy.a, "the native module did not answer (" .. tostring(st) .. ")") end
	else
		if st == "injected" then G.terrainBusy = nil
		elseif age > 300 then terrainFail(busy.a, "the cells were not injected (" .. tostring(st) .. ")") end
	end
end

-- A player joins the company game (act mpfCoJoin, applied by every game at the same game time while all are held there): the
-- registry in the simulation state takes the player in, then, for a new company, the engine creates its player entity (the
-- answer of that command gives the entity of THIS game), which is stored with the company, and the company gets its start money.
local function coCreate(b, c)
	local r, g, bl = CO.rgb(c.color)
	local okc, cmd = pcall(function() return api.cmd.makeGameAddPlayerCmd(tostring(c.name), api.type.Vec3f.new(r, g, bl)) end)
	if not okc or not cmd then log("companies: add player command " .. shortErr(cmd)); G.coBusy = nil; return end
	replaySend(cmd, function(res, success)
		local ent = nil
		pcall(function() ent = res.resultEntity end)
		if not success or type(ent) ~= "number" then
			log("companies: the engine refused the new company " .. tostring(c.id)); G.coBusy = nil; return
		end
		toSim("co_set", { id = c.id, ent = ent })
		local start = (G.co and G.co.start) or 0
		if start > 0 then
			local entry = api.type.JournalEntry.new()
			entry.amount = math.floor(start + 0.5)
			entry.time = -1
			entry.category.type = api.type.JournalEntry.Type.OTHER
			replaySend(api.cmd.makeJournalBookAssetCmd(ent, entry), function() end)
		end
		log("companies: company " .. c.id .. " created (player entity " .. ent .. "), start money " .. tostring(start))
	end)
end

local function pumpCompanies()
	local b = G.coBusy
	if not b then return end
	local age = G.frames - b.frame
	local c = G.co and CO.match(G.co, b.a.args.key, b.a.args.sid, b.a.args.host == true)
	if b.phase == "apply" then
		if not b.sent then b.sent = true; toSim("co_apply", b.a) end
		if c then
			if c.ent then G.coBusy = nil
			else b.phase = "create"; b.frame = G.frames; coCreate(b, c) end
		elseif age > 240 then
			log("companies: the registry did not take the player in"); G.coBusy = nil
		end
	elseif b.phase == "create" then
		if c and c.ent then G.coBusy = nil
		elseif age > 600 then log("companies: the new company was not created"); G.coBusy = nil end
	end
end

-- Trees, plants and rocks another player placed with the brush (see captureNativeBuild): the same models at the same places, in the
-- mod's own construction; what the brush removed is removed too.
-- (the name a mod's construction is known by: tried once)
local ASSET_CON = "mpfever_1::/mpfever_asset.con"
local function assetConName()
	if G.assetConName == nil then
		G.assetConName = false
		for _, n in ipairs({ "mpfever_1::/mpfever_asset.con", "mpfever_asset.con", "::/mpfever_asset.con", "/mpfever_asset.con", "mpfever_1::mpfever_asset.con" }) do
			local ok, id = pcall(api.res.constructionRep.find, n)
			log("assets: construction name '" .. n .. "' -> " .. tostring(ok and id))
			if ok and type(id) == "number" and id >= 0 and not G.assetConName then G.assetConName = n end
		end
	end
	return G.assetConName or ASSET_CON
end
local function replayAssets(a)
	local args = C.deser(C.ser(a.args or {}))
	local miss = R.translateIn(args, G.bind)
	local sp = api.type.SimpleProposal.new()
	local cons = {}
	for i, as in ipairs(args.assets or {}) do
		local ce = api.type.SimpleProposal.ConstructionEntity.new()
		ce.fileName = assetConName()
		ce.params = { mpfModels = as.models or {}, seed = 1 }
		ce.transf = C.plain(as.transf)
		ce.playerEntity = (type(as.player) == "number" and as.player >= 0) and as.player or -1
		pcall(function() ce.name = "" end)
		cons[#cons + 1] = ce
	end
	sp.constructionsToAdd = cons
	local rm = {}
	for _, e in ipairs(args.toRemove or {}) do if type(e) == "number" and e >= 0 then rm[#rm + 1] = e end end
	if #rm > 0 then sp.constructionsToRemove = rm end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = false
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = false
	ctx.gatherFields = false
	ctx.player = api.engine.util.getPlayer()
	local okc, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, true, false) end)
	if not okc or not cmd then
		log("ASSET REPLAY " .. tostring(a.uid) .. ": command " .. shortErr(cmd))
		replayFailed(a, "assets not rebuilt")
		return
	end
	toSim("replaying", {})
	replaySend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		G.assetReplays = (G.assetReplays or 0) + 1
		if G.assetReplays <= 10 or not success then
			log("ASSET REPLAY " .. tostring(a.uid) .. ": " .. #cons .. " construction(s), " .. #rm .. " removed" .. (#miss > 0 and (" (not found here: " .. #miss .. ")") or "") .. ": " .. (success and "BUILT" or ("refused " .. why)))
		end
	end)
end

local function runNativeReplays()
	pumpTerrain()
	pumpCompanies()
	if #G.nativeQueue == 0 then return end
	local now = gameTime()
	table.sort(G.nativeQueue, before)
	local keep = {}
	for _, a in ipairs(G.nativeQueue) do
		if a.at <= now and ((a.fn == "terrainEdit" and G.terrainBusy) or (a.fn == "mpfCoJoin" and (G.coBusy or G.frames - (a.recvFrame or 0) < JOIN_GATHER))) then
			keep[#keep + 1] = a      -- the previous one is still being handed to the engine
		elseif a.at <= now then
			if a.at < now then
				log("LATE native build " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)")
				G.aheadLocked = true
			end
			nativeArrived(a)
			local okr, errr
			if a.fn == "terrainEdit" then okr, errr = pcall(withActor, PL(a), replayTerrain, a)
			elseif a.fn == "assetBuild" then okr, errr = pcall(withActor, PL(a), replayAssets, a)
			elseif a.fn == "mpfCoJoin" then G.coBusy = { a = a, phase = "apply", frame = G.frames }; okr = true
			else okr, errr = pcall(withActor, PL(a), replayNative, a, 1) end
			if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " failed: " .. tostring(errr)) end
		else
			keep[#keep + 1] = a
		end
	end
	G.nativeQueue = keep
end

H.hash = function(from, p)
	if p.paused then
		G.pendingPaused[#G.pendingPaused + 1] = { kind = "hash", n = p.n, at = p.at, origin = "", oseq = -1 }
	else
		toSim("queue", { kind = "hash", n = p.n, at = p.at, origin = "", oseq = -1 })
	end
end

-- host authority: the host's values at checkpoint n (only the other games correct themselves)
H.auth = function(from, p)
	if C.ROLE == "host" or type(p.n) ~= "number" then return end
	local own = G.authOwn and G.authOwn[p.n]
	if own then
		-- checkpoint taken while paused, here in the GUI half
		local ok, err = pcall(correctMoney, own, p, p.n, O.sendCommand, G.co)
		if not ok then log("money correction failed: " .. tostring(err)) end
	else
		toSim("auth", p)
	end
end

-- ---------------------------------------------------------------- resynchronisation by the host's savegame
-- resync_save (host): save the paused game; resync_load (others): load the host's savegame received by the launcher.
-- Handled here when the application functions are reachable from this state, otherwise by the UI hook (which waits
-- for a claim in resync_claims.txt before acting, so that only one of them does it).
local function claimResync(kind, id)
	if type(app) ~= "table" or not app.saveGame then return false end
	local f = C.IO.open(C.DIR .. BS .. "resync_claims.txt", "rb")
	local claims = f and (f:read("*a") or "") or ""
	if f then f:close() end
	local key = kind .. " " .. tostring(id) .. NL
	if claims:find(key, 1, true) then return false end
	C.appendFile(C.DIR .. BS .. "resync_claims.txt", key)
	return true
end

H.resync_save = function(from, p)
	if not claimResync("resync_save", p.id) then return end
	log("resynchronisation: saving the game as '" .. tostring(p.name) .. "' at t=" .. tostring(gameTime()))
	local ok, err = pcall(app.saveGame, p.name, function()
		log("resynchronisation: game saved")
		send("save_done", { id = p.id, name = p.name, ok = true, t = gameTime() })
	end, false, true)
	if not ok then
		log("resynchronisation: save failed: " .. tostring(err))
		send("save_done", { id = p.id, name = p.name, ok = false, err = tostring(err) })
	end
end

H.resync_load = function(from, p)
	if not claimResync("resync_load", p.id) then return end
	local ns = app.SaveGameNamespace.getSavegame()
	local id = nil
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == p.name then
			id = api.type.SavegameId.new()
			id.path = s.path
			id.saveGameName = s.saveName
			id.saveGameNamespace = ns
		end
	end
	if not id then log("resynchronisation: savegame '" .. tostring(p.name) .. "' not found"); return end
	C.appendFile(C.DIR .. BS .. "resync_pending.txt", "1")
	log("resynchronisation: loading the host's game '" .. tostring(p.name) .. "'")
	app.loadGame(id, false)
end

H.det_run = function(from, p)
	local round, steps = p.round, p.steps or 0
	setSpeed(0)
	local target = gameTime() + steps * STEP
	if steps > 0 and O.steps then O.sendCommand(O.steps(steps)) end
	local stable, deadline = 0, G.frames + 60 * 300
	local function poll()
		local t = gameTime()
		if t >= target then stable = stable + 1 else stable = 0 end
		if stable >= 5 or G.frames > deadline then
			local parts = simHash(nil, G.co)
			parts.reached = (t >= target)
			send("det_hash", { round = round, steps = steps, parts = parts })
		else
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = poll }
		end
	end
	G.waits[#G.waits + 1] = { at = G.frames + 10, fn = poll }
end

-- commands held by the UI hook: stamp them (two steps ahead, or at the pause point) and ship them
local function stampHeld()
	for _, line in ipairs(readLines("ui.log", "uiOff")) do
		local kind, _, payload = parseLine(line)
		local p = payload and C.deser(payload)
		if p and kind == "act_req" then
			local now = gameTime()
			G.oseq = G.oseq + 1
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
			local a = { tok = p.tok, id = p.id, fn = p.fn, args = p.args, origin = G.me, oseq = G.oseq, co = G.myCo,
				uid = G.me .. ":" .. G.oseq, at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil }
			send("act", a)
			queueLocal(a)
		elseif p and (kind == "speed_req" or kind == "act_fail" or kind == "save_done") then
			send(kind, p)
		end
	end
end

-- native builds captured by the simulation half: ship them with their exact time
local function enrichEdgeObjects(compact)
	local st = compact and compact.proposal
	if type(st) ~= "table" or #(st.edgeObjectsToAdd or {}) == 0 then return end
	for _, seg in ipairs(st.addedSegments or {}) do
		local c = seg.comp or {}
		local objs = c.objects or {}
		if #objs > 0 and c.position0 and c.position1 then
			local edge = R.resolve({ k = "edge", id = -1, p0 = { x = c.position0.x, y = c.position0.y, z = c.position0.z },
				p1 = { x = c.position1.x, y = c.position1.y, z = c.position1.z } }, {})
			local be = edge and api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
			if be then
				for _, pair in ipairs(objs) do
					local placeholder, side = pair[1], pair[2]
					local idx = -(placeholder + 400000000) + 1
					local entry = st.edgeObjectsToAdd[idx]
					if entry then
						for i = 1, #be.objects do
							if be.objects[i][2] == side then
								local eo = api.engine.getComponent(be.objects[i][1], api.type.ComponentType.EDGE_OBJECT)
								if eo then
									entry.param = eo.param
									entry.model = eo.edgeObjectConstruction
									entry.params = C.marshal(eo.params)
								end
							end
						end
					end
				end
			else
				log("edge object enrichment: new edge not found")
			end
		end
	end
end

local function needsEnrich(compact)
	for _, e in ipairs(((compact or {}).proposal or {}).edgeObjectsToAdd or {}) do
		if type(e) == "table" and e.model == nil then return true end
	end
	return false
end

-- A terrain edit made here: the cells the DLL copied go to the others with the time the engine applied it. Without them
-- (no native module, cells not read) the games differ for sure: the host's game is reloaded everywhere.
local function shipTerrain(o)
	local d = o.args or {}
	local k = nil
	-- the edits are applied in the order the DLL copies them: the oldest copy of the right size that is not too old (an edit
	-- the engine refused leaves a copy no edit comes for), and never one older than the last used
	local first = G.outFirstSeen[o.n] or G.frames
	for i = 1, #G.terrainBlobs do
		local b = G.terrainBlobs[i]
		if b.id > (G.lastBlobId or 0) and first - b.frame < 240 and b.x0 == d.x0 and b.y0 == d.y0 and b.w == d.w and b.h == d.h then k = i; break end
	end
	local function fail(why)
		log("terrain edit made here at t=" .. tostring(o.at) .. " cannot be copied to the other games: " .. why .. " (the host's game will be reloaded)")
		send("replay_failed", { uid = "terrain", why = "terrain modification" })
		return "failed"
	end
	if not k then
		if G.frames - (G.outFirstSeen[o.n] or G.frames) < 150 then return "wait" end
		return fail("the native module did not copy the cells")
	end
	local b = table.remove(G.terrainBlobs, k)
	G.lastBlobId = b.id
	local f = C.IO.open(C.DIR .. BS .. "terrain_out_" .. b.id .. ".txt", "rb")
	local txt = f and f:read("*a")
	if f then f:close() end
	if type(txt) ~= "string" or #txt ~= b.len then return fail("the file of the cells is missing or damaged") end
	if (b.extra or 0) > 0 then
		log("terrain edit at t=" .. tostring(o.at) .. " carries " .. b.extra .. " more grid(s) (ground paint?) that are not copied")
	end
	G.oseq = G.oseq + 1
	local a = { fn = "terrainEdit", args = { x0 = d.x0, y0 = d.y0, w = d.w, h = d.h, fnv = b.fnv, blob = txt }, at = o.at, origin = G.me,
		oseq = G.oseq, uid = G.me .. ":" .. G.oseq, native = true, paused = o.paused, co = G.myCo }
	send("act", a)
	toSim("terrain_note", { v = tonumber(b.fnv:sub(-8), 16) or 0 })
	G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
		log("terrain edit " .. a.uid .. ": ground here now sum " .. tostring(G.terrainSum(d.x0, d.y0, d.w, d.h)))
	end }
	log("terrain edit shipped " .. a.uid .. " (" .. d.w .. "x" .. d.h .. " cells, " .. #txt .. " bytes as text, made here at t=" .. tostring(o.at) .. ") [frame " .. G.frames .. "]")
	return "sent"
end

local function shipNativeBuilds(st)
	G.outFirstSeen = G.outFirstSeen or {}
	for _, o in ipairs(st.out or {}) do
		if o.n > G.outSent and o.terrain then
			G.outFirstSeen[o.n] = G.outFirstSeen[o.n] or G.frames
			local okT, r = pcall(shipTerrain, o)
			if not okT then log("terrain shipping failed: " .. tostring(r)); r = "failed" end
			if r == "wait" then return end
			G.outSent = o.n
		elseif o.n > G.outSent then
			G.outFirstSeen[o.n] = G.outFirstSeen[o.n] or G.frames
			if o.ready == false and G.frames - G.outFirstSeen[o.n] < 30 then return end
			G.outSent = o.n
			G.oseq = G.oseq + 1
			if needsEnrich(o.args and o.args[1]) then
				local oke, erre = pcall(enrichEdgeObjects, o.args and o.args[1])
				if not oke then log("edge object enrichment failed: " .. tostring(erre)) end
			end
			local a = { fn = o.fn, args = o.args, at = o.at, origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
				native = true, paused = o.paused, co = G.myCo }
			if G.natShipIds and #G.natShipIds > 0 then
				-- the released build that was built at this time; the ones released before it and not shipped were refused
				local k = nil
				for i, e in ipairs(G.natShipIds) do if e.at == o.at then k = i; break end end
				k = k or 1
				if G.natShipIds[k].at ~= o.at then
					log("WARNING: a native build landed at t=" .. tostring(o.at) .. " instead of t=" .. tostring(G.natShipIds[k].at) .. " (desync risk)")
				end
				for i = 1, k - 1 do cancelNativeBuild(G.natShipIds[i], "refused before a later build") end
				a.natId = G.natShipIds[k].id
				local rest = {}
				for i = k + 1, #G.natShipIds do rest[#rest + 1] = G.natShipIds[i] end
				G.natShipIds = rest
			end
			send("act", a)
			log("native build shipped " .. a.uid .. " (built here at t=" .. o.at .. ", the other games build it at the same time) [frame " .. G.frames .. "]")
		end
	end
end

local function runPausedActions()
	local natAt = nativeHoldAt()
	if #G.pendingPaused == 0 and natAt == nil then
		if G.holdAt then
			G.holdAt = nil
			if not G.session.pauseAt then toSim("resume", {}) end
		end
		return
	end
	local now = gameTime()
	local minAt = natAt
	for _, a in ipairs(G.pendingPaused) do
		if a.at > now and (minAt == nil or a.at < minAt) then minAt = a.at end
	end
	if minAt and G.holdAt ~= minAt then
		G.holdAt = minAt
		toSim("pause_at", { at = minAt })
	end
	if gameSpeed() ~= 0 then return end
	local keep = {}
	table.sort(G.pendingPaused, before)
	for _, a in ipairs(G.pendingPaused) do
		if a.at <= now then
			if a.at < now then log("paused action " .. tostring(a.uid) .. " for t=" .. tostring(a.at) .. " applied at " .. now .. " (desync risk)") end
			if a.kind == "hash" then
				local okA, auth = pcall(authValues, G.co)
				G.authOwn = G.authOwn or {}
				G.authOwn[a.n] = okA and auth or nil
				send("sync_hash", { n = a.n, parts = simHash(G.simTerrainSig, G.co), cost = 0, auth = okA and auth or nil })
			elseif a.fn == "mpfCoJoin" or coIsLoanEvent({ co = G.co }, a) then
				toSim("co_apply", a)
			else
				toSim("replaying", {})
				-- paused: the engine answers in a callback, a frame later; the result is reported then
				withActor(PL(a), executeAction, a, O.sendCommand, true, G.bind, function(r)
					r.at = now
					r.answered, r.returned = nil, nil
					log("paused action " .. tostring(r.uid) .. " " .. tostring(r.fn) .. " at t=" .. tostring(now) .. " -> " .. (r.success and "OK" or "REFUSED"))
					if r.created then G.bind[r.created.key] = r.created.e; G.rev[r.created.e] = r.created.key; toSim("bind", r.created) end
					G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true
					C.appendFile(C.DIR .. BS .. "results.log", C.line("result", r))
					if r.created then C.appendFile(C.DIR .. BS .. "bindings.log", r.created.key .. " " .. tostring(r.created.e) .. NL) end
					if not r.success then send("act_refused", { uid = r.uid, fn = r.fn, err = r.err }) end
				end)
			end
		else
			keep[#keep + 1] = a
		end
	end
	G.pendingPaused = keep
end

-- ================================================================== autotest scenario (MPFever.exe --autotest)
-- Builds like a player would (playerInitiated commands, the path the native tools take): a road from a dead end, a
-- second road from the new node, a bus stop on the second road. The other games must replicate everything.

local AUTO = { running = false, results = {}, points = {} }
local STOP_MODEL = "stations/street/small_stops/small_old.con"

local function vec(p) return api.type.Vec3f.new(p.x, p.y, p.z) end
local function pos3(v) return { x = v.x, y = v.y, z = v.z } end

local function groundZ(x, y, fallback)
	local z = nil
	pcall(function() z = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(x, y)) end)
	if type(z) ~= "number" then pcall(function() z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end) end
	return type(z) == "number" and z or fallback
end

-- dead ends of the street network, in a deterministic order (same save = same ids for these)
local function deadEnds()
	local list, edgeOf = {}, {}
	for n, segs in pairs(api.engine.system.streetSystem.getNode2SegmentMap() or {}) do
		local k = 0
		pcall(function() k = #segs end)
		if k == 1 then
			local e = segs[1]
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if c and c.type == 0 and c.roadTemplate and c.roadTemplate ~= "" then
				list[#list + 1] = n
				edgeOf[n] = { e = e, other = (c.node0 == n) and c.node1 or c.node0, c = c }
			end
		end
	end
	table.sort(list)
	return list, edgeOf
end

local function nodePosition(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and pos3(c.position) or nil
end

local function roadProposal(fromNode, fromPos, toPos, tmpl)
	local sp = api.type.SimpleProposal.new()
	local n = api.type.NodeAndEntity.new()
	n.entity = -1
	n.comp.position = vec(toPos)
	sp.streetProposal.nodesToAdd[1] = n
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.comp.node0 = fromNode
	e.comp.node1 = -1
	local t = { x = toPos.x - fromPos.x, y = toPos.y - fromPos.y, z = toPos.z - fromPos.z }
	e.comp.tangent0 = vec(t)
	e.comp.tangent1 = vec(t)
	e.comp.type = 0
	e.comp.typeIndex = -1
	e.type = 0
	e.streetEdge = api.type.BaseEdgeStreet.new()
	e.comp.roadTemplate = tmpl.roadTemplate
	e.comp.roadStyle = tmpl.roadStyle
	e.comp.roadType = tmpl.roadType
	local po = C.newOf("PlayerOwned")
	po.player = api.engine.util.getPlayer()
	e.playerOwned = po
	sp.streetProposal.edgesToAdd[1] = e
	return sp
end

local function stopProposal(edge)
	local c = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
	local sp = api.type.SimpleProposal.new()
	sp.streetProposal.edgesToRemove[1] = edge
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.comp.node0 = c.node0
	e.comp.node1 = c.node1
	e.comp.tangent0 = vec(c.tangent0)
	e.comp.tangent1 = vec(c.tangent1)
	e.comp.type = 0
	e.comp.typeIndex = -1
	e.type = 0
	e.streetEdge = api.type.BaseEdgeStreet.new()
	e.comp.roadTemplate = c.roadTemplate
	e.comp.roadStyle = c.roadStyle
	e.comp.roadType = c.roadType
	local po = C.newOf("PlayerOwned")
	po.player = api.engine.util.getPlayer()
	e.playerOwned = po
	sp.streetProposal.edgesToAdd[1] = e
	local eo = api.type.SimpleStreetProposal.EdgeObject.new()
	eo.edgeEntity = -1
	eo.param = 0.5
	eo.oneWay = false
	eo.left = true
	eo.model = STOP_MODEL
	eo.playerEntity = api.engine.util.getPlayer()
	eo.name = "MPF " .. C.ROLE
	sp.streetProposal.edgeObjectsToAdd[1] = eo
	return sp
end

local function autoStep(name, makeProposal, after)
	local okp, sp = pcall(makeProposal)
	if not okp or not sp then
		AUTO.results[#AUTO.results + 1] = name .. ": proposal error " .. tostring(sp)
		log("AUTOTEST " .. name .. ": proposal error " .. tostring(sp))
		return after(false)
	end
	local okc, err = pcall(function()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, nil, false, true), function(res, success)
			AUTO.results[#AUTO.results + 1] = name .. ": " .. (success and "built" or "refused by the engine")
			log("AUTOTEST " .. name .. ": " .. (success and "built" or "refused by the engine"))
			G.waits[#G.waits + 1] = { at = G.frames + 40, fn = function() after(success) end }
		end)
	end)
	if not okc then
		AUTO.results[#AUTO.results + 1] = name .. ": command error " .. tostring(err)
		log("AUTOTEST " .. name .. ": command error " .. tostring(err))
		after(false)
	end
end

local function autoFinish()
	AUTO.running = false
	G.autoPoints = G.autoPoints or {}
	for _, q in ipairs(AUTO.points) do G.autoPoints[#G.autoPoints + 1] = q end
	send("autotest_done", { role = C.ROLE, results = AUTO.results, points = AUTO.points })
end

local function runScenario(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ends, edgeOf = deadEnds()
	log("AUTOTEST start (" .. C.ROLE .. "): " .. #ends .. " dead ends")
	local candidate = (p.offset or 0)
	local function tryCandidate(attempt)
		if attempt > 12 then
			AUTO.results[#AUTO.results + 1] = "no free place for a road"
			return autoFinish()
		end
		candidate = candidate + 1
		local n = ends[(candidate * 37) % #ends + 1]
		local info = edgeOf[n]
		local pn, po = nodePosition(n), nodePosition(info.other)
		local dx, dy = pn.x - po.x, pn.y - po.y
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 1 then return tryCandidate(attempt + 1) end
		dx, dy = dx / len, dy / len
		local a = { x = pn.x + dx * 60, y = pn.y + dy * 60 }
		a.z = groundZ(a.x, a.y, pn.z)
		local b = { x = a.x + dx * 60, y = a.y + dy * 60 }
		b.z = groundZ(b.x, b.y, a.z)
		local tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType }
		autoStep("road 1 from dead end " .. n, function() return roadProposal(n, pn, a, tmpl) end, function(ok)
			if not ok then return tryCandidate(attempt + 1) end
			AUTO.points[#AUTO.points + 1] = pn
			local na = R.resolve({ k = "node", id = -1, p = a }, {})
			if not na then
				AUTO.results[#AUTO.results + 1] = "new node A not found"
				return autoFinish()
			end
			local pa = nodePosition(na)
			autoStep("road 2 from the new node", function() return roadProposal(na, pa, b, tmpl) end, function(ok2)
				if not ok2 then return autoFinish() end
				local edge = R.resolve({ k = "edge", id = -1, p0 = pa, p1 = b }, {})
				if not edge then
					AUTO.results[#AUTO.results + 1] = "new edge A-B not found"
					return autoFinish()
				end
				autoStep("bus stop on road 2", function() return stopProposal(edge) end, function() autoFinish() end)
			end)
		end)
	end
	tryCandidate(1)
end

-- Street proposal matrix: every sub-object is read, changed and written back (properties return COPIES), the result is
-- read back to check what the proposal really holds, the factory is tried, and the first accepted form is really built
-- to see whether a road appears.
local function edgeCount() return #R.allEdges() end

local function buildMatrixProposal(o, n, pn, a)
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local nodeId = -1
	local edgeId = o.sharedIds and -2 or -1
	local ne = api.type.NodeAndEntity.new()
	ne.entity = nodeId
	local bn = ne.comp
	bn.position = vec(a)
	ne.comp = bn
	local list = {}
	if not o.noEdge then
		local e = api.type.SegmentAndEntity.new()
		e.entity = edgeId
		e.type = 0
		local c = e.comp
		if o.tlanes then
			local lanes = C.templateLanes(o.tmpl.roadTemplate)
			if not lanes then error("no template lanes for " .. tostring(o.tmpl.roadTemplate)) end
			c.laneConfigs = lanes
		elseif o.lanesWire then
			local src = api.engine.getComponent(o.cloneOf, api.type.ComponentType.BASE_EDGE)
			local wire = C.deser(C.ser(C.marshal(src.laneConfigs)))
			c.laneConfigs = C.rebuildLanes(wire)
		elseif o.lanes then
			local src = api.engine.getComponent(o.cloneOf, api.type.ComponentType.BASE_EDGE)
			c.laneConfigs = src.laneConfigs
			if o.decor then c.edgeDecorations = src.edgeDecorations end
			if o.dist then c.distance = src.distance end
		end
		c.node0 = n
		c.node1 = nodeId
		local t = { x = a.x - pn.x, y = a.y - pn.y, z = a.z - pn.z }
		c.tangent0 = vec(t)
		c.tangent1 = vec(t)
		c.type = 0
		c.typeIndex = -1
		if o.positions then
			c.position0 = vec(pn)
			c.position1 = vec(a)
		end
		if o.template then
			c.roadTemplate = o.tmpl.roadTemplate
			c.roadStyle = o.tmpl.roadStyle
		end
		if o.roadType then c.roadType = o.tmpl.roadType end
		e.comp = c
		if o.street then
			local se = e.streetEdge
			se.precedenceNode0 = 2
			se.precedenceNode1 = 2
			e.streetEdge = se
		end
		if o.owner then
			local po = e.playerOwned
			if po == nil then po = C.newOf("PlayerOwned") end
			po.player = api.engine.util.getPlayer()
			e.playerOwned = po
		end
		list[1] = e
	end
	if o.stop and #list > 0 then
		local sc = list[1].comp
		sc.objects = { { -400000000, o.stopLeft and 0 or 1 } }
		list[1].comp = sc
	end
	ssp.nodesToAdd = { ne }
	if #list > 0 then ssp.edgesToAdd = list end
	if o.stop then
		local so = api.type.SimpleStreetProposal.EdgeObject.new()
		so.edgeEntity = o.stopEdge
		so.param = 0.5
		so.oneWay = false
		so.left = false
		so.model = o.stop
		if o.stopNoOwner then so.playerEntity = -1 else so.playerEntity = api.engine.util.getPlayer() end
		if o.stopLeft then so.left = true end
		so.name = "MPF stop"
		ssp.edgeObjectsToAdd = { so }
	end
	sp.streetProposal = ssp
	return sp
end

local function readBack(sp)
	local out = {}
	pcall(function()
		local ssp = sp.streetProposal
		out[#out + 1] = "nodes=" .. #ssp.nodesToAdd .. " edges=" .. #ssp.edgesToAdd
		if #ssp.edgesToAdd > 0 then
			local e = ssp.edgesToAdd[1]
			out[#out + 1] = "edge id=" .. tostring(e.entity) .. " n0=" .. tostring(e.comp.node0) .. " n1=" .. tostring(e.comp.node1)
				.. " tmpl=" .. tostring(e.comp.roadTemplate) .. " type=" .. tostring(e.type)
		end
	end)
	return table.concat(out, " ")
end

local MATRIX = {
	{ name = "tlShared", tlanes = true, template = true, roadType = true, street = true, owner = true, sharedIds = true },
	{ name = "tlPosShared", tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true },
}

local function matrixPlace(k)
	local ends, edgeOf = deadEnds()
	local n = ends[(k * 37) % #ends + 1]
	local info = edgeOf[n]
	local pn, po = nodePosition(n), nodePosition(info.other)
	local dx, dy = pn.x - po.x, pn.y - po.y
	local len = math.sqrt(dx * dx + dy * dy)
	dx, dy = dx / len, dy / len
	local a = { x = pn.x + dx * 40, y = pn.y + dy * 40 }
	a.z = groundZ(a.x, a.y, pn.z)
	return n, info, pn, a
end

local function runMatrix(done)
	local n, info, pn, a = matrixPlace(3)
	local tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType }
	local accepted = {}
	pcall(function()
		local forms = {
			zeroBased = function() local t = {}; for j = 0, 15 do t[j] = (j == 1 or j == 2) end; return t end,
			oneBased = function() local t = {}; for j = 1, 16 do t[j] = (j == 2 or j == 3) end; return t end,
		}
		for name, mk in pairs(forms) do
			local lc = api.type.LaneConfig.new()
			local okA, errA = pcall(function() lc.transportModes = mk() end)
			local okE = pcall(function() local tm = lc.transportModes; tm[1] = true; tm[2] = true; lc.transportModes = tm end)
			log("MATRIX transportModes " .. name .. ": assign=" .. tostring(okA) .. " readback=" .. C.ser(C.marshal(lc.transportModes)) .. " " .. tostring(errA))
		end
		local lc = api.type.LaneConfig.new()
		log("MATRIX fresh LaneConfig transportModes=" .. C.ser(C.marshal(lc.transportModes)) .. " raw type=" .. type(lc.transportModes))
	end)
	pcall(function()
		local src = api.engine.getComponent(info.e, api.type.ComponentType.BASE_EDGE)
		log("MATRIX source edge: lanes=" .. tostring(#src.laneConfigs) .. " wire=" .. C.ser(C.marshal(src.laneConfigs)):sub(1, 300))
	end)
	for _, o in ipairs(MATRIX) do
		o.tmpl = tmpl
		o.cloneOf = info.e
		local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
		if not okb then
			log("MATRIX " .. o.name .. ": build error " .. shortErr(sp))
		else
			local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, nil, true, true) end)
			log("MATRIX " .. o.name .. ": " .. readBack(sp):gsub("edge id=.*tmpl=[^ ]* ", "") .. " -> factory " .. (okf and (cmd and "OK" or "nil") or shortErr(cmd)))
			if okf and cmd and not o.noEdge then accepted[#accepted + 1] = o end
		end
	end
	-- real builds
	local trials = {}
	for i, o in ipairs(accepted) do
		trials[#trials + 1] = { o = o, ie = false, pi = true }
	end
	local k = 10
	local function nextTrial(i)
		if i > #trials then return done() end
		local tr = trials[i]
		k = k + 1
		local n2, info2, pn2, a2 = matrixPlace(k)
		local o = tr.o
		o.tmpl = { roadTemplate = info2.c.roadTemplate, roadStyle = info2.c.roadStyle, roadType = info2.c.roadType }
		o.cloneOf = info2.e
		local okb, sp = pcall(buildMatrixProposal, o, n2, pn2, a2)
		if not okb then return nextTrial(i + 1) end
		local before = edgeCount()
		local answered = false
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			if not answered then
				answered = true
				log("MATRIX real build '" .. o.name .. "': no answer from the engine")
				nextTrial(i + 1)
			end
		end }
		local okc, errc = pcall(function()
			local ctx = nil
			if tr.ctx then
				ctx = api.type.Context.new()
				ctx.checkTerrainAlignment = true
				ctx.cleanupStreetGraph = true
				ctx.gatherBuildings = true
				ctx.gatherFields = true
				ctx.player = api.engine.util.getPlayer()
			end
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, tr.ie, tr.pi), function(res, success)
				if answered then return end
				answered = true
				local info = ""
				pcall(function()
					local m = C.marshal(res)
					C.appendFile(C.DIR .. BS .. "build_results.txt", "==== " .. o.name .. " ie=" .. tostring(tr.ie) .. " pi=" .. tostring(tr.pi) .. NL .. C.dump(res):sub(1, 20000) .. NL)
					local keys = {}
					for kk, _ in pairs(m or {}) do keys[#keys + 1] = tostring(kk) end
					info = "keys " .. table.concat(keys, ",")
					local rpd = m and (m.resultProposalData or m.proposalData)
					if rpd then info = info .. " errorState=" .. C.ser(rpd.errorState):sub(1, 600) end
				end)
				G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
					local after = edgeCount()
					local line = "real build '" .. o.name .. "' ctx=" .. tostring(tr.ctx) .. " pi=" .. tostring(tr.pi) .. ": success=" .. tostring(success) .. " edges " .. before .. " -> " .. after
					log("MATRIX " .. line .. " data=" .. info)
					AUTO.results[#AUTO.results + 1] = line
					if after > before then AUTO.points[#AUTO.points + 1] = pn2 end
					nextTrial(i + 1)
				end }
			end)
		end)
		if not okc then log("MATRIX send failed " .. shortErr(errc)); nextTrial(i + 1) end
	end
	nextTrial(1)
end

H.matrix = function(from, p)
	if p.role ~= C.ROLE then return end
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(runMatrix, function() send("autotest_done", { role = C.ROLE .. "_matrix", results = AUTO.results, points = AUTO.points }) end)
	if not ok then
		log("MATRIX failed: " .. tostring(err))
		send("autotest_done", { role = C.ROLE .. "_matrix", results = { "error " .. tostring(err) } })
	end
end

-- Upgrade scenario: the ENGINE makes the proposal (replaceSegment = the street upgrade tool), the originator applies it
-- as a player build; the other games must rebuild it from what is shipped.
local function playerContext()
	local c = api.type.Context.new()
	c.checkTerrainAlignment = false
	-- (the tools' proposals are cleaned up before they are applied; a scripted one cleaned at apply time gets node configurations the
	-- replays cannot know of: MPFEVER_CLEANUP=1 to test that)
	c.cleanupStreetGraph = os.getenv("MPFEVER_CLEANUP") == "1"
	c.gatherBuildings = false
	if os.getenv("MPFEVER_CTXMATCH") then c.checkTerrainAlignment = true; c.gatherBuildings = true end
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	return c
end

local function runUpgrade(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local edges = R.allEdges()
	local templates, list = {}, {}
	for _, e in ipairs(edges) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate ~= "" and #c.objects == 0 then
			templates[c.roadTemplate] = true
			list[#list + 1] = { e = e, c = c }
		end
	end
	local names = {}
	for t, _ in pairs(templates) do names[#names + 1] = t end
	table.sort(names)
	log("AUTOTEST upgrade (" .. C.ROLE .. "): " .. #list .. " street segments, templates: " .. table.concat(names, ", "))
	local tries = 0
	local function attempt(i)
		tries = tries + 1
		if tries > 6 then return autoFinish() end
		local pick = list[((p.offset or 0) * 53 + i * 97) % #list + 1]
		local target = nil
		for _, t in ipairs(names) do
			if t ~= pick.c.roadTemplate and t:find("town", 1, true) and not t:find("entrance", 1, true) then target = t; break end
		end
		local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(pick.e, target) end)
		if not okp or not P then
			log("AUTOTEST replaceSegment(" .. pick.e .. ") failed: " .. tostring(P))
			return attempt(i + 1)
		end
		local a = nodePosition(pick.c.node0)
		if false and p.ab and not AUTO.bisectDone then
			AUTO.bisectDone = true
			local compact = C.compactProposal(P)
			local ctx = playerContext()
			local function f(name, fn)
				local ok, res = pcall(function()
					local P2 = fn()
					return api.cmd.makeWorldBuildProposalCmd(P2, ctx, false, true)
				end)
				log("BISECT " .. name .. ": " .. (ok and (res and "OK" or "nil") or shortErr(res)))
			end
			local nat = P.proposal
			local natAdd, natRem = nat.addedSegments[1], nat.removedSegments[1]
			f("original", function() return P end)
			f("emptyNew", function() return api.type.Proposal.new() end)
			f("engineObjects", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				sp.addedSegments = { natAdd }; sp.removedSegments = { natRem }; P2.proposal = sp; return P2
			end)
			f("engineObjectsMaps", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				sp.addedSegments = { natAdd }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourAdded", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = C.rebuild("SegmentAndEntity", compact.proposal.addedSegments[1], "a")
				local c = e.comp; c.laneConfigs = C.templateLanes(compact.proposal.addedSegments[1].comp.roadTemplate); e.comp = c
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourAddedNatLanes", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = C.rebuild("SegmentAndEntity", compact.proposal.addedSegments[1], "a")
				local c = e.comp; c.laneConfigs = natAdd.comp.laneConfigs; e.comp = c
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourRemoved", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local r = C.rebuild("SegmentAndEntity", compact.proposal.removedSegments[1], "r")
				local c = r.comp; c.laneConfigs = natRem.comp.laneConfigs; r.comp = c
				sp.addedSegments = { natAdd }; sp.removedSegments = { r }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourBoth", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = C.rebuild("SegmentAndEntity", compact.proposal.addedSegments[1], "a")
				local c = e.comp; c.laneConfigs = natAdd.comp.laneConfigs; e.comp = c
				local r = C.rebuild("SegmentAndEntity", compact.proposal.removedSegments[1], "r")
				local c2 = r.comp; c2.laneConfigs = natRem.comp.laneConfigs; r.comp = c2
				sp.addedSegments = { e }; sp.removedSegments = { r }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("copyNewSegment", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = api.type.SegmentAndEntity.new()
				e.entity = natAdd.entity; e.type = natAdd.type; e.comp = natAdd.comp; e.streetEdge = natAdd.streetEdge
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("copyNewSegmentNoStreet", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = api.type.SegmentAndEntity.new()
				e.entity = natAdd.entity; e.type = natAdd.type; e.comp = natAdd.comp
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			local members = {}
			pcall(function() for _, k in ipairs(C.members(natAdd) or {}) do members[#members + 1] = k end end)
			log("BISECT SegmentAndEntity members: " .. table.concat(members, ","))
			local cm = {}
			pcall(function() for _, k in ipairs(C.members(natAdd.comp) or {}) do cm[#cm + 1] = k end end)
			log("BISECT BaseEdge members: " .. table.concat(cm, ","))
		end
		-- A/B: our rebuild of this very proposal first (same world, same game), engine answers dumped for comparison
		if false and p.ab and not AUTO.abDone then
			AUTO.abDone = true
			local okr, errr = pcall(function()
				local compact = C.compactProposal(P)
				local margs = { n = 4, [1] = compact, [2] = { __player = true }, [3] = false, [4] = true }
				R.translateOut("makeWorldBuildProposalCmd", margs, {})
				margs = C.deser(C.ser(margs))
				R.translateIn(margs, {})
				local args, n = C.rebuildArgs("makeWorldBuildProposalCmd", margs, { seed = 7919, variant = "native" })
				C.appendFile(C.DIR .. BS .. "ab_simple_in.txt", C.dump(args[1]):sub(1, 60000) .. NL)
				C.appendFile(C.DIR .. BS .. "ab_native_in.txt", C.dump(P):sub(1, 60000) .. NL)
				deferredSend(api.cmd.makeWorldBuildProposalCmd(table.unpack(args, 1, n)), function(res, success)
					C.appendFile(C.DIR .. BS .. "ab_simple.txt", "success=" .. tostring(success) .. NL .. C.dump(res):sub(1, 60000) .. NL)
					log("AUTOTEST A/B rebuilt proposal on the originator: " .. tostring(success))
					G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function() attempt(i) end }
				end)
			end)
			if not okr then log("AUTOTEST A/B failed: " .. tostring(errr)) else return end
		end
		local before = C.ser(C.marshal(api.engine.getComponent(pick.e, api.type.ComponentType.BASE_EDGE).roadTemplate))
		log("AUTOTEST sending the engine's upgrade proposal")
		local okc, errc = pcall(function()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)

				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				local line = "upgrade of segment " .. pick.e .. " to " .. tostring(target) .. ": " .. (success and "built" or ("refused " .. why))
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				if success then
					AUTO.points[#AUTO.points + 1] = a
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
				else
					G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function() attempt(i + 1) end }
				end
			end)
		end)
		if not okc then
			log("AUTOTEST upgrade command failed: " .. shortErr(errc))
			attempt(i + 1)
		end
	end
	attempt(1)
end

-- New road scenario: a road from a dead end, in the form the engine accepted (shared numbering, positions, lanes)
local function runNewRoad(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local tries = 0
	local function attempt(k)
		tries = tries + 1
		if tries > 6 then return autoFinish() end
		local n, info, pn, a = matrixPlace(k)
		local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
			tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
		if p.stop then
			o.stop = "stations/street/small_stops/small_old.con"
			o.stopEdge = (C.ROLE == "host") and -2 or -1   -- host: the segment's entity id; client: its index
			o.stopLeft = false
			o.tmpl = { roadTemplate = "::/infrastructure/street/town/town_old_small.street_template",
				roadStyle = "::/infrastructure/street/town/town_old_small.street", roadType = info.c.roadType }
			log("AUTOTEST new road with a stop, edgeEntity " .. o.stopEdge)
		end
		local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
		if not okb then log("AUTOTEST new road proposal error " .. shortErr(sp)); return attempt(k + 1) end
		local before = edgeCount()
		log("AUTOTEST new road from node " .. n)
		local okc, errc = pcall(function()
			local ctx = api.type.Context.new()
			ctx.checkTerrainAlignment = true
			-- (the street tool's proposals are cleaned up before they are applied: a scripted one cleaned at apply time gets node
			-- configurations no replay knows of; MPFEVER_CLEANUP=1 to see that)
			ctx.cleanupStreetGraph = os.getenv("MPFEVER_CLEANUP") == "1"
			ctx.gatherBuildings = true
			ctx.gatherFields = true
			ctx.player = api.engine.util.getPlayer()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
					local stops = 0
					pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do stops = stops + 1 end end)
					local line = "new road from node " .. n .. ": " .. (success and "built" or ("refused " .. why)) .. ", edges " .. before .. " -> " .. edgeCount() .. ", edge objects " .. stops
					log("AUTOTEST " .. line)
					AUTO.results[#AUTO.results + 1] = line
					if success then
						AUTO.points[#AUTO.points + 1] = pn
						G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
					else
						attempt(k + 1)
					end
				end }
			end)
		end)
		if not okc then log("AUTOTEST new road command failed: " .. shortErr(errc)); attempt(k + 1) end
	end
	attempt((p.offset or 0) + 20)
end

-- Exploration for separate companies: can a second player be created, and do builds / purchases honour it?
local runCompanyBuild
local function runCompany(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST company " .. t); AUTO.results[#AUTO.results + 1] = t end
	local P1 = api.engine.util.getPlayer()
	local function bal(P)
		local ok, v = pcall(function() local a = api.engine.getComponent(P, api.type.ComponentType.ACCOUNT); return a.balance end)
		return ok and v or ("err " .. tostring(v))
	end
	say("player 1 = " .. tostring(P1) .. ", balance " .. tostring(bal(P1)))
	local function comps(P)
		local out = {}
		for _, n in ipairs({ "PLAYER", "ACCOUNT", "NAME", "PLAYER_OWNED" }) do
			local ok, c = pcall(api.engine.getComponent, P, api.type.ComponentType[n])
			out[#out + 1] = n .. "=" .. ((ok and c) and "yes" or "no")
		end
		return table.concat(out, " ")
	end
	say("player 1 components: " .. comps(P1))
	local cmd = api.cmd.makeGameAddPlayerCmd("MPF Company 2", api.type.Vec3f.new(0.9, 0.2, 0.2))
	O.sendCommand(cmd, function(res, success)
		local P2 = nil
		pcall(function() P2 = res.resultEntity end)
		if not P2 then pcall(function() P2 = res.data and res.data.resultEntity end) end
		say("add player: success=" .. tostring(success) .. ", new entity " .. tostring(P2))
		if not success or not P2 then return autoFinish() end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
			say("player 2 exists=" .. tostring(api.engine.entityExists(P2)) .. " balance " .. tostring(bal(P2)) .. " components: " .. comps(P2))
			local acc = nil
			pcall(function() acc = api.engine.getComponent(P2, api.type.ComponentType.ACCOUNT) end)
			if acc then say("player 2 account balance " .. tostring(acc.balance) .. " loan " .. tostring(acc.loan)) end
			nativeCtl("setplayer " .. P2)
			G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function()
				local now = api.engine.util.getPlayer()
				say("after writing the game's local-player field: getPlayer() = " .. tostring(now) .. " (player 2 is " .. tostring(P2) .. ")")
				if now == P2 then say("balance seen through getPlayer: " .. tostring(bal(api.engine.util.getPlayer()))) end
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function() runCompanyBuild(P1, P2, say, bal) end }
			end }
		end }
	end)
end

runCompanyBuild = function(P1, P2, say, bal)
	do
		do
			local p = {}
			local entry = api.type.JournalEntry.new()
			entry.amount = 5000000
			entry.time = -1
			entry.category.type = api.type.JournalEntry.Type.OTHER
			O.sendCommand(api.cmd.makeJournalBookAssetCmd(P2, entry), function() end)
			local n, info, pn, a = matrixPlace((p.offset or 0) + 20)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
			local realGet = api.engine.util.getPlayer
			local swapped = pcall(function() api.engine.util.getPlayer = function() return P2 end end)
			local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
			if swapped then pcall(function() api.engine.util.getPlayer = realGet end) end
			say("owner override " .. tostring(swapped))
			if not okb then say("road proposal error " .. shortErr(sp)); return autoFinish() end
			local known = {}
			for _, e in ipairs(R.allEdges()) do known[e] = true end
			local b1, b2 = bal(P1), bal(P2)
			local ctx = api.type.Context.new()
			ctx.checkTerrainAlignment = true
			ctx.cleanupStreetGraph = true
			ctx.gatherBuildings = true
			ctx.gatherFields = true
			ctx.player = P2
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res2, ok2)
				G.waits[#G.waits + 1] = { at = G.frames + 40, fn = function()
					local owners = {}
					for _, e in ipairs(R.allEdges()) do
						if not known[e] then
							local po = nil
							pcall(function() po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED) end)
							owners[#owners + 1] = e .. ":" .. (po and tostring(po.player) or "none")
						end
					end
					say("road built with player 2 context: " .. tostring(ok2) .. "; new edges (owner) " .. table.concat(owners, ",")
						.. "; balance P1 " .. tostring(b1) .. " -> " .. tostring(bal(P1)) .. ", P2 " .. tostring(b2) .. " -> " .. tostring(bal(P2)))
					-- a vehicle bought for player 2
					local vehicles = R.entitiesWith("TRANSPORT_VEHICLE")
					local pick = nil
					for _, v in ipairs(vehicles) do
						local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
						if tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) then pick = tv; break end
					end
					if not pick then say("no vehicle to copy"); return autoFinish() end
					local c1, c2, nv = bal(P1), bal(P2), #vehicles
					O.sendCommand(api.cmd.makeVehicleBuyCmd(P2, pick.depot, pick.transportVehicleConfig), function(res3, ok3)
						G.waits[#G.waits + 1] = { at = G.frames + 40, fn = function()
							local newOwner = "?"
							for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
								if v > 0 then
									local po = nil
									pcall(function() po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED) end)
									if po and po.player == P2 then newOwner = tostring(v) end
								end
							end
							say("vehicle bought for player 2: " .. tostring(ok3) .. ", vehicles " .. nv .. " -> " .. #R.entitiesWith("TRANSPORT_VEHICLE")
								.. ", vehicle owned by P2: " .. newOwner .. "; balance P1 " .. tostring(c1) .. " -> " .. tostring(bal(P1)) .. ", P2 " .. tostring(c2) .. " -> " .. tostring(bal(P2)))
							autoFinish()
						end }
					end)
				end }
			end)
		end
	end
end

H.company = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runCompany, p)
	if not ok then
		log("AUTOTEST company failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "company error " .. tostring(err)
		autoFinish()
	end
end

-- Exploration: which word of memory is read by getPlayer()? Candidates (words equal to player 1's id, found by the DLL) are
-- patched one at a time to player 2's id; the candidate that changes getPlayer() is the local-player field.
H.pprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local P1 = api.engine.util.getPlayer()
	local function say(t) log("AUTOTEST pprobe " .. t); AUTO.results[#AUTO.results + 1] = t end
	O.sendCommand(api.cmd.makeGameAddPlayerCmd("MPF probe", api.type.Vec3f.new(0.2, 0.6, 0.9)), function(res, success)
		local P2 = res.resultEntity
		say("player 2 = " .. tostring(P2) .. " (player 1 = " .. tostring(P1) .. ")")
		nativeCtl("setplayer " .. P2)
		local i = 0
		local function nextCandidate()
			i = i + 1
			if i > (tonumber(p.max) or 160) then
				nativeCtl("probe 0")
				say("no candidate changed getPlayer()")
				return autoFinish()
			end
			nativeCtl("probe " .. i)
			O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
			G.waits[#G.waits + 1] = { at = G.frames + 24, fn = function()
				local now = api.engine.util.getPlayer()
				if now ~= P1 then
					say("candidate " .. i .. " is the local-player field: getPlayer() became " .. tostring(now))
					G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
						nativeCtl("probe 0")
						O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
						G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
					end }
				else
					nextCandidate()
				end
			end }
		end
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = nextCandidate }
	end)
end

-- Exploration: how the DLL's iteration counter relates to the game time (paused, stepped, and running)
H.iterclock = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local seq = 0
	local function mark(tag)
		seq = seq + 1
		nativeCtl("iterlog " .. seq)
		O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
		local t = gameTime()
		local line = "mark " .. seq .. " (" .. tag .. ") game time " .. t .. " speed " .. tostring(gameSpeed())
		log("AUTOTEST iterclock " .. line)
		AUTO.results[#AUTO.results + 1] = line
	end
	local plan = { 1, 3, 5, 2, 8 }
	local k = 0
	local function nextStep()
		k = k + 1
		if k > #plan then
			O.sendCommand(O.setSpeed(1))
			G.waits[#G.waits + 1] = { at = G.frames + 420, fn = function()
				O.sendCommand(O.setSpeed(0))
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = function() mark("after ~7 s at x1"); autoFinish() end }
			end }
			return
		end
		O.sendCommand(O.steps(plan[k]))
		G.waits[#G.waits + 1] = { at = G.frames + 150, fn = function() mark(plan[k] .. " steps"); nextStep() end }
	end
	O.sendCommand(O.setSpeed(0))
	G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function() mark("paused"); nextStep() end }
end

-- Terrain edit (a patch of ground raised, 4 m cells): the DLL copies the cells, the other game must make the same ground
-- (with MPFEVER_TERRAIN_PATTERN=1 the DLL gives the cells an uneven pattern, so that the copy is checked cell by cell)
H.terrain = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local n = tonumber(os.getenv("MPFEVER_TERRAIN_SIZE") or "12") or 12
		local burst = tonumber(os.getenv("MPFEVER_TERRAIN_BURST") or "1") or 1       -- edits sent in the same frame
		local bx, by = -640, -756
		if C.ROLE ~= "host" then bx, by = 300, -200 end
		local patches = {}
		for i = 1, burst do
			patches[i] = { x0 = bx + (i - 1) * (n + 6), y0 = by, w = n + (i - 1), h = n + (i - 1) }
			local pt = patches[i]
			pt.cx, pt.cy = (pt.x0 + pt.w / 2) * 4, (pt.y0 + pt.h / 2) * 4
			pt.h0 = nil
			pcall(function() pt.h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(pt.cx, pt.cy)) end)
			pt.sum0 = G.terrainSum(pt.x0, pt.y0, pt.w, pt.h)
		end
		local pending = burst
		for i, pt in ipairs(patches) do
			local prop = api.type.Proposal.new()
			local zero = os.getenv("MPFEVER_TERRAIN_ZERO")      -- test: an edit whose cells are all {0, 0} (what an empty carrier would be)
			prop.terrain.baseHeightMod = api.type.GridVec2f.new(pt.x0, pt.y0, pt.w, pt.h, zero and api.type.Vec2f.new(0, 0) or api.type.Vec2f.new((pt.h0 or 0) + 3, pt.h0 or 0))
			local ctx = api.type.Context.new()
			ctx.player = api.engine.util.getPlayer()
			log("AUTOTEST terrain edit " .. i .. "/" .. burst .. ": " .. pt.w .. "x" .. pt.h .. " at " .. pt.x0 .. "," .. pt.y0 .. ": height " .. tostring(pt.h0) .. ", sum " .. pt.sum0)
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true), function(res, success)
				local line = "terrain edit " .. i .. ": " .. (success and "built" or "refused")
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				pending = pending - 1
				if pending == 0 then
					G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
						for j, q in ipairs(patches) do
							local h1 = nil
							pcall(function() h1 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(q.cx, q.cy)) end)
							local line2 = "ground after " .. j .. ": centre " .. tostring(q.h0) .. " -> " .. tostring(h1) .. ", sum " .. G.terrainSum(q.x0, q.y0, q.w, q.h)
							log("AUTOTEST " .. line2)
							AUTO.results[#AUTO.results + 1] = line2
						end
						autoFinish()
					end }
				end
			end)
		end
	end)
	if not ok then
		AUTO.results[#AUTO.results + 1] = "terrain error " .. tostring(err)
		autoFinish()
	end
end

-- A series of terrain edits one after the other (MPFEVER_TERRAIN_COUNT, MPFEVER_TERRAIN_SIZE, MPFEVER_TERRAIN_GAP frames between them)
H.terrainsoak = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local count = tonumber(os.getenv("MPFEVER_TERRAIN_COUNT") or "10") or 10
	local n = tonumber(os.getenv("MPFEVER_TERRAIN_SIZE") or "20") or 20
	local gap = tonumber(os.getenv("MPFEVER_TERRAIN_GAP") or "90") or 90
	local bx, by = -640, -756
	if C.ROLE ~= "host" then bx, by = 300, -200 end
	local patches, k = {}, 0
	local function finish()
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			local bad = 0
			for j, q in ipairs(patches) do
				local line = "ground after " .. j .. ": sum " .. G.terrainSum(q.x0, q.y0, q.w, q.h)
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
			end
			autoFinish()
		end }
	end
	local function nextEdit()
		k = k + 1
		if k > count then return finish() end
		local pt = { x0 = bx + ((k - 1) % 6) * (n + 4), y0 = by + math.floor((k - 1) / 6) * (n + 4), w = n, h = n }
		patches[#patches + 1] = pt
		local ok, err = pcall(function()
			local cx, cy = (pt.x0 + pt.w / 2) * 4, (pt.y0 + pt.h / 2) * 4
			local h0 = nil
			pcall(function() h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(cx, cy)) end)
			local prop = api.type.Proposal.new()
			prop.terrain.baseHeightMod = api.type.GridVec2f.new(pt.x0, pt.y0, pt.w, pt.h, api.type.Vec2f.new((h0 or 0) + 1 + (k % 4), h0 or 0))
			local ctx = api.type.Context.new()
			ctx.player = api.engine.util.getPlayer()
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true), function(res, success)
				if not success then AUTO.results[#AUTO.results + 1] = "terrain edit " .. k .. ": refused" end
				G.waits[#G.waits + 1] = { at = G.frames + gap, fn = nextEdit }
			end)
		end)
		if not ok then
			AUTO.results[#AUTO.results + 1] = "terrain edit " .. k .. " error " .. tostring(err)
			G.waits[#G.waits + 1] = { at = G.frames + gap, fn = nextEdit }
		end
	end
	nextEdit()
end

-- Diagnostic (with MPFEVER_PAYLOAD_DUMP=1 in the DLL): empty world-build commands that differ by one flag of the Context, so
-- that the bytes of the flags can be found in the command (then read from the real tools' commands)
H.ctxprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local variants = {
		{ "none", {}, false, true },
		{ "align", { checkTerrainAlignment = true }, false, true },
		{ "cleanup", { cleanupStreetGraph = true }, false, true },
		{ "buildings", { gatherBuildings = true }, false, true },
		{ "fields", { gatherFields = true }, false, true },
		{ "all", { checkTerrainAlignment = true, cleanupStreetGraph = true, gatherBuildings = true, gatherFields = true }, false, true },
		{ "ignore", {}, true, true },
		{ "notplayer", {}, false, false },
	}
	local i = 0
	local function nextOne()
		i = i + 1
		local v = variants[i]
		if not v then return autoFinish() end
		local ok, err = pcall(function()
			local ctx = api.type.Context.new()
			for k, x in pairs(v[2]) do ctx[k] = x end
			ctx.player = api.engine.util.getPlayer()
			log("AUTOTEST ctxprobe " .. i .. " " .. v[1])
			AUTO.results[#AUTO.results + 1] = "ctxprobe " .. i .. " " .. v[1]
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(api.type.Proposal.new(), ctx, v[3], v[4]), function() end)
		end)
		if not ok then AUTO.results[#AUTO.results + 1] = "ctxprobe error " .. tostring(err) end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextOne }
	end
	nextOne()
end

H.deferroad = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.deferCount = (AUTO.deferCount or 0) + 1
	nativeCtl("defernext " .. AUTO.deferCount)
	log("AUTOTEST next road command held by the DLL (test mode)")
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST deferred road failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "error " .. tostring(err)
		autoFinish()
	end
end

H.newroadstop = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.stop = true
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST new road with stop failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "error " .. tostring(err)
		autoFinish()
	end
end

H.newroad = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST new road failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "new road error " .. tostring(err)
		autoFinish()
	end
end

-- Stop scenario: which proposal form can put a bus stop on an existing street segment?
local function stopForms(E)
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local function eo(edgeEntity)
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		o.edgeEntity = edgeEntity
		o.param = 0.5
		o.oneWay = false
		o.left = true
		o.model = STOP_MODEL
		o.playerEntity = api.engine.util.getPlayer()
		o.name = "MPF stop"
		return o
	end
	local function copySeg(id, withPos)
		local e = api.type.SegmentAndEntity.new()
		e.entity = id
		e.type = 0
		local cc = e.comp
		cc.node0 = c.node0; cc.node1 = c.node1
		cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
		if withPos then cc.position0 = vec(c.position0); cc.position1 = vec(c.position1) end
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		cc.laneConfigs = c.laneConfigs   -- the segment's own lanes (engine objects)
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		return e
	end
	pcall(function()
		local function tm(l) local t = {} for i = 1, #l do t[#t + 1] = C.ser(C.marshal(l[i].transportModes)) end return table.concat(t, " ") end
		log("STOPS lanes segment: " .. tm(c.laneConfigs))
		log("STOPS lanes template: " .. tm(C.templateLanes(c.roadTemplate)))
	end)
	local function cfgNodes()
		local list = {}
		for _, n in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then list[#list + 1] = n end
		end
		return list
	end
	return {
		{ name = "replacePosCfgObj", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			local sg = copySeg(-1, true)
			local sc = sg.comp; sc.objects = { { -400000000, 0 } }; sg.comp = sc
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { sg }; ssp.edgeObjectsToAdd = { eo(-1) }
			ssp.nodeConfigsToRemove = cfgNodes()
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceNoPosCfg", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			ssp.nodeConfigsToRemove = cfgNodes()
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceGather", gather = true, make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceGatherNoCleanup", gather = true, nocleanup = true, make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceGatherIgnore", gather = true, ie = true, make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "objectOnExisting", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgeObjectsToAdd = { eo(E) }; sp.streetProposal = ssp; return sp end },
		{ name = "replaceNoPos", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replacePos", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, true) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceId2", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-2, false) }; ssp.edgeObjectsToAdd = { eo(-2) }
			sp.streetProposal = ssp; return sp end },
	}
end

local c0node = nil
local function runStopMatrix(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local forms = nil
	local i = 0
	local function nextForm()
		i = i + 1
		if forms and i > #forms then return autoFinish() end
		local E = list[((p.offset or 0) * 31 + i * 67) % #list + 1]
		c0node = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).node0
		forms = forms or stopForms(E)
		local f = stopForms(E)[i]
		local okb, sp = pcall(f.make)
		if not okb then log("STOPS " .. f.name .. ": build error " .. shortErr(sp)); return nextForm() end
		local ctx = playerContext()
		if f.gather then ctx.gatherBuildings = true; ctx.checkTerrainAlignment = true end
		if f.nocleanup then ctx.cleanupStreetGraph = false end
		local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, f.ie == true, true) end)
		if not okf or not cmd then log("STOPS " .. f.name .. ": factory " .. shortErr(cmd)); return nextForm() end
		O.sendCommand(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			local n = 0
			pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
			local line = "stop form " .. f.name .. " on segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
			log("STOPS " .. line)
			AUTO.results[#AUTO.results + 1] = line
			if success then
				AUTO.points[#AUTO.points + 1] = nodePosition(c0node or 0) or { x = 0, y = 0, z = 0 }
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
			else
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = nextForm }
			end
		end)
	end
	nextForm()
end

H.stops = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStopMatrix, p)
	if not ok then
		log("STOPS failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops error " .. tostring(err)
		autoFinish()
	end
end

-- Stop on a street without sidewalks (what the stop tool does there: it adds two platform lanes to the segment)
local function runTramStop(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function hasPersonLane(c)
		for i = 1, #c.laneConfigs do if c.laneConfigs[i].transportModes[0] then return true end end
		return false
	end
	local list = {}
	local function scan()
		list = {}
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if c and c.type == 0 and #c.objects == 0 and #c.laneConfigs > 0 and not hasPersonLane(c) then list[#list + 1] = e end
		end
		log("TRAMSTOP " .. #list .. " street segments without sidewalks")
	end
	scan()
	if #list == 0 and not p.built then
		-- none in the save: build a tram road (no sidewalks) from a dead end first, then retry
		local tries = 0
		local function build(k)
			tries = tries + 1
			if tries > 6 then
				AUTO.results[#AUTO.results + 1] = "could not build a tram road"
				return autoFinish()
			end
			local n, info, pn, a = matrixPlace(k)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = "::/infrastructure/street/tram/tram_old.street_template",
					roadStyle = "::/infrastructure/street/tram/tram_old.street", roadType = info.c.roadType } }
			local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
			if not okb then log("TRAMSTOP road proposal error " .. shortErr(sp)); return build(k + 1) end
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				log("TRAMSTOP tram road from node " .. n .. ": " .. tostring(success))
				if success then
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
						AUTO.running = false
						p.built = true
						local ok, err = pcall(runTramStop, p)
						if not ok then log("TRAMSTOP failed: " .. tostring(err)); autoFinish() end
					end }
				else
					G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function() build(k + 1) end }
				end
			end)
		end
		return build((p.offset or 0) * 5 + 20)
	end
	if #list == 0 then
		AUTO.results[#AUTO.results + 1] = "no street segment without sidewalks"
		return autoFinish()
	end
	local function stopCount()
		local n = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
		return n
	end
	local variants = { "platformLanes" }
	log("TRAMSTOP transportModes write shift " .. tostring(C.transportModesWriteShift()))
	local i = 0
	local convertedEO = nil
	local function platformLanes(c)
		local platform = { speed = 10, width = 5, height = 0.1, forward = true, offset = 0, transportModes = { [0] = true } }
		local m = { platform }
		for _, l in ipairs(C.marshal(c.laneConfigs)) do m[#m + 1] = l end
		m[#m + 1] = platform
		return C.rebuildLanes(m)
	end
	local nextVariant
	-- the engine's own replacement of the segment, with the stop grafted (as the stop tool builds it)
	local function nativeVariant(v, E, c)
		local P = api.engine.util.proposal.replaceSegment(E, c.roadTemplate)
		local st = P.proposal
		local segs = st.addedSegments
		local seg = segs[1]
		local sc = seg.comp
		sc.objects = { { -400000000, 0 } }
		sc.laneConfigs = platformLanes(c)
		seg.comp = sc
		segs[1] = seg
		st.addedSegments = segs
		local eo
		if v == "nativeConverted" then
			eo = convertedEO
		else
			eo = api.type.StreetProposal.EdgeObject.new()
			eo.resultEntity = -1; eo.category = 0; eo.oneWay = false; eo.left = true
			eo.name = "MPF stop"; eo.playerEntity = api.engine.util.getPlayer()
		end
		eo.segmentEntity = seg.entity
		st.edgeObjectsToAdd = { eo }
		P.proposal = st
		log("TRAMSTOP " .. v .. ": segment id " .. tostring(seg.entity) .. ", node configs +" .. #st.nodeConfigsToAdd .. " -" .. #st.nodeConfigsToRemove)
		return P
	end
	nextVariant = function()
		i = i + 1
		local v = variants[i]
		if not v then return autoFinish() end
		scan()
		if #list == 0 then return autoFinish() end
		local E = list[((p.offset or 0) * 7 + i * 13) % #list + 1]
		local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		if v == "nativeConverted" and not convertedEO then
			-- get the engine's converted stop object: a stop on a town street in the form the engine refuses (parcels)
			local T = nil
			for _, e in ipairs(R.allEdges()) do
				local tc = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if tc and tc.type == 0 and tc.roadTemplate and tc.roadTemplate:find("town", 1, true) and #tc.objects == 0 then T = e; break end
			end
			local tc = api.engine.getComponent(T, api.type.ComponentType.BASE_EDGE)
			local sp = api.type.SimpleProposal.new()
			local ssp = sp.streetProposal
			local e = api.type.SegmentAndEntity.new()
			e.entity = -1; e.type = 0
			local cc = e.comp
			cc.node0 = tc.node0; cc.node1 = tc.node1
			cc.tangent0 = vec(tc.tangent0); cc.tangent1 = vec(tc.tangent1)
			cc.type = 0; cc.typeIndex = -1
			cc.roadTemplate = tc.roadTemplate; cc.roadStyle = tc.roadStyle; cc.roadType = tc.roadType
			cc.laneConfigs = C.templateLanes(tc.roadTemplate)
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			local o = api.type.SimpleStreetProposal.EdgeObject.new()
			o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = true
			o.model = STOP_MODEL
			o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF stop"
			ssp.edgesToRemove = { T }; ssp.edgesToAdd = { e }; ssp.edgeObjectsToAdd = { o }
			sp.streetProposal = ssp
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				log("TRAMSTOP conversion probe on town segment " .. T .. ": success " .. tostring(success))
				pcall(function()
					local list2 = res.proposal.proposal.edgeObjectsToAdd
					log("TRAMSTOP converted stops " .. #list2)
					if #list2 > 0 then convertedEO = list2[1] end
				end)
				i = i - 1
				if not convertedEO then
					AUTO.results[#AUTO.results + 1] = "no converted stop object"
					i = i + 1
				end
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = nextVariant }
			end)
			return
		end
		if v:sub(1, 6) == "native" then
			local before = stopCount()
			local okp, P = pcall(nativeVariant, v, E, c)
			if not okp then
				AUTO.results[#AUTO.results + 1] = "tram stop " .. v .. ": proposal " .. shortErr(P)
				return nextVariant()
			end
			local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true) end)
			if not okf or not cmd then
				AUTO.results[#AUTO.results + 1] = "tram stop " .. v .. ": factory " .. shortErr(cmd)
				return nextVariant()
			end
			deferredSend(cmd, function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
					local after = stopCount()
					local model = ""
					pcall(function()
						for eoE, _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do
							local x = api.engine.getComponent(eoE, api.type.ComponentType.EDGE_OBJECT)
							if x and x.edgeObjectConstruction then model = model .. " " .. tostring(x.edgeObjectConstruction) end
						end
					end)
					local line = "tram stop " .. v .. " on segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why)) .. ", stops " .. before .. " -> " .. after
					log("TRAMSTOP " .. line .. " models:" .. model)
					AUTO.results[#AUTO.results + 1] = line
					if success then AUTO.points[#AUTO.points + 1] = nodePosition(c.node0) end
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextVariant }
				end }
			end)
			return
		end
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		local e = api.type.SegmentAndEntity.new()
		e.entity = -1
		e.type = 0
		local cc = e.comp
		cc.node0 = c.node0; cc.node1 = c.node1
		cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
		cc.position0 = vec(nodePosition(c.node0)); cc.position1 = vec(nodePosition(c.node1))
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		if v == "platformLanes" then
			local platform = { speed = 10, width = 5, height = 0.1, forward = true, offset = 0, transportModes = { [0] = true } }
			local m = { platform }
			for _, l in ipairs(C.marshal(c.laneConfigs)) do m[#m + 1] = l end
			m[#m + 1] = platform
			cc.laneConfigs = C.rebuildLanes(m)
		else
			cc.laneConfigs = c.laneConfigs
		end
		cc.objects = { { -400000000, 0 } }
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		local eo = api.type.SimpleStreetProposal.EdgeObject.new()
		eo.edgeEntity = -1; eo.param = 0.5; eo.oneWay = false; eo.left = true
		eo.model = STOP_MODEL
		eo.playerEntity = api.engine.util.getPlayer()
		eo.name = "MPF stop"
		local ncr = {}
		for _, n in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = n end
		end
		ssp.edgesToRemove = { E }; ssp.edgesToAdd = { e }; ssp.edgeObjectsToAdd = { eo }
		if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
		sp.streetProposal = ssp
		local before = stopCount()
		local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true) end)
		if not okf or not cmd then
			AUTO.results[#AUTO.results + 1] = "tram stop " .. v .. ": factory " .. shortErr(cmd)
			return nextVariant()
		end
		deferredSend(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				local line = "tram stop " .. v .. " on segment " .. E .. " (" .. tostring(c.roadTemplate) .. "): "
					.. (success and "BUILT" or ("refused " .. why)) .. ", stops " .. before .. " -> " .. stopCount()
				log("TRAMSTOP " .. line)
				AUTO.results[#AUTO.results + 1] = line
				if success then AUTO.points[#AUTO.points + 1] = nodePosition(c.node0) end
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextVariant }
			end }
		end)
	end
	nextVariant()
end

H.tramstop = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runTramStop, p)
	if not ok then
		log("TRAMSTOP failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "tramstop error " .. tostring(err)
		autoFinish()
	end
end

-- Replays native builds captured in a real game (one compact proposal per line in <temp>\mpfever\replay_case.txt),
-- through the same path as a peer: checks the segment count against the originator's
local function runReplayFile(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local path = C.DIR:gsub("[^" .. BS .. "]+$", "") .. "replay_case.txt"
	-- replay_acts.txt: acts exactly as a peer received them (third column of in.log)
	local actsPath = C.DIR:gsub("[^" .. BS .. "]+$", "") .. "replay_acts.txt"
	local fa = C.IO.open(actsPath, "rb")
	if fa then
		local acts = {}
		for l in fa:lines() do if #l > 2 then acts[#acts + 1] = l end end
		fa:close()
		local k = 0
		local function nextAct()
			k = k + 1
			if not acts[k] then return autoFinish() end
			local a = C.deser(acts[k])
			a.uid = "act:" .. k .. ":" .. tostring(a.uid)
			local st = a.args[1].proposal
			local line = "act " .. k .. ": originator +" .. #st.addedSegments .. " -" .. #st.removedSegments .. ", edges before " .. #R.allEdges()
			if k == 2 then
				pcall(function()
					local d = {}
					for _, e in ipairs(R.allEdges()) do
						local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
						local p0, p1 = nodePosition(c.node0), nodePosition(c.node1)
						local function near(q) return q and math.abs(q.x - 1416) < 60 and math.abs(q.y + 346.6) < 60 end
						if near(p0) or near(p1) then
							d[#d + 1] = string.format("%d %d(%.1f %.1f)-%d(%.1f %.1f) t0(%.1f %.1f) t1(%.1f %.1f) %s", e, c.node0, p0.x, p0.y, c.node1, p1.x, p1.y,
								c.tangent0.x, c.tangent0.y, c.tangent1.x, c.tangent1.y, tostring(c.roadTemplate):match("[^/]+$"))
						end
					end
					log("REPLAYFILE near: " .. table.concat(d, " | "))
				end)
			end
			local ok, err = pcall(replayNative, a, 1)
			if not ok then line = line .. ", replay error " .. tostring(err) end
			G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function()
				line = line .. ", after " .. #R.allEdges()
				local deco, tram, dist5, track0 = 0, 0, 0, 0
				pcall(function()
					for _, e in ipairs(R.allEdges()) do
						local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
						if c and #c.edgeDecorations > 0 then deco = deco + 1 end
						local hasTram = false
						pcall(function() for k = 1, #c.laneConfigs do if c.laneConfigs[k].transportModes[5] then hasTram = true end end end)
						if hasTram then tram = tram + 1 end
						if c and c.distance and c.distance > 0 then dist5 = dist5 + 1 end
						if c and c.type == 1 and c.distance == 0 then track0 = track0 + 1 end
					end
				end)
				line = line .. ", edges with decorations " .. deco .. ", with tram lanes " .. tram .. ", with distance " .. dist5 .. ", tracks with distance 0: " .. track0
				log("REPLAYFILE " .. line)
				AUTO.results[#AUTO.results + 1] = line
				nextAct()
			end }
		end
		return nextAct()
	end
	local f = C.IO.open(path, "rb")
	if not f then AUTO.results[#AUTO.results + 1] = "no " .. path; return autoFinish() end
	local lines = {}
	for l in f:lines() do if #l > 2 then lines[#lines + 1] = l end end
	f:close()
	local i = 0
	local function nextOne()
		i = i + 1
		if not lines[i] then return end
		local compact = C.deser(lines[i])
		local margs = { n = 4, [1] = compact, [2] = { __player = true }, [3] = false, [4] = true }
		R.translateOut("makeWorldBuildProposalCmd", margs, {})
		local a = { uid = "file:" .. i, origin = "file", fn = "makeWorldBuildProposalCmd", args = C.deser(C.ser(margs)), native = true }
		local st = compact.proposal
		local line = "case " .. i .. ": originator +" .. #st.addedSegments .. " -" .. #st.removedSegments .. ", edges before " .. #R.allEdges()
		local ok, err = pcall(replayNative, a, 1)
		if not ok then line = line .. ", replay error " .. tostring(err) end
		G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function()
			line = line .. ", after " .. #R.allEdges()
			log("REPLAYFILE " .. line)
			AUTO.results[#AUTO.results + 1] = line
			nextOne()
		end }
	end
	nextOne()
	G.waits[#G.waits + 1] = { at = G.frames + 120 * (#lines + 1), fn = autoFinish }
end

H.replayfile = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	if C.ROLE ~= "host" then AUTO.results = { "host only" }; return autoFinish() end
	local ok, err = pcall(runReplayFile, p)
	if not ok then
		log("REPLAYFILE failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "replayfile error " .. tostring(err)
		autoFinish()
	end
end

-- Bulldozer scenario: the engine's own removal proposal for a dead-end segment
local function runBulldoze(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- what the API offers to build stops inside an engine proposal
	local av = {}
	for _, path in ipairs({ "api.type.EdgeObject", "api.type.Proposal.EdgeObject", "api.type.ProposalEdgeObject", "api.type.ModelInstance",
		"api.type.Proposal.StreetProposal", "api.type.StreetProposal" }) do
		local cur = _G
		for part in path:gmatch("[^.]+") do if cur ~= nil then local ok, v = pcall(function() return cur[part] end); cur = ok and v or nil end end
		local canNew = false
		if cur ~= nil then canNew = pcall(function() return cur.new() end) end
		av[#av + 1] = path .. "=" .. type(cur) .. (canNew and "(new ok)" or "")
	end
	log("BULLDOZE api: " .. table.concat(av, ", "))
	local ends, edgeOf = deadEnds()
	local tries = 0
	local function attempt(k)
		tries = tries + 1
		if tries > 6 then return autoFinish() end
		local n = ends[(k * 41) % #ends + 1]
		local info = edgeOf[n]
		local okp, P = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal({ info.e }) end)
		if not okp or not P then log("BULLDOZE no proposal " .. tostring(P)); return attempt(k + 1) end
		local before = edgeCount()
		local pn = nodePosition(n)
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				local line = "bulldoze segment " .. info.e .. ": " .. (success and "removed" or ("refused " .. why)) .. ", edges " .. before .. " -> " .. edgeCount()
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				if success then
					AUTO.points[#AUTO.points + 1] = pn
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
				else
					attempt(k + 1)
				end
			end }
		end)
	end
	attempt((p.offset or 0) + 3)
end

H.bulldoze = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runBulldoze, p)
	if not ok then
		log("BULLDOZE failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "bulldoze error " .. tostring(err)
		autoFinish()
	end
end

-- Stops inside an engine-made proposal
local function runStops2(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function mem(o)
		local t = {}
		pcall(function() for _, k in ipairs(C.members(o) or {}) do t[#t + 1] = k end end)
		return table.concat(t, ",")
	end
	pcall(function() log("STOPS2 EdgeObject members: " .. mem(api.type.EdgeObject.new())) end)
	pcall(function() log("STOPS2 ModelInstance members: " .. mem(api.type.ModelInstance.new())) end)
	pcall(function() log("STOPS2 StreetProposal members: " .. mem(api.type.StreetProposal.new())) end)
	for _, path in ipairs({ "api.type.StreetProposal.EdgeObject", "api.type.StreetProposalEdgeObject", "api.type.Proposal.StreetProposal",
		"api.type.ProposalEdgeObject", "api.type.StreetProposal.NodeAndEntity" }) do
		local cur = _G
		for part in path:gmatch("[^.]+") do if cur ~= nil then local ok, v = pcall(function() return cur[part] end); cur = ok and v or nil end end
		local ok, obj = false, nil
		if cur ~= nil then ok, obj = pcall(function() return cur.new() end) end
		log("STOPS2 type " .. path .. " = " .. type(cur) .. (ok and obj and (" new ok, members: " .. mem(obj)) or ""))
	end
	pcall(function()
		local keys = {}
		for k, _ in pairs(api.type) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		log("STOPS2 api.type: " .. table.concat(keys, ","))
	end)
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local E = list[((p.offset or 0) * 31 + 67) % #list + 1]
	local ctx = playerContext()
	local function try(name, mk)
		local ok, res = pcall(function() return api.cmd.makeWorldBuildProposalCmd(mk(), ctx, false, true) end)
		log("STOPS2 " .. name .. ": factory " .. (ok and (res and "OK" or "nil") or shortErr(res)))
		return ok and res or nil
	end
	try("replaceSegment as is", function() return api.engine.util.proposal.replaceSegment(E) end)
	try("replaceSegment reassigned", function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		P.proposal = sp
		return P
	end)
	try("replaceSegment segments reassigned", function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		local segs = sp.addedSegments
		sp.addedSegments = segs
		P.proposal = sp
		return P
	end)
	local withStop
	withStop = function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		local segs = sp.addedSegments
		local seg = segs[1]
		local c = seg.comp
		c.objects = { { -400000000, 1 } }
		seg.comp = c
		segs[1] = seg
		sp.addedSegments = segs
		local EOT = nil
		pcall(function() EOT = api.type.StreetProposal.EdgeObject end)
		local eo = EOT and EOT.new() or api.type.EdgeObject.new()
		pcall(function() eo.resultEntity = -1 end)
		pcall(function() eo.category = 0 end)
		pcall(function() eo.segmentEntity = seg.entity end)
		pcall(function() eo.left = true end)
		pcall(function() eo.oneWay = false end)
		pcall(function() eo.name = "MPF stop" end)
		pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
		pcall(function() eo.param = 0.5 end)
		pcall(function() eo.edgeObjectConstruction = STOP_MODEL end)
		pcall(function() eo.model = STOP_MODEL end)
		sp.edgeObjectsToAdd = { eo }
		P.proposal = sp
		log("STOPS2 stop object: " .. C.ser(C.marshal(eo)):sub(1, 400))
		return P
	end
	-- a template stop object: the engine re-adds the stops of a segment it replaces
	local T = nil
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and #c.objects > 0 then T = e; break end
	end
	local template = nil
	if T then
		local okt, errt = pcall(function()
			local P0 = api.engine.util.proposal.replaceSegment(T)
			local sp0 = P0.proposal
			local list = sp0.edgeObjectsToAdd
			log("STOPS2 template segment " .. T .. ": objects to add " .. #list .. ", segment objects " .. C.ser(C.marshal(sp0.addedSegments[1].comp.objects)))
			if #list > 0 then
				template = list[1]
				log("STOPS2 template members: " .. mem(template) .. " = " .. C.ser(C.marshal(template)):sub(1, 600))
				pcall(function() log("STOPS2 template modelInstance: " .. mem(template.modelInstance) .. " modelId=" .. tostring(template.modelInstance.modelId)) end)
			end
		end)
		if not okt then log("STOPS2 template failed: " .. tostring(errt)) end
	end
	-- template from the engine's own conversion of a stop on a road outside the map (refused, nothing is built)
	local function afterTemplate()
		if not template then AUTO.results[#AUTO.results + 1] = "no stop template"; return autoFinish() end
		withStop = function()
			local P = api.engine.util.proposal.replaceSegment(E)
			local sp = P.proposal
			local segs = sp.addedSegments
			local seg = segs[1]
			local c = seg.comp
			c.objects = { { -400000000, 1 } }
			seg.comp = c
			segs[1] = seg
			sp.addedSegments = segs
			local eo = template
			pcall(function() eo.resultEntity = -1 end)
			pcall(function() eo.segmentEntity = seg.entity end)
			pcall(function() eo.left = false end)
			pcall(function() eo.name = "MPF stop" end)
			pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
			pcall(function()
				local mi = eo.modelInstance
				local tr = mi.transf
				local a, b = c.position0, c.position1
				local V = api.type.Vec4f.new
				mi.transf = api.type.Mat4f.new(V(tr[1], tr[2], tr[3], tr[4]), V(tr[5], tr[6], tr[7], tr[8]), V(tr[9], tr[10], tr[11], tr[12]),
					V((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1))
				eo.modelInstance = mi
			end)
			sp.edgeObjectsToAdd = { eo }
			P.proposal = sp
			return P
		end
		local cmd = try("replaceSegment + stop (engine template)", withStop)
		if not cmd then AUTO.results[#AUTO.results + 1] = "stop: factory refused"; return autoFinish() end
		O.sendCommand(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			local n = 0
			pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
			local line = "stop on town segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
			log("STOPS2 " .. line)
			AUTO.results[#AUTO.results + 1] = line
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
		end)
	end
	if not template then
		local cE = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		-- right on top of the target street: refused for collision, the conversion still comes back
		local q, q2 = nodePosition(cE.node0), nodePosition(cE.node1)
		local px, py, pz = q.x + 1, q.y + 1, q.z
		local pz2 = q2.z
		local n1 = api.type.NodeAndEntity.new(); n1.entity = -1
		local b1 = n1.comp; b1.position = api.type.Vec3f.new(px, py, pz); n1.comp = b1
		local n2 = api.type.NodeAndEntity.new(); n2.entity = -2
		local b2 = n2.comp; b2.position = api.type.Vec3f.new(q2.x + 1, q2.y + 1, pz2); n2.comp = b2
		local e = api.type.SegmentAndEntity.new(); e.entity = -3; e.type = 0
		local ec = e.comp
		ec.node0 = -1; ec.node1 = -2
		local tx, ty, tz = q2.x - q.x, q2.y - q.y, pz2 - pz
		ec.tangent0 = api.type.Vec3f.new(tx, ty, tz); ec.tangent1 = api.type.Vec3f.new(tx, ty, tz)
		ec.position0 = api.type.Vec3f.new(px, py, pz); ec.position1 = api.type.Vec3f.new(q2.x + 1, q2.y + 1, pz2)
		ec.type = 0; ec.typeIndex = -1
		ec.roadTemplate = cE.roadTemplate; ec.roadStyle = cE.roadStyle; ec.roadType = cE.roadType
		ec.laneConfigs = C.templateLanes(cE.roadTemplate)
		e.comp = ec
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		local modelName = (C.ROLE == "host") and "stations/street/small_stops/small_old.con" or "::/stations/street/small_stops/small_old.con"
		log("STOPS2 template probe with model " .. modelName)
		o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = false; o.model = modelName
		o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF template"
		ssp.nodesToAdd = { n1, n2 }
		ssp.edgesToAdd = { e }
		ssp.edgeObjectsToAdd = { o }
		sp.streetProposal = ssp
		local okc, cmdT = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true) end)
		log("STOPS2 template probe factory: " .. (okc and "OK" or shortErr(cmdT)))
		if not okc then return afterTemplate() end
		O.sendCommand(cmdT, function(res, success)
			local okx, errx = pcall(function()
				local list = res.proposal.proposal.edgeObjectsToAdd
				log("STOPS2 template probe: success=" .. tostring(success) .. ", converted stops " .. #list)
				if #list > 0 then
					template = list[1]
					log("STOPS2 template members: " .. mem(template))
					pcall(function() log("STOPS2 template modelId=" .. tostring(template.modelInstance.modelId) .. " category=" .. tostring(template.category)) end)
				end
			end)
			if not okx then log("STOPS2 template read failed: " .. tostring(errx)) end
			G.waits[#G.waits + 1] = { at = G.frames + 5, fn = afterTemplate }
		end)
		return
	end
	if template then
		withStop = function()
			local P = api.engine.util.proposal.replaceSegment(E)
			local sp = P.proposal
			local segs = sp.addedSegments
			local seg = segs[1]
			local c = seg.comp
			c.objects = { { -400000000, 1 } }
			seg.comp = c
			segs[1] = seg
			sp.addedSegments = segs
			local eo = template
			pcall(function() eo.resultEntity = -1 end)
			pcall(function() eo.segmentEntity = seg.entity end)
			pcall(function() eo.left = false end)
			pcall(function() eo.name = "MPF stop" end)
			pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
			pcall(function()
				local mi = eo.modelInstance
				local tr = mi.transf
				local a, b = c.position0, c.position1
				local V = api.type.Vec4f.new
				mi.transf = api.type.Mat4f.new(V(tr[1], tr[2], tr[3], tr[4]), V(tr[5], tr[6], tr[7], tr[8]), V(tr[9], tr[10], tr[11], tr[12]),
					V((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1))
				eo.modelInstance = mi
			end)
			sp.edgeObjectsToAdd = { eo }
			P.proposal = sp
			return P
		end
	end
	local cmd = try("replaceSegment + stop", withStop)
	if not cmd then AUTO.results[#AUTO.results + 1] = "stop: factory refused"; return autoFinish() end
	O.sendCommand(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		local n = 0
		pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
		local line = "stop on town segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
		log("STOPS2 " .. line)
		AUTO.results[#AUTO.results + 1] = line
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
	end)
end

H.stops2 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStops2, p)
	if not ok then
		log("STOPS2 failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops2 error " .. tostring(err)
		autoFinish()
	end
end

-- Vehicle purchase scenario: the same request the depot window sends (through the UI hook file)
local function runBuy(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local vehicles = R.entitiesWith("TRANSPORT_VEHICLE")
	local pick = nil
	for _, v in ipairs(vehicles) do
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) then pick = { v = v, tv = tv }; break end
	end
	if not pick then
		AUTO.results[#AUTO.results + 1] = "no vehicle with a depot (" .. #vehicles .. " vehicles)"
		return autoFinish()
	end
	local before = #vehicles
	local margs = { n = 3, [1] = api.engine.util.getPlayer(), [2] = pick.tv.depot, [3] = C.marshal(pick.tv.transportVehicleConfig) }
	R.translateOut("makeVehicleBuyCmd", margs, G.rev)
	C.appendFile(C.DIR .. BS .. "ui.log", C.line("act_req", { tok = "auto-" .. C.ROLE, id = 1, fn = "makeVehicleBuyCmd", args = margs }))
	log("AUTOTEST buy a copy of vehicle " .. pick.v .. " in depot " .. pick.tv.depot .. " (" .. before .. " vehicles)")
	G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
		local after = #R.entitiesWith("TRANSPORT_VEHICLE")
		local line = "purchase: vehicles " .. before .. " -> " .. after
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		autoFinish()
	end }
end

H.buy = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runBuy, p)
	if not ok then
		log("AUTOTEST buy failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "buy error " .. tostring(err)
		autoFinish()
	end
end

-- Line scenario: a new line with the stops of an existing line, then a vehicle bought and assigned to it
local function uiRequest(fn, margs)
	R.translateOut(fn, margs, G.rev)
	AUTO.reqId = (AUTO.reqId or 0) + 1
	C.appendFile(C.DIR .. BS .. "ui.log", C.line("act_req", { tok = "auto-" .. C.ROLE, id = AUTO.reqId, fn = fn, args = margs }))
end

-- Loan scenario: the player takes the first loan on offer, through the same request path as the loan window
local runLoan
runLoan = function(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local availed = nil
	if G.myCo and G.myCo ~= 1 and (G.loanFile or "") == "" and (AUTO.loanWait or 0) < 20 then
		-- (the company's loans are created by the first simulation step that sees the company)
		AUTO.loanWait = (AUTO.loanWait or 0) + 1
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function() runLoan(p) end }
		return
	end
	if G.myCo and G.myCo ~= 1 and G.loanFile and G.loanFile ~= "" then
		local view = C.deser(G.loanFile)
		availed = view and view.availableLoans and view.availableLoans[1]
	else
		local ok, tbl = pcall(function()
			local e = api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/finance/loan.gs")
			return C.marshal(api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT).state.availableLoans)
		end)
		availed = ok and tbl and tbl[1] or nil
	end
	if not availed then AUTO.results[#AUTO.results + 1] = "no loan on offer"; return autoFinish() end
	local me = api.engine.util.getPlayer()
	local before = api.engine.util.finance.getPlayersBalance(me)
	uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "", [2] = "Loan", [3] = "Obtain", [4] = { availed, availed } })
	log("AUTOTEST loan " .. C.ser(availed):sub(1, 200) .. " asked by company " .. tostring(G.myCo) .. " (balance " .. tostring(before) .. ")")
	G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
		local after = api.engine.util.finance.getPlayersBalance(me)
		local line = "loan: balance " .. tostring(before) .. " -> " .. tostring(after)
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		autoFinish()
	end }
end

-- Contract scenario: a contract offer is made to appear (the game's debug event), the player accepts the first one on offer
local runContract
runContract = function(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function sstate()
		local e = api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/subventions/subventions.gs")
		return C.marshal(api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT).state)
	end
	local function count(s) return #(s.proposedSubventions or {}) .. " offered, " .. #(s.activeSubventions or {}) .. " active, " .. #(s.completedSubventions or {}) .. " completed" end
	local s0 = sstate()
	log("AUTOTEST contract: before " .. count(s0))
	if #(s0.proposedSubventions or {}) == 0 then
		uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "", [2] = "Subvention", [3] = "_debugSpawn", [4] = {} })
	end
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
		local s1 = sstate()
		local offer = (s1.proposedSubventions or {})[1]
		log("AUTOTEST contract: after the spawn " .. count(s1) .. (offer and (", accepting " .. tostring(offer.id) .. " uid " .. tostring(offer.uid)) or ""))
		if not offer then AUTO.results[#AUTO.results + 1] = "no contract on offer"; return autoFinish() end
		uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "", [2] = "Subvention", [3] = "onAccept", [4] = { uid = offer.uid } })
		G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
			local s2 = sstate()
			local owners, mineAt = {}, nil
			for i, v in ipairs(s2.activeSubventions or {}) do
				owners[#owners + 1] = tostring(v.uid) .. "->" .. tostring(v.mpfOwner)
				if v.uid == offer.uid then mineAt = i end
			end
			local line = "contract: " .. count(s2) .. ", owners {" .. table.concat(owners, " ") .. "}"
			log("AUTOTEST " .. line)
			AUTO.results[#AUTO.results + 1] = line
			-- the contract completed at once (the game's debug event): its reward must go to this company only
			local function money()
				local t = {}
				for _, c in ipairs((G.co and G.co.list) or {}) do
					local okb, b = pcall(api.engine.util.finance.getPlayersBalance, c.ent)
					t[#t + 1] = c.id .. ":" .. tostring(okb and b)
				end
				return table.concat(t, " ")
			end
			local before = money()
			if mineAt then uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "", [2] = "Subvention", [3] = "_debugComplete", [4] = { index = mineAt } }) end
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
				-- the contract cards this game shows (notifications)
				local cards = {}
				pcall(function()
					local e = api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/notifications/notifications.gs")
					local ns = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT).state
					for id, n in pairs(ns.notifications or {}) do
						local nn = type(n) == "table" and n.notification or nil
						if type(nn) == "table" and tostring(nn.type):find("subvention", 1, true) and not n.expired then
							local p = nn.params or {}
							cards[#cards + 1] = tostring(nn.type):match("types/([%w_]+)") .. ":" .. tostring(p.uid) .. (n.dismissed and "(dismissed)" or "")
						end
					end
				end)
				table.sort(cards)
				local line2 = "contract completed: money " .. before .. " -> " .. money() .. "; cards here {" .. table.concat(cards, " ") .. "}"
				log("AUTOTEST " .. line2)
				AUTO.results[#AUTO.results + 1] = line2
				autoFinish()
			end }
		end }
	end }
end

-- Wait scenario: nothing for MPFEVER_WAIT seconds (default 60), host only: what drifts after the previous actions
H.wait = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE ~= "host" then AUTO.results = { "host only" } return autoFinish() end
	local secs = tonumber(os.getenv("MPFEVER_WAIT") or "") or 60
	G.waits[#G.waits + 1] = { at = G.frames + secs * 60, fn = function()
		AUTO.results[#AUTO.results + 1] = "waited " .. secs .. " s"
		autoFinish()
	end }
end

H.contract = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runContract, p)
	if not ok then
		log("AUTOTEST contract failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "contract error " .. tostring(err)
		autoFinish()
	end
end

H.loan = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runLoan, p)
	if not ok then
		log("AUTOTEST loan failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "loan error " .. tostring(err)
		autoFinish()
	end
end

local function runLine(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local lines = R.entitiesWith("LINE")
	if #lines == 0 then AUTO.results[#AUTO.results + 1] = "no line in the save"; return autoFinish() end
	local src = api.engine.getComponent(lines[1], api.type.ComponentType.LINE)
	local before = #lines
	local known = {}
	for _, l in ipairs(lines) do known[l] = true end
	uiRequest("makeLineCreateCmd", { n = 4, [1] = "MPF " .. C.ROLE, [2] = C.marshal(api.type.Vec3f.new(0.9, 0.2, 0.1)),
		[3] = api.engine.util.getPlayer(), [4] = C.marshal(src) })
	log("AUTOTEST line with the " .. #src.stops .. " stops of line " .. lines[1])
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
		local now = R.entitiesWith("LINE")
		local newLine = nil
		for _, l in ipairs(now) do if not known[l] then newLine = l end end
		local line = "line create: lines " .. before .. " -> " .. #now
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		-- assign a vehicle of the save to the new line (companies mode: one of this company's)
		local veh = nil
		local me = api.engine.util.getPlayer()
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			if not veh and (G.cmode ~= "separate" or R.ownerOf(v) == me) then veh = v end
		end
		if veh and newLine and #now > before then
			uiRequest("makeVehicleSetLineCmd", { n = 3, [1] = veh, [2] = newLine, [3] = 0 })
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
				local tv = api.engine.getComponent(veh, api.type.ComponentType.TRANSPORT_VEHICLE)
				local l2 = "vehicle " .. veh .. " on line " .. tostring(tv and tv.line)
				log("AUTOTEST " .. l2)
				AUTO.results[#AUTO.results + 1] = l2
				autoFinish()
			end }
		else
			autoFinish()
		end
	end }
end

-- Share scenario (companies mode): the host shares the stations of the save's first line (fee 1000 per stop); the client then
-- creates a line through them (scenario line) and pays for every stop
H.share = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE ~= "host" then
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
			local t = {}
			for k, fee in pairs((G.co and G.co.shares) or {}) do t[#t + 1] = fee end
			AUTO.results[#AUTO.results + 1] = "stations shared seen here: " .. #t
			autoFinish()
		end }
		return
	end
	local ok, err = pcall(function()
		local lines = R.entitiesWith("LINE")
		local lc = api.engine.getComponent(lines[1], api.type.ComponentType.LINE)
		local n = 0
		for i = 1, #lc.stops do
			local sg = lc.stops[i].stationGroup
			uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "share", [4] = { key = R.sgKey(sg), fee = 1000 } })
			n = n + 1
		end
		AUTO.results[#AUTO.results + 1] = "asked to share " .. n .. " station(s)"
	end)
	if not ok then AUTO.results[#AUTO.results + 1] = "share error " .. tostring(err) end
	G.waits[#G.waits + 1] = { at = G.frames + 240, fn = function()
		local t = 0
		for _ in pairs((G.co and G.co.shares) or {}) do t = t + 1 end
		AUTO.results[#AUTO.results + 1] = "stations shared now: " .. t
		autoFinish()
	end }
end

-- Fees scenario: what the shared stations earned their company so far (logged by both games); the interface tells what the window
-- of the save's first station shows (ui_mod.log, "selftest window")
H.fees = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = { "station fees earned: " .. C.ser((G.co and G.co.shareIncome) or {}) }
	AUTO.points = {}
	pcall(function()
		local lines = R.entitiesWith("LINE")
		local lc = api.engine.getComponent(lines[1], api.type.ComponentType.LINE)
		local f = C.IO.open(C.DIR .. BS .. "ui_selftest.txt", "wb")
		f:write(tostring(lc.stops[1].stationGroup))
		f:close()
	end)
	G.waits[#G.waits + 1] = { at = G.frames + 180, fn = autoFinish }
end

-- API probe (diagnostic): which native types a script can make, and their members (for trees and ground paint)
H.apiprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local names = { "ConstructionEntity", "Proposal.ConstructionEntity", "Construction", "SubConstruction", "Subconstruction", "ModelInstance",
		"ModelInstanceList", "Proposal", "ProposalTerrain", "Proposal.Terrain", "TerrainProposal", "GridVec2f", "GridFloat", "GridU8", "GridVec4f",
		"TerrainMaterialMod", "MaterialMod", "Model", "ModelInstanceProposal", "SimpleProposal.ConstructionEntity", "Asset", "AssetEntity" }
	for _, n in ipairs(names) do
		local ok, info = pcall(function()
			local t = api.type
			for part in n:gmatch("[^.]+") do t = t[part] end
			if t == nil then return "absent" end
			local okn, obj = pcall(function() return t.new() end)
			if not okn then return "type, new() fails: " .. tostring(obj):sub(1, 80) end
			local m = C.members(obj)
			local ms = {}
			if m then for i = 1, #m do ms[#ms + 1] = tostring(m[i]) end end
			return "members {" .. table.concat(ms, ",") .. "}"
		end)
		local line = n .. ": " .. (ok and tostring(info) or ("error " .. tostring(info):sub(1, 80)))
		log("APIPROBE " .. line)
		AUTO.results[#AUTO.results + 1] = line
	end
	-- the terrain part of a native proposal
	pcall(function()
		local P = api.type.Proposal.new()
		local m = C.members(P.terrain)
		local ms = {}
		if m then for i = 1, #m do ms[#ms + 1] = tostring(m[i]) end end
		local line = "Proposal.terrain members {" .. table.concat(ms, ",") .. "}"
		log("APIPROBE " .. line)
		AUTO.results[#AUTO.results + 1] = line
		local ce = C.members(P.toAdd)
		log("APIPROBE Proposal.toAdd: " .. tostring(P.toAdd) .. " " .. tostring(#P.toAdd))
	end)
	autoFinish()
end

-- Tree probe (diagnostic): what the constructions without a file (assets: trees, rocks placed with the brush) look like
H.treeprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE ~= "host" then AUTO.results = { "host only" } return autoFinish() end
	local blank, files = {}, {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		local f = c and tostring(c.fileName) or "?"
		files[f] = (files[f] or 0) + 1
		if f == "" then blank[#blank + 1] = e end
	end
	local t = {}
	for f, n in pairs(files) do if n > 3 or f == "" then t[#t + 1] = f .. "=" .. n end end
	table.sort(t)
	log("TREEPROBE constructions by file: " .. table.concat(t, " "):sub(1, 1500))
	AUTO.results[#AUTO.results + 1] = "constructions without file: " .. #blank
	if blank[1] then
		local e = blank[1]
		pcall(function()
			C.appendFile(C.DIR .. BS .. "treeprobe.txt", "==== CONSTRUCTION " .. e .. NL .. C.dump(api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)):sub(1, 20000) .. NL)
			C.appendFile(C.DIR .. BS .. "treeprobe.txt", "==== MODEL_INSTANCE_LIST " .. e .. NL .. C.dump(api.engine.getComponent(e, api.type.ComponentType.MODEL_INSTANCE_LIST)):sub(1, 8000) .. NL)
			for _, n in ipairs({ "PLAYER_OWNED", "TOWN_BUILDING", "NAME", "BOUNDING_VOLUME", "COLLIDER", "PARCEL" }) do
				local okc, cc = pcall(function() return api.engine.getComponent(e, api.type.ComponentType[n]) end)
				if okc and cc then C.appendFile(C.DIR .. BS .. "treeprobe.txt", "==== " .. n .. NL .. C.dump(cc):sub(1, 2000) .. NL) end
			end
		end)
	end
	-- the models a brush offers (trees)
	pcall(function()
		local list = {}
		api.res.modelRep.forEachModelWithMetadata("tree", function(resName) if #list < 5 then list[#list + 1] = resName end end)
		log("TREEPROBE tree models: " .. table.concat(list, ", "))
		AUTO.results[#AUTO.results + 1] = "tree models: " .. table.concat(list, ", ")
	end)
	pcall(function()
		local ce = api.type.Proposal.ConstructionEntity.new()
		C.appendFile(C.DIR .. BS .. "treeprobe.txt", "==== new Proposal.ConstructionEntity" .. NL .. C.dump(ce):sub(1, 6000) .. NL)
		local con = api.type.Construction.new()
		C.appendFile(C.DIR .. BS .. "treeprobe.txt", "==== new Construction" .. NL .. C.dump(con):sub(1, 6000) .. NL)
	end)
	autoFinish()
end

-- Asset scenario: trees placed (1) as the brush makes them (a construction without a file, its models inline), when a script can
-- make that, and (2) with the mod's own construction; the other game must end with the same trees
local function assetCount()
	local n = 0
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		if c and R.isAssetFile(c.fileName) then n = n + 1 end
	end
	return n
end

H.assettest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST assets " .. t) AUTO.results[#AUTO.results + 1] = t end
	-- (the client builds: the game log of the game started last is the one kept)
	if C.ROLE ~= "client" then
		G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function() say("asset constructions here: " .. assetCount()) autoFinish() end }
		return
	end
	local model = nil
	pcall(function() api.res.modelRep.forEachModelWithMetadata("tree", function(resName) if not model and resName:find("trees", 1, true) then model = resName end end) end)
	pcall(function() if not model then api.res.modelRep.forEachModelWithMetadata("tree", function(resName) model = model or resName end) end end)
	say("model " .. tostring(model) .. ", con " .. tostring(assetConName()) .. ", asset constructions before " .. assetCount())
	local ends = deadEnds()
	local q = nodePosition(ends[((p.offset or 0) * 13 + 5) % #ends + 1])
	local function tf(dx, dy)
		local x, y = q.x + dx, q.y + dy
		return api.type.Mat4f.new(api.type.Vec4f.new(1, 0, 0, 0), api.type.Vec4f.new(0, 1, 0, 0), api.type.Vec4f.new(0, 0, 1, 0), api.type.Vec4f.new(x, y, groundZ(x, y, q.z), 1))
	end
	-- (1) the brush's kind of construction
	local okN, errN = pcall(function()
		local P = api.type.Proposal.new()
		local ce = api.type.Proposal.ConstructionEntity.new()
		ce.fileName = ""
		ce.transf = tf(25, 25)
		ce.playerEntity = api.engine.util.getPlayer()
		local con = ce.construction
		local subs = con.subconstructions
		say("native construction: subconstructions " .. tostring(subs) .. " (" .. tostring(#subs) .. ")")
		pcall(function() say("native construction: subconstruction members " .. C.ser(C.members(subs[1]) or {})) end)
	end)
	if not okN then say("native construction: " .. shortErr(errN)) end
	-- (2) the mod's construction, as another game rebuilds a brush stroke
	local okM, errM = pcall(function()
		local sp = api.type.SimpleProposal.new()
		local cons = {}
		for k = 1, 3 do
			local ce = api.type.SimpleProposal.ConstructionEntity.new()
			ce.fileName = assetConName()
			ce.params = { mpfModels = { { id = model, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } }, { id = model, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 4, 3, 0, 1 } } }, seed = 1 }
			ce.transf = tf(20 + 9 * k, -20)
			ce.playerEntity = api.engine.util.getPlayer()
			pcall(function() ce.name = "" end)
			cons[k] = ce
		end
		sp.constructionsToAdd = cons
		local ctx = playerContext()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, os.getenv("MPFEVER_ASSETIE") == "1", true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			say("mod construction: " .. (success and "BUILT" or ("refused " .. why)) .. ", result entities " .. C.ser(C.marshal(res.resultEntities)):sub(1, 200) .. ", now " .. assetCount())
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
				pcall(function()
					for i = 1, #res.resultEntities do
						local e = res.resultEntities[i]
						if type(e) ~= "number" then e = e[1] end
						local have = {}
						for _, n in ipairs({ "CONSTRUCTION", "MODEL_INSTANCE_LIST", "PLAYER_OWNED", "NAME", "SUBCONSTRUCTION", "TOWN_BUILDING", "BOUNDING_VOLUME", "TRANSFORM" }) do
							local okc, cc = pcall(function() return api.engine.getComponent(e, api.type.ComponentType[n]) end)
							if okc and cc then have[#have + 1] = n end
						end
						local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
						say("entity " .. tostring(e) .. " exists " .. tostring(api.engine.entityExists(e)) .. " {" .. table.concat(have, ",") .. "} file " .. tostring(okc and c and c.fileName))
					end
				end)
			end }
			G.waits[#G.waits + 1] = { at = G.frames + 240, fn = function()
				local names = {}
				for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
					local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
					if c and tostring(c.fileName):find("mpf", 1, true) then names[#names + 1] = tostring(c.fileName) end
				end
				say("asset constructions here: " .. assetCount() .. " {" .. table.concat(names, ","):sub(1, 200) .. "}")
				autoFinish()
			end }
		end)
	end)
	if not okM then say("mod construction: " .. shortErr(errM)) autoFinish() end
end

H.line = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runLine, p)
	if not ok then
		log("AUTOTEST line failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "line error " .. tostring(err)
		autoFinish()
	end
end

-- Commands scenario: the player commands that no other scenario exercises (names, stopping and reversing a vehicle,
-- sending it to a depot, changing a line's waiting times, selling), sent as the interface would; the checkpoint hash
-- (names, vehicle state, lines) then says whether every game ended up the same.
local function runCmds(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local lines = R.entitiesWith("LINE")
	local vehs = R.entitiesWith("TRANSPORT_VEHICLE")
	if #lines == 0 or #vehs < 2 then AUTO.results[#AUTO.results + 1] = "needs a line and two vehicles"; return autoFinish() end
	local line = lines[1]
	local v1 = vehs[((p.offset or 0) % #vehs) + 1]
	local v2 = vehs[((p.offset or 0) + 1) % #vehs + 1]
	local role = C.ROLE
	local steps = {
		{ "rename the line", function() uiRequest("makeEntitySetNameCmd", { n = 2, [1] = line, [2] = "MPF line " .. role }) end },
		{ "rename a vehicle", function() uiRequest("makeEntitySetNameCmd", { n = 2, [1] = v1, [2] = "MPF vehicle " .. role }) end },
		{ "line colour", function() uiRequest("makeEntitySetColorCmd", { n = 2, [1] = line, [2] = C.marshal(api.type.Vec3f.new(0.2, 0.8, role == "host" and 0.1 or 0.9)) }) end },
		{ "stop a vehicle", function() uiRequest("makeVehicleSetStoppedByUserCmd", { n = 2, [1] = v1, [2] = true }) end },
		{ "restart it", function() uiRequest("makeVehicleSetStoppedByUserCmd", { n = 2, [1] = v1, [2] = false }) end },
		{ "reverse a vehicle", function() uiRequest("makeVehicleReverseCmd", { n = 1, [1] = v2 }) end },
		{ "line waiting times", function()
			local lc = C.marshal(api.engine.getComponent(line, api.type.ComponentType.LINE))
			lc.stops[1].minWaitingTime = (role == "host") and 21 or 33
			lc.stops[1].maxWaitingTime = 60
			uiRequest("makeLineUpdateCmd", { n = 2, [1] = line, [2] = lc })
		end },
		{ "send a vehicle to the depot", function() uiRequest("makeVehicleSendToDepotCmd", { n = 2, [1] = v2, [2] = false }) end },
	}
	local i = 0
	local function nextStep()
		i = i + 1
		local st = steps[i]
		if not st then
			AUTO.results[#AUTO.results + 1] = "all commands sent"
			return autoFinish()
		end
		local ok, err = pcall(st[2])
		local line1 = st[1] .. ": " .. (ok and "sent" or ("error " .. tostring(err)))
		log("AUTOTEST cmds " .. line1)
		AUTO.results[#AUTO.results + 1] = line1
		G.waits[#G.waits + 1] = { at = G.frames + 240, fn = nextStep }
	end
	nextStep()
end

-- Command latency scenario: how many interface frames the engine takes to answer a command, the game running or paused
H.cmdlat = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local line = R.entitiesWith("LINE")[1]
	local k = 0
	local function one()
		k = k + 1
		if k > 6 then return autoFinish() end
		local f0 = G.frames
		local t0 = gameTime()
		local cmd = api.cmd.makeEntitySetNameCmd(line, "MPF lat " .. C.ROLE .. k)
		O.sendCommand(cmd, function(res, success)
			local msg = "cmd latency " .. (G.frames - f0) .. " frames, game speed " .. tostring(gameSpeed()) .. ", game time moved " .. (gameTime() - t0)
			log("AUTOTEST " .. msg)
			AUTO.results[#AUTO.results + 1] = msg
			G.waits[#G.waits + 1] = { at = G.frames + 60, fn = one }
		end)
	end
	one()
end

H.cmds = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runCmds, p)
	if not ok then
		log("AUTOTEST cmds failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "cmds error " .. tostring(err)
		autoFinish()
	end
end

-- Stop on a town street: the engine converts our simple proposal (refused for the parcels), we fix the converted
-- proposal (old/new segment maps, as the native stop tool sets them) and send it again
local function runStops3(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local E = list[((p.offset or 0) * 31 + 67) % #list + 1]
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = 0
	local cc = e.comp
	cc.node0 = c.node0; cc.node1 = c.node1
	cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
	cc.type = 0; cc.typeIndex = -1
	cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
	cc.laneConfigs = C.templateLanes(c.roadTemplate)
	e.comp = cc
	local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
	local o = api.type.SimpleStreetProposal.EdgeObject.new()
	o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = false
	o.model = "stations/street/small_stops/small_old.con"
	o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF stop"
	ssp.edgesToRemove = { E }
	ssp.edgesToAdd = { e }
	ssp.edgeObjectsToAdd = { o }
	sp.streetProposal = ssp
	log("STOPS3 step 1: simple proposal on town segment " .. E)
	local ctx = playerContext()
	O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("STOPS3 step 1 result: " .. (success and "BUILT" or ("refused " .. why)))
		if success then AUTO.results[#AUTO.results + 1] = "stop built directly"; return autoFinish() end
		local okp, errp = pcall(function()
			local P2 = res.proposal
			local st = P2.proposal
			local eo = st.edgeObjectsToAdd
			local segs = st.addedSegments
			log("STOPS3 converted: added " .. #segs .. " removed " .. #st.removedSegments .. " stops " .. #eo
				.. " seg id " .. tostring(segs[1] and segs[1].entity) .. " objects " .. C.ser(C.marshal(segs[1] and segs[1].comp.objects)))
			local newId = segs[1].entity
			local seg = segs[1]
			local sc = seg.comp
			sc.objects = { { -400000000, 1 } }
			seg.comp = sc
			segs[1] = seg
			st.addedSegments = segs
			pcall(function() log("STOPS3 stop object: left=" .. tostring(eo[1].left) .. " segment=" .. tostring(eo[1].segmentEntity) .. " category=" .. tostring(eo[1].category)) end)
			-- attempts A: the converted proposal itself, repaired (positions always; maps / stop reference optional)
			local pa, pb = nodePosition(c.node0), nodePosition(c.node1)
			local base = C.ser(1)
			local function variantA(withMaps, withObj)
				local PA = res.proposal
				local stA = PA.proposal
				local segsA = stA.addedSegments
				local sA = segsA[1]
				local cA = sA.comp
				cA.position0 = vec(pa)
				cA.position1 = vec(pb)
				if withObj then cA.objects = { { -400000000, 1 } } end
				sA.comp = cA
				segsA[1] = sA
				stA.addedSegments = segsA
				if withMaps then
					stA.new2oldSegments = { [sA.entity] = { E } }
					stA.old2newSegments = { [E] = { sA.entity } }
				end
				PA.proposal = stA
				return PA
			end
			local tries = {}
			local chosen = nil
			for _, t in ipairs(tries) do
				local okf, cmdA = pcall(function() return api.cmd.makeWorldBuildProposalCmd(variantA(t[2], t[3]), playerContext(), false, true) end)
				log("STOPS3 attempt A " .. t[1] .. ": factory " .. (okf and "OK" or shortErr(cmdA)))
				if okf and cmdA and not chosen then chosen = { name = t[1], cmd = cmdA } end
			end
			if chosen then
				O.sendCommand(chosen.cmd, function(resA, successA)
					local whyA = ""
					if not successA then pcall(function() whyA = C.ser(C.marshal(resA.resultProposalData.errorState.messages)) end) end
					local nA = 0
					pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do nA = nA + 1 end end)
					log("STOPS3 attempt A '" .. chosen.name .. "': " .. (successA and "BUILT" or ("refused " .. whyA)) .. ", edge objects " .. nA)
					AUTO.results[#AUTO.results + 1] = "A " .. chosen.name .. ": " .. (successA and "BUILT" or ("refused " .. whyA))
				end)
			end
			-- attempt B: graft the converted stop object onto the engine's own replacement of the segment
			local P3 = api.engine.util.proposal.replaceSegment(E)
			local st3 = P3.proposal
			local segs3 = st3.addedSegments
			local seg3 = segs3[1]
			local c3 = seg3.comp
			c3.objects = { { -400000000, 1 } }
			seg3.comp = c3
			segs3[1] = seg3
			st3.addedSegments = segs3
			local obj = eo[1]
			obj.segmentEntity = seg3.entity
			st3.edgeObjectsToAdd = { obj }
			st3.new2oldSegments = { [seg3.entity] = { E } }
			st3.old2newSegments = { [E] = { seg3.entity } }
			log("STOPS3 node configs: converted +" .. #st.nodeConfigsToAdd .. " -" .. #st.nodeConfigsToRemove
				.. ", engine replacement +" .. #st3.nodeConfigsToAdd .. " -" .. #st3.nodeConfigsToRemove
				.. "; converted toAdd " .. #P2.toAdd .. ", segmentTags " .. tostring(#P2.segmentTags))
			if #st.nodeConfigsToAdd > 0 then
				st3.nodeConfigsToAdd = st.nodeConfigsToAdd
				st3.nodeConfigsToRemove = st.nodeConfigsToRemove
			end
			P3.proposal = st3
			log("STOPS3 grafted: segment id " .. tostring(seg3.entity) .. ", stops " .. #P3.proposal.edgeObjectsToAdd)
			P2 = P3
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(P2, playerContext(), false, true), function(res2, success2)
				local why2 = ""
				if not success2 then
					pcall(function() why2 = C.ser(C.marshal(res2.resultProposalData.errorState)) end)
					pcall(function() why2 = why2 .. " collisions " .. C.ser(C.marshal(res2.resultProposalData.collisionInfo)):sub(1, 300) end)
				end
				local n = 0
				pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
				local line = "stop via converted proposal on town segment " .. E .. ": " .. (success2 and "BUILT" or ("refused " .. why2)) .. ", edge objects now " .. n
				log("STOPS3 " .. line)
				AUTO.results[#AUTO.results + 1] = line
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end)
		end)
		if not okp then
			log("STOPS3 converted proposal failed: " .. tostring(errp))
			AUTO.results[#AUTO.results + 1] = "converted proposal error " .. tostring(errp)
			autoFinish()
		end
	end)
end

H.stops3 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStops3, p)
	if not ok then
		log("STOPS3 failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops3 error " .. tostring(err)
		autoFinish()
	end
end

-- Split scenario: a branch joining the middle of an existing segment (the most common road build)
local function runSplit(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and #c.objects == 0 then
			local a, b = nodePosition(c.node0), nodePosition(c.node1)
			if a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 60 then list[#list + 1] = e end
		end
	end
	local E = list[((p.offset or 0) * 31 + 11) % #list + 1]
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local A, B = nodePosition(c.node0), nodePosition(c.node1)
	local M = { x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2 }
	local dx, dy = B.x - A.x, B.y - A.y
	local len = math.sqrt(dx * dx + dy * dy)
	local P = { x = M.x - dy / len * 40, y = M.y + dx / len * 40 }
	P.z = groundZ(P.x, P.y, M.z)
	local lanes = C.templateLanes(c.roadTemplate)
	if p.lanesFrom == "segment" then lanes = c.laneConfigs end
	local function seg(id, n0, n1, p0, p1, owner)
		local e = api.type.SegmentAndEntity.new()
		e.entity = id
		e.type = 0
		local cc = e.comp
		cc.node0 = n0; cc.node1 = n1
		local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z }
		cc.tangent0 = vec(t); cc.tangent1 = vec(t)
		cc.position0 = vec(p0); cc.position1 = vec(p1)
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		cc.laneConfigs = lanes
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		if owner then local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po end
		return e
	end
	local function node(id, q)
		local n = api.type.NodeAndEntity.new()
		n.entity = id
		local bn = n.comp; bn.position = vec(q); n.comp = bn
		return n
	end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	ssp.nodesToAdd = { node(-1, M), node(-2, P) }
	ssp.edgesToAdd = { seg(-3, c.node0, -1, A, M, false), seg(-4, -1, c.node1, M, B, false), seg(-5, -1, -2, M, P, true) }
	ssp.edgesToRemove = { E }
	-- lane connections of the nodes touching the removed segment refer to it: remove those node configurations
	local ncr = {}
	for _, n in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = n end
	end
	if p.nodeConfigs then ssp.nodeConfigsToRemove = ncr end
	log("SPLIT node configs on the segment's nodes: " .. #ncr .. (p.nodeConfigs and " (removed)" or " (kept)"))
	sp.streetProposal = ssp
	log("SPLIT segment " .. E .. " (" .. tostring(c.roadTemplate) .. "), lanes from " .. tostring(p.lanesFrom or "template")
		.. ": template " .. tostring(#(C.templateLanes(c.roadTemplate) or {})) .. " lanes, segment " .. #c.laneConfigs .. " lanes")
	pcall(function()
		local function d(l) local t = {} for i = 1, #l do t[#t + 1] = string.format("%.1f/%s/%.2f", l[i].width, tostring(l[i].forward), l[i].offset) end return table.concat(t, " ") end
		log("SPLIT lanes template: " .. d(C.templateLanes(c.roadTemplate)) .. " | segment: " .. d(c.laneConfigs))
	end)
	local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true) end)
	log("SPLIT factory: " .. (okf and "OK" or shortErr(cmd)))
	AUTO.results[#AUTO.results + 1] = "split factory " .. (okf and "OK" or shortErr(cmd))
	if not okf then return autoFinish() end
	O.sendCommand(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("SPLIT build: " .. (success and "BUILT" or ("refused " .. why)))
		AUTO.results[#AUTO.results + 1] = "split build " .. (success and "BUILT" or ("refused " .. why))
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
	end)
end

H.split = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.nodeConfigs = true
	local ok, err = pcall(runSplit, p)
	if not ok then
		log("SPLIT failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "split error " .. tostring(err)
		autoFinish()
	end
end

-- Road types scenario: every street/track template the game has, applied with the engine's own upgrade proposal (the
-- tools' native path: captured here, replayed by the other game); the edge hash (template, style, type, decorations)
-- then shows what a replay loses.
local function allTemplateNames()
	local names = {}
	local rep = api.res.streetTemplateRep
	local ok, list = pcall(function() return rep.getAll() end)
	if ok and type(list) == "table" then
		for _, n in pairs(list) do names[#names + 1] = n end
	else
		log("AUTOTEST roadtypes: getAll failed: " .. tostring(list))
		for i = 0, 400 do
			local okg, t = pcall(function() return rep.get(i) end)
			if not okg or t == nil then break end
			local okn, nm = pcall(function() return rep.getName(i) end)
			if okn and nm then names[#names + 1] = nm end
		end
	end
	table.sort(names)
	return names
end

local function runRoadTypes(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local names = allTemplateNames()
	log("AUTOTEST roadtypes (" .. C.ROLE .. "): " .. #names .. " templates: " .. table.concat(names, ", "))
	local streets, tracks = {}, {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.roadTemplate and c.roadTemplate ~= "" and #c.objects == 0 and not c.roadTemplate:find("entrance", 1, true) then
			local list = (c.type == 0) and streets or tracks
			list[#list + 1] = { e = e, c = c }
		end
	end
	log("AUTOTEST roadtypes: " .. #streets .. " plain street segments, " .. #tracks .. " plain track segments")
	local queue = {}
	for _, t in ipairs(names) do
		-- (highway_new_small_*: the engine itself hangs applying it as an upgrade of a country road, with or without MPFever)
		if not t:find("entrance", 1, true) and not t:find("constructions", 1, true) and not t:find("highway_new_small", 1, true) then queue[#queue + 1] = t end
	end
	-- MPFEVER_TOWN=1: town streets widened to the largest town templates (the upgrade moves buildings of the town)
	if os.getenv("MPFEVER_TOWN") then
		local town = {}
		for _, e in ipairs(streets) do if e.c.roadTemplate:find("/town/", 1, true) then town[#town + 1] = e end end
		streets = town
		queue = {}
		for _, t in ipairs(names) do
			if t:find("/town/town_new_large", 1, true) and not t:find("tram", 1, true) and not t:find("bus", 1, true) then queue[#queue + 1] = t end
		end
		for _, t in ipairs(names) do
			if t:find("/town/town_new_medium", 1, true) and not t:find("tram", 1, true) then queue[#queue + 1] = t end
		end
		log("AUTOTEST roadtypes (town mode): " .. #streets .. " town segments, templates " .. table.concat(queue, ", "))
	end
	local first = (p.offset or 0) + 1
	local done, step = 0, 0
	local limit = tonumber(os.getenv("MPFEVER_ROADTYPES") or "") or 10
	local used = {}
	local function nextOne()
		step = step + 1
		local stride = os.getenv("MPFEVER_TOWN") and 1 or 3
		local t = queue[((first - 1) + (step - 1) * stride) % math.max(1, #queue) + 1]
		if done >= limit or step > #queue + 4 + (os.getenv("MPFEVER_TOWN") and 20 or 0) or not t then return autoFinish() end
		local isTrack = t:find("track", 1, true) ~= nil
		local pool = isTrack and tracks or streets
		local pick = nil
		for k = 1, #pool do
			local cand = pool[((p.offset or 0) * 31 + step * 53 + k * 7) % #pool + 1]
			if cand.c.roadTemplate ~= t and not used[cand.e] then pick = cand; break end
		end
		if not pick then
			AUTO.results[#AUTO.results + 1] = t:match("[^/]+$") .. ": no candidate segment"
			return nextOne()
		end
		used[pick.e] = true
		local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(pick.e, t) end)
		if not okp or not P then
			local line = t:match("[^/]+$") .. ": replaceSegment failed (" .. shortErr(P) .. ")"
			log("AUTOTEST roadtypes " .. line)
			AUTO.results[#AUTO.results + 1] = line
			return nextOne()
		end
		local a = nodePosition(pick.c.node0)
		local okc, errc = pcall(function()
			local ctx = playerContext()
			if os.getenv("MPFEVER_TOOLCTX") then
				-- the flags of the game's own tools (what a replay of an upgrade uses)
				ctx.checkTerrainAlignment = true
				ctx.cleanupStreetGraph = true
				ctx.gatherBuildings = true
			end
			deferredSend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				local line = t:match("[^/]+$") .. " on " .. tostring(pick.c.roadTemplate):match("[^/]+$") .. ": " .. (success and "built" or ("refused " .. why))
				log("AUTOTEST roadtypes " .. line .. " [frame " .. G.frames .. "]")
				AUTO.results[#AUTO.results + 1] = line
				if success then done = done + 1; AUTO.points[#AUTO.points + 1] = a end
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = nextOne }
			end)
		end)
		if not okc then
			log("AUTOTEST roadtypes command failed: " .. shortErr(errc))
			nextOne()
		end
	end
	nextOne()
end

H.roadtypes = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runRoadTypes, p)
	if not ok then
		log("AUTOTEST roadtypes failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "roadtypes error " .. tostring(err)
		autoFinish()
	end
end

H.upgrade = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runUpgrade, p)
	if not ok then
		log("AUTOTEST upgrade failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "upgrade error " .. tostring(err)
		autoFinish()
	end
end

H.autotest_done = function(from, p)
	G.autoPoints = G.autoPoints or {}
	for _, q in ipairs(p.points or {}) do G.autoPoints[#G.autoPoints + 1] = q end
end

H.autotest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runScenario, p)
	if not ok then
		log("AUTOTEST failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "scenario error " .. tostring(err)
		autoFinish()
	end
end

-- what this game has around the test points: edges (rounded end positions, template) and stops
-- autotest: one game moves its camera around the map (does the camera change the simulation?)
H.camtour = function(from, p)
	if p.role ~= C.ROLE then return end
	local cam = api.gui and api.gui.camera
	if not cam then log("camtour: no api.gui.camera"); return end
	local okc, data = pcall(cam.getCameraData)
	log("camtour: camera " .. (okc and C.dump(data):sub(1, 300) or tostring(data)))
	if not okc then return end
	local spots = {}
	pcall(function()
		local edges = R.allEdges()
		for k = 1, #edges, math.max(1, math.floor(#edges / 12)) do
			local c = api.engine.getComponent(edges[k], api.type.ComponentType.BASE_EDGE)
			local q = c and nodePosition(c.node0)
			if q then spots[#spots + 1] = q end
		end
	end)
	local i = 0
	local function hop()
		i = i + 1
		local q = spots[(i % math.max(1, #spots)) + 1]
		if q then
			local ok, err = pcall(function()
				local d = cam.getCameraData()
				if d.x ~= nil then d.x, d.y = q.x, q.y else d[1], d[2] = q.x, q.y end
				cam.setCameraData(d)
			end)
			if i <= 2 then log("camtour: hop " .. i .. " -> " .. (ok and "ok" or tostring(err))) end
		end
		if i < 400 then G.waits[#G.waits + 1] = { at = G.frames + 90, fn = hop } end
	end
	hop()
end

H.area_dump = function(from, p)
	local lines = {}
	local function near(q)
		for _, c in ipairs(G.autoPoints or {}) do
			local dx, dy = q.x - c.x, q.y - c.y
			if dx * dx + dy * dy < 400 * 400 then return true end
		end
		return false
	end
	local function r(v) return string.format("%.0f", v) end
	for _, e in ipairs(R.allEdges()) do repeat
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if not c then break end
		local a, b = nodePosition(c.node0), nodePosition(c.node1)
		if a and b and (near(a) or near(b)) then
			local s1, s2 = r(a.x) .. "," .. r(a.y), r(b.x) .. "," .. r(b.y)
			if s1 > s2 then s1, s2 = s2, s1 end
			local objs = {}
			for i = 1, #c.objects do
				local eo = api.engine.getComponent(c.objects[i][1], api.type.ComponentType.EDGE_OBJECT)
				objs[#objs + 1] = (eo and tostring(eo.edgeObjectConstruction) or "?") .. "@" .. (eo and string.format("%.2f", eo.param) or "?")
			end
			lines[#lines + 1] = "edge " .. s1 .. " - " .. s2 .. " " .. tostring(c.roadTemplate) .. (#objs > 0 and (" objects " .. table.concat(objs, ";")) or "")
		end
	until true end
	-- every node configuration (lane connections, crosswalks, traffic lights), as the checkpoint hash sees it
	pcall(function()
		for _, n in ipairs(R.allNodes()) do
			local okc, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			local q = okc and nc and nodePosition(n)
			if q then
				lines[#lines + 1] = string.format("nodecfg %.0f,%.0f lc=%d cw=%d pref=%s", q.x, q.y, #nc.laneConnections, #nc.crosswalks, tostring(nc.trafficLightPreference))
			end
		end
	end)
	-- every construction (file and rounded position, as the checkpoint hash sees it): what a moved building changes
	pcall(function()
		for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
			local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
			local m = c and c.transf
			if m then
				local pp = R.matPos and R.matPos(m)
				lines[#lines + 1] = string.format("con %s %.1f,%.1f", tostring(c.fileName), pp and pp.x or 0, pp and pp.y or 0)
			end
		end
	end)
	table.sort(lines)
	local f = C.IO.open(C.DIR .. BS .. "area.txt", "wb")
	if f then
		f:write("t=" .. gameTime() .. NL .. table.concat(lines, NL) .. NL)
		f:close()
	end
	send("area_done", { n = #lines })
end

local function neutraliseEmissions()
	-- town pollution/noise and traffic come from engine computations made in parallel (not the same on every game): their effect
	-- on the growth of the towns is removed
	local n = 0
	api.engine.forEachEntityWithComponent(function(town)
		n = n + 1
		for _, rating in ipairs({ "pollution", "noise", "traffic_congestion" }) do
			O.sendCommand(O.event("", "Towns", "setTownRatingSensitivity", { townEntity = town, rating = rating, sensitivity = 0 }))
		end
	end, api.type.ComponentType.TOWN)
	log("pollution, noise and traffic sensitivity set to 0 for " .. n .. " towns")
end

local function fileSize(name)
	local f = C.IO.open(C.DIR .. BS .. name, "rb")
	if not f then return 0 end
	local n = f:seek("end")
	f:close()
	return n or 0
end

-- This GUI half starts with the game, and again after a resynchronisation (the host's savegame loaded here): what the
-- files already hold belongs to the previous game state, and the savegame's script state holds the host's records.
local function resumeAfterLoad(state)
	-- records of the savegame's script state (an earlier session, or the host's): never shipped or reported again
	local st = state:get() or {}
	for _, o in ipairs(st.out or {}) do if o.n > G.outSent then G.outSent = o.n end end
	-- (keyed by uid and game time: uids start again at 1 in every session, an old record must not hide a new one)
	for _, r in ipairs(st.results or {}) do G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true end
	if type(st.hash) == "table" then G.hashSent = st.hash.n end
	-- first start of this game in the session: everything the launcher wrote so far is for it
	if fileSize("started.txt") == 0 then
		C.appendFile(C.DIR .. BS .. "started.txt", "1")
		return
	end
	G.inOff = fileSize("in.log")
	-- A resynchronisation: what the launcher wrote after its order to load (resync_load) is for the game loaded now, although it
	-- arrived while the game was loading (the companies other players announce, their first actions...): read from there.
	pcall(function()
		local f = C.IO.open(C.DIR .. BS .. "in.log", "rb")
		if not f then return end
		local s = f:read("*a") or ""
		f:close()
		local last, pos = nil, 1
		while true do
			local i = s:find("resync_load" .. TAB, pos, true)
			if not i then break end
			if i == 1 or s:sub(i - 1, i - 1) == NL then
				local e = s:find(NL, i, true)
				if e then last = e end
			end
			pos = i + 1
		end
		if last and last < #s then
			log("resynchronisation: " .. (#s - last) .. " bytes of messages received during the load are read")
			G.inOff = last
		end
	end)
	-- commands the UI hook held before the reload were already shipped and applied: never again
	G.uiOff = fileSize("ui.log")
	G.natOff = fileSize("native_events.log")
	local f = C.IO.open(C.DIR .. BS .. "native_ctl.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		-- the DLL keeps counting releases across loads
		for n in s:gmatch("release (%d+)") do
			n = tonumber(n)
			if n and n > G.natReleased then G.natReleased = n end
		end
	end
	-- entity bindings of a previous game state are void
	C.appendFile(C.DIR .. BS .. "bindings.log", "RESET 0" .. NL)
	if G.inOff > 0 then log("started over an existing session (" .. G.inOff .. " bytes of messages skipped): resynchronised game") end
end

-- ================================================================== companies (GUI half)
-- A player is known by its name (what it types in the menu); the relay adds "#n" to the names of the players who join, which
-- changes at every connection, so the key is the name without it.
local function coMyName()
	local n = tostring(G.me or C.NAME or "player"):gsub("#.*$", "")
	return n
end

-- this player's Steam account (steam_id.txt, written by the native module once Steam is up), nil while unknown
local function coMySid()
	if G.mySid == nil and G.frames - (G.sidTried or -1000) > 120 then
		G.sidTried = G.frames
		pcall(function()
			local f = C.IO.open(C.DIR .. BS .. "steam_id.txt", "rb")
			if f then G.mySid = (f:read("*a") or ""):match("%d+"); f:close() end
		end)
	end
	return G.mySid
end

-- The level of a company (rank, experience, permits) lives in a game script that only follows the savegame's company. The interface
-- reads it for the player it acts as: another company would find nothing (rank 0, most things locked). They share the savegame
-- company's progression: the reader maps any company of the registry to it.
local function coReq(name)
	for _, path in ipairs({ "/game_mechanics/company/" .. name, "::/game_mechanics/company/" .. name }) do
		local ok, m = pcall(ug_require, path)
		if ok and type(m) == "table" then return m end
	end
	return nil
end

local function coPatchProgression()
	if G.progPatched then return end
	G.progPatched = true
	local okP = CO.patchProgression(coReq, function(entity)
		if R.coIdOf and R.coIdOf(entity) and R.CO and R.CO.canon then return R.CO.canon end
		return nil
	end, log)
	if not okP then log("companies: the progression module is not reachable from here (rank of other companies stays empty)") end
	if not CO.patchPermits(coReq, log) then log("companies: the permit modules are not reachable from here (unique buildings stay shared)") end
end

local coCtlSeq = 0
local function coGui(st)
	if G.cmode ~= "separate" then return end
	R.CO = st.co
	if not G.gpWrapped then
		G.gpWrapped = true
		local real = api.engine.util.getPlayer
		api.engine.util.getPlayer = function() if G.actor then return G.actor end return real() end
		pcall(coPatchProgression)
	end
	-- the interface's own Lua state (tools, windows) maps player entities to company numbers through this file
	if st.co then
		local lines = { "me	" .. tostring(G.myCo or 0) }
		for _, c in ipairs(st.co.list) do if c.ent then lines[#lines + 1] = c.id .. "	" .. c.ent .. "	" .. tostring(c.name or ""):gsub("[%c]", " ") end end
		local txt = table.concat(lines, NL) .. NL
		if txt ~= G.coFile then
			G.coFile = txt
			local f = C.IO.open(C.DIR .. BS .. "companies.txt", "wb")
			if f then f:write(txt); f:close() end
		end
	end
	-- the stations the companies share (the interface shows them in the station windows)
	do
		local t = {}
		for k, fee in pairs((st.co and st.co.shares) or {}) do t[#t + 1] = tostring(k):gsub("[%c]", " ") .. "\t" .. tostring(fee) end
		table.sort(t)
		local txt = table.concat(t, NL)
		if txt ~= G.shareFile then
			G.shareFile = txt
			local f = C.IO.open(C.DIR .. BS .. "shares.txt", "wb")
			if f then f:write(txt); f:close() end
		end
	end
	-- the loans of this player's company when it is not the savegame's one (the game's loan window shows what this file says)
	do
		local lt = (G.myCo and G.myCo ~= 1 and st.co and st.co.loan) and st.co.loan[G.myCo] or nil
		local txt = lt and C.ser(lt) or ""
		if txt ~= G.loanFile then
			G.loanFile = txt
			local f = C.IO.open(C.DIR .. BS .. "loanview.txt", "wb")
			if f then f:write(txt); f:close() end
		end
	end
	-- this player announces itself once per loaded game: the company it already has (same name), or a new one
	if G.connected and G.session.started and not G.coAsked then
		G.coAsked = true
		local now = gameTime()
		local name = coMyName()
		G.oseq = G.oseq + 1
		local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
		-- the player's Steam account (written by the native module): the company follows the account, whatever name is typed
		local sid = coMySid()
		local a = { fn = "mpfCoJoin", origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
			at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil,
			args = { key = name:lower(), name = name, host = (C.ROLE == "host"), mode = "separate", start = G.coStart, sid = sid,
				cname = C.Tf("Entreprise %s", "%s Company", name) } }
		a.native = true
		send("act", a)
		a.recvFrame = G.frames
		G.nativeQueue[#G.nativeQueue + 1] = a
		log("companies: announced as '" .. name .. "' (company mode " .. tostring(G.cmode) .. ")")
	end
	-- which company is this game's: its interface and tools act as that company from now on
	local reg = st.co
	if reg then
		local c = CO.match(reg, coMyName():lower(), coMySid(), C.ROLE == "host")
		-- the other companies' player entities (the native module empties their money popups, see ClearOthers)
		local others = {}
		for _, o in ipairs(reg.list) do if o.ent and c and o.ent ~= c.ent then others[#others + 1] = o.ent end end
		table.sort(others)
		local osig = table.concat(others, " ")
		-- (said again every few seconds: the native module forgets the value when a game is loaded, see ApplyLocalPlayer)
		if c and c.ent and (G.myCo ~= c.id or G.myEnt ~= c.ent or osig ~= G.coOthers or G.frames - (G.coAsserted or 0) > 400) then
			if G.myCo ~= c.id or G.myEnt ~= c.ent then
				log("companies: this game plays company " .. c.id .. " (player entity " .. c.ent .. ")")
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = function()
					log("companies: the interface's getPlayer() answers " .. tostring(api.engine.util.getPlayer()) .. " (expected " .. tostring(c.ent) .. ")")
					pcall(function()
						local pm = ug_require("/game_mechanics/company/company_progression_util.tl")
						local ps = pm.getCompanyProgressionState(c.ent)
						log("companies: progression read for this company: " .. (ps and ("level " .. tostring(ps.level) .. ", experience " .. tostring(ps.experience)) or "nothing"))
						local cu = ug_require("/game_mechanics/company/company_util.tl")
						local okd, d = pcall(cu.getConstructionDisableCacheData, {})
						log("companies: construction cache for this company: " .. (okd and ("rank " .. tostring(d.companyRank)) or ("ERROR " .. tostring(d):sub(1, 160))))
						if okd and type(d) == "table" then
							local types, built = 0, 0
							for _, v in pairs(d.data or {}) do types = types + 1; built = built + (v.numBuilt or 0) end
							log("companies: permits count " .. types .. " type(s), " .. built .. " construction(s) for this company")
						end
					end)
				end }
			end
			G.myCo, G.myEnt = c.id, c.ent
			G.coAsserted = G.frames
			coCtlSeq = coCtlSeq + 1
			local okT, tm = pcall(os.time)
			local tok = ((okT and tm or 0) % 1000000) * 100 + coCtlSeq % 100
			if not os.getenv("MPFEVER_NOSETLOCAL") then nativeCtl("setlocal " .. c.ent .. " " .. tok) end
			G.coOthers = osig
			if osig ~= "" and not os.getenv("MPFEVER_NOCLEAR") then nativeCtl("setothers " .. tok .. " " .. osig) end
			if reg.canon then nativeCtl("setcanon " .. tok .. " " .. reg.canon) end
		end
	end
end

local function guiUpdate(userParams, state, guiState)
	if not C.ACTIVE then return end
	G.frames = G.frames + 1
	if G.frames % 600 == 0 then
		local ps = G.pstat
		log("gui alive frame " .. G.frames .. " t=" .. tostring(gameTime()) .. " | slowed by other clocks " .. ps.barrier .. "/" .. ps.frames .. " frames, by held actions " .. ps.hold)
		ps.frames, ps.barrier, ps.hold = 0, 0, 0
	end
	if not G.started then
		G.started = true
		-- the game's own functions, even if the UI hook already wrapped this api table (shared after a reload)
		local orig = C.origCmds()
		if not orig.sendCommand then
			orig.sendCommand, orig.setSpeed, orig.event = api.cmd.sendCommand, api.cmd.makeGameSetSpeedCmd, api.cmd.makeScriptingSendEventCmd
		end
		O.sendCommand, O.setSpeed, O.event = orig.sendCommand, orig.setSpeed, orig.event
		O.steps = api.cmd.debug and api.cmd.debug.makeGamePerformSimulationStepsCmd
		pcall(function() guiState:subscribeToAllEvents() end)
		log("bridge v0.17 started: name=" .. C.NAME .. " role=" .. C.ROLE .. " dir=" .. C.DIR)
		local okr, errr = pcall(resumeAfterLoad, state)
		if not okr then log("resume after load failed: " .. tostring(errr)) end
		setSpeed(0)
		local okn, errn = pcall(neutraliseEmissions)
		if not okn then log("emissions: " .. tostring(errn)) end
		send("hello", { name = C.NAME, role = C.ROLE, build = getBuildVersion and getBuildVersion() or "?", time = gameTime() })
	end

	for _, line in ipairs(readLines("in.log", "inOff")) do
		local kind, from, payload = parseLine(line)
		if kind then
			local h = H[kind]
			if h then
				local ok, err = pcall(h, from, C.deser(payload) or {})
				if not ok then log("handler " .. kind .. " failed: " .. tostring(err)) end
			end
		end
	end

	do
		local okT, tNow = pcall(gameTime)
		if okT and tNow ~= G.clockSeen then G.clockSeen = tNow; G.clockMovedAt = G.frames end
	end
	local okh, st = pcall(function() return state:get() end)
	if not (okh and type(st) == "table") then st = {} end
	G.simTerrainSig = st.terrainSig
	G.co = st.co
	local okco, errco = pcall(coGui, st)
	if not okco then log("companies (gui): " .. tostring(errco)) end
	if st.late and st.late > (G.lateSeen or 0) then
		G.lateSeen = st.late
		G.aheadLocked = true
		log("an action arrived late: the full stamp distance is kept for the rest of the session")
	end

	-- outgoing actions BEFORE the clock: a peer must receive an action before it may pass its time
	if G.connected then
		local oks, errs = pcall(stampHeld)
		if not oks then log("stamping failed: " .. tostring(errs)) end
		local okb, errb = pcall(shipNativeBuilds, st)
		if not okb then log("shipping native builds failed: " .. tostring(errb)) end
	end

	if G.connected then
		local okv, errv = pcall(function()
			if G.session.started and not G.natEnabled then G.natEnabled = true; nativeCtl("enable 1") end
			pollNativeEvents()
			runNativeRelease()
			expireNativeWaits()
		end)
		if not okv then log("native deferral failed: " .. tostring(errv)) end
	end
	pcall(runPausedActions)
	local okn, errn = pcall(runNativeReplays)
	if not okn then log("native replays failed: " .. tostring(errn)) end

	if G.connected then
		local okp, sp = pcall(pacing)
		if okp then
			if gameSpeed() ~= sp then G.lastSet = -1 end
			setSpeed(sp)
			-- exact steps up to the stop point (once the engine is stopped, one request at a time)
			local now = gameTime()
			if G.stepTarget and (now >= G.stepTarget or G.frames - G.stepSince > 120) then G.stepTarget = nil end
			if sp == 0 and G.wantSteps and G.wantSteps > 0 and not G.stepTarget and G.simStill() then
				G.stepTarget, G.stepSince = now + G.wantSteps * STEP, G.frames
				O.sendCommand(O.steps(G.wantSteps))
			end
		end
		-- stamp distance = barrier window + overshoot reserve + 1. The engine runs the simulation on its own thread,
		-- driven by real time: a game passes a stop point by what it simulates before its interface reacts (a frame,
		-- or a hiccup of a few hundred milliseconds). The reserve covers about half a second of simulation.
		local spd = math.max(1, math.min(4, G.session.speed or 1))
		G.window = spd + 2
		if G.lastSpd ~= spd then G.lastSpd = spd; G.consumed = {} end
		G.ahead = adaptAhead(G.window + (2 * spd + 1) + 1)
		local okt, t = pcall(gameTime)
		if okt and (t ~= G.lastClock or G.frames % 30 == 0) then
			G.lastClock = t
			G.stampFloor = math.max(G.stampFloor, t + G.ahead * STEP)
			send("clock", { t = t, sp = gameSpeed(), ah = G.ahead })
		end
	end

	-- bindings, results and hashes produced by the simulation half
	for key, e in pairs(st.bind or {}) do
		if G.bind[key] ~= e then
			G.bind[key] = e
			G.rev[e] = key
			C.appendFile(C.DIR .. BS .. "bindings.log", key .. " " .. tostring(e) .. NL)
		end
	end
	if type(st.hash) == "table" and st.hash.n ~= G.hashSent then
		G.hashSent = st.hash.n
		send("sync_hash", { n = st.hash.n, parts = st.hash.parts, cost = st.hash.cost, auth = st.hash.auth })
	end
	for _, r in ipairs(st.results or {}) do
		local key = tostring(r.uid) .. "@" .. tostring(r.at)
		if not G.resultsSeen[key] then
			G.resultsSeen[key] = true
			C.appendFile(C.DIR .. BS .. "results.log", C.line("result", r))
			if not r.success then send("act_refused", { uid = r.uid, fn = r.fn, err = r.err }) end
		end
	end

	if #G.waits > 0 then
		local current = G.waits
		G.waits = setmetatable({}, WAITS_MT)
		for _, w in ipairs(current) do
			if G.frames >= w.at then
				local ok, err = pcall(withActor, w.actor, w.fn)
				if not ok then log("deferred action failed: " .. tostring(err)) end
			else
				G.waits[#G.waits + 1] = w
			end
		end
	end
end

local function guiHandleEvent(userParams, state, guiState, src, id, name, param)
	if not C.ACTIVE then return end
	if type(name) == "string" and name:find("^builder%.") then
		G.evSeen = G.evSeen or {}
		local key = tostring(id) .. "/" .. name
		if not G.evSeen[key] then G.evSeen[key] = true; log("tool event: " .. key) end
	end
end

function data()
	return {
		update = update,
		handleEvent = handleEvent,
		guiUpdate = guiUpdate,
		guiHandleEvent = guiHandleEvent,
	}
end
