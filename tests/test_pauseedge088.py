"""Test of #297's fix (0.8.8, mod/mpfever_1/content/mpfever_bridge.script.lua: G.pauseEdge, deferredSend, pollNativeEvents).

chris + dujuk + Wretched (host), 2026-11-14 01:10: the session's pause time was 6384400. dujuk built a street at 6384000,
before the pause on its game: stamped 6385600 as usual (8 steps ahead), no turn. The games went to that time in the pause and
stood there; chris then made five builds of the pause, all at 6385600, turns 4 to 8. Nothing ordered dujuk's build against them
(the rank of the names is not used in a pause): first on dujuk's game, second on chris's, last on the host's; other ids on each
game, a resynchronisation. Now a build made while the pause is known and not reached yet, whose stamp falls at the pause or
past it, is a build of the pause: the pause's time, a turn from the host, not shipped at the click. MPFEVER_PAUSEEDGE=0: as
before. The real G.pauseEdge and deferredSend run through lupa; the tool's path (pollNativeEvents) is checked in the source.
Needs lupa. Run: python tests/test_pauseedge088.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def grab(pattern, name):
    m = re.search(pattern, src, re.S | re.M)
    check(m is not None, name + " found")
    return m.group(0) if m else ""


try:
    import lupa.lua52 as lupa
except ImportError:
    print("FAIL lupa is not installed (pip install lupa): this test needs it")
    sys.exit(1)

EDGE = grab(r"^G\.pauseEdge = function\(now, stamp\)\n.*?^end\n", "G.pauseEdge")
DS = grab(r"^local function deferredSend\(cmd, cb, proposal, still\)\n.*?^end\n", "deferredSend")

print("the code")
check('G.pauseEdgeOn = os.getenv("MPFEVER_PAUSEEDGE") ~= "0"\n' in src, "MPFEVER_PAUSEEDGE=0: as before")
tool = src[src.index("local rf = C.refundList(api.gui.construction.getRefundableEntities())"):]
tool = tool[:tool.index('log("native build " .. id .. " held by the DLL, released at t="')]
check("local edge = not paused and G.pauseEdge ~= nil and G.pauseEdge(now, stampFor(now) + STEP)\n" in tool
      and "if edge then\n\t\t\t\tpaused = true\n" in tool, "a tool's build made as the pause begins: a build of the pause")
check("local at = paused and math.max(pausedStamp(now), edge and G.session.pauseAt or 0) or (stampFor(now) + STEP)\n" in tool,
      "    its time: the pause's, or the latest clock past it")
check("local pt = paused and G.ptOn or nil\n" in tool and "if pt then G.ptIssue(G.me, id) end\n" in tool
      and "if not paused and G.preship then pcall(G.preship, G.natRelease[#G.natRelease]) end\n" in tool,
      "    its turn asked for (the host's own given), not shipped at the click")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, SENT, ISSUED = {}, {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function logged(pat) local n = 0 for _, l in ipairs(LOGS) do if l:find(pat, 1, true) then n = n + 1 end end return n end
STEP = 200
NOW = 6384000
AHEAD = 7
function gameTime() return NOW end
function stampFor(t) return t + AHEAD * STEP end
PEERS_T = 6384200
function pausedStamp(t) return math.max(t, PEERS_T) end
function markPending() end
function send(k, p) SENT[#SENT + 1] = { k = k, p = p } end
function stillOk() return true end
C = { refundList = function() return {} end, compactProposal = function() return {} end, ROLE = "client" }
api = { gui = { construction = { getRefundableEntities = function() return {} end } } }
function newG(on)
	G = { frames = 85497, natRelease = {}, natWait = {}, session = { pauseAt = 6384400 }, me = "dujuk#2", ptOn = true, pauseEdgeOn = on,
		autoBuildSeq = 366, buildLead = false, waits = {}, wbpOf = setmetatable({}, { __mode = "k" }) }
	G.resyncRefuse = function() return false end
	G.ptIssue = function(o, id) ISSUED[#ISSUED + 1] = tostring(o) .. ":" .. tostring(id) end
	G.preship = function() PRE = (PRE or 0) + 1 end
	LOGS, SENT, ISSUED, PRE = {}, {}, {}, 0
	NOW, PEERS_T = 6384000, 6384200
end
''')
L.execute(DS.replace("local function deferredSend", "function deferredSend", 1))
run = L.eval("function(code) local f = assert(load(code)) return f() end")


def fresh(on=True):
    L.execute("newG(%s)" % ("true" if on else "false"))
    L.execute(EDGE)


print("G.pauseEdge")
fresh()
check(run("return G.pauseEdge(6384000, 6385600)") is True, "the pause known, not reached, the stamp past it: a build of the pause")
check(run("return G.pauseEdge(6384000, 6384400)") is True, "    the stamp at the pause's time: too")
check(run("return G.pauseEdge(6382000, 6383600)") is False, "the stamp before the pause: the usual build")
check(run("return G.pauseEdge(6384400, 6386000)") is False, "the game at the pause already: the pause's own rule (unchanged)")
check(run("G.session.pauseAt = nil; return G.pauseEdge(6384000, 6385600)") is False, "no pause: the usual build")
fresh(False)
check(run("return G.pauseEdge(6384000, 6385600)") is False, "MPFEVER_PAUSEEDGE=0: never")
fresh()
check(run("G.ptOn = false; return G.pauseEdge(6384000, 6385600)") is False, "MPFEVER_PAUSEDORDER=0 (no turns): never")

print("dujuk's build (the scripted builds' path, the tool's twin)")
fresh()
run("deferredSend('road', nil)")
check(run("return #G.natRelease == 1 and G.natRelease[1].at == 6384400 and G.natRelease[1].paused == true") is True,
      "held as a build of the pause, at the pause's time", run("return tostring(G.natRelease[1] and G.natRelease[1].at)"))
check(run('return SENT[1].k == "nat_pending" and SENT[1].p.at == 6384400 and SENT[1].p.paused == true and SENT[1].p.id == G.natRelease[1].id') is True,
      "    announced so: every game gives it its turn", run("return tostring(SENT[1].p.id) .. ' ' .. tostring(SENT[1].p.paused)"))
check(run('return ISSUED[1] == "dujuk#2:" .. tostring(G.natRelease[1].id) and PRE == 0 and #G.waits == 0') is True,
      "    its turn asked for, nothing shipped at the click", run("return tostring(ISSUED[1])"))
check(run('return logged("made as the pause begins (now 6384000, the pause at 6384400)") == 1') is True, "    said")
fresh()
run("PEERS_T = 6385000; deferredSend('road', nil)")
check(run("return G.natRelease[1].at == 6385000 and G.natRelease[1].paused == true") is True,
      "another game already past the pause's time: that game's time (as the builds of a pause)")
fresh()
run("NOW = 6382000; deferredSend('road', nil)")
check(run("return G.natRelease[1].at == 6383600 and G.natRelease[1].paused == nil and SENT[1].p.paused == nil and #ISSUED == 0") is True,
      "a build whose stamp is before the pause: the usual build, unchanged")
fresh()
run("G.session.pauseAt = nil; deferredSend('road', nil)")
check(run("return G.natRelease[1].at == 6385600 and G.natRelease[1].paused == nil and #ISSUED == 0 and logged('as the pause begins') == 0") is True,
      "no pause: stamped as before")
fresh()
run("NOW = 6384400; PEERS_T = 6384400; deferredSend('road', nil)")
check(run("return G.natRelease[1].at == 6384400 and G.natRelease[1].paused == true and logged('as the pause begins') == 0") is True,
      "in the pause: as before")
fresh(False)
run("deferredSend('road', nil)")
check(run("return G.natRelease[1].at == 6385600 and G.natRelease[1].paused == nil and SENT[1].p.paused == nil and #ISSUED == 0") is True,
      "MPFEVER_PAUSEEDGE=0: stamped 6385600 with no turn, as in #297")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
