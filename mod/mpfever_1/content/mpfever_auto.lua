-- MPFever application script, started with: TransportFever3.exe --script mpfever_1::/mpfever_auto.lua
-- * autotest: loads the savegame named by MPFEVER_SAVE from the main menu, so that a test session needs nobody at the
--   keyboard;
-- * resynchronisation: when the mod loads the host's savegame (flag file resync_pending.txt), starts the loaded game
--   as soon as it is ready, without the "press a key" screen.
-- * a new multiplayer game (0.6.3): the game the host created from the MPFever page is saved and taken back to the menu's
--   lobby (see newGameTick).
-- No backslash characters on purpose.

local IO = package.loaded.io
local DIR = os.getenv("MPFEVER_DIR")
local SAVE = os.getenv("MPFEVER_SAVE")
local BS = string.char(92)

local function log(msg)
	pcall(print, "[MPFEVER-AUTO] " .. msg)
	if DIR and IO then
		local f = IO.open(DIR .. BS .. "auto.log", "ab")
		if f then
			f:write(os.date("%H:%M:%S") .. " " .. msg .. string.char(10))
			f:close()
		end
	end
end

local S = { requested = false, frames = 0, readyStarted = false }

local function loadSave(name, fromMenu, hostGame)
	name = name or SAVE
	local ns = app.SaveGameNamespace.getSavegame()
	local found = nil
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == name and (not found or (s.timestamp or 0) > (found.timestamp or 0)) then found = s end
	end
	if not found then
		log("savegame '" .. name .. "' not found")
		return
	end
	local id = api.type.SavegameId.new()
	id.path = found.path
	id.saveGameName = found.saveName
	id.saveGameNamespace = ns
	-- the savegame's details are read first (asynchronous, see update): MPFever is added to its mods if missing,
	-- as the game's own load screen does when the player changes the mods of a savegame
	local ok, async = pcall(app.getSavegameInfo, id)
	if ok and async then
		S.pending = { id = id, async = async, name = name, since = S.frames, fromMenu = fromMenu, host = hostGame }
		log("reading savegame '" .. name .. "' (" .. tostring(found.path) .. ")")
	else
		log("loading savegame '" .. name .. "' (details unavailable: " .. tostring(async) .. ")")
		app.loadGame(id, false)
	end
end

local MOD_ID = "mpfever_1"

