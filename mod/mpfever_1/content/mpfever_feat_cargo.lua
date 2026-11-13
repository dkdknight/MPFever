-- MPFever 0.8.6 game option "cargo": a commodity market (#277, Akamari's idea of shares on cargo such as wood; the user's: prices
-- that follow supply, demand and how the demand is served). A feature module of the options host (mpfever_feat.lua, contract in
-- docs/FEATURES-0.6.md): off by default, and while off nothing at all happens (no state, no event, no file, no money).
--
-- Every cargo the map's industries make or take, and the towns ask for, has a price index (100 when the market opens). Once a
-- game month the host reads the game's own yearly figures (api.engine.util.stock for the industries, the town buildings' supply
-- and limit for the towns): what the consumers could take of each cargo (demand), what reached them (delivered) and what the
-- industries made (production). It moves each price part of the way (the option's speed) to its target and sends the prices:
--   target = 100 x sqrt(shortage) / sqrt(abundance), between 25 and 400:
--     shortage  = demand / delivered, from 1 (all served) to 4: a cargo the consumers lack goes up;
--     abundance = production / demand, from 1/4 to 4: a cargo made far beyond what is taken goes down.
--   The players' own transport moves the prices: deliver much wood to the saw mills and its price falls; leave them short and it
--   rises. The prices go both ways, whatever the players do.
-- A company buys lots of a cargo at the month's price (a lot is worth the option's lot size x index / 100) and sells them back at
-- the month's price less 2 %; the money goes to and comes from the market. At most the option's limit of lots a cargo a month,
-- M.MAXHOLD lots of a cargo held. With one company for everybody, the company trades; with one per player, each company.
--
-- Everything that changes money or lots runs in the simulation half (M.event), on every game at the same step, from the state
-- (st.feat.cargo, saved with the game: plain data, the cargos by their file name, the companies by their number as text) and the
-- events' figures only: integer arithmetic, sorted keys, no balance read. The host computes the prices (the GUI may use floats):
-- every game takes its numbers as they are.

local M = {}
M.ID = "cargo"

local function pct(v) return tostring(v) .. " %" end

M.OPTIONS = {
	{ id = "cargo", title = { "Bourse des marchandises", "Commodity market" },
		desc = { "Chaque marchandise a un cours qui suit l'offre et la demande de la carte : achetez des lots quand elle manque, revendez-les quand elle monte. Vos transports font bouger les cours.",
			"Every cargo has a price that follows the map's supply and demand: buy lots when it is short, sell them when it rises. Your transport moves the prices." },
		modes = "both",
		params = {
			{ id = "lot", label = { "Valeur d'un lot (cours 100)", "Lot value (price 100)" }, values = { 10000, 50000, 200000 }, default = 50000,
				show = function(v, T) return tostring(v) .. " $" end },
			{ id = "speed", label = { "Vitesse des cours", "Price speed" }, values = { 20, 33, 50 }, default = 33, show = pct },
			{ id = "limit", label = { "Lots par mois et marchandise", "Lots a month per cargo" }, values = { 5, 10, 20 }, default = 10 },
		} },
}
M.EVENTS = { f_cargo_price = true, f_cargo_buy = true, f_cargo_sell = true }
M.TAB = { id = "cargo", title = { "Marchandises", "Commodities" } }

M.MAXHOLD = 100      -- lots of one cargo a company holds at most
M.SPREAD = 98        -- a sale gets 98 % (against buying and selling over and over)
M.RESEND = 15        -- seconds: the host sends a month's prices again while they are not applied
M.MINP, M.MAXP = 10, 1000

-- ---------------------------------------------------------------- helpers (plain data)
local function num(x) return tonumber(x) end
local function int(x) x = tonumber(x); if not x then return nil end return math.floor(x) end
local function ckey(id) return tostring(math.floor(tonumber(id) or -1)) end
local function sortedKeys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end
local function get2(t, a, b) local r = t and t[a]; return r and r[b] or nil end
local function set2(S, name, a, b, v)
	S[name] = S[name] or {}
	S[name][a] = S[name][a] or {}
	S[name][a][b] = v
	if v == nil and next(S[name][a]) == nil then S[name][a] = nil end
