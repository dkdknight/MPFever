-- MPFever 0.6 game option "stock": a stock market between the companies of the "one company per player" mode
-- (release/recherche-0.6/04-bourse.md; the owner's decisions D1 to D7 in 00-REPONSES.md come before the note's proposals).
-- A feature module of the options host (mpfever_feat.lua, contract in docs/FEATURES-0.6.md): off by default, and while off
-- nothing at all happens (no state, no event, no file, no money).
--
-- Every company has 10 shares. Once a game month the host measures each company's value (money - loans + resale value of its
-- vehicles, the statistics' figure) and the result of its lines over the month just ended, and sends them in f_stock_price;
-- every game then prices the shares (value / 10, never below a floor: a takeover is never free), pays the dividends (the host's
-- rate of the month's result, 25 % by default, D6) and opens the month's purchases:
--  * a company buys at most 2 shares of another one a month (D4); the money goes to the company whose shares are bought (D5);
--  * a company may buy its own shares back (D4): the money goes to the market (else a buy-back would be free), its own shares
--    pay no dividend and block a takeover (nobody gets more than half while it holds the other half);
--  * a holder sells its shares back to the company at the month's price, at most what it paid for them, less 2 % (the
--    company pays, as it got the money of the purchase; so no money is made by buying and selling between friends, and no
--    company is drained by its own money coming back in its price), within the company's money of the month;
--  * beyond 50 % the buyer takes the whole company over (D1): it pays every share it does not hold at the price plus the host's
--    premium (0 to 100 %), to their holders, the shares nobody held to the market; it gets everything the company owns, its money
--    and its loans (the merge of companies, see env.coMerge below), and the company's players get a new company with the start
--    money, as after a bankruptcy (D2). A computer company can be taken over when the host allows it (D3): it is then retired;
--  * a new company is protected for 24 months (D4): nobody else may buy its shares. The companies there when the stock market
--    opens are protected only up to the game's 24th month (a stock market switched on in an old game opens at once);
--  * the ranking goes by value while the stock market is on (D7): the value of every company is in the window's file
--    (feat_stock_stock.txt, see M.fileLines).
-- A company gone (bankrupt, empty) takes its shares with it: they are cancelled; one merged into another has its shares paid back
-- by the company it went into; the shares a gone company held follow it into the company it went into, or go back to the market.
--
-- Everything that changes money or shares runs in the simulation half (M.event), on every game at the same step, from the state
-- (st.feat.stock, saved with the game: plain data, the companies' numbers as string keys) and the events' figures only: integer
-- arithmetic, sorted keys, no balance read (as co_bid in mpfever_eco.lua: the interface offers only what a company has). The
-- figures the game knows for the local player only (a company's value) are measured on the host and sent (M.gui).

local M = {}
M.ID = "stock"

-- (a value's label in the lobby: a percentage, yes or no)
local function pct(v) return tostring(v) .. " %" end
-- (a number of months shown as years: "2 years")
local function years(v, T)
	local f = T and T("%s ans", "%s years") or "%s years"
	return (f:gsub("%%s", tostring(math.floor((tonumber(v) or 24) / 12))))
end
local function yesNo(v, T)
	if T then return (tonumber(v) == 1) and T("Oui", "Yes") or T("Non", "No") end
	return (tonumber(v) == 1) and "Yes" or "No"
end

M.OPTIONS = {
	{ id = "stock",
		title = { "Bourse", "Stock market" },
		desc = { "Chaque entreprise a 10 actions, cotées chaque mois à sa valeur ; l'argent d'un achat va à l'entreprise. Au-delà de 50 %, on rachète toute l'entreprise.",
			"Every company has 10 shares, priced every month at its value; the money of a purchase goes to the company. Beyond 50 %, you take the whole company over." },
		modes = "separate",
		params = {
			{ id = "premium", label = { "Prime de rachat", "Takeover premium" }, values = { 0, 10, 25, 50, 75, 100 }, default = 25, show = pct },
			{ id = "ai_buyable", label = { "IA rachetables", "Computer companies can be taken over" }, values = { 0, 1 }, default = 1, show = yesNo },
			{ id = "dividend", label = { "Dividendes (part du résultat du mois)", "Dividends (share of the month's result)" }, values = { 0, 10, 25, 50, 75 }, default = 25, show = pct },
			-- (0.6.12, a player's suggestion on Discord: 2 years only before)
			{ id = "protect", label = { "Protection d'une nouvelle entreprise", "A new company's protection" }, values = { 24, 60, 120 }, default = 24, show = years },
		} },
}
M.EVENTS = { f_stock_price = true, f_stock_buy = true, f_stock_sell = true }
M.TAB = { id = "stock", title = { "Bourse", "Stocks" } }

M.SHARES = 10        -- shares of a company
M.LIMIT = 2          -- shares a company buys of another one (or of itself) in a game month
M.PROTECT = 24       -- months a new company's shares are not for sale (the host's "protect" parameter since 0.6.12: 24, 60 or 120)
M.SPREAD = 98        -- a sale gets 98 % (against buying and selling over and over)
M.FLOOR_MIN = 1000   -- the lowest price of a share, whatever the start money
M.NEWS = 20          -- what happened, the last 20 (told in every game's chat)
M.RESEND = 15        -- seconds (real time, on the host) before a price not applied yet is sent again
M.SETTLE = 5         -- seconds a company's entity is known before the host reads its account (the engine asserts before)
-- (autotests only, MPFEVER_SCENARIO set: MPFEVER_STOCKPROTECT=<months> another protection, 0 for the scenario "stocktest" on a young
-- savegame. Read once; every game of the test is started with the same value)
pcall(function()
	local p = os.getenv("MPFEVER_SCENARIO") and tonumber(os.getenv("MPFEVER_STOCKPROTECT") or "")
	if p then M.PROTECT = math.max(0, math.floor(p)); M.TESTPROTECT = M.PROTECT end
end)

-- ---------------------------------------------------------------- small helpers (both halves)
local function num(x) return tonumber(x) end
local function int(x) x = tonumber(x); if not x then return nil end return math.floor(x) end
local function key(id) return tostring(math.floor(tonumber(id) or -1)) end

-- the keys of a table in one order on every game (Lua's own order of a table's keys may differ between two games)
local function sortedKeys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	table.sort(out, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb and na ~= nb then return na < nb end
		return tostring(a) < tostring(b)
	end)
	return out
end

local function get2(t, a, b) local r = t and t[a]; return r and r[b] or nil end
local function set2(S, name, a, b, v)
	S[name] = S[name] or {}
	local r = S[name][a]
	if v == nil or v == 0 then
		if r then r[b] = nil; if next(r) == nil then S[name][a] = nil end end
		if next(S[name]) == nil then S[name] = nil end
		return
	end
	if not r then r = {}; S[name][a] = r end
	r[b] = v
end
local function set1(S, name, a, v)
	if v == nil then
		if S[name] then S[name][a] = nil; if next(S[name]) == nil then S[name] = nil end end
		return
	end
	S[name] = S[name] or {}
	S[name][a] = v
end

-- a text with %s, each taking the next value (as C.Tf)
local function fmt(s, ...)
	local v, i = { ... }, 0
	return (tostring(s):gsub("%%s", function() i = i + 1; return tostring(v[i]) end))
end

local function isAi(c) return type(c) == "table" and type(c.key) == "string" and c.key:sub(1, 3) == "ai:" end
local function live(c) return type(c) == "table" and not c.gone end
local function findCo(reg, id)
	id = tonumber(id)
	for _, c in ipairs(reg and reg.list or {}) do if c.id == id then return c end end
	return nil
end
-- a host (or a dedicated server) sends its events under its plain name; a player who joined has "#n" after it
local function fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

local function registry(st, env) return (env and env.co) or (st and st.co) end
local function separate(st, env)
	local mode = env and env.mode
	if mode == nil then local reg = st and st.co; mode = reg and reg.mode end
	return mode == "separate"
end
local function active(st, env)
	return env and env.on and env.on("stock") and separate(st, env) and registry(st, env) ~= nil
end
local function opt(env, pid, default)
	local v = env.param and num(env.param("stock", pid)) or nil
	if v == nil then return default end
	return v
end
M.opts = function(env)
	return { premium = math.max(0, math.min(100, math.floor(opt(env, "premium", 25)))),
		ai = math.floor(opt(env, "ai_buyable", 1)) == 1,
		dividend = math.max(0, math.min(100, math.floor(opt(env, "dividend", 25)))),
		protect = M.TESTPROTECT or math.max(0, math.min(240, math.floor(opt(env, "protect", M.PROTECT)))) }
end

-- the lowest price of a share: a twentieth of a new company's start money for the 10 shares (10 000 for 2 million)
M.floorPrice = function(reg)
	local start = num(reg and reg.rules and reg.rules.start) or num(reg and reg.start) or 2000000
	return math.max(M.FLOOR_MIN, math.floor(start / (M.SHARES * 20)))
end

-- shares of company k held (by others and by itself), and those left on the market
local function held(S, k)
	local n = 0
	for _, h in pairs(S.hold and S.hold[k] or {}) do n = n + h end
	return n
end
local function floatOf(S, k) return M.SHARES - held(S, k) end

-- whether the computer company of that key ("ai:n") was taken over: it stays retired, mpfever_ai.lua asks here before it
-- announces the company again (else it would come back as a new company of that key)
M.retired = function(st, aiKey)
	local S = st and st.feat and st.feat.stock
	return type(S) == "table" and type(S.retired) == "table" and S.retired[tostring(aiKey)] == true
end

-- ---------------------------------------------------------------- the rules of a purchase (simulation and interface)
-- Whether company `buyer` may buy n shares of company `target` now, from the state and the options: ok, why (a short English
-- reason for the log), info { cost, takeover, unit, total, own }. The interface asks the same before it sends anything.
M.check = function(S, reg, o, buyerId, targetId, n, wantTakeover)
	local B, T = findCo(reg, buyerId), findCo(reg, targetId)
	if not (live(B) and B.ent) then return false, "no company" end
	if not (live(T) and T.ent) then return false, "no such company" end
	if type(S) ~= "table" or not S.month then return false, "the stock market is not open yet" end
	local k, bk = key(T.id), key(B.id)
	local P = S.price and S.price[k]
	if not P then return false, "not listed" end
	n = int(n)
	if not n or n < 0 or n > M.LIMIT then return false, "count" end
	local own = B.id == T.id
	if not own and (num(S["until"] and S["until"][k]) or 0) > S.month then return false, "protected" end
	local h = num(get2(S.hold, k, bk)) or 0
	if not own and h + n > M.SHARES / 2 then
		-- beyond half: the whole company, if the rules allow it and the buyer said so
		if isAi(T) and not o.ai then return false, "a computer company cannot be taken over" end
		if not wantTakeover then return false, "takeover not confirmed" end
		-- (n = 0: a buyer above half already, by the shares of a company it took over, needs no share of the market)
		if n > floatOf(S, k) then return false, "no share left" end
		local bought = num(get2(S.bought, k, bk)) or 0
		if n > 0 and bought + n > M.LIMIT then return false, "monthly limit" end
		local unit = math.floor(P * (100 + o.premium) / 100)
		return true, nil, { takeover = true, unit = unit, total = unit * (M.SHARES - h), cost = unit * (M.SHARES - h) }
	end
	if n < 1 then return false, "count" end
	local bought = num(get2(S.bought, k, bk)) or 0
	if bought + n > M.LIMIT then return false, "monthly limit" end
	if n > floatOf(S, k) then return false, "no share left" end
	return true, nil, { cost = P * n, own = own, unit = P }
end

-- What n shares of company target sell for now, by `seller`: ok, why, info { proceeds, part (of the cost paid), own }
M.checkSell = function(S, reg, sellerId, targetId, n)
	local H, T = findCo(reg, sellerId), findCo(reg, targetId)
	if not (live(H) and H.ent) then return false, "no company" end
	if not (live(T) and T.ent) then return false, "no such company" end
	if type(S) ~= "table" or not S.month then return false, "the stock market is not open yet" end
	local k, hk = key(T.id), key(H.id)
	local P = S.price and S.price[k]
	if not P then return false, "not listed" end
	n = int(n)
	local h = num(get2(S.hold, k, hk)) or 0
	if not n or n < 1 or n > h then return false, "count" end
	local c = num(get2(S.cost, k, hk)) or 0
	local part = math.floor(c * n / h)
	local proceeds = math.floor(math.min(P * n, part) * M.SPREAD / 100)
	local own = H.id == T.id
	if not own then
		-- (the company buys them back with its money of the month, as the host measured it)
		local cash = math.max(0, num(S.cash and S.cash[k]) or 0)
		if (num(S.out and S.out[k]) or 0) + proceeds > cash then return false, "the company cannot buy them back this month" end
	end
	return true, nil, { proceeds = proceeds, part = part, own = own }
end

-- ---------------------------------------------------------------- simulation half (every game, same step)
local function news(S, t)
	S.newsSeq = (S.newsSeq or 0) + 1
	t.n = S.newsSeq
	S.news = S.news or {}
	S.news[#S.news + 1] = t
	while #S.news > M.NEWS do table.remove(S.news, 1) end
end

local function book(env, c, amount)
	amount = math.floor(amount)
	if amount == 0 or not (c and c.ent) then return end
	env.book(c.ent, amount)
end

local function addCum(S, name, k, amount) set1(S, name, k, (num(S[name] and S[name][k]) or 0) + amount) end

-- every entry of a company that is no longer listed (taken over, gone)
local function forget(S, k)
	for _, name in ipairs({ "hold", "cost", "bought", "price", "prev", "value", "result", "cash", "div", "until", "out" }) do set1(S, name, k, nil) end
end

-- company h's shares of company k go to company m (taken over or merged into it): its own when m is k
local function moveHolding(S, k, hk, mk)
	local n = num(get2(S.hold, k, hk)) or 0
	local c = num(get2(S.cost, k, hk)) or 0
	set2(S, "hold", k, hk, nil)
	set2(S, "cost", k, hk, nil)
	set2(S, "bought", k, hk, nil)
	if n > 0 and mk then
		set2(S, "hold", k, mk, (num(get2(S.hold, k, mk)) or 0) + n)
		set2(S, "cost", k, mk, (num(get2(S.cost, k, mk)) or 0) + c)
	end
end

-- the companies gone since the last look: their shares and holdings (see the header)
local function settle(st, S, env)
	local reg = registry(st, env)
	local function into(c)
		if c and (c.gone == "merged" or c.gone == "taken") and c.mergedInto then
			local m = findCo(reg, c.mergedInto)
			if live(m) then return m end
		end
		return nil
	end
	-- (targets gone: the companies with holders or a price)
	local targets = {}
	for k in pairs(S.hold or {}) do targets[k] = true end
	for k in pairs(S.price or {}) do targets[k] = true end
	for _, k in ipairs(sortedKeys(targets)) do
		local T = findCo(reg, k)
		if not live(T) then
			local m = into(T)
			local P = num(S.price and S.price[k]) or num(S.prev and S.prev[k]) or 0
			local paid = 0
			for _, hk in ipairs(sortedKeys(S.hold and S.hold[k])) do
				local H = findCo(reg, hk)
				local n = num(get2(S.hold, k, hk)) or 0
				if m and live(H) and H.id ~= m.id and hk ~= k and n > 0 then
					-- (merged: the company it went into, which has its money, pays its holders the price, at most what they paid)
					local amount = math.min(P * n, num(get2(S.cost, k, hk)) or 0)
					book(env, m, -amount)
					book(env, H, amount)
					paid = paid + amount
				end
			end
			if S.hold and S.hold[k] then
				news(S, { kind = m and "repaid" or "cancel", co = T and T.id or tonumber(k), into = m and m.id or nil, amount = paid })
				env.log("stock: company " .. k .. " is gone (" .. tostring(T and T.gone) .. "): its shares are " .. (m and ("paid back by company " .. m.id .. " (" .. paid .. ")") or "cancelled"))
			end
			forget(S, k)
		end
	end
	-- (holders gone; S.hold empties as it goes)
	for _, k in ipairs(sortedKeys(S.hold)) do
		for _, hk in ipairs(sortedKeys(S.hold and S.hold[k])) do
			local H = findCo(reg, hk)
			if not live(H) then
				local m = into(H)
				moveHolding(S, k, hk, m and key(m.id) or nil)
				env.log("stock: company " .. hk .. " is gone: its shares of company " .. k .. (m and (" go to company " .. m.id) or " go back to the market"))
			end
		end
	end
end

-- f_stock_price: the host's figures of a new month (rows "id,value,result,cash;..."), applied once
local function applyPrice(st, S, param, env)
	if not fromHost(param.mpfFrom) then return false, "not the host" end
	local m = int(param.month)
	if not m then return false, "month" end
	if S.month and m <= S.month then return false, "month " .. m .. " already priced" end
	if S.due and m > S.due then return false, "month " .. m .. " not begun here" end
	if type(param.rows) ~= "string" or #param.rows > 20000 then return false, "rows" end
	local reg = registry(st, env)
	local rows = {}
	for item in param.rows:gmatch("[^;]+") do
		local id, v, r, c = item:match("^(%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
		local co = id and findCo(reg, tonumber(id))
		if co and live(co) and math.abs(tonumber(v)) < 1e14 and math.abs(tonumber(r)) < 1e14 and math.abs(tonumber(c)) < 1e14 then
			rows[#rows + 1] = { id = co.id, v = tonumber(v), r = tonumber(r), c = tonumber(c) }
		end
	end
	table.sort(rows, function(a, b) return a.id < b.id end)
	local opening = S.month == nil
	local age = math.max(0, int(param.age) or 0)
	local floor = M.floorPrice(reg)
	S.prev = S.price
	S.price, S.value, S.result, S.cash, S.div, S.out, S.bought = nil, nil, nil, nil, nil, nil, nil
	S.month = m
	if opening then S.open = m end
	local listed = 0
	for _, row in ipairs(rows) do
		local k = key(row.id)
		set1(S, "price", k, math.max(floor, math.floor(row.v / M.SHARES)))
		set1(S, "value", k, row.v)
		set1(S, "result", k, row.r)
		set1(S, "cash", k, row.c)
		if not (S["until"] and S["until"][k]) then
			-- (listed for the first time: protected; at the opening, only up to the game's month of the protection, 24th by default)
			local protect = M.opts(env).protect
			set1(S, "until", k, m + (opening and math.max(0, protect - age) or protect))
		end
		listed = listed + 1
	end
	-- the dividends of the month: the host's rate of the month's result, to every holder but the company itself, never more than
	-- the company's money
	local rate = M.opts(env).dividend
	for _, row in ipairs(rows) do
		local k = key(row.id)
		local others, holders = 0, {}
		for _, hk in ipairs(sortedKeys(S.hold and S.hold[k])) do
			local H = findCo(reg, hk)
			if hk ~= k and live(H) then others = others + S.hold[k][hk]; holders[#holders + 1] = H end
		end
		if rate > 0 and others > 0 and row.r > 0 and row.c > 0 then
			local d = math.floor(row.r * rate / 100 / M.SHARES)
			if d * others > row.c then d = math.floor(row.c / others) end
			if d > 0 then
				local T = findCo(reg, row.id)
				book(env, T, -d * others)
				addCum(S, "paid", k, d * others)
				for _, H in ipairs(holders) do
					local amount = d * S.hold[k][key(H.id)]
					book(env, H, amount)
					addCum(S, "got", key(H.id), amount)
				end
				set1(S, "div", k, d)
			end
		end
	end
	if opening then news(S, { kind = "open", count = listed }) end
	env.log("stock: month " .. m .. " priced: " .. listed .. " compan" .. (listed == 1 and "y" or "ies") .. " listed, dividends at " .. rate .. " %")
	return true
end

-- f_stock_buy {co, n, takeover, max}: company mpfCo buys n shares of company co (its own: a buy-back)
local function buy(st, S, param, env)
	local reg = registry(st, env)
	local o = M.opts(env)
	local ok, why, info = M.check(S, reg, o, param.mpfCo, param.co, param.n, param.takeover == true)
	if not ok then return false, why end
	local B, T = findCo(reg, param.mpfCo), findCo(reg, param.co)
	local k, bk = key(T.id), key(B.id)
	local n = int(param.n)
	if info.takeover then
		local max = num(param.max)
		if max and info.total > max then return false, "costs " .. info.total .. ", more than the " .. max .. " accepted" end
		if type(env.coMerge) ~= "function" then return false, "no takeover here (no merge)" end
		-- the shares the buyer does not hold: their holders get the price and the premium, the rest goes to the market
		local pay = {}
		for _, hk in ipairs(sortedKeys(S.hold and S.hold[k])) do
			local H = findCo(reg, hk)
			if hk ~= k and hk ~= bk and live(H) then pay[#pay + 1] = { H = H, amount = info.unit * S.hold[k][hk] } end
		end
		-- (the merge first: when it cannot be done, nothing is paid)
		local okM, res = pcall(env.coMerge, T.id, B.id, { members = "release", gone = "taken" })
		if not okM or res == false then
			env.log("stock: takeover of company " .. T.id .. " by company " .. B.id .. ": the merge failed: " .. tostring(res))
			return false, "merge failed"
		end
		book(env, B, -info.total)
		for _, p in ipairs(pay) do book(env, p.H, p.amount) end
		-- (the shares the company held of others are the buyer's now; a buyer above half of another one that way takes it over
		-- with its next share, not at this step)
		for _, tk in ipairs(sortedKeys(S.hold)) do
			if tk ~= k and get2(S.hold, tk, k) then moveHolding(S, tk, k, bk) end
		end
		forget(S, k)
		if isAi(T) then S.retired = S.retired or {}; S.retired[T.key] = true end
		news(S, { kind = "takeover", co = T.id, by = B.id, total = info.total, premium = o.premium })
		env.log("stock: company " .. B.id .. " TAKES OVER company " .. T.id .. " for " .. info.total .. " (premium " .. o.premium .. " %"
			.. (isAi(T) and ", computer company retired" or ", its players get a new company") .. ")")
		return true
	end
	local cost = info.cost
	book(env, B, -cost)
	-- (another company's shares: the money goes to it, D5. Its own: to the market)
	if not info.own then book(env, T, cost) end
	local h = (num(get2(S.hold, k, bk)) or 0) + n
	set2(S, "hold", k, bk, h)
	set2(S, "cost", k, bk, (num(get2(S.cost, k, bk)) or 0) + cost)
	set2(S, "bought", k, bk, (num(get2(S.bought, k, bk)) or 0) + n)
	-- (a holder that reaches 3 or 5 shares of another company: everybody is told)
	-- (the count is not `n`: news() numbers the entries with it)
	if not info.own and ((h - n < 3 and h >= 3) or (h - n < 5 and h >= 5)) then news(S, { kind = "cross", co = T.id, by = B.id, count = h }) end
	env.log("stock: company " .. B.id .. " buys " .. n .. " share(s) of company " .. T.id .. " for " .. cost .. " (holds " .. h .. ")")
	return true
end

-- f_stock_sell {co, n}: company mpfCo sells n shares of company co
local function sell(st, S, param, env)
	local reg = registry(st, env)
	local ok, why, info = M.checkSell(S, reg, param.mpfCo, param.co, param.n)
	if not ok then return false, why end
	local H, T = findCo(reg, param.mpfCo), findCo(reg, param.co)
	local k, hk = key(T.id), key(H.id)
	local n = int(param.n)
	-- (the company buys them back; its own shares are sold to the market)
	if not info.own then
		book(env, T, -info.proceeds)
		set1(S, "out", k, (num(S.out and S.out[k]) or 0) + info.proceeds)
	end
	book(env, H, info.proceeds)
	local h = (num(get2(S.hold, k, hk)) or 0) - n
	set2(S, "hold", k, hk, h)
	set2(S, "cost", k, hk, h > 0 and ((num(get2(S.cost, k, hk)) or 0) - info.part) or nil)
	env.log("stock: company " .. H.id .. " sells " .. n .. " share(s) of company " .. T.id .. " for " .. info.proceeds .. " (holds " .. h .. ")")
	return true
end

-- the contract's M.event: one of M.EVENTS, applied by every game at the same step
function M.event(st, name, param, env)
	if not active(st, env) then return end
	param = type(param) == "table" and param or {}
	local S = env.state(st)
	settle(st, S, env)
	local ok, why
	if name == "f_stock_price" then ok, why = applyPrice(st, S, param, env)
	elseif name == "f_stock_buy" then ok, why = buy(st, S, param, env)
	elseif name == "f_stock_sell" then ok, why = sell(st, S, param, env)
	else return end
	if not ok then env.log("stock: " .. name .. " of '" .. tostring(param.mpfFrom) .. "' (company " .. tostring(param.mpfCo) .. ") refused: " .. tostring(why)) end
end

-- the contract's M.month: a new game month asks for its prices (the host measures and sends them, see M.gui)
function M.month(st, env)
	if not active(st, env) then return end
	local m = env.month and int(env.month())
	if not m then return end
	local S = env.state(st)
	if not S.due or m > S.due then S.due = m end
end

-- ---------------------------------------------------------------- the host's measure (GUI half, host only)
-- Each returns plain numbers (the tests replace them); the statistics' value and money are taken when they have the month (M.fromStats).

-- (the game's time and month length, for the result of the month and the game's age in months)
M.clock = function()
	local now, month = nil, nil
	pcall(function() now = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime end)
	pcall(function() month = api.util.getDefaultMonthDuration() end)
	return tonumber(now), tonumber(month)
end

-- one pass over the vehicles (resale value) and the lines (to sum their result) of every company: { [ent] = { veh, lines } }
M.scan = function()
	local out = {}
	local function of(p) local t = out[p]; if not t then t = { veh = 0, lines = {} }; out[p] = t end return t end
	pcall(function()
		api.engine.forEachEntityWithComponent(function(v)
			local po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED)
			if po and type(po.player) == "number" and po.player >= 0 then
				local ok, val = pcall(api.engine.util.vehicle.getDepreciatedValue, v)
				if ok and type(val) == "number" then local t = of(po.player); t.veh = t.veh + val end
			end
		end, api.type.ComponentType.TRANSPORT_VEHICLE)
	end)
	pcall(function()
		api.engine.forEachEntityWithComponent(function(l)
			local po = api.engine.getComponent(l, api.type.ComponentType.PLAYER_OWNED)
			if po and type(po.player) == "number" and po.player >= 0 then local t = of(po.player); t.lines[#t.lines + 1] = l end
		end, api.type.ComponentType.LINE)
	end)
	return out
end

-- a company's figures: { v = value, r = result of its lines over the last month, c = money } (and, for the log: loan, veh, lines),
-- nil when its money cannot be read (infinite money: the stock market has nothing to price)
M.measure = function(c, scan, now, monthDur)
	local cash, loan, r = nil, 0, 0
	pcall(function() cash = api.engine.util.finance.getPlayersBalance(c.ent) end)
	if type(cash) ~= "number" then return nil end
	pcall(function() loan = api.engine.getComponent(c.ent, api.type.ComponentType.ACCOUNT).loan or 0 end)
	local s = scan[c.ent] or { veh = 0, lines = {} }
	-- (0.6.8) a line has no PLAYER_OWNED component: the scan found none, every company's result was 0 and no dividend was ever
	-- paid ("the stock dividend doesn't work"). The line system knows a company's lines. MPFEVER_STOCKLINES=0: the scan's, as before
	if os.getenv("MPFEVER_STOCKLINES") ~= "0" and #s.lines == 0 then
		local okL, ls = pcall(function() return api.engine.system.lineSystem.getLinesForPlayer(c.ent) end)
		if okL and type(ls) == "table" and #ls > 0 then
			local list = {}
			for _, l in ipairs(ls) do list[#list + 1] = l end
			table.sort(list)
			s = { veh = s.veh, lines = list }
		end
	end
	if now and monthDur and monthDur > 0 and #s.lines > 0 then
		local ok, b = pcall(api.engine.util.finance.calculateBalance, s.lines, now - monthDur, now, true)
		if ok and type(b) == "number" then r = b end
	end
	return { v = math.floor(cash - (tonumber(loan) or 0) + s.veh), r = math.floor(r), c = math.floor(cash), loan = tonumber(loan) or 0, veh = s.veh, lines = #s.lines }
end

-- the statistics' measure of the month (the option "stats", mpfever_feat_stats.lua), when it has one for that month: { [id] = { v, c } }
-- (the last entry of its ring st.feat.stats.m, "mi|year|month|id:b,d,vv;...", mi in env.month()'s numbering: money, loans, the
-- vehicles' resale value; anything else gives nil). The same value as M.measure's, so the two rankings agree; the statistics have
-- no result of the lines, the host measures it by itself.
M.fromStats = function(st, month)
	local s = st and st.feat and st.feat.stats
	local ring = type(s) == "table" and type(s.m) == "table" and s.m or nil
	local last = ring and ring[#ring]
	if type(last) ~= "string" then return nil end
	local m, rows = last:match("^(%-?%d+)|%-?%d+|%d+|(.*)$")
	if not m or tonumber(m) ~= month then return nil end
	local out, any = {}, false
	-- (0.7.17, #190: ",a", the company's assets as its own game counts them, when the month has them: the statistics' value)
	for id, b, d, vv, a in (rows .. ";"):gmatch("(%d+):(%-?%d+),(%-?%d+),(%-?%d+),?(%-?%d*);") do
		b, d, vv = tonumber(b), math.max(0, tonumber(d)), math.max(0, tonumber(vv))
		a = tonumber(a)
		out[tonumber(id)] = { v = math.floor(b - d + (a and math.max(0, a) or vv)), c = math.floor(b) }
		any = true
	end
	return any and out or nil
end

-- the rows of the month for f_stock_price, from the companies the host can read: "id,v,r,c;..." (nil when none)
M.rowsFor = function(st, env, month)
	local reg = st.co
	local stats = M.fromStats(st, month)
	local now = env.realTime and env.realTime() or 0
	M.seenAt = M.seenAt or {}
	local scan, gnow, monthDur = nil, nil, nil
	local out = {}
	for _, c in ipairs(reg.list or {}) do
		if live(c) and c.ent then
			-- (a company's entity is read once it has been known for a few seconds and still exists)
			M.seenAt[c.ent] = M.seenAt[c.ent] or now
			local settled = now - M.seenAt[c.ent] >= M.SETTLE
			if settled and M.exists then settled = M.exists(c.ent) end
			if settled then
				if not scan then scan = M.scan(); gnow, monthDur = M.clock() end
				local f = M.measure(c, scan, gnow, monthDur)
				-- (the statistics' value and money when they have this month: the same figures as their ranking)
				local sf = f and stats and stats[c.id]
				if sf then f = { v = sf.v, r = f.r, c = sf.c, loan = f.loan, veh = f.veh, lines = f.lines } end
				if f then
					out[#out + 1] = string.format("%d,%.0f,%.0f,%.0f", c.id, f.v, f.r, f.c)
					-- (once a month, what the host read: in-game checks of the account's loan, which may not count the MPFever loans
					-- of a company other than the savegame's (their count is told), and of the lines' result)
					if M.loggedFor ~= month and env.log then
						local lt = reg.loan and (reg.loan[c.id] or reg.loan[tostring(c.id)])
						env.log(string.format("feat stock: month %s company %d: value %.0f = money %.0f - account loan %.0f + vehicles %.0f%s; MPFever loans %d; %d line(s), result %.0f",
							tostring(month), c.id, f.v, f.c, f.loan or 0, f.veh or 0, sf and " (statistics' figures)" or "",
							type(lt) == "table" and type(lt.obtainedLoans) == "table" and #lt.obtainedLoans or 0, f.lines or 0, f.r))
					end
				end
			end
		end
	end
	if #out == 0 then return nil end
	M.loggedFor = month
	return table.concat(out, ";")
end
M.exists = function(ent)
	local ok, ex = pcall(function() return api.engine.entityExists(ent) end)
	return ok and ex == true
end
-- the game's age in months (the protection of the companies there at the opening)
M.age = function()
	local now, monthDur = M.clock()
	if now and monthDur and monthDur > 0 then return math.floor(now / monthDur) end
	return 0
end

-- ---------------------------------------------------------------- GUI half (every game, about once a second)
-- this game's language: the options host's env.T (the bridge's C.T), else M.T (English: the offline tests).
-- Every text is written T("français", "English") where it is used, so that tests/test_lang.py finds it.
M.T = function(fr, en) return en end
local function lang(env)
	if env and type(env.T) == "function" then return env.T end
	return M.T
end

M.nameOf = function(st, env, id)
	if env and type(env.coName) == "function" then
		local ok, n = pcall(env.coName, id)
		if ok and type(n) == "string" and n ~= "" then return n end
	end
	local c = findCo(st and st.co, id)
	if c and type(c.name) == "string" and c.name ~= "" then return c.name end
	local T = lang(env)
	return fmt(T("Entreprise %s", "Company %s"), tostring(id))
end

M.money = function(x)
	x = math.floor(tonumber(x) or 0)
	local s = tostring(math.abs(x)):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
	return (x < 0 and "-" or "") .. s .. " $"
end

-- the chat text of one news entry
M.newsText = function(st, env, t)
	local function N(id) return M.nameOf(st, env, id) end
	local T = lang(env)
	if t.kind == "open" then
		return fmt(T("La bourse ouvre : %s entreprises cotées (onglet Bourse de la fenêtre MPFever).", "The stock market opens: %s companies listed (Stocks tab of the MPFever window)."), t.count)
	elseif t.kind == "takeover" then
		return fmt(T("%s rachète %s pour %s (prime %s %) : tous ses biens passent à %s, ses joueurs reçoivent une nouvelle entreprise.",
			"%s takes over %s for %s (premium %s %): all its assets go to %s, its players get a new company."), N(t.by), N(t.co), M.money(t.total), t.premium, N(t.by))
	elseif t.kind == "cross" then
		return fmt(T("%s détient %s actions sur 10 de %s.", "%s holds %s of the 10 shares of %s."), N(t.by), t.count, N(t.co))
	elseif t.kind == "cancel" then
		return fmt(T("Les actions de %s sont annulées : l'entreprise n'existe plus.", "%s's shares are cancelled: the company is gone."), N(t.co))
	elseif t.kind == "repaid" then
		return fmt(T("%s a fusionné avec %s : ses actionnaires sont remboursés (%s).", "%s merged into %s: its shareholders are paid back (%s)."), N(t.co), N(t.into), M.money(t.amount))
	end
	return nil
end

-- the lines of the window's file (env.write "stock": feat_stock_stock.txt of the session folder) for the window (this game's view: "me" names its company and its entity here)
M.fileLines = function(st, env)
	local S = st.feat and st.feat.stock
	local o = M.opts(env)
	local reg = st.co
	local L = { table.concat({ "opt", o.premium, o.ai and 1 or 0, o.dividend, S and S.month or -1, o.protect, M.LIMIT, M.SHARES }, "\t") }
	local my = findCo(reg, env.myCo)
	L[#L + 1] = "me\t" .. tostring(my and my.id or 0) .. "\t" .. tostring(my and my.ent or -1)
	for _, c in ipairs(reg.list or {}) do
		if live(c) then
			local k = key(c.id)
			local g = function(name) return math.floor(num(S and S[name] and S[name][k]) or 0) end
			local own = math.floor(num(S and get2(S.hold, k, k)) or 0)
			local name = M.nameOf(st, env, c.id):gsub("[%c]", " ")
			L[#L + 1] = table.concat({ "co", c.id, isAi(c) and 1 or 0, g("price"), g("prev"), g("value"), g("result"), g("div"), g("until"),
				S and floatOf(S, k) or M.SHARES, own, num(c.color) or 0, name }, "\t")
		end
	end
	if S then
		for _, k in ipairs(sortedKeys(S.hold)) do
			for _, hk in ipairs(sortedKeys(S.hold[k])) do
				if live(findCo(reg, k)) and live(findCo(reg, hk)) then
					L[#L + 1] = table.concat({ "hold", k, hk, S.hold[k][hk], math.floor(num(get2(S.cost, k, hk)) or 0) }, "\t")
				end
			end
		end
		for _, k in ipairs(sortedKeys(S.bought)) do
			for _, bk in ipairs(sortedKeys(S.bought[k])) do L[#L + 1] = table.concat({ "bought", k, bk, S.bought[k][bk] }, "\t") end
		end
		local seen = {}
		for _, name in ipairs({ "paid", "got" }) do for k in pairs(S[name] or {}) do seen[k] = true end end
		for _, k in ipairs(sortedKeys(seen)) do
			L[#L + 1] = table.concat({ "divs", k, math.floor(num(S.paid and S.paid[k]) or 0), math.floor(num(S.got and S.got[k]) or 0) }, "\t")
		end
	end
	return L
end

-- the contract's M.gui: the host's prices of a new month, the news in this game's chat, the window's file
function M.gui(st, env)
	if not (env and env.on and env.on("stock")) or not separate(st, nil) or type(st.co) ~= "table" then return end
	local S = st.feat and st.feat.stock
	local now = env.realTime and env.realTime() or 0
	if env.isHost and S and S.due and (S.month == nil or S.due > S.month) then
		if M.sentFor ~= S.due or now - (M.sentAt or -1e9) >= M.RESEND then
			if now - (M.triedAt or -1e9) >= 2 then
				M.triedAt = now
				local rows = M.rowsFor(st, env, S.due)
				if rows then
					local r = env.send("f_stock_price", { month = S.due, rows = rows, age = M.age() })
					if r ~= false then M.sentFor, M.sentAt = S.due, now end
				end
			end
		end
	end
	-- (what happened, in this game's chat: every game has the same news; those there at the load are not told again)
	if S then
		if M.newsSeen == nil then M.newsSeen = S.newsSeq or 0 end
		for _, t in ipairs(S.news or {}) do
			if t.n > M.newsSeen then
				M.newsSeen = t.n
				local ok, text = pcall(M.newsText, st, env, t)
				if ok and text and env.chat then env.chat(text) end
			end
		end
	end
	if env.write then env.write("stock", M.fileLines(st, env)) end
end

-- the contract's M.request: the window's buttons on this game ("buy", "sell", "takeover"; payload { co, n, max })
M.balanceOf = function(ent)
	local ok, b = pcall(function() return api.engine.util.finance.getPlayersBalance(ent) end)
	if ok and type(b) == "number" then return b end
	return nil
end
function M.request(kind, payload, st, env)
	if not (env and env.on and env.on("stock")) or not separate(st, nil) or type(st.co) ~= "table" then return false, "off" end
	payload = type(payload) == "table" and payload or {}
	local S = st.feat and st.feat.stock
	local o = M.opts(env)
	local T = lang(env)
	local function no(text, why)
		if env.chat then env.chat(text) end
		if env.log then env.log("stock: " .. tostring(kind) .. " refused here: " .. tostring(why or text)) end
		return false, why or text
	end
	local my = findCo(st.co, env.myCo)
	if not (live(my) and my.ent) then return no(T("Vous n'avez pas d'entreprise.", "You have no company."), "no company") end
	local co, n = int(payload.co), int(payload.n) or 1
	local reasons = {
		["the stock market is not open yet"] = T("La bourse ouvre au début du mois prochain.", "The stock market opens at the start of next month."),
		["not listed"] = T("Cette entreprise sera cotée le mois prochain.", "This company is listed next month."),
		["protected"] = T("Cette entreprise est encore protégée.", "This company is still protected."),
		["monthly limit"] = T("Pas plus de 2 actions par mois et par entreprise.", "No more than 2 shares a month per company."),
		["no share left"] = T("Plus aucune action de cette entreprise sur le marché.", "No share of this company left on the market."),
		["a computer company cannot be taken over"] = T("L'hôte n'autorise pas le rachat des IA.", "The host does not allow taking over computer companies."),
		["the company cannot buy them back this month"] = T("L'entreprise ne peut pas racheter ces actions ce mois-ci.", "The company cannot buy these shares back this month."),
		["takeover not confirmed"] = T("Au-delà de 50 %, c'est un rachat de toute l'entreprise : utilisez le bouton Racheter.", "Beyond 50 %, it is a takeover of the whole company: use the Take over button."),
	}
	local function refused(why) return no(reasons[why] or T("Impossible.", "Not possible."), why) end
	if kind == "buy" or kind == "takeover" then
		local ok, why, info = M.check(S, st.co, o, my.id, co, n, kind == "takeover")
		if not ok then return refused(why) end
		local bal = M.balanceOf(my.ent)
		local cost = info.takeover and info.total or info.cost
		if bal and bal < cost then return no(T("Pas assez d'argent.", "Not enough money."), "money") end
		local p = { co = co, n = n }
		if info.takeover then p.takeover = true; p.max = math.floor(num(payload.max) or info.total) end
		env.send("f_stock_buy", p)
		return true
	elseif kind == "sell" then
		local ok, why = M.checkSell(S, st.co, my.id, co, n)
		if not ok then return refused(why) end
		env.send("f_stock_sell", { co = co, n = n })
		return true
	end
	return false, "kind"
end

-- ---------------------------------------------------------------- the MPFever window's tab
-- M.view: the window file's lines -> what the tab shows (plain data, tested offline). M.ui draws it with the options host's helpers.
M.view = function(lines, T, myBal)
	T = T or M.T
	local v = { companies = {}, hold = {}, bought = {}, divs = {}, opt = nil, me = 0, myEnt = -1 }
	for _, line in ipairs(lines or {}) do
		local f = {}
		for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
		if f[1] == "opt" then
			v.opt = { premium = num(f[2]) or 0, ai = f[3] == "1", dividend = num(f[4]) or 0, month = num(f[5]) or -1, protect = num(f[6]) or M.PROTECT,
				limit = num(f[7]) or M.LIMIT, shares = num(f[8]) or M.SHARES }
		elseif f[1] == "me" then v.me, v.myEnt = num(f[2]) or 0, num(f[3]) or -1
		elseif f[1] == "co" then
			v.companies[#v.companies + 1] = { id = num(f[2]), ai = f[3] == "1", price = num(f[4]) or 0, prev = num(f[5]) or 0, value = num(f[6]) or 0,
				result = num(f[7]) or 0, div = num(f[8]) or 0, ["until"] = num(f[9]) or 0, float = num(f[10]) or 0, own = num(f[11]) or 0,
				color = num(f[12]) or 0, name = f[13] or "" }
		elseif f[1] == "hold" then v.hold[#v.hold + 1] = { co = num(f[2]), by = num(f[3]), n = num(f[4]) or 0, cost = num(f[5]) or 0 }
		elseif f[1] == "bought" then v.bought[#v.bought + 1] = { co = num(f[2]), by = num(f[3]), n = num(f[4]) or 0 }
		elseif f[1] == "divs" then v.divs[num(f[2]) or 0] = { paid = num(f[3]) or 0, got = num(f[4]) or 0 } end
	end
	local o = v.opt or { premium = 0, ai = false, dividend = 0, month = -1, protect = M.PROTECT, limit = M.LIMIT, shares = M.SHARES }
	local function holdOf(co, by) for _, h in ipairs(v.hold) do if h.co == co and h.by == by then return h.n, h.cost end end return 0, 0 end
	local function boughtOf(co, by) for _, b in ipairs(v.bought) do if b.co == co and b.by == by then return b.n end end return 0 end
	local byId = {}
	for _, c in ipairs(v.companies) do byId[c.id] = c end
	-- each company's line: price, change, value, dividend, my shares, and what this company may do there now
	v.rows = {}
	for _, c in ipairs(v.companies) do
		local mine = c.id == v.me
		local myN = holdOf(c.id, v.me)
		local row = { id = c.id, name = c.name, ai = c.ai, mine = mine, price = c.price, value = c.value, div = c.div, held = myN, float = c.float,
			own = c.own, listed = c.price > 0 }
		if c.prev > 0 and c.price > 0 then row.change = math.floor((c.price - c.prev) * 1000 / c.prev) / 10 end
		if not row.listed then
			row.status = (o.month < 0) and T("La bourse ouvre au début du mois prochain.", "The stock market opens at the start of next month.")
				or T("Cotée le mois prochain.", "Listed next month.")
		elseif not mine and c["until"] > o.month then
			row.status = fmt(T("Protégée encore %s mois.", "Protected for %s more months."), c["until"] - o.month)
		end
		if row.listed and v.me > 0 and byId[v.me] then
			local left = o.limit - boughtOf(c.id, v.me)
			local n = math.min(left, c.float, o.limit)
			local beyond = not mine and myN + 1 > o.shares / 2
			if beyond then
				-- (the share that goes beyond half: the whole company, at the price and the premium; a company above half already, by
				-- the shares of one it took over, needs no share of the market)
				local unit = math.floor(c.price * (100 + o.premium) / 100)
				local need = myN > o.shares / 2 and 0 or 1
				row.takeover = { n = need, total = unit * (o.shares - myN), allowed = (not c.ai or o.ai) and (need == 0 or (c.float >= 1 and left >= 1))
					and not row.status }
				if c.ai and not o.ai then row.note = T("L'hôte n'autorise pas le rachat des IA.", "The host does not allow taking over computer companies.") end
			elseif n >= 1 and not row.status then
				row.buy = { n = 1, cost = c.price, allowed = myBal == nil or myBal >= c.price }
			end
			if myN > 0 then row.sell = { n = 1 } end
			if not row.buy and not row.takeover and n < 1 and not row.status then
				row.note = c.float < 1 and T("Plus aucune action sur le marché.", "No share left on the market.")
					or T("Limite du mois atteinte (2 actions).", "This month's limit reached (2 shares).")
			end
		end
		v.rows[#v.rows + 1] = row
	end
	-- D7: the ranking by value
	table.sort(v.rows, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.id < b.id end)
	for i, r in ipairs(v.rows) do r.rank = i end
	-- who holds this player's company
	v.holders = {}
	for _, h in ipairs(v.hold) do
		if h.co == v.me and h.by ~= v.me and byId[h.by] then v.holders[#v.holders + 1] = { id = h.by, name = byId[h.by].name, n = h.n, alert = h.n >= 3 } end
	end
	v.portfolio = { value = 0, got = (v.divs[v.me] or {}).got or 0 }
	for _, h in ipairs(v.hold) do
		if h.by == v.me and h.co ~= v.me and byId[h.co] then v.portfolio.value = v.portfolio.value + h.n * byId[h.co].price end
	end
	v.optText = fmt(T("Prime de rachat : %s %. Dividendes : %s % du résultat du mois. Rachat des IA : %s.",
		"Takeover premium: %s %. Dividends: %s % of the month's result. Computer companies can be taken over: %s."),
		o.premium, o.dividend, o.ai and T("oui", "yes") or T("non", "no"))
	return v
end

-- the takeover's second click: armed by the first one for 10 s (this window only)
M.armed = nil

-- M.ui(u): the tab, with the window's helpers (U.featU of mpfever_ui.script.lua): u.T, u.read, u.request and the widgets
-- u.title(t), u.text(s), u.muted(s), u.button(label, fn, primary, enabled), u.row(children). Each row goes in with u.add; without
-- u.add (an older window), the rows are returned instead (never both: the window would draw them twice)
function M.ui(u)
	local T = u.T or M.T
	local now = os.clock()
	local lines = u.read and u.read("stock") or {}
	local myBal = nil
	for _, line in ipairs(lines) do
		local ent = line:match("^me\t%d+\t(%-?%d+)")
		if ent and tonumber(ent) >= 0 then myBal = M.balanceOf(tonumber(ent)) end
	end
	local v = M.view(lines, T, myBal)
	local money = u.money or M.money
	local out = {}
	local function add(w) if w ~= nil then out[#out + 1] = w; if u.add then u.add(w) end end end
	local function title(s) add((u.title and u.title(s)) or (u.section and u.section(s)) or u.text(s)) end
	-- (0.7.4, the menus redone: a card a company, see M.uiCards; the window's old pages asked: the Hub's page of 0.7.3)
	if u.rich and u.card and u.stats and u.add and not u.oldMenus then return M.uiCards(u, v, myBal, now) end
	if u.rich and u.card and u.table and u.add then return M.uiRich(u, v, myBal, now) end
	title(T("Bourse", "Stock market"))
	add(u.muted(T("Chaque entreprise a 10 actions. Prix = valeur / 10 ; valeur = argent - prêts + revente des véhicules, mesurée par l'hôte chaque mois. L'argent d'un achat va à l'entreprise ; au-delà de 50 %, on rachète toute l'entreprise.",
		"Every company has 10 shares. Price = value / 10; value = money - loans + resale value of the vehicles, measured by the host every month. The money of a purchase goes to the company; beyond 50 %, you take the whole company over.")))
	add(u.muted(v.optText))
	if v.me > 0 then
		add(u.text(fmt(T("Votre portefeuille : %s. Dividendes reçus : %s.", "Your portfolio: %s. Dividends received: %s."), money(v.portfolio.value), money(v.portfolio.got))))
		for _, h in ipairs(v.holders) do
			local s = fmt(T("%s détient %s actions sur 10 de votre entreprise.", "%s holds %s of the 10 shares of your company."), h.name, h.n)
			add(h.alert and u.text(s) or u.muted(s))
		end
	end
	title(T("Classement par valeur", "Ranking by value"))
	for _, r in ipairs(v.rows) do
		local change = r.change and ((r.change >= 0 and "+" or "") .. tostring(r.change) .. " %") or ""
		add(u.text(fmt(T("%s. %s : valeur %s, action %s %s, dividende %s", "%s. %s: value %s, share %s %s, dividend %s"),
			r.rank, r.name, money(r.value), r.listed and money(r.price) or "-", change, money(r.div))))
		local info = fmt(T("Vous : %s/10. Sur le marché : %s. Propres : %s.", "You: %s/10. On the market: %s. Own: %s."), r.held, r.float, r.own)
		local buttons = {}
		if r.buy then
			buttons[#buttons + 1] = u.button(r.mine and fmt(T("Racheter 1 action (%s)", "Buy 1 back (%s)"), money(r.buy.cost)) or fmt(T("Acheter 1 (%s)", "Buy 1 (%s)"), money(r.buy.cost)),
				function() u.request("buy", { co = r.id, n = 1 }) end, false, r.buy.allowed)
		end
		if r.takeover then
			local armed = M.armed and M.armed.co == r.id and now - M.armed.at < 10
			local label = armed and fmt(T("Confirmer le rachat (%s)", "Confirm the takeover (%s)"), money(r.takeover.total))
				or fmt(T("Racheter l'entreprise (%s)", "Take over (%s)"), money(r.takeover.total))
			buttons[#buttons + 1] = u.button(label, function()
				if M.armed and M.armed.co == r.id and os.clock() - M.armed.at < 10 then
					M.armed = nil
					u.request("takeover", { co = r.id, n = r.takeover.n, max = r.takeover.total })
				else
					M.armed = { co = r.id, at = os.clock() }
				end
			end, armed, r.takeover.allowed and (myBal == nil or myBal >= r.takeover.total))
		end
		if r.sell then
			buttons[#buttons + 1] = u.button(T("Vendre 1", "Sell 1"), function() u.request("sell", { co = r.id, n = 1 }) end, false, true)
		end
		add(u.muted(info))
		if r.status then add(u.muted(r.status)) end
		if r.note then add(u.muted(r.note)) end
		if #buttons > 0 then add(u.row(buttons)) end
	end
	if u.add then return {} end
	return out
end

-- (0.6) the tab in the Hub (u.rich): the rules and this player's portfolio as figures, the ranking as a table (this company on a
-- band of its own) with the values as bars in the companies' colours, then a card per company with what this company may do there
-- (the same buttons and requests as above)
function M.uiRich(u, v, myBal, now)
	local T = u.T or M.T
	local money = u.money or M.money
	local W = tonumber(u.W) or 556
	local add = u.add
	add(u.title(T("Bourse", "Stock market")))
	add(u.muted(T("Chaque entreprise a 10 actions. Prix = valeur / 10 ; valeur = argent - prêts + revente des véhicules, mesurée par l'hôte chaque mois. L'argent d'un achat va à l'entreprise ; au-delà de 50 %, on rachète toute l'entreprise.",
		"Every company has 10 shares. Price = value / 10; value = money - loans + resale value of the vehicles, measured by the host every month. The money of a purchase goes to the company; beyond 50 %, you take the whole company over.")))
	add(u.muted(v.optText))
	if v.me > 0 then
		add(u.gap(6))
		add(u.stats({ { T("Votre portefeuille", "Your portfolio"), money(v.portfolio.value) }, { T("Dividendes reçus", "Dividends received"), money(v.portfolio.got) } }, 220))
		for _, h in ipairs(v.holders) do
			local s = fmt(T("%s détient %s actions sur 10 de votre entreprise.", "%s holds %s of the 10 shares of your company."), h.name, h.n)
			add(h.alert and u.text(s, "warning") or u.muted(s))
		end
	end
	add(u.title(T("Classement par valeur", "Ranking by value")))
	local lines = { { "#", T("Entreprise", "Company"), T("Valeur", "Value"), T("Action", "Share"), T("Variation", "Change"), T("Dividende", "Dividend"), T("Vous", "You") } }
	local top = 0
	for _, r in ipairs(v.rows) do
		lines[#lines + 1] = { tostring(r.rank), r.name, money(r.value), r.listed and money(r.price) or "-",
			r.change and ((r.change >= 0 and "+" or "") .. tostring(r.change) .. " %") or "", money(r.div), r.held .. "/10" }
		if r.value > top then top = r.value end
	end
	local rows = v.rows
	add(u.table(lines, { 6, 26, 15, 13, 12, 15, 9 }, true, { highlight = function(i) return rows[i] and rows[i].mine end }))
	if u.bar and top > 0 then
		add(u.gap(6))
		for _, r in ipairs(v.rows) do
			add(u.bar(math.max(0, r.value) / top, (u.coColor and u.coColor(r.id)) or r.id, money(r.value), { lead = r.name, leadW = math.floor(W * 0.3), labelW = 130 }))
		end
	end
	for _, r in ipairs(v.rows) do
		local kids = { u.muted(fmt(T("Vous : %s/10. Sur le marché : %s. Propres : %s.", "You: %s/10. On the market: %s. Own: %s."), r.held, r.float, r.own)) }
		if r.status then kids[#kids + 1] = u.muted(r.status) end
		if r.note then kids[#kids + 1] = u.muted(r.note) end
		local buttons = {}
		if r.buy then
			buttons[#buttons + 1] = u.button(r.mine and fmt(T("Racheter 1 action (%s)", "Buy 1 back (%s)"), money(r.buy.cost)) or fmt(T("Acheter 1 (%s)", "Buy 1 (%s)"), money(r.buy.cost)),
				function() u.request("buy", { co = r.id, n = 1 }) end, true, r.buy.allowed)
		end
		if r.takeover then
			local armed = M.armed and M.armed.co == r.id and now - M.armed.at < 10
			local label = armed and fmt(T("Confirmer le rachat (%s)", "Confirm the takeover (%s)"), money(r.takeover.total))
				or fmt(T("Racheter l'entreprise (%s)", "Take over (%s)"), money(r.takeover.total))
			buttons[#buttons + 1] = u.button(label, function()
				if M.armed and M.armed.co == r.id and os.clock() - M.armed.at < 10 then
					M.armed = nil
					u.request("takeover", { co = r.id, n = r.takeover.n, max = r.takeover.total })
				else
					M.armed = { co = r.id, at = os.clock() }
				end
			end, armed, r.takeover.allowed and (myBal == nil or myBal >= r.takeover.total))
		end
		if r.sell then
			buttons[#buttons + 1] = u.button(T("Vendre 1", "Sell 1"), function() u.request("sell", { co = r.id, n = 1 }) end, false, true)
		end
		if #buttons > 0 then kids[#kids + 1] = u.row(buttons) end
		add(u.gap(8))
		add(u.card(fmt("%s. %s", r.rank, r.name) .. (r.mine and (" " .. T("(vous)", "(you)")) or ""), kids, { color = (u.coColor and u.coColor(r.id)) or r.id,
			tint = r.mine and "info" or nil }))
	end
	return {}
end

-- (0.7.4, the menus redone) the tab in the Hub with each company shown once (0.7.3 showed it three times: the table, the bars and a
-- card): a card a company, by rank, its figures as boxes (value, share and its change, dividend, your shares), what is on the
-- market, and what your company may do there (the same buttons and requests as M.uiRich)
M.TX = {
	help1 = { "Chaque entreprise a 10 actions. Leur prix est la valeur de l'entreprise divisée par 10 ; la valeur, mesurée par l'hôte chaque mois, est l'argent moins les prêts, plus la revente des véhicules. Vous pouvez acheter au plus 2 actions d'une entreprise par mois.",
		"Every company has 10 shares. Their price is the company's value divided by 10; the value, measured by the host every month, is the money less the loans, plus the vehicles' resale value. You may buy at most 2 shares of a company a month." },
	help2 = { "L'argent d'un achat va à l'entreprise dont vous achetez l'action. Chaque mois, une part du résultat est versée en dividendes aux actionnaires. Vendre une action vous rend son prix du moment.",
		"The money of a purchase goes to the company whose share you buy. Every month, a part of the result is paid as dividends to the shareholders. Selling a share gives you its price of the moment." },
	help3 = { "Au-delà de 5 actions sur 10, vous rachetez toute l'entreprise, à son prix plus la prime de rachat (un second clic confirme). Une entreprise nouvelle est protégée quelques mois. Le chef de votre entreprise est prévenu quand une autre en détient beaucoup.",
		"Beyond 5 shares out of 10 you take the whole company over, at its price plus the takeover premium (a second click confirms). A new company is protected for a few months. Your company's chief is warned when another one holds many of its shares." },
}
function M.uiCards(u, v, myBal, now)
	local T = u.T or M.T
	local money = u.money or M.money
	local W = tonumber(u.W) or 556
	local add = u.add
	add(u.title(T("Bourse", "Stock market")))
	add(u.muted(v.optText))
	if v.me > 0 then
		add(u.gap(6))
		add(u.stats({ { T("Votre portefeuille", "Your portfolio"), money(v.portfolio.value) }, { T("Dividendes reçus", "Dividends received"), money(v.portfolio.got) } }, 220))
		for _, h in ipairs(v.holders) do
			local s = fmt(T("%s détient %s actions sur 10 de votre entreprise.", "%s holds %s of the 10 shares of your company."), h.name, h.n)
			add(h.alert and u.text(s, "warning") or u.muted(s))
		end
	end
	add(u.title(T("Classement par valeur", "Ranking by value")))
	-- (a box is its width plus its padding: four of them and their gaps in the card's width)
	local bw = math.max(100, math.floor((W - 30) / 4) - 22)
	for _, r in ipairs(v.rows) do
		local change = r.change and ((r.change >= 0 and "+" or "") .. tostring(r.change) .. " %") or nil
		local kids = {
			u.stats({ { T("Valeur", "Value"), money(r.value) },
				{ T("Action", "Share") .. (change and ("  " .. change) or ""), r.listed and money(r.price) or "-", r.change and (r.change > 0 and "success" or (r.change < 0 and "error" or nil)) or nil },
				{ T("Dividende", "Dividend"), money(r.div) }, { T("Vos actions", "Your shares"), r.held .. "/10" } }, bw),
			u.muted(fmt(T("Sur le marché : %s. Propres : %s.", "On the market: %s. Own: %s."), r.float, r.own)),
		}
		if r.status then kids[#kids + 1] = u.muted(r.status) end
		if r.note then kids[#kids + 1] = u.muted(r.note) end
		local buttons = {}
		if r.buy then
			buttons[#buttons + 1] = u.button(r.mine and fmt(T("Racheter 1 action (%s)", "Buy 1 back (%s)"), money(r.buy.cost)) or fmt(T("Acheter 1 (%s)", "Buy 1 (%s)"), money(r.buy.cost)),
				function() u.request("buy", { co = r.id, n = 1 }) end, true, r.buy.allowed)
		end
		if r.takeover then
			local armed = M.armed and M.armed.co == r.id and now - M.armed.at < 10
			local label = armed and fmt(T("Confirmer le rachat (%s)", "Confirm the takeover (%s)"), money(r.takeover.total))
				or fmt(T("Racheter l'entreprise (%s)", "Take over (%s)"), money(r.takeover.total))
			buttons[#buttons + 1] = u.button(label, function()
				if M.armed and M.armed.co == r.id and os.clock() - M.armed.at < 10 then
					M.armed = nil
					u.request("takeover", { co = r.id, n = r.takeover.n, max = r.takeover.total })
				else
					M.armed = { co = r.id, at = os.clock() }
				end
			end, armed, r.takeover.allowed and (myBal == nil or myBal >= r.takeover.total))
		end
		if r.sell then
			buttons[#buttons + 1] = u.button(T("Vendre 1", "Sell 1"), function() u.request("sell", { co = r.id, n = 1 }) end, false, true)
		end
		if #buttons > 0 then kids[#kids + 1] = u.gap(4); kids[#kids + 1] = u.row(buttons) end
		add(u.gap(8))
		add(u.card(fmt("%s. %s", r.rank, r.name) .. (r.mine and (" " .. T("(vous)", "(you)")) or ""), kids, { color = (u.coColor and u.coColor(r.id)) or r.id,
			tint = r.mine and "info" or nil }))
	end
	if u.help then pcall(u.help, "stock", { M.TX.help1, M.TX.help2, M.TX.help3 }) end
	return {}
end

return M
