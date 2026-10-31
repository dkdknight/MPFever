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
-- the native module stamps the segments' ages the same on every game (native_state.txt, written when it starts): read once
R.tickEpochsOn = function()
	if R.tickState == nil then
		local f = C.IO and C.IO.open(C.DIR .. C.BS .. "native_state.txt", "rb")
		local t = f and f:read("*a") or ""
		if f then f:close() end
		R.tickState = t:find("tickepochs=1", 1, true) ~= nil
	end
	return R.tickState
end
local BS, NL, CR, TAB = C.BS, C.NL, C.CR, C.TAB

local STEP = 200          -- game time units per simulation step
local STAMP_AHEAD = 3     -- steps between an action and its application on every game (barrier slack + 1)
-- constants and counters of the main chunk, in one table: the chunk is close to the game's limit of local variables (0.3.16
-- went over it and the mod did not load at all)
local K = {}
-- (0.6) the game options (mpfever_feat.lua, docs/FEATURES-0.6.md): MPFEVER_FEAT=0 turns every one of their hooks off, as in 0.5.14.
-- Read once, as the game loads: every game of a session is started with the host's settings
K.FEAT = os.getenv("MPFEVER_FEAT") ~= "0"
-- (0.6) the modules' answers to this player's interface events (M.guiVeto: a tool's build in another company's territory refused
-- before the click, see G.featGuiVeto). MPFEVER_FEATVETO=0: the bridge answers nothing, as in 0.5.14
K.FEATVETO = os.getenv("MPFEVER_FEATVETO") ~= "0"

local function gameTime()
	local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
	return gt.gameTime
end

local function gameSpeed()
	-- (the engine's own speed, not the session's speed the interface shows on the speed buttons, see the UI hook)
	local gs = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED)
	if type(gs) == "table" and gs.mpfRealSpeedup ~= nil then return gs.mpfRealSpeedup end
	return gs and gs.speedup or 0
end

-- order-independent hash of a plain Lua value (game script states): tables are hashed as a sum over their entries,
-- so that the iteration order (which differs between Lua states) does not matter
-- (noName: the texts kept under "name" left out. The subsidies' script keeps the title of each one in the language of the
-- game that made it, "Transport Workers" here and "Arbeiter transportieren" there: games in different languages were found
-- out of sync and reloaded at every new subsidy, #102. MPFEVER_SUBNAMES=1: hashed as before)
local function valueHash(v, d, noName)
	local t = type(v)
	if t == "number" then
		if v ~= v then return 1 end
		if math.floor(v) == v and math.abs(v) < 1e15 then return C.hashStr(7, C.int(v)) end
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
			if k ~= "revision" and k ~= "guiTimeSeconds" and not (noName and k == "name" and type(x) == "string") then
				acc = (acc + C.hashStr(valueHash(k, d + 1), tostring(valueHash(x, d + 1, noName)))) % 4294967296
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
		acc = (acc + C.hashStr(23, C.int(c))) % 4294967296
	end
	return n .. "/" .. total .. "/" .. acc
end

-- diagnostic: every value of the game script states, one "path = value" per line, sorted, so that two games' files at
-- the same game time can be compared line by line. Kept for the last 12 checks (sdump_ring_<n>.txt, the game time on the
-- first line), so that a drift of script:towns... reported by a player comes with both games' states (MPFEVER_SDUMP=0:
-- off; =1: the first 40 checks, each in its own file)
-- (one table: the main chunk is close to the game's limit of local variables, 0.3.16 went over it and did not load)
-- (MPFEVER_SDUMP_PERSONS=1: every person too, where it is and where it goes: the first person that differs between two
-- games' files shows where a drift of the towns' happiness started)
-- (MPFEVER_SDUMP=all, tests: every check in its own file, no limit, to find the first check of a drift in a long autotest)
local SDUMP = { on = os.getenv("MPFEVER_SDUMP") ~= "0", all = os.getenv("MPFEVER_SDUMP") == "1" or os.getenv("MPFEVER_SDUMP") == "all", n = 0,
	persons = os.getenv("MPFEVER_SDUMP_PERSONS") == "1" }
local function flatten(v, path, out, d)
	if type(v) == "table" and d < 16 then
		for k, x in pairs(v) do flatten(x, path .. "." .. tostring(k), out, d + 1) end
	else
		out[#out + 1] = path .. " = " .. (type(v) == "number" and string.format("%.10g", v) or tostring(v))
	end
end

local function extendedParts(parts)
	local dump = SDUMP.on and (not SDUMP.all or SDUMP.n < 40 or os.getenv("MPFEVER_SDUMP") == "all") and {}
	for name, res in pairs(GAME_SCRIPTS) do
		local ok, v = pcall(function()
			local e = api.engine.system.gameScriptSystem.getEntityForGameScript(res)
			if not e or e < 0 then return "absent" end
			local c = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT)
			if not c then return "absent" end
			if dump then flatten(c.state, name, dump, 0) end
			return tostring(valueHash(c.state, 0, name == "subventions" and os.getenv("MPFEVER_SUBNAMES") ~= "1"))
		end)
		if ok and v ~= "absent" then parts["script:" .. name] = v end
	end
	if dump then
		-- the vehicles too, by their line and where they are (their ids differ between games): the first vehicle that moved
		-- otherwise in two games' files shows where a drift of "vehicles" started
		pcall(function()
			for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
				local ln = ""
				pcall(function()
					local n = tv and tv.line and tv.line >= 0 and api.engine.getComponent(tv.line, api.type.ComponentType.NAME)
					ln = n and tostring(n.name) or "-"
				end)
				dump[#dump + 1] = "~vehicle " .. ln .. " = " .. (mp and C.dump(mp.dyn):sub(1, 160) or "depot")
			end
		end)
		-- the lines and the names (the parts "lines" and "names" of the checks)
		pcall(function()
			for _, l in ipairs(api.engine.system.lineSystem.getLines()) do dump[#dump + 1] = "~line = " .. tostring(R.lineText(l)) end
			for _, cname in ipairs({ "STATION_GROUP", "LINE", "TRANSPORT_VEHICLE" }) do
				for _, e in ipairs(R.entitiesWith(cname)) do dump[#dump + 1] = "~name " .. cname .. " = " .. R.nameOf(e) end
			end
		end)
		-- the stations with their construction and its place (an industry that grew in one game only shows here)
		pcall(function()
			for _, s in ipairs(R.entitiesWith("STATION")) do
				local con, f, p = nil, "-", nil
				pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(s) end)
				local cc = type(con) == "number" and con >= 0 and api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
				if cc then
					f = tostring(cc.fileName)
					pcall(function() local m = R.matPos(cc.transf); p = string.format("%.0f,%.0f", m.x, m.y) end)
				end
				local sg = nil
				pcall(function() sg = api.engine.system.stationGroupSystem.getStationGroup(s) end)
				dump[#dump + 1] = "~station " .. (type(sg) == "number" and sg >= 0 and R.nameOf(sg) or "-") .. " = " .. f .. "@" .. tostring(p)
			end
		end)
		-- the constructions (part "conParams" of the checks): how many of each kind, and every industry with its place, its
		-- modules (a farm's fields, a fishing ground's nets) and its production level: an industry rebuilt or spawned in one
		-- game only shows here
		pcall(function()
			local kinds = {}
			for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
				local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
				if c and not api.engine.getComponent(e, api.type.ComponentType.TOWN_BUILDING) then
					local f = tostring(c.fileName)
					kinds[f] = (kinds[f] or 0) + 1
					if f:find("/industries/", 1, true) then
						local mods, lvl = {}, "?"
						pcall(function() for k in pairs(c.params.modules) do mods[#mods + 1] = tostring(k) end end)
						table.sort(mods)
						pcall(function()
							for _, ind in ipairs(c.industries) do
								local ic = api.engine.getComponent(ind, api.type.ComponentType.INDUSTRY)
								if ic then lvl = tostring(ic.productionLevel) .. "/" .. tostring(ic.maxLevel) end
							end
						end)
						local p = R.matPos(c.transf)
						dump[#dump + 1] = string.format("~industry %s@%.0f,%.0f = modules {%s} level %s", f:match("[^/]*$"), p and p.x or 0, p and p.y or 0, table.concat(mods, ","), lvl)
					end
				end
			end
			for f, n in pairs(kinds) do dump[#dump + 1] = "~constructions " .. f .. " = " .. n end
		end)
		if SDUMP.persons then
			pcall(function()
				local CT = api.type.ComponentType
				local function ids(list)
					local out = {}
					pcall(function() for i = 1, #list do out[#out + 1] = tostring(list[i]) end end)
					return table.concat(out, ",")
				end
				for _, p in ipairs(R.entitiesWith("SIM_PERSON")) do
					local sp = api.engine.getComponent(p, CT.SIM_PERSON)
					if sp then
						local st = "-"
						local v = api.engine.getComponent(p, CT.SIM_ENTITY_AT_VEHICLE)
						local t = not v and api.engine.getComponent(p, CT.SIM_ENTITY_AT_TERMINAL)
						local m = not v and not t and api.engine.getComponent(p, CT.SIM_ENTITY_MOVING)
						if v then
							st = string.format("vehicle %s line %s %s>%s", tostring(v.vehicle), tostring(v.line), tostring(v.lineStop0), tostring(v.lineStop1))
						elseif t then
							st = string.format("terminal line %s %s>%s since %.6g", tostring(t.line), tostring(t.lineStop0), tostring(t.lineStop1), t.arrivalTime or -1)
						elseif m then
							st = string.format("moving line %s %s>%s partial %s", tostring(m.line), tostring(m.lineStop0), tostring(m.lineStop1), tostring(m.partialPath))
						elseif api.engine.getComponent(p, CT.SIM_ENTITY_AT_BUILDING) then
							st = "building"
						elseif api.engine.getComponent(p, CT.SIM_ENTITY_IDLE) then
							st = "idle"
						end
						local tt = {}
						pcall(function() for i = 1, #sp.travelTimes do tt[#tt + 1] = string.format("%.6g", sp.travelTimes[i]) end end)
						dump[#dump + 1] = string.format("~person %d = happy %.6g at %s dest %s modes %s last %s times %s upd %s pick %s %s",
							p, sp.happiness or -1, tostring(sp.targetOrAtEntity), ids(sp.destinations), ids(sp.moveModes),
							tostring(sp.lastMoveMode), table.concat(tt, ","), tostring(sp.lastDestinationUpdate), tostring(sp.pickupTime), st)
					end
				end
				-- the town buildings with their capacities (the persons' destinations) and their place: a building numbered
				-- otherwise in the two games shows with the same place and time under two numbers
				for _, b in ipairs(R.entitiesWith("TOWN_BUILDING")) do
					local tb = api.engine.getComponent(b, CT.TOWN_BUILDING)
					if tb then
						local cap = tb.personCapacity and tb.personCapacity >= 0 and api.engine.getComponent(tb.personCapacity, CT.PERSON_CAPACITY)
						local where = "-"
						pcall(function()
							local cc = api.engine.getComponent(tb.construction, CT.CONSTRUCTION)
							local mp = R.matPos(cc.transf)
							where = string.format("%.1f,%.1f", mp.x, mp.y)
						end)
						dump[#dump + 1] = string.format("~townbuilding %d = cap %s type %s n %s level %s built %s con %s stock %s town %s @%s", b,
							tostring(tb.personCapacity), cap and tostring(cap.type) or "-", cap and tostring(cap.capacity) or "-", tostring(tb.level),
							tostring(tb.timeBuilt), tostring(tb.construction), tostring(tb.stockList), tostring(tb.town), where)
					end
				end
			end)
		end
		SDUMP.n = SDUMP.n + 1
		table.sort(dump)
		pcall(function()
			local name = SDUMP.all and ("sdump_" .. string.format("%012d", gameTime()) .. ".txt") or ("sdump_ring_" .. (SDUMP.n % 12) .. ".txt")
			local f = C.IO.open(C.DIR .. BS .. name, "wb")
			f:write("t = " .. tostring(gameTime()), NL, table.concat(dump, NL), NL)
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

-- Refunds: the engine gives back what a player has just built when that player demolishes it (the tool's refundable
-- entities, api.gui.construction), on the builder's game only: a replay pays the full removal (a heliport: -2 190 453 on the
-- builder's game, +36 162 on the host's). What a native build cost its builder (the proposal data's costs) is shipped with
-- it; each replaying game adds up what its replay of it cost (every proposal applied for it at its time) and, at its next
-- update, books the difference on the builder's company: every game charged what the builder's game charged. Until the
-- booking is applied the amount counts as booked in the checks (REFUND.pending): the builder's game has it already.
-- (The builder's game pays nothing for a removal that refunds nothing, its replays pay 3 000 to 450 000: booked too. Not
-- booking them, as tried after issue #50, put the money of the shared company apart at once.)
-- MPFEVER_NOREFUND=1 turns it off (on every game).
-- (one table: the main chunk is close to Lua's 200 locals)
local REFUND = { pending = {}, on = os.getenv("MPFEVER_NOREFUND") ~= "1" }
function REFUND.costOf(param)
	local c = nil
	pcall(function() c = tonumber(param[2].costs) end)
	return c
end

function REFUND.key(reg, co)
	if reg and reg.mode == "separate" then return "b" .. tostring(co) end
	return "balance"
end

-- what is booked for a refund and not applied yet, by REFUND.key (see authValues and the money part of the checks)
function REFUND.pendingOf(key)
	local sum = 0
	for _, p in ipairs(REFUND.pending or {}) do if p.key == key then sum = sum + p.amount end end
	return sum
end

function REFUND.book(st, now)
	-- (a booking whose answer never came is not counted for ever)
	if #REFUND.pending > 0 then
		local live = {}
		for _, p in ipairs(REFUND.pending) do
			if p.till >= now then live[#live + 1] = p elseif not p.quiet then log("refund booking of " .. p.amount .. " (" .. p.key .. ") not answered by the engine within two steps: no longer counted") end
		end
		REFUND.pending = live
	end
	if not st.rcost or #st.rcost == 0 then return false end
	local keep = {}
	for _, rc in ipairs(st.rcost) do
		if rc.at >= now then
			keep[#keep + 1] = rc
		elseif (rc.n or 0) > 0 and type(rc.cost) == "number" then
			local d = math.floor((rc.got or 0) - rc.cost + 0.5)
			if d ~= 0 then
				local ent = nil
				if st.co and st.co.mode == "separate" then ent = rc.co and CO.entityOf(st.co, rc.co) or nil else ent = api.engine.util.getPlayer() end
				if ent then
					local entry = api.type.JournalEntry.new()
					entry.amount = d
					entry.time = -1
					-- (in the finance window's line of the build, as the builder's game booked it: roads, tracks, infrastructure,
					-- bulldozer; before 0.5.0 under « Other »: the players saw other expenses than the builder. MPFEVER_REFUNDOTHER=1:
					-- as before)
					local sub = rc.kind and os.getenv("MPFEVER_REFUNDOTHER") ~= "1" and api.type.JournalEntry.Construction[rc.kind] or nil
					if sub then
						entry.category.type = api.type.JournalEntry.Type.CONSTRUCTION
						entry.category.construction = sub
					else
						entry.category.type = api.type.JournalEntry.Type.OTHER
					end
					-- (applied with the next iteration's commands; counted until its answer, at most two steps)
					local p = { key = REFUND.key(st.co, rc.co), amount = d, till = now + 2 * STEP }
					REFUND.pending[#REFUND.pending + 1] = p
					local cmd = api.cmd.makeJournalBookAssetCmd(ent, entry, api.type.Vec3f.new(0, 0, 0))
					local okcb = pcall(api.cmd.sendCommand, cmd, function()
						for i, q in ipairs(REFUND.pending or {}) do if q == p then table.remove(REFUND.pending, i); break end end
					end)
					-- (the simulation's states take no callback: applied with the next iteration all the same, counted until then,
					-- without the "not answered" note)
					if not okcb then api.cmd.sendCommand(cmd); p.quiet = true end
					log("refund: build " .. tostring(rc.uid) .. " cost its builder " .. rc.cost .. ", its replay here " .. rc.got .. " (" .. rc.n
						.. " proposal(s)): " .. d .. " booked on company " .. tostring(rc.co or "-") .. " as " .. (sub and ("construction " .. rc.kind) or "other") .. " at t=" .. now)
				else
					log("refund: build " .. tostring(rc.uid) .. ": company " .. tostring(rc.co) .. " unknown here, difference " .. d .. " not booked")
				end
			end
		elseif (rc.n or 0) == 0 then
			log("refund: build " .. tostring(rc.uid) .. " (cost " .. tostring(rc.cost) .. " for its builder) was not applied here: nothing booked")
		end
	end
	st.rcost = #keep > 0 and keep or nil
	return true
end

-- values the host imposes on the other games (corrected at every checkpoint)
local function authValues(reg)
	if reg and reg.mode == "separate" then
		-- one balance and one loan per company (flat numbers: the launcher forwards the host's top-level numbers)
		local t = {}
		for _, c in ipairs(reg.list) do
			local okc, acc = pcall(function() return api.engine.getComponent(c.ent, api.type.ComponentType.ACCOUNT) end)
			if okc and acc then t["b" .. c.id] = acc.balance + REFUND.pendingOf("b" .. c.id); t["l" .. c.id] = acc.loan end
		end
		return t
	end
	local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
	return { balance = acc.balance + REFUND.pendingOf("balance"), loan = acc.loan }
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

-- The host's game sends its names to the games of the other languages (issue #97, see R.nameChanges and H.namesync)
function K.nameSyncOn() return C.ROLE == "host" and os.getenv("MPFEVER_NAMESYNC") ~= "0" end

-- The terrain edits applied, for the checks: a note per edit (its time and the checksum of its cells) reaches the simulation when
-- the interface sends it, a little after the edit's time and not at the same moment on every game. A check at time T counts the
-- edits older than T by more than a note can take to arrive (they are then known everywhere), folded into st.terrainSig.
K.TERRAIN_SIG_LAG = 150 * STEP
local function terrainSigAt(st, now)
	local sig, keep = st.terrainSig or 0, {}
	for _, n in ipairs(st.terrainNotes or {}) do
		if n.at <= now - K.TERRAIN_SIG_LAG then sig = (sig + n.v) % 4294967296 else keep[#keep + 1] = n end
	end
	st.terrainSig, st.terrainNotes = sig, keep
	return sig
end

local hashShown = false
K.hashCostsShown = 0
local function simHash(terrainSig, reg, n, buildIds, at)
	local tStart = os.clock()
	-- the expensive parts take turns (issue #32: the whole check held the simulation step about 0.3 s every 10 s): every
	-- checkpoint hashes the cheap parts and one group, chosen by the checkpoint's number, the same on every game. The
	-- launcher keeps a difference per part until that part is checked again. (Not in the autotests, nor without a number:
	-- the determinism run; MPFEVER_HASHROT=0 / 1 forces it off / on.)
	local rot = os.getenv("MPFEVER_HASHROT")
	R.hashSkip = nil
	if n and (rot == "1" or (rot ~= "0" and not os.getenv("MPFEVER_SAVE"))) then
		local groups = { { "conParams" }, { "edges", "ages" }, { "constructions", "nodeConfigs" } }
		local keep = groups[(n % #groups) + 1]
		R.hashSkip = {}
		for _, g in ipairs(groups) do for _, p in ipairs(g) do R.hashSkip[p] = true end end
		for _, p in ipairs(keep) do R.hashSkip[p] = nil end
	end
	local parts = R.contentHash(C.hashStr, C.dump)
	-- (the builds of 50 steps ago and before: every game has checked those, a few steps after the build, but not at the same
	-- step - the checks follow the script's update calls)
	local bn, bs = 0, 0
	if type(buildIds) == "table" then
		bn, bs = tonumber(buildIds.n0) or 0, tonumber(buildIds.s0) or 0
		local upto = (tonumber(at) or 0) - 50 * STEP
		for _, e in ipairs(type(buildIds.list) == "table" and buildIds.list or {}) do
			if (tonumber(e.at) or 0) <= upto then bn = bn + 1; bs = (bs + (tonumber(e.h) or 0)) % 4294967296 end
		end
	end
	parts.buildIds = bn .. "/" .. bs
	R.hashSkip = nil
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
	if K.hashCostsShown < 3 then
		K.hashCostsShown = K.hashCostsShown + 1
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
				t[#t + 1] = c.id .. ":" .. (acc.balance + REFUND.pendingOf("b" .. c.id)) .. "/" .. acc.loan
			end
			return table.concat(t, "|")
		end
		local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
		return (acc.balance + REFUND.pendingOf("balance")) .. "/" .. acc.loan
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
	-- (kind: the component the entity must have. A vehicle command given an entity that is no vehicle here stopped the engine
	-- on an assertion: a sale of 8 vehicles by their ids, one of them another kind of entity on this game, crashed both games of
	-- a replay at once, 2026-10-26. MPFEVER_ARGKIND=0: existence only, as before)
	local function check(e, what, kind)
		if type(e) == "table" then
			for k, v in ipairs(e) do check(v, what .. "[" .. k .. "]", kind) end
			return
		end
		if type(e) == "number" and e >= 0 then
			local ok, exists = pcall(function() return api.engine.entityExists(e) end)
			if ok and exists == false then missing[#missing + 1] = what .. "=" .. e; return end
			if kind and os.getenv("MPFEVER_ARGKIND") ~= "0" then
				local okc, comp = pcall(function() return api.engine.getComponent(e, api.type.ComponentType[kind]) end)
				if okc and comp == nil then missing[#missing + 1] = what .. "=" .. e .. " (no " .. kind .. ")" end
			end
		end
	end
	local vehicleCmd = type(fn) == "string" and fn:find("^makeVehicle") ~= nil and fn ~= "makeVehicleBuyCmd"
	for _, i in ipairs(ENTITY_ARGS[fn] or {}) do
		local kind = nil
		if vehicleCmd and i == 1 then kind = "TRANSPORT_VEHICLE" elseif fn == "makeVehicleSetLineCmd" and i == 2 then kind = "LINE" end
		check(margs[i], "arg" .. i, kind)
	end
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
-- (in a block: the main chunk of this script is at Lua's limit of 200 locals)
local executeAction
do
local function executeActionOnce(a, sendCommand, useCallback, bind, done)
	local result = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = false }
	-- companies mode: a new line takes its company's colour (a little darker for each line the company already has), so that the
	-- lines of each company can be told apart on the map and in the line lists
	-- (MPFEVER_LINECOLOR=1: the players do not see the other companies' lines, so a line keeps the colour its player gave it)
	if a.fn == "makeLineCreateCmd" and a.co and R.CO and type(a.args) == "table" and os.getenv("MPFEVER_LINECOLOR") == "1" then
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
		and (a.args[2] == "Subvention" or a.args[2] == "mpfever" or (a.args[2] == "Companies" and os.getenv("MPFEVER_NOCOACTIONS") ~= "1"))
		and type(a.args[4]) == "table" then
		a.args[4].mpfCo = a.co
		-- (and the player who sent it: a company's chief answers the requests to join it, see mpfever_eco.lua)
		if a.args[2] == "mpfever" then a.args[4].mpfFrom = a.origin end
	end
	-- (0.6) the events of the game options (f_opts, the modules' f_<module>_...) carry their sender in both company modes: only the
	-- host's f_opts is taken (see mpfever_feat.lua). No such event is ever sent while no option is on
	if K.FEAT and a.fn == "makeScriptingSendEventCmd" and type(a.args) == "table" and a.args[2] == "mpfever" and type(a.args[3]) == "string"
		and a.args[3]:sub(1, 2) == "f_" and type(a.args[4]) == "table" then
		a.args[4].mpfFrom = a.origin
		if a.co then a.args[4].mpfCo = a.co end
	end
	if a.fn == "makeScriptingSendEventCmd" and a.co and R.CO and R.CO.canon and a.co ~= CO.idOfEntity(R.CO, R.CO.canon)
		and type(a.args) == "table" and (a.args[2] == "Loan" or a.args[2] == "Company"
			or (a.args[2] == "Companies" and os.getenv("MPFEVER_NOCOACTIONS") == "1")) then
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
	-- a mod's automatic command (see DET.installModCmds) names, colours or updates a line: on anything else (an id that is
	-- another entity here) the engine asserts and the game closes. Skipped instead, the same on every game
	if a.tok == "mod" and type(a.args) == "table" then
		local okL, isLine = pcall(function() return api.engine.getComponent(a.args[1], api.type.ComponentType.LINE) ~= nil end)
		if not (okL and isLine) then
			result.err = "mod command on entity " .. tostring(a.args[1]) .. ", which is not a line here"
			log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
			return result
		end
	end
	local okm, missing = pcall(missingEntities, a.fn, a.args or {})
	if okm and #missing > 0 then
		result.err = "DESYNC missing entities: " .. table.concat(missing, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	-- companies mode: what belongs to another company is not touched by this one, the same on every game (ported from TPF3-MP's
	-- companies.mayTouch and mayBuyAtDepot): its vehicles, lines, depots and stations (selling, sending to a line or a depot,
	-- editing, renaming, recolouring, buying a vehicle in its depot). What belongs to no company (the towns' streets, the
	-- savegame's objects without an owner) stays everyone's. MPFEVER_NOOWNERGUARD=1 turns it off (on every game).
	if a.co and R.CO and R.CO.mode == "separate" and type(a.args) == "table" and C.OWNER_ARGS[a.fn] and os.getenv("MPFEVER_NOOWNERGUARD") ~= "1" then
		local refused, toll = nil, nil
		pcall(function()
			for _, i in ipairs(C.OWNER_ARGS[a.fn]) do
				local e = a.args[i]
				-- (0.5.14: a list of entities, a sale of several vehicles: each one is checked; before, a list was never checked and
				-- a company could sell another's vehicles. MPFEVER_OWNERLISTS=0: as before)
				if type(e) == "table" and os.getenv("MPFEVER_OWNERLISTS") ~= "0" then
					for _, x in ipairs(e) do
						local o = type(x) == "number" and CO.idOfEntity(R.CO, R.ownerOf(x)) or nil
						if o and o ~= a.co then e = x; break end
					end
				end
				local owner = type(e) == "number" and CO.idOfEntity(R.CO, R.ownerOf(e)) or nil
				if owner and owner ~= a.co then
					-- (a depot its company opened to the others, 0.5.0: a vehicle bought there or sent there, for a toll or not; the
					-- depot's own setting, else its company's rule for its depots, 0.5.2)
					local open, fee = false, 0
					if ((a.fn == "makeVehicleBuyCmd" and i == 2) or (a.fn == "makeVehicleSendToDepotCmd" and i == 3)) and C.eco() then
						open, fee = C.eco().depotUse(R.CO, nil, e, a.co, owner)
					end
					if open then
						if fee > 0 then toll = { to = owner, fee = fee } end
					else
						local c = CO.find(R.CO, owner)
						refused = "it belongs to company " .. owner .. ((c and c.name ~= "") and (" (" .. c.name .. ")") or "")
						break
					end
				end
			end
		end)
		if refused then
			result.err = refused
			log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " of company " .. tostring(a.co) .. " refused on every game: " .. refused)
			return result
		end
		if toll then
			pcall(function()
				local JE = api.type.JournalEntry
				local from, to = CO.entityOf(R.CO, a.co), CO.entityOf(R.CO, toll.to)
				local function entry(n, earn)
					local x = JE.new()
					x.amount = n
					x.time = -1
					if earn then
						x.category.type = JE.Type.INCOME
						x.category.carrier = JE.Carrier.OTHER
					else
						x.category.type = JE.Type.MAINTENANCE
						x.category.maintenance = JE.Maintenance.INFRASTRUCTURE
						x.category.construction = JE.Construction.DEPOT
						x.category.carrier = JE.Carrier.OTHER
					end
					return x
				end
				if from and to then
					api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(from, entry(-toll.fee, false), api.type.Vec3f.new(0, 0, 0)))
					api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(to, entry(toll.fee, true), api.type.Vec3f.new(0, 0, 0)))
				end
				log("companies: company " .. tostring(a.co) .. " uses a depot of company " .. toll.to .. " for " .. toll.fee)
			end)
		end
	end
	-- companies mode: a line stops only at its company's stations and at the stations of another company that are not private
	-- (0.5.2: the station's rule, its own setting or its company's, see mpfever_eco.lua's stationRule; before, its fee: 0 = not
	-- shared, no fee = shared for $100. Without mpfever_eco.lua: as before)
	if (a.fn == "makeLineCreateCmd" or a.fn == "makeLineUpdateCmd") and a.co and R.CO and R.CO.mode == "separate" and type(a.args) == "table" then
		local line = a.args[a.fn == "makeLineCreateCmd" and 4 or 2]
		local blocked = nil
		local eco = C.eco()
		pcall(function()
			for _, stop in ipairs(type(line) == "table" and line.stops or {}) do
				local sg = type(stop) == "table" and stop.stationGroup
				if type(sg) == "number" and sg >= 0 then
					local owner = CO.idOfEntity(R.CO, R.ownerOf(sg))
					if owner and owner ~= a.co then
						local key = R.sgKey(sg)
						local private
						if eco then private = eco.stationRule(R.CO, key, owner) == "private" else private = C.shareFee(R.CO.shares, key) <= 0 end
						if private then blocked = sg break end
					end
				end
			end
		end)
		if blocked then
			result.err = "station " .. tostring(blocked) .. " belongs to another company and is private"
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
	-- (the key of what the action creates: its uid and its stamp. The uid alone came back after every load, its counter
	-- starting again from 0, while the bindings stay in the savegame: a line of an earlier session had the same key as a new
	-- one, an update of the old line went to the new one after it was removed, and every game crashed, issue #53)
	local ckey = createdKey and (createdKey .. tostring(a.uid) .. "@" .. tostring(a.at or ""))
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
			if ok and createdKey and type(first) == "number" then result.created = { key = ckey, e = first } end
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
			-- the line manager's callback reads the vehicle and the line of an assignment ("Send To Line": with an empty
			-- result it failed, and the window's follow-up never ran, issue #22); the references are this game's ids here
			if a.fn == "makeVehicleSetLineCmd" and type(a.args) == "table" then
				data.vehicleEntity, data.lineEntity, data.stopIndex = a.args[1], a.args[2], a.args[3]
			end
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
					result.created = { key = ckey, e = created }
				else
					-- the engine may create it during the next step: watch for it
					local seen = {}
					for e, _ in pairs(beforeSet) do seen[#seen + 1] = e end
					result.watch = { kind = watch, key = ckey, before = seen, steps = 0, fn = a.fn }
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

-- done is called exactly once, also for an action skipped before it reached the engine (an unresolved reference...):
-- a skipped paused action was never reported (issue #12)
executeAction = function(a, sendCommand, useCallback, bind, done)
	if not (useCallback and done) then return executeActionOnce(a, sendCommand, useCallback, bind, done) end
	local fired = false
	local function once(r)
		if fired then return end
		fired = true
		done(r)
	end
	local r = executeActionOnce(a, sendCommand, useCallback, bind, once)
	if not r.returned then once(r) end
	return r
end
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
-- The game keeps api.engine.util from one game to the next in the same run: without companies (a new game, a savegame played
-- alone or shared) the game's own getPlayer() comes back, else the next game asked the company of the game before (issue #88: a
-- new game after a session of companies, getPlayer() gave entity 68473, a group of trees there, and the game crashed).
local function installSimPlayer(st)
	local reg = st and st.co
	local util = api.engine.util
	if util.mpfRealGetPlayer == nil then pcall(function() util.mpfRealGetPlayer = util.getPlayer end) end
	if not (reg and reg.canon) then
		local real = util.mpfRealGetPlayer
		if real and util.getPlayer ~= real then
			util.getPlayer = real
			SIM.wrapper = nil
			log("companies: getPlayer() given back to the game (no company here)")
		end
		return
	end
	SIM.canon = reg.canon
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

-- a company takes another colour: its player entity and, when asked from the MPFever window, its lines (a little darker for
-- each line, as a new line), on every game. The colour picked in the menu leaves the savegame's lines as their owner made them.
-- (in a field of SIM: the main chunk is at Lua's limit of 200 locals)
-- A new game of one company per player (0.5.14): the savegame's company (the host's) starts with the money every other company
-- gets, once, when the registry is made, and only where it has nothing yet (no vehicle, no line): a game under way keeps
-- everybody's money. Applied by the simulation of every game at the same step. (MPFEVER_SHARESWITCH=0: as before, the
-- savegame's own money, often 0)
SIM.coStartCanon = function(st, start)
	if os.getenv("MPFEVER_SHARESWITCH") == "0" or not start or start < 0 or not st.co then return end
	local canon = st.co.canon
	local owned = 0
	for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
		local po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED)
		if po and po.player == canon then owned = owned + 1; break end
	end
	pcall(function() if #api.engine.system.lineSystem.getLinesForPlayer(canon) > 0 then owned = owned + 1 end end)
	-- (and a loan: a map prepared with borrowed money lost the money and kept the debt; the game's loans are the savegame's
	-- company's until the registry is made)
	pcall(function()
		local e = api.engine.system.gameScriptSystem.getEntityForGameScript(GAME_SCRIPTS.loan)
		local s = e and e >= 0 and C.marshal(api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT).state) or nil
		if type(s) == "table" and type(s.obtainedLoans) == "table" and #s.obtainedLoans > 0 then owned = owned + 1 end
	end)
	if owned > 0 then log("companies: the savegame's company already runs vehicles or lines, or has a loan: it keeps its money"); return end
	local acc = api.engine.getComponent(canon, api.type.ComponentType.ACCOUNT)
	local bal = acc and tonumber(acc.balance) or nil
	if not bal then return end
	local delta = math.floor(start - bal + 0.5)
	if delta == 0 then return end
	local entry = api.type.JournalEntry.new()
	entry.amount = delta
	entry.time = -1
	entry.category.type = api.type.JournalEntry.Type.OTHER
	api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(canon, entry))
	log("companies: a new game: the savegame's company takes the start money of every company (" .. start .. ", booked " .. delta .. ")")
end

SIM.coRecolor = function(st, c, withLines)
	if not (c and c.ent) then return end
	local r, g, b = CO.rgb(c.color)
	api.cmd.sendCommand(api.cmd.makeEntitySetColorCmd(c.ent, api.type.Vec3f.new(r, g, b)))
	local lines = {}
	if withLines ~= false then pcall(function() for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(c.ent)) do lines[#lines + 1] = l end end) end
	table.sort(lines)
	for k, l in ipairs(lines) do
		local f = 1 - 0.12 * ((k - 1) % 4)
		pcall(function() api.cmd.sendCommand(api.cmd.makeEntitySetColorCmd(l, api.type.Vec3f.new(r * f, g * f, b * f))) end)
	end
	log("companies: company " .. c.id .. " takes colour " .. tostring(c.color) .. " (" .. #lines .. " line(s) recoloured)")
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
		pcall(SIM.coStartCanon, st, tonumber(p.start))
	end
	-- (a dedicated server names the player who gets the savegame's company)
	if type(p.owner) == "string" then st.co.owner = p.owner end
	-- (two names announcing one Steam account at the same time: two games of one PC, see CO.noteAnnounce)
	if CO.noteAnnounce(st.co, tostring(p.key), p.sid, tonumber(a.at)) then
		log("companies: two players announced the same Steam account (two games of one PC): their companies follow their names only")
	end
	local c, isNew, recolor, dropped = CO.join(st.co, tostring(p.key), tostring(p.name), p.host == true, p.cname, p.sid, tonumber(p.color))
	-- (0.5.14: a new company's start money, its join's: the players' value of the session, or a computer company's own)
	if isNew and c and not c.ent and tonumber(p.start) and os.getenv("MPFEVER_SHARESWITCH") ~= "0" then c.start = math.max(0, math.floor(tonumber(p.start))) end
	if (dropped or 0) > 0 then log("companies: " .. dropped .. " member(s) written twice in a company dropped (a registry saved by 0.5.1 on one PC)") end
	log("companies: player '" .. tostring(p.key) .. "' plays company " .. c.id .. (isNew and " (new)" or " (known)") .. " colour " .. tostring(c.color))
	-- The company this join gave, for the interface of this game, which waits for it (see pumpCompanies): its copy of the
	-- registry is read once per frame, and the frame that sent the join still showed the registry from before it. Known by the
	-- token of that send (a.coTok, this game's own), else by the act's number and time; the last 8 are kept.
	st.co.joined = type(st.co.joined) == "table" and st.co.joined or {}
	st.co.joined[#st.co.joined + 1] = { k = a.coTok or (tostring(a.uid) .. "@" .. tostring(a.at)), id = c.id }
	while #st.co.joined > 8 do table.remove(st.co.joined, 1) end
	if recolor then pcall(SIM.coRecolor, st, c, false) end
	installSimPlayer(st)
end

-- an action's identity across the queue: its number and its stamp (the numbers start again after a resynchronisation,
-- at a later game time); none for checkpoints and company joins
local function doneKey(a)
	if a.uid and a.at and a.fn ~= "mpfCoJoin" then return tostring(a.uid) .. "@" .. tostring(a.at) end
	return nil
end

local function simApplyDue(state)
	local st = state:get() or {}
	R.CO = st.co
	local now = gameTime()
	local changed = false
	if REFUND.on and REFUND.book(st, now) then changed = true end
	-- (the replays of an earlier game time are all applied: their town statistics against their builders', see SIM.townStats)
	if st.rstats then
		local okT, closed = pcall(SIM.townDue, st, now, false)
		if okT and closed then changed = true end
	end
	-- each company's rank, four times a game month (mpfever_progression.lua)
	if st.co and st.co.mode == "separate" then
		local PG = C.progression()
		local okG, ch = pcall(function() return PG and PG.update(st, api, ug_require, log) end)
		if okG and ch then changed = true elseif not okG then log("ranks: " .. tostring(ch)) end
	end
	local q = st.q or {}
	-- The queue is saved with the game. At the first step after a load, an action whose time has passed without being
	-- applied (no other kind is left behind: a due action leaves the queue before it runs) belongs to the session the
	-- savegame was made in: a vehicle sold by such an action as the world loaded crashed the game at every load (« it !=
	-- components.end() » in UI::CSelector, issue #84, a 0.4.5 savegame). Every game loads the same file and drops the same
	-- actions. Purchases waiting for their step (one per step, a.spread) are kept. MPFEVER_KEEPSTALE=1: as before
	if not SIM.loadChecked then
		SIM.loadChecked = true
		-- (the names of the savegame as every game loaded it: the first check sends what changed since, see R.nameSeed)
		if K.nameSyncOn() then pcall(R.nameSeed) end
		if os.getenv("MPFEVER_KEEPSTALE") ~= "1" then
			local kept, gone = {}, {}
			for _, a in ipairs(q) do
				if type(a.at) == "number" and a.at < now and not (a.fn == "makeVehicleBuyCmd" and a.spread) then
					gone[#gone + 1] = tostring(a.uid) .. " " .. tostring(a.fn or a.kind) .. " for t=" .. a.at
				else
					kept[#kept + 1] = a
				end
			end
			if #gone > 0 then
				log("loaded: " .. #gone .. " action(s) of the savegame's session past their time, not applied (now t=" .. now .. "): " .. table.concat(gone, ", "))
				st.q, q, changed = kept, kept, true
			end
		end
	end
	if #q > 0 then
		table.sort(q, before)
		-- the due actions leave the queue before any of them runs: a state saved while one runs (or an event handled
		-- meanwhile) never holds them again (a player's purchase was once applied three times on the host)
		-- (one vehicle purchase per game step, not per call: this function also runs while the game time stands still, at a
		-- held build, at the barrier or behind a terrain tool, and a game standing still then created several vehicles at one
		-- step that a running game created one step apart: other ids, the games drifted apart, issue #35. The step of the last
		-- purchase is part of the state saved with the game, so every game applies the same rule after a reload)
		local due, keep, bought = {}, {}, false
		local oldRule = os.getenv("MPFEVER_OLDBUY") == "1"   -- (tests: the rule of 0.3.9 and before, one purchase per call)
		for _, a in ipairs(q) do
			local buy = a.fn == "makeVehicleBuyCmd"
			if a.at <= now and not (buy and (bought or (not oldRule and st.buyAt and st.buyAt >= now))) then
				if buy then st.buyAt = now; bought = true end
				due[#due + 1] = a
			else
				if buy and a.at <= now then a.spread = true end
				keep[#keep + 1] = a
			end
		end
		st.q = keep
		st.results = st.results or {}
		st.bind = st.bind or {}
		st.doneUid = st.doneUid or {}
		for uid, t in pairs(st.doneUid) do if t < now - 600 * STEP then st.doneUid[uid] = nil end end
		for _, a in ipairs(due) do
			changed = true
			local dk = doneKey(a)
			if dk and st.doneUid[dk] then
				log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " already applied at t=" .. st.doneUid[dk] .. ": skipped")
			else
				if dk then st.doneUid[dk] = now end
				if a.kind == "hash" then
					local c0 = os.clock()
					local okA, auth = pcall(authValues, st.co)
					local nameSync = K.nameSyncOn()
					if nameSync then R.nameCollect = {} end
					st.hash = { n = a.n, parts = simHash(terrainSigAt(st, now), st.co, a.n, st.buildIds, now), cost = os.clock() - c0, auth = okA and auth or nil }
					if nameSync then
						local col = R.nameCollect
						R.nameCollect = nil
						if col and next(col) ~= nil then st.hash.names = R.nameChanges(col) end
					end
					st.authOwn = st.authOwn or {}
					st.authOwn[#st.authOwn + 1] = { n = a.n, auth = okA and auth or nil }
					while #st.authOwn > 10 do table.remove(st.authOwn, 1) end
				elseif a.fn == "mpfCoJoin" then
					local okc, errc = pcall(coApply, st, a)
					if not okc then log("companies: " .. tostring(a.fn) .. " failed: " .. tostring(errc)) end
				elseif a.fn == "makeScriptingSendEventCmd" and type(a.args) == "table" and a.args[3] == "applyLevel"
					and (a.args[2] == "Companies" or a.args[2] == "Company") and st.co and C.progression() and C.progression().multi(st.co) then
					-- a company takes a rank in the company window: its own rank (mpfever_progression.lua), the same on every
					-- game; the savegame's company also takes it in the game's own state (kept when it is alone again)
					local PG = C.progression()
					local co = a.co or 1
					local level = type(a.args[4]) == "table" and tonumber(a.args[4].level) or nil
					local okR, why = PG.take(st.prog, st.co, co, level)
					log("ranks: company " .. tostring(co) .. " takes rank " .. tostring(level) .. ": " .. (okR and "done" or tostring(why)))
					st.results = st.results or {}
					st.results[#st.results + 1] = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = okR, err = (not okR) and why or nil, at = now }
					while #st.results > 40 do table.remove(st.results, 1) end
					if okR and co == 1 then
						state:set(st)
						pcall(executeAction, a, api.cmd.sendCommand, false, st.bind)
						st = state:get() or st
					end
				elseif coIsLoanEvent(st, a) then
					local okc, errc = pcall(coApply, st, a)
					if not okc then log("companies: loan event failed: " .. tostring(errc)) end
					st.results = st.results or {}
					st.results[#st.results + 1] = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = true, at = now }
					while #st.results > 40 do table.remove(st.results, 1) end
				else
					if a.at < now and a.spread then
						-- (a purchase that waited for the one before it: the same step on every game, not a late action, #34)
						log("action " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. ": one purchase per step")
					elseif a.at < now then
						log("LATE action " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)")
						st.late = (st.late or 0) + 1
					end
					-- mark the replay so that onPreBuildProposal does not ship it again
					if C.makesProposal(a.fn) then
						st.replay = { at = now, n = ((st.replay and st.replay.at == now) and st.replay.n or 0) + 1 }
						-- (and what it builds: the engine's second application of the same build is not shipped either)
						if a.fn == "makeWorldBuildProposalCmd" then
							if not (st.replaySigs and st.replaySigs.at == now) then st.replaySigs = { at = now, list = {} } end
							local okg, sig = pcall(C.buildSig, type(a.args) == "table" and a.args[1] or nil)
							if okg and sig then st.replaySigs.list[#st.replaySigs.list + 1] = sig end
						end
					end
					state:set(st)
					-- (0.6) what the game options' modules keep of it, before its references are translated (nothing while no option is on)
					SIM.featDg = nil
					if SIM.featOn then
						local okD, dg = pcall(SIM.featDigests, st, a)
						if okD then SIM.featDg = dg end
					end
					SIM.actor = (st.co and a.co) and CO.entityOf(st.co, a.co) or nil
					local okx, r = pcall(executeAction, a, api.cmd.sendCommand, false, st.bind)
					SIM.actor = nil
					if not okx then error(r) end
					st = state:get() or st
					-- (not replayable here: no build of it comes, the count above is taken back. Else the player's own next
					-- build in this step was taken as this replay and never shipped)
					if C.makesProposal(a.fn) and not r.success and st.replay and st.replay.at == now and st.replay.n > 0 then
						st.replay.n = st.replay.n - 1
					end
					-- (0.6) the game options' modules hear the action and the engine's verdict, on every game at this step (nothing
					-- while no option is on, see SIM.featOn)
					if SIM.featOn then
						local okF, errF = pcall(SIM.featAction, st, a, r.success == true)
						if not okF then log("options: onAction failed: " .. tostring(errF)) end
						SIM.featDg = nil
					end
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
			end
		end
	end
	-- entities created one or more steps after their command (vehicle purchases)
	if st.watches and #st.watches > 0 then
		local keepW = {}
		for _, r in ipairs(st.watches) do
			local w = r.watch
			-- (steps of game time: this runs while the game stands still too, #35)
			if w.lastT ~= now then w.steps = w.steps + 1; w.lastT = now end
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
				elseif w.fn == "makeVehicleReplaceCmd" then
					-- (a replacement is made when the vehicle reaches a depot, later: not a refusal; issue #47 counted it as one
					-- on every game)
				else
					r.success = false
					r.err = "created entity not found"
				end
				log("action " .. tostring(r.uid) .. " result after " .. w.steps .. " step(s): " .. (created and ("entity " .. created)
					or (w.fn == "makeVehicleReplaceCmd" and "nothing created yet (the replacement is made at a depot)" or "nothing created")))
				st.results = st.results or {}
				st.results[#st.results + 1] = r
			else
				keepW[#keepW + 1] = r
			end
		end
		st.watches = keepW
		changed = true
	end
	installSimPlayer(st)
	if st.pauseAt and now >= st.pauseAt and not st.pausedAt then
		st.pausedAt = now
		api.cmd.sendCommand(api.cmd.makeGameSetSpeedCmd(0))
		changed = true
	end
	if changed then state:set(st) end
end

-- Deterministic math.random for the game mechanics: a draw depends only on the game time, the place in the code that draws
-- (file and line) and how many draws that place made at this game time, whatever else drew before. One count for every
-- draw of the state was not enough: something drew at every frame of a pause, as many times as each machine showed frames
-- (81 draws before a player's three loans at one game time, issue #51), and every later draw of that game time, the loans'
-- delays among them, differed between games. math.randomseed(n) (the construction scripts seed from their parameters) starts
-- that place's draws from n until the game time changes.
-- (one table: see SDUMP)
local DET = {}
local function installRandom()
	if DET.random and math.random == DET.random then return end
	local lastT, counts, seeds = -1, {}, {}
	local function mix(h)
		for _ = 1, 3 do
			-- 32-bit multiply in doubles (exact: each partial product stays below 2^53), then fold the high bits down
			local hi, lo = math.floor(h / 65536), h % 65536
			h = ((hi * 2246822519) % 65536 * 65536 + lo * 2246822519) % 4294967296
			h = (h + math.floor(h / 8192)) % 4294967296
		end
		return h
	end
	local function now()
		local okT, t = pcall(gameTime)
		t = okT and t or 0
		if t ~= lastT then lastT, counts, seeds = t, {}, {} end
		return t
	end
	-- (the caller's file and line; level 3: this function, DET.random or DET.seed, their caller. The file's name only: the folders
	-- of the game and of the mods differ between machines)
	local getinfo = type(debug) == "table" and debug.getinfo or nil
	local function where()
		local info = getinfo and getinfo(3, "Sl")
		if not info then return "?" end
		local src = tostring(info.source):gsub("\\", "/"):match("([^/]*)$")
		return src .. ":" .. tostring(info.currentline)
	end
	local function placeHash(s)
		local h = 2166136261
		for i = 1, #s do h = ((h % 16777216) * 16777619 + s:byte(i) * 4099) % 4294967296 end
		return h
	end
	DET.random = function(m, k)
		local t = now()
		local key = where()
		local file = key:match("^(.*):%-?%d+$") or key
		local sd = seeds[file]
		local n
		local h
		if sd then
			-- seeded: the place's file draws in turn from its seed
			sd.n = sd.n + 1
			h = mix((sd.seed + sd.n * 2654435769) % 4294967296)
		else
			n = (counts[key] or 0) + 1
			counts[key] = n
			h = mix((t % 4294967296 + n * 2654435769 + placeHash(key)) % 4294967296)
		end
		local x = h / 4294967296
		if m == nil then return x end
		if k == nil then m, k = 1, m end
		return m + math.floor(x * (k - m + 1))
	end
	local origSeed = (DET.seed and math.randomseed == DET.seed) and DET.origSeed or math.randomseed
	DET.origSeed = origSeed
	DET.seed = function(s)
		now()
		local key = where()
		local file = key:match("^(.*):%-?%d+$") or key
		s = tonumber(s) or 0
		seeds[file] = { seed = mix(math.floor(s) % 4294967296), n = 0 }
		pcall(origSeed, s)
	end
	math.random = DET.random
	math.randomseed = DET.seed
	log("deterministic math.random installed")
end

-- Mods that rename, recolour or update lines by themselves (Auto Line Namer, Auto Color Lines, Auto Assign Terminals, issue
-- #58): their simulation script runs on every game, but decides on the computer's clock (os.time, os.clock), so each game
-- sent its own commands at its own steps and the line names differed. In a session only the host's commands count: they
-- are written to sim_mods.log, the interface half ships them like a player's (applied at the same step everywhere, the host
-- too), and the other games drop their own. (MPFEVER_MODHOST=0: as before, every game applies its own)
DET.mod = { hostOnly = { makeEntitySetNameCmd = true, makeEntitySetColorCmd = true, makeLineUpdateCmd = true } }
function DET.installModCmds()
	local MODCMD = DET.mod
	if MODCMD.installed or os.getenv("MPFEVER_MODHOST") == "0" or not C.ACTIVE then return end
	local getinfo = type(debug) == "table" and debug.getinfo or nil
	if not getinfo then
		if not MODCMD.warned then MODCMD.warned = true; log("mod commands: debug.getinfo missing, not intercepted") end
		return
	end
	MODCMD.installed = true
	local origSend = api.cmd.sendCommand
	local tags = setmetatable({}, { __mode = "k" })
	for name, _ in pairs(MODCMD.hostOnly) do
		local fn = api.cmd[name]
		if fn ~= nil then
			pcall(function()
				api.cmd[name] = function(...)
					local cmd = fn(...)
					if cmd ~= nil then tags[cmd] = { name = name, args = { n = select("#", ...), ... } } end
					return cmd
				end
			end)
		end
	end
	local seen, dropped = {}, 0
	api.cmd.sendCommand = function(cmd, cb, ...)
		local tag = cmd ~= nil and tags[cmd] or nil
		-- (the first Lua function up the stack: MPFever applies the commands it ships through pcall, a C function)
		local src = ""
		if tag then
			for lv = 2, 12 do
				local info = getinfo(lv, "S")
				if not info then break end
				if info.what ~= "C" then src = tostring(info.source):gsub("\\", "/"); break end
			end
		end
		-- (MPFever's own replays of these commands, and anything not tagged, go to the engine)
		if tag == nil or src:find("mpfever", 1, true) or (C.ROLE ~= "host" and C.ROLE ~= "client") then return origSend(cmd, cb, ...) end
		local file = src:match("([^/]*)$") or src
		local okT, now = pcall(gameTime)
		now = okT and now or 0
		if not seen[file .. tag.name] then
			seen[file .. tag.name] = true
			log("mod command " .. tag.name .. " from " .. file .. " (" .. src:sub(1, 120) .. ") at t=" .. tostring(now) .. ": "
				.. (C.ROLE == "host" and "shipped from the host's game" or "dropped here, the host's game sends it"))
		end
		if C.ROLE == "host" then
			local okm, margs = pcall(function()
				local r = { n = tag.args.n }
				for i = 1, tag.args.n do r[i] = C.marshal(tag.args[i]) end
				return r
			end)
			if not okm then
				log("mod command " .. tag.name .. " from " .. file .. " cannot be shipped (" .. tostring(margs) .. "): applied here only (desync risk)")
				return origSend(cmd, cb, ...)
			end
			C.appendFile(C.DIR .. BS .. "sim_mods.log", C.line("mod_req", { fn = tag.name, args = margs, mod = file, t = now }))
		else
			dropped = dropped + 1
			if dropped % 200 == 0 then log("mod commands dropped here so far: " .. dropped) end
		end
		if cb then pcall(cb, nil, true, {}) end
	end
	log("mod commands intercepted in the simulation (" .. C.ROLE .. ")")
end

-- A build replayed here for another player is announced by the engine to every script as made by a player (the replays
-- pass playerInitiated, as the tools do). Mods that answer a player's build with builds of their own (Auto Signals adds
-- signals after a signal is placed) then did it on every game, and each game shipped its own: the signals were built
-- several times. The mods' scripts (not the game's own, whose town reputation counts replayed builds too) are told that
-- such a build was not made by a player here. (MPFEVER_MODEVENTS=0: not changed)
function DET.wrapModEvents()
	if os.getenv("MPFEVER_MODEVENTS") == "0" or type(game) ~= "table" or not C.ACTIVE then return end
	for k, v in pairs(game) do
		if type(k) == "string" and type(v) == "table" and type(v.handleEvent) == "function" and not v.__mpfEv
			and k:sub(1, 3) ~= "::/" and not k:find("mpfever", 1, true) then
			v.__mpfEv = true
			local orig = v.handleEvent
			v.handleEvent = function(u, st, src, id, name, param, ...)
				if name == "onPostBuildProposal" and SIM.replayBuildAt ~= nil and type(param) == "table" and param[4] then
					local okT, now = pcall(gameTime)
					if okT and now == SIM.replayBuildAt then
						local p2 = {}
						for i, x in pairs(param) do p2[i] = x end
						p2[4] = false
						SIM.modEvTold = (SIM.modEvTold or 0) + 1
						if SIM.modEvTold <= 10 then log("replayed build at t=" .. tostring(now) .. " announced to " .. k .. " as not made by a player here") end
						return orig(u, st, src, id, name, p2, ...)
					end
				end
				return orig(u, st, src, id, name, param, ...)
			end
			log("mod script events watched: " .. k)
		end
	end
end

-- Diagnostic (MPFEVER_EVSTEPLOG=1, tests): the step at which the contracts' script receives each engine event ("evstep <name>
-- t=<time> n=<entries>"), to compare two games: does an event reach the scripts at the same step on every game, whatever the
-- engine's batches? (a contract completed one step apart on two games, 2026-10-27, tests 522 and 525)
SIM.evStepInstall = function()
	local sub = type(game) == "table" and game["::/game_mechanics/subventions/subventions.script"]
	if type(sub) ~= "table" or type(sub.handleEvent) ~= "function" or sub.__mpfEvStep then return end
	sub.__mpfEvStep = true
	local oh, ou = sub.handleEvent, sub.update
	local function t()
		local ok, gt = pcall(function() return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime end)
		return ok and gt or -1
	end
	sub.handleEvent = function(u, st, src, id, name, param, ...)
		if id ~= "Subvention" then log("evstep " .. tostring(name) .. " t=" .. tostring(t()) .. " n=" .. tostring(type(param) == "table" and #param or "-")) end
		return oh(u, st, src, id, name, param, ...)
	end
	if type(ou) == "function" then
		sub.update = function(u, st, dt, ...)
			SIM.evUp = (SIM.evUp or 0) + 1
			if SIM.evUp % 20 == 1 then log("evstep update t=" .. tostring(t()) .. " dt=" .. tostring(dt) .. " #" .. SIM.evUp) end
			return ou(u, st, dt, ...)
		end
	end
	log("evstep: the contracts' script events are logged with their step")
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

-- Shared stations: the vehicles of a company stopping at a station of another company whose rule is a toll pay the fee set by its
-- owner (per stop), booked to both companies. Every few steps: the lines using such stations, their vehicles' next stop (a vehicle
-- whose next stop moved on has left the stops in between): see mpfever_eco.lua's stationFees (0.5.2; it was here before, it reads
-- the stations' rules there). In the finance window (0.5.0): the line's company pays them as station upkeep of its vehicles'
-- carrier, the station's company earns them as revenue of that carrier (before: one sum per company under « Other »).
-- MPFEVER_FEEOTHER=1: as before.
-- the journal's carrier of a vehicle's carrier (api.type.enum.Carrier, as the game's achievements read it)
SIM.journalCarrier = function(carrier)
	local JC = api.type.JournalEntry.Carrier
	local ok, EC = pcall(function() return api.type["enum"].Carrier end)
	if ok and EC then
		for _, n in ipairs({ "ROAD", "RAIL", "TRAM", "AIR", "WATER" }) do
			if carrier == EC[n] then return JC[n] end
		end
	end
	return JC.OTHER
end
local function chargeShares(st, dt)
	local reg = st.co
	if not (reg and reg.mode == "separate" and #(reg.list or {}) > 1 and dt and dt > 0) then return false end
	-- (on the game time, not on a counter: the simulation may run this script in several Lua states, each with its own counters,
	-- and every game must book the fees at the same steps)
	local stepNo = math.floor(gameTime() / STEP + 0.5)
	if stepNo % 5 ~= 0 then return false end
	-- (the same module on every game: without it, which never happens with MPFever's files in place, no fee is booked anywhere)
	local eco = C.eco()
	if not eco then
		if not SIM.feesNoEco then SIM.feesNoEco = true; log("companies: station fees: mpfever_eco.lua is not loaded, no fee is booked") end
		return false
	end
	local owed, changed = eco.stationFees(st, SIM.ecoEnv(), SIM)
	if #owed == 0 then return changed end
	local JE = api.type.JournalEntry
	local plain = os.getenv("MPFEVER_FEEOTHER") == "1"
	-- (one entry per company, way and carrier, booked in the order of their keys: the same on every game)
	local sums, order = {}, {}
	local function add(co, way, carrier, amount)
		local k = string.format("%04d %s %s", co, way, plain and "-" or tostring(carrier or "-"))
		if not sums[k] then sums[k] = { co = co, way = way, carrier = carrier, amount = 0 }; order[#order + 1] = k end
		sums[k].amount = sums[k].amount + amount
	end
	reg.shareIncome = reg.shareIncome or {}
	reg.shareExpense = reg.shareExpense or {}
	for _, o in ipairs(owed) do
		add(o.from, "pay", o.carrier, -o.fee)
		add(o.to, "earn", o.carrier, o.fee)
		reg.shareIncome[tostring(o.to)] = (reg.shareIncome[tostring(o.to)] or 0) + o.fee
		reg.shareExpense[tostring(o.from)] = (reg.shareExpense[tostring(o.from)] or 0) + o.fee
	end
	table.sort(order)
	for _, k in ipairs(order) do
		local b = sums[k]
		local c = CO.find(reg, b.co)
		if c and c.ent and b.amount ~= 0 then
			local entry = JE.new()
			entry.amount = b.amount
			entry.time = -1
			if plain then
				entry.category.type = JE.Type.OTHER
			elseif b.way == "earn" then
				entry.category.type = JE.Type.INCOME
				entry.category.carrier = b.carrier or JE.Carrier.OTHER
			else
				entry.category.type = JE.Type.MAINTENANCE
				entry.category.maintenance = JE.Maintenance.INFRASTRUCTURE
				entry.category.construction = JE.Construction.STATION
				entry.category.carrier = b.carrier or JE.Carrier.OTHER
			end
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

-- what mpfever_eco.lua needs from here
SIM.ecoEnv = function()
	if not SIM.eco then
		SIM.eco = { log = log, CO = CO, R = R, STEP = STEP, gameTime = gameTime, journalCarrier = SIM.journalCarrier, loanTable = coLoanTable,
			payBack = function(loan) local M = loanMods(); return M and M.lu.getFullLoanAndInterestPayBack(loan) or 0 end }
	end
	return SIM.eco
end

-- (0.6) The game options (mpfever_feat.lua, docs/FEATURES-0.6.md), the simulation's side: what the modules get from here (the
-- module's env is made of it, see F.simEnv) and the hooks below. None of them runs while no option is on: SIM.featOn is read from
-- the state at the top of every update (st.optsText, the options every game applied from the host's f_opts). MPFEVER_FEAT=0:
-- never (K.FEAT).
SIM.featBridge = function()
	if not SIM.featB then
		SIM.featB = { log = log, gameTime = gameTime, STEP = STEP, R = R, CO = CO,
			money = function(ent)
				local ok, b = pcall(api.engine.util.finance.getPlayersBalance, ent)
				return (ok and type(b) == "number") and b or nil
			end,
			-- (money added to or taken from a company, from an event: the same entry on every game, as a gift between companies;
			-- kind "subsidy": a SUBSIDY entry, as the game's own subsidies book their money, subvention_util.applyBonusMalus)
			book = function(ent, amount, who, kind)
				amount = math.floor((tonumber(amount) or 0) + 0.5)
				if not ent or amount == 0 then return false end
				local e = api.type.JournalEntry.new()
				e.amount = amount
				e.time = -1
				e.category.type = kind == "subsidy" and api.type.JournalEntry.Type.SUBSIDY or api.type.JournalEntry.Type.OTHER
				coBook(ent, e)
				log("options (" .. tostring(who) .. "): " .. amount .. " booked to player entity " .. tostring(ent) .. (kind and (" (" .. tostring(kind) .. ")") or ""))
				return true
			end,
			-- (the companies, sorted by number: those of the registry in the separate mode, the one company of the co-op else)
			companies = function(st)
				local out = {}
				local reg = st and st.co
				if type(reg) == "table" and reg.mode == "separate" then
					for _, c in ipairs(reg.list or {}) do
						if c.ent and not c.gone then
							local mem = {}
							for _, m in ipairs(CO.members(c)) do mem[#mem + 1] = m.key end
							out[#out + 1] = { id = c.id, ent = c.ent, name = c.name or "", ai = tostring(c.key or ""):sub(1, 3) == "ai:", members = mem }
						end
					end
					table.sort(out, function(x, y) return x.id < y.id end)
				else
					local ok, p = pcall(api.engine.util.getPlayer)
					if ok and p then out[1] = { id = 1, ent = p, name = "", ai = false, members = {} } end
				end
				return out
			end,
			-- (the game month, as mpfever_eco.lua counts it: the game time over a month's duration)
			month = function()
				local ok, d = pcall(api.util.getDefaultMonthDuration)
				if ok and type(d) == "number" and d > 0 then return math.floor(gameTime() / d) end
				return nil
			end,
			date = function()
				local ok, d = pcall(function()
					local x = api.engine.util.getCalendarDate(gameTime())
					return { year = x.year, month = x.month, day = x.day }
				end)
				return ok and d or nil
			end,
			-- (a company's lots, as its auction would list them: mpfever_eco.lua's E.lotsOf; nil without it)
			lots = function(st, id)
				local E, reg = C.eco(), st and st.co
				local c = E and E.lotsOf and type(reg) == "table" and CO.find(reg, tonumber(id)) or nil
				if not (c and c.ent) then return nil end
				return E.lotsOf(SIM.ecoEnv(), c)
			end,
			-- (a lot of company fromId to company toId, as an auction's lot sold, with the stations of a line's stops (lot.withStations)
			-- and the constructions' own tracks (lot.frozen): mpfever_eco.lua's E.transferLot. How many entities change hands, or nil
			-- and why. Money is not booked here: the module books it)
			transferLot = function(st, fromId, toId, lot)
				local E, reg = C.eco(), st and st.co
				if not (E and E.transferLot) then return nil, "mpfever_eco.lua has no transfer" end
				local from = type(reg) == "table" and CO.find(reg, tonumber(fromId)) or nil
				local to = type(reg) == "table" and CO.find(reg, tonumber(toId)) or nil
				if not (from and from.ent and to and to.ent) then return nil, "a company has no player entity on this game" end
				return E.transferLot(SIM.ecoEnv(), from, to, lot, { withStations = lot.withStations == true, frozen = lot.frozen == true, reg = reg })
			end,
			-- (company fromId goes into company intoId, the merge of companies with the option's opts, see E.coMerge; from an event:
			-- the same step on every game. The state is saved by handleEvent after the event)
			coMerge = function(st, fromId, intoId, opts)
				local E = C.eco()
				if not (E and E.coMerge) then return false, "mpfever_eco.lua not loaded" end
				return E.coMerge(st, fromId, intoId, SIM.ecoEnv(), opts)
			end,
		}
	end
	return SIM.featB
end
-- every step (update): each module's month and tick; the state is saved only when one of them changed it
SIM.featTick = function(state)
	local F = C.feat()
	local st = state:get()
	if not (F and type(st) == "table") then return end
	if F.simTick(st, SIM.featBridge()) then state:set(st) end
end
-- an MPFever event "f_..." (handleEvent saves the state after it)
SIM.featEvent = function(st, name, param)
	if name == "f_me" then
		-- (this game's session name, from its own interface: never another game's, whose events carry their sender, see
		-- executeActionOnce; for this game's own builds, see SIM.featWho)
		if type(param) == "table" and param.mpfFrom == nil and type(param.name) == "string" then SIM.featMe = param.name end
		return
	end
	local F = C.feat()
	if not F then
		if not SIM.featMissing then SIM.featMissing = true; log("options: mpfever_feat.lua is not loaded: event " .. tostring(name) .. " ignored") end
		return
	end
	F.simEvent(st, name, param, SIM.featBridge())
end
-- an action applied by the simulation (simApplyDue saves the state after it), with the modules' copies of it taken before it was
-- applied (SIM.featDg, see SIM.featDigests)
SIM.featAction = function(st, a, ok)
	local F = C.feat()
	if F then F.simAction(st, a, ok, SIM.featBridge(), SIM.featDg) end
end
-- what the modules on keep of an action before it is applied (its references are then translated in place, see F.digests); nil
-- when none takes a copy
SIM.featDigests = function(st, a)
	local F = C.feat()
	return F and F.digests(st.optsText, a) or nil
end
-- the captures of this game so far (before a tool's build is captured, see SIM.featNative); nil when the state cannot be read
SIM.featSeq = function(state)
	local ok, st = pcall(function() return state:get() end)
	if not ok then return nil end
	return type(st) == "table" and tonumber(st.outSeq) or 0
end
-- A tool's build, at the step the engine applies it: the builder's own (captured, so shipped to the others: seq0 tells) and the
-- replay of another player's (see captureNativeBuild), so every game hears the same builds at the same steps. What the simulation
-- does not know here, it does not say: who built it (a company's build carries its player entity in the proposal).
SIM.featNative = function(state, param, seq0)
	local st = state:get()
	if type(st) ~= "table" or st.solo then return end
	local now = gameTime()
	local own = seq0 ~= nil and (tonumber(st.outSeq) or 0) > seq0
	if not (SIM.replayBuildAt == now or own) then return end
	local F = C.feat()
	if not F then return end
	local a = { fn = "nativeBuild", native = true, at = now, proposal = param[1], data = param[2] }
	-- (who built it and what it cost its builder, when known: see SIM.featWho)
	pcall(SIM.featWho, st, a, own, now)
	if F.simAction(st, a, true, SIM.featBridge()) then state:set(st) end
end
-- The builder of a tool's build and its cost, the same on every game (a.origin, a.cost, a.co; a.uid for a replay): this game's own
-- build, the capture just made (its cost as shipped, REFUND.costOf; its builder this game's player under its session name, as the
-- others name it, told by the interface: f_me, see G.featGui; its company the one its owner references name: a computer
-- company's build is captured on the host's game too); another player's, the last announcement of a shipped build at this step
-- (replay_cost: its uid "<player>:<n>", its builder's cost and company), heard once (a replay of several proposals is one build).
-- Nothing when the cost was not shipped (MPFEVER_NOREFUND=1) or the name is not known yet.
SIM.featWho = function(st, a, own, now)
	if own then
		local o = type(st.out) == "table" and st.out[#st.out] or nil
		if not (o and o.n == st.outSeq and o.at == now) then return end
		if not SIM.featMe then
			if not SIM.featMeMissing then SIM.featMeMissing = true; log("options: this game's session name is not known yet: its build at t=" .. now .. " has no builder for the options") end
			return
		end
		a.origin, a.cost = SIM.featMe, o.cost
		if type(st.co) == "table" and st.co.mode == "separate" then a.co = SIM.featBuildCo(o.args) end
		return
	end
	local rc = type(st.rcost) == "table" and st.rcost[#st.rcost] or nil
	if not (rc and rc.at == now and not rc.heard) then return end
	rc.heard = true
	a.uid, a.cost, a.co = rc.uid, rc.cost, rc.co
	a.origin = type(rc.uid) == "string" and rc.uid:match("^(.*):%d+$") or nil
end
-- the company a captured build's owner references name most (as the capture's log counts them), nil for none
SIM.featBuildCo = function(args)
	local tally, seen = {}, 0
	local function walk(t, depth)
		if type(t) ~= "table" or depth > 7 or seen > 20000 then return end
		seen = seen + 1
		if t.k == "player" and type(t.co) == "number" then tally[t.co] = (tally[t.co] or 0) + 1 end
		for _, v in pairs(t) do if type(v) == "table" then walk(v, depth + 1) end end
	end
	pcall(walk, args, 0)
	local best, n = nil, 0
	for co, k in pairs(tally) do if k > n or (k == n and co < best) then best, n = co, k end end
	return best
end
-- whether a module on hears the game's own script events (and the modules loaded, with this log, at the first look); st: the
-- state of this step (a module may have nothing to hear now, see F.hearsGameEvents)
SIM.featHearing = function(text, st)
	local F = C.feat()
	if not F then return false end
	F.load(log)
	return F.hearsGameEvents(text, st)
end
-- the game's own script events, for the modules that hear them (SIM.featHears)
SIM.featGameEvent = function(state, src, id, name, param)
	local F = C.feat()
	-- (the state is read only for an event some module on hears by its name, see M.GAME_EVENTS: the game sends many)
	if F and F.wantsGameEvent and SIM.featText and not F.wantsGameEvent(SIM.featText, name) then return end
	local st = state:get()
	if not (F and type(st) == "table") then return end
	if F.simGameEvent(st, id, name, param, SIM.featBridge(), src) then state:set(st) end
end

local function update(userParams, state, dt)
	if not C.ACTIVE then return end
	pcall(function()
		local st0 = state:get()
		SIM.coRegistry = st0 and st0.co or nil
		-- (0.6) whether a game option is on (st.optsText, the options every game applied from the host's f_opts): the only thing of
		-- them read while none is on (see SIM.featBridge)
		SIM.featOn = K.FEAT and type(st0) == "table" and type(st0.optsText) == "string" and st0.optsText ~= ""
		SIM.featHears = SIM.featOn and SIM.featHearing(st0.optsText, st0)
		SIM.featText = SIM.featOn and st0.optsText or nil
		-- (again from time to time: the game loads the script of a type of contract when it first needs it)
		SIM.ctTick = (SIM.ctTick or 0) + 1
		if SIM.ctTick % 50 == 1 and os.getenv("MPFEVER_EVSTEPLOG") == "1" then pcall(SIM.evStepInstall) end
		if SIM.coRegistry and SIM.coRegistry.mode == "separate" and SIM.ctTick % 50 == 1 then
			CO.installContracts({ log = log, registry = function() return SIM.coRegistry end, localCo = simLocalCo })
		end
		-- (at every step, so that every game wraps the companies script at the same step: its prospections run per company from
		-- then on, and a game wrapping it later kept a different state for a while, "script:company" in the checks)
		if SIM.coRegistry and SIM.coRegistry.mode == "separate" and os.getenv("MPFEVER_NOCOACTIONS") ~= "1" then
			SIM.coActEnv = SIM.coActEnv or { log = log, registry = function() return SIM.coRegistry end }
			CO.installCompanyActions(SIM.coActEnv)
		end
	end)
	if os.getenv("MPFEVER_CPROBE") then local okp, errp = pcall(contractProbe) if not okp then log("PROBE failed: " .. tostring(errp)) end end
	-- The game mechanics scripts (contracts, loans, weather, industries, towns...) draw random numbers from the Lua
	-- generator, which is not part of the savegame and differs between games: reseeded from the game time at every
	-- simulation step, every game draws the same numbers.
	-- (scripts that kept the engine's own function draw from it: reseeded every step)
	pcall(function() if DET.seed and math.randomseed == DET.seed then DET.origSeed(gameTime()) else math.randomseed(gameTime()) end end)
	installRandom()
	pcall(DET.installModCmds)
	SIM.evTick = (SIM.evTick or 0) + 1
	if SIM.evTick % 50 == 1 then pcall(DET.wrapModEvents) end
	-- (how many engine events this script receives, every one of them: see subscribeToAllEvents below)
	-- (and how big the state the engine walks at every state:get() is, by its largest parts)
	if SIM.evTick % 3000 == 0 then
		local sizes = {}
		pcall(function()
			local function count(t, seen)
				if seen[t] then return 0 end
				seen[t] = true
				local n = 0
				for _, v in pairs(t) do n = n + 1; if type(v) == "table" then n = n + count(v, seen) end end
				return n
			end
			local st, seen, total = state:get() or {}, {}, 0
			for k, v in pairs(st) do
				local n = type(v) == "table" and count(v, seen) + 1 or 1
				total = total + n
				sizes[#sizes + 1] = { k = tostring(k), n = n }
			end
			table.sort(sizes, function(a, b) return a.n > b.n end)
			for i = #sizes, 5, -1 do sizes[i] = nil end
			for i, s in ipairs(sizes) do sizes[i] = s.k .. " " .. s.n end
			table.insert(sizes, 1, total .. " entries")
		end)
		log(string.format("events received: %.1f per update; state: %s", (SIM.evN or 0) / 3000, table.concat(sizes, ", ")))
		SIM.evN = 0
	end
	if not SIM.subscribed then
		SIM.subscribed = true
		pcall(function() state:subscribeToAllEvents() end)
	end
	local ok, err = pcall(simApplyDue, state)
	if not ok then log("simulation apply failed: " .. tostring(err)) end
	if SIM.idChecks then pcall(SIM.idResolve, state, false) end
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
	-- the months in debt, the bankruptcies, the tolls (mpfever_eco.lua)
	local oke, erre = pcall(function()
		local st = state:get()
		if st and st.co and st.co.mode == "separate" and dt and dt > 0 and C.eco() then
			if C.eco().tick(st, SIM.ecoEnv()) then state:set(st) end
		end
	end)
	if not oke then log("companies: economy failed: " .. tostring(erre)) end
	-- (0.6) the game options' modules, their month and their tick (mpfever_feat.lua): nothing while no option is on
	if SIM.featOn then
		local okF, errF = pcall(SIM.featTick, state)
		if not okF then log("options: tick failed: " .. tostring(errF)) end
	end
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

-- A build that only takes groups of trees away: the bulldozer on every tree of a group, or on a group of one tree, adds nothing
-- back (on some trees of a group it adds the others back in a construction without a file: the asset branch of
-- captureNativeBuild). Nothing else in it: no street, no terrain, no construction removed.
SIM.treeRemovalOnly = function(proposal)
	local ok, yes = pcall(function()
		local n = #proposal.toRemove
		if n == 0 then return false end
		local pr = nil
		pcall(function() pr = proposal.parcelsToRemove end)
		if pr ~= nil and #pr > 0 then return false end
		local g = nil
		pcall(function() g = proposal.terrain.baseHeightMod end)
		if g and (g.width or 0) * (g.height or 0) > 0 then return false end
		local sp = proposal.proposal
		for _, k in ipairs({ "addedNodes", "removedNodes", "addedSegments", "removedSegments", "edgeObjectsToAdd", "edgeObjectsToRemove", "nodeConfigsToAdd", "nodeConfigsToRemove" }) do
			local v = sp[k]
			if v ~= nil and #v > 0 then return false end
		end
		for i = 1, n do
			if not R.isTreeGroup(proposal.toRemove[i]) then return false end
		end
		return true
	end)
	return ok and yes == true
end

-- (diagnostic) a removed entity the capture could not describe: its components and its numbers of fat and thin models
SIM.assetDiag = function(e, why)
	log("ASSETS: removal " .. tostring(e) .. " " .. tostring(why) .. ": " .. R.assetComponents(e))
end

-- The town statistics of a build: what the game's towns script takes from every player's build (towns.script onPreBuildProposal ->
-- town_util.getProposalStats): the terrain alignment volumes added and removed, the trees and rocks the engine takes away (auto
-- removal), the terrain brush's volumes and the volume of new tunnels, each summed over the towns. A replay that gives the towns
-- other numbers than the builder's build gave its own makes the towns drift apart: script:towns at the next checks, then a
-- resynchronisation 30 to 140 s later (a stop placed on a bridge, replayed with 77.517/117.783 of terrain alignment against the
-- builder's 0/0, 2026-10-25). The builder ships them with its build (ts, next to its cost); each replaying game adds up its own
-- replay's proposals (SIM.townAdd) and, when they differ, asks for a resynchronisation at once (SIM.townClose, G.townDiffs). Not
-- the money (a replay's cost may differ, REFUND books that), nor the town buildings taken away (town streets: the engine puts them
-- back itself). MPFEVER_ALIGNCHECK=0: off (nothing shipped, nothing compared). Never part of the simulation: only a message to
-- the host.
-- Only the proposals of the announced replay are added up: each of its "replaying" events carries the mark of its announcement
-- (tok, see G.townExpect), and the simulation adds a proposal to the open record only when the last "replaying" event before it
-- carried that record's mark. Before, every proposal taken as a replay at the record's game time was added: in a pause (the same
-- game time for minutes) a terrain edit near a town replayed after a road counted its brush volume into the road's record, and
-- the host reloaded every game although both builds were made exactly (a false "TOWN STATS DIFFER"). The replays that announce
-- nothing (terrain, trees, the edits from a window, the paused actions of scripts) are never added. MPFEVER_TOWNTAG=0: as before
-- (every replay at that game time added to the last record).
SIM.TOWNKEYS = { "al", "ar", "tr", "rk", "ba", "br", "tv" }
SIM.alignShip = os.getenv("MPFEVER_ALIGNCHECK") ~= "0"
SIM.townTag = os.getenv("MPFEVER_TOWNTAG") ~= "0"
SIM.townStats = function(proposal, data, pi)
	local t = { al = 0, ar = 0, tr = 0, rk = 0, ba = 0, br = 0, tv = 0 }
	-- (a build not initiated by a player: the towns script takes nothing from it)
	if pi == false then return t end
	local U = api.engine.util.town or {}
	-- (a value that cannot be read is left out, and then never compared)
	local function sum(fn, arg, ka, kb)
		local ok, r = pcall(fn, arg)
		if not (ok and type(r) == "table") then t[ka], t[kb] = nil, nil return end
		for _, v in pairs(r) do
			t[ka] = t[ka] + (tonumber(v[1]) or 0)
			t[kb] = t[kb] + (tonumber(v[2]) or 0)
		end
	end
	sum(U.getTerrainAlignmentImpact, data, "al", "ar")
	sum(U.getAutoRemovalEntityImpact, data, "tr", "rk")
	sum(U.getTerrainBrushVolumeImpact, proposal, "ba", "br")
	-- (the towns count what a build adds of tunnels beyond what it removes, never less than nothing)
	local okv, va, vr = pcall(SIM.tunnelVolume, proposal, data)
	if okv and type(va) == "number" and type(vr) == "number" then t.tv = math.max(0, va - vr) else t.tv = nil end
	return t
end

-- The volume of the tunnels a build adds and removes, as town_util.getProposalStats measures it (its getBaseParallelStripVolume:
-- length x width x height of each strip whose first edge is a tunnel), without the towns' share by distance
SIM.tunnelVolume = function(proposal, data)
	local BE = api.type.ComponentType.BASE_EDGE
	local added = {}
	local sp = proposal.proposal
	for i = 1, sp.addedSegments_native:size() do
		local s = sp.addedSegments_native:at(i)
		added[s.entity] = s.comp
	end
	local function edgeOf(e)
		if e >= 0 then return api.engine.getComponent(e, BE) end
		return added[e]
	end
	local function len(be)
		local p, q = be.position0, be.position1
		return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
	end
	local function volume(strip)
		local v, width, height = 0, 0, 0
		local groups = strip.rangeGroups_native
		for i = 1, groups:size() do
			local g = groups:at(i)
			local first = edgeOf(g:at(1).edge)
			if not first then return 0 end
			if i == 1 then
				if first.type ~= 2 then return 0 end
				local tun = api.res.tunnelTypeRep.get(first.typeIndex)
				if not tun then return 0 end
				local w = 0
				for k = 1, first.laneConfigs_native:size() do w = w + first.laneConfigs_native:at(k).width end
				if g:size() == 1 then width = w + 2 * tun.padding else width = w * g:size() + 2 * tun.padding + (g:size() - 1) * first.distance end
				height = tun.height
			end
			local l = len(first) * math.abs(g:at(1).bounds[1] - g:at(1).bounds[2])
			if g:size() > 1 then
				local last = edgeOf(g:at(g:size()).edge)
				if last then l = (l + len(last) * math.abs(g:at(g:size()).bounds[1] - g:at(g:size()).bounds[2])) / 2 end
			end
			v = v + l * width * height
		end
		return v
	end
	local va, vr = 0, 0
	local pp = data.parallelProposal
	for i = 1, pp.toAdd_native:size() do va = va + volume(pp.toAdd_native:at(i)) end
	for i = 1, pp.toRemove_native:size() do
		local s = api.engine.getComponent(pp.toRemove_native:at(i), api.type.ComponentType.BASE_PARALLEL_STRIP)
		if s then vr = vr + volume(s) end
	end
	return va, vr
end

-- (event replay_stats, from G.townExpect) a replay about to be applied here, with its builder's town statistics: the replays
-- before it are all applied, they are compared now
SIM.townExpect = function(st, p)
	SIM.townDue(st, gameTime(), true)
	if type(p) ~= "table" or type(p.ts) ~= "table" then return end
	local got = {}
	for _, k in ipairs(SIM.TOWNKEYS) do got[k] = 0 end
	st.rstats = st.rstats or {}
	st.rstats[#st.rstats + 1] = { at = gameTime(), uid = p.uid, tok = p.tok, exp = p.ts, got = got, n = 0 }
	while #st.rstats > 8 do table.remove(st.rstats, 1) end
end

-- (captureNativeBuild) one proposal applied here for the replay announced last, at its time; tok: the mark of the last "replaying"
-- event, which must be that replay's (see SIM.townTag)
SIM.townAdd = function(st, now, ts, tok)
	local rs = st.rstats and st.rstats[#st.rstats]
	if not rs or rs.at ~= now or type(ts) ~= "table" then return end
	if SIM.townTag and (rs.tok == nil or tok ~= rs.tok) then return end
	rs.n = rs.n + 1
	for _, k in ipairs(SIM.TOWNKEYS) do
		if rs.got[k] ~= nil and type(ts[k]) == "number" then rs.got[k] = rs.got[k] + ts[k] else rs.got[k] = nil end
	end
end

-- the replays whose builds are applied (an earlier game time, or all of them): their statistics against the builder's
SIM.townDue = function(st, now, all)
	if not st.rstats or #st.rstats == 0 then return false end
	local keep = {}
	for _, rc in ipairs(st.rstats) do
		if all or rc.at < now then
			local ok, err = pcall(SIM.townClose, st, rc)
			if not ok then log("town stats of build " .. tostring(rc.uid) .. " not compared: " .. tostring(err)) end
		else
			keep[#keep + 1] = rc
		end
	end
	local closed = #keep ~= #st.rstats
	st.rstats = #keep > 0 and keep or nil
	return closed
end

SIM.townClose = function(st, rc)
	-- (nothing applied here: a refused replay asks for the resynchronisation itself)
	if (rc.n or 0) == 0 or type(rc.exp) ~= "table" or type(rc.got) ~= "table" then return end
	local diffs, shown = {}, {}
	for _, k in ipairs(SIM.TOWNKEYS) do
		local e, g = tonumber(rc.exp[k]), tonumber(rc.got[k])
		if e and g then
			-- (the same proposal gives the same numbers on every game: the native replays of two bridges on 2026-10-25 gave their
			-- builder's to the last digit; a relative margin for the big volumes)
			local tol = math.max(0.05, 1e-5 * math.max(math.abs(e), math.abs(g)))
			if math.abs(e - g) > tol then diffs[#diffs + 1] = string.format("%s %.3f/%.3f", k, e, g) end
			if e ~= 0 or g ~= 0 then shown[#shown + 1] = string.format("%s %.3f", k, g) end
		end
	end
	if #diffs == 0 then
		if #shown > 0 then log("town stats of build " .. tostring(rc.uid) .. " as the builder's (" .. rc.n .. " proposal(s) here): " .. table.concat(shown, ", ")) end
		return
	end
	local why = "town stats differ (builder/here): " .. table.concat(diffs, ", ")
	log("TOWN STATS DIFFER for build " .. tostring(rc.uid) .. " (" .. rc.n .. " proposal(s) here): " .. table.concat(diffs, ", ")
		.. " (al/ar terrain alignment added/removed, tr/rk trees/rocks taken away, ba/br terrain brush, tv tunnels)")
	st.townDiffs = st.townDiffs or {}
	st.townDiffs[#st.townDiffs + 1] = { uid = rc.uid, tok = rc.tok, at = rc.at, why = why:sub(1, 110) }
	while #st.townDiffs > 8 do table.remove(st.townDiffs, 1) end
end

-- the build ids of the builds applied before ("build ids", part buildIds), read two steps after each build or, at the latest,
-- when a later build is about to be applied (force): at x4 the script runs once per batch of steps, and one game read after
-- the next build had split a segment (-1) while the other read before it (towncross with the builder leading, 2026-10-27).
-- MPFEVER_IDREADEARLY=0: only two steps after, as before.
SIM.idResolve = function(state, force)
	if not SIM.idChecks then return end
	local keep = {}
	-- (read two steps after the build, at that game time on every game: read two script updates after it, one game read
	-- after the next build had removed the segment (-1) and the other before, a false "buildIds" difference, 2026-10-25)
	local okT, tCk = pcall(gameTime)
	for _, ck in ipairs(SIM.idChecks) do
		ck.ticks = ck.ticks + 1
		if okT and (tCk >= ck.at + 2 * STEP or (force and ck.at <= tCk)) then
			local si, ni = R.idsAt(ck.segs, ck.nodes)
			-- (and how many of its new nodes have a node configuration: issue #50's drift, nodeConfigs 7418 / 7420 after
			-- a station of 200 nodes, compares here between the builder's game and the others)
			local cfg = 0
			for _, n in ipairs(ni) do
				if type(n) == "number" and n >= 0 then
					local okc, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
					if okc and nc then cfg = cfg + 1 end
				end
			end
			log("build ids t=" .. ck.at .. ": segments " .. table.concat(si, ",") .. " nodes " .. table.concat(ni, ",") .. " (node configurations " .. cfg .. ")")
			-- (and summed for the checks, part "buildIds": every game gives a build the same ids, or the games went apart
			-- right there - an entity one game made and not the other, 2026-10-25 11:03 - long before it shows elsewhere. In
			-- the simulation's state: the script runs in more than one Lua state, and the interface's checks read it too)
			local okI, errI = pcall(function()
				local st = state:get() or {}
				local b = type(st.buildIds) == "table" and st.buildIds or {}
				b.n0, b.s0 = tonumber(b.n0) or 0, tonumber(b.s0) or 0
				local list = type(b.list) == "table" and b.list or {}
				list[#list + 1] = { at = ck.at, h = C.hashStr(0, ck.at .. ":" .. table.concat(si, ",") .. "|" .. table.concat(ni, ",")) }
				-- (the old ones folded into one sum: the checks count them all the same)
				local keep, old = {}, gameTime() - 600 * STEP
				for _, e in ipairs(list) do
					if (tonumber(e.at) or 0) <= old then b.n0 = b.n0 + 1; b.s0 = (b.s0 + (tonumber(e.h) or 0)) % 4294967296 else keep[#keep + 1] = e end
				end
				b.list = keep
				b.n, b.sum = nil, nil
				st.buildIds = b
				state:set(st)
			end)
			if not okI then log("build ids sum: " .. tostring(errI)) end
		else
			keep[#keep + 1] = ck
		end
	end
	SIM.idChecks = (#keep > 0) and keep or nil
end

local function captureNativeBuild(state, param)
	-- (before this build changes the world: the ids of the builds before it, see SIM.idResolve)
	if SIM.idChecks and os.getenv("MPFEVER_IDREADEARLY") ~= "0" then pcall(SIM.idResolve, state, true) end
	local st = state:get() or {}
	-- (a game without a lobby sends its builds to nobody: they are not kept, see H.solo)
	if st.solo then SIM.replayBuildAt = nil; return end
	R.CO = st.co
	local now = gameTime()
	SIM.replayBuildAt = nil   -- (see DET.wrapModEvents)
	-- (the build's town statistics, see SIM.townStats)
	local tstats = nil
	if SIM.alignShip then
		local okS, ts = pcall(SIM.townStats, param[1], param[2], param[4])
		if okS then tstats = ts else log("town stats not read: " .. tostring(ts)) end
	end
	-- diagnostic: what the game's town script takes from every player build (town reputation, see town_util.getProposalStats)
	-- and what it costs, on the builder's game and on the replaying ones alike: a replay that differs here makes the towns
	-- (script:towns) and the money drift apart
	pcall(function()
		local proposal, data, pi = param[1], param[2], param[4]
		if pi == false then return end
		local function impact(fn)
			local a, r, n = 0, 0, 0
			local okI, t = pcall(fn, data)
			if okI and type(t) == "table" then
				for _, v in pairs(t) do a = a + (v[1] or 0); r = r + (v[2] or 0); n = n + 1 end
			end
			return string.format("%.3f/%.3f/%d", a, r, n)
		end
		local tb, rem = 0, 0
		pcall(function()
			for i = 1, proposal.toRemove_native:size() do
				rem = rem + 1
				local c = api.engine.getComponent(proposal.toRemove_native:at(i), api.type.ComponentType.CONSTRUCTION)
				if c then tb = tb + #c.townBuildings end
			end
		end)
		local costs = "?"
		pcall(function() costs = tostring(data.costs) end)
		log("build stats t=" .. now .. ": costs " .. costs .. ", terrain alignment " .. impact(api.engine.util.town.getTerrainAlignmentImpact)
			.. ", auto removal " .. impact(api.engine.util.town.getAutoRemovalEntityImpact) .. ", removed " .. rem .. " (town buildings " .. tb .. ")")
	end)
	-- diagnostic: the ids this game gives to the new segments and nodes, logged once they exist ("build ids"). The same places
	-- must get the same ids on every game: a game that numbers them differently numbers everything after differently too
	-- (vehicles, people) and the games drift apart
	pcall(function()
		local sp = param[1].proposal
		local segs, nodes = {}, {}
		local function p3(v) return { x = v.x, y = v.y, z = v.z } end
		for i = 1, #sp.addedSegments do
			local c = sp.addedSegments[i].comp
			segs[i] = { p3(c.position0), p3(c.position1) }
		end
		for i = 1, #sp.addedNodes do nodes[i] = p3(sp.addedNodes[i].comp.position) end
		if #segs + #nodes > 0 then
			SIM.idChecks = SIM.idChecks or {}
			SIM.idChecks[#SIM.idChecks + 1] = { at = now, segs = segs, nodes = nodes, ticks = 0 }
		end
	end)
	if st.replay and st.replay.at == now and st.replay.n > 0 then
		st.replay.n = st.replay.n - 1     -- our own replay of a shipped action
		SIM.replayBuildAt = now
		-- (what it costs here, for the refund of a shipped native build: see REFUND.book)
		local rc = st.rcost and st.rcost[#st.rcost]
		local cl = REFUND.costOf(param)
		if rc and rc.at == now and cl then rc.got = (rc.got or 0) + cl; rc.n = (rc.n or 0) + 1 end
		-- (and its town statistics, against the builder's: see SIM.townStats; only for the replay announced, SIM.townTag)
		if tstats then pcall(SIM.townAdd, st, now, tstats, st.replay.tok) end
		-- (BUILDLEAD: a build this game released at once may land at this step too: taken for the replay, it would never be
		-- shipped. The interface avoids it (buildLeadState); this says when it happened anyway)
		if st.leadOut and #st.leadOut > 0 then
			log("BUILDLEAD WARNING: build at t=" .. tostring(now) .. " taken as a replay while a build released here at once (t="
				.. table.concat(st.leadOut, ",") .. ") is not captured yet: if it is the released one, the games now differ")
		end
		state:set(st)
		log("build at t=" .. tostring(now) .. " taken as a replay (" .. st.replay.n .. " more expected at this time)")
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
	-- The bulldozer on trees builds the same way: the group it took trees from is removed and its other trees are added back in one
	-- construction without a file. On every tree of a group (or on a group of one tree) it only removes the group: that build took
	-- the general path, where nothing removes a group of trees, and the other games kept it. It comes here too now, and so does a
	-- build of the mod's own asset construction made by a script (the treeerase autotest): the same trees for the other games.
	-- MPFEVER_ASSETCAPTURE=0: as before (constructions without a file only, at least one; removals described all in one go)
	local assetCap = os.getenv("MPFEVER_ASSETCAPTURE") ~= "0"
	local okA, assets = pcall(function()
		local n = #proposal.toAdd
		if n == 0 then return (assetCap and SIM.treeRemovalOnly(proposal)) and {} or nil end
		local list = {}
		for i = 1, n do
			local ce = proposal.toAdd[i]
			local f = tostring(ce.fileName)
			if f ~= "" and not (assetCap and R.isAssetFile(f)) then return nil end
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
			-- (the mod's construction with no model read here: the general path, the others would get a marker in its place)
			if f ~= "" and #models == 0 then return nil end
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
	if okA and assets and (#assets > 0 or assetCap) then
		local removed, lost = {}, 0
		if assetCap then
			-- (each removal on its own: one that cannot be described is logged with what it is made of, and shipped as lost, so that
			-- the other games resync at once instead of keeping it, see replayAssets. 0.5.1 dropped it without a word)
			local nrm = 0
			pcall(function() nrm = #proposal.toRemove end)
			-- (a group of trees described by a tree this build takes away, not by one it adds back: see R.describe's kept.
			-- MPFEVER_ASSETFELLED=0: as before, by its first tree)
			local kept = nil
			if nrm > 0 and os.getenv("MPFEVER_ASSETFELLED") ~= "0" then
				local okK, g = pcall(R.keptGrid, assets)
				if okK then kept = g else log("assets: the trees kept not read: " .. tostring(g):sub(1, 120)) end
			end
			for i = 1, nrm do
				local e = nil
				pcall(function() e = proposal.toRemove[i] end)
				local okd, d = pcall(R.describe, "con", e, kept)
				if okd and type(d) == "table" then
					d.__ref = true
					removed[#removed + 1] = d
				else
					lost = lost + 1
					pcall(SIM.assetDiag, e, okd and "not described" or ("describe failed: " .. tostring(d):sub(1, 120)))
				end
			end
		else
			pcall(function()
				for i = 1, #proposal.toRemove do
					local d = R.describe("con", proposal.toRemove[i])
					if d then d.__ref = true; removed[#removed + 1] = d end
				end
			end)
		end
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
		-- (every one that removes something: the bulldozer on trees, whose removal must be the same on every game)
		if st.assetBuilds <= 10 or #removed > 0 or lost > 0 then
			local first = assets[1] and assets[1].models[1] and assets[1].models[1].id
			log("assets placed at t=" .. now .. ": " .. #assets .. " construction(s), " .. nm .. " model(s) (" .. tostring(first) .. "...), " .. #removed .. " removed"
				.. (assetCap and (", " .. lost .. " not described") or ""))
		end
		st.out = st.out or {}
		st.outSeq = (st.outSeq or 0) + 1
		st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
			fn = "assetBuild", args = { assets = assets, toRemove = removed, lost = lost > 0 and lost or nil }, captured = now }
		if st.leadOut and #st.leadOut > 0 then table.remove(st.leadOut, 1) end   -- (BUILDLEAD: the released build, captured)
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
	-- MPFEVER_SLOWCAPTURE=<seconds> (tests): each capture takes that much longer, as a big build does (a street through a town
	-- that took 28 town buildings away: 1.7 s); the simulation stands still meanwhile, the interface runs on
	local slow = tonumber(os.getenv("MPFEVER_SLOWCAPTURE") or "")
	if slow and slow > 0 then
		while os.clock() - c0 < slow do end
		log("capture: held back " .. slow .. " s (MPFEVER_SLOWCAPTURE)")
	end
	local okc, compact = pcall(C.compactProposal, proposal)
	log("capture: compact " .. string.format("%.3f", os.clock() - c0) .. " s, " .. #C.ser(compact or {}) .. " bytes" .. C.mapSizes(compact))
	if not okc then
		log("native build capture failed at t=" .. now .. ": " .. tostring(compact) .. " (desync)")
		return
	end
	-- (diagnostic, MPFEVER_RAWBUILDS=1: the first native proposals in full. Dumping a big one took the capture 4 to 74 s on a
	-- large map while the simulation stood still: the build counted as refused, the others ran on and got it late)
	st.rawLogged = (st.rawLogged or 0) + 1
	if st.rawLogged <= 6 and os.getenv("MPFEVER_RAWBUILDS") == "1" then
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
	-- the same build as an action this game just applied, at the same moment: the engine's second application of it, which
	-- every game makes by itself (shipped, each game replayed the other's copy late)
	do
		local okg, sig = pcall(C.buildSig, compact)
		if okg and sig and st.replaySigs and st.replaySigs.at == now then
			for i, s in ipairs(st.replaySigs.list or {}) do
				if s == sig then
					-- (once: a third build alike at this time is the player's own)
					if os.getenv("MPFEVER_SIGCON") ~= "0" then table.remove(st.replaySigs.list, i) end
					log("build at t=" .. now .. ": the same as the action just applied here (the engine applies it again): not shipped")
					state:set(st)
					return
				end
			end
			log("capture: build " .. sig .. " differs from the action(s) applied at this time (" .. table.concat(st.replaySigs.list or {}, " ; ") .. ")")
		end
	end
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
	-- (ts: its town statistics, which the replaying games compare with their replay's, see SIM.townStats)
	st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
		fn = "makeWorldBuildProposalCmd", args = args, captured = now, ready = not hasObjects, cost = REFUND.on and REFUND.costOf(param) or nil,
		ts = tstats }
	if st.leadOut and #st.leadOut > 0 then table.remove(st.leadOut, 1) end   -- (BUILDLEAD: the released build, captured)
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
	SIM.evN = (SIM.evN or 0) + 1
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
		-- (0.6: this game's captures so far, to tell its own build shipped to the others, see SIM.featNative)
		local seq0 = SIM.featOn and SIM.featSeq(state) or nil
		local ok, err = pcall(captureNativeBuild, state, param)
		if not ok then log("onPreBuildProposal capture failed: " .. tostring(err)) end
		-- (0.6) the game options' modules hear the tools' builds, on every game at the build's step (nothing while no option is on)
		if SIM.featOn then
			local okF, errF = pcall(SIM.featNative, state, param, seq0)
			if not okF then log("options: onAction of a build failed: " .. tostring(errF)) end
		end
		return
	end

	if id ~= "mpfever" then
		-- (0.6) the game's own script events, for the game options' modules that hear them (nothing while no option is on)
		if SIM.featHears then
			local okF, errF = pcall(SIM.featGameEvent, state, src, id, name, param)
			if not okF then log("options: onGameEvent failed: " .. tostring(errF)) end
		end
		return
	end
	local ok, err = pcall(function()
		local st = state:get() or {}
		if name == "queue" then
			st.q = st.q or {}
			local dk = doneKey(param)
			local dup = dk and st.doneUid and st.doneUid[dk]
			for _, a in ipairs(st.q) do if dk and doneKey(a) == dk then dup = true end end
			if dup then log("action " .. tostring(param.uid) .. " queued twice: ignored") else st.q[#st.q + 1] = param end
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
			-- (an error is told: the interface waits for this join's company until its time runs out, see pumpCompanies)
			local okc, errc = pcall(coApply, st, param)
			if not okc then log("companies: co_apply " .. tostring(param and param.fn) .. " failed: " .. tostring(errc)) end
		elseif name == "broke" then
			-- test (scenario broke): the savegame's company spends nearly all its money
			local M = loanMods()
			if M and st.co and st.co.canon then
				local acc = api.engine.getComponent(st.co.canon, api.type.ComponentType.ACCOUNT)
				local have = acc and acc.balance or 0
				coBook(st.co.canon, M.lu.makeLoan(-(have + 100000), -1))
				log("test: the savegame's company spent " .. tostring(have + 100000))
			end
		elseif name == "share" then
			-- a company's setting for one of its stations (its window), for the other companies' vehicles: { key, rule, fee } with
			-- rule "co" (no setting of its own: the company's rule, see mpfever_eco.lua's stationRule), "open", "private" or "toll"
			-- (fee per stop). The form before 0.5.2, { key, fee }, stays: fee 0 = private, else that toll.
			-- Kept in reg.stationRule[key] = { rule, fee, co } (the company that set it: its "every station" choice clears them);
			-- a fee of 0.5.1 under the same key (reg.shares) goes.
			local reg = st.co
			if reg and reg.mode == "separate" and type(param.key) == "string" then
				local okS, errS = pcall(function()
					-- (a key "id:<n>" names the station by its entity id, which may be another station on another game: the
					-- setting would apply on some games only, and so would its fees. Refused on every game; the station window
					-- offers no choice for it. MPFEVER_IDKEYCHECK=0: as before)
					if param.key:sub(1, 3) == "id:" and os.getenv("MPFEVER_IDKEYCHECK") ~= "0" then
						log("companies: share of " .. param.key .. " refused (a station known by its entity id only)")
						return
					end
					local found = nil
					for _, sg in ipairs(R.entitiesWith("STATION_GROUP")) do
						if R.sgKey(sg) == param.key then found = sg break end
					end
					local owner = found and CO.idOfEntity(reg, R.ownerOf(found)) or nil
					local fee = math.max(0, math.floor(tonumber(param.fee) or 0))
					local rule = param.rule
					if rule == nil then rule = fee > 0 and "toll" or "private" end
					rule = tostring(rule)
					local why = nil
					if not (owner and owner == param.mpfCo) then why = "owner " .. tostring(owner) .. ", asked by " .. tostring(param.mpfCo)
					elseif rule ~= "co" and rule ~= "open" and rule ~= "private" and rule ~= "toll" then why = "rule " .. rule
					elseif rule == "toll" and fee <= 0 then why = "a toll of " .. fee end
					if why then
						log("companies: share of " .. tostring(param.key) .. " refused (" .. why .. ")")
						return
					end
					reg.stationRule = reg.stationRule or {}
					if rule == "co" then
						reg.stationRule[param.key] = nil
					else
						reg.stationRule[param.key] = { rule = rule, fee = rule == "toll" and fee or 0, co = owner }
					end
					if reg.shares then
						reg.shares[param.key] = nil
						if next(reg.shares) == nil then reg.shares = nil end
					end
					if next(reg.stationRule) == nil then reg.stationRule = nil end
					-- (the vehicles' next stops are read afresh: the fees count from the next look on, see E.stationFees.
					-- MPFEVER_FEESCAN=0: kept, as before)
					if os.getenv("MPFEVER_FEESCAN") ~= "0" then reg.vstop = nil end
					log("companies: company " .. owner .. " station " .. param.key .. ": " .. (rule == "co" and "the company's rule"
						or rule == "toll" and (fee .. " per stop") or rule))
				end)
				if not okS then log("companies: share failed: " .. tostring(errS)) end
			end
		elseif name == "ai_loan" then
			-- a computer company in debt takes the first loan on offer to it, as a player does from the loan window (see
			-- mpfever_ai.lua): every game takes the same offer at the same step. A player's company cannot send it.
			local reg = st.co
			local c = reg and reg.mode == "separate" and CO.find(reg, tonumber(param.mpfCo)) or nil
			local okL, errL = pcall(function()
				if not (c and type(c.key) == "string" and c.key:sub(1, 3) == "ai:") then log("companies: ai_loan refused to company " .. tostring(param.mpfCo)); return end
				local lt = coLoanTable(st, c.id)
				local now = gameTime()
				-- (0.5.14) at most param.max loans; with param.pick == 1 the offer of the lowest monthly payment (amount / months, plus
				-- its interest). The command's parameters and this simulation's offers are the same on every game: the same choice.
				-- Without them: the first offer, as before
				local most = tonumber(param.max)
				if most and #(lt and lt.obtainedLoans or {}) >= most then log("companies: computer company " .. c.id .. " has " .. most .. " loan(s) already"); return end
				local M = tonumber(param.pick) == 1 and loanMods() or nil
				local offer, pay = nil, nil
				for _, loan in ipairs(lt and lt.availableLoans or {}) do
					if type(loan.amount) == "number" and not (loan.cooldownUntil and loan.cooldownUntil > now) then
						if M then
							local p = loan.amount / math.max(1, M.lu.getDurationInMonths(loan.duration or 0)) * (1 + (loan.percentage or 0))
							if not pay or p < pay then offer, pay = loan, p end
						elseif not offer then offer = loan end
					end
				end
				if not offer then log("companies: no loan on offer to computer company " .. c.id); return end
				coLoanEvent(st, c.id, "Obtain", { offer, offer })
			end)
			if not okL then log("companies: ai_loan failed: " .. tostring(errL)) end
		elseif name == "ai_repay" then
			-- (0.5.14) a computer company with money to spare repays its oldest loan, as a player does from the loan window, when its
			-- money on this simulation, at this step, covers the loan and its interest plus what it keeps back (param.keep): every
			-- game decides the same. A player's company cannot send it. (mpfever_ai.lua: MPFEVER_AIREPAY=0, never sent)
			local reg = st.co
			local c = reg and reg.mode == "separate" and CO.find(reg, tonumber(param.mpfCo)) or nil
			local okR, errR = pcall(function()
				if not (c and c.ent and type(c.key) == "string" and c.key:sub(1, 3) == "ai:") then log("companies: ai_repay refused to company " .. tostring(param.mpfCo)); return end
				local M = loanMods()
				local lt = coLoanTable(st, c.id)
				local loan = lt and lt.obtainedLoans and lt.obtainedLoans[1]
				if not (M and loan) then return end
				local amount = M.lu.getFullLoanAndInterestPayBack(loan)
				local bal = api.engine.util.finance.getPlayersBalance(c.ent)
				local keep = math.max(0, tonumber(param.keep) or 0)
				if type(bal) ~= "number" or type(amount) ~= "number" or bal < amount + keep then
					log("companies: computer company " .. c.id .. " cannot repay its loan yet (" .. tostring(bal) .. " for " .. tostring(amount) .. " + " .. keep .. ")")
					return
				end
				coLoanEvent(st, c.id, "Repay", { loan, loan })
			end)
			if not okR then log("companies: ai_repay failed: " .. tostring(errR)) end
		elseif name == "recolor" then
			-- a company picks another colour in the MPFever window (one no other company has)
			local reg = st.co
			local c = reg and reg.mode == "separate" and CO.find(reg, tonumber(param.mpfCo)) or nil
			if c and CO.colorFree(reg, param.color, c.id) then
				c.color = tonumber(param.color)
				c.colorPicked = true
				pcall(SIM.coRecolor, st, c, os.getenv("MPFEVER_LINECOLOR") == "1")
			else
				log("companies: colour " .. tostring(param.color) .. " refused to company " .. tostring(param.mpfCo))
			end
		elseif name == "give" then
			-- a company gives money to another one (MPFever window): booked on both accounts at the same step on every game
			local reg = st.co
			local from = reg and tonumber(param.mpfCo)
			local to = reg and tonumber(param.to)
			local amount = math.floor(tonumber(param.amount) or 0)
			local cf, ct = from and CO.find(reg, from), to and CO.find(reg, to)
			local why = nil
			if not (reg and reg.mode == "separate") then why = "not in the companies mode"
			elseif not (cf and cf.ent and ct and ct.ent) then why = "unknown company"
			elseif from == to then why = "same company"
			elseif amount <= 0 then why = "amount " .. tostring(param.amount)
			else
				local okb, bal = pcall(api.engine.util.finance.getPlayersBalance, cf.ent)
				if not (okb and type(bal) == "number" and bal >= amount) then why = "balance " .. tostring(bal) .. " below " .. amount end
			end
			if why then
				log("companies: gift of " .. tostring(param.amount) .. " from company " .. tostring(from) .. " to " .. tostring(to) .. " refused: " .. why)
			else
				local function entry(n)
					local e = api.type.JournalEntry.new()
					e.amount = n
					e.time = -1
					e.category.type = api.type.JournalEntry.Type.OTHER
					return e
				end
				coBook(cf.ent, entry(-amount))
				coBook(ct.ent, entry(amount))
				reg.gifts = reg.gifts or {}
				reg.gifts[#reg.gifts + 1] = { at = gameTime(), from = from, to = to, amount = amount }
				while #reg.gifts > 20 do table.remove(reg.gifts, 1) end
				log("companies: company " .. from .. " gave " .. amount .. " to company " .. to)
			end
		elseif K.FEAT and type(name) == "string" and name:sub(1, 2) == "f_" then
			-- (0.6) the game options (mpfever_feat.lua): the host's options (f_opts), an action the interface applied (f_act), the
			-- modules' own events
			local okF, errF = pcall(SIM.featEvent, st, name, param)
			if not okF then log("options: event " .. name .. " failed: " .. tostring(errF)) end
		elseif C.eco() and C.eco().EVENTS[name] then
			-- mixed modes, bankruptcy, auctions, tracks' and depots' rules (mpfever_eco.lua)
			local okE, errE = pcall(C.eco().event, st, name, param, SIM.ecoEnv())
			if not okE then log("companies: event " .. name .. " failed: " .. tostring(errE)) end
		elseif name == "co_set" then
			local c = st.co and CO.find(st.co, param.id)
			if c then c.ent = param.ent; log("companies: company " .. c.id .. " is player entity " .. tostring(param.ent) .. " here") end
		elseif name == "terrain_note" then
			-- (counted by the checks from the edit's time on, see terrainSigAt)
			st.terrainNotes = st.terrainNotes or {}
			st.terrainNotes[#st.terrainNotes + 1] = { at = tonumber(param.at) or 0, v = tonumber(param.v) or 0 }
		elseif name == "lead_out" then
			-- (BUILDLEAD: this game released a build at once; it lands at this step or a few later, see captureNativeBuild)
			st.leadOut = st.leadOut or {}
			st.leadOut[#st.leadOut + 1] = gameTime()
			while #st.leadOut > 8 do table.remove(st.leadOut, 1) end
		elseif name == "lead_gone" then
			-- (BUILDLEAD: the oldest of them was refused, it will not be captured)
			if st.leadOut and #st.leadOut > 0 then table.remove(st.leadOut, 1) end
		elseif name == "replay_cost" then
			-- (a shipped native build about to be replayed here, with what it cost its builder: see REFUND.book)
			st.rcost = st.rcost or {}
			st.rcost[#st.rcost + 1] = { at = gameTime(), uid = param.uid, cost = tonumber(param.cost), co = param.co, got = 0, n = 0, kind = param.kind }
			while #st.rcost > 8 do table.remove(st.rcost, 1) end
		elseif name == "replay_stats" then
			-- (a shipped native build about to be replayed here, with its builder's town statistics: see SIM.townStats)
			local okT, errT = pcall(SIM.townExpect, st, param)
			if not okT then log("town stats: " .. tostring(errT)) end
		elseif name == "replay_unused" then
			-- (a counted replay the engine refused: no build of it will come, see replaySend)
			if st.replay and st.replay.at == gameTime() and st.replay.n > 0 then
				st.replay.n = st.replay.n - 1
				log("replay refused here: " .. st.replay.n .. " build(s) still expected at t=" .. tostring(st.replay.at))
			end
		elseif name == "replaying" then
			-- (tok: the mark of the replay announced with its town statistics, whose next command this event precedes; none for a
			-- replay without statistics of its own (nots), see SIM.townTag)
			local tok = (type(param) == "table" and param.nots ~= true and type(param.tok) == "string") and param.tok or nil
			st.replay = { at = gameTime(), n = ((st.replay and st.replay.at == gameTime()) and st.replay.n or 0) + 1, tok = tok }
			-- (what it builds, when known: see C.buildSig)
			if type(param) == "table" and type(param.sig) == "string" then
				if not (st.replaySigs and st.replaySigs.at == gameTime()) then st.replaySigs = { at = gameTime(), list = {} } end
				st.replaySigs.list[#st.replaySigs.list + 1] = param.sig
			end
		elseif name == "out_shipped" then
			-- (the interface has sent the captured builds up to n: their proposals are not needed here any more. They made the
			-- state megabytes heavy, and the engine copies the whole state at every state:get())
			local upto = tonumber(param.n) or 0
			for _, o in ipairs(st.out or {}) do if o.n <= upto then o.args = nil end end
		elseif name == "teststall" then
			-- (tests: the simulation thread stands still, no handshake meanwhile; see MPFEVER_TESTSTALL)
			local t0 = os.clock()
			while os.clock() - t0 < (tonumber(param.s) or 0) do end
		elseif name == "solo" then
			-- (in the state: the simulation's script runs in more than one Lua state. Cleared at every load, see resumeAfterLoad)
			st.solo = param.on ~= false or nil
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
	oldHolds = os.getenv("MPFEVER_OLDHOLDS") == "1",   -- (tests: the stop logic of 0.3.9 and before, issue #34)
	-- (experimental, off by default: the shorter proof that the engine stands still, see stillWatch; read once, and the counters
	-- are only watched with it or with MPFEVER_STEPLOG)
	fastStill = os.getenv("MPFEVER_FASTSTILL") ~= "0",   -- (on by default for testing; MPFEVER_FASTSTILL=0 turns it off)
	stillLog = os.getenv("MPFEVER_STEPLOG") ~= nil,
	-- (experimental, off by default: the builder leads, see buildLeadState; read once, every new path below is guarded by it)
	buildLead = os.getenv("MPFEVER_BUILDLEAD") == "1",
	inOff = 0, uiOff = 0, modOff = 0, frames = 0, started = false, me = C.NAME, connected = false,
	session = { speed = 0, pauseAt = nil, started = false },
	peers = {},                -- other players' clocks (barrier)
	oseq = 0, outSent = 0, lastClock = -1,
	hashSent = -1, resultsSeen = {}, lastSet = -1,
	leadStats = { atOnce = 0, held = 0, shipped = 0 },   -- (BUILDLEAD: builds released at once / held the usual way / shipped from the first)
	waits = {}, pendingPaused = {}, holdAt = nil, bind = {}, rev = {},
	ahead = 3, stampFloor = 0,    -- steps ahead of this game's stamps; no stamp below what others were allowed
}

-- Companies: the company whose action this game is replaying (G.actor, a player entity). The GUI's getPlayer() answers it while it is
-- set (see coGui); the continuations of a replay (command answers, deferred steps) run under the same company.
local WAITS_MT = { __newindex = function(t, k, v)
	if type(v) == "table" and v.actor == nil then v.actor = G.actor end
	if type(v) == "table" and v.refund == nil then v.refund = G.refund end
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

-- A creation key bound to an entity: the entity it named before loses it (an entity with a stale key travelled as that key and
-- reached what the key names now, issue #53)
G.rebind = function(key, e)
	local old = G.bind[key]
	if old and old ~= e and G.rev[old] == key then G.rev[old] = nil end
	G.bind[key] = e
	G.rev[e] = key
end

-- The builder's refundable entities (what that player had just built, see pollNativeEvents), while one of their builds is replayed
-- (G.refund, carried into the replay's callbacks and deferred steps like G.actor): put into a replay's Context, a demolition gives
-- the same money back as on the builder's game. Before, it cost money on the other games and the host's money was then imposed
-- on everyone: the builder lost the refund.
G.refundInto = function(ctx)
	if type(G.refund) ~= "table" or ctx == nil then return end
	local ok, err = pcall(function() ctx.refundableEntities = C.toRefund(G.refund) end)
	if not ok then
		G.refundErrors = (G.refundErrors or 0) + 1
		if G.refundErrors <= 3 then log("refundable entities not put into a replay's context: " .. shortErr(err)) end
	end
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
	local f = C.keptOpen(C.DIR .. BS .. fileName)
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
	return lines
end

local function parseLine(line)
	local kind, from, payload = line:match("^([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "(.*)$")
	return kind, from, payload
end

local function toSim(name, param)
	-- (a replay announced to the simulation: the next replaySend is the command it counts, see replaySend)
	if name == "replaying" then G.replayCounted = (G.replayCounted or 0) + 1 end
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

-- (0.6.4) A queued action holds the native stop point a step before its time until the simulation has taken it (the command's
-- answer, see pacing): it came with a margin of one step in a 45-minute test at 4x, the host's next clock moved the stop point
-- on before the simulation had it, and this game applied it 4 steps late (a vehicle sent to its line late, then vehicles,
-- money and towns apart, t1 of 2026-10-31). With the usual margin the answer comes long before. MPFEVER_QHOLD=0: as before
local function queueLocal(a)
	if a.paused then
		-- (its turn among the paused builds, given by the host: see G.actTurn)
		if G.actTurns and a.fn ~= "mpfCoJoin" and a.kind ~= "hash" then G.ptIssue(a.origin, G.actTurnId(a)) end
		G.pendingPaused[#G.pendingPaused + 1] = a
	elseif os.getenv("MPFEVER_QHOLD") ~= "0" and type(a.at) == "number" then
		local h = { at = a.at, frame = G.frames, uid = a.uid }
		G.qHold = G.qHold or {}
		G.qHold[#G.qHold + 1] = h
		O.sendCommand(O.event("mpfever", "mpfever", "queue", a), function() h.done = true end)
	else
		toSim("queue", a)
	end
end

-- A terrain tool applies its edit at once on the game of the player who uses it (the native module cannot hold it: the tool
-- crashed), at that game's time; a game already past that time made it late, the towns (whose reputation an edit changes) then
-- drifted apart. So while a player has a terrain tool in hand, that game LEADS: the others stay behind it by more than what a
-- game may overshoot a stop point, and get every edit before its time. It lasts a while after the tool was last seen or an edit
-- last made (the menu says when a terrain tool is picked, not when it is put away). Level 2 for a tool picked or used in the last
-- seconds, 1 for one picked a while ago: the higher level leads; two players at the same level: normal barrier between them.
K.TERRAIN_LEAD_SECONDS = 60
K.TERRAIN_ACTIVE_SECONDS = 10
local function terrainLead(why, what)
	-- (what: BUILDLEAD says it is a construction tool, whose lead has its own times and ranks below a terrain tool's, see
	-- leadLevel; the terrain tools' callers give nothing)
	if what ~= nil then
		local firstB = not G.buildLeadUntil or os.clock() >= G.buildLeadUntil
		G.buildLeadUntil = os.clock() + K.TERRAIN_LEAD_SECONDS
		G.buildActiveUntil = os.clock() + K.TERRAIN_ACTIVE_SECONDS
		if firstB then log(what .. " in hand (" .. tostring(why) .. "): the other games stay behind this one") end
		return
	end
	local first = not G.terrainLeadUntil or os.clock() >= G.terrainLeadUntil
	G.terrainLeadUntil = os.clock() + K.TERRAIN_LEAD_SECONDS
	G.terrainActiveUntil = os.clock() + K.TERRAIN_ACTIVE_SECONDS
	if first then log("terrain tool in hand (" .. tostring(why) .. "): the other games stay behind this one") end
end

-- 0: no terrain tool in hand, 1: picked a while ago, 2: picked or used in the last seconds
-- BUILDLEAD, when every game takes part: a terrain tool ranks above a construction tool, whatever the other game does (its
-- edits are made at once and must stay covered by a lead): construction tools 1 (picked a while ago) or 2, terrain tools 3 or 4.
-- (With a game that does not take part the levels of a terrain tool stay 1 and 2, as the others compare them.)
local function leadLevel()
	local now = os.clock()
	local terr = 0
	if G.terrainLeadUntil and now < G.terrainLeadUntil then terr = (G.terrainActiveUntil and now < G.terrainActiveUntil) and 2 or 1 end
	if not G.buildLead or not G.buildLeadPeers() then return terr end
	if terr > 0 then return terr + 2 end
	if G.buildLeadUntil and now < G.buildLeadUntil and not G.leadYields() then
		return (G.buildActiveUntil and now < G.buildActiveUntil) and 2 or 1
	end
	return 0
end

-- the steps a game may run past a stop point before its interface stops it (see the stamp distance)
local function overshootReserve()
	return 2 * math.max(1, math.min(4, G.session.speed or 1)) + 1
end

-- how far behind a leader the others stay: their overshoot, then as much again to stop exactly at an edit's time
local function terrainLeadSteps()
	return 2 * (overshootReserve() + 1)
end

-- another player leads this game (terrain tool in hand, game running)
local function otherLeads()
	if G.session.pauseAt ~= nil then return false end
	local mine = leadLevel()
	for _, pc in pairs(G.peers) do if (pc.tl or 0) > mine then return true end end
	return false
end

-- ---------------------------------------------------------------- the builder leads (experimental, MPFEVER_BUILDLEAD=1)
-- A tool's build is held by the native module until a game time 8 steps ahead, and the builder's game stops for it (issue
-- #34): a build appears about 2 s after the click, and the tool cannot place the next piece before. Here the construction tools
-- get the lead the terrain tools have: while a player has one in hand, that game LEADS (the others stay a few steps behind it,
-- see terrainLeadSteps) and its builds are not held at all: they are released at once, the engine applies them at the next
-- step wherever the game is, the capture ships the step they were applied at ("built here at t=..."), and the other games, far
-- enough behind, apply them there. Nothing else changes: two players at the same level, a paused session and every game that
-- does not take part (no "bl" in its clock) keep the held builds of today.
-- What makes it safe (a game must never pass the step a build lands at before it has the build):
--  * every other game is known to stay well behind this one when a build is released (buildLeadState: it says in its clock that
--    it follows this game's lead, and its clock is at least its overshoot plus the room to stop exactly, behind this one's);
--  * the build is announced at once ("nat_pending", marked "lead") for this game's current time. That is a LOWER bound of the
--    step it lands at: a game that has not got the build holds there (nativeHoldAt), so it cannot go past the real step either,
--    whatever the delays are; the real step (the capture's) replaces it when the build arrives (nativeReceived);
--  * while a released build has not been shipped, this game does not run on for long (leadCap in pacing), so that the others
--    do not come up against that hold;
--  * no other build lands on this game at the steps a released build may land at (buildLeadState): the capture takes the first
--    build at a step where it expects a replay for that replay (captureNativeBuild), and the released one would never be shipped.
-- (everything of it hangs on G: this chunk is a few locals short of the 200 a Lua function may have)

-- Which tools take the lead: every tool that sends builder events (guiHandleEvent), but the terrain tools, which have their own
-- lead (their edits are not held). (Seen in logs: streetBuilder, trackBuilder, constructionBuilder, streetTerminalBuilder,
-- bulldozer; a list guessed from the native module's tool classes named ids the game does not have.)
-- (the tools whose builds were tried with the lead: streets, tracks, constructions such as stations, street stops, the bulldozer;
-- the others, as the module builder or the lane and track modifiers, keep the held builds of today until they are tried)
G.BUILD_LEAD_TOOLS = { streetBuilder = true, trackBuilder = true, constructionBuilder = true, streetTerminalBuilder = true, bulldozer = true }
G.buildLeadTool = function(id)
	return G.BUILD_LEAD_TOOLS[id] == true
end

-- A lead that comes from construction tools only gives way while another game's build is announced to this one: that game
-- stamped it ahead of this one's clock and must come up to its time to release it, which the lead (that game stays well behind
-- this one) would keep it from: the other game would first wait for this one to reach the build's time (see pacing).
-- Meanwhile this game releases nothing at once (buildLeadState). A terrain tool's lead does not give way: its edits are made at
-- once, a game coming up to this one could pass them (the case of 0.3.10, unchanged).
G.leadYields = function()
	for _, w in ipairs(G.natWait or {}) do
		if not w.lead then
			if not G.leadYielding then G.leadYielding = true; log("BUILDLEAD: the lead gives way while the build of " .. tostring(w.origin) .. " for t=" .. tostring(w.at) .. " is due") end
			return true
		end
	end
	if G.leadYielding then G.leadYielding = nil; log("BUILDLEAD: the lead is back") end
	return false
end

-- The steps a build released at once may land at, after the time it was released at: this game does not run further while it
-- is not shipped (leadCap), and the others come up to its announced time only past that (see G.updateLeadCap).
G.leadWindow = function()
	return (terrainLeadSteps() - overshootReserve() - 1) * STEP
end

-- The times of the actions that make a build (C.makesProposal), this game's and the others', still to be applied here: a build
-- released at once must not land at one of them (buildLeadState).
G.leadDueList = {}
G.leadNoteDue = function(a)
	if type(a) ~= "table" or type(a.at) ~= "number" or a.fn == nil or not C.makesProposal(a.fn) then return end
	local l = G.leadDueList
	l[#l + 1] = a.at
	if #l > 200 then table.remove(l, 1) end
end
G.leadDue = function(now)
	local keep, first = {}, nil
	local last = now + G.leadWindow() + STEP
	for _, t in ipairs(G.leadDueList) do
		if t >= now then
			keep[#keep + 1] = t
			if t <= last and (first == nil or t < first) then first = t end
		end
	end
	G.leadDueList = keep
	return first
end

-- The other games' clocks say whether they can follow a builder's lead ("bl" 1; 2: and this game follows another one's lead
-- right now). Is it right to take a construction tool in hand for a lead? Only when every other game can follow.
G.buildLeadPeers = function()
	local n = 0
	for _, pc in pairs(G.peers) do
		n = n + 1
		if (pc.bl or 0) < 1 then return false end
	end
	return n > 0
end

-- a construction tool is in the player's hand (its events, see guiHandleEvent)
G.buildToolSeen = function(id)
	if not G.buildLeadTool(id) or not G.buildLeadPeers() then return end
	terrainLead(id, "BUILDLEAD: construction tool")
end

-- Is this game leading right now, so that a tool's build is released at once? Returns true, or false and why not.
G.buildLeadState = function()
	if not G.buildLead then return false, "off" end
	if not G.session.started then return false, "the session has not started" end
	if G.session.pauseAt ~= nil then return false, "the session is paused" end
		-- (at every speed since 0.5.9: what drifted was the seeds counting the frames a game stood still, fixed by the tick epochs of
	-- 0.5.3 - towncross at 4x: 3 of 3 desynced in 0.3.12, in sync now, and desynced again with MPFEVER_NOTICKEPOCH=1, tests
	-- 410-414 of 2026-10-27. MPFEVER_BUILDLEADX1=1: at 1x only, as before)
	if (G.session.speed or 1) > 1 and os.getenv("MPFEVER_BUILDLEADX1") == "1" then return false, "the session runs faster than 1x" end
	if G.leadYields() then return false, "the lead gives way to another game's build" end
	local mine = leadLevel()
	if mine == 0 then return false, "no tool in hand" end
	local okT, now = pcall(gameTime)
	if not okT then return false, "no clock" end
	-- no other build may land here at the steps this one may land at (see the top): none while this game is held or replays, nor
	-- while another game's build is announced or an action that makes a build is due within that window
	if G.holdAt ~= nil then return false, "this game is held for a build or an action" end
	if (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) then return false, "a replay is in the engine's hands" end
	if #(G.nativeQueue or {}) > 0 or #(G.natWait or {}) > 0 then return false, "another game's build is announced or not applied yet" end
	local due = G.leadDue(now)
	if due then return false, "an action that makes a build is due at t=" .. due end
	-- the steps a game follows behind the leader's last reported clock are terrainLeadSteps(); it may be as far as its overshoot
	-- past that (the barrier keeps a reserve for it), and must still have the room to stop exactly at the announced step
	local need = (terrainLeadSteps() - overshootReserve()) * STEP
	local n = 0
	for name, pc in pairs(G.peers) do
		n = n + 1
		if (pc.tl or 0) >= mine then return false, tostring(name) .. " leads too (level " .. pc.tl .. ", this game " .. mine .. ")" end
		if (pc.bl or 0) < 2 then return false, tostring(name) .. " does not follow yet" end
		if type(pc.t) ~= "number" or pc.t > now - need then
			return false, tostring(name) .. " is only " .. (type(pc.t) == "number" and ((now - pc.t) / STEP) or "?") .. " steps behind (needs " .. (need / STEP) .. ")"
		end
	end
	if n == 0 then return false, "no other game" end
	return true
end

-- the time of this game's earliest held build (released by this script when the game stands at that time, see
-- runNativeRelease), nil when there is none
G.ownHeldAt = function()
	local m = nil
	for _, r in ipairs(G.natRelease or {}) do if m == nil or r.at < m then m = r.at end end
	return m
end

-- the speed this game may run at: session speed, never past the slowest other player (barrier), stop points
G.pstat = { frames = 0, barrier = 0, hold = 0 }
local function pacing()
	local now = gameTime()
	local s = G.session
	G.lastStopAt = nil
	if not s.started then return 0 end
	local stopAt = s.pauseAt
	-- paused, but an action stamped later (another game stopped further): catch up to it, one step at a time
	local catchUp = s.pauseAt ~= nil and G.holdAt ~= nil and G.holdAt > s.pauseAt and now < G.holdAt
	if catchUp then stopAt = G.holdAt
	elseif G.holdAt and (stopAt == nil or G.holdAt < stopAt) then stopAt = G.holdAt end
	-- (0.6.4) a queued action the simulation has not taken yet: a step before its time (see queueLocal; 600 frames at most)
	if G.qHold and #G.qHold > 0 then
		local keep, q = {}, nil
		for _, h in ipairs(G.qHold) do
			if not h.done and G.frames - h.frame < 600 then
				keep[#keep + 1] = h
				if q == nil or h.at - STEP < q then q = h.at - STEP end
			elseif not h.done then
				log("queued action " .. tostring(h.uid) .. ": no answer of the simulation within 600 frames, no longer held")
			end
		end
		G.qHold = keep
		if q and (stopAt == nil or q < stopAt) then
			stopAt = q
			if now >= q and G.qHoldLogged ~= q then G.qHoldLogged = q; log("queued action held at t=" .. q .. " until the simulation has it (now " .. now .. ") [frame " .. G.frames .. "]") end
		end
	end
	local barrier, exactBarrier = nil, nil
	local mine = leadLevel()
	for _, pc in pairs(G.peers) do
		-- window (see G.ahead): a game that overshoots this limit by its reserve is still before the time stamped on
		-- the peer's next action
		local limit = pc.t + (G.window or 3) * STEP
		-- exact steps never overshoot: they may go up to the step before the peer's next action could be stamped (its stamp
		-- distance past its clock), one round less towards a build's time (issue #34)
		local exact = pc.t + math.max(G.window or 3, (tonumber(pc.ah) or 0) - 1) * STEP
		local theirs = pc.tl or 0
		if s.pauseAt == nil and theirs > mine then
			-- that player has a terrain tool in hand: stay behind it, overshoot included, with room to stop before its edits
			limit = pc.t - terrainLeadSteps() * STEP
			-- but not short of this game's own held build once the leader's clock has reached its time. That build is stamped
			-- ahead of the leader's clock, so the leader stops there and waits for it, and only this game can release it, at that
			-- time: kept behind the leader, the two games waited for each other until the hold expired (1800 frames) and the build
			-- landed late. The leader sends its clock after the edits it made up to that time, and this game comes up from
			-- terrainLeadSteps() behind it. An edit the leader makes while it waits lands at that time too; once the build is
			-- released this game is behind the leader again and does not pass that time before the leader is that far past it.
			local own = G.ownHeldAt()
			if own and pc.t >= own and own > limit then limit = own end
			exact = limit
		elseif s.pauseAt == nil and mine > theirs then
			-- this game leads: the others keep that distance behind it
			limit = pc.t + ((G.window or 3) + terrainLeadSteps()) * STEP
			exact = limit
		end
		if G.oldHolds then exact = limit end
		if barrier == nil or limit < barrier then barrier = limit end
		if exactBarrier == nil or exact < exactBarrier then exactBarrier = exact end
	end
	-- BUILDLEAD: a build released at once and not shipped yet (leadCapAt, see guiUpdate): this game does not run on beyond it, as
	-- far as the others are concerned like a barrier (they hold at the build's step anyway, this keeps them from coming up to it)
	if G.buildLead and G.leadCapAt and s.pauseAt == nil then
		if barrier == nil or G.leadCapAt < barrier then barrier = G.leadCapAt end
		if exactBarrier == nil or G.leadCapAt < exactBarrier then exactBarrier = G.leadCapAt end
		if now >= G.leadCapAt and G.leadCapLogged ~= G.leadCapAt then
			G.leadCapLogged = G.leadCapAt
			G.leadStats.capped = (G.leadStats.capped or 0) + 1
			log("BUILDLEAD cap: this game stops at t=" .. G.leadCapAt .. " (now " .. now .. ") until the build released at once has been shipped [frame " .. G.frames .. "]")
		end
	end
	-- (the native stop point, see G.nstop: exact at the holds and the session's pause, but the barrier keeps its reserve for the
	-- overshoot as before: held exactly at the barrier, each game waited for the other's next clock and the games ran at half
	-- speed at 4x, 10 steps a second instead of 20, tests 602-639 of 2026-10-27. The stamp distance keeps that reserve too.)
	local nativeAt = stopAt
	if barrier then
		local soft = barrier + overshootReserve() * STEP
		if nativeAt == nil or soft < nativeAt then nativeAt = soft end
	end
	G.lastStopAt = nativeAt
	if barrier and (stopAt == nil or barrier < stopAt) then stopAt = barrier end
	G.lastBarrier = barrier
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
		-- the native module keeps the stop point (G.nstop): the batches end there exactly, so the game runs at its speed up to it,
		-- with no pause short of it and no exact steps, and stands there at that speed (it goes on in the batch after the stop point
		-- moves, with no speed change to wait for). The session's own pause still pauses the game.
		if G.nstopOk() and not (s.pauseAt ~= nil and now >= s.pauseAt and not catchUp) then
			if now >= stopAt then slowed(0) end
			return want
		end
		if now >= stopAt then return slowed(0) end
		-- near a stop point, running at a speed would overshoot it (N steps per frame, a speed change takes a frame):
		-- the game pauses and the engine performs exactly the steps left
		-- (only for real stop points: the barrier keeps a reserve for the overshoot and moves all the time)
		-- (the zone a stop point is approached from, see nativeHoldAt: a game stopped inside it never runs at speed again; nor
		-- towards the barrier when an action waits just past it, which the overshoot would reach)
		local zone = (overshootReserve() + 1) * STEP
		local holdNear = G.holdAt ~= nil and G.holdAt - now <= zone
		if O.steps and holdNear and stopAt == barrier and exactBarrier and exactBarrier > barrier then
			-- towards a hold by exact steps: as far as the peers' stamp distances allow
			local target = math.min(G.holdAt, exactBarrier)
			if s.pauseAt ~= nil and not catchUp then target = math.min(target, s.pauseAt) end
			if now >= target then return slowed(0) end
			G.wantSteps = math.floor((target - now) / STEP)
			return slowed(0)
		end
		if O.steps and (stopAt ~= barrier or holdNear) and stopAt - now <= zone then
			G.wantSteps = math.floor((stopAt - now) / STEP)
			return slowed(0)
		end
		if want > 1 and stopAt - now < want * STEP then return slowed(1) end   -- do not overshoot a stop point inside a batch
	end
	return want
end

-- Smooth pacing: instead of running at full speed into the barrier and standing there until the slowest player's clock moves
-- (vehicles moved, stopped, moved: issue #47, a dedicated server on the same PC), this game's batches are shown a little
-- longer as it comes close to the barrier, and a little shorter when it is behind: the native module scales the engine's
-- batch interval by the factor written in native_pace.txt (see SyncCallWrap in mpfever_native.cpp; TPF3-MP's batch
-- interval). Only the real time between batches changes, every game still runs the same steps at the same game times. The
-- factor keeps a batch and a half of room before the barrier: 1 with that room or more, up to 2 (half speed) at the
-- barrier; the game that is behind never runs faster than the session's speed. (Tuned on a model of two games, one of them
-- 15 to 50 % slower, 50 to 300 ms apart: no stop left at 1x and 2x up to 30 % slower, fewer at 4x.) MPFEVER_SMOOTH=0 turns
-- it off.
G.smooth = { on = os.getenv("MPFEVER_SMOOTH") ~= "0", trim = 1, written = 1, frame = -1000, seq = 0 }
G.smoothPace = function(sp)
	local S = G.smooth
	if not S.on then return end
	local s = G.session
	local target = 1
	local okT, now = pcall(gameTime)
	-- (running at the session's speed, nothing held or stepped exactly: the stop points keep their own logic)
	if okT and s.started and s.pauseAt == nil and sp > 0 and sp == s.speed and G.holdAt == nil and not G.stepTarget and G.lastBarrier then
		local per = math.max(1, sp)                                  -- steps per batch
		local margin = (G.lastBarrier - now) / STEP / per            -- batches left before the barrier
		target = 1 + 2 * (1.5 - margin)
		if target < 1 then target = 1 elseif target > 2 then target = 2 end
	end
	if target == 1 and sp == 0 then S.trim = 1 else S.trim = S.trim + (target - S.trim) * 0.15 end
	if math.abs(S.trim - 1) < 0.02 and math.abs(target - 1) < 0.02 then S.trim = 1 end
	-- (written when it moved by 3 %, at most every 6 frames, and every 2 s while it is not 1: the native module goes back to 1
	-- when it is not refreshed for 5 s)
	local due = math.abs(S.trim - S.written) >= 0.03 or (S.trim == 1 and S.written ~= 1) or (S.trim ~= 1 and G.frames - S.frame >= 120)
	if due and (G.frames - S.frame >= 6 or S.trim == 1) then
		S.written, S.frame, S.seq = S.trim, G.frames, S.seq + 1
		local f = C.IO.open(C.DIR .. BS .. "native_pace.txt", "wb")
		if f then f:write(tostring(math.floor(S.trim * 1000 + 0.5)) .. " " .. S.seq .. NL); f:close() end
		if S.trim ~= 1 and (S.logged or 0) < 5 then
			S.logged = (S.logged or 0) + 1
			log("smooth pacing: batches shown at " .. string.format("%.2f", S.trim) .. " times their interval (barrier " .. tostring(G.lastBarrier) .. ", t=" .. tostring(now) .. ") [frame " .. G.frames .. "]")
		end
	end
end

local H = {}

H.welcome = function(from, p)
	if p.you then G.me = p.you end
	G.connected = true
	if G.solo then G.solo = nil; pcall(toSim, "solo", { on = false }) end
	log("connected to session as " .. tostring(G.me) .. " (" .. tostring(p.role) .. ")")
end

-- The launcher has no lobby for this game (MPFever.exe, then a savegame loaded from the game's own menu): its builds go to nobody.
-- The simulation stops keeping them (issue #82: every edit of a train station kept in full in its state, which the engine copies
-- several times a frame; the frame rate fell with each module added)
H.solo = function(from, p)
	if G.connected then return end
	G.solo = true
	pcall(toSim, "solo", { on = true })
	log("no lobby: the builds of this game are not kept for other players")
end

H.chat = function(from, p) log("chat " .. tostring(from) .. ": " .. tostring(p.text)) end

H.session = function(from, p)
	if p.cmode ~= nil then G.cmode = p.cmode; G.coStart = p.cstart; G.coOwner = p.owner; G.coBankrupt = p.bankrupt end
	-- (0.5.14: the sharing rules between companies on or off, the host's choice; none: on)
	if p.cmode ~= nil then G.coShare = p.share ~= false and p.share ~= 0 end
	-- (the computer companies the host chose in its lobby, "n:colour,...": run by the host's game, see mpfever_ai.lua)
	if p.cmode ~= nil then G.coAi = p.ai end
	-- (0.6) the session's game options, the host's choice ("id=1;id.param=v;..."; none: nothing to change), see G.featGui
	-- (G.featTestOpts: an autotest's own options, see H.permstest and H.journaltest)
	if K.FEAT then G.featOpts = G.featTestOpts or (type(p.opts) == "string" and p.opts or nil) end
	G.session.started = p.started == true
	-- a resynchronisation is under way (see G.resyncRefuse); MPFEVER_RESYNCBUILDS=1: builds are not refused then (as before 0.5.0)
	local rs = p.resync == true and os.getenv("MPFEVER_RESYNCBUILDS") ~= "1"
	if rs ~= (G.session.resync == true) then log("session: resynchronisation " .. (rs and "under way: this player's builds are refused" or "over")) end
	G.session.resync = rs
	if not rs then G.resyncNewWorld = nil end
	G.session.speed = p.speed or 0
	-- the tutorial: its missions are validated by each game's own interface, so they diverge (a unique building the client
	-- built for its task stays a task on the host's game...): the players are told, once per game loaded
	if G.session.started and C.ROLE == "host" and not G.tutorialChecked then
		G.tutorialChecked = true
		pcall(function()
			local found, where = false, {}
			local function scan(v, d, path)
				if d > 12 then return end
				if type(v) == "string" then
					if v:lower():find("tutorial", 1, true) and #where < 6 then where[#where + 1] = path .. "=" .. v:sub(1, 60) end
				elseif type(v) == "table" then
					for k, x in pairs(v) do
						if type(k) == "string" and k:lower():find("tutorial", 1, true) and #where < 6 then where[#where + 1] = path .. "." .. k .. "=" .. tostring(x):sub(1, 40) end
						scan(x, d + 1, path .. "." .. tostring(k))
					end
				end
			end
			local e = api.engine.system.gameScriptSystem.getEntityForGameScript(GAME_SCRIPTS.mission)
			local c = e and e >= 0 and api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT)
			if c then
				scan(c.state, 0, "mission")
				-- (the mission script's own flag; finished, it is no longer in the way)
				found = type(c.state) == "table" and c.state.isTutorialActive == true and c.state.isComplete ~= true
			end
			log("tutorial in this game: " .. tostring(found) .. " (mentions: " .. table.concat(where, " ; "):sub(1, 300) .. ")")
			if found then send("notice", { what = "tutorial" }) end
		end)
	end
	if p.pauseAt ~= G.session.pauseAt then
		G.session.pauseAt = p.pauseAt
		if p.pauseAt then toSim("pause_at", { at = p.pauseAt }) else toSim("resume", {}) end
	end
end

H.peerclock = function(from, p)
	if p.name and p.name ~= G.me then
		local was = G.peers[p.name] and G.peers[p.name].tl or 0
		local tl = tonumber(p.tl) or 0
		-- (bl: the game takes part in BUILDLEAD, 1; 2: and it follows another game's lead now; only sent with the switch on)
		local bl = tonumber(p.bl)
		-- (ns: that game keeps its stop points natively, see G.nstop)
		G.peers[p.name] = { t = p.t, ah = p.ah, tl = tl > 0 and tl or nil, bl = bl and bl > 0 and bl or nil, ns = tonumber(p.ns) == 1 }
		if (tl > 0) ~= (was > 0) then
			log(tostring(p.name) .. (tl > 0 and (" has a tool in hand that leads (level " .. tl .. "): the game that used it last leads") or " put its leading tool away"))
		end
	end
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
	-- MPFEVER_ADAPTAHEAD=1 is the launcher's "Slow PC mode", whose text says it gives builds more room on a busy PC: it did the
	-- opposite, it shortened the distance down to 60 % (a host with it on, #104: stamp distance 7 to 10 instead of 16 at x4, 70
	-- builds arrived with no step to spare). It now gives a third more room (the builds of this PC show a little later and
	-- reach the others in time). MPFEVER_ADAPTAHEAD=short: shortened, as before
	if os.getenv("MPFEVER_ADAPTAHEAD") == "1" then return base + math.ceil(base / 3) end
	-- (opt-in, MPFEVER_ADAPTAHEAD=short: on a loaded PC builds already arrive up to 3 steps late with the full distance, so it is
	-- not shortened by default)
	if os.getenv("MPFEVER_ADAPTAHEAD") ~= "short" or G.aheadLocked or #G.consumed < 8 then return base end
	local mx = 0
	for _, c in ipairs(G.consumed) do mx = math.max(mx, c) end
	return math.max(math.ceil(base * 0.6), math.min(base, math.ceil(mx * 1.5) + 4))
end

local function logMargin(kind, at, origin, lead)
	local ok, now = pcall(gameTime)
	if ok and type(at) == "number" then
		local m = (at - now) / STEP
		-- what the stamp's distance lost on the way: the other game's lead and the network
		-- (BUILDLEAD: a build released at once was not stamped ahead: its margin says nothing about the stamp distance)
		local pa = origin and G.peers[origin] and G.peers[origin].ah
		if pa and not lead and (kind == "nat_pending" or kind == "act") then
			table.insert(G.consumed, pa + (kind == "nat_pending" and 1 or 0) - m)
			if #G.consumed > 12 then table.remove(G.consumed, 1) end
		end
		G.minMargin = math.min(G.minMargin or 99, m)
		log("MARGIN " .. kind .. " " .. m .. " steps (smallest so far " .. G.minMargin .. ", stamp distance " .. tostring(G.ahead) .. ", speed " .. tostring(G.session.speed) .. ") [frame " .. G.frames .. "]")
	end
end

-- The edit of an existing construction sent by a window of the interface (not by a tool, whose builds the native module holds):
-- the Drive-in Warehouses mod's goods for a warehouse. Its proposal (the engine's replacement of the construction) could not be
-- rebuilt from its pieces on any game ("Unknown exception": refused everywhere, a session of the friends). Such an edit is
-- replayed like another player's build on every game, the originator's too, by the engine's own replacement with the new
-- settings (see replayNative). MPFEVER_UIEDIT=0: as before.
G.uiEdit = function(p)
	if p.native or p.fn ~= "makeWorldBuildProposalCmd" or os.getenv("MPFEVER_UIEDIT") == "0" then return false end
	local m = type(p.args) == "table" and p.args[1]
	if type(m) ~= "table" or type(m.toAdd) ~= "table" or type(m.toRemove) ~= "table" or #m.toAdd ~= 1 or #m.toRemove ~= 1 then return false end
	local ce = m.toAdd[1]
	return type(ce) == "table" and type(ce.params) == "table" and ce.params.upgrade == true
end

H.act = function(from, p)
	logMargin(p.native and "act(native)" or "act", p.at, p.origin, p.lead)
	p.recvFrame = G.frames
	pcall(G.noteOthers, p)
	-- (a player announced while the session is paused: its turn among the others' announcements, see G.joinTurn)
	if p.fn == "mpfCoJoin" and p.paused and G.joinTurns then G.ptIssue(p.origin, G.joinTurnId(p)) end
	if G.uiEdit(p) then
		p.native, p.uiEdit = true, true
		log("action " .. tostring(p.uid) .. ": the edit of a construction from a window, replayed by the engine's replacement on every game")
		-- (in a pause: its turn among the paused builds and actions, see G.actTurn)
		if p.paused and G.actTurns then G.ptIssue(p.origin, G.actTurnId(p)) end
	end
	if p.native then
		G.nativeQueue[#G.nativeQueue + 1] = p
		if nativeReceived then pcall(nativeReceived, p) end
	else
		queueLocal(p)
		if G.buildLead then G.leadNoteDue(p) end
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
	-- A replay counted by the simulation ("replaying": its build there is taken as this replay, not shipped) that the engine
	-- refuses builds nothing: the simulation is told, else it kept waiting for that build. While the game is paused (the same
	-- game time for minutes) these counts added up (a station replay's conversion command, refused on purpose, counted one
	-- each) and the player's own next builds were taken as replays and never shipped (issues #64, #66)
	local counted = (G.replayCounted or 0) > 0 and os.getenv("MPFEVER_REPLAYUNUSED") ~= "0"
	if counted then G.replayCounted = G.replayCounted - 1 end
	G.replayOut = (G.replayOut or 0) + 1
	G.replaySince = G.frames
	-- (another player's build reaches the engine here: a build this game holds was computed before it, see G.restale)
	G.worldFrame = G.frames
	local who, rf = G.actor, G.refund
	O.sendCommand(cmd, function(...)
		G.replayOut = math.max(0, (G.replayOut or 1) - 1)
		-- room for a follow-up command (next segment, next form); a longer hold for an edge-object count is kept (G.eoCheckHold)
		G.replayQuiet = G.eoHoldOwn and math.max(G.replayQuiet or 0, G.frames + 3) or (G.frames + 3)
		pcall(buildEffects, ...)
		if counted and select(2, ...) ~= true then pcall(toSim, "replay_unused", {}) end
		if cb then
			local prevRf = G.refund
			G.refund = rf
			local ok, r1, r2 = pcall(withActor, who, cb, ...)
			G.refund = prevRf
			if not ok then error(r1, 0) end
			return r1, r2
		end
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
-- a build that cuts a segment carrying stops or signals (they move to its new segments): only a native proposal moves them,
-- and the one rebuilt here is refused by the engine (an assert, "lc.segment0 not found") or, given the node configurations,
-- hangs the game. The script forms would strand the stops (a crash in their catchment area). So no form is tried: the build
-- is reported as not reproduced and the host's game is reloaded everywhere.
local OBJECT_FORMS = {}

-- A pure upgrade (every added segment replaces a removed one between the same nodes, nothing else): the engine's
-- replaceSegment builds it exactly as the upgrade tool does.
local function upgradePlan(margs, townAuto)
	-- (why there is no plan, for the log: G.upgradeWhy)
	local function no(why) G.upgradeWhy = why return nil end
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return no("no proposal") end
	if #(st.addedNodes or {}) > 0 or #(st.removedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return no("nodes added or removed, or stops added") end
	-- the tool said which new segment replaces which old one: the native proposal with those maps gives the new segments the
	-- builder's numbers. replaceSegment numbered them otherwise (issue #64: segment 290428 here, 272675 on the builder's
	-- game; an upgrade of 3 segments became 3 builds), and every later build then differed. MPFEVER_UPGRADEPLAN=1: as before.
	if C.hasReplaceMaps(st) and os.getenv("MPFEVER_UPGRADEPLAN") ~= "1" and os.getenv("MPFEVER_MAPREPLAY") ~= "0" then return no("replacement maps") end
	-- a stop removed with the bulldozer looks like an upgrade, but replaceSegment would keep the stop
	if #(st.edgeObjectsToRemove or {}) > 0 then return no("stops removed") end
	-- constructions: only town buildings the engine moved for the new street (nobody's, -1); every game's own
	-- replaceSegment moves them the same way (a rebuilt proposal could not make them town buildings again)
	local tAdd, tRem = margs[1].toAdd or {}, margs[1].toRemove or {}
	-- buildings moved for the new street: the engine picks their new places at random, so every game would put them
	-- elsewhere (the town then grows differently): they are rebuilt exactly as the originator's engine placed them
	-- (except town buildings the engine itself moves, townAuto: this game's replaceSegment, with buildings gathered, takes the
	-- same ones away and puts the same ones back. Rebuilt by the script forms, a widened street with trees made a proposal
	-- whose lanes the engine asserted on, and the game crashed: issue #65. MPFEVER_TOWNUPGRADE=0: as before)
	if (#tAdd > 0 or #tRem > 0) and not (townAuto and os.getenv("MPFEVER_TOWNUPGRADE") ~= "0") then return no("constructions other than town buildings") end
	local added, removed = st.addedSegments or {}, st.removedSegments or {}
	if #added == 0 or #added ~= #removed then return no("not one new segment per old one") end
	-- tram tracks added to (or taken from) a street: the tool also changes the lane connections of its crossings (node
	-- configurations), which replaceSegment leaves as they were (the tracks stopped at the crossings): the native proposal
	-- is replayed instead, node configurations included
	if #(st.nodeConfigsToAdd or {}) > 0 or #(st.nodeConfigsToRemove or {}) > 0 then
		local function lanes(s) return type(s.comp) == "table" and type(s.comp.laneConfigs) == "table" and C.laneSignature(s.comp.laneConfigs) or nil end
		for _, ad in ipairs(added) do
			for _, rm in ipairs(removed) do
				local ac, rc = ad.comp or {}, rm.comp or {}
				local same = (rc.node0 == ac.node0 and rc.node1 == ac.node1) or (rc.node0 == ac.node1 and rc.node1 == ac.node0)
				-- (same street type, other lanes: tracks; a new street type keeps the upgrade's replay)
				if same and ac.roadTemplate == rc.roadTemplate and lanes(ad) ~= lanes(rm) then return no("tram tracks (node configurations)") end
			end
		end
	end
	local plan = {}
	for _, ad in ipairs(added) do
		local c = ad.comp or {}
		local match, decorations = nil, nil
		local customLanes = C.customLanes(ad)
		for _, rm in ipairs(removed) do
			local rc = rm.comp or {}
			if (rc.node0 == c.node0 and rc.node1 == c.node1) or (rc.node0 == c.node1 and rc.node1 == c.node0) then
				match = rm.entity
				-- (0.6.5, #107) the tool's new segment runs the other way round than the old one (its ends swapped): replaceSegment
				-- keeps the old way round, and a one-way street (a motorway, highway_new_large_barriers) ran one way on the
				-- builder's game and the other way here: the vehicles took other roads from that build on ("vehicles" out of
				-- sync 33 s after the first such upgrade of Kev1505in's session, 2026-10-31). The tool's own proposal is replayed
				-- instead (as with replacement maps), the same way round everywhere. MPFEVER_UPGREV=0: as before (the
				-- decorations' sides swapped only)
				if rc.node0 == c.node1 and rc.node1 == c.node0 and rc.node0 ~= rc.node1 and os.getenv("MPFEVER_UPGREV") ~= "0" then
					log("NATIVE REPLAY: the tool's new segment for " .. tostring(rm.entity) .. " runs the other way round: no upgrade plan, the tool's proposal")
					return no("segment reversed")
				end
				-- more than a new template (a bridge, a different track...): replaceSegment would not make it
				if c.type ~= rc.type or c.typeIndex ~= rc.typeIndex or c.roadType ~= rc.roadType or ad.type ~= rm.type then return no("other segment type") end
				-- (the decorations, a noise barrier for instance, are put on the engine's upgrade proposal below)
				if C.ser(c.edgeDecorations or {}) ~= C.ser(rc.edgeDecorations or {}) then decorations = c.edgeDecorations or {} end
			end
		end
		if type(match) ~= "number" or match < 0 then return no("no old segment between the same nodes") end
		-- (who the tool gave the new segment to, nobody included: see G.stepOwner)
		local owner = type(ad.playerOwned) == "table" and type(ad.playerOwned.player) == "number" and ad.playerOwned.player or false
		plan[#plan + 1] = { edge = match, template = c.roadTemplate, decorations = decorations, lanes = customLanes, n0 = c.node0, owner = owner }
	end
	-- the junctions at both ends as the tool set them (lane connections, crosswalks, traffic lights): replaceSegment lets the
	-- engine work them out again, which almost always gives the same, but not always (a manual test: nodeConfigs differed from
	-- one upgrade on, the same number of junctions). Put on the upgrade's proposal (one segment). MPFEVER_UPGNC=0: as before
	if #plan == 1 and os.getenv("MPFEVER_UPGNC") ~= "0" and #(st.nodeConfigsToAdd or {}) > 0 then
		plan[1].nc = st.nodeConfigsToAdd
		local ncr = {}
		for _, n in ipairs(st.nodeConfigsToRemove or {}) do if type(n) == "number" and n >= 0 then ncr[#ncr + 1] = n end end
		plan[1].ncr = ncr
	end
	return plan
end

-- The engine's upgrade segment with what the template does not give: the originator's decorations (noise barrier, the trees
-- of a street with trees: the engine's upgrade to it has none) and lanes (tram tracks on a road), only where they differ
-- from the engine's segment
G.stepExtras = function(a, step, seg)
	local cmp = seg.comp
	if step.decorations then
		-- a decoration has a side (left of the segment's direction): when this game's segment runs the other way round than
		-- the originator's, the side is the opposite one
		local deco = C.plain(step.decorations)
		local be = api.engine.getComponent(step.edge, api.type.ComponentType.BASE_EDGE)
		if be and type(step.n0) == "number" and be.node0 ~= step.n0 then
			for _, d in ipairs(deco) do if type(d) == "table" then d[2] = not d[2] end end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " segment " .. step.edge .. " runs the other way round: decoration sides swapped")
		end
		local have, want = nil, C.ser(deco)
		pcall(function()
			local t = {}
			for k = 1, #cmp.edgeDecorations do local d = cmp.edgeDecorations[k]; t[k] = { d[1], d[2] } end
			have = C.ser(t)
		end)
		if have == want then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " segment " .. step.edge .. ": decorations already as the tool's")
		else
			log("NATIVE REPLAY " .. tostring(a.uid) .. " segment " .. step.edge .. ": decorations " .. tostring(have) .. " -> " .. want)
			cmp.edgeDecorations = deco
		end
	end
	if step.lanes and C.laneSignature(cmp.laneConfigs) ~= C.laneSignature(step.lanes) then cmp.laneConfigs = C.rebuildLanes(step.lanes) end
	seg.comp = cmp
	return seg
end

-- The engine's upgrade segment owned as the tool's: replaceSegment keeps the old segment's owner, while the tool's segment has
-- its own owner, or none (the engine then makes it nobody's). One company per player, a player who upgraded another company's
-- road had it his or nobody's on his game and still the other company's on the others (owners out of sync, a reload: #104;
-- the autotest upgowner, "none": nobody's on the builder's game, the old owner's here). step.owner: the tool's owner, false for
-- none. MPFEVER_UPGOWNER=0: as before (replaceSegment's owner)
G.stepOwner = function(a, step, seg)
	if os.getenv("MPFEVER_UPGOWNER") == "0" or step.owner == nil then return seg end
	local have = nil
	pcall(function() have = seg.playerOwned and seg.playerOwned.player end)
	if type(have) == "number" and have < 0 then have = nil end
	local want = (type(step.owner) == "number" and step.owner >= 0) and step.owner or nil
	if have == want then return seg end
	if want then
		local po = C.newOf("PlayerOwned")
		po.player = want
		seg.playerOwned = po
	else
		-- (a segment without an owner: a new one with everything but the owner)
		local n = C.newOf("SegmentAndEntity")
		for _, f in ipairs({ "entity", "type", "comp", "streetEdge", "trackEdge", "params", "emissionEmitter" }) do
			pcall(function() local v = seg[f]; if v ~= nil then n[f] = v end end)
		end
		seg = n
	end
	log("NATIVE REPLAY " .. tostring(a.uid) .. " segment " .. tostring(step.edge) .. ": owner " .. tostring(have) .. " -> " .. tostring(want) .. " (the tool's)")
	return seg
end

local function replayUpgrade(a, plan, i)
	local step = plan[i]
	if not step then return end
	local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(step.edge, step.template) end)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": no proposal " .. tostring(P))
		return replayUpgrade(a, plan, i + 1)
	end
	if step.nc then
		local okn, errn = pcall(function()
			local sp = P.proposal
			sp.nodeConfigsToAdd = C.nodeConfigs(step.nc)
			if #step.ncr > 0 then sp.nodeConfigsToRemove = step.ncr end
			P.proposal = sp
		end)
		if not okn then log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": the tool's junctions not applied (" .. shortErr(errn) .. ")") end
	end
	if step.decorations or step.lanes then
		local okd, errd = pcall(function()
			local sp = P.proposal
			local list = sp.addedSegments
			list[1] = G.stepExtras(a, step, list[1])
			sp.addedSegments = list
			P.proposal = sp
		end)
		if not okd then log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": decorations/lanes not applied (" .. shortErr(errd) .. ")") end
	end
	do
		local oko, erro = pcall(function()
			local sp = P.proposal
			local list = sp.addedSegments
			for k = 1, #list do list[k] = G.stepOwner(a, step, list[k]) end
			sp.addedSegments = list
			P.proposal = sp
		end)
		if not oko then log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": the tool's owner not applied (" .. shortErr(erro) .. ")") end
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = true
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	G.refundInto(ctx)
	toSim("replaying", { tok = a.tsTok })
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

-- An upgrade of several segments at once, as the tool makes it: the engine's upgrade proposal of every segment (replaceSegment,
-- which gives the builder's result exactly for one segment) put together into one new proposal, with the tool's junctions,
-- built at once (the town buildings around are taken away and put back once for the whole street, as by the tool). Returns
-- whether the command was made (else the caller replays it another way).
G.replayMergedUpgrade = function(a, plan, probe)
	local added, removed = {}, {}
	for _, step in ipairs(plan) do
		local okp, Pk = pcall(function() return api.engine.util.proposal.replaceSegment(step.edge, step.template) end)
		if not okp or not Pk then log("NATIVE REPLAY " .. tostring(a.uid) .. " merged upgrade: no proposal for " .. tostring(step.edge)) return false end
		if os.getenv("MPFEVER_MERGEDUMP") == "1" then pcall(function() C.appendFile(C.DIR .. BS .. "merge_dump.txt", "==== replaceSegment(" .. step.edge .. ")" .. NL .. C.dump(Pk):sub(1, 60000) .. NL) end) end
		local okc, errc = pcall(function()
			local spk = Pk.proposal
			-- (a new street type with trees: its decorations, as on the upgrade of one segment)
			if (step.decorations or step.lanes) and #spk.addedSegments ~= 1 then error(#spk.addedSegments .. " new segments for decorations/lanes") end
			for j = 1, #spk.addedSegments do
				local seg = spk.addedSegments[j]
				if (step.decorations or step.lanes) and os.getenv("MPFEVER_MERGEDECO") ~= "0" then seg = G.stepExtras(a, step, seg) end
				seg = G.stepOwner(a, step, seg)
				seg.entity = -(#added + 1)
				added[#added + 1] = seg
			end
			for j = 1, #spk.removedSegments do removed[#removed + 1] = spk.removedSegments[j] end
		end)
		if not okc then log("NATIVE REPLAY " .. tostring(a.uid) .. " merged upgrade: segment " .. tostring(step.edge) .. " (" .. shortErr(errc) .. ")") return false end
	end
	local P = api.type.Proposal.new()
	local okm, errm = pcall(function()
		local sp = P.proposal
		sp.addedSegments = added
		sp.removedSegments = removed
		-- (the tool's junctions: their lane connections name the new segments -1, -2... in the tool's order, the same as here
		-- when the tool lists its new segments in the order of its removed ones; MPFEVER_MERGENC=0: the engine's own)
		local st = probe[1] and probe[1].proposal
		if st and os.getenv("MPFEVER_MERGENC") ~= "0" and #(st.nodeConfigsToAdd or {}) > 0 then
			sp.nodeConfigsToAdd = C.nodeConfigs(st.nodeConfigsToAdd)
			local ncr = {}
			for _, n in ipairs(st.nodeConfigsToRemove or {}) do if type(n) == "number" and n >= 0 then ncr[#ncr + 1] = n end end
			if #ncr > 0 then sp.nodeConfigsToRemove = ncr end
		end
		P.proposal = sp
	end)
	if not okm then log("NATIVE REPLAY " .. tostring(a.uid) .. " merged upgrade not made (" .. shortErr(errm) .. ")") return false end
	if os.getenv("MPFEVER_MERGEDUMP") == "1" then pcall(function() C.appendFile(C.DIR .. BS .. "merge_dump.txt", "==== merged" .. NL .. C.dump(P):sub(1, 60000) .. NL) end) end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = true
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	G.refundInto(ctx)
	local okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true) end)
	if not okk or not cmd then log("NATIVE REPLAY " .. tostring(a.uid) .. " merged upgrade: command " .. shortErr(cmd)) return false end
	log("NATIVE REPLAY " .. tostring(a.uid) .. ": an upgrade of " .. #plan .. " segments at once, merged")
	toSim("replaying", { tok = a.tsTok })
	replaySend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " merged upgrade: " .. (success and "BUILT" or ("refused " .. why .. " (desync)")))
		if not success and G.replayFailedFn then G.replayFailedFn(a, "merged upgrade refused") end
	end)
	return true
end

-- A pure removal (bulldozer): the engine's own removal proposal
local function removalPlan(margs)
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return nil end
	if #(st.addedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return nil end
	-- town buildings demolished with the road (toRemove) are recomputed by every game's own removal proposal; the player's own
	-- constructions in it are added to that proposal by engineReplay
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

-- cons: the player's constructions the tool removed with the segments (a street station bulldozed with its entrance
-- street): the engine's segment removal leaves them, then the station stayed connected to a removed node and the game
-- crashed (issue #15)
local function engineReplay(a, what, makeP, cons)
	local okp, P = pcall(makeP)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": no proposal " .. tostring(P))
		return
	end
	if cons and #cons > 0 then
		local okr, er = pcall(function()
			local l, have = {}, {}
			for i = 1, #P.toRemove do l[#l + 1] = P.toRemove[i]; have[P.toRemove[i]] = true end
			for _, e in ipairs(cons) do if not have[e] then l[#l + 1] = e end end
			P.toRemove = l
		end)
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": constructions removed with it {" .. table.concat(cons, ",") .. "}" .. (okr and "" or (" NOT WRITTEN " .. shortErr(er))))
		if not okr then pcall(send, "replay_failed", { uid = tostring(a.uid), why = "constructions of a removal" }) return end
	end
	-- the bulldozer's own settings, as the tool built it (issue #20: with terrain alignment and buildings gathered, the
	-- same removal cost money on the other games, and may have reshaped the ground)
	local ctx = api.type.Context.new()
	local bits = tonumber(a.ctx)
	if bits and bits >= 32 then
		ctx.gatherBuildings = bits % 2 == 1
		ctx.checkTerrainAlignment = math.floor(bits / 2) % 2 == 1
		ctx.cleanupStreetGraph = math.floor(bits / 4) % 2 == 1
	else
		ctx.checkTerrainAlignment = false
		ctx.cleanupStreetGraph = true
		ctx.gatherBuildings = false
	end
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	G.refundInto(ctx)
	toSim("replaying", { tok = a.tsTok })
	replaySend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": " .. (success and "BUILT" or ("refused " .. why)))
		if not success then pcall(send, "replay_failed", { uid = tostring(a.uid), why = ("removal refused " .. why):sub(1, 120) }) end
	end)
end

-- A stop placed on an existing street (the stop tool): rebuilt as the street tool would, from this game's segment
local function sVec(q) return api.type.Vec3f.new(q.x, q.y, q.z) end
local function sNodePos(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and { x = c.position.x, y = c.position.y, z = c.position.z } or nil
end
-- The context of a replayed stop or signal: the stop and signal tools clean nothing up. With cleanupStreetGraph the engine
-- reshaped the street around the replayed stop (issue #63: 4 segments and 2 nodes here, 1 segment on the builder's game,
-- so every later entity was numbered differently). The tool's own flags when the act carries them (bits of a.ctx, 32 and
-- up: a tool's build); MPFEVER_STOPCLEANUP=1 brings back the old context.
local function sContext(a, cleanup)
	local c = api.type.Context.new()
	local bits = a and tonumber(a.ctx)
	c.checkTerrainAlignment = false
	c.cleanupStreetGraph = cleanup == true or os.getenv("MPFEVER_STOPCLEANUP") == "1"
	c.gatherBuildings = false
	if bits and bits >= 32 and not cleanup and os.getenv("MPFEVER_STOPCLEANUP") ~= "1" then
		c.gatherBuildings = bits % 2 == 1
		c.checkTerrainAlignment = math.floor(bits / 2) % 2 == 1
		c.cleanupStreetGraph = math.floor(bits / 4) % 2 == 1
	end
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	G.refundInto(c)
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

-- A tool's stop or signal pays nothing for the segment it replaces (the street or track under it); a script's command pays a
-- quarter of that segment's price for it (the Context's refund factor 0.75 against the replaced segment: 15 per metre of a town
-- street, issue #62), and the money was then booked back (REFUND.book). The replay of a tool's build (its flags came with it,
-- a.ctx) is sent with doDust set, which the native module turns into the same terms (refund factor 1.0). Only what was measured
-- against the tools: new stops or signals on a segment of the same template, none removed, the street not cleaned up (not the
-- bulldozer on a stop, nor the stops placed again after a street build, plan.after: what their builder paid is not known; the
-- bookings still even out any difference). MPFEVER_REPLACEFREE=0: as before; MPFEVER_REPLACEFREE=builder (tests): the replays as
-- before, the dstop scenario's builder still priced like the tool.
-- Whether the builder's tool sent its build with ignoreErrors (bit 8 of a.ctx: a signal's own window, which changes the signal
-- in place, does; the tools do not). MPFEVER_EOIGNORE=1 (tests): every replayed stop and signal as if it did
G.toolIgnoresErrors = function(a)
	local bits = tonumber(a and a.ctx)
	return (bits ~= nil and bits >= 32 and math.floor(bits / 8) % 2 == 1) or os.getenv("MPFEVER_EOIGNORE") == "1"
end

G.toolCosts = function(a, plan)
	local bits = tonumber(a and a.ctx)
	local sw = os.getenv("MPFEVER_REPLACEFREE")
	return bits ~= nil and bits >= 32 and math.floor(bits / 4) % 2 == 0 and #(plan.objs or {}) > 0 and next(plan.removeIdx or {}) == nil
		and not plan.after and not plan.plainCosts and not plan.cleanup and os.getenv("MPFEVER_STOPCLEANUP") ~= "1"
		and sw ~= "0" and sw ~= "builder"
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
	-- this game's segment runs the other way round than the builder's (an earlier replay rebuilt it so): the tool's place
	-- along the segment, side, lanes and junction lanes all count from the builder's first node, so the new segment is
	-- made the builder's way round. Kept as it was, the stop went to the mirror place on the other pavement (a manual
	-- test: 2 town buildings taken away here, none on the builder's game). Not with stops already on the segment, whose
	-- places count from this game's first node. MPFEVER_STOPREVERSE=0: as before
	local rev = not plan.after and #c.objects == 0 and os.getenv("MPFEVER_STOPREVERSE") ~= "0" and type(sc.node0) == "number"
		and sc.node0 == c.node1 and sc.node1 == c.node0 and c.node0 ~= c.node1
	-- The segment's own ends (BASE_EDGE position0/1), exactly as the stop tool keeps them: on town streets an end may lie off
	-- its node (0.55 m, 0.08 m, down to one float step, 0.0005 m, in the session of 2026-10-24), and a copy whose ends differ
	-- at all is laid on the ground again by the engine, whatever the Context says: the terrain aligned, town buildings taken
	-- away and put back, on the replaying games only (the resyncs of 23:35 and 23:38, stops 177, 183 and 187). Rebuilt with its
	-- own ends, an offset segment stays where it is (the native street replays copy the ends: 8 of them rebuilt offset segments
	-- in that session, none laid one again).
	-- An end more than 2 m from its node on any axis is taken for a bad read: the node's position then, logged once.
	-- MPFEVER_STOPNODEPOS=1: the nodes' positions, as before
	local function segEnd(k)
		local np = sNodePos((k == 0) and c.node0 or c.node1)
		if os.getenv("MPFEVER_STOPNODEPOS") ~= "1" then
			local okp, q = pcall(function() local v = (k == 0) and c.position0 or c.position1; return { x = v.x, y = v.y, z = v.z } end)
			if okp and type(q) == "table" and type(q.x) == "number" and type(q.y) == "number" and type(q.z) == "number" then
				if not np and q.x == q.x and q.y == q.y and q.z == q.z then return sVec(q) end
				if np and math.abs(q.x - np.x) < 2 and math.abs(q.y - np.y) < 2 and math.abs(q.z - np.z) < 2 then return sVec(q) end
			end
			if not plan.endLogged then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: segment " .. plan.E .. " end " .. k .. " not usable ("
					.. (okp and "far from its node" or shortErr(q)) .. "): its node's position")
			end
			plan.endLogged = true
		end
		return sVec(np)
	end
	if rev then
		if not plan.revLogged then log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: segment " .. plan.E .. " runs the other way round here: rebuilt the builder's way round") end
		plan.revLogged = true
		cc.node0 = c.node1; cc.node1 = c.node0
		cc.tangent0 = api.type.Vec3f.new(-c.tangent1.x, -c.tangent1.y, -c.tangent1.z)
		cc.tangent1 = api.type.Vec3f.new(-c.tangent0.x, -c.tangent0.y, -c.tangent0.z)
		-- (the new segment starts at this game's second node, whose end is this segment's position1)
		cc.position0 = segEnd(1); cc.position1 = segEnd(0)
	else
		cc.node0 = c.node0; cc.node1 = c.node1
		cc.tangent0 = sVec(c.tangent0); cc.tangent1 = sVec(c.tangent1)
		cc.position0 = segEnd(0); cc.position1 = segEnd(1)
	end
	-- (once per build, when the segment's ends lie off its nodes here or the ends sent differ from the builder's segment: how
	-- far, for the reports, see tools/stopacts.py. With plan.after the builder's segment may run the other way round: the
	-- nearer way is measured)
	if not plan.endsLogged then
		plan.endsLogged = true
		pcall(function()
			local function d(p, q)
				if type(p) ~= "table" or type(q) ~= "table" or type(q.x) ~= "number" then return -1 end
				return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
			end
			local okO, o0, o1 = pcall(function()
				return { x = c.position0.x, y = c.position0.y, z = c.position0.z }, { x = c.position1.x, y = c.position1.y, z = c.position1.z }
			end)
			local n0 = okO and d(o0, sNodePos(c.node0)) or -1
			local n1 = okO and d(o1, sNodePos(c.node1)) or -1
			local p0 = { x = cc.position0.x, y = cc.position0.y, z = cc.position0.z }
			local p1 = { x = cc.position1.x, y = cc.position1.y, z = cc.position1.z }
			local b0, b1 = d(p0, sc.position0), d(p1, sc.position1)
			local r0, r1 = d(p0, sc.position1), d(p1, sc.position0)
			if plan.after and r0 >= 0 and r1 >= 0 and (b0 < 0 or b1 < 0 or r0 + r1 < b0 + b1) then b0, b1 = r0, r1 end
			if n0 > 0 or n1 > 0 or b0 > 0 or b1 > 0 then
				log(string.format("NATIVE REPLAY %s stop: segment %s ends off its nodes here by %.5f/%.5f m, the ends sent off the builder's by %.5f/%.5f m (%s)",
					tostring(a.uid), tostring(plan.E), n0, n1, b0, b1,
					(os.getenv("MPFEVER_STOPNODEPOS") == "1") and "its nodes' positions, MPFEVER_STOPNODEPOS=1" or "its own ends kept"))
			end
		end)
	end
	-- the segment as it is (a stop or a signal changes none of these): a tunnel or a bridge stays one (type 2 / 1 and its
	-- index; written 0 / -1, a signal turned the tunnel into track dug in the ground), and a track keeps its distance
	-- (5: with 0 the games differed) and decorations (issue #16)
	cc.type = (type(c.type) == "number") and c.type or 0
	cc.typeIndex = (type(c.typeIndex) == "number") and c.typeIndex or -1
	pcall(function() if type(c.distance) == "number" and c.distance ~= 0 then cc.distance = c.distance end end)
	pcall(function()
		if #c.edgeDecorations == 0 then return end
		if not rev then cc.edgeDecorations = c.edgeDecorations; return end
		-- (a decoration's side counts from the first node too)
		local deco = {}
		for k = 1, #c.edgeDecorations do local d = c.edgeDecorations[k]; deco[k] = { d[1], not d[2] } end
		cc.edgeDecorations = deco
	end)
	cc.roadTemplate = sc.roadTemplate or c.roadTemplate
	cc.roadStyle = sc.roadStyle or c.roadStyle
	cc.roadType = c.roadType
	-- whether the town may develop the street, kept as the stop tool keeps it: a locked street replayed unlocked would be
	-- upgraded by its town on the replaying games only (false in every stop of the 2026-10-24 session: not yet seen to differ).
	-- MPFEVER_STOPDEVLOCK=0: as before (the new segment's default)
	if os.getenv("MPFEVER_STOPDEVLOCK") ~= "0" then pcall(function() cc.roadDevelopmentLocked = c.roadDevelopmentLocked == true end) end
	-- lanes as the stop tool computed them: on a street without sidewalks it adds the platform lanes, without which
	-- the engine accepts the build but silently drops the stop
	local capLanes = sc.laneConfigs
	if type(capLanes) == "table" and #capLanes > 0 then
		cc.laneConfigs = C.rebuildLanes(capLanes)
	elseif rev then
		-- (this game's lanes the other way round: from the other side, each in the other direction)
		local rl = {}
		for k = #c.laneConfigs, 1, -1 do
			local l = C.marshal(c.laneConfigs[k])
			l.forward = not l.forward
			if type(l.offset) == "number" then l.offset = -l.offset end
			rl[#rl + 1] = l
		end
		cc.laneConfigs = C.rebuildLanes(rl)
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
	-- the segment's owner, as the stop tool kept it (else the segment it replaces): without it the new segment belonged to
	-- nobody here and to its company on the builder's game (separate companies: "owners" desync, then a resynchronisation)
	local owner = type(plan.seg.playerOwned) == "table" and plan.seg.playerOwned.player or nil
	if type(owner) ~= "number" then owner = R.ownerOf(plan.E) end
	if type(owner) == "number" and owner >= 0 then
		pcall(function() local po = C.newOf("PlayerOwned"); po.player = owner; e.playerOwned = po end)
	end
	local se = e.streetEdge
	se.precedenceNode0 = (plan.seg.streetEdge and plan.seg.streetEdge.precedenceNode0) or 2
	se.precedenceNode1 = (plan.seg.streetEdge and plan.seg.streetEdge.precedenceNode1) or 2
	e.streetEdge = se
	-- the segment's noise and pollution as the stop or signal tool gave its copy (a script's segment gets none, see C.rebuild's
	-- SegmentAndEntity); MPFEVER_EMITTERS=0: as before
	if type(plan.seg.emissionEmitter) == "table" and os.getenv("MPFEVER_EMITTERS") ~= "0" then
		local oke, erre = pcall(function() e.emissionEmitter = C.rebuild("EmissionEmitter", plan.seg.emissionEmitter) end)
		if not oke and not G.emitterErr then G.emitterErr = true; log("NATIVE REPLAY stop: the segment's emission emitter not copied (" .. shortErr(erre) .. ")") end
	end
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
		C.setEdgeObjectParams(eo, o)
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
	-- and the configurations the stop tool puts back on them (lane connections, crosswalks): without them the junctions of the
	-- replaced segment were left without, unlike the player's game, and a later build there differed (variant 3: without)
	if variant < 3 and #(plan.nodeConfigs or {}) > 0 then
		local okn, errn = pcall(function() ssp.nodeConfigsToAdd = C.nodeConfigs(plan.nodeConfigs) end)
		if not okn then log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: node configurations not copied: " .. tostring(errn)) end
	end
	sp.streetProposal = ssp
	-- (diagnostic, MPFEVER_STOPALIGNPROBE=1: a stop on a bridge or in a tunnel, =all: every stop; once per replay, nothing built:
	-- which form of the replay shapes the ground, see G.stopAlignProbe. plan.probeOnly: H.bridgestopprobe, the proposal is only
	-- probed, never sent)
	local probeSw = os.getenv("MPFEVER_STOPALIGNPROBE")
	if (plan.probeOnly or (probeSw and probeSw ~= "0")) and not plan.alignProbed then
		plan.alignProbed = true
		if plan.probeOnly or probeSw == "all" or ((type(c.type) == "number") and c.type or 0) ~= 0 then
			local okq, errq = pcall(G.stopAlignProbe, a, plan, sp, function() return sContext(not plan.after and a or nil, plan.cleanup) end)
			if not okq then log("STOPALIGNPROBE " .. tostring(a.uid) .. " failed: " .. shortErr(errq)) end
		end
		if plan.probeOnly then return end
	end
	local free = G.toolCosts(a, plan) and cc.roadTemplate == c.roadTemplate
	local okf, cmd = pcall(function()
		-- (a stop on a bridge or in a tunnel shapes the ground here and not on the builder's game whatever this context says: the
		-- stop tool's flags (32) already ask for no terrain alignment, the engine still aligns the ground around the rebuilt bridge
		-- segment (77.517/117.783 against the builder's 0/0, 2026-10-25). The check of 0.5.1 that turned the alignment off here
		-- never fired and is gone; see G.replayNativeStop (the tool's own native proposal) and SIM.townStats (the resynchronisation
		-- asked for at once when the towns would drift))
		local ctx = sContext(not plan.after and a or nil, plan.cleanup)
		-- (there, a builder's build that left the towns alike is replayed as a script's build, which the towns ignore as they
		-- ignored the builder's: G.stopNoTown. Issue #85: signals on track bridges, "TOWN STATS DIFFER" and a reload each time)
		local pi = not (a and ((type(c.type) == "number") and c.type or 0) ~= 0 and G.stopNoTown(a))
		local ign = not plan.after and G.toolIgnoresErrors(a)
		if free then return api.cmd.makeWorldBuildProposalCmd(sp, ctx, ign, pi, true) end
		return api.cmd.makeWorldBuildProposalCmd(sp, ctx, ign, pi)
	end)
		if okf and cmd then log("NATIVE REPLAY " .. tostring(a.uid) .. " stop context: tool flags " .. tostring(a.ctx)) end
	if not okf or not cmd then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: factory (variant " .. variant .. ") " .. shortErr(cmd))
		if free then plan.plainCosts = true; return replayStop(a, plan, variant) end
		if variant < 2 then return replayStop(a, plan, variant + 1) end
		return
	end
	local function stopCount()
		local n = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
		return n
	end
	local before = stopCount()
	toSim("replaying", { tok = a.tsTok })
	replaySend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop on segment " .. plan.E .. ": " .. (success and "BUILT" or ("refused " .. why)) .. (free and ", priced like the tool's build" or ""))
		-- (refused in that form: once more without it, which pays the quarter of the replaced segment, booked back as before)
		if not success and free then
			plan.plainCosts = true
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: tried again without the tool's pricing")
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayStop(a, plan, variant) end }
			return
		end
		-- (built on the player's game: a refusal here means the games differ, the host reloads at once)
		-- (refused without the street cleanup, "Collision" in a test: tried once more with it, as before 0.3.21)
		if not success and not plan.cleanup then
			plan.cleanup = true
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: tried again with the street cleanup")
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayStop(a, plan, variant) end }
			return
		end
		if not success then pcall(send, "replay_failed", { uid = tostring(a.uid), why = ("stop refused " .. why):sub(1, 120) }) end
		if success then
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local after = stopCount()
				local expected = before + #plan.objs - #removeIds
				local owners = {}
				pcall(function()
					for _, sg in ipairs(R.allEdges()) do
						local c = api.engine.getComponent(sg, api.type.ComponentType.BASE_EDGE)
						if c and c.node0 == cc.node0 and c.node1 == cc.node1 then owners[#owners + 1] = sg .. ":" .. tostring(R.ownerOf(sg)) end
					end
				end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stops on the map " .. before .. " -> " .. after .. ((after == expected) and "" or (" (EXPECTED " .. expected .. ")"))
				.. ", segment owner " .. tostring(owner) .. " (here " .. table.concat(owners, ",") .. ")")
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
		-- every colliding entity, once: what it is and where
		pcall(function()
			local seen, out = {}, {}
			for _, ce in ipairs(rpd.collisionInfo.collisionEntities) do
				local ent = ce.entity
				if not seen[ent] then
					seen[ent] = true
					local d = tostring(ent)
					pcall(function()
						local be = api.engine.getComponent(ent, api.type.ComponentType.BASE_EDGE)
						if be then
							local p = api.engine.getComponent(be.node0, api.type.ComponentType.BASE_NODE).position
							d = d .. " edge(" .. string.format("%.0f %.0f", p.x, p.y) .. ")" .. tostring(be.roadTemplate):match("[^/]*$")
						end
					end)
					pcall(function()
						local c = api.engine.getComponent(ent, api.type.ComponentType.CONSTRUCTION)
						if c then d = d .. " con " .. tostring(c.fileName):match("[^/]*$") .. string.format("(%.0f %.0f)", c.transf[13], c.transf[14]) end
					end)
					out[#out + 1] = d
				end
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: " .. #out .. " colliding entities: " .. table.concat(out, " | "):sub(1, 1500))
		end)
	end)
end

-- a build this game could not reproduce: the host reloads its game for everybody at once (without waiting for the
-- next checkpoints to notice the difference)
local function replayFailed(a, why)
	pcall(send, "replay_failed", { uid = tostring(a.uid), why = tostring(why):sub(1, 120) })
end
G.replayFailedFn = replayFailed

-- the verdict of a replayed action for the host: a refusal is counted; an action skipped because something it refers to
-- is missing here means the games already differ, so the host's game is reloaded at once (issue #12: the next action
-- of the same player crashed the game before the next state check)
function G.reportResult(r)
	if r.success then return end
	send("act_refused", { uid = r.uid, fn = r.fn, err = r.err })
	if tostring(r.err or ""):find("^DESYNC") then replayFailed(r, r.err) end
end

-- the street segments a construction brings with it (the entrance of a depot or of a street station, the paths of a
-- rail station): they belong to the construction, whose own script makes them
local function isConstructionSegment(sg)
	local tpl = tostring(sg and sg.comp and sg.comp.roadTemplate or "")
	-- (street entrances, the tracks of rail stations (simple, simple_catenary), the runways and taxiways of airports, the
	-- tracks of rail depots)
	return tpl:find("/constructions/", 1, true) ~= nil or tpl:find("/track/simple/simple[%w_]*%.street_template") ~= nil
		or tpl:find("/street/airport/", 1, true) ~= nil or tpl:find("/rail_depot[%w_]*%.street_template") ~= nil
end

-- A station, depot, airport or port of a player (not a town building): its tracks may be of any type. A modular station
-- whose tracks were set to standard or high-speed track had none of the templates above, its edit was rebuilt by the
-- script forms and then in two steps, and the engine asserted and the game crashed (issues #65 and #67)
-- The road junctions of the street tool (roundabout, T, trumpet, cloverleaf, diamond... in street_construction/) too: their
-- streets were rebuilt by the script forms and refused by the engine ("Construction impossible"), a desync each (issue #72)
local function isTransportConstruction(ce)
	local f = tostring(type(ce) == "table" and ce.fileName or "")
	return f:find("/stations/", 1, true) ~= nil or f:find("depot", 1, true) ~= nil or f:find("airport", 1, true) ~= nil
		or f:find("airfield", 1, true) ~= nil or f:find("harbor", 1, true) ~= nil
		or (f:find("/street_construction/", 1, true) ~= nil and os.getenv("MPFEVER_JUNCTIONCON") ~= "0")
end

local function hasConstructionSegments(m)
	if type(m) ~= "table" or #(m.toAdd or {}) == 0 or type(m.proposal) ~= "table" then return false end
	for _, sg in ipairs(m.proposal.addedSegments or {}) do if isConstructionSegment(sg) then return true end end
	if #(m.proposal.addedSegments or {}) > 0 and os.getenv("MPFEVER_CONBYFILE") ~= "0" then
		for _, ce in ipairs(m.toAdd) do if isTransportConstruction(ce) then return true end end
	end
	return false
end

-- an existing station (or depot...) rebuilt with other tracks or modules: the engine's removal of the old one with the
-- new one is only safe as the tool's own native proposal. The script forms and the two-step replay make proposals the
-- engine asserts on (a segment removed twice, then a missing component: the game crashed, issues #65 and #67): such a
-- build is reported as not reproduced, and the host's game is reloaded everywhere instead
local function editsConstruction(m)
	return type(m) == "table" and #(m.toRemove or {}) > 0 and hasConstructionSegments(m) and os.getenv("MPFEVER_EDITFORMS") ~= "1"
end

-- Whether a build takes away segments that are the own (frozen) tracks of a construction it replaces (m: translated to this
-- game's entities). A modular station edited until tracks went and no new one came (issue #90: no new segment, so not seen by
-- hasConstructionSegments nor editsConstruction) was rebuilt by the script forms, which the engine refused (a segment removed
-- twice, once as the old station's own), then in two steps: the street part took the station's tracks away, the construction
-- was then refused, the station kept tracks that no longer existed (assertion 'it != components.end()' on them), and the
-- resynchronisation's save crashed the host's game. Every later edit of that station failed the same way.
G.ownTracksRemoved = function(m)
	-- (a construction replaced, not only taken away: a station bulldozed has its own removal, see removalPlan)
	if type(m) ~= "table" or type(m.proposal) ~= "table" or #(m.toRemove or {}) == 0 or #(m.toAdd or {}) == 0
		or #(m.proposal.removedSegments or {}) == 0 then return false end
	local own, nOwn = {}, 0
	for _, c in ipairs(m.toRemove) do
		local id = type(c) == "table" and c.entity or c
		if type(id) == "number" and id >= 0 then
			pcall(function()
				local con = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
				if con then for i = 1, #con.frozenEdges do own[con.frozenEdges[i]] = true; nOwn = nOwn + 1 end end
			end)
		end
	end
	-- (and, second, whether it takes them ALL away: the new construction keeps no own track, issue #97, see G.replayByReplace)
	local any, gone = false, 0
	for _, sg in ipairs(m.proposal.removedSegments) do
		if type(sg) == "table" and own[sg.entity] then any = true; gone = gone + 1; own[sg.entity] = nil end
	end
	return any, any and gone >= nOwn
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

-- The edit of a station that took its last own tracks away (issue #97: a modular street station, one module fewer, one
-- segment and two nodes gone, no segment added). The conversion below makes two copies of the new construction to be
-- refused: two constructions of one proposal are not checked against each other, only their segments are, and this one has
-- none - the conversion was BUILT, two stations on this game, then the host's game was reloaded for everybody. The engine's
-- own replacement of the station with the tool's parameters instead, built only if it takes away exactly what the tool took
-- away; else nothing is built and the host's game is reloaded. (MPFEVER_EDITREPLACE=0: the conversion, as before)
G.replayByReplace = function(a)
	local function no(why)
		log("NATIVE REPLAY " .. tostring(a.uid) .. " station edit by the engine's replacement: " .. why .. ": not built (desync)")
		replayFailed(a, "station edit not replayed")
		return true
	end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then return no("unresolved " .. table.concat(miss, ",")) end
	local m = cArgs[1]
	if #(m.toAdd or {}) ~= 1 or #(m.toRemove or {}) ~= 1 then return no(#(m.toAdd or {}) .. " construction(s) added, " .. #(m.toRemove or {}) .. " removed") end
	local old = type(m.toRemove[1]) == "table" and m.toRemove[1].entity or m.toRemove[1]
	local oc = type(old) == "number" and api.engine.getComponent(old, api.type.ComponentType.CONSTRUCTION) or nil
	if not oc or tostring(oc.fileName) ~= tostring(m.toAdd[1].fileName) then return no("not the same construction") end
	local params = C.plain(m.toAdd[1].params or {})
	local okp, P = pcall(function() return api.engine.util.proposal.createProposalReplaceConstruction(old, params) end)
	if not okp or not P then return no("no proposal (" .. shortErr(P) .. ")") end
	-- (what it takes away and adds, against the tool's build: the same entities taken away, as many added)
	local function ids(list)
		local t = {}
		-- (the tool's side: plain tables after the translation; the engine's: its own objects, userdata, read by their field)
		pcall(function()
			for i = 1, #list do
				local x = list[i]
				local id = x
				if type(x) ~= "number" then id = x.entity end
				t[#t + 1] = tonumber(id) or -1
			end
		end)
		table.sort(t)
		for i, v in ipairs(t) do t[i] = tostring(v) end
		return table.concat(t, ",")
	end
	local tp, ep = m.proposal or {}, nil
	pcall(function() ep = P.proposal end)
	if not ep then return no("no street part") end
	local cmp = {
		{ "removed segments", ids(tp.removedSegments or {}), ids(ep.removedSegments) },
		{ "removed nodes", ids(tp.removedNodes or {}), ids(ep.removedNodes) },
		{ "added segments", tostring(#(tp.addedSegments or {})), tostring(#ep.addedSegments) },
		{ "added nodes", tostring(#(tp.addedNodes or {})), tostring(#ep.addedNodes) },
		{ "constructions", "1", tostring(#P.toAdd) },
	}
	local diff = {}
	for _, c in ipairs(cmp) do if c[2] ~= c[3] then diff[#diff + 1] = c[1] .. " tool {" .. c[2] .. "} engine {" .. c[3] .. "}" end end
	if #diff > 0 then return no(table.concat(diff, "; ")) end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	G.refundInto(ctx)
	local okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true) end)
	if not okk or not cmd then return no("command " .. shortErr(cmd)) end
	log("NATIVE REPLAY " .. tostring(a.uid) .. " station edit by the engine's replacement: takes away {" .. cmp[1][3] .. "} as the tool did")
	toSim("replaying", { tok = a.tsTok })
	replaySend(cmd, function(res, success)
		if not success then
			local why = ""
			pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " station edit by the engine's replacement: refused " .. why .. " (desync)")
			logRefusal(a, res)
			replayFailed(a, "station edit refused " .. why)
			return
		end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " station edit by the engine's replacement BUILT")
		pcall(function()
			local st = res.proposal.proposal
			log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments .. " +constructions " .. #res.proposal.toAdd)
		end)
	end)
	return true
end

-- (0.6.4, issue #109) Whether the edge objects a construction's build adds are the stops of the street it cuts: a tram depot put
-- on a street with stops, the tool takes them away and re-creates them on the new pieces of that street. All of them on new
-- segments of the build that are not the construction's own (an airport's signs are on its runways: not these), each with its
-- model and its segment's geometry, as G.eoDryRun needs. MPFEVER_CONSTOPS=0: never (the host's game reloaded, as before)
G.conStopsOk = function(m)
	if os.getenv("MPFEVER_CONSTOPS") == "0" then return false end
	local st = type(m) == "table" and m.proposal
	if type(st) ~= "table" or #(st.edgeObjectsToAdd or {}) == 0 then return false end
	local seg = {}
	for _, sg in ipairs(st.addedSegments or {}) do
		if type(sg) == "table" and type(sg.entity) == "number" and sg.entity < 0 then seg[sg.entity] = sg end
	end
	for _, o in ipairs(st.edgeObjectsToAdd) do
		local sg = type(o) == "table" and type(o.model) == "string" and seg[o.segmentEntity] or nil
		local c = sg and sg.comp
		if type(c) ~= "table" or isConstructionSegment(sg) or type(c.position0) ~= "table" or type(c.position1) ~= "table"
			or type(c.tangent0) ~= "table" or type(c.tangent1) ~= "table" then return false end
	end
	return true
end

local function replayNativeConstruction(a)
	local m0 = a.args[1]
	if not hasConstructionSegments(m0) and not a.industryEdit and not a.ownTracks then return false end
	-- (0.5.14, issue #97: a station edit that takes ALL its own tracks away; one that keeps some, issue #90, the conversion below)
	if a.ownTracks and a.ownTracksAll and not hasConstructionSegments(m0) and os.getenv("MPFEVER_EDITREPLACE") ~= "0" then return G.replayByReplace(a) end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: unresolved " .. table.concat(miss, ",")) return false end
	local m = cArgs[1]
	-- the engine's conversion of the construction (twice: guaranteed collision, so that nothing is built)
	local spCon = C.rebuildProposal(m, { noStreet = true, seed = 7919 })
	local cons = {}
	do
		local one = spCon.constructionsToAdd
		-- (every construction of the build, in the tool's order: a junction and the farm it cuts, see
		-- C.rebuildNativeWithConstruction; then the first one again, the collision)
		local nc = os.getenv("MPFEVER_ALLCONS") ~= "0" and #one or 1
		for i = 1, nc do cons[i] = one[i] end
		local two = C.rebuildProposal(m, { noStreet = true, seed = 7919 }).constructionsToAdd
		cons[nc + 1] = two[1]
		spCon.constructionsToAdd = cons
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = false
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = true
	ctx.gatherFields = os.getenv("MPFEVER_CONVFIELDS") ~= "0"
	ctx.player = api.engine.util.getPlayer()
	G.refundInto(ctx)
	local okc, dry = pcall(function() return api.cmd.makeWorldBuildProposalCmd(spCon, ctx, false, true) end)
	if not okc or not dry then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: conversion command " .. shortErr(dry)) return false end
	toSim("replaying", { tok = a.tsTok })
	local edgesBefore = #R.allEdges()
	local objsBefore = 0
	pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do objsBefore = objsBefore + 1 end end)
	replaySend(dry, function(res, success)
		if success then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the conversion command was built instead of refused (desync)")
			replayFailed(a, "conversion built")
			return
		end
		local conv = res.proposal
		-- the construction's edge objects (an airport's signs) as the engine converts them: a script cannot write a native
		-- edge object's model ("no writable member 'model'", issue #50). The conversion has them once per converted copy
		-- of the construction (C.nativeEdgeObjects matches them by model, place and side)
		local eoNative = nil
		if #(m.proposal.edgeObjectsToAdd or {}) > 0 and os.getenv("MPFEVER_CONEO") ~= "0" then
			pcall(function()
				local eo = conv.proposal.edgeObjectsToAdd
				eoNative = {}
				for i = 1, #eo do eoNative[i] = eo[i] end
			end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the engine's conversion has " .. tostring(eoNative and #eoNative or "no")
				.. " edge object(s), the tool's build " .. #m.proposal.edgeObjectsToAdd)
		end
		pcall(function()
			local function keys(p)
				local t = {}
				pcall(function() for k in pairs(p.modules) do t[#t + 1] = tostring(k) end end)
				table.sort(t)
				return table.concat(t, ",")
			end
			local cp = conv.toAdd[1].params
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: modules tool {" .. keys(m.toAdd[1].params) .. "} converted {" .. keys(cp) .. "} seed " .. tostring(m.toAdd[1].params.seed) .. "/" .. tostring(cp.seed))
		end)
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
		-- (0.6.4, issue #109: the stops of the street the construction cuts, which the tool re-creates on the new pieces of that
		-- street, are not in the engine's conversion of the construction: they are taken from a dry run as for a street build,
		-- G.eoDryRun, and go in the same proposal; before, the construction was built without them and the host's game reloaded)
		local eoRank, eoRes = false, nil
		local function finish()
			-- the construction's edge objects (an airport's signs on its own runways and taxiways, issue #50) go in the same
			-- proposal, as the tool's; if this game cannot make it so, the replay goes without them and the host's game is
			-- reloaded once built (they are never placed afterwards: issue #49)
			local nEO = #(m.proposal.edgeObjectsToAdd or {})
			local withObjects = nEO > 0 and type(eoNative) == "table" and #eoNative >= nEO
			local ctx2 = api.type.Context.new()
			ctx2.checkTerrainAlignment = true
			ctx2.cleanupStreetGraph = false
			-- (0.6: a computer company's garage keeps the town buildings in its way, the build then fails on every game instead of
			-- taking them down: a.keepBuildings, set by mpfever_ai.lua, MPFEVER_AIKEEPBUILDINGS=0 there: not set, as before)
			ctx2.gatherBuildings = a.keepBuildings ~= true
			ctx2.gatherFields = true
			ctx2.player = api.engine.util.getPlayer()
			G.refundInto(ctx2)
			if a.keepBuildings == true then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the town buildings in its way are kept (a computer company's build)") end
			local okk, cmd = false, nil
			if withObjects then
				C.errors = {}
				local okw, PW = pcall(C.rebuildNativeWithConstruction, m, conv, rm, { toolNodes = toolNodes, withObjects = eoNative,
					eoByRank = eoRank or nil, eoMaps = eoRank and os.getenv("MPFEVER_EOMAPS") ~= "0" or nil })
				if okw and PW then okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(PW, ctx2, false, true) end) end
				if okk and cmd then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: with its " .. nEO .. " edge object(s)")
				else
					log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: not made with its " .. nEO .. " edge object(s) ("
						.. (okw and shortErr(cmd) or tostring(PW):gsub("^.*%.lua" .. string.char(34) .. "%]:%d+: ", ""):sub(1, 700)) .. "): without them, then resynchronisation")
					okk, cmd, withObjects = false, nil, false
				end
			end
			local okp, P = true, nil
			if not cmd then
				C.errors = {}
				okp, P = pcall(C.rebuildNativeWithConstruction, m, conv, rm, { toolNodes = toolNodes })
			end
			if not cmd and (not okp or not P) then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: not rebuilt (" .. shortErr(P) .. ")") replayFailed(a, "native rebuild") return end
			do
				local notes = {}
				for _, e in ipairs(C.errors) do if not tostring(e):find("no writable member 'params'", 1, true) then notes[#notes + 1] = e end end
				if #notes > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: rebuild notes " .. table.concat(notes, "; ")) end
				log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: frozen nodes of the first construction " .. tostring(C.frozenHow))
				if C.replacedCons then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: replaced as the engine replaces them: " .. C.replacedCons) end
			end
			if not cmd then okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx2, false, true) end) end
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
				-- (0.6: a computer company's garage that keeps the town buildings, a.keepBuildings: not the two-step replay, which gathers
				-- the buildings in its way; the host's game is reloaded instead, as when this replay returns false, see replayAction)
				if a.keepBuildings == true then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: a computer company's build, no two-step replay (it takes buildings down)")
					replayFailed(a, "computer company's build not replayed")
					return
				end
				-- (the street part and the construction in two steps, see replayTwoStep)
				log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: trying the two-step replay")
				if not replayTwoStep(a) then replayFailed(a, "native command") end
				return
			end
			toSim("replaying", { tok = a.tsTok })
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
				-- the edge objects of the tool's build (an airport's or an airfield's signs on its runways and taxiways) are not
				-- made by the engine's conversion. 0.3.13 placed them afterwards as stops are, by rebuilding each segment: those
				-- segments are the construction's own (frozen) edges, the construction kept the removed ones, and the game crashed
				-- as soon as the construction was selected or demolished (assertion 'it != components.end()', BaseEdge; issue
				-- #49). Never rebuilt now: they go in the replay's proposal (checked below), else the host's game is reloaded for
				-- everybody at once (the airport as the host has it).
				if nEO > 0 and not withObjects then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: " .. nEO
						.. " edge object(s) of the construction (an airport's signs) not replayed: resynchronisation")
					replayFailed(a, "construction edge objects (airport signs)")
				end
				pcall(function()
					local st = res2.proposal.proposal
					log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments .. " +constructions " .. #res2.proposal.toAdd)
				end)
				local expected = #(m.proposal.addedSegments or {}) - #(m.proposal.removedSegments or {})
				-- (an airport's signs are edge objects of the tool's build: are they here too?)
				local objExpected = #(m.proposal.edgeObjectsToAdd or {}) - #(m.proposal.edgeObjectsToRemove or {})
				G.waits[#G.waits + 1] = { at = G.frames + 10 + 30 * #(a.stopsAfter or {}) + 30, fn = function()
					local got = #R.allEdges() - edgesBefore
					local objs = 0
					pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do objs = objs + 1 end end)
					log("NATIVE REPLAY " .. tostring(a.uid) .. " edges here " .. got .. ", originator " .. expected .. (got == expected and "" or " SEGMENT COUNT DIFFERS")
						.. (objExpected ~= 0 and (", edge objects here " .. (objs - objsBefore) .. ", originator " .. objExpected
							.. (objs - objsBefore == objExpected and "" or " EDGE OBJECT COUNT DIFFERS")) or ""))
					if withObjects and objs - objsBefore ~= objExpected then replayFailed(a, "construction edge objects differ") end
				end }
			end)
		end
		local nTool = #(m.proposal.edgeObjectsToAdd or {})
		if nTool > 0 and (type(eoNative) ~= "table" or #eoNative < nTool) and G.conStopsOk(m) then
			local okd, dry2, n = pcall(G.eoDryRun, m)
			if not okd or not dry2 then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the dry run of its " .. nTool .. " stop(s) not made (" .. shortErr(dry2) .. ")")
				return finish()
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: " .. n .. " stop(s) of the street it cuts: their conversion by the engine (dry run)")
			replaySend(dry2, function(res3, success3)
				if success3 then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the dry run of its stops was built instead of refused (desync)")
					replayFailed(a, "edge object dry run built")
					return
				end
				local eo = {}
				pcall(function() local l = res3.proposal.proposal.edgeObjectsToAdd; for i = 1, #l do eo[i] = l[i] end end)
				log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the engine's conversion of its stops has " .. #eo .. ", the tool's build " .. n .. " (dry run: twice)")
				if #eo == 2 * n then
					local first = {}
					for i = 1, n do first[i] = eo[i] end
					-- (the converted objects live in that result: kept until the build is made)
					eoNative, eoRank, eoRes = first, true, res3
				end
				finish()
			end)
			return
		end
		finish()
	end)
	return true
end

-- A street build that cuts a segment carrying stops or signals: the native proposal moves them to the new segments (a script
-- proposal strands them). Rebuilt as for a construction against a street, without the construction: the removed segments and
-- nodes as the engine's own removal proposal makes them, the tool's node configurations and id maps (C.rebuildNativeWithConstruction).
-- The stops and signals the tool removed and placed again on the build's new segments (a.stopsAfter, see the stop branch
-- of replayNative): once the street build is applied, one stop build per new segment, found here by the positions of its
-- ends. Used after the script forms and after the native street proposal (issue #28).
G.placeStopsAfter = function(a)
	if not (a.stopsAfter and #a.stopsAfter > 0) then return end
	local groups = a.stopsAfter
	a.stopsAfter = nil
	-- The builder's game has all of them at once, in the build's step. Placed one every 30 frames while the game ran, they came
	-- over a dozen steps here: a track build with 14 signals placed again was checked half done, twice, and the games reloaded
	-- (the trains also met the signals at other times). The game is now held at the build's time until the last one is applied
	-- (G.stopsAfterBusy: nativeHoldAt, runNativeReplays), and each one goes as soon as the one before it is answered (at most
	-- 10 s each). MPFEVER_STOPSAFTEROLD=1: as before.
	local old = os.getenv("MPFEVER_STOPSAFTEROLD") == "1"
	local place, nextPlace
	local function near(p, q)
		return type(p) == "table" and type(q) == "table" and type(q.x) == "number"
			and math.abs(p.x - q.x) < 0.5 and math.abs(p.y - q.y) < 0.5 and math.abs(p.z - q.z) < 0.5
	end
	local function quiet() return (G.replayOut or 0) == 0 and G.frames >= (G.replayQuiet or 0) end
	nextPlace = function(k, since)
		if not groups[k] then
			if quiet() or G.frames - since > 600 then G.stopsAfterBusy = nil; return end
		elseif quiet() or G.frames - since > 600 then
			return place(k)
		end
		G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() nextPlace(k, since) end }
	end
	place = function(k)
		local g = groups[k]
		if not g then G.stopsAfterBusy = nil; return end
		local c = g.seg.comp or {}
		-- The new segment is found by its own ends (BASE_EDGE position0/1) first: the builder's segment ends, which the street
		-- build's replay copies exactly (C.minimalSegment). Its nodes' positions may lie further from them than the 0.5 m
		-- allowed (0.53 m in y on the street of stop 177, 2026-10-24): the stops were then given up ("stops' segment not
		-- found") and everybody reloaded. The nodes' positions are tried next, as before. MPFEVER_AFTERENDS=0: the nodes'
		-- positions only, as before
		local function search(own)
			for _, e in ipairs(R.allEdges()) do
				local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if be then
					local a0, a1 = nil, nil
					if own then
						local okE, e0, e1 = pcall(function()
							return { x = be.position0.x, y = be.position0.y, z = be.position0.z }, { x = be.position1.x, y = be.position1.y, z = be.position1.z }
						end)
						if okE then a0, a1 = e0, e1 end
					else
						a0, a1 = sNodePos(be.node0), sNodePos(be.node1)
					end
					if near(a0, c.position0) and near(a1, c.position1) then return e, false end
					if near(a0, c.position1) and near(a1, c.position0) then return e, true end
				end
			end
			return nil, false
		end
		local found, reversed = nil, false
		local byEnds = os.getenv("MPFEVER_AFTERENDS") ~= "0"
		if byEnds then found, reversed = search(true) end
		if not found then
			found, reversed = search(false)
			if found and byEnds then log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: segment " .. found .. " found by its nodes' positions, not by its own ends") end
		end
		if not found then
			G.stopsAfterBusy = nil
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: their new segment is not here")
			replayFailed(a, "stops' segment not found")
			return
		end
		-- (a construction's own segment is never rebuilt: the construction would keep the removed one, issue #49)
		local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(found) end)
		if okC and type(con) == "number" and con >= 0 then
			G.stopsAfterBusy = nil
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: segment " .. found .. " belongs to construction " .. con .. ": not rebuilt, resynchronisation")
			replayFailed(a, "stops on a construction's segment")
			return
		end
		local objs = {}
		for _, o in ipairs(g.objs) do
			local x = C.deser(C.ser(o))
			-- (this game's segment runs the other way round: the place along it and the side are the opposite ones)
			if reversed then x.param = 1 - (tonumber(x.param) or 0.5); x.left = not x.left end
			objs[#objs + 1] = x
		end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: " .. #objs .. " placed again on segment " .. found .. (reversed and " (reversed)" or ""))
		replayStop(a, { E = found, seg = g.seg, objs = objs, removeIdx = {}, nodeConfigs = G.keptNodeConfigs(a, found, g.seg), segType = g.seg.type or 0, after = true })
		if old then
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function() place(k + 1) end }
		else
			-- (replayStop sends its command at once: from the next frame on it is out, see replaySend)
			local since = G.frames
			G.waits[#G.waits + 1] = { at = G.frames + 2, fn = function() nextPlace(k + 1, since) end }
		end
	end
	if not old then G.stopsAfterBusy = G.frames end
	G.waits[#G.waits + 1] = { at = G.frames + 3, fn = function() place(1) end }
end

-- The junctions of a segment as they are now, for a stop build that rebuilds it (G.placeStopsAfter): the street build just
-- gave them the tool's lane connections and crosswalks, and the stop build removes the configurations of the segment's two
-- nodes. Put back as they were, the segment itself named by the new segment's placeholder (-1). Without them the engine made
-- its own there: one configuration more or less than on the builder's game, whose single build kept the tool's (a desync of
-- nodeConfigs, then a resynchronisation). MPFEVER_AFTERNC=0: as before (none put back).
G.keptNodeConfigs = function(a, E, seg)
	if os.getenv("MPFEVER_AFTERNC") == "0" then return {} end
	local out = {}
	local ok, err = pcall(function()
		local be = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		if not be then return end
		-- (the new segment takes the tool's lanes: with another number of lanes than this one, a lane connection could name a
		-- lane it does not have, which the engine asserts on: then none kept, as before)
		local capLanes = type(seg) == "table" and type(seg.comp) == "table" and seg.comp.laneConfigs or nil
		if type(capLanes) == "table" and #capLanes > 0 and #capLanes ~= #be.laneConfigs then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: the tool's segment has " .. #capLanes .. " lanes, this one " .. #be.laneConfigs .. ": its junctions not kept")
			return
		end
		for _, n in ipairs({ be.node0, be.node1 }) do
			local nc = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG)
			if nc then
				local lcs = {}
				for j = 1, #nc.laneConnections do
					local l = nc.laneConnections[j]
					lcs[j] = { segment0 = (l.segment0 == E) and -1 or l.segment0, lane0 = l.lane0, segment1 = (l.segment1 == E) and -1 or l.segment1,
						lane1 = l.lane1, withRoad = l.withRoad, withTram = l.withTram }
				end
				local cws = {}
				pcall(function() for j = 1, #nc.crosswalks do cws[j] = nc.crosswalks[j] end end)
				local m = { entity = n, comp = { laneConnections = lcs, crosswalks = cws } }
				pcall(function() m.comp.trafficLightPreference = nc.trafficLightPreference end)
				pcall(function() m.comp.doubleSlipSwitch = nc.doubleSlipSwitch end)
				pcall(function() m.comp.userModifiedLaneConnections = nc.userModifiedLaneConnections end)
				out[#out + 1] = m
			end
		end
	end)
	if not ok then log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: the junctions of segment " .. tostring(E) .. " not read: " .. tostring(err)); return {} end
	log("NATIVE REPLAY " .. tostring(a.uid) .. " stops: " .. #out .. " junction configuration(s) of segment " .. tostring(E) .. " kept")
	return out
end

local function replayNativeStreet(a)
	-- (a build that re-creates stops or signals on its new segments: the engine's own edge objects first, taken from a refused dry
	-- run, then this proposal with them, see G.replayStreetWithObjects; MPFEVER_EOINLINE=0: as before)
	if not a.eoTried and G.eoInlineOk(a.args and a.args[1]) then return G.replayStreetWithObjects(a) end
	-- (a plain new street of the tool, see replayNative: when the tool's proposal cannot be made or is refused here, the
	-- script forms are tried, as before 0.4.0)
	local fallback = a.plainStreet and G.replayForms or nil
	local function failed(why)
		if fallback then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native street: " .. why .. ", the script forms are tried")
			a.plainStreet, a.noNativeStreet = nil, true
			return fallback(a, 1)
		end
		replayFailed(a, why)
	end
	-- (with the engine's own edge objects, or sent here from the stop branch for them: what this proposal cannot do goes the way
	-- of before, which never needed it (the street, then its stops), never to a resynchronisation; see G.eoAsBefore)
	local function gaveUp(why)
		if a.eoNative or a.eoRoute == "stop" then return G.eoAsBefore(a, "native street: " .. why) end
		replayFailed(a, why)
	end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native street: unresolved " .. table.concat(miss, ",")) gaveUp("unresolved references") return end
	local m = cArgs[1]
	local rmIds = {}
	for _, sg in ipairs(m.proposal.removedSegments or {}) do if type(sg.entity) == "number" and sg.entity >= 0 then rmIds[#rmIds + 1] = sg.entity end end
	local okr, rm = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal(rmIds) end)
	if not okr or not rm then log("NATIVE REPLAY " .. tostring(a.uid) .. " native street: removal proposal " .. shortErr(rm)) gaveUp("removal proposal") return end
	local nSeg, nNodes = -1, -1
	pcall(function() nSeg = #rm.proposal.removedSegments end)
	pcall(function() nNodes = #rm.proposal.removedNodes end)
	local capNodes = #(m.proposal.removedNodes or {})
	if nSeg ~= #rmIds or nNodes < 0 then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " native street: the engine's removal (" .. nSeg .. " segments) differs from the tool's (" .. #rmIds .. ")")
		gaveUp("removal differs")
		return
	end
	local toolNodes = nNodes ~= capNodes
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = true
	-- the tool's own flags when they came with the build (the same proposal applied the same way)
	local bits = tonumber(a.ctx)
	if bits and bits >= 32 then
		ctx.gatherBuildings = bits % 2 == 1
		ctx.checkTerrainAlignment = math.floor(bits / 2) % 2 == 1
		ctx.cleanupStreetGraph = math.floor(bits / 4) % 2 == 1
	end
	-- never the street cleanup: the tool's proposal is already the cleaned-up result, and cleaned up once more here the
	-- engine merged one more node of the new road (one segment fewer on the replaying game, a cost a fourth off: a manual
	-- test on 40423, 2026-10-22; without it, the same cost and ground as the builder's). MPFEVER_STREETCLEANUP=1: the
	-- tool's flag as before
	if os.getenv("MPFEVER_STREETCLEANUP") ~= "1" then ctx.cleanupStreetGraph = false end
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	G.refundInto(ctx)
	local okk, cmd, label = false, nil, nil
	local eoUsed = a.eoNative
	for _, variant in ipairs({ {}, { noConfigs = true }, { noConfigs = true, noMaps = true } }) do
		C.errors = {}
		variant.toolNodes = toolNodes
		variant.townAuto = a.townAuto
		-- (the engine's own edge objects of the dry run, matched by rank, and the tool's map of the objects it re-created,
		-- MPFEVER_EOMAPS=0: without that map)
		if eoUsed then
			variant.withObjects = eoUsed
			variant.eoByRank = true
			variant.eoMaps = os.getenv("MPFEVER_EOMAPS") ~= "0"
		end
		local okp, P = pcall(C.rebuildNativeWithConstruction, m, nil, rm, variant)
		label = (variant.noMaps and "without node configurations and id maps") or (variant.noConfigs and "without node configurations") or "complete"
		if okp and P then
			okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true) end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native street (" .. label .. "): " .. ((okk and cmd) and "command made" or shortErr(cmd))
				.. (#C.errors > 0 and (" [" .. table.concat(C.errors, " ; "):sub(1, 200) .. "]") or ""))
		else
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native street (" .. label .. "): not rebuilt (" .. shortErr(P) .. ")")
		end
		if okk and cmd then break end
	end
	if (not okk or not cmd) and eoUsed then return G.eoAsBefore(a, "native street command with its edge objects " .. shortErr(cmd)) end
	if not okk or not cmd then failed("native street command") return end
	local edgesBefore = #R.allEdges()
	local objsBefore = eoUsed and G.eoCount() or nil
	toSim("replaying", { tok = a.tsTok })
	replaySend(cmd, function(res, success)
		if not success then
			local why = ""
			pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native street: refused " .. why .. ((a.plainStreet or eoUsed) and "" or " (desync)"))
			logRefusal(a, res)
			-- (refused, it changed nothing: the way of before)
			if eoUsed then return G.eoAsBefore(a, "native street with its edge objects refused " .. why) end
			failed("native street refused " .. why)
			return
		end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " native street BUILT (" .. label .. ")")
		if eoUsed then
			-- one build as the builder's, its stops and signals in it: none placed afterwards (a.stopsAfter is never set on this
			-- way). Their number here against the builder's, net of what the build removed
			local exp = #(m.proposal.edgeObjectsToAdd or {}) - #(m.proposal.edgeObjectsToRemove or {})
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native street: with its " .. #eoUsed .. " new stop(s)/signal(s), one build as the builder's")
			a.eoNative, a.eoRes = nil, nil
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local got = G.eoCount() - objsBefore
				log("NATIVE REPLAY " .. tostring(a.uid) .. " edge objects here " .. got .. ", originator " .. exp .. (got == exp and "" or " EDGE OBJECT COUNT DIFFERS"))
				if got ~= exp then replayFailed(a, "edge objects differ") end
			end }
			G.eoCheckHold()
		end
		-- (diagnostic) the tool's new nodes and segments the engine did not apply here, by place
		pcall(function()
			local st = res.proposal.proposal
			local got, miss = {}, {}
			local function key(p) return string.format("%.0f,%.0f", p.x, p.y) end
			for i = 1, #st.addedNodes do got[key(st.addedNodes[i].comp.position)] = true end
			for _, n in ipairs(m.proposal.addedNodes or {}) do
				local p = n.comp and n.comp.position
				if p and not got[key(p)] then miss[#miss + 1] = "node " .. tostring(n.entity) .. "@" .. key(p) end
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments
				.. " -segments " .. #st.removedSegments .. (#miss > 0 and ("; missing " .. table.concat(miss, " ")) or ""))
		end)
		-- the stops and signals the tool re-created on the new segments (issue #28)
		G.placeStopsAfter(a)
		local expected = #(m.proposal.addedSegments or {}) - #(m.proposal.removedSegments or {})
		G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
			local got = #R.allEdges() - edgesBefore
			log("NATIVE REPLAY " .. tostring(a.uid) .. " edges here " .. got .. ", originator " .. expected .. (got == expected and "" or " SEGMENT COUNT DIFFERS"))
		end }
	end)
end

-- ================================================================== edge objects in the tool's own proposal
-- (all of it table fields: the main chunk is at the game's limit of 200 local variables)

-- the stops and signals on the map (every edge object)
G.eoCount = function()
	local n = 0
	pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
	return n
end

-- After a replay whose stops and signals are counted on the whole map 10 frames later (native stop, a street with its edge
-- objects), nothing else is sent to the engine until that count is made: the next replay of a pause (or this game's own build
-- held at its step) answered within those frames added its objects to the count, a false difference and a resynchronisation on
-- a slow game. MPFEVER_EOCHECKHOLD=0: as before (3 frames).
G.eoHoldOwn = os.getenv("MPFEVER_EOCHECKHOLD") ~= "0"
G.eoCheckHold = function()
	if G.eoHoldOwn then G.replayQuiet = math.max(G.replayQuiet or 0, G.frames + 11) end
end

-- A fallback of a replay: at once, or on the next frame when it comes from an engine's answer, as the other retries (the game stays
-- held at the build's step meanwhile: G.replayQuiet, see replaySend)
G.nowOrNext = function(fn)
	if (G.replayOut or 0) == 0 and G.frames >= (G.replayQuiet or 0) then return fn() end
	G.waits[#G.waits + 1] = { at = G.frames + 1, fn = fn }
end

-- The engine's own native edge objects (stops, signals) for a build that adds them on its new segments: a script cannot write a
-- native edge object's model ("no writable member 'model'", issue #50), so they are taken from the engine's conversion of a script
-- proposal made to be refused, the shape of test 111 (H.stopexp): every new segment of the build that carries objects TWICE, both
-- copies between the SAME end nodes (an existing node as it is, a new node of the build once, at the tool's place), each copy
-- with the build's new objects. The copies collide with each other (and with the segments still there), so the engine refuses it
-- and builds nothing; its result still holds the converted proposal, whose edge objects come copy after copy in the order they
-- were given (test 111: segments -1, -1, -2, -2; model and place unreadable, so they are matched by rank). The placeholders of the
-- first copy are the tool's own (-400000000 - the object's rank). opts.removeE: the existing segment a stop is put on (no stop on
-- it yet), removed as in test 111. Returns the command and the number of the build's objects (the conversion has twice as many).
G.eoDryRun = function(m, opts)
	opts = opts or {}
	local st = (type(m) == "table" and m.proposal) or {}
	local list = st.edgeObjectsToAdd or {}
	local n = #list
	if n == 0 then error("no new edge objects") end
	local seg = {}
	for _, sg in ipairs(st.addedSegments or {}) do
		if type(sg) == "table" and type(sg.entity) == "number" and sg.entity < 0 then seg[sg.entity] = sg end
	end
	-- (the segments that carry them, in the order of their first object)
	local carriers, rank = {}, {}
	for k, o in ipairs(list) do
		if type(o) ~= "table" or type(o.model) ~= "string" then error("object " .. k .. " without model") end
		local sg = seg[o.segmentEntity]
		if not sg or type(sg.comp) ~= "table" then error("object " .. k .. ": its segment " .. tostring(o.segmentEntity) .. " is not a new segment of the build") end
		if not rank[o.segmentEntity] then carriers[#carriers + 1] = sg; rank[o.segmentEntity] = #carriers end
	end
	local newNode = {}
	for _, nd in ipairs(st.addedNodes or {}) do
		if type(nd) == "table" and type(nd.entity) == "number" then newNode[nd.entity] = nd end
	end
	local nodes, nodeOf, touched, touchedList = {}, {}, {}, {}
	local function endOf(id)
		if type(id) ~= "number" then error("segment end " .. tostring(id) .. " unresolved") end
		if id >= 0 then
			if not touched[id] then touched[id] = true; touchedList[#touchedList + 1] = id end
			return id
		end
		if nodeOf[id] then return nodeOf[id] end
		local p = newNode[id] and newNode[id].comp and newNode[id].comp.position
		if type(p) ~= "table" or type(p.x) ~= "number" then error("new node " .. id .. " without a position") end
		local ne = api.type.NodeAndEntity.new()
		ne.entity = -(#nodes + 1)
		local bn = ne.comp
		bn.position = api.type.Vec3f.new(p.x, p.y, p.z)
		ne.comp = bn
		nodes[#nodes + 1] = ne
		nodeOf[id] = ne.entity
		return ne.entity
	end
	local nC = #carriers
	local edges, eos = {}, {}
	for copy = 0, 1 do
		for ci, sg in ipairs(carriers) do
			local s = C.deser(C.ser(sg))
			s.entity = -(copy * nC + ci)
			s.comp.node0 = endOf(sg.comp.node0)
			s.comp.node1 = endOf(sg.comp.node1)
			s.comp.objects = nil
			local e = C.minimalSegment(s, false, false)
			-- (the tool's own lanes: on a street without pavements the stop tool adds the platform lanes, without which the stop is
			-- dropped, see replayStop)
			local lanes = nil
			if type(sg.comp.laneConfigs) == "table" and #sg.comp.laneConfigs > 0 then lanes = C.rebuildLanes(sg.comp.laneConfigs) end
			lanes = lanes or C.templateLanes(sg.comp.roadTemplate)
			-- (only the new objects, never the ones already on the segment: one object on two new segments)
			local objs = {}
			for k, o in ipairs(list) do
				if o.segmentEntity == sg.entity then objs[#objs + 1] = { -400000000 - (copy * n + k - 1), (o.category == 2) and 2 or (o.left and 0 or 1) } end
			end
			local c = e.comp
			if lanes then c.laneConfigs = lanes end
			c.objects = objs
			e.comp = c
			if type(sg.streetEdge) ~= "table" then
				pcall(function() local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se end)
			end
			if type(sg.playerOwned) ~= "table" or type(sg.playerOwned.player) ~= "number" then
				pcall(function() local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po end)
			end
			edges[#edges + 1] = e
		end
	end
	for copy = 0, 1 do
		for _, o in ipairs(list) do
			local eo = api.type.SimpleStreetProposal.EdgeObject.new()
			eo.edgeEntity = -(copy * nC + rank[o.segmentEntity])
			eo.param = tonumber(o.param) or 0.5
			eo.oneWay = o.oneWay == true
			eo.left = o.left == true
			eo.model = (o.model:gsub("^::/", ""))
			eo.playerEntity = api.engine.util.getPlayer()
			pcall(function() eo.name = o.name or "" end)
			C.setEdgeObjectParams(eo, o)
			eos[#eos + 1] = eo
		end
	end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	if #nodes > 0 then ssp.nodesToAdd = nodes end
	ssp.edgesToAdd = edges
	ssp.edgeObjectsToAdd = eos
	if type(opts.removeE) == "table" and #opts.removeE > 0 then
		ssp.edgesToRemove = opts.removeE
		for _, e in ipairs(opts.removeE) do
			local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if be then endOf(be.node0); endOf(be.node1) end
		end
	end
	-- (the configurations of the existing nodes it touches name the segments there: removed, as every script proposal that changes
	-- a node's segments does (C.rebuildProposal); only those this game has, removing one that does not exist is an assertion)
	local ncr = {}
	for _, nd in ipairs(touchedList) do
		local okn, nc = pcall(function() return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = nd end
	end
	if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
	sp.streetProposal = ssp
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = false
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = false
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	return api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), n
end

-- A street or track build that re-creates stops or signals on its NEW segments (a track upgrade of a signalled line, the Auto
-- Signals mod, a road joined to a street with stops, a town street rebuilt with its bus stops): replayed as ONE native street
-- proposal that carries them (replayNativeStreet with the engine's own objects of a refused dry run, see G.eoDryRun), as the
-- builder's game made it. The way of before was the street, then one stop build per new segment (1 + N builds where the builder
-- made one: every later entity was numbered differently, 3 ids off from a track upgrade on 2026-10-24). Only builds whose objects
-- are all on new segments the capture describes, and whose constructions are town buildings; what it cannot make still goes the
-- way of before (G.eoAsBefore). On by default since the game test of 2026-10-25 (149: the signals re-created inline gave the same
-- build ids on both games); off until then (a scripted street can hang the engine). MPFEVER_EOINLINE=0: as before
G.eoInlineOk = function(m)
	if os.getenv("MPFEVER_EOINLINE") == "0" then return false end
	local st = type(m) == "table" and m.proposal
	if type(st) ~= "table" or #(st.edgeObjectsToAdd or {}) == 0 then return false end
	if hasConstructionSegments(m) then return false end
	for _, ce in ipairs(m.toAdd or {}) do if type(ce) ~= "table" or ce.playerEntity ~= -1 then return false end end
	local seg = {}
	for _, sg in ipairs(st.addedSegments or {}) do
		if type(sg) == "table" and type(sg.entity) == "number" and sg.entity < 0 then seg[sg.entity] = sg end
	end
	for _, o in ipairs(st.edgeObjectsToAdd) do
		local sg = type(o) == "table" and type(o.model) == "string" and seg[o.segmentEntity] or nil
		local c = sg and sg.comp
		if type(c) ~= "table" or type(c.position0) ~= "table" or type(c.position1) ~= "table" or type(c.tangent0) ~= "table"
			or type(c.tangent1) ~= "table" then return false end
	end
	return true
end

-- What the native proposal with the engine's objects could not do: the way of before (a.eoTried: replayNative from the start,
-- whose stop branch then places the stops after the street), never a resynchronisation. That way numbers the entities otherwise
-- than the builder's game: MPFEVER_EOFALLBACKRESYNC=1 asks for a resynchronisation once it is applied
G.eoAsBefore = function(a, why)
	log("NATIVE REPLAY " .. tostring(a.uid) .. " edge objects: " .. tostring(why) .. ": replayed as before (the stops and signals after the street: the entity ids may now differ from the builder's)")
	-- (eoRoute cleared too: the way of before may come back to replayNativeStreet, whose own failures are then the old ones)
	a.eoNative, a.eoRes, a.eoRoute = nil, nil, nil
	a.eoTried = true
	if os.getenv("MPFEVER_EOFALLBACKRESYNC") == "1" then
		local since = G.frames
		G.waits[#G.waits + 1] = { at = G.frames + 2, fn = function() G.eoResyncWhenQuiet(a, since) end }
	end
	return G.nowOrNext(function() G.replayForms(a, 1) end)
end

G.eoResyncWhenQuiet = function(a, since)
	local quiet = (G.replayOut or 0) == 0 and G.frames >= (G.replayQuiet or 0) and G.stopsAfterBusy == nil
	if quiet or G.frames - since > 1200 then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " edge objects replayed as before: resynchronisation (MPFEVER_EOFALLBACKRESYNC)")
		return replayFailed(a, "edge objects replayed as before")
	end
	G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() G.eoResyncWhenQuiet(a, since) end }
end

G.replayStreetWithObjects = function(a)
	a.eoTried = true
	local uid = tostring(a.uid)
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then return G.eoAsBefore(a, "unresolved " .. table.concat(miss, ",")) end
	local okd, dry, n = pcall(G.eoDryRun, cArgs[1])
	if not okd or not dry then return G.eoAsBefore(a, "dry run not made (" .. shortErr(dry) .. ")") end
	log("NATIVE REPLAY " .. uid .. " edge objects: " .. n .. " new stop(s)/signal(s) of the build" .. C.mapSizes(cArgs[1]) .. ": their conversion by the engine (dry run)")
	toSim("replaying", { tok = a.tsTok })
	replaySend(dry, function(res, success)
		if success then
			log("NATIVE REPLAY " .. uid .. " edge objects: the dry run was built instead of refused (desync)")
			replayFailed(a, "edge object dry run built")
			return
		end
		local eo = {}
		pcall(function() local l = res.proposal.proposal.edgeObjectsToAdd; for i = 1, #l do eo[i] = l[i] end end)
		local segs = {}
		pcall(function() for i = 1, math.min(#eo, 8) do segs[i] = tostring(eo[i].segmentEntity) end end)
		log("NATIVE REPLAY " .. uid .. " edge objects: the engine's conversion has " .. #eo .. ", the tool's build " .. n .. " (dry run: twice; segments " .. table.concat(segs, ",") .. ")")
		if #eo ~= 2 * n then return G.eoAsBefore(a, "the engine's conversion has " .. #eo .. " edge object(s)") end
		local first = {}
		for i = 1, n do first[i] = eo[i] end
		-- (the converted objects live in that result: kept with the replay until its build is applied)
		a.eoNative, a.eoRes = first, res
		return replayNativeStreet(a)
	end)
end

-- A stop or a signal put on a bridge or in a tunnel (and the bulldozer on one), replayed as the tool's own native proposal instead
-- of replayStop's script proposal: the tool's segment replacement (its maps new2oldSegments / old2newSegments, the segment as the
-- tool made it), the engine's own removal of the old segment, and the new stops as the engine's own native edge objects of a dry
-- run it refuses (G.eoDryRun). The script proposal is converted as a removed bridge plus a new one, whose ground the engine aligns
-- again: 77.517/117.783 of terrain alignment here against the builder's 0/0 (2026-10-25), the towns drifted apart (script:towns)
-- and the games were reloaded 30 to 140 s later. The native replays of the bridges themselves gave the builder's alignment
-- exactly. What this way cannot make goes to replayStop as before (never to a resynchronisation); a native stop applied with
-- another number of stops than the builder's asks for one at once. On by default for the stops on bridges and in tunnels since the
-- game test of 2026-10-25 (132: the native stops on bridge segments built, and their town statistics were the builder's); the
-- signals there too since 0.5.3 (issue #85: signals on track bridges, the towns drifted after each), and on every track since
-- 0.5.7 (MPFEVER_NATIVESIGNAL=0: as before); MPFEVER_NATIVESTOP=all: every stop and signal (tests); MPFEVER_NATIVESTOP=0: as before (replayStop for every stop).
G.nativeStopWanted = function(a, plan)
	local sw = os.getenv("MPFEVER_NATIVESTOP")
	if sw == "0" then return false end
	if type(plan) ~= "table" or plan.after or type(plan.E) ~= "number" or type(a.args) ~= "table" then return false end
	if #(plan.objs or {}) == 0 and next(plan.removeIdx or {}) == nil then return false end
	if sw == "all" then return true end
	-- (a signal on any track since 0.5.7: the script's replay of a plain track's segment carries none of the tool's maps; a test
	-- replayed that way had other node configurations than the builder's, the tool's own proposal none, 2026-10-26)
	if plan.segType == 1 then return os.getenv("MPFEVER_NATIVESIGNAL") ~= "0" end
	local okc, c = pcall(function() return api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE) end)
	if not (okc and c) or ((type(c.type) == "number") and c.type or 0) == 0 then return false end
	return true
end

-- A stop on a bridge or in a tunnel: the stop tool's build leaves the towns alike (no terrain alignment: 0/0 on the builder's game),
-- while the engine gives its replay terrain alignment (7 to 23 on 2026-10-25, the user's test: "TOWN STATS DIFFER", a
-- resynchronisation after each stop; the dstop tests built their stop by script, with alignment on both games, and showed nothing).
-- When the builder's statistics are all zero, the replay is sent as not initiated by a player: the towns script takes nothing from
-- it, as from the builder's. MPFEVER_STOPPI=1: as before (a player's build)
G.stopNoTown = function(a)
	if os.getenv("MPFEVER_STOPPI") == "1" or type(a.ts) ~= "table" then return false end
	for _, k in ipairs({ "al", "ar", "tr", "rk", "ba", "br", "tv" }) do
		if tonumber(a.ts[k]) ~= 0 then return false end
	end
	return true
end

G.replayNativeStop = function(a, plan)
	local uid = tostring(a.uid)
	local function asBefore(why)
		log("NATIVE REPLAY " .. uid .. " native stop: " .. why .. ": replayed as before (replayStop)")
		return G.nowOrNext(function() replayStop(a, plan) end)
	end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then return asBefore("unresolved " .. table.concat(miss, ",")) end
	local m = cArgs[1]
	local c = api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE)
	if not c then return asBefore("segment " .. tostring(plan.E) .. " missing") end
	-- (this game's segment the other way round than the builder's: the tool's segment replaces it the builder's way round, as
	-- replayStop does; not with stops already on it, whose places count from this game's first node)
	local sc = (type(plan.seg) == "table" and type(plan.seg.comp) == "table") and plan.seg.comp or {}
	if #c.objects > 0 and sc.node0 == c.node1 and sc.node1 == c.node0 and c.node0 ~= c.node1 then
		return asBefore("segment " .. plan.E .. " runs the other way round here and carries stops")
	end
	local okr, rm = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal({ plan.E }) end)
	local nSeg, nNodes = -1, -1
	if okr and rm then
		pcall(function() nSeg = #rm.proposal.removedSegments end)
		pcall(function() nNodes = #rm.proposal.removedNodes end)
	end
	if nSeg ~= 1 or nNodes < 0 then return asBefore("the engine's removal of segment " .. plan.E .. " (" .. (okr and (nSeg .. " segment(s)") or shortErr(rm)) .. ")") end
	-- (the engine also removes the free end of a dead-end segment, the tool kept it: the tool's removed nodes are written instead,
	-- as replayNativeStreet does)
	local toolNodes = nNodes ~= #(m.proposal.removedNodes or {})
	local nObj = #(plan.objs or {})
	local nGone = 0
	for _ in pairs(plan.removeIdx or {}) do nGone = nGone + 1 end
	local kind = "type " .. tostring(c.type) .. "/" .. tostring(c.typeIndex)
	local function build(eo, keep)
		local ctx = sContext(a)
		local pi = not G.stopNoTown(a)
		if not pi then log("NATIVE REPLAY " .. uid .. " native stop: the builder's build left the towns alike: replayed as a script's build (the towns ignore it)") end
		-- (priced like the tool's build, as replayStop: the replaced segment free)
		local free = G.toolCosts(a, plan) and (sc.roadTemplate == nil or sc.roadTemplate == c.roadTemplate)
		local ign = G.toolIgnoresErrors(a)
		local okk, cmd, label = false, nil, nil
		for _, variant in ipairs({ {}, { noConfigs = true }, { noConfigs = true, noMaps = true } }) do
			C.errors = {}
			variant.toolNodes = toolNodes
			if eo then variant.withObjects = eo; variant.eoByRank = true; variant.eoMaps = os.getenv("MPFEVER_EOMAPS") ~= "0" end
			label = (variant.noMaps and "without node configurations and id maps") or (variant.noConfigs and "without node configurations") or "complete"
			local okp, P = pcall(C.rebuildNativeWithConstruction, m, nil, rm, variant)
			if okp and P then
				if free then okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, ign, pi, true) end) end
				if not (okk and cmd) then
					free = false
					okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, ign, pi) end)
				end
				log("NATIVE REPLAY " .. uid .. " native stop (" .. label .. "): " .. ((okk and cmd) and "command made" or shortErr(cmd))
					.. (#C.errors > 0 and (" [" .. table.concat(C.errors, " ; "):sub(1, 200) .. "]") or ""))
			else
				log("NATIVE REPLAY " .. uid .. " native stop (" .. label .. "): not rebuilt (" .. shortErr(P) .. ")")
			end
			if okk and cmd then break end
		end
		if not okk or not cmd then return asBefore("no command") end
		local before = G.eoCount()
		toSim("replaying", { tok = a.tsTok })
		replaySend(cmd, function(res, success)
			if not success then
				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				log("NATIVE REPLAY " .. uid .. " native stop on segment " .. plan.E .. ": refused " .. why)
				logRefusal(a, res)
				-- (refused, it changed nothing)
				return asBefore("refused")
			end
			log("NATIVE REPLAY " .. uid .. " native stop BUILT on segment " .. plan.E .. " (" .. kind .. ", " .. label .. ")" .. (free and ", priced like the tool's build" or ""))
			local expected = before + nObj - nGone
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local after = G.eoCount()
				if keep then keep.res = nil end
				log("NATIVE REPLAY " .. uid .. " stops on the map " .. before .. " -> " .. after .. ((after == expected) and "" or (" (EXPECTED " .. expected .. "): resynchronisation")))
				if after ~= expected then replayFailed(a, "native stop: stops differ") end
			end }
			G.eoCheckHold()
		end)
	end
	-- the bulldozer on a stop: nothing new, the tool's removal of the objects is written by their rank on the segment
	if nObj == 0 then
		log("NATIVE REPLAY " .. uid .. " native stop: " .. nGone .. " object(s) removed from segment " .. plan.E .. " (" .. kind .. ")")
		return build(nil, nil)
	end
	-- the engine's own edge objects first (a dry run it refuses, nothing built); the old segment removed in it only when it carries
	-- nothing yet (the shape of test 111)
	local okd, dry, n = pcall(G.eoDryRun, m, { removeE = (#c.objects == 0) and { plan.E } or nil })
	if not okd or not dry then return asBefore("dry run not made (" .. shortErr(dry) .. ")") end
	log("NATIVE REPLAY " .. uid .. " native stop: " .. n .. " new object(s) on segment " .. plan.E .. " (" .. kind .. "): their conversion by the engine (dry run)")
	toSim("replaying", { tok = a.tsTok })
	replaySend(dry, function(res, success)
		if success then
			log("NATIVE REPLAY " .. uid .. " native stop: the dry run was built instead of refused (desync)")
			replayFailed(a, "stop conversion built")
			return
		end
		local eo = {}
		pcall(function() local l = res.proposal.proposal.edgeObjectsToAdd; for i = 1, #l do eo[i] = l[i] end end)
		log("NATIVE REPLAY " .. uid .. " native stop: the engine's conversion has " .. #eo .. " edge object(s), the tool's build " .. n .. " (dry run: twice)")
		if #eo ~= 2 * n then return asBefore("the engine's conversion has " .. #eo .. " edge object(s)") end
		local first = {}
		for i = 1, n do first[i] = eo[i] end
		-- (the converted objects live in that result: kept until the build is applied)
		return build(first, { res = res })
	end)
end

-- (diagnostic, MPFEVER_STOPALIGNPROBE=1 for the stops on a bridge or in a tunnel, =all for every stop; H.bridgestopprobe) Which
-- form of a stop's replay shapes the ground: the engine's proposal data of each form, made without building anything, and the
-- terrain alignment the towns would count for it (api.engine.util.town.getTerrainAlignmentImpact, as the game's towns script does
-- with every player's build). The stop tool's own build aligned nothing; replayStop's script proposal aligned 77.517/117.783 on a
-- street bridge (2026-10-25). The forms: (a) replayStop's script proposal with its context, (b) the same with the terrain alignment
-- asked for, (c) the tool's native proposal rebuilt with its replacement maps (C.rebuildNativeWithConstruction, without the new
-- stops: the pure replacement of the segment), (d) the same without the maps, (e) (c) with the terrain alignment asked for.
G.stopAlignProbe = function(a, plan, sp, mkCtx)
	local uid = tostring(a.uid)
	local function say(t)
		log("STOPALIGNPROBE " .. uid .. " " .. t)
		if plan.probeSink then pcall(plan.probeSink, uid .. " " .. t) end
	end
	local membersShown = false
	local function stats(label, form, ctx)
		local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(form, ctx) end)
		if not okd or not pd then say(label .. ": no proposal data (" .. shortErr(pd) .. ")") return end
		local al, ar, an = 0, 0, 0
		local okI, t = pcall(function() return api.engine.util.town.getTerrainAlignmentImpact(pd) end)
		if okI and type(t) == "table" then
			for _, v in pairs(t) do al = al + (tonumber(v[1]) or 0); ar = ar + (tonumber(v[2]) or 0); an = an + 1 end
		end
		local pa, pr, costs, crit = "?", "?", "?", "?"
		pcall(function() pa = tostring(#pd.parallelProposal.toAdd) end)
		pcall(function() pr = tostring(#pd.parallelProposal.toRemove) end)
		pcall(function() costs = tostring(pd.costs) end)
		pcall(function() crit = tostring(pd.errorState.critical) end)
		say(label .. ": terrain alignment " .. (okI and string.format("%.3f/%.3f/%d", al, ar, an) or ("unreadable (" .. shortErr(t) .. ")"))
			.. ", parallel strips +" .. pa .. " -" .. pr .. ", costs " .. costs .. ", critical " .. crit)
		if not membersShown then
			membersShown = true
			pcall(function() say("proposal data members: " .. table.concat(C.members(pd) or {}, ",")) end)
		end
	end
	local c = api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE)
	say("segment " .. tostring(plan.E) .. " type " .. tostring(c and c.type) .. "/" .. tostring(c and c.typeIndex) .. ", " .. #(plan.objs or {}) .. " new object(s)"
		.. ((type(a.ts) == "table") and string.format(", the builder's terrain alignment %.3f/%.3f", tonumber(a.ts.al) or -1, tonumber(a.ts.ar) or -1) or ""))
	stats("(a) script proposal, the replay's context", sp, mkCtx())
	local cb = mkCtx()
	cb.checkTerrainAlignment = true
	stats("(b) script proposal, terrain alignment asked for", sp, cb)
	-- the tool's native proposal: the act's, its references translated; for H.bridgestopprobe (no act) and for the stops placed
	-- again after a street build (the act is the street's), made from the script proposal as the stop tool makes it (the new
	-- segment -1 replacing the old one, the maps saying so)
	local m
	if type(a.args) == "table" and not plan.after then
		local cArgs = C.deser(C.ser(a.args))
		local miss = R.translateIn(cArgs, G.bind)
		if #miss > 0 then say("(c)-(e): unresolved " .. table.concat(miss, ",")) return end
		m = cArgs[1]
	else
		local ssp = sp.streetProposal
		local live = api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE)
		m = { toAdd = {}, toRemove = {}, proposal = {
			addedNodes = {}, removedNodes = {}, addedSegments = { C.marshal(ssp.edgesToAdd[1]) },
			removedSegments = { { entity = plan.E, type = plan.segType or 0, comp = C.marshal(live) } },
			edgeObjectsToAdd = {}, edgeObjectsToRemove = {}, nodeConfigsToAdd = {}, nodeConfigsToRemove = C.marshal(ssp.nodeConfigsToRemove) or {},
			new2oldSegments = { [-1] = { plan.E } }, old2newSegments = { [plan.E] = { -1 } } } }
	end
	local okr, rm = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal({ plan.E }) end)
	if not okr or not rm then say("(c)-(e): removal proposal " .. shortErr(rm)) return end
	local nNodes = -1
	pcall(function() nNodes = #rm.proposal.removedNodes end)
	local toolNodes = nNodes ~= #(m.proposal.removedNodes or {})
	for _, f in ipairs({ { "(c) native proposal with the tool's maps", {}, false }, { "(d) native proposal without maps", { noMaps = true }, false },
		{ "(e) native proposal with the tool's maps, terrain alignment asked for", {}, true } }) do
		C.errors = {}
		local opts = f[2]
		opts.toolNodes = toolNodes
		local okp, P = pcall(C.rebuildNativeWithConstruction, m, nil, rm, opts)
		if okp and P then
			local ctx = mkCtx()
			if f[3] then ctx.checkTerrainAlignment = true end
			stats(f[1] .. (#C.errors > 0 and (" [" .. table.concat(C.errors, " ; "):sub(1, 160) .. "]") or ""), P, ctx)
		else
			say(f[1] .. ": not rebuilt (" .. shortErr(P) .. ")")
		end
	end
end

-- (see SIM.townStats) The builder's town statistics of a build this game is about to replay, to the simulation, which adds up its
-- own replay's and compares them once the replay is applied. Each announcement carries a mark of its own: only the differences
-- of replays announced since this game started ask for a resynchronisation (the simulation's list is kept in the savegame, a
-- reloaded game must not ask for one again). The mark goes with the replay (a.tsTok): each of its "replaying" events carries it,
-- and only the proposals they count are added up (see SIM.townTag).
-- The marks are forgotten one at a time, the oldest first, once 64 are kept: the record of the replay announced before stays open
-- until this announcement closes it (in a pause, or at the same step), and a difference found then is still acted on. Before, the
-- 65th announcement emptied the whole list first, and that replay's difference asked for nothing (the towns then drifted until
-- the next checks). MPFEVER_TSWAITWIPE=1: as before (the list emptied every 64 announcements)
G.townExpect = function(a)
	G.tsSeq = (G.tsSeq or 0) + 1
	local tok = string.format("%.4f-%d", os.clock(), G.tsSeq)
	if os.getenv("MPFEVER_TSWAITWIPE") == "1" then
		G.tsWaitN = (G.tsWaitN or 0) + 1
		if not G.tsWait or G.tsWaitN > 64 then G.tsWait, G.tsWaitN = {}, 1 end
		G.tsWait[tok] = tostring(a.uid)
	else
		G.tsWait = G.tsWait or {}
		G.tsOrder = G.tsOrder or {}
		G.tsWait[tok] = tostring(a.uid)
		G.tsOrder[#G.tsOrder + 1] = tok
		while #G.tsOrder > 64 do G.tsWait[table.remove(G.tsOrder, 1)] = nil end
	end
	a.tsTok = tok
	toSim("replay_stats", { uid = tostring(a.uid), ts = a.ts, tok = tok })
end

G.townDiffs = function(st)
	for _, d in ipairs(st.townDiffs or {}) do
		local uid = G.tsWait and d.tok and G.tsWait[d.tok]
		if uid then
			G.tsWait[d.tok] = nil
			log("NATIVE REPLAY " .. uid .. ": TOWN STATS DIFFER from the builder's (" .. tostring(d.why) .. "): resynchronisation asked for")
			replayFailed({ uid = uid }, tostring(d.why))
		end
	end
end

function replayTwoStep(a)
	local m0 = a.args[1]
	if type(m0) ~= "table" or #(m0.toAdd or {}) == 0 or type(m0.proposal) ~= "table" then return false end
	if editsConstruction(m0) then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: not for the edit of an existing station (the engine asserts)") return false end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: unresolved " .. table.concat(miss, ",")) return false end
	-- (the street part alone would take away the own tracks of the construction it replaces: never built apart, see
	-- G.ownTracksRemoved; tried only with the construction in the same proposal)
	local ownTracks = a.ownTracks or G.ownTracksRemoved(cArgs[1])

	local function buildConstruction()
		local okr, args, n = pcall(C.rebuildArgs, a.fn, C.deser(C.ser(cArgs)), { seed = 7919, variant = "minimal", raw = true, ctx = "terrainNoCleanup", noStreet = true })
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction not rebuilt (" .. shortErr(args) .. ")") replayFailed(a, "construction not rebuilt") return end
		args[3] = true args[4] = false   -- (non-critical collision with its own street connection: ignored)
		local okk, cmd2 = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
		if not okk or not cmd2 then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction command " .. shortErr(cmd2)) replayFailed(a, "construction command") return end
		toSim("replaying", { tok = a.tsTok })
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
			if together and ownTracks then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: not the street part alone, it would take away the tracks of the construction it replaces (desync)")
				replayFailed(a, "station edit not replayed")
				return
			end
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
		local okr, args, n = pcall(C.rebuildArgs, a.fn, sArgs, { seed = 7919, variant = form.v, ctx = form.ctx, raw = form.raw, refund = G.refund })
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " rebuild " .. shortErr(args)) return streetStep(k + 1, together) end
		-- with the construction: the collisions the engine reports are the construction against its own street connection
		-- (non-critical errors): the build goes on, as the game's own scripts do (ignoreErrors = true)
		if together then args[3] = true args[4] = false end
		local okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
		if not okc or not cmd then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " command " .. shortErr(cmd)) return streetStep(k + 1, together) end
		toSim("replaying", { tok = a.tsTok })
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
	G.replayForms = G.replayForms or replayNative
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
		-- the edit of a construction sent by a window (a warehouse's goods with the Drive-in Warehouses mod, see G.uiEdit): the
		-- engine's own replacement with the new settings, made the same way on every game
		local e1 = probe[1]
		if a.uiEdit and #missing == 0 and e1 and type((e1.toRemove or {})[1]) == "number" and type(((e1.toAdd or {})[1] or {}).params) == "table" then
			local ctxArg = probe[2]
			if type(ctxArg) == "table" then
				a.ctx = 32 + (ctxArg.gatherBuildings and 1 or 0) + (ctxArg.checkTerrainAlignment and 2 or 0) + (ctxArg.cleanupStreetGraph and 4 or 0)
			end
			return engineReplay(a, "edit of the construction " .. e1.toRemove[1] .. " (" .. tostring(e1.toAdd[1].fileName):match("[^/]*$") .. ")", function()
				return api.engine.util.proposal.createProposalReplaceConstruction(e1.toRemove[1], C.plain(e1.toAdd[1].params))
			end)
		end
		-- town buildings the build moved (a street upgrade in a town: nobody's constructions added, town buildings removed). Rebuilt
		-- as plain constructions they were no town buildings any more (two fewer in the town, which then drifted): the street is
		-- sent without them, and this game's engine takes the same buildings away and puts the same ones back, as the
		-- builder's did (the game's random numbers are the same on every game)
		if #missing == 0 and probe[1] and (#(probe[1].toAdd or {}) > 0 or #(probe[1].toRemove or {}) > 0) then
			local town = true
			for _, ce in ipairs(probe[1].toAdd or {}) do if ce.playerEntity ~= -1 then town = false end end
			for _, e in ipairs(probe[1].toRemove or {}) do
				local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
				if not (okc and c and #c.townBuildings > 0) then town = false end
			end
			-- (only with a street: town buildings bulldozed by a player are no street build, the engine takes nothing away by
			-- itself then; taken for one, the replay sent an empty build and the houses stayed on the other games, a session of
			-- the friends. MPFEVER_HOUSEBULLDOZE=0: as before)
			local pst = probe[1].proposal or {}
			local street = #(pst.addedSegments or {}) + #(pst.removedSegments or {}) + #(pst.addedNodes or {}) + #(pst.removedNodes or {}) > 0
			if not street and os.getenv("MPFEVER_HOUSEBULLDOZE") ~= "0" then
				town = false
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": " .. #(probe[1].toRemove or {}) .. " town building(s) bulldozed, no street")
			end
			if town and not hasConstructionSegments(a.args[1]) then
				a.townAuto = true
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": " .. #(probe[1].toAdd or {}) .. " town building(s) put back and " .. #(probe[1].toRemove or {})
					.. " taken away by the engine itself")
			end
		end
		G.upgradeWhy = nil
		local plan = (#missing == 0) and upgradePlan(probe, a.townAuto) or nil
		-- an upgrade of several segments of a town street is ONE build of the tool: replayed one segment after the other, the
		-- terrain was aligned and the town buildings taken away segment by segment, other ones than the builder's (a manual
		-- test: 926311 for the builder, 489787 + 441524 here; 17 buildings taken away there, 10 + 7 here). The tool's own
		-- proposal is replayed instead, every segment at once (17 buildings, 929986: closer, not yet exact, the town buildings
		-- the tool put back are placed by this game's engine). MPFEVER_UPGRADEMERGE=0: as before
		if plan and (#plan > 1 or os.getenv("MPFEVER_MERGEONE") == "1") and os.getenv("MPFEVER_UPGRADEMERGE") ~= "0" and os.getenv("MPFEVER_UPGRADEMERGE") ~= "native" then
			if G.replayMergedUpgrade(a, plan, probe) then return end
		end
		if plan and #plan > 1 and a.townAuto and os.getenv("MPFEVER_UPGRADEMERGE") ~= "0" and os.getenv("MPFEVER_TOWNNATIVE") ~= "0" then
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": an upgrade of " .. #plan .. " town street segments at once: native street proposal")
			return replayNativeStreet(a)
		end
		if plan then return replayUpgrade(a, plan, 1) end
		if a.townAuto then log("NATIVE REPLAY " .. tostring(a.uid) .. ": no street upgrade (" .. tostring(G.upgradeWhy or (#missing > 0 and "unresolved" or "?")) .. ")") end
		-- a street through a town that moves town buildings: never by the script forms, whose lanes the engine asserted on while
		-- making the command (the host's game crashed, issue #75), nor given up when the street carries stops (every form refused):
		-- the tool's own native proposal, without the town buildings, which this game's engine moves itself.
		-- MPFEVER_TOWNNATIVE=0: as before
		if a.townAuto and #missing == 0 and os.getenv("MPFEVER_TOWNNATIVE") ~= "0" then
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": a street through a town" .. C.mapSizes(a.args[1]) .. ": native street proposal")
			return replayNativeStreet(a)
		end
		-- stops: the stop tool replaces one existing segment between the same nodes and adds edge objects
		local stp = probe[1] and probe[1].proposal
		-- (the signs of an airport are edge objects on its own taxiways: the airport goes the construction's way below)
		if stp and (#(stp.edgeObjectsToAdd or {}) > 0 or #(stp.edgeObjectsToRemove or {}) > 0) and not hasConstructionSegments(a.args[1]) then
			if #missing > 0 then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " (stop) SKIPPED, unresolved: " .. table.concat(missing, ","))
				replayFailed(a, "unresolved references")
				return
			end
			local okp, plan = pcall(function() return stopPlan(probe) end)
			-- (a stop on a bridge or in a tunnel: the tool's own native proposal, see G.replayNativeStop; MPFEVER_NATIVESTOP=0: as
			-- before)
			if okp and plan and G.nativeStopWanted(a, plan) then return G.replayNativeStop(a, plan) end
			if okp and plan then return replayStop(a, plan) end
			-- a street with stops on it taken away with the bulldozer: the engine's own removal proposal removes the stops with it
			local removal0 = (#(stp.edgeObjectsToAdd or {}) == 0) and removalPlan(probe) or nil
			if removal0 then
				return engineReplay(a, "removal (stops included) of " .. table.concat(removal0, ","), function()
					return api.engine.util.proposal.makeSegmentsRemoveProposal(removal0)
				end, R.removedConstructions(probe))
			end
			-- a road joined to a street with stops: the tool removes the stops and places them again on the new pieces of street
			-- (edgeObjectsToRemove / edgeObjectsToAdd). Rebuilt by the script forms below, which do both; before, it was
			-- given up here and the road existed on its builder's game only (C:12 in the 0.3.6 tests).
			-- (a script proposal cannot place them in the same build: refused "Construction impossible", and without their
			-- placeholders the engine asserts): the street build is rebuilt without them, then each new segment that carries
			-- stops gets them back as a stop build (replayStop), which is what the tool's build amounts to.
			-- That is 1 + N builds where the builder made one: every later entity was numbered differently here (a track upgrade
			-- of a signalled line, 2026-10-24: 3 ids off from then on). Now ONE native street proposal that carries the engine's
			-- own stops and signals (G.replayStreetWithObjects, see G.eoInlineOk); if it cannot be made, the way below (a.eoTried).
			-- MPFEVER_EOINLINE=0: as before
			if not a.eoTried and G.eoInlineOk(probe[1]) then
				a.eoRoute = "stop"
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": " .. #(stp.edgeObjectsToAdd or {}) .. " stop(s)/signal(s) re-created on the new segments: one native street proposal with them")
				return replayNativeStreet(a)
			end
			local groups = {}
			for _, o in ipairs(stp.edgeObjectsToAdd or {}) do
				for j, src in ipairs(stp.addedSegments or {}) do
					if type(src) == "table" and src.entity == o.segmentEntity then
						groups[j] = groups[j] or { seg = src, objs = {} }
						groups[j].objs[#groups[j].objs + 1] = o
					end
				end
			end
			a.stopsAfter = {}
			for _, g in pairs(groups) do a.stopsAfter[#a.stopsAfter + 1] = g end
			a.noStops = true
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": stops placed again on a street build (" .. tostring(plan) .. "): the street first, then "
				.. #(stp.edgeObjectsToAdd or {}) .. " stop(s) on " .. #a.stopsAfter .. " new segment(s)")
		end
		-- an industry edited alone (a fishing net or a farm's field taken away with the bulldozer): the engine's replacement of
		-- the existing industry with the tool's parameters. Rebuilt by the script forms as a new industry, its slots filled
		-- themselves again (the nets came back on the replaying game, and the games differed: conParams, a manual test on
		-- 2026-10-22). MPFEVER_REPLACECON=0: as before
		local m1 = probe[1]
		if #missing == 0 and stp and m1 and #(m1.toAdd or {}) == 1 and #(m1.toRemove or {}) == 1 and #(stp.addedSegments or {}) == 0
			and #(stp.removedSegments or {}) == 0 and #(stp.addedNodes or {}) == 0 and type(m1.toAdd[1].params) == "table"
			and tostring(m1.toAdd[1].fileName):find("/industries/", 1, true) and type(m1.toRemove[1]) == "number"
			and os.getenv("MPFEVER_REPLACECON") ~= "0" then
			return engineReplay(a, "edit of the industry " .. m1.toRemove[1] .. " (" .. tostring(m1.toAdd[1].fileName):match("[^/]*$") .. ")", function()
				return api.engine.util.proposal.createProposalReplaceConstruction(m1.toRemove[1], C.plain(m1.toAdd[1].params))
			end)
		end
		-- a street build that reshapes an industry (a road through a farm's field or a forest): the industry is replaced as the
		-- engine replaces it, in the tool's proposal (see C.rebuildNativeWithConstruction). By the script forms, it was built as a
		-- new industry whose slots filled themselves again
		if #missing == 0 and m1 and #(m1.toAdd or {}) > 0 and type(m1.old2newByRank) == "table" and os.getenv("MPFEVER_REPLACECON") ~= "0" then
			for _, v in pairs(m1.old2newByRank) do
				local ce = type(v) == "number" and m1.toAdd[v + 1]
				if type(ce) == "table" and tostring(ce.fileName):find("/industries/", 1, true) then a.industryEdit = true end
			end
			if a.industryEdit and not hasConstructionSegments(a.args[1]) then
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": the build reshapes an industry: the tool's proposal with the industry replaced")
				if replayNativeConstruction(a) then return end
			end
		end
		-- a construction with its street connection: not replayable as one rebuilt proposal (see replayTwoStep)
		-- (and the edit of a station that takes some of its own tracks away and adds none: the script forms always fail there, a
		-- segment removed twice; the tool's proposal as for any other edit of it, see G.ownTracksRemoved. MPFEVER_OWNTRACKS=0: the
		-- script forms first, as before, but never the street part alone)
		if #missing == 0 and not hasConstructionSegments(a.args[1]) and os.getenv("MPFEVER_OWNTRACKS") ~= "0" and G.ownTracksRemoved(m1) then
			a.ownTracks = true
			a.ownTracksAll = select(2, G.ownTracksRemoved(m1)) == true
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": the edit takes away " .. (a.ownTracksAll and "all the" or "some")
				.. " tracks of the construction it replaces: the tool's proposal")
		end
		if hasConstructionSegments(a.args[1]) or a.ownTracks then
			if replayNativeConstruction(a) then return end
			-- (0.6: a computer company's garage that keeps the town buildings, a.keepBuildings: no other form, they all gather the
			-- buildings in their way; the host's game is reloaded instead)
			if a.keepBuildings == true then
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": a computer company's build not replayed as the tool's proposal: no other form (they take buildings down)")
				replayFailed(a, "computer company's build not replayed")
				return
			end
			if replayTwoStep(a) then return end
			if editsConstruction(a.args[1]) or a.ownTracks then
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": the edit of an existing station could not be replayed as the tool's proposal: not rebuilt otherwise")
				replayFailed(a, "station edit not replayed")
				return
			end
		end
		local removal = (#missing == 0) and removalPlan(probe) or nil
		if removal then
			return engineReplay(a, "removal of " .. table.concat(removal, ","), function()
				return api.engine.util.proposal.makeSegmentsRemoveProposal(removal)
			end, R.removedConstructions(probe))
		end
		if C.movesObjects(stp) and #(a.args[1].toAdd or {}) == 0 and #(a.args[1].toRemove or {}) == 0 then
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": the build cuts a segment with stops or signals: native street proposal")
			return replayNativeStreet(a)
		end
		-- the tool said which new segments and nodes replace which old ones (a track joined to another, a curve reshaped, a
		-- junction node moved): only a native proposal carries that. Rebuilt without it, the replaced parts were paid again and
		-- built as new ones on the other games, which then numbered their next entities differently and drifted apart
		-- (a street through a town moves town buildings: the native proposal without them, this game's engine takes the same
		-- ones away. Rebuilt by the script forms instead, the street was laid otherwise: 44 town buildings taken away instead of
		-- 35 and the towns drifted, a manual test on Leawood)
		if stp and C.hasReplaceMaps(stp) and (#(a.args[1].toAdd or {}) == 0 or a.townAuto)
			and #(stp.edgeObjectsToAdd or {}) == 0 and os.getenv("MPFEVER_MAPREPLAY") ~= "0" then
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": the tool's replacement maps" .. C.mapSizes(a.args[1]) .. ": native street proposal")
			return replayNativeStreet(a)
		end
		-- a new street of the street tool (nothing replaced, no station, no stop): the tool's own proposal too. Rebuilt by the
		-- script forms, a street laid with the slope tool cost a quarter less on the other game and its segments differed
		-- (a manual test with mods, 2026-10-22: edges differed after three roads). MPFEVER_NATIVEROAD=0: as before
		if stp and a.natId ~= nil and not a.noNativeStreet and #(a.args[1].toAdd or {}) == 0 and #(a.args[1].toRemove or {}) == 0
			and #(stp.edgeObjectsToAdd or {}) == 0 and #(stp.edgeObjectsToRemove or {}) == 0 and #(stp.addedSegments or {}) > 0
			and not C.movesObjects(stp) and os.getenv("MPFEVER_NATIVEROAD") ~= "0" then
			a.plainStreet = true
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": a new street of the tool: native street proposal")
			return replayNativeStreet(a)
		end
		if C.movesObjects(stp) then
			a.objectForms = true
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": the build cuts a segment with stops or signals: native forms only")
		end
	end
	local form = (a.objectForms and OBJECT_FORMS or REPLAY_FORMS)[formIndex]
	if not form then
		if not a.objectForms and replayTwoStep(a) then return end
		-- (diagnostic, MPFEVER_EXP set: which part of the proposal the factory refuses; only commands are made, nothing is sent)
		if os.getenv("MPFEVER_EXP") then
			local exps = { "noph", "noeor", "oneside", "oneside,noph", "noeo," }
			local function try(k)
				local ex = exps[k]
				if not ex then return end
				local mx = C.deser(C.ser(a.args))
				R.translateIn(mx, G.bind)
				local okr, args, n = pcall(C.rebuildArgs, a.fn, mx, { seed = 7919, variant = "minimal", ctx = (ex == "plain") and "plain" or "terrainNoCleanup", raw = true, exp = ex })
				local okc, cmd = false, args
				if okr then okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end) end
				if #(C.errors or {}) > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " experiment '" .. ex .. "' notes: " .. table.concat(C.errors, " ; "):sub(1, 300)) end
				if not (okr and okc and cmd) then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " experiment '" .. ex .. "': factory " .. shortErr(cmd))
					return try(k + 1)
				end
				replaySend(cmd, function(res, success)
					log("NATIVE REPLAY " .. tostring(a.uid) .. " experiment '" .. ex .. "': " .. (success and "BUILT" or "refused"))
					if success then return end
					logRefusal(a, res)
					G.waits[#G.waits + 1] = { at = G.frames + 2, fn = function() try(k + 1) end }
				end)
			end
			try(1)
		end
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
	if a.townAuto and type(margs[1]) == "table" then
		margs[1].toAdd = {}
		margs[1].toRemove = {}
		margs[1].old2new = nil
		margs[1].old2newByRank = nil
	end
	local okr, args, n = pcall(C.rebuildArgs, a.fn, margs, { seed = 7919, variant = form.v, ctx = form.ctx, raw = form.raw, rm = form.rm, exp = a.noStops and "noeo," or nil, refund = G.refund })
	local label = form.v .. (form.raw and "/raw" or "") .. "/" .. form.ctx .. (form.ie and "/ie" or "") .. (form.pi == false and "/pi0" or "")
		.. (form.rm and ("/rm-" .. form.rm) or "")
	if not okr then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": rebuild " .. shortErr(args))
		return replayNative(a, formIndex + 1)
	end
	local okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
	if not okc or not cmd then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": factory " .. shortErr(cmd)
			.. (#(C.errors or {}) > 0 and (" [" .. table.concat(C.errors, " ; "):sub(1, 200) .. "]") or ""))
		return replayNative(a, formIndex + 1)
	end
	do
		local okg, sig = pcall(C.buildSig, type(a.args) == "table" and a.args[1] or nil)
		toSim("replaying", { sig = okg and sig or nil, tok = a.tsTok })
	end
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
			-- the stops the tool placed again on the new segments (see the stop branch above)
			G.placeStopsAfter(a)
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
K.JOIN_GATHER = 120
-- The engine has really stopped: its speed is 0 AND its clock has not moved for a while (the speed component reads 0 while the
-- simulation thread still finishes the steps it had started)
-- (in real time: the interface sees the simulation's clock only at the 200 ms handshake, so a clock still for a few frames
-- may still be running; asking for exact steps then adds them to the steps it is still making)
-- Every stop round of a hold waits for this, 0.45 s at least. MPFEVER_FASTSTILL=1 proves it from the counters of the game time
-- component instead (G.stillWatch), one handshake after the last step.
-- (either proof is enough: the new one can only make this sooner, never leave a hold waiting for a proof it cannot make)
-- (not the new one once a speed above 0 was asked for since its proof: a step may be under way that no copy shows yet; the old
-- rule decides until the next proof)
G.simStill = function()
	if G.nstopStanding() then return true end
	local S = G.stillS
	if G.fastStill and S and S.usable and S.proven and not S.askedSince and gameSpeed() == 0 then return true end
	return G.stillOldRule()
end

-- Native stop point (0.5.10, MPFEVER_STOPPOINT=0: off). Every stop point of this game (another player's build, its own held build,
-- the barrier of the other games' clocks, the session's pause) is written to native_stop.txt ("<step> <sequence>", step = game
-- time / STEP), and the native module makes the engine's batches end there exactly (see InstallNativeStop in mpfever_native.cpp):
-- the game runs at its speed up to the stop point and stands there at once. Before, it paused short of the point and asked the
-- engine for the exact steps left, a handshake round trip each (STEPS), and waited for the proof that the engine stood still:
-- every build of another player slowed the game for one to three seconds. The module answers in native_stop_state.txt ("<sequence>
-- <step at the start of the latest batch> <steps it made> <stop point>"): standing at the stop point is the latest batch at that
-- step, making none, for the stop point written last. Used once the module has answered (G.nstop.ok).
G.nstop = { on = os.getenv("MPFEVER_STOPPOINT") ~= "0", L = false, seq = (os.time() % 100000) * 1000, ok = false, readFrame = -1 }
G.nstopRead = function()
	local N = G.nstop
	if N.readFrame == G.frames then return N.st end
	N.readFrame = G.frames
	N.st = nil
	local f = C.IO.open(C.DIR .. BS .. "native_stop_state.txt", "rb")
	if not f then return nil end
	local line = f:read("*l")
	f:close()
	local seq, S, n, L = tostring(line or ""):match("^(%-?%d+) (%d+) (%d+) (%-?%d+)")
	if not seq then return nil end
	N.st = { seq = tonumber(seq), S = tonumber(S), n = tonumber(n), L = tonumber(L) }
	if not N.ok and N.st.seq == N.seq and N.L ~= false then
		N.ok = true
		log("stop point: the native module keeps this game's stop points (no exact steps before them any more)")
	end
	return N.st
end
G.nstopOk = function() return G.nstop.on and G.nstop.ok end
G.nstopWrite = function(stopAt)
	local N = G.nstop
	if not N.on or not C.ACTIVE then return end
	local L = stopAt and math.floor(stopAt / STEP) or -1
	if L ~= N.L then
		N.seq, N.L = N.seq + 1, L
		local f = C.IO.open(C.DIR .. BS .. "native_stop.txt", "wb")
		if f then f:write(tostring(L) .. " " .. tostring(N.seq) .. NL); f:close() end
	end
	if not N.ok then G.nstopRead() end
end
-- the simulation stands at the stop point written last, kept by the native module (and this interface sees that time)
G.nstopStanding = function()
	local N = G.nstop
	if not (N.on and N.ok) or N.L == false or N.L < 0 then return false end
	local st = G.nstopRead()
	if st == nil or st.seq ~= N.seq or st.L ~= N.L or st.n ~= 0 or st.S ~= N.L then return false end
	local ok, now = pcall(gameTime)
	return ok and now == N.L * STEP
end

-- The simulation is about to stand at the stop point 'at' (or stands there): the module answered for the stop point written last,
-- and its latest batch ends there. A build sent now goes into the engine's next batch, which starts at that step whichever batch
-- that is (the stop point keeps every batch there at no step), before its steps: it lands exactly at 'at', without waiting for
-- this interface to see that time (one or two handshakes sooner). MPFEVER_STOPEARLY=0: only once the interface sees it.
G.nstopEarly = os.getenv("MPFEVER_STOPEARLY") ~= "0"
G.nstopWillStand = function(at)
	local N = G.nstop
	if not (G.nstopEarly and N.on and N.ok) or N.L == false or N.L < 0 or N.L * STEP ~= at then return false end
	local st = G.nstopRead()
	return st ~= nil and st.seq == N.seq and st.L == N.L and (st.S == N.L or st.S + st.n == N.L)
end

-- the old rule (with MPFEVER_STEPLOG also timed next to the new one)
G.stillOldRule = function()
	return gameSpeed() == 0 and G.frames - (G.clockMovedAt or 0) >= 12 and os.clock() - (G.clockMovedClock or 0) >= 0.45
end

-- A shorter proof that the engine stands still (MPFEVER_FASTSTILL=1; with MPFEVER_STEPLOG=1 both proofs are timed and the new one
-- is checked, in either mode). The interface sees the simulation only at the handshake (every 200 ms of real time, one copy of the
-- world's components), so a clock still for a few frames proves nothing and the old rule waits 0.45 s. The game time component
-- has two counters (engine.d.tl): tickCount, one per frame of the simulation, also when it is paused, and updateCount, one per
-- update (step). Seen from the interface both change only with a handshake. The proof: the latest copy reads speed 0, and its
-- updateCount is the one of the copy before it. No step was made between the two handshakes, and from the latest one on the
-- simulation runs at speed 0: it makes no step until the interface asks for one. (A first version also wanted the copy before to
-- read speed 0: one handshake later, 0.4 s instead of 0.2 s when the game has just stopped for a build.)
-- Measured with two games on one PC (autotests newroad and dsplit at 1x, 2x and 4x, upgrade and dnodemove at 1x and 4x): for
-- the interface tickCount changes about 5 times a second while the game stands still (once per handshake), the clock and
-- updateCount always changed together, the speed only with a new copy, and the clock never moved after this proof without a step
-- request. Safety: never trusted until the counters were watched for 120 frames and tickCount changed in some of them but not
-- more than half (checked again every 120 frames: a counter moving with every frame of the interface proves nothing about a
-- handshake, one that does not move proves nothing either); not used when the fields cannot be read; and the old rule still
-- counts.
-- (the functions hang on G: this chunk is a few locals short of the 200 a Lua function may have)
G.STILL_WINDOW = 120
G.stillCounters = function()
	local okG, gt = pcall(function() return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) end)
	if not okG or gt == nil then return nil end
	local okF, tick, upd = pcall(function() return gt.tickCount, gt.updateCount end)
	if okF and type(tick) == "number" and type(upd) == "number" then return tick, upd end
	return nil
end

G.stillEpisodeLog = function(S, ended)
	local function part(f, s) return f and (f .. " frames / " .. string.format("%.2f", s) .. " s") or "not before the clock moved again" end
	S.logs = (S.logs or 0) + 1
	if S.logs > 3000 then return end
	log("STILL since the clock last moved (t=" .. tostring(S.epT) .. ", frame " .. tostring(S.epAt) .. "): old rule " .. part(S.oldF, S.oldS)
		.. ", new rule " .. (S.usable and part(S.newF, S.newS) or ("not usable (" .. tostring(S.why) .. ")"))
		.. ((S.usable and S.newF and S.oldF) and (", " .. (S.oldF - S.newF) .. " frames / " .. string.format("%.2f", S.oldS - S.newS) .. " s sooner") or "")
		.. ((S.proofText and S.newF) and (", proof: " .. S.proofText) or "")
		.. " (wrong so far: " .. (S.wrong or 0) .. ")"
		.. " [decides: " .. ((G.fastStill and S.usable) and "the earlier of the two" or "the old rule") .. "]" .. (ended and " [episode over]" or ""))
end

G.stillWatch = function()
	local S = G.stillS
	if not S then
		S = { usable = false, why = "watching the counters", win = 0, changes = 0 }
		G.stillS = S
	end
	local tick, upd = G.stillCounters()
	local speed = gameSpeed()
	-- (MPFEVER_STEPLOG: checks of the premise, logged only) the clock moved while the proof stood, with nothing asked of the engine
	-- since (no exact steps, no speed above 0): the proof was wrong. The clock and updateCount should change together, and the speed
	-- only with a new copy. Exact steps that pass their target were added to steps the engine was still making.
	if G.stillLog and tick ~= nil then
		local moved = G.clockMovedAt == G.frames
		if S.lastUpd ~= nil then
			if moved and S.proven and not S.askedSince and (G.stepSince or -1) < (S.provenAt or 0) then
				S.wrong = (S.wrong or 0) + 1
				log("STILL CHECK: the clock moved to t=" .. tostring(G.clockSeen) .. " " .. (G.frames - (S.provenAt or 0)) .. " frames after the new rule's proof, with no step request and no speed above 0 since: the proof was WRONG (" .. S.wrong .. ") [frame " .. G.frames .. "]")
			end
			if moved ~= (upd ~= S.lastUpd) then
				S.apart = (S.apart or 0) + 1
				if S.apart <= 20 then
					log("STILL CHECK: " .. (moved and "the clock moved, updateCount did not" or "updateCount moved, the clock did not") .. " (t=" .. tostring(G.clockSeen) .. ", updateCount " .. upd .. ", speed " .. tostring(speed) .. ", " .. S.apart .. " so far) [frame " .. G.frames .. "]")
				end
			end
			if speed ~= S.lastSpeed and tick == S.lastTickSeen then
				S.speedApart = (S.speedApart or 0) + 1
				if S.speedApart <= 20 then
					log("STILL CHECK: the speed changed from " .. tostring(S.lastSpeed) .. " to " .. tostring(speed) .. " without a new copy (tickCount " .. tick .. ", " .. S.speedApart .. " so far) [frame " .. G.frames .. "]")
				end
			end
		end
		S.lastUpd, S.lastSpeed, S.lastTickSeen = upd, speed, tick
	end
	-- (always: two replays of 2026-10-25 were built two steps after their time, see "REPLAY SEND")
	if G.stepTarget and type(G.clockSeen) == "number" and G.clockSeen > G.stepTarget and S.overAt ~= G.stepTarget then
		S.overAt = G.stepTarget
		S.over = (S.over or 0) + 1
		log("STILL CHECK: exact steps passed their target: t=" .. G.clockSeen .. " for " .. G.stepTarget .. " (" .. S.over .. " so far, hold "
			.. tostring(G.holdAt) .. ", still proof " .. tostring(S.proven) .. ") [frame " .. G.frames .. "]")
	end
	if tick == nil then
		if S.why ~= "fields not readable" then
			S.why = "fields not readable"
			log("STILL: GameTime.tickCount / updateCount cannot be read from the interface: the old rule decides" .. (G.fastStill and " (MPFEVER_FASTSTILL has no effect)" or ""))
		end
		S.usable, S.proven, S.cpTick, S.cpUpd, S.cpPrevUpd = false, false, nil, nil, nil
	else
		-- is tickCount a handshake counter (it changes in a fraction of the frames) or a frame counter (it changes in all)?
		S.win = S.win + 1
		if S.lastTick ~= nil and tick ~= S.lastTick then S.changes = S.changes + 1 end
		S.lastTick = tick
		if S.win >= G.STILL_WINDOW then
			local frameCounter = S.changes * 2 > S.win
			local was = S.calibrated and S.usable
			S.usable = not frameCounter and S.changes > 0
			S.why = frameCounter and "tickCount changes with nearly every frame" or (S.changes == 0 and "tickCount does not change" or "ok")
			if S.calibrated == nil or was ~= S.usable then
				log("STILL: tickCount changed in " .. S.changes .. " of " .. S.win .. " frames (" .. (speed == 0 and "stopped" or "running") .. "): "
					.. (S.usable and "it follows the handshakes, the new rule can be used" or ("the new rule is not used (" .. S.why .. "), the old rule decides")))
			end
			S.calibrated = true
			S.win, S.changes = 0, 0
		end
		-- the proof (see above): the latest copy and the one before it
		if tick ~= S.cpTick then S.cpPrevTick, S.cpPrevUpd, S.cpTick, S.cpUpd = S.cpTick, S.cpUpd, tick, upd end
		local proven = speed == 0 and S.cpPrevUpd ~= nil and S.cpUpd == S.cpPrevUpd
		if proven and not S.proven then
			S.provenAt, S.askedSince = G.frames, false
			S.proofText = "updateCount " .. upd .. " in the copies with tickCount " .. tostring(S.cpPrevTick) .. " and " .. tick .. ", speed 0"
		end
		S.proven = proven
		-- (for the check above: a speed other than 0 asked of the engine since the proof; -1 = to be sent again, counted too)
		if S.proven and G.lastSet ~= 0 then S.askedSince = true end
	end
	-- timing, per time the clock stood still: the frames and seconds after its last move that each rule needed
	if G.stillLog then
		if S.epAt ~= G.clockMovedAt then
			if S.epAt ~= nil and not S.logged and (S.oldF or S.newF) then G.stillEpisodeLog(S, true) end
			S.epAt, S.epT, S.oldF, S.oldS, S.newF, S.newS, S.logged = G.clockMovedAt, G.clockSeen, nil, nil, nil, nil, false
		end
		local sinceF, sinceS = G.frames - (G.clockMovedAt or 0), os.clock() - (G.clockMovedClock or 0)
		if not S.oldF and G.stillOldRule() then S.oldF, S.oldS = sinceF, sinceS end
		if not S.newF and S.usable and S.proven then S.newF, S.newS = sinceF, sinceS end
		if not S.logged and S.oldF and (S.newF or not S.usable) then
			S.logged = true
			G.stillEpisodeLog(S, false)
		end
	end
end

-- (a due company join holds the game until it is applied, see nativeHoldAt)
G.joinHoldDue = os.getenv("MPFEVER_JOINHOLD") ~= "0"

local function nativeHoldAt()
	local m = nil
	local now = gameTime()
	-- A game running at speed passes a stop point by what it simulates before the speed change reaches the engine (up to a few
	-- steps at x4): a build would then land a step late here. So the game first stops a little BEFORE the build's time, then
	-- the engine performs exactly the steps left (exact once stopped, see pacing).
	-- (as far before it as a running game may overshoot a stop point: then it never passes the build's time)
	local early = overshootReserve() + 1
	local stopped = G.simStill()
	local function approach(at)
		-- (with exact steps, pacing already stops the game that far before a stop point and steps exactly from there: aimed
		-- at that early point as well, the two margins added up and the game stopped at the click, issue #34)
		if O.steps and not G.oldHolds then return at end
		local e = at - early * STEP
		if now < e or not stopped then return e end   -- (inside the margin while still running: stop where it is)
		return at
	end
	for _, r in ipairs(G.natRelease) do if not r.lead then local t = approach(r.at) if m == nil or t < m then m = t end end end
	for _, w in ipairs(G.natWait) do local t = approach(w.at) if m == nil or t < m then m = t end end
	-- other players' builds already received: this game must stop exactly at their time
	if (G.replayOut or 0) > 0 and G.frames - (G.replaySince or 0) > 600 then
		log("replay without engine answer for 600 frames: hold released")
		G.replayOut = 0
	end
	-- (stops and signals placed again after a build: all in its step, see G.placeStopsAfter; not more than a minute)
	if G.stopsAfterBusy and G.frames - G.stopsAfterBusy > 3600 then log("stops placed again: still busy after a minute, hold released"); G.stopsAfterBusy = nil end
	-- (at the time of the replay sent last when it was sent as the simulation came to it, see G.nstopWillStand)
	if (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or G.terrainBusy or G.coBusy or G.stopsAfterBusy then
		if G.replayAt and G.replayAt > now and G.replayAt <= now + 8 * STEP then return G.replayAt end
		return now
	end
	-- (a player joining waits until the others announced at the same time have arrived too, see runNativeReplays; a replay due
	-- now waits until the engine is proven still, see G.sendStillWait)
	for _, a in ipairs(G.nativeQueue or {}) do
		if a.fn == "mpfCoJoin" and a.at <= now and (G.frames - (a.recvFrame or 0) < K.JOIN_GATHER or G.joinTurn(a) == false) then return now end
		-- A due join still waiting here is applied later in this frame (runNativeReplays, after this): released now, the "resume"
		-- of runPausedActions reached the simulation first and a batch of steps could run before G.coBusy held it again. The
		-- company was then created 4 or 5 steps late on that game, with other entity ids than on the others (0.5.13 night tests
		-- x2 and x4: company 5 entity 33903 on the host, 44955 on the client), and the games drifted later. MPFEVER_JOINHOLD=0: as before.
		if a.fn == "mpfCoJoin" and a.at <= now and G.joinHoldDue then
			if not a.dueHoldLogged then a.dueHoldLogged = true; log("companies: join " .. tostring(a.uid) .. " due at t=" .. tostring(a.at) .. " holds the game at t=" .. tostring(now) .. " until it is applied [frame " .. G.frames .. "]") end
			return now
		end
		if a.stillWait and a.at <= now then return now end
	end
	for _, a in ipairs(G.nativeQueue or {}) do
		if a.at > now then local t = approach(a.at) if m == nil or t < m then m = t end end
	end
	return m
end

-- Builds made while the session is paused all have the same time: each game applied its own at once and the others' when they
-- came, so two players building within the network's delay built in a different order on each game (a session of the friends:
-- a station and a bulldozing, one segment more on one game, a resync). Each paused build now takes a turn from the host
-- (announced with "nat_ticket" to every game, in the order the host gave them) and every game applies them in that order: its
-- own builds wait for the turns before them to be applied here. A turn that never comes is skipped after 30 s (desync risk).
-- MPFEVER_PAUSEDORDER=0: as before.
G.pt = { next = 1, done = 0, of = {}, skip = {}, seen = false }
G.ptOn = os.getenv("MPFEVER_PAUSEDORDER") ~= "0"
G.ptKey = function(origin, id) return tostring(origin) .. ":" .. tostring(id) end
G.ptTicket = function(origin, id, seq)
	-- (the first turn this game hears of: the ones before it were made before this game was loaded)
	if not G.pt.seen then G.pt.seen = true; if G.pt.done < seq - 1 then G.pt.done = seq - 1 end end
	G.pt.of[G.ptKey(origin, id)] = seq
	if seq >= G.pt.next then G.pt.next = seq + 1 end
end
G.ptIssue = function(origin, id)
	if C.ROLE ~= "host" or not G.ptOn then return end
	local seq = G.pt.next
	G.ptTicket(origin, id, seq)
	send("nat_ticket", { origin = origin, id = id, seq = seq })
	log((tostring(id):match("^a%d") and "paused action " or "paused build ") .. G.ptKey(origin, id) .. ": turn " .. seq)
end
G.ptAdvance = function()
	while G.pt.skip[G.pt.done + 1] do G.pt.skip[G.pt.done + 1] = nil; G.pt.done = G.pt.done + 1 end
end
G.ptMayGo = function(seq)
	if not seq then return true end
	G.ptAdvance()
	if G.pt.done >= seq - 1 then G.pt.waitSince = nil; return true end
	G.pt.waitSince = G.pt.waitSince or G.frames
	if G.frames - G.pt.waitSince > 1800 then
		log("paused build turn " .. (G.pt.done + 1) .. " never applied here in 30 s: skipped (desync risk)")
		G.pt.done = G.pt.done + 1
		G.pt.waitSince = nil
		return G.ptMayGo(seq)
	end
	return false
end
G.ptDone = function(seq)
	if seq and seq > G.pt.done then G.pt.done = seq end
	G.pt.waitSince = nil
end
H.nat_ticket = function(from, p)
	if type(p.seq) == "number" then G.ptTicket(p.origin, p.id, p.seq) end
end

-- The players' announcements made in a pause (the start of a session, a resynchronisation's load) all have the same time. Each
-- game applied them in its own order: the host its own at once, a player in the order of the names, and with two new players
-- each game gave them other company numbers (a session of 2026-10-25: the host made a company 6 for the client that the client
-- never made, its money and loans differed at every check). Every announcement made in a pause now takes a turn from the host,
-- among the paused builds (G.pt), and every game applies them in that order; one whose turn has not come in 10 s goes as before.
-- MPFEVER_JOINTURNS=0: as before.
G.joinTurns = G.ptOn and os.getenv("MPFEVER_JOINTURNS") ~= "0"
G.joinTurnId = function(a) return "co" .. tostring(a.oseq) end
-- the turn of a paused announcement: its number, false while it has none yet (wait), nil when it needs none
G.joinTurn = function(a)
	if a.fn ~= "mpfCoJoin" or not a.paused or not G.joinTurns then return nil end
	local seq = G.pt.of[G.ptKey(a.origin, G.joinTurnId(a))]
	if seq then return seq end
	if G.frames - (a.recvFrame or G.frames) > 600 then
		if not a.turnLogged then log("companies: no turn from the host for the announcement " .. tostring(a.uid) .. " in 10 s: applied as before") end
		a.turnLogged = true
		return nil
	end
	return false
end

-- Every other action made in a pause (a line edited, a vehicle bought, a name) took no turn: each game applied its own at once and
-- the others' when they came, so an action and another player's build went in a different order on each game. A line edited on
-- the host just before a stop of the client's was built there, and just after it on the client's (a session of the friends,
-- 2026-10-25 22:10:47): the build took other free entity ids on each game, every vehicle bought after it got another id, and the
-- games were reloaded 3 minutes later. Each paused action now takes a turn from the host among the paused builds (G.pt), and every
-- game applies it in that order; one whose turn has not come in 10 s goes as before. MPFEVER_ACTTURNS=0: as before.
G.actTurns = G.ptOn and os.getenv("MPFEVER_ACTTURNS") ~= "0"
-- (with its time: a player's action counter starts again from 1 when its game loads, and a turn kept from an earlier pause would
-- let the new action go out of its turn)
G.actTurnId = function(a) return "a" .. tostring(a.oseq) .. "@" .. tostring(a.at) end
-- the turn of a paused action: its number, false while it has none yet (wait), nil when it needs none
G.actTurn = function(a)
	if not a.paused or not G.actTurns or a.kind == "hash" or a.fn == "mpfCoJoin" or a.oseq == nil then return nil end
	local seq = G.pt.of[G.ptKey(a.origin, G.actTurnId(a))]
	if seq then return seq end
	a.turnSince = a.turnSince or G.frames
	if G.frames - a.turnSince > 600 then
		if not a.turnLogged then log("paused action " .. tostring(a.uid) .. ": no turn from the host in 10 s, applied as before (desync risk)") end
		a.turnLogged = true
		return nil
	end
	return false
end

H.nat_pending = function(from, p)
	if p.origin == G.me then return end
	if p.paused then G.ptIssue(p.origin, p.id) end
	pcall(G.noteOthers, { origin = p.origin, at = p.at, native = true })
	logMargin("nat_pending", p.at, p.origin, p.lead)
	G.natWait[#G.natWait + 1] = { origin = p.origin, id = p.id, at = p.at, since = G.frames, lead = p.lead }
	if p.lead then
		-- BUILDLEAD: the builder released it at once; the time is only the earliest the build can land at (its game's time when it
		-- was released), the real one comes with the build (nativeReceived). Holding there keeps this game from passing it.
		local okT, nowT = pcall(gameTime)
		log("BUILDLEAD native build of " .. tostring(p.origin) .. " released at once at t=" .. tostring(p.at) .. " (this game is at " .. tostring(okT and nowT or "?") .. "): holding there until it arrives")
		if okT and p.at < nowT then
			log("BUILDLEAD WARNING: this game is already past t=" .. tostring(p.at) .. ": the build will land late here (desync risk)")
			G.aheadLocked = true
		end
	else
		log("native build of " .. tostring(p.origin) .. " announced for t=" .. tostring(p.at) .. ": holding there")
	end
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
			terrainLead("edit")
			G.terrainBlobs[#G.terrainBlobs + 1] ={ id = tonumber(tid), x0 = tonumber(tx0), y0 = tonumber(ty0), w = tonumber(tw),
				h = tonumber(th), len = tonumber(tlen), fnv = tfnv, extra = tonumber(textra), frame = G.frames }
			while #G.terrainBlobs > 12 do table.remove(G.terrainBlobs, 1) end
		end
		local rid, rst = line:match("^terrain_in (%d+) (%a+)")
		if rid then G.terrainIn[tonumber(rid)] = rst end
		local id = tonumber(line:match("^deferred (%d+)"))
		if id and G.resyncRefuse("native build " .. id) then
			-- (held by the DLL: dropped there, never given to the engine)
			nativeCtl("dropid " .. id)
			id = nil
		end
		-- (0.6) refused by a game option (a module's allow, with the build the tool applied when it is known: see G.featTool):
		-- dropped by the DLL as a build made during a resynchronisation, never announced to the others
		if id and G.featOn and G.featAllow and G.featRefuse({ fn = "nativeBuild", native = true, natId = id, proposal = G.featTakeTool() }) then
			nativeCtl("dropid " .. id)
			id = nil
		end
		if id then
			-- the tool's Context flags (1 gatherBuildings, 2 terrain alignment, 4 street graph cleanup; 32 = known), shipped with the build
			local cbits = tonumber(line:match("^deferred %d+ (%d+)"))
			if cbits then G.natCtx = G.natCtx or {}; G.natCtx[id] = cbits end
			-- and the interface's refundable entities as the tool had them (what this player just built, given back when
			-- demolished): read now, before the build is applied, and shipped with it (see refundInto)
			pcall(function()
				local rf = C.refundList(api.gui.construction.getRefundableEntities())
				G.natRefund = G.natRefund or {}
				G.natRefund[id] = rf
				G.refundLogged = (G.refundLogged or 0) + 1
				if G.refundLogged <= 3 then log("native build " .. id .. ": refundable entities " .. C.ser(rf):sub(1, 300)) end
			end)
			local now = gameTime()
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt
			-- BUILDLEAD: this game leads, and the others stay well behind it: no hold, no circle on the ground, the build goes to the
			-- engine in this very frame (runNativeRelease). It is announced for the time this game is at: the earliest it can land at.
			local lead, why = false, nil
			if G.buildLead then G.leadRefusedCheck(true) end
			if G.buildLead and not paused then lead, why = G.buildLeadState() end
			if G.buildLead and paused then why = leadLevel() > 0 and "the session is paused" or "no tool in hand" end
			if lead then
				G.natRelease[#G.natRelease + 1] = { id = id, at = now, lead = true }
				send("nat_pending", { origin = G.me, at = now, id = id, lead = true })
				G.leadStats.atOnce = G.leadStats.atOnce + 1
				log("BUILDLEAD native build " .. id .. " released at once at t=" .. now .. " (it lands at this step or a few later) [frame " .. G.frames .. "]")
			else
				markPending(id)
				local at = paused and pausedStamp(now) or (stampFor(now) + STEP)
				-- (paused: released in its turn, see G.pt)
				local pt = paused and G.ptOn or nil
				-- (t0, copy: see G.restale)
				G.natRelease[#G.natRelease + 1] = { id = id, at = at, paused = pt, frame0 = G.frames, t0 = now, copy = G.takeToolCopy() }
				if pt then G.ptIssue(G.me, id) end
				send("nat_pending", { origin = G.me, at = at, id = id, paused = pt })
				log("native build " .. id .. " held by the DLL, released at t=" .. at .. " (now " .. now .. ") [frame " .. G.frames .. "]")
				-- (with a tool in hand, the reason it is held the usual way: which test of G.buildLeadState failed)
				if G.buildLead and why ~= "no tool in hand" then
					G.leadStats.held = G.leadStats.held + 1
					log("BUILDLEAD native build " .. id .. " held the usual way: " .. tostring(why))
				end
			end
		end
	end
end

-- A tool's build is computed when the player clicks (the ground it aligns, the town buildings it takes away: the proposal itself
-- carries them), held about two seconds, then applied as it was computed. Another player's build landing in between (19 industry
-- extensions next to a track the player was taking away, 2026-10-25; two streets of one junction upgraded at once, the restale
-- scenario) changed the place: the builder applied its computation of the click, every other game computed the build again from
-- what was shipped, and the games went apart (town statistics, entity ids: a reload). Now the proposal the tool applied is kept
-- (its compact form, the one a capture ships), and when another player's build or world action was applied here since the click,
-- or is stamped between the click and the release, the held build is not given to the engine: it is shipped as it is and this
-- game replays it too, by the same way as the others (as the edits from a window, G.uiEdit): every game computes it at the same
-- moment from the same data. Not in the separate companies mode, where the tool's proposal names the savegame's company (the
-- native module gives its build this player's company, not a replay). MPFEVER_RESTALE=0: as before.
-- OFF by default since 0.5.12 (MPFEVER_RESTALE=1 turns it on): the tool's own command is then never given to the engine, and the
-- tool waits for its answer for ever. The stop tool, for one, marks itself busy when it sends a build and only that answer frees
-- it: the tool stayed dead until the next reload (issue #91, one company per player: "build cancelled" then no more stops,
-- bulldozer, modules, streets; in one report 2 of 6 builds were cancelled, by builds anywhere on the map). The answer cannot be
-- made up either: the tool reads the build's result from it and the engine asserts on a build that was not applied. A build
-- made where another player built in the same second is applied as the tool computed it, as before 0.5.7, and if the games then
-- differ, the host's game is reloaded everywhere.
G.restaleOn = os.getenv("MPFEVER_RESTALE") == "1"
G.othersAt = {}
G.worldFrame = 0
-- the tool's event when it applies a build ({proposal, data} by position or by name): its compact form, for G.restale
G.toolApplied = function(param)
	if not G.restaleOn or not G.session.started or G.cmode == "separate" then return end
	local pr = type(param) == "table" and (param[1] or param.proposal) or nil
	if pr == nil then return end
	local ok, compact = pcall(C.compactProposal, pr)
	-- (a copy with nothing in it is never used: replayed, the player's build would be lost on every game)
	local function hasContent(m)
		if #(m.toAdd or {}) > 0 or #(m.toRemove or {}) > 0 then return true end
		for _, k in ipairs({ "addedNodes", "addedSegments", "removedNodes", "removedSegments", "edgeObjectsToAdd", "edgeObjectsToRemove" }) do
			if #((m.proposal or {})[k] or {}) > 0 then return true end
		end
		return false
	end
	if ok and type(compact) == "table" and hasContent(compact) then
		G.toolCopy = { frame = G.frames, compact = compact }
	else
		G.toolCopy = nil
		if not G.toolCopyErr then
			G.toolCopyErr = true
			log("held builds: the tool's proposal could not be read (" .. (ok and "nothing in it" or shortErr(compact)) .. "): not replayed here when another player builds meanwhile")
		end
	end
end
-- the copy of the build the tool applied in this frame or just before (the native module reports a held build a frame or two
-- after the tool's event)
G.takeToolCopy = function()
	local t = G.toolCopy
	G.toolCopy = nil
	if t and G.frames - t.frame <= 5 then return t.compact end
	return nil
end
-- an action of another player that changes the world (a build, an industry extension, a terrain edit, a mod's command), at its
-- game time: a build held here since before that time was computed without it
G.isWorldAct = function(p)
	if type(p) ~= "table" then return false end
	local fn = tostring(p.fn or "")
	return p.native == true or p.terrain == true or p.fn == nil or fn:find("Proposal", 1, true) ~= nil or fn:find("Terrain", 1, true) ~= nil
		or fn:find("^makeTown") ~= nil or fn:find("Bulldozable", 1, true) ~= nil or fn:find("^asset") ~= nil or fn == "makeScriptingSendEventCmd"
end
G.noteOthers = function(p)
	if not G.restaleOn or type(p) ~= "table" or p.origin == G.me or type(p.at) ~= "number" or not G.isWorldAct(p) then return end
	G.othersAt[#G.othersAt + 1] = { at = p.at, origin = p.origin }
	while #G.othersAt > 64 do table.remove(G.othersAt, 1) end
end
-- whether the world changed here under a held build since the tool computed it: another player's build or action applied in a
-- frame after the click (G.worldFrame, the replays and the actions of a pause), or stamped between the click's time and the release
G.restaleWhy = function(r, at)
	if (G.worldFrame or 0) > (r.frame0 or math.huge) then return "another player's build applied here since the click" end
	-- (one at the release's own step counts when its player is ranked before this one: it is applied first, see G.sameStepWait)
	for _, o in ipairs(G.othersAt) do
		if r.t0 and o.at >= r.t0 and (o.at < at or (o.at == at and tostring(o.origin) < tostring(G.me))) then
			return "another player's build or action at t=" .. o.at .. " (clicked at t=" .. r.t0 .. ")"
		end
	end
	return nil
end
-- at the release of the held build r: true when it was shipped and queued here as a replay instead (an error leaves the build as
-- the tool computed it)
G.restale = function(r, at)
	local ok, res = pcall(G.restaleBody, r, at)
	if not ok then log("native build " .. tostring(r.id) .. ": not replayed here (" .. tostring(res):sub(1, 200) .. ")") end
	return ok and res == true
end
-- the chat tells everybody that a player's build was left out (said by every game: only the host's game reaches the chat, the
-- launcher of a player's game does not pass it on)
G.sameSpotSay = function(origin)
	G.coSay(C.Tf("La construction de %s a été annulée : un autre joueur a construit au même endroit au même moment. Refaites-la.",
		"%s's build was cancelled: another player built at the same place at the same moment. Please make it again.", tostring(origin)))
end
G.restaleBody = function(r, at)
	-- (MPFEVER_RESTALELOG=1, tests: why a held build is or is not replayed here)
	if os.getenv("MPFEVER_RESTALELOG") == "1" then
		log("restale check " .. tostring(r.id) .. ": copy " .. tostring(r.copy ~= nil) .. ", t0 " .. tostring(r.t0) .. ", at " .. tostring(at)
			.. ", frame0 " .. tostring(r.frame0) .. ", world frame " .. tostring(G.worldFrame) .. ", others " .. C.ser(G.othersAt):sub(1, 200))
	end
	if not G.restaleOn or r.lead then return false end
	-- One company per player: the tool's copy names the savegame's company (the native module gives the build this player's
	-- company at the tool's command only), so it cannot be replayed. The build is left out on every game instead, as a refused
	-- one (the others stop holding for it, its turn of a pause is skipped), and the chat tells its player to make it again:
	-- before, it was applied as computed and the games reloaded. MPFEVER_RESTALESEP=0: as before. (Only with MPFEVER_RESTALE=1
	-- since 0.5.12: the tool of the build left out stayed busy, see G.restaleOn)
	if G.cmode == "separate" then
		if os.getenv("MPFEVER_RESTALESEP") == "0" then return false end
		local whyS = G.restaleWhy(r, at)
		if not whyS then return false end
		if not r.fn then nativeCtl("dropid " .. r.id) end
		local seq = G.pt.of[G.ptKey(G.me, r.id)]
		send("nat_cancel", { origin = G.me, id = r.id, pseq = seq, samespot = true })
		if r.paused and seq then G.ptDone(seq) end
		G.restaled = (G.restaled or 0) + 1
		log("native build " .. r.id .. " left out on every game (one company per player, it cannot be replayed): " .. whyS)
		G.sameSpotSay(G.me)
		if r.cb then G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() pcall(r.cb, nil, false) end } end
		return true
	end
	if type(r.copy) ~= "table" then return false end
	local why = G.restaleWhy(r, at)
	if not why then return false end
	-- the act a capture of this build would have shipped (the compact proposal, its references translated as the capture does)
	local args = { n = 4, [1] = C.deser(C.ser(r.copy)), [2] = { __player = true }, [3] = false, [4] = true }
	R.translateOut("makeWorldBuildProposalCmd", args, G.rev or {})
	args = C.deser(C.ser(args))
	G.oseq = G.oseq + 1
	local a = { fn = "makeWorldBuildProposalCmd", args = args, at = at, origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
		native = true, natId = r.id, paused = r.paused and true or nil, co = G.myCo, lt = G.loadId,
		ctx = G.natCtx and G.natCtx[r.id] or nil, refund = G.natRefund and G.natRefund[r.id] or nil }
	if G.natCtx then G.natCtx[r.id] = nil end
	if G.natRefund then G.natRefund[r.id] = nil end
	if a.paused then a.pseq = G.pt.of[G.ptKey(G.me, r.id)] end
	-- (the tool's command, held by the native module, is never given to the engine: dropped there at the next command)
	if not r.fn then nativeCtl("dropid " .. r.id) end
	send("act", a)
	-- (here: in the replays' queue at once; in a pause it keeps its turn, which the queue takes when it applies it, so that no
	-- later turn goes before it here)
	local here = C.deser(C.ser(a))
	here.recvFrame = G.frames
	G.nativeQueue[#G.nativeQueue + 1] = here
	G.restaled = (G.restaled or 0) + 1
	log("native build " .. r.id .. " shipped as " .. a.uid .. " and replayed here as the others replay it: " .. why)
	-- (an autotest's build: its answer, as the replay's)
	if r.cb then G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function() pcall(r.cb, nil, true) end } end
	return true
end

-- autotest: a scripted build follows the tools' path (announced, every game holds at its time, then it is sent)
G.autoBuildSeq = 0
-- (proposal: the native proposal the command was made from, kept as a tool's is with MPFEVER_RESTALETEST=1, see G.restale)
-- (0.6.4.1) A computer company's build checked again when it is released (still: a function, true when what the build removes is
-- still as it was made against, else why not): it is made from the interface's view of the world and goes to the engine a few
-- steps later, and what it removes may have been replaced meanwhile. A stop built on a segment that a stop of the same company had
-- just replaced: its segment rebuilt without the other stop, the engine asserted ('it != components.end()') and the host's game
-- stopped (o2 test, 2026-10-31). Not sent then: the others stop holding for it, as for a refused build. MPFEVER_AISTILL=0: as before
local function stillOk(id, still, cb)
	if type(still) ~= "function" or os.getenv("MPFEVER_AISTILL") == "0" then return true end
	local okS, res = pcall(still)
	-- (a check that cannot run never stops a build)
	if not okS or res == true then return true end
	log("autotest build " .. id .. " not sent: " .. tostring(res))
	for _, e in ipairs(G.natShipIds or {}) do
		if e.id == id then G.leadRefused(e, "changed since it was made: " .. tostring(res)); break end
	end
	if cb then pcall(cb, nil, false) end
	return false
end

local function deferredSend(cmd, cb, proposal, still)
	-- (as a tool's build: refused during a resynchronisation, see G.resyncRefuse)
	if G.resyncRefuse("autotest build") then
		if cb then G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() pcall(cb, nil, false) end } end
		return
	end
	local now = gameTime()
	G.autoBuildSeq = G.autoBuildSeq + 1
	local id = 100000 + G.autoBuildSeq
	-- (the refundable entities, shipped with it as with a tool's build: see pollNativeEvents)
	pcall(function() G.natRefund = G.natRefund or {}; G.natRefund[id] = C.refundList(api.gui.construction.getRefundableEntities()) end)
	-- BUILDLEAD: as a real tool's build when this game leads (see pollNativeEvents)
	local lead, why = false, nil
	if G.buildLead then G.leadRefusedCheck(true) end
	-- (in a pause: as a tool's build, at the paused time, in its turn: see pollNativeEvents and G.pt)
	local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt
	if G.buildLead and not paused then lead, why = G.buildLeadState() end
	if lead then
		-- (a scripted build hears the engine's answer: a refused one is cancelled at once. MPFEVER_BUILDLEAD_NOANSWER=1, tests:
		-- not used, as for a tool's build, whose answer only the tool hears: G.leadRefusedCheck must find it out)
		local answer = function(res, success, ...)
			if not success and os.getenv("MPFEVER_BUILDLEAD_NOANSWER") ~= "1" then
				for _, e in ipairs(G.natShipIds or {}) do
					if e.id == id then G.leadRefused(e, "refused: the engine's answer (BUILDLEAD autotest)"); break end
				end
			end
			if cb then return cb(res, success, ...) end
		end
		G.natRelease[#G.natRelease + 1] = { id = id, at = now, lead = true, fn = function() if stillOk(id, still, cb) then O.sendCommand(cmd, answer) end end }
		send("nat_pending", { origin = G.me, at = now, id = id, lead = true })
		G.leadStats.atOnce = G.leadStats.atOnce + 1
		log("BUILDLEAD autotest build " .. id .. " released at once at t=" .. now .. " [frame " .. G.frames .. "]")
		return
	end
	local at = paused and pausedStamp(now) or (stampFor(now) + STEP)
	local pt = paused and G.ptOn or nil
	-- (MPFEVER_RESTALETEST=1: kept like a tool's proposal, made again at its release when another player built meanwhile, see
	-- G.restale)
	G.natRelease[#G.natRelease + 1] = { id = id, at = at, fn = function() if stillOk(id, still, cb) then O.sendCommand(cmd, cb) end end, paused = pt, frame0 = G.frames,
		t0 = now, cb = cb, copy = (os.getenv("MPFEVER_RESTALETEST") == "1" and proposal ~= nil) and select(2, pcall(C.compactProposal, proposal)) or nil }
	if pt then G.ptIssue(G.me, id) end
	markPending(id, { x = 0, y = 0 })
	log("autotest build " .. id .. " held, released at t=" .. at .. " (now " .. now .. ") [frame " .. G.frames .. "]")
	if G.buildLead then
		G.leadStats.held = G.leadStats.held + 1
		log("BUILDLEAD autotest build " .. id .. " held the usual way: " .. tostring(why))
	end
	send("nat_pending", { origin = G.me, at = at, id = id, paused = pt })
end

-- A released build the engine refused is never shipped: the others, who hold for it, are told at once (they would
-- wait half a minute), and its id must not be taken by the next build that is shipped.
local function cancelNativeBuild(entry, why)
	-- (its turn, if it was made in a pause: the others skip it, see G.pt)
	send("nat_cancel", { origin = G.me, id = entry.id, pseq = G.pt.of[G.ptKey(G.me, entry.id)] })
	if entry.lead then toSim("lead_gone", {}) end   -- (BUILDLEAD: the simulation half no longer waits for its capture)
	log("native build " .. tostring(entry.id) .. " produced nothing (" .. why .. "): the others stop holding for it")
end

-- BUILDLEAD: a build released at once that the engine refused. It is never captured (a refused build does not reach
-- onPreBuildProposal), so the others are told as soon as that is sure, not 150 frames later: otherwise the capture of the next
-- build would take its number (it is paired with the first entry at or before its time), and this game would stop at the cap.
G.leadRefused = function(e, why)
	cancelNativeBuild(e, why)
	G.leadStats.refused = (G.leadStats.refused or 0) + 1
	local keep = {}
	for _, x in ipairs(G.natShipIds or {}) do if x ~= e then keep[#keep + 1] = x end end
	G.natShipIds = keep
end

-- Sure means: no capture of this game waits to be shipped (G.outPending), and the interface has seen 4 handshakes since the
-- release (applied at the next one, captured during it, seen here after it; counted by expireShipIds), or 5 frames have passed
-- since the tool placed its next build (a tool waits for the engine's answer to the previous one, and an applied build is
-- captured before that answer; the interface sees the capture a frame after the answer, and a tool's next click came 1 to 2
-- frames after that in a session: so not at once).
G.leadRefusedCheck = function(nextBuild)
	for _, e in ipairs(G.natShipIds or {}) do
		if e.lead and nextBuild and not e.nextSeen then e.nextSeen = G.frames end
	end
	if G.outPending then return end
	for _, e in ipairs(G.natShipIds or {}) do
		if e.lead then
			if e.nextSeen and G.frames - e.nextSeen >= 5 then
				G.leadRefused(e, "refused: not built 5 frames after the tool placed its next build (BUILDLEAD)")
				return G.leadRefusedCheck(false)
			elseif (e.handshakes or 0) >= 4 then
				G.leadRefused(e, "refused: not built " .. e.handshakes .. " handshakes after its release (BUILDLEAD)")
				return G.leadRefusedCheck(false)
			end
		end
	end
end

-- The interface's copy of GameTime.tickCount changes when the interface takes over a new copy of the simulation's state (in
-- our runs once per handshake, in a pause too; it counts the engine's frames, not steps, see docs/RESEARCH.md). While the
-- simulation half is still capturing a build no new copy comes, and a big build takes seconds (a street through a town: 1.7 s).
G.simTick = function()
	local ok, t = pcall(function() return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).tickCount end)
	return (ok and type(t) == "number") and t or nil
end

-- A released build not shipped 150 frames and 4 handshakes after its release was refused (an applied build is applied at the
-- first handshake, captured during it and seen here at the next: 4 leave two to spare; counted at most once per frame), and
-- after 900 frames in any case (the others give up waiting after 1800). Counted in frames alone, a big build still being
-- captured was given up: the others stopped holding for it, ran on and built it a step late (and differently). Nothing is
-- given up while a capture waits to be shipped (shipNativeBuilds holds some back for a few frames).
local function expireShipIds()
	if G.buildLead then G.leadRefusedCheck(false) end
	if not G.natShipIds or #G.natShipIds == 0 or G.outWaiting then return end
	local keep = {}
	local tick = G.simTick()
	for _, e in ipairs(G.natShipIds) do
		if tick and e.simTick == nil then e.simTick = tick end
		if tick and tick ~= e.simTick then e.simTick, e.handshakes = tick, (e.handshakes or 0) + 1 end
		local age = G.frames - e.frame
		local sure = (e.handshakes or 0) >= 4 or (tick == nil and e.simTick == nil)
		if age > 150 and (sure or age > 900) then
			cancelNativeBuild(e, "refused or not built: " .. age .. " frames and " .. (e.handshakes or 0) .. " handshakes after its release")
		else
			if age > 150 and not e.waitTold then
				e.waitTold = true
				log("native build " .. tostring(e.id) .. " not shipped " .. age .. " frames after its release, after " .. (e.handshakes or 0)
					.. " handshake(s): the simulation is still busy, waiting for its capture")
			end
			keep[#keep + 1] = e
		end
	end
	G.natShipIds = keep
end

H.nat_cancel = function(from, p)
	-- (a build left out because another player built at the same place meanwhile, see G.restaleBody)
	if p.samespot then G.sameSpotSay(p.origin) end
	if p.origin == G.me then return end
	if type(p.pseq) == "number" and p.pseq > G.pt.done then G.pt.skip[p.pseq] = true end
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
	G.natShipIds[#G.natShipIds + 1] = { id = r.id, at = at, frame = G.frames, combined = how ~= nil, simTick = G.simTick(), handshakes = 0, lead = r.lead }
	-- (BUILDLEAD: the simulation half is told first, see captureNativeBuild; this command enters the list before the build)
	if r.lead then toSim("lead_out", { at = at }) end
	if r.fn then
		-- a scripted build (autotest) deferred like the tools' ones: sent now, at its announced time
		G.natReleased = G.natReleased - 1
		pcall(r.fn)
	else
		-- (by the DLL's id of the build, not by a count: a count went one off after a dropped build, issue #18)
		nativeCtl("releaseid " .. r.id)
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
		if r.lead then
			-- (BUILDLEAD: at once, the game keeps running; r.at is the time it was announced for, the earliest it can land at)
			releaseOne(r, now, " at once (BUILDLEAD)")
		elseif now >= r.at and gameSpeed() == 0 and r.paused then
			-- (paused: in its turn, after the builds before it are applied here; no turn from the host within 10 s: at once)
			local seq = G.pt.of[G.ptKey(G.me, r.id)]
			local busy = (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0)
			if (seq and G.ptMayGo(seq) and not busy) or (not seq and G.frames - (r.frame0 or 0) > 600) then
				log("native build " .. r.id .. (seq and (": turn " .. seq) or ": no turn from the host in 10 s, released now (desync risk)"))
				-- (replayed here instead: its turn is taken by the replays' queue when it applies it, see G.restale)
				if not G.restale(r, now) then
					releaseOne(r, now)
					G.ptDone(seq)
				end
			else
				keep[#keep + 1] = r
			end
		elseif ((now >= r.at and (gameSpeed() == 0 or (now == r.at and G.nstopStanding()))) or (now < r.at and G.nstopWillStand(r.at))) and not (G.eoHoldOwn and G.frames < (G.replayQuiet or 0)) and not G.sameStepWait(r.at, G.me) then
			-- (the simulation about to stand at its time: released for that time, see G.nstopWillStand)
			local at = math.max(now, r.at)
			if not G.restale(r, at) then releaseOne(r, at) end
		else
			keep[#keep + 1] = r
		end
	end
	G.natRelease = keep
end

-- BUILDLEAD: the time this game does not run past while a build it released at once has not been shipped (pacing). The others
-- hold at the build's earliest step (nat_pending) so they cannot pass its real one, and they stay terrainLeadSteps behind this
-- game's clock; they come up to that hold only when this game's clock is the lead minus their overshoot past the build's time
-- (they stop at most their overshoot past the barrier). The cap keeps the clock short of that, so the shipped build is there
-- before any game could wait for it. (Normally the build is applied within the next command swap and seen by the interface
-- at the next handshake, that is two handshakes of simulation steps; the cap is the lead minus the overshoot, minus one.)
G.updateLeadCap = function()
	G.leadCapAt = nil
	local ref = nil
	for _, e in ipairs(G.natShipIds or {}) do
		if e.lead and (ref == nil or e.at < ref) then ref = e.at end
	end
	if ref then G.leadCapAt = ref + G.leadWindow() end
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

-- (0.5.14, issue #96) Whether another game's build that came too late here is left unbuilt: this game already built something
-- at a later step (its own build, G.builtAt, or another replay), so the two would land in the other order than on their
-- builders' games, their entities numbered otherwise. A late street replacement made the engine assert and the game crash
-- (AddComponent, the Real Track Cant mod's builds from the host's script, 15 steps late, after two builds of this game). The
-- host's game is reloaded instead (replay_failed). A late build with nothing built here since is built as before; the friends'
-- 4-hour session of 2026-10-29 had none late at all. MPFEVER_LATERESYNC=0: built as before
function G.lateSkip(a, now)
	if a.at >= now or a.fn == "mpfCoJoin" or os.getenv("MPFEVER_LATERESYNC") == "0" then return false end
	local since = (G.builtAt or -1) > a.at and G.builtAt or nil
	-- (a build of this game released and not shipped yet stands here already, or will at the next step)
	for _, e in ipairs(G.natShipIds or {}) do
		if type(e.at) == "number" and e.at > a.at and e.at <= now then since = math.max(since or -1, e.at) end
	end
	if not since then return false end
	log("LATE native build " .. tostring(a.uid) .. ": this game built at t=" .. since .. " since its t=" .. a.at .. ": not built here, the host's game is reloaded")
	replayFailed(a, "late build after another build")
	-- (the host's game left it out: the host's game is the one reloaded everywhere, so the build is gone on every game, its
	-- builder's too; the chat says so. A player's game that left it out gets it back with the host's game)
	if C.ROLE == "host" then
		G.coSay(C.Tf("La construction de %s est arrivée trop tard sur la partie de l'hôte : elle n'a pas été gardée. Refaites-la.",
			"%s's build reached the host's game too late and was not kept. Please make it again.", tostring(a.origin)))
	end
	return true
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
	-- (a replay without town statistics of its own: its brush volume is never added to another build's, see SIM.townTag)
	toSim("replaying", { nots = true })
	toSim("terrain_note", { v = tonumber(tostring(t.fnv):sub(-8), 16) or 0, at = a.at })
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
		-- (a later frame than the replay's start: the edit is paid by the company of the player who made it, as there)
		if st == "ready" then
			local okc, errc = pcall(withActor, PL(busy.a), sendTerrainCarrier, busy)
			if not okc then terrainFail(busy.a, "carrier failed: " .. tostring(errc)) end
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
		-- (its own start money, from its join, 0.5.14; else the registry's)
		local start = tonumber(c.start) or (G.co and G.co.start) or 0
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

-- The join is sent to the simulation, then this game waits until its copy of the registry shows the company the join gave (the
-- simulation records it under this send's token, see coApply) and works from that company's number. It never decides in the
-- frame that sends: G.co is read once per frame, before the join is applied. A client that applied two joins on two frames in
-- a row found the player in its old company there (the registry before the join), took it as known and never created the
-- player entity of the new company the host created: their money and loans differed, another resynchronisation followed.
-- MPFEVER_COJOINSTALE=1: as before (the company matched by name and account in G.co, in the frame that sends too).
local function pumpCompanies()
	local b = G.coBusy
	if not b then return end
	local age = G.frames - b.frame
	if os.getenv("MPFEVER_COJOINSTALE") == "1" then
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
		return
	end
	if b.phase == "apply" then
		if not b.sent then
			b.sent = true
			-- (the token of this send: unique on this game, across loads too, as an act's number and time may come again after
			-- a resynchronisation at the same game time)
			b.tok = tostring(G.me) .. ":" .. G.frames .. ":" .. math.floor(os.clock() * 1000)
			local a2 = {}
			for k, v in pairs(b.a) do a2[k] = v end
			a2.coTok = b.tok
			toSim("co_apply", a2)
			return
		end
		local j = nil
		for _, x in ipairs((G.co and G.co.joined) or {}) do if x.k == b.tok then j = x end end
		local c = j and CO.find(G.co, j.id)
		if c then
			if c.ent then G.coBusy = nil
			else b.id = c.id; b.phase = "create"; b.frame = G.frames; coCreate(b, c) end
		elseif age > 240 then
			log("companies: the registry did not take the player in"); G.coBusy = nil
		end
	elseif b.phase == "create" then
		local c = G.co and CO.find(G.co, b.id)
		if c and c.ent then G.coBusy = nil
		elseif age > 600 then log("companies: the new company was not created"); G.coBusy = nil end
	end
end

-- Trees, plants and rocks another player placed with the brush (see captureNativeBuild): the same models at the same places, in the
-- mod's own construction; what the brush removed is removed too.
-- (the name a mod's construction is known by: tried once)
K.ASSET_CON = "mpfever_1::/mpfever_asset.con"
local function assetConName()
	if G.assetConName == nil then
		G.assetConName = false
		for _, n in ipairs({ "mpfever_1::/mpfever_asset.con", "mpfever_asset.con", "::/mpfever_asset.con", "/mpfever_asset.con", "mpfever_1::mpfever_asset.con" }) do
			local ok, id = pcall(api.res.constructionRep.find, n)
			log("assets: construction name '" .. n .. "' -> " .. tostring(ok and id))
			if ok and type(id) == "number" and id >= 0 and not G.assetConName then G.assetConName = n end
		end
	end
	return G.assetConName or K.ASSET_CON
end

-- How many of an asset build's models already stand on this game: the same model less than 5 cm away (across), in a group of
-- trees or the mod's asset construction around them (one octree search around them all). Returns the number of models and the
-- number found here.
G.assetsStanding = function(assets)
	local pts = {}
	for _, as in ipairs(assets or {}) do
		local t = as.transf
		if type(t) == "table" and type(t[13]) == "number" then
			for _, m in ipairs(as.models or {}) do
				local mt = m.transf
				if type(mt) == "table" and type(mt[13]) == "number" then
					local x, y, z = mt[13], mt[14], mt[15]
					pts[#pts + 1] = { m = R.normModel(m.id), x = t[1] * x + t[5] * y + t[9] * z + t[13], y = t[2] * x + t[6] * y + t[10] * z + t[14] }
				end
			end
		end
	end
	if #pts == 0 then return 0, 0 end
	local cx, cy = 0, 0
	for _, q in ipairs(pts) do cx, cy = cx + q.x, cy + q.y end
	cx, cy = cx / #pts, cy / #pts
	local rad = 0
	for _, q in ipairs(pts) do rad = math.max(rad, math.sqrt((q.x - cx) ^ 2 + (q.y - cy) ^ 2)) end
	-- (the models around, in cells of 1 m)
	local grid, seen = {}, {}
	for _, compName in ipairs({ "ASSET_GROUP", "MODEL_INSTANCE_LIST" }) do
		for _, e in ipairs(R.assetsNear({ x = cx, y = cy }, math.min(rad + 50, 2000), compName)) do
			if not seen[e] then
				seen[e] = true
				local c = nil
				pcall(function() c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
				if not c or R.isAssetFile(c.fileName) then
					R.eachInstance(e, function(id, q)
						if q then
							local key = math.floor(q.x) .. ":" .. math.floor(q.y)
							local cell = grid[key]
							if not cell then cell = {}; grid[key] = cell end
							cell[#cell + 1] = { m = R.modelName(id), x = q.x, y = q.y }
						end
					end)
				end
			end
		end
	end
	local here = 0
	for _, q in ipairs(pts) do
		local found = false
		local fx, fy = math.floor(q.x), math.floor(q.y)
		for dx = -1, 1 do
			for dy = -1, 1 do
				for _, it in ipairs(grid[(fx + dx) .. ":" .. (fy + dy)] or {}) do
					if it.m == q.m and (it.x - q.x) ^ 2 + (it.y - q.y) ^ 2 < 0.0025 then found = true end
				end
			end
		end
		if found then here = here + 1 end
	end
	return #pts, here
end

-- Whether a replay of trees is sent as a player's build, as the builder's brush or bulldozer build was: the game's towns script
-- counts the trees of a player's build only (town_util.getProposalStats: the groups removed, less the trees built again). Sent as
-- a script's build before, the bulldozer on one tree near a town lowered that town's score on the builder's game only, and the games
-- were reloaded at the next checks of script:towns. Its town statistics are never added to another build's (its "replaying"
-- events say so, see SIM.townTag): a replay of trees carries none of its own. MPFEVER_ASSETPI=0: as before (a script's build)
G.assetPI = function() return os.getenv("MPFEVER_ASSETPI") ~= "0" end

-- (replayAssets) the tree groups removed one after the other by the engine's own removal proposal, then the trees the builder kept
-- (cons, the mod's constructions) in one build. The removals free their ids at the end of each build, as the builder's single
-- build did, so the trees built after them take the same ids from the queue of freed ids as on the builder's game (unless that
-- queue was empty). Player-initiated as replayAssets' build (G.assetPI): the towns count the groups removed, then the trees built
-- again, which adds up to the builder's one tree taken away (their penalty is linear in the trees).
-- The groups of trees rm removed and the kept trees cons (the mod's constructions) built in ONE native build, as the builder's
-- bulldozer did: the towns count that build once, the trees taken away less the trees built again (in two builds the towns' score
-- and penalty, kept within their bounds after each build, could end elsewhere than the builder's near a town of low score). A
-- script's proposal cannot name a group of trees to remove (the factory refuses it, and the engine's createProposalRemove too:
-- "Unknown exception", 2026-10-25), a native proposal can, as the game's reforestation does. The kept trees are converted by the
-- engine first: a dry run it refuses (the kept trees twice, colliding with themselves and with the group still standing), whose
-- result carries them as the native proposal wants them. dry(cmd, cb) sends the dry run; done(cmd, how, builtDry) gets the
-- command of the build, or nil and why (builtDry: the dry run was built, a desync on a replaying game)
G.treeProposal = function(rm, cons, ctx, pi, dry, done)
	local function native(conv)
		local okP, P = pcall(function()
			local P = api.type.Proposal.new()
			local l = {}
			for i, e in ipairs(rm) do l[i] = e end
			P.toRemove = l
			if conv then P.toAdd = conv end
			return P
		end)
		if not okP or not P then return nil, "native proposal " .. shortErr(P) end
		local okc, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, false, pi) end)
		if not okc or not cmd then return nil, "native command " .. shortErr(cmd) end
		return cmd
	end
	if #cons == 0 then
		local cmd, why = native(nil)
		return done(cmd, cmd and (#rm .. " tree group(s) removed in one native build") or why)
	end
	local sp = api.type.SimpleProposal.new()
	local l = {}
	for _, c in ipairs(cons) do l[#l + 1] = c end
	for _, c in ipairs(cons) do l[#l + 1] = c end
	local okd, dcmd = pcall(function()
		sp.constructionsToAdd = l
		return api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, false)
	end)
	if not okd or not dcmd then return done(nil, "kept trees: dry run not made " .. shortErr(dcmd)) end
	dry(dcmd, function(res, success)
		if success then return done(nil, "kept trees: the dry run was built instead of refused", true) end
		local conv = {}
		pcall(function() local t = res.proposal.toAdd; for i = 1, #cons do conv[i] = t[i] end end)
		if #conv ~= #cons then return done(nil, "kept trees: the engine's conversion has " .. #conv .. " construction(s), " .. (2 * #cons) .. " expected") end
		local cmd, why = native(conv)
		-- (the converted constructions live in that result: kept until the command is made)
		G.treeDryRes = res
		done(cmd, cmd and (#rm .. " tree group(s) removed and " .. #conv .. " construction(s) of kept trees in one native build") or why)
	end)
end

G.assetEngineRemoval = function(a, uid, rm, cons, ctx, strict)
	local pi = G.assetPI()
	local function fail(why)
		log("ASSET REPLAY " .. uid .. ": " .. why)
		if strict then replayFailed(a, ("asset removal: " .. why):sub(1, 100)) end
	end
	-- one native build first (G.treeProposal); refused, or not made: the groups one after the other as below. MPFEVER_TREEONEBUILD=0:
	-- as before (the engine's removal of each group, then the kept trees)
	-- (the dry run is refused only because its copies collide: with the asset construction's flags of 0.5.1, skipCollision, every
	-- replaying game would build it, so the groups one after the other then)
	if os.getenv("MPFEVER_TREEONEBUILD") ~= "0" and os.getenv("MPFEVER_ASSETOLDFLAGS") ~= "1" and not a.treeOneTried then
		a.treeOneTried = true
		local function dry(cmd, cb)
			toSim("replaying", { nots = true })
			replaySend(cmd, cb)
		end
		return G.treeProposal(rm, cons, ctx, pi, dry, function(cmd, how, builtDry)
			if builtDry then return fail(how .. " (desync)") end
			if not cmd then
				log("ASSET REPLAY " .. uid .. ": " .. how .. ": the groups one after the other")
				return G.nowOrNext(function() G.assetEngineRemoval(a, uid, rm, cons, ctx, strict) end)
			end
			toSim("replaying", { nots = true })
			replaySend(cmd, function(res, success)
				G.treeDryRes = nil
				if success then log("ASSET REPLAY " .. uid .. ": " .. how .. ": BUILT") return end
				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				log("ASSET REPLAY " .. uid .. ": " .. how .. ": refused " .. why .. ": the groups one after the other")
				G.nowOrNext(function() G.assetEngineRemoval(a, uid, rm, cons, ctx, strict) end)
			end)
		end)
	end
	local function step(i)
		if i > #rm then
			if #cons == 0 then log("ASSET REPLAY " .. uid .. ": " .. #rm .. " tree group(s) removed by the engine's removal: BUILT") return end
			local sp = api.type.SimpleProposal.new()
			sp.constructionsToAdd = cons
			local okc, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, true, pi) end)
			if not okc or not cmd then fail("the kept trees: command " .. shortErr(cmd)) return end
			toSim("replaying", { nots = true })
			replaySend(cmd, function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				if success then log("ASSET REPLAY " .. uid .. ": " .. #rm .. " tree group(s) removed by the engine's removal, " .. #cons .. " construction(s) of kept trees: BUILT")
				else fail("the kept trees refused " .. why) end
			end)
			return
		end
		local okP, P = pcall(api.engine.util.proposal.createProposalRemove, rm[i], ctx)
		-- (the engine's removal refuses a group of trees, "Unknown exception": a native proposal naming it, as G.treeProposal;
		-- MPFEVER_TREEONEBUILD=0: as before, not reproduced)
		if not okP or not P then
			local okN, PN = false, "off"
			if os.getenv("MPFEVER_TREEONEBUILD") ~= "0" then
				okN, PN = pcall(function()
					local q = api.type.Proposal.new()
					q.toRemove = { rm[i] }
					return q
				end)
			end
			if okN and PN then okP, P = true, PN
			else fail("no engine removal for group " .. rm[i] .. " (" .. shortErr(P) .. "; native " .. shortErr(PN) .. ")") return end
		end
		local okc, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx, true, pi) end)
		if not okc or not cmd then fail("the engine's removal of group " .. rm[i] .. ": command " .. shortErr(cmd)) return end
		toSim("replaying", { nots = true })
		replaySend(cmd, function(res, success)
			if not success then
				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				fail("the engine's removal of group " .. rm[i] .. " refused " .. why)
				return
			end
			step(i + 1)
		end)
	end
	step(1)
end

local function replayAssets(a)
	local args = C.deser(C.ser(a.args or {}))
	local miss = R.translateIn(args, G.bind)
	local uid = tostring(a.uid)
	local rm, unresolved = {}, 0
	for _, e in ipairs(args.toRemove or {}) do
		if type(e) == "number" and e >= 0 then rm[#rm + 1] = e else unresolved = unresolved + 1 end
	end
	-- A removal not found here, or one the builder could not describe (args.lost): the builder's game took away a group of trees
	-- this game would keep, so every entity made afterwards got another id here and the games drifted apart minutes later (the
	-- 22:30 resync of 0.5.1: "0 removed: BUILT"). The build is then reported as not reproduced, and the host's game is reloaded at
	-- once. Unless this game already has it: a savegame loaded during a resynchronisation holds it when the host applied it before
	-- saving; then none of its removals is here and every tree it adds already stands (a removal alone, with nothing to add and
	-- nothing lost: its group is not here, the same). MPFEVER_ASSETSTRICT=0: as before (built without the removals not found, and
	-- a refusal only logged)
	local strict = os.getenv("MPFEVER_ASSETSTRICT") ~= "0"
	local lost = tonumber(args.lost) or 0
	if strict and (unresolved > 0 or lost > 0) then
		local okS, nm, here = pcall(G.assetsStanding, args.assets)
		if not okS then log("ASSET REPLAY " .. uid .. ": models here not counted: " .. shortErr(nm)); nm, here = -1, 0 end
		local why = unresolved .. " removal(s) not found here, " .. lost .. " not described by the builder, " .. tostring(here) .. "/" .. tostring(nm) .. " model(s) already here"
		if #rm == 0 and ((nm > 0 and here == nm) or (nm == 0 and lost == 0)) then
			log("ASSET REPLAY " .. uid .. ": already built (loaded savegame): " .. why .. ": not built again")
			return
		end
		log("ASSET REPLAY " .. uid .. ": asset removal not found (" .. why .. "): not reproduced")
		replayFailed(a, "asset removal not found")
		return
	end
	-- (the removals and the trees added back in ONE build, as on the builder's game: the ids the engine frees and gives are then the same)
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
	if #cons > 0 then sp.constructionsToAdd = cons end
	if #rm > 0 then sp.constructionsToRemove = rm end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = false
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = false
	ctx.gatherFields = false
	ctx.player = api.engine.util.getPlayer()
	-- (a player's build, as the builder's: see G.assetPI)
	local pi = G.assetPI()
	-- (the game's own groups of trees: the factory throws on them every time, after an engine assertion that writes a crash dump
	-- and holds the game a moment - four times in a 4-hour session of 2026-10-29. Straight to the engine's removal then; the mod's
	-- own asset constructions still go to the factory. MPFEVER_ASSETFACTORYFIRST=1: the factory first, as before)
	if #rm > 0 and os.getenv("MPFEVER_ASSETENGINERM") ~= "0" and os.getenv("MPFEVER_ASSETFACTORYFIRST") ~= "1" then
		local gameGroups = 0
		for _, e in ipairs(rm) do
			pcall(function()
				local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
				if not c or tostring(c.fileName) ~= tostring(assetConName()) then gameGroups = gameGroups + 1 end
			end)
		end
		if gameGroups == #rm then
			log("ASSET REPLAY " .. uid .. ": " .. #rm .. " group(s) of the game's trees to remove (" .. table.concat(rm, ","):sub(1, 80) .. "): the engine's removal")
			return G.assetEngineRemoval(a, uid, rm, cons, ctx, strict)
		end
	end
	local okc, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, true, pi) end)
	-- A script proposal with a group of trees in constructionsToRemove is refused by the factory ("Unknown exception", treeerase
	-- 2026-10-25): every group is then removed with the engine's own removal proposal (createProposalRemove, what the game's scripts
	-- use for an industry), one after the other, and the trees it keeps are built after them, all at the build's step.
	-- MPFEVER_ASSETENGINERM=0: as before (not reproduced, see below)
	if (not okc or not cmd) and #rm > 0 and os.getenv("MPFEVER_ASSETENGINERM") ~= "0" then
		log("ASSET REPLAY " .. uid .. ": the factory does not take the tree group(s) " .. table.concat(rm, ","):sub(1, 80) .. " for removal (" .. shortErr(cmd) .. "): the engine's removal instead")
		return G.assetEngineRemoval(a, uid, rm, cons, ctx, strict)
	end
	if not okc or not cmd then
		-- (a group of trees the factory does not take for removal: not reproduced. No native proposal with the removal alone: such
		-- partial native proposals have hung the engine's factory)
		log("ASSET REPLAY " .. uid .. ": command " .. shortErr(cmd) .. (#rm > 0 and (" (with " .. #rm .. " group(s) of trees to remove: " .. table.concat(rm, ",") .. ")") or ""))
		replayFailed(a, "assets not rebuilt")
		return
	end
	toSim("replaying", { nots = true })
	replaySend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		G.assetReplays = (G.assetReplays or 0) + 1
		if G.assetReplays <= 10 or not success or #rm > 0 then
			log("ASSET REPLAY " .. uid .. ": " .. #cons .. " construction(s), " .. #rm .. " removed" .. (#rm > 0 and (" (" .. table.concat(rm, ","):sub(1, 120) .. ")") or "")
				.. (#miss > 0 and (" (not found here: " .. #miss .. ")") or "") .. ": " .. (success and "BUILT" or ("refused " .. why)))
		end
		-- A refused asset replay: the builder's game removed and made entities this one did not, so every later id differs here (0.5.1
		-- took it for a difference of decoration only). MPFEVER_ASSETSTRICT=0: as before
		if not success and strict then
			replayFailed(a, #rm > 0 and "asset removal refused" or "assets refused")
			return
		end
		if not success then return end
		-- (what the engine made of the trees, for H.assetdescribe: an AssetGroup or not)
		local made, isMade = {}, {}
		pcall(function()
			for i = 1, #res.resultEntities do
				local e = res.resultEntities[i]
				if type(e) ~= "number" then e = e[1] end
				if type(e) == "number" then made[#made + 1] = e; isMade[e] = true end
			end
		end)
		G.assetReplayed = G.assetReplayed or {}
		for _, e in ipairs(made) do G.assetReplayed[#G.assetReplayed + 1] = e end
		while #G.assetReplayed > 20 do table.remove(G.assetReplayed, 1) end
		-- (the removed groups must be gone; an id the new trees took again counts as gone)
		if #rm > 0 then
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
				local still, reused = {}, 0
				for _, e in ipairs(rm) do
					if isMade[e] then reused = reused + 1
					elseif R.isTreeGroup(e) then still[#still + 1] = e end
				end
				log("ASSET REPLAY " .. uid .. ": removed tree group(s) gone here: " .. (#still == 0 and "yes" or ("NO, still " .. table.concat(still, ",")))
					.. (reused > 0 and (" (" .. reused .. " id(s) taken again by the new trees)") or ""))
			end }
		end
	end)
end

-- A build of constructions only (a headquarters, a depot on its own...) whose every construction already stands here, the same file
-- at the same place: the savegame this game loaded had it (the host built it during the pause of a resynchronisation, saved it,
-- then shipped it to the game that was loading). Built again, it stood twice on this game only (the collision refused every form
-- but the last), then the companies got other entity ids here and the game stopped at the next load. MPFEVER_ALREADYBUILT=0: as before
-- Only an act that savegame can hold is looked at: one stamped at or before the game time this game loaded (G.loadT, the savegame's
-- time: the host applies an act at its time, so what it saved is stamped no later); a later act cannot be in it and is built as
-- usual. And the constructions are looked for around their place (R.conNear, the octree) instead of among every construction of
-- the map. Before, every construction-only build of another player was checked (a full read of the map's constructions in the
-- interface, about 0.1 s each on a large map), and the same mod construction placed twice at one spot was built once here and
-- twice on the builder's game (a resynchronisation). MPFEVER_ALREADYBUILT=all: as before (every act, the whole map)
-- The game time stands still in the pause after a load, so a build made in it is stamped the load's time too: a build whose
-- builder had loaded the same resynchronisation as this game (a.lt, G.loadId) was made after its savegame was taken and is not
-- looked at either. MPFEVER_ALREADYBUILT=time: the game time only
G.alreadyBuilt = function(a)
	local sw = os.getenv("MPFEVER_ALREADYBUILT")
	if a.fn ~= "makeWorldBuildProposalCmd" or sw == "0" then return false end
	if sw ~= "all" and not (type(G.loadT) == "number" and type(a.at) == "number" and a.at <= G.loadT) then return false end
	if sw ~= "all" and sw ~= "time" and a.lt ~= nil and a.lt == G.loadId then return false end
	local m = type(a.args) == "table" and a.args[1]
	if type(m) ~= "table" or #(m.toAdd or {}) == 0 or #(m.toRemove or {}) > 0 then return false end
	local st = m.proposal or {}
	if #(st.addedSegments or {}) + #(st.removedSegments or {}) + #(st.addedNodes or {}) + #(st.removedNodes or {}) > 0 then return false end
	for _, ce in ipairs(m.toAdd) do
		local t = ce.transf
		if type(t) ~= "table" or type(t[13]) ~= "number" then return false end
		local p = { x = t[13], y = t[14], z = t[15] }
		local e, listed = nil, false
		if sw ~= "all" then e, listed = R.conNear(ce.fileName, p, 0.1) end
		-- (the octree listed no construction around the place: looked for the old way, once in a while only, see above)
		if not e and not listed then e = R.resolve({ k = "con", id = -1, f = ce.fileName, p = p }) end
		local c = type(e) == "number" and api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		local q = c and R.matPos(c.transf)
		if not q or (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 + (q.z - p.z) ^ 2 > 0.01 then return false end
	end
	return true
end

-- A replay due now waits while the engine may still be making a step: "now" is this interface's copy of the game time, and a
-- build sent while the engine finished one more step landed a step later on that game only, with no "LATE" (a replay of the
-- friends' session, 2026-10-26: theop#1:41 built at 105717600 on one game and 105717400 on the other, both games drifting from
-- then on; "REPLAY SEND ... still=false stepTarget=nil"). It goes once the engine is proven still, or at once when the exact
-- steps asked for end at this time (the engine applies the build after them); after 3 s it goes anyway (logged). The game is
-- held where it is meanwhile (nativeHoldAt). MPFEVER_SENDSTILL=0: as before.
G.sendStill = os.getenv("MPFEVER_SENDSTILL") ~= "0"
G.sendStillWait = function(a, now)
	if not G.sendStill then return false end
	if G.simStill() or (G.stepTarget ~= nil and G.stepTarget == now) or G.nstopWillStand(a.at) then a.stillWait = nil; return false end
	a.stillWait = a.stillWait or G.frames
	if G.frames - a.stillWait > 180 then
		log("NATIVE REPLAY " .. tostring(a.uid) .. ": the engine not proven still in 3 s, sent anyway (t=" .. tostring(now) .. ") [frame " .. G.frames .. "]")
		a.stillWait = nil
		return false
	end
	return true
end

-- Builds of several players stamped with the same step: every game applies them in one order, by player (the name), whatever
-- order they arrive in. A game applied its own build at once and the other's when it came, the other game the other way round:
-- two streets of one junction upgraded at once got other ids on each game and the towns went apart (the restale scenario,
-- 2026-10-26). A build at time t waits here while a build of a player ranked before its own is announced for t and not applied
-- yet (its announcement holds every game at t; a build cancelled or never sent stops holding as before). MPFEVER_SAMESTEP=0: as
-- before.
G.sameStepWait = function(at, origin)
	if os.getenv("MPFEVER_SAMESTEP") == "0" then return false end
	-- (in a pause every build has the pause's time: the host's turns give their order, see G.pt)
	if G.session.pauseAt ~= nil and at >= G.session.pauseAt then return false end
	for _, w in ipairs(G.natWait) do
		if w.at == at and w.origin ~= origin and tostring(w.origin) < tostring(origin) then return true end
	end
	return false
end

local function runNativeReplays()
	pumpTerrain()
	pumpCompanies()
	if #G.nativeQueue == 0 then return end
	local now = gameTime()
	table.sort(G.nativeQueue, before)
	local keep = {}
	-- a native replay still in the engine's hands (its commands answer in callbacks, a form or a step after the other): the
	-- next build waits for it, as it may refer to what it makes (four quick edits of one station: the second was translated
	-- before the first was built, issue #19). Not forever: an engine that never answers lets the queue go after 20 s.
	local function replayBusy() return (((G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0)) and G.frames - (G.replaySince or 0) < 1200) or G.stopsAfterBusy ~= nil end
	for _, a in ipairs(G.nativeQueue) do
		-- (a paused build: in its turn, see G.pt)
		local seq = a.paused and (a.pseq or (a.natId ~= nil and G.pt.of[G.ptKey(a.origin, a.natId)])) or nil
		-- (a player's announcement in a pause: its turn from the host, see G.joinTurn)
		local jt = G.joinTurn(a)
		if jt then seq = jt end
		-- (a construction edited from a window in a pause: its turn among the paused actions, see G.actTurn)
		local et = a.uiEdit and G.actTurn(a) or nil
		if et then seq = et end
		-- (a native build of the engine's own kind may go as the simulation is about to stand at its time, see G.nstopWillStand)
		local due = a.at <= now or (a.native and not a.paused and a.fn ~= "terrainEdit" and a.fn ~= "mpfCoJoin" and a.fn ~= "assetBuild" and G.nstopWillStand(a.at))
		if due and ((a.fn == "terrainEdit" and G.terrainBusy) or (a.fn == "mpfCoJoin" and (G.coBusy or jt == false or G.frames - (a.recvFrame or 0) < K.JOIN_GATHER))
			or (a.fn ~= "terrainEdit" and a.fn ~= "mpfCoJoin" and replayBusy()) or et == false) then
			keep[#keep + 1] = a      -- the previous one is still being handed to the engine (or its turn has not been given yet)
		elseif due and seq and not G.ptMayGo(seq) then
			keep[#keep + 1] = a      -- a paused build whose turn has not come here yet
		elseif due and not seq and a.native and G.sameStepWait(a.at, a.origin) then
			keep[#keep + 1] = a      -- a build of a player ranked before this one, at this same step, comes first
		elseif due and a.fn ~= "mpfCoJoin" and G.sendStillWait(a, now) then
			keep[#keep + 1] = a      -- the engine may still be making a step (see G.sendStillWait)
		elseif due then
			G.replayAt = a.at
			if a.at > now then log("NATIVE REPLAY " .. tostring(a.uid) .. ": sent as the simulation comes to t=" .. a.at .. " (this interface at " .. now .. ") [frame " .. G.frames .. "]") end
			if seq then G.ptDone(seq); log("NATIVE REPLAY " .. tostring(a.uid) .. ": paused build, turn " .. seq) end
			if a.at < now then
				log("LATE native build " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)")
				G.aheadLocked = true
			end
			nativeArrived(a)
			-- (0.6: to the game options' modules that keep a copy of the players' builds, before the replay translates its references,
			-- see G.featNativeAct; nothing while no option is on)
			if G.featOn then pcall(G.featNativeAct, a) end
			local okr, errr
			local skip = G.lateSkip(a, now)
			if skip then okr = true
			elseif a.fn == "terrainEdit" then okr, errr = pcall(withActor, PL(a), replayTerrain, a)
			elseif a.fn == "assetBuild" then okr, errr = pcall(withActor, PL(a), replayAssets, a)
			elseif a.fn == "mpfCoJoin" then
				G.coBusy = { a = a, phase = "apply", frame = G.frames }; okr = true
				-- (test: MPFEVER_JOINGAPTEST=1 waits half a second here, the simulation running meanwhile if nothing holds it: see
				-- G.joinHoldDue)
				if os.getenv("MPFEVER_JOINGAPTEST") == "1" then local t0 = os.clock(); while os.clock() - t0 < 0.5 do end end
			elseif select(2, pcall(G.alreadyBuilt, a)) == true then
				log("NATIVE REPLAY " .. tostring(a.uid) .. ": its construction(s) already stand here (in the loaded savegame): not built again")
				okr = true
			else
				if type(a.cost) == "number" then toSim("replay_cost", { uid = a.uid, cost = a.cost, co = a.co, kind = G.costKind(a) }) end
				-- (its builder's town statistics, compared with this replay's: see SIM.townStats; MPFEVER_ALIGNCHECK=0: off. The mark of
				-- the announcement, a.tsTok, goes with every "replaying" event of this replay; none without one)
				a.tsTok = nil
				if type(a.ts) == "table" and os.getenv("MPFEVER_ALIGNCHECK") ~= "0" then
					local okT, errT = pcall(G.townExpect, a)
					if not okT then log("town stats of " .. tostring(a.uid) .. " not announced: " .. tostring(errT)) end
				end
				G.refund = a.refund
				-- (diagnostic: how this game stands when the replay goes to the engine; two replays of 2026-10-25 were sent at their
				-- time and built two steps later, with no "LATE" here)
				pcall(function()
					log("REPLAY SEND " .. tostring(a.uid) .. " at=" .. tostring(a.at) .. " now=" .. tostring(now) .. " speed=" .. tostring(gameSpeed())
						.. " still=" .. tostring(G.simStill()) .. " hold=" .. tostring(G.holdAt) .. " stepTarget=" .. tostring(G.stepTarget)
						.. " wantSteps=" .. tostring(G.wantSteps) .. " barrier=" .. tostring(G.lastBarrier) .. " replayOut=" .. tostring(G.replayOut)
						.. " [frame " .. G.frames .. "]")
				end)
				okr, errr = pcall(withActor, PL(a), replayNative, a, 1)
				G.refund = nil
			end
			-- (what this game built, at the step it has on its builder's game, see G.lateSkip: a late one keeps its place among the
			-- builds of the same step and after, as harry:110 and 111 of issue #96, both of one step)
			if not skip then G.builtAt = math.max(G.builtAt or -1, a.at) end
			if not okr then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " failed: " .. tostring(errr))
				-- (the engine threw: this game did not build what the others did, issue #49)
				replayFailed(a, "error: " .. shortErr(errr))
			end
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
	-- (a checkpoint of a pause the host took at another turn than this game: its money is another moment's, a correction from it
	-- was undone at the next checkpoint, and the money kept moving in a long paused building session. MPFEVER_TURNCHECK=0: as before)
	if own and type(p.ptd) == "number" and type(own.ptd) == "number" and p.ptd ~= own.ptd and os.getenv("MPFEVER_TURNCHECK") ~= "0" then
		if (G.authTurnLogged or 0) < 20 then
			G.authTurnLogged = (G.authTurnLogged or 0) + 1
			log("host authority: checkpoint " .. p.n .. " taken at turn " .. tostring(p.ptd) .. " on the host, " .. tostring(own.ptd) .. " here: no correction")
		end
		return
	end
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
	-- Not while another player's build is being replayed here: a session of the friends saved in the very frame a replay was
	-- applied, and both games stopped on an engine assertion 40 steps after loading that save. The save waits until the replays
	-- due now are handed to the engine and answered (at most 10 s). MPFEVER_SAVEQUIET=0: at once, as before.
	local start = G.frames
	local function busy()
		if os.getenv("MPFEVER_SAVEQUIET") == "0" then return false end
		if (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or G.terrainBusy then return true end
		local now = gameTime()
		for _, a in ipairs(G.nativeQueue or {}) do if a.at <= now then return true end end
		return false
	end
	local function save()
		if busy() and G.frames - start < 600 then G.waits[#G.waits + 1] = { at = G.frames + 3, fn = save }; return end
		if G.frames > start then log("resynchronisation: the save waited " .. (G.frames - start) .. " frames for the replays under way" .. (busy() and " (still busy: saved anyway)" or "")) end
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
	save()
end

-- autotest "toshared": back to the game's main menu (the pause menu's "Return to Main Menu"), where mpfever_auto.lua loads the
-- test's savegame again in this same run of the game (auto_reload.txt)
H.tomenu = function(from, p)
	if os.getenv("MPFEVER_SAVE") == nil then return end
	C.appendFile(C.DIR .. BS .. "auto_reload.txt", tostring(p.seq or 1))
	log("AUTOTEST tomenu: back to the main menu, the test savegame loaded again from there")
	G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
		local ok, err = pcall(app.stopGame)
		if not ok then log("AUTOTEST tomenu: " .. tostring(err)) end
	end }
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
	-- the companies' entity ids of the game unloaded now mean nothing in the one loaded: the native module forgets them until
	-- this game says them again. Kept, the interface read the player of the old id at once, a group of trees in the host's
	-- game (the companies had other ids here), and the engine stopped the game. The native module reads its control file when a
	-- command is added: the event below makes it read it now. MPFEVER_LOADKEEPCO=1: as before
	if os.getenv("MPFEVER_LOADKEEPCO") ~= "1" then
		K.coCtlSeq = (K.coCtlSeq or 0) + 1
		local okT, tm = pcall(os.time)
		local tok = ((okT and tm or 0) % 1000000) * 100 + K.coCtlSeq % 100
		nativeCtl("setlocal 0 " .. tok)
		nativeCtl("setothers " .. tok)
		pcall(toSim, "native_ctl", {})
	end
	-- (with this player's personal mods: see C.loadWithPlan)
	C.loadWithPlan(id, log, function(fn) G.waits[#G.waits + 1] = { at = G.frames + 1, fn = fn } end)
end

-- Census (diagnostic, MPFEVER_CENSUS set): every component of every entity, written as text (census_<tag>.txt in the
-- session folder): "TYPE <tab> entity <tab> hash <tab> text". Two games' files compared entity by entity show every value
-- that differs between them (tools/census_diff.py).
local CENSUS_TYPES = { "AIRCRAFT", "ANIMAL", "ASSET_GROUP", "BASE_EDGE", "BASE_EDGE_STREET", "BASE_NODE", "BASE_PARALLEL_STRIP",
	"CUSTOM_STATE", "EMISSION_EMITTER", "FIELD", "GAME_TIME", "GAME_SPEED", "NAME", "LINE", "LOG_BOOK",
	"MOVE_PATH", "MOVE_PATH_AIRCRAFT", "STATION", "STATION_GROUP", "SIM_PERSON", "SIM_PERSON_AT_TERMINAL",
	"SIM_PERSON_AT_VEHICLE", "SIM_CARGO", "SIM_ENTITY_AT_BUILDING", "SIM_ENTITY_AT_VEHICLE", "SIM_ENTITY_AT_TERMINAL",
	"SIM_ENTITY_IDLE", "SIM_ENTITY_MOVING", "SIGNAL_LIST", "TOWN", "INDUSTRY", "STOCK_LIST", "TOWN_BUILDING", "TRANSPORT_VEHICLE",
	"TRAIN", "CARRIAGE", "CARRIAGE_LIST", "VEHICLE_DEPOT", "COLOR", "CONSTRUCTION", "SUBCONSTRUCTION",
	"PERSON_CAPACITY", "PLAYER_OWNED", "ACCOUNT", "GAME_SCRIPT", "WAREHOUSE", "TRANSPORT_NETWORK", "MAINTENANCE_COST",
	"RAILROAD_CROSSING", "PLAYER", "WORLD", "BRIDGE", "BASE_NODE_CONFIG", "LAND_VEHICLE", "BASE_NODE_TRAFFIC_LIGHT", "EDGE_OBJECT",
	"EMISSION_GRID", "SHIP", "TICK_EPOCH" }
-- (TICK_EPOCH: the step each street and track segment was added at, which the towns' parcels compare; not in the API's
-- documentation, read when the game has it)
-- (left out: what only the renderer uses - MODEL_INSTANCE_LIST, MODEL_PERSON, BOUNDING_VOLUME - and the terrain, compared by
-- its own signature)

local function census(tag)
	local c0 = os.clock()
	local f = C.IO.open(C.DIR .. BS .. "census_" .. tostring(tag) .. ".txt", "wb")
	if not f then return end
	local total, only = 0, os.getenv("MPFEVER_CENSUS")
	-- the entities to look at: those the engine lists per component (not every type can be listed), the street graph,
	-- the lines, the edges' objects, the players and the world
	local found, universe, useen = {}, {}, {}
	local function add(e) if type(e) == "number" and e >= 0 and not useen[e] then useen[e] = true; universe[#universe + 1] = e end end
	for _, name in ipairs(CENSUS_TYPES) do
		local list = {}
		pcall(function() api.engine.forEachEntityWithComponent(function(e) list[#list + 1] = e end, api.type.ComponentType[name]) end)
		found[name] = list
		-- (the trees and the emitters - over 100 000 - hold nothing else)
		if name ~= "ASSET_GROUP" and name ~= "EMISSION_EMITTER" then for _, e in ipairs(list) do add(e) end end
	end
	-- the entity groups a type can be on (asking an entity for a component it has not is slow: only plausible ones are asked)
	local G_ = { edges = R.allEdges(), nodes = R.allNodes(), lines = R.entitiesWith("LINE"), objs = {}, players = {}, world = {},
		vehicles = found.TRANSPORT_VEHICLE or {}, persons = found.SIM_PERSON or {}, cons = {} }
	for _, e in ipairs(G_.edges) do
		add(e)
		pcall(function()
			local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			for _, o in ipairs(be and be.objects or {}) do add(o[1]); G_.objs[#G_.objs + 1] = o[1] end
		end)
	end
	for _, n in ipairs(G_.nodes) do add(n) end
	for _, l in ipairs(G_.lines) do add(l) end
	pcall(function() local w = api.engine.util.getWorld(); add(w); G_.world[1] = w end)
	local pseen = {}
	local function addPlayer(p) if type(p) == "number" and p >= 0 and not pseen[p] then pseen[p] = true; add(p); G_.players[#G_.players + 1] = p end end
	pcall(function() addPlayer(api.engine.util.getPlayer()) end)
	for _, e in ipairs(found.PLAYER_OWNED or {}) do pcall(function() addPlayer(api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED).player) end) end
	for _, k in ipairs({ "CONSTRUCTION", "TOWN_BUILDING", "INDUSTRY", "STATION", "STATION_GROUP", "VEHICLE_DEPOT", "TOWN" }) do
		for _, e in ipairs(found[k] or {}) do G_.cons[#G_.cons + 1] = e end
	end
	table.sort(universe)
	-- (MPFEVER_CENSUS=IDS: only which entities each listable type has, fast: two games' entity sets compared)
	if only == "IDS" then
		for _, name in ipairs(CENSUS_TYPES) do
			local list = found[name] or {}
			table.sort(list)
			for _, e in ipairs(list) do f:write(name, "\t", tostring(e), "\t0\t-\n") end
		end
		f:close()
		log(string.format("census %s: entity ids of %d entities in %.1f s", tostring(tag), #universe, os.clock() - c0))
		return
	end
	local WHERE = {
		BASE_EDGE = { "edges" }, BASE_EDGE_STREET = { "edges" }, BRIDGE = { "edges" }, BASE_PARALLEL_STRIP = { "edges" }, SIGNAL_LIST = { "edges" },
		TICK_EPOCH = { "edges" }, BASE_NODE = { "nodes" }, BASE_NODE_CONFIG = { "nodes" }, BASE_NODE_TRAFFIC_LIGHT = { "nodes" }, RAILROAD_CROSSING = { "nodes" },
		TRANSPORT_NETWORK = { "edges", "nodes", "cons", "objs" }, LINE = { "lines" }, EDGE_OBJECT = { "objs" },
		NAME = { "lines", "vehicles", "cons", "players", "persons", "objs" }, COLOR = { "lines", "vehicles", "cons", "players" },
		LOG_BOOK = { "lines", "vehicles", "cons", "players", "persons" }, MOVE_PATH = { "vehicles", "persons" }, LAND_VEHICLE = { "vehicles", "persons" },
		MOVE_PATH_AIRCRAFT = { "vehicles" }, AIRCRAFT = { "vehicles" }, SHIP = { "vehicles" }, TRAIN = { "vehicles" }, CARRIAGE_LIST = { "vehicles" },
		SIM_PERSON_AT_TERMINAL = { "persons" }, SIM_PERSON_AT_VEHICLE = { "persons" }, SIM_ENTITY_AT_BUILDING = { "persons" },
		SIM_ENTITY_AT_VEHICLE = { "persons" }, SIM_ENTITY_AT_TERMINAL = { "persons" }, SIM_ENTITY_IDLE = { "persons" }, SIM_ENTITY_MOVING = { "persons" },
		SIM_CARGO = { "persons" }, STOCK_LIST = { "cons" }, PERSON_CAPACITY = { "cons" }, SUBCONSTRUCTION = { "cons" }, CUSTOM_STATE = { "cons" },
		FIELD = { "cons" }, WAREHOUSE = { "cons" }, MAINTENANCE_COST = { "cons", "vehicles", "edges" }, ACCOUNT = { "players", "cons", "lines", "vehicles" },
		PLAYER = { "players" }, WORLD = { "world" }, GAME_TIME = { "world" }, GAME_SPEED = { "world" }, EMISSION_GRID = { "world" }, GAME_SCRIPT = { "world" },
	}
	SIM.censusKnown = SIM.censusKnown or {}
	for _, name in ipairs(CENSUS_TYPES) do
		if only == "1" or only == "all" or only:find(name, 1, true) then
			local tType = os.clock()
			local ct = api.type.ComponentType[name]
			local list = found[name]
			if #list == 0 then
				local seen = {}
				local function try(e)
					if seen[e] then return end
					seen[e] = true
					local okc, comp = pcall(api.engine.getComponent, e, ct)
					if okc and comp ~= nil then list[#list + 1] = e end
				end
				local where = WHERE[name]
				if where then
					for _, g in ipairs(where) do for _, e in ipairs(G_[g] or {}) do try(e) end end
				else
					-- no known group: every entity the first time, then the entities that had it and the new ones
					local known = SIM.censusKnown[name]
					if not known then
						for _, e in ipairs(universe) do try(e) end
					else
						for e in pairs(known.has) do try(e) end
						for _, e in ipairs(universe) do if not known.scanned[e] then try(e) end end
					end
					local has, scanned = {}, {}
					for _, e in ipairs(list) do has[e] = true end
					for _, e in ipairs(universe) do scanned[e] = true end
					SIM.censusKnown[name] = { has = has, scanned = scanned }
				end
			end
			table.sort(list)
			local n = 0
			for _, e in ipairs(list) do
				local okc, comp = pcall(api.engine.getComponent, e, ct)
				local txt
				if okc and name == "TRANSPORT_NETWORK" then
					-- (its full text takes a quarter of a second: the lanes' connections and current speeds only)
					local okt, t = pcall(function()
						local parts = { "nodes = " .. #comp.nodes, "edges = " .. #comp.edges }
						for i = 1, #comp.edges do
							local ed = comp.edges[i]
							local c = ed.conns
							parts[#parts + 1] = string.format("e%d = %d.%d-%d.%d %.6g", i, c[1].entity, c[1].index, c[2].entity, c[2].index, ed.curSpeed)
						end
						return table.concat(parts, ", ")
					end)
					txt = okt and t or ("ERR " .. tostring(t))
				else
					txt = okc and C.dump(comp) or ("ERR " .. tostring(comp))
				end
				txt = txt:gsub("[%c]", " ")
				f:write(name, "\t", tostring(e), "\t", tostring(C.hashStr(0, txt)), "\t", (#txt > 2000 and name ~= "GAME_TIME") and txt:sub(1, 2000) or txt, "\n")
				n = n + 1
			end
			f:write("#COUNT\t", name, "\t", tostring(n), "\t", string.format("%.1f", os.clock() - tType), "\n")
			total = total + n
		end
	end
	f:close()
	log(string.format("census %s: %d components of %d entities in %.1f s", tostring(tag), total, #universe, os.clock() - c0))
end

H.census_now = function(from, p)
	if os.getenv("MPFEVER_CENSUS") then
		local ok, err = pcall(census, tostring(p.tag) .. "_t" .. tostring(gameTime()))
		if not ok then log("census failed: " .. tostring(err)) end
	end
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
			local parts = simHash(nil, G.co, nil, G.simBuildIds, t)
			parts.reached = (t >= target)
			send("det_hash", { round = round, steps = steps, parts = parts })
			-- (MPFEVER_CENSUS_FROM=n: no census before round n)
			if os.getenv("MPFEVER_CENSUS") and round >= (tonumber(os.getenv("MPFEVER_CENSUS_FROM") or "0") or 0) then
				pcall(census, "r" .. tostring(round) .. "_t" .. tostring(t))
			end
		else
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = poll }
		end
	end
	G.waits[#G.waits + 1] = { at = G.frames + 10, fn = poll }
end

-- A player's build during a resynchronisation is refused by its own game: the launcher keeps none (the others never get it),
-- and on a game that has already loaded the host's savegame nothing would undo it (issue #81: a station that stayed on one game
-- only, a resync right after). The player is told in the chat.
G.resyncRefuse = function(what)
	-- (a player between two companies, after leaving one or a bankruptcy: nothing of it is applied until its new company is
	-- there, a few seconds; see coGui)
	if G.coNone and G.cmode == "separate" and G.session.started then
		if G.frames - (G.coNoneToldAt or -1000) > 300 then G.coNoneToldAt = G.frames; log("companies: " .. tostring(what) .. " refused: this player has no company yet") end
		return true
	end
	if not G.session.resync then return false end
	log("resynchronisation under way: " .. tostring(what) .. " refused here")
	if G.frames - (G.resyncToldAt or -1000) > 300 then
		G.resyncToldAt = G.frames
		pcall(send, "notice", { what = "resyncbuild" })
	end
	return true
end

-- an MPFever event sent by this game itself (the host closing an auction's lot, its rules), stamped and shipped as the
-- interface's events are: applied by every game at the same step (see mpfever_eco.lua)
G.coEvent = function(name, param)
	if G.session.resync then log("companies: event " .. name .. " not sent during the resynchronisation"); return false end
	local now = gameTime()
	G.oseq = G.oseq + 1
	local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
	local a = { fn = "makeScriptingSendEventCmd", args = { "mpfever", "mpfever", name, param or {} }, origin = G.me, oseq = G.oseq, co = G.myCo,
		uid = G.me .. ":" .. G.oseq, at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil }
	send("act", a)
	queueLocal(a)
	log("companies: event " .. name .. " sent")
end

-- commands held by the UI hook: stamp them (two steps ahead, or at the pause point) and ship them
local function stampHeld()
	for _, line in ipairs(readLines("ui.log", "uiOff")) do
		local kind, _, payload = parseLine(line)
		local p = payload and C.deser(payload)
		if p and kind == "act_req" and G.resyncRefuse(p.fn) then
			-- (refused: never applied here, never sent)
		elseif p and kind == "act_req" and G.featOn and G.featAllow and G.featRefuse(p) then
			-- (0.6, refused by a game option: never applied here, never sent; the window's command gets its refusal, see G.featRefuse)
		elseif p and kind == "act_req" then
			local now = gameTime()
			G.oseq = G.oseq + 1
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
			local a = { tok = p.tok, id = p.id, fn = p.fn, args = p.args, origin = G.me, oseq = G.oseq, co = tonumber(p.co) or G.myCo,
				uid = G.me .. ":" .. G.oseq, at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil }
			-- (the edit of a construction from a window: replayed here too, as the others' builds are, see G.uiEdit)
			local edit = G.uiEdit(a)
			if edit then
				a.native, a.uiEdit = true, true
				log("action " .. a.uid .. ": the edit of a construction from a window, replayed by the engine's replacement on every game")
			end
			send("act", a)
			if edit then
				a.recvFrame = G.frames
				if a.paused and G.actTurns then G.ptIssue(a.origin, G.actTurnId(a)) end
				G.nativeQueue[#G.nativeQueue + 1] = a
			else
				queueLocal(a)
				if G.buildLead then G.leadNoteDue(a) end
			end
		elseif p and kind == "speed_req" and G.featOn and G.featAllow
			and G.featRefuse({ fn = "makeGameSetSpeedCmd", args = { n = 1, p.speed }, speed = true }) then
			-- (0.6, a speed or a pause refused by a game option: never asked of MPFever.exe; the buttons show the session's speed
			-- again after 2 s, see U.shownSpeed)
		elseif p and (kind == "speed_req" or kind == "act_fail" or kind == "save_done") then
			send(kind, p)
		elseif p and kind == "terrain_tool" then
			terrainLead("tool " .. tostring(p.tool))
		elseif p and kind == "ping_arm" then
			pcall(G.pingArm, p)
		elseif p and kind == "feat_req" and G.featOn then
			-- (0.6) a request of the MPFever window to a game option's module of this game (u.request, see G.featRequest)
			local okF, errF = pcall(G.featRequest, p)
			if not okF then log("options: request failed: " .. tostring(errF)) end
		end
	end
	-- the host's automatic mod commands, written by its simulation (see DET.installModCmds): shipped like a player's. Their
	-- line goes to the other games as a player's command names it: a line made during the session by its creation key (the
	-- ids of new entities differ between games; the command waits up to 30 frames for the simulation to bind it), a line of
	-- the savegame by its id, the same everywhere. (A wrong id is skipped by the other games, see executeActionOnce)
	G.modWait = G.modWait or {}
	for _, line in ipairs(readLines("sim_mods.log", "modOff")) do
		local kind, _, payload = parseLine(line)
		local p = payload and C.deser(payload)
		if p and kind == "mod_req" and C.ROLE == "host" then p.frame = G.frames; G.modWait[#G.modWait + 1] = p end
	end
	local waiting = G.modWait
	G.modWait = {}
	for _, p in ipairs(waiting) do
		local e = type(p.args) == "table" and p.args[1] or nil
		if type(e) == "number" and G.rev[e] == nil and G.frames - p.frame < 30 then
			G.modWait[#G.modWait + 1] = p
		elseif G.session.resync then
			-- (during a resynchronisation the launcher keeps no command: applied here only, the games would differ)
			log("resynchronisation under way: mod command " .. tostring(p.fn) .. " of " .. tostring(p.mod) .. " dropped")
		else
			pcall(R.translateOut, p.fn, p.args, G.rev)
			local now = gameTime()
			G.oseq = G.oseq + 1
			G.modSeq = (G.modSeq or 0) + 1
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
			local a = { tok = "mod", id = G.modSeq, fn = p.fn, args = p.args, origin = G.me, oseq = G.oseq, co = G.myCo,
				uid = G.me .. ":" .. G.oseq, at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil, mod = p.mod }
			send("act", a)
			queueLocal(a)
			if G.modSeq <= 20 or G.modSeq % 100 == 0 then
				log("mod command #" .. G.modSeq .. " " .. tostring(p.fn) .. " of " .. tostring(p.mod) .. " on " .. tostring(e)
					.. (G.rev[e] and (" (" .. tostring(G.rev[e]) .. ")") or "") .. " (sent at t=" .. tostring(p.t) .. ") stamped " .. a.uid .. " for t=" .. tostring(a.at))
			end
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
	-- (a terrain tool edits the ground at once, it cannot be refused: made during a resynchronisation on a game that has already
	-- loaded the host's savegame, nothing undoes it there and the launcher keeps none: the host's game is reloaded once more.
	-- On a game still in the previous world its load undoes it.)
	if G.session.resync and G.resyncNewWorld then return fail("made during the resynchronisation") end
	if G.session.resync then log("terrain edit made during the resynchronisation: undone by the coming load"); return "failed" end
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
	-- (0.6: to the game options' modules that keep a copy of the players' builds, see G.featNativeAct)
	if G.featOn then pcall(G.featNativeAct, a) end
	toSim("terrain_note", { v = tonumber(b.fnv:sub(-8), 16) or 0, at = o.at })
	G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
		log("terrain edit " .. a.uid .. ": ground here now sum " .. tostring(G.terrainSum(d.x0, d.y0, d.w, d.h)))
	end }
	log("terrain edit shipped " .. a.uid .. " (" .. d.w .. "x" .. d.h .. " cells, " .. #txt .. " bytes as text, made here at t=" .. tostring(o.at) .. ") [frame " .. G.frames .. "]")
	return "sent"
end

local function shipNativeBuilds(st)
	G.outFirstSeen = G.outFirstSeen or {}
	-- (a capture held back here is not shipped yet: see expireShipIds)
	G.outWaiting = false
	for _, o in ipairs(st.out or {}) do
		if o.n > G.outSent and o.terrain then
			G.outFirstSeen[o.n] = G.outFirstSeen[o.n] or G.frames
			local okT, r = pcall(shipTerrain, o)
			if not okT then log("terrain shipping failed: " .. tostring(r)); r = "failed" end
			if r == "wait" then G.outWaiting = true; return end
			G.outSent = o.n
		elseif o.n > G.outSent then
			G.outFirstSeen[o.n] = G.outFirstSeen[o.n] or G.frames
			if o.ready == false and G.frames - G.outFirstSeen[o.n] < 30 then G.outWaiting = true; return end
			G.outSent = o.n
			G.oseq = G.oseq + 1
			if needsEnrich(o.args and o.args[1]) then
				local oke, erre = pcall(enrichEdgeObjects, o.args and o.args[1])
				if not oke then log("edge object enrichment failed: " .. tostring(erre)) end
			end
			local a = { fn = o.fn, args = o.args, at = o.at, origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
				native = true, paused = o.paused, co = G.myCo, cost = o.cost, ts = o.ts, lt = G.loadId }
			if G.natShipIds and #G.natShipIds > 0 then
				-- the released build that was built at this time; the ones released before it and not shipped were refused
				-- (BUILDLEAD: a build released at once lands at some step at or after the time it was released at, the first of
				-- those released and not shipped is the one, builds are applied in the order they were released in)
				local k = nil
				for i, e in ipairs(G.natShipIds) do
					if e.at == o.at or (e.lead and e.at <= o.at) then k = i; break end
				end
				k = k or 1
				local ek = G.natShipIds[k]
				if ek.at ~= o.at and not (ek.lead and ek.at <= o.at) then
					log("WARNING: a native build landed at t=" .. tostring(o.at) .. " instead of t=" .. tostring(G.natShipIds[k].at) .. " (desync risk)")
				end
				for i = 1, k - 1 do cancelNativeBuild(G.natShipIds[i], "refused before a later build") end
				a.natId = G.natShipIds[k].id
				if a.paused then a.pseq = G.pt.of[G.ptKey(G.me, a.natId)] end
				if ek.lead then
					a.lead = true
					G.leadStats.shipped = G.leadStats.shipped + 1
					log("BUILDLEAD native build " .. tostring(ek.id) .. " landed at t=" .. tostring(o.at) .. " (released at once at t=" .. tostring(ek.at) .. ", "
						.. ((o.at - ek.at) / STEP) .. " step(s) later; this game is at t=" .. tostring(G.clockSeen) .. ", " .. (G.frames - ek.frame) .. " frames after the release)")
				end
			if G.natCtx and G.natCtx[a.natId] then a.ctx = G.natCtx[a.natId]; G.natCtx[a.natId] = nil end
			if G.natRefund and G.natRefund[a.natId] then a.refund = G.natRefund[a.natId]; G.natRefund[a.natId] = nil end
			-- (a build of a game company, see mpfever_ai.lua: the other games build it for that company)
			if G.aiNatCo and G.aiNatCo[a.natId] then a.co = G.aiNatCo[a.natId]; G.aiNatCo[a.natId] = nil end
				local rest = {}
				for i = k + 1, #G.natShipIds do rest[#rest + 1] = G.natShipIds[i] end
				G.natShipIds = rest
			end
			send("act", a)
			-- (0.6: to the game options' modules that keep a copy of the players' builds, see G.featNativeAct)
			if G.featOn then pcall(G.featNativeAct, a) end
			G.builtAt = math.max(G.builtAt or -1, o.at)
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
		-- (an action waiting for its turn holds the game at its time too, as a paused build does: the session may be resumed meanwhile)
		if (a.at > now or (a.at == now and G.actTurn(a) ~= nil)) and (minAt == nil or a.at < minAt) then minAt = a.at end
	end
	if minAt and G.holdAt ~= minAt then
		G.holdAt = minAt
		toSim("pause_at", { at = minAt })
	end
	-- (or standing at the native stop point: the game stands there at its speed, see pacing. Applied at speed 0 only, the paused
	-- actions waited for ever there: a session with companies, whose host's rules go in their turn at the start, never ran, 0.5.10)
	if gameSpeed() ~= 0 and not (G.nstopOk() and G.lastStopAt and now >= G.lastStopAt) then return end
	local keep = {}
	table.sort(G.pendingPaused, before)
	-- An action that creates something (a vehicle, a line) is known to the later actions only once the engine has answered,
	-- a frame later: until then the actions after it wait, in their order. A vehicle bought and assigned to a line at once in a
	-- pause had its assignment skipped on the other games, which then all reloaded (issue #36). (At most 600 frames.)
	local creating = G.pausedCreating ~= nil and G.frames - G.pausedCreating.frame < 600
	if not creating then G.pausedCreating = nil end
	-- A checkpoint waits while a player's join is under way here (G.coBusy) or due and still gathering in the native queue: its
	-- hash reads this game's copy of the registry, which shows the join only once the simulation applied it and the interface
	-- read it back. The first check after a resynchronisation was taken on one game before its registry showed the two joins and
	-- on the other after: a false "companies" difference. The actions after it wait with it (they would change what it reads).
	-- MPFEVER_COHASHWAIT=0: as before.
	local joining = false
	if os.getenv("MPFEVER_COHASHWAIT") ~= "0" then
		joining = G.coBusy ~= nil
		for _, q in ipairs(G.nativeQueue) do if q.fn == "mpfCoJoin" and q.at <= now then joining = true end end
	end
	for _, a in ipairs(G.pendingPaused) do
		if a.kind == "hash" and joining and a.at <= now and not creating then
			creating = true
			if G.coHashWaitLogged ~= a.n then G.coHashWaitLogged = a.n; log("checkpoint " .. tostring(a.n) .. " waits for a company join under way here") end
		end
		-- (in its turn among the paused builds and actions, see G.actTurn; not while a build before it is still being handed to the
		-- engine here, a stop's replay is several commands)
		local turn = G.actTurn(a)
		local busy = turn and ((G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or G.stopsAfterBusy ~= nil)
		if a.at <= now and not creating and turn ~= false and (turn == nil or (not busy and G.ptMayGo(turn))) then
			if turn then G.ptDone(turn) end
			if a.at < now then log("paused action " .. tostring(a.uid) .. " for t=" .. tostring(a.at) .. " applied at " .. now .. " (desync risk)") end
			if a.kind == "hash" then
				local okA, auth = pcall(authValues, G.co)
				-- (the turns of the pause applied here: a host's value taken at another turn is no correction, see H.auth)
				if okA and type(auth) == "table" and G.ptOn and G.pt.seen then auth.ptd = G.pt.done end
				G.authOwn = G.authOwn or {}
				G.authOwn[a.n] = okA and auth or nil
				-- (with the turns this game has applied in the pause: a game a turn behind the others is not compared, see the launcher)
				local nameSync = K.nameSyncOn()
				if nameSync then R.nameCollect = {} end
				send("sync_hash", { n = a.n, parts = simHash(G.simTerrainSig, G.co, a.n, G.simBuildIds, now), cost = 0, auth = okA and auth or nil,
					ptd = (G.ptOn and G.pt.seen) and G.pt.done or nil })
				if nameSync then
					local col = R.nameCollect
					R.nameCollect = nil
					local list = col and next(col) ~= nil and R.nameChanges(col) or nil
					if list then send("namesync", { n = a.n, list = list }) end
				end
			elseif a.fn == "mpfCoJoin" or coIsLoanEvent({ co = G.co }, a) then
				toSim("co_apply", a)
			else
				if C.makesProposal(a.fn) then
					local okg, sig = pcall(C.buildSig, a.fn == "makeWorldBuildProposalCmd" and type(a.args) == "table" and a.args[1] or nil)
					toSim("replaying", { sig = okg and sig or nil, nots = true })
				end
				-- paused: the engine answers in a callback, a frame later; the result is reported then
				-- (another player's change of the world: a build held here was computed before it, see G.restale)
				if a.origin ~= G.me and G.isWorldAct(a) then G.worldFrame = G.frames end
				local creates = (a.fn == "makeVehicleBuyCmd" or a.fn == "makeLineCreateCmd") and os.getenv("MPFEVER_OLDPAUSED") ~= "1"
				if creates then
					G.pausedCreating = { uid = a.uid, frame = G.frames }
					creating = true
				end
				-- (0.6) what the game options' modules keep of it, before its references are translated (see G.featPausedAct)
				local featDg = nil
				if G.featOn then
					local okD, dg = pcall(G.featDigests, a)
					if okD then featDg = dg end
				end
				withActor(PL(a), executeAction, a, O.sendCommand, true, G.bind, function(r)
					if G.pausedCreating and G.pausedCreating.uid == a.uid then G.pausedCreating = nil end
					-- (the replay counted above went to the engine by itself, not through replaySend: its count is used here. A
					-- refused or unreplayable one builds nothing, the simulation is told: else, in a pause (the same game time for
					-- minutes), the counts added up and the player's own next build was taken as a replay and never shipped, a
					-- station on one game only. MPFEVER_PAUSEDUNUSED=0: as before)
					if C.makesProposal(a.fn) and os.getenv("MPFEVER_PAUSEDUNUSED") ~= "0" then
						if (G.replayCounted or 0) > 0 then G.replayCounted = G.replayCounted - 1 end
						if not r.success then pcall(toSim, "replay_unused", {}) end
					end
					r.at = now
					r.answered, r.returned = nil, nil
					log("paused action " .. tostring(r.uid) .. " " .. tostring(r.fn) .. " at t=" .. tostring(now) .. " -> " .. (r.success and "OK" or "REFUSED"))
					-- (0.6) the game options' modules hear it in the simulation as the actions it applies (every game applies the paused
					-- actions in the same turns, at the same game time; nothing while no option is on)
					if G.featOn then pcall(G.featPausedAct, a, r, featDg) end
					if r.created then G.rebind(r.created.key, r.created.e); toSim("bind", r.created) end
					G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true
					C.appendFile(C.DIR .. BS .. "results.log", C.line("result", r))
					if r.created then C.appendFile(C.DIR .. BS .. "bindings.log", r.created.key .. " " .. tostring(r.created.e) .. NL) end
					G.reportResult(r)
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
K.STOP_MODEL = "stations/street/small_stops/small_old.con"

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
	eo.model = K.STOP_MODEL
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

-- Two players building at the same place within the build margin (MPFEVER_SCENARIO=restale with MPFEVER_TOGETHER=1): two town
-- street segments meet at one junction; both games upgrade one of them at once (the engine's own upgrade proposal, as the
-- street upgrade tool makes it), the host the first and the client the second, each held the usual two seconds. Both change
-- the junction: the one released second was computed before the other was there (MPFEVER_RESTALETEST=1: it is made again at
-- its release, see G.restale, with MPFEVER_RESTALE=1 since 0.5.12; without it: as before 0.5.7).
H.restale = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		-- the junctions of exactly two plain town street segments, in a fixed order (the same on both games)
		local nodes = {}
		for n, segs in pairs(api.engine.system.streetSystem.getNode2SegmentMap() or {}) do
			local list = {}
			pcall(function() for i = 1, #segs do list[#list + 1] = segs[i] end end)
			if #list == 2 then
				local good = true
				for _, e in ipairs(list) do
					local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
					if not (c and c.type == 0 and #c.objects == 0 and tostring(c.roadTemplate):find("town", 1, true)) then good = false end
				end
				table.sort(list)
				if good then nodes[#nodes + 1] = { n = n, segs = list } end
			end
		end
		table.sort(nodes, function(x, y) return x.n < y.n end)
		if #nodes == 0 then error("no junction of two town streets") end
		local k = tonumber(os.getenv("MPFEVER_RESTALE_NODE") or "7") or 7
		local pick = nodes[(k * 37) % #nodes + 1]
		local E = pick.segs[(C.ROLE == "host") and 1 or 2]
		local cur = tostring(api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).roadTemplate)
		-- (another town template: the first one of the save's town streets that is not this one)
		local target = nil
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			local t = c and tostring(c.roadTemplate) or ""
			if t ~= cur and t:find("town", 1, true) and not t:find("entrance", 1, true) and (target == nil or t < target) then target = t end
		end
		if not target then error("no other town template") end
		log("RESTALE " .. C.ROLE .. ": segment " .. E .. " at junction " .. pick.n .. " upgraded from " .. cur .. " to " .. target)
		AUTO.points[#AUTO.points + 1] = nodePosition(pick.n)
		local P = api.engine.util.proposal.replaceSegment(E, target)
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = false
		ctx.cleanupStreetGraph = false
		ctx.gatherBuildings = false
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
			local why = ""
			if not success and res then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			local line = "upgrade of segment " .. E .. " at junction " .. pick.n .. ": " .. (success and "built" or ("refused " .. why))
			log("RESTALE " .. line)
			AUTO.results[#AUTO.results + 1] = line
			G.waits[#G.waits + 1] = { at = G.frames + 150, fn = function()
				-- (the segments of the junction now, on this game: ids, templates and emission emitters)
				pcall(function()
					local list = {}
					for node, segs in pairs(api.engine.system.streetSystem.getNode2SegmentMap() or {}) do
						if node == pick.n then for i = 1, #segs do list[#list + 1] = segs[i] end end
					end
					table.sort(list)
					for _, s in ipairs(list) do
						local c = api.engine.getComponent(s, api.type.ComponentType.BASE_EDGE)
						local em = api.engine.getComponent(s, api.type.ComponentType.EMISSION_EMITTER)
						local l2 = "segment " .. s .. " at the junction: " .. tostring(c and c.roadTemplate) .. ", emission emitter " .. (em and "yes" or "NONE")
						log("RESTALE " .. l2)
						AUTO.results[#AUTO.results + 1] = l2
					end
				end)
				autoFinish()
			end }
		end, P)
	end)
	if not ok then
		log("RESTALE error " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "restale error " .. tostring(err)
		autoFinish()
	end
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
		if p.attach then
			-- (scenario attach) from the end of the newest road built in the game (an edge a company owns)
			local ends, edgeOf = deadEnds()
			local owned = {}
			for _, e in ipairs(ends) do
				local po = nil
				pcall(function() po = api.engine.getComponent(edgeOf[e].e, api.type.ComponentType.PLAYER_OWNED) end)
				if po and po.player and po.player >= 0 then owned[#owned + 1] = { n = e, owner = po.player } end
			end
			-- this game's company's roads first (MPFEVER_ATTACH=other: the other companies' first), the newest first
			local me = api.engine.util.getPlayer()
			local mineFirst = os.getenv("MPFEVER_ATTACH") ~= "other"
			table.sort(owned, function(x, y)
				local xm, ym = (x.owner == me) == mineFirst, (y.owner == me) == mineFirst
				if xm ~= ym then return xm end
				return x.n > y.n
			end)
			local pick = owned[tries]
			-- (MPFEVER_ATTACH_NODE=n: that dead end, whoever owns it)
			local forced = tonumber(os.getenv("MPFEVER_ATTACH_NODE") or "")
			if forced and tries == 1 and edgeOf[forced] then pick = { n = forced, owner = -1 } end
			if not pick then log("AUTOTEST attach: no road built in the game to attach to"); return autoFinish() end
			n, info = pick.n, edgeOf[pick.n]
			pn = nodePosition(n)
			local po = nodePosition(info.other)
			local dx, dy = pn.x - po.x, pn.y - po.y
			local len = math.sqrt(dx * dx + dy * dy)
			-- (sideways, so that the new piece makes a junction rather than continuing the road)
			a = { x = pn.x - dy / len * 40, y = pn.y + dx / len * 40 }
			if os.getenv("MPFEVER_ATTACH_DIR") == "straight" then a = { x = pn.x + dx / len * 40, y = pn.y + dy / len * 40 } end
			a.z = groundZ(a.x, a.y, pn.z)
			log("AUTOTEST attach to node " .. n .. " of edge " .. info.e .. " owned by " .. pick.owner .. " (this game plays " .. tostring(api.engine.util.getPlayer()) .. ")")
		end
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
			if p.attach then
				-- what the engine says of it before building (what a tool shows while the player aims)
				pcall(function()
					local pd = api.engine.util.proposal.makeProposalData(sp, ctx)
					log("AUTOTEST attach preview: critical " .. tostring(pd.errorState.critical) .. " messages " .. C.ser(C.marshal(pd.errorState.messages))
						.. " warnings " .. C.ser(C.marshal(pd.errorState.warnings)))
				end)
			end
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
	-- as a player picking a terrain tool in the menu (MPFEVER_TERRAIN_LEAD=0: not, the first edits may then come late elsewhere)
	if os.getenv("MPFEVER_TERRAIN_LEAD") ~= "0" then
		terrainLead("autotest")
		G.waits[#G.waits + 1] = { at = G.frames + 300, fn = nextEdit }
	else
		nextEdit()
	end
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

-- a road built from the end of a road built in the game (separate companies: one's own, then another company's)
H.attach = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.attach = true
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST attach failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "attach error " .. tostring(err)
		autoFinish()
	end
end

-- an existing construction against a street rebuilt in place, as the construction tool does when a module is added
-- (toRemove = the old one, old2new = its stations kept; issue #14). MPFEVER_CONEDIT_FILE=part of a file name picks it.
H.conedit = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(function()
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- candidates against a street, a refused one makes way for the next. Modular stations only when asked by file name: a scripted
	-- rebuild of one crashes the builder's game ("Construction impossible", then a crash), and real station edits are not replayed
	local want = os.getenv("MPFEVER_CONEDIT_FILE")
	local cands = {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
		if okc and c then
			local f = tostring(c.fileName)
			local street = f:find("street", 1, true) or f:find("modular_terminal", 1, true) or f:find("depot", 1, true)
			if not want and f:find("modular_station", 1, true) then street = nil end
			local has = false
			pcall(function() has = #c.stations > 0 or #c.depots > 0 end)
			if has and street and (not want or f:find(want, 1, true)) then cands[#cands + 1] = { e = e, c = c } end
		end
	end
	table.sort(cands, function(x, y) return x.e < y.e end)
	if #cands == 0 then log("AUTOTEST conedit: no construction against a street"); AUTO.results[#AUTO.results + 1] = "conedit: none"; return autoFinish() end
	local tries = 0
	local tryOne
	tryOne = function()
	tries = tries + 1
	if tries > math.min(#cands, 4) then G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }; return end
	local pick, pc = cands[tries].e, cands[tries].c
	-- what C.rebuildNativeWithConstruction writes on a native proposal for an edit (read back, nothing sent)
	pcall(function()
		local P = api.type.Proposal.new()
		local okw, ew = pcall(function() P.toRemove = { pick }; P.old2new = { [pick] = 0 } end)
		local line = "conedit native fields: " .. (okw and ("toRemove " .. #P.toRemove .. " {" .. tostring(P.toRemove[1]) .. "} old2new[" .. pick .. "]=" .. tostring(P.old2new[pick])) or ("write failed " .. shortErr(ew)))
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
	end)
	local params = C.marshal(pc.params) or {}
	params.upgrade = true
	local m = { toAdd = { { fileName = pc.fileName, params = params, transf = C.marshal(pc.transf), playerEntity = api.engine.util.getPlayer() } },
		toRemove = { pick }, old2newByRank = { [1] = 0 } }
	local okp, sp = pcall(C.rebuildProposal, m, { noStreet = true, seed = 7919 })
	if not okp then log("AUTOTEST conedit proposal error " .. shortErr(sp)); AUTO.results[#AUTO.results + 1] = "conedit: no proposal"; return tryOne() end
	local cons0 = #R.entitiesWith("CONSTRUCTION")
	log("AUTOTEST conedit: rebuilding construction " .. pick .. " " .. tostring(pc.fileName))
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
			local line = "conedit " .. tostring(pc.fileName) .. ": " .. (success and "built" or ("refused " .. why)) .. ", constructions " .. cons0 .. " -> " .. #R.entitiesWith("CONSTRUCTION")
			log("AUTOTEST " .. line)
			AUTO.results[#AUTO.results + 1] = line
			if success then G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish } else tryOne() end
		end }
	end)
	end
	tryOne()
	end)
	if not ok then
		log("AUTOTEST conedit failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "conedit error " .. tostring(err)
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

-- Builder lead scenario (MPFEVER_BUILDLEAD=1 on every game, MPFEVER_SCENARIO=buildlead; MPFEVER_SPEED=n runs it at that speed;
-- without the switch the same roads are held the usual way, to compare the answers):
-- this game is the builder with a construction tool in hand and lays MPFEVER_BUILDLEAD_COUNT (4) roads one after the other,
-- MPFEVER_BUILDLEAD_GAP (40) frames after the answer to the previous one, each sent like a tool's build. Once the other games stay
-- behind this one (at most 30 s), they are released at once: the log shows "BUILDLEAD ... released at once" and the step each
-- landed at ("landed at"), the other games "released at once ... holding there" and the replay at that step. The launcher's checks
-- at the end of the autotest tell whether the games ended identical. The answer of each build (frames from sending it to the
-- engine's verdict) is in the results: a tool places its next piece after that answer.
-- MPFEVER_BUILDLEAD_BOTH=1: the other game lays roads too at the same time (the usual held way, it does not lead), so that this
-- game has the other's builds announced and replayed while it leads (buildLeadState must then hold its own the usual way).
H.buildlead = function(from, p)
	local count = tonumber(os.getenv("MPFEVER_BUILDLEAD_COUNT") or "4") or 4
	local gap = tonumber(os.getenv("MPFEVER_BUILDLEAD_GAP") or "40") or 40
	-- one road from matrix place k, sent like a tool's build; done(success, why, frames to the answer)
	local function road(k, done)
		local n, info, pn, a = matrixPlace(k)
		local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
			tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
		local sp = buildMatrixProposal(o, n, pn, a)
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = true
		ctx.cleanupStreetGraph = os.getenv("MPFEVER_CLEANUP") == "1"
		ctx.gatherBuildings = true
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		local edges0, frame0 = edgeCount(), G.frames
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			done(success, "from node " .. n .. ": " .. (success and "built" or ("refused " .. why)) .. ", edges " .. edges0 .. " -> " .. edgeCount(),
				G.frames - frame0, pn)
		end)
	end
	if p.role ~= C.ROLE then
		-- (BOTH=2: and it has the street tool in hand as well: both lead at the same level, nobody leads)
		local both = os.getenv("MPFEVER_BUILDLEAD_BOTH")
		if (both ~= "1" and both ~= "2") or G.coBuilding then return end
		G.coBuilding = true
		local i = 0
		local function coNext()
			if i >= count then G.coBuilding = nil; log("AUTOTEST buildlead (other game) done: " .. i .. " roads"); return end
			i = i + 1
			if both == "2" then G.buildToolSeen("streetBuilder") end
			local okc, errc = pcall(road, (p.offset or 0) + 100 + i * 5, function(success, what, frames)
				log("AUTOTEST buildlead (other game) road " .. i .. " " .. what .. ", answer after " .. frames .. " frames")
				G.waits[#G.waits + 1] = { at = G.frames + gap, fn = coNext }
			end)
			if not okc then
				log("AUTOTEST buildlead (other game) road " .. i .. " failed: " .. shortErr(errc))
				G.waits[#G.waits + 1] = { at = G.frames + gap, fn = coNext }
			end
		end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = coNext }
		return
	end
	if AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST buildlead " .. t); AUTO.results[#AUTO.results + 1] = t end
	local startFrame = G.frames
	local stats0 = { atOnce = G.leadStats.atOnce, held = G.leadStats.held, shipped = G.leadStats.shipped,
		refused = G.leadStats.refused or 0, capped = G.leadStats.capped or 0 }
	local built, answers = 0, {}
	local nextBuild
	-- a player aiming with the street tool: its events keep the lead up
	local function aim() G.buildToolSeen("streetBuilder") end
	local function finish()
		say("done: " .. built .. " builds, " .. (G.leadStats.atOnce - stats0.atOnce) .. " released at once, " .. (G.leadStats.held - stats0.held)
			.. " held the usual way, " .. (G.leadStats.shipped - stats0.shipped) .. " shipped from a lead, "
			.. ((G.leadStats.refused or 0) - stats0.refused) .. " refused at once, " .. ((G.leadStats.capped or 0) - stats0.capped)
			.. " stops at the cap; answers after " .. table.concat(answers, "/") .. " frames")
		G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
	end
	local function waitLead()
		aim()
		local ok, why = G.buildLeadState()
		if ok or G.frames - startFrame > 1800 then
			say(ok and ("the lead is established after " .. (G.frames - startFrame) .. " frames")
				or ("no lead after " .. (G.frames - startFrame) .. " frames: " .. tostring(why) .. " (the builds go the usual way)"))
			return nextBuild()
		end
		G.waits[#G.waits + 1] = { at = G.frames + 5, fn = waitLead }
	end
	nextBuild = function()
		aim()
		if built >= count then return finish() end
		built = built + 1
		local i = built
		local okp, err = pcall(road, (p.offset or 0) + 20 + i * 5, function(success, what, frames, pn)
			answers[#answers + 1] = frames
			say("road " .. i .. " " .. what .. ", answer after " .. frames .. " frames")
			if success then AUTO.points[#AUTO.points + 1] = pn end
			G.waits[#G.waits + 1] = { at = G.frames + gap, fn = nextBuild }
		end)
		if not okp then
			say("road " .. i .. " failed: " .. shortErr(err))
			G.waits[#G.waits + 1] = { at = G.frames + gap, fn = nextBuild }
		end
	end
	-- (without the switch the same builds are held the usual way: the baseline to compare the answers with)
	if G.buildLead then
		waitLead()
	else
		say("MPFEVER_BUILDLEAD is off: the builds are held the usual way (baseline)")
		nextBuild()
	end
end

-- Town streets scenario (MPFEVER_SCENARIO=towncross), as in a real session that went out of sync: a street that splits a town
-- street and runs 3 pieces of 30 m through the houses beside it (the engine takes them away), and a few frames after it is
-- answered (a tool's next click comes a frame after the answer at the earliest) a second one that splits its middle piece and
-- runs 2 pieces of 25 m through the houses on one side (the other side if the engine refuses it). Only where no other street
-- comes closer than 18 m (a street across another one is refused). Both sent like a tool's
-- build, with the tool's settings (buildings gathered, terrain aligned): held the usual way, or with MPFEVER_BUILDLEAD=1 released
-- at once, so that the second lands a few steps after the first. MPFEVER_TOWNCROSS_COUNT pairs (3). The replaying game logs
-- "edges here" and the build ids of both; the hash checks show whether the games stayed the same.
H.towncross = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local count = tonumber(os.getenv("MPFEVER_TOWNCROSS_COUNT") or "3") or 3
	local function say(t) log("AUTOTEST towncross " .. t); AUTO.results[#AUTO.results + 1] = t end
	local function aim() if G.buildLead then G.buildToolSeen("streetBuilder") end end
	-- the houses of the towns (constructions with town buildings) and their places
	local houses = {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		pcall(function()
			local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
			if c and #c.townBuildings > 0 then
				local q = R.matPos(c.transf)
				if q then houses[#houses + 1] = q end
			end
		end)
	end
	local function near(q, r)
		local k = 0
		for _, h in ipairs(houses) do if (h.x - q.x) ^ 2 + (h.y - q.y) ^ 2 < r * r then k = k + 1 end end
		return k
	end
	-- houses along a street from q in direction d (unit), n pieces of len
	local function along(q, d, n, len)
		local k = 0
		for j = 1, n * 2 do k = k + near({ x = q.x + d.x * len * j / 2, y = q.y + d.y * len * j / 2 }, 12) end
		return k
	end
	local function ctx()
		local c = api.type.Context.new()
		c.gatherBuildings = true
		c.checkTerrainAlignment = true
		c.cleanupStreetGraph = false
		c.gatherFields = true
		c.player = api.engine.util.getPlayer()
		return c
	end
	local function seg(id, n0, n1, p0, p1, src, owner)
		local e = api.type.SegmentAndEntity.new()
		e.entity = id
		e.type = 0
		local cc = e.comp
		cc.node0 = n0; cc.node1 = n1
		local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z }
		cc.tangent0 = vec(t); cc.tangent1 = vec(t)
		cc.position0 = vec(p0); cc.position1 = vec(p1)
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = src.roadTemplate; cc.roadStyle = src.roadStyle; cc.roadType = src.roadType
		cc.laneConfigs = C.templateLanes(src.roadTemplate)
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
	local function ground(q) return { x = q.x, y = q.y, z = groundZ(q.x, q.y, q.z or 0) } end
	-- split segment E at its middle and run a street of n pieces of len from there in direction d
	local function splitAndBranch(E, d, n, len)
		local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local A, B = nodePosition(c.node0), nodePosition(c.node1)
		local M = ground({ x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2 })
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		local nodes, edges = { node(-1, M) }, { seg(-20, c.node0, -1, A, M, c, false), seg(-21, -1, c.node1, M, B, c, false) }
		local prev, prevPos = -1, M
		local pts = { M }
		for j = 1, n do
			local q = ground({ x = M.x + d.x * len * j, y = M.y + d.y * len * j, z = M.z })
			nodes[#nodes + 1] = node(-1 - j, q)
			edges[#edges + 1] = seg(-21 - j, prev, -1 - j, prevPos, q, c, true)
			prev, prevPos = -1 - j, q
			pts[#pts + 1] = q
		end
		ssp.nodesToAdd = nodes
		ssp.edgesToAdd = edges
		ssp.edgesToRemove = { E }
		local ncr = {}
		for _, nn in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(nn, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = nn end
		end
		ssp.nodeConfigsToRemove = ncr
		sp.streetProposal = ssp
		return sp, pts
	end
	local function edgeBetween(a, b)
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if c then
				local p0, p1 = nodePosition(c.node0), nodePosition(c.node1)
				local function at(x, q) return x and math.abs(x.x - q.x) < 1 and math.abs(x.y - q.y) < 1 end
				if (at(p0, a) and at(p1, b)) or (at(p0, b) and at(p1, a)) then return e end
			end
		end
		return nil
	end
	-- room for a street from q in direction d, n pieces of len: no other street (straight between its nodes) closer than 18 m to
	-- its points from 20 m on (the street it starts from, and its continuation, are nearer before), but the segments in `skip`
	local function clear(q, d, n, len, skip)
		local lines = {}
		for _, e in ipairs(R.allEdges()) do
			if not skip[e] then
				local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				local a, b = c and nodePosition(c.node0), c and nodePosition(c.node1)
				if a and b then lines[#lines + 1] = { a, b } end
			end
		end
		for k = 20, n * len, 5 do
			local x, y = q.x + d.x * k, q.y + d.y * k
			for _, l in ipairs(lines) do
				local a, b = l[1], l[2]
				local vx, vy = b.x - a.x, b.y - a.y
				local t = ((x - a.x) * vx + (y - a.y) * vy) / math.max(1e-6, vx * vx + vy * vy)
				t = math.max(0, math.min(1, t))
				local px, py = a.x + vx * t - x, a.y + vy * t - y
				if px * px + py * py < 18 * 18 then return false end
			end
		end
		return true
	end
	-- town street segments, in a deterministic order (same save = same ids)
	local cands = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("/town/", 1, true) and #c.objects == 0 then
			local a, b = nodePosition(c.node0), nodePosition(c.node1)
			if a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 50 then cands[#cands + 1] = e end
		end
	end
	table.sort(cands)
	say(#cands .. " town street segments, " .. #houses .. " houses; " .. (G.buildLead and "BUILDLEAD on" or "BUILDLEAD off (held the usual way)"))
	local used, done, tries, k0 = {}, 0, 0, (p.offset or 0) * 31
	local nextPair
	local function send2(name, sp, after)
		aim()
		local f0 = G.frames
		local okc, err = pcall(function()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx(), false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				say(name .. ": " .. (success and "built" or ("refused " .. why)) .. ", answer after " .. (G.frames - f0) .. " frames, edges " .. #R.allEdges())
				after(success)
			end)
		end)
		if not okc then say(name .. ": command error " .. shortErr(err)); after(false) end
	end
	nextPair = function()
		if done >= count or tries >= count * 3 or #cands == 0 then
			say("done: " .. done .. " pairs built in " .. tries .. " tries")
			G.waits[#G.waits + 1] = { at = G.frames + 120, fn = autoFinish }
			return
		end
		tries = tries + 1
		-- a town street with houses beside it
		local E, d, best = nil, nil, 0
		for j = 1, #cands do
			local e = cands[(k0 + tries * 53 + j * 7) % #cands + 1]
			if not used[e] then
				-- (a candidate split by an earlier street is gone)
				local okc, c = pcall(api.engine.getComponent, e, api.type.ComponentType.BASE_EDGE)
				if not okc then c = nil end
				local a, b = c and nodePosition(c.node0), c and nodePosition(c.node1)
				if a and b then
					local L = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
					local M = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2 }
					for _, s in ipairs({ 1, -1 }) do
						local dd = { x = -(b.y - a.y) / L * s, y = (b.x - a.x) / L * s }
						local h = along(M, dd, 3, 30)
						if h > best and clear(M, dd, 3, 30, { [e] = true }) then E, d, best = e, dd, h end
					end
				end
				if best >= 3 then break end
			end
		end
		if not E then say("no town street with houses beside it and room for a street left"); tries = count * 3; return nextPair() end
		used[E] = true
		local okp, sp1, pts = pcall(splitAndBranch, E, d, 3, 30)
		if not okp then say("pair " .. tries .. ": proposal error " .. shortErr(sp1)); return nextPair() end
		AUTO.points[#AUTO.points + 1] = pts[1]
		send2("pair " .. tries .. " street 1 (segment " .. E .. ", " .. best .. " houses on its way)", sp1, function(ok1)
			if not ok1 then G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextPair }; return end
			local pair = tries
			-- street 2: the first street's middle piece split, and a street through the houses on one side of it
			local function street2(side, last)
				local E2 = edgeBetween(pts[2], pts[3])
				if not E2 then say("pair " .. pair .. ": the first street's middle piece not found"); G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextPair }; return end
				local c2 = api.engine.getComponent(E2, api.type.ComponentType.BASE_EDGE)
				local a, b = nodePosition(c2.node0), nodePosition(c2.node1)
				local L = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
				local Q = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2 }
				local sides = {}
				for _, s in ipairs({ 1, -1 }) do
					local dd = { x = -(b.y - a.y) / L * s, y = (b.x - a.x) / L * s }
					sides[#sides + 1] = { d = dd, h = along(Q, dd, 2, 25), room = clear(Q, dd, 2, 25, { [E2] = true }) }
				end
				table.sort(sides, function(x, y) if x.room ~= y.room then return x.room end return x.h > y.h end)
				local pick = sides[side]
				local okq, sp2 = pcall(splitAndBranch, E2, pick.d, 2, 25)
				if not okq then say("pair " .. pair .. ": second proposal error " .. shortErr(sp2)); G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextPair }; return end
				send2("pair " .. pair .. " street 2" .. (side == 2 and " (other side)" or "") .. " (splits " .. E2 .. ", " .. pick.h .. " houses on its way)", sp2, function(ok2)
					if ok2 then done = done + 1 end
					if not ok2 and not last then G.waits[#G.waits + 1] = { at = G.frames + 3, fn = function() street2(2, true) end }; return end
					G.waits[#G.waits + 1] = { at = G.frames + 200, fn = nextPair }
				end)
			end
			-- (a few frames after the answer, as a tool's next click: in the frame of the answer, the interface has not yet seen the
			-- first street's capture. MPFEVER_TOWNCROSS_DELAY=0: in that very frame, to test the refusal check)
			local delay = tonumber(os.getenv("MPFEVER_TOWNCROSS_DELAY") or "3") or 3
			if delay <= 0 then street2(1, false) else G.waits[#G.waits + 1] = { at = G.frames + delay, fn = function() street2(1, false) end } end
		end)
	end
	if G.buildLead then
		-- (the lead first, as for a player who has the street tool in hand)
		local start = G.frames
		local function waitLead()
			aim()
			local ok, why = G.buildLeadState()
			if ok or G.frames - start > 1800 then
				say(ok and ("the lead is established after " .. (G.frames - start) .. " frames") or ("no lead: " .. tostring(why)))
				return nextPair()
			end
			G.waits[#G.waits + 1] = { at = G.frames + 5, fn = waitLead }
		end
		waitLead()
	else
		nextPair()
	end
end

-- Terrain lead scenario (MPFEVER_SCENARIO=terrainlead): the other game has a terrain tool in hand, as when a player shapes the
-- ground (it leads; no edit is made), and this game lays MPFEVER_TERRAINLEAD_COUNT (3) roads the usual held way, each one 40
-- frames after the answer to the previous one. A held build of this game is stamped ahead of the leader's clock, and the leader
-- stops there for it. The results give the frames from sending each road to the engine's answer; the logs show whether the
-- leader had to give up waiting ("never arrived", then "LATE native build" on the leader).
H.terrainlead = function(from, p)
	if p.role ~= C.ROLE then
		-- the leader: the terrain tool stays in hand until the builder is done (terrainlead_stop), at most 14400 frames, and
		-- it shapes the ground every 120 frames (8x8 cells next to each other, as the terrain scenario does) while the builder
		-- waits for its builds (MPFEVER_TERRAINLEAD_EDITS=0: no edit)
		local last = G.frames + 14400
		local edits = os.getenv("MPFEVER_TERRAINLEAD_EDITS") ~= "0"
		local bx, by = -640, -756
		if C.ROLE ~= "host" then bx, by = 300, -200 end
		local calls, k = 0, 0
		-- (a player shapes the ground a moment after picking the tool: the edits start once the other games have fallen as far
		-- behind as the lead keeps them; an edit made before lands late on a game that was still ahead, as in 0.3.10)
		local function behind()
			local okT, now = pcall(gameTime)
			if not okT then return false end
			for _, pc in pairs(G.peers) do
				if type(pc.t) ~= "number" or pc.t > now - (terrainLeadSteps() - overshootReserve()) * STEP then return false end
			end
			return true
		end
		G.tlHold = true
		local function keep()
			if not G.tlHold or G.frames > last then G.tlHold = nil; log("AUTOTEST terrainlead: terrain tool put away after " .. k .. " edits"); return end
			terrainLead("autotest terrainlead")
			calls = calls + 1
			if edits and calls % 2 == 0 and behind() then
				k = k + 1
				local i, x0 = k, bx + ((k - 1) % 4) * 10
				local okE, errE = pcall(function()
					local h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new((x0 + 4) * 4, (by + 4) * 4))
					local prop = api.type.Proposal.new()
					prop.terrain.baseHeightMod = api.type.GridVec2f.new(x0, by, 8, 8, api.type.Vec2f.new(h0 + 1 + i % 3, h0))
					local ctx = api.type.Context.new()
					ctx.player = api.engine.util.getPlayer()
					O.sendCommand(api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true), function(res, success)
						log("AUTOTEST terrainlead: edit " .. i .. " " .. (success and "made" or "refused") .. " at t=" .. tostring(gameTime()))
					end)
				end)
				if not okE then log("AUTOTEST terrainlead: edit " .. i .. " failed: " .. shortErr(errE)) end
			end
			G.waits[#G.waits + 1] = { at = G.frames + 60, fn = keep }
		end
		keep()
		return
	end
	if AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST terrainlead " .. t); AUTO.results[#AUTO.results + 1] = t end
	local count = tonumber(os.getenv("MPFEVER_TERRAINLEAD_COUNT") or "3") or 3
	local startFrame, built, answers = G.frames, 0, {}
	local nextRoad
	local function finish()
		say("done: " .. built .. " roads, answers after " .. table.concat(answers, "/") .. " frames")
		send("terrainlead_stop", {})
		G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
	end
	-- (MPFEVER_TERRAINLEAD_AIM=1 with BUILDLEAD: this game also has a construction tool in hand, as a player who builds while the
	-- other shapes the ground; the terrain tool's lead must still cover the other game's edits)
	local function aim() if os.getenv("MPFEVER_TERRAINLEAD_AIM") == "1" and G.buildLead then G.buildToolSeen("streetBuilder") end end
	local function waitLead()
		aim()
		local leads = otherLeads()
		if leads or G.frames - startFrame > 1800 then
			say(leads and ("the other game leads after " .. (G.frames - startFrame) .. " frames") or "no lead of the other game seen in 1800 frames")
			return nextRoad()
		end
		G.waits[#G.waits + 1] = { at = G.frames + 5, fn = waitLead }
	end
	nextRoad = function()
		aim()
		if built >= count then return finish() end
		built = built + 1
		local i = built
		local okp, err = pcall(function()
			local n, info, pn, a = matrixPlace((p.offset or 0) + 40 + i * 5)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
			local sp = buildMatrixProposal(o, n, pn, a)
			local ctx = api.type.Context.new()
			ctx.checkTerrainAlignment = true
			ctx.cleanupStreetGraph = os.getenv("MPFEVER_CLEANUP") == "1"
			ctx.gatherBuildings = true
			ctx.gatherFields = true
			ctx.player = api.engine.util.getPlayer()
			local edges0, frame0 = edgeCount(), G.frames
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				answers[#answers + 1] = G.frames - frame0
				say("road " .. i .. " from node " .. n .. ": " .. (success and "built" or ("refused " .. why)) .. ", answer after " .. (G.frames - frame0)
					.. " frames, edges " .. edges0 .. " -> " .. edgeCount())
				if success then AUTO.points[#AUTO.points + 1] = pn end
				G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextRoad }
			end)
		end)
		if not okp then
			say("road " .. i .. " failed: " .. shortErr(err))
			G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextRoad }
		end
	end
	waitLead()
end

-- (the builder of the terrain lead scenario is done: the leader puts the terrain tool away)
H.terrainlead_stop = function(from, p) G.tlHold = nil end

-- Build and demolish scenario (MPFEVER_SCENARIO=dozenew): this game lays a road and demolishes its new segments a second after
-- the engine's answer, three times, each sent like a tool's build (with MPFEVER_BUILDLEAD=1 once it leads, with the street tool
-- in hand). The game gives money back for something just built; the costs of both are logged on every game ("build stats"),
-- so the logs show whether the replaying game pays the same as the builder.
H.dozenew = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST dozenew " .. t); AUTO.results[#AUTO.results + 1] = t end
	-- three roads built and demolished; a refused or failed spot makes way for another dead end (at most 12 spots)
	local i, built, startFrame = 0, 0, G.frames
	local function aim() if G.buildLead then G.buildToolSeen("streetBuilder") end end
	local nextOne
	local function edgeSet() local s = {} for _, e in ipairs(R.allEdges()) do s[e] = true end return s end
	nextOne = function()
		aim()
		if built >= 3 or i >= 12 then G.waits[#G.waits + 1] = { at = G.frames + 120, fn = autoFinish }; return end
		i = i + 1
		local n0 = i
		local okp, err = pcall(function()
			local n, info, pn, a = matrixPlace((p.offset or 0) + (p.role == "host" and 160 or 60) + n0 * 5)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
			local sp = buildMatrixProposal(o, n, pn, a)
			local before = edgeSet()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				local new = {}
				for _, e in ipairs(R.allEdges()) do if not before[e] then new[#new + 1] = e end end
				local why = ""
				if not success then pcall(function() why = " " .. C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				say("road " .. n0 .. ": " .. (success and "built" or ("refused" .. why)) .. ", new segments " .. table.concat(new, ","))
				if success and #new > 0 then built = built + 1 end
				if not success or #new == 0 then G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne }; return end
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
					aim()
					local okr, P = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal(new) end)
					if not okr or not P then say("road " .. n0 .. ": no removal proposal " .. tostring(P)); return nextOne() end
					deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res2, success2)
						say("road " .. n0 .. ": " .. (success2 and "demolished" or "demolition refused"))
						G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne }
					end)
				end }
			end)
		end)
		if not okp then say("road " .. n0 .. " failed: " .. shortErr(err)); G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne } end
	end
	local function waitLead()
		aim()
		if not G.buildLead or G.buildLeadState() or G.frames - startFrame > 1800 then return nextOne() end
		G.waits[#G.waits + 1] = { at = G.frames + 5, fn = waitLead }
	end
	waitLead()
end

-- Refund probe (MPFEVER_SCENARIO=refundprobe): what the interface's list of refundable entities holds after a road is marked as just
-- built, and what a removal costs with that list in its Context (the tool's way) and without it (the replays' way so far)
H.refundprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST refundprobe " .. t); AUTO.results[#AUTO.results + 1] = t end
	local function edgeSet() local s = {} for _, e in ipairs(R.allEdges()) do s[e] = true end return s end
	local function dumpRefund(tag)
		local ok, r = pcall(function() return api.gui.construction.getRefundableEntities() end)
		say(tag .. ": getRefundableEntities " .. (ok and (type(r) .. " " .. C.dump(r):sub(1, 400)) or ("error " .. tostring(r))))
		return ok and r or nil
	end
	dumpRefund("start")
	pcall(function() local c = api.type.Context.new(); say("new Context.refundableEntities " .. type(c.refundableEntities) .. " " .. C.dump(c.refundableEntities):sub(1, 200)) end)
	local i = 0
	local nextOne
	nextOne = function()
		if i >= 6 or (p.done or 0) >= 2 then G.waits[#G.waits + 1] = { at = G.frames + 120, fn = autoFinish }; return end
		i = i + 1
		local n0 = i
		local okp, err = pcall(function()
			local n, info, pn, a = matrixPlace((p.offset or 0) + 60 + n0 * 5)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
			local sp = buildMatrixProposal(o, n, pn, a)
			local before = edgeSet()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				local new = {}
				for _, e in ipairs(R.allEdges()) do if not before[e] then new[#new + 1] = e end end
				say("road " .. n0 .. ": " .. (success and "built" or "refused") .. ", new segments " .. table.concat(new, ","))
				if not success or #new == 0 then G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne }; return end
				local oku, erru = pcall(function() api.gui.construction.updateRefundableEntities(res.resultEntities, res.proposal.proposal) end)
				if not oku then say("updateRefundableEntities(resultEntities, proposal.proposal) " .. shortErr(erru)) end
				dumpRefund("road " .. n0 .. " after update")
				local withRefund = (p.done or 0) == 0
				p.done = (p.done or 0) + 1
				local okl, rf = pcall(function() return C.refundList(api.gui.construction.getRefundableEntities()) end)
				say("road " .. n0 .. ": shipped form " .. (okl and C.ser(rf) or ("error " .. tostring(rf))))
				if not okl then rf = nil end
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
					local okr, P = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal(new) end)
					if not okr or not P then say("road " .. n0 .. ": no removal proposal " .. tostring(P)); return nextOne() end
					local ctx = playerContext()
					if withRefund and rf then
						local okc, errc = pcall(function() ctx.refundableEntities = C.toRefund(rf) end)
						say("road " .. n0 .. ": Context.refundableEntities written " .. tostring(okc) .. (okc and "" or (" " .. shortErr(errc)))
							.. ", reads back " .. C.dump(ctx.refundableEntities):sub(1, 300))
					end
					deferredSend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res2, success2)
						local cost = "?"
						pcall(function() cost = tostring(res2.resultProposalData.costs) end)
						say("road " .. n0 .. ": " .. (success2 and "demolished" or "demolition refused") .. (withRefund and " WITH" or " without")
							.. " the refundable list, costs " .. cost)
						G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne }
					end)
				end }
			end)
		end)
		if not okp then say("road " .. n0 .. " failed: " .. shortErr(err)); G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne } end
	end
	nextOne()
end

-- (autotest notiftest: the interface does the work, see N.test in mpfever_ui.script.lua; this game answers once it had the time)
H.notiftest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = { "see ui_mod.log (NOTIFTEST lines)" }
	AUTO.points = {}
	G.waits[#G.waits + 1] = { at = G.frames + 180, fn = autoFinish }
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
		o.model = K.STOP_MODEL
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
		-- (held until its announced step, as a player's tool build: sent at once, the other games applied it a few steps
		-- late and the simulation drifted apart)
		deferredSend(cmd, function(res, success)
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

-- The ends of an autotest builder's copy of segment c (its BASE_EDGE), as the stop and signal tools copy a segment: its own
-- ends (position0/1), which may lie off its nodes; rev: the copy runs the other way round. The other games replay such a
-- copy with their segment's own ends (replayStop): a builder that put the ends on the nodes laid an offset segment on the
-- ground again on its own game only, a desync the test itself made (tramstop, dsignal, dstop). MPFEVER_DSTOPNODEPOS=1: the
-- nodes' positions, as before
G.autoSegEnds = function(c, rev)
	local p0, p1
	if os.getenv("MPFEVER_DSTOPNODEPOS") == "1" then
		p0, p1 = vec(nodePosition(c.node0)), vec(nodePosition(c.node1))
	else
		p0, p1 = vec(c.position0), vec(c.position1)
	end
	if rev then return p1, p0 end
	return p0, p1
end

-- How far the ends of segment c (its BASE_EDGE) lie off its nodes, in metres (nil, nil if not readable): for the autotests' logs
G.autoEndsOff = function(c)
	local ok, d0, d1 = pcall(function()
		local a, b = nodePosition(c.node0), nodePosition(c.node1)
		local function d(p, q) return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2) end
		return d(c.position0, a), d(c.position1, b)
	end)
	if ok then return d0, d1 end
	return nil, nil
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
			o.model = K.STOP_MODEL
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
		-- (the segment's own ends, as the stop tool copies them, see G.autoSegEnds)
		cc.position0, cc.position1 = G.autoSegEnds(c)
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
		eo.model = K.STOP_MODEL
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
			-- a build from another map (a player's log): shift = {x, y} moves it there, at the height of the ground there
			if type(a.shift) == "table" then
				local m, dx, dy, dz = a.args[1], nil, nil, 0
				local n1 = m.proposal.addedNodes[1].comp.position
				dx, dy = a.shift[1] - n1.x, a.shift[2] - n1.y
				pcall(function() dz = api.engine.terrain.getHeightAt(api.type.Vec2f.new(a.shift[1], a.shift[2])) - n1.z end)
				local function mv(v) if type(v) == "table" and v.x then v.x, v.y, v.z = v.x + dx, v.y + dy, v.z + dz end end
				for _, nd in ipairs(m.proposal.addedNodes or {}) do mv(nd.comp.position) end
				for _, sg in ipairs(m.proposal.addedSegments or {}) do mv(sg.comp.position0); mv(sg.comp.position1) end
				for _, ce in ipairs(m.toAdd or {}) do local t = ce.transf; if t then t[13], t[14], t[15] = t[13] + dx, t[14] + dy, t[15] + dz end end
				log(string.format("REPLAYFILE act %d shifted by %.1f %.1f %.1f", k, dx, dy, dz))
			end
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
			G.waits[#G.waits + 1] = { at = G.frames + (os.getenv("MPFEVER_EXP") and 900 or 120), fn = function()
				line = line .. ", after " .. #R.allEdges()
				local deco, tram, dist5, track0, tunnels = 0, 0, 0, 0, 0
				pcall(function()
					for _, e in ipairs(R.allEdges()) do
						local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
						if c and #c.edgeDecorations > 0 then deco = deco + 1 end
						local hasTram = false
						pcall(function() for k = 1, #c.laneConfigs do if c.laneConfigs[k].transportModes[5] then hasTram = true end end end)
						if hasTram then tram = tram + 1 end
						if c and c.distance and c.distance > 0 then dist5 = dist5 + 1 end
						if c and c.type == 1 and c.distance == 0 then track0 = track0 + 1 end
					if c and c.type == 2 then tunnels = tunnels + 1 end
					end
				end)
				local objs = 0
			pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do objs = objs + 1 end end)
			line = line .. ", edges with decorations " .. deco .. ", with tram lanes " .. tram .. ", with distance " .. dist5 .. ", tracks with distance 0: " .. track0
				.. ", tunnel segments " .. tunnels .. ", edge objects " .. objs .. ", constructions " .. #R.entitiesWith("CONSTRUCTION")
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

-- (autotest recplay: one game saves, where its autosave did in the session replayed)
H.test_save = function(from, p)
	if p.role ~= C.ROLE and p.role ~= "both" then return end
	log("test save '" .. tostring(p.name) .. "' at t=" .. tostring(gameTime()))
	pcall(app.saveGame, tostring(p.name), function() log("test save '" .. tostring(p.name) .. "' done") end, false, true)
end

H.replayfile = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	-- (MPFEVER_REPLAYBOTH=1: every game replays the file, the checks then compare what each made of it)
	if C.ROLE ~= "host" and os.getenv("MPFEVER_REPLAYBOTH") ~= "1" then AUTO.results = { "host only" }; return autoFinish() end
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
		pcall(function() eo.edgeObjectConstruction = K.STOP_MODEL end)
		pcall(function() eo.model = K.STOP_MODEL end)
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

-- Builds from windows that no game can replay (MPFEVER_SCENARIO=badui, with MPFEVER_PAUSED=1 and a build after it, e.g.
-- "badui,newroad"): in a pause they left their replay counted, and the player's next build at the same time was taken as a
-- replay and never shipped (a station on one game only, a session of the friends)
H.badui = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	for k = 1, 2 do uiRequest("makeWorldBuildProposalCmd", { n = 4, "not a proposal " .. k, false, false, true }) end
	AUTO.results[1] = "2 builds no game can replay sent at t=" .. tostring(gameTime())
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = autoFinish }
end

-- Industry extends (MPFEVER_SCENARIO=extend with MPFEVER_PAUSED=1 and a build after it, "extend,newroad"; the friends' 0.5.12
-- resyncs of 2026-10-28): MPFEVER_EXTEND_N (4) extends sent as the industry window sends them. Counted as builds to come (0.5.12,
-- MPFEVER_EXTENDCOUNT=1 on a game), the next road built at that time there was taken as a replay and never shipped: the games
-- then differ (edges) at the test's last check
H.extend = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local cons, had = {}, {}
	for _, e in ipairs(R.entitiesWith("INDUSTRY")) do
		pcall(function()
			local c = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY).construction
			pcall(function()
				local top = api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(c)
				if type(top) == "number" and top >= 0 then c = top end
			end)
			if type(c) == "number" and c >= 0 and not had[c] then had[c] = true; cons[#cons + 1] = c end
		end)
	end
	table.sort(cons)
	local want = #cons > 0 and (tonumber(os.getenv("MPFEVER_EXTEND_N") or "") or 4) or 0
	for k = 1, want do uiRequest("makeCreateIndustryExtendProposalCmd", { n = 3, cons[(k - 1) % #cons + 1], 0, 1 }) end
	AUTO.results[1] = want .. " industry extends sent at t=" .. tostring(gameTime()) .. (G.session.pauseAt and " (paused)" or " (not paused)")
		.. ", EXTENDCOUNT=" .. tostring(os.getenv("MPFEVER_EXTENDCOUNT"))
	log("AUTOTEST extend: " .. AUTO.results[1])
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = autoFinish }
end

-- A train station edited again and again, as the module tool does (MPFEVER_SCENARIO=stationedit, host; issue #82: the frame
-- rate fell with every module added to a train station): the station with the most modules replaced by itself
-- MPFEVER_STATIONEDIT_N times (6), 10 s apart. Each round tells the interface's frame rate, the simulation state's size and what
-- reading it costs. MPFEVER_KEEPOUT=1: the captures keep their proposals, as before 0.5.3 and without a lobby before 0.5.4.
H.stationedit = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST stationedit " .. t); AUTO.results[#AUTO.results + 1] = t end
	if C.ROLE ~= "host" then say("host only"); return autoFinish() end
	local function pickStation()
		local pick, pc, best = nil, nil, -1
		for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
			local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
			if okc and c and tostring(c.fileName):find("stations/rail/", 1, true) then
				local n = 0
				pcall(function() for _ in pairs(c.params.modules) do n = n + 1 end end)
				if n > best then pick, pc, best = e, c, n end
			end
		end
		return pick, pc, best
	end
	local function measure()
		local state = G.stateObj
		local st = state:get() or {}
		local withArgs = 0
		for _, o in ipairs(st.out or {}) do if o.args then withArgs = withArgs + 1 end end
		local c0 = os.clock()
		for _ = 1, 5 do state:get() end
		return #C.ser(st), (os.clock() - c0) / 5 * 1000, #(st.out or {}), withArgs
	end
	-- (MPFEVER_STATIONEDIT_SOLO=1: the simulation told « no lobby » as H.solo does; its captures must stop)
	if os.getenv("MPFEVER_STATIONEDIT_SOLO") == "1" then toSim("solo", { on = true }) end
	local rounds = tonumber(os.getenv("MPFEVER_STATIONEDIT_N") or "") or 6
	local k = 0
	local f0, t0 = G.frames, os.clock()
	local function round()
		local fps = (G.frames - f0) / math.max(0.001, os.clock() - t0)
		local size, getMs, nOut, withArgs = measure()
		say(string.format("round %d: interface %.1f fps, state %d bytes, state:get() %.2f ms, captures %d (%d with their proposal)", k, fps, size, getMs, nOut, withArgs))
		if k >= rounds then return autoFinish() end
		k = k + 1
		local pick, pc, nmod = pickStation()
		if not pick then say("no train station"); return autoFinish() end
		local okp, errp = pcall(function()
			local params = C.plain(C.marshal(pc.params))
			local P = api.engine.util.proposal.createProposalReplaceConstruction(pick, params)
			deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)
				log("AUTOTEST stationedit build " .. k .. ": " .. tostring(success))
			end)
		end)
		if k == 1 then say("station " .. pick .. " '" .. tostring(pc.fileName) .. "', " .. nmod .. " modules") end
		if not okp then say("edit failed " .. shortErr(errp)) end
		f0, t0 = G.frames, os.clock()
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = round }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function() f0, t0 = G.frames, os.clock(); G.waits[#G.waits + 1] = { at = G.frames + 300, fn = round } end }
end

-- The edit of a construction sent by a window, as the Drive-in Warehouses mod sends a warehouse's goods (MPFEVER_SCENARIO=uiedit,
-- host): the engine's replacement of a warehouse (else of a station or a depot of a player) with its settings, captured as the
-- interface hook captures it. Every game must replay it (G.uiEdit) and stay in sync. MPFEVER_UIEDIT_FILE: part of the file name.
H.uiedit = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST uiedit " .. t); AUTO.results[#AUTO.results + 1] = t end
	if C.ROLE ~= "host" then say("host only"); return autoFinish() end
	local want = os.getenv("MPFEVER_UIEDIT_FILE")
	local pick, pc, rank = nil, nil, 99
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
		if okc and c then
			local f = tostring(c.fileName)
			local r = (want and f:find(want, 1, true)) and 0 or (f:find("warehouses/", 1, true) and 1) or ((f:find("station", 1, true) or f:find("depot", 1, true)) and R.ownerOf(e) and 2) or 99
			if r < rank then pick, pc, rank = e, c, r end
		end
	end
	if not pick then say("no construction to edit"); return autoFinish() end
	local ok, err = pcall(function()
		local params = C.plain(C.marshal(pc.params))
		params.upgrade = true
		local P = api.engine.util.proposal.createProposalReplaceConstruction(pick, params)
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = true
		ctx.cleanupStreetGraph = true
		ctx.gatherBuildings = true
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		local margs = { n = 4, C.marshal(P), C.marshal(ctx), false, true }
		say("edit of " .. tostring(pc.fileName) .. " (construction " .. pick .. "): " .. #P.toAdd .. " added, " .. #P.toRemove .. " removed, sent as a window's command")
		local cons0 = #R.entitiesWith("CONSTRUCTION")
		uiRequest("makeWorldBuildProposalCmd", margs)
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			say("constructions " .. cons0 .. " -> " .. #R.entitiesWith("CONSTRUCTION"))
			autoFinish()
		end }
	end)
	if not ok then say("failed " .. shortErr(err)); autoFinish() end
end

-- Several purchases at once (issue #35): four copies of a vehicle requested in the same frame, so stamped at the same step;
-- MPFEVER_BUYBUILD=1: with a held road build at the same time, so that the games stand still around the purchases' step.
-- Every game must create them at the same steps (one per step) and with the same ids
H.buymany = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local me = api.engine.util.getPlayer()
		local pick = nil
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not pick and tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot)
				and (G.cmode ~= "separate" or R.ownerOf(v) == me) then pick = { v = v, tv = tv } end
		end
		if not pick then AUTO.results[#AUTO.results + 1] = "buymany: no vehicle with a depot"; return autoFinish() end
		local before = #R.entitiesWith("TRANSPORT_VEHICLE")
		for _ = 1, 4 do
			uiRequest("makeVehicleBuyCmd", { n = 3, [1] = me, [2] = pick.tv.depot, [3] = C.marshal(pick.tv.transportVehicleConfig) })
		end
		log("AUTOTEST buymany: 4 copies of vehicle " .. pick.v .. " requested at once (" .. before .. " vehicles)")
		-- (an empty build held like a tool's: every game stops around its step, which is right after the purchases')
		if os.getenv("MPFEVER_BUYBUILD") == "1" then
			pcall(function() deferredSend(api.cmd.makeWorldBuildProposalCmd(api.type.SimpleProposal.new(), playerContext(), false, true), function() end) end)
		end
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			local line = "buymany: vehicles " .. before .. " -> " .. #R.entitiesWith("TRANSPORT_VEHICLE")
			log("AUTOTEST " .. line)
			AUTO.results[#AUTO.results + 1] = line
			autoFinish()
		end }
	end)
	if not ok then
		log("AUTOTEST buymany failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "buymany error " .. tostring(err)
		autoFinish()
	end
end

-- Paused builds and actions of two players at once (MPFEVER_SCENARIO=pmix with MPFEVER_TOGETHER=1 and MPFEVER_PAUSED=1): the host
-- buys a vehicle every half second while the client puts stops on streets (H.dstop). Each game applied its own paused actions at
-- once and the others' when they came, the builds in their turns, so purchases and builds went in another order on each game and
-- took other entity ids (the friends' session of 2026-10-25, see G.actTurn). Every game must give the vehicles the same ids.
H.pmix = function(from, p)
	if p.role ~= C.ROLE then return end
	if C.ROLE ~= "host" then return H.dstop(from, p) end
	if AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local me = api.engine.util.getPlayer()
	local pick = nil
	for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if not pick and tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot)
			and (G.cmode ~= "separate" or R.ownerOf(v) == me) then pick = { v = v, tv = tv } end
	end
	if not pick then AUTO.results[#AUTO.results + 1] = "pmix: no vehicle with a depot"; return autoFinish() end
	local before = #R.entitiesWith("TRANSPORT_VEHICLE")
	-- (read once: a component read from the engine points into its storage, which the next vehicle bought moves; read again a
	-- second later it crashed the game)
	local depot, cfg = pick.tv.depot, C.marshal(pick.tv.transportVehicleConfig)
	local n = 0
	local function buyOne()
		n = n + 1
		uiRequest("makeVehicleBuyCmd", { n = 3, [1] = me, [2] = depot, [3] = C.deser(C.ser(cfg)) })
		if n < 8 then G.waits[#G.waits + 1] = { at = G.frames + 30, fn = buyOne } end
	end
	buyOne()
	log("AUTOTEST pmix: 8 copies of vehicle " .. pick.v .. ", one every 30 frames (" .. before .. " vehicles)")
	G.waits[#G.waits + 1] = { at = G.frames + 30 * 8 + 600, fn = function()
		local line = "pmix: vehicles " .. before .. " -> " .. #R.entitiesWith("TRANSPORT_VEHICLE")
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		autoFinish()
	end }
end

-- Purchases then line assignments (issue #36, run with MPFEVER_PAUSED=1): three copies of a vehicle on a line requested at
-- once, and each new vehicle assigned to that line as soon as this game knows it, as the depot window does from the
-- purchase's callback. Every game must assign them all (an assignment that arrived before its purchase was registered on the
-- other game was skipped there, and every game reloaded)
H.buyline = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local me = api.engine.util.getPlayer()
		local pick = nil
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not pick and tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot)
				and type(tv.line) == "number" and tv.line >= 0 and (G.cmode ~= "separate" or R.ownerOf(v) == me) then
				pick = { v = v, depot = tv.depot, line = tv.line, cfg = C.marshal(tv.transportVehicleConfig) }
			end
		end
		if not pick then AUTO.results[#AUTO.results + 1] = "buyline: no vehicle with a depot on a line"; return autoFinish() end
		local known = {}
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do known[v] = true end
		for _ = 1, 2 do
			uiRequest("makeVehicleBuyCmd", { n = 3, [1] = me, [2] = pick.depot, [3] = pick.cfg })
		end
		log("AUTOTEST buyline: 2 copies of vehicle " .. pick.v .. " requested, each assigned to line " .. pick.line .. " once known")
		local assigned, frames, mine = 0, 0, {}
		local function poll()
			frames = frames + 1
			for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
				if not known[v] and G.rev[v] then
					known[v] = true
					assigned = assigned + 1
					mine[#mine + 1] = v
					uiRequest("makeVehicleSetLineCmd", { n = 3, [1] = v, [2] = pick.line, [3] = 0 })
					log("AUTOTEST buyline: vehicle " .. v .. " (" .. tostring(G.rev[v]) .. ") assigned at frame " .. frames)
				end
			end
			if assigned >= 2 or frames > 900 then
				G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
					local onLine = 0
					for _, v in ipairs(mine) do
						local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
						if tv and tv.line == pick.line then onLine = onLine + 1 end
					end
					local line = "buyline: " .. assigned .. " bought and assigned here, " .. onLine .. " on the line"
					log("AUTOTEST " .. line)
					AUTO.results[#AUTO.results + 1] = line
					autoFinish()
				end }
			else
				G.waits[#G.waits + 1] = { at = G.frames + 1, fn = poll }
			end
		end
		G.waits[#G.waits + 1] = { at = G.frames + 1, fn = poll }
	end)
	if not ok then
		log("AUTOTEST buyline failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "buyline error " .. tostring(err)
		autoFinish()
	end
end

-- Double slip scenario (issue #26): the node window's build, which holds nothing but a node configuration, sent through the
-- same request path; then every game must have the switch
H.dslip = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(function()
		AUTO.running = true
		AUTO.results = {}
		AUTO.points = {}
		-- a track node with 4 track segments (a crossing), the host and the client each take another one
		local map = api.engine.system.streetSystem.getNode2SegmentMap()
		-- (else a track switch: the flag is a field of the node's configuration either way)
		local cands, switches = {}, {}
		for n, segs in pairs(map) do
			local k, tracks = 0, 0
			pcall(function() k = #segs end)
			if k >= 3 then
				for i = 1, k do
					-- (a track segment: no street component)
					if not api.engine.getComponent(segs[i], api.type.ComponentType.BASE_EDGE_STREET) then tracks = tracks + 1 end
				end
				if tracks == 4 and k == 4 then cands[#cands + 1] = n elseif tracks == k then switches[#switches + 1] = n end
			end
		end
		if #cands == 0 then cands = switches end
		table.sort(cands)
		local node = cands[(C.ROLE == "host") and 1 or 2] or cands[1]
		if not node then AUTO.results[#AUTO.results + 1] = "dslip: no track crossing"; return autoFinish() end
		local function flag()
			local v = "none"
			pcall(function()
				local nc = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG)
				if nc then v = tostring(nc.doubleSlipSwitch) end
			end)
			return v
		end
		local before = flag()
		local cfg = { entity = node, comp = { doubleSlipSwitch = true, laneConnections = {}, crosswalks = {}, trafficLightPreference = 1,
			trafficLightConfig = { trafficLightType = -1, states = {} }, userModifiedTrafficLightStates = false } }
		local proposal = { streetProposal = { nodeConfigsToAdd = { cfg }, nodeConfigsToRemove = (before ~= "none") and { node } or nil } }
		uiRequest("makeWorldBuildProposalCmd", { n = 4, [1] = proposal, [3] = false, [4] = true })
		log("AUTOTEST dslip on node " .. node .. " (" .. #cands .. " crossings), switch before " .. before)
		G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
			local line = "dslip node " .. node .. ": switch " .. before .. " -> " .. flag()
			log("AUTOTEST " .. line)
			AUTO.results[#AUTO.results + 1] = line
			autoFinish()
		end }
	end)
	if not ok then
		log("AUTOTEST dslip failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "dslip error " .. tostring(err)
		autoFinish()
	end
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
-- Build previews (MPFEVER_SCENARIO=pvtest): this game sends the preview of three existing street segments as the street tool
-- would (G.previewOut); the other one draws it (its log: "build preview of ... circle(s) shown"), and takes it away 1.5 s later
H.pvtest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local segs = {}
	for _, e in ipairs(R.allEdges()) do
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if be and #segs < 3 and (#segs == 0 or be.node0 == segs[#segs].node1) then segs[#segs + 1] = be end
		if #segs >= 3 then break end
	end
	-- the event as the street tool gives it: { Proposal, ProposalData } by position, here the engine's own proposal that
	-- replaces the first of those segments (a real Proposal, as the tool's)
	local edge = nil
	for _, e in ipairs(R.allEdges()) do
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if be and segs[1] and be.node0 == segs[1].node0 and be.node1 == segs[1].node1 then edge = e break end
	end
	local okP, P = pcall(function() return api.engine.util.proposal.replaceSegment(edge) end)
	if not okP or not P then
		AUTO.results[#AUTO.results + 1] = "no engine proposal for segment " .. tostring(edge) .. ": " .. tostring(P)
		return autoFinish()
	end
	local param = { P, nil }
	local pts = G.pvPoints(param)
	-- (the others look at it: MPFEVER_PVCAM=1 moves their camera there, for a screenshot)
	if pts[1] then send("pvcam", { x = pts[1][1], y = pts[1][2] }) end
	local sent = 0
	local function again()
		G.pv.sentAt = -1000
		G.previewOut("streetBuilder", param)
		sent = sent + 1
		if sent < 30 then G.waits[#G.waits + 1] = { at = G.frames + 20, fn = again } end
	end
	again()
	AUTO.results[#AUTO.results + 1] = "preview of an engine proposal on segment " .. tostring(edge) .. ": " .. #pts .. " point(s) sent"
	G.waits[#G.waits + 1] = { at = G.frames + 20 * 30 + 240, fn = function()
		AUTO.results[#AUTO.results + 1] = "preview " .. (G.pv.sending and "still shown" or "taken away after the tool's silence")
		autoFinish()
	end }
end

-- Finance lines (MPFEVER_SCENARIO=fincat): books three entries on this game's company (a road construction, station upkeep
-- and road revenue, as the refunds and the shared stations' fees are now booked) and reads the finance window's table before
-- and after: each must land in its own line ("Roads", "Upkeep Stations" of Road, "Revenue" of Road), none in « Other »
H.fincat = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local player = api.engine.util.getPlayer()
	local function table_()
		local t = {}
		local cfg = api.type.ChartConfig.new()
		cfg.count = 1
		local fd = api.engine.util.finance.computeFinanceTable(player, cfg)
		fd:foreach_investment(function(key, values)
			local k = fd:unfoldKey(key)
			t["investment " .. tostring(k[1]) .. "/" .. tostring(k[3])] = values[#values]
		end)
		fd:foreach_carrier(function(carrier)
			fd:foreach_transport(function(key, values)
				local k = fd:unfoldKey(key)
				t["transport " .. tostring(carrier) .. " " .. tostring(k[1]) .. "/" .. tostring(k[2]) .. "/" .. tostring(k[3])] = values[#values]
			end, carrier)
		end)
		fd:foreach_other(function(key, values) t["other " .. tostring(key)] = values[#values] end)
		return t
	end
	local okB, before = pcall(table_)
	local JE = api.type.JournalEntry
	local function book(amount, fill)
		local e = JE.new()
		e.amount = amount
		e.time = -1
		local okF, err = pcall(fill, e)
		if not okF then AUTO.results[#AUTO.results + 1] = "category not writable: " .. tostring(err) end
		api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(player, e, api.type.Vec3f.new(0, 0, 0)))
	end
	book(-12345, function(e) e.category.type = JE.Type.CONSTRUCTION; e.category.construction = JE.Construction.STREET end)
	book(-111, function(e) e.category.type = JE.Type.MAINTENANCE; e.category.maintenance = JE.Maintenance.INFRASTRUCTURE; e.category.construction = JE.Construction.STATION; e.category.carrier = JE.Carrier.ROAD end)
	book(222, function(e) e.category.type = JE.Type.INCOME; e.category.carrier = JE.Carrier.ROAD end)
	G.waits[#G.waits + 1] = { at = G.frames + 180, fn = function()
		local okA, after = pcall(table_)
		if not (okB and okA) then
			AUTO.results[#AUTO.results + 1] = "finance table not read: " .. tostring(okB and after or before)
			return autoFinish()
		end
		local keys = {}
		for k in pairs(after) do keys[k] = true end
		for k in pairs(before) do keys[k] = true end
		for k in pairs(keys) do
			local d = (after[k] or 0) - (before[k] or 0)
			if d ~= 0 then AUTO.results[#AUTO.results + 1] = k .. ": " .. d end
		end
		AUTO.results[#AUTO.results + 1] = "keys: CONSTRUCTION=" .. tostring(JE.Type.CONSTRUCTION) .. " STREET=" .. tostring(JE.Construction.STREET)
			.. " MAINTENANCE=" .. tostring(JE.Type.MAINTENANCE) .. " INCOME=" .. tostring(JE.Type.INCOME) .. " ROAD=" .. tostring(JE.Carrier.ROAD)
		autoFinish()
	end }
end

H.pvcam = function(from, p)
	if from == G.me or os.getenv("MPFEVER_PVCAM") ~= "1" then return end
	pcall(function() api.gui.camera.setManualCamera(api.type.Vec2f.new(p.x, p.y), 250) end)
	log("preview test: camera moved to " .. tostring(p.x) .. "," .. tostring(p.y))
end

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

-- Window scenario (MPFEVER_SCENARIO=wintabs, each game in its turn): MPFever's window shows each of its tabs in turn, Session,
-- Chat, Company, Rules, Settings, MPFEVER_WINTABSECONDS each (10 by default), asked to the interface through ui_tab_req.txt
-- (the interface opens the window on that tab, see U.pollTabReq); the interface says which tab it drew and whether the tab
-- failed (ui_tab_shown.txt). For the screenshots of the test campaign ("AUTOTEST wintabs: <tab> drawn" in mod.log, the
-- tab on screen from then until the next one is asked) and to check that no tab fails to draw. With one company for everybody
-- the interface shows Session for Company and Rules (those tabs do not exist there): the results say so.
-- (0.6) Then the Hub (unless MPFEVER_HUB=0): "hub:" opens it on its first page and its answer lists the session's pages, each then
-- asked in its turn ("hub:<page>"; "AUTOTEST hub: <page> drawn, N rows" in mod.log, the page on screen until the next one). With the
-- Hub, the tabs the small window no longer has (Company, Rules, Game, Settings) are drawn by the Hub: the results say "drawn as".
H.wintabs = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- (the Game tab of 0.5.14 too: the game's rules, one company per player only, else Session is drawn in its place)
	-- ((0.6) p.tabs: the tabs of another scenario, see H.pubtest)
	local tabs = type(p.tabs) == "table" and p.tabs or { "session", "chat", "company", "rules", "game", "settings" }
	if type(p.tabs) ~= "table" and os.getenv("MPFEVER_HUB") ~= "0" then tabs[#tabs + 1] = "hub:" end
	local frames = math.max(3, tonumber(os.getenv("MPFEVER_WINTABSECONDS") or "") or 10) * 60
	local function ask(i)
		if i > #tabs then return autoFinish() end
		local f = C.IO.open(C.DIR .. BS .. "ui_tab_req.txt", "wb")
		if f then f:write(tabs[i] .. TAB .. i .. NL); f:close() end
		log("AUTOTEST wintabs: " .. tabs[i] .. " asked")
		G.waits[#G.waits + 1] = { at = G.frames + math.floor(frames / 3), fn = function()
			local s = ""
			local fr = C.IO.open(C.DIR .. BS .. "ui_tab_shown.txt", "rb")
			if fr then s = fr:read("*a") or ""; fr:close() end
			local seq, asked, shown, result, rows = s:match("^(%d+)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "(%d+)")
			local line
			local hubPage = tabs[i]:match("^hub:(.*)$")
			if hubPage == "" then
				-- (the Hub's first answer: its pages, after the rows; each one asked next)
				local pages = s:match("^%d+" .. TAB .. "[^" .. TAB .. "]*" .. TAB .. "[^" .. TAB .. "]*" .. TAB .. "[^" .. TAB .. "]*" .. TAB .. "%d+" .. TAB .. "([%w_,]+)")
				if tonumber(seq) ~= i then line = "hub: NOT OPENED (no answer from the interface)"
				else
					local n = 0
					for pg in (pages or ""):gmatch("[%w_]+") do n = n + 1; table.insert(tabs, i + n, "hub:" .. pg) end
					line = "hub: opened on " .. tostring(shown) .. ", " .. n .. " page(s): " .. tostring(pages or "none")
				end
			elseif hubPage then
				if tonumber(seq) ~= i then line = "hub: " .. hubPage .. " NOT DRAWN (no answer from the interface)"
				else line = "hub: " .. hubPage .. " drawn" .. (shown ~= hubPage and (" as " .. tostring(shown)) or "") .. ", " .. tostring(rows) .. " rows"
					.. (result ~= "ok" and (" (" .. tostring(result) .. ")") or "") end
			elseif tonumber(seq) ~= i then line = "wintabs: " .. tabs[i] .. " NOT DRAWN (no answer from the interface)"
			else line = "wintabs: " .. tabs[i] .. " drawn as " .. tostring(shown) .. ", " .. tostring(result) .. ", " .. tostring(rows) .. " rows" end
			AUTO.results[#AUTO.results + 1] = line
			log("AUTOTEST " .. line)
			G.waits[#G.waits + 1] = { at = G.frames + frames - math.floor(frames / 3), fn = function() ask(i + 1) end }
		end }
	end
	ask(1)
end
-- (0.6) Public games scenario (MPFEVER_SCENARIO=pubtest, both games at once: MPFever.exe's RunPubTest has switched the options
-- public, join_bans and join_approve on, and a stranger waits for the host's answer): each game says which options its game has
-- (f_opts: "public=1" expected on both), then shows its MPFever window's "Public game" tab and its Session tab as the window
-- scenario does (the host's offer Accept and Refuse for the stranger). "AUTOTEST pubtest: ..." in mod.log.
H.pubtest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local have = type(G.featSt) == "table" and type(G.featSt.optsText) == "string" and G.featSt.optsText or ""
	local line = "pubtest: the game's options " .. (have ~= "" and have or "none") .. (have:find("public=1", 1, true) and " (public on)" or " (PUBLIC NOT ON)")
	log("AUTOTEST " .. line)
	H.wintabs(from, { role = p.role, tabs = { "f_public", "session" } })
	table.insert(AUTO.results, 1, line)
end

-- (0.6) Statistics scenario (MPFEVER_SCENARIO=featstats, companies mode, best with MPFEVER_SPEED=4): the host's game switches the
-- options goal, stats and yearly on (MPFEVER_STATSOPTS: other options, "id=1;id.param=v;..."), as its lobby would, and every game
-- waits for game months measured by the host (two on the host, one more on the client, MPFEVER_STATSSECONDS at most, 170 by
-- default) and tells what it holds: the options, the months, the last figures, the goal, the window's file, whether this game sent
-- figures (the host only). The games' results must show the same figures; the launcher's checks say whether they stayed alike.
H.featstats = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if not K.FEAT then AUTO.results[1] = "featstats: the game options are off here (MPFEVER_FEAT=0)"; return autoFinish() end
	if C.ROLE == "host" then
		G.featOpts = os.getenv("MPFEVER_STATSOPTS") or "goal=1;goal.target=10;goal.years=5;stats=1;yearly=1"
		G.featOptsAt = nil
		log("AUTOTEST featstats: the host asks for the options " .. G.featOpts)
	end
	local want = C.ROLE == "host" and 2 or 1
	local secs = tonumber(os.getenv("MPFEVER_STATSSECONDS") or "") or 170
	local untilFrame = G.frames + secs * 60
	local seen, first = 0, nil
	local function stats()
		local st = G.featSt
		return st, type(st) == "table" and type(st.feat) == "table" and st.feat.stats or nil
	end
	local function report()
		local st, s = stats()
		local R1 = AUTO.results
		R1[#R1 + 1] = "featstats: options " .. tostring(st and st.optsText) .. " (" .. tostring(st and st.optsMode) .. ")"
		if type(s) ~= "table" then R1[#R1 + 1] = "featstats: NO STATE"; return autoFinish() end
		R1[#R1 + 1] = "featstats: months measured " .. seen .. " here (last " .. tostring(s.last) .. ", due " .. tostring(s.due) .. ", " .. #(s.m or {}) .. " kept, " .. #(s.y or {}) .. " year(s))"
		R1[#R1 + 1] = "featstats: last figures " .. tostring(s.m and s.m[#s.m])
		local g = s.goal
		R1[#R1 + 1] = "featstats: goal " .. (type(g) == "table" and (tostring(g.seq) .. " " .. tostring(g.state) .. " " .. tostring(g.crit) .. " target " .. tostring(g.target)
			.. " months " .. tostring(g.startM) .. "-" .. tostring(g.endM) .. " calendar end " .. tostring(g.endYM) .. " winner " .. tostring(g.winner)) or "none")
		local f = C.IO.open(C.DIR .. BS .. "feat_stats_main.txt", "rb")
		local text = f and f:read("*a") or nil
		if f then f:close() end
		R1[#R1 + 1] = "featstats: window file " .. (text and (#text .. " bytes") or "MISSING")
		local F = C.feat()
		local SM = F and F.byId and F.byId.stats
		R1[#R1 + 1] = "featstats: this game sent figures: " .. ((SM and SM.g and SM.g.sentFor) and ("yes, last month " .. SM.g.sentFor) or "no")
		for _, l in ipairs(R1) do log("AUTOTEST " .. l) end
		autoFinish()
	end
	local function poll()
		local _, s = stats()
		local last = type(s) == "table" and s.last or nil
		if last and last ~= first then
			if first ~= nil or C.ROLE == "host" then seen = seen + 1 end
			first = last
			log("AUTOTEST featstats: month " .. last .. " measured here (" .. seen .. " of " .. want .. ")")
		end
		if seen >= want or G.frames >= untilFrame then return report() end
		G.waits[#G.waits + 1] = { at = G.frames + 120, fn = poll }
	end
	poll()
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

-- Companies scenario (companies mode): this company gives 12345 to another company, takes another free colour, and greens an
-- industry from the company window (a "Companies" event, refused for the other companies before 0.4.4)
H.cofeat = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local reg = G.co
	if not (reg and G.myCo) then AUTO.results = { "cofeat: not in the companies mode" }; return autoFinish() end
	local other = nil
	for _, c in ipairs(reg.list) do if c.id ~= G.myCo and c.ent and not other then other = c end end
	local mine = CO.find(reg, G.myCo)
	if not (other and mine and mine.ent) then AUTO.results = { "cofeat: no other company" }; return autoFinish() end
	local function bal(e) local ok, b = pcall(api.engine.util.finance.getPlayersBalance, e) return ok and b or nil end
	local b0, o0 = bal(mine.ent), bal(other.ent)
	uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "give", [4] = { to = other.id, amount = 12345 } })
	local free = nil
	for ix = #CO.PALETTE, 1, -1 do if not free and CO.colorFree(reg, ix, mine.id) and ix ~= mine.color then free = ix end end
	if free then uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "recolor", [4] = { color = free } }) end
	local ind = R.entitiesWith("INDUSTRY")[1 + (C.ROLE == "host" and 0 or 1)]
	if ind then
		uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "", [2] = "Companies", [3] = "MakeGreen", [4] = { companyEntity = mine.ent, constructionEntity = ind } })
	end
	G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
		local b1, o1 = bal(mine.ent), bal(other.ent)
		AUTO.results[#AUTO.results + 1] = "gift: company " .. mine.id .. " " .. tostring(b0) .. " -> " .. tostring(b1) .. ", company " .. other.id .. " " .. tostring(o0) .. " -> " .. tostring(o1)
		local m2 = G.co and CO.find(G.co, G.myCo)
		AUTO.results[#AUTO.results + 1] = "colour: asked " .. tostring(free) .. ", now " .. tostring(m2 and m2.color)
		local eco = nil
		pcall(function()
			local e = api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/emission/emissions.gs")
			local stt = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT).state
			eco = stt and stt.ecoLevels and stt.ecoLevels[ind] ~= nil
		end)
		AUTO.results[#AUTO.results + 1] = "green industry " .. tostring(ind) .. ": " .. tostring(eco)
		for _, r in ipairs(AUTO.results) do log("AUTOTEST " .. r) end
		autoFinish()
	end }
end

-- Mixed modes scenario (MPFEVER_SCENARIO=coeco, companies mode, the host with MPFEVER_COAUTO=1 and MPFEVER_LOTSECONDS=8): the
-- host opens its tracks for a toll; the client asks to join company 1 (the host's chief accepts), leaves it (a new company),
-- offers to merge it into company 1 (accepted), leaves again; then company 1 goes bankrupt (its first two lots at auction): the
-- client bids on the first, nobody on the second. The checks then say whether every game did the same.
H.coeco = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function ev(name, param) uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = name, [4] = param }) end
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST " .. t) end
	if not (G.co and G.myCo) then note("coeco: not in the companies mode"); return autoFinish() end
	if C.ROLE == "host" then
		-- (0.5.2: tracks are open when nothing was set, expect "open 1000" here)
		local r0 = C.eco() and C.eco().trackRule(G.co, CO.find(G.co, G.myCo))
		note("host: tracks of company " .. tostring(G.myCo) .. " before: " .. tostring(r0 and r0.rule) .. " " .. tostring(r0 and r0.toll))
		ev("co_track_rule", { rule = "toll", toll = 1500 })
		G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
			local r = C.eco() and C.eco().trackRule(G.co, CO.find(G.co, G.myCo))
			note("host: tracks of company " .. tostring(G.myCo) .. ": " .. tostring(r and r.rule) .. " " .. tostring(r and r.toll))
			autoFinish()
		end }
		return
	end
	-- the client: a list of steps, each waiting for its condition (at most 40 s)
	local steps = {}
	local function step(what, start, done) steps[#steps + 1] = { what = what, start = start, done = done } end
	local first = nil
	step("join company 1", function() first = G.myCo; ev("co_join_ask", { to = 1 }) end, function() return G.myCo == 1 end)
	step("leave company 1", function() ev("co_leave", {}) end, function() return G.myCo ~= nil and G.myCo ~= 1 end)
	step("merge into company 1", function() ev("co_merge_ask", { to = 1 }) end, function() return G.myCo == 1 end)
	step("leave again", function() ev("co_leave", {}) end, function() return G.myCo ~= nil and G.myCo ~= 1 end)
	step("company 1 bankrupt", function() ev("co_test", { op = "bankrupt", co = 1, maxLots = 2 }) end,
		function() local c1 = CO.find(G.co, 1); return c1 and c1.gone == "bankrupt" and G.co.auction ~= nil end)
	step("bid on lot 1", function()
			local au = G.co.auction
			local lot = au and au.lots[au.idx]
			if lot then ev("co_bid", { seq = au.seq, lot = au.idx, amount = lot.reserve }) end
		end,
		function() local au = G.co.auction; return au and au.bidder == G.myCo end)
	step("auction over", function() end, function() return G.co.auction == nil end)
	-- MPFEVER_COECO_UNTIL=join or merge: the client stops once it is a member of company 1 again, right after its join or after
	-- its merger, so that a resynchronisation chained after it (MPFEVER_SCENARIO=coeco,resync,cocheck) reloads a company 1 with
	-- two members. On one PC (two games, one Steam account) that reload once gave the client a new company (see CO.join).
	local stopAfter = ({ join = "join company 1", merge = "merge into company 1" })[os.getenv("MPFEVER_COECO_UNTIL") or ""]
	if stopAfter then
		for k, s in ipairs(steps) do
			if s.what == stopAfter then
				for j = #steps, k + 1, -1 do table.remove(steps, j) end
				break
			end
		end
	end
	local i, since = 0, 0
	local function nextStep()
		i = i + 1
		local s = steps[i]
		if not s then
			note("client plays company " .. tostring(G.myCo) .. " (first " .. tostring(first) .. ")")
			for _, c in ipairs(G.co.list) do
				local m = {}
				for _, x in ipairs(CO.members(c)) do m[#m + 1] = x.key end
				note("company " .. c.id .. " " .. tostring(c.gone or "playing") .. " members " .. table.concat(m, ","))
			end
			G.waits[#G.waits + 1] = { at = G.frames + 600, fn = autoFinish }
			return
		end
		pcall(s.start)
		since = G.frames
		local function poll()
			local ok, d = pcall(s.done)
			if ok and d then note("step '" .. s.what .. "': done in " .. (G.frames - since) .. " frames"); return nextStep() end
			if G.frames - since > 2400 then note("step '" .. s.what .. "': NOT DONE within 40 s"); return nextStep() end
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
		end
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
	end
	nextStep()
end

-- Companies after a reload (MPFEVER_SCENARIO=coeco,resync,cocheck with MPFEVER_COECO_UNTIL=join or merge, companies mode, the host
-- with MPFEVER_COAUTO=1): each game waits until its joins are done (at most 30 s), then notes the company it plays, each
-- company's members and chief, and the registry's signature (what the checks compare). With MPFEVER_COECO_UNTIL set, the client
-- must still play company 1, with the host, and no company may have a member written twice.
H.cocheck = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST " .. t) end
	local since = G.frames
	local function poll()
		local pending = G.coBusy ~= nil
		for _, q in ipairs(G.nativeQueue) do if q.fn == "mpfCoJoin" then pending = true end end
		if (pending or not (G.co and G.myCo)) and G.frames - since < 1800 then
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
			return
		end
		if not (G.co and G.myCo) then note("cocheck: not in the companies mode"); return autoFinish() end
		note(C.ROLE .. " plays company " .. tostring(G.myCo) .. (pending and " (a join still under way after 30 s)" or ""))
		local twice = 0
		for _, c in ipairs(G.co.list) do
			local m, seen = {}, {}
			for _, x in ipairs(CO.members(c)) do
				local k = tostring(x.key)
				m[#m + 1] = k
				if seen[k] then twice = twice + 1 end
				seen[k] = true
			end
			note("company " .. c.id .. " " .. tostring(c.gone or "playing") .. " members " .. table.concat(m, ",") .. " chief " .. tostring(CO.chief(c)))
		end
		note("registry " .. CO.signature(G.co))
		note("members written twice: " .. twice .. (twice > 0 and " (WRONG)" or ""))
		local stopAfter = os.getenv("MPFEVER_COECO_UNTIL")
		if C.ROLE ~= "host" and (stopAfter == "join" or stopAfter == "merge") then
			note("client still in company 1 after the reload: " .. (G.myCo == 1 and "yes" or ("NO (company " .. tostring(G.myCo) .. ")")))
		end
		G.waits[#G.waits + 1] = { at = G.frames + 300, fn = autoFinish }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
end

-- (0.6) Trade scenario (MPFEVER_SCENARIO=tradetest with MPFEVER_TOGETHER=1, companies mode, the host with MPFEVER_COAUTO=1, on a
-- COPY of a test savegame whose savegame company has a line, a station or a depot): the host's game switches the options "sales"
-- and "contracts" on for this session (as its lobby would: G.featOpts), then offers its first line (else its first station, else
-- its first depot) to the client's company for 1000, through the trade module's request (its chief check included); the client's
-- game accepts it. Each game then notes the lots of both companies and their money (both games must note the same). Then the
-- client offers a supply contract (the host delivers a cargo at the client's first station, 10 a month for 3 months, 5 a unit),
-- which the host's game signs. The checks then say whether every game did the same (mpfever_feat_trade.lua).
H.tradetest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST " .. t) end
	local F, E = C.feat(), C.eco()
	if not (F and E) then note("tradetest: no options host"); return autoFinish() end
	F.load(log)
	local TR = F.byId.trade
	if not TR then note("tradetest: no trade module"); return autoFinish() end
	if C.ROLE == "host" then G.featOpts = F.canon("contracts=1;sales=1", "separate") end
	local function S() return G.featSt and G.featSt.feat and G.featSt.feat.trade end
	local function req(kind, t) F.request("trade", kind, TR.encode(t), G.featSt or {}, G.featBridge()) end
	local function otherCo()
		for _, c in ipairs(G.co.list) do if c.id ~= G.myCo and c.ent and not c.gone and not E.isAi(c) then return c end end
		return nil
	end
	local function lotsOf(id)
		local c = CO.find(G.co, id)
		if not (c and c.ent) then return {} end
		local ok, l = pcall(E.lotsOf, { R = R, log = log, CO = CO }, c)
		return ok and l or {}
	end
	local function holdings(tag)
		for _, id in ipairs({ G.myCo, (otherCo() or {}).id }) do
			local c = CO.find(G.co, id)
			if c and c.ent then
				local n = { line = 0, station = 0, depot = 0 }
				for _, l in ipairs(lotsOf(id)) do n[l.kind] = (n[l.kind] or 0) + 1 end
				local okB, b = pcall(api.engine.util.finance.getPlayersBalance, c.ent)
				note(tag .. ": company " .. id .. " has " .. n.line .. " line(s), " .. n.station .. " station(s), " .. n.depot .. " depot(s), money "
					.. tostring(okB and math.floor(b) or "?"))
			end
		end
		local s = S()
		note(tag .. ": trade state: seq " .. tostring(s and s.seq) .. ", " .. #(s and s.offers or {}) .. " offer(s), " .. #(s and s.ct or {}) .. " contract(s)")
	end
	local steps, offerId, myLot = {}, nil, nil
	local function step(what, start, done) steps[#steps + 1] = { what = what, start = start, done = done } end
	-- (the client's company may come a moment after the scenario starts: MPFEVER_TOGETHER starts both at once)
	step("a company here", function() end, function() return G.co ~= nil and G.myCo ~= nil end)
	step("options on", function() end, function() local o = G.featSt and G.featSt.opts; return o and o.sales == "1" and o.contracts == "1" end)
	if C.ROLE == "host" then
		step("offer a lot", function()
				local other = otherCo()
				for _, l in ipairs(lotsOf(G.myCo)) do if not myLot or (l.kind == "line" and myLot.kind ~= "line") then myLot = l end end
				if not (other and myLot) then note("host: nothing to offer (company " .. tostring(other and other.id) .. ")"); return end
				note("host offers " .. myLot.kind .. " '" .. tostring(myLot.label) .. "' (" .. tostring(myLot.vehicles or 0) .. " vehicle(s)) to company " .. other.id)
				holdings("before")
				req("offer", { to = other.id, kind = myLot.kind, key = myLot.key, price = 1000 })
			end,
			function()
				for _, o in ipairs((S() or {}).offers or {}) do if o.from == G.myCo and myLot and o.key == myLot.key then offerId = o.id; return true end end
				return false
			end)
		step("sold", function() end, function()
			for _, o in ipairs((S() or {}).offers or {}) do if o.id == offerId then return false end end
			return true
		end)
		local signed = {}
		step("sign the client's contract", function() end, function()
			for _, c in ipairs((S() or {}).ct or {}) do
				if c.state == "offer" and c.by ~= G.myCo and not signed[c.id] then signed[c.id] = true; req("ct_answer", { id = c.id, accept = true }) end
				if c.state == "active" then return true end
			end
			return false
		end)
	else
		step("accept the offer", function() end, function()
			for _, o in ipairs((S() or {}).offers or {}) do
				if o.to == G.myCo then
					if offerId ~= o.id then offerId = o.id; holdings("before"); req("answer", { id = o.id, accept = true }) end
					return false
				end
			end
			return offerId ~= nil
		end)
		step("offer a contract", function()
				local other = otherCo()
				local station = nil
				for _, l in ipairs(lotsOf(G.myCo)) do if l.kind == "station" and not station then station = l end end
				local cargos = TR.rt.cargos()
				local cargo = nil
				for _, x in ipairs(cargos) do if x.name == "COAL" then cargo = x end end
				cargo = cargo or cargos[1]
				if not (other and station and cargo) then note("client: no contract offered (station " .. tostring(station and station.key) .. ", cargo " .. tostring(cargo and cargo.name) .. ")"); return end
				note("client offers a contract: company " .. other.id .. " delivers 10 " .. cargo.name .. " a month at " .. tostring(station.label))
				req("ct_offer", { to = other.id, role = "pay", station = station.key, cargo = cargo.name, per = 10, price = 5, penalty = 1, months = 3 })
			end,
			function() for _, c in ipairs((S() or {}).ct or {}) do if c.state == "active" then return true end end return false end)
	end
	local i, since = 0, 0
	local function nextStep()
		i = i + 1
		local s = steps[i]
		if not s then
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
				holdings("after")
				for _, n in ipairs((S() or {}).news or {}) do note("news " .. tostring(n.n) .. ": " .. tostring(n.kind) .. (n.why and (" " .. n.why) or "")) end
				G.waits[#G.waits + 1] = { at = G.frames + 300, fn = autoFinish }
			end }
			return
		end
		pcall(s.start)
		since = G.frames
		local function poll()
			local ok, d = pcall(s.done)
			if ok and d then note(C.ROLE .. ": step '" .. s.what .. "': done in " .. (G.frames - since) .. " frames"); return nextStep() end
			if G.frames - since > 2400 then note(C.ROLE .. ": step '" .. s.what .. "': NOT DONE within 40 s"); return nextStep() end
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
		end
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
	end
	nextStep()
end

-- Bankruptcy scenario (MPFEVER_SCENARIO=cobroke, companies mode, MPFEVER_BANKRUPT=3 for the host's rule): the client's company
-- spends all its money and 100000 more; the host's look at each new month counts it in debt; after 3 months it goes bankrupt
-- and the client gets a new company. Waits at most 12 minutes (the game's speed: MPFEVER_SPEED).
H.cobroke = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST " .. t) end
	if not (G.co and G.myCo) then note("cobroke: not in the companies mode"); return autoFinish() end
	if C.ROLE == "host" then note("host: rule " .. tostring((G.co.rules or {}).bankrupt) .. ", month " .. tostring(G.co.month) .. " (a month is " .. tostring(api.util.getDefaultMonthDuration()) .. " ms of game time)"); return autoFinish() end
	local first = G.myCo
	uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "co_test", [4] = { op = "broke", co = first } })
	local since = G.frames
	local lastDebt = nil
	local function poll()
		local c = CO.find(G.co, first)
		if c and c.debt ~= lastDebt then lastDebt = c.debt; note("company " .. first .. " in debt for " .. tostring(c.debt) .. " month(s) at t=" .. tostring(gameTime())) end
		if c and c.gone == "bankrupt" and G.myCo and G.myCo ~= first and not G.coNone then
			note("company " .. first .. " bankrupt after " .. math.floor((G.frames - since) / 60) .. " s; the client now plays company " .. tostring(G.myCo))
			G.waits[#G.waits + 1] = { at = G.frames + 900, fn = autoFinish }
			return
		end
		if G.frames - since > 60 * 720 then note("NOT bankrupt within 12 minutes (debt " .. tostring(c and c.debt) .. ")"); return autoFinish() end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }
end

-- Broke scenario (companies mode): the host's company is left 100000 in debt; the other scenarios then show whether another
-- company can still build with its own money
H.broke = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE ~= "host" then AUTO.results = { "host only" }; return autoFinish() end
	uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "broke", [4] = { x = 1 } })
	G.waits[#G.waits + 1] = { at = G.frames + 200, fn = function()
		pcall(function()
			local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
			AUTO.results[#AUTO.results + 1] = "host money " .. tostring(acc and acc.balance)
		end)
		autoFinish()
	end }
end

-- Buy2 scenario: two purchases a second apart, then each bought vehicle put on the line of the copied vehicle (as a
-- player does in the depot window); every game must end with the same vehicles (a purchase applied twice made a copy)
H.buy2 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local me = api.engine.util.getPlayer()
	local pick = nil
	for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) and tv.line and tv.line >= 0
			and (pick == nil or (R.ownerOf(v) == me and R.ownerOf(pick.v) ~= me)) then
			-- (a component read is only valid until the next one: its fields are copied now)
			pick = { v = v, depot = tv.depot, line = tv.line, cfg = C.marshal(tv.transportVehicleConfig) }
		end
	end
	if not pick then AUTO.results[#AUTO.results + 1] = "no vehicle with a depot and a line"; return autoFinish() end
	local before = {}
	for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do before[v] = true end
	for k = 1, 2 do
		G.waits[#G.waits + 1] = { at = G.frames + k * 45, fn = function()
			uiRequest("makeVehicleBuyCmd", { n = 3, [1] = me, [2] = pick.depot, [3] = C.deser(C.ser(pick.cfg)) })
		end }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
		local new = {}
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do if not before[v] then new[#new + 1] = v end end
		AUTO.results[#AUTO.results + 1] = "bought " .. #new .. " vehicle(s) (2 asked)"
		for i, v in ipairs(new) do
			G.waits[#G.waits + 1] = { at = G.frames + i * 20, fn = function() uiRequest("makeVehicleSetLineCmd", { n = 3, [1] = v, [2] = pick.line, [3] = 0 }) end }
		end
		G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
			for _, v in ipairs(new) do
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				AUTO.results[#AUTO.results + 1] = "vehicle " .. v .. " line " .. tostring(tv and tv.line)
			end
			autoFinish()
		end }
	end }
end

-- Sharemine scenario (companies mode): the client shares every station of its own (fee 500); pickcheck: each game asks its
-- interface whether the line tool may pick each station of another company (ui_mod.log "selftest window ... pickable")
H.sharemine = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE == "host" then AUTO.results = { "client only" }; return autoFinish() end
	local me = api.engine.util.getPlayer()
	local n = 0
	pcall(function()
		for _, sg in ipairs(R.entitiesWith("STATION_GROUP")) do
			if R.ownerOf(sg) == me then
				uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "share", [4] = { key = R.sgKey(sg), fee = 500 } })
				n = n + 1
				AUTO.results[#AUTO.results + 1] = "share " .. R.sgKey(sg)
			end
		end
	end)
	AUTO.results[#AUTO.results + 1] = "asked to share " .. n .. " station(s) of mine"
	G.waits[#G.waits + 1] = { at = G.frames + 240, fn = autoFinish }
end

H.pickcheck = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local me = api.engine.util.getPlayer()
	local list = {}
	pcall(function()
		for _, sg in ipairs(R.entitiesWith("STATION_GROUP")) do
			local o = R.ownerOf(sg)
			if o and o ~= me and o >= 0 then
				local key = R.sgKey(sg)
				local rule, fee = nil, 0
				if C.eco() then rule, fee = C.eco().stationRule(G.co or {}, key, CO.idOfEntity(G.co, o)) end
				if rule and rule ~= "private" and #list < 4 then list[#list + 1] = sg; AUTO.results[#AUTO.results + 1] = "foreign station " .. sg .. " " .. key .. " " .. rule .. " fee " .. fee end
			end
		end
	end)
	local i = 0
	local function nextOne()
		i = i + 1
		if not list[i] then return autoFinish() end
		local f = C.IO.open(C.DIR .. BS .. "ui_selftest.txt", "wb")
		if f then f:write(tostring(list[i])); f:close() end
		G.waits[#G.waits + 1] = { at = G.frames + 90, fn = nextOne }
	end
	nextOne()
end

-- Observe scenario: this game's own vehicles (line, next stop, state, speed) and the issues the game finds on its own lines
H.observe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local me = api.engine.util.getPlayer()
	pcall(function()
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			if R.ownerOf(v) == me then
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
				local sp = "?"
				pcall(function() sp = string.format("%.1f", mp.dyn.speed) end)
				AUTO.results[#AUTO.results + 1] = "vehicle " .. v .. ": line " .. tostring(tv and tv.line) .. " stop " .. tostring(tv and tv.stopIndex)
					.. " state " .. tostring(tv and tv.state) .. " speed " .. sp .. (mp and "" or " (no path)")
			end
		end
	end)
	pcall(function()
		local issues = api.engine.util.line.getLinesIssues(me, false)
		local n = 0
		for line, iss in pairs(issues or {}) do
			n = n + 1
			AUTO.results[#AUTO.results + 1] = "line issue " .. tostring(line) .. ": " .. C.ser(C.marshal(iss)):sub(1, 300)
		end
		AUTO.results[#AUTO.results + 1] = "lines with issues: " .. n
	end)
	AUTO.results[#AUTO.results + 1] = "station fees earned: " .. C.ser((G.co and G.co.shareIncome) or {})
	G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
end

-- Share scenario (companies mode): the host shares the stations of the save's first line (fee 1000 per stop); the client then
-- creates a line through them (scenario line) and pays for every stop
H.share = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- (0.5.2: the stations' own settings are in reg.stationRule)
	if C.ROLE ~= "host" then
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
			local t = 0
			for _ in pairs((G.co and G.co.stationRule) or {}) do t = t + 1 end
			AUTO.results[#AUTO.results + 1] = "stations shared seen here: " .. t
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
		for _ in pairs((G.co and G.co.stationRule) or {}) do t = t + 1 end
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

-- Station rules scenario (0.5.2; MPFEVER_SCENARIO=line,stoprule,stoprule in the companies mode, MPFEVER_SPEED=4 advised so that
-- the vehicles stop often): the client's line (scenario line) stops at the host's stations, open by default (free).
--  host, round 1: A) 15 s as they are: nothing earned, no vehicle followed (reg.vstop empty); B) its company's rule a toll of
--     500 per stop, 40 s: the earnings grow by multiples of 500, the first growth at most 500 per vehicle of the other companies'
--     lines (no round of a line charged at once); C) its rule open again and one station of the client's line private, 40 s: the
--     client's line keeps its stop there and pays 100 per stop (MPFEVER_PRIVATEFEE).
--  client, round 1: its line updated (a waiting time changed) while it keeps the private stop: refused on every game ("is
--     private" in both mod.logs, "refused" counted by the launcher, the waiting time unchanged); then 15 s of what it pays.
--  host, round 2: D) the station back to the company's rule (open), 15 s: nothing earned; E) its own toll of 1000, 25 s:
--     multiples of 1000; F) the company's rule open for every station (reset): no setting of its own left, 15 s: nothing earned,
--     no vehicle followed.
--  client, round 2: its line updated again: accepted now (the new waiting time is there).
-- The checkpoints and the launcher's last "sync:" line then say whether every game did the same.
H.stoprule = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function ev(name, param) uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = name, [4] = param }) end
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST stoprule " .. t) end
	local E = C.eco()
	if not (E and G.co and G.co.mode == "separate" and G.myCo and G.myEnt) then note("not in the companies mode"); return autoFinish() end
	G.stopruleRound = (G.stopruleRound or 0) + 1
	local round = G.stopruleRound
	local me, myEnt = G.myCo, G.myEnt
	local function sum(t) return math.floor(tonumber(t and t[tostring(me)]) or 0) end
	local function vstopCount() local n = 0; for _ in pairs((G.co and G.co.vstop) or {}) do n = n + 1 end; return n end
	local function ownCount()
		local n = 0
		for _, o in pairs((G.co and G.co.stationRule) or {}) do if type(o) == "table" and o.co == me then n = n + 1 end end
		return n
	end
	-- (the steps one after the other, real time: the launcher waits 180 s for each round)
	local steps, i = {}, 0
	local function nextStep()
		i = i + 1
		local s = steps[i]
		if not s then return autoFinish() end
		local okS, errS = pcall(s)
		if not okS then note("step " .. i .. " failed: " .. tostring(errS)); autoFinish() end
	end
	-- until cond() (at most `secs` seconds), then nextStep
	local function waitFor(what, cond, secs)
		local t0 = os.clock()
		local function look()
			local ok, yes = pcall(cond)
			if ok and yes then note(what .. ": applied after " .. string.format("%.1f", os.clock() - t0) .. " s"); return nextStep() end
			if os.clock() - t0 > secs then note(what .. ": NOT APPLIED after " .. secs .. " s"); return nextStep() end
			G.waits[#G.waits + 1] = { at = G.frames + 15, fn = look }
		end
		look()
	end
	-- what the company earns (field "shareIncome") or pays ("shareExpense") during `secs` seconds, looked at every 10 frames
	-- (a growth then holds one look of the fees, every 5 steps, most of the time): the whole sum, the first growth, and whether
	-- every growth is a multiple of `unit`
	local function sample(label, field, secs, unit, firstMax)
		local t0 = os.clock()
		local start = sum(G.co and G.co[field])
		local last, first, steps2, odd = start, nil, 0, 0
		local function look()
			local now = sum(G.co and G.co[field])
			if now ~= last then
				local d = now - last
				steps2 = steps2 + 1
				if not first then first = d end
				if unit and unit > 0 and d % unit ~= 0 then odd = odd + 1 end
				last = now
			end
			if os.clock() - t0 < secs then G.waits[#G.waits + 1] = { at = G.frames + 10, fn = look }; return end
			local t = label .. ": " .. field .. " +" .. (now - start) .. " in " .. secs .. " s (" .. steps2 .. " growth(s)"
				.. (unit and ("; not a multiple of " .. unit .. ": " .. odd) or "")
				.. (first and ("; first +" .. first) or "") .. (firstMax and first and (first <= firstMax and " (at most " .. firstMax .. ": OK)" or " (MORE THAN " .. firstMax .. ")") or "")
				.. "), vehicles followed " .. vstopCount()
			note(t)
			nextStep()
		end
		look()
	end
	if C.ROLE == "host" then
		-- the other companies' lines stopping at this company's stations: their vehicles, and one such station
		local nVeh, key, nLines = 0, nil, 0
		for _, l in ipairs(R.entitiesWith("LINE")) do
			local lo = R.ownerOf(l)
			if lo and lo ~= myEnt then
				local mineHere = false
				pcall(function()
					local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
					local sgs = {}
					for k = 1, #lc.stops do sgs[k] = lc.stops[k].stationGroup end
					for _, sg in ipairs(sgs) do
						if R.ownerOf(sg) == myEnt then
							mineHere = true
							local k = R.sgKey(sg)
							if not key and k:sub(1, 3) ~= "id:" then key = k end
						end
					end
				end)
				if mineHere then
					nLines = nLines + 1
					pcall(function() nVeh = nVeh + #api.engine.system.transportVehicleSystem.getLineVehicles(l) end)
				end
			end
		end
		note("round " .. round .. ": " .. nLines .. " line(s) of other companies stop at this company's stations, " .. nVeh .. " vehicle(s), station " .. tostring(key))
		if not key then note("no station of this company on another company's line (run the scenario line before)"); return autoFinish() end
		local function myRule() local r = G.co.stops and G.co.stops[tostring(me)]; return r and r.rule end
		local function stationOwn() local o = G.co.stationRule and G.co.stationRule[key]; return o and o.rule end
		if round == 1 then
			local r0, f0 = E.stationRule(G.co, key, me)
			note("A: station " .. key .. " " .. tostring(r0) .. " " .. tostring(f0) .. " (expected open)")
			steps = {
				function() sample("A open", "shareIncome", 15, nil, nil) end,
				function() ev("co_stop_rule", { rule = "toll", fee = 500 }); waitFor("B toll 500", function() return myRule() == "toll" end, 10) end,
				function() sample("B toll 500", "shareIncome", 40, 500, 500 * math.max(1, nVeh)) end,
				function()
					ev("co_stop_rule", { rule = "open" })
					ev("share", { key = key, rule = "private" })
					waitFor("C open, station private", function() return myRule() == "open" and stationOwn() == "private" end, 10)
				end,
				function() sample("C private, its lines pay " .. tostring(E.STOP_FEE_DEFAULT), "shareIncome", 40, E.STOP_FEE_DEFAULT, nil) end,
			}
		else
			steps = {
				function() ev("share", { key = key, rule = "co" }); waitFor("D station back to the company's rule", function() return stationOwn() == nil end, 10) end,
				function() sample("D open", "shareIncome", 15, nil, nil) end,
				function() ev("share", { key = key, rule = "toll", fee = 1000 }); waitFor("E station toll 1000", function() return stationOwn() == "toll" end, 10) end,
				function() sample("E toll 1000", "shareIncome", 25, 1000, 1000 * math.max(1, nVeh)) end,
				function() ev("co_stop_rule", { rule = "open", reset = true }); waitFor("F open for every station", function() return myRule() == "open" and ownCount() == 0 end, 10) end,
				function() sample("F open, reset", "shareIncome", 15, nil, nil) end,
				function() note("F: settings of its own left " .. ownCount() .. ", vehicles followed " .. vstopCount()); nextStep() end,
			}
		end
		return nextStep()
	end
	-- the client: its line that stops at another company's station
	local line = G.stopruleLine
	if not line then
		for _, l in ipairs(R.entitiesWith("LINE")) do
			if not line and R.ownerOf(l) == myEnt then
				pcall(function()
					local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
					local sgs = {}
					for k = 1, #lc.stops do sgs[k] = lc.stops[k].stationGroup end
					for _, sg in ipairs(sgs) do
						local o = R.ownerOf(sg)
						if o and o ~= myEnt and CO.idOfEntity(G.co, o) then line = l end
					end
				end)
			end
		end
		G.stopruleLine = line
	end
	if not line then note("no line of this company stops at another company's station (run the scenario line before)"); return autoFinish() end
	local function waiting() return api.engine.getComponent(line, api.type.ComponentType.LINE).stops[1].minWaitingTime end
	local before = waiting()
	local want = (before or 0) + 7
	note("round " .. round .. ": line " .. line .. ", stop 1 waits " .. tostring(before) .. ", asked " .. want)
	steps = {
		function()
			local lc = C.marshal(api.engine.getComponent(line, api.type.ComponentType.LINE))
			lc.stops[1].minWaitingTime = want
			lc.stops[1].maxWaitingTime = math.max(tonumber(lc.stops[1].maxWaitingTime) or 0, want + 60)
			uiRequest("makeLineUpdateCmd", { n = 2, [1] = line, [2] = lc })
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
				local now = waiting()
				note("line update " .. (now == want and "ACCEPTED" or "refused") .. " (stop 1 waits " .. tostring(now) .. "; expected "
					.. (round == 1 and "refused: a private station" or "accepted") .. ")")
				nextStep()
			end }
		end,
		function() sample("client pays", "shareExpense", 15, round == 1 and E.STOP_FEE_DEFAULT or nil, nil) end,
	}
	nextStep()
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

-- Tree groups described (MPFEVER_SCENARIO=assetdescribe, no build, any savegame, e.g. k98resync): the first 30 groups of trees
-- (AssetGroup) within 400 m of a dead end of the street network (else of the camera), each with its numbers of fat and thin
-- models, what 0.5.1 made of it (nil for a forest of thin models only: its removal was dropped, the 22:30 resync) and the new
-- description, found again here by its id and by its place alone (the octree search another game makes when the id differs).
-- Then what the engine made of the trees this game rebuilt for another player (after a treeerase, e.g.
-- MPFEVER_SCENARIO=treeerase,assetdescribe): an AssetGroup as the builder's trees, or not.
-- Check in mod.log ("AUTOTEST assetdescribe"): no "new nil", "by place" names the group itself, the same lines on both games.
H.assetdescribe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST assetdescribe " .. t) AUTO.results[#AUTO.results + 1] = t end
	local ok, err = pcall(function()
		-- (the first of the street network's first 10 dead ends with trees around: the same place on every game of one savegame;
		-- else the camera's place)
		local c, list = nil, {}
		local ends = deadEnds()
		for k = 1, math.min(10, #ends) do
			local q = nodePosition(ends[k])
			if not c and q then
				local l = R.assetsNear(q, 400, "ASSET_GROUP")
				if #l > 0 then c, list = q, l end
			end
		end
		if not c then
			pcall(function()
				local d = api.gui.camera.getCameraData()
				local x, y = d.x, d.y
				if x == nil then x, y = d[1], d[2] end
				if type(x) == "number" and type(y) == "number" then c = { x = x, y = y, z = 0 } end
			end)
			c = c or { x = 0, y = 0, z = 0 }
			list = R.assetsNear(c, 400, "ASSET_GROUP")
		end
		say(#list .. " tree group(s) within 400 m of " .. string.format("%.0f,%.0f", c.x, c.y))
		local n, thinOnly, oldNil, newNil, byId, byPlace = math.min(30, #list), 0, 0, 0, 0, 0
		for i = 1, n do
			local g = list[i]
			local nf, nt = R.instanceCounts(g)
			if nf == 0 and nt > 0 then thinOnly = thinOnly + 1 end
			local okO, old = pcall(R.describeAssetOld, g)
			if not (okO and old) then oldNil = oldNil + 1 end
			local okN, d = pcall(R.describe, "con", g)
			local line = "group " .. g .. ": fat " .. nf .. ", thin " .. nt .. ", 0.5.1 " .. ((okO and old) and "ok" or "nil") .. ", new "
			if okN and type(d) == "table" then
				local okI, i1 = pcall(R.resolve, d)
				local okP, i2 = pcall(R.resolve, { k = d.k, id = -1, p = d.p, m = d.m, bb = d.bb })
				i1, i2 = okI and i1 or nil, okP and i2 or nil
				if i1 == g then byId = byId + 1 end
				if i2 == g then byPlace = byPlace + 1 end
				local q = d.p
				line = line .. tostring(d.k) .. " " .. (q and string.format("%.2f,%.2f,%.2f", q.x, q.y, q.z or 0) or "without a place") .. " " .. tostring(d.m)
					.. " n " .. tostring(d.n) .. (d.ag and " ag" or "") .. (d.bb and " bbox" or "") .. ", by id " .. tostring(i1) .. ", by place " .. tostring(i2)
			else
				newNil = newNil + 1
				line = line .. "nil" .. (okN and "" or (" (" .. shortErr(d) .. ")"))
			end
			say(line)
		end
		say(string.format("summary: %d group(s), %d of thin models only, 0.5.1 nil %d, new nil %d, found by id %d, by place %d", n, thinOnly, oldNil, newNil, byId, byPlace))
		local rep = G.assetReplayed or {}
		if #rep == 0 then say("no tree rebuilt here for another player yet (run treeerase before this scenario)") end
		for _, e in ipairs(rep) do say("rebuilt trees " .. e .. ": " .. R.assetComponents(e)) end
	end)
	if not ok then say("error " .. shortErr(err)) end
	autoFinish()
end

-- Tree erase scenario (MPFEVER_SCENARIO=treeerase,newroad with MPFEVER_PAUSED=1, as the friends' bulldozer click on one tree of a
-- forest in a pause at 22:23): this game takes one tree out of a group of trees the way the bulldozer does, in ONE build: the group
-- removed, its other trees built again in one construction (the mod's asset construction here: a script cannot make one without a
-- file). The group is a small forest of thin models when there is one near the street network (the kind 0.5.1 could not describe).
-- MPFEVER_TREEERASE=whole removes the whole group (the bulldozer on a group of one tree: nothing added, a build 0.5.1 replayed
-- nowhere); =reforest sends the engine's own reforestation proposal (groups recycled into constructions without a file, as the tree
-- brush does) when it has groups to recycle, else one tree as by default; =lasttree takes the group's last tree out instead of its
-- first (the removal is then described by that tree, not by the first one the build keeps: the same checks as by default).
-- Check: this game logs "assets placed ... N removed, 0 not described" and "AUTOTEST treeerase ...: BUILT", then the group gone
-- ("here after the build: exists false", or its id taken again by the new trees); the other game "ASSET REPLAY ...: N removed (G):
-- BUILT" and "removed tree group(s) gone here: yes"; nowhere "asset removal not found" nor a resync; the newroad after it prints the
-- same "build ids" on both games. As 0.5.1 (MPFEVER_ASSETREF=0, MPFEVER_ASSETCAPTURE=0, MPFEVER_ASSETSTRICT=0): "0 removed" and the
-- build ids shifted by one, expected.
-- (autotest treeremove) The engine's own removal proposal for a group of trees (api.engine.util.proposal.createProposalRemove,
-- what the game's scripts use to demolish an industry): built by this game as a player's build, the other games replay it.
-- A script proposal with a group of trees in constructionsToRemove is refused ("Unknown exception", treeerase 2026-10-25).
H.treeremove = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST treeremove " .. t) AUTO.results[#AUTO.results + 1] = t end
	local ok, sent = pcall(function()
		local ends = deadEnds()
		local best = nil
		for j = 0, math.min(5, #ends - 1) do
			local q = nodePosition(ends[((p.offset or 0) * 13 + 5 + j * 7) % #ends + 1])
			for _, e in ipairs(q and R.assetsNear(q, 300, "ASSET_GROUP") or {}) do
				if R.isTreeGroup(e) and (best == nil or e < best) then best = e end
			end
		end
		local g = best
		if not g then say("no group of trees near the street network's dead ends") return false end
		local d = R.describe("con", g)
		if d and d.p then AUTO.points[#AUTO.points + 1] = { x = d.p.x, y = d.p.y, z = d.p.z or 0 } end
		local okP, P = pcall(api.engine.util.proposal.createProposalRemove, g, playerContext())
		-- (refused for a group of trees, "Unknown exception", 2026-10-25: a native proposal naming the group, as G.treeProposal;
		-- MPFEVER_TREEREMOVE=engine: the engine's removal only)
		if (not okP or not P) and os.getenv("MPFEVER_TREEREMOVE") ~= "engine" then
			say("group " .. g .. ": createProposalRemove " .. shortErr(P) .. ": a native proposal instead")
			okP, P = pcall(function()
				local q = api.type.Proposal.new()
				q.toRemove = { g }
				return q
			end)
		end
		if not okP or not P then say("group " .. g .. ": no removal proposal " .. shortErr(P)) return false end
		local nr = -1
		pcall(function() nr = P.toRemove_native:size() end)
		if nr < 0 then pcall(function() nr = #P.toRemove end) end
		say("group " .. g .. " (" .. R.assetComponents(g) .. "): the removal proposal removes " .. tostring(nr))
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			say("removal of group " .. g .. ": " .. (success and "BUILT" or ("refused " .. why)))
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
				say("group " .. g .. " here after the build: " .. (R.isTreeGroup(g) and "STILL HERE" or "gone"))
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end }
		end)
		return true
	end)
	if not ok then say("error " .. shortErr(sent)) end
	if not (ok and sent) then autoFinish() end
end

H.treeerase = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST treeerase " .. t) AUTO.results[#AUTO.results + 1] = t end
	local mode = os.getenv("MPFEVER_TREEERASE") or "onetree"
	local ok, sent = pcall(function()
		local P, what, g, kept = nil, nil, nil, {}
		if mode == "reforest" then
			for seed = 1, 5 do
				if not P then
					local okP, q = pcall(function() return api.engine.util.proposal.makeReforestationProposal(seed, 4, 10) end)
					local nr, na = 0, 0
					if okP and q then pcall(function() nr, na = #q.toRemove, #q.toAdd end) end
					if nr > 0 then
						P = q
						what = "reforestation (seed " .. seed .. "): " .. nr .. " group(s) recycled, " .. na .. " construction(s)"
						pcall(function()
							for i = 1, math.min(nr, 5) do
								local e = q.toRemove[i]
								local d = R.describe("con", e)
								say("recycled group " .. tostring(e) .. ": " .. R.assetComponents(e) .. ", described " .. (d and (tostring(d.k) .. (d.p and "" or " without a place")) or "nil"))
							end
						end)
					end
				end
			end
			if not P then say("reforestation: no group to recycle (no forest_mask, or no tile qualifies): one tree instead") end
		end
		if not P then
			-- (a small forest of thin models first, then the smallest group of two trees or more, then any)
			local ends = deadEnds()
			local best, bestScore = nil, nil
			for j = 0, math.min(5, #ends - 1) do
				local q = nodePosition(ends[((p.offset or 0) * 13 + 5 + j * 7) % #ends + 1])
				for _, e in ipairs(q and R.assetsNear(q, 300, "ASSET_GROUP") or {}) do
					if R.isTreeGroup(e) then
						local nf, nt = R.instanceCounts(e)
						local n = nf + nt
						local score = (nf == 0 and n >= 2 and n <= 200) and n or (n >= 2 and 1000 + n or 1000000)
						if n > 0 and (bestScore == nil or score < bestScore or (score == bestScore and e < best)) then best, bestScore = e, score end
					end
				end
			end
			g = best
			if not g then say("no group of trees within 300 m of the street network's dead ends") return false end
			-- its trees, each with its matrix (a thin model has an angle and a scale instead)
			local inst = {}
			R.eachInstance(g, function(id, q, it, thin)
				if not q then return end
				local tf
				if thin then
					local a, s = 0, 1
					pcall(function() a, s = it.rot or 0, it.scale or 1 end)
					local c, si = math.cos(a) * s, math.sin(a) * s
					tf = { c, si, 0, 0, -si, c, 0, 0, 0, 0, s, 0, q.x, q.y, q.z, 1 }
				else
					tf = {}
					local m = it.transf
					for k = 1, 16 do tf[k] = m[k] end
				end
				inst[#inst + 1] = { id = id, tf = tf }
			end)
			local d = R.describe("con", g)
			local old = R.describeAssetOld(g)
			say("group " .. g .. ": " .. R.assetComponents(g) .. ", " .. #inst .. " read; described " .. (d and (tostring(d.k) .. " " .. tostring(d.m) .. (d.p and "" or " without a place")) or "nil")
				.. "; 0.5.1 described it " .. (old and "with a place" or "NOT (nil)"))
			if d and d.p then AUTO.points[#AUTO.points + 1] = { x = d.p.x, y = d.p.y, z = d.p.z or 0 } end
			-- (a model of the game is named with "::/" for the mod's construction, see mpfever_asset.script)
			local function loadable(id)
				local raw = ""
				pcall(function() raw = tostring(api.res.modelRep.getName(id) or "") end)
				if raw:find("::", 1, true) then return raw end
				if raw:sub(1, 1) == "/" then return "::" .. raw end
				return "::/" .. raw
			end
			local sp = api.type.SimpleProposal.new()
			sp.constructionsToRemove = { g }
			if mode ~= "whole" and #inst >= 2 then
				-- (the first tree out, the others kept, relative to the first kept one; MPFEVER_TREEERASE=lasttree: the last tree out,
				-- the group's first kept: the removal must then be described by the felled tree, see R.describe's kept)
				local out = (mode == "lasttree") and #inst or 1
				local b = nil
				local models = {}
				for k = 1, #inst do
					if k ~= out then
						b = b or { x = inst[k].tf[13], y = inst[k].tf[14], z = inst[k].tf[15] }
						local t = {}
						for q = 1, 16 do t[q] = inst[k].tf[q] end
						t[13], t[14], t[15] = t[13] - b.x, t[14] - b.y, t[15] - b.z
						models[#models + 1] = { id = loadable(inst[k].id), transf = t }
					end
				end
				local V = api.type.Vec4f.new
				local ce = api.type.SimpleProposal.ConstructionEntity.new()
				ce.fileName = assetConName()
				ce.params = { mpfModels = models, seed = 1 }
				ce.transf = api.type.Mat4f.new(V(1, 0, 0, 0), V(0, 1, 0, 0), V(0, 0, 1, 0), V(b.x, b.y, b.z, 1))
				ce.playerEntity = api.engine.util.getPlayer()
				pcall(function() ce.name = "" end)
				sp.constructionsToAdd = { ce }
				kept = { ce }
				what = "one tree taken out of group " .. g .. " (" .. #models .. " kept tree(s) built again)"
			else
				what = "group " .. g .. " removed whole (" .. #inst .. " tree(s))"
			end
			P = sp
		end
		local function built(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			say(what .. ": " .. (success and "BUILT" or ("refused " .. why)))
			local made = {}
			pcall(function()
				for i = 1, #res.resultEntities do
					local e = res.resultEntities[i]
					if type(e) ~= "number" then e = e[1] end
					if type(e) == "number" then made[#made + 1] = e end
				end
			end)
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
				if g then
					local reused = false
					for _, e in ipairs(made) do if e == g then reused = true end end
					say("group " .. g .. " here after the build: " .. R.assetComponents(g)
						.. (reused and " (its id taken again by the new trees)" or (R.isTreeGroup(g) and " STILL HERE" or "")))
				end
				for i = 1, math.min(#made, 5) do say("made " .. made[i] .. ": " .. R.assetComponents(made[i])) end
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end }
		end
		-- (a script's proposal naming the group is refused by the factory: one native build as the bulldozer's, G.treeProposal;
		-- MPFEVER_TREENATIVE=0: the script's proposal, as before)
		if g and mode ~= "reforest" and os.getenv("MPFEVER_TREENATIVE") ~= "0" and os.getenv("MPFEVER_ASSETOLDFLAGS") ~= "1" then
			local function dry(cmd, cb)
				toSim("replaying", { nots = true })
				replaySend(cmd, cb)
			end
			G.treeProposal({ g }, kept, playerContext(), true, dry, function(cmd, how, builtDry)
				say(how)
				if not cmd then G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish } return end
				deferredSend(cmd, function(res, success) G.treeDryRes = nil built(res, success) end)
			end)
			return true
		end
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), built)
		return true
	end)
	if not ok then say("error " .. shortErr(sent)) end
	if not (ok and sent) then autoFinish() end
end

-- Waypoint scenario (issue #27): a waypoint added after the first stop of a train line, on a track its train drives on,
-- through the line window's command; then every game must have it
H.waypoint = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(function()
		AUTO.running = true
		AUTO.results = {}
		AUTO.points = {}
		-- a train on a line, and a track segment of its path (a waypoint is a place on a lane: the path's edge ids are such places)
		local pick = nil
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
			if tv and mp and type(tv.line) == "number" and tv.line >= 0 then
				if not AUTO.mpShown then
					AUTO.mpShown = true
					pcall(function() log("AUTOTEST waypoint: a vehicle's path " .. C.ser(C.marshal(mp.path)):sub(1, 700)) end)
				end
				local okp, errp = pcall(function()
					local edges = mp.path.edges
					AUTO.wpSeen = (AUTO.wpSeen or 0) + 1
					for i = math.max(1, math.floor(#edges / 2)), #edges do
						local eid = edges[i].edgeId
						local e = eid.entity
						local isEdge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) ~= nil
						local isStreet = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) ~= nil
						AUTO.wpEdges = (AUTO.wpEdges or 0) + (isEdge and 1 or 0)
						AUTO.wpStreets = (AUTO.wpStreets or 0) + (isStreet and 1 or 0)
						if isEdge and not isStreet then
							pick = pick or { line = tv.line, e = e, index = eid.index, veh = v }
							break
						end
						-- (else a street: the same kind of place on a lane, for a save without trains)
						if isEdge and not AUTO.wpStreet and os.getenv("MPFEVER_WP_STREET") then AUTO.wpStreet = { line = tv.line, e = e, index = eid.index, veh = v } end
					end
				end)
				if not okp and not AUTO.mpErr then AUTO.mpErr = true; log("AUTOTEST waypoint: path not read: " .. tostring(errp)) end
			end
			if pick and (C.ROLE == "host" or pick.veh ~= v) then break end
		end
		pick = pick or AUTO.wpStreet
		AUTO.wpStreet = nil
		if not pick then
			AUTO.results[#AUTO.results + 1] = "waypoint: no train on a track (vehicles on lines " .. tostring(AUTO.wpSeen) .. ", path edges that are segments "
				.. tostring(AUTO.wpEdges) .. ", streets " .. tostring(AUTO.wpStreets) .. ")"
			return autoFinish()
		end
		local function count()
			local n = 0
			pcall(function()
				local lc = api.engine.getComponent(pick.line, api.type.ComponentType.LINE)
				for i = 1, #lc.stops do n = n + #lc.stops[i].waypoints end
			end)
			return n
		end
		local before = count()
		local lc = C.marshal(api.engine.getComponent(pick.line, api.type.ComponentType.LINE))
		local wps = lc.stops[1].waypoints or {}
		wps[#wps + 1] = { tag = before + 10, edgePos = { edgeId = { entity = pick.e, index = pick.index }, param = (C.ROLE == "host") and 0.3 or 0.6 } }
		lc.stops[1].waypoints = wps
		uiRequest("makeLineUpdateCmd", { n = 2, [1] = pick.line, [2] = lc })
		log("AUTOTEST waypoint on line " .. pick.line .. ", track " .. pick.e .. " lane " .. tostring(pick.index) .. ", waypoints before " .. before)
		G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
			local line = "waypoint on line " .. pick.line .. ": waypoints " .. before .. " -> " .. count()
			log("AUTOTEST " .. line)
			AUTO.results[#AUTO.results + 1] = line
			autoFinish()
		end }
	end)
	if not ok then
		log("AUTOTEST waypoint failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "waypoint error " .. tostring(err)
		autoFinish()
	end
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

-- Names of another language scenario (issue #97): the given role names a station, a line and a vehicle on its own game only,
-- as a game of another language names what it builds; the checks after it say whether the other games took the host's names
-- (MPFEVER_NAMESYNC=0: they differ for good, "names" and "lines")
H.langnames = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- (only the host's names are sent: a name only another game has is not a case of the game, which names a new entity on every game)
	if C.ROLE ~= "host" then
		AUTO.results[1] = "nothing named here (the host's names count)"
		return autoFinish()
	end
	local picks = {}
	for _, k in ipairs({ "STATION_GROUP", "LINE", "TRANSPORT_VEHICLE" }) do
		local list = R.entitiesWith(k)
		if #list > 0 then picks[#picks + 1] = { k = k, e = list[(#list > 1) and 2 or 1] } end
	end
	for i, pk in ipairs(picks) do
		local nm = "MPF " .. C.ROLE .. " Sprache " .. i
		local ok, err = pcall(function() O.sendCommand(api.cmd.makeEntitySetNameCmd(pk.e, nm)) end)
		local line1 = pk.k .. " " .. pk.e .. " named here only: " .. (ok and nm or ("error " .. tostring(err)))
		log("AUTOTEST langnames " .. line1)
		AUTO.results[#AUTO.results + 1] = line1
	end
	-- (the checks after it decide; the scenario ends after four of them)
	G.waits[#G.waits + 1] = { at = G.frames + 60 * 45, fn = function()
		local same = 0
		for _, pk in ipairs(picks) do if R.nameOf(pk.e):find("MPF " .. C.ROLE .. " Sprache", 1, true) then same = same + 1 end end
		AUTO.results[#AUTO.results + 1] = same .. "/" .. #picks .. " names still this game's own"
		autoFinish()
	end }
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
	-- (p.defer: sent like a tool's build, held and shipped as a native build)
	local sendIt = p.defer and deferredSend or O.sendCommand
	sendIt(cmd, function(res, success)
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

-- the same split sent like a tool's build (native: the other games rebuild it from what is shipped)
H.dsplit = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.nodeConfigs = true
	p.defer = true
	local ok, err = pcall(runSplit, p)
	if not ok then
		log("SPLIT failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "split error " .. tostring(err)
		autoFinish()
	end
end

-- A segment a vehicle is on, cut in two by a new road (a native proposal, like a tool's), held and shipped as a native build.
-- MPFEVER_SPLITMAPS=1: with the tool's maps of which new segments replace the old one
H.dsplitbusy = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local busy, seen = {}, {}
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			pcall(function()
				local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
				local e = mp.path.edges[mp.dyn.pathPos.edgeIndex + 1].edgeId.entity
				local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if c and c.type == 0 and #c.objects == 0 and not seen[e] then
					local a, b = nodePosition(c.node0), nodePosition(c.node1)
					if a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 30 then seen[e] = true; busy[#busy + 1] = e end
				end
			end)
		end
		table.sort(busy)
		if #busy == 0 then AUTO.results[#AUTO.results + 1] = "dsplitbusy: no vehicle on a plain segment"; return autoFinish() end
		local E = busy[((C.ROLE == "host") and 0 or 1) % #busy + 1]
		local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local A, B = nodePosition(c.node0), nodePosition(c.node1)
		local M = { x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2 }
		local dx, dy = B.x - A.x, B.y - A.y
		local len = math.sqrt(dx * dx + dy * dy)
		local Q = { x = M.x - dy / len * 30, y = M.y + dx / len * 30 }
		Q.z = groundZ(Q.x, Q.y, M.z)
		local function seg(id, n0, n1, p0, p1, t0, t1)
			local e = api.type.SegmentAndEntity.new()
			e.entity = id
			e.type = 0
			local cc = e.comp
			cc.node0 = n0; cc.node1 = n1
			cc.tangent0 = vec(t0); cc.tangent1 = vec(t1)
			cc.position0 = vec(p0); cc.position1 = vec(p1)
			cc.type = 0; cc.typeIndex = -1
			cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
			cc.laneConfigs = c.laneConfigs
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po
			return e
		end
		local function node(id, q)
			local n = api.type.NodeAndEntity.new()
			n.entity = id
			local bn = n.comp; bn.position = vec(q); n.comp = bn
			return n
		end
		local half = { x = (B.x - A.x) / 2, y = (B.y - A.y) / 2, z = (B.z - A.z) / 2 }
		local side = { x = Q.x - M.x, y = Q.y - M.y, z = Q.z - M.z }
		local P = api.engine.util.proposal.makeSegmentsRemoveProposal({ E })
		local st = P.proposal
		st.addedNodes = { node(-1, M), node(-2, Q) }
		st.addedSegments = { seg(-3, c.node0, -1, A, M, half, half), seg(-4, -1, c.node1, M, B, half, half), seg(-5, -1, -2, M, Q, side, side) }
		local maps = os.getenv("MPFEVER_SPLITMAPS") == "1"
		if maps then
			st.new2oldSegments = { [-3] = { E }, [-4] = { E } }
			st.old2newSegments = { [E] = { -3, -4 } }
		end
		local ncr = {}
		for _, n in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = n end
		end
		if #ncr > 0 then st.nodeConfigsToRemove = ncr end
		P.proposal = st
		AUTO.points[#AUTO.points + 1] = M
		log("DSPLITBUSY segment " .. E .. " (" .. tostring(c.roadTemplate) .. "), " .. #busy .. " busy segments, maps " .. tostring(maps)
			.. ", removed nodes " .. #P.proposal.removedNodes)
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			log("DSPLITBUSY build: " .. (success and "BUILT" or ("refused " .. why)))
			AUTO.results[#AUTO.results + 1] = "busy split of " .. E .. ": " .. (success and "built" or ("refused " .. why))
			G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
		end)
	end)
	if not ok then
		log("DSPLITBUSY failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "dsplitbusy error " .. tostring(err)
		autoFinish()
	end
end

-- A node of two segments replaced by a node 2 m aside with a branch (as a tool joining a road to it does: the node and its two
-- segments are replaced by reshaped ones), a native proposal held and shipped as a native build. MPFEVER_SPLITMAPS=1: with
-- the tool's maps of which new node and segments replace the old ones
H.dnodemove = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local busy = {}
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
			pcall(function()
				local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
				busy[mp.path.edges[mp.dyn.pathPos.edgeIndex + 1].edgeId.entity] = true
			end)
		end
		local deg, segs = {}, {}
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if c then
				for _, n in ipairs({ c.node0, c.node1 }) do
					deg[n] = (deg[n] or 0) + 1
					segs[n] = segs[n] or {}
					segs[n][#segs[n] + 1] = e
				end
			end
		end
		local cands = {}
		for n, d in pairs(deg) do
			if d == 2 then
				local s1, s2 = segs[n][1], segs[n][2]
				local c1 = api.engine.getComponent(s1, api.type.ComponentType.BASE_EDGE)
				local c2 = api.engine.getComponent(s2, api.type.ComponentType.BASE_EDGE)
				if s1 ~= s2 and c1.type == 0 and c2.type == 0 and #c1.objects == 0 and #c2.objects == 0 and c1.roadTemplate == c2.roadTemplate
					and api.engine.getComponent(s1, api.type.ComponentType.BASE_EDGE_STREET) and api.engine.getComponent(s2, api.type.ComponentType.BASE_EDGE_STREET) then
					cands[#cands + 1] = { n = n, s1 = s1, s2 = s2, busy = (busy[s1] or busy[s2]) and 1 or 0 }
				end
			end
		end
		table.sort(cands, function(x, y) if x.busy ~= y.busy then return x.busy > y.busy end return x.n < y.n end)
		if #cands == 0 then AUTO.results[#AUTO.results + 1] = "dnodemove: no node of two plain segments"; return autoFinish() end
		local pick = cands[((C.ROLE == "host") and 0 or 1) % #cands + 1]
		local N, S1, S2 = pick.n, pick.s1, pick.s2
		local c1 = api.engine.getComponent(S1, api.type.ComponentType.BASE_EDGE)
		local c2 = api.engine.getComponent(S2, api.type.ComponentType.BASE_EDGE)
		local a = (c1.node0 == N) and c1.node1 or c1.node0
		local b = (c2.node0 == N) and c2.node1 or c2.node0
		local PA, PB, PN = nodePosition(a), nodePosition(b), nodePosition(N)
		local dx, dy = PB.x - PA.x, PB.y - PA.y
		local len = math.sqrt(dx * dx + dy * dy)
		local ux, uy = -dy / len, dx / len
		local N2 = { x = PN.x + ux * 2, y = PN.y + uy * 2, z = PN.z }
		local Q = { x = PN.x + ux * 30, y = PN.y + uy * 30 }
		Q.z = groundZ(Q.x, Q.y, PN.z)
		local function d(p0, p1) return { x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z } end
		local function seg(id, n0, n1, p0, p1, tmpl)
			local e = api.type.SegmentAndEntity.new()
			e.entity = id
			e.type = 0
			local cc = e.comp
			cc.node0 = n0; cc.node1 = n1
			cc.tangent0 = vec(d(p0, p1)); cc.tangent1 = vec(d(p0, p1))
			cc.position0 = vec(p0); cc.position1 = vec(p1)
			cc.type = 0; cc.typeIndex = -1
			cc.roadTemplate = tmpl.roadTemplate; cc.roadStyle = tmpl.roadStyle; cc.roadType = tmpl.roadType
			cc.laneConfigs = tmpl.laneConfigs
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po
			return e
		end
		local function node(id, q)
			local nn = api.type.NodeAndEntity.new()
			nn.entity = id
			local bn = nn.comp; bn.position = vec(q); nn.comp = bn
			return nn
		end
		local P = api.engine.util.proposal.makeSegmentsRemoveProposal({ S1, S2 })
		local st = P.proposal
		st.addedNodes = { node(-1, N2), node(-2, Q) }
		st.addedSegments = { seg(-3, a, -1, PA, N2, c1), seg(-4, -1, b, N2, PB, c2), seg(-5, -1, -2, N2, Q, c1) }
		local maps = os.getenv("MPFEVER_SPLITMAPS") == "1"
		if maps then
			st.new2oldNodes = { [-1] = { N } }
			st.old2newNodes = { [N] = { -1 } }
			st.new2oldSegments = { [-3] = { S1 }, [-4] = { S2 } }
			st.old2newSegments = { [S1] = { -3 }, [S2] = { -4 } }
		end
		local ncr = {}
		for _, n in ipairs({ a, b }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = n end
		end
		if #ncr > 0 then st.nodeConfigsToRemove = ncr end
		P.proposal = st
		AUTO.points[#AUTO.points + 1] = PN
		log("DNODEMOVE node " .. N .. " segments " .. S1 .. "," .. S2 .. " busy " .. pick.busy .. " (" .. tostring(c1.roadTemplate) .. "), maps " .. tostring(maps)
			.. ", removed nodes " .. #P.proposal.removedNodes)
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			log("DNODEMOVE build: " .. (success and "BUILT" or ("refused " .. why)))
			AUTO.results[#AUTO.results + 1] = "node move " .. N .. ": " .. (success and "built" or ("refused " .. why))
			G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
		end)
	end)
	if not ok then
		log("DNODEMOVE failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "dnodemove error " .. tostring(err)
		autoFinish()
	end
end

-- A signal put on a track like the signal tool does (its segment replaced by a copy carrying the new signal, no street graph
-- cleanup), held and shipped as a native build: the other games replay it. MPFEVER_DSIGNALBRIDGE=1: on a track bridge (issue #85)
H.dsignal = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- (MPFEVER_DSIG_ROLE=host or client: only that game puts a signal, the other only replays it)
	local onlyRole = os.getenv("MPFEVER_DSIG_ROLE")
	if onlyRole and onlyRole ~= C.ROLE then
		AUTO.results[#AUTO.results + 1] = "dsignal: not this game's turn (MPFEVER_DSIG_ROLE=" .. onlyRole .. ")"
		return autoFinish()
	end
	local ok, err = pcall(function()
		local list = {}
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			local bridge = os.getenv("MPFEVER_DSIGNALBRIDGE") == "1"
			if c and c.type == (bridge and 1 or 0) and #c.objects == 0 and not api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) then
				local a, b = nodePosition(c.node0), nodePosition(c.node1)
				if a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > (bridge and 12 or 40) then list[#list + 1] = e end
			end
		end
		if #list == 0 then AUTO.results[#AUTO.results + 1] = "dsignal: no free track segment"; return autoFinish() end
		-- (MPFEVER_DSIG_INDEX: which of the free segments, the same on every game)
		local E = list[(tonumber(os.getenv("MPFEVER_DSIG_INDEX") or "") or ((C.ROLE == "host") and 7 or 23)) % #list + 1]
		local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		local e = api.type.SegmentAndEntity.new()
		e.entity = -1
		e.type = 1
		local cc = e.comp
		cc.node0 = c.node0; cc.node1 = c.node1
		cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
		-- (the segment's own ends, as the signal tool copies them, see G.autoSegEnds)
		cc.position0, cc.position1 = G.autoSegEnds(c)
		cc.type = c.type; cc.typeIndex = c.typeIndex
		pcall(function() if c.distance ~= 0 then cc.distance = c.distance end end)
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		cc.laneConfigs = c.laneConfigs
		cc.objects = { { -400000000, 2 } }
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po
		-- (MPFEVER_DSIGEMIT=1, diagnostic: the segment's emission emitter given to its copy, as the signal tool's proposal has it)
		if os.getenv("MPFEVER_DSIGEMIT") == "1" then
			local oke, ee = pcall(function()
				local em = api.engine.getComponent(E, api.type.ComponentType.EMISSION_EMITTER)
				if not em then return "none on the segment" end
				e.emissionEmitter = em
				return "copied"
			end)
			log("DSIGNAL emission emitter: " .. (oke and tostring(ee) or shortErr(ee)))
		end
		local eo = api.type.SimpleStreetProposal.EdgeObject.new()
		eo.edgeEntity = -1
		eo.param = 0.5
		eo.oneWay = false
		eo.left = true
		eo.model = "infrastructure/signal/signal_path_a.con"
		eo.playerEntity = api.engine.util.getPlayer()
		eo.name = "MPF signal"
		-- (MPFEVER_DSIGPARAMS=1, diagnostic: whether a script's signal can carry the construction params the signal tool gives it)
		if os.getenv("MPFEVER_DSIGPARAMS") == "1" then
			local okm, mem = pcall(C.members, eo)
			log("DSIGNAL edge object members: " .. (okm and type(mem) == "table" and table.concat(mem, ",") or tostring(mem)))
			local okp, ep = pcall(function() eo.params = { oneWay = 1, year = 1948, seed = 0 } end)
			log("DSIGNAL params written: " .. tostring(okp) .. (okp and "" or (" " .. tostring(ep):sub(1, 160))))
		end
		ssp.edgesToRemove = { E }
		ssp.edgesToAdd = { e }
		ssp.edgeObjectsToAdd = { eo }
		sp.streetProposal = ssp
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = false
		ctx.cleanupStreetGraph = false
		ctx.gatherBuildings = false
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		local p0 = nodePosition(c.node0)
		AUTO.points[#AUTO.points + 1] = p0
		local off0, off1 = G.autoEndsOff(c)
		log("DSIGNAL on track segment " .. E .. " (" .. tostring(c.roadTemplate) .. ")"
			.. (off0 and string.format(", its ends off its nodes by %.5f/%.5f m", off0, off1) or ""))
		local cmd = api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true)
		-- MPFEVER_SPLITMAPS=1: the command's own native proposal (the engine's conversion), with the map of the replaced segment
		-- added, as the signal tool's build has it
		if os.getenv("MPFEVER_SPLITMAPS") == "1" then
			local okc, P = pcall(function() return cmd.proposal end)
			log("DSIGNAL command's proposal: " .. tostring(okc) .. " " .. tostring(P):sub(1, 60))
			if okc and P then
				local okm, em = pcall(function()
					local st = P.proposal
					local newId = st.addedSegments[1].entity
					log("DSIGNAL converted: +segments " .. #st.addedSegments .. " (" .. tostring(newId) .. ") -segments " .. #st.removedSegments
						.. " objects " .. #st.edgeObjectsToAdd .. " maps " .. C.mapSizes({ proposal = { new2oldSegments = C.marshalMap(st.new2oldSegments), old2newSegments = C.marshalMap(st.old2newSegments) } }))
					st.new2oldSegments = { [newId] = { E } }
					st.old2newSegments = { [E] = { newId } }
					P.proposal = st
					cmd = api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true)
				end)
				log("DSIGNAL maps added: " .. (okm and "yes" or shortErr(em)))
			end
		end
		deferredSend(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			log("DSIGNAL build: " .. (success and "BUILT" or ("refused " .. why)))
			AUTO.results[#AUTO.results + 1] = "signal on segment " .. E .. ": " .. (success and "built" or ("refused " .. why))
			if success and os.getenv("MPFEVER_DSIGPARAMS") == "1" then
				-- (the nodes' ids now: a component is never kept across frames)
				local n0, n1 = cc.node0, cc.node1
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
					pcall(function()
						for _, s in ipairs(R.allEdges()) do
							local be = api.engine.getComponent(s, api.type.ComponentType.BASE_EDGE)
							if be and be.node0 == n0 and be.node1 == n1 then
								local em = api.engine.getComponent(s, api.type.ComponentType.EMISSION_EMITTER)
								local eline = "DSIGNAL new segment " .. s .. " emission emitter " .. (em and C.ser(C.marshal(em)):sub(1, 200) or "NONE")
								log(eline)
								AUTO.results[#AUTO.results + 1] = eline
								for _, o in ipairs(be.objects) do
									local ec = api.engine.getComponent(o[1], api.type.ComponentType.EDGE_OBJECT)
									local line = "DSIGNAL new signal " .. o[1] .. " params " .. C.ser(C.marshal(ec and ec.params))
									log(line)
									AUTO.results[#AUTO.results + 1] = line
								end
							end
						end
					end)
				end }
			end
			G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
		end)
	end)
	if not ok then
		log("DSIGNAL failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "dsignal error " .. tostring(err)
		autoFinish()
	end
end

-- Signals re-created on several track segments in ONE build (MPFEVER_SCENARIO=dsigmulti, the host then the client as builder;
-- MPFEVER_DSIG_ROLE=host or client: only that game builds): a chain of MPFEVER_DSIG_N (2, at most 8) consecutive plain track
-- segments, replaced by copies that carry a signal each, as the Auto Signals mod or a track upgrade of a signalled line builds it.
-- Held and shipped as a native build with the signal tool's flags (32): the other game replays it. As before (MPFEVER_EOINLINE=0
-- on the replaying game): the track, then one signal build per segment (1 + N builds, the entity ids then differ: "stops placed
-- again on a street build" in the replaying game's mod.log); by default: one native proposal with the engine's own signals ("edge
-- objects: the engine's conversion has 2N", "native street: with its N new stop(s)/signal(s)", "edge objects here N, originator N"). The
-- "build ids t=..." line of that build must be the same in both games' mod.log (MPFEVER_ENTWATCH=1 MPFEVER_ENTLOG=1: entseq.txt too).
H.dsigmulti = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("DSIGMULTI " .. t); AUTO.results[#AUTO.results + 1] = t end
	local only = os.getenv("MPFEVER_DSIG_ROLE")
	if only and only ~= "" and only ~= C.ROLE then say("only the " .. only .. " builds"); return autoFinish() end
	local ok, err = pcall(function()
		local k = math.max(1, math.min(8, math.floor(tonumber(os.getenv("MPFEVER_DSIG_N") or "2") or 2)))
		local BE = api.type.ComponentType.BASE_EDGE
		-- the segments at each node (streets and tracks)
		local at = {}
		local all = R.allEdges()
		for _, e in ipairs(all) do
			local c = api.engine.getComponent(e, BE)
			if c then
				for _, nd in ipairs({ c.node0, c.node1 }) do at[nd] = at[nd] or {}; at[nd][#at[nd] + 1] = e end
			end
		end
		-- (a plain track segment of nobody's construction, no signal on it yet, 30 m at least)
		local function free(e)
			local c = api.engine.getComponent(e, BE)
			if not c or c.type ~= 0 or #c.objects > 0 or api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) then return nil end
			local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
			if okC and type(con) == "number" and con >= 0 then return nil end
			local a, b = nodePosition(c.node0), nodePosition(c.node1)
			if not (a and b) or math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) < 30 then return nil end
			return c
		end
		-- k segments one after the other through nodes that join only those two segments (no switch on the way)
		local function chainFrom(e)
			local c = free(e)
			if not c then return nil end
			local chain, seen, node, cur = { e }, { [e] = true }, c.node1, e
			while #chain < k do
				local segs = at[node] or {}
				if #segs ~= 2 then return nil end
				local nxt = (segs[1] == cur) and segs[2] or segs[1]
				if seen[nxt] then return nil end
				local cn = free(nxt)
				if not cn then return nil end
				chain[#chain + 1] = nxt
				seen[nxt] = true
				node = (cn.node0 == node) and cn.node1 or cn.node0
				cur = nxt
			end
			return chain
		end
		local list = {}
		for _, e in ipairs(all) do if free(e) then list[#list + 1] = e end end
		table.sort(list)
		if #list == 0 then say("no free track segment"); return autoFinish() end
		local chain = nil
		local start = ((C.ROLE == "host") and 7 or 23) % #list
		for i = 0, #list - 1 do
			chain = chainFrom(list[(start + i) % #list + 1])
			if chain then break end
		end
		if not chain then say("no chain of " .. k .. " plain track segments"); return autoFinish() end
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		local edges, eos, touched, ncr = {}, {}, {}, {}
		for i, E in ipairs(chain) do
			local c = api.engine.getComponent(E, BE)
			local e = api.type.SegmentAndEntity.new()
			e.entity = -i
			e.type = 1
			local cc = e.comp
			cc.node0 = c.node0; cc.node1 = c.node1
			cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
			cc.position0 = vec(nodePosition(c.node0)); cc.position1 = vec(nodePosition(c.node1))
			cc.type = c.type; cc.typeIndex = c.typeIndex
			pcall(function() if c.distance ~= 0 then cc.distance = c.distance end end)
			pcall(function() if #c.edgeDecorations > 0 then cc.edgeDecorations = c.edgeDecorations end end)
			cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
			cc.laneConfigs = c.laneConfigs
			cc.objects = { { -400000000 - (i - 1), 2 } }
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po
			edges[i] = e
			local eo = api.type.SimpleStreetProposal.EdgeObject.new()
			eo.edgeEntity = -i
			eo.param = 0.5
			eo.oneWay = false
			eo.left = true
			eo.model = "infrastructure/signal/signal_path_a.con"
			eo.playerEntity = api.engine.util.getPlayer()
			eo.name = "MPF signal " .. i
			eos[i] = eo
			for _, nd in ipairs({ c.node0, c.node1 }) do
				if not touched[nd] then
					touched[nd] = true
					local okn, nc = pcall(function() return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end)
					if okn and nc then ncr[#ncr + 1] = nd end
				end
			end
		end
		ssp.edgesToRemove = chain
		ssp.edgesToAdd = edges
		ssp.edgeObjectsToAdd = eos
		if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
		sp.streetProposal = ssp
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = false
		ctx.cleanupStreetGraph = false
		ctx.gatherBuildings = false
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		local c1 = api.engine.getComponent(chain[1], BE)
		AUTO.points[#AUTO.points + 1] = nodePosition(c1.node0)
		say(k .. " signal(s) on track segments " .. table.concat(chain, ",") .. " (" .. tostring(c1.roadTemplate):match("[^/]*$") .. "), "
			.. #ncr .. " junction configuration(s) removed, edge objects on the map " .. G.eoCount())
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			say("build: " .. (success and "BUILT" or ("refused " .. why)) .. ", edge objects on the map " .. G.eoCount())
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = autoFinish }
		end)
		-- (shipped with the signal tool's flags, 32: nothing cleaned up, no terrain alignment, see pollNativeEvents)
		G.natCtx = G.natCtx or {}
		G.natCtx[100000 + G.autoBuildSeq] = 32
	end)
	if not ok then
		say("failed " .. shortErr(err))
		autoFinish()
	end
end

-- Which form of a stop's replay shapes the ground on a bridge or in a tunnel (MPFEVER_SCENARIO=bridgestopprobe, on each game in
-- turn, nothing built, nothing shipped: the games stay alike): for each segment, a two-sided stop of the stop tool as replayStop
-- would replay it, and the native forms; their terrain alignment by the engine's proposal data, without building (G.stopAlignProbe,
-- "STOPALIGNPROBE" lines). MPFEVER_PROBE_SEGMENT=id,id...: those segments (a track gets a signal); MPFEVER_PROBE_AT=x,y[,r]: the
-- bridge and tunnel street segments with an end within r m (40) of x,y; else MPFEVER_PROBE_COUNT (4) bridge and tunnel street
-- segments of the map, those at an end of a bridge first (a segment in the middle of a high bridge replayed at 0/0 even with the
-- old way). MPFEVER_PROBE_MODEL: the stop's model (stations/street/small_stops/small_old_twosided.con).
H.bridgestopprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("BRIDGESTOPPROBE " .. t); AUTO.results[#AUTO.results + 1] = t end
	local ok, err = pcall(function()
		local BE = api.type.ComponentType.BASE_EDGE
		local list = {}
		local want = os.getenv("MPFEVER_PROBE_SEGMENT")
		if want and want ~= "" then
			for id in want:gmatch("%d+") do
				local e = tonumber(id)
				local okc, c = pcall(function() return api.engine.getComponent(e, BE) end)
				if okc and c then list[#list + 1] = e else say("segment " .. id .. " is not here") end
			end
		else
			local ax, ay, ar = nil, nil, 40
			local pat = os.getenv("MPFEVER_PROBE_AT")
			if pat then
				local x, y, r = pat:match("^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,?%s*([%d%.]*)")
				ax, ay, ar = tonumber(x), tonumber(y), tonumber(r) or 40
			end
			local n2s = {}
			local all = R.allEdges()
			for _, e in ipairs(all) do
				local c = api.engine.getComponent(e, BE)
				if c then
					for _, nd in ipairs({ c.node0, c.node1 }) do n2s[nd] = n2s[nd] or {}; n2s[nd][#n2s[nd] + 1] = e end
				end
			end
			local ends, mids = {}, {}
			for _, e in ipairs(all) do
				local c = api.engine.getComponent(e, BE)
				local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
				if c and c.type ~= 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) and not (okC and type(con) == "number" and con >= 0) then
					local near = true
					if ax then
						near = false
						for _, nd in ipairs({ c.node0, c.node1 }) do
							local q = nodePosition(nd)
							if q and math.sqrt((q.x - ax) ^ 2 + (q.y - ay) ^ 2) <= ar then near = true end
						end
					end
					if near then
						-- (an end of the bridge: a segment on the ground at one of its nodes)
						local isEnd = false
						for _, nd in ipairs({ c.node0, c.node1 }) do
							for _, s in ipairs(n2s[nd] or {}) do
								local cs = s ~= e and api.engine.getComponent(s, BE)
								if cs and cs.type == 0 then isEnd = true end
							end
						end
						if isEnd then ends[#ends + 1] = e else mids[#mids + 1] = e end
					end
				end
			end
			table.sort(ends)
			table.sort(mids)
			local cap = math.max(1, tonumber(os.getenv("MPFEVER_PROBE_COUNT") or "4") or 4)
			for _, e in ipairs(ends) do if #list < cap then list[#list + 1] = e end end
			for _, e in ipairs(mids) do if #list < cap then list[#list + 1] = e end end
			say(#ends + #mids .. " bridge or tunnel street segment(s)" .. (ax and string.format(" near %.1f,%.1f", ax, ay) or "") .. ", " .. #ends .. " at an end")
		end
		if #list == 0 then say("no segment to probe"); return autoFinish() end
		local model = os.getenv("MPFEVER_PROBE_MODEL") or "stations/street/small_stops/small_old_twosided.con"
		for _, E in ipairs(list) do
			local c = api.engine.getComponent(E, BE)
			local track = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE_STREET) == nil
			local objs
			if track then
				objs = { { model = "infrastructure/signal/signal_path_a.con", category = 2, param = 0.5, left = true, oneWay = false } }
			else
				objs = { { model = model, category = 0, param = 0.5, left = true, oneWay = false }, { model = model, category = 0, param = 0.5, left = false, oneWay = false } }
			end
			local owner = R.ownerOf(E)
			local plan = { E = E, seg = { comp = {}, playerOwned = (type(owner) == "number" and owner >= 0) and { player = owner } or nil }, objs = objs,
				removeIdx = {}, nodeConfigs = {}, segType = track and 1 or 0, probeOnly = true, probeSink = say }
			say("segment " .. E .. " (" .. tostring(c.roadTemplate):match("[^/]*$") .. ", type " .. tostring(c.type) .. "/" .. tostring(c.typeIndex) .. ", " .. #c.objects .. " object(s) on it)")
			AUTO.points[#AUTO.points + 1] = nodePosition(c.node0)
			-- (the stop tool's flags, 32: nothing cleaned up, no terrain alignment)
			local okp, errp = pcall(replayStop, { uid = "probe:" .. E, ctx = 32 }, plan)
			if not okp then say("segment " .. E .. ": " .. shortErr(errp)) end
		end
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
	end)
	if not ok then
		say("failed " .. shortErr(err))
		autoFinish()
	end
end

-- Road junctions of the street tool (MPFEVER_SCENARIO=streetcon, issue #72): roundabout, T, trumpet and diamond junctions
-- (street_construction/*.con, their parameters at the game's defaults) built by each game on open ground next to a dead end, held
-- and shipped as a native build: the other games replay them. MPFEVER_STREETCON_FILES=names separated by commas.
H.streetcon = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST streetcon " .. t); AUTO.results[#AUTO.results + 1] = t end
	local names = {}
	for n in (os.getenv("MPFEVER_STREETCON_FILES") or "roundabout,t_interchange,trumpet_interchange,diamond_interchange"):gmatch("[^,]+") do names[#names + 1] = n end
	local i = 0
	local nextOne
	nextOne = function()
		i = i + 1
		if i > #names then G.waits[#G.waits + 1] = { at = G.frames + 180, fn = autoFinish }; return end
		local ok, err = pcall(function()
			local file, id = nil, -1
			for _, f in ipairs({ "::/infrastructure/street_construction/" .. names[i] .. ".con", "infrastructure/street_construction/" .. names[i] .. ".con" }) do
				local okf, r = pcall(api.res.constructionRep.find, f)
				if okf and type(r) == "number" and r >= 0 then file, id = f, r break end
			end
			if not file then say(names[i] .. ": construction not found"); return nextOne() end
			local params = { seed = 1 }
			pcall(function()
				local rep = api.res.constructionRep.get(id)
				for k = 1, #rep.params do local pp = rep.params[k]; params[pp.key] = pp.defaultIndex or 0 end
			end)
			-- (open ground: 250 m beyond a dead end, away from the ones the other game takes)
			local ends = deadEnds()
			local n = ends[(((p.role == "host") and 11 or 29) + i * 17) % #ends + 1]
			local info = select(2, deadEnds())[n]
			local pn, po = nodePosition(n), nodePosition(info.other)
			local dx, dy = pn.x - po.x, pn.y - po.y
			local len = math.sqrt(dx * dx + dy * dy)
			local x, y = pn.x + dx / len * 250, pn.y + dy / len * 250
			local z = groundZ(x, y, pn.z)
			AUTO.points[#AUTO.points + 1] = { x = x, y = y, z = z }
			local sp = api.type.SimpleProposal.new()
			local ce = api.type.SimpleProposal.ConstructionEntity.new()
			ce.fileName = file
			ce.params = params
			ce.transf = api.type.Mat4f.new(api.type.Vec4f.new(1, 0, 0, 0), api.type.Vec4f.new(0, 1, 0, 0), api.type.Vec4f.new(0, 0, 1, 0), api.type.Vec4f.new(x, y, z, 1))
			ce.playerEntity = api.engine.util.getPlayer()
			pcall(function() ce.name = "" end)
			sp.constructionsToAdd = { ce }
			local edges0 = #R.allEdges()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = " " .. C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				say(names[i] .. ": " .. (success and "built" or ("refused" .. why)) .. ", edges " .. edges0 .. " -> " .. #R.allEdges())
				G.waits[#G.waits + 1] = { at = G.frames + 120, fn = nextOne }
			end)
		end)
		if not ok then say(tostring(names[i]) .. " failed: " .. shortErr(err)); G.waits[#G.waits + 1] = { at = G.frames + 40, fn = nextOne } end
	end
	nextOne()
end

-- Two-sided stop experiment (MPFEVER_SCENARIO=stopexp, host only, nothing shipped: the games differ afterwards): a pair of
-- "small_mid_twosided" stops at one place, one on each side, as the stop tool places them (issue: the friends' replays of such
-- pairs made one station less than the builder's tool). On a first town segment the pair is built by the replay's simple
-- proposal: what it makes (stations, constructions, names, node configurations, town buildings, cost, the stops' parameters).
-- On a second one, the engine's conversion of the same proposal (made to fail: the segment twice): its native edge objects.
H.stopexp = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("STOPEXP " .. t); AUTO.results[#AUTO.results + 1] = t end
	if C.ROLE ~= "host" then say("host only"); return autoFinish() end
	local function count(kind)
		local n = 0
		pcall(function() n = #R.entitiesWith(kind) end)
		return n
	end
	local function snapshot()
		local s = { st = count("STATION"), sg = count("STATION_GROUP"), con = count("CONSTRUCTION"), tb = count("TOWN_BUILDING"), nm = count("NAME"), nc = count("BASE_NODE_CONFIG") }
		s.eo = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do s.eo = s.eo + 1 end end)
		return s
	end
	local function diff(a, b)
		local t = {}
		for _, k in ipairs({ "st", "sg", "con", "tb", "nm", "nc", "eo" }) do t[#t + 1] = k .. " " .. (b[k] - a[k] >= 0 and "+" or "") .. (b[k] - a[k]) end
		return table.concat(t, ", ")
	end
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
		if c and c.type == 0 and #c.objects == 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) and tostring(c.roadTemplate):find("/town/", 1, true)
			and not (okC and type(con) == "number" and con >= 0) then
			local a, b = nodePosition(c.node0), nodePosition(c.node1)
			local len = a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) or 0
			if len > 50 and len < 120 then list[#list + 1] = e end
		end
	end
	if #list < 2 then say("not enough town segments"); return autoFinish() end
	local model = os.getenv("MPFEVER_STOPEXP_MODEL") or "stations/street/small_stops/small_mid_twosided.con"
	local function proposal(E, twice)
		local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		local edges, eos = {}, {}
		for k = 1, (twice and 2 or 1) do
			local e = api.type.SegmentAndEntity.new()
			e.entity = -k
			e.type = 0
			local cc = e.comp
			cc.node0 = c.node0; cc.node1 = c.node1
			cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
			cc.position0 = vec(nodePosition(c.node0)); cc.position1 = vec(nodePosition(c.node1))
			cc.type = c.type; cc.typeIndex = c.typeIndex
			cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
			cc.laneConfigs = c.laneConfigs
			cc.objects = { { -400000000 - 2 * (k - 1), 0 }, { -400000001 - 2 * (k - 1), 1 } }
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			edges[k] = e
			for side = 0, 1 do
				local eo = api.type.SimpleStreetProposal.EdgeObject.new()
				eo.edgeEntity = -k
				eo.param = 0.5
				eo.oneWay = false
				eo.left = side == 0
				eo.model = model
				eo.playerEntity = api.engine.util.getPlayer()
				eo.name = "MPF two-sided"
				eos[#eos + 1] = eo
			end
		end
		ssp.edgesToRemove = { E }
		ssp.edgesToAdd = edges
		ssp.edgeObjectsToAdd = eos
		local ncr = {}
		for _, nd in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = nd end
		end
		if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
		sp.streetProposal = ssp
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = false
		ctx.cleanupStreetGraph = false
		ctx.gatherBuildings = false
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		return sp, ctx
	end
	local A, B = list[1], list[math.floor(#list / 2) + 1]
	local s0 = snapshot()
	local cons0 = {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do cons0[e] = true end
	local sp, ctx = proposal(A, false)
	replaySend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
		local costs, why = "?", ""
		pcall(function() costs = tostring(res.resultProposalData.costs) end)
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
			say("simple proposal on segment " .. A .. ": " .. (success and "built" or ("refused " .. why)) .. ", costs " .. costs .. "; " .. diff(s0, snapshot()))
			-- the new constructions, their stations and parameters
			pcall(function()
				for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
					if not cons0[e] then
						local cc = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
						local pr = "?"
						pcall(function() pr = C.ser(C.marshal(cc.params)) end)
						say("new construction " .. e .. " " .. tostring(cc.fileName) .. " stations " .. #cc.stations .. " params " .. pr:sub(1, 200))
					end
				end
			end)
			-- the conversion of the same proposal by the engine (the segment twice: refused, nothing built)
			local sp2, ctx2 = proposal(B, true)
			replaySend(api.cmd.makeWorldBuildProposalCmd(sp2, ctx2, false, true), function(r2, ok2)
				local lines = { "conversion on segment " .. B .. ": " .. (ok2 and "BUILT (unexpected)" or "refused, as wanted") }
				pcall(function()
					local eo = r2.proposal.proposal.edgeObjectsToAdd
					lines[#lines + 1] = #eo .. " native edge object(s)"
					for i = 1, math.min(#eo, 4) do
						local x = eo[i]
						local f = {}
						for _, k in ipairs({ "model", "param", "left", "category", "segmentEntity", "oneWay", "name" }) do
							local okf, v = pcall(function() return x[k] end)
							f[#f + 1] = k .. "=" .. tostring(okf and v or "?")
						end
						local okp, pv = pcall(function() return C.ser(C.marshal(x.params)) end)
						f[#f + 1] = "params=" .. tostring(okp and pv or ("unreadable " .. tostring(pv)))
						local okw, ew = pcall(function() x.params = { year = 1961, seed = 0 } end)
						f[#f + 1] = "params writable=" .. tostring(okw) .. (okw and "" or (" (" .. tostring(ew):sub(1, 80) .. ")"))
						lines[#lines + 1] = "#" .. i .. " " .. table.concat(f, " ")
					end
				end)
				pcall(function() lines[#lines + 1] = "conversion costs " .. tostring(r2.resultProposalData.costs) end)
				for _, l in ipairs(lines) do say(l) end
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end)
		end }
	end)
end

-- Stops put on town streets the way the stop tool builds them (MPFEVER_SCENARIO=dstop): the street segment is replaced by a copy
-- carrying the stop, with the tool's Context (nothing cleaned up) and the junctions' node configurations removed (the tool also puts
-- them back; this does not), sent as a script's command marked like a replayed stop (doDust: the native module prices it like the
-- tool's build, the replaced segment free), held and shipped as a native build: the other games replay it and must pay what this one
-- did. MPFEVER_DSTOP_COUNT stops (3), each on a segment of its own. MPFEVER_STOPTOOL=0 or MPFEVER_REPLACEFREE=0: not marked (the
-- segment is paid for, the replay then pays it too). The copy keeps the segment's own ends, as the tool does (G.autoSegEnds).
-- MPFEVER_DSTOPOFFSET=1: segments with an end off its node are taken first (town streets: about 3 % of the ends), to see that
-- the replay keeps them (no terrain alignment, no town building taken away on the replaying game; with MPFEVER_STOPNODEPOS=1 on
-- the replaying game, MPFEVER_ENV_CLIENT for the host's stops, the bug of 2026-10-24 comes back: the segment laid again there).
H.dstop = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("DSTOP " .. t); AUTO.results[#AUTO.results + 1] = t end
	local ok, err = pcall(function()
		local want = tonumber(os.getenv("MPFEVER_DSTOP_COUNT") or "3") or 3
		local list, offList = {}, {}
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
			-- (MPFEVER_DSTOPBRIDGE=1: street segments of bridges instead, any length: the replay of a stop on a bridge, see
			-- G.replayNativeStop)
			local bridge = os.getenv("MPFEVER_DSTOPBRIDGE") == "1"
			if c and c.type == (bridge and 1 or 0) and #c.objects == 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET)
				and (bridge or tostring(c.roadTemplate):find("/town/", 1, true)) and not (okC and type(con) == "number" and con >= 0) then
				local a, b = nodePosition(c.node0), nodePosition(c.node1)
				local len = a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) or 0
				if (len > 40 and len < 120) or (bridge and len > 12) then
					list[#list + 1] = e
					local d0, d1 = G.autoEndsOff(c)
					if d0 and (d0 > 0 or d1 > 0) then offList[#offList + 1] = e end
				end
			end
		end
		if #list < want then say("dstop: only " .. #list .. " free town street segments"); return autoFinish() end
		local offFirst = os.getenv("MPFEVER_DSTOPOFFSET") == "1"
		say("dstop: " .. #offList .. " of " .. #list .. " free town street segments have an end off its node" .. (offFirst and " (taken first)" or ""))
		local used, n, step = {}, 0, ((C.ROLE == "host") and 7 or 23)
		local nextOne
		nextOne = function()
			if n >= want then G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }; return end
			local E
			for _, pool in ipairs((offFirst and #offList > 0) and { offList, list } or { list }) do
				for k = 1, #pool do
					local cand = pool[(step * (n + 1) + k) % #pool + 1]
					local cc0 = api.engine.getComponent(cand, api.type.ComponentType.BASE_EDGE)
					if cc0 and #cc0.objects == 0 and not used[cc0.node0] and not used[cc0.node1] then E = cand; break end
				end
				if E then break end
			end
			if not E then say("dstop: no segment left"); return autoFinish() end
			n = n + 1
			local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
			used[c.node0] = true; used[c.node1] = true
			local sp = api.type.SimpleProposal.new()
			local ssp = sp.streetProposal
			local e = api.type.SegmentAndEntity.new()
			e.entity = -1
			e.type = 0
			local cc = e.comp
			-- (MPFEVER_DSTOPREVERSE=1: the segment rebuilt the other way round, as it may run on another game after a replay:
			-- the other games' segment then runs the other way round than this one)
			local rev = os.getenv("MPFEVER_DSTOPREVERSE") == "1"
			if rev then
				cc.node0 = c.node1; cc.node1 = c.node0
				cc.tangent0 = api.type.Vec3f.new(-c.tangent1.x, -c.tangent1.y, -c.tangent1.z)
				cc.tangent1 = api.type.Vec3f.new(-c.tangent0.x, -c.tangent0.y, -c.tangent0.z)
				cc.position0, cc.position1 = G.autoSegEnds(c, true)
			else
				cc.node0 = c.node0; cc.node1 = c.node1
				cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
				cc.position0, cc.position1 = G.autoSegEnds(c)
			end
			cc.type = c.type; cc.typeIndex = c.typeIndex
			cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
			if rev then
				local rl = {}
				for k = #c.laneConfigs, 1, -1 do
					local l = C.marshal(c.laneConfigs[k])
					l.forward = not l.forward
					if type(l.offset) == "number" then l.offset = -l.offset end
					rl[#rl + 1] = l
				end
				cc.laneConfigs = C.rebuildLanes(rl)
			else
				cc.laneConfigs = c.laneConfigs
			end
			local left = n % 2 == 0
			cc.objects = { { -400000000, left and 0 or 1 } }
			e.comp = cc
			-- (the segment's owner, as the stop tool keeps it and as the replays copy it: a bridge built by a company is owned. Without
			-- it the copy belonged to nobody on this game and to the bridge's company on the replaying game, which keeps the owner of
			-- the segment it replaces: with MPFEVER_DSTOPBRIDGE=1 the "owners" differed. MPFEVER_DSTOPOWNER=0: as before, no owner)
			if os.getenv("MPFEVER_DSTOPOWNER") ~= "0" then
				local owner = R.ownerOf(E)
				if type(owner) == "number" and owner >= 0 then
					pcall(function() local po = C.newOf("PlayerOwned"); po.player = owner; e.playerOwned = po end)
				end
			end
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			local eo = api.type.SimpleStreetProposal.EdgeObject.new()
			eo.edgeEntity = -1
			eo.param = 0.3 + 0.1 * n
			eo.oneWay = false
			eo.left = left
			eo.model = K.STOP_MODEL
			eo.playerEntity = api.engine.util.getPlayer()
			eo.name = "MPF stop " .. C.ROLE .. n
			ssp.edgesToRemove = { E }
			ssp.edgesToAdd = { e }
			ssp.edgeObjectsToAdd = { eo }
			-- (the junctions' node configurations refer to the replaced segment: removed)
			local ncr = {}
			for _, nd in ipairs({ c.node0, c.node1 }) do
				local okn, nc = pcall(function() return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end)
				if okn and nc then ncr[#ncr + 1] = nd end
			end
			if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
			sp.streetProposal = ssp
			local ctx = api.type.Context.new()
			ctx.checkTerrainAlignment = false
			ctx.cleanupStreetGraph = false
			ctx.gatherBuildings = false
			ctx.gatherFields = true
			ctx.player = api.engine.util.getPlayer()
			local tool = os.getenv("MPFEVER_STOPTOOL") ~= "0" and os.getenv("MPFEVER_REPLACEFREE") ~= "0"
			local p0, p1 = nodePosition(c.node0), nodePosition(c.node1)
			AUTO.points[#AUTO.points + 1] = p0
			local off0, off1 = G.autoEndsOff(c)
			say("stop " .. n .. " on segment " .. E .. " (" .. tostring(c.roadTemplate):match("[^/]+$") .. ", chord "
				.. string.format("%.2f", math.sqrt((p0.x - p1.x) ^ 2 + (p0.y - p1.y) ^ 2 + (p0.z - p1.z) ^ 2)) .. (tool and ", priced like the tool's build" or ", priced as a script's")
				.. (off0 and string.format(", ends off its nodes by %.5f/%.5f m", off0, off1) or "") .. ")")
			-- (doDust set: the native module turns that into the tool's terms)
			local cmd = tool and api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true, true) or api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true)
			deferredSend(cmd, function(res, success)
				local why, costs = "", "?"
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				pcall(function() costs = tostring(res.resultProposalData.costs) end)
				say("stop " .. n .. ": " .. (success and "built" or ("refused " .. why)) .. ", costs " .. costs)
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextOne }
			end)
			-- (what the native module reports of a tool's command: its flags, 32 = known, see pollNativeEvents)
			if tool then
				G.natCtx = G.natCtx or {}
				G.natCtx[100000 + G.autoBuildSeq] = 32
			end
		end
		nextOne()
	end)
	if not ok then
		say("failed " .. shortErr(err))
		autoFinish()
	end
end

-- A construction against a street (station, depot) bulldozed, sent like a tool's build (issue #15: the other game removed its
-- entrance street but not the construction, and crashed). MPFEVER_CONEDIT_FILE=part of a file name picks it.
H.conbulldoze = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local want = os.getenv("MPFEVER_CONEDIT_FILE")
		local pick, pc = nil, nil
		for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
			local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
			if okc and c and R.ownerOf(e) then
				local f = tostring(c.fileName)
				local has = false
				pcall(function() has = #c.stations > 0 or #c.depots > 0 end)
				local street = f:find("street", 1, true) or f:find("depot", 1, true)
				if has and street and (not want or f:find(want, 1, true)) and (not pick or e > pick) then pick, pc = e, c end
			end
		end
		if not pick then AUTO.results[#AUTO.results + 1] = "conbulldoze: no construction against a street"; return autoFinish() end
		local sp = api.type.SimpleProposal.new()
		sp.constructionsToRemove = { pick }
		local cons0, edges0 = #R.entitiesWith("CONSTRUCTION"), #R.allEdges()
		log("AUTOTEST conbulldoze: construction " .. pick .. " " .. tostring(pc.fileName))
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = false
		ctx.cleanupStreetGraph = true
		ctx.gatherBuildings = false
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				local line = "conbulldoze " .. tostring(pc.fileName) .. ": " .. (success and "built" or ("refused " .. why)) .. ", constructions " .. cons0 .. " -> " .. #R.entitiesWith("CONSTRUCTION") .. ", edges " .. edges0 .. " -> " .. #R.allEdges()
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end }
		end)
	end)
	if not ok then
		log("AUTOTEST conbulldoze failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "conbulldoze error " .. tostring(err)
		autoFinish()
	end
end

-- Town buildings bulldozed one after the other, as the bulldozer builds it (MPFEVER_SCENARIO=housebulldoze, both games: the
-- friends' houses stayed on the other game). MPFEVER_HOUSE_COUNT (3) houses, each away from the streets' ends.
H.housebulldoze = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST housebulldoze " .. t); AUTO.results[#AUTO.results + 1] = t end
	local want = tonumber(os.getenv("MPFEVER_HOUSE_COUNT") or "3") or 3
	local houses = {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local okc, c = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) end)
		if okc and c and #c.townBuildings > 0 then houses[#houses + 1] = e end
	end
	if #houses < want then say("only " .. #houses .. " town buildings"); return autoFinish() end
	local step = (C.ROLE == "host") and 7 or 13
	local n = 0
	local nextOne
	nextOne = function()
		n = n + 1
		if n > want then G.waits[#G.waits + 1] = { at = G.frames + 120, fn = autoFinish }; return end
		local e = houses[(step * n * 37) % #houses + 1]
		local tb0 = #R.entitiesWith("TOWN_BUILDING")
		local sp = api.type.SimpleProposal.new()
		sp.constructionsToRemove = { e }
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = true
		ctx.cleanupStreetGraph = false
		ctx.gatherBuildings = false
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
			local costs = "?"
			pcall(function() costs = tostring(res.resultProposalData.costs) end)
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				say("house " .. n .. " (construction " .. e .. "): " .. (success and "bulldozed" or "refused") .. ", costs " .. costs .. ", town buildings " .. tb0 .. " -> " .. #R.entitiesWith("TOWN_BUILDING"))
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextOne }
			end }
		end)
		-- (the bulldozer's flags: terrain aligned, known)
		G.natCtx = G.natCtx or {}
		G.natCtx[100000 + G.autoBuildSeq] = 32 + 2
	end
	nextOne()
end

-- A road joined to the middle of a street that carries a stop, as the street tool builds it (the stops removed and placed
-- again on the new pieces: edgeObjectsToRemove / edgeObjectsToAdd), sent like a tool's build (C:12 in the 0.3.6 tests)
H.splitstop = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local E, c = nil, nil
		for _, e in ipairs(R.allEdges()) do
			local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if be and be.type == 0 and #be.objects > 0 then
				local a, b = nodePosition(be.node0), nodePosition(be.node1)
				local stopsOnly = true
				for i = 1, #be.objects do if be.objects[i][2] == 2 then stopsOnly = false end end
				if stopsOnly and a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 50 and (not E or e > E) then E, c = e, be end
			end
		end
		if not E then AUTO.results[#AUTO.results + 1] = "splitstop: no street with a stop"; return autoFinish() end
		local A, B = nodePosition(c.node0), nodePosition(c.node1)
		local M = { x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2 }
		local dx, dy = B.x - A.x, B.y - A.y
		local len = math.sqrt(dx * dx + dy * dy)
		local P = { x = M.x - dy / len * 40, y = M.y + dx / len * 40 }
		P.z = groundZ(P.x, P.y, M.z)
		local lanes = C.templateLanes(c.roadTemplate) or c.laneConfigs
		local function seg(id, n0, n1, p0, p1, objs)
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
			if objs then cc.objects = objs end
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			return e
		end
		local function node(id, q)
			local n = api.type.NodeAndEntity.new()
			n.entity = id
			local bn = n.comp; bn.position = vec(q); n.comp = bn
			return n
		end
		-- the stops of the segment: removed, and placed again on the half where they were
		local rmObjs, adds, half = {}, {}, { {}, {} }
		for i = 1, #c.objects do
			local id, side = c.objects[i][1], c.objects[i][2]
			local par = 0.25
			pcall(function() par = api.engine.getComponent(id, api.type.ComponentType.EDGE_OBJECT).param end)
			rmObjs[#rmObjs + 1] = id
			local h = par < 0.5 and 1 or 2
			local eo = api.type.SimpleStreetProposal.EdgeObject.new()
			eo.edgeEntity = -h
			eo.param = (h == 1) and par * 2 or (par - 0.5) * 2
			eo.oneWay = false
			eo.left = side == 0
			eo.model = K.STOP_MODEL
			eo.playerEntity = api.engine.util.getPlayer()
			adds[#adds + 1] = eo
			half[h][#half[h] + 1] = { -400000000 - (#adds - 1), side }
		end
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		ssp.nodesToAdd = { node(-1, M), node(-2, P) }
		ssp.edgesToAdd = { seg(-1, c.node0, -1, A, M, half[1]), seg(-2, -1, c.node1, M, B, half[2]), seg(-3, -1, -2, M, P) }
		ssp.edgesToRemove = { E }
		ssp.edgeObjectsToRemove = rmObjs
		ssp.edgeObjectsToAdd = adds
		local ncr = {}
		for _, n in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = n end
		end
		if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
		sp.streetProposal = ssp
		local stops0 = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do stops0 = stops0 + 1 end end)
		local edges0 = #R.allEdges()
		log("AUTOTEST splitstop: segment " .. E .. " with " .. #rmObjs .. " stop(s)")
		local ctx = api.type.Context.new()
		ctx.checkTerrainAlignment = true
		ctx.cleanupStreetGraph = false
		ctx.gatherBuildings = true
		ctx.gatherFields = true
		ctx.player = api.engine.util.getPlayer()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				local stops = 0
				pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do stops = stops + 1 end end)
				local line = "splitstop on segment " .. E .. ": " .. (success and "built" or ("refused " .. why)) .. ", edges " .. edges0 .. " -> " .. #R.allEdges() .. ", edge objects " .. stops0 .. " -> " .. stops
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end }
		end)
	end)
	if not ok then
		log("AUTOTEST splitstop failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "splitstop error " .. tostring(err)
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

-- Upgrade of another company's street (MPFEVER_SCENARIO=upgowner, one company per player, issue #104): the client's company
-- upgrades two street segments of the host's company, as the street upgrade tool does with the sharing rules on: the first with
-- the engine's upgrade proposal as it is (its new segment keeps the old owner), the second with the new segment's owner left out,
-- as in the tool's proposals of #104 (the engine then decides). The sync check after it compares the owners of both games; each
-- game logs who owns the new segments ("AUTOTEST upgowner ... owner").
G.runUpgOwner = function(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE == "host" then
		AUTO.results[#AUTO.results + 1] = "upgowner: the client upgrades"
		return autoFinish()
	end
	local me = api.engine.util.getPlayer()
	local list, templates = {}, {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		local st = c and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET)
		local own = R.ownerOf(e)
		if st and c.type == 0 and #c.objects == 0 and c.roadTemplate and c.roadTemplate ~= "" then templates[c.roadTemplate] = true end
		if st and c.type == 0 and #c.objects == 0 and own and own ~= me and c.roadTemplate and c.roadTemplate ~= "" then list[#list + 1] = { e = e, c = c, own = own } end
	end
	table.sort(list, function(x, y) return x.e < y.e end)
	local names = {}
	for t, _ in pairs(templates) do names[#names + 1] = t end
	table.sort(names)
	log("AUTOTEST upgowner: " .. #list .. " street segment(s) of other companies, this company " .. tostring(me))
	if #list < 2 then
		AUTO.results[#AUTO.results + 1] = "upgowner: fewer than 2 street segments of another company"
		return autoFinish()
	end
	local picks = { list[1], list[math.floor(#list / 2) + 1] }
	local function ownersAt(c)
		local out = {}
		for _, e in ipairs(R.allEdges()) do
			local b = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if b and ((b.node0 == c.node0 and b.node1 == c.node1) or (b.node0 == c.node1 and b.node1 == c.node0)) then
				out[#out + 1] = e .. ":" .. tostring(R.ownerOf(e))
			end
		end
		return table.concat(out, ",")
	end
	local function one(k)
		local pick = picks[k]
		if not pick then return autoFinish() end
		local target = nil
		for _, t in ipairs(names) do if t ~= pick.c.roadTemplate and not t:find("entrance", 1, true) then target = t; break end end
		local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(pick.e, target) end)
		if not okp or not P then
			AUTO.results[#AUTO.results + 1] = "upgowner " .. k .. ": no proposal " .. tostring(P)
			return one(k + 1)
		end
		local variant = (k == 1) and "explicit" or "none"
		if k == 2 then
			local okn, errn = pcall(function()
				local sp = P.proposal
				local list2 = sp.addedSegments
				local seg = list2[1]
				local n = C.newOf("SegmentAndEntity")
				for _, f in ipairs({ "entity", "type", "comp", "streetEdge", "trackEdge", "params", "emissionEmitter" }) do
					pcall(function() local v = seg[f]; if v ~= nil then n[f] = v end end)
				end
				list2[1] = n
				sp.addedSegments = list2
				P.proposal = sp
			end)
			if not okn then variant = "none failed (" .. shortErr(errn) .. ")" end
		end
		log("AUTOTEST upgowner " .. k .. " (" .. variant .. "): segment " .. pick.e .. " of " .. tostring(pick.own) .. " to " .. tostring(target))
		local ctx = playerContext()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
				local line = "upgowner " .. k .. " (" .. variant .. "): " .. (success and "built" or ("refused " .. why)) .. ", owner " .. ownersAt(pick.c)
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				one(k + 1)
			end }
		end)
	end
	one(1)
end

H.upgowner = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(G.runUpgOwner, p)
	if not ok then
		log("AUTOTEST upgowner failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "upgowner error " .. tostring(err)
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
	-- (the names of the savegame as every game loaded it, for the checks made in a pause, see R.nameSeed)
	if K.nameSyncOn() then pcall(R.nameSeed) end
	-- the game time of the savegame loaded now (the session's start, or the host's game of a resynchronisation): the acts stamped
	-- later cannot be in it (see G.alreadyBuilt)
	pcall(function() G.loadT = gameTime() end)
	-- (and the resynchronisation it came from, when it did: read below from the launcher's order to load)
	G.loadId = nil
	-- records of the savegame's script state (an earlier session, or the host's): never shipped or reported again
	local st = state:get() or {}
	for _, o in ipairs(st.out or {}) do if o.n > G.outSent then G.outSent = o.n end end
	G.outTold = nil
	-- (a savegame made without a lobby: its builds are kept again until the launcher says « solo », see H.solo)
	if st.solo then toSim("solo", { on = false }) end
	-- (keyed by uid and game time: uids start again at 1 in every session, an old record must not hide a new one)
	for _, r in ipairs(st.results or {}) do G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true end
	if type(st.hash) == "table" then G.hashSent = st.hash.n end
	-- the native module keeps counting released builds as long as the game runs (also across a session left for the main menu)
	pcall(function()
		local f = C.IO.open(C.DIR .. BS .. "native_ctl.txt", "rb")
		if not f then return end
		local s = f:read("*a") or ""
		f:close()
		for n in s:gmatch("release (%d+)") do
			n = tonumber(n)
			if n and n > G.natReleased then G.natReleased = n end
		end
	end)
	-- first start of this game in the session: everything the launcher wrote so far is for it
	if fileSize("started.txt") == 0 then
		-- (loaded from the main menu by MPFever's order: the resynchronisation's or the lobby start's number, written by the
		-- launcher for this load only, see G.alreadyBuilt)
		pcall(function()
			local f = C.IO.open(C.DIR .. BS .. "load_id.txt", "rb")
			if not f then return end
			local s = f:read("*a") or ""
			f:close()
			G.loadId = tonumber(s:match("%d+"))
			if G.loadId then log("loaded from the main menu: savegame of resynchronisation " .. G.loadId) end
			local w = C.IO.open(C.DIR .. BS .. "load_id.txt", "wb")
			if w then w:close() end
		end)
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
		local last, pos, lastAt = nil, 1, nil
		while true do
			local i = s:find("resync_load" .. TAB, pos, true)
			if not i then break end
			if i == 1 or s:sub(i - 1, i - 1) == NL then
				local e = s:find(NL, i, true)
				if e then last = e; lastAt = i end
			end
			pos = i + 1
		end
		-- (the host's number of that resynchronisation, the same on every game: "7" on the host's, "7-<ticks>" on the others')
		if lastAt then G.loadId = tonumber(s:sub(lastAt, last):match('%["id"%]="?(%d+)')) end
		if G.loadId then log("loaded: savegame of resynchronisation " .. G.loadId) end
		if last and last < #s then
			log("resynchronisation: " .. (#s - last) .. " bytes of messages received during the load are read")
			G.inOff = last
		end
		-- (loaded by a resynchronisation, which may still be under way for the others: builds refused until the launcher's
		-- session says it is over, see H.session)
		if last and os.getenv("MPFEVER_RESYNCBUILDS") ~= "1" then G.session.resync = true; G.resyncNewWorld = true end
	end)
	-- commands the UI hook held before the reload were already shipped and applied: never again
	G.uiOff = fileSize("ui.log")
	G.modOff = fileSize("sim_mods.log")
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
G.coMyName = function()
	local n = tostring(G.me or C.NAME or "player"):gsub("#.*$", "")
	return n
end

-- the colour this player picked in the menu (company_color.txt, a palette index), nil when none
G.coMyColor = function()
	local f = C.IO.open(C.DIR .. BS .. "company_color.txt", "rb")
	if not f then return nil end
	local n = tonumber((f:read("*a") or ""):match("%d+"))
	f:close()
	return n
end

-- (G.coMyName/coMyKey/coMySid are fields of G: the main chunk is at Lua's limit of 200 locals)
-- this player's key in the registry: its name in lower case; empty for a dedicated server, which plays no company of its own
G.coMyKey = function()
	if C.SERVER then return "" end
	return G.coMyName():lower()
end

-- this player's Steam account (steam_id.txt, written by the native module once Steam is up), nil while unknown (and never
-- used for a dedicated server: its account owns no company)
G.coMySid = function()
	if C.SERVER then return nil end
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
	end, log, function(entity)
		-- (each company's own rank, see mpfever_progression.lua)
		local PG = C.progression()
		local id = R.coIdOf and R.coIdOf(entity)
		if not (PG and id and R.CO and PG.multi(R.CO)) then return nil end
		return PG.view(G.prog, id)
	end)
	if not okP then log("companies: the progression module is not reachable from here (rank of other companies stays empty)") end
	if not CO.patchPermits(coReq, log) then log("companies: the permit modules are not reachable from here (unique buildings stay shared)") end
end

K.coCtlSeq = 0
local function coGui(st)
	if G.cmode ~= "separate" then return end
	R.CO = st.co
	G.prog = st.prog
	if not G.gpWrapped then
		G.gpWrapped = true
		local real = api.engine.util.getPlayer
		api.engine.util.getPlayer = function() if G.actor then return G.actor end return real() end
		pcall(coPatchProgression)
	end
	-- the interface's own Lua state (tools, windows) maps player entities to company numbers through this file
	if st.co then
		local lines = { "me	" .. tostring((not G.coNone and G.myCo) or 0) }
		for _, c in ipairs(st.co.list) do if c.ent then lines[#lines + 1] = c.id .. "	" .. c.ent .. "	" .. tostring(c.name or ""):gsub("[%c]", " ") end end
		-- (each company's colour, a palette index: see CO.PALETTE)
		for _, c in ipairs(st.co.list) do lines[#lines + 1] = "color	" .. c.id .. "	" .. tostring(c.color or 1) end
		-- (each company's rank, when there is more than one company: see mpfever_progression.lua)
		for _, r in ipairs((st.prog and st.prog.records) or {}) do
			lines[#lines + 1] = "rank	" .. tostring(r.company) .. "	" .. tostring(r.experience) .. "	" .. tostring(r.level) .. "	" .. tostring(r.potential)
		end
		local txt = table.concat(lines, NL) .. NL
		if txt ~= G.coFile then
			G.coFile = txt
			local f = C.IO.open(C.DIR .. BS .. "companies.txt", "wb")
			if f then f:write(txt); f:close() end
		end
	end
	-- the stations with a setting of their own (the interface shows them in the station windows and the line tool): one line
	-- "key TAB rule TAB fee" each (0.5.2; before, "key TAB fee"), the fees of 0.5.1 (reg.shares) as the rules they now are
	do
		local t = {}
		local function clean(k) return (tostring(k):gsub("[%c]", " ")) end
		local sr = (st.co and st.co.stationRule) or {}
		for k, o in pairs(sr) do
			if type(o) == "table" then t[#t + 1] = clean(k) .. "\t" .. tostring(o.rule) .. "\t" .. tostring(math.floor(tonumber(o.fee) or 0)) end
		end
		for k, fee in pairs((st.co and st.co.shares) or {}) do
			local n = math.floor(tonumber(fee) or 0)
			if sr[k] == nil then t[#t + 1] = clean(k) .. "\t" .. (n > 0 and "toll" or "private") .. "\t" .. math.max(n, 0) end
		end
		table.sort(t)
		local txt = table.concat(t, NL)
		if txt ~= G.shareFile then
			G.shareFile = txt
			local f = C.IO.open(C.DIR .. BS .. "shares.txt", "wb")
			if f then f:write(txt); f:close() end
			-- (the map's icons and the counts of eco.txt follow at once, see G.hudShare)
			G.hudShareAt = nil
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
		local name = G.coMyName()
		G.oseq = G.oseq + 1
		local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
		-- the player's Steam account (written by the native module): the company follows the account, whatever name is typed
		local sid = G.coMySid()
		local a = { fn = "mpfCoJoin", origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
			at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil,
			args = { key = G.coMyKey(), name = name, host = (C.ROLE == "host"), mode = "separate", start = G.coStart, sid = sid,
				color = G.coMyColor(),
				owner = C.SERVER and (G.coOwner or "") or nil,
				cname = C.Tf("Entreprise %s", "%s Company", name) } }
		a.native = true
		send("act", a)
		a.recvFrame = G.frames
		G.nativeQueue[#G.nativeQueue + 1] = a
		if paused and G.joinTurns then G.ptIssue(G.me, G.joinTurnId(a)) end
		log("companies: announced as '" .. name .. "' (company mode " .. tostring(G.cmode) .. ")")
	end
	-- which company is this game's: its interface and tools act as that company from now on
	local reg = st.co
	if reg then
		-- (a Steam account shared by two games of one PC finds no company by itself, here as in the simulation: a player who
		-- left a company where the other game's player still is plays none, and asks for a new one; see CO.sharedSid)
		local c = CO.match(reg, G.coMyKey(), G.coMySid(), C.ROLE == "host")
		-- (no company any more: this player left its company, or its company went bankrupt; it acts as nobody's until its new
		-- one is there, see G.coEco)
		-- (G.myCo stays the company it played: the native module still acts as it; its actions are refused meanwhile, see
		-- G.resyncRefuse)
		if not c and G.myCo and G.session.started and G.coAsked and not G.coNone then
			log("companies: this game plays no company any more (it was company " .. tostring(G.myCo) .. "): a new one is coming")
			G.coNone = true
		elseif c and G.coNone and c.ent then
			G.coNone = nil
		end
		-- the other companies' player entities (the native module empties their money popups, see ClearOthers)
		local others = {}
		for _, o in ipairs(reg.list) do if o.ent and not o.gone and c and o.ent ~= c.ent then others[#others + 1] = o.ent end end
		table.sort(others)
		local osig = table.concat(others, " ")
		-- (said again every few seconds: the native module forgets the value when a game is loaded, see ApplyLocalPlayer. Said
		-- right after a load, it was forgotten a second later when the new game state applied its first command, and the
		-- tools built for the savegame's company until the next time, 7 to 15 s later: a client's stop belonged to the host's
		-- company, issue #47. So every 30 frames during the first 1200 frames of a game)
		if c and c.ent and (G.myCo ~= c.id or G.myEnt ~= c.ent or osig ~= G.coOthers
			or G.frames - (G.coAsserted or 0) > (G.frames < 1200 and 30 or 400)) then
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
			K.coCtlSeq = K.coCtlSeq + 1
			local okT, tm = pcall(os.time)
			local tok = ((okT and tm or 0) % 1000000) * 100 + K.coCtlSeq % 100
			if not os.getenv("MPFEVER_NOSETLOCAL") then nativeCtl("setlocal " .. c.ent .. " " .. tok) end
			G.coOthers = osig
			if osig ~= "" and not os.getenv("MPFEVER_NOCLEAR") then nativeCtl("setothers " .. tok .. " " .. osig) end
			if reg.canon then nativeCtl("setcanon " .. tok .. " " .. reg.canon) end
		end
		-- the stations of the other companies that are not private: the native module lets their icons through the map's owner
		-- filter (the line tool shows them, as this company's own), see HudShareSplice. Every 300 frames (at once when a rule
		-- changed), written only when the list changes; the count of each company's stations with a setting of their own (eco.txt)
		-- comes from the same look, MPFEVER_NOHUDSHARE=1 or not
		if c and c.ent and G.frames - (G.hudShareAt or -1000) >= 300 then
			G.hudShareAt = G.frames
			local okH, errH = pcall(G.hudShare, reg, c)
			if not okH and (G.hudShareErrs or 0) < 5 then G.hudShareErrs = (G.hudShareErrs or 0) + 1; log("companies: shared stations failed: " .. tostring(errH)) end
		end
		-- the tracks the other companies opened (their rule "open" or "toll", or gone companies'): this game's track tool may
		-- connect to them (see the native module's IsOwnedDetour). Every 300 frames (1800 when listing the tracks is slow, see
		-- G.openNet), written only when the list changes
		if c and c.ent and G.frames - (G.openNetAt or -1000) >= (G.openNetEvery or 300) then
			G.openNetAt = G.frames
			local okO, errO = pcall(G.openNet, reg, c)
			if not okO then log("companies: open tracks failed: " .. tostring(errO)) end
		end
		local okE, errE = pcall(G.coEco, st, reg, c)
		if not okE and G.frames - (G.coEcoErrAt or -10000) > 600 then G.coEcoErrAt = G.frames; log("companies: economy view failed: " .. tostring(errE)) end
	end
end

-- Mixed modes, bankruptcy, auctions, rules (mpfever_eco.lua), the interface's side, every frame:
--  * eco.txt for the interface (the MPFever window): this player's key, the members and chiefs, the companies gone, the months in
--    debt, the requests and offers, the rules, the fees and tolls, the auction under way;
--  * a player left without a company (it left one, its company went bankrupt) announces itself again: it gets a new one;
--  * the host: the bankruptcy rule of its session into the game, the auction's clock (a lot closes a minute after it opened,
--    and 15 s after its last bid), and what happens told in the chat.
G.coEco = function(st, reg, c)
	local E = C.eco()
	if not E then return end
	local function clean(t) return (tostring(t or ""):gsub("[%c]", " ")) end
	local L = { "mykey\t" .. G.coMyKey(), "rules\t" .. tostring((reg.rules or {}).bankrupt or E.BANKRUPT_DEFAULT),
		-- (0.5.14: the sharing rules on or off, the start money of a new company)
		"share\t" .. (E.sharingOff(reg) and "0" or "1"), "start\t" .. tostring(math.floor(tonumber((reg.rules or {}).start) or tonumber(reg.start) or 0)) }
	local function num(t, id) return math.floor(tonumber(t and t[tostring(id)]) or 0) end
	local rulesSig = {}
	for _, co in ipairs(reg.list) do
		if co.gone then L[#L + 1] = "gone\t" .. co.id .. "\t" .. tostring(co.gone) end
		-- (a computer company: its lines and its journal in the window, see H.aijournal)
		if tostring(co.key or ""):sub(1, 3) == "ai:" then L[#L + 1] = "ai\t" .. co.id end
		for _, m in ipairs(CO.members(co)) do L[#L + 1] = "member\t" .. co.id .. "\t" .. clean(m.key) end
		local ch = CO.chief(co)
		if ch and not co.gone then L[#L + 1] = "chief\t" .. co.id .. "\t" .. clean(ch) end
		if co.debt then L[#L + 1] = "debt\t" .. co.id .. "\t" .. co.debt end
		local r = E.trackRule(reg, co)
		L[#L + 1] = "track\t" .. co.id .. "\t" .. tostring(r.rule) .. "\t" .. tostring(r.toll or 0)
		-- (0.6.2: its rule for its roads)
		if E.roadRule then L[#L + 1] = "road\t" .. co.id .. "\t" .. tostring(E.roadRule(reg, co).rule) end
		-- (0.5.2: the company's rule for its stations and stops, with the number of its stations that have a setting of their
		-- own, counted by G.hudShare; its rule for its depots without a setting of their own)
		local s = E.stopRule(reg, co)
		L[#L + 1] = "stops\t" .. co.id .. "\t" .. tostring(s.rule) .. "\t" .. math.floor(tonumber(s.fee) or 0) .. "\t" .. ((G.stopOwn or {})[co.id] or 0)
		rulesSig[#rulesSig + 1] = co.id .. tostring(s.rule) .. tostring(s.fee)
		local d = E.depotCoRule(reg, co)
		L[#L + 1] = "depotco\t" .. co.id .. "\t" .. tostring(d.rule) .. "\t" .. math.floor(tonumber(d.toll) or 0)
		L[#L + 1] = "fees\t" .. co.id .. "\t" .. num(reg.shareIncome, co.id) .. "\t" .. num(reg.shareExpense, co.id) .. "\t" .. num(reg.tollIncome, co.id) .. "\t" .. num(reg.tollExpense, co.id)
	end
	-- (a company's rule for its stations changed: the map's icons and the line tool follow at once, see G.hudShare)
	local rs = table.concat(rulesSig, " ")
	if rs ~= G.stopRulesSig then G.stopRulesSig = rs; G.hudShareAt = nil end
	for _, r in ipairs(reg.requests or {}) do L[#L + 1] = "req\t" .. clean(r.key) .. "\t" .. clean(r.name) .. "\t" .. tostring(r.to) end
	for _, o in ipairs(reg.mergeOffers or {}) do L[#L + 1] = "merge\t" .. tostring(o.from) .. "\t" .. tostring(o.to) end
	local au = reg.auction
	-- (when this game saw the lot open: the time left it shows)
	local nowT = os.time()
	if au and au.lots[au.idx] then
		if not G.coAuSeen or G.coAuSeen.seq ~= au.seq or G.coAuSeen.idx ~= au.idx then G.coAuSeen = { seq = au.seq, idx = au.idx, t = nowT } end
		if au.lastBidAt and G.coAuSeen.bidAt ~= au.lastBidAt then G.coAuSeen.bidAt = au.lastBidAt; G.coAuSeen.bidT = nowT end
		local left = math.max(0, E.LOT_SECONDS - (nowT - G.coAuSeen.t))
		if G.coAuSeen.bidT then left = math.max(left, E.LAST_BID_SECONDS - (nowT - G.coAuSeen.bidT)) end
		local lot = au.lots[au.idx]
		local minBid = math.max(lot.reserve or 0, au.best and math.ceil(au.best * (1 + E.MIN_RAISE)) or 0)
		L[#L + 1] = "auction\t" .. au.seq .. "\t" .. au.co .. "\t" .. au.idx .. "\t" .. #au.lots .. "\t" .. tostring(lot.kind) .. "\t" .. clean(lot.label)
			.. "\t" .. tostring(lot.reserve or 0) .. "\t" .. tostring(au.best or 0) .. "\t" .. tostring(au.bidder or 0) .. "\t" .. left .. "\t" .. minBid
	else
		G.coAuSeen = nil
	end
	local dk = {}
	for k in pairs(reg.depots or {}) do dk[#dk + 1] = k end
	table.sort(dk)
	for _, k in ipairs(dk) do local d = reg.depots[k]; L[#L + 1] = "depot\t" .. clean(k) .. "\t" .. tostring(d.rule) .. "\t" .. tostring(d.toll or 0) .. "\t" .. tostring(d.co or 0) end
	local txt = table.concat(L, NL) .. NL
	if txt ~= G.ecoFile then
		G.ecoFile = txt
		local f = C.IO.open(C.DIR .. BS .. "eco.txt", "wb")
		if f then f:write(txt); f:close() end
	end
	-- a player without a company (it left its company, or its company went bankrupt): announced again two seconds later
	if G.session.started and G.coAsked and not G.coBusy and not c then
		G.coNoneSince = G.coNoneSince or G.frames
		if G.frames - G.coNoneSince > 120 and G.frames - (G.coReannAt or -100000) > 900 then
			G.coNoneSince = nil
			G.coReannAt = G.frames
			G.coAsked = false
			log("companies: this player has no company any more: it asks for a new one")
		end
	else
		G.coNoneSince = nil
	end
	-- (autotests, MPFEVER_COAUTO=1: this game's chief accepts the requests and offers to its company by itself)
	if os.getenv("MPFEVER_COAUTO") == "1" and c and CO.chief(c) == G.coMyKey() and G.frames - (G.coAutoAt or -1000) > 120 then
		for _, r in ipairs(reg.requests or {}) do
			if r.to == c.id then G.coAutoAt = G.frames; uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "co_join_answer", [4] = { key = r.key, accept = true } }) end
		end
		for _, o in ipairs(reg.mergeOffers or {}) do
			if o.to == c.id then G.coAutoAt = G.frames; uiRequest("makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "co_merge_answer", [4] = { from = o.from, accept = true } }) end
		end
	end
	if C.ROLE ~= "host" then return end
	-- the host's rules into the game (once, and again if the game did not take it): months in debt before a bankruptcy, the
	-- sharing rules on or off and the start money of a new company (0.5.14; kept in the savegame, MPFever.exe reads them back
	-- when the host opens a lobby on it. MPFEVER_SHARESWITCH=0: the bankruptcy only, as before)
	local want = tonumber(G.coBankrupt)
	local rules = reg.rules or {}
	local newRules = os.getenv("MPFEVER_SHARESWITCH") ~= "0"
	-- (not "newRules and x or nil": a false x would give nil, and the rules switched off never reached the game)
	local shareWant = nil
	if newRules then shareWant = G.coShare ~= false end
	local startWant = newRules and tonumber(G.coStart) or nil
	-- (as mpfever_eco.lua keeps it: 0 to 10 billion; another value was never kept, and co_rules went again every 10 s)
	if startWant and (startWant < 0 or startWant > 1e10) then startWant = nil end
	-- (the computer companies with their colour, level and start money, "n:colour:level[:money],...": a lobby on this savegame
	-- gives them their level and money again)
	local aiWant = newRules and type(G.coAi) == "string" and G.coAi or nil
	local differs = (want and want ~= tonumber(rules.bankrupt))
		or (shareWant ~= nil and shareWant ~= (rules.share ~= false))
		or (startWant ~= nil and startWant ~= tonumber(rules.start))
		or (aiWant ~= nil and aiWant ~= (rules.ai or ""))
	if differs and G.frames - (G.coRulesAt or -100000) > 600 then
		G.coRulesAt = G.frames
		G.coEvent("co_rules", { bankrupt = want or tonumber(rules.bankrupt) or E.BANKRUPT_DEFAULT, share = shareWant, start = startWant, ai = aiWant })
	end
	-- each new month: the companies in debt on this game (the host's money is every game's), applied by all at the same step
	if reg.month and reg.month ~= (reg.monthSeen or -1) and (G.coMonthSent ~= reg.month or G.frames - (G.coMonthAt or 0) > 900) then
		G.coMonthSent = reg.month
		G.coMonthAt = G.frames
		local debt = {}
		for _, co in ipairs(reg.list) do
			if co.ent and not co.gone then
				local okB, b = pcall(api.engine.util.finance.getPlayersBalance, co.ent)
				if okB and type(b) == "number" and b < 0 then debt[#debt + 1] = co.id end
			end
		end
		G.coEvent("co_month", { month = reg.month, debt = debt })
	end
	-- the auction's clock (the host's real time: the game may be paused, its speed may change)
	if au and au.lots[au.idx] then
		local A = G.coAu
		if not A or A.seq ~= au.seq or A.idx ~= au.idx then
			A = { seq = au.seq, idx = au.idx, start = nowT, sent = -1000 }
			G.coAu = A
			local lot = au.lots[au.idx]
			-- (after what happened up to now: the bankruptcy is told before its first lot)
			G.coNewsSay(reg)
			G.coSay(C.Tf("Enchères de %s : lot %s/%s, %s (mise à prix %s). Enchérissez dans la fenêtre MPFever.", "Auction of %s: lot %s/%s, %s (reserve %s). Bid in the MPFever window.",
				G.coName(reg, au.co), au.idx, #au.lots, G.coLotText(lot), G.coMoney(lot.reserve)))
		end
		if au.lastBidAt ~= A.bidAt then A.bidAt = au.lastBidAt; A.bidT = nowT end
		if nowT - A.start >= E.LOT_SECONDS and (not A.bidT or nowT - A.bidT >= E.LAST_BID_SECONDS) and nowT - A.sent >= 10 then
			A.sent = nowT
			G.coEvent("co_lot_close", { seq = au.seq, lot = au.idx })
		end
	else
		G.coAu = nil
	end
	G.coNewsSay(reg)
end

-- what happened, in the chat (from the host only: one message for everybody)
G.coNewsSay = function(reg)
	if G.coNewsSeen == nil then G.coNewsSeen = reg.newsSeq or 0 end
	for _, n in ipairs(reg.news or {}) do
		if n.n > G.coNewsSeen then
			G.coNewsSeen = n.n
			local okT, t = pcall(G.coNewsText, reg, n)
			if okT and t then G.coSay(t) end
		end
	end
end

G.coMoney = function(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return "$" .. out
end

G.coLotText = function(lot)
	if lot.kind == "line" then return C.Tf("la ligne « %s » et ses %s véhicule(s)", "line « %s » and its %s vehicle(s)", lot.label, lot.vehicles or 0) end
	if lot.kind == "station" then return C.Tf("la gare « %s »", "station « %s »", lot.label) end
	return C.Tf("le dépôt « %s »", "depot « %s »", lot.label)
end

G.coSay = function(text)
	pcall(send, "notice", { what = "cochat", text = text })
	log("companies (chat): " .. text)
end

-- a company's name as the players see it: the game's (the savegame's company has none in the registry), else the registry's
G.coName = function(reg, id)
	local c = CO.find(reg, id)
	if not c then return "#" .. tostring(id) end
	local n = nil
	pcall(function() n = api.engine.getComponent(c.ent, api.type.ComponentType.NAME).name end)
	if type(n) == "string" and n ~= "" then return n end
	if c.name and c.name ~= "" then return c.name end
	return "#" .. tostring(id)
end

G.coNewsText = function(reg, n)
	local function nm(id) return G.coName(reg, id) end
	local k = n.kind
	if k == "bankrupt" then return C.Tf("%s fait faillite : %s lot(s) mis aux enchères. Ses joueurs reçoivent une nouvelle entreprise.", "%s goes bankrupt: %s lot(s) put up for auction. Its players get a new company.", nm(n.co), n.lots or 0) end
	if k == "debt" then
		if (n.limit or 0) <= 0 then return nil end
		return C.Tf("%s est endettée depuis %s mois (faillite à %s mois de dette).", "%s has been in debt for %s month(s) (bankruptcy after %s months).", nm(n.co), n.months, n.limit)
	end
	if k == "bid" then return C.Tf("%s offre %s.", "%s bids %s.", nm(n.by), G.coMoney(n.amount)) end
	if k == "lot_sold" then return C.Tf("Adjugé : « %s » à %s pour %s.", "Sold: « %s » to %s for %s.", n.label, nm(n.to), G.coMoney(n.amount)) end
	if k == "lot_unsold" then return C.Tf("« %s » : aucune offre, démoli.", "« %s »: no bid, demolished.", n.label) end
	if k == "auction_end" then return C.Tf("Fin des enchères de %s.", "The auction of %s is over.", nm(n.co)) end
	if k == "ask" then return C.Tf("%s demande à rejoindre %s (son chef répond dans la fenêtre MPFever).", "%s asks to join %s (its chief answers in the MPFever window).", n.name or n.key, nm(n.co)) end
	if k == "joined" then return C.Tf("%s rejoint %s.", "%s joins %s.", n.key, nm(n.co)) end
	if k == "refused" then return C.Tf("%s refuse la demande de %s.", "%s refuses %s's request.", nm(n.co), n.key) end
	if k == "left" then return C.Tf("%s quitte %s et fonde sa propre entreprise.", "%s leaves %s and starts its own company.", n.key, nm(n.co)) end
	if k == "merge_ask" then return C.Tf("%s propose de fusionner avec %s.", "%s offers to merge with %s.", nm(n.co), nm(n.to)) end
	if k == "merged" then return C.Tf("%s fusionne avec %s : tous ses biens, son argent et ses joueurs passent à %s.", "%s merges with %s: all its assets, its money and its players go to %s.", nm(n.co), nm(n.into), nm(n.into)) end
	if k == "merge_refused" then return C.Tf("%s refuse de fusionner avec %s.", "%s refuses to merge with %s.", nm(n.to), nm(n.co)) end
	if k == "track_rule" then
		local what = n.rule == "open" and C.T("ouvertes à tous", "open to all") or n.rule == "toll" and C.Tf("ouvertes avec un péage de %s par passage", "open with a toll of %s per passage", G.coMoney(n.toll)) or C.T("privées", "private")
		return C.Tf("Voies de %s : %s.", "%s's tracks: %s.", nm(n.co), what)
	end
	if k == "road_rule" then
		return n.rule == "open" and C.Tf("Routes de %s : ouvertes à tous.", "%s's roads: open to all.", nm(n.co))
			or C.Tf("Routes de %s : privées.", "%s's roads: private.", nm(n.co))
	end
	-- (whole sentences: the words for open and private take the gender of stations or depots in other languages)
	if k == "stop_rule" then
		local t = n.rule == "open" and C.Tf("Gares et arrêts de %s : ouverts à tous.", "%s's stations and stops: open to all.", nm(n.co))
			or n.rule == "toll" and C.Tf("Gares et arrêts de %s : péage de %s par arrêt.", "%s's stations and stops: a toll of %s per stop.", nm(n.co), G.coMoney(n.fee))
			or C.Tf("Gares et arrêts de %s : privés.", "%s's stations and stops: private.", nm(n.co))
		return t .. (n.reset and C.T(" Pour toutes ses gares.", " For all its stations.") or "")
	end
	if k == "depot_rule" then
		return n.rule == "open" and C.Tf("Dépôts de %s : ouverts à tous.", "%s's depots: open to all.", nm(n.co))
			or n.rule == "toll" and C.Tf("Dépôts de %s : péage de %s par véhicule.", "%s's depots: a toll of %s per vehicle.", nm(n.co), G.coMoney(n.toll))
			or C.Tf("Dépôts de %s : privés.", "%s's depots: private.", nm(n.co))
	end
	return nil
end

-- (a field of G: the main chunk is at Lua's limit of 200 locals)
-- The other companies' stations that are not private (0.5.2: their rule, see mpfever_eco.lua's stationRule; before, their fee),
-- for the map (hud_share.txt), and the number of each company's stations that have a setting of their own (G.stopOwn, eco.txt).
-- The stations' keys are read only when some station has a setting of its own.
G.hudShare = function(reg, me)
	local E = C.eco()
	local ids, seen = {}, {}
	local own = {}
	local needKey = E == nil or next(reg.stationRule or {}) ~= nil or next(reg.shares or {}) ~= nil
	local function add(e) if type(e) == "number" and e >= 0 and not seen[e] then seen[e] = true; ids[#ids + 1] = e end end
	for _, sg in ipairs(R.entitiesWith("STATION_GROUP")) do
		local owner = R.ownerOf(sg)
		local oc = owner and CO.idOfEntity(reg, owner)
		if oc then
			local key = nil
			if needKey then
				local okk, k = pcall(R.sgKey, sg)
				key = okk and k or nil
			end
			local rule, isOwn = nil, false
			if E then
				local r, _, o = E.stationRule(reg, key, oc)
				rule, isOwn = r, o
			elseif key then
				rule = (C.shareFee(reg.shares, key) or 0) > 0 and "toll" or "private"
			end
			if isOwn then own[oc] = (own[oc] or 0) + 1 end
			if oc ~= me.id and rule and rule ~= "private" then
				add(sg)
				pcall(function()
					for _, stn in ipairs(api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP).stations) do
						add(stn)
						local okc, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForStation, stn)
						if okc then add(con) end
					end
				end)
			end
		end
	end
	G.stopOwn = own
	if os.getenv("MPFEVER_NOHUDSHARE") == "1" then return end
	table.sort(ids)
	local txt = table.concat(ids, " ")
	if txt == G.hudShareTxt then return end
	G.hudShareTxt = txt
	local f = C.IO.open(C.DIR .. BS .. "hud_share.txt", "wb")
	if not f then return end
	f:write(txt .. NL)
	f:close()
	K.coCtlSeq = K.coCtlSeq + 1
	local okT, tm = pcall(os.time)
	nativeCtl("hudshare " .. (((okT and tm or 0) % 1000000) * 100 + K.coCtlSeq % 100))
	log("companies: " .. #ids .. " entities of the stations the other companies share shown on the map")
end

-- The tracks the other companies opened, their segments and nodes (open_net.txt). 0.5.2: tracks are open by default, so the list
-- is in use in every companies game: only the track segments are looked at (R.entitiesWith("BASE_EDGE_TRACK"); before, every
-- segment of the map, streets included, with a component read each), and their owners are read again only when the number of
-- tracks or the open companies changed, or every 1800 frames (a sale or a merger changes owners without changing the number).
-- When the engine refuses to list the tracks, every segment as before; when listing them takes long, every 1800 frames instead of
-- 300 (G.openNetEvery). MPFEVER_OPENNETFAST=0: as before.
-- TF3 has no track component (api.type.ComponentType has BASE_EDGE and BASE_EDGE_STREET only): R.entitiesWith("BASE_EDGE_TRACK")
-- failed in every session and the component read of the fallback failed for every segment, so the list stayed empty and no company
-- could ever connect to another's open tracks (open_net.txt held nothing, "0 entities" in native.log). A track is a segment without
-- a street component, as the scenarios already tell them (see G.openTracks, which also keeps each segment's owner from one look to
-- the next instead of reading every segment again). MPFEVER_TRACKTYPE=0: as before (BASE_EDGE_TRACK, MPFEVER_OPENNETFAST read).
G.openNet = function(reg, me)
	local E = C.eco()
	if not E then return end
	local open, sig = {}, {}
	-- (0.6.2: the roads of the companies whose road rule is open, see E.roadRule; roads[ent] = true)
	local roads = {}
	for _, co in ipairs(reg.list) do
		if co.ent and co.id ~= me.id then
			local r = E.trackRule(reg, co)
			if r.rule == "open" or r.rule == "toll" then open[co.ent] = true; sig[#sig + 1] = co.ent end
			if E.roadRule and E.roadRule(reg, co).rule == "open" then roads[co.ent] = true; sig[#sig + 1] = "r" .. co.ent end
		end
	end
	local ids, seen = {}, {}
	local function add(e) if type(e) == "number" and e >= 0 and not seen[e] then seen[e] = true; ids[#ids + 1] = e end end
	if os.getenv("MPFEVER_TRACKTYPE") ~= "0" then
		G.openTracks(open, sig, me, add, roads)
	else
		local fast = os.getenv("MPFEVER_OPENNETFAST") ~= "0" and not G.openNetAll
		local edges = {}
		if #sig > 0 then
			if fast then
				local t0 = os.clock()
				edges = R.entitiesWith("BASE_EDGE_TRACK")
				local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
				if #edges == 0 and R.loopErrors.BASE_EDGE_TRACK then
					G.openNetAll = true
					fast = false
					log("companies: open tracks: the engine does not list the tracks (" .. tostring(R.loopErrors.BASE_EDGE_TRACK) .. "): every segment is looked at")
					edges = R.allEdges()
				else
					G.openNetEvery = ms > 100 and 1800 or 300
					G.openNetLogs = (G.openNetLogs or 0) + 1
					if G.openNetLogs <= 5 then log("companies: open tracks: " .. #edges .. " track segment(s) listed in " .. ms .. " ms") end
				end
			else
				edges = R.allEdges()
			end
		end
		if fast then
			local key = me.id .. "|" .. table.concat(sig, " ") .. "|" .. #edges
			if key == G.openNetKey and G.frames - (G.openNetFull or -100000) < 1800 then return end
			G.openNetKey = key
			G.openNetFull = G.frames
		end
		for _, e in ipairs(edges) do
			local okc, po = pcall(api.engine.getComponent, e, api.type.ComponentType.PLAYER_OWNED)
			if okc and po and open[po.player] then
				local isTrack = fast
				if not isTrack then
					local okt, tr = pcall(api.engine.getComponent, e, api.type.ComponentType.BASE_EDGE_TRACK)
					isTrack = okt and tr ~= nil
				end
				if isTrack then
					add(e)
					pcall(function()
						local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
						add(be.node0)
						add(be.node1)
					end)
				end
			end
		end
	end
	table.sort(ids)
	local txt = table.concat(ids, " ")
	if txt == G.openNetTxt then return end
	G.openNetTxt = txt
	local f = C.IO.open(C.DIR .. BS .. "open_net.txt", "wb")
	if not f then return end
	f:write(txt .. NL)
	f:close()
	K.coCtlSeq = K.coCtlSeq + 1
	local okT, tm = pcall(os.time)
	nativeCtl("opennet " .. (((okT and tm or 0) % 1000000) * 100 + K.coCtlSeq % 100))
	log("companies: " .. #ids .. " entities of the tracks the other companies opened")
end

-- (G.openNet) the track segments of the open companies (open: their player entities) and their nodes, through add. Every segment of
-- the street graph is listed by its map of nodes to segments, which also gives each segment's nodes (no segment is read for them).
-- Each segment's owner is read once and kept (G.openNetCache) while the segment has the same nodes (an id the engine gives again to
-- another segment has other nodes); every owner is read again when the open companies change and every 1800 frames (a sale or a
-- merger changes owners without changing the segments). Whether a segment is a track (no street component) is read only for the
-- segments of an open company, once. The whole look is timed: over 100 ms, G.openNet runs every 1800 frames instead of 300.
G.openTracks = function(open, sig, me, add, roads)
	roads = roads or {}
	local t0 = os.clock()
	if #sig == 0 then G.openNetCache = nil; return end
	local key = me.id .. "|" .. table.concat(sig, " ")
	if key ~= G.openNetSig or not G.openNetCache or G.frames - (G.openNetFull or -100000) >= 1800 then
		G.openNetSig, G.openNetFull, G.openNetCache = key, G.frames, {}
	end
	local cache = G.openNetCache
	local map = {}
	pcall(function() map = api.engine.system.streetSystem.getNode2SegmentMap() end)
	local ends, list = {}, {}
	for n, segs in pairs(map) do
		local k = 0
		pcall(function() k = #segs end)
		for i = 1, k do
			local e = segs[i]
			if type(e) == "number" and type(n) == "number" then
				local p = ends[e]
				if not p then p = {}; ends[e] = p; list[#list + 1] = e end
				p[#p + 1] = n
			end
		end
	end
	local PO, ST = api.type.ComponentType.PLAYER_OWNED, api.type.ComponentType.BASE_EDGE_STREET
	local reads, tracks = 0, 0
	for _, e in ipairs(list) do
		local p = ends[e]
		local a, b = p[1], p[2] or p[1]
		if a > b then a, b = b, a end
		local c = cache[e]
		if not c or c.a ~= a or c.b ~= b then
			reads = reads + 1
			local okc, po = pcall(api.engine.getComponent, e, PO)
			c = { a = a, b = b, o = (okc and po and po.player) or false }
			cache[e] = c
		end
		if c.o and (open[c.o] or roads[c.o]) then
			if c.t == nil then
				local okS, s = pcall(api.engine.getComponent, e, ST)
				c.t = okS and s == nil
			end
			-- (a track of a company with open tracks, a street of a company with open roads)
			if (c.t and open[c.o]) or (not c.t and roads[c.o]) then
				tracks = tracks + 1
				add(e)
				for _, n in ipairs(p) do add(n) end
			end
		end
	end
	for e in pairs(cache) do if not ends[e] then cache[e] = nil end end
	local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
	G.openNetEvery = ms > 100 and 1800 or 300
	G.openNetLogs = (G.openNetLogs or 0) + 1
	if G.openNetLogs <= 5 then
		log("companies: open tracks: " .. tracks .. " track or road segment(s) of the open companies, " .. #list .. " segment(s) looked at, " .. reads .. " owner(s) read, " .. ms .. " ms")
	end
end

-- The finance window's line of a shipped native build (JournalEntry.Construction key), where its builder's game booked it and
-- where the difference its replay costs here is booked (REFUND.book): a construction (station, depot, warehouse), stops and
-- signals, tracks, streets, else a removal (bulldozer)
G.costKind = function(a)
	local m = type(a.args) == "table" and type(a.args[1]) == "table" and a.args[1] or {}
	local sp = type(m.proposal) == "table" and m.proposal or {}
	for _, ce in ipairs(m.toAdd or {}) do
		local f = tostring(type(ce) == "table" and ce.fileName or ""):lower()
		-- (the town buildings a street moves: not the build's)
		if f:find("building") or f:find("/town") or f:find("industry") then goto continue end
		if f:find("depot") then return "DEPOT" end
		if f:find("warehouse") then return "WAREHOUSE" end
		if f:find("station") or f:find("airport") or f:find("airfield") or f:find("harbor") or f:find("port") or f:find("stop") then return "STATION" end
		if f ~= "" then return "OTHER" end
		::continue::
	end
	local objs = sp.edgeObjectsToAdd or {}
	if #objs > 0 then
		for _, o in ipairs(objs) do if type(o) == "table" and (o.category == 0 or o.category == nil) then return "STATION" end end
		return "SIGNAL"
	end
	local segs = sp.addedSegments or {}
	if #segs > 0 then
		for _, sg in ipairs(segs) do if type(sg) == "table" and sg.type == 1 then return "TRACK" end end
		return "STREET"
	end
	if #(m.toRemove or {}) > 0 or #(sp.removedSegments or {}) > 0 then return "BULLDOZER" end
	return nil
end

-- ---------------------------------------------------------------- the others' build previews (0.5.0)
-- What a player's build tool shows before the click (a street, a track, a station, a stop), the others see on the ground in
-- their games while it shows: a chain of circles along its segments, a circle where a construction goes, in the builder's
-- company colour (the game's mission zones, as the pending builds' circles: nothing of it reaches the world). Sent at most four
-- times a second while the tool shows, and gone after its build or 1.5 s without a new proposal (the tool closed); a preview not
-- heard of again for 6 s is taken away. The host's setting (MPFEVER_PREVIEWS=0) turns them off on every game.
G.pv = { lastEv = -1000, sentAt = -1000, sending = false, shown = {}, out = 0, logged = {} }
G.PV_TOOLS = { streetBuilder = "street", trackBuilder = "track", constructionBuilder = "construction", streetTerminalBuilder = "stop" }
G.pvPoints = function(param)
	local pts, r = {}, 6
	-- the tool's event gives { Proposal, ProposalData } by position (as the game's missions read it: mission_sim.script)
	local pr = type(param) == "table" and (param[1] or param.proposal) or param
	local sp = pr and pr.proposal
	local nodes = {}
	local function V(v) if v == nil then return nil end return { x = v.x or v[1], y = v.y or v[2], z = v.z or v[3] } end
	if sp then
		pcall(function() for i = 1, #sp.addedNodes do local n = sp.addedNodes[i]; nodes[n.entity] = V(n.comp.position) end end)
		local function pos(e)
			if nodes[e] then return nodes[e] end
			local ok, bn = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.BASE_NODE) end)
			return ok and bn and V(bn.position) or nil
		end
		local segs = {}
		pcall(function() for i = 1, #sp.addedSegments do segs[#segs + 1] = sp.addedSegments[i].comp end end)
		local total = 0
		local geo = {}
		for _, c in ipairs(segs) do
			local p0, p1 = pos(c.node0), pos(c.node1)
			if p0 and p1 then
				local t0, t1 = V(c.tangent0) or { x = 0, y = 0 }, V(c.tangent1) or { x = 0, y = 0 }
				local len = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
				total = total + len
				geo[#geo + 1] = { p0 = p0, p1 = p1, t0 = t0, t1 = t1, len = len }
			end
		end
		local step = math.max(10, total / 150)
		for _, g in ipairs(geo) do
			local n = math.max(1, math.ceil(g.len / step))
			for k = 0, n do
				local t = k / n
				local h00, h10, h01, h11 = 2 * t ^ 3 - 3 * t ^ 2 + 1, t ^ 3 - 2 * t ^ 2 + t, -2 * t ^ 3 + 3 * t ^ 2, t ^ 3 - t ^ 2
				pts[#pts + 1] = { math.floor((h00 * g.p0.x + h10 * g.t0.x + h01 * g.p1.x + h11 * g.t1.x) * 10 + 0.5) / 10,
					math.floor((h00 * g.p0.y + h10 * g.t0.y + h01 * g.p1.y + h11 * g.t1.y) * 10 + 0.5) / 10 }
			end
		end
	end
	-- the constructions it places: a circle each, where it goes
	pcall(function()
		for i = 1, #pr.toAdd do
			local tf = pr.toAdd[i].transf
			local x, y = tf[13], tf[14]
			if type(x) == "number" and type(y) == "number" then pts[#pts + 1] = { math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10, 30 } end
		end
	end)
	while #pts > 220 do table.remove(pts) end
	return pts, r
end
G.previewOut = function(tool, param)
	local kind = G.PV_TOOLS[tool]
	if not kind or not G.session.started then return end
	G.pv.lastEv = G.frames
	if G.frames - G.pv.sentAt < 15 then return end
	local okP, pts, r = pcall(G.pvPoints, param)
	local why = not okP and tostring(pts) or nil
	if not okP then pts, r = {}, 6 end
	-- (logged once per tool when it has points, and the first empty ones with what the event gave, to see why)
	local lk = tool .. (#pts > 0 and "" or ":empty")
	G.pv.logged[lk] = (G.pv.logged[lk] or 0) + 1
	if G.pv.logged[lk] == 1 then
		local shape = ""
		if #pts == 0 then
			pcall(function()
				local t = {}
				for k, v in pairs(type(param) == "table" and param or {}) do t[#t + 1] = tostring(k) .. "=" .. type(v) end
				shape = " (event " .. type(param) .. " {" .. table.concat(t, ",") .. "}" .. (why and (", " .. why) or "") .. ")"
			end)
		end
		log("build preview of the " .. kind .. " tool: " .. #pts .. " point(s) sent to the others" .. shape)
	end
	if #pts == 0 then return end
	G.pv.sentAt = G.frames
	G.pv.sending = true
	local color = nil
	pcall(function() for _, c in ipairs((R.CO or {}).list or {}) do if c.id == G.myCo then color = c.color end end end)
	send("preview", { k = kind, r = r, c = color or G.coMyColor(), pts = pts })
end
G.previewGone = function()
	if not G.pv.sending then return end
	G.pv.sending = false
	send("preview", { k = "", pts = {} })
end
G.previewClear = function(who)
	local s = G.pv.shown[who]
	if not s then return end
	for k = 1, s.n do pcall(api.gui.mission.removeZone, "mpfever_pv_" .. s.tag .. "_" .. k) end
	G.pv.shown[who] = nil
end
-- Signals on the map (0.5.14, idea G3 of 0.6): a player picks a kind in the MPFever window (here, watch out, build here), then
-- clicks the map; every game draws a circle there for 12 s, of the kind's colour with the player's colour in its middle, and
-- tells it in the chat (ping_journal.txt, read by the window). The interface only: nothing in the simulation, nothing replayed;
-- the launcher passes the message on as it does the build previews. A dedicated server's game shows none.
-- MPFEVER_PINGS=0: no signal.
G.pings = {}
G.PING_KINDS = { here = { 0.15, 0.7, 1.0 }, warn = { 1.0, 0.3, 0.1 }, build = { 0.25, 0.95, 0.3 } }
G.pingArm = function(p)
	if os.getenv("MPFEVER_PINGS") == "0" or type(p) ~= "table" or not G.PING_KINDS[p.k] then return end
	G.pingArmed = { k = p.k, till = os.clock() + 15 }
	log("map signal armed: " .. p.k .. " (the next click on the map places it)")
end
G.pingClick = function(name, param)
	local a = G.pingArmed
	G.pingArmed = nil
	if not a or os.clock() > a.till then return end
	local pos = nil
	if name == "select-world" and type(param) == "table" and type(param.pos) == "table" then pos = param.pos end
	if not pos then
		local m = api.gui.mouse
		if m and m.hasTerrainPosition and m.hasTerrainPosition() then pos = m.getTerrainPosition() end
	end
	local x, y, z = tonumber(pos and pos.x), tonumber(pos and pos.y), tonumber(pos and pos.z)
	if not (x and y) then log("map signal: no ground under the click"); return end
	-- (one signal every 2 s at most)
	if G.pingLast and G.frames - G.pingLast < 120 and G.frames >= G.pingLast then return end
	G.pingLast = G.frames
	local p = { x = x, y = y, z = z or 0, k = a.k, c = G.coMyColor and G.coMyColor() or nil, r = 60 }
	send("ping", p)
	H.ping(G.me, p, true)
end
H.ping = function(from, p, mine)
	if os.getenv("MPFEVER_PINGS") == "0" or C.SERVER or type(p) ~= "table" then return end
	if from == G.me and not mine then return end
	local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0
	local kind = G.PING_KINDS[p.k]
	-- (a number of the map: no NaN, no infinity)
	if not (kind and x and y and x == x and y == y and math.abs(x) < 1e6 and math.abs(y) < 1e6 and z == z and math.abs(z) < 1e5) then return end
	local who = tostring(from or "?"):gsub("%c", " ")
	-- (three signals of one player at most at a time: its oldest one goes)
	local mineN, oldest = 0, nil
	for key, s in pairs(G.pings) do
		if s.who == who then mineN = mineN + 1; if not oldest or s.till < G.pings[oldest].till then oldest = key end end
	end
	if mineN >= 3 and oldest then pcall(api.gui.mission.removeZone, oldest); pcall(api.gui.mission.removeZone, oldest .. "_c"); G.pings[oldest] = nil end
	G.pingN = (G.pingN or 0) + 1
	local key = "mpfever_ping_" .. G.pingN
	local r = math.max(25, math.min(200, tonumber(p.r) or 60))
	pcall(api.gui.mission.setZoneCircle, key, api.type.Vec2f.new(x, y), r, true, api.type.Vec4f.new(kind[1], kind[2], kind[3], 0.45), false, false)
	if type(p.c) == "number" then
		local cr, cg, cb = CO.rgb(p.c)
		pcall(api.gui.mission.setZoneCircle, key .. "_c", api.type.Vec2f.new(x, y), r / 3, true, api.type.Vec4f.new(cr, cg, cb, 0.7), false, false)
	end
	G.pings[key] = { till = G.frames + 720, who = who }
	C.appendFile(C.DIR .. BS .. "ping_journal.txt", table.concat({ tostring(os.time()), who, p.k, string.format("%.1f", x), string.format("%.1f", y), string.format("%.1f", z) }, "\t") .. NL)
	log("map signal of " .. who .. " (" .. p.k .. ") shown at " .. math.floor(x) .. "," .. math.floor(y))
end
-- Map signal scenario (MPFEVER_SCENARIO=pingtest): the host places a "watch out" signal at the middle of the map as a click
-- would; the client's mod.log must say "map signal of ... shown", and the circle goes after 12 s on both games
H.pingtest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	if C.ROLE ~= "host" then AUTO.results[1] = "nothing placed here (the host places it)"; return autoFinish() end
	G.pingArm({ k = "warn" })
	local okc, errc = pcall(G.pingClick, "select-world", { pos = { x = 0, y = 0, z = 0 } })
	AUTO.results[1] = "signal placed at 0,0: " .. (okc and "sent" or tostring(errc))
	G.waits[#G.waits + 1] = { at = G.frames + 60 * 15, fn = function()
		local n = 0
		for _ in pairs(G.pings) do n = n + 1 end
		AUTO.results[#AUTO.results + 1] = n .. " signal(s) still drawn after 15 s (0 expected)"
		autoFinish()
	end }
end

-- (0.6) Tenders scenario (MPFEVER_SCENARIO=tenders, one company per player: MPFEVER_COMPANIES=separate; MPFEVER_TDGOAL=n on the
-- host advised, MPFEVER_SPEED=4 to let the months pass): the host switches the game option "tenders" on as its lobby would
-- (G.featOpts, the session's options: MPFEVER_TDOPTS, else "tenders=1;tenders.freq=3"), its game sends f_opts, every game applies
-- it, the host's module publishes tender 1 (f_tenders_new). The host's results say when the first tender came and what it is,
-- after MPFEVER_TDWAIT more seconds (20) each company's count; the client's say what its game holds (the same tenders, the same
-- signature, the window's file, the chat notice). Compare both games' "signature" lines and the final "sync:" line.
H.tenders = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function S() local st = G.featSt; return type(st) == "table" and type(st.feat) == "table" and st.feat.tenders or nil end
	local function report(prefix)
		local st, s = G.featSt or {}, S()
		AUTO.results[#AUTO.results + 1] = prefix .. "options '" .. tostring(st.optsText) .. "' (" .. tostring(st.optsMode) .. ")"
		if not s then AUTO.results[#AUTO.results + 1] = "no tenders state"; return end
		for _, t in ipairs(s.open or {}) do
			local pr = {}
			for k, n in pairs(t.prog or {}) do pr[#pr + 1] = "company " .. k .. "=" .. n end
			table.sort(pr)
			AUTO.results[#AUTO.results + 1] = "open #" .. tostring(t.id) .. " " .. tostring(t.kind) .. " " .. tostring(t.a and t.a.name) .. (t.b and (" - " .. tostring(t.b.name)) or "")
				.. (t.cargo and (" " .. t.cargo) or "") .. ", goal " .. tostring(t.goal) .. ", bonus " .. tostring(t.prize) .. ", until month " .. tostring(t.deadline)
				.. ": " .. (#pr > 0 and table.concat(pr, ", ") or "nobody counted yet")
		end
		local F = C.feat()
		local M = F and F.byId and F.byId.tenders
		AUTO.results[#AUTO.results + 1] = "signature " .. tostring(M and M.signature and M.signature(st))
		local f = C.IO.open(C.DIR .. BS .. "feat_tenders_list.txt", "rb")
		local n = 0
		if f then for _ in (f:read("*a") or ""):gmatch("[^\n]+") do n = n + 1 end f:close() end
		AUTO.results[#AUTO.results + 1] = "window file feat_tenders_list.txt: " .. (f and (n .. " lines") or "MISSING")
		local c = C.IO.open(C.DIR .. BS .. "chat.txt", "rb")
		local told = false
		if c then
			-- (the notice in French or English; another language's is not recognised here)
			local all = (c:read("*a") or ""):lower()
			c:close()
			told = all:find("tender #", 1, true) ~= nil or all:find("appel d'offres n", 1, true) ~= nil
		end
		AUTO.results[#AUTO.results + 1] = "chat notice of a tender: " .. (told and "yes" or "NO")
	end
	if G.cmode ~= "separate" then AUTO.results[1] = "the tenders need one company per player (MPFEVER_COMPANIES=separate)"; return autoFinish() end
	if C.ROLE ~= "host" then
		report("")
		return autoFinish()
	end
	G.featOpts = os.getenv("MPFEVER_TDOPTS") or "tenders=1;tenders.freq=3"
	G.featOptsAt = nil
	log("AUTOTEST tenders: the session's options are now " .. G.featOpts)
	local t0 = G.frames
	local function poll()
		local s = S()
		if s and (tonumber(s.seq) or 0) >= 1 then
			AUTO.results[#AUTO.results + 1] = "tender 1 published after " .. math.floor((G.frames - t0) / 60) .. " s"
			local secs = tonumber(os.getenv("MPFEVER_TDWAIT") or "") or 20
			G.waits[#G.waits + 1] = { at = G.frames + secs * 60, fn = function() report("after " .. secs .. " s more: ") autoFinish() end }
			return
		end
		if G.frames - t0 > 90 * 60 then
			report("NO tender within 90 s: ")
			return autoFinish()
		end
		G.waits[#G.waits + 1] = { at = G.frames + 120, fn = poll }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 120, fn = poll }
end

-- (0.6) Competition scenario (MPFEVER_SCENARIO=markettest, one company per player with two companies at least): the host asks
-- its MPFever.exe for the game option "market" (the "opt" request of the window's Game tab), every game applies it (f_opts),
-- the host's game measures the market shares and sends them (f_market_snap, mpfever_feat_market.lua); each game says what it
-- applied (the month, its towns, industries and alerts: compare the two games' lines) and how many lines its window file has,
-- then shows the window's Competition tab (ui_tab_req.txt, as wintabs). 90 s after its part the host asks for the option off
-- again (the test profile's game options as before). Nothing of it runs without the scenario.
H.markettest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local t0 = G.frames
	local function say(line) AUTO.results[#AUTO.results + 1] = line; log("AUTOTEST markettest: " .. line) end
	if G.cmode ~= "separate" then say("skipped: one company per player only"); return autoFinish() end
	local function opt(arg)
		local f = C.IO.open(C.DIR .. BS .. "menu_req.txt", "wb")
		if f then f:write(tostring(os.time()) .. ".mkt" .. G.frames .. TAB .. "opt" .. TAB .. arg .. TAB .. tostring(C.NAME or "") .. TAB .. NL); f:close() end
		log("AUTOTEST markettest: opt " .. arg .. " asked to MPFever.exe")
	end
	if C.ROLE == "host" then opt("market=1") end
	local stage, tabSeq = "option", nil
	local function poll()
		local st = G.featSt or {}
		local S = type(st.feat) == "table" and st.feat.market or nil
		local secs = math.floor((G.frames - t0) / 60)
		if stage == "option" then
			if type(st.opts) == "table" and st.opts.market == "1" then
				say("option on in the game after " .. secs .. " s (" .. tostring(st.optsText) .. ")")
				stage = "measure"
			elseif secs > 60 then
				say("option NOT on after 60 s (the game has " .. tostring(st.optsText) .. ")")
				return autoFinish()
			end
		end
		if stage == "measure" then
			if type(S) == "table" and S.month ~= nil then
				local nco = 0
				for _, t in ipairs(type(S.towns) == "table" and S.towns or {}) do nco = nco + #(t.cos or {}) end
				say("measure of month " .. tostring(S.month) .. " applied after " .. secs .. " s: " .. #(S.towns or {}) .. " town(s), " .. nco
					.. " company share(s), " .. #(S.ind or {}) .. " industry(ies), alert number " .. tostring(S.seq))
				local n = 0
				local f = C.IO.open(C.DIR .. BS .. "feat_market_shares.txt", "rb")
				if f then for _ in (f:read("*a") or ""):gmatch("[^" .. NL .. "]+") do n = n + 1 end; f:close() end
				say("window file feat_market_shares.txt: " .. n .. " line(s)")
				tabSeq = tostring(900 + (G.frames % 90))
				local q = C.IO.open(C.DIR .. BS .. "ui_tab_req.txt", "wb")
				if q then q:write("f_market" .. TAB .. tabSeq .. NL); q:close() end
				stage, t0 = "tab", G.frames
			elseif secs > 120 then
				say("NO measure applied after 120 s (two companies at least? see 'feat market:' in mod.log)")
				return autoFinish()
			end
		elseif stage == "tab" then
			if G.frames - t0 < 240 then G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }; return end
			local s = ""
			local fr = C.IO.open(C.DIR .. BS .. "ui_tab_shown.txt", "rb")
			if fr then s = fr:read("*a") or ""; fr:close() end
			local seq, asked, shown, result, rows = s:match("^(%d+)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "(%d+)")
			if seq ~= tabSeq then say("Competition tab NOT DRAWN (no answer from the interface)")
			else say("Competition tab drawn as " .. tostring(shown) .. ", " .. tostring(result) .. ", " .. tostring(rows) .. " rows") end
			if C.ROLE == "host" then G.waits[#G.waits + 1] = { at = G.frames + 90 * 60, fn = function() opt("market=0") end } end
			return autoFinish()
		end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }
end

-- Territories scenario (0.6, MPFEVER_SCENARIO=terrtest, one company per player, the host then the client): the host's game puts
-- the game options "territory" and "handicap" into the game as its session's (MPFEVER_TERRTEST_OPTS, else every player at 50 %
-- of the start money and a 2 km territory for 5 years), then each game claims the biggest town its company may claim from the
-- module's own claim list, as the window's button does. Each game checks its claim in its state and its circle on the ground;
-- the client also checks that a station put at the host's town is turned down by the tool's hook (a proposal as the tool's
-- event gives it) and its own handicap. "AUTOTEST terrtest:" lines in mod.log; the sync check afterwards says whether both
-- games hold the same.
H.terrtest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST terrtest: " .. t) end
	local F = C.feat()
	local M = F and (F.load(log) and F.byId.territory)
	if not (K.FEAT and M) then note("FAILED: no options host or no territory module here"); return autoFinish() end
	if G.cmode ~= "separate" then note("FAILED: one company per player needed (this session: " .. tostring(G.cmode) .. ")"); return autoFinish() end
	if C.ROLE == "host" then
		G.featOpts = os.getenv("MPFEVER_TERRTEST_OPTS") or "handicap=1;handicap.money=50;territory=1"
		G.featOptsAt = nil
		note("session options set to " .. G.featOpts)
	end
	local tries = 0
	local function claimed()
		local st = G.featSt or {}
		local s = type(st.feat) == "table" and st.feat.territory or nil
		local mine = s and s.terr and s.terr[tostring(G.myCo)]
		if not mine then
			if tries < 3 then tries = tries + 1; G.waits[#G.waits + 1] = { at = G.frames + 600, fn = claimed }; return end
			note("FAILED: no territory of company " .. tostring(G.myCo) .. " in the state after 40 s")
			return autoFinish()
		end
		note("territory of company " .. G.myCo .. ": " .. tostring(mine.name) .. " at " .. tostring(mine.x) .. "," .. tostring(mine.y) .. ", radius " .. tostring(mine.r)
			.. ", until " .. tostring(mine.untilT))
		note("its circle drawn here: " .. ((M.drawn or {})["mpfever_terr_" .. G.myCo] and "yes" or "NO"))
		local hc = s.hc and s.hc[tostring(G.myCo)]
		note("handicap of company " .. G.myCo .. ": " .. (hc and (hc.pct .. " %, " .. hc.amount) or "none") .. (G.myCo == 1 and " (the savegame's company: none expected)" or ""))
		-- (the client: a station at another company's town, as the station tool's event gives it, must be turned down)
		for k, t in pairs(s.terr or {}) do
			if tonumber(k) ~= G.myCo and not t.ended then
				local m = { __mat = true }
				for i = 1, 16 do m[i] = 0 end
				m[1], m[6], m[11], m[16], m[13], m[14] = 1, 1, 1, 1, t.x + 10, t.y + 10
				local prop = { toAdd = { { fileName = "station/rail/modular_station/modular_station.con", transf = m, construction = { stations = { 1 }, depots = {} } } },
					toRemove = {}, proposal = { edgeObjectsToAdd = {} } }
				local okv, r = pcall(F.guiVeto, "constructionBuilder", "builder.proposalCreate", { prop, { errorState = { critical = false } } }, G.featSt, G.featBridge())
				local said = nil
				if okv and type(r) == "table" then for text in pairs(r.errorMessages or {}) do said = text end end
				note("a station at " .. tostring(t.name) .. " (company " .. k .. "): " .. (said and ("turned down: " .. said) or ("NOT turned down" .. (okv and "" or (": " .. tostring(r))))))
				m[13], m[14] = mine.x, mine.y
				local okw, r2 = pcall(F.guiVeto, "constructionBuilder", "builder.proposalCreate", { prop, { errorState = { critical = false } } }, G.featSt, G.featBridge())
				note("a station at its own town: " .. ((okw and r2 == nil) and "allowed" or "TURNED DOWN"))
			end
		end
		autoFinish()
	end
	-- (the options in the game first: the host's f_opts, every game at the same step)
	local waited = 0
	local function claim()
		local st = G.featSt or {}
		if not (F.on(st.opts, "territory")) then
			waited = waited + 1
			if waited < 12 then G.waits[#G.waits + 1] = { at = G.frames + 300, fn = claim }; return end
			note("FAILED: the option territory not in the game after 60 s (its options: " .. tostring(st.optsText) .. ")")
			return autoFinish()
		end
		note("the game's options: " .. tostring(st.optsText))
		local B = G.featBridge()
		local _, env = F.moduleOn("territory", st, B)
		local town = nil
		for _, t in ipairs(M.towns()) do
			if M.canClaim(st, env, G.myCo, t.x, t.y) then town = t; break end
		end
		if not town then note("FAILED: no town this company may claim"); return autoFinish() end
		M.townList = M.townList or {}
		M.townList[#M.townList + 1] = town
		local okr, sent = pcall(F.request, "territory", "claim", tostring(town.e), st, B)
		note("claim of " .. town.name .. " (town " .. town.e .. "): " .. (okr and "asked" or tostring(sent)))
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = claimed }
	end
	G.waits[#G.waits + 1] = { at = G.frames + 120, fn = claim }
end

-- (0.6) Stock market scenario (MPFEVER_SCENARIO=stocktest on both games, one company per player, the game option "stock" on in the
-- host's lobby (or gameopts=stock=1 in its mpfever_settings.txt), MPFEVER_STOCKPROTECT=0 on both games for a savegame younger than
-- 2 game years, MPFEVER_TOGETHER=1 so that both games run it at once (the launcher waits 300 s), MPFEVER_SPEED=4 advised): once
-- the stock market opens (the game month after the option came), the client buys 2 shares of company MPFEVER_STOCKTARGET (1, the
-- host's, by default) and sells 1 back; with MPFEVER_STOCKTAKEOVER=1 it then buys up to 5 over the next months and takes the
-- company over (its players get a new company; a computer company is retired). Each game notes the stock market's state at every
-- change and its companies' money at the end: the two logs must show the same states, and the checks no resynchronisation.
-- Without MPFEVER_TOGETHER=1 the host only notes the state it has (the launcher runs the host's part first, then the client's).
H.stocktest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function note(t) AUTO.results[#AUTO.results + 1] = t; log("AUTOTEST " .. t) end
	local function S() local st = G.featSt; return st and type(st.feat) == "table" and st.feat.stock or nil end
	if not (G.co and G.myCo) then
		-- (the client's company may come a moment after the scenario starts, MPFEVER_TOGETHER starts both at once: again in 2 s,
		-- for a minute)
		G.stockWaited = (G.stockWaited or 0) + 1
		if G.stockWaited <= 30 then
			AUTO.running = false
			G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function() H.stocktest(from, p) end }
			return
		end
		note("stocktest: not in the companies mode"); return autoFinish()
	end
	local function sorted(t) local ks = {} for k in pairs(t or {}) do ks[#ks + 1] = k end table.sort(ks, function(a, b) return tostring(a) < tostring(b) end) return ks end
	-- (the state as both games must have it: the month, the prices, the holdings, the computer companies retired)
	local function sig()
		local s = S()
		if not s then return "none" end
		local t = { "month " .. tostring(s.month) }
		for _, k in ipairs(sorted(s.price)) do t[#t + 1] = "price" .. k .. "=" .. tostring(s.price[k]) end
		for _, k in ipairs(sorted(s.hold)) do
			for _, h in ipairs(sorted(s.hold[k])) do t[#t + 1] = "hold" .. k .. "/" .. h .. "=" .. tostring(s.hold[k][h]) end
		end
		local r = sorted(s.retired)
		if #r > 0 then t[#t + 1] = "retired " .. table.concat(r, ",") end
		return table.concat(t, " ")
	end
	local function moneyNote()
		for _, c in ipairs(G.co.list) do
			local b = nil
			if c.ent then pcall(function() b = api.engine.util.finance.getPlayersBalance(c.ent) end) end
			note("company " .. c.id .. " " .. tostring(c.gone or "playing") .. " money " .. tostring(b))
		end
	end
	local target = tonumber(os.getenv("MPFEVER_STOCKTARGET") or "") or 1
	local takeover = os.getenv("MPFEVER_STOCKTAKEOVER") == "1"
	local function held() local s = S(); return math.floor(tonumber(s and s.hold and s.hold[tostring(target)] and s.hold[tostring(target)][tostring(G.myCo)]) or 0) end
	local function ask(kind, payload) local okR, errR = pcall(G.featRequest, { m = "stock", kind = kind, payload = payload }); if not okR then note(kind .. " failed: " .. tostring(errR)) end end
	local since, lastSig, done = os.clock(), nil, false
	local mine = G.myCo
	local together = os.getenv("MPFEVER_TOGETHER") == "1"
	-- (each game: the state at every change, every 2 s; the host's part ends after 270 s, the launcher waits 300 s)
	local function watch()
		local s = sig()
		if s ~= lastSig then lastSig = s; note("stock state: " .. s) end
		if done or (C.ROLE == "host" and (not together or os.clock() - since > 270)) or os.clock() - since > 290 then
			moneyNote()
			return autoFinish()
		end
		G.waits[#G.waits + 1] = { at = G.frames + 120, fn = watch }
	end
	local okOn = G.featSt and type(G.featSt.opts) == "table" and G.featSt.opts.stock == "1"
	note(C.ROLE .. " plays company " .. tostring(mine) .. "; option stock " .. (okOn and "on" or "not on yet (the host's options come within 10 s)") .. ", protection " .. tostring(os.getenv("MPFEVER_STOCKPROTECT") or "24 months"))
	watch()
	if C.ROLE == "host" then return end
	-- the client's steps, each waiting for its condition (at most 120 s: several game months at MPFEVER_SPEED=4)
	local steps = {}
	local function step(what, start, ok) steps[#steps + 1] = { what = what, start = start, ok = ok } end
	step("the stock market opens", function() end, function() local s = S(); return s and s.month and s.price and s.price[tostring(target)] ~= nil end)
	step("buy 2 shares of company " .. target, function() ask("buy", { co = target, n = 2 }) end, function() return held() == 2 end)
	step("sell 1 back", function() ask("sell", { co = target, n = 1 }) end, function() return held() == 1 end)
	if takeover then
		-- (two shares a month at most: buy the month's, then wait for the next month, up to 5; the takeover's share is a next
		-- month's too)
		for _ = 1, 3 do
			step("buy up to 5 and wait for the next month", function()
				local s = S()
				local n = math.min(2, 5 - held())
				if n > 0 then ask("buy", { co = target, n = n }) end
				AUTO.points.stockMonth = s and s.month
			end, function() local s = S(); return s and s.month ~= AUTO.points.stockMonth end)
		end
		step("take company " .. target .. " over", function()
			local s = S()
			local P = s and s.price and tonumber(s.price[tostring(target)]) or 0
			local prem = 25
			pcall(function() prem = tonumber(C.feat().param(G.featSt.opts, "stock", "premium")) or 25 end)
			ask("takeover", { co = target, n = held() > 5 and 0 or 1, max = math.floor(P * (100 + prem) / 100) * (10 - held()) })
		end, function() local c = CO.find(G.co, target); return c and c.gone == "taken" end)
	end
	local i, at = 0, 0
	local function nextStep()
		i = i + 1
		local s = steps[i]
		if not s then
			note("client plays company " .. tostring(G.myCo) .. " (first " .. tostring(mine) .. "), holds " .. held() .. " of company " .. target)
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function() done = true end }
			return
		end
		pcall(s.start)
		at = os.clock()
		local function poll()
			local okP, d = pcall(s.ok)
			if okP and d then note("step '" .. s.what .. "': done in " .. math.floor(os.clock() - at) .. " s"); return nextStep() end
			if os.clock() - at > 120 then note("step '" .. s.what .. "': NOT DONE within 120 s"); return nextStep() end
			G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }
		end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = poll }
	end
	nextStep()
end

G.pingTick = function()
	for key, s in pairs(G.pings) do
		if G.frames > s.till or G.frames < s.till - 2000 then
			pcall(api.gui.mission.removeZone, key)
			pcall(api.gui.mission.removeZone, key .. "_c")
			G.pings[key] = nil
		end
	end
	if G.pingArmed and os.clock() > G.pingArmed.till then G.pingArmed = nil; log("map signal: no click within 15 s") end
end

H.preview = function(from, p)
	if from == G.me or not from then return end
	if os.getenv("MPFEVER_PREVIEWS") == "0" then return end
	local old = G.pv.shown[from]
	G.pv.out = G.pv.out + 1
	local tag = old and old.tag or tostring(G.pv.out)
	local pts = type(p.pts) == "table" and p.pts or {}
	local n = 0
	local rr, gg, bb = 0.25, 0.6, 1.0
	if type(p.c) == "number" then rr, gg, bb = CO.rgb(p.c) end
	local col = api.type.Vec4f.new(rr, gg, bb, 0.45)
	for _, q in ipairs(pts) do
		if type(q) == "table" and type(q[1]) == "number" and type(q[2]) == "number" and n < 220 then
			n = n + 1
			pcall(api.gui.mission.setZoneCircle, "mpfever_pv_" .. tag .. "_" .. n, api.type.Vec2f.new(q[1], q[2]), (type(q[3]) == "number" and q[3]) or tonumber(p.r) or 6, true, col, false, false)
		end
	end
	-- (the circles the previous preview had beyond this one's)
	if old then for k = n + 1, old.n do pcall(api.gui.mission.removeZone, "mpfever_pv_" .. tag .. "_" .. k) end end
	if n == 0 then G.pv.shown[from] = nil; return end
	G.pv.shown[from] = { tag = tag, n = n, frame = G.frames }
	if not G.pv.logged["in:" .. from] then G.pv.logged["in:" .. from] = true; log("build preview of " .. tostring(from) .. " (" .. tostring(p.k) .. "): " .. n .. " circle(s) shown") end
end
G.previewTick = function()
	-- this player's tool closed (no proposal for 1.5 s): the others take its preview away
	if G.pv.sending and G.frames - G.pv.lastEv > 90 then G.previewGone() end
	for who, s in pairs(G.pv.shown) do
		if G.frames - s.frame > 360 then G.previewClear(who) end
	end
end

-- The computer companies' journal (the MPFever window's AI tab, and the chat): what they build and buy, and where. The host's
-- module (mpfever_ai.lua) sends each entry to every game and gives it to its own; each game appends it to ai_journal.txt
-- ("time co kind x y z a b", tab-separated), which the interface reads.
-- The host's names (issue #97, see R.nameChanges): taken here once the entity is there, through the engine (a name changes
-- nothing in the simulation, and it is no player's command to ship). A game in the host's language has them already.
G.nameQueue = {}
H.namesync = function(from, p)
	if C.ROLE == "host" or os.getenv("MPFEVER_NAMESYNC") == "0" or type(p) ~= "table" or type(p.list) ~= "table" then return end
	local till = G.frames + 1800
	for _, v in ipairs(p.list) do
		local e = type(v) == "table" and tonumber(v.e) or nil
		if e and (v.k == "STATION_GROUP" or v.k == "LINE" or v.k == "TRANSPORT_VEHICLE") and type(v.nm) == "string" and #v.nm <= 200 then
			G.nameQueue[e] = { k = v.k, nm = v.nm, till = till }
		end
	end
end
G.nameTick = function()
	if next(G.nameQueue) == nil then return end
	local seen = 0
	for e, v in pairs(G.nameQueue) do
		seen = seen + 1
		if seen > 60 then break end
		local okc, has = pcall(function() return api.engine.getComponent(e, api.type.ComponentType[v.k]) ~= nil end)
		if okc and has then
			if R.nameOf(e) ~= v.nm then
				local oks, err = pcall(function() O.sendCommand(api.cmd.makeEntitySetNameCmd(e, v.nm)) end)
				G.namesTaken = (G.namesTaken or 0) + 1
				if G.namesTaken <= 20 or G.namesTaken % 100 == 0 then
					log("names: " .. v.k .. " " .. e .. " takes the host's name " .. C.ser(v.nm):sub(1, 80) .. " (was " .. C.ser(R.nameOf(e)):sub(1, 80) .. ")"
						.. (oks and "" or (": " .. tostring(err))) .. " [" .. G.namesTaken .. " so far]")
				end
			end
			G.nameQueue[e] = nil
		elseif G.frames > v.till then
			G.nameQueue[e] = nil
		end
	end
end

H.aijournal = function(from, p)
	if type(p) ~= "table" then return end
	local function clean(v) return (tostring(v == nil and "" or v):gsub("%c", " "):sub(1, 120)) end
	C.appendFile(C.DIR .. BS .. "ai_journal.txt", table.concat({ clean(p.t), clean(p.co), clean(p.kind), clean(p.x), clean(p.y), clean(p.z),
		clean(p.a), clean(p.b) }, "\t") .. NL)
end

-- game companies (mpfever_ai.lua): what the module needs from here, then its step on the host. MPFEVER_AIDEV=<folder>: the module
-- is read again from that folder whenever it changes, and ai_probe.lua there runs once each time it changes (tests)
G.aiEnv = function()
	return { api = api, G = G, C = C, R = R, CO = CO, log = log, send = send, queueLocal = queueLocal, toSim = toSim,
		stampFor = stampFor, pausedStamp = pausedStamp, gameTime = gameTime, gameSpeed = gameSpeed, deferredSend = deferredSend,
		replaySend = replaySend, nodePosition = nodePosition, groundZ = groundZ, vec = vec, shortErr = shortErr, nativeCtl = nativeCtl,
		playerContext = playerContext, withActor = withActor, STEP = STEP, BS = BS, NL = NL, H = H }
end
G.aiStep = function(st)
	local dev = os.getenv("MPFEVER_AIDEV")
	local function loadFile(path)
		local f = C.IO.open(path, "rb")
		if not f then return nil end
		local src = f:read("*a")
		f:close()
		return src
	end
	if dev and G.frames % 30 == 0 then
		for _, name in ipairs({ "mpfever_ai.lua", "ai_probe.lua" }) do
			local src = loadFile(dev .. BS .. name)
			local key = src and (#src .. ":" .. (src:sub(1, 64)) .. (src:sub(-64)))
			G.aiSrcSeen = G.aiSrcSeen or {}
			if src and G.aiSrcSeen[name] ~= key then
				G.aiSrcSeen[name] = key
				local chunk, err = load(src, "=" .. name, "t", _ENV)
				if not chunk then log("AI " .. name .. ": " .. tostring(err))
				elseif name == "mpfever_ai.lua" then
					local okm, m = pcall(chunk)
					if okm and type(m) == "table" then G.aiMod = m; log("AI module (re)loaded from " .. dev) else log("AI module: " .. tostring(m)) end
				else
					local okp, errp = pcall(chunk, G.aiEnv(), st)
					log("AI probe ran: " .. (okp and "ok" or tostring(errp)))
				end
			end
		end
	end
	if not G.aiMod and not dev and not G.aiTried then
		G.aiTried = true
		local okm, m = pcall(ug_require, "mpfever_ai.lua")
		if not okm then okm, m = pcall(ug_require, "mpfever_1::/mpfever_ai.lua") end
		if okm and type(m) == "table" then G.aiMod = m else log("AI module not loaded: " .. tostring(m)) end
	end
	if G.aiMod and G.aiMod.tick then
		local okt, errt = pcall(G.aiMod.tick, G.aiEnv(), st)
		if not okt and G.frames - (G.aiErrAt or -10000) > 600 then G.aiErrAt = G.frames; log("AI step failed: " .. tostring(errt)) end
	end
end

-- (0.6) The game options (mpfever_feat.lua, docs/FEATURES-0.6.md), the interface's side. The session's options come with the
-- session (G.featOpts, see H.session); the game's are those every game applied from the host's f_opts (st.optsText, read here every
-- frame). Nothing below runs while the game has none on and the session asks for none (G.featOn false, G.featOpts empty).
-- what the modules' gui, request and allow get from here (the module's env is made of it, see F.guiEnv)
G.featBridge = function()
	local B = G.featB
	if not B then
		B = { log = log, gameTime = gameTime, R = R, CO = CO, T = C.T,
			-- (the calendar's date at a game time, now by default: what the host's game reads to date its figures, see stats)
			date = function(t)
				local ok, d = pcall(function()
					local x = api.engine.util.getCalendarDate(tonumber(t) or gameTime())
					return { year = x.year, month = x.month, day = x.day }
				end)
				return ok and d or nil
			end,
			-- (a company's name as the players see it, the chat's: the game's name of its player entity, else the registry's)
			coName = function(id) return G.coName(G.co, tonumber(id)) end,
			-- (an event of a module: stamped and applied by every game at the same step, as the host's events)
			send = function(name, param) return G.coEvent(name, param) ~= false end,
			chat = function(text) return G.featChat(text) end,
			-- (a file of the session folder for the window, written only when its text changed)
			write = function(file, text)
				G.featFiles = G.featFiles or {}
				if G.featFiles[file] == text then return true end
				local f = C.IO.open(C.DIR .. BS .. file, "wb")
				if not f then return false end
				f:write(text)
				f:close()
				G.featFiles[file] = text
				return true
			end,
			-- (0.6, T = C.T above: the player's language; the points of a tool's route; the other players this game hears from:
			-- their names, sorted, see F.guiEnv)
			pvPoints = function(param) return G.pvPoints(param) end,
			players = function()
				local out = {}
				for name in pairs(G.peers or {}) do if type(name) == "string" and name ~= G.me then out[#out + 1] = name end end
				table.sort(out)
				return out
			end,
			-- (a company's lots: mpfever_eco.lua's E.lotsOf, as the simulation's env.lots)
			lots = function(st, id)
				local E, reg = C.eco(), st and st.co
				local c = E and E.lotsOf and type(reg) == "table" and CO.find(reg, tonumber(id)) or nil
				if not (c and c.ent) then return nil end
				return E.lotsOf({ R = R, log = log, CO = CO }, c)
			end }
		G.featB = B
	end
	B.isHost, B.me, B.myCo = C.ROLE == "host", G.me, G.myCo
	B.mode = G.cmode == "separate" and "separate" or "shared"
	-- (a dedicated server's owner, its game only: the session's owner it names, see H.session)
	B.owner = C.SERVER and G.coOwner or nil
	return B
end
-- a notice in this game's chat only (the window's chat file, as MPFever.exe writes it: id 0, from « MPFever »)
G.featChat = function(text)
	-- (control bytes listed, not %c: under a code page locale %c may take a byte of a UTF-8 character, issue #30)
	text = tostring(text or ""):gsub("[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. "]", " ")
	log("options (chat here): " .. text)
	local okT, t = pcall(os.time)
	return C.appendFile(C.DIR .. BS .. "chat.txt", "0" .. TAB .. tostring(okT and t or 0) .. TAB .. "msg" .. TAB .. "MPFever" .. TAB .. text .. NL)
end
-- every frame (guiUpdate): the host's game sends the session's options when the game's differ (f_opts, at most every 10 s, not
-- during a resynchronisation: every game applies them at the same step), then the modules' gui about once a second
G.featGui = function(st)
	local have = type(st.optsText) == "string" and st.optsText or ""
	G.featOn = have ~= ""
	G.featSt = st
	-- (G.featTestOpts: the options an autotest scenario puts into a test's session, see H.journaltest and H.permstest; never set
	-- otherwise)
	local want = G.featTestOpts or G.featOpts
	if not G.featOn and (want == nil or want == "") then G.featAllow, G.featVeto = false, false; return end
	local F = C.feat()
	if not F then return end
	F.load(log)
	G.featAllow = G.featOn and F.wantsAllow(have)
	G.featVeto = G.featOn and F.wantsVeto ~= nil and F.wantsVeto(have)
	if C.ROLE == "host" and want ~= nil and G.connected and G.session.started and not G.session.resync then
		local mode = G.cmode == "separate" and "separate" or "shared"
		-- (the canon of the session's text, kept while it is the same)
		if G.featCanonOf ~= mode .. "|" .. want then G.featCanonOf, G.featCanon = mode .. "|" .. want, F.canon(want, mode) end
		local s = G.featCanon
		-- (also when only the company mode differs: a savegame played in the other mode keeps the same text, and the modules'
		-- simulation half reads the mode it was sent with, see F.simMode)
		if (s ~= have or (have ~= "" and st.optsMode ~= nil and st.optsMode ~= mode)) and G.frames - (G.featOptsAt or -100000) > 600 then
			G.featOptsAt = G.frames
			log("options: the session's options (" .. (s ~= "" and s or "all off") .. ") into the game (it has " .. (have ~= "" and have or "none") .. ")")
			G.coEvent("f_opts", { s = s, mode = mode })
		end
	end
	if G.featOn then F.gui(st, G.featBridge(), os.clock()) end
	-- (this game's session name to its simulation, for its own builds: see SIM.featWho; again every 30 s, as a load starts the
	-- simulation's Lua state again)
	if G.featOn and G.connected and (G.featMeSent ~= G.me or G.frames - (G.featMeAt or -100000) > 1800) then
		G.featMeSent, G.featMeAt = G.me, G.frames
		pcall(toSim, "f_me", { name = G.me })
	end
end
-- A window's command (an "act_req" of ui.log, before it is stamped) or a tool's build held by the DLL (fn "nativeBuild"), checked by
-- the modules on (M.allow) before anything is sent: refused, it is never applied anywhere (no desync), the chat says why and a
-- window's command gets its refusal as a refused action does. A module that fails lets it through (see F.allow).
G.featRefuse = function(p)
	local ok, refused = pcall(function()
		local F = C.feat()
		if not F then return false end
		local a = { fn = p.fn, args = p.args, co = tonumber(p.co) or G.myCo, origin = G.me, native = p.native, natId = p.natId, proposal = p.proposal }
		local allowed, why, M = F.allow(a, G.featSt or {}, G.featBridge())
		if allowed then return false end
		local reason = (type(why) == "string" and why ~= "") and why or C.T("Refusé par une option de la partie.", "Refused by a game option.")
		log("options: " .. tostring(a.fn) .. (a.natId and (" " .. a.natId) or "") .. " refused here by " .. tostring(M and M.ID) .. ": " .. reason)
		G.featRefused = (G.featRefused or 0) + 1
		-- (a speed request comes again while the buttons wait: the same reason said once in 3 s)
		if not (p.speed and G.featSaid == reason and G.frames - (G.featSaidAt or -1000) < 180) then G.featChat(reason) end
		G.featSaid, G.featSaidAt = reason, G.frames
		if p.tok then C.appendFile(C.DIR .. BS .. "results.log", C.line("result", { tok = p.tok, id = p.id, fn = p.fn, success = false, err = "game option: " .. reason })) end
		return true
	end)
	if not ok then log("options: allow failed: " .. tostring(refused)) end
	return ok and refused == true
end
-- the build a tool applies (its event, a frame or two before the DLL reports it held), for the modules' allow
G.featTool = function(param)
	local pr = type(param) == "table" and (param[1] or param.proposal) or nil
	local ok, compact = pcall(C.compactProposal, pr)
	G.featToolCopy = (pr ~= nil and ok) and { frame = G.frames, compact = compact } or nil
end
G.featTakeTool = function()
	local t = G.featToolCopy
	G.featToolCopy = nil
	if t and G.frames - t.frame <= 5 then return t.compact end
	return nil
end
-- The game's interface events on this game (guiHandleEvent, only while G.featVeto), for the modules on that answer them (M.guiVeto:
-- a tool's proposal, the vehicle store's buy button, the line window's delete; every module on hears it, see F.guiVeto): the
-- answer guiHandleEvent returns, as company.script's permits ({ errorMessages, skipRender }: the tool shows the reasons in red and
-- does not build), nil for none (as before 0.6). Anything failing here answers nothing. The first answers of each kind are
-- logged (a tool turned down: by which module, and why), for the in-game check that the game heeds them alongside its own scripts.
G.featGuiVeto = function(id, name, param)
	local F = C.feat()
	if not (F and F.guiVeto and G.featSt) then return nil end
	local r, M = F.guiVeto(id, name, param, G.featSt, G.featBridge())
	if r ~= nil then
		G.featVetoLog = G.featVetoLog or {}
		local k = tostring(id) .. "/" .. tostring(name)
		local n = (G.featVetoLog[k] or 0) + 1
		G.featVetoLog[k] = n
		if n <= 3 or n % 500 == 0 then
			local okS, s = pcall(function()
				if type(r) ~= "table" then return tostring(r) end
				local why = {}
				for t in pairs(type(r.errorMessages) == "table" and r.errorMessages or {}) do why[#why + 1] = tostring(t) end
				table.sort(why)
				return "turned down by " .. tostring(M and M.ID) .. ": " .. table.concat(why, " | ")
			end)
			log("options: " .. k .. " answered by " .. tostring(M and M.ID) .. " (" .. n .. "): " .. (okS and s or "?"))
		end
	end
	return r
end
-- a request of the MPFever window (ui.log "feat_req": the module, its kind and payload) to that module of this game
G.featRequest = function(p)
	local F = C.feat()
	if F then F.request(p.m, p.kind, p.payload, G.featSt or {}, G.featBridge()) end
end
-- a paused action applied here (runPausedActions): to the simulation, whose modules hear it as the others (F.simAction); dg: the
-- modules' copies of it taken before it was applied (G.featDigests)
G.featPausedAct = function(a, r, dg)
	local args = nil
	if a.fn ~= "makeWorldBuildProposalCmd" and type(a.args) == "table" then args = a.args end
	toSim("f_act", { a = { fn = a.fn, args = args, co = a.co, origin = a.origin, uid = a.uid, at = a.at, tok = a.tok, paused = true }, ok = r.success == true, dg = dg })
end
-- what the modules on keep of an action before it is applied here (see F.digests); nil when none takes a copy
G.featDigests = function(a)
	local F = C.feat()
	local st = G.featSt
	if not (F and type(st) == "table") then return nil end
	return F.digests(st.optsText, a)
end
-- (0.6) A tool's build of a player as the games ship it, its references not translated yet: this game's own when it is shipped
-- (shipNativeBuilds, shipTerrain), another player's as this game replays it (runNativeReplays). The simulation does not know who
-- made a tool's build (SIM.featNative), so its copy for the modules that keep one (M.digest: the journal) goes to the simulation
-- from here (f_act, only to those modules: the others hear the build there). Not stamped: such a module keeps a state that every
-- game ends with whatever the order the builds come in (the journal sorts its entries by the build's own game time). Nothing
-- while no option is on, nor when no module on keeps copies.
G.featNativeAct = function(a)
	if type(a) ~= "table" or a.fn == "mpfCoJoin" then return end
	local dg = G.featDigests(a)
	if not dg then return end
	toSim("f_act", { a = { fn = a.fn, co = a.co, origin = a.origin, uid = a.uid, at = a.at, tok = a.tok, native = true, paused = a.paused }, ok = true, dg = dg, only = true })
end

-- Players' journal scenario (MPFEVER_SCENARIO=journaltest, 0.6, each game in its turn): the host's game puts the options journal,
-- builtby and playerview into the test's session (G.featTestOpts: MPFever.exe does not know them, so the MPFever window shows no
-- Journal tab in this test; the games apply them from the host's f_opts as in a real session), then this game lays a road as the
-- street tool does, demolishes it, and asks for the view of the other game's player. Its results: the journal's entries of this
-- game (its road, its demolition, the other player's entries when that game ran before), the view's answer and whether the camera
-- took it, the tab's file. Every game's mod.log says "feat journal: ..." for each entry it makes (the other game's too).
H.journaltest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST journaltest " .. t); AUTO.results[#AUTO.results + 1] = t end
	local F = C.feat()
	if F then F.load(log) end
	local M = F and F.byId.journal
	if not M then say("the options host or the journal module is not loaded"); return autoFinish() end
	if C.ROLE == "host" then
		G.featTestOpts = "builtby=1;journal=1;journal.details=1;playerview=1"
		G.featOptsAt = nil
		say("options put into the test's session: " .. G.featTestOpts)
	end
	local function J() local st = G.featSt; return type(st) == "table" and type(st.feat) == "table" and type(st.feat.journal) == "table" and st.feat.journal or nil end
	local function count(kind, own)
		local n, me = 0, M.key(G.me)
		for _, e in ipairs(J() and M.entries(J()) or {}) do
			if (kind == nil or e.kind == kind) and ((M.key(e.who) == me) == own) then n = n + 1 end
		end
		return n
	end
	local function later(frames, fn) G.waits[#G.waits + 1] = { at = G.frames + frames, fn = fn } end
	local function finish()
		local kinds = {}
		for _, e in ipairs(J() and M.entries(J()) or {}) do kinds[#kinds + 1] = tostring(e.who) .. ":" .. tostring(e.kind) end
		say("journal here: " .. #kinds .. " entr(y/ies): " .. table.concat(kinds, ", "):sub(1, 400))
		say("entries of the other player here: " .. count(nil, false))
		local f = C.IO.open(C.DIR .. BS .. "feat_journal_log.txt", "rb")
		local txt = f and f:read("*a") or nil
		if f then f:close() end
		local n = 0
		for _ in tostring(txt or ""):gmatch("[^\n]+") do n = n + 1 end
		say("the tab's file feat_journal_log.txt: " .. (txt and (n .. " line(s)") or "MISSING"))
		autoFinish()
	end
	-- 4. the view of the other game's player (as the tab's button: the module's request "view")
	local function view()
		local list = G.featBridge().players()
		local other = list[1]
		if not other then say("view: no other player"); return finish() end
		local g = M.guiState()
		g.status = nil
		F.request("journal", "view", M.key(other), G.featSt or {}, G.featBridge())
		local tries = 0
		local function poll()
			tries = tries + 1
			local s = g.status
			if s and s[1] ~= "ask" then
				local cam = nil
				pcall(function() cam = M.camGet() end)
				say("view of " .. tostring(other) .. ": " .. tostring(s[1]) .. " (view = the camera took it), camera now " .. (cam and string.format("%.0f,%.0f d=%.0f", cam[1], cam[2], cam[3]) or "?"))
				return finish()
			end
			if tries > 40 then say("view of " .. tostring(other) .. ": NO ANSWER in 20 s (status " .. tostring(s and s[1]) .. ")"); return finish() end
			later(30, poll)
		end
		later(30, poll)
	end
	-- 2. and 3. a road, then its demolition, each sent as the street tool's build
	local tries = 0
	local function road()
		tries = tries + 1
		if tries > 8 then say("no road could be built at 8 places"); return view() end
		local okp, err = pcall(function()
			local n, info, pn, a = matrixPlace((p.offset or 0) + (C.ROLE == "host" and 300 or 200) + tries * 5)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
			local sp = buildMatrixProposal(o, n, pn, a)
			local before = {}
			for _, e in ipairs(R.allEdges()) do before[e] = true end
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				local new = {}
				for _, e in ipairs(R.allEdges()) do if not before[e] then new[#new + 1] = e end end
				if not success or #new == 0 then later(40, road); return end
				later(300, function()
					say("road built: journal entries 'road' of this player here: " .. count("road", true) .. " (1 expected)")
					local okr, P = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal(new) end)
					if not okr or not P then say("no removal proposal: " .. tostring(P)); return view() end
					deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res2, success2)
						later(300, function()
							say("road demolished (" .. tostring(success2) .. "): journal entries 'road_del' of this player here: " .. count("road_del", true) .. " (1 expected)")
							view()
						end)
					end)
				end)
			end)
		end)
		if not okp then say("road " .. tries .. " failed: " .. shortErr(err)); later(40, road) end
	end
	-- 1. the options on in the game (applied by every game from the host's f_opts, at most 10 s after they were asked)
	local waited = 0
	local function waitOn()
		local s = type(G.featSt) == "table" and G.featSt.optsText or ""
		if s:find("journal=1", 1, true) and s:find("playerview=1", 1, true) then say("options on in the game: " .. s); return road() end
		waited = waited + 1
		if waited > 80 then say("the options are not on in the game after 40 s (" .. tostring(s) .. ")"); return finish() end
		later(30, waitOn)
	end
	waitOn()
end

-- Team permissions scenario (0.6, MPFEVER_SCENARIO=permstest, a co-op session, any savegame; a vehicle with a depot lets the client
-- try a real purchase): the host switches the game options "perms" (budget 1 000 000) and "plans" on for this session (whatever
-- MPFever.exe's options), takes the client's Vehicles and Speed rights away and puts a note on the map; the client's game then
-- refuses its own purchase and its pause before anything is sent, its vehicle store's buy button says why, and it asks for an
-- approval, which every game must hold. "AUTOTEST permstest: ..." in both mod.log; the last check must stay in sync (nothing
-- refused was ever sent).
H.permstest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(line) log("AUTOTEST permstest: " .. line); AUTO.results[#AUTO.results + 1] = "permstest: " .. line end
	local function perms() local st = G.featSt or {}; return type(st.feat) == "table" and st.feat.perms or nil end
	local function on() local st = G.featSt or {}; return type(st.optsText) == "string" and st.optsText:find("perms=1", 1, true) ~= nil end
	-- (cond polled every 30 frames, then done(cond met) once it is or after that many frames)
	local function wait(cond, frames, done)
		local t0 = G.frames
		local function poll()
			local ok = cond()
			if ok or G.frames - t0 > frames then return done(ok) end
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = poll }
		end
		poll()
	end
	if G.cmode == "separate" then say("co-op only (the host leads the co-op's team): nothing tried"); return autoFinish() end
	if C.ROLE == "host" then
		G.featTestOpts = "perms=1;perms.budget=1000000;plans=1"
		G.featOpts = G.featTestOpts
		wait(on, 60 * 40, function(ok)
			say("options in the game: " .. tostring((G.featSt or {}).optsText) .. (ok and "" or " (NOT applied within 40 s)"))
			if not ok then return autoFinish() end
			local peer = nil
			for name in pairs(G.peers) do if not peer or name < peer then peer = name end end
			if not peer then say("no other player"); return autoFinish() end
			local key = peer:gsub("#.*$", ""):lower()
			pcall(G.featRequest, { m = "perms", kind = "right", payload = key .. "\tv" })
			pcall(G.featRequest, { m = "perms", kind = "right", payload = key .. "\ts" })
			pcall(G.featRequest, { m = "perms", kind = "note", payload = "permstest\tA note of the autotest" })
			wait(function() local s = perms(); local e = s and type(s.p) == "table" and s.p[key]; return type(e) == "table" and e.r == "bdlm" end, 60 * 20, function(ok2)
				local s = perms()
				local e = s and type(s.p) == "table" and s.p[key] or nil
				say(key .. "'s rights here: " .. tostring(e and e.r) .. (ok2 and " (bdlm expected)" or " (NOT bdlm)") .. ", plans "
					.. tostring(s and type(s.plans) == "table" and #s.plans or 0) .. " (1 expected)")
				autoFinish()
			end)
		end)
		return
	end
	local me = tostring(G.me):gsub("#.*$", ""):lower()
	wait(function() local s = perms(); local e = s and type(s.p) == "table" and s.p[me]; return on() and type(e) == "table" and e.r == "bdlm" end, 60 * 40, function(ok)
		if not ok then say("the host's rule did not come within 40 s (options " .. tostring((G.featSt or {}).optsText) .. ")"); return autoFinish() end
		say("this player's rights: bdlm (vehicles and speed taken)")
		local n0 = G.featRefused or 0
		-- a purchase as the depot window sends it (a copy of a vehicle with a depot), and a pause
		local bought = false
		pcall(function()
			local mePl = api.engine.util.getPlayer()
			for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				if not bought and tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) then
					bought = true
					uiRequest("makeVehicleBuyCmd", { n = 3, [1] = mePl, [2] = tv.depot, [3] = C.marshal(tv.transportVehicleConfig) })
				end
			end
		end)
		C.appendFile(C.DIR .. BS .. "ui.log", C.line("speed_req", { speed = 0 }))
		local okS, store = pcall(G.featGuiVeto, "vehicleStore", "mission.buyVehicle", { modelId2quantity = {} })
		say("the vehicle store's buy button: " .. tostring(okS and store or "error " .. tostring(store)))
		pcall(G.featRequest, { m = "perms", kind = "ask", payload = "500000\tpermstest" })
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			say("refused here: " .. ((G.featRefused or 0) - n0) .. " (" .. (bought and 2 or 1) .. " expected: " .. (bought and "the purchase and " or "") .. "the pause)")
			local s = perms()
			local asked = false
			for _, a in ipairs(s and type(s.asks) == "table" and s.asks or {}) do if a.key == me then asked = true end end
			say("the request for approval " .. (asked and "is in the game" or "is NOT in the game"))
			autoFinish()
		end }
	end)
end

local function guiUpdate(userParams, state, guiState)
	if not C.ACTIVE then return end
	G.frames = G.frames + 1
	G.stateObj = state
	if G.frames % 15 == 0 then pcall(G.previewTick); pcall(G.pingTick) end
	if G.frames % 30 == 7 then pcall(G.nameTick) end
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
	-- the native module holds the tools' builds while this script runs, and hears from it here from its first frame on
	-- (bridge_alive.txt, a counter rewritten every 2 s). A game loaded with MPFever disabled while a lobby was open has no such
	-- script: the module stops holding after a minute of silence instead of keeping every build forever.
	if os.getenv("MPFEVER_NOHEARTBEAT") ~= "1" and os.clock() - (G.aliveAt or -10) >= 2 then
		G.aliveAt = os.clock(); G.aliveN = (G.aliveN or 0) + 1
		local hb = C.IO.open(C.DIR .. BS .. "bridge_alive.txt", "wb")
		if hb then hb:write(tostring(G.aliveN)); hb:close() end
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
		if okT and tNow ~= G.clockSeen then G.clockSeen = tNow; G.clockMovedAt = G.frames; G.clockMovedClock = os.clock() end
	end
	-- the counters of the game time component (MPFEVER_FASTSTILL decides with them; MPFEVER_STEPLOG times both rules)
	if (G.fastStill or G.stillLog) and not G.stillFailed then
		local okS, errS = pcall(G.stillWatch)
		if not okS and not G.stillFailed then G.stillFailed = true; G.stillS = nil; log("stillness watch failed: " .. tostring(errS)) end
	end
	local okh, st = pcall(function() return state:get() end)
	if not (okh and type(st) == "table") then st = {} end
	G.simTerrainSig = st.terrainSig
	G.simBuildIds = st.buildIds
	G.co = st.co
	local okco, errco = pcall(coGui, st)
	if not okco then log("companies (gui): " .. tostring(errco)) end
	-- (0.6) the game options: the host's options into the game (f_opts), the modules' gui (mpfever_feat.lua); nothing while no option
	-- is on or asked. MPFEVER_FEAT=0: never
	if K.FEAT then
		local okf, errf = pcall(G.featGui, st)
		if not okf and G.frames - (G.featErrAt or -10000) > 600 then G.featErrAt = G.frames; log("options (gui): " .. tostring(errf)) end
	end
	-- the computer companies (the host's game only: the host chose them in its lobby; MPFEVER_AI=1 / MPFEVER_AIDEV for the tests)
	if C.ROLE == "host" and ((G.coAi and G.coAi ~= "") or os.getenv("MPFEVER_AI") or os.getenv("MPFEVER_AIDEV")) then pcall(G.aiStep, st) end
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
		-- (the simulation forgets the proposals of the captures sent, and those of the savegame's: see out_shipped)
		if G.outSent > (G.outTold or 0) and os.getenv("MPFEVER_KEEPOUT") ~= "1" then
			for _, o in ipairs(st.out or {}) do
				if o.n <= G.outSent and o.args then toSim("out_shipped", { n = G.outSent }); break end
			end
			G.outTold = G.outSent
		end
		if G.buildLead then
			-- (BUILDLEAD: a capture of this game still waits to be shipped, see G.leadRefusedCheck)
			G.outPending = false
			for _, o in ipairs(st.out or {}) do if (o.n or 0) > G.outSent then G.outPending = true end end
		end
	elseif G.solo then
		-- (no lobby, see H.solo: the captures made before the launcher said so are forgotten as if sent)
		for _, o in ipairs(st.out or {}) do if o.n > G.outSent then G.outSent = o.n end end
		if G.outSent > (G.outTold or 0) then
			for _, o in ipairs(st.out or {}) do
				if o.n <= G.outSent and o.args then toSim("out_shipped", { n = G.outSent }); break end
			end
			G.outTold = G.outSent
		end
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

	-- (no session: no stop point, see G.nstop)
	if not G.connected then pcall(G.nstopWrite, nil) end
	if G.connected then
		if G.buildLead then G.updateLeadCap() end
		local okp, sp = pcall(pacing)
		if okp then
			if gameSpeed() ~= sp then G.lastSet = -1 end
			setSpeed(sp)
			pcall(G.smoothPace, sp)
			pcall(G.nstopWrite, G.lastStopAt)
			-- exact steps up to the stop point (once the engine is stopped, one request at a time)
			local now = gameTime()
			-- (the engine may take seconds for many steps, in batches: a request is given up only when the clock stopped moving,
			-- else a second one would add its steps to what is left of the first and pass the stop point)
			-- (a request is given up while the clock stands still only once the engine is proven idle SINCE it: two handshakes after
			-- it with the same updateCount, see G.stillWatch; without such a proof, after 30 s. The interface sees no handshake while
			-- the simulation is busy: friends' sessions of 2026-10-25 asked for the same 3 steps 3 and 5 times while the engine stood
			-- in a 10 s step, ran 11 and 15 steps, and the builds held there landed 4 to 8 steps late: reloads)
			if G.stepTarget and now < G.stepTarget and G.frames - G.stepSince > 120 and G.frames - (G.clockMovedAt or 0) > 120 then
				local S = G.stillS
				-- (MPFEVER_OLDSTEPGIVEUP=1, tests: given up after the 120 frames, as before 0.5.6)
				local idle = os.getenv("MPFEVER_OLDSTEPGIVEUP") == "1" or (S and S.usable and S.proven and (S.provenAt or -1) > G.stepSince)
				if idle or os.clock() - (G.stepSinceClock or 0) > 30 then
					log("STEPS to " .. G.stepTarget .. " given up at t=" .. now .. " (" .. (idle and "the engine is idle since the request" or "30 s without the engine's answer") .. ") [frame " .. G.frames .. "]")
					G.stepTarget = nil
				end
			end
			if G.stepTarget and now >= G.stepTarget then G.stepTarget = nil end
			if sp == 0 and G.wantSteps and G.wantSteps > 0 and not G.stepTarget and G.simStill() then
				G.stepTarget, G.stepSince, G.stepSinceClock = now + G.wantSteps * STEP, G.frames, os.clock()
				-- (also while another game's build is awaited here: see "REPLAY SEND")
				if os.getenv("MPFEVER_STEPLOG") or #(G.nativeQueue or {}) > 0 or #(G.natWait or {}) > 0 then log("STEPS " .. G.wantSteps .. " from t=" .. now .. " to " .. G.stepTarget .. " (hold " .. tostring(G.holdAt) .. ", barrier " .. tostring(G.lastBarrier) .. ", pause " .. tostring(G.session.pauseAt) .. ") [frame " .. G.frames .. "]"
					.. (G.stillS and (" [still: old rule " .. (G.stillOldRule() and "yes" or "no") .. ", new rule " .. ((G.stillS.usable and G.stillS.proven) and "yes" or (G.stillS.usable and "no" or "n/a")) .. ", " .. ((G.fastStill and G.stillS.usable) and "the earlier of the two decides" or "the old rule decides") .. "]") or "")) end
				O.sendCommand(O.steps(G.wantSteps))
				-- (tests, MPFEVER_TESTSTALL=<seconds>: the simulation stands that long inside these steps, as the friends' engine did for
				-- 10 to 13 s, while another game's build is awaited; at most 3 times)
				local stall = tonumber(os.getenv("MPFEVER_TESTSTALL") or "")
				if stall and stall > 0 and (#(G.nativeQueue or {}) > 0 or #(G.natWait or {}) > 0) and (G.testStalls or 0) < 3 then
					G.testStalls = (G.testStalls or 0) + 1
					log("TESTSTALL " .. G.testStalls .. ": the simulation stands " .. stall .. " s inside the steps to " .. G.stepTarget)
					toSim("teststall", { s = stall })
				end
			end
		end
		-- stamp distance = barrier window + overshoot reserve + 1. The engine runs the simulation on its own thread,
		-- driven by real time: a game passes a stop point by what it simulates before its interface reacts (a frame,
		-- or a hiccup of a few hundred milliseconds). The reserve covers about half a second of simulation.
		local spd = math.max(1, math.min(4, G.session.speed or 1))
		G.window = spd + 2
		if G.lastSpd ~= spd then G.lastSpd = spd; G.consumed = {} end
		-- (MPFEVER_SHORTSTAMP=1, tests: with every game keeping its stop points natively and exactly at the barrier, one step of room
		-- instead of the overshoot reserve. Off: the barrier keeps its reserve, see pacing)
		local reserve = 2 * spd + 1
		if G.nstopOk() and os.getenv("MPFEVER_SHORTSTAMP") == "1" then
			local all = true
			for _, pc in pairs(G.peers) do if not pc.ns then all = false end end
			if all then reserve = 1 end
		end
		G.ahead = adaptAhead(G.window + reserve + 1)
		-- (another player leads with a terrain tool: it may be that much further ahead of this game)
		if otherLeads() then G.ahead = G.ahead + terrainLeadSteps() end
		local okt, t = pcall(gameTime)
		local tl = leadLevel()
		if tl == 0 then tl = nil end
		-- BUILDLEAD: this game takes part (1), and follows another game's lead (2): the leader releases its builds at once only
		-- when every other game says 2 (nothing is sent without the switch)
		local bl = nil
		if G.buildLead then bl = otherLeads() and 2 or 1 end
		local ns = G.nstopOk() and 1 or nil
		if okt and (t ~= G.lastClock or G.frames % 30 == 0 or tl ~= G.lastTl or bl ~= G.lastBl or ns ~= G.lastNs) then
			G.lastClock = t
			G.lastTl = tl
			G.lastBl = bl
			G.lastNs = ns
			G.stampFloor = math.max(G.stampFloor, t + G.ahead * STEP)
			send("clock", { t = t, sp = gameSpeed(), ah = G.ahead, tl = tl, bl = bl, ns = ns })
		end
	end

	-- bindings, results and hashes produced by the simulation half
	for key, e in pairs(st.bind or {}) do
		if G.bind[key] ~= e then
			G.rebind(key, e)
			C.appendFile(C.DIR .. BS .. "bindings.log", key .. " " .. tostring(e) .. NL)
		end
	end
	if type(st.hash) == "table" and st.hash.n ~= G.hashSent then
		G.hashSent = st.hash.n
		send("sync_hash", { n = st.hash.n, parts = st.hash.parts, cost = st.hash.cost, auth = st.hash.auth })
		-- (the host's names for the games of the other languages, see R.nameChanges)
		if type(st.hash.names) == "table" and C.ROLE == "host" then send("namesync", { n = st.hash.n, list = st.hash.names }) end
	end
	for _, r in ipairs(st.results or {}) do
		local key = tostring(r.uid) .. "@" .. tostring(r.at)
		if not G.resultsSeen[key] then
			G.resultsSeen[key] = true
			C.appendFile(C.DIR .. BS .. "results.log", C.line("result", r))
			G.reportResult(r)
		end
	end
	-- replays of this game whose town statistics differ from their builders' (see SIM.townStats)
	if st.townDiffs and G.tsWait then pcall(G.townDiffs, st) end

	if #G.waits > 0 then
		local current = G.waits
		G.waits = setmetatable({}, WAITS_MT)
		for _, w in ipairs(current) do
			if G.frames >= w.at then
				local prevRf = G.refund
				G.refund = w.refund
				local ok, err = pcall(withActor, w.actor, w.fn)
				G.refund = prevRf
				if not ok then log("deferred action failed: " .. tostring(err)) end
			else
				G.waits[#G.waits + 1] = w
			end
		end
	end
end

local function guiHandleEvent(userParams, state, guiState, src, id, name, param)
	if not C.ACTIVE then return end
	-- (a map signal armed in the MPFever window: the next click on the map places it, see G.pingArm)
	if G.pingArmed and id == "mainView" and (name == "select-world" or name == "select") then pcall(G.pingClick, name, param) end
	-- (what this player's tool shows, for the others' games: see G.previewOut)
	if name == "builder.proposalCreate" then pcall(G.previewOut, tostring(id), param)
	elseif name == "builder.proposalApply" then
		pcall(G.previewGone); pcall(G.toolApplied, param)
		-- (0.6: the build the tool applies, for a game option that checks this player's builds, see G.featRefuse)
		if G.featOn and G.featAllow then pcall(G.featTool, param) end
	end
	if type(name) == "string" and name:find("^builder%.") then
		G.evSeen = G.evSeen or {}
		local key = tostring(id) .. "/" .. name
		if not G.evSeen[key] then G.evSeen[key] = true; log("tool event: " .. key) end
		-- BUILDLEAD: a construction tool is in hand (it sends these while the player aims, as well as when it builds)
		if G.buildLead then G.buildToolSeen(tostring(id)) end
	end
	-- (0.6) the game options' answer to this event (M.guiVeto of every module on, see F.guiVeto: a tool turned down before the
	-- click, a station, stop or depot in another company's territory, the vehicle store's buy button off, a line kept), returned
	-- as the game's own scripts return theirs. Only while a module on answers (G.featVeto); nothing while no option is on: no
	-- answer, as before. MPFEVER_FEATVETO=0 (K.FEATVETO false) or MPFEVER_FEAT=0: never
	if K.FEATVETO ~= false and G.featVeto and G.featOn then
		local okv, r = pcall(G.featGuiVeto, id, name, param)
		if okv and r ~= nil then return r end
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
