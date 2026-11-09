"""Offline test: a script's street build whose node configuration names a piece already taken away is refused on every game
(0.7.15, issue #174; C.staleNodeConfig and C.noteGone in mpfever_common.lua, executeActionOnce in mpfever_bridge.script.lua).

Issue #174 (hluki, host, 0.7.13, 2026-11-09 12:09, the host's game crashed): Town Transit Planner sent 12 street pieces at once
(its stops put on town streets: each piece replaced by a copy with its stops), each with the node configurations the engine had
made for it (replaceSegment) from the world before any of them was built. Four were replayed at game time 25867000: hluki:253
replaced segment 309652 at node 249149, and hluki:254's configuration of node 249149 still named 309652; the engine stopped when
it applied hluki:254 (its "build ids" line never came). Alone, the game refuses such a build ("Unknown exception": the mod's
own comments), and the mod goes on.
  - C.staleNodeConfig, run here through lupa on the two real actions (tests/data/issue174_burst.lua): hluki:253 is fresh;
    once its pieces are noted (C.noteGone), hluki:254 names 309652 "taken away by an earlier build at this time"; without the
    note, with the world after it (309652 no longer at node 249149), "no longer at that node here";
  - not looked at: the segments the build removes itself, its new ones (negative), a native proposal (m.proposal);
  - a piece to remove that an earlier build took away, a configuration of a node taken away: refused too;
  - the bridge refuses before the forms are built (every game, MPFEVER_STALECFG=0: as before), notes what each build sent takes
    away, keeps the list for one game time only; a native build is only said in mod.log;
  - the autotest scenario stalecfg sends two such pieces of one junction in the same frame.
Needs lupa (pip install lupa). Run: python tests/test_stalecfg0715.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fns = {}
for name in ("staleNodeConfig", "noteGone"):
    m = re.search(r"^function C\." + name + r"\(.*?^end\n", common, re.S | re.M)
    check(m is not None, "C." + name + " found")
    if not m:
        sys.exit(1)
    fns[name] = m.group(0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("C = {}\napi = nil\n" + fns["staleNodeConfig"] + fns["noteGone"])
data = open(os.path.join(HERE, "data", "issue174_burst.lua"), encoding="utf-8").read()
L.execute("D = (function() " + data + " end)()")
L.execute('''
A253, A254 = D[253].args[1], D[254].args[1]
-- the world before the burst: every piece at its nodes
function before() return true end
-- after hluki:253: 309652 gone (at no node)
function after(seg, node) return seg ~= 309652 end
function why(s) if not s then return "nil" end return tostring(s.node) .. "|" .. tostring(s.seg) .. "|" .. s.why end
''')

print("issue #174: the two real actions")
check(L.eval("A253.streetProposal.edgesToRemove[1]") == 309652, "(data) hluki:253 replaces 309652")
check(L.eval("why(C.staleNodeConfig(A253, {}, before))") == "nil", "hluki:253 alone, on the world before: fresh")
check(L.eval("why(C.staleNodeConfig(A254, {}, before))") == "nil", "hluki:254 on the world before (as made): fresh")
L.execute("G = C.noteGone(A253, {})")
check(L.eval("G[309652]") is True and L.eval("(function() local n = 0 for _ in pairs(G) do n = n + 1 end return n end)()") == 1,
      "C.noteGone: hluki:253 takes away 309652 (its only piece, no node)")
check(L.eval("why(C.staleNodeConfig(A254, G, before))") == "249149|309652|taken away by an earlier build at this time",
      "hluki:254 after it at the same time: its configuration of node 249149 names 309652, taken away by an earlier build")
check(L.eval("why(C.staleNodeConfig(A254, {}, after))") == "249149|309652|no longer at that node here",
      "hluki:254 at a later time (309652 no longer at node 249149): refused too")

print("what is not looked at")
L.execute('''
function cfg(node, a, b) return { entity = node, comp = { laneConnections = { { segment0 = a, lane0 = 0, segment1 = b, lane1 = 1 } } } } end
OWN = { streetProposal = { edgesToRemove = { 500 }, nodeConfigsToAdd = { cfg(10, 500, -1) } } }
NEW = { streetProposal = { nodeConfigsToAdd = { cfg(10, -1, -2) } } }
NAT = { proposal = { removedSegments = { 600 }, nodeConfigsToAdd = { cfg(10, 600, 601) } } }
''')
check(L.eval("why(C.staleNodeConfig(OWN, { [500] = true }, function() return false end))") == "nil|500|the piece it replaces was taken away by an earlier build at this time",
      "a piece to remove already taken away: refused (its own segment never looked at in the configurations)")
check(L.eval("why(C.staleNodeConfig(OWN, {}, function() return false end))") == "nil", "the segment the build removes itself: not looked at")
check(L.eval("why(C.staleNodeConfig(NEW, { [1] = true, [2] = true }, function() return false end))") == "nil", "its new segments (negative): not looked at")
check(L.eval("why(C.staleNodeConfig(NAT, { [601] = true }, function() return false end))") == "nil", "a native proposal: not refused here")
L.execute("GN = C.noteGone(NAT, {})")
check(L.eval("GN[600]") is True, "C.noteGone: a native build's pieces are noted too (for the script builds after it)")
check(L.eval("why(C.staleNodeConfig({ streetProposal = { nodeConfigsToAdd = { cfg(10, 700, 701) } } }, { [10] = true }, before))")
      == "10|nil|its node was taken away by an earlier build at this time", "a configuration of a node taken away: refused")
check(L.eval("why(C.staleNodeConfig({ streetProposal = {} }, {}, before))") == "nil" and L.eval("why(C.staleNodeConfig(nil, {}, before))") == "nil",
      "nothing given: nothing")
L.execute("ERR = C.staleNodeConfig({ streetProposal = { nodeConfigsToAdd = { cfg(10, 700, 701) } } }, {}, function() error('x') end)")
check(L.eval("ERR") is None, "a piece that cannot be read: not refused")

print("the bridge")
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = bridge.find("local function executeActionOnce(a, sendCommand, useCallback, bind, done)")
body = bridge[i:bridge.find("\nexecuteAction = function", i)]
a = body.find("local okm, missing = pcall(missingEntities")
b = body.find('if a.fn == "makeWorldBuildProposalCmd" and type(a.args) == "table" and type(a.args[1]) == "table" and os.getenv("MPFEVER_STALECFG") ~= "0" then')
c = body.find("local okS, stale = pcall(C.staleNodeConfig, a.args[1], stepGone)")
d = body.find('log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " refused on every game: " .. result.err)', c)
e = body.find("local cmd, label, errs, cargs = buildCommand(")
check(0 < a < b < c < d < e, "checked before the forms are built, refused on every game with its reason (MPFEVER_STALECFG=0: as before)")
check('local key = (useCallback and ("u" .. tostring(C.uiFrame or 0)) or ("s" .. tostring(SIM.ctTick or 0))) .. "@" .. tostring(okT and tNow or "")' in body
      and "if not (C.stepGone and C.stepGone.at == key) then C.stepGone = { at = key, ids = {} } end" in body,
      "the pieces taken away kept for the builds sent in one update of the simulation (one frame of the interface), at one game "
      "time: not for a whole pause, where each build is applied before the next and a freed id goes to a new segment")
check(bridge.find(chr(9) + "G.frames = G.frames + 1" + chr(10)) < bridge.find(chr(9) + "C.uiFrame = G.frames" + chr(10)) and (chr(9) + "C.uiFrame = G.frames" + chr(10)) in bridge,
      "  the interface's frame kept for it")
f = body.find('log("SEND FAILED "')
g = body.find("if stepGone and isBuild then pcall(C.noteGone, a.args[1], stepGone) end")
check(0 < e < f < g, "what a build takes away is noted once it was sent (a build not sent takes nothing away)")
check("a native build that names" in body and "(applied as before)" in body, "a native build: only said in mod.log")
k = bridge.find("H.stalecfg = function(from, p)")
sc = bridge[k:k + 3500]
check(k > 0 and "api.engine.util.proposal.replaceSegment(s)" in sc and "api.type.SimpleProposal.new()" in sc
      and sc.count('uiRequest("makeWorldBuildProposalCmd"') == 2 and "C.staleNodeConfig(mb, { [segs[1]] = true }" in sc,
      "the autotest scenario stalecfg: two pieces of one junction, made from the same world, sent in the same frame")
check(bridge.find("local function uiRequest(fn, margs)") < k, "  (uiRequest defined before it)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
