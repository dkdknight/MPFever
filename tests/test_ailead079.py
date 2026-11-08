"""Offline test: a computer company's commands no longer make the other games stand behind the host (0.7.9, G.lineLeadStamp in
mod/mpfever_1/content/mpfever_bridge.script.lua).

The user's server 2026-11-08 14:41-14:58 (separate companies, a computer company, NOSTOP on): every time the host's AI bought,
sold or sent a vehicle to a line, ACTLEAD took it for a player with a vehicle window open ("ACTLEAD: a vehicle or a line in
hand"): the host led, the other games stayed behind it and stood 7 to 11 s, 8 times in 18 minutes. An AI command (tok "ai",
written by mpfever_ai.lua) is now stamped as usual; a player's own vehicle and line commands lead as before.
MPFEVER_AILEAD=1: as before. Run: python tests/test_ailead079.py (lupa for the Lua part: pip install lupa)
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
ai = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_ai.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check('C.line("act_req", { tok = "ai",' in ai, "the computer companies' commands are written with tok \"ai\"")
m = re.search(r"^G\.lineLeadStamp = function\(a, now\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "G.lineLeadStamp found")
body = m.group(0) if m else ""
check('if a.tok == "ai" and os.getenv("MPFEVER_AILEAD") ~= "1" then return end' in body
      and body.index('a.tok == "ai"') < body.index("terrainLead("), "  an AI command returns before the lead starts (MPFEVER_AILEAD=1: as before)")
try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed: the Lua part skipped")
if lupa and m:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
LEADS = 0
G = { actLeadOn = true, buildLead = true, ACT_LEAD_FNS = { makeVehicleSellCmd = true, makeVehicleBuyCmd = true }, LINE_LEAD_FNS = {} }
G.buildLeadPeers = function() return true end
G.buildLeadState = function() return false, "test" end
terrainLead = function() LEADS = LEADS + 1 end
log = function() end
overshootReserve = function() return 2 end
''' + body)
    L.execute('G.lineLeadStamp({ fn = "makeVehicleSellCmd", tok = "ai" }, 0)')
    check(L.eval("LEADS") == 0, "an AI's vehicle sold: no lead")
    L.execute('G.lineLeadStamp({ fn = "makeVehicleBuyCmd", tok = "12" }, 0)')
    check(L.eval("LEADS") == 1, "  a player's vehicle bought from its window: leads, as before")
    L.execute('ENV.MPFEVER_AILEAD = "1"; G.lineLeadStamp({ fn = "makeVehicleSellCmd", tok = "ai" }, 0)')
    check(L.eval("LEADS") == 2, "  MPFEVER_AILEAD=1: the AI leads too, as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
