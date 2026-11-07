"""Offline test: a tool's preview copy older than its last preview is not shipped at the click (0.7.6, G.takeToolCopy in
mpfever_bridge.script.lua, with "several players building without stopping").

The user's upgrade of 15 road segments on the dedicated server, 2026-11-07 20:32:29 (Knight-HD#2:57, NOSTOP on): a preview of
the upgrade tool took 13 ms to read, so none was read for a second (G.toolCreated); the copy of 55 frames before was taken and
shipped at the click while the last preview, 41 frames before, had not been read. The build came out otherwise than shipped
(15 segments shipped, 14 described after the build, in another order), the other games had built the copy: the host's game was
reloaded. The two builds shipped at the click before it took a copy of the last preview (1 and 36 frames, "the last preview 1
and 36 frames before") and were alike everywhere.
  - G.takeToolCopy (run here through lupa): a preview copy of the tool's last preview is taken; one older than the last preview
    is not (the build is held and shipped the usual way), and says so; a prepared copy (a construction tool's) is taken as before;
    MPFEVER_PRECREATESTALE=0: taken, as before.
Needs lupa (pip install lupa). Run: python tests/test_precreatestale076.py
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


src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^G\.takeToolCopy = function\(\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "G.takeToolCopy found")
if not m:
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
G = { frames = 1000 }
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
''' + m.group(0) + '''
function take(copyAge, at, lastAge)
  G.toolCopy = { frame = G.frames - copyAge, compact = { tag = "copy" }, at = at, tool = "streetTrackModifier" }
  G.lastCreate = lastAge and { frame = G.frames - lastAge, tool = "streetTrackModifier" } or nil
  local c = G.takeToolCopy()
  return c ~= nil, G.toolCopy == nil
end
''')
took, cleared = L.eval("take(36, 'create', 36)")
check(took and cleared, "the copy of the tool's last preview (36 frames before, 36 before: Knight-HD#2:55): taken")
check(L.eval("take(1, 'create', 1)")[0], "  (1 frame before, the last preview 1 before: Knight-HD#2:53)")
L.execute("LOGS = {}")
took, cleared = L.eval("take(55, 'create', 41)")
check(not took and cleared, "a copy older than the last preview (55 frames before, the last 41 before: Knight-HD#2:57): not taken")
check(L.eval("#LOGS") == 1 and "older than its last preview" in L.eval("LOGS[1]") and "the usual way" in L.eval("LOGS[1]"), "  and said")
check(L.eval("take(55, 'prepare', 41)")[0], "a prepared copy (a construction tool's): taken as before")
check(L.eval("take(30, 'create', nil)")[0], "no preview seen: taken as before")
check(not L.eval("take(200, 'create', 200)")[0], "a copy too old (over 120 frames): not taken, as before")
L.execute("ENV.MPFEVER_PRECREATESTALE = '0'")
check(L.eval("take(55, 'create', 41)")[0], "MPFEVER_PRECREATESTALE=0: taken, as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
