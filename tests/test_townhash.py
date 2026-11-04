"""Offline test of the game script states' hash (valueHash in the bridge) for a town's idle marketing campaign (0.6.12, the
user's session of 2026-11-03 20:37).

The game's town_util.getTownState writes a campaign's two fields with their defaults (marketingInitiatedTimestamp 0,
marketingParams {durationMs 0, lineCostFactor 0.5}) into every town a build touches, and the town's next update drops them
(applyEventDecay keeps a campaign only while it runs). A build and its replay do not touch exactly the same towns: the fields
stood in one game's state only, through a whole pause, and "script:towns" reloaded the games. An idle campaign now hashes as
no campaign; a running one still counts; MPFEVER_MARKETINGHASH=0: as before.
Run: python tests/test_townhash.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
COMMON = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def runtime(env_off):
    src = open(BRIDGE, encoding="utf-8").read()
    com = open(COMMON, encoding="utf-8").read()
    vh = re.search(r"^C\.marketingHash = .*?\n(local function valueHash\(v, d, noName\)\n.*?^end\n)", src, re.S | re.M)
    hs = re.search(r"^function C\.int\(v\)\n.*?^end\n", com, re.S | re.M)
    hh = re.search(r"^function C\.hashStr\(h, s\)\n.*?^end\n", com, re.S | re.M)
    if not (vh and hs and hh):
        return None
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {} os.getenv = function(k) return ENV[k] end C = {}")
    if env_off:
        L.execute('ENV.MPFEVER_MARKETINGHASH = "0"')
    L.execute(hs.group(0) + hh.group(0) + 'C.marketingHash = os.getenv("MPFEVER_MARKETINGHASH") ~= "0"\n' + vh.group(1).replace("local function valueHash", "function valueHash", 1))
    return L.eval("function(code) return assert(load(code))() end")


TOWN = """
local function town(extra)
  local ef = { score = 0.9, itemDelivery = 1, numItemsDelivered = 0, averageItemsDelivered = 0, onTimeItemDelivery = 1, reasonToPenalty = { TerrainModification = 0.001 } }
  for k, v in pairs(extra or {}) do ef[k] = v end
  return { townStates = { { authorityScore = 0.83, eventFactors = ef, townEntity = { entity = 80278, revision = { num = { 1, 6, 258353 } } } } } }
end
"""


def main():
    run = runtime(False)
    check("valueHash, C.int and C.hashStr found", run is not None)
    if run is None:
        return 1
    got = run(TOWN + """
      local plain = valueHash(town(), 0)
      local idle = valueHash(town({ marketingInitiatedTimestamp = 0, marketingParams = { durationMs = 0, lineCostFactor = 0.5 } }), 0)
      local running = valueHash(town({ marketingInitiatedTimestamp = 47000000, marketingParams = { durationMs = 3600000, lineCostFactor = 0.5 } }), 0)
      local other = valueHash(town({ score = 0.8 }), 0)
      return tostring(plain == idle) .. " " .. tostring(plain ~= running) .. " " .. tostring(plain ~= other)""")
    check("#20:37: an idle campaign's default fields hash as no campaign", got.split()[0] == "true", got)
    check("a running campaign still counts", got.split()[1] == "true", got)
    check("any other town value still counts", got.split()[2] == "true", got)
    run = runtime(True)
    got = run(TOWN + """
      return tostring(valueHash(town(), 0) ~= valueHash(town({ marketingInitiatedTimestamp = 0, marketingParams = { durationMs = 0, lineCostFactor = 0.5 } }), 0))""")
    check("MPFEVER_MARKETINGHASH=0: as before (they differ)", got == "true", got)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
