-- MPFever 0.6 game options: the players' journal, « built by » and a player's view (ideas G1, G2 and G4 of
-- release/recherche-0.6/07-coop-journal-signal.md; the map signals, G3, are the bridge's own since 0.5.14: H.ping).
--
-- Three options of the lobby's game settings, off by default (while they are off nothing at all happens here: no state, no
-- event, no file, no chat):
--   journal     a tab of the MPFever window lists what every player builds, demolishes, buys and sells, the latest first; the
--               details (signals, stops, line changes, terrain, trees...) behind a switch of the tab, whose default is the
--               option's parameter. In the separate mode the rivals show too, as the computer companies do in their tab. The
--               chat only tells « X demolished what Y built ».
--   builtby     the stations and constructions keep the player who built them (and who last changed them) in the savegame;
--               their window shows it (the window's U.featBuiltBy: M.builtByText, M.creatorText for vehicles and lines).
--   playerview  a player takes the camera to where another player looks (in the separate mode only between the members of one
--               company); every player may refuse it (a switch of the tab, kept in the savegame).
--
-- Where it runs (docs/FEATURES-0.6.md):
--   simulation half, every game: M.onAction makes the journal's entries and keeps the registry of who built what from the
--     actions every game replays (nothing new on the network), from the copies M.digest takes before the bridge translates
--     them (the options host's F.digests; the tools' builds with their builder through the bridge's G.featNativeAct); M.event
--     applies the events of the view.
--   GUI half, every game: M.gui writes the window's files, tells a demolition in the chat, answers a request for this player's
--     view and takes the view this player asked for. The host's game alone ends a request nobody answers (M.CAM_TIMEOUT
--     seconds of real time: one decider, the games' clocks differ and the game time stands still in a pause).
--   the window: M.ui builds the tab from those files.
--
-- The state (st.feat.journal, saved with the game) is plain data: strings, numbers, booleans and small tables. The journal and
-- the registry are each ONE string, a line per entry: the state is copied at every read and the interface reads it at every
-- frame; a string of 40 KB is copied at once where 300 small tables would be copied one value at a time (see the note, 4.2).
--   v        format (1)
--   log      the journal: "\n", then one line per entry (M.FIELDS, tab-separated), sorted by game time then action, M.MAX_LOG
--            at most; nlog its lines, la / lu the time and action of its last line, seq the entries taken so far (a change
--            mark for the interface)
--   reg      the registry: "\n", then "key TAB who TAB at TAB editor" lines, the oldest first, M.MAX_REG at most; nreg its lines
--   uids     the last actions taken ("uid@at", M.MAX_UIDS): an action given twice makes one entry; nuids its lines
--   who      player key -> the name it shows (the players seen, for the view's list); nwho their number
--   noview   player key -> true: that player refuses that the others see its view
--   cam      the requests of a view under way { id, from, fn, to, tn, at }; camN the requests so far
--   ans      the last answers { id, to, from, fn, d = { x, y, distance, angle, pitch } | no = why }
-- A player key is its name without "#n", in lower case: the key of the companies registry (the bridge's G.coMyKey).
--
-- The entries are sorted by (game time, action) and merged by (player, kind, what, slice of M.MERGE_MS of game time): two games
-- that get the same actions in another order (a native build handed over a frame later) end with the same journal.

local M = {}
M.ID = "journal"

M.MAX_LOG = 300          -- entries kept in the journal
M.MAX_REG = 2000         -- constructions kept in the registry (about 200 KB)
M.MAX_UIDS = 200         -- actions remembered against a second copy
M.MAX_WHO = 64           -- players remembered by name
M.MERGE_MS = 30000       -- roads, signals, terrain... of one player within 30 s of game time make one entry
M.CAM_TIMEOUT = 8        -- seconds of real time (on the host's game) before a request of a view nobody answers ends
M.CAM_MAX = 8            -- requests of a view under way at most
M.ANS_MAX = 6            -- answers kept (each game takes the ones for its player)
M.TOL = 1                -- metres: a construction's place read back from the engine rounds to a neighbour metre at worst
M.SHOW_MAX = 40          -- entries the tab shows

-- the files of the session folder the GUI half writes (env.write) and the window reads (u.read): feat_journal_<name>.txt
M.FILE = "log"              -- feat_journal_log.txt, the tab: a header ("@" lines), then the journal's lines
M.FILE_BUILTBY = "builtby"  -- feat_journal_builtby.txt, the registry's lines, for the windows of the stations and constructions

-- the fields of a journal's line, in their order
M.FIELDS = { "mk", "at", "uid", "who", "co", "kind", "det", "x", "y", "z", "a", "b", "n", "c", "ym" }
local NUMERIC = { at = true, co = true, det = true, x = true, y = true, z = true, n = true, c = true, ym = true }

-- the kinds merged with the same kind of the same player in the same 30 s
local MERGED = {
	road = true, track = true, road_del = true, track_del = true, road_mod = true, track_mod = true, stop = true, signal = true,
	waypoint = true, terrain = true, trees = true, trees_del = true, buy = true, sell = true, replace = true, lineupd = true,
	assign = true, todepot = true, houses = true,
}
-- the kinds whose construction goes into the registry
local BUILT = { station = true, depot = true, con = true }

-- Texts shown to the players: { French, English }, put through the game's T (the language of each game) by M.say. In a table
-- rather than T("...", "...") calls: the interface's T, the GUI's and the lobby's are given at run time.
M.TEXTS = {
	yes = { "oui", "yes" },
	no = { "non", "no" },
	built_station = { "%s a construit la gare %s", "%s built the station %s" },
	built_depot = { "%s a construit le dépôt %s", "%s built the depot %s" },
	built_con = { "%s a construit %s", "%s built %s" },
	edit = { "%s a modifié %s", "%s changed %s" },
	edit_by = { "%s a modifié %s, construit par %s", "%s changed %s, built by %s" },
	demolish = { "%s a démoli %s", "%s demolished %s" },
	demolish_by = { "%s a démoli %s, construit par %s", "%s demolished %s, built by %s" },
	a_construction = { "une construction", "a construction" },
	a_vehicle = { "un modèle inconnu", "an unknown model" },
	houses = { "%s a démoli %s bâtiment(s) de ville", "%s demolished %s town building(s)" },
	road = { "%s a construit %s m de route", "%s built %s m of road" },
	track = { "%s a construit %s m de voie", "%s built %s m of track" },
	road_del = { "%s a démoli %s m de route", "%s demolished %s m of road" },
	track_del = { "%s a démoli %s m de voie", "%s demolished %s m of track" },
	road_mod = { "%s a modifié %s m de route", "%s changed %s m of road" },
	track_mod = { "%s a modifié %s m de voie", "%s changed %s m of track" },
	stop = { "%s a placé %s arrêt(s)", "%s placed %s stop(s)" },
	signal = { "%s a placé %s signal(aux)", "%s placed %s signal(s)" },
	waypoint = { "%s a placé %s point(s) de passage", "%s placed %s waypoint(s)" },
	terrain = { "%s a modifié le terrain (×%s)", "%s changed the terrain (×%s)" },
	trees = { "%s a placé %s arbre(s) ou rocher(s)", "%s placed %s tree(s) or rock(s)" },
	trees_del = { "%s a retiré des arbres ou des rochers", "%s removed trees or rocks" },
	buy = { "%s a acheté %s véhicule(s) : %s", "%s bought %s vehicle(s): %s" },
	sell = { "%s a vendu %s véhicule(s)", "%s sold %s vehicle(s)" },
	sell_by = { "%s a vendu %s véhicule(s) acheté(s) par %s", "%s sold %s vehicle(s) bought by %s" },
	replace = { "%s a fait remplacer %s véhicule(s) par %s", "%s had %s vehicle(s) replaced with %s" },
	line = { "%s a créé la ligne %s", "%s created the line %s" },
	unline = { "%s a supprimé la ligne %s", "%s deleted the line %s" },
	unline_any = { "%s a supprimé une ligne", "%s deleted a line" },
	unline_by = { "%s a supprimé une ligne créée par %s", "%s deleted a line created by %s" },
	lineupd = { "%s a modifié des lignes (×%s)", "%s changed lines (×%s)" },
	assign = { "%s a affecté %s véhicule(s) à une ligne", "%s assigned %s vehicle(s) to a line" },
	todepot = { "%s a envoyé %s véhicule(s) au dépôt", "%s sent %s vehicle(s) to a depot" },
	rename = { "%s a renommé quelque chose en « %s »", "%s renamed something « %s »" },
	chat_demolish = { "%s a démoli ce que %s avait construit : %s", "%s demolished what %s built: %s" },
	intro = { "Ce que font les joueurs, le plus récent en premier. « Voir » amène la caméra sur place.",
		"What the players do, the latest first. « Show » takes the camera there." },
	details_on = { "Détails : affichés", "Details: shown" },
	details_off = { "Détails : masqués", "Details: hidden" },
	who_all = { "Joueur : tous", "Player: all" },
	who_one = { "Joueur : %s", "Player: %s" },
	show = { "Voir", "Show" },
	nothing = { "Rien pour l'instant.", "Nothing yet." },
	builtby_note = { "Les fenêtres des gares et des constructions disent qui les a construites.",
		"The windows of stations and constructions tell who built them." },
	view_title = { "Voir la vue d'un joueur", "See a player's view" },
	view_company = { "Seulement entre membres d'une même entreprise.", "Only between members of one company." },
	view_button = { "Voir sa vue", "See their view" },
	view_none = { "Aucun autre joueur pour l'instant.", "No other player yet." },
	share_on = { "Les autres peuvent voir ma vue : oui", "The others may see my view: yes" },
	share_off = { "Les autres peuvent voir ma vue : non", "The others may see my view: no" },
	st_ask = { "Demande envoyée à %s…", "Asked %s…" },
	st_view = { "Vue de %s", "%s's view" },
	st_noshare = { "%s ne partage pas sa vue", "%s does not share their view" },
	st_timeout = { "%s ne répond pas", "%s does not answer" },
	st_company = { "%s n'est pas dans ton entreprise", "%s is not in your company" },
	st_nocam = { "La vue de %s n'a pas pu être prise", "%s's view could not be taken" },
	st_off = { "La vue des joueurs est éteinte", "The players' view is off" },
	built_by = { "Construit par %s", "Built by %s" },
	built_by_ed = { "Construit par %s, modifié par %s", "Built by %s, changed by %s" },
	changed_by = { "Modifié par %s", "Changed by %s" },
	bought_by = { "Acheté par %s", "Bought by %s" },
	created_by = { "Créée par %s", "Created by %s" },
}

-- a text in the language of the game (T: the game's T(fr, en), else English), each %s taking the next value (put in with gsub:
-- a value may contain % itself, as C.Tf)
function M.say(T, key, ...)
	local t = M.TEXTS[key]
	if not t then return tostring(key) end
	local s = t[2]
	if type(T) == "function" then
		local ok, r = pcall(T, t[1], t[2])
		if ok and type(r) == "string" then s = r end
	end
	local values, i = { ... }, 0
	s = s:gsub("%%s", function()
		i = i + 1
		local v = values[i]
		return tostring(v == nil and "" or v)
	end)
	return s
end

M.OPTIONS = {
	{ id = "journal",
		title = { "Journal des joueurs", "Players' journal" },
		desc = { "Un onglet de la fenêtre MPFever liste ce que chaque joueur construit, démolit, achète et vend. Le chat dit seulement qui a démoli ce qu'un autre avait construit.",
			"A tab of the MPFever window lists what every player builds, demolishes, buys and sells. The chat only tells who demolished what another player built." },
		modes = "both",
		params = {
			{ id = "details", label = { "Détails affichés par défaut", "Details shown by default" }, values = { 0, 1 }, default = 0,
				show = function(v, T) return M.say(T, tonumber(v) == 1 and "yes" or "no") end },
		} },
	{ id = "builtby",
		title = { "« Construit par »", "« Built by »" },
		desc = { "Les gares et les constructions gardent dans la sauvegarde le joueur qui les a construites ; leur fenêtre l'affiche.",
			"Stations and constructions keep the player who built them in the savegame; their window shows it." },
		modes = "both" },
	{ id = "playerview",
		title = { "Voir la vue d'un joueur", "See a player's view" },
		desc = { "Un bouton amène la caméra là où regarde un autre joueur (en mode séparé, seulement entre membres d'une même entreprise). Chacun peut le refuser.",
			"A button takes the camera to where another player looks (in the separate mode, only between members of one company). Every player may refuse it." },
		modes = "both" },
}

-- f_journal_camreq {to, from}       a player asks for the view of player `to` (its key)
-- f_journal_cam    {id, d | no, from} the player asked answers: its camera (x, y, distance, angle, pitch), or why not
-- f_journal_camend {id, from}       the host ends a request nobody answered in M.CAM_TIMEOUT s
-- f_journal_share  {allow, from}    a player lets the others see its view, or not
-- (`from`: the sender as its game names itself; the options host's env.from, or the bridge's param.mpfFrom, come first)
M.EVENTS = { f_journal_camreq = true, f_journal_cam = true, f_journal_camend = true, f_journal_share = true }

M.TAB = { id = "journal", title = { "Journal", "Journal" } }
-- (0.7.4) the page's « How does it work? », at its end in the Hub (see the window's U.featTabRows)
M.HELP = {
	{ "Le journal liste ce que chaque joueur construit, démolit, achète et vend, le plus récent en premier. Le chat dit seulement qui a démoli ce qu'un autre avait construit.",
		"The journal lists what each player builds, demolishes, buys and sells, the latest first. The chat only tells who demolished what another one had built." },
	{ "Avec les options de l'hôte, la fenêtre d'une gare ou d'une construction montre aussi qui l'a construite, et un bouton amène la caméra là où regarde un autre joueur (chacun peut le refuser).",
		"With the host's options, a station's or a construction's window also shows who built it, and a button takes the camera where another player looks (each one may refuse it)." },
}

-- ------------------------------------------------------------------ small helpers (plain Lua, the same on every game)

-- a finite number of the map's size
local function num(v)
	return type(v) == "number" and v == v and v > -1e12 and v < 1e12
end

-- one line of text: no tab, no line break, at most `max` characters
local function clean(v, max)
	local s = tostring(v == nil and "" or v):gsub("%c", " ")
	return s:sub(1, max or 120)
end

-- an integer as text, the same on every PC: rounded by math.floor (IEEE, exact), then written by tostring, which writes an
-- integer value exactly (printf's own rounding of "%.0f" has changed between builds of the Windows C library)
local function int(v)
	local n = math.floor(v + 0.5) + 0   -- (+ 0: no "-0")
	if n == 0 then n = 0 end
	return tostring(n)
end
M.int = int

local function split(line)
	local f = {}
	for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
	return f
end

-- a player's name without its "#n" (the number a joining player gets), and its key
function M.base(name)
	local s = tostring(name or ""):gsub("#.*$", "")
	return s
end
function M.key(name)
	return M.base(name):lower()
end
local function isAiKey(k) return type(k) == "string" and k:sub(1, 3) == "ai:" end

-- a construction's file as one form ("::/stations/..." and "stations/..." name the same file)
function M.normFile(f)
	local s = tostring(f or ""):gsub("\\", "/")
	s = s:gsub("^::/", "")
	s = s:gsub("^/+", "")
	return clean(s, 160)
end

-- A construction known by its file and its place, the same on every game (its entity id may differ): "c:<file>@x,y", the
-- metres rounded. The form of the bridge's R.sgKey for a station without its "#i" (M.keyOfSg).
function M.conKey(f, x, y)
	if type(f) ~= "string" or f == "" or not num(x) or not num(y) then return nil end
	return "c:" .. M.normFile(f) .. "@" .. int(x) .. "," .. int(y)
end

-- the registry's key of a station from the bridge's R.sgKey ("c:<file>@x,y#i"); nil for a stop by the road ("e:...")
function M.keyOfSg(k)
	if type(k) ~= "string" then return nil end
	local f, x, y = k:match("^c:(.-)@(%-?[%d%.]+),(%-?[%d%.]+)")
	if not f then return nil end
	return M.conKey(f, tonumber(x), tonumber(y))
end

-- a key and its neighbours within M.TOL metres (the key itself first)
local function nearKeys(key)
	local out = { key }
	local f, x, y = tostring(key):match("^c:(.-)@(%-?%d+),(%-?%d+)$")
	if not f then return out end
	x, y = tonumber(x), tonumber(y)
	for dx = -M.TOL, M.TOL do
		for dy = -M.TOL, M.TOL do
			if dx ~= 0 or dy ~= 0 then out[#out + 1] = "c:" .. f .. "@" .. int(x + dx) .. "," .. int(y + dy) end
		end
	end
	return out
end

-- what a construction's file is: a station, a depot (maintenance stations too), trees of the bridge's own construction, or
-- another construction (a junction of the street constructions, a building...)
function M.conKind(f)
	local s = M.normFile(f):lower()
	if s:find("mpfever_asset", 1, true) then return "trees" end
	-- (the towns' buildings: "buildings/a/c1/....con", taken away by a player's road or bulldozer)
	if s:sub(1, 10) == "buildings/" then return "house" end
	if s:find("depot", 1, true) then return "depot" end
	if s:find("station", 1, true) then return "station" end
	return "con"
end

-- ------------------------------------------------------------------ what an action is (the same on every game)

local function position(t)
	if type(t) == "table" and num(t[13]) and num(t[14]) then return t[13], t[14], num(t[15]) and t[15] or 0 end
	return nil
end

-- a reference to a construction (as the actions ship it, see the bridge's R.describe: { k = "con", f, p }): its file and place
local function refCon(r)
	if type(r) == "table" and type(r.f) == "string" and type(r.p) == "table" and num(r.p.x) and num(r.p.y) then
		return r.f, r.p.x, r.p.y, num(r.p.z) and r.p.z or 0
	end
	return nil
end

-- a segment's length and middle (its length from the engine when the proposal has it)
local function segment(s)
	local c = type(s) == "table" and type(s.comp) == "table" and s.comp or {}
	local p0, p1 = c.position0, c.position1
	local L, x, y, z = 0, nil, nil, nil
	if type(p0) == "table" and type(p1) == "table" and num(p0.x) and num(p0.y) and num(p1.x) and num(p1.y) then
		local dx, dy, dz = p1.x - p0.x, p1.y - p0.y, (num(p1.z) and p1.z or 0) - (num(p0.z) and p0.z or 0)
		L = math.sqrt(dx * dx + dy * dy + dz * dz)
		x, y, z = (p0.x + p1.x) / 2, (p0.y + p1.y) / 2, ((num(p0.z) and p0.z or 0) + (num(p1.z) and p1.z or 0)) / 2
	end
	if num(c.distance) and c.distance > 0 then L = c.distance end
	return L, x, y, z, (type(s) == "table" and s.type == 1)
end

-- A build (a native capture or a build command, the compact proposal of the bridge's C.compactProposal, references not yet
-- translated): its constructions added, edited (the same file at the same place, removed and added again) and demolished;
-- else its edge objects (stops, waypoints, signals) and its segments (roads and tracks built, changed or demolished)
function M.classifyBuild(m, cost)
	if type(m) ~= "table" then return nil end
	local out = {}
	local adds, rems = {}, {}
	for i, ce in ipairs(type(m.toAdd) == "table" and m.toAdd or {}) do
		if i > 8 then break end
		local f = type(ce) == "table" and ce.fileName or nil
		if type(f) == "string" and f ~= "" then
			local x, y, z = position(ce.transf)
			adds[#adds + 1] = { f = f, x = x, y = y, z = z, key = M.conKey(f, x, y) }
		end
	end
	for i, r in ipairs(type(m.toRemove) == "table" and m.toRemove or {}) do
		if i > 16 then break end
		local f, x, y, z = refCon(r)
		-- (an entity id: already translated to this game's ids, its file and place are not known here any more)
		rems[#rems + 1] = f and { f = f, x = x, y = y, z = z, key = M.conKey(f, x, y) } or {}
	end
	for _, ad in ipairs(adds) do
		for _, rm in ipairs(rems) do
			if not rm.pair and rm.f and ad.x and M.normFile(rm.f) == M.normFile(ad.f) and math.abs(rm.x - ad.x) <= 2 and math.abs(rm.y - ad.y) <= 2 then
				rm.pair, ad.pair = true, rm
				break
			end
		end
	end
	for _, ad in ipairs(adds) do
		local kind = M.conKind(ad.f)
		if kind == "house" then kind = "con" end
		if kind == "trees" then
			out[#out + 1] = { kind = "trees", det = 1, n = 1, merge = true, x = ad.x, y = ad.y, z = ad.z }
		elseif ad.pair then
			out[#out + 1] = { kind = "edit", det = 1, x = ad.x, y = ad.y, z = ad.z, a = M.normFile(ad.f), key = ad.key, oldKey = ad.pair.key }
		else
			out[#out + 1] = { kind = kind, det = 0, x = ad.x, y = ad.y, z = ad.z, a = M.normFile(ad.f), key = ad.key }
		end
	end
	local houses = nil
	for _, rm in ipairs(rems) do
		if not rm.pair and rm.f and M.conKind(rm.f) == "house" then
			-- (the towns' buildings a build takes away: one entry with their number)
			houses = houses or { kind = "houses", det = 0, n = 0, merge = true, x = rm.x, y = rm.y, z = rm.z }
			houses.n = houses.n + 1
		elseif not rm.pair then
			out[#out + 1] = { kind = "demolish", det = 0, x = rm.x, y = rm.y, z = rm.z, a = rm.f and M.normFile(rm.f) or "", rmKey = rm.key }
		end
	end
	if houses then out[#out + 1] = houses end
	if #out == 0 then
		local P = type(m.proposal) == "table" and m.proposal or {}
		-- edge objects: Proposal.EdgeObject.category 0 = stop, 1 = waypoint, 2 = signal
		local cats = { [0] = "stop", [1] = "waypoint", [2] = "signal" }
		local seen = {}
		for _, o in ipairs(type(P.edgeObjectsToAdd) == "table" and P.edgeObjectsToAdd or {}) do
			local kind = type(o) == "table" and cats[o.category] or nil
			if kind then
				local e = seen[kind]
				if not e then
					local mi = type(o.modelInstance) == "table" and o.modelInstance or {}
					local x, y, z = position(mi.transf)
					e = { kind = kind, det = 1, n = 0, merge = true, x = x, y = y, z = z }
					seen[kind] = e
					out[#out + 1] = e
				end
				e.n = e.n + 1
			end
		end
		local objects = #out > 0
		local added = type(P.addedSegments) == "table" and P.addedSegments or {}
		local removed = type(P.removedSegments) == "table" and P.removedSegments or {}
		local addL, remL, track, px, py, pz = 0, 0, false, nil, nil, nil
		for _, s in ipairs(added) do
			local L, x, y, z, tr = segment(s)
			addL = addL + L
			track = track or tr
			if not px then px, py, pz = x, y, z end
		end
		for _, s in ipairs(removed) do
			local L, x, y, z, tr = segment(s)
			remL = remL + L
			track = track or tr
			if not px then px, py, pz = x, y, z end
		end
		if #added + #removed > 0 then
			local base = track and "track" or "road"
			local net = addL - remL
			local e = nil
			if #removed == 0 then
				e = { kind = base, det = 0, n = math.floor(addL + 0.5) }
			elseif #added == 0 then
				e = { kind = base .. "_del", det = 0, n = math.floor(remL + 0.5) }
			elseif net > 1 then
				e = { kind = base, det = 0, n = math.floor(net + 0.5) }
			elseif net < -1 then
				e = { kind = base .. "_del", det = 0, n = math.floor(-net + 0.5) }
			elseif not objects then
				-- (the segments a stop or a signal splits are not a change of their own)
				e = { kind = base .. "_mod", det = 1, n = math.floor(addL + 0.5) }
			end
			if e then
				e.merge, e.x, e.y, e.z = true, px, py, pz
				out[#out + 1] = e
			end
		end
	end
	if #out == 0 then return nil end
	if num(cost) and cost ~= 0 then out[1].c = math.floor(math.abs(cost) + 0.5) end
	return out
end

-- a vehicle's model in a TransportVehicleConfig as the actions ship it (its first part's model id: the same on every game, the
-- purchase itself is replayed with it)
local function modelOf(cfg)
	local v = type(cfg) == "table" and type(cfg.vehicles) == "table" and cfg.vehicles[1]
	local p = type(v) == "table" and type(v.part) == "table" and v.part or nil
	return (p and num(p.modelId)) and int(p.modelId) or ""
end

-- a list of entities or one entity (a sale of several vehicles takes a list since 0.5.14)
local function listOf(v)
	if type(v) == "table" and not v.__ref and #v > 0 then return v end
	return { v }
end

-- the player who made what a creation key names ("V<uid>@<at>" a vehicle bought, "L<uid>@<at>" a line created; the uid is
-- "<player>:<n>")
local function creatorOfKey(k)
	if type(k) ~= "string" then return nil, nil end
	local kind, origin = k:match("^([VL])(.+):%d+@")
	return kind, origin
end

-- what an action is: a list of items { kind, det, x, y, z, a, b, n, c, merge, key, oldKey, rmKey, lineKey }, or nil (an action
-- the journal does not tell). Reads the action only: never changes it (the bridge translates its arguments in place).
function M.classify(a)
	local fn = a.fn
	local args = type(a.args) == "table" and a.args or {}
	if fn == "makeWorldBuildProposalCmd" then return M.classifyBuild(args[1], a.cost) end
	if fn == "assetBuild" then
		-- (trees, plants and rocks of the brush, see the bridge's capture: { assets = { { models = { { id, transf } } } }, toRemove })
		local n, x, y, z = 0, nil, nil, nil
		for _, as in ipairs(type(args.assets) == "table" and args.assets or {}) do
			for _, md in ipairs(type(as) == "table" and type(as.models) == "table" and as.models or {}) do
				n = n + 1
				if not x and type(md) == "table" then x, y, z = position(md.transf) end
			end
		end
		if n > 0 then return { { kind = "trees", det = 1, n = n, merge = true, x = x, y = y, z = z } } end
		if type(args.toRemove) == "table" and #args.toRemove > 0 then return { { kind = "trees_del", det = 1, n = #args.toRemove, merge = true } } end
		return nil
	end
	if fn == "terrainEdit" then return { { kind = "terrain", det = 1, n = 1, merge = true } } end
	if fn == "makeVehicleBuyCmd" then
		local d = args[2]
		local p = type(d) == "table" and type(d.con) == "table" and type(d.con.p) == "table" and d.con.p or nil
		local ok = p and num(p.x) and num(p.y)
		return { { kind = "buy", det = 0, n = 1, merge = true, a = modelOf(args[3]),
			x = ok and p.x or nil, y = ok and p.y or nil, z = ok and (num(p.z) and p.z or 0) or nil } }
	end
	if fn == "makeVehicleSellCmd" then
		local list = listOf(args[1])
		local _, buyer = creatorOfKey(type(list[1]) == "table" and list[1].key or nil)
		return { { kind = "sell", det = 0, n = #list, merge = true, b = buyer and M.base(buyer) or nil } }
	end
	if fn == "makeVehicleReplaceCmd" then return { { kind = "replace", det = 1, n = 1, merge = true, a = modelOf(args[2]) } } end
	if fn == "makeLineCreateCmd" then
		local line = type(args[4]) == "table" and args[4] or {}
		local stop = type(line.stops) == "table" and line.stops[1] or nil
		local sg = type(stop) == "table" and stop.stationGroup or nil
		local s = type(sg) == "table" and type(sg.st) == "table" and sg.st or {}
		local p = (type(s.con) == "table" and s.con.p) or (type(s.edge) == "table" and s.edge.p0) or nil
		local ok = type(p) == "table" and num(p.x) and num(p.y)
		return { { kind = "line", det = 0, a = clean(args[1], 60),
			x = ok and p.x or nil, y = ok and p.y or nil, z = ok and (num(p.z) and p.z or 0) or nil } }
	end
	if fn == "makeLineDestroyCmd" then
		local l = args[1]
		local key = type(l) == "table" and l.key or nil
		local _, creator = creatorOfKey(key)
		return { { kind = "unline", det = 0, b = creator and M.base(creator) or nil, lineKey = key } }
	end
	if fn == "makeLineUpdateCmd" then return { { kind = "lineupd", det = 1, n = 1, merge = true } } end
	if fn == "makeVehicleSetLineCmd" then return { { kind = "assign", det = 1, n = #listOf(args[1]), merge = true } } end
	if fn == "makeVehicleSendToDepotCmd" then return { { kind = "todepot", det = 1, n = #listOf(args[1]), merge = true } } end
	if fn == "makeEntitySetNameCmd" and type(args[2]) == "string" then return { { kind = "rename", det = 1, a = clean(args[2], 60) } } end
	return nil
end

-- A small copy of an action, all the journal needs of it: to take BEFORE the action is applied (the bridge then translates its
-- references to this game's ids, in place: a demolished construction's file and place, a sold vehicle's creation key are gone)
-- and to hand to the simulation half instead of the action (a native build replayed by the interface: its proposal can be
-- large). M.onAction takes it as it takes an action.
function M.digest(a)
	if type(a) ~= "table" then return nil end
	local ok, items = pcall(M.classify, a)
	return { fn = a.fn, origin = a.origin, uid = a.uid, at = a.at, co = a.co, tok = a.tok, native = a.native or nil, items = (ok and items) or false }
end

-- the companies, as a list of { id, ai, gone, members = { key... } }: the options host's env.companies() (simulation half),
-- else the registry the GUI half reads (st.co, the separate mode)
function M.companiesOf(st, env)
	local raw = nil
	if env and type(env.companies) == "function" then
		local ok, l = pcall(env.companies)
		if ok and type(l) == "table" then raw = l end
	end
	if not raw and type(st) == "table" and type(st.co) == "table" and type(st.co.list) == "table" then raw = st.co.list end
	local out = {}
	for _, c in ipairs(raw or {}) do
		if type(c) == "table" then
			local members = {}
			local ms = c.members
			if type(ms) ~= "table" then ms = (type(c.key) == "string" and c.key ~= "") and { c.key } or {} end
			for _, m in ipairs(ms) do
				local k = type(m) == "table" and m.key or m
				if type(k) == "string" then members[#members + 1] = k end
			end
			out[#out + 1] = { id = c.id, gone = c.gone, ai = c.ai == true or isAiKey(c.key), members = members }
		end
	end
	return out
end

-- the company a player plays (a company of people, not gone), nil when none
function M.companyOfKey(list, key)
	for _, c in ipairs(list or {}) do
		if not c.gone and not c.ai then
			for _, k in ipairs(c.members) do if k == key then return c end end
		end
	end
	return nil
end

-- a player's action: not a computer company's (its own journal tells it), not a mod's command, not an autotest's, not the
-- announcement of a player
function M.isHuman(a, env)
	if type(a.origin) ~= "string" or a.origin == "" or a.fn == "mpfCoJoin" then return false end
	local tok = a.tok
	if tok == "ai" or tok == "mod" or (type(tok) == "string" and tok:sub(1, 4) == "auto") then return false end
	if a.co ~= nil then
		for _, c in ipairs(M.companiesOf(nil, env)) do
			if c.id == a.co and c.ai then return false end
		end
	end
	return true
end

-- the sender of an event: the options host's (env.from), the bridge's (param.mpfFrom, the separate mode), else the event's own
function M.sender(param, env)
	local f = (type(env) == "table" and env.from) or param.mpfFrom or param.from
	if type(f) ~= "string" then return nil end
	return f
end

-- ------------------------------------------------------------------ the state (simulation half)

function M.init(J)
	if J.v == nil then J.v = 1 end
	if type(J.log) ~= "string" then J.log, J.nlog = "\n", 0 end
	if type(J.seq) ~= "number" then J.seq = 0 end
	if type(J.reg) ~= "string" then J.reg, J.nreg = "\n", 0 end
	if type(J.uids) ~= "string" then J.uids, J.nuids = "\n", 0 end
	if type(J.who) ~= "table" then J.who, J.nwho = {}, 0 end
	if type(J.noview) ~= "table" then J.noview = {} end
	if type(J.cam) ~= "table" then J.cam = {} end
	if type(J.camN) ~= "number" then J.camN = 0 end
	if type(J.ans) ~= "table" then J.ans = {} end
	return J
end

function M.lineOf(e)
	local t = {}
	for i, k in ipairs(M.FIELDS) do
		local v = e[k]
		if v == nil then
			t[i] = ""
		elseif NUMERIC[k] then
			t[i] = num(tonumber(v)) and int(tonumber(v)) or ""
		else
			t[i] = clean(v, 120)
		end
	end
	return table.concat(t, "\t")
end

function M.parse(line)
	if type(line) ~= "string" or line == "" or line:sub(1, 1) == "@" then return nil end
	local f = split(line)
	if #f < 7 then return nil end
	local e = {}
	for i, k in ipairs(M.FIELDS) do
		local v = f[i]
		if v ~= nil and v ~= "" then
			if NUMERIC[k] then e[k] = tonumber(v) else e[k] = v end
		end
	end
	e.at, e.det, e.uid, e.kind = e.at or 0, e.det or 0, e.uid or "", e.kind or ""
	return e
end

local function before(p, q)
	if p.at ~= q.at then return p.at < q.at end
	if p.uid ~= q.uid then return p.uid < q.uid end
	if p.kind ~= q.kind then return p.kind < q.kind end
	return (p.mk or "") < (q.mk or "")
end

-- the journal's entries, the oldest first
function M.entries(J)
	local list = {}
	for line in tostring(J.log or ""):gmatch("[^\n]+") do
		local e = M.parse(line)
		if e then list[#list + 1] = e end
	end
	return list
end

local function logTrim(J)
	while J.nlog > M.MAX_LOG do
		local e = J.log:find("\n", 2, true)
		if not e then break end
		J.log = "\n" .. J.log:sub(e + 1)
		J.nlog = J.nlog - 1
	end
end

local function logRebuild(J, list)
	table.sort(list, before)
	local t = {}
	for i, e in ipairs(list) do t[i] = M.lineOf(e) end
	J.log = "\n" .. ((#t > 0) and (table.concat(t, "\n") .. "\n") or "")
	J.nlog = #t
	local last = list[#list]
	J.la, J.lu = last and last.at or nil, last and last.uid or nil
	logTrim(J)
end

local function logInsert(J, e)
	if J.nlog == 0 or J.la == nil or e.at > J.la or (e.at == J.la and e.uid > (J.lu or "")) then
		J.log = J.log .. M.lineOf(e) .. "\n"
		J.nlog = J.nlog + 1
		J.la, J.lu = e.at, e.uid
		logTrim(J)
	else
		-- (an action of an earlier game time than the last entry: put in its place)
		local list = M.entries(J)
		list[#list + 1] = M.parse(M.lineOf(e))
		logRebuild(J, list)
	end
	J.seq = J.seq + 1
end

-- an entry merged into the one of the same player, kind and 30 s (its merge key, field mk): counts and costs added up, the
-- earliest action of them gives its time and place
local function logMerge(J, e)
	local s = J.log:find("\n" .. e.mk .. "\t", 1, true)
	if not s then return false end
	local stop = J.log:find("\n", s + 1, true)
	local old = stop and M.parse(J.log:sub(s + 1, stop - 1)) or nil
	if not old then return false end
	old.n = (old.n or 0) + (e.n or 0)
	if e.c then old.c = (old.c or 0) + e.c end
	local earlier = before(e, old)
	if earlier then old.at, old.uid, old.x, old.y, old.z, old.ym = e.at, e.uid, e.x, e.y, e.z, e.ym end
	J.log = J.log:sub(1, s) .. M.lineOf(old) .. J.log:sub(stop)
	if earlier then logRebuild(J, M.entries(J)) end
	J.seq = J.seq + 1
	return true
end

-- whether an action ("uid@at") was taken already; remembers it
local function seen(J, id)
	if J.uids:find("\n" .. id .. "\n", 1, true) then return true end
	J.uids = J.uids .. id .. "\n"
	J.nuids = J.nuids + 1
	while J.nuids > M.MAX_UIDS do
		local e = J.uids:find("\n", 2, true)
		if not e then break end
		J.uids = "\n" .. J.uids:sub(e + 1)
		J.nuids = J.nuids - 1
	end
	return false
end

-- the registry's line of a key (exactly): its start (the line break before it), its end (the line break after it), its fields
local function regLine(J, key)
	local s = J.reg:find("\n" .. key .. "\t", 1, true)
	if not s then return nil end
	local e = J.reg:find("\n", s + 1, true)
	if not e then return nil end
	return s, e, split(J.reg:sub(s + 1, e - 1))
end

-- who built a construction: the fields { key, who, at, editor } of its line (within M.TOL metres), and the key found
function M.regGet(J, key)
	if type(J) ~= "table" or type(J.reg) ~= "string" or type(key) ~= "string" then return nil end
	for _, k in ipairs(nearKeys(key)) do
		local s, _, f = regLine(J, k)
		if s then return f, k end
	end
	return nil
end

local function regRemove(J, key)
	local s, e = regLine(J, key)
	if not s then return end
	J.reg = J.reg:sub(1, s) .. J.reg:sub(e + 1)
	J.nreg = J.nreg - 1
end

local function regPut(J, key, who, at, ed)
	regRemove(J, key)
	J.reg = J.reg .. key .. "\t" .. clean(who, 40) .. "\t" .. int(at) .. "\t" .. clean(ed or "", 40) .. "\n"
	J.nreg = J.nreg + 1
	while J.nreg > M.MAX_REG do
		local e = J.reg:find("\n", 2, true)
		if not e then break end
		J.reg = "\n" .. J.reg:sub(e + 1)
		J.nreg = J.nreg - 1
	end
end

local function regDel(J, key)
	local f, k = M.regGet(J, key)
	if f then regRemove(J, k) end
	return f
end

-- a player seen (the name it shows, for the view's list)
local function noteWho(J, name)
	local k = M.key(name)
	if k == "" or isAiKey(k) then return end
	if J.who[k] == nil then
		if J.nwho >= M.MAX_WHO then return end
		J.nwho = J.nwho + 1
	end
	J.who[k] = clean(M.base(name), 40)
end

-- the name of a line its journal entry gave (its creation key "L<uid>@<at>"), "" when it is no longer in the journal
local function lineName(J, key)
	local uid, at = tostring(key or ""):match("^L(.+)@(%-?%d+)$")
	if not uid then return "" end
	local s = J.log:find("\t" .. at .. "\t" .. uid .. "\t", 1, true)
	if not s then return "" end
	local ls = J.log:sub(1, s):match(".*()\n")
	local le = J.log:find("\n", s, true)
	local e = (ls and le) and M.parse(J.log:sub(ls + 1, le - 1)) or nil
	return (e and e.kind == "line") and (e.a or "") or ""
end

-- ------------------------------------------------------------------ simulation half (every game, the same step)

-- After every action the games replay (the options host's hook): its entries in the journal, its constructions in the registry.
-- `a` is the action, or its M.digest taken before it was applied (a.items: what it is, already read).
function M.onAction(st, a, ok, env)
	if ok == false or type(st) ~= "table" or type(a) ~= "table" then return end
	local onJ, onB, onV = env.on("journal"), env.on("builtby"), env.on("playerview")
	if not (onJ or onB or onV) then return end
	local okc, res = true, nil
	if a.items ~= nil then
		res = type(a.items) == "table" and a.items or nil
	else
		okc, res = pcall(M.classify, a)
	end
	if not okc then
		env.log("journal: action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " not read: " .. tostring(res))
		res = nil
	end
	local keep = (onJ or onB) and type(res) == "table" and #res > 0
	if not M.isHuman(a, env) then
		-- (a computer company's build or a mod's: not in the journal, but what it took away leaves the registry)
		local J = type(st.feat) == "table" and st.feat[M.ID] or nil
		if keep and type(J) == "table" and type(J.reg) == "string" then
			for _, x in ipairs(res) do
				if type(x) == "table" and type(x.rmKey) == "string" then regDel(J, x.rmKey) end
			end
		end
		return
	end
	if not (keep or onV) then return end
	local J = M.init(env.state(st))
	noteWho(J, a.origin)
	if not keep then return end
	local at = num(tonumber(a.at)) and tonumber(a.at) or env.gameTime()
	local uid = clean(a.uid or "?", 60)
	if seen(J, uid .. "@" .. int(at)) then return end
	local who = clean(M.base(a.origin), 40)
	local ym = nil
	if type(env.month) == "function" then
		local okm, v = pcall(env.month)
		if okm and num(v) then ym = v end
	end
	local bucket = int(math.floor(at / M.MERGE_MS))
	-- (what this game made of it, for the in-game checks: "feat journal:" in mod.log, on every game)
	local said = {}
	for i, x in ipairs(res) do repeat
		if type(x) ~= "table" or type(x.kind) ~= "string" then break end
		local e = { at = at, uid = (i == 1) and uid or (uid .. "." .. i), who = who, co = tonumber(a.co), kind = x.kind, det = x.det or 0,
			x = x.x, y = x.y, z = x.z, a = x.a, b = x.b, n = x.n, c = x.c, ym = ym }
		said[#said + 1] = x.kind .. (x.n and ("x" .. int(x.n)) or "") .. (x.key and (" " .. x.key) or "")
		if x.rmKey then
			local f = regDel(J, x.rmKey)
			if f and f[2] and f[2] ~= "" then e.b = f[2] end
			said[#said] = said[#said] .. " " .. x.rmKey .. (f and (" (in the registry, built by '" .. tostring(f[2]) .. "')") or " (not in the registry)")
		end
		if x.kind == "edit" then
			-- (the builder stays; the editor is kept when it is another player. A construction the registry did not know, built
			-- before the option was on, keeps no builder: « changed by » only)
			local f = x.oldKey and regDel(J, x.oldKey) or nil
			local builder = (f and f[2]) or ""
			local other = builder ~= "" and M.key(builder) ~= M.key(who)
			local ed = (builder == "" or other) and who or (f[4] or "")
			if x.key then regPut(J, x.key, builder, (f and tonumber(f[3])) or at, ed) end
			e.b = other and builder or nil
		elseif BUILT[x.kind] and x.key then
			regPut(J, x.key, who, at, "")
		end
		if x.kind == "unline" and x.lineKey then e.a = lineName(J, x.lineKey) end
		if onJ then
			if x.merge and MERGED[x.kind] then
				e.mk = clean("m:" .. M.key(who) .. ":" .. x.kind .. ":" .. bucket .. ":" .. (e.a or "") .. ":" .. (e.b or ""), 120)
				if not logMerge(J, e) then logInsert(J, e) end
			else
				e.mk = "-"
				logInsert(J, e)
			end
		end
	until true end
	env.log("feat journal: " .. uid .. " " .. tostring(a.fn) .. (a.native and " (a tool's build)" or "") .. " of " .. who .. " at t=" .. int(at)
		.. ": " .. table.concat(said, "; "):sub(1, 300))
end

-- a camera's data: x, y (its centre), distance, angle, pitch, as numbers of the map's size; nil when it is not one
function M.camData(d)
	if type(d) ~= "table" then return nil end
	local v = {}
	for i, k in ipairs({ "x", "y", "z", "w", "q" }) do
		local x = d[i]
		if x == nil then x = d[k] end
		x = tonumber(x)
		if not num(x) then return nil end
		v[i] = x
	end
	if math.abs(v[1]) > 1e6 or math.abs(v[2]) > 1e6 or v[3] <= 0 or v[3] > 1e6 or math.abs(v[4]) > 1e3 or math.abs(v[5]) > 1e3 then return nil end
	return v
end

local function pushAns(J, x)
	J.ans[#J.ans + 1] = x
	while #J.ans > M.ANS_MAX do table.remove(J.ans, 1) end
end

local function findReq(J, id)
	for i, r in ipairs(J.cam) do if r.id == id then return i, r end end
	return nil
end

-- the events of the view (every game, the same step)
function M.event(st, name, param, env)
	if not M.EVENTS[name] or type(st) ~= "table" or type(param) ~= "table" then return end
	if not env.on("playerview") then
		env.log("journal: " .. name .. " ignored (the players' view is off)")
		return
	end
	local from = M.sender(param, env)
	local fk = M.key(from)
	if fk == "" or isAiKey(fk) then return end
	local J = M.init(env.state(st))
	noteWho(J, from)
	if name == "f_journal_share" then
		J.noview[fk] = (param.allow == false) or nil
		env.log("journal: " .. fk .. (param.allow == false and " keeps its view to itself" or " shares its view"))
	elseif name == "f_journal_camreq" then
		local to = M.key(param.to)
		if to == "" or to == fk or isAiKey(to) then return end
		local tn = J.who[to] or clean(M.base(param.to), 40)
		local why = nil
		if J.noview[to] then
			why = "noshare"
		elseif env.mode == "separate" then
			-- (the separate mode: only between the members of one company, G2)
			local list = M.companiesOf(nil, env)
			local c1, c2 = M.companyOfKey(list, fk), M.companyOfKey(list, to)
			if not (c1 and c2 and c1.id == c2.id) then why = "company" end
		end
		J.camN = J.camN + 1
		local id = J.camN
		if why then
			pushAns(J, { id = id, to = fk, from = to, fn = tn, no = why })
			env.log("journal: " .. fk .. " may not see the view of " .. to .. " (" .. why .. ")")
			return
		end
		-- (one request of a player at a time: its earlier one goes)
		for i = #J.cam, 1, -1 do if J.cam[i].from == fk then table.remove(J.cam, i) end end
		J.cam[#J.cam + 1] = { id = id, from = fk, fn = clean(M.base(from), 40), to = to, tn = tn, at = env.gameTime() }
		while #J.cam > M.CAM_MAX do table.remove(J.cam, 1) end
	elseif name == "f_journal_cam" then
		local i, r = findReq(J, tonumber(param.id))
		-- (only the player asked answers)
		if not i or r.to ~= fk then return end
		table.remove(J.cam, i)
		local ans = { id = r.id, to = r.from, from = r.to, fn = r.tn }
		local d = M.camData(param.d)
		if d then ans.d = d else ans.no = (param.no == "noshare") and "noshare" or "nocam" end
		pushAns(J, ans)
	elseif name == "f_journal_camend" then
		local i, r = findReq(J, tonumber(param.id))
		if not i then return end
		table.remove(J.cam, i)
		pushAns(J, { id = r.id, to = r.from, from = r.to, fn = r.tn, no = "timeout" })
	end
end

-- ------------------------------------------------------------------ GUI half (every game, about once a second)

-- What this game's interface has done (never the simulation's): the demolitions told, the requests answered, the views taken,
-- the status line of the tab. nil until the first call after a load: what the state holds then is not told again.
M._g = nil
function M.guiState()
	local g = M._g or { told = {}, answered = {}, applied = {}, seenReq = {}, ended = {} }
	M._g = g
	return g
end

-- the game's camera (GUI only; the integration may replace these two)
function M.camGet()
	local cam = api.gui.camera
	local d = cam.getCameraData()
	local function at(i, k)
		local ok, v = pcall(function() return d[k] end)
		if not ok or v == nil then ok, v = pcall(function() return d[i] end) end
		return ok and v or nil
	end
	return M.camData({ at(1, "x"), at(2, "y"), at(3, "z"), at(4, "w"), at(5, "q") })
end
function M.camSet(d)
	local cam = api.gui.camera
	-- (a camera following a vehicle: taken off it first; not tried in game yet, see the note's section 3)
	local following = false
	pcall(function()
		-- ({ entity, revision }: a table or the engine's own list)
		local f = cam.getFollowEntity()
		local e = f ~= nil and f[1] or nil
		following = type(e) == "number" and e >= 0
	end)
	if following then pcall(cam.focusPosition, api.type.Vec3f.new(d[1], d[2], 0), d[3]) end
	local ok = pcall(cam.setCameraData, api.type.Vec5f.new(d[1], d[2], d[3], d[4], d[5]))
	if not ok then ok = pcall(cam.focusPosition, api.type.Vec3f.new(d[1], d[2], 0), d[3]) end
	return ok
end

-- names for the texts (the interface; the integration may replace them)
function M.conName(f)
	local s = tostring(f or "")
	local name = nil
	pcall(function()
		local rep = api.res.constructionRep
		local id = rep.find(s)
		if type(id) ~= "number" or id < 0 then id = rep.find("::/" .. s) end
		if type(id) == "number" and id >= 0 then name = rep.get(id).description.name end
	end)
	if type(name) == "string" and name ~= "" then return "« " .. name .. " »" end
	local b = s:match("([^/]+)%.con$") or s:match("([^/]+)$") or s
	return "« " .. b:gsub("_", " ") .. " »"
end
function M.modelName(id, T)
	local n = tonumber(id)
	if not n then return M.say(T, "a_vehicle") end
	local name = nil
	pcall(function()
		local m = api.res.modelRep.get(n)
		name = m.metadata.description.name
	end)
	if type(name) ~= "string" or name == "" then
		pcall(function() name = tostring(api.res.modelRep.getName(n)):match("([^/]+)%.mdl$") end)
	end
	if type(name) ~= "string" or name == "" then name = "#" .. tostring(id) end
	return name
end
function M.money(v)
	local ok, s = pcall(function() return api.util.formatMoney(math.floor(v)) end)
	if ok and type(s) == "string" then return s end
	return "$" .. int(v)
end

-- what an entry says, in the language of T
function M.text(e, T)
	local who, k = e.who or "?", e.kind
	local n = e.n and int(e.n) or "1"
	local s
	if k == "station" then s = M.say(T, "built_station", who, M.conName(e.a))
	elseif k == "depot" then s = M.say(T, "built_depot", who, M.conName(e.a))
	elseif k == "con" then s = M.say(T, "built_con", who, M.conName(e.a))
	elseif k == "edit" then
		s = (e.b and e.b ~= "") and M.say(T, "edit_by", who, M.conName(e.a), e.b) or M.say(T, "edit", who, M.conName(e.a))
	elseif k == "demolish" then
		local what = (e.a and e.a ~= "") and M.conName(e.a) or M.say(T, "a_construction")
		s = (e.b and e.b ~= "") and M.say(T, "demolish_by", who, what, e.b) or M.say(T, "demolish", who, what)
	elseif k == "buy" or k == "replace" then s = M.say(T, k, who, n, M.modelName(e.a, T))
	elseif k == "sell" then s = (e.b and e.b ~= "" and M.key(e.b) ~= M.key(who)) and M.say(T, "sell_by", who, n, e.b) or M.say(T, "sell", who, n)
	elseif k == "line" then s = M.say(T, "line", who, "« " .. tostring(e.a or "") .. " »")
	elseif k == "unline" then
		if e.a and e.a ~= "" then s = M.say(T, "unline", who, "« " .. e.a .. " »")
		elseif e.b and e.b ~= "" and M.key(e.b) ~= M.key(who) then s = M.say(T, "unline_by", who, e.b)
		else s = M.say(T, "unline_any", who) end
	elseif k == "rename" then s = M.say(T, "rename", who, e.a or "")
	elseif M.TEXTS[k] then s = M.say(T, k, who, n)
	else s = who .. ": " .. tostring(k) end
	if e.c and e.c > 0 and k ~= "sell" then s = s .. " (" .. M.money(e.c) .. ")" end
	return s
end

local function bit(v) return v and "1" or "0" end
-- the real time of the interface (os.clock, given by the options host), 0 without it
local function rt(env)
	local ok, v = pcall(env.realTime)
	return (ok and type(v) == "number") and v or 0
end

-- the players this player may ask for their view: { key, name, state = "ok" | "noshare" }, sorted by key. In the separate mode
-- the other members of its company; else the players the integration lists (env.players(), names), else those seen so far.
function M.peers(st, env, J)
	local me = M.key(env.me)
	local mode = env.mode or ((type(st) == "table" and type(st.co) == "table" and st.co.mode == "separate") and "separate" or "shared")
	local keys, names = {}, {}
	local function add(k, name)
		if type(k) ~= "string" or k == "" or k == me or isAiKey(k) or names[k] then return end
		names[k] = name or (J and J.who[k]) or k
		keys[#keys + 1] = k
	end
	if mode == "separate" then
		local list = M.companiesOf(st, env)
		local c = M.companyOfKey(list, me)
		for _, k in ipairs(c and c.members or {}) do add(k) end
	else
		local listed = false
		if type(env.players) == "function" then
			local ok, l = pcall(env.players)
			if ok and type(l) == "table" then
				listed = true
				for _, p in ipairs(l) do add(M.key(p), clean(M.base(p), 40)) end
			end
		end
		if not listed and J then for k, name in pairs(J.who) do add(k, name) end end
	end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		out[#out + 1] = { key = k, name = names[k], state = (J and J.noview[k]) and "noshare" or "ok" }
	end
	return out, mode
end

function M.gui(st, env)
	local onJ, onB, onV = env.on("journal"), env.on("builtby"), env.on("playerview")
	if not (onJ or onB or onV) then return end
	local J = (type(st) == "table" and type(st.feat) == "table") and st.feat[M.ID] or nil
	if type(J) ~= "table" or type(J.log) ~= "string" then J = nil end
	local g = M.guiState()
	-- (the first look after a load: what the state holds is not told again, an old answer not taken again)
	local first = not g.loaded
	g.loaded = true
	local me = M.key(env.me)
	local T = env.T
	-- the chat: only « X demolished what Y built » (G1)
	local list = nil
	if J and (J.seq ~= g.seq or first) then
		g.seq = J.seq
		list = M.entries(J)
		if onJ then
			local told = {}
			for _, e in ipairs(list) do
				if e.kind == "demolish" and e.b and e.b ~= "" and M.key(e.b) ~= M.key(e.who) then
					local id = e.uid .. "@" .. int(e.at)
					told[id] = true
					if not g.told[id] and not first then
						env.chat(M.say(T, "chat_demolish", e.who, e.b, (e.a and e.a ~= "") and M.conName(e.a) or M.say(T, "a_construction")))
					end
				end
			end
			g.told = told
		end
	end
	-- the view (G2, G4)
	if onV and J then
		-- (what this game remembers of the requests and answers still in the state only: their ids never come back)
		local answered, seenReq, ended, applied = {}, {}, {}, {}
		for _, r in ipairs(J.cam) do answered[r.id], seenReq[r.id], ended[r.id] = g.answered[r.id], g.seenReq[r.id], g.ended[r.id] end
		for _, x in ipairs(J.ans) do applied[x.id] = g.applied[x.id] end
		g.answered, g.seenReq, g.ended, g.applied = answered, seenReq, ended, applied
		for _, r in ipairs(J.cam) do
			if r.to == me and not g.answered[r.id] then
				g.answered[r.id] = true
				if J.noview[me] then
					env.send("f_journal_cam", { id = r.id, no = "noshare", from = env.me })
					env.log("feat journal: " .. tostring(r.fn) .. " asked for this player's view: refused (not shared)")
				else
					local okc, d = pcall(M.camGet)
					if okc and d then
						env.send("f_journal_cam", { id = r.id, d = d, from = env.me })
					else
						env.send("f_journal_cam", { id = r.id, no = "nocam", from = env.me })
					end
					-- (in game: does getCameraData give the five numbers? see M.camGet)
					env.log("feat journal: " .. tostring(r.fn) .. " asked for this player's view: camera "
						.. ((okc and d) and string.format("%.1f,%.1f distance %.1f angle %.3f pitch %.3f sent", d[1], d[2], d[3], d[4], d[5]) or ("NOT READ (" .. tostring(d) .. ")")))
				end
			end
			-- (the host alone ends a request nobody answers: one decider)
			if env.isHost then
				local now = rt(env)
				g.seenReq[r.id] = g.seenReq[r.id] or now
				if not g.ended[r.id] and now - g.seenReq[r.id] > M.CAM_TIMEOUT then
					g.ended[r.id] = true
					env.send("f_journal_camend", { id = r.id, from = env.me })
					env.log("journal: the request " .. r.id .. " of a view (" .. tostring(r.from) .. " -> " .. tostring(r.to) .. ") got no answer")
				end
			end
		end
		for _, x in ipairs(J.ans) do
			if x.to == me and not g.applied[x.id] then
				g.applied[x.id] = true
				-- (an answer the state held when this game loaded is not taken again)
				if not first then
					if x.d then
						local okc, done = pcall(M.camSet, x.d)
						g.status = { (okc and done) and "view" or "nocam", x.fn or "", t = rt(env) }
						-- (in game: does setCameraData take it, while following a vehicle too? see M.camSet)
						env.log("feat journal: the view of " .. tostring(x.fn) .. " taken: camera set " .. ((okc and done) and "ok" or ("FAILED (" .. tostring(done) .. ")")))
					else
						g.status = { x.no or "timeout", x.fn or "", t = rt(env) }
						env.log("feat journal: the view of " .. tostring(x.fn) .. " not taken: " .. tostring(x.no))
					end
				end
			end
		end
	end
	-- the window's files (written by the options host only when they change)
	local peers, mode = {}, "shared"
	if onV then peers, mode = M.peers(st, env, J) end
	local det = tonumber(env.param("journal", "details")) or 0
	local head = {
		"@v\t1",
		"@me\t" .. me .. "\t" .. clean(M.base(env.me), 40),
		"@on\t" .. bit(onJ) .. "\t" .. bit(onB) .. "\t" .. bit(onV),
		"@details\t" .. (det == 1 and "1" or "0"),
		"@mode\t" .. mode,
		"@share\t" .. ((J and J.noview[me]) and "0" or "1"),
	}
	for _, p in ipairs(peers) do head[#head + 1] = "@peer\t" .. p.key .. "\t" .. clean(p.name, 40) .. "\t" .. p.state end
	-- (the tab's status line for 30 s)
	if g.status and g.status.t and rt(env) - g.status.t > 30 then g.status = nil end
	if g.status then head[#head + 1] = "@status\t" .. clean(g.status[1], 20) .. "\t" .. clean(g.status[2], 40) end
	local sig = table.concat(head, "\n") .. "\n" .. tostring(J and J.seq)
	if sig ~= g.sig then
		g.sig = sig
		local lines = head
		if onJ and J then for line in J.log:gmatch("[^\n]+") do lines[#lines + 1] = line end end
		env.write(M.FILE, lines)
	end
	-- (written empty too while the state has none yet: the file of an earlier session of the folder is not read as this game's)
	local reg = J and J.reg or "\n"
	if onB and reg ~= g.reg then
		g.reg = reg
		local lines = {}
		for line in reg:gmatch("[^\n]+") do lines[#lines + 1] = line end
		env.write(M.FILE_BUILTBY, lines)
	end
end

-- requests of the MPFever window on this game: "view" (payload: a player's key), "share" ("1" / "0")
function M.request(kind, payload, st, env)
	local g = M.guiState()
	g.sig = nil   -- (the tab's status changes: its file is written again)
	if not env.on("playerview") then
		g.status = { "off", "", t = rt(env) }
		return
	end
	local J = (type(st) == "table" and type(st.feat) == "table") and st.feat[M.ID] or nil
	if type(J) ~= "table" or type(J.log) ~= "string" then J = nil end
	local me = M.key(env.me)
	if kind == "share" then
		env.send("f_journal_share", { allow = tostring(payload) ~= "0", from = env.me })
	elseif kind == "view" then
		local to = M.key(payload)
		if to == "" or to == me or isAiKey(to) then return end
		local name = (J and J.who[to]) or clean(M.base(payload), 40)
		if J and J.noview[to] then g.status = { "noshare", name, t = rt(env) }; return end
		local _, mode = M.peers(st, env, J)
		if mode == "separate" then
			local list = M.companiesOf(st, env)
			local c1, c2 = M.companyOfKey(list, me), M.companyOfKey(list, to)
			if not (c1 and c2 and c1.id == c2.id) then g.status = { "company", name, t = rt(env) }; return end
		end
		env.send("f_journal_camreq", { to = to, from = env.me })
		g.status = { "ask", name, t = rt(env) }
	end
end

-- ------------------------------------------------------------------ the MPFever window (its own Lua state)

-- the tab's file: its header { me, on = { journal, builtby, playerview }, details, mode, share, peers, status } and its entries
function M.readFile(lines)
	local h = { peers = {} }
	local list = {}
	for _, line in ipairs(lines or {}) do
		if type(line) == "string" and line:sub(1, 1) == "@" then
			local f = split(line)
			local k = f[1]
			if k == "@me" then h.me, h.myName = f[2], f[3]
			elseif k == "@on" then h.on = { journal = f[2] == "1", builtby = f[3] == "1", playerview = f[4] == "1" }
			elseif k == "@details" then h.details = f[2] == "1"
			elseif k == "@mode" then h.mode = f[2]
			elseif k == "@share" then h.share = f[2] ~= "0"
			elseif k == "@peer" then h.peers[#h.peers + 1] = { key = f[2], name = f[3], state = f[4] }
			elseif k == "@status" then h.status = { f[2], f[3] or "" } end
		else
			local e = M.parse(line)
			if e then list[#list + 1] = e end
		end
	end
	return h, list
end

-- the camera on an entry's place (the window; the integration may replace it)
function M.focus(e)
	pcall(function() api.gui.camera.focusPosition(api.type.Vec3f.new(e.x, e.y, e.z or 0), 400) end)
end

-- the window's own choices, this game only: details shown (nil: the option's default), the player shown (nil: all)
M._u = nil

-- The tab: u.T, u.read, u.request and the window's widgets u.text(s), u.muted(s) (else u.text), u.button(label, fn) and
-- u.row(list). Returns the list of its rows, as the window's own tabs do.
function M.ui(u)
	local T = u.T
	local text = u.text
	local muted = u.muted or u.text
	local button = u.button
	local row = u.row
	local h, list = M.readFile(u.read and u.read(M.FILE) or {})
	local s = M._u or {}
	M._u = s
	local rows = {}
	if not h.on then
		rows[1] = muted(M.say(T, "nothing"))
		return rows
	end
	if h.on.journal then
		rows[#rows + 1] = muted(M.say(T, "intro"))
		local details = s.details
		if details == nil then details = h.details == true end
		-- the players of the journal, for the filter
		local players, names = {}, {}
		for _, e in ipairs(list) do
			local k = M.key(e.who)
			if not names[k] then names[k] = e.who; players[#players + 1] = k end
		end
		table.sort(players)
		if s.who and not names[s.who] then s.who = nil end
		rows[#rows + 1] = row({
			button(M.say(T, details and "details_on" or "details_off"), function() s.details = not details end),
			button(s.who and M.say(T, "who_one", names[s.who]) or M.say(T, "who_all"), function()
				local nxt = nil
				if not s.who then nxt = players[1] else
					for i, k in ipairs(players) do if k == s.who then nxt = players[i + 1] end end
				end
				s.who = nxt
			end),
		})
		local n = 0
		for i = #list, 1, -1 do
			local e = list[i]
			if (details or e.det == 0) and (not s.who or M.key(e.who) == s.who) then
				n = n + 1
				if n > M.SHOW_MAX then break end
				local r = { text(M.text(e, T)) }
				if e.x and e.y then r[#r + 1] = button(M.say(T, "show"), function() M.focus(e) end) end
				rows[#rows + 1] = row(r)
			end
		end
		if n == 0 then rows[#rows + 1] = muted(M.say(T, "nothing")) end
	end
	if h.on.builtby then rows[#rows + 1] = muted(M.say(T, "builtby_note")) end
	if h.on.playerview then
		rows[#rows + 1] = text(M.say(T, "view_title"))
		if h.mode == "separate" then rows[#rows + 1] = muted(M.say(T, "view_company")) end
		for _, p in ipairs(h.peers) do
			if p.state == "noshare" then
				rows[#rows + 1] = row({ text(p.name), muted(M.say(T, "st_noshare", p.name)) })
			else
				local key = p.key
				rows[#rows + 1] = row({ text(p.name), button(M.say(T, "view_button"), function() u.request("view", key) end) })
			end
		end
		if #h.peers == 0 then rows[#rows + 1] = muted(M.say(T, "view_none")) end
		local share = h.share ~= false
		rows[#rows + 1] = button(M.say(T, share and "share_on" or "share_off"), function() u.request("share", share and "0" or "1") end)
		if h.status and M.TEXTS["st_" .. tostring(h.status[1])] then rows[#rows + 1] = muted(M.say(T, "st_" .. h.status[1], h.status[2])) end
	end
	return rows
end

-- ------------------------------------------------------------------ the entity windows (a hook of the window, "builtby")

-- the registry's file (M.FILE_BUILTBY) as key -> { who, at, ed }
function M.builtByIndex(lines)
	local idx = {}
	for _, line in ipairs(lines or {}) do
		local f = split(tostring(line))
		if f[1] and f[1] ~= "" and ((f[2] or "") ~= "" or (f[4] or "") ~= "") then idx[f[1]] = { who = f[2] or "", at = tonumber(f[3]), ed = f[4] or "" } end
	end
	return idx
end

-- « Built by X » (« ..., changed by Y ») for a construction's key (M.conKey, or M.keyOfSg of a station's R.sgKey); nil when the
-- registry does not know it
function M.builtByText(idx, key, T)
	if type(idx) ~= "table" or type(key) ~= "string" then return nil end
	for _, k in ipairs(nearKeys(key)) do
		local r = idx[k]
		if r then
			if r.who == "" then return M.say(T, "changed_by", r.ed) end
			if r.ed and r.ed ~= "" then return M.say(T, "built_by_ed", r.who, r.ed) end
			return M.say(T, "built_by", r.who)
		end
	end
	return nil
end

-- « Bought by X » / « Created by X » for a vehicle or a line made during a session: its creation key in the bridge's bindings
-- (st.bind, the window's U.rev). A computer company's purchase goes through the host: its key names the host (the window shows
-- the company instead)
function M.creatorText(bindKey, T)
	local kind, origin = creatorOfKey(bindKey)
	if not kind then return nil end
	return M.say(T, kind == "V" and "bought_by" or "created_by", M.base(origin))
end

return M
