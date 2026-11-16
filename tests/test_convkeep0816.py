"""Offline test (0.8.16): the dry run's result of a native construction replay is kept referenced (G.convKeep).

Chain h7ec (a station edited with a signal on its own new track): the same build, at the same step, was refused once
("Unknown exception" making the command with its edge object) and built in two reruns. The edge objects handed to the
command are the engine's own objects inside the dry run's edge object list, a temporary that Lua could collect first.
Now:
  - right after `local conv = res.proposal`, G.convKeep holds the result, the proposal, its edge object list and toAdd
    (each read in a pcall), until the next replay replaces it; MPFEVER_CONVKEEP=0: not kept, as before;
  - MPFEVER_GCSTRESS=1 (tests only) makes garbage before the command, logged, so that Lua collects there.
Needs lupa. Run: python tests/test_convkeep0816.py
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


m = re.search(r"\t\tlocal conv = res\.proposal\n.*?\n(\t\tif os\.getenv\(\"MPFEVER_CONVKEEP\"\) ~= \"0\" then\n.*?\n\t\tend)\n", src, re.S)
check(m is not None, "G.convKeep block right after the dry run's proposal is read")
i_keep = src.find('os.getenv("MPFEVER_CONVKEEP")')
i_eo = src.find("local eo = conv.proposal.edgeObjectsToAdd")
check(0 < i_keep < i_eo, "  kept before the edge objects are taken from it")
i_gc = src.find('os.getenv("MPFEVER_GCSTRESS") == "1"')
i_cmd = src.find("local okw, PW = pcall(C.rebuildNativeWithConstruction")
check(0 < i_gc < i_cmd, "MPFEVER_GCSTRESS garbage made before the command with edge objects")
check("garbage made before the command (MPFEVER_GCSTRESS)" in src, "  and logged")

if m:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
G = {}
ENV = {}
os = { getenv = function(k) return ENV[k] end }
function run(res)
  G.convKeep = nil
  local conv = res.proposal
""" + m.group(1) + """
  return G.convKeep
end
""")
    lua = L.globals()
    same = L.eval("function(a, b) return rawequal(a, b) end")
    eo = L.eval("{ 'sign' }")
    p = L.table_from({"edgeObjectsToAdd": eo})
    ta = L.eval("{ 'con' }")
    conv = L.table_from({"proposal": p, "toAdd": ta})
    res = L.table_from({"proposal": conv})
    k = lua.run(res)
    check(k is not None and same(k["res"], res) and same(k["conv"], conv), "result and proposal kept")
    check(k is not None and same(k["p"], p) and same(k["eo"], eo) and same(k["ta"], ta), "inner proposal, edge object list and toAdd kept")
    # a conversion without an inner proposal: the reads fail in their pcall, the rest is still kept
    conv2 = L.eval("setmetatable({}, { __index = function(t, k) error('no member ' .. k) end })")
    res2 = L.table_from({"proposal": conv2})
    k2 = lua.run(res2)
    check(k2 is not None and same(k2["conv"], conv2) and k2["eo"] is None, "missing members: no error, the conversion still kept")
    lua.ENV["MPFEVER_CONVKEEP"] = "0"
    check(lua.run(res) is None, "MPFEVER_CONVKEEP=0: not kept")

print("ALL OK" if not fails else "%d FAILED" % len(fails))
sys.exit(1 if fails else 0)
