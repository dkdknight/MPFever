"""Offline test (0.8.16, #359): a report over the service's limit cuts the drift dumps last.

Kasper and Eier's #359 report: both games' first-drift dumps (sdump_drift_first) held only their last part, alike: the report was
over the report service's limit, and Reporter.Shrink cut the largest text files to their last half, the dumps first (the
largest), so the towns' part (at their start) was gone and the first difference could not be found.
  - Reporter.DriftDump: sdump_drift*, drift_* and native_drift.txt; MPFEVER_REPORTKEEPDRIFT=0: none;
  - CutLargest: a first pass over every text but the drift dumps, the dumps only when nothing else is left to cut;
  - the launcher's selftest builds such a report and checks that the dump keeps its start (MPFever.exe --selftest, run by
    build.bat and the CI).
Run: python tests/test_reportkeepdrift0816.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "launcher", "Reporter.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


d = src[src.find("internal static bool DriftDump(string name)"):]
d = d[:d.find("\n        }\n") + 10]
check("DriftDump" in d, "Reporter.DriftDump found")
# (0.8.17, #393: and the segments' stamps, sdump_epochs_*, see test_epochdump0817.py)
check('n.StartsWith("sdump_drift") || n.StartsWith("sdump_epochs") || n.StartsWith("drift_") || n == "native_drift.txt"' in d, "  the drift dumps by their names")
check('"MPFEVER_REPORTKEEPDRIFT") == "0") return false' in d, "  MPFEVER_REPORTKEEPDRIFT=0: none kept")
c = src[src.find("static string CutLargest(ref byte[] zipBytes)"):]
c = c[:c.find("if (best == null || bestLen < 64 * 1024) return null;")]
check("for (int pass = 0; pass < 2" in c and "bool dumpsToo = pass == 1;" in c, "CutLargest: two passes")
check(c.count("(dumpsToo || !DriftDump(") == 2, "  the dumps left out of the first pass, in the report and in a player's report inside it")
check("0.8.16: a drift dump keeps its start, the logs are cut first" in st, "the launcher's selftest checks it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
