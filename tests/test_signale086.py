"""Offline test: "Deutsche Signale" (tf3_signale_de_1) made the same on every game (0.8.6, #276 and Elias's reports;
DET.wrapModEvents in mod/mpfever_1/content/mpfever_bridge.script.lua, M.STRICT in mpfever_modauto.lua, launcher/Mods.cs).

Its scripts read (2026-11-13): after every load its engine sweeps the lamps no signal keeps, 400 entities an evaluation at most but
stopping once 2 ms of the PC's clock (its CLOCK, os.clock) have gone: each PC finished at another step and freed other ids. And its
interface sends the player's camera to its engine (its signals work within 1100 m of it), from every player's game.
  - its engine's CLOCK is made the one it uses without os.clock (always 0), shared by its clean-up; said in the log;
  - the other mods' scripts untouched; MPFEVER_SIGNALECLOCK=0: as before; no debug library: said, nothing changed;
  - its camera goes from one game only (modauto M.STRICT), its disk path and its game path alike;
  - the launcher's note: never as a personal mod, « Einfach / Simple » advised.
Needs lupa (pip install lupa). Run: python tests/test_signale086.py
"""
import os, sys

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


src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = src.index("function DET.wrapModEvents()")
b = src.index("\nend\n", a) + 5
code = src[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
local realgetenv = os.getenv
os.getenv = function(k) return ENV[k] end
LOGS = {}
log = function(s) LOGS[#LOGS + 1] = s end
C = { ACTIVE = true, ROLE = "host" }
SIM = {}
DET = {}
gameTime = function() return 1000 end
-- a mod's engine as Deutsche Signale writes it: CLOCK a local of its file, used by its update and its clean-up
function makeSignale()
  local CLOCK = function() return 0 end
  CLOCK = function() return 12.5 end   -- (os.clock)
  local function sweep() return CLOCK() end
  return { update = function(u, st, dt) return CLOCK() end, sweep = sweep }
end
function makeOther()
  local CLOCK = function() return 7 end
  return { update = function(u, st, dt) return CLOCK() end }
end
''' + code)


def setup(env=None, nodebug=False):
    L.execute("LOGS = {}; ENV = {}; DET_DEBUG = debug")
    if env:
        L.execute('ENV.MPFEVER_SIGNALECLOCK = "%s"' % env)
    L.execute('S = makeSignale(); O = makeOther(); game = { ["tf3_signale_de_1::/game_mechanics/de_signal_engine/de_signal_engine.script"] = S, ["some_mod::/x.script"] = O }')
    if nodebug:
        L.execute("debug = nil")
    L.execute("DET.wrapModEvents()")
    if nodebug:
        L.execute("debug = DET_DEBUG")


def logs():
    return [L.eval("LOGS[%d]" % i) for i in range(1, int(L.eval("#LOGS")) + 1)]


setup()
check(L.eval("S.update(nil, {}, 0.2)") == 0, "its engine's clock is 0 now (the clock it uses without os.clock)", L.eval("S.update(nil, {}, 0.2)"))
check(L.eval("S.sweep()") == 0, "  its clean-up shares it")
check(L.eval("O.update(nil, {}, 0.2)") == 7, "another mod's script untouched")
check(any("Deutsche Signale: its engine's clock is the same on every game now" in l for l in logs()), "said in the log")
L.execute("DET.wrapModEvents()")
check(L.eval("S.update(nil, {}, 0.2)") == 0, "done once (a second call changes nothing)")
setup("0")
check(L.eval("S.update(nil, {}, 0.2)") == 12.5, "MPFEVER_SIGNALECLOCK=0: as before")
setup(nodebug=True)
check(L.eval("S.update(nil, {}, 0.2)") == 12.5 and any("not changed (no debug library)" in l for l in logs()), "no debug library: nothing changed, said")

ma = open(os.path.join(CONTENT, "mpfever_modauto.lua"), encoding="utf-8").read()
M = lupa.LuaRuntime(unpack_returned_tuples=True)
mod = M.execute(ma)
pats = [mod.STRICT[i].pat for i in range(1, len(mod.STRICT) + 1)]
check("/de_signal_engine/" in pats, "its camera from one game only (M.STRICT)")
for path in ["@C:/Users/Public/mod.io/10640/mods/6492729/content/game_mechanics/de_signal_engine/de_signal_engine.script.lua",
             "tf3_signale_de_1::/game_mechanics/de_signal_engine/de_signal_engine.script.lua"]:
    n = mod.norm(path)
    check("/de_signal_engine/" in n, "  the pattern matches " + path.split("/")[0][:30])

ms = open(os.path.join(HERE, "..", "launcher", "Mods.cs"), encoding="utf-8-sig").read()
check("Never as a personal mod. Brakes the trains near the host's camera; its « Einfach / Simple » setting is advised in multiplayer (0.8.6)." in ms,
      "the launcher's note")
check('"hary_goods_complex", "era_oil_platform"' in ms, "Import Hub and Oil Platform on the list of mods that work")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
