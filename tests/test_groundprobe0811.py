"""Offline test (0.8.11, #150): the ground probe is on by default, without the trees, on the builder's game and every replay.

The drift between two PCs now begins with the animals, whose way depends on the terrain's height, and the checks never compare the
ground. G.groundProbe logs "GROUND <uid> <builder|replay>: ..." 30 frames after a build stands; tools/ground_diff.py compares every
player's lines of a report.
  - MPFEVER_GROUNDPROBE unset: heights only; =1: with the trees as in 0.8.9; =0: none;
  - the builder's probe for a build shipped the usual way too (not only the copies shipped at the click), once;
  - tools/ground_diff.py finds a build whose signature differs between two games.
Run: python tests/test_groundprobe0811.py
"""
import os, sys, tempfile, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


g = src.find("G.groundProbe = function(m, uid, who)")
body = src[g:src.find("\nend\n", g)]
check(g > 0, "G.groundProbe found")
check('if mode == "0" or type(m) ~= "table" then return end' in body, "on unless MPFEVER_GROUNDPROBE=0")
check('if mode == "1" then pcall(function()' in body, "the trees only with MPFEVER_GROUNDPROBE=1")
check('"GROUND %s %s: %d points, sum %.4f, signature %d"' in body, "the GROUND line ground_diff.py reads")
check('if not preDone and a.post == nil then pcall(G.groundProbe' in src, "the builder's probe for a build shipped the usual way, once")
check('pcall(G.groundProbe, a.args and a.args[1], a.uid, "replay")' in src, "the replays' probe")
for what in ('" native construction BUILT")', '" native street BUILT (" .. label .. ")")', '" BUILT with form " .. label)'):
    check((what + '; pcall(G.groundProbe, a.args and a.args[1], a.uid, "replay")') in src, "  also after" + what.split('"')[1])

tool = os.path.join(HERE, "..", "tools", "ground_diff.py")
with tempfile.TemporaryDirectory() as d:
    for game, sig in (("a", 111), ("b", 111), ("c", 222)):
        os.makedirs(os.path.join(d, game))
        with open(os.path.join(d, game, "mod.log"), "w", encoding="utf-8") as f:
            f.write("10:00:00 GROUND x:1 %s: 105 points, sum 12.5000, signature 7\n" % ("builder" if game == "a" else "replay"))
            f.write("10:00:01 GROUND x:2 %s: 105 points, sum 13.0000, signature %d\n" % ("builder" if game == "a" else "replay", sig))
    r = subprocess.run([sys.executable, "-I", tool, d], capture_output=True, text=True)
    check(r.returncode == 1 and "GROUND DIFFERS for build x:2" in r.stdout and "x:1" not in r.stdout.split("GROUND DIFFERS")[1], "ground_diff: x:2 differs on one game, x:1 alike")
    check("2 build(s) seen on two games or more, 1 with another ground" in r.stdout, "ground_diff: the summary")
    # (two session folders given, each with its mod.log at its top: both counted)
    r2 = subprocess.run([sys.executable, "-I", tool, os.path.join(d, "a"), os.path.join(d, "c")], capture_output=True, text=True)
    check("2 build(s) seen on two games or more, 1 with another ground" in r2.stdout, "ground_diff: two session folders given")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
