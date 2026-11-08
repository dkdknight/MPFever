"""Offline test: a build refused on every game, its builder's too, reloads nothing (0.7.7, "replay_failed" in
launcher/MainForm.cs, FailedUid / RefusedEverywhere, H.replay_alike in the bridge).

Test Gameplay, two games and two computer companies, 2026-11-08 01:30: an AI garage (Host:58) was refused by the engine on both
games, the host's too (a computer company's builds are replayed on the host's game as well): nobody built it, the games did not
part. Each "replay_failed" reloaded every game (needless, in a real session); in the autotests (no reload) the player's game
then left the next build out for 45 s (G.brokenSkip, #113), waiting for a reload that never came: the AI's next garage (Host:60)
stood on the host's game only, "DÉSYNCHRONISÉ" for the rest of the test. The launcher now waits the 1.5 s it waited before its
reload and, when every game and the builder's say they refused it, tells every game (replay_alike: the hold ends) and reloads
nothing; otherwise as before. MPFEVER_FAILALIKE=0: as before. The launcher's self-test (RunReport077) runs FailedUid and
RefusedEverywhere.
Run: python tests/test_failalike077.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read()
br = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


c = mf[mf.index('case "replay_failed":'):]
c = c[:c.index('case "save_done":')]
check('Environment.GetEnvironmentVariable("MPFEVER_FAILALIKE") != "0" && fuid != null' in c, "MPFEVER_FAILALIKE=0: as before")
check("who.Add(BaseName(m.From));" in c and "first = true;" in c, "the games that refused each build, counted by its uid")
t = c[c.index("if (alikeOn && first)"):]
check(t.find("Thread.Sleep(1500);") < t.find("RefusedEverywhere(fuid, who, all.Select(BaseName))") < t.find("Resync(T(\"construction non reproduite\""),
      "the reports waited for 1.5 s, as before; refused everywhere looked at before the reload")
check('Msg.Make("replay_alike"' in t and "relay.Broadcast(alike, null)" in t and "return;" in t[:t.index("int oth;")],
      "  then every game told, and no reload")
check("if (started && !resyncing && !autotest && oth > 0 && Now - lastResync > 15)" in t, "  otherwise the reload, under the same conditions as before")
check("else if (!alikeOn && started && !resyncing && !autotest && others > 0 && Now - lastResync > 15)" in c, "  switched off: the old reload unchanged")
r = mf[mf.index("internal static bool RefusedEverywhere("):]
r = r[:r.index("\n        }\n")]
check("if (!set.Contains(builder)) return false;" in r and "if (!set.Contains(BaseName(p))) return false;" in r,
      "RefusedEverywhere: the builder's game and every player's")
h = br[br.index("H.replay_alike = function(from, p)"):]
h = h[:h.index("\nend\n")]
check("tostring(p.uid) == b.uid" in h and "G.replayBroken = nil" in h, "the bridge: the hold of that build ends (G.brokenSkip)")
check("RefusedEverywhere(\"Host:58\"" in st and "FailedUid(" in st, "the launcher's self-test runs them")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
