"""Offline test (0.8.9): a stop or a signal is shipped at the click only with MPFEVER_PRESHIPSTOP=1 (research; G.preship in
mpfever_bridge.script.lua).

#296 and #297 (0.8.7): every stand of more than a second before a replay was a stop or a signal built by the player who did not
lead (shipped the usual way, its data came once its builder reached its step). Shipping it at the click was tried for 0.8.9 and
kept off: the tool's copy has no model nor place on the segment for its objects (the copies of 0.7.4 in the report of AMD and
keviK, 2026-11-07), and the stop replays ask for a resynchronisation without a model.
  - G.preship run here through lupa with the engine stubbed: by default a copy with a stop is shipped the usual way (false,
    nothing translated or sent, said in the logs), a plain street at the click as before;
  - MPFEVER_PRESHIPSTOP=1 or MPFEVER_PRESHIPOBJ=1 (as 0.7.4): a copy with a stop goes on to be shipped;
  - the other games still replay such a copy as a capture (replayNative), never as a street proposal;
  - the scenario dstop has its leader option (MPFEVER_DSTOP_LEAD=1), which gives the terrain tool back at its end (its stops
    stay a script's simple proposal, never shipped at the click: the reproduction of the stand, not of its fix).
Run: python tests/test_preshipstop089.py
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
api = { res = { constructionRep = { find = function(n) if n == "::/stations/street/small_stops/small_old.con" then return 7 end return -1 end } } }
"""


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    parts = []
    for name in ("G.preHasContent", "G.preHasObjects", "G.noteEo", "G.f32", "G.eoModelName", "G.preshipObjects", "G.preship", "G.preshipSettle"):
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
G.natEo = {}
G.natEoOrder = {}
LAST = nil
-- eo: nil = no line from the command; else { bits, mod, path }
function run(withStop, env, eo)
  ENV = env or {}
  SENT = {}; SENTP = {}; LOGS = {}; TRANSLATED = 0
  G.natEo = {}
  G.natEoOrder = {}
  if eo then G.noteEo(7, 0, eo[1], eo[2], eo[3]) end
  local copy = { proposal = { addedSegments = { {} }, removedSegments = { {} } } }
  if withStop then copy.proposal.edgeObjectsToAdd = { { name = "Impasse" } } end
  local r = { id = 7, at = 1000, copy = copy }
  local ok, res = pcall(G.preship, r)
  LAST = withStop and copy.proposal.edgeObjectsToAdd[1] or nil
  LASTR = r
  return tostring(ok) .. "|" .. tostring(res) .. "|" .. TRANSLATED .. "|" .. #SENT .. "|" .. tostring(r.preshipped)
