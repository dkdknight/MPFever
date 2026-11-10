"""Offline test: a report over what MPFever's report service takes is cut to fit (0.7.17, issue #195; Reporter.Shrink,
CutLargest, HalfTail in launcher/Reporter.cs, ReportOnce in launcher/ReportShare.cs).

#195 (CowboyPilot, three players): MPFever-report-20261109-174412.zip was 32 MB, the service takes 32 MB at most
(serverlist/Reports.cs MaxReport): it was refused and the player was asked to upload it by hand.
  - before the upload, the report is cut to Reporter.ServiceLimit (31 MB) when it is larger: its largest text log (a player's
    report.zip inside too) keeps its last half, again until it fits; report.txt and players.txt never;
  - MPFEVER_REPORTTRIM=0: as before;
  - the launcher's self-test (RunTrim0717) builds a report with a player's report inside and cuts it.
Run: python tests/test_reporttrim0717.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
rp = open(os.path.join(L, "Reporter.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
rs = open(os.path.join(L, "ReportShare.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
sv = open(os.path.join(HERE, "..", "serverlist", "Reports.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


m = re.search(r"MaxReport = (\d+) \* 1024 \* 1024", sv)
check(m and "internal const long ServiceLimit = 31L * 1024 * 1024;" in rp and int(m.group(1)) >= 32, "ServiceLimit under the service's MaxReport")
sh = rp[rp.index("public static List<string> Shrink("):]
sh = sh[:sh.index("\n        }\n")]
check('Environment.GetEnvironmentVariable("MPFEVER_REPORTTRIM") == "0"' in sh, "MPFEVER_REPORTTRIM=0: as before")
check("if (size <= max) return cuts;" in sh and "CutLargest(ref bytes)" in sh, "cut one log at a time until it fits")
t = rp[rp.index("internal static bool TrimmableText("):]
t = t[:t.index(";\n") + 2]
check('"report.txt"' in t and '"players.txt"' in t, "report.txt and players.txt never cut")
check('EndsWith("report.zip"' in rp and "bestInner" in rp, "a player's report inside is looked into")
o = rs[rs.index("void ReportOnce(bool crashed)"):]
check(o.index("Reporter.Shrink(zip, Reporter.ServiceLimit)") < o.index("Reporter.Upload("), "cut before the upload, only when uploading")
check("ok &= RunTrim0717();" in st and "Reporter.Shrink(zip, before / 3)" in st, "the launcher's self-test runs it")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
