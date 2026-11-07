-- MPFever 0.6 game options "perms" and "plans" (idea 08 of 0.6, release/recherche-0.6/08-coop-permissions-plans.md; the
-- owner's answers H1 to H8 in 00-REPONSES.md): the rights and budgets of a team's players, the approvals of their chief, and
-- the plans a team draws on the map. A feature module of the options host (mpfever_feat.lua, contract docs/FEATURES-0.6.md).
--
-- A team: everybody in co-op ("shared" mode), led by the host; a company of several players in the "separate" mode, led by its
-- chief (H1). The leader names team leads (H3: "chefs d'équipe") among its players; the leader and the leads set the rights and
-- budgets of the other players and answer their requests for approval. A leader is never restricted; a player alone in its
-- company is its chief; a computer company has no team.
--   rights (letters): b build, d bulldoze, v vehicles (buy, replace, sell), l lines, m loans, s speed and pause (H8). A new
--   player has them all and the default budget (H2: as before the option).
--   budget: what a player may spend in a game year (H5: back to 0 on 1 January), the option's default or its own (0: nothing
--   without an approval, -1: no limit).
--   approval (H4): the right to spend up to an amount beyond the budget during 3 game months.
--   plans (H6): seen by everybody in co-op, by the company's players only in the separate mode. TF3 has no plan mode of its
--   own (no such tool nor function in api/tealdef): MPFever's plan mode (H7) is a local switch that turns the construction
--   tools' builds down while their route still shows; "Keep this route" shares that route. A note is put at the centre of the
--   view. Both are drawn with the game's mission zones (circles, as the build previews of 0.5.0): nothing reaches the world.
--
-- Nothing is ever refused in the simulation: a player's own game refuses its action before it is sent (M.allow for the
-- commands held by the interface, M.guiVeto for the tools, the vehicle store and the line window), so a refusal cannot make the
-- games differ. The simulation half only keeps the team's data (st.feat.perms, saved with the game), changed by the stamped
-- events below at the same step on every game, and counts what each player spends from the actions every game replays (the
-- cost a native build carries, the store's price of a bought vehicle: the same numbers everywhere).
--
--   f_perms_set     {key, r, add, del, b}   a player's rights (r: all its letters; add / del: letters given or taken) and/or
--                                        its budget ("default", -1, or an amount)
--   f_perms_lead    {key, on}            the team's leader names a team lead, or takes the role back
--   f_perms_ask     {amount, note}       a player asks for an approval (one open request each)
--   f_perms_cancel  {}                   a player takes its request back
--   f_perms_answer  {n, ok}              a leader or lead answers request n
--   f_perms_plan    {kind, name, text, pts, z, c}   a plan: a route ("x,y[,r];..." rounded to the metre) or a note (one point)
--   f_perms_plandel {id}                 a plan taken away (its author, or a leader or lead over its author)
--
-- The sender of an event is env.from (else param.mpfFrom, which the bridge puts in every f_ event in both modes, over whatever the
-- sender wrote there): its name, "#n" after it for a player who joined; the host's has none (as in mpfever_eco.lua). The players are known by their key: the name in lower
-- case without "#n" (the registry's member keys, G.coMyKey).

local M = {}
M.ID = "perms"

-- (which language T speaks: it gives the first of these in French)
local LANG_PROBE = { "fr", "en" }

-- (the money a lobby's choice shows, in the language of T: api.util.formatMoney when the game is there)
local function fmtMoney(n, T)
	n = math.floor(tonumber(n) or 0)
	if api and api.util and api.util.formatMoney then
		local ok, s = pcall(api.util.formatMoney, n)
		if ok and s ~= nil then return tostring(s) end
	end
	local fr = T and T(LANG_PROBE[1], LANG_PROBE[2]) == LANG_PROBE[1]
	local s, neg = tostring(math.abs(n)), n < 0
	local out = s:reverse():gsub("(%d%d%d)", "%1" .. (fr and " " or ",")):reverse():gsub("^[ ,]", "")
	out = fr and (out .. " $") or ("$" .. out)
	return neg and ("-" .. out) or out
end
M.money = fmtMoney

M.OPTIONS = {
	{ id = "perms",
		title = { "Droits et budgets d'équipe", "Team permissions and budgets" },
		desc = { "Le chef de l'équipe (l'hôte en coop, le chef d'une entreprise à plusieurs) règle les droits et le budget annuel de "
			.. "chacun ; au-delà du budget, son accord donne une somme pour 3 mois.",
			"The team's leader (the host in co-op, the chief of a company of several players) sets everyone's permissions and yearly "
			.. "budget; beyond the budget, its approval grants an amount for 3 months." },
		modes = "both",
		params = {
			{ id = "budget", label = { "Budget par an d'un joueur", "A player's budget per year" },
				values = { 0, 1000000, 5000000, 20000000, 100000000 }, default = 0,
				show = function(v, T)
					if (tonumber(v) or 0) <= 0 then return M.tr(T, "unlimited_c") end
					return fmtMoney(v, T)
				end },
		} },
	{ id = "plans",
		title = { "Plans partagés", "Shared plans" },
		desc = { "Tracés gardés avec le mode plan et notes sur la carte, vus par tous en coop et par sa seule entreprise sinon.",
			"Routes kept with the plan mode and notes on the map, seen by everybody in co-op and by one's own company otherwise." },
		modes = "both" },
}

M.EVENTS = {
	f_perms_set = true, f_perms_lead = true, f_perms_ask = true, f_perms_cancel = true, f_perms_answer = true,
	f_perms_plan = true, f_perms_plandel = true,
}

M.TAB = { id = "team", title = { "Équipe", "Team" } }
-- (0.7.4) the page's « How does it work? », at its end in the Hub (see the window's U.featTabRows)
M.HELP = {
	{ "Le chef de l'équipe (l'hôte en coopération, le chef d'une entreprise à plusieurs joueurs) décide de ce que chaque joueur a le droit de faire et du budget qu'il peut dépenser par an.",
		"The team's chief (the host in co-op, the chief of a company with several players) decides what each player may do and the budget each one may spend a year." },
	{ "Une action interdite ou au-delà du budget est refusée sur tous les jeux, et le joueur voit pourquoi. Les plans partagés (tracés du mode plan et notes sur la carte) sont vus par toute l'équipe.",
		"An action that is not allowed or beyond the budget is refused on every game, and the player sees why. The shared plans (plan mode layouts and notes on the map) are seen by the whole team." },
}
-- the tab's data: feat_perms_team.txt of the session folder (env.write on the bridge's side, u.read in the window)
M.FILE = "team"

M.ALL = "bdvlms"                 -- every right, in the order they are written
M.GRANT_MONTHS = 3               -- an approval lasts that many game months (H4)
M.ASK_MONTHS = 3                 -- a request nobody answered goes after that many
M.MAX_ASKS = 20
M.MAX_AMOUNT = 1e12
M.NOTE_LEN = 120                 -- a request's reason
M.NAME_LEN = 40                  -- a plan's name
M.TEXT_LEN = 200                 -- a note's text
M.MAX_PLANS = 40
M.MAX_PLANS_PLAYER = 12
M.MAX_POINTS = 300               -- per plan
M.MAX_POINTS_ALL = 6000
M.MAX_WHO = 64                   -- the players a co-op team lists
M.MAX_ZONES = 1500               -- the plans' circles one game draws at most (frames per second)
M.ROUTE_STEP = 15                -- a route keeps one point every 15 m
-- the budgets a leader picks for a player, after "default": no limit, nothing without approval, amounts
M.BUDGETS = { -1, 0, 100000, 500000, 1000000, 5000000, 20000000, 100000000 }
-- the amounts a player asks for with one click (the last amount refused comes first)
M.ASK_AMOUNTS = { 100000, 500000, 1000000, 5000000, 20000000 }
-- The refusals can be switched off on one game (MPFEVER_PERMSVETO=0: no action refused, no tool vetoed; the team's data still
-- follows the events). The interface only: nothing of the simulation depends on it.
M.VETO_OFF = os.getenv("MPFEVER_PERMSVETO") == "0"

-- Every text a player sees, { French, English }, through the options host's T (env.T / u.T). (Kept in this table, not in
-- T("...", "...") calls: tests/test_lang.py looks the latter up in launcher/lang.json.)
M.TEXTS = {
	right_b = { "Construire", "Build" },
	right_d = { "Démolir", "Bulldoze" },
	right_v = { "Véhicules", "Vehicles" },
	right_l = { "Lignes", "Lines" },
	right_m = { "Prêts", "Loans" },
	right_s = { "Vitesse et pause", "Speed and pause" },
	no_b = { "Vous n'avez pas le droit de construire (règle de votre équipe).", "You may not build (your team's rule)." },
	no_d = { "Vous n'avez pas le droit de démolir (règle de votre équipe).", "You may not bulldoze (your team's rule)." },
	no_v = { "Vous n'avez pas le droit d'acheter, de remplacer ou de vendre des véhicules (règle de votre équipe).",
		"You may not buy, replace or sell vehicles (your team's rule)." },
	no_l = { "Vous n'avez pas le droit de gérer les lignes (règle de votre équipe).", "You may not manage lines (your team's rule)." },
	no_m = { "Vous n'avez pas le droit de prendre ou de rembourser un prêt (règle de votre équipe).",
		"You may not take or repay a loan (your team's rule)." },
	no_s = { "Vous n'avez pas le droit de changer la vitesse du jeu ni de le mettre en pause (règle de votre équipe).",
		"You may not change the game's speed or pause it (your team's rule)." },
	over = { "Budget dépassé : il vous reste %s (accord compris). Demandez l'accord dans la fenêtre MPFever, onglet Équipe.",
		"Over budget: %s left (approval included). Ask for approval in the MPFever window, Team tab." },
	plan_mode = { "Mode plan : rien n'est construit. Gardez le tracé dans la fenêtre MPFever, onglet Équipe.",
		"Plan mode: nothing is built. Keep the route in the MPFever window, Team tab." },
	ask_news = { "%s demande l'accord pour %s : %s", "%s asks for approval of %s: %s" },
	granted = { "Accord de %s : vous pouvez dépenser %s de plus pendant 3 mois.", "Approved by %s: you may spend %s more for 3 months." },
	denied = { "Votre demande d'accord a été refusée par %s.", "Your request for approval was refused by %s." },
	changed = { "Vos droits ont changé : %s ; budget : %s.", "Your permissions changed: %s; budget: %s." },
	none = { "aucun", "none" },
	-- the tab
	h_mine = { "Vos droits", "Your permissions" },
	role = { "Rôle : %s", "Role: %s" },
	role_host = { "hôte, chef de l'équipe", "host, the team's leader" },
	role_chief = { "chef de l'entreprise", "company chief" },
	role_lead = { "chef d'équipe", "team lead" },
	role_member = { "membre", "member" },
	role_free = { "pas d'équipe : tous les droits", "no team: every permission" },
	allowed = { "Droits : %s", "Allowed: %s" },
	denied_list = { "Refusé : %s", "Not allowed: %s" },
	every = { "tous", "all of them" },
	budget_of = { "Budget de l'année : %s dépensés sur %s", "This year's budget: %s spent of %s" },
	budget_free = { "Pas de limite de budget (%s dépensés cette année)", "No budget limit (%s spent this year)" },
	grant = { "Accord en cours : %s pendant encore %s mois", "Approval: %s for %s more month(s)" },
	my_ask = { "Votre demande : %s, en attente", "Your request: %s, waiting" },
	withdraw = { "Retirer ma demande", "Withdraw my request" },
	ask_for = { "Demander l'accord pour :", "Ask for approval of:" },
	amount = { "Montant", "Amount" },
	reason = { "Raison (facultatif)", "Reason (optional)" },
	ask = { "Demander", "Ask" },
	h_asks = { "Demandes à traiter", "Requests to answer" },
	ask_line = { "%s : %s %s", "%s: %s %s" },
	accept = { "Accepter", "Accept" },
	refuse = { "Refuser", "Refuse" },
	h_players = { "Joueurs de l'équipe", "The team's players" },
	player_line = { "%s (%s) : %s dépensés cette année, budget %s", "%s (%s): %s spent this year, budget %s" },
	b_default = { "par défaut (%s)", "default (%s)" },
	unlimited = { "illimité", "unlimited" },
	unlimited_c = { "Illimité", "Unlimited" },
	budget_btn = { "Budget : %s", "Budget: %s" },
	lead_yes = { "Chef d'équipe : oui", "Team lead: yes" },
	lead_no = { "Chef d'équipe : non", "Team lead: no" },
	on_mark = { "[x] %s", "[x] %s" },
	off_mark = { "[ ] %s", "[ ] %s" },
	h_plans = { "Plans", "Plans" },
	plans_help = { "Mode plan : vos outils montrent leur tracé sans rien construire ; « Garder ce tracé » le partage avec votre équipe.",
		"Plan mode: your tools show their route without building anything; \"Keep this route\" shares it with your team." },
	planmode_on = { "Mode plan : activé", "Plan mode: on" },
	planmode_off = { "Mode plan : désactivé", "Plan mode: off" },
	keep = { "Garder ce tracé (%s points)", "Keep this route (%s points)" },
	note_here = { "Note au centre de la vue", "Note at the centre of the view" },
	plan_name = { "Nom du plan", "Plan name" },
	note_text = { "Texte de la note", "Text of the note" },
	plan_route = { "%s : %s (tracé, %s)", "%s: %s (route, %s)" },
	plan_note = { "%s : %s (note) %s", "%s: %s (note) %s" },
	route_of = { "Tracé de %s", "%s's route" },
	note_of = { "Note de %s", "%s's note" },
	view = { "Voir", "View" },
	hide = { "Masquer", "Hide" },
	show = { "Afficher", "Show" },
	delete = { "Supprimer", "Delete" },
	no_plan = { "Aucun plan pour l'instant.", "No plan yet." },
	waiting = { "En attente des données de l'équipe…", "Waiting for the team's data…" },
}

