"""Offline test (0.8.17, #398): a build sent by the interface's Lua that cuts segments with stops or signals is replayed as a tool's
build on every game, its sender's too (G.uiObjBuild, H.act and the sender's act_req in mpfever_bridge.script.lua, switch
MPFEVER_UIOBJBUILD).

Andy's 16 builds of 2026-11-16 20:07-20:08 (12 track pieces each, with their signals) came from the interface's Lua, not from a
tool the native module holds; shipped as ordinary actions, every game rebuilt them by the script forms, which refuse a build that
cuts segments carrying stops or signals ("native form only"): 48 refusals, the build lost everywhere, Andy's game too, no word.
  - G.uiObjBuild (run through lupa): such a build (a native proposal whose removed segments carry objects not removed by it) is
    taken, whether its objects travel by reference (the receivers) or by id (the sender); MPFEVER_UIOBJBUILD=0: not taken (the
    bug, the script forms);
  - not taken: a tool's native build, a build whose removed segments carry nothing, one that removes their objects, a street
    proposal of a script (handled by the script forms and C.strandedObjects);
  - the sender and the receivers route it the way of the edits from a window (native, its turn in a pause).
Needs lupa. Run: python tests/test_uiobjbuild0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r"^G\.uiObjBuild = function\(p\)\n.*?^end\n", src, re.S | re.M)
check("G.uiObjBuild found", m is not None)
if not m:
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = {}\n" + m.group(0))
run = L.eval("function(code) return assert(load(code))() end")

ANDY = """{ fn = 'makeWorldBuildProposalCmd', uid = 'Andy#4:44', args = { n = 4, [1] = { toAdd = {}, toRemove = {}, proposal = {
  addedSegments = { { comp = { type = 1, objects = {} } } }, edgeObjectsToRemove = {},
  removedSegments = { { entity = { __ref = true, k = 'edge', id = 128204 }, comp = { type = 1, objects = { { { __ref = true, k = 'eo', id = 9001 }, 2 } } } } } } } } }"""
check("Andy's build (removed track pieces with a signal, by reference): replayed as a tool's build", run("return G.uiObjBuild(%s)" % ANDY) is True)
SENDER = ANDY.replace("{ { { __ref = true, k = 'eo', id = 9001 }, 2 } }", "{ { 9001, 2 } }")
check("  on the sender (the signal by its id): the same", run("return G.uiObjBuild(%s)" % SENDER) is True)
run("ENV.MPFEVER_UIOBJBUILD = '0'")
check("MPFEVER_UIOBJBUILD=0: not taken (the script forms refuse it everywhere: the bug)", run("return G.uiObjBuild(%s)" % ANDY) is False)
run("ENV = {}")
check("a tool's native build: not concerned (it is native already)", run("local p = %s; p.native = true; return G.uiObjBuild(p)" % ANDY) is False)
check("removed pieces carrying nothing: not taken (the script forms build it as before)",
      run("return G.uiObjBuild(%s)" % ANDY.replace("{ { { __ref = true, k = 'eo', id = 9001 }, 2 } }", "{}")) is False)
check("a build that removes the signal too: not taken",
      run("return G.uiObjBuild(%s)" % ANDY.replace("edgeObjectsToRemove = {}", "edgeObjectsToRemove = { { __ref = true, k = 'eo', id = 9001 } }")) is False)
check("a script's street proposal (edgesToRemove by id): not taken",
      run("return G.uiObjBuild({ fn = 'makeWorldBuildProposalCmd', args = { n = 1, [1] = { streetProposal = { edgesToRemove = { 5 } } } } })") is False)
check("another command: not taken", run("return G.uiObjBuild({ fn = 'makeVehicleSellCmd', args = { n = 1, [1] = { 5 } } })") is False)

act = src[src.index("H.act = function(from, p)"):]
act = act[:act.index("\nend\n")]
check("the receivers route it as an edit from a window", "elseif G.uiObjBuild and G.uiObjBuild(p) then" in act and act.count("p.native, p.uiEdit = true, true") == 2)
req = src[src.index('elseif p and kind == "act_req" then'):]
req = req[:req.index('elseif p and kind == "speed_req"')]
check("the sender replays it too (its own queue of native replays)", "elseif G.uiObjBuild and G.uiObjBuild(a) then" in req and "edit = true" in req)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
