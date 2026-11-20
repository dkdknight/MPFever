"""Offline test: the mod API works in the game's interface state, which has no rawget (0.9.3, issue #448, MPFEVER_APIRAWGET;
mod/mpfever_1/content/mpfever_api.lua).

The bug (#448, Leinlein's session, 0.9.2 and 0.9.1 alike): the interface's log said 12 times
  "mods' automatic commands: check failed: [string "mpfever_1::/mpfever_api.lua"]:65: attempt to call global 'rawget' (a nil value)"
The game's interface Lua state has no rawget. A.declaredOf (0.8.17) called it for every command a mod sent by itself, so
U.autoVerdict failed on each of them: no verdict, and the command left from every game, none of mpfever_modauto.lua's rules
(one game sends it). A second A.install in that state (a new game) failed the same way.
The fix: mpfever_api.lua takes a plain read when the state has no rawget (its tables have no metatable).
MPFEVER_APIRAWGET=0: as before.

Part 1 reproduces the bug (rawget removed, the switch at 0: declaredOf raises the same error). Part 2 shows the fix in the same
state (declaredOf answers, a declared mod is found, an undeclared one is not, a second install keeps the declarations). Part 3:
in a state with rawget, nothing changes. Part 4: the interface's verdict through U.autoVerdict's call reaches MA.decide again.
Run: python tests/test_apirawget093.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
API = open(os.path.join(CONTENT, "mpfever_api.lua"), encoding="utf-8").read()
UI = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
MODIO = "@C:/Users/Public/mod.io/10640/mods/6419266/content/res/scripts/my_mod.lua"
OTHER = "@C:/Users/Public/mod.io/10640/mods/6416560/content/auto_signals/auto_signals.script.lua"
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def state(has_rawget, switch_off):
    """A Lua state like the game's interface (no rawget) or the simulation's (rawget), the API loaded in it."""
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.loaded['mpfever'] = nil")
    if not has_rawget:
        L.execute("rawget = nil")
    L.execute("os = { getenv = function(k) if k == 'MPFEVER_APIRAWGET' then return %s end return nil end }"
              % ("'0'" if switch_off else "nil"))
    L.globals().A = L.execute(API)
    L.execute("""
      ENV = { half = 'interface', version = '0.9.3', log = function() end,
              getinfo = function(lvl) return { source = '%s', what = 'Lua' } end,
              role = function() return 'client' end, server = function() return false end, mode = function() return nil end,
              companyOf = function() return nil end, entityOf = function() return nil end, myCompany = function() return 1 end,
              ownerCompany = function() return nil end, gamePlayer = function() return 900 end }
    """ % MODIO)
    return L


def run(L, code):
    f = L.eval("function(code) local ok, a, b = pcall(assert(load(code))) return ok, tostring(a), tostring(b) end")
    return f(code)


# ---- part 1: the bug, rawget missing and the switch at 0
L = state(False, True)
ok, a, b = run(L, "local mp = A.install(ENV) return A.declaredOf(mp, { '%s' }) ~= nil" % MODIO)
check("bug reproduced: no rawget in the state, MPFEVER_APIRAWGET=0 -> declaredOf raises", not ok and "rawget" in a, a)

# ---- part 2: the fix in the same state
L = state(False, False)
ok, a, b = run(L, """
  local mp = A.install(ENV)
  local before = A.declaredOf(mp, { '%s' })
  mp.declare({ autoCommands = 'self' })
  local mine = A.declaredOf(mp, { '%s' })
  local other = A.declaredOf(mp, { '%s' })
  return tostring(before == nil) .. ',' .. tostring(mine ~= nil) .. ',' .. tostring(other == nil), ''
""" % (MODIO, MODIO, OTHER))
check("fix: declaredOf answers in a state without rawget", ok, a)
check("  nothing declared: nil; the declared mod found; another mod not", ok and a == "true,true,true", a)
ok, a, b = run(L, """
  local first = package.loaded['mpfever']
  local mp = A.install(ENV)
  return tostring(mp == first) .. ',' .. tostring(A.declaredOf(mp, { '%s' }) ~= nil), ''
""" % MODIO)
check("  a second install in the same state (a new game) keeps the table and its declarations", ok and a == "true,true", a)

# ---- part 3: a state with rawget (the simulation): unchanged
L = state(True, False)
ok, a, b = run(L, "local mp = A.install(ENV) mp.declare({ autoCommands = 'self' }) return tostring(A.declaredOf(mp, { '%s' }) ~= nil), ''"
               % MODIO)
check("a state with rawget: as before", ok and a == "true", a)
check("  the state's own rawget is used there", "local rawget = rawget\nif rawget == nil then" in API)

# ---- part 4: the interface's verdict goes through declaredOf (the check that failed)
i = UI.index("U.autoVerdict = function(tag)")
v = UI[i:UI.index("\nend\n", i)]
check("the interface's verdict asks declaredOf for a mod's automatic command", "MPAPI.declaredOf(U.api, sf.mods)" in v)
check("  then MA.decide gives the verdict", "MA.decide(facts)" in v and v.index("MPAPI.declaredOf") < v.index("MA.decide(facts)"))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
