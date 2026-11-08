using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace MPFever.ServerList
{
    /// <summary>(0.7.9) MPFever's problem reports, sent by the launcher with no file to drag anywhere: POST /api/report takes the
    /// report (a zip of every player's logs, MPFever 0.7.9) and keeps it under reports\ next to the exe; GET /r/&lt;id&gt;.zip gives it
    /// back. With a GitHub key (MPFEVER_GITHUB_TOKEN, or github_token.txt next to the exe: a fine-grained key that may only
    /// write the issues of one repository), the service opens the issue itself, in the name of its own account: the player needs
    /// no GitHub account, and the key never leaves this PC (a key shipped in MPFever would let anyone post in the project's
    /// name). Without one it only keeps the file: the launcher then opens a new issue with the link in it, sent by the player.
    ///
    /// Body: a 4-byte length (little-endian), that many bytes of UTF-8 JSON {title, body, issue?} (issue: a number, the report
    /// then goes as a comment of that issue), then the zip itself. Limits: 32 MB a report, 3 every 10 minutes and 10 a day from
    /// one address, 100 a day in all; the files are deleted after 60 days. Their names are 32 random hexadecimal digits: the
    /// link is the only way to them (no listing).
    /// Other files next to the exe: github_repo.txt (default dkdknight/MPFever), public_url.txt (the address the links start
    /// with, default https://mpfever.knight-hd.fr). MPFEVER_GITHUB_API (the tests): another address than api.github.com.</summary>
    sealed class Reports
    {
        public const int MaxReport = 32 * 1024 * 1024, MaxText = 64 * 1024;
        const int PerIpShort = 3, PerIpDay = 10, AllDay = 100, KeepDays = 60;
        static readonly TimeSpan Short = TimeSpan.FromMinutes(10), Day = TimeSpan.FromDays(1);
        readonly Dictionary<string, List<DateTime>> byIp = new Dictionary<string, List<DateTime>>();
        readonly List<DateTime> all = new List<DateTime>();
        DateTime lastSweep;

        static string Base => AppDomain.CurrentDomain.BaseDirectory;
        // (MPFEVER_REPORTS_DIR: another folder, the tests)
        public static string Dir => Environment.GetEnvironmentVariable("MPFEVER_REPORTS_DIR") is string d && d != "" ? d : Path.Combine(Base, "reports");

        static string FileText(string name)
        {
            try { var f = Path.Combine(Base, name); return File.Exists(f) ? File.ReadAllText(f).Trim() : null; } catch { return null; }
        }

        static string Token() { var t = Environment.GetEnvironmentVariable("MPFEVER_GITHUB_TOKEN"); return string.IsNullOrWhiteSpace(t) ? FileText("github_token.txt") : t.Trim(); }
        static string Repo() => FileText("github_repo.txt") is string r && r.Contains("/") ? r : "dkdknight/MPFever";
        static string Api() => (Environment.GetEnvironmentVariable("MPFEVER_GITHUB_API") ?? "https://api.github.com").TrimEnd('/');
        static string PublicUrl() => (FileText("public_url.txt") is string u && u.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? u
            : Program.Loopback ? "http://127.0.0.1:" + Program.Port : "https://mpfever.knight-hd.fr").TrimEnd('/');

        /// <summary>Whether this address (and everybody) may send one more report now; counts it when so.</summary>
        bool Allowed(string ip, out string why)
        {
            var now = DateTime.UtcNow;
            lock (byIp)
            {
                all.RemoveAll(t => now - t > Day);
                if (!byIp.TryGetValue(ip, out var l)) byIp[ip] = l = new List<DateTime>();
                l.RemoveAll(t => now - t > Day);
                if (l.Count(t => now - t < Short) >= PerIpShort) { why = "too many reports: wait 10 minutes"; return false; }
                if (l.Count >= PerIpDay) { why = "too many reports from this address today"; return false; }
                if (all.Count >= AllDay) { why = "too many reports today"; return false; }
                l.Add(now); all.Add(now);
            }
            why = null;
            return true;
        }

        /// <summary>POST /api/report: the answer's JSON, `code` its HTTP status.</summary>
        public string Receive(Stream s, string ip, byte[] early, int len, out int code)
        {
            code = 400;
            if (len < 4 + 2 + 22) return "{\"error\":\"empty report\"}";
            if (len > MaxReport) { code = 413; return "{\"error\":\"too large (32 MB at most)\"}"; }
            // (the body read first, even to refuse it: a sender still writing it gets the answer, not a cut connection)
            var body = new byte[len];
            int got = Math.Min(early.Length, len);
            Array.Copy(early, body, got);
            while (got < len) { int n = s.Read(body, got, len - got); if (n <= 0) break; got += n; }
            if (got < len) return "{\"error\":\"report cut short\"}";
            if (!Allowed(ip, out var why)) { code = 429; return "{\"error\":" + Q(why) + "}"; }
            int textLen = BitConverter.ToInt32(body, 0);
            if (textLen < 2 || textLen > MaxText || 4 + textLen + 22 > len) return "{\"error\":\"bad report\"}";
            Dictionary<string, object> d;
            try { d = Json.Parse(Encoding.UTF8.GetString(body, 4, textLen)) as Dictionary<string, object>; } catch { d = null; }
            if (d == null) return "{\"error\":\"bad json\"}";
            int zipAt = 4 + textLen;
            // (a zip and nothing else: its local file header's signature)
            if (body[zipAt] != 'P' || body[zipAt + 1] != 'K' || body[zipAt + 2] != 3 || body[zipAt + 3] != 4) return "{\"error\":\"not a zip\"}";
            string title = Field(d, "title", 120), text = Field(d, "body", 20000, true);
            if (title == "") title = "Problem report";
            int issue = d.TryGetValue("issue", out var iv) && iv is double dv && dv >= 1 && dv < 1e7 ? (int)dv : 0;
            var id = NewId();
            try
            {
                Directory.CreateDirectory(Dir);
                using (var f = File.Create(Path.Combine(Dir, id + ".zip"))) f.Write(body, zipAt, len - zipAt);
            }
            catch (Exception e) { Program.Log("report not kept: " + e.Message); code = 500; return "{\"error\":\"could not keep the report\"}"; }
            var link = PublicUrl() + "/r/" + id + ".zip";
            Program.Log("report " + id + " (" + ((len - zipAt) / 1024) + " KB) from " + ip + ": " + title);
            code = 200;
            string issueUrl = "", note = "";
            var token = Token();
            if (string.IsNullOrEmpty(token)) note = "no GitHub key on the service";
            else
            {
                var full = text.TrimEnd() + "\n\n### Logs\n**Every player's logs:** " + link + "\n\n_Sent by MPFever's report service (" + (len - zipAt) / 1024 + " KB)._";
                try
                {
                    issueUrl = issue > 0 ? GitHub("/repos/" + Repo() + "/issues/" + issue + "/comments", "{\"body\":" + Q(full) + "}", token)
                        : GitHub("/repos/" + Repo() + "/issues", "{\"title\":" + Q(title) + ",\"body\":" + Q(full) + "}", token);
                    Program.Log("report " + id + ": " + issueUrl);
                }
                catch (Exception e) { note = "GitHub refused: " + e.Message; Program.Log("report " + id + ": " + note); }
            }
            return "{\"ok\":true,\"file\":" + Q(link) + ",\"issue\":" + Q(issueUrl) + (note != "" ? ",\"note\":" + Q(note) : "") + "}";
        }

        /// <summary>A POST to GitHub's API: the html_url of what it made.</summary>
        static string GitHub(string path, string json, string token)
        {
            try { if (ServicePointManager.SecurityProtocol != SecurityProtocolType.SystemDefault) ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
            var req = (HttpWebRequest)WebRequest.Create(Api() + path);
            req.Method = "POST";
            req.Timeout = req.ReadWriteTimeout = 20000;
            req.UserAgent = "MPFever-report-service";
            req.Accept = "application/vnd.github+json";
            req.Headers["Authorization"] = "Bearer " + token;
            req.Headers["X-GitHub-Api-Version"] = "2022-11-28";
            req.ContentType = "application/json";
            var b = Encoding.UTF8.GetBytes(json);
            req.ContentLength = b.Length;
            using (var st = req.GetRequestStream()) st.Write(b, 0, b.Length);
            string answer;
            try
            {
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) answer = r.ReadToEnd();
            }
            catch (WebException e) when (e.Response is HttpWebResponse hr)
            {
                throw new IOException("HTTP " + (int)hr.StatusCode);
            }
            var d = Json.Parse(answer) as Dictionary<string, object>;
            return d != null && d.TryGetValue("html_url", out var u) && u is string us ? us : throw new IOException("no html_url in GitHub's answer");
        }

        /// <summary>GET /r/&lt;id&gt;.zip.</summary>
        public void Serve(Stream s, string name)
        {
            if (name.Length != 36 || !name.EndsWith(".zip", StringComparison.Ordinal) || !name.Substring(0, 32).All(ch => (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')))
            { Listing.Reply(s, 404, "{\"error\":\"not found\"}"); return; }
            var f = Path.Combine(Dir, name);
            if (!File.Exists(f)) { Listing.Reply(s, 404, "{\"error\":\"not found\"}"); return; }
            using (var src = File.OpenRead(f))
            {
                var h = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: " + src.Length
                    + "\r\nContent-Disposition: attachment; filename=\"MPFever-report-" + name.Substring(0, 8) + ".zip\"\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
                s.Write(h, 0, h.Length);
                src.CopyTo(s);
            }
        }

        /// <summary>Every hour: the reports older than 60 days deleted.</summary>
        public void Sweep()
        {
            if (DateTime.UtcNow - lastSweep < TimeSpan.FromHours(1)) return;
            lastSweep = DateTime.UtcNow;
            try
            {
                if (!Directory.Exists(Dir)) return;
                foreach (var f in Directory.GetFiles(Dir, "*.zip"))
                    if (DateTime.UtcNow - File.GetLastWriteTimeUtc(f) > TimeSpan.FromDays(KeepDays)) { File.Delete(f); Program.Log("report deleted (60 days): " + Path.GetFileName(f)); }
            }
            catch (Exception e) { Program.Log("reports' sweep: " + e.Message); }
        }

        static string NewId()
        {
            var b = new byte[16];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
            return string.Concat(b.Select(x => x.ToString("x2", CultureInfo.InvariantCulture)));
        }

        /// <summary>A text field: control characters out (line breaks kept in a multiline one), at most `max` characters.</summary>
        static string Field(Dictionary<string, object> d, string k, int max, bool multiline = false)
        {
            if (!d.TryGetValue(k, out var v) || !(v is string s)) return "";
            s = new string(s.Where(ch => !char.IsControl(ch) || (multiline && (ch == '\n' || ch == '\t'))).ToArray()).Trim();
            return s.Length > max ? s.Substring(0, max) : s;
        }

        static string Q(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (var ch in s ?? "")
            {
                if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
                else if (ch == '\n') sb.Append("\\n");
                else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                else sb.Append(ch);
            }
            return sb.Append('"').ToString();
        }
    }
}
