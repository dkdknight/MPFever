-- MPFever companies' economy (0.5.0), in the "one company per player" mode: several players in a company (mixed modes),
-- joining, leaving and merging companies, bankruptcy with an auction of the bankrupt company's assets, and the owners' rules
-- for their tracks, stations and stops, and depots (private, open, open with a toll).
--
-- Everything here runs in the simulation half of the bridge, on every game at the same game time, from the state saved with
-- the game (the companies registry st.co, see mpfever_co.lua) and the stamped events of the players (handleEvent "mpfever"):
--
--   co_rules        {bankrupt}           the host's rules: months in debt before a bankruptcy (0: never)
--   co_join_ask     {to}                 a player asks to join company `to`
--   co_join_answer  {key, accept}        the chief of the company asked answers
--   co_leave        {}                   a player leaves its company (it gets a new one: see the bridge's coGui)
--   co_cancel       {}                   a player takes its requests back
--   co_merge_ask    {to}                 a chief offers to merge its company into company `to`
--   co_merge_answer {from, accept}       the chief of `to` answers: everything of `from` becomes its company's
--   co_bid          {seq, lot, amount}   a bid at the auction of a bankrupt company
--   co_lot_close    {seq, lot}           the host closes the lot under the hammer (a minute after it opened, see coGui)
--   co_month        {month, debt}        the host's look at a new month: the companies in debt (their money below zero on the
--                                        host's game, which every game's money follows: a game's own balance may lag a step)
--   co_track_rule   {rule, toll}         a company's rule for its tracks: "private", "open", "toll"
--   co_road_rule    {rule}               a company's rule for its roads (0.6.2): "private", "open"
--   co_depot_rule   {key, rule, toll}    a company's rule for one of its depots (its own setting; "co": its company's rule)
--   co_depot_default {rule, toll}        a company's rule for its depots, the depots without a setting of their own (0.5.2)
--   co_stop_rule    {rule, fee, reset}   a company's rule for its stations and stops (0.5.2); reset: its stations' own settings
--                                        go, every one of them follows the company's rule
--
-- The rules (0.5.2): tracks, stations and stops, depots are open to the other companies when their company set nothing (free:
-- before, tracks and depots were private and a station without a setting was shared for $100 per stop). A station's or a
-- depot's own setting (its window, the 'share' event of the bridge for a station) comes before its company's rule. Any member
-- of a company may change its rules. What a savegame already holds is kept: a station's fee of 0.5.1 (reg.shares) is its own
-- setting, 0 = private. MPFEVER_OPENDEFAULT=0: as before (tracks and depots private, a station shared for $100 when nothing
-- is set).
--
-- param.mpfCo is the sender's company and param.mpfFrom the sender (its name, "#n" for a player who joined), both added by the
-- bridge when the event is applied. What happens in the game's world (owners, money, demolitions) goes through commands sent from
-- here: every game sends the same at the same step. env = { log, CO, R, STEP }.

local E = {}

E.EVENTS = {
	co_rules = true, co_join_ask = true, co_join_answer = true, co_leave = true, co_cancel = true, co_merge_ask = true,
	co_merge_answer = true, co_bid = true, co_lot_close = true, co_track_rule = true, co_depot_rule = true, co_test = true, co_month = true,
	co_stop_rule = true, co_depot_default = true, co_road_rule = true, co_auction_close = true,
	-- (0.8.3) loans between companies, see E.loanEvent
	co_loan_ask = true, co_loan_counter = true, co_loan_answer = true, co_loan_cancel = true,
}
-- (0.7.4) the smallest bid a lot takes: its reserve, or the best bid and 5 %
function E.minBid(lot)
	return math.max(lot.reserve or 0, lot.best and math.ceil(lot.best * (1 + E.MIN_RAISE)) or 0)
