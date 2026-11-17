"""Offline test (0.8.17, #405): a construction tool's prepared copy older than its last preview is not shipped at the click
(G.takeToolCopy in mpfever_bridge.script.lua, switch MPFEVER_PREPARESTALE).

Flubi's station edit (modular_terminal.con, 2026-11-16 21:02): the copy was the tool's "prepare" of 110 frames before the build,
while a newer preview was 96 frames before (the player had moved the tool). The build had 1 new street piece, the copy 2: "built
otherwise than shipped at the click", every game reloaded. The 0.7.6 rule left out only older preview ("create") copies.
In the reports of 2026-11-16, 1 prepared copy of 185 had a newer preview: this one.
G.takeToolCopy is taken from the real bridge and run through lupa:
  - MPFEVER_PREPARESTALE=0: the prepared copy of 110 frames before, the last preview 96 before: taken (the bug, reproduced);
  - now: not taken (the build is held and shipped the usual way), and said;
  - a prepared copy after the last preview (the usual case, 184 of 185): taken as before.
Needs lupa. Run: python tests/test_preparestale0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m = re.search(r"^G\.takeToolCopy = function\(\)\n.*?^end\n", src, re.S | re.M)
check(m is not None, "G.takeToolCopy found")
if not m:
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
G = { frames = 30000 }
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(s) LOGS[#LOGS + 1] = s end
''' + m.group(0) + '''
function take(copyAge, at, lastAge)
  G.toolCopy = { frame = G.frames - copyAge, compact = { tag = "copy" }, at = at, tool = "constructionBuilder" }
  G.lastCreate = lastAge and { frame = G.frames - lastAge, tool = "constructionBuilder" } or nil
  return G.takeToolCopy() ~= nil
end
''')
L.execute("ENV.MPFEVER_PREPARESTALE = '0'")
check(L.eval("take(110, 'prepare', 96)"), "MPFEVER_PREPARESTALE=0: Flubi's prepared copy (110 frames, a preview 96 frames before) taken (the bug)")
L.execute("ENV.MPFEVER_PREPARESTALE = nil; LOGS = {}")
check(not L.eval("take(110, 'prepare', 96)"), "now: not taken, the build shipped the usual way")
check("older than its last preview" in (L.eval("LOGS[1]") or ""), "  and said")
check(L.eval("take(6, 'prepare', 40)"), "a prepared copy after the last preview (the usual case): taken")
check(L.eval("take(6, 'prepare', 6)"), "  the same frame: taken")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
