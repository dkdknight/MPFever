-- MPFever 0.8.8: the computer companies' game options. They are the work of the host's game (mpfever_ai.lua, driven by the
-- bridge's G.aiStep): this module only declares them, so that the lobby's "Game settings", the dedicated server's settings and
-- the window's Game tab show them like the others (see docs/FEATURES-0.6.md). No simulation code: no event, no state in the
-- game; what a computer company builds goes to every game as its other actions do. Off by default; with it off the computer
-- companies play exactly as in 0.8.7.
--   aitrains   the computer companies may build passenger railways between the towns of their area (a station in each town,
--              the track, a depot, trains), besides their buses, trucks and freight railways. The host's game plans the track
--              in slices of a few milliseconds (see mpfever_ai.lua, RL.inTime). MPFEVER_AIPAXRAIL=1 / hard / 0 (tests) still
--              decides over it.
local M = {}
M.ID = "ai"
M.OPTIONS = {
	{ id = "aitrains",
		title = { "Trains de voyageurs des entreprises ordinateur", "Computer companies' passenger trains" },
		desc = { "Les entreprises dirigées par l'ordinateur peuvent relier par le rail les villes de leur zone (une gare dans chaque ville, la voie, un dépôt, des trains), en plus de leurs bus, de leurs camions et de leurs trains de marchandises. Expérimental : une gare et sa voie coûtent cher, elles n'en construisent que lorsqu'elles en ont les moyens.",
			"The companies run by the computer may link the towns of their area by rail (a station in each town, the track, a depot, trains), besides their buses, trucks and freight trains. Experimental: a station and its track are dear, they only build one when they can afford it." },
		modes = "separate" },
}

return M
