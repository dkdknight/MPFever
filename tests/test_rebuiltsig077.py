"""Offline test: the engine's second application of a rebuilt build is recognised, not shipped by every game (0.7.7, issue
#133, C.rebuiltSig in mpfever_common.lua, SIM.addReplaySig and the "replay_sig" event in the bridge).

Issue #133 (yoyo's session, 0.7.6, 2026-11-07 23:11): YkeWoudstra electrified 18 track segments. Every game replayed that build
in the form "full", which gives the tool's node configurations again only for the nodes it touches (0.7.6, #131): 1 of the
tool's 24. The engine applied the build a second time at the same moment, as it does for some node configurations; each game
recognises that second application by the signature of the action it just replayed (C.buildSig), but that signature was the
shipped build's, 24 configurations: "capture: build 0/0/18/18/0/0/1/1/0/0/-1353,12025/false differs from the action(s) applied
at this time (0/0/18/18/0/0/24/1/...)". The three games each shipped it as a build of their own (yoyo:1, Bence#11:3,
YkeWoudstra#2:4): refused on the others ("Apply: invalid entity"), resynchronisation n°6.
  - C.rebuiltSig (run here through lupa): the shipped build with the configurations the form really adds and removes gives the
    capture's signature of that session exactly; nil when it is the shipped one's (the raw forms: nothing more is kept);
  - C.rebuildProposal says which configurations each form adds and removes (C.rebuiltCfgs), buildCommand clears it before every
    form, executeActionOnce takes it right after the form that worked;
  - the simulation keeps that signature next to the shipped one for this game time (SIM.addReplaySig, once), after the
    action (the engine applies the command after the script's update); a paused action's goes to the simulation before its
    command ("replay_sig", sent by the interface's hook around that call only);
  - MPFEVER_REBUILTSIG=0: the shipped build's signature only, as before.
Needs lupa (pip install lupa). Run: python tests/test_rebuiltsig077.py
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
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fns = {}
for name in ("buildSig", "rebuiltSig"):
    m = re.search(r"^function C\." + name + r"\(.*?^end\n", common, re.S | re.M)
    check(m is not None, "C." + name + " found")
    if not m:
        sys.exit(1)
    fns[name] = m.group(0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
# the nodes of yoyo's session whose configurations the tool gave (positions from the capture's log line); 900 is the node the
# form gives its configuration again (-1353,12025)
L.execute('''
C = {}
POS = { [900] = { x = -1353.2, y = 12025.4 } }
api = { type = { ComponentType = { BASE_NODE = 1 } },
  engine = { getComponent = function(e, t) local p = POS[e] if p then return { position = p } end end } }
''' + fns["buildSig"] + fns["rebuiltSig"])
L.execute('''
local P = { {-1344,12029}, {-1383,12119}, {-1353,12025}, {-1392,12115}, {-1423,12210}, {-1432,12206}, {-1449,12269}, {-1348,12027},
  {-1388,12117}, {-1428,12208}, {-1453,12267}, {-1458,12265} }
local cfgs = {}
for i = 1, 24 do local p = P[(i - 1) % #P + 1]; cfgs[i] = { entity = { p = { x = p[1], y = p[2] } }, comp = { doubleSlipSwitch = false } } end
local segs, rm = {}, {}
for i = 1, 18 do segs[i] = { entity = -i, comp = {} }; rm[i] = 357000 + i end
SHIPPED = { proposal = { addedNodes = {}, removedNodes = {}, addedSegments = segs, removedSegments = rm, edgeObjectsToAdd = {},
  edgeObjectsToRemove = {}, nodeConfigsToAdd = cfgs, nodeConfigsToRemove = { 318940 } }, toAdd = {}, toRemove = {} }
-- the form "full": the configuration of node 900 given again, the one of 318940 removed
FULL = { add = { { entity = 900, comp = { doubleSlipSwitch = false } } }, rm = { 318940 } }
RAW = { add = cfgs, rm = { 318940 } }
''')
shipped = L.eval("C.buildSig(SHIPPED)")
rebuilt = L.eval("C.rebuiltSig(SHIPPED, FULL)")
print("issue #133: the electrification of 18 segments")
check(shipped.startswith("0/0/18/18/0/0/24/1/0/0/-1344,12029/false"), "the shipped build's signature: 24 configurations (" + shipped[:40] + "...)")
check(rebuilt == "0/0/18/18/0/0/1/1/0/0/-1353,12025/false",
      "the rebuilt form's: exactly the capture's of that session, 0/0/18/18/0/0/1/1/0/0/-1353,12025/false (" + str(rebuilt) + ")")
check(L.eval("C.rebuiltSig(SHIPPED, RAW)") is None, "a raw form (the tool's configurations): nil, the shipped signature says it")
check(L.eval("#SHIPPED.proposal.nodeConfigsToAdd") == 24 and L.eval("SHIPPED.streetProposal") is None,
      "the shipped build is not changed (a copy)")
check(L.eval("C.rebuiltSig(nil, FULL)") is None and L.eval("C.rebuiltSig(SHIPPED, nil)") is None and L.eval("C.rebuiltSig({}, FULL)") is None,
      "nothing known: nil")
L.execute('''
NONE = { add = {}, rm = { 318940 } }
''')
check(L.eval("C.rebuiltSig(SHIPPED, NONE)") == "0/0/18/18/0/0/0/1/0/0", "a form that gives none again (MPFEVER_CFGREADD=0): 0 configurations")

print("the forms say what they keep")
i = common.find("function C.rebuildProposal(m, opts)")
body = common[i:common.find("\nlocal function segmentFrom", i)]
check(body.find("C.rebuiltCfgs = nil") < body.find("local sp = C.newOf(\"SimpleProposal\")"), "C.rebuildProposal: none known at its start")
check("C.rebuiltCfgs = { add = {}, rm = cfgKeep }" in body and body.find("cfgKeep = keep") < body.find("C.rebuiltCfgs = { add = {}, rm = cfgKeep }"),
      "  the street part: the configurations it removes, none added yet")
check("C.rebuiltCfgs.add = st.nodeConfigsToAdd" in body and "if okr then C.rebuiltCfgs.rm = rm end" in body, "  the raw forms: the tool's (and #127's replacement)")
check("if okc then C.rebuiltCfgs.add = put end" in body, "  the other forms: those given again (#131)")
bc = bridge[bridge.find("local function buildCommand(fn, srcArgs, tries)"):]
bc = bc[:bc.find("\nend\n")]
check(bc.find("C.rebuiltCfgs = nil") < bc.find("pcall(C.rebuildArgs"), "buildCommand: cleared before every form (a native form has no street part)")
ex = bridge[bridge.find("local function executeActionOnce(a, sendCommand, useCallback, bind, done)"):]
ex = ex[:ex.find("local createdKey")]
check(ex.find("local rcfgs = C.rebuiltCfgs") > ex.find("buildCommand(a.fn") and ex.find("local rcfgs = C.rebuiltCfgs") < ex.find("if isBuild then"),
      "executeActionOnce: taken right after the form that worked (before the debug line rebuilds it)")
check('os.getenv("MPFEVER_REBUILTSIG") ~= "0"' in ex and "result.rebuiltSig = rs" in ex and "if C.rebuiltSigHook then pcall(C.rebuiltSigHook, rs) end" in ex,
      "  its signature in the result, and to the hook (MPFEVER_REBUILTSIG=0: not, as before)")

print("the simulation keeps it")
m = re.search(r"SIM\.addReplaySig = function\(st, t, sig\)\n(.*?)\nend\n", bridge, re.S)
check(m is not None, "SIM.addReplaySig")
if m:
    L.execute("SIM = {}; function log() end; SIM.addReplaySig = function(st, t, sig)\n" + m.group(1) + "\nend")
    L.execute('''
ST = { replaySigs = { at = 100, list = { "A" } } }
SIM.addReplaySig(ST, 100, "B"); SIM.addReplaySig(ST, 100, "B"); SIM.addReplaySig(ST, 100, "A")
ST2 = { replaySigs = { at = 50, list = { "A" } } }
SIM.addReplaySig(ST2, 100, "B")
''')
    check(L.eval("#ST.replaySigs.list") == 2 and L.eval("ST.replaySigs.list[2]") == "B", "  next to the shipped one, once")
    check(L.eval("ST2.replaySigs.at") == 100 and L.eval("#ST2.replaySigs.list") == 1, "  a list of another game time: started again")
k = bridge.find("local okx, r = pcall(executeAction, a, api.cmd.sendCommand, false, st.bind)")
sim = bridge[k:k + 900]
check(k > 0 and sim.find("st = state:get() or st") < sim.find("SIM.addReplaySig(st, now, r.rebuiltSig)") and "changed = true" in sim,
      "  a running game's action: after the action, in the state it saves")
ev = bridge[bridge.find('elseif name == "replay_sig" then'):]
check('SIM.addReplaySig(st, gameTime(), param.sig)' in ev[:400], "  a paused action's: the event replay_sig")
p = bridge.find('C.rebuiltSigHook = function(sig) toSim("replay_sig", { sig = sig }) end')
q = bridge.find("withActor(PL(a), executeAction, a, O.sendCommand, true, G.bind, function(r)")
z = bridge.find("C.rebuiltSigHook = nil", q)
check(0 < p < q < z and z - q < 2500, "  the interface's hook set around the paused action's call only")
check(bridge.count("C.rebuiltSigHook = function") == 1, "  nowhere else (the simulation's own state never sets it)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
