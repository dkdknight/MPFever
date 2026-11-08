"""Offline test of RESTALE v2 (0.7.7): a held build whose place another player changed since the click is replayed on every game,
its builder's too, and its tool still gets its answer (G.failidOn / G.restaleV2 / G.othersBusy / G.restaleMark / G.restaleNeed /
G.restaleBody in mod/mpfever_1/content/mpfever_bridge.script.lua; failid / FailOne / ApplyBody in native/mpfever_native.cpp).

A tool's build is computed at the click, held about two seconds, then applied as computed. Another player's build landing at the
same place meanwhile (two streets of one junction upgraded at once) made the builder apply a proposal computed on the old world
while every other game rebuilt it from what was shipped: the games parted. The old answer (G.restale, MPFEVER_RESTALE=1 since
0.5.12) dropped the tool's command, and the tool stayed busy for ever (#91), and it fired on any build anywhere (29 of 39 held
builds in #133). Now, by default with a native module that says failid=1:
  - at the click, while another player builds, the tool's copy is kept with the act it would ship (translated then) and the
    fingerprint of what it names already standing (nodes, segments, constructions: PRESHIP's);
  - at the release, only when another player's build came since the click AND that fingerprint changed (or the copy was computed
    before a build applied here around the click): the copy is shipped and replayed here like on every other game; a build naming
    nothing already standing, a stop or a signal: applied as the tool computed it, as before;
  - the tool's own command goes to the engine in its turn and is refused there ("failid", then "releaseid"), never dropped:
    the native module refuses that payload at Apply as the engine refuses a command naming an entity that is gone (the
    element's success byte +0x30 set to 0, nothing dispatched; Apply 0x9e84b0 in 40425);
  - one company per player: the copy's constructions named for this player's company, replayed too (not cancelled);
  - MPFEVER_RESTALE=0: off; =1: the old rule; MPFEVER_FAILID=0 (native): no refusal, and v2 stays off.
Needs lupa (pip install lupa). Run: python tests/test_restale077.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
NATIVE = os.path.join(HERE, "..", "native", "mpfever_native.cpp")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


# ---------------------------------------------------------------- the native refusal (source)
nat = open(NATIVE, encoding="utf-8").read().replace("\r\n", "\n")
ab = nat[nat.index("static u64 ApplyBody(void* a, void* b, bool inLoop)\n{"):]
ab = ab[:ab.index("\n}\n")]
ref = ab[ab.index("if (kind == 52 && g_failPayN > 0) {"):]
check(ab.index("if (kind == 52 && g_failPayN > 0) {") < ab.index("TerrainCapture(pay)") < ab.index("g_applyOrig(a, b)"),
      "ApplyBody: the refusal before anything else is done with the build (terrain capture, the company of the build, the engine)")
check("if (f.pay != pay) continue;" in ref and "((u8*)b)[0x30] = 0;" in ref[:900] and "return 0;" in ref[:1100],
      "  that payload only: its success byte 0, nothing dispatched (the engine's own 'invalid entity' path)")
check("if (now - f.at > 60000) { f.pay = 0;" in ref and "f.pay = 0; _InterlockedDecrement(&g_failPayN);" in ref, "  matched once, within 60 s")
fo = nat[nat.index("static void FailOne()"):]
fo = fo[:fo.index("\n}\n")]
check("u8* pay = *(u8**)h->cmd;" in fo and "*(u8*)(pay + 0x9b8) == 52" in fo and fo.rstrip().endswith("ReleaseOne();"),
      "FailOne: the held command's payload noted (a build), then given to the engine like a released one (the tool gets its answer)")
check(nat.count("else if (g_nFailIds > 0 && IsFailed(g_held[g_heldHead % 64]->id)) FailOne(); else ReleaseOne();") == 2,
      "  in both release loops (the mod silent, and by id)")
check('memcmp(l, "failid ", 7) == 0 && g_failOn' in nat, "the control word failid N")
check('"tickepochs=1\\nfailid=1\\n"' in nat and 'GetEnvironmentVariableA("MPFEVER_FAILID", fv, 3) > 0 && fv[0] == \'0\') g_failOn = false;' in nat,
      "native_state.txt tells the mod (failid=1); MPFEVER_FAILID=0: not")

# ---------------------------------------------------------------- the bridge (lupa)
try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): the Lua part skipped")
    lupa = None

if lupa:
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    pre = src[src.index("-- ================================================================== builds shipped at the click"):src.index("local function shipNativeBuilds(st)")]
    rs = src[src.index('G.restaleOn = os.getenv("MPFEVER_RESTALE") == "1"'):src.index("-- autotest: a scripted build follows the tools' path")]
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, SENT, CTL, CMDS = {}, {}, {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function send(kind, p) SENT[#SENT + 1] = { kind = kind, p = p } end
function toSim() end
function nativeCtl(s) CTL[#CTL + 1] = s end
function needsEnrich() return false end
function enrichEdgeObjects() end
function shortErr(e) return tostring(e) end
O = { sendCommand = function(c) CMDS[#CMDS + 1] = c end, event = function(a, b, c) return c end }
BS, NL = "\\", "\n"
local function cp(x) if type(x) ~= "table" then return x end local r = {} for k, v in pairs(x) do r[k] = cp(v) end return r end
FILES = {}
C = { copy = cp, DIR = "S", buildSig = function(m) return "sig" end, compactProposal = function(p) return cp(p) end,
  ser = function(x) return tostring(x) end, Tf = function(fr, en, ...) return string.format(en, ...) end,
  IO = { open = function(p) local s = FILES[p] if not s then return nil end return { read = function() return s end, close = function() end } end } }
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
G = { cmode = "shared", oseq = 0, me = "Client#1", myCo = 2, loadId = 3, frames = 1000, natWait = {}, nativeQueue = {}, session = { started = true },
      pt = { of = {} }, ptKey = function(a, b) return a .. ":" .. b end, ptDone = function() end, coSay = function() end,
      gateOn = function() return false end, preshipOn = function() return false end }
''')
    L.execute(pre)
    L.execute(rs)

    def fresh(native="tickepochs=1\nfailid=1\n", env=None):
        L.execute("FILES = {}; G.failidState = nil; ENV = {}; SENT = {}; CTL = {}; CMDS = {}; LOGS = {}; G.othersAt = {}; G.worldFrame = 0; G.nativeQueue = {}; G.replayOut = 0; G.frames = 1000; G.cmode = 'shared'")
        if native is not None:
            L.execute('FILES["S\\\\native_state.txt"] = %s' % ("'" + native.replace("\n", "\\n") + "'"))
        for k, v in (env or {}).items():
            L.execute("ENV.%s = '%s'" % (k, v))

    COPY = """{ proposal = { addedSegments = { { entity = -1, comp = { node0 = 10, node1 = 11 } } },
      removedSegments = { { entity = 100, comp = { node0 = 10, node1 = 11 } } } }, cons = { con = 500 } }"""
    OPEN = "{ proposal = { addedSegments = { { entity = -1, comp = { node0 = -2, node1 = -3 } } }, addedNodes = { { entity = -2 }, { entity = -3 } } } }"
    STOP = "{ proposal = { edgeObjectsToAdd = { { segmentEntity = 100, param = 0.5 } } } }"

    def held(copy, extra=""):
        # a held build announced at frame 1000, game time 500000; its copy made at frame 996
        L.execute("G.lastCopyFrame = 996; RB = { id = 5, at = 500600, frame0 = 1000, t0 = 500000, copy = %s %s }; G.restaleMark(RB)" % (copy, extra))

    fresh()
    check(L.eval("G.failidOn()") is True and L.eval("G.restaleV2()") is True, "on by default with a native module that refuses on purpose (failid=1)")
    fresh(native="tickepochs=1\n")
    check(L.eval("G.restaleV2()") is False, "  an older native module (no failid): off, never a dropped tool command")
    fresh(env={"MPFEVER_RESTALE": "0"})
    check(L.eval("G.restaleV2()") is False, "  MPFEVER_RESTALE=0: off")

    fresh()
    check(L.eval("G.othersBusy()") is False, "nobody else building: no copy kept (no cost at the click)")
    L.execute("G.noteOthers({ origin = 'Host', at = 499800, native = true })")
    check(L.eval("G.othersBusy()") is True and L.eval("G.othersAt[1].frame") == 1000, "another player's build received: the copies are kept", L.eval("G.othersAt[1].frame"))

    fresh(); held(COPY)
    keys = [L.eval("RB.refs[%d].key" % k) for k in range(1, int(L.eval("#RB.refs")) + 1)]
    check(keys == ["con:500", "edge:100", "node:10", "node:11"], "at the click: what the build names already standing", keys)
    check(L.eval("RB.v2args ~= nil and RB.refSig ~= nil and RB.sigUncertain == nil") is True, "  with the act it would ship and how each one stood")
    check(L.eval("G.restaleNeed(RB, 500600)") is None, "no other build since the click: applied as the tool computed it")
    L.execute("G.worldFrame = 1010")
    check(L.eval("G.restaleNeed(RB, 500600)") is None, "another player's build since the click, elsewhere (what it names unchanged): applied as computed (#133: 29 of 39)")
    L.execute("W.nodes[10].x = 1.5")
    why = L.eval("G.restaleNeed(RB, 500600)")
    check(why is not None and "what it names changed since the click" in why and "node:10" in why, "the same place changed: replayed on every game", why)
    L.execute("W.nodes[10].x = 1")
    fresh(); L.execute("G.othersAt = { { at = 500400, origin = 'Host', frame = 1001 } }"); held(COPY)
    L.execute("W.edges[100] = nil")
    why = L.eval("G.restaleNeed(RB, 500600)")
    check(why is not None and "t=500400" in why, "  a build stamped between the click and the release that took a segment it names away", why)
    L.execute("W.edges[100] = { n0 = 10, n1 = 11, objs = 0 }")

    fresh(); held(OPEN); L.execute("G.worldFrame = 1010")
    check(L.eval("#RB.refs") == 0 and L.eval("G.restaleNeed(RB, 500600)") is None, "a build naming nothing already standing (#133's GCT station): never replayed for this")
    fresh(); held(STOP); L.execute("G.worldFrame = 1010")
    check(L.eval("RB.v2skip") == "a stop or a signal" and L.eval("G.restaleNeed(RB, 500600)") is None, "a stop or a signal: as before (a copy replayed as a street lost its stop)")
    fresh(); L.execute("G.worldFrame = 998"); held(COPY)
    check(L.eval("RB.sigUncertain") is True and L.eval("G.restaleNeed(RB, 500600)") is not None,
          "another player's build applied here after the tool's copy was made and before the click: replayed (the copy was computed before it)")
    fresh(env={"MPFEVER_RESTALEFORCE": "1"}); held(COPY); L.execute("G.worldFrame = 1010")
    check((L.eval("G.restaleNeed(RB, 500600)") or "").startswith("forced"), "MPFEVER_RESTALEFORCE=1 (tests): every held build with a copy")

    # the release: shipped, replayed here, the tool's command refused by the engine (never dropped)
    fresh(); held(COPY); L.execute("W.nodes[11].y = 9; G.worldFrame = 1010; OKB = G.restaleBody(RB, 500600); W.nodes[11].y = 6")
    ctl = [L.eval("CTL[%d]" % k) for k in range(1, int(L.eval("#CTL")) + 1)]
    check(L.globals().OKB is True and ctl == ["failid 5", "releaseid 5"] and L.eval("#CMDS") == 1,
          "the release: the tool's command marked to refuse, then given to the engine at once (a command lets the native module go)", ctl)
    check("dropid 5" not in ctl, "  never dropped (the tool got no answer and stayed busy, #91)")
    a = L.eval("SENT[1] and SENT[1].p")
    check(L.eval("SENT[1].kind") == "act" and a.fn == "makeWorldBuildProposalCmd" and a.natId == 5 and a.at == 500600 and a.native is True,
          "  its copy shipped for the release's time, as the build it is")
    check(L.eval("SENT[1].p.args[1].removedSegments ~= nil or SENT[1].p.args[1].proposal.removedSegments[1].entity.__ref == true") is True,
          "  the act translated at the click (as the tool named things then)")
    check(L.eval("#G.nativeQueue") == 1 and L.eval("G.nativeQueue[1].uid") == a.uid, "  and replayed here in the replays' queue, like on every other game")
    check(any("RESTALE native build 5 shipped as" in L.eval("LOGS[%d]" % k) for k in range(1, int(L.eval("#LOGS")) + 1)), "  one RESTALE line in the log")
    fresh(); held(COPY); L.execute("G.worldFrame = 1010; OKB = G.restaleBody(RB, 500600)")
    check(L.globals().OKB is False and L.eval("#CTL") == 0 and L.eval("#SENT") == 0, "no race: nothing done, the release goes the usual way")
    fresh(native="tickepochs=1\n"); held(COPY); L.execute("W.nodes[11].y = 9; G.worldFrame = 1010; OKB = G.restaleBody(RB, 500600); W.nodes[11].y = 6")
    check(L.globals().OKB is False and L.eval("#CTL") == 0, "  an older native module: off (applied as computed, as in 0.7.6)")

    # one company per player: replayed with this player's company (not cancelled)
    COPYCON = "{ toAdd = { { playerEntity = 1, fileName = 'depot.con', con = 500 } }, proposal = { removedSegments = { { entity = 100, comp = { node0 = 10, node1 = 11 } } } } }"
    fresh(); L.execute("G.cmode = 'separate'"); held(COPYCON); L.execute("W.nodes[10].z = 4; G.worldFrame = 1010; OKB = G.restaleBody(RB, 500600); W.nodes[10].z = 3")
    check(L.globals().OKB is True and L.eval("SENT[1].kind") == "act" and L.eval("SENT[1].p.args[1].toAdd[1].playerEntity") == 1002,
          "one company per player: replayed too, its construction named for this player's company", L.eval("SENT[1] and SENT[1].kind"))
    check(L.eval("CTL[1]") == "failid 5", "  the tool's command refused, not dropped")

    # the hooks in the file
    check("pcall(G.restaleMark, G.natRelease[#G.natRelease])" in src, "the mark taken when the held build is announced")
    check("(G.preshipOn and G.preshipOn()) or (G.restaleV2() and G.othersBusy())" in src, "  the street tool's previews read while another player builds")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
