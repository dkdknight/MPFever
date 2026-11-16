using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>(0.6, release/recherche-0.6/09) Who may come into a player's own game besides the version check, when its host
    /// asked for it in the lobby's game options (mod/mpfever_1/content/mpfever_feat_public.lua): its ban list (join_bans, kept
    /// between games in mpfever_bans.txt next to MPFever.exe), a free place in a public game (public, 8 players at most), and
    /// its answer to every arrival (join_approve: the arrival waits, told so, until the host lets it in or not). With those
    /// options off it lets everybody in and reads no file, as in 0.5.14. A dedicated server has its own rules (Server.cs).</summary>
    sealed class PublicGate
    {
        /// <summary>The session's game options ("id=1;id.param=v;...").</summary>
        public Func<string> Options = () => "";
        public string BanFile;
        /// <summary>How long an arrival waits for the host's answer (then it is refused).</summary>
        public double AskSeconds = 120;
        /// <summary>The arrivals waiting for the host or the ban list changed: the lobby and the window show them.</summary>
        public event Action Changed;
        /// <summary>An arrival now waits for the host's answer (its name, name#id).</summary>
        public event Action<string> Asked;

        public bool On(string id) => MainForm.OptValue(Options(), id) == "1";
        public string Param(string id, string p) => MainForm.OptValue(Options(), id + "." + p);

        /// <summary>The players at most in a public game, the host counted (8 at most, decision I7), else 0: no limit.</summary>
        public int MaxPlayers
        {
            get
            {
                if (!On("public")) return 0;
                return int.TryParse(Param("public", "max"), NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? Math.Max(2, Math.Min(8, v)) : 8;
            }
        }

        static string Base(string n) { if (n == null) return ""; int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }

        // ---------------------------------------------------------------- the ban list
        // One ban a line, tab-separated: the player's name (without its number), its Steam id (a player who came through
        // Steam), its IP address (one who came by its address), the day. Read again when the file changed (edited by hand).

        public sealed class Ban { public string Name = "", Steam = "", Ip = "", Date = ""; }
        readonly object banGate = new object();
        List<Ban> bans;
        DateTime bansAt;

        static string Clean(string s) => new string((s ?? "").Where(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '-' || ch == '.' || ch == ':').ToArray());

        void LoadBans()
        {
            var at = BanFile != null && File.Exists(BanFile) ? File.GetLastWriteTimeUtc(BanFile) : DateTime.MinValue;
            if (bans != null && at == bansAt) return;
            var list = new List<Ban>();
            try
            {
                if (at != DateTime.MinValue)
                    foreach (var l in File.ReadAllLines(BanFile, Encoding.UTF8))
                    {
                        if (l.TrimStart().StartsWith("#", StringComparison.Ordinal) || l.Trim() == "") continue;
                        var f = l.Split('\t');
                        var b = new Ban { Name = Clean(f[0]), Steam = f.Length > 1 ? Clean(f[1]) : "", Ip = f.Length > 2 ? Clean(f[2]) : "", Date = f.Length > 3 ? Clean(f[3]) : "" };
                        if (b.Name != "" || b.Steam != "" || b.Ip != "") list.Add(b);
                    }
            }
            catch (Exception e) { Log.W("bans: " + e.Message); }
            bans = list;
            bansAt = at;
        }

        void SaveBans()
        {
            try
            {
                var lines = new List<string> { "# MPFever: the players banned from this host's games (name, Steam id, IP address, day; tab-separated)" };
                lines.AddRange(bans.Select(b => b.Name + "\t" + b.Steam + "\t" + b.Ip + "\t" + b.Date));
                File.WriteAllLines(BanFile, lines, new UTF8Encoding(false));
                bansAt = File.GetLastWriteTimeUtc(BanFile);
            }
            catch (Exception e) { Log.W("bans: " + e.Message); }
        }

        public List<Ban> Bans() { lock (banGate) { LoadBans(); return bans.ToList(); } }

        /// <summary>A player banned: by its name, and its Steam id or address when known (a line of its own, or added to that
        /// name's line).</summary>
        public void AddBan(string name, string steam, string ip)
        {
            lock (banGate)
            {
                LoadBans();
                name = Clean(name); steam = Clean(steam); ip = Clean(ip);
                var b = bans.FirstOrDefault(x => x.Name != "" && string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
                if (b == null) bans.Add(b = new Ban { Name = name });
                if (steam != "") b.Steam = steam;
                if (ip != "") b.Ip = ip;
                b.Date = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                SaveBans();
            }
            Changed?.Invoke();
        }

        public bool RemoveBan(string name)
        {
            int n;
            lock (banGate)
            {
                LoadBans();
                n = bans.RemoveAll(x => string.Equals(x.Name, Clean(name), StringComparison.OrdinalIgnoreCase));
                if (n > 0) SaveBans();
            }
            if (n > 0) Changed?.Invoke();
            return n > 0;
        }

        /// <summary>The ban that names this player (its name, any case; its Steam id; its address), or null.</summary>
        public Ban BannedAs(string name, string steam, string ip)
        {
            lock (banGate)
            {
                LoadBans();
                return bans.FirstOrDefault(b => (b.Name != "" && string.Equals(b.Name, name, StringComparison.OrdinalIgnoreCase))
                    || (b.Steam != "" && b.Steam == steam) || (b.Ip != "" && b.Ip == ip));
            }
        }

        // ---------------------------------------------------------------- the host's answer to every arrival

        sealed class Ask { public string Name; public int Answer; public readonly ManualResetEvent Done = new ManualResetEvent(false); }
        readonly List<Ask> asks = new List<Ask>();
        // (the players the host let in during this session, by Steam id or name, with their name: not asked again when they come
        // back, unless they were kicked)
        readonly Dictionary<string, string> letIn = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        static string Key(string name, string steam) => steam != "" ? "steam:" + steam : "name:" + name;

        /// <summary>The arrivals waiting for the host's answer (name#id).</summary>
        public string[] Waiting() { lock (asks) return asks.Select(a => a.Name).ToArray(); }

        /// <summary>The host's answer to an arrival (name#id, or its name alone). False: nobody waits under that name.</summary>
        public bool Answer(string name, bool yes)
        {
            Ask a;
            lock (asks) a = asks.FirstOrDefault(x => x.Name == name) ?? asks.FirstOrDefault(x => string.Equals(Base(x.Name), name, StringComparison.OrdinalIgnoreCase));
            if (a == null) return false;
            a.Answer = yes ? 1 : -1;
            a.Done.Set();
            return true;
        }

        /// <summary>A player kicked: asked again if it comes back.</summary>
        public void Forget(string name)
        {
            lock (letIn) foreach (var k in letIn.Where(kv => string.Equals(kv.Value, name, StringComparison.OrdinalIgnoreCase)).Select(kv => kv.Key).ToList()) letIn.Remove(k);
        }

        /// <summary>The session ends: every arrival still waiting is refused, the players let in are forgotten.</summary>
        public void EndSession()
        {
            lock (asks) foreach (var a in asks) { a.Answer = -1; a.Done.Set(); }
            lock (letIn) letIn.Clear();
        }

        /// <summary>The player's IP address when it came by its address (through Steam, the tunnel comes from this PC: none).</summary>
        static string IpOf(Peer p)
        {
            if (p.SteamId != null) return "";
            try
            {
                if (p.Tcp?.Client?.RemoteEndPoint is IPEndPoint ep)
                {
                    var a = ep.Address.IsIPv4MappedToIPv6 ? ep.Address.MapToIPv4() : ep.Address;
                    return IPAddress.IsLoopback(a) ? "" : a.ToString();
                }
            }
            catch { }
            return "";
        }

        /// <summary>Whether a player who says "join" (after the version check) may come in: null, or the payload of its "denied"
        /// message (reason banned, full or refused; "game" tells its MPFever that a player's game refused it, not a server).
        /// others: the players already in, the host not counted (read again after the host's answer). tell: tells the arrival
        /// that it waits for the host, every 3 s (false: its connection is gone). Runs on the arrival's own connection thread,
        /// which waits here for the host's answer.</summary>
        public string Admit(Peer p, Func<int> others, Func<Peer, bool> tell)
        {
            string name = Base(p.Name), steam = p.SteamId ?? "", ip = IpOf(p);
            string Refuse(string reason, string extra = "")
            {
                Log.Warn(F("{0} ({1}) refusé : {2}", "{0} ({1}) refused: {2}", name, p.Address, reason));
                return "{[\"reason\"]=" + LuaLit.Quote(reason) + extra + ",[\"game\"]=true}";
            }
            if (On("join_bans") && BannedAs(name, steam, ip) != null) return Refuse("banned");
            int max = MaxPlayers;
            if (max > 0 && others() + 1 >= max) return Refuse("full", ",[\"max\"]=" + max);
            if (!On("join_approve")) return null;
            lock (letIn) if (letIn.ContainsKey(Key(name, steam))) return null;
            var a = new Ask { Name = p.Name };
            lock (asks) asks.Add(a);
            Log.Warn(F("{0} veut rejoindre la partie : acceptez ou refusez dans la page Multijoueur ou dans la fenêtre MPFever.", "{0} wants to join the game: accept or refuse on the Multiplayer page or in the MPFever window.", name));
            Changed?.Invoke();
            Asked?.Invoke(p.Name);
            try
            {
                var end = DateTime.UtcNow.AddSeconds(AskSeconds);
                while (true)
                {
                    if (tell != null && !tell(p)) { a.Answer = -1; break; }
                    double left = (end - DateTime.UtcNow).TotalSeconds;
                    if (left <= 0 || a.Done.WaitOne(TimeSpan.FromSeconds(Math.Min(3, Math.Max(0.05, left))))) break;
                }
            }
            finally
            {
                lock (asks) asks.Remove(a);
                Changed?.Invoke();
            }
            if (a.Answer != 1) return Refuse("refused");
            Log.Dim("feat public: " + name + (steam != "" ? " (Steam)" : ip != "" ? " (" + ip + ")" : "") + " let in by the host");
            lock (letIn) letIn[Key(name, steam)] = name;
            // (the places taken meanwhile: another arrival let in, a player back)
            max = MaxPlayers;
            if (max > 0 && others() + 1 >= max) return Refuse("full", ",[\"max\"]=" + max);
            return null;
        }
    }

    /// <summary>(0.6, release/recherche-0.6/09, decisions I2-I7 in 00-REPONSES.md) A player's own game in the public list, and the
    /// host's hand on the arrivals, as its lobby's game options say (all off by default: nothing changes then):
    ///   public              the lobby announces itself to the public list (ServerList.cs's list, version 2) every 30 s while it
    ///                       is open, by its host's Steam id; public.max: 2 to 8 players; public.late=1: it stays in the list
    ///                       while the game runs (players join it then, each arrival reloads everybody's game as before);
    ///                       public.ip=1: its public IPv4 address is shown in the list (the lobby warns the host)
    ///   join_bans           Kick and Ban in the lobby and in the game's MPFever window; the banned players are refused
    ///   join_approve        every arrival waits until the host lets it in or not (lobby or window)
    ///   join_steamfriends   a private game takes Steam connections from the host's Steam friends only (the game module's
    ///                       "host ... friends"); never once the game was public in this session (strangers may be in it)
    /// The game's name ("Partie de &lt;name&gt;" / "&lt;name&gt;'s game", the host can change it in the lobby) is kept in
    /// mpfever_settings.txt (pubname=). MPFEVER_PUBLICGAMES=0: all of it off, and the list read as before (/api/servers).</summary>
    sealed partial class MainForm
    {
        // (MPFEVER_FEAT=0, the whole 0.6 options host off, docs/FEATURES-0.6.md: these options too, the game's lobby shows none)
        static bool PublicOff => Environment.GetEnvironmentVariable("MPFEVER_PUBLICGAMES") == "0" || Environment.GetEnvironmentVariable("MPFEVER_FEAT") == "0";

        readonly object pubLock = new object();
        PublicGate pubGate;
        PublicGate Gate
        {
            get
            {
                lock (pubLock)
                {
                    if (pubGate != null) return pubGate;
                    // (an autotest bans in a file of its own: never the player's list)
                    var g = new PublicGate { BanFile = autotest ? Path.Combine(Path.GetTempPath(), "mpfever_autotest_bans.txt") : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mpfever_bans.txt") };
                    // (the session's game options, the very string the lobby's "Game settings" and the window's Game tab edit)
                    g.Options = () => PublicOff || server != null ? "" : GameOptions();
                    g.Changed += MenuStatus;
                    // (the host in its game: told in its own chat, the MPFever window shows Accept and Refuse)
                    g.Asked += who =>
                    {
                        var hg = hostGame;
                        if (hg != null && hg.InGame)
                            hg.AppendChat(0, UnixNow(), "msg", "MPFever", F("{0} veut rejoindre la partie : acceptez ou refusez dans la fenêtre MPFever.", "{0} wants to join the game: accept or refuse in the MPFever window.", BaseName(who)));
                    };
                    return pubGate = g;
                }
            }
        }

        /// <summary>The host's own game, as a player hosts it from the main menu (not a dedicated server); an autotest's host too
        /// (the scenario pubtest: its window's Accept, Refuse, Kick and Ban; it never goes into the public list).</summary>
        bool PublicHosting() => !PublicOff && (menuMode || autotest) && server == null && hostGame != null && relay != null && hostName != null;

        /// <summary>Relay.Admit of a player's own game, after the version check (see StartHost).</summary>
        string PublicAdmit(IRelay r, Peer p)
        {
            if (PublicOff || server != null) return null;
            return Gate.Admit(p, () => OthersConnected(r, p), q => r.TrySend(q, Msg.Make("admitwait", "MPFever", "{}")));
        }

        // ---------------------------------------------------------------- the lobby's and the window's requests

        /// <summary>The menu's and the window's requests of the public games (see OnMenuRequest); false: not one of them.
        ///   pubname &lt;text&gt;     the public game's name (empty: the default one)
        ///   admit &lt;name#id&gt; 1|0  the host's answer to an arrival
        ///   kick &lt;name&gt;, ban &lt;name&gt;, unban &lt;name&gt;   (join_bans on)</summary>
        bool PublicMenuRequest(string cmd, string arg)
        {
            if (cmd != "pubname" && cmd != "admit" && cmd != "kick" && cmd != "ban" && cmd != "unban") return false;
            if (PublicOff || server != null) return true;
            var a = (arg ?? "").Trim();
            if (cmd == "pubname")
            {
                var nm = new string(a.Where(ch => !char.IsControl(ch)).ToArray()).Trim();
                if (nm.Length > 40) nm = nm.Substring(0, 40);
                SaveSetting("pubname", nm);
                pubName = null;
            }
            else if (cmd == "admit")
            {
                var parts = a.Split(' ');
                if (parts.Length == 2 && PublicHosting()) Gate.Answer(parts[0], parts[1] == "1");
            }
            else
            {
                var who = new string(a.Where(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '-').ToArray());
                if (who == "" || !PublicHosting() || !Gate.On("join_bans")) return true;
                if (cmd == "unban")
                {
                    if (Gate.RemoveBan(who)) Log.W(F("{0} n'est plus banni de vos parties.", "{0} is no longer banned from your games.", who));
                }
                else if (!string.Equals(who, BaseName(hostName), StringComparison.OrdinalIgnoreCase))
                {
                    var r = relay;
                    if (cmd == "ban")
                    {
                        // (its Steam id or address too, when it is here: a new name does not let it in again)
                        var here = r?.Admitted().Where(p => string.Equals(BaseName(p.Name), who, StringComparison.OrdinalIgnoreCase)).ToList() ?? new List<Peer>();
                        string steam = here.Select(p => p.SteamId).FirstOrDefault(s => !string.IsNullOrEmpty(s)) ?? "";
                        string ip = "";
                        foreach (var p in here)
                            try
                            {
                                if (p.SteamId == null && p.Tcp?.Client?.RemoteEndPoint is IPEndPoint ep)
                                {
                                    var ad = ep.Address.IsIPv4MappedToIPv6 ? ep.Address.MapToIPv4() : ep.Address;
                                    if (!IPAddress.IsLoopback(ad)) ip = ad.ToString();
                                }
                            }
                            catch { }
                        Gate.AddBan(who, steam, ip);
                        Log.W(F("{0} est banni de vos parties.", "{0} is banned from your games.", who));
                    }
                    Gate.Forget(who);
                    int n = r?.Kick(who, "{[\"reason\"]=" + (cmd == "ban" ? "\"banned\"" : "\"kicked\"") + ",[\"game\"]=true}") ?? 0;
                    if (n > 0) Log.W(F("{0} exclu de la partie.", "{0} kicked from the game.", who));
                }
            }
            MenuStatus();
            return true;
        }

        /// <summary>The lobby's view of the public games (menu_state): pub (the list's state for this game: wait, listed, ended,
        /// !old, !off, !steam, !&lt;error&gt;; empty while public is off), pubName, pubIp (the address shown in the list),
        /// pubKick (Kick and Ban shown), pending (the arrivals waiting, name#id), bans ("name|day;...").</summary>
        void PublicMenuState(IDictionary<string, string> ms)
        {
            bool hosting = PublicHosting();
            bool pub = hosting && Gate.On("public");
            bool kick = hosting && Gate.On("join_bans");
            ms["pub"] = pub ? (pubState == "" ? "wait" : pubState) : "";
            ms["pubName"] = pub ? PublicName() : "";
            ms["pubIp"] = pub ? pubShownIp : "";
            ms["pubKick"] = kick ? "1" : "";
            ms["pending"] = hosting ? string.Join(",", Gate.Waiting()) : "";
            ms["bans"] = kick ? string.Join(";", Gate.Bans().Where(b => b.Name != "").Select(b => b.Name + "|" + b.Date)) : "";
        }

        /// <summary>The host's own lines of mp_status.txt (its game's MPFever window, not sent to the players): the arrivals
        /// waiting for its answer, and whether it may kick and ban; (0.6, the window's "Public game" tab, mpfever_feat_public.lua)
        /// the list's state for this game, its name and the address shown (public on), the ban list (join_bans on) and whether
        /// Steam takes the host's friends only. Nothing while those options are off.</summary>
        string PublicHostStatus()
        {
            if (!PublicHosting()) return "";
            string Clean(string s) => (s ?? "").Replace("\r", " ").Replace("\n", " ");
            var w = Gate.Waiting();
            var sb = new StringBuilder();
            if (w.Length > 0) sb.Append("pending=").Append(Clean(string.Join(",", w))).Append('\n');
            bool kick = Gate.On("join_bans");
            if (kick)
            {
                sb.Append("pubkick=1\n");
                var bans = Gate.Bans().Where(b => b.Name != "").Select(b => b.Name + "|" + b.Date).ToList();
                if (bans.Count > 0) sb.Append("bans=").Append(Clean(string.Join(";", bans))).Append('\n');
            }
            if (Gate.On("public"))
            {
                sb.Append("pub=").Append(pubState == "" ? "wait" : Clean(pubState)).Append('\n');
                sb.Append("pubname=").Append(Clean(PublicName())).Append('\n');
                if (pubShownIp != "") sb.Append("pubip=").Append(Clean(pubShownIp)).Append('\n');
            }
            if (steamFriendsSent) sb.Append("pubfriends=1\n");
            var s = sb.ToString();
            // (what the host's window is given, told once each time it changes: for the in-game test)
            if (s != pubStatusSaid)
            {
                pubStatusSaid = s;
                if (s != "") Log.Dim("feat public: the host's window shows " + s.TrimEnd('\n').Replace("\n", ", "));
            }
            return s;
        }
        string pubStatusSaid = "";

        // ---------------------------------------------------------------- the public list

        string pubListId, pubListToken, pubSig = "", pubName, pubBuild;
        // (the list's state for the lobby, see PublicMenuState; the address shown in the list)
        volatile string pubState = "", pubShownIp = "";
        double pubAt = -1000, pubV2At = -1000;
        bool? pubV2;
        // the game was public at some time in this session: strangers may be in it (Steam friends only no more)
        volatile bool pubEver;
        // (the public games' options last told in the log, see PublicGameTick)
        string pubOptsSaid = "";

        string PublicName()
        {
            var n = pubName;
            if (n != null) return n;
            n = LoadSettings().TryGetValue("pubname", out var s) ? s.Trim() : "";
            if (n == "") n = F("Partie de {0}", "{0}'s game", BaseName(hostName));
            return pubName = n;
        }

        /// <summary>Started with the game's menu: once a second, the host's game announced to the public list, or taken out of it,
        /// as its options say; and the Steam friends-only rule kept as they say.</summary>
        void PublicGameLoop()
        {
            while (running)
            {
                Thread.Sleep(1000);
                try { PublicGameTick(); }
                catch (Exception e) { Log.W("public game: " + e.Message); }
            }
        }

        void PublicGameTick()
        {
            bool hosting = PublicHosting();
            bool pub = hosting && Gate.On("public");
            if (pub) pubEver = true;
            if (hosting)
            {
                // (the public games' options as MPFever.exe reads them, told when they change: for the in-game test)
                var mine = string.Join(";", GameOpts.Parse(Gate.Options()).Where(kv => kv.Key.StartsWith("public", StringComparison.Ordinal)
                    || kv.Key.StartsWith("join_", StringComparison.Ordinal)).Select(kv => kv.Key + "=" + kv.Value));
                if (mine != pubOptsSaid) { pubOptsSaid = mine; Log.Dim("feat public: the host's options now " + (mine == "" ? "all off" : mine)); }
                SteamFriendsSync();
            }
            // (nothing listed, nothing to list: the options off, as in 0.5.14)
            if (!pub && pubListId == null && pubState == "") return;
            bool late = Gate.Param("public", "late") == "1";
            var url = ServerListUrl();
            // (never from a test or a developer's game: they would fill the real list)
            bool test = autotest || Dev;
            bool want = pub && url != "" && !test && (lobbyOpen || late);
            string old = pubState;
            if (!want)
            {
                if (pubListId != null) PublicGameRemove();
                pubState = !pub ? "" : url == "" || test ? "!off" : "ended";
            }
            else if (pubV2 != true && (pubV2 == false ? Now - pubV2At >= 300 : Now - pubV2At >= 60))
            {
                // the list takes the players' games (version 2), else an older list would show this one as a server, with this
                // PC's address, and try its port: asked once (again every minute while it does not answer)
                pubV2At = Now;
                pubV2 = ListTakesGames(url);
                pubState = pubV2 == null ? "!down" : pubV2 == false ? "!old" : old;
            }
            else if (pubV2 == true)
            {
                var sid = hostSteamId;
                bool showIp = Gate.Param("public", "ip") == "1";
                pubShownIp = showIp ? (lobbyPublic ?? "").Split(',').Select(x => x.Trim()).FirstOrDefault(x => x != "" && x != "?" && x != "..." && !x.StartsWith("[", StringComparison.Ordinal)) ?? "" : "";
                // (through Steam, or by the address the host shows: without either, nobody could join it)
                if (sid == null && pubShownIp == "") pubState = "!steam";
                else
                {
                    string state = lobbyOpen ? "lobby" : "playing";
                    int players = 1 + (relay?.AdmittedCount ?? 0);
                    int max = Gate.MaxPlayers;
                    var sig = string.Join("|", PublicName(), state, players, max, sid, pubShownIp, late, companyMode, lobbySave);
                    // (every 30 s, at once when something shown changed; the list takes one announce every 10 s)
                    if ((pubListId == null || sig != pubSig || Now - pubAt >= 30) && Now - pubAt >= 11)
                    {
                        pubAt = Now;
                        if (pubBuild == null) { try { pubBuild = Reporter.GameBuild(gameDir) ?? ""; } catch { pubBuild = ""; } }
                        var body = "{\"kind\":\"game\",\"name\":" + JsonStr(PublicName()) + ",\"port\":" + lobbyPort + ",\"version\":" + JsonStr(Version)
                            + ",\"build\":" + JsonStr(pubBuild) + ",\"mode\":" + JsonStr(companyMode) + ",\"world\":" + JsonStr(lobbySave)
                            + ",\"host\":" + JsonStr(BaseName(hostName)) + ",\"lang\":" + JsonStr(L.Code) + ",\"state\":" + JsonStr(state)
                            + ",\"players\":" + players + ",\"max\":" + max + ",\"password\":false,\"joinPlaying\":" + (late ? "true" : "false")
                            + ",\"showAddress\":" + (pubShownIp != "" ? "true" : "false") + ",\"steam\":" + JsonStr(sid ?? "")
                            + ",\"address\":" + JsonStr(pubShownIp) + ",\"token\":" + JsonStr(pubListToken ?? "") + "}";
                        try
                        {
                            var d = Json.Parse(ListRequest(url + "/api/announce", body)) as Dictionary<string, object>;
                            if (d != null && d.TryGetValue("ok", out var ok) && ok is bool okb && okb)
                            {
                                pubListId = d.TryGetValue("id", out var id) ? id as string : pubListId;
                                pubListToken = d.TryGetValue("token", out var tk) ? tk as string : pubListToken;
                                pubSig = sig;
                                if (pubState != "listed") Log.Ok(F("Partie publique : la partie apparaît dans la liste publique ({0}).", "Public game: the game is in the public list ({0}).", url));
                                pubState = "listed";
                            }
                            else if (d != null && d.TryGetValue("error", out var err) && !(err as string ?? "").StartsWith("too often", StringComparison.Ordinal))
                            {
                                Log.Warn(F("Liste des serveurs : {0}", "Server list: {0}", err));
                                pubState = "!" + err;
                            }
                        }
                        catch (Exception e)
                        {
                            Log.Dim(F("Liste des serveurs injoignable : {0}", "Server list unreachable: {0}", e.Message));
                            pubState = "!down";
                        }
                    }
                }
            }
            if (pubState != old) MenuStatus();
        }

        /// <summary>Whether the list takes the players' games (GET /api/health says "v":2 or more); null: it does not answer.</summary>
        static bool? ListTakesGames(string url)
        {
            try
            {
                var d = Json.Parse(ListRequest(url + "/api/health", null)) as Dictionary<string, object>;
                return d != null && d.TryGetValue("v", out var v) && v is double dv && dv >= 2;
            }
            catch { return null; }
        }

        /// <summary>The game leaves the public list now (else after 90 s).</summary>
        void PublicGameRemove()
        {
            string id = pubListId, tok = pubListToken, url = ServerListUrl();
            pubListId = null; pubSig = "";
            if (id == null || url == "") return;
            try { ListRequest(url + "/api/remove", "{\"id\":" + JsonStr(id) + ",\"token\":" + JsonStr(tok) + "}"); } catch { }
            Log.W(T("Partie publique : la partie a quitté la liste publique.", "Public game: the game left the public list."));
        }

        /// <summary>The session ends (EndSession): out of the list (on a thread of its own: the list may be slow), arrivals still
        /// waiting refused, this session's public state forgotten.</summary>
        void PublicSessionEnd()
        {
            if (pubGate != null) Gate.EndSession();
            steamHostLine = null;
            pubEver = false; pubV2 = null; pubV2At = -1000; pubAt = -1000; pubName = null; pubState = ""; pubShownIp = "";
            steamFriendsSent = false; pubOptsSaid = ""; pubStatusSaid = "";
            if (pubListId != null) new Thread(PublicGameRemove) { IsBackground = true, Name = "Public game out" }.Start();
        }

        // ---------------------------------------------------------------- Steam: friends only (a private game)

        // the host's Steam listen command of this session (StartHost) without its friends-only flag, the game's folder, and the
        // flag last sent: the command is sent again (same port and secret: the connections stay) when the flag must change
        string steamHostLine, steamHostDir;
        bool steamFriendsSent;

        bool SteamFriendsWanted() => !PublicOff && server == null && Gate.On("join_steamfriends") && !Gate.On("public") && !pubEver;

        /// <summary>The game module's "host" command of StartHost: with " friends" when the host's options keep Steam connections
        /// to its Steam friends (a private game); as before otherwise.</summary>
        string SteamHostCommand(string dir, int port, string secret)
        {
            steamHostDir = dir;
            steamHostLine = "host " + port + " " + secret;
            steamFriendsSent = SteamFriendsWanted();
            if (steamFriendsSent) Log.W(T("Steam : seuls vos amis Steam peuvent rejoindre par Steam.", "Steam: only your Steam friends can join through Steam."));
            return steamHostLine + (steamFriendsSent ? " friends" : "");
        }

        void SteamFriendsSync()
        {
            var line = steamHostLine;
            if (line == null || hostSteamId == null) return;
            bool want = SteamFriendsWanted();
            if (want == steamFriendsSent) return;
            steamFriendsSent = want;
            try { SteamNet.Cmd(steamHostDir, line + (want ? " friends" : "")); } catch (Exception e) { Log.W("steamnet: " + e.Message); return; }
            // (the game module's answer is in its own log: "not a friend" for a stranger refused, see the in-game checks)
            Log.Dim("feat public: the game module's host command sent again, Steam friends only " + (want ? "on" : "off"));
            Log.W(want ? T("Steam : seuls vos amis Steam peuvent rejoindre par Steam.", "Steam: only your Steam friends can join through Steam.")
                : T("Steam : tout le monde peut de nouveau rejoindre par Steam.", "Steam: everybody can join through Steam again."));
        }

        // ---------------------------------------------------------------- autotest

        /// <summary>Autotest pubtest (MPFEVER_SCENARIO=pubtest, the autotest's two games): the public games' options switched on
        /// for the session (public with 3 players at most, join_bans, join_approve: the scenario's own, never written into
        /// mpfever_settings.txt; an autotest never goes into the public list), every game takes them (f_opts); a stranger (a
        /// connection of this MPFever.exe named Stranger) waits for the host's answer while both games show their MPFever window's
        /// "Public game" tab, then the Session tab (the bridge's H.pubtest: the host's offer Accept and Refuse); the host refuses
        /// it, bans it (refused when it comes back), takes the ban back, through the requests of the window's buttons; the options
        /// off again. Each check is a line "pubtest: ok/FAIL ..." of the autotest's report; the games are compared afterwards as
        /// after every scenario.</summary>
        void RunPubTest()
        {
            void Line(bool ok, string what) => AutoLine("pubtest: " + (ok ? "ok    " : "FAIL  ") + what);
            bool Wait(Func<bool> f, double s) { var end = Now + s; while (Now < end && !f()) Thread.Sleep(200); return f(); }
            if (PublicOff) { AutoLine("pubtest: MPFEVER_PUBLICGAMES=0, nothing tested"); return; }
            if (Environment.GetEnvironmentVariable("MPFEVER_ANYVERSION") == "1") { AutoLine("pubtest: MPFEVER_ANYVERSION=1 checks no arrival, nothing tested"); return; }
            int port = relay?.Port ?? 0;
            try { File.Delete(Gate.BanFile); } catch { }
            gameOptsTest = "join_approve=1;join_bans=1;public=1;public.max=3";
            BroadcastSession();
            Line(PublicHosting() && Gate.On("public") && Gate.On("join_approve") && Gate.On("join_bans") && Gate.MaxPlayers == 3, "the options read by MPFever.exe: " + GameOptions());
            // (the host's game puts them into the game at once: f_opts, applied by both games at the same step)
            Thread.Sleep(8000);
            var clients = new List<Client>();
            Dictionary<object, object> denied = null;
            int waits = 0;
            void Join()
            {
                denied = null; waits = 0;
                var c = new Client();
                c.Denied += d => denied = d;
                c.Waiting += () => Interlocked.Increment(ref waits);
                clients.Add(c);
                c.Connect("127.0.0.1", port, "Stranger");
            }
            string Reason() { var d = denied; return d != null && d.TryGetValue("reason", out var r) ? r as string : null; }
            try
            {
                Join();
                bool asked = Wait(() => Gate.Waiting().Length == 1 && waits > 0, 15);
                Line(asked, "a stranger waits for the host's answer, told so (" + string.Join(",", Gate.Waiting()) + ")");
                Thread.Sleep(1500);
                Line(PublicHostStatus().Contains("pending=Stranger#"), "the host's window is given the arrival (pending=)");
                // (both games: the options in the game, the window's tabs; the arrival waits meanwhile, 120 s at most)
                lock (autoDone) { autoDone.Remove("host"); autoDone.Remove("client"); }
                foreach (var r in new[] { "host", "client" }) HostSend(Msg.Make("pubtest", hostName, "{[\"role\"]=\"" + r + "\"}"));
                WaitUntil(() => { lock (autoDone) return (autoDone.ContainsKey("host") && autoDone.ContainsKey("client")) || ClosedGames() != ""; }, 90);
                lock (autoDone) foreach (var r in new[] { "host", "client" }) AutoLine("pubtest: " + r + " game: " + (autoDone.ContainsKey(r) ? autoDone[r] : "TIMEOUT"));
                // the host's answer, as the window's Refuse button asks it
                var who = Gate.Waiting().FirstOrDefault();
                PublicMenuRequest("admit", (who ?? "Stranger") + " 0");
                Line(who != null && Wait(() => denied != null, 10) && Reason() == "refused", "refused by the host (" + Reason() + ")");
                // banned (the Ban button), refused at once when it comes back; the ban taken back (Remove)
                PublicMenuRequest("ban", "Stranger");
                Line(Gate.BannedAs("Stranger", "", "") != null && PublicHostStatus().Contains("bans=Stranger|"), "banned, the host's window lists it (bans=)");
                Join();
                Line(Wait(() => denied != null, 10) && Reason() == "banned" && Gate.Waiting().Length == 0, "a banned player refused before asking (" + Reason() + ")");
                PublicMenuRequest("unban", "Stranger");
                Line(Gate.BannedAs("Stranger", "", "") == null, "the ban taken back");
            }
            catch (Exception e) { Line(false, "error " + e.Message); }
            finally
            {
                foreach (var c in clients) try { c.Dispose(); } catch { }
                Gate.EndSession();
                try { File.Delete(Gate.BanFile); } catch { }
                // (all off again for what follows: nothing of them stays in the games)
                gameOptsTest = "";
                BroadcastSession();
                Thread.Sleep(8000);
                Line(!Gate.On("public") && PublicHostStatus() == "", "the options off again: nothing given to the host's window");
            }
        }
    }
}
