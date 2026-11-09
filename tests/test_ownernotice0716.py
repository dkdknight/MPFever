"""Offline test: a player whose command touched another company's vehicle, line, depot or station is told why it did nothing
(0.7.16, issue #181; U.ownerRefusedText in mpfever_ui.script.lua).

#181 (one company per player, 2026-11-09 17:32): the host recoloured Simon's vehicle three times in 17 s; the owner guard refused
each on every game ("it belongs to company 2 (Firma Simon)"), as it must, and nothing was said to the player.
  - U.ownerRefusedText, run through lupa: one chat notice item naming the company ("Refused: it belongs to another company
    (Firma Simon)."), "#2" without a name, a long name cut at 24 characters at a character's start; nothing for a success, for
    another refusal (the engine's, a desync, a game option) or with MPFEVER_OWNERNOTICE=0;
  - pollResults shows it for this player's own commands' results only;
  - lang.json: the text in every language, 70 characters at most with a 24-character name (the notice cuts there).
Needs lupa (pip install lupa). Run: python tests/test_ownernotice0716.py
"""
import json, os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CONTENT = os.path.join(ROOT, "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = ui.index("U.ownerRefusedText = function(r)")
fn = ui[i:ui.index("\nend\n", ui.index("U.ownerRefusedShow = function(r)")) + 5]
common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
t1 = common.index("function C.T(fr, en)")
tf = common[t1:common.index("\nend\n", common.index("function C.Tf(fr, en, ...)")) + 5]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
function log() end
C = { LANG = {}, LANGCODE = "en" }
U = {}
NEWS = {}
U.onChatNews = function(items) NEWS[#NEWS + 1] = items end
''' + tf + fn)
run = L.eval("function(code) return assert(load(code))() end")

items = run("return U.ownerRefusedText({ fn = 'makeEntitySetColorCmd', success = false, err = 'it belongs to company 2 (Firma Simon)' })")
check(items is not None and len(items) == 1 and items[1]["text"] == "Refused: it belongs to another company (Firma Simon)."
      and items[1]["kind"] == "msg" and items[1]["name"] == "MPFever", "#181's recolouring: one notice item naming the company",
      items and items[1]["text"])
items = run("return U.ownerRefusedText({ success = false, err = 'it belongs to company 7' })")
check(items is not None and items[1]["text"] == "Refused: it belongs to another company (#7).", "no name: its number", items and items[1]["text"])
items = run("return U.ownerRefusedText({ success = false, err = 'it belongs to company 3 (' .. string.rep('Wurzel', 8) .. ')' })")
check(items is not None and items[1]["text"] == "Refused: it belongs to another company (WurzelWurzelWurzelWur...).",
      "a long name: cut to 24 characters", items and items[1]["text"])
long_utf = "Schöne Grüße Verkehrsbetriebe Überland"
items = run("return U.ownerRefusedText({ success = false, err = 'it belongs to company 3 (%s)' })" % long_utf)
txt = items[1]["text"] if items else ""
check(items is not None and txt.endswith("...).") and len(txt.encode("utf-8")) == len(txt.encode("utf-8").decode("utf-8").encode("utf-8")),
      "  never cut in the middle of a character", txt)
for r in ["{ success = true, err = 'it belongs to company 2 (X)' }", "{ success = false }",
          "{ success = false, err = 'created entity not found' }", "{ success = false, err = 'DESYNC missing entities: 5' }",
          "{ success = false, err = 'game option: no vehicles' }"]:
    check(run("return U.ownerRefusedText(" + r + ")") is None, "nothing for " + r)
run("ENV.MPFEVER_OWNERNOTICE = '0'")
check(run("return U.ownerRefusedText({ success = false, err = 'it belongs to company 2 (X)' })") is None, "MPFEVER_OWNERNOTICE=0: nothing said")
run("ENV.MPFEVER_OWNERNOTICE = nil; C.LANGCODE = 'fr'")
items = run("return U.ownerRefusedText({ success = false, err = 'it belongs to company 2 (Firma Simon)' })")
check(items[1]["text"] == "Refusé : appartient à une autre entreprise (Firma Simon).", "FR", items[1]["text"])
run("C.LANGCODE = 'en'; NEWS = {}")
run("U.ownerRefusedShow({ success = false, err = 'it belongs to company 2 (X)' }) return nil")
check(run("return #NEWS") == 1, "U.ownerRefusedShow: on the chat's notice")

poll = ui[ui.index("local function pollResults()"):]
poll = poll[:poll.index("\nend\n")]
own = poll[poll.index("if r and r.tok == U.tok and U.pending[r.id] then"):poll.index("elseif r and r.fn == \"makeVehicleBuyCmd\"")]
check("if r.success ~= true then pcall(U.ownerRefusedShow, r) end" in own, "pollResults: shown for this player's own commands only")

lang = json.load(open(os.path.join(ROOT, "launcher", "lang.json"), encoding="utf-8-sig"))["texts"]
k = "Refused: it belongs to another company (%s)."
tr = lang.get(k) or {}
codes = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
check(all(tr.get(c) and "%s" in tr[c] for c in codes), "lang.json: in every language, with its %s")
longest = max([len(tr.get(c, "").replace("%s", "x" * 24)) for c in codes] + [len("Refusé : appartient à une autre entreprise (%s).".replace("%s", "x" * 24))])
check(longest <= 70, "  70 characters at most with a 24-character name", longest)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
