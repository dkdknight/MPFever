"""Offline test of #146 (0.7.11): one problem report at a time, whichever button asked (launcher/ReportShare.cs, Report).

Domenik, 2026-11-08 15:55: two clicks a few seconds apart made two reports (#145 and #146); the second one asked the other
players while the first one's wait was under way, replaced it, and got no other player's report ("Tim: no answer"). The
in-game button had a guard of its own, the launcher's button none. Now Report itself refuses a second report while one is
being made (MPFEVER_REPORTONE=0: as before). Run: python tests/test_reportone0711.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
rs = open(os.path.join(ROOT, "launcher", "ReportShare.cs"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


r = rs[rs.index("        void Report(bool crashed)"):]
r = r[:r.index("        void ReportOnce(bool crashed)")]
check('Environment.GetEnvironmentVariable("MPFEVER_REPORTONE") != "0" && System.Threading.Interlocked.CompareExchange(ref reportRunning, 1, 0) != 0' in r,
      "a report while another one is being made is refused (MPFEVER_REPORTONE=0: as before)")
check("try { ReportOnce(crashed); }" in r and "finally { System.Threading.Interlocked.Exchange(ref reportRunning, 0); }" in r,
      "  the next one is allowed once it is done, whatever happened")
check(r.index("CompareExchange") < r.index("ReportOnce(crashed)"), "  checked before anything is made")
check("void ReportOnce(bool crashed)" in rs and "GatherOthers(notes)" in rs[rs.index("void ReportOnce(bool crashed)"):], "the report itself unchanged, in ReportOnce")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
