-- MPFever 0.6 game option "Competition" (market): each company's market shares per town, who serves each industry, and
-- competition alerts, in the "one company per player" mode. A feature module of the options host (mpfever_feat.lua; the
-- contract is docs/FEATURES-0.6.md, the research release/recherche-0.6/03-parts-de-marche.md with the owner's decisions C1
-- to C6 in 00-REPONSES.md).
--
-- What the players see, while the host has the option on (a tab "Competition" of the MPFever window):
--  - per town, each company's share of the passengers and of the cargo, in two columns (C1), and which company is first
--    there. The passengers are the 6-month average mpfever_progression.lua keeps for the rank (st.prog.passengers: people
--    on lines to, from and within the town); the cargo is what was delivered to the town in the last half year, by the
--    game's statistics per line and the line's owner, as the rank takes it (PG.measure). So the shares are the rank's own;
--  - per industry, only which companies serve it (C2): a company with a line that stops at a station whose catchment takes
--    the industry's goods;
--  - each company's totals, never the detail of a competitor's lines (C4);
--  - two alerts in the chat, without sound (C3): "a competitor arrives in a town where you are" (its first station there,
--    its own or one where its line stops) and "you lose first place in a town". The option's parameter "alerts" turns them
--    off.
--  Market shares are not a goal of the game (C6).
--
-- Who measures: the game reads several of these figures for its LOCAL player only, and an interface reads them at its own
-- time; so the host's game alone measures, in its GUI half (M.gui), once a game month (M.month marks it due), spread over a
-- few calls; it sends the figures in one event (f_market_snap) that every game applies at the same step (M.event). Every
-- player sees the same figures, the alerts are decided in the simulation half from the event only (the same on every
-- game), and the last measure is kept in the savegame. The simulation half never reads the engine here.
--
-- The state (st.feat.market, plain data, saved with the game):
--   due    = the game month the next measure is for (M.month)
--   month  = the game month of the measure applied (-1: the first one, taken before a month began)
--   towns  = { { town = entity, pop = residents, lead = the company first there (nil: nobody carries anything),
--                cos = { { co = company id, pa = passengers x 10, fr = cargo delivered, st = stations }, ... } }, ... }
--            (towns by entity, companies by id; only towns where a company is)
--   ind    = { { ind = entity, cos = { company id, ... } }, ... }   (industries by entity, served by a company at least)
--   alerts = { { n = number, kind = "arrive" or "lead", co = the company told, by = the other company, town = entity,
--                month = }, ... }   (the last M.KEEP_ALERTS)
--   seq    = the number of the last alert
-- Town and industry entities come from the savegame: their ids are the same on every game (not those of stations and lines,
-- which are never sent).
--
-- In game: every line of this module in mod.log starts with "feat market:" (the host's measure, its cost and, the first time,
-- what the game gave; each game's measure applied; the camera moved). The autotest MPFEVER_SCENARIO=markettest (the bridge's
-- H.markettest) switches the option on through the host's MPFever.exe and checks the measure, the file and the tab on both games.

local M = {}
M.ID = "market"

-- the texts, { French, English } (looked up by their English text in the other languages, as C.T does)
M.TEXT = {
	optTitle = { "Concurrence", "Competition" },
	optDesc = { "Parts de marché par ville (voyageurs et fret), qui dessert chaque industrie, et des alertes : un concurrent arrive dans votre ville, vous perdez la 1re place. Un onglet de la fenêtre MPFever.",
		"Market shares per town (passengers and cargo), who serves each industry, and alerts: a competitor arrives in your town, you lose first place. A tab of the MPFever window." },
	optAlerts = { "Alertes dans le chat", "Alerts in the chat" },
	yes = { "Oui", "Yes" },
	no = { "Non", "No" },
	tab = { "Concurrence", "Competition" },
	title = { "Parts de marché", "Market shares" },
	explain = { "Voyageurs : les gens transportés vers, depuis et dans la ville (moyenne sur 6 mois, celle du rang). Fret : les marchandises livrées à la ville sur 6 mois. Mesuré par l'hôte chaque mois de jeu.",
		"Passengers: people carried to, from and within the town (6-month average, the one of the rank). Cargo: goods delivered to the town over 6 months. Measured by the host every game month." },
	noMeasure = { "Pas encore de mesure : la première vient au début du prochain mois de jeu.", "No measure yet: the first one comes at the start of the next game month." },
	alone = { "Une seule entreprise joue : pas de concurrent, rien à mesurer.", "Only one company plays: no competitor, nothing to measure." },
	totals = { "Totaux des entreprises", "Companies' totals" },
	company = { "Entreprise", "Company" },
	passengers = { "Voyageurs", "Passengers" },
	cargo = { "Fret", "Cargo" },
	towns = { "Villes", "Towns" },
	industries = { "Industries", "Industries" },
	townsMine = { "Villes où vous êtes", "Towns where you are" },
	townsAll = { "Toutes les villes desservies", "All towns served" },
	showAll = { "Toutes les villes", "All towns" },
	showMine = { "Mes villes", "My towns" },
	townLine = { "%s (%s habitants), 1re place : %s", "%s (%s inhabitants), first place: %s" },
	townLineNoLead = { "%s (%s habitants)", "%s (%s inhabitants)" },
	share = { "%s : voyageurs %s, fret %s, %s gare(s)", "%s: passengers %s, cargo %s, %s station(s)" },
	more = { "... et %s autre(s)", "... and %s more" },
	indTitle = { "Industries : qui les dessert", "Industries: who serves them" },
	indLine = { "%s : %s", "%s: %s" },
	noIndustry = { "Aucune industrie desservie pour l'instant.", "No industry served yet." },
	noTown = { "Aucune ville desservie pour l'instant.", "No town served yet." },
	alertsTitle = { "Alertes récentes", "Recent alerts" },
	noAlert = { "Aucune alerte pour l'instant.", "No alert yet." },
	alertsOff = { "L'hôte a désactivé les alertes.", "The host turned the alerts off." },
	show = { "Voir", "Show" },
	you = { "(vous)", "(you)" },
	arrive = { "Concurrence : %s arrive à %s, une ville où vous êtes.", "Competition: %s arrives in %s, a town where you are." },
	lead = { "Concurrence : vous perdez la 1re place à %s, %s passe devant.", "Competition: you lose first place in %s, %s takes the lead." },
	moreAlerts = { "Concurrence : %s autre(s) alerte(s) dans l'onglet Concurrence de la fenêtre MPFever.", "Competition: %s more alert(s) in the Competition tab of the MPFever window." },
}

-- an option's yes-or-no parameter, in whatever form the options host gives it (1, "1", true)
function M.flag(v)
	return v == true or v == 1 or v == "1" or v == "on" or v == "yes"
end

M.OPTIONS = {
	{ id = "market",
		title = M.TEXT.optTitle,
		desc = M.TEXT.optDesc,
		modes = "separate",
		params = {
			{ id = "alerts", label = M.TEXT.optAlerts, values = { 1, 0 }, default = 1,
				show = function(v, T) local L = M.flag(v) and M.TEXT.yes or M.TEXT.no; return T(L[1], L[2]) end },
		} },
}
M.EVENTS = { f_market_snap = true }
M.TAB = { id = "market", title = M.TEXT.tab }

