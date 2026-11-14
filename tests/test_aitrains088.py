"""The game option « Computer companies' passenger trains » (0.8.8: mod/mpfever_1/content/mpfever_feat_ai.lua "aitrains", the
bridge's G.aiTrainsWanted, mpfever_ai.lua's M.trains / RP.on / M.slicingWanted; the user's choice of 2026-11-14: an option of the
lobby, off by default).
  - the option is declared like the others (one company per player only: the computer companies exist there), listed by the
    options host, shipped with the mod, in the dedicated server's table (launcher/gameopts.json);
  - off by default: RP.on() false, the step in one go, exactly as 0.8.7;
  - on: the bridge tells the module (G.aiMod.trains), the passenger railway may be planned and the step runs in slices;
  - MPFEVER_AIPAXRAIL (tests) decides over the option: 1 always, hard the Hard level only, 0 never;
  - MPFEVER_AIRAIL=0 (no railway at all) still wins.
Offline, through lupa with the mocked game of tests/ai_mock.py; the options host is the real mpfever_feat.lua.
Needs lupa (pip install lupa). Run: python tests/test_aitrains088.py
"""
import json
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CONTENT = os.path.join(ROOT, "mod", "mpfever_1", "content")
check, failures = checker()

print("the option")
feat = open(os.path.join(CONTENT, "mpfever_feat.lua"), encoding="utf-8").read()
mod = open(os.path.join(CONTENT, "mpfever_feat_ai.lua"), encoding="utf-8").read()
LF = lupa.LuaRuntime(unpack_returned_tuples=True)
MA = LF.execute(mod)
check(MA.ID == "ai" and len(MA.OPTIONS) == 1 and MA.OPTIONS[1].id == "aitrains", "mpfever_feat_ai.lua declares aitrains")
check(MA.OPTIONS[1].modes == "separate", "    one company per player only (the computer companies exist there)")
check(MA.TAB is None and MA.sim is None and MA.gui is None, "    no page, no simulation code: only declared")
check(re.search(r'F\.MODULES = \{[^}]*"ai"[^}]*\}', feat) is not None, "listed by the options host (F.MODULES)")
content = json.load(open(os.path.join(ROOT, "mod", "mpfever_1", "_content.json"), encoding="utf-8"))
check("mpfever_feat_ai.lua" in content["files"], "shipped with the mod (_content.json: the game loads it)")
go = json.load(open(os.path.join(ROOT, "launcher", "gameopts.json"), encoding="utf-8"))
ids = [o.get("id") for o in go["options"]]
check("aitrains" in ids, "in the dedicated server's table (launcher/gameopts.json)")
F = LF.execute(feat)
check(F.on(F.parse("tenders=1;aitrains=1"), "aitrains") is True and F.on(F.parse("tenders=1"), "aitrains") is False
      and F.on(F.parse(""), "aitrains") is False, "read from the session's options text: on only when asked for")

print("the bridge")
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^G\.aiTrainsWanted = function\(opts\)\n.*?^end\n", bridge, re.S | re.M)
check(m is not None, "G.aiTrainsWanted found")
LB = lupa.LuaRuntime(unpack_returned_tuples=True)
LB.globals().FEATSRC = feat
LB.execute("F = assert(load(FEATSRC))(); G = {}; C = { feat = function() return F end }\n" + (m.group(0) if m else ""))
w = LB.eval("function(o) return G.aiTrainsWanted(o) end")
check(w("aitrains=1") is True and w("stats=1;aitrains=1;yearly=1") is True, "the option on: wanted")
check(w("") is False and w(None) is False and w("stats=1") is False and w("aitrains=0") is False, "off, or no option at all: not wanted")
LB.execute("C.feat = nil")
check(w("aitrains=1") is False, "no options host: not wanted (as before)")
st = bridge[bridge.index("G.aiStep = function(st)"):]
check(st.index("pcall(G.aiMod.trains, on)") < st.index('local sl = os.getenv("MPFEVER_AISLICE")'),
      "told to the module before the step decides whether it runs in slices")
check("if G.aiMod.trains and (G.aiTrainsOpts ~= (G.featOpts or \"\")" in st, "    only with a module that knows it, when the options' text changes (and once a second)")

print("the module")
L, M = load()
run = L.eval("function(code) local f = assert(load(code)) return f() end")
run("ENV.MPFEVER_AIPAXRAIL = nil; ENV.MPFEVER_AIRAIL = nil; M.p.set(2, 400000, 150000)")
check(run("return M.f.RP.on()") is False and run("return M.slicingWanted()") is False, "by default: no passenger railway, the step in one go (as 0.8.7)")
run("M.trains(true)")
check(run("return M.f.RP.on()") is True and run("return M.slicingWanted()") is True, "the option on: the passenger railway may be planned, in slices")
run("M.trains(false)")
check(run("return M.f.RP.on()") is False and run("return M.slicingWanted()") is False, "the option off again: as before")
run("M.trains(1)")
check(run("return M.f.RP.on()") is False, "    only a true answer turns it on")
run("M.trains(true); ENV.MPFEVER_AIPAXRAIL = '0'")
check(run("return M.f.RP.on()") is False and run("return M.slicingWanted()") is False, "MPFEVER_AIPAXRAIL=0 decides over the option: never")
run("M.trains(false); ENV.MPFEVER_AIPAXRAIL = '1'")
check(run("return M.f.RP.on()") is True and run("return M.slicingWanted()") is True, "MPFEVER_AIPAXRAIL=1: always, as before")
run("ENV.MPFEVER_AIPAXRAIL = 'hard'")
check(run("return M.f.RP.on()") is False, "MPFEVER_AIPAXRAIL=hard on Normal: no, as before")
run("M.p.set(3, 350000, 150000)")
check(run("return M.f.RP.on()") is True, "    on Hard: yes, as before")
run("M.p.set(2, 400000, 150000); ENV.MPFEVER_AIPAXRAIL = nil; M.trains(true); ENV.MPFEVER_AIRAIL = '0'")
check(run("return M.f.RP.on()") is False, "MPFEVER_AIRAIL=0 (no railway at all): no passenger railway either")
run("ENV.MPFEVER_AIRAIL = nil; M.trains(false)")

if failures:
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1)
print("\nPASS")
