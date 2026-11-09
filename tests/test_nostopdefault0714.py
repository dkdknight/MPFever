"""Test of « without waiting » and « without stopping » on by default (0.7.14, launcher/Options.cs, launcher/lang.json,
mod/mpfever_1/content/mpfever_bridge.script.lua).

The user's choice of 2026-11-09: both on by default for every player, so that the reports tell what is left to fix; 0.7.13 had
removed them. They are the host's settings again (the whole session the same, never one game alone), and the problems found in
the field are fixed first:
  (a) Options.cs: the host's two settings, on by default, "1" on and "0" off in settings.txt, kept under new names in
      mpfever_settings.txt (StoreName): the values kept before 0.7.14 (off, the default then) are not read;
  (b) lang.json: their four texts back, with the translations of 0.7.12;
  (c) the bridge's switches (lupa): none set (the default) -> NOWAIT, PRESHIP, LEADACK, HELDNOTPAUSED on, ACTLEAD off (no
      longer part of NOSTOP: its leads moved the stands onto the other game in #150); NOSTOP=0 -> all off; NOSTOP=0 NOWAIT=1 ->
      NOWAIT alone; NOSTOP=1 NOWAIT=0 -> all but NOWAIT; ACTLEAD=1 -> on;
  (d) a launcher session (lupa, with the mod's own os.getenv wrapper): the host's "0" in settings.txt turns them off whatever a
      PC's environment says, the host's "1" turns them on; an autotest (no settings.txt) reads its environment, on by default;
  (e) NOWAIT v2 (lupa): a street stop by the script forms keeps its wait (its retries, without the tool's pricing, with the street
      cleanup, by the engine's conversion, must come at its step: r161), MPFEVER_NOWAITSTOPS=1 as in 0.7.12; the other replays
      still go without waiting;
  (f) PRESHIP (lupa): a held build that takes a construction away (and puts none in its place) goes the usual way (#172: CowboyPilot's bulldozer on his
      modular station, "built here otherwise than shipped at the click" twice, every game had taken it away),
      MPFEVER_PRESHIPREMOVE=1 as in 0.7.12; a street or a construction added still at the click.
Needs lupa (Lua 5.2). Run: python tests/test_nostopdefault0714.py
"""
import json
import os
import sys

import lupa.lua52 as lupa

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


