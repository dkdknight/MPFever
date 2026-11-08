"""Offline test of the players' reports in one, sent without a file to drag (0.7.9, launcher/ReportShare.cs, Reporter.AddPlayers /
Upload / IssueBody, MainForm's message handling).

#136 had only a client's report; the cause was in the host's logs. Checked here, the code's side (MPFever.exe --selftest puts
reports together and builds the upload's body, see SelfTest.RunReport079; tests/test_reportservice079.py runs the service):
  - the host asks every player ("report_req"); a player asks the host ("report_ask"), which says who answers ("report_plan"),
    sends its own and asks the others; "report_req" and "report_plan" come from the host only;
  - a report's parts ("report_bin") and refusals ("report_no") go to whoever asked, never to every game;
  - each player's report is made as usual (the personal data taken out), in 64 KB parts, at most 24 MB; reportshare=0 (or
    MPFEVER_REPORTSHARE=0) refuses, and asks for none;
  - the wait ends when every player answered, after 25 s without news (10 s without the host's plan: an older host), or 2
    minutes; who did not answer is said in players.txt;
  - the report goes to the report service (the server list's address + /api/report): an issue opened there is shown in the
    browser; a link only: a new issue with the link; out of reach: as before (the zip shown, an issue to drag it into).
    reportupload=0 (or MPFEVER_REPORTUPLOAD=0): as before.
Run: python tests/test_reportshare079.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8").read().replace("\r\n", "\n")


fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


rs = read("launcher", "ReportShare.cs")
mf = read("launcher", "MainForm.cs")
rp = read("launcher", "Reporter.cs")

ho = mf[mf.index("static readonly HashSet<string> HostOnlyKinds"):][:700]
check('"report_req", "report_plan"' in ho, "report_req and report_plan: the host's only")
ohm = mf[mf.index("        void OnHostMessage(Msg m, Peer from)"):]
check(ohm.index("if (OnHostReportMessage(m, from)) return;") < ohm.index("            switch (m.Kind)"), "the host handles the reports' messages before anything is passed on")
check(ohm.index("HostOnlyKinds.Contains(m.Kind)") < ohm.index("OnHostReportMessage"), "  after a player's host-only message is dropped")
check("if (OnReportMessage(m, client)) return;" in mf, "a player handles the host's report messages")
check('reportMe = youName;' in mf, "  knows its name in the session from the host's welcome")
hr = rs[rs.index("        bool OnHostReportMessage("):]
check('if (to == hostName) { FeedGather(m); return true; }' in hr and "var p = relay?.Find(to);" in hr and "relay.TrySend(p, m);" in hr
      and "relay.Broadcast(m" not in hr, "parts go to whoever asked (the host or one player), never to every game")
check('Msg.Make("report_plan"' in hr and "relay.Broadcast(req, from);" in hr and "SendOwnReport(id, asker, hostName" in hr,
      "  a player's ask: who answers said back, the others asked, the host's own sent")
sr = rs[rs.index("        void SendOwnReport("):]
check("Reporter.Collect(" in sr and "ReportPart" in sr and "ReportShareMax" in sr and '"report_no"' in sr and "reportshare=0" in sr,
      "each player's report made as usual, in parts, at most 24 MB; reportshare=0: refused")
check("const int ReportPart = 64 * 1024;" in rs and "const long ReportShareMax = 24L * 1024 * 1024;" in rs, "  64 KB parts, 24 MB at most")
check('SettingOff("reportshare", "MPFEVER_REPORTSHARE")' in rs and 'SettingOff("reportupload", "MPFEVER_REPORTUPLOAD")' in rs,
      "reportshare=0 / reportupload=0 in mpfever_settings.txt, MPFEVER_REPORTSHARE=0 / MPFEVER_REPORTUPLOAD=0")
go = rs[rs.index("        internal Dictionary<string, byte[]> GatherOthers("):]
check("if (!ReportShareOn()) return none;" in go and "TimeSpan.FromSeconds(plan ? 25 : 10)" in go and "TimeSpan.FromMinutes(ReportWaitOn() ? 4 : 2)" in go,
      "the wait: every answer, 25 s without news (10 s without the plan), 4 minutes at most (0.7.12; MPFEVER_REPORTWAIT=0: 2)")
check('notes.Add(e + ": no answer' in go and "Reporter.AddPlayers(zip, others, notes);" in rs, "  who did not answer said in players.txt")
rep = rs[rs.index("        void Report(bool crashed)"):]
rep = rep[:rep.index("        void OpenUrl(")]
check('Reporter.Upload(ServerListUrl() + "/api/report"' in rep and "OpenUrl(up.Issue);" in rep and "Reporter.OpenIssue(title, b);" in rep,
      "sent to the report service: its issue shown, or a new issue with the link")
check(rep.index("catch (Exception e) { Log.W(F(\"Envoi du rapport impossible") < rep.index("Reporter.ShowInExplorer(zip);"), "  out of reach: as before")
check("public static void AddPlayers(" in rp and '"players/" + SafeName(kv.Key) + "/"' in rp and 'name.Contains("..")' in rp,
      "the players' reports under players/<name>/, no path out of it")
check("BitConverter.GetBytes(json.Length).CopyTo(all, 0);" in rp, "the upload's body: a length, the JSON, the zip (as serverlist/Reports.cs reads it)")
check("if (Redact.IsText(e.Name)) Redact.Copy(src, dst);" in rp, "the personal data still taken out of every report")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
