"""Offline test of the removal of the game's trees (0.5.14): a replayed removal of groups of the game's own trees goes straight
to the engine's removal, not first through the factory, which always threw there (an engine assertion, a crash dump and a
hitch each time: four times in the friends' 4-hour session of 2026-10-29).

replayAssets is taken from the real bridge file and run through lupa (Lua 5.2) with a mocked engine (the factory throws on
a group of the game's trees, as the game's does). Cases:
  - groups of the game's trees: the engine's removal at once, the factory not called;
  - the mod's own asset construction among them (trees the brush placed): the factory first, as before;
  - MPFEVER_ASSETFACTORYFIRST=1: the factory first, then the engine's removal when it throws, as before;
  - MPFEVER_ASSETENGINERM=0: the factory only, a refusal reported (as before 0.5.13's engine removal);
  - trees added only (no removal): the factory.
Run: python tests/test_treeremoval.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
CONS = {}          -- construction entity -> its file
CALLS, LOGS = {}, {}
local function copy(v) if type(v) ~= "table" then return v end local t = {} for k, x in pairs(v) do t[k] = copy(x) end return t end
api = {
  type = {
    ComponentType = { CONSTRUCTION = "con" },
    SimpleProposal = { new = function() return {} end, ConstructionEntity = { new = function() return {} end } },
    Context = { new = function() return {} end },
  },
  engine = {
    getComponent = function(e, ct) if ct == "con" and CONS[e] then return { fileName = CONS[e] } end return nil end,
    util = { getPlayer = function() return 1 end },
  },
  cmd = {
    makeWorldBuildProposalCmd = function(sp, ctx, a, b)
      CALLS[#CALLS + 1] = "factory"
      -- (the factory throws on a group of the game's trees to remove)
      for _, e in ipairs(sp.constructionsToRemove or {}) do if CONS[e] ~= "mpfever_1::/mpfever_asset.con" then error("Unknown exception") end end
      return { kind = "build" }
    end,
  },
}
C = { ser = function(v) return v end, deser = copy, copy = copy, plain = copy, marshal = function(v) return v end }
R = { translateIn = function(args, bind) return {} end }
G = { bind = {}, assetPI = function() return true end,
  assetEngineRemoval = function(a, uid, rm, cons, ctx, strict) CALLS[#CALLS + 1] = "engine " .. table.concat(rm, ",") end }
function assetConName() return "mpfever_1::/mpfever_asset.con" end
function log(s) LOGS[#LOGS + 1] = s end
function shortErr(e) return tostring(e) end
function replayFailed(a, why) CALLS[#CALLS + 1] = "failed: " .. why end
function toSim() end
function replaySend(cmd, cb) CALLS[#CALLS + 1] = "sent" end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^local function replayAssets\(a\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: replayAssets not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0).replace("local function replayAssets", "function replayAssets", 1))
    lua_run = L.eval("function(code) local f = assert(load(code)) return f() end")

    def run(code):
        # (a Lua error is a result too: the case that gets it fails, the others still run)
        try:
            return lua_run(code)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]

    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    run(r'''
CONS = { [500] = "::/assets/trees/forest_group.con", [501] = "::/assets/trees/forest_group.con", [600] = "mpfever_1::/mpfever_asset.con" }
function replay(toRemove, env, assets)
  ENV = env or {}
  CALLS = {}
  replayAssets({ uid = "bob:7", args = { toRemove = toRemove, assets = assets } })
  ENV = {}
  return table.concat(CALLS, " ; ")
end
''')
    got = run("return replay({ 500, 501 })")
    check("groups of the game's trees: the engine's removal at once, no factory", got == "engine 500,501", got)
    got = run("return replay({ 500 }, nil, { { models = {}, transf = {} } })")
    check("with trees added back: the engine's removal, which builds them too", got == "engine 500", got)
    got = run("return replay({ 600 })")
    check("the mod's own asset construction: the factory, as before", got == "factory ; sent", got)
    got = run("return replay({ 500, 600 })")
    check("a mix: the factory first, then the engine's removal when it throws, as before", got == "factory ; engine 500,600", got)
    got = run('return replay({ 500 }, { MPFEVER_ASSETFACTORYFIRST = "1" })')
    check("MPFEVER_ASSETFACTORYFIRST=1: the factory first, as before", got == "factory ; engine 500", got)
    got = run('return replay({ 500 }, { MPFEVER_ASSETENGINERM = "0" })')
    check("MPFEVER_ASSETENGINERM=0: the factory only, not reproduced", got == "factory ; failed: assets not rebuilt", got)
    got = run("return replay({}, nil, { { models = {}, transf = {} } })")
    check("trees added only: the factory", got == "factory ; sent", got)

    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
