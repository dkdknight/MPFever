using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>(0.7.9) "Report a problem" with every player's logs, sent without a file to drag anywhere.
    ///
    /// Issue #136 had the report of one player only (a client), and what told the cause (the host's game ran an old copy of
    /// MPFever's mod) was in the host's logs: one more round of messages and a day lost. Now the player who makes a report gets
    /// the others' too, through the session's own connections (the host relays, as for everything else):
    ///   - the host asks every player: "report_req" {id, to}; each MPFever makes its own report as usual (Reporter.Collect: the
    ///     personal data taken out) and sends it back in "report_bin" parts {id, to, who, i, n}, or "report_no" {id, to, who, why}
    ///     when its player turned the sharing off (reportshare=0 in mpfever_settings.txt);
    ///   - a player asks the host ("report_ask" {id}): the host answers who will answer ("report_plan" {id, who}), sends its own
    ///     report and asks the others for theirs, and passes their parts on to that player alone;
    ///   - the reports that came within the wait (25 s without news, 2 minutes at most) go into the zip under players\&lt;name&gt;\,
    ///     players.txt says who answered and who did not (an MPFever before 0.7.9 says nothing).
    /// Then the zip goes to MPFever's report service (the server list's PC, POST /api/report, see serverlist\Reports.cs), which
    /// keeps it and opens the GitHub issue itself: the browser shows that issue. A service without GitHub key gives the file's
    /// link: the browser opens a new issue with it, sent by the player. The service out of reach: as before (the zip shown in
    /// the Explorer, a new issue to drag it into). reportupload=0 in mpfever_settings.txt, or MPFEVER_REPORTUPLOAD=0: as before;
    /// MPFEVER_REPORTSHARE=0: neither asked nor sent.</summary>
    sealed partial class MainForm
    {
        /// <summary>This player's name in the session, from the host's welcome (a client).</summary>
        string reportMe;

        sealed class ReportGather
        {
            public string Id;
            public readonly HashSet<string> Expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            public bool PlanKnown;
            public readonly Dictionary<string, byte[][]> Parts = new Dictionary<string, byte[][]>(StringComparer.OrdinalIgnoreCase);
            public readonly Dictionary<string, byte[]> Got = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            public readonly Dictionary<string, string> Refused = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            public DateTime Last = DateTime.UtcNow;
            public int Answered => Got.Count + Refused.Count;
        }
        ReportGather gather;
        readonly object gatherGate = new object();
        const int ReportPart = 64 * 1024;
        const long ReportShareMax = 24L * 1024 * 1024;

        static bool SettingOff(string key, string env)
        {
            if (Environment.GetEnvironmentVariable(env) == "0") return true;
            try { return LoadSettings().TryGetValue(key, out var v) && (v.Trim() == "0" || v.Trim().Equals("off", StringComparison.OrdinalIgnoreCase)); } catch { return false; }
        }
        internal static bool ReportShareOn() => !SettingOff("reportshare", "MPFEVER_REPORTSHARE");
        static bool ReportUploadOn() => !SettingOff("reportupload", "MPFEVER_REPORTUPLOAD") && ServerListUrl() != "";

        /// <summary>The session as report.txt and the issue describe it.</summary>
        string ReportSummary(bool crashed, string forWhom = null)
        {
            var sb = new System.Text.StringBuilder();
            sb.AppendLine("MPFever " + Version + ", game build " + Reporter.GameBuild(gameDir));
            // (after the game closed: the session it left then, see LeaveOnGameExit)
            sb.AppendLine(leftSession ?? SessionLines(false));
            sb.AppendLine("Settings changed: " + Options.Changed() + (GameInstall.DiagOn() ? "; DIAGNOSTIC BUILD (free-id log, state dumps)" : ""));
            sb.AppendLine("Sync: " + syncText + "; desyncs " + desyncs + ", resynchronisations " + resyncId + ", actions relayed " + actsRelayed + ", refused " + actRefused);
            sb.AppendLine("Processor: " + Reporter.Processor() + "; " + Reporter.WindowsVersion());
            // (0.6.9: the game's DLCs here, and what differs from the host's or a player's)
            sb.AppendLine("DLCs: " + Mods.InstalledDlcs() + (PlayerDlcWarn() != "" ? " | " + PlayerDlcWarn() : "") + (HostDlcWarn() != "" ? " | " + HostDlcWarn() : ""));
            sb.AppendLine("Report made " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + (crashed ? " after a crash of the game" : "")
                + (forWhom != null ? " for " + forWhom + "'s report" : ""));
            return sb.ToString();
        }

        // (0.7.11, #146) one report at a time, whichever button asked: two clicks a few seconds apart (the launcher's button has
        // no guard of its own) made two reports, and the second one, asking while the first one's wait was under way, got no
        // other player's report (its request replaced the first one's). MPFEVER_REPORTONE=0: as before
        int reportRunning;

        void Report(bool crashed)
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_REPORTONE") != "0" && System.Threading.Interlocked.CompareExchange(ref reportRunning, 1, 0) != 0)
            {
                Log.W(F("Rapport déjà en cours de création : demande ignorée.", "A report is already being made: request ignored."));
                return;
            }
            try { ReportOnce(crashed); }
            finally { System.Threading.Interlocked.Exchange(ref reportRunning, 0); }
        }

        void ReportOnce(bool crashed)
        {
            try
            {
                var summary = ReportSummary(crashed);
                List<string> left;
                var dirs = games.Select(g => g.Dir).ToList();
                var zip = Reporter.Collect(dirs, summary, out left);
                if (left.Count > 0) Log.W(F("Laissés de côté (trop gros) : {0}", "Left out (too large): {0}", string.Join(", ", left)));
                // the other players' reports (a session with others)
                var notes = new List<string>();
                var others = GatherOthers(notes);
                if (others.Count > 0 || notes.Count > 0) Reporter.AddPlayers(zip, others, notes);
                long size = new FileInfo(zip).Length;
                Log.Ok(F("Rapport de problème : {0} ({1:0.0} Mo)", "Problem report: {0} ({1:0.0} MB)", zip, size / 1048576.0));
                var title = (crashed ? "Crash" : "Problem") + " (MPFever " + Version + ", " + (ReportCompanyMode() == "separate" ? "separate companies" : "shared company") + ")";
                if (ReportUploadOn())
                {
                    ReportAnswer(T("Envoi du rapport...", "Sending the report..."));
                    try
                    {
                        var up = Reporter.Upload(ServerListUrl() + "/api/report", zip, title, Reporter.IssueBody(Path.GetFileName(zip), size, summary, crashed, sent: true, players: others.Keys.ToList()));
                        if (up.Issue != "")
                        {
                            Log.Ok(F("Rapport envoyé : {0}", "Report sent: {0}", up.Issue));
                            OpenUrl(up.Issue);
                            ReportAnswer(F("Rapport envoyé, merci ! Issue : {0}", "Report sent, thank you! Issue: {0}", up.Issue));
                            return;
                        }
                        if (up.File != "")
                        {
                            var b = Reporter.IssueBody(Path.GetFileName(zip), size, summary, crashed, link: up.File, players: others.Keys.ToList());
                            try { BeginInvoke((Action)(() => { try { Clipboard.SetText(b); } catch { } })); } catch { }
                            Reporter.OpenIssue(title, b);
                            Log.Ok(F("Rapport envoyé ({0}) : la page de l'issue GitHub est ouverte avec son lien, il reste à l'envoyer.", "Report uploaded ({0}): the GitHub issue page is open with its link, just send it.", up.File));
                            ReportAnswer(T("Rapport envoyé : la page de l'issue GitHub est ouverte avec son lien, il reste à l'envoyer.", "Report uploaded: the GitHub issue page is open with its link, just send it."));
                            return;
                        }
                    }
                    catch (Exception e) { Log.W(F("Envoi du rapport impossible ({0}) : à joindre à la main.", "Could not send the report ({0}): attach it by hand.", e.Message)); }
                }
                // (as before 0.7.9: the zip shown, a new issue to drag it into)
                var body = Reporter.IssueBody(Path.GetFileName(zip), size, summary, crashed, players: others.Keys.ToList());
                try { BeginInvoke((Action)(() => { try { Clipboard.SetText(body); } catch { } })); } catch { }
                Reporter.ShowInExplorer(zip);
                Reporter.OpenIssue(title, body);
                ReportAnswer(F("Rapport prêt : {0}. La page de l'issue GitHub est ouverte dans le navigateur : glissez-y ce fichier.", "Report ready: {0}. The GitHub issue page is open in your browser: drag that file into it.", Path.GetFileName(zip)));
            }
            catch (Exception e)
            {
                Log.Err(F("Rapport de problème impossible : {0}", "Could not make the problem report: {0}", e.Message));
                ReportAnswer(F("Rapport impossible : {0}", "Could not make the report: {0}", e.Message));
            }
        }

        void OpenUrl(string url)
        {
            if (autotest) return;
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception e) { Log.W("report: " + e.Message); }
        }

        /// <summary>The other players' reports for this one (by their names), within the wait; `notes` says who did not send one.
        /// Nothing outside a session, or with the sharing off.</summary>
        internal Dictionary<string, byte[]> GatherOthers(List<string> notes, bool asClient = false)
        {
            var none = new Dictionary<string, byte[]>();
            if (!ReportShareOn()) return none;
            var id = Guid.NewGuid().ToString("N").Substring(0, 12);
            var g = new ReportGather { Id = id };
            // (asClient: the autotest's two games in one MPFever, the client's side asking)
            bool isHost = !asClient && relay != null && (hostGame != null || server != null);
            Client c = null;
            if (!isHost) lock (clients) c = clients.LastOrDefault();
            if (isHost)
            {
                lock (players) foreach (var p in players) if (BaseName(p) != BaseName(hostName ?? "")) g.Expected.Add(BaseName(p));
                if (g.Expected.Count == 0) return none;
                g.PlanKnown = true;
                lock (gatherGate) gather = g;
                relay.Broadcast(Msg.Make("report_req", hostName, "{[\"id\"]=" + LuaLit.Quote(id) + ",[\"to\"]=" + LuaLit.Quote(hostName) + "}"));
            }
            else if (c != null && reportMe != null)
            {
                lock (gatherGate) gather = g;
                try { c.Send(Msg.Make("report_ask", reportMe, "{[\"id\"]=" + LuaLit.Quote(id) + "}")); } catch { return none; }
            }
            else return none;
            var t0 = DateTime.UtcNow;
            int shown = -1;
            try
            {
                while (true)
                {
                    int answered, expected; bool plan, done; DateTime last;
                    lock (gatherGate)
                    {
                        answered = g.Answered; expected = g.Expected.Count; plan = g.PlanKnown; last = g.Last;
                        done = plan && g.Expected.All(e => g.Got.ContainsKey(e) || g.Refused.ContainsKey(e));
                    }
                    if (done) break;
                    // (25 s without news, the plan not even come in 10 s: an older host; 2 minutes at most)
                    if (DateTime.UtcNow - last > TimeSpan.FromSeconds(plan ? 25 : 10) || DateTime.UtcNow - t0 > TimeSpan.FromMinutes(ReportWaitOn() ? 4 : 2)) break;
                    if (plan && answered != shown)
                    {
                        shown = answered;
                        ReportAnswer(F("Rapports des autres joueurs : {0} sur {1}...", "The other players' reports: {0} of {1}...", answered, expected));
                    }
                    Thread.Sleep(250);
                }
            }
            finally { lock (gatherGate) if (gather == g) gather = null; }
            lock (gatherGate)
            {
                if (!g.PlanKnown) notes.Add("The host did not answer the request for the players' reports (an MPFever before 0.7.9?).");
                foreach (var e in g.Expected.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                {
                    if (g.Got.ContainsKey(e)) notes.Add(e + ": report included (players/" + Reporter.SafeName(e) + "/)");
                    else if (g.Refused.TryGetValue(e, out var why)) notes.Add(e + ": no report (" + why + ")");
                    else notes.Add(e + ": no answer (an MPFever before 0.7.9, or not in the session any more)");
                }
                Log.W(F("Rapports des autres joueurs reçus : {0} sur {1}", "The other players' reports received: {0} of {1}", g.Got.Count, g.Expected.Count));
                return new Dictionary<string, byte[]>(g.Got, StringComparer.OrdinalIgnoreCase);
            }
        }

        /// <summary>A report's part or refusal for the report under way here.</summary>
        void FeedGather(Msg m)
        {
            var h = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (h == null) return;
            string S(string k) => h.TryGetValue(k, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
            int N(string k) => int.TryParse(S(k), NumberStyles.Integer, CultureInfo.InvariantCulture, out var x) ? x : -1;
            lock (gatherGate)
            {
                var g = gather;
                if (g == null || g.Id != S("id")) return;
                var who = BaseName(S("who"));
                if (who == "") return;
                g.Last = DateTime.UtcNow;
                if (m.Kind == "report_no") { g.Refused[who] = S("why"); g.Expected.Add(who); return; }
                int i = N("i"), n = N("n");
                if (m.Data == null || n < 1 || n > ReportShareMax / ReportPart + 1 || i < 0 || i >= n) return;
                if (!g.Parts.TryGetValue(who, out var parts) || parts.Length != n) g.Parts[who] = parts = new byte[n][];
                parts[i] = m.Data;
                if (parts.All(p => p != null))
                {
                    var all = new byte[parts.Sum(p => (long)p.Length)];
                    int at = 0;
                    foreach (var p in parts) { Buffer.BlockCopy(p, 0, all, at, p.Length); at += p.Length; }
                    g.Got[who] = all;
                    g.Parts.Remove(who);
                    g.Expected.Add(who);
                }
            }
        }

        // (0.7.12, #157/#161: yoyo's reports of 2026-11-08 18:11 and 19:33, three players: the other players' reports, 0 of 1 then
        // 0 of 2. A player's report is made before any of it is sent: 20 s and more after a long session (the host's own, 10.7 MB,
        // took 20 s), and the one asking gave up after 25 s without news. While this one is made, a word every 8 s says it is
        // coming ("report_work"), and the one asking waits 4 minutes at most instead of 2. MPFEVER_REPORTWAIT=0: as before)
        static bool ReportWaitOn() => Environment.GetEnvironmentVariable("MPFEVER_REPORTWAIT") != "0";

        /// <summary>This player's own report, sent for another's (`to`), in parts through `send`.</summary>
        void SendOwnReport(string id, string to, string me, Action<Msg> send)
        {
            string Fields() => "[\"id\"]=" + LuaLit.Quote(id) + ",[\"to\"]=" + LuaLit.Quote(to) + ",[\"who\"]=" + LuaLit.Quote(BaseName(me));
            try
            {
                if (!ReportShareOn()) { send(Msg.Make("report_no", me, "{" + Fields() + ",[\"why\"]=\"its player keeps their reports to themselves (reportshare=0)\"}")); return; }
                string zip;
                using (var made = new ManualResetEvent(false))
                {
                    if (ReportWaitOn())
                    {
                        try { send(Msg.Make("report_work", me, "{" + Fields() + "}")); } catch { }
                        new Thread(() =>
                        {
                            try { while (!made.WaitOne(8000)) send(Msg.Make("report_work", me, "{" + Fields() + "}")); }
                            catch { }
                        }) { IsBackground = true, Name = "Report coming for " + to }.Start();
                    }
                    try { zip = Reporter.Collect(games.Select(x => x.Dir).ToList(), ReportSummary(false, BaseName(to)), out _); }
                    finally { made.Set(); }
                }
                var bytes = File.ReadAllBytes(zip);
                if (bytes.Length > ReportShareMax) { send(Msg.Make("report_no", me, "{" + Fields() + ",[\"why\"]=\"" + (bytes.Length >> 20) + " MB, too large to send\"}")); return; }
                int n = Math.Max(1, (bytes.Length + ReportPart - 1) / ReportPart);
                for (int i = 0; i < n; i++)
                {
                    int len = Math.Min(ReportPart, bytes.Length - i * ReportPart);
                    send(Msg.MakeBinary("report_bin", me, Fields() + ",[\"i\"]=" + i + ",[\"n\"]=" + n, bytes, i * ReportPart, len));
                }
                Log.W(F("Rapport de ce PC envoyé pour celui de {0} ({1:0.0} Mo)", "This PC's report sent for {0}'s ({1:0.0} MB)", BaseName(to), bytes.Length / 1048576.0));
            }
            catch (Exception e)
            {
                Log.W("report for " + to + ": " + e.Message);
                try { send(Msg.Make("report_no", me, "{" + Fields() + ",[\"why\"]=" + LuaLit.Quote("could not make it: " + e.Message) + "}")); } catch { }
            }
        }

        /// <summary>A player: the host's messages about reports (true when it was one).</summary>
        bool OnReportMessage(Msg m, Client client)
        {
            switch (m.Kind)
            {
                case "report_req":
                    {
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        var id = h != null && h.TryGetValue("id", out var iv) ? iv as string : null;
                        var to = h != null && h.TryGetValue("to", out var tv) ? tv as string : null;
                        var me = reportMe;
                        if (id == null || to == null || me == null || BaseName(to) == BaseName(me)) return true;
                        new Thread(() => SendOwnReport(id, to, me, x => client.Send(x))) { IsBackground = true, Name = "Report for " + to }.Start();
                        return true;
                    }
                case "report_plan":
                    {
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        var id = h != null && h.TryGetValue("id", out var iv) ? iv as string : null;
                        var who = h != null && h.TryGetValue("who", out var wv) ? wv as string ?? "" : "";
                        lock (gatherGate)
                        {
                            var g = gather;
                            if (g == null || g.Id != id) return true;
                            foreach (var w in who.Split(',').Select(x => BaseName(x.Trim())).Where(x => x != "" && x != BaseName(reportMe ?? ""))) g.Expected.Add(w);
                            g.PlanKnown = true;
                            g.Last = DateTime.UtcNow;
                        }
                        return true;
                    }
                case "report_bin":
                case "report_no":
                case "report_work":
                    FeedGather(m);
                    return true;
            }
            return false;
        }

        /// <summary>The host: a player's report asked for, or a report (part) for whoever asked: handled here, never passed on to
        /// every game (true when it was one).</summary>
        bool OnHostReportMessage(Msg m, Peer from)
        {
            if (m.Kind == "report_ask")
            {
                if (from == null || relay == null) return true;
                var h = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                var id = h != null && h.TryGetValue("id", out var iv) ? iv as string : null;
                if (id == null) return true;
                var asker = from.Name;
                List<string> others;
                lock (players) others = players.Select(BaseName).Where(p => p != BaseName(asker) && p != BaseName(hostName ?? "")).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                // (a dedicated server: no player of its own; its own report is the session's)
                var who = new List<string>(others) { BaseName(hostName ?? "") };
                relay.TrySend(from, Msg.Make("report_plan", hostName, "{[\"id\"]=" + LuaLit.Quote(id) + ",[\"who\"]=" + LuaLit.Quote(string.Join(",", who)) + "}"));
                Log.W(F("{0} fait un rapport de problème : les rapports des joueurs lui sont envoyés", "{0} is making a problem report: the players' reports are sent to them", BaseName(asker)));
                var req = Msg.Make("report_req", hostName, "{[\"id\"]=" + LuaLit.Quote(id) + ",[\"to\"]=" + LuaLit.Quote(asker) + "}");
                relay.Broadcast(req, from);
                new Thread(() => SendOwnReport(id, asker, hostName, x => { var p = relay?.Find(asker); if (p != null) relay.TrySend(p, x); })) { IsBackground = true, Name = "Report for " + asker }.Start();
                return true;
            }
            if (m.Kind == "report_bin" || m.Kind == "report_no" || m.Kind == "report_work")
            {
                if (from == null) return true;
                var h = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                var to = h != null && h.TryGetValue("to", out var tv) ? tv as string : null;
                if (to == null) return true;
                if (to == hostName) { FeedGather(m); return true; }
                var p = relay?.Find(to);
                if (p != null) relay.TrySend(p, m);
                return true;
            }
            return false;
        }
    }
}
