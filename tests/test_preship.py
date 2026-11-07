"""Offline test of the builds shipped at the click (0.7.3, MPFEVER_PRESHIP, on with the host's MPFEVER_NOSTOP=1; off by default).

Several players building at once: a build of this game is held for a step ahead and was only captured and shipped at that step,
so the other games, at that step too, stood until its data came (the two-builder stress test of 2026-11-06: "LAG ... 785 ms for
its data", 25 of the client's 42 s of stand). Now the tool's copy goes to the others at the click, with what it was computed on
(the nodes, segments, constructions it names, and how each one stood). At its step every game looks at them again: unchanged,
the others build the copy without standing and the builder confirms (pre_done, with its cost); changed (another player built
at the very same place meanwhile: the 2026-11-06 test rs1, the copy built on the client while the host's engine refused the
tool's own command, computed before the client's build), every game waits for the capture as before. A refused tool command:
the others are told, a game that built the copy reloads. The bridge's functions are taken from the real file and run through
lupa with a small world (nodes, segments, a construction):
  - G.preship ships the copy with its references and how they stand, only with the setting on, not in a pause or a lead, and
    in the separate companies mode with its constructions named for this player's company;
  - the builder at its step (G.preCleanAt) and the others (G.preUsable) find the same: unchanged, or changed;
  - the capture: confirmed when built as the copy; shipped with it otherwise (a reload when nothing had changed);
  - the others: the capture of a copy built here is not built again; a copy refused here and built by its builder, or built
    here and refused by its builder, reloads; refused on both: the games agree; a copy held for its capture is built when its
    builder confirms it.
Run: python tests/test_preship.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
OPTIONS = os.path.join(HERE, "..", "launcher", "Options.cs")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
i = src.index("-- ================================================================== builds shipped at the click")
j = src.index("local function shipNativeBuilds(st)")
code = src[i:j]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, SENT, SIMS = {}, {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function send(kind, p) SENT[#SENT + 1] = { kind = kind, p = p } end
function toSim(kind, p) SIMS[#SIMS + 1] = { kind = kind, p = p } end
function needsEnrich() return false end
function enrichEdgeObjects() end
RECEIVED = {}
function nativeReceived(a) RECEIVED[#RECEIVED + 1] = a end
local function cp(x) if type(x) ~= "table" then return x end local r = {} for k, v in pairs(x) do r[k] = cp(v) end return r end
-- (the real C.buildSig counts the parts; here: the street part's segments and a tag)
C = { copy = cp, buildSig = function(m) if not m then return nil end local p = m.proposal or {} return tostring(#(p.addedSegments or {})) .. "/" .. tostring(p.tag) end }
-- the world: nodes (place, segments), segments (ends, objects), one construction
W = { nodes = { [10] = { x = 1, y = 2, z = 3, segs = { 100, 101 } }, [11] = { x = 5, y = 6, z = 7, segs = { 100 } } },
      edges = { [100] = { n0 = 10, n1 = 11, objs = 0 }, [101] = { n0 = 10, n1 = 12, objs = 1 } },
      cons = { [500] = { file = "station.con", fe = 3, fn = 2 } } }
api = { type = { ComponentType = { BASE_NODE = "N", BASE_EDGE = "E", BASE_EDGE_STREET = "S", CONSTRUCTION = "C" } },
  engine = {
    getComponent = function(e, ct)
      if ct == "N" and W.nodes[e] then local n = W.nodes[e] return { position = { x = n.x, y = n.y, z = n.z } } end
      if ct == "E" and W.edges[e] then local b = W.edges[e] local o = {} for k = 1, b.objs do o[k] = k end return { node0 = b.n0, node1 = b.n1, objects = o, type = 0, typeIndex = -1 } end
      if ct == "S" and W.edges[e] then return { streetType = 7 } end
      if ct == "C" and W.cons[e] then local c = W.cons[e] local fe, fn = {}, {} for k = 1, c.fe do fe[k] = k end for k = 1, c.fn do fn[k] = k end return { fileName = c.file, frozenEdges = fe, frozenNodes = fn } end
      return nil
    end,
    entityExists = function(e) return W.nodes[e] ~= nil or W.edges[e] ~= nil or W.cons[e] ~= nil end,
    system = { streetSystem = { getNodeSegments = function(e) local n = W.nodes[e] return n and cp(n.segs) or {} end } } } }
-- references: shipped as { __ref, k, id }; resolved here by id (the real file resolves them by id and place)
R = { CO = { canon = 1 },
  translateOut = function(fn, args)
    local function walk(t)
      for k, v in pairs(t) do
        if type(v) == "table" then walk(v)
        elseif (k == "node0" or k == "node1") and type(v) == "number" and v >= 0 then t[k] = { __ref = true, k = "node", id = v }
        elseif k == "entity" and type(v) == "number" and v >= 0 then t[k] = { __ref = true, k = "edge", id = v }
        elseif k == "con" and type(v) == "number" then t[k] = { __ref = true, k = "con", id = v } end
      end
    end
    walk(args[1])
    if args[1].owner then args[1].owner = { __ref = true, k = "player", id = 1, co = 1 } end
    return args
  end,
  translateIn = function(t)
    for k, v in pairs(t) do
      if type(v) == "table" and v.__ref then
        local e = v.id
        local there = (v.k == "node" and W.nodes[e]) or (v.k == "edge" and W.edges[e]) or (v.k == "con" and W.cons[e])
        t[k] = there and e or -999999999
      end
    end
    return {}
  end }
CO = { entityOf = function(reg, id) return id == 1 and 1 or (1000 + id) end }
H = {}
WANT = true
G = { cmode = "shared", oseq = 0, me = "Client#1", myCo = 2, loadId = 3, frames = 100, preshipWanted = true, natWait = {}, nativeQueue = {},
      gateOn = function() return WANT end }
''')
L.execute(code)
run = L.eval("function(code) local f = assert(load(code)) return f() end")

# a build: a segment from node 10 to node 11 replacing segment 100, and the removal of construction 500
COPY = """{ proposal = { tag = 'road', addedSegments = { { entity = -1, comp = { node0 = 10, node1 = 11 } } },
  removedSegments = { { entity = 100, comp = { node0 = 10, node1 = 11 } } } }, cons = { con = 500 } }"""
L.execute("R1 = { id = 5, at = 26213600, copy = %s }; OK1 = G.preship(R1)" % COPY)
sent = L.eval("SENT")
check(L.globals().OK1 is True and len(sent) == 1 and sent[1].kind == "act", "a held build with its copy: shipped at the click as an act")
a = sent[1].p if len(sent) else None
check(a is not None and a.at == 26213600 and a.natId == 5 and a.pre is True and a.fn == "makeWorldBuildProposalCmd",
      "for its time, with its build number (the others' hold is matched by it)")
keys = [a.refs[k].key for k in range(1, len(a.refs) + 1)] if a is not None else []
check(keys == ["con:500", "edge:100", "node:10", "node:11"], "what it was computed on: each reference once, sorted, not the companies", keys)
check(a is not None and "node:10=1.0,2.0,3.0|100,101" in a.refSig and "edge:100=10-11|0|0/-1|7" in a.refSig and "con:500=con:station.con:3:2" in a.refSig,
      "and how each one stood at the click", a.refSig if a is not None else "")
check(L.eval("R1.preshipped") == "Client#1:1" and L.eval("R1.preSig") == "1/road" and L.eval("R1.refSig") == a.refSig,
      "the held build remembers it")
for name, r in [("released at once (BUILDLEAD)", "{ id = 6, at = 1, lead = true, copy = %s }" % COPY),
                ("in a pause (its turn)", "{ id = 7, at = 1, paused = true, copy = %s }" % COPY),
                ("without a copy of the tool's build", "{ id = 8, at = 1 }")]:
    L.execute("SENT = {}; OKX = G.preship(%s)" % r)
    check(L.globals().OKX is False and len(L.eval("SENT")) == 0, "not shipped at the click: " + name)
L.execute("WANT = false; SENT = {}; OKX = G.preship({ id = 10, at = 1, copy = %s }); WANT = true" % COPY)
check(L.globals().OKX is False, "without the no-wait part: not")
L.execute("G.preshipWanted = false; SENT = {}; OKX = G.preship({ id = 11, at = 1, copy = %s }); G.preshipWanted = true" % COPY)
check(L.globals().OKX is False, "without the setting (the default): not")
L.execute("G.cmode = 'separate'; SENT = {}; OKX = G.preship({ id = 12, at = 1, copy = %s }); G.cmode = 'shared'" % COPY)
sent = L.eval("SENT")
check(L.globals().OKX is True, "one company per player: shipped too")
COPYCON = "{ toAdd = { { playerEntity = 1, fileName = 'depot.con' } }, proposal = { tag = 'depot' } }"
L.execute("ENV.MPFEVER_PRESHIPCON = '0'; SENT = {}; OKX = G.preship({ id = 14, at = 1, copy = %s }); ENV.MPFEVER_PRESHIPCON = nil" % COPYCON)
check(L.globals().OKX is False and len(L.eval("SENT")) == 0, "MPFEVER_PRESHIPCON=0: a construction (a station, a depot...) shipped the usual way, as in 0.7.3")
L.execute("G.cmode = 'separate'; SENT = {}; OKX = G.preship({ id = 15, at = 1, copy = %s }); G.cmode = 'shared'" % COPYCON)
sent = L.eval("SENT")
check(L.globals().OKX is True and sent[1].p.args[1].toAdd[1].playerEntity == 1002,
      "(0.7.4) a construction shipped at the click; one company per player: its constructions named for this player's company, not the savegame's")
# (0.7.4) the copy compared by its street part and the players' constructions, not the town buildings the engine puts back
L.execute("""C.buildSig = function(m) if not m then return nil end local p = m.proposal or {} local t = {} for _, ce in ipairs(m.toAdd or {}) do t[#t + 1] = ce.fileName end
  return tostring(#(p.addedSegments or {})) .. '/' .. tostring(p.tag) .. '/' .. table.concat(t, ',') end""")
SIGA = L.eval("G.preStreetSig({ toAdd = { { playerEntity = 1, fileName = 'depot.con' } }, proposal = { tag = 'd' } })")
SIGB = L.eval("G.preStreetSig({ toAdd = { { playerEntity = 1, fileName = 'depot.con' }, { playerEntity = -1, fileName = 'house.con' } }, toRemove = { 5 }, proposal = { tag = 'd' } })")
SIGC = L.eval("G.preStreetSig({ toAdd = { { playerEntity = 1, fileName = 'station.con' } }, proposal = { tag = 'd' } })")
check(SIGA == SIGB and SIGA != SIGC, "(0.7.4) a construction's copy against its capture: its file counts, the town buildings put back do not", f"{SIGA} {SIGB} {SIGC}")
L.execute("ENV.MPFEVER_PRECONSIG = '0'")
check(L.eval("G.preStreetSig({ toAdd = { { playerEntity = 1, fileName = 'station.con' } }, proposal = { tag = 'd' } })") == "0/d/", "MPFEVER_PRECONSIG=0: the street part only, as in 0.7.3")
L.execute("ENV.MPFEVER_PRECONSIG = nil")
L.execute("C.buildSig = function(m) if not m then return nil end local p = m.proposal or {} return tostring(#(p.addedSegments or {})) .. '/' .. tostring(p.tag) end")
L.execute("G.cmode = 'separate'; ENV.MPFEVER_PRESHIPSEP = '0'; SENT = {}; OKX = G.preship({ id = 13, at = 1, copy = %s }); G.cmode = 'shared'; ENV.MPFEVER_PRESHIPSEP = nil" % COPY)
check(L.globals().OKX is False, "MPFEVER_PRESHIPSEP=0: not in that mode, as in 0.7.2")

# ---- at its step: the builder and the others look again
L.execute("G.preCleanAt(R1)")
check(L.eval("R1.preClean") is True, "the builder at its step, nothing changed: its copy is built by the others")
L.globals().ACT = a
check(L.eval("G.preUsable(ACT)") is True, "another game at that step, nothing changed: builds the copy at once")
# another player built at node 10 meanwhile (a segment more there): the builder and the others both see it
L.execute("W.nodes[10].segs = { 100, 101, 102 }")
L.execute("G.preCleanAt(R1)")
check(L.eval("R1.preClean") is False and any("node:10=1.0,2.0,3.0|100,101 then, node:10=1.0,2.0,3.0|100,101,102 now" in x for x in L.eval("LOGS").values()),
      "a segment more at one of its nodes: the builder sees the change (and says which)")
L.execute("G.natWait = { { origin = 'Client#1', id = 5, at = 26213600, arrived = true, since = 1 } }")
check(L.eval("G.preUsable(ACT)") is False and L.eval("G.preHeld['Client#1:1'] ~= nil") and L.eval("G.natWait[1].arrived") is False,
      "another game sees it too: it waits for the capture (held at its step again)")
L.execute("W.nodes[10].segs = { 100, 101 }; W.edges[100] = nil")
L.execute("G.preCleanAt(R1)")
check(L.eval("R1.preClean") is False, "its segment gone: changed")
L.execute("W.edges[100] = { n0 = 10, n1 = 11, objs = 1 }")
L.execute("G.preCleanAt(R1)")
check(L.eval("R1.preClean") is False, "a signal or a stop put on its segment: changed")
L.execute("W.edges[100].objs = 0; W.cons[500].fe = 4")
L.execute("G.preCleanAt(R1)")
check(L.eval("R1.preClean") is False, "its construction edited: changed")
L.execute("W.cons[500].fe = 3; W.nodes[99] = { x = 0, y = 0, z = 0, segs = { 1 } }")
L.execute("G.preCleanAt(R1)")
check(L.eval("R1.preClean") is True, "a build elsewhere: unchanged")
L.execute("G.preVerdict['Client#1:1'] = 'same'; W.nodes[10].segs = { 1 }")
check(L.eval("G.preUsable(ACT)") is True, "already confirmed by its builder: built from the copy")
L.execute("W.nodes[10].segs = { 100, 101 }; G.preVerdict = {}; G.preHeld = {}")

# ---- the capture, on the builder
L.execute("SENT = {}; E = { pre = 'Client#1:1', preSig = '1/road', preAt = 26213600, preClean = true, id = 5 }")
L.execute("A1 = { preOf = E }; DONE = G.preshipSettle(A1, { at = 26213600, cost = 4200, args = { { proposal = { tag = 'road', addedSegments = { {} } } } } })")
sent = L.eval("SENT")
check(L.globals().DONE is True and len(sent) == 1 and sent[1].kind == "pre_done" and sent[1].p.cost == 4200 and sent[1].p.uid == "Client#1:1",
      "built as its copy, nothing changed: a confirmation with its cost goes, not the capture")
L.execute("SENT = {}; A2 = { preOf = E }; DONE = G.preshipSettle(A2, { at = 26213600, args = { { proposal = { tag = 'road', addedSegments = { {}, {} } } } } })")
sent = L.eval("SENT")
check(L.globals().DONE is False and L.eval("A2.post") == "Client#1:1" and len(sent) == 1 and sent[1].kind == "replay_failed",
      "built otherwise, nothing had changed: its capture goes with it and the host's game is reloaded")
L.execute("SENT = {}; A3 = { preOf = E }; DONE = G.preshipSettle(A3, { at = 26213800, args = { { proposal = { tag = 'road', addedSegments = { {} } } } } })")
check(L.globals().DONE is False and L.eval("SENT")[1].kind == "replay_failed", "built at another step than shipped for: the same")
L.execute("SENT = {}; E.preClean = false; A4 = { preOf = E }; DONE = G.preshipSettle(A4, { at = 26213600, args = { { proposal = { tag = 'road', addedSegments = { {}, {} } } } } })")
check(L.globals().DONE is False and L.eval("A4.post") == "Client#1:1" and L.eval("A4.preClean") is False and len(L.eval("SENT")) == 0,
      "changed since the click: its capture goes for the others, who waited for it (no reload)")

# ---- the others
def other(setup, code_):
    L.execute("SENT = {}; SIMS = {}; RECEIVED = {}; G.preUsed = {}; G.preHeld = {}; G.preVerdict = {}; G.nativeQueue = {}; " + setup)
    return L.eval(code_)

check(other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock() }",
            "G.prePost({ post = 'Client#1:1', preClean = true, args = { { proposal = { tag = 'road', addedSegments = { {} } } } } })") is True
      and len(L.eval("SENT")) == 0, "its capture after its copy was built here: dropped, not built again")
