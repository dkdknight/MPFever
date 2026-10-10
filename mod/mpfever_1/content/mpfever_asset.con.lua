-- MPFever: trees, plants and rocks another player placed with the brush (their models given as parameters). Never in the build
-- menus: only the multiplayer mod builds it, on the games of the other players.
function data()
return {
	description = {
		name = "MPFever assets",
		description = "Trees, plants and rocks placed by another player",
		icon = "",
	},
	params = { },
	order = 100000,
	skipCollision = true,
	updateScript = {
		fileName = "mpfever_asset.script@updateFn",
		params = { },
	},
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
}
end
