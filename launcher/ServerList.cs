using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The public list of dedicated servers (the service of serverlist\ in the sources): a dedicated server whose
    /// mpfever_server.properties says public=true announces itself there every 30 s while its world runs, and the players'
    /// multiplayer page shows the list in its « Servers » tab. serverlist= in mpfever_settings.txt names another list, else
    /// DefaultServerList; serverlist=0 turns it off.</summary>
    sealed partial class MainForm
    {
        /// <summary>The list MPFever uses when mpfever_settings.txt names none (empty: none).</summary>
        public const string DefaultServerList = "https://mpfever.knight-hd.fr";

        static string ServerListUrl()
        {
            var u = LoadSettings().TryGetValue("serverlist", out var v) ? v.Trim() : DefaultServerList;
            if (u == "" || u == "0" || u.Equals("off", StringComparison.OrdinalIgnoreCase)) return "";
            if (!u.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !u.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) u = "http://" + u;
            return u.TrimEnd('/');
        }

        static string ListRequest(string url, string body)
        {
            if (body != null && PostIPv4(url, body) is string sent) return sent;
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = req.ReadWriteTimeout = 6000;
            req.UserAgent = "MPFever/" + Version;
            req.ServicePoint.Expect100Continue = false;
            if (body != null)
            {
                req.Method = "POST";
                req.ContentType = "application/json";
                var b = Encoding.UTF8.GetBytes(body);
                req.ContentLength = b.Length;
                using (var s = req.GetRequestStream()) s.Write(b, 0, b.Length);
            }
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return r.ReadToEnd();
        }

        /// <summary>A POST to the list over IPv4, when both ends have it: the list shows a server with the address its announce
        /// came from, and a home router forwards the game's port for IPv4 (its IPv6 often stays closed to the Internet, and
        /// players without IPv6 could not use it). null when that fails in any way: the caller then goes the usual way.</summary>
        static string PostIPv4(string url, string body)
        {
            try
            {
                var u = new Uri(url);
                var v4 = Dns.GetHostAddresses(u.DnsSafeHost).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
                if (v4 == null) return null;
                using (var c = new TcpClient(AddressFamily.InterNetwork))
                {
                    if (!c.ConnectAsync(v4, u.Port).Wait(6000)) return null;
                    c.ReceiveTimeout = c.SendTimeout = 6000;
                    Stream s = c.GetStream();
                    if (u.Scheme == Uri.UriSchemeHttps) { var ssl = new SslStream(s); ssl.AuthenticateAsClient(u.DnsSafeHost); s = ssl; }
                    using (s)
                    {
                        var b = Encoding.UTF8.GetBytes(body);
                        var head = Encoding.ASCII.GetBytes("POST " + u.PathAndQuery + " HTTP/1.1\r\nHost: " + u.Authority + "\r\nUser-Agent: MPFever/" + Version
                            + "\r\nContent-Type: application/json\r\nContent-Length: " + b.Length + "\r\nConnection: close\r\n\r\n");
                        s.Write(head, 0, head.Length);
                        s.Write(b, 0, b.Length);
                        s.Flush();
                        // (the answer read until it is whole, by its Content-Length or its last chunk, or until the connection closes)
                        var got = new MemoryStream();
                        var buf = new byte[4096];
                        string answer = null;
                        while (answer == null)
                        {
                            int n = s.Read(buf, 0, buf.Length);
                            if (n > 0) got.Write(buf, 0, n);
                            answer = HttpAnswer(got.ToArray(), n <= 0);
                            if (n <= 0 && answer == null) return null;
                        }
                        return answer.Length > 0 && answer[0] == '\0' ? null : answer;
                    }
                }
            }
            catch { return null; }
        }

        /// <summary>The body of a whole HTTP answer; null while it is not whole, "\0" when it is not a success.</summary>
        static string HttpAnswer(byte[] a, bool closed)
        {
            int end = -1;
            for (int i = 3; i < a.Length; i++) if (a[i - 3] == '\r' && a[i - 2] == '\n' && a[i - 1] == '\r' && a[i] == '\n') { end = i + 1; break; }
            if (end < 0) return null;
            var lines = Encoding.ASCII.GetString(a, 0, end).Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries);
            var status = lines[0].Split(' ');
            if (status.Length < 2 || status[1].Length != 3 || status[1][0] != '2') return "\0";
            string Header(string name) => lines.Skip(1).Where(l => l.StartsWith(name + ":", StringComparison.OrdinalIgnoreCase)).Select(l => l.Substring(name.Length + 1).Trim()).FirstOrDefault();
            if ((Header("Transfer-Encoding") ?? "").IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                var body = new MemoryStream();
                int p = end;
                while (true)
                {
                    int eol = -1;
                    for (int i = p + 1; i < a.Length; i++) if (a[i - 1] == '\r' && a[i] == '\n') { eol = i - 1; break; }
                    if (eol < 0) return closed ? "\0" : null;
                    var hex = Encoding.ASCII.GetString(a, p, eol - p).Split(';')[0].Trim();
                    if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int size) || size < 0) return "\0";
                    if (size == 0) return Encoding.UTF8.GetString(body.ToArray());
                    if (eol + 2 + size + 2 > a.Length) return closed ? "\0" : null;
                    body.Write(a, eol + 2, size);
                    p = eol + 2 + size + 2;
                }
            }
            if (int.TryParse(Header("Content-Length"), NumberStyles.Integer, CultureInfo.InvariantCulture, out int len))
                return a.Length - end >= len ? Encoding.UTF8.GetString(a, end, len) : closed ? "\0" : null;
            return closed ? Encoding.UTF8.GetString(a, end, a.Length - end) : null;
        }

        static string JsonStr(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (var ch in s ?? "")
            {
                if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
                else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                else sb.Append(ch);
            }
            return sb.Append('"').ToString();
        }

        // ---------------------------------------------------------------- the dedicated server's side

        string listId, listToken;
        bool listShown;

        /// <summary>Started with the server: every 30 s while the world runs, the server tells the list who it is.</summary>
        void ServerListAnnounceLoop()
        {
            var url = ServerListUrl();
            if (server == null || !server.Public) return;
            if (url == "") { Log.Warn(T("public=true, mais aucune liste de serveurs n'est connue (serverlist= dans mpfever_settings.txt) : le serveur n'y apparaît pas.", "public=true, but no server list is known (serverlist= in mpfever_settings.txt): the server is not listed.")); return; }
            // (docs/PRIVACY.txt: what the server sends, told in its console at each start instead of the players' window)
            Log.Dim(T("Confidentialité : tant que son monde tourne, ce serveur annonce son nom, son monde, ses joueurs, son adresse et son identifiant Steam à la liste des serveurs publics (public=false dans mpfever_server.properties l'en retire). Détails : PRIVACY.txt.",
                "Privacy: while its world runs, this server announces its name, world, players, address and Steam ID to the public server list (public=false in mpfever_server.properties keeps it out). Details: PRIVACY.txt."));
            string build = "";
            try { build = Reporter.GameBuild(gameDir) ?? ""; } catch { }
            while (serverStarted && !serverStopping)
            {
                bool st; lock (sessionGate) st = started;
                if (st)
                {
                    try
                    {
                        var body = "{\"name\":" + JsonStr(server.Name) + ",\"port\":" + server.Port + ",\"version\":" + JsonStr(Version) + ",\"build\":" + JsonStr(build)
                            + ",\"mode\":" + JsonStr(server.CompanyMode) + ",\"world\":" + JsonStr(server.World) + ",\"motd\":" + JsonStr(server.Motd)
                            + ",\"players\":" + (relay?.AdmittedCount ?? 0) + ",\"max\":" + server.MaxPlayers + ",\"password\":" + (server.Password != "" ? "true" : "false")
                            + ",\"steam\":" + JsonStr(hostSteamId ?? "") + ",\"address\":" + JsonStr(server.PublicAddress) + ",\"token\":" + JsonStr(listToken ?? "") + "}";
                        var d = Json.Parse(ListRequest(url + "/api/announce", body)) as Dictionary<string, object>;
                        if (d != null && d.TryGetValue("ok", out var ok) && ok is bool okb && okb)
                        {
                            listId = d.TryGetValue("id", out var id) ? id as string : listId;
                            listToken = d.TryGetValue("token", out var tk) ? tk as string : listToken;
                            if (!listShown) { listShown = true; Log.Ok(F("Le serveur apparaît dans la liste publique ({0}).", "The server is in the public list ({0}).", url)); }
                        }
                        else if (d != null && d.TryGetValue("error", out var err) && !(err as string ?? "").StartsWith("too often", StringComparison.Ordinal))
                            Log.Warn(F("Liste des serveurs : {0}", "Server list: {0}", err));
                    }
                    catch (Exception e) { Log.Dim(F("Liste des serveurs injoignable : {0}", "Server list unreachable: {0}", e.Message)); }
                }
                for (int i = 0; i < 30 && serverStarted && !serverStopping; i++) Thread.Sleep(1000);
            }
        }

        /// <summary>The server stops: it leaves the list at once (else after 90 s).</summary>
        void ServerListRemove()
        {
            var url = ServerListUrl();
            if (url == "" || listId == null) return;
            try { ListRequest(url + "/api/remove", "{\"id\":" + JsonStr(listId) + ",\"token\":" + JsonStr(listToken) + "}"); } catch { }
            listId = null;
        }

        // ---------------------------------------------------------------- the players' side

        volatile string serverListView = "";
        volatile bool serverListWanted;
        // (0.6) until when the list is taken as an older one (no /api/games, see FetchList)
        DateTime listOldUntil = DateTime.MinValue;

        /// <summary>(0.6) The entries of the list: /api/games (v2: every entry, the players' public games too), else /api/servers.
        /// A list that answers /api/games with an HTTP error (an older list: 404) is remembered as one for 10 minutes: one request a
        /// cycle, /api/servers, not two. A list that does not answer at all (down, unreachable) is not asked /api/servers as well:
        /// the error goes to the caller after one wait of 6 s, not two. v2 false (MPFEVER_PUBLICGAMES=0): /api/servers, as before.</summary>
        internal static List<object> FetchList(string url, bool v2, ref DateTime oldUntil)
        {
            if (v2 && DateTime.UtcNow >= oldUntil)
            {
                string body = null;
                try { body = ListRequest(url + "/api/games", null); }
                catch (WebException e) when (e.Response is HttpWebResponse r && (int)r.StatusCode >= 400 && (int)r.StatusCode < 500) { }
                List<object> games = null;
                if (body != null)
                    try { games = Json.Parse(body) is Dictionary<string, object> d && d.TryGetValue("games", out var g) ? g as List<object> : null; } catch (Exception) { }
                if (games != null) return games;
                // (an older list has no such route: its servers, as before)
                oldUntil = DateTime.UtcNow.AddMinutes(10);
            }
            var ds = Json.Parse(ListRequest(url + "/api/servers", null)) as Dictionary<string, object>;
            return ds != null && ds.TryGetValue("servers", out var s) ? s as List<object> : null;
        }

        /// <summary>Started with the game's menu: the list read every 20 s (at once when the page asks) while no session runs,
        /// for the « Servers » tab (menu_state servers=, one server per \u001e, its fields separated by \u001f: name, address to
        /// join, players, max, password 1/0, version, mode, world, motd; 0.6: then kind s/g (a dedicated server, a player's
        /// game), state (a game's: lobby, playing), host, language, join while playing 1/0). From 0.6 the list is read by
        /// /api/games (every entry, the players' public games too, see PublicGames.cs), /api/servers when the list has no such
        /// route (an older list); MPFEVER_PUBLICGAMES=0: /api/servers, as before.</summary>
        void ServerListFetchLoop()
        {
            double last = -1000;
            while (running)
            {
                Thread.Sleep(500);
                var url = ServerListUrl();
                if (url == "" || menuGame == null || !menuGame.GameRunning) continue;
                bool idle = menuPhase == "idle" || menuPhase == "error";
                if (!(serverListWanted || (idle && Now - last >= 20))) continue;
                serverListWanted = false;
                last = Now;
                string view;
                try
                {
                    var list = FetchList(url, !PublicOff, ref listOldUntil);
                    var rows = new List<string>();
                    foreach (var o in (list ?? new List<object>()).OfType<Dictionary<string, object>>().Take(200))
                    {
                        string S(string k) => o.TryGetValue(k, out var v) && v is string sv ? sv.Replace("\u001e", " ").Replace("\u001f", " ") : "";
                        string N(string k) => o.TryGetValue(k, out var v) && v is double dv ? ((int)dv).ToString(CultureInfo.InvariantCulture) : "0";
                        bool B(string k) => o.TryGetValue(k, out var v) && v is bool bv && bv;
                        var address = S("address");
                        var steam = S("steam");
                        // (through the server's Steam and its address at once: whichever answers, see Client.Connect)
                        var join = (steam != "" ? "steam:" + steam + (address != "" ? "," : "") : "") + address;
                        if (join == "") continue;
                        rows.Add(string.Join("\u001f", S("name"), join, N("players"), N("max"), B("password") ? "1" : "0", S("version"), S("mode"), S("world"), S("motd"),
                            S("kind") == "game" ? "g" : "s", S("state"), S("host"), S("lang"), B("joinPlaying") ? "1" : "0"));
                    }
                    view = rows.Count == 0 ? "-" : string.Join("\u001e", rows);
                }
                catch (Exception e)
                {
                    view = "!" + e.Message.Replace("\u001e", " ").Replace("\u001f", " ");
                }
                if (view != serverListView) { serverListView = view; MenuStatus(); }
            }
        }
    }
}
