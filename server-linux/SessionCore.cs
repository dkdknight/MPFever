using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;

namespace MPFever.LinuxServer
{
    /// <summary>Settings of the server (command line).</summary>
    sealed class ServerOptions
    {
        public int Port = 28090;
        public string Password = "";
        public int MaxPlayers = 8;
        public string Name = "MPFever Linux Server";
        /// <summary>Seconds a chosen successor has to say host_ready before the next player is asked (host migration).</summary>
        public int MigrationTimeoutSeconds = 120;
        /// <summary>When the host leaves: pass the session to the next player (true), or end the session (false, as with a normal host).</summary>
        public bool Migration = false;
    }

    /// <summary>
    /// The Linux server is a tunnel between the players and the one player that hosts (docs/LINUX-RELAY.md).
    ///
    /// The host's brain (the launcher's MainForm.OnHostMessage: ordering of the actions, clocks, speed, hashes, resyncs, lobby, checks)
    /// stays in that player's launcher, unchanged. What the server adds is the address everybody reaches (the host needs no open
    /// port), the admission rules, and the choice of the host. Wire format between the server and the host's launcher:
    ///
    ///   server -> host   tun_host  { you, epoch }                  this connection is the host
    ///                    tun_join  { name, addr }                  a player was let in (name = "Name#n")
    ///                    tun_left  { name }                        a player is gone
    ///                    any other message of a player, unchanged kind and payload, From = that player's name
    ///   host -> server   kind                                      to every player
    ///                    !Name#n:kind                              to every player but that one
    ///                    @Name#n:kind                              to that player only
    ///                    tun_kick { name, payload }                refuse a player (payload: the "denied" payload)
    ///
    /// What a player sees is what it would see from a host of its own: the server forwards the host's messages as they are (From is
    /// the host's name without its "#n"), except the "rtok" of a welcome, which is replaced by the player's link with the server.
    /// </summary>
    sealed partial class SessionCore
    {
        readonly Relay relay;
        readonly ServerOptions opt;
        readonly object sendGate = new object();   // every message to the players goes through it: all of them get the host's messages in order

        public SessionCore(Relay relay, ServerOptions opt)
        {
            this.relay = relay;
            this.opt = opt;
            relay.Admit = Admit;
            relay.Joined += OnJoined;
            relay.Left += OnLeft;
            relay.MayWait = p => false;
            relay.Received += (p, m) => OnMessage(m, p);
        }

        public string HostName => opt.Name;

        // ---------------------------------------------------------------- admission

        /// <summary>The "denied" payload for a player who may not come in (the rules of the dedicated server, Server.cs: Admission), else null.</summary>
        string Admit(Peer p, Msg m)
        {
            var t = LuaLit.Parse(m.Payload ?? "") as Dictionary<object, object> ?? new Dictionary<object, object>();
            string S(string k) => t.TryGetValue(k, out var v) && v is string sv ? sv : "";
            string reason = null, extra = "";
            var me = BaseName(p.Name);
            int others = relay.Admitted().Count(o => o != p && !string.Equals(BaseName(o.Name), me, StringComparison.OrdinalIgnoreCase));
            if (S("v") != MainForm.Version) { reason = "version"; extra = ",[\"v\"]=" + LuaLit.Quote(MainForm.Version); }
            else if (opt.Password != "" && S("pw") != opt.Password) reason = "password";
            else if (others >= opt.MaxPlayers) { reason = "full"; extra = ",[\"max\"]=" + opt.MaxPlayers; }
            else if (WantsHost(t) && HasHost && !IsAwaitedSuccessor(me)) reason = "hosted";   // somebody hosts this server already: join it
            else if (!WantsHost(t) && !HasHost) reason = "nohost";    // nobody hosts it yet: somebody must host first
            if (reason == null && WantsHost(t)) lock (hostGate) hostJoins.Add(p);
            if (reason != null) Log.Warn(BaseName(p.Name) + " (" + p.Address + ") refused: " + reason);
            return reason == null ? null : "{[\"reason\"]=" + LuaLit.Quote(reason) + extra + "}";
        }