end
E.BANKRUPT_DEFAULT = 12        -- months in debt
E.BANKRUPT_CHOICES = { 0, 3, 6, 12, 24 }
-- (0.8.3, Zoey's suggestion, the owner's rules of 2026-11-12) Loans between companies. The BORROWER asks: how much, over how many
-- months, and the interest it offers (in % of the amount, for the whole loan); the lender's chief accepts, refuses or makes a
-- counter-offer, and so on in turn. Accepted: the lender pays the amount at once (refused when it has not got it), then the
-- borrower pays back the amount and the interest in equal parts, one at each new month of the game (co_month, the same step on
-- every game; a borrower without the money goes into debt, the bankruptcy rule then counts). A borrower gone bankrupt: the lender
-- loses what is left; a lender gone: the borrower keeps it. Chiefs only. MPFEVER_LOANS=0: no loan asked nor paid back
E.LOAN_MONTHS_MAX = 120
E.LOAN_RATE_MAX = 100
E.LOAN_AMOUNT_MAX = 1e10
E.LOANS = os.getenv("MPFEVER_LOANS") ~= "0"
E.LOT_SECONDS = tonumber(os.getenv("MPFEVER_LOTSECONDS") or "") or 60   -- a lot stays open that long (seconds of the game's time since 0.8.3, see the bridge's G.auClock)
E.LAST_BID_SECONDS = math.min(15, E.LOT_SECONDS)                         -- and that long after its last bid
E.MIN_RAISE = 0.05             -- a bid beats the best one by 5 % at least
E.TOLL_DEFAULT = 1000
-- (a station's toll per stop when its company chooses one without an amount: the smallest of the station window, as
-- C.SHARE_DEFAULT in mpfever_common.lua)
E.STOP_FEE_DEFAULT = 100
-- what nothing set means (see the header): read once, every game is started with the same value (MPFEVER_OPENDEFAULT=0: as
-- before)
E.OPEN_DEFAULT = os.getenv("MPFEVER_OPENDEFAULT") ~= "0"
-- A station its company makes private while the lines of other companies already stop there: the engine keeps their stops (the
-- owner's choice cannot take them out of another company's lines), and the line check only refuses new ones. Those lines pay
-- E.STOP_FEE_DEFAULT per stop there until their company takes the stop out (before, they stopped there for free, a way around
-- every fee). MPFEVER_PRIVATEFEE=0: as before.
E.PRIVATE_FEE = os.getenv("MPFEVER_PRIVATEFEE") ~= "0"
-- A track segment, for the tolls (E.tolls): a segment (BASE_EDGE) without a street component. TF3 has no BASE_EDGE_TRACK component
-- type: reading it failed for every segment, so no train ever paid a toll. Read once, every game is started with the same value
-- (MPFEVER_TRACKTYPE=0: as before)
E.TRACK_STREET = os.getenv("MPFEVER_TRACKTYPE") ~= "0"
E.RESERVE = { line = 50000, vehicle = 50000, station = 100000, depot = 50000 }
-- (0.7.4) The auction of a bankrupt company, as the host chooses it (reg.rules.auction, "mode:minutes"; the lobby, the Rules tab):
--   assets   every lot (each line with its vehicles, each station, each depot) for sale at once, one clock for all of them
--            (0.7.3: one lot after the other, a minute each: an advanced company's twenty lines took twenty minutes, and the
--            window showed one at a time);
--   company  one lot, the whole company: its lines, vehicles, stations, depots, tracks and roads; its reserve the sum of theirs;
--   serial   the auction of 0.7.3, one lot after the other (an auction of a savegame of 0.7.3 under way goes on that way).
-- The clock: E.AUCTION_MINUTES (5 by default), a bid in its last E.SNIPE_SECONDS gives every lot that much more. What nobody
-- bought is demolished (a line, a depot, a station no other company's line stops at); a station another company's lines still
-- stop at, the tracks and roads and whatever the company still owns go to an heir instead of breaking the others' lines: a
-- computer company if there is one (it may sell them), else a company that took part in the auction, else any company, chosen
-- by the auction's number (the same on every game).
E.AUCTION_MODES = { assets = true, company = true, serial = true }
E.AUCTION_MINUTES = { 3, 5, 10 }
E.AUCTION_DEFAULT = "assets:5"
E.SNIPE_SECONDS = 30
-- the host's choice, read from the registry: mode and minutes
function E.auctionRule(reg)
	local v = tostring(((reg or {}).rules or {}).auction or E.AUCTION_DEFAULT)
	local mode, mins = v:match("^(%a+):(%d+)$")
	mins = tonumber(mins)
	local okM = false
	for _, m in ipairs(E.AUCTION_MINUTES) do if m == mins then okM = true end end
	if not (mode and E.AUCTION_MODES[mode]) then mode = "assets" end
	if not okM then mins = 5 end
	return mode, mins
end
-- (0.6) A computer company never goes bankrupt, whatever its level (the owner's rule of 2026-10-30): its months in debt are not
-- counted, so no bankruptcy and no "in debt" notice for it; it keeps itself solvent instead (mpfever_ai.lua: its reserve, its
-- floor, its sales and its loan). Read once, every game is started with the same value (MPFEVER_AINOBANKRUPT=0: as before, a
-- computer company goes bankrupt as a player's does)
E.AI_NO_BANKRUPT = os.getenv("MPFEVER_AINOBANKRUPT") ~= "0"

-- (the game time and the bridge's helpers, given by the bridge at every call: see E.event and E.tick)
E.env = nil
local function gt() return E.env.gameTime() end

local function keyOf(origin)
	local plain = tostring(origin or ""):gsub("#.*$", "")
	return plain:lower(), plain
end

-- a host (or a dedicated server) sends its events under its plain name; a player who joined has "#n" after it
local function fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

local function balanceOf(ent)
	local ok, b = pcall(api.engine.util.finance.getPlayersBalance, ent)
	return (ok and type(b) == "number") and b or nil
end

local function book(ent, amount, fill)
	if not ent or amount == 0 then return end
	local e = api.type.JournalEntry.new()
	e.amount = math.floor(amount + 0.5)
	e.time = -1
	local ok = pcall(fill or function(x) x.category.type = api.type.JournalEntry.Type.OTHER end, e)
	if not ok then e.category.type = api.type.JournalEntry.Type.OTHER end
	api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(ent, e, api.type.Vec3f.new(0, 0, 0)))
end

-- what happened, for the players (the host's game tells it in the chat, see the bridge's coGui): reg.news, the last 30
local function news(reg, t)
	reg.newsSeq = (reg.newsSeq or 0) + 1
	t.n = reg.newsSeq
	t.at = gt()
	reg.news = reg.news or {}
	reg.news[#reg.news + 1] = t
	while #reg.news > 30 do table.remove(reg.news, 1) end
end

local function live(c) return c and not c.gone end

-- (0.6) a computer company: its key, or one of its members' keys, is "ai:<n>" (the host's module joins it under that key, see
-- mpfever_ai.lua; a name taken twice gets "@..." after it). Read from the registry, the same on every game
function E.isAi(c)
	if type(c) ~= "table" then return false end
	if tostring(c.key or ""):sub(1, 3) == "ai:" then return true end
	for _, m in ipairs(type(c.members) == "table" and c.members or {}) do
		if tostring(m.key or ""):sub(1, 3) == "ai:" then return true end
	end
	return false
end

-- (the registry's company by its number, without env: the rules are also read by the interface's half of the bridge)
local function findCo(reg, id)
	for _, c in ipairs(reg and reg.list or {}) do if c.id == id then return c end end
	return nil
end

-- ---------------------------------------------------------------- what a company owns
-- every entity a player entity owns (PlayerOwned), sorted (the same set on every game; the ids may differ)
function E.ownedBy(env, ent)
	local out, seen = {}, {}
	local function add(e) if type(e) == "number" and e >= 0 and not seen[e] then seen[e] = true; out[#out + 1] = e end end
	local ok = pcall(function()
		api.engine.forEachEntityWithComponent(function(e)
			local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
			if po and po.player == ent then add(e) end
		end, api.type.ComponentType.PLAYER_OWNED)
	end)
	if not ok or #out == 0 then
		-- (the engine refused the loop: what the checks count, piece by piece)
		local function owned(e)
			local okc, po = pcall(api.engine.getComponent, e, api.type.ComponentType.PLAYER_OWNED)
			return okc and po and po.player == ent
		end
		for _, e in ipairs(env.R.allEdges()) do if owned(e) then add(e) end end
		for _, e in ipairs(env.R.entitiesWith("CONSTRUCTION")) do if owned(e) then add(e) end end
		pcall(function() for _, v in ipairs(api.engine.system.transportVehicleSystem.getVehiclesForPlayer(ent)) do add(v) end end)
	end
	pcall(function() for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(ent)) do add(l) end end)
	table.sort(out)
	return out
end

function E.hasAssets(env, c)
	if not (c and c.ent) then return false end
	local n = 0
	pcall(function() n = n + #api.engine.system.lineSystem.getLinesForPlayer(c.ent) end)
	pcall(function() n = n + #api.engine.system.transportVehicleSystem.getVehiclesForPlayer(c.ent) end)
	if n > 0 then return true end
	return #E.ownedBy(env, c.ent) > 0
end

-- the entities of `list` that `from` owns become `to`'s (the others are left alone: an entity without an owner has none)
-- (0.7.4: E.handing, while an auction closes: the entities already handed over, sold or demolished in this step. The commands
-- are applied after this step, so the owners read here are still the bankrupt company's: without it the line just sold went to
-- the heir with the rest, two owner changes of one entity in one step, au1 2026-11-07)
-- (0.7.4) A line's stops given every cargo type's load and maxLoad, as the game's line window makes a stop (gui line_util.makeNewStop).
-- The computer companies' freight lines had an unloading stop with empty lists; the engine computes a line again when its owner
-- changes and reads, at each stop, the maxLoad of every cargo the line loads: past the end of the empty list, a crash on every game
-- (au1 to au6 of 2026-11-07, the line sold at an auction; reproduced with the owner change alone). A stop that listed nothing
-- loads nothing, or the passengers on a line that loads nothing at all (a bus line). Sends the line's update (before the owner
-- change, in the same step); returns whether it did. MPFEVER_LINEFIX=0: as before
function E.fullLineStops(l)
	if os.getenv("MPFEVER_LINEFIX") == "0" then return false end
	local n = 0
	pcall(function() for id in pairs(api.res.cargoTypeRep.getAll(true)) do if id + 1 > n then n = id + 1 end end end)
	if n <= 0 then return false, "the cargo types could not be read" end
	local ok, sent = pcall(function()
		local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
		if not lc then return false end
		local lineData = api.type.Line.new(lc)
		local stops, short, any = {}, false, false
		for _, s in ipairs(lineData.stops) do
			stops[#stops + 1] = s
			local nl, nm = 0, 0
			for _, v in ipairs(s.stopConfig.load) do nl = nl + 1; if v then any = true end end
			for _ in ipairs(s.stopConfig.maxLoad) do nm = nm + 1 end
			if nl < n or nm < n then short = true end
		end
		if not short then return "full" end
		local pid = nil
		if not any then pcall(function() pid = api.res.cargoTypeRep.getPassengerCargoTypeId() end) end
		for _, s in ipairs(stops) do
			local old = s.stopConfig
			local oldL, oldM = {}, {}
			for k, v in ipairs(old.load) do oldL[k] = v end
			for k, v in ipairs(old.maxLoad) do oldM[k] = v end
			if #oldL < n or #oldM < n then
				local cfg = api.type.Line.StopConfig.new()
				local load, maxLoad = {}, {}
				for k = 1, n do
					if oldL[k] ~= nil then load[k] = oldL[k] == true else load[k] = (#oldL == 0 and type(pid) == "number" and k == pid + 1) end
					maxLoad[k] = tonumber(oldM[k]) or 1
				end
				cfg.load, cfg.maxLoad = load, maxLoad
				cfg.forceUnload = old.forceUnload
				cfg.destroyForConfigChange = old.destroyForConfigChange
				cfg.destroyForRefresh = old.destroyForRefresh
				s.stopConfig = cfg
			end
		end
		lineData.stops = stops
		api.cmd.sendCommand(api.cmd.makeLineUpdateCmd(l, lineData))
		return true
	end)
	if not ok then return false, tostring(sent) end
	if sent == "full" then return false, "full" end
	return sent == true, sent == true and "filled" or tostring(sent)
end

local function setOwner(list, from, to)
	local n = 0
	for _, e in ipairs(list) do
		local okc, po = pcall(api.engine.getComponent, e, api.type.ComponentType.PLAYER_OWNED)
		if okc and po and po.player == from and not (E.handing and E.handing[e]) then
			-- (0.7.4: a line's stops filled first, see E.fullLineStops)
			local okL, lc = pcall(api.engine.getComponent, e, api.type.ComponentType.LINE)
			if okL and lc then
				local filled, why = E.fullLineStops(e)
				if E.env and why ~= "full" then E.env.log("companies: line " .. e .. " changes hands: its stops' cargo lists " .. (filled and "filled first" or ("not filled (" .. tostring(why) .. ")"))) end
			end
			local ok = pcall(function() api.cmd.sendCommand(api.cmd.makeEntitySetPlayerCmd(e, to)) end)
			if ok then n = n + 1 end
			if E.handing then E.handing[e] = true end
		end
	end
	return n
end

local function nameOf(e)
	local ok, n = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.NAME).name end)
	return (ok and type(n) == "string") and n or tostring(e)
end

-- ---------------------------------------------------------------- the lots of a bankrupt company
-- Lots: each line with its vehicles, each station, each depot with the vehicles in it. Known by keys that are the same on every
-- game (the line's name and stops, the station's key, the depot's construction and place), sorted by them.
local function lineKey(env, line)
	local parts = {}
	pcall(function()
		local lc = api.engine.getComponent(line, api.type.ComponentType.LINE)
		for i = 1, #lc.stops do parts[#parts + 1] = env.R.sgKey(lc.stops[i].stationGroup) end
	end)
	return "L:" .. nameOf(line) .. "|" .. table.concat(parts, ";")
end

local function depotKey(con)
	local ok, k = pcall(function()
		local c = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
		local t = c.transf
		return "D:" .. tostring(c.fileName) .. "@" .. string.format("%.0f,%.0f", t[13], t[14])
	end)
	return ok and k or ("D:" .. tostring(con))
end
E.depotKey = depotKey

-- the construction of a depot entity (or the depot's construction itself)
function E.depotCon(depot)
	local ok, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForDepot, depot)
	if ok and type(con) == "number" and con >= 0 then return con end
	return depot
end

local function stationEntities(env, sg)
	local out = { sg }
	pcall(function()
		local g = api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP)
		for i = 1, #g.stations do
			local st = g.stations[i]
			out[#out + 1] = st
			local okc, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForStation, st)
			if okc and type(con) == "number" and con >= 0 then out[#out + 1] = con end
		end
	end)
	return out
end

local function depotsOf(env, ent)
	local out = {}
	for _, e in ipairs(env.R.withoutAssets(env.R.entitiesWith("CONSTRUCTION"))) do
		local ok, isMine = pcall(function()
			local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
			if not (c and c.depots and #c.depots > 0) then return false end
			local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
			return po and po.player == ent
		end)
		if ok and isMine then out[#out + 1] = e end
	end
	return out
end

local function stationsOf(env, ent)
	local out = {}
	for _, sg in ipairs(env.R.entitiesWith("STATION_GROUP")) do
		if env.R.ownerOf(sg) == ent then out[#out + 1] = sg end
	end
	return out
end

-- (0.7.5) The town of a station the game never named (a computer company's truck stops): its lot reads « Unnamed station in
-- <town> (lot N) » instead of its number only. The engine's station -> town, the same on every game; always kept here (the
-- interface's MPFEVER_LOTTOWN=0 only hides it: never a switch in the simulation, each PC has its own)
function E.townOfStation(sg)
	local town
	pcall(function()
		local g = api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP)
		for _, st in ipairs(g and g.stations or {}) do
			local t = api.engine.system.stationSystem.getTown(st)
			if t and t > 0 then
				local n = api.engine.getComponent(t, api.type.ComponentType.NAME)
				if n and type(n.name) == "string" and n.name ~= "" then town = n.name break end
			end
		end
	end)
	return town
end

function E.lotsOf(env, c)
	local lines, stations, depots = {}, {}, {}
	pcall(function()
		for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(c.ent)) do
			local nv = 0
			pcall(function() nv = #api.engine.system.transportVehicleSystem.getLineVehicles(l) end)
			lines[#lines + 1] = { kind = "line", key = lineKey(env, l), label = nameOf(l), vehicles = nv,
				reserve = math.max(E.RESERVE.line, nv * E.RESERVE.vehicle) }
		end
	end)
	for _, sg in ipairs(stationsOf(env, c.ent)) do
		local lot = { kind = "station", key = env.R.sgKey(sg), label = nameOf(sg), reserve = E.RESERVE.station }
		if lot.label == "" then lot.town = E.townOfStation(sg) end
		stations[#stations + 1] = lot
	end
	for _, d in ipairs(depotsOf(env, c.ent)) do
		depots[#depots + 1] = { kind = "depot", key = depotKey(d), label = nameOf(d), reserve = E.RESERVE.depot }
	end
	local function byKey(a, b) return a.key < b.key end
	table.sort(lines, byKey)
	table.sort(stations, byKey)
	table.sort(depots, byKey)
	local lots = {}
	for _, t in ipairs({ lines, stations, depots }) do for _, l in ipairs(t) do lots[#lots + 1] = l end end
	return lots
end

-- (0.7.4) the whole company as one lot: what it holds, its reserve the sum of its assets' reserves (at least a line's)
function E.companyLot(env, c, lots, label)
	local reserve, n = 0, { line = 0, station = 0, depot = 0, vehicles = 0 }
	for _, l in ipairs(lots) do
		reserve = reserve + (l.reserve or 0)
		n[l.kind] = (n[l.kind] or 0) + 1
		n.vehicles = n.vehicles + (l.vehicles or 0)
	end
	return { kind = "company", key = "C:" .. tostring(c.id), label = label or ("#" .. tostring(c.id)), reserve = math.max(E.RESERVE.line, reserve),
		lines = n.line, stations = n.station, depots = n.depot, vehicles = n.vehicles }
end

-- the entities of a lot in this game, found again by its key
local function lotEntities(env, c, lot)
	local ents, vehicles, cons = {}, {}, {}
	if lot.kind == "line" then
		pcall(function()
			for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(c.ent)) do
				if lineKey(env, l) == lot.key then
					ents[#ents + 1] = l
					local seenV = {}
					for _, v in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(l)) do vehicles[#vehicles + 1] = v; seenV[v] = true end
					-- (0.7.4) and the company's vehicles sent to that line that are not on it yet (bought, still leaving their depot):
					-- the line changed hands without them, a vehicle of one company left on another one's line (au5, 2026-11-07; that
					-- game's crash itself came from the line's stops, see E.fullLineStops). MPFEVER_LINEVEH=0: the line's vehicles only
					if os.getenv("MPFEVER_LINEVEH") ~= "0" then
						pcall(function()
							for _, v in ipairs(api.engine.system.transportVehicleSystem.getVehiclesForPlayer(c.ent)) do
								if not seenV[v] then
									local okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
									if okT and tv and tv.line == l then vehicles[#vehicles + 1] = v; seenV[v] = true end
								end
							end
						end)
					end
					break
				end
			end
		end)
	elseif lot.kind == "station" then
		for _, sg in ipairs(stationsOf(env, c.ent)) do
			if env.R.sgKey(sg) == lot.key then
				for _, e in ipairs(stationEntities(env, sg)) do
					ents[#ents + 1] = e
					local okc, cc = pcall(api.engine.getComponent, e, api.type.ComponentType.CONSTRUCTION)
					if okc and cc then cons[#cons + 1] = e end
				end
				break
			end
		end
	elseif lot.kind == "depot" then
		for _, d in ipairs(depotsOf(env, c.ent)) do
			if depotKey(d) == lot.key then
				ents[#ents + 1] = d
				cons[#cons + 1] = d
				pcall(function()
					local cc = api.engine.getComponent(d, api.type.ComponentType.CONSTRUCTION)
					for i = 1, #cc.depots do
						ents[#ents + 1] = cc.depots[i]
						for _, v in ipairs(api.engine.system.transportVehicleSystem.getDepotVehicles(cc.depots[i])) do vehicles[#vehicles + 1] = v end
					end
				end)
				break
			end
		end
	end
	return ents, vehicles, cons
end

-- what nobody bought goes: the vehicles sold, the line removed, the station or depot demolished (a construction the engine
-- refuses to remove stays, with no player of its own: see E.openOwners)
local function demolish(env, c, lot)
	local ents, vehicles, cons = lotEntities(env, c, lot)
	if E.handing then for _, list in ipairs({ ents, vehicles, cons }) do for _, e in ipairs(list) do E.handing[e] = true end end end
	for _, v in ipairs(vehicles) do pcall(function() api.cmd.sendCommand(api.cmd.makeVehicleSellCmd({ v })) end) end
	if lot.kind == "line" then
		for _, l in ipairs(ents) do pcall(function() api.cmd.sendCommand(api.cmd.makeLineDestroyCmd(l)) end) end
	elseif #cons > 0 then
		pcall(function()
			local sp = api.type.SimpleProposal.new()
			sp.constructionsToRemove = cons
			local ctx = api.type.Context.new()
			ctx.player = c.ent
			ctx.checkTerrainAlignment = false
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, true, false))
		end)
	end
	env.log("companies: auction: lot '" .. tostring(lot.label) .. "' (" .. lot.kind .. ") of company " .. c.id .. " unsold: "
		.. #vehicles .. " vehicle(s) sold, " .. #cons .. " construction(s) demolished")
end

-- A station or a depot sold at the auction (or demolished) loses its own setting: a station the buyer gets follows the buyer's
-- rule, not the rule the bankrupt company chose for it (and a demolished one leaves no setting behind under its key).
-- MPFEVER_LOTRULES=0: as before (the setting stayed with the key).
local function dropLotRule(reg, lot)
	if os.getenv("MPFEVER_LOTRULES") == "0" or not lot then return end
	if lot.kind == "station" then
		if reg.stationRule then reg.stationRule[lot.key] = nil end
		if reg.shares then reg.shares[lot.key] = nil end
	elseif lot.kind == "depot" then
		if reg.depots then reg.depots[lot.key] = nil end
	end
end

-- (0.6) The own tracks and nodes of constructions (a station's platforms, a depot's tracks), added to `all` once each
local function frozenOf(cons, all, seen)
	for _, con in ipairs(cons) do
		pcall(function()
			local cc = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
			if not cc then return end
			for _, list in ipairs({ cc.frozenEdges, cc.frozenNodes }) do
				for i = 1, #(list or {}) do
					local e = list[i]
					if type(e) == "number" and not seen[e] then seen[e] = true; all[#all + 1] = e end
				end
			end
		end)
	end
end

-- (0.6) The assets of a lot (E.lotsOf: a line with its vehicles, a station, a depot with the vehicles in it), found again by its key
-- in company `from`'s, become company `to`'s; returns how many entities changed hands. The auction's sale (sell, below) goes
-- through it with no opts, exactly as before; the sales between companies (mpfever_feat_trade.lua, through the bridge's
-- SIM.featBridge) give opts:
--   withStations  a line goes with the stations of its stops that `from` owns (each one as a station lot of its own)
--   frozen        the own tracks and nodes of the stations' and depots' constructions change hands too (without them the buyer's
--                 trains would pay the seller's toll inside a station they bought)
--   reg           the registry: the own settings of the stations and depots that change hands go (as an auction's lot, see
--                 dropLotRule: they follow the buyer's rules), and the vehicles' stops are read afresh for the fees (reg.vstop)
-- Books nothing: the caller does.
function E.transferLot(env, from, to, lot, opts)
	opts = opts or {}
	local ents, vehicles, cons = lotEntities(env, from, lot)
	local all, seen = {}, {}
	for _, e in ipairs(ents) do all[#all + 1] = e; seen[e] = true end
	for _, v in ipairs(vehicles) do all[#all + 1] = v; seen[v] = true end
	local stations = {}
	if opts.withStations and lot.kind == "line" then
		-- (the line's stops, read at once: a component read is only valid until the next one)
		local sgs = {}
		for _, l in ipairs(ents) do
			pcall(function()
				local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
				for i = 1, #lc.stops do sgs[#sgs + 1] = lc.stops[i].stationGroup end
			end)
		end
		for _, sg in ipairs(sgs) do
			if not seen[sg] and env.R.ownerOf(sg) == from.ent then
				for _, e in ipairs(stationEntities(env, sg)) do
					if not seen[e] then
						seen[e] = true
						all[#all + 1] = e
						local okc, cc = pcall(api.engine.getComponent, e, api.type.ComponentType.CONSTRUCTION)
						if okc and cc then cons[#cons + 1] = e end
					end
				end
				stations[#stations + 1] = env.R.sgKey(sg)
			end
		end
	end
	-- (0.7.4, diagnostic: vehicles of another company than `from` sent to a line that changes hands, which the engine does not take)
	if lot.kind == "line" then
		pcall(function()
			local lineSet, odd = {}, {}
			for _, l in ipairs(ents) do lineSet[l] = true end
			api.engine.forEachEntityWithComponent(function(v)
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				if tv and lineSet[tv.line] and not seen[v] then
					local po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED)
					odd[#odd + 1] = tostring(v) .. "(owner " .. tostring(po and po.player) .. ")"
				end
			end, api.type.ComponentType.TRANSPORT_VEHICLE)
			if #odd > 0 then env.log("companies: lot '" .. tostring(lot.label) .. "': vehicles of other owners on the line: " .. table.concat(odd, ", ")) end
		end)
	end
	local nFrozen = #all
	if opts.frozen then frozenOf(cons, all, seen) end
	nFrozen = #all - nFrozen
	local n = setOwner(all, from.ent, to.ent)
	if opts.reg then
		dropLotRule(opts.reg, lot)
		for _, key in ipairs(stations) do dropLotRule(opts.reg, { kind = "station", key = key }) end
		opts.reg.vstop = nil
	end
	if opts.withStations or opts.frozen then
		env.log("companies: lot '" .. tostring(lot.label) .. "' (" .. tostring(lot.kind) .. ") of company " .. tostring(from.id) .. " to company "
			.. tostring(to.id) .. ": " .. #ents .. " entities, " .. #vehicles .. " vehicle(s), " .. #stations .. " station(s) of its stops, "
			.. nFrozen .. " own track(s) and node(s): " .. n .. " change hands")
	end
	return n, { stations = stations, vehicles = #vehicles, frozen = nFrozen }
end

local function sell(env, c, lot, winner, amount, reg)
	local n
	if lot.kind == "company" then
		-- (0.7.4: the whole company, everything it owns; its money and its debt are not part of it. The own settings of its
		-- stations and depots are the buyer's now, as in a merger)
		n = setOwner(E.ownedBy(env, c.ent), c.ent, winner.ent)
		if reg then
			for _, o in pairs(reg.stationRule or {}) do if type(o) == "table" and o.co == c.id then o.co = winner.id end end
			for _, d in pairs(reg.depots or {}) do if type(d) == "table" and d.co == c.id then d.co = winner.id end end
		end
	else
		-- (0.7.4: a station's or a depot's own tracks go with it, as in a sale between companies: the buyer's trains paid the
		-- bankrupt company's toll inside a station they bought. MPFEVER_LOTFROZEN=0: as before)
		n = E.transferLot(env, c, winner, lot, os.getenv("MPFEVER_LOTFROZEN") ~= "0" and { frozen = true } or nil)
	end
	book(winner.ent, -amount, function(x) x.category.type = api.type.JournalEntry.Type.ACQUISITION end)
	env.log("companies: auction: lot '" .. tostring(lot.label) .. "' (" .. lot.kind .. ") of company " .. c.id .. " sold to company "
		.. winner.id .. " for " .. amount .. " (" .. n .. " entities change hands)")
end
E.lotEntities = function(env, c, lot) return lotEntities(env, c, lot) end

-- (0.7.4) whether a line of another company than c stops at station group sg
local function usedByOthers(env, c, sg)
	local used = false
	pcall(function()
		for _, l in ipairs(env.R.entitiesWith("LINE")) do
			local po = api.engine.getComponent(l, api.type.ComponentType.PLAYER_OWNED)
			if not (po and po.player == c.ent) then
				local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
				for i = 1, #lc.stops do if lc.stops[i].stationGroup == sg then used = true; return end end
			end
		end
	end)
	return used
end

-- (0.7.4) the heir of what a bankrupt company keeps unsold: a computer company, else a company that bid at its auction, else any
-- company with players, sorted by number and picked by the auction's number (the same on every game); nil when there is none
function E.heirOf(reg, au, env)
	local function pick(list)
		if #list == 0 then return nil end
		table.sort(list, function(a, b) return a.id < b.id end)
		return list[(math.floor(tonumber(au.seq) or 1) % #list) + 1]
	end
	local ai, bidders, any = {}, {}, {}
	local bid = {}
	for _, l in ipairs(au.lots or {}) do if l.bidder then bid[l.bidder] = true end end
	for id in pairs(au.bidders or {}) do bid[tonumber(id) or -1] = true end
	for _, c in ipairs(reg.list or {}) do
		if live(c) and c.ent and c.id ~= au.co then
			if E.isAi(c) then ai[#ai + 1] = c end
			if bid[c.id] then bidders[#bidders + 1] = c end
			if #env.CO.members(c) > 0 then any[#any + 1] = c end
		end
	end
	return pick(ai) or pick(bidders) or pick(any)
end

-- (0.7.4) a lot nobody bought: demolished, but a station another company's lines stop at goes to the heir (demolished, it broke
-- their lines); returns whether it went to the heir
local function unsold(env, c, lot, heir)
	if lot.kind == "station" and heir and os.getenv("MPFEVER_UNSOLDHEIR") ~= "0" then
		local sgs = {}
		for _, sg in ipairs(stationsOf(env, c.ent)) do if env.R.sgKey(sg) == lot.key then sgs[#sgs + 1] = sg end end
		for _, sg in ipairs(sgs) do
			if usedByOthers(env, c, sg) then
				local n = E.transferLot(env, c, heir, lot, { frozen = true })
				env.log("companies: auction: station '" .. tostring(lot.label) .. "' of company " .. c.id .. " unsold, other companies' lines stop there: to company "
					.. heir.id .. " (" .. n .. " entities)")
				return true
			end
		end
	end
	demolish(env, c, lot)
	return false
end

-- (0.7.4) the end of an auction of every lot at once (or of the whole company): each lot sold to its best bidder, or unsold; then
-- what the company still owns (its tracks and roads, a station kept for the others' lines...) goes to the heir
function E.closeAll(st, env)
	local reg = st.co
	local au = reg.auction
	if not (au and au.v == 2) then return end
	local c = env.CO.find(reg, au.co)
	local heir = E.heirOf(reg, au, env)
	local sold, gone, kept = 0, 0, 0
	E.handing = {}
	local okC, errC = pcall(function()
	if c and c.ent then
		for i, lot in ipairs(au.lots) do
			local w = lot.bidder and env.CO.find(reg, lot.bidder) or nil
			if w and (w.gone == "merged" or w.gone == "taken") and w.mergedInto then w = env.CO.find(reg, w.mergedInto) end
			if w and live(w) and w.ent then
				sell(env, c, lot, w, lot.best, reg)
				sold = sold + 1
				news(reg, { kind = "lot_sold", co = au.co, lot = i, lk = lot.kind, label = lot.label, town = lot.town, to = w.id, amount = lot.best })
			elseif lot.kind == "company" then
				-- (the whole company unsold: its lines, depots and stations nobody else uses go, as lots of their own would)
				for _, sub in ipairs(E.lotsOf(env, c)) do
					if unsold(env, c, sub, heir) then kept = kept + 1 else gone = gone + 1 end
					dropLotRule(reg, sub)
				end
				news(reg, { kind = "lot_unsold", co = au.co, lot = i, label = lot.label })
			else
				local toHeir = unsold(env, c, lot, heir)
				if toHeir then kept = kept + 1 else gone = gone + 1 end
				news(reg, { kind = "lot_unsold", co = au.co, lot = i, lk = lot.kind, label = lot.label, town = lot.town, heir = (toHeir and heir) and heir.id or nil })
			end
			if lot.kind ~= "company" then dropLotRule(reg, lot) end
		end
		-- (whatever it still owns and nothing handed over yet: its tracks, roads, a station kept for the others' lines go to the heir;
		-- a vehicle or a line left over is sold or taken away, as an unsold lot's)
		if heir and heir.ent and os.getenv("MPFEVER_UNSOLDHEIR") ~= "0" then
			local left, sellV, dropL = {}, 0, 0
			for _, e in ipairs(E.ownedBy(env, c.ent)) do
				if not E.handing[e] then
					local okV, tv = pcall(api.engine.getComponent, e, api.type.ComponentType.TRANSPORT_VEHICLE)
					local okL, ln = pcall(api.engine.getComponent, e, api.type.ComponentType.LINE)
					if okV and tv then
						E.handing[e] = true; sellV = sellV + 1
						pcall(function() api.cmd.sendCommand(api.cmd.makeVehicleSellCmd({ e })) end)
					elseif okL and ln then
						E.handing[e] = true; dropL = dropL + 1
						pcall(function() api.cmd.sendCommand(api.cmd.makeLineDestroyCmd(e)) end)
					else
						left[#left + 1] = e
					end
				end
			end
			local n = setOwner(left, c.ent, heir.ent)
			if n > 0 then news(reg, { kind = "heir", co = au.co, to = heir.id, n = n }) end
			env.log("companies: auction of company " .. c.id .. ": " .. n .. " entities left (tracks, roads...) to company " .. heir.id
				.. ", " .. sellV .. " vehicle(s) left sold, " .. dropL .. " line(s) left taken away")
		end
	end
	end)
	E.handing = nil
	if not okC then env.log("companies: auction close failed: " .. tostring(errC)) end
	env.log("companies: auction of company " .. tostring(au.co) .. " closed: " .. sold .. " lot(s) sold, " .. gone .. " demolished, " .. kept .. " to the heir")
	E.finishAuction(st, env)
end

-- ---------------------------------------------------------------- bankruptcy
function E.bankrupt(st, c, env, maxLots)
	local reg = st.co
	c.gone = "bankrupt"
	c.debt = nil
	local mem = env.CO.ensureMembers(c)
	local names = {}
	for _, m in ipairs(mem) do names[#names + 1] = m.key end
	c.formerMembers = names
	c.members = {}
	c.chief = nil
	local lots = E.lotsOf(env, c)
	-- (autotests: the first lots only)
	if maxLots then while #lots > maxLots do table.remove(lots) end end
	reg.auctionSeq = (reg.auctionSeq or 0) + 1
	-- (0.7.4: the host's choice, see E.auctionRule; "serial" is the auction of 0.7.3)
	local mode, mins = E.auctionRule(reg)
	if mode == "serial" then
		reg.auction = { seq = reg.auctionSeq, co = c.id, lots = lots, idx = 1, openAt = gt() }
	else
		if mode == "company" and #lots > 0 then lots = { E.companyLot(env, c, lots, c.ent and nameOf(c.ent) or nil) } end
		reg.auction = { v = 2, seq = reg.auctionSeq, co = c.id, mode = mode, minutes = mins, lots = lots, openAt = gt(), bids = 0, bidders = {} }
	end
	news(reg, { kind = "bankrupt", co = c.id, lots = #lots, mode = mode, minutes = mode ~= "serial" and mins or nil })
	env.log("companies: company " .. c.id .. " is BANKRUPT (in debt for " .. tostring((reg.rules or {}).bankrupt or E.BANKRUPT_DEFAULT)
		.. " months): " .. #lots .. " lot(s) at auction (" .. mode .. (mode ~= "serial" and (", " .. mins .. " min") or "") .. "); its players get a new company")
	if #lots == 0 then
		-- (0.7.4: nothing to sell, its tracks and roads still go to the heir)
		if reg.auction.v == 2 then E.closeAll(st, env) else E.finishAuction(st, env) end
	end
end

function E.finishAuction(st, env)
	local reg = st.co
	local au = reg.auction
	if not au then return end
	news(reg, { kind = "auction_end", co = au.co })
	env.log("companies: auction of company " .. tostring(au.co) .. " finished")
	reg.auction = nil
end

local function closeLot(st, env)
	local reg = st.co
	local au = reg.auction
	local c = env.CO.find(reg, au.co)
	local lot = au.lots[au.idx]
	if c and c.ent and lot then
		local w = au.bidder and env.CO.find(reg, au.bidder) or nil
		-- (the best bidder merged meanwhile: the company it went into keeps its bid; 0.6: or taken over, see E.coMerge)
		if w and (w.gone == "merged" or w.gone == "taken") and w.mergedInto then w = env.CO.find(reg, w.mergedInto) end
		if w and live(w) and w.ent then
			sell(env, c, lot, w, au.best)
			news(reg, { kind = "lot_sold", co = au.co, lot = au.idx, label = lot.label, to = w.id, amount = au.best })
		else
			demolish(env, c, lot)
			news(reg, { kind = "lot_unsold", co = au.co, lot = au.idx, label = lot.label })
		end
		dropLotRule(reg, lot)
	end
	au.best, au.bidder, au.lastBidAt = nil, nil, nil
	au.idx = au.idx + 1
	au.openAt = gt()
	if au.idx > #au.lots then E.finishAuction(st, env) end
end

-- ---------------------------------------------------------------- the monthly look, the tolls
-- Every step (from the bridge's update). At each new game month: each playing company's months in debt (money below zero at the
-- month's turn; back to 0 when it is not), and a bankruptcy when they reach the host's rule. Returns whether the state changed.
function E.tick(st, env)
	E.env = env
	local reg = st.co
	if not (reg and reg.mode == "separate") then return false end
	local changed = false
	local okM, monthDur = pcall(api.util.getDefaultMonthDuration)
	if okM and type(monthDur) == "number" and monthDur > 0 then
		local m = math.floor(gt() / monthDur)
		if reg.month == nil then
			-- (the month the companies mode starts in is not counted)
			reg.month = m
			reg.monthSeen = m
			changed = true
		elseif m > reg.month then
			-- (the months in debt are counted when the host's look at this month arrives: see co_month)
			reg.month = m
			changed = true
		end
	end
	local okT, ch = pcall(E.tolls, st, env)
	if okT and ch then changed = true elseif not okT then env.log("companies: tolls failed: " .. tostring(ch)) end
	return changed
end

-- ---------------------------------------------------------------- the rules (tracks, stations and stops, depots)
-- Read the same way by the simulation (fees, tolls, the bridge's checks of the commands) and by the interface's half of the
-- bridge (eco.txt, shares.txt, the map's icons, the open tracks): what nothing set means is decided here, when read, so that no
-- savegame needs to be changed and every game reads the same.

-- The sharing rules switched off by the host (0.5.14, its lobby or its game settings; reg.rules.share, kept in the savegame):
-- nothing between companies then, every track, station, stop and depot is open and free, whatever a company or one of its
-- stations set (those settings are kept, and count again when the host switches the rules back on)
function E.sharingOff(reg)
	return type(reg) == "table" and type(reg.rules) == "table" and reg.rules.share == false
end

-- the rule of a company for its tracks: { rule = "private" | "open" | "toll", toll = n }; a gone company's tracks are open, and
-- so are those of a company that set nothing (0.5.2; MPFEVER_OPENDEFAULT=0: private as before)
function E.trackRule(reg, c)
	if E.sharingOff(reg) then return { rule = "open", toll = E.TOLL_DEFAULT } end
	local default = E.OPEN_DEFAULT and { rule = "open", toll = E.TOLL_DEFAULT } or { rule = "private" }
	if not c then return default end
	if c.gone then return { rule = "open", toll = E.TOLL_DEFAULT } end
	local r = reg.track and reg.track[tostring(c.id)]
	return r or default
end

-- the rule of a company for its roads (0.6.2, co_road_rule): { rule = "private" | "open" }. The other companies' street tools
-- connect to its open roads (the open network, see the bridge's G.openNet) as to its open tracks. Before, only tracks were ever
-- open: another company's roads stayed closed to every street tool, and no rule could open them. Open when nothing was set (as
-- the tracks, MPFEVER_OPENDEFAULT=0: private), a gone company's roads are open. MPFEVER_ROADRULE=0: private, as before
E.ROAD_RULE = os.getenv("MPFEVER_ROADRULE") ~= "0"
function E.roadRule(reg, c)
	if not E.ROAD_RULE then return { rule = "private" } end
	if E.sharingOff(reg) then return { rule = "open" } end
	if c and c.gone then return { rule = "open" } end
	local r = c and reg and reg.road and reg.road[tostring(c.id)]
	if r then return r end
	return E.OPEN_DEFAULT and { rule = "open" } or { rule = "private" }
end

-- the rule of a company for its depots without a setting of their own (co_depot_default): { rule, toll }; open when nothing
-- was set (0.5.2; MPFEVER_OPENDEFAULT=0: private as before), a gone company's depots are open
function E.depotCoRule(reg, c)
	if E.sharingOff(reg) then return { rule = "open", toll = E.TOLL_DEFAULT } end
	if E.OPEN_DEFAULT and c and c.gone then return { rule = "open", toll = E.TOLL_DEFAULT } end
	local r = c and reg and reg.depotCo and reg.depotCo[tostring(c.id)]
	if r then return r end
	return E.OPEN_DEFAULT and { rule = "open", toll = E.TOLL_DEFAULT } or { rule = "private", toll = E.TOLL_DEFAULT }
end

-- the rule of a depot (its key, see depotKey) of company ownerCo: its own setting (its window: reg.depots, private included since
-- 0.5.2), else its company's rule
function E.depotRule(reg, key, ownerCo)
	if E.sharingOff(reg) then return { rule = "open", toll = E.TOLL_DEFAULT } end
	local c = ownerCo and findCo(reg, ownerCo) or nil
	if E.OPEN_DEFAULT and c and c.gone then return { rule = "open", toll = E.TOLL_DEFAULT } end
	local r = reg and reg.depots and reg.depots[key]
	if r then return r end
	return E.depotCoRule(reg, c)
end

-- the rule of a company for its stations and stops (co_stop_rule): { rule, fee per stop }; open when nothing was set (0.5.2;
-- MPFEVER_OPENDEFAULT=0: a toll of $100 per stop as before), a gone company's stations are open. The fee is kept when the rule
-- is not a toll: the amount the interface proposes when the toll is chosen again.
function E.stopRule(reg, c)
	if E.sharingOff(reg) then return { rule = "open", fee = E.STOP_FEE_DEFAULT } end
	if E.OPEN_DEFAULT and c and c.gone then return { rule = "open", fee = E.STOP_FEE_DEFAULT } end
	local r = c and reg and reg.stops and reg.stops[tostring(c.id)]
	if r then return r end
	return E.OPEN_DEFAULT and { rule = "open", fee = E.STOP_FEE_DEFAULT } or { rule = "toll", fee = E.STOP_FEE_DEFAULT }
end

-- (a rule as the fees read it: a toll of 0 is open, anything unknown is open)
local function stopNorm(rule, fee)
	fee = math.floor(tonumber(fee) or 0)
	if rule == "toll" then
		if fee > 0 then return "toll", fee end
		return "open", 0
	end
	if rule == "private" then return "private", 0 end
	return "open", 0
end

-- The rule of a station (its key, see R.sgKey) of company ownerCo for the other companies: rule ("private" | "open" | "toll"),
-- fee per stop, and whether it is the station's own setting (else its company's rule). nil when the station belongs to no company
-- (a town's stop: free for everyone). In this order: a gone company's stations are open; the station's own setting (its window:
-- reg.stationRule, or the fee of 0.5.1 and before in reg.shares, 0 = private); its company's rule (E.stopRule). key may be nil
-- when no station has a setting of its own (the caller then needs not read it).
function E.stationRule(reg, key, ownerCo)
	if not ownerCo then return nil, 0, false end
	if E.sharingOff(reg) then return "open", 0, false end
	local c = findCo(reg, ownerCo)
	if E.OPEN_DEFAULT and (not c or c.gone) then return "open", 0, false end
	local o = key and reg.stationRule and reg.stationRule[key]
	if type(o) == "table" then
		local rule, fee = stopNorm(o.rule, o.fee)
		return rule, fee, true
	end
	local n = key and reg.shares and tonumber(reg.shares[key])
	if n then
		if n > 0 then return "toll", math.floor(n), true end
		return "private", 0, true
	end
	local r = E.stopRule(reg, c)
	local rule, fee = stopNorm(r.rule, r.fee)
	return rule, fee, false
end

-- what a stop of a vehicle of company lineCo at a station of company ownerCo costs: nil when nothing (its own company's
-- station, a town's, an open one); a private one its line already stops at costs E.STOP_FEE_DEFAULT (see E.PRIVATE_FEE)
function E.stopFee(reg, key, ownerCo, lineCo)
	if not ownerCo or ownerCo == lineCo then return nil end
	local rule, fee = E.stationRule(reg, key, ownerCo)
	if rule == "toll" then return fee end
	if rule == "private" and E.PRIVATE_FEE then return E.STOP_FEE_DEFAULT end
	return nil
end

-- whether a stop at some company's station may cost something (a company's rule or a station's own setting that is a toll, or
-- private when those stops pay): when none does, the fees look at no line
function E.anyStopFee(reg)
	if E.sharingOff(reg) then return false end
	local function costs(rule, fee)
		if rule == "toll" then return (tonumber(fee) or 0) > 0 end
		return rule == "private" and E.PRIVATE_FEE
	end
	for _, c in ipairs(reg.list or {}) do
		local r = E.stopRule(reg, c)
		if costs(r.rule, r.fee) then return true end
	end
	for _, o in pairs(reg.stationRule or {}) do
		if type(o) == "table" and costs(o.rule, o.fee) then return true end
	end
	for _, n in pairs(reg.shares or {}) do
		if (tonumber(n) or 0) > 0 or E.PRIVATE_FEE then return true end
	end
	return false
end

-- The stops of the other companies' vehicles at a company's stations, every 5 steps on the game time (the bridge's
-- chargeShares books them): each line's stops at another company's station that cost something (E.stopFee), and each of its
-- vehicles' next stop (a vehicle whose next stop moved on has left the stops in between). Returns the stops owed
-- ({ from, to, fee, carrier }) and whether the saved state changed (reg.vstop: each vehicle's next stop at the last look).
-- holder: a table kept between the calls (the bridge's SIM).
-- 0.5.2 (MPFEVER_FEESCAN=0: as before, the same rules):
--  * when no station of any company may cost anything (the usual case now, every station open), no line is looked at and
--    reg.vstop is forgotten. Before, every stop of every line was read every 5 steps for nothing;
--  * reg.vstop holds only the vehicles of the lines looked at, as they are now. Before, a vehicle sold stayed in it, and so
--    did one whose line no longer stopped at a paying station: its next stop of long ago stayed, and when a station became
--    paying again, its first look charged every stop between that old one and the present one, up to a whole round of the line;
--  * a station's key (R.sgKey) is read at each look, and only when some station has a setting of its own. Before, it was kept
--    for the whole game: a street stop's key changes when its street is split, the fees kept the old key while the line check
--    and the windows read the new one, and a game that read it at another time (loaded later, or in another Lua state of the
--    simulation) could charge differently.
function E.stationFees(st, env, holder)
	local reg = st.co
	local fresh = os.getenv("MPFEVER_FEESCAN") ~= "0"
	if fresh and not E.anyStopFee(reg) then
		if reg.vstop ~= nil then reg.vstop = nil; return {}, true end
		return {}, false
	end
	local needKey = not fresh or next(reg.stationRule or {}) ~= nil or next(reg.shares or {}) ~= nil
	local keys = {}
	if not fresh then
		holder.sgKeys = holder.sgKeys or {}
		keys = holder.sgKeys
	end
	local list = {}
	for _, line in ipairs(env.R.entitiesWith("LINE")) do
		-- (the stops' station groups copied at once: a component read is only valid until the next one)
		local sgs = nil
		pcall(function()
			local lc = api.engine.getComponent(line, api.type.ComponentType.LINE)
			if lc then
				sgs = {}
				for i = 1, #lc.stops do sgs[i] = lc.stops[i].stationGroup end
			end
		end)
		local lineCo = sgs and env.CO.idOfEntity(reg, env.R.ownerOf(line))
		if lineCo then
			local stops, n = {}, #sgs
			for i = 1, n do
				local sg = sgs[i]
				local ownerCo = env.CO.idOfEntity(reg, env.R.ownerOf(sg))
				if ownerCo and ownerCo ~= lineCo then
					local key = nil
					if needKey then
						key = keys[sg]
						if not key then key = env.R.sgKey(sg); keys[sg] = key end
					end
					local fee = E.stopFee(reg, key, ownerCo, lineCo)
					if fee then stops[i - 1] = { co = ownerCo, fee = fee } end
				end
			end
			if next(stops) ~= nil then list[#list + 1] = { line = line, co = lineCo, n = n, stops = stops } end
		end
	end
	if #list == 0 then
		if fresh and reg.vstop ~= nil then reg.vstop = nil; return {}, true end
		return {}, false
	end
	local was = reg.vstop or {}
	local now = fresh and {} or was
	local owed = {}
	for _, l in ipairs(list) do
		local okv, vehicles = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, l.line)
		for _, v in ipairs(okv and vehicles or {}) do
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			local idx = tv and tv.stopIndex
			if tv and not l.carrier then l.carrier = env.journalCarrier(tv.carrier) end
			if type(idx) == "number" and l.n > 0 then
				local k = tostring(v)
				local last = was[k]
				if last ~= nil and last ~= idx then
					-- the stops left since the last look: last, last+1, ... idx-1
					local s, guard = last, 0
					while s ~= idx and guard < l.n do
						local f = l.stops[s]
						if f then owed[#owed + 1] = { from = l.co, to = f.co, fee = f.fee, carrier = l.carrier } end
						s = (s + 1) % l.n
						guard = guard + 1
					end
				end
				now[k] = idx
			end
		end
	end
	if fresh then reg.vstop = next(now) ~= nil and now or nil else reg.vstop = now end
	return owed, true
end

-- (0.6.8, #115) what a company paid to another, by kind: "s" its stations' fees, "t" its tracks' tolls, "d" its depots' tolls
-- (reg.paidTo["<from>><to>:<kind>"] = amount; kept in the game's state like the totals, the same on every game). A player saw
-- only totals and could not tell that, nor to whom, a toll was paid. MPFEVER_PAIDTO=0: not kept
function E.notePaid(reg, from, to, kind, fee)
	if os.getenv("MPFEVER_PAIDTO") == "0" or type(reg) ~= "table" or from == nil or to == nil or not (tonumber(fee) and tonumber(fee) > 0) then return end
	reg.paidTo = reg.paidTo or {}
	local k = tostring(from) .. ">" .. tostring(to) .. ":" .. kind
	reg.paidTo[k] = (reg.paidTo[k] or 0) + math.floor(tonumber(fee))
end

-- Tolls: a train of a company that enters the tracks of a company whose rule is "toll" pays that company the toll, once each time it
-- enters them (every 5 steps: each line vehicle's present segment). Booked as for the shared stations: track upkeep of the
-- carrier for the train's company, revenue for the tracks' company.
function E.tolls(st, env)
	local reg = st.co
	local stepNo = math.floor(gt() / env.STEP + 0.5)
	if stepNo % 5 ~= 0 then return false end
	local tollOf = {}
	local any = false
	for _, c in ipairs(reg.list) do
		local r = E.trackRule(reg, c)
		if c.ent and r.rule == "toll" and (tonumber(r.toll) or 0) > 0 then tollOf[c.ent] = { co = c.id, toll = math.floor(tonumber(r.toll)) }; any = true end
	end
	if not any then
		if reg.tollOn then reg.tollOn = nil; return true end
		return false
	end
	local ownerCache = {}
	local CT = api.type.ComponentType
	local function ownerOfEdge(e)
		local o = ownerCache[e]
		if o == nil then
			o = false
			pcall(function()
				-- (a track: a segment without a street component, see E.TRACK_STREET)
				local track
				if E.TRACK_STREET then
					track = api.engine.entityExists(e) and api.engine.getComponent(e, CT.BASE_EDGE) ~= nil
						and api.engine.getComponent(e, CT.BASE_EDGE_STREET) == nil
				else
					track = api.engine.getComponent(e, CT.BASE_EDGE_TRACK) ~= nil
				end
				if track then
					local po = api.engine.getComponent(e, CT.PLAYER_OWNED)
					if po then o = po.player end
				end
			end)
			ownerCache[e] = o
		end
		return o
	end
	local was = reg.tollOn or {}
	local now = {}
	local owed = {}
	for _, c in ipairs(reg.list) do
		if c.ent then
			local okL, lines = pcall(api.engine.system.lineSystem.getLinesForPlayer, c.ent)
			for _, l in ipairs(okL and lines or {}) do
				local okV, vehicles = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, l)
				for _, v in ipairs(okV and vehicles or {}) do
					local edge = nil
					pcall(function()
						local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
						edge = mp.path.edges[mp.dyn.pathPos.edgeIndex + 1].edgeId.entity
					end)
					local o = type(edge) == "number" and ownerOfEdge(edge) or false
					local t = o and tollOf[o] or nil
					if t and t.co ~= c.id then
						local k = tostring(v)
						now[k] = t.co
						if was[k] ~= t.co then
							local carrier = nil
							pcall(function() carrier = env.journalCarrier(api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE).carrier) end)
							owed[#owed + 1] = { from = c, to = t.co, fee = t.toll, carrier = carrier }
						end
					end
				end
			end
		end
	end
	reg.tollOn = next(now) and now or nil
	if #owed == 0 then return true end
	local JE = api.type.JournalEntry
	reg.tollIncome = reg.tollIncome or {}
	reg.tollExpense = reg.tollExpense or {}
	for _, o in ipairs(owed) do
		local to = env.CO.find(reg, o.to)
		if to and to.ent and o.from.ent then
			book(o.from.ent, -o.fee, function(x)
				x.category.type = JE.Type.MAINTENANCE
				x.category.maintenance = JE.Maintenance.INFRASTRUCTURE
				x.category.construction = JE.Construction.TRACK
				x.category.carrier = o.carrier or JE.Carrier.RAIL
			end)
			book(to.ent, o.fee, function(x)
				x.category.type = JE.Type.INCOME
				x.category.carrier = o.carrier or JE.Carrier.RAIL
			end)
			reg.tollIncome[tostring(o.to)] = (reg.tollIncome[tostring(o.to)] or 0) + o.fee
			reg.tollExpense[tostring(o.from.id)] = (reg.tollExpense[tostring(o.from.id)] or 0) + o.fee
			E.notePaid(reg, o.from.id, o.to, "t", o.fee)
		end
	end
	E.tollLogged = (E.tollLogged or 0) + 1
	if E.tollLogged <= 20 then env.log("companies: tolls: " .. #owed .. " train(s) entered another company's tracks") end
	return true
end

-- a vehicle bought in (or sent to) another company's depot: allowed when that depot is open; returns allowed, toll. ownerCo: the
-- depot's company (its rule for the depots without a setting of their own, 0.5.2)
function E.depotUse(reg, env, depot, co, ownerCo)
	local con = E.depotCon(depot)
	local r = E.depotRule(reg, depotKey(con), ownerCo)
	if r.rule == "open" then return true, 0 end
	if r.rule == "toll" then return true, math.max(0, math.floor(tonumber(r.toll) or E.TOLL_DEFAULT)) end
	return false, 0
end

-- ---------------------------------------------------------------- merging
-- Company a goes into company b: everything a owns, its money, its MPFever loans and its players become b's (co_merge_answer).
-- (0.6) opts, for a game option's merge (E.coMerge; nil: exactly the merge above):
--   members = "release": a's players do not go into b, they get a new company with the start money, as after a bankruptcy
--                        (a.formerMembers keeps their keys);
--   gone = "taken":      a.gone (else "merged"), a.takenBy = b; the news says "taken" (the bridge's chat tells nothing of it: the
--                        option tells it itself);
--   a the savegame's company: its game loans stay with it (the game's own, it cannot hand them over), and so does the money to
--   pay them back: b gets a's money less what a still owes the game (as the option's price counts a's value: money - loans).
function E.merge(st, a, b, env, opts)
	local reg = st.co
	local list = E.ownedBy(env, a.ent)
	local n = setOwner(list, a.ent, b.ent)
	local bal = balanceOf(a.ent) or 0
	if opts and a.ent == reg.canon and bal > 0 then
		local owed = 0
		pcall(function() owed = math.floor(tonumber(api.engine.getComponent(a.ent, api.type.ComponentType.ACCOUNT).loan) or 0) end)
		if owed > 0 then
			env.log("companies: company " .. a.id .. " (the savegame's) keeps " .. math.min(owed, bal) .. " for its game loans (" .. owed .. " owed)")
			bal = bal - math.min(owed, bal)
		end
	end
	if bal ~= 0 then
		book(a.ent, -bal)
		book(b.ent, bal)
	end
	-- (the loans of a company other than the savegame's follow it: the merged company pays them from now on)
	local la = reg.loan and reg.loan[a.id]
	if la and la.obtainedLoans and #la.obtainedLoans > 0 then
		if b.ent ~= reg.canon and env.loanTable then
			local lb = env.loanTable(st, b.id)
			for _, loan in ipairs(la.obtainedLoans) do
				loan.id = lb.freeId
				lb.freeId = lb.freeId + 1
				lb.obtainedLoans[#lb.obtainedLoans + 1] = loan
			end
		elseif env.payBack then
			-- (into the savegame's company, whose loans are the game's own: paid back at once)
			local sum = 0
			for _, loan in ipairs(la.obtainedLoans) do sum = sum + (env.payBack(loan) or 0) end
			book(b.ent, -sum, function(x) x.category.type = api.type.JournalEntry.Type.LOAN end)
		end
		la.obtainedLoans = {}
	end
	local release = opts and opts.members == "release"
	local names = {}
	for _, m in ipairs(env.CO.ensureMembers(a)) do
		if release then names[#names + 1] = m.key else env.CO.addMember(b, m.key, m.sid) end
	end
	if release then a.formerMembers = names end
	a.members = {}
	a.chief = nil
	a.gone = (opts and opts.gone == "taken") and "taken" or "merged"
	a.mergedInto = b.id
	if a.gone == "taken" then a.takenBy = b.id end
	if reg.track then reg.track[tostring(a.id)] = nil end
	-- (its rules for its stations and depots go with it: they follow b's from now on. The settings of its own stations and depots
	-- are kept, they are now b's (its window shows them, its "every station" choice clears them). MPFEVER_LOTRULES=0: as before,
	-- the settings stayed a's)
	if reg.stops then reg.stops[tostring(a.id)] = nil end
	if reg.depotCo then reg.depotCo[tostring(a.id)] = nil end
	if os.getenv("MPFEVER_LOTRULES") ~= "0" then
		for _, o in pairs(reg.stationRule or {}) do if type(o) == "table" and o.co == a.id then o.co = b.id end end
		for _, d in pairs(reg.depots or {}) do if type(d) == "table" and d.co == a.id then d.co = b.id end end
	end
	news(reg, { kind = a.gone == "taken" and "taken" or "merged", co = a.id, into = b.id })
	env.log("companies: company " .. a.id .. " " .. (a.gone == "taken" and "taken over by" or "merged into") .. " company " .. b.id .. ": " .. n
		.. " entities and " .. bal .. " money change hands" .. (release and (", its " .. #names .. " player(s) get a new company") or ""))
end

-- (0.6) The merge a game option asks for (env.coMerge of mpfever_feat.lua: the stock market's takeover, mpfever_feat_stock.lua),
-- in the simulation, at the step of the option's event, on every game: company fromId goes into company intoId as E.merge does,
-- with opts (see E.merge). Returns true, or false and why (nothing done). MPFEVER_STOCKMERGE=0: always refused (no takeover, as
-- in 0.5.14).
E.OPTION_MERGE = os.getenv("MPFEVER_STOCKMERGE") ~= "0"
function E.coMerge(st, fromId, intoId, env, opts)
	E.env = env
	if not E.OPTION_MERGE then return false, "MPFEVER_STOCKMERGE=0" end
	local reg = st.co
	if not (reg and reg.mode == "separate") then return false, "not one company per player" end
	local a, b = env.CO.find(reg, tonumber(fromId)), env.CO.find(reg, tonumber(intoId))
	if not (live(a) and live(b) and a.ent and b.ent) or a.id == b.id then return false, "no such companies" end
	-- (the offers to merge from it or into it go with it)
	if reg.mergeOffers then
		local keep = {}
		for _, o in ipairs(reg.mergeOffers) do if o.from ~= a.id and o.to ~= a.id then keep[#keep + 1] = o end end
		reg.mergeOffers = keep
	end
	E.merge(st, a, b, env, type(opts) == "table" and opts or {})
	return true
end

-- ---------------------------------------------------------------- the players' events
-- The own settings of company c's stations go (co_stop_rule with reset): every one of them follows the company's rule. The
-- settings made since 0.5.2 name their company (reg.stationRule[key].co); those of 0.5.1 (reg.shares) are found by the keys of
-- the company's stations, read only when there are some. Returns how many went.
function E.dropStationRules(reg, env, c)
	local n = 0
	for k, o in pairs(reg.stationRule or {}) do
		if type(o) == "table" and o.co == c.id then reg.stationRule[k] = nil; n = n + 1 end
	end
	if c.ent and (next(reg.shares or {}) ~= nil or next(reg.stationRule or {}) ~= nil) then
		for _, sg in ipairs(stationsOf(env, c.ent)) do
			local k = env.R.sgKey(sg)
			if reg.shares and reg.shares[k] ~= nil then reg.shares[k] = nil; n = n + 1 end
			if reg.stationRule and reg.stationRule[k] ~= nil then reg.stationRule[k] = nil; n = n + 1 end
		end
	end
	return n
end

local function dropRequests(reg, key)
	local keep = {}
	for _, r in ipairs(reg.requests or {}) do if r.key ~= key then keep[#keep + 1] = r end end
	reg.requests = keep
end

local function dropOffers(reg, from)
	local keep = {}
	for _, o in ipairs(reg.mergeOffers or {}) do if o.from ~= from then keep[#keep + 1] = o end end
	reg.mergeOffers = keep
end

-- a player goes into company t (from the company it played, which keeps running without it; an empty one, nothing built and
-- nobody else in it, is gone)
local function moveMember(st, key, t, env)
	local reg = st.co
	local cur = env.CO.memberOf(reg, key)
	local sid = nil
	if cur then
		local m = env.CO.removeMember(cur, key)
		sid = m and m.sid
		if #env.CO.members(cur) == 0 and not E.hasAssets(env, cur) then
			cur.gone = "empty"
			dropOffers(reg, cur.id)
		end
	end
	env.CO.addMember(t, key, sid)
	dropRequests(reg, key)
	news(reg, { kind = "joined", key = key, co = t.id, from = cur and cur.id or nil })
	env.log("companies: player '" .. key .. "' joins company " .. t.id .. (cur and (" (leaves company " .. cur.id .. ")") or ""))
end

-- (0.8.3) A loan's terms from an event: amount (whole money), months (1..E.LOAN_MONTHS_MAX), rate (% of the amount for the whole
-- loan, 0..E.LOAN_RATE_MAX); nil and why when they cannot be taken
function E.loanTerms(param)
	local a = math.floor(tonumber(param.amount) or 0)
	local m = math.floor(tonumber(param.months) or 0)
	local r = math.floor(tonumber(param.rate) or -1)
	if a <= 0 or a > E.LOAN_AMOUNT_MAX then return nil, "amount " .. tostring(param.amount) end
	if m < 1 or m > E.LOAN_MONTHS_MAX then return nil, "months " .. tostring(param.months) end
	if r < 0 or r > E.LOAN_RATE_MAX then return nil, "rate " .. tostring(param.rate) end
	return { amount = a, months = m, rate = r }
end

-- what the borrower pays back in all, and each month
function E.loanPlan(t)
	local total = math.floor(t.amount * (100 + t.rate) / 100 + 0.5)
	return total, math.ceil(total / t.months)
end

-- the loans' events: co_loan_ask {to, amount, months, rate} (the borrower's chief), co_loan_counter {id, amount, months, rate} and
-- co_loan_answer {id, accept} (the chief whose turn it is), co_loan_cancel {id} (either chief). reg.loanOffers: { id, borrower,
-- lender, amount, months, rate, turn = "lender" | "borrower" (who answers next) }; reg.loans: { id, borrower, lender, amount, months,
-- rate, total, monthly, rest }
function E.loanEvent(st, name, param, env, mine, key, refuse)
	local reg = st.co
	if not E.LOANS then return refuse("loans are off (MPFEVER_LOANS=0)") end
	if not (live(mine) and mine.ent and env.CO.chief(mine) == key) then return refuse("not the chief of a company") end
	reg.loanOffers = reg.loanOffers or {}
	reg.loans = reg.loans or {}
	local function findOffer(id)
		for i, o in ipairs(reg.loanOffers) do if o.id == tonumber(id) then return o, i end end
	end
	if name == "co_loan_ask" then
		local t = env.CO.find(reg, tonumber(param.to))
		if not (live(t) and t.ent) or t.id == mine.id then return refuse("no such company") end
		local terms, why = E.loanTerms(param)
		if not terms then return refuse(why) end
		-- (one offer between two companies: a new ask takes the place of the last one)
		for i = #reg.loanOffers, 1, -1 do
			local o = reg.loanOffers[i]
			if o.borrower == mine.id and o.lender == t.id then table.remove(reg.loanOffers, i) end
		end
		reg.loanSeq = (reg.loanSeq or 0) + 1
		reg.loanOffers[#reg.loanOffers + 1] = { id = reg.loanSeq, borrower = mine.id, lender = t.id, amount = terms.amount, months = terms.months,
			rate = terms.rate, turn = "lender", at = gt() }
		while #reg.loanOffers > 20 do table.remove(reg.loanOffers, 1) end
		news(reg, { kind = "loan_ask", co = mine.id, to = t.id, amount = terms.amount, months = terms.months, rate = terms.rate })
		env.log("companies: company " .. mine.id .. " asks company " .. t.id .. " for a loan of " .. terms.amount .. " over " .. terms.months .. " month(s) at " .. terms.rate .. " %")
		return
	end
	local o, idx = findOffer(param.id)
	if not o then return refuse("no such offer") end
	local myTurn = (o.turn == "lender" and mine.id == o.lender) or (o.turn == "borrower" and mine.id == o.borrower)
	if name == "co_loan_cancel" then
		if mine.id ~= o.lender and mine.id ~= o.borrower then return refuse("not its offer") end
		table.remove(reg.loanOffers, idx)
		news(reg, { kind = "loan_refused", co = o.borrower, to = o.lender, by = mine.id })
		return
	end
	if not myTurn then return refuse("not its turn") end
	if name == "co_loan_counter" then
		local terms, why = E.loanTerms(param)
		if not terms then return refuse(why) end
		o.amount, o.months, o.rate = terms.amount, terms.months, terms.rate
		o.turn = o.turn == "lender" and "borrower" or "lender"
		o.at = gt()
		news(reg, { kind = "loan_counter", co = mine.id, to = (mine.id == o.lender) and o.borrower or o.lender, amount = o.amount, months = o.months, rate = o.rate })
		env.log("companies: company " .. mine.id .. " answers loan offer " .. o.id .. ": " .. o.amount .. " over " .. o.months .. " month(s) at " .. o.rate .. " %")
		return
	end
	if name == "co_loan_answer" then
		table.remove(reg.loanOffers, idx)
		if not param.accept then
			news(reg, { kind = "loan_refused", co = o.borrower, to = o.lender, by = mine.id })
			return
		end
		local lender, borrower = env.CO.find(reg, o.lender), env.CO.find(reg, o.borrower)
		if not (live(lender) and lender.ent and live(borrower) and borrower.ent) then return refuse("a company is gone") end
		local bal = balanceOf(lender.ent)
		if not (bal and bal >= o.amount) then
			news(reg, { kind = "loan_nomoney", co = o.borrower, to = o.lender, amount = o.amount })
			return refuse("the lender has " .. tostring(bal) .. ", not " .. o.amount)
		end
		book(lender.ent, -o.amount)
		book(borrower.ent, o.amount)
		local total, monthly = E.loanPlan(o)
		reg.loans[#reg.loans + 1] = { id = o.id, borrower = o.borrower, lender = o.lender, amount = o.amount, months = o.months, rate = o.rate,
			total = total, monthly = monthly, rest = total, at = gt() }
		news(reg, { kind = "loan_ok", co = o.borrower, to = o.lender, amount = o.amount, months = o.months, rate = o.rate })
		env.log("companies: loan " .. o.id .. ": company " .. o.lender .. " lends " .. o.amount .. " to company " .. o.borrower .. ", " .. total .. " to pay back, " .. monthly .. " a month")
	end
end

-- (0.8.3) each new month (co_month, every game at the same step): the loans' parts paid back
function E.loanMonth(reg, env)
	if not E.LOANS or type(reg.loans) ~= "table" or #reg.loans == 0 then return end
	local keep = {}
	for _, l in ipairs(reg.loans) do
		local b, le = env.CO.find(reg, l.borrower), env.CO.find(reg, l.lender)
		if not (live(b) and b.ent) then
			news(reg, { kind = "loan_lost", co = l.borrower, to = l.lender, amount = l.rest })
		elseif not (live(le) and le.ent) then
			news(reg, { kind = "loan_freed", co = l.borrower, to = l.lender, amount = l.rest })
		else
			local pay = math.min(l.rest, l.monthly)
			book(b.ent, -pay)
			book(le.ent, pay)
			l.rest = l.rest - pay
			if l.rest > 0 then keep[#keep + 1] = l else news(reg, { kind = "loan_done", co = l.borrower, to = l.lender, amount = l.total }) end
		end
	end
	reg.loans = keep
end

function E.event(st, name, param, env)
	E.env = env
	local reg = st.co
	if not (reg and reg.mode == "separate") then return end
	param = type(param) == "table" and param or {}
	local key, plain = keyOf(param.mpfFrom)
	local mine = tonumber(param.mpfCo) and env.CO.find(reg, tonumber(param.mpfCo)) or nil
	local function refuse(why) env.log("companies: " .. name .. " of '" .. tostring(param.mpfFrom) .. "' refused: " .. why) end
	if name:sub(1, 8) == "co_loan_" then return E.loanEvent(st, name, param, env, mine, key, refuse) end
	if name == "co_rules" then
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local b = tonumber(param.bankrupt)
		local ok = false
		for _, x in ipairs(E.BANKRUPT_CHOICES) do if b == x then ok = true end end
		if not ok then return refuse("months " .. tostring(param.bankrupt)) end
		reg.rules = reg.rules or {}
		reg.rules.bankrupt = b
		-- (0.5.14) the sharing rules on or off, the start money of a new company (none sent: unchanged)
		if param.share ~= nil then reg.rules.share = param.share ~= false end
		local s = tonumber(param.start)
		if s and s >= 0 and s <= 1e10 then reg.rules.start = math.floor(s) end
		-- (the computer companies' colours, levels and start money, "n:colour:level[:money],...": digits, ':', ',' and '-' only)
		if type(param.ai) == "string" and #param.ai <= 300 and not param.ai:find("[^%d:,%-]") then reg.rules.ai = param.ai end
		-- (0.7.4) the auction of a bankrupt company, "mode:minutes" (see E.auctionRule)
		if type(param.auction) == "string" then
			local m, mi = param.auction:match("^(%a+):(%d+)$")
			if m and E.AUCTION_MODES[m] then
				local okM = false
				for _, x in ipairs(E.AUCTION_MINUTES) do if x == tonumber(mi) then okM = true end end
				if okM then reg.rules.auction = m .. ":" .. mi end
			end
		end
		-- (one text MPFever.exe finds in the savegame, to show this game's rules again in a lobby opened on it)
		reg.rules.cfg = "mpfrules:bankrupt=" .. b .. ";share=" .. (reg.rules.share == false and "0" or "1") .. ";start=" .. tostring(reg.rules.start or "")
			.. ";ai=" .. tostring(reg.rules.ai or "") .. ";auction=" .. tostring(reg.rules.auction or E.AUCTION_DEFAULT) .. ";"
		env.log("companies: rules: bankruptcy after " .. b .. " month(s) in debt" .. (b == 0 and " (never)" or "")
			.. ", sharing rules " .. (reg.rules.share == false and "OFF (everything open and free)" or "on") .. ", start money " .. tostring(reg.rules.start)
			.. ", auction " .. tostring(reg.rules.auction or E.AUCTION_DEFAULT))
	elseif name == "co_join_ask" then
		local t = env.CO.find(reg, tonumber(param.to))
		local cur = env.CO.memberOf(reg, key)
		if key == "" or not live(t) then return refuse("no such company") end
		if cur and cur.id == t.id then return refuse("already in it") end
		dropRequests(reg, key)
		reg.requests[#reg.requests + 1] = { key = key, name = plain, to = t.id, at = gt() }
		news(reg, { kind = "ask", key = key, name = plain, co = t.id })
		env.log("companies: '" .. key .. "' asks to join company " .. t.id)
	elseif name == "co_cancel" then
		-- (the request to join, or the merger offered, as asked: both when nothing says which)
		if param.what ~= "merge" then dropRequests(reg, key) end
		if param.what ~= "join" and mine and env.CO.chief(mine) == key then dropOffers(reg, mine.id) end
	elseif name == "co_join_answer" then
		if not (live(mine) and env.CO.chief(mine) == key) then return refuse("not the chief of company " .. tostring(param.mpfCo)) end
		local found = nil
		for _, r in ipairs(reg.requests or {}) do if r.key == param.key and r.to == mine.id then found = r end end
		if not found then return refuse("no such request") end
		if param.accept then moveMember(st, found.key, mine, env)
		else
			dropRequests(reg, found.key)
			news(reg, { kind = "refused", key = found.key, co = mine.id })
		end
	elseif name == "co_leave" then
		if not live(mine) then return refuse("no company") end
		local cur = env.CO.memberOf(reg, key)
		if not cur or cur.id ~= mine.id then return refuse("not a member") end
		if #env.CO.members(cur) <= 1 then return refuse("alone in it") end
		env.CO.removeMember(cur, key)
		cur.left = cur.left or {}
		cur.left[key] = true
		news(reg, { kind = "left", key = key, co = cur.id })
		env.log("companies: player '" .. key .. "' leaves company " .. cur.id .. " (it gets a new one)")
	elseif name == "co_merge_ask" then
		local t = env.CO.find(reg, tonumber(param.to))
		if not (live(mine) and env.CO.chief(mine) == key) then return refuse("not a chief") end
		if not live(t) or t.id == mine.id then return refuse("no such company") end
		dropOffers(reg, mine.id)
		reg.mergeOffers[#reg.mergeOffers + 1] = { from = mine.id, to = t.id, at = gt() }
		news(reg, { kind = "merge_ask", co = mine.id, to = t.id })
		env.log("companies: company " .. mine.id .. " offers to merge into company " .. t.id)
	elseif name == "co_merge_answer" then
		if not (live(mine) and env.CO.chief(mine) == key) then return refuse("not a chief") end
		local from = env.CO.find(reg, tonumber(param.from))
		local found = false
		for _, o in ipairs(reg.mergeOffers or {}) do if o.from == tonumber(param.from) and o.to == mine.id then found = true end end
		if not (found and live(from) and from.ent and mine.ent) then return refuse("no such offer") end
		dropOffers(reg, from.id)
		if param.accept then E.merge(st, from, mine, env)
		else news(reg, { kind = "merge_refused", co = from.id, to = mine.id }) end
	elseif name == "co_bid" and reg.auction and reg.auction.v == 2 then
		-- (0.7.4) any lot of an auction of every lot at once
		local au = reg.auction
		local idx = tonumber(param.lot)
		local lot = au.seq == tonumber(param.seq) and idx and au.lots[idx] or nil
		if not lot then return refuse("no such lot") end
		if not (live(mine) and mine.ent) or mine.id == au.co then return refuse("company " .. tostring(param.mpfCo)) end
		local amount = math.floor(tonumber(param.amount) or 0)
		local min = E.minBid(lot)
		if amount < min then return refuse("bid " .. amount .. " below " .. min) end
		-- (no balance read here, as before: a game's own balance may lag a step behind the host's. The window offers only what the
		-- company has left once its other best bids are counted; a winner short of money is in debt)
		lot.best, lot.bidder, lot.lastBidAt = amount, mine.id, gt()
		lot.bids = (lot.bids or 0) + 1
		au.bids = (au.bids or 0) + 1
		au.lastBidAt = gt()
		au.bidders = au.bidders or {}
		au.bidders[tostring(mine.id)] = true
		news(reg, { kind = "bid", co = au.co, lot = idx, label = lot.label, by = mine.id, amount = amount })
		env.log("companies: auction: company " .. mine.id .. " bids " .. amount .. " on lot " .. idx .. " (" .. tostring(lot.label) .. ")")
	elseif name == "co_auction_close" then
		-- (0.7.4) the host's clock of an auction of every lot at once is over
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local au = reg.auction
		if not (au and au.v == 2 and au.seq == tonumber(param.seq)) then return refuse("auction already closed") end
		E.closeAll(st, env)
	elseif name == "co_bid" then
		local au = reg.auction
		if not (au and au.seq == tonumber(param.seq) and au.idx == tonumber(param.lot)) then return refuse("not the lot under the hammer") end
		if not (live(mine) and mine.ent) or mine.id == au.co then return refuse("company " .. tostring(param.mpfCo)) end
		local lot = au.lots[au.idx]
		local amount = math.floor(tonumber(param.amount) or 0)
		local min = math.max(lot.reserve or 0, au.best and math.ceil(au.best * (1 + E.MIN_RAISE)) or 0)
		if amount < min then return refuse("bid " .. amount .. " below " .. min) end
		-- (no balance read here: a game's own balance may lag a step behind the host's, and the bid would be taken on one
		-- game and refused on another. The interface offers only what the company has; a winner short of money is in debt)
		au.best, au.bidder, au.lastBidAt = amount, mine.id, gt()
		au.bids = (au.bids or 0) + 1
		news(reg, { kind = "bid", co = au.co, lot = au.idx, by = mine.id, amount = amount })
		env.log("companies: auction: company " .. mine.id .. " bids " .. amount .. " on lot " .. au.idx)
	elseif name == "co_lot_close" then
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local au = reg.auction
		if not (au and au.seq == tonumber(param.seq) and au.idx == tonumber(param.lot)) then return refuse("lot already closed") end
		closeLot(st, env)
	elseif name == "co_track_rule" then
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" and rule ~= "toll" then return refuse("rule " .. rule) end
		reg.track = reg.track or {}
		reg.track[tostring(mine.id)] = { rule = rule, toll = math.max(0, math.floor(tonumber(param.toll) or E.TOLL_DEFAULT)) }
		news(reg, { kind = "track_rule", co = mine.id, rule = rule, toll = reg.track[tostring(mine.id)].toll })
		env.log("companies: company " .. mine.id .. " tracks: " .. rule)
	elseif name == "co_road_rule" then
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" then return refuse("rule " .. rule) end
		reg.road = reg.road or {}
		reg.road[tostring(mine.id)] = { rule = rule }
		news(reg, { kind = "road_rule", co = mine.id, rule = rule })
		env.log("companies: company " .. mine.id .. " roads: " .. rule)
	elseif name == "co_month" then
		-- the host's look at a new month: each playing company in debt there one month more, the others none
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local m = tonumber(param.month)
		if not m or m <= (reg.monthSeen or -1) then return refuse("month " .. tostring(param.month) .. " already seen") end
		reg.monthSeen = m
		local inDebt = {}
		for _, id in ipairs(type(param.debt) == "table" and param.debt or {}) do inDebt[tonumber(id) or -1] = true end
		local limit = tonumber((reg.rules or {}).bankrupt) or E.BANKRUPT_DEFAULT
		for _, c in ipairs(reg.list) do
			if live(c) and #env.CO.members(c) > 0 then
				-- (0.6: a computer company's months in debt are not counted, see E.AI_NO_BANKRUPT; a count of an earlier version goes)
				if inDebt[c.id] and not (E.AI_NO_BANKRUPT and E.isAi(c)) then
					c.debt = (c.debt or 0) + 1
					news(reg, { kind = "debt", co = c.id, months = c.debt, limit = limit })
				else
					c.debt = nil
				end
			end
		end
		if limit > 0 and not reg.auction then
			for _, c in ipairs(reg.list) do
				if live(c) and (c.debt or 0) >= limit and not (E.AI_NO_BANKRUPT and E.isAi(c)) then E.bankrupt(st, c, env) break end
			end
		end
		-- (0.8.3) the loans' monthly parts
		E.loanMonth(reg, env)
	elseif name == "co_test" then
		-- (autotests only, MPFEVER_SCENARIO set: a company goes bankrupt at once, with its first lots only. 0.7.4: or the host's
		-- test button, MPFEVER_AUCTIONTEST=1 on the host's PC, hostTest: taken from the host only, by every game alike)
		if not (os.getenv("MPFEVER_SCENARIO") or (param.hostTest == true and fromHost(param.mpfFrom) and param.op == "bankrupt")) then return refuse("not a test") end
		local c = env.CO.find(reg, tonumber(param.co))
		if param.op == "bankrupt" and live(c) and not reg.auction then E.bankrupt(st, c, env, tonumber(param.maxLots)) end
		-- (a company spends all its money and 100000 more: the months in debt then count)
		if param.op == "broke" and live(c) and c.ent then book(c.ent, -((balanceOf(c.ent) or 0) + 100000)) end
	elseif name == "co_depot_rule" then
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" and rule ~= "toll" and rule ~= "co" then return refuse("rule " .. rule) end
		-- (only its own depots)
		local ownerOk = false
		for _, d in ipairs(depotsOf(env, mine.ent)) do if depotKey(d) == param.key then ownerOk = true end end
		if not ownerOk then return refuse("not its depot") end
		reg.depots = reg.depots or {}
		-- (0.5.2: "co" takes the depot's own setting away, it follows its company's rule; private is a setting of its own, since
		-- the company's rule may be open. MPFEVER_OPENDEFAULT=0: private is no setting, as before)
		if rule == "co" or (rule == "private" and not E.OPEN_DEFAULT) then
			reg.depots[tostring(param.key)] = nil
		else
			reg.depots[tostring(param.key)] = { rule = rule, toll = math.max(0, math.floor(tonumber(param.toll) or E.TOLL_DEFAULT)), co = mine.id }
		end
		env.log("companies: company " .. mine.id .. " depot " .. tostring(param.key) .. ": " .. rule)
	elseif name == "co_depot_default" then
		-- a company's rule for its depots (the depots without a setting of their own): any of its players may change it
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" and rule ~= "toll" then return refuse("rule " .. rule) end
		local toll = math.max(0, math.floor(tonumber(param.toll) or E.TOLL_DEFAULT))
		reg.depotCo = reg.depotCo or {}
		reg.depotCo[tostring(mine.id)] = { rule = rule, toll = toll }
		news(reg, { kind = "depot_rule", co = mine.id, rule = rule, toll = toll })
		env.log("companies: company " .. mine.id .. " depots: " .. rule .. (rule == "toll" and (" " .. toll) or ""))
	elseif name == "co_stop_rule" then
		-- a company's rule for its stations and stops (those without a setting of their own; reset: all of them): any of its
		-- players may change it
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" and rule ~= "toll" then return refuse("rule " .. rule) end
		local fee = math.max(0, math.floor(tonumber(param.fee) or E.STOP_FEE_DEFAULT))
		-- (a toll of nothing is no toll)
		if rule == "toll" and fee <= 0 then rule = "open" end
		reg.stops = reg.stops or {}
		reg.stops[tostring(mine.id)] = { rule = rule, fee = fee > 0 and fee or E.STOP_FEE_DEFAULT }
		local cleared = param.reset and E.dropStationRules(reg, env, mine) or 0
		-- (the vehicles' next stops are read afresh: the fees count from the next look on, see E.stationFees)
		reg.vstop = nil
		news(reg, { kind = "stop_rule", co = mine.id, rule = rule, fee = reg.stops[tostring(mine.id)].fee, reset = param.reset and true or nil })
		env.log("companies: company " .. mine.id .. " stations: " .. rule .. (rule == "toll" and (" " .. fee .. " per stop") or "")
			.. (param.reset and (", " .. cleared .. " station setting(s) of its own cleared") or ""))
	end
end

return E