op = read("launcher", "Options.cs")
src = read("mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
com = read("mod", "mpfever_1", "content", "mpfever_common.lua")

# ---------------------------------------------------------------- (a) Options.cs
for k in ("MPFEVER_NOWAIT", "MPFEVER_NOSTOP"):
    check(('new Opt { Key = "%s", Session = true, DefaultOn = true, OnValue = "1", OffValue = "0", StoreName = "opt.%s.0714",' % (k, k)) in op,
          "(a) %s: the host's setting, on by default, \"1\" / \"0\", kept under a new name" % k)
check('static string StoreKey(Opt o) => o.Launcher ? o.Key : o.StoreName ?? ("opt." + o.Key);' in op and "public string StoreName;" in op,
      "(a) a setting's own store name is used to read and write it (the old opt.MPFEVER_NOWAIT / NOSTOP values are not read)")
ia, ib, ic = op.index('Key = "MPFEVER_BUILDLEAD"'), op.index('Key = "MPFEVER_NOWAIT"'), op.index('Key = "MPFEVER_NOSTOP"')
check(ia < ib < ic < op.index('Key = "MPFEVER_NOREFUND"'), "(a) in the session settings, after « Responsive builds », as in 0.7.12")
check("Expert = true" not in op[ib:op.index('Key = "MPFEVER_NOREFUND"')], "(a) shown in the session settings (not expert)")

# ---------------------------------------------------------------- (b) lang.json
lang = json.loads(read("launcher", "lang.json"))["texts"]
texts = ["Other players' builds without waiting (experimental)",
         "Your game no longer stops at every build of another player to wait for the engine's answer: it is applied at the same moment, without a pause.",
         "Several players building without stopping (experimental)",
         "When several players build at once, the games no longer stop to wait for each other's builds: each one goes at the click and every game checks at its time that nothing changed where it is made. Includes the no-wait setting."]
check(all(k in lang and len(lang[k]) >= 10 and "de" in lang[k] for k in texts), "(b) the four texts back in lang.json, translated")
check(all(('"' + k.replace('"', '\\"') + '"') in op for k in texts), "(b) the launcher's English texts are the same keys")

# ---------------------------------------------------------------- (c) the bridge's switches
fi = src.index("G.nostopOn = false\nG.featureOn = function(name)")
fj = src.index("-- ================================================================== no wait for the answer (0.8, MPFEVER_NOWAIT=1)")
feat = src[fi:fj]
ra = src.index("local function resumeAfterLoad(state)")
ri = src.index('G.nostopOn = os.getenv("MPFEVER_NOSTOP") ~= "0"', ra)
rj = src.index('G.actLeadOn = os.getenv("MPFEVER_ACTLEAD") == "1"', ra)
reads = src[ri:src.index("\n", rj)]
check(ri - ra < 1600 and rj > ri, "(c) the switches read at every start of a session, near the top of resumeAfterLoad")
PARTS = ["gateWanted", "preshipWanted", "leadAckOn", "heldNotPausedOn", "actLeadOn"]
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = {}\n" + feat)
L.execute("function readAll()\n" + reads + "\nend")


def parts(env):
    L.execute("ENV = {}")
    for k, v in env.items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute("readAll()")
    g = L.globals().G
    return {p: g[p] for p in PARTS}


r = parts({})
check(all(r[p] is True for p in PARTS[:4]) and r["actLeadOn"] is False, "(c) none set (the default): NOWAIT, PRESHIP, LEADACK, HELDNOTPAUSED on, ACTLEAD off", r)
r = parts({"MPFEVER_NOSTOP": "0", "MPFEVER_NOWAIT": "0"})
check(all(v is False for v in r.values()), "(c) the host's two settings off: every part off", r)
r = parts({"MPFEVER_NOSTOP": "0", "MPFEVER_NOWAIT": "1"})
check(r["gateWanted"] is True and all(r[p] is False for p in PARTS[1:]), "(c) « without stopping » off, « without waiting » on: NOWAIT alone", r)
r = parts({"MPFEVER_NOSTOP": "1", "MPFEVER_NOWAIT": "0"})
check(r["gateWanted"] is False and all(r[p] is True for p in PARTS[1:4]), "(c) « without waiting » off: all but NOWAIT (PRESHIP then does nothing: it needs NOWAIT)", r)
r = parts({"MPFEVER_ACTLEAD": "1"})
check(r["actLeadOn"] is True, "(c) MPFEVER_ACTLEAD=1: the vehicle and line windows lead, as before", r)
check("return G.gateOn and G.gateOn()" not in src and "if not (G.gateOn and G.gateOn()) or not G.preshipWanted then return false end" in src,
      "(c) PRESHIP needs NOWAIT, as before")

# ---------------------------------------------------------------- (d) a launcher session: the host's values over a PC's environment
wi = com.index("C.SETTINGS = {}\n")
wj = com.index("\treturn rawGetenv(k)\nend\n", wi) + len("\treturn rawGetenv(k)\nend\n")
wrap = com[wi:wj]


def session(settings, env):
    R = lupa.LuaRuntime(unpack_returned_tuples=True)
    R.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end")
    for k, v in env.items():
        R.execute('ENV["%s"] = "%s"' % (k, v))
    R.globals().FILE = settings
    R.execute("""
C = { ACTIVE = true, DIR = "S", BS = string.char(92), NL = string.char(10), CR = string.char(13) }
C.IO = { open = function(p, m)
    if FILE == nil or p ~= "S" .. C.BS .. "settings.txt" then return nil end
    return { read = function(self) return FILE end, close = function(self) end }
end }
local BS, NL, CR = C.BS, C.NL, C.CR
""" + wrap + "\nG = {}\n" + feat + "\nfunction readAll()\n" + reads + "\nend\nreadAll()")
    g = R.globals().G
    return {p: g[p] for p in PARTS}


OFF = "MPFEVER_BUILDLEAD=1\nMPFEVER_NOWAIT=0\nMPFEVER_NOSTOP=0\n"
ON = "MPFEVER_BUILDLEAD=1\nMPFEVER_NOWAIT=1\nMPFEVER_NOSTOP=1\n"
r = session(OFF, {"MPFEVER_NOWAIT": "1", "MPFEVER_NOSTOP": "1", "MPFEVER_PRESHIP": ""})
check(all(r[p] is False for p in PARTS[:4]), "(d) the host's « off »: off on this game, whatever its environment says", r)
r = session(ON, {"MPFEVER_NOWAIT": "0", "MPFEVER_NOSTOP": "0"})
check(all(r[p] is True for p in PARTS[:4]), "(d) the host's « on »: on, whatever this PC's environment says", r)
r = session(None, {})
check(all(r[p] is True for p in PARTS[:4]), "(d) an autotest (no settings.txt): on by default", r)
r = session(None, {"MPFEVER_NOSTOP": "0", "MPFEVER_NOWAIT": "0"})
check(all(v is False for v in r.values()), "(d) an autotest with MPFEVER_NOSTOP=0 MPFEVER_NOWAIT=0: off, as 0.7.13", r)

# ---------------------------------------------------------------- (e) NOWAIT v2: the street stops keep their wait
i = src.index("-- ================================================================== no wait for the answer (0.8, MPFEVER_NOWAIT=1)")
j = src.index("-- ================================================================== native deferral (with mpfever_native.dll)")
nw = src[i:j]
rst = src[src.index("local function replayStop(a, plan, variant)"):]
rst = rst[:rst.index("\nend\n")]
check('local nws = os.getenv("MPFEVER_NOWAITSTOPS")\n\tif nws == "1" or (dryRun and nws ~= "0") then pcall(G.gateSingle) end\n\treplaySend(cmd, function(res, success)' in rst,
      "(e) (0.7.15, NOWAIT v3) a street stop by the script forms is marked single again once the engine's verdict was asked "
      "(MPFEVER_STOPDRYRUN=0 or MPFEVER_NOWAITSTOPS=0: it waits, as in 0.7.14; =1: as in 0.7.12)")
check(rst.count("pcall(G.gateSingle)") == 1, "(e)   its only G.gateSingle is behind that switch")
check(src.count("pcall(G.gateSingle)") == 8, "(e) the 7 other replays still marked single (streets, tracks, constructions, upgrades, the engine's stops)", src.count("pcall(G.gateSingle)"))
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
L2.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nLOGS = {}\nfunction log(s) LOGS[#LOGS + 1] = s end\nC = { ACTIVE = true }\nG = {}\n")
L2.execute(nw)
run = L2.eval("function(code) local f = assert(load(code)) return f() end")
# the street stop of r161: the replay under way, its command handed, refused, tried again a frame later
L2.execute("G.gateWanted = true; G.gateCur = { at = 100000, uid = 'Bence#11:16' }")
GATE = ("local dryRun = os.getenv('MPFEVER_STOPDRYRUN') ~= '0'; local nws = os.getenv('MPFEVER_NOWAITSTOPS'); "
        "if nws == '1' or (dryRun and nws ~= '0') then pcall(G.gateSingle) end; G.gateCur.handed = 1")
L2.execute("ENV.MPFEVER_STOPDRYRUN = '0'")
L2.execute(GATE)
check(run("return G.gateHolds()") == 100000, "(e) MPFEVER_STOPDRYRUN=0 (0.7.14): the game holds at the stop's step while its answer (and a retry) may come")
L2.execute("G.gateLate('a refused stop, tried again')")
check(run("return G.gateHolds()") == 100000 and not any("after the build's step" in str(s) for s in L2.globals().LOGS.values()),
      "(e)   its retry is held too: nothing comes after the step")
L2.execute("ENV.MPFEVER_NOWAITSTOPS = '1'; G.gateCur = { at = 100000, uid = 'x' }")
L2.execute(GATE)
check(run("return G.gateHolds()") is False, "(e) MPFEVER_NOWAITSTOPS=1: not held, as in 0.7.12")
L2.execute("ENV.MPFEVER_NOWAITSTOPS = nil; ENV.MPFEVER_STOPDRYRUN = nil; G.gateCur = { at = 100000, uid = 'y' }")
L2.execute(GATE)
check(run("return G.gateHolds()") is False, "(e) (0.7.15) default: the engine's verdict asked first, not held")
L2.execute("ENV.MPFEVER_NOWAITSTOPS = '0'; G.gateCur = { at = 100000, uid = 'z' }")
L2.execute(GATE)
check(run("return G.gateHolds()") == 100000, "(e) (0.7.15) MPFEVER_NOWAITSTOPS=0: held, as in 0.7.14")
L2.execute("ENV.MPFEVER_NOWAITSTOPS = nil")
L2.execute("G.gateCur = { at = 100000, uid = 'street' }; G.gateSingle(); G.gateCur.handed = 1")
check(run("return G.gateHolds()") is False, "(e) a street by the script forms: once handed, no wait (NOWAIT as before)")

# ---------------------------------------------------------------- (f) PRESHIP: a construction taken away goes the usual way
pi = src.index("G.preship = function(r)")
pj = src.index("\tlocal args = { n = 4, [1] = C.copy(r.copy)", pi)
head = src[pi:pj] + "\treturn true\nend\n"
check('if #(r.copy.toRemove or {}) > 0 and #(r.copy.toAdd or {}) == 0 and os.getenv("MPFEVER_PRESHIPREMOVE") ~= "1" then' in head
      and "takes a construction away: shipped the usual way" in head, "(f) a copy that takes a construction away: shipped the usual way")
L3 = lupa.LuaRuntime(unpack_returned_tuples=True)
L3.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nLOGS = {}\nfunction log(s) LOGS[#LOGS + 1] = s end\nG = {}\n"
           "G.preshipOn = function() return true end\n"
           "R = { isAssetFile = function(f) f = tostring(f or '') return f == '' or f:find('mpfever_asset', 1, true) ~= nil end }\n"
           + src[src.index("G.preHasContent = function(m)"):src.index("G.preship = function(r)")] + head)
pre = L3.eval("function(copy) return G.preship({ id = 74, at = 4878600, copy = copy }) end")
bull = L3.eval("{ toRemove = { 1 }, proposal = { removedNodes = { 1, 2 }, removedSegments = { 1 } } }")
check(pre(bull) is False, "(f) #172: the bulldozer on a modular station: not at the click")
check(pre(L3.eval("{ proposal = { addedSegments = { 1 }, addedNodes = { 1, 2 } } }")) is True, "(f) a street: at the click, as before")
check(pre(L3.eval("{ toAdd = { { fileName = 'station.con' } }, proposal = { addedSegments = { 1 } } }")) is True, "(f) a construction added: at the click, as before")
check(pre(L3.eval("{ proposal = { removedSegments = { 1 } } }")) is True, "(f) a street taken away by the bulldozer: at the click, as before")
check(pre(L3.eval("{ toRemove = { 1 }, toAdd = { { fileName = 'station.con' } }, proposal = { addedSegments = { 1 } } }")) is True,
      "(f) a station's edit (one construction for another: 168 in the field, none failed): at the click, as before")
L3.execute("ENV.MPFEVER_PRESHIPREMOVE = '1'")
check(pre(bull) is True, "(f) MPFEVER_PRESHIPREMOVE=1: at the click, as in 0.7.12")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