end
""")
    run = L.eval("run")
    lua_table = L.eval("function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end")

    def env(**kw):
        return lua_table(L.table_from(kw))

    check(run(True, None) == "true|false|0|0|nil", "a stop: shipped the usual way by default (nothing translated or sent)")
    check(any("a stop or a signal: shipped the usual way" in str(x) for x in L.globals().LOGS.values()), "  (and said in the logs)")
    check(run(False, None).startswith("true|true|1|1|host:"), "a plain street: shipped at the click as before")
    eo_ok = L.eval('{"3f0aa0fa", "", "stations/street/small_stops/small_old.con"}')
    check(run(True, env(MPFEVER_PRESHIPSTOP="1"), eo_ok).startswith("true|true|1|1|host:"), "MPFEVER_PRESHIPSTOP=1: a stop read in the tool's command shipped at the click")
    last = L.globals().LAST
    check(last.model == "::/stations/street/small_stops/small_old.con" and repr(last.param) == "0.5415188074111938",
          "  its construction and place filled exactly as its capture reads them (::/...small_old.con, 0.54151880741119385)")
    act = L.globals().SENTP[1]
    check(act is not None and act.ts is not None and all(act.ts[k] == 0 for k in ("al", "ar", "tr", "rk", "ba", "br", "tv")),
          "  its copy says the build moves no ground (town numbers 0: the other games hide its replay from the towns)")
    settle = L.eval("""function(ts)
      SENT = {}; SENTP = {}; LOGS = {}
      local r = LASTR
      local a = { preOf = { pre = r.preshipped, preSig = "sig", preAt = 1000, preClean = true, preTs = r.preTs } }
      local o = { at = 1000, args = { {} }, ts = ts, cost = 30000 }
      local ok, res = pcall(G.preshipSettle, a, o)
      local kinds = {}
      for i, k in ipairs(SENT) do kinds[i] = k end
      return tostring(ok) .. "|" .. tostring(res) .. "|" .. table.concat(kinds, ",")
    end""")
    check(settle(L.eval("{ al = 0, ar = 0, tr = 0, rk = 0, ba = 0, br = 0, tv = 0 }")) == "true|true|pre_done",
          "  its builder moved no ground either: only the confirmation goes")
    check(settle(L.eval("{ al = 0.5, ar = 0, tr = 0, rk = 0, ba = 0, br = 0, tv = 0 }")).startswith("true|true|replay_failed,pre_done"),
          "  its builder's build moved ground: a resynchronisation is asked for")
    check(run(True, env(MPFEVER_PRESHIPSTOP="1")) == "true|false|0|0|nil", "MPFEVER_PRESHIPSTOP=1: nothing read in the command: the usual way")
    check(any("not complete at the click" in str(x) for x in L.globals().LOGS.values()), "  (and said in the logs)")
    check(run(True, env(MPFEVER_PRESHIPSTOP="1"), L.eval('{"3f0aa0fa", "somemod", "stations/x.con"}')) == "true|false|0|0|nil",
          "MPFEVER_PRESHIPSTOP=1: a construction not known here: the usual way")
    check(run(True, env(MPFEVER_PRESHIPSTOP="1"), L.eval('{"7f800000", "", "stations/street/small_stops/small_old.con"}')) == "true|false|0|0|nil",
          "MPFEVER_PRESHIPSTOP=1: a place that is no number (infinite): the usual way")
    f32 = L.eval("G.f32")
    check(f32("3f800000") == 1.0 and f32("0") == 0.0 and f32("bf000000") == -0.5, "G.f32: 1, 0, -0.5 from their bits")
    name = L.eval("G.eoModelName")
    check(name("", "stations/a.con") == "::/stations/a.con" and name("m_1", "/stations/a.con") == "m_1::/stations/a.con" and name("", "") is None,
          "G.eoModelName: the base game's ::/<path>, a mod's <mod>::/<path>")
    check(run(True, env(MPFEVER_PRESHIPOBJ="1")).startswith("true|true|1|1|host:"), "MPFEVER_PRESHIPOBJ=1: at the click, as 0.7.4")
    check(run(False, env(MPFEVER_PRESHIPSTOP="1"), eo_ok).startswith("true|true|1|1|host:"), "MPFEVER_PRESHIPSTOP=1: a plain street unchanged")

    j = src.find("local preCon = a.pre and type(a.args[1]) == \"table\"")
    rp = src[j:j + 1400]
    k = rp.find('if a.pre and not preCon and G.preHasObjects(a.args[1]) and os.getenv("MPFEVER_PRESHIPOBJ") ~= "1" then')
    check(k > 0 and "preCon = true" in rp[k:k + 300], "the other games: a copy with stops or signals replayed as a capture")

    d = src.find("H.dstop = function(from, p)")
    body = src[d:d + 12000]
    check('os.getenv("MPFEVER_DSTOP_LEAD") == "1"' in body and 'send("terrainlead", { role = C.ROLE })' in body, "dstop: the other game led with a terrain tool (MPFEVER_DSTOP_LEAD=1)")
    check('send("terrainlead_stop", {})' in body and "return done()" in body, "dstop: the terrain tool given back when its stops are done")

    nat = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read()
    i = nat.find('Buf q; q.str("deferred_eo ")')
    blk = nat[max(0, i - 2600):i + 200]
    check(i > 0 and "pay + 0x128" in blk and "% 0x1a0 == 0" in blk and "eo + 0x28" in blk and "0x70 : 0x90" in blk,
          "native: deferred_eo from the held command's edgeObjectsToAdd (+0x128, 0x1a0 each: place +0x28, mod +0x70, path +0x90)")
    check('"MPFEVER_EOCLICK"' in blk and nat.find('Buf e; e.str("deferred ")') > i, "  (MPFEVER_EOCLICK=0: none; written before the deferred line)")
    check("H.leadhold = function(from, p)" in src and "MPFEVER_LEADHOLD_SECONDS" in src, "scenario leadhold: a game that leads with a terrain tool, no edit")
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
