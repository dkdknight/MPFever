-- Loaded by the native module (winhttp.dll) in front of the game's gui/main/pause_menu.tl, in a game's UI state, when
-- the game was started by MPFever. The pause menu's main page is a local recipe of that file: the id the engine gives
-- it is caught here while it registers (as mpfever_menu.lua does for the main menu's page), so that
-- mpfever_ui.script.lua can draw MPFever's card beside it (no button in the game's HUD).
-- No backslash characters on purpose.

local ok, err = pcall(function()
	local detail = api.gui.react.detail
	local orig = detail.makeRecipeId
	if package.loaded["mpfever_pause_wrapped"] then return end
	package.loaded["mpfever_pause_wrapped"] = true
	detail.makeRecipeId = function(name, ...)
		local id = orig(name, ...)
		if name == "PauseMainPage" then package.loaded["mpfever_pause_id"] = id end
		-- (0.9.2, build 40444: the page is drawn in a Lua state of its own; this file is also loaded in front of the UI
		-- state's gui/main/pause_menu_tool.tl, whose recipe PauseWrap is the menu's frame there)
		if name == "PauseWrap" then package.loaded["mpfever_pausewrap_id"] = id end
		return id
	end
end)
if not ok then pcall(print, "[MPFEVER-PAUSE] " .. tostring(err)) end
return {}
