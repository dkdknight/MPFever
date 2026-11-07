"""The Hub opens centred (0.7.5, mpfever_ui.script.lua, U.hubCentre and U.hubAt).

The game places a window by its first size, before the Hub's pages are laid out (no size yet), and keeps it there by its id for
the session (initialX/Y is read once; seen in game 2026-11-07: a Hub opened again kept its place, and a window whose id changed
while shown closed the game with an assertion). With initialX/Y 0.5/0.45 the Hub's top left corner landed in the middle of the
screen (1280 x 895: at 640, 395) and a larger Hub ran off a small screen. A few frames after it opens, from react.onStep (the
interface's API is refused in a timer, "API is currently restricted"), its size is read as a part of the screen (0.475 x 0.478
of 1 x 1) and the ratio to its measures kept (hubk, in the ui_prefs.txt kept across launches, for that screen); the next
openings put its top left corner where it is centred, from the first frame. The game's resetMovedWindowPosition (to the top left
corner) is not used, nor a new id, nor a reopening. MPFEVER_HUBCENTER=0: 0.5/0.45 as before.
Needs lupa (pip install lupa). Run: python tests/test_hubcenter075.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find('U.HubWindow = react.RegisterWrapperRecipe("MPFeverHubWindow"')
j = src.find("return builtin.Window {", i)
win = src[i:j]
check(i > 0 and j > i, "the Hub's window found")
on = win.find("react.onStep(function()")
check(on > 0 and "pcall(U.hubCentre)" in win[on:], "its size read from react.onStep")
w = src[j:j + 500]
check("initialX = atX" in w and "initialY = atY" in w and "local atX, atY = U.hubAt()" in win, "it opens where U.hubAt says")
check('id = "window.mpfever.hub"' in w, "one id, never changed")
check("api.gui.byId.resetMovedWindowPosition" not in src and "hubReopen" not in src, "no reset, no reopening")
check('hubk = true' in src and '"hubk=" .. tostring(p.hubk)' in src, "the ratio kept across launches")

a = src.find("U.hubCentre = function()")
b = src.find("U.closeHub = function()", a)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG = {}
function log(s) LOG[#LOG + 1] = s end
U = {}
SIZES = {}
api = { gui = { byId = { getSize = function(id) local v = SIZES[id]; if not v then error("no such id") end return { x = v[1], y = v[2] } end } } }
SAVED = 0
U.saveGlobalPrefs = function() SAVED = SAVED + 1 end
U.prefs = {}
U.loadPrefs = function() return U.prefs end
SW, SH = 1280, 895
U.hubScreen = function() return SW, SH end
SIZE = 2
U.hubMeasures = function() local f = ({ 0.55, 0.67, 0.8 })[SIZE]; return { W = math.floor(math.max(900, SW * f)), H = math.floor(math.max(520, SH * f)) } end
""")
L.execute(src[a:b])
x, y = L.eval("U.hubAt()")
check((x, y) == (0.5, 0.45), "nothing learnt yet: 0.5, 0.45 as before")
L.execute('SIZES["window.mpfever.hub"] = { 0.475, 0.478 }; SIZES["GameUiWindowContainer"] = { 1, 1 }; U.hubCentre()')
check(L.eval("SAVED") == 1 and str(L.eval("U.prefs.hubk")).startswith("1280,895,"), "the ratio learnt and saved for this screen: " + str(L.eval("U.prefs.hubk")))
x, y = L.eval("U.hubAt()")
check(abs(x - 0.2625) < 0.001 and abs(y - 0.261) < 0.001, "the same Hub opens centred: %.4f, %.4f" % (x, y))
L.execute("SIZE = 3")
x, y = L.eval("U.hubAt()")
check(0.15 < x < 0.26 and 0.15 < y < 0.26, "a larger Hub opens further left and up: %.3f, %.3f" % (x, y))
L.execute("U.hubCentre()")
check(L.eval("SAVED") == 2 or L.eval("SAVED") == 1, "measured again at each opening (saved only when it changed)")
L.execute("SW, SH = 1920, 1080")
check(L.eval("U.hubAt()") == (0.5, 0.45), "another screen: not used, learnt again")
L.execute('ENV.MPFEVER_HUBCENTER = "0"; SW, SH = 1280, 895')
check(L.eval("U.hubAt()") == (0.5, 0.45), "MPFEVER_HUBCENTER=0: 0.5, 0.45")
L.execute('ENV.MPFEVER_HUBCENTER = nil; SIZES["window.mpfever.hub"] = nil; LOG = {}; U.hubCentre()')
check("not read" in L.eval("LOG[1]"), "a size not read: said, nothing changed")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
