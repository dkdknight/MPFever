-- MPFever 0.6: the public games' options (release/recherche-0.6/09-trouver-joueurs.md, the owner's decisions I2-I8 in
-- 00-REPONSES.md). They are the work of MPFever.exe and of the public list (launcher/PublicGames.cs, serverlist/ServerList.cs),
-- not of the game: this module declares them, so that the lobby's "Game settings" and the window's Game tab show them like the
-- others (see docs/FEATURES-0.6.md), and draws the MPFever window's "Public game" tab while one of them is on (M.ui: the list's
-- state, the arrivals waiting with Accept and Refuse, the ban list with Remove; from the host's own lines of mp_status.txt, its
-- buttons are requests to MPFever.exe). No simulation code: no event, no state in the game. Every option is off by default;
-- with all of them off a game is hosted exactly as in 0.5.14.
--   public              the lobby shows in the public list (found by the host's Steam id, joined through Steam with no port to
--                       open); max: the players at most (8, I7); late: it stays listed while the game runs (I2, off: the lobby
--                       only); ip: the host's IP address shown in the list too (I3, the lobby warns the host). The game's name,
--                       "Partie de <name>" / "<name>'s game", is changed in the lobby (I7).
--   join_bans           the host kicks and bans players from the lobby and from the MPFever window; the banned ones are
--                       refused from then on, in its next games too (a list kept on its PC, I4)
--   join_approve        every arrival waits until the host lets it in or not (I4)
--   join_steamfriends   a private game takes Steam connections from the host's Steam friends only (I6); joining by address
--                       still works, and a public game takes everybody
-- No moderation of the list in v1 (I8). The texts of the values go through T(fr, en) of the options host.
local M = {}
M.ID = "public"
M.OPTIONS = {
	{ id = "public",
		title = { "Partie publique", "Public game" },
		desc = { "Le salon apparaît dans la liste publique des parties, avec votre identifiant Steam : n'importe quel joueur de la même version peut le rejoindre par Steam, sans port à ouvrir.",
			"The lobby shows in the public list of games, with your Steam id: any player with the same version can join it through Steam, with no port to open." },
		modes = "both",
		params = {
			{ id = "max", label = { "Joueurs au maximum", "Players at most" }, values = { 2, 3, 4, 5, 6, 7, 8 }, default = 8 },
			{ id = "late", label = { "Arrivées pendant la partie", "Arrivals during the game" }, values = { 0, 1 }, default = 0,
				show = function(v, T) return v == 1 and T("Oui (chacune recharge la partie de tous)", "Yes (each one reloads everybody's game)") or T("Non (salon seulement)", "No (lobby only)") end },
			{ id = "ip", label = { "Montrer mon adresse IP", "Show my IP address" }, values = { 0, 1 }, default = 0,
				show = function(v, T) return v == 1 and T("Oui (visible par tous)", "Yes (shown to everybody)") or T("Non (par Steam seulement)", "No (through Steam only)") end },
		} },
	{ id = "join_bans",
		title = { "Exclure et bannir", "Kick and ban" },
		desc = { "L'hôte peut exclure ou bannir un joueur depuis le salon et la fenêtre MPFever. Les bannis sont refusés, aussi dans ses parties suivantes.",
			"The host can kick or ban a player from the lobby and the MPFever window. Banned players are refused, in its next games too." },
		modes = "both" },
	{ id = "join_approve",
		title = { "Accepter chaque arrivée", "Approve every arrival" },
		desc = { "Chaque joueur qui arrive attend que l'hôte l'accepte ou le refuse (salon ou fenêtre MPFever).",
			"Every player who arrives waits until the host accepts or refuses them (lobby or MPFever window)." },
		modes = "both" },
	{ id = "join_steamfriends",
		title = { "Steam : amis seulement", "Steam: friends only" },
		desc = { "Une partie privée n'accepte par Steam que vos amis Steam. Rejoindre par l'adresse reste possible.",
			"A private game takes only your Steam friends through Steam. Joining by the address still works." },
		modes = "both" },
}

