"""Offline test (0.8.9, #305): the host's game that could not reproduce the edit of a construction (its stops or signals on its own
tracks not replayed) leaves out that player's next edits of constructions until the resynchronisation (G.brokenSkip, replayFailed
in mpfever_bridge.script.lua).

seaso (host) and Brumaren, 2026-11-14 15:49: Brumaren#1:5, an edit of a modular station, was rebuilt on the host without the 7
stops and signals on the station's own tracks ("resynchronisation" asked for); Brumaren#1:6, the next edit of the same station,
was applied on that state 3 s later and the host's game crashed ('it != components.end()', GetComponentDataIndex, entity 159867).
  - replayFailed on the host with "construction edge objects" marks G.hostBroken (the uid, its builder); other reasons do not;
    a player's game is unchanged (G.replayBroken, issue #113); MPFEVER_HOSTFAILHOLD=0: nothing marked;
  - G.brokenSkip on the host: the same player's native build that adds or removes constructions is left out (true), said in the
    log, told to the launcher (replay_failed) and in the chat; a street of the same player, another player's edit: applied;
  - after G.BROKEN_HOLD seconds, or when the build turns out refused everywhere (replay_alike): applied again.
Run: python tests/test_hostfailhold089.py
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
    m1 = re.search(r"^local function replayFailed\(a, why\)\n.*?^end\n", src, re.S | re.M)
    m2 = re.search(r"^function G\.brokenSkip\(a\)\n.*?^end\n", src, re.S | re.M)
    m3 = re.search(r"^H\.replay_alike = function\(from, p\)\n(.*?)\n", src, re.S | re.M)
    check(m1 is not None and m2 is not None and m3 is not None, "replayFailed, G.brokenSkip, H.replay_alike found")
    if not (m1 and m2 and m3):
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r"""
G = { BROKEN_HOLD = 45 }
H = {}
C = { ROLE = "host", Tf = function(fr, en, ...) return string.format(en, ...) end }
ENV = {}
CLOCK = 100
SENT = {}
SAID = {}
LOGS = {}
os = { getenv = function(k) return ENV[k] end, clock = function() return CLOCK end }
function log(t) LOGS[#LOGS + 1] = t end
function send(kind, p) SENT[#SENT + 1] = kind end
G.coSay = function(t) SAID[#SAID + 1] = t end
""" + m1.group(0).replace("local function replayFailed", "function replayFailed") + m2.group(0) + r"""
function edit(origin, uid, cons) return { origin = origin, uid = uid, native = true, args = { { toRemove = cons and { 5 } or {}, toAdd = {} } } } end
""")
    g = L.globals()
    rf = L.eval("replayFailed")
    skip = L.eval("G.brokenSkip")
    edit = L.eval("edit")

    rf(edit("Brumaren#1", "Brumaren#1:5", True), "construction edge objects (airport signs)")
    hb = g.G.hostBroken
    check(hb is not None and hb.uid == "Brumaren#1:5" and hb.origin == "Brumaren#1", "host: a construction's edge objects not replayed marks the game (uid, builder)")
    check(g.G.replayBroken is None, "  (the players' mark, G.replayBroken, unchanged on the host)")
    n0 = len(list(g.SENT.values()))
    check(skip(edit("Brumaren#1", "Brumaren#1:6", True)) is True, "the same player's next construction edit: left out")
    check(len(list(g.SENT.values())) == n0 + 1 and list(g.SENT.values())[-1] == "replay_failed", "  told to the launcher (replay_failed)")
    check(len(list(g.SAID.values())) == 1 and "make it again" in list(g.SAID.values())[0], "  and in the chat (make it again)")
    check(skip(edit("Brumaren#1", "Brumaren#1:7", False)) is False, "the same player's street (no construction): applied")
    check(skip(edit("seaso", "seaso:9", True)) is False, "another player's construction edit: applied")
    g.CLOCK = 100 + 46
    check(skip(edit("Brumaren#1", "Brumaren#1:8", True)) is False and g.G.hostBroken is None, "after G.BROKEN_HOLD seconds: applied again")

    g.CLOCK = 200
    g.G.hostBroken = None
    rf(edit("Brumaren#1", "Brumaren#1:10", True), "native construction refused x")
    check(g.G.hostBroken is None, "another reason of failure: nothing marked")
    g.ENV.MPFEVER_HOSTFAILHOLD = "0"
    rf(edit("Brumaren#1", "Brumaren#1:11", True), "construction edge objects (airport signs)")
    check(g.G.hostBroken is None, "MPFEVER_HOSTFAILHOLD=0: nothing marked")
    g.ENV.MPFEVER_HOSTFAILHOLD = None
    g.C.ROLE = "client"
    rf(edit("Brumaren#1", "Brumaren#1:12", True), "construction edge objects (airport signs)")
    check(g.G.hostBroken is None and g.G.replayBroken is not None, "a player's game: G.replayBroken as before (#113), not G.hostBroken")

    check("if G.hostBroken and type(p) == \"table\" and tostring(p.uid) == G.hostBroken.uid then G.hostBroken = nil end" in m3.group(1),
          "refused on every game (replay_alike): the mark is dropped")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
