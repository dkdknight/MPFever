-- MPFever: the models of mpfever_asset.con (params.mpfModels = { { id = model file, transf = 16 numbers, relative to the
-- construction }, ... }).
function data()
return {
	updateFn = function(captureParams, params)
		local result = { models = { } }
		for _, m in ipairs((params and params.mpfModels) or { }) do
			if type(m) == "table" and type(m.id) == "string" and type(m.transf) == "table" and #m.transf == 16 then
				-- (a model of the game is named with "::/", else it is looked for in this mod)
				local id = m.id
				if id:sub(1, 1) == "/" then id = "::" .. id end
				result.models[#result.models + 1] = { id = id, transf = m.transf }
			end
		end
		if #result.models == 0 then
			result.models[1] = { id = "::/assets/markers/marker_exclamation.mdl", transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } }
		end
		result.terrainAlignmentLists = { { type = "EQUAL", faces = { } } }
		return { subconstructions = { result } }
	end,
}
end
