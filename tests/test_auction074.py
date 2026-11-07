"""Offline checks of the 0.7.4 auction of a bankrupt company that need the game's code as it is (the logic itself, every lot at
once, the whole company, the heir, is run by tests/test_companies.py with a mocked game):

  - a computer company that went bankrupt starts again with a new company, but kept what it knew of the old one: it bought a
    truck at the old company's depot and sent it to the old company's line, which the auction then put up for sale (au3,
    2026-11-07). Its memory now starts again when its company changes (MPFEVER_AIKEEPMEMORY=1: kept, as before). (The crash
    of au1 to au6 at the close came from the computer companies' freight lines' stops: see tests/test_stopfull074.py);
  - at the close, an entity changes hands once only (the commands are applied after the step: the line just sold went to the
    heir with the rest), and a vehicle or a line left over is sold or taken away, never handed to the heir;
  - the host's clock: the minutes of the host's rule, 30 s more after a late bid, MPFEVER_AUCTIONSECONDS for the tests;
  - the window's page: every lot at once, the detail of each lot, an unnamed station's label;
  - a computer company's freight line is named after its cargo's name, not its file's path.
Run: python tests/test_auction074.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
ai = open(os.path.join(C, "mpfever_ai.lua"), encoding="utf-8").read()
eco = open(os.path.join(C, "mpfever_eco.lua"), encoding="utf-8").read()
br = open(os.path.join(C, "mpfever_bridge.script.lua"), encoding="utf-8").read()
ui = open(os.path.join(C, "mpfever_ui.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


tick = ai[ai.index("function M.tick(E, st)"):]
check('if known and G.AI.coId and G.AI.coId ~= known.id and os.getenv("MPFEVER_AIKEEPMEMORY") ~= "1" then' in tick
      and "G.AIS[cur.n] = { lookAt = G.AI.lookAt, levelSaid = G.AI.levelSaid }" in tick and "if known then G.AI.coId = known.id end" in tick
      and tick.index("G.AI.coId ~= known.id") < tick.index("step(E)"),
      "a computer company that changed company (a bankruptcy) forgets the old one before it acts")
so = eco[eco.index("local function setOwner(list, from, to)"):eco.index("local function nameOf(e)")]
check("not (E.handing and E.handing[e])" in so and "if E.handing then E.handing[e] = true end" in so, "at the close, an entity changes hands once")
ca = eco[eco.index("function E.closeAll(st, env)"):eco.index("-- ---------------------------------------------------------------- bankruptcy")]
check("E.handing = {}" in ca and "E.handing = nil" in ca and "makeVehicleSellCmd({ e })" in ca and "makeLineDestroyCmd(e)" in ca,
      "the close: a vehicle or a line left over is sold or taken away, the rest to the heir")
check("if E.handing then for _, list in ipairs({ ents, vehicles, cons }) do" in eco, "what is demolished is never handed to the heir afterwards")
check("G.auSeconds = function(au)" in br and 'os.getenv("MPFEVER_AUCTIONSECONDS")' in br and "A.endT = nowT + E.SNIPE_SECONDS" in br
      and 'G.coEvent("co_auction_close", { seq = au.seq })' in br, "the host's clock: its minutes, 30 s more after a late bid, then the close")
check('"lotd\\t"' in br and "G.coLotDetail = function(reg, au, i, lot)" in br, "each lot's detail for the window")
check("U.TABS.auction = function(K, st, ctx)" in ui and 'C.Tf("Gare sans nom (lot %s)"' in ui and '"auction2" then' in ui,
      "the Auctions page: every lot at once, an unnamed station's label")
check("local function cargoLabel(E, id)" in ai and 'AINAME .. " " .. cargoLabel(E, f.cargo)' in ai,
      "a computer company's freight line named after its cargo, not its file's path")
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