-- A text of M.TEXTS in the player's language; each %s takes the next value (put in with gsub: a value may hold a % itself)
local function tr(T, id, ...)
	local t = M.TEXTS[id] or { id, id }
	local s = T and T(t[1], t[2]) or t[2]
	local values, i = { ... }, 0
	return (s:gsub("%%s", function() i = i + 1; return tostring(values[i] == nil and "" or values[i]) end))
end
M.tr = tr

-- ------------------------------------------------------------------------------------------------- small helpers
-- A text of an event's parameter: a string or a number, else "" (tostring of a table or a function gives its address, which
-- differs from one game to the other)
local function str(v)
	if type(v) == "string" then return v end
	if type(v) == "number" then return tostring(v) end
	return ""
end

-- a player's key (its name in lower case, without the "#n" of a player who joined) and its plain name
local function keyOf(origin)
	local plain = str(origin):gsub("#.*$", "")
	return plain:lower(), plain
end
M.keyOf = keyOf

-- a host (or a dedicated server) sends its events under its plain name; a player who joined has "#n" after it
local function fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

-- a text of a player, on one line, without tabs, at most n characters (bytes: the game's names are UTF-8)
local function clean(t, n)
	t = str(t):gsub("[%c]", " "):gsub("^ +", ""):gsub(" +$", "")
	if #t > n then
		t = t:sub(1, n)
		-- (not in the middle of a UTF-8 character)
		while #t > 0 and t:byte(#t) >= 128 and t:byte(#t) < 192 do t = t:sub(1, #t - 1) end
		if #t > 0 and t:byte(#t) >= 192 then t = t:sub(1, #t - 1) end
	end
	return t
end

-- a whole amount of money, nil when it is not one (no NaN, no infinity)
local function amountOf(v)
	local n = tonumber(v)
	if not n or n ~= n or n < 1 or n > M.MAX_AMOUNT then return nil end
	return math.floor(n)
end

-- the rights letters of a text, in the order of M.ALL
local function letters(r)
	r = str(r)
	local out = {}
	for i = 1, #M.ALL do
		local c = M.ALL:sub(i, i)
		if r:find(c, 1, true) then out[#out + 1] = c end
	end
	return table.concat(out)
end

-- the payload of a window's request: a table (by position), or a text whose parts are separated by tabs
local function parts(payload)
	if type(payload) == "table" then return payload end
	local out = {}
	for p in (tostring(payload or "") .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = p end
	return out
end

-- (the colours of the companies, CO.PALETTE of mpfever_co.lua; a co-op player without a colour gets one from its key)
M.PALETTE = {
	{ 0.86, 0.20, 0.20 }, { 0.20, 0.45, 0.90 }, { 0.20, 0.72, 0.30 }, { 0.98, 0.62, 0.10 },
	{ 0.62, 0.30, 0.82 }, { 0.10, 0.75, 0.80 }, { 0.95, 0.88, 0.15 }, { 0.95, 0.45, 0.70 },
	{ 0.55, 0.35, 0.18 }, { 0.55, 0.85, 0.15 }, { 0.15, 0.30, 0.55 }, { 0.62, 0.62, 0.62 },
}
function M.rgb(c, key)
	local ix = tonumber(c)
	if not ix then
		ix = 0
		for i = 1, #tostring(key or "") do ix = (ix * 31 + tostring(key):byte(i)) % 9973 end
		ix = ix + 1
	end
	local p = M.PALETTE[(math.floor(ix) - 1) % #M.PALETTE + 1]
	return p[1], p[2], p[3]
end

-- ------------------------------------------------------------------------------------------------- the teams
-- The companies registry of the separate mode (plain data: st.co, see mpfever_co.lua), nil in co-op. The simulation half has
-- it as env.co and env.mode; the interface's half reads the game state's mirror (st.co).
local function regOf(st, env)
	if env and env.mode == "shared" then return nil end
	local reg = (env and type(env.co) == "table" and env.co) or (type(st) == "table" and st.co) or nil
	if type(reg) == "table" and reg.mode == "separate" and type(reg.list) == "table" then return reg end
	return nil
end
function M.modeOf(st, env)
	return regOf(st, env) and "separate" or "shared"
end

-- (the same reading of a company as CO.members / CO.chief: a member is { key, sid }, the first registries had one, its key)
local function members(c)
	if type(c.members) == "table" then return c.members end
	if type(c.key) == "string" and c.key ~= "" then return { { key = c.key } } end
	return {}
end
local function memberKey(m)
	if type(m) == "table" then return m.key end
	return m
end
local function chiefOf(c)
	if c.chief then return c.chief end
	local m = members(c)[1]
	return m and memberKey(m) or nil
end
local function isAiCo(c)
	return type(c.key) == "string" and c.key:sub(1, 3) == "ai:"
end
-- the company a player plays now (gone companies, bankrupt or merged, have no players any more)
local function companyOf(reg, key)
	for _, c in ipairs(reg.list) do
		if type(c) == "table" and not c.gone then
			for _, m in ipairs(members(c)) do if memberKey(m) == key then return c end end
		end
	end
	return nil
end
local function findCo(reg, id)
	for _, c in ipairs(reg.list) do if type(c) == "table" and c.id == id then return c end end
	return nil
end

-- the team's data (st.feat.perms) as the interface's half reads it: nil while the option never ran
function M.read(st)
	local f = type(st) == "table" and st.feat or nil
	local s = type(f) == "table" and f[M.ID] or nil
	return type(s) == "table" and s or nil
end

-- A player's place: its role and its team (the company's id in the separate mode, 0 in co-op).
--   "top"    the team's leader: the host in co-op (isHost: the player's game or event says so; else the key the team's data
--            noted for the host), the chief of a company;
--   "lead"   a team lead its leader named (for that team only);
--   "member" the others, who follow their entry (rights, budget);
--   "free"   no team: no company, a computer company.
function M.roleOf(st, env, s, key, isHost)
	local reg = regOf(st, env)
	if reg then
		local c = companyOf(reg, key)
		if not c or isAiCo(c) then return "free", nil end
		if chiefOf(c) == key then return "top", c.id end
		if s and type(s.lead) == "table" and s.lead[key] == c.id then return "lead", c.id end
		return "member", c.id
	end
	if isHost or (s and s.host ~= nil and s.host == key) then return "top", 0 end
	if s and type(s.lead) == "table" and s.lead[key] == 0 then return "lead", 0 end
	return "member", 0
end

local function restricted(role) return role == "member" or role == "lead" end
M.restricted = restricted

-- a player's entry, when it was set for the team it is in now (a player who changed company starts again with all rights)
local function entryOf(s, key, team)
	local e = s and type(s.p) == "table" and s.p[key] or nil
	if type(e) == "table" and e.co == team then return e end
	return nil
end

function M.rightsOf(s, key, role, team)
	if not restricted(role) then return M.ALL end
	local e = entryOf(s, key, team)
	return (e and type(e.r) == "string") and e.r or M.ALL
end

-- a player's budget for the year: its own (-1: no limit) or the option's default (0: no limit); nil when it has no limit
function M.limitOf(s, env, key, role, team)
	if not restricted(role) then return nil end
	local e = entryOf(s, key, team)
	local b = e and tonumber(e.b) or nil
	if b == nil then
		b = tonumber(env.param("perms", "budget")) or 0
		if b <= 0 then return nil end
		return b
	end
	if b < 0 then return nil end
	return b
end

-- a player's approval under way (for its team now, not over: till is the month it ends at; nil while the first month of the
-- option has not started)
function M.grantOf(s, key, team)
	local g = s and type(s.grant) == "table" and s.grant[key] or nil
	if type(g) ~= "table" or g.co ~= team or (tonumber(g.left) or 0) <= 0 then return nil end
	if g.till ~= nil and s.mon ~= nil and s.mon >= g.till then return nil end
	return g
end

-- what a player may still spend this year (its budget left, and its approval), nil when it has no limit; and the parts
function M.available(s, env, key, role, team)
	local lim = M.limitOf(s, env, key, role, team)
	if not lim then return nil end
	local spent = s and type(s.spent) == "table" and tonumber(s.spent[key]) or 0
	local g = M.grantOf(s, key, team)
	return math.max(0, lim - spent) + (g and g.left or 0), lim, spent, g
end

-- whether `by` may set the rights of `target` and answer its requests: the team's leader over everybody of its team, a team
-- lead over the members; never over the leader, never over oneself
function M.canManage(st, env, s, by, byHost, target)
	if type(target) ~= "string" or target == "" or target == by then return false end
	local rb, tb = M.roleOf(st, env, s, by, byHost)
	if rb ~= "top" and rb ~= "lead" then return false end
	local rt, tt = M.roleOf(st, env, s, target, false)
	if tt == nil or tb ~= tt or rt == "top" or rt == "free" then return false end
	if rb == "top" then return true end
	return rt == "member"
end

-- whether `by` may name `target` a team lead (or take the role back): the leader only, a player of its team
function M.canName(st, env, s, by, byHost, target)
	if type(target) ~= "string" or target == "" or target == by then return false end
	local rb, tb = M.roleOf(st, env, s, by, byHost)
	if rb ~= "top" then return false end
	local rt, tt = M.roleOf(st, env, s, target, false)
	return tt ~= nil and tt == tb and (rt == "member" or rt == "lead")
end

-- ------------------------------------------------------------------------------------------------- the simulation half
-- (every game, at the same step: only the events, the replayed actions and the months change the data; no clock, no file)

local function refuse(env, name, why)
	env.log("perms: " .. tostring(name) .. " refused: " .. tostring(why))
	return false, why
end

-- the game month now (env.month(): the game months since the game's start, floor(game time / a month's duration), as
-- mpfever_eco.lua counts them), else the last one M.month saw, else nil
local function monthNow(s, env)
	if type(env.month) == "function" then
		local ok, m = pcall(env.month)
		if ok and type(m) == "number" then return m end
	end
	return s.mon