-- ---------------------------------------------------------------- the MPFever window's "Public game" tab
-- Shown to every player while one of the options above is on. The host's from its own lines of mp_status.txt (MPFever.exe's
-- PublicHostStatus, never sent to the players): pub (the list's state for this game: wait, listed, ended, !old, !off, !steam,
-- !down, !<error>), pubname, pubip (the address shown in the list), pending (the arrivals waiting, name#id), pubkick, bans
-- ("name|day;..."), pubfriends (Steam takes the host's friends only). Its buttons are the requests of the lobby's (admit,
-- unban: launcher/PublicGames.cs's PublicMenuRequest); Kick and Ban are on the players' lines of the Session tab.
M.TAB = { id = "public", title = { "Partie publique", "Public game" } }
-- (0.7.4) the page's « How does it work? », at its end in the Hub (see the window's U.featTabRows)
M.HELP = {
	{ "Une partie publique apparaît dans la liste des parties de MPFever avec votre identifiant Steam : tout joueur de la même version peut la rejoindre par Steam, sans port à ouvrir.",
		"A public game shows in MPFever's list of games with your Steam id: any player of the same version may join it through Steam, without opening a port." },
	{ "L'hôte peut accepter chaque arrivée, exclure ou bannir un joueur (les bannis sont refusés dans ses parties suivantes aussi), et limiter le nombre de joueurs.",
		"The host may approve every arrival, kick or ban a player (the banned ones are refused in the host's next games too), and limit the number of players." },
}

-- the list's state as the host reads it: its text and its class
local function listState(p, T)
	if p == "listed" then return T("La partie est dans la liste publique.", "The game is in the public list."), "success" end
	if p == "ended" then return T("La partie n'est plus dans la liste publique (arrivées pendant la partie : non).", "The game is no longer in the public list (arrivals during the game: no)."), nil end
	if p == "" or p == "wait" then return T("Partie publique : envoi à la liste publique...", "Public game: sending to the public list..."), nil end
	if p == "!old" then return T("La liste publique ne prend pas encore les parties de joueurs : vos amis peuvent toujours rejoindre par Steam ou par l'adresse.",
		"The public list does not take players' games yet: your friends can still join through Steam or by the address."), "warning" end
	if p == "!off" then return T("Aucune liste publique n'est utilisée ici (serverlist= dans mpfever_settings.txt) : la partie n'y apparaît pas.",
		"No public list is used here (serverlist= in mpfever_settings.txt): the game does not show in it."), "warning" end
	if p == "!steam" then return T("Steam n'est pas encore prêt : la partie apparaîtra dans la liste dès qu'il le sera.", "Steam is not ready yet: the game will show in the list as soon as it is."), "warning" end
	return T("La liste publique ne répond pas : vos amis peuvent toujours rejoindre par Steam ou par l'adresse.", "The public list does not answer: your friends can still join through Steam or by the address.")
		.. ((p ~= "!down" and p:sub(1, 1) == "!") and (" (" .. p:sub(2) .. ")") or ""), "warning"
end

function M.ui(u)
	local T = u.T
	local function status(k) return type(u.status) == "function" and tostring(u.status(k) or "") or "" end
	local public = u.on("public")
	-- (the players: what the host's options mean for them)
	if not u.isHost then
		if public then u.add(u.text(T("Cette partie est publique : n'importe quel joueur de la même version peut la trouver dans la liste et la rejoindre.",
			"This game is public: any player with the same version can find it in the list and join it."))) end
		if u.on("join_approve") then u.add(u.muted(T("L'hôte accepte ou refuse chaque arrivée.", "The host accepts or refuses every arrival."))) end
		if u.on("join_bans") then u.add(u.muted(T("L'hôte peut exclure ou bannir un joueur.", "The host can kick or ban a player."))) end
		if u.on("join_steamfriends") and not public then u.add(u.muted(T("Par Steam, seuls les amis Steam de l'hôte peuvent rejoindre.", "Through Steam, only the host's Steam friends can join."))) end
		return
	end
	if public then
		u.add(u.title(T("Liste publique", "Public list")))
		local text, cls = listState(status("pub"), T)
		u.add(u.text(text, cls))
		if status("pubname") ~= "" then u.add(u.muted(T("Nom de la partie", "Game name") .. T(" : ", ": ") .. status("pubname"))) end
		u.add(u.muted(T("Joueurs au maximum", "Players at most") .. T(" : ", ": ") .. tostring(u.param("public", "max"))
			.. "   ·   " .. T("Arrivées pendant la partie", "Arrivals during the game") .. T(" : ", ": ") .. (u.param("public", "late") == 1 and T("oui", "yes") or T("non", "no"))))
		if status("pubip") ~= "" then
			u.add(u.text((T("Votre adresse IP (%s) est visible par tous dans la liste publique : n'importe qui peut la voir et s'en servir.",
				"Your IP address (%s) is shown to everybody in the public list: anyone can see and use it."):gsub("%%s", function() return status("pubip") end)), "warning"))
		end
		if u.mode ~= "separate" then
			u.add(u.text(T("Une entreprise pour tous : un inconnu pourra construire, démolir et dépenser l'argent de l'entreprise.",
				"One company for everybody: a stranger will be able to build, demolish and spend the company's money."), "warning"))
		end
		u.add(u.gap(8))
	end
	if u.on("join_steamfriends") then
		u.add(u.text(status("pubfriends") == "1" and T("Steam : seuls vos amis Steam peuvent rejoindre par Steam.", "Steam: only your Steam friends can join through Steam.")
			or T("Steam : tout le monde peut rejoindre par Steam (la partie est ou a été publique pendant cette session).", "Steam: everybody can join through Steam (the game is or was public during this session).")))
		u.add(u.gap(8))
	end
	-- the arrivals waiting for the host's answer (join_approve; a player banned or a full game is refused before asking)
	local pending = status("pending")
	if u.on("join_approve") or pending ~= "" then
		u.add(u.title(T("Arrivées", "Arrivals")))
		if pending == "" then u.add(u.muted(T("Personne n'attend.", "Nobody is waiting."))) end
		for who in pending:gmatch("[^,]+") do
			local id = who
			u.add(u.text(u.Tf("%s veut rejoindre la partie", "%s wants to join the game", (id:gsub("#%d+$", ""))), "warning"))
			u.add(u.row({ u.button(T("Accepter", "Accept"), function() u.exe("admit", id .. " 1") end, true),
				u.gap(6), u.button(T("Refuser", "Refuse"), function() u.exe("admit", id .. " 0") end) }))
		end
		u.add(u.gap(8))
	end
	-- the players banned from the host's games (join_bans; kept on its PC), each can be taken back
	if u.on("join_bans") then
		local banned = {}
		for e in status("bans"):gmatch("[^;]+") do
			local nm, day = e:match("^([^|]*)|?(.*)$")
			if nm and nm ~= "" then banned[#banned + 1] = { nm = nm, day = day or "" } end
		end
		u.add(u.title((T("Joueurs bannis (%s)", "Banned players (%s)"):gsub("%%s", tostring(#banned)))))
		u.add(u.muted(T("Exclure et Bannir : sur la ligne de chaque joueur de l'onglet Session.", "Kick and Ban: on each player's line of the Session tab.")))
		for _, b in ipairs(banned) do
			local nm = b.nm
			u.add(u.text(nm .. (b.day ~= "" and ("   ·   " .. b.day) or "")))
			u.add(u.row({ u.button(T("Retirer", "Remove"), function() u.exe("unban", nm) end) }))
		end
	end
end
return M