M.FILE = "shares"            -- the window's file, feat_market_shares.txt of the session folder (env.write, u.read)
M.LEAD_MARGIN = 0.02         -- another company takes first place only when its share passes the first's by this much
M.MAX_TOWNS = 300            -- towns sent in one measure at most (the most populated)
M.MAX_INDUSTRIES = 400
M.MAX_NEW_ALERTS = 30        -- alerts kept from one measure at most
M.KEEP_ALERTS = 40
M.CHAT_MAX = 3               -- alerts told in the chat at once, the rest in one line
M.RESEND_S = 30              -- a measure sent and not applied (a resynchronisation drops events) goes again after this
M.FILE_EVERY_S = 30          -- the window's file is written again at least this often (names may change)
M.BUDGET = { lines = 60, towns = 8, groups = 20 }   -- items of the host's measure per call of M.gui (about once a second)
M.BUDGET_S = 0.010           -- and no more time than this per call (one item at least)
M.UI_TOWNS = 25              -- towns shown in the tab
M.UI_INDUSTRIES = 30
M.UI_ALERTS = 10

-- ---------------------------------------------------------------------------------------------------- texts

-- C.T of mpfever_common.lua (this game's language), loaded when first needed: never at load time (the lobby and the tests
-- load this module without the game)
function M.common()
	if M._C == nil then
		local ok, C = pcall(ug_require, "mpfever_common.lua")
		if not (ok and type(C) == "table") then ok, C = pcall(ug_require, "mpfever_1::/mpfever_common.lua") end
		M._C = (ok and type(C) == "table") and C or false
	end
	return M._C or nil
end

function M.T(fr, en)
	local C = M.common()
	if C and C.T then return C.T(fr, en) end
	return en
end

-- a text of M.TEXT with %s, each taking the next value (put in with gsub: a name may contain % itself)
function M.say(T, key, ...)
	local pair = M.TEXT[key]
	local values, i = { ... }, 0
	local s = (T or M.T)(pair[1], pair[2]):gsub("%%s", function() i = i + 1; return tostring(values[i]) end)
	return s
end