end
-- the year of a game month when the calendar is not known: twelve months of env.month() a year
function M.yearOf(m)
	return math.floor(m / 12)
end
-- The calendar's year now (env.date(): the date of the game time, the same on every game), so that the year's spending goes back
-- to 0 on 1 January (H5); without the calendar, the year of the game month m
function M.yearNow(env, m)
	if type(env.date) == "function" then
		local ok, d = pcall(env.date)
		if ok and type(d) == "table" and tonumber(d.year) then return math.floor(tonumber(d.year)) end
	end
	return M.yearOf(m)
end

-- (who the team is: the players seen, for the co-op leader's list; the host's key, for everybody's view of the roles)
local function noteWho(s, key, plain, host)
	if key == "" or key:sub(1, 3) == "ai:" then return end
	if host and s.host ~= key then s.host = key end
	s.who = type(s.who) == "table" and s.who or {}
	if s.who[key] == nil then
		local n = 0
		for _ in pairs(s.who) do n = n + 1 end
		if n < M.MAX_WHO then s.who[key] = clean(plain, 40) end
	end
end

-- a plan's points: "x,y[,r];..." (whole metres; r: a circle's radius, a construction) -> the list, or nil and why
function M.parsePts(pts, maxN)
	if type(pts) ~= "string" or #pts > 20 * maxN then return nil, "points" end
	local out = {}
	for tok in pts:gmatch("[^;]+") do
		local x, y, r = tok:match("^(%-?%d+),(%-?%d+),?(%d*)$")
		x, y, r = tonumber(x), tonumber(y), tonumber(r)
		if not (x and y) or math.abs(x) > 1e6 or math.abs(y) > 1e6 or (r and (r < 1 or r > 200)) then return nil, "point " .. tok end
		out[#out + 1] = { x, y, r }
		if #out > maxN then return nil, "too many points" end
	end
	if #out == 0 then return nil, "no point" end
	return out
end
function M.encodePts(list)
	local t = {}
	for i, p in ipairs(list) do
		t[i] = math.floor(p[1] + 0.5) .. "," .. math.floor(p[2] + 0.5) .. (p[3] and ("," .. math.floor(p[3] + 0.5)) or "")
	end
	return table.concat(t, ";")
end

local function removeAsk(s, key)
	if type(s.asks) ~= "table" then return end
	for i = #s.asks, 1, -1 do if s.asks[i].key == key then table.remove(s.asks, i) end end
end

function M.event(st, name, param, env)
	if not M.EVENTS[name] then return false end
	local plan = name == "f_perms_plan" or name == "f_perms_plandel"
	-- (an option switched off: nothing happens, no data)
	if not env.on(plan and "plans" or "perms") then return refuse(env, name, "option off") end
	param = type(param) == "table" and param or {}
	local origin = env.from or param.mpfFrom
	if type(origin) ~= "string" or origin == "" then return refuse(env, name, "no sender") end
	local by, plain = keyOf(origin)
	local byHost = fromHost(origin)
	local s = env.state(st)
	noteWho(s, by, plain, byHost)
	local mon = monthNow(s, env)
	if name == "f_perms_set" then
		local target = keyOf(param.key)
		if not M.canManage(st, env, s, by, byHost, target) then return refuse(env, name, by .. " over " .. target) end
		local _, team = M.roleOf(st, env, s, target, false)
		local old = entryOf(s, target, team)
		local r = (old and old.r) or M.ALL
		if param.r ~= nil then r = letters(param.r) end
		-- (a right given or taken on what the player has here and now: two clicks of the window before the first one arrives
		-- both count)
		if param.add ~= nil then r = letters(r .. str(param.add)) end
		local del = letters(param.del)
		if del ~= "" then r = r:gsub("[" .. del .. "]", "") end
		local b = old and old.b or nil
		if param.b == "default" then
			b = nil
		elseif param.b ~= nil then
			local n = tonumber(param.b)
			if not n or n ~= n then return refuse(env, name, "budget " .. tostring(param.b)) end
			b = n < 0 and -1 or math.min(math.floor(n), M.MAX_AMOUNT)
		end
		s.p = type(s.p) == "table" and s.p or {}
		-- (everything as a new player has it: no entry, the data stays small)
		if r == M.ALL and b == nil then s.p[target] = nil else s.p[target] = { r = r, b = b, co = team } end
		env.log("perms: " .. by .. " set " .. target .. ": " .. r .. ", budget " .. tostring(b or "default"))
	elseif name == "f_perms_lead" then
		local target = keyOf(param.key)
		if not M.canName(st, env, s, by, byHost, target) then return refuse(env, name, by .. " names " .. target) end
		local _, team = M.roleOf(st, env, s, by, byHost)
		s.lead = type(s.lead) == "table" and s.lead or {}
		s.lead[target] = (param.on == true or param.on == 1 or param.on == "1") and team or nil
		env.log("perms: " .. target .. (s.lead[target] and " is a team lead" or " is no longer a team lead"))
	elseif name == "f_perms_ask" then
		local role, team = M.roleOf(st, env, s, by, byHost)
		if not restricted(role) then return refuse(env, name, by .. " needs no approval") end
		local amount = amountOf(param.amount)
		if not amount then return refuse(env, name, "amount " .. tostring(param.amount)) end
		s.asks = type(s.asks) == "table" and s.asks or {}
		removeAsk(s, by)
		s.askSeq = (tonumber(s.askSeq) or 0) + 1
		s.asks[#s.asks + 1] = { n = s.askSeq, key = by, co = team, amount = amount, note = clean(param.note, M.NOTE_LEN), at = mon }
		while #s.asks > M.MAX_ASKS do table.remove(s.asks, 1) end
		env.log("perms: " .. by .. " asks for " .. amount .. " (request " .. s.askSeq .. ")")
	elseif name == "f_perms_cancel" then
		removeAsk(s, by)
	elseif name == "f_perms_answer" then
		local n = tonumber(param.n)
		local ask, ix = nil, nil
		for i, a in ipairs(type(s.asks) == "table" and s.asks or {}) do if a.n == n then ask, ix = a, i end end
		if not ask then return refuse(env, name, "no request " .. tostring(param.n)) end
		if not M.canManage(st, env, s, by, byHost, ask.key) then return refuse(env, name, by .. " over " .. ask.key) end
		table.remove(s.asks, ix)
		local _, team = M.roleOf(st, env, s, ask.key, false)
		-- (a request made for another team: its player changed company since)
		if team ~= ask.co then return refuse(env, name, "request " .. ask.n .. " of another team") end
		local ok = param.ok == true or param.ok == 1 or param.ok == "1"
		if ok then
			s.grant = type(s.grant) == "table" and s.grant or {}
			s.grant[ask.key] = { left = ask.amount, till = mon and (mon + M.GRANT_MONTHS) or nil, co = team }
		end
		s.ans = type(s.ans) == "table" and s.ans or {}
		s.ans[ask.key] = { n = ask.n, ok = ok, by = clean(plain, 40), amount = ask.amount }
		env.log("perms: request " .. ask.n .. " of " .. ask.key .. (ok and " approved" or " refused") .. " by " .. by)
	elseif name == "f_perms_plan" then
		local kind = param.kind == "note" and "note" or (param.kind == "route" and "route" or nil)
		if not kind then return refuse(env, name, "kind " .. tostring(param.kind)) end
		local reg = regOf(st, env)
		local team = 0
		if reg then
			local c = companyOf(reg, by)
			if not c or isAiCo(c) then return refuse(env, name, by .. " has no company") end
			team = c.id
		end
		local pts, why = M.parsePts(param.pts, kind == "note" and 1 or M.MAX_POINTS)
		if not pts then return refuse(env, name, why) end
		if kind == "route" and #pts < 2 then return refuse(env, name, "a route of one point") end
		s.plans = type(s.plans) == "table" and s.plans or {}
		local mine, all = 0, #pts
		for _, p in ipairs(s.plans) do
			if p.key == by then mine = mine + 1 end
			all = all + (tonumber(p.np) or 0)
		end
		if #s.plans >= M.MAX_PLANS or mine >= M.MAX_PLANS_PLAYER or all > M.MAX_POINTS_ALL then return refuse(env, name, "too many plans") end
		s.planSeq = (tonumber(s.planSeq) or 0) + 1
		local z = tonumber(param.z)
		if not z or z ~= z or math.abs(z) > 1e5 then z = 0 end
		local c = tonumber(param.c)
		if not c or c ~= math.floor(c) or c < 1 or c > #M.PALETTE then c = nil end
		s.plans[#s.plans + 1] = { id = s.planSeq, key = by, who = clean(plain, 40), co = team, kind = kind,
			name = clean(param.name, M.NAME_LEN), text = clean(param.text, M.TEXT_LEN), pts = M.encodePts(pts), np = #pts,
			z = math.floor(z + 0.5), c = c }
		env.log("perms: plan " .. s.planSeq .. " (" .. kind .. ", " .. #pts .. " points) of " .. by)
	elseif name == "f_perms_plandel" then
		local id = tonumber(param.id)
		local ix, p = nil, nil
		for i, q in ipairs(type(s.plans) == "table" and s.plans or {}) do if q.id == id then ix, p = i, q end end
		if not p then return refuse(env, name, "no plan " .. tostring(param.id)) end
		local ok = p.key == by
		if not ok then
			local rb, tb = M.roleOf(st, env, s, by, byHost)
			ok = tb == p.co and (rb == "top" or (rb == "lead" and M.canManage(st, env, s, by, byHost, p.key)))
		end
		if not ok then return refuse(env, name, by .. " deletes plan " .. p.id) end
		table.remove(s.plans, ix)
		env.log("perms: plan " .. p.id .. " taken away by " .. by)
	end
	return true
end

-- Once at the start of every game month: the year's spending back to 0 on 1 January (H5), the approvals and requests over.
function M.month(st, env)
	if not env.on("perms") then return end
	local s = env.state(st)
	local m = monthNow(s, env)
	if type(m) ~= "number" then return end
	s.mon = m
	local y = M.yearNow(env, m)
	if s.year ~= nil and s.year ~= y then
		s.spent = nil
		env.log("perms: a new year (" .. y .. "): the budgets start again")
	end
	s.year = y
	for key, g in pairs(type(s.grant) == "table" and s.grant or {}) do
		if g.till == nil then g.till = m + M.GRANT_MONTHS end
		if m >= g.till or (tonumber(g.left) or 0) <= 0 then s.grant[key] = nil end
	end
	if type(s.asks) == "table" then
		for i = #s.asks, 1, -1 do
			local a = s.asks[i]
			if a.at == nil then a.at = m end
			if m - a.at >= M.ASK_MONTHS then table.remove(s.asks, i) end
		end
	end
end

-- The price of a model as the game's vehicle store reads it (vehicle_store_window.tl: metadata.cost.price), per model, kept
-- (the resources do not change during a game). A replaceable function.
M.priceCache = {}
function M.modelPrice(id)
	if type(id) ~= "number" then return 0 end
	local p = M.priceCache[id]
	if p == nil then
		p = 0
		pcall(function()
			local m = api.res.modelRep.get(id)
			local c = m and m.metadata and m.metadata.cost
			p = math.max(0, tonumber(c and c.price) or 0)
		end)
		M.priceCache[id] = p
	end
	return p
end

-- what a vehicle's configuration (TransportVehicleConfig: vehicles[i].part.modelId) costs in the store
function M.configPrice(tvc)
	local sum = 0
	pcall(function()
		local list = tvc.vehicles
		for i = 1, #list do sum = sum + M.modelPrice(list[i].part.modelId) end
	end)
	return sum
end

-- What an action costs its player: the cost a native build carries (a tool's build, fn "nativeBuild": its builder's game read
-- it from the tool, REFUND.costOf, and shipped it; the bridge's SIM.featWho gives it with its builder on every game, the same
-- number everywhere), the store's price of a bought vehicle. A replaced vehicle, a
-- window's edit and a removal are not counted in v1 (their price is not known before the engine applies them).
function M.costOf(a)
	local c = tonumber(a.cost)
	if c and c == c and c > 0 and c < M.MAX_AMOUNT then return math.floor(c + 0.5) end
	if a.fn == "makeVehicleBuyCmd" and type(a.args) == "table" then return M.configPrice(a.args[3]) end
	return 0
end

-- After every player action every game replays: the players seen (the co-op leader's list) and what each one spends this
-- year; beyond its budget, its approval goes down.
function M.onAction(st, a, ok, env)
	if not env.on("perms") or type(a) ~= "table" then return end
	local origin = a.origin
	if type(origin) ~= "string" or origin == "" or origin == "file" then return end
	-- (a computer company's builds come from the host's game: they are nobody's spending)
	local reg = regOf(st, env)
	if reg and a.co ~= nil then
		local c = findCo(reg, a.co)
		if c and isAiCo(c) then return end
	end
	local s = env.state(st)
	local by, plain = keyOf(origin)
	local host = fromHost(origin)
	noteWho(s, by, plain, host)
	if not ok then return end
	local cost = M.costOf(a)
	if cost <= 0 then return end
	s.spent = type(s.spent) == "table" and s.spent or {}
	s.cnt = type(s.cnt) == "table" and s.cnt or {}
	local before = tonumber(s.spent[by]) or 0
	local after = before + cost
	s.spent[by] = after
	-- (how many spendings were counted for the player: its game drops what it was waiting for, see M.pending)
	s.cnt[by] = (tonumber(s.cnt[by]) or 0) + 1
	env.log("feat perms: " .. by .. " spends " .. cost .. " (" .. tostring(a.fn) .. "), " .. after .. " this year")
	local role, team = M.roleOf(st, env, s, by, host)
	local lim = M.limitOf(s, env, by, role, team)
	if lim then
		local over = math.max(0, after - lim) - math.max(0, before - lim)
		local g = M.grantOf(s, by, team)
		if over > 0 and g then
			g.left = math.max(0, g.left - over)
			if g.left == 0 then s.grant[by] = nil end
		end
	end
end

-- ------------------------------------------------------------------------------------------------- the interface's half
-- (this game only: what it refuses, draws and writes; kept here, never in the game state)
local GUI = { pend = {}, planMode = false, route = nil, hidden = {}, drawn = {}, sig = nil, seen = nil, ownerSent = false,
	lastRefused = nil, vetoed = {} }
M.GUI = GUI

-- this player: its key, role, team, and the team's data
function M.me(st, env)
	local key = keyOf(env.me)
	local s = M.read(st)
	local role, team = M.roleOf(st, env, s, key, env.isHost == true)
	return { key = key, role = role, team = team, s = s }
end

-- What this game sent and the simulation has not counted yet (the actions travel two steps): dropped once the simulation
-- counted as many spendings of this player, or after 20 s (the engine refused it).
function M.pending(me, env)
	local cnt = me.s and type(me.s.cnt) == "table" and tonumber(me.s.cnt[me.key]) or 0
	local now = env.realTime and env.realTime() or 0
	local keep, sum = {}, 0
	for _, p in ipairs(GUI.pend) do
		if p.key == me.key and cnt < p.cnt and now < p.till then keep[#keep + 1] = p; sum = sum + p.amount end
	end
	GUI.pend = keep
	return sum
end
local function addPending(me, env, amount)
	M.pending(me, env)
	local cnt = me.s and type(me.s.cnt) == "table" and tonumber(me.s.cnt[me.key]) or 0
	GUI.pend[#GUI.pend + 1] = { key = me.key, amount = amount, cnt = cnt + #GUI.pend + 1, till = (env.realTime and env.realTime() or 0) + 20 }
end

-- whether this player may spend `cost` now; else the text why. The amount refused is kept for the window's request (keep:
-- not the store's, which asks for every row of its list on every frame)
local function budgetOk(me, env, cost, keep)
	local avail = M.available(me.s, env, me.key, me.role, me.team)
	if avail == nil then return true end
	avail = avail - M.pending(me, env)
	if cost <= avail then return true end
	if keep then GUI.lastRefused = cost end
	return false, tr(env.T, "over", fmtMoney(math.max(0, avail), env.T))
end

-- the right a command of the interface needs (nil: none)
M.CLASS = {
	makeVehicleBuyCmd = "v", makeVehicleReplaceCmd = "v", makeVehicleSellCmd = "v", makeVehicleSendToDepotCmd = "v",
	makeLineCreateCmd = "l", makeLineDestroyCmd = "l", makeLineUpdateCmd = "l", makeVehicleSetLineCmd = "l",
	makeCreateIndustryExtendProposalCmd = "b", makeWorldSetBulldozableCmd = "d",
	makeGameSetSpeedCmd = "s",
}
local ADDS = { "toAdd", "constructionsToAdd", "edgesToAdd", "nodesToAdd", "addedSegments", "addedNodes", "edgeObjectsToAdd" }
local REMOVES = { "toRemove", "constructionsToRemove", "edgesToRemove", "nodesToRemove", "removedSegments", "removedNodes", "edgeObjectsToRemove" }
-- a proposal of a window (makeWorldBuildProposalCmd's first argument, as the interface ships it): one that only takes things
-- away is a demolition, anything else a build
function M.proposalClass(args)
	local p = type(args) == "table" and args[1] or nil
	if type(p) ~= "table" then return "b" end
	local add, rem = false, false
	for _, t in ipairs({ p, type(p.proposal) == "table" and p.proposal or {}, type(p.streetProposal) == "table" and p.streetProposal or {} }) do
		for _, k in ipairs(ADDS) do if type(t[k]) == "table" and #t[k] > 0 then add = true end end
		for _, k in ipairs(REMOVES) do if type(t[k]) == "table" and #t[k] > 0 then rem = true end end
	end
	if rem and not add then return "d" end
	return "b"
end
function M.classOf(a)
	if a.fn == "makeScriptingSendEventCmd" then
		-- (the game's loans: finances_loan_gui.tl sends "Loan" "Obtain" / "Repay"; MPFever's own events are never refused: a
		-- player must still be able to ask for an approval)
		local args = type(a.args) == "table" and a.args or {}
		if args[2] == "Loan" then return "m" end
		return nil
	end
	if a.fn == "makeWorldBuildProposalCmd" then return M.proposalClass(a.args) end
	return M.CLASS[a.fn]
end

-- THIS player's own command, before it is shipped (the options host's hook in the bridge, for the commands held by the
-- interface and the speed requests): false and why to refuse it here. A native build (a.native: a tool's, already done on this
-- game) and a terrain edit are never refused here: dropping them would leave the tool waiting (#91) or the ground changed on
-- this game only. The tools are refused before the click (M.guiVeto).
function M.allow(a, st, env)
	if M.VETO_OFF or type(a) ~= "table" or not env.on("perms") then return true end
	if a.native or a.uiEdit or a.fn == "terrainEdit" then return true end
	local letter = M.classOf(a)
	local cost = a.fn == "makeVehicleBuyCmd" and M.costOf(a) or 0
	if not letter and cost <= 0 then return true end
	local me = M.me(st, env)
	if not restricted(me.role) then return true end
	if letter and not M.rightsOf(me.s, me.key, me.role, me.team):find(letter, 1, true) then
		return false, tr(env.T, "no_" .. letter)
	end
	if cost > 0 then
		local ok, why = budgetOk(me, env, cost, true)
		if not ok then return false, why end
		addPending(me, env, cost)
	end
	return true
end

-- the points of a tool's route (env.pvPoints: the bridge's G.pvPoints, { {x, y[, r]}... }: the segments' points, then a circle
-- per construction), one every M.ROUTE_STEP metres (the constructions' circles and the route's last point always kept), at
-- most M.MAX_POINTS
function M.simplify(pts)
	local out, last = {}, nil
	pts = type(pts) == "table" and pts or {}
	for i, q in ipairs(pts) do
		local x, y, r = tonumber(q[1] or q.x), tonumber(q[2] or q.y), tonumber(q[3])
		if x and y and x == x and y == y then
			local far = not last or (x - last[1]) ^ 2 + (y - last[2]) ^ 2 >= M.ROUTE_STEP ^ 2
			-- (the route's end: the last point, or the last before the constructions' circles)
			local ends = i == #pts or (type(pts[i + 1]) == "table" and tonumber(pts[i + 1][3]) ~= nil and not r)
			if far or r or ends then
				last = { x, y, r and math.min(200, math.max(1, r)) or nil }
				out[#out + 1] = last
				if #out >= M.MAX_POINTS then break end
			end
		end
	end
	return out
end

-- The game's interface events (the options host's hook in the bridge's guiHandleEvent; its return value is the hook's):
--  * builder.proposalCreate: a tool's proposal; in plan mode the route is kept and the build turned down (the route still
--    shows: skipRender false); else a tool needs the right to build (to bulldoze for the bulldozer) and the budget for its
--    cost (ProposalData.costs). The game's own vetoes work the same way (company.script.tl, permits);
--  * builder.proposalApply: the build goes; its cost waits for the simulation's count (M.pending);
--  * vehicleStore / mission.buyVehicle: the store asks before it shows a buy button (a text = the button is off, the text
--    says why: vehicle_store_window.tl);
--  * management.line / delete: true keeps the line (manager_window.tl).
-- nil when nothing is turned down (the game's other scripts keep their say).
function M.guiVeto(id, name, param, st, env)
	if name == "builder.proposalCreate" or name == "builder.proposalApply" then
		local tool = tostring(id)
		local cost = 0
		pcall(function() cost = tonumber(param[2].costs) or 0 end)
		if name == "builder.proposalApply" then
			-- (for the in-game check: a build the game applied although its proposal was turned down here, the game did not heed
			-- the answer alongside its own scripts' answers)
			if GUI.vetoed[tool] then env.log("feat perms: WARNING the tool " .. tool .. " applied a build this game turned down (" .. GUI.vetoed[tool] .. ")") end
			if cost > 0 and not M.VETO_OFF and env.on("perms") then
				local me = M.me(st, env)
				if restricted(me.role) then addPending(me, env, cost) end
			end
			return nil
		end
		GUI.vetoed[tool] = nil
		if GUI.planMode and tool ~= "bulldozer" and env.on("plans") then
			if type(env.pvPoints) == "function" then
				local ok, pts = pcall(env.pvPoints, param)
				local list = ok and M.simplify(pts) or {}
				if #list >= 2 then GUI.route = { pts = M.encodePts(list), n = #list, tool = tool } end
			end
			GUI.vetoed[tool] = "plan mode"
			return { errorMessages = { [tr(env.T, "plan_mode")] = true }, skipRender = false }
		end
		if M.VETO_OFF or not env.on("perms") then return nil end
		local me = M.me(st, env)
		if not restricted(me.role) then return nil end
		local letter = tool == "bulldozer" and "d" or "b"
		local why = nil
		if not M.rightsOf(me.s, me.key, me.role, me.team):find(letter, 1, true) then
			why = tr(env.T, "no_" .. letter)
		elseif cost > 0 then
			local ok, w = budgetOk(me, env, cost, true)
			if not ok then why = w end
		end
		if why then
			GUI.vetoed[tool] = why
			return { errorMessages = { [why] = true }, skipRender = false }
		end
		return nil
	end
	if M.VETO_OFF or not env.on("perms") then return nil end
	if id == "vehicleStore" and name == "mission.buyVehicle" then
		local me = M.me(st, env)
		if not restricted(me.role) then return nil end
		if not M.rightsOf(me.s, me.key, me.role, me.team):find("v", 1, true) then return tr(env.T, "no_v") end
		local price = 0
		pcall(function()
			for modelId, n in pairs(param.modelId2quantity) do
				price = price + M.modelPrice(tonumber(modelId)) * math.max(0, tonumber(n) or 0)
			end
		end)
		if price > 0 then
			local ok, why = budgetOk(me, env, price)
			if not ok then return why end
		end
		return nil
	end
	if id == "management.line" and name == "delete" then
		local me = M.me(st, env)
		if restricted(me.role) and not M.rightsOf(me.s, me.key, me.role, me.team):find("l", 1, true) then return true end
	end
	return nil
end

-- this player's colour for its plans: its company's (separate mode), else env.myColor (a palette index), else from its key
local function myColor(st, env, me)
	local reg = regOf(st, env)
	if reg and me.team then
		local c = findCo(reg, me.team)
		if c and tonumber(c.color) then return tonumber(c.color) end
	end
	return tonumber(env.myColor)
end

-- The window's requests (u.request on this game). Checked here as the simulation will check them: a request the simulation
-- would refuse is not sent. Returns whether something was sent or changed.
function M.request(kind, payload, st, env)
	local p = parts(payload)
	local onP, onPl = env.on("perms"), env.on("plans")
	local me = M.me(st, env)
	local s = me.s
	if kind == "right" and onP then
		local target, letter = keyOf(p[1]), tostring(p[2] or "")
		if #letter ~= 1 or not M.ALL:find(letter, 1, true) then return false end
		if not M.canManage(st, env, s, me.key, env.isHost == true, target) then return false end
		local rt, tt = M.roleOf(st, env, s, target, false)
		local has = M.rightsOf(s, target, rt, tt):find(letter, 1, true) ~= nil
		env.send("f_perms_set", has and { key = target, del = letter } or { key = target, add = letter })
		return true
	elseif kind == "budget" and onP then
		local target = keyOf(p[1])
		if not M.canManage(st, env, s, me.key, env.isHost == true, target) then return false end
		local b = p[2]
		if b ~= "default" then
			b = tonumber(b)
			if not b then return false end
		end
		env.send("f_perms_set", { key = target, b = b })
		return true
	elseif kind == "lead" and onP then
		local target = keyOf(p[1])
		if not M.canName(st, env, s, me.key, env.isHost == true, target) then return false end
		env.send("f_perms_lead", { key = target, on = p[2] == "1" or p[2] == true or p[2] == 1 })
		return true
	elseif kind == "ask" and onP then
		-- (an amount typed with spaces, commas or apostrophes between its digits)
		local amount = amountOf((tostring(p[1] or ""):gsub("[%s,'.]", "")))
		if not amount or not restricted(me.role) then return false end
		env.send("f_perms_ask", { amount = amount, note = clean(p[2], M.NOTE_LEN) })
		return true
	elseif kind == "cancel" and onP then
		env.send("f_perms_cancel", {})
		return true
	elseif kind == "answer" and onP then
		local n = tonumber(p[1])
		for _, a in ipairs(s and type(s.asks) == "table" and s.asks or {}) do
			if a.n == n and M.canManage(st, env, s, me.key, env.isHost == true, a.key) then
				env.send("f_perms_answer", { n = n, ok = p[2] == "1" or p[2] == true or p[2] == 1 })
				return true
			end
		end
		return false
	elseif kind == "planmode" and onPl then
		GUI.planMode = p[1] == "1" or p[1] == true or p[1] == 1
		if not GUI.planMode then GUI.route = nil end
		env.log("perms: plan mode " .. (GUI.planMode and "on" or "off"))
		return true
	elseif kind == "keep" and onPl then
		if not GUI.route then return false end
		local name = clean(p[1], M.NAME_LEN)
		if name == "" then name = tr(env.T, "route_of", select(2, keyOf(env.me))) end
		env.send("f_perms_plan", { kind = "route", name = name, pts = GUI.route.pts, c = myColor(st, env, me) })
		GUI.route = nil
		return true
	elseif kind == "note" and onPl then
		local okC, x, y, z = pcall(M.draw.center)
		if not (okC and tonumber(x) and tonumber(y)) then
			env.log("feat perms: the centre of the view is not known, no note: " .. tostring(okC and x or x))
			return false
		end
		env.log("feat perms: a note at the centre of the view " .. math.floor(tonumber(x)) .. "," .. math.floor(tonumber(y)))
		local name = clean(p[1], M.NAME_LEN)
		if name == "" then name = tr(env.T, "note_of", select(2, keyOf(env.me))) end
		env.send("f_perms_plan", { kind = "note", name = name, text = clean(p[2], M.TEXT_LEN),
			pts = M.encodePts({ { tonumber(x), tonumber(y) } }), z = tonumber(z) or 0, c = myColor(st, env, me) })
		return true
	elseif kind == "plandel" and onPl then
		env.send("f_perms_plandel", { id = tonumber(p[1]) })
		return true
	elseif kind == "hide" and onPl then
		local id = tonumber(p[1])
		if not id then return false end
		GUI.hidden[id] = not GUI.hidden[id] or nil
		return true
	elseif kind == "see" and onPl then
		local id = tonumber(p[1])
		for _, q in ipairs(s and type(s.plans) == "table" and s.plans or {}) do
			if q.id == id then
				local pts = M.parsePts(q.pts, M.MAX_POINTS)
				if pts then
					local i = math.floor((#pts + 1) / 2)
					pcall(M.draw.focus, pts[i][1], pts[i][2], tonumber(q.z) or 0)
					return true
				end
			end
		end
		return false
	end
	return false
end

-- Drawing on the map: the game's mission zones (as the build previews and the map signals: interface only, never
-- prohibitBuilding). Replaceable functions (the tests draw nothing).
M.draw = {
	circle = function(key, x, y, r, c)
		api.gui.mission.setZoneCircle(key, api.type.Vec2f.new(x, y), r, true, api.type.Vec4f.new(c[1], c[2], c[3], c[4]), false, false)
	end,
	remove = function(key) api.gui.mission.removeZone(key) end,
	focus = function(x, y, z) api.gui.camera.focusPosition(api.type.Vec3f.new(x, y, z or 0), 600) end,
	-- the point at the centre of the view (getCameraData: Vec5f x, y, distance, angle, pitch) and the ground's height there
	center = function()
		local d = api.gui.camera.getCameraData()
		local x, y = d.x or d[1], d.y or d[2]
		local z = 0
		pcall(function() z = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(x, y)) end)
		return x, y, z
	end,
}

-- the plans this player sees (H6): all in co-op, its company's in the separate mode
function M.visiblePlans(st, env, me)
	local out = {}
	local sep = M.modeOf(st, env) == "separate"
	for _, q in ipairs(me.s and type(me.s.plans) == "table" and me.s.plans or {}) do
		if not sep or (me.team ~= nil and q.co == me.team) then out[#out + 1] = q end
	end
	return out
end

local function clearDrawn()
	for _, k in ipairs(GUI.drawn) do pcall(M.draw.remove, k) end
	GUI.drawn = {}
	GUI.sig = nil
end
M.clearDrawn = clearDrawn

-- the plans on the map, drawn again only when the list (or what this player hides) changed
local function drawPlans(st, env, me)
	local list = M.visiblePlans(st, env, me)
	local sig = {}
	for _, q in ipairs(list) do sig[#sig + 1] = q.id .. (GUI.hidden[q.id] and "h" or "") end
	sig = table.concat(sig, ",")
	if sig == GUI.sig then return end
	clearDrawn()
	GUI.sig = sig
	local n = 0
	for _, q in ipairs(list) do
		if not GUI.hidden[q.id] then
			local pts = M.parsePts(q.pts, M.MAX_POINTS) or {}
			local r, g, b = M.rgb(q.c, q.key)
			for i, pt in ipairs(pts) do
				if n >= M.MAX_ZONES then break end
				local key = "mpfever_plan_" .. q.id .. "_" .. i
				local ok
				if q.kind == "note" then
					ok = pcall(M.draw.circle, key, pt[1], pt[2], 40, { r, g, b, 0.3 })
					if ok then n = n + 1; GUI.drawn[#GUI.drawn + 1] = key end
					key = key .. "_c"
					ok = pcall(M.draw.circle, key, pt[1], pt[2], 10, { r, g, b, 0.8 })
				else
					ok = pcall(M.draw.circle, key, pt[1], pt[2], pt[3] or 6, { r, g, b, 0.35 })
				end
				if ok then n = n + 1; GUI.drawn[#GUI.drawn + 1] = key end
			end
		end
	end
end

-- (a plan's size for the window: a route's length in km with one decimal, a note's points; a plan never changes, its size is
-- kept by its id: the window's file is made every second)
local function sizeText(q)
	local key = tostring(q.id) .. "/" .. tostring(q.pts)
	GUI.sizes = GUI.sizes or {}
	local c = GUI.sizes[q.id]
	if c and c.key == key then return c.text end
	local pts = M.parsePts(q.pts, M.MAX_POINTS) or {}
	local text = tostring(#pts)
	if q.kind == "route" then
		local d = 0
		for i = 2, #pts do d = d + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2) end
		text = string.format("%.1f km", d / 1000)
	end
	GUI.sizes[q.id] = { key = key, text = text }
	return text
end

local function nameOf(s, key)
	return (s and type(s.who) == "table" and s.who[key]) or key
end

-- the players a leader or lead sees in the tab: its company's (separate mode); in co-op every player seen, set or named, and
-- those of the session (env.players(), optional)
local function teamKeys(st, env, me)
	local reg = regOf(st, env)
	local keys, seen = {}, {}
	local function add(k)
		k = keyOf(k)
		if k ~= "" and k ~= me.key and k:sub(1, 3) ~= "ai:" and not seen[k] then seen[k] = true; keys[#keys + 1] = k end
	end
	if reg then
		local c = me.team and findCo(reg, me.team)
		if c then for _, m in ipairs(members(c)) do add(memberKey(m)) end end
	else
		local s = me.s
		for k in pairs(s and type(s.who) == "table" and s.who or {}) do add(k) end
		for k, e in pairs(s and type(s.p) == "table" and s.p or {}) do if type(e) == "table" and e.co == 0 then add(k) end end
		for k, t in pairs(s and type(s.lead) == "table" and s.lead or {}) do if t == 0 then add(k) end end
		if type(env.players) == "function" then
			local ok, list = pcall(env.players)
			if ok and type(list) == "table" then for _, n in ipairs(list) do add(n) end end
		end
	end
	table.sort(keys)
	return keys
end

-- (a budget code for the file and the window: "default", "-1" or the amount)
local function budgetCode(s, key, team)
	local e = entryOf(s, key, team)
	if not e or e.b == nil then return "default" end
	return tostring(math.floor(e.b))
end

local function field(t) return clean(t, 300) end

-- What the window shows, written to the session folder (feat_perms_team.txt through env.write, only when it changed), one fact
-- per line, tab-separated:
--   opt     perms(0/1) plans(0/1) mode
--   me      key role rights limit(-: none) spent grantLeft grantMonths avail(-: none) lastRefused askN askAmount
--   player  key name role rights budgetCode spent grantLeft lead(0/1) canManage(0/1) canName(0/1)
--   ask     n key name amount note canAnswer(0/1)
--   planmode on(0/1) routePoints
--   plan    id author kind name text length/points shown(0/1) canDelete(0/1) colour
function M.lines(st, env, me)
	local s = me.s
	local onP, onPl = env.on("perms"), env.on("plans")
	local L = { table.concat({ "opt", onP and "1" or "0", onPl and "1" or "0", M.modeOf(st, env) }, "\t") }
	if onP then
		local avail, lim, spent, g = M.available(s, env, me.key, me.role, me.team)
		spent = spent or (s and type(s.spent) == "table" and tonumber(s.spent[me.key])) or 0
		local myAsk = nil
		for _, a in ipairs(s and type(s.asks) == "table" and s.asks or {}) do if a.key == me.key then myAsk = a end end
		g = g or M.grantOf(s, me.key, me.team)
		local months = (g and g.till and s.mon) and math.max(0, g.till - s.mon) or (g and M.GRANT_MONTHS or 0)
		L[#L + 1] = table.concat({ "me", me.key, me.role, M.rightsOf(s, me.key, me.role, me.team), lim and tostring(lim) or "-",
			tostring(math.floor(spent)), tostring(g and g.left or 0), tostring(months),
			avail and tostring(math.floor(avail - M.pending(me, env))) or "-", tostring(GUI.lastRefused or 0),
			tostring(myAsk and myAsk.n or 0), tostring(myAsk and myAsk.amount or 0) }, "\t")
		if me.role == "top" or me.role == "lead" then
			for _, k in ipairs(teamKeys(st, env, me)) do
				local rt, tt = M.roleOf(st, env, s, k, false)
				local gk = M.grantOf(s, k, tt)
				L[#L + 1] = table.concat({ "player", k, field(nameOf(s, k)), rt, M.rightsOf(s, k, rt, tt), budgetCode(s, k, tt),
					tostring(math.floor(s and type(s.spent) == "table" and tonumber(s.spent[k]) or 0)), tostring(gk and gk.left or 0),
					rt == "lead" and "1" or "0", M.canManage(st, env, s, me.key, env.isHost == true, k) and "1" or "0",
					M.canName(st, env, s, me.key, env.isHost == true, k) and "1" or "0" }, "\t")
			end
		end
		for _, a in ipairs(s and type(s.asks) == "table" and s.asks or {}) do
			local can = M.canManage(st, env, s, me.key, env.isHost == true, a.key)
			if can then
				L[#L + 1] = table.concat({ "ask", tostring(a.n), a.key, field(nameOf(s, a.key)), tostring(a.amount), field(a.note), "1" }, "\t")
			end
		end
	end
	if onPl then
		L[#L + 1] = table.concat({ "planmode", GUI.planMode and "1" or "0", tostring(GUI.route and GUI.route.n or 0) }, "\t")
		for _, q in ipairs(M.visiblePlans(st, env, me)) do
			local canDel = q.key == me.key
			if not canDel then
				canDel = q.co == me.team and (me.role == "top" or (me.role == "lead" and M.canManage(st, env, s, me.key, env.isHost == true, q.key)))
			end
			L[#L + 1] = table.concat({ "plan", tostring(q.id), field(q.who or q.key), q.kind, field(q.name), field(q.text),
				sizeText(q), GUI.hidden[q.id] and "0" or "1", canDel and "1" or "0",
				tostring(q.c or 0) }, "\t")
		end
	end
	return L
end

-- This player's notices in its own chat: a request it can answer, the answer to its request, its rights changed. Nothing the
-- first time (what the data held at the load is no news).
local function notices(st, env, me)
	local s = me.s
	local maxAsk = 0
	for _, a in ipairs(s and type(s.asks) == "table" and s.asks or {}) do
		if a.n > maxAsk then maxAsk = a.n end
		if GUI.seen and a.n > GUI.seen.ask and M.canManage(st, env, s, me.key, env.isHost == true, a.key) then
			env.chat(tr(env.T, "ask_news", nameOf(s, a.key), fmtMoney(a.amount, env.T), a.note or ""))
		end
	end
	local ans = s and type(s.ans) == "table" and s.ans[me.key] or nil
	local ansN = ans and tonumber(ans.n) or 0
	local rights = M.rightsOf(s, me.key, me.role, me.team) .. "/" .. budgetCode(s, me.key, me.team) .. "/" .. tostring(me.role)
	if GUI.seen then
		if ansN > GUI.seen.ans then
			if ans.ok then env.chat(tr(env.T, "granted", ans.by or "?", fmtMoney(ans.amount or 0, env.T)))
			else env.chat(tr(env.T, "denied", ans.by or "?")) end
		end
		if rights ~= GUI.seen.rights and restricted(me.role) then
			local names = {}
			local r = M.rightsOf(s, me.key, me.role, me.team)
			for i = 1, #r do names[#names + 1] = tr(env.T, "right_" .. r:sub(i, i)) end
			local lim = M.limitOf(s, env, me.key, me.role, me.team)
			env.chat(tr(env.T, "changed", #names > 0 and table.concat(names, ", ") or tr(env.T, "none"),
				lim and fmtMoney(lim, env.T) or tr(env.T, "unlimited")))
		end
	end
	GUI.seen = { ask = math.max(maxAsk, GUI.seen and GUI.seen.ask or 0), ans = math.max(ansN, GUI.seen and GUI.seen.ans or 0), rights = rights }
end

-- About once a second on every game (read only: st is the game state as the interface sees it).
function M.gui(st, env)
	local onP, onPl = env.on("perms"), env.on("plans")
	if not onPl then
		-- (the plans' option switched off: nothing of them stays on this game's map)
		if #GUI.drawn > 0 then clearDrawn() end
		GUI.planMode, GUI.route = false, nil
	end
	if not (onP or onPl) then return end
	local me = M.me(st, env)
	-- The host's decision: a dedicated server's game (the host of a co-op game, it plays no part) names the player its settings
	-- name as the owner (env.owner) a team lead, once, so that somebody manages the team. Sent as an event: every game applies it.
	if onP and env.isHost and type(env.owner) == "string" and env.owner ~= "" and not GUI.ownerSent and M.modeOf(st, env) == "shared" then
		GUI.ownerSent = true
		local ok = keyOf(env.owner)
		if ok ~= me.key and not (me.s and type(me.s.lead) == "table" and me.s.lead[ok] == 0) then
			env.send("f_perms_lead", { key = ok, on = true })
		end
	end
	if onP then notices(st, env, me) end
	if onPl then drawPlans(st, env, me) end
	env.write(M.FILE, M.lines(st, env, me))
end

-- ------------------------------------------------------------------------------------------------- the window's tab
-- The tab's data read back from feat_perms_team.txt (u.read), as a table
function M.model(lines)
	local m = { opt = {}, players = {}, asks = {}, plans = {} }
	for _, line in ipairs(type(lines) == "table" and lines or {}) do
		local f = parts(tostring(line):gsub("\r$", ""))
		local k = f[1]
		if k == "opt" then m.opt = { perms = f[2] == "1", plans = f[3] == "1", mode = f[4] }
		elseif k == "me" then
			m.me = { key = f[2], role = f[3], rights = f[4] or "", limit = tonumber(f[5]), spent = tonumber(f[6]) or 0,
				grant = tonumber(f[7]) or 0, months = tonumber(f[8]) or 0, avail = tonumber(f[9]), refused = tonumber(f[10]) or 0,
				askN = tonumber(f[11]) or 0, askAmount = tonumber(f[12]) or 0 }
		elseif k == "player" then
			m.players[#m.players + 1] = { key = f[2], name = f[3], role = f[4], rights = f[5] or "", budget = f[6], spent = tonumber(f[7]) or 0,
				grant = tonumber(f[8]) or 0, lead = f[9] == "1", canManage = f[10] == "1", canName = f[11] == "1" }
		elseif k == "ask" then
			m.asks[#m.asks + 1] = { n = tonumber(f[2]), key = f[3], name = f[4], amount = tonumber(f[5]) or 0, note = f[6] or "" }
		elseif k == "planmode" then m.planMode, m.route = f[2] == "1", tonumber(f[3]) or 0
		elseif k == "plan" then
			m.plans[#m.plans + 1] = { id = tonumber(f[2]), who = f[3], kind = f[4], name = f[5], text = f[6] or "", size = f[7],
				shown = f[8] == "1", canDel = f[9] == "1", c = tonumber(f[10]) }
		end
	end
	return m
end

-- the next budget code of a leader's button (default, no limit, 0, the amounts, default again)
function M.nextBudget(code)
	if code == "default" then return tostring(M.BUDGETS[1]) end
	local n = tonumber(code)
	for i, b in ipairs(M.BUDGETS) do
		if b == n then return M.BUDGETS[i + 1] and tostring(M.BUDGETS[i + 1]) or "default" end
	end
	return "default"
end

-- (what the player typed in the tab's fields: the window builds its tabs again every second, these stay in its Lua state)
local UIV = { amount = "", reason = "", name = "", text = "" }
M.UIV = UIV

-- The tab, with the window's helpers (U.featU in mpfever_ui.script.lua): u.T, u.read, u.request, and widgets u.text(t),
-- u.button(label, fn, primary, enabled), u.row(list); optional: u.muted(t), u.title(t) (a section's title), u.input(placeholder,
-- onValue, key) (a text field that keeps what was typed across the window's rebuilds; without it the amounts are buttons and the
-- plans take their author's name). Returns the list of rows, top to bottom. Sentences never share a row with buttons; a row holds
-- three buttons at most (the labels are long, the window is 556 pixels wide).
M.ROW_BUTTONS = 3
function M.ui(u)
	local T = u.T
	local function t(id, ...) return tr(T, id, ...) end
	local function money(n) return fmtMoney(n, T) end
	local rows = {}
	local function text(s) rows[#rows + 1] = u.text(s) end
	local function muted(s) rows[#rows + 1] = (u.muted or u.text)(s) end
	local function section(s) rows[#rows + 1] = (u.title or u.text)(s) end
	local function buttons(list)
		local per = M.ROW_BUTTONS
		for i = 1, #list, per do
			local r = {}
			for j = i, math.min(#list, i + per - 1) do r[#r + 1] = u.button(list[j][1], list[j][2], nil, list[j][3]) end
			rows[#rows + 1] = u.row and u.row(r) or r[1]
		end
	end
	local function req(kind, payload) return function() u.request(kind, payload) end end
	local m = M.model(u.read(M.FILE))
	if not m.opt.perms and not m.opt.plans then
		muted(t("waiting"))
		return rows
	end
	local function rightNames(r, present)
		local out = {}
		for i = 1, #M.ALL do
			local c = M.ALL:sub(i, i)
			if (r:find(c, 1, true) ~= nil) == present then out[#out + 1] = t("right_" .. c) end
		end
		return table.concat(out, ", ")
	end
	if m.opt.perms and m.me then
		local me = m.me
		section(t("h_mine"))
		local roleText = ({ top = m.opt.mode == "separate" and t("role_chief") or t("role_host"), lead = t("role_lead"),
			member = t("role_member"), free = t("role_free") })[me.role] or tostring(me.role)
		text(t("role", roleText))
		if restricted(me.role) then
			local yes, no = rightNames(me.rights, true), rightNames(me.rights, false)
			text(t("allowed", no == "" and t("every") or (yes == "" and t("none") or yes)))
			if no ~= "" then text(t("denied_list", no)) end
			if me.limit then text(t("budget_of", money(me.spent), money(me.limit))) else text(t("budget_free", money(me.spent))) end
			if me.grant > 0 then text(t("grant", money(me.grant), me.months)) end
			if me.askN > 0 then
				text(t("my_ask", money(me.askAmount)))
				buttons({ { t("withdraw"), req("cancel", "") } })
			else
				text(t("ask_for"))
				local list = {}
				if me.refused > 0 then
					local r = math.ceil(me.refused / 10000) * 10000
					list[#list + 1] = { money(r), req("ask", tostring(r)) }
				end
				for _, a in ipairs(M.ASK_AMOUNTS) do list[#list + 1] = { money(a), req("ask", tostring(a)) } end
				buttons(list)
				if u.input then
					rows[#rows + 1] = u.input(t("amount"), function(v) UIV.amount = tostring(v or "") end, "perms-amount")
					rows[#rows + 1] = u.input(t("reason"), function(v) UIV.reason = tostring(v or "") end, "perms-reason")
					buttons({ { t("ask"), function() u.request("ask", UIV.amount .. "\t" .. UIV.reason) end } })
				end
			end
		else
			if me.spent > 0 then muted(t("budget_free", money(me.spent))) end
		end
		if #m.asks > 0 then
			section(t("h_asks"))
			for _, a in ipairs(m.asks) do
				text(t("ask_line", a.name, money(a.amount), a.note))
				buttons({ { t("accept"), req("answer", a.n .. "\t1") }, { t("refuse"), req("answer", a.n .. "\t0") } })
			end
		end
		if #m.players > 0 then
			section(t("h_players"))
			for _, p in ipairs(m.players) do
				local roleP = ({ top = m.opt.mode == "separate" and t("role_chief") or t("role_host"), lead = t("role_lead"),
					member = t("role_member"), free = t("role_free") })[p.role] or p.role
				local b = p.budget == "default" and t("b_default", t("unlimited")) or
					(tonumber(p.budget) and tonumber(p.budget) < 0 and t("unlimited") or money(tonumber(p.budget) or 0))
				text(t("player_line", p.name, roleP, money(p.spent), b))
				if p.canManage then
					local list = {}
					for i = 1, #M.ALL do
						local c = M.ALL:sub(i, i)
						local has = p.rights:find(c, 1, true) ~= nil
						list[#list + 1] = { t(has and "on_mark" or "off_mark", t("right_" .. c)), req("right", p.key .. "\t" .. c) }
					end
					list[#list + 1] = { t("budget_btn", b), req("budget", p.key .. "\t" .. M.nextBudget(p.budget)) }
					if p.canName then list[#list + 1] = { t(p.lead and "lead_yes" or "lead_no"), req("lead", p.key .. "\t" .. (p.lead and "0" or "1")) } end
					buttons(list)
				end
			end
		end
	end
	if m.opt.plans then
		section(t("h_plans"))
		muted(t("plans_help"))
		if u.input then
			rows[#rows + 1] = u.input(t("plan_name"), function(v) UIV.name = tostring(v or "") end, "perms-plan-name")
			rows[#rows + 1] = u.input(t("note_text"), function(v) UIV.text = tostring(v or "") end, "perms-note-text")
		end
		buttons({
			{ t(m.planMode and "planmode_on" or "planmode_off"), req("planmode", m.planMode and "0" or "1") },
			{ t("keep", m.route or 0), function() u.request("keep", UIV.name) end, (m.route or 0) >= 2 },
			{ t("note_here"), function() u.request("note", UIV.name .. "\t" .. UIV.text) end },
		})
		if #m.plans == 0 then muted(t("no_plan")) end
		for _, q in ipairs(m.plans) do
			if q.kind == "route" then text(t("plan_route", q.who, q.name, q.size)) else text(t("plan_note", q.who, q.name, q.text)) end
			local list = { { t("view"), req("see", tostring(q.id)) }, { t(q.shown and "hide" or "show"), req("hide", tostring(q.id)) } }
			if q.canDel then list[#list + 1] = { t("delete"), req("plandel", tostring(q.id)) } end
			buttons(list)
		end
	end
	return rows
end

return M
