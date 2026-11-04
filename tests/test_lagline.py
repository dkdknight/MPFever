"""Offline test of the lag line (0.6.12): one "LAG ..." line per build of another player replayed here, with how long this
game stood at the build's time (waiting for its data, then for its replay), the commands it took and the data's size. It is
the measure of the freezes the players feel on big stations (the user's test of 2026-11-03 23:17). MPFEVER_LAGLINE=0: none.

G.lagStart, G.lagCommand and G.lagLine are run through lupa (Lua 5.2) with a mocked clock and frames.
Run: python tests/test_lagline.py
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
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^G\.lagStart = function\(a\)\n.*?^G\.lagLine = function\(\)\n.*?^end\n", src, re.S | re.M)
    check("G.lagStart .. G.lagLine found", m is not None)
    if not m:
        return 1
    check("started at REPLAY SEND, counted per command, checked every frame",
          "pcall(G.lagStart, a)\n\t\t\t\tokr, errr = pcall(withActor, PL(a), replayNative, a, 1)" in src
          and "if G.lagCommand then pcall(G.lagCommand) end" in src and "if G.lagCur then pcall(G.lagLine) end" in src)
    check("the wait records when this game came to the build's time and when its data came",
          "if okN and not w.reachedT and type(w.at) == \"number\" and nowN >= w.at then w.reachedT = os.clock() end" in src
          and "w.gotT = w.gotT or os.clock()" in src)
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {} os.getenv = function(k) return ENV[k] end
NOW = 10 os.clock = function() return NOW end
LOG = {} log = function(s) LOG[#LOG + 1] = s end
G = { frames = 100, replayOut = 0 }
matchesWait = function(w, a) return w.origin == a.origin and w.at == a.at end
""" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    got = run("""
      local a = { uid = "Dimi:102", origin = "Dimi", at = 500, lagBytes = 2295081 }
      G.lagW = { origin = "Dimi", at = 500, sinceT = 8.0, reachedT = 9.0, gotT = 11.5 }
      NOW = 12.0
      G.lagStart(a)
      G.replayOut = 1; G.lagCommand(); G.lagLine()            -- the conversion command at the engine
      NOW = 12.4; G.replayOut = 0; G.frames = 110; G.lagLine()  -- answered
      G.replayOut = 1; G.lagCommand(); G.frames = 112; G.lagLine()   -- the real command
      NOW = 13.5; G.replayOut = 0; G.frames = 120; G.lagLine()
      for f = 121, 129 do G.frames = f; G.lagLine() end
      local n0 = #LOG
      G.frames = 131; G.lagLine()
      return n0 .. "|" .. tostring(LOG[#LOG])""")
    n0, line = got.split("|", 1)
    check("nothing before 10 quiet frames after the last command", n0 == "0", got)
    check("one line: stood 4500 ms (data 2500 ms, replay 1500 ms, 2 commands, its size)",
          "LAG Dimi:102 for t=500: this game stood 4500 ms at its time (2500 ms for its data, 500 ms before its replay, 1500 ms of replay, 2 command(s)); data 3500 ms after its announce, 2295081 bytes" in line, line)
    got = run("""G.frames = 200; G.lagLine(); return tostring(G.lagCur) .. " " .. #LOG""")
    check("once", got == "nil 1", got)
    got = run("""ENV.MPFEVER_LAGLINE = "0"; G.lagStart({ uid = "x", at = 1 }); return tostring(G.lagCur)""")
    check("MPFEVER_LAGLINE=0: none", got == "nil", got)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
