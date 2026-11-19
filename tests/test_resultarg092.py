"""Offline test: the entities a build made are read from its callback's third argument (0.9.2, MPFEVER_RESULTARG; G.madeEntities
in mod/mpfever_1/content/mpfever_bridge.script.lua).

Build 40444 (2026-11-19) changed WorldBuildProposalCommandData.resultEntities (api/tealdef/api/cmd.d.tl): {entity, revision}
pairs in 40425, plain entities in 40444, the constructions added only; the pairs of everything made now come as the callback's
third argument (both builds). The asset replay's check (the removed tree groups gone, the ids taken again by the new trees) and
the autotests' lists read resultEntities: on 40444 they saw no tree made. G.madeEntities reads the third argument first, else
resultEntities in either shape.
The function is run through lupa (Lua 5.2), cut out of the bridge's source.
Run: python tests/test_resultarg092.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


i = SRC.index("G.madeEntities = function(res, ear)")
fn = SRC[i:SRC.index("\nend\n", i) + 5]


def lua(env=None):
    if env is None:
        os.environ.pop("MPFEVER_RESULTARG", None)
    else:
        os.environ["MPFEVER_RESULTARG"] = env
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run("G = {}\n" + fn)
    return run


def made(run, res, ear):
    return list(run(f"local t = G.madeEntities({res}, {ear}) local s = {{}} for i, e in ipairs(t) do s[i] = e end return table.concat(s, ',')").split(",")) if run(f"return #G.madeEntities({res}, {ear})") > 0 else []


R40425 = "{ resultEntities = { { 501, 1 }, { 502, 1 } } }"
R40444 = "{ resultEntities = {} }"          # trees: no construction added
EAR = "{ { 501, 1 }, { 502, 1 } }"

run = lua("0")
check("the bug (40444, MPFEVER_RESULTARG=0: resultEntities only): the trees made are not seen", made(run, R40444, EAR) == [])
run = lua()
check("the fix: read from the callback's third argument", made(run, R40444, EAR) == ["501", "502"], made(run, R40444, EAR))
check("  40425's pairs in resultEntities, no third argument: as before", made(run, R40425, "nil") == ["501", "502"])
check("  40444's plain entities in resultEntities: read too", made(run, "{ resultEntities = { 601, 602 } }", "nil") == ["601", "602"])
check("  nothing at all: an empty list", made(run, "nil", "nil") == [])
check("the three readers use it", SRC.count("G.madeEntities(res, ear)") == 3 and "replaySend(cmd, function(res, success, ear)" in SRC
      and "built(res, success, ear)" in SRC)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
