-- MPFever: the mod's preRunScript (mod.json), called by the game before it loads the game's and the mods' resources, with the base
-- configuration. Nothing changes unless a research switch asks for it.
--
-- (0.8.6, #150 research) MPFEVER_NOANIMALS=1: no animal is spawned (baseConfig.animal.populationDensityMultiplier = 0). Two games
-- of a session at x4 on Test Gameplay, one company per player, parted at the same step, an animal's octree node made on one game
-- only (AnimalMoveSystem, step 135926). With no animals, does the drift go? Off by default (a research switch, every game alike).
--
-- A Lua ".script" resource gives the game its functions through a global data() (base/init.lua: "function data() not defined"
-- otherwise, and the game refuses to start: "Could not init game"); "@preRunFn" in mod.json names the field of its table.
local function preRunFn(captureParams, configDict, allModParams, baseConfig)
	pcall(function()
		if type(os) == "table" and os.getenv("MPFEVER_NOANIMALS") == "1" and baseConfig and baseConfig.animal then
			baseConfig.animal.populationDensityMultiplier = 0
			print("[MPFEVER] animals off (MPFEVER_NOANIMALS=1): population density x 0")
		end
	end)
end

function data()
	return { preRunFn = preRunFn }
end