        static bool WantsHost(Dictionary<object, object> join) => join.TryGetValue("host", out var h) && h is bool b && b;

        /// <summary>"Name#3" -> "Name": the relay adds #n to the names of the players who join.</summary>
        public static string BaseName(string name)
        {
            if (name == null) return "";
            int i = name.LastIndexOf('#');
            return i > 0 ? name.Substring(0, i) : name;
        }

        // ---------------------------------------------------------------- joining and leaving

        void OnJoined(Peer p)
        {
            Log.Ok(p.Name + " connected");
            HostJoined(p);
            relay.DropOlder(p);   // (after: a successor that reconnects as the host closes its own guest connection, which must no longer count as the candidate)
        }

        void OnLeft(Peer p)
        {
            Log.W(p.Name + " left");
            HostLeft(p);
        }

        void ToHost(Peer host, Msg m) { if (host != null) lock (sendGate) relay.Send(host, m); }

        /// <summary>Tells the host's launcher that a player came in.</summary>
        void AnnounceJoin(Peer host, Peer p)
        {
            ToHost(host, Msg.Make("tun_join", p.Name, "{[\"name\"]=" + LuaLit.Quote(p.Name) + ",[\"addr\"]=" + LuaLit.Quote(p.Address ?? "") + "}"));
        }

        // ---------------------------------------------------------------- messages

        void OnMessage(Msg m, Peer from)
        {
            Peer host; bool fromHost;
            lock (hostGate) { host = this.host; fromHost = from == this.host; }

            if (m.Kind == "host_ready") { OnHostReady(m, from); return; }

            if (fromHost) { FromHost(m, from); return; }

            // a player's message: for the host's launcher to handle
            if (host != null) ToHost(host, m);
        }

        /// <summary>What the host's launcher sent: to everybody, to one player ("@name:kind"), or a control message.</summary>
        void FromHost(Msg m, Peer host)
        {
            m.From = BaseName(host.Name);   // (the relay put the host's connection name there: the players know the host without its #n)
            if (m.Kind == "tun_kick")
            {
                var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                string name = t != null && t.TryGetValue("name", out var nv) ? nv as string : null;
                string payload = t != null && t.TryGetValue("payload", out var pv) ? pv as string : null;
                var target = name == null ? null : relay.Find(name);
                if (target != null && target != host) new Thread(() => relay.Deny(target, payload ?? "{[\"reason\"]=\"kicked\"}")) { IsBackground = true }.Start();
                return;
            }
            if (m.Kind.Length > 1 && m.Kind[0] == '@')
            {
                int i = m.Kind.IndexOf(':');
                if (i < 0) return;
                var target = relay.Find(m.Kind.Substring(1, i - 1));
                if (target == null || target == host) return;
                m.Kind = m.Kind.Substring(i + 1);
                lock (sendGate) relay.Send(target, Fix(m, target));
                return;
            }
            // "!name:kind": to everybody but that player (the host's Broadcast(m, except))
            Peer except = null;
            if (m.Kind.Length > 1 && m.Kind[0] == '!')
            {
                int i = m.Kind.IndexOf(':');
                if (i > 0) { except = relay.Find(m.Kind.Substring(1, i - 1)); m.Kind = m.Kind.Substring(i + 1); }
            }
            lock (sendGate)
                foreach (var q in relay.Admitted()) if (q != host && q != except) relay.Send(q, Fix(m, q));
        }

        static readonly Regex RtokRx = new Regex("\\[\"rtok\"\\]=\"[^\"]*\"", RegexOptions.Compiled);

        /// <summary>A copy for this player: a welcome carries the player's link with the server, not the host's.</summary>
        static Msg Fix(Msg m, Peer to)
        {
            if (m.Kind != "welcome" || to.Link == null) return m;
            return new Msg { Kind = m.Kind, From = m.From, Payload = RtokRx.Replace(m.Payload ?? "", "[\"rtok\"]=" + LuaLit.Quote(to.Link.Token ?? "")) };
        }
    }
}
