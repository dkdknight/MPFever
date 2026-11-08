"""The check after a difference dumps every vehicle whole on every game, and every dump gives each vehicle's state hash
(0.7.7, RequestHash / WantsWorldDump in launcher/MainForm.cs, H.hash and extendedParts in the bridge).

The user's server and PC, 2026-11-08 02:40, a reload on "vehicles": the dumps of t=49442400 (the check's number chose them on both
games) showed every vehicle alike, the check of t=49452600 found them apart, and no dump of the vehicles came before the reload:
the vehicle that went otherwise first could not be told. The dump's line of a vehicle also showed only the first 160 characters
of its state, while the check hashes all of it. Now:
  - a check that finds a part of the simulation apart (not money, which the host corrects, the names or a diagnostic part) makes
    the launcher ask the next check with world=true, the same request to every game;
  - the bridge carries it to the dump (running and paused checks): the world part, every vehicle's whole state;
  - every vehicle's line ends with the hash of its whole state (C.hashStr of the text the check hashes);
  - MPFEVER_SDUMPAFTER=0: not.
The launcher's self-test (RunReport077) runs WantsWorldDump.
Run: python tests/test_sdumpafter077.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
mf = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
br = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check("if (diffs.Any(d => WantsWorldDump(DiffKey(d)))) worldDumpNext = true;" in mf, "a check with a part of the simulation apart asks for it")
r = mf[mf.index("void RequestHash()"):]
r = r[:r.index("\n        }\n")]
check('if (worldDumpNext) { worldDumpNext = false; if (Environment.GetEnvironmentVariable("MPFEVER_SDUMPAFTER") != "0") world = ",[\\"world\\"]=true"; }' in r,
      "  the next request carries it, once (MPFEVER_SDUMPAFTER=0: not)")
check(r.count("+ world + \"}\"") == 2, "  running and paused checks alike")
w = mf[mf.index("internal static bool WantsWorldDump(string part)"):][:300]
check('part != "money" && part != "names"' in w and "!DiagnosticParts.Contains(part)" in w, "not for money, names or a diagnostic part")
h = br[br.index("H.hash = function(from, p)"):][:700]
check("local w = p.world == true or nil" in h and h.count("world = w }") == 2, "the bridge keeps it on the queued check, running or paused")
check(br.count("SDUMP.forceWorld = a.world == true") == 2 and br.count("SDUMP.forceWorld = nil") == 2, "  set around both checks' hash, cleared after")
e = br[br.index("local function extendedParts(parts, checkN)"):]
e = e[:e.index("\nend\n")]
check('local forced = SDUMP.forceWorld == true and os.getenv("MPFEVER_SDUMPAFTER") ~= "0"' in e and "worldTurn or forced or" in e,
      "the dump: its world part at that check")
check('(forced and whole or whole:sub(1, 160)) .. " #" .. tostring(C.hashStr(0, whole))' in e,
      "every vehicle with the hash of its whole state, the whole state at that check")
check("local parts = R.contentHash(C.hashStr, C.dump)" in br, "  the text the check hashes (C.dump)")
check("MainForm.WantsWorldDump(\"vehicles\")" in st, "the launcher's self-test runs WantsWorldDump")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
