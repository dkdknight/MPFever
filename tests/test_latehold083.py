"""Offline test: builds that came late (0.8.3, #237 MPFEVER_DUEHOLD, #239 MPFEVER_LATETERRAIN).

#237 (2026-11-11 20:07, Wretched, dujuk and chris): Wretched's warehouse edit pc:19 (t=28092200) was due on chris's game while the
replay before it was still in the engine's hands. It waited in the queue but nothing held the game at its time any more (the hold
only counted actions still to come): chris's game went one step on, released its own build there, and the edit then came "1 step
late after another build": the host's game was reloaded. A due action not applied yet now holds the game where it is.
#239 (20:34, yoyo, YkeWoudstra and Bence): Bence's terrain edit (shipped once made, so always some steps late) came 9 steps late on
YkeWoudstra's game, which had built in between: reloaded. A terrain edit makes no entity: it is built late, as before 0.5.14.
The code is taken from the real bridge and run through lupa (Lua 5.2).
Run: python tests/test_latehold083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
late = re.search(r"^function G\.lateSkip\(a, now\)\n.*?^end\n", src, re.S | re.M)
hold = re.search(r'\n(\tif os\.getenv\("MPFEVER_DUEHOLD"\) ~= "0" then\n.*?\n\tend\n)', src, re.S)
if not late or not hold:
    print("FAIL: G.lateSkip or the due hold not found in the bridge")
    sys.exit(1)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENVV = {}
os.getenv = function(k) return ENVV[k] end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
FAILED = {}
replayFailed = function(a, why) FAILED[#FAILED + 1] = why end
C = { ROLE = "client", Tf = function(fr, en, ...) return en end }
G = { natShipIds = {}, nativeQueue = {}, frames = 1000, coSay = function() end }
""" + late.group(0) + """
function HOLD(now, m)
""" + hold.group(1) + """
  return m
end
""")
run = L.eval("function(code) return assert(load(code))() end")

# #239: Bence's terrain edit 9 steps late, this game built in between
run("G.builtAt = 14492200")
check("#239: a terrain edit 9 steps late after a build here: built late, no reload",
      run("return G.lateSkip({ uid = 'Bence#16:51', fn = 'terrainEdit', at = 14491800 }, 14493600)") is False and run("return #FAILED") == 0)
check("a street build late after a build here: still left out and reloaded (0.5.14)",
      run("return G.lateSkip({ uid = 'x:1', fn = 'makeWorldBuildProposalCmd', native = true, at = 14491800 }, 14493600)") is True and run("return FAILED[1]") == "late build after another build")
run("FAILED = {} ENVV.MPFEVER_LATETERRAIN = '0'")
check("MPFEVER_LATETERRAIN=0: the terrain edit left out and reloaded, as 0.5.14 to 0.8.2",
      run("return G.lateSkip({ uid = 'Bence#16:51', fn = 'terrainEdit', at = 14491800 }, 14493600)") is True)
run("ENVV.MPFEVER_LATETERRAIN = nil")

# #237: the warehouse edit due at 28092200, kept in the queue (the replay before it under way)
run("G.nativeQueue = { { uid = 'pc:19', fn = 'makeWorldBuildProposalCmd', at = 28092200 } }")
check("the frame it becomes due: as before (it is sent later in that frame)", run("return HOLD(28092200, 28092400)") == 28092400)
run("G.frames = G.frames + 1")
check("#237: still waiting in the queue a frame later (the replay before it under way): holds the game where it is",
      run("return HOLD(28092200, 28092400)") == 28092200)
check("  also one step past it (and said once)", run("return HOLD(28092400, 28092600)") == 28092400
      and sum(1 for i in range(1, 5) if "the game holds" in str(run(f"return LOG[{i}]"))) == 1)
run("G.frames = G.frames + 600")
check("  not longer than 600 frames (10 s)", run("return HOLD(28092400, 28092600)") == 28092600)
run("G.frames = 1000 G.nativeQueue = { { uid = 'p:1', fn = 'makeWorldBuildProposalCmd', at = 28092200, paused = true, dueF = 999 } }")
check("a paused action: its turns, no hold here", run("return HOLD(28092200, 28092400)") == 28092400)
run("G.nativeQueue = { { uid = 'j:1', fn = 'mpfCoJoin', at = 28092200, dueF = 999 } }")
check("a company join: its own hold, no hold here", run("return HOLD(28092200, 28092400)") == 28092400)
run("G.nativeQueue = { { uid = 'f:1', fn = 'makeWorldBuildProposalCmd', at = 28092600 } }")
check("an action still to come: as before (no hold here)", run("return HOLD(28092200, 28092400)") == 28092400)
run("G.nativeQueue = { { uid = 'pc:19', fn = 'makeWorldBuildProposalCmd', at = 28092200, dueF = 999 } } ENVV.MPFEVER_DUEHOLD = '0'")
check("MPFEVER_DUEHOLD=0: as before", run("return HOLD(28092200, 28092400)") == 28092400)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
