using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace MPFever
{
    /// <summary>
    /// The host's side when it hosts through an MPFever server (server-linux/, docs/LINUX-RELAY.md) instead of listening itself: the same
    /// surface as Relay (IRelay), so the host's code (MainForm.OnHostMessage and the session around it) is unchanged. The host is one
    /// connection to the server; the server tells it which players came in and left (tun_join, tun_left) and forwards what they send,
    /// and the host's messages go through it: "kind" to every player, "!name:kind" to every player but one, "@name:kind" to one.
    /// </summary>
    sealed class RemoteRelay : IRelay
    {
        readonly Client client = new Client();
        readonly Dictionary<string, Peer> peers = new Dictionary<string, Peer>();
        readonly object gate = new object();
        readonly ManualResetEventSlim hosted = new ManualResetEventSlim(false);
        readonly ManualResetEventSlim announced = new ManualResetEventSlim(false);
        string denied;
        int nextId = 1;
        volatile bool stop;

        public event Action<Peer, Msg> Received;
        public event Action<Peer> Joined, Left;
        // (the server waits for the players who drop, and tells the host only when one is really gone: no Away, no Resumed)
        public event Action<Peer> Away { add { } remove { } }
        public event Action<Peer, double, int> Resumed { add { } remove { } }
        /// <summary>The connection to the server was lost: the session cannot go on.</summary>
        public event Action<string> Lost;

        // The server admits the players (version, password, places) and waits for those who drop (it has its own link with each):
        // these are the Relay's settings, of no use here.
        public Func<Peer, bool> MayWait { get; set; }
        public double Grace { get; set; }
        public Func<Peer, Msg, string> Admit { get; set; }
        public string SteamSecret { get; set; }

        /// <summary>The host's name on the server ("Name#n").</summary>
        public string Me { get; private set; }
        public int Epoch { get; private set; }

        public int Count { get { lock (gate) return peers.Count; } }
        public int AdmittedCount { get { lock (gate) return peers.Count; } }
        public int Port => 0;
        public string[] PeerNames() { lock (gate) return peers.Keys.ToArray(); }
        public Peer[] Admitted() { lock (gate) return peers.Values.ToArray(); }
        public Peer Find(string name) { lock (gate) return peers.TryGetValue(name ?? "", out var p) ? p : null; }
        public Dictionary<string, double> AwayNames() => new Dictionary<string, double>();
        public BulkLink[] BulkOf(Peer p) => new BulkLink[0];
        public void Start(int port) { }
        public void DropOlder(Peer p) { }
        public void FinalizeAway(string why) { }

        /// <summary>Connects to the server as its host. Throws with the server's reason when it refuses (another host, wrong password,
        /// version...).</summary>
        public void Connect(string host, int port, string name, string password, string migrationToken = null)
        {
            client.Received += OnServerMessage;
            client.Denied += d => { denied = d.TryGetValue("reason", out var r) ? r as string : "?"; hosted.Set(); };
            client.Closed += () => { if (!stop) { Lose("connection to the server closed"); } hosted.Set(); };
            client.Connect(host, port, name, password, false, true, false, migrationToken);
            hosted.Wait(TimeSpan.FromSeconds(15));
            if (denied != null) throw new InvalidOperationException(denied);
            if (Me == null) throw new TimeoutException("the server did not answer");
        }

        /// <summary>After a takeover: waits until the server has announced every player that was there (tun_players). False on timeout.</summary>
        public bool WaitPlayersAnnounced(int milliseconds) => announced.Wait(milliseconds);

        void OnServerMessage(Msg m)
        {
            // (the server's own kinds come from the server only, which drops a player's: nothing else is taken for a control message)
            switch (m.Kind)
            {
                case "tun_host":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        Me = t != null && t.TryGetValue("you", out var y) ? y as string : null;
                        Epoch = t != null && t.TryGetValue("epoch", out var e) && e is double ed ? (int)ed : 0;
                        hosted.Set();
                        return;
                    }
                case "tun_players":
                    // (after a takeover: every player that was there has been announced, see Joined)
                    announced.Set();
                    return;
                case "tun_join":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string name = t != null && t.TryGetValue("name", out var n) ? n as string : null;
                        if (string.IsNullOrEmpty(name)) return;
                        var p = new Peer { Id = Interlocked.Increment(ref nextId), Name = name, Admitted = true,
                            Address = t.TryGetValue("addr", out var a) ? a as string : "" };
                        lock (gate) peers[name] = p;
                        Joined?.Invoke(p);
                        return;
                    }
                case "tun_left":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string name = t != null && t.TryGetValue("name", out var n) ? n as string : null;
                        Peer p;
                        lock (gate) { if (name == null || !peers.TryGetValue(name, out p)) return; peers.Remove(name); }
                        Left?.Invoke(p);
                        return;
                    }
            }
            Peer from = Find(m.From);
            if (from == null) return;   // (a message of a player the host was not told about)
            Received?.Invoke(from, m);
        }

        void Lose(string why)
        {
            Log.Err("Server: " + why);
            Peer[] all;
            lock (gate) { all = peers.Values.ToArray(); peers.Clear(); }
            foreach (var p in all) Left?.Invoke(p);
            Lost?.Invoke(why);
        }

        // ---------------------------------------------------------------- sending

        public void Send(Peer p, Msg m) => TrySend(p, m);

        public bool TrySend(Peer p, Msg m) => Forward("@" + p.Name + ":", m);

        public void Broadcast(Msg m, Peer except = null) => Forward(except == null ? "" : "!" + except.Name + ":", m);

        bool Forward(string prefix, Msg m)
        {
            if (stop) return false;
            try
            {
                client.Send(new Msg { Kind = prefix + m.Kind, From = m.From, Payload = m.Payload, Data = m.Data });
                return true;
            }
            catch (Exception e) { Log.Warn("sending to the server: " + e.Message); return false; }
        }

        /// <summary>Refuses a player: it is told why ("denied" with this payload) and disconnected by the server.</summary>
        public void Deny(Peer p, string payload)
        {
            try { client.Send(Msg.Make("tun_kick", "-", "{[\"name\"]=" + LuaLit.Quote(p.Name) + ",[\"payload\"]=" + LuaLit.Quote(payload ?? "") + "}")); }
            catch (Exception e) { Log.Warn("kick: " + e.Message); }
        }

        public int Kick(string name, string payload)
        {
            Peer[] found;
            lock (gate) found = peers.Values.Where(p => string.Equals(BaseOf(p.Name), name, StringComparison.OrdinalIgnoreCase) || p.Name == name).ToArray();
            foreach (var p in found) Deny(p, payload);
            return found.Length;
        }

        static string BaseOf(string n) { if (n == null) return ""; int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }

        public void Dispose()
        {
            stop = true;
            try { client.Leave(); } catch { }
        }
    }
}
