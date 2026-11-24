"""Offline test (0.9.7, #482 #483): a stop whose construction has parameters of its own is no longer shipped at the click, and a
stop whose engine check throws is not sent (mpfever_bridge.script.lua: G.preshipObjects, the dry run of replayStop).

magnu's game (the host) stopped twice in one evening on williamcolberg's stops of the Traditional Bus Stops mod
(ingo_stops::/stations/street/ingo_stops/ingo_stops.con): "Assertion '!mil.fatInstances.empty() || !mil.thinInstances.empty()'",
collision_util::CalcBoundingBox. Both were copies shipped at the click (PRESHIP): the copy carried the stop's construction and place,
not its parameters ("auswahl", which stop of the mod), which the capture of williamcolberg's earlier stops of the same mod carried
(params = {year, seed, noLandmarkResources, auswahl = 5}: built fine). In every report, the only two copies at the click with a mod's
stop are these two; the base game's stops (31) and signals (86) have no parameters ("params = {}") and were built.
  - before (MPFEVER_PRESHIPPARAMS=0, as 0.9.6): such a stop is shipped at the click without its parameters (the crash);
  - now: a MOD's construction with parameters of its own is shipped the usual way (its capture), said in the logs; the base game's
    stops (none) and path signals (5 parameters, read in game by the autotest conparams; its 86 copies at the click in the reports
    were built) still go at the click; a mod's construction whose parameters cannot be read: the usual way; a copy that already has
    params goes at the click;
  - the replaying game: an exception from the engine's check of a stop (not a refusal, not an error of MPFever's own script) means
    the build would stop the simulation: not sent, reported as not reproduced (MPFEVER_STOPDRYFAIL=0: sent, as before).
Run: python tests/test_stopparams097.py
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


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


STUBS = r"""
G = { cmode = "shared", me = "host", oseq = 0, frames = 1, loadId = 1, myCo = 1 }
R = {}
C = {}
SENT = {}
LOGS = {}
ENV = {}
function log(t) LOGS[#LOGS + 1] = t end
function send(kind, p) SENT[#SENT + 1] = kind; SENTP = SENTP or {}; SENTP[#SENT] = p end
function needsEnrich() return false end
function enrichEdgeObjects() end
os = { getenv = function(k) return ENV[k] end }
C.copy = function(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = C.copy(v) end
  return o
end
R.translateOut = function() TRANSLATED = (TRANSLATED or 0) + 1 end
R.isAssetFile = function() return false end
C.ser = function(t) return "{...}" end
-- the base game's stop (id 7, params = {}) and the mod's (id 9, one parameter of its own: auswahl)
GETFAIL = false
api = { res = { constructionRep = {
  find = function(n)
    if n == "::/stations/street/small_stops/small_old.con" then return 7 end
    if n == "ingo_stops::/stations/street/ingo_stops/ingo_stops.con" then return 9 end
    if n == "::/infrastructure/signal/signal_path_c.con" then return 11 end
    return -1
  end,
  get = function(id)
    if GETFAIL then error("Unknown exception") end
    if id == 9 then return { params = { { key = "auswahl" } } } end
    if id == 11 then return { params = { {}, {}, {}, {}, {} } } end
    return { params = {} }
  end } } }
"""


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    parts = []
    for name in ("G.preHasContent", "G.preHasObjects", "G.preStopOnly", "G.noteEo", "G.f32", "G.eoModelName", "G.preshipObjects", "G.preship", "G.preshipSettle"):
        m = re.search(r"^" + re.escape(name) + r" = function\(.*?\)\n.*?^end\n", src, re.S | re.M)
        check(m is not None, name + " found")
        if not m:
            return 1
        parts.append(m.group(0))
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(STUBS + "\n".join(parts) + r"""
G.preshipOn = function() return true end
G.preTouchesCon = function() return nil end
G.preRefsOf = function() return {} end
G.refSigOf = function() return "" end
G.preStreetSig = function() return "sig" end
G.preStats = { shipped = 0, same = 0, differ = 0, changed = 0 }
function run(mod, path, env, withParams, getFail)
  ENV = env or {}
  GETFAIL = getFail == true
  SENT = {}; SENTP = {}; LOGS = {}; TRANSLATED = 0
  G.natEo = {}
  G.natEoOrder = {}
  G.noteEo(7, 0, "3f0aa0fa", mod, path)
  local stop = { name = "Gerlevvej" }
  if withParams then stop.params = { auswahl = 5 } end
  local copy = { proposal = { addedSegments = { {} }, removedSegments = { {} }, edgeObjectsToAdd = { stop } } }
  local r = { id = 7, at = 1000, copy = copy }
  local ok, res = pcall(G.preship, r)
  return tostring(ok) .. "|" .. tostring(res) .. "|" .. TRANSLATED .. "|" .. #SENT
end
function logged(s)
  for _, l in ipairs(LOGS) do if tostring(l):find(s, 1, true) then return true end end
  return false
end
""")
    run = L.eval("run")
    logged = L.eval("logged")
    lua_table = L.eval("function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end")

    def env(**kw):
        return lua_table(L.table_from(kw))

    MOD, MPATH = "ingo_stops", "stations/street/ingo_stops/ingo_stops.con"
    BASE = "stations/street/small_stops/small_old.con"
    # the reproduction: as 0.9.6, the mod's stop goes at the click without its parameters
    check(run(MOD, MPATH, env(MPFEVER_PRESHIPPARAMS="0")).startswith("true|true|1|1"),
          "before (MPFEVER_PRESHIPPARAMS=0, as 0.9.6): the mod's stop shipped at the click without its parameters (the crash of #482)")
    check(run(MOD, MPATH) == "true|false|0|0", "now: a stop whose construction has parameters of its own goes the usual way (nothing sent at the click)")
    check(logged("has 1 parameter(s) the click does not show"), "  (said in the logs, with the construction)")
    check(run("", BASE).startswith("true|true|1|1"), "a base-game stop (params = {}): still at the click")
    check(run("", "infrastructure/signal/signal_path_c.con").startswith("true|true|1|1"),
          "a base-game path signal (5 parameters in game, its 86 copies at the click built): still at the click")
    check(run(MOD, MPATH, None, True).startswith("true|true|1|1"), "a copy that carries its params: at the click")
    check(run(MOD, MPATH, None, False, True) == "true|false|0|0" and logged("its parameters not read"),
          "parameters not readable: a mod's construction the usual way")
    check(run("", BASE, None, False, True).startswith("true|true|1|1"), "parameters not readable: a base-game construction at the click")

    # the replaying game: the dry run's exception
    i = src.find("local okV, crit, msgs, pd = pcall(G.stopDryVerdict")
    j = src.find("local function stopCount()", i)
    blk = src[i:j]
    k = blk.find("elseif not okV then")
    tail = blk[k:]
    check(k > 0 and 'os.getenv("MPFEVER_STOPDRYFAIL") ~= "0"' in tail and 'not tostring(crit):find("%.lua:%d+")' in tail,
          "replay: an exception of the engine's check (not one of MPFever's script errors) is caught, MPFEVER_STOPDRYFAIL=0: as before")
    r = tail.find("G.replayFailedFn")
    ret = tail.find("return", r)
    sent_old = tail.find("): sent\")")
    check(r > 0 and 0 < ret < sent_old, "  the stop is reported as not reproduced and the function returns before the old 'sent' path")
    check(src.find('toSim("replaying", { tok = a.tsTok })', j) > j, "  (returned before the simulation is told a replay comes: nothing counted)")
    # the dry run is the engine's proposal data: the only call that can throw there
    dv = re.search(r"^G\.stopDryVerdict = function\(sp, ctx\)\n.*?^end\n", src, re.S | re.M)
    check(dv is not None and "api.engine.util.proposal.makeProposalData(sp, ctx)" in dv.group(0), "G.stopDryVerdict asks the engine's proposal data")
    cp = src.find("H.conparams = function(from, p)")
    check(cp > 0 and "signal_path_c.con" in src[cp:cp + 1500], "autotest conparams: the base game's stops' and signals' parameters read in game")
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
