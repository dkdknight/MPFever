-- MPFever: the fine drift diagnostic (0.8.7 diagnostic build, MPFEVER_FINEDIAG=1; nothing of it runs without that switch).
--
-- Why: the drift diagnostic of 0.8.2 (native rings) names the first engine operation that differs between two games (#150:
-- an aircraft's octree node, AircraftMoveSystem, on Leawood and in #255/#284), but not the numbers that led to it. This module
-- notes, at EVERY simulation step and on the simulation's own thread (the bridge's update), the full moving state of every
-- aircraft and a digest of every animal, in a ring of the last steps. When the mod keeps a drift (SDUMP.keepDrift writes the
-- check's number to native_drift.txt), the ring is written to finediag_<check>.txt. Two games' files compared step by step
-- (tools/finediag_diff.py) give the first step, the first aircraft and the first number that differ.
--
-- It reads only (api.engine.getComponent), never changes the game. Its cost is logged once a minute ("fine diagnostic: ...").
-- MPFEVER_FINEDIAG_STEPS=<n>: the ring's length (default 6000 steps, 20 min of game at x1); MPFEVER_FINEDIAG_FULL=<n>: the
-- steps with every animal's own numbers (default 200); MPFEVER_FINEDIAG_LAND=1: the land vehicles' digest too (costly on big maps).
local M = {}

local function num(x)
	if type(x) == "number" then
		if x ~= x then return "nan" end
		return string.format("%.17g", x)
	end
	return tostring(x)
end

-- a marshaled value as sorted "key=value" pairs, numbers exact (%.17g)
local function flat(v, prefix, out, d)
	if type(v) == "table" then
		if d > 6 then out[#out + 1] = prefix .. "=..."; return end
		local keys = {}
		for k in pairs(v) do if k ~= "__ud" and k ~= "__vec" then keys[#keys + 1] = k end end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do flat(v[k], prefix .. "." .. tostring(k), out, d + 1) end
	else
		out[#out + 1] = prefix .. "=" .. num(v)
	end
end

local function pathInfo(p)
	local n, off = "?", "?"
	pcall(function() n = #p.edges end)
	pcall(function() off = p.endOffset end)
	return tostring(n) .. "/" .. tostring(off)
end

function M.init(E)
	local FD = {
		E = E, ring = {}, size = tonumber(os.getenv("MPFEVER_FINEDIAG_STEPS") or "") or 6000,
		full = tonumber(os.getenv("MPFEVER_FINEDIAG_FULL") or "") or 200, land = os.getenv("MPFEVER_FINEDIAG_LAND") == "1",
		personsEvery = tonumber(os.getenv("MPFEVER_FINEDIAG_PERSONS") or "") or 25,
		head = 0, count = 0, lastT = nil, costSum = 0, costMax = 0, costN = 0, costAt = os.clock(), drift = nil, pollN = 0,
	}
	-- (the request already there at the start is not a new one)
	pcall(function()
		local f = E.C.IO.open(E.C.DIR .. E.BS .. "native_drift.txt", "rb")
		if f then FD.drift = f:read("*a"); f:close() end
	end)
	E.log(string.format("fine diagnostic: on (every aircraft's moving state and the animals' digest at every step, persons and cargo every %d steps, ring of %d steps, %d with every animal%s)",
		FD.personsEvery, FD.size, FD.full, FD.land and ", land vehicles' digest too" or ""))
	return FD
end

-- one aircraft's moving state, every number exact
local function aircraftRec(E, e)
	local api, C = E.api, E.C
	local CT = api.type.ComponentType
	local out = {}
	local mp = api.engine.getComponent(e, CT.MOVE_PATH_AIRCRAFT)
	if mp then
		for _, k in ipairs({ "speed", "speed0", "brakeDecel" }) do pcall(function() out[#out + 1] = k .. "=" .. num(mp[k]) end) end
		for _, k in ipairs({ "pathPos", "pathPos0", "state", "pathState", "aircraftState" }) do
			pcall(function() flat(C.marshal(mp[k]), k, out, 0) end)
		end
		for _, k in ipairs({ "path0", "path2" }) do pcall(function() out[#out + 1] = k .. "=" .. pathInfo(mp[k]) end) end
		pcall(function() out[#out + 1] = "path1=" .. tostring(#mp.path1) end)
	end
	local ac = api.engine.getComponent(e, CT.AIRCRAFT)
	if ac then pcall(function() flat(C.marshal(ac), "ac", out, 0) end) end
	return table.concat(out, " ")
end

-- the drift kept by the mod (native_drift.txt changed): the ring to finediag_<check>.txt
local function writeRing(FD, check)
	local E = FD.E
	local name = "finediag_" .. tostring(check):gsub("[^%w]", "") .. ".txt"
	local f = E.C.IO.open(E.C.DIR .. E.BS .. name, "wb")
	if not f then return end
	f:write("fine diagnostic of check ", tostring(check), ": the last ", tostring(FD.count), " steps (step = game time)", E.NL)
	f:write("step <t>; A <aircraft> <its numbers>; N <animals> <sum x> <sum y> <sum z> <sum speed> <sum target x> <sum target y>; a <animal> <x> <y> <z> <speed> <tx> <ty> <type>; L <land vehicles digest>", E.NL)
	local first = FD.head - FD.count
	for i = first + 1, FD.head do
		local r = FD.ring[(i - 1) % FD.size + 1]
		if r then
			f:write("step ", num(r.t), E.NL)
			if r.air ~= "" then f:write(r.air, E.NL) end
			f:write(r.animals, E.NL)
			if r.animalsFull then f:write(r.animalsFull, E.NL) end
			if r.landDigest then f:write(r.landDigest, E.NL) end
			if r.persons then f:write(r.persons, E.NL) end
		end
	end
	f:close()
	E.log("fine diagnostic: " .. name .. " written (" .. FD.count .. " steps)")
end

function M.step(FD)
	local E = FD.E
	local api = E.api
	local CT = api.type.ComponentType
	local okT, t = pcall(E.gameTime)
	if not okT or t == FD.lastT then return end
	FD.lastT = t
	local c0 = os.clock()
	local rec = { t = t }
	-- every aircraft (by id: the same order on every game while their ids are alike)
	local air = {}
	local list = E.R.entitiesWith("MOVE_PATH_AIRCRAFT")
	table.sort(list)
	for _, e in ipairs(list) do
		local ok, s = pcall(aircraftRec, E, e)
		air[#air + 1] = "A " .. tostring(e) .. " " .. (ok and s or ("error " .. tostring(s)))
	end
	rec.air = table.concat(air, E.NL)
	-- the animals: sums every step, each one's numbers for the last FD.full steps
	local an = E.R.entitiesWith("ANIMAL")
	table.sort(an)
	local sx, sy, sz, ss, stx, sty = 0, 0, 0, 0, 0, 0
	local keepFull = FD.full > 0
	local full = keepFull and {} or nil
	for _, e in ipairs(an) do
		pcall(function()
			local a = api.engine.getComponent(e, CT.ANIMAL)
			if not a then return end
			local p, tc = a.worldPosition, a.targetCoord
			local x, y, z, s, tx, ty = p.x, p.y, p.z, a.movementSpeed, tc.x, tc.y
			sx, sy, sz, ss, stx, sty = sx + x, sy + y, sz + z, ss + s, stx + tx, sty + ty
			if full then full[#full + 1] = "a " .. e .. " " .. num(x) .. " " .. num(y) .. " " .. num(z) .. " " .. num(s) .. " " .. num(tx) .. " " .. num(ty) .. " " .. tostring(a.movementType) end
		end)
	end
	rec.animals = "N " .. #an .. " " .. num(sx) .. " " .. num(sy) .. " " .. num(sz) .. " " .. num(ss) .. " " .. num(stx) .. " " .. num(sty)
	if full then rec.animalsFull = table.concat(full, E.NL) end
	-- (the land vehicles: one digest a step, MPFEVER_FINEDIAG_LAND=1)
	if FD.land then
		local lv = E.R.entitiesWith("MOVE_PATH")
		table.sort(lv)
		local a1, a2, a3 = 0, 0, 0
		for _, e in ipairs(lv) do
			pcall(function()
				local m = api.engine.getComponent(e, CT.MOVE_PATH)
				if not m then return end
				local d = E.C.marshal(m.dyn)
				for k, v in pairs(d or {}) do if type(v) == "number" then a1 = a1 + v end end
				a2 = a2 + (m.endPos or 0)
				a3 = a3 + (m.blocked or 0)
			end)
		end
		rec.landDigest = "L " .. #lv .. " " .. num(a1) .. " " .. num(a2) .. " " .. num(a3)
	end
	-- (the persons and the cargo: counts and sums by state every FD.personsEvery steps; the aircraft carry the persons, and
	-- the Leawood drift of 2026-11-11 showed in the persons' digest first)
	if FD.personsEvery > 0 and FD.head % FD.personsEvery == 0 then
		local parts = {}
		local function sums(ct, fields)
			local n, acc = 0, {}
			for i = 1, #fields do acc[i] = 0 end
			-- (by id: floating-point sums depend on their order)
			local ents = E.R.entitiesWith(ct)
			table.sort(ents)
			n = #ents
			if #fields > 0 then
				for _, e in ipairs(ents) do
					pcall(function()
						local c = api.engine.getComponent(e, CT[ct])
						if c then
							for i, f in ipairs(fields) do local v = c[f]; if type(v) == "number" then acc[i] = acc[i] + v end end
						end
					end)
				end
			end
			local s = { ct, tostring(n) }
			for i = 1, #fields do s[#s + 1] = num(acc[i]) end
			parts[#parts + 1] = table.concat(s, " ")
		end
		sums("SIM_ENTITY_MOVING", { "expectedArrivalTime", "lineStop0", "lineStop1" })
		sums("SIM_ENTITY_AT_VEHICLE", { "roundTripCounter", "lineStop0", "lineStop1" })
		sums("SIM_ENTITY_AT_TERMINAL", { "arrivalTime", "lineStop0", "lineStop1" })
		sums("SIM_ENTITY_AT_BUILDING", { "waitingTime" })
		sums("SIM_ENTITY_IDLE", {})
		sums("SIM_PERSON_AT_VEHICLE", { "expectedArrivalTime", "part", "place" })
		sums("SIM_PERSON", { "walkSpeed", "modelIdPerson" })
		sums("SIM_CARGO", { "speed", "startTime", "pickupTime" })
		rec.persons = "P " .. table.concat(parts, " ; ")
	end
	-- into the ring; the animals' own numbers dropped from the steps older than FD.full
	FD.head = FD.head + 1
	FD.ring[(FD.head - 1) % FD.size + 1] = rec
	FD.count = math.min(FD.count + 1, FD.size)
	if FD.full > 0 and FD.head > FD.full then
		local old = FD.ring[(FD.head - FD.full - 1) % FD.size + 1]
		if old then old.animalsFull = nil end
	end
	-- (its cost, logged once a minute)
	local dt = os.clock() - c0
	FD.costSum, FD.costN, FD.costMax = FD.costSum + dt, FD.costN + 1, math.max(FD.costMax, dt)
	if os.clock() - FD.costAt > 60 then
		E.log(string.format("fine diagnostic: %d step(s) noted in the last minute, %.1f ms a step on average, %.1f ms at most (%d aircraft, %d animals)",
			FD.costN, FD.costSum * 1000 / math.max(1, FD.costN), FD.costMax * 1000, #list, #an))
		FD.costSum, FD.costN, FD.costMax, FD.costAt = 0, 0, 0, os.clock()
	end
	-- (a drift kept by the mod: every 16 steps, native_drift.txt read again)
	FD.pollN = FD.pollN + 1
	if FD.pollN % 16 == 0 then
		local cur
		pcall(function()
			local f = E.C.IO.open(E.C.DIR .. E.BS .. "native_drift.txt", "rb")
			if f then cur = f:read("*a"); f:close() end
		end)
		if cur and cur ~= "" and cur ~= FD.drift then
			FD.drift = cur
			local check = cur:match("(%d+)") or "x"
			local okW, errW = pcall(writeRing, FD, check)
			if not okW then E.log("fine diagnostic: the ring not written: " .. tostring(errW)) end
		end
	end
end

-- (for the offline test)
M.num, M.flat, M.writeRing = num, flat, writeRing
return M
