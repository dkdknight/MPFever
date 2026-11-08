using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace MPFever.ServerList
{
    /// <summary>The public list of MPFever dedicated servers: a small HTTP service on a PC that runs all the time. A server whose
    /// mpfever_server.properties says public=true announces itself every 30 s (POST /api/announce) and leaves the list when it
    /// stops (POST /api/remove) or after 90 s without news. MPFever's multiplayer page reads GET /api/servers. The list lives
    /// in memory only: after a restart of the service, the servers are back within 30 s.
    ///
    /// The address a server is listed with is the one its announce came from (its public IP) and the port it gives; the
    /// service checks that the port answers before listing it (a server reachable only through Steam, with its Steam id,
    /// is listed too). No account, no database. Limits: 8 KiB per request, 4 servers per IP address, 2000 servers.
    ///
    /// Version 2 (MPFever 0.6) lists the players' own games too, public at their host's choice ("kind":"game", see
    /// AnnounceGame): GET /api/games gives every entry with its kind, GET /api/servers still gives the dedicated servers alone,
    /// exactly as before (the MPFever versions before 0.6 read it and never see a player's game), and GET /api/health says
    /// "v":2 (a launcher announces a game only to a list that says so).
    ///
    /// MPFeverServerList.exe [port] runs in a console (default port 28100); install-service.bat installs it as a Windows
    /// service that starts with Windows (MPFeverServerList.exe --service). --loopback listens on 127.0.0.1 only (the offline
    /// test, tests/test_serverlist.py: no firewall question, and X-Forwarded-For names the announcing address).</summary>
    static class Program
    {
        public static int Port = 28100;
        public static string LogPath;
        public static bool Loopback;

        static int Main(string[] args)
        {
            LogPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "serverlist.log");
            Loopback = args.Contains("--loopback");
            var rest = args.Where(a => a != "--service" && a != "--loopback").ToArray();
            if (rest.Length > 0 && !int.TryParse(rest[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out Port)) { Console.WriteLine("usage: MPFeverServerList.exe [port] [--service]"); return 2; }
            var portFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "port.txt");
            if (rest.Length == 0 && File.Exists(portFile) && int.TryParse(File.ReadAllText(portFile).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int fp)) Port = fp;
            if (args.Contains("--service")) { ServiceBase.Run(new ListService()); return 0; }
            var list = new Listing();
            list.Start();
            Console.WriteLine("MPFever server list on port " + Port + " (Ctrl+C to stop). Log: " + LogPath);
            var done = new ManualResetEvent(false);
            Console.CancelKeyPress += (s, e) => { e.Cancel = true; done.Set(); };
            done.WaitOne();
            list.Stop();
            return 0;
        }

        static readonly object logGate = new object();
        public static void Log(string s)
        {
            var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " " + s;
            if (Environment.UserInteractive) Console.WriteLine(line);
            lock (logGate)
            {
                try
                {
                    // (one old copy kept: the log never grows past 2 MB twice)
                    var fi = new FileInfo(LogPath);
                    if (fi.Exists && fi.Length > 2 * 1024 * 1024) { File.Copy(LogPath, LogPath + ".old", true); File.WriteAllText(LogPath, ""); }
                    File.AppendAllText(LogPath, line + "\r\n");
                }
                catch { }
            }
        }
    }

    sealed class ListService : ServiceBase
    {
        Listing list;
        public ListService() { ServiceName = "MPFeverServerList"; }
        protected override void OnStart(string[] args) { list = new Listing(); list.Start(); }
        protected override void OnStop() { list?.Stop(); }
    }

    /// <summary>One listed server.</summary>
    sealed class Entry
    {
        public string Id, Token, Ip, Name, Version, Build, Mode, World, Motd, Steam, Address;
        public int Port, Players, MaxPlayers;
        public bool Password, Reachable, CheckedOnce;
        public DateTime Seen, Checked;
        // (v2) "server", or "game": a player's own game, found by its key (its host's Steam id, else ip:port), with its state
        // ("lobby" or "playing"), its host's name and language, whether players may join it while it runs, and whether its
        // host shows its address
        public string Kind = "server", Key = "", State = "", Host = "", Lang = "";
        public bool JoinPlaying, ShowAddress;
    }

    sealed class Listing
    {
        const int MaxBody = 8192, MaxPerIp = 4, MaxServers = 2000;
        // (v2) players' games from one address: several players behind a carrier's shared address (CGNAT) may host at once
        const int MaxGamesPerIp = 8;
        static readonly TimeSpan Expiry = TimeSpan.FromSeconds(90), Recheck = TimeSpan.FromMinutes(5);
        readonly Dictionary<string, Entry> servers = new Dictionary<string, Entry>();   // by id
        readonly Dictionary<string, DateTime> lastAnnounce = new Dictionary<string, DateTime>();   // by ip:port
        readonly Reports reports = new Reports();
        TcpListener listener;
        volatile bool running;

        public void Start()
        {
            if (Program.Loopback) listener = new TcpListener(IPAddress.Loopback, Program.Port);
            else
            {
                listener = new TcpListener(IPAddress.IPv6Any, Program.Port);
                listener.Server.SetSocketOption(SocketOptionLevel.IPv6, SocketOptionName.IPv6Only, false);
            }
            listener.Start();
            running = true;
            new Thread(Accept) { IsBackground = true, Name = "Accept" }.Start();
            new Thread(Sweep) { IsBackground = true, Name = "Sweep" }.Start();
            Program.Log("listening on port " + Program.Port);
        }

        public void Stop()
        {
            running = false;
            try { listener.Stop(); } catch { }
            Program.Log("stopped");
        }

        void Accept()
        {
            while (running)
            {
                TcpClient c;
                try { c = listener.AcceptTcpClient(); }
                catch { if (!running) return; Thread.Sleep(100); continue; }
                ThreadPool.QueueUserWorkItem(_ => Serve(c));
            }
        }

        void Sweep()
        {
            while (running)
            {
                Thread.Sleep(10000);
                lock (servers)
                {
                    var now = DateTime.UtcNow;
                    foreach (var id in servers.Where(kv => now - kv.Value.Seen > Expiry).Select(kv => kv.Key).ToList())
                    {
                        Program.Log("expired: " + servers[id].Name + " (" + servers[id].Ip + ":" + servers[id].Port + ")");
                        servers.Remove(id);
                    }
                    foreach (var k in lastAnnounce.Where(kv => now - kv.Value > Expiry).Select(kv => kv.Key).ToList()) lastAnnounce.Remove(k);
                }
                reports.Sweep();
            }
        }

        // ------------------------------------------------------------------------------------------------- HTTP (HTTP/1.1, one
        // request per connection: a GET, or a POST with a body of at most 8 KiB)
        void Serve(TcpClient c)
        {
            try
            {
                using (c)
                {
                    c.ReceiveTimeout = 5000; c.SendTimeout = 5000;
                    var s = c.GetStream();
                    var ip = ((IPEndPoint)c.Client.RemoteEndPoint).Address;
                    if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
                    var head = ReadHead(s, out byte[] early);
                    if (head == null) return;
                    var lines = head.Split(new[] { "\r\n" }, StringSplitOptions.None);
                    ip = ClientIp(ip, lines);
                    var first = lines[0].Split(' ');
                    if (first.Length < 2) { Reply(s, 400, "{\"error\":\"bad request\"}"); return; }
                    string method = first[0], path = first[1];
                    int q = path.IndexOf('?');
                    if (q >= 0) path = path.Substring(0, q);
                    int len = 0;
                    foreach (var l in lines.Skip(1))
                        if (l.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) int.TryParse(l.Substring(15).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out len);
                    // (0.7.9) a problem report: up to 32 MB, read slowly enough for a player's upload (see Reports)
                    if (method == "POST" && path == "/api/report")
                    {
                        c.ReceiveTimeout = 60000; c.SendTimeout = 60000;
                        var r = reports.Receive(s, ip.ToString(), early, len, out int code);
                        Reply(s, code, r);
                        return;
                    }
                    if (method == "GET" && path.StartsWith("/r/", StringComparison.Ordinal)) { c.SendTimeout = 60000; reports.Serve(s, path.Substring(3)); return; }
                    if (len < 0 || len > MaxBody) { Reply(s, 413, "{\"error\":\"too large\"}"); return; }
                    var body = new byte[len];
                    int got = Math.Min(early.Length, len);
                    Array.Copy(early, body, got);
                    while (got < len) { int n = s.Read(body, got, len - got); if (n <= 0) break; got += n; }
                    var text = Encoding.UTF8.GetString(body, 0, got);
                    if (method == "GET" && (path == "/api/servers" || path == "/")) { Reply(s, 200, ListJson(false)); return; }
                    // (v2: every entry with its kind; /api/servers stays the dedicated servers' alone, for the older MPFever)
                    if (method == "GET" && path == "/api/games") { Reply(s, 200, ListJson(true)); return; }
                    if (method == "GET" && path == "/api/health")
                    {
                        int n, g;
                        lock (servers) { g = servers.Values.Count(x => x.Kind == "game"); n = servers.Count - g; }
                        Reply(s, 200, "{\"ok\":true,\"servers\":" + n + ",\"games\":" + g + ",\"v\":2}");
                        return;
                    }
                    if (method == "POST" && path == "/api/announce") { Reply(s, 200, Announce(ip.ToString(), text)); return; }
                    if (method == "POST" && path == "/api/remove") { Reply(s, 200, Remove(text)); return; }
                    Reply(s, 404, "{\"error\":\"not found\"}");
                }
            }
            catch (Exception e) { Program.Log("request failed: " + e.GetType().Name + ": " + e.Message); }
        }

        // ------------------------------------------------------------------------------------------------- behind a reverse proxy
        // (Caddy, nginx, IIS on the same PC or network, maybe behind Cloudflare): the connection then comes from the proxy, and
        // the announcing server's own address is in the headers. They are believed only from a proxy of this PC or network:
        // X-Forwarded-For's last address is the one the proxy saw (Caddy and nginx set or append it), and Cloudflare's
        // CF-Connecting-IP only when that address is one of Cloudflare's.
        static readonly string[] Cloudflare = {
            "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18",
            "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
            "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
            "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32" };
        static readonly string[] Local = { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10" };

        static IPAddress ClientIp(IPAddress peer, string[] lines)
        {
            if (!IPAddress.IsLoopback(peer) && !In(peer, Local)) return peer;
            string Header(string name)
            {
                foreach (var l in lines.Skip(1))
                    if (l.Length > name.Length && l[name.Length] == ':' && l.StartsWith(name, StringComparison.OrdinalIgnoreCase)) return l.Substring(name.Length + 1).Trim();
                return null;
            }
            var ip = peer;
            var xff = Header("X-Forwarded-For");
            if (xff != null && IPAddress.TryParse(xff.Split(',').Last().Trim(), out var seen)) ip = seen;
            var cf = Header("CF-Connecting-IP");
            if (cf != null && In(ip, Cloudflare) && IPAddress.TryParse(cf, out var real)) ip = real;
            return ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4() : ip;
        }

        static bool In(IPAddress ip, string[] ranges)
        {
            if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
            var a = ip.GetAddressBytes();
            foreach (var r in ranges)
            {
                var parts = r.Split('/');
                var b = IPAddress.Parse(parts[0]).GetAddressBytes();
                if (a.Length != b.Length) continue;
                int bits = int.Parse(parts[1], CultureInfo.InvariantCulture), i = 0;
                while (bits >= 8 && a[i] == b[i]) { bits -= 8; i++; }
                if (bits >= 8) continue;
                if (bits == 0 || ((a[i] ^ b[i]) & (0xff << (8 - bits)) & 0xff) == 0) return true;
            }
            return false;
        }

        static string ReadHead(Stream s, out byte[] early)
        {
            var buf = new byte[MaxBody + 4096];
            int n = 0;
            early = new byte[0];
            while (n < buf.Length)
            {
                int r = s.Read(buf, n, buf.Length - n);
                if (r <= 0) return null;
                n += r;
                for (int i = 3; i < n; i++)
                    if (buf[i - 3] == '\r' && buf[i - 2] == '\n' && buf[i - 1] == '\r' && buf[i] == '\n')
                    {
                        early = new byte[n - i - 1];
                        Array.Copy(buf, i + 1, early, 0, early.Length);
                        return Encoding.ASCII.GetString(buf, 0, i - 3);
                    }
            }
            return null;
        }

        internal static void Reply(Stream s, int code, string json)
        {
            var b = Encoding.UTF8.GetBytes(json);
            var reason = code == 200 ? "OK" : code == 404 ? "Not Found" : code == 413 ? "Payload Too Large" : code == 429 ? "Too Many Requests" : "Bad Request";
            var h = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: " + b.Length
                + "\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
            s.Write(h, 0, h.Length);
            s.Write(b, 0, b.Length);
        }

        // ------------------------------------------------------------------------------------------------- the list
        string Announce(string ip, string text)
        {
            Dictionary<string, object> d;
            try { d = Json.Parse(text) as Dictionary<string, object>; } catch { d = null; }
            if (d == null) return "{\"error\":\"bad json\"}";
            // (v2) a player's own game: see AnnounceGame (a dedicated server, and every MPFever before 0.6, says no kind)
            if (Str(d, "kind", 8) == "game") return AnnounceGame(ip, d);
            int port = Int(d, "port", 0);
            if (port < 1 || port > 65535) return "{\"error\":\"bad port\"}";
            var key = ip + ":" + port;
            var now = DateTime.UtcNow;
            Entry e;
            lock (servers)
            {
                // (at most one announce per server every 10 s: a loop or a flood changes nothing)
                if (lastAnnounce.TryGetValue(key, out var last) && now - last < TimeSpan.FromSeconds(10)) return "{\"error\":\"too often\",\"next\":10}";
                lastAnnounce[key] = now;
                // (the servers only: a player's game from the same address and port is an entry of its own)
                e = servers.Values.FirstOrDefault(x => x.Kind == "server" && x.Ip == ip && x.Port == port);
                string token = Str(d, "token", 64);
                if (e != null && e.Token != token) e = null;   // another server took that port since (a restart): a new entry
                if (e == null)
                {
                    var old = servers.Values.FirstOrDefault(x => x.Kind == "server" && x.Ip == ip && x.Port == port);
                    if (old != null) servers.Remove(old.Id);
                    if (servers.Values.Count(x => x.Kind == "server" && x.Ip == ip) >= MaxPerIp) return "{\"error\":\"too many servers from this address\"}";
                    if (servers.Count >= MaxServers) return "{\"error\":\"list full\"}";
                    e = new Entry { Id = NewId(8), Token = NewId(16), Ip = ip, Port = port };
                    servers[e.Id] = e;
                    Program.Log("new: " + Str(d, "name", 40) + " (" + ip + ":" + port + ")");
                }
                e.Name = Str(d, "name", 40);
                if (e.Name == "") e.Name = "MPFever Server";
                e.Version = Str(d, "version", 20);
                e.Build = Str(d, "build", 20);
                e.Mode = Str(d, "mode", 12);
                e.World = Str(d, "world", 60);
                e.Motd = Str(d, "motd", 140);
                e.Steam = Str(d, "steam", 20);
                if (e.Steam.Any(ch => ch < '0' || ch > '9')) e.Steam = "";
                e.Address = Str(d, "address", 80);
                e.Players = Int(d, "players", 0);
                e.MaxPlayers = Int(d, "max", 0);
                e.Password = d.TryGetValue("password", out var pw) && pw is bool pb && pb;
                e.Seen = now;
            }
            // (checked again every 5 minutes, or at every announce while it does not answer: a port just opened shows soon)
            if (now - e.Checked > Recheck || !e.Reachable) { e.Checked = now; ThreadPool.QueueUserWorkItem(_ => Check(e)); }
            return "{\"ok\":true,\"id\":" + Q(e.Id) + ",\"token\":" + Q(e.Token) + ",\"every\":30}";
        }

        /// <summary>(v2, MPFever 0.6) A player's own game, public at its host's choice. It is found by its host's Steam id, not
        /// by its address: two players behind the same shared address (CGNAT) with the game's usual port are two games. Its
        /// address is neither probed nor listed unless its host chose to show it (then it is probed as a server's); without a
        /// Steam id it must show it. A Steam id cannot be checked here: a game announced with another host's id fails at the
        /// connection (the Steam tunnel authenticates the host), and while an entry lives, its id is refused from another
        /// address. Limits: one announce every 10 s per game and address, 8 games per address.</summary>
        string AnnounceGame(string ip, Dictionary<string, object> d)
        {
            var steam = Str(d, "steam", 20);
            if (steam.Any(ch => ch < '0' || ch > '9')) steam = "";
            bool show = Bool(d, "showAddress");
            int port = Int(d, "port", 0);
            if (port > 65535) port = 0;
            if (steam == "" && !show) return "{\"error\":\"a game needs its host's Steam id or its address\"}";
            if (show && port < 1) return "{\"error\":\"bad port\"}";
            var key = steam != "" ? "steam:" + steam : ip + ":" + port;
            var now = DateTime.UtcNow;
            Entry e;
            lock (servers)
            {
                // (counted per game and address: another address announcing the same id does not hold the host's own back)
                var rate = "game " + key + " " + ip;
                if (lastAnnounce.TryGetValue(rate, out var last) && now - last < TimeSpan.FromSeconds(10)) return "{\"error\":\"too often\",\"next\":10}";
                lastAnnounce[rate] = now;
                string token = Str(d, "token", 64);
                e = servers.Values.FirstOrDefault(x => x.Kind == "game" && x.Key == key);
                if (e != null && e.Token != token)
                {
                    // (its host again, its MPFever started again: a new entry; from another address: refused while it lives)
                    if (e.Ip != ip) return "{\"error\":\"this game is listed from another address\"}";
                    servers.Remove(e.Id);
                    e = null;
                }
                if (e == null)
                {
                    if (servers.Values.Count(x => x.Kind == "game" && x.Ip == ip) >= MaxGamesPerIp) return "{\"error\":\"too many games from this address\"}";
                    if (servers.Count >= MaxServers) return "{\"error\":\"list full\"}";
                    e = new Entry { Id = NewId(8), Token = NewId(16), Ip = ip, Kind = "game", Key = key };
                    servers[e.Id] = e;
                    Program.Log("new game: " + Str(d, "name", 40) + " (" + (steam != "" ? "steam " + steam + ", " : "") + ip + ")");
                }
                e.Port = port;
                e.Name = Str(d, "name", 40);
                if (e.Name == "") e.Name = "MPFever game";
                e.Version = Str(d, "version", 20);
                e.Build = Str(d, "build", 20);
                e.Mode = Str(d, "mode", 12);
                e.World = Str(d, "world", 60);
                e.Motd = Str(d, "motd", 140);
                e.Steam = steam;
                e.ShowAddress = show;
                e.Address = show ? Str(d, "address", 80) : "";
                e.Players = Int(d, "players", 0);
                e.MaxPlayers = Int(d, "max", 0);
                e.Password = Bool(d, "password");
                e.State = Str(d, "state", 12) == "playing" ? "playing" : "lobby";
                e.Host = Str(d, "host", 24);
                e.Lang = Str(d, "lang", 8);
                e.JoinPlaying = Bool(d, "joinPlaying");
                if (!show) e.Reachable = false;
                e.Seen = now;
            }
            if (show && (now - e.Checked > Recheck || !e.Reachable)) { e.Checked = now; ThreadPool.QueueUserWorkItem(_ => Check(e)); }
            return "{\"ok\":true,\"id\":" + Q(e.Id) + ",\"token\":" + Q(e.Token) + ",\"every\":30}";
        }

        string Remove(string text)
        {
            Dictionary<string, object> d;
            try { d = Json.Parse(text) as Dictionary<string, object>; } catch { d = null; }
            if (d == null) return "{\"error\":\"bad json\"}";
            var id = Str(d, "id", 32);
            var token = Str(d, "token", 64);
            lock (servers)
            {
                if (servers.TryGetValue(id, out var e) && e.Token == token)
                {
                    servers.Remove(id);
                    Program.Log("removed: " + e.Name + " (" + e.Ip + ":" + e.Port + ")");
                    return "{\"ok\":true}";
                }
            }
            return "{\"error\":\"unknown server\"}";
        }

        /// <summary>Whether the server's port answers (a TCP connection within 4 s; nothing is sent).</summary>
        static void Check(Entry e)
        {
            bool ok = false;
            try
            {
                using (var c = new TcpClient(IPAddress.Parse(e.Ip).AddressFamily))
                {
                    var ar = c.BeginConnect(e.Ip, e.Port, null, null);
                    ok = ar.AsyncWaitHandle.WaitOne(4000) && c.Connected;
                    if (ok) c.EndConnect(ar);
                }
            }
            catch { ok = false; }
            if (ok != e.Reachable || !e.CheckedOnce) Program.Log((ok ? "reachable: " : "not reachable: ") + e.Name + " (" + e.Ip + ":" + e.Port + ")" + (ok || e.Steam != "" ? "" : ", not listed"));
            e.Reachable = ok;
            e.CheckedOnce = true;
        }

        /// <summary>The list: the dedicated servers alone, as before 0.6 (GET /api/servers), or every entry with its kind (v2,
        /// GET /api/games, "games"). A player's game is listed with its address only when its host chose to show it.</summary>
        string ListJson(bool all)
        {
            var sb = new StringBuilder(all ? "{\"v\":2,\"games\":[" : "{\"servers\":[");
            lock (servers)
            {
                bool first = true;
                // (the fullest first, then by name; a server neither reachable nor joinable through Steam is left out, a player's
                // game too)
                foreach (var e in servers.Values.Where(x => (all || x.Kind == "server") && (x.Reachable || x.Steam != "")).OrderByDescending(x => x.Players).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                {
                    if (!first) sb.Append(',');
                    first = false;
                    bool game = e.Kind == "game";
                    var host = e.Ip.Contains(':') ? "[" + e.Ip + "]" : e.Ip;
                    var address = game && !e.ShowAddress ? "" : e.Address != "" ? e.Address : host + ":" + e.Port;
                    sb.Append("{\"id\":").Append(Q(e.Id))
                      .Append(",\"name\":").Append(Q(e.Name))
                      .Append(",\"address\":").Append(Q(address))
                      .Append(",\"steam\":").Append(Q(e.Steam))
                      .Append(",\"reachable\":").Append(e.Reachable && (!game || e.ShowAddress) ? "true" : "false")
                      .Append(",\"version\":").Append(Q(e.Version))
                      .Append(",\"build\":").Append(Q(e.Build))
                      .Append(",\"mode\":").Append(Q(e.Mode))
                      .Append(",\"world\":").Append(Q(e.World))
                      .Append(",\"motd\":").Append(Q(e.Motd))
                      .Append(",\"players\":").Append(e.Players)
                      .Append(",\"max\":").Append(e.MaxPlayers)
                      .Append(",\"password\":").Append(e.Password ? "true" : "false");
                    if (all)
                        sb.Append(",\"kind\":").Append(Q(e.Kind))
                          .Append(",\"state\":").Append(Q(game ? e.State : ""))
                          .Append(",\"host\":").Append(Q(e.Host))
                          .Append(",\"lang\":").Append(Q(e.Lang))
                          .Append(",\"joinPlaying\":").Append(e.JoinPlaying ? "true" : "false");
                    sb.Append('}');
                }
            }
            return sb.Append("]}").ToString();
        }

        static string NewId(int bytes)
        {
            var b = new byte[bytes];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
            return string.Concat(b.Select(x => x.ToString("x2", CultureInfo.InvariantCulture)));
        }

        /// <summary>A text field: control characters taken out, at most `max` characters.</summary>
        static string Str(Dictionary<string, object> d, string k, int max)
        {
            if (!d.TryGetValue(k, out var v) || !(v is string s)) return "";
            s = new string(s.Where(ch => !char.IsControl(ch)).ToArray()).Trim();
            return s.Length > max ? s.Substring(0, max) : s;
        }

        static bool Bool(Dictionary<string, object> d, string k) => d.TryGetValue(k, out var v) && v is bool b && b;

        static int Int(Dictionary<string, object> d, string k, int def)
        {
            if (!d.TryGetValue(k, out var v) || !(v is double x) || x < 0 || x > 1000000) return def;
            return (int)x;
        }

        static string Q(string s)
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
    }

    /// <summary>Minimal JSON reader (objects, arrays, strings, numbers, true/false/null), as MPFever's own.</summary>
    static class Json
    {
        public static object Parse(string s)
        {
            int i = 0;
            var v = Value(s, ref i, 0);
            Skip(s, ref i);
            if (i < s.Length) throw new FormatException("JSON: unexpected text at " + i);
            return v;
        }

        static void Skip(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static char At(string s, int i) { if (i >= s.Length) throw new FormatException("JSON: unexpected end"); return s[i]; }

        static object Value(string s, ref int i, int depth)
        {
            if (depth > 16) throw new FormatException("JSON: too deep");
            Skip(s, ref i);
            char c = At(s, i);
            if (c == '{')
            {
                var d = new Dictionary<string, object>();
                i++; Skip(s, ref i);
                if (At(s, i) == '}') { i++; return d; }
                while (true)
                {
                    Skip(s, ref i);
                    var k = Str(s, ref i);
                    Skip(s, ref i);
                    if (At(s, i++) != ':') throw new FormatException("JSON: ':' expected");
                    d[k] = Value(s, ref i, depth + 1);
                    Skip(s, ref i);
                    if (At(s, i) == ',') { i++; continue; }
                    if (At(s, i++) == '}') return d;
                    throw new FormatException("JSON: ',' or '}' expected");
                }
            }
            if (c == '[')
            {
                var l = new List<object>();
                i++; Skip(s, ref i);
                if (At(s, i) == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Value(s, ref i, depth + 1));
                    Skip(s, ref i);
                    if (At(s, i) == ',') { i++; continue; }
                    if (At(s, i++) == ']') return l;
                    throw new FormatException("JSON: ',' or ']' expected");
                }
            }
            if (c == '"') return Str(s, ref i);
            if (string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(s, i, "null", 0, 4) == 0) { i += 4; return null; }
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (i == start) throw new FormatException("JSON: unexpected character");
            return double.Parse(s.Substring(start, i - start), CultureInfo.InvariantCulture);
        }

        static string Str(string s, ref int i)
        {
            if (At(s, i) != '"') throw new FormatException("JSON: string expected");
            var sb = new StringBuilder();
            for (i++; At(s, i) != '"'; i++)
            {
                if (s[i] != '\\') { sb.Append(s[i]); continue; }
                char e = At(s, ++i);
                switch (e)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'u':
                        if (i + 4 >= s.Length) throw new FormatException("JSON: bad escape");
                        sb.Append((char)int.Parse(s.Substring(i + 1, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: sb.Append(e); break;
                }
            }
            i++;
            return sb.ToString();
        }
    }
}
