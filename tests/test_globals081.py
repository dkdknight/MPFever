"""Offline test: the mod's Lua files use no unknown global (0.8.1, a luacheck-like check; tests/luascan.py).

After the 0.7.17 regression (REFUND.book read SIM, a top-level local declared further down, so the global SIM, nil), every name a
file of mod/ reads or makes as a global must be a standard Lua one or one of the game's, listed below with why. It finds:
  - a local used above its declaration (the 0.7.17 bug: SIM; the toll notice: T),
  - a typo in a name (a local `stattion` read as `station`... is a global read),
  - a forgotten `local` (a global made inside a function: shared by every call and every file of the same Lua state).
A new global of the game: add it to GAME with where it comes from. Run: python tests/test_globals081.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import luascan  # noqa: E402

ROOT = os.path.join(HERE, "..", "mod")

LUA = set("_G _ENV _VERSION assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall print rawequal "
          "rawget rawlen rawset require select setmetatable tonumber tostring type xpcall unpack coroutine debug io math os "
          "package string table bit32 utf8 loadstring".split())
# the game's globals (Transport Fever 3, build 40425), each with where it comes from
GAME = {
    "api": "the game's scripting API (api.engine, api.cmd, api.gui, api.res, api.type, api.util)",
    "game": "the game's script interface (game.interface, game.gui), in game scripts and the interface",
    "app": "the game's application object (main menu: app.getUserProfile...)",
    "ug_require": "the game's require for its own script libraries",
    "_": "the game's translation function _(text)",
    "_react": "the game's React bridge (menu and interface plugins)",
    "getBuildVersion": "the game's build number",
    "debugPrint": "the game's debug printer",
    "toString": "the game's table printer",
}
# top-level globals a resource file must make for the game
MADE = {"data": "a resource file's data function (mod.lua, .con, .gs, game scripts)"}

fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def problems(res, rel):
    out = []
    for name, line, _i in res["reads"]:
        if name not in LUA and name not in GAME and name not in MADE:
            d = res["toplevel"].get(name)
            why = f"declared 'local' further down" if d is not None else "unknown global"
            out.append(f"{rel}:{line}: '{name}' read as a global ({why})")
    for name, line, in_fn in res["writes"]:
        if in_fn:
            out.append(f"{rel}:{line}: '{name}' made a global inside a function (a forgotten 'local'?)")
        elif name not in MADE:
            out.append(f"{rel}:{line}: '{name}' made a global (not one the game asks for)")
    return out


files = []
for dp, dn, fn in os.walk(ROOT):
    for f in fn:
        if f.endswith(".lua"):
            files.append(os.path.join(dp, f))
found = []
for p in sorted(files):
    rel = os.path.relpath(p, os.path.join(HERE, ".."))
    found += problems(luascan.scan(p), rel)
for f in found[:60]:
    print("FAIL " + f)
check(not found, f"{len(files)} Lua files: no unknown global ({len(found)} found)")

# the check finds the two bugs of that class seen on 2026-11-10, and a forgotten local, and passes clean code
cases = {
    "the 0.7.17 bug (SIM above its local)": ("local REFUND = {}\nfunction REFUND.book() return SIM.ctTick end\nlocal SIM = { ctTick = 0 }\n", True),
    "the toll notice (T above its local)": ("local function f() return T('a', 'b') end\nlocal T = function(a, b) return b end\n", True),
    "a typo in a local's name": ("local station = 1\nlocal function f() return stattion end\n", True),
    "a forgotten local": ("local function f() count = 1 end\n", True),
    "clean code": ("local t = {}\nfor k, v in pairs(t) do local x = k end\nlocal function f(a, ...) return a, api.engine end\n", False),
}
for what, (src, bad) in cases.items():
    got = bool(problems(luascan.scan(src=src), "probe"))
    check(got == bad, f"  {what}: {'found' if bad else 'nothing found'}")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
