"""Offline test (0.8.17, speed): the look at the other companies' open tracks is skipped while nothing was built
(G.openNetSkip / G.openNet in mpfever_bridge.script.lua, switch MPFEVER_OPENNETSKIP).

The look (G.openTracks: the street graph's map of nodes to segments, every segment) ran every 300 frames on the interface's
thread: 30 to 40 ms on Andy's and berni1212's map (6 444 segments, up to 114 ms in the reports of 2026-11-16), a hitch every 5 s,
though its list only changes with a build or the companies' rules. G.openNetSkip is run through lupa:
  - MPFEVER_OPENNETSKIP=0: never skipped (a look every 300 frames, as before);
  - now: the first look made; then skipped while the simulation's count of builds and the open companies stay the same;
  - a build (n0 + #list grows), another open company, or 1800 frames since the last whole look: looked at again;
  - G.openNet calls it before any look, and only with the track rule of 0.6 (MPFEVER_TRACKTYPE).
Needs lupa. Run: python tests/test_opennetskip0817.py
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


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r"^G\.openNetSkip = function\(me, sig\)\n.*?^end\n", src, re.S | re.M)
check("G.openNetSkip found", m is not None)
if not m:
    sys.exit(1)
on = src[src.index("G.openNet = function(reg, me)"):]
on = on[:on.index("\nend\n")]
check("G.openNet asks it before any look, with the track rule of 0.6",
      on.index('if os.getenv("MPFEVER_TRACKTYPE") ~= "0" and G.openNetSkip(me, sig) then return end') < on.index("G.openTracks(open, sig, me, add, roads)"))


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = { frames = 1000 }\n" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_OPENNETSKIP = '0'")
    run("ME = { id = 2 }; SIG = { 46534 }; G.simBuildIds = { n0 = 40, list = { { at = 1 }, { at = 2 } } }")
    return run


def look(run):
    # what G.openNet does after a look that went through: the key kept, its text set; G.openTracks sets openNetFull at a whole look
    run("G.openNetSkipKey, G.openNetSkipNext = G.openNetSkipNext, nil")
    run("G.openNetTxt = G.openNetTxt or ''; if G.openNetFull == nil or G.frames - G.openNetFull >= 1800 then G.openNetFull = G.frames end")


run = runtime(off=True)
seq = []
for k in range(4):
    sk = run("return G.openNetSkip(ME, SIG)")
    seq.append(sk)
    if not sk:
        look(run)
    run("G.frames = G.frames + 300")
check("MPFEVER_OPENNETSKIP=0: a look every time (as before)", seq == [False] * 4, seq)

run = runtime()
seq = []
for k in range(4):
    sk = run("return G.openNetSkip(ME, SIG)")
    seq.append(sk)
    if not sk:
        look(run)
    run("G.frames = G.frames + 300")
check("now: the first look made, then skipped while nothing changes", seq == [False, True, True, True], seq)
run("G.simBuildIds.list[#G.simBuildIds.list + 1] = { at = 3 }")
check("a build: looked at again", run("return G.openNetSkip(ME, SIG)") is False)
look(run)
check("  then skipped again", run("return G.openNetSkip(ME, SIG)") is True)
run("G.simBuildIds.n0 = G.simBuildIds.n0 + 1; table.remove(G.simBuildIds.list, 1)")
check("old builds folded into n0 (the same count): still skipped", run("return G.openNetSkip(ME, SIG)") is True)
check("another open company: looked at again", run("return G.openNetSkip(ME, { 46534, 31434 })") is False)
run("G.frames = G.frames + 1800")
check("1800 frames since the last whole look (a sale, a merger): looked at again", run("return G.openNetSkip(ME, { 46534, 31434 })") is False)
# (the review) a look that failed (G.openNet stopped by an error before the end) is made again at the next turn
run = runtime()
check("(review) the first look", run("return G.openNetSkip(ME, SIG)") is False)
run("G.openNetTxt = ''; G.openNetFull = G.frames")   # the look failed after G.openTracks: the key is not kept
run("G.frames = G.frames + 300")
check("(review) a look that failed is made again", run("return G.openNetSkip(ME, SIG)") is False)
check("G.openNet keeps the key only after its look went through", on.index("G.openNetSkipKey, G.openNetSkipNext = G.openNetSkipNext, nil") > on.index("G.openTracks(open, sig, me, add, roads)")
      and on.index("G.openNetSkipKey, G.openNetSkipNext = G.openNetSkipNext, nil") < on.index("table.sort(ids)"))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
