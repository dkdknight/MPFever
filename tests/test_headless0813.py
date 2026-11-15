"""Offline test (0.8.13): a dedicated server "without display" draws the world in its hidden window and never waits on a message box.

Issues #354 and #361 (2026-11-15): with many vehicles replaced at once, the server's hidden game failed at the end of a frame
(Vulkan assertion 'destroyLater->back().empty()') or crashed in the graphics driver (nvoglv64.dll): CRenderer::Render was
skipped since 0.5.8, and the graphics resources of removed vehicles are released along that drawing. After the crash the game's
error box waited for a click in the hidden window: the server stood still until the launcher's watchdog.
  - CRenderer::Render is skipped only with MPFEVER_HEADLESS_NORENDER=1;
  - SDL_ShowSimpleMessageBox and SDL_ShowMessageBox are replaced (headless only): logged, answered at once, default button.
Run: python tests/test_headless0813.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


a = src.find("static void InstallHeadless()")
body = src[a:src.find("\n}\n", a)]
check(a > 0, "InstallHeadless found")
k = body.find('SkipFunction("CRenderer::Render')
check(k > 0, "the Render skip is still there")
check('MPFEVER_HEADLESS_NORENDER' in body[max(0, k - 200):k], "  only with MPFEVER_HEADLESS_NORENDER=1")
check("drawn in the hidden window" in body, "  native.log says the world is drawn")
check(body.find("if (!g_headless) return;") < k, "  headless only")

s = src.find("static void SetupHeadlessImports()")
setup = src[s:src.find("\n}\n", s)]
check(setup.find("g_headless = true") < setup.find("SDL_ShowSimpleMessageBox"), "message boxes replaced after the headless check")
check('"SDL2.dll", "SDL_ShowSimpleMessageBox", (void*)&SdlShowSimpleMessageBoxHeadless' in setup, "  SDL_ShowSimpleMessageBox replaced")
check('"SDL2.dll", "SDL_ShowMessageBox", (void*)&SdlShowMessageBoxHeadless' in setup, "  SDL_ShowMessageBox replaced")

m = src.find('extern "C" int SdlShowMessageBoxHeadless(')
mb = src[m:src.find("\n}\n", m)]
check("*buttonid = id" in mb and "return 0;" in mb, "SDL_ShowMessageBox answered (button id, success)")
check("(f & 1)" in mb, "  the default button (RETURNKEY_DEFAULT) chosen")
check("i < 16" in mb, "  bounded")
m2 = src.find('extern "C" int SdlShowSimpleMessageBoxHeadless(')
check("return 0;" in src[m2:src.find("\n}\n", m2)], "SDL_ShowSimpleMessageBox answered")
lg = src[src.find("static void LogHeadlessBox("):]
lg = lg[:lg.find("\n}\n")]
check("> 20) return" in lg and "b.n < 900" in lg, "box texts logged, bounded")
check(not re.search(r"'\s*'\s*\|\|", lg), "no broken character literal")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
