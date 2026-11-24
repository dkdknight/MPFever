"""Offline test (0.9.7, #487): a build a mod sends from the interface waits for its real answer (mpfever_ui.script.lua, the
callback of a held command).

hluki's session of 2026-11-23 (0.9.5, #487): AndisPC's Town Transit Planner replaced street pieces one after the other, each from the
callback of the one before. MPFever answered every interface build at once (IMMEDIATE, as for the construction tools, which only
wait to be released), before any game had applied it: the mod made its next piece on the world without the previous one, its node
configurations named a segment the earlier build had just replaced, and half its pieces (29 of 58 actions) were refused on every
game ("its node configuration of node ... names segment ..., taken away by an earlier build at this time"). The game script
interface's hook (G.installGsMods) already answered a mod's commands once applied.
  - before (MPFEVER_MODBUILDWAIT=0, as 0.9.6): a mod's build answered at once, the callback runs before the result (the refusals);
  - now: a mod's build (a mod in the command's stack: fromMod, else U.fromMod) waits in U.pending for its result, delivered by the
    results reader (r.tok == U.tok); the game's own tools (no mod) are still answered at once; without the per-step component
    (U.stepping false) everything is answered at once as before; another command keeps waiting for its result as before.
Run: python tests/test_modbuildwait097.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def main():
    src = open(UI, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"\n(\t\tif cb then\n\t\t\t-- \(\(0\.9\.7, #487\).*?\n\t\tend\n)", src, re.S)
    check(m is not None, "the held command's callback block found")
    if not m:
        return 1
    block = m.group(1)
    check('local IMMEDIATE = { makeWorldBuildProposalCmd = true }' in src, "construction tools' builds are still in IMMEDIATE")
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r"""
LOGS = {}
ENV = {}
function log(t) LOGS[#LOGS + 1] = t end
os = { getenv = function(k) return ENV[k] end, clock = function() return 1 end }
IMMEDIATE = { makeWorldBuildProposalCmd = true }
function hold(name, fromMod, stackMod, stepping, env)
  ENV = env or {}
  local U = { seq = 7, pending = {}, stepping = stepping, fromMod = function() return stackMod end }
  local tag = { name = name }
  local autoNow = false
  local answered = false
  local cb = function() answered = true end
""" + block + r"""
  return tostring(answered) .. "|" .. tostring(U.pending[7] ~= nil)
end
""")
    hold = L.eval("hold")
    lua_table = L.eval("function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end")

    def env(**kw):
        return lua_table(L.table_from(kw))

    B = "makeWorldBuildProposalCmd"
    check(hold(B, True, None, True, env(MPFEVER_MODBUILDWAIT="0")) == "true|false",
          "before (MPFEVER_MODBUILDWAIT=0, as 0.9.6): a mod's build answered at once, before any game applied it (#487)")
    check(hold(B, True, None, True) == "false|true", "now: a mod's build waits for its result (U.pending)")
    check(hold(B, False, "town_transit::/res/scripts/x.lua", True) == "false|true",
          "  a mod found in the stack by U.fromMod when the automatic-commands check did not say so")
    check(any("its answer waits until every game has applied it" in str(x) for x in L.globals().LOGS.values()), "  (said in the logs)")
    check(hold(B, False, None, True) == "true|false", "the game's own construction tools: answered at once, as before")
    check(hold(B, True, None, False) == "true|false", "without the per-step component (no result could be delivered): at once, as before")
    check(hold("makeLineCreateCmd", False, None, True) == "false|true", "another command waits for its result, as before")
    # the results reader delivers it
    r = src.find("if r and r.tok == U.tok and U.pending[r.id] then")
    check(r > 0 and "pcall(p.cb, data, r.success == true, entities)" in src[r:r + 1200], "the results reader gives the pending callback its real answer")
    br = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
    check("H.modwait = function(from, p)" in br and 'if kind == "modsig" then' in src and '"=mpftestmod::/res/scripts/modsig.lua"' in src,
          "autotest modwait: the host's interface sends a build from a mod's file and notes whether it stood when answered")
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
