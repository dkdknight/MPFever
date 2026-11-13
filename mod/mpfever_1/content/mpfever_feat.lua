-- MPFever 0.6 game options host (docs/FEATURES-0.6.md): the feature modules (mpfever_feat_<id>.lua), their options and their
-- hooks. Generic: no feature code here.
--
-- Every 0.6 idea is a game option the host switches on or off in the lobby's "Game settings" (or in the Game tab of its game's
-- MPFever window), off by default. The options travel as one string "id=1;id.param=v;..." (the options on and the parameters
-- that are not their default, keys sorted): MPFever.exe keeps the session's, the host's game sends it to every game in the event
-- f_opts, every game keeps it in its state (st.optsText, st.opts, kept in the savegame) and the modules read it through env.on and
-- env.param. With no option on, the bridge calls nothing here at all (st.optsText is empty): a game plays exactly as 0.5.14 did.
--
-- Loaded in four Lua states, each with its own copy: the bridge's simulation half and its interface half (mpfever_bridge.script.lua,
-- through C.feat()), the MPFever window (mpfever_ui.script.lua) and the main menu's lobby (mpfever_menu.lua). So neither this file
-- nor a module may call the game's API when it is loaded, and nothing here keeps state of the game: the options come in with
-- every call. The simulation half's code must give the same result on every game (no os.clock, os.time, math.random or file
-- there; the log is the only exception, its rate is limited by counts).

local F = {}

-- The feature modules, one line each (mpfever_feat_<id>.lua; a module whose file is not there yet is skipped without a word)
F.MODULES = { "journal", "stats", "market", "territory", "tenders", "perms", "trade", "stock", "cargo", "public" }

-- the options string at most (characters, entries): MPFever.exe caps it the same way (launcher/MainForm.cs, FeatOpts)
F.MAX_TEXT = 1000
F.MAX_ENTRIES = 64

-- (tests and the lobby may give their own loader: function(id) return the module table or nil)
F.loader = nil

