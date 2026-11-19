"""Offline test: MPFever's cards of the pause menu on Transport Fever 3's build 40444 (0.9.2, MPFEVER_PAUSEHOST; the pause card's
installation in mod/mpfever_1/content/mpfever_ui.script.lua).

The bug (build 40444, reports #437/#438: "session: the pause menu's page was not found: MPFever's window cannot be opened in
game"): 40444 draws the pause menu's page (PauseMainPage, gui/main/pause_menu.tl) in a Lua state of its own that mods cannot
reach (gui/main/pause.lua -> bootstrap_pause.tl -> pause.tl; pause_menu.tl asserts api.util.hasPrivilegedApis()). The game's
UI state only has the menu's frame, the recipe "PauseWrap" of the new gui/main/pause_menu_tool.tl, which holds
builtin.PauseMenuHost. mpfever_pause.lua (loaded by the native module in front of pause_menu.tl) now runs in that other state,
so the page's id never reached the UI state, and MPFever's and the chat's cards were gone (the bar's icon still opened the
window).
The fix: when the page is not in this state and the game has builtin.PauseMenuHost, the frame PauseWrap is replaced in this
state: drawn as before, the two cards over it at the page's right; a card opens the window, then the frame's own onClose closes
the menu. 40425 (PauseMainPage in this state) as before.
With the game installed next to MPFever, its gui.zip is read: the recipe names this relies on.
Run: python tests/test_pausehost092.py
"""
import os, re, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
ui = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i3 = ui.index("-- 3. (0.9.2) Build 40444 draws the pause menu's page")
inotfound = ui.index('log("session: the pause menu\'s page was not found: MPFever\'s window cannot be opened in game")')
i2 = ui.index('makeRecipeId("PauseMainPage")')
check(i2 < i3 < inotfound, "the frame is tried after the page's three ways, before giving up")
s3 = ui[i3:inotfound]
check('if not id and builtin.PauseMenuHost ~= nil and os.getenv("MPFEVER_PAUSEHOST") ~= "0" then' in s3,
      "only when the page is not in this state and the game has PauseMenuHost (40444); MPFEVER_PAUSEHOST=0: off")
check('package.loaded["mpfever_pausewrap_id"]' in s3 and 'makeRecipeId("PauseWrap")' in s3 and "rr.originalRecipeFn[rid]" in s3,
      "  the frame's id caught while it registered (makeRecipeId as a last try: in the autotest of 2026-11-19 it gave another id),"
      " only an existing recipe's")
pz = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_pause.lua"), encoding="utf-8").read().replace("\r\n", "\n")
check('if name == "PauseWrap" then package.loaded["mpfever_pausewrap_id"] = id end' in pz, "mpfever_pause.lua catches PauseWrap's id too")
nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
check('EndsWith(chunkname, "gui/main/pause_menu_tool.tl") && !EnvIsZero("MPFEVER_PAUSEHOST")' in nat
      and nat.count("PAUSE_PREFIX, sizeof(PAUSE_PREFIX) - 1") == 2,
      "the native module loads mpfever_pause.lua in front of pause_menu_tool.tl too (MPFEVER_PAUSEHOST=0: not)")
check("local node = wrapOrig(params, ...)" in s3 and "if not C.ACTIVE then return node end" in s3,
      "  the frame drawn as the game draws it (its hooks: the menu's events, its action), the cards only in a session")
check("builtin.FloatingLayoutChild { h = -1, v = -1, item = node }" in s3 and "builtin.FloatingLayoutChild { h = 0.97, v = 0.5," in s3,
      "  the cards over it at the page's right, as on 40425")
check("Card { commonParams = cp }" in s3 and "ChatCard { commonParams = cp }" in s3, "  MPFever's card and the chat's card")
check("local cp = { onClose = function() pcall(params.onClose) end }" in s3, "  a card's click closes the menu with the frame's own onClose")
check(re.search(r'log\("session: MPFever\'s card added over the pause menu.*?\n\s*return\n', s3, re.S) is not None,
      "  logged, and the 40425 way not tried after")
# openFromCard: a container-less window falls back to the default one
ofc = ui[ui.index("local function openFromCard(commonParams, tab)"):]
ofc = ofc[:ofc.index("\n\tend\n")]
check("pcall(function() wapi = commonParams.windowContainer:get():getApi() end)" in ofc and "pcall(commonParams.onClose)" in ofc,
      "openFromCard: no window container in the frame's parameters is fine (the default one), then onClose")

g = os.path.join(ROOT, "..", "base", "content", "gui.zip")
if os.path.isfile(g):
    with zipfile.ZipFile(g) as z:
        names = set(z.namelist())
        if "gui/main/pause_menu_tool.tl" in names:
            t = z.read("gui/main/pause_menu_tool.tl").decode("utf-8", "replace")
            b = z.read("gui/main/builtin.lua").decode("utf-8", "replace")
            pm = z.read("gui/main/pause_menu.tl").decode("utf-8", "replace")
            check('react.RegisterRecipe("PauseWrap"' in t and "builtin.PauseMenuHost{}" in t and "params.onClose()" in t,
                  "the installed game (40444): PauseWrap holds PauseMenuHost and closes the menu with params.onClose")
            check("PauseMenuHost" in b, "  builtin.PauseMenuHost exists")
            check("hasPrivilegedApis" in pm, "  the page itself in the privileged state (the bug's cause)")
        else:
            check('"PauseMainPage"' in z.read("gui/main/pause_menu.tl").decode("utf-8", "replace"),
                  "the installed game (40425): the page in the UI state, as before")
else:
    print("(the game is not installed next to MPFever: its files not read)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
