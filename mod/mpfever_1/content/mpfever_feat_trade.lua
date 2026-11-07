-- MPFever 0.6 game options: trade between the companies, in the "one company per player" mode (docs/FEATURES-0.6.md is the
-- contract with the options host; release/recherche-0.6/05-commerce-joueurs.md is the study, and the owner's decisions E1 to E6
-- of release/recherche-0.6/00-REPONSES.md come before it). Two options of the host, off by default:
--
--   sales      the chief of a company offers one of its lines, stations or depots to another company for a price, and that
--              company's chief accepts or refuses. A line always goes with the seller's stations it stops at (E5). The assets
--              change hands as the lots of a bankrupt company's auction do (mpfever_eco.lua: M.rt.transfer), the buyer pays the
--              seller. No tracks for sale in v1 (E4), no vehicle on its own.
--   contracts  supply contracts: company A delivers N units of a cargo a month at a station of company B, for p per unit. A month
--              not met is paid pro rata, and A pays B the contract's penalty for each unit missing (E2). Delivered = all of that
--              cargo A's vehicles unload at B's station (E3). The first month (signed during it) is paid without a penalty.
--
-- Only the chief of a company sells, buys, signs and cancels (E1). The computer companies stay out of trade in v1 (E6); since 0.7.5
-- they sell the stations they no longer use (the host's game sends their offers), and still never buy nor sign.
--
-- Events (sent by a game's GUI half with env.send; the bridge adds param.mpfCo, the sender's company, and param.mpfFrom, the
-- sender's name, "#n" after it for a player who joined, as for every "mpfever" event of the companies mode):
--   f_trade_offer      {to, kind, key, price}        a chief offers a lot of its company ("line", "station", "depot" and its key,
--                                                     as mpfever_eco.lua's E.lotsOf gives them) to company `to`
--   f_trade_answer     {id, accept}                  the buyer's chief answers: the assets change hands and the money is booked
--   f_trade_cancel     {id}                          the seller's chief takes its offer back
--   f_trade_ct_offer   {to, role, station, cargo, per, price, penalty, months}
--                                                     a chief offers a contract to company `to`; role "supply" (its company
--                                                     delivers) or "pay"; station = the key (R.sgKey) of a station of the payer;
--                                                     cargo = the cargo's resource name; per = units a month; price and penalty
--                                                     per unit; months = 0 (until cancelled), 3, 6, 12 or 24
--   f_trade_ct_answer  {id, accept}                  the other company's chief answers
--   f_trade_ct_cancel  {id}                          an offer taken back (its proposer), or an active contract cancelled (the chief
--                                                     of either company): it ends after the current month is paid
--   f_trade_pay        {month, ct = {{id, n, lost}}} the host's figures for a month that is over: n units delivered (the host's
--                                                     own measure), lost = the station is no longer the payer's on the host's game
--
-- The state (st.feat.trade, saved with the game, plain data):
--   seq            the last number given to an offer or a contract
--   offers         { {id, from, to, kind, key, label, nveh, price, mon} }   the open offers of sale
--   ct             { {id, state = "offer"|"active"|"ending", by, supplier, payer, key, label, cargo, per, price, penalty, months,
--                    mon, start, done, paid, pen, last} }                     the contracts (offered, running, ending)
--   mon, due, paidMon   the game month at the last month's turn, the month over whose deliveries the host pays, the last one paid
--   news, newsSeq  what happened (the last 30), told in every game's chat by its GUI half
--   here           { cur, last, lastMon, trk }  THIS game's measure of the deliveries (vehicles' local ids, counts): it may differ
--                  from another game's by a unit, since it follows the vehicles' movement. Only the host's figures move money. It
--                  must be left out of any comparison of the games' states.
--
-- Everything here that every game runs at the same step (M.event, M.tick, M.month) is deterministic: no clock, no random, no
-- file, no balance read (a game's own balance may lag a step behind, see co_bid in mpfever_eco.lua: a buyer short of money ends
-- in debt; the window greys nothing out on money). The world is read through the small functions of M.rt, which the integration
-- (and the offline test) may replace.

local M = {}
M.ID = "trade"
-- (the window's file: env.write("trade") writes feat_trade_trade.txt of the session folder, u.read("trade") reads it back)
M.FILE = "trade"
M.OPTIONS = {
	{ id = "sales", title = { "Ventes entre entreprises", "Sales between companies" },
		desc = { "Le chef d'une entreprise peut vendre une ligne (avec ses gares), une gare ou un dépôt à une autre entreprise, au prix convenu.",
			"A company's chief can sell a line (with its stations), a station or a depot to another company, at the agreed price." },
		modes = "separate" },
	{ id = "contracts", title = { "Contrats de livraison", "Supply contracts" },
		desc = { "Une entreprise livre chaque mois une quantité de marchandise à la gare d'une autre, payée à l'unité. Un mois non tenu est payé au prorata, avec la pénalité du contrat.",
			"A company delivers a quantity of a cargo each month at another's station, paid per unit. A month not met is paid pro rata, with the contract's penalty." },
		modes = "separate" },
}
M.EVENTS = { f_trade_offer = true, f_trade_answer = true, f_trade_cancel = true, f_trade_ct_offer = true, f_trade_ct_answer = true,
	f_trade_ct_cancel = true, f_trade_pay = true }
M.TAB = { id = "trade", title = { "Commerce", "Trade" } }

M.KINDS = { line = true, station = true, depot = true }
M.MAX_PRICE = 1e10            -- a sale's price, as the gifts and the start money (0 to 10 billion)
M.MAX_OPEN = 10               -- open offers of sale per company, and contracts (offered or running) per company
M.OFFER_MONTHS = 2            -- an offer (of sale or of contract) not answered within that many game months goes
M.CT_MONTHS = { 0, 3, 6, 12, 24 }
M.CT_MAX_PER = 100000         -- units a month
M.CT_MAX_PRICE = 1000000      -- per unit, the price and the penalty
M.NEWS_KEEP = 30
M.REFRESH = 50                -- steps between two looks at which vehicles serve a contract's station (see M.tick)

-- ---------------------------------------------------------------------------------------------------------------- helpers
-- (as mpfever_eco.lua: a player's key is its name without the "#n" of a player who joined, in lower case)
local function keyOf(origin)
	local plain = tostring(origin or ""):gsub("#.*$", "")
	return plain:lower(), plain
end

-- a host (or a dedicated server) sends its events under its plain name; a player who joined has "#n" after it
local function fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

local function findCo(reg, id)
	for _, c in ipairs(type(reg) == "table" and reg.list or {}) do if c.id == id then return c end end
	return nil
end

-- (as CO.members and CO.chief of mpfever_co.lua, without loading it: a registry of the first versions has one player, its key)
local function members(c)
	if not c then return {} end
	if type(c.members) == "table" then return c.members end
	if type(c.key) == "string" and c.key ~= "" then return { { key = c.key } } end
	return {}
end

local function chief(c)
	if not c then return nil end
	if c.chief then return c.chief end
	local m = members(c)[1]
	return m and m.key or nil
end

local function isAi(c)
	if not c then return false end
	if c.ai or tostring(c.key or ""):sub(1, 3) == "ai:" then return true end
	for _, m in ipairs(members(c)) do if tostring(m.key or ""):sub(1, 3) == "ai:" then return true end end
	return false
end

-- a company that may trade: playing (not bankrupt, merged or empty) and not a computer company (E6)
local function tradable(c) return c ~= nil and not c.gone and not isAi(c) end
M.tradable, M.chief, M.keyOf = tradable, chief, keyOf

local function int(x)
	local n = tonumber(x)
	if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
	return math.floor(n)
end

local function oneOf(x, list)
	for _, v in ipairs(list) do if v == x then return true end end
	return false
end

-- the saved state, without creating it (nothing is written while nothing happened: the options' rule)
local function peek(st)
	return type(st) == "table" and type(st.feat) == "table" and st.feat[M.ID] or nil
end

local function state(st, env)
	local s = env.state(st)
	s.seq = s.seq or 0
	s.offers = s.offers or {}
	s.ct = s.ct or {}
	s.news = s.news or {}
	s.newsSeq = s.newsSeq or 0
	return s
end

-- the game month now: the options host's (year * 12 + month, the same on every game), else the months counted by M.month
local function monthNow(env, s)
	if env.month then
		local ok, m = pcall(env.month)
		if ok and tonumber(m) then return math.floor(tonumber(m)) end
	end
	return s and s.mon or 0
end

local function news(s, t)
	s.newsSeq = (s.newsSeq or 0) + 1
	t.n = s.newsSeq
	s.news[#s.news + 1] = t
	while #s.news > M.NEWS_KEEP do table.remove(s.news, 1) end
end

-- money from or to a company, the same on every game (env.book). kind: what it is, for the game's journal when the options host
-- can tell ("acquisition", "income", "maintenance", "other"); a host that books everything the same way may ignore it
local function book(env, c, amount, kind)
	amount = math.floor(amount + 0.5)
	if amount == 0 or not (c and c.ent) then return end
	env.book(c.ent, amount, kind)
end

local function what(o) return { kind = o.kind, label = o.label, nveh = o.nveh } end

-- (a lot of a company's list, by its kind and key)
local function findLot(lots, kind, key)
	for _, l in ipairs(lots or {}) do if l.kind == kind and l.key == key then return l end end
	return nil
end

local function countOpen(s, id)
	local n = 0
	for _, o in ipairs(s and s.offers or {}) do if o.from == id then n = n + 1 end end
	return n
end

local function countCt(s, id)
	local n = 0
	for _, c in ipairs(s and s.ct or {}) do if c.supplier == id or c.payer == id then n = n + 1 end end
	return n
end

-- ---------------------------------------------------------------------------------------------------------------- the world
-- What the game knows and the state does not: read through these functions, which the integration (or the offline test) may
-- replace. Each one is read the same way on every game at the same step when the simulation half calls it (owners, names, line
-- stops and vehicles change by commands only); the measure's (watch, vehicle, load) follow the vehicles' movement and may differ
-- by a step between games: they never decide anything about money, the host's figures do.
M.rt = {}

-- (a module of the mod, loaded once per Lua state when the options host gives none; nil outside the game)
local loaded = {}
local function modFile(name)
	if loaded[name] == nil then
		loaded[name] = false
		if type(ug_require) == "function" then
			local ok, m = pcall(ug_require, name)
			if not (ok and type(m) == "table") then ok, m = pcall(ug_require, "mpfever_1::/" .. name) end
			if ok and type(m) == "table" then loaded[name] = m end
		end
	end
	return loaded[name] or nil
end

-- the references (mpfever_refs.lua): env.R in the simulation half, loaded here on the GUI's side
function M.rt.R(env) return (env and env.R) or modFile("mpfever_refs.lua") end

-- The lots a company could sell: { {kind, key, label, vehicles, reserve} } sorted by kind then key, the same keys on every game.
-- env.lots(id) when the options host gives it, else mpfever_eco.lua's E.lotsOf (the lots of a bankrupt company's auction).
function M.rt.lots(env, st, c)
	if not (c and c.ent) then return {} end
	if env.lots then
		local lots = env.lots(c.id)
		if type(lots) == "table" then return lots end
	end
	local E = modFile("mpfever_eco.lua")
	if E and E.lotsOf then
		local ok, lots = pcall(E.lotsOf, { R = M.rt.R(env), log = env.log }, c)
		if ok and type(lots) == "table" then return lots end
	end
	return {}
end

-- The lot's assets change hands, from company `from` to company `to` (records of the registry), as an auction's lot sold:
-- lot = {kind, key, label, withStations, frozen}. Returns how many entities moved, or nil and why when no transfer is available.
-- env.transferLot(fromId, toId, lot) (the options host's: mpfever_eco.lua's E.transferLot through the bridge, with the registry,
-- so the stations' and depots' own settings go as an auction's do), else mpfever_eco.lua's E.transferLot loaded here.
function M.rt.transfer(env, st, from, to, lot)
	if env.transferLot then
		local n, why = env.transferLot(from.id, to.id, lot)
		if n ~= nil or why ~= nil then return n, why end
	end
	local E = modFile("mpfever_eco.lua")
	if E and E.transferLot and M.rt.R(env) then
		return E.transferLot({ R = M.rt.R(env), log = env.log, gameTime = env.gameTime, STEP = env.STEP }, from, to, lot,
			{ withStations = lot.withStations, frozen = lot.frozen, reg = env.co })
	end
	return nil, "no transfer of assets in this version"
end

local function nameOf(e)
	local ok, n = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.NAME).name end)
	return (ok and type(n) == "string") and n or tostring(e)
end

-- The station group of company c whose key (R.sgKey) is `key`, and its name; nil when c has no such station. The last one found
-- is kept, checked again at each call (one key read), the stations looked through only when it no longer matches.
M.sgSeen = {}
function M.rt.station(env, st, c, key)
	if not (c and c.ent and type(key) == "string") then return nil end
	local R = M.rt.R(env)
	if not R then return nil end
	local sg = M.sgSeen[key]
	if sg and not (R.ownerOf(sg) == c.ent and R.sgKey(sg) == key) then sg = nil end
	if not sg then
		for _, e in ipairs(R.entitiesWith("STATION_GROUP")) do
			if R.ownerOf(e) == c.ent and R.sgKey(e) == key then sg = e break end
		end
		M.sgSeen[key] = sg
	end
	if not sg then return nil end
	return sg, nameOf(sg)
end

-- The stations of the companies (GUI only, for the window's contract form): { [company id] = { {key, label} } } for the
-- companies of `ids` ({ [player entity] = company id }), sorted by name, at most 60 per company
function M.rt.stations(env, st, ids)
	local out = {}
	local R = M.rt.R(env)
	if not R then return out end
	for _, e in ipairs(R.entitiesWith("STATION_GROUP")) do
		local id = ids[R.ownerOf(e) or -1]
		if id then
			out[id] = out[id] or {}
			local list = out[id]
			if #list < 60 then list[#list + 1] = { key = R.sgKey(e), label = nameOf(e) } end
		end
	end
	for _, list in pairs(out) do table.sort(list, function(a, b) return a.label < b.label or (a.label == b.label and a.key < b.key) end) end
	return out
end

-- a cargo's id by its resource name, nil when the game has none; whether it is the passengers
M.cargoIds = {}
function M.rt.cargoId(name)
	if type(name) ~= "string" or name == "" then return nil end
	local id = M.cargoIds[name]
	if id == nil then
		id = false
		local ok, x = pcall(function() return api.res.cargoTypeRep.find(name) end)
		if ok and type(x) == "number" and x >= 0 then id = x end
		M.cargoIds[name] = id
	end
	return id or nil
end

function M.rt.isPassengers(id)
	local ok, p = pcall(function() return api.res.cargoTypeRep.getPassengerCargoTypeId() end)
	return ok and p == id
end

-- the cargo's name as the players see it (GUI)
function M.rt.cargoLabel(name)
	local id = M.rt.cargoId(name)
	local label = nil
	if id then pcall(function() label = api.res.cargoTypeRep.get(id).name end) end
	if type(label) == "string" and label ~= "" then
		if type(_) == "function" then
			local ok, t = pcall(_, label)
			if ok and type(t) == "string" then label = t end
		end
		return label
	end
	return tostring(name)
end

-- every cargo but the passengers (GUI): { {name, label} } sorted by label
function M.rt.cargos()
	local out = {}
	pcall(function()
		local pass = api.res.cargoTypeRep.getPassengerCargoTypeId()
		for id in pairs(api.res.cargoTypeRep.getAll()) do
			if id ~= pass then
				local name = api.res.cargoTypeRep.getName(id)
				if type(name) == "string" then out[#out + 1] = { name = name, label = M.rt.cargoLabel(name) } end
			end
		end
	end)
	table.sort(out, function(a, b) return a.label < b.label or (a.label == b.label and a.name < b.name) end)
	return out
end

-- a company's name as the players see it (the game's, else the registry's)
function M.rt.coName(st, c)
	if not c then return "?" end
	local n = nil
	if c.ent then pcall(function() n = api.engine.getComponent(c.ent, api.type.ComponentType.NAME).name end) end
	if type(n) == "string" and n ~= "" then return n end
	if type(c.name) == "string" and c.name ~= "" then return c.name end
	return "#" .. tostring(c.id)
end

-- The vehicles that serve a contract's station: { {v = vehicle, at = { [stop index, from 0] = true }} }, each vehicle of the
-- supplier's lines that stop at the payer's station (TransportVehicle.stopIndex counts from 0: the game's vehicle_eow script reads
-- line.stops[stopIndex + 1])
function M.rt.watch(env, st, c, reg)
	local sup, pay = findCo(reg, c.supplier), findCo(reg, c.payer)
	if not (sup and sup.ent and pay and pay.ent) then return {} end
	local sg = M.rt.station(env, st, pay, c.key)
	if not sg then return {} end
	local out = {}
	local okL, lines = pcall(api.engine.system.lineSystem.getLinesForPlayer, sup.ent)
	for _, l in ipairs(okL and lines or {}) do
		local at, any = {}, false
		pcall(function()
			local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
			for i = 1, #lc.stops do
				if lc.stops[i].stationGroup == sg then at[i - 1] = true; any = true end
			end
		end)
		if any then
			local okV, vehicles = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, l)
			for _, v in ipairs(okV and vehicles or {}) do out[#out + 1] = { v = v, at = at } end
		end
	end
	return out
end

-- a vehicle's state: "en_route", "at_terminal" or "other", and the index of its stop (the next one en route, the present one at
-- a terminal)
function M.rt.vehicle(v)
	local stt, idx = nil, nil
	pcall(function()
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if tv then stt, idx = tv.state, tv.stopIndex end
	end)
	local S = nil
	pcall(function() S = api.type.enum.TransportVehicleState end)
	if S and stt == S.EN_ROUTE then return "en_route", idx end
	if S and stt == S.AT_TERMINAL then return "at_terminal", idx end
	return "other", idx
end

-- how many units of a cargo a vehicle carries
function M.rt.load(v, cargoId)
	local ok, n = pcall(api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType, v, cargoId)
	return (ok and type(n) == "number") and n or 0
end

-- ---------------------------------------------------------------------------------------------------------------- the events
local SALES_EVENTS = { f_trade_offer = true, f_trade_answer = true, f_trade_cancel = true }

local function findById(list, id)
	for i, x in ipairs(list or {}) do if x.id == id then return x, i end end
	return nil
end

local function endContract(s, i, why)
	local c = table.remove(s.ct, i)
	news(s, { kind = "ct_end", id = c.id, supplier = c.supplier, payer = c.payer, cargo = c.cargo, why = why })
	return c
end

local function sale(st, s, reg, env, name, param, mine, key, refuse)
	if name == "f_trade_offer" then
		-- (0.7.5) a computer company sells too (stations it no longer uses, see mpfever_ai.lua): the host's game sends its offers, it
		-- has no chief; it never buys (an offer to it is refused, as before)
		local aiSeller = mine ~= nil and not mine.gone and isAi(mine)
		if not aiSeller then
			if not tradable(mine) then return refuse("company " .. tostring(param.mpfCo) .. " may not trade") end
			if chief(mine) ~= key then return refuse("not the chief of company " .. mine.id) end
		end
		local to = findCo(reg, int(param.to))
		if not tradable(to) or to.id == mine.id then return refuse("buyer " .. tostring(param.to)) end
		local price = int(param.price)
		if not price or price ~= tonumber(param.price) or price < 0 or price > M.MAX_PRICE then return refuse("price " .. tostring(param.price)) end
		local kind, lkey = tostring(param.kind), param.key
		if not M.KINDS[kind] or type(lkey) ~= "string" or lkey == "" then return refuse("lot " .. kind) end
		local lot = findLot(M.rt.lots(env, st, mine), kind, lkey)
		if not lot then return refuse("company " .. mine.id .. " has no such " .. kind) end
		s = s or peek(st)
		-- (the same lot offered again: the new offer replaces the old one)
		local again = nil
		for i, o in ipairs(s and s.offers or {}) do if o.from == mine.id and o.kind == kind and o.key == lkey then again = i end end
		if not again and countOpen(s, mine.id) >= M.MAX_OPEN then return refuse("company " .. mine.id .. " has " .. M.MAX_OPEN .. " offers open") end
		s = state(st, env)
		if again then table.remove(s.offers, again) end
		s.seq = s.seq + 1
		local o = { id = s.seq, from = mine.id, to = to.id, kind = kind, key = lkey, label = tostring(lot.label or ""),
			nveh = int(lot.vehicles) or 0, price = price, mon = monthNow(env, s) }
		s.offers[#s.offers + 1] = o
		news(s, { kind = "offer", from = o.from, to = o.to, what = what(o), price = price })
		env.log("trade: company " .. mine.id .. " offers " .. kind .. " '" .. o.label .. "' to company " .. to.id .. " for " .. price .. " (offer " .. o.id .. ")")
		return true
	end
	-- (an answer or a cancel: an offer that exists)
	if not s then return refuse("no offer") end
	local o, i = findById(s.offers, int(param.id))
	if not o then return refuse("no offer " .. tostring(param.id)) end
	if name == "f_trade_cancel" then
		if not (mine and mine.id == o.from and (chief(mine) == key or isAi(mine))) then return refuse("not the chief of the seller") end
		table.remove(s.offers, i)
		news(s, { kind = "cancelled", from = o.from, to = o.to, what = what(o) })
		env.log("trade: offer " .. o.id .. " taken back")
		return true
	end
	-- f_trade_answer: the buyer's chief
	if not (mine and mine.id == o.to and tradable(mine) and chief(mine) == key) then return refuse("not the chief of the buyer") end
	table.remove(s.offers, i)
	if not param.accept then
		news(s, { kind = "refused", from = o.from, to = o.to, what = what(o) })
		env.log("trade: offer " .. o.id .. " refused by company " .. mine.id)
		return true
	end
	local seller = findCo(reg, o.from)
	-- (0.7.5: a computer company's offer, see f_trade_offer)
	if not (tradable(seller) or (seller and not seller.gone and isAi(seller))) then
		news(s, { kind = "failed", from = o.from, to = o.to, what = what(o) })
		return refuse("the seller is gone")
	end
	-- (found again by its key in the seller's assets: a line must still have the vehicles it had when it was offered)
	local lot = findLot(M.rt.lots(env, st, seller), o.kind, o.key)
	if not lot or (o.kind == "line" and (int(lot.vehicles) or 0) ~= o.nveh) then
		news(s, { kind = "changed", from = o.from, to = o.to, what = what(o) })
		return refuse("the offer changed")
	end
	-- (a line with its stations (E5); a station's or a depot's own tracks with it: the buyer pays no toll inside what it bought)
	local n, why = M.rt.transfer(env, st, seller, mine, { kind = o.kind, key = o.key, label = o.label, withStations = o.kind == "line", frozen = true })
	if n == nil then
		news(s, { kind = "failed", from = o.from, to = o.to, what = what(o) })
		return refuse("transfer: " .. tostring(why))
	end
	-- (booked whatever the count: the lot was found by the same keys on every game, the money must be the same everywhere)
	book(env, mine, -o.price, "acquisition")
	book(env, seller, o.price, "acquisition")
	news(s, { kind = "sold", from = o.from, to = o.to, what = what(o), price = o.price })
	env.log("trade: offer " .. o.id .. ": " .. o.kind .. " '" .. o.label .. "' of company " .. seller.id .. " sold to company " .. mine.id
		.. " for " .. o.price .. " (" .. tostring(n) .. " entities change hands)")
	return true
end

local function contract(st, s, reg, env, name, param, mine, key, refuse)
	if name == "f_trade_ct_offer" then
		if not tradable(mine) then return refuse("company " .. tostring(param.mpfCo) .. " may not trade") end
		if chief(mine) ~= key then return refuse("not the chief of company " .. mine.id) end
		local other = findCo(reg, int(param.to))
		if not tradable(other) or other.id == mine.id then return refuse("company " .. tostring(param.to)) end
		local supplier, payer
		if param.role == "supply" then supplier, payer = mine, other
		elseif param.role == "pay" then supplier, payer = other, mine
		else return refuse("role " .. tostring(param.role)) end
		local per, price, penalty, months = int(param.per), int(param.price), int(param.penalty or 0), int(param.months)
		if not per or per < 1 or per > M.CT_MAX_PER then return refuse("units a month " .. tostring(param.per)) end
		if not price or price < 1 or price > M.CT_MAX_PRICE then return refuse("price " .. tostring(param.price)) end
		if not penalty or penalty < 0 or penalty > M.CT_MAX_PRICE then return refuse("penalty " .. tostring(param.penalty)) end
		if not oneOf(months, M.CT_MONTHS) then return refuse("months " .. tostring(param.months)) end
		local cid = M.rt.cargoId(param.cargo)
		if not cid or M.rt.isPassengers(cid) then return refuse("cargo " .. tostring(param.cargo)) end
		local sg, label = M.rt.station(env, st, payer, param.station)
		if not sg then return refuse("company " .. payer.id .. " has no such station") end
		s = s or peek(st)
		if countCt(s, mine.id) >= M.MAX_OPEN or countCt(s, other.id) >= M.MAX_OPEN then return refuse("too many contracts") end
		s = state(st, env)
		s.seq = s.seq + 1
		local c = { id = s.seq, state = "offer", by = mine.id, supplier = supplier.id, payer = payer.id, key = param.station,
			label = tostring(label or ""), cargo = param.cargo, per = per, price = price, penalty = penalty, months = months,
			mon = monthNow(env, s), done = 0, paid = 0, pen = 0 }
		s.ct[#s.ct + 1] = c
		news(s, { kind = "ct_offer", id = c.id, by = c.by, supplier = c.supplier, payer = c.payer, cargo = c.cargo, per = per,
			price = price, penalty = penalty, months = months, label = c.label })
		env.log("trade: company " .. mine.id .. " offers contract " .. c.id .. ": company " .. supplier.id .. " delivers " .. per .. " "
			.. tostring(param.cargo) .. " a month to company " .. payer.id .. " at " .. tostring(param.station) .. " for " .. price
			.. " per unit, penalty " .. penalty .. ", " .. months .. " month(s)")
		return true
	end
	if name == "f_trade_pay" then
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		if not s then return refuse("no contract") end
		local m = int(param.month)
		if not m or m <= (s.paidMon or -math.huge) then return refuse("month " .. tostring(param.month) .. " already paid") end
		if not s.due or m > s.due then return refuse("month " .. tostring(param.month) .. " not over") end
		s.paidMon = m
		local fig = {}
		for _, x in ipairs(type(param.ct) == "table" and param.ct or {}) do
			if type(x) == "table" and int(x.id) then fig[int(x.id)] = x end
		end
		local i = 1
		while i <= #s.ct do
			local c = s.ct[i]
			local f = fig[c.id]
			local ended = nil
			if c.state ~= "offer" and f and (c.start or m) <= m then
				local sup, pay = findCo(reg, c.supplier), findCo(reg, c.payer)
				if not (tradable(sup) and tradable(pay)) then
					ended = "gone"
				else
					local n = math.max(0, math.min(int(f.n) or 0, c.per))
					-- (the month it was signed in is paid without a penalty, and the month its station was lost)
					local first = c.start == m
					local short = (first or f.lost) and 0 or (c.per - n)
					local amount, pen = n * c.price, short * c.penalty
					book(env, pay, -amount, "maintenance")
					book(env, sup, amount, "income")
					if pen > 0 then
						book(env, sup, -pen, "other")
						book(env, pay, pen, "other")
					end
					c.paid = (c.paid or 0) + amount
					c.pen = (c.pen or 0) + pen
					c.last = n
					if not first then c.done = (c.done or 0) + 1 end
					-- (the units delivered as "units": a news's n is its number, see news)
					news(s, { kind = "ct_paid", id = c.id, supplier = c.supplier, payer = c.payer, cargo = c.cargo, units = n, per = c.per,
						amount = amount, pen = pen })
					env.log("trade: contract " .. c.id .. ", month " .. m .. ": " .. n .. "/" .. c.per .. " delivered, " .. amount .. " paid, penalty " .. pen)
					if f.lost then ended = "lost"
					elseif c.state == "ending" then ended = "cancelled"
					elseif c.months > 0 and c.done >= c.months then ended = "done" end
				end
			end
			if ended then endContract(s, i, ended) else i = i + 1 end
		end
		return true
	end
	if not s then return refuse("no contract") end
	local c, i = findById(s.ct, int(param.id))
	if not c then return refuse("no contract " .. tostring(param.id)) end
	if not (mine and chief(mine) == key and (mine.id == c.supplier or mine.id == c.payer)) then return refuse("not the chief of a company of the contract") end
	if name == "f_trade_ct_answer" then
		if c.state ~= "offer" or mine.id == c.by then return refuse("not an offer to company " .. mine.id) end
		if not param.accept then
			table.remove(s.ct, i)
			news(s, { kind = "ct_refused", id = c.id, by = mine.id, from = c.by })
			return true
		end
		local sup, pay = findCo(reg, c.supplier), findCo(reg, c.payer)
		if not (tradable(sup) and tradable(pay) and M.rt.station(env, st, pay, c.key)) then
			table.remove(s.ct, i)
			news(s, { kind = "ct_refused", id = c.id, by = mine.id, from = c.by, changed = true })
			return refuse("the contract's station or companies changed")
		end
		c.state = "active"
		c.start = monthNow(env, s)
		news(s, { kind = "ct_start", id = c.id, supplier = c.supplier, payer = c.payer, cargo = c.cargo, per = c.per, price = c.price,
			penalty = c.penalty, months = c.months, label = c.label })
		env.log("trade: contract " .. c.id .. " signed, from month " .. c.start)
		return true
	end
	-- f_trade_ct_cancel: an offer by its proposer; a running contract by either company, at the end of the month
	if c.state == "offer" then
		if mine.id ~= c.by then return refuse("not the proposer") end
		table.remove(s.ct, i)
		news(s, { kind = "ct_cancelled", id = c.id, by = mine.id })
	elseif c.state == "active" then
		c.state = "ending"
		news(s, { kind = "ct_ending", id = c.id, by = mine.id, supplier = c.supplier, payer = c.payer })
	else
		return refuse("already ending")
	end
	return true
end

-- An event of the module, on every game at the same step. Returns true when it was taken.
function M.event(st, name, param, env)
	if not M.EVENTS[name] then return false end
	param = type(param) == "table" and param or {}
	local function refuse(why)
		env.log("trade: " .. name .. " of '" .. tostring(param.mpfFrom) .. "' refused: " .. why)
		return false
	end
	if env.mode ~= "separate" or type(env.co) ~= "table" then return refuse("not in the one company per player mode") end
	local isSale = SALES_EVENTS[name] == true
	if isSale and not env.on("sales") then return refuse("the sales are off") end
	if not isSale and not env.on("contracts") then return refuse("the supply contracts are off") end
	local reg = env.co
	local key = keyOf(param.mpfFrom)
	local mine = findCo(reg, int(param.mpfCo))
	local s = peek(st)
	if isSale then return sale(st, s, reg, env, name, param, mine, key, refuse) end
	return contract(st, s, reg, env, name, param, mine, key, refuse)
end

-- ---------------------------------------------------------------------------------------------------------------- the months
-- At the start of every game month, on every game: the month over is the one the host's figures pay (f_trade_pay); this game's
-- measure keeps its count; the offers not answered for M.OFFER_MONTHS go; what involves a company gone (bankrupt, merged,
-- empty) goes, a running contract ends without a payment for the month.
function M.month(st, env)
	if env.mode ~= "separate" or not (env.on("sales") or env.on("contracts")) then return end
	local s = peek(st)
	if not s then return end
	local reg = env.co
	local m = env.month and monthNow(env, nil) or ((s.mon or 0) + 1)
	s.mon = m
	s.due = m - 1
	local h = s.here
	if h then
		h.last = h.cur or {}
		h.cur = {}
		h.lastMon = m - 1
	end
	local keep = {}
	for _, o in ipairs(s.offers or {}) do
		if not (tradable(findCo(reg, o.from)) and tradable(findCo(reg, o.to))) then
			env.log("trade: offer " .. o.id .. " dropped: a company is gone")
		elseif m - (o.mon or m) >= M.OFFER_MONTHS then
			news(s, { kind = "expired", from = o.from, to = o.to, what = what(o) })
		else
			keep[#keep + 1] = o
		end
	end
	s.offers = keep
	local i = 1
	while i <= #s.ct do
		local c = s.ct[i]
		local gone = not (tradable(findCo(reg, c.supplier)) and tradable(findCo(reg, c.payer)))
		if c.state == "offer" and (gone or m - (c.mon or m) >= M.OFFER_MONTHS) then
			table.remove(s.ct, i)
			news(s, { kind = "ct_expired", id = c.id, by = c.by })
		elseif c.state ~= "offer" and gone then
			endContract(s, i, "gone")
		else
			i = i + 1
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- the measure
-- Every step, on every game, while some contract runs: what the supplier's vehicles unload at the payer's station. A vehicle on
-- its way to that stop (one of the stops of its line at the station) is followed: its load of the contract's cargo before the
-- stop (pre), the lowest load while it stands there (low); when it leaves, pre - low is counted for the contract. A stop it went
-- through without standing there counts nothing. Known error (the study's 4.3): a vehicle that loads the same cargo there before
-- it has unloaded all of it counts what it kept. The count is this game's (st.feat.trade.here); the host's is paid.
M.watching = {}
-- (this Lua state's log of the measure, for the in-game checks: how many vehicles each contract follows when that changes, and the
-- first unloads counted; a count, not the clock)
M.watchSeen, M.unloadLogs = {}, 0
-- Whether this vehicle's look changed the measure (so that the state is saved, and the interface half sees it)
local function measure(h, c, x, cid, env)
	local changed = false
	local k = tostring(c.id) .. ":" .. tostring(x.v)
	local stt, idx = M.rt.vehicle(x.v)
	local t = h.trk[k]
	local atStop = t ~= nil and stt == "at_terminal" and idx == t.i
	if t and not atStop and not (stt == "en_route" and idx == t.i and t.low == nil) then
		-- (it left the stop, or went past it: what it unloaded there counts)
		if t.low ~= nil then
			local ck = tostring(c.id)
			local n = math.max(0, (t.pre or 0) - t.low)
			h.cur[ck] = (h.cur[ck] or 0) + n
			if M.unloadLogs < 30 and env and env.log then
				M.unloadLogs = M.unloadLogs + 1
				env.log("feat trade: contract " .. c.id .. ": a vehicle of company " .. c.supplier .. " left the station having unloaded " .. n
					.. " " .. tostring(c.cargo) .. " (load " .. tostring(t.pre) .. " -> lowest " .. tostring(t.low) .. "), this game's count this month "
					.. h.cur[ck])
			end
		end
		h.trk[k] = nil
		t = nil
		changed = true
	end
	if atStop then
		local n = M.rt.load(x.v, cid)
		if t.low == nil or n < t.low then t.low = n; changed = true end
	elseif stt == "en_route" and type(idx) == "number" and x.at[idx] then
		if not t then
			t = { i = idx }
			h.trk[k] = t
			changed = true
		end
		local pre = M.rt.load(x.v, cid)
		if t.pre ~= pre then t.pre = pre; changed = true end
	end
	return changed
end

-- Every step: the measure. Returns true when it changed this game's count or the vehicles it follows (the options host saves
-- the state then: the interface half reads the count for the window and, on the host's game, for its figures)
function M.tick(st, env)
	if env.mode ~= "separate" or not env.on("contracts") then return end
	local s = peek(st)
	if not (s and s.ct and #s.ct > 0) then return end
	local running = {}
	for _, c in ipairs(s.ct) do if c.state == "active" or c.state == "ending" then running[#running + 1] = c end end
	if #running == 0 then
		if s.here and s.here.trk and next(s.here.trk) ~= nil then s.here.trk = {}; return true end
		return
	end
	local changed = false
	local h = s.here
	if not h then
		h = { cur = {}, last = {}, trk = {} }
		s.here = h
		changed = true
	end
	h.cur, h.trk = h.cur or {}, h.trk or {}
	-- (which vehicles serve each station: looked at again every M.REFRESH steps, at once for a contract just signed)
	local refresh = env.every and env.every(M.REFRESH)
	local watched = refresh and {} or nil
	if refresh then M.watching = {} end
	for _, c in ipairs(running) do
		local w = M.watching[c.id]
		if not w then
			w = M.rt.watch(env, st, c, env.co) or {}
			M.watching[c.id] = w
			if M.watchSeen[c.id] ~= #w then
				M.watchSeen[c.id] = #w
				env.log("feat trade: contract " .. c.id .. ": " .. #w .. " vehicle(s) of company " .. c.supplier .. "'s lines stop at company "
					.. c.payer .. "'s station " .. tostring(c.key) .. " (followed for " .. tostring(c.cargo) .. ")")
			end
		end
		local cid = M.rt.cargoId(c.cargo)
		if cid then
			for _, x in ipairs(w) do
				if watched then watched[tostring(c.id) .. ":" .. tostring(x.v)] = true end
				if measure(h, c, x, cid, env) then changed = true end
			end
		end
	end
	-- (a vehicle no longer on a line that serves the station, a contract over: forgotten)
	if watched then
		for k in pairs(h.trk) do if not watched[k] then h.trk[k] = nil; changed = true end end
	end
	return changed
end

-- ---------------------------------------------------------------------------------------------------------------- texts
-- The texts are { French, English } pairs, as the options' titles: the options host's T picks the player's language (they are
-- not T("...", "...") calls of the code, which tests/test_lang.py would look up in lang.json: their translations come with the
-- one translation pass of the 0.6 features).
M.TX = {
	offer = { "%s propose %s à %s pour %s.", "%s offers %s to %s for %s." },
	refused = { "%s refuse l'offre de %s : %s.", "%s refuses the offer of %s: %s." },
	sold = { "Vendu : %s, de %s à %s pour %s.", "Sold: %s, from %s to %s for %s." },
	changed = { "Offre de %s retirée : %s a changé depuis.", "Offer of %s withdrawn: %s changed since." },
	failed = { "La vente de %s n'a pas pu se faire.", "The sale of %s could not take place." },
	cancelled = { "%s retire son offre : %s.", "%s withdraws its offer: %s." },
	expired = { "L'offre de %s a expiré : %s.", "The offer of %s expired: %s." },
	lot_line = { "la ligne « %s » (%s véhicule(s)) avec ses gares", "line « %s » (%s vehicle(s)) with its stations" },
	lot_station = { "la gare « %s »", "station « %s »" },
	lot_depot = { "le dépôt « %s »", "depot « %s »" },
	months_open = { "jusqu'à résiliation", "until cancelled" },
	months = { "%s mois", "%s months" },
	ct_offer = { "%s propose un contrat : %s livre %s %s par mois à %s, gare « %s », %s par unité, pénalité %s par unité manquante, %s.",
		"%s offers a contract: %s delivers %s %s a month to %s, station « %s », %s per unit, penalty %s per missing unit, %s." },
	ct_refused = { "%s refuse le contrat proposé par %s.", "%s refuses the contract offered by %s." },
	ct_cancelled = { "%s retire son offre de contrat.", "%s withdraws its contract offer." },
	ct_expired = { "L'offre de contrat de %s a expiré.", "The contract offer of %s expired." },
	ct_start = { "Contrat signé : %s livre %s %s par mois à %s, gare « %s » (%s par unité).",
		"Contract signed: %s delivers %s %s a month to %s, station « %s » (%s per unit)." },
	ct_paid = { "Contrat de %s pour %s : %s/%s %s livrés, %s payés.", "Contract of %s for %s: %s/%s %s delivered, %s paid." },
	ct_penalty = { " Pénalité : %s.", " Penalty: %s." },
	ct_ending = { "%s résilie le contrat entre %s et %s : il prend fin avec ce mois.",
		"%s cancels the contract between %s and %s: it ends with this month." },
	ct_end = { "Fin du contrat entre %s et %s (%s).", "The contract between %s and %s is over (%s)." },
	why_done = { "terminé", "completed" },
	why_cancelled = { "résilié", "cancelled" },
	why_gone = { "une entreprise a disparu", "a company is gone" },
	why_lost = { "la gare n'est plus à l'entreprise qui paie", "the station no longer belongs to the paying company" },
	-- (the window)
	only_separate = { "Le commerce se fait entre entreprises, en mode « une entreprise par joueur ».",
		"Trade takes place between companies, in the « one company per player » mode." },
	no_company = { "Votre entreprise n'est pas encore prête.", "Your company is not ready yet." },
	only_chief = { "Seul le chef de l'entreprise peut vendre, acheter ou signer un contrat.",
		"Only the company's chief can sell, buy or sign a contract." },
	no_other = { "Aucune autre entreprise avec qui commercer (les entreprises de l'ordinateur n'en font pas partie).",
		"No other company to trade with (the computer companies take no part)." },
	sales = { "Ventes entre entreprises", "Sales between companies" },
	got_offer = { "%s vous propose %s pour %s.", "%s offers you %s for %s." },
	my_offer = { "Vous proposez %s à %s pour %s.", "You offer %s to %s for %s." },
	accept = { "Accepter", "Accept" },
	refuse = { "Refuser", "Refuse" },
	cancel = { "Annuler", "Cancel" },
	sell = { "Vendre…", "Sell…" },
	sell_pick = { "Vendre : choisissez un bien de votre entreprise.", "Sell: pick an asset of your company." },
	sell_none = { "Votre entreprise n'a rien à vendre.", "Your company has nothing to sell." },
	sell_to = { "Vendre %s à %s", "Sell %s to %s" },
	price = { "Prix : %s (valeur indicative %s)", "Price: %s (indicative value %s)" },
	propose = { "Proposer", "Offer" },
	contracts = { "Contrats de livraison", "Supply contracts" },
	ct_line = { "%s livre %s %s par mois à %s, gare « %s », %s par unité, pénalité %s : %s livrés ce mois-ci, %s le mois dernier, %s.",
		"%s delivers %s %s a month to %s, station « %s », %s per unit, penalty %s: %s delivered this month, %s last month, %s." },
	ct_left = { "encore %s mois", "%s more months" },
	ct_ends = { "prend fin avec ce mois", "ends with this month" },
	ct_end_btn = { "Résilier", "Cancel the contract" },
	ct_got = { "Offre de %s : %s livre %s %s par mois à %s, gare « %s », %s par unité, pénalité %s, %s.",
		"Offer of %s: %s delivers %s %s a month to %s, station « %s », %s per unit, penalty %s, %s." },
	ct_mine = { "Votre offre : %s livre %s %s par mois à %s, gare « %s », %s par unité, pénalité %s, %s.",
		"Your offer: %s delivers %s %s a month to %s, station « %s », %s per unit, penalty %s, %s." },
	ct_new = { "Nouveau contrat :", "New contract:" },
	ct_supply = { "Je livre", "I deliver" },
	ct_pay = { "Je paie", "I pay" },
	ct_with = { "Avec %s", "With %s" },
	ct_station = { "Gare de %s : %s", "Station of %s: %s" },
	ct_nostation = { "%s n'a aucune gare.", "%s has no station." },
	ct_cargo = { "Marchandise : %s", "Cargo: %s" },
	ct_per = { "%s par mois", "%s per month" },
	ct_price = { "%s par unité", "%s per unit" },
	ct_pen = { "Pénalité : %s par unité manquante", "Penalty: %s per missing unit" },
	ct_months = { "Durée : %s", "Length: %s" },
	ct_propose = { "Proposer le contrat", "Offer the contract" },
	ct_how = { "Livré = tout ce que les véhicules du livreur déchargent de cette marchandise à cette gare. Un mois non tenu est payé au prorata, et le livreur paie la pénalité pour chaque unité manquante (pas le mois de la signature).",
		"Delivered = all of that cargo the deliverer's vehicles unload at that station. A month not met is paid pro rata, and the deliverer pays the penalty for each missing unit (not in the month of the signature)." },
	news = { "Dernières nouvelles", "Latest news" },
}

-- the text of a { French, English } pair in the language of T(fr, en), each %s taking the next value (put in with gsub: a value
-- may contain % itself, as C.Tf)
function M.tr(T, pair, ...)
	local values, i = { ... }, 0
	local s = T(pair[1], pair[2])
	return (s:gsub("%%s", function() i = i + 1; return tostring(values[i] == nil and "" or values[i]) end))
end

-- the T(fr, en) of the GUI half: env.T when the options host gives it, else mpfever_common.lua's, else English
function M.T(env)
	if env and type(env.T) == "function" then return env.T end
	local C = modFile("mpfever_common.lua")
	if C and type(C.T) == "function" then return C.T end
	return function(fr, en) return en end
end

-- "$1 234 567", as the bridge's G.coMoney
function M.money(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local neg = s:sub(1, 1) == "-"
	if neg then s = s:sub(2) end
	local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return (neg and "-$" or "$") .. out
end

function M.lotText(T, w)
	if not w then return "?" end
	if w.kind == "line" then return M.tr(T, M.TX.lot_line, w.label, w.nveh or 0) end
	if w.kind == "station" then return M.tr(T, M.TX.lot_station, w.label) end
	return M.tr(T, M.TX.lot_depot, w.label)
end

function M.monthsText(T, n)
	if (tonumber(n) or 0) <= 0 then return T(M.TX.months_open[1], M.TX.months_open[2]) end
	return M.tr(T, M.TX.months, n)
end

-- a news of the state as the players read it; name(id) = a company's name, cargo(name) = a cargo's
function M.newsText(T, n, name, cargo)
	local k, X = n.kind, M.TX
	local tr = function(pair, ...) return M.tr(T, pair, ...) end
	if k == "offer" then return tr(X.offer, name(n.from), M.lotText(T, n.what), name(n.to), M.money(n.price)) end
	if k == "refused" then return tr(X.refused, name(n.to), name(n.from), M.lotText(T, n.what)) end
	if k == "sold" then return tr(X.sold, M.lotText(T, n.what), name(n.from), name(n.to), M.money(n.price)) end
	if k == "changed" then return tr(X.changed, name(n.from), M.lotText(T, n.what)) end
	if k == "failed" then return tr(X.failed, M.lotText(T, n.what)) end
	if k == "cancelled" then return tr(X.cancelled, name(n.from), M.lotText(T, n.what)) end
	if k == "expired" then return tr(X.expired, name(n.from), M.lotText(T, n.what)) end
	if k == "ct_offer" then
		return tr(X.ct_offer, name(n.by), name(n.supplier), n.per, cargo(n.cargo), name(n.payer), n.label, M.money(n.price),
			M.money(n.penalty), M.monthsText(T, n.months))
	end
	if k == "ct_refused" then return tr(X.ct_refused, name(n.by), name(n.from)) end
	if k == "ct_cancelled" then return tr(X.ct_cancelled, name(n.by)) end
	if k == "ct_expired" then return tr(X.ct_expired, name(n.by)) end
	if k == "ct_start" then return tr(X.ct_start, name(n.supplier), n.per, cargo(n.cargo), name(n.payer), n.label, M.money(n.price)) end
	if k == "ct_paid" then
		local t = tr(X.ct_paid, name(n.supplier), name(n.payer), n.units or 0, n.per, cargo(n.cargo), M.money(n.amount))
		if (n.pen or 0) > 0 then t = t .. tr(X.ct_penalty, M.money(n.pen)) end
		return t
	end
	if k == "ct_ending" then return tr(X.ct_ending, name(n.by), name(n.supplier), name(n.payer)) end
	if k == "ct_end" then
		local why = X["why_" .. tostring(n.why)] or X.why_done
		return tr(X.ct_end, name(n.supplier), name(n.payer), T(why[1], why[2]))
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------------------------- GUI half
-- (this GUI state's own memory: never saved, never shared)
M.g = { seen = nil, payMon = nil, payAt = nil, heavyAt = nil, heavy = nil, cargos = nil }

-- (a text field of the window's file and of a request: no tab, line end, ';', '=' or '%' left in it)
function M.enc(s)
	return (tostring(s == nil and "" or s):gsub("[%%\t\r\n;=]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

function M.dec(s)
	return (tostring(s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- a request's payload: "k=v;k=v", the values encoded (M.enc); keys sorted
function M.encode(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local v = t[k]
		if v == true then v = "1" elseif v == false then v = "0" end
		out[#out + 1] = M.enc(k) .. "=" .. M.enc(v)
	end
	return table.concat(out, ";")
end

function M.decode(s)
	local t = {}
	for part in tostring(s or ""):gmatch("[^;]+") do
		local k, v = part:match("^([^=]*)=(.*)$")
		if k then t[M.dec(k)] = M.dec(v) end
	end
	return t
end

-- Whether a news is told to company `me`: a sale done, a contract signed or over to everybody; the rest (offers, answers,
-- the monthly payments) to the companies it concerns only (a chat line a month per contract for every player would be noise).
M.PUBLIC = { sold = true, ct_start = true, ct_end = true }
function M.newsFor(n, me)
	if M.PUBLIC[n.kind] then return true end
	if me == nil then return false end
	return n.from == me or n.to == me or n.by == me or n.supplier == me or n.payer == me
end

local function sayNews(s, reg, st, env)
	local last = s and s.newsSeq or 0
	if M.g.seen == nil then M.g.seen = last; return end
	if last <= M.g.seen then
		-- (another savegame loaded in this GUI state: its news start again)
		if last < M.g.seen then M.g.seen = last end
		return
	end
	local T = M.T(env)
	local me = tonumber(env.myCo)
	local function name(id) return M.rt.coName(st, findCo(reg, id)) end
	for _, n in ipairs(s.news or {}) do
		if n.n > M.g.seen and M.newsFor(n, me) then
			local ok, t = pcall(M.newsText, T, n, name, M.rt.cargoLabel)
			if ok and t then env.chat(t) end
		end
	end
	M.g.seen = last
end

-- the host's figures for the month over (its own measure), sent once (again after 10 s when the games did not take them)
local function hostPay(st, s, reg, env)
	local due = s.due
	if not due or due <= (s.paidMon or -math.huge) then return end
	local now = env.realTime and env.realTime() or 0
	if M.g.payMon == due and now - (M.g.payAt or now) < 10 then return end
	local h = s.here or {}
	local fig = {}
	for _, c in ipairs(s.ct or {}) do
		if (c.state == "active" or c.state == "ending") and (c.start or due) <= due then
			local n = (h.lastMon == due and type(h.last) == "table") and (tonumber(h.last[tostring(c.id)]) or 0) or 0
			local lost = not M.rt.station(env, st, findCo(reg, c.payer), c.key)
			fig[#fig + 1] = { id = c.id, n = math.floor(n), lost = lost or nil }
		end
	end
	if #fig == 0 then return end
	M.g.payMon, M.g.payAt = due, now
	env.send("f_trade_pay", { month = due, ct = fig })
	env.log("trade: the host's figures of month " .. due .. " sent (" .. #fig .. " contract(s))")
end

-- the window's file (M.FILE: feat_trade_trade.txt): what this player's company can do and sees
local function windowFile(st, s, reg, env, sales, contracts)
	local T = M.T(env)
	local mine = findCo(reg, tonumber(env.myCo))
	local isChief = mine ~= nil and chief(mine) == keyOf(env.me)
	local L = { "me\t" .. tostring(mine and mine.id or 0) .. "\t" .. (isChief and 1 or 0) .. "\t" .. (sales and 1 or 0) .. "\t" .. (contracts and 1 or 0) }
	local names, ids = {}, {}
	for _, c in ipairs(reg.list or {}) do
		names[c.id] = M.rt.coName(st, c)
		L[#L + 1] = "co\t" .. c.id .. "\t" .. M.enc(names[c.id]) .. "\t" .. (tradable(c) and 1 or 0)
		if tradable(c) and c.ent then ids[c.ent] = c.id end
	end
	-- (the world's lists, which look through every construction and station of the map: only while the player looks at the tab,
	-- whose drawing asks for them (M.request "look", kept a minute), read again every 10 s of real time, or at once when the
	-- offers or contracts changed. Nothing is read on a big map while nobody trades)
	local now = env.realTime and env.realTime() or 0
	local sig = tostring(s and s.seq or 0) .. ":" .. tostring(s and #s.offers or 0) .. ":" .. tostring(s and #s.ct or 0)
	local looking = M.g.lookAt ~= nil and now - M.g.lookAt < 60 and now >= M.g.lookAt
	if not M.g.heavy then M.g.heavy = { lots = {}, stations = {} } end
	if looking and (M.g.heavy.sig ~= sig or now - (M.g.heavyAt or -1000) >= 10 or now < (M.g.heavyAt or 0)) then
		M.g.heavyAt = now
		M.g.heavy = { sig = sig, lots = (sales and isChief and mine) and M.rt.lots(env, st, mine) or {},
			stations = contracts and M.rt.stations(env, st, ids) or {} }
		if contracts and not M.g.cargos then M.g.cargos = M.rt.cargos() end
		-- (for the in-game check: what the window's lists hold, logged when it changes)
		local nst = 0
		for _, list in pairs(M.g.heavy.stations) do nst = nst + #list end
		local said = #M.g.heavy.lots .. "/" .. nst .. "/" .. #(M.g.cargos or {})
		if M.g.heavySaid ~= said then
			M.g.heavySaid = said
			env.log("feat trade: the window's lists: " .. #M.g.heavy.lots .. " lot(s) of company " .. tostring(mine and mine.id) .. " to sell, "
				.. nst .. " station(s) of the companies, " .. #(M.g.cargos or {}) .. " cargo(s)")
		end
	end
	for _, l in ipairs(M.g.heavy.lots) do
		L[#L + 1] = "lot\t" .. tostring(l.kind) .. "\t" .. M.enc(l.key) .. "\t" .. M.enc(l.label) .. "\t" .. (int(l.vehicles) or 0) .. "\t" .. (int(l.reserve) or 0)
	end
	if contracts then
		local cos = {}
		for id in pairs(M.g.heavy.stations) do cos[#cos + 1] = id end
		table.sort(cos)
		for _, id in ipairs(cos) do
			for _, x in ipairs(M.g.heavy.stations[id]) do L[#L + 1] = "st\t" .. id .. "\t" .. M.enc(x.key) .. "\t" .. M.enc(x.label) end
		end
		for _, x in ipairs(M.g.cargos or {}) do L[#L + 1] = "cargo\t" .. M.enc(x.name) .. "\t" .. M.enc(x.label) end
	end
	local me = mine and mine.id or -1
	for _, o in ipairs(s and s.offers or {}) do
		if o.from == me or o.to == me then
			L[#L + 1] = "offer\t" .. o.id .. "\t" .. o.from .. "\t" .. o.to .. "\t" .. o.kind .. "\t" .. M.enc(o.label) .. "\t" .. (o.nveh or 0) .. "\t" .. o.price
		end
	end
	local h = s and s.here or {}
	for _, c in ipairs(s and s.ct or {}) do
		if c.supplier == me or c.payer == me then
			local ck = tostring(c.id)
			L[#L + 1] = "ct\t" .. c.id .. "\t" .. c.state .. "\t" .. c.by .. "\t" .. c.supplier .. "\t" .. c.payer .. "\t" .. M.enc(c.label)
				.. "\t" .. M.enc(M.rt.cargoLabel(c.cargo)) .. "\t" .. c.per .. "\t" .. c.price .. "\t" .. c.penalty .. "\t" .. c.months
				.. "\t" .. (c.done or 0) .. "\t" .. math.floor(tonumber(h.cur and h.cur[ck]) or 0) .. "\t" .. tostring(c.last or "")
		end
	end
	local function name(id) return names[id] or ("#" .. tostring(id)) end
	local list = s and s.news or {}
	for i = math.max(1, #list - 7), #list do
		local ok, t = pcall(M.newsText, T, list[i], name, M.rt.cargoLabel)
		if ok and t then L[#L + 1] = "news\t" .. M.enc(t) end
	end
	env.write(M.FILE, L)
end

-- The GUI half, every game, about once a second: the news in this game's chat, the host's figures of a month over, the window's
-- file. Nothing while both options are off.
function M.gui(st, env)
	local sales, contracts = env.on("sales"), env.on("contracts")
	if not (sales or contracts) then return end
	local reg = type(st) == "table" and st.co or nil
	if not (type(reg) == "table" and reg.mode == "separate") then return end
	local s = peek(st)
	sayNews(s, reg, st, env)
	if contracts and env.isHost and s then hostPay(st, s, reg, env) end
	windowFile(st, s, reg, env, sales, contracts)
end

-- A request of the MPFever window (its buttons, see M.view): checked here (a player who is not its company's chief is told why,
-- nothing is sent) and sent as the module's event. payload: "k=v;..." (M.encode) or a table. Returns true when sent.
function M.request(kind, payload, st, env)
	-- (the tab is looked at: the lists of assets, stations and cargos are read for its file, see windowFile)
	if kind == "look" then
		M.g.lookAt = env.realTime and env.realTime() or 0
		return false
	end
	local p = type(payload) == "table" and payload or M.decode(payload)
	local reg = type(st) == "table" and st.co or nil
	if not (type(reg) == "table" and reg.mode == "separate") then return false end
	local T = M.T(env)
	local mine = findCo(reg, tonumber(env.myCo))
	if not (mine and chief(mine) == keyOf(env.me)) then
		env.chat(T(M.TX.only_chief[1], M.TX.only_chief[2]))
		return false
	end
	local yes = p.accept == true or p.accept == "1"
	if kind == "offer" and env.on("sales") then
		env.send("f_trade_offer", { to = tonumber(p.to), kind = p.kind, key = p.key, price = tonumber(p.price) })
	elseif kind == "answer" and env.on("sales") then
		env.send("f_trade_answer", { id = tonumber(p.id), accept = yes })
	elseif kind == "cancel" and env.on("sales") then
		env.send("f_trade_cancel", { id = tonumber(p.id) })
	elseif kind == "ct_offer" and env.on("contracts") then
		env.send("f_trade_ct_offer", { to = tonumber(p.to), role = p.role, station = p.station, cargo = p.cargo, per = tonumber(p.per),
			price = tonumber(p.price), penalty = tonumber(p.penalty), months = tonumber(p.months) })
	elseif kind == "ct_answer" and env.on("contracts") then
		env.send("f_trade_ct_answer", { id = tonumber(p.id), accept = yes })
	elseif kind == "ct_cancel" and env.on("contracts") then
		env.send("f_trade_ct_cancel", { id = tonumber(p.id) })
	else
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------------------------------------------- the window
-- The tab's content as plain data (M.view, tested offline), drawn by M.ui with the window's helpers. M.form holds the choices of
-- the forms (this window's memory).
M.form = {}

function M.parse(lines)
	local m = { cos = {}, names = {}, lots = {}, st = {}, cargos = {}, offers = {}, ct = {}, news = {} }
	for _, line in ipairs(lines or {}) do
		local f = {}
		for x in (tostring(line) .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
		local k = f[1]
		if k == "me" then
			m.known = true
			m.me = tonumber(f[2]); if m.me == 0 then m.me = nil end
			m.chief, m.sales, m.contracts = f[3] == "1", f[4] == "1", f[5] == "1"
		elseif k == "co" then
			local c = { id = tonumber(f[2]), name = M.dec(f[3]), ok = f[4] == "1" }
			m.cos[#m.cos + 1] = c
			m.names[c.id] = c.name
		elseif k == "lot" then
			m.lots[#m.lots + 1] = { kind = f[2], key = M.dec(f[3]), label = M.dec(f[4]), nveh = tonumber(f[5]) or 0, reserve = tonumber(f[6]) or 0 }
		elseif k == "st" then
			local id = tonumber(f[2])
			m.st[id] = m.st[id] or {}
			m.st[id][#m.st[id] + 1] = { key = M.dec(f[3]), label = M.dec(f[4]) }
		elseif k == "cargo" then
			m.cargos[#m.cargos + 1] = { name = M.dec(f[2]), label = M.dec(f[3]) }
		elseif k == "offer" then
			m.offers[#m.offers + 1] = { id = tonumber(f[2]), from = tonumber(f[3]), to = tonumber(f[4]), kind = f[5], label = M.dec(f[6]),
				nveh = tonumber(f[7]) or 0, price = tonumber(f[8]) or 0 }
		elseif k == "ct" then
			m.ct[#m.ct + 1] = { id = tonumber(f[2]), state = f[3], by = tonumber(f[4]), supplier = tonumber(f[5]), payer = tonumber(f[6]),
				label = M.dec(f[7]), cargo = M.dec(f[8]), per = tonumber(f[9]) or 0, price = tonumber(f[10]) or 0, penalty = tonumber(f[11]) or 0,
				months = tonumber(f[12]) or 0, done = tonumber(f[13]) or 0, cur = tonumber(f[14]) or 0, last = tonumber(f[15]) }
		elseif k == "news" then
			m.news[#m.news + 1] = M.dec(f[2])
		end
	end
	return m
end

-- (the one after or before `cur` in `list`, by field `field`, going round; the first when cur is not in it)
local function step(list, field, cur, d)
	if #list == 0 then return nil end
	local at = nil
	for i, x in ipairs(list) do if x[field] == cur then at = i end end
	if not at then return list[1][field] end
	return list[(at - 1 + d) % #list + 1][field]
end

local function pick(list, field, cur)
	for _, x in ipairs(list) do if x[field] == cur then return x end end
	return list[1]
end

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- The tab's rows: { { item, ... }, ... }, an item = { text = "..." } or { button = "label", req = { kind, payload }, off = true
-- when it cannot be used } or { button = "label", set = { field = value, ... } } (a choice of the form, M.form).
function M.view(m, T, f)
	f = f or {}
	local X = M.TX
	local rows = {}
	local function tr(pair, ...) return M.tr(T, pair, ...) end
	local function text(s, cls) rows[#rows + 1] = { { text = s, cls = cls } } end
	local function row(items) rows[#rows + 1] = items end
	-- (no file: not the companies mode; a file without a company: a player between two companies, for a few seconds)
	if not m.me then text(tr(m.known and X.no_company or X.only_separate)); return rows end
	local function name(id) return m.names[id] or ("#" .. tostring(id)) end
	local others = {}
	for _, c in ipairs(m.cos) do if c.ok and c.id ~= m.me then others[#others + 1] = c end end
	local off = not m.chief
	if off then text(tr(X.only_chief), "warning") end
	if #others == 0 then text(tr(X.no_other)) end
	if m.sales then
		text(tr(X.sales), "title")
		for _, o in ipairs(m.offers) do
			local w = M.lotText(T, { kind = o.kind, label = o.label, nveh = o.nveh })
			if o.to == m.me then
				row({ { text = tr(X.got_offer, name(o.from), w, M.money(o.price)) },
					{ button = tr(X.accept), req = { "answer", M.encode({ id = o.id, accept = true }) }, off = off },
					{ button = tr(X.refuse), req = { "answer", M.encode({ id = o.id, accept = false }) }, off = off } })
			elseif o.from == m.me then
				row({ { text = tr(X.my_offer, w, name(o.to), M.money(o.price)) },
					{ button = tr(X.cancel), req = { "cancel", M.encode({ id = o.id }) }, off = off } })
			end
		end
		if m.chief and #others > 0 then
			local lot = nil
			for _, l in ipairs(m.lots) do if f.lot and l.key == f.lot then lot = l end end
			if lot then
				local buyer = pick(others, "id", f.buyer)
				local price = clamp(math.floor(tonumber(f.price) or lot.reserve or 0), 0, M.MAX_PRICE)
				row({ { text = tr(X.sell_to, M.lotText(T, lot), buyer.name) },
					{ button = "<", set = { buyer = step(others, "id", buyer.id, -1) } },
					{ button = ">", set = { buyer = step(others, "id", buyer.id, 1) } } })
				local items = { { text = tr(X.price, M.money(price), M.money(lot.reserve)) } }
				for _, d in ipairs({ -1000000, -100000, 100000, 1000000 }) do
					items[#items + 1] = { button = (d > 0 and "+" or "-") .. (math.abs(d) >= 1000000 and "1 M" or "100 k"), set = { price = clamp(price + d, 0, M.MAX_PRICE) } }
				end
				row(items)
				row({ { button = tr(X.propose), req = { "offer", M.encode({ to = buyer.id, kind = lot.kind, key = lot.key, price = price }) } },
					{ button = tr(X.cancel), set = { lot = false, price = false } } })
			elseif #m.lots > 0 then
				text(tr(X.sell_pick))
				for _, l in ipairs(m.lots) do
					row({ { text = M.lotText(T, l) }, { button = tr(X.sell), set = { lot = l.key, price = l.reserve } } })
				end
			else
				text(tr(X.sell_none))
			end
		end
	end
	if m.contracts then
		text(tr(X.contracts), "title")
		for _, c in ipairs(m.ct) do
			if c.state == "active" or c.state == "ending" then
				local left = c.state == "ending" and tr(X.ct_ends) or (c.months > 0 and tr(X.ct_left, math.max(0, c.months - c.done)) or M.monthsText(T, 0))
				local items = { { text = tr(X.ct_line, name(c.supplier), c.per, c.cargo, name(c.payer), c.label, M.money(c.price), M.money(c.penalty),
					c.cur, c.last or 0, left) } }
				if c.state == "active" then items[#items + 1] = { button = tr(X.ct_end_btn), req = { "ct_cancel", M.encode({ id = c.id }) }, off = off } end
				row(items)
			elseif c.by ~= m.me then
				row({ { text = tr(X.ct_got, name(c.by), name(c.supplier), c.per, c.cargo, name(c.payer), c.label, M.money(c.price), M.money(c.penalty), M.monthsText(T, c.months)) },
					{ button = tr(X.accept), req = { "ct_answer", M.encode({ id = c.id, accept = true }) }, off = off },
					{ button = tr(X.refuse), req = { "ct_answer", M.encode({ id = c.id, accept = false }) }, off = off } })
			else
				row({ { text = tr(X.ct_mine, name(c.supplier), c.per, c.cargo, name(c.payer), c.label, M.money(c.price), M.money(c.penalty), M.monthsText(T, c.months)) },
					{ button = tr(X.cancel), req = { "ct_cancel", M.encode({ id = c.id }) }, off = off } })
			end
		end
		if m.chief and #others > 0 then
			local role = f.role == "pay" and "pay" or "supply"
			local other = pick(others, "id", f.other)
			local payer = role == "supply" and other.id or m.me
			local sts = m.st[payer] or {}
			local stn = pick(sts, "key", f.station)
			local cargo = pick(m.cargos, "name", f.cargo)
			local per = clamp(math.floor(tonumber(f.per) or 100), 1, M.CT_MAX_PER)
			local price = clamp(math.floor(tonumber(f.cprice) or 50), 1, M.CT_MAX_PRICE)
			local pen = clamp(math.floor(tonumber(f.penalty) or 0), 0, M.CT_MAX_PRICE)
			local months = oneOf(tonumber(f.months), M.CT_MONTHS) and tonumber(f.months) or 12
			row({ { text = tr(X.ct_new) }, { button = tr(X.ct_supply), set = { role = "supply" }, off = role == "supply" },
				{ button = tr(X.ct_pay), set = { role = "pay" }, off = role == "pay" } })
			row({ { text = tr(X.ct_with, other.name) }, { button = "<", set = { other = step(others, "id", other.id, -1), station = false } },
				{ button = ">", set = { other = step(others, "id", other.id, 1), station = false } } })
			if stn then
				row({ { text = tr(X.ct_station, name(payer), stn.label) }, { button = "<", set = { station = step(sts, "key", stn.key, -1) } },
					{ button = ">", set = { station = step(sts, "key", stn.key, 1) } } })
			else
				text(tr(X.ct_nostation, name(payer)))
			end
			if cargo then
				row({ { text = tr(X.ct_cargo, cargo.label) }, { button = "<", set = { cargo = step(m.cargos, "name", cargo.name, -1) } },
					{ button = ">", set = { cargo = step(m.cargos, "name", cargo.name, 1) } } })
			end
			local function steps(label, field, value, list, lo, hi)
				local items = { { text = label } }
				for _, d in ipairs(list) do
					items[#items + 1] = { button = (d > 0 and "+" or "-") .. math.abs(d), set = { [field] = clamp(value + d, lo, hi) } }
				end
				row(items)
			end
			steps(tr(X.ct_per, per), "per", per, { -100, -10, 10, 100 }, 1, M.CT_MAX_PER)
			steps(tr(X.ct_price, M.money(price)), "cprice", price, { -100, -10, 10, 100 }, 1, M.CT_MAX_PRICE)
			steps(tr(X.ct_pen, M.money(pen)), "penalty", pen, { -100, -10, 10, 100 }, 0, M.CT_MAX_PRICE)
			local nextMonths = M.CT_MONTHS[1]
			for i, x in ipairs(M.CT_MONTHS) do if x == months then nextMonths = M.CT_MONTHS[i % #M.CT_MONTHS + 1] end end
			row({ { text = tr(X.ct_months, M.monthsText(T, months)) }, { button = ">", set = { months = nextMonths } } })
			row({ { button = tr(X.ct_propose), off = not (stn and cargo), req = { "ct_offer", M.encode({ to = other.id, role = role,
				station = stn and stn.key or "", cargo = cargo and cargo.name or "", per = per, price = price, penalty = pen, months = months }) } } })
			text(tr(X.ct_how))
		end
	end
	if #m.news > 0 then
		text(tr(X.news), "title")
		for _, t in ipairs(m.news) do text(t) end
	end
	return rows
end

-- an item of the view used: a request to this game's module (M.request), or a choice of the form
function M.act(u, item)
	if item.off then return end
	if item.req then
		u.request(item.req[1], item.req[2])
	elseif item.set then
		for k, v in pairs(item.set) do
			if v == false then M.form[k] = nil else M.form[k] = v end
		end
	end
	if u.refresh then u.refresh() end
end

-- The tab, drawn with the window's helpers (U.featU of mpfever_ui.script.lua, docs/FEATURES-0.6.md): each row of the view is its
-- texts, one under the other at the window's width (u.title for a heading, u.text with a class), then its buttons side by side
-- (u.row of u.button(label, fn, primary, enabled)), each put in the tab with u.add. The window draws it again after a button and
-- about once a second. Drawing it tells the GUI half that the player looks at it (at most every 15 s): the lists of the world are
-- read only then.
-- (0.7.4, the menus redone) the page in the Hub: two tabs (sales, supply contracts); the offers as cards; a sale in three steps (what,
-- to whom, the price typed in a field, no more ±100 k buttons); the contracts in a table and a form of lists and fields. The same
-- requests as M.view's buttons (M.request checks them). Used when the Hub draws the page (u.rich) and the player did not ask for
-- the window's old pages (u.oldMenus); else M.view's rows, as before.
M.TX2 = {
	tab_sales = { "Ventes", "Sales" },
	tab_contracts = { "Contrats de livraison", "Supply contracts" },
	got_title = { "Offres reçues", "Offers received" },
	sent_title = { "Mes offres envoyées", "My offers sent" },
	none_got = { "Aucune offre reçue pour l'instant.", "No offer received yet." },
	none_sent = { "Vous n'avez envoyé aucune offre.", "You sent no offer." },
	from = { "Proposé par %s, pour %s", "Offered by %s, for %s" },
	to = { "Proposé à %s, pour %s", "Offered to %s, for %s" },
	sell_title = { "Vendre un bien à une autre entreprise", "Sell an asset to another company" },
	step1 = { "1. Ce que vous vendez", "1. What you sell" },
	step2 = { "2. L'acheteur", "2. The buyer" },
	step3 = { "3. Votre prix", "3. Your price" },
	k_line = { "Lignes, avec leurs véhicules et les gares de leurs arrêts", "Lines, with their vehicles and the stations of their stops" },
	k_station = { "Gares", "Stations" },
	k_depot = { "Dépôts", "Depots" },
	h_asset = { "Bien", "Asset" },
	h_value = { "Valeur indicative", "Indicative value" },
	pick = { "Choisir", "Pick" },
	chosen = { "Vous vendez %s.", "You sell %s." },
	change = { "Changer", "Change" },
	price_field = { "Prix en dollars", "Price in dollars" },
	price_is = { "Prix proposé : %s (valeur indicative %s)", "Price offered: %s (indicative value %s)" },
	price_bad = { "Tapez un prix entre 0 et 10 milliards de dollars.", "Type a price between 0 and 10 billion dollars." },
	ct_running = { "Contrats en cours", "Running contracts" },
	ct_none = { "Aucun contrat en cours.", "No running contract." },
	ct_pending = { "Offres de contrat", "Contract offers" },
	h_who = { "Livre → paie", "Delivers → pays" },
	h_cargo = { "Marchandise", "Cargo" },
	h_station = { "Gare", "Station" },
	h_month = { "Ce mois / prévu", "This month / due" },
	h_last = { "Mois dernier", "Last month" },
	h_price = { "Prix · pénalité", "Price · penalty" },
	h_end = { "Fin", "End" },
	ct_form = { "Proposer un contrat", "Offer a contract" },
	f_role = { "Votre rôle", "Your role" },
	f_other = { "L'autre entreprise", "The other company" },
	f_station = { "Gare de livraison (de %s)", "Delivery station (of %s)" },
	f_cargo = { "Marchandise", "Cargo" },
	f_per = { "Quantité par mois", "Quantity per month" },
	f_price = { "Prix par unité ($)", "Price per unit ($)" },
	f_pen = { "Pénalité par unité manquante ($)", "Penalty per missing unit ($)" },
	f_months = { "Durée", "Length" },
	f_sum = { "Résumé : %s livre %s %s par mois à %s, gare « %s », %s par unité, pénalité %s, %s.",
		"Summary: %s delivers %s %s a month to %s, station « %s », %s per unit, penalty %s, %s." },
	f_bad = { "Quantité de 1 à 100 000 par mois, prix et pénalité de 0 à 1 000 000 $ par unité.", "Quantity from 1 to 100 000 a month, price and penalty from $0 to $1 000 000 per unit." },
	help1 = { "Le commerce se fait entre les entreprises des joueurs (pas celles de l'ordinateur), et seul le chef d'une entreprise vend, achète ou signe.",
		"Trade takes place between the players' companies (not the computer's), and only a company's chief sells, buys or signs." },
	help2 = { "Vendre : choisissez un bien (une ligne part avec ses véhicules et les gares de ses arrêts), l'acheteur et votre prix. L'acheteur accepte ou refuse ; une offre sans réponse expire après deux mois de jeu. L'argent passe d'une entreprise à l'autre à l'acceptation.",
		"Sell: pick an asset (a line goes with its vehicles and the stations of its stops), the buyer and your price. The buyer accepts or refuses; an offer without an answer expires after two game months. The money changes hands when it is accepted." },
	help3 = { "Un contrat de livraison : une entreprise livre chaque mois une quantité d'une marchandise à une gare de l'autre, qui paie un prix par unité livrée. Un mois non tenu est payé au prorata et le livreur paie la pénalité pour chaque unité manquante.",
		"A supply contract: one company delivers every month a quantity of a cargo to a station of the other, which pays a price per unit delivered. A month not met is paid pro rata and the deliverer pays the penalty for each missing unit." },
}

function M.uiRich(u, m, T)
	local X, Y = M.TX, M.TX2
	local f = M.form
	local function tr(pair, ...) return M.tr(T, pair, ...) end
	local function name(id) return m.names[id] or ("#" .. tostring(id)) end
	local function digits(s) return tonumber((tostring(s or ""):gsub("[^%d]", ""))) end
	local function req(kind, t) u.request(kind, M.encode(t)); for k in pairs(f) do if k ~= "tab" then f[k] = nil end end end
	if not m.me then u.add(u.text(tr(m.known and X.no_company or X.only_separate))); return end
	local others = {}
	for _, c in ipairs(m.cos) do if c.ok and c.id ~= m.me then others[#others + 1] = c end end
	local off = not m.chief
	-- (the tabs: only those of the options the host turned on)
	local tab = f.tab
	if tab ~= "sales" and tab ~= "contracts" then tab = m.sales and "sales" or "contracts" end
	if tab == "sales" and not m.sales then tab = "contracts" end
	if tab == "contracts" and not m.contracts then tab = "sales" end
	if m.sales and m.contracts then
		u.add(u.row({ u.button(tr(Y.tab_sales), function() f.tab = "sales" end, tab == "sales"),
			u.button(tr(Y.tab_contracts), function() f.tab = "contracts" end, tab == "contracts") }))
		u.add(u.gap(8))
	end
	if off then u.add(u.text(tr(X.only_chief), "warning")) end
	if #others == 0 then u.add(u.muted(tr(X.no_other))) end
	if tab == "sales" then
		-- the offers received and sent, a card each
		local got, sent = {}, {}
		for _, o in ipairs(m.offers) do if o.to == m.me then got[#got + 1] = o elseif o.from == m.me then sent[#sent + 1] = o end end
		u.add(u.title(tr(Y.got_title)))
		if #got == 0 then u.add(u.muted(tr(Y.none_got))) end
		for _, o in ipairs(got) do
			local id = o.id
			u.add(u.card(M.lotText(T, { kind = o.kind, label = o.label, nveh = o.nveh }), {
				u.text(tr(Y.from, name(o.from), M.money(o.price))),
				u.row({ u.button(tr(X.accept), function() req("answer", { id = id, accept = true }) end, true, not off),
					u.button(tr(X.refuse), function() req("answer", { id = id, accept = false }) end, false, not off) }),
			}, { color = u.coColor(o.from) }))
			u.add(u.gap(6))
		end
		u.add(u.title(tr(Y.sent_title)))
		if #sent == 0 then u.add(u.muted(tr(Y.none_sent))) end
		for _, o in ipairs(sent) do
			local id = o.id
			u.add(u.card(M.lotText(T, { kind = o.kind, label = o.label, nveh = o.nveh }), {
				u.text(tr(Y.to, name(o.to), M.money(o.price))),
				u.row({ u.button(tr(X.cancel), function() req("cancel", { id = id }) end, false, not off) }),
			}, { color = u.coColor(o.to) }))
			u.add(u.gap(6))
		end
		-- the sale, in three steps
		if m.chief and #others > 0 then
			u.add(u.title(tr(Y.sell_title)))
			local lot = nil
			for _, l in ipairs(m.lots) do if f.lot and l.key == f.lot and l.kind == f.lotKind then lot = l end end
			u.add(u.text(tr(Y.step1)))
			if not lot then
				if #m.lots == 0 then u.add(u.muted(tr(X.sell_none))) end
				for _, kind in ipairs({ "line", "station", "depot" }) do
					local lines = {}
					for _, l in ipairs(m.lots) do
						if l.kind == kind then
							local key, k2, res = l.key, l.kind, l.reserve
							lines[#lines + 1] = { M.lotText(T, l), M.money(l.reserve),
								u.button(tr(Y.pick), function() f.lot, f.lotKind, f.price = key, k2, res end, false, true) }
						end
					end
					if #lines > 0 then
						u.add(u.muted(tr(Y["k_" .. kind])))
						table.insert(lines, 1, { tr(Y.h_asset), tr(Y.h_value), "" })
						u.add(u.table(lines, { 60, 22, 18 }, true))
						u.add(u.gap(6))
					end
				end
			else
				u.add(u.row({ u.text(tr(Y.chosen, M.lotText(T, lot))), u.button(tr(Y.change), function() f.lot, f.lotKind, f.price = nil, nil, nil end) }))
				u.add(u.gap(6))
				u.add(u.text(tr(Y.step2)))
				local buyer = pick(others, "id", f.buyer)
				local bs = {}
				for _, c in ipairs(others) do
					local cid = c.id
					bs[#bs + 1] = u.button(c.name, function() f.buyer = cid end, c.id == buyer.id)
				end
				u.add(u.row(bs))
				u.add(u.gap(6))
				u.add(u.text(tr(Y.step3)))
				u.add(u.input(tr(Y.price_field), function(v) f.price = digits(v) end, "sale_price", 260))
				local price = math.floor(tonumber(f.price) or lot.reserve or 0)
				local ok = price >= 0 and price <= M.MAX_PRICE
				u.add(ok and u.muted(tr(Y.price_is, M.money(price), M.money(lot.reserve))) or u.text(tr(Y.price_bad), "error"))
				local kind, key, to = lot.kind, lot.key, buyer.id
				u.add(u.row({ u.button(tr(X.propose), function() req("offer", { to = to, kind = kind, key = key, price = price }) end, true, ok),
					u.button(tr(X.cancel), function() f.lot, f.lotKind, f.price = nil, nil, nil end) }))
			end
		end
	else
		-- the contracts: those offered (a card each), those running (a table), the form
		local pending, running = {}, {}
		for _, c in ipairs(m.ct) do
			if c.state == "active" or c.state == "ending" then running[#running + 1] = c else pending[#pending + 1] = c end
		end
		if #pending > 0 then
			u.add(u.title(tr(Y.ct_pending)))
			for _, c in ipairs(pending) do
				local id = c.id
				if c.by ~= m.me then
					u.add(u.card(nil, {
						u.text(tr(X.ct_got, name(c.by), name(c.supplier), c.per, c.cargo, name(c.payer), c.label, M.money(c.price), M.money(c.penalty), M.monthsText(T, c.months))),
						u.row({ u.button(tr(X.accept), function() req("ct_answer", { id = id, accept = true }) end, true, not off),
							u.button(tr(X.refuse), function() req("ct_answer", { id = id, accept = false }) end, false, not off) }),
					}, { color = u.coColor(c.by) }))
				else
					u.add(u.card(nil, {
						u.text(tr(X.ct_mine, name(c.supplier), c.per, c.cargo, name(c.payer), c.label, M.money(c.price), M.money(c.penalty), M.monthsText(T, c.months))),
						u.row({ u.button(tr(X.cancel), function() req("ct_cancel", { id = id }) end, false, not off) }),
					}))
				end
				u.add(u.gap(6))
			end
		end
		u.add(u.title(tr(Y.ct_running)))
		if #running == 0 then
			u.add(u.muted(tr(Y.ct_none)))
		else
			local lines = { { tr(Y.h_who), tr(Y.h_cargo), tr(Y.h_station), tr(Y.h_month), tr(Y.h_last), tr(Y.h_price), tr(Y.h_end), "" } }
			for _, c in ipairs(running) do
				local left = c.state == "ending" and tr(X.ct_ends) or (c.months > 0 and tr(X.ct_left, math.max(0, c.months - c.done)) or M.monthsText(T, 0))
				local id = c.id
				lines[#lines + 1] = { name(c.supplier) .. " → " .. name(c.payer), c.cargo, c.label, c.cur .. " / " .. c.per, tostring(c.last or 0),
					M.money(c.price) .. " · " .. M.money(c.penalty), left,
					c.state == "active" and u.button(tr(X.ct_end_btn), function() req("ct_cancel", { id = id }) end, false, not off) or "" }
			end
			u.add(u.table(lines, { 22, 12, 14, 10, 8, 14, 10, 10 }, true))
		end
		if m.chief and #others > 0 then
			u.add(u.title(tr(Y.ct_form)))
			local role = f.role == "pay" and "pay" or "supply"
			local other = pick(others, "id", f.other)
			local payer = role == "supply" and other.id or m.me
			local supplier = role == "supply" and m.me or other.id
			local sts = m.st[payer] or {}
			local stn = pick(sts, "key", f.station)
			local cargo = pick(m.cargos, "name", f.cargo)
			-- (a label and its field a line, the fields in one column)
			local form = {}
			form[#form + 1] = { tr(Y.f_role), u.row({ u.button(tr(X.ct_supply), function() f.role = "supply"; f.station = nil end, role == "supply"),
				u.button(tr(X.ct_pay), function() f.role = "pay"; f.station = nil end, role == "pay") }) }
			local cos = {}
			for _, c in ipairs(others) do cos[#cos + 1] = { value = c.id, label = c.name } end
			form[#form + 1] = { tr(Y.f_other), u.choice(cos, other.id, function(v) f.other = v; f.station = nil end, 300) }
			local sl = {}
			for _, x in ipairs(sts) do sl[#sl + 1] = { value = x.key, label = x.label } end
			if stn then
				form[#form + 1] = { tr(Y.f_station, name(payer)), u.choice(sl, stn.key, function(v) f.station = v end, 300) }
			else
				form[#form + 1] = { tr(Y.f_station, name(payer)), u.text(tr(X.ct_nostation, name(payer)), "warning") }
			end
			local cl = {}
			for _, x in ipairs(m.cargos) do cl[#cl + 1] = { value = x.name, label = x.label } end
			if cargo then form[#form + 1] = { tr(Y.f_cargo), u.choice(cl, cargo.name, function(v) f.cargo = v end, 300) } end
			local per = math.floor(tonumber(f.per) or 100)
			local price = math.floor(tonumber(f.cprice) or 50)
			local pen = math.floor(tonumber(f.penalty) or 0)
			form[#form + 1] = { tr(Y.f_per), u.input("100", function(v) f.per = digits(v) end, "ct_per", 160) }
			form[#form + 1] = { tr(Y.f_price), u.input("50", function(v) f.cprice = digits(v) end, "ct_price", 160) }
			form[#form + 1] = { tr(Y.f_pen), u.input("0", function(v) f.penalty = digits(v) end, "ct_pen", 160) }
			local months = oneOf(tonumber(f.months), M.CT_MONTHS) and tonumber(f.months) or 12
			local ms = {}
			for _, x in ipairs(M.CT_MONTHS) do
				local v = x
				ms[#ms + 1] = u.button(M.monthsText(T, x), function() f.months = v end, x == months)
			end
			form[#form + 1] = { tr(Y.f_months), u.row(ms) }
			u.add(u.table(form, { 34, 66 }, false))
			local ok = per >= 1 and per <= M.CT_MAX_PER and price >= 0 and price <= M.CT_MAX_PRICE and pen >= 0 and pen <= M.CT_MAX_PRICE
			if not ok then u.add(u.text(tr(Y.f_bad), "error")) end
			if stn and cargo and ok then
				u.add(u.muted(tr(Y.f_sum, name(supplier), per, cargo.label, name(payer), stn.label, M.money(price), M.money(pen), M.monthsText(T, months))))
			end
			local to, rl = other.id, role
			u.add(u.row({ u.button(tr(X.ct_propose), function()
				req("ct_offer", { to = to, role = rl, station = stn and stn.key or "", cargo = cargo and cargo.name or "", per = per, price = price, penalty = pen, months = months })
			end, true, (stn and cargo and ok) and true or false) }))
			u.add(u.muted(tr(X.ct_how)))
		end
	end
	if #m.news > 0 then
		u.add(u.title(tr(X.news)))
		for _, t in ipairs(m.news) do u.add(u.muted(t)) end
	end
	u.help("trade", { Y.help1, Y.help2, Y.help3 })
end

function M.ui(u)
	local T = u.T or function(fr, en) return en end
	local now = os.clock()
	if not M.lookAt or now - M.lookAt >= 15 or now < M.lookAt then
		M.lookAt = now
		u.request("look", "")
	end
	-- (0.7.4: the Hub's page, see M.uiRich; the old pages asked, or a kit without its helpers: as before)
	if u.rich and not u.oldMenus and u.choice and u.help and u.input and u.table and u.card then
		local okR, errR = pcall(M.uiRich, u, M.parse(u.read(M.FILE) or {}), T)
		if okR then return {} end
		if u.add then u.add(u.text("trade: " .. tostring(errR), "error")) end
		return {}
	end
	local rows = M.view(M.parse(u.read(M.FILE) or {}), T, M.form)
	local nodes = {}
	local function add(n) if n ~= nil then if u.add then u.add(n) else nodes[#nodes + 1] = n end end end
	for _, r in ipairs(rows) do
		local buttons = {}
		for _, it in ipairs(r) do
			if it.button then
				local item = it
				buttons[#buttons + 1] = u.button(it.button, function() M.act(u, item) end, false, not it.off)
			elseif it.cls == "title" and u.title then
				add(u.gap and u.gap(6) or nil)
				add(u.title(it.text))
			else
				add(u.text(it.text, it.cls))
			end
		end
		if #buttons > 0 then add(u.row and u.row(buttons) or buttons[1]) end
	end
	return nodes
end

return M
