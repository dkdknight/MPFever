"""Offline test: the game's landmarks script is called with the steps only (0.8.3, #228, MPFEVER_LANDMARKDT0).

Report #228 (2026-11-11, dedicated server and Knight-HD, separate companies): Knight-HD built an arena (Knight-HD#2:99, t=78002600).
The game's landmarks script (base/content/landmarks/landmarks.script.tl) rebuilds a landmark at its level from its update, so the new
arena was rebuilt at once. The 0.8.2 drift diagnostic, step 390012: on the server, which replayed the build standing at its time, the
engine called that update with dt 0 and the rebuild went in the same step, outside the systems (-218815 +46661); on Knight-HD's game,
which did not stand, it went in step 390013's GameScriptSystem, after AnimalMoveSystem had taken the freed id 46661 (+220242). From
then on the free-id queues, the people and the towns differed (onboard, script:towns: resynchronisation 2).
The landmarks script's update is now called with the steps only (dt 0 skipped in a session), as the mods' scripts since 0.7.0.
The wrapper is taken from the real bridge and run through lupa (Lua 5.2).
Run: python tests/test_landmarkdt0083.py
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


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r'\n(\t\tif k == "::/landmarks/landmarks\.script".*?\n\t\tend\n)', src, re.S)
    if not m:
        print("FAIL: the landmarks wrapper not found in DET.wrapModEvents")
        return 1
    w = src[src.index("function DET.wrapModEvents()"):]
    w = w[:w.index("\nend\n")]
    check("in DET.wrapModEvents (every role, both company modes), MPFEVER_LANDMARKDT0=1: as before",
          m.group(1) in w and 'os.getenv("MPFEVER_LANDMARKDT0") ~= "1"' in m.group(1))

    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    run("""
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
SIM = {}
C = { ROLE = "client" }
CALLS = {}
game = { ["::/landmarks/landmarks.script"] = { update = function(u, st, dt) CALLS[#CALLS + 1] = dt end },
         ["::/towns/towns.script"] = { update = function(u, st, dt) CALLS[#CALLS + 1] = "towns" end } }
WRAP = function()
  for k, v in pairs(game) do
""" + m.group(1) + """
  end
end
""")
    run("WRAP(); WRAP()")
    run("game['::/landmarks/landmarks.script'].update(nil, nil, 0)")
    check("in a session, a call with dt 0 (a game standing between steps): skipped, counted",
          run("return #CALLS") == 0 and run("return SIM.lmDt0") == 1)
    run("game['::/landmarks/landmarks.script'].update(nil, nil, 0.2)")
    check("a step's call (dt 0.2): the game's update, once (wrapped once)", run("return #CALLS") == 1 and run("return CALLS[1]") == 0.2)
    run("game['::/towns/towns.script'].update(nil, nil, 0)")
    check("the game's other scripts: left as they are", run("return CALLS[2]") == "towns")
    run("C.ROLE = 'solo'; game['::/landmarks/landmarks.script'].update(nil, nil, 0)")
    check("alone (no session): every call, as the game does", run("return CALLS[3]") == 0)
    check("logged once", sum(1 for i in range(1, 10) if "landmarks script" in str(run(f"return LOG[{i}]"))) == 1)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
