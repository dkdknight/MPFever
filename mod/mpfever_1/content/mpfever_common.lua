-- MPFever common code, shared by the game-script state (link + execution) and the UI state (interception).
-- No backslash characters on purpose: special characters are built with string.char.

local C = {}

C.BS = string.char(92)
C.NL = string.char(10)
C.CR = string.char(13)
C.TAB = string.char(9)
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
-- a text with one %s (put in with gsub: the value may contain % itself)
function C.Tf(fr, en, value)
	local s = C.T(fr, en):gsub("%%s", function() return tostring(value) end)
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
	Waypoint = { "api.type.Waypoint" },
	EdgePos = { "api.type.EdgePos" },
	EdgeId = { "api.type.EdgeId" },
}

-- fields needing a specific type; false = derived by the engine, never copied; absent = copied generically
local SCHEMA = {
	NodeAndEntity = { comp = "BaseNode" },
	BaseNode = { position = "Vec3f" },
	SegmentAndEntity = { comp = "BaseEdge", streetEdge = "BaseEdgeStreet", playerOwned = "PlayerOwned", emissionEmitter = false, params = false },
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
		o.comp = cfg
		cfgs[i] = o
	end
	return cfgs
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
	return table.concat(parts, "/")
end

-- Whether replaying a command can reach onPreBuildProposal (and must be marked as a replay so that it is not shipped
-- again). Vehicles, lines, names, events... never do: counting them while the game time stood still (a paused session)
-- made every later build of the player look like a replay, and none was shipped (issue #12).
local NO_PROPOSAL_PREFIXES = { "makeVehicle", "makeLine", "makeEntitySet", "makeScriptingSendEvent", "makeGameSet",
	"makeJournal", "makeStockList", "makeTownSet", "makeTownBuildingSet", "makeIndustrySet" }
function C.makesProposal(fn)
	fn = tostring(fn)
	for _, p in ipairs(NO_PROPOSAL_PREFIXES) do
		if fn:sub(1, #p) == p then return false end
	end
	return true
end

-- Proposal (native, from the construction tools) or SimpleProposal -> SimpleProposal for makeWorldBuildProposalCmd
-- opts.noStreet: constructions only (their .con template regenerates its own street connector)
-- opts.seed: deterministic seed for constructions that have none (a script ConstructionEntity needs params.seed)
function C.rebuildProposal(m, opts)
	opts = opts or {}
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
		if not opts.raw then C.renumberStreet(st) end
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
								list[#list + 1] = { -400000000 - k, (o.category == 2) and 2 or (o.left and 0 or 1) }
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
		end)
		-- and the configurations it added (lane connections, crosswalks, traffic lights), with the native ids: for the raw
		-- forms, and for a build that only changes configurations (a node window's double slip switch, issue #26), where
		-- they are the whole build
		local onlyConfigs = #nodes == 0 and #edges == 0 and #entityList(st.nodesToRemove or st.removedNodes) == 0
			and #entityList(st.edgesToRemove or st.removedSegments) == 0
		if (opts.raw or onlyConfigs) and #(st.nodeConfigsToAdd or {}) > 0 then
			local okc, errc = pcall(function() ssp.nodeConfigsToAdd = C.nodeConfigs(st.nodeConfigsToAdd) end)
			if not okc then C.errors[#C.errors + 1] = "node configs: " .. tostring(errc):sub(1, 120) end
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
	return tpl:find("/constructions/", 1, true) ~= nil or tpl:find("/track/simple/simple[%w_]*%.street_template") ~= nil
end

function C.frozenNodesOf(m, i)
	local ce = m.toAdd and m.toAdd[i or 1]
	if type(ce) == "table" and type(ce.frozenNodes) == "table" and #ce.frozenNodes > 0 then return ce.frozenNodes, "captured" end
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
		-- the engine's conversion numbers the construction's nodes in its own proposal: they are this build's (see C.frozenNodesOf)
		local how
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
		P.toAdd = conList
	end
	-- an edited construction (a module added to a street station): the old one is replaced, and old2new keeps its
	-- stations (the lines stopping there keep their stops). Without them the new one collided with the old (issue #14).
	-- (without a construction: the town buildings the street build takes away)
	local removeList = entityList(m.toRemove or m.constructionsToRemove)
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
			for _, o in ipairs(c.objects) do if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then keep[#keep + 1] = { objIds[o[1]] or o[1], o[2] } end end
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
	-- the node configurations (lane connections...) the tool removed: only those this game has (removing one that does not
	-- exist is an engine assertion), and those it added, with the native ids
	if stage < 4 then P.proposal = sp return P end
	local cfgRemove = {}
	for _, n in ipairs(opts.noConfigs and {} or entityList(st.nodeConfigsToRemove)) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then cfgRemove[#cfgRemove + 1] = n end
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
}

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

-- Companies mode: a station built by a player is shared with the other companies from the start, at the smallest fee; its
-- company may change the fee or stop sharing it (fee 0, kept in the registry: a station absent from it is shared by default)
C.SHARE_DEFAULT = 100
function C.shareFee(shares, key)
	local f = shares and key and shares[key]
	if f == nil then return C.SHARE_DEFAULT end
	return f
end

return C
