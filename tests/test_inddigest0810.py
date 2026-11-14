"""Offline test (0.8.10, #317): the sync check reads only the end of each industry rule's application history.

BeunHaas34, 2026-11-14 (0.8.8, a small map, two players): the check every 10 s grew from 0.01 s to 2 to 8.7 s in two hours, the
games froze every 10 s; it stayed so after a resynchronisation (the same save) and fell back with a new game only. The
industries' digest (0.8.6) and the dump's stock lists turned every rule's whole applyHistory (every application since the
industry was founded, saved with the game) into text at every check. An autotest on Test Gameplay reproduced the growth
(0.40 s -> 0.65 s of check in 3 minutes, mostly outside the listed parts).
  - K.ruleDatasText: each rule's history length, decay factor and its last K.RULE_TAIL (4) applications;
    MPFEVER_INDDIGESTFULL=1: the whole history (C.dump(sl.ruleDatas)), as before;
  - K.industriesDigest and SDUMP.stocks use it (never the whole sl / sl.ruleDatas without the switch);
  - the check's diagnostic parts are timed ("y.contentHash", "y.stepsDigest", "y.industriesDigest").
Run: python tests/test_inddigest0810.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def block(src, start, end_marker):
    i = src.find(start)
    return src[i:src.find(end_marker, i + len(start))] if i >= 0 else ""


def main():
    src = open(BRIDGE, encoding="utf-8-sig").read().replace("\r\n", "\n")
    rt = block(src, "K.ruleDatasText = function(sl)", "\nend\n")
    check(rt != "", "K.ruleDatasText found")
    check("K.RULE_TAIL = 4" in src, "  the last 4 applications kept")
    check('os.getenv("MPFEVER_INDDIGESTFULL") == "1" then return C.dump(sl.ruleDatas) end' in rt, "  MPFEVER_INDDIGESTFULL=1: whole, as before")
    check("math.max(1, n - K.RULE_TAIL + 1), n do" in rt, "  only the tail of applyHistory is dumped")
    check("tostring(n)" in rt and "lastApplyDecayFactor" in rt, "  the history's length and decay factor still hashed")

    ind = block(src, "K.industriesDigest = function()", "\nend\n")
    check(ind != "", "K.industriesDigest found")
    check("K.ruleDatasText(sl)" in ind, "  the digest uses the bounded text")
    check("C.dump(sl.ruleDatas)" not in ind, "  never the whole histories")
    check('os.getenv("MPFEVER_INDDIGEST") == "0" then return nil end' in ind, "  MPFEVER_INDDIGEST=0 still turns it off")

    st = block(src, "function SDUMP.stocks(dump)", "\nend\n")
    check(st != "", "SDUMP.stocks found")
    check("K.ruleDatasText(sl)" in st, "  the dump's stock lists use the bounded text")
    check(re.search(r"full and C\.dump\(sl\)|if full then whole = C\.dump\(sl\)", st) is not None, "  the whole stock list only with the switch")
    check("pcall(function() return C.dump(sl.stocks)" in st, "  the bounded text under pcall")

    sh = block(src, "local function simHash(", "\nend\n")
    check('costs["y." .. k] = v' in sh, "check's diagnostic parts timed (y.*)")
    for k in ("contentHash", "stepsDigest", "industriesDigest"):
        check("yCost." + k in sh or "{ " + k + " =" in sh, "  y." + k)

    print()
    if fails:
        print("FAILED: %d" % len(fails))
        sys.exit(1)
    print("all ok")


if __name__ == "__main__":
    main()
