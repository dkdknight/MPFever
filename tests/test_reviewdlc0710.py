"""Offline test of a regression of 0.7.8 (fixed in 0.7.10): the join review opens again when this PC's DLCs are not the host's
game's (launcher/MainForm.cs, JoinReviewClear / CheckHostDlcs).

The join review (0.7.0, the user's request of 2026-11-05): a player joining a game already running sees its mods and DLCs on
the Multiplayer page and presses « Join the game » first. It opened when something differed, the DLCs among them. 0.7.8 dropped
the "different DLCs" warning (DLCSESSION: an unused DLC does nothing, a used one is switched off for the session), and the
review, which opened on that warning, no longer showed for most players (the user, 2026-11-08: « la dernière mise à jour a
retiré le salon »). Now:
  - any difference between the host's game's DLCs and this PC's (either way) opens the review, as before 0.7.8;
  - the same mods and DLCs still join at once (the 0.7.0 design), a player who accepted already too;
  - the difference is forgotten with the host (the three places the DLC warning is reset);
  - MPFEVER_REVIEWDLC=0: as 0.7.8.
See docs/REGRESSIONS.md. Run: python tests/test_reviewdlc0710.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
form = open(os.path.join(ROOT, "launcher", "MainForm.cs"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


jr = form[form.index("        bool JoinReviewClear()"):]
jr = jr[:jr.index("\n        }\n")]
check("bool dlcs = !dlcsDiffer || Environment.GetEnvironmentVariable(\"MPFEVER_REVIEWDLC\") == \"0\";" in jr
      and "return mods && dlcs && string.IsNullOrEmpty(PlayerDlcWarn());" in jr, "different DLCs: the review opens (MPFEVER_REVIEWDLC=0: as 0.7.8)")
check("c.Missing.Count == 0 && c.Differs.Count == 0 && c.Bad.Count == 0" in jr, "  missing, other-version and incompatible mods still open it")
ch = form[form.index("        void CheckHostDlcs("):]
ch = ch[:ch.index("\n        }\n")]
check("dlcsDiffer = !string.IsNullOrEmpty(hostList) && (hostOnly.Count > 0 || mineOnly.Count > 0);" in ch
      and ch.index("Mods.DlcDiff(hostList, mine)") < ch.index("dlcsDiffer ="), "  either way, whatever the warnings say; an older host that says nothing: no difference")
# (0.8.1: and where an old copy of a mod is moved out, the host's mods compared again)
check(form.count('lastHostDlcs = null; dlcWarn = ""; dlcsDiffer = false;') == 4, "  forgotten with the host, where the DLC warning is")
check("if (review && (always || !JoinReviewClear()) && reviewAccepted != key)" in form and "else send(false);" in form,
      "the review every time (the user's choice, 0.7.10), with MPFEVER_REVIEWALWAYS=0 only when something differs; accepted already: joins at once")
check(os.path.isfile(os.path.join(ROOT, "docs", "REGRESSIONS.md")) and "join review" in open(os.path.join(ROOT, "docs", "REGRESSIONS.md"), encoding="utf-8").read(),
      "docs/REGRESSIONS.md records it")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
