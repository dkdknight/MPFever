"""Offline test of the line lead (0.7.0, experimental, MPFEVER_LINELEAD=1; the user's sessions of 2026-11-04: a stop added in the
line window showed 1.3 s later, up to 3.7 s).

A line command starts the builder's lead; while this game leads (G.buildLeadState true) it is stamped its overshoot plus one step
ahead instead of the stamp distance. G.lineLeadStamp runs through lupa (Lua 5.2) with the lead mocked.
Cases: off by default (stamp kept); on and leading: stamped sooner, and the lead started; on but the others do not follow yet:
stamp kept; another command (a vehicle bought): stamp kept; never later than the usual stamp.
Run: python tests/test_linelead.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def runtime(env):
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^G\.LINE_LEAD_FNS = .*?^end\n", src, re.S | re.M)
    if not m:
        return None
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {} os.getenv = function(k) return ENV[k] end")
    for k, v in env.items():
        L.execute(f'ENV.{k} = "{v}"')
    L.execute("""
STEP = 200
NOW = 1000000
LEADS = 0
LEADOK = true
log = function() end
G = { buildLead = true }
G.buildLeadPeers = function() return true end
G.buildLeadState = function() if LEADOK then return true end return false, "x does not follow yet" end
terrainLead = function(why, what) LEADS = LEADS + 1 end
overshootReserve = function() return 3 end
""" + m.group(0))
    return L.eval("function(code) return assert(load(code))() end")


def main():
    run = runtime({})
    check("G.lineLeadStamp found", run is not None)
    if run is None:
        return 1
    usual = "NOW + 7 * STEP"
    got = run(f"local a = {{ fn = 'makeLineUpdateCmd', at = {usual} }}; G.lineLeadStamp(a, NOW); return a.at - NOW")
    check("off by default: the usual stamp", got == 7 * 200, got)
    run = runtime({"MPFEVER_LINELEAD": "1"})
    got = run(f"local a = {{ fn = 'makeLineUpdateCmd', at = {usual} }}; G.lineLeadStamp(a, NOW); return (a.at - NOW) .. ' ' .. LEADS")
    check("on and leading: overshoot + 1 steps ahead, the lead started", got == "800 1", got)
    got = run(f"LEADOK = false; local a = {{ fn = 'makeLineCreateCmd', at = {usual} }}; G.lineLeadStamp(a, NOW); return a.at - NOW")
    check("on, the others do not follow yet: the usual stamp", got == 7 * 200, got)
    got = run(f"LEADOK = true; local a = {{ fn = 'makeVehicleBuyCmd', at = {usual} }}; G.lineLeadStamp(a, NOW); return a.at - NOW")
    check("another command: the usual stamp", got == 7 * 200, got)
    got = run("local a = { fn = 'makeLineUpdateCmd', at = NOW + 2 * STEP }; G.lineLeadStamp(a, NOW); return a.at - NOW")
    check("never later than the usual stamp", got == 2 * 200, got)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
