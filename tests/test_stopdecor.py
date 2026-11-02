"""Offline test of what a script's stop keeps of its street segment (0.6.9, C.keepSegmentLook in mpfever_common.lua).

Tests fz1, fz2 and fe2/fe3 of 2026-11-02 (one company per player, Test Gameplay): a stop put by a script (the dstop scenario,
and the computer companies' stops, made the same way) on a town street with trees: the builder's game had the copy of the
segment without its trees, the other game, replaying the stop as the stop tool's build, with both rows (segment 35306,
decorations 0 against 0l,0r): "edges" apart, then the towns, many reloads. The copy now keeps the decorations and a track's
distance, as replayStop does. C.keepSegmentLook is taken from the real file and run through lupa (Lua 5.2). Cases:
  - decorations kept as they are; turned round, each side flipped (a side counts from the first node);
  - no decoration: none written; a track's distance kept, a street's 0 not written;
  - MPFEVER_STOPDECOR=0: nothing kept, as before;
  - the computer companies' stops and the dstop scenario call it.
Run: python tests/test_stopdecor.py
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


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read()
    m = re.search(r"^function C\.keepSegmentLook\(cc, c, rev\)\n.*?^end\n", common, re.S | re.M)
    if not m:
        print("FAIL: C.keepSegmentLook not found")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nC = {}\n" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")

    out = run("local cc = {}; C.keepSegmentLook(cc, { distance = 0, edgeDecorations = { { 3, true }, { 3, false } } }, false); "
              "return cc.edgeDecorations[1][2] == true and cc.edgeDecorations[2][2] == false and cc.distance == nil")
    check("decorations kept as they are, a street's 0 distance not written", out is True)
    out = run("local cc = {}; C.keepSegmentLook(cc, { distance = 0, edgeDecorations = { { 3, true }, { 4, false } } }, true); "
              "return cc.edgeDecorations[1][1] == 3 and cc.edgeDecorations[1][2] == false and cc.edgeDecorations[2][2] == true")
    check("turned round: each side flipped", out is True)
    out = run("local cc = {}; C.keepSegmentLook(cc, { distance = 5, edgeDecorations = {} }, false); return cc.edgeDecorations == nil and cc.distance == 5")
    check("no decoration: none written; a track's distance kept", out is True)
    out = run("ENV.MPFEVER_STOPDECOR = '0'; local cc = {}; C.keepSegmentLook(cc, { distance = 5, edgeDecorations = { { 3, true } } }, false); "
              "ENV.MPFEVER_STOPDECOR = nil; return next(cc) == nil")
    check("MPFEVER_STOPDECOR=0: nothing kept, as before", out is True)

    ai = open(os.path.join(CONTENT, "mpfever_ai.lua"), encoding="utf-8").read()
    i = ai.find("local function buildStop(")
    bs = ai[i:ai.find("\nend\n", i)]
    check("the computer companies' stops keep the look", "C.keepSegmentLook(cc, c, false)" in bs)
    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
    i = bridge.find("H.dstop = function")
    ds = bridge[i:bridge.find("\nend\n", i)]
    check("the dstop scenario too (turned round with MPFEVER_DSTOPREVERSE)", "C.keepSegmentLook(cc, c, rev)" in ds)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