end
local function fmt(s, ...)
	local v, i = { ... }, 0
	return (tostring(s):gsub("%%s", function() i = i + 1; return tostring(v[i]) end))
end
local function fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end
local function active(st, env) return env and env.on and env.on("cargo") end

M.opts = function(env)
	local function p(id, d) local v = env and env.param and env.param("cargo", id); return tonumber(v) or d end
	return { lot = math.max(1, math.floor(p("lot", 50000))), speed = math.max(1, math.min(100, math.floor(p("speed", 33)))),
		limit = math.max(1, math.floor(p("limit", 10))) }
end

-- a lot's value at index p
M.lotValue = function(o, p) return math.floor(o.lot * (tonumber(p) or 0) / 100) end

-- the companies that trade: one company per player, each (by its number); one for everybody, the company (1)
local function companyOf(env, coId)
	local list = env and env.companies and env.companies() or {}
	if env and env.mode == "separate" then
		for _, c in ipairs(list) do if c.id == tonumber(coId) and not c.gone then return c end end
		return nil
	end
	return list[1]
end

-- ---------------------------------------------------------------- the host's prices (GUI half, host only; plain numbers)
-- the target index of a cargo from its yearly demand, deliveries and production (floats: the host's alone)
M.target = function(dem, del, prod)
	dem, del, prod = math.max(0, dem or 0), math.max(0, del or 0), math.max(0, prod or 0)
	local shortage, abundance = 1, 1
	if dem > 0 then
		shortage = math.min(4, math.max(1, dem / math.max(del, 1)))
		abundance = math.min(4, math.max(0.25, prod / dem))
	elseif prod > 0 then
		abundance = 4
	end
	return 100 * math.sqrt(shortage) / math.sqrt(abundance)
end
-- the next index: part of the way from the old one to the target, whole, within M.MINP .. M.MAXP
M.nextPrice = function(old, target, speed)
	old = tonumber(old) or 100
	local v = old + (target - old) * (speed or 33) / 100
	v = math.floor(v + 0.5)
	return math.max(M.MINP, math.min(M.MAXP, v))
end

-- the cargo's name as players read it (its file's name without the folder when it has none)
M.label = function(id, file)
	local n = nil
	pcall(function()
		local ct = api.res.cargoTypeRep.get(id)
		n = ct and ct.name
		if type(n) == "string" and n ~= "" and type(_) == "function" then
			local okT, tr = pcall(_, n)
			if okT and type(tr) == "string" and tr ~= "" then n = tr end
		end
	end)
	if type(n) ~= "string" or n == "" or n:find("/", 1, true) then n = tostring(file):match("([^/]+)%.cargo$") or tostring(file) end
	return (n:gsub("[|;%c]", " "))
end

-- the map's figures by cargo file: { [file] = { label, dem, del, prod } } (the tests replace it)
M.measure = function()
	local out = {}
	local passengers = nil
	pcall(function() passengers = api.res.cargoTypeRep.getPassengerCargoTypeId() end)
	local function of(id)
		if id == nil or id == passengers then return nil end
		local file = nil
		pcall(function() file = api.res.cargoTypeRep.getName(id) end)
		if type(file) ~= "string" or file == "" then return nil end
		local t = out[file]
		if not t then t = { label = M.label(id, file), dem = 0, del = 0, prod = 0 }; out[file] = t end
		return t
	end
	local U = api.engine.util.stock
	pcall(function()
		api.engine.forEachEntityWithComponent(function(ind)
			local okIO, io = pcall(U.getInputsOutputsFromRules, ind)
			if not okIO or type(io) ~= "table" then return end
			for _, c in ipairs(io[1] or {}) do
				local t = of(c)
				if t then
					local okD, d = pcall(U.getCargoMaxConsumptionPerYear, ind, c)
					local okL, l = pcall(U.getCargoTypeDeliveredPerYear, ind, c)
					if okD and type(d) == "number" then t.dem = t.dem + d end
					if okL and type(l) == "number" then t.del = t.del + l end
				end
			end
			for _, c in ipairs(io[2] or {}) do
				local t = of(c)
				if t then
					local okP, p = pcall(U.getCargoProducedPerYear, ind, c)
					if okP and type(p) == "number" then t.prod = t.prod + p end
				end
			end
		end, api.type.ComponentType.INDUSTRY)
	end)
	-- the towns: their buildings' supply (delivered) and limit (demand) of each cargo
	pcall(function()
		api.engine.forEachEntityWithComponent(function(town)
			local okS, map = pcall(api.engine.system.townBuildingSystem.getCargoSupplyAndLimit, town)
			if not okS or type(map) ~= "table" then return end
			for c, v in pairs(map) do
				local t = of(c)
				if t and type(v) == "table" then
					t.del = t.del + math.max(0, tonumber(v[1]) or 0)
					t.dem = t.dem + math.max(0, tonumber(v[2]) or 0)
				end
			end
		end, api.type.ComponentType.TOWN)
	end)
	return out