check(other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock(), refused = true }",
            "G.prePost({ post = 'Client#1:1', preClean = false, args = { {} } })") is True
      and L.eval("SENT")[1].kind == "replay_failed", "refused here, built by its builder (its capture came): reloaded")
check(other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock() }",
            "G.prePost({ post = 'Client#1:1', preClean = false, args = { { proposal = { tag = 'road', addedSegments = { {}, {} } } } } })") is True
      and L.eval("SENT")[1].kind == "replay_failed", "built here from its copy, its builder saw a change and built otherwise: reloaded")
check(other("G.preHeld['Client#1:1'] = { uid = 'Client#1:1' }", "G.prePost({ post = 'Client#1:1', args = { {} } })") is False
      and L.eval("G.preHeld['Client#1:1']") is None, "held here for its capture: the capture is built (as any build)")
check(other("G.nativeQueue = { { uid = 'Client#1:1', pre = true }, { uid = 'Host:4' } }", "G.prePost({ post = 'Client#1:1', args = { {} } })") is False
      and len(L.eval("G.nativeQueue")) == 1 and L.eval("G.nativeQueue[1].uid") == "Host:4", "its capture before its time here: built instead of the copy")
other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock() }", "G.preCancelled({ pre = 'Client#1:1' })")
check(L.eval("SENT")[1].kind == "replay_failed" if len(L.eval("SENT")) else False, "built here from its copy, refused by its builder's engine: reloaded")
other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock(), refused = true }", "G.preCancelled({ pre = 'Client#1:1' })")
check(len(L.eval("SENT")) == 0, "refused here and by its builder's engine: the games agree, nothing more")
other("G.nativeQueue = { { uid = 'Client#1:1', pre = true } }", "G.preCancelled({ pre = 'Client#1:1' })")
check(len(L.eval("G.nativeQueue")) == 0, "refused by its builder before its time here: the copy is not built here either")
other("G.preHeld['Client#1:1'] = { uid = 'Client#1:1', at = 5 }", "H.pre_done(nil, { uid = 'Client#1:1', origin = 'Host', cost = 4200 })")
check(len(L.eval("G.nativeQueue")) == 1 and len(L.eval("RECEIVED")) == 1, "held here, confirmed by its builder as its copy: built from the copy")
check(L.eval("SIMS")[1].kind == "replay_cost_set" and L.eval("SIMS")[1].p.cost == 4200, "its builder's cost goes to this game's books")
other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock(), refused = true }", "H.pre_done(nil, { uid = 'Client#1:1', origin = 'Host' })")
check(L.eval("SENT")[1].kind == "replay_failed", "refused here, confirmed built by its builder: reloaded")
other("G.preUsed['Client#1:1'] = { sig = '1/road', t = os.clock() - 31, refused = true }", "G.preTick()")
check(len(L.eval("SENT")) == 1 and L.eval("SENT")[1].kind == "replay_failed", "refused here and no word from its builder in 30 s: reloaded")

