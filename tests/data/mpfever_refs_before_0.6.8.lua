-- MPFever entity references.
--
-- Entity ids are NOT the same on every machine: the UI of one game allocates entities the others never see
-- (previews, store windows...), so every entity allocated afterwards can get a different id. An action therefore
-- never travels with a raw id for something built during the session: the originator replaces each entity id with a
-- reference describing the entity (construction file + position, depot/station = its construction + index, road
-- node = position, road edge = its end positions, station group = one of its stations, line/vehicle created during
-- the session = the key of the action that created it). Every game resolves the reference against its own world:
-- the same id is used when it still describes the same thing (everything that came from the save), otherwise the
-- entity is searched for.

local R = {}

local CT = function(name) return api.type.ComponentType[name] end

local function comp(e, name)
	if type(e) ~= "number" or e < 0 then return nil end
	local ok, exists = pcall(function() return api.engine.entityExists(e) end)
	if not ok or not exists then return nil end
	local okc, c = pcall(function() return api.engine.getComponent(e, CT(name)) end)
	if okc then return c end
	return nil
end

local function pos3(v)
	if v == nil then return nil end
	local ok, p = pcall(function() return { x = v.x, y = v.y, z = v.z } end)
	if ok and type(p.x) == "number" then return p end
	return nil
end

local function matPos(m)
	if m == nil then return nil end
	local ok, p = pcall(function() return { x = m[13], y = m[14], z = m[15] } end)
	if ok and type(p.x) == "number" then return p end
	return nil
end

R.matPos = matPos

local function dist(a, b)
	if not a or not b then return math.huge end
	local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function listIndex(list, e)
	local found = nil
	pcall(function()
		for i = 1, #list do if list[i] == e then found = i end end
	end)
	return found
end

local function nodePos(n)
	local c = comp(n, "BASE_NODE")
	return c and pos3(c.position) or nil
end

-- ------------------------------------------------------------------ describe (originator side)

local describe

-- (0.5.1, MPFEVER_ASSETREF=0) a tree, a plant or a rock (placed with the brush): an entity of models without a construction, known
-- by its first model and place
local function assetPlaceOld(e)
	local mil = comp(e, "MODEL_INSTANCE_LIST")
	if not mil then return nil end
	local p, m = nil, nil
	pcall(function()
		local inst = mil.fatInstances[1] or mil.thinInstances[1]
		m = inst.modelId
		p = matPos(inst.transf)
	end)
	return p, m
end

