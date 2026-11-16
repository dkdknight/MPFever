using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace MPFever.LinuxServer
{
    /// <summary>
    /// Who plays the host (docs/LINUX-RELAY.md). The server has no game, so one connected player's launcher and game are the host: the
    /// reference for the world, the one that holds and sends the savegame, answers the mod and build checks and compares the games.
    /// The first player in is the host. When it leaves, either the session ends (the default) or, with ServerOptions.Migration, a player
    /// that said it can take over ("mig" in its join) is asked, the oldest first:
    ///
    ///   server -> successor   tun_host  { you, epoch, migrate = true, prev, token }   "take over": the token is random, made for this
    ///                                                                                attempt and this player, and used once
    ///   successor -> server   a new connection, join { host = true, mtok = token }    its game was reloaded as the host
    ///   server -> new host    tun_join for every other player, then tun_players { n }  (the end of the list: it may start)
    ///
    /// A successor that does not connect within MigrationTimeoutSeconds, or that leaves, is not asked again for this migration; the
    /// next one is. When nobody is left to ask, the session ends. Whether the new host has finished reloading and resynchronising the
    /// others is up to the launchers: the server only knows that the successor is connected as the host, and if that connection drops
    /// a new migration starts.
    /// </summary>
    sealed partial class SessionCore
    {
        enum Phase { Idle, AwaitingSuccessor }

        readonly object hostGate = new object();
        readonly List<Peer> order = new List<Peer>();             // connected players, oldest first
        readonly HashSet<Peer> hostJoins = new HashSet<Peer>();   // the connections that asked to host (join { host = true })
        readonly HashSet<Peer> capable = new HashSet<Peer>();     // the players that can take over (join { mig = true })
        readonly HashSet<Peer> failed = new HashSet<Peer>();      // asked during this migration and not there in time
        readonly Dictionary<Peer, string> presentedTokens = new Dictionary<Peer, string>();   // what a host join showed as its token
        readonly Dictionary<Peer, string> joinVersions = new Dictionary<Peer, string>();      // the MPFever version each player said (for the host)
        Peer host;                                                // the current host, or null (nobody, or a migration under way)
        Peer candidate;                                           // the player asked to take over
        Phase phase = Phase.Idle;
        string token;                                             // the successor's token (null outside a migration)
        int epoch;
        CancellationTokenSource attempt;                          // the wait for the successor, cancelled as soon as it is over

        public int Epoch { get { lock (hostGate) return epoch; } }
        public string HostPlayer { get { lock (hostGate) return (phase == Phase.AwaitingSuccessor ? candidate : host)?.Name; } }
        public bool Migrating { get { lock (hostGate) return phase == Phase.AwaitingSuccessor; } }
        public bool SessionEnded { get; private set; }
        /// <summary>Tests only: called by the timer of an attempt between its check and Migrate, where a takeover can slip in.</summary>
        internal Action TestHookBeforeMigrate;
        bool HasHost { get { lock (hostGate) return host != null || phase == Phase.AwaitingSuccessor; } }

        static bool WantsHost(Dictionary<object, object> join) => join.TryGetValue("host", out var h) && h is bool b && b;
        static bool CanTakeOver(Dictionary<object, object> join) => join.TryGetValue("mig", out var h) && h is bool b && b;

        /// <summary>This join is the successor's: a migration waits for a player of this name and the token is the one given to it.</summary>
        bool IsAwaitedSuccessor(string baseName, string presented)
        {
            lock (hostGate)
            {
                if (phase != Phase.AwaitingSuccessor || candidate == null || token == null || string.IsNullOrEmpty(presented)) return false;
                if (!string.Equals(BaseName(candidate.Name), baseName, StringComparison.OrdinalIgnoreCase)) return false;
                // (compared in constant time: the token is a secret)
                return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes(presented));
            }
        }

        static bool SameName(Peer a, Peer b) => string.Equals(BaseName(a.Name), BaseName(b.Name), StringComparison.OrdinalIgnoreCase);

        static string NewToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();

        bool IsHostJoin(Peer p) { lock (hostGate) return hostJoins.Contains(p); }

        void HostJoined(Peer p)
        {
            Peer h; bool first;
            // the successor, back as the host (its token proves it is the one that was asked)
            if (IsHostJoin(p) && TakeOver(p)) return;

            lock (hostGate)
            {
                order.Remove(p);
                order.Add(p);
                first = host == null && phase == Phase.Idle && IsHostJoin(p);
                if (first) { host = p; epoch++; }
                h = host;
            }
            if (first)
            {
                Log.Ok(p.Name + " is the host");
                ToHost(p, TunHost(p, false, ""));
            }
            else if (h != null && !SameName(p, h)) AnnounceJoin(h, p);
        }

        /// <summary>The awaited successor connected again as the host.</summary>
        bool TakeOver(Peer p)
        {
            Peer[] others;
            lock (hostGate)
            {
                if (!presentedTokens.TryGetValue(p, out var presented) || !IsAwaitedSuccessor(BaseName(p.Name), presented)) return false;
                host = p; candidate = null; phase = Phase.Idle; token = null; failed.Clear();
                attempt?.Cancel(); attempt = null;
                presentedTokens.Clear();
                others = order.Where(q => q != p && !SameName(q, p)).ToArray();
                order.Remove(p); order.Add(p);
            }
            Log.Ok(p.Name + " is the host now (reconnected)");
            ToHost(p, TunHost(p, true, ""));
            foreach (var q in others) AnnounceJoin(p, q);
            ToHost(p, Msg.Make("tun_players", HostName, "{[\"n\"]=" + others.Length + "}"));   // (the end of the list)
            return true;
        }

        void HostLeft(Peer p)
        {
            bool wasHost, wasCandidate; Peer h; int atEpoch;
            lock (hostGate)
            {
                atEpoch = epoch;
                order.Remove(p);
                hostJoins.Remove(p);
                capable.Remove(p);
                presentedTokens.Remove(p);
                joinVersions.Remove(p);
                wasHost = host == p;
                wasCandidate = phase == Phase.AwaitingSuccessor && candidate == p;
                if (wasHost) host = null;
                if (wasHost) failed.Clear();
                if (wasCandidate) failed.Add(p);
                h = host;
            }
            if (wasHost)
            {
                if (opt.Migration) Migrate(p.Name, atEpoch);
                else EndSession("The host " + p.Name + " left");
            }
            else if (wasCandidate) Migrate(p.Name, atEpoch);
            else if (h != null && !SameName(p, h)) ToHost(h, Msg.Make("tun_left", p.Name, "{[\"name\"]=" + LuaLit.Quote(p.Name) + "}"));
        }

        /// <summary>The host is gone and nobody takes over: every player is disconnected, as when a host of its own quits.</summary>
        void EndSession(string why)
        {
            Log.Warn(why + ": session ended");
            SessionEnded = true;
            lock (hostGate) { phase = Phase.Idle; candidate = null; token = null; failed.Clear(); presentedTokens.Clear(); attempt?.Cancel(); attempt = null; }
            foreach (var q in relay.Admitted()) { q.NoWait = true; NetAddr.Cut(q.Tcp); }
        }

        Msg TunHost(Peer p, bool migrate, string prev, string tok = null)
        {
            int ep; lock (hostGate) ep = epoch;
            return Msg.Make("tun_host", HostName, "{[\"you\"]=" + LuaLit.Quote(p.Name) + ",[\"epoch\"]=" + ep + ",[\"migrate\"]=" + (migrate ? "true" : "false")
                + ",[\"prev\"]=" + LuaLit.Quote(prev) + (tok != null ? ",[\"token\"]=" + LuaLit.Quote(tok) : "") + "}");
        }

        /// <summary>The host is gone (or the successor asked before did not come): ask the next player that can take over, once each.
        /// When none is left the session ends. fromEpoch is the epoch the caller saw when it decided: if the state has moved on since (a
        /// takeover, another call that already asked the next player) nothing is done, which makes the transition atomic: a late timer, or two
        /// events at once, cannot ask a second player while a host is there, nor end a healthy session.</summary>
        void Migrate(string prev, int fromEpoch)
        {
            Peer next; string tok = null; int ep = 0; CancellationTokenSource cts = null;
            lock (hostGate)
            {
                if (epoch != fromEpoch || host != null) return;
                attempt?.Cancel(); attempt = null;
                next = order.FirstOrDefault(q => q != host && capable.Contains(q) && !failed.Contains(q));
                if (next != null)
                {
                    phase = Phase.AwaitingSuccessor;
                    candidate = next;
                    token = tok = NewToken();
                    ep = ++epoch;
                    attempt = cts = new CancellationTokenSource();
                }
            }
            if (next == null) { EndSession("No player left to take over after " + prev); return; }
            Log.Warn("The host " + prev + " is gone: " + next.Name + " is asked to take over (epoch " + ep + ")");
            ToHost(next, TunHost(next, true, prev, tok));
            int seconds = opt.MigrationTimeoutSeconds;
            Task.Delay(TimeSpan.FromSeconds(seconds), cts.Token).ContinueWith(t =>
            {
                if (t.IsCanceled) return;
                bool stale;
                lock (hostGate)
                {
                    stale = phase != Phase.AwaitingSuccessor || candidate != next || epoch != ep;
                    if (!stale) failed.Add(next);
                }
                if (stale) return;
                Log.Warn(next.Name + " did not take over in " + seconds + " s");
                TestHookBeforeMigrate?.Invoke();
                Migrate(next.Name, ep);
            }, TaskScheduler.Default);
        }
    }
}