L.execute("SENT = {}; OKX = G.preship({ id = 22, at = 1, copy = { toAdd = {}, toRemove = {}, proposal = { addedSegments = {} } } })")
check(L.globals().OKX is False and len(L.eval("SENT")) == 0, "a copy with nothing in it: never shipped")
check("pcall(C.compactProposal, made)" in src and "G.wbpOf[cmd] = { p = p, bits = bits }" in src and 'os.getenv("MPFEVER_PRESHIPCMD") ~= "0"' in src, "a scripted build without its proposal: the command's own")
L.execute("G.aiNatCo = { [21] = 4 }; SENT = {}; G.cmode = 'separate'; OKX = G.preship({ id = 21, at = 1, copy = %s }); G.cmode = 'shared'; G.aiNatCo = nil" % COPY)
sent = L.eval("SENT")
check(L.globals().OKX is True and sent[1].p.co == 4, "a computer company's build: shipped for that company")

# ---- the rest of the file
check('if a.pre and not preCon and os.getenv("MPFEVER_PRERAW") ~= "0" then' in src and "return replayNativeStreet(a)" in src[src.index('MPFEVER_PRERAW'):][:1200],
      "the others apply a copy of a street as the tool made it, never made again from its shape")
check("local preCon = a.pre and type(a.args[1]) == \"table\" and (#(a.args[1].toAdd or {}) > 0 or #(a.args[1].toRemove or {}) > 0)" in src,
      "(0.7.4) a copy with constructions is replayed as a capture (the engine's conversion of its constructions, then the build)")
