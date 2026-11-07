-- MPFever 0.6 game options, module "stats": the game goal, the companies' ranking and graphs, and the yearly report in the chat
-- (research note release/recherche-0.6/01-objectifs-stats.md; the owner's decisions A1-A6 and B7 in 00-REPONSES.md come first).
--
-- Three options of the lobby's "Game settings", all off by default (the contract: docs/FEATURES-0.6.md):
--   goal    (one company per player only) a company wins the game: the first one to reach the target, or the best one when the
--           goal's length, in game years (A1), is over. Criterion: the company value, the money, or the tenders won (B7, only
--           while the tenders option is on: else the value). Computer companies are ranked but win only when the host's box
--           lets them (A2). Once a goal runs its rules no longer change: the host can only cancel it (A5). The game goes on
--           after the end.
--   stats   (both modes) the Ranking tab of the MPFever window with every company's value, money and vehicles, and their
--           graphs (A4).
--   yearly  (one company per player only) at every new game year, the year in review of ALL the companies in the chat (A6),
--           written by each game in its own language.
--
-- The figures. The company value is OUR value, money - loans + resale value of the vehicles (A3), explained in the tab (the
-- "money" criterion is money - loans: a loan never brings a company nearer its goal). The
-- game's own "company value" and "transported" follow the LOCAL player on each PC (00-INDEX.md), and a client's money may lag a
-- step behind the host's. So the HOST's game measures every company once per game month (M.gui, the GUI half) and sends the
-- figures in the event f_stats_sample, as co_month in 0.5; every game applies the same figures at the same step and decides the
-- goal from them alone (M.event): the winner is the same everywhere. Nothing here moves money or changes the world.
--
-- Events (stamped by the options host, applied by every game at the same step; refused unless the host sent them):
--   f_stats_sample {mi, rows, y, mo}  the figures of game month mi: "id:b,d,vv;..." (money, loans, the vehicles' resale value),
--                               and the calendar's year and month at that month's start as the host's game reads them (the
--                               calendar may run slower than the game months: the host's word, the same on every game)
--   f_stats_cancel {seq}        the host cancels goal number seq
--
-- State (st.feat.stats, saved with the game, plain data only: the whole state is copied at every state:get(), issue #82, so one
-- month of figures is ONE string):
--   v        the format (1)
--   due      the game month (env.month(): the game time over a month's duration) whose figures are wanted, set at the start
--            of every game month; dueAt its game time (the host reads the calendar's date of it)
--   last     the last game month measured
--   m        the last M.RING months' figures, "mi|year|month|rows", oldest first (the graph over 2 years)
--   y        one entry per game year, its first figures (the 1st of January, or the start of the statistics): "year|mi|rows"
--   goal     { seq, crit, want, target, years, ai, key, startM, endM, endYM, state = "run" | "won" | "ended" | "cancelled",
--              how, winner, endAt, endKey, final = "id:score[:ai];...", names = "id=name|..." } (target: dollars, or tenders;
--              endYM: the calendar's year * 12 + month - 1 the goal ends at, from its first figures with the host's date; endM,
--              in game months, when no date came)
--   goalOff  set when the goal option is switched off after a goal: the next goal starts when it is on again
--
-- The window's file (feat_stats_<M.FILE>.txt of the session folder, written on every game by M.gui with env.write, read by
-- M.ui with u.read): see M.fileLines.

local M = {}
M.ID = "stats"

M.CRITERIA = { "value", "money", "tenders" }
M.TARGETS = { 0, 10, 25, 50, 100, 250, 500 }   -- millions of the value or the money (0: none, the best at the end wins)
M.WINS = { 0, 3, 5, 10, 20 }                     -- tenders won (0: none, the most at the end wins)
M.YEARS = { 5, 10, 20, 30, 50 }                  -- the goal's length in game years (A1)
M.RING = 24                                      -- months of figures kept for the graph over 2 years
M.FILE = "main"
M.SETTLE = 5        -- seconds a company's player entity must be known before the host reads its account (see M.measure)
M.WAIT_MAX = 20     -- seconds the host waits for the companies not settled yet before it sends the month without them
M.RESEND = 10       -- seconds before the host sends a month again that no game applied (refused during a resynchronisation)

-- ---------------------------------------------------------------- texts
-- Every text is a { French, English } pair, as the options' titles: they reach the player through the T of the lobby, the
-- window (u.T) or the bridge (env.T), which find the other languages by the English text (lang.txt).
local TX = {
	goal = { "Objectif de partie", "Game goal" },
	goalDesc = { "Une entreprise gagne la partie : la première qui atteint la cible, ou la meilleure à la fin de la durée choisie. La partie continue ensuite.",
		"A company wins the game: the first one to reach the target, or the best one when the chosen length is over. The game goes on afterwards." },
	criterion = { "Critère", "Criterion" },
	target = { "Cible (valeur ou argent)", "Target (value or money)" },
	wins = { "Cible (appels d'offres)", "Target (tenders)" },
	years = { "Durée", "Length" },
	aiCanWin = { "Les IA peuvent gagner", "Computer companies can win" },
	none = { "Aucune", "None" },
	no = { "Non", "No" },
	yes = { "Oui", "Yes" },
	nYears = { "%s ans", "%s years" },
	millions = { "%s M$", "$%s M" },
	stats = { "Classement et graphiques", "Ranking and graphs" },
	statsDesc = { "Un onglet Classement dans la fenêtre MPFever : la valeur, l'argent et les véhicules de chaque entreprise, mesurés par l'hôte chaque mois de jeu, avec leurs graphiques.",
		"A Ranking tab in the MPFever window: each company's value, money and vehicles, measured by the host every game month, with their graphs." },
	yearly = { "Bilan annuel dans le chat", "Yearly report in the chat" },
	yearlyDesc = { "À chaque nouvelle année de jeu, le bilan de toutes les entreprises dans le chat.",
		"At every new game year, the year in review of every company in the chat." },
	tab = { "Classement", "Ranking" },
	critValue = { "Valeur de l'entreprise", "Company value" },
	critMoney = { "Argent (moins les prêts)", "Money (less the loans)" },
	critTenders = { "Appels d'offres gagnés", "Tenders won" },
	rules = { "Critère : %s. Cible : %s. Durée : %s ans.", "Criterion: %s. Target: %s. Length: %s years." },
	rulesTarget = { "La première entreprise qui atteint la cible gagne ; si aucune ne l'atteint à temps, la meilleure à la fin gagne.",
		"The first company to reach the target wins; if none does in time, the best one at the end wins." },
	rulesBest = { "La meilleure entreprise à la fin gagne.", "The best company at the end wins." },
	aiNo = { "Les entreprises de l'ordinateur sont classées mais ne peuvent pas gagner.", "Computer companies are ranked but cannot win." },
	aiYes = { "Les entreprises de l'ordinateur peuvent gagner aussi.", "Computer companies can win too." },
	tendersOff = { "Les appels d'offres ne sont pas activés : l'objectif compte la valeur de l'entreprise.",
		"Tenders are not switched on: the goal counts the company value." },
	left = { "Temps restant : %s an(s) et %s mois.", "Time left: %s year(s) and %s month(s)." },
	leading = { "En tête : %s (%s sur %s).", "Leading: %s (%s of %s)." },
	leadingBest = { "En tête : %s (%s).", "Leading: %s (%s)." },
	wonTarget = { "Objectif atteint ! %s remporte la partie.", "Goal reached! %s wins the game." },
	wonTime = { "Fin de l'objectif : %s remporte la partie.", "The goal's time is up: %s wins the game." },
	endedNone = { "Fin de l'objectif : aucune entreprise ne pouvait gagner.", "The goal's time is up: no company could win." },
	cancelledHost = { "L'hôte a annulé l'objectif.", "The host cancelled the goal." },
	cancelledOff = { "L'hôte a désactivé l'objectif.", "The host switched the goal off." },
	goesOn = { "La partie continue.", "The game goes on." },
	newGoal = { "Objectif de partie : %s, cible %s, %s ans.", "Game goal: %s, target %s, %s years." },
	final = { "Classement final", "Final ranking" },
	fixed = { "Les règles d'un objectif en cours ne changent plus : l'hôte peut seulement l'annuler.",
		"A running goal's rules no longer change: the host can only cancel it." },
	btnCancel = { "Annuler l'objectif", "Cancel the goal" },
	btnConfirm = { "Confirmer l'annulation", "Yes, cancel the goal" },
	btnKeep = { "Garder l'objectif", "Keep the goal" },
	colCo = { "Entreprise", "Company" },
	colValue = { "Valeur", "Value" },
	colMoney = { "Argent", "Money" },
	colVeh = { "Véhicules", "Vehicles" },
	colTenders = { "Appels", "Tenders" },
	colTrend = { "Sur un mois", "Over a month" },
	help1 = { "Le classement compare les entreprises par leur valeur : leur argent, moins leurs prêts, plus ce que rapporterait la revente de leurs véhicules. L'hôte la mesure au début de chaque mois de jeu, la même pour tout le monde.",
		"The ranking compares the companies by their value: their money, less their loans, plus what their vehicles would fetch if sold. The host measures it at the start of each game month, the same for everybody." },
	help2 = { "« Sur un mois » montre comment la valeur a changé depuis le mois d'avant. Cliquez sur le titre d'une colonne pour trier le tableau par elle ; un second clic revient au classement.",
		"« Over a month » shows how the value changed since the month before. Click a column's title to sort the table by it; a second click goes back to the ranking." },
	help3 = { "Avec l'objectif de partie, la première entreprise qui atteint le but (ou la meilleure à la fin du temps donné) gagne ; la partie continue ensuite.",
		"With the game's goal, the first company to reach the target (or the best one when the time is up) wins; the game goes on afterwards." },
	you = { "(vous)", "(you)" },
	aiTag = { "(IA)", "(AI)" },
	company = { "Entreprise %s", "Company %s" },
	valueExplained = { "Valeur = argent - prêts + valeur de revente des véhicules, mesurée par l'hôte au début de chaque mois de jeu. Les voies et les gares ne comptent pas : ce chiffre diffère de la valeur de l'entreprise que montre le jeu.",
		"Value = money - loans + resale value of the vehicles, measured by the host at the start of every game month. Tracks and stations do not count: this figure differs from the game's own company value." },
	moneyExplained = { "Argent = argent en banque moins les prêts.", "Money = cash in the bank minus the loans." },
	noData = { "Pas encore de chiffres (une mesure par mois de jeu).", "No figures yet (one each game month)." },
	lastFigures = { "Chiffres du %s/%s.", "Figures of %s/%s." },
	history = { "Évolution", "History" },
	range2y = { "2 ans (mensuel)", "2 years (monthly)" },
	rangeAll = { "Toute la partie (annuel)", "Whole game (yearly)" },
	now = { "Maintenant", "Now" },
	monthsAgo = { "Il y a %s mois", "%s months ago" },
	review = { "Bilan %s :", "%s in review:" },
	reviewLine = { "%s. %s : valeur %s (%s), argent %s, véhicules %s", "%s. %s: value %s (%s), money %s, vehicles %s" },
	reviewTenders = { ", appels gagnés : %s", ", tenders won: %s" },
	newCo = { "nouvelle", "new" },
}
M.TX = TX

-- a text of TX in the language of `T` (a T(fr, en) function; English without one), each %s taking the next value (put in with
-- gsub: a value may contain % itself)
local function tr(T, pair, ...)
	local s = pair[2]
	if type(T) == "function" then
		local ok, r = pcall(T, pair[1], pair[2])
		if ok and type(r) == "string" then s = r end
	end
	local values, i = { ... }, 0
	if #values == 0 then return s end
	return (s:gsub("%%s", function() i = i + 1; return tostring(values[i] == nil and "" or values[i]) end))
end
M.tr = tr

-- ---------------------------------------------------------------- the options
local function critName(T, c)
	if c == "money" then return tr(T, TX.critMoney) end
	if c == "tenders" then return tr(T, TX.critTenders) end
	return tr(T, TX.critValue)
end

M.OPTIONS = {
	{ id = "goal", title = TX.goal, desc = TX.goalDesc, modes = "separate",
		params = {
			{ id = "criterion", label = TX.criterion, values = M.CRITERIA, default = "value",
				show = function(v, T) return critName(T, tostring(v)) end },
			{ id = "target", label = TX.target, values = M.TARGETS, default = 0,
				show = function(v, T) if tonumber(v) == 0 then return tr(T, TX.none) end return tr(T, TX.millions, v) end },
			-- (only the tenders criterion reads it: `when` tells the lobby, if it can, to show it only then)
			{ id = "wins", label = TX.wins, values = M.WINS, default = 5, when = { criterion = "tenders" },
				show = function(v, T) if tonumber(v) == 0 then return tr(T, TX.none) end return tostring(v) end },
			{ id = "years", label = TX.years, values = M.YEARS, default = 20,
				show = function(v, T) return tr(T, TX.nYears, v) end },
			{ id = "ai_can_win", label = TX.aiCanWin, values = { 0, 1 }, default = 0,
				show = function(v, T) return tr(T, tostring(v) == "1" and TX.yes or TX.no) end },
		} },
	{ id = "stats", title = TX.stats, desc = TX.statsDesc, modes = "both" },
	{ id = "yearly", title = TX.yearly, desc = TX.yearlyDesc, modes = "separate" },
}
M.EVENTS = { f_stats_sample = true, f_stats_cancel = true }
M.TAB = { id = "stats", title = TX.tab }

-- ---------------------------------------------------------------- reading the options (the same on every game: st.opts)
local function on(env, id)
	if type(env) ~= "table" or type(env.on) ~= "function" then return false end
	local ok, v = pcall(env.on, id)
	return ok and (v == true or v == 1 or v == "1")
end

local function param(env, opt, pid)
	if type(env) ~= "table" or type(env.param) ~= "function" then return nil end
	local ok, v = pcall(env.param, opt, pid)
	return ok and v or nil
end

local function inList(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

-- "separate" (one company per player) or "shared": env.mode in the simulation half; the GUI half's env has none, the companies
-- registry tells it
local function modeOf(st, env)
	if type(env) == "table" and (env.mode == "separate" or env.mode == "shared") then return env.mode end
	local reg = type(st) == "table" and st.co or nil
	return (type(reg) == "table" and reg.mode == "separate") and "separate" or "shared"
end

function M.goalOn(st, env) return modeOf(st, env) == "separate" and on(env, "goal") end
function M.statsOn(st, env) return on(env, "stats") end
function M.yearlyOn(st, env) return modeOf(st, env) == "separate" and on(env, "yearly") end
function M.anyOn(st, env) return M.statsOn(st, env) or M.goalOn(st, env) or M.yearlyOn(st, env) end

-- the goal's rules as the options say now: { want, target, wins, years, ai, key } (a value no list holds: the default)
function M.rules(env)
	local want = tostring(param(env, "goal", "criterion") or "value")
	if not inList(M.CRITERIA, want) then want = "value" end
	local target = tonumber(param(env, "goal", "target"))
	if not inList(M.TARGETS, target) then target = 0 end
	local wins = tonumber(param(env, "goal", "wins"))
	if not inList(M.WINS, wins) then wins = 5 end
	local years = tonumber(param(env, "goal", "years"))
	if not inList(M.YEARS, years) then years = 20 end
	local a = param(env, "goal", "ai_can_win")
	local ai = a == true or tostring(a) == "1" or tostring(a) == "true"
	return { want = want, target = target, wins = wins, years = years, ai = ai,
		key = want .. "|" .. target .. "|" .. wins .. "|" .. years .. "|" .. (ai and 1 or 0) }
end

-- ---------------------------------------------------------------- what the integration may replace
-- The calendar's year and month of game month `mi`: those the host's figures came with (param.y, param.mo: the host's game read
-- the calendar's date at the month's start, see M.hostDate), else counted from the index alone (env.month() is the game time
-- over a month's duration, from 0: "year" mi // 12, month mi % 12 + 1). The third value: whether the date is the host's.
-- Either way the same on every game (the event's figures, or the index).
function M.calendar(mi, param)
	mi = math.floor(tonumber(mi) or 0)
	local y = type(param) == "table" and tonumber(param.y) or nil
	local mo = type(param) == "table" and tonumber(param.mo) or nil
	if y and mo and y == math.floor(y) and mo == math.floor(mo) and mo >= 1 and mo <= 12 and y > -100000 and y < 100000 then
		return y, mo, true
	end
	return math.floor(mi / 12), mi % 12 + 1, false
end

-- whether the tenders count (B7): their option on (the same on every game, st.opts)
function M.tendersOn(st, env)
	return on(env, "tenders")
end

-- the tenders company `id` won: the tenders module's own count (mpfever_feat_tenders.lua's M.wins, reached through the options
-- host, env.module) while both are on; else read from its state (simulation data, the same everywhere): its `wins` table
-- ({ ["<id>"] = n }), else its `done` list ({ status = "won", winner = id }...)
function M.tenderWins(st, id, env)
	if type(env) == "table" and type(env.module) == "function" and on(env, "tenders") then
		local okM, TM = pcall(env.module, "tenders")
		if okM and type(TM) == "table" and type(TM.wins) == "function" then
			local ok, n = pcall(TM.wins, st, id)
			if ok and tonumber(n) then return math.max(0, math.floor(tonumber(n))) end
		end
	end
	local t = type(st) == "table" and type(st.feat) == "table" and st.feat.tenders or nil
	if type(t) ~= "table" then return 0 end
	if type(t.wins) == "table" then
		local n = tonumber(t.wins[tostring(id)]) or tonumber(t.wins[id])
		return n and math.max(0, math.floor(n)) or 0
	end
	local n = 0
	for _, d in ipairs(type(t.done) == "table" and t.done or {}) do
		if type(d) == "table" and tonumber(d.winner) == id and (d.status == nil or d.status == "won") then n = n + 1 end
	end
	return n
end

local function isAi(c)
	return type(c) == "table" and (c.ai == true or (type(c.key) == "string" and c.key:sub(1, 3) == "ai:"))
end

local function cleanName(n)
	return (tostring(n or ""):gsub("[%c|=;:\t]", " "))
end

-- the companies in the simulation, sorted by number: { id, name, ai, gone } (env.companies(), the registry's `gone` mark added)
function M.simCompanies(st, env)
	local reg = type(st) == "table" and type(st.co) == "table" and st.co or nil
	local function regCo(id)
		for _, c in ipairs(reg and reg.list or {}) do if c.id == id then return c end end
		return nil
	end
	local out = {}
	local ok, list = false, nil
	if type(env) == "table" and type(env.companies) == "function" then ok, list = pcall(env.companies) end
	if ok and type(list) == "table" then
		for _, c in ipairs(list) do
			local id = tonumber(type(c) == "table" and c.id)
			if id then
				local r = regCo(id)
				out[#out + 1] = { id = id, name = c.name or (r and r.name), ai = isAi(c) or isAi(r), gone = c.gone or (r and r.gone) or nil }
			end
		end
	elseif reg and reg.mode == "separate" then
		for _, c in ipairs(reg.list or {}) do
			if tonumber(c.id) then out[#out + 1] = { id = c.id, name = c.name, ai = isAi(c), gone = c.gone } end
		end
	else
		out[1] = { id = 1, name = "", ai = false }
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

-- ---------------------------------------------------------------- the figures of a month
-- a whole number as text, every digit (not "1e+14" as tostring writes it; "%d" takes only 32 bits in a Lua built with a 32-bit
-- long, as on Windows: money above $2.1 billion would fail there). Exact up to 2^53, and never "-0".
local function num(x) return string.format("%.0f", math.floor(tonumber(x) or 0) + 0) end
M.num = num

-- rows: { { id, b, d, vv }... } sorted by id <-> "id:b,d,vv;..." (whole numbers; b may be below zero)
function M.rowsText(rows)
	local t = {}
	for _, r in ipairs(rows) do
		t[#t + 1] = num(r.id) .. ":" .. num(r.b) .. "," .. num(r.d) .. "," .. num(r.vv)
	end
	return table.concat(t, ";")
end

-- the rows of a text, nil when it is not one (each company once, at most 64, sorted by id)
function M.parseRows(s)
	if type(s) ~= "string" or #s > 4000 then return nil end
	local rows, seen = {}, {}
	if s == "" then return rows end
	for part in (s .. ";"):gmatch("([^;]*);") do
		local id, b, d, vv = part:match("^(%d+):(%-?%d+),(%-?%d+),(%-?%d+)$")
		id, b, d, vv = tonumber(id), tonumber(b), tonumber(d), tonumber(vv)
		if not (id and b and d and vv) or seen[id] or #rows >= 64 or math.abs(b) > 1e15 or math.abs(d) > 1e15 or math.abs(vv) > 1e15 then
			return nil
		end
		seen[id] = true
		rows[#rows + 1] = { id = id, b = b, d = math.max(0, d), vv = math.max(0, vv) }
	end
	table.sort(rows, function(x, y) return x.id < y.id end)
	return rows
end

-- the scores of one row
function M.value(r) return r.b - r.d + r.vv end
function M.money(r) return r.b - r.d end

-- "mi|year|month|rows" and "year|mi|rows"
local function splitMonth(e)
	local mi, y, mo, rows = tostring(e):match("^(%-?%d+)|(%-?%d+)|(%d+)|(.*)$")
	return tonumber(mi), tonumber(y), tonumber(mo), rows
end
local function splitYear(e)
	local y, mi, rows = tostring(e):match("^(%-?%d+)|(%-?%d+)|(.*)$")
	return tonumber(y), tonumber(mi), rows
end
M.splitMonth, M.splitYear = splitMonth, splitYear

-- the newest row of company `id` in the months kept (a company the host could not read this month keeps its last figures)
function M.latestRow(s, id)
	for k = #(s.m or {}), 1, -1 do
		local _, _, _, text = splitMonth(s.m[k])
		for _, r in ipairs(M.parseRows(text) or {}) do if r.id == id then return r end end
	end
	return nil
end

-- the live companies' scores by a criterion, best first (the score, then the smaller number): { id, name, ai, score }
function M.standings(st, s, env, crit)
	local list = {}
	for _, c in ipairs(M.simCompanies(st, env)) do
		if not c.gone then
			local score = nil
			if crit == "tenders" then score = M.tenderWins(st, c.id, env)
			else
				local r = M.latestRow(s, c.id)
				if r then score = crit == "money" and M.money(r) or M.value(r) end
			end
			if score then list[#list + 1] = { id = c.id, name = c.name, ai = c.ai, score = score } end
		end
	end
	table.sort(list, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.id < b.id end)
	return list
end

-- ---------------------------------------------------------------- SIMULATION half (every game, the same step)
local function fromHost(param, env)
	if type(env) == "table" and type(env.fromHost) == "function" then
		local ok, r = pcall(env.fromHost, param)
		return ok and r == true
	end
	-- (as mpfever_eco.lua: the host, or a dedicated server, sends under its plain name; a player who joined has "#n" after it)
	local origin = param.mpfFrom
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

local function log(env, text) if type(env) == "table" and type(env.log) == "function" then pcall(env.log, "feat stats: " .. text) end end

-- The goal's end: its state, the winner (nil: none), how, and the final ranking frozen with the companies' names of the moment.
-- endKey: the options' rules at the end; the next goal starts only when the host changes them AFTER the end (a change refused
-- while the goal ran does not start a new goal by itself the month it ends), or switches the option off and on again.
local function endGoal(g, state, how, winner, endAt, list, env)
	g.state, g.how, g.winner, g.endAt = state, how, winner, endAt
	g.endKey = env and M.rules(env).key or g.key
	if list then
		local f, n = {}, {}
		for _, c in ipairs(list) do
			f[#f + 1] = num(c.id) .. ":" .. num(c.score) .. (c.ai and ":ai" or "")
			n[#n + 1] = c.id .. "=" .. cleanName(c.name)
		end
		g.final, g.names = table.concat(f, ";"), table.concat(n, "|")
	end
end

-- The goal's turn, at the start of every game month: a goal starts when the option is on and none runs (the first one, or a
-- new one once the last ended and the host changed its rules or switched the option off and on again); a running goal ends,
-- cancelled, when the option is switched off. The rules are copied into the goal: changing the options later changes nothing
-- of a running goal (A5).
function M.goalTurn(st, s, env)
	local g = s.goal
	if M.goalOn(st, env) then
		local r = M.rules(env)
		local fresh = not g or (g.state ~= "run" and ((g.endKey or g.key) ~= r.key or s.goalOff))
		if fresh and s.due then
			local crit, target = r.want, r.target * 1000000
			if crit == "tenders" then
				-- (B7: the tenders count only while their option is on; else the goal counts the value, and says so)
				if M.tendersOn(st, env) then target = r.wins else crit = "value" end
			end
			s.goal = { seq = (g and g.seq or 0) + 1, crit = crit, want = r.want, target = target, years = r.years, ai = r.ai,
				key = r.key, startM = s.due, endM = s.due + r.years * 12, state = "run" }
			s.goalOff = nil
			log(env, "goal " .. s.goal.seq .. ": " .. crit .. " target " .. target .. " in " .. r.years .. " years from month "
				.. s.due .. (r.ai and " (computer companies can win)" or ""))
		end
	elseif g then
		if g.state == "run" then
			endGoal(g, "cancelled", "off", nil, s.last or s.due, nil, nil)
			log(env, "goal " .. g.seq .. " cancelled: the option is off")
		end
		s.goalOff = true
	end
end

-- the goal's check after the figures of month `mi`: the first company that reaches the target wins (the best one when several
-- do, then the smaller number); when the length is over, the best one wins. Computer companies win only when the rules let them.
-- ym: the calendar's year * 12 + month - 1 of the figures when the host's date came with them (nil else). The length is counted in
-- the calendar's years (A1) once the goal's first figures came with a date (endYM), else in game months (endM).
function M.check(st, s, env, mi, ym)
	local g = s.goal
	if not (g and g.state == "run") or not M.goalOn(st, env) then return end
	if ym and not g.endYM and mi >= (g.startM or mi) then
		g.endYM = ym + math.max(0, (g.endM or mi) - mi)
		log(env, "goal " .. g.seq .. " ends at the calendar's " .. math.floor(g.endYM / 12) .. "/" .. (g.endYM % 12 + 1)
			.. " (figures of month " .. mi .. " dated " .. math.floor(ym / 12) .. "/" .. (ym % 12 + 1) .. ")")
	end
	local list = M.standings(st, s, env, g.crit)
	local function eligible(c) return g.ai or not c.ai end
	if (g.target or 0) > 0 then
		for _, c in ipairs(list) do
			if eligible(c) and c.score >= g.target then
				endGoal(g, "won", "target", c.id, mi, list, env)
				log(env, "goal " .. g.seq .. " reached by company " .. c.id .. " at month " .. mi .. " (" .. c.score .. ")")
				return
			end
		end
	end
	local over
	-- (a goal dated by the calendar ends by the calendar only: figures that came without a date do not end it)
	if g.endYM then over = ym ~= nil and ym >= g.endYM else over = mi >= (g.endM or mi) end
	if over then
		for _, c in ipairs(list) do
			if eligible(c) then
				endGoal(g, "won", "time", c.id, mi, list, env)
				log(env, "goal " .. g.seq .. " over at month " .. mi .. ": company " .. c.id .. " wins (" .. c.score .. ")")
				return
			end
		end
		endGoal(g, "ended", "none", nil, mi, list, env)
		log(env, "goal " .. g.seq .. " over at month " .. mi .. ": no company could win")
	end
end

-- once at the start of every game month
function M.month(st, env)
	if not M.anyOn(st, env) then
		-- (every option off: nothing at all, but a goal still running in a state made before is cancelled, as a switch-off is)
		local s = type(st.feat) == "table" and st.feat[M.ID] or nil
		if type(s) == "table" and s.goal then M.goalTurn(st, s, env) end
		return
	end
	local s = env.state(st)
	s.v = s.v or 1
	s.m = s.m or {}
	s.y = s.y or {}
	local mi = tonumber(type(env.month) == "function" and env.month() or nil)
	if mi then
		mi = math.floor(mi)
		-- (months skipped: this module was off meanwhile, its three options off, so the options host called nothing here: a goal
		-- that ran then was switched off with them, as if this had seen it)
		local g = s.goal
		if s.due and mi > s.due + 1 and type(g) == "table" and g.state == "run" then
			endGoal(g, "cancelled", "off", nil, s.last or s.due, nil, nil)
			s.goalOff = true
			log(env, "goal " .. g.seq .. " cancelled: the options were off from month " .. (s.due + 1) .. " to " .. (mi - 1))
		end
		if not s.due or mi > s.due then
			s.due = mi
			s.dueAt = tonumber(type(env.gameTime) == "function" and env.gameTime() or nil)
		end
	end
	M.goalTurn(st, s, env)
end

function M.event(st, name, param, env)
	if not M.EVENTS[name] or not M.anyOn(st, env) then return end
	param = type(param) == "table" and param or {}
	local s = env.state(st)
	s.m = s.m or {}
	s.y = s.y or {}
	local function refuse(why) log(env, name .. " of '" .. tostring(param.mpfFrom) .. "' refused: " .. why) end
	if not fromHost(param, env) then return refuse("not the host") end
	if name == "f_stats_sample" then
		local mi = tonumber(param.mi)
		if not mi or mi ~= math.floor(mi) then return refuse("month " .. tostring(param.mi)) end
		if s.last and mi <= s.last then return refuse("month " .. mi .. " already measured") end
		if not s.due or mi > s.due then return refuse("month " .. mi .. " not started here") end
		local rows = M.parseRows(param.rows)
		if not rows then return refuse("figures") end
		local text = M.rowsText(rows)
		local year, month, dated = M.calendar(mi, param)
		s.last = mi
		s.m[#s.m + 1] = num(mi) .. "|" .. num(year) .. "|" .. num(month) .. "|" .. text
		while #s.m > M.RING do table.remove(s.m, 1) end
		local lastYear = #s.y > 0 and splitYear(s.y[#s.y]) or nil
		if not lastYear or year > lastYear then s.y[#s.y + 1] = num(year) .. "|" .. num(mi) .. "|" .. text end
		-- (once a game month on every game: what the in-game test compares between the games' mod.log)
		log(env, "month " .. mi .. " (" .. year .. "/" .. month .. (dated and "" or ", no date from the host") .. ") taken: " .. text)
		M.check(st, s, env, mi, dated and (year * 12 + month - 1) or nil)
	elseif name == "f_stats_cancel" then
		local g = s.goal
		if not (g and g.state == "run") then return refuse("no goal running") end
		if tonumber(param.seq) ~= g.seq then return refuse("goal " .. tostring(param.seq) .. " is not the running one") end
		endGoal(g, "cancelled", "host", nil, s.last or s.due, nil, env)
		log(env, "goal " .. g.seq .. " cancelled by the host")
	end
end

-- ---------------------------------------------------------------- GUI half of the bridge (every game, about once a second)
-- This game's own memory (never saved, never sent): the notices told, the host's sending, the companies' first sight.
M.g = {}

local function realTime(env)
	if type(env) == "table" and type(env.realTime) == "function" then
		local ok, t = pcall(env.realTime)
		if ok and tonumber(t) then return tonumber(t) end
	end
	return os.clock()
end

-- the T of this game's language: the env's, else the bridge's common module (C.T), else English
local function guiT(env)
	if type(env) == "table" and type(env.T) == "function" then return env.T end
	if M.C == nil then
		M.C = false
		if type(ug_require) == "function" then
			local ok, C = pcall(ug_require, "mpfever_common.lua")
			if not (ok and type(C) == "table") then ok, C = pcall(ug_require, "mpfever_1::/mpfever_common.lua") end
			if ok and type(C) == "table" and type(C.T) == "function" then M.C = C end
		end
	end
	return M.C and M.C.T or nil
end

-- a company colour (r, g, b in 0..1) from its palette index (mpfever_co.lua's palette), grey when the palette is not reachable
function M.rgb(index)
	if M.CO == nil then
		M.CO = false
		if type(ug_require) == "function" then
			local ok, CO = pcall(ug_require, "mpfever_co.lua")
			if not (ok and type(CO) == "table") then ok, CO = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
			if ok and type(CO) == "table" and type(CO.rgb) == "function" then M.CO = CO end
		end
	end
	if M.CO then
		local ok, r, g, b = pcall(M.CO.rgb, tonumber(index) or 1)
		if ok and tonumber(r) then return r, g, b end
	end
	return 0.7, 0.7, 0.7
end

-- The companies as this game's GUI sees them: { id, ent, name, ai, gone, color } sorted by number, gone ones included (the
-- yearly report and the final ranking name them). `ent` is this game's own player entity of the company.
function M.guiCompanies(st, env)
	local out = {}
	local reg = type(st) == "table" and type(st.co) == "table" and st.co or nil
	if reg and reg.mode == "separate" then
		for _, c in ipairs(reg.list or {}) do
			if tonumber(c.id) then out[#out + 1] = { id = c.id, ent = c.ent, name = c.name, ai = isAi(c), gone = c.gone, color = c.color } end
		end
	else
		-- (one company for everybody: the game's own player)
		local ok, ent = pcall(function() return api.engine.util.getPlayer() end)
		out[1] = { id = 1, ent = ok and ent or nil, name = "", ai = false, color = 1 }
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

-- every company's vehicles' resale value: player entity -> sum (one pass over the vehicles, only on the host, once a month)
function M.vehicleValues()
	local map = {}
	pcall(function()
		api.engine.forEachEntityWithComponent(function(v)
			local po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED)
			if po and type(po.player) == "number" and po.player >= 0 then
				local ok, val = pcall(api.engine.util.vehicle.getDepreciatedValue, v)
				if ok and tonumber(val) then map[po.player] = (map[po.player] or 0) + tonumber(val) end
			end
		end, api.type.ComponentType.TRANSPORT_VEHICLE)
	end)
	return map
end

-- The host's look at every company: { { id, b, d, vv }... } and how many companies could not be read yet. A company's player
-- entity is read only once it has been known for M.SETTLE seconds and still exists (as the window's U.companyList: the engine
-- asserts, and the game closes, when the interface reads the account of a player entity the simulation is still adding, or of
-- one gone with the previous game). Money: the bank balance; loans: the account's loan (what is left to repay of the loans
-- taken: the game's loan script books a loan and its repayments as LOAN entries of the company's journal, loan_util.makeLoan,
-- and the bridge books those of the other companies the same way; its sign is not known for sure: its size is taken). Each
-- company's first reading of a session is logged with the registry's own count of its loans to compare (st: the GUI's state).
-- With companies not settled yet, nothing is read (nil) unless `force`: the month then goes without them.
function M.measure(cos, env, now, force, st)
	M.g.seen = M.g.seen or {}
	local ready, unsettled = {}, 0
	for _, c in ipairs(cos) do
		if not c.gone and type(c.ent) == "number" and c.ent >= 0 then
			M.g.seen[c.ent] = M.g.seen[c.ent] or now
			local settled = now - M.g.seen[c.ent] >= M.SETTLE
			if settled then
				local okE, ex = pcall(api.engine.entityExists, c.ent)
				settled = okE and ex == true
			end
			if settled then ready[#ready + 1] = c else unsettled = unsettled + 1 end
		end
	end
	if unsettled > 0 and not force then return nil, unsettled end
	-- (figures the events can carry: a game of infinite money has a balance far beyond any goal)
	local function clamp(x) return math.max(-1e14, math.min(1e14, math.floor(x))) end
	local rows, vv = {}, nil
	for _, c in ipairs(ready) do
		local b, d = nil, 0
		pcall(function() b = api.engine.util.finance.getPlayersBalance(c.ent) end)
		pcall(function()
			local acc = api.engine.getComponent(c.ent, api.type.ComponentType.ACCOUNT)
			if acc then
				if not tonumber(b) then b = acc.balance end
				d = math.abs(tonumber(acc.loan) or 0)
			end
		end)
		if tonumber(b) then
			vv = vv or M.vehicleValues()
			rows[#rows + 1] = { id = c.id, b = clamp(tonumber(b)), d = clamp(d), vv = clamp(vv[c.ent] or 0) }
			M.g.logged = M.g.logged or {}
			if not M.g.logged[c.ent] then
				M.g.logged[c.ent] = true
				local left = M.registryLoanLeft(st, c.id)
				log(env, "company " .. c.id .. " (player entity " .. c.ent .. ") read: balance " .. num(b) .. ", ACCOUNT.loan " .. num(d)
					.. (left and (", loans left in the registry " .. num(left)) or "") .. ", vehicles' resale value " .. num(vv[c.ent] or 0))
			end
		end
	end
	return rows, unsettled
end

-- What the companies registry (the bridge's loans of the companies other than the savegame's, st.co.loan) says is left to repay
-- of a company's loans, as the computer companies count it (mpfever_ai.lua's loanBook); nil when the registry has none for it.
-- For the log only: the figures sent are the account's.
function M.registryLoanLeft(st, id)
	local lt = type(st) == "table" and type(st.co) == "table" and type(st.co.loan) == "table" and st.co.loan[id] or nil
	if type(lt) ~= "table" then return nil end
	local month = nil
	pcall(function() month = api.util.getDefaultMonthDuration() end)
	month = tonumber(month)
	if not (month and month > 0) then return nil end
	local owe = 0
	for _, l in ipairs(type(lt.obtainedLoans) == "table" and lt.obtainedLoans or {}) do
		local months = math.max(1, math.floor((tonumber(l.duration) or 0) / month + 0.5))
		owe = owe + math.max(0, (tonumber(l.amount) or 0) - (tonumber(l.timesPaid) or 0) * (tonumber(l.amount) or 0) / months)
	end
	return owe
end

-- The calendar's date at the start of the month wanted (its game time, s.dueAt, set by the simulation): y, mo as the host's
-- game reads them (env.date, the engine's calendar), nil when it cannot be read (the games then count the month's index alone)
function M.hostDate(s, env)
	if not (type(env) == "table" and type(env.date) == "function") then return nil end
	local ok, d = pcall(env.date, tonumber(s.dueAt))
	if not (ok and type(d) == "table") then return nil end
	local y, mo = tonumber(d.year), tonumber(d.month)
	if not (y and mo) then return nil end
	return math.floor(y), math.floor(mo)
end

-- the host's figures of the month wanted (s.due), sent once and again after M.RESEND seconds until a game applied them
function M.hostSample(st, s, env, now)
	local G = M.g
	if not (s and s.due) or (s.last and s.last >= s.due) then G.waitFor = nil; return end
	if G.sentFor == s.due and now - (G.sentAt or 0) < M.RESEND then return end
	if G.waitFor ~= s.due then G.waitFor, G.waitSince = s.due, now end
	local rows, unsettled = M.measure(M.guiCompanies(st, env), env, now, now - G.waitSince >= M.WAIT_MAX, st)
	if not rows then return end
	if type(env.send) ~= "function" then return end
	local p = { mi = s.due, rows = M.rowsText(rows) }
	p.y, p.mo = M.hostDate(s, env)
	env.send("f_stats_sample", p)
	log(env, "month " .. s.due .. " measured and sent (" .. #rows .. " companies" .. ((unsettled or 0) > 0 and (", " .. unsettled .. " not readable yet") or "")
		.. (G.sentFor == s.due and ", again" or "") .. ", calendar " .. tostring(p.y) .. "/" .. tostring(p.mo) .. " at game time " .. tostring(s.dueAt) .. ")")
	G.sentFor, G.sentAt = s.due, now
end

local function nameOf(cos, id, T)
	for _, c in ipairs(cos) do
		if c.id == id then
			if type(c.name) == "string" and c.name ~= "" then return c.name end
			break
		end
	end
	return tr(T, TX.company, id)
end

-- compact money: $12.3 M, $850 k, $1234 (the window's tables and the chat)
function M.fmt(n, signed)
	n = tonumber(n) or 0
	local a = math.abs(n)
	local s
	if a >= 1e9 then s = string.format("%.2f G", a / 1e9)
	elseif a >= 1e6 then s = string.format("%.1f M", a / 1e6)
	elseif a >= 1e4 then s = string.format("%.0f k", a / 1e3)
	else s = num(a + 0.5) end
	return (n < 0 and "-" or (signed and "+" or "")) .. "$" .. s
end

-- the target of a goal in words
local function targetText(g, T)
	if (g.target or 0) <= 0 then return tr(T, TX.none) end
	if g.crit == "tenders" then return tostring(g.target) end
	return M.fmt(g.target)
end
M.targetText = targetText

-- the lines of the year in review of entry k of s.y (k >= 2): the year that ended, every company of its figures (A6) by value
function M.reviewLines(st, s, k, T, cos, env)
	local y, _, text = splitYear(s.y[k])
	local _, _, before = splitYear(s.y[k - 1])
	local rows = M.parseRows(text) or {}
	local prev = {}
	for _, r in ipairs(M.parseRows(before) or {}) do prev[r.id] = r end
	table.sort(rows, function(a, b)
		local va, vb = M.value(a), M.value(b)
		if va ~= vb then return va > vb end
		return a.id < b.id
	end)
	local tenders = M.tendersOn(st, env)
	local out = { tr(T, TX.review, (y or 0) - 1) }
	for i, r in ipairs(rows) do
		local co = nil
		for _, c in ipairs(cos) do if c.id == r.id then co = c end end
		local delta = prev[r.id] and M.fmt(M.value(r) - M.value(prev[r.id]), true) or tr(T, TX.newCo)
		local line = tr(T, TX.reviewLine, i, nameOf(cos, r.id, T) .. ((co and co.ai) and (" " .. tr(T, TX.aiTag)) or ""),
			M.fmt(M.value(r)), delta, M.fmt(M.money(r)), M.fmt(r.vv))
		if tenders then line = line .. tr(T, TX.reviewTenders, M.tenderWins(st, r.id, env)) end
		out[#out + 1] = line
	end
	return out
end

-- the goal in a sentence (the chat's notice of a new goal)
local function goalShort(g, T)
	return tr(T, TX.newGoal, critName(T, g.crit), targetText(g, T), g.years)
end

-- what changed, told in this game's chat in its own language: a new goal, its end, a new game year. What a state already holds
-- at this game's first look (a load, a resynchronisation's reload) is not told again.
function M.notices(st, s, env, T)
	local G = M.g
	local first = not G.looked
	G.looked = true
	local cos = nil
	local function chat(text) if type(env.chat) == "function" then pcall(env.chat, text) end end
	-- the goal (also once its option is off: the switch-off is told)
	local g = type(s) == "table" and type(s.goal) == "table" and s.goal or nil
	local gk = g and (g.seq .. ":" .. tostring(g.state)) or ""
	if first or G.goalSeen == nil then G.goalSeen = gk
	elseif gk ~= G.goalSeen then
		G.goalSeen = gk
		if g then
			cos = cos or M.guiCompanies(st, env)
			if g.state == "run" then chat(goalShort(g, T))
			elseif g.state == "won" then
				chat(tr(T, g.how == "target" and TX.wonTarget or TX.wonTime, nameOf(cos, g.winner, T)) .. " " .. tr(T, TX.goesOn))
			elseif g.state == "ended" then chat(tr(T, TX.endedNone) .. " " .. tr(T, TX.goesOn))
			elseif g.state == "cancelled" then chat(tr(T, g.how == "off" and TX.cancelledOff or TX.cancelledHost))
			end
		end
	end
	-- the year in review
	if type(s) == "table" and type(s.y) == "table" and #s.y > 0 and M.yearlyOn(st, env) then
		local lastYear = splitYear(s.y[#s.y])
		if first or G.yearSeen == nil then G.yearSeen = lastYear
		elseif lastYear and lastYear > G.yearSeen then
			cos = cos or M.guiCompanies(st, env)
			for k = 2, #s.y do
				local y = splitYear(s.y[k])
				if y and y > G.yearSeen then
					for _, line in ipairs(M.reviewLines(st, s, k, T, cos, env)) do chat(line) end
				end
			end
			G.yearSeen = lastYear
		end
	end
end

-- The window's file: every game writes it from the state (the same on every game but `host` and `me`). Tab-separated lines:
--   host 0|1, me <company>, mode separate|shared, opts <goal> <stats> <yearly> <tenders> (0|1 each)
--   co <id> <r,g,b> <ai 0|1> <gone 0|1> <name>
--   goal <seq> <crit> <want> <target> <years> <ai 0|1> <startM> <endM> <state> <how> <winner|0> <endAt|0> <endYM|0>
--   final <id:score[:ai];...>, fname <id=name|...> (an ended goal's frozen ranking)
--   last <mi>, m <mi> <year> <month> <rows> (oldest first), y <year> <mi> <rows>, tw <id:wins;...>
function M.fileLines(st, s, env)
	local L = {}
	local function b(x) return x and "1" or "0" end
	L[#L + 1] = "v\t1"
	L[#L + 1] = "host\t" .. b(env.isHost)
	L[#L + 1] = "me\t" .. tostring(tonumber(env.myCo) or 0)
	L[#L + 1] = "mode\t" .. modeOf(st, env)
	local tenders = M.tendersOn(st, env)
	L[#L + 1] = "opts\t" .. b(M.goalOn(st, env)) .. "\t" .. b(M.statsOn(st, env)) .. "\t" .. b(M.yearlyOn(st, env)) .. "\t" .. b(tenders)
	local cos = M.guiCompanies(st, env)
	for _, c in ipairs(cos) do
		local r, g, bl = M.rgb(c.color)
		-- (0.7.4: the company's name as the other pages show it, the game's name of its player (env.coName): the host's first
		-- company has no name of its own in the registry and showed as "Company 1". MPFEVER_STATSNAMES=0: the registry's, as before)
		local name = c.name
		if type(env.coName) == "function" and os.getenv("MPFEVER_STATSNAMES") ~= "0" then
			local okN, n = pcall(env.coName, c.id)
			if okN and type(n) == "string" and n ~= "" and n:sub(1, 1) ~= "#" then name = n end
		end
		L[#L + 1] = "co\t" .. c.id .. "\t" .. string.format("%.2f,%.2f,%.2f", r, g, bl) .. "\t" .. b(c.ai) .. "\t" .. b(c.gone) .. "\t"
			.. (tostring(name or ""):gsub("%c", " "))
	end
	if type(s) ~= "table" then return L end
	local g = s.goal
	if type(g) == "table" and M.goalOn(st, env) then
		L[#L + 1] = table.concat({ "goal", g.seq, g.crit, g.want or g.crit, num(g.target), g.years, b(g.ai),
			g.startM or 0, g.endM or 0, g.state, g.how or "", g.winner or 0, g.endAt or 0, g.endYM or 0 }, "\t")
		if g.final then L[#L + 1] = "final\t" .. g.final end
		if g.names then L[#L + 1] = "fname\t" .. g.names end
	end
	if s.last then L[#L + 1] = "last\t" .. s.last end
	for _, e in ipairs(s.m or {}) do
		local mi, y, mo, rows = splitMonth(e)
		if mi then L[#L + 1] = "m\t" .. mi .. "\t" .. y .. "\t" .. mo .. "\t" .. rows end
	end
	for _, e in ipairs(s.y or {}) do
		local y, mi, rows = splitYear(e)
		if y then L[#L + 1] = "y\t" .. y .. "\t" .. mi .. "\t" .. rows end
	end
	if tenders then
		local t = {}
		for _, c in ipairs(cos) do t[#t + 1] = c.id .. ":" .. M.tenderWins(st, c.id, env) end
		L[#L + 1] = "tw\t" .. table.concat(t, ";")
	end
	return L
end

function M.gui(st, env)
	if type(st) ~= "table" or not M.anyOn(st, env) then return end
	local s = type(st.feat) == "table" and st.feat[M.ID] or nil
	local T = guiT(env)
	M.notices(st, s, env, T)
	if env.isHost then M.hostSample(st, s, env, realTime(env)) end
	if type(env.write) == "function" then env.write(M.FILE, M.fileLines(st, s, env)) end
end

-- a request of the MPFever window on this game: "cancel" (the host cancels the running goal, A5)
function M.request(kind, payload, st, env)
	if kind ~= "cancel" or type(st) ~= "table" then return false end
	if not (env.isHost and M.goalOn(st, env)) or type(env.send) ~= "function" then return false end
	local s = type(st.feat) == "table" and st.feat[M.ID] or nil
	local g = type(s) == "table" and s.goal or nil
	if not (g and g.state == "run") then return false end
	env.send("f_stats_cancel", { seq = g.seq })
	return true
end

-- ---------------------------------------------------------------- the MPFever window (the Ranking tab)
-- the window's file read back: { host, me, mode, opts, cos = { [id] = co }, coList, goal, final, fname, last, m, y, tw }
function M.model(lines)
	local md = { host = false, me = 0, mode = "shared", opts = {}, cos = {}, coList = {}, m = {}, y = {}, tw = {}, names = {} }
	for _, line in ipairs(type(lines) == "table" and lines or {}) do
		local p = {}
		for x in (tostring(line) .. "\t"):gmatch("([^\t]*)\t") do p[#p + 1] = x end
		local k = p[1]
		if k == "host" then md.host = p[2] == "1"
		elseif k == "me" then md.me = tonumber(p[2]) or 0
		elseif k == "mode" then md.mode = p[2]
		elseif k == "opts" then md.opts = { goal = p[2] == "1", stats = p[3] == "1", yearly = p[4] == "1", tenders = p[5] == "1" }
		elseif k == "co" then
			local r, g, b = (p[3] or ""):match("^([%d.]+),([%d.]+),([%d.]+)$")
			local c = { id = tonumber(p[2]), rgb = { tonumber(r) or 0.7, tonumber(g) or 0.7, tonumber(b) or 0.7 }, ai = p[4] == "1",
				gone = p[5] == "1", name = p[6] or "" }
			if c.id then md.cos[c.id] = c; md.coList[#md.coList + 1] = c end
		elseif k == "goal" then
			md.goal = { seq = tonumber(p[2]), crit = p[3], want = p[4], target = tonumber(p[5]) or 0, years = tonumber(p[6]) or 0,
				ai = p[7] == "1", startM = tonumber(p[8]) or 0, endM = tonumber(p[9]) or 0, state = p[10], how = p[11],
				winner = tonumber(p[12]), endAt = tonumber(p[13]), endYM = tonumber(p[14]) }
			if md.goal.winner == 0 then md.goal.winner = nil end
			if md.goal.endYM == 0 then md.goal.endYM = nil end
		elseif k == "final" then
			md.final = {}
			for id, score, ai in ((p[2] or "") .. ";"):gmatch("(%d+):(%-?%d+):?(%a*);") do
				md.final[#md.final + 1] = { id = tonumber(id), score = tonumber(score), ai = ai == "ai" }
			end
		elseif k == "fname" then
			for id, n in ((p[2] or "") .. "|"):gmatch("(%d+)=([^|]*)|") do md.names[tonumber(id)] = n end
		elseif k == "last" then md.last = tonumber(p[2])
		elseif k == "m" then md.m[#md.m + 1] = { mi = tonumber(p[2]), year = tonumber(p[3]), month = tonumber(p[4]), rows = M.parseRows(p[5] or "") or {} }
		elseif k == "y" then md.y[#md.y + 1] = { year = tonumber(p[2]), mi = tonumber(p[3]), rows = M.parseRows(p[4] or "") or {} }
		elseif k == "tw" then
			for id, n in ((p[2] or "") .. ";"):gmatch("(%d+):(%d+);") do md.tw[tonumber(id)] = tonumber(n) end
		end
	end
	return md
end

-- the window's choices (this window only): the graph's figure and range, the host's confirmation of a cancel
M.sel = { metric = "value", range = "m", confirm = false }

local function coLabel(md, id, T)
	local c = md.cos[id]
	local n = (c and c.name ~= "") and c.name or md.names[id] or tr(T, TX.company, id)
	if c and c.ai then n = n .. " " .. tr(T, TX.aiTag) end
	if id == md.me and md.me ~= 0 then n = n .. " " .. tr(T, TX.you) end
	return n
end

local function metricOf(r, metric)
	if metric == "money" then return M.money(r) end
	if metric == "vehicles" then return r.vv end
	return M.value(r)
end

-- The tab's content as plain data (the view is tested offline; M.ui turns it into the window's widgets):
--   { kind = "title" | "text" | "muted" | "good", text }, { kind = "table", head = {...}, rows = { {...}... } },
--   { kind = "buttons", items = { { label, on = true|false, act = function } } },
--   { kind = "chart", series = { { label, color = {r,g,b}, x = {...}, y = {...} } }, xMin, xMax, yMin, yMax }
function M.view(md, T, sel)
	sel = sel or M.sel
	local out = {}
	local function add(kind, text) out[#out + 1] = { kind = kind, text = text } end
	local latest = md.m[#md.m]
	local rowsById = {}
	if latest then for _, r in ipairs(latest.rows) do rowsById[r.id] = r end end
	-- the goal
	local g = md.opts.goal and md.goal or nil
	if g then
		add("title", tr(T, TX.goal))
		add("text", tr(T, TX.rules, critName(T, g.crit), targetText(g, T), g.years))
		if g.want == "tenders" and g.crit ~= "tenders" then add("muted", tr(T, TX.tendersOff)) end
		add("muted", tr(T, (g.target or 0) > 0 and TX.rulesTarget or TX.rulesBest))
		add("muted", tr(T, g.ai and TX.aiYes or TX.aiNo))
		if g.state == "run" then
			-- (in the calendar's months once the goal's end is dated, else in game months)
			local left = math.max(0, (g.endM or 0) - (md.last or g.startM or 0))
			if g.endYM and latest and latest.year and latest.month then left = math.max(0, g.endYM - (latest.year * 12 + latest.month - 1)) end
			add("text", tr(T, TX.left, math.floor(left / 12), left % 12))
			-- (the leader by the goal's criterion, among the companies that may win)
			local best = nil
			for _, c in ipairs(md.coList) do
				if not c.gone and (g.ai or not c.ai) then
					local score = nil
					if g.crit == "tenders" then score = md.tw[c.id] or 0
					elseif rowsById[c.id] then score = g.crit == "money" and M.money(rowsById[c.id]) or M.value(rowsById[c.id]) end
					if score and (not best or score > best.score) then best = { id = c.id, score = score } end
				end
			end
			if best then
				local sc = g.crit == "tenders" and tostring(best.score) or M.fmt(best.score)
				if (g.target or 0) > 0 then add("text", tr(T, TX.leading, coLabel(md, best.id, T), sc, targetText(g, T)))
				else add("text", tr(T, TX.leadingBest, coLabel(md, best.id, T), sc)) end
			end
			if md.host then
				add("muted", tr(T, TX.fixed))
				if sel.confirm then
					out[#out + 1] = { kind = "buttons", items = {
						{ label = tr(T, TX.btnConfirm), request = { "cancel", tostring(g.seq) }, act = function() sel.confirm = false end },
						{ label = tr(T, TX.btnKeep), act = function() sel.confirm = false end } } }
				else
					out[#out + 1] = { kind = "buttons", items = { { label = tr(T, TX.btnCancel), act = function() sel.confirm = true end } } }
				end
			end
		else
			if g.state == "won" then add("good", tr(T, g.how == "target" and TX.wonTarget or TX.wonTime, coLabel(md, g.winner, T)))
			elseif g.state == "ended" then add("good", tr(T, TX.endedNone))
			else add("text", tr(T, g.how == "off" and TX.cancelledOff or TX.cancelledHost)) end
			if g.state ~= "cancelled" then
				add("muted", tr(T, TX.goesOn))
				if md.final and #md.final > 0 then
					local rows = {}
					for i, f in ipairs(md.final) do
						rows[#rows + 1] = { tostring(i), coLabel(md, f.id, T), g.crit == "tenders" and tostring(f.score) or M.fmt(f.score) }
					end
					add("title", tr(T, TX.final))
					out[#out + 1] = { kind = "table", head = { "#", tr(T, TX.colCo), critName(T, g.crit) }, rows = rows }
				end
			end
		end
	end
	-- the ranking now (the last figures; by the running goal's criterion, else by value)
	add("title", tr(T, TX.tab))
	if not latest then
		add("muted", tr(T, TX.noData))
		return out
	end
	add("muted", tr(T, TX.lastFigures, latest.month, latest.year))
	local crit = (g and g.state == "run") and g.crit or "value"
	local list = {}
	for _, c in ipairs(md.coList) do
		local r = rowsById[c.id]
		if r and not c.gone then
			local score = crit == "tenders" and (md.tw[c.id] or 0) or (crit == "money" and M.money(r) or M.value(r))
			list[#list + 1] = { id = c.id, r = r, score = score }
		end
	end
	table.sort(list, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.id < b.id end)
	local head = { "#", tr(T, TX.colCo), tr(T, TX.colValue), tr(T, TX.colMoney), tr(T, TX.colVeh) }
	if md.opts.tenders then head[#head + 1] = tr(T, TX.colTenders) end
	local rows = {}
	for i, x in ipairs(list) do
		local row = { tostring(i), coLabel(md, x.id, T), M.fmt(M.value(x.r)), M.fmt(M.money(x.r)), M.fmt(x.r.vv) }
		if md.opts.tenders then row[#row + 1] = tostring(md.tw[x.id] or 0) end
		rows[#rows + 1] = row
	end
	local ids = {}
	for i, x in ipairs(list) do ids[i] = x.id end
	out[#out + 1] = { kind = "table", head = head, rows = rows, ids = ids }
	add("muted", tr(T, TX.valueExplained))
	add("muted", tr(T, TX.moneyExplained))
	-- the graphs (A4: with the stats option)
	if md.opts.stats then
		add("title", tr(T, TX.history))
		local function pickBtn(label, field, v)
			return { label = label, on = sel[field] == v, act = function() sel[field] = v end }
		end
		out[#out + 1] = { kind = "buttons", items = { pickBtn(tr(T, TX.colValue), "metric", "value"), pickBtn(tr(T, TX.colMoney), "metric", "money"),
			pickBtn(tr(T, TX.colVeh), "metric", "vehicles") } }
		out[#out + 1] = { kind = "buttons", items = { pickBtn(tr(T, TX.range2y), "range", "m"), pickBtn(tr(T, TX.rangeAll), "range", "y") } }
		local points = {}
		if sel.range == "y" then
			for _, e in ipairs(md.y) do points[#points + 1] = { x = e.year, rows = e.rows } end
			-- (the year under way: its last figures)
			if latest and (#points == 0 or latest.mi ~= md.y[#md.y].mi) then points[#points + 1] = { x = latest.year + (latest.month - 1) / 12, rows = latest.rows } end
		else
			for _, e in ipairs(md.m) do points[#points + 1] = { x = e.year + (e.month - 1) / 12, rows = e.rows } end
		end
		local series, yMin, yMax = {}, 0, 0
		for _, c in ipairs(md.coList) do
			local xs, ys = {}, {}
			for _, p in ipairs(points) do
				for _, r in ipairs(p.rows) do
					if r.id == c.id then
						local v = metricOf(r, sel.metric)
						xs[#xs + 1], ys[#ys + 1] = p.x, v
						if v < yMin then yMin = v end
						if v > yMax then yMax = v end
					end
				end
			end
			if #xs > 0 then series[#series + 1] = { id = c.id, label = coLabel(md, c.id, T), color = c.rgb, x = xs, y = ys } end
		end
		local chart = { kind = "chart", series = series, xMin = points[1] and points[1].x or 0, xMax = points[#points] and points[#points].x or 1,
			yMin = yMin, yMax = yMax > yMin and yMax or yMin + 1 }
		-- (the same figures as a table, for a window without a chart: now and some months or years before)
		local cols, colHead = {}, { tr(T, TX.colCo) }
		local picks = sel.range == "y" and { 0, 1, 2, 5, 10 } or { 0, 6, 12, 23 }
		for _, back in ipairs(picks) do
			local p = points[#points - back]
			if p then
				cols[#cols + 1] = p
				if sel.range == "y" then colHead[#colHead + 1] = back == 0 and tr(T, TX.now) or tostring(math.floor(p.x))
				else colHead[#colHead + 1] = back == 0 and tr(T, TX.now) or tr(T, TX.monthsAgo, back) end
			end
		end
		local trows = {}
		for _, s in ipairs(series) do
			local row = { s.label }
			for _, p in ipairs(cols) do
				local v = nil
				for _, r in ipairs(p.rows) do if r.id == s.id then v = metricOf(r, sel.metric) end end
				row[#row + 1] = v and M.fmt(v) or "-"
			end
			trows[#trows + 1] = row
		end
		chart.table = { kind = "table", head = colHead, rows = trows }
		out[#out + 1] = chart
	end
	return out
end

-- the columns' widths of a table in the window's text width W: "#" narrow, the company's name wider, the figures sharing the rest
function M.widths(head, W)
	local n = #head
	if n == 0 then return nil end
	local first = head[1] == "#" and 30 or 0
	local nameCol = first > 0 and 2 or 1
	local rest = n - nameCol
	local name = rest > 0 and math.floor((W - first) * (rest >= 3 and 0.34 or 0.5)) or (W - first)
	local each = rest > 0 and math.floor((W - first - name) / rest) or 0
	local out = {}
	for i = 1, n do
		if first > 0 and i == 1 then out[i] = first
		elseif i == nameCol then out[i] = name
		else out[i] = each end
	end
	return out
end

-- The tab's widgets, made with the window's helpers (U.featU in mpfever_ui.script.lua, docs/FEATURES-0.6.md): u.title(t),
-- u.text(t, cls) (cls "success" for an end), u.muted(t), u.button(label, fn, primary) (the choice shown selected as primary),
-- u.row(nodes), u.table(lines, widths, header) (the first line as titles), and u.chart(spec) if a window has one one day (else
-- the graph's figures as a table). A helper missing: its text instead. Returns the list of the tab's nodes.
function M.ui(u)
	local T = u.T
	local md = M.model(type(u.read) == "function" and u.read(M.FILE) or nil)
	local W = tonumber(u.W) or 556
	local nodes = {}
	local function call(name, ...)
		if type(u[name]) ~= "function" then return nil end
		local ok, n = pcall(u[name], ...)
		return ok and n or nil
	end
	local function add(n) if n ~= nil then nodes[#nodes + 1] = n end end
	local latest = md.m[#md.m]
	local function rowsOf(id)
		for _, r in ipairs(latest and latest.rows or {}) do if r.id == id then return r end end
		return nil
	end
	local function textNode(kind, text)
		local n = nil
		if kind == "title" then n = call("title", text)
		elseif kind == "muted" then n = call("muted", text)
		elseif kind == "good" then n = call("text", text, "success") end
		return n or call("text", text)
	end
	-- (0.6, the Hub) the companies' figures as bars in their colours: one a company, the longest the biggest (a figure under 0: no
	-- bar); pairs { id, value, label }
	local function bars(list)
		local top = 0
		for _, x in ipairs(list) do if x[2] > top then top = x[2] end end
		for _, x in ipairs(list) do
			local c = md.cos[x[1]]
			add(call("bar", top > 0 and math.max(0, x[2]) / top or 0, c and c.rgb or { 0.7, 0.7, 0.7 }, M.fmt(x[2]),
				{ lead = x[3], leadW = math.floor(W * 0.3), labelW = 120 }))
		end
	end
	-- (0.7.4, the menus redone: the ranking with a podium of the first three, each company's trend since the month before (an arrow
	-- and %), sorted by a click on a column's head; the window's old pages asked: as before)
	local function rankingNode(t)
		local prev = md.m[#md.m - 1]
		local function prevValue(id)
			for _, r in ipairs(prev and prev.rows or {}) do if r.id == id then return M.value(r) end end
			return nil
		end
		local items = {}
		for i, id in ipairs(t.ids) do
			local r = rowsOf(id)
			if r then
				local v, pv = M.value(r), prevValue(id)
				local trend = nil
				if pv and pv ~= 0 then trend = (v - pv) / math.abs(pv) * 100 end
				items[#items + 1] = { rank = i, id = id, row = t.rows[i], value = v, money = M.money(r), veh = r.vv, trend = trend, tw = md.tw[id] or 0 }
			end
		end
		-- the podium
		local pod = {}
		for i = 1, math.min(3, #items) do
			local x = items[i]
			pod[#pod + 1] = { tostring(i) .. ". " .. coLabel(md, x.id, T), x.row[3] or M.fmt(x.value), i == 1 and "success" or nil }
		end
		if #pod > 0 and u.stats then add(call("stats", pod, math.floor((W - 20) / 3))); add(call("gap", 8)) end
		-- the table, sorted as asked
		local key = M.sel.sort
		if key == "value" or key == "money" or key == "veh" or key == "trend" or key == "tw" then
			table.sort(items, function(a, b)
				local x, y = a[key] or -math.huge, b[key] or -math.huge
				if x ~= y then return x > y end
				return a.rank < b.rank
			end)
		end
		local function head(label, k)
			return call("button", label, function() M.sel.sort = (M.sel.sort == k) and nil or k end, M.sel.sort == k)
		end
		local hl = { "#", tr(T, TX.colCo), head(tr(T, TX.colValue), "value"), head(tr(T, TX.colMoney), "money"), head(tr(T, TX.colVeh), "veh"),
			head(tr(T, TX.colTrend), "trend") }
		if md.opts.tenders then hl[#hl + 1] = head(tr(T, TX.colTenders), "tw") end
		local lines = { hl }
		local ids = {}
		for _, x in ipairs(items) do
			local tn = "–"
			if x.trend then
				local s = string.format("%+.1f %%", x.trend)
				tn = call("text", s, x.trend > 0.05 and "success" or (x.trend < -0.05 and "error" or nil)) or s
			end
			local line = { tostring(x.rank), coLabel(md, x.id, T), M.fmt(x.value), M.fmt(x.money), M.fmt(x.veh), tn }
			if md.opts.tenders then line[#line + 1] = tostring(x.tw) end
			lines[#lines + 1] = line
			ids[#ids + 1] = x.id
		end
		local widths = md.opts.tenders and { 30, 170, 95, 95, 85, 85, 70 } or { 30, 190, 105, 105, 95, 95 }
		local n = call("table", lines, widths, true, { highlight = function(i) return md.me ~= 0 and ids[i] == md.me end })
		if n then add(n) end
		-- (the values as bars in the companies' colours, the first one's the longest)
		local list = {}
		for _, x in ipairs(items) do list[#list + 1] = { x.id, x.value, coLabel(md, x.id, T) } end
		if #list > 0 then add(call("gap", 6)); bars(list) end
		return nil
	end
	local function tableNode(t)
		if u.rich and not u.oldMenus and t.ids and t.head[1] == "#" and u.stats and u.button then
			local okR, errR = pcall(rankingNode, t)
			if okR then return nil end
			add(textNode("muted", "stats: " .. tostring(errR)))
		end
		local lines = { t.head }
		for _, r in ipairs(t.rows) do lines[#lines + 1] = r end
		-- (the Hub: this player's company on a band of its own)
		local opts = nil
		if u.rich and t.ids then opts = { highlight = function(i) return md.me ~= 0 and t.ids[i] == md.me end } end
		local n = call("table", lines, M.widths(t.head, W), true, opts)
		if n then
			-- (the Hub: the ranking's values as bars under its table)
			if u.rich and t.ids and u.bar then
				local list = {}
				for _, id in ipairs(t.ids) do
					local r = rowsOf(id)
					if r then list[#list + 1] = { id, M.value(r), coLabel(md, id, T) } end
				end
				if #list > 0 then add(n); add(call("gap", 6)); bars(list); return nil end
			end
			return n
		end
		-- (no table in the window: one text a row)
		add(textNode("muted", table.concat(t.head, "   ")))
		for _, r in ipairs(t.rows) do add(textNode("text", table.concat(r, "   "))) end
		return nil
	end
	local ok, items = pcall(M.view, md, T, M.sel)
	if not ok then items = { { kind = "muted", text = "stats: " .. tostring(items) } } end
	for _, it in ipairs(items) do
		if it.kind == "table" then add(tableNode(it))
		elseif it.kind == "buttons" then
			local row = {}
			for _, b in ipairs(it.items) do
				local fn = function()
					if b.request and type(u.request) == "function" then u.request(b.request[1], b.request[2]) end
					if b.act then b.act() end
				end
				local n = call("button", b.label, fn, b.on)
				if n then row[#row + 1] = n end
			end
			local r = #row > 0 and call("row", row) or nil
			if r then add(r) else for _, n in ipairs(row) do add(n) end end
		elseif it.kind == "chart" then
			local n = nil
			if #it.series > 0 then n = call("chart", it) end
			if n then add(n)
			elseif u.rich and u.bar and #it.series > 0 then
				-- (the Hub: each company's last figure as a bar in its colour, then the figures over time as a table)
				local list = {}
				for _, s in ipairs(it.series) do list[#list + 1] = { s.id, s.y[#s.y] or 0, s.label } end
				bars(list)
				add(call("gap", 8))
				add(tableNode(it.table))
			else add(tableNode(it.table)) end
		else
			add(textNode(it.kind, it.text))
		end
	end
	-- (0.7.4: « How does it work? »)
	if u.rich and not u.oldMenus and u.help then
		for _, n in ipairs(nodes) do if u.add then u.add(n) end end
		if u.add then nodes = {} end
		pcall(u.help, "stats", { TX.help1, TX.help2, TX.help3 })
	end
	return nodes
end

return M
