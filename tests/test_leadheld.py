"""Offline test of the builder's lead for the tools that had none (0.6.12, the user's test of 2026-11-03 23:17).

A station's or warehouse's module tool sends no tool event, and the street and track upgrade tool was not among the lead
tools: their builds waited 16 steps (x4) on the builder's game and held the others for seconds. Now the upgrade tool leads, and
a build held although no lead tool was in hand starts the lead (G.leadFromBuild), so that the next ones are released at once.
G.buildLeadTool and G.leadFromBuild run through lupa (Lua 5.2) with a mocked clock and lead.
Cases: streetTrackModifier is a lead tool (MPFEVER_LEADTOOLS=0: not); a build held for "no tool in hand" starts the lead; a
lead running keeps going with every build; a build held for another reason does not start one; MPFEVER_LEADHELD=0: never;
nothing without BUILDLEAD or while a peer does not take part.
Run: python tests/test_leadheld.py
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
    m = re.search(r"^G\.BUILD_LEAD_TOOLS = .*?^G\.leadFromBuild = function\(lead, why\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        return None
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {} os.getenv = function(k) return ENV[k] end NOW = 100 os.clock = function() return NOW end")
    for k, v in env.items():
        L.execute(f'ENV.{k} = "{v}"')
    L.execute("""
G = { buildLead = true }
PEERS = true
G.buildLeadPeers = function() return PEERS end
LEADS = {}
terrainLead = function(why, what) LEADS[#LEADS + 1] = why; G.buildLeadUntil = os.clock() + 60 end
""" + m.group(0))
    return L.eval("function(code) return assert(load(code))() end")


def main():
    run = runtime({})
    check("G.BUILD_LEAD_TOOLS .. G.leadFromBuild found", run is not None)
    if run is None:
        return 1
    src = open(BRIDGE, encoding="utf-8").read()
    check("asked after each tool build's lead decision (not in a pause), and by the autotests' builds with MPFEVER_LEADHELDTEST=1",
          "if not paused then pcall(G.leadFromBuild, lead, why) end" in src
          and 'if not paused and os.getenv("MPFEVER_LEADHELDTEST") == "1" then pcall(G.leadFromBuild, lead, why) end' in src)
    check("the street and track upgrade tool leads", run("return tostring(G.buildLeadTool('streetTrackModifier'))") == "true")
    check("the five tools of before still lead", run("return tostring(G.buildLeadTool('streetBuilder') and G.buildLeadTool('bulldozer'))") == "true")
    check("a build held with no lead tool in hand starts the lead", run("G.leadFromBuild(false, 'no tool in hand'); return #LEADS") == 1)
    check("a running lead keeps going with each build", run("NOW = 130; G.leadFromBuild(true); return #LEADS") == 2)
    check("a build held for another reason starts none", run("LEADS = {}; G.buildLeadUntil = nil; G.leadFromBuild(false, 'this game is held for a build or an action'); return #LEADS") == 0)
    check("nothing while a peer does not take part", run("PEERS = false; G.leadFromBuild(false, 'no tool in hand'); PEERS = true; return #LEADS") == 0)
    check("nothing without BUILDLEAD", run("G.buildLead = false; G.leadFromBuild(false, 'no tool in hand'); G.buildLead = true; return #LEADS") == 0)
    run = runtime({"MPFEVER_LEADHELD": "0", "MPFEVER_LEADTOOLS": "0"})
    check("MPFEVER_LEADHELD=0: never", run("G.leadFromBuild(false, 'no tool in hand'); return #LEADS") == 0)
    check("MPFEVER_LEADTOOLS=0: the upgrade tool does not lead, as before", run("return tostring(G.buildLeadTool('streetTrackModifier'))") == "false")
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
