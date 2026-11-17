"""Offline test (0.8.17, #397 #398): the map's count after a replay is compared only when no other build went to the engine since
(G.countSince / G.countLine and the four counts in mpfever_bridge.script.lua, switch MPFEVER_COUNTGUARD).

"SEGMENT COUNT DIFFERS" came for berni1212#3:4 (1/0), #3:5 (0/6), #3:6 (0/-6) during a quick run of station edits, and for
Andy#1:69 (3/0, berni1212#3:62's 3 segments counted with it): the count is read a few frames after the replay, and the next build
applied meanwhile was counted too. None was followed by a drift; and a native construction's count of edge objects asks for a
resynchronisation (an airport's signs), which such a count could ask for nothing.
  - G.countLine (run through lupa): the same count: nothing; another count, no build since: "SEGMENT COUNT DIFFERS"; another
    build sent since: "not compared"; MPFEVER_COUNTGUARD=0: compared always (the false alarm, reproduced);
  - the four counts of the bridge use it, and the edge objects' resynchronisation only when nothing went since.
Needs lupa. Run: python tests/test_countguard0817.py
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


m = re.search(r"^G\.countSince = function\(since\)\n.*?^G\.countLine = function\(uid, got, expected, since\)\n.*?^end\n", src, re.S | re.M)
check("G.countSince and G.countLine found", m is not None)
if not m:
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nG = { worldFrame = 1000 }\n" + m.group(0))
run = L.eval("function(code) return assert(load(code))() end")
check("the same count: nothing said", run("return G.countLine('x', 2, 2, 1000)") == "")
check("another count, no build since the replay: SEGMENT COUNT DIFFERS", run("return G.countLine('x', 3, 2, 1000)") == " SEGMENT COUNT DIFFERS")
run("G.worldFrame = 1004")
check("another build sent since (berni1212#3:62 counted with Andy#1:69): not compared", "not compared" in run("return G.countLine('Andy#1:69', 3, 0, 1000)"))
run("ENV.MPFEVER_COUNTGUARD = '0'")
check("MPFEVER_COUNTGUARD=0: compared always (the false alarm)", run("return G.countLine('Andy#1:69', 3, 0, 1000)") == " SEGMENT COUNT DIFFERS")
check("the four counts use the guard", src.count("G.countLine(a.uid, got, expected, since") == 3 and "G.countSince(since) and \" SEGMENT COUNT DIFFERS\"" in src)
check("no unguarded count left", src.count('(got == expected and "" or " SEGMENT COUNT DIFFERS")') == 0)
check("a native construction's edge objects: the resynchronisation asked as before (the review: it guards the host, #305)",
      "if withObjects and objs - objsBefore ~= objExpected then replayFailed(a, \"construction edge objects differ\") end" in src)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