-- (0.6.13) A DLC of the host's game this PC does not have (the Deluxe upgrade, the pre-order pack): the game loads without it, as
-- its own load screen lets a player do (the DLCs' severityRemove "Warning"), instead of not loading at all; the lobby and the join
-- review said that the games may then desynchronise (the user's choice, 2026-11-05: the game can still be played).
-- MPFEVER_DLCDROP=0: a missing DLC counts as a missing mod, the host's game is not loaded, as before.
local function dlcOf(descs, m)
	local d = descs[m.name]
	return os.getenv("MPFEVER_DLCDROP") ~= "0" and d ~= nil and d.modSource == "DLC"
end

local function descsOf(info)
	local descs = {}
	pcall(function()
		for _, d in ipairs(info.metadata.gameModDescs or {}) do
			if d.modId and d.modId.name then descs[d.modId.name] = d end
		end
	end)
	return descs
end

-- personal mods (0.5.0): the launcher's plan for this player's load of the host's game (load_mods.txt, see Mods.LoadPlan):
-- "drop TAB id" (the host's personal mods this player does not run) and "add TAB id" (this player's own)
local function loadPlan()
	if not (DIR and IO) then return nil end
	local f = IO.open(DIR .. BS .. "load_mods.txt", "rb")
	if not f then return nil end
	local s = f:read("*a") or ""
	f:close()
	local plan = { drop = {}, add = {}, n = 0 }
	for line in s:gmatch("[^" .. string.char(10, 13) .. "]+") do
		local k, id = line:match("^(%a+)" .. string.char(9) .. "(.+)$")
		if k == "drop" then plan.drop[id] = true; plan.n = plan.n + 1
		elseif k == "add" then plan.add[#plan.add + 1] = id; plan.n = plan.n + 1 end
	end
	return plan.n > 0 and plan or nil
end

-- the savegame's mods not installed here: written to missing_mods.txt (one "id TAB name TAB origin" line each); true if any
-- (the host's personal mods this player leaves out are not needed)
local function missingMods(info, plan)
	local okr, rep = pcall(function() return app.getUserProfile():getModRep() end)
	if not okr or not rep then return false end
	local descs = descsOf(info)
	local lines = {}
	for _, m in ipairs(info.mods or {}) do
		if m.name ~= MOD_ID and not (plan and plan.drop[m.name]) and not dlcOf(descs, m) then
			local ok, exists = pcall(function() return rep:exists(m) end)
			if ok and exists == false then
				local d = descs[m.name]
				local name = d and d.name ~= "" and d.name or m.name
				lines[#lines + 1] = (m.name .. string.char(9) .. name .. string.char(9) .. (d and d.modSource or "")):gsub("[" .. string.char(10, 13) .. "]", " ")
			end
		end
	end
	if #lines == 0 then return false end
	-- (MPFever.exe must hear of it: loaded anyway if the file cannot be written)
	if not (DIR and IO) then return false end
	local f = IO.open(DIR .. BS .. "missing_mods.txt", "wb")
	if not f then return false end
	f:write(table.concat(lines, string.char(10)) .. string.char(10))
	f:close()
	-- (no resynchronisation load waits any more)
	local fl = IO.open(DIR .. BS .. "resync_pending.txt", "wb")
	if fl then fl:close() end
	log("not loaded: " .. #lines .. " mod(s) of the host's game missing here")
	return true
end

local function loadPending()
	local p = S.pending
	local ok, done = pcall(function() return p.async:isCompleted() end)
	if ok and not done and S.frames - p.since < 600 then return end
	S.pending = nil
	local info
	if ok and done then
		local okg, data = pcall(function() return p.async:get() end)
		if okg and data and data.info then info = data.info end
	end
	if not info then
		log("loading savegame '" .. p.name .. "' (details unavailable)")
		app.loadGame(p.id, false)
		return
	end
	-- the host's game received from the main menu: not loaded when mods of it are missing on this PC (the game would load
	-- without them, and never match the host's). MPFever.exe reads missing_mods.txt and shows them.
	local plan = p.host and loadPlan() or nil
	if p.fromMenu and missingMods(info, plan) then return end
	local details = api.type.SaveGameDetails.new(info)
	local has = false
	local mods = {}
	-- (tests: MPFEVER_DROPMODS=id1,id2 leaves mods of the savegame out, as the load screen does: a DLC this PC does not have)
	local drop, dropped = {}, {}
	for id in tostring(os.getenv("MPFEVER_DROPMODS") or ""):gmatch("[^,%s]+") do drop[id] = true end
	-- (0.6.13) the host's DLCs this PC does not have: left out (see dlcOf)
	local descs = descsOf(info)
	local okrep, rep0 = pcall(function() return app.getUserProfile():getModRep() end)
	local function dlcMissing(m)
		if not (p.fromMenu and okrep and rep0 and dlcOf(descs, m)) then return false end
		local ok, ex = pcall(function() return rep0:exists(m) end)
		return ok and ex == false
	end
	for _, m in ipairs(info.mods or {}) do
		if dlcMissing(m) then dropped[#dropped + 1] = m.name; log("DLC " .. tostring(m.name) .. " of the host's game not on this PC: loaded without it (the games may desynchronise)")
		elseif drop[m.name] or (plan and plan.drop[m.name]) then dropped[#dropped + 1] = m.name
		else
			mods[#mods + 1] = m
			if m.name == MOD_ID then has = true end
		end
	end
	-- (tests: MPFEVER_ADDMODS=id1,id2 adds installed mods to the savegame, as the load screen does; the plan adds this
	-- player's personal mods, those installed)
	local added = {}
	local adds = {}
	for id in tostring(os.getenv("MPFEVER_ADDMODS") or ""):gmatch("[^,%s]+") do adds[#adds + 1] = id end
	if plan then
		local okr, rep = pcall(function() return app.getUserProfile():getModRep() end)
		for _, id in ipairs(plan.add) do
			local m = api.type.ModId.new()
			m.name = id
			local ok, ex = pcall(function() return okr and rep and rep:exists(m) end)
			if ok and ex then adds[#adds + 1] = id else log("personal mod " .. id .. " not installed here: not added") end
		end
	end
	for _, id in ipairs(adds) do
		local dup = false
		for _, m in ipairs(mods) do if m.name == id then dup = true end end
		if not dup then
			local m = api.type.ModId.new()
			m.name = id
			mods[#mods + 1] = m
			added[#added + 1] = id
		end
	end
	if not has then
		local m = api.type.ModId.new()
		m.name = MOD_ID
		mods[#mods + 1] = m
		log("loading savegame '" .. p.name .. "' with MPFever added to its mods")
	else
		log("loading savegame '" .. p.name .. "'")
	end
	if not has or #added > 0 or #dropped > 0 then details.mods = mods end
	if #dropped > 0 then log("mods left out: " .. table.concat(dropped, ", ")) end
	if #added > 0 then log("mods added: " .. table.concat(added, ", ")) end
	app.loadGame(p.id, false, details)
end

-- a resynchronisation load is pending (written by the mod just before it loads the host's savegame)
local function resyncPending()
	if not (DIR and IO) then return false end
	local f = IO.open(DIR .. BS .. "resync_pending.txt", "rb")
	if not f then return false end
	local s = f:read("*a") or ""
	f:close()
	return s:find("1", 1, true) ~= nil
end

local function clearResync()
	local f = IO.open(DIR .. BS .. "resync_pending.txt", "wb")
	if f then f:close() end
end

-- main menu: MPFever.exe received the host's savegame (menu_state.txt: load=name, loadSeq=n), load it
local lastLoadSeq = nil
local function menuLoad()
	if not (DIR and IO and S.menuReady) then return end
	local f = IO.open(DIR .. BS .. "menu_state.txt", "rb")
	if not f then return end
	local s = f:read("*a") or ""
	f:close()
	-- (read while MPFever.exe wrote it: its last line "end=1" is missing, a name may be cut)
	if s:find("end=1", 1, true) then S.stateEnd = true elseif S.stateEnd then return end
	local name = s:match("load=([^" .. string.char(10, 13) .. "]*)")
	local seq = s:match("loadSeq=([^" .. string.char(10, 13) .. "]*)")
	if not name or name == "" or not seq or seq == "" or seq == lastLoadSeq then return end
	-- the request already handled (kept in a file: this script may be restarted with the loaded game)
	local fd = IO.open(DIR .. BS .. "menu_loaded.txt", "rb")
	local done = fd and fd:read("*a") or ""
	if fd then fd:close() end
	lastLoadSeq = seq
	if done == seq then log("load " .. seq .. " of '" .. name .. "' already done: not loaded again") return end
	fd = IO.open(DIR .. BS .. "menu_loaded.txt", "wb")
	if fd then fd:write(seq) fd:close() end
	local fl = IO.open(DIR .. BS .. "resync_pending.txt", "wb")
	if fl then fl:write("1") fl:close() end
	-- (a host's game received by this player: loadSeq "r..."; the host's own savegame: "h...")
	local ok, err = pcall(loadSave, name, true, seq:sub(1, 1) == "r")
	if not ok then log("menu load failed: " .. tostring(err)) end
end

-- (autotest "toshared") the game was sent back to the main menu to load the test's savegame again (auto_reload.txt, written by
-- the bridge's H.tomenu): true once, the file emptied
local function takeReload()
	if not (DIR and IO) then return false end
	local f = IO.open(DIR .. BS .. "auto_reload.txt", "rb")
	if not f then return false end
	local s = f:read("*a") or ""
	f:close()
	if s == "" then return false end
	local w = IO.open(DIR .. BS .. "auto_reload.txt", "wb")
	if w then w:close() end
	return true
end

-- the loaded game waits for a key press: start it once loading is complete
local function startWhenReady()
	local ok, waiting = pcall(app.isWaitForStartReadyGame)
	if ok and waiting then
		local okp, progress = pcall(function() return app.getProgressMonitor():getProgress() end)
		if okp and progress and progress >= 1 then
			pcall(app.startReadyGame)
			return true
		end
	end
	return false
end

-- (0.6.3) A new multiplayer game without a savegame: the host's « New game » button of the MPFever page (mpfever_menu.lua,
-- newGame) writes newgame.txt and opens the game's own New Game page; the menu marks the file "started" when that page starts
-- a game (app.startGame2, or a saved map loaded). Once that game is loaded, this script starts it (no "press a key" screen),
-- saves it after about 2 s under the name "MPFever <date>", marks the file "saved" with that name and goes back to the main
-- menu, where the MPFever page opens the lobby with that savegame (newGame.take). "any" (the menu could not watch the game's
-- start): the next game loaded counts. A file older than 2 hours, or in another state, is left alone. MPFEVER_NEWGAME=0: never.
-- newgame.txt: "state TAB time TAB company mode TAB player name TAB savegame name"
local NG = { file = "newgame.txt" }
function NG.read()
	local f = IO.open(DIR .. BS .. NG.file, "rb")
	if not f then return nil end
	local s = f:read("*a") or ""
	f:close()
	local t = {}
	for v in (s:gsub("[" .. string.char(10, 13) .. "]+$", "") .. string.char(9)):gmatch("([^" .. string.char(9) .. "]*)" .. string.char(9)) do t[#t + 1] = v end
	if (t[1] or "") == "" then return nil end
	return { state = t[1], at = tonumber(t[2]) or 0, mode = t[3] or "", player = t[4] or "", save = t[5] or "" }
end
function NG.write(m)
	local f = IO.open(DIR .. BS .. NG.file, "wb")
	if not f then return end
	f:write(table.concat({ m.state, tostring(m.at), m.mode, m.player, m.save or "" }, string.char(9)) .. string.char(10))
	f:close()
end
local function newGameTick()
	if os.getenv("MPFEVER_NEWGAME") == "0" or not (DIR and IO) then return end
	if NG.stop then
		-- (saved: back to the main menu, unless the player went there already, which takes the file)
		NG.stop = nil
		local m = NG.read()
		if m and m.state == "saved" then
			log("new game saved as '" .. m.save .. "': back to the main menu for its lobby")
			local ok, err = pcall(app.stopGame)
			if not ok then log("new game: back to the main menu failed: " .. tostring(err)) end
		end
		return
	end
	local m = NG.read()
	if not m or (m.state ~= "started" and m.state ~= "any") or os.time() - m.at > 7200 then NG.since = nil NG.beat = nil return end
	if not NG.since then
		-- (the new game loaded and waiting for a key: started now)
		if startWhenReady() then NG.since = S.frames; log("new game loaded, starting it") return end
		-- (0.6.2) a new game from the game's New Game page starts at once, without the "press a key" screen: it was never seen,
		-- never saved, and the player stayed in it without a lobby (the user's test of 2026-10-31). It runs once MPFever's game
		-- script beats (bridge_alive.txt, a counter it rewrites every 2 s, still on the main menu). MPFEVER_NEWGAMEBEAT=0: the
		-- "press a key" screen only, as before
		if os.getenv("MPFEVER_NEWGAMEBEAT") ~= "0" then
			local f = IO.open(DIR .. BS .. "bridge_alive.txt", "rb")
			local beat = f and f:read("*a") or ""
			if f then f:close() end
			if NG.beat == nil then NG.beat = beat
			elseif beat ~= NG.beat then NG.since = S.frames; NG.beat = nil; log("new game running (MPFever's game script beats): saving it in a moment") end
		end
		return
	end
	if S.frames - NG.since < 120 then return end
	NG.since = nil
	m.state = "saving"
	m.save = os.date("MPFever %Y-%m-%d %Hh%M")
	NG.write(m)
	log("new game: saving it as '" .. m.save .. "'")
	local ok, err = pcall(app.saveGame, m.save, function()
		m.state = "saved"
		NG.write(m)
		NG.stop = true
	end, false, true)
	if not ok then
		log("new game: the save failed: " .. tostring(err))
		m.state = "failed"
		NG.write(m)
	end
end

local handlers = {
	handleEvent = function(id, name, param)
		if name == "mainMenuReady" then S.menuReady = true end
		if name == "mainMenuReady" and SAVE then
			local again = takeReload()
			if not S.requested or again then
				S.requested = true
				S.readyStarted = false
				if again then log("back on the main menu: the test savegame loaded again") end
				local ok, err = pcall(loadSave)
				if not ok then log("load failed: " .. tostring(err)) end
			end
		end
	end,
	update = function()
		S.frames = S.frames + 1
		if S.frames % 30 ~= 0 then return end
		if S.pending then
			local ok, err = pcall(loadPending)
			if not ok then log("load failed: " .. tostring(err)) S.pending = nil end
		end
		if S.requested and not S.readyStarted and startWhenReady() then
			S.readyStarted = true
			log("game loaded, starting it")
		end
		pcall(menuLoad)
		local okN, errN = pcall(newGameTick)
		if not okN then log("new game: " .. tostring(errN)) end
		if resyncPending() and startWhenReady() then
			clearResync()
			log("host's game loaded (resynchronisation), starting it")
		end
	end,
}

-- (0.6.1, #103) the same loader run by the main menu's page (mpfever_menu.lua, require), when this application script is gone: a
-- change of the game's language in its settings starts the game's interface again, and the script started with
-- --script runs no more. One call each half second of the menu: the host's game received is loaded (menu_loaded.txt keeps a
-- request from being loaded twice); the "press a key" screen that follows is the player's
handlers.menuTick = function()
	S.menuReady = true
	S.frames = S.frames + 30
	if S.pending then
		local ok, err = pcall(loadPending)
		if not ok then log("(menu) load failed: " .. tostring(err)) S.pending = nil end
	end
	menuLoad()
end

-- (required by the menu, package.loaded.mpfever_auto_embed set: the handlers only, the game's application script is this file
-- run with --script)
if type(package) == "table" and type(package.loaded) == "table" and package.loaded["mpfever_auto_embed"] then return handlers end
function data()
	return handlers
end
