"""The Multiplayer page's « Host » tab keeps its title row (« New game… » and the filter) when the resynchronisation box shows
(0.7.5, mpfever_menu.lua).

0.7.4 added a row « Show the resynchronisation savegames » between the title row and the savegames' list, but the list kept its
height (500): the page was taller than the game's card, and the game squeezed the title row out, « New game… » with it
(players reported the button gone; checked on screen 2026-11-07, then by the user after the fix). The list now gives that row
its room (64 less) when the row is shown; MPFEVER_RESYNCROWOLD=1: as 0.7.4.
Run: python tests/test_menuresync075.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_menu.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find('elseif tab:old() == "host" then')
j = src.find('elseif tab:old() == "servers"', i)
host = src[i:j]
check(i > 0 and j > i, "the Host tab found")
title = host.find('T("Choisissez la sauvegarde à partager"')
newgame = host.find('T("Nouvelle partie…"')
row = host.find("local resyncRow = nResync > 0 or showResync:old()")
scroll = host.find("builtin.ScrollArea{")
check(0 < title < newgame < row < scroll, "title row with « New game… », then the resynchronisation row, then the list")
check("if resyncRow then" in host, "the resynchronisation row shown on the same condition")
m = re.search(r"\(hasError and 440 or 500\)\s*-\s*\(\(resyncRow and os\.getenv\(\"MPFEVER_RESYNCROWOLD\"\) ~= \"1\"\) and 64 or 0\)", host)
check(m is not None and m.start() > scroll, "the list gives the row 64 of its height (MPFEVER_RESYNCROWOLD=1: as 0.7.4)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