-- The name of a model, the same on every game (a model's number depends on the resources each game loaded), without the prefix
-- some places of the game write: "::/assets/x.mdl", "/assets/x.mdl" and "assets/x.mdl" are the same model.
local modelNames = {}
local function normModel(name)
	return (tostring(name or ""):gsub("^::/*", ""):gsub("^/+", ""))
end
local function modelName(id)
	if id == nil then return nil end
	if type(id) ~= "number" then return normModel(id) end
	local n = modelNames[id]
	if n == nil then
		local ok, s = pcall(function() return api.res.modelRep.getName(id) end)
		n = (ok and type(s) == "string" and s ~= "") and normModel(s) or ("#" .. tostring(id))
		modelNames[id] = n
	end
	return n
end
R.normModel, R.modelName = normModel, modelName

-- The trees a build adds (the asset capture's list: each construction's matrix and its models, a name and a matrix relative to
-- it), by their place on the map, in cells of 1 m: what R.isKept looks in. nil when it adds none.
function R.keptGrid(assets)
	local grid, n = {}, 0
	for _, as in ipairs(assets or {}) do
		local t = as.transf
		if type(t) == "table" and type(t[13]) == "number" then
			for _, m in ipairs(as.models or {}) do
				local mt = m.transf
				if type(mt) == "table" and type(mt[13]) == "number" then
					local x, y, z = mt[13], mt[14], mt[15]
					local q = { m = normModel(m.id), x = t[1] * x + t[5] * y + t[9] * z + t[13], y = t[2] * x + t[6] * y + t[10] * z + t[14] }
					local key = math.floor(q.x) .. ":" .. math.floor(q.y)
					grid[key] = grid[key] or {}
					local cell = grid[key]
					cell[#cell + 1] = q
					n = n + 1
				end
			end
		end
	end
	return n > 0 and grid or nil
end

-- Whether the tree id at q is one the build adds back (kept: R.keptGrid): the same model less than 5 cm away (across)
function R.isKept(kept, id, q)
	if not kept or not q then return false end
	local name = nil
	local fx, fy = math.floor(q.x), math.floor(q.y)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for _, it in ipairs(kept[(fx + dx) .. ":" .. (fy + dy)] or {}) do
				if (it.x - q.x) ^ 2 + (it.y - q.y) ^ 2 < 0.0025 then
					name = name or modelName(id)
					if it.m == name then return true end
				end
			end
		end
	end
	return false
end

-- The fat models (a full matrix) and the thin ones (a position, an angle and a scale: the forests of a map are made of them) of
-- a model list, as two lists with :size() and :at(i) from 1: the native vectors (the converted tables copy a whole forest at
-- each read), else those tables.
local function instanceLists(mil)
	local function wrap(t) return { size = function() return #t end, at = function(_, i) return t[i] end } end
	local fv, tv = nil, nil
	pcall(function() local v = mil.fatInstances_native; if type(v:size()) == "number" then fv = v end end)
	if not fv then pcall(function() fv = wrap(mil.fatInstances) end) end
	pcall(function() local v = mil.thinInstances_native; if type(v:size()) == "number" then tv = v end end)
	if not tv then pcall(function() tv = wrap(mil.thinInstances) end) end
	return fv, tv
end

-- Every model of an asset entity (a group of trees, plants or rocks), the fat ones first: fn(modelId, position, instance, thin)
-- for each, until fn returns true. A thin model has no matrix: its position is its pos. Returns the numbers of fat and thin models
-- (without fn: only those numbers).
local function eachInstance(e, fn)
	local mil = comp(e, "MODEL_INSTANCE_LIST")
	if not mil then return 0, 0 end
	local fv, tv = instanceLists(mil)
	local nf, nt = 0, 0
	pcall(function() nf = fv:size() end)
	pcall(function() nt = tv:size() end)
	if fn then
		pcall(function()
			for i = 1, nf do
				local inst = fv:at(i)
				if fn(inst.modelId, matPos(inst.transf), inst, false) then return end
			end
			for i = 1, nt do
				local inst = tv:at(i)
				if fn(inst.modelId, pos3(inst.pos), inst, true) then return end
			end
		end)
	end
	return nf, nt
end
R.eachInstance = eachInstance
function R.instanceCounts(e) return eachInstance(e, nil) end

-- the centre of an entity's bounding box (nil without one)
local function bboxCentre(e)
	local bv = comp(e, "BOUNDING_VOLUME")
	if not bv then return nil end
	local p = nil
	pcall(function()
		local a, b = bv.bbox.min, bv.bbox.max
		p = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
	end)
	return p
end

-- A group of trees, plants or rocks: models without a construction (the forests of a map and the brush's trees have an AssetGroup
-- too; the trees the mod's construction rebuilt for another player may not, see H.assetdescribe)
function R.isTreeGroup(e)
	if type(e) ~= "number" or e < 0 or comp(e, "CONSTRUCTION") then return false end
	return comp(e, "ASSET_GROUP") ~= nil or comp(e, "MODEL_INSTANCE_LIST") ~= nil
end

-- (diagnostic, the asset logs) what an entity is made of: whether it exists, its components among those of trees and
-- constructions, and its numbers of fat and thin models
function R.assetComponents(e)
	local ex = nil
	pcall(function() ex = api.engine.entityExists(e) end)
	local have = {}
	for _, n in ipairs({ "CONSTRUCTION", "ASSET_GROUP", "MODEL_INSTANCE_LIST", "BOUNDING_VOLUME", "PLAYER_OWNED", "TOWN_BUILDING" }) do
		if comp(e, n) then have[#have + 1] = n end
	end
	local nf, nt = eachInstance(e, nil)
	return "exists " .. tostring(ex) .. " {" .. table.concat(have, ",") .. "}, fat " .. nf .. ", thin " .. nt
end

-- A tree, a plant or a rock: an entity of models without a construction (a group of them), known by its first model and its place,
-- and by its number of models. The forests of a map have thin models only, with no matrix: 0.5.1 read a matrix on them, got no
-- place, and dropped the removal of such a group without a word (the bulldozer on one tree of a forest: the builder's game freed
-- one entity more than the others, every later id differed, a resync minutes later). Without a readable model, the centre of its
-- bounding box (bb). MPFEVER_ASSETREF=0: as before
-- kept (the bulldozer on one tree: the trees the same build adds back, see R.keptGrid): a tree of the group that is NOT among them,
-- the one taken away. Described by its first tree (one the build keeps), a game whose loaded savegame already held the build found
-- that tree in what was left of the group, took the build for not applied and removed and built the trees once more there only
-- (other ids, a resynchronisation minutes later). The felled tree stands nowhere once the build is applied: the removal is then not
-- found, and replayAssets sees the build already made. Every tree kept (a reforestation, a whole group): its first, as before.
local function assetPlace(e, kept)
	local p, m = nil, nil
	local nf, nt = 0, 0
	if kept then
		nf, nt = eachInstance(e, function(id, q)
			if q and not R.isKept(kept, id, q) then p, m = q, modelName(id) return true end
		end)
	end
	if not p then
		nf, nt = eachInstance(e, function(id, q)
			if q then p, m = q, modelName(id) return true end
		end)
	end
	local bb = false
	if not p then
		p = bboxCentre(e)
		bb = p ~= nil
	end
	return p, m, nf + nt, bb
end

-- (0.5.1) a removed entity without a construction, as 0.5.1 described it (nil for a forest of thin models): see H.assetdescribe
function R.describeAssetOld(e)
	if comp(e, "CONSTRUCTION") then return nil end
	local p, m = assetPlaceOld(e)
	if p then return { k = "asset", id = e, p = p, m = m } end
	return nil
end

local function describeCon(e, kept)
	local c = comp(e, "CONSTRUCTION")
	if not c then
		if os.getenv("MPFEVER_ASSETREF") == "0" then return R.describeAssetOld(e) end
		-- (a group of trees is always described, even without a place: dropped, its removal was lost on the other games)
		local ag = comp(e, "ASSET_GROUP") ~= nil
		if not ag and not comp(e, "MODEL_INSTANCE_LIST") then return nil end
		local p, m, n, bb = assetPlace(e, kept)
		return { k = "asset", id = e, p = p, m = m, n = n, ag = ag, bb = bb or nil }
	end
	return { k = "con", id = e, f = c.fileName, p = matPos(c.transf) }
end

local function describeEdge(e)
	local c = comp(e, "BASE_EDGE")
	if not c then return nil end
	return { k = "edge", id = e, p0 = nodePos(c.node0), p1 = nodePos(c.node1) }
end

-- (kept: for a group of trees, the trees the same build adds back, see assetPlace)
describe = function(kind, e, kept)
	if type(e) ~= "number" or e < 0 then return nil end
	if kind == "con" then return describeCon(e, kept) end
	if kind == "node" then
		local p = nodePos(e)
		return p and { k = "node", id = e, p = p } or nil
	end
	if kind == "edge" then return describeEdge(e) end
	if kind == "depot" then
		local con = nil
		pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(e) end)
		local cd = describeCon(con)
		local cc = comp(con, "CONSTRUCTION")
		if cd and cc then return { k = "depot", id = e, con = cd, i = listIndex(cc.depots, e) } end
		return { k = "depot", id = e }
	end
	if kind == "station" then
		local con = nil
		pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(e) end)
		local cd = describeCon(con)
		local cc = comp(con, "CONSTRUCTION")
		if cd and cc then return { k = "station", id = e, con = cd, i = listIndex(cc.stations, e) } end
		-- a roadside stop: an edge object
		local edge = nil
		pcall(function() edge = api.engine.system.streetSystem.getEdgeForEdgeObject(e) end)
		local ed = describeEdge(edge)
		if ed then
			local side = nil
			pcall(function()
				local be = comp(edge, "BASE_EDGE")
				for i = 1, #be.objects do
					if be.objects[i][1] == e then side = be.objects[i][2] end
				end
			end)
			return { k = "station", id = e, edge = ed, side = side }
		end
		return { k = "station", id = e }
	end
	if kind == "sg" then
		local sg = comp(e, "STATION_GROUP")
		local first = nil
		pcall(function() first = sg.stations[1] end)
		return { k = "sg", id = e, st = describe("station", first) }
	end
	return { k = kind, id = e }
end
R.describe = describe

-- ------------------------------------------------------------------ resolve (every game)

-- Every entity with a component. forEachEntityWithComponent refuses some types ("Cannot loop over this component type":
-- BASE_EDGE, BASE_NODE...): the street graph comes from the street system instead.
local function streetMap()
	local ok, m = pcall(function() return api.engine.system.streetSystem.getNode2SegmentMap() end)
	return ok and m or {}
end

function R.allNodes()
	local r = {}
	for n, _ in pairs(streetMap()) do r[#r + 1] = n end
	table.sort(r)
	return r
end

function R.allEdges()
	local seen, r = {}, {}
	for _, segs in pairs(streetMap()) do
		local n = 0
		pcall(function() n = #segs end)
		for i = 1, n do
			local e = segs[i]
			if type(e) == "number" and not seen[e] then seen[e] = true; r[#r + 1] = e end
		end
	end
	table.sort(r)
	return r
end

R.loopErrors = {}
function R.entitiesWith(compName)
	if compName == "BASE_EDGE" then return R.allEdges() end
	if compName == "BASE_NODE" then return R.allNodes() end
	if compName == "LINE" then
		local r = {}
		pcall(function() local l = api.engine.system.lineSystem.getLines(); for i = 1, #l do r[#r + 1] = l[i] end end)
		return r
	end
	local r = {}
	local ok, err = pcall(function()
		api.engine.forEachEntityWithComponent(function(e) r[#r + 1] = e end, CT(compName))
	end)
	if not ok then
		r = {}
		local ok2, list = pcall(function() return api.engine.getEntitiesWithComponent(CT(compName)) end)
		if ok2 and list then
			pcall(function() for i = 1, #list do r[#r + 1] = list[i] end end)
		else
			R.loopErrors[compName] = tostring(err):sub(1, 120)
		end
	end
	return r
end

local function nearestWith(compName, accept)
	local best, bestD = nil, math.huge
	for _, e in ipairs(R.entitiesWith(compName)) do
		local okd, d = pcall(accept, e)
		if okd and d and d < bestD then best, bestD = e, d end
	end
	return best, bestD
end

local resolve

-- trees, plants and rocks: placed with the brush (a construction without a file) on one game, rebuilt with the mod's own construction
-- on the others (see replayAssets in the bridge): the same thing for a reference
local function isAssetFile(f)
	f = tostring(f or "")
	return f == "" or f:find("mpfever_asset", 1, true) ~= nil
end
R.isAssetFile = isAssetFile

function R.withoutAssets(list)
	local r = {}
	for _, e in ipairs(list) do
		local c = comp(e, "CONSTRUCTION")
		if not (c and isAssetFile(c.fileName)) then r[#r + 1] = e end
	end
	return r
end

local function sameFile(a, b)
	return a == b or (isAssetFile(a) and isAssetFile(b))
end

local function resolveCon(r)
	if not r then return nil end
	local c = comp(r.id, "CONSTRUCTION")
	if c and sameFile(c.fileName, r.f) and dist(matPos(c.transf), r.p) < 1 then return r.id end
	local e, d = nearestWith("CONSTRUCTION", function(x)
		local cx = comp(x, "CONSTRUCTION")
		if cx and sameFile(cx.fileName, r.f) then return dist(matPos(cx.transf), r.p) end
		return nil
	end)
	if e and d < 3 then return e end
	return nil
end

-- A construction of file f standing at p (within tol metres), looked for among the constructions around p only (the octree, 50 m)
-- instead of every construction of the map (resolveCon's way, a tenth of a second on a large map): the nearest, nil when none.
-- Second result: whether the octree listed any construction around p at all (when it lists none, the caller may look the old way).
function R.conNear(f, p, tol)
	if not p then return nil, false end
	local list = R.assetsNear(p, 50, "CONSTRUCTION")
	local best, bestD = nil, math.huge
	for _, e in ipairs(list) do
		local c = comp(e, "CONSTRUCTION")
		if c and sameFile(c.fileName, f) then
			local d = dist(matPos(c.transf), p)
			if d <= tol and d < bestD then best, bestD = e, d end
		end
	end
	return best, #list > 0
end

-- The entities with this component around p (octree, radius in metres), by id.
local function assetsNear(p, radius, compName)
	local list, seen = {}, {}
	if not p then return list end
	pcall(function()
		local found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), radius, CT(compName))
		for i = 1, #found do
			local e = found[i]
			if type(e) == "number" and not seen[e] then seen[e] = true; list[#list + 1] = e end
		end
	end)
	table.sort(list)
	return list
end
R.assetsNear = assetsNear

-- How far the described tree is from entity e (nil: e does not hold it). e must be models without a construction; the tree is any
-- of its models (fat or thin) of the same model within 0.5 m: a group rebuilt by another game's replay has fat models where the
-- builder's had thin ones, and its first model may be another tree. Described by its bounding box (no readable model): the centre
-- of e's own, within 1 m. Described without a place: e itself, while it is still models without a construction.
local function assetDistance(e, r)
	if type(e) ~= "number" or e < 0 or comp(e, "CONSTRUCTION") then return nil end
	if r.p == nil then return (comp(e, "MODEL_INSTANCE_LIST") or comp(e, "ASSET_GROUP")) and 0 or nil end
	if r.bb then
		local d = dist(bboxCentre(e), r.p)
		return d < 1 and d or nil
	end
	local best = nil
	eachInstance(e, function(id, q)
		if q and (r.m == nil or modelName(id) == r.m) then
			local d = dist(q, r.p)
			if d < 0.5 and (best == nil or d < best) then best = d end
			return d < 0.001
		end
	end)
	return best
end

-- A group of trees: its own id when it still holds the described tree (the same id on every game for the savegame's groups and
-- for what was built in step), else the group holding it within 50 m (octree: the groups of trees first, then any entity with
-- models, as the trees of a replay may have no AssetGroup), the nearest, the lowest id on a tie. 0.5.1 scanned every entity with
-- models of the map instead (over 100 000 on a large one, each forest copied as a table). MPFEVER_ASSETREF=0: as before
local function resolveAsset(r)
	if assetDistance(r.id, r) then return r.id end
	if r.p == nil then return nil end
	for _, compName in ipairs({ "ASSET_GROUP", "MODEL_INSTANCE_LIST" }) do
		local best, bestD = nil, math.huge
		for _, e in ipairs(assetsNear(r.p, 50, compName)) do
			local d = assetDistance(e, r)
			if d and d < bestD then best, bestD = e, d end
		end
		if best then return best end
	end
	return nil
end

-- A node or segment whose id does not match is looked up by position. Scanning the whole street graph for each one made a
-- large station edit take seconds on the other games (issue #25): within one translation pass (R.translateIn, synchronous,
-- so the graph cannot change) the nodes are put once into a grid of 1 m cells, and the segments are found through the
-- nodes at their ends. The result is the same as the full scan's: the nearest within 1 m, the lowest id on a tie.
local function nodeGrid()
	local pass = R.pass
	if not pass then return nil end
	if not pass.grid then
		local grid, map = {}, streetMap()
		for n, _ in pairs(map) do
			local p = nodePos(n)
			if p then
				local key = math.floor(p.x) .. ":" .. math.floor(p.y)
				local cell = grid[key]
				if not cell then cell = {}; grid[key] = cell end
				cell[#cell + 1] = { n = n, p = p }
			end
		end
		pass.grid, pass.map = grid, map
	end
	return pass.grid, pass.map
end

-- the nodes less than 1 m from p, with their distance (nil without a pass)
local function nodesNear(p)
	local grid = nodeGrid()
	if not grid or not p then return nil end
	local out, cx, cy = {}, math.floor(p.x), math.floor(p.y)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for _, it in ipairs(grid[(cx + dx) .. ":" .. (cy + dy)] or {}) do
				local d = dist(it.p, p)
				if d < 1 then out[#out + 1] = { n = it.n, d = d } end
			end
		end
	end
	return out
end

local function better(e, d, best, bestD)
	return d < bestD or (d == bestD and best ~= nil and e < best)
end

local function resolveNode(r)
	if dist(nodePos(r.id), r.p) < 0.5 then return r.id end
	local near = nodesNear(r.p)
	if near then
		local best, bestD = nil, math.huge
		for _, it in ipairs(near) do if better(it.n, it.d, best, bestD) then best, bestD = it.n, it.d end end
		return best
	end
	local e, d = nearestWith("BASE_NODE", function(x) return dist(nodePos(x), r.p) end)
	if e and d < 1 then return e end
	return nil
end

local function resolveEdge(r)
	local function score(x)
		local c = comp(x, "BASE_EDGE")
		if not c then return nil end
		local a, b = nodePos(c.node0), nodePos(c.node1)
		return math.min(math.max(dist(a, r.p0), dist(b, r.p1)), math.max(dist(a, r.p1), dist(b, r.p0)))
	end
	local s = score(r.id)
	if s and s < 0.5 then return r.id end
	-- (a segment scoring under 1 m has an end less than 1 m from p0)
	local near = nodesNear(r.p0)
	if near then
		local _, map = nodeGrid()
		local best, bestD, seen = nil, math.huge, {}
		for _, it in ipairs(near) do
			local segs, n = map[it.n], 0
			pcall(function() n = #segs end)
			for i = 1, n do
				local x = segs[i]
				if type(x) == "number" and not seen[x] then
					seen[x] = true
					local d = score(x)
					if d and d < 1 and better(x, d, best, bestD) then best, bestD = x, d end
				end
			end
		end
		return best
	end
	local e, d = nearestWith("BASE_EDGE", score)
	if e and d < 1 then return e end
	return nil
end

-- (diagnostic) the ids this game gave to the segments and nodes at these places: {{p0, p1}...}, {p...} -> two id lists
function R.idsAt(segs, nodes)
	local outer = R.pass
	R.pass = {}
	local si, ni = {}, {}
	local ok = pcall(function()
		for i, sg in ipairs(segs or {}) do si[i] = resolveEdge({ id = -1, p0 = sg[1], p1 = sg[2] }) or -1 end
		for i, p in ipairs(nodes or {}) do ni[i] = resolveNode({ id = -1, p = p }) or -1 end
	end)
	R.pass = outer
	return si, ni, ok
end

resolve = function(r, bind)
	if type(r) ~= "table" then return r end
	if r.key and bind and bind[r.key] then
		-- (a line or a vehicle bound to a key must still be one: a removed line's key sent an update to an entity without a
		-- line, and the engine crashed, issue #53. Not the sender's id then: the ids of created things differ between games)
		local b = bind[r.key]
		if r.k == "line" then return comp(b, "LINE") and b or nil end
		if r.k == "veh" then return comp(b, "TRANSPORT_VEHICLE") and b or nil end
		return b
	end
	local k = r.k
	if k == "con" then return resolveCon(r) end
	if k == "asset" then
		if os.getenv("MPFEVER_ASSETREF") ~= "0" then return resolveAsset(r) end
		local p0, m0 = assetPlaceOld(r.id)
		if p0 and m0 == r.m and dist(p0, r.p) < 0.5 and not comp(r.id, "CONSTRUCTION") then return r.id end
		local e, d = nearestWith("MODEL_INSTANCE_LIST", function(x)
			if comp(x, "CONSTRUCTION") then return nil end
			local p, m = assetPlaceOld(x)
			if p and m == r.m then return dist(p, r.p) end
			return nil
		end)
		if e and d < 0.5 then return e end
		return nil
	end
	if k == "node" then return resolveNode(r) end
	if k == "edge" then return resolveEdge(r) end
	if k == "depot" then
		if r.con then
			local con = resolveCon(r.con)
			local cc = comp(con, "CONSTRUCTION")
			local e = nil
			if cc and r.i then pcall(function() e = cc.depots[r.i] end) end
			if e then return e end
		end
		return comp(r.id, "VEHICLE_DEPOT") and r.id or nil
	end
	if k == "station" then
		if r.con then
			local con = resolveCon(r.con)
			local cc = comp(con, "CONSTRUCTION")
			local e = nil
			if cc and r.i then pcall(function() e = cc.stations[r.i] end) end
			return e
		end
		if r.edge then
			local edge = resolveEdge(r.edge)
			local be = comp(edge, "BASE_EDGE")
			local e = nil
			if be then
				pcall(function()
					for i = 1, #be.objects do
						if r.side == nil or be.objects[i][2] == r.side then e = e or be.objects[i][1] end
					end
				end)
			end
			return e
		end
		return comp(r.id, "STATION") and r.id or nil
	end
	if k == "sg" then
		if r.st then
			local st = resolve(r.st, bind)
			if st then
				local sg = nil
				pcall(function() sg = api.engine.system.stationGroupSystem.getStationGroup(st) end)
				if type(sg) == "number" and sg >= 0 then return sg end
			end
		end
		return comp(r.id, "STATION_GROUP") and r.id or nil
	end
	if k == "player" then
		-- companies mode: the company's player entity in THIS game; otherwise this game's player
		if r.co and R.coEntity then
			local e = R.coEntity(r.co)
			if e then return e end
		end
		return api.engine.util.getPlayer()
	end
	-- a vehicle or a line: the id must still be one (a skipped purchase left the key unbound, and the same id was
	-- something else here: the engine then crashed on the vehicle command, issue #12)
	if k == "veh" then return comp(r.id, "TRANSPORT_VEHICLE") and r.id or nil end
	if k == "line" then return comp(r.id, "LINE") and r.id or nil end
	-- plain id (things from the save keep their id everywhere)
	local ok, exists = pcall(function() return api.engine.entityExists(r.id) end)
	if ok and exists then return r.id end
	return nil
end
R.resolve = resolve

-- A station group known by what it is, the same in every game (its entity id may differ): the construction of its first station
-- (file, position, index) or, for a stop by the road, the ends of its segment and its side.
function R.sgKey(sg)
	local d = describe("sg", sg)
	local s = d and d.st
	local function r(v) return string.format("%.0f", v or 0) end
	if s and s.con and s.con.p then
		return "c:" .. tostring(s.con.f) .. "@" .. r(s.con.p.x) .. "," .. r(s.con.p.y) .. "#" .. tostring(s.i)
	end
	if s and s.edge and s.edge.p0 and s.edge.p1 then
		local a, b = r(s.edge.p0.x) .. "," .. r(s.edge.p0.y), r(s.edge.p1.x) .. "," .. r(s.edge.p1.y)
		local side = s.side
		-- (the side is relative to the segment's direction, which may differ between games)
		if a > b then a, b = b, a; if type(side) == "number" then side = 1 - side end end
		return "e:" .. a .. "-" .. b .. ":" .. tostring(side)
	end
	return "id:" .. tostring(sg)
end

-- The player entity owning an entity: its own owner, else the owner of its station group's first station, else of its construction
-- The player's constructions in a removal (translated args): owned by a company. Town buildings belong to nobody, and
-- every game's own removal proposal finds them.
function R.removedConstructions(margs)
	local out = {}
	for _, e in ipairs((margs[1] or {}).toRemove or {}) do
		if type(e) == "number" and e >= 0 and comp(e, "CONSTRUCTION") and R.ownerOf(e) then out[#out + 1] = e end
	end
	return out
end

function R.ownerOf(e)
	if type(e) ~= "number" or e < 0 then return nil end
	local function po(x)
		local c = comp(x, "PLAYER_OWNED")
		return (c and type(c.player) == "number" and c.player >= 0) and c.player or nil
	end
	local p = po(e)
	if p then return p end
	local sg = comp(e, "STATION_GROUP")
	if sg then
		local first = nil
		pcall(function() first = sg.stations[1] end)
		if type(first) == "number" then
			p = po(first)
			if p then return p end
			e = first
		end
	end
	local con = nil
	pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(e) end)
	if type(con) ~= "number" or con < 0 then pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(e) end) end
	if type(con) == "number" and con >= 0 then return po(con) end
	return nil
end

-- the station group of an entity the player clicked (a station group, one of its stations, or the station's construction)
function R.stationGroupOf(e)
	if type(e) ~= "number" or e < 0 then return nil end
	if comp(e, "STATION_GROUP") then return e end
	local st = comp(e, "STATION") and e or nil
	if not st then
		local c = comp(e, "CONSTRUCTION")
		pcall(function() st = c and c.stations[1] or nil end)
	end
	if not st then return nil end
	local sg = nil
	pcall(function() sg = api.engine.system.stationGroupSystem.getStationGroup(st) end)
	return (type(sg) == "number" and sg >= 0) and sg or nil
end

-- ------------------------------------------------------------------ which arguments are entities

-- per command: argument index -> kind
R.ARGS = {
	makeVehicleBuyCmd = { [1] = "player", [2] = "depot" },
	makeVehicleSellCmd = { [1] = "veh" },
	makeVehicleSetLineCmd = { [1] = "veh", [2] = "line" },
	makeVehicleSendToDepotCmd = { [1] = "veh", [2] = "depot" },
	makeVehicleReverseCmd = { [1] = "veh" },
	makeVehicleReplaceCmd = { [1] = "veh" },
	makeVehicleSetStoppedByUserCmd = { [1] = "veh" },
	makeVehicleTryToDepartCmd = { [1] = "veh" },
	makeVehicleSetManualDepartureCmd = { [1] = "veh" },
	makeVehicleSetModifiersCmd = { [1] = "veh" },
	makeLineCreateCmd = { [3] = "player" },
	makeLineUpdateCmd = { [1] = "line" },
	makeLineDestroyCmd = { [1] = "line" },
	makeEntitySetNameCmd = { [1] = "any" },
	makeEntitySetColorCmd = { [1] = "any" },
}

-- replace entity ids by references, in place, in marshalled arguments (originator side)
-- rev: local entity -> creation key (lines and vehicles created by replicated actions)
function R.translateOut(fn, margs, rev)
	rev = rev or {}
	local function ref(kind, e)
		if type(e) ~= "number" or e < 0 then return e end
		-- a company's player entity travels as the company number (entity ids of players can differ between games)
		local co = R.coIdOf and R.coIdOf(e) or nil
		if co then return { __ref = true, k = "player", id = e, co = co } end
		if rev[e] then return { __ref = true, key = rev[e], id = e, k = kind } end
		local d = (kind == "player") and { k = "player", id = e } or describe(kind, e)
		d = d or { k = kind, id = e }
		d.__ref = true
		return d
	end
	for i, kind in pairs(R.ARGS[fn] or {}) do
		local v = margs[i]
		-- (a list of entities, as a sale of several vehicles takes them: each one a reference too, 0.5.14. Before, the list went
		-- with this game's raw ids, which name other vehicles on a game whose ids differ. MPFEVER_REFLISTS=0: as before)
		local list = type(v) == "table" and not v.__ref and not v.__ud and #v > 0 and os.getenv("MPFEVER_REFLISTS") ~= "0"
		if list then
			for k, x in pairs(v) do if type(k) ~= "number" or type(x) ~= "number" then list = false; break end end
		end
		if list then
			for k = 1, #v do v[k] = ref(kind, v[k]) end
		else
			margs[i] = ref(kind, v)
		end
	end
	if fn == "makeLineCreateCmd" or fn == "makeLineUpdateCmd" then
		local line = margs[fn == "makeLineCreateCmd" and 4 or 2]
		if type(line) == "table" then
			for _, stop in ipairs(line.stops or {}) do
				if type(stop) == "table" then
					stop.stationGroup = ref("sg", stop.stationGroup)
					-- the waypoints after the stop (issue #27): their track, as a reference that may be missing on another
					-- game (the waypoint alone is then dropped), with the position of its first end (a track found the other
					-- way round there takes the opposite place along it)
					for _, wp in ipairs(stop.waypoints or {}) do
						local eid = type(wp) == "table" and type(wp.edgePos) == "table" and type(wp.edgePos.edgeId) == "table" and wp.edgePos.edgeId or nil
						local e = eid and eid.entity
						local be = (type(e) == "number" and e >= 0) and comp(e, "BASE_EDGE") or nil
						if be then
							wp.__p0 = nodePos(be.node0)
							local r = ref("edge", e)
							if type(r) == "table" then r.opt = true end
							eid.entity = r
						end
					end
				end
			end
		end
	end
	if fn == "makeWorldBuildProposalCmd" and type(margs[1]) == "table" then
		local p = margs[1]
		for i, e in ipairs(p.toRemove or {}) do p.toRemove[i] = ref("con", e) end
		for _, ce in ipairs(p.toAdd or {}) do
			if type(ce.playerEntity) == "number" then ce.playerEntity = ref("player", ce.playerEntity) end
		end
		for _, eo in ipairs((p.proposal and p.proposal.edgeObjectsToAdd) or {}) do
			if type(eo) == "table" and type(eo.playerEntity) == "number" and eo.playerEntity >= 0 and R.coIdOf and R.coIdOf(eo.playerEntity) then
				eo.playerEntity = ref("player", eo.playerEntity)
			end
		end
		local st = p.proposal
		if type(st) == "table" then
			for _, n in ipairs(st.addedNodes or {}) do
				if type(n) == "table" and type(n.entity) == "number" and n.entity >= 0 then n.entity = ref("node", n.entity) end
			end
			for _, s in ipairs(st.addedSegments or {}) do
				if type(s) == "table" then
					if type(s.playerOwned) == "table" and type(s.playerOwned.player) == "number" and R.coIdOf and R.coIdOf(s.playerOwned.player) then
						s.playerOwned.player = ref("player", s.playerOwned.player)
					end
					if type(s.entity) == "number" and s.entity >= 0 then s.entity = ref("edge", s.entity) end
					if type(s.comp) == "table" then
						if type(s.comp.node0) == "number" and s.comp.node0 >= 0 then s.comp.node0 = ref("node", s.comp.node0) end
						if type(s.comp.node1) == "number" and s.comp.node1 >= 0 then s.comp.node1 = ref("node", s.comp.node1) end
					end
				end
			end
			for _, n in ipairs(st.removedNodes or {}) do
				if type(n) == "table" and type(n.entity) == "number" then n.entity = ref("node", n.entity) end
			end
			for _, s in ipairs(st.removedSegments or {}) do
				if type(s) == "table" then
					if type(s.entity) == "number" then s.entity = ref("edge", s.entity) end
					if type(s.comp) == "table" then
						if type(s.comp.node0) == "number" and s.comp.node0 >= 0 then s.comp.node0 = ref("node", s.comp.node0) end
						if type(s.comp.node1) == "number" and s.comp.node1 >= 0 then s.comp.node1 = ref("node", s.comp.node1) end
					end
				end
			end
			-- node configurations: their node, and the existing segments their lane connections and crosswalks use
			for _, m in ipairs(st.nodeConfigsToAdd or {}) do
				if type(m) == "table" then
					if type(m.entity) == "number" and m.entity >= 0 then m.entity = ref("node", m.entity) end
					local mc = m.comp
					if type(mc) == "table" then
						for _, l in ipairs(mc.laneConnections or {}) do
							if type(l) == "table" then
								if type(l.segment0) == "number" and l.segment0 >= 0 then l.segment0 = ref("edge", l.segment0) end
								if type(l.segment1) == "number" and l.segment1 >= 0 then l.segment1 = ref("edge", l.segment1) end
							end
						end
						for i, x in ipairs(mc.crosswalks or {}) do
							if type(x) == "number" and x >= 0 then mc.crosswalks[i] = ref("edge", x) end
						end
					end
				end
			end
			for i, n in ipairs(st.nodeConfigsToRemove or {}) do
				if type(n) == "number" and n >= 0 then st.nodeConfigsToRemove[i] = ref("node", n) end
			end
			-- existing ids in the new/old maps (keys and values)
			for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
				local mm = st[k]
				if type(mm) == "table" then
					local kind = k:find("Nodes") and "node" or "edge"
					local out = {}
					for key, list in pairs(mm) do
						if type(list) == "table" and type(key) == "number" then
							local l2 = {}
							for i = 1, #list do
								local x = list[i]
								l2[i] = (type(x) == "number" and x >= 0) and ref(kind, x) or x
							end
							out[#out + 1] = { k = (key >= 0) and ref(kind, key) or key, v = l2 }
						end
					end
					st[k] = { __pairs = out }
				end
			end
		end
	end
	return margs
end

-- resolve every reference found in marshalled arguments (every game); returns the list of what is missing
function R.translateIn(margs, bind)
	local missing = {}
	-- (one pass: the street graph is indexed at the first miss, and a reference met again is not looked up again)
	local outer = R.pass
	R.pass = outer or { memo = {} }
	local memo = R.pass.memo
	local function lookup(v)
		if v.k ~= "node" and v.k ~= "edge" then return resolve(v, bind) end
		if v.key and bind and bind[v.key] then return bind[v.key] end
		local p, p0, p1 = v.p or {}, v.p0 or {}, v.p1 or {}
		local mk = v.k .. ":" .. tostring(v.id) .. ":" .. tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z) .. ":"
			.. tostring(p0.x) .. "," .. tostring(p0.y) .. "," .. tostring(p0.z) .. ":" .. tostring(p1.x) .. "," .. tostring(p1.y) .. "," .. tostring(p1.z)
		local hit = memo[mk]
		if hit == nil then
			hit = { e = resolve(v, bind) }
			memo[mk] = hit
		end
		return hit.e
	end
	local function walk(t, depth)
		if depth > 12 then return end
		for k, v in pairs(t) do
			if type(v) == "table" then
				if v.__ref then
					local e = lookup(v)
					if e == nil and v.opt then
						-- (an optional reference: what holds it is dropped alone, see C.rebuild)
						t[k] = -999999999
					elseif e == nil then
						missing[#missing + 1] = tostring(v.k) .. "#" .. tostring(v.id) .. (v.key and ("/" .. v.key) or "")
						t[k] = -999999999
					else
						t[k] = e
					end
				else
					walk(v, depth + 1)
				end
			end
		end
	end
	local okw, errw = pcall(walk, margs, 0)
	R.pass = outer
	if not okw then error(errw, 0) end
	return missing
end

-- order-independent hash of a plain Lua value (much faster than hashing its printed form)
local function quickHash(hashStr, v, d)
	local t = type(v)
	if t == "table" then
		if d > 10 then return 13 end
		local acc = 17 + d
		for k, x in pairs(v) do
			acc = (acc + (quickHash(hashStr, k, d + 1) * 1000003 + quickHash(hashStr, x, d + 1)) % 4294967296) % 4294967296
		end
		return acc
	elseif t == "number" then
		if v == math.floor(v) and v > -2147483648 and v < 2147483648 then return (v * 2654435761) % 4294967296 end
		return hashStr(5, string.format("%.6g", v))
	elseif t == "string" then
		return hashStr(3, v)
	elseif t == "boolean" then
		return v and 1 or 2
	end
	return 0
end

-- the name of an entity, and what the player sets on a line (its text in the checks and in the state dumps)
local function nameOf(e)
	local n = comp(e, "NAME")
	return n and n.name and tostring(n.name) or ""
end
R.nameOf = nameOf

-- Names in each game's language (issue #97): the game names a new station, line or vehicle by itself, in its own language
-- ("Ingolstadt Fishing Grounds West" on an English game, "Ingolstadt Fischzucht" on a German one), so the games of players of
-- two languages differed in the checks ("names", "lines") and reloaded. The host's game sends the names that are new or changed
-- since its last check (the names part fills R.nameCollect), and the other games take them: a name changes nothing in the
-- simulation. Gives nil when nothing changed, and for a first call with no baseline (R.nameSeed sets one at every load).
-- (MPFEVER_NAMESYNC=0: off)
R.NAMESYNC_MAX = 400
function R.nameChanges(collected)
	local prev = R.namesPrev
	R.namesPrev = collected
	if not prev then return nil end
	local list = {}
	for e, v in pairs(collected) do
		local p = prev[e]
		if not p or p.k ~= v.k or p.nm ~= v.nm then list[#list + 1] = { e = e, k = v.k, nm = v.nm } end
	end
	if #list == 0 then return nil end
	table.sort(list, function(a, b) return a.e < b.e end)
	-- (the rest goes with the next check: it counts as not seen yet)
	for i = #list, R.NAMESYNC_MAX + 1, -1 do
		local e = list[i].e
		collected[e] = prev[e]
		list[i] = nil
	end
	return list
end

-- the names of the savegame as every game loaded it, the baseline of the next R.nameChanges: a station, line or vehicle named
-- between the load and the first check went unsent before, the first check only set the baseline
function R.nameSeed()
	local col = {}
	for _, cname in ipairs({ "STATION_GROUP", "LINE", "TRANSPORT_VEHICLE" }) do
		for _, e in ipairs(R.entitiesWith(cname)) do col[e] = { k = cname, nm = nameOf(e) } end
	end
	R.namesPrev = col
end

function R.lineText(e)
	local c = comp(e, "LINE")
	if not c then return nil end
	local t = { nameOf(e) }
	for i = 1, #c.stops do
		local st = c.stops[i]
		-- (the waypoints after the stop: how many, and where along their track; the tracks' ids differ between games)
		local wps = ""
		pcall(function()
			local w = {}
			for j = 1, #st.waypoints do
				local wp = st.waypoints[j]
				local prm = 0
				pcall(function() prm = wp.edgePos.param end)
				w[#w + 1] = string.format("%.2f", prm)
			end
			wps = table.concat(w, ";")
		end)
		t[#t + 1] = nameOf(st.stationGroup) .. "," .. tostring(st.terminal) .. "," .. tostring(st.loadMode) .. ","
			.. string.format("%.0f/%.0f/%.0f", st.minWaitingTime or 0, st.maxWaitingTime or 0, st.maxAdditionalWaitingTime or 0)
			.. "," .. wps
	end
	return table.concat(t, "|")
end

-- id-independent world fingerprint parts
function R.contentHash(hashStr, dumpFn)
	local parts = {}
	local off = os.getenv("MPFEVER_HASHOFF") or ""
	R.partCost = {}
	local function part(name, fn)
		if off:find(name, 1, true) then return end
		-- (R.hashSkip: the parts left out of this checkpoint, see the rotation in simHash)
		if R.hashSkip and R.hashSkip[name] then return end
		local t0 = os.clock()
		local ok, v = pcall(fn)
		R.partCost[name] = os.clock() - t0
		parts[name] = ok and v or ("ERR " .. tostring(v):sub(1, 100))
	end
	local function count(cname, contentFn)
		local n, acc = 0, 0
		for _, e in ipairs(R.entitiesWith(cname)) do
			-- (contentFn answers false for what is not counted at all)
			local s = contentFn and contentFn(e) or nil
			if s ~= false then
				n = n + 1
				if s then acc = (acc + hashStr(0, s)) % 4294967296 end
			end
		end
		if R.loopErrors[cname] then return "cannot list " .. cname end
		return n .. "/" .. acc
	end
	local function r1(v) return v and string.format("%.0f", v) or "?" end
	-- (trees, plants and rocks of the brush are left out: see isAssetFile)
	part("constructions", function() return count("CONSTRUCTION", function(e)
		local c = comp(e, "CONSTRUCTION")
		if c and isAssetFile(c.fileName) then return false end
		local p = c and matPos(c.transf)
		return c and (tostring(c.fileName) .. "@" .. r1(p and p.x) .. "," .. r1(p and p.y)) or nil
	end) end)
	part("edges", function() return count("BASE_EDGE", function(e)
		local c = comp(e, "BASE_EDGE")
		if not c then return nil end
		local a, b = nodePos(c.node0), nodePos(c.node1)
		if not a or not b then return nil end
		local s1 = r1(a.x) .. "," .. r1(a.y)
		local s2 = r1(b.x) .. "," .. r1(b.y)
		local swapped = false
		if s1 > s2 then s1, s2 = s2, s1; swapped = true end
		-- what the road carries beyond its template: decorations (side and model) and which vehicles each lane takes (tram)
		local deco, lanesig = "", ""
		-- (a component's members are copies: each list is read once)
		local decos, nd = nil, 0
		pcall(function() decos = c.edgeDecorations; nd = #decos end)
		if nd > 0 then
			pcall(function()
				local t = {}
				for k = 1, nd do
					local dk = decos[k]
					-- (the side is relative to the segment's direction, which may differ between games: the canonical one is used)
					local left = dk[2] and true or false
					if swapped then left = not left end
					t[#t + 1] = tostring(dk[1]) .. (left and "l" or "r")
				end
				table.sort(t)
				deco = table.concat(t, ",")
			end)
		end
		pcall(function()
			local t = {}
			local lanes = c.laneConfigs
			for k = 1, #lanes do
				local tm = lanes[k].transportModes
				local m = 0
				for j = 0, 15 do if tm[j] then m = m + 2 ^ j end end
				t[#t + 1] = m
			end
			table.sort(t)
			lanesig = table.concat(t, ",")
		end)
		local okd = true
		return s1 .. "-" .. s2 .. tostring(c.roadTemplate) .. "/" .. tostring(okd and nd or 0) .. "/" .. tostring(c.roadStyle)
			.. "/" .. tostring(c.roadType) .. "/" .. tostring(c.type) .. "/" .. tostring(c.typeIndex) .. "/" .. deco .. "/" .. lanesig .. "/d" .. tostring(c.distance)
	end) end)
	-- the segments' ages (TICK_EPOCH: the step each was added at, which the towns' parcels compare; the street tool used to give
	-- its own on the builder's game only), as a set
	part("ages", function()
		local ct = CT("TICK_EPOCH")
		if not ct then return "none" end
		-- (only where the native module stamps them, R.tickEpochsOn: without it the street tool's ages differ by design)
		if R.tickEpochsOn and not R.tickEpochsOn() then return "off" end
		local get = api.engine.getComponent
		return count("BASE_EDGE", function(e)
			local ok, t = pcall(get, e, ct)
			return ok and t and (tostring(t.time) .. "/" .. tostring(t.commandIndex) .. "/" .. tostring(t.subIndex)) or "-"
		end)
	end)
	part("vehicles", function() return count("TRANSPORT_VEHICLE", function(e)
		local c = comp(e, "MOVE_PATH")
		return c and dumpFn(c.dyn) or "depot"
	end) end)
	part("townBuildings", function() return count("TOWN_BUILDING") end)
	part("persons", function() return count("SIM_PERSON") end)
	part("stations", function() return count("STATION") end)
	-- the lines with what the player sets on them: name, and for every stop its station's name, terminal, loading mode
	-- and waiting times (the ids of the stations differ between games, their names do not)
	part("lines", function() return count("LINE", R.lineText) end)
	-- the names of stations, lines and vehicles
	part("names", function()
		local n, acc = 0, 0
		-- (R.nameCollect, on the host's game: every name read here, for the games of the other languages, see R.nameChanges)
		local col = R.nameCollect
		for _, cname in ipairs({ "STATION_GROUP", "LINE", "TRANSPORT_VEHICLE" }) do
			for _, e in ipairs(R.entitiesWith(cname)) do
				n = n + 1
				local nm = nameOf(e)
				acc = (acc + hashStr(0, cname .. ":" .. nm)) % 4294967296
				if col then col[e] = { k = cname, nm = nm } end
			end
		end
		return n .. "/" .. acc
	end)
	-- what the player sets on a vehicle: its line, stopped by the player, to be sold
	part("vehicleState", function() return count("TRANSPORT_VEHICLE", function(e)
		local c = comp(e, "TRANSPORT_VEHICLE")
		if not c then return nil end
		return (c.line and c.line >= 0 and nameOf(c.line) or "-") .. "/" .. tostring(c.userStopped) .. "/" .. tostring(c.sellOnArrival)
	end) end)
	-- lane connections, crosswalks and traffic lights of the road nodes
	part("nodeConfigs", function()
		local n, acc = 0, 0
		local dump = os.getenv("MPFEVER_NCDUMP") and {} or nil     -- diagnostic: the line of every node, to diff two games
		for _, node in ipairs(R.allNodes()) do
			local nc = comp(node, "BASE_NODE_CONFIG")
			local p = nc and nodePos(node)
			if nc and p then
				n = n + 1
				local tl = nil
				pcall(function() tl = nc.trafficLightConfig.trafficLightType end)
				local line = r1(p.x) .. "," .. r1(p.y) .. "/" .. #nc.laneConnections .. "/" .. #nc.crosswalks .. "/"
					.. tostring(nc.trafficLightPreference) .. "/" .. tostring(tl) .. "/" .. tostring(nc.doubleSlipSwitch)
				if dump then dump[#dump + 1] = line .. " #" .. tostring(node) .. " " .. string.format("%.2f,%.2f", p.x, p.y) end
				acc = (acc + hashStr(0, line)) % 4294967296
			end
		end
		R.ncDump = dump
		return n .. "/" .. acc
	end)
	-- (the height of the ground is not sampled: api.engine.terrain.getHeightAt called from the game script stalls the game)
	-- the parameters of every construction that is not a town building (the modules of a modular station...)
	part("conParams", function() return count("CONSTRUCTION", function(e)
		if comp(e, "TOWN_BUILDING") then return nil end
		local c = comp(e, "CONSTRUCTION")
		if not c then return nil end
		if isAssetFile(c.fileName) then return false end
		local p = matPos(c.transf)
		local d = ""
		pcall(function()
			local params = c.params
			if type(params) == "table" then d = tostring(quickHash(hashStr, params, 0)) else d = dumpFn(params) end
		end)
		return tostring(c.fileName) .. "@" .. r1(p and p.x) .. "," .. r1(p and p.y) .. "#" .. tostring(d)
	end) end)
	part("edgeObjects", function()
		local n, acc = 0, 0
		for eo, edge in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap() or {}) do
			local c = comp(eo, "EDGE_OBJECT")
			local be = comp(edge, "BASE_EDGE")
			local a = be and nodePos(be.node0)
			n = n + 1
			if c and a then acc = (acc + hashStr(0, tostring(c.edgeObjectConstruction) .. r1(a.x) .. r1(a.y))) % 4294967296 end
		end
		return n .. "/" .. acc
	end)
	return parts
end

return R
