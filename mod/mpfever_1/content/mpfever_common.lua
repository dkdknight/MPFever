-- MPFever common code, shared by the game-script state (link + execution) and the UI state (interception).
-- No backslash characters on purpose: special characters are built with string.char.

local C = {}

C.BS = string.char(92)
C.NL = string.char(10)
C.CR = string.char(13)
C.TAB = string.char(9)
-- (0.7.9) this mod's version, the same as MPFever.exe's (tests/check_repo.py): the game says it in its "hello", and the launcher
-- warns when the game runs another copy of the mod than the one it installed (issue #136: an old copy in the game's own
-- mods folder, mods/release/MPFever/mod/mpfever_1, which the game takes before the player's mods folder)
C.MODVERSION = "0.7.13"
-- (0.7.11, #156) a custom entity's commands that name one (its move, its state, its removal), see the bridge's guard
C.CUSTOM_ENTITY_FNS = { makeCustomEntityUpdateTransformationCmd = true, makeCustomEntityUpdateStateCmd = true, makeCustomEntityDestroyCmd = true }
-- (0.7.11, #156/#158) Is entity e no mod's custom entity on this game? Such a command names it by its id on the game that made
-- it; on another game that id can be missing, or be something else: on Julian's game (2026-11-08 18:33) the id of marcu's
-- L-Signalsystem preview, 138059, was a node of Julian's tracks, and the preview's move stopped the game (GetComponentDataIndex,
-- OctreeSystemNode). Returns why (a text), or nil when it may be one (or when it cannot be told). A custom entity has none of the
-- world's components below. strict: one without a bounding volume is not one either (a custom entity has one)
C.CUSTOM_NOT = { "BASE_NODE", "BASE_EDGE", "CONSTRUCTION", "TOWN_BUILDING", "TRANSPORT_VEHICLE", "SIM_PERSON", "ANIMAL", "STATION", "LINE", "TOWN", "INDUSTRY" }
function C.notCustomEntity(e, strict)
	if type(e) ~= "number" then return nil end
	local okE, there = pcall(function() return api.engine.entityExists(e) end)
	if not okE then return nil end
	if not there then return "not here" end
	for _, k in ipairs(C.CUSTOM_NOT) do
		local okC, has = pcall(function() return api.engine.getComponent(e, api.type.ComponentType[k]) ~= nil end)
		if okC and has then return "a " .. k:lower() .. " here" end
	end
	if strict then
		local okB, bv = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME) ~= nil end)
		if okB and not bv then return "no custom entity here" end
	end
	return nil
end
local BS, NL, CR, TAB, QUOTE = C.BS, C.NL, C.CR, C.TAB, string.char(34)

do
	local ok, v = pcall(function() return package.loaded["io"] end)
	C.IO = ok and v or nil
end

C.DIR = os.getenv("MPFEVER_DIR")
C.NAME = os.getenv("MPFEVER_NAME") or "player"
C.ROLE = os.getenv("MPFEVER_ROLE") or "solo"
-- the game of a dedicated server (MPFever.exe --server): it hosts the world and plays no company of its own
C.SERVER = os.getenv("MPFEVER_SERVER") == "1"
C.ACTIVE = C.DIR ~= nil and C.DIR ~= "" and C.IO ~= nil

-- Settings of the launcher's settings window (settings.txt in the session folder, "KEY=value" lines, written by MPFever.exe:
-- the host's session settings, the same on every game, and this player's own). They take the place of the environment
-- variables of the same name: os.getenv is wrapped in this Lua state. An empty value means unset.
C.SETTINGS = {}
-- (the original os.getenv, kept once per Lua state: this module loaded again must not wrap its own wrapper)
local rawGetenv = os.getenv
pcall(function()
	if package.loaded["mpfever_rawgetenv"] then rawGetenv = package.loaded["mpfever_rawgetenv"] else package.loaded["mpfever_rawgetenv"] = rawGetenv end
end)
function C.loadSettings()
	local t = {}
	local f = C.ACTIVE and C.IO.open(C.DIR .. BS .. "settings.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		for line in s:gmatch("[^" .. NL .. "]+") do
			local k, v = line:match("^([%w_]+)=(.-)" .. CR .. "?$")
			if k then t[k] = v end
		end
	end
	C.SETTINGS = t
	return t
end
C.loadSettings()
os.getenv = function(k)
	local v = C.SETTINGS[k]
	if v ~= nil then if v == "" then return nil end return v end
	return rawGetenv(k)
end

-- Texts: French and English are written in the code as T("français", "English"); the other languages come from
-- lang.txt in the session folder, written by MPFever.exe: "@lang TAB code", then "English TAB translation" lines.
C.LANG, C.LANGCODE = {}, os.getenv("MPFEVER_LANG") or "en"
function C.loadLang()
	local t = {}
	local f = C.ACTIVE and C.IO.open(C.DIR .. BS .. "lang.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		for line in s:gmatch("[^" .. NL .. "]+") do
			local k, v = line:match("^(.-)" .. TAB .. "(.*)$")
			if k and k ~= "" then
				v = v:gsub(CR, "")
				if k == "@lang" then C.LANGCODE = v else t[k] = v end
			end
		end
	end
	C.LANG = t
end
C.loadLang()
function C.T(fr, en)
	if C.LANGCODE == "fr" then return fr end
	return C.LANG[en] or en
end
-- a text with %s, each taking the next value (put in with gsub: a value may contain % itself; before 0.5.0 every %s took the
-- first one: « 100000 sent to 100000 »)
function C.Tf(fr, en, ...)
	local values, i = { ... }, 0
	local s = C.T(fr, en):gsub("%%s", function() i = i + 1; return tostring(values[i] == nil and values[1] or values[i]) end)
	return s
end

-- name and role chosen in the main menu's MPFever window (written by MPFever.exe before the savegame is loaded)
if C.ACTIVE then
	local f = C.IO.open(C.DIR .. BS .. "identity.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		local n = s:match("name=([^" .. NL .. CR .. "]+)")
		local r = s:match("role=([^" .. NL .. CR .. "]+)")
		if n then C.NAME = n end
		if r then C.ROLE = r end
	end
end

function C.appendFile(path, text)
	local f = C.IO and C.IO.open(path, "ab")
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

-- A file read again every frame, which the launcher appends to: kept open (never closed). An open of a file another program has
-- just written waits for the antivirus to read it again (about 9 ms with Windows Defender, measured), several times a second
-- during a session; through a kept handle the appended lines are read in microseconds. (The launcher empties these files, it
-- never deletes them: the handle stays the file's.) A missing file is looked for again twice a second.
C.kept, C.keptMissed = {}, {}
function C.keptOpen(path)
	local f = C.kept[path]
	if f then return f end
	if not C.IO or (C.keptMissed[path] and os.clock() - C.keptMissed[path] < 0.5) then return nil end
	f = C.IO.open(path, "rb")
	if f then C.kept[path] = f; C.keptMissed[path] = nil else C.keptMissed[path] = os.clock() end
	return f
end

function C.logger(prefix, fileName)
	return function(msg)
		pcall(debugPrint, "[MPFEVER" .. prefix .. "] " .. msg)
		if C.ACTIVE then
			pcall(C.appendFile, C.DIR .. BS .. fileName, os.date("%H:%M:%S") .. " " .. msg .. NL)
		end
	end
end

local function escapeChar(c)
	if c == NL then return BS .. "n" end
	if c == CR then return BS .. "r" end
	if c == QUOTE then return BS .. QUOTE end
	if c == BS then return BS .. BS end
	return BS .. string.format("%03d", string.byte(c))
end

-- A whole number as decimal text. string.format("%d") takes only 32-bit values in Lua 5.2 on Windows (a company balance
-- above 2^31 raised "not a number in proper range", issue #30); "%.0f" is exact for every whole number a double holds
-- exactly (below 2^53), and writes the same text as "%d" did for the others
function C.int(v)
	if v == 0 then return "0" end   -- (also -0)
	return string.format("%.0f", v)
end

-- the bytes a string escapes, listed instead of %c, whose meaning follows the process locale (under a code page it may
-- also take the second byte of a UTF-8 character, issue #30): control bytes 0-31 and 127, the quote and the backslash
local ESCAPED = "[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. QUOTE .. BS .. BS .. "]"

function C.ser(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "0" end
		if math.floor(v) == v and math.abs(v) < 9007199254740992 then return C.int(v) end
		return string.format("%.17g", v)
	elseif t == "string" then
		return QUOTE .. v:gsub(ESCAPED, escapeChar) .. QUOTE
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" and depth < 40 then
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = "[" .. C.ser(k, depth + 1) .. "]=" .. C.ser(val, depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

function C.deser(s)
	local chunk = load("return " .. s, "msg", "t", {})
	if not chunk then return nil end
	local ok, v = pcall(chunk)
	if ok then return v end
	return nil
end

-- (0.6.12) A copy of a plain value as C.deser(C.ser(v)) makes it (what C.ser cannot write is left out: functions, native objects,
-- tables deeper than 40; NaN and infinities become 0), without the text in between: about 4 times faster on a big station's
-- 2.3 MB action (0.04 s instead of 0.17 s), which the replays copied several times while the games stood (the user's test of
-- 2026-11-03 23:17). MPFEVER_FASTCOPY=0: through the text, as before.
function C.copy(v, depth)
	if C.SLOWCOPY then return C.deser(C.ser(v)) end
	depth = depth or 0
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return 0 end
		return v
	elseif t == "string" or t == "boolean" then
		return v
	elseif t == "table" and depth < 40 then
		local out = {}
		for k, x in pairs(v) do
			local kk = C.copy(k, depth + 1)
			if kk ~= nil then out[kk] = C.copy(x, depth + 1) end
		end
		return out
	end
	return nil
end
C.SLOWCOPY = os.getenv("MPFEVER_FASTCOPY") == "0"

function C.dump(v)
	local ok, s = pcall(function() return toString(v) end)
	if ok then return tostring(s) end
	return tostring(v)
end

-- h * 31 + byte over the string, modulo 2^32 (four bytes per step: the products stay exact in doubles below 2^53)
function C.hashStr(h, s)
	local n = #s
	local i = 1
	local byte = string.byte
	while i + 3 <= n do
		local a, b, c, d = byte(s, i, i + 3)
		h = ((h * 31 + a) * 31 + b) % 4294967296
		h = ((h * 31 + c) * 31 + d) % 4294967296
		i = i + 4
	end
	while i <= n do
		h = (h * 31 + byte(s, i)) % 4294967296
		i = i + 1
	end
	return h
end

-- the game's own command functions, saved before the UI hook wraps them; kept in package.loaded so that every
-- script of the Lua state (UI hook, game script bridge) sees the same table, also after a savegame reload
function C.origCmds()
	local ok, t = pcall(function()
		local t = package.loaded["mpfever_orig_cmds"]
		if type(t) ~= "table" then t = {}; package.loaded["mpfever_orig_cmds"] = t end
		return t
	end)
	if ok then return t end
	C._orig = C._orig or {}
	return C._orig
end

-- one protocol line: kind TAB from TAB payload
function C.line(kind, payload)
	return kind .. TAB .. C.NAME .. TAB .. C.ser(payload or {}) .. NL
end

-- ------------------------------------------------------------------ marshalling of native objects

local mfailHook
local function members(o)
	local ok, m = pcall(function() return o.__members end)
	if not ok and mfailHook then mfailHook(o, ".__members", m) end
	if ok and m ~= nil then return m end
	local mt = getmetatable(o)
	if type(mt) == "table" then
		ok, m = pcall(function() return mt.__members end)
		if ok and m ~= nil then return m end
	end
	return nil
end
C.members = members

-- MPFEVER_MARSHALLOG: every failed access while marshalling, with the object's name (marshal_fail.txt): each one costs a
-- crash dump written by the game and about 0.1 s (issue #21)
local MLOG = os.getenv("MPFEVER_MARSHALLOG")
local function mfail(v, what, err)
	if not MLOG then return end
	pcall(function()
		local f = C.IO.open(C.DIR .. string.char(92) .. "marshal_fail.txt", "ab")
		f:write(tostring(v), "\t", what, "\t", tostring(err):sub(1, 120), "\n")
		f:close()
	end)
end
mfailHook = mfail

-- Every failed read of an engine object costs a crash dump written by the game and about 0.1 s, even inside pcall (issue #21:
-- the members of a Vec3f include its functions, distance, lerp, dot... 11 failed reads per colour of a vehicle part). The
-- vectors and matrices are read directly, and the members that cannot be read on an object are remembered per type.
local badMembers = {}
local isMatrix = {}   -- type name -> whether its objects are read as 1..16 (probed once per type)
local function typeName(v)
	local ok, s = pcall(tostring, v)
	return ok and type(s) == "string" and s:match("^([%w_%.]+): ") or nil
end

local function marshal(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" then return v end
	if depth > 30 then return nil end
	if t == "table" then
		local r = {}
		for k, x in pairs(v) do
			if type(k) == "number" or type(k) == "string" then r[k] = marshal(x, depth + 1) end
		end
		return r
	end
	if t == "userdata" then
		local tn = typeName(v)
		if tn == "Vec3f" or tn == "Vec2f" or tn == "Vec4f" then
			local r = { __vec = true }
			local ok = pcall(function()
				r.x, r.y = v.x, v.y
				if tn ~= "Vec2f" then r.z = v.z end
				if tn == "Vec4f" then r.w = v.w end
			end)
			if ok then return r end
		end
		if tn == "Mat4f" then
			local r = { __mat = true }
			if pcall(function() for i = 1, 16 do r[i] = v[i] end end) then return r end
		end
		-- matrix first: Mat4f exposes no members but is indexable by 1..16 (probed once per type: that read
		-- failed on every object of the other types)
		local okm, m16 = true, nil
		if not tn or isMatrix[tn] ~= false then
			okm, m16 = pcall(function() return v[16] end)
			if tn then isMatrix[tn] = okm and type(m16) == "number" end
		end
		if not okm then mfail(v, "[16]", m16) end
		if okm and type(m16) == "number" then
			local r = { __mat = true }
			for i = 1, 16 do r[i] = v[i] end
			return r
		end
		local m = members(v)
		if m ~= nil and #m > 0 then
			local r = { __ud = true }
			local ok = pcall(function()
				local bad = tn and badMembers[tn]
				for i = 1, #m do
					local k = m[i]
					local okk, x = false, nil
					if not (bad and bad[k]) then
						okk, x = pcall(function() return v[k] end)
						if not okk then
							mfail(v, "." .. tostring(k), x)
							if tn then badMembers[tn] = badMembers[tn] or {}; badMembers[tn][k] = true; bad = badMembers[tn] end
						end
					end
					if okk and type(x) ~= "function" then r[k] = marshal(x, depth + 1) end
				end
			end)
			if ok then return r end
		end
		local okx, x = pcall(function() return v.x end)
		if not okx then mfail(v, ".x", x) end
		if okx and type(x) == "number" then
			local r = { __vec = true, x = x }
			pcall(function() r.y = v.y end)
			pcall(function() r.z = v.z end)
			local okw, ew = pcall(function() r.w = v.w end)
			if not okw then mfail(v, ".w", ew) end
			return r
		end
		local okl, n = pcall(function() return #v end)
		if not okl then mfail(v, "#", n) end
		if okl and type(n) == "number" then
			local r = {}
			local ok0, v0 = pcall(function() return v[0] end)
			if ok0 and v0 ~= nil then r[0] = marshal(v0, depth + 1) end
			for i = 1, n do
				local oki, e = pcall(function() return v[i] end)
				if oki then r[i] = marshal(e, depth + 1) end
			end
			return r
		end
		local r = {}
		local okp = pcall(function()
			for k, x in pairs(v) do
				if type(k) == "number" or type(k) == "string" then r[k] = marshal(x, depth + 1) end
			end
		end)
		if okp then return r end
		return { __unknown = tostring(v) }
	end
	return nil
end
C.marshal = marshal

local function isVec(m)
	return type(m) == "table" and (m.__vec or (m.__ud and type(m.x) == "number" and type(m.y) == "number" and m.n == nil))
end

local function plain(m)
	if type(m) ~= "table" then return m end
	if isVec(m) then
		if m.w ~= nil then return api.type.Vec4f.new(m.x, m.y, m.z, m.w) end
		if m.z ~= nil then return api.type.Vec3f.new(m.x, m.y, m.z) end
		return api.type.Vec2f.new(m.x, m.y)
	end
	if m.__mat then
		local V = api.type.Vec4f.new
		return api.type.Mat4f.new(V(m[1], m[2], m[3], m[4]), V(m[5], m[6], m[7], m[8]), V(m[9], m[10], m[11], m[12]), V(m[13], m[14], m[15], m[16]))
	end
	local r = {}
	for k, x in pairs(m) do
		if k ~= "__ud" then r[k] = plain(x) end
	end
	return r
end
C.plain = plain

local function path(root, dotted)
	local cur = root
	for part in dotted:gmatch("[^.]+") do
		if cur == nil then return nil end
		local ok, nxt = pcall(function() return cur[part] end)
		if not ok then return nil end
		cur = nxt
	end
	return cur
end

C.CTOR = {
	SimpleProposal = { "api.type.SimpleProposal" },
	ConstructionEntity = { "api.type.SimpleProposal.ConstructionEntity" },
	NodeAndEntity = { "api.type.NodeAndEntity", "api.type.Proposal.NodeAndEntity" },
	SegmentAndEntity = { "api.type.SegmentAndEntity", "api.type.Proposal.SegmentAndEntity" },
	BaseNode = { "api.type.BaseNode", "api.engine.Component.BaseNode" },
	BaseEdge = { "api.type.BaseEdge", "api.engine.Component.BaseEdge" },
	BaseEdgeStreet = { "api.type.BaseEdgeStreet", "api.engine.Component.BaseEdgeStreet" },
	PlayerOwned = { "api.type.PlayerOwned", "api.engine.Component.PlayerOwned" },
	TransportVehicleConfig = { "api.type.TransportVehicleConfig" },
	TransportVehiclePart = { "api.type.TransportVehiclePart" },
	VehiclePart = { "api.type.VehiclePart" },
	LoadConfig = { "api.type.LoadConfig" },
	Line = { "api.type.Line", "api.engine.Component.Line" },
	LineStop = { "api.type.Line.Stop", "api.engine.Component.Line.Stop" },
	StopConfig = { "api.type.Line.StopConfig", "api.engine.Component.Line.StopConfig" },
	StationTerminal = { "api.type.StationTerminal" },
	Context = { "api.type.Context" },
	StreetEdgeObject = { "api.type.SimpleStreetProposal.EdgeObject" },
	EmissionEmitter = { "api.type.EmissionEmitter" },
	Waypoint = { "api.type.Waypoint" },
	EdgePos = { "api.type.EdgePos" },
	EdgeId = { "api.type.EdgeId" },
	-- (a booking: the cost of a town marketing campaign, the sandbox money field)
	JournalEntry = { "api.type.JournalEntry" },
}

-- fields needing a specific type; false = derived by the engine, never copied; absent = copied generically
-- (a segment's emission emitter, its noise and pollution: the engine does not derive it for a script's segment, which had none
-- on the replaying games while the builder's had one, a stop's or a signal's segment included (2026-10-26: 21 track segments
-- of the session without their pollution on the other game). MPFEVER_EMITTERS=0: as before, never copied)
local SCHEMA = {
	NodeAndEntity = { comp = "BaseNode" },
	BaseNode = { position = "Vec3f" },
	SegmentAndEntity = { comp = "BaseEdge", streetEdge = "BaseEdgeStreet", playerOwned = "PlayerOwned",
		emissionEmitter = (os.getenv("MPFEVER_EMITTERS") ~= "0") and "EmissionEmitter" or false, params = false },
	EmissionEmitter = { position = "Vec3f" },
	BaseEdge = { position0 = "Vec3f", position1 = "Vec3f", tangent0 = "Vec3f", tangent1 = "Vec3f", laneConfigs = false, laneConfigs_native = false, laneConfig = false, distance = false },
	TransportVehicleConfig = { vehicles = { list = "TransportVehiclePart" } },
	TransportVehiclePart = { part = "VehiclePart" },
	VehiclePart = { compartment2loadConfig = { list = "LoadConfig" }, color = "Vec3f" },
	Line = { stops = { list = "LineStop" } },
	-- (the waypoints are set by the player, issue #27: before, they were taken for engine data and dropped)
	LineStop = { alternativeTerminals = { list = "StationTerminal" }, stopConfig = "StopConfig", waypoints = { list = "Waypoint" } },
	Waypoint = { edgePos = "EdgePos", pos = "Vec3f", __p0 = false },
	EdgePos = { edgeId = "EdgeId" },
}

-- A line stop's waypoints as this game takes them: a waypoint whose track is not here is dropped alone (its optional
-- reference resolved to -999999999, see R.translateIn), and one on a track that runs the other way round here takes the
-- opposite place along it
local function waypointsHere(m)
	local list = {}
	for _, wp in ipairs(m.waypoints or {}) do
		local eid = type(wp) == "table" and type(wp.edgePos) == "table" and wp.edgePos.edgeId or nil
		local e = type(eid) == "table" and eid.entity or nil
		if e == -999999999 then
			C.errors[#C.errors + 1] = "waypoint dropped: its track is not on this game"
		else
			if type(e) == "number" and e >= 0 and type(wp.__p0) == "table" and type(wp.edgePos.param) == "number" then
				pcall(function()
					local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
					local n0 = api.engine.getComponent(be.node0, api.type.ComponentType.BASE_NODE).position
					local n1 = api.engine.getComponent(be.node1, api.type.ComponentType.BASE_NODE).position
					local function d(p) return math.abs(p.x - wp.__p0.x) + math.abs(p.y - wp.__p0.y) end
					if d(n0) > 1 and d(n1) < 1 then wp.edgePos.param = 1 - wp.edgePos.param end
				end)
			end
			list[#list + 1] = wp
		end
	end
	m.waypoints = list
	return m
end

C.errors = {}

function C.newOf(tname)
	for _, p in ipairs(C.CTOR[tname] or {}) do
		local c = path(_G, p)
		if c ~= nil then
			local ok, obj = pcall(function() return c.new() end)
			if ok and obj ~= nil then return obj end
			ok, obj = pcall(function() return c:new() end)
			if ok and obj ~= nil then return obj end
		end
	end
	error("no constructor for " .. tname)
end

local rebuild

local function fill(obj, m, tname, where)
	local schema = SCHEMA[tname] or {}
	for k, mv in pairs(m) do
		if k ~= "__ud" and k ~= "__mat" and k ~= "__vec" then
			local ft = schema[k]
			if ft ~= false then
				local val
				local okv, errv = pcall(function()
					if type(ft) == "string" then
						val = rebuild(ft, mv, where .. "." .. k)
					elseif type(ft) == "table" and ft.list then
						val = {}
						for i, e in ipairs(mv) do val[i] = rebuild(ft.list, e, where .. "." .. k .. "[" .. i .. "]") end
					elseif type(mv) == "table" and mv.__ud and not isVec(mv) then
						local cur = obj[k]
						if type(cur) == "userdata" then
							fill(cur, mv, "?", where .. "." .. k)
							val = cur
						else
							val = plain(mv)
						end
					else
						val = plain(mv)
					end
				end)
				if okv then
					local oka, erra = pcall(function() obj[k] = val end)
					if not oka then
						-- a sub-object that cannot be replaced is filled in place; read-only members are derived by
						-- the engine and are skipped
						local cur = nil
						pcall(function() cur = obj[k] end)
						local msg = tostring(erra)
						if type(cur) == "userdata" and type(mv) == "table" then
							pcall(fill, cur, mv, "?", where .. "." .. k)
						elseif not msg:find("read only", 1, true) then
							C.errors[#C.errors + 1] = where .. "." .. k .. ": " .. msg:sub(1, 120)
						end
					end
				else
					C.errors[#C.errors + 1] = where .. "." .. k .. ": " .. tostring(errv):sub(1, 120)
				end
			end
		end
	end
	return obj
end

rebuild = function(tname, m, where)
	where = where or tname
	if type(m) ~= "table" then return m end
	if tname == "Vec3f" or tname == "Mat4f" or isVec(m) or m.__mat then return plain(m) end
	if tname == "LineStop" and type(m.waypoints) == "table" then m = waypointsHere(m) end
	local obj = C.newOf(tname)
	return fill(obj, m, tname, where)
end
C.rebuild = rebuild

local function entityList(list, field)
	local r = {}
	for _, e in ipairs(list or {}) do
		if type(e) == "table" then r[#r + 1] = e[field or "entity"] else r[#r + 1] = e end
	end
	return r
end

local function baseName(fileName)
	local b = tostring(fileName or "construction"):match("([^/]+)$") or "construction"
	return (b:gsub("%.con$", ""))
end

-- The lanes of a street template, as the native street tool uses them
C.templateLaneCache = {}
function C.templateLanes(roadTemplate)
	if type(roadTemplate) ~= "string" or roadTemplate == "" then return nil end
	local cached = C.templateLaneCache[roadTemplate]
	if cached ~= nil then return cached or nil end
	local lanes = false
	pcall(function()
		local rep = api.res.streetTemplateRep
		local idx = rep.find(roadTemplate)
		if idx == nil or idx < 0 then idx = rep.find((roadTemplate:gsub("^::/", ""))) end
		local t = rep.get(idx)
		if t and t.laneConfigs and #t.laneConfigs > 0 then lanes = t.laneConfigs end
	end)
	C.templateLaneCache[roadTemplate] = lanes
	return lanes or nil
end

-- Which vehicles each lane takes and its direction: lanes of a template and lanes captured on a segment (tables) compare
-- by this signature. Tram tracks laid on a road change it while the road's template stays the same.
function C.laneSignature(lanes)
	local parts = {}
	local ok = pcall(function()
		for i = 1, #lanes do
			local l = lanes[i]
			local modes = {}
			for j = 0, 15 do
				local on = false
				pcall(function() on = l.transportModes[j] == true end)
				if on then modes[#modes + 1] = j end
			end
			parts[#parts + 1] = tostring(l.forward) .. ":" .. table.concat(modes, ",")
		end
	end)
	return ok and table.concat(parts, "|") or nil
end

-- the captured lanes of a segment when they are not the lanes of its template (nil: the template's lanes are right)
function C.customLanes(src)
	local c = type(src) == "table" and src.comp
	if type(c) ~= "table" or type(c.laneConfigs) ~= "table" or #c.laneConfigs == 0 then return nil end
	local tl = C.templateLanes(c.roadTemplate)
	if not tl then return nil end
	local a, b = C.laneSignature(c.laneConfigs), C.laneSignature(tl)
	if a and b and a ~= b then return c.laneConfigs end
	return nil
end

-- transportModes reads from index 0 but its writes may be shifted by one (tm[j] = x lands at j-1, tm[0] wraps to the
-- end): measured once, so that a rebuilt lane keeps its modes (a shifted PERSON flag drops the platform of a stop)
function C.transportModesWriteShift()
	if C.tmShift ~= nil then return C.tmShift end
	C.tmShift = 0
	pcall(function()
		local lc = api.type.LaneConfig.new()
		local tm = lc.transportModes
		for j = 0, 15 do tm[j] = false end
		tm[3] = true
		lc.transportModes = tm
		local back = lc.transportModes
		if back[3] then C.tmShift = 0 elseif back[2] then C.tmShift = 1 end
	end)
	return C.tmShift
end

-- Lane configurations (required: a segment without them makes the factory throw "Unknown exception").
-- transportModes is read from index 0.
function C.rebuildLanes(list)
	local out = {}
	local shift = C.transportModesWriteShift()
	for i, m in ipairs(list or {}) do
		local lc = api.type.LaneConfig.new()
		for _, k in ipairs({ "speed", "width", "height", "forward", "offset" }) do
			if m[k] ~= nil then pcall(function() lc[k] = m[k] end) end
		end
		if type(m.transportModes) == "table" then
			pcall(function()
				local tm = lc.transportModes
				for j = 0, 15 do
					pcall(function() tm[j + shift] = m.transportModes[j] == true end)
				end
				lc.transportModes = tm
			end)
		end
		out[i] = lc
	end
	return out
end

-- a street/track segment with only the fields a script proposal needs (the engine derives lanes, decorations...)
-- bare: geometry only (no street template, no precedence, no owner)
function C.minimalSegment(s, noOwner, bare)
	local se = C.newOf("SegmentAndEntity")
	se.entity = s.entity
	pcall(function() se.type = s.type end)
	local c = s.comp or {}
	local comp = se.comp
	local keys = bare and { "node0", "node1", "type", "typeIndex" }
		or { "node0", "node1", "type", "typeIndex", "roadType", "roadTemplate", "roadStyle", "roadDevelopmentLocked" }
	for _, k in ipairs(keys) do
		if c[k] ~= nil then pcall(function() comp[k] = c[k] end) end
	end
	if bare then
		for _, k in ipairs({ "tangent0", "tangent1" }) do
			if c[k] ~= nil then pcall(function() comp[k] = plain(c[k]) end) end
		end
		pcall(function() se.comp = comp end)
		return se
	end
	for _, k in ipairs({ "tangent0", "tangent1", "position0", "position1" }) do
		if c[k] ~= nil then pcall(function() comp[k] = plain(c[k]) end) end
	end
	-- the distance of a track from its axis (5 for the tracks the tool lays: a noise barrier is placed at that distance, so a
	-- track rebuilt with 0 gets its barrier in the middle of the track)
	if type(c.distance) == "number" and c.distance ~= 0 then pcall(function() comp.distance = c.distance end) end
	-- the road's decorations (the trees of a "_trees" template...) are not derived from the template
	if type(c.edgeDecorations) == "table" and #c.edgeDecorations > 0 then
		local okd, errd = pcall(function() comp.edgeDecorations = plain(c.edgeDecorations) end)
		if not okd then C.errors[#C.errors + 1] = "edgeDecorations: " .. tostring(errd):sub(1, 100) end
	end
	pcall(function() se.comp = comp end)
	if type(s.streetEdge) == "table" then
		pcall(function()
			local e = se.streetEdge
			e.precedenceNode0 = s.streetEdge.precedenceNode0
			e.precedenceNode1 = s.streetEdge.precedenceNode1
			se.streetEdge = e
		end)
	end
	if not noOwner and type(s.playerOwned) == "table" and type(s.playerOwned.player) == "number" then
		pcall(function()
			local po = C.newOf("PlayerOwned")
			po.player = s.playerOwned.player
			se.playerOwned = po
		end)
	end
	return se
end

-- A native proposal numbers its new entities in one sequence shared by nodes, segments and edge objects (nodes -1, -2,
-- -6, segments -3, -7...) and marks the new stops of a segment with placeholders (-400000000 - k). A script proposal
-- numbers new nodes and new segments separately from -1 and adds stops through edgeObjectsToAdd only.
function C.renumberStreet(st)
	local nodeMap, edgeMap = {}, {}
	local nodes = st.nodesToAdd or st.addedNodes or {}
	local edges = st.edgesToAdd or st.addedSegments or {}
	local k = 0
	for _, n in ipairs(nodes) do
		if type(n) == "table" and type(n.entity) == "number" and n.entity < 0 then
			k = k + 1
			nodeMap[n.entity] = -k
			n.entity = -k
		end
	end
	k = 0
	for _, e in ipairs(edges) do
		if type(e) == "table" and type(e.entity) == "number" and e.entity < 0 then
			k = k + 1
			edgeMap[e.entity] = -k
			e.entity = -k
		end
	end
	for _, e in ipairs(edges) do
		local c = type(e) == "table" and e.comp
		if type(c) == "table" then
			if type(c.node0) == "number" and nodeMap[c.node0] then c.node0 = nodeMap[c.node0] end
			if type(c.node1) == "number" and nodeMap[c.node1] then c.node1 = nodeMap[c.node1] end
			if type(c.objects) == "table" then
				local keep = {}
				for _, o in ipairs(c.objects) do
					if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then keep[#keep + 1] = o end
				end
				c.objects = keep
			end
		end
	end
	for _, o in ipairs(st.edgeObjectsToAdd or {}) do
		if type(o) == "table" and type(o.segmentEntity) == "number" and edgeMap[o.segmentEntity] then
			o.segmentEntity = edgeMap[o.segmentEntity]
		end
	end
	return nodeMap, edgeMap
end

-- The objects (signals, stops) that stay on a segment a build replaces carry the originator's entity ids, which differ from
-- this game's: they are matched by their rank on the removed segment (the removed segments are already this game's own).
function C.existingObjectIds(st)
	local map = {}
	for _, rm in ipairs(st.removedSegments or st.edgesToRemove or {}) do
		if type(rm) == "table" and type(rm.entity) == "number" and rm.entity >= 0 and type(rm.comp) == "table" and type(rm.comp.objects) == "table" then
			local okc, lc = pcall(function() return api.engine.getComponent(rm.entity, api.type.ComponentType.BASE_EDGE) end)
			if okc and lc then
				for k, o in ipairs(rm.comp.objects) do
					local okl, lo = pcall(function() return lc.objects[k][1] end)
					if okl and type(lo) == "number" and type(o) == "table" and type(o[1]) == "number" then map[o[1]] = lo end
				end
			end
		end
	end
	return map
end

-- a build that cuts a segment carrying stops or signals and keeps them (they move to its new segments)
function C.movesObjects(st)
	if type(st) ~= "table" then return false end
	local gone = {}
	for _, id in ipairs(st.edgeObjectsToRemove or {}) do gone[id] = true end
	for _, rm in ipairs(st.removedSegments or st.edgesToRemove or {}) do
		local objs = type(rm) == "table" and type(rm.comp) == "table" and rm.comp.objects
		if type(objs) == "table" then
			for _, o in ipairs(objs) do
				if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 and not gone[o[1]] then return true end
			end
		end
	end
	return false
end

-- the existing objects of a captured added segment, as this game's ({ id, kind } pairs)
function C.localObjects(src, idMap)
	local list = {}
	local objs = type(src) == "table" and type(src.comp) == "table" and src.comp.objects
	if type(objs) ~= "table" then return list end
	for _, o in ipairs(objs) do
		if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then
			list[#list + 1] = { idMap[o[1]] or o[1], o[2] }
		end
	end
	return list
end

-- the node configurations (lane connections, crosswalks, traffic lights) of a captured proposal, for a SimpleStreetProposal
-- (entities already this game's, new segments with the proposal's own negative ids)
function C.nodeConfigs(list)
	local cfgs = {}
	for i, m in ipairs(list or {}) do
		local o = api.type.BaseNodeLaneConnectionAndEntity.new()
		o.entity = m.entity
		local cfg = o.comp
		local mc = m.comp or {}
		local lcs = {}
		for j, l in ipairs(mc.laneConnections or {}) do
			local lc = api.type.LaneConnection.new()
			lc.segment0 = l.segment0; lc.lane0 = l.lane0; lc.segment1 = l.segment1; lc.lane1 = l.lane1
			lc.withRoad = l.withRoad == true; lc.withTram = l.withTram == true
			lcs[j] = lc
		end
		cfg.laneConnections = lcs
		local cw = {}
		for j, x in ipairs(mc.crosswalks or {}) do cw[j] = x end
		cfg.crosswalks = cw
		pcall(function() cfg.trafficLightPreference = mc.trafficLightPreference end)
		pcall(function() cfg.doubleSlipSwitch = mc.doubleSlipSwitch == true end)
		pcall(function() cfg.userModifiedLaneConnections = mc.userModifiedLaneConnections == true end)
		-- (0.6.9: a junction's traffic light phases, the engine's own object when the caller has it, see C.keptNodeConfigs)
		if m.tlc ~= nil then pcall(function() cfg.trafficLightConfig = m.tlc end) end
		if m.noCrosswalks then cfg.crosswalks = {} end
		o.comp = cfg
		cfgs[i] = o
	end
	return cfgs
end

-- (0.7.1, issue #127) the node configurations a build adds to nodes that already have one on this game: replaced (the node is
-- also put in the list of configurations the build removes, as the native tools do for a junction they change), never added a
-- second time. A client's builds made during a pause reached the host all at once at the unpause; one of them (a junction's
-- configuration only) added one to a node the host had already configured: ecs::Engine::AddComponent assertion, the host
-- crashed (0.6.12, Malle355). add: the configurations to add ({ entity = node, ... }); remove: the nodes whose configuration
-- the build removes (a list, completed in place and returned); skip(node), if given: a node the build removes (left as it is);
-- has(node), if given: this game's node has a configuration (default: the engine's BASE_NODE_CONFIG). Returns the list and the
-- number of nodes put in. MPFEVER_CFGREPLACE=0: nothing changed, as before
function C.cfgGuard(add, remove, skip, has)
	remove = remove or {}
	if os.getenv("MPFEVER_CFGREPLACE") == "0" then return remove, 0 end
	has = has or function(n) return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) ~= nil end
	local inRemove, n = {}, 0
	for _, r in ipairs(remove) do inRemove[r] = true end
	for _, c in ipairs(add or {}) do
		local e = type(c) == "table" and c.entity or nil
		if type(e) == "number" and e >= 0 and not inRemove[e] and not (skip and skip(e)) then
			local ok, h = pcall(has, e)
			if ok and h then remove[#remove + 1] = e; inRemove[e] = true; n = n + 1 end
		end
	end
	return remove, n
end

-- (0.7.6, issue #131) the tool's configurations (list: the captured nodeConfigsToAdd) of the nodes whose configuration a
-- script form of its build removes (removed: this game's node ids), for that form: its new segments numbered again from -1
-- (edgeMap: the tool's number -> the form's, see C.renumberStreet), the existing segments as they are. A node the build
-- removes (gone[node]) or a new node gets none; a configuration naming a new segment the form does not have is left (counted).
-- Returns the list (copies) and the number left.
function C.readdedConfigs(list, removed, edgeMap, gone)
	local want, out, left = {}, {}, 0
	for _, n in ipairs(removed or {}) do want[n] = true end
	for _, c in ipairs(list or {}) do
		local e = type(c) == "table" and c.entity or nil
		if type(e) == "number" and e >= 0 and want[e] and not (gone and gone[e]) then
			local comp = type(c.comp) == "table" and c.comp or {}
			local ok, lcs = true, {}
			for j, l in ipairs(comp.laneConnections or {}) do
				local x = {}
				for k, v in pairs(l) do x[k] = v end
				for _, f in ipairs({ "segment0", "segment1" }) do
					local s = x[f]
					if type(s) == "number" and s < 0 then
						if edgeMap and edgeMap[s] then x[f] = edgeMap[s] else ok = false end
					end
				end
				lcs[j] = x
			end
			if ok then
				local cc = {}
				for k, v in pairs(comp) do cc[k] = v end
				cc.laneConnections = lcs
				out[#out + 1] = { entity = e, comp = cc }
			else
				left = left + 1
			end
		end
	end
	return out, left
end

-- (0.6.9) what a script's copy of a segment keeps of it, as the stop tool and the replays of its stops keep it (replayStop): its
-- decorations (a town street's trees: the copy had none on the builder's game, both rows on the replaying games: "edges" apart,
-- then the towns, test fe3 of 2026-11-02) and a track's distance. rev: the copy runs the other way round (a decoration's side
-- counts from the first node). MPFEVER_STOPDECOR=0: none kept, as before
function C.keepSegmentLook(cc, c, rev)
	if os.getenv("MPFEVER_STOPDECOR") == "0" then return end
	pcall(function() if type(c.distance) == "number" and c.distance ~= 0 then cc.distance = c.distance end end)
	pcall(function()
		if #c.edgeDecorations == 0 then return end
		if not rev then cc.edgeDecorations = c.edgeDecorations; return end
		local deco = {}
		for k = 1, #c.edgeDecorations do local d = c.edgeDecorations[k]; deco[k] = { d[1], not d[2] } end
		cc.edgeDecorations = deco
	end)
end

-- (0.6.9) the node configurations of a segment's ends, for a script's build that replaces the segment by a copy (newId, the
-- proposal's negative id): the lane connections of the old segment moved onto the copy, as the stop tool puts them back. Removing
-- them alone left a junction with traffic lights but no configuration: the engine asserted (it != components.end(), stress test
-- 2026-11-02 on Test Knight 14, node 58155). A list for C.nodeConfigs; get(node) reads a node's configuration (marshalled);
-- newId may be a table, a node -> the copy's id at that node (a segment split in two). raw(node), if given: the engine's
-- component, whose traffic light phases are put back as they are
function C.keptNodeConfigs(nodes, oldSeg, newId, get, raw, opts)
	local out = {}
	for _, nd in ipairs(nodes or {}) do
		local mc = get(nd)
		local nid = type(newId) == "table" and newId[nd] or newId
		if type(mc) == "table" and type(nid) == "number" then
			local lcs = {}
			for j, l in ipairs(mc.laneConnections or {}) do
				local c = {}
				for k, v in pairs(l) do c[k] = v end
				if c.segment0 == oldSeg then c.segment0 = nid end
				if c.segment1 == oldSeg then c.segment1 = nid end
				lcs[j] = c
			end
			local comp = {}
			for k, v in pairs(mc) do comp[k] = v end
			comp.laneConnections = lcs
			local o = { entity = nd, comp = comp }
			-- (raw(node): the engine's component, its traffic light phases put as they are; opts.noCrosswalks: none)
			if raw and not (opts and opts.noTlc) then
				local okr, r = pcall(raw, nd)
				if okr and r ~= nil then pcall(function() o.tlc = r.trafficLightConfig end) end
			end
			if opts and opts.noCrosswalks then o.noCrosswalks = true end
			out[#out + 1] = o
		end
	end
	return out
end

-- (0.6.9) a stop's copy of a segment with its junctions' configurations put back (C.keptNodeConfigs) on ssp, in the first form
-- the command's factory takes (make(sp) makes the command): without the traffic light phases, then without the phases nor the
-- crosswalks. Returns the command and what was tried, or nil when no form was taken (the stop is not built: removed alone, the
-- configurations made the engine assert). The phases are never put back: the other games replay the stop from its capture,
-- which cannot carry them, and a junction with the builder's phases on one game and the engine's on the others made the
-- traffic, then the towns and the vehicles, go apart (one company per player with two computer companies: 6 runs of 6 out of
-- sync after their stops, 0.6.8 in sync: its companies left those streets out). MPFEVER_STOPTLC=1: the phases tried first, as
-- the first 0.6.9 build did (the full form, without the phases, without the crosswalks, with neither)
function C.stopWithNodeConfigs(sp, ssp, ncr, seg, make)
	local function rawCfg(nd) return api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) end
	local function getCfg(nd) return C.marshal(rawCfg(nd)) end
	local forms = { { "no phases", { noTlc = true } }, { "neither", { noTlc = true, noCrosswalks = true } } }
	if os.getenv("MPFEVER_STOPTLC") == "1" then
		forms = { { "full", {} }, { "no phases", { noTlc = true } }, { "no crosswalks", { noCrosswalks = true } },
			{ "neither", { noTlc = true, noCrosswalks = true } } }
	end
	local tried = {}
	for _, f in ipairs(forms) do
		local cmd
		local ok, err = pcall(function()
			ssp.nodeConfigsToAdd = C.nodeConfigs(C.keptNodeConfigs(ncr, seg, -1, getCfg, rawCfg, f[2]))
			sp.streetProposal = ssp
			cmd = make(sp)
		end)
		tried[#tried + 1] = f[1] .. " " .. (ok and "OK" or tostring(err):gsub("^%[string \"[^\"]*\"%]:%d+: ", ""):sub(1, 60))
		if ok and cmd then return cmd, table.concat(tried, "; ") end
	end
	return nil, table.concat(tried, "; ")
end

-- What a build does, in short (counts of each kind of change, and the place and switch flag of each node configuration
-- added), from shipped arguments as well as from a captured build (both with references): the engine sometimes applies an
-- action's build a second time at the same moment (a double slip switch on a node next to another one), on every game,
-- and that second build must not be shipped as a new one (each game then replayed the other's copy late)
function C.buildSig(m)
	if type(m) ~= "table" then return nil end
	local st = m.proposal or m.streetProposal or {}
	local function n(t) return type(t) == "table" and #t or 0 end
	local parts = { n(st.addedNodes or st.nodesToAdd), n(st.removedNodes or st.nodesToRemove), n(st.addedSegments or st.edgesToAdd),
		n(st.removedSegments or st.edgesToRemove), n(st.edgeObjectsToAdd), n(st.edgeObjectsToRemove), n(st.nodeConfigsToAdd),
		n(st.nodeConfigsToRemove), n(m.toAdd), n(m.toRemove) }
	for _, c in ipairs(st.nodeConfigsToAdd or {}) do
		local e = type(c) == "table" and c.entity or nil
		local p = type(e) == "table" and e.p or nil
		-- (a node given by its id here: its position, as a reference gives it)
		if type(e) == "number" and e >= 0 then
			pcall(function() p = api.engine.getComponent(e, api.type.ComponentType.BASE_NODE).position end)
		end
		parts[#parts + 1] = p and string.format("%.0f,%.0f", p.x or 0, p.y or 0) or tostring(e)
		parts[#parts + 1] = tostring(type(c) == "table" and type(c.comp) == "table" and c.comp.doubleSlipSwitch)
	end
	-- the file and place of each construction added: in a pause every build has the same game time, and two players' stations
	-- (or one player's two depots) both read "one construction added". The second was taken for the engine's second
	-- application of the first, not shipped, and stood on its own game only (money, constructions and towns out of sync,
	-- #102). MPFEVER_SIGCON=0: counts only, as before
	if os.getenv("MPFEVER_SIGCON") ~= "0" then
		for _, ce in ipairs(type(m.toAdd) == "table" and m.toAdd or {}) do
			local t = type(ce) == "table" and ce.transf or nil
			parts[#parts + 1] = tostring(type(ce) == "table" and ce.fileName or "?"):match("[^/]*$") .. "@"
				.. ((type(t) == "table" and type(t[13]) == "number") and string.format("%.0f,%.0f", t[13], t[14] or 0) or "?")
		end
	end
	return table.concat(parts, "/")
end

-- (0.7.7, issue #133) The signature of what a rebuilt form builds: the shipped build (m) with the node configurations the
-- form really adds and removes (cfgs, C.rebuiltCfgs). A form other than the raw ones gives the tool's configurations again
-- only for the nodes it touches (#131), so it adds fewer than the tool: the engine's second application of that build had
-- another signature than the shipped one, and every game shipped it as a build of its own (yoyo's session, 2026-11-07 23:11:
-- 18 segments electrified, built three more times, resynchronisation). nil when it is the shipped one's.
function C.rebuiltSig(m, cfgs)
	if type(m) ~= "table" or type(cfgs) ~= "table" then return nil end
	local src = m.proposal or m.streetProposal
	if type(src) ~= "table" then return nil end
	local p = {}
	for k, v in pairs(src) do p[k] = v end
	p.nodeConfigsToAdd = cfgs.add or {}
	p.nodeConfigsToRemove = cfgs.rm or {}
	local copy = {}
	for k, v in pairs(m) do copy[k] = v end
	copy.streetProposal = nil
	copy.proposal = p
	local a, b = C.buildSig(m), C.buildSig(copy)
	if b == nil or a == b then return nil end
	return b
end

-- Whether replaying a command can reach onPreBuildProposal (and must be marked as a replay so that it is not shipped
-- again). Vehicles, lines, names, events... never do: counting them while the game time stood still (a paused session)
-- made every later build of the player look like a replay, and none was shipped (issue #12).
local NO_PROPOSAL_PREFIXES = { "makeVehicle", "makeLine", "makeEntitySet", "makeScriptingSendEvent", "makeGameSet",
	"makeJournal", "makeStockList", "makeTownSet", "makeTownBuildingSet", "makeIndustrySet" }
-- (the industry window's "extend": the command only computes the proposal it shows, the build comes as a command of its own.
-- Counted, every replayed click made the player's next own build look like a replay, never shipped, cancelled and built on
-- one game only: every resync of a 3.5 h session, 2026-10-28. MPFEVER_EXTENDCOUNT=1: counted as before)
if os.getenv("MPFEVER_EXTENDCOUNT") ~= "1" then NO_PROPOSAL_PREFIXES[#NO_PROPOSAL_PREFIXES + 1] = "makeCreateIndustryExtendProposalCmd" end
-- (0.7.11, #156: a mod's custom entity, L-Signalsystem's previews: made, moved, changed, taken away, never a build. Counted, the
-- host's previews in a pause brought Julian's count to 76 replays, none of them a build; the player's own next build at that game
-- time would have been taken as one of them and never shipped, built on one game only. MPFEVER_CUSTOMCOUNT=1: counted as before)
if os.getenv("MPFEVER_CUSTOMCOUNT") ~= "1" then NO_PROPOSAL_PREFIXES[#NO_PROPOSAL_PREFIXES + 1] = "makeCustomEntity" end
function C.makesProposal(fn)
	fn = tostring(fn)
	for _, p in ipairs(NO_PROPOSAL_PREFIXES) do
		if fn:sub(1, #p) == p then return false end
	end
	return true
end

-- (0.7.7) The edge objects of a script's street proposal (SimpleStreetProposal.EdgeObject: a mod's game script such as Auto
-- Signals, a script tool of the interface) name their new segment by edgeEntity (its rank in edgesToAdd, -1, -2...) and say
-- their kind only through the placeholder the script put in that segment's objects (-400000000 - their rank from 0, with
-- SIGNAL 2, STOP_LEFT 0 or STOP_RIGHT 1). C.rebuildProposal reads the tool's form (segmentEntity, category): every form set
-- edgeEntity = nil, "The lua object can't be cast to desired type", refused on every game, the builder's too (Knight-HD
-- 2026-11-08 01:39, YkeWoudstra #133, torol's paused stops #127). Taken over here: segmentEntity and the script's own kind
-- (o.scriptKind). Returns how many. MPFEVER_SCRIPTEO=0: as before
function C.scriptEdgeObjects(st)
	local list = type(st) == "table" and st.edgeObjectsToAdd or nil
	if type(list) ~= "table" then return 0 end
	local edges = st.edgesToAdd or st.addedSegments or {}
	local n = 0
	for k, o in ipairs(list) do
		if type(o) == "table" and o.segmentEntity == nil and type(o.edgeEntity) == "number" then
			o.segmentEntity = o.edgeEntity
			local want = -400000000 - (k - 1)
			for _, s in ipairs(edges) do
				local objs = type(s) == "table" and s.entity == o.edgeEntity and type(s.comp) == "table" and s.comp.objects or nil
				for _, p in ipairs(type(objs) == "table" and objs or {}) do
					if type(p) == "table" and p[1] == want and type(p[2]) == "number" then o.scriptKind = p[2] end
				end
			end
			if o.scriptKind == nil then o.scriptKind = o.left and 0 or 1 end
			o.category = (o.scriptKind == 2) and 2 or 0
			n = n + 1
		end
	end
	return n
end

-- Proposal (native, from the construction tools) or SimpleProposal -> SimpleProposal for makeWorldBuildProposalCmd
-- opts.noStreet: constructions only (their .con template regenerates its own street connector)
-- opts.seed: deterministic seed for constructions that have none (a script ConstructionEntity needs params.seed)
function C.rebuildProposal(m, opts)
	opts = opts or {}
	-- (0.7.7) the node configurations this form adds and removes, as Lua lists, for the signature of what it builds (see
	-- C.rebuiltSig): nil when the form has no street part
	C.rebuiltCfgs = nil
	local sp = C.newOf("SimpleProposal")
	local toAdd = m.constructionsToAdd or m.toAdd or {}
	local cons = {}
	for i, ce in ipairs(toAdd) do
		local c = C.newOf("ConstructionEntity")
		c.fileName = ce.fileName
		local params = ce.params
		if params == nil and type(ce.construction) == "table" then params = ce.construction.params end
		params = plain(params or {})
		if params.seed == nil then params.seed = (opts.seed or 0) + i end
		c.params = params
		if ce.transf then c.transf = plain(ce.transf) end
		-- -1 = nobody's (a town building the tool moved for the new street): it must stay a town building, not
		-- become the player's construction (which the player would also pay for)
		local player = ce.playerEntity
		if type(player) ~= "number" then player = api.engine.util.getPlayer() end
		c.playerEntity = player
		if ce.hq == true then pcall(function() c.setAsHeadquarterHack = true end) end
		local name = ce.name
		if type(name) ~= "string" or name == "" then name = baseName(ce.fileName) end
		pcall(function() c.name = name end)
		cons[i] = c
	end
	sp.constructionsToAdd = cons
	local removeList = entityList(m.constructionsToRemove or m.toRemove)
	sp.constructionsToRemove = removeList
	if type(m.old2newByRank) == "table" then
		pcall(function()
			local map = {}
			for i, e in ipairs(removeList) do
				local v = m.old2newByRank[i] or m.old2newByRank[tostring(i)]
				if v ~= nil then map[e] = v end
			end
			sp.old2new = map
		end)
	elseif type(m.old2new) == "table" then pcall(function() sp.old2new = plain(m.old2new) end) end

	local st = m.streetProposal or m.proposal
	if type(st) == "table" and not opts.noStreet then
		local ssp = sp.streetProposal
		local variant = opts.variant or "full"
		local nodeMap, edgeMap = {}, {}
		local scriptEO = (os.getenv("MPFEVER_SCRIPTEO") ~= "0") and C.scriptEdgeObjects(st) or 0
		if not opts.raw then nodeMap, edgeMap = C.renumberStreet(st) end
		local nodes = {}
		for i, n in ipairs(st.nodesToAdd or st.addedNodes or {}) do
			if variant == "full" then
				nodes[i] = rebuild("NodeAndEntity", n, "addedNodes[" .. i .. "]")
			else
				local ne = C.newOf("NodeAndEntity")
				ne.entity = n.entity
				local comp = ne.comp
				comp.position = plain(n.comp and n.comp.position)
				ne.comp = comp
				nodes[i] = ne
			end
		end
		-- the stops and signals already on a segment the build cuts: a script proposal cannot move them to the new segments
		-- (the engine asserts adding their component again) and leaves them stranded on the removed segment (the game then
		-- crashed in their catchment area). Only the native form moves them (see C.movesObjects).
		if C.movesObjects(st) then error("stops or signals on a segment the build cuts: native form only") end
		local edges = {}
		for i, s in ipairs(st.edgesToAdd or st.addedSegments or {}) do
			if variant == "full" then
				edges[i] = rebuild("SegmentAndEntity", s, "addedSegments[" .. i .. "]")
			else
				edges[i] = C.minimalSegment(s, variant ~= "minimal", variant == "bare")
			end
		end
		-- Properties return COPIES: the lists are built in Lua, assigned to the street proposal copy, and the copy is
		-- written back. Every segment needs its lanes (without them the engine asserts in CreateShapes): the lanes of
		-- its street template, as the native tool uses them.
		for i, e in ipairs(edges) do
			local src = (st.edgesToAdd or st.addedSegments)[i]
			local tmpl = src and src.comp and src.comp.roadTemplate
			local custom = C.customLanes(src)
			local lanes = custom and C.rebuildLanes(custom) or C.templateLanes(tmpl)
			if not lanes and src and src.comp and type(src.comp.laneConfigs) == "table" then lanes = C.rebuildLanes(src.comp.laneConfigs) end
			if lanes then
				local c = e.comp
				c.laneConfigs = lanes
				e.comp = c
			else
				C.errors[#C.errors + 1] = "segment " .. i .. ": no lanes for template " .. tostring(tmpl)
			end
		end
		if scriptEO > 0 and variant == "full" then
			for i, e in ipairs(edges) do
				local s = (st.edgesToAdd or st.addedSegments)[i]
				local d = type(s) == "table" and type(s.comp) == "table" and s.comp.distance or nil
				if type(d) == "number" and d ~= 0 then pcall(function() local c = e.comp; c.distance = d; e.comp = c end) end
			end
		end
		local EXP = opts.exp or ""
		-- the stops added on new segments: each segment lists its new objects as placeholders (-400000000 - k, k the rank
		-- of the stop in edgeObjectsToAdd, then its side), as the stop replay does; without them the factory fails (a road
		-- joined to a street with stops: the tool takes the stops away and places them again on the new pieces)
		do
			local srcEdges = st.edgesToAdd or st.addedSegments or {}
			local k = 0
			for _, o in ipairs((EXP:find("noph") or EXP:find("noeo,")) and {} or st.edgeObjectsToAdd or {}) do
				if type(o) == "table" and o.model then
					for i, src in ipairs(srcEdges) do
						if type(src) == "table" and src.entity == o.segmentEntity and edges[i] then
							local okp, errp = pcall(function()
								local c = edges[i].comp
								local list = {}
								for j = 1, #c.objects do list[#list + 1] = { c.objects[j][1], c.objects[j][2] } end
								-- (a script's placeholder kept by a raw form is not given twice, see C.scriptEdgeObjects)
								local have = false
								if o.scriptKind ~= nil then for j = 1, #list do if list[j][1] == -400000000 - k then have = true end end end
								if not have then list[#list + 1] = { -400000000 - k, o.scriptKind or ((o.category == 2) and 2 or (o.left and 0 or 1)) } end
								c.objects = list
								edges[i].comp = c
							end)
							if not okp then C.errors[#C.errors + 1] = "stop placeholder " .. (k + 1) .. ": " .. tostring(errp):sub(1, 100) end
						end
					end
					k = k + 1
				end
			end
		end
		ssp.nodesToAdd = nodes
		ssp.edgesToAdd = edges
		ssp.nodesToRemove = entityList(st.nodesToRemove or st.removedNodes)
		ssp.edgesToRemove = entityList(st.edgesToRemove or st.removedSegments)
		-- the lane connections of the existing nodes a build touches refer to the old segments: their node
		-- configurations must go (the native tools do the same), or the engine fails a lookup (map_util Get assert)
		local cfgKeep = {}
		pcall(function()
			local touched, list = {}, {}
			local function touch(n)
				if type(n) == "number" and n >= 0 and not touched[n] then
					touched[n] = true
					local okc, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
					if okc and nc then list[#list + 1] = n end
				end
			end
			for _, e in ipairs(entityList(st.edgesToRemove or st.removedSegments)) do
				local be = type(e) == "number" and e >= 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if be then touch(be.node0); touch(be.node1) end
			end
			for _, sg in ipairs(st.edgesToAdd or st.addedSegments or {}) do
				if type(sg) == "table" and type(sg.comp) == "table" then touch(sg.comp.node0); touch(sg.comp.node1) end
			end
			for _, n in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do touched[n] = true end
			local keep = {}
			for _, n in ipairs(list) do
				local removed = false
				for _, r in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do if r == n then removed = true end end
				if not removed then keep[#keep + 1] = n end
			end
			-- the configurations the native proposal removed, when known (even none: a node the originator's engine kept must be
			-- kept here too), else the computed set; only those this game has (removing one that does not exist is an assertion)
			if type(st.nodeConfigsToRemove) == "table" then
				keep = {}
				for _, n in ipairs(entityList(st.nodeConfigsToRemove)) do
					local okc, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
					if okc and nc then keep[#keep + 1] = n end
				end
			end
			if #keep > 0 then ssp.nodeConfigsToRemove = keep end
			cfgKeep = keep
		end)
		C.rebuiltCfgs = { add = {}, rm = cfgKeep }
		-- and the configurations it added (lane connections, crosswalks, traffic lights), with the native ids: for the raw
		-- forms, and for a build that only changes configurations (a node window's double slip switch, issue #26), where
		-- they are the whole build
		local onlyConfigs = #nodes == 0 and #edges == 0 and #entityList(st.nodesToRemove or st.removedNodes) == 0
			and #entityList(st.edgesToRemove or st.removedSegments) == 0
		if (opts.raw or onlyConfigs) and #(st.nodeConfigsToAdd or {}) > 0 then
			local okc, errc = pcall(function() ssp.nodeConfigsToAdd = C.nodeConfigs(st.nodeConfigsToAdd) end)
			if not okc then C.errors[#C.errors + 1] = "node configs: " .. tostring(errc):sub(1, 120) end
			-- (0.7.1, issue #127: a node configured here already gets its configuration replaced, never a second one)
			if okc then
				C.rebuiltCfgs.add = st.nodeConfigsToAdd
				local gone = {}
				for _, r in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do gone[r] = true end
				local rm, nput = C.cfgGuard(st.nodeConfigsToAdd, cfgKeep, function(e) return gone[e] end)
				if nput > 0 then
					local okr, errr = pcall(function() ssp.nodeConfigsToRemove = rm end)
					if okr then C.rebuiltCfgs.rm = rm end
					C.errors[#C.errors + 1] = "node configs replaced: " .. nput .. (okr and "" or " (" .. tostring(errr):sub(1, 80) .. ")")
				end
			end
		elseif not onlyConfigs and #cfgKeep > 0 and #(st.nodeConfigsToAdd or {}) > 0 and os.getenv("MPFEVER_CFGREADD") ~= "0" then
			-- (0.7.6, issue #131) The other forms removed the configurations of the nodes the build touches (the tool's list) and
			-- added none: the engine makes a plain node's again, not a junction's with traffic lights. juliu, 2026-11-07 19:09, a
			-- tram tunnel's type changed from its window during a pause (2 segments replaced, the configurations of their 3 nodes
			-- removed and given again by the tool): node 35603, the traffic-light junction at the tunnel's end, was left without
			-- one, "it != components.end()" (BaseNodeConfig), the host crashed. The tool's configurations of the nodes whose
			-- configuration is removed here are given again, with this form's numbers of the new segments (as the tool does:
			-- a replacement, never a second one, see C.cfgGuard). MPFEVER_CFGREADD=0: none, as before
			local gone = {}
			for _, r in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do gone[r] = true end
			local put, left = C.readdedConfigs(st.nodeConfigsToAdd, cfgKeep, edgeMap, gone)
			if #put > 0 then
				local okc, errc = pcall(function() ssp.nodeConfigsToAdd = C.nodeConfigs(put) end)
				if okc then C.rebuiltCfgs.add = put end
				C.errors[#C.errors + 1] = "node configs given again: " .. #put .. (left > 0 and (" (" .. left .. " left: a new segment unknown)") or "")
					.. (okc and "" or (" (" .. tostring(errc):sub(1, 100) .. ")"))
			end
		end
		-- (the removed stops carry the originator's ids: this game's are found by their rank on the removed segments)
		do
			local idMap = C.existingObjectIds(st)
			local rmObjs = {}
			for _, id in ipairs(entityList(st.edgeObjectsToRemove)) do rmObjs[#rmObjs + 1] = idMap[id] or id end
			if not EXP:find("noeor") then ssp.edgeObjectsToRemove = rmObjs end
			if EXP ~= "" then C.errors[#C.errors + 1] = "stops removed {" .. table.concat(rmObjs, ",") .. "} (captured {" .. table.concat(entityList(st.edgeObjectsToRemove), ",") .. "})" end
		end
		local objs = {}
		local seenSided = {}
		for i, o in ipairs(EXP:find("noeo,") and {} or st.edgeObjectsToAdd or {}) do
			if EXP:find("oneside") and type(o) == "table" then
				local key = tostring(o.model) .. "@" .. tostring(o.segmentEntity) .. "@" .. string.format("%.3f", tonumber(o.param) or 0)
				if seenSided[key] then o = nil else seenSided[key] = true end
			end
			if type(o) == "table" and o.model then
				local eo = C.newOf("StreetEdgeObject")
				-- the new segment it goes on, by its rank in edgesToAdd (-1, -2...): the native id (-10...) made the factory fail
				local seIdx = nil
				for j, src in ipairs(st.edgesToAdd or st.addedSegments or {}) do
					if type(src) == "table" and src.entity == o.segmentEntity then seIdx = -j end
				end
				eo.edgeEntity = seIdx or o.segmentEntity
				eo.param = o.param or 0.5
				eo.oneWay = o.oneWay == true
				eo.left = o.left == true
				-- (without "::/": with it the factory fails or hangs, as for the stop replay)
				eo.model = tostring(o.model):gsub("^::/", "")
				local pl = o.playerEntity
				if type(pl) ~= "number" or pl < 0 then pl = api.engine.util.getPlayer() end
				eo.playerEntity = pl
				pcall(function() eo.name = o.name or "" end)
				C.setEdgeObjectParams(eo, o)
				objs[#objs + 1] = eo
			else
				C.errors[#C.errors + 1] = "edge object " .. i .. " without model (not replicated)"
			end
		end
		if #objs > 0 then ssp.edgeObjectsToAdd = objs end
		sp.streetProposal = ssp
	end
	return sp
end

-- A native Proposal (the type the construction tools produce) rebuilt from its compact form: street part only.
-- The engine accepts it as is (a SimpleProposal replacing existing segments is refused).
local function segmentFrom(s, where)
	local e = rebuild("SegmentAndEntity", s, where)
	if type(s.comp) == "table" and type(s.comp.distance) == "number" and s.comp.distance ~= 0 then
		pcall(function() local cd = e.comp; cd.distance = s.comp.distance; e.comp = cd end)
	end
	local tmpl = s.comp and s.comp.roadTemplate
	local custom = C.customLanes(s)
	local lanes = custom and C.rebuildLanes(custom) or C.templateLanes(tmpl)
	if not lanes and s.comp and type(s.comp.laneConfigs) == "table" then lanes = C.rebuildLanes(s.comp.laneConfigs) end
	if lanes then
		local c = e.comp
		c.laneConfigs = lanes
		e.comp = c
	end
	return e
end

-- {new id = {old ids}} maps; after reference translation they travel as { __pairs = { {k = id, v = {ids}} } }
local function idMap(m)
	if type(m) ~= "table" then return nil end
	local r = {}
	local entries = m.__pairs
	if not entries then
		entries = {}
		for k, v in pairs(m) do entries[#entries + 1] = { k = k, v = v } end
	end
	for _, en in ipairs(entries) do
		if type(en.k) == "number" and type(en.v) == "table" then
			local list = {}
			for i = 1, #en.v do list[i] = en.v[i] end
			r[en.k] = list
		end
	end
	return r
end

-- stage (diagnostics): how much of the street part is filled in, to find which assignment the factory refuses
-- 1 nothing, 2 +nodes, 3 +segments, 4 +removed nodes, 5 +removed segments, 6 +id maps (default: everything)
-- rm: how the removed segments are given: nil = rebuilt from the capture, "entity" = their id only, "live" = id and
-- the segment's current edge component in this game
function C.rebuildNativeProposal(m, stage, rm)
	stage = stage or 99
	local st = m.proposal
	if type(st) ~= "table" then error("no street part") end
	if #(m.toAdd or {}) > 0 or #(m.toRemove or {}) > 0 then error("constructions: not a street-only build") end
	local P = api.type.Proposal.new()
	local sp = P.proposal
	local nodes, edges, rnodes, redges = {}, {}, {}, {}
	local objIds = C.existingObjectIds(st)
	for i, n in ipairs(st.addedNodes or {}) do nodes[i] = rebuild("NodeAndEntity", n, "addedNodes[" .. i .. "]") end
	for i, s in ipairs(st.addedSegments or {}) do
		local c = s.comp or {}
		if type(c.objects) == "table" then
			local keep = {}
			for _, o in ipairs(c.objects) do if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then keep[#keep + 1] = { objIds[o[1]] or o[1], o[2] } end end
			c.objects = keep
		end
		edges[i] = segmentFrom(s, "addedSegments[" .. i .. "]")
	end
	for i, n in ipairs(st.removedNodes or {}) do rnodes[i] = rebuild("NodeAndEntity", n, "removedNodes[" .. i .. "]") end
	for i, s in ipairs(st.removedSegments or {}) do
		if rm and type(s.entity) == "number" then
			local se = rebuild("SegmentAndEntity", { entity = s.entity }, "removedSegments[" .. i .. "]")
			if rm == "live" then
				local okl, comp = pcall(function() return api.engine.getComponent(s.entity, api.type.ComponentType.BASE_EDGE) end)
				if okl and comp then pcall(function() se.comp = comp end) end
			end
			redges[i] = se
		else
			redges[i] = segmentFrom(s, "removedSegments[" .. i .. "]")
		end
	end
	if stage >= 2 then sp.addedNodes = nodes end
	if stage >= 3 then sp.addedSegments = edges end
	if stage >= 4 then sp.removedNodes = rnodes end
	if stage >= 5 then sp.removedSegments = redges end
	for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
		local mm = stage >= 6 and idMap(st[k])
		if mm then
			local okm, errm = pcall(function() sp[k] = mm end)
			if not okm then C.errors[#C.errors + 1] = k .. ": " .. tostring(errm):sub(1, 100) end
		end
	end
	if #(st.edgeObjectsToAdd or {}) > 0 then C.errors[#C.errors + 1] = "native form: stops not supported yet" end
	P.proposal = sp
	return P
end

-- The native proposal of a construction placed against a street (depot, station), rebuilt in this game from the tool's
-- capture: the construction itself (an engine-made native object, taken from the engine's own conversion of the same
-- construction: `conv` is that converted proposal), the street part as the tool made it (the junction node where the
-- entrance is stretched to the street, the split street), and the removed segments as the engine's own removal
-- proposal `rm` makes them. Returns the native Proposal.
-- The nodes a construction is "frozen" to (0-based indices in the proposal's added nodes): the free end of its own entrance
-- segment, which the tool stretched to the street. Captured with the build (toAdd[i].frozenNodes); for older captures, guessed:
-- the new ends of the construction's own segments that no other segment of the build uses.
local function isConSegment(sg)
	local tpl = tostring(sg and sg.comp and sg.comp.roadTemplate or "")
	-- (street entrances, the tracks of rail stations (simple, simple_catenary), the runways and taxiways of airports, the
	-- tracks of rail depots)
	return tpl:find("/constructions/", 1, true) ~= nil or tpl:find("/track/simple/simple[%w_]*%.street_template") ~= nil
		or tpl:find("/street/airport/", 1, true) ~= nil or tpl:find("/rail_depot[%w_]*%.street_template") ~= nil
end

function C.frozenNodesOf(m, i)
	local ce = m.toAdd and m.toAdd[i or 1]
	if type(ce) == "table" and type(ce.frozenNodes) == "table" and #ce.frozenNodes > 0 then return ce.frozenNodes, "captured" end
	-- captured empty (a road junction of the street tool: its streets are ordinary streets, it keeps no node): nothing is
	-- guessed. Guessed, the junction took the entrance node of the farm whose field it cut, stayed a construction on the
	-- replaying games only (one construction more: conParams, then a resynchronisation, a manual test 2026-10-22)
	if type(ce) == "table" and type(ce.frozenNodes) == "table" and ce.segmentsBefore ~= nil and os.getenv("MPFEVER_FROZENGUESS") ~= "1" then
		return {}, "captured (none)"
	end
	local st = m.proposal or {}
	local index = {}
	for k, n in ipairs(st.addedNodes or {}) do if type(n) == "table" and type(n.entity) == "number" then index[n.entity] = k - 1 end end
	local usedByStreet = {}
	for _, sg in ipairs(st.addedSegments or {}) do
		if not isConSegment(sg) and type(sg.comp) == "table" then usedByStreet[sg.comp.node0] = true usedByStreet[sg.comp.node1] = true end
	end
	local out, seen = {}, {}
	for _, sg in ipairs(st.addedSegments or {}) do
		if isConSegment(sg) and type(sg.comp) == "table" then
			for _, n in ipairs({ sg.comp.node0, sg.comp.node1 }) do
				if type(n) == "number" and index[n] and not usedByStreet[n] and not seen[n] then seen[n] = true out[#out + 1] = index[n] end
			end
		end
	end
	if #out > 0 then return out, "guessed" end
	return nil
end

-- The edge objects of a native proposal for a construction's signs: the engine's own native objects (native, from its
-- conversion of the construction: a script cannot write a native object's model), matched by model, place and side, each
-- put on its segment by the tool's native id. A missing one is an error: the caller then replays without them
-- (and resynchronises)
-- how (nil: as for the airports): how.byRank, the engine's objects of a dry run that lists the tool's objects in the tool's order,
-- copy after copy (G.eoDryRun in the bridge): the i-th is the tool's i-th (their model and place cannot be read, and the tests below
-- could take an object of the second copy); how.keepResult: the tool's placeholder of each new object (-400000000 - k, which the new
-- segment's list of objects names) as its result entity, else -1 as before
function C.nativeEdgeObjects(list, native, how)
	local out = {}
	-- Matched, in this order: same segment id (the conversion of the first copy numbers its segments as the tool did) and
	-- model; same model, place and side; same model; else by rank within the first copy (the conversion lists each copy's
	-- objects in turn, as the tool lists its own). Issue #50: model, place and side alone matched nothing.
	native = type(native) == "table" and native or {}
	local used = {}
	local function norm(v) return (tostring(v):gsub("^::/", ""):gsub("^/", "")) end
	local function field(x, k) local ok, v = pcall(function() return x[k] end) if ok then return v end return nil end
	local tests = {
		function(x, o) return field(x, "segmentEntity") == o.segmentEntity and norm(field(x, "model")) == norm(o.model) end,
		function(x, o) return norm(field(x, "model")) == norm(o.model) and math.abs((tonumber(field(x, "param")) or -9) - (tonumber(o.param) or 0)) < 1e-3
			and (field(x, "left") == true) == (o.left == true) end,
		function(x, o) return norm(field(x, "model")) == norm(o.model) end,
	}
	local function find(o, i)
		if type(how) == "table" and how.byRank then
			if native[i] ~= nil and not used[i] then used[i] = true return native[i] end
			return nil
		end
		for _, t in ipairs(tests) do
			for j, x in ipairs(native) do
				if not used[j] then
					local okx, same = pcall(t, x, o)
					if okx and same then used[j] = true return x end
				end
			end
		end
		if #list > 0 and #native >= #list and #native % #list == 0 and native[i] and not used[i] then used[i] = true return native[i] end
		return nil
	end
	-- (what the engine's objects look like, for the log when nothing matches)
	local function show(x)
		local t = {}
		for _, k in ipairs({ "model", "segmentEntity", "param", "left", "category" }) do t[#t + 1] = k .. "=" .. tostring(field(x, k)) end
		return table.concat(t, " ")
	end
	for i, o in ipairs(list or {}) do
		local eo = type(o) == "table" and find(o, i) or nil
		if type(o) ~= "table" or type(o.segmentEntity) ~= "number" or eo == nil then
			error("edge object " .. i .. " not converted (" .. show(o) .. "; the engine's first: " .. (native[1] and show(native[1]) or "none") .. ")")
		end
		eo.segmentEntity = o.segmentEntity
		local pl = o.playerEntity
		if type(pl) ~= "number" or pl < 0 then pl = api.engine.util.getPlayer() end
		pcall(function() eo.playerEntity = pl end)
		local re = -1
		if type(how) == "table" and how.keepResult and type(o.resultEntity) == "number" and o.resultEntity <= -400000000 then re = o.resultEntity end
		pcall(function() eo.resultEntity = re end)
		out[i] = eo
	end
	return out
end

-- The construction params of a replayed stop or signal (o.params, read from its EDGE_OBJECT on the builder's game: a path
-- signal's oneWay, its year), written on a script's edge object (a field the API does not list, kept by the engine). Without
-- them the replayed signal had {seed = 0} only, the builder's {oneWay = 2, seed = 0, year = 1948}: another signal on every
-- replaying game, which numbered its next entities otherwise (2026-10-26, 20 signals changed in their window, a reload).
-- MPFEVER_EOPARAMS=0: as before.
function C.setEdgeObjectParams(eo, o)
	if type(o) ~= "table" or type(o.params) ~= "table" or os.getenv("MPFEVER_EOPARAMS") == "0" then return false end
	local p = {}
	for k, v in pairs(o.params) do
		if type(k) == "string" and k:sub(1, 2) ~= "__" and (type(v) == "number" or type(v) == "string" or type(v) == "boolean") then p[k] = v end
	end
	if next(p) == nil then return false end
	return (pcall(function() eo.params = p end))
end

function C.rebuildNativeWithConstruction(m, conv, rm, opts)
	opts = opts or {}
	local st = m.proposal
	if type(st) ~= "table" then error("no street part") end
	local P = api.type.Proposal.new()
	-- (conv nil: a street build alone, e.g. a road cutting a street that carries stops, which only a native proposal moves)
	local fz = nil
	if conv then
		local conList = {}
		local ce = conv.toAdd[1]
		-- an industry the build reshapes (a street through a farm's field: the farm without that field) is the engine's own
		-- replacement of the existing one with the tool's parameters: the conversion builds it as a new industry, whose field
		-- slots fill themselves (autofill), all 20 fields back, on the streets around: refused, "Collision". MPFEVER_REPLACECON=0: off
		C.replacedCons = nil
		C.replaceKeep = {}
		local function replaced(i)
			local t = type(m.toAdd) == "table" and m.toAdd[i]
			if os.getenv("MPFEVER_REPLACECON") == "0" or type(t) ~= "table" or type(t.params) ~= "table"
				or not tostring(t.fileName):find("/industries/", 1, true) or type(m.old2newByRank) ~= "table" then return nil end
			local old = nil
			for r, e in ipairs(entityList(m.toRemove or m.constructionsToRemove)) do
				local v = m.old2newByRank[r] or m.old2newByRank[tostring(r)]
				if v == i - 1 then old = e end
			end
			if type(old) ~= "number" or old < 0 then return nil end
			local okp, rp = pcall(function() return api.engine.util.proposal.createProposalReplaceConstruction(old, plain(t.params)) end)
			local okc, c = pcall(function() return okp and rp and rp.toAdd[1] end)
			if not okp or not okc or not c then
				C.errors[#C.errors + 1] = "replacement of " .. tostring(old) .. ": " .. tostring(okp and c or rp):sub(1, 120)
				return nil
			end
			C.replaceKeep[#C.replaceKeep + 1] = rp
			local n = 0
			pcall(function() for _ in pairs(c.construction.params.modules) do n = n + 1 end end)
			C.replacedCons = (C.replacedCons and (C.replacedCons .. ", ") or "") .. tostring(t.fileName):match("[^/]*$") .. " " .. old .. " (" .. n .. " modules)"
			return c
		end
		local r1 = replaced(1)
		if r1 then ce = r1 end
		-- the engine's conversion numbers the construction's nodes in its own proposal: they are this build's (see C.frozenNodesOf)
		local how
		C.frozenHow = nil
		fz, how = C.frozenNodesOf(m, 1)
		if fz and not opts.keepFrozen then
			local okf, ef = pcall(function()
				local l = {}
				for k, v in ipairs(fz) do l[k] = v end
				ce.frozenNodes = l
				local sb = m.toAdd[1] and m.toAdd[1].segmentsBefore
				ce.segmentsBefore = type(sb) == "number" and sb or 0
			end)
			C.frozenHow = okf and how or ("not written: " .. tostring(ef):sub(1, 80))
		end
		conList[1] = ce
		-- the other constructions of the build (a junction cutting a farm's field: the farm rebuilt without that field), in the
		-- tool's order: the removed farm's old2new points at them. With the first one only, the command could not be made
		-- ("Unknown exception") and the junction was not reproduced
		if os.getenv("MPFEVER_ALLCONS") ~= "0" then
			for i = 2, #(m.toAdd or {}) do
				local c = replaced(i)
				if not c then c = conv.toAdd[i] end
				-- (its own frozen nodes and segment count as the tool gave them: the farm's entrance, see C.frozenNodesOf)
				local fzi = C.frozenNodesOf(m, i)
				if fzi and not opts.keepFrozen then
					local okf, ef = pcall(function()
						local l = {}
						for k, v in ipairs(fzi) do l[k] = v end
						c.frozenNodes = l
						local sb = m.toAdd[i].segmentsBefore
						c.segmentsBefore = type(sb) == "number" and sb or 0
					end)
					if not okf then C.errors[#C.errors + 1] = "frozenNodes of " .. i .. ": " .. tostring(ef):sub(1, 80) end
				end
				conList[i] = c
			end
		end
		P.toAdd = conList
	end
	-- an edited construction (a module added to a street station): the old one is replaced, and old2new keeps its
	-- stations (the lines stopping there keep their stops). Without them the new one collided with the old (issue #14).
	-- (without a construction: the town buildings the street build takes away)
	local removeList = entityList(m.toRemove or m.constructionsToRemove)
	-- (opts.townAuto: a street through a town whose engine takes the town buildings away and puts them back itself. Named here,
	-- the engine took the same ones away but put them back elsewhere than the builder's tool: other ground, another cost, the
	-- towns drifted apart - a 2-segment upgrade: 929986 instead of the builder's 926311; without the list, 926311 and the same
	-- ground, issue #79. MPFEVER_TOWNREMOVE=1: named as before)
	if opts.townAuto and os.getenv("MPFEVER_TOWNREMOVE") ~= "1" then removeList = {} end
	if #removeList > 0 and os.getenv("MPFEVER_CONREMOVE") ~= "0" then
		local okr, er = pcall(function() P.toRemove = removeList end)
		if not okr then C.errors[#C.errors + 1] = "toRemove: " .. tostring(er):sub(1, 100) end
		if conv and type(m.old2newByRank) == "table" then
			local okm, em = pcall(function()
				local map = {}
				for i, e in ipairs(removeList) do
					local v = m.old2newByRank[i] or m.old2newByRank[tostring(i)]
					if v ~= nil then map[e] = v end
				end
				P.old2new = map
			end)
			if not okm then C.errors[#C.errors + 1] = "old2new: " .. tostring(em):sub(1, 100) end
		end
	end
	local sp = P.proposal
	local nodes, edges = {}, {}
	local objIds = C.existingObjectIds(st)
	for i, n in ipairs(st.addedNodes or {}) do nodes[i] = rebuild("NodeAndEntity", n, "addedNodes[" .. i .. "]") end
	for i, sg in ipairs(st.addedSegments or {}) do
		local c = sg.comp or {}
		if type(c.objects) == "table" then
			local keep = {}
			for _, o in ipairs(c.objects) do
				if type(o) == "table" and type(o[1]) == "number" then
					if o[1] >= 0 then keep[#keep + 1] = { objIds[o[1]] or o[1], o[2] }
					-- (the tool's placeholders of its new edge objects, -400000000 - k: kept with them, see C.nativeEdgeObjects)
					elseif opts.withObjects and o[1] <= -400000000 then keep[#keep + 1] = { o[1], o[2] } end
				end
			end
			c.objects = keep
		end
		edges[i] = segmentFrom(sg, "addedSegments[" .. i .. "]")
	end
	local stage = opts.stage or 99
	if stage >= 2 then sp.addedNodes = nodes end
	if stage >= 3 then sp.addedSegments = edges end
	if stage < 3 then P.proposal = sp return P end
	if rm and stage >= 3 then
		local rsp = rm.proposal
		local ok1, e1 = pcall(function() sp.removedSegments = rsp.removedSegments end)
		if not ok1 then C.errors[#C.errors + 1] = "removedSegments: " .. tostring(e1):sub(1, 100) end
		local ok2, e2 = pcall(function()
			if opts.toolNodes then
				local rnodes = {}
				for i, n in ipairs(st.removedNodes or {}) do rnodes[i] = rebuild("NodeAndEntity", n, "removedNodes[" .. i .. "]") end
				sp.removedNodes = rnodes
			else
				sp.removedNodes = rsp.removedNodes
			end
		end)
		if not ok2 then C.errors[#C.errors + 1] = "removedNodes: " .. tostring(e2):sub(1, 100) end
		-- the stops and signals the tool removed (it re-creates them on a new segment, placed afterwards here, see
		-- placeStopsAfter in the bridge): this game's ids, found by their rank on the removed segments. Only the tool's
		-- list: the removal proposal's own would also remove the objects the build moves to its new segments (issue #28)
		local rmObjs = {}
		for _, id in ipairs(entityList(st.edgeObjectsToRemove)) do rmObjs[#rmObjs + 1] = objIds[id] or id end
		if #rmObjs > 0 then
			local oko, eo = pcall(function() sp.edgeObjectsToRemove = rmObjs end)
			if not oko then C.errors[#C.errors + 1] = "edgeObjectsToRemove: " .. tostring(eo):sub(1, 100) end
		end
	end
	-- the tool's new edge objects (an airport's signs on its own runways and taxiways), as the tool's proposal has them (opts.eoByRank:
	-- the stops and signals a street build re-creates, from a dry run, see C.nativeEdgeObjects; MPFEVER_EORESULT=-1: their result
	-- entity -1, as the airports' signs)
	if opts.withObjects and #(st.edgeObjectsToAdd or {}) > 0 then
		local how = opts.eoByRank and { byRank = true, keepResult = os.getenv("MPFEVER_EORESULT") ~= "-1" } or nil
		local okn, en = pcall(function() sp.edgeObjectsToAdd = C.nativeEdgeObjects(st.edgeObjectsToAdd, opts.withObjects, how) end)
		if not okn then error("edge objects: " .. tostring(en):gsub("^.-:%d+: ", ""):sub(1, 700)) end
	end
	-- the node configurations (lane connections...) the tool removed: only those this game has (removing one that does not
	-- exist is an engine assertion), and those it added, with the native ids
	if stage < 4 then P.proposal = sp return P end
	local cfgRemove = {}
	for _, n in ipairs(opts.noConfigs and {} or entityList(st.nodeConfigsToRemove)) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then cfgRemove[#cfgRemove + 1] = n end
	end
	-- (0.7.1, issue #127: the configurations it adds to nodes configured here already replace theirs, see C.cfgGuard)
	if not opts.noConfigs and #(st.nodeConfigsToAdd or {}) > 0 then
		local gone = {}
		for _, r in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do gone[r] = true end
		local _, nput = C.cfgGuard(st.nodeConfigsToAdd, cfgRemove, function(e) return gone[e] end)
		if nput > 0 then C.errors[#C.errors + 1] = "node configs replaced: " .. nput end
	end
	if #cfgRemove > 0 then
		local okc, ec = pcall(function() sp.nodeConfigsToRemove = cfgRemove end)
		if not okc then C.errors[#C.errors + 1] = "nodeConfigsToRemove: " .. tostring(ec):sub(1, 100) end
	end
	if #(st.nodeConfigsToAdd or {}) > 0 and not opts.noConfigs then
		local okc, errc = pcall(function()
			local cfgs = {}
			for i, mcfg in ipairs(st.nodeConfigsToAdd) do
				local o = api.type.BaseNodeLaneConnectionAndEntity.new()
				o.entity = mcfg.entity
				local cfg = o.comp
				local mc = mcfg.comp or {}
				local lcs = {}
				for j, l in ipairs(mc.laneConnections or {}) do
					local lc = api.type.LaneConnection.new()
					lc.segment0 = l.segment0; lc.lane0 = l.lane0; lc.segment1 = l.segment1; lc.lane1 = l.lane1
					lc.withRoad = l.withRoad == true; lc.withTram = l.withTram == true
					lcs[j] = lc
				end
				cfg.laneConnections = lcs
				local cw = {}
				for j, x in ipairs(mc.crosswalks or {}) do cw[j] = x end
				cfg.crosswalks = cw
				pcall(function() cfg.trafficLightPreference = mc.trafficLightPreference end)
				pcall(function() cfg.doubleSlipSwitch = mc.doubleSlipSwitch == true end)
				pcall(function() cfg.userModifiedLaneConnections = mc.userModifiedLaneConnections == true end)
				o.comp = cfg
				cfgs[i] = o
			end
			sp.nodeConfigsToAdd = cfgs
		end)
		if not okc then C.errors[#C.errors + 1] = "nodeConfigsToAdd: " .. tostring(errc):sub(1, 120) end
	end
	-- the street part's own list of frozen nodes (the tool's: the construction's nodes)
	local pfz = (type(st.frozenNodes) == "table" and #st.frozenNodes > 0) and st.frozenNodes or fz
	if pfz and not opts.noMaps then
		local l = {}
		for i, v in ipairs(pfz) do l[i] = v end
		local okf, ef = pcall(function() sp.frozenNodes = l end)
		if not okf then C.errors[#C.errors + 1] = "frozenNodes: " .. tostring(ef):sub(1, 100) end
	end
	for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
		local mm = (not opts.noMaps) and idMap(st[k]) or nil
		if mm then
			local okm, errm = pcall(function() sp[k] = mm end)
			if not okm then C.errors[#C.errors + 1] = k .. ": " .. tostring(errm):sub(1, 100) end
		end
	end
	-- (opts.eoMaps, with the engine's own objects of a street build: the tool's maps of the objects it re-created, the old ones by
	-- this game's ids (their rank on the removed segments), the new ones by the tool's placeholders, as the tool had them: a track
	-- upgrade said that its new signal -400000000 replaces the old one)
	if opts.eoMaps and opts.withObjects and not opts.noMaps then
		local function tr(id) if type(id) == "number" and id >= 0 then return objIds[id] or id end return id end
		for _, k in ipairs({ "new2oldEdgeObjects", "old2newEdgeObjects" }) do
			local mm = idMap(st[k])
			if mm and next(mm) ~= nil then
				local okm, errm = pcall(function()
					local out = {}
					for key, list in pairs(mm) do
						local l = {}
						for i, v in ipairs(list) do l[i] = tr(v) end
						out[tr(key)] = l
					end
					sp[k] = out
				end)
				if not okm then C.errors[#C.errors + 1] = k .. ": " .. tostring(errm):sub(1, 100) end
			end
		end
	end
	P.proposal = sp
	return P
end

function C.proposalHasConstructions(m)
	return type(m) == "table" and #(m.constructionsToAdd or m.toAdd or {}) > 0
end

-- A native map read WITHOUT indexing it: map[k] on a C++ map inserts the key, which corrupts the live proposal
-- (the engine then loops forever applying it).
function C.marshalMap(v)
	if v == nil then return nil end
	local r = {}
	local ok = pcall(function()
		for k, x in pairs(v) do
			local list = {}
			pcall(function() for _, y in pairs(x) do list[#list + 1] = y end end)
			r[k] = list
		end
	end)
	return ok and r or nil
end

-- whether a street part says which new segments or nodes replace which old ones (maps as shipped: __pairs, or plain)
function C.hasReplaceMaps(st)
	if type(st) ~= "table" then return false end
	for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
		local t = st[k]
		if type(t) == "table" and next(t.__pairs or t) ~= nil then return true end
	end
	return false
end

-- for the logs: how many entries the replacement maps of a compact proposal have (", maps segments 2/2 nodes 1/1")
function C.mapSizes(m)
	local st = type(m) == "table" and m.proposal
	if type(st) ~= "table" then return "" end
	local function n(t)
		local c = 0
		if type(t) == "table" then for _ in pairs(t.__pairs or t) do c = c + 1 end end
		return c
	end
	local a, b, c, d, e, f = n(st.new2oldSegments), n(st.old2newSegments), n(st.new2oldNodes), n(st.old2newNodes), n(st.new2oldEdgeObjects), n(st.old2newEdgeObjects)
	if a + b + c + d + e + f == 0 then return "" end
	return ", maps segments " .. a .. "/" .. b .. " nodes " .. c .. "/" .. d .. " objects " .. e .. "/" .. f
end

-- compact, serializable form of a native Proposal (from the construction tools): only what a replay needs
function C.compactProposal(p)
	local function get(o, k)
		local ok, v = pcall(function() return o[k] end)
		if ok then return v end
		return nil
	end
	local out = { toAdd = {}, toRemove = C.marshal(get(p, "toRemove")) or {}, old2new = C.marshal(get(p, "old2new")) }
	-- old2new is keyed by the removed constructions' entity ids, which differ between games: shipped by their rank in
	-- toRemove (references there are translated), rebuilt with each game's own ids
	pcall(function()
		if type(out.old2new) ~= "table" then return end
		local byRank = {}
		for i, e in ipairs(out.toRemove) do
			local v = out.old2new[e]
			if v ~= nil then byRank[i] = v end
		end
		out.old2newByRank = byRank
	end)
	local toAdd = get(p, "toAdd") or get(p, "constructionsToAdd")
	local n = 0
	pcall(function() n = #toAdd end)
	for i = 1, n do
		local ce = toAdd[i]
		local params = get(ce, "params")
		if params == nil then
			local con = get(ce, "construction")
			if con ~= nil then params = get(con, "params") end
		end
		out.toAdd[i] = {
			fileName = get(ce, "fileName"),
			params = C.marshal(params),
			transf = C.marshal(get(ce, "transf")),
			playerEntity = get(ce, "playerEntity"),
			name = get(ce, "name"),
			hq = get(ce, "setAsHeadquarterHack") == true or nil,
			-- (the nodes of the street part the construction is attached to, see C.frozenNodesOf)
			frozenNodes = C.marshal(get(ce, "frozenNodes")),
			segmentsBefore = get(ce, "segmentsBefore"),
		}
	end
	local st = get(p, "proposal") or get(p, "streetProposal")
	if st ~= nil then
		out.proposal = {
			addedNodes = C.marshal(get(st, "addedNodes")) or {},
			addedSegments = C.marshal(get(st, "addedSegments")) or {},
			removedNodes = C.marshal(get(st, "removedNodes")) or {},
			removedSegments = C.marshal(get(st, "removedSegments")) or {},
			edgeObjectsToAdd = C.marshal(get(st, "edgeObjectsToAdd")) or {},
			edgeObjectsToRemove = C.marshal(get(st, "edgeObjectsToRemove")) or {},
			nodeConfigsToAdd = C.marshal(get(st, "nodeConfigsToAdd")) or {},
			nodeConfigsToRemove = C.marshal(get(st, "nodeConfigsToRemove")) or {},
			frozenNodes = C.marshal(get(st, "frozenNodes")),
		}
		-- which new segments and nodes replace which old ones (a track joined to an existing one, a signal put on a segment):
		-- the engine charges nothing for a replaced part and carries over what was on it. Rebuilt without them, every game
		-- paid for the replaced parts and the simulation drifted apart
		for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes", "new2oldEdgeObjects", "old2newEdgeObjects" }) do
			local mm = C.marshalMap(get(st, k))
			if mm and next(mm) ~= nil then out.proposal[k] = mm end
		end
	end
	return out
end

C.ARGS = {
	makeWorldBuildProposalCmd = { "Proposal", "Context" },
	makeVehicleBuyCmd = { false, false, "TransportVehicleConfig" },
	makeVehicleReplaceCmd = { false, "TransportVehicleConfig" },
	makeLineCreateCmd = { false, "Vec3f", false, "Line" },
	makeLineUpdateCmd = { false, "Line" },
	makeEntitySetColorCmd = { false, "Vec3f" },
	makeJournalBookAssetCmd = { false, "JournalEntry", "Vec3f" },
}

-- The interface's refundable entities (api.gui.construction.getRefundableEntities(): {{entity, n} = {revision, updateCount}}, what
-- this player just built; the engine gives its cost back when it is demolished while unchanged) as a list that can be shipped
function C.refundList(raw)
	local list = {}
	for k, v in pairs(raw or {}) do
		local num = v[1] and v[1].num
		if type(k) == "table" and type(k[1]) == "number" and num then
			list[#list + 1] = { e = k[1], x = k[2], r = { num[1], num[2], num[3] }, n = v[2] }
		end
	end
	return list
end

-- ... and back, for a Context's refundableEntities: the revision is this game's own of that entity (no Revision can be made in
-- Lua), and only when it is the one the builder's game had (the entity unchanged since, as there)
function C.toRefund(list)
	local out = {}
	for _, it in ipairs(list or {}) do
		local okr, rev = pcall(function() return api.engine.getRevision(it.e) end)
		local num = okr and rev and rev.num
		if num and type(it.r) == "table" and num[1] == it.r[1] and num[2] == it.r[2] and num[3] == it.r[3] then
			out[{ it.e, it.x }] = { rev, it.n }
		end
	end
	return out
end

function C.rebuildArgs(fn, margs, opts)
	C.errors = {}
	local types = C.ARGS[fn] or {}
	local args = {}
	local n = margs.n or #margs
	for i = 1, n do
		local m = margs[i]
		local tn = types[i]
		if type(m) ~= "table" then
			args[i] = m
		elseif tn == "Proposal" then
			if opts.variant == "native" then args[i] = C.rebuildNativeProposal(m, nil, opts.rm) else args[i] = C.rebuildProposal(m, opts) end
		elseif tn == "Context" and m.__player then
			-- the build context of the native tools: this game's player (opts.ctx selects the flags)
			local k = opts.ctx or "terrain"
			if k == "nil" then
				args[i] = nil
			else
				local ctx = api.type.Context.new()
				ctx.checkTerrainAlignment = (k == "terrain" or k == "terrainNoCleanup")
				ctx.cleanupStreetGraph = (k ~= "terrainNoCleanup" and k ~= "plainNoCleanup")
				ctx.gatherBuildings = (k == "terrain" or k == "terrainNoCleanup")
				ctx.gatherFields = true
				ctx.player = api.engine.util.getPlayer()
				-- (the builder's refundable entities, see G.refundInto in the bridge)
				if type(opts.refund) == "table" then pcall(function() ctx.refundableEntities = C.toRefund(opts.refund) end) end
				args[i] = ctx
			end
		elseif tn == "Context" then
			local okc, ctx = pcall(function() return fill(C.newOf("Context"), m, "Context", "context") end)
			args[i] = okc and ctx or nil
		elseif tn then
			args[i] = rebuild(tn, m, fn .. "#" .. i)
		elseif (m.__ud and not isVec(m)) or m.__unknown then
			error("argument " .. i .. " is a native object without rebuild rule")
		else
			args[i] = plain(m)
		end
	end
	return args, n
end

-- every command factory of api.cmd (pairs() cannot enumerate the native table)
C.FACTORIES = {
	"makeAnimalSetStateCmd", "makeAnimalSpawnAtCmd", "makeCreateIndustryExtendProposalCmd", "makeCustomEntityCreateCmd",
	"makeCustomEntityDestroyCmd", "makeCustomEntityUpdateStateCmd", "makeCustomEntityUpdateTransformationCmd",
	"makeCustomVehicleCreateOrUpdateCmd", "makeEntitySetColorCmd", "makeEntitySetEmissionsCmd", "makeEntitySetNameCmd",
	"makeEntitySetPlayerCmd", "makeGameAddPlayerCmd", "makeGameSetCalendarSpeedCmd", "makeGameSetCloudCoverageCmd",
	"makeGameSetDateCmd", "makeGameSetSpeedCmd", "makeGameSetTimeOfDayCmd", "makeIndustrySetDespawnTimeCmd",
	"makeIndustrySetManualDevelopmentCmd", "makeJournalBookAssetCmd", "makeJournalClearAllCmd", "makeJournalLogEntryCmd",
	"makeLineCreateCmd", "makeLineDestroyCmd", "makeLineUpdateCmd", "makeScriptingSendEventCmd",
	"makeStockListDiscardCargoCmd", "makeStockListSetModifiersCmd", "makeStockListSetStocksCargoTypeCmd",
	"makeTownAutoDetectConnectionsCmd", "makeTownBuildingSetBlockedDevelopmentCmd", "makeTownConnectWithIndustriesCmd",
	"makeTownCreateCmd", "makeTownCustomDistributionWeightsCmd", "makeTownDestroyCmd", "makeTownDevelopAtCmd",
	"makeTownSetDevelopmentActiveCmd", "makeTownSetInitialLandUseCapacitiesCmd", "makeTownUpdateCargoNeedsCmd",
	"makeTownUpdateSizeCmd", "makeVehicleBuyCmd", "makeVehicleReplaceCmd", "makeVehicleReverseCmd", "makeVehicleSellCmd",
	"makeVehicleSendToDepotCmd", "makeVehicleSetLineCmd", "makeVehicleSetManualDepartureCmd", "makeVehicleSetModifiersCmd",
	"makeVehicleSetStoppedByUserCmd", "makeVehicleTryToDepartCmd", "makeWorldBuildProposalCmd", "makeWorldChangeWindCmd",
	"makeWorldReplaceTerrainCmd", "makeWorldSetBulldozableCmd",
}

-- the ranks of the companies (mpfever_progression.lua), loaded once per Lua state; false when it cannot be loaded
-- the companies' economy (mpfever_eco.lua: mixed modes, bankruptcy, tolls), loaded once per Lua state
function C.eco()
	if C.ECO == nil then
		local ok, m = pcall(ug_require, "mpfever_eco.lua")
		if not (ok and type(m) == "table") then ok, m = pcall(ug_require, "mpfever_1::/mpfever_eco.lua") end
		C.ECO = (ok and type(m) == "table") and m or false
	end
	return C.ECO or nil
end

function C.progression()
	if C.PG == nil then
		local ok, m = pcall(ug_require, "mpfever_progression.lua")
		if not (ok and type(m) == "table") then ok, m = pcall(ug_require, "mpfever_1::/mpfever_progression.lua") end
		C.PG = (ok and type(m) == "table") and m or false
	end
	return C.PG or nil
end

-- (0.6) the game options host (mpfever_feat.lua: the feature modules, their options and hooks), loaded once per Lua state; nil
-- when it cannot be loaded (no option then works anywhere: the game plays as 0.5.14)
function C.feat()
	if C.FEAT == nil then
		local ok, m = pcall(ug_require, "mpfever_feat.lua")
		if not (ok and type(m) == "table") then ok, m = pcall(ug_require, "mpfever_1::/mpfever_feat.lua") end
		C.FEAT = (ok and type(m) == "table") and m or false
	end
	return C.FEAT or nil
end

-- Companies mode: the arguments of a command that name something its company must own (see the bridge's executeAction):
-- the vehicle, the line, the depot a vehicle is bought in, the entity renamed or recoloured
C.OWNER_ARGS = {
	makeVehicleSellCmd = { 1 }, makeVehicleSetLineCmd = { 1, 2 }, makeVehicleSendToDepotCmd = { 1, 3 }, makeVehicleReverseCmd = { 1 },
	makeVehicleReplaceCmd = { 1 }, makeVehicleSetStoppedByUserCmd = { 1 }, makeVehicleSetManualDepartureCmd = { 1 },
	makeVehicleTryToDepartCmd = { 1 }, makeVehicleSetModifiersCmd = { 1 }, makeVehicleBuyCmd = { 2 },
	makeLineUpdateCmd = { 1 }, makeLineDestroyCmd = { 1 }, makeEntitySetNameCmd = { 1 }, makeEntitySetColorCmd = { 1 },
}

-- Companies mode: the smallest toll per stop of a station (the rules of the stations are read by mpfever_eco.lua's stationRule
-- since 0.5.2: open by default, a toll or private by its company's rule or its own setting). C.shareFee is how 0.5.1 read them
-- (a station absent from reg.shares shared for this fee, 0 = not shared): kept for the bridge when mpfever_eco.lua is missing.
C.SHARE_DEFAULT = 100
function C.shareFee(shares, key)
	local f = shares and key and shares[key]
	if f == nil then return C.SHARE_DEFAULT end
	return f
end

-- ---------------------------------------------------------------- personal mods (0.5.0)
-- A player's load of the host's game, as the launcher planned it (load_mods.txt, see Mods.LoadPlan in the launcher): the
-- host's personal mods this player does not run are left out, this player's own are added. nil when there is no plan.
function C.loadPlan()
	local f = C.IO and C.DIR and C.IO.open(C.DIR .. BS .. "load_mods.txt", "rb")
	if not f then return nil end
	local s = f:read("*a") or ""
	f:close()
	local plan = { drop = {}, add = {}, n = 0 }
	for line in s:gmatch("[^" .. NL .. CR .. "]+") do
		local k, id = line:match("^(%a+)" .. string.char(9) .. "(.+)$")
		if k == "drop" then plan.drop[id] = true; plan.n = plan.n + 1
		elseif k == "add" then plan.add[#plan.add + 1] = id; plan.n = plan.n + 1 end
	end
	if plan.n == 0 then return nil end
	return plan
end

-- a savegame's mods (a ModId list) with a plan applied: the new list, the mods left out and those added (installed ones only)
function C.planMods(mods, plan)
	local out, dropped, added, seen = {}, {}, {}, {}
	for _, m in ipairs(mods or {}) do
		if plan.drop[m.name] then dropped[#dropped + 1] = m.name else out[#out + 1] = m; seen[m.name] = true end
	end
	local rep
	pcall(function() rep = app.getUserProfile():getModRep() end)
	for _, id in ipairs(plan.add) do
		if not seen[id] then
			local m = api.type.ModId.new()
			m.name = id
			local ok, ex = pcall(function() return rep and rep:exists(m) end)
			if ok and ex then out[#out + 1] = m; added[#added + 1] = id; seen[id] = true end
		end
	end
	return out, dropped, added
end

-- loads a savegame of this player (the host's game) with the plan: its details are read first, which takes a few frames
-- (later(fn) calls fn at a coming frame). Without a plan, or without the details, it loads with its own mods as before.
-- (0.7.7) the DLCs the host switched off for this session (dlc_drop.txt, see ApplyDlcOff in the launcher; MPFEVER_DLCOFFTEST for the
-- tests), as a set, or nil when none. MPFEVER_DLCSESSION=0: none
function C.dlcOffList()
	if os.getenv("MPFEVER_DLCSESSION") == "0" then return nil end
	local off, n = {}, 0
	for id in tostring(os.getenv("MPFEVER_DLCOFFTEST") or ""):gmatch("[^,%s]+") do off[id] = true; n = n + 1 end
	local f = C.IO and C.DIR and C.IO.open(C.DIR .. BS .. "dlc_drop.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		for id in s:gmatch("off" .. string.char(9) .. "([^" .. NL .. CR .. "]+)") do off[id] = true; n = n + 1 end
	end
	return n > 0 and off or nil
end

-- (0.7.7) a mod list without the session's DLCs that are off (those whose savegame entry says source "DLC"): the list and those left out
function C.dropDlcs(mods, off, descs)
	if not off then return mods, {} end
	local out, dropped = {}, {}
	for _, m in ipairs(mods or {}) do
		local d = descs and descs[m.name]
		if off[m.name] and d and d.modSource == "DLC" then dropped[#dropped + 1] = m.name else out[#out + 1] = m end
	end
	return out, dropped
end

function C.loadWithPlan(id, logf, later)
	local plan = C.loadPlan()
	-- (0.7.7: also for the DLCs off for this session, see C.dlcOffList; nothing to change: loaded with its own mods, as before)
	local off = C.dlcOffList()
	if not plan and not off then app.loadGame(id, false) return end
	local ok, async = pcall(app.getSavegameInfo, id)
	if not ok or not async then
		logf("personal mods: the savegame's details cannot be read here, loaded with its own mods")
		app.loadGame(id, false)
		return
	end
	local tries = 0
	local function poll()
		tries = tries + 1
		local okc, done = pcall(function() return async:isCompleted() end)
		if okc and not done and tries < 600 then later(poll) return end
		local info
		if okc and done then
			local okg, d = pcall(function() return async:get() end)
			if okg and d and d.info then info = d.info end
		end
		if not info then
			logf("personal mods: the savegame's details did not come, loaded with its own mods")
			app.loadGame(id, false)
			return
		end
		local details = api.type.SaveGameDetails.new(info)
		local mods, dropped, added = info.mods, {}, {}
		if plan then mods, dropped, added = C.planMods(info.mods, plan) end
		local descs = {}
		pcall(function() for _, d in ipairs(info.metadata.gameModDescs or {}) do if d.modId and d.modId.name then descs[d.modId.name] = d end end end)
		local offOut
		mods, offOut = C.dropDlcs(mods, off, descs)
		details.mods = mods
		if plan then
			logf("personal mods: the host's game loaded without " .. (#dropped > 0 and table.concat(dropped, ", ") or "none") .. ", with "
				.. (#added > 0 and table.concat(added, ", ") or "none") .. " added")
		end
		if #offOut > 0 then logf("DLC " .. table.concat(offOut, ", ") .. " switched off for this session (every game runs without it)") end
		app.loadGame(id, false, details)
	end
	later(poll)
end

return C
