-- MPFever 0.6 game option "tenders": shared calls for offers between the companies, in the "one company per player" mode only
-- (docs/FEATURES-0.6.md is the contract of the 0.6 options; release/recherche-0.6/02-appels-offres.md the research, and the
-- owner's decisions B1-B7 in 00-REPONSES.md).
--
-- Now and then the host's game publishes a tender every company sees: (a) carry N passengers between the towns A and B without a
-- transfer, (b) deliver N units of a cargo to an industry, (c) deliver N units of a cargo to a town, before a date. The first
-- company to reach N wins a bonus, created as the game's own subsidies are (a SUBSIDY entry of its journal: nobody pays it, B1).
-- There is no registration: the race starts when the tender is published. Every company runs, the computer companies too,
-- whatever their level (B4). Two tenders at most are open at a time; the host sets how often they come and the bonus level (B5).
--
-- Who decides what:
--  * every game counts the progress in its simulation from the engine's ticket price event (OnCalcTicketPrice, the one the game's
--    subsidies count with, see M.onGameEvent): one entry is one passenger or one unit of cargo carried by the company of the
--    entry's line. Every leg of a chain counts for the company that carries it (B6), as for the game's subsidies: a cargo's entry
--    names its final destination on every leg, so a feeder line counts as well as the last one;
--  * the host's game alone publishes, names the winner, expires and cancels (M.gui), with the module's events, stamped and applied
--    by every game at the same step (as co_month in 0.5). A game never decides from its own count: the winner and the money are
--    the host's word, the same on every game by construction (the shown progress is all a difference of counts could change).
--
-- Events (all from the host's game: param.mpfFrom, added by the bridge, tells it; see fromHost):
--   f_tenders_new    {id, kind, a, b, cargo, goal, deadline, prize}  a tender opens (id = the last one + 1)
--   f_tenders_win    {id, co}                                         company co wins it: the bonus is booked to it
--   f_tenders_expire {id}                                             its date passed without a winner
--   f_tenders_cancel {id, why}                                        its town or industry is gone (why: its name)
-- a and b are places { name, x, y, e }: a town, or an industry by its stock list (what the ticket price events name), with the
-- host's entity as a hint only. Each game finds its own entity from them (entity ids may differ between games, see M.world).
-- The cargo travels by its resource name (api.res.cargoTypeRep.getName), never by its id.
--
-- State st.feat.tenders (plain data, saved with the game; nothing at all while the option is off):
--   { month = <the game month seen last (env.month())>, seq = <the last tender published>, next = <the month of the next one>,
--     open = { tender... } (M.MAX_OPEN at most), done = { the last M.KEEP_DONE, status "won" / "expired" / "cancelled" },
--     wins = { ["<co>"] = n } (the tenders each company won: the goal's count, B7, see M.wins) }
--   tender = { id, kind = "pax" | "ind" | "town", a, b (pax), cargo (ind, town), goal, deadline = <month>, prize, at = <month>,
--              prog = { ["<co>"] = n }, reached = { ["<co>"] = <game time it reached the goal> } }
-- (the companies are keys as strings: a saved table keeps them so, as the registry's own maps)

local M = {}
M.ID = "tenders"

M.FREQ_VALUES, M.FREQ_DEFAULT = { 12, 6, 3 }, 6         -- months between two tenders
M.PRIZE_VALUES, M.PRIZE_DEFAULT = { 50, 100, 200 }, 100  -- the bonus level, in percent

M.OPTIONS = {
	{ id = "tenders",
		title = { "Appels d'offres", "Tenders" },
		desc = { "De temps en temps, une ville ou une industrie lance un appel d'offres ouvert à toutes les entreprises, celles de l'ordinateur comprises : la première qui atteint l'objectif avant la date touche la prime.",
			"Now and then a town or an industry calls for offers, open to every company, the computer ones too: the first one to reach the goal before the date wins the bonus." },
		modes = "separate",
		params = {
			{ id = "freq", label = { "Fréquence", "Frequency" }, values = M.FREQ_VALUES, default = M.FREQ_DEFAULT,
				show = function(v, T) return M.say(T, "freq" .. tostring(v)) end },
			{ id = "prize", label = { "Niveau de prime", "Bonus level" }, values = M.PRIZE_VALUES, default = M.PRIZE_DEFAULT,
				show = function(v, T) return M.say(T, "prize" .. tostring(v)) end },
		} },
}

M.EVENTS = { f_tenders_new = true, f_tenders_win = true, f_tenders_expire = true, f_tenders_cancel = true }
-- the engine events the module counts with: the options host may leave the others out before it reads the state
M.GAME_EVENTS = { OnCalcTicketPrice = true }
M.TAB = { id = "tenders", title = { "Appels d'offres", "Tenders" } }
-- (0.7.4) the page's « How does it work? », at its end in the Hub (see the window's U.featTabRows)
M.HELP = {
	{ "De temps en temps, une ville ou une industrie lance un appel d'offres : transporter une quantité de voyageurs ou de marchandises avant une date. Il est ouvert à toutes les entreprises, celles de l'ordinateur comprises.",
		"Now and then a town or an industry calls for tenders: carry a quantity of passengers or goods before a date. It is open to every company, the computer's included." },
	{ "La première entreprise qui atteint l'objectif avant la date touche la prime ; les autres ne gagnent rien. La barre de chaque appel montre où en est chaque entreprise, et « Voir » amène la caméra sur la ville ou l'industrie.",
		"The first company to reach the goal before the date gets the bonus; the others win nothing. Each tender's bar shows where every company stands, and « Show » takes the camera to the town or industry." },
}
-- the window's file: env.write("list") writes feat_tenders_list.txt in the session folder, u.read("list") reads it back
M.FILE = "list"

M.MAX_OPEN = 2           -- tenders open at a time (B5)
M.KEEP_DONE = 20         -- closed tenders kept for the history (the engine walks the whole state at every state:get())
M.RESEND_SECONDS = 15    -- an event of the host the state did not take (a resynchronisation refuses them) goes again
M.MAX_SENDS = 4          -- and is given up after that many sends: the host decides again (a winner gone bankrupt meanwhile)
M.RETRY_SECONDS = 60     -- nothing to publish: the host looks again a minute later
M.CHECK_SECONDS = 30     -- the host looks for a tender's town or industry gone that often
M.KIND_ORDER = { "pax", "ind", "town" }
-- the engine's systems that send the ticket price event: passengers, cargo (the game's subsidy scripts tell them apart so)
M.PAX_SYSTEM, M.CARGO_SYSTEM = "SimEntityAtVehicleSystem", "TransportVehicleSystem"

-- Every text a player sees: { French, English }, as the contract's OPTIONS. M.say puts them through the caller's T(fr, en)
-- (C.T: the other languages from lang.txt, by the English text).
M.TEXTS = {
	freq12 = { "Rares (tous les 12 mois)", "Rare (every 12 months)" },
	freq6 = { "Normaux (tous les 6 mois)", "Normal (every 6 months)" },
	freq3 = { "Fréquents (tous les 3 mois)", "Frequent (every 3 months)" },
	prize50 = { "Faible (x0,5)", "Low (x0.5)" },
	prize100 = { "Normal (x1)", "Normal (x1)" },
	prize200 = { "Élevé (x2)", "High (x2)" },
	pax = { "Transporter %s voyageurs entre %s et %s, sans correspondance", "Carry %s passengers between %s and %s, without a transfer" },
	ind = { "Livrer %s %s à %s", "Deliver %s %s to %s" },
	town = { "Livrer %s %s à la ville de %s", "Deliver %s %s to the town of %s" },
	number = { "Appel d'offres n°%s", "Tender #%s" },
	prizeLeft = { "Prime : %s. Reste %s mois.", "Bonus: %s. %s months left." },
	lastMonth = { "Prime : %s. Dernier mois.", "Bonus: %s. Last month." },
	progress = { "%s : %s / %s", "%s: %s / %s" },
	you = { "%s (vous)", "%s (you)" },
	nobody = { "Aucune entreprise n'a encore commencé.", "No company has started yet." },
	see = { "Voir %s", "Show %s" },
	none = { "Aucun appel d'offres en cours : le prochain arrive bientôt.", "No tender open: the next one comes soon." },
	rule = { "La première entreprise qui atteint l'objectif avant la date touche la prime, une subvention. Chaque tronçon d'une correspondance compte pour l'entreprise qui le fait.",
		"The first company to reach the goal before the date wins the bonus, a subsidy. Each leg of a chain counts for the company that carries it." },
	history = { "Terminés", "Closed" },
	won = { "n°%s, %s : gagné par %s (%s)", "#%s, %s: won by %s (%s)" },
	expired = { "n°%s, %s : expiré sans gagnant", "#%s, %s: expired without a winner" },
	cancelled = { "n°%s, %s : annulé, %s a disparu", "#%s, %s: cancelled, %s is gone" },
	winsTitle = { "Appels d'offres gagnés", "Tenders won" },
	winsLine = { "%s : %s", "%s: %s" },
	company = { "Entreprise %s", "Company %s" },
	chatNew = { "Nouvel appel d'offres n°%s : %s, en %s mois. Prime : %s.", "New tender #%s: %s, within %s months. Bonus: %s." },
	chatWon = { "%s remporte l'appel d'offres n°%s et touche %s.", "%s wins tender #%s and gets %s." },
	chatExpired = { "L'appel d'offres n°%s a expiré sans gagnant.", "Tender #%s expired without a winner." },
	chatCancelled = { "L'appel d'offres n°%s est annulé : %s a disparu.", "Tender #%s is cancelled: %s is gone." },
}

-- a text of M.TEXTS in the caller's language (T: env.T or u.T; English without one); each %s takes the next value, put in with
-- gsub (a value may contain % itself, as C.Tf)
function M.say(T, key, ...)
	local t = M.TEXTS[key]
	if not t then return tostring(key) end
	local s = (type(T) == "function" and T(t[1], t[2])) or t[2]
	local values, i = { ... }, 0
	s = s:gsub("%%s", function() i = i + 1; return tostring(values[i]) end)
	return s
end

-- "$1 234 567", as the bridge's G.coMoney
function M.money(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local neg = s:sub(1, 1) == "-"
	if neg then s = s:sub(2) end
	s = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return (neg and "-$" or "$") .. s
end

local function num(v)
	v = tonumber(v)
	if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
	return v
end

local function int(v)
	v = num(v)
	return v and math.floor(v + 0.5) or nil
end

local function clean(s, n)
	s = tostring(s or ""):gsub("%c", " ")
	return s:sub(1, n or 80)
end

-- ------------------------------------------------------------------------------------------------------------- the game's world
-- Everything the module reads from the game goes through these functions (each one in pcall: a missing piece reads as nothing).
-- The tests replace them; the integration may too. Simulation half: the places, a line's company, the passengers' towns, the
-- cargo. GUI half (the host's choice of a tender): the towns, the industries, what is produced and needed, the camera.
local W = {}
M.world = W

local function ctype(name)
	local ok, v = pcall(function() return api.type.ComponentType[name] end)
	return ok and v or nil
end

function W.comp(e, name)
	local t = ctype(name)
	if t == nil or type(e) ~= "number" then return nil end
	local ok, c = pcall(api.engine.getComponent, e, t)
	return ok and c or nil
end

function W.name(e)
	if type(e) ~= "number" then return nil end
	local ok, n = pcall(function() return api.engine.util.getEntityName(e) end)
	if ok and type(n) == "string" and n ~= "" then return n end
	local c = W.comp(e, "NAME")
	return c and c.name or nil
end

-- the middle of an entity's bounding volume, as the game's entity_util.getPosition
function W.position(e)
	local bb = W.comp(e, "BOUNDING_VOLUME")
	if not bb then return nil end
	local ok, x, y = pcall(function() return (bb.bbox.max.x + bb.bbox.min.x) / 2, (bb.bbox.max.y + bb.bbox.min.y) / 2 end)
	if ok and type(x) == "number" and type(y) == "number" then return x, y end
	return nil
end

-- the entities with a component, sorted (gathered first: nothing else is read inside the engine's loop)
function W.each(name)
	local t = ctype(name)
	local out = {}
	if t ~= nil then pcall(api.engine.forEachEntityWithComponent, function(e) out[#out + 1] = e end, t) end
	table.sort(out)
	return out
end

local function far2(place, x, y)
	if type(x) ~= "number" or type(y) ~= "number" then return math.huge end
	return (x - place.x) ^ 2 + (y - place.y) ^ 2
end
local NEAR2 = 1500 * 1500

-- a town of this game from a place: the hint when it is a town of that name or still where the host saw it (a town grows, its
-- middle moves a little), else the nearest town of that name
function W.findTown(place)
	if type(place) ~= "table" then return nil end
	local e = place.e
	if type(e) == "number" and W.comp(e, "TOWN") and (W.name(e) == place.name or far2(place, W.position(e)) < NEAR2) then return e end
	local best, bd = nil, nil
	for _, t in ipairs(W.each("TOWN")) do
		if W.name(t) == place.name then
			local d = far2(place, W.position(t))
			if not bd or d < bd then best, bd = t, d end
		end
	end
	return best
end

-- an industry's stock list, what the ticket price events name (as the game's deliver_cargo subsidies)
function W.industryStock(e)
	local ind = W.comp(e, "INDUSTRY")
	return ind and ind.stockList or nil
end

-- an industry of this game from a place (its stock list): the hint when its name and place match (stock lists are many: both
-- must), else the nearest industry of that name
function W.findIndustry(place)
	if type(place) ~= "table" then return nil end
	local e = place.e
	if type(e) == "number" and W.comp(e, "STOCK_LIST") and W.name(e) == place.name and far2(place, W.position(e)) < NEAR2 then return e end
	local best, bd = nil, nil
	for _, i in ipairs(W.each("INDUSTRY")) do
		local sl = W.industryStock(i)
		if sl and W.name(sl) == place.name then
			local d = far2(place, W.position(sl))
			if not bd or d < bd then best, bd = sl, d end
		end
	end
	return best
end

-- the company's player entity of a line
function W.lineOwner(line)
	local po = W.comp(line, "PLAYER_OWNED")
	return po and po.player or nil
end

-- whether a line stops in a town (unknown: true, the passengers' own towns decide then)
function W.lineServes(line, town)
	local ok, yes = pcall(function() return api.engine.util.town.isLineStoppingInTown(line, town) end)
	if ok then return yes == true end
	return true
end

-- the town of a passenger's (or a cargo's) boarding or alighting stop on its line: the game's town_util.getTownForSimEntity
-- (game_mechanics/towns/town_util.tl), the one its passenger subsidies count with, written here so that nothing is required
function W.townOfSim(sim, boarding)
	local ok, town = pcall(function()
		local at = W.comp(sim, "SIM_ENTITY_AT_VEHICLE") or W.comp(sim, "SIM_ENTITY_AT_TERMINAL")
		if not at then return nil end
		local line = W.comp(at.line, "LINE")
		local stop = line.stops[(boarding and at.lineStop0 or at.lineStop1) + 1]
		local sg = W.comp(stop.stationGroup, "STATION_GROUP")
		if not sg or #sg.stations == 0 then return nil end
		return api.engine.system.stationSystem.getTown(sg.stations[1])
	end)
	return ok and town or nil
end

function W.isPerson(sim) return W.comp(sim, "SIM_PERSON") ~= nil end

function W.cargoOfSim(sim)
	local c = W.comp(sim, "SIM_CARGO")
	return c and c.cargoType or nil
end

-- the town of a town building's stock list (as the game's deliver_cargo_town subsidies)
function W.townOfStockList(sl)
	local tb = W.comp(sl, "TOWN_BUILDING")
	return tb and tb.town or nil
end

function W.cargoId(name)
	local ok, id = pcall(function() return api.res.cargoTypeRep.find(name) end)
	return (ok and type(id) == "number" and id >= 0) and id or nil
end

function W.cargoName(id)
	local ok, n = pcall(function() return api.res.cargoTypeRep.getName(id) end)
	return (ok and type(n) == "string" and n ~= "") and n or nil
end

-- a cargo's name in this game's language (the game's own translation), else its resource name
function W.cargoLabel(name)
	local ok, s = pcall(function() return api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(name)).name end)
	if ok and type(s) == "string" and s ~= "" then return s end
	return (tostring(name):match("([^/]+)%.lua$") or tostring(name))
end

-- the towns: { { e, name, x, y, size } } (size: the towns' person capacities, as the computer companies' townsBySize)
function W.towns()
	local caps = {}
	pcall(function() caps = api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() or {} end)
	local out = {}
	for _, e in ipairs(W.each("TOWN")) do
		local x, y = W.position(e)
		local n = W.name(e)
		if x and n then
			local size = 0
			pcall(function() local c = caps[e]; size = (c[1] or 0) + (c[2] or 0) + (c[3] or 0) end)
			out[#out + 1] = { e = e, name = n, x = x, y = y, size = size }
		end
	end
	return out
end

-- the industries by their stock list, with the cargo they need and nobody delivers yet (the inputs of their rules, as the game's
-- subvention_util.getAllCargoRequired, delivered 0 a year): { { e, name, x, y, needs = { cargo name... } } }
function W.industries()
	local out = {}
	for _, i in ipairs(W.each("INDUSTRY")) do
		local sl = W.industryStock(i)
		local stock = sl and W.comp(sl, "STOCK_LIST")
		local x, y = W.position(sl)
		local n = W.name(sl)
		if stock and x and n then
			local needs, seen = {}, {}
			pcall(function()
				for _, rule in ipairs(stock.rules) do
					for _, v in ipairs(rule.input) do
						for stockId, amount in ipairs(v) do
							if amount ~= 0 then
								local cid = stock.stocks[stockId].cargoType
								local cn = W.cargoName(cid)
								local okd, d = pcall(function() return api.engine.util.stock.getCargoTypeDeliveredPerYear(sl, cid) end)
								if cn and not seen[cn] and okd and d == 0 then seen[cn] = true; needs[#needs + 1] = cn end
							end
						end
					end
				end
			end)
			table.sort(needs)
			out[#out + 1] = { e = sl, name = n, x = x, y = y, needs = needs }
		end
	end
	return out
end

-- the cargo some industry ever produced (the game's subvention_util.getAllProducedCargo): { [cargo name] = true }
function W.produced()
	local out = {}
	for _, i in ipairs(W.each("INDUSTRY")) do
		local sl = W.industryStock(i)
		local stock = sl and W.comp(sl, "STOCK_LIST")
		if stock then
			pcall(function()
				for k, rd in ipairs(stock.ruleDatas) do
					if #rd.applyHistory > 0 then
						for cid, amount in pairs(stock.rules[k].output) do
							local cn = (amount or 0) > 0 and W.cargoName(cid)
							if cn then out[cn] = true end
						end
					end
				end
			end)
		end
	end
	return out
end

-- the cargo a town needs and nobody supplies (as the game's deliver_cargo_town: supply 0), sorted
function W.townNeeds(town)
	local out = {}
	pcall(function()
		for cid, v in pairs(api.engine.system.townBuildingSystem.getCargoSupplyAndLimit(town)) do
			if v[1] == 0 then
				local cn = W.cargoName(cid)
				if cn then out[#out + 1] = cn end
			end
		end
	end)
	table.sort(out)
	return out
end

-- whether a passenger line with vehicles already links two towns directly: the game's own test before it offers its passenger
-- subsidy (subvention_util.areTownsConnected + cargo_util.hasLineVehicleWithCapacity); unknown: not linked
function W.connected(a, b)
	local ok, yes = pcall(function()
		local su = ug_require("/game_mechanics/subventions/subvention_util.tl")
		local cu = ug_require("::/gui/main/cargo_util.tl")
		local line = su.areTownsConnected(a, b, true)
		return line ~= nil and cu.hasLineVehicleWithCapacity(line, cu.getPassengerCargoTypeId())
	end)
	return ok and yes == true
end

-- an amount of the game's first years in today's money (the game's finances_util.scaleWithInflation, as its subsidies)
function W.inflation(amount)
	local ok, v = pcall(function() return ug_require("/game_mechanics/finance/finances_util.tl").scaleWithInflation(amount) end)
	return (ok and type(v) == "number" and v > 0) and v or amount
end

function W.focus(place)
	local ok = pcall(function() api.gui.camera.focusPosition(api.type.Vec3f.new(place.x, place.y, 0), 600) end)
	return ok
end

-- (0.6) the game's own multiplier of the subsidies' money (its advanced options, as the game's subsidy scripts read it); 1 when
-- it cannot be read or is not above 0 (the host switched the tenders on with a bonus level of its own)
function W.rewardMultiplier()
	local ok, v = pcall(function() return api.res.getBaseConfig().advancedOptions.subventionFinancialRewardMultiplier end)
	if ok and type(v) == "number" and v > 0 and v <= 100 then return v end
	return 1
end

-- ----------------------------------------------------------------------------------------------------------------- the state
local function peek(st)
	local f = type(st) == "table" and st.feat or nil
	local S = type(f) == "table" and f[M.ID] or nil
	return type(S) == "table" and S or nil
end

local function stateOf(st, env)
	local S = env.state(st)
	S.seq = S.seq or 0
	S.open = S.open or {}
	S.done = S.done or {}
	S.wins = S.wins or {}
	return S
end

-- the option on, in the separate mode (B3: not in co-op): else nothing at all happens, no state is even made
local function active(env)
	return env.mode == "separate" and env.on("tenders") and true or false
end

local function paramOf(env, pid, values, default)
	local v = int(env.param and env.param("tenders", pid))
	for _, x in ipairs(values) do if x == v then return v end end
	return default
end

local function openIndex(S, id)
	for i, t in ipairs(S and S.open or {}) do if t.id == id then return i end end
	return nil
end

-- the module's events come from the host's game only: the bridge adds the sender's name (mpfFrom) to every MPFever event in the
-- separate mode, and a player who joined has "#n" after it (as mpfever_eco.lua's fromHost). An event without a sender (an
-- options host that leaves it out) is taken: every game applies the same anyway.
local function fromHost(param, env)
	if env.fromHost then return env.fromHost(param) and true or false end
	local o = param.mpfFrom
	if o == nil then return true end
	return type(o) == "string" and o ~= "" and not o:find("#", 1, true)
end

-- the companies (env.companies() of the contract, else the registry), and whether one is gone (bankrupt, merged, empty): the
-- registry says it when the list does not
local function companiesOf(env)
	if env.companies then return env.companies() or {} end
	return (type(env.co) == "table" and env.co.list) or {}
end

local function isGone(env, c)
	if c.gone then return true end
	if type(env.co) == "table" and type(env.co.list) == "table" then
		for _, r in ipairs(env.co.list) do if r.id == c.id then return r.gone ~= nil and r.gone ~= false end end
	end
	return false
end

local function companyOf(env, id)
	for _, c in ipairs(companiesOf(env)) do if c.id == id then return c end end
	if type(env.co) == "table" and type(env.co.list) == "table" then
		for _, c in ipairs(env.co.list) do if c.id == id then return c end end
	end
	return nil
end

local function place(p)
	if type(p) ~= "table" then return nil end
	local name, x, y = p.name, num(p.x), num(p.y)
	if type(name) ~= "string" or name == "" or not x or not y then return nil end
	return { name = clean(name), x = math.floor(x + 0.5), y = math.floor(y + 0.5), e = int(p.e) }
end

local function samePlace(a, b) return a and b and a.name == b.name and a.x == b.x and a.y == b.y end

local function close(S, i, status, month, winner, why)
	local t = table.remove(S.open, i)
	S.done[#S.done + 1] = { id = t.id, kind = t.kind, a = t.a, b = t.b, cargo = t.cargo, goal = t.goal, prize = t.prize,
		status = status, closed = month, winner = winner, why = why }
	while #S.done > M.KEEP_DONE do table.remove(S.done, 1) end
end

-- B7: the tenders a company won (the game's goal may count them, see 01-objectifs-stats.md)
function M.wins(st, co)
	local S = peek(st)
	local n = S and type(S.wins) == "table" and S.wins[tostring(co)]
	return tonumber(n) or 0
end

-- a part of the games' check: what was published and how each one ended (not the progress: only the host's word decides)
function M.signature(st)
	local S = peek(st)
	if not S then return nil end
	local parts = { tostring(S.seq or 0) }
	for _, t in ipairs(S.open or {}) do parts[#parts + 1] = tostring(t.id) .. ":open" end
	for _, d in ipairs(S.done or {}) do parts[#parts + 1] = tostring(d.id) .. ":" .. tostring(d.status) .. ":" .. tostring(d.winner or 0) end
	return table.concat(parts, ",")
end

-- ------------------------------------------------------------------------------------------------------- simulation half
-- (every game, at the same step: only the state, the events and the world; nothing of a clock, a random or a file)

local function publish(S, p, env, month)
	local id = int(p.id)
	if not id or id ~= S.seq + 1 then
		env.log("tenders: tender " .. tostring(p.id) .. " refused: the last one published is " .. tostring(S.seq)); return
	end
	if #S.open >= M.MAX_OPEN then env.log("tenders: tender " .. id .. " refused: " .. M.MAX_OPEN .. " are open"); return end
	local kind = p.kind
	local a, b = place(p.a), place(p.b)
	local cargo = (type(p.cargo) == "string" and p.cargo ~= "") and clean(p.cargo, 200) or nil
	local goal, prize, deadline = int(p.goal), int(p.prize), int(p.deadline)
	local okKind = kind == "pax" or kind == "ind" or kind == "town"
	if not okKind or not a or (kind == "pax" and (not b or samePlace(a, b))) or (kind ~= "pax" and not cargo)
		or not goal or goal < 1 or goal > 1000000 or not prize or prize < 0 or prize > 1e10 or not deadline or deadline <= month then
		env.log("tenders: tender " .. id .. " refused: its content is not valid"); return
	end
	S.seq = id
	S.open[#S.open + 1] = { id = id, kind = kind, a = a, b = kind == "pax" and b or nil, cargo = kind ~= "pax" and cargo or nil,
		goal = goal, prize = prize, deadline = deadline, at = month, prog = {}, reached = {} }
	-- (the rhythm is kept in the state: a reload or another host keeps it)
	S.next = month + paramOf(env, "freq", M.FREQ_VALUES, M.FREQ_DEFAULT)
	env.log("tenders: tender " .. id .. " (" .. kind .. ") open until month " .. deadline .. ", goal " .. goal .. ", bonus " .. prize)
end

function M.event(st, name, param, env)
	if not M.EVENTS[name] then return end
	-- (the option off, or the co-op mode: nothing at all, not even a state; a late send of the host's is only logged)
	if not active(env) then env.log("tenders: " .. tostring(name) .. " ignored: the option is off (or the co-op mode)"); return end
	if type(param) ~= "table" then return end
	if not fromHost(param, env) then
		env.log("tenders: " .. name .. " from " .. tostring(param.mpfFrom) .. " refused: only the host decides"); return
	end
	local S = stateOf(st, env)
	local month = int(env.month and env.month()) or S.month or 0
	if name == "f_tenders_new" then return publish(S, param, env, month) end
	local id = int(param.id)
	local i = openIndex(S, id)
	if not i then env.log("tenders: " .. name .. " for tender " .. tostring(param.id) .. " refused: it is not open"); return end
	local t = S.open[i]
	if name == "f_tenders_win" then
		local co = int(param.co)
		local c = co and companyOf(env, co)
		-- (a company gone meanwhile wins nothing: the same on every game, the registry is; the host then decides again)
		if not c or isGone(env, c) then env.log("tenders: tender " .. id .. " refused to company " .. tostring(param.co) .. ": no such company"); return end
		-- the bonus is created as the game's subsidies are (B1): booked to the company, taken from nobody
		if c.ent then
			env.book(c.ent, t.prize, "subsidy")
			env.log("feat tenders: bonus " .. t.prize .. " of tender " .. id .. " booked to company " .. co .. " (player entity " .. tostring(c.ent) .. ") as a subsidy")
		else
			env.log("tenders: company " .. co .. " has no entity here: bonus not booked")
		end
		local k = tostring(co)
		S.wins[k] = (S.wins[k] or 0) + 1
		close(S, i, "won", month, co, nil)
		env.log("tenders: tender " .. id .. " won by company " .. co .. " (" .. t.prize .. ")")
	elseif name == "f_tenders_expire" then
		-- (the month is every game's at this step: a host's look that came too early is refused everywhere alike)
		if month < t.deadline then env.log("tenders: tender " .. id .. " not expired yet (month " .. month .. " < " .. t.deadline .. ")"); return end
		close(S, i, "expired", month, nil, nil)
		env.log("tenders: tender " .. id .. " expired")
	elseif name == "f_tenders_cancel" then
		close(S, i, "cancelled", month, nil, clean(param.why, 80))
		env.log("tenders: tender " .. id .. " cancelled (" .. tostring(param.why) .. " is gone)")
	end
end

-- the game month in the state, for the host's decisions (the GUI half has no calendar of its own here): at the start of every
-- month, and a few steps after the option is switched on
function M.month(st, env)
	if not active(env) or not env.month then return end
	local S = stateOf(st, env)
	S.month = int(env.month()) or S.month
	return true
end

function M.tick(st, env)
	if not (env.every and env.month and env.every(25)) or not active(env) then return end
	local m = int(env.month())
	local S = peek(st)
	if not m or (S and S.month == m) then return end
	S = stateOf(st, env)
	S.month = m
	return true
end

-- This Lua state's look at the world. The tenders' places and cargo found once (by name and place: the entity ids may differ
-- between games). The rest only within one step (the world changes between steps, and the simulation may run this script in
-- several Lua states, each with its own tables): what a line serves, its company, a stock list's town.
M._sim = { res = {}, step = nil }

local function stepCache(env)
	local c = M._sim
	local now = env.gameTime()
	if c.step ~= now then
		c.step, c.owner, c.serves, c.town, c.coOf = now, {}, {}, {}, nil
	end
	return c
end

local function resolved(t, env)
	local key = t.id .. "|" .. t.kind .. "|" .. t.a.name .. "|" .. (t.b and t.b.name or "") .. "|" .. (t.cargo or "")
	local r = M._sim.res[t.id]
	if r and r.key == key and (r.ok or env.gameTime() < r.retryAt) then return r.ok and r or nil end
	r = { key = key }
	if t.kind == "ind" then r.a = W.findIndustry(t.a) else r.a = W.findTown(t.a) end
	if t.kind == "pax" then r.b = W.findTown(t.b) end
	if t.cargo then r.cargo = W.cargoId(t.cargo) end
	r.ok = r.a ~= nil and (t.kind ~= "pax" or r.b ~= nil) and (t.kind == "pax" or r.cargo ~= nil)
	-- (not found here: the host cancels it when it cannot find it either; looked for again 25 steps later)
	if not r.ok then
		r.retryAt = env.gameTime() + 25 * (env.STEP or 200)
		env.log("tenders: tender " .. t.id .. ": " .. t.a.name .. " not found on this game")
	end
	M._sim.res[t.id] = r
	return r.ok and r or nil
end

-- a field of an event's entry (a Lua table, as the game's scripts read it; anything else is read in pcall: a field it lacks
-- may throw)
local function field(p, k)
	if type(p) == "table" then return p[k] end
	local ok, v = pcall(function() return p[k] end)
	return ok and v or nil
end

local function matches(t, r, p, isCargo, c)
	if isCargo then
		local sl = field(p, "stockListEntity")
		if sl == nil then return false end
		if t.kind == "ind" then
			if sl ~= r.a then return false end
		else
			local town = c.town[sl]
			if town == nil then town = W.townOfStockList(sl) or false; c.town[sl] = town end
			if town ~= r.a then return false end
		end
		return W.cargoOfSim(field(p, "simEntity")) == r.cargo
	end
	-- (a line that does not stop in both towns carries nobody between them: one look per line and step)
	local line = field(p, "lineEntity")
	local key = t.id .. ":" .. tostring(line)
	local serves = c.serves[key]
	if serves == nil then serves = W.lineServes(line, r.a) and W.lineServes(line, r.b); c.serves[key] = serves end
	if not serves then return false end
	local sim = field(p, "simEntity")
	local from, to = W.townOfSim(sim, true), W.townOfSim(sim, false)
	return (from == r.a and to == r.b) or (from == r.b and to == r.a)
end

-- The engine's ticket price event (every game): one entry per passenger or unit of cargo at the end of its ride on a line.
-- Returns true when the state changed (the options host writes it back then). The options host must never return anything
-- for this event from the bridge's handleEvent: a table returned there changes the ticket prices.
-- id: the engine's system that sent it, as the game's subsidy scripts read it (handleEvent(src, id, name, param): id
-- "SimEntityAtVehicleSystem" for passengers, "TransportVehicleSystem" for cargo); src: the event's source. The options host gives
-- them in that order (F.simGameEvent: st, id, name, param, env, src); either one naming a system is taken, and without one each
-- entry tells what it carries.
-- (this Lua state's first ticket price events and first counts are logged, "feat tenders: ...", for the in-game checks)
M._seen = { sys = {}, counted = {} }

-- (the options host asks once a step: no tender open, nothing to count, the bridge reads no state for the game's events)
function M.hearsNow(st)
	local S = peek(st)
	return (S and type(S.open) == "table" and S.open[1] ~= nil) and true or false
end
function M.onGameEvent(st, id, name, param, env, src)
	if name ~= "OnCalcTicketPrice" or param == nil then return false end
	local S = peek(st)
	if not (S and type(S.open) == "table" and S.open[1]) then return false end
	if not active(env) then return false end
	local sys = nil
	if id == M.PAX_SYSTEM or src == M.PAX_SYSTEM then sys = "pax" elseif id == M.CARGO_SYSTEM or src == M.CARGO_SYSTEM then sys = "cargo" end
	local wantPax, wantCargo = false, false
	for _, t in ipairs(S.open) do if t.kind == "pax" then wantPax = true else wantCargo = true end end
	if (sys == "pax" and not wantPax) or (sys == "cargo" and not wantCargo) then return false end
	local okn, n = pcall(function() return #param end)
	if not okn or type(n) ~= "number" or n == 0 then return false end
	local seenKey = tostring(id) .. "/" .. tostring(src)
	local seenN = M._seen.sys[seenKey] or 0
	if seenN < 3 then
		M._seen.sys[seenKey] = seenN + 1
		env.log("feat tenders: ticket price event id " .. tostring(id) .. ", src " .. tostring(src) .. ": " .. n .. " entries, read as " .. tostring(sys or "unknown (each entry tells)"))
	end
	local c = stepCache(env)
	if not c.coOf then
		-- (the live companies by their player entity on this game: a gone company's lines count for nobody)
		c.coOf = {}
		for _, co in ipairs(companiesOf(env)) do if co.ent and not isGone(env, co) then c.coOf[co.ent] = co.id end end
	end
	local changed = false
	local rs = {}
	for i = 1, n do
		local p = param[i]
		if p ~= nil then
			local line = field(p, "lineEntity")
			local owner = c.owner[line or false]
			if owner == nil and line ~= nil then owner = W.lineOwner(line) or false; c.owner[line] = owner end
			local co = owner and c.coOf[owner]
			if co then
				local isCargo
				if sys then isCargo = sys == "cargo" else isCargo = field(p, "stockListEntity") ~= nil or not W.isPerson(field(p, "simEntity")) end
				for j, t in ipairs(S.open) do
					if (t.kind ~= "pax") == isCargo then
						-- (the tender's places on this game: looked up once for the whole event)
						local r = rs[j]
						if r == nil then r = resolved(t, env) or false; rs[j] = r end
						if r and matches(t, r, p, isCargo, c) then
							local k = tostring(co)
							t.prog = t.prog or {}
							t.reached = t.reached or {}
							t.prog[k] = (t.prog[k] or 0) + 1
							if t.prog[k] >= t.goal and not t.reached[k] then
								t.reached[k] = env.gameTime()
								env.log("feat tenders: company " .. k .. " reached the goal of tender " .. t.id .. " (" .. t.prog[k] .. ") at t=" .. tostring(t.reached[k]))
							end
							if not M._seen.counted[t.id .. ":" .. k] then
								M._seen.counted[t.id .. ":" .. k] = true
								env.log("feat tenders: tender " .. t.id .. " (" .. t.kind .. ") counts for company " .. k .. " (line " .. tostring(field(p, "lineEntity"))
									.. ", " .. (isCargo and "cargo" or "passengers") .. "), now " .. t.prog[k] .. " / " .. t.goal)
							end
							changed = true
						end
					end
				end
			end
		end
	end
	return changed
end

-- ----------------------------------------------------------------------------------------------------------------- GUI half
-- (every game, about once a second, the state read only; the host's game alone decides and sends)

-- this game's memory: the host's events not taken yet, the notices already told, the last looks
M._g = { pending = {}, checkAt = {}, labels = {} }

-- the companies as the GUI sees them, sorted by number: { id, name, color, gone, ai }. The registry first: it tells the companies
-- gone (a list without that would let the host name a bankrupt company again and again, refused on every game each time)
local function guiCompanies(st, env)
	local list = (type(st) == "table" and type(st.co) == "table" and type(st.co.list) == "table" and st.co.list)
		or (env.companies and env.companies()) or {}
	local out = {}
	for _, c in ipairs(list) do
		if type(c) == "table" and tonumber(c.id) then
			out[#out + 1] = { id = tonumber(c.id), name = c.name, color = c.color, gone = c.gone and true or false,
				ai = c.ai and true or (type(c.key) == "string" and c.key:sub(1, 3) == "ai:") }
		end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

local function coName(cos, id, T)
	for _, c in ipairs(cos) do if c.id == id and type(c.name) == "string" and c.name ~= "" then return c.name end end
	return M.say(T, "company", tostring(id))
end

local function label(cargo)
	if not cargo then return "" end
	local g = M._g
	g.labels = g.labels or {}
	if not g.labels[cargo] then g.labels[cargo] = W.cargoLabel(cargo) end
	return g.labels[cargo]
end

-- a tender in words: "Carry 200 passengers between A and B, without a transfer" / "Deliver 80 Iron ore to X"
function M.describe(t, T, cargoLabel)
	if t.kind == "pax" then return M.say(T, "pax", t.goal, t.a and t.a.name or "?", t.b and t.b.name or "?") end
	return M.say(T, t.kind == "ind" and "ind" or "town", t.goal, cargoLabel or "", t.a and t.a.name or "?")
end

-- The winner of an open tender on the host's look: among the live companies at the goal, the first to reach it, then the most
-- carried, then the smallest number (the companies sorted by number, a later one replaces only a better one)
function M.winner(t, cos)
	local best = nil
	for _, c in ipairs(cos) do
		if not c.gone then
			local k = tostring(c.id)
			local n = tonumber(t.prog and t.prog[k]) or 0
			local at = tonumber(t.reached and t.reached[k])
			if n >= t.goal and at then
				if not best or at < best.at or (at == best.at and n > best.n) then best = { id = c.id, at = at, n = n } end
			end
		end
	end
	return best and best.id or nil
end

-- a small generator of numbers (the host's choice only: the tender itself travels in the event). Seeded by the tender's number
-- and month, the same choice comes again for the same tender (a resend after a resynchronisation proposes the same)
function M.rng(seed)
	local s = math.floor(math.abs(seed or 1)) % 2147483647
	if s == 0 then s = 1 end
	return function(lo, hi)
		s = (s * 16807) % 2147483647
		if hi <= lo then return lo end
		return lo + s % (hi - lo + 1)
	end
end

local function used(S)
	local u = {}
	for _, t in ipairs(S.open or {}) do
		if t.kind == "pax" then
			local x, y = t.a.name, t.b and t.b.name or ""
			if x > y then x, y = y, x end
			u["pax:" .. x .. "|" .. y] = true
		else
			u[t.kind .. ":" .. t.a.name .. "|" .. tostring(t.cargo)] = true
		end
	end
	return u
end

local function placeOf(x) return { name = x.name, x = math.floor(x.x + 0.5), y = math.floor(x.y + 0.5), e = x.e } end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- the host's choice of a tender of each kind: a target, the goal, the date and the bonus before its level and the inflation
M.pick = {}

-- passengers: two towns 2 to 15 km apart, the bigger the likelier, not linked yet by a direct passenger line (as the game's own
-- passenger subsidies: a link already made would be a race won before its start)
function M.pick.pax(S, rnd, month)
	local towns, u = W.towns(), used(S)
	local list, total = {}, 0
	for i = 1, #towns do
		for j = i + 1, #towns do
			local a, b = towns[i], towns[j]
			local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
			local x, y = a.name, b.name
			if x > y then x, y = y, x end
			if d >= 2000 and d <= 15000 and not u["pax:" .. x .. "|" .. y] then
				local w = math.floor(((a.size or 0) + (b.size or 0)) / 100) + 1
				list[#list + 1] = { a = a, b = b, d = d, w = w }
				total = total + w
			end
		end
	end
	for _ = 1, 8 do
		if total <= 0 or #list == 0 then return nil end
		local r, k = rnd(1, total), 1
		while k < #list and r > list[k].w do r = r - list[k].w; k = k + 1 end
		local c = list[k]
		if not W.connected(c.a.e, c.b.e) then
			local goal = clamp(math.floor(((c.a.size or 0) + (c.b.size or 0)) / 80 + 0.5) * 10, 100, 500)
			local distF = 0.5 + 1.5 * clamp((c.d - 2000) / 13000, 0, 1)
			return { a = placeOf(c.a), b = placeOf(c.b), goal = goal, deadline = month + 18 + math.min(12, math.floor(c.d / 1000)),
				prize = rnd(10, 30) * 100000 * distF }
		end
		total = total - c.w
		table.remove(list, k)
	end
	return nil
end

-- cargo to an industry: a cargo it needs, nobody delivers yet, and some industry produces
function M.pick.ind(S, rnd, month)
	local produced, u, list = W.produced(), used(S), {}
	for _, ind in ipairs(W.industries()) do
		for _, cargo in ipairs(ind.needs or {}) do
			if produced[cargo] and not u["ind:" .. ind.name .. "|" .. cargo] then list[#list + 1] = { ind = ind, cargo = cargo } end
		end
	end
	if #list == 0 then return nil end
	local c = list[rnd(1, #list)]
	local goal = 10 * rnd(4, 15)
	return { a = placeOf(c.ind), cargo = c.cargo, goal = goal, deadline = month + 18 + rnd(0, 12), prize = rnd(8, 20) * 100000 * goal / 100 }
end

-- cargo to a town: a cargo it needs, nobody supplies, and some industry produces
function M.pick.town(S, rnd, month)
	local produced, u, list = W.produced(), used(S), {}
	for _, t in ipairs(W.towns()) do
		for _, cargo in ipairs(W.townNeeds(t.e)) do
			if produced[cargo] and not u["town:" .. t.name .. "|" .. cargo] then list[#list + 1] = { town = t, cargo = cargo } end
		end
	end
	if #list == 0 then return nil end
	local c = list[rnd(1, #list)]
	local goal = 10 * rnd(4, 15)
	return { a = placeOf(c.town), cargo = c.cargo, goal = goal, deadline = month + 18 + rnd(0, 12), prize = rnd(8, 20) * 100000 * goal / 100 }
end

-- (in-game tests, the host's game only: MPFEVER_TDGOAL=n gives every new tender the goal n)
local function testGoal()
	local ok, v = pcall(function() return os.getenv("MPFEVER_TDGOAL") end)
	v = ok and int(v) or nil
	return (v and v >= 1) and v or nil
end

-- the next tender the host publishes: the kinds in turn (the first one that finds a target), its bonus at the host's level
function M.propose(S, env)
	local month = S.month
	local id = (S.seq or 0) + 1
	local rnd = M.rng(id * 7919 + month * 31 + 17)
	local level = paramOf(env, "prize", M.PRIZE_VALUES, M.PRIZE_DEFAULT)
	-- (and the game's own subsidy money multiplier, as its subsidies: the host's game reads it, the bonus travels in the event)
	local mult = W.rewardMultiplier()
	local first = (id - 1) % #M.KIND_ORDER
	for k = 0, #M.KIND_ORDER - 1 do
		local kind = M.KIND_ORDER[(first + k) % #M.KIND_ORDER + 1]
		local ok, p = pcall(M.pick[kind], S, rnd, month)
		if ok and p then
			p.id, p.kind = id, kind
			p.prize = math.floor(W.inflation(p.prize * level / 100 * mult) / 10000 + 0.5) * 10000
			p.goal = testGoal() or p.goal
			env.log("feat tenders: the host proposes tender " .. id .. " (" .. kind .. ", " .. tostring(p.a and p.a.name) .. (p.b and (" - " .. tostring(p.b.name)) or "")
				.. (p.cargo and (", " .. p.cargo) or "") .. "), goal " .. p.goal .. ", until month " .. p.deadline .. ", bonus " .. p.prize
				.. " (level " .. level .. " %, game multiplier " .. mult .. ")")
			return p
		elseif not ok then
			env.log("tenders: no " .. kind .. " tender: " .. tostring(p))
		end
	end
	return nil
end

-- the name of a tender's place this game cannot find any more (an industry closed), nil when all are there
function M.goneTarget(t)
	if t.kind == "ind" then
		if not W.findIndustry(t.a) then return t.a.name end
	elseif not W.findTown(t.a) then
		return t.a.name
	end
	if t.kind == "pax" and not W.findTown(t.b) then return t.b.name end
	if t.cargo and not W.cargoId(t.cargo) then return label(t.cargo) end
	return nil
end

local function taken(S, p)
	if p.name == "f_tenders_new" then return (S.seq or 0) >= p.id end
	return openIndex(S, p.id) == nil
end

-- The host's decisions: the winners, the dates passed, the places gone, then a new tender when its month came. Each event goes
-- again until the state took it (a resynchronisation refuses the events: see the bridge's G.coEvent), and is given up after
-- M.MAX_SENDS sends (then decided again: a winner gone bankrupt meanwhile is refused on every game).
function M.decide(S, cos, env)
	local g = M._g
	local now = env.realTime()
	g.pending, g.checkAt = g.pending or {}, g.checkAt or {}
	for i = #g.pending, 1, -1 do
		local p = g.pending[i]
		if taken(S, p) then
			table.remove(g.pending, i)
		elseif now - p.at >= M.RESEND_SECONDS then
			if p.sends >= M.MAX_SENDS then
				table.remove(g.pending, i)
				env.log("tenders: " .. p.key .. " not taken after " .. p.sends .. " sends: decided again")
			else
				p.sends, p.at = p.sends + 1, now
				env.send(p.name, p.param)
			end
		end
	end
	local function pendingFor(id, name)
		for _, p in ipairs(g.pending) do if (id and p.id == id and p.name ~= "f_tenders_new") or (name and p.name == name) then return true end end
		return false
	end
	local function send(key, name, param)
		g.pending[#g.pending + 1] = { key = key, name = name, param = param, id = param.id, at = now, sends = 1 }
		env.log("feat tenders: the host sends " .. name .. " for tender " .. tostring(param.id) .. (param.co and (", company " .. tostring(param.co)) or ""))
		env.send(name, param)
	end
	local month = S.month
	for _, t in ipairs(S.open) do
		if not pendingFor(t.id) then
			local w = M.winner(t, cos)
			if w then
				send("win:" .. t.id, "f_tenders_win", { id = t.id, co = w })
			elseif month and month >= t.deadline then
				send("expire:" .. t.id, "f_tenders_expire", { id = t.id })
			elseif now >= (g.checkAt[t.id] or 0) then
				g.checkAt[t.id] = now + M.CHECK_SECONDS
				local gone = M.goneTarget(t)
				if gone then send("cancel:" .. t.id, "f_tenders_cancel", { id = t.id, why = gone }) end
			end
		end
	end
	if month and #S.open < M.MAX_OPEN and not pendingFor(nil, "f_tenders_new") and month >= (S.next or month)
		and now >= (g.retryAt or 0) then
		local p = M.propose(S, env)
		if p then
			send("new:" .. p.id, "f_tenders_new", p)
		else
			g.retryAt = now + M.RETRY_SECONDS
			env.log("tenders: no tender to publish now")
		end
	end
end

-- the notices in this game's chat, in its language (each game tells its own player: nothing goes on the network). What the
-- state holds at the first look (a reload, a join) was told before: only what comes after is.
function M.notices(S, cos, env, T)
	local g = M._g
	if not g.seen then
		g.seen = {}
		for _, t in ipairs(S.open) do g.seen["o" .. t.id] = true end
		for _, d in ipairs(S.done) do g.seen["o" .. d.id] = true; g.seen["d" .. d.id] = true end
		return
	end
	for _, t in ipairs(S.open) do
		if not g.seen["o" .. t.id] then
			g.seen["o" .. t.id] = true
			env.chat(M.say(T, "chatNew", t.id, M.describe(t, T, label(t.cargo)), t.deadline - (S.month or t.at), M.money(t.prize)))
		end
	end
	for _, d in ipairs(S.done) do
		if not g.seen["d" .. d.id] then
			g.seen["d" .. d.id], g.seen["o" .. d.id] = true, true
			if d.status == "won" then
				env.chat(M.say(T, "chatWon", coName(cos, d.winner, T), d.id, M.money(d.prize)))
			elseif d.status == "expired" then
				env.chat(M.say(T, "chatExpired", d.id))
			else
				env.chat(M.say(T, "chatCancelled", d.id, d.why or "?"))
			end
		end
	end
end

-- the window's file (env.write(M.FILE): feat_tenders_list.txt, tab-separated; written only when it changed):
--   month <m>            me <this player's company>
--   co <id> <name> <colour> <gone 0/1> <ai 0/1>
--   open <id> <kind> <goal> <months left> <prize> <a> <b> <cargo label> <ax> <ay> <bx> <by>
--   prog <tender> <company> <n>
--   done <id> <kind> <status> <winner> <prize> <a> <b> <cargo label> <why> <goal>   (the latest first)
--   wins <company> <n>
function M.lines(S, cos, env)
	local L = { "v\t1", "month\t" .. tostring(S.month or ""), "me\t" .. tostring(env.myCo or 0) }
	for _, c in ipairs(cos) do
		L[#L + 1] = table.concat({ "co", c.id, clean(c.name or ""), tostring(c.color or 0), c.gone and "1" or "0", c.ai and "1" or "0" }, "\t")
	end
	for _, t in ipairs(S.open) do
		L[#L + 1] = table.concat({ "open", t.id, t.kind, t.goal, t.deadline - (S.month or t.at), t.prize, clean(t.a.name),
			t.b and clean(t.b.name) or "", clean(label(t.cargo)), t.a.x, t.a.y, t.b and t.b.x or "", t.b and t.b.y or "" }, "\t")
		for _, c in ipairs(cos) do
			local n = t.prog and tonumber(t.prog[tostring(c.id)])
			if n and n > 0 then L[#L + 1] = "prog\t" .. t.id .. "\t" .. c.id .. "\t" .. n end
		end
	end
	for i = #S.done, 1, -1 do
		local d = S.done[i]
		L[#L + 1] = table.concat({ "done", d.id, d.kind, d.status, d.winner or 0, d.prize, clean(d.a and d.a.name),
			d.b and clean(d.b.name) or "", clean(label(d.cargo)), clean(d.why or ""), d.goal or 0 }, "\t")
	end
	for _, c in ipairs(cos) do
		local n = tonumber(S.wins and S.wins[tostring(c.id)])
		if n and n > 0 then L[#L + 1] = "wins\t" .. c.id .. "\t" .. n end
	end
	return L
end

function M.gui(st, env)
	-- (the option off: nothing at all, no file, no notice, no event)
	if not (env.on and env.on("tenders")) then return end
	local mode = env.mode or (type(st) == "table" and type(st.co) == "table" and st.co.mode) or nil
	if mode ~= "separate" then return end
	-- (no state yet: the simulation makes it at its first look at the month, a few steps after the option is switched on)
	local S = peek(st)
	if not S or type(S.open) ~= "table" or type(S.done) ~= "table" then return end
	local cos = guiCompanies(st, env)
	if env.write then
		local okW = env.write(M.FILE, M.lines(S, cos, env))
		if not M._g.wrote then
			M._g.wrote = true
			env.log("feat tenders: the window's file " .. M.FILE .. (okW == false and " NOT written" or " written") .. " (" .. #S.open .. " open, " .. #S.done .. " closed, last " .. tostring(S.seq) .. ")")
		end
	end
	if env.chat then M.notices(S, cos, env, env.T) end
	if env.isHost then M.decide(S, cos, env) end
end

-- the window's "Show" buttons: the camera on a tender's place ("<id>:a" or "<id>:b")
function M.request(kind, payload, st, env)
	if kind ~= "focus" then return false end
	local id, which = tostring(payload or ""):match("^(%d+):([ab])$")
	local S = peek(st)
	if not (id and S) then return false end
	id = tonumber(id)
	for _, list in ipairs({ S.open or {}, S.done or {} }) do
		for _, t in ipairs(list) do
			if t.id == id and t[which] then return W.focus(t[which]) end
		end
	end
	return false
end

-- ----------------------------------------------------------------------------------------------------------------- the window
local function split(line)
	local out, i = {}, 1
	while true do
		local j = line:find("\t", i, true)
		if not j then out[#out + 1] = line:sub(i); return out end
		out[#out + 1] = line:sub(i, j - 1)
		i = j + 1
	end
end

function M.parse(lines)
	local D = { me = 0, cos = {}, open = {}, done = {}, wins = {} }
	local byId = {}
	for _, line in ipairs(lines or {}) do
		local f = split(tostring(line))
		local k = f[1]
		if k == "month" then
			D.month = tonumber(f[2])
		elseif k == "me" then
			D.me = tonumber(f[2]) or 0
		elseif k == "co" then
			local id = tonumber(f[2])
			if id then D.cos[id] = { id = id, name = f[3], color = tonumber(f[4]), gone = f[5] == "1", ai = f[6] == "1" } end
		elseif k == "open" then
			local t = { id = tonumber(f[2]), kind = f[3], goal = tonumber(f[4]) or 0, left = tonumber(f[5]) or 0, prize = tonumber(f[6]) or 0,
				a = { name = f[7], x = tonumber(f[10]), y = tonumber(f[11]) }, cargo = f[9], prog = {} }
			if f[8] and f[8] ~= "" then t.b = { name = f[8], x = tonumber(f[12]), y = tonumber(f[13]) } end
			if t.id then D.open[#D.open + 1] = t; byId[t.id] = t end
		elseif k == "prog" then
			local t = byId[tonumber(f[2])]
			if t then t.prog[#t.prog + 1] = { co = tonumber(f[3]), n = tonumber(f[4]) or 0 } end
		elseif k == "done" then
			local d = { id = tonumber(f[2]), kind = f[3], status = f[4], winner = tonumber(f[5]), prize = tonumber(f[6]) or 0,
				a = { name = f[7] }, cargo = f[9], why = f[10], goal = tonumber(f[11]) or 0 }
			if f[8] and f[8] ~= "" then d.b = { name = f[8] } end
			if d.id then D.done[#D.done + 1] = d end
		elseif k == "wins" then
			D.wins[#D.wins + 1] = { co = tonumber(f[2]), n = tonumber(f[3]) or 0 }
		end
	end
	return D
end

-- The tab's content as rows, whatever the window's widgets: { kind = "title" | "text" | "muted" | "progress" | "button", text,
-- tender, request, payload, co, value (0..1), mine }. A card per open tender: what, the bonus and the time left, every company
-- that started (this player's first, then the most carried), "Show" buttons; then the history and the tenders won.
function M.view(lines, T)
	local D = M.parse(lines)
	local rows = { { kind = "muted", text = M.say(T, "rule") } }
	local function name(id)
		local c = D.cos[id]
		local n = (c and c.name and c.name ~= "") and c.name or M.say(T, "company", tostring(id))
		return id == D.me and M.say(T, "you", n) or n
	end
	if #D.open == 0 then rows[#rows + 1] = { kind = "text", text = M.say(T, "none") } end
	for _, t in ipairs(D.open) do
		rows[#rows + 1] = { kind = "title", text = M.say(T, "number", t.id), tender = t.id }
		rows[#rows + 1] = { kind = "text", text = M.describe(t, T, t.cargo), tender = t.id }
		rows[#rows + 1] = { kind = "muted", tender = t.id, text = t.left > 1 and M.say(T, "prizeLeft", M.money(t.prize), t.left) or M.say(T, "lastMonth", M.money(t.prize)) }
		table.sort(t.prog, function(a, b)
			if (a.co == D.me) ~= (b.co == D.me) then return a.co == D.me end
			if a.n ~= b.n then return a.n > b.n end
			return a.co < b.co
		end)
		for _, p in ipairs(t.prog) do
			rows[#rows + 1] = { kind = "progress", tender = t.id, co = p.co, mine = p.co == D.me, value = t.goal > 0 and math.min(1, p.n / t.goal) or 0,
				text = M.say(T, "progress", name(p.co), p.n, t.goal) }
		end
		if #t.prog == 0 then rows[#rows + 1] = { kind = "muted", tender = t.id, text = M.say(T, "nobody") } end
		rows[#rows + 1] = { kind = "button", tender = t.id, text = M.say(T, "see", t.a.name), request = "focus", payload = t.id .. ":a", x = t.a.x, y = t.a.y }
		if t.b then rows[#rows + 1] = { kind = "button", tender = t.id, text = M.say(T, "see", t.b.name), request = "focus", payload = t.id .. ":b", x = t.b.x, y = t.b.y } end
	end
	if #D.done > 0 then
		rows[#rows + 1] = { kind = "title", text = M.say(T, "history") }
		for _, d in ipairs(D.done) do
			local what = M.describe(d, T, d.cargo)
			local text
			if d.status == "won" then text = M.say(T, "won", d.id, what, name(d.winner), M.money(d.prize))
			elseif d.status == "expired" then text = M.say(T, "expired", d.id, what)
			else text = M.say(T, "cancelled", d.id, what, d.why or "?") end
			rows[#rows + 1] = { kind = "muted", tender = d.id, text = text }
		end
	end
	if #D.wins > 0 then
		rows[#rows + 1] = { kind = "title", text = M.say(T, "winsTitle") }
		table.sort(D.wins, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.co < b.co end)
		for _, w in ipairs(D.wins) do rows[#rows + 1] = { kind = "text", co = w.co, text = M.say(T, "winsLine", name(w.co), w.n) } end
	end
	return rows
end

-- a progress as the window shows it: "Bob Co: 30 / 200  (15 %)"
local function percent(r)
	return r.text .. "  (" .. math.floor((tonumber(r.value) or 0) * 100 + 0.5) .. " %)"
end

-- The tab, with the window's helpers (U.featU: u.T, u.read, u.request, u.add and the widgets, each of which returns its node):
-- the rows of M.view put in the tab with u.add. A "Show" button moves this window's camera itself (the window's Lua state has
-- the camera, as its computer companies' journal), else asks the module on this game's interface half (u.request, M.request).
-- Returns nothing: every node is added.
-- (0.6) In the Hub (u.rich): each tender's card (its title starts it), every company's progress as a bar in its colour (this
-- player's in green), the « Show » buttons side by side.
function M.ui(u)
	local rows = M.view((u.read and u.read(M.FILE)) or {}, u.T)
	local add = u.add or function(n) return n end
	if u.rich and u.bar and u.row then
		local btns = nil
		local function flush() if btns then add(u.row(btns)); btns = nil end end
		for _, r in ipairs(rows) do
			if r.kind ~= "button" then flush() end
			if r.kind == "button" then
				btns = btns or {}
				btns[#btns + 1] = u.button(r.text, function()
					if not (r.x and r.y and W.focus({ x = r.x, y = r.y })) and u.request then u.request(r.request, r.payload) end
				end)
			elseif r.kind == "title" then add(u.title(r.text))
			elseif r.kind == "muted" then add(u.muted(r.text))
			elseif r.kind == "progress" then
				local colour = r.mine and "success" or ((u.coColor and u.coColor(r.co)) or r.co)
				add(u.bar(r.value, colour, math.floor((tonumber(r.value) or 0) * 100 + 0.5) .. " %", { lead = r.text, leadW = math.floor((tonumber(u.W) or 556) * 0.4),
					labelW = 60, leadCls = r.mine and "success" or nil }))
			else add(u.text(r.text)) end
		end
		flush()
		return
	end
	local lastTender = nil
	for _, r in ipairs(rows) do
		-- (a little space between two tenders' cards)
		if r.tender and r.tender ~= lastTender and lastTender ~= nil and u.gap and r.kind == "title" then add(u.gap(6)) end
		lastTender = r.tender or lastTender
		if r.kind == "button" then
			if u.button then
				add(u.button(r.text, function()
					if not (r.x and r.y and W.focus({ x = r.x, y = r.y })) and u.request then u.request(r.request, r.payload) end
				end))
			end
		elseif r.kind == "title" and u.title then
			add(u.title(r.text))
		elseif r.kind == "muted" and u.muted then
			add(u.muted(r.text))
		elseif r.kind == "progress" and u.text then
			add(u.text(percent(r), r.mine and "success" or nil))
		elseif u.text then
			add(u.text(r.text))
		end
	end
end

return M
