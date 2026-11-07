-- Starting territories and money handicaps (0.6, idea 06 of release/recherche-0.6; the owner's answers F1-F5 in 00-REPONSES.md),
-- in the "one company per player" mode only. Two game options of the host's lobby, both off by default (docs/FEATURES-0.6.md):
--
--   territory  {radius (km), years}   each company claims ONE town during its first game year (counted from the option's start,
--                                     or from the company's creation when it comes later); for `years` of game time after the
--                                     claim (0: for good) the other companies, the computer ones too, cannot build a station, a
--                                     stop or a depot within `radius` of the town's centre. Streets and tracks stay free.
--   handicap   {money, per player}    the start money of each player's company, in % of the game's start money, booked once for
--                                     each player's company; the savegame's company (company 1, the host's) keeps its money (F3)
--
-- Loans keep the game's own rules (F4: no cap of ours). The computer companies have no territory and respect the players' (F5):
-- their module asks M.blockedFor before it builds (see there).
--
-- Simulation half (every game, at the same step): the claims (events f_territory_claim, f_territory_drop), the end of a
-- protection, the handicaps. Everything comes from the state saved with the game (st.feat.territory), the companies registry and
-- the options, never from the world: a town's centre is not the same on every game (the towns drift), so the claimer's game
-- reads it and sends it, rounded to the metre. No square root and no power here: the distances are compared squared, on whole
-- metres, which every machine computes alike.
-- GUI half: the circles on the ground (the game's mission zones, as the map signals of 0.5.14), the chat, the window's file, and
-- the refusal of THIS player's own build in another company's territory before anything is sent (M.allow, M.proposal): one
-- decider, the builder's game, so no desync even when the games' clocks differ by a step.
--
-- The state (plain data, saved with the game; string keys = company numbers, as reg.track):
--   s.t0                     game time the territory option was first seen on (the claim year of the first companies)
--   s.seen[co]               game time a company was first seen with the option on (the claim year of a later company)
--   s.terr[co]               { co, x, y, r, name, t0, untilT (nil: for good), years, by, ended = "time"|"gone"|nil }
--   s.hc[co]                 { pct, amount, key, at }: the handicap booked for a player's company (once; 100 % books nothing)
--   s.news, s.newsSeq        what happened, the last 20 (each game tells them in its own chat, in its own language)
local M = {}
M.ID = "territory"

-- the lobby's choices (their defaults: see M.OPTIONS)
M.RADII = { 1, 2, 3, 5 }               -- km
M.YEARS = { 2, 5, 10, 20, 0 }          -- years of protection after the claim; 0 = for good
M.MONEY = { 50, 75, 100, 125, 150, 200 } -- % of the game's start money
M.EVERY = 25                           -- steps between two looks of the simulation at the companies (5 s of game time)
M.NAME = "board"                       -- the window's file: env.write(M.NAME) = feat_territory_board.txt of the session folder
M.ALPHA = 0.15                         -- the circles' opacity on the ground
M.TOWNS_MAX = 12                       -- towns offered in the window's claim list (the biggest)

M.OPTIONS = {
	{ id = "territory",
		title = { "Territoires de départ", "Starting territories" },
		desc = { "Chaque entreprise revendique une ville pendant sa première année. Les autres entreprises, IA comprises, ne peuvent pas construire de gare, d'arrêt ni de dépôt dans son cercle.",
			"Each company claims one town during its first year. The other companies, computer ones included, cannot build a station, stop or depot within its circle." },
		modes = "separate",
		params = {
			{ id = "radius", label = { "Rayon", "Radius" }, values = M.RADII, default = 2,
				show = function(v) return tostring(v) .. " km" end },
			{ id = "years", label = { "Protection", "Protected for" }, values = M.YEARS, default = 5,
				show = function(v, T)
					if tonumber(v) == 0 then return T("toujours", "for good") end
					return (T("%s ans", "%s years"):gsub("%%s", tostring(v)))
				end },
		} },
	{ id = "handicap",
		title = { "Handicaps d'argent", "Money handicaps" },
		desc = { "L'hôte choisit l'argent de départ de chaque joueur, en % de celui de la partie, versé une fois à son entreprise. L'entreprise de la sauvegarde (celle de l'hôte) garde son argent.",
			"The host picks each player's start money, in % of the game's, booked once to their company. The savegame's company (the host's) keeps its money." },
		modes = "separate",
		-- (perPlayer: the lobby shows one choice per player, read with env.param("handicap", "money." .. key), key = the player's
		-- key in the registry; "money" alone is the value of the players without a choice of their own)
		params = {
			{ id = "money", perPlayer = true, label = { "Argent de départ", "Start money" }, values = M.MONEY, default = 100,
				show = function(v) return tostring(v) .. " %" end },
		} },
}
M.EVENTS = { f_territory_claim = true, f_territory_drop = true }
M.TAB = { id = "territory", title = { "Territoires", "Territories" } }
-- (0.7.4) the page's « How does it work? », at its end in the Hub (see the window's U.featTabRows)
M.HELP = {
	{ "Pendant sa première année, chaque entreprise peut revendiquer une ville. Dans le cercle autour de cette ville, les autres entreprises, celles de l'ordinateur comprises, ne peuvent construire ni gare, ni arrêt, ni dépôt tant que dure la protection.",
		"During its first year each company may claim a town. Within the circle around that town, the other companies, the computer's included, can build no station, stop or depot while the protection lasts." },
	{ "Le rayon du cercle et la durée de la protection sont des réglages de l'hôte. Les voies et les routes des autres peuvent toujours traverser un territoire.",
		"The circle's radius and how long the protection lasts are the host's settings. The others' tracks and roads may still cross a territory." },
}

-- Texts: the env's T when the options host gives one (env.T, the bridge's C.T), else English. The integration may set M.T = C.T.
M.T = function(fr, en) return en end
local function Tx(env) return (type(env) == "table" and type(env.T) == "function") and env.T or M.T end
-- (a text with %s, each taking the next value; put in with gsub, as C.Tf: a value may contain % itself. The texts are written
-- T("français", "English") where they are used, so that tests/test_lang.py finds them for launcher/lang.json)
local function fill(t, ...)
	local values, i = { ... }, 0
	return (t:gsub("%%s", function() i = i + 1; return tostring(values[i]) end))
end

-- ---------------------------------------------------------------- small helpers (plain data, no game API)
local function num(v)
	v = tonumber(v)
	if v and v == v and v > -1e15 and v < 1e15 then return v end
	return nil
end
local function pick(v, list, default)
	v = tonumber(v)
	for _, x in ipairs(list) do if x == v then return v end end
	return default
end
-- (a map's keys in one order on every game: pairs() order differs between Lua states, and the news and their numbers are part of
-- the state every game must hold alike)
local function sortedKeys(t)
	local ks = {}
	if type(t) ~= "table" then return ks end
	for k in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb and na ~= nb then return na < nb end
		return tostring(a) < tostring(b)
	end)
	return ks
end
local function companyOf(reg, id)
	for _, c in ipairs(type(reg) == "table" and reg.list or {}) do if c.id == id then return c end end
	return nil
end
local function isAi(c) return c ~= nil and (c.ai == true or tostring(c.key or ""):sub(1, 3) == "ai:") end
-- the player a company's handicap follows: its chief (the player who created it), else its first member, else its key
local function playerOf(c)
	if not c then return nil end
	if type(c.chief) == "string" and c.chief ~= "" then return c.chief end
	local m = type(c.members) == "table" and c.members[1] or nil
	if type(m) == "table" and type(m.key) == "string" and m.key ~= "" then return m.key end
	if type(m) == "string" and m ~= "" then return m end
	if type(c.key) == "string" and c.key ~= "" then return (c.key:gsub("@.*$", "")) end
	return nil
end
-- (a name for the state and the chat: no control character, 60 bytes at most, no cut UTF-8 character at its end)
local function cleanName(s)
	s = tostring(s or ""):gsub("%c", " ")
	if #s > 60 then s = s:sub(1, 60):gsub("[\192-\255][\128-\191]*$", "") end
	return s
end
-- the companies mode: the env's (simulation half), else the registry's (the GUI half's env has no mode in the contract)
local function separate(st, env)
	local m = type(env) == "table" and env.mode or nil
	if m == nil and type(st) == "table" and type(st.co) == "table" then m = st.co.mode end
	return m == "separate"
end
local function stateOf(st) return type(st) == "table" and type(st.feat) == "table" and st.feat[M.ID] or nil end
local function on(env, id)
	if type(env) ~= "table" then return false end
	local ok, v = pcall(env.on, id)
	return ok and v == true
end
local function optParam(env, id, pid)
	if type(env) ~= "table" then return nil end
	local ok, v = pcall(env.param, id, pid)
	if ok then return v end
	return nil
end
-- whether a territory still protects: its time and its company's end are marked by the simulation (see M.tick); a company gone
-- since the last look counts as ended at once
local function protects(t, reg)
	if type(t) ~= "table" or t.ended then return false end
	local c = companyOf(reg, t.co)
	return c ~= nil and not c.gone
end
local function overlaps(t, x, y, r)
	local dx, dy, rr = t.x - x, t.y - y, t.r + r
	return dx * dx + dy * dy < rr * rr
end

-- ---------------------------------------------------------------- the options' values
function M.radius(env) return pick(optParam(env, "territory", "radius"), M.RADII, 2) * 1000 end
function M.years(env) return pick(optParam(env, "territory", "years"), M.YEARS, 5) end
function M.moneyPct(env, key)
	local v = nil
	if type(key) == "string" and key ~= "" then v = optParam(env, "handicap", "money." .. key) end
	if pick(v, M.MONEY, nil) == nil then v = optParam(env, "handicap", "money") end
	return pick(v, M.MONEY, 100)
end

-- The length of a game year in game time (ms): the game's default year, the same constant on every game (as mpfever_eco.lua's
-- months). The integration may replace it.
M.YEAR_FALLBACK = 1461000
function M.yearMs()
	local y = nil
	pcall(function() y = api.util.getDefaultYearDuration() end)
	y = num(y)
	if y and y > 0 then return y end
	return M.YEAR_FALLBACK
end

-- the end of a company's claim year: one game year from the option's start, or from the company's first look when it came later
function M.claimEnd(s, co)
	local t0 = num(s and s.t0)
	local seen = num(s and s.seen and s.seen[tostring(co)])
	local from = t0 or seen
	if t0 and seen and seen > t0 then from = seen end
	if not from then return nil end
	return from + M.yearMs()
end

-- ---------------------------------------------------------------- where a company may not build
-- The territory that protects (x, y) against company `co` (another company's, still protecting), nil when none. Read on the state
-- as either half sees it.
function M.ownerAt(st, co, x, y)
	local s = stateOf(st)
	x, y = num(x), num(y)
	if type(s) ~= "table" or type(s.terr) ~= "table" or not (x and y) then return nil end
	for _, k in ipairs(sortedKeys(s.terr)) do
		local t = s.terr[k]
		if t.co ~= co and protects(t, st.co) then
			local dx, dy = x - t.x, y - t.y
			if dx * dx + dy * dy < t.r * t.r then return t end
		end
	end
	return nil
end

-- For the computer companies' module (host only, F5): whether company `co` may not build a station, stop or depot at (x, y)
-- (another company's territory there), with that company's number and its town's name. `env` is an env of the options host for
-- this module (its env.on); without one, the territories of the state count as on.
function M.blockedFor(st, env, co, x, y)
	if type(env) == "table" and env.on and not on(env, "territory") then return false end
	if not separate(st, env) then return false end
	local t = M.ownerAt(st, co, x, y)
	if t then return true, t.co, t.name end
	return false
end

-- whether another company than `co` holds a territory that protects (the refusals' quick way out: no proposal read)
local function anyForeign(st, co)
	local s = stateOf(st)
	for _, t in pairs(type(s) == "table" and type(s.terr) == "table" and s.terr or {}) do
		if t.co ~= co and protects(t, st.co) then return true end
	end
	return false
end
-- (the same for the computer companies' module: nothing to look at while no other company's territory protects)
function M.anyFor(st, co) return anyForeign(st, co) end

-- (a read that never fails: the tool's Proposal is userdata, its fields and lists read with pcall as G.pvPoints does)
local function get(o, k)
	if o == nil then return nil end
	local ok, v = pcall(function() return o[k] end)
	if ok then return v end
	return nil
end
local function len(o)
	if o == nil then return 0 end
	local ok, n = pcall(function() return #o end)
	return (ok and type(n) == "number") and n or 0
end
-- the keys of a map, read with pairs only: indexing a native map inserts the key and corrupts the live proposal (C.marshalMap)
local function mapKeys(m, into)
	into = into or {}
	if m == nil then return into end
	local src = m
	pcall(function() if type(m) == "table" and type(m.__pairs) == "table" then src = m.__pairs end end)
	pcall(function() for k in pairs(src) do into[k] = true end end)
	return into
end
local function mapValues(m, into)
	into = into or {}
	if m == nil then return into end
	local src = m
	pcall(function() if type(m) == "table" and type(m.__pairs) == "table" then src = m.__pairs end end)
	pcall(function()
		for _, list in pairs(src) do
			pcall(function() for _, v in pairs(list) do into[v] = true end end)
		end
	end)
	return into
end
-- the translation of a matrix (a Mat4f, or its shipped form { __mat, 1..16 })
local function xyOf(tf)
	local x, y = num(get(tf, 13)), num(get(tf, 14))
	if x and y then return x, y end
	return nil
end

-- A station, a depot, an airport or a port, by its construction file (as the bridge's isTransportConstruction): the street tool's
-- junctions, the towns' buildings and the industries are not one
function M.isTransportFile(f)
	f = tostring(f or ""):lower()
	if f == "" or f:find("street_construction/", 1, true) or f:find("/buildings/", 1, true) or f:find("^buildings/")
		or f:find("/industries/", 1, true) or f:find("^industries/") then return false end
	return f:find("/stations/", 1, true) ~= nil or f:find("^stations/") ~= nil or f:find("depot", 1, true) ~= nil
		or f:find("airport", 1, true) ~= nil or f:find("airfield", 1, true) ~= nil or f:find("harbor", 1, true) ~= nil
		or f:find("helipad", 1, true) ~= nil or f:find("heliport", 1, true) ~= nil
end

-- The places where a build puts a station, a depot or a stop: { { x, y, what }... }. `p` is the tool's Proposal (userdata, from
-- builder.proposalCreate) or its shipped form (C.compactProposal: an act's args[1]). Signals, waypoints, streets and tracks are
-- none. The stops the stop tool only re-creates on the segment it rebuilds (new2oldEdgeObjects) are none either: else a street
-- with a stop already on it could not be edited.
function M.buildPoints(p)
	local pts = {}
	local toAdd = get(p, "toAdd") or get(p, "constructionsToAdd")
	for i = 1, len(toAdd) do
		local ce = get(toAdd, i)
		local con = get(ce, "construction")
		if M.isTransportFile(get(ce, "fileName")) or len(get(con, "stations")) > 0 or len(get(con, "depots")) > 0 then
			local x, y = xyOf(get(ce, "transf"))
			if x then pts[#pts + 1] = { x = x, y = y, what = "con" } end
		end
	end
	local sp = get(p, "proposal") or get(p, "streetProposal")
	local objs = get(sp, "edgeObjectsToAdd")
	if len(objs) > 0 then
		local again = mapKeys(get(sp, "new2oldEdgeObjects"))
		mapValues(get(sp, "old2newEdgeObjects"), again)
		local lost = false
		for i = 1, len(objs) do
			local o = get(objs, i)
			local id = get(o, "resultEntity")
			if get(o, "category") == 0 and not (id ~= nil and again[id]) then
				local x, y = xyOf(get(get(o, "modelInstance"), "transf"))
				if x then pts[#pts + 1] = { x = x, y = y, what = "stop" } else lost = true end
			end
		end
		-- (a new stop without a model position: the nodes of the segments the tool rebuilds for it, which are where it goes)
		if lost then
			local nodes = get(sp, "addedNodes")
			for i = 1, len(nodes) do
				local pos = get(get(get(nodes, i), "comp"), "position")
				local x, y = num(get(pos, "x")), num(get(pos, "y"))
				if x and y then pts[#pts + 1] = { x = x, y = y, what = "stop" } end
			end
		end
	end
	return pts
end

-- The company that owns an entity of this game (the registry's number), nil when none; `e` may be a shipped reference, whose `id`
-- is the builder's (this game's) entity. GUI half; the integration may replace it.
function M.ownerCo(st, e)
	if type(e) == "table" then e = num(get(e, "id")) end
	if type(e) ~= "number" then return nil end
	local p = nil
	pcall(function()
		local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
		p = po and po.player
	end)
	if p == nil then return nil end
	for _, c in ipairs(type(st) == "table" and type(st.co) == "table" and st.co.list or {}) do
		if c.ent == p then return c.id end
	end
	return nil
end

local function companyName(st, id, T)
	local c = companyOf(type(st) == "table" and st.co or nil, id)
	if c and type(c.name) == "string" and c.name ~= "" then return c.name end
	return fill(T("entreprise %s", "company %s"), tostring(id))
end

-- The reason a build of company `co` is refused (another company's territory), nil when it is not. A build that rebuilds a
-- construction of `co` (a station's modules edited, its own station there from before the claim) is not refused.
function M.refusal(p, st, env, co)
	if co == nil or not on(env, "territory") or not separate(st, env) or not anyForeign(st, co) then return nil end
	local pts = M.buildPoints(p)
	if #pts == 0 then return nil end
	local tr = get(p, "toRemove")
	for i = 1, len(tr) do
		if M.ownerCo(st, get(tr, i)) == co then return nil end
	end
	for _, q in ipairs(pts) do
		local t = M.ownerAt(st, co, q.x, q.y)
		if t then
			local T = Tx(env)
			return fill(T("Territoire de %s (%s) : vous ne pouvez pas y construire de gare, d'arrêt ni de dépôt.",
				"Territory of %s (%s): you cannot build a station, stop or depot here."), companyName(st, t.co, T), t.name)
		end
	end
	return nil
end

-- THIS player's own action, before it is shipped (contract hook): a build of a station, stop or depot in another company's
-- territory is refused here, nothing is sent. The act's company first (a computer company's act shipped by the host's game is
-- held to the players' territories too), else this player's.
function M.allow(a, st, env)
	if type(a) ~= "table" or a.fn ~= "makeWorldBuildProposalCmd" or type(a.args) ~= "table" then return true end
	local why = M.refusal(a.args[1], st, env, a.co or (type(env) == "table" and env.myCo) or nil)
	if why then return false, why end
	return true
end

-- The tool's own refusal (hook the contract lacks, see the integration notes): `param` is the { Proposal, ProposalData } of the
-- game's builder.proposalCreate event. The text returned goes into the answer's errorMessages, as the game's permits do
-- (company.script): the tool shows it in red and does not build. A proposal the game already refuses is left alone.
function M.proposal(param, st, env)
	local p = get(param, 1)
	if p == nil then return nil end
	if get(get(get(param, 2), "errorState"), "critical") == true then return nil end
	return M.refusal(p, st, env, type(env) == "table" and env.myCo or nil)
end

-- (a log line of the GUI half, the first ones of a kind and then every 100th: the tool's events come at every mouse move)
M.logN = {}
local function logSome(env, kind, text)
	M.logN[kind] = (M.logN[kind] or 0) + 1
	local n = M.logN[kind]
	if (n <= 3 or n % 100 == 0) and type(env) == "table" and type(env.log) == "function" then
		pcall(env.log, "feat territory: " .. text .. (n > 1 and (" [" .. n .. " so far]") or ""))
	end
end

-- The options host's hook of the game's interface events (F.guiVeto, the bridge's guiHandleEvent; MPFEVER_FEATVETO=0: never
-- called): a tool's proposal (builder.proposalCreate) that puts a station, a stop or a depot in another company's territory gets
-- the reason in its errorMessages, as the game's permits (company.script): the tool shows it in red and does not build. The
-- proposal stays drawn (skipRender false). nil for anything else (the game's other scripts keep their say).
function M.guiVeto(id, name, param, st, env)
	if name ~= "builder.proposalCreate" and name ~= "builder.proposalApply" then return nil end
	if not on(env, "territory") then return nil end
	local why = M.proposal(param, st, env)
	if not why then return nil end
	if name == "builder.proposalApply" then
		-- (the game applies a build our answer to its proposal turned down: our errorMessages did not stop the tool, the in-game
		-- fact to check; its build then goes on as any build, M.allow lets the tools' builds through, see #91)
		logSome(env, "applied", "WARNING the " .. tostring(id) .. " tool applied a build turned down here (" .. why .. "): the game did not take our errorMessages")
		return nil
	end
	logSome(env, "veto", "the " .. tostring(id) .. " tool's proposal turned down here: " .. why)
	return { errorMessages = { [why] = true }, skipRender = false }
end

-- ---------------------------------------------------------------- simulation half
local function news(s, t, now)
	s.newsSeq = (s.newsSeq or 0) + 1
	t.n = s.newsSeq
	t.at = now
	s.news = s.news or {}
	s.news[#s.news + 1] = t
	while #s.news > 20 do table.remove(s.news, 1) end
end

-- (this game's handicap bookings waiting for the company's player entity: each game creates it a few frames after the join, see
-- the bridge's coCreate. Not in the state: the decision is, the same on every game; a load in between leaves the booking to the
-- host's balances, which every game's follow)
M.pending = {}
local function bookOrWait(env, c, amount)
	if c.ent then env.book(c.ent, amount) else M.pending[#M.pending + 1] = { id = c.id, amount = amount } end
end
local function flushPending(reg, env)
	local keep = {}
	for _, p in ipairs(M.pending) do
		local c = companyOf(reg, p.id)
		if c and not c.gone then
			if c.ent then env.book(c.ent, p.amount); env.log("territory: handicap of company " .. c.id .. " booked (" .. p.amount .. ")")
			else keep[#keep + 1] = p end
		end
	end
	M.pending = keep
end

-- each player's company gets its handicap once (a new company too: a new player, a restart after a bankruptcy), from the start
-- money its join gave it (c.start, 0.5.14) else the registry's; not the savegame's company (company 1) nor a computer company
local function handicaps(s, reg, env, now)
	local changed = s.hc == nil
	s.hc = s.hc or {}
	for _, c in ipairs(reg.list or {}) do
		local k = tostring(c.id)
		if c.id ~= 1 and not c.gone and not isAi(c) and s.hc[k] == nil then
			local key = playerOf(c)
			if key then
				changed = true
				local pct = M.moneyPct(env, key)
				local start = num(c.start) or num(reg.start) or 2000000
				local amount = math.floor(start * (pct - 100) / 100 + 0.5)
				s.hc[k] = { pct = pct, amount = amount, key = key, at = now }
				if amount ~= 0 then
					bookOrWait(env, c, amount)
					news(s, { k = "hc", co = c.id, pct = pct, amount = amount }, now)
				end
				env.log("territory: handicap of company " .. c.id .. " (" .. key .. "): " .. pct .. " %, " .. amount)
			end
		end
	end
	return changed
end

-- Every simulation step while an option is on (a look every M.EVERY steps): whether the state changed (the options host saves the
-- state only then, else the next step reads it as it was: a handicap would be booked again)
function M.tick(st, env)
	if #M.pending > 0 then flushPending(env.co or st.co, env) end
	local onT, onH = on(env, "territory"), on(env, "handicap")
	if not (onT or onH) or env.mode ~= "separate" then return false end
	local reg = env.co or st.co
	if type(reg) ~= "table" or not env.every(M.EVERY) then return false end
	local changed = type(st.feat) ~= "table" or type(st.feat[M.ID]) ~= "table"
	local s = env.state(st)
	local now = env.gameTime()
	if onT then
		if s.t0 == nil then s.t0 = now; changed = true end
		if s.seen == nil then s.seen = {}; changed = true end
		for _, c in ipairs(reg.list or {}) do
			local k = tostring(c.id)
			if not c.gone and not isAi(c) and s.seen[k] == nil then s.seen[k] = now; changed = true end
		end
		-- the protections that end: their time is up, or their company is gone (bankrupt, merged, left empty)
		for _, k in ipairs(sortedKeys(s.terr)) do
			local t = s.terr[k]
			if not t.ended then
				local c = companyOf(reg, t.co)
				local why = nil
				if not c or c.gone then why = "gone" elseif t.untilT and now >= t.untilT then why = "time" end
				if why then
					t.ended = why
					changed = true
					news(s, { k = "end", co = t.co, name = t.name, why = why }, now)
					env.log("territory: the territory of company " .. t.co .. " (" .. t.name .. ") ends (" .. why .. ")")
				end
			end
		end
	end
	if onH and handicaps(s, reg, env, now) then changed = true end
	return changed
end

-- A claim (any member of a company, from the window: f_territory_claim {x, y, name}) or its withdrawal within the claim year
-- (f_territory_drop {}). The sender's company is param.mpfCo, its name param.mpfFrom, both put in by the bridge as for its co_*
-- events. A claim is refused when the company already has a territory, its claim year is over, it is a computer company, or the
-- circle would overlap another company's territory that still protects; the refusal is a news for the claimer's game.
function M.event(st, name, param, env)
	if type(param) ~= "table" or not M.EVENTS[name] or not on(env, "territory") or env.mode ~= "separate" then return end
	local reg = env.co or st.co
	local c = companyOf(reg, num(param.mpfCo))
	if not c then
		env.log("territory: " .. tostring(name) .. " of an unknown company (" .. tostring(param.mpfCo) .. ") ignored")
		return
	end
	local s = env.state(st)
	local now = env.gameTime()
	local k = tostring(c.id)
	if s.t0 == nil then s.t0 = now end
	s.seen = s.seen or {}
	if s.seen[k] == nil and not isAi(c) then s.seen[k] = now end
	s.terr = s.terr or {}
	local last = M.claimEnd(s, c.id)
	if name == "f_territory_drop" then
		local t = s.terr[k]
		if t and not t.ended and last and now <= last then
			s.terr[k] = nil
			news(s, { k = "drop", co = c.id, name = t.name }, now)
			env.log("territory: company " .. c.id .. " gives up its territory (" .. t.name .. ")")
		end
		return
	end
	local x, y = num(param.x), num(param.y)
	local why, other, otherName = nil, nil, nil
	local r = M.radius(env)
	if c.gone then why = "company"
	elseif isAi(c) then why = "ai"
	elseif not (x and y and math.abs(x) < 1e6 and math.abs(y) < 1e6) then why = "place"
	elseif s.terr[k] then why = "already"
	elseif not last or now > last then why = "late"
	else
		x, y = math.floor(x + 0.5), math.floor(y + 0.5)
		for _, ok in ipairs(sortedKeys(s.terr)) do
			local t = s.terr[ok]
			if t.co ~= c.id and protects(t, reg) and overlaps(t, x, y, r) then why, other, otherName = "overlap", t.co, t.name; break end
		end
	end
	local town = cleanName(param.name)
	if why then
		news(s, { k = "refused", co = c.id, name = town, why = why, other = other, otherName = otherName }, now)
		env.log("territory: claim of company " .. c.id .. " (" .. town .. ") refused: " .. why)
		return
	end
	local years = M.years(env)
	s.terr[k] = { co = c.id, x = x, y = y, r = r, name = town, t0 = now, untilT = years > 0 and (now + years * M.yearMs()) or nil,
		years = years, by = cleanName(param.mpfFrom) }
	news(s, { k = "claim", co = c.id, name = town, years = years, r = r }, now)
	env.log("territory: company " .. c.id .. " claims " .. town .. " at " .. x .. "," .. y .. " (radius " .. r .. " m, " .. years .. " years)")
end

-- ---------------------------------------------------------------- GUI half
-- (this game's: the circles drawn, the news already told, the towns of the claim list)
M.drawn = {}
M.newsSeen = nil
M.townList, M.townsAt = nil, nil

-- This game's game time in the GUI half (the window's months left; the env of M.gui has none in the contract). Replaceable.
function M.now(env)
	if type(env) == "table" and type(env.gameTime) == "function" then
		local ok, t = pcall(env.gameTime)
		if ok and num(t) then return num(t) end
	end
	local t = nil
	pcall(function() t = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime end)
	return num(t)
end

-- The circle of a territory on the ground: the game's mission zones (draw, never prohibitBuilding: it would refuse every build
-- there, streets and tracks too, and perhaps the replays), as the map signals and the build previews. Replaceable.
-- (the colours of mpfever_co.lua's CO.PALETTE; the integration may set M.rgb = CO.rgb)
M.PALETTE = {
	{ 0.86, 0.20, 0.20 }, { 0.20, 0.45, 0.90 }, { 0.20, 0.72, 0.30 }, { 0.98, 0.62, 0.10 },
	{ 0.62, 0.30, 0.82 }, { 0.10, 0.75, 0.80 }, { 0.95, 0.88, 0.15 }, { 0.95, 0.45, 0.70 },
	{ 0.55, 0.35, 0.18 }, { 0.55, 0.85, 0.15 }, { 0.15, 0.30, 0.55 }, { 0.62, 0.62, 0.62 },
}
function M.rgb(ix)
	local p = M.PALETTE[((tonumber(ix) or 1) - 1) % #M.PALETTE + 1]
	return p[1], p[2], p[3]
end
function M.zone(key, x, y, r, cr, cg, cb)
	pcall(function()
		api.gui.mission.setZoneCircle(key, api.type.Vec2f.new(x, y), r, true, api.type.Vec4f.new(cr, cg, cb, M.ALPHA), false, false)
	end)
end
function M.unzone(key) pcall(function() api.gui.mission.removeZone(key) end) end
function M.clearZones()
	for key in pairs(M.drawn) do M.unzone(key); M.drawn[key] = nil end
end
local function drawZones(s, st, env)
	local want = {}
	for _, k in ipairs(sortedKeys(s and s.terr)) do
		local t = s.terr[k]
		if protects(t, st.co) then
			local c = companyOf(st.co, t.co)
			want["mpfever_terr_" .. k] = { t.x, t.y, t.r, c and c.color or 1 }
		end
	end
	for key in pairs(M.drawn) do
		if not want[key] then M.unzone(key); M.drawn[key] = nil; logSome(env, "unzone", "circle " .. key .. " taken away") end
	end
	for key, z in pairs(want) do
		local sig = table.concat(z, ",")
		if M.drawn[key] ~= sig then
			M.zone(key, z[1], z[2], z[3], M.rgb(z[4]))
			M.drawn[key] = sig
			-- (in game: the circle must show on the ground and on the map of every game, in the company's colour)
			logSome(env, "zone", "circle " .. key .. " drawn at " .. z[1] .. "," .. z[2] .. ", radius " .. z[3] .. " m, colour " .. tostring(z[4]))
		end
	end
end

-- The towns a player may claim, the biggest first: { { e, name, x, y, size }... } (residential district centre, as the computer
-- companies take it). GUI half; replaceable.
function M.towns()
	local out = {}
	pcall(function()
		local list = {}
		api.engine.forEachEntityWithComponent(function(t) list[#list + 1] = t end, api.type.ComponentType.TOWN)
		local caps = {}
		pcall(function() caps = api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() or {} end)
		local use = api.type.enum.LandUseType.RESIDENTIAL
		for _, t in ipairs(list) do
			local name, x, y = tostring(t), nil, nil
			pcall(function() name = api.engine.getComponent(t, api.type.ComponentType.NAME).name end)
			pcall(function() local p = api.engine.util.town.getTownDistrictCenter(t, use); x, y = p.x, p.y end)
			local cap = nil
			pcall(function() cap = caps[t] end)
			if num(x) and num(y) then
				out[#out + 1] = { e = t, name = cleanName(name), x = x, y = y,
					size = type(cap) == "table" and ((cap[1] or 0) + (cap[2] or 0) + (cap[3] or 0)) or 0 }
			end
		end
	end)
	table.sort(out, function(a, b) if a.size ~= b.size then return a.size > b.size end return a.e < b.e end)
	return out
end

-- whether this player's company may claim (x, y) now, by the rules the simulation applies (it decides: a claim sent at the last
-- moment may still be refused there); false and the reason otherwise
function M.canClaim(st, env, co, x, y)
	local T = Tx(env)
	local c = companyOf(type(st) == "table" and st.co or nil, co)
	if not c or c.gone or isAi(c) then return false, T("Votre entreprise ne peut pas revendiquer de territoire.", "Your company cannot claim a territory.") end
	local s = stateOf(st)
	if s and s.terr and s.terr[tostring(co)] then return false, T("Votre entreprise a déjà un territoire.", "Your company already has a territory.") end
	local last, now = M.claimEnd(s, co), M.now(env)
	if last and now and now > last then
		return false, T("Le délai d'un an pour revendiquer une ville est passé.", "The year to claim a town is over.")
	end
	x, y = num(x), num(y)
	if not (x and y) then return false, T("Ville introuvable.", "Town not found.") end
	local r = M.radius(env)
	for _, k in ipairs(sortedKeys(s and s.terr)) do
		local t = s.terr[k]
		if t.co ~= co and protects(t, st.co) and overlaps(t, math.floor(x + 0.5), math.floor(y + 0.5), r) then
			return false, fill(T("Trop près du territoire de %s (%s).", "Too close to the territory of %s (%s)."), companyName(st, t.co, T), t.name)
		end
	end
	return true
end

local function money(n)
	local s = tostring(math.floor(math.abs(n) + 0.5)):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return (n < 0 and "-" or "+") .. s
end
-- (metres as kilometres: "2", "1.5", whatever Lua's version writes for a whole float)
local function km(r) return string.format("%g", (tonumber(r) or 0) / 1000) end
local function yearsText(T, years)
	if years == 0 then return T("pour toujours", "for good") end
	return fill(T("pendant %s ans", "for %s years"), tostring(years))
end

-- the chat line of a news, in this game's language; nil for a news this player need not see (another company's refused claim)
function M.newsText(n, st, env)
	local T = Tx(env)
	local who = companyName(st, n.co, T)
	if n.k == "claim" then
		return fill(T("%s a revendiqué %s comme territoire (rayon %s km, protégé %s).", "%s claimed %s as its territory (radius %s km, protected %s)."),
			who, n.name, km(n.r), yearsText(T, n.years))
	elseif n.k == "end" then
		if n.why == "gone" then
			return fill(T("Le territoire de %s (%s) prend fin : l'entreprise n'est plus là.", "The territory of %s (%s) ends: the company is gone."), who, n.name)
		end
		return fill(T("Le territoire de %s (%s) n'est plus protégé.", "The territory of %s (%s) is no longer protected."), who, n.name)
	elseif n.k == "drop" then
		return fill(T("%s renonce à son territoire (%s).", "%s gives up its territory (%s)."), who, n.name)
	elseif n.k == "hc" then
		return fill(T("Handicap : %s commence avec %s % de l'argent de départ (%s).", "Handicap: %s starts with %s % of the start money (%s)."),
			who, tostring(n.pct), money(n.amount or 0))
	elseif n.k == "refused" then
		if type(env) ~= "table" or env.myCo ~= n.co then return nil end
		local why
		if n.why == "already" then why = T("Votre entreprise a déjà un territoire.", "Your company already has a territory.")
		elseif n.why == "late" then why = T("Le délai d'un an pour revendiquer une ville est passé.", "The year to claim a town is over.")
		elseif n.why == "overlap" then
			why = fill(T("Trop près du territoire de %s (%s).", "Too close to the territory of %s (%s)."), companyName(st, n.other, T), n.otherName or "?")
		elseif n.why == "ai" then why = T("Une entreprise de l'ordinateur n'a pas de territoire.", "A computer company has no territory.")
		else why = T("Revendication impossible.", "The claim is not possible.") end
		return fill(T("Revendication de %s refusée.", "Claim of %s refused."), n.name) .. " " .. why
	end
	return nil
end

local function tellNews(s, st, env)
	local seq = s and s.newsSeq or 0
	if M.newsSeen == nil then
		-- (the first look of this game, a load: the news older than 30 s of game time are not told again)
		M.newsSeen = 0
		local now = M.now(env)
		for _, n in ipairs(s and s.news or {}) do
			if not now or (n.at or 0) < now - 30000 then M.newsSeen = math.max(M.newsSeen, n.n or 0) end
		end
	end
	if seq <= M.newsSeen then return end
	for _, n in ipairs(s.news or {}) do
		if (n.n or 0) > M.newsSeen then
			local text = M.newsText(n, st, env)
			if text then env.chat(text) end
		end
	end
	M.newsSeen = seq
end

-- (a field of the window's file: no tab, no line break)
local function field(v) return (tostring(v == nil and "" or v):gsub("[%c]", " ")) end
local function monthsLeft(untilT, now)
	if not (untilT and now) then return -1 end
	return math.max(0, math.ceil((untilT - now) / (M.yearMs() / 12)))
end

-- The window's file (env.write): tab-separated lines, read by M.ui on this game
--   rule  radiusKm years | me state(claim/has/late/none) monthsLeft canDrop | town e name free x y | terr co coName town radiusKm
--   status(on/forever/ended) monthsLeft mine x y | hc co coName pct amount
-- (0.6, the Hub: x y after town and terr, the town's or the territory's centre, for the tab's « View » buttons; read by this game's
-- own window only)
function M.fileLines(st, env, onT, onH)
	local s = stateOf(st)
	local now = M.now(env)
	local L = {}
	local co = type(env) == "table" and env.myCo or nil
	if onT then
		L[#L + 1] = "rule\t" .. km(M.radius(env)) .. "\t" .. M.years(env)
		local c = companyOf(st.co, co)
		local mine = s and s.terr and s.terr[tostring(co)]
		local last = M.claimEnd(s, co) or (now and now + M.yearMs())
		if not c or c.gone or isAi(c) then L[#L + 1] = "me\tnone\t-1\t0"
		elseif mine then
			L[#L + 1] = "me\thas\t" .. monthsLeft(last, now) .. "\t" .. ((not mine.ended and now and last and now <= last) and 1 or 0)
		elseif now and last and now <= last then
			L[#L + 1] = "me\tclaim\t" .. monthsLeft(last, now) .. "\t0"
			-- (the claim list: the biggest towns, read again every 15 s of real time while this company may claim)
			local rt = (type(env.realTime) == "function" and env.realTime()) or 0
			if not M.townList or not M.townsAt or rt - M.townsAt > 15 or rt < M.townsAt then
				M.townList, M.townsAt = M.towns(), rt
				logSome(env, "towns", #M.townList .. " town(s) found for the claim list" .. (M.townList[1] and (", the biggest " .. M.townList[1].name .. " at "
					.. math.floor(M.townList[1].x) .. "," .. math.floor(M.townList[1].y)) or ""))
			end
			for i, t in ipairs(M.townList) do
				if i > M.TOWNS_MAX then break end
				L[#L + 1] = "town\t" .. field(t.e) .. "\t" .. field(t.name) .. "\t" .. (M.canClaim(st, env, co, t.x, t.y) and 1 or 0)
					.. "\t" .. math.floor(t.x + 0.5) .. "\t" .. math.floor(t.y + 0.5)
			end
		else L[#L + 1] = "me\tlate\t0\t0" end
		for _, k in ipairs(sortedKeys(s and s.terr)) do
			local t = s.terr[k]
			local status = protects(t, st.co) and (t.untilT and "on" or "forever") or "ended"
			L[#L + 1] = "terr\t" .. t.co .. "\t" .. field(companyName(st, t.co, Tx(env))) .. "\t" .. field(t.name) .. "\t" .. km(t.r)
				.. "\t" .. status .. "\t" .. (status == "on" and monthsLeft(t.untilT, now) or -1) .. "\t" .. (t.co == co and 1 or 0)
				.. "\t" .. (num(t.x) and math.floor(t.x + 0.5) or "") .. "\t" .. (num(t.y) and math.floor(t.y + 0.5) or "")
		end
	end
	if onH then
		for _, k in ipairs(sortedKeys(s and s.hc)) do
			local h = s.hc[k]
			L[#L + 1] = "hc\t" .. k .. "\t" .. field(companyName(st, tonumber(k), Tx(env))) .. "\t" .. h.pct .. "\t" .. h.amount
		end
	end
	return L
end

-- GUI half, every game, about once a second: the circles, the chat, the window's file. Nothing is decided here (every decision is
-- the simulation's, from the state and the options): no event is sent, on the host's game as on the others.
function M.gui(st, env)
	local onT, onH = on(env, "territory"), on(env, "handicap")
	local sep = separate(st, env)
	if not (onT and sep) then M.clearZones() end
	if not ((onT or onH) and sep) then return end
	local s = stateOf(st)
	tellNews(s, st, env)
	if onT then drawZones(s, st, env) end
	env.write(M.NAME, M.fileLines(st, env, onT, onH))
end

-- The window's requests on this game: "claim" (payload: the town's entity, from the claim list or a town's own window) and
-- "drop". The claim is checked here first (the reason in the chat), then sent: the simulation decides.
function M.request(kind, payload, st, env)
	if not (on(env, "territory") and separate(st, env)) then return false end
	local T = Tx(env)
	if kind == "claim" then
		local e = tonumber(payload)
		local town = nil
		for _, t in ipairs(M.townList or {}) do if t.e == e then town = t end end
		if not town then
			for _, t in ipairs(M.towns()) do if t.e == e then town = t end end
		end
		if not town then env.chat(T("Ville introuvable.", "Town not found.")); logSome(env, "notown", "claim: town " .. tostring(payload) .. " not found"); return false end
		local ok, why = M.canClaim(st, env, env.myCo, town.x, town.y)
		if not ok then env.chat(why); logSome(env, "noclaim", "claim of " .. town.name .. " not sent: " .. tostring(why)); return false end
		env.send("f_territory_claim", { x = math.floor(town.x + 0.5), y = math.floor(town.y + 0.5), name = cleanName(town.name) })
		logSome(env, "claim", "claim of " .. town.name .. " (town " .. tostring(town.e) .. " at " .. math.floor(town.x + 0.5) .. "," .. math.floor(town.y + 0.5) .. ") sent for company " .. tostring(env.myCo))
		return true
	elseif kind == "drop" then
		local s = stateOf(st)
		if not (s and s.terr and s.terr[tostring(env.myCo)]) then return false end
		env.send("f_territory_drop", {})
		return true
	end
	return false
end

-- ---------------------------------------------------------------- the window's tab
-- What the tab shows, from the file's lines: { { kind = "title"|"text"|"muted"|"button", text, label, req, payload }... }. Plain
-- data, so that the tab can be drawn by any set of widgets (M.ui below draws it with the options host's).
-- (0.6, the Hub) the items also say what they are for its tables: part ("rule", "mine", "claim", "others", "hc"), the town's or the
-- territory's centre (x, y: its « View » button), and the cells (co, town, km, status, pct, amount).
function M.uiModel(lines, T)
	T = T or M.T
	local out = {}
	local function add(kind, text, label, req, payload, ex)
		local it = { kind = kind, text = text, label = label, req = req, payload = payload }
		for k, v in pairs(ex or {}) do it[k] = v end
		out[#out + 1] = it
	end
	local rule, me, towns, terrs, hcs = nil, nil, {}, {}, {}
	for _, line in ipairs(lines or {}) do
		local f = {}
		for x in (tostring(line) .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
		if f[1] == "rule" then rule = f
		elseif f[1] == "me" then me = f
		elseif f[1] == "town" then towns[#towns + 1] = f
		elseif f[1] == "terr" then terrs[#terrs + 1] = f
		elseif f[1] == "hc" then hcs[#hcs + 1] = f end
	end
	if rule then
		add("title", T("Territoires", "Territories"), nil, nil, nil, { part = "rule" })
		local years = tonumber(rule[3]) or 0
		add("muted", fill(T("Chaque entreprise revendique une ville pendant sa première année : rayon %s km, protégé %s après la revendication. Les rues et les voies restent libres.",
			"Each company claims one town during its first year: radius %s km, protected %s after the claim. Streets and tracks stay free."), rule[2], yearsText(T, years)),
			nil, nil, nil, { part = "rule" })
		local mine = nil
		for _, t in ipairs(terrs) do if t[8] == "1" then mine = t end end
		if me and me[2] == "has" and mine then
			local status = mine[6] == "forever" and T("protégé pour toujours", "protected for good")
				or mine[6] == "on" and fill(T("protégé encore %s mois", "protected for %s more month(s)"), mine[7])
				or T("plus protégé", "no longer protected")
			add("text", fill(T("Votre territoire : %s (rayon %s km), %s.", "Your territory: %s (radius %s km), %s."), mine[4], mine[5], status), nil, nil, nil,
				{ part = "mine", town = mine[4], km = mine[5], status = status, x = num(mine[9]), y = num(mine[10]) })
			if me[4] == "1" then add("button", T("Vous pouvez encore changer d'avis pendant votre année de revendication.", "You may still change your mind during your claim year."),
				T("Renoncer", "Give up"), "drop", "", { part = "mine" }) end
		elseif me and me[2] == "claim" then
			add("text", fill(T("Choisissez la ville de votre territoire (encore %s mois) :", "Choose the town of your territory (%s more month(s)):"), me[3]),
				nil, nil, nil, { part = "claim", head = true })
			for _, t in ipairs(towns) do
				if t[4] == "1" then add("button", t[3], T("Revendiquer", "Claim"), "claim", t[2], { part = "claim", town = t[3], x = num(t[5]), y = num(t[6]) })
				else add("muted", fill(T("%s (trop près d'un autre territoire)", "%s (too close to another territory)"), t[3]), nil, nil, nil,
					{ part = "claim", town = t[3], close = true, x = num(t[5]), y = num(t[6]) }) end
			end
		elseif me and me[2] == "late" then
			add("muted", T("Le délai d'un an pour revendiquer une ville est passé.", "The year to claim a town is over."), nil, nil, nil, { part = "mine" })
		end
		local others = {}
		for _, t in ipairs(terrs) do if t[8] ~= "1" then others[#others + 1] = t end end
		if #others > 0 then
			add("title", T("Les territoires des autres", "The others' territories"), nil, nil, nil, { part = "others" })
			for _, t in ipairs(others) do
				local status = t[6] == "forever" and T("pour toujours", "for good")
					or t[6] == "on" and fill(T("encore %s mois", "%s more month(s)"), t[7])
					or T("plus protégé", "no longer protected")
				add(t[6] == "ended" and "muted" or "text", fill(T("%s : %s, rayon %s km, %s", "%s: %s, radius %s km, %s"), t[3], t[4], t[5], status), nil, nil, nil,
					{ part = "others", co = t[3], coId = tonumber(t[2]), town = t[4], km = t[5], status = status, ended = t[6] == "ended", x = num(t[9]), y = num(t[10]) })
			end
		end
	end
	if #hcs > 0 then
		add("title", T("Handicaps d'argent", "Money handicaps"), nil, nil, nil, { part = "hc" })
		add("muted", T("L'entreprise de la sauvegarde (celle de l'hôte) garde son argent.", "The savegame's company (the host's) keeps its money."), nil, nil, nil, { part = "hc" })
		for _, h in ipairs(hcs) do
			add("text", fill(T("%s : %s % de l'argent de départ (%s)", "%s: %s % of the start money (%s)"), h[3], h[4], money(tonumber(h[5]) or 0)), nil, nil, nil,
				{ part = "hc", co = h[3], coId = tonumber(h[2]), pct = h[4], amount = money(tonumber(h[5]) or 0) })
		end
	end
	return out
end

-- (0.6) the camera over a town or a territory (the window's « View » buttons; GUI only, as the journal's « Show »): from above at
-- a distance that takes in the territory's circle (km: its radius), 1500 m for a town of the claim list. Whether it moved.
function M.focus(x, y, km)
	x, y = num(x), num(y)
	if not (x and y) then return false end
	local r = (num(km) or 0) * 1000
	local d = r > 0 and math.max(1200, math.min(8000, r * 2.2)) or 1500
	return pcall(function() api.gui.camera.focusPosition(api.type.Vec3f.new(x, y, 0), d) end)
end

-- The tab, drawn with the options host's widgets: u.text(s), u.muted(s) (else u.text), u.section(s) (else u.text), u.button(label,
-- fn), u.row(list) (else the text and the button one under the other). Returns the list of widgets, top to bottom.
-- (0.6) In the Hub (u.rich): the rules, then a card for this company's territory (« View », « Give up ») or the claim list as a
-- table (each town with « View » and « Claim »), the others' territories as a table (« View »), the handicaps as a table.
function M.ui(u)
	local items = M.uiModel(u.read(M.NAME) or {}, u.T)
	if u.rich and u.card and u.table then return M.uiRich(u, items) end
	local out = {}
	local text = u.text
	local muted = u.muted or text
	-- (the options host's window gives u.title for a section's title)
	local section = u.title or u.section or text
	for _, it in ipairs(items) do
		if it.kind == "title" then out[#out + 1] = section(it.text)
		elseif it.kind == "muted" then out[#out + 1] = muted(it.text)
		elseif it.kind == "button" then
			local req, payload = it.req, it.payload
			local b = u.button(it.label, function() u.request(req, payload) end)
			if u.row then out[#out + 1] = u.row({ text(it.text), b })
			else out[#out + 1] = text(it.text); out[#out + 1] = b end
		else out[#out + 1] = text(it.text) end
	end
	return out
end

function M.uiRich(u, items)
	local T = u.T or M.T
	local W = tonumber(u.W) or 556
	local out = {}
	local function view(it, km)
		if not (it.x and it.y) then return u.text("") end
		local x, y = it.x, it.y
		return u.button(T("Voir", "View"), function() M.focus(x, y, km) end, false, true, T("Amener la caméra sur place", "Take the camera there"))
	end
	local function part(p) local l = {} for _, it in ipairs(items) do if it.part == p then l[#l + 1] = it end end return l end
	local rule = part("rule")
	if #rule == 0 then
		out[#out + 1] = u.muted(T("Aucun territoire dans cette partie.", "No territory in this game."))
		return out
	end
	-- the rules (the title starts the page's first card)
	for _, it in ipairs(rule) do out[#out + 1] = it.kind == "title" and u.title(it.text) or u.muted(it.text) end
	-- this company's territory, or its claim
	local mine = part("mine")
	if #mine > 0 then
		local kids, right = {}, {}
		for _, it in ipairs(mine) do
			if it.kind == "button" then
				local req, payload = it.req, it.payload
				kids[#kids + 1] = u.muted(it.text)
				kids[#kids + 1] = u.row({ u.button(it.label, function() u.request(req, payload) end) })
			elseif it.town then
				kids[#kids + 1] = u.text(it.text)
				if it.x then right[#right + 1] = view(it, tonumber(it.km)) end
			else kids[#kids + 1] = u.muted(it.text) end
		end
		out[#out + 1] = u.gap(10)
		out[#out + 1] = u.card(T("Votre territoire", "Your territory"), kids, { color = u.coColor and u.coColor(u.myCo) or nil, right = right, rightW = #right * 90 })
	end
	local claim = part("claim")
	if #claim > 0 then
		local lines = { { T("Ville", "Town"), T("État", "State"), "" } }
		local headText = nil
		for _, it in ipairs(claim) do
			if it.head then headText = it.text
			else
				local cells = { view(it) }
				if not it.close then
					local req, payload = it.req, it.payload
					cells[#cells + 1] = u.button(it.label, function() u.request(req, payload) end, true)
				end
				lines[#lines + 1] = { it.town or it.text, it.close and T("trop près d'un autre territoire", "too close to another territory") or T("libre", "free"), u.row(cells) }
			end
		end
		local kids = {}
		if headText then kids[#kids + 1] = u.text(headText) end
		if #lines > 1 then kids[#kids + 1] = u.table(lines, { math.floor(W * 0.45), math.floor(W * 0.3), math.floor(W * 0.25) }, true)
		else kids[#kids + 1] = u.muted(T("Aucune ville trouvée.", "No town found.")) end
		out[#out + 1] = u.gap(10)
		out[#out + 1] = u.card(T("Revendiquer une ville", "Claim a town"), kids)
	end
	-- the others' territories
	local others = part("others")
	local rows = { { T("Entreprise", "Company"), T("Ville", "Town"), T("Rayon", "Radius"), T("Protection", "Protection"), "" } }
	for _, it in ipairs(others) do
		if it.kind ~= "title" then rows[#rows + 1] = { it.co or "", it.town or "", (it.km or "?") .. " km", it.status or "", view(it, tonumber(it.km)) } end
	end
	if #rows > 1 then
		out[#out + 1] = u.gap(10)
		out[#out + 1] = u.card(T("Les territoires des autres", "The others' territories"), { u.table(rows, { 30, 26, 10, 22, 12 }, true) })
	end
	-- the money handicaps
	local hc = part("hc")
	local hrows = { { T("Entreprise", "Company"), T("Argent de départ", "Start money"), T("Montant", "Amount") } }
	local note = nil
	for _, it in ipairs(hc) do
		if it.co then hrows[#hrows + 1] = { it.co, tostring(it.pct) .. " %", it.amount or "" }
		elseif it.kind == "muted" then note = it.text end
	end
	if #hrows > 1 then
		local kids = {}
		if note then kids[#kids + 1] = u.muted(note) end
		kids[#kids + 1] = u.table(hrows, { 50, 25, 25 }, true)
		out[#out + 1] = u.gap(10)
		out[#out + 1] = u.card(T("Handicaps d'argent", "Money handicaps"), kids)
	end
	return out
end

return M
