-- MPFever UI hook (v0.4), runs in the UI Lua state, where the player's tools and windows live.
--
-- doReplace (react-replacement-config, at UI boot): wraps api.cmd so that every command the player issues is held
--   back, marshalled and sent to MPFever.exe (ui.log). The host stamps it and every game applies it at that stamp.
-- MPFeverEntry (react-plugin on the game's ModEntryPointExtension): an invisible component mounted for the whole
--   game; its onStep hook reads results.log and gives each tool the real result of its command (new line id,
--   bought vehicle...), as the native command would have.
-- Construction tools get their callback at once (they only need to know the command was accepted).

local okC, C = pcall(ug_require, "mpfever_common.lua")
if not okC then C = ug_require("mpfever_1::/mpfever_common.lua") end
local log = C.logger("-UI", "ui_mod.log")
local okR, R = pcall(ug_require, "mpfever_refs.lua")
if not okR then R = ug_require("mpfever_1::/mpfever_refs.lua") end

-- immediate answer for these (the tool just waits to be released); every other command waits for its result
local IMMEDIATE = { makeWorldBuildProposalCmd = true }

local U = {
	tags = setmetatable({}, { __mode = "k" }),
	seq = 0, logged = 0, installed = false,
	tok = tostring(os.time()) .. "-" .. tostring(math.floor((os.clock() % 1) * 1000000)) .. "-" .. C.NAME,
	pending = {},       -- id -> { cb, name, t0 }
	resOff = 0, bindOff = 0, rev = {},
	stats = { held = 0, speed = 0, failed = 0, untracked = 0, answered = 0 },
}

-- notifications kept across reloads (see N.record and N.tick, before tick)
local N = {}

local function sendLine(kind, payload)
	if not C.appendFile(C.DIR .. C.BS .. "ui.log", C.line(kind, payload)) then log("cannot write ui.log") end
end

local function isCallable(f)
	if type(f) == "function" then return true end
	local mt = getmetatable(f)
	return mt ~= nil and (type(mt) ~= "table" or mt.__call ~= nil)
end

-- ---------------------------------------------------------------- mods' automatic commands (0.7.0, see mpfever_modauto.lua)
local okMA, MA = pcall(ug_require, "mpfever_modauto.lua")
if not (okMA and type(MA) == "table") then okMA, MA = pcall(ug_require, "mpfever_1::/mpfever_modauto.lua") end
if not (okMA and type(MA) == "table") then MA = nil end
-- (MPFEVER_MODAUTO=0: every game sends what its mods send, as before)
U.modAutoOn = MA ~= nil and C.ACTIVE and os.getenv("MPFEVER_MODAUTO") ~= "0"
-- > 0 while a react.onStep / onStepTimer callback or a mod's guiUpdate runs (see the wrappers below)
U.autoDepth = 0

-- What the stack says about the code sending a command: the mods' files on it, and whether the outermost Lua function is a
-- mod's guiUpdate (called by the engine itself every frame: 3 parameters, userParams, state, guiState). Nothing without the
-- debug library.
U.stackFacts = function()
	local okD, dbg = pcall(function() return debug end)
	local getinfo = okD and type(dbg) == "table" and dbg.getinfo or nil
	if not getinfo then
		if not U.noDebugLogged then U.noDebugLogged = true; log("mods' automatic commands: no debug library here, only react.onStep is watched") end
		return { mods = {}, guiUpdate = false }
	end
	local mods, outer = {}, nil
	for lv = 3, 60 do
		local okI, info = pcall(getinfo, lv, "Su")
		if not okI or not info then break end
		if info.what ~= "C" then
			outer = info
			if MA.isModSource(info.source) then mods[#mods + 1] = info.source end
		end
	end
	local gu = outer ~= nil and MA.isModSource(outer.source) and outer.nparams == 3 and not outer.isvararg
	return { mods = mods, guiUpdate = gu }
end

-- the mod sending the command (its label), or nil
U.fromMod = function()
	local f = U.stackFacts()
	return f.mods[1] and MA.label(f.mods[1]) or nil
end

-- Which company owns what a command changes (its first argument): "mine", "theirs" or nil (no owner, or one company for
-- everybody: only one company per player has owners that tell the games apart)
U.ownerOf = function(tag)
	local e = tag.args and tag.args[1]
	if type(e) ~= "number" or not U.myCo or not U.coMap then return nil end
	local co = U.coMap[e]
	if co == nil then
		local okO, po = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED) end)
		if okO and po and po.player then co = U.coMap[po.player] end
	end
	if co == nil then return nil end
	return co == U.myCo and "mine" or "theirs"
end

U.autoVerdict = function(tag)
	local sf = U.stackFacts()
	local auto
	if U.cbAuto ~= nil then auto = U.cbAuto else auto = U.autoDepth > 0 or sf.guiUpdate end
	local facts = { auto = auto, mod = #sf.mods > 0, src = sf.mods[1] }
	if not (facts.auto and facts.mod) then return "send", "not automatic", facts end
	local st = U.status
	facts.role = C.ROLE
	facts.separate = st ~= nil and st.mode == "separate"
	facts.strict = MA.strictOf(sf.mods)
	if facts.separate then facts.owner = U.ownerOf(tag) end
	-- (this player's own last action: a command of theirs, or a build of their tools, see the bridge's guiHandleEvent)
	local last = U.lastLocal
	local okP, tb = pcall(function() return package.loaded["mpfever_local_activity"] end)
	if okP and type(tb) == "number" and (last == nil or tb > last) then last = tb end
	facts.idle = last and (os.clock() - last) or nil
	local verdict, why = MA.decide(facts)
	return verdict, why, facts
end

U.autoLog = function(tag, facts, why, dropped)
	local key = (facts and facts.src and MA.label(facts.src) or "?") .. "/" .. tostring(tag.name) .. (dropped and "/d" or "/s")
	U.autoSeen = U.autoSeen or {}
	local n = (U.autoSeen[key] or 0) + 1
	U.autoSeen[key] = n
	if dropped then U.stats.autoDropped = (U.stats.autoDropped or 0) + 1 end
	if n <= 3 or n % 200 == 0 then
		log("mods: " .. tostring(tag.name) .. " sent by itself by " .. (facts and facts.src and MA.label(facts.src) or "?")
			.. (facts and facts.strict and (" (" .. facts.strict .. ")") or "") .. ": " .. (dropped and "not sent from this game, " or "sent, ")
			.. tostring(why) .. " x" .. n)
	end
end

-- A mod's game script whose guiUpdate the engine calls every frame: its commands are automatic (the same as the stack's
-- guiUpdate test above, for a game without the debug library). The interface's table of game scripts, when it has one.
U.wrapModGuiUpdates = function()
	if not U.modAutoOn then return end
	local okG, g = pcall(function() return game end)
	if not (okG and type(g) == "table") then return end
	for k, v in pairs(g) do
		if type(k) == "string" and type(v) == "table" and type(v.guiUpdate) == "function" and not v.__mpfAuto
			and k:sub(1, 3) ~= "::/" and not k:find("mpfever", 1, true) then
			v.__mpfAuto = true
			local orig = v.guiUpdate
			v.guiUpdate = function(...)
				U.autoDepth = U.autoDepth + 1
				local r = table.pack(pcall(orig, ...))
				U.autoDepth = U.autoDepth - 1
				if not r[1] then error(r[2], 0) end
				return table.unpack(r, 2, r.n)
			end
			log("mods' automatic commands: the guiUpdate of " .. k .. " is watched")
		end
	end
end

local function install()
	if U.installed then return end
	U.installed = true
	-- (a game just loaded: what its mods send in their first seconds (a scan of the whole world) is nobody's own job, even
	-- right after this player built something in the game before)
	pcall(function() package.loaded["mpfever_local_activity"] = nil end)
	-- the game script bridge may share this api table: it must keep using the game's own functions, never the
	-- wrapped ones (its speed commands would come back as player requests, its events would be replicated)
	-- (api.cmd is userdata and takes no new member: the originals are kept in package.loaded, shared by the state)
	local orig = C.origCmds()
	if not orig.sendCommand then
		orig.sendCommand, orig.setSpeed, orig.event = api.cmd.sendCommand, api.cmd.makeGameSetSpeedCmd, api.cmd.makeScriptingSendEventCmd
	end
	local O = { sendCommand = orig.sendCommand }
	local wrapped, missing, kinds = 0, {}, {}
	for _, name in ipairs(C.FACTORIES) do
		local fn = nil
		pcall(function() fn = api.cmd[name] end)
		if fn ~= nil and isCallable(fn) then
			kinds[type(fn)] = true
			local okw = pcall(function()
				api.cmd[name] = function(...)
					local cmd = fn(...)
					if cmd ~= nil then U.tags[cmd] = { name = name, args = { n = select("#", ...), ... } } end
					return cmd
				end
			end)
			if okw then wrapped = wrapped + 1 else missing[#missing + 1] = name .. "(read-only)" end
		else
			missing[#missing + 1] = name .. "(" .. type(fn) .. ")"
		end
	end
	-- (0.7.0) the debug factories are tagged too (they go to the engine as before, but a mod's are refused in a session, see
	-- tag.debug below)
	if U.modAutoOn then
		pcall(function()
			local dbgCmd = api.cmd.debug
			for _, name in ipairs({ "makeMaintenanceCostUpdateCmd", "makeSimPersonSetStateCmd", "makeSimPersonSetHappiness",
				"makeComponentExchangeCmd", "makeStockSetCargoAmountCmd", "makeClearLogbooksCmd" }) do
				local fn = nil
				pcall(function() fn = dbgCmd[name] end)
				if fn ~= nil and isCallable(fn) then
					pcall(function()
						dbgCmd[name] = function(...)
							local cmd = fn(...)
							if cmd ~= nil then U.tags[cmd] = { name = "debug." .. name, debug = true, args = { n = 0 } } end
							return cmd
						end
					end)
				end
			end
		end)
	end
	api.cmd.sendCommand = function(cmd, cb, progress)
		local tag = cmd ~= nil and U.tags[cmd] or nil
		if tag == nil then
			U.stats.untracked = U.stats.untracked + 1
			if U.logged < 30 then U.logged = U.logged + 1; log("untracked command sent natively: " .. C.dump(cmd):sub(1, 160)) end
			return O.sendCommand(cmd, cb, progress)
		end
		-- (0.7.0) a debug command (api.cmd.debug: a person's state, a stock's cargo...) is applied on this game only. A mod that
		-- sends one changed this game's world alone (Just More Weather sets people's states every frame): refused in a session.
		-- Anything else (the game's own debug tools) goes to the engine as before. MPFEVER_MODAUTO=0: as before
		if tag.debug then
			local okD, fromMod = pcall(U.fromMod)
			if okD and fromMod and (C.ROLE == "host" or C.ROLE == "client") then
				U.debugRefused = (U.debugRefused or 0) + 1
				if U.debugRefused <= 5 or U.debugRefused % 500 == 0 then
					log("mods: debug command " .. tag.name .. " of " .. tostring(fromMod) .. " refused in a session (it would change this game only) x" .. U.debugRefused)
				end
				return
			end
			return O.sendCommand(cmd, cb, progress)
		end
		-- notification events (popup sound, dismiss) are sent automatically by each game's own interface: local only
		if tag.name == "makeScriptingSendEventCmd" and tag.args[2] == "Notifications" then
			U.notifLogged = (U.notifLogged or 0) + 1
			if U.notifLogged <= 40 then log("local notification event " .. tostring(tag.args[1]) .. "/" .. tostring(tag.args[3]) .. " " .. C.ser(C.marshal(tag.args[4])):sub(1, 200)) end
			local okr, errr = pcall(N.record, tag.args[3], tag.args[4])
			if not okr then log("notifications: not kept: " .. tostring(errr)) end
			if os.getenv("MPFEVER_NONOTIF") then return end
			return O.sendCommand(cmd, cb, progress)
		end
		-- town development at a position: the engine seeds it from the C library's rand(), seeded with the clock, so every
		-- game would develop the town differently (found by TPF3-MP, investigation/TPF3_RNG_2026-09-29.md). No stock script
		-- sends it; a mod's is refused in a session
		if tag.name == "makeTownDevelopAtCmd" then
			U.townDevRefused = (U.townDevRefused or 0) + 1
			if U.townDevRefused <= 5 then log("makeTownDevelopAtCmd refused in a session (its random numbers differ on every game)") end
			return
		end
		if tag.name == "makeGameSetSpeedCmd" then
			U.stats.speed = U.stats.speed + 1
			-- the interface repeats its request every frame while the game holds another speed: one per second at most
			local now = os.clock()
			if U.speedRepeatHeld and U.speedRepeatHeld(tag.args[1], now) then
				if cb then pcall(cb, nil, true, {}) end
				return
			end
			if tag.args[1] ~= U.lastSpeedReq or now - (U.lastSpeedAt or -10) > 1 then
				U.lastSpeedReq, U.lastSpeedAt = tag.args[1], now
				sendLine("speed_req", { speed = tag.args[1] })
			end
			-- (the speed buttons wait for this answer before they follow the game's speed again, issue #24)
			if cb then pcall(cb, nil, true, {}) end
			return
		end
		-- (0.7.0) a command a mod's interface sends by itself goes from one game only (mpfever_modauto.lua); a debug command of a
		-- mod is refused in a session (applied on this game only, it made the games differ)
		local autoNow, autoCtx, fromMod = false, false, false
		if U.modAutoOn then
			local okA, verdict, why, facts = pcall(U.autoVerdict, tag)
			if okA and facts then autoNow, autoCtx, fromMod = facts.auto and facts.mod, facts.auto, facts.mod end
			if okA and verdict == "drop" then
				U.autoLog(tag, facts, why, true)
				return
			elseif okA and autoNow then
				U.autoLog(tag, facts, why, false)
			elseif not okA then
				U.autoErr = (U.autoErr or 0) + 1
				if U.autoErr <= 3 then log("mods' automatic commands: check failed: " .. tostring(verdict)) end
			end
		end
		-- (this player's own action: what a mod sends by itself in the next seconds is taken as the end of this job. A command
		-- of the game's own windows only: a mod's command that is not seen as automatic (sent while the game loads, from
		-- elsewhere than a step) opened that window on every game, the test of 2026-11-04 10:17)
		if not autoCtx and not fromMod then U.lastLocal = os.clock() end
		local okm, margs = pcall(function()
			local r = { n = tag.args.n }
			for i = 1, tag.args.n do r[i] = C.marshal(tag.args[i]) end
			return r
		end)
		if not okm then
			U.stats.failed = U.stats.failed + 1
			log("marshal failed for " .. tag.name .. ": " .. tostring(margs) .. " -> executed locally only (desync risk)")
			sendLine("act_fail", { fn = tag.name, stage = "marshal", err = tostring(margs) })
			return O.sendCommand(cmd, cb, progress)
		end
		local okt, errt = pcall(R.translateOut, tag.name, margs, U.rev)
		if not okt then log("reference translation failed for " .. tag.name .. ": " .. tostring(errt)) end
		U.seq = U.seq + 1
		U.stats.held = U.stats.held + 1
		sendLine("act_req", { tok = U.tok, id = U.seq, fn = tag.name, args = margs })
		if U.logged < 80 then
			U.logged = U.logged + 1
			log("held " .. tag.name .. " #" .. U.seq .. " (" .. #C.ser(margs) .. " bytes)")
			if U.logged <= 12 then C.appendFile(C.DIR .. C.BS .. "captured.txt", tag.name .. " #" .. U.seq .. C.NL .. C.ser(margs) .. C.NL) end
		end
		if cb then
			if IMMEDIATE[tag.name] or not U.stepping then
				-- without the per-step component the result could never be delivered: answer now
				local okc, errc = pcall(cb, nil, true, {})
				if not okc then log("tool callback error (ignored): " .. tostring(errc):sub(1, 160)) end
			else
				U.pending[U.seq] = { cb = cb, name = tag.name, t0 = os.clock(), auto = autoNow }
			end
		end
	end
	-- the game's speed buttons (GameSpeedHelper in gui/main/game.tl) show the engine's speed, which the lockstep holds at 0
	-- between steps: they are shown the session's speed instead (mp_status.txt), or for 2 s the speed this player asked for
	local okSp, errSp = pcall(function()
		local origGet = api.engine.getComponent
		local speedType = api.type.ComponentType.GAME_SPEED
		api.engine.getComponent = function(e, ct, ...)
			local c = origGet(e, ct, ...)
			if ct == speedType and c ~= nil then
				local sp = U.shownSpeed()
				-- (mpfRealSpeedup: the engine's own speed, which the lockstep reads, see gameSpeed in the bridge)
				if sp ~= nil and U.shownLogged ~= sp then
					U.shownLogged = sp
					log("speed buttons: session speed " .. tostring(sp) .. " shown (engine " .. tostring(c.speedup) .. ")")
				end
				if sp ~= nil then return setmetatable({ speedup = sp, mpfRealSpeedup = c.speedup }, { __index = function(_, key) return c[key] end }) end
			end
			return c
		end
	end)
	if not okSp then log("speed buttons: not redirected: " .. tostring(errSp)) end
	-- the speed buttons also clamp the speed to what this PC is estimated to keep up with (getEstimatedMaximumGameSpeed) and
	-- ask for the clamped speed again every frame while it is lower: in a session the lockstep's waits bring that estimate
	-- down to 1, so every x2 or x3 a player asked was turned back into x1 by the host's game (a test: 190 requests for x1).
	-- The lockstep paces the games itself: no clamp during a session. MPFEVER_SPEEDCLAMP=1: as before
	local okMx, errMx = pcall(function()
		local g = api.gui.game
		local origMax = g.getEstimatedMaximumGameSpeed
		g.getEstimatedMaximumGameSpeed = function(...)
			-- (MPFEVER_FAKEMAXSPEED=n, tests: the estimate of a PC that keeps up with x n only)
			local m = tonumber(os.getenv("MPFEVER_FAKEMAXSPEED") or "") or origMax(...)
			if U.shownSpeed() == nil or os.getenv("MPFEVER_SPEEDCLAMP") == "1" then return m end
			if type(m) == "number" and m > 0 and m < 4 and U.clampLogged ~= m then
				U.clampLogged = m
				log("speed buttons: this game's estimated maximum speed " .. tostring(m) .. " not applied in a session")
			end
			return 4
		end
	end)
	if not okMx then log("speed buttons: maximum speed not redirected: " .. tostring(errMx)) end
	local k = {}
	for t, _ in pairs(kinds) do k[#k + 1] = t end
	log("UI interception installed on " .. wrapped .. " factories (types: " .. table.concat(k, ",") .. ")" .. (#missing > 0 and (", missing: " .. table.concat(missing, ",")) or ""))
end

-- companies mode: the company numbers of the player entities (companies.txt, written by the game-script bridge); a command that
-- names a company's player (vehicle purchase, line creation...) then travels with the company number, not the entity id
R.coIdOf = function(e) return U.coMap and U.coMap[e] or nil end
-- the game's company modules, adjusted for the companies mode in this state too (see mpfever_co.lua)
local function patchGameModules()
	local okO, CO = pcall(ug_require, "mpfever_co.lua")
	if not okO then okO, CO = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
	if not (okO and type(CO) == "table" and CO.patchPermits) then log("companies: mpfever_co.lua is not reachable from the interface") return end
	local function req(name)
		for _, path in ipairs({ "/game_mechanics/company/" .. name, "::/game_mechanics/company/" .. name }) do
			local ok, m = pcall(ug_require, path)
			if ok and type(m) == "table" then return m end
		end
		return nil
	end
	CO.patchProgression(req, function(entity)
		if U.coMap and U.coMap[entity] and U.canon then return U.canon end
		return nil
	end, log, function(entity)
		-- (each company's own rank, written by the bridge into companies.txt when there is more than one company)
		local id = U.coMap and U.coMap[entity]
		return id and U.ranks and U.ranks[id] or nil
	end)
	CO.patchPermits(req, log)
end
local function pollCompanies()
	local f = C.IO.open(C.DIR .. C.BS .. "companies.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.coTxt then return end
	U.coTxt = txt
	local map, names, ranks, nRanks, colors = {}, {}, {}, 0, {}
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local rid, rx, rl, rp = line:match("^rank" .. C.TAB .. "(%d+)" .. C.TAB .. "([%d%.%-]+)" .. C.TAB .. "(%d+)" .. C.TAB .. "(%d+)")
		if rid then ranks[tonumber(rid)] = { experience = tonumber(rx), level = tonumber(rl), potentialLevel = tonumber(rp) }; nRanks = nRanks + 1 end
		local a, b, n = line:match("^(%d+)" .. C.TAB .. "(%d+)" .. C.TAB .. "?([^" .. C.TAB .. "]*)")
		if a then map[tonumber(b)] = tonumber(a); names[tonumber(b)] = n end
		local me = line:match("^me" .. C.TAB .. "(%d+)")
		-- (0: between two companies)
		if me then U.myCo = tonumber(me) ~= 0 and tonumber(me) or nil end
		local cid, cix = line:match("^color" .. C.TAB .. "(%d+)" .. C.TAB .. "(%d+)")
		if cid then colors[tonumber(cid)] = tonumber(cix) end
	end
	-- (0.7.5) A file of the world before: the session folder stays the same until the game closes, and a client that played
	-- one company per player, then joined a game of one company for everybody without closing the game, read the companies
	-- of its previous world before the bridge wrote anything; the interface then read a company's data on an entity of the new
	-- world that is none, « it != components.end() » in UI::CSelector (the user's crash of 2026-10-28, autotests ts2 and ts3
	-- of 2026-11-07, both times right after the load). A file naming an entity that is no company here is left until it
	-- changes. MPFEVER_COFILEOLD=1: taken as it is, as before
	if os.getenv("MPFEVER_COFILEOLD") ~= "1" then
		for e in pairs(map) do
			local okP, isP = pcall(function()
				return api.engine.entityExists(e) and api.engine.getComponent(e, api.type.ComponentType.PLAYER) ~= nil
			end)
			if not (okP and isP) then
				if U.coStaleTxt ~= txt then
					U.coStaleTxt = txt
					log("companies.txt names entity " .. tostring(e) .. ", no company in this world: a file of the world before, left")
				end
				U.coMap, U.myCo, U.coNames, U.coColors, U.ranks, U.canon = {}, nil, {}, {}, nil, nil
				U.coTxt = nil
				return
			end
		end
	end
	U.coColors = colors
	U.coMap = map
	U.coNames = names
	U.ranks = nRanks > 1 and ranks or nil
	for e, id in pairs(map) do if id == 1 then U.canon = e end end
	if U.canon and not U.coPatched then
		U.coPatched = true
		local okp, errp = pcall(patchGameModules)
		if not okp then log("companies: patching the game modules failed: " .. tostring(errp)) end
	end
	log("companies known to the interface: " .. txt:gsub(C.NL, " "))
end

-- Mixed modes, bankruptcy, auctions, rules (0.5.0): eco.txt, written by the bridge (see its G.coEco)
U.pollEco = function()
	local f = C.IO.open(C.DIR .. C.BS .. "eco.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.ecoTxt then return end
	U.ecoTxt = txt
	-- (stops, depotco: each company's rule for its stops and stations, and for its depots, shown in the window's Rules tab)
	local e = { members = {}, chief = {}, gone = {}, debt = {}, track = {}, fees = {}, requests = {}, merges = {}, depots = {}, stops = {}, depotco = {}, ai = {}, road = {}, paid = {} }
	local TAB = C.TAB
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local f1 = {}
		for x in (line .. TAB):gmatch("([^" .. TAB .. "]*)" .. TAB) do f1[#f1 + 1] = x end
		local k = f1[1]
		if k == "mykey" then e.myKey = f1[2]
		elseif k == "rules" then e.bankrupt = tonumber(f1[2])
		elseif k == "share" then e.share = f1[2] ~= "0"
		elseif k == "start" then e.start = tonumber(f1[2])
		elseif k == "auctionrule" then e.auctionRule = f1[2]
		elseif k == "member" then local id = tonumber(f1[2]); e.members[id] = e.members[id] or {}; table.insert(e.members[id], f1[3])
		elseif k == "chief" then e.chief[tonumber(f1[2])] = f1[3]
		elseif k == "gone" then e.gone[tonumber(f1[2])] = f1[3]
		elseif k == "ai" then e.ai[tonumber(f1[2]) or -1] = true
		elseif k == "debt" then e.debt[tonumber(f1[2])] = tonumber(f1[3])
		elseif k == "track" then e.track[tonumber(f1[2])] = { rule = f1[3], toll = tonumber(f1[4]) or 0 }
		elseif k == "road" then e.road[tonumber(f1[2]) or -1] = { rule = f1[3] }
		elseif k == "fees" then e.fees[tonumber(f1[2])] = { si = tonumber(f1[3]) or 0, se = tonumber(f1[4]) or 0, ti = tonumber(f1[5]) or 0, te = tonumber(f1[6]) or 0 }
		elseif k == "req" then e.requests[#e.requests + 1] = { key = f1[2], name = f1[3], to = tonumber(f1[4]) }
		elseif k == "merge" then e.merges[#e.merges + 1] = { from = tonumber(f1[2]), to = tonumber(f1[3]) }
		-- (0.8.3) the loans' offers and the loans under way (see U.loanCard)
		elseif k == "loanoffer" then
			e.loanOffers = e.loanOffers or {}
			e.loanOffers[#e.loanOffers + 1] = { id = tonumber(f1[2]), borrower = tonumber(f1[3]), lender = tonumber(f1[4]), amount = tonumber(f1[5]) or 0,
				months = tonumber(f1[6]) or 0, rate = tonumber(f1[7]) or 0, turn = f1[8] }
		elseif k == "loan" then
			e.loans = e.loans or {}
			e.loans[#e.loans + 1] = { id = tonumber(f1[2]), borrower = tonumber(f1[3]), lender = tonumber(f1[4]), rest = tonumber(f1[5]) or 0,
				monthly = tonumber(f1[6]) or 0, total = tonumber(f1[7]) or 0 }
		elseif k == "auction" then
			e.auction = { seq = tonumber(f1[2]), co = tonumber(f1[3]), idx = tonumber(f1[4]), n = tonumber(f1[5]), kind = f1[6], label = f1[7],
				reserve = tonumber(f1[8]) or 0, best = tonumber(f1[9]) or 0, bidder = tonumber(f1[10]) or 0, left = tonumber(f1[11]) or 0, min = tonumber(f1[12]) or 0 }
		elseif k == "auction2" then
			-- (0.7.4) every lot at once, one clock (see the bridge's G.coEco); its lots follow as "lot" lines
			e.auction2 = { seq = tonumber(f1[2]), co = tonumber(f1[3]), mode = f1[4], minutes = tonumber(f1[5]) or 5, left = tonumber(f1[6]) or 0,
				n = tonumber(f1[7]) or 0, bids = tonumber(f1[8]) or 0, lots = {}, at = os.clock() }
		elseif k == "lotd" and e.auction2 then
			-- (what the lot holds, its lines of text separated by "||", and an entity the camera goes to)
			local d = { focus = tonumber(f1[3]), lines = {} }
			for x in ((f1[4] or "") .. "||"):gmatch("(.-)||") do if x ~= "" then d.lines[#d.lines + 1] = x end end
			e.auction2.detail = e.auction2.detail or {}
			e.auction2.detail[tonumber(f1[2]) or -1] = d
		elseif k == "lot" and e.auction2 then
			e.auction2.lots[#e.auction2.lots + 1] = { idx = tonumber(f1[2]), kind = f1[3], label = f1[4], reserve = tonumber(f1[5]) or 0, best = tonumber(f1[6]) or 0,
				bidder = tonumber(f1[7]) or 0, min = tonumber(f1[8]) or 0, vehicles = tonumber(f1[9]) or 0, bids = tonumber(f1[10]) or 0, key = f1[11],
				lines = tonumber(f1[12]) or 0, stations = tonumber(f1[13]) or 0, depots = tonumber(f1[14]) or 0 }
		elseif k == "depot" then e.depots[f1[2]] = { rule = f1[3], toll = tonumber(f1[4]) or 0, co = tonumber(f1[5]) }
		elseif k == "stops" then e.stops[tonumber(f1[2])] = { rule = f1[3], fee = tonumber(f1[4]) or 0, own = tonumber(f1[5]) or 0 }
		elseif k == "depotco" then e.depotco[tonumber(f1[2])] = { rule = f1[3], toll = tonumber(f1[4]) or 0 }
		elseif k == "paid" then e.paid[#e.paid + 1] = { from = tonumber(f1[2]), to = tonumber(f1[3]), kind = f1[4], amount = tonumber(f1[5]) or 0 }
		end
	end
	U.eco = e
	U.ecoVersion = (U.ecoVersion or 0) + 1
	pcall(U.paidNotice, e)
end

-- (0.6.8, #115) what this company paid to each other company: { [to] = { s = stations' fees, t = tracks' tolls, d = depots' tolls } }
U.paidBy = function(eco, my)
	local out = {}
	for _, p in ipairs((eco and eco.paid) or {}) do
		if p.from == my and p.to and p.to ~= my then
			local t = out[p.to] or { s = 0, t = 0, d = 0 }
			t[p.kind] = (t[p.kind] or 0) + p.amount
			out[p.to] = t
		end
	end
	return out
end
-- a line in the chat the first time this session this company pays another one (what it had paid at the load is not told):
-- a player could not tell that a toll was paid, nor to whom. MPFEVER_PAIDNOTICE=0: no line
U.paidNotice = function(eco)
	if os.getenv("MPFEVER_PAIDNOTICE") == "0" or not U.myCo then return end
	local by = U.paidBy(eco, U.myCo)
	local first = U.paidSeen == nil
	U.paidSeen = U.paidSeen or {}
	local told = {}
	for to, t in pairs(by) do
		local sum = t.s + t.t + t.d
		local was = U.paidSeen[to]
		U.paidSeen[to] = sum
		if not first and sum > (was or 0) and not (U.paidTold or {})[to] then
			U.paidTold = U.paidTold or {}
			U.paidTold[to] = true
			local what = {}
			-- (0.8.1: C.T, "local T" is declared further down: T here was the global, nil, and this notice never showed)
			if t.s > 0 then what[#what + 1] = C.T("ses gares", "its stations") end
			if t.t > 0 then what[#what + 1] = C.T("ses voies", "its tracks") end
			if t.d > 0 then what[#what + 1] = C.T("ses dépôts", "its depots") end
			told[#told + 1] = C.Tf("Votre entreprise paie %s pour utiliser %s (le détail : fenêtre MPFever, Entreprise, Gains et frais).",
				"Your company pays %s to use %s (the details: MPFever window, Company, Earnings and fees).", U.aiCoName(to), table.concat(what, ", "))
		end
	end
	if #told == 0 then return end
	U.chat = U.chat or {}
	for _, x in ipairs(told) do U.chat[#U.chat + 1] = { id = 0, t = os.time(), kind = "ai", name = "MPFever", text = x } end
	while #U.chat > 100 do table.remove(U.chat, 1) end
	U.chatVersion = (U.chatVersion or 0) + 1
end

-- The companies' rules for their stations and depots (0.5.2: the "stops", "depotco" and "gone" lines of eco.txt, see the bridge's
-- G.coEco), for the station and depot windows and the line tool: U.rules = { stops = { [co] = { rule, fee, own } },
-- depotCo = { [co] = { rule, toll } }, gone = { [co] = true } } (own: how many of the company's stations have a setting of
-- their own). Read at most twice a second, apart from U.pollEco (the MPFever window's view of the same file).
U.pollRules = function(force)
	local now = os.clock()
	if not force and U.rulesAt and now - U.rulesAt < 0.5 then return end
	U.rulesAt = now
	local f = C.IO.open(C.DIR .. C.BS .. "eco.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.rulesTxt then return end
	U.rulesTxt = txt
	local r = { stops = {}, depotCo = {}, gone = {} }
	local TAB = C.TAB
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local f1 = {}
		for x in (line .. TAB):gmatch("([^" .. TAB .. "]*)" .. TAB) do f1[#f1 + 1] = x end
		local id = tonumber(f1[2])
		if id and f1[1] == "stops" then r.stops[id] = { rule = f1[3], fee = tonumber(f1[4]) or 0, own = tonumber(f1[5]) or 0 }
		elseif id and f1[1] == "depotco" then r.depotCo[id] = { rule = f1[3], toll = tonumber(f1[4]) or 0 }
		elseif id and f1[1] == "gone" then r.gone[id] = true
		elseif f1[1] == "share" then r.off = f1[2] == "0" end
	end
	U.rules = r
	U.rulesVersion = (U.rulesVersion or 0) + 1
end

-- an MPFever event of the interface (applied by every game at the same step: see mpfever_eco.lua)
U.coSend = function(name, param)
	local ok, err = pcall(function() api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", name, param or {})) end)
	log("companies: " .. name .. " requested" .. (ok and "" or (": " .. tostring(err))))
	return ok
end

-- The loans of a company other than the savegame's: the game's loan window reads the loan script's state, which holds the
-- savegame company's loans only. The loans of this player's company (loanview.txt, written by the game-script bridge) are given to
-- it instead, when it asks for that script's state.
local function pollLoanView()
	local f = C.IO.open(C.DIR .. C.BS .. "loanview.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.loanTxt then return end
	U.loanTxt = txt
	U.loanView = (txt ~= "") and C.deser(txt) or nil
	if U.loanView and not U.getCompWrapped then
		U.getCompWrapped = true
		local orig = api.engine.getComponent
		api.engine.getComponent = function(e, ct, ...)
			if U.loanView and ct == api.type.ComponentType.GAME_SCRIPT then
				if U.loanEntity == nil then
					local ok, ent = pcall(api.engine.system.gameScriptSystem.getEntityForGameScript, "::/game_mechanics/finance/loan.gs")
					U.loanEntity = ok and ent or false
				end
				if U.loanEntity and e == U.loanEntity then return { state = U.loanView } end
			end
			return orig(e, ct, ...)
		end
		log("companies: the loan window shows this company's loans")
	end
end

-- ---------------------------------------------------------------- owner of what the player clicks (companies mode)
-- Every entity window (station, depot, vehicle, line, building...) shows on its first line which company it belongs to. The game's
-- window maker is wrapped: its result is put under a line of text (no button, nothing else changes).
local T = C.T

local function ownerOf(e)
	if type(e) ~= "number" or e < 0 then return nil end
	local function po(x)
		local ok, c = pcall(api.engine.getComponent, x, api.type.ComponentType.PLAYER_OWNED)
		return (ok and c and type(c.player) == "number" and c.player >= 0) and c.player or nil
	end
	local p = po(e)
	if p then return p end
	local okg, sg = pcall(api.engine.getComponent, e, api.type.ComponentType.STATION_GROUP)
	if okg and sg then
		local okf, first = pcall(function() return sg.stations[1] end)
		if okf and type(first) == "number" then
			p = po(first)
			if p then return p end
			e = first
		end
	end
	local okc, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction, e)
	if okc and type(con) == "number" and con >= 0 then return po(con) end
	return nil
end

local function companyName(ent)
	local name = nil
	pcall(function()
		local n = api.engine.getComponent(ent, api.type.ComponentType.NAME)
		if n and type(n.name) == "string" and n.name ~= "" then name = n.name end
	end)
	if not name and U.coNames and U.coNames[ent] and U.coNames[ent] ~= "" then name = U.coNames[ent] end
	if not name then name = C.Tf("Entreprise %s", "Company %s", U.coMap and U.coMap[ent] or "?") end
	return name
end

-- the stations with a setting of their own (shares.txt, written by the game-script bridge): station key -> { rule, fee per stop }
-- (0.5.2: "key TAB rule TAB fee" lines; a line "key TAB fee" of an older file: fee 0 private, else that toll)
local function pollShares()
	local f = C.IO.open(C.DIR .. C.BS .. "shares.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.shareTxt then return end
	U.shareTxt = txt
	local t = {}
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local k, rule, fee = line:match("^(.-)" .. C.TAB .. "(%a+)" .. C.TAB .. "(%d+)$")
		if k then
			t[k] = { rule = rule, fee = tonumber(fee) or 0 }
		else
			local k2, fee2 = line:match("^(.-)" .. C.TAB .. "(%d+)$")
			local n = tonumber(fee2) or 0
			if k2 then t[k2] = { rule = n > 0 and "toll" or "private", fee = n } end
		end
	end
	U.stationRules = t
	U.shareVersion = (U.shareVersion or 0) + 1
end

-- the tolls per stop the station window offers
local SHARE_FEES = { 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000 }

local function money(n)
	local ok, s = pcall(api.util.formatMoney, n)
	return ok and tostring(s) or tostring(n)
end

-- The rule of a station (its key, nil when no station has a setting of its own) of company `co` for the other companies, read as
-- mpfever_eco.lua's stationRule reads it in the game (from shares.txt and eco.txt): rule ("private" | "open" | "toll"), fee per
-- stop, and whether it is the station's own setting (else its company's rule). nil when no company owns it.
U.stationRuleOf = function(key, co)
	if not co then return nil, 0, false end
	-- (the sharing rules switched off by the host, 0.5.14: everything open and free)
	if U.rules and U.rules.off then return "open", 0, false end
	local openDefault = os.getenv("MPFEVER_OPENDEFAULT") ~= "0"
	local rs = U.rules or {}
	if openDefault and rs.gone and rs.gone[co] then return "open", 0, false end
	local function norm(rule, fee)
		fee = math.floor(tonumber(fee) or 0)
		if rule == "toll" then
			if fee > 0 then return "toll", fee end
			return "open", 0
		end
		if rule == "private" then return "private", 0 end
		return "open", 0
	end
	local o = key and U.stationRules and U.stationRules[key]
	if o then
		local r, f = norm(o.rule, o.fee)
		return r, f, true
	end
	local s = rs.stops and rs.stops[co]
	if s then
		local r, f = norm(s.rule, s.fee)
		return r, f, false
	end
	if openDefault then return "open", 0, false end
	return "toll", C.SHARE_DEFAULT, false
end

-- a station's choice in its window: "co" (no setting of its own), "open", "private" or "toll:<fee>"
U.stationChoice = function(key)
	local o = key and U.stationRules and U.stationRules[key]
	if not o then return "co" end
	if o.rule == "toll" then return (tonumber(o.fee) or 0) > 0 and ("toll:" .. math.floor(o.fee)) or "open" end
	if o.rule == "private" then return "private" end
	return "open"
end

-- (the lines of other companies that already stop at a private station pay this per stop there, see mpfever_eco.lua)
U.privateFee = function() return os.getenv("MPFEVER_PRIVATEFEE") ~= "0" and C.SHARE_DEFAULT or nil end

-- what the rule line of a station window says: for its company (mine) or for the others; own: the station's own setting, else
-- its company's rule
local function shareText(mine, rule, fee, own)
	local t
	if mine then
		if rule == "toll" then t = T("Péage pour les autres entreprises : ", "Toll for the other companies: ") .. money(fee) .. T(" par arrêt", " per stop")
		elseif rule == "private" then t = T("Privée (les autres entreprises ne peuvent pas l'ajouter à leurs lignes)", "Private (the other companies cannot add it to their lines)")
		else t = T("Ouverte aux autres entreprises, sans péage", "Open to the other companies, no toll") end
	else
		if rule == "toll" then t = T("Péage : ", "Toll: ") .. money(fee) .. T(" par arrêt de vos véhicules", " per stop of your vehicles")
		elseif rule == "private" then
			local pf = U.privateFee()
			t = pf and C.Tf("Privée : vos lignes ne peuvent pas l'ajouter, celles qui s'y arrêtent déjà paient %s par arrêt", "Private: your lines cannot add it, those already stopping here pay %s per stop", money(pf))
				or T("Privée : vos lignes ne peuvent pas s'y arrêter", "Private: your lines cannot stop here")
		else t = T("Ouverte : vos véhicules s'y arrêtent sans péage", "Open: your vehicles stop here without a toll") end
	end
	if not own then t = t .. T(" (règle de l'entreprise)", " (company rule)") end
	return t
end

-- the rule line of a station window: what a stop there costs the other companies (nil when not a station)
local function shareInfo(e, owner)
	local okg, sg = pcall(R.stationGroupOf, e)
	if not (okg and sg) then return nil end
	local okk, key = pcall(R.sgKey, sg)
	if not (okk and type(key) == "string") then return nil end
	local co = U.coMap and U.coMap[owner]
	pcall(U.pollRules)
	local rule, fee, own = U.stationRuleOf(key, co)
	if not rule then return nil end
	local mine = U.myCo ~= nil and co == U.myCo
	-- (a station known by its entity id only, which may be another station on another game: no setting of its own for it, the
	-- bridge refuses it, see its 'share' event. MPFEVER_IDKEYCHECK=0: as before)
	local idKey = key:sub(1, 3) == "id:" and os.getenv("MPFEVER_IDKEYCHECK") ~= "0"
	return { key = key, co = co, rule = rule, fee = fee, own = own, mine = mine, text = shareText(mine, rule, fee, own), canEdit = mine and not idKey }
end

-- the station group of what the line tool points at (a station, its construction, its group, or the street of a street stop)
local function sharedGroupOf(e)
	local okg, sg = pcall(R.stationGroupOf, e)
	if okg and sg then return sg end
	local found = nil
	pcall(function()
		local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		for _, o in ipairs(edge and edge.objects or {}) do
			local oe = o[1] or o.entity
			if type(oe) == "number" and api.engine.getComponent(oe, api.type.ComponentType.STATION) then
				found = R.stationGroupOf(oe)
				if found then return end
			end
		end
	end)
	return found
end

-- the rule of another company's station for this machine's company: rule, fee per stop, whether it is the station's own setting;
-- nil when the station is not another company's (its key is read only when some station has a setting of its own)
local function foreignRule(sg)
	if not (U.coMap and type(sg) == "number") then return nil end
	local owner = ownerOf(sg)
	local co = owner and U.coMap[owner]
	if not co or co == U.myCo then return nil end
	local key = nil
	if U.stationRules and next(U.stationRules) ~= nil then
		local okk, k = pcall(R.sgKey, sg)
		if okk then key = k end
	end
	return U.stationRuleOf(key, co)
end

-- The line windows and tooltips name the stations: another company's station shows its rule (0.5.2: open, a toll per stop, or
-- private; before, its fee or "not shared")
local function installStopFees()
	if U.stopFeesInstalled then return end
	U.stopFeesInstalled = true
	local function decorate(orig)
		return function(e, ...)
			local name = orig(e, ...)
			if type(name) ~= "string" or type(e) ~= "number" then return name end
			local okc, isSg = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.STATION_GROUP) ~= nil end)
			if not (okc and isSg) then return name end
			local okf, rule, fee = pcall(foreignRule, e)
			if not okf or rule == nil then return name end
			if rule == "toll" then return name .. T("  [péage : ", "  [toll: ") .. money(fee) .. T(" par arrêt]", " per stop]") end
			if rule == "private" then return name .. T("  [privée]", "  [private]") end
			return name .. T("  [ouverte]", "  [open]")
		end
	end
	local okE, eu = pcall(ug_require, "/scripts/entity_util.tl")
	if okE and type(eu) == "table" and type(eu.getEntityName) == "function" and not eu.__mpfFees then
		eu.__mpfFees = true
		eu.getEntityName = decorate(eu.getEntityName)
	end
	local util = api.engine.util
	if type(util.getEntityName) == "function" and not U.engineNameWrapped then
		U.engineNameWrapped = true
		util.getEntityName = decorate(util.getEntityName)
	end
	log("companies: the line windows show the fee of the other companies' stations")
end

-- The terrain tools apply their edit at once on this game (the native module cannot hold them, see the bridge): while one is in
-- the player's hand, the other games stay a few steps behind this one, so that an edit always reaches them before its time. The
-- construction menu makes the tool's action with construction_react_util.getActionParams: a terrain tool there means one is in
-- hand (said at most once a second; the bridge keeps the lead a while after the last word or edit).
local function installTerrainWatch()
	if U.terrainWatch then return end
	U.terrainWatch = true
	local ok, cu = pcall(ug_require, "/gui/construction/construction_react_util.tl")
	if not (ok and type(cu) == "table" and type(cu.getActionParams) == "function") then
		log("terrain tools: not watched (" .. tostring(cu):sub(1, 120) .. ")")
		return
	end
	if cu.__mpfTerrain then return end
	cu.__mpfTerrain = true
	local orig = cu.getActionParams
	cu.getActionParams = function(definition, ...)
		pcall(function()
			local a = definition and definition.action
			if type(a) == "string" and a:find("ACTION_TERRAIN_MODIFIER_", 1, true) == 1 then
				local now = os.clock()
				if not U.terrainSaidAt or now - U.terrainSaidAt > 1 then
					U.terrainSaidAt = now
					sendLine("terrain_tool", { tool = a })
				end
			end
		end)
		return orig(definition, ...)
	end
	log("terrain tools: watched (the other games stay behind this one while a terrain tool is in hand)")
end

-- The line tool lets a company pick only its own stations (entity_util.isOwnedByPlayerOrNotOwned): a station of another company
-- that is not private (0.5.2: open by default, or a toll per stop; its own setting or its company's rule) can be picked too. The
-- toll is booked by the game-script bridge at every stop.
local function installShareSelect()
	if U.shareSelectInstalled then return end
	local okE, eu = pcall(ug_require, "/scripts/entity_util.tl")
	if not (okE and type(eu) == "table" and type(eu.isOwnedByPlayerOrNotOwned) == "function") then
		U.shareSelectInstalled = true
		log("companies: shared stations cannot be picked by the line tool (" .. tostring(eu):sub(1, 120) .. ")")
		return
	end
	U.shareSelectInstalled = true
	if eu.__mpfShare then return end
	eu.__mpfShare = true
	local orig = eu.isOwnedByPlayerOrNotOwned
	local cache, cacheAt = {}, -1
	eu.isOwnedByPlayerOrNotOwned = function(entity, ...)
		if orig(entity, ...) then return true end
		if not U.coMap or type(entity) ~= "number" then return false end
		local now = os.clock()
		if now - cacheAt > 1 then cache = {}; cacheAt = now end
		local v = cache[entity]
		if v == nil then
			v = false
			local sg = sharedGroupOf(entity)
			if sg then
				local rule = foreignRule(sg)
				v = rule ~= nil and rule ~= "private"
			end
			-- a street the tool points at: a stop by that street of another company that is not private (0.5.2: every stop on it,
			-- by its rule; before, only those with a fee of their own), or one whose setting's key starts with the street's ends
			if not v then
				pcall(function()
					local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
					if not edge then return end
					-- (copied at once: a component read is only valid until the next one)
					local n0, n1, objs = edge.node0, edge.node1, {}
					for _, o in ipairs(edge.objects or {}) do objs[#objs + 1] = o[1] or o.entity end
					for _, oe in ipairs(objs) do
						if not v and type(oe) == "number" and api.engine.getComponent(oe, api.type.ComponentType.STATION) then
							local g = R.stationGroupOf(oe)
							local rule = g and foreignRule(g)
							if rule and rule ~= "private" then v = true end
						end
					end
					if v then return end
					local function r(x) return string.format("%.0f", x or 0) end
					local function np(n) local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE); return c and c.position end
					local p0 = np(n0)
					local q0 = p0 and { x = p0.x, y = p0.y }
					local p1 = np(n1)
					local q1 = p1 and { x = p1.x, y = p1.y }
					if not (q0 and q1) then return end
					local a, b = r(q0.x) .. "," .. r(q0.y), r(q1.x) .. "," .. r(q1.y)
					if a > b then a, b = b, a end
					local prefix = "e:" .. a .. "-" .. b .. ":"
					for k, o in pairs(U.stationRules or {}) do
						if o.rule ~= "private" and k:sub(1, #prefix) == prefix then v = true end
					end
				end)
			end
			cache[entity] = v
		end
		return v
	end
	log("companies: the line tool can pick the stations shared by the other companies")
end

-- a depot's rule (0.5.0): its construction's key, as mpfever_eco.lua knows it ("D:<file>@x,y"), and whether this company owns it
U.depotInfo = function(e, owner)
	local con = e
	pcall(function()
		local c = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(e)
		if type(c) == "number" and c >= 0 then con = c end
	end)
	local ok, key = pcall(function()
		local c = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
		if not (c and c.depots and #c.depots > 0) then return nil end
		local t = c.transf
		return "D:" .. tostring(c.fileName) .. "@" .. string.format("%.0f,%.0f", t[13], t[14])
	end)
	if not (ok and key) then return nil end
	local mine = U.myCo ~= nil and owner ~= nil and U.coMap and U.coMap[owner] == U.myCo
	-- (co: the depot's company, whose rule for its depots applies when the depot has no setting of its own, 0.5.2)
	return { key = key, canEdit = mine, co = owner ~= nil and U.coMap and U.coMap[owner] or nil }
end

-- a station's setting (the bridge's 'share' event, 0.5.2): rule "co" (its company's rule), "open", "private" or "toll" (fee)
local function sendShare(key, rule, fee)
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "share", { key = key, rule = rule, fee = fee or 0 }))
	end)
	if not ok then log("companies: share request failed: " .. tostring(err)) end
end

local function ownerText(e)
	if not U.coMap then return nil end
	local n = 0
	for _ in pairs(U.coMap) do n = n + 1 end
	if n < 2 then return nil end
	local owner = ownerOf(e)
	if not owner or not U.coMap[owner] then return nil end
	local mine = U.myCo ~= nil and U.coMap[owner] == U.myCo
	return T("Propriétaire : ", "Owner: ") .. companyName(owner) .. (mine and T(" (vous)", " (you)") or ""), owner
end

-- The map's icons of what a company owns (stations, depots, buildings) get a small square of that company's colour beside them,
-- when there is more than one company: the game's default icon (builtin.UseDefaultHudIcon, looked up at every render) is wrapped.
-- The owner of an icon's entity is kept 3 seconds.
local function installHudColors(builtin)
	if U.hudColorsInstalled then return end
	U.hudColorsInstalled = true
	if os.getenv("MPFEVER_NOHUDCOLORS") == "1" or type(builtin.UseDefaultHudIcon) ~= "function" then return end
	local okC, CO = pcall(ug_require, "mpfever_co.lua")
	if not okC then okC, CO = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
	if not (okC and type(CO) == "table" and CO.rgb) then log("companies: icon colours not shown (mpfever_co.lua)") return end
	local orig = builtin.UseDefaultHudIcon
	local cache, swatches = {}, {}
	local function colorOf(e)
		if type(e) ~= "number" or e < 0 or not U.coMap then return nil end
		local n = 0
		for _ in pairs(U.coMap) do n = n + 1 if n > 1 then break end end
		if n < 2 then return nil end
		local now = os.clock()
		local c = cache[e]
		if not c or now - c.at > 3 then
			local owner = nil
			pcall(function() owner = ownerOf(e) end)
			local id = owner and U.coMap[owner] or nil
			c = { at = now, ix = id and (U.coColors and U.coColors[id] or id) or false }
			cache[e] = c
		end
		return c.ix or nil
	end
	builtin.UseDefaultHudIcon = function(params, ...)
		local base = orig(params, ...)
		local okI, ix = pcall(colorOf, params and params.entity)
		if not (okI and ix) then return base end
		local sw = swatches[ix]
		if sw == nil then
			sw = false
			pcall(function()
				local r, g, b = CO.rgb(ix)
				local st = api.gui.StyleSheet.new()
				st.size = api.type.Vec2f.new(10, 10)
				st.backgroundColor1 = api.type.Vec4f.new(r, g, b, 1)
				local n = api.gui.NinePatch.new()
				n.fileName = "::/gui/line_vehicle_mgmt/icons/line_surface.tga"
				st.backgroundImage1 = n
				sw = st
			end)
			swatches[ix] = sw
		end
		if not sw then return base end
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal,
			children = { builtin.Component { meta = { styleSheet = sw } }, base } }
	end
	log("companies: the map's icons show their company's colour")
end

-- The other companies' vehicles get a dot of their company's colour floating over them (0.6.10, a Discord suggestion of 2026-11-01:
-- in a game with one company per player, whose bus is this?). Their stations, depots and buildings have their colour already
-- (the square beside their icon, installHudColors). Every U.DOTS_EVERY seconds, the vehicles of another company within
-- U.DOTS_RANGE metres of the camera's centre, the U.DOTS_MAX nearest, are listed; at every frame each gets the game's short-lived
-- HUD image (api.gui.spawnEphemeralHudImage, as the towns' happy faces): mpfever_dot.tga, a white disc tinted with that company's
-- colour, U.DOTS_LIFT metres above where the vehicle is now, lasting a little more than that frame. The image stays where it was
-- put (the autotest ko4's screenshots: a dot left behind a moving truck), and one given the vehicle without a place shows nowhere
-- (autotests dm1 to dm3, 0.6.11, whatever its revision): 0.6.10 put them again 4 times a second, and they jumped behind their
-- vehicles (the user's test of 2026-11-03), hence every frame now. The game's own grey icons are opaque (their corners black):
-- they showed as dark squares. Nothing while there is one company, nor with the camera higher than U.DOTS_HEIGHT (the map's icons
-- then). The Settings tab turns them off ("dots" in the ui_prefs.txt kept across launches). An owner is read once per vehicle.
-- MPFEVER_DOTS=0: never; MPFEVER_DOTSSMOOTH=0: put again with the list only, 80 at most, as in 0.6.10.
U.DOTS_EVERY, U.DOTS_RANGE, U.DOTS_MAX, U.DOTS_HEIGHT, U.DOTS_LIFT = 0.25, 2000, 30, 2500, 6
U.DOTS_ICON = "mpfever_1::/mpfever_dot.tga"
-- (the list of the dots to draw, rebuilt every U.DOTS_EVERY seconds: { vehicle, colour, company } each, nil while none are shown)
U.dotsList = function(now, smooth)
	U.dotsNear = nil
	local n = 0
	for _ in pairs(U.coMap) do n = n + 1 end
	if n < 2 then return end
	if U.dotsCO == nil then
		local ok, m = pcall(ug_require, "mpfever_co.lua")
		if not ok then ok, m = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
		U.dotsCO = (ok and type(m) == "table" and m.rgb) and m or false
		if not U.dotsCO then log("companies: vehicle dots not shown (mpfever_co.lua)") end
	end
	if not U.dotsCO then return end
	local okC, c = pcall(api.gui.camera.getCenter)
	local okH, h = pcall(api.gui.camera.getHeightAboveTerrain)
	local cam = os.getenv("MPFEVER_DOTSCAM") == "1"
	if not (okC and c) or (not cam and okH and type(h) == "number" and h > U.DOTS_HEIGHT) then return end
	-- (the owners read again every minute: a sold vehicle's id goes to the next one bought, maybe another company's)
	if not U.dotOwner or now - (U.dotOwnerAt or 0) > 60 then U.dotOwner, U.dotOwnerAt = {}, now end
	local own, near, r2 = U.dotOwner, {}, U.DOTS_RANGE * U.DOTS_RANGE
	local cx, cy = c.x, c.y
	pcall(api.engine.forEachEntityWithComponent, function(v)
		local id = own[v]
		if id == nil then
			local p = ownerOf(v)
			id = p and U.coMap[p] or false
			own[v] = id
		end
		if not id or id == U.myCo then return end
		if cam and not U.dotsAny then U.dotsAny = v end
		local okP, pos = pcall(api.engine.util.vehicle.getPosition, v)
		if not (okP and pos) then return end
		local dx, dy = pos.x - cx, pos.y - cy
		local d2 = dx * dx + dy * dy
		if d2 <= r2 then near[#near + 1] = { v, d2, id } end
	end, api.type.ComponentType.TRANSPORT_VEHICLE)
	table.sort(near, function(a, b) return a[2] < b[2] end)
	local list, max = {}, smooth and U.DOTS_MAX or 80
	for i = 1, math.min(#near, max) do
		local id = near[i][3]
		local ix = U.coColors and U.coColors[id] or id
		local ok, r, g, b = pcall(U.dotsCO.rgb, ix)
		if ok then list[#list + 1] = { near[i][1], api.type.Vec4f.new(r, g, b, 1), id } end
	end
	if #list > 0 then U.dotsNear = list end
	-- (MPFEVER_DOTSCAM=1, the autotests: with none near, the camera goes to another company's vehicle first; then it follows the
	-- nearest one once, for a screenshot of its dot)
	if cam and #list == 0 and U.dotsAny and not U.dotsMoved then
		U.dotsMoved = true
		local okF = pcall(api.gui.camera.followEntity, U.dotsAny, true)
		log("companies: dots test: no vehicle of another company near the camera, it goes to vehicle " .. tostring(U.dotsAny) .. (okF and "" or " (refused)"))
	end
	if #list > 0 and not U.dotsCam and cam then
		U.dotsCam = true
		local okF = pcall(api.gui.camera.followEntity, list[1][1], true)
		log("companies: dots test: the camera follows vehicle " .. tostring(list[1][1]) .. " of company " .. tostring(list[1][3]) .. (okF and "" or " (refused)"))
	end
end
-- Shown or not (0.6.12): off by default (the user's choice, 2026-11-04: their look is not good enough yet), on once the player
-- ticks them in the Settings tab ("vdots=1" in the ui_prefs.txt kept across launches). The "dots" key of 0.6.10 and 0.6.11 was
-- written "1" for everybody who changed any setting, so it says nothing about a choice and is left aside. MPFEVER_DOTS=0 or 1
-- (autotests) decides alone; MPFEVER_DOTSON=1: on by default as in 0.6.11 ("dots=0" still off).
U.dotsOn = function()
	local e = os.getenv("MPFEVER_DOTS")
	if e == "0" then return false end
	if e == "1" then return true end
	local p = U.loadPrefs()
	if p.vdots ~= nil then return p.vdots == "1" end
	if os.getenv("MPFEVER_DOTSON") == "1" then return p.dots ~= "0" end
	return false
end
U.dotsTick = function()
	if not U.dotsOn() or not U.coMap or not U.myCo then U.dotsNear = nil; return end
	local smooth = os.getenv("MPFEVER_DOTSSMOOTH") ~= "0"
	local now = os.clock()
	local listed = false
	if now - (U.dotsAt or -10) >= U.DOTS_EVERY then
		U.dotsAt = now
		listed = true
		U.dotsList(now, smooth)
	end
	local list = U.dotsNear
	if not list or not (smooth or listed) then return end
	-- (once a frame: the tick also runs on a timer)
	local dt = now - (U.dotsDrawAt or -10)
	if smooth and dt < 0.004 then return end
	U.dotsDrawAt = now
	local life = smooth and math.min(math.max(dt * 1.3, 0.02), 0.3) or U.DOTS_EVERY * 1.05
	local shown = 0
	for i = 1, #list do
		local d = list[i]
		local ok, err = pcall(function()
			local pos = api.engine.util.vehicle.getPosition(d[1])
			api.gui.spawnEphemeralHudImage(U.DOTS_ICON, d[1], d[2], api.type.Vec3f.new(pos.x, pos.y, pos.z + U.DOTS_LIFT), life, false, false)
		end)
		if ok then shown = shown + 1 elseif not U.dotsErrLogged then U.dotsErrLogged = true; log("companies: a dot refused: " .. tostring(err)) end
	end
	if not U.dotsLogged and shown > 0 then U.dotsLogged = true; log("companies: dots of their company's colour over " .. shown .. " vehicle(s) of the other companies near the camera") end
	-- (how often they are drawn, once, 10 s after the first: the frames of this PC)
	U.dotsDraws = (U.dotsDraws or 0) + 1
	U.dotsFirst = U.dotsFirst or now
	if not U.dotsRateLogged and now - U.dotsFirst >= 10 then
		U.dotsRateLogged = true
		log(string.format("companies: dots drawn %d times in %.1f s", U.dotsDraws, now - U.dotsFirst))
	end
end

-- (0.6, the game option "builtby" of mpfever_feat_journal.lua) the line « Built by X » (« ..., changed by Y ») of an entity's
-- window: a station or another construction from the registry the journal's interface half writes (feat_journal_builtby.txt, read
-- again at most every 2 s), a vehicle or a line made in a session from its creation key (bindings.log, U.rev). nil while the
-- option is off (the session's options, mp_status.txt), for what the registry does not know, and for a computer company's vehicle
-- or line (its purchases go through the host's game and carry the host's name). MPFEVER_FEAT=0: never.
U.featBuiltBy = function(e)
	if type(e) ~= "number" or e < 0 then return nil end
	local F, map = U.featView(U.status)
	if not (F and F.on(map, "builtby")) then return nil end
	local M = F.byId.journal
	if not (M and M.builtByText and M.builtByIndex) then return nil end
	local function say(what, txt)
		-- (once per thing asked: does the window's key match the registry's in game?)
		U.featBbSaid = U.featBbSaid or {}
		if U.featBbSaid[what] then return end
		U.featBbSaid[what] = true
		log("feat journal: built-by line of " .. what .. ": " .. tostring(txt or "not in the registry"))
	end
	-- a vehicle or a line made in a session
	local bk = U.rev and U.rev[e]
	if type(bk) == "string" and bk:match("^[VL]") then
		local owner = ownerOf(e)
		local co = owner and U.coMap and U.coMap[owner]
		pcall(U.pollEco)
		if co and U.eco and U.eco.ai and U.eco.ai[co] then return nil end
		local txt = M.creatorText(bk, T)
		say(bk, txt)
		return txt
	end
	-- a station (its group's key, as R.sgKey) or another construction (its file and place)
	local key = nil
	pcall(function()
		local sg = R.stationGroupOf(e)
		if sg then key = M.keyOfSg(R.sgKey(sg)) end
	end)
	if not key then
		pcall(function()
			local con = nil
			if api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) then con = e end
			local function try(sys, fn)
				if con then return end
				local okc, c = pcall(function() return api.engine.system[sys][fn](e) end)
				if okc and type(c) == "number" and c >= 0 then con = c end
			end
			try("streetConnectorSystem", "getConstructionEntityForDepot")
			try("streetConstructionSystem", "getConstructionEntityForStation")
			try("streetConnectorSystem", "getConstructionEntityForSubconstruction")
			local c = con and api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
			if c then key = M.conKey(tostring(c.fileName), c.transf[13], c.transf[14]) end
		end)
	end
	if not key then return nil end
	if not U.featBbIdx or os.clock() - (U.featBbAt or -10) > 2 then
		U.featBbAt = os.clock()
		local lines = {}
		local f = C.IO.open(C.DIR .. C.BS .. "feat_journal_builtby.txt", "rb")
		if f then
			for line in (f:read("*a") or ""):gmatch("[^" .. C.NL .. "]+") do lines[#lines + 1] = (line:gsub(C.CR, "")) end
			f:close()
		end
		U.featBbIdx = M.builtByIndex(lines)
	end
	local txt = M.builtByText(U.featBbIdx, key, T)
	say(key, txt)
	return txt
end
-- the session has the option builtby on: the entity windows' line is installed for it (nothing read while no option is on)
U.featWantsOwnerLine = function()
	if U.featOff or not (U.status and type(U.status.opts) == "string" and U.status.opts ~= "") then return false end
	local ok, on = pcall(function()
		local F, map = U.featView(U.status)
		return F ~= nil and F.on(map, "builtby")
	end)
	return ok and on == true
end

local function installOwnerLine(react, builtin)
	if U.ownerInstalled then return end
	U.ownerInstalled = true
	local okM, mew = pcall(ug_require, "/gui/entity_window/make_entity_window.tl")
	if not (okM and type(mew) == "table" and type(mew.makeEntityWindowContent) == "function") then
		log("companies: the entity windows cannot show their owner (" .. tostring(mew):sub(1, 120) .. ")")
		return
	end
	local Wrap = react.RegisterRecipe("MPFeverOwnerLine", function(p)
		-- the station's rule changes while the window is open (this player's choice, the owner's, its company's rule): read again
		-- from shares.txt and eco.txt
		local ver = react.useState(U.shareVersion or 0)
		local rver = react.useState(U.rulesVersion or 0)
		local pending = react.useState(nil)   -- the choice just made, until every game has applied it: { v, at }
		react.onStepTimer(function()
			local v = U.shareVersion or 0
			if ver:old() ~= v then ver:set(v) end
			if p.shareKey or p.depotKey then pcall(U.pollRules) end
			local rv = U.rulesVersion or 0
			if rver:old() ~= rv then rver:set(rv) end
			local pd = pending:old()
			if pd and (U.stationChoice(p.shareKey) == pd.v or os.clock() - pd.at > 10) then pending:set(nil) end
		end, 0.5)
		-- a depot's rule: its company's rule (0.5.2), private, open, open for a toll per vehicle (mpfever_eco.lua)
		local depotNow = react.useState(nil)
		react.onStepTimer(function()
			if not p.depotKey then return end
			pcall(U.pollEco)
			local d = U.eco and U.eco.depots and U.eco.depots[p.depotKey]
			local v = d and (d.rule == "toll" and ("toll:" .. tostring(d.toll)) or d.rule) or "co"
			if depotNow:old() ~= v then depotNow:set(v) end
		end, 1)
		local inner = nil
		if p.innerRecipe then inner = p.innerRecipe(p.innerParam)
		elseif p.innerBuiltin then inner = p.innerBuiltin({ entity = p.innerParam and p.innerParam.keyEntity }) end
		local children = { builtin.TextView { meta = { class = "font-scale-body" }, text = p.ownerText } }
		-- (0.6: « Built by » under the owner, see U.featBuiltBy)
		if p.builtByText then children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" }, text = p.builtByText } end
		-- (the sharing rules switched off by the host, 0.5.14: no setting here, everything is open and free)
		pcall(U.pollRules)
		if (p.shareKey or p.depotKey) and U.rules and U.rules.off then
			children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" }, text = T("Règles de partage désactivées par l'hôte : ouvert et gratuit pour toutes les entreprises.", "Sharing rules turned off by the host: open and free for every company.") }
		elseif p.shareKey then
			local rule, fee, own = U.stationRuleOf(p.shareKey, p.shareCo)
			if rule and p.shareEdit then
				-- the owner chooses the station's setting for the other companies' vehicles (0.5.2): its company's rule (shown
				-- in the item), open, private, or a toll per stop
				local pd = pending:old()
				local shown = pd and pd.v or U.stationChoice(p.shareKey)
				local cr, cf = U.stationRuleOf(nil, p.shareCo)
				local function itemText(v)
					if v == "co" then return C.Tf("Règle de l'entreprise : %s", "Company rule: %s", itemText(cr == "toll" and ("toll:" .. cf) or cr)) end
					if v == "open" then return T("Ouverte, sans péage", "Open, no toll") end
					if v == "private" then return T("Privée (vos lignes seulement)", "Private (your lines only)") end
					return money(tonumber(tostring(v):match("^toll:(%d+)$")) or 0) .. T(" par arrêt", " per stop")
				end
				local choices = { "co", "open", "private" }
				local listed = false
				for _, f in ipairs(SHARE_FEES) do
					choices[#choices + 1] = "toll:" .. f
					if shown == "toll:" .. f then listed = true end
				end
				-- (a toll set before, not in the list: shown too)
				if not listed and tostring(shown):find("^toll:") then choices[#choices + 1] = shown end
				local items = {}
				for _, v in ipairs(choices) do
					items[#items + 1] = builtin.ComboBoxItem { value = v, content = builtin.TextView { meta = { class = "font-scale-body" }, text = itemText(v) } }
				end
				local key = p.shareKey
				children[#children + 1] = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {
					builtin.TextView { meta = { class = "font-scale-body" }, text = T("Autres entreprises :  ", "Other companies:  ") },
					builtin.ComboBox {
						value = shown,
						items = items,
						onValueChange = function(v)
							if v == nil or v == shown then return end
							local n = tonumber(tostring(v):match("^toll:(%d+)$"))
							sendShare(key, n and "toll" or tostring(v), n or 0)
							pending:set({ v = v, at = os.clock() })
						end,
					},
				} }
				local note
				if pd then note = T("Modification en cours pour tous les joueurs…", "Applying for every player…")
				elseif rule == "toll" then note = T("Leurs véhicules paient ce montant à chaque arrêt ici ; vos lignes s'y arrêtent gratuitement.", "Their vehicles pay this at every stop here; your own lines stop for free.")
				elseif rule == "private" then
					local pf = U.privateFee()
					note = pf and C.Tf("Les autres entreprises ne peuvent pas l'ajouter à leurs lignes ; celles qui s'y arrêtent déjà paient %s par arrêt.", "The other companies cannot add it to their lines; those already stopping here pay %s per stop.", money(pf))
						or T("Les autres entreprises ne peuvent pas s'arrêter ici.", "The other companies cannot stop here.")
				else note = T("Les autres entreprises peuvent s'y arrêter sans péage.", "The other companies may stop here without a toll.") end
				children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" .. (pd and ", info" or "") }, text = note }
			elseif rule then
				children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" }, text = shareText(p.shareMine, rule, fee, own) }
			end
		end
		if p.depotKey and not (U.rules and U.rules.off) then
			local cur = depotNow:old() or "co"
			local function label(v)
				if v == "co" then
					-- (the depot's company's rule for its depots, 0.5.2)
					local dc = U.rules and U.rules.depotCo and U.rules.depotCo[p.depotCo]
					local r = dc and (dc.rule == "toll" and ("toll:" .. tostring(dc.toll)) or dc.rule)
						or (os.getenv("MPFEVER_OPENDEFAULT") ~= "0" and "open" or "private")
					if r == "co" then r = "open" end
					return C.Tf("Règle de l'entreprise : %s", "Company rule: %s", label(r))
				end
				if v == "private" then return T("Privé : vos véhicules seulement", "Private: your vehicles only") end
				if v == "open" then return T("Ouvert aux autres entreprises, gratuit", "Open to the other companies, free") end
				local n = tonumber(v:match("^toll:(%d+)$"))
				return C.Tf("Ouvert, péage de %s par véhicule acheté ou envoyé ici", "Open, a toll of %s per vehicle bought or sent here", money(n or 0))
			end
			if p.depotEdit then
				local items = {}
				for _, v in ipairs({ "co", "private", "open", "toll:500", "toll:1000", "toll:2000", "toll:5000", "toll:10000" }) do
					items[#items + 1] = builtin.ComboBoxItem { value = v, content = builtin.TextView { meta = { class = "font-scale-body" }, text = label(v) } }
				end
				local key = p.depotKey
				children[#children + 1] = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {
					builtin.TextView { meta = { class = "font-scale-body" }, text = T("Autres entreprises :  ", "Other companies:  ") },
					builtin.ComboBox {
						value = cur,
						items = items,
						onValueChange = function(v)
							if v == nil or v == cur then return end
							local toll = tonumber(tostring(v):match("^toll:(%d+)$"))
							U.coSend("co_depot_rule", { key = key, rule = toll and "toll" or v, toll = toll or 0 })
						end,
					},
				} }
			else
				children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" }, text = label(cur) }
			end
		end
		children[#children + 1] = inner
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = children }
	end)
	local orig = mew.makeEntityWindowContent
	mew.makeEntityWindowContent = function(entity, gameCtx, isMapEditor, isSandboxMode, skipConstruction, ...)
		local r = orig(entity, gameCtx, isMapEditor, isSandboxMode, skipConstruction, ...)
		if skipConstruction or type(r) ~= "table" or not (r.recipe or r.builtin) then return r end
		local target = r.replacedEntity or (type(r.param) == "table" and r.param.keyEntity) or entity
		local okt, txt, owner = pcall(ownerText, target)
		-- (0.6: the « Built by » line of the game option builtby, also with one company for everybody: then it is the window's only
		-- line; nil while the option is off, see U.featBuiltBy)
		local bb = nil
		if not U.featOff and U.status and type(U.status.opts) == "string" and U.status.opts ~= "" then
			local okb, b = pcall(U.featBuiltBy, target)
			if okb then bb = b end
		end
		local share, depot = nil, nil
		if not (okt and txt) then
			if not bb then return r end
			-- (no owner line: the « Built by » line alone, no rule of a station or a depot)
			txt, bb = bb, nil
		else
			local oks, sh = pcall(shareInfo, target, owner)
			if oks then share = sh end
			local okd, dp = pcall(U.depotInfo, target, owner)
			if okd then depot = dp end
		end
		local w = {}
		for k, v in pairs(r) do w[k] = v end
		w.recipe = Wrap
		w.builtin = nil
		w.param = { innerRecipe = r.recipe, innerBuiltin = r.builtin, innerParam = r.param, ownerText = txt, builtByText = bb,
			shareText = share and share.text or nil, shareKey = share and share.key or nil, shareFee = share and share.fee or nil,
			shareEdit = share and share.canEdit or nil, shareCo = share and share.co or nil, shareMine = share and share.mine or nil,
			depotKey = depot and depot.key or nil, depotEdit = depot and depot.canEdit or nil, depotCo = depot and depot.co or nil,
			keyEntity = type(r.param) == "table" and r.param.keyEntity or nil, meta = type(r.param) == "table" and r.param.meta or nil }
		return w
	end
	log("companies: the entity windows show their owner")
end

-- ---------------------------------------------------------------- the session: players, their link, the sync state
-- MPFever.exe writes mp_status.txt every second (the host's view, relayed to every player): "key=value" lines and one
-- "p=id TAB name TAB state TAB lag TAB role" line per player. It is shown in MPFever's own window, opened from MPFever's icon
-- in the game's bottom bar (coloured by the session's state, see U.barState) or from a card that MPFever puts in the game's
-- pause menu.

local function pollStatus()
	local now = os.clock()
	if U.statusAt and now - U.statusAt < 0.5 then return end
	U.statusAt = now
	local f = C.IO.open(C.DIR .. C.BS .. "mp_status.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.statusTxt then return end
	U.statusTxt = txt
	local st = { players = {} }
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		line = line:gsub(C.CR, "")
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k == "p" then
			-- (id, name, state, lag, role, and since 0.7.4 the percent of the host's game it has received while one is on its way)
			local f = {}
			for x in (v .. C.TAB):gmatch("([^" .. C.TAB .. "]*)" .. C.TAB) do f[#f + 1] = x end
			if #f >= 3 then st.players[#st.players + 1] = { id = f[1], name = f[2], state = f[3], lag = tonumber(f[4] or "") or 0, role = f[5] or "", pct = tonumber(f[6] or "") } end
		elseif k then
			st[k] = v
		end
	end
	U.status = st
	U.statusVersion = (U.statusVersion or 0) + 1
end

-- (0.8.4, issue #252) A speed request repeated by the interface frame after frame (a stream: the calls less than 0.5 s apart)
-- once the session took it and another player changed the speed since: not sent again. tybjo's game asked for the pause once
-- a second for two minutes (99 requests), so every speed jmm15 set was paused again within a second (28 times): something of
-- its interface kept asking for 0 while the engine ran. A new request (another speed, or the same one after a gap of 0.5 s: a
-- real click) is sent as before. The first held request logs where it came from (the next report names the caller).
-- MPFEVER_SPEEDREPEAT=0: as before (once a second)
U.speedRepeatHeld = function(v, now)
	if os.getenv("MPFEVER_SPEEDREPEAT") == "0" then return false end
	local stream = v == U.speedStreamV and now - (U.speedStreamAt or -10) < 0.5
	U.speedStreamV, U.speedStreamAt = v, now
	if not stream then U.speedStreamDone = false; return false end
	local cur = tonumber(U.status and U.status.speed)
	-- (the session took this request: from then on a speed other than it was set by another player)
	if cur == v then U.speedStreamDone = true; return false end
	if not U.speedStreamDone then return false end
	if U.speedHeldLogged ~= v then
		U.speedHeldLogged = v
		local tb = ""
		pcall(function() tb = debug.traceback("", 2):gsub("\n%s*", " | "):sub(1, 600) end)
		log("speed: this game's interface keeps asking for speed " .. tostring(v) .. " while another player set " .. tostring(cur)
			.. ": not asked again (from:" .. tb .. ")")
	end
	return true
end

-- the speed the game's speed buttons show during a session (nil: the engine's own): the speed this player just asked
-- for, else the session's (0 while paused)
U.shownSpeed = function()
	local st = U.status
	local t = st and tonumber(st.t)
	if not st or st.started ~= "1" or t == nil or os.time() - t > 6 then return nil end
	if U.lastSpeedReq ~= nil and os.clock() - (U.lastSpeedAt or -10) < 2 then return U.lastSpeedReq end
	return tonumber(st.speed)
end

-- the status is older than a few seconds: MPFever.exe no longer writes it
local function statusStale(st)
	local t = st and tonumber(st.t)
	return t ~= nil and os.time() - t > 6
end

-- the sync line: text and colour class
local function syncLine(st)
	local sync = st and st.sync or "none"
	local parts = (st and st.parts and st.parts ~= "") and (" (" .. st.parts .. ")") or ""
	if sync == "ok" then
		local age = tonumber(st.age) or -1
		return T("Synchrone", "In sync") .. (age >= 0 and ("  ·  " .. C.Tf("vérifiée il y a %s s", "checked %s s ago", age)) or ""), "success"
	elseif sync == "drift" then
		return T("Légère dérive", "Slight drift") .. parts .. "  ·  " .. T("corrigée si elle dure", "corrected if it lasts"), "warning"
	elseif sync == "desync" then
		return T("Désynchronisé", "Out of sync") .. parts .. "  ·  " .. T("la partie de l'hôte est rechargée si l'écart persiste", "the host's game is reloaded if it persists"), "error"
	elseif sync == "resync" then
		return T("Resynchro…", "Resyncing…") .. "  ·  " .. T("rechargement de la partie de l'hôte", "reloading the host's game"), "info"
	end
	return T("pas encore vérifiée", "not checked yet"), nil
end

local PLAYER_STATES = {
	ok = function() return T("connecté", "connected"), nil end,
	slow = function(pl) return C.Tf("%s pas de retard", "%s steps behind", pl.lag), "warning" end,
	noresp = function() return T("ne répond plus", "not responding"), "error" end,
	-- (0.7.4: the percent of the host's game it has received, while it is on its way)
	loading = function(pl)
		if pl.pct then return C.Tf("reçoit la partie de l'hôte : %s %", "receiving the host's game: %s %", pl.pct), "info" end
		return T("charge la partie de l'hôte…", "loading the host's game…"), "info"
	end,
	joining = function(pl)
		if pl.pct then return C.Tf("reçoit la partie de l'hôte : %s %", "receiving the host's game: %s %", pl.pct), "info" end
		return T("se connecte…", "connecting…"), "info"
	end,
	left = function() return T("a quitté la partie", "left the game"), "negative" end,
	-- (its connection dropped: every game waits for it to come back, lag = the seconds since)
	away = function(pl) return C.Tf("connexion perdue, la partie l'attend (%s s)", "connection lost, the game waits for them (%s s)", pl.lag), "warning" end,
}

-- a player's line: name, (you), host, its state; and the colour class (a dedicated server is not one of the players: it
-- is named above them)
local function playerLine(pl, me)
	local text = pl.name
	if pl.id == me then text = text .. T(" (vous)", " (you)") end
	if pl.role == "host" then text = text .. "  –  " .. T("hôte", "host") end
	local state, cls = (PLAYER_STATES[pl.state] or PLAYER_STATES.ok)(pl)
	return text .. "  ·  " .. state, cls
end

-- the players still in the session (those who left are listed too, for a while; a dedicated server is not counted)
local function playerCount(st)
	local n = 0
	for _, pl in ipairs(st and st.players or {}) do if pl.state ~= "left" and pl.role ~= "server" then n = n + 1 end end
	return n
end

-- this game's own link to the host, when it is not fine (nil otherwise)
local function linkLine(st)
	if not st then return T("En attente de MPFever.exe…", "Waiting for MPFever.exe…"), "info" end
	local attempt = tonumber(st.attempt) or 0
	if st.conn == "lost" then
		if attempt > 0 then return C.Tf("Connexion à l'hôte perdue : reconnexion (essai %s)…", "Connection to the host lost: reconnecting (attempt %s)…", attempt), "error" end
		return T("Connexion à l'hôte perdue…", "Connection to the host lost…"), "error"
	elseif st.conn == "gone" then
		return T("Connexion à l'hôte perdue (reconnexion impossible).", "Connection to the host lost (could not reconnect)."), "error"
	elseif st.conn == "denied" then
		-- (the host refused this player: why, in this player's language, written by MPFever.exe)
		return (st.denied and st.denied ~= "") and st.denied or T("Connexion refusée par l'hôte.", "Connection refused by the host."), "error"
	elseif statusStale(st) then
		return T("Pas de nouvelles de MPFever.exe depuis quelques secondes.", "No news from MPFever.exe for a few seconds."), "warning"
	end
	return nil
end

-- The colour of MPFever's icon in the bottom bar, with its one-line state for the tooltip: grey while there is no session yet,
-- red for a problem (link to the host lost or refused, MPFever.exe silent, games out of sync, a player not responding), yellow
-- while a resynchronisation is under way, the games drift slightly, or a player loads the host's game or joins, green
-- otherwise. A player a few steps behind ("slow") only shows in the tooltip: a guest's game is often a little behind, and the
-- icon must not blink for it.
U.barState = function(st)
	local link = linkLine(st)
	if not st then return "grey", link end
	if st.conn == "lost" or st.conn == "gone" or st.conn == "denied" or statusStale(st) then return "red", link end
	if st.started ~= "1" then return "grey", T("La partie n'a pas encore commencé.", "The game has not started yet.") end
	local sync = syncLine(st)
	if st.sync == "desync" then return "red", sync end
	local busy = nil
	for _, pl in ipairs(st.players or {}) do
		if pl.role ~= "server" and pl.state == "noresp" then return "red", (playerLine(pl, st.me)) end
		if pl.role ~= "server" and not busy and (pl.state == "loading" or pl.state == "joining" or pl.state == "away") then busy = pl end
	end
	if st.sync == "resync" or st.sync == "drift" then return "yellow", sync end
	if busy then return "yellow", (playerLine(busy, st.me)) end
	return "green", sync
end

-- A request to MPFever.exe, as the main menu's MPFever window sends them (menu_req.txt: "id TAB command TAB argument TAB name
-- TAB"; the launcher acts on a new id, see OnMenuRequest)
U.menuRequest = function(cmd, arg)
	U.reqSeq = (U.reqSeq or 0) + 1
	local f = C.IO.open(C.DIR .. C.BS .. "menu_req.txt", "wb")
	if not f then log("session: cannot write menu_req.txt") return false end
	f:write(tostring(os.time()) .. ".ui" .. U.reqSeq .. C.TAB .. cmd .. C.TAB .. tostring(arg or "") .. C.TAB .. (C.NAME or "") .. C.TAB .. C.NL)
	f:close()
	log("session: " .. cmd .. " " .. tostring(arg or "") .. " asked to MPFever.exe")
	return true
end

-- the host asks MPFever.exe to send Steam invitations (as the main menu's MPFever window does)
local function requestInvite()
	U.menuRequest("invite")
end

-- "Report a problem": MPFever.exe puts the logs into a zip and opens a new GitHub issue (see Reporter.cs); it says where
-- the zip is in report.txt, shown under the button
-- (0.6.8) a report takes some 20 s: while it is being made, the button says so and another click asks nothing (three
-- zips in 20 s, 2026-11-01), and only an answer written after the click is shown (the last report's "ready" line came back
-- at once). MPFEVER_REPORTBUSY=0: every click asks a report, as before
function U.reportLine()
	local f = C.IO.open(C.DIR .. C.BS .. "report.txt", "rb")
	if not f then return nil end
	local line = f:read("*l")
	f:close()
	return line
end
function U.reportBusy()
	return os.getenv("MPFEVER_REPORTBUSY") ~= "0" and U.reportWaiting == true and U.reportAsked ~= nil and os.time() - U.reportAsked <= 120
end
function U.reportLabel()
	return U.reportBusy() and T("Rapport en cours de création…", "Making the report…") or T("Signaler un problème (journaux)", "Report a problem (logs)")
end
local function requestReport()
	if U.reportBusy() then return end
	U.reportOld = U.reportLine()
	if not U.menuRequest("report") then return end
	U.reportAsked = os.time()
	U.reportWaiting = true
	U.reportMsg = T("Rapport en cours de création (environ 20 s)…", "Making the report (about 20 s)…")
	U.statusVersion = (U.statusVersion or 0) + 1
end

-- the answer of MPFever.exe to the last report asked (report.txt: "<ticks> TAB <text>")
local function pollReport()
	if not U.reportAsked or os.time() - U.reportAsked > 120 then
		if U.reportWaiting then U.reportWaiting = false U.statusVersion = (U.statusVersion or 0) + 1 end
		return
	end
	local line = U.reportLine()
	if os.getenv("MPFEVER_REPORTBUSY") ~= "0" and line == U.reportOld then return end
	local text = line and line:match("^%d+\t(.*)$")
	if text and text ~= U.reportMsg then
		U.reportMsg = text
		U.reportWaiting = false
		U.statusVersion = (U.statusVersion or 0) + 1
	end
end

-- re-renders its recipe when the status changes, and once more when it gets old
local function useStatus(react)
	local key = function() return tostring(U.statusVersion or 0) .. (statusStale(U.status) and "s" or "") end
	local ver = react.useState(key())
	react.onStepTimer(function()
		pcall(pollReport)
		local k = key()
		if ver:old() ~= k then ver:set(k) end
	end, 0.5)
	return U.status
end

-- ---------------------------------------------------------------- in-game chat
-- MPFever.exe writes every line of the session's chat to chat.txt ("id TAB time TAB kind TAB player TAB text"; kind:
-- msg, join, left, unsent); this game's messages go to chat_out.txt ("seq TAB text"), which MPFever.exe sends to the host

-- one UTF-8 character (the mod's files have no backslash: the bytes are made with string.char)
local UTF8_CHAR = "[" .. string.char(1) .. "-" .. string.char(127) .. string.char(194) .. "-" .. string.char(244) .. "][" .. string.char(128) .. "-" .. string.char(191) .. "]*"

local function ulen(t)
	local n = 0
	for _ in t:gmatch(UTF8_CHAR) do n = n + 1 end
	return n
end

local function usub(t, maxChars)
	local out, n = {}, 0
	for ch in t:gmatch(UTF8_CHAR) do
		n = n + 1
		if n > maxChars then break end
		out[#out + 1] = ch
	end
	return table.concat(out)
end

-- a text in lines of at most w characters (the first one: firstW), cut between words when it can
local function wrap(t, firstW, w)
	local lines, cur, curLen = {}, "", 0
	local function limit() return #lines == 0 and firstW or w end
	local function push() lines[#lines + 1] = cur; cur, curLen = "", 0 end
	for word in t:gmatch("[^ ]+") do
		local wl = ulen(word)
		if curLen > 0 and curLen + 1 + wl > limit() then push() end
		while wl > limit() do
			local lim = limit() - curLen - (curLen > 0 and 1 or 0)
			if lim <= 0 then push() lim = limit() end
			local head = usub(word, lim)
			cur = cur .. (curLen > 0 and " " or "") .. head
			push()
			word = word:sub(#head + 1)
			wl = ulen(word)
		end
		if wl > 0 then
			cur = cur .. (curLen > 0 and " " or "") .. word
			curLen = curLen + (curLen > 0 and 1 or 0) + wl
		end
	end
	if curLen > 0 or #lines == 0 then push() end
	return lines
end

-- this player's name as the chat shows it (the host's status: "me", without the connection number)
local function myChatName()
	local me = U.status and U.status.me
	if me and me ~= "" then return me:match("^(.-)#%d+$") or me end
	return C.NAME
end

local CHAT_LINE = "^([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "(.*)$"

local function pollChat()
	local now = os.clock()
	if U.chatAt and now - U.chatAt < 0.4 then return end
	U.chatAt = now
	local f = C.IO.open(C.DIR .. C.BS .. "chat.txt", "rb")
	if not f then return end
	local size = f:seek("end") or 0
	U.chatOff = U.chatOff or 0
	if size < U.chatOff then U.chatOff = 0 end
	if size == U.chatOff then f:close() return end
	f:seek("set", U.chatOff)
	local data = f:read(size - U.chatOff) or ""
	f:close()
	local pos, fresh = 1, {}
	while true do
		local e = data:find(C.NL, pos, true)
		if not e then break end   -- a line still being written: read next time
		local line = data:sub(pos, e - 1):gsub(C.CR, "")
		pos = e + 1
		local id, t, kind, name, txt = line:match(CHAT_LINE)
		if id then fresh[#fresh + 1] = { id = tonumber(id) or 0, t = tonumber(t) or 0, kind = kind, name = name, text = txt } end
	end
	U.chatOff = U.chatOff + pos - 1
	if #fresh == 0 then return end
	U.chat = U.chat or {}
	for _, m in ipairs(fresh) do U.chat[#U.chat + 1] = m end
	while #U.chat > 100 do table.remove(U.chat, 1) end
	U.chatVersion = (U.chatVersion or 0) + 1
	-- the lines already there when this game loaded (a resynchronisation reloads it) are not new
	if not U.chatSeen then U.chatSeen = true return end
	local me = myChatName()
	local news = {}
	for _, m in ipairs(fresh) do
		if m.kind == "msg" and m.name ~= me then news[#news + 1] = m end
	end
	if #news > 0 and not U.chatOpen then
		U.chatUnread = (U.chatUnread or 0) + #news
		if U.onChatNews then pcall(U.onChatNews, news) end
	end
end

-- this player's message, for MPFever.exe (which sends it to the host)
local function sendChat(t)
	-- (control bytes listed, not %c: under a code page locale %c may take a byte of a UTF-8 character, issue #30)
	t = tostring(t or ""):gsub("[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. "]", " "):gsub("^ +", ""):gsub(" +$", "")
	if t == "" then return false end
	if ulen(t) > 300 then t = usub(t, 300) end
	U.chatSeq = (U.chatSeq or 0) + 1
	local f = C.IO.open(C.DIR .. C.BS .. "chat_out.txt", "ab")
	if not f then log("chat: cannot write chat_out.txt") return false end
	f:write(tostring(os.time()) .. "." .. U.chatSeq .. C.TAB .. t .. C.NL)
	f:close()
	return true
end

-- re-renders its recipe when a chat line arrives
local function useChat(react)
	local ver = react.useState(U.chatVersion or 0)
	react.onStepTimer(function()
		local v = U.chatVersion or 0
		if ver:old() ~= v then ver:set(v) end
	end, 0.3)
	return U.chat or {}
end

-- the game's own window container (to open a window without the pause menu); loaded only in game, when game.tl
-- has long been loaded by the game itself
local function defaultWindowApi()
	local ok, wapi = pcall(function()
		local okG, g = pcall(ug_require, "::/gui/main/game.tl")
		if not (okG and type(g) == "table") then g = ug_require("/gui/main/game.tl") end
		local wc = g.game_react_globals.getDefaultWindowContainer()
		if wc == nil or wc:hasExpired() then return nil end
		return wc:get():getApi()
	end)
	if ok then return wapi end
	return nil
end

-- each company's vehicles: player entity -> count, read once every 2 s (TF3 has no getVehiclesForPlayer: the menu showed 0 vehicles
-- for every company)
U.vehicleCounts = function()
	local now = os.clock()
	if U.vehCount and now - U.vehCount.at < 2 then return U.vehCount.map end
	local map = {}
	pcall(function()
		api.engine.forEachEntityWithComponent(function(v)
			local po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED)
			if po and type(po.player) == "number" and po.player >= 0 then map[po.player] = (map[po.player] or 0) + 1 end
		end, api.type.ComponentType.TRANSPORT_VEHICLE)
	end)
	U.vehCount = { at = now, map = map }
	return map
end

-- companies mode: the companies of the session, best first (money, then number), each { ent, id, name, bal, lines, veh, rank }
-- (gone ones left out), and this player's company's money (nil when unknown)
U.companyList = function(eco)
	local list = {}
	-- (a company's entity is read only once it has been known for a few seconds and still exists: the engine asserts, and the
	-- game closes, when the interface reads the account of a player entity the simulation is still adding, or of one gone with
	-- the previous game)
	U.coSeenAt = U.coSeenAt or {}
	local now = os.clock()
	for ent, id in pairs(U.coMap or {}) do
		if not eco.gone[id] then
			U.coSeenAt[ent] = U.coSeenAt[ent] or now
			local settled = now - U.coSeenAt[ent] >= 5
			if settled then
				local okE, ex = pcall(api.engine.entityExists, ent)
				settled = okE and ex == true
			end
			local bal = nil
			local nLines, nVeh = 0, 0
			if settled then
				pcall(function() bal = api.engine.util.finance.getPlayersBalance(ent) end)
				pcall(function() nLines = #api.engine.system.lineSystem.getLinesForPlayer(ent) end)
				nVeh = U.vehicleCounts()[ent] or 0
			end
			local rank = U.ranks and U.ranks[id] and U.ranks[id].level or nil
			list[#list + 1] = { ent = ent, id = id, name = companyName(ent), bal = bal or 0, lines = nLines, veh = nVeh, rank = rank }
		end
	end
	table.sort(list, function(a, b) if a.bal ~= b.bal then return a.bal > b.bal end return a.id < b.id end)
	local myBal = nil
	for _, c in ipairs(list) do if c.id == U.myCo then myBal = c.bal end end
	return list, myBal
end

-- ---------------------------------------------------------------- the computer companies' journal (0.5.13)
-- ai_journal.txt (see the bridge's H.aijournal): one entry a line, "time co kind x y z a b". Read every second; new entries are
-- told in the chat too when the player wants it (Settings, on by default). Each one's "Show" takes the camera there.
U.pollAiJournal = function()
	local now = os.clock()
	if U.aiJAt and now - U.aiJAt < 1 then return end
	U.aiJAt = now
	-- (the entries there when this game loaded, a resynchronisation's reload too, are not told again)
	local first = not U.aiJSeen
	U.aiJSeen = true
	local f = C.IO.open(C.DIR .. C.BS .. "ai_journal.txt", "rb")
	if not f then return end
	local size = f:seek("end") or 0
	U.aiJOff = U.aiJOff or 0
	if size < U.aiJOff then U.aiJOff = 0; U.aiJournal = {} end
	if size == U.aiJOff then f:close() return end
	f:seek("set", U.aiJOff)
	local data = f:read(size - U.aiJOff) or ""
	f:close()
	local pos, fresh = 1, {}
	while true do
		local e = data:find(C.NL, pos, true)
		if not e then break end   -- a line still being written: read next time
		local line = data:sub(pos, e - 1):gsub(C.CR, "")
		pos = e + 1
		local p = {}
		for x in (line .. C.TAB):gmatch("([^" .. C.TAB .. "]*)" .. C.TAB) do p[#p + 1] = x end
		if #p >= 3 then
			fresh[#fresh + 1] = { co = tonumber(p[2]), kind = p[3], x = tonumber(p[4]), y = tonumber(p[5]), z = tonumber(p[6]), a = p[7] or "", b = p[8] or "" }
		end
	end
	U.aiJOff = U.aiJOff + pos - 1
	if #fresh == 0 then return end
	U.aiJournal = U.aiJournal or {}
	for _, x in ipairs(fresh) do U.aiJournal[#U.aiJournal + 1] = x end
	while #U.aiJournal > 200 do table.remove(U.aiJournal, 1) end
	U.aiJVersion = (U.aiJVersion or 0) + 1
	if first or (U.loadPrefs().aichat or "1") == "0" then return end
	U.chat = U.chat or {}
	for _, x in ipairs(fresh) do U.chat[#U.chat + 1] = { id = 0, t = os.time(), kind = "ai", name = U.aiCoName(x.co), text = U.aiText(x) } end
	while #U.chat > 100 do table.remove(U.chat, 1) end
	U.chatVersion = (U.chatVersion or 0) + 1
end

U.aiCoName = function(id)
	for ent, cid in pairs(U.coMap or {}) do if cid == id then return companyName(ent) end end
	return C.Tf("Entreprise %s", "Company %s", tostring(id))
end

-- what an entry says, in this game's language
-- (0.7.4) a cargo's name as the game shows it ("Bricks"), not its file's path (::/cargos/bricks/bricks.cargo), as the computer
-- companies' line names (mpfever_ai.lua's cargoLabel). MPFEVER_AICARGOPATH=1: the path, as before
U.cargoLabel = function(id)
	local file, n = tostring(id or ""), nil
	pcall(function() file = api.res.cargoTypeRep.getName(tonumber(id)) end)
	if os.getenv("MPFEVER_AICARGOPATH") == "1" then return file end
	pcall(function()
		local ct = api.res.cargoTypeRep.get(tonumber(id))
		n = ct and ct.name
		if type(n) == "string" and n ~= "" and type(_) == "function" then
			local okT, tr = pcall(_, n)
			if okT and type(tr) == "string" and tr ~= "" then n = tr end
		end
	end)
	if type(n) == "string" and n ~= "" and not n:find("/", 1, true) then return n end
	return tostring(file):match("([^/]+)%.cargo$") or tostring(file)
end
U.aiText = function(x)
	local function cargo(id) return U.cargoLabel(id) end
	if x.kind == "stop" then return T("a construit un arrêt", "built a stop") end
	if x.kind == "garage" then return T("construit un garage", "is building a garage") end
	if x.kind == "road" then return T("a construit une route vers une industrie", "built a road to an industry") end
	if x.kind == "line" then return C.Tf("a ouvert la ligne de bus %s", "opened the bus line %s", x.a) end
	if x.kind == "freight" then return C.Tf("a ouvert la ligne de fret %s (%s)", "opened the freight line %s (%s)", x.a, cargo(x.b)) end
	if x.kind == "bus" then return C.Tf("a acheté un bus (%s)", "bought a bus (%s)", x.a) end
	if x.kind == "truck" then return C.Tf("a acheté un camion pour %s (%s)", "bought a truck for %s (%s)", cargo(x.b), x.a) end
	if x.kind == "sold" then return T("a vendu un véhicule", "sold a vehicle") end
	if x.kind == "giveup" then return C.Tf("a abandonné la ligne %s", "gave up the line %s", x.a) end
	-- (0.6.4: its railways, see mpfever_ai.lua's RL)
	if x.kind == "railstation" then return T("a construit une gare de fret", "built a cargo station") end
	if x.kind == "railtrack" then return T("a posé une voie ferrée", "laid a railway track") end
	if x.kind == "raildepot" then return T("a construit un dépôt ferroviaire", "built a train depot") end
	if x.kind == "railline" then return C.Tf("a ouvert la ligne de train %s (%s)", "opened the train line %s (%s)", x.a, cargo(x.b)) end
	if x.kind == "train" then return C.Tf("a acheté un train pour %s (%s)", "bought a train for %s (%s)", cargo(x.b), x.a) end
	return tostring(x.kind)
end

U.aiFocus = function(x)
	local ok, err = pcall(function() api.gui.camera.focusPosition(api.type.Vec3f.new(x.x, x.y, x.z or 0), 400) end)
	if not ok then log("AI journal: camera not moved: " .. tostring(err)) end
end

-- the camera on a line's first stop
U.focusLine = function(l)
	local ok, err = pcall(function()
		local lc = api.engine.getComponent(l, api.type.ComponentType.LINE)
		local sg = api.engine.getComponent(lc.stops[1].stationGroup, api.type.ComponentType.STATION_GROUP)
		api.gui.camera.focusEntity(sg.stations[1])
	end)
	if not ok then log("AI lines: camera not moved: " .. tostring(err)) end
end

-- (0.8.3, Zoey's suggestion: "the window of a stop showing the other players' lines that use it") The other companies' lines that
-- stop at this company's stations: { station group, its name, line, its name, company, its vehicles }, by station then line. Read
-- here in the interface, only while this company's sheet shows them (the button of its section, closed by default: nothing of it
-- in normal play), again every 5 s. companies: the tab's list (id, ent); label(c): the name shown. Changes nothing in any game
U.otherLinesAtMine = function(companies, label)
	local now = os.clock()
	if U.olCache and now - U.olCache.at < 5 and now >= U.olCache.at then return U.olCache.rows end
	local mineEnt, lineCo = nil, {}
	for _, c in ipairs(companies or {}) do
		if c.id == U.myCo then mineEnt = c.ent
		elseif c.ent then
			pcall(function() for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(c.ent)) do lineCo[l] = c end end)
		end
	end
	local rows = {}
	if mineEnt then
		local function nameOf(e) local n = tostring(e) pcall(function() n = api.engine.getComponent(e, api.type.ComponentType.NAME).name end) return n end
		for _, sg in ipairs(R.entitiesWith("STATION_GROUP")) do
			if R.ownerOf(sg) == mineEnt then
				local seen = {}
				pcall(function()
					for _, ls in ipairs(api.engine.system.lineSystem.getLineStops(sg)) do
						local l = ls[1]
						if lineCo[l] and not seen[l] then
							seen[l] = true
							local nv = 0
							pcall(function() nv = #api.engine.system.transportVehicleSystem.getLineVehicles(l) end)
							rows[#rows + 1] = { sg = sg, sgName = nameOf(sg), line = l, lineName = nameOf(l), co = label and label(lineCo[l]) or tostring(lineCo[l].id), nv = nv }
						end
					end
				end)
			end
		end
	end
	table.sort(rows, function(a, b) if a.sgName ~= b.sgName then return a.sgName < b.sgName end return a.lineName < b.lineName end)
	U.olCache = { at = now, rows = rows }
	return rows
end

-- the camera on a station group (its first station)
U.focusStationGroup = function(sg)
	local ok, err = pcall(function()
		local c = api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP)
		api.gui.camera.focusEntity(c.stations[1])
	end)
	if not ok then log("other companies' lines: camera not moved: " .. tostring(err)) end
end

-- a computer company's lines in its card of the Company tab: name, vehicles, "Show" (10 at most)
U.aiLineRows = function(K, c, card, CW)
	if (c.lines or 0) == 0 then return end
	local ok, lines = pcall(function() return api.engine.system.lineSystem.getLinesForPlayer(c.ent) end)
	if not (ok and type(lines) == "table") then return end
	card[#card + 1] = K.gap(1, 4)
	for i, l in ipairs(lines) do
		if i > 10 then card[#card + 1] = K.muted(C.Tf("… et %s autres lignes", "… and %s more lines", #lines - 10), CW); break end
		local name, nv = tostring(l), 0
		pcall(function() name = api.engine.getComponent(l, api.type.ComponentType.NAME).name end)
		pcall(function() nv = #api.engine.system.transportVehicleSystem.getLineVehicles(l) end)
		card[#card + 1] = K.row { K.text(C.Tf("%s  ·  %s véhicule(s)", "%s  ·  %s vehicle(s)", name, nv), nil, nil, CW - 80), K.gap(6, 1),
			K.btn(T("Voir", "Show"), nil, function() U.focusLine(l) end) }
	end
end

-- an empty view of eco.txt, before the bridge has written it
U.ECO_EMPTY = function()
	return { members = {}, chief = {}, gone = {}, debt = {}, track = {}, fees = {}, requests = {}, merges = {}, depots = {}, stops = {}, depotco = {}, ai = {}, road = {} }
end

-- mpfever_co.lua (palette, colours), loaded once
U.coLib = function()
	if U.coModule == nil then
		local ok, m = pcall(ug_require, "mpfever_co.lua")
		if not ok then ok, m = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
		U.coModule = (ok and type(m) == "table") and m or false
	end
	return U.coModule
end

-- companies mode: the companies of the session in the MPFever window, best first (money, rank, lines, vehicles), with a gift of
-- money to another company (event "give", applied by every game at the same step: see the bridge's handleEvent)
-- (the single-list window of MPFEVER_NEWWINDOW=0, as before the tabs; the tabbed window uses U.TABS.company and U.TABS.rules)
U.companyRows = function(ui)
	local list = {}
	-- (a company's entity is read only once it has been known for a few seconds and still exists: the engine asserts, and the
	-- game closes, when the interface reads the account of a player entity the simulation is still adding, or of one gone with
	-- the previous game)
	U.coSeenAt = U.coSeenAt or {}
	local now = os.clock()
	pcall(U.pollEco)
	local eco = U.eco or { members = {}, chief = {}, gone = {}, debt = {}, track = {}, fees = {}, requests = {}, merges = {}, depots = {} }
	for ent, id in pairs(U.coMap) do
		if eco.gone[id] then goto continue end
		U.coSeenAt[ent] = U.coSeenAt[ent] or now
		local settled = now - U.coSeenAt[ent] >= 5
		if settled then
			local okE, ex = pcall(api.engine.entityExists, ent)
			settled = okE and ex == true
		end
		local bal = nil
		local nLines, nVeh = 0, 0
		if settled then
			pcall(function() bal = api.engine.util.finance.getPlayersBalance(ent) end)
			pcall(function() nLines = #api.engine.system.lineSystem.getLinesForPlayer(ent) end)
			nVeh = U.vehicleCounts()[ent] or 0
		end
		local rank = U.ranks and U.ranks[id] and U.ranks[id].level or nil
		list[#list + 1] = { ent = ent, id = id, name = companyName(ent), bal = bal or 0, lines = nLines, veh = nVeh, rank = rank }
		::continue::
	end
	if #list < 1 then return nil end
	table.sort(list, function(a, b) if a.bal ~= b.bal then return a.bal > b.bal end return a.id < b.id end)
	local CO = U.coModule
	if CO == nil then
		local ok, m = pcall(ug_require, "mpfever_co.lua")
		if not ok then ok, m = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
		CO = (ok and type(m) == "table") and m or false
		U.coModule = CO
	end
	local row, text, muted, builtin = ui.row, ui.text, ui.muted, ui.builtin
	local out = { text(" "), ui.section(ui.ICON_PLAYERS, T("Entreprises", "Companies") .. "  (" .. #list .. ")") }
	local myBal = nil
	for _, c in ipairs(list) do if c.id == U.myCo then myBal = c.bal end end
	local function swatch(id)
		local ix = U.coColors and U.coColors[id] or id
		local c = nil
		if CO then pcall(function() local r, g, b = CO.rgb(ix); c = api.type.Vec4f.new(r, g, b, 1) end) end
		return builtin.Component { meta = { styleSheet = ui.style { size = { 14, 14 }, image = "::/gui/line_vehicle_mgmt/icons/line_surface.tga", bg = c } } }
	end
	local function give(c)
		local n = tonumber((tostring(ui.amount:old() or ""):gsub("[%s%.,']", "")))
		if not n or n <= 0 then U.giveMsg = T("Entrez un montant.", "Enter an amount.") return end
		n = math.floor(n)
		if myBal and n > myBal then U.giveMsg = T("Pas assez d'argent.", "Not enough money.") return end
		local ok, err = pcall(function()
			api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "give", { to = c.id, amount = n }))
		end)
		if not ok then log("companies: gift request failed: " .. tostring(err)) U.giveMsg = T("Envoi impossible.", "Could not send.") return end
		U.giveMsg = C.Tf("%s envoyés à %s.", "%s sent to %s.", money(n), c.name)
		log("companies: gift of " .. n .. " to company " .. c.id .. " requested")
		pcall(sendChat, "→ " .. c.name .. " : " .. money(n))
		ui.amount:set("")
		ui.gen:set(ui.gen:old() + 1)
	end
	local myKey = eco.myKey
	local amChief = U.myCo and eco.chief[U.myCo] ~= nil and eco.chief[U.myCo] == myKey
	local myMembers = U.myCo and eco.members[U.myCo] or {}
	local asked = nil
	for _, r in ipairs(eco.requests) do if r.key == myKey then asked = r.to end end
	local offered = nil
	for _, o in ipairs(eco.merges) do if o.from == U.myCo then offered = o.to end end
	local function btn(label, tip, fn, primary)
		return builtin.Button { meta = { class = primary and "primary" or "secondary", tooltip = tip }, content = text(label), onClick = fn }
	end
	for i, c in ipairs(list) do
		local mine = c.id == U.myCo
		local info = tostring(i) .. ".  " .. c.name .. (mine and T(" (vous)", " (you)") or "") .. "  ·  " .. money(c.bal)
			.. (c.rank and ("  ·  " .. C.Tf("rang %s", "rank %s", c.rank)) or "")
			.. "  ·  " .. C.Tf("%s lignes, %s véhicules", "%s lines, %s vehicles", c.lines, c.veh)
		local children = { swatch(c.id), text("  " .. info, nil, mine and "success" or nil) }
		if not mine and U.myCo then
			children[#children + 1] = text("  ")
			children[#children + 1] = builtin.Button { meta = { class = "secondary", tooltip = T("Donner le montant ci-dessous à cette entreprise", "Give the amount below to this company") },
				content = text(T("Donner", "Give")), onClick = function() give(c) end }
			-- mixed modes: join it (its chief accepts), or merge into it (the two chiefs)
			children[#children + 1] = text(" ")
			if asked == c.id then
				children[#children + 1] = btn(T("Annuler la demande", "Cancel the request"), nil, function() U.coSend("co_cancel", { what = "join" }) end)
			else
				children[#children + 1] = btn(T("Rejoindre", "Join"), T("Demander au chef de cette entreprise de vous y accueillir (vous quittez la vôtre, qui continue sans vous)", "Ask this company's chief to take you in (you leave yours, which goes on without you)"),
					function() U.coSend("co_join_ask", { to = c.id }) end)
			end
			if amChief then
				children[#children + 1] = text(" ")
				if offered == c.id then
					children[#children + 1] = btn(T("Annuler la fusion", "Cancel the merger"), nil, function() U.coSend("co_cancel", { what = "merge" }) end)
				else
					children[#children + 1] = btn(T("Fusionner", "Merge"), T("Proposer à son chef que votre entreprise rejoigne la sienne : tous vos biens, votre argent et vos joueurs y passent", "Offer its chief that your company joins theirs: all your assets, your money and your players go to it"),
						function() U.coSend("co_merge_ask", { to = c.id }) end)
				end
			end
		end
		out[#out + 1] = row(children)
		-- its players (and its chief)
		local mem = eco.members[c.id] or {}
		if #mem > 0 then
			local names = {}
			for _, k in ipairs(mem) do names[#names + 1] = k .. (eco.chief[c.id] == k and T(" (chef)", " (chief)") or "") end
			out[#out + 1] = muted("      " .. C.Tf("Joueurs : %s", "Players: %s", table.concat(names, ", ")))
		else
			out[#out + 1] = muted("      " .. T("Aucun joueur : elle continue seule", "No player: it goes on by itself"))
		end
		if eco.debt[c.id] then
			local lim = eco.bankrupt or 12
			out[#out + 1] = muted("      " .. (lim > 0 and C.Tf("Endettée depuis %s mois (faillite à %s mois)", "In debt for %s month(s) (bankruptcy at %s months)", eco.debt[c.id], lim)
				or C.Tf("Endettée depuis %s mois", "In debt for %s month(s)", eco.debt[c.id])))
		end
	end
	-- this company: leaving it, the requests and offers its chief answers
	if U.myCo then
		if #myMembers > 1 then
			out[#out + 1] = row { btn(T("Quitter l'entreprise", "Leave the company"), T("Vous fondez votre propre entreprise (argent de départ) ; celle-ci continue avec ses autres joueurs", "You start your own company (start money); this one goes on with its other players"),
				function() U.coSend("co_leave", {}) end) }
		end
		if amChief then
			for _, r in ipairs(eco.requests) do
				if r.to == U.myCo then
					out[#out + 1] = row {
						text(C.Tf("%s demande à rejoindre votre entreprise.  ", "%s asks to join your company.  ", r.name ~= "" and r.name or r.key), nil, "warning"),
						btn(T("Accepter", "Accept"), nil, function() U.coSend("co_join_answer", { key = r.key, accept = true }) end, true),
						text(" "),
						btn(T("Refuser", "Refuse"), nil, function() U.coSend("co_join_answer", { key = r.key, accept = false }) end),
					}
				end
			end
			for _, o in ipairs(eco.merges) do
				if o.to == U.myCo then
					local from = "#" .. tostring(o.from)
					for _, c in ipairs(list) do if c.id == o.from then from = c.name end end
					out[#out + 1] = row {
						text(C.Tf("%s propose de fusionner avec la vôtre (ses biens, son argent et ses joueurs vous rejoignent).  ", "%s offers to merge into yours (its assets, money and players join you).  ", from), nil, "warning"),
						btn(T("Accepter", "Accept"), nil, function() U.coSend("co_merge_answer", { from = o.from, accept = true }) end, true),
						text(" "),
						btn(T("Refuser", "Refuse"), nil, function() U.coSend("co_merge_answer", { from = o.from, accept = false }) end),
					}
				end
			end
		end
		-- the rule of its tracks, the fees and tolls it earned and paid
		local tr = eco.track[U.myCo] or { rule = "private", toll = 0 }
		local function ruleBtn(rule, label, tip)
			return builtin.Button { meta = { class = tr.rule == rule and "primary" or "secondary", tooltip = tip }, content = text(label),
				onClick = function() U.coSend("co_track_rule", { rule = rule, toll = tr.toll > 0 and tr.toll or 1000 }) end }
		end
		out[#out + 1] = row {
			muted(T("Vos voies : ", "Your tracks: ")),
			ruleBtn("private", T("Privées", "Private"), T("Les autres entreprises ne peuvent pas s'y raccorder", "The other companies cannot connect to them")),
			text(" "),
			ruleBtn("open", T("Ouvertes", "Open"), T("Les autres entreprises peuvent s'y raccorder et y faire rouler leurs trains, gratuitement", "The other companies may connect to them and run their trains on them, for free")),
			text(" "),
			ruleBtn("toll", T("Péage", "Toll"), T("Ouvertes, chaque train d'une autre entreprise paie le péage à chaque passage", "Open, every train of another company pays the toll each time it enters them")),
		}
		if tr.rule == "toll" then
			local tolls = { row { muted(T("Péage par passage : ", "Toll per passage: ")) } }
			local r = { muted(T("Péage par passage : ", "Toll per passage: ")) }
			for _, v in ipairs({ 500, 1000, 2000, 5000, 10000 }) do
				r[#r + 1] = builtin.Button { meta = { class = tr.toll == v and "primary" or "secondary" }, content = text(money(v)),
					onClick = function() U.coSend("co_track_rule", { rule = "toll", toll = v }) end }
				r[#r + 1] = text(" ")
			end
			out[#out + 1] = row(r)
		end
		local fe = eco.fees[U.myCo]
		if fe and (fe.si + fe.se + fe.ti + fe.te) > 0 then
			out[#out + 1] = muted(C.Tf("Gares partagées : reçu %s, payé %s  ·  Péages : reçu %s, payé %s", "Shared stations: earned %s, paid %s  ·  Tolls: earned %s, paid %s",
				money(fe.si), money(fe.se), money(fe.ti), money(fe.te)))
		end
		local lim = eco.bankrupt or 12
		out[#out + 1] = muted(lim > 0 and C.Tf("Règle de la partie : faillite après %s mois de dette.", "Game rule: bankruptcy after %s months in debt.", lim)
			or T("Règle de la partie : pas de faillite.", "Game rule: no bankruptcy."))
	end
	-- the auction of a bankrupt company (0.7.4: on the Auctions page, see U.TABS.auction; MPFEVER_OLDMENUS=1: here, as before)
	local au = U.oldMenus() and eco.auction or nil
	if au then
		local seller = "#" .. tostring(au.co)
		for ent, id in pairs(U.coMap) do if id == au.co then seller = companyName(ent) end end
		local bidder = nil
		for _, c in ipairs(list) do if c.id == au.bidder then bidder = c.name end end
		local what = au.kind == "line" and C.Tf("ligne « %s »", "line « %s »", au.label) or au.kind == "station" and C.Tf("gare « %s »", "station « %s »", au.label) or C.Tf("dépôt « %s »", "depot « %s »", au.label)
		out[#out + 1] = text(" ")
		out[#out + 1] = ui.section(ui.ICON_PLAYERS, C.Tf("Enchères : biens de %s", "Auction: assets of %s", seller))
		out[#out + 1] = text(C.Tf("Lot %s/%s : %s", "Lot %s/%s: %s", au.idx, au.n, what))
		out[#out + 1] = muted(C.Tf("Mise à prix %s  ·  meilleure offre %s  ·  encore %s s", "Reserve %s  ·  best bid %s  ·  %s s left",
			money(au.reserve), au.best > 0 and (money(au.best) .. " (" .. tostring(bidder or "?") .. ")") or T("aucune", "none"), au.left))
		if U.myCo and au.bidder ~= U.myCo then
			local r = { muted(T("Offrir : ", "Bid: ")) }
			local seen = {}
			for _, f in ipairs({ 1, 1.1, 1.25, 1.5 }) do
				local v = math.ceil(au.min * f / 1000) * 1000
				if not seen[v] then
					seen[v] = true
					r[#r + 1] = builtin.Button { meta = { class = f == 1 and "primary" or "secondary", enabled = myBal == nil or myBal >= v }, content = text(money(v)),
						onClick = function() U.coSend("co_bid", { seq = au.seq, lot = au.idx, amount = v }) end }
					r[#r + 1] = text(" ")
				end
			end
			out[#out + 1] = row(r)
		elseif au.bidder == U.myCo then
			out[#out + 1] = muted(T("Vous avez la meilleure offre.", "You have the best bid."))
		end
	end
	if U.myCo then
		out[#out + 1] = row {
			muted(T("Montant à donner : ", "Amount to give: ")),
			builtin.TextInputField {
				meta = { class = "font-scale-body", localKey = "mpfever-give-" .. tostring(ui.gen:old()), styleSheet = ui.style { size = { 160, -1 } } },
				value = "",
				placeholderText = "100000",
				maxLength = 15,
				acceptOnFocusLoss = true,
				onTyping = function(v) ui.amount:set(v or "") end,
				onValueChange = function(v) ui.amount:set(v or "") end,
			},
		}
		if U.giveMsg then out[#out + 1] = muted(U.giveMsg) end
		-- this company's colour: the palette, without the colours of the other companies
		if CO and CO.PALETTE then
			local taken = {}
			for id, ix in pairs(U.coColors or {}) do if id ~= U.myCo then taken[ix] = true end end
			local mineIx = U.coColors and U.coColors[U.myCo] or nil
			local sw = { muted(T("Votre couleur : ", "Your colour: ")) }
			for ix = 1, #CO.PALETTE do
				local p = CO.PALETTE[ix]
				local c = nil
				pcall(function() c = api.type.Vec4f.new(p[1], p[2], p[3], taken[ix] and 0.25 or 1) end)
				sw[#sw + 1] = builtin.Button {
					meta = { class = ix == mineIx and "primary" or "secondary", enabled = not taken[ix] and ix ~= mineIx,
						tooltip = taken[ix] and T("Déjà prise par une autre entreprise", "Already taken by another company") or nil },
					content = builtin.Component { meta = { styleSheet = ui.style { size = { 16, 16 }, image = "::/gui/line_vehicle_mgmt/icons/line_surface.tga", bg = c } } },
					onClick = function()
						local ok, err = pcall(function()
							api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "recolor", { color = ix }))
						end)
						log("companies: colour " .. ix .. " requested" .. (ok and "" or (": " .. tostring(err))))
					end,
				}
			end
			out[#out + 1] = row(sw)
		end
	end
	return out
end

-- ---------------------------------------------------------------- MPFever's window (tabs) and its icon in the bottom bar
-- One window of fixed width with five tabs: Session (link, sync, speed, players), Chat, Company and Rules (one company per
-- player only: nothing about companies shows when everybody plays one company), Settings. Nothing may go out of the window:
-- every text gets a width (the game wraps it there), a sentence never shares a row with buttons, long lists are combo boxes or
-- rows of six, and the long tabs scroll. It opens by itself at the start of a session and again after each load of a
-- resynchronisation, on the tab it showed. MPFEVER_NEWWINDOW=0: the single-list window of before (no tabs).
-- (0.6) With the Hub (see U.hubOn), this window is a quick view: Session and Chat, and a button that opens the Hub, where every
-- other tab is a page.

-- The drawing helpers, made once per interface from the game's builtin module (the bar's icon draws before the window exists)
U.makeKit = function(builtin)
	local K = { builtin = builtin }
	K.V, K.H = builtin.type.Orientation.Vertical, builtin.type.Orientation.Horizontal
	-- the window's measures: the content of the scroll area leaves room for its vertical bar; a card's padding is inside it
	K.WIN_W, K.BODY_H, K.INNER_W, K.TEXT_W = 600, 440, 572, 556
	K.CARD_W, K.CARD_TEXT_W = 548, 524
	K.ICON_PLAYERS = "::/gui/statistics/icons/symbol_person_multiple.tga"
	K.ICON_SYNC = "::/gui/menu/icons/symbol_arrows_refresh.tga"
	K.ICON_PERSON = "::/gui/entity_window/icons/symbol_person.tga"
	-- the game has no chat icon: MPFever brings its own (48 x 48 grey levels, like the game's icons)
	K.ICON_CHAT = "mpfever_1::/mpfever_chat.tga"
	K.ICON_MONEY = "::/gui/menu/icons/earnings.tga"
	K.ICON_COLOR = "::/gui/entity_window/icons/symbol_paintbucket.tga"
	K.ICON_TRACKS = "::/gui/game_bar/icons/infrastructure_tracks_30.tga"
	K.ICON_STATIONS = "::/gui/entity_window/icons/building_stations.tga"
	K.ICON_DEPOTS = "::/gui/entity_window/icons/building_depot_arrow.tga"
	K.ICON_SETTINGS = "::/gui/menu/icons/settings.tga"
	K.ICON_ALERT = "::/gui/menu/icons/alert.tga"
	K.ICON_SPEED = "::/gui/game_bar/icons/playback_play.tga"
	K.DISC = "::/gui/line_vehicle_mgmt/icons/line_surface.tga"
	-- (0.8.8) The Hub in the game's own style: its cards, headings, tables, bars, menu and choices are drawn with the recipes and
	-- the theme of the game's own windows (Finances, Company: game_mechanics/finance/*.tl, game_mechanics/company/company.tl and
	-- their .css.lua, read in base/content/gui.zip and game_mechanics.zip). The Hub has no style sheet of its own: everything is
	-- an inline style (api.gui.StyleSheet) or a recipe whose look follows it. Only the Hub's pages change (K.hub(): this kit,
	-- while the Hub draws a page); the small window draws as before. MPFEVER_OLDHUB=1 (read once): the Hub drawn as in 0.8.7,
	-- nothing of the new drawing; each of the game's recipes is also asked for with a fallback to that drawing (K.base, a
	-- widget the game's builtin module no longer has), so that a game update never breaks the window.
	K.old = os.getenv("MPFEVER_OLDHUB") == "1"
	K.game = not K.old
	function K.hub() return K.game == true and U.hubDrawing == true end
	-- (two parts of the new drawing can be left out alone, each read once: MPFEVER_HUBBASE=0, none of the game's script modules
	-- (the headings are drawn by hand, see K.heading); MPFEVER_HUBNAV=0, the head and the menu of before in place of the tabs
	-- and the list (see U.hubNav))
	K.noBase = os.getenv("MPFEVER_HUBBASE") == "0"
	K.noNav = os.getenv("MPFEVER_HUBNAV") == "0"
	-- the icons of the Hub's buttons (each one checked in gui.zip / game_mechanics.zip; a size is always given: 36 to 96 pixels)
	K.ICON_LOCATE = "::/gui/builtin/window/icons/symbol_locate.tga"
	K.ICON_ACCEPT = "::/game_mechanics/subventions/icons/subsidy_acceptance.tga"
	K.ICON_REFUSE = "::/game_mechanics/subventions/icons/subsidy_decline.tga"
	K.ICON_BACK = "::/gui/menu/icons/back.tga"
	K.ICON_KICK = "::/gui/builtin/window/icons/symbol_quit_arrow_right.tga"
	K.ICON_BAN = "::/gui/builtin/window/icons/lock.tga"
	K.ICON_SMALLER = "::/gui/builtin/window/icons/symbol_reduce_18.tga"
	K.ICON_LARGER = "::/gui/builtin/window/icons/symbol_maximize_18.tga"
	K.ICON_QUICK = "::/gui/builtin/window/icons/symbol_minimize_18.tga"
	K.ICON_INFO = "::/gui/entity_window/design/symbol_info_outline.tga"
	K.ICON_FOLD = "::/gui/entity_window/design/collapse_up.tga"
	K.ICON_UNFOLD = "::/gui/entity_window/design/collapse_down.tga"
	K.ICON_HAND = "::/game_mechanics/finance/icons/symbol_hand_dollar.tga"
	-- the game's speed buttons (gui/game_bar/game_bar_widgets.tl): pause, x1, x2, x4
	K.ICON_SPEEDS = { [0] = "::/gui/game_bar/icons/playback_pause.tga", [1] = "::/gui/game_bar/icons/playback_play.tga",
		[2] = "::/gui/game_bar/icons/playback_play_2.tga", [4] = "::/gui/game_bar/icons/playback_play_4.tga" }
	-- the game's card (gui/main/content_card.css.lua, "R::ContentCard !card-permanent" and "!card-outline"): a nine-patch surface
	-- and its contour; the Finances window's cards have the padding 10 / 18 and 8 pixels between two cards, its tables 12 pixels
	-- in a cell (game_mechanics/finance/finances.css.lua)
	K.CARD_SURFACE, K.CARD_CONTOUR = "::/gui/entity_window/design/card_surface.tga", "::/gui/entity_window/design/card_contour.tga"
	K.CARD_NINE = { 0, 6, 26, 32 }
	K.PAD_CARD, K.PAD_CELL, K.SPACE = { 10, 18, 10, 18 }, { 12, 12, 12, 12 }, 8
	-- the game's own colours (default_colors.gres), with fallbacks when they cannot be read (0.8.8: the theme's real values, as
	-- gui/main/default_colors.gres.lua makes them: hue 210, the Base colours at saturation 0.25, the Accent ones at 0.55)
	local FALLBACK = {
		Ok = { 0.298, 0.733, 0.09, 1 }, Warning = { 0.855, 0.647, 0.125, 1 }, Error = { 0.808, 0.125, 0.161, 1 }, Info = { 0.176, 0.408, 0.769, 1 },
		Positive = { 0.541, 0.725, 0.945, 1 }, Negative = { 0.941, 0.502, 0.502, 1 },
		NeutralMedium = { 0.502, 0.502, 0.502, 1 }, NeutralLight = { 0.702, 0.702, 0.702, 1 }, NeutralLightest = { 1, 1, 1, 1 },
		BaseVeryDark = { 0.09, 0.105, 0.12, 1 }, BaseDark = { 0.1125, 0.13125, 0.15, 1 }, BaseDarkMedium = { 0.135, 0.1575, 0.18, 1 },
		BaseMedium = { 0.1575, 0.18375, 0.21, 1 }, BaseLightMedium = { 0.18, 0.21, 0.24, 1 }, BaseLight = { 0.2025, 0.23625, 0.27, 1 },
		BaseVeryLight = { 0.2625, 0.30625, 0.35, 1 },
		AccentVeryDark = { 0.1575, 0.25375, 0.35, 1 }, AccentDark = { 0.2025, 0.32625, 0.45, 1 }, AccentMedium = { 0.2925, 0.47125, 0.65, 1 },
		AccentLight = { 0.3825, 0.61625, 0.85, 1 }, AccentVeryLight = { 0.4275, 0.68875, 0.95, 1 },
	}
	local CLASS_COLOR = { success = "Ok", warning = "Warning", error = "Error", info = "Info", negative = "Negative", positive = "Positive" }
	-- (the .gres colours are plain tables { r, g, b, a }: a style wants a Vec4f; alpha replaces the colour's own)
	local colorCache = {}
	local function rawColor(name)
		local okR, raw = pcall(function()
			local d = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
			return d[name]
		end)
		if not (okR and type(raw) == "table" and tonumber(raw[1])) then raw = FALLBACK[name] end
		return raw
	end
	function K.color(name, alpha)
		local key = name .. "/" .. tostring(alpha)
		if colorCache[key] ~= nil then return colorCache[key] or nil end
		local raw = rawColor(name)
		local c = nil
		if raw then
			local ok, v = pcall(function() return api.type.Vec4f.new(raw[1], raw[2], raw[3], alpha or raw[4] or 1) end)
			if ok then c = v end
		end
		colorCache[key] = c or false
		return c
	end
	function K.classColor(cls) return K.color(CLASS_COLOR[cls or ""] or "NeutralLightest") end
	-- (0.8.8) one of the game's colours as a plain { r, g, b, a } (a box's flat background, see K.style's `background`)
	function K.rgba(name, alpha)
		local raw = rawColor(name)
		if not raw then return nil end
		return { tonumber(raw[1]) or 0, tonumber(raw[2]) or 0, tonumber(raw[3]) or 0, alpha or tonumber(raw[4]) or 1 }
	end
	-- (0.8.8) the theme's flat backgrounds, as the Finances table has them (finances.css.lua): a table's head, its rows (one in
	-- two lighter), this player's own row, a bar's empty part, the menu, a heading's line
	K.TINTS = { head = { "BaseDark" }, odd = { "BaseLight" }, even = { "BaseMedium" }, mine = { "AccentDark" }, track = { "BaseVeryDark" },
		side = { "BaseDark" }, line = { "BaseVeryLight" } }
	function K.tint(kind)
		local t = K.TINTS[kind]
		return t and K.rgba(t[1], t[2]) or nil
	end
	-- (0.8.8) a status class as a class of money: the game writes an amount in « positive » (blue) or « negative » (red), never
	-- in the green of a status (finances_table.tl's moneyToClass); as it was outside the Hub's new drawing
	function K.moneyCls(cls)
		if not K.hub() then return cls end
		if cls == "success" then return "positive" end
		if cls == "error" then return "negative" end
		return cls
	end
	-- an inline style (meta.styleSheet, as the game's own windows use it): one property at a time, a value the interface refuses
	-- only loses that property; nil when there is no style sheet at all
	function K.style(t)
		local okS, st = pcall(function() return api.gui.StyleSheet.new() end)
		if not (okS and st) then return nil end
		if t.color then pcall(function() st.color = t.color end) end
		if t.bg then pcall(function() st.backgroundColor1 = t.bg end) end
		if t.background then pcall(function() st.backgroundColor = api.type.Vec4f.new(t.background[1], t.background[2], t.background[3], t.background[4]) end) end
		if t.size then pcall(function() st.size = api.type.Vec2f.new(t.size[1], t.size[2]) end) end
		if t.padding then pcall(function() st.padding = api.type.Vec4f.new(t.padding[1], t.padding[2], t.padding[3], t.padding[4]) end) end
		if t.image then
			pcall(function()
				local n = api.gui.NinePatch.new()
				n.fileName = t.image
				if t.nine then n.horizontal = t.nine; n.vertical = t.nineV or t.nine end
				st.backgroundImage1 = n
			end)
		end
		-- (0.8.8, the game's cards) a contour: a nine-patch image as the border, in a colour (a Vec4f); a second background layer
		if t.border then
			pcall(function()
				local n = api.gui.NinePatch.new()
				n.fileName = t.border
				local nb = t.borderNine or t.nine
				if nb then n.horizontal = nb; n.vertical = t.borderNineV or t.nineV or nb end
				st.borderImage = n
			end)
		end
		if t.borderColor then pcall(function() st.borderColor = t.borderColor end) end
		if t.borderWidth then pcall(function() st.borderWidth = api.type.Vec4f.new(t.borderWidth[1], t.borderWidth[2], t.borderWidth[3], t.borderWidth[4]) end) end
		if t.bg2 then pcall(function() st.backgroundColor2 = t.bg2 end) end
		if t.image2 then
			pcall(function()
				local n = api.gui.NinePatch.new()
				n.fileName = t.image2
				if t.nine2 then n.horizontal = t.nine2; n.vertical = t.nine2 end
				st.backgroundImage2 = n
			end)
		end
		return st
	end
	-- (0.8.8) a panel in the game's theme, as a style for K.box / K.style: the card's surface in a colour and its contour, the
	-- card's padding; st: the other fields (size...), which win. Kinds: "card" (BaseMedium, the Finances window's cards), "inner"
	-- (a box in a card, darker), "mine" (this player's own: the accent), and the tinted ones as the game's info bubble
	-- (content_card.css.lua, "R::Component!info-hint-comp": the surface in the status colour at alpha 0.25)
	K.PANELS = {
		card = { "BaseMedium", nil, "BaseVeryLight" }, inner = { "BaseDark", nil, "BaseVeryLight" }, mine = { "AccentVeryDark", nil, "AccentLight" },
		warning = { "Warning", 0.25, "Warning", 0.5 }, error = { "Error", 0.25, "Error", 0.5 }, success = { "Ok", 0.25, "Ok", 0.5 }, info = { "Info", 0.25, "Info", 0.5 },
	}
	function K.panel(kind, st)
		local p = K.PANELS[kind or "card"] or K.PANELS.card
		local out = { image = K.CARD_SURFACE, nine = K.CARD_NINE, bg = K.color(p[1], p[2]), border = K.CARD_CONTOUR, borderColor = K.color(p[3], p[4]),
			padding = K.PAD_CARD }
		for k, v in pairs(st or {}) do out[k] = v end
		return out
	end
	-- a text; with a width (a whole number: the interface refuses another), the game wraps it there
	function K.text(t, class, cls, width)
		return builtin.TextView { meta = { class = (class or "font-scale-body") .. (cls and (", " .. cls) or "") }, text = tostring(t or ""),
			width = width and math.floor(width) or nil }
	end
	-- (the window draws again every second: the style sheets used over and over are made once, one style sheet can serve many
	-- nodes, as the map icons' colour squares do)
	local styleCache = {}
	local function cached(key, make)
		local st = styleCache[key]
		if st == nil then st = make() or false; styleCache[key] = st end
		return st or nil
	end
	function K.muted(t, width)
		return builtin.TextView { meta = { class = "font-scale-body", styleSheet = cached("muted", function() return K.style { color = K.color("NeutralLight") } end) },
			text = tostring(t or ""), width = width and math.floor(width) or nil }
	end
	function K.colored(t, c, width, class)
		return builtin.TextView { meta = { class = class or "font-scale-body", styleSheet = K.style { color = c } }, text = tostring(t or ""),
			width = width and math.floor(width) or nil }
	end
	-- a small round dot: in a status colour (the game's line colour dot), or in one of the game's colours
	function K.dot(cls, size)
		size = size or 14
		return builtin.Component { meta = { styleSheet = cached("dot/" .. tostring(cls) .. "/" .. size, function()
			return K.style { size = { size, size }, image = K.DISC, bg = K.classColor(cls) }
		end) } }
	end
	function K.disc(colorName, size)
		size = size or 14
		return builtin.Component { meta = { styleSheet = cached("disc/" .. tostring(colorName) .. "/" .. size, function()
			return K.style { size = { size, size }, image = K.DISC, bg = K.color(colorName) }
		end) } }
	end
	-- (some of the game's icons are large pictures: always a fixed size; h: its height when it is not a square)
	function K.icon(path, size, h)
		return builtin.ImageView { path = path, meta = { styleSheet = K.style { size = { size, h or size } } } }
	end
	function K.row(children) return builtin.BoxLayout { orientation = K.H, children = children } end
	function K.col(children) return builtin.BoxLayout { orientation = K.V, children = children } end
	-- (0.6.8, #114) the windows' content with an inner margin on the left and at the bottom (the text touched the border).
	-- MPFEVER_WINPAD=0: no margin, as before
	function K.padded(content)
		if os.getenv("MPFEVER_WINPAD") == "0" or content == nil then return content end
		K.padStyle = K.padStyle or K.style { padding = { 0, 0, 10, 12 } }
		return builtin.Component { meta = { styleSheet = K.padStyle }, layout = K.col { content } }
	end
	function K.gap(w, h)
		return builtin.Component { meta = { styleSheet = cached("gap/" .. w .. "x" .. h, function() return K.style { size = { w, h } } end) } }
	end
	-- (0.8.8) one of the game's own script modules (gui/main/content_card.tl...), asked once, by the very path the game's own
	-- files ask it with (the game keeps one copy of a module per path: a second copy would register its recipes twice): nil
	-- when it cannot be had (a game update moved or changed it; the tests have no ug_require), and its caller then draws by
	-- hand. names: the fields it must have to be of any use
	local baseCache = {}
	function K.base(path, names)
		if K.noBase then return nil end
		if baseCache[path] == nil then
			local ok, m = pcall(function() return ug_require(path) end)
			local good = ok and type(m) == "table"
			if good then for _, k in ipairs(names or {}) do if m[k] == nil then good = false end end end
			baseCache[path] = good and m or false
			if not good then pcall(log, "hub: " .. path .. " not usable (" .. tostring(ok and "a field is missing" or m) .. "): drawn by hand") end
		end
		return baseCache[path] or nil
	end
	-- (0.8.8) a heading in the game's style, w wide: the game's own ContentCard{ title } (gui/main/content_card.tl: the title in
	-- the headline font and its thin line, as the Finances window puts one above each of its cards, game_mechanics/finance/
	-- finances_table.tl; its rules are scoped to the recipe itself, gui/main/content_card.css.lua, so its look follows it here;
	-- with a title alone it never reads the game context the Hub has not), in a box of the width. When the module cannot be had:
	-- the title in the headline font and a thin line under it, drawn by hand.
	function K.heading(title, w)
		w = math.max(40, math.floor(w or K.TEXT_W))
		local cc = K.base("::/gui/main/content_card.tl", { "ContentCard" })
		if cc then
			local ok, n = pcall(function() return cc.ContentCard { title = tostring(title or "") } end)
			if ok and n ~= nil then return K.box({ n }, { size = { w, -1 } }) end
		end
		return K.col { K.text(title, "font-scale-headline", nil, w), K.gap(1, 3), K.rect(w, 1, K.tint("line")) }
	end
	-- a section's title: an icon and the title, on a row of their own
	function K.section(path, title)
		-- (0.8.8, the Hub: the game's heading, as wide as the page's cards; the game's headings have no icon)
		if K.hub() then return K.heading(title, K.TEXT_W + 40) end
		return K.row { K.icon(path, 22), K.gap(8, 1), K.text(title, "font-scale-title-4", nil, K.TEXT_W - 30) }
	end
	-- a card: a light background around a company, a request... (its texts take K.CARD_TEXT_W)
	function K.card(children)
		-- (0.8.8, the Hub: the game's card, see K.panel; the Hub gives K.CARD_TEXT_W the room its padding leaves)
		if K.hub() then
			return builtin.Component { meta = { styleSheet = K.style(K.panel("card", { size = { K.CARD_W, -1 } })) },
				layout = builtin.BoxLayout { orientation = K.V, children = children } }
		end
		return builtin.Component {
			meta = { styleSheet = K.style { size = { K.CARD_W, -1 }, padding = { 6, 10, 6, 10 }, background = { 1, 1, 1, 0.06 } } },
			layout = builtin.BoxLayout { orientation = K.V, children = children },
		}
	end
	-- (0.8.8) icon: an icon before the text, in the Hub's new drawing only, as the game's buttons have (gui/main/
	-- button_react_util.tl's makeIconTextButton: a horizontal layout of the image and the text; the game's own rule
	-- "Button::Layout > BoxLayout" puts 4 pixels between them). K.IW: what the icon adds to the button's width
	K.IW = 22
	function K.btn(label, tip, fn, primary, enabled, icon)
		local content
		if icon and K.hub() then content = builtin.BoxLayout { orientation = K.H, children = { K.icon(icon, 18), K.text(label) } }
		else content = K.text(label) end
		return builtin.Button { meta = { class = primary and "primary" or "secondary", tooltip = tip, enabled = enabled ~= false },
			content = content, onClick = fn }
	end
	-- (0.8.8) a button of an icon alone, its text as the tooltip (button_react_util.tl's makeIconButton: the locate button of the
	-- game's subsidies, game_mechanics/subventions/subventions_gui.tl)
	function K.ibtn(icon, tip, fn, primary, enabled, size, h)
		return builtin.Button { meta = { class = primary and "primary" or "secondary", tooltip = tip, enabled = enabled ~= false },
			content = K.icon(icon, size or 18, h), onClick = fn }
	end
	-- (0.8.8) « Show » on the map: in the Hub's new drawing the game's locate button (an icon, the text as its tooltip), never
	-- wider than the text button it replaces
	function K.locate(label, tip, fn)
		if K.hub() then return K.ibtn(K.ICON_LOCATE, tip or label, fn) end
		return K.btn(label, tip, fn)
	end
	-- (0.8.8) what an icon adds to a row's buttons (n of them) in the Hub's new drawing, 0 otherwise: the rows that give their
	-- text a fixed width take it off
	function K.iw(n) return K.hub() and (n or 1) * K.IW or 0 end
	-- (0.8.8) One choice among several, as the game draws it: builtin.ToggleButtonGroup (gui/main/builtin.lua; the game bar's
	-- speed buttons, gui/game_bar/game_bar_widgets.tl, and the construction parameters, gui/main/script_param_util.tl), in place of
	-- a row of buttons with the chosen one in primary. items: { { label = "..." or icon = path, tip = "..." }... }; selected: the
	-- chosen one's place (nil: none, the group then allows none, as the game bar does for a speed that is not one of its
	-- buttons); onPick(place) at a click, on the chosen one too (the callers leave out what changes nothing, as their buttons
	-- did); key: a name of its own on the page; perRow: buttons per row (a group a row: nothing goes out of the page). The
	-- chosen button is always the one given here: a choice shows once the session has it, as the primary button did.
	-- A group of another number of buttons is another node (its key): the game's recipe makes a hook per button.
	-- Returns nil, having made nothing, outside the Hub's new drawing or when the game no longer has the widget: the caller then
	-- draws its buttons as before.
	function K.choice(items, selected, onPick, key, perRow)
		if not K.hub() then return nil end
		local TBG = nil
		pcall(function() TBG = builtin.ToggleButtonGroup end)
		if not TBG then return nil end
		local n = #items
		perRow = math.max(1, math.floor(tonumber(perRow) or n))
		local rows = {}
		local first = 1
		while first <= n do
			local last = math.min(n, first + perRow - 1)
			local at = first
			local buttons = {}
			for j = first, last do
				local it = items[j]
				buttons[#buttons + 1] = { content = it.icon and K.icon(it.icon, 24) or K.text(it.label), meta = { tooltip = it.tip } }
			end
			local sel = (selected and selected >= first and selected <= last) and (selected - first + 1) or -1
			if #rows > 0 then rows[#rows + 1] = K.gap(1, 4) end
			rows[#rows + 1] = TBG {
				meta = { localKey = "mpfever-choice-" .. tostring(key) .. "-" .. at .. "-" .. #buttons },
				buttons = buttons,
				selected = sel,
				deselectAllowed = sel == -1,
				onValueChange = function(index)
					index = tonumber(index)
					if index and index >= 1 and index <= #buttons then onPick(at + index - 1) end
				end,
			}
			first = last + 1
		end
		if #rows == 1 then return rows[1] end
		return K.col(rows)
	end
	-- (0.6, the Hub) a box: a component with its own inline style (size, padding, background { r, g, b, a }) around a vertical
	-- (default) or horizontal layout, as the lobby's box() draws its panels
	function K.box(children, st, orientation)
		return builtin.Component { meta = { styleSheet = st and K.style(st) or nil },
			layout = builtin.BoxLayout { orientation = orientation or K.V, children = children } }
	end
	-- (0.6, the Hub) a plain rectangle of colour, w x h pixels (a bar's fill, a swatch), as the lobby draws its colour squares
	function K.rect(w, h, rgba)
		return builtin.Component { meta = { styleSheet = K.style { size = { math.max(1, math.floor(w)), math.max(1, math.floor(h)) }, background = rgba } } }
	end
	-- (0.6, the Hub) a button of a fixed width (the Hub's side menu)
	function K.wbtn(label, tip, fn, primary, width)
		return builtin.Button { meta = { class = primary and "primary" or "secondary", tooltip = tip, styleSheet = width and K.style { size = { width, -1 } } or nil },
			content = K.text(label), onClick = fn }
	end
	return K
end

-- ---------------------------------------------------------------- the window's preferences
-- Per session (ui_prefs.txt in the session folder, kept across the loads of a resynchronisation): whether the window is open,
-- its tab, reduced to the small card, pinned. Across launches (ui_prefs.txt in the folder above, as company_color.txt): whether
-- the window opens by itself when a game starts.
U.PREFS_KEYS = { "open", "tab", "compact", "pinned", "hubpage", "hubsize" }
U.loadPrefs = function()
	if U.prefs then return U.prefs end
	local p = {}
	local function read(path, keys)
		local f = C.IO.open(path, "rb")
		if not f then return end
		local s = f:read("*a") or ""
		f:close()
		for line in s:gmatch("[^" .. C.NL .. "]+") do
			local k, v = line:match("^(%w+)=(.-)" .. C.CR .. "?$")
			if k and keys[k] then p[k] = v end
		end
	end
	read(C.DIR .. C.BS .. "ui_prefs.txt", { open = true, tab = true, compact = true, pinned = true, hubpage = true, hubsize = true })
	read(C.DIR .. C.BS .. ".." .. C.BS .. "ui_prefs.txt", { autoopen = true, aichat = true, dots = true, vdots = true, oldmenus = true, hubk = true, hubu = true })
	U.prefs = p
	U.tab = U.tab or p.tab or "session"
	U.compact = p.compact == "1"
	return p
end
U.savePrefs = function()
	local p = U.loadPrefs()
	p.tab = U.tab or p.tab
	p.compact = U.compact and "1" or "0"
	local L = {}
	for _, k in ipairs(U.PREFS_KEYS) do if p[k] ~= nil then L[#L + 1] = k .. "=" .. tostring(p[k]) end end
	local f = C.IO.open(C.DIR .. C.BS .. "ui_prefs.txt", "wb")
	if f then f:write(table.concat(L, C.NL) .. C.NL); f:close() end
end
-- (the preferences kept across launches: the window opening by itself, the computer companies' builds told in the chat)
U.saveGlobalPrefs = function()
	local p = U.loadPrefs()
	local f = C.IO.open(C.DIR .. C.BS .. ".." .. C.BS .. "ui_prefs.txt", "wb")
	if f then f:write("autoopen=" .. tostring(p.autoopen or "1") .. C.NL .. "aichat=" .. tostring(p.aichat or "1") .. C.NL .. "dots=" .. tostring(p.dots or "1") .. C.NL
		.. (p.vdots ~= nil and ("vdots=" .. tostring(p.vdots) .. C.NL) or "") .. (p.oldmenus == "1" and ("oldmenus=1" .. C.NL) or "")
		.. (p.hubk ~= nil and ("hubk=" .. tostring(p.hubk) .. C.NL) or "") .. (p.hubu ~= nil and ("hubu=" .. tostring(p.hubu) .. C.NL) or "")); f:close() end
end
U.saveAutoOpen = function(on)
	local p = U.loadPrefs()
	p.autoopen = on and "1" or "0"
	U.saveGlobalPrefs()
	log("window: opens by itself when a game starts: " .. p.autoopen)
end

-- ---------------------------------------------------------------- tabs, opening and closing
U.TAB_IDS = { "session", "chat", "company", "auction", "ai", "rules", "game", "settings" }
-- (0.7.4, the menus redone: new pages by default; the Settings tab's box (oldmenus=1, kept across launches) or MPFEVER_OLDMENUS=1,
-- this player's PC only: the pages of 0.7.3)
U.oldMenus = function()
	if os.getenv("MPFEVER_OLDMENUS") == "1" then return true end
	local okP, p = pcall(U.loadPrefs)
	return okP and type(p) == "table" and p.oldmenus == "1"
end
-- (0.7.4) the Auctions page: while an auction runs, and for the rest of the session once one was seen
U.auctionShown = function(separate)
	if not separate or U.oldMenus() then return false end
	local eco = U.eco
	if eco and (eco.auction or eco.auction2) then U.auctionSeen = true end
	return U.auctionSeen == true or os.getenv("MPFEVER_AUCTIONTEST") == "1"
end
-- (the French names, for MPFEVER_SHOWTAB)
U.TAB_ALIAS = { entreprise = "company", regles = "rules", reglages = "settings", discussion = "chat", ia = "ai", partie = "game" }
U.tabName = function(tab)
	tab = tostring(tab or "session"):lower()
	return U.TAB_ALIAS[tab] or tab
end
-- the tabs of this session: Company and Rules with one company per player only, AI when there are computer companies
U.tabsFor = function(st)
	local separate = st and st.mode == "separate"
	if separate then pcall(U.pollEco) end
	local ai = separate and U.eco ~= nil and next(U.eco.ai or {}) ~= nil
	-- (0.6) the Game tab in the co-op too when it has game options to show (see U.featGameTab)
	local game06 = not separate and U.featGameTab(st)
	local t = {}
	local auction = U.auctionShown(separate)
	for _, id in ipairs(U.TAB_IDS) do
		if (separate or (id ~= "company" and id ~= "rules" and id ~= "game") or (id == "game" and game06)) and (id ~= "ai" or ai) and (id ~= "auction" or auction) then t[#t + 1] = id end
	end
	-- (0.6) a game option's module with a tab of its own while one of its options is on (before Settings, the last one)
	for _, tb in ipairs(U.featTabs(st)) do table.insert(t, #t, tb.key) end
	return t
end
-- (0.6) the small window's tabs: with the Hub, a quick view of the session and the chat only (every page is in the Hub); without it
-- (MPFEVER_HUB=0, the single-list window, a Hub that could not be installed), every tab of the session as before
U.QUICK_TABS = { "session", "chat" }
U.winTabs = function(st)
	if U.HubWindow and U.hubOn() then return U.QUICK_TABS end
	return U.tabsFor(st)
end
-- the tab to show: the one asked, when this session's small window has it, else Session
U.validTab = function(tab, st)
	tab = U.tabName(tab)
	for _, id in ipairs(U.winTabs(st)) do if id == tab then return tab end end
	return "session"
end
U.tabLabel = function(id)
	if id == "session" then return T("Session", "Session") end
	if id == "chat" then
		local n = U.chatUnread or 0
		return T("Chat", "Chat") .. (n > 0 and ("  (" .. n .. ")") or "")
	end
	if id == "company" then return T("Entreprise", "Company") end
	if id == "auction" then
		local on = U.eco and (U.eco.auction or U.eco.auction2)
		return T("Enchères", "Auctions") .. (on and T("  (en cours)", "  (live)") or "")
	end
	if id == "ai" then return T("IA", "AI") end
	if id == "rules" then return T("Règles", "Rules") end
	if id == "game" then return T("Partie", "Game") end
	-- (0.6) a module's own tab: its title
	if tostring(id):sub(1, 2) == "f_" then
		for _, tb in ipairs(U.featTabs(U.status)) do if tb.key == id then return U.featLib().text(tb.title, T) end end
	end
	return T("Réglages", "Settings")
end

-- the window's own state changed (tab, card, a message under a button): its recipe draws again (see U.viewKey)
U.winChanged = function()
	U.winVersion = (U.winVersion or 0) + 1
	if U.winKick then pcall(U.winKick) end
	if U.hubKick then pcall(U.hubKick) end
end
U.viewKey = function()
	return tostring(U.tab) .. "|" .. tostring(U.winVersion or 0) .. "|" .. tostring(U.ecoVersion or 0) .. "|" .. tostring(U.chatUnread or 0) .. "|" .. tostring(U.tab == "ai" and U.aiJVersion or 0)
end

-- the chat counts as read while the window shows its Chat tab (no notice then, see pollChat and the toast)
U.refreshChat = function()
	if not U.newWindow then return end
	U.chatOpen = (U.winOpen == true and not U.compact and U.validTab(U.tab, U.status) == "chat")
		or (U.hubOpen == true and U.hubValid(U.hubPage, U.status) == "chat")
	if U.chatOpen then
		U.chatUnread = 0
		if U.toastShown then
			U.toastShown = false
			local wapi = defaultWindowApi()
			if wapi then pcall(function() wapi.removeAllWindows(U.ChatToast) end) end
		end
	end
end

U.setTab = function(tab)
	U.loadPrefs()
	U.tab = U.tabName(tab)
	U.savePrefs()
	U.refreshChat()
	U.winChanged()
end

-- the small card of issue #68 (the sync, the players and the chat), kept for the session
U.setCompact = function(on)
	U.loadPrefs()
	U.compact = on and true or false
	U.savePrefs()
	U.refreshChat()
	U.winChanged()
end

-- MPFever's window, on a tab (nil: the one it showed last), in the game's window container (the pause menu's is the same one;
-- wapi: the pause menu's, when the game's own cannot be had). Whether it is open.
U.openWindow = function(tab, wapi)
	U.loadPrefs()
	if tab then U.setTab(tab) end
	if U.winOpen then U.refreshChat() return true end
	wapi = defaultWindowApi() or wapi
	if not (wapi and U.SessionWindow) then return false end
	local ok, err = pcall(function() wapi.addSingletonWindow(U.SessionWindow, { onClose = function() U.closeWindow(true) end }) end)
	if not ok then log("window not opened: " .. tostring(err)) return false end
	U.winOpen, U.winApi = true, wapi
	U.prefs.open = "1"
	U.savePrefs()
	U.refreshChat()
	U.winChanged()
	return true
end

U.closeWindow = function(byPlayer)
	local wapi = U.winApi or defaultWindowApi()
	if wapi and U.SessionWindow then pcall(function() wapi.removeAllWindows(U.SessionWindow) end) end
	U.winOpen = false
	-- (closed by the player: it stays closed for the session, also after a resynchronisation's load; a window that went with
	-- the game a resynchronisation reloads opens again after the load)
	if byPlayer and not (U.status and U.status.sync == "resync") then
		U.loadPrefs().open = "0"
		U.savePrefs()
	end
	U.refreshChat()
end

U.toggleWindow = function()
	if U.winOpen then U.closeWindow(true) else U.openWindow(nil) end
end

-- ---------------------------------------------------------------- the Hub (0.6)
-- A big window (about two thirds of the screen, measured from the game's window container) with a menu on its left in three
-- groups: the game (Session, Chat, Rules and options, Public games, Settings), my company (Company, Sharing rules, Team, Trade,
-- Stocks) and the competition (Ranking, Market shares, Tenders, Territories, Journal, AI companies). Only the pages this session
-- has show, by the very rules of the small window's tabs before 0.6 (U.tabsFor): the game options' pages while one of their
-- options is on, Company and the sharing rules with one company per player only. The small window stays as a quick view (Session
-- and Chat) with a button that opens the Hub; the bar's icon and the pause menu's cards still open the small window. The Hub
-- cannot be resized with the mouse (the game's windows take their content's size): three sizes, chosen with its - and + buttons
-- and kept for the session. MPFEVER_HUB=0: no Hub, the small window with every tab as before.
U.hubOn = function() return U.newWindow ~= false and not U.hubOff end
-- (0.8.8) The Hub in the game's own style (see U.makeKit: its cards, headings, bars, menu and choices as the game's Finances and
-- Company windows draw theirs). MPFEVER_OLDHUB=1 (read once): the Hub drawn as in 0.8.7.
U.oldHub = os.getenv("MPFEVER_OLDHUB") == "1"
-- (0.8.8) a page's icon in the Hub's menu, each one of the game's own small icons (checked in gui.zip / game_mechanics.zip; drawn
-- at 24 pixels); a page without one (a game option of a later version) gets the settings' gear
U.HUB_ICON = {
	session = "::/gui/statistics/icons/symbol_person_multiple.tga", chat = "mpfever_1::/mpfever_chat.tga",
	game = "::/gui/menu/icons/configure.tga", f_public = "::/gui/menu/icons/mod_management/mod-public.tga",
	settings = "::/gui/menu/icons/settings.tga", company = "::/gui/main/icons/headquarter.tga",
	auction = "::/game_mechanics/finance/icons/symbol_hand_dollar.tga", rules = "::/game_mechanics/finance/icons/relation_street_track.tga",
	f_team = "::/gui/menu/icons/profile.tga", f_trade = "::/gui/entity_window/icons/symbol_shopping_cart.tga",
	f_stock = "::/game_mechanics/finance/icons/symbol_chart_arrow_up.tga", f_stats = "::/gui/menu/icons/symbol_crown_laurels.tga",
	f_market = "::/gui/radial_menu/icons/symbol_bars_arrow_down_48.tga", f_tenders = "::/game_mechanics/subventions/icons/radial_menu_subventions.tga",
	f_territory = "::/gui/menu/icons/map_town.tga", f_journal = "::/gui/game_bar/icons/notifications.tga",
	ai = "::/gui/game_bar/icons/building_industry_gear_30.tga",
}
U.hubIcon = function(id) return U.HUB_ICON[id] or "::/gui/menu/icons/settings.tga" end
U.HUB_GROUPS = {
	{ key = "game", pages = { "session", "chat", "game", "f_public", "settings" } },
	{ key = "company", pages = { "company", "auction", "rules", "f_team", "f_trade", "f_stock" } },
	{ key = "competition", pages = { "f_stats", "f_market", "f_tenders", "f_territory", "f_journal", "ai" } },
}
U.hubGroupTitle = function(key)
	if key == "company" then return T("Mon entreprise", "My company") end
	if key == "competition" then return T("Compétition", "Competition") end
	return T("Partie", "Game")
end
-- the menu of this session: { { key, title, pages = { id... } }... }, the groups without a page left out; a page no group names
-- (a game option of a later version) goes with the game's pages, before Settings
U.hubMenu = function(st)
	local tabs = U.tabsFor(st)
	local have, placed, out = {}, {}, {}
	for _, id in ipairs(tabs) do have[id] = true end
	for _, g in ipairs(U.HUB_GROUPS) do
		local pages = {}
		for _, id in ipairs(g.pages) do if have[id] then pages[#pages + 1] = id; placed[id] = true end end
		out[#out + 1] = { key = g.key, title = U.hubGroupTitle(g.key), pages = pages }
	end
	for _, id in ipairs(tabs) do
		if not placed[id] then
			local gp = out[1].pages
			local at = #gp + 1
			for i, x in ipairs(gp) do if x == "settings" then at = i end end
			table.insert(gp, at, id)
		end
	end
	local res = {}
	for _, g in ipairs(out) do if #g.pages > 0 then res[#res + 1] = g end end
	return res
end
-- the pages of the menu, in its order
U.hubPages = function(st)
	local out = {}
	for _, g in ipairs(U.hubMenu(st)) do for _, id in ipairs(g.pages) do out[#out + 1] = id end end
	return out
end
-- the page to show: the one asked, when this session has it, else Session
U.hubValid = function(page, st)
	page = U.tabName(page)
	for _, id in ipairs(U.tabsFor(st)) do if id == page then return page end end
	return "session"
end
-- a page's name in the Hub's menu (the small window's tab names, some longer here)
U.hubLabel = function(id)
	if id == "game" then return T("Règles et options", "Rules and options") end
	if id == "rules" then return T("Règles de partage", "Sharing rules") end
	if id == "ai" then return T("Entreprises IA", "AI companies") end
	if id == "f_market" then return T("Concurrence", "Market shares") end
	if id == "f_public" then return T("Parties publiques", "Public games") end
	return U.tabLabel(id)
end
U.hubGroupOf = function(st, page)
	for _, g in ipairs(U.hubMenu(st)) do for _, id in ipairs(g.pages) do if id == page then return g.title end end end
	return ""
end
-- (0.8.8) the Hub's window title: the page's name, as the game's windows have theirs in their title bar and no head in their
-- content (the Company and Finances windows); MPFEVER_OLDHUB=1: « MPFever Hub », the page's name in the content as before
U.hubTitle = function(st)
	if U.oldHub then return "MPFever Hub" end
	local ok, label = pcall(function() return U.hubLabel(U.hubValid(U.hubPage, st)) end)
	if not (ok and type(label) == "string" and label ~= "") then return "MPFever Hub" end
	return "MPFever – " .. label
end
U.hubViewKey = function()
	return tostring(U.hubPage) .. "|" .. tostring(U.winVersion or 0) .. "|" .. tostring(U.ecoVersion or 0) .. "|" .. tostring(U.chatUnread or 0)
		.. "|" .. tostring(U.hubPage == "ai" and U.aiJVersion or 0) .. "|" .. tostring(U.hubSize or 2)
end
-- the screen in the interface's own units: the game's window container (the windows' room), else the 3D view in pixels, else
-- 1920 x 1080; measured again at each opening of the Hub (the resolution may change)
U.hubScreen = function()
	if U.hubScreenWH then return U.hubScreenWH[1], U.hubScreenWH[2] end
	local w, h, how = nil, nil, "default"
	local function size(v)
		local x, y = nil, nil
		pcall(function() x, y = v.x, v.y end)
		if not tonumber(x) then pcall(function() x, y = v[1], v[2] end) end
		x, y = tonumber(x), tonumber(y)
		if x and y and x >= 640 and y >= 400 then return x, y end
		return nil
	end
	pcall(function() w, h = size(api.gui.byId.getSize("GameUiWindowContainer")) end)
	if w then how = "window container" else
		pcall(function() w, h = size(api.gui.camera.getSize()) end)
		if w then how = "3D view" end
	end
	w, h = w or 1920, h or 1080
	-- (0.8.8) The 3D view's size is in the screen's pixels, the interface's sizes are in its own units: on a 4K screen the game
	-- draws its interface twice as large, and the Hub, measured from 3840 x 2054, was 2572 units wide on a screen of 1920: it
	-- covered the whole screen, its frame out of sight and its third column cut ("hub: 1 x 1 of the screen", the user's PC,
	-- 2026-11-14). The pixels of one unit are measured from the Hub itself once it is drawn (U.hubCentre), kept for that screen
	-- (hubu in the ui_prefs.txt kept across launches); until then: 2 on a screen more than 1500 pixels high, else 1.
	-- MPFEVER_HUBUNIT=0: the pixels taken for units, as before
	U.hubPx = { w, h }
	local unit = 1
	if how == "3D view" and os.getenv("MPFEVER_HUBUNIT") ~= "0" then
		unit = U.hubUnitOf(w, h, (U.prefs or U.loadPrefs()).hubu)
		w, h = w / unit, h / unit
	end
	U.hubUnitNow = unit
	U.hubScreenWH = { w, h }
	log("hub: screen " .. math.floor(w) .. " x " .. math.floor(h) .. " (" .. how .. (unit ~= 1 and string.format(", %.3g pixels a unit", unit) or "") .. ")")
	return w, h
end
-- (pure) the pixels of one interface unit for a screen of w x h pixels: the one measured for that screen (kept: "w,h,unit"),
-- else 2 above 1500 pixels of height, else 1
U.hubUnitOf = function(w, h, kept)
	local kw, kh, ku = tostring(kept or ""):match("^(%d+),(%d+),([%d%.]+)$")
	ku = tonumber(ku)
	if ku and tonumber(kw) == math.floor(w) and tonumber(kh) == math.floor(h) and ku >= 0.5 and ku <= 4 then return ku end
	return h > 1500 and 2 or 1
end
-- (pure) what the Hub's measured size says of the unit: fw, fh = the parts of the screen it takes, W, H = its size in units,
-- pw, ph = the screen in pixels, unit = the unit it was drawn with. Returns the unit to keep and whether the Hub must be drawn
-- again: a Hub that takes the whole width or height is cut by the screen (the unit is larger than thought: half as many units
-- next time); else the unit is its pixels by its units, drawn again when it differs by more than 8 %.
U.hubUnitFrom = function(fw, fh, W, H, pw, ph, unit)
	if fw >= 0.97 or fh >= 0.97 then return math.min(4, unit * 1.5), true end
	local m = math.max(0.5, math.min(4, fw * pw / W))
	return m, math.abs(m - unit) / unit > 0.08
end
-- the Hub's measures from the screen and its size (1 small, 2 about two thirds of the screen, 3 large): the window, the menu, the
-- page (its scroll area), the page's content and its texts (a card takes the content's width, its texts the text width)
U.HUB_SCALES = { 0.55, 0.67, 0.8 }
U.hubMeasures = function()
	local sw, sh = U.hubScreen()
	local f = U.HUB_SCALES[U.hubSize or 2] or 0.67
	local W = math.floor(math.max(900, math.min(math.max(900, sw - 40), sw * f)))
	local H = math.floor(math.max(520, math.min(math.max(520, sh - 140), sh * f)))
	local side = W >= 1300 and 250 or 220
	local pageW = W - side - 14
	local inner = pageW - 22
	-- (0.8.8: the game's cards have 18 pixels of padding on each side, the Hub's had 12; MPFEVER_OLDHUB=1: as before)
	return { W = W, H = H, side = side, bodyH = H - 70, pageW = pageW, inner = inner, text = inner - (U.oldHub and 24 or 40) }
end

-- the Hub, on a page (nil: the one it showed last), in the game's window container (wapi: another one, when the game's own
-- cannot be had); brought to the front when it is open already. Whether it is open.
U.openHub = function(page, wapi)
	if not U.hubOn() then return false end
	local p = U.loadPrefs()
	if page and page ~= "" then U.hubPage = U.tabName(page) end
	U.hubPage = U.hubPage or p.hubpage or "session"
	U.hubSize = U.hubSize or tonumber(p.hubsize) or 2
	p.hubpage = U.hubPage
	U.savePrefs()
	if U.hubOpen then
		local w = U.hubApi or defaultWindowApi()
		if w then pcall(function() w.moveSingletonWindowToFront(U.HubWindow) end) end
		U.refreshChat()
		U.winChanged()
		return true
	end
	wapi = defaultWindowApi() or wapi
	if not (wapi and U.HubWindow) then return false end
	U.hubScreenWH = nil
	local ok, err = pcall(function() wapi.addSingletonWindow(U.HubWindow, { onClose = function() U.closeHub() end }) end)
	if not ok then log("hub: not opened: " .. tostring(err)) return false end
	U.hubOpen, U.hubApi = true, wapi
	-- (0.7.5, see U.hubCentre)
	U.hubCenterDue = 6
	-- (the small window, the quick view, stood out behind the Hub: it closes while the Hub is open, not as the player's choice,
	-- so it still opens by itself after a reload. MPFEVER_HUBHIDESMALL=0: it stays)
	if U.winOpen and os.getenv("MPFEVER_HUBHIDESMALL") ~= "0" then pcall(U.closeWindow, false) end
	log("hub: opened on the " .. U.hubValid(U.hubPage, U.status) .. " page")
	U.refreshChat()
	U.winChanged()
	return true
end
-- (0.7.5) Where the Hub opens. The game places a window by its first size, before the Hub's pages are laid out (no size yet), and
-- keeps it there by its id for the rest of the session (initialX/Y is read once: seen in game, a Hub opened again kept its place;
-- a window whose id changes while shown is a fatal assertion). With 0.5/0.45 the Hub's top left corner landed in the middle of
-- the screen and a larger Hub ran off a small screen (1280 x 895). Once laid out, the Hub's size is read as a part of the
-- screen (api.gui.byId.getSize, from onStep: the interface's API is refused in a timer; the game gives parts of the screen,
-- the Hub 0.475 x 0.478 of 1 x 1) and compared with its measures: the ratio is kept (hubk in the ui_prefs.txt kept across
-- launches, for that screen), and the next openings put its top left corner where it is centred, from the first frame.
U.hubCentre = function()
	local function wh(id)
		local x, y
		pcall(function() local v = api.gui.byId.getSize(id); x, y = tonumber(v.x or v[1]), tonumber(v.y or v[2]) end)
		return x, y
	end
	local hw, hh = wh("window.mpfever.hub")
	local cw, ch = wh("GameUiWindowContainer")
	if not (cw and ch and cw > 0 and ch > 0) then cw, ch = wh("mainView") end
	if not (hw and hh and cw and ch and hw > 0 and hh > 0 and cw > 0 and ch > 0 and hw <= cw * 1.5 and hh <= ch * 1.5) then
		log("hub: its size not read (hub " .. tostring(hw) .. " x " .. tostring(hh) .. ", screen " .. tostring(cw) .. " x " .. tostring(ch) .. ")")
		return
	end
	local m = U.hubMeasures()
	local sw, sh = U.hubScreen()
	local p = U.loadPrefs()
	-- (0.8.8: the pixels of one unit, from the Hub's own size, see U.hubScreen; a Hub cut by the screen, or drawn with a unit
	-- that is not the screen's, is drawn again once with the unit found, at most 3 times for an opening)
	if U.hubPx and U.hubUnitNow and os.getenv("MPFEVER_HUBUNIT") ~= "0" then
		local unit, again = U.hubUnitFrom(hw / cw, hh / ch, m.W, m.H, U.hubPx[1], U.hubPx[2], U.hubUnitNow)
		local kept = string.format("%d,%d,%.4g", math.floor(U.hubPx[1]), math.floor(U.hubPx[2]), unit)
		if p.hubu ~= kept then p.hubu = kept; pcall(U.saveGlobalPrefs) end
		if again and (U.hubUnitTries or 0) < 3 then
			U.hubUnitTries = (U.hubUnitTries or 0) + 1
			log(string.format("hub: %.3g x %.3g of the screen with %.3g pixels a unit: drawn again with %.3g", hw / cw, hh / ch, U.hubUnitNow, unit))
			-- (its content is drawn again with the screen measured again, and its size read again a few frames later; never
			-- closed and opened for it: the game keeps a window's place by its id)
			p.hubk = nil
			U.hubScreenWH = nil
			U.hubCenterDue = 6
			pcall(U.winChanged)
			return
		end
		U.hubUnitTries = 0
	end
	-- (the part of the screen the Hub takes for each unit of its measures: its frame and title included)
	local rx, ry = (hw / cw) / m.W, (hh / ch) / m.H
	local key = string.format("%d,%d", math.floor(sw), math.floor(sh))
	local old = p.hubk
	p.hubk = string.format("%s,%.8g,%.8g", key, rx, ry)
	if old ~= p.hubk then pcall(U.saveGlobalPrefs) end
	log(string.format("hub: %.3g x %.3g of the screen (%s): kept for its next openings, centred", hw / cw, hh / ch, key))
end
-- the Hub's initialX/Y: its top left corner where it is centred, when its ratio is known for this screen (see U.hubCentre)
U.hubAt = function()
	if os.getenv("MPFEVER_HUBCENTER") == "0" then return 0.5, 0.45 end
	local p = U.prefs or U.loadPrefs()
	local sw, sh = U.hubScreen()
	local w, h, rx, ry = tostring(p.hubk or ""):match("^(%d+),(%d+),([%d%.eE%-]+),([%d%.eE%-]+)$")
	rx, ry = tonumber(rx), tonumber(ry)
	if not (rx and ry) or tonumber(w) ~= math.floor(sw) or tonumber(h) ~= math.floor(sh) then
		-- (0.8.8) nothing measured for this screen yet: centred from its measures, the screen being in the interface's units
		-- (U.hubScreen), its title 40 units more; before, its top left corner was put near the middle of the screen (0.5, 0.45) and
		-- the first Hub of a screen ran off it. MPFEVER_HUBFIRSTAT=0: 0.5, 0.45 as before
		if os.getenv("MPFEVER_HUBFIRSTAT") == "0" then return 0.5, 0.45 end
		local m0 = U.hubMeasures()
		return math.max(0, (1 - m0.W / sw) / 2), math.max(0, (1 - (m0.H + 40) / sh) / 2)
	end
	local m = U.hubMeasures()
	return math.max(0, (1 - rx * m.W) / 2), math.max(0, (1 - ry * m.H) / 2)
end
U.closeHub = function()
	local wapi = U.hubApi or defaultWindowApi()
	if wapi and U.HubWindow then pcall(function() wapi.removeAllWindows(U.HubWindow) end) end
	U.hubOpen = false
	U.refreshChat()
end
U.setHubPage = function(page)
	local p = U.loadPrefs()
	U.hubPage = U.tabName(page)
	p.hubpage = U.hubPage
	U.savePrefs()
	U.refreshChat()
	U.winChanged()
end
U.setHubSize = function(d)
	local p = U.loadPrefs()
	U.hubSize = math.max(1, math.min(#U.HUB_SCALES, (U.hubSize or 2) + d))
	p.hubsize = tostring(U.hubSize)
	U.savePrefs()
	-- (the game keeps a window where it was put for its first size: a larger Hub grew to the right, off the middle of the screen.
	-- Opened again at its new size, it is centred again. MPFEVER_HUBRECENTER=0: as before)
	if U.hubOpen and os.getenv("MPFEVER_HUBRECENTER") ~= "0" then
		local page = U.hubPage
		pcall(U.closeHub)
		pcall(U.openHub, page)
	end
	U.winChanged()
end

-- The window opens by itself at the start of a session and again after each load of a resynchronisation, on the tab it showed.
-- It stays closed when the player closed it in this session, unticked « Open MPFever when a game starts » (Settings tab), in the
-- autotests (MPFEVER_SCENARIO or MPFEVER_SAVE set, unless MPFEVER_SHOWWIN=1) and in a dedicated server's own game. MPFEVER_SHOWWIN=1 opens it
-- in any case, on the tab MPFEVER_SHOWTAB names (screenshots). MPFEVER_AUTOOPEN=0: it opens only when asked, as before.
U.autoOpenTick = function()
	if U.autoOpenDone or not (U.SessionWindow and U.status) then return end
	local now = os.clock()
	if U.autoOpenAt and now - U.autoOpenAt < 1 then return end
	U.autoOpenAt = now
	local p = U.loadPrefs()
	local why = nil
	if os.getenv("MPFEVER_SHOWWIN") ~= "1" then
		if os.getenv("MPFEVER_AUTOOPEN") == "0" then why = "MPFEVER_AUTOOPEN=0"
		elseif os.getenv("MPFEVER_SCENARIO") or os.getenv("MPFEVER_SAVE") then why = "autotest"
		elseif C.SERVER then why = "a dedicated server's game"
		elseif p.open == "0" then why = "closed by the player in this session"
		elseif p.open == nil and p.autoopen == "0" then why = "the player's choice in the Settings tab" end
	end
	if why then
		U.autoOpenDone = true
		log("window: not opened by itself (" .. why .. ")")
		return
	end
	if os.getenv("MPFEVER_SHOWWIN") == "1" and U.compact then U.compact = false end
	if U.openWindow(os.getenv("MPFEVER_SHOWTAB") or p.tab or "session") then
		U.autoOpenDone = true
		log("window: opened by itself on the " .. U.validTab(U.tab, U.status) .. " tab")
		-- (0.6, screenshots) MPFEVER_SHOWHUB=<page>: the Hub opens too, on that page; so does a tab of MPFEVER_SHOWTAB that the
		-- small window no longer has (Company, Rules, Game, Settings, a game option's)
		local hubPage = os.getenv("MPFEVER_SHOWHUB")
		local showTab = os.getenv("MPFEVER_SHOWTAB")
		if (not hubPage or hubPage == "") and showTab and U.HubWindow and U.hubOn() and U.validTab(showTab, U.status) ~= U.tabName(showTab) then hubPage = showTab end
		if hubPage and hubPage ~= "" then pcall(U.openHub, hubPage) end
	end
end

-- (autotests, the window scenario: MPFEVER_SCENARIO=wintabs) a tab asked by the bridge (ui_tab_req.txt: "tab TAB number"); the
-- window then says which tab it drew (ui_tab_shown.txt: "number TAB asked TAB drawn TAB ok or the error TAB rows")
U.pollTabReq = function()
	local now = os.clock()
	if U.tabReqAt and now - U.tabReqAt < 0.5 then return end
	U.tabReqAt = now
	local f = C.IO.open(C.DIR .. C.BS .. "ui_tab_req.txt", "rb")
	if not f then return end
	local s = f:read("*a") or ""
	f:close()
	-- (a game option's tab too: "f_<id>", 0.6; a page of the Hub: "hub:<page>", "hub:" its first page)
	local tab, seq = s:match("^([%w_:]+)" .. C.TAB .. "(%d+)")
	if not tab or seq == U.tabReqSeq or not U.SessionWindow then return end
	-- (0.6) with the Hub, a tab the small window no longer has is drawn by the Hub
	local hubPage = tab:match("^hub:(.*)$")
	if not hubPage and U.HubWindow and U.hubOn() then
		local quick = false
		for _, id in ipairs(U.QUICK_TABS) do if id == U.tabName(tab) then quick = true end end
		if not quick then hubPage = tab end
	end
	if hubPage then
		if not U.HubWindow then return end
		if U.openHub(hubPage ~= "" and hubPage or "session") then
			U.tabReqSeq, U.tabReqTab, U.tabReqDone, U.tabReqHub = seq, tab, nil, true
			U.winChanged()
			log("autotest: hub shown for the " .. tab .. " page")
		end
		return
	end
	U.compact = false
	if U.openWindow(tab) then
		U.tabReqSeq, U.tabReqTab, U.tabReqDone, U.tabReqHub = seq, tab, nil, nil
		U.winChanged()
		log("autotest: window shown for the " .. tab .. " tab")
	end
end
-- (pages: the Hub's pages of this session, "a,b,c", after the rows: the window scenario then visits each of them)
U.ackTabReq = function(shown, result, nRows, pages)
	if not U.tabReqSeq or U.tabReqDone == U.tabReqSeq then return end
	U.tabReqDone = U.tabReqSeq
	local f = C.IO.open(C.DIR .. C.BS .. "ui_tab_shown.txt", "wb")
	if f then
		f:write(U.tabReqSeq .. C.TAB .. tostring(U.tabReqTab) .. C.TAB .. shown .. C.TAB .. tostring(result):gsub("[%c]", " ") .. C.TAB .. tostring(nRows)
			.. (pages and (C.TAB .. pages) or "") .. C.NL)
		f:close()
	end
	log("autotest: the " .. shown .. (pages and " page of the hub" or " tab") .. " drawn (" .. tostring(U.tabReqTab) .. " asked): " .. tostring(result) .. ", " .. tostring(nRows) .. " rows")
end

-- ---------------------------------------------------------------- small helpers of the tabs
-- a text's width in average characters: a wide character (Chinese, Japanese, Korean: 3 bytes or more in UTF-8) counts two
U.textWidth = function(t)
	local n = 0
	for ch in tostring(t or ""):gmatch(UTF8_CHAR) do n = n + (#ch >= 3 and 2 or 1) end
	return n
end
-- a name cut to n characters (combo boxes: a long company name must not widen the row)
U.short = function(t, n)
	t = tostring(t or "")
	if ulen(t) > n then return usub(t, n - 1) .. "…" end
	return t
end
U.hhmm = function(t)
	local ok, s = pcall(os.date, "%H:%M", t)
	return ok and s or ""
end
-- this player is the session's host (a dedicated server has no host player)
U.isHost = function(st)
	for _, pl in ipairs(st and st.players or {}) do
		if pl.id == st.me and pl.role == "host" then return true end
	end
	return false
end
-- a speed for the session, asked as the game's own speed buttons ask it (the lockstep's wrapper sends it to MPFever.exe)
U.setSpeed = function(v)
	local ok, err = pcall(function() api.cmd.sendCommand(api.cmd.makeGameSetSpeedCmd(v)) end)
	if not ok then log("speed " .. tostring(v) .. " not asked: " .. tostring(err)) end
end
-- a company's money and figures, on one line
U.coFigures = function(c)
	return money(c.bal) .. (c.rank and ("  ·  " .. C.Tf("rang %s", "rank %s", c.rank)) or "")
		.. "  ·  " .. C.Tf("%s lignes, %s véhicules", "%s lines, %s vehicles", c.lines, c.veh)
end
-- a company's colour swatch
U.swatch = function(K, id, size)
	local CO = U.coLib()
	local ix = U.coColors and U.coColors[id] or id
	local c = nil
	if CO then pcall(function() local r, g, b = CO.rgb(ix); c = api.type.Vec4f.new(r, g, b, 1) end) end
	return K.builtin.Component { meta = { styleSheet = K.style { size = { size or 14, size or 14 }, image = K.DISC, bg = c } } }
end
-- a gift of money to another company (event "give", applied by every game at the same step: see the bridge's handleEvent)
U.give = function(c, ctx, myBal)
	local n = tonumber((tostring(ctx.amount:old() or ""):gsub("[%s%.,']", "")))
	if not n or n <= 0 then U.giveMsg = T("Entrez un montant.", "Enter an amount.") U.winChanged() return end
	n = math.floor(n)
	if myBal and n > myBal then U.giveMsg = T("Pas assez d'argent.", "Not enough money.") U.winChanged() return end
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "give", { to = c.id, amount = n }))
	end)
	if not ok then
		log("companies: gift request failed: " .. tostring(err))
		U.giveMsg = T("Envoi impossible.", "Could not send.")
		U.winChanged()
		return
	end
	U.giveMsg = C.Tf("%s envoyés à %s.", "%s sent to %s.", money(n), c.name)
	log("companies: gift of " .. n .. " to company " .. c.id .. " requested")
	pcall(sendChat, "→ " .. c.name .. " : " .. money(n))
	ctx.amount:set("")
	ctx.giveGen:set(ctx.giveGen:old() + 1)
	U.winChanged()
end

-- (0.8.3, Zoey's suggestion) A loan between this player's company and company c, in c's sheet: the offer under way (its terms, and
-- Accept / Refuse / a counter-offer when it is this company's turn, Withdraw else), else the fields to ask for one (the borrower
-- asks: amount, months, interest in % of the amount for the whole loan); the loans under way between the two. The events go to
-- every game (mpfever_eco.lua: E.loanEvent), which checks the terms, the chiefs and the lender's money.
U.loanIn = U.loanIn or {}
U.loanNum = function(v)
	return tonumber((tostring(v or ""):gsub("[%s%.,'%%]", "")))
end
-- (0.8.5, #266) the form keeps what was typed (the card is drawn again on every refresh: its fields came back empty, showing
-- their grey examples, and Creeper took "1000000" for the amount the field went back to), an empty field counts as its grey
-- example (1000000, 12, 10: Akamari's ask never left the form, "Enter an amount"), and the fields are emptied once sent.
-- MPFEVER_LOANFORMKEEP=0: as in 0.8.3
U.LOANFORM = os.getenv("MPFEVER_LOANFORMKEEP") ~= "0"
U.LOAN_DEFAULTS = { a = "1000000", m = "12", r = "10" }
U.loanSend = function(name, param)
	U.loanMsg = nil
	if not U.coSend(name, param) then U.loanMsg = T("Envoi impossible.", "Could not send.")
	elseif U.LOANFORM then U.loanIn = {} end
	U.loanGen = (U.loanGen or 0) + 1
	U.winChanged()
end
U.loanTermsIn = function(c)
	local i = U.loanIn[c.id] or {}
	local function val(k)
		local v = i[k]
		if U.LOANFORM and (v == nil or tostring(v):match("^%s*$")) then v = U.LOAN_DEFAULTS[k] end
		return v
	end
	local a, m, r = U.loanNum(val("a")), U.loanNum(val("m")), U.loanNum(val("r"))
	if not a or a <= 0 then return nil, T("Entrez un montant.", "Enter an amount.") end
	if not m or m < 1 or m > 120 then return nil, T("Durée : de 1 à 120 mois.", "Duration: 1 to 120 months.") end
	if not r or r < 0 or r > 100 then return nil, T("Intérêts : de 0 à 100 %.", "Interest: 0 to 100 %.") end
	return { amount = math.floor(a), months = math.floor(m), rate = math.floor(r) }
end
U.loanCard = function(K, c, eco)
	if not U.myCo then return nil end
	local me = U.myCo
	local card = {}
	local function fields(c2)
		local g = tostring(U.loanGen or 0)
		local function field(key, ph, w)
			return K.builtin.TextInputField {
				meta = { class = "font-scale-body", localKey = "mpfever-loan-" .. key .. "-" .. g .. "-" .. c2.id, styleSheet = K.style { size = { w, -1 } } },
				value = U.LOANFORM and tostring((U.loanIn[c2.id] or {})[key] or "") or "", placeholderText = ph, maxLength = 15, acceptOnFocusLoss = true,
				onTyping = function(v) U.loanIn[c2.id] = U.loanIn[c2.id] or {}; U.loanIn[c2.id][key] = v end,
				onValueChange = function(v) U.loanIn[c2.id] = U.loanIn[c2.id] or {}; U.loanIn[c2.id][key] = v end,
			}
		end
		return K.row { K.muted(T("Montant", "Amount"), 70), field("a", "1000000", 130), K.gap(8, 1), K.muted(T("Mois", "Months"), 50), field("m", "12", 60),
			K.gap(8, 1), K.muted(T("Intérêts %", "Interest %"), 80), field("r", "10", 60) }
	end
	-- the offer under way between the two companies
	local offer = nil
	for _, o in ipairs(eco.loanOffers or {}) do
		if (o.borrower == me and o.lender == c.id) or (o.lender == me and o.borrower == c.id) then offer = o end
	end
	if offer then
		local total = math.floor(offer.amount * (100 + offer.rate) / 100 + 0.5)
		local iBorrow = offer.borrower == me
		card[#card + 1] = K.text(C.Tf(iBorrow and "Vous empruntez %s sur %s mois, à %s % : %s à rembourser." or "Elle vous emprunte %s sur %s mois, à %s % : %s à rembourser.",
			iBorrow and "You borrow %s over %s month(s), at %s %: %s to pay back." or "It borrows %s from you over %s month(s), at %s %: %s to pay back.",
			money(offer.amount), offer.months, offer.rate, money(total)), nil, nil, K.CARD_TEXT_W)
		local myTurn = (offer.turn == "lender" and offer.lender == me) or (offer.turn == "borrower" and offer.borrower == me)
		if myTurn then
			card[#card + 1] = K.row {
				K.btn(T("Accepter", "Accept"), nil, function() U.loanSend("co_loan_answer", { id = offer.id, accept = true }) end, true, nil, K.ICON_ACCEPT),
				K.gap(8, 1),
				K.btn(T("Refuser", "Refuse"), nil, function() U.loanSend("co_loan_answer", { id = offer.id, accept = false }) end, false, nil, K.ICON_REFUSE),
			}
			card[#card + 1] = K.gap(1, 6)
			card[#card + 1] = K.muted(T("Ou proposez d'autres conditions :", "Or offer other terms:"), K.CARD_TEXT_W)
			card[#card + 1] = fields(c)
			card[#card + 1] = K.row { K.btn(T("Contre-proposition", "Counter-offer"), nil, function()
				local t, why = U.loanTermsIn(c)
				if not t then U.loanMsg = why; U.winChanged(); return end
				U.loanSend("co_loan_counter", { id = offer.id, amount = t.amount, months = t.months, rate = t.rate })
			end) }
		else
			card[#card + 1] = K.muted(T("En attente de sa réponse.", "Waiting for its answer."), K.CARD_TEXT_W)
			card[#card + 1] = K.row { K.btn(T("Retirer", "Withdraw"), nil, function() U.loanSend("co_loan_cancel", { id = offer.id }) end) }
		end
	else
		card[#card + 1] = K.muted(T("Demander un prêt à cette entreprise : vous fixez le montant, la durée et les intérêts que vous offrez (en % du montant, pour tout le prêt). Vous remboursez une part chaque mois.",
			"Ask this company for a loan: you set the amount, the duration and the interest you offer (in % of the amount, for the whole loan). You pay back a part each month."), K.CARD_TEXT_W)
		card[#card + 1] = fields(c)
		card[#card + 1] = K.row { K.btn(T("Demander le prêt", "Ask for the loan"), nil, function()
			local t, why = U.loanTermsIn(c)
			if not t then U.loanMsg = why; U.winChanged(); return end
			U.loanSend("co_loan_ask", { to = c.id, amount = t.amount, months = t.months, rate = t.rate })
		end, true) }
	end
	-- the loans under way between the two
	for _, l in ipairs(eco.loans or {}) do
		if l.borrower == me and l.lender == c.id then
			card[#card + 1] = K.text(C.Tf("Vous lui devez encore %s (%s par mois).", "You still owe it %s (%s a month).", money(l.rest), money(l.monthly)), nil, "warning", K.CARD_TEXT_W)
		elseif l.lender == me and l.borrower == c.id then
			card[#card + 1] = K.text(C.Tf("Elle vous doit encore %s (%s par mois).", "It still owes you %s (%s a month).", money(l.rest), money(l.monthly)), nil, K.moneyCls("success"), K.CARD_TEXT_W)
		end
	end
	card[#card + 1] = K.muted(T("Seul le chef d'une entreprise peut demander ou accepter un prêt.", "Only a company's chief can ask for or accept a loan."), K.CARD_TEXT_W)
	if U.loanMsg then card[#card + 1] = K.muted(U.loanMsg, K.CARD_TEXT_W) end
	return card
end

-- ---------------------------------------------------------------- the tabs (each one a list of rows, drawn in a scroll area)
U.TABS = {}

-- The host's [Resynchronise] button: every game reloads the host's game (MPFever.exe's "resync" request). MPFever.exe allows one
-- resynchronisation every 2 minutes and says how long is left (resyncin= in mp_status.txt): the button waits until then. A
-- dedicated server has no host player: nobody has the button there. MPFEVER_RESYNCBUTTON=0: no button, as before.
U.resyncRows = function(K, st, rows)
	if os.getenv("MPFEVER_RESYNCBUTTON") == "0" or not st or st.started ~= "1" then return end
	local W = K.TEXT_W
	if not U.isHost(st) then
		rows[#rows + 1] = K.muted(T("Seul l'hôte peut demander une resynchronisation.", "Only the host can ask for a resynchronisation."), W)
		return
	end
	local left = tonumber(st.resyncin) or 0
	local note, enabled = nil, false
	if st.sync == "resync" then note = T("Resynchro…", "Resyncing…")
	elseif U.resyncAskedAt and os.clock() - U.resyncAskedAt < 15 then note = T("Resynchronisation demandée…", "Resynchronisation asked…")
	elseif playerCount(st) < 2 then note = T("Aucun autre joueur à resynchroniser.", "No other player to resynchronise.")
	elseif left > 0 then note = C.Tf("Possible dans %s s (une seule toutes les 2 minutes).", "Available in %s s (one every 2 minutes).", math.ceil(left))
	else note, enabled = T("Tous les jeux rechargent votre partie (une minute environ).", "Every game reloads your game (about a minute)."), true end
	rows[#rows + 1] = K.gap(1, 4)
	rows[#rows + 1] = K.row { K.btn(T("Resynchroniser", "Resynchronise"), T("Recharger votre partie chez tous les joueurs", "Reload your game on every player's PC"), function()
		if U.menuRequest("resync") then
			U.resyncAskedAt = os.clock()
			U.winChanged()
		end
	end, false, enabled, K.ICON_SYNC) }
	rows[#rows + 1] = K.muted(note, W)
end

-- Session: the host, the link, the sync (and the host's resynchronisation), the speed, the players, the invitations
U.TABS.session = function(K, st, ctx)
	local rows = {}
	local W = K.TEXT_W
	if st and st.host then
		-- (a dedicated server: its name as its settings write it)
		local hostText = st.server == "1" and C.Tf("Serveur dédié : %s", "Dedicated server: %s", (st.title and st.title ~= "") and st.title or st.host)
			or C.Tf("Hôte : %s", "Host: %s", st.host)
		rows[#rows + 1] = K.muted(hostText .. "  ·  "
			.. (st.mode == "separate" and T("Une entreprise par joueur", "One company per player") or T("Une entreprise pour tous", "One company for everybody")), W)
	end
	local link, linkCls = linkLine(st)
	if link then rows[#rows + 1] = K.row { K.dot(linkCls), K.gap(8, 1), K.text(link, nil, linkCls, W - 22) } end
	rows[#rows + 1] = K.gap(1, 8)
	rows[#rows + 1] = K.section(K.ICON_SYNC, T("Synchronisation", "Sync"))
	local sync, syncCls = syncLine(st)
	rows[#rows + 1] = K.row { K.dot(syncCls), K.gap(8, 1), K.text(sync, nil, syncCls, W - 22) }
	local desyncs, resyncs = tonumber(st and st.desyncs) or 0, tonumber(st and st.resyncs) or 0
	if desyncs > 0 or resyncs > 0 then
		rows[#rows + 1] = K.muted(C.Tf("%s désynchronisation(s) et %s resynchronisation(s) depuis le début", "%s desync(s) and %s resync(s) since the start", desyncs, resyncs), W)
	end
	U.resyncRows(K, st, rows)
	-- the session's speed, as the game's own speed buttons ask it (only once MPFever holds the commands back)
	if U.installed and st and st.started == "1" then
		rows[#rows + 1] = K.gap(1, 8)
		rows[#rows + 1] = K.section(K.ICON_SPEED, T("Vitesse", "Speed"))
		local cur = tonumber(st.speed)
		-- (0.8.8, the Hub's new drawing: the game bar's own speed buttons, a group of toggle buttons with its playback icons
		-- (gui/game_bar/game_bar_widgets.tl), see K.choice; a click always asks, on the speed shown too, as the buttons did)
		local speeds = { 0, 1, 2, 4 }
		local items, sel = {}, nil
		for i, v in ipairs(speeds) do
			items[i] = { icon = (K.ICON_SPEEDS or {})[v], label = v == 0 and "II" or ("x" .. v), tip = v == 0 and T("Pause", "Pause") or ("x" .. v) }
			if cur == v then sel = i end
		end
		local group = K.choice and K.choice(items, sel, function(i) if speeds[i] ~= nil then U.setSpeed(speeds[i]) end end, "speed")
		if group ~= nil then
			rows[#rows + 1] = K.row { group }
		else
			local r = {}
			for i, v in ipairs(speeds) do
				if i > 1 then r[#r + 1] = K.gap(6, 1) end
				r[#r + 1] = K.btn(v == 0 and "II" or ("x" .. v), v == 0 and T("Pause", "Pause") or nil, function() U.setSpeed(v) end, cur == v)
			end
			rows[#rows + 1] = K.row(r)
		end
	end
	rows[#rows + 1] = K.gap(1, 8)
	rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")")
	-- (0.6, the host's game options join_bans and join_approve) Kick and Ban on each player's line, Accept and Refuse for each
	-- arrival waiting: the host's own lines of mp_status.txt, pubkick= and pending= (launcher/PublicGames.cs)
	local kick = st and st.pubkick == "1" and U.isHost(st)
	for _, pl in ipairs(st and st.players or {}) do
		if pl.role ~= "server" then
			local line, cls = playerLine(pl, st.me)
			if kick and pl.role ~= "host" and pl.state ~= "left" then
				local who = pl.name
				rows[#rows + 1] = K.row { K.icon(K.ICON_PERSON, 20), K.gap(6, 1), K.text(line, nil, cls, W - 206 - K.iw(2)),
					K.btn(T("Exclure", "Kick"), nil, function() U.menuRequest("kick", who) end, false, nil, K.ICON_KICK), K.gap(6, 1),
					K.btn(T("Bannir", "Ban"), nil, function() U.menuRequest("ban", who) end, false, nil, K.ICON_BAN) }
			else
				rows[#rows + 1] = K.row { K.icon(K.ICON_PERSON, 20), K.gap(6, 1), K.text(line, nil, cls, W - 26) }
			end
		end
	end
	if st and (st.pending or "") ~= "" and U.isHost(st) then
		for who in st.pending:gmatch("[^,]+") do
			local id = who
			rows[#rows + 1] = K.gap(1, 4)
			rows[#rows + 1] = K.text(C.Tf("%s veut rejoindre la partie", "%s wants to join the game", (id:gsub("#%d+$", ""))), nil, "warning", W)
			rows[#rows + 1] = K.row { K.btn(T("Accepter", "Accept"), nil, function() U.menuRequest("admit", id .. " 1") end, true, nil, K.ICON_ACCEPT), K.gap(6, 1),
				K.btn(T("Refuser", "Refuse"), nil, function() U.menuRequest("admit", id .. " 0") end, false, nil, K.ICON_REFUSE) }
		end
	end
	if st and st.invite == "1" and U.isHost(st) then
		rows[#rows + 1] = K.gap(1, 6)
		rows[#rows + 1] = K.row { K.btn(T("Inviter des amis Steam", "Invite Steam friends"), nil, requestInvite, true) }
	end
	-- the signals on the map (0.5.14): a kind, then a click on the map; every player sees it 12 s (see the bridge's H.ping)
	if st and st.started == "1" and os.getenv("MPFEVER_PINGS") ~= "0" then
		rows[#rows + 1] = K.gap(1, 8)
		rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Signaux sur la carte", "Map signals"))
		local r = {}
		for i, k in ipairs({ "here", "warn", "build" }) do
			if i > 1 then r[#r + 1] = K.gap(6, 1) end
			local kind = k
			r[#r + 1] = K.btn(U.pingName(k), nil, function() sendLine("ping_arm", { k = kind }); U.pingArmedAt = os.clock(); U.winChanged() end)
		end
		if U.lastPing then
			r[#r + 1] = K.gap(12, 1)
			r[#r + 1] = K.btn(T("Voir le dernier", "Show the last"), nil, function()
				local x = U.lastPing
				pcall(function() api.gui.camera.focusPosition(api.type.Vec3f.new(x.x, x.y, x.z or 0), 400) end)
			end, false, nil, K.ICON_LOCATE)
		end
		rows[#rows + 1] = K.row(r)
		rows[#rows + 1] = K.muted((U.pingArmedAt and os.clock() - U.pingArmedAt < 15) and T("Cliquez sur la carte pour placer le signal (15 s).", "Click on the map to place the signal (15 s).")
			or T("Choisissez un signal, puis cliquez sur la carte : tous les joueurs le voient 12 s.", "Pick a signal, then click on the map: every player sees it for 12 s."), W)
	end
	rows[#rows + 1] = K.gap(1, 12)
	-- (0.6.2, #105) the problem report here too: since 0.6 the small window shows Session and Chat only, and the button of the
	-- Settings tab was found in the Hub only ("the in-game button to report issues seems to have disappeared").
	-- MPFEVER_SESSIONREPORT=0: in Settings only, as before
	local reportBtn = os.getenv("MPFEVER_SESSIONREPORT") ~= "0" and requestReport or nil
	rows[#rows + 1] = K.row { K.btn(T("Réduire", "Reduce"), T("Une petite carte : la synchronisation, les joueurs et la discussion", "A small card: the sync, the players and the chat"),
		function() U.setCompact(true) end), reportBtn and K.gap(8, 1) or nil,
		reportBtn and K.btn(U.reportLabel(), T("MPFever.exe rassemble les journaux dans un zip et ouvre un nouveau ticket GitHub.", "MPFever.exe gathers the logs into a zip and opens a new GitHub issue."), reportBtn) or nil }
	if reportBtn and U.reportMsg and U.reportAsked and os.time() - U.reportAsked <= 120 then rows[#rows + 1] = K.muted(U.reportMsg, W) end
	return rows
end

-- a map signal's kind, in this game's language
U.pingName = function(k)
	if k == "warn" then return T("Attention", "Watch out") end
	if k == "build" then return T("Construire ici", "Build here") end
	return T("Ici", "Here")
end

-- The map signals shown on this game (ping_journal.txt, written by the bridge's H.ping): told in the chat, the last one kept for
-- the "Show the last" button. Read every second; the lines there when the game loaded are not told again.
U.pollPings = function()
	local now = os.clock()
	if U.pingAt and now - U.pingAt < 1 then return end
	U.pingAt = now
	local first = not U.pingSeen
	U.pingSeen = true
	local f = C.IO.open(C.DIR .. C.BS .. "ping_journal.txt", "rb")
	if not f then return end
	local size = f:seek("end") or 0
	U.pingOff = U.pingOff or 0
	if size < U.pingOff then U.pingOff = 0 end
	if size == U.pingOff then f:close() return end
	f:seek("set", U.pingOff)
	local data = f:read(size - U.pingOff) or ""
	f:close()
	local pos, fresh = 1, {}
	while true do
		local e = data:find(C.NL, pos, true)
		if not e then break end
		local line = data:sub(pos, e - 1):gsub(C.CR, "")
		pos = e + 1
		local p = {}
		for x in (line .. C.TAB):gmatch("([^" .. C.TAB .. "]*)" .. C.TAB) do p[#p + 1] = x end
		if #p >= 6 and tonumber(p[4]) and tonumber(p[5]) then fresh[#fresh + 1] = { who = p[2], k = p[3], x = tonumber(p[4]), y = tonumber(p[5]), z = tonumber(p[6]) } end
	end
	U.pingOff = U.pingOff + pos - 1
	if #fresh == 0 or first then return end
	U.chat = U.chat or {}
	for _, x in ipairs(fresh) do
		U.lastPing = x
		U.chat[#U.chat + 1] = { id = 0, t = os.time(), kind = "ping", name = x.who, text = C.Tf("signal « %s » sur la carte", "signal « %s » on the map", U.pingName(x.k)) }
	end
	U.pingArmedAt = nil
	while #U.chat > 100 do table.remove(U.chat, 1) end
	U.chatVersion = (U.chatVersion or 0) + 1
	U.winChanged()
end

-- The Chat tab: the newest messages that fit in about 16 lines (a long message takes several), the newest at the bottom, then
-- the field to write in. No scroll area here: it would show the oldest lines first and push the field out of view.
U.CHAT_LINES = 16
U.chatBody = function(K, st, chat, ctx)
	local builtin = K.builtin
	local W = K.TEXT_W
	local TIME_W, NAME_W = 52, 130
	local MSG_W = W - TIME_W - NAME_W - 8
	local me = myChatName()
	-- (about 46 average characters on a line of the message column, 15 in the name column)
	local function height(m)
		if m.kind == "msg" then return math.max(1, math.ceil(U.textWidth(m.text) / 46), math.ceil(U.textWidth(m.name .. ":") / 15)) end
		if m.kind == "unsent" then return math.max(1, math.ceil((U.textWidth(m.text) + 40) / 60)) end
		return 1
	end
	local pick, budget = {}, U.CHAT_LINES
	for i = #chat, 1, -1 do
		local h = height(chat[i])
		if h > budget and #pick > 0 then break end
		budget = budget - h
		table.insert(pick, 1, chat[i])
	end
	local rows = {}
	if #chat == 0 then rows[#rows + 1] = K.muted(T("Aucun message pour l'instant.", "No messages yet."), W) end
	for _, m in ipairs(pick) do
		local time = U.hhmm(m.t)
		if m.kind == "join" then
			rows[#rows + 1] = K.muted(time .. "   " .. C.Tf("%s a rejoint la partie", "%s joined the game", m.name), W)
		elseif m.kind == "left" then
			rows[#rows + 1] = K.muted(time .. "   " .. C.Tf("%s a quitté la partie", "%s left the game", m.name), W)
		elseif m.kind == "away" then
			rows[#rows + 1] = K.muted(time .. "   " .. C.Tf("%s a perdu la connexion : la partie l'attend", "%s lost the connection: the game waits for them", m.name), W)
		elseif m.kind == "back" then
			rows[#rows + 1] = K.muted(time .. "   " .. C.Tf("%s est de retour : la partie continue", "%s is back: the game goes on", m.name), W)
		elseif m.kind == "unsent" then
			rows[#rows + 1] = K.row { K.muted(time, TIME_W),
				K.text(T("Non envoyé (pas de connexion à l'hôte) : ", "Not sent (no connection to the host): ") .. m.text, nil, "error", W - TIME_W) }
		else
			rows[#rows + 1] = K.row { K.muted(time, TIME_W), K.colored(m.name .. ":", K.color(m.name == me and "Ok" or "Info"), NAME_W), K.gap(8, 1),
				K.text(m.text, nil, nil, MSG_W) }
		end
	end
	local function send(v)
		if sendChat(v) then
			ctx.draft:set("")
			ctx.chatGen:set(ctx.chatGen:old() + 1)
		end
	end
	rows[#rows + 1] = K.gap(1, 10)
	rows[#rows + 1] = K.row {
		builtin.TextInputField {
			-- (the Hub: a page of a fixed height gave the field all the height left, a big dark box; there it has the height of a
			-- line and the page's width)
			meta = { class = "font-scale-body", localKey = "mpfever-chat-input-" .. tostring(ctx.chatGen:old()),
				styleSheet = K.style { size = U.hubDrawing and { math.max(440, W - 140), 34 } or { 440, -1 } } },
			value = "",
			placeholderText = T("Écrire un message…", "Write a message…"),
			maxLength = 300,
			acceptOnFocusLoss = false,
			onTyping = function(v) ctx.draft:set(v or "") end,
			onValueChange = function(v) send(v) end,
		},
		K.gap(8, 1),
		K.btn(T("Envoyer", "Send"), nil, function() send(ctx.draft:old()) end, true),
	}
	return rows
end

-- Company (one company per player): this player's company, the answers its chief gives, every company (best first) with
-- joining and merging, a gift of money, the company's colour, the auction of a bankrupt company
-- ---------------------------------------------------------------- the Companies page (0.7.4)
-- The companies as cards in a grid, in the game's colours: each one's colour band, name, money (red when negative), rank, lines,
-- vehicles, stations, players and the months in debt; this company first. A card's « Open » shows its sheet: its figures, its
-- lines with « Show », its players, its sharing rules and what this player can do with it (join, merge, give money). The requests
-- and offers to answer come first. MPFEVER_OLDMENUS=1: the list of 0.7.3.
U.coSort = "value"
U.coStatsCache = {}
-- a company's stations and depots (counted at most every 10 s: a loop over the game's entities)
U.coStats = function(ent)
	local c = U.coStatsCache[ent]
	if c and os.clock() - c.at < 10 then return c end
	c = { at = os.clock(), stations = 0, depots = 0 }
	pcall(function()
		api.engine.forEachEntityWithComponent(function(e)
			local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
			if po and po.player == ent then c.stations = c.stations + 1 end
		end, api.type.ComponentType.STATION_GROUP)
	end)
	pcall(function()
		api.engine.forEachEntityWithComponent(function(e)
			local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
			if po and po.player == ent then
				local cc = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
				if cc and #cc.depots > 0 then c.depots = c.depots + 1 end
			end
		end, api.type.ComponentType.CONSTRUCTION)
	end)
	-- (0.7.4, the company's sheet: its vehicles by kind of transport and its result since the year began, as the game's
	-- finance window counts it; MPFEVER_COSHEETMORE=0: not read)
	-- (only for a company known for a few seconds that still exists, as U.companyList reads the balances: the engine asserts
	-- when the interface reads the account of a player entity the simulation is still adding)
	local seen = U.coSeenAt and U.coSeenAt[ent]
	local settled = seen ~= nil and os.clock() - seen >= 5
	if settled then local okE, ex = pcall(api.engine.entityExists, ent); settled = okE and ex == true end
	if settled and os.getenv("MPFEVER_COSHEETMORE") ~= "0" then
		c.byCarrier = {}
		local okV, errV = pcall(function()
			-- (compared one by one, as the bridge's SIM.journalCarrier does: the enum's values are not plain table keys)
			local CR = api.type["enum"].Carrier
			local kinds = { { "road", CR.ROAD }, { "rail", CR.RAIL }, { "tram", CR.TRAM }, { "air", CR.AIR }, { "water", CR.WATER } }
			-- (every vehicle, as U.vehicleCounts reads them: its owner, then its carrier, each read kept before the next one)
			api.engine.forEachEntityWithComponent(function(v)
				local po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED)
				local owner = po and po.player
				if owner ~= ent then return end
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				local car = tv and tv.carrier
				for _, kv in ipairs(kinds) do
					if car == kv[2] then c.byCarrier[kv[1]] = (c.byCarrier[kv[1]] or 0) + 1; break end
				end
			end, api.type.ComponentType.TRANSPORT_VEHICLE)
		end)
		if not okV and not U.coKindsFailed then U.coKindsFailed = true; log("company sheet: vehicles by kind not read: " .. tostring(errV)) end
		pcall(function() c.earn = api.engine.util.finance.calculateEarnings(ent) end)
	end
	U.coStatsCache[ent] = c
	return c
end
U.TABS.company = function(K, st, ctx)
	if U.oldMenus() then return U.TABS.companyOld(K, st, ctx) end
	local builtin = K.builtin
	local W = K.TEXT_W
	if not U.coMap then return { K.muted(T("En attente des entreprises…", "Waiting for the companies…"), W) } end
	pcall(U.pollEco)
	local eco = U.eco or U.ECO_EMPTY()
	local list, myBal = U.companyList(eco)
	local myKey = eco.myKey
	local amChief = U.myCo ~= nil and eco.chief[U.myCo] ~= nil and eco.chief[U.myCo] == myKey
	local asked, offered = nil, nil
	for _, r in ipairs(eco.requests) do if r.key == myKey then asked = r.to end end
	for _, o in ipairs(eco.merges) do if o.from == U.myCo then offered = o.to end end
	local count = {}
	for _, c in ipairs(list) do count[c.name] = (count[c.name] or 0) + 1 end
	local function label(c) return c.name .. ((count[c.name] or 0) > 1 and ("  #" .. c.id) or "") end
	local function playerNames(id)
		local names, done = {}, {}
		for _, k in ipairs(eco.members[id] or {}) do
			if not done[k] then done[k] = true; names[#names + 1] = k .. (eco.chief[id] == k and T(" (chef)", " (chief)") or "") end
		end
		return names
	end
	local rows = {}
	-- the requests and offers this company's chief answers
	if amChief then
		for _, r in ipairs(eco.requests) do
			if r.to == U.myCo then
				rows[#rows + 1] = K.card {
					K.text(C.Tf("%s demande à rejoindre votre entreprise.", "%s asks to join your company.", r.name ~= "" and r.name or r.key), "font-scale-title-4", "warning", K.CARD_TEXT_W),
					K.row { K.btn(T("Accepter", "Accept"), nil, function() U.coSend("co_join_answer", { key = r.key, accept = true }) end, true, nil, K.ICON_ACCEPT), K.gap(8, 1),
						K.btn(T("Refuser", "Refuse"), nil, function() U.coSend("co_join_answer", { key = r.key, accept = false }) end, false, nil, K.ICON_REFUSE) },
				}
				rows[#rows + 1] = K.gap(1, 6)
			end
		end
		for _, o in ipairs(eco.merges) do
			if o.to == U.myCo then
				local from = "#" .. tostring(o.from)
				for _, c in ipairs(list) do if c.id == o.from then from = label(c) end end
				rows[#rows + 1] = K.card {
					K.text(C.Tf("%s propose de fusionner avec la vôtre : ses biens, son argent et ses joueurs vous rejoignent.", "%s offers to merge into yours: its assets, money and players join you.", from), "font-scale-title-4", "warning", K.CARD_TEXT_W),
					K.row { K.btn(T("Accepter", "Accept"), nil, function() U.coSend("co_merge_answer", { from = o.from, accept = true }) end, true, nil, K.ICON_ACCEPT), K.gap(8, 1),
						K.btn(T("Refuser", "Refuse"), nil, function() U.coSend("co_merge_answer", { from = o.from, accept = false }) end, false, nil, K.ICON_REFUSE) },
				}
				rows[#rows + 1] = K.gap(1, 6)
			end
		end
	end
	-- one company's sheet
	local open = nil
	for _, c in ipairs(list) do if c.id == U.coDetail then open = c end end
	if open then
		local c = open
		local isMine = c.id == U.myCo
		local s = U.coStats(c.ent)
		-- (0.8.8, the Hub: the game's back icon instead of the text's arrow)
		local backText = T("← Toutes les entreprises", "← All the companies")
		if K.hub() then backText = (backText:gsub("^" .. string.char(226, 134, 144) .. "%s*", "")) end
		rows[#rows + 1] = K.row { K.btn(backText, nil, function() U.coDetail = nil; U.winChanged() end, false, nil, K.ICON_BACK) }
		rows[#rows + 1] = K.gap(1, 8)
		rows[#rows + 1] = K.row { U.swatch(K, c.id, 26), K.gap(10, 1), K.text(label(c) .. (isMine and T("  (votre entreprise)", "  (your company)") or ""), "font-scale-title-2", isMine and "success" or nil, W - 40) }
		rows[#rows + 1] = K.gap(1, 6)
		local fig = {
			K.row { K.icon(K.ICON_MONEY, 18), K.gap(6, 1), K.text(money(c.bal), "font-scale-title-4", c.bal < 0 and "negative" or "positive", 220),
				K.gap(12, 1), K.muted(c.rank and C.Tf("Rang %s", "Rank %s", c.rank) or "", 120) },
			K.muted(C.Tf("%s ligne(s)  ·  %s véhicule(s)  ·  %s gare(s)  ·  %s dépôt(s)", "%s line(s)  ·  %s vehicle(s)  ·  %s station(s)  ·  %s depot(s)", c.lines, c.veh, s.stations, s.depots), K.CARD_TEXT_W),
		}
		-- (0.7.4) its vehicles by kind, its result of the year so far
		local kinds = {}
		local bc = s.byCarrier or {}
		if (bc.road or 0) > 0 then kinds[#kinds + 1] = C.Tf("%s par la route", "%s by road", bc.road) end
		if (bc.rail or 0) > 0 then kinds[#kinds + 1] = C.Tf("%s trains", "%s trains", bc.rail) end
		if (bc.tram or 0) > 0 then kinds[#kinds + 1] = C.Tf("%s trams", "%s trams", bc.tram) end
		if (bc.water or 0) > 0 then kinds[#kinds + 1] = C.Tf("%s navires", "%s ships", bc.water) end
		if (bc.air or 0) > 0 then kinds[#kinds + 1] = C.Tf("%s avions", "%s aircraft", bc.air) end
		if #kinds > 0 then fig[#fig + 1] = K.muted(C.Tf("Véhicules : %s", "Vehicles: %s", table.concat(kinds, "  ·  ")), K.CARD_TEXT_W) end
		if tonumber(s.earn) then
			fig[#fig + 1] = K.row { K.muted(T("Résultat de l'année en cours :", "Result of the year so far:"), 220), K.gap(6, 1),
				K.text(money(s.earn), nil, s.earn < 0 and "negative" or "positive", 200) }
		end
		if eco.debt[c.id] then
			local lim = eco.bankrupt or 12
			fig[#fig + 1] = K.text(lim > 0 and C.Tf("Endettée depuis %s mois : faillite à %s mois de dette.", "In debt for %s month(s): bankruptcy at %s months in debt.", eco.debt[c.id], lim)
				or C.Tf("Endettée depuis %s mois.", "In debt for %s month(s).", eco.debt[c.id]), nil, "error", K.CARD_TEXT_W)
		end
		local names = playerNames(c.id)
		fig[#fig + 1] = K.muted((eco.ai and eco.ai[c.id]) and T("Gérée par l'ordinateur", "Run by the computer") or (#names > 0 and C.Tf("Joueurs : %s", "Players: %s", table.concat(names, ", ")) or T("Aucun joueur : elle continue seule", "No player: it goes on by itself")), K.CARD_TEXT_W)
		rows[#rows + 1] = K.card(fig)
		-- its lines
		rows[#rows + 1] = K.gap(1, 10)
		rows[#rows + 1] = K.section(U.AU_ICON.line, C.Tf("Lignes (%s)", "Lines (%s)", c.lines))
		local okL, lines = pcall(function() return api.engine.system.lineSystem.getLinesForPlayer(c.ent) end)
		local lcard = {}
		if okL and type(lines) == "table" and #lines > 0 then
			for i, l in ipairs(lines) do
				if i > 20 then lcard[#lcard + 1] = K.muted(C.Tf("… et %s autres lignes", "… and %s more lines", #lines - 20), K.CARD_TEXT_W); break end
				local name, nv = tostring(l), 0
				pcall(function() name = api.engine.getComponent(l, api.type.ComponentType.NAME).name end)
				pcall(function() nv = #api.engine.system.transportVehicleSystem.getLineVehicles(l) end)
				local line = l
				lcard[#lcard + 1] = K.row { K.text(name, nil, nil, K.CARD_TEXT_W - 220), K.gap(6, 1), K.muted(C.Tf("%s véhicule(s)", "%s vehicle(s)", nv), 120), K.gap(6, 1),
					K.locate(T("Voir", "Show"), T("Amener la caméra sur sa première gare", "Take the camera to its first station"), function() U.focusLine(line) end) }
			end
		else
			lcard[#lcard + 1] = K.muted(T("Aucune ligne pour l'instant.", "No line yet."), K.CARD_TEXT_W)
		end
		rows[#rows + 1] = K.card(lcard)
		-- its sharing rules
		rows[#rows + 1] = K.gap(1, 10)
		rows[#rows + 1] = K.section(K.ICON_TRACKS, T("Ses règles de partage", "Its sharing rules"))
		local tr, rd, sp, dp = eco.track[c.id] or {}, eco.road[c.id] or {}, eco.stops[c.id] or {}, eco.depotco[c.id] or {}
		rows[#rows + 1] = K.card {
			K.muted(C.Tf("Voies : %s  ·  routes : %s  ·  gares et arrêts : %s  ·  dépôts : %s", "Tracks: %s  ·  roads: %s  ·  stations and stops: %s  ·  depots: %s",
				U.ruleWords(tr.rule, tr.toll), U.ruleWords(rd.rule), U.ruleWords(sp.rule, sp.fee), U.ruleWords(dp.rule, dp.toll)), K.CARD_TEXT_W) }
		-- what this player can do with it
		if not isMine and U.myCo then
			local acts = {}
			-- (0.7.4: a computer company takes nobody in and no merger: its chief, the computer, never answers)
			local isAiCo = eco.ai and eco.ai[c.id]
			if isAiCo then
				acts[#acts + 1] = K.muted(T("Une entreprise de l'ordinateur n'accueille personne et ne fusionne pas.", "A computer company takes nobody in and does not merge."), K.CARD_TEXT_W)
			elseif asked == c.id then
				acts[#acts + 1] = K.btn(T("Annuler la demande", "Cancel the request"), nil, function() U.coSend("co_cancel", { what = "join" }) end)
			else
				acts[#acts + 1] = K.btn(T("Rejoindre", "Join"), T("Demander au chef de cette entreprise de vous y accueillir (vous quittez la vôtre, qui continue sans vous)", "Ask this company's chief to take you in (you leave yours, which goes on without you)"),
					function() U.coSend("co_join_ask", { to = c.id }) end)
			end
			if amChief and not isAiCo then
				acts[#acts + 1] = K.gap(8, 1)
				if offered == c.id then
					acts[#acts + 1] = K.btn(T("Annuler la fusion", "Cancel the merger"), nil, function() U.coSend("co_cancel", { what = "merge" }) end)
				else
					acts[#acts + 1] = K.btn(T("Fusionner", "Merge"), T("Proposer à son chef que votre entreprise rejoigne la sienne : tous vos biens, votre argent et vos joueurs y passent", "Offer its chief that your company joins theirs: all your assets, your money and your players go to it"),
						function() U.coSend("co_merge_ask", { to = c.id }) end)
				end
			end
			rows[#rows + 1] = K.gap(1, 10)
			rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Actions", "Actions"))
			local acard = { K.row(acts) }
			if asked == c.id then acard[#acard + 1] = K.muted(T("Votre demande attend la réponse de son chef.", "Your request is waiting for its chief's answer."), K.CARD_TEXT_W) end
			if offered == c.id then acard[#acard + 1] = K.muted(T("Votre proposition de fusion attend la réponse de son chef.", "Your merger offer is waiting for its chief's answer."), K.CARD_TEXT_W) end
			-- a gift of money to it
			acard[#acard + 1] = K.gap(1, 8)
			acard[#acard + 1] = K.row {
				K.muted(T("Lui donner :", "Give it:"), 110),
				builtin.TextInputField {
					meta = { class = "font-scale-body", localKey = "mpfever-give2-" .. tostring(ctx.giveGen:old()) .. "-" .. c.id, styleSheet = K.style { size = { 180, -1 } } },
					value = "", placeholderText = "100000", maxLength = 15, acceptOnFocusLoss = true,
					onTyping = function(v) ctx.amount:set(v or "") end, onValueChange = function(v) ctx.amount:set(v or "") end,
				},
				K.gap(8, 1),
				K.btn(T("Donner", "Give"), T("Donner ce montant à cette entreprise ; le don est annoncé dans la discussion", "Give this amount to this company; the gift is announced in the chat"), function() U.give(c, ctx, myBal) end, true),
			}
			if U.giveMsg then acard[#acard + 1] = K.muted(U.giveMsg, K.CARD_TEXT_W) end
			rows[#rows + 1] = K.card(acard)
			-- (0.8.3) a loan between this company and that one (see U.loanCard)
			if os.getenv("MPFEVER_LOANS") ~= "0" then
				local okL, lcard = pcall(U.loanCard, K, c, eco)
				if okL and lcard then
					rows[#rows + 1] = K.gap(1, 10)
					rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Prêt", "Loan"))
					rows[#rows + 1] = K.card(lcard)
				elseif not okL then log("loans: card: " .. tostring(lcard)) end
			end
		elseif isMine then
			-- (0.8.3) the other companies' lines at this company's stations, on demand (see U.otherLinesAtMine; MPFEVER_OTHERLINES=0: none)
			if os.getenv("MPFEVER_OTHERLINES") ~= "0" and #list > 1 then
				local ocard = { K.muted(T("Les lignes des autres entreprises qui s'arrêtent à vos gares, quand vous voulez les voir.", "The other companies' lines that stop at your stations, when you want to see them."), K.CARD_TEXT_W),
					K.row { K.btn(U.otherLinesOpen and T("Masquer", "Hide") or T("Voir", "Show"), nil, function() U.otherLinesOpen = not U.otherLinesOpen; U.olCache = nil; U.winChanged() end) } }
				if U.otherLinesOpen then
					local okO, orows = pcall(U.otherLinesAtMine, list, label)
					orows = okO and orows or {}
					if #orows == 0 then ocard[#ocard + 1] = K.muted(T("Aucune ligne d'une autre entreprise ne s'arrête à vos gares.", "No line of another company stops at your stations."), K.CARD_TEXT_W) end
					for i, o in ipairs(orows) do
						if i > 30 then ocard[#ocard + 1] = K.muted(C.Tf("… et %s autres lignes", "… and %s more lines", #orows - 30), K.CARD_TEXT_W); break end
						local sg = o.sg
						ocard[#ocard + 1] = K.row { K.text(C.Tf("%s : %s (%s, %s véhicule(s))", "%s: %s (%s, %s vehicle(s))", o.sgName, o.lineName, o.co, o.nv), nil, nil, K.CARD_TEXT_W - 80), K.gap(6, 1),
							K.locate(T("Voir", "Show"), T("Amener la caméra sur la gare", "Take the camera to the station"), function() U.focusStationGroup(sg) end) }
					end
				end
				rows[#rows + 1] = K.gap(1, 10)
				rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Lignes des autres entreprises à vos gares", "Other companies' lines at your stations"))
				rows[#rows + 1] = K.card(ocard)
			end
			local nPl = #names
			if nPl > 1 then
				rows[#rows + 1] = K.gap(1, 10)
				rows[#rows + 1] = K.card { K.muted(T("Vous pouvez quitter cette entreprise : vous fondez la vôtre (argent de départ), elle continue avec ses autres joueurs.", "You can leave this company: you start your own (start money), it goes on with its other players."), K.CARD_TEXT_W),
					K.row { K.btn(T("Quitter l'entreprise", "Leave the company"), nil, function() U.coSend("co_leave", {}) end) } }
			end
			-- this company's colour: the palette, the other companies' colours greyed
			local CO = U.coLib()
			if CO and CO.PALETTE then
				local taken = {}
				for id, ix in pairs(U.coColors or {}) do if id ~= U.myCo then taken[ix] = true end end
				local mineIx = U.coColors and U.coColors[U.myCo] or nil
				rows[#rows + 1] = K.gap(1, 10)
				rows[#rows + 1] = K.section(K.ICON_COLOR, T("Votre couleur", "Your colour"))
				local sw = {}
				for ix = 1, #CO.PALETTE do
					local p = CO.PALETTE[ix]
					local col = nil
					pcall(function() col = api.type.Vec4f.new(p[1], p[2], p[3], taken[ix] and 0.25 or 1) end)
					if ix > 1 then sw[#sw + 1] = K.gap(6, 1) end
					local pick = ix
					sw[#sw + 1] = builtin.Button {
						meta = { class = ix == mineIx and "primary" or "secondary", enabled = not taken[ix] and ix ~= mineIx,
							tooltip = taken[ix] and T("Déjà prise par une autre entreprise", "Already taken by another company") or nil },
						content = builtin.Component { meta = { styleSheet = K.style { size = { 16, 16 }, image = K.DISC, bg = col } } },
						onClick = function()
							local ok, err = pcall(function() api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "recolor", { color = pick })) end)
							log("companies: colour " .. pick .. " requested" .. (ok and "" or (": " .. tostring(err))))
						end,
					}
				end
				rows[#rows + 1] = K.row(sw)
			end
		end
		return rows
	end
	-- the grid of cards: the sort, then this company first and the others
	-- (0.8.8, the Hub's new drawing: the sort as the game's group of toggle buttons, see K.choice; else its three buttons)
	local sorts = { "money", "value", "lines" }
	local sortSel = nil
	for i, s in ipairs(sorts) do if U.coSort == s then sortSel = i end end
	local sortGroup = K.choice and K.choice({ { label = T("Argent", "Money") }, { label = T("Rang", "Rank") }, { label = T("Lignes", "Lines") } }, sortSel, function(i)
		if sorts[i] then U.coSort = sorts[i]; U.winChanged() end
	end, "cosort")
	if sortGroup ~= nil then
		rows[#rows + 1] = K.row {
			K.text(C.Tf("%s entreprise(s)", "%s company(ies)", #list), "font-scale-title-4", nil, 240), K.gap(12, 1), K.muted(T("Trier par :", "Sort by:"), 90), sortGroup }
	else
		rows[#rows + 1] = K.row {
			K.text(C.Tf("%s entreprise(s)", "%s company(ies)", #list), "font-scale-title-4", nil, 240), K.gap(12, 1), K.muted(T("Trier par :", "Sort by:"), 90),
			K.btn(T("Argent", "Money"), nil, function() U.coSort = "money"; U.winChanged() end, U.coSort == "money"), K.gap(4, 1),
			K.btn(T("Rang", "Rank"), nil, function() U.coSort = "value"; U.winChanged() end, U.coSort == "value"), K.gap(4, 1),
			K.btn(T("Lignes", "Lines"), nil, function() U.coSort = "lines"; U.winChanged() end, U.coSort == "lines"),
		}
	end
	rows[#rows + 1] = K.gap(1, 8)
	local sorted = {}
	for _, c in ipairs(list) do sorted[#sorted + 1] = c end
	table.sort(sorted, function(a, b)
		if (a.id == U.myCo) ~= (b.id == U.myCo) then return a.id == U.myCo end
		if U.coSort == "lines" and a.lines ~= b.lines then return a.lines > b.lines end
		if U.coSort == "value" and (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
		if a.bal ~= b.bal then return a.bal > b.bal end
		return a.id < b.id
	end)
	local cols = W >= 900 and 3 or 2
	local cw = math.floor((W - (cols - 1) * 10) / cols)
	local rowItems = {}
	local function flush()
		if #rowItems == 0 then return end
		rows[#rows + 1] = K.row(rowItems)
		rows[#rows + 1] = K.gap(1, 10)
		rowItems = {}
	end
	for _, c in ipairs(sorted) do
		local isMine = c.id == U.myCo
		local s = U.coStats(c.ent)
		local names = playerNames(c.id)
		local CO = U.coLib()
		local band = { 0.5, 0.5, 0.5, 1 }
		if CO then pcall(function() local r, g, b = CO.rgb(U.coColors and U.coColors[c.id] or c.id); band = { r, g, b, 1 } end) end
		local tw = cw - 20
		local body = {
			K.rect(tw, 5, band),
			K.gap(1, 6),
			K.text(U.short(label(c), 34), "font-scale-title-4", isMine and "success" or nil, tw),
			K.text(money(c.bal), nil, c.bal < 0 and "negative" or "positive", tw),
			K.muted(C.Tf("%s ligne(s) · %s véhicule(s) · %s gare(s)", "%s line(s) · %s vehicle(s) · %s station(s)", c.lines, c.veh, s.stations), tw),
			K.muted((c.rank and (C.Tf("Rang %s", "Rank %s", c.rank) .. "  ·  ") or "") .. ((eco.ai and eco.ai[c.id]) and T("ordinateur", "computer") or (#names > 0 and C.Tf("%s joueur(s)", "%s player(s)", #names) or T("sans joueur", "no player"))), tw),
		}
		if eco.debt[c.id] then body[#body + 1] = K.text(C.Tf("Endettée depuis %s mois", "In debt for %s month(s)", eco.debt[c.id]), nil, "error", tw) end
		if asked == c.id then body[#body + 1] = K.text(T("Demande envoyée", "Request sent"), nil, "info", tw) end
		body[#body + 1] = K.gap(1, 6)
		local id = c.id
		body[#body + 1] = K.row { K.btn(isMine and T("Ma fiche", "My sheet") or T("Ouvrir la fiche", "Open the sheet"), T("Ses chiffres, ses lignes, ses joueurs, ses règles et les actions", "Its figures, lines, players, rules and actions"),
			function() U.coDetail = id; U.winChanged() end, isMine) }
		if #rowItems > 0 then rowItems[#rowItems + 1] = K.gap(10, 1) end
		-- (0.8.8, the Hub: the game's card, this player's own in the accent with a light contour; the same padding, see K.panel)
		if K.hub() then rowItems[#rowItems + 1] = K.box(body, K.panel(isMine and "mine" or "card", { size = { cw, -1 }, padding = { 8, 10, 8, 10 } }))
		else rowItems[#rowItems + 1] = K.box(body, { size = { cw, -1 }, padding = { 8, 10, 8, 10 }, background = isMine and { 0.25, 0.55, 0.85, 0.16 } or { 1, 1, 1, 0.06 } }) end
		if #rowItems >= cols * 2 - 1 then flush() end
	end
	flush()
	U.helpCard(K, rows, "company", {
		T("Chaque joueur dirige une entreprise ; plusieurs joueurs peuvent en partager une. Chaque carte montre une entreprise : son argent, ses lignes, ses véhicules, ses gares, son rang et ses joueurs. Votre entreprise est en bleu.",
			"Each player runs a company; several players may share one. Each card shows a company: its money, lines, vehicles, stations, rank and players. Your company is in blue."),
		T("« Ouvrir la fiche » montre tout le détail d'une entreprise et ce que vous pouvez faire avec elle : demander à la rejoindre, proposer une fusion à son chef, lui donner de l'argent. Le chef de votre entreprise répond aux demandes en haut de cette page.",
			"« Open the sheet » shows a company in detail and what you can do with it: ask to join it, offer its chief a merger, give it money. Your company's chief answers the requests at the top of this page."),
		T("Une entreprise dont l'argent reste sous zéro trop de mois (règle de la partie) fait faillite : ses joueurs repartent avec une nouvelle entreprise et ses biens sont vendus aux enchères (page « Enchères »).",
			"A company whose money stays below zero for too many months (the game's rule) goes bankrupt: its players start again with a new company and its assets are auctioned (« Auctions » page)."),
	})
	return rows
end

U.TABS.companyOld = function(K, st, ctx)
	local builtin = K.builtin
	local W, CW = K.TEXT_W, K.CARD_TEXT_W
	if not U.coMap then return { K.muted(T("En attente des entreprises…", "Waiting for the companies…"), W) } end
	pcall(U.pollEco)
	local eco = U.eco or U.ECO_EMPTY()
	local list, myBal = U.companyList(eco)
	local rows = {}
	local myKey = eco.myKey
	local amChief = U.myCo ~= nil and eco.chief[U.myCo] ~= nil and eco.chief[U.myCo] == myKey
	local asked, offered = nil, nil
	for _, r in ipairs(eco.requests) do if r.key == myKey then asked = r.to end end
	for _, o in ipairs(eco.merges) do if o.from == U.myCo then offered = o.to end end
	-- (a name several companies have, as three « Entreprise Knight-HD2 », gets the company's number)
	local count = {}
	for _, c in ipairs(list) do count[c.name] = (count[c.name] or 0) + 1 end
	local function label(c) return c.name .. ((count[c.name] or 0) > 1 and ("  #" .. c.id) or "") end
	-- (a company's players once each, its chief marked)
	local function players(id)
		local names, done = {}, {}
		for _, k in ipairs(eco.members[id] or {}) do
			if not done[k] then
				done[k] = true
				names[#names + 1] = k .. (eco.chief[id] == k and T(" (chef)", " (chief)") or "")
			end
		end
		return names
	end
	local function playersLine(id)
		local names = players(id)
		if #names == 0 then return K.muted(T("Aucun joueur : elle continue seule", "No player: it goes on by itself"), CW), 0 end
		return K.muted(C.Tf("Joueurs : %s", "Players: %s", table.concat(names, ", ")), CW), #names
	end
	local function debtLine(id)
		if not eco.debt[id] then return nil end
		local lim = eco.bankrupt or 12
		return K.text(lim > 0 and C.Tf("Endettée depuis %s mois (faillite à %s mois)", "In debt for %s month(s) (bankruptcy at %s months)", eco.debt[id], lim)
			or C.Tf("Endettée depuis %s mois", "In debt for %s month(s)", eco.debt[id]), nil, "warning", CW)
	end
	local mine = nil
	for _, c in ipairs(list) do if c.id == U.myCo then mine = c end end
	-- this player's company
	rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Votre entreprise", "Your company"))
	if not mine then
		rows[#rows + 1] = K.muted(T("Vous n'avez pas d'entreprise pour l'instant.", "You have no company at the moment."), W)
	else
		local pl, nPl = playersLine(mine.id)
		local card = {
			K.row { U.swatch(K, mine.id, 16), K.gap(8, 1), K.text(label(mine), "font-scale-title-4", nil, CW - 24) },
			K.muted(U.coFigures(mine), CW),
			pl,
		}
		card[#card + 1] = debtLine(mine.id)
		if nPl > 1 then
			card[#card + 1] = K.gap(1, 6)
			card[#card + 1] = K.muted(T("Vous fondez votre propre entreprise (argent de départ) ; celle-ci continue avec ses autres joueurs", "You start your own company (start money); this one goes on with its other players"), CW)
			card[#card + 1] = K.row { K.btn(T("Quitter l'entreprise", "Leave the company"), nil, function() U.coSend("co_leave", {}) end) }
		end
		rows[#rows + 1] = K.card(card)
	end
	-- the requests and offers this company's chief answers: the sentence, then the buttons under it
	if amChief then
		for _, r in ipairs(eco.requests) do
			if r.to == U.myCo then
				rows[#rows + 1] = K.gap(1, 6)
				rows[#rows + 1] = K.card {
					K.text(C.Tf("%s demande à rejoindre votre entreprise.  ", "%s asks to join your company.  ", r.name ~= "" and r.name or r.key), nil, "warning", CW),
					K.row {
						K.btn(T("Accepter", "Accept"), nil, function() U.coSend("co_join_answer", { key = r.key, accept = true }) end, true),
						K.gap(8, 1),
						K.btn(T("Refuser", "Refuse"), nil, function() U.coSend("co_join_answer", { key = r.key, accept = false }) end),
					},
				}
			end
		end
		for _, o in ipairs(eco.merges) do
			if o.to == U.myCo then
				local from = "#" .. tostring(o.from)
				for _, c in ipairs(list) do if c.id == o.from then from = label(c) end end
				rows[#rows + 1] = K.gap(1, 6)
				rows[#rows + 1] = K.card {
					K.text(C.Tf("%s propose de fusionner avec la vôtre (ses biens, son argent et ses joueurs vous rejoignent).  ", "%s offers to merge into yours (its assets, money and players join you).  ", from), nil, "warning", CW),
					K.row {
						K.btn(T("Accepter", "Accept"), nil, function() U.coSend("co_merge_answer", { from = o.from, accept = true }) end, true),
						K.gap(8, 1),
						K.btn(T("Refuser", "Refuse"), nil, function() U.coSend("co_merge_answer", { from = o.from, accept = false }) end),
					},
				}
			end
		end
	end
	-- every company, best first: one card each, its actions on a row of their own
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Entreprises", "Companies") .. "  (" .. #list .. ")")
	for i, c in ipairs(list) do
		local isMine = c.id == U.myCo
		local pl = playersLine(c.id)
		local card = {
			K.row { U.swatch(K, c.id, 14), K.gap(8, 1), K.text(tostring(i) .. ".  " .. label(c) .. (isMine and T(" (vous)", " (you)") or ""), nil, isMine and "success" or nil, CW - 22) },
			K.muted(U.coFigures(c), CW),
			pl,
		}
		card[#card + 1] = debtLine(c.id)
		-- (a computer company: its lines, each with a button that shows it on the map)
		if eco.ai and eco.ai[c.id] then U.aiLineRows(K, c, card, CW) end
		if not isMine and U.myCo then
			local acts = {}
			-- mixed modes: join it (its chief accepts), or merge into it (the two chiefs)
			if asked == c.id then
				acts[#acts + 1] = K.btn(T("Annuler la demande", "Cancel the request"), nil, function() U.coSend("co_cancel", { what = "join" }) end)
			else
				acts[#acts + 1] = K.btn(T("Rejoindre", "Join"), T("Demander au chef de cette entreprise de vous y accueillir (vous quittez la vôtre, qui continue sans vous)", "Ask this company's chief to take you in (you leave yours, which goes on without you)"),
					function() U.coSend("co_join_ask", { to = c.id }) end)
			end
			if amChief then
				acts[#acts + 1] = K.gap(8, 1)
				if offered == c.id then
					acts[#acts + 1] = K.btn(T("Annuler la fusion", "Cancel the merger"), nil, function() U.coSend("co_cancel", { what = "merge" }) end)
				else
					acts[#acts + 1] = K.btn(T("Fusionner", "Merge"), T("Proposer à son chef que votre entreprise rejoigne la sienne : tous vos biens, votre argent et vos joueurs y passent", "Offer its chief that your company joins theirs: all your assets, your money and your players go to it"),
						function() U.coSend("co_merge_ask", { to = c.id }) end)
				end
			end
			card[#card + 1] = K.gap(1, 4)
			card[#card + 1] = K.row(acts)
			if asked == c.id then card[#card + 1] = K.muted(T("Votre demande attend la réponse de son chef.", "Your request is waiting for its chief's answer."), CW) end
			if offered == c.id then card[#card + 1] = K.muted(T("Votre proposition de fusion attend la réponse de son chef.", "Your merger offer is waiting for its chief's answer."), CW) end
		end
		rows[#rows + 1] = K.gap(1, 4)
		rows[#rows + 1] = K.card(card)
	end
	-- a gift: the company in a list, the amount, then the button
	local targets = {}
	for _, c in ipairs(list) do if c.id ~= U.myCo then targets[#targets + 1] = c end end
	if mine and #targets > 0 then
		local target = targets[1]
		for _, c in ipairs(targets) do if c.id == ctx.giveTo:old() then target = c end end
		local items = {}
		for _, c in ipairs(targets) do
			items[#items + 1] = builtin.ComboBoxItem { value = c.id, content = K.text(U.short(label(c), 30)) }
		end
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_MONEY, T("Donner de l'argent", "Give money"))
		rows[#rows + 1] = K.muted(T("Le montant passe tout de suite à l'entreprise choisie ; le don est annoncé dans la discussion.", "The amount goes at once to the chosen company; the gift is announced in the chat."), W)
		rows[#rows + 1] = K.row { K.muted(T("À :", "To:")), K.gap(8, 1),
			builtin.ComboBox { value = target.id, items = items, onValueChange = function(v) v = tonumber(v); if v then ctx.giveTo:set(v) end end } }
		rows[#rows + 1] = K.row {
			builtin.TextInputField {
				meta = { class = "font-scale-body", localKey = "mpfever-give-" .. tostring(ctx.giveGen:old()), styleSheet = K.style { size = { 200, -1 } } },
				value = "",
				placeholderText = "100000",
				maxLength = 15,
				acceptOnFocusLoss = true,
				onTyping = function(v) ctx.amount:set(v or "") end,
				onValueChange = function(v) ctx.amount:set(v or "") end,
			},
			K.gap(8, 1),
			K.btn(T("Donner", "Give"), T("Donner ce montant à l'entreprise choisie", "Give this amount to the chosen company"), function() U.give(target, ctx, myBal) end, true),
		}
		if U.giveMsg then rows[#rows + 1] = K.muted(U.giveMsg, W) end
	end
	-- this company's colour: the palette in two rows of six, the other companies' colours greyed
	local CO = U.coLib()
	if mine and CO and CO.PALETTE then
		local taken = {}
		for id, ix in pairs(U.coColors or {}) do if id ~= U.myCo then taken[ix] = true end end
		local mineIx = U.coColors and U.coColors[U.myCo] or nil
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_COLOR, T("Votre couleur", "Your colour"))
		for first = 1, #CO.PALETTE, 6 do
			local sw = {}
			for ix = first, math.min(#CO.PALETTE, first + 5) do
				local p = CO.PALETTE[ix]
				local c = nil
				pcall(function() c = api.type.Vec4f.new(p[1], p[2], p[3], taken[ix] and 0.25 or 1) end)
				if ix > first then sw[#sw + 1] = K.gap(6, 1) end
				sw[#sw + 1] = builtin.Button {
					meta = { class = ix == mineIx and "primary" or "secondary", enabled = not taken[ix] and ix ~= mineIx,
						tooltip = taken[ix] and T("Déjà prise par une autre entreprise", "Already taken by another company") or nil },
					content = builtin.Component { meta = { styleSheet = K.style { size = { 16, 16 }, image = K.DISC, bg = c } } },
					onClick = function()
						local ok, err = pcall(function()
							api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "recolor", { color = ix }))
						end)
						log("companies: colour " .. ix .. " requested" .. (ok and "" or (": " .. tostring(err))))
					end,
				}
			end
			rows[#rows + 1] = K.row(sw)
			rows[#rows + 1] = K.gap(1, 4)
		end
	end
	-- the auction of a bankrupt company
	local au = eco.auction
	if au then
		local seller = "#" .. tostring(au.co)
		for ent, id in pairs(U.coMap) do if id == au.co then seller = companyName(ent) end end
		local bidder = nil
		for _, c in ipairs(list) do if c.id == au.bidder then bidder = label(c) end end
		local what = au.kind == "line" and C.Tf("ligne « %s »", "line « %s »", au.label) or au.kind == "station" and C.Tf("gare « %s »", "station « %s »", au.label) or C.Tf("dépôt « %s »", "depot « %s »", au.label)
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_MONEY, C.Tf("Enchères : biens de %s", "Auction: assets of %s", seller))
		local card = {
			K.text(C.Tf("Lot %s/%s : %s", "Lot %s/%s: %s", au.idx, au.n, what), nil, nil, CW),
			K.muted(C.Tf("Mise à prix %s  ·  meilleure offre %s  ·  encore %s s", "Reserve %s  ·  best bid %s  ·  %s s left",
				money(au.reserve), au.best > 0 and (money(au.best) .. " (" .. tostring(bidder or "?") .. ")") or T("aucune", "none"), au.left), CW),
		}
		if U.myCo and au.bidder ~= U.myCo then
			local r = {}
			local seen = {}
			for _, f in ipairs({ 1, 1.1, 1.25, 1.5 }) do
				local v = math.ceil(au.min * f / 1000) * 1000
				if not seen[v] then
					seen[v] = true
					if #r > 0 then r[#r + 1] = K.gap(6, 1) end
					r[#r + 1] = K.btn(money(v), T("Offrir : ", "Bid: ") .. money(v), function() U.coSend("co_bid", { seq = au.seq, lot = au.idx, amount = v }) end,
						f == 1, myBal == nil or myBal >= v)
				end
			end
			card[#card + 1] = K.gap(1, 4)
			card[#card + 1] = K.row(r)
		elseif au.bidder == U.myCo then
			card[#card + 1] = K.muted(T("Vous avez la meilleure offre.", "You have the best bid."), CW)
		end
		rows[#rows + 1] = K.card(card)
	end
	return rows
end

-- ---------------------------------------------------------------- the Auctions page (0.7.4)
-- A bankrupt company's assets for sale: every lot at once with one clock (or its whole company in one lot), each lot a card with
-- what it holds (its detail: the stops of a line and its vehicles by model, the other companies' lines at a station, the vehicles in
-- a depot), its reserve, its best bid and who holds it, the bids this company can make (never more than it has left once its
-- other best bids are counted), "Show" on the map. The auction of 0.7.3 (one lot after the other) shows here too. With
-- MPFEVER_AUCTIONTEST=1 the host can make a company bankrupt to try it out.
-- (0.8.8: the game's small icons. The files of gui/context_helper/icons used before are the 800 x 200 banners of the game's help
-- window: drawn in a 20 pixel square they were a grey smear, and a warehouse had none. MPFEVER_OLDHUB=1: those of before)
U.AU_ICON = { line = "::/gui/game_bar/icons/statistics_line_26.tga", station = "::/gui/game_bar/icons/statistics_station_26.tga",
	depot = "::/gui/game_bar/icons/statistics_depot_26.tga", company = "::/gui/main/icons/headquarter.tga",
	warehouse = "::/gui/entity_window/icons/symbol_cargo.tga" }
if U.oldHub then
	U.AU_ICON = { line = "::/gui/context_helper/icons/window_line.tga", station = "::/gui/context_helper/icons/window_station_group.tga",
		depot = "::/gui/context_helper/icons/window_depot.tga", company = "::/gui/context_helper/icons/menu_headquarter.tga" }
end
U.auOpen = {}
U.auTime = function(s)
	s = math.max(0, math.floor(s or 0))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
U.auLotTitle = function(lot)
	-- (a station or a depot the game never named, as a computer company's truck stops: its number in the sale)
	if (lot.label or "") == "" then
		-- (0.7.5: and its town, when the engine gives one; MPFEVER_LOTTOWN=0: its number only, as 0.7.4)
		if lot.kind == "station" and lot.town and os.getenv("MPFEVER_LOTTOWN") ~= "0" then
			return C.Tf("Gare sans nom à %s (lot %s)", "Unnamed station in %s (lot %s)", lot.town, lot.idx or "?")
		end
		if lot.kind == "station" then return C.Tf("Gare sans nom (lot %s)", "Unnamed station (lot %s)", lot.idx or "?") end
		if lot.kind == "depot" then return C.Tf("Dépôt sans nom (lot %s)", "Unnamed depot (lot %s)", lot.idx or "?") end
		if lot.kind == "warehouse" then return C.Tf("Entrepôt sans nom (lot %s)", "Unnamed warehouse (lot %s)", lot.idx or "?") end
	end
	if lot.kind == "line" then return C.Tf("Ligne « %s »", "Line « %s »", lot.label) end
	if lot.kind == "station" then return C.Tf("Gare « %s »", "Station « %s »", lot.label) end
	if lot.kind == "depot" then return C.Tf("Dépôt « %s »", "Depot « %s »", lot.label) end
	-- (0.8.3) a company's warehouse, a lot of its own
	if lot.kind == "warehouse" then return C.Tf("Entrepôt « %s »", "Warehouse « %s »", lot.label) end
	return C.Tf("L'entreprise entière : %s", "The whole company: %s", lot.label)
end
U.auLotSub = function(lot)
	if lot.kind == "line" then return C.Tf("avec ses %s véhicule(s)", "with its %s vehicle(s)", lot.vehicles) end
	if lot.kind == "company" then return C.Tf("%s ligne(s), %s gare(s), %s dépôt(s), %s véhicule(s), voies et routes", "%s line(s), %s station(s), %s depot(s), %s vehicle(s), tracks and roads", lot.lines, lot.stations, lot.depots, lot.vehicles) end
	if lot.kind == "station" then return T("avec ses quais et ses voies", "with its platforms and tracks") end
	if lot.kind == "warehouse" then return T("un entrepôt de marchandises", "a goods warehouse") end
	return T("avec les véhicules qu'il contient", "with the vehicles in it")
end
U.auHelp = function(K, rows, W)
	U.helpCard(K, rows, "auction", {
		T("Une entreprise endettée trop longtemps fait faillite : ses joueurs repartent avec une nouvelle entreprise et ses biens sont vendus ici aux autres entreprises. Selon la règle de l'hôte, chaque ligne (avec ses véhicules), chaque gare et chaque dépôt est vendu à part, tous en même temps, ou bien l'entreprise entière d'un coup.",
		"A company in debt for too long goes bankrupt: its players start again with a new company and its assets are sold here to the other companies. By the host's rule, each line (with its vehicles), each station and each depot is sold on its own, all at once, or else the whole company in one go."),
		T("Une offre doit dépasser la meilleure d'au moins 5 %. Tous les lots se terminent ensemble ; une offre dans les 30 dernières secondes ajoute 30 s pour tout le monde. Vous ne pouvez pas promettre plus que votre argent : vos meilleures offres en cours sont déduites. « Détail » montre exactement ce que contient un lot, « Voir » l'amène à l'écran.",
		"A bid must beat the best one by 5 % at least. All the lots end together; a bid in the last 30 seconds gives everybody 30 s more. You cannot promise more than your money: your best bids under way are taken off it. « Detail » shows exactly what a lot holds, « Show » brings it on screen."),
		T("À la fin, chaque lot va à sa meilleure offre, qui est payée. Ce que personne n'a acheté est démoli ; une gare où s'arrêtent les lignes d'autres entreprises, ainsi que les voies et les routes, reviennent à une autre entreprise (de l'ordinateur d'abord, sinon une qui a enchéri) pour ne rien casser. L'argent de la vente ne va à personne et les dettes de l'entreprise disparaissent avec elle.",
		"At the end each lot goes to its best bid, which is paid. What nobody bought is demolished; a station other companies' lines stop at, and the tracks and roads, go to another company (a computer one first, else one that bid) so that nothing breaks. The money of the sale goes to nobody and the company's debts go with it."),
	})
end
U.TABS.auction = function(K, st, ctx)
	local W, CW = K.TEXT_W, K.CARD_TEXT_W
	pcall(U.pollEco)
	local eco = U.eco or U.ECO_EMPTY()
	local list, myBal = U.companyList(eco)
	local rows = {}
	local function coLabel(id)
		for _, c in ipairs(list) do if c.id == id then return c.name end end
		for ent, cid in pairs(U.coMap or {}) do if cid == id then return companyName(ent) end end
		return "#" .. tostring(id)
	end
	local au = eco.auction2
	if not au then
		if eco.auction then
			-- (an auction of 0.7.3 under way, one lot after the other: its lot as before)
			local a1 = eco.auction
			rows[#rows + 1] = K.section(K.ICON_MONEY, C.Tf("Enchères : biens de %s", "Auction: assets of %s", coLabel(a1.co)))
			local card = { K.text(C.Tf("Lot %s/%s : %s", "Lot %s/%s: %s", a1.idx, a1.n, U.auLotTitle(a1)), "font-scale-title-4", nil, CW),
				K.muted(C.Tf("Mise à prix %s  ·  meilleure offre %s  ·  encore %s s", "Reserve %s  ·  best bid %s  ·  %s s left",
					money(a1.reserve), a1.best > 0 and (money(a1.best) .. " (" .. coLabel(a1.bidder) .. ")") or T("aucune", "none"), a1.left), CW) }
			if U.myCo and a1.bidder ~= U.myCo and a1.co ~= U.myCo then
				local r = {}
				for _, f in ipairs({ 1, 1.1, 1.25, 1.5 }) do
					local v = math.ceil(a1.min * f / 1000) * 1000
					if #r > 0 then r[#r + 1] = K.gap(6, 1) end
					r[#r + 1] = K.btn(money(v), T("Offrir : ", "Bid: ") .. money(v), function() U.coSend("co_bid", { seq = a1.seq, lot = a1.idx, amount = v }) end, f == 1, myBal == nil or myBal >= v)
				end
				card[#card + 1] = K.gap(1, 4)
				card[#card + 1] = K.row(r)
			elseif a1.bidder == U.myCo then
				card[#card + 1] = K.text(T("Vous avez la meilleure offre.", "You have the best bid."), nil, "success", CW)
			end
			rows[#rows + 1] = K.card(card)
		else
			rows[#rows + 1] = K.section(K.ICON_MONEY, T("Ventes aux enchères", "Auctions"))
			rows[#rows + 1] = K.muted(T("Aucune vente en cours. Quand une entreprise fait faillite, tous ses biens sont mis en vente sur cette page, et la discussion vous prévient.",
				"No sale under way. When a company goes bankrupt, all its assets are put up for sale on this page, and the chat tells you."), W)
		end
		-- (tests, MPFEVER_AUCTIONTEST=1 on the host's PC: a company made bankrupt at once, every game takes it from the host)
		if os.getenv("MPFEVER_AUCTIONTEST") == "1" and U.isHost(st) and not eco.auction then
			rows[#rows + 1] = K.gap(1, 10)
			rows[#rows + 1] = K.section(K.ICON_ALERT, T("Test (MPFEVER_AUCTIONTEST)", "Test (MPFEVER_AUCTIONTEST)"))
			-- (by number, not by balance: the balances change all the time, and the row under the mouse with them)
			local byId = {}
			for _, c in ipairs(list) do byId[#byId + 1] = c end
			table.sort(byId, function(a, b) return a.id < b.id end)
			for _, c in ipairs(byId) do
				if c.id ~= U.myCo then
					local id = c.id
					rows[#rows + 1] = K.row { K.text(c.name, nil, nil, CW - 260), K.gap(8, 1),
						K.btn(T("Mettre en faillite (test)", "Make bankrupt (test)"), T("Pour essayer les enchères : cette entreprise fait faillite tout de suite.", "To try the auctions: this company goes bankrupt at once."),
							function() U.coSend("co_test", { op = "bankrupt", co = id, hostTest = true }) end) }
				end
			end
		end
		rows[#rows + 1] = K.gap(1, 12)
		U.auHelp(K, rows, W)
		return rows
	end
	-- (0.8.3: the time left is in seconds of the game's time, see the bridge's G.auClock: between two updates of eco.txt it goes
	-- down at the session's speed, not at all while paused; MPFEVER_AUCTIONREAL=1: real seconds, as before)
	local auRate = 1
	if os.getenv("MPFEVER_AUCTIONREAL") ~= "1" then auRate = tonumber(U.shownSpeed and U.shownSpeed()) or 1 end
	local left = math.max(0, au.left - math.floor((os.clock() - (au.at or os.clock())) * auRate))
	-- my situation: the best bids this company holds, what is left to bid with
	local committed, leading = 0, 0
	for _, lot in ipairs(au.lots) do if U.myCo and lot.bidder == U.myCo then committed = committed + lot.best; leading = leading + 1 end end
	local free = myBal and (myBal - committed) or nil
	rows[#rows + 1] = K.section(K.ICON_MONEY, C.Tf("Vente aux enchères : biens de %s", "Auction: the assets of %s", coLabel(au.co)))
	local head = {
		K.row { K.text(left > 0 and C.Tf("Fin dans %s", "Ends in %s", U.auTime(left)) or T("Clôture…", "Closing…"), "font-scale-title-2", left <= 30 and "warning" or nil, 300),
			K.gap(12, 1), K.muted(au.mode == "company" and T("L'entreprise entière en un seul lot", "The whole company in one lot")
				or C.Tf("%s lot(s) en vente en même temps  ·  %s offre(s)", "%s lot(s) for sale at once  ·  %s bid(s)", #au.lots, au.bids), CW - 320) },
		K.muted(T("Une offre dans les 30 dernières secondes ajoute 30 s.", "A bid in the last 30 seconds adds 30 s."), CW),
	}
	if U.myCo == au.co then
		head[#head + 1] = K.text(T("Ce sont les biens de votre ancienne entreprise : vous ne pouvez pas enchérir.", "These are your former company's assets: you cannot bid."), nil, "warning", CW)
	elseif U.myCo then
		head[#head + 1] = K.text(C.Tf("Votre argent : %s  ·  vos meilleures offres : %s sur %s lot(s)  ·  disponible pour enchérir : %s", "Your money: %s  ·  your best bids: %s on %s lot(s)  ·  left to bid with: %s",
			money(myBal or 0), money(committed), leading, money(math.max(0, free or 0))), nil, (free or 0) < 0 and "error" or "info", CW)
	end
	rows[#rows + 1] = K.card(head)
	-- the lots, by kind
	local kinds = { { "company", T("Entreprise", "Company") }, { "line", T("Lignes", "Lines") }, { "station", T("Gares", "Stations") }, { "depot", T("Dépôts", "Depots") }, { "warehouse", T("Entrepôts", "Warehouses") } }
	for _, kd in ipairs(kinds) do
		local these = {}
		for _, lot in ipairs(au.lots) do if lot.kind == kd[1] then these[#these + 1] = lot end end
		if #these > 0 then
			rows[#rows + 1] = K.gap(1, 10)
			rows[#rows + 1] = K.section(U.AU_ICON[kd[1]], kd[2] .. "  (" .. #these .. ")")
			for _, lot in ipairs(these) do
				local idx = lot.idx
				local mineBest = U.myCo ~= nil and lot.bidder == U.myCo
				local det = au.detail and au.detail[idx]
				local card = {
					K.row { K.icon(U.AU_ICON[lot.kind] or K.ICON_MONEY, 20), K.gap(8, 1), K.text(U.auLotTitle(lot), "font-scale-title-4", nil, CW - 260), K.gap(8, 1),
						K.muted(U.auLotSub(lot), 220) },
					K.row { K.muted(C.Tf("Mise à prix %s", "Reserve %s", money(lot.reserve)), 220), K.gap(8, 1),
						lot.best > 0 and K.text(C.Tf("Meilleure offre : %s (%s)", "Best bid: %s (%s)", money(lot.best), mineBest and T("vous", "you") or coLabel(lot.bidder)), nil, mineBest and K.moneyCls("success") or nil, CW - 240)
							or K.muted(T("Aucune offre pour l'instant", "No bid yet"), CW - 240) },
				}
				local acts = {}
				if U.myCo and U.myCo ~= au.co and not mineBest and left > 0 then
					local seen = {}
					for _, f in ipairs({ 1, 1.1, 1.25, 1.5 }) do
						local v = math.ceil(lot.min * f / 1000) * 1000
						if not seen[v] then
							seen[v] = true
							if #acts > 0 then acts[#acts + 1] = K.gap(6, 1) end
							local ok = free == nil or v <= free
							acts[#acts + 1] = K.btn(money(v), ok and (T("Offrir : ", "Bid: ") .. money(v)) or T("Pas assez d'argent disponible", "Not enough money left"),
								function() U.coSend("co_bid", { seq = au.seq, lot = idx, amount = v }) end, f == 1, ok)
						end
					end
				end
				if #acts > 0 then acts[#acts + 1] = K.gap(12, 1) end
				acts[#acts + 1] = K.btn(U.auOpen[idx] and T("Masquer le détail", "Hide the detail") or T("Détail", "Detail"), T("Ce que contient exactement ce lot", "What exactly this lot holds"),
					function() U.auOpen[idx] = not U.auOpen[idx]; U.winChanged() end)
				if det and det.focus and det.focus >= 0 then
					acts[#acts + 1] = K.gap(6, 1)
					acts[#acts + 1] = K.locate(T("Voir", "Show"), T("Amener la caméra sur place", "Take the camera there"), function() pcall(function() api.gui.camera.focusEntity(det.focus) end) end)
				end
				card[#card + 1] = K.gap(1, 4)
				card[#card + 1] = K.row(acts)
				if mineBest then card[#card + 1] = K.text(T("Vous avez la meilleure offre.", "You have the best bid."), nil, "success", CW) end
				if U.auOpen[idx] then
					card[#card + 1] = K.gap(1, 4)
					if det then for _, x in ipairs(det.lines) do card[#card + 1] = K.muted(x, CW) end
					else card[#card + 1] = K.muted(T("Détail en cours de lecture…", "Reading the detail…"), CW) end
				end
				rows[#rows + 1] = K.gap(1, 4)
				rows[#rows + 1] = K.card(card)
			end
		end
	end
	rows[#rows + 1] = K.gap(1, 12)
	U.auHelp(K, rows, W)
	return rows
end

-- One of this company's rules (tracks, stops and stations, depots): its three choices, the amount when it takes a toll (a
-- list), and what it means. The choice just made shows at once, until every game has applied it (or 10 s).
U.TOLLS = { 500, 1000, 2000, 5000, 10000 }
U.STOP_FEES = { 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000 }
U.ruleBlock = function(K, rows, b)
	local builtin = K.builtin
	local W = K.TEXT_W
	U.rulePending = U.rulePending or {}
	local pend = U.rulePending[b.kind]
	if pend and ((pend.rule == b.rule and (b.rule ~= "toll" or pend.amount == b.amount)) or os.clock() - pend.at > 10) then
		U.rulePending[b.kind] = nil
		pend = nil
	end
	local shown = pend and pend.rule or b.rule
	local amount = pend and pend.amount or b.amount
	local function pick(rule, amt)
		U.rulePending[b.kind] = { rule = rule, amount = amt, at = os.clock() }
		b.send(rule, amt)
		U.winChanged()
	end
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.section(b.icon, b.title)
	-- (0.8.8, the Hub's new drawing: the game's group of toggle buttons, see K.choice; else the buttons, the chosen one in primary)
	local ruleList = b.rules or { "private", "open", "toll" }
	local items, sel = {}, nil
	for i, rule in ipairs(ruleList) do
		items[i] = { label = b.labels[rule], tip = b.texts[rule] }
		if rule == shown then sel = i end
	end
	local group = K.choice and K.choice(items, sel, function(i)
		local rule = ruleList[i]
		if rule and rule ~= shown then pick(rule, amount) end
	end, "rule-" .. tostring(b.kind))
	if group ~= nil then
		rows[#rows + 1] = K.row { group }
	else
		local r = {}
		for i, rule in ipairs(ruleList) do
			if i > 1 then r[#r + 1] = K.gap(6, 1) end
			r[#r + 1] = K.btn(b.labels[rule], b.texts[rule], function() if rule ~= shown then pick(rule, amount) end end, rule == shown)
		end
		rows[#rows + 1] = K.row(r)
	end
	if shown == "toll" then
		local items, listed = {}, false
		local amounts = {}
		for _, v in ipairs(b.amounts) do amounts[#amounts + 1] = v; if v == amount then listed = true end end
		if not listed and amount > 0 then amounts[#amounts + 1] = amount; table.sort(amounts) end
		for _, v in ipairs(amounts) do items[#items + 1] = builtin.ComboBoxItem { value = v, content = K.text(money(v)) } end
		rows[#rows + 1] = K.row { K.muted(b.amountLabel), K.gap(8, 1),
			builtin.ComboBox { value = amount, items = items, onValueChange = function(v) v = tonumber(v); if v and v ~= amount then pick("toll", v) end end } }
	end
	rows[#rows + 1] = K.muted(pend and T("Modification en cours pour tous les joueurs…", "Applying for every player…") or b.texts[shown] or "", W)
end

-- a company's rule in a few words (the other companies' rules)
U.ruleWords = function(rule, amount)
	if rule == "private" then return T("privé", "private") end
	if rule == "toll" then return C.Tf("péage %s", "toll %s", money(amount or 0)) end
	return T("libre", "open")
end
-- (0.7.4) a rule's colour in the other companies' table: open green, toll amber, private red
U.ruleClass = function(rule)
	if rule == "private" then return "error" end
	if rule == "toll" then return "warning" end
	return "success"
end

-- (0.7.4, the menus redone) A table for the window's own pages, as the options' pages have (u.table): its head on a darker band,
-- its rows striped, the columns at the widths given (stretched to the page). A cell is a text (a string), a coloured text
-- { text = ..., cls = "success" | "warning" | "error" | "info" }, or a node of the kit { node = n } (a dot, a button). opts.highlight(i):
-- this player's own row (a blue band); opts.width: the table's width (K.TEXT_W). MPFEVER_OLDMENUS=1 does not use it.
U.hubTable = function(K, lines, widths, opts)
	opts = type(opts) == "table" and opts or {}
	local n = 0
	for _, line in ipairs(lines or {}) do n = math.max(n, #line) end
	n = math.max(1, n)
	-- (0.8.8, the Hub: the game's table, as u.table: 12 pixels around a cell, the Finances table's colours)
	local game = K.hub ~= nil and K.hub()
	local padH, padV, gut = game and 12 or 8, game and 12 or 4, game and 12 or 8
	local TINT = game and K.tint or function(k) return U.HUB_TINT[k] end
	local inner = (tonumber(opts.width) or K.TEXT_W) - 2 * padH
	local ws, sum = {}, 0
	for j = 1, n do ws[j] = math.max(16, tonumber(widths and widths[j]) or math.floor(inner / n)); sum = sum + ws[j] end
	local k, used = inner / math.max(1, sum), 0
	for j = 1, n do
		ws[j] = math.max(16, math.floor(ws[j] * k))
		if j == n then ws[j] = math.max(16, inner - used) end
		used = used + ws[j]
	end
	local out = {}
	for i, line in ipairs(lines or {}) do
		local head = opts.header ~= false and i == 1
		local cells = {}
		for j = 1, n do
			local cell = line[j]
			local node
			if type(cell) == "table" and cell.node ~= nil then
				node = cell.node
			elseif type(cell) == "table" and cell.text ~= nil then
				node = K.colored(tostring(cell.text), K.classColor(cell.cls), ws[j] - gut)
			elseif head then
				node = K.colored(tostring(cell or ""), K.color("NeutralLight"), ws[j] - gut)
			else
				node = K.text(tostring(cell or ""), nil, nil, ws[j] - gut)
			end
			cells[#cells + 1] = K.box({ node }, { size = { ws[j], -1 } }, K.H)
		end
		local bg = head and TINT("head") or ((i % 2 == 0) and TINT("odd") or TINT("even"))
		if not head and type(opts.highlight) == "function" then
			local okH, hi = pcall(opts.highlight, opts.header ~= false and i - 1 or i)
			if okH and hi then bg = TINT("mine") end
		end
		out[#out + 1] = K.box(cells, { size = { inner + 2 * padH, -1 }, padding = { padV, padH, padV, padH }, background = bg }, K.H)
	end
	return K.col(out)
end

-- (0.7.4) « How does it work? » at the end of a page: a section that folds (its button), open until the player folds it, for this
-- session (U.helpFolded[key]); paragraphs: the texts, each one already through T (tests/test_lang.py reads the T calls)
U.helpFolded = U.helpFolded or {}
U.helpCard = function(K, rows, key, paragraphs)
	local W = K.TEXT_W
	local folded = U.helpFolded[key] == true
	rows[#rows + 1] = K.gap(1, 14)
	-- (the Hub: a title of its own, its paragraphs in its card, see U.hubCards; the small window: a box of its own)
	local inHub = U.hubDrawing == true and type(U.hubMarks) == "table"
	local head
	if inHub and K.hub ~= nil and K.hub() then
		-- (0.8.8, the Hub's new drawing: the game's information bubble (gui/main/content_card.tl's makeInfoHint: its outlined « i »
		-- and the card in the Info colour at alpha 0.25, here at the page's width: the game's own is 380 pixels wide), folded with
		-- the arrow of the game's collapsible cards (collapse_up / collapse_down), the word as its tooltip)
		head = K.row { K.icon(K.ICON_INFO, 20), K.gap(8, 1), K.text(T("Comment ça marche ?", "How does it work?"), "font-scale-headline", nil, W - 80),
			K.ibtn(folded and K.ICON_UNFOLD or K.ICON_FOLD, folded and T("Afficher", "Show") or T("Masquer", "Hide"), function() U.helpFolded[key] = not folded; U.winChanged() end, false, true, 17, 12) }
		U.hubMarks.tints = U.hubMarks.tints or {}
		U.hubMarks.tints[head] = "info"
	else
		head = K.row { K.icon(K.ICON_ALERT, 22), K.gap(8, 1), K.text(T("Comment ça marche ?", "How does it work?"), "font-scale-title-4", nil, W - 150),
			K.btn(folded and T("Afficher", "Show") or T("Masquer", "Hide"), nil, function() U.helpFolded[key] = not folded; U.winChanged() end) }
	end
	if inHub then U.hubMarks[head] = "title" end
	rows[#rows + 1] = head
	if folded then return end
	local list = {}
	for i, p in ipairs(paragraphs or {}) do
		if i > 1 then list[#list + 1] = K.gap(1, 6) end
		list[#list + 1] = K.muted(tostring(p), W - 4)
	end
	if inHub or not K.box then
		for _, x in ipairs(list) do rows[#rows + 1] = x end
	else
		rows[#rows + 1] = K.box(list, { size = { W + 20, -1 }, padding = { 8, 10, 8, 10 }, background = U.HUB_TINT.card })
	end
end

-- Rules (one company per player): this company's rules for its tracks, its stops and stations and its depots (events applied by
-- every game, see mpfever_eco.lua), the other companies' rules, the fees and tolls earned and paid, the bankruptcy rule. A rule
-- eco.txt does not give yet is open (the default of every company).
-- the computer companies (0.5.13): what each one did last (its journal, the latest first), each entry with a "Show" button
U.TABS.ai = function(K, st, ctx)
	local W, CW = K.TEXT_W, K.CARD_TEXT_W
	pcall(U.pollEco)
	pcall(U.pollAiJournal)
	local eco = U.eco or U.ECO_EMPTY()
	local rows = { K.muted(T("Ce que font les entreprises de l'ordinateur, le plus récent en premier. « Voir » amène la caméra sur place.",
		"What the computer companies do, the latest first. « Show » takes the camera there."), W) }
	for _, c in ipairs((U.companyList(eco))) do
		if eco.ai[c.id] then
			local card = {
				K.row { U.swatch(K, c.id, 16), K.gap(8, 1), K.text(c.name, "font-scale-title-4", nil, CW - 24) },
				K.muted(U.coFigures(c), CW),
			}
			local n = 0
			local list = U.aiJournal or {}
			for i = #list, 1, -1 do
				local x = list[i]
				if x.co == c.id then
					n = n + 1
					if n > 12 then break end
					local r = { K.text(U.aiText(x), nil, nil, CW - 80) }
					if x.x and x.y then r[#r + 1] = K.gap(6, 1); r[#r + 1] = K.locate(T("Voir", "Show"), nil, function() U.aiFocus(x) end) end
					card[#card + 1] = K.row(r)
				end
			end
			if n == 0 then card[#card + 1] = K.muted(T("Rien pour l'instant.", "Nothing yet."), CW) end
			rows[#rows + 1] = K.gap(1, 8)
			rows[#rows + 1] = K.card(card)
		end
	end
	if not U.oldMenus() then
		U.helpCard(K, rows, "ai", {
			T("Les entreprises de l'ordinateur jouent seules, sur le jeu de l'hôte : elles construisent des arrêts, des lignes de bus et de camions, achètent et renouvellent leurs véhicules. Leurs actions passent par tous les jeux comme celles des joueurs.",
				"The computer companies play by themselves, on the host's game: they build stops, bus and truck lines, buy and renew their vehicles. Their actions go to every game as the players' do."),
			T("Elles suivent les règles de partage comme tout le monde et ne font jamais faillite. Leur niveau et leur argent de départ se choisissent dans le salon. Cette page montre ce que fait chacune ; « Voir » amène la caméra sur place.",
				"They follow the sharing rules as everybody does and never go bankrupt. Their level and start money are chosen in the lobby. This page shows what each one does; « Show » takes the camera there."),
		})
	end
	return rows
end

U.TABS.rules = function(K, st, ctx)
	local W = K.TEXT_W
	if not U.coMap then return { K.muted(T("En attente des entreprises…", "Waiting for the companies…"), W) } end
	pcall(U.pollEco)
	local eco = U.eco or U.ECO_EMPTY()
	eco.stops, eco.depotco = eco.stops or {}, eco.depotco or {}
	local rows = {}
	local my = U.myCo
	if not my then
		rows[#rows + 1] = K.muted(T("Les règles de votre entreprise apparaissent dès que vous en avez une.", "Your company's rules show once you have a company."), W)
	else
		local tr = eco.track[my] or { rule = "open", toll = 0 }
		U.ruleBlock(K, rows, {
			kind = "track", icon = K.ICON_TRACKS, title = T("Vos voies ferrées", "Your tracks"),
			rule = tr.rule, amount = (tr.toll or 0) > 0 and tr.toll or 1000, amounts = U.TOLLS, amountLabel = T("Péage par passage : ", "Toll per passage: "),
			labels = { private = T("Privées", "Private"), open = T("Ouvertes", "Open"), toll = T("Péage", "Toll") },
			texts = {
				private = T("Les autres entreprises ne peuvent pas s'y raccorder", "The other companies cannot connect to them"),
				open = T("Les autres entreprises peuvent s'y raccorder et y faire rouler leurs trains, gratuitement", "The other companies may connect to them and run their trains on them, for free"),
				toll = T("Ouvertes, chaque train d'une autre entreprise paie le péage à chaque passage", "Open, every train of another company pays the toll each time it enters them"),
			},
			send = function(rule, amt) U.coSend("co_track_rule", { rule = rule, toll = amt }) end,
		})
		-- (0.6.2) its roads: open or private, no toll (see mpfever_eco.lua's roadRule)
		local rd = (eco.road or {})[my] or { rule = "open" }
		U.ruleBlock(K, rows, {
			kind = "roads", icon = K.ICON_TRACKS, title = T("Vos routes", "Your roads"), rules = { "private", "open" },
			rule = rd.rule, amount = 0, amounts = {}, amountLabel = "",
			labels = { private = T("Privées", "Private"), open = T("Ouvertes", "Open") },
			texts = {
				private = T("Les autres entreprises ne peuvent pas raccorder leurs routes aux vôtres ni les modifier.", "The other companies cannot connect their roads to yours or change them."),
				open = T("Les autres entreprises peuvent raccorder leurs routes aux vôtres, gratuitement. Tous les véhicules y roulent toujours.", "The other companies may connect their roads to yours, for free. Every vehicle always drives on them."),
			},
			send = function(rule) U.coSend("co_road_rule", { rule = rule }) end,
		})
		local sp = eco.stops[my] or { rule = "open", fee = 0, own = 0 }
		local spFee = (sp.fee or 0) > 0 and sp.fee or C.SHARE_DEFAULT
		U.ruleBlock(K, rows, {
			kind = "stops", icon = K.ICON_STATIONS, title = T("Vos arrêts et gares", "Your stops and stations"),
			rule = sp.rule, amount = spFee, amounts = U.STOP_FEES, amountLabel = T("Par arrêt :", "Per stop:"),
			labels = { private = T("Privés", "Private"), open = T("Ouverts", "Open"), toll = T("Péage", "Toll") },
			texts = {
				private = T("Les autres entreprises ne peuvent pas s'arrêter à vos arrêts et gares.", "The other companies cannot stop at your stops and stations."),
				open = T("Les autres entreprises peuvent s'arrêter à vos arrêts et gares, gratuitement.", "The other companies may stop at your stops and stations, for free."),
				toll = T("Les véhicules des autres entreprises paient ce montant à chaque arrêt chez vous ; vos lignes s'y arrêtent gratuitement.", "The other companies' vehicles pay this at every stop at yours; your own lines stop for free."),
			},
			send = function(rule, amt) U.coSend("co_stop_rule", { rule = rule, fee = amt, reset = false }) end,
		})
		-- (a station's own setting, made in its window, comes before the company's)
		local own = tonumber(sp.own) or 0
		rows[#rows + 1] = K.muted(own > 0 and C.Tf("%s de vos gares ont leur propre réglage (dans leur fenêtre) : il passe avant celui-ci.", "%s of your stations have their own setting (in their window): it comes before this one.", own)
			or T("Une gare peut avoir son propre réglage, dans sa fenêtre : il passe avant celui-ci.", "A station may have its own setting, in its window: it comes before this one."), W)
		rows[#rows + 1] = K.row { K.btn(T("Appliquer à toutes mes gares", "Apply to all my stations"),
			T("Retire le réglage propre de chacune de vos gares : toutes suivent celui-ci.", "Removes each of your stations' own setting: they all follow this one."), function()
				-- (the choice just made in the rows above, before eco.txt shows it: else the old rule went with the reset)
				local pend = U.rulePending and U.rulePending.stops
				if pend and os.clock() - (pend.at or 0) > 10 then pend = nil end
				U.coSend("co_stop_rule", { rule = (pend and pend.rule) or sp.rule or "open", fee = (pend and pend.amount) or spFee, reset = true })
				U.winChanged()
			end, false, own > 0 or eco.stops[my] == nil) }
		local dp = eco.depotco[my] or { rule = "open", toll = 0 }
		U.ruleBlock(K, rows, {
			kind = "depots", icon = K.ICON_DEPOTS, title = T("Vos dépôts", "Your depots"),
			rule = dp.rule, amount = (dp.toll or 0) > 0 and dp.toll or 1000, amounts = U.TOLLS, amountLabel = T("Par véhicule :", "Per vehicle:"),
			labels = { private = T("Privés", "Private"), open = T("Ouverts", "Open"), toll = T("Péage", "Toll") },
			texts = {
				private = T("Seuls vos véhicules peuvent utiliser vos dépôts.", "Only your vehicles may use your depots."),
				open = T("Les autres entreprises peuvent acheter et envoyer leurs véhicules dans vos dépôts, gratuitement.", "The other companies may buy and send their vehicles to your depots, for free."),
				toll = T("Les autres entreprises paient ce péage par véhicule acheté ou envoyé dans vos dépôts.", "The other companies pay this toll per vehicle bought or sent to your depots."),
			},
			send = function(rule, amt) U.coSend("co_depot_default", { rule = rule, toll = amt }) end,
		})
		rows[#rows + 1] = K.muted(T("Un dépôt peut avoir sa propre règle, dans sa fenêtre : elle passe avant celle-ci.", "A depot may have its own rule, in its window: it comes before this one."), W)
	end
	-- the other companies' rules (read only)
	local others = {}
	for ent, id in pairs(U.coMap) do if id ~= my and not eco.gone[id] then others[#others + 1] = { ent = ent, id = id } end end
	table.sort(others, function(a, b) return a.id < b.id end)
	-- (0.7.4: a table, a company a row, its rules in colour; MPFEVER_OLDMENUS=1: a card a company, as before)
	if #others > 0 and not U.oldMenus() then
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Règles des autres entreprises", "The other companies' rules"))
		local lines = { { T("Entreprise", "Company"), T("Voies", "Tracks"), T("Routes", "Roads"), T("Arrêts et gares", "Stops and stations"), T("Dépôts", "Depots") } }
		for _, o in ipairs(others) do
			local tr = eco.track[o.id] or { rule = "open", toll = 0 }
			local rd = (eco.road or {})[o.id] or { rule = "open" }
			local sp = eco.stops[o.id] or { rule = "open", fee = 0 }
			local dp = eco.depotco[o.id] or { rule = "open", toll = 0 }
			local nameW = math.floor((W - 16) * 0.32)
			lines[#lines + 1] = {
				{ node = K.row { K.box({ K.gap(1, 3), U.swatch(K, o.id, 12) }), K.gap(6, 1), K.text(companyName(o.ent), nil, nil, nameW - 26) } },
				{ text = U.ruleWords(tr.rule, tr.toll), cls = U.ruleClass(tr.rule) },
				{ text = U.ruleWords(rd.rule), cls = U.ruleClass(rd.rule) },
				{ text = U.ruleWords(sp.rule, sp.fee), cls = U.ruleClass(sp.rule) },
				{ text = U.ruleWords(dp.rule, dp.toll), cls = U.ruleClass(dp.rule) },
			}
		end
		rows[#rows + 1] = K.gap(1, 4)
		rows[#rows + 1] = U.hubTable(K, lines, { 32, 17, 17, 17, 17 })
		rows[#rows + 1] = K.muted(T("Libre : vos lignes et vos trains y passent gratuitement. Péage : le montant est payé à chaque passage ou arrêt. Privé : interdit à votre entreprise.",
			"Open: your lines and trains use them for free. Toll: the amount is paid at every passage or stop. Private: closed to your company."), W)
	elseif #others > 0 then
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_PLAYERS, T("Règles des autres entreprises", "The other companies' rules"))
		for _, o in ipairs(others) do
			local tr = eco.track[o.id] or { rule = "open", toll = 0 }
			local rd = (eco.road or {})[o.id] or { rule = "open" }
			local sp = eco.stops[o.id] or { rule = "open", fee = 0 }
			local dp = eco.depotco[o.id] or { rule = "open", toll = 0 }
			rows[#rows + 1] = K.gap(1, 4)
			rows[#rows + 1] = K.card {
				K.row { U.swatch(K, o.id, 14), K.gap(8, 1), K.text(companyName(o.ent), nil, nil, K.CARD_TEXT_W - 22) },
				K.muted(C.Tf("Voies : %s  ·  routes : %s  ·  arrêts : %s  ·  dépôts : %s", "Tracks: %s  ·  roads: %s  ·  stops: %s  ·  depots: %s",
					U.ruleWords(tr.rule, tr.toll), U.ruleWords(rd.rule), U.ruleWords(sp.rule, sp.fee), U.ruleWords(dp.rule, dp.toll)), K.CARD_TEXT_W),
			}
		end
	end
	-- what this company earned and paid
	local fe = my and eco.fees[my]
	-- (0.7.4: a table of what this company received from and paid to each other company, by kind; MPFEVER_OLDMENUS=1: as before)
	if fe and not U.oldMenus() then
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_MONEY, T("Gains et frais", "Earnings and fees"))
		rows[#rows + 1] = U.hubTable(K, {
			{ "", T("Reçu", "Received"), T("Payé", "Paid") },
			{ T("Gares et arrêts partagés", "Shared stations and stops"), { text = money(fe.si), cls = (fe.si or 0) > 0 and K.moneyCls("success") or nil }, { text = money(fe.se), cls = (fe.se or 0) > 0 and K.moneyCls("error") or nil } },
			{ T("Péages (voies et dépôts)", "Tolls (tracks and depots)"), { text = money(fe.ti), cls = (fe.ti or 0) > 0 and K.moneyCls("success") or nil }, { text = money(fe.te), cls = (fe.te or 0) > 0 and K.moneyCls("error") or nil } },
		}, { 46, 27, 27 })
		-- (by company: what this one paid to it and what it paid to this one, every kind together)
		local paidTo, gotFrom = U.paidBy(eco, my), {}
		for _, p in ipairs(eco.paid or {}) do
			if p.to == my and p.from and p.from ~= my then gotFrom[p.from] = (gotFrom[p.from] or 0) + (p.amount or 0) end
		end
		local ids, seen = {}, {}
		for id in pairs(paidTo) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
		for id in pairs(gotFrom) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
		table.sort(ids)
		if #ids > 0 then
			local lines = { { T("Entreprise", "Company"), T("Reçu d'elle", "Received from it"), T("Payé à elle", "Paid to it"), T("Dont gares / voies / dépôts", "Of which stations / tracks / depots") } }
			for _, id in ipairs(ids) do
				local t = paidTo[id] or { s = 0, t = 0, d = 0 }
				local out = (t.s or 0) + (t.t or 0) + (t.d or 0)
				lines[#lines + 1] = { U.aiCoName(id), { text = money(gotFrom[id] or 0), cls = (gotFrom[id] or 0) > 0 and K.moneyCls("success") or nil },
					{ text = money(out), cls = out > 0 and K.moneyCls("error") or nil }, money(t.s or 0) .. " / " .. money(t.t or 0) .. " / " .. money(t.d or 0) }
			end
			rows[#rows + 1] = K.gap(1, 6)
			rows[#rows + 1] = U.hubTable(K, lines, { 28, 20, 20, 32 })
		end
	elseif fe then
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.section(K.ICON_MONEY, T("Gains et frais", "Earnings and fees"))
		rows[#rows + 1] = K.muted(C.Tf("Gares partagées : reçu %s, payé %s", "Shared stations: earned %s, paid %s", money(fe.si), money(fe.se)), W)
		rows[#rows + 1] = K.muted(C.Tf("Péages : reçu %s, payé %s", "Tolls: earned %s, paid %s", money(fe.ti), money(fe.te)), W)
		-- (0.6.8, #115) to whom
		local by = U.paidBy(eco, my)
		local tos = {}
		for to in pairs(by) do tos[#tos + 1] = to end
		table.sort(tos)
		for _, to in ipairs(tos) do
			local t = by[to]
			rows[#rows + 1] = K.muted(C.Tf("Payé à %s : gares %s, voies %s, dépôts %s", "Paid to %s: stations %s, tracks %s, depots %s",
				U.aiCoName(to), money(t.s), money(t.t), money(t.d)), W)
		end
	end
	local lim = eco.bankrupt or 12
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.section(K.ICON_ALERT, T("Faillite", "Bankruptcy"))
	rows[#rows + 1] = K.muted(lim > 0 and C.Tf("Règle de la partie : faillite après %s mois de dette.", "Game rule: bankruptcy after %s months in debt.", lim)
		or T("Règle de la partie : pas de faillite.", "Game rule: no bankruptcy."), W)
	if not U.oldMenus() then
		U.helpCard(K, rows, "rules", {
			T("Chaque entreprise décide qui peut utiliser ce qu'elle a construit. Ouvert : les autres entreprises s'en servent gratuitement. Péage : elles paient à chaque passage d'un train sur vos voies, à chaque arrêt d'un véhicule chez vous ou pour chaque véhicule acheté ou envoyé dans vos dépôts. Privé : elles ne peuvent pas s'en servir du tout.",
				"Each company decides who may use what it built. Open: the other companies use it for free. Toll: they pay for every passage of a train on your tracks, every stop of a vehicle at yours, or every vehicle bought or sent to your depots. Private: they cannot use it at all."),
			T("Une gare ou un dépôt peut avoir sa propre règle, dans sa fenêtre du jeu : elle passe avant celle de l'entreprise. Les routes ne se ferment qu'aux raccordements : tous les véhicules continuent d'y rouler.",
				"A station or a depot may have its own rule, in its window in the game: it comes before the company's. Roads close to connections only: every vehicle keeps driving on them."),
			T("Le tableau des autres entreprises montre ce que vous coûterait chacune de leurs voies, routes, gares et dépôts. « Gains et frais » compte ce que vous avez reçu et payé depuis le début de la partie, par entreprise.",
				"The other companies' table shows what each of their tracks, roads, stations and depots would cost you. « Earnings and fees » counts what you received and paid since the game began, by company."),
		})
	end
	return rows
end

-- the session's settings and this player's own, read only: the game takes them when it loads (they change in MPFever.exe's
-- settings window). settings_info.txt (MPFever.exe) names them in the player's language; without it, the variables themselves.
U.settingsRows = function(K, rows)
	local W = K.TEXT_W
	local txt = ""
	local f = C.IO.open(C.DIR .. C.BS .. "settings_info.txt", "rb")
	if f then txt = f:read("*a") or ""; f:close() end
	local groups = { session = {}, own = {}, expert = {} }
	local any = false
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local key, name, kind, on = line:match("^([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "(%d)")
		if key and groups[kind] then
			any = true
			table.insert(groups[kind], { name = name ~= "" and name or key, on = on == "1" })
		end
	end
	local function onOff(on) return on and T("activé", "on") or T("désactivé", "off") end
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.section(K.ICON_SETTINGS, T("Réglages de la session", "Session settings"))
	if any then
		rows[#rows + 1] = K.muted(T("Choisis par l'hôte, les mêmes pour tous les joueurs.", "Chosen by the host, the same for every player."), W)
		for _, s in ipairs(groups.session) do rows[#rows + 1] = K.text(s.name .. "  ·  " .. onOff(s.on), nil, s.on and nil or "warning", W) end
		local off = {}
		for _, s in ipairs(groups.expert) do if not s.on then off[#off + 1] = s.name end end
		if #off > 0 then rows[#rows + 1] = K.text(C.Tf("Correctifs récents désactivés : %s", "Recent fixes turned off: %s", table.concat(off, " ; ")), nil, "warning", W) end
		rows[#rows + 1] = K.gap(1, 8)
		rows[#rows + 1] = K.text(T("Vos réglages", "Your settings"), "font-scale-title-4", nil, W)
		for _, s in ipairs(groups.own) do rows[#rows + 1] = K.text(s.name .. "  ·  " .. onOff(s.on), nil, nil, W) end
	else
		local keys = {}
		for k in pairs(C.SETTINGS or {}) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do rows[#rows + 1] = K.muted(k .. " = " .. tostring(C.SETTINGS[k]), W) end
		if #keys == 0 then rows[#rows + 1] = K.muted(T("Aucun réglage reçu de MPFever.exe.", "No settings received from MPFever.exe."), W) end
	end
	rows[#rows + 1] = K.muted(T("Ils se changent dans la fenêtre Réglages de MPFever.exe et comptent au prochain chargement de la partie.", "They are changed in MPFever.exe's settings window and count from the next load of the game."), W)
end

-- Game (0.5.14, one company per player): the game's rules, the host's choice in its lobby or here, kept in the savegame (see
-- mpfever_eco.lua's co_rules): the start money of a new company (a player who arrives, a company started again after a
-- bankruptcy), the sharing rules between companies on or off, the months in debt before a bankruptcy. Every player sees them;
-- the host changes them (MPFever.exe's "startmoney", "share" and "bankrupt" requests; the value asked shows until the game has
-- it, or 15 s). The computer companies' own start money is chosen in the lobby.
U.START_MONEY = { 0, 500000, 1000000, 2000000, 5000000, 10000000, 20000000, 50000000 }
U.TABS.game = function(K, st, ctx)
	local builtin = K.builtin
	local W = K.TEXT_W
	local rows = {}
	-- (0.6) everybody plays one company: the tab is there for the game options only (see U.tabsFor)
	if not (st and st.mode == "separate") then
		U.featGameRows(K, st, rows)
		return rows
	end
	pcall(U.pollEco)
	local eco = U.eco or {}
	local host = U.isHost(st)
	local function asked(field, cur)
		local a = U[field]
		if a and (cur == a.v or os.clock() - a.at > 15) then U[field] = nil; a = nil end
		return a and a.v
	end
	rows[#rows + 1] = K.section(K.ICON_SETTINGS, T("Règles de la partie", "Game rules"))
	rows[#rows + 1] = K.muted(host and T("Vous les choisissez pour tous les joueurs ; elles sont gardées dans la sauvegarde.", "You choose them for every player; they are kept in the savegame.")
		or T("Choisies par l'hôte, gardées dans la sauvegarde.", "Chosen by the host, kept in the savegame."), W)
	-- the start money of a new company
	local start = math.floor(tonumber(eco.start) or 2000000)
	local startCur = asked("startAsked", start) or start
	rows[#rows + 1] = K.gap(1, 10)
	rows[#rows + 1] = K.text(T("Argent de départ d'une nouvelle entreprise", "Start money of a new company"), nil, nil, W)
	rows[#rows + 1] = K.muted(T("Un joueur qui arrive, une entreprise repartie après une faillite. Une entreprise déjà là garde son argent.", "A player who arrives, a company started again after a bankruptcy. A company already there keeps its money."), W)
	if host then
		local items, listed = {}, false
		for _, n in ipairs(U.START_MONEY) do
			if n == startCur then listed = true end
			items[#items + 1] = builtin.ComboBoxItem { value = n, content = K.text(money(n)) }
		end
		if not listed then items[#items + 1] = builtin.ComboBoxItem { value = startCur, content = K.text(money(startCur)) } end
		rows[#rows + 1] = K.row { builtin.ComboBox { value = startCur, items = items, onValueChange = function(v)
			v = tonumber(v)
			if v ~= nil and v ~= startCur and U.menuRequest("startmoney", v) then U.startAsked = { v = v, at = os.clock() }; U.winChanged() end
		end } }
	else
		rows[#rows + 1] = K.text(money(startCur), nil, nil, W)
	end
	-- the sharing rules between companies
	local share = eco.share ~= false
	local a = asked("shareAsked", share)
	local shareCur = share
	if a ~= nil then shareCur = a end
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.text(T("Règles de partage entre entreprises", "Sharing rules between companies"), nil, nil, W)
	rows[#rows + 1] = K.muted(T("Activées : chaque entreprise décide si ses voies, gares, arrêts et dépôts sont privés, ouverts ou payants. Désactivées : tout est ouvert et gratuit pour toutes les entreprises.",
		"On: each company decides whether its tracks, stations, stops and depots are private, open or paying. Off: everything is open and free for every company."), W)
	if host then
		rows[#rows + 1] = K.row { builtin.CheckBox {
			value = shareCur and 1 or 0,
			label = T("Règles de partage activées", "Sharing rules on"),
			onValueChange = function(v)
				local on = v == 1
				if on ~= shareCur and U.menuRequest("share", on and 1 or 0) then U.shareAsked = { v = on, at = os.clock() }; U.winChanged() end
			end,
		} }
	else
		rows[#rows + 1] = K.text(shareCur and T("Activées", "On") or T("Désactivées : tout est ouvert et gratuit", "Off: everything is open and free"), nil, nil, W)
	end
	-- the months in debt before a bankruptcy (MPFever.exe's "bankrupt" request)
	local lim = tonumber(eco.bankrupt) or 12
	local limCur = asked("bankruptAsked", lim) or lim
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.text(T("Faillite", "Bankruptcy"), nil, nil, W)
	rows[#rows + 1] = K.muted(T("Mois de dette avant qu'une entreprise fasse faillite.", "Months in debt before a company goes bankrupt."), W)
	if host then
		local items = {}
		for _, n in ipairs(U.BANKRUPT_MONTHS) do
			items[#items + 1] = builtin.ComboBoxItem { value = n, content = K.text(n == 0 and T("Jamais", "Never") or C.Tf("%s mois", "%s months", n)) }
		end
		rows[#rows + 1] = K.row { builtin.ComboBox { value = limCur, items = items, onValueChange = function(v)
			v = tonumber(v)
			if v ~= nil and v ~= limCur and U.menuRequest("bankrupt", v) then U.bankruptAsked = { v = v, at = os.clock() }; U.winChanged() end
		end } }
	else
		rows[#rows + 1] = K.text(limCur == 0 and T("Jamais", "Never") or C.Tf("Après %s mois de dette", "After %s months in debt", limCur), nil, nil, W)
	end
	-- (0.7.4) the auction of a bankrupt company: its lots all at once or the whole company, and how long (MPFever.exe's "auction"
	-- request, "mode:minutes")
	local auRule = tostring(eco.auctionRule or "assets:5")
	local auCur = asked("auctionAsked", auRule) or auRule
	local auMode, auMin = auCur:match("^(%a+):(%d+)$")
	auMode, auMin = auMode or "assets", tonumber(auMin) or 5
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.text(T("Vente aux enchères d'une faillite", "Auction of a bankruptcy"), nil, nil, W)
	rows[#rows + 1] = K.muted(T("Les actifs : chaque ligne (avec ses véhicules), chaque gare et chaque dépôt en vente en même temps, chacun son prix. L'entreprise entière : un seul lot, tout ce qu'elle possédait, voies et routes comprises.",
		"The assets: each line (with its vehicles), each station and each depot for sale at once, each with its own price. The whole company: one lot, everything it owned, tracks and roads included."), W)
	local function auShow(m) return m == "company" and T("L'entreprise entière", "The whole company") or m == "serial" and T("Un lot après l'autre (0.7.3)", "One lot after the other (0.7.3)") or T("Les actifs, tous en même temps", "The assets, all at once") end
	if host then
		local items = {}
		for _, m in ipairs({ "assets", "company" }) do items[#items + 1] = builtin.ComboBoxItem { value = m, content = K.text(auShow(m)) } end
		if auMode == "serial" then items[#items + 1] = builtin.ComboBoxItem { value = "serial", content = K.text(auShow("serial")) } end
		local mins = {}
		for _, n in ipairs({ 3, 5, 10 }) do mins[#mins + 1] = builtin.ComboBoxItem { value = n, content = K.text(C.Tf("%s min", "%s min", n)) } end
		rows[#rows + 1] = K.row {
			builtin.ComboBox { value = auMode, items = items, onValueChange = function(v)
				local want = tostring(v) .. ":" .. auMin
				if v ~= nil and want ~= auCur and U.menuRequest("auction", want) then U.auctionAsked = { v = want, at = os.clock() }; U.winChanged() end
			end },
			K.gap(12, 1),
			builtin.ComboBox { value = auMin, items = mins, onValueChange = function(v)
				local want = auMode .. ":" .. tostring(v)
				if v ~= nil and want ~= auCur and U.menuRequest("auction", want) then U.auctionAsked = { v = want, at = os.clock() }; U.winChanged() end
			end },
		}
	else
		rows[#rows + 1] = K.text(auShow(auMode) .. "  ·  " .. C.Tf("%s min", "%s min", auMin), nil, nil, W)
	end
	if next(eco.ai or {}) ~= nil then
		rows[#rows + 1] = K.gap(1, 12)
		rows[#rows + 1] = K.muted(T("L'argent de départ de chaque entreprise de l'ordinateur se choisit dans le salon.", "Each computer company's start money is chosen in the lobby."), W)
	end
	-- (0.6) the game options, under the rules of 0.5.14
	local okF, errF = pcall(U.featGameRows, K, st, rows)
	if not okF then log("window: game options not drawn: " .. tostring(errF)) end
	if not U.oldMenus() then
		U.helpCard(K, rows, "game", {
			T("Les règles de la partie sont choisies par l'hôte dans son salon et gardées dans la sauvegarde ; l'hôte peut aussi les changer ici, pendant la partie. Chaque joueur les voit.",
				"The game's rules are chosen by the host in the lobby and kept in the savegame; the host may also change them here, during the game. Every player sees them."),
			T("L'argent de départ va à chaque nouvelle entreprise (un joueur qui arrive, une entreprise qui repart après une faillite). Sans règles de partage, tout est ouvert et gratuit entre les entreprises. Une entreprise fait faillite après le nombre de mois de dette choisi, et ses biens sont vendus selon la règle des enchères.",
				"The start money goes to every new company (a player who arrives, a company starting again after a bankruptcy). Without sharing rules everything is open and free between the companies. A company goes bankrupt after the chosen number of months in debt, and its assets are sold by the auction's rule."),
			T("L'hôte choisit les options de partie (bourse, commerce, classement, appels d'offres…) dans le salon ou sur cette page ; les pages des options activées apparaissent dans ce menu.",
				"The host chooses the game options (stock market, trade, ranking, tenders…) in the lobby or on this page; the pages of the options turned on show in this menu."),
		})
	end
	return rows
end

-- ---------------------------------------------------------------- the game options (0.6)
-- The modules of the game options (mpfever_feat.lua, docs/FEATURES-0.6.md) as the window shows them: the options the session has
-- on (the host's choice, sent by MPFever.exe in mp_status.txt: "opts"), listed in the Game tab for every player, switched there by
-- the host (MPFever.exe's "opt" request, as in the lobby: the host's game then puts them into the game), and the tab of a module
-- (M.TAB, M.ui) while one of its options is on. MPFEVER_FEAT=0: nothing of it, the window of 0.5.14.
U.featOff = os.getenv("MPFEVER_FEAT") == "0"
-- (0.6) MPFEVER_HUB=0: no Hub, the small window with every tab and the pages drawn as before (see U.hubOn)
U.hubOff = os.getenv("MPFEVER_HUB") == "0"
-- (0.6, the Hub) the backgrounds of its boxes: a card, a table's head and its rows (one in two a little lighter), this player's own
-- row, the tinted cards (a warning, an error, a success, an information), a bar's empty part, the menu
-- (0.8.8: the Hub's drawing of before, kept for MPFEVER_OLDHUB=1 and for what is drawn when the game no longer has one of its
-- widgets; the Hub's new drawing takes the game's theme from the kit: K.panel, K.tint)
U.HUB_TINT = {
	card = { 1, 1, 1, 0.06 }, head = { 1, 1, 1, 0.11 }, odd = { 1, 1, 1, 0.05 }, even = { 1, 1, 1, 0.015 }, mine = { 0.25, 0.55, 0.9, 0.24 },
	warning = { 0.6, 0.45, 0.1, 0.25 }, error = { 0.6, 0.1, 0.1, 0.35 }, success = { 0.15, 0.5, 0.2, 0.25 }, info = { 0.1, 0.3, 0.5, 0.3 },
	track = { 1, 1, 1, 0.1 }, side = { 0, 0, 0, 0.22 },
}
-- a text's length in characters (UTF-8: the bytes 128-191 continue a character)
U.featLen = function(s)
	local n = 0
	for _ in tostring(s or ""):gmatch("[^" .. string.char(128) .. "-" .. string.char(191) .. "]") do n = n + 1 end
	return n
end
-- (0.8.8) a bar's or a swatch's status colours: the game's own (default_colors.gres: Ok #4CBB17, Warning #DAA520, Error #CE2029,
-- Info #2D68C4); MPFEVER_OLDHUB=1: the Hub's own of before
U.HUB_COLORS_OLD = { success = { 0.42, 0.82, 0.45 }, warning = { 1, 0.76, 0.25 }, error = { 1, 0.38, 0.33 }, info = { 0.45, 0.72, 1 } }
U.HUB_COLORS_GAME = { success = { 0.298, 0.733, 0.09 }, warning = { 0.855, 0.647, 0.125 }, error = { 0.808, 0.125, 0.161 }, info = { 0.176, 0.408, 0.769 } }
U.HUB_COLORS = U.oldHub and U.HUB_COLORS_OLD or U.HUB_COLORS_GAME
-- a colour as a box's background { r, g, b, a }: { r, g, b[, a] } in 0..1, a class name ("success", "warning", "error", "info"),
-- or a company's number (its colour in the companies' palette); grey otherwise
U.hubRgba = function(c)
	if type(c) == "number" then
		local ok, r, g, b = pcall(function()
			local CO = U.coLib and U.coLib()
			local ix = U.coColors and U.coColors[c] or c
			return CO.rgb(ix)
		end)
		if ok and tonumber(r) then return { r, g, b, 1 } end
		return { 0.7, 0.7, 0.7, 1 }
	end
	if type(c) == "string" and U.HUB_COLORS[c] then c = U.HUB_COLORS[c] end
	if type(c) == "table" and tonumber(c[1]) then return { c[1], c[2] or c[1], c[3] or c[1], c[4] or 1 } end
	return { 0.7, 0.7, 0.7, 1 }
end
-- (0.6, the Hub) a page's rows put into cards: a title (a node marked "title": u.title, or K.section while the Hub draws a page of
-- the small window's) starts a card holding the rows after it, up to the next title; the rows before the first title stay as they
-- are (an introduction); a page without any title gets one card around everything. A group that holds a card already (marked
-- "card": K.card, u.card) keeps its title as a heading without a card around it, and the gaps (marked "gap") at the end of a
-- group go after its card (the room between two cards: none of the page's nodes is left out, the game's react made each one in
-- its tree). w: the cards' width (the page's content). Plain list in, list out.
-- (0.8.8, the Hub's new drawing) The game's own way, as its Finances window (game_mechanics/finance/finances_table.tl: a heading,
-- then its card under it): a title stays above its card, which holds the group's rows only, 4 pixels under the title and 8
-- between two cards; the card is the game's (K.panel), tinted when its title asks for it (marks.tints[title], see U.helpCard).
U.hubCards = function(K, rows, marks, w)
	local lead, groups, cur = {}, {}, nil
	for _, n in ipairs(rows or {}) do
		local m = marks[n]
		if m == "title" then
			cur = { title = n, items = {} }
			groups[#groups + 1] = cur
		elseif cur then cur.items[#cur.items + 1] = n
		else lead[#lead + 1] = n end
	end
	-- (a list's last gaps, taken out of it)
	local function tail(list)
		local t = {}
		while #list > 0 and marks[list[#list]] == "gap" do table.insert(t, 1, table.remove(list)) end
		return t
	end
	-- (0.8.8: the game's card, see K.panel; a kit without it, or MPFEVER_OLDHUB=1: the flat box of before)
	local game = K.game == true and K.panel ~= nil
	local function box(children)
		if game then return K.box(children, K.panel("card", { size = { w, -1 } })) end
		return K.box(children, { size = { w, -1 }, padding = { 10, 12, 10, 12 }, background = U.HUB_TINT.card })
	end
	local function holdsCard(list) for _, n in ipairs(list) do if marks[n] == "card" then return true end end return false end
	local out = {}
	local function add(list) for _, n in ipairs(list) do out[#out + 1] = n end end
	local leadTail = tail(lead)
	if #groups == 0 then
		if #lead > 0 and not holdsCard(lead) then out[1] = box(lead) else add(lead) end
		add(leadTail)
		return out
	end
	add(lead)
	add(leadTail)
	for _, g in ipairs(groups) do
		local after = tail(g.items)
		-- (0.8.8: 8 pixels between two cards, as in the game's Finances window)
		if #out > 0 and marks[out[#out]] ~= "gap" then out[#out + 1] = K.gap(1, game and K.SPACE or 12) end
		if game then
			-- (0.8.8) the game's way (Finances: a heading, then its card under it): the title stays above its card, which holds
			-- the rows only; a card tinted for its title (marks.tints: « How does it work? » in the info bubble's colour)
			out[#out + 1] = g.title
			if #g.items > 0 then
				out[#out + 1] = K.gap(1, 4)
				if holdsCard(g.items) then add(g.items)
				else out[#out + 1] = K.box(g.items, K.panel(type(marks.tints) == "table" and marks.tints[g.title] or "card", { size = { w, -1 } })) end
			end
		elseif holdsCard(g.items) then
			out[#out + 1] = g.title
			out[#out + 1] = K.gap(1, 6)
			add(g.items)
		else
			local c = { g.title }
			if #g.items > 0 then c[#c + 1] = K.gap(1, 6) end
			for _, n in ipairs(g.items) do c[#c + 1] = n end
			out[#out + 1] = box(c)
		end
		add(after)
	end
	return out
end
U.featLib = function()
	if U.featOff then return nil end
	local F = C.feat()
	if F and not U.featLoaded then U.featLoaded = true; F.load(log) end
	return F
end
-- the options host, the map of the options on in this mode (a choice of the host just asked counts until MPFever.exe has it, or 15
-- s, see U.featAsk) and the mode; nil when there is no options host
U.featView = function(st)
	local F = U.featLib()
	if not F then return nil end
	local mode = (st and st.mode == "separate") and "separate" or "shared"
	local raw = st and st.opts or ""
	local key = mode .. "|" .. raw
	if U.featKey ~= key then U.featKey, U.featMapCached = key, F.parse(F.canon(raw, mode)) end
	local map = U.featMapCached
	if U.featAsked and next(U.featAsked) ~= nil then
		local m = {}
		for k, v in pairs(map) do m[k] = v end
		for k, a in pairs(U.featAsked) do
			if map[k] == a.v or (a.v == "0" and map[k] == nil) or os.clock() - a.at > 15 then U.featAsked[k] = nil
			else m[k] = a.v ~= "0" and a.v or nil end
		end
		map = m
	end
	return F, map, mode
end
-- the host asks MPFever.exe for an option on or off ("id", "1"/"0") or a parameter ("id.param", value)
U.featAsk = function(key, value)
	value = tostring(value)
	if U.menuRequest("opt", key .. "=" .. value) then
		U.featAsked = U.featAsked or {}
		U.featAsked[key] = { v = value, at = os.clock() }
		U.winChanged()
	end
end
-- the modules' tabs while one of their options is on (see F.tabs)
U.featTabs = function(st)
	local ok, list = pcall(function()
		local F, map = U.featView(st)
		return F and F.tabs(map) or {}
	end)
	return ok and list or {}
end
-- the co-op shows the Game tab when an option is on, or to the host when the co-op has options to offer
U.featGameTab = function(st)
	local ok, show = pcall(function()
		local F, map, mode = U.featView(st)
		if not F then return false end
		return next(map) ~= nil or (U.isHost(st) and #F.offered(mode) > 0)
	end)
	return ok and show == true
end
-- The Game tab's section: for the host, every option of this mode with its On / Off buttons, its text and, while it is on, its
-- parameters; for the players, the options on and their parameters
U.featGameRows = function(K, st, rows)
	local F, map, mode = U.featView(st)
	if not F then return end
	local offered = F.offered(mode)
	if #offered == 0 then return end
	local W = K.TEXT_W
	local host = U.isHost(st)
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.section(K.ICON_SETTINGS, T("Options de partie (0.6)", "Game options (0.6)"))
	if not host then
		local sum = F.summary(map, mode, T)
		if #sum == 0 then rows[#rows + 1] = K.muted(T("Aucune option de partie activée.", "No game option on."), W) end
		for _, s in ipairs(sum) do
			rows[#rows + 1] = K.text(s.title, nil, nil, W)
			for _, ps in ipairs(s.params) do rows[#rows + 1] = K.muted("   " .. ps, W) end
		end
		return
	end
	rows[#rows + 1] = K.muted(T("Désactivées par défaut. Vous les choisissez pour tous les joueurs ; elles sont gardées dans la sauvegarde.",
		"Off by default. You choose them for every player; they are kept in the savegame."), W)
	for _, e in ipairs(offered) do
		local id = e.opt.id
		local on = F.on(map, id)
		rows[#rows + 1] = K.gap(1, 8)
		rows[#rows + 1] = K.text(F.text(e.opt.title or id, T), nil, nil, W)
		-- (0.8.8, the Hub's new drawing: On / Off and a parameter's values as the game's groups of toggle buttons, see K.choice; any
		-- other kit, the small window, MPFEVER_OLDHUB=1: the buttons of before, the chosen one in primary)
		local onOff = K.choice and K.choice({ { label = T("Activée", "On") }, { label = T("Désactivée", "Off") } }, on and 1 or 2, function(i)
			if i == 1 and not on then U.featAsk(id, 1) elseif i == 2 and on then U.featAsk(id, 0) end
		end, "opt-" .. tostring(id))
		if onOff ~= nil then
			rows[#rows + 1] = K.row { onOff }
		else
			rows[#rows + 1] = K.row { K.btn(T("Activée", "On"), nil, function() if not on then U.featAsk(id, 1) end end, on),
				K.gap(4, 1), K.btn(T("Désactivée", "Off"), nil, function() if on then U.featAsk(id, 0) end end, not on) }
		end
		if e.opt.desc then rows[#rows + 1] = K.muted(F.text(e.opt.desc, T), W) end
		if on then
			for _, p in ipairs(e.params) do
				local cur = tostring(F.param(map, id, p.id))
				rows[#rows + 1] = K.text("   " .. F.text(p.label or p.id, T), nil, nil, W)
				local items, sel = {}, nil
				if K.choice then
					for i, v in ipairs(p.values) do
						items[i] = { label = F.showValue(p, v, T) }
						if tostring(v) == cur then sel = i end
					end
				end
				-- (rows of six buttons at most: nothing may go out of the window)
				local values = K.choice and K.choice(items, sel, function(i)
					local v = p.values[i]
					if v ~= nil and tostring(v) ~= cur then U.featAsk(id .. "." .. p.id, tostring(v)) end
				end, "opt-" .. tostring(id) .. "-" .. tostring(p.id), 6)
				if values ~= nil then
					rows[#rows + 1] = K.row { values }
				else
					local line = {}
					for _, v in ipairs(p.values) do
						local pick = tostring(v)
						if #line >= 12 then rows[#rows + 1] = K.row(line); line = {} end
						line[#line + 1] = K.btn(F.showValue(p, v, T), nil, function() if pick ~= cur then U.featAsk(id .. "." .. p.id, pick) end end, pick == cur)
						line[#line + 1] = K.gap(4, 1)
					end
					if #line > 0 then rows[#rows + 1] = K.row(line) end
				end
			end
		end
	end
end
-- What a module's tab gets to draw itself (M.ui(u)): its options, the files its gui writes (env.write), a request to its module on
-- this game, an event of its own, and the window's widgets. A widget returns its node: u.add(node) puts it in the tab, and M.ui
-- may also return a list of nodes (they come after those added).
U.featU = function(K, st, M)
	local F, map, mode = U.featView(st)
	local W = K.TEXT_W
	local rows = {}
	local u = { W = W, mode = mode, isHost = U.isHost(st), me = st and st.me, rows = rows, T = T, Tf = C.Tf, money = money, myCo = U.myCo }
	u.on = function(id) return F.on(map, id) end
	u.param = function(id, pid) return F.param(map, id, pid) end
	-- (the lines of feat_<module>_<name>.txt, written by the module's gui with env.write; {} when there is none)
	u.read = function(name)
		local lines = {}
		if type(name) ~= "string" or not name:match("^[a-z0-9_]+$") then return lines end
		local f = C.IO.open(C.DIR .. C.BS .. "feat_" .. M.ID .. "_" .. name .. ".txt", "rb")
		if not f then return lines end
		local s = f:read("*a") or ""
		f:close()
		for line in s:gmatch("[^" .. C.NL .. "]+") do lines[#lines + 1] = (line:gsub(C.CR, "")) end
		return lines
	end
	-- (to M.request of the module on this game, through the bridge: ui.log "feat_req")
	u.request = function(kind, payload) sendLine("feat_req", { m = M.ID, kind = tostring(kind), payload = payload }) end
	-- (a line "key=value" of mp_status.txt, as MPFever.exe wrote it for this game; "" when there is none. The host's own lines too,
	-- never sent to the players: the public games' pending, bans...)
	u.status = function(key) return tostring(st and st[tostring(key)] or "") end
	-- (a request to MPFever.exe, as the window's own buttons send them: menu_req.txt, OnMenuRequest)
	u.exe = function(cmd, arg) return U.menuRequest(tostring(cmd), arg) end
	-- (an event of the module, sent as a command of this player: stamped, applied by every game at the same step)
	u.send = function(name, param)
		if F.eventOwner[name] ~= M then log("window: event " .. tostring(name) .. " is not one of " .. M.ID .. "'s") return false end
		local ok, err = pcall(function() api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", name, type(param) == "table" and param or {})) end)
		if not ok then log("window: event " .. name .. " not sent: " .. tostring(err)) end
		return ok
	end
	-- (0.6) u.rich: the page is drawn by the Hub (U.hubDrawing, with a kit that has boxes): the titles start cards (U.hubCards),
	-- the tables have a head and stripes, u.card, u.bar and u.stat draw boxes. Otherwise (the small window of MPFEVER_HUB=0, the
	-- tests' kits) every helper draws what it drew before 0.6's Hub, and the new ones fall back to plain rows.
	local rich = U.hubDrawing == true and K.box ~= nil
	u.rich = rich
	-- (0.8.8) the Hub's new drawing, in the game's own style (see U.makeKit; never with another kit or MPFEVER_OLDHUB=1)
	local game = rich and K.game == true and K.panel ~= nil
	-- (the nodes the page's cards are made from, see U.hubCards: the Hub's own table while it draws, else this page's)
	local marks = (rich and U.hubMarks) or {}
	u.marks = marks
	u.add = function(node) if node ~= nil then rows[#rows + 1] = node end return node end
	u.title = function(t)
		if not rich then return K.section(K.ICON_SETTINGS, tostring(t)) end
		-- (0.8.8: the game's heading, as wide as the page's cards, see K.heading; before: a bold text)
		local n = game and K.heading(tostring(t), W + 40) or K.text(tostring(t), "font-scale-title-4", nil, W)
		marks[n] = "title"
		return n
	end
	-- (the Hub: the texts and buttons u made, so that a row of a text and buttons gives the text only what the buttons leave)
	-- In the Hub a text is made only where it goes (u.row, u.card, a cell of u.table, the page: U.featTabRows), at the width it
	-- gets there: u.text and u.muted give a token (an empty table, its text in `deferred`) that u.resolve turns into the node. No
	-- node is made and then left out (the game's react makes each node in its tree as it is asked for).
	local made, deferred, nodes = {}, {}, {}
	u.resolve = function(x, w)
		local d = x ~= nil and deferred[x] or nil
		if not d then return x end
		if d.kind == "muted" then return K.muted(d.t, w or W) end
		return K.text(d.t, nil, d.cls, w or W)
	end
	u.text = function(t, cls)
		if not rich then return K.text(t, nil, cls, W) end
		local x = {}
		deferred[x] = { kind = "text", t = t, cls = cls }
		return x
	end
	u.muted = function(t)
		if not rich then return K.muted(t, W) end
		local x = {}
		deferred[x] = { kind = "muted", t = t }
		return x
	end
	u.gap = function(h)
		local n = K.gap(1, h or 8)
		if rich then marks[n] = "gap" end
		return n
	end
	-- (0.6) a heading over several cards: a bigger title, and a line under it
	u.section = function(t, sub)
		if not rich then
			local n = K.section(K.ICON_SETTINGS, tostring(t))
			if sub then return K.col { n, K.muted(sub, W) } end
			return n
		end
		local list = { K.text(tostring(t), "font-scale-title-3", nil, W) }
		if sub then list[#list + 1] = K.muted(sub, W) end
		return K.col(list)
	end
	-- (0.6) a card: a box with a title (nil: none) and its children, the width of the page; opts.color: a company's colour (a
	-- number, or { r, g, b }) as a swatch before the title, opts.tint: "warning", "error", "success" or "info" for a tinted
	-- background, opts.right: nodes after the title (buttons, opts.rightW: their width). The children take u.W (a card's room).
	-- Without the Hub: the title (u.title) and the children one under the other, as the pages did before.
	u.card = function(title, children, opts)
		opts = type(opts) == "table" and opts or {}
		local list = {}
		if not rich then
			if title then list[#list + 1] = u.title(title) end
			for _, c in ipairs(children or {}) do list[#list + 1] = c end
			return K.col(list)
		end
		if title or opts.right then
			local head = {}
			local tw = W - (tonumber(opts.rightW) or 0)
			if opts.color ~= nil then
				head[#head + 1] = K.box({ K.gap(1, 5), K.rect(14, 14, U.hubRgba(opts.color)) })
				head[#head + 1] = K.gap(8, 1)
				tw = tw - 22
			end
			-- (0.8.8: a card's title in the game's headline font, as its ContentCard writes it)
			head[#head + 1] = K.text(tostring(title or ""), game and "font-scale-headline" or "font-scale-title-4", nil, math.max(40, tw))
			for _, n in ipairs(opts.right or {}) do head[#head + 1] = u.resolve(n) end
			list[#list + 1] = K.row(head)
			list[#list + 1] = K.gap(1, 6)
		end
		for _, c in ipairs(children or {}) do list[#list + 1] = u.resolve(c) end
		local n
		-- (0.8.8: the game's card, tinted as its info bubble is, see K.panel; the page's texts are 40 narrower than its cards)
		if game then n = K.box(list, K.panel(opts.tint or "card", { size = { W + 40, -1 } }))
		else n = K.box(list, { size = { W + 24, -1 }, padding = { 10, 12, 10, 12 }, background = U.HUB_TINT[opts.tint or "card"] or U.HUB_TINT.card }) end
		marks[n] = "card"
		return n
	end
	-- (0.6) a horizontal bar: fraction (0..1) of its length filled in colour (see U.hubRgba: { r, g, b }, a class, a company's
	-- number), label after it (nil: none); opts.lead: a text before it (opts.leadW its width, 200 by default), opts.width: the bar's
	-- length (else what the texts leave), opts.labelW: the label's width, opts.height (14). Without the Hub: the texts only (nil
	-- when there are none).
	u.bar = function(fraction, colour, label, opts)
		opts = type(opts) == "table" and opts or {}
		if not rich then
			local s = (opts.lead and (tostring(opts.lead) .. "   ") or "") .. (label and tostring(label) or "")
			return s ~= "" and K.muted(s, W) or nil
		end
		local f = math.max(0, math.min(1, tonumber(fraction) or 0))
		local leadW = opts.lead and (tonumber(opts.leadW) or 200) or 0
		local labelW = label and (tonumber(opts.labelW) or math.min(260, math.floor(W * 0.3))) or 0
		local bw = tonumber(opts.width) or (W - leadW - labelW - (opts.lead and 10 or 0) - (label and 10 or 0))
		bw = math.max(40, math.floor(bw))
		local h = tonumber(opts.height) or 14
		-- (0.8.8) the game's own progress bar (builtin.ProgressBar, as its loans and subsidies show theirs: game_mechanics/finance/
		-- finances_loan_gui.tl; the game's rule gives it its rounded track on BaseVeryDark and its height of 20, the fill takes the
		-- style's colour). The lead and the label stay texts beside it, at the same widths. A game without that widget, or an
		-- error making it: the two rectangles of before.
		local bar = nil
		if game then
			local okP, pb = pcall(function()
				local PB = K.builtin.ProgressBar
				if not PB then return nil end
				local c = U.hubRgba(colour)
				return PB { meta = { class = "font-scale-annotation",
					styleSheet = K.style { size = { bw, math.max(20, h) }, color = api.type.Vec4f.new(c[1], c[2], c[3], c[4] or 1) } }, value = f }
			end)
			if okP and pb ~= nil then bar = pb end
		end
		if bar == nil then
			local fill = math.floor(bw * f + 0.5)
			local track = K.box(fill >= 1 and { K.rect(fill, h, U.hubRgba(colour)) } or {}, { size = { bw, h }, background = U.HUB_TINT.track }, K.H)
			-- (the bar a little lower: in the middle of the texts' line)
			bar = K.box({ K.gap(1, 4), track })
		end
		local cells = {}
		if opts.lead then cells[#cells + 1] = K.text(tostring(opts.lead), nil, opts.leadCls, leadW); cells[#cells + 1] = K.gap(10, 1) end
		cells[#cells + 1] = bar
		if label then cells[#cells + 1] = K.gap(10, 1); cells[#cells + 1] = K.text(tostring(label), nil, opts.labelCls, labelW) end
		return K.row(cells)
	end
	-- (0.6) a figure in a small box: its name above, the figure big (cls: "success", "warning"...); opts.width (180). u.stats(list
	-- of { label, value, cls }): the boxes side by side, as many as the page's width takes. Without the Hub: "name: figure".
	u.stat = function(label, value, cls, opts)
		opts = type(opts) == "table" and opts or {}
		if not rich then return K.text(tostring(label) .. T(" : ", ": ") .. tostring(value), nil, cls, W) end
		local w = tonumber(opts.width) or 180
		-- (0.8.8: a darker box with the card's contour, as the game's cards hold theirs; the same padding: the widths are kept)
		if game then
			return K.box({ K.muted(tostring(label), w - 20), K.text(tostring(value), "font-scale-title-3", cls, w - 20) },
				K.panel(opts.tint or "inner", { size = { w, -1 }, padding = { 6, 10, 6, 10 } }))
		end
		return K.box({ K.muted(tostring(label), w - 20), K.text(tostring(value), "font-scale-title-3", cls, w - 20) },
			{ size = { w, -1 }, padding = { 6, 10, 6, 10 }, background = U.HUB_TINT[opts.tint or "card"] or U.HUB_TINT.card })
	end
	u.stats = function(list, width)
		local out = {}
		if not rich then
			for _, s in ipairs(list or {}) do out[#out + 1] = u.stat(s[1], s[2], s[3]) end
			return K.col(out)
		end
		local w = tonumber(width) or 180
		-- (0.8.8: a row of boxes never wider than the page's texts, the room in one of the game's cards)
		local per = math.max(1, math.floor((W + (game and 0 or 24) + 10) / (w + 10)))
		local line = {}
		for _, s in ipairs(list or {}) do
			if #line > 0 then line[#line + 1] = K.gap(10, 1) end
			line[#line + 1] = u.stat(s[1], s[2], s[3], { width = w })
			if #line >= per * 2 - 1 then out[#out + 1] = K.row(line); out[#out + 1] = K.gap(1, 8); line = {} end
		end
		if #line > 0 then out[#out + 1] = K.row(line) end
		return K.col(out)
	end
	-- (0.6) a company's colour { r, g, b } (its number in the companies' registry), nil when it is not known here
	u.coColor = function(id)
		id = tonumber(id)
		if not id or not (U.coColors and U.coColors[id]) then return nil end
		local c = U.hubRgba(id)
		return { c[1], c[2], c[3] }
	end
	u.button = function(label, fn, primary, enabled, tip)
		local n = K.btn(label, tip, function()
			local ok, err = pcall(fn)
			if not ok then log("window: " .. M.ID .. ": " .. tostring(err)) end
			U.winChanged()
		end, primary, enabled)
		-- (its width, about: 8 pixels a character and its padding)
		if rich then made[n] = { kind = "button", w = 34 + 8 * U.featLen(label) } end
		return n
	end
	-- (0.6, the Hub) a row whose texts were made at the page's width: drawn again at what its buttons leave (else they would go out
	-- of the card)
	u.row = function(children)
		if not rich then return K.row(children) end
		local texts, others = 0, 0
		for i, c in ipairs(children or {}) do
			if deferred[c] then texts = texts + 1
			elseif made[c] and made[c].w then others = others + made[c].w end
			if i > 1 then others = others + 6 end
		end
		local w = texts > 0 and math.max(80, math.floor((W - others) / texts)) or W
		local out = {}
		for i, c in ipairs(children or {}) do
			if i > 1 and texts > 0 and others > 0 then out[#out + 1] = K.gap(6, 1) end
			out[#out + 1] = u.resolve(c, w)
		end
		return K.row(out)
	end
	-- (0.6: a text field; what was typed stays across the window's rebuilds (its localKey, key: the module's name for it); onValue
	-- gets the text at every key and when it is accepted)
	u.input = function(placeholder, onValue, key, width)
		local function give(v)
			local ok, err = pcall(onValue, tostring(v or ""))
			if not ok then log("window: " .. M.ID .. ": " .. tostring(err)) end
		end
		local n = K.builtin.TextInputField {
			meta = { class = "font-scale-body", localKey = "mpfever-feat-" .. M.ID .. "-" .. tostring(key or ""), styleSheet = K.style { size = { width or 300, -1 } } },
			value = "", placeholderText = tostring(placeholder or ""), maxLength = 200, acceptOnFocusLoss = true,
			onTyping = give, onValueChange = give,
		}
		-- (0.7.4: its width counted by u.row, as a button's)
		if rich then made[n] = { kind = "input", w = width or 300 } end
		return n
	end
	-- (lines of cells, in columns: widths in pixels, else the width shared; header: the first line as titles). 0.6, the Hub: a
	-- real table, its head on a darker band, its rows striped, the columns aligned in the page's width (the widths given are
	-- stretched or shrunk to it); a cell may be a node (a button, a bar: u.bar(f, colour, nil, { width = ... })); opts.highlight(i,
	-- line): true for a row of this player's own (a blue band), opts.width: the table's width (u.W).
	u.table = function(lines, widths, header, opts)
		local out = {}
		if not rich then
			for i, line in ipairs(lines or {}) do
				local cells = {}
				local n = math.max(1, #line)
				for j, cell in ipairs(line) do
					local w = (widths and widths[j]) or math.floor(W / n)
					cells[#cells + 1] = K.text(cell, (header and i == 1) and "font-scale-title-4" or nil, nil, w)
				end
				out[#out + 1] = K.row(cells)
			end
			return K.col(out)
		end
		opts = type(opts) == "table" and opts or {}
		local n = 0
		for _, line in ipairs(lines or {}) do n = math.max(n, #line) end
		n = math.max(1, n)
		-- (0.8.8: the game's table, game_mechanics/finance/finances.css.lua: 12 pixels around a cell, the head on BaseDark, the
		-- rows BaseLight / BaseMedium, this player's row in the accent; before: 4 / 8 pixels and white veils)
		local padH, padV, gut = game and 12 or 8, game and 12 or 4, game and 12 or 8
		local TINT = game and K.tint or function(k) return U.HUB_TINT[k] end
		local inner = (tonumber(opts.width) or W) - 2 * padH
		local ws, sum = {}, 0
		for j = 1, n do
			ws[j] = math.max(16, tonumber(widths and widths[j]) or math.floor(inner / n))
			sum = sum + ws[j]
		end
		-- (the widths a page gave for the small window, stretched to the Hub's page; the last column takes what is left)
		local k = inner / math.max(1, sum)
		local used = 0
		for j = 1, n do
			ws[j] = math.max(16, math.floor(ws[j] * k))
			if j == n then ws[j] = math.max(16, inner - used) end
			used = used + ws[j]
		end
		for i, line in ipairs(lines or {}) do
			local head = header and i == 1
			local cells = {}
			for j = 1, n do
				local cell = line[j]
				if cell == nil then cell = "" end
				-- (each text in a box of its column's width: the game sizes a lone text to its letters, and the columns ran together)
				if deferred[cell] then
					cells[#cells + 1] = K.box({ u.resolve(cell, ws[j] - gut) }, { size = { ws[j], -1 } }, K.H)
				elseif type(cell) == "string" or (type(cell) == "number" and not (made[cell] or nodes[cell])) then
					local t = head and K.colored(tostring(cell), K.color("NeutralLight"), ws[j] - gut) or K.text(tostring(cell), nil, nil, ws[j] - gut)
					cells[#cells + 1] = K.box({ t }, { size = { ws[j], -1 } }, K.H)
				else
					cells[#cells + 1] = K.box({ cell }, { size = { ws[j], -1 } }, K.H)
				end
			end
			local bg = head and TINT("head") or ((i % 2 == (header and 0 or 1)) and TINT("odd") or TINT("even"))
			if not head and type(opts.highlight) == "function" then
				local okH, hi = pcall(opts.highlight, header and i - 1 or i, line)
				if okH and hi then bg = TINT("mine") end
			end
			out[#out + 1] = K.box(cells, { size = { inner + 2 * padH, -1 }, padding = { padV, padH, padV, padH }, background = bg }, K.H)
		end
		return K.col(out)
	end
	-- (0.7.4, the menus redone) the window's old pages asked (Settings, MPFEVER_OLDMENUS=1): the modules draw their pages of 0.7.3
	u.oldMenus = type(U.oldMenus) == "function" and U.oldMenus() or false
	-- (0.7.4) a list to pick from (the game's ComboBox): items { { value = v, label = "..." }, ... }, value the one shown; onValue(v)
	-- when the player picks another (the item's own value, not its place in the list)
	u.choice = function(items, value, onValue, width)
		local list, at = {}, nil
		for i, it in ipairs(items or {}) do
			list[#list + 1] = K.builtin.ComboBoxItem { value = i, content = K.text(tostring(it.label or it.value)) }
			if it.value == value then at = i end
		end
		if #list == 0 then return K.muted(T("(rien à choisir)", "(nothing to pick)"), width or 200) end
		local n = K.builtin.ComboBox { meta = width and { styleSheet = K.style { size = { width, -1 } } } or nil, value = at or 1, items = list,
			onValueChange = function(v)
				local it = items[tonumber(v) or 0]
				if it and it.value ~= value then
					local ok, err = pcall(onValue, it.value)
					if not ok then log("window: " .. M.ID .. ": " .. tostring(err)) end
					U.winChanged()
				end
			end }
		if rich then made[n] = { kind = "choice", w = width or 200 } end
		return n
	end
	-- (0.7.4) the page's « How does it work? » (U.helpCard): paragraphs { { "French", "English" }, ... } (tests/test_lang.py reads
	-- them in the module) or texts
	u.help = function(key, paragraphs)
		u.helpDone = true
		local list = {}
		for _, p in ipairs(paragraphs or {}) do list[#list + 1] = type(p) == "table" and T(p[1], p[2]) or tostring(p) end
		local tmp = {}
		if type(U.helpCard) ~= "function" then for _, t in ipairs(list) do rows[#rows + 1] = K.muted(t, W) end return end
		U.helpCard(K, tmp, "f_" .. tostring(M.ID) .. "_" .. tostring(key or ""), list)
		for _, n in ipairs(tmp) do rows[#rows + 1] = n end
	end
	-- (the Hub) the game's components are numbers: every one the helpers make is noted, so that a table tells a cell holding a
	-- component (a row of buttons) from a cell holding a number to write (the territories' « View » and « Claim » showed as a
	-- number). MPFEVER_HUBNODES=0: as before
	if rich and os.getenv("MPFEVER_HUBNODES") ~= "0" then
		local plain = { T = true, Tf = true, money = true, on = true, param = true, read = true, request = true, send = true,
			coColor = true, resolve = true, table = true }
		for k, f in pairs(u) do
			if type(f) == "function" and not plain[k] then
				u[k] = function(...)
					local r = f(...)
					if type(r) == "number" then nodes[r] = true end
					return r
				end
			end
		end
	end
	return u
end
-- a module's tab (key "f_<its TAB id>"): its rows, or a line saying it could not be drawn
U.featTabRows = function(K, st, key)
	local W = K.TEXT_W
	for _, tb in ipairs(U.featTabs(st)) do
		if tb.key == key then
			local u = U.featU(K, st, tb.M)
			local ok, more = pcall(tb.M.ui, u)
			if not ok then
				if U.featTabFailed ~= key .. tostring(more) then U.featTabFailed = key .. tostring(more); log("window: the " .. key .. " tab failed: " .. tostring(more)) end
				return { K.text(T("Cet onglet n'a pas pu être affiché (voir ui_mod.log).", "This tab could not be drawn (see ui_mod.log)."), nil, "error", W) }
			end
			for _, n in ipairs(type(more) == "table" and more or {}) do u.rows[#u.rows + 1] = n end
			-- (0.7.4: a module's « How does it work? » (M.HELP: { { "French", "English" }, ... }) at the end of its page, unless it put
			-- it there itself; the window's old pages asked: none)
			if u.rich and not u.oldMenus and not u.helpDone and type(tb.M.HELP) == "table" and #tb.M.HELP > 0 then pcall(u.help, "page", tb.M.HELP) end
			-- (the Hub: the texts made where they go, see u.resolve)
			if u.rich then for i, n in ipairs(u.rows) do u.rows[i] = u.resolve(n) end end
			return u.rows
		end
	end
	return { K.muted(T("Cette option n'est plus activée.", "This option is no longer on."), W) }
end

-- Settings: whether the window opens by itself, the bankruptcy rule (the host, one company per player), the settings (read
-- only), the problem report
U.BANKRUPT_MONTHS = { 0, 3, 6, 12, 24 }
U.TABS.settings = function(K, st, ctx)
	local builtin = K.builtin
	local W = K.TEXT_W
	local rows = {}
	local p = U.loadPrefs()
	rows[#rows + 1] = K.section(K.ICON_SETTINGS, T("Fenêtre MPFever", "MPFever window"))
	rows[#rows + 1] = K.row { builtin.CheckBox {
		value = p.autoopen == "0" and 0 or 1,
		label = T("Ouvrir MPFever au début de chaque partie", "Open MPFever when a game starts"),
		onValueChange = function(v) U.saveAutoOpen(v == 1); U.winChanged() end,
	} }
	-- (the computer companies' builds and purchases told in the chat: see U.pollAiJournal)
	if st and st.mode == "separate" then
		rows[#rows + 1] = K.row { builtin.CheckBox {
			value = p.aichat == "0" and 0 or 1,
			label = T("Annoncer dans le chat ce que font les entreprises de l'ordinateur", "Tell in the chat what the computer companies do"),
			onValueChange = function(v) p.aichat = v == 1 and "1" or "0"; U.saveGlobalPrefs(); U.winChanged() end,
		} }
		-- (the dots over the other companies' vehicles, see U.dotsTick)
		rows[#rows + 1] = K.row { builtin.CheckBox {
			value = U.dotsOn() and 1 or 0,
			label = T("Un point de leur couleur sur les véhicules des autres entreprises", "A dot of their colour over the other companies' vehicles"),
			onValueChange = function(v) p.vdots = v == 1 and "1" or "0"; U.saveGlobalPrefs(); U.winChanged() end,
		} }
	end
	-- (0.7.4: the window's pages of 0.7.3, for those who prefer them; this PC only, kept across launches)
	rows[#rows + 1] = K.row { builtin.CheckBox {
		value = U.oldMenus() and 1 or 0,
		label = T("Utiliser les anciennes pages de la fenêtre (MPFever 0.7.3)", "Use the window's old pages (MPFever 0.7.3)"),
		onValueChange = function(v) p.oldmenus = v == 1 and "1" or "0"; U.saveGlobalPrefs(); U.winChanged() end,
	} }
	-- (the bankruptcy rule is in the Game tab since 0.5.14, with the game's other rules)
	U.settingsRows(K, rows)
	rows[#rows + 1] = K.gap(1, 12)
	rows[#rows + 1] = K.section(K.ICON_ALERT, T("Un problème ?", "A problem?"))
	rows[#rows + 1] = K.muted(T("MPFever.exe rassemble les journaux dans un zip et ouvre un nouveau ticket GitHub.", "MPFever.exe gathers the logs into a zip and opens a new GitHub issue."), W)
	-- (the Discord: MPFever.exe opens it in the browser)
	rows[#rows + 1] = K.row { K.btn(U.reportLabel(), nil, requestReport), K.gap(8, 1),
		K.btn("Discord", "discord.gg/DfMxFUQZCR", function() U.menuRequest("discord") end) }
	if U.reportMsg and U.reportAsked and os.time() - U.reportAsked <= 120 then rows[#rows + 1] = K.muted(U.reportMsg, W) end
	return rows
end

-- ---------------------------------------------------------------- the window itself
-- The tab strip: the game's TabWidget, as its entity windows put it at the top of their content (make_entity_window.tl).
-- MPFEVER_WINTABS=buttons: a row of buttons instead (the main menu page's way), should the tab strip misbehave.
U.tabStrip = function(K, tabs, cur)
	local builtin = K.builtin
	if os.getenv("MPFEVER_WINTABS") == "buttons" then
		local r = {}
		for i, id in ipairs(tabs) do
			if i > 1 then r[#r + 1] = K.gap(4, 1) end
			r[#r + 1] = K.btn(U.tabLabel(id), nil, function() U.setTab(id) end, id == cur)
		end
		return K.row(r)
	end
	local children = {}
	for _, id in ipairs(tabs) do
		children[#children + 1] = builtin.TabWidgetChild {
			localKey = "mpfever-tab-" .. id,
			value = id,
			indicator = builtin.TextView { meta = { class = "font-scale-tab-widget-indicator" }, text = U.tabLabel(id) },
			item = builtin.Component {},
		}
	end
	return builtin.TabWidget {
		meta = { class = "no-content", disableFocusableRecursive = true },
		orientation = builtin.type.TabOrientation.North,
		deselectAllowed = false,
		value = cur,
		onValueChange = function(v) if v ~= nil and tostring(v) ~= U.tab then U.setTab(tostring(v)) end end,
		tabs = children,
	}
end

-- the small card (issue #68): the link, the sync, the players, and the chat
U.compactContent = function(K, st)
	local CW = 260
	local sync, syncCls = syncLine(st)
	local link, linkCls = linkLine(st)
	local mini = {}
	if link then mini[#mini + 1] = K.row { K.dot(linkCls), K.gap(6, 1), K.text(link, nil, linkCls, CW - 20) } end
	mini[#mini + 1] = K.row { K.dot(syncCls), K.gap(6, 1), K.text(sync, nil, syncCls, CW - 20) }
	mini[#mini + 1] = K.row { K.icon(K.ICON_PLAYERS, 20), K.gap(6, 1), K.text(T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")") }
	local unread = U.chatUnread or 0
	local line = {
		K.builtin.Button { meta = { class = unread > 0 and "primary" or "secondary", tooltip = T("Discussion", "Chat") }, content = K.icon(K.ICON_CHAT, 20),
			onClick = function() U.compact = false; U.setTab("chat") end },
		K.gap(6, 1),
		K.btn(T("Agrandir", "Expand"), nil, function() U.setCompact(false) end),
	}
	-- (0.6) the Hub, from the small card too
	if U.HubWindow and U.hubOn() then line[#line + 1] = K.gap(6, 1); line[#line + 1] = K.btn("Hub", U.hubTip(), function() U.openHub() end) end
	mini[#mini + 1] = K.row(line)
	return K.builtin.Component { meta = { styleSheet = K.style { size = { 280, -1 } } }, layout = K.col(mini) }
end

-- the window's content: the tab strip, then the tab (a scroll area of fixed size; the Chat tab without one)
U.windowContent = function(K, st, chat, ctx)
	local builtin = K.builtin
	if U.compact then return U.compactContent(K, st) end
	local tabs = U.winTabs(st)
	local tab = U.validTab(U.tab, st)
	local rows, result = nil, "ok"
	local okB, res = pcall(function()
		if tab == "chat" then return U.chatBody(K, st, chat, ctx) end
		-- (0.6: a game option's module's own tab, see U.featTabRows)
		if not U.TABS[tab] and tab:sub(1, 2) == "f_" then return U.featTabRows(K, st, tab) end
		return U.TABS[tab](K, st, ctx)
	end)
	if okB and type(res) == "table" then rows = res else
		result = tostring(res)
		if U.tabFailed ~= tab .. result then U.tabFailed = tab .. result; log("window: the " .. tab .. " tab failed: " .. result) end
		rows = { K.text(T("Cet onglet n'a pas pu être affiché (voir ui_mod.log).", "This tab could not be drawn (see ui_mod.log)."), nil, "error", K.TEXT_W) }
	end
	if not U.tabReqHub then U.ackTabReq(tab, result, #rows) end
	local body
	if tab == "chat" then
		-- (the same height as the other tabs: the window kept jumping in size from one tab to the other)
		body = builtin.Component { meta = { localKey = "mpfever-body-chat", styleSheet = K.style { size = { K.WIN_W, K.BODY_H } } }, layout = K.col(rows) }
	else
		body = builtin.ScrollArea {
			meta = { localKey = "mpfever-body-" .. tab, styleSheet = K.style { size = { K.WIN_W, K.BODY_H } } },
			content = builtin.Component { meta = { styleSheet = K.style { size = { K.INNER_W, -1 } } }, layout = K.col(rows) },
			horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
			verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
		}
	end
	local top = { U.tabStrip(K, tabs, tab), K.gap(1, 8), body }
	-- (0.6) the quick view's way to the Hub: a clear button above the tabs
	if U.HubWindow and U.hubOn() then
		table.insert(top, 1, K.row { K.btn(T("Ouvrir le Hub", "Open the Hub"), U.hubTip(), function() U.openHub() end, true), K.gap(10, 1),
			K.muted(U.hubTip(), K.TEXT_W - 170) })
		table.insert(top, 2, K.gap(1, 8))
	end
	return builtin.Component { meta = { styleSheet = K.style { size = { K.WIN_W, -1 } } }, layout = K.col(top) }
end
-- (0.6) what the Hub holds, under its button
U.hubTip = function()
	if U.status and U.status.mode == "separate" then
		return T("Toutes les pages : entreprise, règles et options, classements, commerce…", "Every page: company, rules and options, rankings, trade…")
	end
	return T("Toutes les pages : règles et options, réglages, classements…", "Every page: rules and options, settings, rankings…")
end

-- (0.6) the Hub's page: the page's own rows (a tab of the small window's, a game option's module, the chat), drawn in the Hub's
-- measures (the kit's widths swapped for the Hub's while it draws, see U.hubContent) and put into cards (U.hubCards)
U.hubPageRows = function(K, st, chat, ctx, page)
	if page == "chat" then return U.chatBody(K, st, chat, ctx) end
	if not U.TABS[page] and page:sub(1, 2) == "f_" then return U.featTabRows(K, st, page) end
	return U.TABS[page](K, st, ctx)
end
U.HUB_KIT_KEYS = { "WIN_W", "BODY_H", "INNER_W", "TEXT_W", "CARD_W", "CARD_TEXT_W", "section", "gap", "card" }
-- (0.8.8) The Hub's navigation in the game's own way, as its Company window has it (game_mechanics/company/company.tl): the three
-- groups are North tabs (builtin.TabWidget, with empty items as the entity windows' tab strip and this mod's small window:
-- class "no-content", gui/entity_window/make_entity_window.tl), the group's pages a builtin.List on the left, each entry an icon
-- and its name in the headline font (the list's own global rules show the entry under the mouse and the one chosen,
-- gui/main/builtin.css.lua "List::Item!checked"); the page's name is in the window's title (U.hubTitle), and the session's state,
-- the size buttons and « Quick view » are icons at the right of the tabs. Returns the tabs' row and the list, or nil when the
-- game no longer has those widgets: the head and the menu of before are drawn then (U.hubHeadOld, U.hubSideOld), as with
-- MPFEVER_OLDHUB=1.
U.hubGroupOfPage = function(menu, page)
	for _, g in ipairs(menu) do for _, id in ipairs(g.pages) do if id == page then return g end end end
	return menu[1]
end
-- a group's tab: the page it showed last in this session, else its first one
U.setHubGroup = function(key, menu)
	for _, g in ipairs(menu or {}) do
		if g.key == key then
			local want, page = U.hubLastIn and U.hubLastIn[key], g.pages[1]
			for _, id in ipairs(g.pages) do if id == want then page = id end end
			if page then U.setHubPage(page) end
			return
		end
	end
end
U.hubNav = function(K, st, m, menu, page)
	local builtin = K.builtin
	local TabWidget, TabChild, List, north, pol
	local okW = pcall(function()
		TabWidget, TabChild, List = builtin.TabWidget, builtin.TabWidgetChild, builtin.List
		north, pol = builtin.type.TabOrientation.North, builtin.type.ScrollBarPolicy
	end)
	local cur = U.hubGroupOfPage(menu, page)
	if not (okW and TabWidget and TabChild and List and north ~= nil and pol and cur) then
		if not U.hubNavMissing then U.hubNavMissing = true; log("hub: the game's tabs or list cannot be had: the menu of before") end
		return nil
	end
	U.hubLastIn = U.hubLastIn or {}
	U.hubLastIn[cur.key] = page
	-- the groups (MPFEVER_WINTABS=buttons: a row of buttons, as the small window's tab strip then)
	local strip
	if os.getenv("MPFEVER_WINTABS") == "buttons" then
		local r = {}
		for i, g in ipairs(menu) do
			local key = g.key
			if i > 1 then r[#r + 1] = K.gap(4, 1) end
			r[#r + 1] = K.btn(g.title, nil, function() if key ~= cur.key then U.setHubGroup(key, menu) end end, key == cur.key)
		end
		strip = K.row(r)
	else
		local tabs = {}
		for _, g in ipairs(menu) do
			tabs[#tabs + 1] = TabChild {
				localKey = "mpfever-hub-group-" .. g.key,
				value = g.key,
				indicator = builtin.TextView { meta = { class = "font-scale-tab-widget-indicator" }, text = g.title },
				item = builtin.Component {},
			}
		end
		strip = TabWidget {
			meta = { class = "no-content", disableFocusableRecursive = true },
			orientation = north,
			deselectAllowed = false,
			value = cur.key,
			onValueChange = function(v) if v ~= nil and tostring(v) ~= cur.key then U.setHubGroup(tostring(v), menu) end end,
			tabs = tabs,
		}
	end
	-- at the right of the tabs: the session's state (its dot and its text), smaller, larger, the quick view (the icons of the game's
	-- window buttons, gui/builtin/window/icons; the texts of the buttons of before are their tooltips)
	local sync, syncCls = syncLine(st)
	local syncW = math.max(120, math.min(300, m.W - 640))
	local rightW = syncW + 150
	local head = K.row {
		K.box({ strip }, { size = { m.W - rightW, -1 } }),
		K.col { K.gap(1, 3), K.row {
			K.col { K.gap(1, 11), K.dot(syncCls, 12) }, K.gap(6, 1), K.col { K.gap(1, 6), K.text(sync, nil, syncCls, syncW) }, K.gap(8, 1),
			K.ibtn(K.ICON_SMALLER, T("Plus petit", "Smaller"), function() U.setHubSize(-1) end, false, (U.hubSize or 2) > 1),
			K.gap(4, 1),
			K.ibtn(K.ICON_LARGER, T("Plus grand", "Larger"), function() U.setHubSize(1) end, false, (U.hubSize or 2) < #U.HUB_SCALES),
			K.gap(4, 1),
			K.ibtn(K.ICON_QUICK, T("Vue rapide", "Quick view") .. "  ·  " .. T("La petite fenêtre : la session et la discussion", "The small window: the session and the chat"),
				function() U.openWindow(nil) end),
		} },
	}
	-- the group's pages: the list, in a darker panel with the card's contour
	local pages, entries, sel = cur.pages, {}, 1
	local tw = math.max(60, m.side - 60)
	for i, id in ipairs(pages) do
		local on = id == page
		if on then sel = i end
		local label = U.hubLabel(id)
		entries[#entries + 1] = builtin.Component {
			meta = { styleSheet = K.style { size = { m.side - 4, -1 }, padding = { 8, 6, 8, 12 } } },
			-- (the chosen page's name in the accent, as the Company window's list writes its chosen rank: company.css.lua)
			layout = K.row { K.icon(U.hubIcon(id), 24), K.gap(8, 1),
				on and K.colored(label, K.color("AccentVeryLight"), tw, "font-scale-headline") or K.text(label, "font-scale-headline", nil, tw) },
		}
	end
	local list = List {
		meta = { localKey = "mpfever-hub-list-" .. cur.key, styleSheet = K.style { size = { m.side - 4, m.bodyH - 12 } } },
		children = entries,
		-- (the list counts from 1, as company.tl's and map_editor.tl's do)
		selectionIndex = sel,
		onSelect = function(index)
			local id = pages[tonumber(index) or 0]
			if id and id ~= page then U.setHubPage(id) end
		end,
		verticalScrollBarPolicy = pol.AsNeeded,
		horizontalScrollBarPolicy = pol.AlwaysOff,
	}
	return head, K.box({ list }, K.panel("inner", { size = { m.side, m.bodyH }, padding = { 6, 2, 6, 2 } }))
end
-- the menu of before 0.8.8: the groups' titles and a button per page (the page shown: the primary one)
U.hubSideOld = function(K, m, menu, page)
	local builtin = K.builtin
	local side = {}
	for gi, g in ipairs(menu) do
		if gi > 1 then side[#side + 1] = K.gap(1, 14) end
		side[#side + 1] = K.colored(g.title, K.color("NeutralLight"), m.side - 24, "font-scale-title-4")
		side[#side + 1] = K.gap(1, 4)
		for _, id in ipairs(g.pages) do
			local target = id
			side[#side + 1] = K.wbtn(U.hubLabel(id), nil, function() U.setHubPage(target) end, id == page, m.side - 24)
			side[#side + 1] = K.gap(1, 3)
		end
	end
	return builtin.ScrollArea {
		meta = { localKey = "mpfever-hub-menu", styleSheet = K.style { size = { m.side, m.bodyH } } },
		content = K.box(side, { size = { m.side - 6, -1 }, padding = { 10, 8, 10, 8 }, background = U.HUB_TINT.side }),
		horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
	}
end
-- the head of before 0.8.8: the page's name and its group, the session's state, the size, the quick view
U.hubHeadOld = function(K, st, m, page)
	local sync, syncCls = syncLine(st)
	local headW = m.W - 330
	return K.row {
		K.box({
			K.text(U.hubLabel(page), "font-scale-title-2", nil, headW),
			K.row { K.muted(U.hubGroupOf(st, page) .. "   ·   ", nil), K.dot(syncCls, 12), K.gap(6, 1), K.text(sync, nil, syncCls, math.max(80, headW - 220)) },
		}, { size = { headW, -1 } }),
		K.gap(12, 1),
		K.btn("  -  ", T("Plus petit", "Smaller"), function() U.setHubSize(-1) end, false, (U.hubSize or 2) > 1),
		K.gap(4, 1),
		K.btn("  +  ", T("Plus grand", "Larger"), function() U.setHubSize(1) end, false, (U.hubSize or 2) < #U.HUB_SCALES),
		K.gap(12, 1),
		K.btn(T("Vue rapide", "Quick view"), T("La petite fenêtre : la session et la discussion", "The small window: the session and the chat"), function() U.openWindow(nil) end),
	}
end
U.hubContent = function(K, st, chat, ctx)
	local builtin = K.builtin
	local m = U.hubMeasures()
	local page = U.hubValid(U.hubPage, st)
	local menu = U.hubMenu(st)
	-- (0.8.8) the Hub's new drawing: this kit's, never with MPFEVER_OLDHUB=1
	local game = K.game == true and K.panel ~= nil
	-- the tabs and the list (0.8.8), else the head and the menu of before
	local head, sideBox = nil, nil
	if game and not K.noNav then
		local okN, h, s = pcall(U.hubNav, K, st, m, menu, page)
		if okN and h ~= nil and s ~= nil then head, sideBox = h, s
		elseif not okN and U.hubNavFailed ~= tostring(h) then U.hubNavFailed = tostring(h); log("hub: its tabs and list not drawn: " .. tostring(h)) end
	end
	local nav = head ~= nil
	if not nav then sideBox = U.hubSideOld(K, m, menu, page) end
	-- the page, drawn in the Hub's measures: the kit's widths and its section, gap and card swapped while it draws (the titles,
	-- the gaps and the cards marked for U.hubCards), the chat's lines as many as the page's height takes
	local marks = {}
	local saved = {}
	for _, k in ipairs(U.HUB_KIT_KEYS) do saved[k] = K[k] end
	local sec, gap, card = K.section, K.gap, K.card
	K.WIN_W, K.BODY_H, K.INNER_W, K.TEXT_W, K.CARD_W, K.CARD_TEXT_W = m.pageW, m.bodyH, m.inner, m.text, m.text, m.text - 24
	-- (0.8.8: the game's cards take the page's width, as the cards of U.hubCards, and leave their texts the page's text width)
	if K.game then K.CARD_W, K.CARD_TEXT_W = m.inner, m.text end
	K.section = function(...) local n = sec(...); marks[n] = "title"; return n end
	-- (0.8.8: never more than the game's 8 pixels between two rows or two cards; the pages asked for 10 to 14)
	K.gap = function(w, h)
		if K.game and w == 1 and (tonumber(h) or 0) > K.SPACE then h = K.SPACE end
		local n = gap(w, h); marks[n] = "gap"; return n
	end
	K.card = function(...) local n = card(...); marks[n] = "card"; return n end
	local chatLines = U.CHAT_LINES
	U.CHAT_LINES = math.max(chatLines or 16, math.floor((m.bodyH - 150) / 26))
	U.hubDrawing, U.hubMarks = true, marks
	local okB, res = pcall(U.hubPageRows, K, st, chat, ctx, page)
	U.hubDrawing, U.hubMarks = nil, nil
	U.CHAT_LINES = chatLines
	for _, k in ipairs(U.HUB_KIT_KEYS) do K[k] = saved[k] end
	local rows, result = nil, "ok"
	if okB and type(res) == "table" then
		rows = res
	else
		result = tostring(res)
		if U.hubFailed ~= page .. result then U.hubFailed = page .. result; log("hub: the " .. page .. " page failed: " .. result) end
		rows = { K.text(T("Cette page n'a pas pu être affichée (voir ui_mod.log).", "This page could not be drawn (see ui_mod.log)."), nil, "error", m.text) }
	end
	local nRows = #rows
	if U.tabReqHub then U.ackTabReq(page, result, nRows, table.concat(U.hubPages(st), ",")) end
	local body
	if page == "chat" then
		-- (no fixed height: the game gave the height left to the last row, the field and its « Send » button, which went to the
		-- middle of the right edge; the menu beside it keeps the Hub's height)
		-- (0.8.8: its lines in one of the game's cards, as wide as the other pages' cards)
		body = builtin.Component { meta = { localKey = "mpfever-hub-chat", styleSheet = K.style { size = { m.pageW, -1 } } },
			layout = K.col(game and { K.box(rows, K.panel("card", { size = { m.inner, -1 } })) } or rows) }
	else
		local okC, carded = pcall(U.hubCards, K, rows, marks, m.inner)
		if okC then rows = carded else log("hub: the " .. page .. " page's cards: " .. tostring(carded)) end
		-- (0.8.8: the room of the scroll bar always kept, as the game's own windows do (finances_table.tl): the page's content
		-- never jumps sideways when it grows; a game without that policy: as before)
		local pol = builtin.type.ScrollBarPolicy
		local reserve = nil
		if game then pcall(function() reserve = pol.AsNeededButAlwaysReserveSpace end) end
		body = builtin.ScrollArea {
			meta = { localKey = "mpfever-hub-page-" .. page, styleSheet = K.style { size = { m.pageW, m.bodyH } } },
			content = builtin.Component { meta = { styleSheet = K.style { size = { m.inner, -1 } } }, layout = K.col(rows) },
			horizontalPolicy = pol.AlwaysOff,
			verticalPolicy = reserve or pol.AsNeeded,
		}
	end
	-- (0.8.8) the tabs, then the list and the page, 8 pixels apart as the game's cards
	if nav then
		return builtin.Component { meta = { styleSheet = K.style { size = { m.W, -1 } } },
			layout = K.col { head, K.gap(1, K.SPACE), K.row { sideBox, K.gap(K.SPACE, 1), body } } }
	end
	-- the head: the page's name and its group, the session's state, the size, the quick view
	head = U.hubHeadOld(K, st, m, page)
	return builtin.Component { meta = { styleSheet = K.style { size = { m.W, -1 } } },
		layout = K.col { head, K.gap(1, 10), K.row { sideBox, K.gap(14, 1), body } } }
end

U.installNewWindow = function(react, builtin)
	local K = U.kit
	U.SessionWindow = react.RegisterWrapperRecipe("MPFeverSessionWindow", builtin.Window, function(wp)
		-- (every hook first, the same ones on every render whatever the tab or the card: the game's react wants them in order)
		local st = useStatus(react)
		local chat = useChat(react)
		local view = react.useState(U.viewKey())
		react.onStepTimer(function()
			local k = U.viewKey()
			if view:old() ~= k then view:set(k) end
		end, 0.25)
		local ctx = {}
		ctx.draft = react.useState("")
		ctx.chatGen = react.useState(0)   -- a new input field after each message (an empty one)
		ctx.amount = react.useState("")   -- the amount typed for a gift to another company
		ctx.giveGen = react.useState(0)
		ctx.giveTo = react.useState(0)    -- the company the gift goes to
		-- (the window removed in any way: the bar's icon opens it again with one click)
		react.onUnmount(function()
			U.winOpen = false
			pcall(U.refreshChat)
		end)
		U.winKick = function()
			local k = U.viewKey()
			if view:old() ~= k then view:set(k) end
		end
		local okC, content = pcall(U.windowContent, K, st, chat, ctx)
		if not okC then
			if not U.winFailed then U.winFailed = true; log("window: not drawn: " .. tostring(content)) end
			content = builtin.Component { meta = { styleSheet = K.style { size = { K.WIN_W, -1 } } },
				layout = K.col { K.text(T("La fenêtre n'a pas pu être affichée (voir ui_mod.log).", "The window could not be drawn (see ui_mod.log)."), nil, "error", K.TEXT_W) } }
		end
		local p = U.loadPrefs()
		return builtin.Window {
			title = U.compact and "MPFever" or ("MPFever – " .. T("Multijoueur", "Multiplayer")),
			id = "window.mpfever.session",
			initialX = 0.99,
			initialY = 0.1,
			movable = true,
			closable = true,
			pinnable = true,
			pinned = p.pinned == "1",
			onPinned = function(on)
				p.pinned = on and "1" or "0"
				U.savePrefs()
				U.winChanged()
			end,
			-- (it opens by itself: it must not take the keyboard from the game)
			autoFocusOnBecomingVisible = false,
			onClose = wp.onClose,
			content = K.padded(content),
		}
	end)
end

-- (0.6) the Hub's window: the same hooks as the small window's (its own states: what is typed in its chat and its gift's amount)
U.installHub = function(react, builtin)
	local K = U.kit
	-- (0.8.8) the game's heading module asked for here, once, outside any drawing (see K.heading: a module that registers its
	-- recipes is not to be loaded for the first time in the middle of a window's drawing)
	if K and K.game and K.base then pcall(K.base, "::/gui/main/content_card.tl", { "ContentCard" }) end
	U.HubWindow = react.RegisterWrapperRecipe("MPFeverHubWindow", builtin.Window, function(wp)
		local st = useStatus(react)
		local chat = useChat(react)
		local view = react.useState(U.hubViewKey())
		-- (0.7.5) where it opens, see U.hubAt (read once by the game, at its first frame)
		local atX, atY = U.hubAt()
		react.onStepTimer(function()
			local k = U.hubViewKey()
			if view:old() ~= k then view:set(k) end
		end, 0.25)
		-- (0.7.5) a few frames after it opens, once laid out, its size is read for its next openings, see U.hubCentre.
		-- MPFEVER_HUBCENTER=0: as before
		if react.onStep and os.getenv("MPFEVER_HUBCENTER") ~= "0" then
			react.onStep(function()
				if not U.hubCenterDue then return end
				U.hubCenterDue = U.hubCenterDue - 1
				if U.hubCenterDue > 0 then return end
				U.hubCenterDue = nil
				pcall(U.hubCentre)
			end)
		end
		local ctx = {}
		ctx.draft = react.useState("")
		ctx.chatGen = react.useState(0)
		ctx.amount = react.useState("")
		ctx.giveGen = react.useState(0)
		ctx.giveTo = react.useState(0)
		react.onUnmount(function()
			U.hubOpen = false
			U.hubKick = nil
			pcall(U.refreshChat)
		end)
		U.hubKick = function()
			local k = U.hubViewKey()
			if view:old() ~= k then view:set(k) end
		end
		local okC, content = pcall(U.hubContent, K, st, chat, ctx)
		if not okC then
			if U.hubDrawFailed ~= tostring(content) then U.hubDrawFailed = tostring(content); log("hub: not drawn: " .. tostring(content)) end
			content = builtin.Component { meta = { styleSheet = K.style { size = { 900, -1 } } },
				layout = K.col { K.text(T("La fenêtre n'a pas pu être affichée (voir ui_mod.log).", "The window could not be drawn (see ui_mod.log)."), nil, "error", 860) } }
		end
		return builtin.Window {
			-- (0.8.8: the page's name in the title, see U.hubTitle; the id never changes: a shown window whose id changes is a
			-- fatal assertion of the game)
			title = U.hubTitle(st),
			id = "window.mpfever.hub",
			initialX = atX,
			initialY = atY,
			movable = true,
			closable = true,
			pinnable = false,
			onClose = wp.onClose,
			content = K.padded(content),
		}
	end)
end

-- ---------------------------------------------------------------- MPFever's icon in the game's bottom bar
-- A plugin of the game's ::GameBarInfoDisplayExtension (the row of Earnings and Transported; mpfever_bar.res.lua): a disc in the
-- session's colour (U.barState) and « MPFever », with the number of unread chat messages; a click opens or closes the window.
-- Not a Button: a button's padding does not fit the bar's 28 pixels (FeverLink3 saw buttons squashed there). The click is
-- caught as the game's own CheckBox catches it (useSelfRef + onMouseEvent), and the window is opened at the next step by tick
-- (where it has always been opened from). MPFEVER_BARICON=0: no icon, as before. MPFEVER_BARBUTTON=1: a flat button around
-- the icon catches the click instead. MPFEVER_BARFAIL=1 (tests): the icon fails to draw; =reg: it is not registered (an empty
-- recipe takes its place): the game's bar must still show.
U.BAR_COLOR = { grey = "NeutralLight", green = "Ok", yellow = "Warning", red = "Error" }
U.barInfo = function()
	local st = U.status
	local state, line = U.barState(st)
	local tip = { "MPFever  –  " .. tostring(line or "") }
	if st and st.started == "1" then
		tip[#tip + 1] = C.Tf("%s joueur(s) dans la partie", "%s player(s) in the game", playerCount(st))
		for _, pl in ipairs(st.players or {}) do
			if pl.state == "slow" and pl.role ~= "server" then tip[#tip + 1] = pl.name .. " : " .. C.Tf("%s pas de retard", "%s steps behind", pl.lag) end
		end
	end
	tip[#tip + 1] = T("Clic : ouvrir ou fermer la fenêtre", "Click: open or close the window")
	return state, table.concat(tip, "  ·  ")
end
U.barNode = function()
	if os.getenv("MPFEVER_BARFAIL") == "1" then error("MPFEVER_BARFAIL=1 (test)") end
	local K = U.kit
	local builtin = K.builtin
	local state, tip = U.barInfo()
	local unread = U.chatUnread or 0
	local inner = builtin.BoxLayout { orientation = K.H, children = {
		-- (the disc a little lower: in the middle of the bar's text)
		builtin.BoxLayout { orientation = K.V, children = { K.gap(1, 7), K.disc(U.BAR_COLOR[state] or "NeutralLight", 14) } },
		K.gap(6, 1),
		builtin.TextView { meta = { class = "font-scale-headline" }, text = "MPFever" .. (unread > 0 and ("  (" .. unread .. ")") or "") },
	} }
	-- (MPFEVER_BARBUTTON=1, should the bar's row not pass the clicks to the icon: a flat button around it instead)
	local item
	if os.getenv("MPFEVER_BARBUTTON") == "1" then
		item = builtin.Button { meta = { class = "secondary", tooltip = tip, styleSheet = K.style { padding = { 0, 4, 0, 4 } } }, content = builtin.Component { layout = inner },
			onClick = function() U.barClick = true end }
	else
		item = builtin.Component { meta = { tooltip = tip }, layout = inner }
	end
	return builtin.BoxLayout { orientation = K.H, children = { item, K.gap(18, 1) } }
end
-- a left click on the icon: pressed and released on it (as the game's CheckBox); the window is toggled by tick
U.barMouse = function(selfRef, evt)
	if evt.button ~= 0 or os.getenv("MPFEVER_BARBUTTON") == "1" then return false end
	local node = selfRef:get()
	if not node then return false end
	local inside = node:containsPosition(api.type.Vec2i.new(evt.x, evt.y))
	local types = api.gui.mouse.Event.Type
	if evt.type == types.Pressed then
		if inside then
			U.barPressed = true
			pcall(function() node:setSelectedRecursive(true) end)
			return true
		end
	elseif evt.type == types.Released then
		local pressed = U.barPressed
		U.barPressed = false
		pcall(function() node:setSelectedRecursive(false) end)
		if inside and pressed then
			U.barClick = true
			return true
		end
	elseif evt.type == types.Clicked then
		return inside
	end
	return false
end
U.barFn = function()
	local react, builtin = U.react, U.builtin
	-- (read once: the same hooks on every render)
	if U.barOn == nil then U.barOn = C.ACTIVE and os.getenv("MPFEVER_BARICON") ~= "0" and U.kit ~= nil end
	if not U.barOn then return builtin.BoxLayout { children = {} } end
	local key = react.useState("")
	react.onStepTimer(function()
		local okI, state, tip = pcall(U.barInfo)
		local k = okI and (tostring(state) .. "|" .. tostring(tip) .. "|" .. tostring(U.chatUnread or 0)) or "?"
		if key:old() ~= k then key:set(k) end
	end, 0.5)
	local selfRef = react.useSelfRef()
	react.onMouseEvent(function(evt)
		local ok, r = pcall(U.barMouse, selfRef, evt)
		return ok and r == true
	end)
	local ok, node = pcall(U.barNode)
	if ok and node then return node end
	if not U.barFailLogged then U.barFailLogged = true; log("bar: icon not drawn: " .. tostring(node)) end
	return builtin.BoxLayout { children = {} }
end


local function installSession(react, builtin)
	if U.sessionInstalled then return end
	U.sessionInstalled = true
	-- (the drawing helpers of the window and the bar's icon, see U.makeKit)
	local K = U.kit or U.makeKit(builtin)
	U.kit = K
	local V, H = K.V, K.H
	local text, color, classColor, style, dot, icon, row, muted = K.text, K.color, K.classColor, K.style, K.dot, K.icon, K.row, K.muted
	local ICON_PLAYERS, ICON_SYNC, ICON_PERSON, ICON_CHAT = K.ICON_PLAYERS, K.ICON_SYNC, K.ICON_PERSON, K.ICON_CHAT
	local function section(path, title) return row { icon(path, 26), text("  " .. title, "font-scale-title-4") } end
	-- MPFever's window: the tabbed one (U.installNewWindow); MPFEVER_NEWWINDOW=0: the single list of before, below (its width
	-- set with - and +, the chat in a window of its own)
	U.newWindow = os.getenv("MPFEVER_NEWWINDOW") ~= "0"

	-- MPFever's window: stays open while playing, can be moved and closed
	U.ListWindow = react.RegisterWrapperRecipe("MPFeverListWindow", builtin.Window, function(wp)
		local st = useStatus(react)
		-- reduced to one small card (issue #68): the sync, the players and the chat, kept for the session
		local small = react.useState(U.sessionSmall == true)
		-- its width, adjustable by steps (the game's windows cannot be resized with the mouse), kept for the session
		-- (every state before the reduced card's early return: the same hooks on every render)
		local width = react.useState(U.sessionWidth or 540)
		-- the amount typed for a gift to another company (companies mode)
		local giveAmount = react.useState("")
		local giveGen = react.useState(0)
		local function toggle()
			U.sessionSmall = not small:old()
			small:set(U.sessionSmall)
		end
		if small:old() then
			local sync, syncCls = syncLine(st)
			local link, linkCls = linkLine(st)
			local mini = {}
			if link and linkCls ~= "success" then mini[#mini + 1] = row { dot(linkCls), text("  " .. link, nil, linkCls) } end
			mini[#mini + 1] = row { dot(syncCls), text("  " .. sync, nil, syncCls) }
			mini[#mini + 1] = row { icon(ICON_PLAYERS, 22), text("  " .. T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")") }
			mini[#mini + 1] = row {
				builtin.Button { meta = { class = "secondary" }, content = icon(ICON_CHAT, 22), onClick = function() if U.openChat then U.openChat() end end },
				text("  "),
				builtin.Button { meta = { class = "secondary" }, content = text(T("Agrandir", "Expand")), onClick = toggle },
			}
			return builtin.Window {
				title = "MPFever",
				id = "window.mpfever.session",
				initialX = 0.98,
				initialY = 0.12,
				movable = true,
				closable = true,
				onClose = wp.onClose,
				content = builtin.Component { meta = { styleSheet = style { size = { 280, -1 } } }, layout = builtin.BoxLayout { orientation = V, children = mini } },
			}
		end
		local rows = {}
		local function widen(d)
			local w = math.max(400, math.min(900, width:old() + d))
			U.sessionWidth = w
			width:set(w)
		end
		rows[#rows + 1] = row {
			builtin.Button { meta = { class = "secondary" }, content = text(T("Réduire", "Reduce")), onClick = toggle },
			text("  "),
			builtin.Button { meta = { class = "secondary", tooltip = T("Plus étroite", "Narrower") }, content = text("  -  "), onClick = function() widen(-80) end },
			text(" "),
			builtin.Button { meta = { class = "secondary", tooltip = T("Plus large", "Wider") }, content = text("  +  "), onClick = function() widen(80) end },
		}
		if st and st.host then
			-- (a dedicated server: its name as its settings write it)
			local hostText = st.server == "1" and C.Tf("Serveur dédié : %s", "Dedicated server: %s", (st.title and st.title ~= "") and st.title or st.host)
				or C.Tf("Hôte : %s", "Host: %s", st.host)
			rows[#rows + 1] = muted(hostText .. "  ·  "
				.. (st.mode == "separate" and T("Une entreprise par joueur", "One company per player") or T("Une entreprise pour tous", "One company for everybody")))
		end
		local link, linkCls = linkLine(st)
		if link then rows[#rows + 1] = row { dot(linkCls), text("  " .. link, nil, linkCls) } end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = section(ICON_SYNC, T("Synchronisation", "Sync"))
		local sync, syncCls = syncLine(st)
		rows[#rows + 1] = row { dot(syncCls), text("  " .. sync, nil, syncCls) }
		local desyncs = tonumber(st and st.desyncs) or 0
		if desyncs > 0 then rows[#rows + 1] = muted(C.Tf("%s désynchronisation(s) depuis le début", "%s desync(s) since the start", desyncs)) end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = section(ICON_PLAYERS, T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")")
		for _, pl in ipairs(st and st.players or {}) do
			if pl.role ~= "server" then
				local line, cls = playerLine(pl, st.me)
				rows[#rows + 1] = row { icon(ICON_PERSON, 22), text("  " .. line, nil, cls) }
			end
		end
		if st and st.mode == "separate" and U.coMap then
			local okC, cr = pcall(U.companyRows, { row = row, text = text, muted = muted, section = section, icon = icon, style = style,
				color = color, builtin = builtin, amount = giveAmount, gen = giveGen, ICON_PLAYERS = ICON_PLAYERS })
			if okC and cr then for _, r in ipairs(cr) do rows[#rows + 1] = r end
			elseif not okC then log("companies: the companies' table failed: " .. tostring(cr)) end
		end
		if st and st.invite == "1" and st.me and st.players then
			local host = false
			for _, pl in ipairs(st.players) do if pl.id == st.me and pl.role == "host" then host = true end end
			if host then
				rows[#rows + 1] = text(" ")
				rows[#rows + 1] = builtin.Button { meta = { class = "primary" }, content = text(T("Inviter des amis Steam", "Invite Steam friends")), onClick = requestInvite }
			end
		end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = builtin.Button { meta = { class = "secondary" }, content = row { icon(ICON_CHAT, 22), text("  " .. T("Ouvrir la discussion", "Open the chat")) },
			onClick = function() if U.openChat then U.openChat() end end }
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = builtin.Button { meta = { class = "secondary" }, content = text(U.reportLabel()), onClick = requestReport }
		if U.reportMsg and U.reportAsked and os.time() - U.reportAsked <= 120 then rows[#rows + 1] = muted(U.reportMsg) end
		return builtin.Window {
			title = "MPFever – " .. T("Multijoueur", "Multiplayer"),
			id = "window.mpfever.session",
			initialX = 0.85,
			initialY = 0.3,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			-- wide enough for the title and the longest lines (the window takes its content's size)
			pinnable = true,
			content = builtin.Component { meta = { styleSheet = style { size = { width:old(), -1 } } }, layout = builtin.BoxLayout { orientation = V, children = rows } },
		}
	end)
	if U.newWindow then U.installNewWindow(react, builtin) else U.SessionWindow = U.ListWindow end
	log("session: MPFever's window " .. (U.newWindow and "with tabs" or "as a single list (MPFEVER_NEWWINDOW=0)"))
	-- (0.6) the Hub, with the tabbed window only; MPFEVER_HUB=0: none
	if U.newWindow and U.hubOn() then
		local okH, errH = pcall(U.installHub, react, builtin)
		log("session: " .. (okH and "the Hub installed (the small window is a quick view)" or ("the Hub not installed: " .. tostring(errH))))
	else
		log("session: no Hub" .. (U.hubOff and " (MPFEVER_HUB=0)" or ""))
	end

	-- ------------------------------------------------ the chat window and the short notice of new messages
	-- (the chat window: the single-list window's; the tabbed window has a Chat tab instead)
	local function hhmm(t)
		local ok, s = pcall(os.date, "%H:%M", t)
		return ok and s or ""
	end
	local function nameColor(name)
		return color(name == myChatName() and "Ok" or "Info")
	end
	local function coloredText(t, c, class)
		return builtin.TextView { meta = { class = class or "font-scale-body", styleSheet = style { color = c } }, text = t }
	end

	-- one chat line: time, player, text (long texts on several lines)
	local function chatRows(m, out, width)
		local time = hhmm(m.t)
		if m.kind == "join" then
			out[#out + 1] = muted(time .. "   " .. C.Tf("%s a rejoint la partie", "%s joined the game", m.name))
		elseif m.kind == "left" then
			out[#out + 1] = muted(time .. "   " .. C.Tf("%s a quitté la partie", "%s left the game", m.name))
		elseif m.kind == "away" then
			out[#out + 1] = muted(time .. "   " .. C.Tf("%s a perdu la connexion : la partie l'attend", "%s lost the connection: the game waits for them", m.name))
		elseif m.kind == "back" then
			out[#out + 1] = muted(time .. "   " .. C.Tf("%s est de retour : la partie continue", "%s is back: the game goes on", m.name))
		elseif m.kind == "unsent" then
			out[#out + 1] = row { muted(time .. "   "), text(T("Non envoyé (pas de connexion à l'hôte) : ", "Not sent (no connection to the host): ") .. m.text, nil, "error") }
		else
			local head = m.name .. ":  "
			local lines = wrap(m.text, math.max(10, width - ulen(head)), width)
			out[#out + 1] = row { muted(time .. "   "), coloredText(head, nameColor(m.name)), text(lines[1]) }
			for i = 2, #lines do out[#out + 1] = row { muted("              "), text(lines[i]) } end
		end
	end

	U.ChatWindow = react.RegisterWrapperRecipe("MPFeverChatWindow", builtin.Window, function(wp)
		local chat = useChat(react)
		local draft = react.useState("")
		local gen = react.useState(0)   -- a new input field after each message (an empty one)
		local rows = {}
		local first = math.max(1, #chat - 13)
		if #chat == 0 then rows[#rows + 1] = muted(T("Aucun message pour l'instant.", "No messages yet.")) end
		for i = first, #chat do chatRows(chat[i], rows, 52) end
		rows[#rows + 1] = text(" ")
		local function send(v)
			if sendChat(v) then
				draft:set("")
				gen:set(gen:old() + 1)
			end
		end
		rows[#rows + 1] = row {
			builtin.TextInputField {
				meta = { class = "font-scale-body", localKey = "mpfever-chat-input-" .. tostring(gen:old()), styleSheet = style { size = { 420, -1 } } },
				value = "",
				placeholderText = T("Écrire un message…", "Write a message…"),
				maxLength = 300,
				acceptOnFocusLoss = false,
				onTyping = function(v) draft:set(v or "") end,
				onValueChange = function(v) send(v) end,
			},
			text("  "),
			builtin.Button { meta = { class = "primary" }, content = text(T("Envoyer", "Send")), onClick = function() send(draft:old()) end },
		}
		return builtin.Window {
			title = "MPFever – " .. T("Discussion", "Chat"),
			id = "window.mpfever.chat",
			initialX = 0.02,
			initialY = 0.45,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			content = (U.kit and U.kit.padded or function(c) return c end)(builtin.Component { meta = { styleSheet = style { size = { 560, -1 } } }, layout = builtin.BoxLayout { orientation = V, children = rows } }),
		}
	end)

	-- the notice: the new messages for a few seconds at the left of the screen (no button: it closes by itself)
	U.ChatToast = react.RegisterWrapperRecipe("MPFeverChatToast", builtin.Window, function(wp)
		local ver = react.useState(U.toastVersion or 0)
		react.onStepTimer(function()
			local v = U.toastVersion or 0
			if ver:old() ~= v then ver:set(v) end
			if U.toastShown and (U.chatOpen or os.time() >= (U.toastUntil or 0)) then
				U.toastShown = false
				pcall(function() wp.windowApi.removeAllWindows(U.ChatToast) end)
			end
		end, 0.5)
		local rows = {
			row { icon(ICON_CHAT, 22), coloredText("  MPFever – " .. T("Discussion", "Chat"), color("NeutralLight")) },
		}
		for _, m in ipairs(U.toastItems or {}) do
			local t = m.text
			if ulen(t) > 70 then t = usub(t, 68) .. "…" end
			rows[#rows + 1] = row { coloredText(m.name .. ":  ", nameColor(m.name)), text(t) }
		end
		-- (where to answer: the bar's icon opens the window, its Chat tab; else the pause menu's chat card)
		if U.newWindow and U.barOn then
			rows[#rows + 1] = muted(T("Répondre : MPFever (barre du bas)  ›  Chat", "Reply: MPFever (bottom bar)  ›  Chat"))
		else
			rows[#rows + 1] = muted(T("Répondre : Échap  ›  Discussion", "Reply: Esc  ›  Chat"))
		end
		return builtin.Window {
			title = "",
			id = "window.mpfever.chattoast",
			initialX = 0.005,
			initialY = 0.1,
			movable = false,
			closable = false,
			pinnable = false,
			compact = true,
			autoFocusOnBecomingVisible = false,
			onClose = function() end,
			content = builtin.Component {
				mouseTransparent = true,
				meta = { styleSheet = style { size = { 520, -1 } } },
				layout = builtin.BoxLayout { orientation = V, children = rows },
			},
		}
	end)

	U.onChatNews = function(news)
		local items = U.toastItems or {}
		if not U.toastShown then items = {} end
		for _, m in ipairs(news) do items[#items + 1] = m end
		while #items > 3 do table.remove(items, 1) end
		U.toastItems = items
		U.toastUntil = os.time() + 8
		U.toastVersion = (U.toastVersion or 0) + 1
		if U.toastShown then return end
		local wapi = defaultWindowApi()
		if not wapi then return end
		local ok, err = pcall(function() wapi.addSingletonWindow(U.ChatToast, { windowApi = wapi }) end)
		if ok then U.toastShown = true else log("chat: notice not shown: " .. tostring(err)) end
	end

	-- the chat window, from the pause menu (its window container) or from MPFever's window (the game's own)
	local function openChat(wapi)
		wapi = wapi or defaultWindowApi()
		if not wapi then log("chat: no window container") return false end
		local ok, err = pcall(function()
			wapi.addSingletonWindow(U.ChatWindow, {
				onClose = function()
					U.chatOpen = false
					pcall(function() wapi.removeAllWindows(U.ChatWindow) end)
				end,
			})
		end)
		if not ok then log("chat window not opened: " .. tostring(err)) return false end
		U.chatOpen = true
		U.chatUnread = 0
		if U.toastShown then
			U.toastShown = false
			pcall(function() wapi.removeAllWindows(U.ChatToast) end)
		end
		return true
	end
	-- (the tabbed window: its Chat tab)
	U.openChat = U.newWindow and function() return U.openWindow("chat") end or openChat

	-- MPFever's window from a card of the pause menu (on its Session or Chat tab), then back to the game: the window stays open
	-- (the single-list window's chat: its own window, as before)
	local function openFromCard(commonParams, tab)
		local wapi = nil
		pcall(function() wapi = commonParams.windowContainer:get():getApi() end)
		local ok
		if tab == "chat" and not U.newWindow then ok = openChat(wapi)
		else
			-- (the Chat card shows the chat, also when the window was reduced to its small card)
			if tab == "chat" and U.compact then pcall(U.setCompact, false) end
			ok = U.openWindow(tab, wapi)
		end
		if ok then pcall(commonParams.onClose) else log("session window not opened from the pause menu") end
	end

	-- the card in the pause menu: drawn as the menu's own cards (classes of the pause page: dark card, shadow,
	-- accent on hover), with an icon, a summary, and a click opens the window
	local CARD_NINE = { 0, 16, 48, 64 }   -- main_menu_sizes.ninePatchHorizontal/Vertical
	local Card = react.RegisterRecipe("MPFeverPauseCard", function(p)
		local st = useStatus(react)
		local hover = react.useState(false)
		local sync, syncCls = syncLine(st)
		local link, linkCls = linkLine(st)
		local status, cls = link or sync, link and linkCls or syncCls
		local info = builtin.BoxLayout { orientation = V, children = {
			text("MPFever  –  " .. T("Multijoueur", "Multiplayer"), "font-scale-title-4"),
			row { dot(cls), builtin.TextView { meta = { class = "font-scale-body" .. (cls and (", " .. cls) or ""), styleSheet = style { color = classColor(cls) } }, text = "  " .. status } },
			muted(C.Tf("%s joueur(s) dans la partie", "%s player(s) in the game", playerCount(st)) .. "   ·   " .. T("Afficher pendant la partie  ›", "Show while playing  ›")),
		} }
		-- a recipe's result must be a layout (the game refuses a bare button here)
		return builtin.BoxLayout { children = {
			builtin.Button {
				-- the menu card's look, set here: the pause page's CSS does not reach the card (background,
				-- colour 90 % opaque as the game's cards, accent colour under the mouse)
				meta = {
					class = "burger-menu, top-right, ani-pulse",
					styleSheet = style { size = { 600, 112 }, image = "::/gui/menu/design/main_menu_card_top_right_content_mask.tga", nine = CARD_NINE,
						bg = color(hover:old() and "AccentVeryDark" or "BaseDarkMedium", 0.9) },
					onMouseOver = function(h) if hover:old() ~= (h and true or false) then hover:set(h and true or false) end end,
				},
				content = builtin.Component { layout = builtin.BoxLayout { orientation = H, children = {
					builtin.Component { meta = { styleSheet = style { size = { 84, -1 } } }, layout = builtin.BoxLayout { children = { builtin.ImageView { path = ICON_PLAYERS } } } },
					builtin.Component { layout = info },
				} } },
				onClick = function() openFromCard(p.commonParams, "session") end,
			},
		} }
	end)

	-- the chat's card, under MPFever's card: the new messages, and a click opens the chat
	local ChatCard = react.RegisterRecipe("MPFeverChatCard", function(p)
		useChat(react)
		local hover = react.useState(false)
		local unread = U.chatUnread or 0
		local info = builtin.BoxLayout { orientation = V, children = {
			text(T("Discussion", "Chat"), "font-scale-title-4"),
			unread > 0 and coloredText(C.Tf("%s nouveau(x) message(s)  ›", "%s new message(s)  ›", unread), color("Info"))
				or muted(T("Écrire aux autres joueurs  ›", "Write to the other players  ›")),
		} }
		return builtin.BoxLayout { children = {
			builtin.Button {
				meta = {
					class = "burger-menu, bottom-left, ani-pulse",
					styleSheet = style { size = { 600, 88 }, image = "::/gui/menu/design/main_menu_card_bottom_left_content_mask.tga", nine = CARD_NINE,
						bg = color(hover:old() and "AccentVeryDark" or "BaseDarkMedium", 0.9) },
					onMouseOver = function(h) if hover:old() ~= (h and true or false) then hover:set(h and true or false) end end,
				},
				content = builtin.Component { layout = builtin.BoxLayout { orientation = H, children = {
					builtin.Component { meta = { styleSheet = style { size = { 84, -1 } } }, layout = builtin.BoxLayout { children = { builtin.ImageView { path = ICON_CHAT } } } },
					builtin.Component { layout = info },
				} } },
				onClick = function() openFromCard(p.commonParams, "chat") end,
			},
		} }
	end)

	-- the pause menu's main page is wrapped: drawn as usual, with the card floating at its right
	-- (the game's UI state has no rawget, and maybe no debug library: every step is guarded)
	local okR, rr = pcall(function() return _react end)
	if not (okR and type(rr) == "table" and type(rr.recipeReplace) == "table" and type(rr.originalRecipeFn) == "table") then
		log("session: the pause menu cannot be extended (no _react)")
		return
	end
	local id, how = nil, nil
	-- 0. the id caught while the page registered (mpfever_pause.lua, loaded by the native module in front of pause_menu.tl)
	local okP, pid = pcall(function() return package.loaded["mpfever_pause_id"] end)
	if okP and pid ~= nil and rr.originalRecipeFn[pid] then id, how = pid, "native hook" end
	-- 1. the recipe's id from react.lua's own table of names (the only upvalue of GetRecipeName): no side effect
	local okD, dbg = pcall(function() return debug end)
	if id then
		-- found
	elseif okD and type(dbg) == "table" and type(dbg.getupvalue) == "function" and type(react.GetRecipeName) == "function" then
		for i = 1, 8 do
			local okU, name, names = pcall(dbg.getupvalue, react.GetRecipeName, i)
			if not okU or name == nil then break end
			if type(names) == "table" then
				for fn, n in pairs(names) do
					if n == "PauseMainPage" then
						local okI, rid = pcall(react.GetRecipeId, fn)
						if okI and rid ~= nil and rr.originalRecipeFn[rid] then id, how = rid, "names table" end
					end
				end
			end
			if id then break end
		end
	else
		log("session: no debug library in the UI state")
	end
	-- 2. the id the engine gives the name, only when it is the id of an existing recipe (ids given per name)
	if not id then
		local okM, rid = pcall(function() return api.gui.react.detail.makeRecipeId("PauseMainPage") end)
		if okM and rid ~= nil and rr.originalRecipeFn[rid] then id, how = rid, "recipe name" end
	end
	if not id then
		log("session: the pause menu's page was not found: MPFever's window cannot be opened in game")
		return
	end
	local original = rr.originalRecipeFn[id]
	rr.recipeReplace[id] = function(params, ...)
		if not C.ACTIVE then return original(params, ...) end
		return builtin.FloatingLayout {
			children = {
				builtin.FloatingLayoutChild { h = -1, v = -1, item = builtin.Component { mouseTransparent = true, layout = builtin.BoxLayout { children = { original(params, ...) } } } },
				builtin.FloatingLayoutChild { h = 0.97, v = 0.5, item = builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = {
					Card { commonParams = params and params.commonParams },
					builtin.Component { meta = { styleSheet = style { size = { 600, 12 } } } },
					ChatCard { commonParams = params and params.commonParams },
				} } },
			},
		}
	end
	log("session: MPFever's card added to the pause menu (page found by " .. tostring(how) .. ")")
end

-- (0.7.13, #148: a purchase the engine refused, most often because the buying company had less money than the price when it
-- was applied, was said nowhere: the store's purchase showed nothing, the line manager's clone the game's own words seconds later,
-- and the players took it for an MPFever fault. The buyer is now told, on the chat's notice: two short items, the notice cuts a
-- line at 70 characters. r: the result of one of this player's purchases (why = "money", price, balance, tollFee: see C.buyWhy in
-- the bridge). nil when there is nothing to say. MPFEVER_BUYMONEY=0: nothing said, as in 0.7.12)
U.buyRefusedText = function(r)
	if os.getenv("MPFEVER_BUYMONEY") == "0" or type(r) ~= "table" or r.fn ~= "makeVehicleBuyCmd" or r.success == true then return nil end
	if r.why == "money" and type(r.price) == "number" and type(r.balance) == "number" then
		return { { kind = "msg", name = "MPFever", text = T("Achat refusé : pas assez d'argent.", "Purchase refused: not enough money.") },
			{ kind = "msg", name = "MPFever", text = C.Tf("Prix %s, votre entreprise a %s.", "Price %s, your company has %s.",
				money(r.price + (tonumber(r.tollFee) or tonumber(r.toll) or 0)), money(r.balance)) } }
	end
	-- (the general item only for the engine's refusal: its answer in a pause (no err) or nothing made in the steps after it
	-- ("created entity not found"). A purchase MPFever itself refused (another company's depot, entities missing here, a game
	-- option...) was not the game's: nothing said of it, as in 0.7.12; its reason is in mod.log)
	if r.err ~= nil and r.err ~= "created entity not found" then return nil end
	return { { kind = "msg", name = "MPFever", text = T("Achat refusé par le jeu : aucun véhicule créé.", "Purchase refused by the game: no vehicle made.") } }
end
U.buyRefusedShow = function(r)
	local items = U.buyRefusedText(r)
	if not items then return end
	if U.onChatNews then pcall(U.onChatNews, items) end
	log("purchase refused shown: " .. tostring(r.why or "no vehicle") .. " price " .. tostring(r.price) .. " company " .. tostring(r.balance))
end

-- (0.7.16, issue #181: with one company per player, a vehicle of another company recoloured three times in 17 s, each refused on
-- every game by the owner guard, "it belongs to company 2 (Firma Simon)", and nothing said to the player) The player whose own
-- command touched another company's vehicle, line, depot or station is told on the chat's notice, with that company's name (the
-- notice cuts a line at 70 characters: the name cut at 24). r: the result of one of this player's commands. nil when the refusal
-- is not the owner guard's. MPFEVER_OWNERNOTICE=0: nothing said, as in 0.7.15
U.ownerRefusedText = function(r)
	if os.getenv("MPFEVER_OWNERNOTICE") == "0" or type(r) ~= "table" or r.success == true or type(r.err) ~= "string" then return nil end
	local id, name = r.err:match("^it belongs to company (%S+)%s*%((.*)%)$")
	if not id then id = r.err:match("^it belongs to company (%S+)$") end
	if not id then return nil end
	local who = (type(name) == "string" and name ~= "") and name or ("#" .. id)
	-- (cut at a character's start: a last character of several bytes is left out whole)
	if #who > 24 then who = who:sub(1, 21):gsub("[\192-\255][\128-\191]*$", "") .. "..." end
	return { { kind = "msg", name = "MPFever", text = C.Tf("Refusé : appartient à une autre entreprise (%s).", "Refused: it belongs to another company (%s).", who) } }
end
U.ownerRefusedShow = function(r)
	local items = U.ownerRefusedText(r)
	if not items then return end
	if U.onChatNews then pcall(U.onChatNews, items) end
	log("owner refusal shown: " .. tostring(r.fn) .. " " .. tostring(r.err))
end

-- results of our own actions, written by the game-script bridge after the simulation applied them
local function pollResults()
	if not C.ACTIVE then return end
	local f = C.IO.open(C.DIR .. C.BS .. "results.log", "rb")
	if not f then return end
	local size = f:seek("end")
	-- (0.7.13: where results.log ended when this interface first read it; the autotests' purchases before it are not new, see below)
	if U.resStart == nil then U.resStart = size end
	if size > U.resOff then
		f:seek("set", U.resOff)
		local chunk = f:read(size - U.resOff) or ""
		local last, pos = nil, 1
		while true do
			local i = chunk:find(C.NL, pos, true)
			if not i then break end
			last = i
			local line = chunk:sub(pos, i - 1)
			local lineAt = U.resOff + pos - 1
			pos = i + 1
			local payload = line:match("^result" .. C.TAB .. "[^" .. C.TAB .. "]*" .. C.TAB .. "(.*)$")
			local r = payload and C.deser(payload)
			if r and r.tok == U.tok and U.pending[r.id] then
				local p = U.pending[r.id]
				U.pending[r.id] = nil
				U.stats.answered = U.stats.answered + 1
				local data = type(r.data) == "table" and C.plain(r.data) or nil
				local entities = type(r.entities) == "table" and C.plain(r.entities) or {}
				-- (a mod's next command from this callback is automatic when the first one was, see U.autoFacts)
				local prevCb = U.cbAuto
				U.cbAuto = p.auto == true
				local okc, errc = pcall(p.cb, data, r.success == true, entities)
				U.cbAuto = prevCb
				log("result #" .. tostring(r.id) .. " " .. tostring(p.name) .. " success=" .. tostring(r.success) .. " after " .. string.format("%.2f", os.clock() - p.t0) .. "s" .. (okc and "" or (" (callback error: " .. tostring(errc):sub(1, 160) .. ")")))
				-- (0.7.13, #148: a refused purchase, its buyer told, see U.buyRefusedText; only here, so a results.log read again
				-- from its start after a reload tells nothing twice)
				if r.fn == "makeVehicleBuyCmd" and r.success ~= true then pcall(U.buyRefusedShow, r) end
				-- (0.7.16, #181: a command on another company's vehicle, line, depot or station, refused by the owner guard)
				if r.success ~= true then pcall(U.ownerRefusedShow, r) end
			elseif r and r.fn == "makeVehicleBuyCmd" and r.success ~= true and os.getenv("MPFEVER_SCENARIO")
				and r.tok == "auto-" .. tostring(C.ROLE) and lineAt >= (U.resStart or 0) then
				-- (the autotests' purchases, sent through ui.log without a callback here: the same notice, see H.buypoor)
				pcall(U.buyRefusedShow, r)
			end
		end
		if last then U.resOff = U.resOff + last end
	end
	f:close()
end

local M = {}

M.doReplace = function(replacementApi)
	if not C.ACTIVE then return end
	local ok, err = pcall(install)
	if not ok then log("UI interception FAILED: " .. tostring(err)) end
end

-- MPFever panel, mounted on the game's mod entry point for the whole game. It gives the UI state a periodic hook
-- (results of our own actions and entity bindings).
local function readPending()
	local f = C.IO.open(C.DIR .. C.BS .. "pending_build.txt", "rb")
	if not f then return "" end
	local s = f:read("*a") or ""
	f:close()
	return s
end

local function pollBindings()
	local f = C.IO.open(C.DIR .. C.BS .. "bindings.log", "rb")
	if not f then return end
	local size = f:seek("end")
	if size > U.bindOff then
		f:seek("set", U.bindOff)
		local chunk = f:read(size - U.bindOff) or ""
		local consumed = 0
		for line in chunk:gmatch("([^" .. C.NL .. "]*)" .. C.NL) do
			consumed = consumed + #line + 1
			local key, e = line:match("^(%S+) (%-?%d+)")
			if key == "RESET" then U.rev = {}; U.byKey = {}
			elseif key then
				-- (a key bound again: the entity it named before loses it, issue #53)
				local n = tonumber(e)
				U.byKey = U.byKey or {}
				local old = U.byKey[key]
				if old and old ~= n and U.rev[old] == key then U.rev[old] = nil end
				U.byKey[key] = n
				U.rev[n] = key
			end
		end
		U.bindOff = U.bindOff + consumed
	end
	f:close()
end

-- ---------------------------------------------------------------- resynchronisation by the host's savegame
-- The launcher pauses every game, asks the host to save (resync_save), sends the file to the other players and asks
-- them to load it (resync_load). Saving and loading are application functions, available in this UI state.

local function findSave(name)
	local ns = app.SaveGameNamespace.getSavegame()
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == name then
			local id = api.type.SavegameId.new()
			id.path = s.path
			id.saveGameName = s.saveName
			id.saveGameNamespace = ns
			return id
		end
	end
	return nil
end

local function resyncSave(p)
	log("resynchronisation: saving the game as '" .. tostring(p.name) .. "'")
	local ok, err = pcall(app.saveGame, p.name, function()
		log("resynchronisation: game saved")
		sendLine("save_done", { id = p.id, name = p.name, ok = true })
	end, false, true)
	if not ok then
		log("resynchronisation: save failed: " .. tostring(err))
		sendLine("save_done", { id = p.id, name = p.name, ok = false, err = tostring(err) })
	end
end

local function resyncLoad(p)
	local id = findSave(p.name)
	if not id then
		log("resynchronisation: savegame '" .. tostring(p.name) .. "' not found")
		return
	end
	-- the application script starts the loaded game by itself (no "press a key" screen)
	C.appendFile(C.DIR .. C.BS .. "resync_pending.txt", "1")
	log("resynchronisation: loading the host's game '" .. tostring(p.name) .. "'")
	-- (with this player's personal mods: see C.loadWithPlan)
	C.loadWithPlan(id, log, function(fn) U.later = U.later or {}; U.later[#U.later + 1] = fn end)
end

local function pollControl()
	if U.later and #U.later > 0 then
		local fns = U.later
		U.later = {}
		for _, fn in ipairs(fns) do
			local ok, err = pcall(fn)
			if not ok then log("load: " .. tostring(err)) end
		end
	end
	local f = C.keptOpen(C.DIR .. C.BS .. "in.log")
	if not f then return end
	local size = f:seek("end")
	if U.ctlOff == nil or size < U.ctlOff then
		-- messages from before this UI started are not for it
		U.ctlOff = size
		return
	end
	if size > U.ctlOff then
		f:seek("set", U.ctlOff)
		local chunk = f:read(size - U.ctlOff) or ""
		local consumed = 0
		for line in chunk:gmatch("([^" .. C.NL .. "]*)" .. C.NL) do
			consumed = consumed + #line + 1
			local kind, payload = line:match("^([^" .. C.TAB .. "]*)" .. C.TAB .. "[^" .. C.TAB .. "]*" .. C.TAB .. "(.*)$")
			if kind == "resync_save" or kind == "resync_load" then
				-- the game script bridge may handle it first (it runs every frame, even paused): wait for its claim
				U.resyncQueue = U.resyncQueue or {}
				U.resyncQueue[#U.resyncQueue + 1] = { kind = kind, p = C.deser(payload) or {}, t = os.clock() }
			elseif kind == "notiftest" then
				local okt, errt = pcall(N.test, C.deser(payload) or {})
				if not okt then log("NOTIFTEST failed: " .. tostring(errt)) end
			end
		end
		U.ctlOff = U.ctlOff + consumed
	end
	local keep = {}
	for _, r in ipairs(U.resyncQueue or {}) do
		if os.clock() - r.t < 1.5 then
			keep[#keep + 1] = r
		else
			local claims = ""
			local cf = C.IO.open(C.DIR .. C.BS .. "resync_claims.txt", "rb")
			if cf then claims = cf:read("*a") or ""; cf:close() end
			if not claims:find(r.kind .. " " .. tostring(r.p.id) .. C.NL, 1, true) then
				C.appendFile(C.DIR .. C.BS .. "resync_claims.txt", r.kind .. " " .. tostring(r.p.id) .. C.NL)
				local ok, err = pcall(r.kind == "resync_save" and resyncSave or resyncLoad, r.p)
				if not ok then log(r.kind .. " failed: " .. tostring(err)) end
			end
		end
	end
	U.resyncQueue = keep
end

-- ---------------------------------------------------------------- notifications kept across reloads
-- At every resynchronisation each game loads the host's savegame, and with it the host's notification list (the game script
-- notifications.gs): the notifications this player dismissed since the last load come back, again and again. Dismissing is a
-- local event (see the hook: each game's own interface), so this player's choices are kept here instead, in the session
-- folder (notif_dismissed.txt, never in a savegame nor in a message), and made again after every load with the same local
-- event a right-click sends. A notification is known by its content, not by its id (each game numbers its own entries):
-- a one-shot one (a new industry, a town's wish...) also by its time, within two game minutes (the host's copy of an entry the
-- interface created has the host's time), a persistent one (warnings, contract cards) by what it stands for, without time.
-- The filter of the notification log (updateIgnoredTypes) is kept the same way. notifications.gs is not among the parts the
-- games compare, and nothing in the simulation reads it: none of this can make the games differ.
-- Also logged, to find why a client sometimes misses an "Industry Founded" notification (made by each game's own interface,
-- not by the simulation): every new notification (type, time, whether it came in dismissed) and every new industry.
N.file = "notif_dismissed.txt"
N.TOLERANCE = 120000                -- (game time units: two game minutes)
N.done, N.seen, N.ind = {}, {}, nil   -- this load: ids dismissed again or by the player, ids looked at, industries known

-- the notification game script's state, as the game's own windows read it
function N.native()
	if N.util == nil then
		local okU, nu = pcall(ug_require, "/game_mechanics/notifications/notification_util.tl")
		N.util = (okU and type(nu) == "table") and nu or false
	end
	if not N.util then return nil end
	local okS, native = pcall(N.util.externalGetNotificationsStateNative)
	if okS then return native end
	return nil
end

function N.entry(native, id)
	local okE, e = pcall(N.util.getNotificationEntryFromNative, native, id)
	if okE and type(e) == "table" then return e end
	return nil
end

-- the same text for the same content on every game: keys sorted, an entity with its revision as the game compares it
-- (entityChanged0: the first number only), whole numbers with C.int (string.format "%d" fails from 2^31 in Lua 5.2 on
-- Windows: a contract card's uid is an entity times 10000), control bytes escaped (listed, not %c, see C.ser)
N.CONTROL = "[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. '"\\]'
function N.canon(v, depth)
	local t = type(v)
	if t == "number" then
		if v == math.floor(v) and math.abs(v) < 1e15 then return C.int(v) end
		return string.format("%.6g", v)
	elseif t == "string" then
		return '"' .. v:gsub(N.CONTROL, function(c) return string.format("\\%03d", c:byte()) end) .. '"'
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		if (depth or 0) > 8 then return "{...}" end
		if v.entity ~= nil and type(v.revision) == "table" and type(v.revision.num) == "table" then
			return "E" .. N.canon(v.entity) .. "@" .. N.canon(v.revision.num[1])
		end
		local ks = {}
		for k in pairs(v) do ks[#ks + 1] = k end
		table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(ks) do parts[#parts + 1] = tostring(k) .. "=" .. N.canon(v[k], (depth or 0) + 1) end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return t
end

-- key of an entry, and whether it is a one-shot one (matched with its time)
function N.key(entry)
	local n = entry and entry.notification
	if type(n) ~= "table" or type(n.type) ~= "string" then return nil end
	local body = n.type .. "|" .. N.canon(n.params)
	if type(entry.persisting) == "table" and next(entry.persisting) ~= nil then return "P|" .. N.canon(entry.persisting) .. "|" .. body, false end
	return "O|" .. body, true
end

-- what this player chose in this session (read once per load)
function N.load()
	if N.keys then return end
	N.keys = {}
	local f = C.IO.open(C.DIR .. C.BS .. N.file, "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local op, a, b = line:match("^(.)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "?(.*)$")
		if op == "+" then
			N.keys[a] = N.keys[a] or {}
			table.insert(N.keys[a], tonumber(b) or 0)
		elseif op == "-" then
			N.keys[a] = nil
		elseif op == "F" then
			N.filter = a
		end
	end
end

-- this player dismissed or brought back a notification, or changed the log's filter (the hook's local events; read before
-- the event changes the entry)
function N.record(ev, p)
	if ev ~= "dismiss" and ev ~= "enlist" and ev ~= "updateIgnoredTypes" then return end
	N.load()
	if ev == "updateIgnoredTypes" then
		local okS, s = pcall(function() return C.ser(C.marshal(p)) end)
		if okS and type(s) == "string" and not s:find("[" .. C.NL .. C.TAB .. "]") then
			N.filter = s
			C.appendFile(C.DIR .. C.BS .. N.file, "F" .. C.TAB .. s .. C.NL)
			log("notifications: the log's filter kept for the next loads")
		end
		return
	end
	local id = type(p) == "table" and tonumber(p.id) or nil
	local native = id and N.native()
	local entry = native and N.entry(native, id)
	local key, oneShot = N.key(entry)
	if not key or key:find("[" .. C.TAB .. C.NL .. "]") then return end
	if ev == "dismiss" then
		local t0 = oneShot and (tonumber(entry.timestamp) or 0) or 0
		N.keys[key] = N.keys[key] or {}
		table.insert(N.keys[key], t0)
		C.appendFile(C.DIR .. C.BS .. N.file, "+" .. C.TAB .. key .. C.TAB .. t0 .. C.NL)
	else
		N.keys[key] = nil
		C.appendFile(C.DIR .. C.BS .. N.file, "-" .. C.TAB .. key .. C.NL)
	end
	N.done[id] = true
	log("notifications: " .. ev .. " of " .. id .. " kept for the next loads (" .. key:sub(1, 160) .. ")")
end

-- is this entry one this player dismissed?
function N.dismissedBefore(entry)
	local key, oneShot = N.key(entry)
	local list = key and N.keys[key]
	if not list then return false end
	if not oneShot then return true end
	local t = tonumber(entry.timestamp) or 0
	for _, t0 in ipairs(list) do
		if math.abs(t - t0) <= N.TOLERANCE then return true end
	end
	return false
end

-- (0.6.5, #110) one company per player: the game's own "rank reached" notification is the savegame company's (the host's)
-- and the game shows it on every player's game; its button then asked a rank the local company had not reached ("company 3
-- has reached rank 0, not 3", six times in #109's logs: "only the host gets ranks"). Whether notification `n` is a rank
-- notification of another company than `me` (this game's player entity), when there are several companies (`many`).
-- MPFEVER_RANKNOTIF=0: shown, as before
function N.foreignRank(n, me, many)
	if not many or os.getenv("MPFEVER_RANKNOTIF") == "0" then return false end
	if type(n) ~= "table" or type(n.type) ~= "string" or not n.type:find("company_notification_rank_up", 1, true) then return false end
	local p = type(n.params) == "table" and n.params.companyEntity or nil
	if type(p) == "table" then p = p.entity end
	return type(p) == "number" and type(me) == "number" and p ~= me
end

-- periodic (tick): after a load, dismiss again what this player had dismissed and set the log's filter again; log new
-- notifications and new industries (the first look after a load only counts them)
function N.tick()
	local now = os.clock()
	if N.primed and N.at and now - N.at < 1 then return end
	N.at = now
	N.load()
	local native = N.native()
	if not native then return end
	local okH, history = pcall(N.util.getHistoryFromNative, native)
	if not okH or type(history) ~= "table" then return end
	local orig = C.origCmds()
	if not (orig.sendCommand and orig.event) then return end
	if N.filter and not N.filterDone then
		N.filterDone = true
		local f = C.deser(N.filter)
		if type(f) == "table" then
			pcall(function() orig.sendCommand(orig.event("", "Notifications", "updateIgnoredTypes", f)) end)
			log("notifications: the log's filter set again after the load")
		end
	end
	local again, fresh, foreign = 0, 0, 0
	local me, many = nil, U.coMap ~= nil and next(U.coMap) ~= nil
	if many then pcall(function() me = api.engine.util.getPlayer() end) end
	for _, id in ipairs(history) do
		if not N.seen[id] then
			local entry = N.entry(native, id)
			if entry then
				N.seen[id] = true
				fresh = fresh + 1
				if N.primed and (N.logs or 0) < 300 then
					N.logs = (N.logs or 0) + 1
					local n = entry.notification or {}
					log("notification new " .. id .. ": " .. tostring(n.type) .. " t=" .. tostring(entry.timestamp)
						.. (entry.dismissed and " (came in dismissed: filtered)" or "") .. " " .. N.canon(n.params):sub(1, 160))
				end
				if not entry.dismissed and not N.done[id] and N.dismissedBefore(entry) then
					N.done[id] = true
					pcall(function() orig.sendCommand(orig.event("", "Notifications", "dismiss", { id = id })) end)
					again = again + 1
				elseif not entry.dismissed and not N.done[id] and N.foreignRank(entry.notification, me, many) then
					N.done[id] = true
					pcall(function() orig.sendCommand(orig.event("", "Notifications", "dismiss", { id = id })) end)
					foreign = foreign + 1
				end
			end
		end
	end
	if foreign > 0 then log("notifications: " .. foreign .. " rank notification(s) of another company dismissed (see N.foreignRank)") end
	if not N.primed then
		N.primed = true
		log("notifications: " .. fresh .. " in the list after the load")
	end
	if again > 0 then log("notifications: " .. again .. " dismissed again as this player had dismissed them before the load") end
	-- new industries, every 5 s (the game's interface scans them every 5 s of game time for "Industry Founded")
	if N.indAt == nil or now - N.indAt >= 5 then
		N.indAt = now
		local list = {}
		pcall(function() api.engine.forEachEntityWithComponent(function(e) list[#list + 1] = e end, api.type.ComponentType.INDUSTRY) end)
		local first = N.ind == nil
		N.ind = N.ind or {}
		local t = nil
		pcall(function() t = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime end)
		for _, e in ipairs(list) do
			if not N.ind[e] then
				N.ind[e] = true
				if not first and (N.logs or 0) < 300 then
					N.logs = (N.logs or 0) + 1
					local con, built = nil, nil
					pcall(function()
						con = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY).construction
						built = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION).timeBuilt
					end)
					log("new industry " .. e .. ": construction " .. tostring(con) .. ", built at t=" .. tostring(built) .. ", seen at t=" .. tostring(t))
				end
			end
		end
		if first then log("industries: " .. #list .. " after the load") end
	end
end

-- autotest (MPFEVER_SCENARIO=notiftest,resync,notiftest,resync,notiftest): 1st message, host: three test notifications of
-- type industry_spawn (a local Notifications/add, as the interface sends it); 2nd, client (it has them from the host's savegame): dismissed the way
-- a right-click does; 3rd, both: how many of them are dismissed (client: all, again after the load; host: none)
function N.test(p)
	if type(p) ~= "table" or p.role ~= C.ROLE then return end
	local f = C.IO.open(C.DIR .. C.BS .. "notiftest_step.txt", "rb")
	local step = 1
	if f then step = (tonumber(f:read("*a")) or 0) + 1; f:close() end
	local fw = C.IO.open(C.DIR .. C.BS .. "notiftest_step.txt", "wb")
	if fw then fw:write(tostring(step)); fw:close() end
	local native = N.native()
	local orig = C.origCmds()
	local function tests()
		local list = {}
		local okH, history = pcall(N.util.getHistoryFromNative, native)
		for _, id in ipairs(okH and history or {}) do
			local e = N.entry(native, id)
			if e and type(e.notification) == "table" and type(e.notification.params) == "table" and e.notification.params.mpfTest then list[#list + 1] = { id = id, e = e } end
		end
		return list
	end
	if not native then log("NOTIFTEST step " .. step .. ": no notification state") return end
	if step == 1 and C.ROLE == "host" then
		local okE, eu = pcall(ug_require, "/scripts/entity_util.tl")
		local inds = {}
		pcall(function() api.engine.forEachEntityWithComponent(function(e) inds[#inds + 1] = e end, api.type.ComponentType.INDUSTRY) end)
		local made = 0
		for i = 1, math.min(3, #inds) do
			local er = okE and eu.makeEntityAndRevision(inds[i]) or nil
			if er then
				pcall(orig.sendCommand, orig.event("", "Notifications", "add", { type = "game_mechanics/notifications/types/industry_spawn.script",
					params = { entity = er, mpfTest = 1 }, autoDismissDuration = 3600000 }))
				made = made + 1
			end
		end
		log("NOTIFTEST step 1 (host): " .. made .. " test notifications added")
	elseif step == 2 and C.ROLE == "client" then
		local list = tests()
		for _, t in ipairs(list) do
			if not t.e.dismissed then
				-- (through the hooked function, as the notification window's right-click)
				api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "Notifications", "dismiss", { id = t.id }))
			end
		end
		log("NOTIFTEST step 2 (client): " .. #list .. " test notifications dismissed")
	else
		local list = tests()
		local d = 0
		for _, t in ipairs(list) do if t.e.dismissed then d = d + 1 end end
		log("NOTIFTEST step " .. step .. " (" .. C.ROLE .. "): " .. #list .. " test notifications, " .. d .. " dismissed")
	end
end

-- (0.8.6, #190) the « Company value » chart of the Finances window for this game's company (mpfever_valuechart.lua): installed at
-- the first tick, a new point looked for every 300 ticks
U.valueChart = function()
	if not U.vc then
		local ok, VC = pcall(ug_require, "mpfever_valuechart.lua")
		if not (ok and type(VC) == "table") then ok, VC = pcall(ug_require, "mpfever_1::/mpfever_valuechart.lua") end
		if not (ok and type(VC) == "table") then U.vc = { failed = true }; log("value chart: module not loaded: " .. tostring(VC)); return end
		U.vc = VC
		local function mine()
			if not U.coMap or not U.myCo then return nil end
			for e, id in pairs(U.coMap) do if id == U.myCo then return e end end
			return nil
		end
		VC.install({ log = log, io = C.IO, dir = (C.DIR:match("^(.*)[\\/][^\\/]+$") or C.DIR), mine = mine,
			canon = function() return U.canon end, separate = function() return U.coMap ~= nil and U.myCo ~= nil and next(U.coMap) ~= nil end })
	end
	if U.vc.failed then return end
	U.vcTicks = (U.vcTicks or 0) + 1
	if U.vcTicks % 300 == 1 then
		local ok, err = pcall(U.vc.poll)
		if not ok and not U.vcPollSaid then U.vcPollSaid = true; log("value chart: point not noted: " .. tostring(err):sub(1, 200)) end
	end
end

local function tick(pendingState)
	-- which company the interface acts as (logged when it changes, and how often it read another one in between)
	pcall(function()
		local p = api.engine.util.getPlayer()
		U.uiReads = (U.uiReads or 0) + 1
		if p ~= U.uiPlayer then
			log("the interface plays " .. tostring(p) .. " (was " .. tostring(U.uiPlayer) .. ", " .. tostring(U.uiReads) .. " reads)")
			U.uiPlayer = p
			U.uiReads = 0
		end
	end)
	pcall(pollBindings)
	pcall(pollCompanies)
	-- (0.8.6, #190: the Finances window's « Company value » chart for this game's own company, see mpfever_valuechart.lua)
	pcall(U.valueChart)
	-- (0.7.0: the mods' guiUpdate, when the interface has a table of game scripts; a script may start late: every 300 ticks)
	U.autoTicks = (U.autoTicks or 0) + 1
	if U.modAutoOn and U.autoTicks % 300 == 1 then pcall(U.wrapModGuiUpdates) end
	if not U.terrainWatch then
		local okt, errt = pcall(installTerrainWatch)
		if not okt then U.terrainWatch = true; log("terrain tools: not watched: " .. tostring(errt)) end
	end
	pcall(pollShares)
	-- (the companies' rules for their stations and depots: the line tool's pick and the names of the stations, twice a second)
	if U.coMap then pcall(U.pollRules) end
	if U.coMap and not U.shareSelectInstalled then
		local oks, errs = pcall(installShareSelect)
		if not oks then U.shareSelectInstalled = true; log("companies: share pick not installed: " .. tostring(errs)) end
	end
	if U.coMap and not U.stopFeesInstalled then
		local okf, errf = pcall(installStopFees)
		if not okf then U.stopFeesInstalled = true; log("companies: stop fees not shown: " .. tostring(errf)) end
	end
	if U.coMap and not U.hudColorsInstalled and U.builtin then
		local okh, errh = pcall(installHudColors, U.builtin)
		if not okh then log("companies: icon colours not installed: " .. tostring(errh)) end
	end
	-- (0.6: also for the « Built by » line of the game option builtby, with one company for everybody too, see U.featBuiltBy)
	if (U.coMap or U.featWantsOwnerLine()) and not U.ownerInstalled and U.react and U.builtin then
		local oko, erro = pcall(installOwnerLine, U.react, U.builtin)
		if not oko then log("companies: owner line not installed: " .. tostring(erro)) end
	end
	-- (autotest) the window maker asked for an entity: what the owner line would show
	if U.ownerInstalled and (U.selfTestAt == nil or os.clock() - U.selfTestAt > 1) then
		U.selfTestAt = os.clock()
		local f = C.IO.open(C.DIR .. C.BS .. "ui_selftest.txt", "rb")
		if f then
			local e = tonumber((f:read("*a") or ""):match("%d+"))
			f:close()
			if e then
			local fw = C.IO.open(C.DIR .. C.BS .. "ui_selftest.txt", "wb")
			if fw then fw:close() end
			local okm, mew = pcall(ug_require, "/gui/entity_window/make_entity_window.tl")
			local okw, r = pcall(function()
				return mew.makeEntityWindowContent(e, nil, false, false, nil, { function() end, "static" }, nil, { function() end, "static" })
			end)
			if okw and type(r) == "table" then
				local p = r.param or {}
				local oke, eu = pcall(ug_require, "/scripts/entity_util.tl")
				local pick = oke and type(eu) == "table" and eu.isOwnedByPlayerOrNotOwned(e)
				-- (the line tool points at the station, its construction or its street too)
				pcall(function()
					local g = api.engine.getComponent(e, api.type.ComponentType.STATION_GROUP)
					for _, st in ipairs(g and g.stations or {}) do
						pick = tostring(pick) .. " station " .. st .. ":" .. tostring(eu.isOwnedByPlayerOrNotOwned(st))
						local okc, con = pcall(function() return api.engine.system.streetConnectorSystem and nil end)
						local ce = nil
						pcall(function() ce = api.engine.system.streetConstructionSystem.getConstructionEntityForStation(st) end)
						if type(ce) == "number" and ce >= 0 then pick = pick .. " con " .. ce .. ":" .. tostring(eu.isOwnedByPlayerOrNotOwned(ce)) end
					end
				end)
				log("selftest window of " .. tostring(e) .. ": recipe " .. tostring(r.recipe) .. ", owner '" .. tostring(p.ownerText) .. "', share '" .. tostring(p.shareText) .. "' edit " .. tostring(p.shareEdit) .. " key " .. tostring(p.shareKey) .. " pickable " .. tostring(pick)
					.. " name '" .. tostring(oke and type(eu) == "table" and eu.getEntityName(e)) .. "'" .. (p.builtByText and (" built by '" .. tostring(p.builtByText) .. "'") or ""))
			else
				log("selftest window of " .. tostring(e) .. ": " .. tostring(r):sub(1, 200))
			end
			end
		end
	end
	pcall(pollLoanView)
	local okn, errn = pcall(N.tick)
	if not okn and not N.failed then N.failed = true; log("notifications: " .. tostring(errn)) end
	pcall(pollStatus)
	local okch, errch = pcall(pollChat)
	if not okch then log("chat poll failed: " .. tostring(errch)) end
	local okaj, erraj = pcall(U.pollAiJournal)
	pcall(U.pollPings)
	local okd, errd = pcall(U.dotsTick)
	if not okd and not U.dotsFailed then U.dotsFailed = true; log("companies: vehicle dots failed: " .. tostring(errd)) end
	if not okaj and not U.aiJFailed then U.aiJFailed = true; log("AI journal poll failed: " .. tostring(erraj)) end
	if not U.sessionInstalled and U.react and U.builtin then
		local oks, errs = pcall(installSession, U.react, U.builtin)
		if not oks then log("session: not installed: " .. tostring(errs)) end
	end
	-- MPFever's window: a click on the bar's icon (done here, at the step after it, where the window has always been opened
	-- from), opened by itself at the start of the session (U.autoOpenTick), a tab the window scenario asks for
	if U.barClick then
		U.barClick = nil
		local okT, errT = pcall(U.toggleWindow)
		log("bar: click on the icon: window " .. (U.winOpen and "opened" or "closed") .. (okT and "" or (" (" .. tostring(errT) .. ")")))
	end
	local okA, errA = pcall(U.autoOpenTick)
	if not okA and not U.autoOpenFailed then U.autoOpenFailed = true; log("window: not opened by itself: " .. tostring(errA)) end
	pcall(U.pollTabReq)
	local okc, errc = pcall(pollControl)
	if not okc then log("control poll failed: " .. tostring(errc)) end
	if not U.stepping then U.stepping = true; log("periodic UI hook active") end
	local okp, errp = pcall(pollResults)
	if not okp then log("results poll failed: " .. tostring(errp)) end
	local okr, pending = pcall(readPending)
	if okr and pendingState and pending ~= pendingState:old() then pendingState:set(pending) end
end

do
	local okR, react = pcall(ug_require, "::/gui/main/react.lua")
	local okB, builtin = pcall(ug_require, "::/gui/main/builtin.lua")
	local okE, entry = pcall(ug_require, "::/gui/main/mod_entry_point.tl")
	-- (0.8.3, #224: Ren's game crashed when another player demolished a road depot while Ren's management window listed it: the
	-- game's window (ManagerWindowContent's step, gui/line_vehicle_mgmt/manager_window.tl) reads each depot of its list with
	-- getComponent and no check, and a replay can take an entity away between two of its steps; the engine's "Invalid entity"
	-- went up through this wrapper and the interface's root failed. In a session, such an error of a step is left for that frame
	-- (logged), the window catching up later, instead of ending the game. MPFEVER_UIINVALID=0: raised, as before)
	U.swallowInvalid = function(err)
		if os.getenv("MPFEVER_UIINVALID") == "0" or not (C.ROLE == "host" or C.ROLE == "client") then return false end
		if not tostring(err):find("Invalid entity", 1, true) then return false end
		U.invalidSwallowed = (U.invalidSwallowed or 0) + 1
		if U.invalidSwallowed <= 5 or U.invalidSwallowed % 500 == 0 then
			log("a window's step read an entity taken away by another player's build (" .. U.invalidSwallowed .. " so far): left for this frame, not raised: " .. tostring(err):sub(1, 160))
		end
		return true
	end
	-- (0.7.0) what runs from react.onStep / onStepTimer runs by itself every frame (or every few seconds): a mod's command sent
	-- from there is automatic (see mpfever_modauto.lua). Wrapped here, at the interface's start, before the windows register
	if okR and type(react) == "table" and U.modAutoOn and not U.reactWrapped then
		pcall(function()
			for _, name in ipairs({ "onStep", "onStepTimer" }) do
				local orig = react[name]
				if type(orig) == "function" then
					react[name] = function(fn, ...)
						if type(fn) ~= "function" then return orig(fn, ...) end
						return orig(function(...)
							U.autoDepth = U.autoDepth + 1
							local r = table.pack(pcall(fn, ...))
							U.autoDepth = U.autoDepth - 1
							if not r[1] then
								if U.swallowInvalid and U.swallowInvalid(r[2]) then return end
								error(r[2], 0)
							end
							return table.unpack(r, 2, r.n)
						end, ...)
					end
				end
			end
			U.reactWrapped = true
		end)
		log("mods' automatic commands: react.onStep and onStepTimer watched (" .. tostring(U.reactWrapped) .. ")")
	end
	if okR and okB then
		U.react, U.builtin = react, builtin
		-- hidden entry point (the game keeps it invisible): only used as a periodic hook
		if okE and entry and entry.ModEntryPointExtension then
			local okP, recipe = pcall(react.RegisterPluginRecipe, entry.ModEntryPointExtension, "MPFeverEntry", function(params)
				if C.ACTIVE then
					if not U.installed then pcall(install) end
					react.onStep(function() tick(nil) end)
					pcall(function() react.onStepTimer(function() tick(nil) end, 0.2) end)
				end
				return builtin.BoxLayout { children = {} }
			end)
			if okP then M.MPFeverEntry = recipe else log("entry registration failed: " .. tostring(recipe)) end
		end
		local okK, kit = pcall(U.makeKit, builtin)
		if okK then U.kit = kit else log("window: drawing helpers not made: " .. tostring(kit)) end
		-- MPFever's icon in the game's bottom bar (see U.barFn). mpfever_bar.res.lua names this recipe: it must exist whatever
		-- happens, an empty one when the bar's extension point cannot be had, or the game would draw its bar with a missing
		-- recipe. (The bar's module by the very name the game loads it with: the same module, its extension point once.)
		local okW, gbw = false, nil
		-- ("::/" names the game's own file: a bare "/..." was looked for in this mod, "module not found", and the icon never showed)
		if os.getenv("MPFEVER_BARFAIL") ~= "reg" then
			okW, gbw = pcall(ug_require, "::/gui/game_bar/game_bar_widgets.tl")
			if not (okW and type(gbw) == "table") then okW, gbw = pcall(ug_require, "/gui/game_bar/game_bar_widgets.tl") end
		end
		if okW and type(gbw) == "table" and gbw.GameBarInfoDisplayExtension then
			local okG, recipe = pcall(react.RegisterPluginRecipe, gbw.GameBarInfoDisplayExtension, "MPFeverBar", function(...) return U.barFn(...) end)
			if okG then M.MPFeverBar = recipe else log("bar: icon not registered: " .. tostring(recipe)) end
		else
			log("bar: the game's bottom bar was not found (" .. tostring(gbw):sub(1, 120) .. ")")
		end
		if not M.MPFeverBar then
			local okF, empty = pcall(react.RegisterRecipe, "MPFeverBar", function() return builtin.BoxLayout { children = {} } end)
			if okF then M.MPFeverBar = empty else log("bar: no empty recipe either: " .. tostring(empty)) end
		end
	else
		log("UI unavailable: react=" .. tostring(okR) .. " builtin=" .. tostring(okB))
	end
end

function data()
	return M
end
