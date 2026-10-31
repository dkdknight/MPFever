-- Computer companies (AI, experimental, 0.5.12): companies the host's game runs by itself, in the companies mode. The host adds
-- them in its lobby (each with its colour); a savegame's computer companies are taken again by the lobby. Every decision is taken
-- on the host only and goes to the other games exactly as a player's builds and actions do (their replays, their stamps): no new
-- determinism risk. The module keeps no knowledge of its own across loads: each step reads the world (what the company owns) and
-- does the next thing missing, one at a time. Several companies take their steps in turn.
local M = {}

-- the company of the step under way (see M.tick): its key in the registry ("ai:<n>"), its name, its colour (a palette index)
local AIKEY, AINAME, AICOLOR, AINUM, AIMONEY = "ai:1", "", 7, 1, nil
-- the names of new computer companies, by number
local NAMES_FR = { "Transports Régionaux", "Cars de la Vallée", "Lignes du Littoral", "Autocars du Plateau", "Réseau des Collines", "Transports du Pays",
	"Bus de la Plaine", "Lignes de l'Estuaire" }
local NAMES_EN = { "Regional Transport", "Valley Coaches", "Coastal Lines", "Plateau Buses", "Hills Network", "Country Transport",
	"Plain Buses", "Estuary Lines" }
-- (two-sided: a bus going either way along the street stops at it; a one-sided stop on a line there and back left the engine
-- searching for a way to turn round, and the simulation stood still on every game)
local STOP_MODEL = "stations/street/small_stops/small_old_twosided.con"
local DEPOT_FILE = "::/depots/road/road_maint_station.con"
local TICK = 60            -- frames between two looks at the world
local RESERVE = 400000     -- money kept back (the lines' first months cost more than they earn): the level's, see LEVELS
local BUS_COST = 180000    -- a bus, until the first purchase measures it
-- (0.6) The floor: money no purchase or build ever takes the company under (see spendOk), whatever the project: two months of
-- its vehicles' running costs and of its loans' payments, at least FLOOR_MIN, never above its reserve (set in step). A computer
-- company never goes bankrupt any more (mpfever_eco.lua), it keeps itself solvent: under its reserve it opens nothing new and
-- sells the vehicles of its losing lines; under its floor it sells faster, then takes a loan (see manageLines).
-- MPFEVER_AIFLOOR=0: no floor (the reserve of each project only, as before); MPFEVER_AISOLVENT=0: the old rules in debt
local FLOOR_MIN = 100000
local FLOOR = FLOOR_MIN

-- The levels (0.5.13), the host's choice for each company in its lobby: how often it looks at the world (frames), the money it
-- keeps back, the vehicles a line may get, when a line gets one more (seats used, cargo waiting), how many of its lines carry
-- freight, how far its freight goes, and whether it competes with the players (Hard: the industries and towns they serve are
-- not left to them).
-- (0.5.14) and how it grows: its first lines (bootstrap) freely, then a new one only once the last one had time to fill
-- (settle, game time) and while its lines earn (their result together) or it holds that much money besides its reserve (freeCash);
-- whether the lines between towns and the freight come before the towns' own lines (profitFirst: a fare grows with the
-- distance flown, so the short town lines earn the least)
local LEVELS = {
	{ name = "easy", tick = 150, reserve = 700000, maxBus = 4, maxTruck = 5, busUse = 0.85, truckUse = 0.6, waiting = 80, freightShare = 1 / 3,
		freightMax = 4000, compete = false, townMin = 600, pause = 1200, bootstrap = 1, settle = 480000, freeCash = 3000000, maxUnproven = 1, profitFirst = true, runMonths = 6, addMargin = 1.3, giveUp = 0.4, ramp = 480000 },
	{ name = "normal", tick = 60, reserve = 400000, maxBus = 8, maxTruck = 10, busUse = 0.75, truckUse = 0.45, waiting = 40, freightShare = 1 / 2,
		freightMax = 5000, compete = false, townMin = 500, pause = 600, bootstrap = 2, settle = 360000, freeCash = 2000000, maxUnproven = 1, profitFirst = true, runMonths = 4, addMargin = 1.15, giveUp = 0.5, ramp = 360000 },
	{ name = "hard", tick = 30, reserve = 350000, maxBus = 12, maxTruck = 14, busUse = 0.6, truckUse = 0.35, waiting = 25, freightShare = 2 / 3,
		freightMax = 6500, compete = true, townMin = 300, pause = 300, bootstrap = 3, settle = 240000, freeCash = 1200000, maxUnproven = 2, profitFirst = true, runMonths = 3, addMargin = 1.05, giveUp = 0.6, ramp = 300000 },
}
local LV = LEVELS[2]
-- (0.6.4) the computer companies' railways, see "trains" below
local RL = { MIN = 2500, MAX = 15000, LEN = 3, STEP = 60, GRADE = 0.03, STATION = "::/stations/rail/modular_station/modular_station.con",
	DEPOT = "::/depots/rail/rail_depot.con", DEPOT_EXIT = { x = -12.2, y = -90 }, POWER = 400, WAGONS = 6,
	OFFSETS = { 0, 0.12, -0.12, 0.25, -0.25, 0.4, -0.4 }, CELL = 100, CROSS = 300, ALONG = 150, LEG = 600, LEAD = 500, RADIUS = 80, TRIES = 3, SPAN = 50, CLEAR = 7, WATER = 300, WET = 400, IDLE_TRIES = 20,
	RAMP = 0.07, LOOK = 7200, MAXTRAINS = 3, NEAR = 8, NEARCELL = 20, MINPROD = tonumber(os.getenv("MPFEVER_AIRAILMIN") or "") or 300, LOSSLOOKS = 5 }

local function L(E, s) E.log("AI" .. (AINUM ~= 1 and tostring(AINUM) or "") .. " " .. s) end

