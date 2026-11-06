"""Offline test of the builds shipped ahead (0.8 research, MPFEVER_PRESHIP=1 with MPFEVER_NOWAIT; off by default).

Two players building at once: this game's build is held until its time and only then captured and shipped, so the other games,
at that time too, stood until its data came (the two-builder stress test of 2026-11-06: the client stood 785 ms for the host's
stop, "LAG ... 785 ms for its data"; replays were 17 of its 42 s of stand). Now the tool's copy (the compact proposal a capture
ships) goes to the others at once, for its time; this game still gives the tool's command to the engine then, and its capture is
compared with the copy instead of being shipped. The bridge's functions are taken from the real file and run through lupa:
  - G.preship ships the copy as an act for the build's time, with the build's native id (the others' hold is matched by it), only
    with the no-wait setting, one company for everybody, a held build (not one released at once, not a paused one) with a copy;
  - G.preshipSettle: a capture like the copy, at that time: nothing more is shipped; another one, or at another time: the host's
    game is reloaded (replay_failed);
  - the release remembers the build was shipped ahead, the capture is then not shipped again, a refused one reloads.
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
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
i = src.index("G.preshipOn = function()")
j = src.index("local function shipNativeBuilds(st)")
code = src[i:j]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = { MPFEVER_PRESHIP = "1" }
os.getenv = function(k) return ENV[k] end
LOGS, SENT = {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function send(kind, p) SENT[#SENT + 1] = { kind = kind, p = p } end
function needsEnrich() return false end
function enrichEdgeObjects() end
C = { copy = function(t) local function cp(x) if type(x) ~= "table" then return x end local r = {} for k, v in pairs(x) do r[k] = cp(v) end return r end return cp(t) end,
      buildSig = function(m) return m and (tostring(#(m.toAdd or {})) .. "/" .. tostring(m.tag)) or nil end }
R = { translateOut = function() end }
WANT = true
G = { cmode = "shared", oseq = 0, me = "Client#1", myCo = 1, loadId = 3, frames = 100, gateOn = function() return WANT end }
''')
L.execute(code)
run = L.eval("function(code) local f = assert(load(code)) return f() end")

COPY = "{ toAdd = { {} }, tag = 'road' }"
L.execute("R1 = { id = 5, at = 26213600, copy = %s }; OK1 = G.preship(R1)" % COPY)
sent = L.eval("SENT")
check(L.globals().OK1 is True and len(sent) == 1 and sent[1].kind == "act", "a held build with its copy: shipped at once as an act")
a = sent[1].p if len(sent) else None
check(a is not None and a.at == 26213600 and a.natId == 5 and a.native is True and a.pre is True and a.fn == "makeWorldBuildProposalCmd",
      "for its time, with its native id (the others' hold is matched by it)")
check(L.eval("R1.preshipped") == "Client#1:1" and L.eval("R1.preSig") == "1/road", "the release remembers it and its signature")
for name, r in [("released at once (BUILDLEAD)", "{ id = 6, at = 1, lead = true, copy = %s }" % COPY),
                ("in a pause (its turn)", "{ id = 7, at = 1, paused = true, copy = %s }" % COPY),
                ("without a copy of the tool's build", "{ id = 8, at = 1 }")]:
    L.execute("SENT = {}; OKX = G.preship(%s)" % r)
    check(L.globals().OKX is False and len(L.eval("SENT")) == 0, "not shipped ahead: " + name)
L.execute("G.cmode = 'separate'; SENT = {}; OKX = G.preship({ id = 9, at = 1, copy = %s }); G.cmode = 'shared'" % COPY)
check(L.globals().OKX is False and len(L.eval("SENT")) == 0, "one company per player: not (the copy names the savegame's company)")
L.execute("WANT = false; SENT = {}; OKX = G.preship({ id = 10, at = 1, copy = %s }); WANT = true" % COPY)
check(L.globals().OKX is False, "without the no-wait setting: not")
L.execute('ENV["MPFEVER_PRESHIP"] = nil; SENT = {}; OKX = G.preship({ id = 11, at = 1, copy = %s }); ENV["MPFEVER_PRESHIP"] = "1"' % COPY)
check(L.globals().OKX is False, "without MPFEVER_PRESHIP=1 (the default): not")

# the capture
L.execute("SENT = {}; E = { pre = 'Client#1:1', preSig = '1/road', preAt = 26213600 }")
L.execute("DONE = G.preshipSettle({ preOf = E }, { at = 26213600, args = { { toAdd = { {} }, tag = 'road' } } })")
check(L.globals().DONE is True and len(L.eval("SENT")) == 0, "its capture like the copy, at its time: nothing more shipped")
L.execute("SENT = {}; DONE = G.preshipSettle({ preOf = E }, { at = 26213600, args = { { toAdd = { {}, {} }, tag = 'road' } } })")
sent = L.eval("SENT")
check(L.globals().DONE is True and len(sent) == 1 and sent[1].kind == "replay_failed", "a capture that differs: the host's game is reloaded")
L.execute("SENT = {}; DONE = G.preshipSettle({ preOf = E }, { at = 26213800, args = { { toAdd = { {} }, tag = 'road' } } })")
sent = L.eval("SENT")
check(len(sent) == 1 and sent[1].kind == "replay_failed", "built at another time than shipped: reloaded")

check("pre = r.preshipped, preSig = r.preSig, preAt = r.at" in src, "the release keeps what was shipped ahead")
check("if ek.pre then a.preOf = ek end" in src and "if not preDone then send(\"act\", a) end" in src, "its capture is not shipped again")
check('pcall(send, "replay_failed", { uid = tostring(entry.pre), why = "shipped ahead, not built by its builder" })' in src, "a build shipped ahead and refused here: reloaded")
check(src.count("if not paused and G.preship then pcall(G.preship, G.natRelease[#G.natRelease]) end") == 1
      and "if not pt and G.preship then pcall(G.preship, G.natRelease[#G.natRelease]) end" in src, "a tool's held build and an autotest's both shipped ahead")
check("if not (G.restaleOn or (G.preshipOn and G.preshipOn())) or not G.session.started" in src, "the tool's copy is kept for it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