# (0.7.4) a real tool hands its proposal over at proposalPrepareForApply, before its command; proposalApply comes once the engine
# applied it, after the held build was announced (the manual test x1 of 2026-11-07)
gh = src[src.index("local function guiHandleEvent("):]
check('elseif name == "builder.proposalPrepareForApply" then' in gh and "pcall(G.toolPrepared, param, id)" in gh,
      "(0.7.4) the tool's copy taken when the tool prepares its build, before its command")
tp = src[src.index("G.toolPrepared = function(param, id)"):src.index("G.toolCopyFrom = function(param)")]
check("if G.toolCopyAtApply() then return end" in tp and "if not G.toolCopyAtApply() then return end" in tp and 'MPFEVER_TOOLCOPYAPPLY") == "1"' in src,
      "(0.7.4) never at proposalApply any more (MPFEVER_TOOLCOPYAPPLY=1: as before)")
# (0.7.4) the street tool prepares nothing: its copy is its last preview (proposalCreate), never for a tool seen preparing
check("pcall(G.toolCreated, id, param)" in gh and "if G.toolPrepares[tool] or G.toolCopyAtApply() or os.getenv(\"MPFEVER_PRECREATE\") == \"0\" then return end" in src,
      "(0.7.4) a tool that prepares nothing (the street tool): its last preview is its copy; never for a tool that prepares (MPFEVER_PRECREATE=0: none)")