end

-- the month's rows for f_cargo_price, "file|price|dem|del|prod|label;..." sorted by file (nil when the map has no cargo)
M.rowsFor = function(S, env)
	local o = M.opts(env)
	local figs = M.measure()
	local out = {}
	for _, file in ipairs(sortedKeys(figs)) do
		local f = figs[file]
		if (f.dem or 0) > 0 or (f.prod or 0) > 0 then
			local old = num(S and S.price and S.price[file]) or 100
			local p = M.nextPrice(old, M.target(f.dem, f.del, f.prod), o.speed)
			if S == nil or S.price == nil or S.price[file] == nil then p = 100 end
			out[#out + 1] = table.concat({ file, p, math.floor(f.dem), math.floor(f.del), math.floor(f.prod), f.label }, "|")
		end
	end
	if #out == 0 then return nil end
	return table.concat(out, ";")
end

-- ---------------------------------------------------------------- simulation half (every game, same step)
local function book(env, c, amount)
	amount = math.floor(amount)
	if amount == 0 or not (c and c.ent) then return end
	env.book(c.ent, amount)
end

-- f_cargo_price: the host's prices of a new month, applied once
local function applyPrice(S, param, env)
	if not fromHost(param.mpfFrom) then return false, "not the host" end
	local m = int(param.month)
	if not m then return false, "month" end
	if S.month and m <= S.month then return false, "month " .. m .. " already priced" end
	if S.due and m > S.due then return false, "month " .. m .. " not begun here" end
	if type(param.rows) ~= "string" or #param.rows > 60000 then return false, "rows" end
	local price, fig, label = {}, {}, {}
	local n = 0
	for item in param.rows:gmatch("[^;]+") do
		local file, p, d, l, pr, lab = item:match("^([^|]+)|(%d+)|(%d+)|(%d+)|(%d+)|([^|]*)$")
		p = tonumber(p)
		if file and p and p >= M.MINP and p <= M.MAXP and n < 200 then
			price[file] = math.floor(p)
			fig[file] = { math.floor(tonumber(d)), math.floor(tonumber(l)), math.floor(tonumber(pr)) }
			label[file] = lab
			n = n + 1
		end
	end
	S.prev = S.price
	S.price, S.fig, S.label, S.bought = price, fig, label, nil
	if S.month == nil then S.open = m end
	S.month = m
	env.log("cargo: month " .. m .. " priced: " .. n .. " cargo(s)")
	return true
end

-- whether company `coId` may buy n lots of cargo `file` now: ok, why, cost
M.check = function(S, o, coId, file, n)
	if type(S) ~= "table" or not S.month then return false, "the market is not open yet" end
	local p = S.price and S.price[file]
	if not p then return false, "not listed" end
	n = int(n)
	if not n or n < 1 then return false, "count" end
	local k = ckey(coId)
	if (num(get2(S.bought, file, k)) or 0) + n > o.limit then return false, "monthly limit" end
	if (num(get2(S.hold, file, k)) or 0) + n > M.MAXHOLD then return false, "too many lots" end
	return true, nil, M.lotValue(o, p) * n
end
-- what n lots of `file` held by company `coId` sell for now: ok, why, proceeds
M.checkSell = function(S, o, coId, file, n)
	if type(S) ~= "table" or not S.month then return false, "the market is not open yet" end
	local p = S.price and S.price[file]
	if not p then return false, "not listed" end
	n = int(n)
	local h = num(get2(S.hold, file, ckey(coId))) or 0
	if not n or n < 1 or n > h then return false, "count" end
	return true, nil, math.floor(M.lotValue(o, p) * n * M.SPREAD / 100)
end

local function buy(S, param, env)
	local o = M.opts(env)
	local c = companyOf(env, param.mpfCo)
	if not (c and c.ent) then return false, "no company" end
	local file, n = tostring(param.cargo or ""), int(param.n) or 1
	local ok, why, cost = M.check(S, o, c.id, file, n)
	if not ok then return false, why end
	local k = ckey(c.id)
	book(env, c, -cost)
	set2(S, "hold", file, k, (num(get2(S.hold, file, k)) or 0) + n)
	set2(S, "cost", file, k, (num(get2(S.cost, file, k)) or 0) + cost)
	set2(S, "bought", file, k, (num(get2(S.bought, file, k)) or 0) + n)
	env.log("cargo: company " .. c.id .. " buys " .. n .. " lot(s) of " .. file .. " for " .. cost)
	return true
end

local function sell(S, param, env)
	local o = M.opts(env)
	local c = companyOf(env, param.mpfCo)
	if not (c and c.ent) then return false, "no company" end
	local file, n = tostring(param.cargo or ""), int(param.n) or 1
	local ok, why, proceeds = M.checkSell(S, o, c.id, file, n)
	if not ok then return false, why end
	local k = ckey(c.id)
	local h = num(get2(S.hold, file, k)) or 0
	local paid = num(get2(S.cost, file, k)) or 0
	local part = math.floor(paid * n / h)
	book(env, c, proceeds)
	set2(S, "hold", file, k, h - n > 0 and (h - n) or nil)
	set2(S, "cost", file, k, h - n > 0 and (paid - part) or nil)
	S.gain = S.gain or {}
	S.gain[k] = (num(S.gain[k]) or 0) + proceeds - part
	env.log("cargo: company " .. c.id .. " sells " .. n .. " lot(s) of " .. file .. " for " .. proceeds .. " (gain " .. (proceeds - part) .. ")")
	return true
end

-- the contract's M.event
function M.event(st, name, param, env)
	if not active(st, env) then return end
	param = type(param) == "table" and param or {}
	local S = env.state(st)
	local ok, why
	if name == "f_cargo_price" then ok, why = applyPrice(S, param, env)
	elseif name == "f_cargo_buy" then ok, why = buy(S, param, env)
	elseif name == "f_cargo_sell" then ok, why = sell(S, param, env)
	else return end
	if not ok then env.log("cargo: " .. name .. " of '" .. tostring(param.mpfFrom) .. "' (company " .. tostring(param.mpfCo) .. ") refused: " .. tostring(why)) end
end

-- the contract's M.month: a new game month asks for its prices
function M.month(st, env)
	if not active(st, env) then return end
	local m = env.month and int(env.month())
	if not m then return end
	local S = env.state(st)
	if not S.due or m > S.due then S.due = m end
end

-- ---------------------------------------------------------------- GUI half
M.T = function(fr, en) return en end
local function lang(env)
	if env and type(env.T) == "function" then return env.T end
	return M.T
end

M.money = function(x)
	x = math.floor(tonumber(x) or 0)
	local s = tostring(math.abs(x)):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return (x < 0 and "-" or "") .. s .. " $"
end

-- this game's company number (one for everybody: 1)
local function myCoId(st, env)
	if env and env.mode == "separate" then return tonumber(env.myCo) end
	return 1
end

-- the window's file (env.write "cargo"): "opt", "me", then a line a cargo
M.fileLines = function(st, env)
	local S = st.feat and st.feat.cargo
	local o = M.opts(env)
	local me = myCoId(st, env) or 0
	local k = ckey(me)
	local L = { table.concat({ "opt", o.lot, o.speed, o.limit, S and S.month or -1, M.MAXHOLD }, "\t") }
	L[#L + 1] = table.concat({ "me", me, math.floor(num(S and S.gain and S.gain[k]) or 0) }, "\t")
	for _, file in ipairs(sortedKeys(S and S.price)) do
		local f = S.fig and S.fig[file] or {}
		L[#L + 1] = table.concat({ "c", file, S.price[file], num(S.prev and S.prev[file]) or 0, f[1] or 0, f[2] or 0, f[3] or 0,
			math.floor(num(get2(S.hold, file, k)) or 0), math.floor(num(get2(S.cost, file, k)) or 0), math.floor(num(get2(S.bought, file, k)) or 0),
			(((S.label and S.label[file]) or file):gsub("[%c\t]", " ")) }, "\t")
	end
	return L
end

function M.gui(st, env)
	if not active(st, env) then return end
	local S = st.feat and st.feat.cargo
	local now = env.realTime and env.realTime() or 0
	if env.isHost and S and S.due and (S.month == nil or S.due > S.month) then
		if M.sentFor ~= S.due or now - (M.sentAt or -1e9) >= M.RESEND then
			if now - (M.triedAt or -1e9) >= 2 then
				M.triedAt = now
				local rows = M.rowsFor(S, env)
				if rows then
					local r = env.send("f_cargo_price", { month = S.due, rows = rows })
					if r ~= false then M.sentFor, M.sentAt = S.due, now end
				end
			end
		end
	end
	if env.write then env.write("cargo", M.fileLines(st, env)) end
end

M.balanceOf = function(st, env)
	local ent = nil
	if env and env.mode == "separate" then
		for _, c in ipairs(st.co and st.co.list or {}) do if c.id == tonumber(env.myCo) then ent = c.ent end end
	else
		pcall(function() ent = api.engine.util.getPlayer() end)
	end
	if not ent then return nil end
	local ok, b = pcall(function() return api.engine.util.finance.getPlayersBalance(ent) end)
	if ok and type(b) == "number" then return b end
	return nil
end

-- the window's buttons ("buy", "sell"; payload { cargo, n })
function M.request(kind, payload, st, env)
	if not active(st, env) then return false, "off" end
	payload = type(payload) == "table" and payload or {}
	local S = st.feat and st.feat.cargo
	local o = M.opts(env)
	local T = lang(env)
	local function no(text, why)
		if env.chat then env.chat(text) end
		if env.log then env.log("cargo: " .. tostring(kind) .. " refused here: " .. tostring(why or text)) end
		return false, why or text
	end
	local me = myCoId(st, env)
	if not me then return no(T("Vous n'avez pas d'entreprise.", "You have no company."), "no company") end
	local file, n = tostring(payload.cargo or ""), int(payload.n) or 1
	local reasons = {
		["the market is not open yet"] = T("La bourse des marchandises ouvre au début du mois prochain.", "The commodity market opens at the start of next month."),
		["not listed"] = T("Cette marchandise n'a pas de cours.", "This cargo has no price."),
		["monthly limit"] = fmt(T("Pas plus de %s lots par mois de cette marchandise.", "No more than %s lots a month of this cargo."), o.limit),
		["too many lots"] = fmt(T("Pas plus de %s lots d'une marchandise.", "No more than %s lots of one cargo."), M.MAXHOLD),
		["count"] = T("Vous n'avez pas ces lots.", "You do not have these lots."),
	}
	if kind == "buy" then
		local ok, why, cost = M.check(S, o, me, file, n)
		if not ok then return no(reasons[why] or T("Impossible.", "Not possible."), why) end
		local bal = M.balanceOf(st, env)
		if bal and bal < cost then return no(T("Pas assez d'argent.", "Not enough money."), "money") end
		env.send("f_cargo_buy", { cargo = file, n = n })
		return true
	elseif kind == "sell" then
		local ok, why = M.checkSell(S, o, me, file, n)
		if not ok then return no(reasons[why] or T("Impossible.", "Not possible."), why) end
		env.send("f_cargo_sell", { cargo = file, n = n })
		return true
	end
	return false, "kind"
end

-- ---------------------------------------------------------------- the MPFever window's tab
-- M.view: the window file's lines -> what the tab shows (plain data, tested offline)
M.view = function(lines, myBal)
	local v = { opt = nil, me = 0, gain = 0, cargos = {} }
	for _, line in ipairs(lines or {}) do
		local f = {}
		for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
		if f[1] == "opt" then
			v.opt = { lot = num(f[2]) or 50000, speed = num(f[3]) or 33, limit = num(f[4]) or 10, month = num(f[5]) or -1, maxhold = num(f[6]) or M.MAXHOLD }
		elseif f[1] == "me" then v.me, v.gain = num(f[2]) or 0, num(f[3]) or 0
		elseif f[1] == "c" then
			local c = { file = f[2], price = num(f[3]) or 0, prev = num(f[4]) or 0, dem = num(f[5]) or 0, del = num(f[6]) or 0, prod = num(f[7]) or 0,
				held = num(f[8]) or 0, cost = num(f[9]) or 0, bought = num(f[10]) or 0, label = f[11] or f[2] }
			v.cargos[#v.cargos + 1] = c
		end
	end
	local o = v.opt or { lot = 50000, speed = 33, limit = 10, month = -1, maxhold = M.MAXHOLD }
	v.portfolio = 0
	for _, c in ipairs(v.cargos) do
		local lot = M.lotValue(o, c.price)
		if c.prev > 0 then c.change = math.floor((c.price - c.prev) * 1000 / c.prev) / 10 end
		c.served = c.dem > 0 and math.floor(math.min(c.del, c.dem) * 100 / c.dem) or nil
		c.made = c.dem > 0 and math.floor(c.prod * 100 / c.dem) or nil
		c.value = lot * c.held
		v.portfolio = v.portfolio + c.value
		if c.bought < o.limit and c.held < o.maxhold then c.buy = { cost = lot, allowed = myBal == nil or myBal >= lot } end
		if c.held > 0 then c.sell = { proceeds = math.floor(lot * M.SPREAD / 100) } end
	end
	table.sort(v.cargos, function(a, b) return tostring(a.label) < tostring(b.label) end)
	v.open = o.month >= 0
	return v
end

function M.ui(u)
	local T = u.T or M.T
	local money = u.money or M.money
	local myBal = nil
	pcall(function() if u.balance then myBal = u.balance() end end)
	local v = M.view(u.read and u.read("cargo") or {}, myBal)
	local out = {}
	local function add(w) if w ~= nil then out[#out + 1] = w; if u.add then u.add(w) end end end
	add((u.title and u.title(T("Bourse des marchandises", "Commodity market"))) or u.text(T("Bourse des marchandises", "Commodity market")))
	add(u.muted(T("Le cours de chaque marchandise suit la demande des industries et des villes, ce qui leur est livré et ce qui est produit, chaque mois. Un lot s'achète au cours du mois et se revend au cours du mois moins 2 %.",
		"Each cargo's price follows, every month, what the industries and towns ask for, what reaches them and what is made. A lot is bought at the month's price and sold back at the month's price less 2 %.")))
	if not v.open then
		add(u.muted(T("La bourse des marchandises ouvre au début du mois prochain.", "The commodity market opens at the start of next month.")))
		if u.add then return {} end
		return out
	end
	add(u.text(fmt(T("Vos lots : %s. Gains réalisés : %s.", "Your lots: %s. Realised gains: %s."), money(v.portfolio), money(v.gain))))
	for _, c in ipairs(v.cargos) do
		local change = c.change and ((c.change >= 0 and "+" or "") .. tostring(c.change) .. " %") or ""
		add(u.text(fmt(T("%s : cours %s %s", "%s: price %s %s"), c.label, c.price, change)))
		local info = (c.served and fmt(T("Demande servie : %s. Production : %s de la demande.", "Demand served: %s. Production: %s of the demand."), pct(c.served), pct(c.made))
			or T("Personne ne la demande sur la carte.", "Nobody asks for it on the map."))
		add(u.muted(info))
		add(u.muted(fmt(T("Vous : %s lots (%s).", "You: %s lots (%s)."), c.held, money(c.value))))
		local buttons = {}
		if c.buy then
			buttons[#buttons + 1] = u.button(fmt(T("Acheter 1 lot (%s)", "Buy 1 lot (%s)"), money(c.buy.cost)), function() u.request("buy", { cargo = c.file, n = 1 }) end, false, c.buy.allowed)
		end
		if c.sell then
			buttons[#buttons + 1] = u.button(fmt(T("Vendre 1 lot (%s)", "Sell 1 lot (%s)"), money(c.sell.proceeds)), function() u.request("sell", { cargo = c.file, n = 1 }) end, false, true)
		end
		if #buttons > 0 then add(u.row(buttons)) end
	end
	if u.add then return {} end
	return out
end

return M
