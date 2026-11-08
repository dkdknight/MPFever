"""Test of #156's side fix (0.7.11, mod/mpfever_1/content/mpfever_common.lua, C.makesProposal).

A mod's custom entity commands (makeCustomEntityCreateCmd, ...UpdateTransformationCmd, ...UpdateStateCmd, ...DestroyCmd:
L-Signalsystem's previews) build nothing, but were counted as replayed builds (st.replay.n). In the host's pause of 2026-11-08
the count reached 76 on Julian's game: the player's own next build at that game time would have been taken as a replay and never
shipped (built on one game only), as the industry "extend" was before 0.5.13. Not counted now; the builds are as before.
MPFEVER_CUSTOMCOUNT=1: counted as before. Needs lupa. Run: python tests/test_customcount0711.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
com = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = com.index("local NO_PROPOSAL_PREFIXES = {")
blk = com[i:com.index("\treturn true\nend\n", i) + len("\treturn true\nend\n")]
check('if os.getenv("MPFEVER_CUSTOMCOUNT") ~= "1" then NO_PROPOSAL_PREFIXES[#NO_PROPOSAL_PREFIXES + 1] = "makeCustomEntity" end' in blk,
      "the custom entity commands taken out (MPFEVER_CUSTOMCOUNT=1: as before)")
try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed: the Lua part skipped")
if lupa:
    for env, counted in ((None, False), ("1", True)):
        L = lupa.LuaRuntime(unpack_returned_tuples=True)
        L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; C = {}")
        if env:
            L.execute('ENV.MPFEVER_CUSTOMCOUNT = "' + env + '"')
        L.execute(blk)
        mp = L.eval("C.makesProposal")
        tag = "MPFEVER_CUSTOMCOUNT=1: " if env else ""
        for fn in ("makeCustomEntityCreateCmd", "makeCustomEntityUpdateTransformationCmd", "makeCustomEntityUpdateStateCmd", "makeCustomEntityDestroyCmd"):
            check(bool(mp(fn)) == counted, f"{tag}{fn} {'counted' if counted else 'not counted'}")
        check(mp("makeWorldBuildProposalCmd") is True, f"  {tag}a build still counted")
        check(mp("makeCustomVehicleCreateOrUpdateCmd") is True, f"  {tag}other commands as before (makeCustomVehicle...)")
        check(mp("makeCreateIndustryExtendProposalCmd") is False and mp("makeVehicleBuyCmd") is False and mp("makeLineCreateCmd") is False,
              f"  {tag}the ones taken out before still out")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
