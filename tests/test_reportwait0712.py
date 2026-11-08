"""Test of the fix of the players' reports that never came (0.7.12, issues #157/#161, launcher/ReportShare.cs).

yoyo (2026-11-08, three players, a long session): "The other players' reports received: 0 of 1" at 18:11, "0 of 2" at 19:33.
A player's report is made (Reporter.Collect) before any of it is sent: 20 s and more after a long session (the host's own,
10.7 MB, took 20 s), and the one asking (GatherOthers) gave up after 25 s without news.
Now, while a player's report is made, it sends "report_work" at once and every 8 s; the one asking takes it as news (FeedGather
sets Last), through the host when it is a player who asked; and it waits 4 minutes at most instead of 2.
MPFEVER_REPORTWAIT=0: as before. Run: python tests/test_reportwait0712.py
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


check('static bool ReportWaitOn() => Environment.GetEnvironmentVariable("MPFEVER_REPORTWAIT") != "0";' in rs, "MPFEVER_REPORTWAIT=0: as before")
own = rs[rs.index("void SendOwnReport(string id, string to, string me, Action<Msg> send)"):]
own = own[:own.index("/// <summary>A player: the host's messages about reports")]
check(own.index('send(Msg.Make("report_work", me, "{" + Fields() + "}"));') < own.index("Reporter.Collect("),
      "a word that the report is coming, before it is made")
check("while (!made.WaitOne(8000)) send(Msg.Make(\"report_work\"" in own and "finally { made.Set(); }" in own,
      "  and every 8 s while it is made, stopped once it is made (or failed)")
check(own.index("finally { made.Set(); }") < own.index('Msg.MakeBinary("report_bin"'), "  stopped before its parts are sent")
fg = rs[rs.index("void FeedGather(Msg m)"):]
fg = fg[:fg.index("int i = N(\"i\")")]
check(fg.index("g.Last = DateTime.UtcNow;") < fg.index('if (m.Kind == "report_no")'), "the one asking takes it as news (its wait starts again)")
orm = rs[rs.index("bool OnReportMessage(Msg m, Client client)"):]
orm = orm[:orm.index("return false;")]
check('case "report_work":' in orm, "  a player who asked hears it")
check('if (m.Kind == "report_bin" || m.Kind == "report_no" || m.Kind == "report_work")' in rs, "  the host takes it, or passes it on to the player who asked")
check("TimeSpan.FromMinutes(ReportWaitOn() ? 4 : 2)" in rs and "TimeSpan.FromSeconds(plan ? 25 : 10)" in rs,
      "4 minutes at most instead of 2; 25 s without news still ends the wait (a player gone)")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
