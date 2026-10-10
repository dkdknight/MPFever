-- MPFever page of the game's main menu.
-- The main menu's UI runs in its own Lua state, where mods are not loaded: the native module (winhttp.dll) puts
-- require("mpfever_1::/mpfever_menu.lua") in front of gui/menu/main_menu.tl. This file then wraps the main page through
-- the UI's recipe replacement table: the page is drawn as usual, with a « Multiplayer » button on top of it, which opens
-- the MPFever window (host one of the player's savegames, or join a host by its address).
-- Link with MPFever.exe: two small files in the session folder (MPFEVER_DIR).
--   menu_req.txt   written here: seq TAB command TAB argument TAB player name   (host / join / cancel)
--   menu_state.txt written by MPFever.exe: key=value lines (phase, text, progress, load, name, addr, players)
-- No backslash characters on purpose.

local IO = package.loaded.io
local DIR = os.getenv("MPFEVER_DIR")
if not (IO and DIR and DIR ~= "") then return {} end

local BS, NL, TAB = string.char(92), string.char(10), string.char(9)
local FR = (os.getenv("MPFEVER_LANG") or "en") == "fr"
local function T(fr, en) return FR and fr or en end

local function log(msg)
	pcall(print, "[MPFEVER-MENU] " .. tostring(msg))
	local f = IO.open(DIR .. BS .. "menu.log", "ab")
	if f then f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. NL) f:close() end
end