check("if dt > 0.008 then" in src and "G.createSlowUntil = os.clock() + 1" in src, "(0.7.4) a preview too long to read is not read for a second (the interface keeps its speed)")
tk = src[src.index("G.takeToolCopy = function()"):src.index("G.isWorldAct = function(p)")]
check('(t.at == "prepare" or t.at == "create") and 120 or 5' in tk, "(0.7.4) a copy of the preparation or of the preview is taken up to 120 frames later (the command is held a few frames after)")
check("preSig = G.preStreetSig(r.copy)" in src and "local sig = G.preStreetSig(type(o.args)" in src, "the street part is compared (the town buildings the engine moves are not in the copy)")
check('G.preVerdict[tostring(a.uid)] ~= "same" then' in src, "refused here after its builder confirmed it: reloaded at once")
check("ctx = (G.natCtx and G.natCtx[r.id]) or r.ctxBits" in src and "G.natRelease[#G.natRelease].ctxBits = madeCtx" in src,
      "a scripted build's Context flags go with its copy, as a tool's (the others apply it the same way)")
rc = src[src.index('elseif name == "replay_cost" then'):src.index('elseif name == "replay_cost_set" then')]
check("while #st.rcost >" in rc, "the books keep their size limit where they grow")
check("pre = r.preshipped, preSig = r.preSig, preAt = r.at, preClean = r.preClean" in src, "the release keeps what was shipped at the click")
check("if r.preshipped then pcall(G.preCleanAt, r) end" in src, "the builder looks again at its step, before the tool's command goes")
check("if ek.pre then a.preOf = ek end" in src and "if not preDone then send(\"act\", a) end" in src and "a.preOf = nil" in src, "the capture: confirmed or shipped")
check('send("nat_cancel", { origin = G.me, id = entry.id, pre = entry.pre })' in src, "a tool's command refused here: the others are told")
check("if p.pre then pcall(G.preCancelled, p) end" in src and "(not w.arrived or p.pre)" in src, "...and stop holding for it even though its copy came")
check("if p.post and G.prePost then" in src, "a capture after its copy: looked at first")
check("elseif due and a.pre and G.preUsable and not G.preUsable(a) then" in src, "the others look again at its step")
check("if a.pre then G.preUsed[tostring(a.uid)] = { sig = a.preSig, t = os.clock(), origin = a.origin } end" in src, "a copy built here is remembered")
check("G.preUsed[tostring(a.uid)].refused = true" in src, "a copy refused here waits for what its builder's engine did")
check("(rc.late and rc.cost == nil and now - rc.at <= 50 * STEP)" in src and 'elseif name == "replay_cost_set" then' in src,
      "its builder's cost booked when it comes")
tool = src.index('send("nat_pending", { origin = G.me, at = at, id = id, paused = pt })\n\t\t\t\t-- (0.8, no wait: its copy goes')
check(tool > 0 and src.count("if not paused and G.preship then pcall(G.preship, G.natRelease[#G.natRelease]) end") == 1
      and "G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() pcall(G.preship, held) end }" in src,
      "a tool's held build and an autotest's (a frame later: a computer company's gets its company) both shipped at the click, after their announcement")
check("if not (G.restaleOn or pre) or not G.session.started or (G.cmode == \"separate\" and not pre) then return end" in src,
      "the tool's copy is kept for it, in the separate companies mode too")
check("if not G.restaleOn or r.lead or r.preshipped then return false end" in src, "never replayed here the old restale way")
check('G.preshipWanted = G.featureOn("MPFEVER_PRESHIP")' in src, "on with the host's setting")
opt = open(OPTIONS, encoding="utf-8").read()
check('Key = "MPFEVER_NOSTOP", Session = true, DefaultOn = false' in opt, "the host's setting in the launcher, off by default")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
