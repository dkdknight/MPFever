"""Offline test: with "several players building without stopping" (MPFEVER_NOSTOP), a stop or a signal is no longer shipped
at the click (0.7.5, G.preship in mpfever_bridge.script.lua).

AMD (host) and keviK, 2026-11-07 14:12-14:21, 0.7.4 with NOSTOP on: every bus stop of keviK's that went to the host as the
tool's copy at the click ("a copy shipped at the click, applied as the tool made it") was rebuilt there as a street proposal:
the segment replaced, its stop lost (keviK#7:3, :13, :15, :19 ...: "stops 1" in its shape, no stop built), while every stop
replayed from a capture ("stop on segment ...: BUILT") was there. The host had fewer edge objects and stations, every line of
keviK's through those stops was refused there ("DESYNC unresolved: sg#..."), 6 reloads in 10 minutes.
  - G.preHasObjects (run here through lupa): a copy that adds or removes edge objects (a stop, a signal) has some; a plain
    street or a segment's removal has none; nothing readable: none;
  - G.preship ships such a build the usual way (before anything is translated or sent), MPFEVER_PRESHIPOBJ=1: as 0.7.4;
  - a copy with stops or signals that comes anyway is replayed as a capture, not applied as a street proposal.
Run: python tests/test_preshipstops075.py
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


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"^G\.preHasObjects = function\(m\)\n.*?^end\n", src, re.S | re.M)
    check(m is not None, "G.preHasObjects found")
    if not m:
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("G = {}\n" + m.group(0))
    has = L.eval("function(code) return G.preHasObjects(assert(load('return ' .. code))()) end")
    check(has("{ proposal = { addedSegments = { {}, }, removedSegments = { {} }, edgeObjectsToAdd = { { model = 'bus_stop' } } } }"), "a bus stop on a replaced segment: edge objects")
    check(has("{ streetProposal = { edgeObjectsToAdd = { {} } } }"), "  (in a streetProposal too)")
    check(has("{ proposal = { edgeObjectsToRemove = { 5 } } }"), "a stop removed: edge objects")
    check(not has("{ proposal = { addedSegments = { {} }, addedNodes = { {} } } }"), "a plain street: none")
    check(not has("{ proposal = { removedSegments = { {} } } }"), "a segment removed: none")
    check(not has("{}") and not has("'x'") and not has("{ proposal = 'x' }"), "nothing readable: none")

    i = src.find("G.preship = function(r)")
    body = src[i:i + 3000]
    a = body.find("if not G.preHasContent(r.copy) then")
    b = body.find('if G.preHasObjects(r.copy) and os.getenv("MPFEVER_PRESHIPOBJ") ~= "1" then')
    c = body.find("R.translateOut(")
    check(0 < a < b < c, "G.preship: a stop or a signal shipped the usual way, before anything is translated or sent")
    check("return false" in body[b:b + 200], "  (false: held and shipped the usual way)")
    j = src.find("local preCon = a.pre and type(a.args[1]) == \"table\"")
    rp = src[j:j + 1400]
    k = rp.find('if a.pre and not preCon and G.preHasObjects(a.args[1]) and os.getenv("MPFEVER_PRESHIPOBJ") ~= "1" then')
    r = rp.find('if a.pre and not preCon and os.getenv("MPFEVER_PRERAW") ~= "0" then')
    check(0 < k < r and "preCon = true" in rp[k:r], "a copy with stops or signals that comes anyway: replayed as a capture, not as a street proposal")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
