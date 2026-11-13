-- MPFever (0.8.6, #190): the game's « Bank account / Company value » chart (Finances window, Charts) for the player's OWN company.
--
-- The game draws that chart from two series of the WORLD's logbook, "companyBalance" and "companyTotalValue", which the engine
-- writes for the savegame's company only (finances_charts.tl, BalanceChart; MPFever's autotest logprobe: no such series per
-- company). With one company per player, every other player saw the host's history, with their own figures as the last point.
--
-- Here, in the interface's own Lua state (nothing of the simulation changes, nothing is sent):
--   - once a game month (the calendar's month changes), this game notes its OWN company's bank account and company value as the
--     game gives them (getCompaniesValue: the local player's, the chart's own formula totalAssets + balance - debt), at that time;
--   - the points are kept in a file beside the session folders (they outlive the session), one per savegame (the time of the
--     world logbook's first "companyBalance" entry) and company (its entity); points later than the game's time (an older save
--     of the same game) are dropped;
--   - api.engine.util.logbook.getChart asked for exactly those two series on a game that plays another company than the
--     savegame's returns this company's history instead (the same chart, the same window), and api.engine.util.chart.setLastValue
--     writes its last point. Anything else, or anything that fails: the game's own answer.
-- MPFEVER_VALUECHART=0: off (the host's history, as before).

local M = {}
M.SERIES1, M.SERIES2 = "companyBalance", "companyTotalValue"
M.MAXPOINTS = 2400          -- 200 game years of months

-- the two series the chart asks for, in that order
function M.isBalanceChart(logNames)
	return type(logNames) == "table" and logNames[1] == M.SERIES1 and logNames[2] == M.SERIES2 and logNames[3] == nil
end

-- "t b v" lines -> { {t, b, v}, ... } in time order (a line that is not three numbers is skipped)
function M.parse(txt)
	local pts = {}
	for line in tostring(txt or ""):gmatch("[^\r\n]+") do
		local t, b, v = line:match("^(%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+)$")
		if t then pts[#pts + 1] = { tonumber(t), tonumber(b), tonumber(v) } end
	end
	table.sort(pts, function(a, c) return a[1] < c[1] end)
	return pts
end

function M.format(pts)
	local out = {}
	for i, p in ipairs(pts) do out[i] = string.format("%d %d %d", p[1], p[2], p[3]) end
	return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

-- a point at time t (a later one already there, from an older save of the same game, goes: the game's time runs on from here)
function M.add(pts, t, b, v)
	local keep = {}
	for _, p in ipairs(pts) do if p[1] < t then keep[#keep + 1] = p end end
	keep[#keep + 1] = { t, b, v }
	while #keep > M.MAXPOINTS do table.remove(keep, 1) end
	return keep
end

-- markers: about n round values from lo to hi (lo and hi included in the range)
function M.niceMarkers(lo, hi, n)
	n = n or 5
	if hi < lo then lo, hi = hi, lo end
	if hi == lo then hi = lo + 1 end
	local raw = (hi - lo) / n
	local mag = 10 ^ math.floor(math.log(raw, 10))
	local step = mag
	for _, f in ipairs({ 1, 2, 2.5, 5, 10 }) do
		if f * mag >= raw then step = f * mag; break end
	end
	local first = math.floor(lo / step) * step
	local marks = {}
	local v = first
	while v < hi + step * 0.5 and #marks < 30 do
		marks[#marks + 1] = v
		v = v + step
	end
	if marks[#marks] < hi then marks[#marks + 1] = marks[#marks] + step end
	return marks
end

-- the chart (the fields finances_react_util's chart reads: series {{x...},{y...}} per label, xMarkers, yMarkers, ranges) from
-- the points (and the game's own x markers when it has them: the same years on the axis), with an equals method as the
-- engine's charts have
function M.chart(pts, xMarkers)
	local xs, b, v = {}, {}, {}
	for i, p in ipairs(pts) do xs[i], b[i], v[i] = p[1], p[2], p[3] end
	local x2 = {}
	for i = 1, #xs do x2[i] = xs[i] end
	local lo, hi = 0, 0
	for i = 1, #b do lo = math.min(lo, b[i], v[i]); hi = math.max(hi, b[i], v[i]) end
	local xm = {}
	if type(xMarkers) == "table" and #xMarkers >= 2 then
		for i = 1, #xMarkers do xm[i] = xMarkers[i] end
	else
		local x0, x1 = xs[1] or 0, xs[#xs] or 1
		if x1 <= x0 then x1 = x0 + 1 end
		for i = 0, 4 do xm[#xm + 1] = x0 + (x1 - x0) * i / 4 end
	end
	local c = { mpf = true, series = { { xs, b }, { x2, v } }, xMarkers = xm, yMarkers = M.niceMarkers(lo, hi, 5) }
	c.xRange = { xm[1], xm[#xm] }
	c.yRange = { c.yMarkers[1], c.yMarkers[#c.yMarkers] }
	c.numPotentialGroups = 2
	c.equals = M.equals
	return c
end

function M.equals(a, c)
	if type(a) ~= "table" or type(c) ~= "table" or not a.mpf or not c.mpf then return false end
	for s = 1, 2 do
		local ya, yc = a.series[s][2], c.series[s][2]
		if #ya ~= #yc or ya[#ya] ~= yc[#yc] or a.series[s][1][#ya] ~= c.series[s][1][#yc] then return false end
	end
	return true
end

-- setLastValue on one of these charts: the last point of series idx (0-based, as the engine's), its y range widened
function M.setLast(c, idx, value)
	local s = c.series[(tonumber(idx) or 0) + 1]
	if not s or #s[2] == 0 then return end
	s[2][#s[2]] = value
	local lo, hi = 0, 0
	for k = 1, #c.series do for _, y in ipairs(c.series[k][2]) do lo = math.min(lo, y); hi = math.max(hi, y) end end
	c.yMarkers = M.niceMarkers(lo, hi, 5)
	c.yRange = { c.yMarkers[1], c.yMarkers[#c.yMarkers] }
end

-- ---------------------------------------------------------------- in game (the interface's state)
-- env: { log, dir (the folder of the files), io (C.IO), mine() (this game's company entity), canon() (the savegame's company
-- entity), separate() }
function M.install(env)
	if M.installed then return end
	if os.getenv("MPFEVER_VALUECHART") == "0" then M.installed = true; env.log("value chart: the game's own (MPFEVER_VALUECHART=0)"); return end
	local util = api.engine.util
	local lb = util and util.logbook
	local ch = util and util.chart
	local okG, realGet = pcall(function() return lb.getChart end)
	local okS, realSet = pcall(function() return ch.setLastValue end)
	if not okG or realGet == nil then
		M.installed = true
		env.log("value chart: no logbook interface here (util " .. type(util) .. ", logbook " .. type(lb) .. ", getChart " .. tostring(okG and type(realGet) or realGet) .. ")")
		return
	end
	if not okS then realSet = nil end
	M.env, M.realGet = env, realGet
	M.installed = true
	local function myGet(entity, logNames, ...)
		if M.isBalanceChart(logNames) then
			local ok, c = pcall(M.ownChart, entity, logNames, ...)
			if ok and c then return c end
			if not ok and not M.failSaid then M.failSaid = true; env.log("value chart: the game's own, ours failed: " .. tostring(c):sub(1, 200)) end
		end
		return realGet(entity, logNames, ...)
	end
	local function mySet(c, idx, value, ...)
		if type(c) == "table" and c.mpf then return M.setLast(c, idx, value) end
		return realSet(c, idx, value, ...)
	end
	-- (a Lua table: its field replaced; else, as in the interface's state where they are the engine's own objects, a table in its
	-- place that answers this function and hands every other name to the object)
	local function put(owner, key, obj, name, fn)
		if type(obj) == "table" and pcall(function() obj[name] = fn end) and obj[name] == fn then return "field" end
		local proxy = setmetatable({ [name] = fn }, { __index = obj })
		if pcall(function() owner[key] = proxy end) and owner[key] == proxy then return "proxy" end
		return nil
	end
	local how = put(util, "logbook", lb, "getChart", myGet)
	local howS = how and realSet and put(util, "chart", ch, "setLastValue", mySet) or nil
	if not how then
		-- (api.engine.util itself an engine object: a table in its place, with both wrapped)
		local lbP = setmetatable({ getChart = myGet }, { __index = lb })
		local chP = realSet and setmetatable({ setLastValue = mySet }, { __index = ch }) or ch
		local utilP = setmetatable({ logbook = lbP, chart = chP }, { __index = util })
		if pcall(function() api.engine.util = utilP end) and api.engine.util == utilP then how, howS = "util proxy", realSet and "util proxy" or nil end
	end
	if not how then env.log("value chart: the logbook interface cannot be wrapped here (util " .. type(util) .. ", logbook " .. type(lb) .. ")"); return end
	env.log("value chart: the Finances window's « Company value » chart shows this game's own company (getChart " .. how
		.. ", setLastValue " .. tostring(howS) .. "; MPFEVER_VALUECHART=0: off)")
end

-- the key of this savegame and company, and the file of its points
function M.fileOf(first, ent)
	local env = M.env
	return env.dir .. "\\mpfever_value_" .. tostring(first) .. "_" .. tostring(ent) .. ".txt"
end

function M.load(path)
	local f = M.env.io.open(path, "rb")
	if not f then return {} end
	local s = f:read("*a") or ""
	f:close()
	return M.parse(s)
end

function M.save(path, pts)
	local f = M.env.io.open(path, "wb")
	if not f then return end
	f:write(M.format(pts))
	f:close()
end

-- the game's time now
function M.now()
	return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
end

-- this savegame's key: the time of the world's first "companyBalance" entry, read once per load from the world's logbook
-- itself (the chart's own first x moves with its scale: 256694, then 256728 a minute later, seen in game)
function M.saveKey()
	if M.key then return M.key end
	local world = api.engine.util.getWorld()
	local k = nil
	pcall(function()
		local lbc = api.engine.getComponent(world, api.type.ComponentType.LOG_BOOK)
		local log = lbc.name2log[M.SERIES1]
		-- (its first time is 0 in every game: the first values, the savegame company's bank account in its first months, tell
		-- the games apart)
		k = M.keyOf(log.times, log.values)
	end)
	if type(k) ~= "string" then return nil end
	M.key = k
	return k
end

-- "<first time>_<first values>" of a log (up to its first 4 entries), nil without entries
function M.keyOf(times, values)
	if type(times) ~= "table" or type(values) ~= "table" or times[1] == nil then return nil end
	local parts = { string.format("%d", tonumber(times[1]) or 0) }
	for i = 1, 4 do
		if values[i] == nil then break end
		parts[#parts + 1] = string.format("%d", math.floor(tonumber(values[i]) or 0)):gsub("%-", "m")
	end
	return table.concat(parts, "_")
end

-- a game month index from a game time (the calendar: year * 12 + month)
function M.monthOf(t)
	local d = api.engine.util.getCalendarDate(t)
	return (tonumber(d.year) or 0) * 12 + (tonumber(d.month) or 0)
end

-- once in a while (the interface's tick): a new game month -> this company's own figures noted at that time
function M.poll()
	local env = M.env
	if not env or not env.separate() then return end
	local mine, canon = env.mine(), env.canon()
	if not mine or not canon or mine == canon then return end
	local first = M.saveKey()
	if not first then return end
	local last = M.now()
	local month = M.monthOf(last)
	if month == M.lastMonth then return end
	local v = api.engine.util.headquarters.getCompaniesValue()
	if api.engine.util.getPlayer() ~= mine then return end
	local balance = v.balance
	local value = v.totalAssets + balance - v.debt
	M.lastMonth = month
	local path = M.fileOf(first, mine)
	local pts = M.add(M.load(path), last, balance, value)
	M.save(path, pts)
	M.pts, M.ptsFor = pts, path
	if not M.saidPoint then M.saidPoint = true; env.log("value chart: this company's point noted at " .. tostring(last) .. " (" .. #pts .. " point(s) in " .. path .. ")") end
	-- (what the chart gets now, said once: the same call as the game's chart makes)
	if not M.saidCheck then
		M.saidCheck = true
		local okc, c = pcall(api.engine.util.logbook.getChart, api.engine.util.getWorld(), { M.SERIES1, M.SERIES2 }, nil, nil, 0, 0)
		env.log("value chart: the chart now gets " .. (okc and type(c) == "table" and c.mpf and ("this company's history, " .. #c.series[1][2] .. " point(s), last value " .. tostring(c.series[2][2][#c.series[2][2]])) or ("the game's own (" .. tostring(c) .. ")")))
	end
end

-- the chart for this company, or nil (the game's own: the savegame's company here, one company for everybody, no point yet)
function M.ownChart(entity, logNames, ...)
	local env = M.env
	if not env.separate() then return nil end
	local mine, canon = env.mine(), env.canon()
	if not mine or not canon or mine == canon or api.engine.util.getPlayer() ~= mine then return nil end
	local first = M.saveKey()
	if not first then return nil end
	local last = M.now()
	local wc = nil
	pcall(function() wc = M.realGet(api.engine.util.getWorld(), { M.SERIES1 }) end)
	local path = M.fileOf(first, mine)
	local pts = (M.ptsFor == path and M.pts) or M.load(path)
	-- (the game's time now: a point later than it belongs to a later save of this game)
	local keep = {}
	for _, p in ipairs(pts) do if p[1] <= last then keep[#keep + 1] = p end end
	if #keep == 0 then return nil end
	-- (and the current figures as the last point, which the chart sets with setLastValue)
	local now = keep[#keep]
	if now[1] < last then keep[#keep + 1] = { last, now[2], now[3] } end
	local xm = nil
	pcall(function() xm = {}; for i = 1, #wc.xMarkers do xm[i] = wc.xMarkers[i] end end)
	return M.chart(keep, xm)
end

return M
