"""Offline test of two small lag changes in a construction's replay (0.7.7, lag research F4/F5, replayNativeConstruction and
SIM.idResolve in mod/mpfever_1/content/mpfever_bridge.script.lua).

F5: before a station edit's replay sends its conversion (a dry run the engine refuses on purpose), it counted every segment of
the map (R.allEdges walks and sorts the whole street map) and every edge object, for the "edges here N, originator N" line
written once the build is applied: 20 to 60 ms on a big map, while the game stands at the build's step. The counts are now
read right after the conversion is handed to the engine, in the same frame (nothing changes before the build: the conversion
is refused). MPFEVER_COUNTSAFTER=0: before, as in 0.7.6.
F4: the "build ids" lookup (R.idsAt) rebuilds a grid of the whole street map in the simulation thread for every build; when
it takes more than 20 ms, a line of its own says how long (the "build ids" line itself stays the same on every game: the
games' logs are compared line by line).
Run: python tests/test_countsafter077.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


rc = src[src.index("local function replayNativeConstruction(a)"):]
rc = rc[:rc.index("\n\treturn true\nend\n") + 18]
check("local edgesBefore, objsBefore = nil, 0" in rc and "local function countNow()" in rc, "the counts made by one function, not at once")
check('local countsAfter = os.getenv("MPFEVER_COUNTSAFTER") ~= "0"' in rc and "if not countsAfter then countNow() end" in rc,
      "MPFEVER_COUNTSAFTER=0: counted before the conversion is sent, as before")
i_send = rc.index("G.gateDryNext = true; replaySend(dry, function(res, success)")
i_after = rc.index("\tif countsAfter and edgesBefore == nil then countNow() end\n\treturn true\nend")
check(rc.index("if not countsAfter then countNow() end") < i_send < i_after, "  else counted right after the conversion is handed to the engine, in the same frame")
check(rc.index("if edgesBefore == nil then countNow() end", i_send) < rc.index("if success then", i_send), "  (an answer before that: counted first)")
check("local got = #R.allEdges() - edgesBefore" in rc and "(objs - objsBefore)" in rc, "the line after the build still compares with them")
ir = src[src.index("SIM.idResolve = function(state, force)"):][:2600]
check("local idc0 = os.clock()" in ir and "local idMs = (os.clock() - idc0) * 1000" in ir and "if idMs > 20 then" in ir,
      "F4: the build ids lookup timed, said when over 20 ms")
check('log("build ids t=" .. ck.at .. ": segments " .. table.concat(si, ",") .. " nodes " .. table.concat(ni, ",") .. " (node configurations " .. cfg .. ")" .. nms)' in ir,
      "  the build ids line itself unchanged (compared between the games' logs)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
