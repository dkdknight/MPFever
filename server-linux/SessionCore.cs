using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
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
        /// <summary>Seconds a successor has to connect as the host before the next player is asked (host migration).</summary>
        public int MigrationTimeoutSeconds = 120;
        /// <summary>When the host leaves: pass the session to a player that can take over (true), or end the session (false, as with a normal host).</summary>
        public bool Migration = false;
        /// <summary>Seconds a connection may stay without being let in (0: no limit).</summary>
        public int UnadmittedTimeoutSeconds = 15;
        /// <summary>Connections accepted at once, let in or not (0: no limit).</summary>
        public int MaxConnections = 64;
        /// <summary>Seconds a guest that drops is waited for (0: not waited for). The host is never waited for: a migration starts.</summary>
        public int Grace = 60;
        /// <summary>Wrong passwords from one address before it is refused for LockoutSeconds (0: never).</summary>
        public int MaxBadPasswords = 5;
        public int LockoutSeconds = 300;
        /// <summary>Directory where the latest complete save of the session is kept (null: nothing is kept).</summary>
        public string CheckpointDirectory;
        /// <summary>Key of the host that may store and read the save (the owner).</summary>
        public string CheckpointOwnerKey = "";
        /// <summary>EXPERIMENTAL: a key that lets another player read the save and host from it when nobody hosts.</summary>
        public string CheckpointRecoveryKey = "";
        public bool ResumeWithoutHost;
    }

    /// <summary>
    /// The Linux server is a tunnel between the players and the one player that hosts (docs/LINUX-RELAY.md).
    ///
    /// The host's brain (the launcher's MainForm.OnHostMessage: ordering of the actions, clocks, speed, hashes, resyncs, lobby, checks)
    /// stays in that player's launcher, unchanged. What the server adds is the address everybody reaches (the host needs no open
    /// port), the admission rules, and the choice of the host. Wire format between the server and the host's launcher:
    ///
    ///   server -> host   tun_host  { you, epoch, migrate, prev, token }   this connection is the host (see Hosting.cs for a migration)
    ///                    tun_join  { name, addr, v }               a player was let in (name = "Name#n"; v = its MPFever version: the host
    ///                                                              decides whether it accepts that version, as a host that listens itself does)
    ///                    tun_left  { name }                        a player is gone for good (a guest that drops is waited for first)
    ///                    tun_players { n }                         after a takeover: the n players already there were all announced
    ///                    any other message of a player, unchanged kind and payload, From = that player's name
    ///   host -> server   kind                                      to every player
    ///                    !Name#n:kind                              to every player but that one
    ///                    @Name#n:kind                              to that player only
    ///                    tun_kick { name, payload }                refuse a player (payload: the "denied" payload)
    ///
    /// Kinds that start with "tun_" are the server's own: a player's message of that kind is dropped, never passed on. What a player sees is
    /// what it would see from a host of its own: the server forwards the host's messages as they are (From is the host's name without its
    /// "#n"), except the "rtok" of a welcome, which is replaced by the player's link with the server.
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
            if (!string.IsNullOrEmpty(opt.CheckpointDirectory)) checkpoint = new RelayCheckpoint(opt.CheckpointDirectory);
            relay.StrictBeforeAdmission = true;
            relay.UnadmittedTimeoutSeconds = opt.UnadmittedTimeoutSeconds;
            relay.MaxConnections = opt.MaxConnections;
            // a guest that drops is waited for, as a host of its own would (its launcher goes on with its link); the host is not: a migration starts
            relay.Grace = opt.Grace;
            relay.MayWait = p => opt.Grace > 0 && !IsHost(p);
            relay.Received += (p, m) => OnMessage(m, p);
        }

        public string HostName => opt.Name;
        /// <summary>Control messages (tun_*) that players sent and the server dropped.</summary>
        public int DroppedControl;

        bool IsHost(Peer p) { lock (hostGate) return host == p || (phase == Phase.AwaitingSuccessor && candidate == p && IsHostJoin(p)); }

        // ---------------------------------------------------------------- admission

        readonly Dictionary<string, BadPasswords> badPasswords = new Dictionary<string, BadPasswords>();
        sealed class BadPasswords { public int Count; public DateTime Since; public DateTime LockedUntil; }

        static string AddressOf(Peer p)
        {
            var a = p.Address ?? "";
            int i = a.LastIndexOf(':');
            return i > 0 ? a.Substring(0, i) : a;   // (without the port: one address, not one connection)
        }

        bool LockedOut(string ip)
        {
            lock (badPasswords) return badPasswords.TryGetValue(ip, out var b) && b.LockedUntil > DateTime.UtcNow;
        }

        void NoteBadPassword(string ip)
        {
            if (opt.MaxBadPasswords <= 0) return;
            lock (badPasswords)
            {
                var now = DateTime.UtcNow;
                if (badPasswords.Count >= 10000 && !badPasswords.ContainsKey(ip)) return;   // (a hard limit: addresses cost memory)
                if (badPasswords.Count > 1000) foreach (var k in badPasswords.Where(kv => kv.Value.LockedUntil < now && now - kv.Value.Since > TimeSpan.FromSeconds(opt.LockoutSeconds)).Select(kv => kv.Key).ToList()) badPasswords.Remove(k);
                if (!badPasswords.TryGetValue(ip, out var b) || now - b.Since > TimeSpan.FromSeconds(opt.LockoutSeconds)) badPasswords[ip] = b = new BadPasswords { Since = now };
                if (++b.Count >= opt.MaxBadPasswords) b.LockedUntil = now.AddSeconds(opt.LockoutSeconds);
            }
        }

        /// <summary>The "denied" payload for a player who may not come in (the rules of the dedicated server, Server.cs: Admission), else null.
        /// An error while deciding refuses: Relay lets a player in when its Admit throws, which a join that cannot be read must not get.</summary>
        string Admit(Peer p, Msg m)
        {
            try { return AdmitCore(p, m); }
            catch (Exception e)
            {
                Log.Warn(p.Name + " (" + p.Address + ") refused: its join could not be read (" + e.Message + ")");
                return ProtocolDenied;
            }
        }

        static string ProtocolDenied => "{[\"reason\"]=\"relay\",[\"rp\"]=" + RelayProtocol.Number + "}";

        string AdmitCore(Peer p, Msg m)
        {
            var t = LuaLit.Parse(m.Payload ?? "") as Dictionary<object, object> ?? new Dictionary<object, object>();
            string S(string k) => t.TryGetValue(k, out var v) && v is string sv ? sv : "";
            string reason = null, extra = "";
            var me = BaseName(p.Name);
            var ip = AddressOf(p);
            int others = relay.Admitted().Count(o => o != p && !string.Equals(BaseName(o.Name), me, StringComparison.OrdinalIgnoreCase));
            // (the relay checks the protocol it speaks, not the MPFever version: the host checks the version between players, see RemoteRelay)
            if (!t.TryGetValue("rp", out var rpv) || !(rpv is double rp) || rp != RelayProtocol.Number)
            {
                Log.Warn(me + " (" + p.Address + ") refused: relay");
                return ProtocolDenied;
            }
            if (opt.Password != "" && LockedOut(ip)) reason = "password";   // (too many wrong ones from this address: even the right one waits)
            else if (opt.Password != "" && !SamePassword(S("pw"), opt.Password)) { reason = "password"; NoteBadPassword(ip); }
            else if (others >= opt.MaxPlayers) { reason = "full"; extra = ",[\"max\"]=" + opt.MaxPlayers; }
            else if (WantsHost(t) && HasHost && !IsAwaitedSuccessor(me, S("mtok"))) reason = "hosted";   // somebody hosts this server already: join it
            else if (!WantsHost(t) && !HasHost) reason = "nohost";    // nobody hosts it yet: somebody must host first
            if (reason == null)
            {
                lock (hostGate)
                {
                    if (WantsHost(t)) { hostJoins.Add(p); if (HasHost) presentedTokens[p] = S("mtok"); }
                    if (CanTakeOver(t)) capable.Add(p);
                    joinVersions[p] = S("v");
                }
            }
            else Log.Warn(BaseName(p.Name) + " (" + p.Address + ") refused: " + reason);
            return reason == null ? null : "{[\"reason\"]=" + LuaLit.Quote(reason) + extra + "}";
        }

        /// <summary>The password, compared in constant time.</summary>
        static bool SamePassword(string given, string expected)
            => CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(given ?? "")), SHA256.HashData(Encoding.UTF8.GetBytes(expected)));

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
            try { lock (checkpointGate) ReleaseCheckpoint(p); }
            catch (Exception e) when (e is System.IO.IOException || e is UnauthorizedAccessException) { Log.Warn("checkpoint cleanup: " + e.Message); }
            HostLeft(p);
        }

        void ToHost(Peer host, Msg m) { if (host != null) lock (sendGate) relay.Send(host, m); }

        /// <summary>Tells the host's launcher that a player came in.</summary>
        void AnnounceJoin(Peer host, Peer p)
        {
            string v; lock (hostGate) joinVersions.TryGetValue(p, out v);
            ToHost(host, Msg.Make("tun_join", p.Name, "{[\"name\"]=" + LuaLit.Quote(p.Name) + ",[\"addr\"]=" + LuaLit.Quote(p.Address ?? "") + ",[\"v\"]=" + LuaLit.Quote(v ?? "") + "}"));
        }

        // ---------------------------------------------------------------- messages

        void OnMessage(Msg m, Peer from)
        {
            // (a message that cannot be handled is dropped: it must not end the connection of the host, which would start a migration)
            try { Route(m, from); }
            catch (Exception e) { Log.Warn("a '" + m.Kind + "' from " + from.Name + " could not be handled: " + e.Message); }
        }

        void Route(Msg m, Peer from)
        {
            Peer host; bool fromHost;
            lock (hostGate) { host = this.host; fromHost = from == this.host; }

            if (fromHost) { FromHost(m, from); return; }

            // "tun_" is the server's own: a player cannot speak for it (it could make the host forget a player or believe in one that is not there)
            // (also the host's routing prefixes "@name:" and "!name:": a host passes on what it does not know, and the server would deliver
            // "@Victim#3:tun_host" as a "tun_host" to Victim)
            if (RelayProtocol.IsReserved(m.Kind) || RelayProtocol.IsRouting(m.Kind) || m.Kind == "host_ready")
            {
                if (Interlocked.Increment(ref DroppedControl) <= 3) Log.Warn(from.Name + " sent '" + m.Kind + "', which is the server's: dropped");
                return;
            }

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
            if (m.Kind == CheckpointWire.Request || m.Kind == CheckpointWire.Binary) { HandleCheckpoint(m, host); return; }
            if (m.Kind.StartsWith("tun_", StringComparison.Ordinal)) return;   // (the server's own kinds are not the host's to send)
            if (m.Kind.Length > 1 && m.Kind[0] == '@')
            {
                int i = m.Kind.IndexOf(':');
                if (i < 0) return;
                var target = relay.Find(m.Kind.Substring(1, i - 1));
                if (target == null || target == host) return;
                m.Kind = m.Kind.Substring(i + 1);
                if (RelayProtocol.IsReserved(m.Kind) || RelayProtocol.IsRouting(m.Kind)) return;   // (a reserved kind is never delivered to a player)
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
            if (RelayProtocol.IsReserved(m.Kind) || RelayProtocol.IsRouting(m.Kind)) return;
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
