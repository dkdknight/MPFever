"""Offline test: the railroad crossing's and the signal's window builds of Transport Fever 3's build 40444 are refused in a
session, the player told (0.9.2, MPFEVER_WINPROPOSAL; mod/mpfever_1/content/mpfever_ui.script.lua).

The bug (autotest rcsig, 2026-11-19, two games on 40444, "TEST Game Knight 18-2"): in 40444 those windows are game scripts that
make their proposal with api.engine.util.proposal.makeRailroadCrossingProposal / makeSignalTypeProposal and send it with
makeWorldBuildProposalCmd. MPFever held and shipped them as any build and every game rebuilt them: the crossing's new type
(the proposal's node2rcType) was not rebuilt, so nothing changed ("asked: crossing type 0 ... after: crossing type 3"), and the
signal's new edge object had no model ("edge object 1 without model (not replicated)"): its replacement removed the old signal
and added none, on every game. Both games stayed in sync.
The fix (until each game makes those proposals itself): the two functions are wrapped in the interface's state, the proposals
they make are marked (a weak table), and a world build of a marked proposal is refused in a session, its window answered
"not done", the player told on the chat's notice. MPFEVER_WINPROPOSAL=1: shipped as any build.
The autotest rcsig shows it in a game (the crossing's type and the signal kept, both answers false).
Run: python tests/test_winproposal092.py
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
ui = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
lang = json.loads(open(os.path.join(ROOT, "launcher", "lang.json"), encoding="utf-8-sig").read())["texts"]
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


w = ui[ui.index("U.winProps = setmetatable({}, { __mode = \"k\" })"):]
w = w[:w.index("-- (0.7.0) the debug factories are tagged too")]
check('if os.getenv("MPFEVER_WINPROPOSAL") ~= "1" then' in w, "MPFEVER_WINPROPOSAL=1: nothing marked (shipped as any build)")
check('{ "makeRailroadCrossingProposal", "crossing" }, { "makeSignalTypeProposal", "signal" }' in w, "the two functions of 40444's windows")
# (0.9.4: marked with what they were made from, { what, ent, v }: shipped and made again by every game, tests/test_winreplay094.py;
# refused as here with MPFEVER_WINREPLAY=0)
check("local p = fn(...)" in w and "U.winProps[p] = { what = pair[2]" in w and "return p" in w, "  their proposals marked, returned unchanged")
check(w.count("pcall(") >= 3, "  every step guarded (40425 has no such functions)")
g = ui[ui.index("-- (0.9.2) a railroad crossing's or a signal's window build (see U.winProps)"):]
g = g[:g.index("-- notification events (popup sound, dismiss)")]
check('tag.name == "makeWorldBuildProposalCmd" and tag.args[1] ~= nil' in g and "U.winProps[tag.args[1]]" in g,
      "a world build of a marked proposal is recognised")
check("if cb then pcall(cb, nil, false, {}) end" in g and re.search(r"\n\t\t\t\treturn\n", g) is not None,
      "  refused: its window answered 'not done', nothing shipped nor applied")
check("U.onChatNews" in g, "  the player told on the chat's notice")
i_g = ui.index("-- (0.9.2) a railroad crossing's or a signal's window build")
i_m = ui.index("local okm, margs = pcall(function()")
check(i_g < i_m, "  before the command is marshalled and shipped")
for t in ("A level crossing's type cannot be changed in multiplayer yet.",
          "A signal cannot be made one-way from its window in multiplayer yet: use the signal tool."):
    check(t in g and t in lang and len(lang[t]) >= 11, "  told in every language: " + t[:40])

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
