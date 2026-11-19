"""Offline test: why a Mod Hub subscription failed is read on Transport Fever 3's build 40444 too (0.9.2; mpfever_menu.lua,
the missing mods' installation from the Mod Hub).

Build 40444 (2026-11-19) replaced the Mod Hub error's field message by localizedMessage and debugMessage
(api/tealdef/api/modhub.d.tl): the reason of a failed subscription read nil, and the menu showed "nil" instead of the Hub's
words. The error's fields are read one by one in pcall: localizedMessage, debugMessage, then message (40425).
The lines are run through lupa (Lua 5.2) on errors of both builds.
Run: python tests/test_modhuberr092.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_menu.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


a = SRC.index("local e = result:getError()")
b = SRC.index(chr(10), SRC.index('return e and (f("localizedMessage")', a))
body = SRC[a:b]
check("the reason: localizedMessage, debugMessage, then message", 'f("localizedMessage") or f("debugMessage") or f("message")' in body)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
reason = L.eval("function(err) local result = { getError = function() return err end } " + body.replace("result:getError()", "result.getError()") + " end")
# a userdata whose missing field raises, as the engine's
strict = L.eval("""function(t) return setmetatable({}, { __index = function(_, k) local v = rawget(t, k) if v == nil then error("no field " .. k) end return v end }) end""")
old = L.eval("function() return { message = 'not logged in' } end")()
new = L.eval("function() return { localizedMessage = 'Not logged in', debugMessage = 'E401' } end")()
check("the bug's form (40444): message read as nil before", L.eval("function(e) return e.message end")(new) is None)
check("40444's error: its localised words", reason(strict(new)) == "Not logged in", reason(strict(new)))
check("40425's error: its message, as before (the missing fields read in pcall)", reason(strict(old)) == "not logged in", reason(strict(old)))
check("no error object: '?'", reason(None) == "?")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