local function readFile(name)
	local f = IO.open(DIR .. BS .. name, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function writeFile(name, text)
	local f = IO.open(DIR .. BS .. name, "wb")
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

-- what MPFever.exe tells the menu
local function readState()
	local st = {}
	for line in (readFile("menu_state.txt") or ""):gmatch("[^" .. NL .. "]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then st[k] = v:gsub(string.char(13), "") end
	end
	return st
end

local reqSeq = 0
local function request(cmd, arg, name, option)
	reqSeq = reqSeq + 1
	local seq = tostring(os.time()) .. "." .. reqSeq
	writeFile("menu_req.txt", seq .. TAB .. cmd .. TAB .. (arg or "") .. TAB .. (name or "") .. TAB .. (option or "") .. NL)
	log("request " .. cmd .. " " .. tostring(arg))
end

local function listSaves()
	local out = {}
	local ok, err = pcall(function()
		local ns = app.SaveGameNamespace.getSavegame()
		local byName = {}
		for _, s in ipairs(app.findAllSavegames(ns) or {}) do
			-- one entry per savegame name, the most recent file
			local name = s.saveName
			if name and not name:find("^MPFever resync") and not name:find("^autosave_") and not name:find("^crash_") then
				local cur = byName[name]
				if not cur or (s.timestamp or 0) > (cur.timestamp or 0) then byName[name] = s end
			end
		end
		for _, s in pairs(byName) do out[#out + 1] = s end
		table.sort(out, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
	end)
	if not ok then log("savegames: " .. tostring(err)) end
	return out
end

-- loads a savegame of this player; the application script (mpfever_auto.lua) starts it once loaded
local function loadSave(name)
	local ns = app.SaveGameNamespace.getSavegame()
	local found
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == name and (not found or (s.timestamp or 0) > (found.timestamp or 0)) then found = s end
	end
	if not found then log("savegame not found: " .. tostring(name)) return false end
	local id = api.type.SavegameId.new()
	id.path = found.path
	id.saveGameName = found.saveName
	id.saveGameNamespace = ns
	writeFile("resync_pending.txt", "1")
	log("loading savegame '" .. name .. "'")
	app.loadGame(id, false)
	return true
end

-- the main page's recipe id, caught when main_page.tl registers it (this file is loaded before it)
local mainId
local MPPage
local installReplacement
do
	local detail = api.gui.react.detail
	local orig = detail.makeRecipeId
	local ok, err = pcall(function()
		detail.makeRecipeId = function(name, ...)
			local id = orig(name, ...)
			if name == "MainPage" and not mainId then mainId = id; installReplacement() end
			return id
		end
	end)
	if not ok then log("makeRecipeId not wrapped: " .. tostring(err)) end
end

local function setup()
	local react = ug_require("::/gui/main/react.lua")
	local builtin = ug_require("::/gui/main/builtin.lua")
	local V = builtin.type.Orientation.Vertical
	local H = builtin.type.Orientation.Horizontal

	local WIDTH = 760   -- width of the MPFever window's content
	local autoClosed = false
	local function text(s, class, width)
		return builtin.TextView{ meta = { class = class or "font-scale-title-4" }, text = s, width = width }
	end
	local function button(label, onClick, enabled, class, width)
		return builtin.Button{
			meta = { class = "secondary", enabled = enabled ~= false },   -- game style: outlined button
			content = text(label, class or "font-scale-title-4", width),
			onClick = onClick,
		}
	end
	local function gap() return text(" ", "font-scale-body") end
	local function box(orientation, children, class)
		return builtin.Component{
			meta = { class = class },
			layout = builtin.BoxLayout{ orientation = orientation, children = children },
		}
	end

	local MPWindow = react.RegisterWrapperRecipe("MPFeverWindow", builtin.Window, function(wp)
		local st0 = readState()
		local tab = react.useState("host")
		local saves = react.useStateLazy(listSaves)
		local selected = react.useState(nil)
		local name = react.useState(st0.name or "")
		local companies = react.useState("shared")     -- hosting: everybody plays one company, or each player has its own
		local addr = react.useState(st0.addr or "")
		local state = react.useState(st0)
		-- (the host's savegame, once received, is loaded by the application script mpfever_auto.lua)
		react.onStepTimer(function()
			local s = readState()
			state:set(s)
			-- the game is about to load (the host's own, or the host's game received by a player who joins) or is loaded: the
			-- window has done its job and goes away. Left open it stayed over the game as a leftover whose close button no
			-- longer answered, so it is closed before the load starts.
			if s.phase == "hosting" or s.phase == "loading" or s.phase == "ingame" then
				if not autoClosed then
					autoClosed = true
					log("phase " .. tostring(s.phase) .. ": closing the MPFever window")
					local ok, err = pcall(wp.onClose)
					if not ok then log("closing the window failed: " .. tostring(err)) end
				end
			else
				autoClosed = false
			end
		end, 0.5)

		local st = state:old()
		local busy = st.phase ~= nil and st.phase ~= "" and st.phase ~= "idle" and st.phase ~= "error"
		local rows = {}

		rows[#rows + 1] = text(T("Jouer à plusieurs à Transport Fever 3", "Play Transport Fever 3 together"), "font-scale-title-2", WIDTH)
		rows[#rows + 1] = gap()
		rows[#rows + 1] = box(H, {
			text(T("Pseudo :  ", "Player name:  ")),
			builtin.TextInputField{
				meta = { class = "font-scale-title-4" },
				placeholderText = T("Votre pseudo", "Your name"),
				value = name:old(),
				onTyping = function(v) name:set(v) end,
			},
		})
		rows[#rows + 1] = gap()
		rows[#rows + 1] = box(H, {
			button((tab:old() == "host" and "> " or "") .. T("Héberger une partie", "Host a game"), function() tab:set("host") end, not busy, "font-scale-title-3", WIDTH / 2 - 10),
			button((tab:old() == "join" and "> " or "") .. T("Rejoindre une partie", "Join a game"), function() tab:set("join") end, not busy, "font-scale-title-3", WIDTH / 2 - 10),
		})
		rows[#rows + 1] = gap()

		if tab:old() == "host" then
			rows[#rows + 1] = text(T("Choisissez la sauvegarde à partager :", "Choose the savegame to share:"))
			local list = {}
			for i, s in ipairs(saves:old()) do
				if i > 12 then break end
				local isSel = selected:old() == s.saveName
				list[#list + 1] = button((isSel and ">  " or "    ") .. s.saveName .. (s.timestamp and ("   (" .. os.date("%d/%m/%Y %H:%M", s.timestamp) .. ")") or ""), function() selected:set(s.saveName) end, not busy, nil, WIDTH)
			end
			if #list == 0 then list[1] = text(T("Aucune sauvegarde trouvée.", "No savegame found.")) end
			rows[#rows + 1] = box(V, list)
			rows[#rows + 1] = gap()
			rows[#rows + 1] = text(T("Entreprises :", "Companies:"))
			rows[#rows + 1] = box(H, {
				button((companies:old() == "shared" and "> " or "") .. T("Une entreprise pour tous", "One company for everybody"), function() companies:set("shared") end, not busy, "font-scale-title-4", WIDTH / 2 - 10),
				button((companies:old() == "separate" and "> " or "") .. T("Une entreprise par joueur", "One company per player"), function() companies:set("separate") end, not busy, "font-scale-title-4", WIDTH / 2 - 10),
			})
			rows[#rows + 1] = gap()
			rows[#rows + 1] = button(T("Héberger cette partie", "Host this game"), function()
				local sel = selected:old()
				if not sel then return end
				request("host", sel, name:old(), companies:old())   -- MPFever.exe opens the session, then has the savegame loaded
			end, selected:old() ~= nil and not busy, "font-scale-title-3", WIDTH)
		else
			rows[#rows + 1] = box(H, {
				text(T("Adresse de l'hôte : ", "Host address: ")),
				builtin.TextInputField{
					meta = { class = "font-scale-title-4" },
					placeholderText = "1.2.3.4:28090",
					value = addr:old(),
					onTyping = function(v) addr:set(v) end,
				},
			})
			rows[#rows + 1] = gap()
			rows[#rows + 1] = button(T("Rejoindre", "Join"), function()
				if addr:old() == "" then return end
				request("join", addr:old(), name:old())
			end, addr:old() ~= "" and not busy, "font-scale-title-3", WIDTH)
		end
		rows[#rows + 1] = gap()

		if st.invite == "1" then rows[#rows + 1] = button(T("Inviter des amis Steam", "Invite Steam friends"), function() request("invite") end, true, "font-scale-title-3", WIDTH) end
		if busy and st.phase ~= "hosting" and st.phase ~= "ingame" then rows[#rows + 1] = button(T("Annuler", "Cancel"), function() request("cancel") end) end
		if st.text and st.text ~= "" then rows[#rows + 1] = text(st.text, nil, WIDTH) end
		if st.players and st.players ~= "" then rows[#rows + 1] = text(T("Joueurs : ", "Players: ") .. st.players, nil, WIDTH) end

		return builtin.Window{
			title = "MPFever – " .. T("Multijoueur", "Multiplayer"),
			id = "window.mpfever",
			initialX = 0.5,
			initialY = 0.5,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			content = box(V, rows),
		}
	end)

	MPPage = react.RegisterRecipe("MPFeverMainPage", function(p)
		local function open()
			local wc = p.commonParams.windowContainer:get():getApi()
			wc.addSingletonWindow(MPWindow, {
				onClose = function() p.commonParams.windowContainer:get():getApi().removeAllWindows(MPWindow) end,
			})
		end
		-- test mode (MPFEVER_MENU_OPEN): the window opens by itself
		react.onMount(function() if os.getenv("MPFEVER_MENU_OPEN") then open() end end)
		-- inside the menu's box layout a page must be a layout: the original page fills it, the button floats over it
		return builtin.FloatingLayout{
			children = {
				builtin.FloatingLayoutChild{ h = -1, v = -1, item = builtin.Component{ mouseTransparent = true, layout = builtin.BoxLayout{ children = { _react.originalRecipeFn[mainId](p) } } } },
				builtin.FloatingLayoutChild{ h = 0.02, v = 0.5, item = button(T("  MULTIJOUEUR  ", "  MULTIPLAYER  ") .. string.char(10) .. "  MPFever", open, true, "font-scale-title-1") },
			},
		}
	end)
end

installReplacement = function()
	log("main page recipe id caught")
	_react.recipeReplace[mainId] = function(...)
		if not MPPage then
			local ok, err = pcall(setup)
			if not ok or not MPPage then
				log("setup failed: " .. tostring(err))
				_react.recipeReplace[mainId] = nil
				return _react.originalRecipeFn[mainId](...)
			end
			log("multiplayer page ready")
		end
		return MPPage(...)
	end
end
log("menu module loaded")
return {}