-- 12 345 678 (as the companies' money is written in the chat)
function M.thousands(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", ""):gsub("^%- ", "-"))
end

-- per mille -> "45 %" ("-": nobody carries that kind there)
function M.pct(pm)
	if type(pm) ~= "number" or pm < 0 then return "-" end
	return string.format("%d %%", math.floor(pm / 10 + 0.5))
end

local function clean(s) return (tostring(s or ""):gsub("[%c]", " ")) end

-- ---------------------------------------------------------------------------------------------------- the companies

-- the companies that play, by id: { id, ent, ai }. From env.companies() (simulation half) or the registry st.co.list (the
-- GUI's view); a company gone (bankrupt, merged) or without its player entity yet is none. (A lookup table only: never
-- walked with pairs where the order counts)
function M.companies(list)
	local live = {}
	for _, c in ipairs(type(list) == "table" and list or {}) do
		if type(c) == "table" and type(c.id) == "number" and not c.gone and type(c.ent) == "number" and c.ent >= 0 then
			local ai = c.ai
			if ai == nil then ai = tostring(c.key or ""):sub(1, 3) == "ai:" end
			live[c.id] = { id = c.id, ent = c.ent, ai = ai and true or false }
		end
	end
	return live
end

-- the option is on, in the "one company per player" mode (env.mode; the GUI's env may not have it: the registry says)
function M.active(st, env)
	if not (env and env.on and env.on("market")) then return false end
	local mode = env.mode
	if mode == nil and type(st) == "table" and type(st.co) == "table" then mode = st.co.mode end
	return mode == "separate"
end

function M.alertsOn(env)
	local v = env.param and env.param("market", "alerts")
	if v == nil then return true end
	return M.flag(v)
end

-- ---------------------------------------------------------------------------------------------------- shares and first place

-- each company's share of a town's passengers and of its cargo (0 to 1; nil for a kind nobody carries there), and the two
-- mixed as the rank mixes them (PG.share, weights 1 and 1). Pure: the same numbers on every game
function M.shares(t)
	local paAll, frAll = 0, 0
	for _, c in ipairs(t.cos) do paAll = paAll + c.pa; frAll = frAll + c.fr end
	local out = {}
	for _, c in ipairs(t.cos) do
		local pa = paAll > 0 and c.pa / paAll or nil
		local fr = frAll > 0 and c.fr / frAll or nil
		local mix = 0
		if pa and fr then mix = (pa + fr) / 2 elseif pa then mix = pa elseif fr then mix = fr end
		out[#out + 1] = { co = c.co, pa = pa, fr = fr, mix = mix }
	end
	return out, paAll, frAll
end

-- the company first in a town: the best mixed share (the lowest id on a tie: the companies are in id order); the one first
-- before stays first unless another passes it by more than M.LEAD_MARGIN (two companies close to each other would swap the
-- place, and the alert, every month). nil when nobody carries anything there
function M.leader(t, prev, live)
	local sh = M.shares(t)
	local best, bestMix = nil, 0
	for _, s in ipairs(sh) do
		if s.mix > bestMix then best, bestMix = s.co, s.mix end
	end
	if best == nil then return nil end
	if prev ~= nil and prev ~= best and live[prev] then
		for _, s in ipairs(sh) do
			if s.co == prev and s.mix > 0 and s.mix + M.LEAD_MARGIN >= bestMix then return prev end
		end
	end
	return best
end

-- ---------------------------------------------------------------------------------------------------- the event (every game)

-- the event's towns, "town,pop,co:pa:fr:st,co:pa:fr:st;town,..." -> records of the companies that play, towns by entity and
-- companies by id; anything malformed is left out
function M.decodeTowns(s, live)
	local towns, seen = {}, {}
	if type(s) ~= "string" then return towns end
	for part in s:gmatch("[^;]+") do
		local fields = {}
		for f in part:gmatch("[^,]+") do fields[#fields + 1] = f end
		local town, pop = tonumber(fields[1]), tonumber(fields[2])
		if town and pop and town >= 0 and town == math.floor(town) and not seen[town] then
			local cos, have = {}, {}
			for k = 3, #fields do
				local co, pa, fr, n = fields[k]:match("^(%d+):(%d+):(%d+):(%d+)$")
				co, pa, fr, n = tonumber(co), tonumber(pa), tonumber(fr), tonumber(n)
				if co and live[co] and not have[co] and (pa > 0 or fr > 0 or n > 0) then
					have[co] = true
					cos[#cos + 1] = { co = co, pa = pa, fr = fr, st = n }
				end
			end
			if #cos > 0 then
				seen[town] = true
				table.sort(cos, function(a, b) return a.co < b.co end)
				towns[#towns + 1] = { town = town, pop = math.max(0, math.floor(pop)), cos = cos }
			end
		end
	end
	table.sort(towns, function(a, b) return a.town < b.town end)
	while #towns > M.MAX_TOWNS do table.remove(towns) end
	return towns
end

-- the event's industries, "ind:co.co;ind:co" -> records, industries by entity and companies by id
function M.decodeIndustries(s, live)
	local out, seen = {}, {}
	if type(s) ~= "string" then return out end
	for part in s:gmatch("[^;]+") do
		local e, list = part:match("^(%d+):([%d%.]+)$")
		e = tonumber(e)
		if e and not seen[e] then
			local cos, have = {}, {}
			for x in list:gmatch("%d+") do
				local co = tonumber(x)
				if live[co] and not have[co] then have[co] = true; cos[#cos + 1] = co end
			end
			if #cos > 0 then
				seen[e] = true
				table.sort(cos)
				out[#out + 1] = { ind = e, cos = cos }
			end
		end
	end
	table.sort(out, function(a, b) return a.ind < b.ind end)
	while #out > M.MAX_INDUSTRIES do table.remove(out) end
	return out
end

-- a measure into the state: the first place in each town, and the alerts against the measure before (none for the first
-- measure: it is the reference). Returns the number of new alerts. Pure, in a fixed order: the same on every game
function M.apply(S, month, towns, inds, live, alertsOn)
	local first = S.month == nil
	local before = {}
	for _, t in ipairs(type(S.towns) == "table" and S.towns or {}) do before[t.town] = t end
	local new = {}
	for _, t in ipairs(towns) do
		local old = before[t.town]
		t.lead = M.leader(t, old and old.lead, live)
		if alertsOn and not first then
			-- "a competitor arrives in a town where you are": its first station there (its own, or one where its line stops),
			-- told to each company that had a station there and still has one; never to a computer company
			local was, now = {}, {}
			for _, c in ipairs(old and old.cos or {}) do if (c.st or 0) > 0 then was[c.co] = true end end
			for _, c in ipairs(t.cos) do if c.st > 0 then now[c.co] = true end end
			for _, x in ipairs(t.cos) do
				if now[x.co] and not was[x.co] then
					for _, y in ipairs(t.cos) do
						if y.co ~= x.co and was[y.co] and now[y.co] and live[y.co] and not live[y.co].ai then
							new[#new + 1] = { kind = "arrive", co = y.co, by = x.co, town = t.town }
						end
					end
				end
			end
			-- "you lose first place": told to the company first there before, when another one is first now
			local l0 = old and old.lead
			if l0 ~= nil and t.lead ~= nil and t.lead ~= l0 and live[l0] and not live[l0].ai then
				new[#new + 1] = { kind = "lead", co = l0, by = t.lead, town = t.town }
			end
		end
	end
	S.v = 1
	S.towns, S.ind, S.month = towns, inds, month
	if type(S.alerts) ~= "table" then S.alerts = {} end
	S.seq = tonumber(S.seq) or 0
	local kept = math.min(#new, M.MAX_NEW_ALERTS)
	for k = 1, kept do
		local a = new[k]
		S.seq = S.seq + 1
		a.n, a.month = S.seq, month
		S.alerts[#S.alerts + 1] = a
	end
	while #S.alerts > M.KEEP_ALERTS do table.remove(S.alerts, 1) end
	return kept
end

-- SIMULATION half: a new game month, a new measure is due (the host's game takes it, see M.gui)
function M.month(st, env)
	if not M.active(st, env) then return end
	local m = env.month and env.month()
	if type(m) ~= "number" then return end
	local S = env.state(st)
	S.due = m
end

-- SIMULATION half: the host's measure, applied by every game at the same step. A measure of a month already applied (sent
-- again after a loss) or older is left out
function M.event(st, name, param, env)
	if name ~= "f_market_snap" or type(param) ~= "table" or not M.active(st, env) then return end
	-- (only the host's game measures: a measure from a player who joined, whose name has "#n" after it, is left out. The
	-- sender is in the event itself, the same on every game)
	if type(param.mpfFrom) == "string" and param.mpfFrom:find("#", 1, true) then
		if env.log then env.log("feat market: a measure from " .. param.mpfFrom .. " left out (only the host's game measures)") end
		return
	end
	local month = tonumber(param.month)
	-- (a game month is year x 12 + month, -1 the first measure: a wild number would leave every later measure out)
	if month == nil or month ~= math.floor(month) or month < -1 or month > 1e6 then return end
	local S = env.state(st)
	if S.month ~= nil and month <= S.month then return end
	local live = M.companies(env.companies and env.companies() or (type(st.co) == "table" and st.co.list))
	local towns = M.decodeTowns(param.t, live)
	local inds = M.decodeIndustries(param.i, live)
	local n = M.apply(S, month, towns, inds, live, M.alertsOn(env))
	if env.log then env.log("feat market: measure of month " .. month .. " applied: " .. #towns .. " town(s), " .. #inds .. " industry(ies), " .. n .. " alert(s), alert number " .. tostring(S.seq)) end
end

-- ---------------------------------------------------------------------------------------------------- the engine (host's GUI)

-- What the host's measure reads from the game, one function each: the tests and the integration may replace any of them.
-- All are called in the GUI half of the host's game only, under pcall, and give empty answers when the game refuses.
M.engine = {}
local E = M.engine

function M.refs()
	if M._R == nil then
		local ok, R = pcall(ug_require, "mpfever_refs.lua")
		if not (ok and type(R) == "table") then ok, R = pcall(ug_require, "mpfever_1::/mpfever_refs.lua") end
		M._R = (ok and type(R) == "table") and R or false
	end
	return M._R or nil
end

-- the player entity that owns an entity (a line, a station: R.ownerOf also looks at a station's construction)
function E.ownerOf(e)
	if type(e) ~= "number" or e < 0 then return nil end
	local R = M.refs()
	if R and R.ownerOf then
		local ok, o = pcall(R.ownerOf, e)
		if ok then return o end
	end
	local ok, o = pcall(function()
		local c = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
		return c and c.player
	end)
	if ok and type(o) == "number" and o >= 0 then return o end
	return nil
end

-- the lines, by entity
function E.lines()
	local out = {}
	pcall(function() local l = api.engine.system.lineSystem.getLines(); for i = 1, #l do out[#out + 1] = l[i] end end)
	table.sort(out)
	return out
end

-- the station groups a line stops at
function E.lineGroups(line)
	local out = {}
	pcall(function()
		local l = api.engine.getComponent(line, api.type.ComponentType.LINE)
		for i = 1, #l.stops do
			local sg = l.stops[i].stationGroup
			if type(sg) == "number" and sg >= 0 then out[#out + 1] = sg end
		end
	end)
	return out
end

-- the towns with their residents, by entity (as PG.measure: getTown2personCapacitiesMap, the first number)
function E.towns()
	local out = {}
	pcall(function()
		for town, c in pairs(api.engine.system.townBuildingSystem.getTown2personCapacitiesMap()) do
			local okP, p = pcall(function() return c[1] end)
			out[#out + 1] = { town = town, pop = (okP and tonumber(p)) or 0 }
		end
	end)
	table.sort(out, function(a, b) return a.town < b.town end)
	return out
end

-- town -> its stations (the engine's own attachment of a station to a town)
function E.townStations()
	local out = {}
	pcall(function()
		for town, list in pairs(api.engine.system.stationSystem.getTown2StationsMap()) do
			local l = {}
			for i = 1, #list do l[#l + 1] = list[i] end
			out[town] = l
		end
	end)
	return out
end

function E.halfYear()
	local ok, y = pcall(function() return api.util.getDefaultYearDuration() end)
	return math.floor(((ok and tonumber(y)) or 0) / 2 + 0.5)
end

-- the cargo a line delivered (one line's entry of getTownDeliveriesStats: { cargo type: { late, total } }, the type -1 for
-- all of them when asked so), as PG.measure counts it
function M.delivered(byCargo)
	-- (how the game gives it, counted for the first measure's log line: see M.diagnose)
	local shape = M.mem.shape
	if type(byCargo) ~= "table" then
		if shape then shape.other = shape.other + 1 end
		return 0
	end
	local all = byCargo[-1]
	if shape then if type(all) == "table" then shape.all = shape.all + 1 else shape.cargo = shape.cargo + 1 end end
	if type(all) == "table" then return tonumber(all[2]) or 0 end
	local n = 0
	for _, pair in pairs(byCargo) do
		if type(pair) == "table" then n = n + (tonumber(pair[2]) or 0) end
	end
	return n
end

-- line -> the cargo it delivered to the town over the interval
function E.deliveries(town, interval)
	local out = {}
	pcall(function()
		for line, byCargo in pairs(api.engine.util.town.getTownDeliveriesStats(town, interval, true, false) or {}) do
			if type(line) == "number" and line >= 0 then out[line] = M.delivered(byCargo) end
		end
	end)
	return out
end

function E.stationGroup(station)
	local ok, sg = pcall(function() return api.engine.system.stationGroupSystem.getStationGroup(station) end)
	if ok and type(sg) == "number" and sg >= 0 then return sg end
	return nil
end

function E.groupStations(sg)
	local out = {}
	pcall(function()
		local g = api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP)
		for i = 1, #g.stations do
			local s = g.stations[i]
			if type(s) == "number" and s >= 0 then out[#out + 1] = s end
		end
	end)
	return out
end

-- the stock lists a station's catchment takes cargo from (industries', town buildings', warehouses')
function E.catchables(station)
	local out = {}
	pcall(function()
		local c = api.engine.system.catchmentAreaSystem.getStationCatchables(station, true)
		for i = 1, #c do out[#out + 1] = c[i] end
	end)
	return out
end

-- the industries with their stock list, by entity
function E.industries()
	local list = {}
	local R = M.refs()
	if R and R.entitiesWith then
		local ok, l = pcall(R.entitiesWith, "INDUSTRY")
		if ok and type(l) == "table" then list = l end
	else
		pcall(function() api.engine.forEachEntityWithComponent(function(e) list[#list + 1] = e end, api.type.ComponentType.INDUSTRY) end)
	end
	local out = {}
	for _, e in ipairs(list) do
		pcall(function()
			local ind = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY)
			if ind and type(ind.stockList) == "number" and ind.stockList >= 0 then out[#out + 1] = { ind = e, stockList = ind.stockList } end
		end)
	end
	table.sort(out, function(a, b) return a.ind < b.ind end)
	return out
end

-- a town's or an industry's name, as the game's own windows write it
function E.name(e)
	local n = nil
	pcall(function() n = api.engine.util.getEntityName(e) end)
	if type(n) ~= "string" or n == "" then
		pcall(function() n = api.engine.getComponent(e, api.type.ComponentType.NAME).name end)
	end
	if type(n) == "string" and n ~= "" then return n end
	return "#" .. tostring(e)
end

-- a company's name as the players see it (as G.coName: the game's, then the registry's)
function E.companyName(c)
	local n = nil
	pcall(function() n = api.engine.getComponent(c.ent, api.type.ComponentType.NAME).name end)
	if type(n) == "string" and n ~= "" then return n end
	if type(c.name) == "string" and c.name ~= "" then return c.name end
	return "#" .. tostring(c.id)
end

-- the camera over a town (its residential centre; else the town entity itself)
function E.focusTown(town)
	local ok = pcall(function()
		local p = api.engine.util.town.getTownDistrictCenter(town, api.type.enum.LandUseType.RESIDENTIAL)
		-- (a town without a residential district: the game may give the map's origin, not the town)
		if not p or (p.x == 0 and p.y == 0) then error("no residential centre") end
		api.gui.camera.focusPosition(p, 1000)
	end)
	if not ok then ok = pcall(function() api.gui.camera.focusEntity(town) end) end
	return ok
end

-- ---------------------------------------------------------------------------------------------------- the host's measure

-- this game's interface memory (not game state): the host's measure under way, the measure sent, the alerts told, the file
M.mem = {}

-- a new measure for `month`: the companies that play now (by their player entity)
function M.newPass(month, st)
	local live = M.companies(type(st.co) == "table" and st.co.list)
	local byEnt = {}
	for _, c in ipairs(type(st.co) == "table" and st.co.list or {}) do
		local x = type(c) == "table" and live[c.id]
		if x then byEnt[x.ent] = x.id end
	end
	-- (the first measure of this game counts what the game gave, for its log line: see M.diagnose)
	if not M.mem.diagDone and not M.mem.shape then M.mem.shape = { all = 0, cargo = 0, other = 0 } end
	return { month = month, phase = "lines", i = 0, live = live, byEnt = byEnt, owner = {}, groups = {}, towns = {},
		calls = 0, ms = 0, coLines = 0, withStations = 0, withCargo = 0 }
end

-- the company owning an entity, in this measure (owners read once each)
local function companyOf(pass, e)
	local x = pass.owner[e]
	if x == nil then
		local o = E.ownerOf(e)
		x = (o and pass.byEnt[o]) or false
		pass.owner[e] = x
	end
	return x or nil
end

-- one call's share of the measure: the lines (which company stops at which station group), then the towns (cargo per
-- line's owner, stations per company), then the stations' catchments (who serves each industry). Returns true when done
function M.step(pass, env)
	local clock = env.realTime or function() return 0 end
	local t0 = clock()
	local function more(k, budget) return k < budget and (k == 0 or clock() - t0 <= M.BUDGET_S) end
	if pass.phase == "lines" then
		pass.list = pass.list or E.lines()
		local k = 0
		while pass.i < #pass.list and more(k, M.BUDGET.lines) do
			pass.i, k = pass.i + 1, k + 1
			local line = pass.list[pass.i]
			local co = companyOf(pass, line)
			if co then
				pass.coLines = pass.coLines + 1
				for _, sg in ipairs(E.lineGroups(line)) do
					pass.groups[sg] = pass.groups[sg] or {}
					pass.groups[sg][co] = true
				end
			end
		end
		if pass.i >= #pass.list then pass.phase, pass.i, pass.list = "towns", 0, nil end
		return false
	end
	if pass.phase == "towns" then
		if not pass.list then pass.list, pass.t2s, pass.half = E.towns(), E.townStations(), E.halfYear() end
		local k = 0
		while pass.i < #pass.list and more(k, M.BUDGET.towns) do
			pass.i, k = pass.i + 1, k + 1
			local t = pass.list[pass.i]
			local rec = { town = t.town, pop = t.pop, fr = {}, st = {} }
			for line, n in pairs(E.deliveries(t.town, pass.half)) do
				local co = companyOf(pass, line)
				if co and n > 0 then rec.fr[co] = (rec.fr[co] or 0) + n end
			end
			for _, s in ipairs(pass.t2s[t.town] or {}) do
				local here = {}
				local o = companyOf(pass, s)
				if o then here[o] = true end
				local sg = E.stationGroup(s)
				for co in pairs(sg and pass.groups[sg] or {}) do here[co] = true end
				for co in pairs(here) do rec.st[co] = (rec.st[co] or 0) + 1 end
			end
			if next(rec.st) ~= nil then pass.withStations = pass.withStations + 1 end
			if next(rec.fr) ~= nil then pass.withCargo = pass.withCargo + 1 end
			pass.towns[#pass.towns + 1] = rec
		end
		if pass.i >= #pass.list then pass.phase, pass.i, pass.list = "industries", 0, nil end
		return false
	end
	if pass.phase == "industries" then
		if not pass.list then
			pass.list, pass.sl = {}, {}
			for sg in pairs(pass.groups) do pass.list[#pass.list + 1] = sg end
			table.sort(pass.list)
		end
		local k = 0
		while pass.i < #pass.list and more(k, M.BUDGET.groups) do
			pass.i, k = pass.i + 1, k + 1
			local sg = pass.list[pass.i]
			for _, s in ipairs(E.groupStations(sg)) do
				for _, sl in ipairs(E.catchables(s)) do
					pass.sl[sl] = pass.sl[sl] or {}
					for co in pairs(pass.groups[sg]) do pass.sl[sl][co] = true end
				end
			end
		end
		if pass.i >= #pass.list then
			pass.inds = {}
			pass.nGroups, pass.nStock, pass.nInd = #pass.list, 0, 0
			for _ in pairs(pass.sl) do pass.nStock = pass.nStock + 1 end
			-- (no station of a company takes anything: the industries are not listed)
			for _, it in ipairs(next(pass.sl) ~= nil and E.industries() or {}) do
				pass.nInd = pass.nInd + 1
				local x = pass.sl[it.stockList]
				if x then
					local cos = {}
					for co in pairs(x) do cos[#cos + 1] = co end
					table.sort(cos)
					pass.inds[#pass.inds + 1] = { ind = it.ind, cos = cos }
				end
			end
			pass.phase = "done"
		end
	end
	return pass.phase == "done"
end

local function int(n) return string.format("%d", math.floor(n)) end

-- the measure as the event's parameter (whole numbers in two strings: the same on every game whatever its float printing).
-- The passengers are the rank's 6-month average of the host's state (st.prog.passengers), in tenths
function M.encode(pass, st)
	local pa = {}
	local prog = type(st.prog) == "table" and st.prog or {}
	for _, e in ipairs(type(prog.passengers) == "table" and prog.passengers or {}) do
		local co, town, v = tonumber(e.company), tonumber(e.town), tonumber(e.value)
		if co and town and v and pass.live[co] then
			local n = math.floor(v * 10 + 0.5)
			if n > 0 then pa[town] = pa[town] or {}; pa[town][co] = n end
		end
	end
	local rows = {}
	for _, t in ipairs(pass.towns) do
		local ids, seen = {}, {}
		local function add(co) if not seen[co] then seen[co] = true; ids[#ids + 1] = co end end
		for co in pairs(t.fr) do add(co) end
		for co in pairs(t.st) do add(co) end
		for co in pairs(pa[t.town] or {}) do add(co) end
		table.sort(ids)
		local parts = {}
		for _, co in ipairs(ids) do
			local p, f, s = (pa[t.town] or {})[co] or 0, math.floor((t.fr[co] or 0) + 0.5), t.st[co] or 0
			if p > 0 or f > 0 or s > 0 then parts[#parts + 1] = int(co) .. ":" .. int(p) .. ":" .. int(f) .. ":" .. int(s) end
		end
		if #parts > 0 then rows[#rows + 1] = { town = t.town, pop = t.pop or 0, s = int(t.town) .. "," .. int(math.max(0, t.pop or 0)) .. "," .. table.concat(parts, ",") } end
	end
	-- (too many towns: the most populated)
	if #rows > M.MAX_TOWNS then
		table.sort(rows, function(a, b) if a.pop ~= b.pop then return a.pop > b.pop end return a.town < b.town end)
		while #rows > M.MAX_TOWNS do table.remove(rows) end
		table.sort(rows, function(a, b) return a.town < b.town end)
	end
	local ts = {}
	for _, r in ipairs(rows) do ts[#ts + 1] = r.s end
	local is = {}
	for _, x in ipairs(pass.inds or {}) do
		if #is >= M.MAX_INDUSTRIES then break end
		local cos = {}
		for _, co in ipairs(x.cos) do cos[#cos + 1] = int(co) end
		is[#is + 1] = int(x.ind) .. ":" .. table.concat(cos, ".")
	end
	return { month = pass.month, t = table.concat(ts, ";"), i = table.concat(is, ";") }
end

-- the host's game: a measure when one is due (the state's due month, or the first one), sent once done; sent again when
-- it did not arrive. The measure under way is finished even when the next month is already due (else a big map at a high
-- speed would never finish one): the next one follows
function M.hostTick(st, S, env)
	local mem = M.mem
	local now = env.realTime and env.realTime() or 0
	local want = (S and S.due) or -1
	if S and S.month ~= nil and want <= S.month then mem.pass = nil; return end
	local live = M.companies(type(st.co) == "table" and st.co.list)
	local n = 0
	for _, c in ipairs(type(st.co) == "table" and st.co.list or {}) do if type(c) == "table" and live[c.id] then n = n + 1 end end
	-- (one company: no competitor, nothing to measure)
	if n < 2 then
		mem.pass = nil
		if not mem.aloneSaid and env.log then env.log("feat market: one company plays: nothing measured until another one comes") end
		mem.aloneSaid = true
		return
	end
	mem.aloneSaid = nil
	if mem.sent and mem.sent.month == want and not mem.pass then
		if now - mem.sent.at < M.RESEND_S then return end
		mem.sent.at = now
		env.send("f_market_snap", mem.sent.param)
		if env.log then env.log("feat market: the measure of month " .. want .. " sent again (not applied after " .. M.RESEND_S .. " s)") end
		return
	end
	if not mem.pass then mem.pass = M.newPass(want, st) end
	local pass = mem.pass
	local done = M.step(pass, env)
	pass.calls = pass.calls + 1
	pass.ms = pass.ms + math.max(0, ((env.realTime and env.realTime() or now) - now) * 1000)
	if done then
		local p = M.encode(pass, st)
		mem.sent = { month = pass.month, at = now, param = p }
		mem.pass = nil
		env.send("f_market_snap", p)
		M.diagnose(pass, p, st, env)
	end
end

-- The host's log lines of a measure (what the in-game test checks): every measure its size and cost; the first one of this
-- game also what the game gave (lines of companies, towns with their stations and cargo, the deliveries' form per line,
-- station groups and the stock lists their catchments take, the industries those match, the rank's passenger entries)
function M.diagnose(pass, p, st, env)
	if not env.log then return end
	local nTowns, nInds = 0, 0
	if p.t ~= "" then nTowns = select(2, p.t:gsub(";", ";")) + 1 end
	if p.i ~= "" then nInds = select(2, p.i:gsub(";", ";")) + 1 end
	env.log(string.format("feat market: measure of month %s sent: %d town(s), %d industry(ies), %d characters, %d call(s), %d ms",
		tostring(p.month), nTowns, nInds, #p.t + #p.i, pass.calls, math.floor(pass.ms + 0.5)))
	local mem = M.mem
	if mem.diagDone then return end
	mem.diagDone = true
	local shape = mem.shape or { all = 0, cargo = 0, other = 0 }
	mem.shape = nil
	local nPa = 0
	local prog = type(st.prog) == "table" and st.prog or {}
	for _ in ipairs(type(prog.passengers) == "table" and prog.passengers or {}) do nPa = nPa + 1 end
	env.log(string.format("feat market: first measure: %d line(s) of the companies, %d town(s) (%d with a company's station, %d with its cargo delivered), "
		.. "deliveries per line %d with the total (-1), %d per cargo, %d of another form; %d station group(s) of the lines take %d stock list(s), "
		.. "%d industry(ies) looked at, %d served; %d passenger entries of the rank",
		pass.coLines, #pass.towns, pass.withStations, pass.withCargo, shape.all, shape.cargo, shape.other,
		pass.nGroups or 0, pass.nStock or 0, pass.nInd or 0, #(pass.inds or {}), nPa))
end

-- ---------------------------------------------------------------------------------------------------- every game's GUI

-- the names this game shows (read here, kept a minute)
function M.names(env)
	local mem = M.mem
	local now = env.realTime and env.realTime() or 0
	if not mem.names or now - (mem.namesAt or -1e9) > 60 then mem.names, mem.namesAt = {}, now end
	return function(e)
		local n = mem.names[e]
		if n == nil then n = E.name(e); mem.names[e] = n end
		return n
	end
end

function M.companyNames(st)
	local out = {}
	for _, c in ipairs(type(st.co) == "table" and st.co.list or {}) do
		if type(c) == "table" and type(c.id) == "number" then out[c.id] = E.companyName(c) end
	end
	return out
end

-- what an alert says, in this game's language
function M.alertText(T, a, coName, townName)
	if a.kind == "lead" then return M.say(T, "lead", townName(a.town), coName(a.by)) end
	return M.say(T, "arrive", coName(a.by), townName(a.town))
end

-- the alerts for this player's company told in the chat; the ones there when this game loaded (a resynchronisation's
-- reload too) are not told again
function M.tell(st, S, env)
	local mem = M.mem
	local seq = (S and tonumber(S.seq)) or 0
	if mem.seen == nil then mem.seen = seq; return end
	if seq <= mem.seen then return end
	local mine = {}
	for _, a in ipairs(S and type(S.alerts) == "table" and S.alerts or {}) do
		if type(a) == "table" and (tonumber(a.n) or 0) > mem.seen and env.myCo ~= nil and a.co == env.myCo then mine[#mine + 1] = a end
	end
	mem.seen = seq
	if #mine == 0 or not M.alertsOn(env) or not env.chat then return end
	local T = env.T or M.T
	local cn = M.companyNames(st)
	local function coName(id) return cn[id] or ("#" .. tostring(id)) end
	local townName = M.names(env)
	for k = 1, math.min(#mine, M.CHAT_MAX) do env.chat(M.alertText(T, mine[k], coName, townName)) end
	if #mine > M.CHAT_MAX then env.chat(M.say(T, "moreAlerts", #mine - M.CHAT_MAX)) end
end

-- the window's file (see M.parseFile): the measure as this player sees it. Every game writes its own (its company, its
-- language's names); the figures are the state's, the same everywhere
function M.fileLines(st, S, env)
	local me = env.myCo or 0
	local live = M.companies(type(st.co) == "table" and st.co.list)
	local cn = M.companyNames(st)
	local name = M.names(env)
	local L = { "v\t1", "me\t" .. tostring(me), "alerts\t" .. (M.alertsOn(env) and "1" or "0") }
	local nLive = 0
	for _ in pairs(live) do nLive = nLive + 1 end
	if nLive < 2 then L[#L + 1] = "alone\t1" end
	if not (S and S.month ~= nil) then return L end
	L[#L + 1] = "month\t" .. tostring(S.month)
	local ids = {}
	for _, c in ipairs(type(st.co) == "table" and st.co.list or {}) do
		if type(c) == "table" and live[c.id] then ids[#ids + 1] = c.id end
	end
	table.sort(ids)
	for _, id in ipairs(ids) do L[#L + 1] = "co\t" .. id .. "\t" .. (live[id].ai and "1" or "0") .. "\t" .. clean(cn[id]) end
	-- each company's totals: its share of all the passengers and of all the cargo, the towns where it is, the industries
	local paAll, frAll, pa, fr, towns, inds = 0, 0, {}, {}, {}, {}
	local rows = {}
	for _, t in ipairs(type(S.towns) == "table" and S.towns or {}) do
		local sh, tpa, tfr = M.shares(t)
		paAll, frAll = paAll + tpa, frAll + tfr
		rows[#rows + 1] = "town\t" .. t.town .. "\t" .. math.floor(t.pop or 0) .. "\t" .. tostring(t.lead or 0) .. "\t" .. clean(name(t.town))
		for k, c in ipairs(t.cos) do
			pa[c.co], fr[c.co] = (pa[c.co] or 0) + c.pa, (fr[c.co] or 0) + c.fr
			towns[c.co] = (towns[c.co] or 0) + 1
			if live[c.co] then
				local s = sh[k]
				rows[#rows + 1] = "tp\t" .. t.town .. "\t" .. c.co .. "\t" .. (s.pa and math.floor(s.pa * 1000 + 0.5) or -1) .. "\t"
					.. (s.fr and math.floor(s.fr * 1000 + 0.5) or -1) .. "\t" .. c.st
			end
		end
	end
	for _, x in ipairs(type(S.ind) == "table" and S.ind or {}) do
		local cos = {}
		for _, co in ipairs(x.cos) do
			inds[co] = (inds[co] or 0) + 1
			if live[co] then cos[#cos + 1] = co end
		end
		if #cos > 0 then rows[#rows + 1] = "ind\t" .. x.ind .. "\t" .. table.concat(cos, ",") .. "\t" .. clean(name(x.ind)) end
	end
	for _, id in ipairs(ids) do
		L[#L + 1] = "tot\t" .. id .. "\t" .. (paAll > 0 and math.floor((pa[id] or 0) * 1000 / paAll + 0.5) or -1) .. "\t"
			.. (frAll > 0 and math.floor((fr[id] or 0) * 1000 / frAll + 0.5) or -1) .. "\t" .. (towns[id] or 0) .. "\t" .. (inds[id] or 0)
	end
	for _, r in ipairs(rows) do L[#L + 1] = r end
	-- this company's last alerts, the newest first
	local alerts = type(S.alerts) == "table" and S.alerts or {}
	local n = 0
	for k = #alerts, 1, -1 do
		local a = alerts[k]
		if n >= M.UI_ALERTS then break end
		if type(a) == "table" and a.co == me and me ~= 0 then
			n = n + 1
			L[#L + 1] = "alert\t" .. tostring(a.n) .. "\t" .. tostring(a.kind) .. "\t" .. tostring(a.by) .. "\t" .. tostring(a.town) .. "\t" .. clean(name(a.town))
		end
	end
	return L
end

-- GUI half, every game, about once a second: the host measures; every game tells its alerts and writes the window's file
function M.gui(st, env)
	if type(st) ~= "table" or not M.active(st, env) then return end
	local S = type(st.feat) == "table" and st.feat.market or nil   -- (read only here)
	if env.isHost then
		local ok, err = pcall(M.hostTick, st, S, env)
		if not ok then
			-- (the measure starts again; said once a minute at most)
			local mem, now = M.mem, env.realTime and env.realTime() or 0
			mem.pass = nil
			if env.log and now - (mem.errAt or -1e9) >= 60 then mem.errAt = now; env.log("feat market: the host's measure failed: " .. tostring(err)) end
		end
	end
	M.tell(st, S, env)
	if env.write then
		local mem = M.mem
		local now = env.realTime and env.realTime() or 0
		local sig = { tostring(S and S.month), tostring(S and S.seq), tostring(env.myCo), M.alertsOn(env) and "1" or "0" }
		for _, c in ipairs(type(st.co) == "table" and st.co.list or {}) do
			if type(c) == "table" then sig[#sig + 1] = tostring(c.id) .. ":" .. tostring(c.ent) .. ":" .. tostring(c.gone) .. ":" .. tostring(c.name) end
		end
		sig = table.concat(sig, "/")
		if sig ~= mem.fileSig or now - (mem.fileAt or -1e9) >= M.FILE_EVERY_S then
			mem.fileSig, mem.fileAt = sig, now
			env.write(M.FILE, M.fileLines(st, S, env))
		end
	end
end

-- a request of the MPFever window: "show" a town (its entity) on the map
function M.request(kind, payload, st, env)
	if kind == "show" then
		local town = tonumber(payload)
		if town then
			local ok = E.focusTown(town)
			if env and env.log then env.log("feat market: camera to town " .. tostring(town) .. (ok and "" or ": NOT moved (the game refused)")) end
			return ok
		end
	end
	return false
end

-- ---------------------------------------------------------------------------------------------------- the window's tab

local function split(line)
	local out = {}
	for x in (line .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = x end
	return out
end

-- the window's file back into tables
function M.parseFile(lines)
	local d = { me = 0, alerts = true, cos = {}, tot = {}, towns = {}, inds = {}, list = {} }
	local town = nil
	for _, raw in ipairs(type(lines) == "table" and lines or {}) do
		local f = split((tostring(raw):gsub("\r", "")))
		local k = f[1]
		if k == "me" then d.me = tonumber(f[2]) or 0
		elseif k == "alerts" then d.alerts = f[2] ~= "0"
		elseif k == "alone" then d.alone = f[2] == "1"
		elseif k == "month" then d.month = tonumber(f[2])
		elseif k == "co" and tonumber(f[2]) then d.cos[tonumber(f[2])] = { id = tonumber(f[2]), ai = f[3] == "1", name = f[4] or "" }
		elseif k == "tot" and tonumber(f[2]) then
			d.tot[#d.tot + 1] = { co = tonumber(f[2]), pa = tonumber(f[3]) or -1, fr = tonumber(f[4]) or -1, towns = tonumber(f[5]) or 0, inds = tonumber(f[6]) or 0 }
		elseif k == "town" and tonumber(f[2]) then
			town = { town = tonumber(f[2]), pop = tonumber(f[3]) or 0, lead = tonumber(f[4]) or 0, name = f[5] or "", cos = {} }
			d.towns[#d.towns + 1] = town
		elseif k == "tp" and town and tonumber(f[2]) == town.town and tonumber(f[3]) then
			town.cos[#town.cos + 1] = { co = tonumber(f[3]), pa = tonumber(f[4]) or -1, fr = tonumber(f[5]) or -1, st = tonumber(f[6]) or 0 }
		elseif k == "ind" and tonumber(f[2]) then
			local cos = {}
			for x in tostring(f[3] or ""):gmatch("%d+") do cos[#cos + 1] = tonumber(x) end
			d.inds[#d.inds + 1] = { ind = tonumber(f[2]), cos = cos, name = f[4] or "" }
		elseif k == "alert" and tonumber(f[2]) then
			d.list[#d.list + 1] = { n = tonumber(f[2]), kind = f[3], by = tonumber(f[4]), town = tonumber(f[5]), townName = f[6] or "" }
		end
	end
	return d
end

-- the tab's content as plain blocks (the renderer below turns them into the window's widgets):
--   { kind = "title" | "text" | "muted", text = }, { kind = "table", headers = { ... }, rows = { { ... }, ... } },
--   { kind = "item", text =, town = } (a line with a "Show" button), { kind = "toggle", text = } (the towns' filter)
-- showAll: every town served (else the towns where this player's company is, when it is somewhere)
function M.view(d, T, showAll)
	T = T or M.T
	local B = {}
	local function add(b) B[#B + 1] = b end
	local function tr(key, ...) return M.say(T, key, ...) end
	add({ kind = "title", text = tr("title") })
	add({ kind = "muted", text = tr("explain") })
	if d.alone then add({ kind = "text", text = tr("alone") }) end
	if d.month == nil then
		if not d.alone then add({ kind = "text", text = tr("noMeasure") }) end
		return B
	end
	local function coName(id)
		local c = d.cos[id]
		local n = (c and c.name ~= "" and c.name) or ("#" .. tostring(id))
		if id == d.me and d.me ~= 0 then n = n .. " " .. tr("you") end
		return n
	end
	-- the companies' totals (C4: totals only), this player's company first
	local tot = {}
	for _, x in ipairs(d.tot) do tot[#tot + 1] = x end
	table.sort(tot, function(a, b)
		if (a.co == d.me) ~= (b.co == d.me) then return a.co == d.me end
		return a.co < b.co
	end)
	local rows = {}
	-- (0.6, the Hub: each row's company and its shares, for its band and its bars)
	local ids, shares = {}, {}
	for _, x in ipairs(tot) do
		rows[#rows + 1] = { coName(x.co), M.pct(x.pa), M.pct(x.fr), tostring(x.towns), tostring(x.inds) }
		ids[#ids + 1] = x.co
		shares[#shares + 1] = { co = x.co, name = coName(x.co), pa = x.pa, fr = x.fr }
	end
	add({ kind = "text", text = tr("totals") })
	add({ kind = "table", headers = { tr("company"), tr("passengers"), tr("cargo"), tr("towns"), tr("industries") }, rows = rows, ids = ids, shares = shares,
		me = d.me })
	-- the towns, the most populated first
	local mineSomewhere = false
	local function mine(t) for _, c in ipairs(t.cos) do if c.co == d.me then return true end end return false end
	for _, t in ipairs(d.towns) do if mine(t) then mineSomewhere = true break end end
	local all = showAll or not mineSomewhere or d.me == 0
	local towns = {}
	for _, t in ipairs(d.towns) do if all or mine(t) then towns[#towns + 1] = t end end
	table.sort(towns, function(a, b) if a.pop ~= b.pop then return a.pop > b.pop end return a.town < b.town end)
	add({ kind = "text", text = tr(all and "townsAll" or "townsMine") })
	if mineSomewhere and d.me ~= 0 then add({ kind = "toggle", text = tr(all and "showMine" or "showAll") }) end
	if #towns == 0 then add({ kind = "muted", text = tr("noTown") }) end
	for k, t in ipairs(towns) do
		if k > M.UI_TOWNS then add({ kind = "muted", text = tr("more", #towns - M.UI_TOWNS) }) break end
		local pop = M.thousands(t.pop)
		add({ kind = "item", town = t.town, text = t.lead ~= 0 and tr("townLine", t.name, pop, coName(t.lead)) or tr("townLineNoLead", t.name, pop) })
		for _, c in ipairs(t.cos) do add({ kind = "muted", text = "    " .. tr("share", coName(c.co), M.pct(c.pa), M.pct(c.fr), c.st) }) end
	end
	-- the industries: who serves them (C2), this player's ones first
	add({ kind = "text", text = tr("indTitle") })
	local inds = {}
	for _, x in ipairs(d.inds) do inds[#inds + 1] = x end
	local function serves(x) for _, co in ipairs(x.cos) do if co == d.me then return true end end return false end
	table.sort(inds, function(a, b)
		if serves(a) ~= serves(b) then return serves(a) end
		return a.ind < b.ind
	end)
	if #inds == 0 then add({ kind = "muted", text = tr("noIndustry") }) end
	for k, x in ipairs(inds) do
		if k > M.UI_INDUSTRIES then add({ kind = "muted", text = tr("more", #inds - M.UI_INDUSTRIES) }) break end
		local names = {}
		for _, co in ipairs(x.cos) do names[#names + 1] = coName(co) end
		add({ kind = "muted", text = tr("indLine", x.name, table.concat(names, ", ")) })
	end
	-- this company's last alerts (C3)
	add({ kind = "text", text = tr("alertsTitle") })
	if not d.alerts then add({ kind = "muted", text = tr("alertsOff") })
	elseif #d.list == 0 then add({ kind = "muted", text = tr("noAlert") }) end
	for _, a in ipairs(d.list) do
		local function cn(id) local c = d.cos[id]; return (c and c.name ~= "" and c.name) or ("#" .. tostring(id)) end
		add({ kind = "item", town = a.town, text = M.alertText(T, a, cn, function() return a.townName end) })
	end
	return B
end

-- The window's tab: its file, the content above, the window's widgets as the window gives them (U.featU of
-- mpfever_ui.script.lua: u.title, u.text, u.muted, u.button(label, fn), u.row(nodes), u.table(lines, widths, header); each
-- returns a node, the list of nodes is the tab's content; the window draws again after a button's function). A widget the
-- window does not give falls back to a text.
M.SHOW_W = 90                 -- the room a line keeps for its "Show" button (pixels)
M.NUM_W = 92                  -- the width of a number column of the totals
M.HELP = {
	{ "Les parts de marché comparent ce que chaque entreprise transporte dans chaque ville : les voyageurs qui vont vers la ville, en partent ou y circulent (en moyenne sur six mois), et les marchandises livrées à la ville sur six mois. L'hôte les mesure chaque mois de jeu.",
		"The market shares compare what each company carries in each town: the passengers going to, from and within the town (on average over six months), and the goods delivered to the town over six months. The host measures them every game month." },
	{ "Le tableau donne les totaux de chaque entreprise ; cliquez sur le titre d'une colonne pour le trier par elle. Les barres montrent la part de chacune.",
		"The table gives each company's totals; click a column's title to sort it by that column. The bars show each one's share." },
	{ "Plus bas, chaque ville où vous êtes, avec l'entreprise en tête et sa part ; « Voir » amène la caméra sur la ville. « Toutes les villes » montre aussi celles où vous n'êtes pas.",
		"Further down, each town where you are, with the leading company and its share; « Show » takes the camera to the town. « All the towns » shows the others too." },
}

function M.ui(u)
	local out = {}
	if type(u) ~= "table" or not u.text then return out end
	local T = u.T or M.T
	local W = tonumber(u.W) or 556
	local d = M.parseFile(u.read and u.read(M.FILE) or {})
	local function text(s, style)
		if style == "title" and u.title then return u.title(s) end
		if style == "muted" and u.muted then return u.muted(s) end
		return u.text(s)
	end
	local function button(label, fn) if u.button then return u.button(label, fn) end return nil end
	for _, b in ipairs(M.view(d, T, M.showAll)) do
		local node = nil
		if b.kind == "title" or b.kind == "muted" or b.kind == "text" then
			node = text(b.text, b.kind)
		elseif b.kind == "table" then
			if u.table then
				-- (the company's name takes what the four number columns leave)
				local lines = { b.headers }
				for _, r in ipairs(b.rows) do lines[#lines + 1] = r end
				local widths = { math.max(120, W - 4 * M.NUM_W) }
				for k = 2, #b.headers do widths[k] = M.NUM_W end
				if u.rich and b.ids and not u.oldMenus and u.button then
					-- (0.7.4, the menus redone: sorted by a click on a column's head, a second click back to the first order)
					local order = {}
					for i = 1, #b.rows do order[i] = i end
					local col = M.sortCol
					if col and col >= 2 and col <= #b.headers then
						local function val(i) return tonumber(tostring(b.rows[i][col] or ""):match("[%d%.]+")) or -1 end
						table.sort(order, function(x, y) if val(x) ~= val(y) then return val(x) > val(y) end return x < y end)
					end
					local head = { b.headers[1] }
					for k = 2, #b.headers do
						local kk = k
						head[k] = u.button(b.headers[k], function() M.sortCol = (M.sortCol == kk) and nil or kk end, col == k)
					end
					lines = { head }
					local ids2 = {}
					for _, i in ipairs(order) do lines[#lines + 1] = b.rows[i]; ids2[#ids2 + 1] = b.ids[i] end
					b = setmetatable({ ids = ids2 }, { __index = b })
				end
				if u.rich and b.ids then
					-- (0.6, the Hub: this player's company on a band of its own, then the shares as bars in the companies' colours)
					local ids, me = b.ids, b.me
					out[#out + 1] = u.table(lines, widths, true, { highlight = function(i) return me ~= 0 and ids[i] == me end })
					for pass = 1, 2 do
						local k = pass == 1 and "pa" or "fr"
						local any = false
						for _, s in ipairs(b.shares or {}) do if (s[k] or -1) >= 0 then any = true end end
						if any and u.bar then
							out[#out + 1] = u.gap and u.gap(6) or nil
							out[#out + 1] = text(M.say(T, k == "pa" and "passengers" or "cargo"), "muted")
							for _, s in ipairs(b.shares or {}) do
								local v = s[k] or -1
								out[#out + 1] = u.bar(v >= 0 and v / 1000 or 0, (u.coColor and u.coColor(s.co)) or s.co, M.pct(v),
									{ lead = s.name, leadW = math.floor(W * 0.3), labelW = 70 })
							end
						end
					end
				else
					node = u.table(lines, widths, true)
				end
			else
				out[#out + 1] = text(table.concat(b.headers, " | "), "muted")
				for _, r in ipairs(b.rows) do out[#out + 1] = text(table.concat(r, " | ")) end
			end
		elseif b.kind == "item" then
			local town = b.town
			-- (the camera moved by the bridge's interface, which logs it, see M.request; without it, from here)
			local btn = town and button(M.say(T, "show"), function()
				if u.request then u.request("show", tostring(town)) else E.focusTown(town) end
			end)
			if btn and u.row then
				-- (the line's text keeps the room of its button: one cell of u.table with a width; the Hub's u.row gives a text the room
				-- its buttons leave)
				local label = (not u.rich and u.table) and u.table({ { b.text } }, { W - M.SHOW_W }) or text(b.text)
				node = u.row({ label, btn })
			else
				node = text(b.text)
			end
		elseif b.kind == "toggle" then
			node = button(b.text, function() M.showAll = not M.showAll; if u.refresh then u.refresh() end end)
		end
		if node ~= nil then out[#out + 1] = node end
	end
	-- (0.7.4: « How does it work? » at the end of the page)
	if u.rich and not u.oldMenus and u.help and u.add then
		for _, n in ipairs(out) do u.add(n) end
		pcall(u.help, "market", { M.HELP[1], M.HELP[2], M.HELP[3] })
		return {}
	end
	return out
end

return M
