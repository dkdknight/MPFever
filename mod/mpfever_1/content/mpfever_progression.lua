-- MPFever: a rank for each company, in the "one company per player" mode.
--
-- Ported from Juliansgith's TPF3-MP (MIT, github.com/Juliansgith/Transport-Fever-3-Multiplayer-Mod,
-- mod/tpf3mp_1/content/scripts/tpf3mp/progression.lua, docs/DECISIONS.md D23), on MPFever's registry (mpfever_co.lua).
--
-- The game's company growth script keeps ONE company, the savegame's: its experience is the highest world population it
-- has seen, its rank the game's thresholds on that. Until now every other company read the savegame company's rank. Each
-- company now has a score of its own, the sum over the towns of
--
--   population x share x rating / 100
--
-- - population: the town's residents (townBuildingSystem.getTown2personCapacitiesMap);
-- - share: the company's share of what was carried for the town: the cargo delivered to it in the last half year (the
--   game's delivery statistics per line) and the passengers travelling to and from it on lines (the game's statistics per
--   line, averaged over half a year here), the two weighed alike; a kind nobody carries there does not count;
-- - rating: the company's rating there, 0 to 100: the lowest of the town's own parts (care, traffic, noise, pollution) and
--   of the two a company earns itself on its own lines (the happiness of its passengers, its cargo on time), by the game's
--   formulas.
--
-- (0.7.1: the experience comes from the towns' growth instead, see PG.grow.)
--
-- The score is taken four times a game month, at the same game time on every game, from the simulation's state only (the
-- simulation half of the bridge, in its update). Experience is the highest score reached; the rank it reaches is the
-- game's own thresholds (company_progression_util.getLevelAndFraction); the rank taken is the company's, when the company
-- window takes it (the "applyLevel" event). It is kept in the simulation half's state, saved with the game:
--
--   prog = { quarter = n, records = { { company = id, experience =, potential =, level = }, ... },
--            passengers = { { company = id, town = entity, value = }, ... } }
--
-- With one company in the game nothing changes: the game keeps its own score.

local PG = {}

PG.WEIGHTS = { cargo = 1, passengers = 1 }
PG.PER_MONTH = 4
PG.WINDOW = 24
PG.LINES = 1000
PG.SHARED = { "urban_care", "traffic_congestion", "noise", "pollution" }
PG.PATHS = {
	progression = "/game_mechanics/company/company_progression_util.tl",
	towns = "/game_mechanics/towns/town_util.tl",
	company = "/game_mechanics/company/company_util.tl",
}

local function clamp(x, lo, hi)
	if x < lo then return lo end
	if x > hi then return hi end
	return x
end

