"""Offline test of the mods of a player's wish list (0.7.15, Elias on Discord, 2026-11-09; mpfever_modauto.lua M.STRICT,
DET.wrapModEvents in mpfever_bridge.script.lua).

Their scripts were read (docs/MODS.md):
  - Hohenzollern Bridge (hzb_cleanup) takes away the pieces of a bulldozed bridge from its interface, as Sydney Harbour Bridge
    (shb_cleanup, one game only since 0.7.0): when a player bulldozed it, the player's and the host's games both sent it;
  - Better Priority (gui/sushiflux_bp) changes line priorities and holds trains every half second of its game's clock: two
    games could decide;
    both are now in M.STRICT (their automatic commands go from one game only, whatever this player did);
  - German Trafficlights / German Railroadcrossings split their presets every 15 calls of postUpdate, which the engine also
    calls with dt 0 between steps (a game standing at a stop point, a pause): how many depends on each game's frames. A mod's
    postUpdate is now called with the steps only, as its update since 0.7.0 (MPFEVER_MODPOSTDT0=1 or MPFEVER_MODDT0=1: every
    call; the game's own scripts and MPFever's are left as they are; alone, every call).
Needs lupa (pip install lupa). Run: python tests/test_modwish0715.py
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


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("M = (function() " + open(os.path.join(CONTENT, "mpfever_modauto.lua"), encoding="utf-8").read() + " end)()")
so = L.eval("function(p) return M.strictOf({ p }) end")
check(so("@C:/Users/Public/mod.io/10640/mods/6492313/content/hzb_cleanup/hzb_cleanup.script.lua") == "Hohenzollern Bridge",
      "Hohenzollern Bridge's clean-up: one game only (as Sydney Harbour Bridge)")
check(so("@C:/Users/Public/mod.io/10640/mods/6484488/content/gui/sushiflux_bp/hub.lua") == "Better Priority",
      "Better Priority's half-second decisions: one game only")
check(so("@C:/Users/Public/mod.io/10640/mods/1/content/gui/shb_cleanup/x.lua") == "Sydney Harbour Bridge" and so("@C:/x/content/other/mod.lua") is None,
      "the others as before")

src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = src.index("function DET.wrapModEvents()")
fn = src[i:src.index("\nend\n", i) + 5]
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
L2.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
C = { ACTIVE = true, ROLE = "client" }
SIM = {}
DET = {}
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
function gameTime() return 0 end
CALLS = {}
local function mk(name) return { postUpdate = function(u, st, dt) CALLS[#CALLS + 1] = name .. ":" .. tostring(dt) end } end
game = { ["german_trafficlights::/game_script/asset_assembly.script"] = mk("gt"), ["::/game_mechanics/x.script"] = mk("base"),
         ["mpfever_1::/mpfever_bridge.script"] = mk("mpf") }
''' + fn)
run = L2.eval("function(code) return assert(load(code))() end")
run("DET.wrapModEvents()")
run("for _, k in ipairs({ 'german_trafficlights::/game_script/asset_assembly.script', '::/game_mechanics/x.script', 'mpfever_1::/mpfever_bridge.script' }) do "
    "game[k].postUpdate(nil, nil, 0); game[k].postUpdate(nil, nil, 0.2) end")
got = run("return table.concat(CALLS, ' ')")
check(got == "gt:0.2 base:0 base:0.2 mpf:0 mpf:0.2", "in a session: a mod's postUpdate with the steps only (dt 0 skipped), the game's and MPFever's every call", got)
check(run("return SIM.modPostDt0") == 1, "  the skipped calls counted")
run("DET.wrapModEvents(); CALLS = {}; game['german_trafficlights::/game_script/asset_assembly.script'].postUpdate(nil, nil, 0.2)")
check(run("return table.concat(CALLS, ' ')") == "gt:0.2", "wrapped once")
run("C.ROLE = nil; CALLS = {}; game['german_trafficlights::/game_script/asset_assembly.script'].postUpdate(nil, nil, 0)")
check(run("return table.concat(CALLS, ' ')") == "gt:0", "alone (no session): every call, as the game")
for sw in ("MPFEVER_MODPOSTDT0", "MPFEVER_MODDT0"):
    L3 = lupa.LuaRuntime(unpack_returned_tuples=True)
    L3.execute("ENV = { " + sw + " = '1' }\nos.getenv = function(k) return ENV[k] end\nC = { ACTIVE = true, ROLE = 'host' }\nSIM = {}\nDET = {}\n"
               "function log() end\nCALLS = {}\ngame = { ['m::/s.script'] = { postUpdate = function(u, st, dt) CALLS[#CALLS + 1] = dt end } }\n" + fn)
    L3.execute("DET.wrapModEvents(); game['m::/s.script'].postUpdate(nil, nil, 0)")
    check(L3.eval("#CALLS") == 1, sw + "=1: every call, as before")
check("mod script postUpdate called with the steps only: " in fn, "said in mod.log")

mods = open(os.path.join(HERE, "..", "launcher", "Mods.cs"), encoding="utf-8-sig").read()
for mid, lvl in (("hohenzollern_bridge", "fixed"), ("sushiflux_betterpriority", "caution"), ("jm_german_trafficlights", "caution"),
                 ("tf3_signale_de_1", "caution"), ("jm_german_railroadcrossings", "caution"), ("jm_signal_builder", "caution")):
    check(('["' + mid + '"] = () => new Verdict { Level = "' + lvl + '"') in mods, "the lobby: " + mid + " shown " + lvl)
ok_list = mods[mods.index("static readonly string[] CheckedOk"):mods.index("static readonly string[] FixedHostNames")]
check(all('"' + m + '"' in ok_list for m in ("bostrab_signals", "db_class_430_neu", "mrnickert_ultimate_metro")),
      "the lobby: the three that read clean shown checked")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
