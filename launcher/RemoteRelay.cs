using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace MPFever
{
    /// <summary>
    /// The host's side when it hosts through an MPFever relay (relay/, docs/RELAY.md) instead of listening itself: the same
    /// surface as Relay (IRelay), so the host's code (MainForm.OnHostMessage and the session around it) is unchanged. The host is one
    /// connection to the relay; the relay tells it which players came in and left (tun_join, tun_left) and forwards what they send,
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
        // (the relay waits for the players who drop, and tells the host only when one is really gone: no Away, no Resumed)
        public event Action<Peer> Away { add { } remove { } }
        public event Action<Peer, double, int> Resumed { add { } remove { } }
        /// <summary>The connection to the relay was lost: the session cannot go on.</summary>
        public event Action<string> Lost;

        // The relay checks the relay protocol, password and places and waits for players who drop.
        // The host supplies Admit for its own version and public-game rules.
        public Func<Peer, bool> MayWait { get; set; }
        public double Grace { get; set; }
        public Func<Peer, Msg, string> Admit { get; set; }
        public string SteamSecret { get; set; }

        /// <summary>The host wants the session to end with it: no player takes over ("handover=0", told to the relay in the join).</summary>
        public bool NoHandover;

        /// <summary>(0.9.3) The key a relay with --host-key wants from its host.</summary>
        public string HostKey;

        /// <summary>(0.9.3) What the relay tells the public list about this host (a relay started with --list-url and --host-key; another relay ignores it): the launcher's own announce body.</summary>
        public void SendListInfo(string json)
        {
            try { client.Send(Msg.Make("tun_list", "-", "{[" + (char)34 + "json" + (char)34 + "]=" + LuaLit.Quote(json) + "}")); } catch { }
        }

        /// <summary>The host's name on the relay ("Name#n").</summary>
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

        /// <summary>Connects to the relay as its host. Throws with the relay's reason when it refuses (another host, wrong password,
        /// relay protocol...).</summary>
        public void Connect(string host, int port, string name, string password, string migrationToken = null)
        {
            client.Received += OnRelayMessage;
            client.Denied += d => { denied = d.TryGetValue("reason", out var r) ? r as string : "?"; hosted.Set(); };
            client.Closed += () => { if (!stop) { Lose("connection to the relay closed"); } hosted.Set(); };
            client.NoHandover = NoHandover;
            client.HostKey = HostKey;
            client.Connect(host, port, name, password, false, true, false, migrationToken);
            hosted.Wait(TimeSpan.FromSeconds(15));
            if (denied != null) throw new InvalidOperationException(denied);
            if (Me == null) throw new TimeoutException("the relay did not answer");
        }

        // ---------------------------------------------------------------- the save the relay keeps (CheckpointWire, relay/CheckpointProtocol.cs)

        readonly object cpGate = new object();
        readonly Dictionary<string, Msg> cpReplies = new Dictionary<string, Msg>();

        static byte[] Sha256(byte[] data) { using (var h = System.Security.Cryptography.SHA256.Create()) return h.ComputeHash(data); }
        static readonly System.Diagnostics.Stopwatch clockWatch = System.Diagnostics.Stopwatch.StartNew();
        static long Now() => clockWatch.ElapsedMilliseconds;

        Msg CpSend(Msg m, string id, int ms)
        {
            lock (cpGate) cpReplies.Remove(id);
            client.Send(m);
            var end = Now() + ms;
            lock (cpGate)
                while (!cpReplies.ContainsKey(id))
                {
                    long left = end - Now();
                    if (left <= 0 || stop) return null;
                    Monitor.Wait(cpGate, (int)Math.Min(left, 500));
                }
            lock (cpGate) { var r = cpReplies[id]; cpReplies.Remove(id); return r; }
        }

        static string CpStatus(Msg r) => r == null ? "timeout" : CheckpointWire.Text(CheckpointWire.Read(r), "status") ?? "invalid";

        string CpRequest(string body, int ms = 30000)
        {
            string id = Guid.NewGuid().ToString("N");
            return CpStatus(CpSend(Msg.Make(CheckpointWire.Request, "-", "{" + CheckpointWire.Field("id", id) + "," + body + "}"), id, ms));
        }

        /// <summary>Sends the save to the relay, which keeps it when it is complete (its SHA-256 is checked). "saved" or the reason it was not.</summary>
        public string UploadCheckpoint(string key, byte[] data)
        {
            if (data == null || data.Length == 0 || data.Length > CheckpointWire.MaxSize) return "invalid";
            string sha = CheckpointWire.Hex(Sha256(data));
            string status = CpRequest(CheckpointWire.Field("op", "begin") + "," + CheckpointWire.Field("key", key ?? "") + "," + CheckpointWire.Field("size", data.Length) + "," + CheckpointWire.Field("sha", sha));
            if (status != "upload") return status;
            for (int off = 0; off < data.Length; off += CheckpointWire.UploadChunkSize)
            {
                var chunk = new byte[Math.Min(CheckpointWire.UploadChunkSize, data.Length - off)];
                Buffer.BlockCopy(data, off, chunk, 0, chunk.Length);
                string id = Guid.NewGuid().ToString("N");
                var r = CpSend(new Msg { Kind = CheckpointWire.Binary, From = "-", Data = chunk,
                    Payload = "{" + CheckpointWire.Field("id", id) + "," + CheckpointWire.Field("len", chunk.Length) + "}" }, id, 30000);
                if (CpStatus(r) != "part") return CpStatus(r);
            }
            return CpRequest(CheckpointWire.Field("op", "commit"));
        }

        /// <summary>Reads the save the relay keeps (null with the reason in status: denied, empty, ...). The hash is checked.</summary>
        public byte[] DownloadCheckpoint(string key, out string status)
        {
            string id = Guid.NewGuid().ToString("N");
            var open = CpSend(Msg.Make(CheckpointWire.Request, "-", "{" + CheckpointWire.Field("id", id) + "," + CheckpointWire.Field("op", "open") + "," + CheckpointWire.Field("key", key ?? "") + "}"), id, 30000);
            status = CpStatus(open);
            if (status != "download") return null;
            var f = CheckpointWire.Read(open);
            if (!CheckpointWire.Number(f, "size", CheckpointWire.MaxSize, out long size) || size == 0) { status = "invalid"; return null; }
            string sha = CheckpointWire.Text(f, "sha");
            var data = new byte[size];
            long got = 0;
            while (got < size)
            {
                string rid = Guid.NewGuid().ToString("N");
                var r = CpSend(Msg.Make(CheckpointWire.Request, "-", "{" + CheckpointWire.Field("id", rid) + "," + CheckpointWire.Field("op", "read") + "," + CheckpointWire.Field("offset", got) + "}"), rid, 30000);
                if (r == null) { status = "timeout"; return null; }
                if (r.Kind != CheckpointWire.Binary || r.Data == null || r.Data.Length == 0 || got + r.Data.Length > size) { status = CpStatus(r); return null; }
                Buffer.BlockCopy(r.Data, 0, data, (int)got, r.Data.Length);
                got += r.Data.Length;
            }
            if (!string.Equals(CheckpointWire.Hex(Sha256(data)), sha, StringComparison.OrdinalIgnoreCase)) { status = "invalid"; return null; }
            status = CpRequest(CheckpointWire.Field("op", "loaded"));
            if (status != "ready") return null;
            return data;
        }

        /// <summary>After a takeover: waits until the relay has announced every player that was there (tun_players). False on timeout.</summary>
        public bool WaitPlayersAnnounced(int milliseconds) => announced.Wait(milliseconds);

        void OnRelayMessage(Msg m)
        {
            // (the relay's own kinds come from the relay only, which drops a player's: nothing else is taken for a control message)
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
                case CheckpointWire.Reply:
                case CheckpointWire.Binary:
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string id = t != null && t.TryGetValue("id", out var iv) ? iv as string : null;
                        if (id != null) lock (cpGate) { cpReplies[id] = m; Monitor.PulseAll(cpGate); }
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
                        // The relay checks the password, the places and the relay protocol; the rest of the admission is the host's, as with a host that
                        // listens itself (the same MPFever version between players, the rules of a public game...). Admit receives the version
                        // from tun_join. A refused player gets the host's own "denied" and never reaches Joined.
                        var admit = Admit;
                        if (admit != null)
                        {
                            string refused = null;
                            try { refused = admit(p, Msg.Make("join", name, "{[\"v\"]=" + LuaLit.Quote(t.TryGetValue("v", out var vv) ? vv as string ?? "" : "") + "}")); }
                            catch (Exception e) { Log.Warn("admit: " + e.Message); }
                            if (refused != null) { Deny(p, refused); return; }
                        }
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
            Log.Err("Relay: " + why);
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
            catch (Exception e) { Log.Warn("sending to the relay: " + e.Message); return false; }
        }

        /// <summary>Refuses a player: it is told why ("denied" with this payload) and disconnected by the relay.</summary>
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