-- ---------------------------------------------------------------- the modules
-- a module of the list: its file under the names the game resolves (the bridge's way, see the top of the bridge), else nil
local function loadModule(id)
	if F.loader then return F.loader(id) end
	local name = "mpfever_feat_" .. id .. ".lua"
	local tries = {}
	if type(ug_require) == "function" then
		tries[#tries + 1] = function() return ug_require(name) end
		tries[#tries + 1] = function() return ug_require("mpfever_1::/" .. name) end
	end
	if type(require) == "function" then tries[#tries + 1] = function() return require("mpfever_1::/" .. name) end end
	for _, t in ipairs(tries) do
		local ok, m = pcall(t)
		if ok and type(m) == "table" then return m end
	end
	return nil
end

-- What the list gives, once per Lua state: F.mods (in the list's order), F.byId, F.optIndex (option id -> { M, opt, params }) and
-- F.eventOwner (event name -> module). A module, an option or an event declared twice: the first one is kept, the other logged.
-- logf: a log function (the first caller's is kept for the problems found here).
function F.load(logf)
	if F.mods then return F.mods end
	F.logf = F.logf or logf
	local function say(t) if F.logf then pcall(F.logf, "options: " .. t) end end
	F.mods, F.byId, F.optIndex, F.eventOwner = {}, {}, {}, {}
	for _, id in ipairs(F.MODULES) do
		local ok, M = pcall(loadModule, id)
		if ok and type(M) == "table" then
			M.ID = type(M.ID) == "string" and M.ID or id
			if not M.ID:match("^[a-z]+$") or F.byId[M.ID] then
				say("module " .. tostring(M.ID) .. " (" .. id .. ") left out: its id is not [a-z]+ or is taken")
			else
				F.byId[M.ID] = M
				F.mods[#F.mods + 1] = M
				M.OPTIONS = type(M.OPTIONS) == "table" and M.OPTIONS or {}
				for _, o in ipairs(M.OPTIONS) do
					if type(o) == "table" and type(o.id) == "string" and o.id:match("^[a-z_]+$") and not F.optIndex[o.id] then
						local params = {}
						for _, p in ipairs(type(o.params) == "table" and o.params or {}) do
							if type(p) == "table" and type(p.id) == "string" and p.id:match("^[a-z_]+$") and type(p.values) == "table" and #p.values > 0 then
								params[p.id] = p
								if p.default == nil then p.default = p.values[1] end
							end
						end
						F.optIndex[o.id] = { M = M, opt = o, params = params }
					else
						say("module " .. M.ID .. ": option " .. tostring(type(o) == "table" and o.id or o) .. " left out (no [a-z_]+ id, or one taken)")
					end
				end
				for name in pairs(type(M.EVENTS) == "table" and M.EVENTS or {}) do
					if type(name) == "string" and name:sub(1, #M.ID + 3) == "f_" .. M.ID .. "_" and not F.eventOwner[name] then
						F.eventOwner[name] = M
					else
						say("module " .. M.ID .. ": event " .. tostring(name) .. " left out (its name must start with f_" .. M.ID .. "_)")
					end
				end
			end
		end
	end
	if #F.mods > 0 then
		local ids = {}
		for _, M in ipairs(F.mods) do ids[#ids + 1] = M.ID end
		say("modules " .. table.concat(ids, ", "))
	end
	return F.mods
end

-- an option's mode: "separate" (one company per player only), "shared" (co-op only) or "both" (the default)
function F.modeOk(opt, mode)
	local m = type(opt) == "table" and opt.modes or "both"
	if m == nil or m == "both" or mode == nil then return true end
	return m == mode
end

-- ---------------------------------------------------------------- the options string
-- "id=1;id.param=v;..." as a map key -> value text; an entry of another syntax is left out (ids [a-z_]+, values [-0-9a-z_.]+)
function F.parse(s)
	local map, n = {}, 0
	if type(s) ~= "string" or #s > F.MAX_TEXT then return map end
	for entry in s:gmatch("[^;]+") do
		local k, v = entry:match("^%s*([a-z_%.]+)=([%-0-9a-z_%.]+)%s*$")
		if k and (k:match("^[a-z_]+$") or k:match("^[a-z_]+%.[a-z_]+$")) and n < F.MAX_ENTRIES then
			if map[k] == nil then n = n + 1 end
			map[k] = v
		end
	end
	return map
end

-- the string of a map, its keys sorted (byte order, as MPFever.exe sorts them): the same map gives the same text everywhere
function F.encode(map)
	local keys = {}
	for k in pairs(map or {}) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. tostring(map[k]) end
	return table.concat(out, ";")
end

-- (0.6) A parameter declared perPlayer = true (the territory module's handicaps) has one value per player besides its own: the key
-- "id.<param>_<player>", the player's key in the companies registry (its name in lower case) written with the letters a to p, two
-- per byte (the options' syntax takes [a-z_] only, here and in MPFever.exe). A key of more than 30 bytes has no value of its own
-- (MPFever.exe takes a request of 80 characters at most). A player's value is kept even when it is the default: it differs from
-- the parameter's own value then.
F.PLAYER_KEY_MAX = 30
function F.playerPid(pid, key)
	key = tostring(key or "")
	if key == "" or #key > F.PLAYER_KEY_MAX then return nil end
	return tostring(pid) .. "_" .. key:gsub(".", function(c)
		local b = c:byte()
		return string.char(97 + math.floor(b / 16), 97 + b % 16)
	end)
end
-- the parameter and the player's key of a player's parameter id ("money_gcgpgc" -> "money", "bob"), nil when it is none
function F.playerOf(pid)
	local base, enc = tostring(pid or ""):match("^([a-z_]-)_([a-p]+)$")
	if not base or base == "" or #enc % 2 ~= 0 then return nil end
	local key = enc:gsub("..", function(two) return string.char((two:byte(1) - 97) * 16 + two:byte(2) - 97) end)
	return base, key
end
-- the declared parameter of a player's parameter id of an option (perPlayer), nil when it is none
local function playerParam(ent, pid)
	local base, key = F.playerOf(pid)
	local p = base and ent.params[base]
	if p and p.perPlayer == true then return p, key end
	return nil
end

-- The canonical form of an options string for a company mode (nil: any mode): only the options a module declares, that are on
-- ("1") and allowed in that mode, and their parameters with a declared value other than the default (a player's value of a
-- perPlayer parameter: any declared value). Every game computes the same from the same text: the host's game compares it with
-- the game's (st.optsText), every game keeps it when f_opts comes.
function F.canon(s, mode)
	F.load()
	local map = F.parse(s)
	local out = {}
	for key, v in pairs(map) do
		local id, pid = key:match("^([a-z_]+)%.([a-z_]+)$")
		id = id or key
		local ent = F.optIndex[id]
		if ent and map[id] == "1" and F.modeOk(ent.opt, mode) then
			if not pid then
				out[id] = "1"
			else
				local p = ent.params[pid]
				if p and v ~= tostring(p.default) then
					for _, x in ipairs(p.values) do if tostring(x) == v then out[key] = v end end
				elseif not p then
					p = playerParam(ent, pid)
					if p then for _, x in ipairs(p.values) do if tostring(x) == v then out[key] = v end end end
				end
			end
		end
	end
	return F.encode(out)
end

-- an option is on in a map of the options
function F.on(map, id)
	return type(map) == "table" and map[id] == "1"
end

-- an option's parameter, as the module declares its values (a number stays a number); its default when unset or unknown. A
-- player's value of a perPlayer parameter: pid "<param>.<player's key>", nil when that player has none (the module then takes
-- the parameter's own value)
function F.param(map, id, pid)
	F.load()
	local ent = F.optIndex[id]
	if ent and type(pid) == "string" and pid:find(".", 1, true) then
		local base, key = pid:match("^([a-z_]+)%.(.+)$")
		local p = base and ent.params[base]
		local ppid = p and p.perPlayer == true and F.playerPid(base, key)
		local v = ppid and type(map) == "table" and map[id .. "." .. ppid] or nil
		if v ~= nil then
			for _, x in ipairs(p.values) do if tostring(x) == v then return x end end
		end
		return nil
	end
	local p = ent and ent.params[pid]
	if not p then return nil end
	local v = type(map) == "table" and map[id .. "." .. pid] or nil
	if v ~= nil then
		for _, x in ipairs(p.values) do if tostring(x) == v then return x end end
	end
	return p.default
end

-- a module has one of its options on
function F.modOn(map, M)
	for _, o in ipairs(M.OPTIONS or {}) do
		if type(o) == "table" and F.on(map, o.id) then return true end
	end
	return false
end

-- the modules with an option on in a canonical string (kept per string: the simulation asks at every step)
F.activeCache = {}
function F.active(text)
	if type(text) ~= "string" or text == "" then return {} end
	local list = F.activeCache[text]
	if list then return list end
	F.load()
	local map = F.parse(text)
	list = {}
	for _, M in ipairs(F.mods) do if F.modOn(map, M) then list[#list + 1] = M end end
	-- (a few strings at most in a session: the cache is emptied when it grows)
	local n = 0
	for _ in pairs(F.activeCache) do n = n + 1 end
	if n > 16 then F.activeCache = {} end
	F.activeCache[text] = list
	return list
end

-- a { French, English } text (or a plain text) in the player's language, with the caller's T(fr, en)
function F.text(pair, T)
	if type(pair) == "table" then
		if T then return T(tostring(pair[1] or pair[2] or ""), tostring(pair[2] or pair[1] or "")) end
		return tostring(pair[2] or pair[1] or "")
	end
	return tostring(pair or "")
end

-- a parameter's value as the lobby and the window show it (the module's show(), else the value itself)
function F.showValue(p, v, T)
	if type(p.show) == "function" then
		local ok, s = pcall(p.show, v, T)
		if ok and s ~= nil then return tostring(s) end
	end
	return tostring(v)
end

-- The options a mode offers, for the lobby and the window: { { M, opt, params = { p... } } } in the modules' order
function F.offered(mode)
	F.load()
	local out = {}
	for _, M in ipairs(F.mods) do
		for _, o in ipairs(M.OPTIONS) do
			local ent = type(o) == "table" and F.optIndex[o.id]
			if ent and ent.opt == o and F.modeOk(o, mode) then
				local ps = {}
				for _, p in ipairs(type(o.params) == "table" and o.params or {}) do if ent.params[p.id] == p then ps[#ps + 1] = p end end
				out[#out + 1] = { M = M, opt = o, params = ps }
			end
		end
	end
	return out
end

-- The options on, as players read them: { { title, params = { "Label: value", ... } } }, T for the language
function F.summary(map, mode, T)
	local out = {}
	for _, e in ipairs(F.offered(mode)) do
		if F.on(map, e.opt.id) then
			local ps = {}
			for _, p in ipairs(e.params) do
				ps[#ps + 1] = F.text(p.label or p.id, T) .. F.text({ " : ", ": " }, T) .. F.showValue(p, F.param(map, e.opt.id, p.id), T)
				-- (a perPlayer parameter: each player's own value too, "Label (name): value")
				if p.perPlayer == true then
					local keys = {}
					for k in pairs(map or {}) do
						local pid = k:match("^" .. e.opt.id .. "%.([a-z_]+)$")
						local base, key = F.playerOf(pid)
						if base == p.id then keys[#keys + 1] = key end
					end
					table.sort(keys)
					for _, key in ipairs(keys) do
						ps[#ps + 1] = F.text(p.label or p.id, T) .. " (" .. key .. ")" .. F.text({ " : ", ": " }, T)
							.. F.showValue(p, F.param(map, e.opt.id, p.id .. "." .. key), T)
					end
				end
			end
			out[#out + 1] = { title = F.text(e.opt.title or e.opt.id, T), params = ps, id = e.opt.id }
		end
	end
	return out
end

-- ---------------------------------------------------------------- calls into the modules
-- Every call is protected; a failing hook is logged the first 5 times and then every 100th (counts, not time: the simulation's
-- log must not depend on the clock either)
F.fails = {}
function F.call(hook, M, fn, ...)
	local ok, r1, r2 = pcall(fn, ...)
	if not ok then
		local k = hook .. "/" .. tostring(M.ID)
		local n = (F.fails[k] or 0) + 1
		F.fails[k] = n
		if (n <= 5 or n % 100 == 0) and F.logf then pcall(F.logf, "options: " .. tostring(M.ID) .. "." .. hook .. " failed (" .. n .. "): " .. tostring(r1)) end
		return false
	end
	return true, r1, r2
end

-- The env of a module, one per module and per half in each Lua state, its functions reading the call's state (env._st) and the
-- bridge's helpers (env._B, see the bridge's SIM.featBridge and G.featBridge).
F.envs = { sim = {}, gui = {} }
local function simEnv(M, st, B)
	local e = F.envs.sim[M.ID]
	if not e then
		e = { ID = M.ID }
		e.log = function(t) e._B.log("options (" .. M.ID .. "): " .. tostring(t)) end
		e.gameTime = function() return e._B.gameTime() end
		e.on = function(id) return F.on(e._st.opts, id) end
		e.param = function(id, pid) return F.param(e._st.opts, id, pid) end
		-- (the module's own part of the state, created empty)
		e.state = function(s)
			s = s or e._st
			if type(s.feat) ~= "table" then s.feat = {} end
			if type(s.feat[M.ID]) ~= "table" then s.feat[M.ID] = {} end
			return s.feat[M.ID]
		end
		e.companies = function() return e._B.companies(e._st) end
		e.money = function(ent) return e._B.money(ent) end
		-- (kind: nil, a journal entry OTHER; "subsidy", a SUBSIDY entry as the game's own subsidies book their money)
		e.book = function(ent, amount, kind) return e._B.book(ent, amount, M.ID, kind) end
		-- (true once every that many steps, at the same steps on every game: from the game time, as the station fees count)
		e.every = function(steps)
			steps = math.max(1, math.floor(tonumber(steps) or 1))
			return math.floor(e._B.gameTime() / e._B.STEP + 0.5) % steps == 0
		end
		e.month = function() return e._B.month() end
		e.date = function() return e._B.date() end
		-- (another feature module loaded here, e.g. the tenders' count for the game goal: F.byId; nil when it is not there)
		e.module = function(id) return F.byId and F.byId[tostring(id)] or nil end
		-- (a company's lots, as a bankrupt company's auction lists them, and the transfer of one to another company: mpfever_eco.lua's
		-- E.lotsOf and E.transferLot through the bridge; nil when the bridge has none. Called from an event, the same on every game)
		e.lots = function(id) local f = e._B.lots; if f then return f(e._st, id) end return nil end
		e.transferLot = function(fromId, toId, lot) local f = e._B.transferLot; if f then return f(e._st, fromId, toId, lot) end return nil end
		-- (company fromId goes into company intoId at this step, as the merge of companies does (mpfever_eco.lua, E.coMerge; opts:
		-- members = "release", gone = "taken"): true, or false and why. Only from an event: the same step on every game)
		e.coMerge = function(fromId, intoId, opts)
			if type(e._B.coMerge) ~= "function" then return false, "no merge here" end
			return e._B.coMerge(e._st, fromId, intoId, opts)
		end
		F.envs.sim[M.ID] = e
	end
	e._st, e._B = st, B
	e.STEP, e.R, e.CO = B.STEP, B.R, B.CO
	-- (0.6) the texts' T(fr, en) of the bridge, when it gives one (a module's logs and messages; never in the state)
	e.T = B.T
	e.mode = F.simMode(st)
	e.co = (type(st.co) == "table" and st.co.mode == "separate") and st.co or nil
	return e
end
F.simEnv = simEnv

-- the company mode of the game's options (sent with them by the host's game), else the registry's
function F.simMode(st)
	if st.optsMode == "separate" or st.optsMode == "shared" then return st.optsMode end
	return (type(st.co) == "table" and st.co.mode == "separate") and "separate" or "shared"
end

-- a host (or a dedicated server) sends its events under its plain name; a player who joined has "#n" after it (as mpfever_eco.lua)
function F.fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

-- ---------------------------------------------------------------- simulation half (every game, the same step)
-- The host's options, from the event f_opts { s = text, mode }: the game's options from this step on. Only the host's.
function F.applyOpts(st, param, B)
	if not F.fromHost(param.mpfFrom) then
		B.log("options: f_opts of '" .. tostring(param.mpfFrom) .. "' refused: not the host")
		return false
	end
	local mode = param.mode == "separate" and "separate" or "shared"
	local s = F.canon(type(param.s) == "string" and param.s or "", mode)
	st.optsText = s
	st.opts = F.parse(s)
	st.optsMode = mode
	-- (one text MPFever.exe finds in the savegame, to open a lobby on it with these options again: see SaveInfo.Opts)
	st.optsCfg = "mpfopts:" .. s .. ";"
	B.log("options: the game's options are now " .. (s ~= "" and s or "all off") .. " (" .. mode .. ")")
	return true
end

-- an MPFever event whose name starts with "f_": f_opts here, f_act (an action the interface applied, see the bridge's
-- runPausedActions), else the module that declares it, while one of its options is on
function F.simEvent(st, name, param, B)
	F.load(B.log)
	param = type(param) == "table" and param or {}
	if name == "f_opts" then return F.applyOpts(st, param, B) end
	if name == "f_act" then
		-- (dg / only: the modules' copies of the action, see F.digests and F.simAction)
		if type(param.a) == "table" then F.simAction(st, param.a, param.ok, B, param.dg, param.only == true) end
		return true
	end
	local M = F.eventOwner[name]
	if not (M and type(M.event) == "function") then
		B.log("options: event " .. tostring(name) .. " has no module here: ignored")
		return false
	end
	if not F.modOn(st.opts, M) then
		B.log("options: event " .. tostring(name) .. " ignored: the options of " .. M.ID .. " are off")
		return false
	end
	F.call("event", M, M.event, st, name, param, simEnv(M, st, B))
	return true
end

-- Every simulation step while an option is on: each module's month (at the first step of every game month, the game month of
-- mpfever_eco.lua: the game time over the month's duration) and tick. Whether the state changed (a tick says so by returning true).
function F.simTick(st, B)
	local mods = F.active(st.optsText)
	if #mods == 0 then return false end
	local changed, newMonth = false, false
	local m = B.month()
	if type(m) == "number" then
		if type(st.featMonth) ~= "number" then
			-- (the month the options start in is not counted)
			st.featMonth = m
			changed = true
		elseif m > st.featMonth then
			st.featMonth = m
			newMonth, changed = true, true
		end
	end
	for _, M in ipairs(mods) do
		if newMonth and type(M.month) == "function" then F.call("month", M, M.month, st, simEnv(M, st, B)) end
		if type(M.tick) == "function" then
			local ok, r = F.call("tick", M, M.tick, st, simEnv(M, st, B))
			if ok and r then changed = true end
		end
	end
	return changed
end

-- A player's action the games replay, after it (see the contract): every module with onAction while its options are on. Whether
-- a module heard it (it may have changed the state).
-- (0.6) dg: the copies the modules took of the action before it was applied (F.digests: module id -> copy), given to each such
-- module instead of the action; only: the action goes to those modules alone (a tool's build the interface hands over, see the
-- bridge's G.featNativeAct: the other modules hear it in the simulation, SIM.featNative)
function F.simAction(st, a, ok, B, dg, only)
	local heard = false
	for _, M in ipairs(F.active(st.optsText)) do
		local x = type(dg) == "table" and dg[M.ID] or nil
		if type(M.onAction) == "function" and (x ~= nil or not only) then
			heard = true
			F.call("onAction", M, M.onAction, st, x ~= nil and x or a, ok, simEnv(M, st, B))
		end
	end
	return heard
end

-- (0.6) The small copies of an action the modules on keep of it (M.digest(a), plain data), taken BEFORE it is applied: the bridge
-- then translates its references to this game's entity ids in place (a demolished construction's file and place, a sold vehicle's
-- creation key are gone after). { [module id] = copy }, nil when no module on takes one (then nothing changes for anybody).
-- A pure function of the action: the same on every game.
function F.digests(text, a)
	local out = nil
	if type(a) ~= "table" then return nil end
	for _, M in ipairs(F.active(text)) do
		if type(M.digest) == "function" then
			local ok, d = F.call("digest", M, M.digest, a)
			if ok and d ~= nil then
				out = out or {}
				out[M.ID] = d
			end
		end
	end
	return out
end

-- the modules that hear the game's own script events (onGameEvent), while their options are on; with the game's state st (the
-- bridge, once a step), a module whose M.hearsNow(st) says false does not count (nothing to hear now: the tenders while none is
-- open), so the bridge reads no state for the game's events at all
function F.hearsGameEvents(text, st)
	for _, M in ipairs(F.active(text)) do
		if type(M.onGameEvent) == "function" then
			if st == nil or type(M.hearsNow) ~= "function" then return true end
			local ok, r = F.call("hearsNow", M, M.hearsNow, st)
			if not ok or r then return true end
		end
	end
	return false
end

-- a module hears a game event of that name: every one, or (M.GAME_EVENTS = { name = true }) only those it lists
local function hearsName(M, name)
	return type(M.onGameEvent) == "function" and (type(M.GAME_EVENTS) ~= "table" or M.GAME_EVENTS[name] == true)
end

-- (0.6) some module on hears a game event of that name: the bridge reads the state for it only then (the game sends its script
-- events many times a step, a ticket price event at every arrival of a vehicle)
function F.wantsGameEvent(text, name)
	for _, M in ipairs(F.active(text)) do if hearsName(M, name) then return true end end
	return false
end

-- The game's own script events the bridge sees (id: the event's id, e.g. "apply_command"; src: its source): whether the state
-- changed (a module says so by returning true)
function F.simGameEvent(st, id, name, param, B, src)
	local changed = false
	for _, M in ipairs(F.active(st.optsText)) do
		if hearsName(M, name) then
			local ok, r = F.call("onGameEvent", M, M.onGameEvent, st, id, name, param, simEnv(M, st, B), src)
			if ok and r then changed = true end
		end
	end
	return changed
end

-- ---------------------------------------------------------------- interface half (each game, about once a second)
local function guiEnv(M, st, B)
	local e = F.envs.gui[M.ID]
	if not e then
		e = { ID = M.ID }
		e.log = function(t) e._B.log("options (" .. M.ID .. "): " .. tostring(t)) end
		e.on = function(id) return F.on(e._st.opts, id) end
		e.param = function(id, pid) return F.param(e._st.opts, id, pid) end
		-- (an event of this module, stamped and applied by every game at the same step)
		e.send = function(name, param)
			if F.eventOwner[name] ~= M then e.log("event " .. tostring(name) .. " not sent: not one of this module's EVENTS"); return false end
			return e._B.send(name, type(param) == "table" and param or {})
		end
		e.chat = function(text) return e._B.chat(tostring(text or "")) end
		-- (a text file of the session folder for the window, feat_<module>_<name>.txt, written only when it changed)
		e.write = function(name, lines)
			if type(name) ~= "string" or not name:match("^[a-z0-9_]+$") then e.log("file " .. tostring(name) .. " not written: its name is not [a-z0-9_]+"); return false end
			local text = type(lines) == "table" and table.concat(lines, "\n") or tostring(lines or "")
			return e._B.write("feat_" .. M.ID .. "_" .. name .. ".txt", text)
		end
		e.realTime = function() return os.clock() end
		e.gameTime = function() return e._B.gameTime() end
		-- (0.6: the names of the other players of the session this game knows, nil when the bridge gives none)
		e.players = function() return type(e._B.players) == "function" and e._B.players() or nil end
		-- (the calendar's { year, month, day } at a game time, now by default; nil when it cannot be read)
		e.date = function(t) if type(e._B.date) == "function" then return e._B.date(t) end return nil end
		e.module = function(id) return F.byId and F.byId[tostring(id)] or nil end
		-- (a text in this game's language, as C.T: the French, the English or lang.txt's translation of the English; English
		-- without the bridge's)
		e.T = function(fr, en)
			if e._B.T then return e._B.T(fr, en) end
			return en
		end
		-- (a company's lots, as the simulation's env.lots: for the window's lists)
		e.lots = function(id) local f = e._B.lots; if f then return f(e._st, id) end return nil end
		F.envs.gui[M.ID] = e
	end
	e._st, e._B = st, B
	e.isHost, e.me, e.myCo, e.mode = B.isHost, B.me, B.myCo, B.mode
	e.R, e.CO = B.R, B.CO
	-- (0.6: e.T and e.players above, the bridge's C.T and the session's other players' names; the points of a tool's route (the
	-- bridge's G.pvPoints), a dedicated server's owner (its game only), a company's name as the players see it, coName(id); each
	-- nil when the bridge does not give it)
	e.pvPoints, e.owner, e.coName = B.pvPoints, B.owner, B.coName
	return e
end
F.guiEnv = guiEnv

-- (0.6) A module of this game while one of its options is on, with its env of the interface half: M, env; nil else. For the code
-- of this game that asks a module (the computer companies ask the territories, see mpfever_ai.lua).
function F.moduleOn(modId, st, B)
	F.load(B and B.log)
	local M = F.byId[tostring(modId)]
	if not (M and type(st) == "table" and F.modOn(st.opts, M)) then return nil end
	return M, guiEnv(M, st, B)
end

-- every module's gui while its options are on, about once a second (now: the caller's clock in seconds)
function F.gui(st, B, now)
	if (now or 0) - (F.guiAt or -10) < 1 then return end
	F.guiAt = now or 0
	for _, M in ipairs(F.active(st.optsText)) do
		if type(M.gui) == "function" then F.call("gui", M, M.gui, st, guiEnv(M, st, B)) end
	end
end

-- a request of the MPFever window to a module of this game (u.request): to its M.request, while its options are on
function F.request(modId, kind, payload, st, B)
	F.load(B.log)
	local M = F.byId[tostring(modId)]
	if not (M and type(M.request) == "function" and F.modOn(st.opts, M)) then return false end
	F.call("request", M, M.request, kind, payload, st, guiEnv(M, st, B))
	return true
end

-- some module on checks this player's own actions (M.allow)
function F.wantsAllow(text)
	for _, M in ipairs(F.active(text)) do if type(M.allow) == "function" then return true end end
	return false
end

-- This player's own action, before it is shipped: true, or false, the reason and the module that refused it. A module whose
-- check fails lets the action through (logged): a broken module never stops a player.
function F.allow(a, st, B)
	for _, M in ipairs(F.active(st.optsText)) do
		if type(M.allow) == "function" then
			local ok, r, why = F.call("allow", M, M.allow, a, st, guiEnv(M, st, B))
			if ok and r == false then return false, why, M end
		end
	end
	return true
end

-- (0.6) some module on answers the game's interface events (M.guiVeto)
function F.wantsVeto(text)
	for _, M in ipairs(F.active(text)) do if type(M.guiVeto) == "function" then return true end end
	return false
end

-- The game's interface events on THIS player's game (the bridge's guiHandleEvent: a tool's proposal builder.proposalCreate, the
-- vehicle store's buy button, the line window's delete...), to EVERY module on with M.guiVeto(id, name, param, st, env): each one
-- hears it (a module may keep something of it: the plans' route, a build's cost that waits), and their answers make the bridge's
-- answer to the game, as the game's own scripts answer (company.script: { errorMessages = { [text] = true }, skipRender }: the tool
-- shows the texts in red and does not build). Two answers that are tables: one table with the texts of both (skipRender when one
-- says so); else the first answer that is not nil (a text: the store's button is off; true: the line is kept). nil: no module
-- has a say. A module that fails says nothing (logged). Returns the answer and the first module that gave one.
function F.guiVeto(id, name, param, st, B)
	local ans, by, merged = nil, nil, false
	for _, M in ipairs(F.active(st.optsText)) do
		if type(M.guiVeto) == "function" then
			local ok, r = F.call("guiVeto", M, M.guiVeto, id, name, param, st, guiEnv(M, st, B))
			if ok and r ~= nil then
				if ans == nil then
					ans, by = r, M
				elseif type(ans) == "table" and type(r) == "table" then
					-- (a copy: the modules' own tables stay as they are)
					if not merged then
						local c = {}
						for k, v in pairs(ans) do c[k] = v end
						c.errorMessages = {}
						for k, v in pairs(type(ans.errorMessages) == "table" and ans.errorMessages or {}) do c.errorMessages[k] = v end
						ans, merged = c, true
					end
					for k, v in pairs(type(r.errorMessages) == "table" and r.errorMessages or {}) do ans.errorMessages[k] = v end
					if r.skipRender then ans.skipRender = true end
				end
			end
		end
	end
	return ans, by
end

-- ---------------------------------------------------------------- the MPFever window
-- The tabs of the modules (M.TAB and M.ui) with an option on in a map: { { key = "f_<tab id>", M, title } }
function F.tabs(map)
	F.load()
	local out = {}
	for _, M in ipairs(F.mods) do
		if type(M.TAB) == "table" and type(M.TAB.id) == "string" and M.TAB.id:match("^[a-z_]+$") and type(M.ui) == "function" and F.modOn(map, M) then
			out[#out + 1] = { key = "f_" .. M.TAB.id, M = M, title = M.TAB.title or M.TAB.id }
		end
	end
	return out
end

return F