-- the computer companies the host chose in its lobby: "n:colour:level,..." (the session's "ai"; 0.5.12 sent "n:colour"), as
-- { { n, color, level }... }; the developer tests' MPFEVER_AI=1 gives the first one when the session has none
function M.listOf(text)
	local out, seen = {}, {}
	for part in tostring(text or ""):gmatch("[^,;]+") do
		-- ("n:colour:level:money", 0.5.14: its start money, -1 or none = the players')
		local n, ix, lv, mo = part:match("^%s*(%d+):(%d+):?(%d*):?(%-?%d*)%s*$")
		n, ix, lv, mo = tonumber(n), tonumber(ix), tonumber(lv), tonumber(mo)
		if n and n >= 1 and n <= 32 and not seen[n] then
			seen[n] = true
			out[#out + 1] = { n = n, color = ix, level = (lv and lv >= 1 and lv <= 3) and lv or 2, money = (mo and mo >= 0 and mo <= 1e10) and mo or nil }
		end
	end
	return out
end

local function newName(E, n)
	local list = (E.C.LANGCODE == "fr") and NAMES_FR or NAMES_EN
	return list[(n - 1) % #list + 1] .. (n > #list and (" " .. tostring(n)) or "")
end

-- ------------------------------------------------------------------ reading the world

local function aiCompany(E)
	local reg = E.G.co
	if not reg then return nil end
	return E.CO.byKey(reg, AIKEY)
end

-- (0.6, the game option "territory", F5) The players' territories (mpfever_feat_territory.lua): a computer company builds no stop,
-- depot or garage within another company's territory, and leaves the towns there out of its lines. nil while no game option is
-- on (the bridge's G.featOn: nothing read, the company plays as without the options) or while no territory protects against it;
-- else a function(x, y) that says whether it may not build there. MPFEVER_AITERRITORY=0: never
local function territoryCheck(E)
	local G = E.G
	if not (G and G.featOn) or os.getenv("MPFEVER_AITERRITORY") == "0" then return nil end
	local ok, chk = pcall(function()
		local co = aiCompany(E)
		local F = co and E.C.feat and E.C.feat()
		local st = G.featSt
		if not (F and F.moduleOn and type(st) == "table" and G.featBridge) then return nil end
		local T, env = F.moduleOn("territory", st, G.featBridge())
		if not (T and T.blockedFor and T.anyFor and T.anyFor(st, co.id)) then return nil end
		return function(x, y)
			local okb, b, other, town = pcall(T.blockedFor, st, env, co.id, x, y)
			if okb and b == true then
				G.aiTerrN = (G.aiTerrN or 0) + 1
				if G.aiTerrN <= 5 or G.aiTerrN % 200 == 0 then
					L(E, "feat territory: a place at " .. math.floor(x) .. "," .. math.floor(y) .. " left out, territory of company " .. tostring(other) .. " (" .. tostring(town) .. ") [" .. G.aiTerrN .. " so far]")
				end
				return true
			end
			return false
		end
	end)
	return ok and chk or nil
end

local function balanceOf(E, ent)
	local ok, acc = pcall(function() return E.api.engine.getComponent(ent, E.api.type.ComponentType.ACCOUNT) end)
	return ok and acc and acc.balance or 0
end

local function ownerOf(E, e)
	local ok, o = pcall(function() return E.R.ownerOf(e) end)
	return ok and o or nil
end

local function townName(E, t)
	local n = tostring(t)
	pcall(function() n = E.api.engine.getComponent(t, E.api.type.ComponentType.NAME).name end)
	return n
end

local function centre(E, t, use)
	local api = E.api
	local ok, p = pcall(function() return api.engine.util.town.getTownDistrictCenter(t, use) end)
	if ok and p then return { x = p.x, y = p.y, z = p.z } end
	return nil
end

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

local function currentYear(E)
	local api = E.api
	local y = 1940
	pcall(function()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		local now, best = gt.gameTime, -1
		for _, d in ipairs(gt.dates) do
			if d[1] <= now and d[1] > best then best = d[1]; y = d[2].year end
		end
	end)
	return y
end

-- towns by inhabitants (residential capacity), the biggest first
local function townsBySize(E)
	local api, R = E.api, E.R
	local caps = {}
	pcall(function() caps = api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() end)
	local list = {}
	for _, t in ipairs(R.entitiesWith("TOWN")) do
		local c = caps[t]
		list[#list + 1] = { e = t, size = c and ((c[1] or 0) + (c[2] or 0) + (c[3] or 0)) or 0 }
	end
	table.sort(list, function(a, b) if a.size ~= b.size then return a.size > b.size end return a.e < b.e end)
	return list
end

-- towns for the company's own lines: the biggest first, the ones the other companies already serve put back (a town crossed by a
-- player's line of 15 stops left the company's new line a few passengers only; and the players keep their towns, PvE)
local function townsForLines(E, ent)
	local api = E.api
	local list = townsBySize(E)
	-- (0.6, F5) a town whose centre is in a player's territory is left out (see territoryCheck)
	local terr = territoryCheck(E)
	if terr then
		local keep = {}
		for _, t in ipairs(list) do
			local c = centre(E, t.e, api.type.enum.LandUseType.RESIDENTIAL)
			if not (c and terr(c.x, c.y)) then keep[#keep + 1] = t end
		end
		list = keep
	end
	for _, t in ipairs(list) do
		local others = 0
		pcall(function()
			for _, s in ipairs(api.engine.system.stationSystem.getStations(t.e)) do
				-- (0.5.14: another company's station; a station nobody owns, an industry's own, is none. MPFEVER_AIRETRY=0: counted)
				local o = ownerOf(E, s)
				if o ~= ent and (o ~= nil or os.getenv("MPFEVER_AIRETRY") == "0") then others = others + 1 end
			end
		end)
		-- (0.5.14) a town another computer company already works on counts as served too: the companies all start at once, and
		-- three of them built their rings in the same three towns in the tests of 2026-10-29. MPFEVER_AISPREAD=0: as before
		if os.getenv("MPFEVER_AISPREAD") ~= "0" then
			for _, S in pairs(E.G.AIS or {}) do
				if S ~= E.G.AI and type(S.targets) == "table" and S.targets[t.e] then others = others + (LV.compete and 3 or 8) end
			end
		end
		t.others = others
		t.score = t.size / (1 + others / (LV.compete and 12 or 3))
	end
	table.sort(list, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.e < b.e end)
	return list
end

-- the company's street stations: station group -> { station entity, edge, position }
-- (every street segment is read: kept 10 s, or until the company's next build)
local function myStops(E, ent)
	local api, R = E.api, E.R
	local A = E.G.AI or {}
	local cache = A.stopsCache
	if cache and cache.ent == ent and E.G.frames - cache.frame < 600 then return cache.list end
	local out = {}
	A.stopsCache = { ent = ent, frame = E.G.frames, list = out }
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and #c.objects > 0 then
			for k = 1, #c.objects do
				local eo = c.objects[k][1]
				if ownerOf(E, eo) == ent and api.engine.getComponent(eo, api.type.ComponentType.STATION) then
					local okg, sg = pcall(function() return api.engine.system.stationGroupSystem.getStationGroup(eo) end)
					local a, b = E.nodePosition(c.node0), E.nodePosition(c.node1)
					if okg and sg and a and b then
						out[#out + 1] = { station = eo, group = sg, edge = e, pos = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 } }
					end
				end
			end
		end
	end
	return out
end

local function myDepots(E, ent)
	local api, R = E.api, E.R
	local out = {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		if c and #c.depots > 0 and ownerOf(E, e) == ent and tostring(c.fileName):find("road", 1, true) then
			local m = E.C.marshal(c.transf)
			out[#out + 1] = { con = e, depot = c.depots[1], pos = { x = m[13], y = m[14], z = m[15] } }
		end
	end
	return out
end

-- Road garages (road_depot.con, not the maintenance stations: they have no exit) whose entrance is joined to the streets: the
-- company's own first, else any other company's (open to the others by default, for a fee), the nearest to a point
-- (0.5.14) the road garages joined to the streets, read once for every computer company every 10 s (each look of each company
-- read every construction and the whole street map, several times: about a second of the host's frame in the first minutes, a
-- hitch every player felt). MPFEVER_AICACHE=0: read at every call, as before
local function roadGarages(E)
	local api, R = E.api, E.R
	local T = E.G.AIT or {}
	local cache = os.getenv("MPFEVER_AICACHE") ~= "0"
	if cache and T.garages and T.garagesAt and E.G.frames - T.garagesAt < 600 and E.G.frames >= T.garagesAt then return T.garages end
	local segmap = api.engine.system.streetSystem.getNode2SegmentMap()
	local list = {}
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		if c and #c.depots > 0 and tostring(c.fileName):find("road_depot", 1, true) and #c.frozenEdges > 0 then
			local vd = api.engine.getComponent(c.depots[1], api.type.ComponentType.VEHICLE_DEPOT)
			local be = api.engine.getComponent(c.frozenEdges[1], api.type.ComponentType.BASE_EDGE)
			local joined = be and (#(segmap[be.node0] or {}) > 1 or #(segmap[be.node1] or {}) > 1)
			if vd and #vd.outNodes > 0 and joined then
				local m = E.C.marshal(c.transf)
				list[#list + 1] = { con = e, depot = c.depots[1], pos = { x = m[13], y = m[14], z = m[15] }, owner = ownerOf(E, e) }
			end
		end
	end
	if cache then T.garages, T.garagesAt = list, E.G.frames end
	return list
end

local function garagesNear(E, ent, p, maxD)
	local list = {}
	-- (0.5.14: not another company's garage whose rule keeps the others out: its purchases were refused on every game, look after
	-- look. MPFEVER_AICACHE=0: as before)
	local eco = os.getenv("MPFEVER_AICACHE") ~= "0" and E.C.eco and E.C.eco() or nil
	local myId = eco and E.G.co and E.CO.idOfEntity(E.G.co, ent) or nil
	local T = E.G.AIT or {}
	for _, g in ipairs(roadGarages(E)) do
		local d = dist(g.pos, p)
		-- (a garage near enough read again: its depot id may name another depot since, freed by a bulldozer and taken by a new one)
		if d < maxD and os.getenv("MPFEVER_AICACHE") ~= "0" then
			local still = false
			pcall(function()
				local vd = E.api.engine.getComponent(g.depot, E.api.type.ComponentType.VEHICLE_DEPOT)
				still = vd ~= nil and #vd.outNodes > 0 and E.api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(g.depot) == g.con
			end)
			if not still then d = maxD; T.garagesAt = nil end
		end
		local own = g.owner == ent
		local open = true
		if d < maxD and not own and eco and myId and g.owner then
			local ownerCo = E.CO.idOfEntity(E.G.co, g.owner)
			if ownerCo then
				local okU, may = pcall(eco.depotUse, E.G.co, nil, g.depot, myId, ownerCo)
				if okU and may == false then open = false end
			end
		end
		if d < maxD and open then list[#list + 1] = { con = g.con, depot = g.depot, pos = g.pos, d = d, own = own, rank = d - (own and 100000 or 0) } end
	end
	table.sort(list, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.con < b.con end)
	return list
end

-- a depot whose lanes reach the streets (an exit node): a vehicle of a depot without one, sent to a line, stopped the simulation
local function depotLinked(E, depot)
	local ok, n = pcall(function() return #E.api.engine.getComponent(depot, E.api.type.ComponentType.VEHICLE_DEPOT).outNodes end)
	return ok and n and n > 0
end

-- (0.6.4) without its lines of trains (all: with them): the buses and trucks' rules never see them, the railways run them (RL)
local function myLines(E, ent, all)
	local api, R = E.api, E.R
	local out = {}
	for _, l in ipairs(R.entitiesWith("LINE")) do
		if ownerOf(E, l) == ent then
			local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
			local groups = {}
			for k = 1, #lc.stops do groups[#groups + 1] = lc.stops[k].stationGroup end
			if all or not (groups[1] and RL.on() and RL.isRailGroup(E, groups[1])) then out[#out + 1] = { e = l, groups = groups } end
		end
	end
	return out
end

-- (0.6.4) without its trains (see myLines)
local function myVehicles(E, ent)
	local api, R = E.api, E.R
	local out = {}
	for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
		if ownerOf(E, v) == ent then
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not (tv and RL.on() and RL.isTrain(E, tv)) then out[#out + 1] = { e = v, line = tv and tv.line or -1 } end
		end
	end
	return out
end

-- the best bus on sale this year: most seats, then the newest
local function bestBus(E)
	local api = E.api
	local year = currentYear(E)
	local best
	for id, name in pairs(api.res.modelRep.getAll()) do
		if tostring(name):find("/vehicle/bus/", 1, true) then
			local m = api.res.modelRep.get(id)
			local md = m and m.metadata
			local av = md and md.availability
			local from, to = av and av.yearFrom or 0, av and av.yearTo or 0
			if from <= year and (to == 0 or to > year) then
				local seats = 0
				-- (0.5.14: a model of one compartment only, the shape of the purchase below: one load setting; a model of more was a
				-- shape no test ever sent the engine. MPFEVER_AIMULTICOMP=1: any model, as before)
				local comps = 1
				pcall(function() comps = #md.transportVehicle.compartments end)
				if comps > 1 and os.getenv("MPFEVER_AIMULTICOMP") ~= "1" then seats = -1 end
				pcall(function()
					if seats < 0 then return end
					for _, comp in ipairs(md.transportVehicle.compartments) do
						for _, lc in ipairs(comp.loadConfigs) do seats = math.max(seats, lc.cargoEntry.capacity or 0) end
					end
				end)
				if seats > 0 and (not best or seats > best.seats or (seats == best.seats and from > best.from)) then
					best = { id = id, name = name, seats = seats, from = from }
					-- (0.6: its price on the model, for the floor, see spendOk)
					pcall(function() best.price = tonumber(md.cost.price) end)
				end
			end
		end
	end
	return best, year
end

-- ------------------------------------------------------------------ acting (as a player would, for the company)

-- a command as the interface sends it: stamped, shipped and applied by every game for the company
local function act(E, coId, fn, margs)
	local A = E.G.AI
	E.R.translateOut(fn, margs, E.G.rev)
	A.reqId = (A.reqId or 0) + 1
	E.C.appendFile(E.C.DIR .. E.BS .. "ui.log", E.C.line("act_req", { tok = "ai", id = A.reqId, fn = fn, args = margs, co = coId }))
end

-- (0.6) the floor of a company, see FLOOR: two months of its vehicles' running costs (runCost: a year's) and of its loans'
-- payments (loanMonthly: a month's), at least FLOOR_MIN, at most its reserve
local function floorOf(runCost, loanMonthly, reserve)
	local f = math.max(FLOOR_MIN, ((tonumber(runCost) or 0) / 12 + (tonumber(loanMonthly) or 0)) * 2)
	if reserve and f > reserve then f = math.max(0, reserve) end
	return f
end

-- (0.6) whether the company may spend that much now: its money read at this moment, less the cost, stays at its floor (FLOOR) or
-- above. Every purchase and build goes through it (buses, trucks, stops, garages, streets): the projects check their own reserve
-- with the money of the look's start and a price guessed before the first purchase measured one; this is the last word. A
-- refusal is logged once every 30 s. MPFEVER_AIFLOOR=0: always, as before
local function spendOk(E, co, cost, what)
	if os.getenv("MPFEVER_AIFLOOR") == "0" then return true end
	local money = balanceOf(E, co.ent)
	if money - (tonumber(cost) or 0) >= FLOOR then return true end
	local A = E.G.AI
	if E.G.frames - (A.floorSaid or -100000) > 1800 then
		A.floorSaid = E.G.frames
		L(E, string.format("%s not bought: %d less %d would leave it under its floor %d", tostring(what), math.floor(money), math.floor(tonumber(cost) or 0), math.floor(FLOOR)))
	end
	return false
end

-- An entry of the companies' journal, on every game (the MPFever window's AI tab and the chat, see the bridge's H.aijournal):
-- what (kind), where (pos, for its "Show" button), and up to two words (a name, a model). MPFEVER_AIJOURNAL=0: none.
local function journal(E, coId, kind, pos, a, b)
	if os.getenv("MPFEVER_AIJOURNAL") == "0" then return end
	local p = { t = E.gameTime(), co = coId, kind = kind, a = a, b = b }
	if pos then p.x, p.y, p.z = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor((pos.z or 0) + 0.5) end
	pcall(E.send, "aijournal", p)
	if E.H and E.H.aijournal then pcall(E.H.aijournal, E.G.me, p) end
end

-- where a depot stands (its construction's place), nil if unknown
local function depotPos(E, depot)
	local api, R = E.api, E.R
	for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
		local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		if c and #c.depots > 0 then
			for k = 1, #c.depots do
				if c.depots[k] == depot then local m = E.C.marshal(c.transf); return { x = m[13], y = m[14], z = m[15] } end
			end
		end
	end
	return nil
end

-- bits as the native module reports a tool's Context (see the replays): 1 buildings gathered, 2 terrain aligned, 4 street graph
-- cleaned up, 32 known. The depot tool builds with 39: without the clean-up the maintenance station's lanes were never linked
-- to the street (no exit node), and a bus of it sent to a line stopped the simulation of every game.
local CTX_STOP, CTX_DEPOT = 32, 39
-- (0.6) A build of a computer company never takes a town building down (the owner's rule of 2026-10-30): a context without
-- bit 1, the buildings in the way are kept and the build is refused instead (a tool's build gathers them: the street tool and
-- the depot tool take the houses in their way down and charge for them). Its streets and garages are built so (the garage's
-- replay: the act's keepBuildings, see buildGarage); its stops never gathered any (CTX_STOP). MPFEVER_AIKEEPBUILDINGS=0:
-- gathered, as before
local function keepBuildings() return os.getenv("MPFEVER_AIKEEPBUILDINGS") ~= "0" end
local function withoutBuildings(bits) return (bits % 2 == 1) and (bits - 1) or bits end

-- (0.6) the town buildings a proposal's dry run would take down or runs into (makeProposalData: collisionInfo.buildingEntities,
-- the buildings it gathers, and the colliding entities that are town buildings or their constructions); -1 when it cannot be read
local function buildingsHit(E, pd)
	local n = -1
	pcall(function()
		local api = E.api
		local ci = pd.collisionInfo
		n = #(ci.buildingEntities or {})
		for _, x in ipairs(ci.collisionEntities or {}) do
			local e = x.entity
			local hit = false
			pcall(function()
				if api.engine.getComponent(e, api.type.ComponentType.TOWN_BUILDING) then hit = true return end
				local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
				if c and #c.townBuildings > 0 then hit = true end
			end)
			if hit then n = n + 1 end
		end
	end)
	return n
end

local function context(E, ent, bits)
	local api = E.api
	local ctx = api.type.Context.new()
	bits = bits or CTX_STOP
	ctx.gatherBuildings = bits % 2 == 1
	ctx.checkTerrainAlignment = math.floor(bits / 2) % 2 == 1
	ctx.cleanupStreetGraph = math.floor(bits / 4) % 2 == 1
	ctx.gatherFields = true
	ctx.player = ent
	return ctx
end

-- a build as a tool's, for the company: held at its time, shipped with the company's number (the others build it for it)
-- (still: see deferredSend in the bridge, checked again when the build is released, 0.6.4.1)
local function build(E, coId, cmd, what, ctxBits, jr, still)
	local G = E.G
	local A = G.AI
	A.busy = { what = what, since = G.frames }
	-- (the company's number when it asked: the answer comes later, when another company may be looking, 0.5.14)
	local num = AINUM
	local seq0 = G.autoBuildSeq
	E.deferredSend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = " " .. E.C.ser(E.C.marshal(res.resultProposalData.errorState.messages)) end) end
		-- (0.6.4: refused with no message: the whole error state, and what it collided with)
		if not success and (why == "" or why == " {}") then
			pcall(function() why = why .. " " .. E.C.ser(E.C.marshal(res.resultProposalData.errorState)):sub(1, 300) end)
			pcall(function() why = why .. " collision " .. E.C.ser(E.C.marshal(res.resultProposalData.collisionInfo)):sub(1, 300) end)
		end
		E.log("AI" .. (num ~= 1 and tostring(num) or "") .. " " .. what .. ": " .. (success and "built" or ("refused" .. why)))
		A.busy = nil
		A.stopsCache = nil
		A.lastResult = { what = what, ok = success, frame = G.frames }
		if success and jr then journal(E, coId, jr.kind, jr.pos, jr.a, jr.b) end
		-- (a build this game did not take, res nil, is no refusal of the place: not counted against it)
		if not success and (res ~= nil or os.getenv("MPFEVER_AIRETRY") == "0") then A.failed = A.failed or {}; A.failed[what] = (A.failed[what] or 0) + 1 end
	end, nil, still)
	-- (a build this game did not take, during a resynchronisation or with no company here: no number of its own, nothing written
	-- for it - the number would be the previous build's, perhaps another company's, 0.5.14)
	if G.autoBuildSeq == seq0 and os.getenv("MPFEVER_AIRETRY") ~= "0" then L(E, what .. ": not taken by this game"); return end
	local id = 100000 + G.autoBuildSeq
	G.aiNatCo = G.aiNatCo or {}
	G.aiNatCo[id] = coId
	if ctxBits then G.natCtx = G.natCtx or {}; G.natCtx[id] = ctxBits end
end

-- a stop on a town street segment, as the stop tool builds it (see H.dstop): the segment replaced by a copy carrying the stop
local function buildStop(E, co, seg, n)
	local api, C, G = E.api, E.C, E.G
	-- (0.6: never under the floor, see spendOk; a stop of 1972 costs 30 000 to 60 000. False: not built)
	if not spendOk(E, co, 60000, "stop " .. tostring(n)) then return false end
	local c = api.engine.getComponent(seg, api.type.ComponentType.BASE_EDGE)
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = 0
	local cc = e.comp
	cc.node0 = c.node0; cc.node1 = c.node1
	cc.tangent0 = E.vec(c.tangent0); cc.tangent1 = E.vec(c.tangent1)
	if G.autoSegEnds then cc.position0, cc.position1 = G.autoSegEnds(c) end
	cc.type = c.type; cc.typeIndex = c.typeIndex
	cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
	cc.laneConfigs = c.laneConfigs
	cc.objects = { { -400000000, 1 } }
	e.comp = cc
	local owner = ownerOf(E, seg)
	if type(owner) == "number" and owner >= 0 then
		pcall(function() local po = C.newOf("PlayerOwned"); po.player = owner; e.playerOwned = po end)
	end
	local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
	local eo = api.type.SimpleStreetProposal.EdgeObject.new()
	eo.edgeEntity = -1
	eo.param = 0.5
	eo.oneWay = false
	eo.left = false
	eo.model = STOP_MODEL
	eo.playerEntity = co.ent
	eo.name = ""
	ssp.edgesToRemove = { seg }
	ssp.edgesToAdd = { e }
	ssp.edgeObjectsToAdd = { eo }
	local ncr = {}
	for _, nd in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = nd end
	end
	if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
	sp.streetProposal = ssp
	local cmd = api.cmd.makeWorldBuildProposalCmd(sp, context(E, co.ent, CTX_STOP), false, true, true)
	local pa, pb = E.nodePosition(c.node0), E.nodePosition(c.node1)
	-- (0.6.4.1: the segment as it was when this build was made: the same ends and still no stop, else not sent, see deferredSend.
	-- A stop built on a segment another stop had just replaced stopped the host's game, test o2 of 2026-10-31)
	local n0, n1 = c.node0, c.node1
	local function still()
		local c2 = api.engine.getComponent(seg, api.type.ComponentType.BASE_EDGE)
		if not c2 then return "segment " .. seg .. " no longer exists" end
		if c2.node0 ~= n0 or c2.node1 ~= n1 then return "segment " .. seg .. " is another segment now" end
		if #c2.objects > 0 then return "segment " .. seg .. " carries " .. #c2.objects .. " object(s) now" end
		return true
	end
	L(E, "stop " .. tostring(n) .. " on segment " .. seg)
	build(E, co.id, cmd, "stop " .. n, CTX_STOP, { kind = "stop", pos = pa and pb and { x = (pa.x + pb.x) / 2, y = (pa.y + pb.y) / 2, z = (pa.z + pb.z) / 2 } or nil }, still)
	return true
end

-- free town street segments near a point, the nearest first
local function streetSegmentsNear(E, p, radius, avoid)
	local api, R = E.api, E.R
	local list = {}
	-- (0.5.14) the free town segments read once for every computer company every 10 s, like the garages (see roadGarages); each one
	-- found is checked again here (still there, still free: a segment a build replaced since must not get a stop).
	-- MPFEVER_AICACHE=0: every segment read at every call, as before
	local T = E.G.AIT or {}
	-- (0.6, F5) every place found serves a stop, a depot or a garage: none in a player's territory (see territoryCheck)
	local terr = territoryCheck(E)
	if os.getenv("MPFEVER_AICACHE") ~= "0" then
		if not (T.segs and T.segsAt and E.G.frames - T.segsAt < 600 and E.G.frames >= T.segsAt) then
			local all = {}
			for _, e in ipairs(R.allEdges()) do
				local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if c and c.type == 0 and #c.objects == 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET)
					and tostring(c.roadTemplate):find("/town/", 1, true) then
					local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
					if not (okC and type(con) == "number" and con >= 0) then
						local a, b = E.nodePosition(c.node0), E.nodePosition(c.node1)
						if a and b then
							local len = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
							if len > 40 and len < 160 then all[#all + 1] = { e = e, a = a, b = b, m = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 } } end
						end
					end
				end
			end
			T.segs, T.segsAt = all, E.G.frames
		end
		for _, s in ipairs(T.segs) do
			local d = dist(s.m, p)
			local ok = d < radius
			if ok then for _, q in ipairs(avoid or {}) do if dist(s.m, q) < 120 then ok = false; break end end end
			if ok and terr and terr(s.m.x, s.m.y) then ok = false end
			if ok then
				-- (read again as the uncached path reads it: an id freed by a build may name another segment now, the half of a
				-- segment cut by another company's garage. The ends taken from now; anything that differs drops the cache)
				local good = false
				pcall(function()
					local c = api.engine.getComponent(s.e, api.type.ComponentType.BASE_EDGE)
					if not (c and c.type == 0 and #c.objects == 0 and api.engine.getComponent(s.e, api.type.ComponentType.BASE_EDGE_STREET)
						and tostring(c.roadTemplate):find("/town/", 1, true)) then return end
					local con = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(s.e)
					if type(con) == "number" and con >= 0 then return end
					local a, b = E.nodePosition(c.node0), E.nodePosition(c.node1)
					if not (a and b) or dist(a, s.a) > 0.5 or dist(b, s.b) > 0.5 then return end
					good = true
				end)
				if good then list[#list + 1] = { e = s.e, d = d, a = s.a, b = s.b, m = s.m } else T.segsAt = nil end
			end
		end
		table.sort(list, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.e < y.e end)
		return list
	end
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and #c.objects == 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET)
			and tostring(c.roadTemplate):find("/town/", 1, true) then
			local okC, con = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
			if not (okC and type(con) == "number" and con >= 0) then
				local a, b = E.nodePosition(c.node0), E.nodePosition(c.node1)
				if a and b then
					local len = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
					local m = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
					local d = dist(m, p)
					local ok = len > 40 and len < 160 and d < radius
					for _, q in ipairs(avoid or {}) do if dist(m, q) < 120 then ok = false end end
					if ok and terr and terr(m.x, m.y) then ok = false end
					if ok then list[#list + 1] = { e = e, d = d, a = a, b = b, m = m } end
				end
			end
		end
	end
	table.sort(list, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.e < y.e end)
	return list
end

-- a maintenance station against a street near a point: the first place the engine finds free (dry runs)
local function findDepotPlace(E, co, p)
	local api = E.api
	local V = api.type.Vec4f.new
	local tried = 0
	-- (0.6, F5: the station itself out of a player's territory too, its street may be at the circle's edge)
	local terr = territoryCheck(E)
	for _, s in ipairs(streetSegmentsNear(E, p, 700, {})) do
		if tried > 400 then break end
		local dx, dy = s.b.x - s.a.x, s.b.y - s.a.y
		local len = math.sqrt(dx * dx + dy * dy)
		dx, dy = dx / len, dy / len
		for _, side in ipairs({ 1, -1 }) do
			tried = tried + 1
			local nx, ny = -dy * side, dx * side
			local off = 23
			local m = { x = s.m.x + nx * off, y = s.m.y + ny * off }
			m.z = E.groundZ(m.x, m.y, s.m.z)
			local sp = api.type.SimpleProposal.new()
			local ce = api.type.SimpleProposal.ConstructionEntity.new()
			ce.fileName = DEPOT_FILE
			ce.params = { seed = 1, year = currentYear(E), modules = {} }
			ce.transf = api.type.Mat4f.new(V(ny, -nx, 0, 0), V(nx, ny, 0, 0), V(0, 0, 1, 0), V(m.x, m.y, m.z, 1))
			ce.playerEntity = co.ent
			pcall(function() ce.name = "" end)
			sp.constructionsToAdd = { ce }
			-- (0.6, dev probes only: the dry run without the buildings gathered, see keepBuildings, a house in the way is a refusal)
			local bits = keepBuildings() and withoutBuildings(CTX_DEPOT) or CTX_DEPOT
			local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(sp, context(E, co.ent, bits)) end)
			if okd and pd and #pd.errorState.messages == 0 and not pd.errorState.critical and not (keepBuildings() and buildingsHit(E, pd) > 0)
				and not (terr and terr(m.x, m.y)) then
				return sp, s, pd.costs
			end
		end
	end
	return nil
end

-- ------------------------------------------------------------------ a garage, as the depot tool builds it

-- The depot tool's build of a road garage (road_depot.con), as MPFever captures it from a player (and every game replays it,
-- see replayNativeConstruction in the bridge): the town street split at the junction, the garage's entrance stretched from the
-- street's axis to the garage (42 m in front of the construction's origin, its own entrance ends at 35), the entrance's inner
-- node frozen to the construction. A script's proposal of the garage alone was never joined to the streets ("Construction
-- impossible" at a street node; no exit when left apart). Sent as a native act that every game, this one too, replays at its
-- time, as a player's garage is replayed.
local GARAGE_FILE = "::/depots/road/road_depot/road_depot.con"
local ENTRANCE_TPL = "::/infrastructure/street/constructions/entrance_new.street_template"

local function v3(p) return { x = p.x, y = p.y, z = p.z, __vec = true } end

-- straight town street segments near a point where a garage stands free (a dry run of the garage alone, its footprint)
local function garagePlaces(E, co, p, maxD)
	local api, C, R = E.api, E.C, E.R
	local V = api.type.Vec4f.new
	local out = {}
	local tried = 0
	-- (0.6, F5: the garage itself out of a player's territory too, 42 m from its street)
	local terr = territoryCheck(E)
	for _, s in ipairs(streetSegmentsNear(E, p, maxD, {})) do
		if tried > 60 or #out >= 1 then break end
		local c = api.engine.getComponent(s.e, api.type.ComponentType.BASE_EDGE)
		local len = math.sqrt((s.b.x - s.a.x) ^ 2 + (s.b.y - s.a.y) ^ 2)
		local t0 = c.tangent0
		local tl = math.sqrt(t0.x ^ 2 + t0.y ^ 2)
		local straight = tl > 0 and math.abs((t0.x * (s.b.x - s.a.x) + t0.y * (s.b.y - s.a.y)) / (tl * len)) > 0.995
		if straight and len > 50 then
			local dx, dy = (s.b.x - s.a.x) / len, (s.b.y - s.a.y) / len
			for _, side in ipairs({ 1, -1 }) do
				tried = tried + 1
				local nx, ny = -dy * side, dx * side
				local P = { x = (s.a.x + s.b.x) / 2, y = (s.a.y + s.b.y) / 2, z = (s.a.z + s.b.z) / 2 }
				local O = { x = P.x + nx * 42, y = P.y + ny * 42, z = P.z }
				-- (only on level ground: the garage, its entrance and the street end within 3 m of height, see freight's garages)
				local lo, hi = P.z, P.z
				for _, q in ipairs({ { 42, 0 }, { 21, 0 }, { 60, 0 }, { 42, 15 }, { 42, -15 }, { 60, 15 }, { 60, -15 } }) do
					local x, y = P.x + nx * q[1] + dx * q[2], P.y + ny * q[1] + dy * q[2]
					local z = E.groundZ(x, y, P.z)
					if z < lo then lo = z end
					if z > hi then hi = z end
				end
				local level = hi - lo <= 3 and not (terr and terr(O.x, O.y))
				local sp = api.type.SimpleProposal.new()
				local ce = api.type.SimpleProposal.ConstructionEntity.new()
				ce.fileName = GARAGE_FILE
				ce.params = { seed = 0, year = currentYear(E), modules = {} }
				ce.transf = api.type.Mat4f.new(V(ny, -nx, 0, 0), V(nx, ny, 0, 0), V(0, 0, 1, 0), V(O.x, O.y, O.z, 1))
				ce.playerEntity = co.ent
				pcall(function() ce.name = "" end)
				sp.constructionsToAdd = { ce }
				local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(sp, context(E, co.ent, CTX_STOP)) end)
				-- (its entrance touches the street it joins: a collision with that segment only is no obstacle, the tool's build
				-- replaces that segment)
				local free = level and okd and pd and not pd.errorState.critical
				if free and #pd.errorState.messages > 0 then
					local only = true
					pcall(function()
						for _, x in ipairs(pd.collisionInfo.collisionEntities) do
							if x.entity ~= s.e and x.entity ~= c.node0 and x.entity ~= c.node1 then only = false end
						end
						for _, msg in ipairs(pd.errorState.messages) do if msg ~= "Collision" then only = false end end
					end)
					free = only
				end
				if free then
					out[#out + 1] = { seg = s.e, c = c, a = s.a, b = s.b, P = P, O = O, n = { x = nx, y = ny }, side = side }
					-- (0.6: the garage's price as the dry run says it, for the floor, see buildGarage)
					pcall(function() out[#out].cost = tonumber(pd.costs) end)
					break
				end
			end
		end
	end
	return out
end

local function marshalSeg(E, entity, comp, n0, n1, p0, p1, tpl, lanes, owner, locked)
	local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z, __vec = true }
	return {
		entity = entity, type = 0,
		params = { precedenceNode0 = 2, precedenceNode1 = 2, __ud = true },
		streetEdge = { precedenceNode0 = 2, precedenceNode1 = 2, __ud = true },
		playerOwned = owner and { player = owner, __ud = true } or nil,
		comp = { type = 0, typeIndex = -1, node0 = n0, node1 = n1, position0 = v3(p0), position1 = v3(p1), tangent0 = t, tangent1 = t,
			roadTemplate = tpl, roadStyle = comp and comp.roadStyle or nil, roadType = comp and comp.roadType or 1, laneConfigs = lanes,
			edgeDecorations = {}, distance = 0, objects = {}, roadDevelopmentLocked = locked or false, __ud = true },
		__ud = true,
	}
end

local function garageCapture(E, co, place)
	local api, C, G = E.api, E.C, E.G
	local c = place.c
	local P, O, n = place.P, place.O, place.n
	local M = { x = P.x + n.x * 21.74, y = P.y + n.y * 21.74, z = P.z }
	local cm = C.marshal(c)
	local townLanes = cm.laneConfigs
	local entLanes = C.marshal(C.templateLanes(ENTRANCE_TPL)) or townLanes
	local addedSegments = {
		-- (the entrance takes the street's style, as in the tool's build: without one the engine threw on the command)
		marshalSeg(E, -3, { roadStyle = cm.roadStyle, roadType = cm.roadType }, -1, -2, P, M, ENTRANCE_TPL, entLanes, co.ent, true),
		marshalSeg(E, -4, cm, c.node0, -1, place.a, P, c.roadTemplate, townLanes, nil, false),
		marshalSeg(E, -5, cm, -1, c.node1, P, place.b, c.roadTemplate, townLanes, nil, false),
	}
	local ncr = {}
	for _, nd in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = nd end
	end
	local m = {
		toAdd = { { name = "", params = { seed = 0, year = currentYear(E), modules = {} }, fileName = GARAGE_FILE, segmentsBefore = 0,
			transf = { n.y, -n.x, 0, 0, n.x, n.y, 0, 0, 0, 0, 1, 0, O.x, O.y, O.z, 1, __mat = true }, playerEntity = co.ent, frozenNodes = { 1 } } },
		toRemove = {}, old2new = {}, old2newByRank = {},
		proposal = {
			addedNodes = { { entity = -1, comp = { position = v3(P), __ud = true }, __ud = true }, { entity = -2, comp = { position = v3(M), __ud = true }, __ud = true } },
			addedSegments = addedSegments,
			removedSegments = { { entity = place.seg, type = 0, comp = cm, params = { precedenceNode0 = 2, precedenceNode1 = 2, __ud = true },
				streetEdge = { precedenceNode0 = 2, precedenceNode1 = 2, __ud = true }, __ud = true } },
			removedNodes = {}, nodeConfigsToAdd = {}, nodeConfigsToRemove = ncr, edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
		},
	}
	local margs = { n = 4, [1] = m, [2] = { __player = true }, [3] = false, [4] = true }
	E.R.translateOut("makeWorldBuildProposalCmd", margs, G.rev)
	return margs
end

local function buildGarage(E, co, place)
	local G = E.G
	local A = G.AI
	-- (0.6: never under the floor, see spendOk: the dry run's price of the garage, 650 000 when unknown, and its entrance.
	-- False: not built)
	if not spendOk(E, co, (tonumber(place.cost) or 650000) + 20000, "garage on segment " .. tostring(place.seg)) then return false end
	local margs = garageCapture(E, co, place)
	local now = E.gameTime()
	G.oseq = G.oseq + 1
	local a = { fn = "makeWorldBuildProposalCmd", args = margs, origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
		at = E.stampFor(now) + E.STEP, native = true, co = co.id, ctx = CTX_DEPOT }
	-- (0.6) never a town building taken down for it: every game replays the garage with the buildings in its way kept (a building
	-- there makes the build fail everywhere instead of being demolished; the depot tool of a player gathers them, see the bridge's
	-- replayNativeConstruction). Its place was chosen free of buildings (garagePlaces); this covers a building grown there since.
	-- MPFEVER_AIKEEPBUILDINGS=0: gathered, as before
	if os.getenv("MPFEVER_AIKEEPBUILDINGS") ~= "0" then a.keepBuildings = true end
	E.send("act", a)
	a.recvFrame = G.frames
	G.nativeQueue[#G.nativeQueue + 1] = a
	A.busy = { what = "garage on segment " .. place.seg, since = G.frames, until_ = G.frames + 600 }
	L(E, "garage requested on segment " .. place.seg .. " (" .. a.uid .. ", for t=" .. a.at .. ")")
	journal(E, co.id, "garage", place.O)
end

-- ------------------------------------------------------------------ the plan

-- the stops a town project wants: near its residential, commercial and industrial centres
local USES = { "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }

-- Where a town's line stops: its residential, commercial and industrial centres, at least 300 m apart; when they are fewer than
-- two, the farthest point of the town's streets from the first (a company stop already there first, so that the choice stays the
-- same once built)
local function townTargets(E, town, stops, rich)
	local api = E.api
	local pts = {}
	for _, u in ipairs(USES) do
		local p = centre(E, town, api.type.enum.LandUseType[u])
		if p then
			local dup = false
			for _, q in ipairs(pts) do if dist(p, q.p) < 300 then dup = true end end
			if not dup then pts[#pts + 1] = { use = u, p = p } end
		end
	end
	-- (a town's own line: also a ring of points 450 m around its residential centre where the town has streets, so that the line
	-- crosses the town as the players' well filled lines do; then the points chained, each to the nearest one left)
	if rich and pts[1] then
		local c = pts[1].p
		for k = 0, 5 do
			local a = k * math.pi / 3
			local q = { x = c.x + math.cos(a) * 450, y = c.y + math.sin(a) * 450, z = c.z }
			local near = streetSegmentsNear(E, q, 150, {})[1]
			if near then
				local dup = false
				for _, o in ipairs(pts) do if dist(near.m, o.p) < 300 then dup = true end end
				if not dup then pts[#pts + 1] = { use = "RING" .. k, p = near.m } end
			end
		end
		-- (chained from the point farthest from the centre)
		local start, sd = 1, -1
		for i, o in ipairs(pts) do local d = dist(o.p, c); if d > sd then start, sd = i, d end end
		local chain, left = { table.remove(pts, start) }, pts
		while #left > 0 do
			local last = chain[#chain].p
			local bi, bd = 1, nil
			for i, o in ipairs(left) do local d = dist(o.p, last); if not bd or d < bd then bi, bd = i, d end end
			chain[#chain + 1] = table.remove(left, bi)
		end
		return chain
	end
	if #pts == 1 then
		local first = pts[1].p
		local far
		for _, s in ipairs(stops) do
			local d = dist(s.pos, first)
			if d > 350 and d < 800 and (not far or d > far.d) then far = { p = s.pos, d = d } end
		end
		if not far then
			for _, s in ipairs(streetSegmentsNear(E, first, 750, {})) do
				if s.d > 400 and (not far or s.d > far.d) then far = { p = s.m, d = s.d } end
			end
		end
		if far then pts[#pts + 1] = { use = "EDGE", p = far.p } end
	end
	return pts
end

local function townProject(E, co, town, stops)
	local want = {}
	local A = E.G.AI
	local drop = A.dropPoint or {}
	-- (computed once: a point moves once a stop takes its street segment, and the line would follow a moving target)
	A.targets = A.targets or {}
	A.targets[town] = A.targets[town] or townTargets(E, town, stops, true)
	for _, w in ipairs(A.targets[town]) do if not drop[town .. ":" .. w.use] then want[#want + 1] = w end end
	-- a wanted stop is there when one of the company's stops stands within 200 m of its point; one stop serves one point only
	local have, missing, used = {}, {}, {}
	for _, w in ipairs(want) do
		local found, fd
		for _, s in ipairs(stops) do
			local d = dist(s.pos, w.p)
			if d < 200 and not used[s.group] and (not fd or d < fd) then found, fd = s, d end
		end
		if found then used[found.group] = true; have[#have + 1] = { want = w, stop = found } else missing[#missing + 1] = w end
	end
	return have, missing, want
end

local function lineFor(E, lines, groups)
	for _, l in ipairs(lines) do
		local all = true
		for _, g in ipairs(groups) do
			local f = false
			for _, x in ipairs(l.groups) do if x == g then f = true end end
			if not f then all = false end
		end
		if all then return l end
	end
	return nil
end

local function createLine(E, co, groups, town, name)
	local api, C, R = E.api, E.C, E.R
	-- (a bus line of the savegame as the template of the line's fields, its stops replaced)
	local template
	for _, l in ipairs(R.entitiesWith("LINE")) do
		local m = C.marshal(api.engine.getComponent(l, api.type.ComponentType.LINE))
		if m and m.vehicleInfo and m.vehicleInfo.transportModes and m.vehicleInfo.transportModes[3] == true then template = m break end
	end
	if not template then
		local ln = api.type.Line.new()
		template = C.marshal(ln)
	end
	local stop0 = template.stops and template.stops[1]
	-- (0.5.14: the loading mode and waiting times of a new stop, not the savegame line's: a full load or a long wait there held the
	-- company's buses at every stop. Its cargo settings stay the line's: a new stop's load nothing. MPFEVER_AISTOPTPL=0: as before)
	if stop0 and os.getenv("MPFEVER_AISTOPTPL") ~= "0" then
		local fresh = nil
		pcall(function() fresh = C.marshal(api.type.Line.Stop.new()) end)
		if type(fresh) == "table" then
			local s0 = {}
			for k, v in pairs(stop0) do s0[k] = v end
			for _, k in ipairs({ "loadMode", "minWaitingTime", "maxWaitingTime" }) do if fresh[k] ~= nil then s0[k] = fresh[k] end end
			stop0 = s0
		end
	end
	local stops = {}
	-- there and back: A B C B
	local order = {}
	for i = 1, #groups do order[#order + 1] = groups[i] end
	for i = #groups - 1, 2, -1 do order[#order + 1] = groups[i] end
	for i, g in ipairs(order) do
		local s = {}
		if stop0 then for k, v in pairs(stop0) do s[k] = v end end
		s.stationGroup = g
		s.station = 0
		s.terminal = 0
		-- (the group's other stations and terminals as alternatives: the engine takes the one on the bus's side of the street)
		local alt = {}
		pcall(function()
			local sg = api.engine.getComponent(g, api.type.ComponentType.STATION_GROUP)
			for k = 1, #sg.stations do
				local sc = api.engine.getComponent(sg.stations[k], api.type.ComponentType.STATION)
				for t = 1, #sc.terminals do
					if not (k == 1 and t == 1) then alt[#alt + 1] = { station = k - 1, terminal = t - 1, __ud = true } end
				end
			end
		end)
		s.alternativeTerminals = alt
		s.waypoints = {}
		s.__ud = true
		stops[i] = s
	end
	template.stops = stops
	name = name or (AINAME .. " " .. townName(E, town))
	act(E, co.id, "makeLineCreateCmd", { n = 4, [1] = name, [2] = C.marshal(api.type.Vec3f.new(0.2, 0.5, 0.9)), [3] = co.ent, [4] = template })
	-- (its growth waits until this line had time to fill, see mayExpand)
	E.G.AI.lastNewAt = E.gameTime()
	local jpos = centre(E, town, E.api.type.enum.LandUseType.RESIDENTIAL)
	E.G.AI.busy = { what = "line " .. name, since = E.G.frames, linesBefore = #myLines(E, co.ent), jr = { kind = "line", pos = jpos, a = name } }
	L(E, "line requested: " .. name .. " with " .. #order .. " stops")
end

local function buyBus(E, co, depot)
	local bus, year = bestBus(E)
	if not bus then L(E, "no bus on sale in " .. year); return false end
	-- (0.6: never under the floor, see spendOk; the price the last purchase measured, or the model's when higher)
	if not spendOk(E, co, math.max(E.G.AI.busCost or BUS_COST, bus.price or 0), "bus " .. tostring(bus.name)) then return false end
	local cfg = {
		vehicles = { { part = { modelId = bus.id, reversed = false, compartment2loadConfig = { { loadConfigIndex = 0, cargoTypeId = 0, __ud = true } },
			color = { x = -1, y = -1, z = -1, __vec = true }, __ud = true }, purchaseTime = 0, maintenanceChange = 0, maintenanceState = 1,
			autoLoadConfig = { true }, __ud = true } },
		vehicleGroups = { 1 }, muFileNames = {}, __ud = true }
	-- (0.5.14: the fleet of the line it is for changes now, see manageLines' settled)
	do local A0 = E.G.AI; if A0.forLine then A0.changedAt = A0.changedAt or {}; A0.changedAt[A0.forLine] = E.gameTime() end end
	act(E, co.id, "makeVehicleBuyCmd", { n = 3, [1] = co.ent, [2] = depot, [3] = cfg })
	E.G.AI.busy = { what = "bus " .. bus.name, since = E.G.frames, vehBefore = #myVehicles(E, co.ent), moneyBefore = balanceOf(E, co.ent),
		jr = { kind = "bus", pos = depotPos(E, depot), a = tostring(bus.name):match("([^/]+)%.mdl$") or bus.name } }
	L(E, "bus requested: " .. bus.name .. " (" .. bus.seats .. " seats, " .. year .. ") at depot " .. depot)
	return true
end

-- ------------------------------------------------------------------ long-term freight (0.6): the rules
-- In 1972 an industry makes 50 to 270 units a year until its cargo is carried, and no freight line of the tests of 2026-10-29
-- paid its truck (160 000 a year). An industry grows only with what is shipped from it: the game's industries script
-- (game_mechanics/industries) tries every half game year to extend each industry, with a chance that goes from 0 to 1 as its
-- production rating times the share of its output shipped goes from 0.25 to 0.75, one level more each time up to its most, and
-- its production grows with its level. So a freight line is an investment: one at a time, a line from a raw producer that can
-- still grow to an industry that takes its cargo (or, once the company feeds a processing industry, from that industry to one
-- that takes its product), whose loss is accepted within a budget (LT.share of the company's money to spare, at most LT.cap) and
-- a time (LT.horizonY game years), judged on its trend (its producer's production and its result over the last months, LT.proofY
-- after its start) rather than on one month, never under the company's floor. Once it pays its trucks it is a line like the
-- others and the next one can start; after a line given up the next one waits LT.cooldownY, longer each time (see ltEnd).
-- Its first trucks come as any freight line's (see step), and it starts only while the company may grow. MPFEVER_AILONGFREIGHT=0: none, as in
-- 0.5.14 (freight only with plenty of money). MPFEVER_AILTTREND=0: judged on its budget and time only; MPFEVER_AILTTRUCKS=0: its
-- trucks as any line's (no truck more for the cargo waiting); MPFEVER_AILTCHAIN=0: raw producers only
local LT = { share = 0.2, cap = 1500000, min = 300000, horizonY = 3, proofY = 1, grow = 1.25, cooldownY = 0.5, maxTrucks = 4, sample = 240000, keep = 8 }

local function ltOn() return os.getenv("MPFEVER_AILONGFREIGHT") ~= "0" and os.getenv("MPFEVER_AIFREIGHT") ~= "0" end

local function yearOf(E)
	local y = 1461000
	pcall(function() local v = E.api.util.getDefaultYearDuration(); if type(v) == "number" and v > 0 then y = v end end)
	return y
end

-- the budget of a new long-term line: LT.share of the money to spare (its money less its loans' money), at most LT.cap; nil
-- while under LT.min (not affordable yet)
local function ltBudget(spare)
	local b = math.min(LT.cap, LT.share * math.max(0, tonumber(spare) or 0))
	if b < LT.min then return nil end
	return math.floor(b)
end

-- The verdict on a long-term line at a sample (pure, see tests/test_ai_longfreight.py): "paid" once its income covered its
-- trucks' running costs two samples in a row (a line like the others then), "end" when its budget is spent or its time is up, or
-- (trend) when its proof time is over and neither its producer's production grew by LT.grow nor its result over the last four
-- months got better than over its first four; else "keep".
-- lt = { born, budget, spent, prod0, proofFrom, samples = { { t, bal, prod, ratio }... } }; P = { horizon, proof, grow } (ms)
local function ltJudge(lt, now, P, trend)
	local s = lt.samples or {}
	local n = #s
	if n >= 2 and (s[n].ratio or 0) >= 1 and (s[n - 1].ratio or 0) >= 1 then return "paid", "it pays its trucks" end
	if (lt.spent or 0) >= (lt.budget or 0) then return "end", "its budget is spent" end
	if now - (lt.born or now) >= P.horizon then return "end", "its time is up" end
	if trend and n >= 1 and now - (lt.proofFrom or lt.born or now) >= P.proof then
		local grew = (s[n].prod or 0) >= math.max(1, tonumber(lt.prod0) or 0) * P.grow
		local better = false
		if n >= 4 then
			local first, last = (s[1].bal or 0) + (s[2].bal or 0), (s[n].bal or 0) + (s[n - 1].bal or 0)
			better = last > first + 0.2 * math.abs(first)
		end
		if not grew and not better then return "end", "its producer does not grow and its result gets no better" end
	end
	return "keep"
end

-- A long-term line's investment ends (its budget, its time, no growth, the floor): the fleet rules take it from now on, its route
-- is not tried again as a long-term line, and the next one waits LT.cooldownY, twice as long after each one given up (at most 8
-- times: the company does not throw a share of its money away every half year)
local function ltEnd(A, lt, why, now, yearMs)
	lt.state, lt.why = "ended", why
	A.ltFailed = A.ltFailed or {}; A.ltFailed[lt.key or ""] = true
	A.ltFails = (A.ltFails or 0) + 1
	A.ltNextAt = now + LT.cooldownY * yearMs * 2 ^ math.min(3, A.ltFails - 1)
end

-- a long-term line in its investment (its loss accepted, see above): not judged by the fleet rules, not sold in debt before the
-- other lines, not counted against the company's growth
local function ltProtected(E, line)
	if not ltOn() then return false end
	local t = E.G.AI.lt
	local lt = t and t[line]
	return lt ~= nil and lt.state == "invest"
end

-- ------------------------------------------------------------------ running the lines

-- passengers' share of the line's seats in use (nil if unknown)
local function lineUse(E, line)
	local ok, u = pcall(function() return E.api.engine.util.line.getLineCapacityUsages(line, false) end)
	if not ok or type(u) ~= "table" then return nil end
	local used, total = 0, 0
	for _, x in pairs(u) do used = used + (x.used or 0); total = total + (x.capacity or x.total or 0) end
	if total <= 0 then return nil end
	return used / total
end

-- a line's earnings less its upkeep over the last two game months (4000 ms of game time a day), nil if unknown
local function lineBalance(E, line)
	local now = E.gameTime()
	local ok, b = pcall(function() return E.api.engine.util.finance.calculateBalance({ line }, now - 240000, now, true) end)
	return ok and type(b) == "number" and b or nil
end

-- The result of the company's lines together over the last two months (earnings less upkeep), read at most every 10 s; nil
-- when no line has one yet. (0.6: tag, another list's result kept apart: the lines without the long-term ones, see mayExpand)
local function companyResult(E, lines, tag)
	local A = E.G.AI
	if tag then
		A.opTag = A.opTag or {}
		local c = A.opTag[tag]
		if c and E.G.frames - c.at < 600 then return c.r end
		local sum, known = 0, 0
		for _, l in ipairs(lines) do
			local b = lineBalance(E, l.e)
			if b then sum = sum + b; known = known + 1 end
		end
		A.opTag[tag] = { at = E.G.frames, r = known > 0 and sum or nil }
		return A.opTag[tag].r
	end
	if A.opAt and E.G.frames - A.opAt < 600 then return A.opResult end
	A.opAt = E.G.frames
	local sum, known = 0, 0
	for _, l in ipairs(lines) do
		local b = lineBalance(E, l.e)
		if b then sum = sum + b; known = known + 1 end
	end
	A.opResult = known > 0 and sum or nil
	return A.opResult
end

-- (0.5.14) The company's loans as the simulation books them (the registry's copy here, G.co.loan, as the bridge keeps it): how
-- many, what is still owed and what they cost a month (amount / months, plus the interest). 0 when it has none or they cannot be read
local function loanBook(E, co)
	local n, owe, monthly = 0, 0, 0
	pcall(function()
		local lt = E.G.co and E.G.co.loan and E.G.co.loan[co.id]
		local month = E.api.util.getDefaultMonthDuration()
		for _, l in ipairs(lt and lt.obtainedLoans or {}) do
			local months = math.max(1, math.floor((tonumber(l.duration) or 0) / month + 0.5))
			local per = (tonumber(l.amount) or 0) / months
			n = n + 1
			owe = owe + math.max(0, (tonumber(l.amount) or 0) - (tonumber(l.timesPaid) or 0) * per)
			monthly = monthly + per * (1 + (tonumber(l.percentage) or 0))
		end
	end)
	return n, owe, monthly
end

-- (0.5.14) Whether the company may open something new (stops, a line, a garage for a new line): its first lines freely (the
-- level's bootstrap); then not before its last new line had time to fill (settle, game time), and only while its lines earn
-- together or it holds plenty of money besides its reserve (freeCash). The tests of 2026-10-29: three companies opened 6 to 10
-- lines in minutes with their 2 million, ran into debt, sold every vehicle and ended at -1.6 million. Vehicles for its lines
-- that are full are not held back. MPFEVER_AIGOVERN=0: as before.
local function mayExpand(E, co, lines, money)
	if os.getenv("MPFEVER_AIGOVERN") == "0" then return true end
	local A = E.G.AI
	local now = E.gameTime()
	local why
	-- (0.6) nothing new while its money is under its reserve, its first lines included: it keeps itself solvent (see manageLines).
	-- MPFEVER_AISOLVENT=0: as before
	if os.getenv("MPFEVER_AISOLVENT") ~= "0" and money < RESERVE then why = "its money is under its reserve (" .. math.floor(money) .. " for " .. math.floor(RESERVE) .. ")" end
	-- (0.6) its long-term freight line in its investment is neither a line still filling nor part of its lines' result: its loss is
	-- planned and budgeted (see ltJudge), it must not hold the growth of the others for years
	local others = lines
	if ltOn() and A.lt then
		others = {}
		for _, l in ipairs(lines) do if not ltProtected(E, l.e) then others[#others + 1] = l end end
	end
	-- (its first lines, the level's bootstrap, freely; then not before its last new line had time to fill, and with plenty of
	-- money besides its reserve and its loans whatever its lines do; else not while the level's number of its lines are still
	-- filling or about to be given up, and only while its lines earn together)
	if not why and #lines >= (LV.bootstrap or 0) then
		local spare = money - (A.loanCash or 0)
		if A.lastNewAt and A.lastNewAt <= now and now - A.lastNewAt < (LV.settle or 0) then
			why = "its last new line fills (" .. math.floor((LV.settle - (now - A.lastNewAt)) / 4000) .. " day(s) left)"
		elseif spare < RESERVE + (LV.freeCash or 0) then
			local unproven = 0
			local fleetOn = os.getenv("MPFEVER_AIFLEET") ~= "0"
			for _, l in ipairs(others) do
				local born = A.born and A.born[l.e]
				-- (a line with no measure yet, no vehicle or MPFEVER_AIFLEET=0, by its age only; a measured one while under the level's
				-- give-up share, which the fleet rules end: one paying a little less than its vehicles no longer holds growth for good)
				local r = A.ratio and A.ratio[l.e]
				if (born and born <= now and now - born < (LV.ramp or 0)) or (fleetOn and r ~= nil and r < (LV.giveUp or 0.5)) then unproven = unproven + 1 end
			end
			if unproven >= (LV.maxUnproven or 99) then
				why = unproven .. " line(s) still filling or about to be given up"
			else
				local r = (others == lines) and companyResult(E, lines) or companyResult(E, others, "grow")
				if r == nil or r <= 0 then why = "its lines do not earn yet (" .. tostring(r and math.floor(r)) .. " over 2 months)" end
			end
		end
	end
	if why then
		if E.G.frames - (A.waitSaid or -100000) > 3600 then A.waitSaid = E.G.frames; L(E, "growth waits: " .. why) end
		return false
	end
	return true
end

-- the seats in use, sampled every 20 s: the mean of the last 6 samples (one look at a bus in a terminus said 2 %, the next 33 %)
local function sampleUse(E, lines)
	local G = E.G
	local A = G.AI
	if G.frames - (A.sampleAt or -100000) < 1200 then return end
	A.sampleAt = G.frames
	A.useHist = A.useHist or {}
	for _, l in ipairs(lines) do
		local h = A.useHist[l.e] or {}
		local u = lineUse(E, l.e)
		if u then h[#h + 1] = u; while #h > 6 do table.remove(h, 1) end end
		A.useHist[l.e] = h
	end
end

local function meanUse(E, line)
	local h = (E.G.AI.useHist or {})[line]
	if not h or #h == 0 then return nil end
	local s = 0
	for _, u in ipairs(h) do s = s + u end
	return s / #h
end

-- the company's lines the engine reports a problem for (a stop no vehicle reaches...)
local function problemLines(E, ent)
	local out = {}
	pcall(function()
		for _, p in ipairs(E.api.engine.util.line.getLineProblems()) do
			if ownerOf(E, p[1]) == ent then out[p[1]] = p[2] end
		end
	end)
	return out
end

-- one look at the lines every 2 minutes: a bus more on a full line, a line with a problem given up
local function sellVehicle(E, co, v, why, line)
	-- (0.5.14: the line's fleet changed now: its next fleet decision waits until its balance shows it, see manageLines)
	if line then local A0 = E.G.AI; A0.changedAt = A0.changedAt or {}; A0.changedAt[line] = E.gameTime() end
	act(E, co.id, "makeVehicleSellCmd", { n = 1, [1] = { v } })
	E.G.AI.busy = { what = "sale of vehicle " .. v, since = E.G.frames, until_ = E.G.frames + 120 }
	L(E, "vehicle " .. v .. " sold (" .. why .. ")")
	journal(E, co.id, "sold", nil)
end

-- (0.5.14) a line the company gave up (its fleet sold down to nothing, see manageLines): no purchase path buys it a vehicle any
-- more, it is destroyed once empty. MPFEVER_AIFLEET=0: none (as before, it bought the vehicle back at the next look)
local function dropped(E, line)
	local d = E.G.AI.dropLine
	return d ~= nil and d[line] == true
end

-- (freight, see below: a line's trucks and cargo)
local buyFor, freightOf

local function cargoName(E, id)
	local n = tostring(id)
	pcall(function() n = E.api.res.cargoTypeRep.getName(id) end)
	return n
end

-- (0.6.4) Whether a line may be destroyed now: no person or cargo travels on it and none waits at its stops (each stop, each
-- cargo type). A destroy that dropped cargo still waiting is the suspect of a test's split of entity ids between two games (the
-- engine re-routes or frees that cargo, the free ids followed another order on each game, 2026-10-31 g1). True when it cannot be
-- read (the engine as before), and after RL.IDLE_TRIES looks that found something (an empty line is not kept for ever).
-- MPFEVER_AIDESTROYIDLE=0: at once, as before
local function lineIdle(E, l)
	if os.getenv("MPFEVER_AIDESTROYIDLE") == "0" then return true end
	local A = E.G.AI
	local api = E.api
	local busy = 0
	local ok = pcall(function()
		busy = busy + #api.engine.system.simPersonSystem.getSimPersonsForLine(l.e)
		local ids = {}
		for id in pairs(api.res.cargoTypeRep.getAll()) do ids[#ids + 1] = id end
		for k = 0, #l.groups - 1 do
			for _, c in ipairs(ids) do busy = busy + (api.engine.system.simEntityAtTerminalSystem.getLineStopSimEntitiesCount(l.e, k, c) or 0) end
		end
	end)
	if not ok or busy == 0 then return true end
	A.idleTries = A.idleTries or {}
	A.idleTries[l.e] = (A.idleTries[l.e] or 0) + 1
	if A.idleTries[l.e] > RL.IDLE_TRIES then return true end
	if A.idleTries[l.e] == 1 or A.idleTries[l.e] % 5 == 0 then L(E, "line " .. l.e .. " to give up: " .. busy .. " person(s) or cargo still on it or waiting, destroyed once none is left") end
	return false
end

local function manageLines(E, co, lines, vehicles, money)
	local G = E.G
	local A = G.AI
	-- (in debt: a bus of the emptiest line sold every 20 s until the account is back above zero)
	-- (0.6, MPFEVER_AISOLVENT: under its floor already, FLOOR, not in debt only: it keeps itself solvent, a computer company never
	-- goes bankrupt any more. MPFEVER_AISOLVENT=0: at zero, as before)
	local solvent = os.getenv("MPFEVER_AISOLVENT") ~= "0"
	local low = solvent and FLOOR or 0
	local period = money < low and 1200 or 7200
	if G.frames - (A.manageAt or -100000) < period then return false end
	A.manageAt = G.frames
	local probs = problemLines(E, co.ent)
	A.emptyRuns = A.emptyRuns or {}
	-- (0.5.14) what it remembers of lines and vehicles gone is dropped: MPFever gives a new entity the smallest free id, and a new
	-- line took an old one's "empty" count, first trucks or age, and was given up or pruned at once. MPFEVER_AIRETRY=0: kept
	local grace = os.getenv("MPFEVER_AIGRACE") ~= "0"
	if os.getenv("MPFEVER_AIRETRY") ~= "0" then
		local liveL, liveV = {}, {}
		for _, l in ipairs(lines) do liveL[l.e] = true end
		for _, v in ipairs(vehicles) do liveV[v.e] = true end
		for _, name in ipairs({ "emptyRuns", "trucksFor", "problemSeen", "useHist", "seenAt", "losing", "born", "ratio", "dropLine", "changedAt" }) do
			local t = A[name]
			if type(t) == "table" then for k in pairs(t) do if not liveL[k] then t[k] = nil end end end
		end
		if type(A.lineSent) == "table" then for k in pairs(A.lineSent) do if not liveV[k] then A.lineSent[k] = nil end end end
	end
	local nowG = E.gameTime()
	A.born = A.born or {}
	-- (the lines there at this session's first look ran before it: not young, after a load as on a new game's first lines. Only
	-- those with a vehicle: a line made just before a resynchronisation, its bus not bought yet, keeps its grace, see below)
	if not A.bornInit then
		A.bornInit = true
		local has = {}
		for _, v in ipairs(vehicles) do has[v.line] = true end
		for _, l in ipairs(lines) do if has[l.e] then A.born[l.e] = A.born[l.e] or (nowG - (LV.ramp or 0) - 1) end end
	end
	-- (0.5.14: each line's vehicles fit what it earns, see l.econ below. MPFEVER_AIFLEET=0: as before)
	local fleet = os.getenv("MPFEVER_AIFLEET") ~= "0"
	local yearMs = 1461000
	pcall(function() local y = E.api.util.getDefaultYearDuration(); if type(y) == "number" and y > 0 then yearMs = y end end)
	local emptiest, eUse
	-- (in debt, only the vehicles of a line that loses money are sold: selling the buses of the lines that earned left the companies
	-- of a test of 2026-10-29 at -1.6 million with lines and no vehicle, earning nothing any more. MPFEVER_AIDEBTSELL=0: as before,
	-- the emptiest line's whatever it earns)
	local losingOnly = os.getenv("MPFEVER_AIDEBTSELL") ~= "0"
	for _, l in ipairs(lines) do
		local n, last = 0, nil
		for _, v in ipairs(vehicles) do if v.line == l.e then n = n + 1; last = v.e end end
		local use = meanUse(E, l.e) or lineUse(E, l.e) or 0
		local bal = lineBalance(E, l.e)
		-- (0.5.14, MPFEVER_AIGRACE: not a line still filling up, every young line loses money its first months)
		local young = grace and A.born[l.e] and A.born[l.e] <= nowG and nowG - A.born[l.e] < (LV.ramp or 0)
		-- (0.6, MPFEVER_AISOLVENT: the losing line that loses the most per vehicle first, not the emptiest, and never a long-term line in
		-- its investment, whose loss is planned: it comes last, see below)
		local protected = ltProtected(E, l.e)
		if solvent and losingOnly then
			if n > 0 and not young and not protected and bal ~= nil and bal < 0 and (not emptiest or bal / n < emptiest.per) then emptiest = { line = l, last = last, n = n, per = bal / n } end
		elseif n > 0 and not young and not protected and (not losingOnly or (bal ~= nil and bal < 0)) and (not eUse or use < eUse) then emptiest, eUse = { line = l, last = last, n = n }, use end
		-- (a freight line: its trucks come back empty, and a producer starts slowly once served: emptier, and given more time)
		l.freight = os.getenv("MPFEVER_AIFREIGHT") ~= "0" and freightOf(E, l) or nil
		local emptyUse, emptyLooks = l.freight and 0.04 or 0.08, l.freight and 6 or 3
		-- (empty: few seats used on average, and losing money when its balance is known)
		-- (a freight line that never had its first trucks yet is not empty: it waits for them, see the first trucks in step)
		local waitsTrucks = l.freight and n == 0 and ((A.trucksFor or {})[l.e] or 0) == 0
		local empty = not waitsTrucks and (n == 0 or (use < emptyUse and (bal == nil or bal <= 0)))
		-- (0.5.14) a new line has two game months to get its vehicles and fill before it counts as empty, and only the regular looks
		-- count (in debt they come every 20 s: three looks were a minute). MPFEVER_AIGRACE=0: as before
		if grace then
			if not A.born[l.e] or A.born[l.e] > nowG then A.born[l.e] = nowG end
			if nowG - A.born[l.e] < 240000 then empty = false end
		end
		-- (0.6: a long-term line in its investment with its trucks is not empty: its producer makes little until it grows, its trucks
		-- wait at it for their load)
		if protected and n > 0 then empty = false end
		-- (a line given up, see dropped: empty for good, its last vehicles sold and the line destroyed as the empty ones are)
		if A.dropLine and A.dropLine[l.e] then empty = true; A.emptyRuns[l.e] = math.max(A.emptyRuns[l.e] or 0, emptyLooks - 1) end
		if not grace or period == 7200 then A.emptyRuns[l.e] = empty and ((A.emptyRuns[l.e] or 0) + 1) or 0 end
		-- (a count, never nil: a line had none before its first regular look, and the comparisons below stopped every look in debt)
		A.emptyRuns[l.e] = A.emptyRuns[l.e] or 0
		l.use, l.bal = use, bal
		-- (0.6: for the last way out under its floor, see below)
		l.nVeh, l.lastVeh, l.young, l.protected = n, last, young, protected
		-- (0.5.14) what the line earns against what its vehicles cost to run, over the same two months: its income (the balance
		-- plus the running costs it paid), the running costs of one vehicle, and their ratio (1: it pays its vehicles)
		if fleet then
			local run = 0
			for _, v in ipairs(vehicles) do
				if v.line == l.e then
					local okc, c = pcall(function() return E.api.engine.util.vehicle.getRunningCost(v.e) end)
					if okc and type(c) == "number" then run = run + c end
				end
			end
			local run2m = run * 240000 / yearMs
			local income = (bal or 0) + run2m
			l.econ = { run2m = run2m, income = income, perVeh = n > 0 and run2m / n or nil, ratio = run2m > 0 and income / run2m or nil }
			A.ratio = A.ratio or {}
			A.ratio[l.e] = l.econ.ratio
		end
		-- (a line that stays empty three looks in a row: its buses sold one by one, the line given up with the last)
		if A.emptyRuns[l.e] >= emptyLooks and n > 0 and period == 7200 then
			L(E, string.format("line %d empty for %d looks: a bus less", l.e, A.emptyRuns[l.e]))
			sellVehicle(E, co, last, "empty line " .. l.e)
			return true
		end
		-- (the line itself goes once its last bus is sold: the engine keeps a line that still has a vehicle)
		if A.emptyRuns[l.e] >= emptyLooks and n == 0 and period == 7200 and lineIdle(E, l) then
			L(E, "line " .. l.e .. " given up (empty)")
			local ln = tostring(l.e)
			pcall(function() ln = E.api.engine.getComponent(l.e, E.api.type.ComponentType.NAME).name end)
			journal(E, co.id, "giveup", nil, ln)
			act(E, co.id, "makeLineDestroyCmd", { n = 1, [1] = l.e })
			A.badPair = A.badPair or {}
			if l.groups[1] and l.groups[2] then A.badPair[math.min(l.groups[1], l.groups[2]) .. "-" .. math.max(l.groups[1], l.groups[2])] = true end
			-- (a round: its two ends too, the route it served is not made again)
			local g1, gN = l.groups[1], l.groups[#l.groups]
			if g1 and gN and g1 ~= gN then A.badPair[math.min(g1, gN) .. "-" .. math.max(g1, gN)] = true end
			-- (its stops are demolished afterwards, and a town whose own line it was gets no new one; not for a freight line, whose
			-- town stop may be a stop of the town's bus line)
			A.deadGroups = A.deadGroups or {}
			if not l.freight then for _, g in ipairs(l.groups) do A.deadGroups[g] = true end end
			-- (0.5.14: only for a line of one town; a line between two towns that failed says nothing of either town's own line,
			-- and both towns were left for the whole session. MPFEVER_AIRETRY=0: as before)
			local mine = {}
			for _, g in ipairs(l.groups) do mine[g] = true end
			local touched, nTouched = {}, 0
			for town, pts in pairs(A.targets or {}) do
				for _, s in ipairs(myStops(E, co.ent)) do
					for _, w in ipairs(pts) do
						if mine[s.group] and dist(s.pos, w.p) < 200 and not touched[town] then touched[town] = true; nTouched = nTouched + 1 end
					end
				end
			end
			if nTouched <= 1 or os.getenv("MPFEVER_AIRETRY") == "0" then
				for town, pts in pairs(A.targets or {}) do
					for _, s in ipairs(myStops(E, co.ent)) do
						for _, w in ipairs(pts) do
							if A.deadGroups[s.group] and dist(s.pos, w.p) < 200 then A.skipTown = A.skipTown or {}; A.skipTown[town] = true end
						end
					end
				end
			end
			A.busy = { what = "line " .. l.e .. " destroyed", since = G.frames, until_ = G.frames + 120 }
			return true
		end
	end
	-- the stops of a given up line that no other line of the company uses: demolished one by one (their upkeep for nothing). OFF
	-- (MPFEVER_AIDEMOLISH=1: on): a stop demolished frees its entity, MPFever's free-id order (the smallest first) gives that id
	-- to a new octree node a step later, and the interface's copy of the world, which still had the stop's log book under that
	-- id, stopped both games ("LogBookSystem::EntityAdded isSupported", test rel052 of 2026-10-28)
	if A.deadGroups and period == 7200 and os.getenv("MPFEVER_AIDEMOLISH") == "1" then
		local used = {}
		for _, l in ipairs(lines) do for _, g in ipairs(l.groups) do used[g] = true end end
		for _, s in ipairs(myStops(E, co.ent)) do
			-- (0.6: its removal is paid too: never under the floor, see spendOk)
			if A.deadGroups[s.group] and not used[s.group] and spendOk(E, co, 20000, "demolition of stop " .. s.station) then
				local api = E.api
				local sp = api.type.SimpleProposal.new()
				local ssp = sp.streetProposal
				ssp.edgeObjectsToRemove = { s.station }
				sp.streetProposal = ssp
				L(E, "stop " .. s.station .. " of a given up line demolished")
				build(E, co.id, api.cmd.makeWorldBuildProposalCmd(sp, context(E, co.ent, CTX_STOP), false, true), "demolition of stop " .. s.station, CTX_STOP)
				return true
			end
		end
	end
	if money < low and emptiest and #vehicles > 0 then
		sellVehicle(E, co, emptiest.last, (solvent and losingOnly) and ("under its floor, the line losing the most per vehicle " .. emptiest.line.e) or ("in debt, emptiest line " .. emptiest.line.e))
		return true
	end
	-- (0.6, MPFEVER_AISOLVENT) under its reserve, not yet under its floor: one vehicle of its line losing the most per vehicle at each
	-- regular look (every 2 minutes), its new projects wait meanwhile (see mayExpand). Before, it waited until it was in debt
	if solvent and losingOnly and period == 7200 and money < RESERVE and emptiest and #vehicles > 0 then
		sellVehicle(E, co, emptiest.last, "under its reserve, the line losing the most per vehicle " .. emptiest.line.e, emptiest.line.e)
		return true
	end
	-- (in debt with no line losing money: a loan, as a player would take, rather than waiting in debt; one ask every 2 minutes at
	-- most, the game refuses more than its loans' maximum. MPFEVER_AILOAN=0: none)
	-- (0.5.14, MPFEVER_AILOANPICK: one loan at most, the offer of the lowest monthly payment, see the bridge's ai_loan; the first
	-- offer was taken before, 5 to 70 million over 1 to 24 years: a short one cost more a month than the company earned)
	local pickLoan = os.getenv("MPFEVER_AILOANPICK") ~= "0"
	-- (0.6, MPFEVER_AISOLVENT: under its floor, before it is in debt)
	local loanFree = losingOnly and os.getenv("MPFEVER_AILOAN") ~= "0" and (not pickLoan or (A.loanCount or 0) < 1)
	if money < low and loanFree and G.frames - (A.loanAsked or -100000) > 7200 then
		A.loanAsked = G.frames
		A.loanAskMoney = money
		act(E, co.id, "makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "ai_loan", [4] = pickLoan and { pick = 1, max = 1 } or {} })
		A.busy = { what = "loan", since = G.frames, until_ = G.frames + 120 }
		L(E, (money < 0 and "in debt (" or "under its floor (") .. math.floor(money) .. "): a loan asked")
		return true
	end
	-- (0.6) under its floor with no other losing line to sell from and no loan to take (it has one, or the game gave none): its
	-- long-term line's investment ends there, the floor comes first; its trucks are sold as a losing line's from the next look
	-- (MPFEVER_AISOLVENT=0: in debt)
	-- (a loan asked and still not there two looks later, 40 s: none to take. The game gave none: no loan module, no offer, refused.
	-- Before, the long-term line waited for a loan asked again every 2 minutes and was never ended for the floor)
	local loanWait = loanFree and G.frames - (A.loanAsked or -100000) < 2400
	if money < low and not loanWait then
		for e, lt in pairs(A.lt or {}) do
			if lt.state == "invest" then
				ltEnd(A, lt, "money under its floor", nowG, yearMs)
				L(E, "long-term line " .. e .. " ended: its money is under its floor (" .. math.floor(money) .. " for " .. math.floor(FLOOR) .. ")")
				return true
			end
		end
	end
	-- (0.6) the last way out under its floor: no losing line to sell from, no loan to take, no long-term line to end. One vehicle of
	-- the line earning the least per vehicle, whatever it earns, at each look until it is back above its floor (a young line's only
	-- when no other line has one). Its months in debt are never counted (mpfever_eco.lua, E.AI_NO_BANKRUPT): it stayed in debt,
	-- frozen, for the rest of the game. Nothing is bought again under its reserve (bestBuy, mayExpand), so no sale and purchase in
	-- turn. MPFEVER_AISTUCK=0: never
	if solvent and losingOnly and money < low and not loanWait and not emptiest and #vehicles > 0 and os.getenv("MPFEVER_AISTUCK") ~= "0" then
		local pick
		for _, l in ipairs(lines) do
			if (l.nVeh or 0) > 0 and l.lastVeh and not l.protected then
				local per = (l.bal or 0) / l.nVeh
				local better = not pick or (pick.young and not l.young) or (pick.young == (l.young or false) and per < pick.per)
				if better then pick = { line = l, per = per, young = l.young or false } end
			end
		end
		if pick then
			sellVehicle(E, co, pick.line.lastVeh, "under its floor with no losing line and no loan to take, the line earning the least per vehicle " .. pick.line.e, pick.line.e)
			return true
		end
	end
	-- (0.5.14) money to spare: its oldest loan repaid, if it has one (the simulation decides on its own balance, the same on every
	-- game, see the bridge's ai_repay), at most every 6 game months. Before, a loan was never repaid and its money was spent as
	-- profit. MPFEVER_AIREPAY=0: never
	local nowT = E.gameTime()
	if os.getenv("MPFEVER_AIREPAY") ~= "0" and (A.loanCount == nil or A.loanCount > 0) and money > 2 * RESERVE + 1000000 and (not A.repayAt or A.repayAt > nowT or nowT - A.repayAt > 720000) then
		A.repayAt = nowT
		act(E, co.id, "makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "ai_repay", [4] = { keep = math.floor(RESERVE) } })
		A.busy = { what = "loan repaid", since = G.frames, until_ = G.frames + 120 }
		L(E, "money to spare (" .. math.floor(money) .. "): its oldest loan repaid if it has one")
		return true
	end
	-- (a loan's money, seen at the next look after asking: kept apart from the money to spare, see mayExpand; spent down with it)
	-- (MPFEVER_AILOANBOOK=0 only: else the loan book read in step says it, see loanBook)
	if os.getenv("MPFEVER_AILOANBOOK") == "0" then
		if A.loanAskMoney and money - A.loanAskMoney > 500000 then A.loanCash = (A.loanCash or 0) + money - A.loanAskMoney end
		A.loanAskMoney = nil
		if A.loanCash and money < RESERVE + A.loanCash then A.loanCash = math.max(0, money - RESERVE) end
	end
	local reinvest = os.getenv("MPFEVER_AIREINVEST") ~= "0"
	local bestBuy = nil
	for _, l in ipairs(lines) do
		local n, last = 0, nil
		for _, v in ipairs(vehicles) do if v.line == l.e then n = n + 1; last = v.e end end
		local use = l.use
		L(E, string.format("line %d: %d bus(es), %s of the seats used on average, balance of the last 2 months %s%s", l.e, n,
			use and (math.floor(use * 100) .. "%") or "?", l.bal and tostring(math.floor(l.bal)) or "?", probs[l.e] and (", problem " .. tostring(probs[l.e])) or ""))
		-- (0.5.14, MPFEVER_AIPROBLEMSELL: its vehicles sold first, one a look, the line destroyed with the last as an empty one; the
		-- engine keeps a line that still has a vehicle. MPFEVER_AIPROBLEMSELL=0: destroyed at once, as before)
		if probs[l.e] and n > 0 and (A.problemSeen or {})[l.e] and os.getenv("MPFEVER_AIPROBLEMSELL") ~= "0" then
			L(E, "line " .. l.e .. " has a problem (" .. tostring(probs[l.e]) .. "): its vehicles sold, then the line")
			A.dropLine = A.dropLine or {}; A.dropLine[l.e] = true
			sellVehicle(E, co, last, "line " .. l.e .. " with a problem", l.e)
			return true
		end
		if probs[l.e] and n > 0 and (A.problemSeen or {})[l.e] and lineIdle(E, l) then
			-- (a problem seen twice in a row: the line is given up, its buses go to the company's other lines)
			L(E, "line " .. l.e .. " given up (problem " .. tostring(probs[l.e]) .. ")")
			local ln = tostring(l.e)
			pcall(function() ln = E.api.engine.getComponent(l.e, E.api.type.ComponentType.NAME).name end)
			journal(E, co.id, "giveup", nil, ln)
			act(E, co.id, "makeLineDestroyCmd", { n = 1, [1] = l.e })
			-- (its stops are not joined again: keyed by their station groups)
			A.badPair = A.badPair or {}
			if l.groups[1] and l.groups[2] then A.badPair[math.min(l.groups[1], l.groups[2]) .. "-" .. math.max(l.groups[1], l.groups[2])] = true end
			local g1, gN = l.groups[1], l.groups[#l.groups]
			if g1 and gN and g1 ~= gN then A.badPair[math.min(g1, gN) .. "-" .. math.max(g1, gN)] = true end
			return true
		end
		A.problemSeen = A.problemSeen or {}
		A.problemSeen[l.e] = probs[l.e] and true or nil
		-- (0.5.14) a fleet that fits what the line earns: once the line had time to fill (the level's ramp), one vehicle less when it
		-- does not pay its vehicles' running costs (two looks in a row), and its last one when it pays less than the level's share of
		-- them (the line is then given up as empty). Before, a losing line kept every vehicle until the company was in debt, then
		-- everything was sold at once. MPFEVER_AIFLEET=0 (and MPFEVER_AIPRUNE=0: none): losing lines with more than two vehicles
		if period == 7200 and (fleet or (os.getenv("MPFEVER_AIPRUNE") ~= "0" and LV.name ~= "easy")) then
			A.seenAt = A.seenAt or {}
			if not A.seenAt[l.e] or A.seenAt[l.e] > nowG then A.seenAt[l.e] = nowG end
			local age = nowG - A.seenAt[l.e]
			A.losing = A.losing or {}
			local under
			if fleet then
				local r = l.econ and l.econ.ratio
				-- (not before its balance shows its last fleet change, two game months)
				local ch = A.changedAt and A.changedAt[l.e]
				local settled = not ch or ch > nowG or nowG - ch >= 240000
				under = settled and r ~= nil and age > LV.ramp and ((n > 1 and r < 1) or (n == 1 and r < LV.giveUp))
				-- (0.6: not a long-term line in its investment, its loss is planned, see ltJudge)
				if ltProtected(E, l.e) then under = false end
			else
				under = n > 2 and l.bal and l.bal < 0 and age > 720000
			end
			A.losing[l.e] = under and ((A.losing[l.e] or 0) + 1) or 0
			if A.losing[l.e] >= ((fleet or LV.name == "hard") and 2 or 3) then
				A.losing[l.e] = 0
				L(E, string.format("line %d does not pay its vehicles (%s of their running costs, balance %d over 2 months) with %d vehicle(s): one less",
					l.e, l.econ and l.econ.ratio and (math.floor(l.econ.ratio * 100) .. "%") or "?", math.floor(l.bal or 0), n))
				-- (its last one: the line is given up, nothing buys it back, see dropped)
				if fleet and n == 1 then A.dropLine = A.dropLine or {}; A.dropLine[l.e] = true end
				sellVehicle(E, co, last, "line " .. l.e .. " does not pay its vehicles", l.e)
				return true
			end
		end
		-- (a freight line: a truck more when the cargo waiting at the producer fills one, or the trucks are full one way)
		local busy = use and use > LV.busUse and n < LV.maxBus
		if l.freight then
			local waiting = 0
			pcall(function() waiting = E.api.engine.system.simEntityAtTerminalSystem.getLineStopSimEntitiesCount(l.e, 0, l.freight.cargo) end)
			busy = n < LV.maxTruck and (waiting >= LV.waiting or (use and use > LV.truckUse))
			-- (0.6) a long-term line in its investment: a truck more only for the cargo waiting at its producer (its producer grows only
			-- with what is shipped from it, a quarter left behind and it stops growing), up to LT.maxTrucks, while its budget left pays
			-- one more truck a year; it then comes before the other lines, see bestBuy. MPFEVER_AILTTRUCKS=0: as any line
			l.ltBuy = nil
			if ltProtected(E, l.e) and os.getenv("MPFEVER_AILTTRUCKS") ~= "0" then
				local lt = A.lt[l.e]
				local perYear = ((l.econ and l.econ.perVeh) or 0) * yearMs / 240000
				busy = n < LT.maxTrucks and waiting >= LV.waiting and (lt.budget or 0) - (lt.spent or 0) >= perYear
				l.ltBuy = busy or nil
			end
			if busy then L(E, string.format("line %d: %d %s waiting at the producer", l.e, waiting, cargoName(E, l.freight.cargo))) end
			-- (0.5.14, diagnostic: what the producer ships and what the industry at the other end receives and uses of that cargo a
			-- year: trucks full both ways that earn nothing showed in the tests of 2026-10-29, the reason is still to find)
			if period == 7200 then
				pcall(function()
					local stk, c = E.api.engine.util.stock, l.freight.cargo
					local fr, to = l.freight.from, l.freight.to
					local function n0(f, sl) local ok, v = pcall(f, sl, c); return ok and tostring(v) or "?" end
					L(E, string.format("freight line %d (%s): producer makes %s and ships %s a year; %s", l.e, cargoName(E, c),
						n0(stk.getCargoProducedPerYear, fr.stockList), n0(stk.getCargoTypeShippedPerYear, fr.stockList),
						to.stockList and string.format("the industry there receives %s, uses %s (at most %s) a year", n0(stk.getCargoTypeDeliveredPerYear, to.stockList),
							n0(stk.getCargoConsumedPerYear, to.stockList), n0(stk.getCargoMaxConsumptionPerYear, to.stockList)) or "a town stop"))
				end)
			end
		end
		if busy and not dropped(E, l.e) and money > RESERVE + ((l.freight and A.truckCost or A.busCost) or BUS_COST) then
			if reinvest then
				-- (0.5.14) the busy line that earns the most per vehicle gets the next one; a full line that loses money gets none on
				-- Normal and Hard (each more of its vehicles loses more). MPFEVER_AIREINVEST=0: the first busy line, as before
				local per = (l.bal or 0) / math.max(1, n)
				-- (with MPFEVER_AIFLEET: only while one more vehicle would still pay, its income shared by one more, with the level's margin)
				local pays
				local ch = A.changedAt and A.changedAt[l.e]
				local settled = not ch or ch > nowG or nowG - ch >= 240000
				if fleet and l.econ and l.econ.perVeh then pays = settled and l.econ.income / (n + 1) >= l.econ.perVeh * LV.addMargin
				else pays = LV.name == "easy" or l.bal == nil or l.bal >= 0 end
				-- (0.6: a long-term line's truck for its waiting cargo, see l.ltBuy: first, once its last change shows)
				if l.ltBuy then pays, per = settled, math.huge end
				if pays and (not bestBuy or per > bestBuy.per) then bestBuy = { l = l, per = per } end
			else
				local depot = garagesNear(E, co.ent, l.mid or (l.freight and l.freight.from.pos) or { x = 0, y = 0 }, 5000)[1]
				if depot then
					A.forLine = l.e
					buyFor(E, co, l, depot.depot)
					return true
				end
			end
		end
	end
	if bestBuy then
		local l = bestBuy.l
		local depot = garagesNear(E, co.ent, l.mid or (l.freight and l.freight.from.pos) or { x = 0, y = 0 }, 5000)[1]
		if depot then
			L(E, bestBuy.per == math.huge and string.format("long-term line %d gets a truck more for the cargo waiting at its producer", l.e)
				or string.format("line %d gets a vehicle more (it earns %d per vehicle over 2 months)", l.e, math.floor(bestBuy.per)))
			A.forLine = l.e
			buyFor(E, co, l, depot.depot)
			return true
		end
	end
	return false
end

-- lines between neighbour towns: the company's stops nearest their residential centres, joined when both towns have one and
-- no line of the company joins them yet (a pair whose line was given up is not tried again)
local function interTown(E, co, stops, lines, money)
	local api = E.api
	local A = E.G.AI
	if money < RESERVE + 200000 then return false end
	local main = {}
	for _, t in ipairs(townsBySize(E)) do
		local c = centre(E, t.e, api.type.enum.LandUseType.RESIDENTIAL)
		if c then
			local best, bd
			for _, s in ipairs(stops) do local d = dist(s.pos, c); if d < 300 and (not bd or d < bd) then best, bd = s, d end end
			if best then main[#main + 1] = { town = t.e, stop = best, c = c } end
		end
	end
	for i = 1, #main do
		for j = i + 1, #main do
			local a, b = main[i], main[j]
			local key = math.min(a.stop.group, b.stop.group) .. "-" .. math.max(a.stop.group, b.stop.group)
			if dist(a.c, b.c) < 4500 and not (A.badPair or {})[key] and not (A.pairTried or {})[key] and not lineFor(E, lines, { a.stop.group, b.stop.group }) then
				A.pairTried = A.pairTried or {}; A.pairTried[key] = true
				A.pairOf = A.pairOf or {}
				A.nextPair = key
				createLine(E, co, { a.stop.group, b.stop.group }, a.town, AINAME .. " " .. townName(E, a.town) .. " - " .. townName(E, b.town))
				return true
			end
		end
	end
	return false
end

-- The best pair of towns to join next: both big, 1.2 to 6 km apart (fares grow with the distance), not joined by a line of the
-- company yet, not given up. Score: the product of their sizes over their distance.
local function bestPair(E, co, lines, stops)
	local api = E.api
	local A = E.G.AI
	local towns = {}
	-- (0.6, F5: no town whose centre is in a player's territory, see territoryCheck)
	local terr = territoryCheck(E)
	for _, t in ipairs(townsBySize(E)) do
		local c = centre(E, t.e, api.type.enum.LandUseType.RESIDENTIAL)
		if c and t.size > 150 and not (terr and terr(c.x, c.y)) then towns[#towns + 1] = { e = t.e, size = t.size, c = c } end
	end
	local best
	for i = 1, #towns do
		for j = i + 1, #towns do
			local a, b = towns[i], towns[j]
			local d = dist(a.c, b.c)
			local key = math.min(a.e, b.e) .. "/" .. math.max(a.e, b.e)
			if d > 1200 and d < 6000 and not (A.pairDone or {})[key] and not (A.pairFailed or {})[key] then
				local score = a.size * b.size / d
				-- (0.5.14) a pair another computer company runs or builds shares its passengers with it: its score as the share left
				-- (twice less for the levels that do not compete). The three companies of a test of 2026-10-30 all built the same
				-- three pairs and earned half of what two had. The pair this one builds keeps its score: never left half built.
				-- MPFEVER_AIPAIRSPREAD=0: as before
				if key ~= A.pairUnderWay and os.getenv("MPFEVER_AIPAIRSPREAD") ~= "0" then
					local n = 0
					for _, S in pairs(E.G.AIS or {}) do
						-- (a pair it failed is no pair under way: it kept the key while its growth waited)
						if S ~= A and ((S.pairDone or {})[key] or (S.pairUnderWay == key and not (S.pairFailed or {})[key])) then n = n + 1 end
					end
					score = score / (1 + n * (LV.compete and 1 or 2))
				end
				if not best or score > best.score then best = { a = a, b = b, d = d, key = key, score = score } end
			end
		end
	end
	return best
end

-- the company's stop serving a point (within 200 m), if any
local function stopAt(stops, p)
	local best, bd
	for _, s in ipairs(stops) do local d = dist(s.pos, p); if d < 200 and (not bd or d < bd) then best, bd = s, d end end
	return best
end

-- a stop near a point: the nearest free town street segment, the next one after each refusal; false when none is left
local function stopNear(E, co, stops, p, key)
	local A = E.G.AI
	local avoid = {}
	for _, s in ipairs(stops) do avoid[#avoid + 1] = s.pos end
	-- (within the 200 m stopAt takes: a stop built farther was never found again, and another one was built, and another)
	local segs = streetSegmentsNear(E, p, 200, avoid)
	local tries = (A.failed and A.failed["stop " .. key]) or 0
	local s = segs[1 + tries]
	if not s or tries > 4 then return false end
	L(E, "stop " .. key .. " (" .. math.floor(s.d) .. " m from its point)")
	-- (0.6: not built under the floor: the project waits, "wait" counts as acted for its callers, the place is not given up)
	if buildStop(E, co, s.e, key) == false then return "wait" end
	return true
end

-- the garage for a place: the company's own within 5 km, else one built near it (money allowing), else another company's
-- within 5 km; returns the garage, or "building", or nil
local function garageFor(E, co, p, money, key)
	local A = E.G.AI
	local list = garagesNear(E, co.ent, p, 5000)
	if list[1] and list[1].own then return list[1] end
	-- (0.5.14: a garage open to it within 5 km does, another company's or the town's: a garage costs about 650 000 and a company of
	-- the tests built three of them in its first minutes beside open ones. MPFEVER_AIOWNGARAGE=1: its own first, as before)
	if list[1] and os.getenv("MPFEVER_AIOWNGARAGE") ~= "1" then return list[1] end
	A.garageTried = A.garageTried or {}
	-- (0.5.14: tried again after a year of game time, the town may have grown streets by then; before, one try per session.
	-- MPFEVER_AIRETRY=0: one try)
	local tried, nowT = A.garageTried[key], E.gameTime()
	local again = os.getenv("MPFEVER_AIRETRY") ~= "0" and type(tried) == "number" and (tried > nowT or nowT - tried > 1440000)
	if (not tried or again) and money >= RESERVE + 650000 then
		A.garageTried[key] = nowT
		local pl = garagePlaces(E, co, p, 900)[1]
		if pl then
			L(E, "garage near " .. key .. " on segment " .. pl.seg)
			-- (0.6: not built under the floor: tried again in two months, the project waits meanwhile)
			if buildGarage(E, co, pl) == false then A.garageTried[key] = nowT - 1440000 + 240000 end
			return "building"
		end
		L(E, "no free place for a garage near " .. key)
	end
	return list[1]
end

-- one step of the best pair's project: garage, a stop in each town, the line, its first buses. True when it acted (or waits)
local function pairProject(E, co, stops, lines, vehicles, money, grow)
	local A = E.G.AI
	local pair = bestPair(E, co, lines, stops)
	if not pair then return false end
	-- (a new pair only when the company may grow, see mayExpand; the pair under way gets its line and first buses)
	if grow == false and A.pairUnderWay ~= pair.key then return false end
	A.pairUnderWay = pair.key
	local na, nb = townName(E, pair.a.e), townName(E, pair.b.e)
	local g = garageFor(E, co, pair.a.c, money, na)
	if g == "building" then return true end
	if not g then g = garageFor(E, co, pair.b.c, money, nb) end
	if g == "building" then return true end
	-- (0.5.14: no garage only for want of money: the pair waits, it was left for the session before. MPFEVER_AIRETRY=0: left)
	if not g and money < RESERVE + 650000 and os.getenv("MPFEVER_AIRETRY") ~= "0" then return "wait" end
	if not g then
		L(E, "no garage for " .. na .. " - " .. nb .. ": pair left")
		A.pairFailed = A.pairFailed or {}; A.pairFailed[pair.key] = true
		return false
	end
	-- the line's points: in each town its residential centre and, when another district stands 300 m away, the one nearer to
	-- the other town (people ride from their homes to the other town's shops and works): A home, A work, B work, B home
	local function points(t, other)
		local tg = townTargets(E, t.e, stops)
		local list = { tg[1] }
		local best, bd
		for k = 2, #tg do local d = dist(tg[k].p, other.c); if not bd or d < bd then best, bd = tg[k], d end end
		if best then list[2] = best end
		return list
	end
	local pa, pb = points(pair.a, pair.b), points(pair.b, pair.a)
	local wanted = {}
	for _, p in ipairs(pa) do wanted[#wanted + 1] = { town = pair.a.e, p = p } end
	for k = #pb, 1, -1 do wanted[#wanted + 1] = { town = pair.b.e, p = pb[k] } end
	local groups = {}
	for _, w in ipairs(wanted) do
		local s = stopAt(stops, w.p.p)
		if not s then
			if money < RESERVE + 60000 then return "wait" end
			if stopNear(E, co, stops, w.p.p, w.town .. ":" .. w.p.use) then return true end
			if w.p.use == "RESIDENTIAL" then
				L(E, "no street for a stop in " .. townName(E, w.town) .. ": pair left")
				A.pairFailed = A.pairFailed or {}; A.pairFailed[pair.key] = true
				return false
			end
		else
			groups[#groups + 1] = s.group
		end
	end
	if #groups < 2 then return true end
	local sa, sb = { group = groups[1] }, { group = groups[#groups] }
	local line = lineFor(E, lines, groups)
	local gkey = math.min(sa.group, sb.group) .. "-" .. math.max(sa.group, sb.group)
	if not line and (A.badPair or {})[gkey] then
		-- (a line given up there before: the pair is left)
		A.pairFailed = A.pairFailed or {}; A.pairFailed[pair.key] = true
		return false
	end
	if line and (A.emptyRuns or {})[line.e] and A.emptyRuns[line.e] > 0 then
		A.pairDone = A.pairDone or {}; A.pairDone[pair.key] = true
		return false
	end
	if not line then
		-- (a line only with the money for its first buses)
		if money < RESERVE + 2 * (A.busCost or BUS_COST) then return "wait" end
		createLine(E, co, groups, pair.a.e, AINAME .. " " .. na .. " - " .. nb)
		return true
	end
	local n = 0
	for _, v in ipairs(vehicles) do if v.line == line.e then n = n + 1 end end
	-- (0.5.14, MPFEVER_AIFLEET: two buses to begin with, more as it earns, see manageLines; three before)
	if n < ((os.getenv("MPFEVER_AIFLEET") ~= "0") and 2 or 3) and not dropped(E, line.e) then
		if money < RESERVE + (A.busCost or BUS_COST) then return "wait" end
		A.forLine = line.e
		buyBus(E, co, g.depot)
		return true
	end
	A.pairDone = A.pairDone or {}; A.pairDone[pair.key] = true
	A.pairUnderWay = nil
	L(E, "pair " .. na .. " - " .. nb .. " running (" .. n .. " buses, " .. math.floor(pair.d) .. " m)")
	return true
end

-- ------------------------------------------------------------------ freight (trucks, 0.5.13)

-- Every industry has its own street station (the trucks of the players stop at the industry itself): a freight line is a line
-- from a producer's station to the station of an industry that takes that cargo, with trucks that carry it. Nothing to build
-- but the garage. MPFEVER_AIFREIGHT=0: buses only, as in 0.5.12.
-- (0.5.14) A route left for want of a garage near its producer waits six game months, then is tried again (a garage may stand
-- there by then: the company's own for a town, or another company's), instead of being left for the whole session: freight
-- comes first, before the company has any garage, and the best routes were all left in the first minutes. Returns true when
-- held. MPFEVER_AIRETRY=0: left for good, as before.
local function G_HOLD(E, key)
	if os.getenv("MPFEVER_AIRETRY") == "0" then return false end
	local A = E.G.AI
	A.freightHold = A.freightHold or {}
	A.freightHold[key] = E.gameTime() + 720000
	return true
end

local FREIGHT_MIN = 900      -- the shortest distance between the two industries (m); the longest is the level's (LEVELS)

-- the road terminals of a construction's stations: { group, list = { { station, terminal, node } } } (station and terminal
-- 0-based, as a line's stop takes them), nil when it has none
local function roadTerminals(E, con)
	local api = E.api
	local truck = api.type.enum.TransportMode.TRUCK
	local out
	for k = 1, #con.stations do
		local st = con.stations[k]
		local okg, group = pcall(function() return api.engine.system.stationGroupSystem.getStationGroup(st) end)
		local sg = okg and group and api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local sc = api.engine.getComponent(st, api.type.ComponentType.STATION)
		if sg and sc then
			local si
			for i = 1, #sg.stations do if sg.stations[i] == st then si = i - 1 end end
			for t = 1, #sc.terminals do
				-- (a terminal trucks use: the carriers the engine reports for it; kept when it cannot tell)
				local road = true
				pcall(function()
					local cr = api.engine.system.stationGroupSystem.getCarriers(group, si, t - 1)
					local modes = cr and cr[2]
					if modes and #modes > 0 then
						road = false
						for _, m in ipairs(modes) do if m == truck then road = true end end
					end
				end)
				if road and si then
					out = out or { group = group, list = {} }
					if out.group == group then
						out.list[#out.list + 1] = { station = si, terminal = t - 1, node = sc.terminals[t].vehicleNodeId }
					end
				end
			end
		end
	end
	return out
end

-- the map's industries: what each makes and takes, where it stands, its road terminals (read once a minute)
local function industries(E)
	local api, R = E.api, E.R
	local A = E.G.AI
	if A.indCache and E.G.frames - A.indCache.frame < 3600 then return A.indCache.list end
	local OUT, IN = api.type.enum.StockListType.OutputStock, api.type.enum.StockListType.InputStock
	local list = {}
	for _, e in ipairs(R.entitiesWith("INDUSTRY")) do
		pcall(function()
			local ind = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY)
			local con = ind and api.engine.getComponent(ind.construction, api.type.ComponentType.CONSTRUCTION)
			local sl = ind and api.engine.getComponent(ind.stockList, api.type.ComponentType.STOCK_LIST)
			if not (con and sl) then return end
			local m = E.C.marshal(con.transf)
			local it = { e = e, con = ind.construction, stockList = ind.stockList, pos = { x = m[13], y = m[14], z = m[15] },
				file = tostring(con.fileName), outputs = {}, inputs = {}, inputSets = {} }
			-- (0.6: its level and its most, the room it has to grow, see the long-term freight)
			pcall(function() it.level, it.maxLevel = tonumber(ind.level), tonumber(ind.maxLevel) end)
			for k = 1, #sl.stocks do
				local s = sl.stocks[k]
				if s.type == OUT and s.cargoType >= 0 then it.outputs[#it.outputs + 1] = s.cargoType end
				if s.type == IN then
					if s.cargoType >= 0 then it.inputs[s.cargoType] = true else it.inputSets[#it.inputSets + 1] = s.cargoTypes end
				end
			end
			-- (primary: a rule of it, not a booster, makes cargo from nothing, as a mine or a farm; the others need their inputs)
			it.primary = false
			pcall(function()
				for k = 1, #sl.rules do
					local r = sl.rules[k]
					if not r.booster then
						local need = 0
						local alt = r.input and r.input[1]
						if alt then for j = 1, #alt do need = need + (alt[j] or 0) end end
						if need == 0 then it.primary = true end
					end
				end
			end)
			it.road = roadTerminals(E, con)
			-- (else a station of one of its parts, as the game's own path finding of the missions looks for it)
			for k = 1, #con.subconstructions do
				if it.road then break end
				local sub = api.engine.getComponent(con.subconstructions[k], api.type.ComponentType.CONSTRUCTION)
				if sub then it.road = roadTerminals(E, sub) end
			end
			if it.road then list[#list + 1] = it end
		end)
	end
	table.sort(list, function(a, b) return a.e < b.e end)
	A.indCache = { frame = E.G.frames, list = list }
	return list
end

-- How much of a cargo a producer makes now (a year's worth, for the routes' score), nil when it makes none: an industry that needs
-- inputs makes nothing without them (the first test of 0.5.13: a brick works, a refinery and a food factory with no raw material,
-- lines that ran empty and were given up); a primary one starts once a line serves it (half its most). MPFEVER_AIANYPRODUCER=1:
-- every producer, as before.
local function producedOf(E, ind, c)
	local api = E.api
	local made = 0
	pcall(function() made = api.engine.util.stock.getCargoProducedPerYear(ind.stockList, c) or 0 end)
	if made > 0 then return made end
	if ind.primary or os.getenv("MPFEVER_AIANYPRODUCER") == "1" then
		local most = 0
		pcall(function() most = api.engine.util.stock.getCargoMaxProductionPerYear(ind.stockList, c) or 0 end)
		-- (0.5.14: a tenth of its most, a producer that makes the cargo now comes first; half before. MPFEVER_AIRETRY=0: half)
		return most * (os.getenv("MPFEVER_AIRETRY") == "0" and 0.5 or 0.1)
	end
	return nil
end

local function takes(E, ind, cargo)
	if ind.inputs[cargo] then return true end
	for _, set in ipairs(ind.inputSets) do
		local ok, yes = pcall(function() return E.api.res.cargoTypeRep.hasCargoType(set, cargo) end)
		if ok and yes then return true end
	end
	return false
end

-- the station groups other companies' lines stop at (the industries they serve are theirs: PvE; not on the Hard level, which
-- competes with them)
local function servedByOthers(E, ent)
	local api, R = E.api, E.R
	local out = {}
	if LV.compete then return out end
	for _, l in ipairs(R.entitiesWith("LINE")) do
		if ownerOf(E, l) ~= ent then
			local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
			for k = 1, #lc.stops do out[lc.stops[k].stationGroup] = true end
		end
	end
	return out
end

-- a truck can drive from one industry's road terminals to the other's (the engine's path finding)
local function roadPath(E, a, b)
	local api = E.api
	local na, nb = {}, {}
	for _, t in ipairs(a.road.list) do na[#na + 1] = t.node end
	for _, t in ipairs(b.road.list) do nb[#nb + 1] = t.node end
	local ok, p = pcall(function() return api.engine.util.pathfinding.findPathNodeToNode(na, nb, { api.type.enum.TransportMode.TRUCK }) end)
	return ok and type(p) == "table" and #p > 0
end

-- the best truck on sale this year for a cargo: most capacity for it, then the newest
local function bestTruck(E, cargo)
	local api = E.api
	local year = currentYear(E)
	local best
	for id, name in pairs(api.res.modelRep.getAll()) do
		if tostring(name):find("/vehicle/truck/", 1, true) then
			local m = api.res.modelRep.get(id)
			local md = m and m.metadata
			local av = md and md.availability
			local from, to = av and av.yearFrom or 0, av and av.yearTo or 0
			if from <= year and (to == 0 or to > year) then
				local cap = 0
				-- (one compartment only, as for the buses above; MPFEVER_AIMULTICOMP=1: any model)
				local comps = 1
				pcall(function() comps = #md.transportVehicle.compartments end)
				pcall(function()
					if comps > 1 and os.getenv("MPFEVER_AIMULTICOMP") ~= "1" then return end
					for _, comp in ipairs(md.transportVehicle.compartments) do
						for _, lc in ipairs(comp.loadConfigs) do
							if api.res.cargoTypeRep.hasCargoType(lc.cargoEntry.cargoTypeSet, cargo) then cap = math.max(cap, lc.cargoEntry.capacity or 0) end
						end
					end
				end)
				if cap > 0 and (not best or cap > best.seats or (cap == best.seats and from > best.from)) then
					best = { id = id, name = name, seats = cap, from = from }
					-- (0.6: its price on the model, for the floor, see spendOk)
					pcall(function() best.price = tonumber(md.cost.price) end)
				end
			end
		end
	end
	return best, year
end

-- the road terminals of a station group (a street stop: its two sides), as roadTerminals gives them
local function groupRoad(E, group)
	local api = E.api
	local sg = api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
	if not sg then return nil end
	local out = { group = group, list = {} }
	for k = 1, #sg.stations do
		local sc = api.engine.getComponent(sg.stations[k], api.type.ComponentType.STATION)
		if sc then
			for t = 1, #sc.terminals do out.list[#out.list + 1] = { station = k - 1, terminal = t - 1, node = sc.terminals[t].vehicleNodeId } end
		end
	end
	return #out.list > 0 and out or nil
end

-- a freight line of the company: { from = industry, to = industry or town stop, cargo } when its first stop is an industry's
-- station and its second one an industry that takes a cargo of the first, or a street stop (a town's delivery: the producer's
-- first cargo). Read from the world: nothing kept across loads.
freightOf = function(E, line)
	local inds = industries(E)
	local byGroup = {}
	for _, it in ipairs(inds) do byGroup[it.road.group] = it end
	-- (a round: the producers first, the industry that takes their cargo last)
	local a, b = byGroup[line.groups[1]], byGroup[line.groups[#line.groups]]
	if not a or not line.groups[2] then return nil end
	if b then
		for _, c in ipairs(a.outputs) do if takes(E, b, c) then return { from = a, to = b, cargo = c } end end
		return nil
	end
	if a.outputs[1] and #line.groups == 2 then
		local road = groupRoad(E, line.groups[2])
		if road then return { from = a, to = { road = road }, cargo = a.outputs[1], town = true } end
	end
	return nil
end

-- a vehicle more for a line: a truck for its cargo on a freight line, else a bus
local function buyTruck(E, co, depot, cargo)
	local truck, year = bestTruck(E, cargo)
	if not truck then L(E, "no truck for " .. cargoName(E, cargo) .. " on sale in " .. year); return false end
	-- (0.6: never under the floor, see spendOk)
	if not spendOk(E, co, math.max(E.G.AI.truckCost or BUS_COST, truck.price or 0), "truck " .. tostring(truck.name)) then return false end
	local cfg = {
		vehicles = { { part = { modelId = truck.id, reversed = false, compartment2loadConfig = { { loadConfigIndex = 0, cargoTypeId = 0, __ud = true } },
			color = { x = -1, y = -1, z = -1, __vec = true }, __ud = true }, purchaseTime = 0, maintenanceChange = 0, maintenanceState = 1,
			autoLoadConfig = { true }, __ud = true } },
		vehicleGroups = { 1 }, muFileNames = {}, __ud = true }
	-- (0.5.14: the fleet of the line it is for changes now, see manageLines' settled)
	do local A0 = E.G.AI; if A0.forLine then A0.changedAt = A0.changedAt or {}; A0.changedAt[A0.forLine] = E.gameTime() end end
	act(E, co.id, "makeVehicleBuyCmd", { n = 3, [1] = co.ent, [2] = depot, [3] = cfg })
	E.G.AI.busy = { what = "truck " .. truck.name, since = E.G.frames, vehBefore = #myVehicles(E, co.ent), moneyBefore = balanceOf(E, co.ent),
		jr = { kind = "truck", pos = depotPos(E, depot), a = tostring(truck.name):match("([^/]+)%.mdl$") or truck.name, b = cargo } }
	L(E, "truck requested: " .. truck.name .. " (" .. truck.seats .. " " .. cargoName(E, cargo) .. ", " .. year .. ") at depot " .. depot)
	return true
end

buyFor = function(E, co, line, depot)
	local f = os.getenv("MPFEVER_AIFREIGHT") ~= "0" and freightOf(E, line)
	if f then return buyTruck(E, co, depot, f.cargo) end
	return buyBus(E, co, depot)
end

-- A stop of a freight line; loadCargo: the cargo its trucks load there (a producer's stop). The stop's configuration lists, per
-- cargo type (its id + 1), whether to load it and up to which share: a new stop's lists are empty, and its trucks loaded nothing
-- (the lines of 0.5.13's first test ran empty and were given up). As the game's line window sets it: that cargo loaded, full.
local function freightStop(E, road, stop0, loadCargo)
	local s = {}
	if stop0 then for k, v in pairs(stop0) do s[k] = v end end
	if loadCargo then
		local n = 0
		pcall(function() for id in pairs(E.api.res.cargoTypeRep.getAll(true)) do if id + 1 > n then n = id + 1 end end end)
		if n > loadCargo then
			local cfg = {}
			if type(s.stopConfig) == "table" then for k, v in pairs(s.stopConfig) do cfg[k] = v end end
			local load, maxLoad = {}, {}
			for k = 1, n do load[k] = (k == loadCargo + 1); maxLoad[k] = 1 end
			cfg.load, cfg.maxLoad = load, maxLoad
			if cfg.destroyForConfigChange == nil then cfg.destroyForConfigChange = true end
			if cfg.destroyForRefresh == nil then cfg.destroyForRefresh = true end
			if cfg.forceUnload == nil then cfg.forceUnload = false end
			cfg.__ud = true
			s.stopConfig = cfg
		else
			L(E, "freight stop: the cargo types could not be read, " .. tostring(loadCargo) .. " not set to load")
		end
	end
	local first = road.list[1]
	s.stationGroup = road.group
	s.station = first.station
	s.terminal = first.terminal
	-- (the station's other road terminals as alternatives: the engine takes a free one)
	local alt = {}
	for k = 2, #road.list do alt[#alt + 1] = { station = road.list[k].station, terminal = road.list[k].terminal, __ud = true } end
	s.alternativeTerminals = alt
	s.waypoints = {}
	s.__ud = true
	return s
end

local function createFreightLine(E, co, f, extra)
	local api, C, R = E.api, E.C, E.R
	-- (a truck line of the savegame as the template of the line's fields, else a new line's)
	local template
	for _, l in ipairs(R.entitiesWith("LINE")) do
		local m = C.marshal(api.engine.getComponent(l, api.type.ComponentType.LINE))
		if m and m.vehicleInfo and m.vehicleInfo.transportModes and m.vehicleInfo.transportModes[4] == true then template = m break end
	end
	if not template then template = C.marshal(api.type.Line.new()) end
	-- (a stop's fields without the template's own cargo settings: every cargo loaded and unloaded, the engine's defaults)
	local stop0
	pcall(function() stop0 = C.marshal(api.type.Line.Stop.new()) end)
	if not stop0 and template.stops and template.stops[1] then
		stop0 = {}
		for k, v in pairs(template.stops[1]) do if k ~= "stopConfig" then stop0[k] = v end end
	end
	template.stops = { freightStop(E, f.from.road, stop0, f.cargo), freightStop(E, f.to.road, stop0) }
	-- (a round: a second producer of the same cargo on the way, see collectFrom)
	if extra then table.insert(template.stops, 2, freightStop(E, extra.road, stop0, f.cargo)) end
	local name = AINAME .. " " .. cargoName(E, f.cargo) .. " " .. math.floor(dist(f.from.pos, f.to.pos) / 100) / 10 .. " km"
	act(E, co.id, "makeLineCreateCmd", { n = 4, [1] = name, [2] = C.marshal(api.type.Vec3f.new(0.8, 0.5, 0.1)), [3] = co.ent, [4] = template })
	-- (its growth waits until this line had time to fill, see mayExpand)
	E.G.AI.lastNewAt = E.gameTime()
	E.G.AI.busy = { what = "line " .. name, since = E.G.frames, linesBefore = #myLines(E, co.ent), jr = { kind = "freight", pos = f.from.pos, a = name, b = f.cargo } }
	L(E, "freight line requested: " .. name .. " (industry " .. f.from.e .. " -> " .. tostring(f.to.e or ("town stop " .. tostring(f.to.road.group))) .. ")")
end

-- The best freight route not served yet: a producer, an industry that takes its cargo 0.9 to 5 km away, no other company's line
-- at either, a road between them (looked for once per route, one route per step: the path finding costs). Score: the most the
-- producer can make of that cargo, times the distance (the fare grows with it), less for long routes.
-- (0.5.14) the producers and cargos the company's freight lines already serve, "producer:cargo": one line each (four lines of one
-- company on one farm in the tests of 2026-10-29 shared its cargo four ways). MPFEVER_AIONEPERPRODUCER=0: as before
local function servedByMe(E, lines)
	local mine = {}
	if os.getenv("MPFEVER_AIONEPERPRODUCER") == "0" then return mine end
	for _, l in ipairs(lines or {}) do
		local okf, f = pcall(freightOf, E, l)
		if okf and f and f.from then mine[tostring(f.from.e) .. ":" .. tostring(f.cargo)] = true end
	end
	return mine
end

-- (0.6) the industries the company's freight lines deliver to (a chain's second leg starts there, see the long-term freight)
local function fedByMe(E, lines)
	local fed = {}
	for _, l in ipairs(lines or {}) do
		local okf, f = pcall(freightOf, E, l)
		if okf and f and f.to and f.to.e then fed[f.to.e] = true end
	end
	return fed
end

-- (0.6) whether the towns take a cargo: its category has town districts in this map's economy (food, goods, tools, fuel,
-- construction materials...: economy.cargoCategories[category].landUses, as the game's town growth script reads it); kept for
-- the session
local function townGood(E, cargo)
	local T = E.G.AIT or {}
	T.townGood = T.townGood or {}
	if T.townGood[cargo] ~= nil then return T.townGood[cargo] end
	local yes = false
	pcall(function()
		local api = E.api
		local eco = api.res.economyRep.get(api.res.economyRep.find(api.res.getBaseConfig().economyId))
		local cat = eco.cargoCategories[api.res.cargoTypeRep.get(cargo).category]
		yes = cat ~= nil and cat.landUses ~= nil and #cat.landUses > 0
	end)
	T.townGood[cargo] = yes
	return yes
end

-- (0.6) A long-term route's score (pure, see tests/test_ai_longfreight.py): what its producer could make grown to its most level
-- (its most now times the room of its levels; twice its most when its levels cannot be read), times the distance (the fare grows
-- with it, less for long routes). A producer at its most level scores nothing, unless the company feeds it (a chain's second leg:
-- 1.5 times, the company's cargo comes back as its product); an industry at the other end whose product the towns take, 1.2 times
local function ltScore(most, level, maxLevel, d, fed, townGoodThere)
	local lvl, top = tonumber(level) or 0, tonumber(maxLevel) or 0
	if top > 0 and lvl >= top and not fed then return 0 end
	local room = (top > 0 and lvl > 0) and top / lvl or 2
	local s = ((tonumber(most) or 0) * room + 50) * d / (1 + (d / 3000) ^ 2)
	if fed then s = s * 1.5 end
	if townGoodThere then s = s * 1.2 end
	return s
end

-- (0.6: mode "lt", the long-term route, see ltProject: a raw producer that can still grow, or an industry the company feeds that
-- makes its product now, scored by ltScore, routes given up as long-term lines left out. nil: as before)
local function bestFreight(E, co, lines, mode)
	local api = E.api
	local A = E.G.AI
	local lt = mode == "lt"
	local fed = (lt and os.getenv("MPFEVER_AILTCHAIN") ~= "0") and fedByMe(E, lines) or {}
	A.freightTried = A.freightTried or {}
	-- (a street built to an industry since: the routes that had no road there are looked for again, see roadProject)
	if A.retryInd and E.G.frames >= (A.retryAt or 0) then
		for k, v in pairs(A.freightTried) do
			if v == false and (k:find("^" .. A.retryInd .. ">") or k:find(">" .. A.retryInd .. ":")) then A.freightTried[k] = nil end
		end
		A.retryInd = nil
	end
	local others = servedByOthers(E, co.ent)
	local mine = servedByMe(E, lines)
	local inds = industries(E)
	local cut = A.roadChecked or {}
	local cands = {}
	for _, p in ipairs(inds) do
		if not others[p.road.group] then
			for _, c in ipairs(p.outputs) do
				-- (only a producer that makes that cargo now, or a primary one, see producedOf)
				local prod = producedOf(E, p, c)
				-- (0.6, long-term: a raw producer, or one the company feeds; producedOf gives nothing for the latter until it makes)
				if lt and not (p.primary or fed[p.e]) then prod = nil end
				for _, q in ipairs(prod and inds or {}) do
					-- (an industry found cut off from the streets is left out until a street reaches it, see roadProject)
					if q.e ~= p.e and not others[q.road.group] and cut[p.e] ~= false and cut[q.e] ~= false and takes(E, q, c) then
						local d = dist(p.pos, q.pos)
						local key = p.e .. ">" .. q.e .. ":" .. c
						if d > FREIGHT_MIN and d < LV.freightMax and A.freightTried[key] ~= false and not (A.freightDone or {})[key] and not mine[p.e .. ":" .. c] then
							if lt then
								if not (A.ltFailed or {})[key] then
									local most = 0
									pcall(function() most = api.engine.util.stock.getCargoMaxProductionPerYear(p.stockList, c) or 0 end)
									local tg = false
									for _, oc in ipairs(q.outputs) do if townGood(E, oc) then tg = true end end
									local sc = ltScore(math.max(most, prod), p.level, p.maxLevel, d, fed[p.e] == true, tg)
									if sc > 0 then cands[#cands + 1] = { from = p, to = q, cargo = c, d = d, key = key, score = sc, chain = fed[p.e] == true } end
								end
							else
								cands[#cands + 1] = { from = p, to = q, cargo = c, d = d, key = key, score = (prod + 50) * d / (1 + (d / 3000) ^ 2) }
							end
						end
					end
				end
			end
		end
	end
	table.sort(cands, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.key < b.key end)
	for _, f in ipairs(cands) do
		-- (a line of the company there already: that route is running)
		if lineFor(E, lines, { f.from.road.group, f.to.road.group }) then
			A.freightDone = A.freightDone or {}; A.freightDone[f.key] = true
		elseif A.freightTried[f.key] == true then
			return f
		else
			-- (one path search per step)
			local ok = roadPath(E, f.from, f.to)
			A.freightTried[f.key] = ok
			if ok then L(E, (lt and "long-term " or "") .. "freight route found: " .. cargoName(E, f.cargo) .. ", industry " .. f.from.e .. " -> " .. f.to.e .. " (" .. math.floor(f.d) .. " m)") end
			-- (no road between them: one of the two may be cut off from the streets, see roadProject)
			if not ok then
				A.pathFails = A.pathFails or {}
				if #A.pathFails < 40 then A.pathFails[#A.pathFails + 1] = { from = f.from, to = f.to, score = f.score } end
			end
			return ok and f or "searching"
		end
	end
	return nil
end

-- ---- deliveries to the towns: a producer's cargo to a stop near the town district that wants more of it (its shops or its
-- works). A street stop unloads any cargo of the universal class there; a stop of the company already near that point is taken.
local TOWN_USES = { "COMMERCIAL", "INDUSTRIAL" }

-- what a town's districts want more of: { { cargo, miss, use } } (the district's limit less what it gets)
local function townWants(E, town)
	local api = E.api
	local out = {}
	for _, u in ipairs(TOWN_USES) do
		pcall(function()
			for c, sl in pairs(api.engine.system.townBuildingSystem.getCargoSupplyAndLimit(town, api.type.enum.LandUseType[u])) do
				local miss = math.floor((sl[2] or 0) - (sl[1] or 0))
				if miss > 0 then out[#out + 1] = { cargo = c, miss = miss, use = u } end
			end
		end)
	end
	table.sort(out, function(a, b) if a.miss ~= b.miss then return a.miss > b.miss end return a.cargo < b.cargo end)
	return out
end

-- (0.6) Whether a stock list takes a cargo: one of its input stocks holds that cargo or a set with it. A town building's demand is
-- such a stock list (TOWN_BUILDING.stockList): the cargo a truck unloads at a stop goes to the input stocks of the stop's
-- catchment that take it and have room (Line.StopConfig.forceUnload: "unload cargo at compatible input-stocks"), and the town is
-- paid for and grows with what reaches its buildings (the game's town growth script: OnCalcTicketPrice at a town building's
-- stock list)
local function stockTakes(E, sl, cargo)
	local api = E.api
	local ok, yes = pcall(function()
		local IN = api.type.enum.StockListType.InputStock
		local c = api.engine.getComponent(sl, api.type.ComponentType.STOCK_LIST)
		if not c then return false end
		for k = 1, #c.stocks do
			local st = c.stocks[k]
			if st.type == IN and (st.cargoType == cargo or (st.cargoType < 0 and api.res.cargoTypeRep.hasCargoType(st.cargoTypes, cargo))) then return true end
		end
		return false
	end)
	return ok and yes == true
end

-- (0.6) How many stock lists in reach of a stop take a cargo: the engine's own catchment of the station (its catchables, the
-- entities with a stock list or room for persons it reaches); -1 when it cannot be read
local function stopReaches(E, station, cargo)
	local n = -1
	pcall(function()
		local list = E.api.engine.system.catchmentAreaSystem.getStationCatchables(station, true)
		n = 0
		for _, e in ipairs(list) do if stockTakes(E, e, cargo) then n = n + 1 end end
	end)
	return n
end

-- (0.6) Where a town's buildings that take a cargo stand thickest: the place of the one with the most others that take it within
-- 160 m (a street stop's catchment), and how many; nil when none of the town's buildings takes it. Kept 10 minutes per town and
-- cargo. densest is the pure part (see tests/test_ai_towns.py)
local function densest(pts, radius)
	local best, bn = nil, 0
	for _, a in ipairs(pts) do
		local n = 0
		for _, b in ipairs(pts) do if (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= radius * radius then n = n + 1 end end
		if n > bn or (n == bn and best and (a.x < best.x or (a.x == best.x and a.y < best.y))) then best, bn = a, n end
	end
	return best, bn
end

local function townDropPoint(E, town, cargo)
	local api = E.api
	local A = E.G.AI
	A.dropCache = A.dropCache or {}
	local key = town .. ":" .. cargo
	local c = A.dropCache[key]
	if c and E.G.frames - c.at < 36000 and E.G.frames >= c.at then return c.p, c.n end
	local pts = {}
	pcall(function()
		-- (the map of every town's buildings, read once a minute for all the towns and cargos)
		local T = E.G.AIT or {}
		if not (T.tbMap and T.tbAt and E.G.frames - T.tbAt < 3600 and E.G.frames >= T.tbAt) then
			T.tbMap, T.tbAt = api.engine.system.townBuildingSystem.getTown2BuildingMap(), E.G.frames
		end
		for _, b in ipairs(T.tbMap[town] or {}) do
			local tb = api.engine.getComponent(b, api.type.ComponentType.TOWN_BUILDING)
			if tb and (stockTakes(E, tb.stockList, cargo) or stockTakes(E, b, cargo)) then
				local con = api.engine.getComponent(tb.construction, api.type.ComponentType.CONSTRUCTION)
				local m = con and E.C.marshal(con.transf)
				if m then pts[#pts + 1] = { x = m[13], y = m[14], z = m[15] } end
			end
		end
	end)
	local p, n = densest(pts, 160)
	A.dropCache[key] = { at = E.G.frames, p = p, n = n }
	return p, n
end

-- a truck can drive from an industry's road terminals to the streets around a point
local function roadPathTo(E, a, p)
	local api = E.api
	local na = {}
	for _, t in ipairs(a.road.list) do na[#na + 1] = t.node end
	local ok, path = pcall(function()
		local nb = api.engine.util.octree.findTransportNetworkNodesInCircle(api.type.Vec2f.new(p.x, p.y), 250)
		return api.engine.util.pathfinding.findPathNodeToNode(na, nb, { api.type.enum.TransportMode.TRUCK })
	end)
	return ok and type(path) == "table" and #path > 0
end

-- The best delivery to a town not made yet: a town of 300 people or more, a cargo one of its districts wants, a producer of it
-- 0.9 to 5 km from that district's centre, nobody else's line at the producer, a road between them (one search per step).
-- Score as the routes between industries, times how much the district misses (up to 100).
-- (0.6, MPFEVER_AITOWNCATCH: the delivery's point is where the town's buildings that take the cargo stand thickest, see
-- townDropPoint, not the district's centre, and none when no building of the town takes it; MPFEVER_AITOWNCATCH=0: the centre,
-- as before. Mode "lt": a chain's second leg, from an industry the company feeds only, see ltProject)
local function bestTownFreight(E, co, lines, mode)
	local api = E.api
	local A = E.G.AI
	A.freightTried = A.freightTried or {}
	local others = servedByOthers(E, co.ent)
	local mine = servedByMe(E, lines)
	local inds = industries(E)
	local fed = mode == "lt" and fedByMe(E, lines) or nil
	local catch = os.getenv("MPFEVER_AITOWNCATCH") ~= "0"
	local cands = {}
	-- (0.6, F5: no delivery to a point in a player's territory, its stop would be there, see territoryCheck)
	local terr = territoryCheck(E)
	for _, t in ipairs(townsBySize(E)) do
		if t.size >= 300 then
			for _, w in ipairs(townWants(E, t.e)) do
				local p = centre(E, t.e, api.type.enum.LandUseType[w.use])
				if p and catch then p = townDropPoint(E, t.e, w.cargo) end
				if p and terr and terr(p.x, p.y) then p = nil end
				if p then
					for _, ind in ipairs(inds) do
						if not others[ind.road.group] and (A.roadChecked or {})[ind.e] ~= false
							and (not fed or (fed[ind.e] and not (A.ltFailed or {})[ind.e .. ">town" .. t.e .. ":" .. w.cargo])) then
							for _, c in ipairs(ind.outputs) do
								if c == w.cargo and producedOf(E, ind, c) and not mine[ind.e .. ":" .. c] then
									local d = dist(ind.pos, p)
									local key = ind.e .. ">town" .. t.e .. ":" .. c
									if d > FREIGHT_MIN and d < LV.freightMax and A.freightTried[key] ~= false and not (A.freightDone or {})[key] then
										local prod = producedOf(E, ind, c) or 0
										cands[#cands + 1] = { from = ind, town = t.e, use = w.use, p = p, cargo = c, d = d, key = key,
											score = (prod + 50) * d / (1 + (d / 3000) ^ 2) * math.min(w.miss, 100) / 100 }
									end
								end
							end
						end
					end
				end
			end
		end
	end
	table.sort(cands, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.key < b.key end)
	for _, f in ipairs(cands) do
		if A.freightTried[f.key] == true then return f end
		local ok = roadPathTo(E, f.from, f.p)
		A.freightTried[f.key] = ok
		if ok then L(E, "town delivery found: " .. cargoName(E, f.cargo) .. ", industry " .. f.from.e .. " -> " .. townName(E, f.town) .. " " .. f.use .. " (" .. math.floor(f.d) .. " m)") end
		return ok and f or "searching"
	end
	return nil
end

-- one step of the best town delivery: the garage, the stop in town, the line, its first two trucks. True when it acted (or waits)
-- (0.6: mode "lt", a chain's second leg as the long-term line, see ltProject)
local function townFreightProject(E, co, stops, lines, vehicles, money, mode)
	local A = E.G.AI
	local f = bestTownFreight(E, co, lines, mode)
	if f == "searching" then return "searching" end
	if not f then return false end
	-- (a garage that is there already, the company's own first: none is built near an industry, whose ground is often uneven: a
	-- garage built on a slope there stopped both games for good, the engine never ending its build. MPFEVER_AIFREIGHTGARAGE=1: built)
	local g
	if os.getenv("MPFEVER_AIFREIGHTGARAGE") == "1" then g = garageFor(E, co, f.from.pos, money, "industry " .. f.from.e) else g = garagesNear(E, co.ent, f.from.pos, 5000)[1] end
	if g == "building" then return true end
	if not g then
		L(E, "no garage for the town delivery " .. f.key .. ": left" .. (G_HOLD(E, f.key) and " for now" or ""))
		A.freightTried[f.key] = false
		return false
	end
	local s = stopAt(stops, f.p)
	if not s then
		if money < RESERVE + 60000 then return true end
		if stopNear(E, co, stops, f.p, f.town .. ":" .. f.use) then return true end
		L(E, "no street for a stop near the " .. f.use .. " centre of " .. townName(E, f.town) .. ": delivery left")
		A.freightTried[f.key] = false
		return false
	end
	local road = groupRoad(E, s.group)
	if not road then A.freightTried[f.key] = false; return false end
	local line = lineFor(E, lines, { f.from.road.group, s.group })
	if line and #line.groups ~= 2 then line = nil end
	-- (a line given up there before: that delivery is left)
	if not line and (A.badPair or {})[math.min(f.from.road.group, s.group) .. "-" .. math.max(f.from.road.group, s.group)] then A.freightTried[f.key] = false; return false end
	if not line then
		-- (0.6, MPFEVER_AITOWNCATCH) the stop must reach buildings that take the cargo (the engine's catchment of the stop): in a
		-- test of 0.5.14 a truck full of vegetables at a town stop near the shops unloaded nothing and earned nothing
		if os.getenv("MPFEVER_AITOWNCATCH") ~= "0" then
			local n = stopReaches(E, s.station, f.cargo)
			L(E, "town delivery " .. f.key .. ": " .. n .. " building(s) in reach of the stop take " .. cargoName(E, f.cargo) .. (n == 0 and ": delivery left" or ""))
			if n == 0 then A.freightTried[f.key] = false; return false end
		end
		if money < RESERVE + 2 * (A.truckCost or BUS_COST) then return true end
		createFreightLine(E, co, { from = f.from, to = { road = road, pos = s.pos }, cargo = f.cargo })
		if mode == "lt" then
			local prod0 = 0
			pcall(function() prod0 = E.api.engine.util.stock.getCargoProducedPerYear(f.from.stockList, f.cargo) or 0 end)
			A.ltPending = { key = f.key, groups = { f.from.road.group, s.group }, from = f.from.e, stockList = f.from.stockList, cargo = f.cargo,
				budget = A.ltBudgetNext, prod0 = prod0, frame = E.G.frames, chain = true }
			L(E, string.format("long-term line asked: %s from industry %d to %s (the second leg of its chain), budget %d", cargoName(E, f.cargo), f.from.e,
				townName(E, f.town), math.floor(A.ltBudgetNext or 0)))
		end
		return true
	end
	local n = 0
	for _, v in ipairs(vehicles) do if v.line == line.e then n = n + 1 end end
	if n < ((os.getenv("MPFEVER_AIFLEET") ~= "0") and 1 or 2) and not dropped(E, line.e) then
		if money < RESERVE + (A.truckCost or BUS_COST) then return true end
		A.forLine = line.e
		buyTruck(E, co, g.depot, f.cargo)
		return true
	end
	A.freightDone = A.freightDone or {}; A.freightDone[f.key] = true
	return false
end

-- A round (0.5.13): another producer of the route's cargo within 1.5 km of the first, no line at it yet (nobody's, the company's
-- neither), a road from it to the industry that takes the cargo: its stop goes between the two (one path search per step, kept).
-- Returns that industry, nil, or "searching" (a search was made this step). MPFEVER_AIROUND=0: no rounds.
local function collectFrom(E, co, f, lines)
	if os.getenv("MPFEVER_AIROUND") == "0" then return nil end
	local A = E.G.AI
	A.roundTried = A.roundTried or {}
	local others = servedByOthers(E, co.ent)
	local mine = {}
	for _, l in ipairs(lines) do for _, g in ipairs(l.groups) do mine[g] = true end end
	local best, bd
	for _, p in ipairs(industries(E)) do
		if p.e ~= f.from.e and p.e ~= f.to.e and not others[p.road.group] and not mine[p.road.group] then
			local makes = false
			for _, c in ipairs(p.outputs) do if c == f.cargo and producedOf(E, p, c) then makes = true end end
			local d = dist(p.pos, f.from.pos)
			if makes and d < 1500 and dist(p.pos, f.to.pos) < LV.freightMax and A.roundTried[f.key .. "+" .. p.e] ~= false and (not bd or d < bd) then
				best, bd = p, d
			end
		end
	end
	if not best then return nil end
	local key = f.key .. "+" .. best.e
	if A.roundTried[key] == true then return best end
	local ok = roadPath(E, best, f.to)
	A.roundTried[key] = ok
	if ok then L(E, "round: industry " .. best.e .. " joins the route " .. f.key .. " (" .. math.floor(bd) .. " m from the first)") end
	return ok and best or "searching"
end

-- one step of the best freight route between two industries: its garage, its line, its first two trucks. True when it acted
-- (0.6: mode "lt", the long-term line, see ltProject: its route by bestFreight's long-term rules, no round, and the line asked for
-- is noted, A.ltPending, to be taken as the long-term line once it is there, see ltSync)
local function industryProject(E, co, lines, vehicles, money, mode)
	local A = E.G.AI
	local f = bestFreight(E, co, lines, mode)
	if f == "searching" then return "searching" end
	if not f then return false end
	-- (a garage that is there already, the company's own first: none is built near an industry, whose ground is often uneven: a
	-- garage built on a slope there stopped both games for good, the engine never ending its build. MPFEVER_AIFREIGHTGARAGE=1: built)
	local g
	if os.getenv("MPFEVER_AIFREIGHTGARAGE") == "1" then g = garageFor(E, co, f.from.pos, money, "industry " .. f.from.e) else g = garagesNear(E, co.ent, f.from.pos, 5000)[1] end
	if g == "building" then return true end
	if not g then
		L(E, "no garage for the freight route " .. f.key .. ": route left" .. (G_HOLD(E, f.key) and " for now" or ""))
		A.freightTried[f.key] = false
		return false
	end
	local line = lineFor(E, lines, { f.from.road.group, f.to.road.group })
	-- (a line given up there before: that route is left)
	if not line and (A.badPair or {})[math.min(f.from.road.group, f.to.road.group) .. "-" .. math.max(f.from.road.group, f.to.road.group)] then A.freightTried[f.key] = false; return false end
	if not line then
		if money < RESERVE + 2 * (A.truckCost or BUS_COST) then return true end
		-- (a second producer of that cargo near the first: one round for both)
		local extra = mode ~= "lt" and collectFrom(E, co, f, lines) or nil
		if extra == "searching" then return "searching" end
		createFreightLine(E, co, f, extra)
		if mode == "lt" then
			local prod0 = 0
			pcall(function() prod0 = E.api.engine.util.stock.getCargoProducedPerYear(f.from.stockList, f.cargo) or 0 end)
			A.ltPending = { key = f.key, groups = { f.from.road.group, f.to.road.group }, from = f.from.e, stockList = f.from.stockList, cargo = f.cargo,
				budget = A.ltBudgetNext, prod0 = prod0, frame = E.G.frames, chain = f.chain }
			L(E, string.format("long-term line asked: %s from industry %d (makes %d a year, level %s of %s)%s, budget %d", cargoName(E, f.cargo), f.from.e,
				math.floor(prod0), tostring(f.from.level), tostring(f.from.maxLevel), f.chain and ", the second leg of its chain" or "", math.floor(A.ltBudgetNext or 0)))
		end
		return true
	end
	local n = 0
	for _, v in ipairs(vehicles) do if v.line == line.e then n = n + 1 end end
	if n < ((os.getenv("MPFEVER_AIFLEET") ~= "0") and 1 or 2) and not dropped(E, line.e) then
		if money < RESERVE + (A.truckCost or BUS_COST) then return true end
		A.forLine = line.e
		buyTruck(E, co, g.depot, f.cargo)
		return true
	end
	A.freightDone = A.freightDone or {}; A.freightDone[f.key] = true
	return false
end

-- ---- roads (0.5.13): an industry no truck reaches (a route of it found no road) gets a street from the free end of its own
-- streets to the nearest town street node within 900 m: straight, in pieces of 80 m at most, the town street's template, owned
-- by the company, a dry run first; built as the street tool builds (the same fields as the autotest's roads, see the bridge's
-- buildMatrixProposal), for the company. The routes of that industry are looked for again a little later. MPFEVER_AIROADS=0: none.
local CTX_ROAD = 35

local function nearestTownCentre(E, p)
	local best, bd
	for _, t in ipairs(townsBySize(E)) do
		local c = centre(E, t.e, E.api.type.enum.LandUseType.RESIDENTIAL)
		if c then local d = dist(c, p); if not bd or d < bd then best, bd = c, d end end
	end
	return best
end

-- the street proposal from node n0 (at p0) to the town node n1 (at p1), with the town segment tc's template; nil if no lanes
local function roadProposal(E, co, n0, p0, n1, p1, tc)
	local api, C = E.api, E.C
	local lanes = C.templateLanes(tc.roadTemplate)
	if not lanes then return nil end
	local len = dist(p0, p1)
	local k = math.max(1, math.ceil(len / 80))
	local pts = { p0 }
	for i = 1, k - 1 do
		local x, y = p0.x + (p1.x - p0.x) * i / k, p0.y + (p1.y - p0.y) * i / k
		pts[#pts + 1] = { x = x, y = y, z = E.groundZ(x, y, p0.z + (p1.z - p0.z) * i / k) }
	end
	pts[#pts + 1] = p1
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local nodes, edges = {}, {}
	local ids = { n0 }
	for i = 2, k do
		local ne = api.type.NodeAndEntity.new()
		ne.entity = -i
		local bn = ne.comp
		bn.position = api.type.Vec3f.new(pts[i].x, pts[i].y, pts[i].z)
		ne.comp = bn
		nodes[#nodes + 1] = ne
		ids[i] = -i
	end
	ids[k + 1] = n1
	for i = 1, k do
		local a, b = pts[i], pts[i + 1]
		local e = api.type.SegmentAndEntity.new()
		e.entity = -100 - i
		e.type = 0
		local c = e.comp
		c.laneConfigs = lanes
		c.node0, c.node1 = ids[i], ids[i + 1]
		local t = api.type.Vec3f.new(b.x - a.x, b.y - a.y, b.z - a.z)
		c.tangent0, c.tangent1 = t, t
		c.type, c.typeIndex = 0, -1
		c.position0 = api.type.Vec3f.new(a.x, a.y, a.z)
		c.position1 = api.type.Vec3f.new(b.x, b.y, b.z)
		c.roadTemplate, c.roadStyle, c.roadType = tc.roadTemplate, tc.roadStyle, tc.roadType
		e.comp = c
		local se = e.streetEdge
		se.precedenceNode0, se.precedenceNode1 = 2, 2
		e.streetEdge = se
		local po = e.playerOwned
		if po == nil then po = C.newOf("PlayerOwned") end
		po.player = co.ent
		e.playerOwned = po
		edges[#edges + 1] = e
	end
	if #nodes > 0 then ssp.nodesToAdd = nodes end
	ssp.edgesToAdd = edges
	sp.streetProposal = ssp
	return sp
end

-- one street to an industry cut off from the streets: true when it was asked for
local function connectIndustry(E, co, ind)
	local api, R = E.api, E.R
	local A = E.G.AI
	local con = api.engine.getComponent(ind.con, api.type.ComponentType.CONSTRUCTION)
	local segmap = api.engine.system.streetSystem.getNode2SegmentMap()
	-- the free ends of its own streets
	local ends, seen = {}, {}
	for k = 1, #con.frozenEdges do
		local e = con.frozenEdges[k]
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if be and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) then
			for _, nd in ipairs({ be.node0, be.node1 }) do
				local p = not seen[nd] and #(segmap[nd] or {}) == 1 and E.nodePosition(nd)
				seen[nd] = true
				if p then ends[#ends + 1] = { node = nd, p = p } end
			end
		end
	end
	if #ends == 0 then L(E, "road: industry " .. ind.e .. " has no free street end"); return false end
	-- the town street nodes near them, the nearest pairs first
	local pairsList = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) and tostring(c.roadTemplate):find("/town/", 1, true) then
			local okC, cn = pcall(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end)
			if not (okC and type(cn) == "number" and cn >= 0) then
				for _, nd in ipairs({ c.node0, c.node1 }) do
					local q = #(segmap[nd] or {}) <= 3 and E.nodePosition(nd)
					if q then
						for _, en in ipairs(ends) do
							local d = dist(en.p, q)
							if d > 30 and d < 900 then pairsList[#pairsList + 1] = { en = en, node = nd, q = q, c = c, d = d } end
						end
					end
				end
			end
		end
	end
	table.sort(pairsList, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.node < b.node end)
	-- (0.6: without the buildings gathered, see keepBuildings: the dry run refuses a street through a house, and the build is sent
	-- with those flags, which every game replays. Before, the dry run took the houses in its way as gathered, no error, and the
	-- street would have taken them down)
	local keep = keepBuildings()
	local bits = keep and withoutBuildings(CTX_ROAD) or CTX_ROAD
	local ctx = context(E, co.ent, bits)
	-- (0.6: a street refused for its price only, see spendOk: the next pair is tried, and "wait" when none was built, roadProject
	-- tries the industry again later. Before, the first refusal gave the industry up for the whole session)
	local tooDear = false
	for i = 1, math.min(4, #pairsList) do
		local pr = pairsList[i]
		local okp, sp = pcall(roadProposal, E, co, pr.en.node, pr.en.p, pr.node, pr.q, pr.c)
		if okp and sp then
			local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(sp, ctx) end)
			local why = ""
			if okd and pd then pcall(function() why = E.C.ser(E.C.marshal(pd.errorState.messages)) end) end
			local free = okd and pd and #pd.errorState.messages == 0 and not pd.errorState.critical
			local hits = (free and keep) and buildingsHit(E, pd) or 0
			if free and hits > 0 then
				why = hits .. " town building(s) in its way"
			elseif free then
				-- (0.6: never under the floor, see spendOk: the dry run's price)
				local cost = 0
				pcall(function() cost = tonumber(pd.costs) or 0 end)
				if not spendOk(E, co, cost, "road to industry " .. ind.e) then tooDear = true; goto nextPair end
				local mid = { x = (pr.en.p.x + pr.q.x) / 2, y = (pr.en.p.y + pr.q.y) / 2, z = (pr.en.p.z + pr.q.z) / 2 }
				L(E, string.format("road to industry %d: %.0f m from node %d to the town node %d", ind.e, pr.d, pr.en.node, pr.node))
				build(E, co.id, api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true, true), "road to industry " .. ind.e, bits,
					{ kind = "road", pos = mid })
				return true
			end
			L(E, "road to industry " .. ind.e .. " (" .. math.floor(pr.d) .. " m): dry run refused " .. why:sub(1, 200))
		elseif not okp then
			L(E, "road to industry " .. ind.e .. ": " .. tostring(sp):sub(1, 200))
		end
		::nextPair::
	end
	if tooDear then return "wait" end
	return false
end

-- one step of the roads: the industries of the routes that found no road, the best route first; is each one cut off from the
-- streets (one path search per step)? A street to the first one that is. True when it acted (or searched)
local function roadProject(E, co, money)
	if os.getenv("MPFEVER_AIROADS") == "0" then return false end
	local A = E.G.AI
	if not A.pathFails or #A.pathFails == 0 or money < RESERVE + 400000 then return false end
	-- (0.6: a street refused for its price waits a minute before its industry is tried again, see below)
	if A.roadWaitAt and E.G.frames < A.roadWaitAt then return false end
	A.roadChecked = A.roadChecked or {}
	A.roadDone = A.roadDone or {}
	table.sort(A.pathFails, function(a, b) return a.score > b.score end)
	local waits, tried = false, {}
	for _, pf in ipairs(A.pathFails) do
		for _, ind in ipairs({ pf.from, pf.to }) do
			if not A.roadDone[ind.e] and not tried[ind.e] then
				tried[ind.e] = true
				if A.roadChecked[ind.e] == nil then
					local c = nearestTownCentre(E, ind.pos)
					A.roadChecked[ind.e] = c == nil or roadPathTo(E, ind, c)
					if not A.roadChecked[ind.e] then L(E, "industry " .. ind.e .. " is cut off from the streets") end
					return "searching"
				end
				if A.roadChecked[ind.e] == false then
					A.roadDone[ind.e] = true
					local r = connectIndustry(E, co, ind)
					if r == true then
						A.retryInd, A.retryAt = ind.e, E.G.frames + 1800
						A.roadChecked[ind.e] = nil
						return true
					end
					-- (0.6: refused for its price only, see connectIndustry: not given up, tried again once it has the money)
					if r == "wait" then A.roadDone[ind.e] = nil; waits = true end
				end
			end
		end
	end
	-- (its routes kept while a street waits for the money: the industry is tried again in a minute)
	if waits then A.roadWaitAt = E.G.frames + 3600; return false end
	A.pathFails = {}
	return false
end

-- the next freight step: deliveries to towns and routes between industries in turn (the kind the company has fewer lines of
-- first, the other one when it has nothing to do). Between industries only with MPFEVER_AITOWNFREIGHT=0 (off by default in 0.5.14
-- and 0.6, on again in 0.6.2).
local function freightProject(E, co, stops, lines, vehicles, money)
	-- (the routes left for want of a garage are tried again once their wait is over, see G_HOLD)
	local A = E.G.AI
	if A.freightHold and os.getenv("MPFEVER_AIRETRY") ~= "0" then
		local now = E.gameTime()
		for k, t in pairs(A.freightHold) do
			if now >= t or t - now > 2 * 720000 then A.freightHold[k] = nil; if A.freightTried and A.freightTried[k] == false then A.freightTried[k] = nil end end
		end
	end
	local nTown, nInd = 0, 0
	for _, l in ipairs(lines) do
		local f = freightOf(E, l)
		if f and f.town then nTown = nTown + 1 elseif f then nInd = nInd + 1 end
	end
	-- (0.5.14: off unless MPFEVER_AITOWNFREIGHT=1. In the tests a town stop took none of the cargo: the trucks stayed full, earned
	-- nothing and cost their running costs; on before. 0.6.2: on again: the stop is now placed where the town's buildings take
	-- the cargo (MPFEVER_AITOWNCATCH, 0.6), and a 40-minute test at x4 had 16 deliveries to towns, producers shipping 150 to 172 a
	-- year through them, the company that made most of them 521k ahead over two months, both games in sync. MPFEVER_AITOWNFREIGHT=0:
	-- off)
	local towns = os.getenv("MPFEVER_AITOWNFREIGHT") ~= "0"
	if towns and nTown <= nInd then
		return townFreightProject(E, co, stops, lines, vehicles, money) or industryProject(E, co, lines, vehicles, money) or roadProject(E, co, money)
	end
	return industryProject(E, co, lines, vehicles, money) or (towns and townFreightProject(E, co, stops, lines, vehicles, money)) or roadProject(E, co, money)
end

-- ------------------------------------------------------------------ long-term freight (0.6): its lines
-- The long-term lines, at every look (see LT): the line asked for (A.ltPending) taken once it is there. After a load nothing of
-- the module is kept: the company's oldest freight line from a raw producer, or from an industry it feeds, is taken again, its age
-- from its first truck's purchase and its spending from the line's own accounts since then, so that its budget and its time stay
-- bounded across loads and resynchronisations (its proof time starts again). Every two game months each line in its investment
-- is sampled (its result over those months, its producer's production, its income against its trucks' running costs) and judged
-- (ltJudge): "paid", a line like the others; "end", the fleet rules take it (a losing line), the route is not tried again and the
-- next long-term line waits LT.cooldownY.
local function ltKey(f)
	return tostring(f.from and f.from.e) .. ">" .. tostring(f.to and (f.to.e or ("g" .. tostring(f.to.road and f.to.road.group)))) .. ":" .. tostring(f.cargo)
end

local function ltSync(E, co, lines, vehicles, money)
	if not ltOn() then return end
	local api = E.api
	local A = E.G.AI
	local now = E.gameTime()
	local Y = yearOf(E)
	A.lt = A.lt or {}
	local live = {}
	for _, l in ipairs(lines) do live[l.e] = l end
	for k, lt in pairs(A.lt) do
		-- (gone, or its id taken by another line since: MPFever gives a new entity the smallest free id)
		local l = live[k]
		local f = l and lt.state == "invest" and select(2, pcall(freightOf, E, l)) or nil
		if not l or (lt.state == "invest" and not (type(f) == "table" and f.from and f.from.e == lt.from)) then A.lt[k] = nil end
	end
	local P = A.ltPending
	if P then
		local l = lineFor(E, lines, P.groups)
		if l and not A.lt[l.e] then
			A.lt[l.e] = { key = P.key, from = P.from, stockList = P.stockList, cargo = P.cargo, chain = P.chain, born = now, budget = P.budget or LT.min,
				spent = 0, prod0 = P.prod0, proofFrom = now, at = now, samples = {}, state = "invest" }
			A.ltPending = nil
			L(E, string.format("long-term line %d under way: budget %d, %d game year(s) at most, its producer makes %d a year", l.e, math.floor(A.lt[l.e].budget),
				LT.horizonY, math.floor(tonumber(P.prod0) or 0)))
		elseif E.G.frames < (P.frame or 0) or E.G.frames - (P.frame or 0) > 7200 then
			-- (not asked again: a line refused every 2 minutes)
			A.ltPending = nil
			A.ltFailed = A.ltFailed or {}; A.ltFailed[P.key or ""] = true
			L(E, "the long-term line asked for was not made: its route is left")
		end
	end
	-- (after a load: its oldest line from a raw producer or an industry it feeds, unless its time is up)
	if not A.ltInit then
		A.ltInit = true
		local derive = os.getenv("MPFEVER_AILTLOAD") ~= "0"
		local any = A.ltPending ~= nil
		for _, lt in pairs(A.lt) do if lt.state == "invest" then any = true end end
		if not any then
			local fed = fedByMe(E, lines)
			local best, bt
			for _, l in ipairs(lines) do
				local okf, f = pcall(freightOf, E, l)
				if okf and f and f.from and (f.from.primary or fed[f.from.e]) then
					for _, v in ipairs(vehicles) do
						if v.line == l.e then
							pcall(function()
								local t = api.engine.getComponent(v.e, api.type.ComponentType.TRANSPORT_VEHICLE).transportVehicleConfig.vehicles[1].purchaseTime
								if type(t) == "number" and t <= now and (not bt or t < bt or (t == bt and l.e < best.l.e)) then best, bt = { l = l, f = f }, t end
							end)
						end
					end
				end
			end
			if best and now - bt < LT.horizonY * Y then
				local spent, prod0 = 0, 0
				pcall(function() spent = -(api.engine.util.finance.calculateBalance({ best.l.e }, bt, now, true) or 0) end)
				pcall(function() prod0 = api.engine.util.stock.getCargoProducedPerYear(best.f.from.stockList, best.f.cargo) or 0 end)
				local budget = math.max(LT.min, ltBudget(money - (A.loanCash or 0)) or 0)
				-- (0.6: what ltEnd remembers, the routes given up and the time the next one waits, is not in the savegame. A line whose
				-- loss since its first truck already reached the budget it would get was given up before the load: not taken again
				-- with a fresh budget, counted as given up. MPFEVER_AILTLOAD=0: taken again, as before)
				if derive and spent >= budget then
					ltEnd(A, { key = ltKey(best.f) }, "given up before the load", now, Y)
					A.lt[best.l.e] = { key = ltKey(best.f), from = best.f.from.e, state = "ended", why = "given up before the load" }
					L(E, string.format("long-term line %d not taken again after a load: %d lost since its first truck, its budget would be %d", best.l.e, math.floor(spent), budget))
				else
					A.lt[best.l.e] = { key = ltKey(best.f), from = best.f.from.e, stockList = best.f.from.stockList, cargo = best.f.cargo, chain = fed[best.f.from.e] == true,
						born = bt, budget = budget, spent = spent, prod0 = prod0, proofFrom = now, at = now, samples = {}, state = "invest" }
					L(E, string.format("long-term line %d taken again after a load: %d day(s) old, %d spent of a budget of %d", best.l.e, math.floor((now - bt) / 4000),
						math.floor(spent), budget))
				end
			end
			-- (0.6, the same: none in its investment after the load, and a freight line of the company that lost money since its first
			-- truck, the line given up before the load perhaps: the next long-term line waits LT.cooldownY from the load, not at once)
			if derive and not A.ltNextAt then
				local adopted = false
				for _, lt in pairs(A.lt) do if lt.state == "invest" then adopted = true end end
				if not adopted then
					for _, l in ipairs(lines) do
						local okf, f = pcall(freightOf, E, l)
						local first
						for _, v in ipairs(vehicles) do
							if okf and f and v.line == l.e then
								pcall(function()
									local t = api.engine.getComponent(v.e, api.type.ComponentType.TRANSPORT_VEHICLE).transportVehicleConfig.vehicles[1].purchaseTime
									if type(t) == "number" and t <= now and (not first or t < first) then first = t end
								end)
							end
						end
						local lost = 0
						if first then pcall(function() lost = -(api.engine.util.finance.calculateBalance({ l.e }, first, now, true) or 0) end) end
						if lost > 0 then
							A.ltNextAt = now + LT.cooldownY * Y
							L(E, "after a load: freight line " .. l.e .. " lost " .. math.floor(lost) .. " since its first truck, the next long-term line waits")
							break
						end
					end
				end
			end
		end
	end
	local keys = {}
	for e in pairs(A.lt) do keys[#keys + 1] = e end
	table.sort(keys)
	for _, e in ipairs(keys) do
		local lt = A.lt[e]
		if lt.state == "invest" then
			if lt.at > now then lt.at = now end
			if now - lt.at >= LT.sample then
				local bal, run, prod = 0, 0, 0
				pcall(function() bal = api.engine.util.finance.calculateBalance({ e }, lt.at, now, true) or 0 end)
				for _, v in ipairs(vehicles) do
					if v.line == e then
						local okc, c = pcall(function() return api.engine.util.vehicle.getRunningCost(v.e) end)
						if okc and type(c) == "number" then run = run + c end
					end
				end
				pcall(function() prod = api.engine.util.stock.getCargoProducedPerYear(lt.stockList, lt.cargo) or 0 end)
				local runW = run * (now - lt.at) / Y
				local ratio = runW > 0 and (bal + runW) / runW or nil
				lt.spent = (lt.spent or 0) - bal
				lt.samples[#lt.samples + 1] = { t = now, bal = bal, prod = tonumber(prod) or 0, ratio = ratio }
				while #lt.samples > LT.keep do table.remove(lt.samples, 1) end
				lt.at = now
				local v, why = ltJudge(lt, now, { horizon = LT.horizonY * Y, proof = LT.proofY * Y, grow = LT.grow }, os.getenv("MPFEVER_AILTTREND") ~= "0")
				L(E, string.format("long-term line %d: %d over its last months, %d spent of its budget %d, its producer makes %d a year (%d at its start), %s of its trucks' running costs: %s%s",
					e, math.floor(bal), math.floor(lt.spent), math.floor(lt.budget or 0), math.floor(tonumber(prod) or 0), math.floor(tonumber(lt.prod0) or 0),
					ratio and (math.floor(ratio * 100) .. "%") or "?", v, why and (" (" .. why .. ")") or ""))
				if v == "paid" then
					lt.state = "paid"
				elseif v == "end" then
					ltEnd(A, lt, why, now, Y)
				end
			end
		end
	end
end

-- (0.6) A long-term line to start when the company has none in its investment: once its first lines run (the level's bootstrap),
-- while it may grow (see mayExpand, step) and can afford the budget (ltBudget) and a truck besides its reserve; not within
-- LT.cooldownY of the last one given up. The best route of bestFreight's long-term rules (a raw producer that can grow, or the
-- second leg of its chain to an industry); also a chain's second leg to a town (not with MPFEVER_AITOWNFREIGHT=0). Returns as
-- industryProject (true: it acted)
local function ltProject(E, co, stops, lines, vehicles, money)
	if not ltOn() then return false end
	local A = E.G.AI
	if A.ltPending then return false end
	for _, lt in pairs(A.lt or {}) do if lt.state == "invest" then return false end end
	local now = E.gameTime()
	local Y = yearOf(E)
	if A.ltNextAt and now < A.ltNextAt and A.ltNextAt - now <= 8 * LT.cooldownY * Y then return false end
	if #lines < (LV.bootstrap or 0) then return false end
	local spare = money - (A.loanCash or 0)
	local budget = ltBudget(spare)
	local truck = A.truckCost or BUS_COST
	if not budget or spare < RESERVE + truck + budget then
		if E.G.frames - (A.ltSaid or -100000) > 3600 then
			A.ltSaid = E.G.frames
			L(E, "long-term freight waits: " .. (budget and string.format("its budget %d and a truck besides its reserve %d (money to spare %d)", budget, math.floor(RESERVE), math.floor(spare))
				or string.format("its money to spare %d gives no budget of %d yet", math.floor(spare), LT.min)))
		end
		return false
	end
	A.ltBudgetNext = budget
	local r = industryProject(E, co, lines, vehicles, money, "lt")
	if r == false and os.getenv("MPFEVER_AITOWNFREIGHT") ~= "0" and os.getenv("MPFEVER_AILTCHAIN") ~= "0" then
		r = townFreightProject(E, co, stops, lines, vehicles, money, "lt")
	end
	return r
end

-- ------------------------------------------------------------------ trains (0.6.4)
-- A producer far from the industry that takes its cargo (RL.MIN to RL.MAX, beyond the trucks' reach) gets a railway: a cargo
-- station near each of the two industries (the modular station of the game, one track, its platforms within reach of the
-- industry), a track between the two stations, a depot behind the first one joined to it, a line, a train (the strongest
-- locomotive that needs no catenary and the wagons that carry the most of that cargo). As everything else here, it keeps no
-- knowledge of its own: each look reads the company's stations, tracks, depots and lines from the world and does the next thing
-- missing (a load or a resynchronisation in the middle leaves nothing behind). Each build is a build of the company, as a
-- player's: held, shipped, replayed by every game. Only with plenty of money: a line costs about 4 million in 1970.
-- MPFEVER_AIRAIL=0: no trains, as before.
function RL.on() return os.getenv("MPFEVER_AIRAIL") ~= "0" end

-- the open track of a year (simple before 1930), its style, and the station's own track module
function RL.track(year)
	local kind = year >= 1930 and "standard" or "simple"
	return "::/infrastructure/track/" .. kind .. "/" .. kind .. ".street_template", "::/infrastructure/track/" .. kind .. "/" .. kind .. ".street",
		"::/trainstation___/infrastructure/track/" .. kind .. "/" .. kind .. ".street_template"
end

-- the station's parameters as the game's own template makes them (modular_station.script's createTemplateFn: a cargo station,
-- one track, `length` platforms of 40 m less one, its main building)
function RL.stationParams(year, length)
	local era = year >= 1990 and "c" or year >= 1950 and "b" or "a"
	local _, _, module = RL.track(year)
	local s, e = -math.floor(length / 2), math.ceil(length / 2)
	local mods = {}
	local k = (e - s) % 2 == 0 and 0 or 2
	mods[3400000 + 10 * k] = { name = "::/stations/rail/modular_station/main_building_1_cargo.module", variant = 0 }
	-- (its two side buildings from 3 platforms on, as the template's level 1 has them)
	if length > 2 then
		mods[3400000 + 10 * (k + 1) + 5] = { name = "::/stations/rail/modular_station/side_building_1_cargo.module", variant = 0 }
		mods[3400000 + 10 * (k - 2) + 5] = { name = "::/stations/rail/modular_station/side_building_1_cargo.module", variant = 0 }
	end
	for j = s, e do
		mods[6400000 + 10 * j] = { name = "::/stations/rail/modular_station/platform_cargo_era_" .. era .. ".module", variant = 0 }
		mods[8402000 + 10 * j] = { name = module, variant = 0 }
	end
	return { length = length, seed = 0, specialization = 1, trackType = year >= 1930 and 2 or 1, catenary = 1, tracks = 1, year = year, modules = mods }
end

function RL.transf(E, x, y, z, a)
	local V = E.api.type.Vec4f.new
	local c, s = math.cos(a), math.sin(a)
	return E.api.type.Mat4f.new(V(c, s, 0, 0), V(-s, c, 0, 0), V(0, 0, 1, 0), V(x, y, z, 1))
end

-- a dry run of a construction of the company at x, y turned by a: free (no error), its proposal and context, its price, why not
function RL.dry(E, co, file, params, x, y, a)
	local api = E.api
	-- (a name of its own: the nearest town's and the company's. Built with none, it was named "" on the builder's game and after
	-- its file on the others, a difference of the names at every station, corrected by the host's names)
	local name = AINAME
	pcall(function()
		local best, bd
		for _, t in ipairs(townsBySize(E)) do
			local c = centre(E, t.e, E.api.type.enum.LandUseType.RESIDENTIAL)
			if c then local d = (c.x - x) ^ 2 + (c.y - y) ^ 2; if not bd or d < bd then best, bd = t.e, d end end
		end
		if best then name = townName(E, best) .. " " .. AINAME end
	end)
	local z = E.groundZ(x, y, 0)
	local sp = api.type.SimpleProposal.new()
	local ce = api.type.SimpleProposal.ConstructionEntity.new()
	ce.fileName = file
	ce.params = params
	ce.transf = RL.transf(E, x, y, z, a)
	ce.playerEntity = co.ent
	pcall(function() ce.name = name end)
	sp.constructionsToAdd = { ce }
	local bits = keepBuildings() and withoutBuildings(CTX_DEPOT) or CTX_DEPOT
	local ctx = context(E, co.ent, bits)
	local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(sp, ctx) end)
	if not (okd and pd) then return false, nil, nil, nil, "dry run failed: " .. tostring(pd), bits end
	local why, cost = "", nil
	pcall(function() why = E.C.ser(E.C.marshal(pd.errorState.messages)) .. RL.collides(E, pd) end)
	pcall(function() cost = tonumber(pd.costs) end)
	local free = #pd.errorState.messages == 0 and not pd.errorState.critical
	if free and keepBuildings() and buildingsHit(E, pd) > 0 then free, why = false, "town buildings in its way" end
	return free, sp, ctx, cost, why, bits
end

-- what a dry run collides with, for the logs: " with <kind> <entity>" for its first colliding entity, "" when none
function RL.collides(E, pd)
	local api = E.api
	local out = ""
	pcall(function()
		local x = pd.collisionInfo.collisionEntities[1]
		if x then
			local ce = x.entity
			local kind = api.engine.getComponent(ce, api.type.ComponentType.BASE_EDGE_STREET) and "street" or api.engine.getComponent(ce, api.type.ComponentType.BASE_EDGE) and "track"
				or api.engine.getComponent(ce, api.type.ComponentType.BASE_NODE) and "node" or api.engine.getComponent(ce, api.type.ComponentType.CONSTRUCTION) and "construction"
				or api.engine.getComponent(ce, api.type.ComponentType.TOWN_BUILDING) and "house" or "entity"
			out = " with " .. kind .. " " .. tostring(ce)
		end
	end)
	return out
end

-- the company's constructions of a file (part of its name), with their place
function RL.mine(E, co, part)
	local api = E.api
	local out = {}
	for _, e in ipairs(E.R.entitiesWith("CONSTRUCTION")) do
		local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
		if c and tostring(c.fileName):find(part, 1, true) and ownerOf(E, e) == co.ent then
			local m = E.C.marshal(c.transf)
			out[#out + 1] = { con = e, c = c, pos = { x = m[13], y = m[14], z = m[15] } }
		end
	end
	return out
end

-- the free ends of a construction's tracks: the node, where it is, the way out (from the track into the open)
function RL.ends(E, con)
	local api = E.api
	local c = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
	local segmap = api.engine.system.streetSystem.getNode2SegmentMap()
	local out = {}
	for k = 1, #(c and c.frozenEdges or {}) do
		local e = c.frozenEdges[k]
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		-- (a track: a segment without a street component, TF3 has no track component)
		if be and not api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) then
			for i, nd in ipairs({ be.node0, be.node1 }) do
				if #(segmap[nd] or {}) == 1 then
					local p, q = E.nodePosition(nd), E.nodePosition(i == 1 and be.node1 or be.node0)
					local l = p and q and math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) or 0
					if l > 0 then out[#out + 1] = { node = nd, p = p, d = { x = (p.x - q.x) / l, y = (p.y - q.y) / l } } end
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.node < b.node end)
	return out
end

-- A depot for a station's free end `back`: its exit gap m out along the station's axis and lat m to its side, the depot turned so
-- that its exit (its own -y end, RL.DEPOT_EXIT from its origin) faces that end; a dry run of the depot together with its approach
-- (RL.trackProposal from the station's end to 5 m short of the exit, round nothing), so that the approach is clear and not too
-- tight too. Returns as RL.dry (the proposal of the depot alone) and the depot's origin
function RL.dryDepot(E, co, back, gap, lat)
	local api = E.api
	local d = back.d
	local X = { x = back.p.x + d.x * gap - d.y * lat, y = back.p.y + d.y * gap + d.x * lat }
	-- (its exit faces the station's end: its own -y towards it)
	local fx, fy = back.p.x - X.x, back.p.y - X.y
	local fl = math.sqrt(fx * fx + fy * fy)
	local yx, yy = -fx / fl, -fy / fl
	local ang = math.atan2(-yx, yy)
	local ex, ey = RL.DEPOT_EXIT.x, RL.DEPOT_EXIT.y
	local xa, ya = { x = math.cos(ang), y = math.sin(ang) }, { x = -math.sin(ang), y = math.cos(ang) }
	local O = { x = X.x - (xa.x * ex + ya.x * ey), y = X.y - (xa.y * ex + ya.y * ey) }
	local params = { seed = 0, year = currentYear(E), modules = {} }
	local free, sp, ctx, cost, why, bits = RL.dry(E, co, RL.DEPOT, params, O.x, O.y, ang)
	if not free then return false, sp, ctx, cost, why, bits, O end
	-- (the depot and its approach together)
	local q = { x = X.x - yx * 5, y = X.y - yy * 5 }
	q.z = E.groundZ(q.x, q.y, back.p.z)
	local tsp, _, refused = RL.trackProposal(E, co, back.node, back.p, back.d, -9001, q, { x = yx, y = yy }, currentYear(E), {}, nil)
	if not tsp then return false, sp, ctx, cost, "its approach: " .. tostring(refused), bits, O end
	local ssp = tsp.streetProposal
	local nodes = ssp.nodesToAdd or {}
	local ne = api.type.NodeAndEntity.new()
	ne.entity = -9001
	local bn = ne.comp
	bn.position = api.type.Vec3f.new(q.x, q.y, q.z)
	ne.comp = bn
	nodes[#nodes + 1] = ne
	ssp.nodesToAdd = nodes
	tsp.streetProposal = ssp
	tsp.constructionsToAdd = sp.constructionsToAdd
	local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(tsp, ctx) end)
	if not (okd and pd) then return false, sp, ctx, cost, "dry run with its approach failed: " .. tostring(pd), bits, O end
	local why2 = ""
	pcall(function() why2 = E.C.ser(E.C.marshal(pd.errorState.messages)) end)
	if #pd.errorState.messages > 0 or pd.errorState.critical then return false, sp, ctx, cost, "its approach: " .. why2, bits, O end
	return true, sp, ctx, cost, why, bits, O
end

-- the exit of a depot: its free track end farthest along its own -y axis (the others are its sidings, inside)
function RL.depotExit(E, con)
	local c = E.api.engine.getComponent(con, E.api.type.ComponentType.CONSTRUCTION)
	local m = E.C.marshal(c.transf)
	local best, bv
	for _, f in ipairs(RL.ends(E, con)) do
		local v = (f.p.x - m[13]) * m[5] + (f.p.y - m[14]) * m[6]
		if not bv or v < bv then best, bv = f, v end
	end
	return best
end

-- the train terminals of a station construction, as a line's stop takes them ({ group, list = { { station, terminal, node } } })
function RL.terminals(E, con)
	local api = E.api
	local c = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
	local out
	for k = 1, #(c and c.stations or {}) do
		local st = c.stations[k]
		local okg, group = pcall(function() return api.engine.system.stationGroupSystem.getStationGroup(st) end)
		local sg = okg and group and api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP)
		local sc = api.engine.getComponent(st, api.type.ComponentType.STATION)
		if sg and sc then
			local si
			for i = 1, #sg.stations do if sg.stations[i] == st then si = i - 1 end end
			for t = 1, #sc.terminals do
				out = out or { group = group, list = {} }
				if si and out.group == group then out.list[#out.list + 1] = { station = si, terminal = t - 1, node = sc.terminals[t].vehicleNodeId } end
			end
		end
	end
	return out
end

-- whether a station reaches an industry (its stock list is among the station's catchables)
function RL.reaches(E, con, ind)
	local api = E.api
	local c = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
	local yes = false
	for k = 1, #(c and c.stations or {}) do
		pcall(function()
			for _, x in ipairs(api.engine.system.catchmentAreaSystem.getStationCatchables(c.stations[k], true)) do
				if x == ind.stockList then yes = true end
			end
		end)
	end
	return yes
end

-- a train can run from one set of nodes to the other (the engine's path finding)
function RL.path(E, na, nb)
	local api = E.api
	local ok, p = pcall(function() return api.engine.util.pathfinding.findPathNodeToNode(na, nb, { api.type.enum.TransportMode.TRAIN }) end)
	return ok and type(p) == "table" and #p > 0
end

-- the cheapest locomotive on sale strong enough that needs no catenary, and the wagon that carries the most of a cargo for its price: { loco, wagon, n,
-- seats, price }, nil when there is none (n: wagons, as many as the station's platforms take after the locomotive)
function RL.train(E, cargo)
	local api = E.api
	local year = currentYear(E)
	local loco, wagon
	for id, name in pairs(api.res.modelRep.getAll()) do
		local s = tostring(name)
		local isLoco, isWagon = s:find("vehicle/train/", 1, true), s:find("vehicle/waggon/", 1, true)
		if isLoco or isWagon then
			pcall(function()
				local md = api.res.modelRep.get(id).metadata
				local av = md.availability
				local from, to = av and av.yearFrom or 0, av and av.yearTo or 0
				if not (from <= year and (to == 0 or to > year)) then return end
				local len = 10
				pcall(function() len = md.boundingInfo.bbMax.x - md.boundingInfo.bbMin.x end)
				local price = 0
				pcall(function() price = tonumber(md.cost.price) or 0 end)
				if isLoco then
					-- (a locomotive: engines and no room for any load (its one compartment holds 0); not electric: engine type 2, or
					-- named so. The cheapest one strong enough (RL.POWER kW), else the strongest: a Big Boy costs 18.7 million in 1972, an
					-- Alco HH600 of 450 kW 1.1 million)
					local power, electric, cap = 0, false, 0
					for _, en in ipairs(md.landVehicle and md.landVehicle.engines or {}) do
						power = power + (en.power or 0)
						if en.type == 2 or tostring(en.type):upper():find("ELECTRIC", 1, true) then electric = true end
					end
					pcall(function()
						for _, comp in ipairs(md.transportVehicle.compartments) do
							for _, lc in ipairs(comp.loadConfigs) do cap = cap + (lc.cargoEntry.capacity or 0) end
						end
					end)
					if power > 0 and not electric and cap == 0 then
						local strong, best = power >= RL.POWER, loco and loco.power >= RL.POWER
						if not loco or (strong and (not best or price < loco.price)) or (not strong and not best and power > loco.power) then
							loco = { id = id, name = s, power = power, len = len, price = price }
						end
					end
				else
					local cap = 0
					for _, comp in ipairs(md.transportVehicle.compartments) do
						for _, lc in ipairs(comp.loadConfigs) do
							if api.res.cargoTypeRep.hasCargoType(lc.cargoEntry.cargoTypeSet, cargo) then cap = math.max(cap, lc.cargoEntry.capacity or 0) end
						end
					end
					-- (the most of it for the money: a wagon of 1971 carries 20 grain for 900 000, one of 1915 10 for 300 000)
					local worth = cap / math.max(1, price)
					if cap > 0 and (not wagon or worth > wagon.worth or (worth == wagon.worth and cap > wagon.cap)) then
						wagon = { id = id, name = s, cap = cap, len = len, price = price, from = from, worth = worth }
					end
				end
			end)
		end
	end
	if not (loco and wagon) then return nil, year end
	local room = (RL.LEN + 1) * 40 - 15 - loco.len
	local n = math.max(2, math.min(RL.WAGONS, math.floor(room / math.max(6, wagon.len))))
	return { loco = loco, wagon = wagon, n = n, seats = n * wagon.cap, price = loco.price + n * wagon.price }, year
end

-- the best railway not built yet: a producer that makes RL.MINPROD a year of a cargo or more now (tests: MPFEVER_AIRAILMIN) (one the company's trucks serve
-- too: the railway carries more, further) and an industry that takes it RL.MIN to RL.MAX apart, neither served by another company
-- (PvE, as the trucks), no train station of the company near the producer; the most cargo times the distance
function RL.route(E, co, lines, stations)
	local inds = industries(E)
	local others = servedByOthers(E, co.ent)
	local mine = {}
	for _, l in ipairs(lines) do for _, g in ipairs(l.groups) do mine[g] = true end end
	local best
	for _, a in ipairs(inds) do
		-- (not a producer one of its train stations already serves)
		local near = false
		for _, s in ipairs(stations or {}) do if dist(s.pos, a.pos) < 500 then near = true end end
		-- (0.6.4: a producer its trucks serve too: a railway is where its trucks made it grow; RL.MINPROD a year at least, what it
		-- makes now: a clay pit of 110 a year left a train standing for weeks and its line losing money)
		if not near and not others[a.road.group] and not ((E.G.AI.railTried or {})[a.e]) then
			for _, c in ipairs(a.outputs) do
				local made = 0
				pcall(function() made = E.api.engine.util.stock.getCargoProducedPerYear(a.stockList, c) or 0 end)
				if made >= RL.MINPROD then
					for _, b in ipairs(inds) do
						if b.e ~= a.e and not others[b.road.group] and takes(E, b, c) then
							local d = dist(a.pos, b.pos)
							if d >= RL.MIN and d <= RL.MAX then
								local score = made * d
								if not best or score > best.score then best = { from = a, to = b, cargo = c, d = d, score = score } end
							end
						end
					end
				end
			end
		end
	end
	return best
end

-- A station of the company near an industry, its tracks along the way to the other end of the railway (axis a): the first
-- free place on rings around the industry, the side facing the other end first; built. True when asked for, "dear" when
-- refused for its price, false when no place is free
function RL.stationPlace(E, co, ind, a, tag)
	local year = currentYear(E)
	local params = RL.stationParams(year, RL.LEN)
	local tried, fallback = 0, nil
	-- (beside the industry first, its tracks along the way (sides 2 and -2): then neither end faces the industry, and a depot
	-- fits behind it; a place where no depot would fit behind (RL.depotRoom) is taken last)
	for _, r in ipairs({ 150, 200, 260, 330 }) do
		for _, side in ipairs({ 2, -2, 1, -1, 3, -3, 0, 4 }) do
			local b = a + side * math.pi / 4
			local x, y = ind.pos.x + math.cos(b) * r, ind.pos.y + math.sin(b) * r
			tried = tried + 1
			-- (the station's tracks run along its own y axis: turned a quarter less)
			local free, sp, ctx, cost, why, bits = RL.dry(E, co, RL.STATION, params, x, y, a - math.pi / 2)
			if free then
				local place = { sp = sp, ctx = ctx, cost = cost, bits = bits, x = x, y = y, r = r, a = a }
				if RL.depotRoom(E, co, x, y, a) then return place end
				fallback = fallback or place
			elseif tried <= 3 and tag then L(E, "train station " .. tag .. " at " .. math.floor(r) .. " m: " .. tostring(why):sub(1, 160)) end
		end
	end
	return fallback
end

-- A station of the company near an industry, its tracks along the way to the other end of the railway (axis a), at the first
-- free place RL.stationPlace finds; built. True when asked for, "dear" when refused for its price, false when no place is free
function RL.buildStation(E, co, ind, a, tag)
	local place = RL.stationPlace(E, co, ind, a, tag)
	if not place then return false end
	if not spendOk(E, co, (place.cost or 600000) + 50000, "train station " .. tag) then return "dear" end
	L(E, string.format("train station %s near industry %d: %.0f m from it, %s", tag, ind.e, place.r, place.cost and ("cost " .. math.floor(place.cost)) or "cost unknown"))
	build(E, co.id, E.api.cmd.makeWorldBuildProposalCmd(place.sp, place.ctx, false, true, true), "train station " .. tag, place.bits, { kind = "railstation", pos = { x = place.x, y = place.y, z = 0 } })
	return true
end

-- whether a depot would fit behind a station at x, y whose tracks run along a (its back end 80 m behind its centre): a dry run
-- of the depot alone, 120 m out of that end, on its axis or 80 m to either side
function RL.depotRoom(E, co, x, y, a)
	local dx, dy = -math.cos(a), -math.sin(a)
	local back = { p = { x = x + dx * 80, y = y + dy * 80 }, d = { x = dx, y = dy } }
	for _, lat in ipairs({ 0, 80, -80 }) do
		local X = { x = back.p.x + dx * 120 - dy * lat, y = back.p.y + dy * 120 + dx * lat }
		local fx, fy = back.p.x - X.x, back.p.y - X.y
		local fl = math.sqrt(fx * fx + fy * fy)
		local yx, yy = -fx / fl, -fy / fl
		local ang = math.atan2(-yx, yy)
		local xa, ya = { x = math.cos(ang), y = math.sin(ang) }, { x = -math.sin(ang), y = math.cos(ang) }
		local ox = X.x - (xa.x * RL.DEPOT_EXIT.x + ya.x * RL.DEPOT_EXIT.y)
		local oy = X.y - (xa.y * RL.DEPOT_EXIT.x + ya.y * RL.DEPOT_EXIT.y)
		if RL.dry(E, co, RL.DEPOT, { seed = 0, year = currentYear(E), modules = {} }, ox, oy, ang) then return true end
	end
	return false
end

-- the curve at t of a cubic Bézier B: its point and its derivative
function RL.bez(B, t)
	local u = 1 - t
	return u * u * u * B[1].x + 3 * u * u * t * B[2].x + 3 * u * t * t * B[3].x + t * t * t * B[4].x,
		u * u * u * B[1].y + 3 * u * u * t * B[2].y + 3 * u * t * t * B[3].y + t * t * t * B[4].y,
		3 * u * u * (B[2].x - B[1].x) + 6 * u * t * (B[3].x - B[2].x) + 3 * t * t * (B[4].x - B[3].x),
		3 * u * u * (B[2].y - B[1].y) + 6 * u * t * (B[3].y - B[2].y) + 3 * t * t * (B[4].y - B[3].y)
end

-- The curve of a track through points P (P[1] its start, P[#P] its end), leaving P[1] along d0 and reaching P[#P] along -d1
-- (d1: the way out of the far end, towards the start): one cubic Bézier per span, each point's direction the one from its
-- neighbour before to its neighbour after (Catmull-Rom), each span's inner points a third of its length out. t from 0 to 1 over
-- the whole curve: { at(t) -> x, y, dx, dy (per unit of t), L (its length, about) }
function RL.spline(P, d0, d1)
	local n = #P - 1
	local dirs = {}
	for i = 1, #P do
		local dx, dy
		if i == 1 then dx, dy = d0.x, d0.y
		elseif i == #P then dx, dy = -d1.x, -d1.y
		else dx, dy = P[i + 1].x - P[i - 1].x, P[i + 1].y - P[i - 1].y end
		local l = math.sqrt(dx * dx + dy * dy)
		dirs[i] = l > 0 and { x = dx / l, y = dy / l } or { x = 0, y = 0 }
	end
	local spans, L = {}, 0
	for i = 1, n do
		local a, b = P[i], P[i + 1]
		local h = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / 3
		spans[i] = { { x = a.x, y = a.y }, { x = a.x + dirs[i].x * h, y = a.y + dirs[i].y * h }, { x = b.x - dirs[i + 1].x * h, y = b.y - dirs[i + 1].y * h }, { x = b.x, y = b.y } }
		L = L + 3 * h
	end
	local S = { spans = spans, L = L }
	function S.at(t)
		local k = math.min(n, math.floor(t * n) + 1)
		local x, y, dx, dy = RL.bez(spans[k], t * n - (k - 1))
		return x, y, dx * n, dy * n
	end
	return S
end

-- a segment's curve (Hermite, as the engine draws it) at t: its point and its derivative
function RL.herm(c, t)
	local P0, P1, T0, T1 = c.position0, c.position1, c.tangent0, c.tangent1
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
	local function f(k) return h00 * P0[k] + h10 * T0[k] + h01 * P1[k] + h11 * T1[k], d00 * P0[k] + d10 * T0[k] + d01 * P1[k] + d11 * T1[k] end
	local x, dx = f("x")
	local y, dy = f("y")
	local z, dz = f("z")
	return { x = x, y = y, z = z }, { x = dx, y = dy, z = dz }
end

-- where two pieces a-b and c-d cross: the share along each, or nil
function RL.crossAt(a, b, c, d)
	local rx, ry, sx, sy = b.x - a.x, b.y - a.y, d.x - c.x, d.y - c.y
	local den = rx * sy - ry * sx
	if math.abs(den) < 1e-9 then return nil end
	local u = ((c.x - a.x) * sy - (c.y - a.y) * sx) / den
	local v = ((c.x - a.x) * ry - (c.y - a.y) * rx) / den
	if u >= 0 and u <= 1 and v >= 0 and v <= 1 then return u, v end
	return nil
end

-- What is in a track's way, read once per railway step: within the box, the segments (their curve every ~10 m, whether a street
-- and whether the company may cut it: no stop on it, its own or an open company's or nobody's), the town houses, the other
-- constructions (their place and a reach: 220 m for an industry, 90 m else)
function RL.world(E, co, box)
	local api = E.api
	local W = { edges = {}, houses = {}, cons = {}, box = box, segmap = api.engine.system.streetSystem.getNode2SegmentMap(), grid = {} }
	local eco = E.C.eco and E.C.eco() or nil
	local open = {}
	-- (another company's street or track: only when its rule for them is open, see mpfever_eco.lua)
	local function mayCut(owner, street)
		if not owner or owner == co.ent then return true end
		local k = (street and "r" or "t") .. owner
		if open[k] == nil then
			open[k] = false
			pcall(function()
				local id = E.CO.idOfEntity(E.G.co, owner)
				local c
				for _, x in ipairs(E.G.co.list) do if x.id == id then c = x end end
				local r = street and eco.roadRule(E.G.co, c) or eco.trackRule(E.G.co, c)
				open[k] = eco ~= nil and c ~= nil and r.rule == "open"
			end)
		end
		return open[k]
	end
	for _, e in ipairs(E.R.allEdges()) do
		pcall(function()
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			local m = E.C.marshal(c)
			local p0, p1 = m.position0, m.position1
			if math.max(p0.x, p1.x) < box.x0 or math.min(p0.x, p1.x) > box.x1 or math.max(p0.y, p1.y) < box.y0 or math.min(p0.y, p1.y) > box.y1 then return end
			local len = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
			local n = math.max(1, math.ceil(len / 10))
			local pts = {}
			for i = 0, n do pts[#pts + 1] = (RL.herm(m, i / n)) end
			local street = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) ~= nil
			local owner = ownerOf(E, e)
			local w = { e = e, m = m, pts = pts, street = street, owner = owner, cut = #c.objects == 0 and mayCut(owner, street) }
			W.edges[#W.edges + 1] = w
			-- (each piece of its curve in the cells of RL.NEAR m it touches, for the distance checks)
			for j = 1, #pts - 1 do
				local a, b = pts[j], pts[j + 1]
				local i0, j0 = math.floor(math.min(a.x, b.x) / RL.NEARCELL), math.floor(math.min(a.y, b.y) / RL.NEARCELL)
				local i1, j1 = math.floor(math.max(a.x, b.x) / RL.NEARCELL), math.floor(math.max(a.y, b.y) / RL.NEARCELL)
				for ci = i0, i1 do for cj = j0, j1 do
					local k = ci .. ":" .. cj
					W.grid[k] = W.grid[k] or {}
					W.grid[k][#W.grid[k] + 1] = { w = w, a = a, b = b }
				end end
			end
		end)
	end
	for _, e in ipairs(E.R.entitiesWith("CONSTRUCTION")) do
		pcall(function()
			local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
			local m = E.C.marshal(c.transf)
			if m[13] < box.x0 or m[13] > box.x1 or m[14] < box.y0 or m[14] > box.y1 then return end
			if #c.townBuildings > 0 then W.houses[#W.houses + 1] = { x = m[13], y = m[14] }
			else W.cons[#W.cons + 1] = { e = e, x = m[13], y = m[14], r = tostring(c.fileName):find("industr", 1, true) and 220 or 90 } end
		end)
	end
	return W
end

-- A way for a track from p0 (leaving along d0) to p1 (reached along -d1), round what is in its way: a search (A*) over a grid of
-- RL.CELL m, the houses (80 m round), the other constructions and the segments' nodes closed; each street or track crossed (on a
-- bridge) costs RL.CROSS m more, each cell of water RL.WET more, each step along a street RL.ALONG more, each metre of height 20 m more. The way: the
-- points where it turns (the cells' path pulled straight over open cells), from RL.LEAD m out of each end. nil and why when there is
-- none within the box.
function RL.plan(E, p0, d0, p1, d1, W)
	local cell, box = RL.CELL, W.box
	local nx, ny = math.max(1, math.ceil((box.x1 - box.x0) / cell)), math.max(1, math.ceil((box.y1 - box.y0) / cell))
	local function key(i, j) return j * nx + i end
	local function cellOf(x, y) return math.floor((x - box.x0) / cell), math.floor((y - box.y0) / cell) end
	local function centre(i, j) return box.x0 + (i + 0.5) * cell, box.y0 + (j + 0.5) * cell end
	local closed, road = {}, {}
	local wl = RL.waterLevel(E)
	local function closeRound(x, y, r)
		local i0, j0 = cellOf(x - r, y - r)
		local i1, j1 = cellOf(x + r, y + r)
		for i = i0, i1 do for j = j0, j1 do
			local cx, cy = centre(i, j)
			if (cx - x) ^ 2 + (cy - y) ^ 2 <= (r + cell * 0.5) ^ 2 then closed[key(i, j)] = true end
		end end
	end
	for _, h in ipairs(W.houses) do closeRound(h.x, h.y, 80) end
	for _, c in ipairs(W.cons) do
		-- (not the stations at the two ends)
		if (c.x - p0.x) ^ 2 + (c.y - p0.y) ^ 2 > 250 * 250 and (c.x - p1.x) ^ 2 + (c.y - p1.y) ^ 2 > 250 * 250 then closeRound(c.x, c.y, c.r) end
	end
	for _, w in ipairs(W.edges) do
		for _, q in ipairs(w.pts) do
			local i, j = cellOf(q.x, q.y)
			-- (crossed on a bridge, see RL.trackProposal: at a cost)
			road[key(i, j)] = true
		end
		-- (a segment is crossed between its nodes, not at a junction: the cells of its two ends closed)
		do
			for _, q in ipairs({ w.pts[1], w.pts[#w.pts] }) do local i, j = cellOf(q.x, q.y); closed[key(i, j)] = true end
		end
	end
	local s = { x = p0.x + d0.x * RL.LEAD, y = p0.y + d0.y * RL.LEAD }
	local g = { x = p1.x + d1.x * RL.LEAD, y = p1.y + d1.y * RL.LEAD }
	local si, sj = cellOf(s.x, s.y)
	local gi, gj = cellOf(g.x, g.y)
	closed[key(si, sj)], closed[key(gi, gj)] = nil, nil
	-- the search (a binary heap of open cells by cost + straight distance to the goal)
	local heap, cost, from, zc = {}, {}, {}, {}
	local function z(i, j)
		local k = key(i, j)
		if not zc[k] then local cx, cy = centre(i, j); zc[k] = E.groundZ(cx, cy, 0) end
		return zc[k]
	end
	local function push(k, f)
		heap[#heap + 1] = { k = k, f = f }
		local n = #heap
		while n > 1 do
			local p = math.floor(n / 2)
			if heap[p].f <= heap[n].f then break end
			heap[p], heap[n] = heap[n], heap[p]
			n = p
		end
	end
	local function pop()
		local top = heap[1]
		heap[1] = heap[#heap]
		heap[#heap] = nil
		local n = 1
		while true do
			local l, r, m = 2 * n, 2 * n + 1, n
			if heap[l] and heap[l].f < heap[m].f then m = l end
			if heap[r] and heap[r].f < heap[m].f then m = r end
			if m == n then break end
			heap[m], heap[n] = heap[n], heap[m]
			n = m
		end
		return top
	end
	local function h(i, j) return math.sqrt((i - gi) ^ 2 + (j - gj) ^ 2) * cell end
	local sk, gk = key(si, sj), key(gi, gj)
	cost[sk] = 0
	push(sk, h(si, sj))
	local found, visits = false, 0
	while #heap > 0 do
		local top = pop()
		local k = top.k
		if k == gk then found = true break end
		visits = visits + 1
		if visits > 60000 then return nil, "the search took too long" end
		local i, j = k % nx, math.floor(k / nx)
		for di = -1, 1 do for dj = -1, 1 do
			if di ~= 0 or dj ~= 0 then
				local a, b = i + di, j + dj
				local nk = key(a, b)
				if a >= 0 and b >= 0 and a < nx and b < ny and not closed[nk] then
					local step = (di ~= 0 and dj ~= 0) and cell * 1.4142 or cell
					local c = cost[k] + step + math.abs(math.max(z(a, b), wl) - math.max(z(i, j), wl)) * 20
					-- (water: on a bridge, dear: a river is crossed where it is narrow, a lake gone round)
					if z(a, b) < wl - 0.1 then c = c + RL.WET end
					if road[nk] then c = c + (road[k] and RL.ALONG or RL.CROSS) end
					if not cost[nk] or c < cost[nk] then
						cost[nk], from[nk] = c, k
						push(nk, c + h(a, b))
					end
				end
			end
		end end
	end
	if not found then return nil, "no way round within " .. math.floor((box.x1 - box.x0) / 1000) .. " km" end
	local path = {}
	local k = gk
	while k do
		local i, j = k % nx, math.floor(k / nx)
		local cx, cy = centre(i, j)
		table.insert(path, 1, { x = cx, y = cy })
		k = from[k]
	end
	path[1], path[#path] = s, g
	-- (made straight: from each point, on to the farthest point of the path seen in a straight line over no closed cell - pulling
	-- the string - so that the track has long straight runs and few wide curves; then no two points closer than RL.LEG)
	local function clearLine(a, b)
		local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		local n = math.max(1, math.ceil(l / (cell / 4)))
		for q = 1, n - 1 do
			local i, j = cellOf(a.x + (b.x - a.x) * q / n, a.y + (b.y - a.y) * q / n)
			if closed[key(i, j)] then return false end
		end
		return true
	end
	local way, at = { path[1] }, 1
	while at < #path do
		local nxt = at + 1
		for j = #path, at + 2, -1 do
			if clearLine(path[at], path[j]) then nxt = j break end
		end
		way[#way + 1] = path[nxt]
		at = nxt
	end
	local merged = { way[1] }
	for i = 2, #way - 1 do
		local last = merged[#merged]
		if (way[i].x - last.x) ^ 2 + (way[i].y - last.y) ^ 2 >= RL.LEG * RL.LEG then merged[#merged + 1] = way[i] end
	end
	merged[#merged + 1] = way[#way]
	way = merged
	return way
end

-- The track from node n0 (at p0, leaving along d0) to node n1 (at p1, leaving along d1, towards the first) through the points of
-- way (none: one curve straight from end to end), in pieces of about RL.STEP m. Over every street and track it crosses it runs on
-- a bridge (the game's concrete bridge, RL.SPAN m long, RL.CLEAR m over the segment), as a player's track crosses a road: nothing
-- of the others is touched; over water too (a river or a lake no wider than RL.WATER). Refused (nil, length, why) when it curves
-- tighter than RL.RADIUS, passes within 45 m of a town house,
-- crosses a segment twice or runs along it, crosses one too slantwise (under 14 degrees), or needs more than RL.GRADE (twice that between two fixed
-- points closer than 200 m, RL.RAMP on the ramps of a bridge) between its ends and its bridges. Its heights follow the ground, averaged,
-- within the grade. Owned by the company. W: what is in its way (RL.world), none when nil.
function RL.trackProposal(E, co, n0, p0, d0, n1, p1, d1, year, way, W)
	local api, C = E.api, E.C
	local tpl, style = RL.track(year)
	local lanes = C.templateLanes(tpl)
	if not lanes then return nil, 0, "no lanes for " .. tpl end
	local P = { { x = p0.x, y = p0.y } }
	for _, q in ipairs(way or {}) do P[#P + 1] = q end
	P[#P + 1] = { x = p1.x, y = p1.y }
	local S = RL.spline(P, d0, d1)
	local L0 = S.L
	-- (no curve tighter than RL.RADIUS: the engine refuses them, "excessive curvature", and trains crawl through them)
	do
		local n = math.max(50, math.ceil(L0 / 5))
		for i = 1, n - 1 do
			local t = i / n
			local _, _, dx1, dy1 = S.at(t - 0.5 / n)
			local _, _, dx2, dy2 = S.at(t + 0.5 / n)
			local _, _, dx, dy = S.at(t)
			local v = math.sqrt(dx * dx + dy * dy)
			local k = v > 0 and math.abs(dx * (dy2 - dy1) * n - dy * (dx2 - dx1) * n) / (v * v * v) or 0
			if k * RL.RADIUS > 1 then return nil, L0, string.format("a curve of %.0f m radius", 1 / k) end
		end
	end
	-- (the curve every ~10 m, for the obstacles)
	local fine = math.max(8, math.ceil(L0 / 10))
	local poly = {}
	for i = 0, fine do local x, y = S.at(i / fine); poly[#poly + 1] = { x = x, y = y, t = i / fine } end
	W = W or { edges = {}, houses = {}, cons = {} }
	for _, h in ipairs(W.houses) do
		for i = 1, #poly, 2 do
			if (poly[i].x - h.x) ^ 2 + (poly[i].y - h.y) ^ 2 < 45 * 45 then return nil, L0, "town houses in its way" end
		end
	end
	local crossings = {}
	for _, w in ipairs(W.edges) do
		local hit
		-- (not the segments at its two ends: the stations' own tracks it starts from)
		local own = w.m.node0 == n0 or w.m.node1 == n0 or w.m.node0 == n1 or w.m.node1 == n1
		for i = 1, own and 0 or #poly - 1 do
			for j = 1, #w.pts - 1 do
				local u, v = RL.crossAt(poly[i], poly[i + 1], w.pts[j], w.pts[j + 1])
				if u then
					local t = poly[i].t + u * (poly[i + 1].t - poly[i].t)
					-- (the same crossing found on two pieces when it falls on a point between them: kept once)
					if hit and math.abs(t - hit.t) * L0 > 2 then return nil, L0, "it crosses segment " .. w.e .. " twice or runs along it" end
					if not hit then hit = { t = t, ts = ((j - 1) + v) / (#w.pts - 1), w = w, z = w.pts[j].z + (w.pts[j + 1].z - w.pts[j].z) * v } end
				end
			end
		end
		if hit then
			local _, dX = RL.herm(w.m, hit.ts)
			local _, _, tx, ty = S.at(hit.t)
			local tl, sl = math.sqrt(tx * tx + ty * ty), math.sqrt(dX.x * dX.x + dX.y * dX.y)
			local cos = (tl > 0 and sl > 0) and math.abs((tx * dX.x + ty * dX.y) / (tl * sl)) or 0
			if cos > 0.97 then return nil, L0, "it crosses " .. (w.street and "street " or "track ") .. w.e .. " too slantwise" end
			-- (a slanting crossing: a longer bridge, RL.SPAN over the sine of its angle, 200 m at most)
			hit.span = math.min(200, RL.SPAN / math.sqrt(math.max(0.0625, 1 - cos * cos)))
			crossings[#crossings + 1] = hit
		end
	end
	table.sort(crossings, function(a, b) return a.t < b.t end)
	-- (the bridges: RL.SPAN m round each crossing (more when it slants), two bridges less than 40 m apart made one; RL.CLEAR m
	-- over the highest segment it spans)
	local wl = RL.waterLevel(E)
	local over = {}
	for _, x in ipairs(crossings) do
		local half = (x.span or RL.SPAN) / 2 / L0
		over[#over + 1] = { t0 = x.t - half, t1 = x.t + half, z = x.z + RL.CLEAR }
	end
	-- (water: where the ground is under the water level, a bridge from 20 m before to 20 m after, RL.CLEAR m over the water;
	-- refused when wider than RL.WATER)
	local wet
	for _, q in ipairs(poly) do
		local isWet = E.groundZ(q.x, q.y, wl + 1) < wl - 0.1
		if isWet and not wet then wet = { t0 = q.t, t1 = q.t } elseif isWet then wet.t1 = q.t end
		if wet and (not isWet or q == poly[#poly]) then
			if (wet.t1 - wet.t0) * L0 > RL.WATER then return nil, L0, "water " .. math.floor((wet.t1 - wet.t0) * L0) .. " m wide in its way" end
			over[#over + 1] = { t0 = wet.t0 - 20 / L0, t1 = wet.t1 + 20 / L0, z = wl + RL.CLEAR, water = true }
			wet = nil
		end
	end
	table.sort(over, function(a, b) return a.t0 < b.t0 end)
	local spans = {}
	for _, x in ipairs(over) do
		local last = spans[#spans]
		if last and (x.t0 - last.t1) * L0 < 40 then
			last.t1 = math.max(last.t1, x.t1)
			last.z = math.max(last.z, x.z)
		else
			spans[#spans + 1] = { t0 = x.t0, t1 = x.t1, z = x.z }
		end
	end
	for _, b in ipairs(spans) do
		if b.t0 * L0 < 30 or (1 - b.t1) * L0 < 30 then return nil, L0, "a bridge too near its ends" end
	end
	-- (0.6.4) along a segment it does not cross: no closer than RL.NEAR m, but on a bridge and near its two ends (the dry run
	-- refused such tracks, "Collision" with a street or track it ran beside)
	if W.grid then
		local cs = RL.NEARCELL
		for _, q in ipairs(poly) do
			local onBridge = q.t * L0 < 40 or (1 - q.t) * L0 < 40
			for _, b in ipairs(spans) do if q.t >= b.t0 - 15 / L0 and q.t <= b.t1 + 15 / L0 then onBridge = true end end
			if not onBridge then
				local ci, cj = math.floor(q.x / cs), math.floor(q.y / cs)
				for di = -1, 1 do for dj = -1, 1 do
					for _, piece in ipairs(W.grid[(ci + di) .. ":" .. (cj + dj)] or {}) do
						local w = piece.w
						if not (w.m.node0 == n0 or w.m.node1 == n0 or w.m.node0 == n1 or w.m.node1 == n1) then
							local a, b = piece.a, piece.b
							local vx, vy = b.x - a.x, b.y - a.y
							local l2 = vx * vx + vy * vy
							local u = l2 > 0 and math.max(0, math.min(1, ((q.x - a.x) * vx + (q.y - a.y) * vy) / l2)) or 0
							local dx, dy = a.x + vx * u - q.x, a.y + vy * u - q.y
							if dx * dx + dy * dy < RL.NEAR * RL.NEAR then return nil, L0, "it runs " .. RL.NEAR .. " m or less beside " .. (w.street and "street " or "track ") .. w.e end
						end
					end
				end end
			end
		end
	end
	-- the track's points: every RL.STEP m outside the bridges, and the two ends of each bridge (fixed at its height)
	local k = math.max(2, math.ceil(L0 / RL.STEP))
	local ts = {}
	for i = 0, k do
		local t, inside = i / k, false
		for _, b in ipairs(spans) do if t > b.t0 - 10 / L0 and t < b.t1 + 10 / L0 then inside = true end end
		if not inside or i == 0 or i == k then ts[#ts + 1] = { t = t } end
	end
	for bi, b in ipairs(spans) do
		ts[#ts + 1] = { t = b.t0, z = b.z, bridge = bi }
		ts[#ts + 1] = { t = b.t1, z = b.z, bridgeEnd = bi }
	end
	table.sort(ts, function(a, b) return a.t < b.t end)
	local pts = {}
	for i, q in ipairs(ts) do
		local x, y = S.at(q.t)
		pts[i] = { x = x, y = y, t = q.t, z = q.z or E.groundZ(x, y, p0.z), fixed = q.z ~= nil, bridge = q.bridge, bridgeEnd = q.bridgeEnd }
	end
	pts[1].z, pts[1].fixed, pts[#pts].z, pts[#pts].fixed = p0.z, true, p1.z, true
	-- (the heights: between two fixed points, the ground's averaged over five points, kept within the grade from both (their
	-- envelope) and from one point to the next; refused when two fixed points are too far apart in height for it)
	local s = { 0 }
	for i = 2, #pts do s[i] = s[i - 1] + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2) end
	local g = RL.GRADE
	local zs, a = { pts[1].z }, 1
	while a < #pts do
		local b = a + 1
		while not pts[b].fixed do b = b + 1 end
		local za, zb, span = pts[a].z, pts[b].z, s[b] - s[a]
		-- (a ramp to a bridge, or between two fixed points close together: up to twice the grade, the engine builds up to 8.5 %)
		local ga = (pts[b].bridge or pts[a].bridgeEnd) and RL.RAMP or span < 200 and 2 * g or g
		if math.abs(zb - za) > ga * span + 0.01 then return nil, L0, "too steep: " .. math.floor(math.abs(zb - za)) .. " m over " .. math.floor(span) .. " m" end
		for i = a + 1, b - 1 do
			local sum, n = 0, 0
			for j = math.max(1, i - 2), math.min(#pts, i + 2) do sum = sum + pts[j].z; n = n + 1 end
			local lo = math.max(za - ga * (s[i] - s[a]), zb - ga * (s[b] - s[i]), zs[i - 1] - ga * (s[i] - s[i - 1]))
			local hi = math.min(za + ga * (s[i] - s[a]), zb + ga * (s[b] - s[i]), zs[i - 1] + ga * (s[i] - s[i - 1]))
			zs[i] = math.max(lo, math.min(hi, sum / n))
		end
		zs[b] = zb
		a = b
	end
	local bridgeType = RL.bridgeType(E)
	if #spans > 0 and not bridgeType then return nil, L0, "no bridge type" end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local nodes, edges, ids = {}, {}, { n0 }
	for i = 2, #pts - 1 do
		local ne = api.type.NodeAndEntity.new()
		ne.entity = -i
		local bn = ne.comp
		bn.position = api.type.Vec3f.new(pts[i].x, pts[i].y, zs[i])
		ne.comp = bn
		nodes[#nodes + 1] = ne
		ids[i] = -i
	end
	ids[#pts] = n1
	for i = 1, #pts - 1 do
		local a1, b1 = pts[i], pts[i + 1]
		local dt = b1.t - a1.t
		local _, _, ax, ay = S.at(a1.t)
		local _, _, bx, by = S.at(math.min(b1.t, 1))
		local dz = zs[i + 1] - zs[i]
		local e = api.type.SegmentAndEntity.new()
		e.entity = -1000 - i
		e.type = 1
		local c = e.comp
		c.laneConfigs = lanes
		c.node0, c.node1 = ids[i], ids[i + 1]
		c.position0 = api.type.Vec3f.new(a1.x, a1.y, zs[i])
		c.position1 = api.type.Vec3f.new(b1.x, b1.y, zs[i + 1])
		c.tangent0 = api.type.Vec3f.new(ax * dt, ay * dt, dz)
		c.tangent1 = api.type.Vec3f.new(bx * dt, by * dt, dz)
		-- (the piece from a bridge's start to its end: the bridge)
		if a1.bridge then c.type, c.typeIndex = 1, bridgeType else c.type, c.typeIndex = 0, -1 end
		c.roadTemplate, c.roadStyle, c.roadType = tpl, style, 0
		e.comp = c
		local se = e.streetEdge
		se.precedenceNode0, se.precedenceNode1 = 2, 2
		e.streetEdge = se
		local po = e.playerOwned
		if po == nil then po = C.newOf("PlayerOwned") end
		po.player = co.ent
		e.playerOwned = po
		edges[#edges + 1] = e
	end
	if #nodes > 0 then ssp.nodesToAdd = nodes end
	ssp.edgesToAdd = edges
	sp.streetProposal = ssp
	return sp, L0, nil, #crossings
end

-- the water level of the map (the sea's; rivers and lakes lie in ground under it), 0 when it cannot be read
function RL.waterLevel(E)
	local wl = 0
	pcall(function() wl = E.api.engine.getComponent(E.api.engine.util.getWorld(), E.api.type.ComponentType.TERRAIN).waterLevel or 0 end)
	return wl
end

-- the game's concrete bridge (its index), nil when there is none
function RL.bridgeType(E)
	local id
	pcall(function()
		for i, name in pairs(E.api.res.bridgeTypeRep.getAll()) do if tostring(name):find("concrete", 1, true) then id = i end end
	end)
	return id
end

-- the ways to try for a track between two ends: the search's way round, then one curve pushed further and further out on either
-- side (a single point in the middle, RL.OFFSETS of the distance off the straight line)
function RL.ways(E, p0, d0, p1, d1, W)
	local out = {}
	local okP, way = pcall(RL.plan, E, p0, d0, p1, d1, W)
	if okP and way then out[#out + 1] = { way = way, what = "way round (" .. #way .. " points)" } end
	local L0 = dist(p0, p1)
	local nx, ny = -(p1.y - p0.y) / L0, (p1.x - p0.x) / L0
	for _, f in ipairs(RL.OFFSETS) do
		if f == 0 then out[#out + 1] = { way = {}, what = "straight" }
		else out[#out + 1] = { way = { { x = (p0.x + p1.x) / 2 + nx * f * L0, y = (p0.y + p1.y) / 2 + ny * f * L0 } }, what = string.format("curve %.2f out", f) } end
	end
	return out
end

-- the box round two ends that the ways may use
function RL.box(p0, p1)
	local L0 = dist(p0, p1)
	return { x0 = math.min(p0.x, p1.x) - L0 * 0.5 - 300, x1 = math.max(p0.x, p1.x) + L0 * 0.5 + 300,
		y0 = math.min(p0.y, p1.y) - L0 * 0.5 - 300, y1 = math.max(p0.y, p1.y) + L0 * 0.5 + 300 }
end

-- Whether a railway between two industries can be laid, before anything is built: the places its two stations would take
-- (RL.stationPlace, the second one turned towards the first), their ends facing each other (80 m out of each centre), and some
-- way between those ends clear of what is in its way (RL.trackProposal: towns, slopes, bridges) that the engine's dry run lets
-- through too. True, or false and why
function RL.corridor(E, co, from, to, a)
	local pa = RL.stationPlace(E, co, from, a)
	if not pa then return false, "no place for a station near industry " .. from.e end
	local pb = RL.stationPlace(E, co, to, a + math.pi)
	if not pb then return false, "no place for a station near industry " .. to.e end
	local u = { x = math.cos(a), y = math.sin(a) }
	local back = { x = -u.x, y = -u.y }
	local p0 = { x = pa.x + u.x * 80, y = pa.y + u.y * 80 }
	local p1 = { x = pb.x - u.x * 80, y = pb.y - u.y * 80 }
	p0.z, p1.z = E.groundZ(pa.x, pa.y, 0), E.groundZ(pb.x, pb.y, 0)
	local W = RL.world(E, co, RL.box(p0, p1))
	local why = "no way"
	local bits = keepBuildings() and withoutBuildings(CTX_ROAD) or CTX_ROAD
	local ctx = context(E, co.ent, bits)
	for _, w in ipairs(RL.ways(E, p0, u, p1, back, W)) do
		local sp, _, refused = RL.trackProposal(E, co, -9001, p0, u, -9002, p1, back, currentYear(E), w.way, W)
		if sp then
			-- (0.6.4: and the engine's dry run of that track, its two ends new nodes where the stations' ends will be: what the
			-- checks do not see (a bridge's piers on a track, water, the slopes) refused it after the stations were built)
			local api = E.api
			local ssp = sp.streetProposal
			local nodes = ssp.nodesToAdd or {}
			for k, q in ipairs({ p0, p1 }) do
				local ne = api.type.NodeAndEntity.new()
				ne.entity = -9000 - k
				local bn = ne.comp
				bn.position = api.type.Vec3f.new(q.x, q.y, q.z)
				ne.comp = bn
				nodes[#nodes + 1] = ne
			end
			ssp.nodesToAdd = nodes
			sp.streetProposal = ssp
			local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(sp, ctx) end)
			if okd and pd and #pd.errorState.messages == 0 and not pd.errorState.critical then return true end
			why = w.what .. ": " .. (okd and pd and (E.C.ser(E.C.marshal(pd.errorState.messages)) .. RL.collides(E, pd)) or tostring(pd))
		else
			why = tostring(refused)
		end
	end
	return false, why
end

-- the track between two ends: each way of RL.ways checked against what is in its way (RL.trackProposal), then a dry run; the
-- first one free is built. True when asked for, "dear", or false and the last reason
function RL.buildTrack(E, co, ea, eb, what)
	local api = E.api
	local year = currentYear(E)
	local okW, W = pcall(RL.world, E, co, RL.box(ea.p, eb.p))
	if not okW then return false, "the world could not be read: " .. tostring(W) end
	local bits = keepBuildings() and withoutBuildings(CTX_ROAD) or CTX_ROAD
	local ctx = context(E, co.ent, bits)
	local why = ""
	for _, w in ipairs(RL.ways(E, ea.p, ea.d, eb.p, eb.d, W)) do
		local okp, sp, len, refused, ncross = pcall(RL.trackProposal, E, co, ea.node, ea.p, ea.d, eb.node, eb.p, eb.d, year, w.way, W)
		if not okp then
			why = "no proposal: " .. tostring(sp)
		elseif not sp then
			why = tostring(refused)
		else
			local okd, pd = pcall(function() return api.engine.util.proposal.makeProposalData(sp, ctx) end)
			if not (okd and pd) then
				why = "dry run failed: " .. tostring(pd)
			else
				pcall(function() why = E.C.ser(E.C.marshal(pd.errorState.messages)) end)
				why = why .. RL.collides(E, pd)
				-- (a segment it collides with: was it among what is in its way (W), and crossed (on a bridge)? for the logs)
				pcall(function()
					local ce = pd.collisionInfo.collisionEntities[1].entity
					local known = false
					for _, x in ipairs(W.edges) do if x.e == ce then known = true end end
					why = why .. (known and " (known)" or " (not known)") .. (refused and "" or "")
				end)
				if #pd.errorState.messages == 0 and not pd.errorState.critical then
					if keepBuildings() and buildingsHit(E, pd) > 0 then
						why = "town buildings in its way"
					else
						local cost = 0
						pcall(function() cost = tonumber(pd.costs) or 0 end)
						if not spendOk(E, co, cost, what) then return "dear" end
						L(E, string.format("%s: %.0f m, %s, %d crossing(s) bridged, cost %d", what, len or 0, w.what, ncross or 0, math.floor(cost)))
						build(E, co.id, api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true, true), what, bits,
							{ kind = "railtrack", pos = { x = (ea.p.x + eb.p.x) / 2, y = (ea.p.y + eb.p.y) / 2, z = (ea.p.z + eb.p.z) / 2 } })
						return true
					end
				end
			end
		end
		L(E, string.format("%s: %s refused: %s", what, w.what, tostring(why):sub(1, 160)))
	end
	return false, why
end

-- the railway of the company under way, read from the world: its two stations (the one near the producer, the one near the
-- industry that takes the cargo), else nil
function RL.underway(E, co, lines)
	local A = E.G.AI
	local stations = RL.mine(E, co, "modular_station")
	if #stations == 0 then return nil, stations end
	local inLine = {}
	for _, l in ipairs(lines) do for _, g in ipairs(l.groups) do inLine[g] = l end end
	local inds = industries(E)
	-- (not the stations of a railway left, see RL.TRIES)
	if A.railGone then
		local keep = {}
		for _, s in ipairs(stations) do if not A.railGone[s.con] then keep[#keep + 1] = s end end
		stations = keep
	end
	-- (each station's industry: the nearest one it reaches)
	for _, s in ipairs(stations) do
		local best, bd
		for _, ind in ipairs(inds) do
			local d = dist(s.pos, ind.pos)
			if d < 500 and (not bd or d < bd) then best, bd = ind, d end
		end
		s.ind = best
		s.term = RL.terminals(E, s.con)
		s.line = s.term and inLine[s.term.group] or nil
	end
	-- (a railway running: its line has a train; or its trains were sold for its losses, see RL.manage: no train for it again)
	local running = {}
	for _, v in ipairs(RL.trains(E, co.ent)) do if v.line >= 0 then running[v.line] = true end end
	for l in pairs(A.railDropped or {}) do running[l] = true end
	-- (a pair: a producer's station, and a station of an industry that takes its cargo, not running yet)
	local paired = {}
	for _, sa in ipairs(stations) do
		for _, sb in ipairs(stations) do
			if sa ~= sb and sa.ind and sb.ind then
				for _, c in ipairs(sa.ind.outputs) do
					if takes(E, sb.ind, c) then
						paired[sa], paired[sb] = true, true
						if not (sa.line and sa.line == sb.line and running[sa.line.e]) then return { a = sa, b = sb, cargo = c }, stations end
					end
				end
			end
		end
	end
	-- (a producer's station alone: the other end of its route, the one begun (A.rail), else the farthest industry within reach that
	-- takes its cargo, as RL.route chose it)
	for _, sa in ipairs(stations) do
		if sa.ind and not paired[sa] and not sa.line then
			local A0 = A.rail
			if A0 and A0.from == sa.ind.e then return { a = sa, toInd = A0.to, cargo = A0.cargo }, stations end
			local best
			for _, c in ipairs(sa.ind.outputs) do
				for _, b in ipairs(inds) do
					local d = dist(sa.ind.pos, b.pos)
					if b.e ~= sa.ind.e and d >= RL.MIN and d <= RL.MAX and takes(E, b, c) and (not best or d > best.d) then best = { toInd = b, cargo = c, d = d } end
				end
			end
			if best then return { a = sa, toInd = best.toInd, cargo = best.cargo }, stations end
		end
	end
	return nil, stations
end

-- One step of the company's railway. True when it acted (a build, a purchase, a line), "wait" when it waits for money, false when
-- there is nothing to do (no railway under way, and none to begin: begin = whether it may begin a new one now)
function RL.project(E, co, lines, money, begin)
	if not RL.on() then return false end
	local A = E.G.AI
	local api = E.api
	local u, stations = RL.underway(E, co, lines)
	if not u then
		-- (a new railway: only with the money for all of it, see RL.cost)
		if not begin then return false end
		if A.railNextAt and E.G.frames < A.railNextAt then return false end
		local r = RL.route(E, co, lines, stations)
		if not r then A.railNextAt = E.G.frames + 3600; return false end
		local train = RL.train(E, r.cargo)
		if not train then
			A.railTried = A.railTried or {}; A.railTried[r.from.e] = true
			L(E, "railway: no train for " .. cargoName(E, r.cargo) .. " on sale")
			return false
		end
		-- (its price: two stations of 0.9 million, a depot of 1.9, about 600 a metre of track in 1972 (the first one, 7.8 km with
		-- 8 bridges, cost 4.36 million), its way 1.3 times the distance, the train)
		local need = 2 * 900000 + 2000000 + r.d * 1.3 * 600 + train.price
		if money - (A.loanCash or 0) < RESERVE + need then
			if E.G.frames - (A.railSaid or -100000) > 3600 then
				A.railSaid = E.G.frames
				L(E, string.format("railway %s %.1f km (industry %d -> %d) waits for %d (has %d)", cargoName(E, r.cargo), r.d / 1000, r.from.e, r.to.e, math.floor(RESERVE + need), math.floor(money)))
			end
			return "wait"
		end
		local a = math.atan2(r.to.pos.y - r.from.pos.y, r.to.pos.x - r.from.pos.x)
		-- (a way first: both stations' places and a track between their ends, see RL.corridor; else the stations would be built
		-- for nothing)
		local okF, clear, why = pcall(RL.corridor, E, co, r.from, r.to, a)
		if not (okF and clear) then
			A.railTried = A.railTried or {}; A.railTried[r.from.e] = true
			L(E, string.format("railway %s %.1f km (industry %d -> %d): no way for it (%s)", cargoName(E, r.cargo), r.d / 1000, r.from.e, r.to.e, tostring(okF and why or clear):sub(1, 160)))
			return false
		end
		A.rail = { from = r.from.e, to = r.to, cargo = r.cargo, at = E.G.frames, a = a }
		L(E, string.format("railway begun: %s %.1f km from industry %d to %d", cargoName(E, r.cargo), r.d / 1000, r.from.e, r.to.e))
		local ok = RL.buildStation(E, co, r.from, a, "A")
		if ok == false then A.railTried = A.railTried or {}; A.railTried[r.from.e] = true; A.rail = nil; L(E, "railway: no place for a station near industry " .. r.from.e) end
		return ok == true or (ok == "dear" and "wait") or false
	end
	-- the other station
	if not u.b then
		local to = u.toInd
		local a = (A.rail and A.rail.a) and (A.rail.a + math.pi) or math.atan2(u.a.pos.y - to.pos.y, u.a.pos.x - to.pos.x)
		local ok = RL.buildStation(E, co, to, a, "B")
		if ok == false then
			L(E, "railway: no place for a station near industry " .. to.e .. ": left")
			A.railTried = A.railTried or {}; A.railTried[u.a.ind.e] = true; A.rail = nil
		end
		return ok == true or (ok == "dear" and "wait") or false
	end
	local sa, sb = u.a, u.b
	if not (sa.term and sb.term) then return false end
	local na, nb = {}, {}
	for _, t in ipairs(sa.term.list) do na[#na + 1] = t.node end
	for _, t in ipairs(sb.term.list) do nb[#nb + 1] = t.node end
	-- the track between them (after a refusal of every curve, tried again a minute later)
	if not RL.path(E, na, nb) then
		local what = "railway track " .. sa.ind.e .. "-" .. sb.ind.e
		local key = sa.con .. ":" .. sb.con
		-- (a build the engine refused when it came, after the dry run let it through: water the dry run does not see, a vehicle
		-- in the way; counted as a refusal of the track, see RL.TRIES)
		local lr = A.lastResult
		if lr and lr.what == what and not lr.ok and lr.frame ~= A.railSeen then
			A.railSeen = lr.frame
			A.railFails = A.railFails or {}
			A.railFails[key] = (A.railFails[key] or 0) + 1
			A.railTrackAt = E.G.frames + 3600
		end
		if A.railFails and (A.railFails[key] or 0) >= RL.TRIES then
			A.railGone = A.railGone or {}
			A.railGone[sa.con], A.railGone[sb.con] = true, true
			A.railTried = A.railTried or {}; A.railTried[sa.ind.e] = true
			A.rail, A.railTrackAt = nil, nil
			L(E, "railway " .. sa.ind.e .. "-" .. sb.ind.e .. " left: its track was refused " .. RL.TRIES .. " times")
			return false
		end
		if A.railTrackAt and E.G.frames < A.railTrackAt then return false end
		local ea, eb = RL.ends(E, sa.con), RL.ends(E, sb.con)
		local best
		for _, x in ipairs(ea) do
			for _, y in ipairs(eb) do
				local d = dist(x.p, y.p)
				if not best or d < best.d then best = { a = x, b = y, d = d } end
			end
		end
		if not best then L(E, "railway: no free track end at its stations"); return false end
		local ok, why = RL.buildTrack(E, co, best.a, best.b, what)
		if ok == false then
			A.railFails = A.railFails or {}
			local key = sa.con .. ":" .. sb.con
			A.railFails[key] = (A.railFails[key] or 0) + 1
			A.railTrackAt = E.G.frames + 3600
			L(E, "railway track refused (" .. A.railFails[key] .. "): " .. tostring(why):sub(1, 200))
			-- (left after RL.TRIES rounds of refusals: its two stations are no railway under way any more, its producer is not
			-- tried again in this session)
			if A.railFails[key] >= RL.TRIES then
				A.railGone = A.railGone or {}
				A.railGone[sa.con], A.railGone[sb.con] = true, true
				A.railTried = A.railTried or {}; A.railTried[sa.ind.e] = true
				A.rail, A.railTrackAt = nil, nil
				L(E, "railway " .. sa.ind.e .. "-" .. sb.ind.e .. " left: no track could be laid between its stations")
			end
			return false
		end
		return ok == true or "wait"
	end
	-- a depot of the company that reaches the first station
	local depot
	for _, d in ipairs(RL.mine(E, co, "rail_depot")) do
		local outs = {}
		pcall(function()
			for _, dp in ipairs(d.c.depots) do
				local vd = api.engine.getComponent(dp, api.type.ComponentType.VEHICLE_DEPOT)
				for k = 1, #vd.outNodes do outs[#outs + 1] = vd.outNodes[k] end
				if not depot and #outs > 0 and RL.path(E, outs, na) then depot = { con = d.con, depot = dp, pos = d.pos } end
			end
		end)
	end
	if not depot then
		-- (one of its depots near either station, not left)
		local near, nearSt
		for _, d in ipairs(RL.mine(E, co, "rail_depot")) do
			if not (A.railGone and A.railGone[d.con]) then
				for _, st in ipairs({ sa, sb }) do if not near and dist(d.pos, st.pos) < 600 then near, nearSt = d, st end end
			end
		end
		if not near then
			if A.railDepotAt and E.G.frames < A.railDepotAt then return false end
			-- (behind one of the stations, facing it: see RL.dryDepot; the depot and its approach dry run together, so that the
			-- approach is clear too)
			for _, st in ipairs({ sa, sb }) do
				local back = RL.ends(E, st.con)[1]
				if back then
					local said = 0
					for _, gap in ipairs({ 80, 140, 200, 280 }) do
						for _, lat in ipairs({ 0, 60, -60, 120, -120, 200, -200 }) do
							local free, sp, ctx, cost, why, bits, O = RL.dryDepot(E, co, back, gap, lat)
							if free then
								if not spendOk(E, co, (cost or 2000000) + 50000, "train depot") then return "wait" end
								L(E, string.format("train depot behind station %d: its exit %.0f m out, %.0f m aside, cost %s", st.con, gap, lat, tostring(cost and math.floor(cost))))
								build(E, co.id, api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true, true), "train depot", bits, { kind = "raildepot", pos = { x = O.x, y = O.y, z = 0 } })
								return true
							end
							said = said + 1
							if said <= 3 then L(E, "train depot behind station " .. st.con .. ", " .. gap .. " m out, " .. lat .. " aside: " .. tostring(why):sub(1, 140)) end
						end
					end
				end
			end
			-- (its track is laid: never left for want of a depot, looked for again five minutes later)
			A.railDepotAt = E.G.frames + 18000
			L(E, "railway " .. sa.ind.e .. "-" .. sb.ind.e .. ": no place for a depot behind its stations, looked for again in five minutes")
			return false
		end
		-- (its track to the station: from the depot's exit to the station's free end nearest to it)
		local de, se = { RL.depotExit(E, near.con) }, RL.ends(E, nearSt.con)
		local best
		for _, x in ipairs(de) do for _, y in ipairs(se) do
			local d = dist(x.p, y.p)
			if not best or d < best.d then best = { a = x, b = y, d = d } end
		end end
		if not best then L(E, "railway: no free end between depot " .. near.con .. " and station " .. nearSt.con); return false end
		-- (a depot whose track is refused RL.TRIES times is left: another one is built)
		if A.depotTrackAt and E.G.frames < A.depotTrackAt then return false end
		local ok, why = RL.buildTrack(E, co, best.a, best.b, "depot track " .. near.con)
		if ok == false then
			A.depotFails = A.depotFails or {}
			A.depotFails[near.con] = (A.depotFails[near.con] or 0) + 1
			A.depotTrackAt = E.G.frames + 1800
			L(E, "railway depot track refused (" .. A.depotFails[near.con] .. "): " .. tostring(why):sub(1, 200))
			if A.depotFails[near.con] >= RL.TRIES then
				A.railGone = A.railGone or {}
				A.railGone[near.con] = true
				L(E, "train depot " .. near.con .. " left: no track joins it to its station")
			end
			return false
		end
		return ok == true or "wait"
	end
	-- the line
	local line = sa.line and sa.line == sb.line and sa.line or nil
	if not line then
		local stop0
		pcall(function() stop0 = E.C.marshal(api.type.Line.Stop.new()) end)
		local template = E.C.marshal(api.type.Line.new())
		local s1 = freightStop(E, sa.term, stop0, u.cargo)
		pcall(function() s1.loadMode = api.type.enum.LineLoadMode and api.type.enum.LineLoadMode.FULL_LOAD_ANY or s1.loadMode end)
		template.stops = { s1, freightStop(E, sb.term, stop0) }
		local name = AINAME .. " " .. cargoName(E, u.cargo) .. " (train)"
		act(E, co.id, "makeLineCreateCmd", { n = 4, [1] = name, [2] = E.C.marshal(api.type.Vec3f.new(0.8, 0.5, 0.1)), [3] = co.ent, [4] = template })
		-- (its lines of trains are not counted with the others, see myLines: the line is looked for again at the next look instead)
		A.busy = { what = "line " .. name, since = E.G.frames, until_ = E.G.frames + 300 }
		journal(E, co.id, "railline", sa.pos, name, u.cargo)
		L(E, "train line requested: " .. name)
		return true
	end
	-- its train
	local trains, idle = 0, nil
	for _, v in ipairs(RL.trains(E, co.ent)) do
		if v.line == line.e then trains = trains + 1 elseif v.line < 0 then idle = v.e end
	end
	if idle then
		act(E, co.id, "makeVehicleSetLineCmd", { n = 3, [1] = idle, [2] = line.e, [3] = 0 })
		A.busy = { what = "train " .. idle .. " to line " .. line.e, since = E.G.frames, until_ = E.G.frames + 120 }
		L(E, "train " .. idle .. " sent to line " .. line.e)
		return true
	end
	if trains == 0 then
		local t = RL.train(E, u.cargo)
		if not t then return false end
		if not spendOk(E, co, t.price, "train") then return "wait" end
		RL.buyTrain(E, co, depot.depot, t, u.cargo, depot.pos)
		return true
	end
	-- done: this railway runs
	A.rail = nil
	return false
end

-- The company's lines of trains, every RL.LOOK frames: its trains, its result over the last two months, the cargo waiting at its
-- first stop (logged); a train more (RL.MAXTRAINS at most) when more than 1.5 trains' worth waits there, the line does not lose
-- money (or is younger than its two months) and the company can pay for it, bought at the company's depot that reaches it; a
-- train less when it loses money with nothing waiting RL.LOSSLOOKS looks in a row. True when it bought or sold one
function RL.manage(E, co, money)
	local A = E.G.AI
	local api = E.api
	-- (a train bought for a line, idle in its depot: sent to that line at once)
	if A.trainFor then
		for _, v in ipairs(RL.trains(E, co.ent)) do
			if v.line < 0 then
				act(E, co.id, "makeVehicleSetLineCmd", { n = 3, [1] = v.e, [2] = A.trainFor, [3] = 0 })
				A.busy = { what = "train " .. v.e .. " to line " .. A.trainFor, since = E.G.frames, until_ = E.G.frames + 120 }
				L(E, "train " .. v.e .. " sent to line " .. A.trainFor)
				A.trainFor = nil
				return true
			end
		end
	end
	if A.railLookAt and E.G.frames < A.railLookAt then return false end
	A.railLookAt = E.G.frames + RL.LOOK
	local trains = RL.trains(E, co.ent)
	if #trains == 0 then return false end
	for _, l in ipairs(myLines(E, co.ent, true)) do
		if l.groups[1] and RL.isRailGroup(E, l.groups[1]) then
			local n, model = 0, nil
			for _, v in ipairs(trains) do if v.line == l.e then n = n + 1; model = model or v.e end end
			local cargo, waiting = nil, 0
			pcall(function()
				local lc = E.C.marshal(api.engine.getComponent(l.e, api.type.ComponentType.LINE))
				for i, on in pairs(lc.stops[1].stopConfig.load) do if on == true then cargo = i - 1 end end
			end)
			if cargo then pcall(function() waiting = api.engine.system.simEntityAtTerminalSystem.getLineStopSimEntitiesCount(l.e, 0, cargo) or 0 end) end
			local bal = lineBalance(E, l.e)
			local t = cargo and RL.train(E, cargo)
			L(E, string.format("train line %d (%s): %d train(s), 2-month result %s, %d waiting at its first stop", l.e, cargo and cargoName(E, cargo) or "?", n,
				bal and tostring(math.floor(bal)) or "?", waiting))
			A.railSince = A.railSince or {}
			A.railSince[l.e] = A.railSince[l.e] or E.gameTime()
			local young = E.gameTime() - A.railSince[l.e] < 240000
			-- (a line that loses money past its first two months with nothing waiting, RL.LOSSLOOKS looks in a row: its trains sold
			-- one a look, its stations and track kept for a train later; a line of trains is never destroyed)
			A.railLoss = A.railLoss or {}
			if not young and (bal or 0) < 0 and waiting == 0 and n > 0 then A.railLoss[l.e] = (A.railLoss[l.e] or 0) + 1 else A.railLoss[l.e] = 0 end
			if A.railLoss[l.e] >= RL.LOSSLOOKS and model then
				A.railLoss[l.e] = RL.LOSSLOOKS - 1
				-- (and no train bought for it again: RL.underway and RL.project leave a line given up so, see RL.isRailGroup's callers)
				A.railDropped = A.railDropped or {}
				A.railDropped[l.e] = true
				sellVehicle(E, co, model, "train line " .. l.e .. " losing money with nothing to carry", l.e)
				return true
			end
			if t and n > 0 and n < RL.MAXTRAINS and not (A.railDropped and A.railDropped[l.e]) and waiting > 1.5 * t.seats and ((bal or 0) >= 0 or young) and money - (A.loanCash or 0) > RESERVE + t.price then
				-- (the company's depot that reaches the line's first stop)
				local nodes = {}
				pcall(function()
					local sg = api.engine.getComponent(l.groups[1], api.type.ComponentType.STATION_GROUP)
					for k = 1, #sg.stations do
						local sc = api.engine.getComponent(sg.stations[k], api.type.ComponentType.STATION)
						for i = 1, #sc.terminals do nodes[#nodes + 1] = sc.terminals[i].vehicleNodeId end
					end
				end)
				for _, d in ipairs(RL.mine(E, co, "rail_depot")) do
					for _, dp in ipairs(d.c.depots) do
						local outs = {}
						pcall(function() local vd = api.engine.getComponent(dp, api.type.ComponentType.VEHICLE_DEPOT); for k = 1, #vd.outNodes do outs[#outs + 1] = vd.outNodes[k] end end)
						if #outs > 0 and #nodes > 0 and RL.path(E, outs, nodes) then
							if not spendOk(E, co, t.price, "train") then return false end
							RL.buyTrain(E, co, dp, t, cargo, d.pos)
							A.trainFor = l.e
							L(E, string.format("train line %d: %d waiting, a train more (%d)", l.e, waiting, n + 1))
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- buys a train (RL.train's t) at a depot
function RL.buyTrain(E, co, depot, t, cargo, pos)
	local A = E.G.AI
	local function part(id)
		return { part = { modelId = id, reversed = false, compartment2loadConfig = { { loadConfigIndex = 0, cargoTypeId = -1, __ud = true } },
			color = { x = -1, y = -1, z = -1, __vec = true }, __ud = true }, purchaseTime = 0, maintenanceChange = 0, maintenanceState = 1,
			autoLoadConfig = { true }, __ud = true }
	end
	local parts = { part(t.loco.id) }
	for _ = 1, t.n do parts[#parts + 1] = part(t.wagon.id) end
	local groups, mus = {}, {}
	for i = 1, #parts do groups[i] = 1; mus[i] = "" end
	act(E, co.id, "makeVehicleBuyCmd", { n = 3, [1] = co.ent, [2] = depot, [3] = { vehicles = parts, vehicleGroups = groups, muFileNames = mus, __ud = true } })
	A.busy = { what = "train", since = E.G.frames, until_ = E.G.frames + 600 }
	L(E, string.format("train requested: %s + %d x %s (%d %s) at depot %d", t.loco.name, t.n, t.wagon.name, t.seats, cargoName(E, cargo), depot))
	journal(E, co.id, "train", pos, tostring(t.loco.name):match("([^/]+)%.mdl$") or t.loco.name, cargo)
end

-- the company's trains: { e, line }
function RL.trains(E, ent)
	local api = E.api
	local out = {}
	for _, v in ipairs(E.R.entitiesWith("TRANSPORT_VEHICLE")) do
		if ownerOf(E, v) == ent then
			local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
			if tv and RL.isTrain(E, tv) then out[#out + 1] = { e = v, line = tv.line or -1 } end
		end
	end
	return out
end

function RL.isTrain(E, tv)
	local yes = false
	pcall(function() yes = tv.carrier == E.api.type.enum.Carrier.RAIL end)
	return yes
end

-- (a line of trains: its first stop at a train station; kept apart from the buses and trucks, see myLines)
function RL.isRailGroup(E, group)
	local T = E.G.AIT or {}
	T.railGroup = T.railGroup or {}
	local v = T.railGroup[group]
	if v == nil then
		v = false
		pcall(function()
			local sg = E.api.engine.getComponent(group, E.api.type.ComponentType.STATION_GROUP)
			local con = E.api.engine.system.streetConnectorSystem.getConstructionEntityForStation(sg.stations[1])
			local c = E.api.engine.getComponent(con, E.api.type.ComponentType.CONSTRUCTION)
			v = tostring(c.fileName):find("stations/rail/", 1, true) ~= nil
		end)
		T.railGroup[group] = v
	end
	return v
end

-- ------------------------------------------------------------------ the step

local function join(E)
	local G = E.G
	local A = G.AI
	if A.joinSent and G.frames - A.joinSent < 1800 then return end
	A.joinSent = G.frames
	local now = E.gameTime()
	G.oseq = G.oseq + 1
	local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and E.gameSpeed() == 0
	-- (a running session: stamped 60 steps ahead. A player's builds are held by the native module up to their time, a company's
	-- arrival is not: stamped a few steps ahead as they are, the host's simulation, which runs ahead of its interface, had passed
	-- that time when its hold came, and created the company 4 steps after the other game (ser050 of 2026-10-28: another entity,
	-- everything drifted). That far ahead every game holds at its time, the gathering of the joins included)
	local a = { fn = "mpfCoJoin", origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
		at = paused and E.pausedStamp(now) or (E.stampFor(now) + 60 * E.STEP), paused = paused or nil, native = true,
		args = { key = AIKEY, name = AINAME, host = false, mode = "separate", start = AIMONEY or G.coStart, color = AICOLOR, cname = AINAME } }
	E.send("act", a)
	a.recvFrame = G.frames
	G.nativeQueue[#G.nativeQueue + 1] = a
	if paused and G.joinTurns then G.ptIssue(G.me, G.joinTurnId(a)) end
	L(E, "company announced: " .. AINAME)
end

local function step(E)
	local G = E.G
	local A = G.AI
	local co = aiCompany(E)
	if not co then return join(E) end
	if not co.ent then return end
	-- (0.5.14: a new company under this number, after a bankruptcy: the last one's memory of its towns, lines and garages is
	-- dropped, it named entities of another company. MPFEVER_AIRETRY=0: kept)
	if A.ent ~= nil and A.ent ~= co.ent and os.getenv("MPFEVER_AIRETRY") ~= "0" then
		for k in pairs(A) do A[k] = nil end
		L(E, "a new company (entity " .. co.ent .. "): the last one's memory dropped")
	end
	A.ent = co.ent
	-- the colour the host gave it in the lobby (a savegame's company keeps its own until then): asked once, as a player would
	if AICOLOR and co.color ~= AICOLOR and not A.recolorAsked and E.CO.colorFree(G.co, AICOLOR, co.id) then
		A.recolorAsked = true
		act(E, co.id, "makeScriptingSendEventCmd", { n = 4, [1] = "mpfever", [2] = "mpfever", [3] = "recolor", [4] = { color = AICOLOR } })
		L(E, "colour " .. tostring(AICOLOR) .. " asked")
		return
	end
	if A.busy then
		local age = G.frames - A.busy.since
		-- (a command's result shows in the world: the line or the vehicle appears)
		if A.busy.linesBefore and #myLines(E, co.ent) > A.busy.linesBefore then
			L(E, A.busy.what .. ": done")
			if A.busy.jr then journal(E, co.id, A.busy.jr.kind, A.busy.jr.pos, A.busy.jr.a, A.busy.jr.b) end
			A.busy = nil
		elseif A.busy.vehBefore and #myVehicles(E, co.ent) > A.busy.vehBefore then
			-- (what a bus costs: measured on the company's account)
			local paid = (A.busy.moneyBefore or 0) - balanceOf(E, co.ent)
			-- (a truck's price kept apart: taken for a bus's, it held the bus lines back until the company had a million)
			if paid > 10000 and paid < 5000000 then
				-- (never under the price of a bus of 1940: the account's difference also holds what the company earned meanwhile, and a
				-- price measured at 2 720 let a company buy at every look)
				paid = math.max(paid, BUS_COST)
				if A.busy.jr and A.busy.jr.kind == "truck" then A.truckCost = paid else A.busCost = paid end
			end
			L(E, A.busy.what .. ": done" .. (paid > 0 and (", paid " .. math.floor(paid)) or ""))
			if A.busy.jr then journal(E, co.id, A.busy.jr.kind, A.busy.jr.pos, A.busy.jr.a, A.busy.jr.b) end
			A.busy = nil
		elseif A.busy.until_ and G.frames >= A.busy.until_ then A.busy = nil
		elseif age > 1200 then L(E, A.busy.what .. ": no answer, given up"); A.busy = nil end
		if A.busy then return end
	end
	local money = balanceOf(E, co.ent)
	local stops = myStops(E, co.ent)
	local depots = myDepots(E, co.ent)
	local lines = myLines(E, co.ent)
	local vehicles = myVehicles(E, co.ent)
	-- (0.5.14) the money kept back: the level's, and at least a few months of what its vehicles cost to run (a fixed reserve let a
	-- grown fleet fall into debt at its first bad months). Read at most every 10 s. MPFEVER_AIRESERVE=0: the level's only
	if os.getenv("MPFEVER_AIRESERVE") ~= "0" then
		if not A.runAt or G.frames - A.runAt > 600 then
			A.runAt = G.frames
			local run = 0
			-- (0.6.4: its trains too, kept apart from its vehicles, see myVehicles)
			local all = vehicles
			if RL.on() then
				all = {}
				for _, v in ipairs(vehicles) do all[#all + 1] = v end
				for _, v in ipairs(RL.trains(E, co.ent)) do all[#all + 1] = v end
			end
			for _, v in ipairs(all) do
				local ok, c = pcall(function() return E.api.engine.util.vehicle.getRunningCost(v.e) end)
				if ok and type(c) == "number" then run = run + c end
			end
			A.runCost = run
		end
		RESERVE = math.max(LV.reserve, LV.reserve / 2 + (A.runCost or 0) * (LV.runMonths or 4) / 12)
	end
	-- (0.5.14) and its loans' monthly payments for as many months; the loans' money is no money to spare (see mayExpand).
	-- MPFEVER_AILOANBOOK=0: as before
	if os.getenv("MPFEVER_AILOANBOOK") ~= "0" then
		A.loanCount, A.loanOwe, A.loanMonthly = loanBook(E, co)
		RESERVE = RESERVE + A.loanMonthly * (LV.runMonths or 4)
		A.loanCash = A.loanOwe
	end
	-- (0.6) its floor, see FLOOR and spendOk
	FLOOR = floorOf(A.runCost, A.loanMonthly, RESERVE)
	if G.frames - (A.reportAt or -100000) > 1800 then
		A.reportAt = G.frames
		-- (0.5.14: what it keeps back, its lines' result together over the last two months and its fleet's running costs a year)
		local res = companyResult(E, lines)
		L(E, string.format("company %d (entity %d): money %d, %d stop(s), %d depot(s), %d line(s), %d vehicle(s), kept back %d, lines' 2-month result %s, running costs %d a year",
			co.id, co.ent, money, #stops, #depots, #lines, #vehicles, math.floor(RESERVE), res and tostring(math.floor(res)) or "?", math.floor(A.runCost or 0)))
		-- (0.6: its floor and its long-term freight)
		if ltOn() or os.getenv("MPFEVER_AIFLOOR") ~= "0" then
			local lts = {}
			for e, lt in pairs(A.lt or {}) do lts[#lts + 1] = e .. " " .. tostring(lt.state) .. " " .. math.floor(lt.spent or 0) .. "/" .. math.floor(lt.budget or 0) end
			table.sort(lts)
			L(E, "floor " .. math.floor(FLOOR) .. "; long-term lines: " .. (#lts > 0 and table.concat(lts, ", ") or "none") .. (A.ltPending and " (one asked for)" or ""))
		end
	end
	-- where each line runs: the middle of its stops (the garage of its new buses is looked for from there)
	local groupPos = {}
	for _, s in ipairs(stops) do groupPos[s.group] = s.pos end
	for _, l in ipairs(lines) do
		local n, mx, my = 0, 0, 0
		for _, g in ipairs(l.groups) do if groupPos[g] then n = n + 1; mx = mx + groupPos[g].x; my = my + groupPos[g].y end end
		if n > 0 then l.mid = { x = mx / n, y = my / n } end
	end
	-- vehicles without a line go to the line they were bought for, else the company's last line (once a minute at most each)
	A.lineSent = A.lineSent or {}
	for _, v in ipairs(vehicles) do
		local okD, vdepot = pcall(function() return E.api.engine.getComponent(v.e, E.api.type.ComponentType.TRANSPORT_VEHICLE).depot end)
		local linked = okD and type(vdepot) == "number" and vdepot >= 0 and depotLinked(E, vdepot)
		if (v.line == nil or v.line < 0) and #lines > 0 and not A.noAssign and linked then
			if G.frames - (A.lineSent[v.e] or -100000) > 3600 then
				A.lineSent[v.e] = G.frames
				local target = lines[#lines].e
				for _, l in ipairs(lines) do if l.e == A.forLine then target = l.e end end
				-- (0.5.14: only to the line it was bought for, still running; else it is sold - the company's last line could be of
				-- another kind, a bus on a truck line. MPFEVER_AISTRAY=0: the last line, as before)
				if os.getenv("MPFEVER_AISTRAY") ~= "0" then
					local own = nil
					for _, l in ipairs(lines) do if l.e == A.forLine and not dropped(E, l.e) then own = l.e end end
					if not own then
						sellVehicle(E, co, v.e, "bought for a line that is gone")
						return
					end
					target = own
				end
				act(E, co.id, "makeVehicleSetLineCmd", { n = 3, [1] = v.e, [2] = target, [3] = 0 })
				A.busy = { what = "vehicle " .. v.e .. " to line " .. target, since = G.frames, until_ = G.frames + 120 }
				L(E, "vehicle " .. v.e .. " sent to line " .. target)
				return
			elseif G.frames - A.lineSent[v.e] == 600 or G.frames - A.lineSent[v.e] == 601 or (G.frames - A.lineSent[v.e]) % 1800 < TICK then
				pcall(function()
					local tv = E.api.engine.getComponent(v.e, E.api.type.ComponentType.TRANSPORT_VEHICLE)
					L(E, "vehicle " .. v.e .. " still without a line: " .. E.C.ser(E.C.marshal(tv)):sub(1, 600))
				end)
			end
		end
	end
	-- the lines first (a bus more where full, a broken line given up), then the best pair of towns, then the big towns' own lines
	-- (the towns' own lines across their streets first, as the players' best filled lines; then the lines between towns)
	sampleUse(E, lines)
	-- (0.6: its long-term freight lines' samples and verdicts first, the fleet rules read them, see ltSync)
	ltSync(E, co, lines, vehicles, money)
	if manageLines(E, co, lines, vehicles, money) then return end
	-- every freight line its first two trucks as soon as it is there (whatever the turn of the projects below: a line left without a
	-- truck was given up as empty after a few looks)
	if os.getenv("MPFEVER_AIFREIGHT") ~= "0" then
		A.trucksFor = A.trucksFor or {}
		for _, l in ipairs(lines) do
			local f = freightOf(E, l)
			-- (0.5.14: the trucks it has, not the ones asked for: two refused purchases left a line with no truck, given up as empty
			-- soon after; at most 5 asks. MPFEVER_AIRETRY=0: two asks as before)
			local asks = os.getenv("MPFEVER_AIRETRY") == "0" and 2 or 5
			if f and (A.trucksFor[l.e] or 0) < asks and not dropped(E, l.e) then
				local n = 0
				for _, v in ipairs(vehicles) do if v.line == l.e then n = n + 1 end end
				-- (0.5.14, MPFEVER_AIFLEET: one truck to begin with, more as cargo waits and the line earns; two before)
				if n >= ((os.getenv("MPFEVER_AIFLEET") ~= "0") and 1 or 2) then A.trucksFor[l.e] = asks
				elseif money > RESERVE + (A.truckCost or BUS_COST) then
					local depot = garagesNear(E, co.ent, f.from.pos, 5000)[1]
					if depot then
						A.trucksFor[l.e] = (A.trucksFor[l.e] or 0) + 1
						A.forLine = l.e
						buyTruck(E, co, depot.depot, f.cargo)
						return
					end
				end
			end
		end
	end
	-- (0.5.14: whether it may open something new now, see mayExpand)
	local grow = mayExpand(E, co, lines, money)
	-- (0.6.4) its railway: one under way goes on (a station, the track, the depot, the line, the train, each as soon as it has the
	-- money); a new one only when it may grow and holds plenty besides its reserve (RL.project checks the railway's whole price)
	if RL.on() then
		local begin = grow and money - (A.loanCash or 0) >= RESERVE + (LV.freeCash or 0)
		local r = RL.project(E, co, myLines(E, co.ent, true), money, begin)
		if r == true then return end
		-- (and its lines of trains: a train more where cargo piles up, see RL.manage)
		if RL.manage(E, co, money) == true then return end
	end
	-- (0.6) its long-term freight line when it has none under way and can afford one (see ltProject): before the freight of plenty of
	-- money and the buses' new projects. A path search alone builds nothing: the look goes on
	if grow and ltProject(E, co, stops, lines, vehicles, money) == true then return end
	-- freight: a route of trucks while the company has fewer freight lines than half its lines (one at first), then the buses.
	-- (0.5.14: only with plenty of money besides its reserve and its loans, the level's freeCash: a producer of 1972 makes 50 to
	-- 270 a year until its cargo is carried, and no freight line of the tests of 2026-10-30 paid its truck, 160 000 a year, while
	-- the lines between towns earned up to 350 000 in two months. MPFEVER_AIFREIGHTRICH=0: with the growth gate only, as before)
	local freightRich = os.getenv("MPFEVER_AIFREIGHTRICH") == "0" or money - (A.loanCash or 0) >= RESERVE + (LV.freeCash or 0)
	if os.getenv("MPFEVER_AIFREIGHT") ~= "0" and grow and freightRich then
		local nf = 0
		for _, l in ipairs(lines) do if freightOf(E, l) then nf = nf + 1 end end
		-- (a path search alone builds nothing: the buses' work goes on in the same look)
		if nf < math.max(1, math.ceil(#lines * LV.freightShare)) and freightProject(E, co, stops, lines, vehicles, money) == true then return end
	end
	-- (0.5.14, every level since the test of 2026-10-30, where Easy's town lines lost what Normal's and Hard's lines between towns
	-- earned: the lines between towns before the towns' own lines, a fare grows with the distance flown and the short town lines
	-- earn the least. MPFEVER_AIORDER=0: the towns first, as before)
	local pairsFirst = LV.profitFirst and os.getenv("MPFEVER_AIORDER") ~= "0"
	-- (a pair that only waits for money lets the towns' lines and their buses go on, see pairProject's "wait")
	if pairsFirst and pairProject(E, co, stops, lines, vehicles, money, grow) == true then return end
	for _, t in ipairs(townsForLines(E, co.ent)) do
		local town = t.e
		if (A.skipTown and A.skipTown[town]) or t.size < LV.townMin then goto continue end
		do
			-- the garage of the town's buses (see garageFor)
			local tc = centre(E, town, E.api.type.enum.LandUseType.RESIDENTIAL)
			if not tc then goto continue end
			-- (0.5.14: no garage for a town whose own line the company has not begun while its growth waits, see mayExpand)
			if not grow and not (A.townBegun and A.townBegun[town]) then goto continue end
			local g = garageFor(E, co, tc, money, townName(E, town))
			if g == "building" then return end
			if not g then
				if not (A.noGarage and A.noGarage[town]) then
					A.noGarage = A.noGarage or {}; A.noGarage[town] = true
					L(E, "no road garage joined to the streets within 4 km of " .. townName(E, town) .. ": town skipped for now")
				end
				goto continue
			end
			local have, missing = townProject(E, co, town, stops)
			-- (a town's line not begun yet: only when the company may grow, see mayExpand)
			-- (a town with no stop of the company yet: a new project; one under way, begun when it could grow, goes on)
			-- (a town whose own line the company began, A.townBegun: a stop of a line between towns does not count)
			if not grow and #missing > 0 and not (A.townBegun and A.townBegun[town]) then goto continue end
			if #missing > 0 then
				-- (a town's line is begun only with the money to end it: its stops and two buses; stops left without a line cost
				-- their upkeep for nothing)
				if money < RESERVE + 30000 * #missing + 2 * (A.busCost or BUS_COST) then return end
				local w = missing[1]
				local avoid = {}
				for _, s in ipairs(stops) do avoid[#avoid + 1] = s.pos end
				-- (within the 200 m townProject takes, 0.5.14: a stop built 200 to 300 m away was never found again and another one
				-- was built, and another, until the town ran out of streets. MPFEVER_AIRETRY=0: 300 m as before)
				local segs = streetSegmentsNear(E, w.p, os.getenv("MPFEVER_AIRETRY") == "0" and 300 or 200, avoid)
				local tries = A.failed and A.failed["stop " .. town .. ":" .. w.use] or 0
				local s = segs[1 + tries]
				if not s or tries > 4 then
					-- (a point of the ring is left out; a district centre without a stop leaves the town)
					-- (0.5.14: a district centre too when the town has two stops already: the line is made with those, its stops were
					-- left without a line before. MPFEVER_AIRETRY=0: the town skipped)
					if w.use:sub(1, 4) == "RING" or (#have >= 2 and os.getenv("MPFEVER_AIRETRY") ~= "0") then
						L(E, "no street for the stop " .. w.use .. " of " .. townName(E, town) .. ": point left out")
						A.dropPoint = A.dropPoint or {}; A.dropPoint[town .. ":" .. w.use] = true
						return
					end
					L(E, "no street for a stop near the " .. w.use .. " centre of " .. townName(E, town) .. ": town skipped")
					A.skipTown = A.skipTown or {}; A.skipTown[town] = true
					goto continue
				end
				L(E, "stop near the " .. w.use .. " centre of " .. townName(E, town) .. " (" .. math.floor(s.d) .. " m from it)")
				-- (0.6: not built under the floor, see spendOk: the town waits)
				if buildStop(E, co, s.e, town .. ":" .. w.use) == false then return end
				A.townBegun = A.townBegun or {}
				A.townBegun[town] = true
				-- (a refused stop counts against that centre: the next try takes the next segment)
				if A.busy then A.busy.what = "stop " .. town .. ":" .. w.use end
				return
			end
			-- a depot of the company within 400 m of the stops
			local groups, mid = {}, { x = 0, y = 0 }
			for _, h in ipairs(have) do groups[#groups + 1] = h.stop.group; mid.x = mid.x + h.stop.pos.x / #have; mid.y = mid.y + h.stop.pos.y / #have end
			if #groups < 2 then
				if not (A.oneStop and A.oneStop[town]) then
					A.oneStop = A.oneStop or {}; A.oneStop[town] = true
					L(E, townName(E, town) .. " has room for one stop only: no line there")
				end
				goto continue
			end
			-- a garage joined to the streets within 4 km (its own first): the buses are bought there
			local depot = garagesNear(E, co.ent, mid, 5000)[1]
			if not depot then
				if not (A.noGarage and A.noGarage[town]) then
					A.noGarage = A.noGarage or {}; A.noGarage[town] = true
					L(E, "no road garage joined to the streets within 4 km of " .. townName(E, town) .. ": town skipped for now")
				end
				goto continue
			end
			local line = lineFor(E, lines, groups)
			if not line then
				-- (a line only with the money for its first two buses, as the lines between towns: a line left without one is given up
				-- as empty after a few looks, its stops kept for nothing)
				if money < RESERVE + 2 * (A.busCost or BUS_COST) then return end
				if not grow then goto continue end
				createLine(E, co, groups, town)
				return
			end
			-- buses: two at first, more as the town is bigger
			local onLine = 0
			for _, v in ipairs(vehicles) do if v.line == line.e then onLine = onLine + 1 end end
			-- (0.5.14, MPFEVER_AIFLEET: one bus to begin with, more as it fills and earns, see manageLines: one bus well filled was the
			-- only town line that earned in the tests of 2026-10-29, two to five at 20-30 % lost money)
			local wantBuses = (os.getenv("MPFEVER_AIFLEET") ~= "0") and 1 or math.min(5, LV.maxBus, 2 + math.floor(#groups / 2))
			-- (0.5.14: not to a line whose bus was just sold for being empty, as the other purchases: it was bought back at the next
			-- look, sold again at the next regular one, and the line never given up)
			if onLine < wantBuses and not A.noBuses and not dropped(E, line.e) and ((A.emptyRuns or {})[line.e] or 0) < 3 then
				if money < RESERVE + (A.busCost or BUS_COST) then return end
				A.forLine = line.e
				buyBus(E, co, depot.depot)
				return
			end
		end
		::continue::
	end
	-- every line two buses at least (the lines between towns too)
	for _, l in ipairs(lines) do
		local n = 0
		for _, v in ipairs(vehicles) do if v.line == l.e then n = n + 1 end end
		if n < ((os.getenv("MPFEVER_AIFLEET") ~= "0") and 1 or 2) and not A.noBuses and not dropped(E, l.e) and money > RESERVE + (A.busCost or BUS_COST) and ((A.emptyRuns or {})[l.e] or 0) == 0 then
			local f = os.getenv("MPFEVER_AIFREIGHT") ~= "0" and freightOf(E, l)
			local depot = garagesNear(E, co.ent, l.mid or (f and f.from.pos) or { x = 0, y = 0 }, 5000)[1]
			if depot then
				A.forLine = l.e
				buyFor(E, co, l, depot.depot)
				return
			end
		end
	end
	if not pairsFirst and pairProject(E, co, stops, lines, vehicles, money, grow) == true then return end
	-- (0.5.14: nothing done with money to spare, said once a minute: the reason shows in the log)
	if money > 2 * RESERVE and G.frames - (A.idleSaid or -100000) > 3600 then
		A.idleSaid = G.frames
		L(E, "idle with " .. math.floor(money) .. (grow and ": no town, pair of towns or freight route left to open" or ": its growth waits (see above)"))
	end
end

-- (for the dev probes)
M.f = { aiCompany = aiCompany, myStops = myStops, myDepots = myDepots, myLines = myLines, myVehicles = myVehicles, bestBus = bestBus,
	act = act, build = build, buildStop = buildStop, createLine = createLine, buyBus = buyBus, join = join, context = context,
	findDepotPlace = findDepotPlace, townsBySize = townsBySize, currentYear = currentYear, garagePlaces = garagePlaces,
	buildGarage = buildGarage, garagesNear = garagesNear, garageCapture = garageCapture, industries = industries, roadTerminals = roadTerminals,
	bestTruck = bestTruck, bestFreight = bestFreight, freightOf = freightOf, roadPath = roadPath, cargoName = cargoName,
	bestTownFreight = bestTownFreight, townWants = townWants, townName = townName,
	-- (0.6)
	manageLines = manageLines, lineIdle = lineIdle, mayExpand = mayExpand, spendOk = spendOk, ltSync = ltSync, ltProject = ltProject, connectIndustry = connectIndustry, roadProject = roadProject,
	townFreightProject = townFreightProject, industryProject = industryProject, freightProject = freightProject,
	buildingsHit = buildingsHit, stockTakes = stockTakes, stopReaches = stopReaches, townDropPoint = townDropPoint, townGood = townGood,
	step = step, RL = RL }

-- (0.6) the pure rules, and the module's state of the company under way, for the offline tests (tests/test_ai_*.py)
M.p = { floorOf = floorOf, ltBudget = ltBudget, ltJudge = ltJudge, ltScore = ltScore, densest = densest, LT = LT, FLOOR_MIN = FLOOR_MIN,
	set = function(level, reserve, floor) LV = LEVELS[level or 2] or LEVELS[2]; RESERVE = reserve or LV.reserve; FLOOR = floor or FLOOR_MIN end,
	get = function() return { reserve = RESERVE, floor = FLOOR, level = LV.name } end }

-- (0.6) whether the computer company of that key ("ai:n") was taken over on the stock market (see M.tick)
function M.retiredBy(st, key)
	if os.getenv("MPFEVER_STOCKRETIRE") == "0" then return false end
	local S = type(st) == "table" and type(st.feat) == "table" and st.feat.stock or nil
	return type(S) == "table" and type(S.retired) == "table" and S.retired[tostring(key)] == true
end

function M.tick(E, st)
	local G, C = E.G, E.C
	if C.ROLE ~= "host" or G.cmode ~= "separate" then return end
	if not (G.connected and G.session and G.session.started) or G.session.resync or not G.myCo or G.coNone then return end
	-- (nothing while the session is paused: its actions would wait for their turns)
	if G.session.pauseAt ~= nil then return end
	local list = M.listOf(G.coAi)
	if #list == 0 and os.getenv("MPFEVER_AI") == "1" then list = { { n = 1, color = 7 } } end
	if #list == 0 then return end
	-- (the module's own clock, for all its companies)
	G.AIT = G.AIT or {}
	local T = G.AIT
	-- (dev: the companies act only while ai_enable.txt stands in the module's folder)
	local dev = os.getenv("MPFEVER_AIDEV")
	if dev and G.frames % 120 == 0 then
		local f = C.IO.open(dev .. E.BS .. "ai_enable.txt", "rb")
		T.enabled = f ~= nil
		if f then f:close() end
	end
	if dev and not T.enabled then return end
	if G.frames < (T.nextAt or 0) then return end
	-- (a look every half second at most; each company has its own pace, its level's)
	T.nextAt = G.frames + 30
	-- (not before the session's first minute: the joins and the first checks)
	T.firstAt = T.firstAt or (G.frames + 600)
	if G.frames < T.firstAt then return end
	-- one company per look, in turn: the next one whose own look is due
	G.AIS = G.AIS or {}
	local cur
	for _ = 1, #list do
		T.turn = (T.turn or 0) % #list + 1
		local c = list[T.turn]
		G.AIS[c.n] = G.AIS[c.n] or {}
		if G.frames >= (G.AIS[c.n].lookAt or 0) then cur = c; break end
	end
	if not cur then return end
	G.AI = G.AIS[cur.n]
	LV = LEVELS[cur.level or 2] or LEVELS[2]
	RESERVE = LV.reserve
	FLOOR = FLOOR_MIN
	G.AI.lookAt = G.frames + LV.tick
	if G.AI.levelSaid ~= LV.name then G.AI.levelSaid = LV.name; E.log("AI" .. cur.n .. " level " .. LV.name) end
	AINUM, AIKEY = cur.n, "ai:" .. cur.n
	-- (0.6) a computer company taken over on the stock market (the game option "stock", mpfever_feat_stock.lua: its key in
	-- st.feat.stock.retired, the same on every game) stays retired: it is not announced again as a new company of that key.
	-- Nothing of it while the option was never used. MPFEVER_STOCKRETIRE=0: announced again, as without the check
	if M.retiredBy(st, AIKEY) then
		if not G.AI.retiredSaid then G.AI.retiredSaid = true; L(E, "taken over on the stock market: retired, not announced again") end
		G.AI.lookAt = G.frames + 3600
		return
	end
	AICOLOR = (cur.color and cur.color >= 1 and cur.color <= #E.CO.PALETTE) and cur.color or nil
	-- (its start money, the host's choice for it; else the players')
	AIMONEY = cur.money
	local known = aiCompany(E)
	AINAME = known and known.name ~= "" and known.name or newName(E, cur.n)
	-- (what a step costs this game's interface: the slowest one of each minute is logged)
	local t0 = os.clock()
	local busyBefore = G.AI.busy
	step(E)
	-- (after a purchase, a build or a new line, the level's pause: a Hard company that acted at every look spent its 2 million in
	-- 90 s on a map of 1972, then sold everything in debt)
	if G.AI.busy and G.AI.busy ~= busyBefore then G.AI.lookAt = math.max(G.AI.lookAt or 0, G.frames + (LV.pause or 600)) end
	local dt = os.clock() - t0
	T.slowest = math.max(T.slowest or 0, dt)
	if G.frames - (T.costAt or 0) > 3600 then
		T.costAt = G.frames
		L(E, string.format("slowest step of the last minute: %.3f s (%d compan%s)", T.slowest, #list, #list > 1 and "ies" or "y"))
		T.slowest = 0
	end
	-- (a slow step waits longer before the next one)
	if dt > 0.05 then T.nextAt = G.frames + TICK * 3; G.AI.lookAt = math.max(G.AI.lookAt or 0, G.frames + TICK * 3) end
end

return M