-- the companies of the registry that have a player entity in this game, in registry order
function PG.live(reg)
	local out = {}
	for _, c in ipairs(type(reg) == "table" and reg.list or {}) do
		if type(c.ent) == "number" and c.ent >= 0 then out[#out + 1] = c end
	end
	return out
end

-- this rule, or the game's own (one company)
function PG.multi(reg)
	return type(reg) == "table" and reg.mode == "separate" and #PG.live(reg) > 1
end

function PG.ownerOf(api, entity)
	if type(entity) ~= "number" or entity < 0 then return nil end
	local ok, owner = pcall(function()
		local c = api.engine.getComponent(entity, api.type.ComponentType.PLAYER_OWNED)
		return c and c.player
	end)
	if not ok or type(owner) ~= "number" or owner < 0 then return nil end
	return owner
end

function PG.ensure(prog)
	if type(prog) ~= "table" then prog = {} end
	if type(prog.records) ~= "table" then prog.records = {} end
	if type(prog.passengers) ~= "table" then prog.passengers = {} end
	return prog
end

-- the quarter of a game month now, counted from the game's start (nil when the game does not say)
function PG.quarterNow(api)
	local ok, q = pcall(function()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		local length = api.util.getDefaultMonthDuration()
		if type(length) ~= "number" or length <= 0 or type(gt.gameTime) ~= "number" then return nil end
		return math.floor(gt.gameTime * PG.PER_MONTH / length)
	end)
	return ok and q or nil
end

-- ---------------------------------------------------------------------------------------------------- the game's formulas

function PG.happiness(unhappy, total, sensitivity)
	if sensitivity <= 0 then return 1.0 end
	if total < 15 then total = 15 end
	local average = 1 - (unhappy / total)
	local low = 1 - math.exp(-0.35667 * sensitivity)
	local s = clamp(sensitivity, 0, 1)
	local high = -1.2 * s * s + 2.2 * s
	return clamp((average - low) / (high - low), 0, 1)
end

function PG.onTime(late, delivered, sensitivity)
	if sensitivity <= 0 then return 1.0 end
	delivered = math.max(10, delivered)
	local fraction = 1 - (late / delivered)
	local low = 1 - math.exp(-0.35667 * sensitivity)
	local s = clamp(sensitivity, 0, 1)
	local high = -1.2 * s * s + 2.2 * s
	return clamp((fraction - low) / (high - low), 0, 1)
end

function PG.share(cargo, cargoAll, passengers, passengersAll, weights)
	local wc = cargoAll > 0 and (weights.cargo or 0) or 0
	local wp = passengersAll > 0 and (weights.passengers or 0) or 0
	if wc + wp <= 0 then return nil end
	local sum = 0
	if wc > 0 then sum = sum + wc * cargo / cargoAll end
	if wp > 0 then sum = sum + wp * passengers / passengersAll end
	return sum / (wc + wp)
end

-- the game's modules, in the state this runs in (nil and why when one is missing)
function PG.game(require_)
	local out = {}
	for key, path in pairs(PG.PATHS) do
		local m = nil
		for _, p in ipairs({ path, "::" .. path }) do
			local ok, x = pcall(require_, p)
			if ok and type(x) == "table" then m = x break end
		end
		if not m then return nil, path .. " did not load" end
		out[key] = m
	end
	local game = {}
	function game.levelFor(experience)
		local base = out.company.getBasePopulation()
		if type(base) ~= "number" or base <= 0 then error("the game has no base population yet", 0) end
		return (out.progression.getLevelAndFraction(base, experience))
	end
	function game.own(entity) return out.progression.getCompanyProgressionState(entity) end
	function game.base() return out.company.getBasePopulation() end
	function game.sensitivity(townState, key) return out.towns.getRatingSensitivity(townState, key) end
	function game.townStates()
		local state = out.towns.externalGetTownsState()
		local byTown = {}
		for _, t in ipairs(type(state) == "table" and state.townStates or {}) do
			local e = type(t.townEntity) == "table" and t.townEntity.entity or t.townEntity
			if type(e) == "number" then byTown[e] = t end
		end
		return byTown
	end
	return game
end

local function sharedRating(townState)
	if type(townState) ~= "table" then return nil end
	local low
	local cached = townState.cachedRatings
	if type(cached) == "table" then
		for _, key in ipairs(PG.SHARED) do
			local r = cached[key]
			local v = type(r) == "table" and r.value or nil
			if type(v) == "number" and (low == nil or v < low) then low = v end
		end
	end
	if low == nil and type(townState.authorityScore) == "number" then low = townState.authorityScore end
	return low
end

local function deliveries(byCargo)
	if type(byCargo) ~= "table" then return 0, 0 end
	local all = byCargo[-1]
	if type(all) == "table" then return all[2] or 0, all[1] or 0 end
	local delivered, late = 0, 0
	for _, pair in pairs(byCargo) do
		if type(pair) == "table" then delivered, late = delivered + (pair[2] or 0), late + (pair[1] or 0) end
	end
	return delivered, late
end

-- what each company carried for each town (towns in entity order)
function PG.measure(api, reg, game)
	local ids = {}
	for _, c in ipairs(PG.live(reg)) do ids[c.ent] = c.id end
	local owners = {}
	local function companyOf(line)
		if owners[line] == nil then
			local owner = PG.ownerOf(api, line)
			owners[line] = (owner and ids[owner]) or false
			if PG.seen then
				PG.seen.lines = PG.seen.lines + 1
				if not owners[line] then PG.seen.stranger[tostring(owner)] = (PG.seen.stranger[tostring(owner)] or 0) + 1 end
			end
		end
		return owners[line] or nil
	end
	local populations = api.engine.system.townBuildingSystem.getTown2personCapacitiesMap()
	local states = game.townStates()
	-- (what the sample saw, for the detail line of PG.tally: lines of the statistics, their owners that are no company's)
	PG.seen = { lines = 0, stranger = {}, noState = 0, popType = nil }
	local halfYear = math.floor(api.util.getDefaultYearDuration() / 2 + 0.5)
	local towns = {}
	for town, capacities in pairs(populations) do
		PG.seen.popType = PG.seen.popType or type(capacities)
		towns[#towns + 1] = { town = town, population = (type(capacities) == "table" and capacities[1]) or 0 }
	end
	table.sort(towns, function(a, b) return a.town < b.town end)
	for _, t in ipairs(towns) do
		t.state = states[t.town]
		if t.state == nil then PG.seen.noState = PG.seen.noState + 1 end
		local carried = {}
		local function of(id)
			carried[id] = carried[id] or { cargo = 0, late = 0, passengers = 0, unhappy = 0 }
			return carried[id]
		end
		local stats = api.engine.util.town.getTownDeliveriesStats(t.town, halfYear, true, false)
		local nd = 0
		for _ in pairs(type(stats) == "table" and stats or {}) do nd = nd + 1 end
		for line, byCargo in pairs(stats or {}) do
			local id = type(line) == "number" and line >= 0 and companyOf(line)
			if id then
				local delivered, late = deliveries(byCargo)
				local c = of(id)
				c.cargo, c.late = c.cargo + delivered, c.late + late
			end
		end
		local happiness = api.engine.util.town.getTownHappinessStats(t.town, PG.LINES)
		-- (the raw shape of the statistics of the most populous town, for the detail line)
		if PG.seen and (PG.seen.top == nil or t.population > PG.seen.top.population) then
			local okR, raw = pcall(function()
				local h = happiness
				local function n(x) local c = 0 if type(x) == "table" or type(x) == "userdata" then for _ in pairs(x) do c = c + 1 end end return c end
				local function tot(pair) return (pair and pair[2]) or -1 end
				local other = {}
				for _, k in ipairs({ 0, 5, 50 }) do
					local okH, hk = pcall(api.engine.util.town.getTownHappinessStats, t.town, k)
					other[#other + 1] = k .. " lines: " .. (okH and hk and (tostring(tot(hk.travellingInside)) .. "/" .. tostring(tot(hk.travellingTo and hk.travellingTo.resident)) .. "/" .. n(hk.byLine)) or "?")
				end
				local all = 0
				pcall(function() for _ in pairs(api.engine.util.town.getTownDeliveriesStats(t.town, halfYear, false, false) or {}) do all = all + 1 end end)
				return string.format("deliveries %s/%d keys (%d not per line), happiness %s, byLine %s/%d, travelling to %s/%s from %s/%s inside %s, walking %s, by car %s (asked %d lines; %s)",
					type(stats), nd, all, type(h), type(h and h.byLine), n(h and h.byLine), tostring(tot(h and h.travellingTo and h.travellingTo.resident)),
					tostring(tot(h and h.travellingTo and h.travellingTo.nonResident)), tostring(tot(h and h.travellingFrom and h.travellingFrom.resident)),
					tostring(tot(h and h.travellingFrom and h.travellingFrom.nonResident)), tostring(tot(h and h.travellingInside)),
					tostring(tot(h and h.walking)), tostring(tot(h and h.byCar)), PG.LINES, table.concat(other, ", "))
			end)
			PG.seen.top = { population = t.population, town = t.town, raw = okR and raw or ("unreadable: " .. tostring(raw)) }
		end
		-- (0.6.12, #125) the game gives these statistics as a native object (userdata), not a Lua table: read as tables only,
		-- no passenger of any line was ever counted, and the companies that carry passengers only (#125, #115: buses and
		-- trains) kept a score of 0 and rank 1 for good (a company also carrying cargo to towns scored with its cargo only).
		-- Their fields are now read whatever they are. MPFEVER_RANKNATIVE=0: tables only, as before.
		if os.getenv("MPFEVER_RANKNATIVE") ~= "0" then
			local function field(x, k)
				if x == nil then return nil end
				local ok, v = pcall(function() return x[k] end)
				if ok then return v end
				return nil
			end
			local byLine = field(happiness, "byLine")
			local list = {}
			if type(byLine) == "table" then list = byLine
			elseif byLine ~= nil then pcall(function() for i, e in pairs(byLine) do list[#list + 1] = e end end) end
			for _, entry in ipairs(list) do
				local line = field(entry, 1)
				local id = type(line) == "number" and companyOf(line) or nil
				local by = field(entry, 2)
				if id and by ~= nil then
					local c = of(id)
					for _, who in ipairs({ "resident", "nonResident" }) do
						local pair = field(by, who)
						local unhappy, total = tonumber(field(pair, 1)), tonumber(field(pair, 2))
						if total then
							c.unhappy = c.unhappy + (unhappy or 0)
							c.passengers = c.passengers + total
						end
					end
				end
			end
		else
			for _, entry in ipairs(type(happiness) == "table" and happiness.byLine or {}) do
				local id = companyOf(entry[1])
				local by = entry[2]
				if id and type(by) == "table" then
					local c = of(id)
					for _, who in ipairs({ "resident", "nonResident" }) do
						local pair = by[who]
						if type(pair) == "table" then
							c.unhappy = c.unhappy + (pair[1] or 0)
							c.passengers = c.passengers + (pair[2] or 0)
						end
					end
				end
			end
		end
		t.carried = carried
	end
	return towns
end

local function record(prog, id)
	for _, r in ipairs(prog.records) do if r.company == id then return r end end
	return nil
end

-- each company's record, begun where it has none: the savegame's company from the game's own progression (what it earned
-- before the game had companies), any other at rank 1 with nothing, as the game begins one
local function records(prog, reg, game)
	local out = {}
	for _, c in ipairs(PG.live(reg)) do
		local r = record(prog, c.id)
		if r == nil then
			r = { company = c.id, experience = 0, potential = 1, level = 1 }
			if c.id == 1 then
				local ok, own = pcall(game.own, c.ent)
				if ok and type(own) == "table" then
					r.experience = tonumber(own.experience) or 0
					r.potential = tonumber(own.potentialLevel) or 1
					r.level = tonumber(own.level) or 1
				end
			end
			prog.records[#prog.records + 1] = r
		end
		out[#out + 1] = { company = c, record = r }
	end
	return out
end

local function averaged(prog, index, id, town, count)
	local key = tostring(id) .. ":" .. tostring(town)
	local entry = index[key]
	if entry == nil then
		entry = { company = id, town = town, value = 0 }
		prog.passengers[#prog.passengers + 1] = entry
		index[key] = entry
	end
	entry.value = entry.value + (count - entry.value) / PG.WINDOW
	entry.seen = true
	return entry.value
end

-- (0.7.1, #125) Every company's experience grows as the game's own does for the savegame's company. The game's experience
-- is the world's population (the highest seen): it begins at the population of the game's start (its base, the game's first
-- rank) and grows as the towns grow. Each company's experience was its score instead (population x share x rating, a part
-- of the world's population, never above it), and the savegame's company alone began at the base: it reached rank 5 while
-- the others stayed at rank 1, their bar moving by 1 or 2 % an hour (#125 reopened, 0.7.0: 6237 against 1497, base 3427,
-- world 11368). Now every company begins at the base, as the game begins one, and is credited with the growth of each town
-- in proportion to its share of what was carried for it (the share its score uses): one company alone gets exactly the
-- game's own experience. The growth of a town nobody serves goes to every company alike. The first time (a savegame of an
-- earlier MPFever), the world's growth since its start is shared out by the companies' scores. Experience never goes down;
-- the game's own experience of the savegame's company, when higher, is kept. Kept in the state: prog.growth = { towns =
-- { { town =, pop = }, ... } }, each record's start and credit. MPFEVER_RANKGROWTH=0: the scores, as before
function PG.growthOn() return os.getenv("MPFEVER_RANKGROWTH") ~= "0" end

function PG.grow(prog, list, towns, shareOf, scores, game)
	local n = #list
	if n == 0 or type(game.base) ~= "function" then return false end
	local okB, base = pcall(game.base)
	if not okB or type(base) ~= "number" or base <= 0 then return false end
	local pop = 0
	for _, t in ipairs(towns) do pop = pop + (tonumber(t.population) or 0) end
	local g = prog.growth
	if type(g) ~= "table" then
		-- (the first time: the growth since the game's start shared out by the scores, by count when nobody scored)
		g = {}
		prog.growth = g
		local total = 0
		for _, e in ipairs(list) do total = total + math.max(0, scores[e.company.id] or 0) end
		for _, e in ipairs(list) do
			local r = e.record
			local part = total > 0 and math.max(0, scores[e.company.id] or 0) / total or 1 / n
			r.start = base
			r.credit = math.max(0, pop - base) * part
		end
	else
		local last = {}
		for _, x in ipairs(type(g.towns) == "table" and g.towns or {}) do
			if type(x) == "table" and x.town ~= nil then last[x.town] = tonumber(x.pop) end
		end
		for _, t in ipairs(towns) do
			local before = last[t.town]
			local d = before and ((tonumber(t.population) or 0) - before) or 0
			if d ~= 0 then
				local sh = shareOf[t.town]
				for _, e in ipairs(list) do
					local r = e.record
					local part = sh and (sh[e.company.id] or 0) or 1 / n
					if part ~= 0 then r.credit = (tonumber(r.credit) or 0) + d * part end
				end
			end
		end
	end
	for _, e in ipairs(list) do
		local r = e.record
		-- (a company that came later begins as the game begins one)
		if type(r.start) ~= "number" then r.start = base; r.credit = 0 end
		local x = math.floor(r.start + (tonumber(r.credit) or 0))
		if x > (tonumber(r.experience) or 0) then r.experience = x end
	end
	local keep = {}
	for _, t in ipairs(towns) do keep[#keep + 1] = { town = t.town, pop = tonumber(t.population) or 0 } end
	g.towns = keep
	return true
end

-- one sample: every company's parts of every town, its score, its experience and the rank that reaches; say(line) gets
-- one line per company (the same numbers on every game: compare them to find a difference)
function PG.tally(prog, reg, towns, game, say, now)
	local weights = PG.WEIGHTS
	local list = records(prog, reg, game)
	local index = {}
	for _, e in ipairs(prog.passengers) do
		e.seen = false
		index[tostring(e.company) .. ":" .. tostring(e.town)] = e
	end
	local scores = {}
	local shareOf = {}
	-- (the detail line: per company, the towns where it carried cargo, passengers, and where it scored)
	local detail = {}
	for _, entry in ipairs(list) do scores[entry.company.id] = 0; detail[entry.company.id] = { cargo = 0, passengers = 0, scored = 0, own0 = 0 } end
	local pop, noShared = 0, 0
	for _, t in ipairs(towns) do
		pop = pop + (tonumber(t.population) or 0)
		local cargoAll, passengersAll = 0, 0
		local averages = {}
		for _, entry in ipairs(list) do
			local id = entry.company.id
			local c = t.carried[id] or { cargo = 0, late = 0, passengers = 0, unhappy = 0 }
			averages[id] = averaged(prog, index, id, t.town, c.passengers)
			cargoAll = cargoAll + c.cargo
			passengersAll = passengersAll + averages[id]
		end
		local shared = sharedRating(t.state)
		if shared == nil then noShared = noShared + 1 end
		-- (0.7.1, #125: each company's share of what was carried for the town, for its growth, see PG.grow)
		if cargoAll > 0 or passengersAll > 0 then
			local sh = {}
			for _, entry in ipairs(list) do
				local id = entry.company.id
				local c = t.carried[id] or { cargo = 0, late = 0, passengers = 0, unhappy = 0 }
				sh[id] = PG.share(c.cargo, cargoAll, averages[id], passengersAll, weights) or 0
			end
			shareOf[t.town] = sh
		end
		for _, entry in ipairs(list) do
			local c = t.carried[entry.company.id]
			if c and c.cargo > 0 then detail[entry.company.id].cargo = detail[entry.company.id].cargo + 1 end
			if c and c.passengers > 0 then detail[entry.company.id].passengers = detail[entry.company.id].passengers + 1 end
		end
		if (cargoAll > 0 or passengersAll > 0) and shared ~= nil then
			local sensHappy = game.sensitivity(t.state, "people_happiness")
			local sensCargo = game.sensitivity(t.state, "cargo_delivery")
			for _, entry in ipairs(list) do
				local id = entry.company.id
				local c = t.carried[id] or { cargo = 0, late = 0, passengers = 0, unhappy = 0 }
				local share = PG.share(c.cargo, cargoAll, averages[id], passengersAll, weights) or 0
				if share > 0 then
					local own = math.min(shared, PG.happiness(c.unhappy, c.passengers, sensHappy), PG.onTime(c.late, c.cargo, sensCargo))
					scores[id] = scores[id] + t.population * share * 100 * clamp(own, 0, 1) / 100
					if own > 0 then detail[id].scored = detail[id].scored + 1 else detail[id].own0 = detail[id].own0 + 1 end
				end
			end
		end
	end
	-- the detail line: on the first sample of a game here, every 16 samples (4 game months), every sample with
	-- MPFEVER_RANKDETAIL=1 (the same numbers on every game: what a report needs when a score stays at 0, #125)
	if say and (PG.detailed == nil or (prog.quarter or 0) % 16 == 0 or os.getenv("MPFEVER_RANKDETAIL") == "1") then
		PG.detailed = true
		local seen = PG.seen or { lines = 0, stranger = {}, noState = 0 }
		local str = {}
		for k, n in pairs(seen.stranger) do str[#str + 1] = k .. " x" .. n end
		table.sort(str)
		local parts = {}
		for _, entry in ipairs(list) do
			local d = detail[entry.company.id]
			parts[#parts + 1] = string.format("company %d (player %s): cargo in %d, passengers in %d, scored in %d, rating 0 in %d",
				entry.company.id, tostring(entry.company.ent), d.cargo, d.passengers, d.scored, d.own0)
		end
		say(string.format("ranks detail: %d town(s), population %d (%s), %d without a state, %d without a rating; %d line(s) in the statistics, of no company: %s; %s; most populous town %s (%s): %s",
			#towns, pop, tostring(seen.popType), seen.noState, noShared, seen.lines, (#str > 0 and table.concat(str, ", ") or "none"), table.concat(parts, "; "),
			tostring(seen.top and seen.top.town), tostring(seen.top and seen.top.population), tostring(seen.top and seen.top.raw)))
	end
	local keep = {}
	for _, e in ipairs(prog.passengers) do
		if e.seen and e.value > 1e-6 then e.seen = nil; keep[#keep + 1] = e end
	end
	prog.passengers = keep
	local grown = PG.growthOn() and PG.grow(prog, list, towns, shareOf, scores, game)
	for _, entry in ipairs(list) do
		local r, id = entry.record, entry.company.id
		local experience = math.floor(scores[id])
		if not grown and experience > r.experience then r.experience = experience end
		-- the savegame's company began with the game's own experience (the highest world population), far above its score:
		-- it then stood still (issue #63: 9332, the bar stuck at 3332 of 3600) while the game's own progression went on and
		-- announced a new headquarters level that the company could not take. It follows the game's own experience while
		-- that one is higher (MPFEVER_RANK1OWN=0: as before).
		-- (0.6.3) But the game's own experience grows with what EVERY company carries (the world's population): the host's
		-- company rose with the others' work (supervisor while the others stayed near junior). It now keeps where it began
		-- (r.base: its experience less its score, taken once, saved with the game) and adds its own score only, so its bar
		-- still moves (#63) and its rank never goes down. MPFEVER_RANK1BASE=0: follows the game's own experience, as 0.6.2.
		if id == 1 and not grown and os.getenv("MPFEVER_RANK1OWN") ~= "0" then
			if os.getenv("MPFEVER_RANK1BASE") == "0" then
				local okO, own = pcall(game.own, entry.company.ent)
				local x = okO and type(own) == "table" and tonumber(own.experience) or nil
				if x and math.floor(x) > r.experience then r.experience = math.floor(x) end
			else
				if type(r.base) ~= "number" then r.base = math.max(0, r.experience - experience) end
				if r.base + experience > r.experience then r.experience = r.base + experience end
			end
		end
		local ok, level = pcall(game.levelFor, r.experience)
		if ok and type(level) == "number" then
			-- (0.6.5, #110) below the game's first threshold (the world's population when the game began) the game's levelFor
			-- answers 0: a company that had taken rank 1 was told "has reached rank 0, not 3" (six times in #109's logs). The
			-- rank reached is never below 1 nor below the rank taken. MPFEVER_RANKFLOOR=0: as before
			if os.getenv("MPFEVER_RANKFLOOR") ~= "0" then level = math.max(level, 1, r.level) end
			r.potential = level
		end
		if say then say(string.format("ranks at t=%s: company %d score %.4f, experience %d, rank %d reached, %d taken", tostring(now), id, scores[id], r.experience, r.potential, r.level)) end
	end
	return scores
end

-- the simulation half's update: a sample when a quarter of a month began since the last one. Returns true when the
-- state changed. Never raises (a reason is logged).
function PG.update(st, api, require_, say)
	local reg = st.co
	if not PG.multi(reg) then return false end
	local q = PG.quarterNow(api)
	if q == nil then return false end
	st.prog = PG.ensure(st.prog)
	if st.prog.quarter ~= nil and q <= st.prog.quarter then return false end
	st.prog.quarter = q
	local game, why = PG.game(require_)
	if not game then if say then say("ranks: not sampled, " .. tostring(why)) end return true end
	local ok, towns = pcall(PG.measure, api, reg, game)
	if not ok then if say then say("ranks: the towns' statistics did not read: " .. tostring(towns)) end return true end
	local now = nil
	pcall(function() now = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime end)
	local okT, err = pcall(PG.tally, st.prog, reg, towns, game, say, now)
	if not okT and say then say("ranks: not tallied: " .. tostring(err)) end
	return true
end

-- the company window takes a rank: above the rank taken and reached. Returns true, or false and why.
function PG.take(prog, reg, id, level)
	if type(level) ~= "number" or level ~= math.floor(level) then return false, "a rank is a whole number" end
	local r = type(prog) == "table" and type(prog.records) == "table" and record(prog, id) or nil
	if r == nil then return false, "company " .. tostring(id) .. " has no rank measured yet" end
	if level <= r.level then return false, "company " .. tostring(id) .. " has rank " .. r.level .. " already" end
	if level > r.potential then return false, "company " .. tostring(id) .. " has reached rank " .. r.potential .. ", not " .. level end
	r.level = level
	return true
end

-- the record the game's windows show for company `id` (nil: the game's own)
function PG.view(prog, id)
	if type(prog) ~= "table" or type(prog.records) ~= "table" or type(id) ~= "number" then return nil end
	local r = record(prog, id)
	if r == nil then return nil end
	-- (0.6.12, #125) the game's company window greys its Company tab while the experience is 0
	-- (game_mechanics/company/company.tl: "enabled = ... experience > 0"): a company that has not scored yet showed it greyed and
	-- its players took it for closed. Shown with at least 1 (display only: the record keeps its own). MPFEVER_RANKTAB=0: as before.
	local x = r.experience
	if os.getenv("MPFEVER_RANKTAB") ~= "0" and type(x) == "number" and x < 1 then x = 1 end
	return { experience = x, level = r.level, potentialLevel = r.potential }
end

return PG
