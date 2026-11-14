"""Test of #298's fix (0.8.8, native/mpfever_native.cpp: TerrainCapture; the autotest H.terrain's MPFEVER_TERRAIN_CANON).

One company per player, chris + dujuk + Wretched, 2026-11-14 01:34: chris's eleven edits with the terrain tools took 2.4 M from
company 1 (the savegame's, the host's) on chris's game only; every other game charged chris's company 3 (their replay names
it); the host's figures put chris's game right 30 s later. The terrain tools' command is the only tool's command that reaches
the engine naming the savegame's company: the other tools' builds are held at CommandList::Add, where OwnerFix gives them this
machine's company, and the terrain tools cannot be held. An edit made on this machine (not a replay) that names the savegame's
company now gets this machine's before the engine applies it. MPFEVER_TERRAINOWNER=0: as before.

The native module cannot run here: this checks the source (the place, the conditions, the switch); the autotest
MPFEVER_SCENARIO=terrain with MPFEVER_COMPANIES=separate and MPFEVER_TERRAIN_CANON=1 measures it in game (the client's edit
named for the savegame's company: its company pays on every game, no correction by the host).
Run: python tests/test_terrainowner088.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
bridge = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r"^static void TerrainCapture\(u8\* pay\)\n\{\n.*?^\}\n", nat, re.S | re.M)
check(m is not None, "TerrainCapture found")
body = m.group(0) if m else ""
i_replay = body.find('"terrain: replayed edit applied ("')
i_fix = body.find("*(u32*)(pay + 0x36c) = (u32)local;")
i_id = body.find("long id = _InterlockedIncrement(&g_tSeq);")
check(0 < i_replay < i_fix < i_id, "the company is set after the replays are told apart (they return before it) and before the edit is copied",
      (i_replay, i_fix, i_id))
check("if (on && canon && local && canon != local && *(u32*)(pay + 0x36c) == (u32)canon) {" in body,
      "only with one company per player known here, another company than the savegame's, and a command naming the savegame's")
check('GetEnvironmentVariableA("MPFEVER_TERRAINOWNER", v, 3) > 0 && v[0] == \'0\'' in body, "MPFEVER_TERRAINOWNER=0: as before")
check('"terrain: this machine\'s edit paid by its company "' in body and "shown++ < 20" in body, "said in native.log (20 times at most)")
# the too-large edit leaves before: nothing copied, nothing changed
i_big = body.find('"terrain: edit of "')
check(0 < i_big < i_replay, "an edit too large to copy: left as it is (the mod reloads the games)")
# the context player is read by the apply after TerrainCapture
ab = nat[nat.index("static u64 ApplyBody(void* a, void* b, bool inLoop)\n{"):]
ab = ab[:ab.index("\n}\n")]
check(0 < ab.find("if (kind == 52) TerrainCapture(pay);") < ab.find("long cp = *(long*)(pay + 0x36c);"),
      "the engine's apply reads the command's company after it")

h = bridge[bridge.index("H.terrain = function(from, p)"):]
h = h[:h.index("\nend\n")]
check('if os.getenv("MPFEVER_TERRAIN_CANON") == "1" and G.co and G.co.canon then\n\t\t\t\tctx.player = G.co.canon\n' in h,
      "the autotest's edit can name the savegame's company, as the tools' (MPFEVER_TERRAIN_CANON=1)")
check(h.index("ctx.player = api.engine.util.getPlayer()") < h.index("MPFEVER_TERRAIN_CANON"), "    without it: this game's company, as before")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
