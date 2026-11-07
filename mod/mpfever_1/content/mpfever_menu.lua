-- MPFever page of the game's main menu.
-- The main menu's UI runs in its own Lua state, where mods are not loaded: the native module (winhttp.dll) puts
-- require("mpfever_1::/mpfever_menu.lua") in front of gui/menu/main_menu.tl. This file then wraps the main page through
-- the UI's recipe replacement table: the page is drawn as usual, with a « Multiplayer » card on top of it, which opens
-- the MPFever page in its place (host one of the player's savegames, or join a host by its address).
-- Link with MPFever.exe: two small files in the session folder (MPFEVER_DIR).
--   menu_req.txt   written here: seq TAB command TAB argument TAB player name TAB option   (host / join / cancel; the option
--                  is the company mode of a host, the password of a dedicated server for a join)
--   menu_state.txt written by MPFever.exe: key=value lines (phase, text, progress, load, name, addr, players)
-- No backslash characters on purpose.

local IO = package.loaded.io
local DIR = os.getenv("MPFEVER_DIR")
if not (IO and DIR and DIR ~= "") then return {} end

local BS, NL, TAB = string.char(92), string.char(10), string.char(9)
-- Texts: French and English are written in the code as T("français", "English"); the other languages come from
-- lang.txt in the session folder, written by MPFever.exe: "@lang TAB code", then "English TAB translation" lines.
-- Read again when MPFever.exe announces another language (lang= in menu_state.txt).
local LANG, LANGCODE = {}, os.getenv("MPFEVER_LANG") or "en"
local function loadLang()
	local t = {}
	local f = IO.open(DIR .. BS .. "lang.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		for line in s:gmatch("[^" .. NL .. "]+") do
			local k, v = line:match("^(.-)" .. TAB .. "(.*)$")
			if k and k ~= "" then
				v = v:gsub(string.char(13), "")
				if k == "@lang" then LANGCODE = v else t[k] = v end
			end
		end
	end
	LANG = t
end
loadLang()
local function T(fr, en)
	if LANGCODE == "fr" then return fr end
	return LANG[en] or en
end

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
-- (a state read while MPFever.exe writes it lacks its last line "end=1": the last whole one is kept, else the page showed the
-- tabs for a moment, then the session again, over and over while the host's game came in)
local lastState, endSeen = nil, false
local function readState()
	local st = {}
	for line in (readFile("menu_state.txt") or ""):gmatch("[^" .. NL .. "]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then st[k] = v:gsub(string.char(13), "") end
	end
	if st["end"] then endSeen = true end
	if st["end"] or not lastState or not endSeen then
		lastState = st
		return st
	end
	local copy = {}
	for k, v in pairs(lastState) do copy[k] = v end
	return copy
end

local reqSeq = 0
local function request(cmd, arg, name, option)
	reqSeq = reqSeq + 1
	local seq = tostring(os.time()) .. "." .. reqSeq
	writeFile("menu_req.txt", seq .. TAB .. cmd .. TAB .. (arg or "") .. TAB .. (name or "") .. TAB .. (option or "") .. NL)
	log("request " .. cmd .. " " .. tostring(arg))
end

-- the folders of the player's savegames, as the game gives them (save_dirs.txt, one per line): the launcher looks there
-- too. A game not installed through Steam keeps them elsewhere than Steam's userdata, and the launcher found none of
-- them (« savegame not found » when hosting, issue #76)
local savedDirs = nil
local function noteSaveDirs(list)
	local seen, dirs = {}, {}
	for _, s in ipairs(list) do
		local d = type(s.path) == "string" and s.path:gsub(BS, "/"):match("^(.+)/[^/]*%.sav$") or nil
		if d and d ~= "" and not seen[d] then seen[d] = true dirs[#dirs + 1] = d end
	end
	-- (the engine leaves SaveGameInfo.path empty: issue #80, and #76 again. The game's own folder of the player's data, its
	-- "save" folder inside, is where it writes them, wherever the game is installed)
	pcall(function()
		local u = app.getUserDataFolder()
		if type(u) == "string" and u ~= "" then
			u = u:gsub(BS, "/"):gsub("/+$", "")
			for _, d in ipairs({ u .. "/save" }) do
				if not seen[d] then seen[d] = true dirs[#dirs + 1] = d end
			end
		end
	end)
	table.sort(dirs)
	local text = table.concat(dirs, NL)
	if text ~= savedDirs then
		savedDirs = text
		writeFile("save_dirs.txt", text .. NL)
		log("savegame folders: " .. (text ~= "" and text:gsub(NL, " ; ") or ("none (first path: " .. tostring(list[1] and list[1].path) .. ")")))
	end
end

-- (0.7.4) The host's copies a resynchronisation made (« MPFever resync ») are left out, unless the box under the list is ticked:
-- players asked why the game they had just played was not there. MPFEVER_MENU_RESYNC=1: shown at first (tests)
local function isResyncSave(name) return type(name) == "string" and name:find("^MPFever resync") ~= nil end
local function listSaves()
	local out = {}
	local ok, err = pcall(function()
		local ns = app.SaveGameNamespace.getSavegame()
		local byName = {}
		local all = app.findAllSavegames(ns) or {}
		pcall(noteSaveDirs, all)
		for _, s in ipairs(all) do
			-- one entry per savegame name, the most recent file (the resynchronisations' copies too: the Host tab shows them
			-- when asked)
			local name = s.saveName
			if name and not name:find("^autosave_") and not name:find("^crash_") then
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

-- The mods of a savegame (MPFever left out), as the host sends them to the players of its lobby: "id|name|source|hub"
-- entries separated by ";;" (one line of menu_state.txt). The mod's display name and origin (Steam Workshop, mod.io...)
-- come from the savegame's mod descriptions; hub is its number on its Mod Hub (mod.io, Steam Workshop), from which a player
-- who lacks it installs it (empty for a local mod).
local MOD_ID = "mpfever_1"
-- A mod's number on its Mod Hub, asked only for a mod installed here and once per mod: for a mod the game does not have, the
-- engine asserts ("Could not find ModDesc in cache", ModRep.cpp:338), slowly, and every savegame tile asked again for each of
-- its mods. A player with 370 mods and savegames made with mods since removed saw the page freeze, then the game stop, when
-- opening it (issue #92). A mod not installed is not kept (the next tile asks whether it is, which costs nothing).
local modHubIds = {}
local function modHubId(m, id)
	if modHubIds[id] ~= nil then return modHubIds[id] end
	local okx, here = pcall(function() return app.getUserProfile():getModRep():exists(m) end)
	if okx and not here then return "" end
	local hub = ""
	pcall(function()
		local h = api.modhub.getModHubModIdForModId(m)
		if h and h:isValid() and tostring(h.value):match("^[%w_-]+$") then hub = tostring(h.value) end
	end)
	modHubIds[id] = hub
	return hub
end
local function modsOf(info)
	local out, descs = {}, {}
	pcall(function()
		for _, d in ipairs(info.metadata.gameModDescs or {}) do
			if d.modId and d.modId.name then descs[d.modId.name] = d end
		end
	end)
	pcall(function()
		for _, m in ipairs(info.mods or {}) do
			local id = m.name
			if id and id ~= "" and id ~= MOD_ID then
				local d = descs[id]
				local hub = modHubId(m, id)
				out[#out + 1] = { id = id, name = d and d.name ~= "" and d.name or id, source = d and d.modSource or "", hub = hub }
			end
		end
	end)
	return out
end

local function encodeMods(mods)
	local parts = {}
	local function clean(s) return (tostring(s or ""):gsub("[|;%c]", " ")) end
	for _, m in ipairs(mods or {}) do parts[#parts + 1] = clean(m.id) .. "|" .. clean(m.name) .. "|" .. clean(m.source) .. "|" .. clean(m.hub) end
	return table.concat(parts, ";;")
end

-- MPFever.exe adds what it knows of each mod (see Mods.cs): "id|name|source|kind|level|here|note|personal", kind = assets,
-- load, ui or sim (a script acting on the game), level = ok, fixed, caution or bad, here = ok, differs or notfound (a player's
-- PC), personal = host (the host's personal mod, not needed by the others), mine (taken for personal by this player) or empty
local function decodeMods(s)
	local out = {}
	for e in (s or ""):gmatch("[^;]+") do
		local f = {}
		for x in (e .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
		local id = f[1]
		if id and id ~= "" then
			out[#out + 1] = { id = id, name = (f[2] or "") ~= "" and f[2] or id, source = f[3] or "", kind = f[4] or "",
				level = f[5] or "", here = f[6] or "", note = f[7] or "", personal = f[8] or "", hub = f[9] or "", size = f[10] or "" }
		end
	end
	return out
end

-- whether a mod is installed on this PC (nil: unknown)
local function modInstalled(id)
	local ok, r = pcall(function()
		local m = api.type.ModId.new()
		m.name = id
		return app.getUserProfile():getModRep():exists(m)
	end)
	if ok then return r and true or false end
	return nil
end

-- Installing a host's mod from its Mod Hub (0.5.0): the game's own Mod Hub subscribes this player to it and downloads it
-- (api.modhub, as its Mod Manager does; the way of TPF3-MP's roommods.lua). Each mod is asked once per menu; MPFEVER_AUTOMODS=0
-- (the launcher's setting): not by itself, a button per mod instead.
local hub = { installs = {}, requests = {} }
function hub.backend(source)
	local ok, id = pcall(function() return api.modhub.getBackendIdForSource((source and source ~= "") and source or "mod.io") end)
	if ok and type(id) == "number" and id >= 0 then return id end
	ok, id = pcall(function() return api.modhub.getBackendIdForSource("mod.io") end)
	if ok and type(id) == "number" and id >= 0 then return id end
	return nil
end
function hub.modId(number)
	local id = api.type.modhub.ModId.new()
	id.value = tostring(number)
	return id
end
-- "ok", or why not: "offline" (no Mod Hub), "signed_out" (not signed in to it)
function hub.ready(source)
	local b = hub.backend(source)
	if not b then return "offline" end
	local ok, st = pcall(function()
		if not api.modhub.isInitialized(b) then return "offline" end
		if api.modhub.getCapabilities(b).isInfoOnly then return "offline" end
		if api.modhub.getUserInfo(b) == nil then return "signed_out" end
		return "ok"
	end)
	return ok and st or "offline"
end
-- "none", "subscribed", "downloading", "installed" or "failed"
function hub.state(source, number)
	local b = hub.backend(source)
	if not b then return "none" end
	local ok, st = pcall(function()
		local id = hub.modId(number)
		local states = api.type.modhub.InstallState
		local s = api.modhub.getModInstallState(b, id)
		if s == states.Installed then return "installed" end
		if s == states.InsufficientSpace or s == states.MiscError then return "failed" end
		if s == states.Downloading or s == states.Extracting or s == states.InstallationPending or s == states.UpdatePending then return "downloading" end
		if api.modhub.getModSubscriptionState(b, id) then return "subscribed" end
		return "none"
	end)
	return ok and st or "none"
end
function hub.install(m)
	if hub.installs[m.hub] then return end
	local b = hub.backend(m.source)
	if not b then hub.installs[m.hub] = { state = "failed", err = "Mod Hub" }; return end
	hub.installs[m.hub] = { state = "asked" }
	log("Mod Hub: subscribing to " .. tostring(m.id) .. " (" .. tostring(m.source) .. " " .. tostring(m.hub) .. ")")
	local ok, err = pcall(function()
		local key, over = {}, false
		local handle = api.modhub.subscribeModAsync(b, api.type.modhub.SubscribeModRequest.new(hub.modId(m.hub)), function(result)
			over = true
			hub.requests[key] = nil
			local okr, failed = pcall(function()
				if result:isSuccess() then return nil end
				local e = result:getError()
				return e and e.message or "?"
			end)
			if okr and failed == nil then
				hub.installs[m.hub] = { state = "subscribed" }
				log("Mod Hub: subscribed to " .. tostring(m.id))
			else
				hub.installs[m.hub] = { state = "failed", err = tostring(failed) }
				log("Mod Hub: " .. tostring(m.id) .. " not subscribed: " .. tostring(failed))
			end
		end)
		if not over then hub.requests[key] = handle end
	end)
	if not ok then hub.installs[m.hub] = { state = "failed", err = tostring(err) }; log("Mod Hub: " .. tostring(err)) end
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

-- The release notes window (with the thank-you note for the game's buyers), which the main menu opens over the main
-- page at start until "Do Not Show Again": its close button calls back into the main page, whose states are gone once a
-- game has been loaded from it as MPFever does (the game's own menus leave the main page first). Left open, the window
-- stayed over the loaded game and its close buttons no longer removed it. Its onClose is caught here (recipe
-- replacement, as for the main page) so that MPPage closes it before a game loads.
local NOTICE_WINDOWS = { ReleaseNotesWindow = true }
local noticeClose = {}   -- recipe id -> onClose of that window while it is shown
local function catchNotice(id, name)
	_react.recipeReplace[id] = function(p, ...)
		local okq, q = pcall(function()
			if type(p) ~= "table" or type(p.onClose) ~= "function" then return nil end
			local orig = p.onClose
			local c = {}
			for k, v in pairs(p) do c[k] = v end
			-- (closed by its own button: nothing left to close)
			c.onClose = function(...)
				noticeClose[id] = nil
				return orig(...)
			end
			noticeClose[id] = c.onClose
			return c
		end)
		if okq and q then return _react.originalRecipeFn[id](q, ...) end
		return _react.originalRecipeFn[id](p, ...)
	end
	log("notice window caught: " .. tostring(name))
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
			if NOTICE_WINDOWS[name] then
				local okn, errn = pcall(catchNotice, id, name)
				if not okn then log("notice window " .. tostring(name) .. " not caught: " .. tostring(errn)) end
			end
			return id
		end
	end)
	if not ok then log("makeRecipeId not wrapped: " .. tostring(err)) end
end

-- The MPFever page: a page of the main menu like the game's « Load Game » (same frame, title bar, back button and
-- savegame tiles), opened by a « Multiplayer » card on the main page. Two tabs: host one of the player's savegames (its
-- tile's button opens the lobby), or join a host by its address. While something runs (lobby, connection, download,
-- loading) the page shows the session instead: the savegame's picture, what happens, the players, and its buttons.
local function setup()
	-- (the savegame folders, at once: MPFever.exe needs them to find the savegame the player hosts)
	pcall(noteSaveDirs, {})
	local react = ug_require("::/gui/main/react.lua")
	local builtin = ug_require("::/gui/main/builtin.lua")
	local menuUi = ug_require("::/gui/menu/menu_icon_react_util.tl")
	local tiles = ug_require("::/gui/main/tile_list_react_util.tl")   -- (rows of tiles)
	local guiUtil = ug_require("::/gui/main/gui_react_util.tl")
	local V = builtin.type.Orientation.Vertical
	local H = builtin.type.Orientation.Horizontal

	local PAGE_W, PAGE_H = 1630, 680   -- content of the page's card (the « Load Game » card is 1646 x 774)
	local SIDE_W = 960                 -- picture of the session view (16:9)
	local CHOICE_W = (PAGE_W - 60) / 2
	-- (0.5.13) the session view: its height, its right column, and the savegame's picture of a lobby with options (one company per
	-- player): smaller, the options beside it and the computer companies under it, all in view without scrolling
	local LOBBY_H = PAGE_H - 24
	local RIGHT_W = PAGE_W - SIDE_W - 40
	local PIC_W, PIC_H = 416, 234

	-- inline style: only what the game's style sheets do not give (sizes, paddings, colours)
	local function style(t)
		local s = api.gui.StyleSheet.new()
		local function v4(x) return api.type.Vec4f.new(x[1], x[2], x[3], x[4]) end
		-- (one property at a time: a value the UI refuses only loses that property, not the page)
		local function set(k, f) local ok, err = pcall(f); if not ok then log("style " .. k .. ": " .. tostring(err)) end end
		if t.size then set("size", function() s.size = api.type.Vec2f.new(t.size[1], t.size[2]) end) end
		if t.padding then set("padding", function() s.padding = v4(t.padding) end) end
		if t.color then set("color", function() s.color = v4(t.color) end) end
		if t.background then set("background", function() s.backgroundColor = v4(t.background) end) end
		if t.border then set("border", function() s.borderColor = v4(t.border) end) end
		if t.borderWidth then set("borderWidth", function() s.borderWidth = v4(t.borderWidth) end) end
		if t.background1 then set("background1", function() s.backgroundColor1 = v4(t.background1) end) end
		if t.image1 then
			set("image1", function()
				local n = api.gui.NinePatch.new()
				n.fileName = t.image1.fileName
				n.horizontal = t.image1.horizontal
				n.vertical = t.image1.vertical
				s.backgroundImage1 = n
			end)
		end
		return s
	end
	local function text(s, class, width)
		return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = s, width = width and math.floor(width) or nil }
	end
	-- (some of the game's icons are large pictures: always a fixed size)
	local function icon(path, size)
		size = size or 24
		return builtin.ImageView{ meta = { styleSheet = style{ size = { size, size } } }, path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
	end
	local function box(orientation, children, class, st)
		return builtin.Component{
			meta = { class = class, styleSheet = st and style(st) or nil },
			layout = builtin.BoxLayout{ orientation = orientation, children = children },
		}
	end
	local function gap(w, h) return builtin.Component{ meta = { styleSheet = style{ size = { w or 1, h or 1 } } } } end
	local function hfill() return guiUtil.makeHorizontalSpacer() end
	local function vfill() return guiUtil.makeVerticalSpacer() end
	-- game buttons: "primary" (filled, the main action) or "secondary" (outlined); an icon in front of the label
	local function button(label, onClick, opts)
		opts = opts or {}
		local content = {}
		if opts.icon then content[#content + 1] = icon(opts.icon); content[#content + 1] = gap(8, 1) end
		content[#content + 1] = text(label, opts.font or "font-scale-title-4")
		return builtin.Button{
			meta = {
				class = opts.primary and "primary" or "secondary",
				enabled = opts.enabled ~= false,
				tooltip = opts.tooltip,
				styleSheet = opts.size and style{ size = opts.size } or nil,
			},
			content = box(H, content),
			onClick = onClick,
		}
	end
	local function input(value, placeholder, onTyping, width)
		return builtin.TextInputField{
			meta = { class = "font-scale-title-4", styleSheet = style{ size = { width or 420, 34 } } },
			placeholderText = placeholder,
			value = value,
			onTyping = onTyping,
		}
	end
	local function sanitizeName(s)
		return (tostring(s or ""):gsub("[^%w_%-]", ""))
	end

	-- picture of a savegame (its screenshot), as the game's savegame cards read it
	local function saveId(s)
		local id = api.type.SavegameId.new()
		id.path = s.path
		id.saveGameName = s.saveName
		id.saveGameNamespace = app.SaveGameNamespace.getSavegame()
		return id
	end
	local SavePicture = react.RegisterRecipe("MPFeverSavePicture", function(sp)
		local imageRef = react.useRef(nil)
		local keyRef = react.useRef(nil)
		local key = sp.save and sp.save.saveName or ""
		if keyRef:get() ~= key then
			keyRef:set(key)
			local img
			if sp.save then
				local ok, i = pcall(app.getSavegameImage, saveId(sp.save))
				img = ok and i or nil
			end
			imageRef:set(img)
		end
		local img = imageRef:get()
		local view
		if img and img.image_native then
			view = builtin.ImageView{
				data_native = img.image_native,
				size = api.type.Vec2i.new(img.width, img.height),
				scaling = builtin.type.ImageViewScaling.AutoZoom,
			}
		else
			view = builtin.ImageView{ path = sp.fallback or "::/gui/menu/images/main.tga", scaling = builtin.type.ImageViewScaling.AutoZoom }
		end
		return builtin.BoxLayout{ children = { builtin.Component{ meta = { styleSheet = style{ size = sp.size } }, layout = builtin.BoxLayout{ children = { view } } } } }
	end)

	-- one savegame of the « Host » tab: a card like the game's savegame tiles (screenshot, name, date) with a « Host » button
	local TILE_W = math.floor((PAGE_W - 16 - 4 * 8) / 5) - 2   -- five per row, as on the « Load Game » page
	local CARD_SURFACE = { fileName = "::/gui/entity_window/design/card_surface.tga", horizontal = { 0, 6, 26, 32 }, vertical = { 0, 6, 26, 32 } }
	local SaveTile = react.RegisterRecipe("MPFeverSaveTile", function(tp)
		local asyncState = react.useState(nil)
		local dataState = react.useState(nil)
		if asyncState:old() == nil then
			local ok, a = pcall(app.getSavegameInfo, saveId(tp.save))
			asyncState:set(ok and a or false)
		end
		react.onStep(function()
			local a = asyncState:old()
			if a and dataState:old() == nil and a:isCompleted() then
				local d = a:get()
				local image, mods
				if d and d.info then
					pcall(function()
						local sh = d.info.metadata.screenshot
						image = { native = sh.image_native:clone(), w = sh.width, h = sh.height }
					end)
					mods = modsOf(d.info)
				end
				dataState:set({ image = image or false, mods = mods })
			end
		end)
		react.onUnmount(function()
			local a = asyncState:old()
			if a then pcall(function() a:abort() end) end
		end)
		local d = dataState:old()
		local picture
		if d and d.image then
			picture = builtin.ImageView{
				meta = { styleSheet = style{ size = { TILE_W - 8, 180 } } },
				data_native = d.image.native,
				size = api.type.Vec2i.new(d.image.w, d.image.h),
				scaling = builtin.type.ImageViewScaling.AutoZoom,
			}
		else
			picture = box(H, { hfill(), icon(d and "::/gui/menu/icons/alert.tga" or "::/gui/menu/icons/symbol_arrows_refresh.tga", 48), hfill() }, nil,
				{ size = { TILE_W - 8, 180 }, padding = { 66, 0, 66, 0 }, background = { 0, 0, 0, 0.35 } })
		end
		return builtin.BoxLayout{
			children = {
				box(V, {
					picture,
					gap(1, 6),
					box(H, { text(tp.save.saveName, "font-scale-title-4", TILE_W - 24) }, nil, { padding = { 0, 6, 0, 6 } }),
					box(H, {
						icon("::/gui/menu/icons/calendar.tga", 16),
						gap(6, 1),
						text(tp.save.timestamp and api.util.formatPosixTimestamp(tp.save.timestamp, api.type["enum"].DateFormat.MEDIUM) or "", "font-scale-body"),
					}, nil, { padding = { 2, 6, 0, 6 } }),
					gap(1, 8),
					button(T("Héberger", "Host"), function() tp.onHost(d and d.mods) end, { primary = true, enabled = tp.enabled, icon = "::/gui/menu/icons/menu_play.tga", size = { TILE_W - 8, 40 } }),
				}, nil, { size = { TILE_W, -1 }, padding = { 4, 4, 4, 4 }, image1 = CARD_SURFACE, background1 = { 0.16, 0.24, 0.32, 1 } }),
			},
		}
	end)

	-- a choice of the « Host » tab (company mode): a large button, filled when chosen
	local function choice(selected, title, description, onClick, enabled, warn)
		return builtin.Button{
			meta = {
				class = selected and "primary" or "secondary",
				enabled = enabled,
				styleSheet = style{ size = { CHOICE_W, -1 }, padding = { 10, 14, 10, 14 } },
			},
			content = box(V, {
				box(H, {
					icon(selected and "::/gui/menu/icons/symbol_check.tga" or "::/gui/menu/icons/symbol_star_outline.tga"),
					gap(10, 1),
					text(title, "font-scale-title-4"),
				}),
				gap(1, 4),
				text(description, warn and "font-scale-body, warning" or "font-scale-body", CHOICE_W - 40),
			}),
			onClick = onClick,
		}
	end

	-- (0.6) The game options (mpfever_feat.lua, docs/FEATURES-0.6.md): the options of the feature modules for the session's company
	-- mode, in the host's "Game settings" panel (each with its On / Off buttons and its text, and only while it is on, its
	-- parameters), and for the players a line of those on. MPFever.exe keeps the session's ("opts" of menu_state.txt, the options on
	-- "id=1;id.param=v;...") and takes the host's "opt" requests. Nothing shows while no module offers an option in the mode.
	-- MPFEVER_FEAT=0: nothing of it, the lobby of 0.5.14.
	local FEAT = nil
	if os.getenv("MPFEVER_FEAT") ~= "0" then
		pcall(function()
			local F = require("mpfever_1::/mpfever_feat.lua")
			if type(F) == "table" then F.load(log); FEAT = F end
		end)
	end
	-- the options this mode offers and the map of those on; nil when there is none to offer
	local function featView(st)
		if not FEAT then return nil end
		local okV, fv = pcall(function()
			local mode = st.cmode == "separate" and "separate" or "shared"
			local offered = FEAT.offered(mode)
			if #offered == 0 then return nil end
			return { mode = mode, offered = offered, map = FEAT.parse(FEAT.canon(st.opts or "", mode)) }
		end)
		if not okV then log("game options: " .. tostring(fv)) return nil end
		return fv
	end
	-- the section of the host's panel, as the rows of choices() (the label in a column of its own, then the buttons)
	-- (players: the lobby's players, the host first, for the parameters with one value per player: perPlayer)
	local function featSection(panel, w, fv, playerName, players)
		panel[#panel + 1] = gap(1, 12)
		panel[#panel + 1] = text(T("Options de partie (0.6)", "Game options (0.6)"), "font-scale-title-3", w)
		panel[#panel + 1] = text(T("Désactivées par défaut. Pour tous les joueurs ; gardées dans la sauvegarde.", "Off by default. For every player; kept in the savegame."), "font-scale-body", w)
		panel[#panel + 1] = gap(1, 8)
		for _, e in ipairs(fv.offered) do
			local id = e.opt.id
			local on = FEAT.on(fv.map, id)
			panel[#panel + 1] = box(H, {
				box(H, { text(FEAT.text(e.opt.title or id, T), "font-scale-title-4", 290) }, nil, { size = { 300, -1 } }),
				button(T("Activée", "On"), function() request("opt", id .. "=1", playerName()) end, { font = "font-scale-body", primary = on }),
				gap(4, 1),
				button(T("Désactivée", "Off"), function() request("opt", id .. "=0", playerName()) end, { font = "font-scale-body", primary = not on }),
			}, nil, { size = { w, -1 } })
			if e.opt.desc then panel[#panel + 1] = text(FEAT.text(e.opt.desc, T), "font-scale-body", w) end
			if on then
				for _, p in ipairs(e.params) do
					local cur = tostring(FEAT.param(fv.map, id, p.id))
					local row = { box(H, { text("      " .. FEAT.text(p.label or p.id, T), "font-scale-body", 290) }, nil, { size = { 300, -1 } }) }
					for _, v in ipairs(p.values) do
						local pick = tostring(v)
						row[#row + 1] = button(FEAT.showValue(p, v, T), function() request("opt", id .. "." .. p.id .. "=" .. pick, playerName()) end, { font = "font-scale-body", primary = cur == pick })
						row[#row + 1] = gap(4, 1)
					end
					panel[#panel + 1] = box(H, row, nil, { size = { w, -1 } })
					-- (0.6, perPlayer) one row per player but the host (its company, the savegame's, keeps its money): the player's own
					-- value, the parameter's while it has none (see FEAT.playerPid). MPFEVER_FEATPERPLAYER=0: the parameter's row only
					if p.perPlayer == true and FEAT.playerPid and os.getenv("MPFEVER_FEATPERPLAYER") ~= "0" then
						for i, name in ipairs(players or {}) do
							local base = name:gsub("%s*%(.*$", "")
							local ppid = i > 1 and FEAT.playerPid(p.id, base:lower()) or nil
							if ppid then
								local own = FEAT.param(fv.map, id, p.id .. "." .. base:lower())
								local pcur = tostring(own ~= nil and own or FEAT.param(fv.map, id, p.id))
								local prow = { box(H, { text("         " .. base, "font-scale-body", 290) }, nil, { size = { 300, -1 } }) }
								for _, v in ipairs(p.values) do
									local pick = tostring(v)
									prow[#prow + 1] = button(FEAT.showValue(p, v, T), function() request("opt", id .. "." .. ppid .. "=" .. pick, playerName()) end, { font = "font-scale-body", primary = pcur == pick })
									prow[#prow + 1] = gap(4, 1)
								end
								panel[#panel + 1] = box(H, prow, nil, { size = { w, -1 } })
							end
						end
					end
				end
			end
			panel[#panel + 1] = gap(1, 8)
		end
	end
	-- the players' line: the options on (and their parameters); nil when none is
	local function featSummary(fv)
		local names = {}
		for _, s in ipairs(FEAT.summary(fv.map, fv.mode, T)) do names[#names + 1] = s.title .. (#s.params > 0 and (" (" .. table.concat(s.params, ", ") .. ")") or "") end
		if #names == 0 then return nil end
		return T("Options de partie : ", "Game options: ") .. table.concat(names, "  ·  ")
	end
	-- (one company per player) the short line beside the picture: how many options are on (the box there has a fixed height, the
	-- whole list with their parameters overflowed it); nil when none is
	local function featCount(fv)
		local n = #FEAT.summary(fv.map, fv.mode, T)
		if n == 0 then return nil end
		return (T("Options de partie : %s activée(s)", "Game options: %s on"):gsub("%%s", tostring(n)))
	end

	-- (0.6) The page of the game options: in the lobby, a page of their own in place of the lobby (the host's "Game options (N on)"
	-- button, the players' "See the options"), the options as cards grouped by theme, two or three columns as the width allows. Each
	-- card: the option's icon, its title, its text, the host's On / Off buttons (a player reads whether it is on), and only while it
	-- is on, its parameters (the host's buttons, a player reads the values; a perPlayer one with one row per player but the host).
	-- Same requests as the settings panel. MPFEVER_LOBBYOPTSPAGE=0: no page, the options in the host's settings panel as before.
	local OPTSPAGE = os.getenv("MPFEVER_LOBBYOPTSPAGE") ~= "0"
	-- the icon of each option (the game's own pictures; a module may give its own: the option's field icon), others the settings one
	local FEAT_ICONS = {
		journal = "::/gui/menu/icons/news.tga",
		builtby = "::/gui/entity_window/icons/building_stations.tga",
		playerview = "::/gui/game_bar/icons/symbol_eye.tga",
		perms = "::/gui/builtin/window/icons/lock.tga",
		plans = "::/gui/game_bar/icons/infrastructure_tracks_30.tga",
		goal = "::/gui/menu/icons/symbol_crown_laurels.tga",
		stats = "::/gui/radial_menu/icons/symbol_chart_arrow_up_48.tga",
		yearly = "::/gui/radial_menu/icons/symbol_calendar_48.tga",
		market = "::/gui/statistics/icons/symbol_person_multiple.tga",
		territory = "::/gui/menu/icons/map_town.tga",
		handicap = "::/gui/menu/icons/earnings.tga",
		tenders = "::/gui/game_bar/icons/notifications.tga",
		sales = "::/gui/entity_window/icons/symbol_shopping_cart.tga",
		contracts = "::/gui/entity_window/icons/symbol_cargo.tga",
		stock = "::/gui/radial_menu/icons/symbol_coin_stack_48.tga",
		public = "::/gui/menu/icons/mod_management/mod-public.tga",
		join_bans = "::/gui/builtin/window/icons/cancel.tga",
		join_approve = "::/gui/menu/icons/symbol_check.tga",
		join_steamfriends = "::/gui/menu/icons/mod_management/platform_steam.tga",
	}
	local FEAT_ICON_OTHER = "::/gui/menu/icons/settings.tga"
	-- the width a button of the page takes (its label's characters at the body font, its margins): rows of values are cut to the card
	-- (the characters: the bytes that do not continue a UTF-8 character; no backslash in this file, see its top)
	local UTF8_START = "[^" .. string.char(128) .. "-" .. string.char(191) .. "]"
	local function featLabelW(s)
		local _, n = tostring(s):gsub(UTF8_START, "")
		return n * 7 + 26
	end
	-- buttons { label, on, pick } in rows that fit in the width w, one under the other
	local function featChoices(list, w)
		local rows, row, used = {}, {}, 0
		for _, c in ipairs(list) do
			local bw = featLabelW(c.label)
			if #row > 0 and used + bw > w then
				rows[#rows + 1] = box(H, row)
				rows[#rows + 1] = gap(1, 4)
				row, used = {}, 0
			end
			row[#row + 1] = button(c.label, c.pick, { font = "font-scale-body", primary = c.on })
			row[#row + 1] = gap(4, 1)
			used = used + bw + 4
		end
		if #row > 0 then rows[#rows + 1] = box(H, row) end
		return box(V, rows)
	end
	-- a parameter shows while the option's other parameters have the values its `when` asks (the game goal's tenders won: only for
	-- the tenders criterion), always without one
	local function featShown(p, map, id)
		if type(p.when) ~= "table" then return true end
		for k, v in pairs(p.when) do
			if tostring(FEAT.param(map, id, k)) ~= tostring(v) then return false end
		end
		return true
	end
	-- one option's card (o: host = the host's switches and buttons, else read only; playerName; players = the lobby's, the host first)
	local function featCard(e, fv, o, cardW)
		local id = e.opt.id
		local on = FEAT.on(fv.map, id)
		local inner = cardW - 24
		local head = { icon(type(e.opt.icon) == "string" and e.opt.icon or FEAT_ICONS[id] or FEAT_ICON_OTHER, 28), gap(10, 1) }
		if o.host then
			-- (room for the two buttons: « Désactivée » alone takes about 100 px; the title wraps when longer)
			head[#head + 1] = text(FEAT.text(e.opt.title or id, T), "font-scale-title-4", inner - 38 - 210)
			head[#head + 1] = hfill()
			head[#head + 1] = button(T("Activée", "On"), function() request("opt", id .. "=1", o.playerName()) end, { font = "font-scale-body", primary = on })
			head[#head + 1] = gap(4, 1)
			head[#head + 1] = button(T("Désactivée", "Off"), function() request("opt", id .. "=0", o.playerName()) end, { font = "font-scale-body", primary = not on })
		else
			head[#head + 1] = text(FEAT.text(e.opt.title or id, T), "font-scale-title-4", inner - 38 - 110)
			head[#head + 1] = hfill()
			head[#head + 1] = text(on and T("Activée", "On") or T("Désactivée", "Off"), on and "font-scale-title-4, success" or "font-scale-body")
		end
		local c = { box(H, head, nil, { size = { inner, -1 } }) }
		if e.opt.desc then
			c[#c + 1] = gap(1, 4)
			c[#c + 1] = text(FEAT.text(e.opt.desc, T), "font-scale-body", inner)
		end
		if on then
			local colon = FEAT.text({ " : ", ": " }, T)
			for _, p in ipairs(e.params) do
				if featShown(p, fv.map, id) then
					local label = FEAT.text(p.label or p.id, T)
					local cur = FEAT.param(fv.map, id, p.id)
					c[#c + 1] = gap(1, 8)
					if o.host then
						local list = {}
						for _, v in ipairs(p.values) do
							local pick = tostring(v)
							list[#list + 1] = { label = FEAT.showValue(p, v, T), on = tostring(cur) == pick,
								pick = function() request("opt", id .. "." .. p.id .. "=" .. pick, o.playerName()) end }
						end
						c[#c + 1] = text(label, "font-scale-title-4", inner)
						c[#c + 1] = gap(1, 4)
						c[#c + 1] = featChoices(list, inner)
					else
						c[#c + 1] = text(label .. colon .. FEAT.showValue(p, cur, T), "font-scale-body", inner)
					end
					-- (perPlayer) one row per player but the host (its company, the savegame's, keeps its money): the player's own value,
					-- the parameter's while it has none (see FEAT.playerPid). MPFEVER_FEATPERPLAYER=0: the parameter's row only
					if p.perPlayer == true and FEAT.playerPid and os.getenv("MPFEVER_FEATPERPLAYER") ~= "0" then
						for i, name in ipairs(o.players or {}) do
							local base = name:gsub("%s*%(.*$", "")
							local ppid = i > 1 and FEAT.playerPid(p.id, base:lower()) or nil
							if ppid then
								local own = FEAT.param(fv.map, id, p.id .. "." .. base:lower())
								local val = own ~= nil and own or cur
								c[#c + 1] = gap(1, 4)
								if o.host then
									local list = {}
									for _, v in ipairs(p.values) do
										local pick = tostring(v)
										list[#list + 1] = { label = FEAT.showValue(p, v, T), on = tostring(val) == pick,
											pick = function() request("opt", id .. "." .. ppid .. "=" .. pick, o.playerName()) end }
									end
									c[#c + 1] = box(H, {
										box(H, { text(base, "font-scale-body", 110) }, nil, { size = { 120, -1 } }),
										featChoices(list, inner - 120),
									})
								else
									c[#c + 1] = text("   " .. base .. colon .. FEAT.showValue(p, val, T), "font-scale-body", inner)
								end
							end
						end
					end
				end
			end
		end
		return box(V, c, nil, { size = { cardW, -1 }, padding = { 10, 12, 12, 12 }, image1 = CARD_SURFACE,
			background1 = on and { 0.17, 0.31, 0.43, 1 } or { 0.16, 0.24, 0.32, 1 } })
	end
	-- The page (w x h): its title and the « Back to the lobby » button (o.onBack), then the groups' cards in a scroll area. The options
	-- of the session's mode only (fv.offered); an option of no group (a later module's) under « Other ».
	local function featPage(fv, o)
		local w, h = o.width, o.height
		local GAP, CARD_MIN = 12, 440
		local cols = math.max(1, math.min(3, math.floor((w - 20 + GAP) / (CARD_MIN + GAP))))
		-- (a margin for the scroll bar and the cards' own padding: the third column was cut by the page's right edge)
		local cardW = math.floor((w - 60 - (cols - 1) * GAP) / cols)
		local groups = {
			{ title = T("Coopération", "Co-op"), ids = { "journal", "builtby", "playerview", "perms", "plans" } },
			{ title = T("Compétition", "Competition"), ids = { "goal", "stats", "yearly", "market", "territory", "handicap", "tenders" } },
			{ title = T("Économie entre joueurs", "Trade between players"), ids = { "sales", "contracts", "stock" } },
			{ title = T("Partie publique", "Public game"), ids = { "public" }, prefix = "join_" },
			{ title = T("Autres", "Other"), ids = {} },
		}
		-- each offered option in its group: the group's order first, then (join_*, others) the modules' order
		local byId = {}
		for _, e in ipairs(fv.offered) do byId[e.opt.id] = e end
		local placed = {}
		for _, g in ipairs(groups) do
			g.cards = {}
			for _, id in ipairs(g.ids) do
				if byId[id] and not placed[id] then placed[id] = true; g.cards[#g.cards + 1] = byId[id] end
			end
		end
		for _, e in ipairs(fv.offered) do
			local id = e.opt.id
			if not placed[id] then
				placed[id] = true
				local g = groups[#groups]
				for _, gg in ipairs(groups) do if gg.prefix and id:sub(1, #gg.prefix) == gg.prefix then g = gg end end
				g.cards[#g.cards + 1] = e
			end
		end
		local list = {}
		for _, g in ipairs(groups) do
			if #g.cards > 0 then
				if #list > 0 then list[#list + 1] = gap(1, 16) end
				list[#list + 1] = text(g.title, "font-scale-title-3", w - 40)
				list[#list + 1] = gap(1, 8)
				for r = 1, #g.cards, cols do
					local row = {}
					for k = r, math.min(r + cols - 1, #g.cards) do
						if k > r then row[#row + 1] = gap(GAP, 1) end
						-- (each card at the top of its row, whatever the height of the others)
						row[#row + 1] = box(V, { featCard(g.cards[k], fv, o, cardW), vfill() })
					end
					-- (a row of fewer cards than columns starts at the left, as the full ones: the missing cards' places stay empty)
					for _ = #g.cards - r + 2, cols do
						row[#row + 1] = gap(GAP, 1)
						row[#row + 1] = gap(cardW, 1)
					end
					if r > 1 then list[#list + 1] = gap(1, GAP) end
					list[#list + 1] = box(H, row, nil, { size = { w - 40, -1 } })
				end
			end
		end
		local n = #FEAT.summary(fv.map, fv.mode, T)
		local sub = o.host and T("Désactivées par défaut. Pour tous les joueurs ; gardées dans la sauvegarde.", "Off by default. For every player; kept in the savegame.")
			or T("Choisies par l'hôte, pour tous les joueurs.", "Chosen by the host, for every player.")
		local head = box(H, {
			icon(FEAT_ICON_OTHER, 32),
			gap(12, 1),
			box(V, {
				text(T("Options de partie", "Game options"), "font-scale-title-1"),
				text((featCount(fv) or (T("Options de partie : %s activée(s)", "Game options: %s on"):gsub("%%s", tostring(n)))) .. "   ·   " .. sub, "font-scale-body", w - 420),
			}),
			hfill(),
			button(T("Retour au salon", "Back to the lobby"), o.onBack, { primary = true, icon = "::/gui/menu/icons/back.tga" }),
		}, nil, { size = { w, -1 } })
		return box(V, {
			head,
			gap(1, 10),
			builtin.ScrollArea{
				meta = { styleSheet = style{ size = { w, h - 74 } } },
				content = box(V, list, nil, { size = { w - 20, -1 } }),
				horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
				verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
			},
		}, nil, { size = { w, h } })
	end

	-- the colour of the player's company (one company per player): a palette index, kept between sessions in the folder of every
	-- session (company_color.txt there) and given to this session (company_color.txt in the session folder, read by the
	-- bridge when the player announces itself; a colour another company already has gives the first free one)
	local PALETTE = nil
	pcall(function()
		local CO = require("mpfever_1::/mpfever_co.lua")
		if type(CO) == "table" and type(CO.PALETTE) == "table" then PALETTE = CO.PALETTE end
	end)
	PALETTE = PALETTE or {
		{ 0.86, 0.20, 0.20 }, { 0.20, 0.45, 0.90 }, { 0.20, 0.72, 0.30 }, { 0.98, 0.62, 0.10 },
		{ 0.62, 0.30, 0.82 }, { 0.10, 0.75, 0.80 }, { 0.95, 0.88, 0.15 }, { 0.95, 0.45, 0.70 },
		{ 0.55, 0.35, 0.18 }, { 0.55, 0.85, 0.15 }, { 0.15, 0.30, 0.55 }, { 0.62, 0.62, 0.62 },
	}
	local COLOR_KEPT = ".." .. BS .. "company_color.txt"
	local function readColor()
		local n = tonumber((readFile(COLOR_KEPT) or ""):match("%d+"))
		return (n and n >= 1 and n <= #PALETTE) and n or nil
	end
	local function writeColor(n)
		writeFile(COLOR_KEPT, tostring(n) .. NL)
		writeFile("company_color.txt", tostring(n) .. NL)
	end
	local function colorRow(current, onPick, note, compact, taken)
		local label = text(T("Couleur de votre entreprise", "Your company's colour") .. (compact and note and ("  " .. note) or ""), "font-scale-title-4")
		local items = compact and {} or { label, gap(12, 1) }
		local bw, bh = compact and 32 or 38, compact and 28 or 34
		for i, c in ipairs(PALETTE) do
			local sel = current == i
			local busyC = taken and taken[i]
			items[#items + 1] = builtin.Button{
				meta = { class = sel and "primary" or "secondary", enabled = not busyC,
					tooltip = busyC and T("Déjà prise par un autre joueur", "Already taken by another player") or nil,
					styleSheet = style{ size = { bw, bh }, padding = { 4, 4, 4, 4 } } },
				content = builtin.Component{ meta = { styleSheet = style{ size = { bw - (sel and 10 or 16), bh - (sel and 10 or 16) }, background = { c[1], c[2], c[3], busyC and 0.25 or 1 } } } },
				onClick = function() onPick(i) end,
			}
			items[#items + 1] = gap(4, 1)
		end
		if compact then return box(V, { label, gap(1, 4), box(H, items) }) end
		if note then items[#items + 1] = gap(12, 1); items[#items + 1] = text(note, "font-scale-body") end
		return box(H, items)
	end

	local busyPhase = function(phase) return phase ~= nil and phase ~= "" and phase ~= "idle" and phase ~= "error" end

	-- (0.6.3) A new multiplayer game without a savegame. The host's « New game » button (« Host » tab) writes newgame.txt (state
	-- "wait", the company mode and the player's name chosen on the tab) and opens the game's own New Game page: map, climate,
	-- settings and mods as for a game alone. When that page starts a game (app.startGame2; or app.loadGame of a saved map, the
	-- page's custom maps), the menu marks the file "started". The application script mpfever_auto.lua (newGameTick) then starts
	-- the loaded game, saves it as "MPFever <date>", marks the file "saved" and goes back to the main menu; there the main page
	-- (take, when it shows) opens the MPFever page and asks MPFever.exe to host that savegame, as its tile's « Host » button
	-- does: the lobby opens with it, the players join, the host starts the game for everybody. Back on the main page in any other
	-- state (the player left the New Game page, or loaded a savegame), the file is forgotten: only a game started from that page
	-- is saved and hosted. When the menu cannot watch the game's start (app's functions cannot be wrapped), the file says "any"
	-- and the next game loaded counts. MPFEVER_NEWGAME=0: no button, nothing of it.
	-- newgame.txt: "state TAB time TAB company mode TAB player name TAB savegame name" (see mpfever_auto.lua)
	local newGame = { on = os.getenv("MPFEVER_NEWGAME") ~= "0", file = "newgame.txt" }
	function newGame.read()
		local s = readFile(newGame.file) or ""
		local t = {}
		for v in (s:gsub("[" .. NL .. string.char(13) .. "]+$", "") .. TAB):gmatch("([^" .. TAB .. "]*)" .. TAB) do t[#t + 1] = v end
		if (t[1] or "") == "" then return nil end
		return { state = t[1], at = tonumber(t[2]) or 0, mode = t[3] or "", player = t[4] or "", save = t[5] or "" }
	end
	function newGame.write(m)
		writeFile(newGame.file, table.concat({ m.state, tostring(m.at), m.mode or "", m.player or "", m.save or "" }, TAB) .. NL)
	end
	-- the game's New Game page starts a game: the file asked for it says so (a map editor's start does not count)
	function newGame.started(editor)
		if editor then return end
		local m = newGame.read()
		if m and m.state == "wait" then
			m.state = "started"
			newGame.write(m)
			log("new game: started from the game's New Game page")
		end
	end
	-- app.startGame2 and app.loadGame (a saved map) watched once in this menu; false when they cannot be
	function newGame.watch()
		if newGame.watching ~= nil then return newGame.watching end
		local ok, err = pcall(function()
			local start, load = app.startGame2, app.loadGame
			assert(type(start) == "function" and type(load) == "function", "no app.startGame2 / app.loadGame")
			app.startGame2 = function(map, seed, date, tod, clouds, editor, ...)
				pcall(newGame.started, editor)
				return start(map, seed, date, tod, clouds, editor, ...)
			end
			app.loadGame = function(id, editor, ...)
				pcall(function()
					if id and id.saveGameNamespace == app.SaveGameNamespace.getSavemap() then newGame.started(editor) end
				end)
				return load(id, editor, ...)
			end
		end)
		newGame.watching = ok
		if not ok then log("new game: the game's start cannot be watched (" .. tostring(err) .. "): the next game loaded counts") end
		return ok
	end
	-- the « New game » button: the file, then the game's New Game page (commonParams: the menu's, to change its page)
	function newGame.ask(mode, player, commonParams)
		newGame.write({ state = newGame.watch() and "wait" or "any", at = os.time(), mode = mode, player = player })
		log("new game asked (" .. tostring(mode) .. "): the game's New Game page")
		local ok, err = pcall(function() commonParams.setPage("NewGame", { map = false }) end)
		if not ok then
			log("new game: the game's New Game page did not open: " .. tostring(err))
			writeFile(newGame.file, "")
			return false
		end
		return true
	end
	-- the main page shows: the new game saved, to host now (and the file emptied); nil else (any other state forgotten)
	function newGame.take()
		local m = newGame.read()
		if not m then return nil end
		writeFile(newGame.file, "")
		if m.state == "saved" and m.save ~= "" and os.time() - m.at <= 7200 then return m end
		log("new game: '" .. m.state .. "' forgotten (no game was started and saved from the game's New Game page)")
		return nil
	end
	-- host it: its mods for the players of the lobby, then the « host » request, as the savegame tiles' « Host » button
	function newGame.host(m)
		local mods
		pcall(function()
			for _, s in ipairs(listSaves()) do
				if s.saveName == m.save then
					local id = api.type.SavegameId.new()
					id.path = s.path
					id.saveGameName = s.saveName
					id.saveGameNamespace = app.SaveGameNamespace.getSavegame()
					local a = app.getSavegameInfo(id)
					local d = a and a:get()
					if d and d.info then mods = modsOf(d.info) end
				end
			end
		end)
		writeFile("host_mods.txt", encodeMods(mods))
		log("new game '" .. m.save .. "': hosted (" .. #(mods or {}) .. " mods)")
		request("host", m.save, m.player, m.mode)
	end

	-- (0.6.3) The left column of a lobby with one company per player, in sections. Up to 0.6.2 it all followed in one small
	-- scroll area: beside the picture the colour, the rules' line and two buttons; under it, once the host opened its settings,
	-- a panel of the rules and of the computer companies' start money, then the computer companies again (level, colour), then
	-- the mods. The settings of a computer company were in two places, the labels of every width, a line could be cut at the
	-- edge (« fouillis », said the players). Now: the picture with the player's colour and a short view of the game beside it
	-- (rules, number of game options on), then a row of tabs (Rules, Computers, Game options, Mods) and the chosen one under it,
	-- in a scroll area of its own. Each section is a table: the labels in a column of one width (LOBBY_LABEL_W), the value or the
	-- host's buttons beside, each text wrapped to its column. The players see the same, read only. Same requests as before.
	-- MPFEVER_LOBBYOLD=1: the lobby of 0.6.2.
	local LOBBYOLD = os.getenv("MPFEVER_LOBBYOLD") == "1"
	local LOBBY_LABEL_W, LOBBY_TABS_H = 270, 40
	-- c: host, st, ais, players, mine, taken, pickColor, playerName, lobbySave, modsBox, mods = { n, blocking }, modsFirst, rules =
	-- { start, share, months, fmt, summary }, section (the tab chosen; nil: Rules, or Mods for a player who lacks some), setSection,
	-- openOpts (opens the page of the game options). Returns the column's children.
	local function lobbyColumn(c)
		local w = SIDE_W - 24
		local r = c.rules
		local fv = featView(c.st)
		local LEVELS = { T("Facile", "Easy"), T("Normal", "Normal"), T("Difficile", "Hard") }
		local function aiMoney(v) return v < 0 and T("Comme les joueurs", "As the players") or r.fmt(v) end
		local function aiName(a) return a.name ~= "" and a.name or (T("Ordinateur %s", "Computer %s"):gsub("%%s", tostring(a.n))) end
		-- a row of a section (rw wide): the label in its column, then the value (a text, or the host's buttons) and a note under it
		local function row(label, value, note, rw)
			rw = rw or w
			local right = { value }
			if note then right[#right + 1] = gap(1, 4); right[#right + 1] = text(note, "font-scale-body", rw - LOBBY_LABEL_W) end
			return box(H, {
				box(V, { text(label, "font-scale-title-4", LOBBY_LABEL_W - 16) }, nil, { size = { LOBBY_LABEL_W, -1 } }),
				box(V, right, nil, { size = { rw - LOBBY_LABEL_W, -1 } }),
			}, nil, { size = { rw, -1 } })
		end
		-- the host's buttons of one setting (rows that fit in the value's column), the current value lit
		local function picks(values, cur, show, send, rw)
			local list = {}
			for _, v in ipairs(values) do
				local pick = v
				list[#list + 1] = { label = show(v), on = cur == v, pick = function() send(pick) end }
			end
			return featChoices(list, (rw or w) - LOBBY_LABEL_W)
		end
		local function value(s, rw) return text(s, "font-scale-title-4", (rw or w) - LOBBY_LABEL_W) end
		local sections = {}
		sections.rules = function()
			local s = {
				text(T("Règles de la partie", "Game rules"), "font-scale-title-3", w),
				text(c.host and T("Pour tous les joueurs ; gardés dans la sauvegarde.", "For every player; kept in the savegame.")
					or T("Choisies par l'hôte, pour tous les joueurs.", "Chosen by the host, for every player."), "font-scale-body", w),
				gap(1, 12),
			}
			local months = function(m) return m == 0 and T("Jamais", "Never") or (T("%s mois", "%s months"):gsub("%%s", tostring(m))) end
			local onOff = function(v) return v == 1 and T("Activées", "On") or T("Désactivées", "Off") end
			local startLabel = T("Argent de départ d'une entreprise :", "Start money of a company:")
			local startNote = T("Celui de chaque nouvelle entreprise : un joueur qui arrive, une entreprise repartie après une faillite, et celle de l'hôte au début d'une nouvelle partie.",
				"That of every new company: a player who arrives, a company started again after a bankruptcy, and the host's at the start of a new game.")
			local shareLabel = T("Règles de partage :", "Sharing rules:")
			local shareNote = r.share and T("Chaque entreprise décide si ses voies, gares, arrêts et dépôts sont privés, ouverts ou payants.", "Each company decides whether its tracks, stations, stops and depots are private, open or paying.")
				or T("Tout est ouvert et gratuit pour toutes les entreprises : voies, gares, arrêts et dépôts.", "Everything is open and free for every company: tracks, stations, stops and depots.")
			local bankLabel = T("Faillite d'une entreprise endettée après :", "A company in debt goes bankrupt after:")
			local auLabel = T("Vente aux enchères d'une faillite :", "Auction of a bankruptcy:")
			local auMinLabel = T("Durée de la vente :", "Length of the sale:")
			local auCur = (r.auMode == "company") and "company" or "assets"
			local function auShow(v) return v == "company" and T("L'entreprise entière", "The whole company") or T("Les actifs, tous en même temps", "The assets, all at once") end
			local function minShow(v) return (T("%s min", "%s min"):gsub("%%s", tostring(v))) end
			local auNote = auCur == "company"
				and T("Une seule vente : tout ce que possédait l'entreprise (lignes, véhicules, gares, dépôts, voies, routes) au plus offrant.", "One sale: everything the company owned (lines, vehicles, stations, depots, tracks, roads) to the best bidder.")
				or T("Chaque ligne (avec ses véhicules), chaque gare et chaque dépôt en vente en même temps, chacun son prix, un seul compte à rebours.", "Each line (with its vehicles), each station and each depot for sale at once, each with its own price, one clock for all.")
			if c.host then
				s[#s + 1] = row(startLabel, picks({ 0, 500000, 1000000, 2000000, 5000000, 10000000, 20000000 }, r.start, r.fmt,
					function(v) request("startmoney", tostring(v), c.playerName()) end), startNote)
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(shareLabel, picks({ 1, 0 }, r.share and 1 or 0, onOff, function(v) request("share", tostring(v), c.playerName()) end), shareNote)
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(bankLabel, picks({ 0, 3, 6, 12, 24 }, r.months, months, function(m) request("bankrupt", tostring(m), c.playerName()) end))
				-- (0.7.4) the auction of a bankrupt company: its lots all at once, or the whole company in one lot; how long it lasts
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(auLabel, picks({ "assets", "company" }, auCur, auShow, function(v) request("auction", v .. ":" .. tostring(r.auMin or 5), c.playerName()) end), auNote)
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(auMinLabel, picks({ 3, 5, 10 }, r.auMin or 5, minShow, function(v) request("auction", auCur .. ":" .. tostring(v), c.playerName()) end))
			else
				s[#s + 1] = row(startLabel, value(r.fmt(r.start)), startNote)
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(shareLabel, value(onOff(r.share and 1 or 0)), shareNote)
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(bankLabel, value(months(r.months)))
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(auLabel, value(auShow(auCur)), auNote)
				s[#s + 1] = gap(1, 12)
				s[#s + 1] = row(auMinLabel, value(minShow(r.auMin or 5)))
			end
			return s
		end
		-- the computer companies: each in a frame of its own, its name, then (the host) its level, colour and start money as rows
		sections.ai = function()
			local head = { text(T("Entreprises de l'ordinateur (expérimental)", "Computer companies (experimental)"), "font-scale-title-3", w - 340), hfill() }
			if c.host and #c.ais < 8 then
				head[#head + 1] = button(T("Ajouter une entreprise de l'ordinateur", "Add a computer company"), function() request("aiadd", "", c.playerName()) end, { font = "font-scale-body" })
			end
			local s = {
				box(H, head, nil, { size = { w, -1 } }),
				text(T("Gérées par le jeu de l'hôte : bus, camions de marchandises et livraisons des villes. Plus le niveau est élevé, plus elles grandissent vite.", "Run by the host's game: buses, freight trucks and deliveries to the towns. The higher the level, the faster they grow."), "font-scale-body", w),
			}
			local iw = w - 16
			for i, a in ipairs(c.ais) do
				local n = a.n
				local pc = PALETTE[a.ix]
				local top = {
					pc and builtin.Component{ meta = { styleSheet = style{ size = { 22, 22 }, background = { pc[1], pc[2], pc[3], 1 } } } } or icon("::/gui/menu/icons/profile.tga"),
					gap(10, 1),
					text(aiName(a), "font-scale-title-4", iw - 90),
					hfill(),
				}
				if c.host then
					top[#top + 1] = builtin.Button{
						meta = { class = "secondary", tooltip = T("Retirer", "Remove"), styleSheet = style{ size = { 34, 30 }, padding = { 5, 5, 5, 5 } } },
						content = icon("::/gui/menu/icons/symbol_x.tga", 20),
						onClick = function() request("aidel", tostring(n), c.playerName()) end,
					}
				end
				local rows = { box(H, top, nil, { size = { iw, -1 } }) }
				if c.host then
					rows[#rows + 1] = gap(1, 6)
					rows[#rows + 1] = row(T("Niveau : ", "Level: "), picks({ 1, 2, 3 }, a.lv, function(lv) return LEVELS[lv] end,
						function(lv) request("ailevel", tostring(n) .. ":" .. tostring(lv), c.playerName()) end, iw), nil, iw)
					-- (its colour; those of the players and of the other computer companies greyed)
					local sw = {}
					for ix, col in ipairs(PALETTE) do
						local sel = a.ix == ix
						local busyC = c.taken[ix] and not sel
						local pickC = ix
						sw[#sw + 1] = builtin.Button{
							meta = { class = sel and "primary" or "secondary", enabled = not busyC, styleSheet = style{ size = { 28, 26 }, padding = { 3, 3, 3, 3 } } },
							content = builtin.Component{ meta = { styleSheet = style{ size = { sel and 20 or 14, sel and 18 or 12 }, background = { col[1], col[2], col[3], busyC and 0.25 or 1 } } } },
							onClick = function() request("aicolor", tostring(n) .. ":" .. tostring(pickC), c.playerName()) end,
						}
						sw[#sw + 1] = gap(3, 1)
					end
					rows[#rows + 1] = gap(1, 4)
					rows[#rows + 1] = row(T("Couleur", "Colour"), box(H, sw), nil, iw)
					rows[#rows + 1] = gap(1, 4)
					rows[#rows + 1] = row(T("Argent de départ", "Start money"), picks({ -1, 1000000, 2000000, 5000000, 10000000, 20000000 }, a.money, aiMoney,
						function(v) request("aimoney", tostring(n) .. ":" .. tostring(v), c.playerName()) end, iw), nil, iw)
				else
					rows[#rows + 1] = text(T("Niveau : ", "Level: ") .. (LEVELS[a.lv] or LEVELS[2]) .. "   ·   " .. (T("Départ : %s", "Start: %s"):gsub("%%s", (aiMoney(a.money):gsub("%%", "%%%%")))), "font-scale-body", iw)
				end
				s[#s + 1] = gap(1, 8)
				s[#s + 1] = box(V, rows, nil, { padding = { 8, 8, 8, 8 }, background = { 1, 1, 1, i % 2 == 1 and 0.06 or 0.03 }, size = { w, -1 } })
			end
			return s
		end
		-- the game options: how many are on, the button of their page, then those on, one row each with their parameters
		sections.opts = function()
			local on = FEAT.summary(fv.map, fv.mode, T)
			local s = {
				text(T("Options de partie", "Game options"), "font-scale-title-3", w),
				text((featCount(fv) or T("Aucune option de partie activée.", "No game option on.")) .. "   ·   " .. (c.host and T("Désactivées par défaut. Pour tous les joueurs ; gardées dans la sauvegarde.", "Off by default. For every player; kept in the savegame.")
					or T("Choisies par l'hôte, pour tous les joueurs.", "Chosen by the host, for every player.")), "font-scale-body", w),
				gap(1, 10),
			}
			-- (MPFEVER_LOBBYOPTSPAGE=0, no page: the host's switches here, as in its settings panel of 0.6.2)
			if not OPTSPAGE and c.host then
				featSection(s, w, fv, c.playerName, c.players)
				return s
			end
			if OPTSPAGE then
				s[#s + 1] = button(c.host and (T("Options de partie (%s activées)", "Game options (%s on)"):gsub("%%s", tostring(#on))) or T("Voir les options", "See the options"),
					c.openOpts, { font = "font-scale-body", primary = c.host, icon = "::/gui/menu/icons/settings.tga" })
				s[#s + 1] = gap(1, 10)
			end
			for _, o in ipairs(on) do
				s[#s + 1] = row(o.title, text(#o.params > 0 and table.concat(o.params, "   ·   ") or T("Activée", "On"), "font-scale-body", w - LOBBY_LABEL_W))
				s[#s + 1] = gap(1, 6)
			end
			return s
		end
		sections.mods = function() return { c.modsBox } end

		-- the tabs: Rules always, Computers for the host or when there are some, Game options when the mode offers some, Mods when
		-- the savegame has some (with the alert icon when some are to fix)
		local tabs = { { id = "rules", label = T("Règles", "Rules") } }
		if c.host or #c.ais > 0 then tabs[#tabs + 1] = { id = "ai", label = T("Ordinateurs", "Computers") .. " (" .. #c.ais .. ")" } end
		if fv then tabs[#tabs + 1] = { id = "opts", label = T("Options de partie", "Game options") .. " (" .. #FEAT.summary(fv.map, fv.mode, T) .. ")" } end
		if c.modsBox then tabs[#tabs + 1] = { id = "mods", label = T("Mods", "Mods") .. " (" .. tostring(c.mods and c.mods.n or 0) .. ")", alert = c.mods and c.mods.blocking > 0 } end
		local cur = c.section
		local found = false
		for _, tb in ipairs(tabs) do if tb.id == cur then found = true end end
		if not found then cur = (c.modsFirst and c.modsBox) and "mods" or "rules" end
		local tabRow = {}
		for i, tb in ipairs(tabs) do
			if i > 1 then tabRow[#tabRow + 1] = gap(6, 1) end
			local id = tb.id
			tabRow[#tabRow + 1] = button(tb.label, function() c.setSection(id) end, { primary = cur == id, font = "font-scale-title-4", icon = tb.alert and "::/gui/menu/icons/alert.tga" or nil })
		end

		-- beside the picture: the player's colour, the rules in one line, the number of game options on
		local sw = SIDE_W - PIC_W - 32
		local side = {
			colorRow(c.mine, c.pickColor, nil, true, c.taken),
			gap(1, 14),
			text(T("Règles de la partie", "Game rules"), "font-scale-title-4", sw),
			text(r.summary, "font-scale-body", sw),
		}
		local fc = fv and featCount(fv)
		if fc then side[#side + 1] = text(fc, "font-scale-body", sw) end
		return {
			box(H, {
				SavePicture{ save = c.lobbySave, size = { PIC_W, PIC_H }, fallback = "::/gui/menu/images/main.tga" },
				gap(16, 1),
				box(V, side, nil, { size = { SIDE_W - PIC_W - 16, PIC_H } }),
			}),
			gap(1, 12),
			box(H, tabRow, nil, { size = { SIDE_W, LOBBY_TABS_H } }),
			gap(1, 8),
			builtin.ScrollArea{
				meta = { styleSheet = style{ size = { SIDE_W, LOBBY_H - PIC_H - 12 - LOBBY_TABS_H - 8 } } },
				content = box(V, sections[cur](), nil, { size = { SIDE_W - 20, -1 } }),
				horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
				verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
			},
		}
	end

	local MPFeverPage = react.RegisterRecipe("MPFeverPage", function(pp)
		local st0 = readState()
		-- The page opens from the main menu only: a session still "in game" (or hosting) is the one the player left by going back
		-- to the main menu. MPFever.exe ends it, and the page offers to host or join again.
		-- (only when the page opens: once open, "hosting" is the session the player just started from it)
		local opened = react.useState(false)
		local left = react.useState(false)
		if not opened:old() then
			opened:set(true)
			if st0.phase == "ingame" or st0.phase == "hosting" then
				left:set(true)
				request("leave", "", st0.name or "")
				st0.phase = "idle"
				st0.text = ""
			end
		end
		local tab = react.useState("host")
		local saves = react.useStateLazy(listSaves)
		local filter = react.useState("")
		local showResync = react.useState(os.getenv("MPFEVER_MENU_RESYNC") == "1")
		local defaultName = st0.name
		if not defaultName or defaultName == "" then
			local ok, n = pcall(function() return app.getUserProfile():getUserName() end)
			defaultName = ok and sanitizeName(n) or ""
		end
		local name = react.useState(defaultName)
		local companies = react.useState("shared")     -- hosting: everybody plays one company, or each player has its own
		local coColor = react.useStateLazy(function()
			local n = readColor()
			if n then writeFile("company_color.txt", tostring(n) .. NL) end
			return n
		end)
		-- (in the lobby: MPFever.exe keeps it when no other player has it; the lobby's list then says it, see below)
		local function pickColor(i)
			coColor:set(i)
			request("color", tostring(i))
			log("company colour " .. i .. " asked")
		end
		local colorAsked = react.useRef(false)
		local addr = react.useState(st0.addr or "")
		local password = react.useState("")            -- joining: the password of a dedicated server (none: empty)
		local state = react.useState(st0)
		-- (the host's lobby, one company per player: the game's rules shown, 0.5.14; MPFEVER_MENU_RULES=1: shown at first, tests)
		local rulesOpen = react.useState(os.getenv("MPFEVER_MENU_RULES") == "1")
		-- (0.6, the lobby's page of the game options shown in place of the lobby; MPFEVER_MENU_OPTSPAGE=1: shown at first, tests and
		-- screenshots. Closed when the lobby ends: the next lobby opens on the lobby itself)
		local optsPage = react.useState(os.getenv("MPFEVER_MENU_OPTSPAGE") == "1")
		-- (0.6.3, the lobby's tab chosen, see lobbyColumn; nil: its first. Forgotten when the lobby ends, as the page of the options)
		local section = react.useState(nil)
		local wasLobby = react.useRef(false)
		-- (0.6, the host's public game) its name as the host types it, nil while it shows the name MPFever.exe has
		local pubEdit = react.useState(nil)
		local leaving = react.useRef(false)
		-- (the host's savegame, once received, is loaded by the application script mpfever_auto.lua)
		react.onStepTimer(function()
			local s = readState()
			if s.lang and s.lang ~= "" and s.lang ~= LANGCODE then loadLang() end
			-- (the end of the left session is on its way: not a reason to leave the page)
			if left:old() then
				if s.phase == "ingame" or s.phase == "hosting" then s.phase = "idle"; s.text = ""
				else left:set(false) end
			end
			state:set(s)
			local inLobby = s.lobby == "host" or s.lobby == "client"
			if wasLobby:get() and not inLobby and optsPage:old() then optsPage:set(false) end
			if wasLobby:get() and not inLobby and section:old() ~= nil then section:set(nil) end
			wasLobby:set(inLobby)
			-- the game is about to load (the host's own, or the host's game received by a player who joins) or is loaded: the
			-- page has done its job, the main menu shows its main page again while the game loads
			if s.phase == "hosting" or s.phase == "loading" or s.phase == "ingame" then
				if not leaving:get() then
					leaving:set(true)
					log("phase " .. tostring(s.phase) .. ": back to the main page")
					local ok, err = pcall(pp.back)
					if not ok then log("leaving the page failed: " .. tostring(err)) end
				end
			else
				leaving:set(false)
			end
		end, 0.5)

		local st = state:old()
		local busy = busyPhase(st.phase)
		local playerName = function() return sanitizeName(name:old()) end
		-- (0.6) the button of the page of the game options: the host's with the number of options on, a player's to read them
		local function optsButton(fv)
			local label = st.lobby == "host" and (T("Options de partie (%s activées)", "Game options (%s on)"):gsub("%%s", tostring(#FEAT.summary(fv.map, fv.mode, T))))
				or T("Voir les options", "See the options")
			return button(label, function() optsPage:set(true) end, { font = "font-scale-body", icon = "::/gui/menu/icons/settings.tga" })
		end

		-- header: the two tabs, then the player's name ------------------------------------------------------------
		local function tabButton(id, label, iconPath)
			-- (the public servers' tab asks MPFever.exe to read the list again at once)
			return button(label, function() tab:set(id); if id == "servers" then request("servers") end end, { primary = tab:old() == id, enabled = not busy, icon = iconPath, font = "font-scale-title-3" })
		end
		local header = {
			tabButton("host", T("Héberger une partie", "Host a game"), "::/gui/menu/icons/list.tga"),
			gap(8, 1),
			tabButton("join", T("Rejoindre une partie", "Join a game"), "::/gui/menu/icons/start_mission.tga"),
		}
		-- (a third tab when MPFever.exe knows a public server list, see its ServerList.cs)
		if st.serversOn == "1" then
			header[#header + 1] = gap(8, 1)
			header[#header + 1] = tabButton("servers", T("Serveurs publics", "Public servers"), "::/gui/menu/icons/list.tga")
		end
		for _, c in ipairs({
			hfill(),
			icon("::/gui/menu/icons/profile.tga"),
			gap(8, 1),
			text(T("Pseudo", "Player name"), "font-scale-title-4"),
			gap(12, 1),
			input(name:old(), T("Votre pseudo", "Your name"), function(v) name:set(v) end, 320),
		}) do header[#header + 1] = c end

		local body = {}
		local hasError = st.phase == "error" and st.text and st.text ~= ""
		-- the last error (cannot host, cannot connect, lobby closed...), above the tab
		if hasError then
			body[#body + 1] = box(H, {
				icon("::/gui/menu/icons/alert.tga"),
				gap(10, 1),
				text(st.text, "font-scale-title-4", PAGE_W - 80),
			}, "error-tape", { padding = { 8, 12, 8, 12 } })
			body[#body + 1] = gap(1, 8)
		end

		if busy then
			-- the session view ----------------------------------------------------------------------------------------
			local isHost = st.lobby == "host"
			local titles = {
				lobby = isHost and T("Salon ouvert", "Lobby open") or T("Dans le salon", "In the lobby"),
				connecting = T("Connexion à l'hôte...", "Connecting to the host..."),
				connected = T("Connecté à l'hôte", "Connected to the host"),
				-- (0.7.0) a game already running: its mods and DLCs first, then « Join the game »
				review = T("Avant de rejoindre la partie", "Before joining the game"),
				downloading = T("Réception de la partie", "Receiving the game"),
				loading = T("Chargement de la partie", "Loading the game"),
				hosting = T("En partie", "In game"),
				ingame = T("En partie", "In game"),
			}
			local lobbySave
			if isHost and st.lobbySave then
				for _, s in ipairs(saves:old()) do if s.saveName == st.lobbySave then lobbySave = s end end
			end
			local right = {}
			-- (one company per player) beside the smaller picture: the company colour, the host's bankruptcy rule; under it: the
			-- computer companies (the mods list joins them)
			local side, below = {}, {}
			right[#right + 1] = text(titles[st.phase] or T("Multijoueur", "Multiplayer"), "font-scale-title-1")
			if isHost and st.lobbySave and st.lobbySave ~= "" then
				right[#right + 1] = text(st.lobbySave, "font-scale-title-3")
			end
			right[#right + 1] = gap(1, 12)
			if st.text and st.text ~= "" then right[#right + 1] = text(st.text, "font-scale-title-4", PAGE_W - SIDE_W - 60) end
			-- the host's lobby: the addresses to give to the other players (public: looked up by MPFever.exe, "..." meanwhile,
			-- "?" when unknown)
			-- (0.6.8, #115) a savegame played with one company per player, hosted with one company for everybody
			if isHost and st.saveSeparate == "1" then
				right[#right + 1] = gap(1, 10)
				right[#right + 1] = box(V, {
					text(T("Cette sauvegarde a été jouée avec une entreprise par joueur : ici, les entreprises des autres joueurs ne servent pas. Pour les retrouver, annulez et choisissez « Une entreprise par joueur » avant la sauvegarde.",
						"This savegame was played with one company per player: here the other players' companies are not used. To get them back, cancel and choose 'One company per player' before the savegame."), "font-scale-body, warning", PAGE_W - SIDE_W - 84),
				}, nil, { padding = { 8, 12, 8, 12 }, background = { 0.6, 0.45, 0.1, 0.25 }, size = { PAGE_W - SIDE_W - 60, -1 } })
			end
			-- (0.6.9) players whose DLCs are not the host's (the Deluxe pack's animals, people and vehicles are in one world only)
			if st.dlcWarn and st.dlcWarn ~= "" then
				right[#right + 1] = gap(1, 10)
				right[#right + 1] = box(V, {
					text(st.dlcWarn, "font-scale-body, warning", PAGE_W - SIDE_W - 84),
				}, nil, { padding = { 8, 12, 8, 12 }, background = { 0.6, 0.15, 0.1, 0.3 }, size = { PAGE_W - SIDE_W - 60, -1 } })
			end
			-- (0.7.0, a player) the DLCs of the host's game and of this PC, each with what to do: one the host's game uses and this
			-- PC lacks has its Steam page (MPFever.exe opens it, request dlcstore); from MPFever.exe's dlcList "id|name|state|store;..."
			if not isHost and (st.dlcList or "") ~= "" then
				local w = PAGE_W - SIDE_W - 60
				local rows = { text(T("DLC de la partie", "The game's DLCs"), "font-scale-title-4", w - 24), gap(1, 4) }
				for e in st.dlcList:gmatch("[^;]+") do
					local id, nm, state = e:match("^([^|]*)|([^|]*)|([^|]*)")
					if id and id ~= "" then
						local dlcId = id
						local line = state == "both" and T("vous l'avez aussi", "you have it too")
							or state == "host" and T("la partie de l'hôte l'utilise, vous ne l'avez pas", "the host's game uses it, you do not have it")
							or T("vous l'avez, la partie de l'hôte ne l'utilise pas", "you have it, the host's game does not use it")
						local row = { text(nm .. " : " .. line, state == "both" and "font-scale-body, success" or "font-scale-body, warning", w - 220), hfill() }
						if state == "host" then
							row[#row + 1] = button(T("Page Steam", "Steam page"), function() request("dlcstore", dlcId, playerName()) end,
								{ font = "font-scale-body", icon = "::/gui/menu/icons/mod_management/platform_steam.tga" })
						end
						rows[#rows + 1] = box(H, row, nil, { size = { w - 24, -1 } })
					end
				end
				right[#right + 1] = gap(1, 8)
				right[#right + 1] = box(V, rows, nil, { padding = { 8, 12, 8, 12 }, background = { 1, 1, 1, 0.07 }, size = { w, -1 } })
			end
			if isHost and st.publicAddr and st.publicAddr ~= "" then
				local w = PAGE_W - SIDE_W - 60
				local pub = st.publicAddr
				local addrRows = {
					text(T("Adresse à donner aux autres joueurs (Internet)", "Address to give to the other players (Internet)"), "font-scale-body"),
					gap(1, 4),
				}
				if pub == "..." then
					addrRows[#addrRows + 1] = text(T("Recherche de votre adresse publique...", "Looking up your public address..."), "font-scale-title-3")
				elseif pub == "?" then
					addrRows[#addrRows + 1] = text(T("Adresse publique introuvable : cherchez « mon adresse IP » sur Internet.", "Public address unknown: search « what is my IP » on the Internet."), "font-scale-title-4, warning", w - 24)
				else
					-- (one address a line: an IPv6 one, long, in a smaller font, never cut in the middle)
					for a in pub:gmatch("[^,]+") do
						a = a:gsub("^%s+", ""):gsub("%s+$", "")
						if a ~= "" then addrRows[#addrRows + 1] = text(a, a:find("[", 1, true) and "font-scale-title-4" or "font-scale-title-2", w - 24) end
					end
				end
				if st.port and st.port ~= "" then
					addrRows[#addrRows + 1] = gap(1, 4)
					addrRows[#addrRows + 1] = text((T("Le port TCP %s doit être redirigé vers ce PC sur votre box.", "TCP port %s must be forwarded to this PC on your router."):gsub("%%s", function() return st.port end)), "font-scale-body, warning", w - 24)
				end
				if st.localAddr and st.localAddr ~= "" then
					addrRows[#addrRows + 1] = gap(1, 8)
					addrRows[#addrRows + 1] = text(T("Même réseau local : ", "Same local network: ") .. st.localAddr, "font-scale-body", w - 24)
				end
				right[#right + 1] = gap(1, 10)
				right[#right + 1] = box(V, addrRows, nil, { padding = { 10, 12, 10, 12 }, background = { 1, 1, 1, 0.07 }, size = { w, -1 } })
			end
			-- (0.6, public games) the host's lobby in the public list: its state there, the game's name (the host may change it), a
			-- warning when the host shows its IP address or everybody plays one company; then the arrivals waiting for the host's
			-- answer. From MPFever.exe's menu_state (pub, pubName, pubIp, pending; launcher/PublicGames.cs): nothing while the
			-- game options public and join_approve are off.
			if isHost and ((st.pub or "") ~= "" and st.pub ~= "ended" or (st.pending or "") ~= "") then
				local w = PAGE_W - SIDE_W - 60
				local p = st.pub or ""
				if p ~= "" and p ~= "ended" then
					local msg = p == "listed" and T("Votre salon est dans la liste publique.", "Your lobby is in the public list.")
						or p == "wait" and T("Partie publique : envoi à la liste publique...", "Public game: sending to the public list...")
						or p == "!old" and T("La liste publique ne prend pas encore les parties de joueurs : vos amis peuvent toujours rejoindre par Steam ou par l'adresse.",
							"The public list does not take players' games yet: your friends can still join through Steam or by the address.")
						or p == "!off" and T("Aucune liste publique n'est utilisée ici (serverlist= dans mpfever_settings.txt) : la partie n'y apparaît pas.",
							"No public list is used here (serverlist= in mpfever_settings.txt): the game does not show in it.")
						or p == "!steam" and T("Steam n'est pas encore prêt : la partie apparaîtra dans la liste dès qu'il le sera.", "Steam is not ready yet: the game will show in the list as soon as it is.")
						or (T("La liste publique ne répond pas : vos amis peuvent toujours rejoindre par Steam ou par l'adresse.", "The public list does not answer: your friends can still join through Steam or by the address.")
							.. (p ~= "!down" and (" (" .. p:sub(2) .. ")") or ""))
					local rows = {
						text(msg, p == "listed" and "font-scale-body, success" or (p:sub(1, 1) == "!" and "font-scale-body, warning" or "font-scale-body"), w - 24),
						gap(1, 6),
						text(T("Nom de la partie", "Game name"), "font-scale-body"),
						gap(1, 4),
						box(H, {
							input(pubEdit:old() or st.pubName or "", T("Nom de la partie", "Game name"), function(v) pubEdit:set(v) end, w - 190),
							gap(8, 1),
							button(T("Renommer", "Rename"), function()
								request("pubname", (tostring(pubEdit:old() or ""):gsub("[%c]", "")), playerName())
								pubEdit:set(nil)
							end, { font = "font-scale-body", enabled = pubEdit:old() ~= nil }),
						}),
					}
					if (st.pubIp or "") ~= "" then
						rows[#rows + 1] = gap(1, 6)
						rows[#rows + 1] = text((T("Votre adresse IP (%s) est visible par tous dans la liste publique : n'importe qui peut la voir et s'en servir.",
							"Your IP address (%s) is shown to everybody in the public list: anyone can see and use it."):gsub("%%s", function() return st.pubIp end)), "font-scale-body, warning", w - 24)
					end
					if st.cmode ~= "separate" then
						rows[#rows + 1] = gap(1, 6)
						rows[#rows + 1] = text(T("Une entreprise pour tous : un inconnu pourra construire, démolir et dépenser l'argent de l'entreprise.",
							"One company for everybody: a stranger will be able to build, demolish and spend the company's money."), "font-scale-body, warning", w - 24)
					end
					right[#right + 1] = gap(1, 10)
					right[#right + 1] = box(V, rows, nil, { padding = { 10, 12, 10, 12 }, background = { 1, 1, 1, 0.07 }, size = { w, -1 } })
				end
				for who in (st.pending or ""):gmatch("[^,]+") do
					local id = who
					right[#right + 1] = gap(1, 10)
					right[#right + 1] = box(V, {
						text((T("%s veut rejoindre la partie", "%s wants to join the game"):gsub("%%s", function() return (id:gsub("#%d+$", "")) end)), "font-scale-title-4", w - 24),
						gap(1, 4),
						box(H, {
							button(T("Accepter", "Accept"), function() request("admit", id .. " 1", playerName()) end, { font = "font-scale-body", primary = true }),
							gap(8, 1),
							button(T("Refuser", "Refuse"), function() request("admit", id .. " 0", playerName()) end, { font = "font-scale-body" }),
						}),
					}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.45, 0.1, 0.25 }, size = { w, -1 } })
				end
			end
			-- the download of the host's game: its percentage, from the text MPFever.exe writes
			if st.phase == "downloading" then
				local pct = tonumber((st.text or ""):match("(%d+)%s*%%"))
				if pct then
					right[#right + 1] = gap(1, 8)
					right[#right + 1] = builtin.ProgressBar{ meta = { class = "font-scale-annotation", styleSheet = style{ size = { PAGE_W - SIDE_W - 60, 24 } } }, value = pct / 100 }
				end
			end
			-- the players
			local players = {}
			for p in (st.players or ""):gmatch("[^,]+") do
				p = p:gsub("^%s+", ""):gsub("%s+$", "")
				if p ~= "" then players[#players + 1] = p end
			end
			-- one company per player: each player's colour (picked here, before the game starts)
			local separate = st.cmode == "separate" and (st.lobby == "host" or st.lobby == "client")
			local colorOf, taken, mine = {}, {}, nil
			for nm, ix in (st.colors or ""):gmatch("([^,:]+):(%d+)") do colorOf[nm] = tonumber(ix) end
			local me = st.name or playerName()
			for nm, ix in pairs(colorOf) do if nm == me then mine = ix else taken[ix] = true end end
			-- the computer companies of the lobby (experimental): "n:colour:level:name;..." from MPFever.exe; their colours are taken too
			local ais = {}
			if separate then
				-- ("n:colour:level:money:name", 0.5.14: its start money, -1 the players'; "n:colour:level:name" before)
				for entry in (st.ai or ""):gmatch("[^;]+") do
					local n, ix, lv, rest = entry:match("^(%d+):(%d+):(%d+):(.*)$")
					if n then
						local mo, nm = rest:match("^(%-?%d+):(.*)$")
						if not mo then nm = rest end
						ais[#ais + 1] = { n = tonumber(n), ix = tonumber(ix), lv = tonumber(lv) or 2, money = tonumber(mo) or -1, name = nm or "" }
						taken[tonumber(ix)] = true
					end
				end
			end
			if separate then
				if mine and mine ~= readColor() then writeColor(mine) elseif mine then writeFile("company_color.txt", tostring(mine) .. NL) end
				-- (the colour kept from last time, asked once when the player enters a lobby without one)
				if not mine and not colorAsked:get() then
					colorAsked:set(true)
					local pref = readColor()
					if pref and not taken[pref] then request("color", tostring(pref)) end
				end
			end
			if #players > 0 then
				right[#right + 1] = gap(1, 16)
				right[#right + 1] = text(T("Joueurs", "Players") .. " (" .. #players .. ")", "font-scale-title-3")
				right[#right + 1] = gap(1, 6)
				for i, p in ipairs(players) do
					local base = p:gsub("%s*%(.*$", "")
					local ix = separate and colorOf[base] or nil
					local pc = ix and PALETTE[ix] or nil
					-- (the colour square is the icon's place when the player has one: no hole in the list of children)
					local row = {
						pc and builtin.Component{ meta = { styleSheet = style{ size = { 22, 22 }, background = { pc[1], pc[2], pc[3], 1 } } } }
							or icon("::/gui/menu/icons/profile.tga"),
						gap(10, 1),
						text(p, "font-scale-title-4"),
						hfill(),
						i == 1 and (st.lobby == "host" or st.lobby == "client") and text(T("hôte", "host"), "font-scale-body") or nil,
					}
					-- (0.6, the game option join_bans) the host kicks a player (who may come back) or bans one (refused from then on)
					if i > 1 and isHost and st.pubKick == "1" then
						local who = base
						row[#row + 1] = button(T("Exclure", "Kick"), function() request("kick", who, playerName()) end, { font = "font-scale-body" })
						row[#row + 1] = gap(6, 1)
						row[#row + 1] = button(T("Bannir", "Ban"), function() request("ban", who, playerName()) end, { font = "font-scale-body" })
					end
					right[#right + 1] = box(H, row, nil, { padding = { 4, 10, 4, 10 }, background = { 1, 1, 1, i % 2 == 1 and 0.06 or 0.02 }, size = { PAGE_W - SIDE_W - 60, -1 } })
				end
			end
			-- (0.6, join_bans) the players the host banned (kept on its PC: "name|day;..."), each can be taken back
			if isHost and st.pubKick == "1" and (st.bans or "") ~= "" then
				local banned = {}
				for e in st.bans:gmatch("[^;]+") do
					local nm, day = e:match("^([^|]*)|?(.*)$")
					if nm and nm ~= "" then banned[#banned + 1] = { nm = nm, day = day or "" } end
				end
				right[#right + 1] = gap(1, 12)
				right[#right + 1] = text((T("Joueurs bannis (%s)", "Banned players (%s)"):gsub("%%s", tostring(#banned))), "font-scale-title-4")
				right[#right + 1] = gap(1, 4)
				for i, b in ipairs(banned) do
					local nm = b.nm
					right[#right + 1] = box(H, {
						text(nm .. (b.day ~= "" and ("   ·   " .. b.day) or ""), "font-scale-body"),
						hfill(),
						button(T("Retirer", "Remove"), function() request("unban", nm, playerName()) end, { font = "font-scale-body" }),
					}, nil, { padding = { 2, 10, 2, 10 }, background = { 1, 1, 1, i % 2 == 1 and 0.06 or 0.02 }, size = { PAGE_W - SIDE_W - 60, -1 } })
				end
			end
			if separate then side[#side + 1] = colorRow(mine, pickColor, nil, true, taken) end
			-- (one company per player) the computer companies: run by the host's game, each with its own colour and level; the host
			-- adds them, sets them and takes them out here, a savegame's are there from the start; the players of the lobby see them.
			-- Under the savegame's picture (0.5.13), one line each, so that the lobby shows them without scrolling.
			if separate and (isHost or #ais > 0) then
				local w = SIDE_W - 24
				local head = { text(T("Entreprises de l'ordinateur (expérimental)", "Computer companies (experimental)") .. (#ais > 0 and (" (" .. #ais .. ")") or ""), "font-scale-title-3"), hfill() }
				if isHost and #ais < 8 then
					head[#head + 1] = button(T("Ajouter une entreprise de l'ordinateur", "Add a computer company"), function() request("aiadd", "", playerName()) end, { font = "font-scale-body" })
				end
				below[#below + 1] = box(H, head, nil, { size = { w, -1 } })
				below[#below + 1] = text(T("Gérées par le jeu de l'hôte : bus, camions de marchandises et livraisons des villes. Plus le niveau est élevé, plus elles grandissent vite.", "Run by the host's game: buses, freight trucks and deliveries to the towns. The higher the level, the faster they grow."), "font-scale-body", w)
				below[#below + 1] = gap(1, 6)
				-- its level (0.5.13): how fast it grows and how hard it competes
				local LEVELS = { T("Facile", "Easy"), T("Normal", "Normal"), T("Difficile", "Hard") }
				for i, a in ipairs(ais) do
					local pc = PALETTE[a.ix]
					local n = a.n
					local line = {
						pc and builtin.Component{ meta = { styleSheet = style{ size = { 22, 22 }, background = { pc[1], pc[2], pc[3], 1 } } } } or icon("::/gui/menu/icons/profile.tga"),
						gap(10, 1),
						text(a.name ~= "" and a.name or (T("Ordinateur %s", "Computer %s"):gsub("%%s", tostring(n))), "font-scale-title-4", 220),
						hfill(),
					}
					if isHost then
						for lv = 1, 3 do
							local pick = lv
							line[#line + 1] = button(LEVELS[lv], function() request("ailevel", tostring(n) .. ":" .. tostring(pick), playerName()) end,
								{ font = "font-scale-body", primary = a.lv == lv })
							line[#line + 1] = gap(4, 1)
						end
						line[#line + 1] = gap(8, 1)
						-- (its colour; those of the players and of the other computer companies greyed)
						for ix, c in ipairs(PALETTE) do
							local sel = a.ix == ix
							local busyC = taken[ix] and not sel
							local pickC = ix
							line[#line + 1] = builtin.Button{
								meta = { class = sel and "primary" or "secondary", enabled = not busyC, styleSheet = style{ size = { 24, 22 }, padding = { 3, 3, 3, 3 } } },
								content = builtin.Component{ meta = { styleSheet = style{ size = { sel and 16 or 12, sel and 14 or 10 }, background = { c[1], c[2], c[3], busyC and 0.25 or 1 } } } },
								onClick = function() request("aicolor", tostring(n) .. ":" .. tostring(pickC), playerName()) end,
							}
							line[#line + 1] = gap(2, 1)
						end
						line[#line + 1] = gap(8, 1)
						line[#line + 1] = builtin.Button{
							meta = { class = "secondary", tooltip = T("Retirer", "Remove"), styleSheet = style{ size = { 34, 30 }, padding = { 5, 5, 5, 5 } } },
							content = icon("::/gui/menu/icons/symbol_x.tga", 20),
							onClick = function() request("aidel", tostring(n), playerName()) end,
						}
					else
						line[#line + 1] = text(T("Niveau : ", "Level: ") .. (LEVELS[a.lv] or LEVELS[2]), "font-scale-body")
					end
					below[#below + 1] = box(H, line, nil, { padding = { 4, 10, 4, 10 }, background = { 1, 1, 1, i % 2 == 1 and 0.06 or 0.02 }, size = { w, -1 } })
				end
			end
			-- (one company per player, 0.5.14) the game's rules: the start money of a new company, the sharing rules between
			-- companies on or off, the months in debt before a bankruptcy (its assets auctioned to the others, its players start
			-- again with a new company). Beside the picture, one line for every player of the lobby; the host opens them with a
			-- button under it, in place of the list under the picture (the lobby stays in view without scrolling). MPFever.exe
			-- sends them with the session ("rules" = "start|share|months"), the host's game keeps them in the savegame.
			-- (0.6.3: what is read here, for the lobby in sections, see lobbyColumn)
			local rulesView
			if separate then
				local rStart, rShare, rMonths = (st.rules or ""):match("^(%d+)|(%d)|(%d+)")
				rStart, rMonths = tonumber(rStart) or 2000000, tonumber(rMonths) or tonumber(st.bankrupt) or 12
				-- (0.7.4: and the auction of a bankrupt company, "mode:minutes")
				local auMode, auMin = (st.rules or ""):match("|(%a+):(%d+)$")
				auMode, auMin = auMode or "assets", tonumber(auMin) or 5
				local shareOn = rShare ~= "0"
				local function fmt(n)
					if n >= 1000000 then return (string.format("%g", n / 1000000)) .. " M" end
					if n >= 1000 then return (string.format("%g", n / 1000)) .. " k" end
					return tostring(n)
				end
				local sw = SIDE_W - PIC_W - 32
				local summary = T("Départ : %s", "Start: %s"):gsub("%%s", fmt(rStart)) .. "  ·  "
					.. (shareOn and T("Partage activé", "Sharing on") or T("Partage désactivé", "Sharing off")) .. "  ·  "
					.. (rMonths == 0 and T("Pas de faillite", "No bankruptcy") or (T("Faillite : %s mois", "Bankruptcy: %s months"):gsub("%%s", tostring(rMonths))))
				rulesView = { start = rStart, share = shareOn, months = rMonths, fmt = fmt, summary = summary, auMode = auMode, auMin = auMin }
				side[#side + 1] = gap(1, 12)
				side[#side + 1] = text(T("Règles de la partie", "Game rules"), "font-scale-title-4", sw)
				side[#side + 1] = text(summary, "font-scale-body", sw)
				-- (0.6) the game options on, for every player of the lobby: their number beside the picture, their list with their
				-- parameters at the top of the scroll area under it (in the host's settings panel while it is open, without the page of
				-- the game options); the button of that page beside the host's "Game settings…" button, a player's under the number
				local fv = featView(st)
				local fs = fv and featSummary(fv)
				local fc = fv and featCount(fv)
				if fc then side[#side + 1] = text(fc, "font-scale-body", sw) end
				-- (with the page of the game options, the number and its button are enough: the full list of 15 options covered the
				-- lobby under the picture)
				if fs and not OPTSPAGE and not (isHost and rulesOpen:old()) then
					table.insert(below, 1, text(fs, "font-scale-body", SIDE_W - 24))
					table.insert(below, 2, gap(1, 10))
				end
				if isHost then
					side[#side + 1] = gap(1, 6)
					local settingsButton = button(rulesOpen:old() and T("Fermer les réglages", "Close the settings") or T("Réglages de la partie…", "Game settings…"),
						function() rulesOpen:set(not rulesOpen:old()) end, { font = "font-scale-body", primary = rulesOpen:old() })
					side[#side + 1] = (OPTSPAGE and fv) and box(H, { settingsButton, gap(8, 1), optsButton(fv) }) or settingsButton
				elseif OPTSPAGE and fv then
					side[#side + 1] = gap(1, 6)
					side[#side + 1] = optsButton(fv)
				end
				if isHost and rulesOpen:old() then
					local w = SIDE_W - 24
					local panel = { text(T("Réglages de la partie", "Game settings"), "font-scale-title-3", w),
						text(T("Pour tous les joueurs ; gardés dans la sauvegarde.", "For every player; kept in the savegame."), "font-scale-body", w), gap(1, 10) }
					local function choices(label, values, cur, show, send)
						-- (the label in a column of its own: the buttons of every row start at the same place)
						local row = { box(H, { text(label, "font-scale-title-4", 290) }, nil, { size = { 300, -1 } }) }
						for _, v in ipairs(values) do
							local pick = v
							row[#row + 1] = button(show(v), function() send(pick) end, { font = "font-scale-body", primary = cur == v })
							row[#row + 1] = gap(4, 1)
						end
						panel[#panel + 1] = box(H, row, nil, { size = { w, -1 } })
						panel[#panel + 1] = gap(1, 6)
					end
					local MONEY = { 0, 500000, 1000000, 2000000, 5000000, 10000000, 20000000 }
					choices(T("Argent de départ d'une entreprise :", "Start money of a company:"), MONEY, rStart, fmt,
						function(v) request("startmoney", tostring(v), playerName()) end)
					panel[#panel + 1] = text(T("Celui de chaque nouvelle entreprise : un joueur qui arrive, une entreprise repartie après une faillite, et celle de l'hôte au début d'une nouvelle partie.",
						"That of every new company: a player who arrives, a company started again after a bankruptcy, and the host's at the start of a new game."), "font-scale-body", w)
					panel[#panel + 1] = gap(1, 10)
					choices(T("Règles de partage :", "Sharing rules:"), { 1, 0 }, shareOn and 1 or 0,
						function(v) return v == 1 and T("Activées", "On") or T("Désactivées", "Off") end,
						function(v) request("share", tostring(v), playerName()) end)
					panel[#panel + 1] = text(shareOn and T("Chaque entreprise décide si ses voies, gares, arrêts et dépôts sont privés, ouverts ou payants.", "Each company decides whether its tracks, stations, stops and depots are private, open or paying.")
						or T("Tout est ouvert et gratuit pour toutes les entreprises : voies, gares, arrêts et dépôts.", "Everything is open and free for every company: tracks, stations, stops and depots."), "font-scale-body", w)
					panel[#panel + 1] = gap(1, 10)
					choices(T("Faillite d'une entreprise endettée après :", "A company in debt goes bankrupt after:"), { 0, 3, 6, 12, 24 }, rMonths,
						function(m) return m == 0 and T("Jamais", "Never") or (T("%s mois", "%s months"):gsub("%%s", tostring(m))) end,
						function(m) request("bankrupt", tostring(m), playerName()) end)
					-- (0.7.4) the auction of a bankrupt company
					panel[#panel + 1] = gap(1, 10)
					choices(T("Vente aux enchères d'une faillite :", "Auction of a bankruptcy:"), { "assets", "company" }, auMode == "serial" and "assets" or auMode,
						function(v) return v == "company" and T("L'entreprise entière", "The whole company") or T("Les actifs, tous en même temps", "The assets, all at once") end,
						function(v) request("auction", v .. ":" .. tostring(auMin), playerName()) end)
					choices(T("Durée de la vente :", "Length of the sale:"), { 3, 5, 10 }, auMin,
						function(v) return (T("%s min", "%s min"):gsub("%%s", tostring(v))) end,
						function(v) request("auction", (auMode == "serial" and "assets" or auMode) .. ":" .. tostring(v), playerName()) end)
					if #ais > 0 then
						panel[#panel + 1] = gap(1, 10)
						panel[#panel + 1] = text(T("Argent de départ des entreprises de l'ordinateur", "Start money of the computer companies"), "font-scale-title-4", w)
						for _, a in ipairs(ais) do
							local n = a.n
							choices(a.name ~= "" and a.name or (T("Ordinateur %s", "Computer %s"):gsub("%%s", tostring(n))), { -1, 1000000, 2000000, 5000000, 10000000, 20000000 }, a.money,
								function(v) return v < 0 and T("Comme les joueurs", "As the players") or fmt(v) end,
								function(v) request("aimoney", tostring(n) .. ":" .. tostring(v), playerName()) end)
						end
					end
					-- (0.6) the game options of the separate mode (the list of those on first, see above); on their own page unless
					-- MPFEVER_LOBBYOPTSPAGE=0
					if not OPTSPAGE then
						if fs then panel[#panel + 1] = gap(1, 10); panel[#panel + 1] = text(fs, "font-scale-body", w) end
						if fv then featSection(panel, w, fv, playerName, players) end
					end
					local list = { box(V, panel, nil, { padding = { 10, 12, 10, 12 }, background = { 1, 1, 1, 0.07 }, size = { w, -1 } }), gap(1, 12) }
					for _, c in ipairs(below) do list[#list + 1] = c end
					below = list
				end
			end
			-- (0.6) everybody plays one company: the game options only, when a module offers some in the co-op. The players' line under
			-- the players; the host's "Game settings…" button there, its panel over the mods under a smaller picture (see leftCol).
			-- With the page of the game options (no rules in the co-op, so no settings panel): the number of options on and its button
			local sharedPanel = nil
			if not separate and (st.lobby == "host" or st.lobby == "client") then
				local fv = featView(st)
				local fs = fv and featSummary(fv)
				if OPTSPAGE and fv then
					local fc = featCount(fv)
					if fc then
						right[#right + 1] = gap(1, 10)
						right[#right + 1] = text(fc, "font-scale-body", RIGHT_W - 40)
					end
					right[#right + 1] = gap(1, 8)
					right[#right + 1] = optsButton(fv)
				elseif fs then
					right[#right + 1] = gap(1, 10)
					right[#right + 1] = text(fs, "font-scale-body", RIGHT_W - 40)
				end
				if fv and isHost and not OPTSPAGE then
					right[#right + 1] = gap(1, 8)
					right[#right + 1] = button(rulesOpen:old() and T("Fermer les réglages", "Close the settings") or T("Réglages de la partie…", "Game settings…"),
						function() rulesOpen:set(not rulesOpen:old()) end, { font = "font-scale-body", primary = rulesOpen:old() })
					if rulesOpen:old() then
						local w = SIDE_W - 24
						local panel = { text(T("Réglages de la partie", "Game settings"), "font-scale-title-3", w) }
						featSection(panel, w, fv, playerName)
						sharedPanel = box(V, panel, nil, { padding = { 10, 12, 10, 12 }, background = { 1, 1, 1, 0.07 }, size = { w, -1 } })
					end
				end
			end
			-- (the host) players who lack mods no Mod Hub has: send them from this PC? (with their size)
			if isHost then
				for e in (st.modAsk or ""):gmatch("[^;]+") do
					local who, ids, mb = e:match("^([^|]*)|([^|]*)|([^|]*)$")
					if who and who ~= "" then
						local n = 0
						for _ in ids:gmatch("[^,]+") do n = n + 1 end
						local w = who
						right[#right + 1] = gap(1, 10)
						right[#right + 1] = box(V, {
							text((T("%s n'a pas %s mod(s) qu'aucun Mod Hub ne propose (%s Mo) : ", "%s lacks %s mod(s) no Mod Hub has (%s MB): "):gsub("%%s", (who:gsub("%%", "%%%%")), 1):gsub("%%s", tostring(n), 1):gsub("%%s", mb, 1))
								.. ids:gsub(",", ", "), "font-scale-title-4, warning", PAGE_W - SIDE_W - 80),
							text(T("Les lui envoyer depuis votre PC ? Il devra accepter.", "Send them from your PC? They will have to accept."), "font-scale-body", PAGE_W - SIDE_W - 80),
							box(H, {
								button(T("Envoyer", "Send"), function() request("sendmods", w, playerName(), "1") end, { font = "font-scale-body", primary = true }),
								gap(8, 1),
								button(T("Non", "No"), function() request("sendmods", w, playerName(), "0") end, { font = "font-scale-body" }),
							}),
						}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.45, 0.1, 0.25 } })
					end
				end
				if (st.modSend or "") ~= "" then right[#right + 1] = text(st.modSend, "font-scale-body", PAGE_W - SIDE_W - 80) end
			else
				-- (a player) the host's offer: its mods hold code this game will run, so the player decides
				local ids, mb = (st.modOffer or ""):match("^([^|]*)|([^|]*)$")
				if ids and ids ~= "" then
					right[#right + 1] = gap(1, 10)
					right[#right + 1] = box(V, {
						text((T("L'hôte propose de vous envoyer ces mods (%s Mo) : ", "The host offers to send you these mods (%s MB): "):gsub("%%s", mb, 1)) .. ids:gsub(",", ", "), "font-scale-title-4", PAGE_W - SIDE_W - 80),
						text(T("Un mod contient du code qui s'exécutera dans votre jeu : n'acceptez que d'un hôte de confiance.", "A mod holds code that will run in your game: only accept from a host you trust."), "font-scale-body, warning", PAGE_W - SIDE_W - 80),
						box(H, {
							button(T("Accepter", "Accept"), function() request("takemods", "", playerName(), "1") end, { font = "font-scale-body", primary = true }),
							gap(8, 1),
							button(T("Refuser", "Refuse"), function() request("takemods", "", playerName(), "0") end, { font = "font-scale-body" }),
						}),
					}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.45, 0.1, 0.25 } })
				elseif st.modAskState == "waiting" then
					right[#right + 1] = text(T("Des mods de l'hôte ne s'installent pas automatiquement : l'hôte a été prévenu et peut vous les envoyer. Sinon, installez-les vous-même.",
						"Some of the host's mods cannot be installed by themselves: the host was told and can send them to you. Otherwise, install them yourself."), "font-scale-body, warning", PAGE_W - SIDE_W - 80)
				elseif st.modAskState == "refused" then
					right[#right + 1] = text(T("Les mods locaux de l'hôte ne vous seront pas envoyés : installez-les vous-même.", "The host's local mods will not be sent to you: install them yourself."), "font-scale-body, warning", PAGE_W - SIDE_W - 80)
				end
				if (st.modRecv or "") ~= "" then right[#right + 1] = text(st.modRecv, "font-scale-body", PAGE_W - SIDE_W - 80) end
				-- the host's savegame: on this PC already (copied by hand before joining: nothing to download), or sent at the start
				local hs, hn, hmb = (st.hostSave or ""):match("^([^|]*)|([^|]*)|([^|]*)$")
				if hs and hs ~= "" then
					local w = PAGE_W - SIDE_W - 80
					right[#right + 1] = gap(1, 10)
					if hs == "have" then
						right[#right + 1] = text((T("La sauvegarde de l'hôte (« %s ») est déjà sur ce PC : rien à télécharger au lancement.", "The host's savegame (« %s ») is already on this PC: nothing to download at the start."):gsub("%%s", (hn:gsub("%%", "%%%%")))), "font-scale-body, success", w)
					elseif hs == "checking" then
						right[#right + 1] = text(T("Recherche de la sauvegarde de l'hôte sur ce PC...", "Looking for the host's savegame on this PC..."), "font-scale-body", w)
					else
						right[#right + 1] = box(V, {
							text((T("La sauvegarde de l'hôte (« %s », %s Mo) vous sera envoyée au lancement.", "The host's savegame (« %s », %s MB) will be sent to you at the start."):gsub("%%s", (hn:gsub("%%", "%%%%")), 1):gsub("%%s", hmb, 1)), "font-scale-body", w),
							text(T("Pour éviter ce téléchargement (connexion lente), copiez ce fichier .sav depuis le PC de l'hôte dans votre dossier de sauvegardes, puis cliquez sur « Vérifier ».",
								"To avoid this download (slow connection), copy this .sav file from the host's PC into your savegame folder, then click « Check »."), "font-scale-body", w),
							box(H, {
								button(T("Ouvrir le dossier des sauvegardes", "Open the savegame folder"), function() request("opensaves", "", playerName()) end, { font = "font-scale-body" }),
								gap(8, 1),
								button(T("Vérifier", "Check"), function() request("recheck", "", playerName()) end, { font = "font-scale-body", primary = true }),
							}),
						}, nil, { padding = { 8, 8, 8, 8 }, background = { 1, 1, 1, 0.05 } })
					end
				end
			end
			-- the buttons
			local actions = {}
			-- (0.7.0) the join review: the host's game comes once the player says so
			if st.phase == "review" and not isHost then
				actions[#actions + 1] = button(T("Rejoindre la partie", "Join the game"), function() request("joinready", "", playerName()) end,
					{ primary = true, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" })
				actions[#actions + 1] = gap(8, 1)
			end
			if isHost then
				actions[#actions + 1] = button(T("Lancer la partie", "Start the game"), function() request("start", "", playerName()) end,
					{ primary = true, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" })
				actions[#actions + 1] = gap(8, 1)
			end
			if st.invite == "1" then
				actions[#actions + 1] = button(T("Inviter des amis Steam", "Invite Steam friends"), function() request("invite") end,
					{ icon = "::/gui/menu/icons/mod_management/platform_steam.tga" })
				actions[#actions + 1] = gap(8, 1)
			end
			if st.phase ~= "hosting" and st.phase ~= "ingame" then
				local cancelLabel = isHost and T("Fermer le salon", "Close the lobby")
					or (st.lobby == "client" and T("Quitter le salon", "Leave the lobby") or T("Annuler", "Cancel"))
				actions[#actions + 1] = button(cancelLabel, function() request("cancel") end, { icon = "::/gui/menu/icons/symbol_x.tga" })
			end
			-- (kept under the column, always in view: a long list of players or settings scrolls above them, it no longer pushes
			-- the « Start the game » button out of the page, where it could not be clicked)
			local actionsBox = box(H, actions)

			-- the mods of the host's savegame, under its picture: the player who joins sees at once which ones are missing here
			-- (the host's game cannot be loaded without them, see mpfever_auto.lua)
			local modsBox, modsFirst, modsInfo
			local mods = decodeMods(st.hostMods)
			-- (0.7.0, a player) the DLCs have their own list (st.dlcList, above): not here, where a missing one was told to be
			-- installed from a Mod Hub
			if not isHost then
				local kept = {}
				for _, m in ipairs(mods) do if m.source ~= "DLC" then kept[#kept + 1] = m end end
				mods = kept
			end
			if #mods > 0 then
				-- each mod with what is wrong first: missing here, another version than the host's, known to break a session,
				-- then the untested scripts, the mods MPFever made work, and the others (models, interface, data)
				local W = SIDE_W - 40
				local groups = { {}, {}, {}, {}, {} }
				for _, m in ipairs(mods) do
					-- (an incompatible mod first: the player is never told to install it)
					if m.level == "bad" then m.state = "bad"
					-- (a personal mod, the host's or taken so by this player: never needed, nor in the host's version)
					elseif m.personal == "mine" then m.state = "pmine"
					elseif m.personal == "host" then m.state = isHost and "pown" or "phost"
					elseif not isHost and modInstalled(m.id) == false then m.state = "missing"
					elseif m.here == "differs" then m.state = "differs"
					else m.state = m.level ~= "" and m.level or "ok" end
					local g = (m.state == "missing" or m.state == "differs" or m.state == "bad") and 1
						or (m.state == "caution" and 2) or (m.state == "fixed" and 3) or 4
					groups[g][#groups[g] + 1] = m
				end
				local blocking = #groups[1]
				-- a mod known to break a session (another multiplayer mod, TPF3-MP): told in big, above the lobby's actions
				for _, m in ipairs(groups[1]) do
					if m.state == "bad" then
						table.insert(right, 1, box(H, {
							icon("::/gui/menu/icons/alert.tga"),
							gap(8, 1),
							box(V, {
								text((T("%s est INCOMPATIBLE avec MPFever", "%s is INCOMPATIBLE with MPFever"):gsub("%%s", (m.name:gsub("%%", "%%%%")), 1)), "font-scale-title-3, error", PAGE_W - SIDE_W - 120),
								text(T("C'est un autre mod multijoueur : il modifie les mêmes choses que MPFever et la partie se désynchronise sans cesse. L'hôte doit le désactiver dans les mods de la sauvegarde (au chargement de la partie) avant de jouer.",
									"It is another multiplayer mod: it changes the same things as MPFever and the game keeps desynchronising. The host must turn it off in the savegame's mods (when loading the game) before playing."), "font-scale-body, warning", PAGE_W - SIDE_W - 120),
							}),
						}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.1, 0.1, 0.35 } }))
						table.insert(right, 2, gap(1, 8))
					end
				end
				local rows = {}
				if blocking > 0 then
					rows[#rows + 1] = box(H, {
						icon("::/gui/menu/icons/alert.tga"),
						gap(8, 1),
						text((T("Mods à corriger : %s sur %s", "Mods to fix: %s of %s"):gsub("%%s", tostring(blocking), 1):gsub("%%s", tostring(#mods), 1)), "font-scale-title-3, error"),
					})
				else
					rows[#rows + 1] = text((T("Mods de la partie : %s", "Mods of the game: %s"):gsub("%%s", tostring(#mods), 1))
						.. (isHost and "" or T(" (tous comme chez l'hôte)", " (all as on the host's PC)")), "font-scale-title-3")
				end
				rows[#rows + 1] = gap(1, 6)
				local LABEL = {
					missing = { T("manquant", "missing"), "error" },
					differs = { T("autre version que l'hôte", "other version than the host's"), "error" },
					bad = { T("incompatible", "incompatible"), "error" },
					caution = { T("script non testé", "untested script"), "warning" },
					fixed = { T("rendu compatible", "made compatible"), "success" },
					phost = { T("mod personnel de l'hôte, pas nécessaire ici", "the host's personal mod, not needed here"), "success" },
					pown = { T("mod personnel, pas nécessaire chez les autres", "personal mod, not needed by the others"), "success" },
					pmine = { T("ignoré : pris pour personnel", "left out: taken for personal"), "warning" },
				}
				for gi = 1, 4 do
					for _, m in ipairs(groups[gi]) do
						local lab = LABEL[m.state]
						local line = m.name .. (m.source ~= "" and m.source ~= "mod.io" and " (" .. m.source .. ")" or "")
						if lab then
							rows[#rows + 1] = text(line .. " : " .. lab[1], "font-scale-title-4, " .. lab[2], W)
							local why = m.note
							if m.state == "missing" and m.hub ~= "" then
								local inst = hub.installs[m.hub]
								local hs = hub.state(m.source, m.hub)
								if hs == "downloading" then why = T("Téléchargement par le Mod Hub du jeu...", "Downloading through the game's Mod Hub...")
								elseif hs == "installed" then why = T("Installé : il apparaît dans un instant.", "Installed: it shows in a moment.")
								elseif inst and inst.state == "failed" then why = T("Installation automatique impossible : ", "Cannot be installed by itself: ") .. tostring(inst.err):gsub("[%.%s]+$", "") .. ". " .. T("Installez-le vous-même (mod.io ou Steam Workshop).", "Install it yourself (mod.io or Steam Workshop).")
								elseif inst or hs == "subscribed" then why = T("Abonné : le Mod Hub du jeu le télécharge...", "Subscribed: the game's Mod Hub downloads it...")
								elseif hub.ready(m.source) == "signed_out" then why = T("Connectez-vous au Mod Hub du jeu (bouton Mods du menu principal) pour qu'il s'installe tout seul.", "Sign in to the game's Mod Hub (Mods button of the main menu) to have it installed by itself.")
								else why = T("Installez-le (mod.io ou Steam Workshop) avant que l'hôte lance la partie.", "Install it (mod.io or Steam Workshop) before the host starts the game.") end
							elseif m.state == "missing" then why = T("Aucun Mod Hub ne le propose (mod local de l'hôte) : l'hôte peut vous l'envoyer, sinon installez-le vous-même.", "No Mod Hub has it (the host's local mod): the host can send it to you, else install it yourself.")
							elseif m.state == "differs" then why = T("Mettez-le à jour pour avoir la même version que l'hôte.", "Update it to have the host's version.")
							elseif m.state == "pmine" then why = T("La partie de l'hôte est chargée sans lui chez vous. S'il agit sur la partie, elle se désynchronisera.", "The host's game loads without it here. If it acts on the game, the game will desynchronise.")
							elseif m.state == "phost" or m.state == "pown" then why = "" end
							if why ~= "" then rows[#rows + 1] = text("   " .. why, "font-scale-body", W) end
							-- (a player may take a mod it is missing, or has in another version, for personal: the host's game is then
							-- loaded without it here, with a warning; and give it back)
							local id = m.id
							if m.state == "missing" and m.hub ~= "" and not isHost and not hub.installs[m.hub] and hub.state(m.source, m.hub) == "none" and hub.ready(m.source) == "ok" then
								if st.autoMods ~= "0" then
									hub.install(m)
								else
									local mm = m
									rows[#rows + 1] = box(H, { gap(12, 1), button(T("Installer (Mod Hub)", "Install (Mod Hub)"), function() hub.install(mm) end, { font = "font-scale-body" }) })
								end
							end
							if (m.state == "missing" or m.state == "differs") and not isHost then
								rows[#rows + 1] = box(H, { gap(12, 1), button(T("Jouer sans (le prendre pour personnel)", "Play without it (take it for personal)"),
									function() request("modpersonal", id .. " 1", playerName()) end,
									{ font = "font-scale-body", tooltip = T("Seulement pour un mod qui ne change que votre interface : un autre fera se désynchroniser la partie.", "Only for a mod that only changes your interface: any other will make the game desynchronise.") }) })
							elseif m.state == "pmine" then
								rows[#rows + 1] = box(H, { gap(12, 1), button(T("Annuler", "Undo"), function() request("modpersonal", id .. " 0", playerName()) end, { font = "font-scale-body" }) })
							end
						else
							rows[#rows + 1] = text(line, "font-scale-body", W)
						end
					end
				end
				rows[#rows + 1] = gap(1, 6)
				if blocking > 0 and not isHost then
					rows[#rows + 1] = text(T("Sans les mêmes mods que l'hôte, sa partie ne peut pas être chargée.",
						"Without the host's mods, the host's game cannot be loaded."), "font-scale-body, warning", W)
				elseif #groups[2] > 0 then
					rows[#rows + 1] = text(T("Les scripts non testés peuvent désynchroniser la partie : MPFever la recharge alors chez tout le monde.",
						"Untested scripts can desynchronise the game: MPFever then reloads it for everybody."), "font-scale-body, warning", W)
				end
				-- this player's own personal mods (only its interface: loaded in its game alone), each on or off
				if not isHost then
					local mine = {}
					for e in (st.myMods or ""):gmatch("[^;]+") do
						local id, how, on = e:match("^([^|]*)|([^|]*)|([^|]*)$")
						if id and id ~= "" then mine[#mine + 1] = { id = id, how = how, on = on == "1" } end
					end
					if #mine > 0 then
						rows[#rows + 1] = gap(1, 10)
						rows[#rows + 1] = text(T("Vos mods personnels", "Your personal mods"), "font-scale-title-3")
						rows[#rows + 1] = text(T("Ils ne changent que votre interface : ajoutés à la partie de l'hôte chez vous seul.", "They only change your interface: added to the host's game for you alone."), "font-scale-body", W)
						for _, pm in ipairs(mine) do
							local id = pm.id
							rows[#rows + 1] = box(H, {
								text(id .. (pm.how == "forced" and T(" (pris pour personnel)", " (taken for personal)") or ""), pm.on and "font-scale-body" or "font-scale-body, warning", W - 130),
								hfill(),
								button(pm.on and T("Activé", "On") or T("Désactivé", "Off"), function() request("modmine", id .. (pm.on and " 0" or " 1"), playerName()) end, { font = "font-scale-body" }),
							})
						end
					end
				end
				modsBox = box(V, rows, nil, { padding = { 8, 12, 8, 12 }, background = { 1, 1, 1, 0.07 }, size = { SIDE_W - 20, -1 } })
				-- (a player who joins: its missing mods first, before the computer companies)
				modsFirst = blocking > 0 and not isHost
				modsInfo = { n = #mods, blocking = blocking }
			end
			-- the left column: the savegame's picture; with one company per player (0.5.13) a smaller one with the options beside it,
			-- the computer companies and the mods under it in one scroll area; else the big picture, the mods under a smaller one
			local leftCol
			if separate and rulesView and not LOBBYOLD then
				-- (0.6.3) in sections, see lobbyColumn
				leftCol = lobbyColumn{ host = isHost, st = st, ais = ais, players = players, mine = mine, taken = taken, pickColor = pickColor,
					playerName = playerName, lobbySave = lobbySave, modsBox = modsBox, mods = modsInfo, modsFirst = modsFirst, rules = rulesView,
					section = section:old(), setSection = function(id) section:set(id) end, openOpts = function() optsPage:set(true) end }
			elseif separate then
				local list = {}
				if modsBox and modsFirst then list[#list + 1] = modsBox; list[#list + 1] = gap(1, 12) end
				for _, c in ipairs(below) do list[#list + 1] = c end
				if modsBox and not modsFirst then list[#list + 1] = gap(1, 12); list[#list + 1] = modsBox end
				leftCol = {
					box(H, {
						SavePicture{ save = lobbySave, size = { PIC_W, PIC_H }, fallback = "::/gui/menu/images/main.tga" },
						gap(16, 1),
						box(V, side, nil, { size = { SIDE_W - PIC_W - 16, PIC_H } }),
					}),
					gap(1, 12),
				}
				if #list > 0 then
					leftCol[#leftCol + 1] = builtin.ScrollArea{
						meta = { styleSheet = style{ size = { SIDE_W, LOBBY_H - PIC_H - 12 } } },
						content = box(V, list, nil, { size = { SIDE_W - 20, -1 } }),
						horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
						verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
					}
				end
			elseif sharedPanel then
				-- (0.6) the co-op host's game options open: the panel, then the mods, under a smaller picture
				local picH = 220
				local list = { sharedPanel }
				if modsBox then list[#list + 1] = gap(1, 12); list[#list + 1] = modsBox end
				leftCol = {
					SavePicture{ save = lobbySave, size = { SIDE_W, picH }, fallback = "::/gui/menu/images/main.tga" },
					gap(1, 8),
					builtin.ScrollArea{
						meta = { styleSheet = style{ size = { SIDE_W, LOBBY_H - picH - 8 } } },
						content = box(V, list, nil, { size = { SIDE_W - 20, -1 } }),
						horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
						verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
					},
				}
			elseif modsBox then
				local picH = 220
				leftCol = {
					SavePicture{ save = lobbySave, size = { SIDE_W, picH }, fallback = "::/gui/menu/images/main.tga" },
					gap(1, 8),
					builtin.ScrollArea{
						meta = { styleSheet = style{ size = { SIDE_W, math.floor(SIDE_W * 9 / 16) - picH - 8 } } },
						content = modsBox,
						horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
						verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
					},
				}
			else
				leftCol = { SavePicture{ save = lobbySave, size = { SIDE_W, SIDE_W * 9 / 16 }, fallback = "::/gui/menu/images/main.tga" } }
			end
			-- (0.6) the page of the game options in place of the lobby, the whole width (a lobby whose mode offers none: the lobby)
			local pageFv = OPTSPAGE and optsPage:old() and (st.lobby == "host" or st.lobby == "client") and featView(st) or nil
			if pageFv then
				body[#body + 1] = featPage(pageFv, { host = isHost, playerName = playerName, players = players, width = PAGE_W - 16, height = LOBBY_H,
					onBack = function() optsPage:set(false) end })
			else
				-- (0.5.13: the right column takes the page's whole height, the buttons at its bottom)
				body[#body + 1] = box(H, {
					box(V, leftCol, nil, { size = { SIDE_W, LOBBY_H } }),
					gap(24, 1),
					box(V, {
						builtin.ScrollArea{
							meta = { styleSheet = style{ size = { RIGHT_W, LOBBY_H - 56 } } },
							content = box(V, right, nil, { size = { RIGHT_W - 20, -1 } }),
							horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
							verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
						},
						vfill(),
						actionsBox,
					}, nil, { size = { RIGHT_W, LOBBY_H } }),
				})
			end
		elseif tab:old() == "host" then
			-- the « Host » tab ------------------------------------------------------------------------------------------
			body[#body + 1] = text(T("Mode des entreprises", "Company mode"), "font-scale-title-3")
			body[#body + 1] = gap(1, 6)
			body[#body + 1] = box(H, {
				choice(companies:old() == "shared", T("Une entreprise pour tous", "One company for everybody"),
					T("Tout le monde construit et gère la même entreprise, avec le même argent.", "Everybody builds and runs the same company, with the same money."),
					function() companies:set("shared") end, true),
				gap(8, 1),
				choice(companies:old() == "separate", T("Une entreprise par joueur", "One company per player"),
					T("Chacun son argent, son réseau, ses véhicules et sa couleur, sur la même carte. Les gares peuvent être partagées.", "Everyone has their own money, network, vehicles and colour, on the same map. Stations can be shared."),
					function() companies:set("separate") end, true),
			})
			body[#body + 1] = gap(1, 12)
			local list = {}
			local f = (filter:old() or ""):lower()
			local nResync = 0
			for _, s in ipairs(saves:old()) do if isResyncSave(s.saveName) then nResync = nResync + 1 end end
			for _, s in ipairs(saves:old()) do
				if (f == "" or tostring(s.saveName):lower():find(f, 1, true)) and (showResync:old() or not isResyncSave(s.saveName)) then
					list[#list + 1] = SaveTile{
						meta = { localKey = "save-" .. tostring(s.saveName) },
						save = s,
						enabled = not busy,
						onHost = function(mods)
							-- the savegame's mods, sent by MPFever.exe to the players of the lobby (read now if the tile had not yet)
							if not mods then
								pcall(function()
									local a = app.getSavegameInfo(saveId(s))
									local d = a and a:get()
									if d and d.info then mods = modsOf(d.info) end
								end)
							end
							writeFile("host_mods.txt", encodeMods(mods))
							log("savegame mods: " .. #(mods or {}))
							-- MPFever.exe opens the session as a lobby: the players join it here, then the host starts the game for everybody
							request("host", s.saveName, playerName(), companies:old())
						end,
					}
				end
			end
			body[#body + 1] = box(H, {
				text(T("Choisissez la sauvegarde à partager", "Choose the savegame to share"), "font-scale-title-3"),
				hfill(),
				-- (0.6.3) or a new game made on the game's New Game page, saved and hosted by MPFever (see newGame)
				newGame.on and button(T("Nouvelle partie…", "New game…"), function() newGame.ask(companies:old(), playerName(), pp.commonParams) end,
					{ enabled = not busy, icon = "::/gui/line_vehicle_mgmt/icons/add.tga", tooltip = T("Créez la carte sur la page « Nouvelle partie » du jeu : dès qu'elle est prête, MPFever l'enregistre (« MPFever » et la date) et ouvre son salon ici.",
						"Make the map on the game's « New Game » page: as soon as it is ready, MPFever saves it (« MPFever » and the date) and opens its lobby here.") }) or gap(1, 1),
				gap(12, 1),
				builtin.TextInputField{
					meta = { class = "search-field, font-scale-body", styleSheet = style{ size = { 360, 30 } } },
					placeholderText = T("Filtrer les sauvegardes...", "Filter savegames..."),
					value = filter:old(),
					onTyping = function(v) if v ~= filter:old() then filter:set(v) end end,
				},
			})
			body[#body + 1] = gap(1, 6)
			-- (0.7.4) the resynchronisations' copies, hidden unless asked, with what they are
			if nResync > 0 or showResync:old() then
				body[#body + 1] = box(H, {
					builtin.CheckBox{
						value = showResync:old() and 1 or 0,
						label = T("Afficher les sauvegardes de resynchronisation", "Show the resynchronisation savegames") .. " (" .. nResync .. ")",
						onValueChange = function(v) showResync:set(v == 1) end,
					},
					gap(12, 1),
					text(T("« MPFever resync » est la copie de la partie de l'hôte que MPFever fait à chaque resynchronisation (la dernière remplace la précédente). Elle est masquée d'habitude ; cochez pour la retrouver, par exemple pour reprendre une partie après une coupure.",
						"« MPFever resync » is the copy of the host's game MPFever makes at every resynchronisation (the last one replaces the one before). It is usually hidden; tick to find it, for instance to go on with a game after a cut."), "font-scale-body", PAGE_W - 480),
				})
				body[#body + 1] = gap(1, 6)
			end
			if #list == 0 then
				body[#body + 1] = box(H, { text(#saves:old() == 0 and (newGame.on and T("Aucune sauvegarde trouvée : créez une nouvelle partie avec le bouton « Nouvelle partie… », MPFever l'enregistre et ouvre son salon.", "No savegame found: create a new game with the « New game… » button, MPFever saves it and opens its lobby.")
						or T("Aucune sauvegarde trouvée. Lancez une partie en solo et sauvegardez-la pour pouvoir l'héberger.", "No savegame found. Start a single-player game and save it to host it."))
					or T("Aucune sauvegarde ne correspond au filtre.", "No savegame matches the filter."), "font-scale-title-4", PAGE_W - 40) }, nil, { padding = { 24, 12, 24, 12 } })
			else
				body[#body + 1] = builtin.ScrollArea{
					meta = { class = "tile-list-scroll", styleSheet = style{ size = { PAGE_W - 16, hasError and 440 or 500 } } },
					content = builtin.Component{ layout = guiUtil.makeVerticalBox{ tiles.TileList{ elements = list, numRows = -1, numCols = 5 } } },
					horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
					verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
				}
			end
		elseif tab:old() == "servers" and st.serversOn == "1" then
			-- the « Public servers » tab: the dedicated servers of the public list (MPFever.exe reads it, menu_state servers=:
			-- one server per char 30, its fields separated by char 31: name, address, players, max, password, version, mode,
			-- world, motd) ---------------------------------------------------------------------------------------------
			body[#body + 1] = box(H, {
				text(T("Serveurs publics", "Public servers"), "font-scale-title-1"),
				hfill(),
				button(T("Actualiser", "Refresh"), function() request("servers") end, { enabled = not busy, size = { 220, 36 } }),
			})
			body[#body + 1] = gap(1, 6)
			body[#body + 1] = text(T("Les serveurs dédiés que leurs propriétaires ont rendus publics. Il faut la même version de MPFever et du jeu que le serveur.",
				"The dedicated servers their owners made public. The same versions of MPFever and of the game as the server's are needed."), "font-scale-body", PAGE_W - 40)
			body[#body + 1] = gap(1, 10)
			local raw = st.servers or ""
			if raw == "" or raw == "-" or raw:sub(1, 1) == "!" then
				local msg = raw == "" and T("Lecture de la liste...", "Reading the list...")
					or raw == "-" and T("Aucun serveur public pour l'instant.", "No public server for now.")
					or (T("La liste des serveurs ne répond pas : ", "The server list does not answer: ") .. raw:sub(2))
				body[#body + 1] = box(H, { text(msg, "font-scale-title-4", PAGE_W - 40) }, nil, { padding = { 24, 12, 24, 12 } })
			else
				local rows = {}
				for entry in raw:gmatch("[^" .. string.char(30) .. "]+") do
					local f = {}
					for v in (entry .. string.char(31)):gmatch("(.-)" .. string.char(31)) do f[#f + 1] = v end
					local sName, sAddr, sPlayers, sMax, sPw, sVer, sMode, sWorld, sMotd = f[1] or "", f[2] or "", f[3] or "0", f[4] or "0", f[5], f[6] or "", f[7] or "", f[8] or "", f[9] or ""
					local sameVersion = sVer == "" or sVer == (st.version or sVer)
					-- (0.6) a player's own public game (kind g): its host, its lobby open or its game running (fields 10 to 12)
					local sGame = f[10] == "g" and (T("Partie d'un joueur", "A player's game") .. ((f[12] or "") ~= "" and (" (" .. f[12] .. ")") or "") .. "   ·   "
						.. (f[11] == "playing" and T("partie en cours", "game running") or T("salon ouvert", "lobby open")) .. "   ·   ") or ""
					local info = sGame .. sPlayers .. " / " .. sMax .. " " .. T("joueurs", "players")
						.. "   ·   " .. (sMode == "separate" and T("une entreprise par joueur", "one company per player") or T("entreprise commune", "shared company"))
						.. (sPw == "1" and ("   ·   " .. T("mot de passe", "password")) or "")
						.. (sameVersion and "" or ("   ·   " .. T("autre version de MPFever : ", "other MPFever version: ") .. sVer))
					rows[#rows + 1] = box(H, {
						box(V, {
							text(sName, "font-scale-title-3", PAGE_W - 360),
							gap(1, 2),
							text((sWorld ~= "" and (sWorld .. "   ·   ") or "") .. info, "font-scale-body", PAGE_W - 360),
							sMotd ~= "" and text(sMotd, "font-scale-body", PAGE_W - 360) or gap(1, 1),
						}),
						hfill(),
						-- (a password: the « Join » tab with the address filled in, where the password is typed)
						button(T("Rejoindre", "Join"), function()
							if sPw == "1" then addr:set(sAddr); tab:set("join")
							else request("join", sAddr, playerName(), "") end
						end, { primary = true, enabled = sameVersion and not busy, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" }),
					}, nil, { padding = { 8, 12, 8, 12 } })
					rows[#rows + 1] = gap(1, 6)
				end
				body[#body + 1] = builtin.ScrollArea{
					meta = { class = "tile-list-scroll", styleSheet = style{ size = { PAGE_W - 16, hasError and 400 or 460 } } },
					content = box(V, rows),
					horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
					verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
				}
			end
		else
			-- the « Join » tab ------------------------------------------------------------------------------------------
			local formW = PAGE_W - SIDE_W - 40
			local canJoin = addr:old() ~= "" and not busy
			local function join()
				if addr:old() == "" then return end
				-- (one line of the request file: no tab or line break in the password)
				local pw = tostring(password:old() or ""):gsub("[%c]", "")
				request("join", addr:old(), playerName(), pw)
			end
			body[#body + 1] = box(H, {
				SavePicture{ size = { SIDE_W, SIDE_W * 9 / 16 }, fallback = "::/gui/menu/images/loadgame.tga" },
				gap(24, 1),
				box(V, {
					text(T("Rejoindre une partie", "Join a game"), "font-scale-title-1"),
					gap(1, 8),
					text(T("Entrez l'adresse que l'hôte vous a donnée. Il ouvre d'abord un salon, puis lance la partie quand tout le monde est là.",
						"Enter the address the host gave you. The host first opens a lobby, then starts the game when everybody is here."), "font-scale-body", formW),
					gap(1, 20),
					text(T("Adresse de l'hôte", "Host address"), "font-scale-title-4"),
					gap(1, 4),
					input(addr:old(), "1.2.3.4:28090", function(v) addr:set(v) end, formW - 20),
					gap(1, 14),
					text(T("Mot de passe", "Password"), "font-scale-title-4"),
					gap(1, 4),
					input(password:old(), T("seulement si le serveur en a un", "only if the server has one"), function(v) password:set(v) end, formW - 20),
					gap(1, 20),
					button(T("Rejoindre", "Join"), join, { primary = true, enabled = canJoin, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" }),
					vfill(),
					box(H, {
						icon("::/gui/menu/icons/mod_management/platform_steam.tga"),
						gap(10, 1),
						text(T("Avec Steam, vous pouvez aussi rejoindre un ami depuis votre liste d'amis (« Rejoindre la partie ») ou accepter son invitation.",
							"With Steam, you can also join a friend from your friends list (« Join Game ») or accept their invitation."), "font-scale-body", formW - 60),
					}),
				}, nil, { size = { formW, SIDE_W * 9 / 16 } }),
			})
		end

		local content = menuUi.makeTabAnalogue(header, {
			box(V, body, nil, { size = { PAGE_W, PAGE_H }, padding = { 8, 8, 8, 8 } }),
		})
		return menuUi.makePage(pp.commonParams, "MPFever – " .. T("Multijoueur", "Multiplayer"), pp.back,
			menuUi.makeMainOuterCard(true, { content }), {})
	end)

	-- (0.6.3) Where the « Multiplayer » card sits on the main page. In its top left corner (up to 0.6.2) it covered the game's
	-- own lines there (the player's profile, the edition, the Mod Hub's state). Now beside the game's cards, left of their bottom
	-- row (Continue / Load Game), the gap between them that of the game's cards, where it hides nothing.
	-- The main menu is laid out in units of a 1920 x 1080 screen scaled to the window (the smaller of width / 1920 and height /
	-- 1080, as the « Load Game » frame measures on screenshots at 1532 x 976 and 5120 x 1334): from 1280 x 720 to 2560 x 1440
	-- the same 1920 x 1080 units, a wider screen more width, a taller one more height, never less. The game centres its logo
	-- and cards (FloatingLayoutChild h = v = 0.5; h and v are relative: 0.5 centres the item, 0 / 1 put it against the left /
	-- top or right / bottom edge). Their sizes come from main_menu.css.lua and main_menu_sizes.lua: cards 794 x 314 and
	-- 391 x 151 with 5 of margin, rows 1205 wide and 324 high, the logo 676 x 272 (deluxe 676 x 297.5) with its margins
	-- -18 / 28 (deluxe 36). The card's item is centred too, as big as the game's block and mirrored (an empty width of the
	-- cards and of the card on its right, the space above and below), so it keeps to the cards on every screen; the empty
	-- part lets the mouse through (mouseTransparent), the game's cards under it stay clickable. At 1920 wide the cards leave
	-- 357 on each side: the card (316 x 181, the game's "small-rectangle-card") fits there with 36 to the screen's edge.
	-- MPFEVER_MENUCARD=old: the top left corner as before.
	local function cardPlace(how, deluxe)
		if how == "old" then return { h = 0.0, v = 0.0, padding = { 96, 0, 0, 24 } } end
		local ROWS_W, ROW_H, CARD_W, CARD_H = 1205, 324, 316 + 10, 181 + 10
		local logo = deluxe and (-18 + 297.5 + 36) or (-18 + 272 + 28)
		local below = (ROW_H - CARD_H) / 2
		return { h = 0.5, v = 0.5, padding = { logo + ROW_H + below, ROWS_W + CARD_W, below, 0 } }
	end

	-- the main page, with the « Multiplayer » card beside the game's cards; the MPFever page in its place once opened
	local CARD_IMAGES = {
		"::/gui/menu/images/temperate_ingame.tga",
		"::/gui/menu/images/subarctic_ingame.tga",
		"::/gui/menu/images/tropical_ingame.tga",
		"::/gui/menu/images/dry_ingame.tga",
	}
	MPPage = react.RegisterRecipe("MPFeverMainPage", function(p)
		local showMP = react.useState(os.getenv("MPFEVER_MENU_OPEN") ~= nil)
		local visited = react.useRef(false)
		-- the main menu shows: MPFever.exe ends a session the player left this way without opening the MPFever page (a new
		-- game started from here then ran in the old session). Test mode (MPFEVER_MENU_OPEN): the page opens by itself.
		react.onMount(function()
			local st0 = readState()
			log("main page shown (phase " .. tostring(st0.phase) .. ")")
			if st0.phase ~= nil and st0.phase ~= "" and st0.phase ~= "idle" then request("menu", "", st0.name or "") end
			-- (0.6.3) back from a new game saved for multiplayer: its lobby, on the MPFever page (see newGame)
			local ng = newGame.on and newGame.take() or nil
			if ng and busyPhase(st0.phase) then log("new game '" .. ng.save .. "' not hosted: a session runs (" .. tostring(st0.phase) .. ")")
			elseif ng then newGame.host(ng); showMP:set(true) end
		end)
		-- MPFever starts something from here (a lobby, a join, the host's game received): the release notes window is
		-- closed now, while the main page it calls back into still exists (see NOTICE_WINDOWS). Done here and not by the
		-- MPFever page, which is not open when a player joins through a Steam invitation. (Often, as nothing is read
		-- while no such window is shown: the load may follow the phase change within a second.)
		react.onStepTimer(function()
			if next(noticeClose) == nil then return end
			local s = readState()
			if s.phase == nil or s.phase == "" or s.phase == "idle" or s.phase == "error" then return end
			for id, close in pairs(noticeClose) do
				noticeClose[id] = nil
				log("phase " .. tostring(s.phase) .. ": closing the release notes window")
				local okc, errc = pcall(close)
				if not okc then log("closing the release notes window failed: " .. tostring(errc)) end
			end
		end, 0.2)

		-- (0.6.1, #103) the host's game received is loaded by the application script mpfever_auto.lua. A change of the game's
		-- language in its settings starts the game's interface again and that script runs no more: the player stayed on the
		-- main menu, "loading" for good. When the script has not taken the request within 6 s (menu_loaded.txt), the main page
		-- runs the same loader (mpfever_auto.lua's menuTick). MPFEVER_MENULOAD=0: never.
		-- (tests, MPFEVER_MENU_LANGTEST=<language code>: the game's language changed once from here, as a player does in the game's
		-- settings, to check the load from the main page after it; menu_langtest.txt marks it done)
		react.onStepTimer(function()
			if not os.getenv("MPFEVER_MENU_LANGTEST") or not (DIR and IO) or readFile("menu_langtest.txt") then return end
			writeFile("menu_langtest.txt", "1")
			log("test: the game's language changed to " .. os.getenv("MPFEVER_MENU_LANGTEST"))
			-- (the game's list of languages: { name, key }; the one whose name holds the code, else the first other than the current)
			local ok, err = pcall(function()
				local prof = app.getUserProfile()
				local cur, pick, other = prof:getLanguage(), nil, nil
				local want = os.getenv("MPFEVER_MENU_LANGTEST"):lower()
				for _, l in ipairs(prof:getLanguageRep():getAllLanguages()) do
					local same = false
					pcall(function() same = l[2]:equals(cur) end)
					if not same then
						other = other or l
						if not pick and tostring(l[1]):lower():find(want, 1, true) then pick = l end
					end
				end
				pick = pick or other
				log("test: language " .. tostring(pick and pick[1]))
				prof:changeLanguage(pick[2])
				-- (as the settings page does when it is left after a change of language)
				app.restart()
			end)
			if not ok then log("test: the language change failed: " .. tostring(err)) end
		end, 3)
		local autoWait = react.useRef(nil)
		react.onStepTimer(function()
			if os.getenv("MPFEVER_MENULOAD") == "0" or not (DIR and IO) then return end
			local s = readState()
			if s.phase ~= "loading" or not s.loadSeq or s.loadSeq == "" or not s.load or s.load == "" then autoWait:set(nil) return end
			local w = autoWait:get()
			if not w or w.seq ~= s.loadSeq then autoWait:set({ seq = s.loadSeq, n = 0 }) return end
			if w.off then return end
			w.n = w.n + 1
			if w.n < 12 then return end
			if w.n == 12 then
				if readFile("menu_loaded.txt") == w.seq then w.off = true return end
				log("the host's game not taken by the loader within 6 s (the game's language changed?): loaded from the main page")
			end
			-- (the flag in package.loaded: the main menu's scripts may not create globals, the game stops them, "creating globals by
			-- assignment is not allowed", and the menu was built again every 6 s, in the in-game test of the language change)
			package.loaded["mpfever_auto_embed"] = true
			local okA, A = pcall(require, "mpfever_1::/mpfever_auto.lua")
			package.loaded["mpfever_auto_embed"] = nil
			if not okA or type(A) ~= "table" or type(A.menuTick) ~= "function" then
				w.off = true
				log("the loader could not be read here: " .. tostring(A))
				return
			end
			local ok, err = pcall(A.menuTick)
			if not ok then log("loading from the main page failed: " .. tostring(err)) end
		end, 0.5)

		-- a session starts without the page (a Steam invitation accepted, the command line): the page opens to show it
		local lastPhase = react.useRef(readState().phase)
		-- (0.7.0) the join review waits for the player's « Join the game »: the page opens once for it, even when the phase was
		-- already "review" as the main menu showed (a join from the command line or a Steam invitation is faster than the menu)
		local reviewShown = react.useRef(false)
		react.onStepTimer(function()
			local phase = readState().phase
			local was = lastPhase:get()
			lastPhase:set(phase)
			local review = phase == "review" and not reviewShown:get()
			if phase ~= "review" then reviewShown:set(false) end
			if (review or (phase ~= was and busyPhase(phase) and not busyPhase(was))) and phase ~= "hosting" and phase ~= "loading" and phase ~= "ingame" and not showMP:old() then
				if phase == "review" then reviewShown:set(true) end
				log("phase " .. tostring(phase) .. ": opening the MPFever page")
				for id, close in pairs(noticeClose) do noticeClose[id] = nil; pcall(close) end
				showMP:set(true)
			end
		end, 0.5)

		-- (inside the menu's box layout a page must be a layout, as below)
		if showMP:old() then
			visited:set(true)
			return builtin.FloatingLayout{
				children = {
					builtin.FloatingLayoutChild{ h = -1, v = -1, item = builtin.Component{ layout = builtin.BoxLayout{ children = {
						MPFeverPage{ commonParams = p.commonParams, back = function() showMP:set(false) end },
					} } } },
				},
			}
		end

		local function open()
			log("multiplayer card clicked")
			-- (the release notes window would stay over the page)
			for id, close in pairs(noticeClose) do noticeClose[id] = nil; pcall(close) end
			showMP:set(true)
		end
		-- back from the MPFever page: the main page shows again without its release notes
		local mainParams = p
		if visited:get() and type(p) == "table" and type(p.params) == "table" and p.params.startWithReleaseNotes then
			mainParams = {}
			for k, v in pairs(p) do mainParams[k] = v end
			mainParams.params = {}
			for k, v in pairs(p.params) do mainParams.params[k] = v end
			mainParams.params.startWithReleaseNotes = false
		end
		local card = menuUi.CardButton{
			bottomComponent = menuUi.makeCardLabelBottomComponent(T("Multijoueur", "Multiplayer"), "MPFever", nil, nil, true),
			onClick = open,
			tooltip = T("Jouer à plusieurs : héberger une partie ou en rejoindre une", "Play together: host a game or join one"),
			images = CARD_IMAGES,
			initialImageIndex = 1,
			displayDurationSeconds = 12,
			class = "small-rectangle-card",
			-- (as the game's cards: the menu's background answers the mouse over it)
			onAttention = function(x, y) pcall(function() p.commonParams.triggerBackgroundEvent(api.type.Vec2f.new(x, y)) end) end,
		}
		-- (the logo the main page shows: the deluxe one is taller, the cards lower)
		local okD, dlc = pcall(function() return p.commonParams.getDLCModState() end)
		local place = cardPlace(os.getenv("MPFEVER_MENUCARD"), okD and type(dlc) == "table" and dlc.hasDeluxeDLC and true or false)
		-- inside the menu's box layout a page must be a layout: the original page fills it, the card floats over it
		return builtin.FloatingLayout{
			children = {
				builtin.FloatingLayoutChild{ h = -1, v = -1, item = builtin.Component{ mouseTransparent = true, layout = builtin.BoxLayout{ children = { _react.originalRecipeFn[mainId](mainParams) } } } },
				builtin.FloatingLayoutChild{ h = place.h, v = place.v, item = builtin.Component{ mouseTransparent = true, meta = { styleSheet = style{ padding = place.padding } }, layout = builtin.BoxLayout{ children = { card } } } },
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
