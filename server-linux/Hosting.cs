using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace MPFever.LinuxServer
{
    /// <summary>
    /// Who plays the host (docs/LINUX-RELAY.md). The server has no game, so one connected player's launcher and game are the host: the
    /// reference for the world, the one that holds and sends the savegame, answers the mod and build checks and compares the games.
    /// The first player in is the host. When it leaves, either the session ends (as with a host of its own, the default) or, with
    /// ServerOptions.Migration, the next player in is asked to take over:
    ///
    ///   server -> new host   tun_host  { you, epoch, migrate = true, prev = "Name#n" }     "take over": its game is reloaded as the host
    ///   new host -> server   host_ready { epoch }                                          done: the others are announced to it (tun_join)
    /// </summary>
    sealed partial class SessionCore
    {
        readonly object hostGate = new object();
        readonly List<Peer> order = new List<Peer>();   // connected players, oldest first
        Peer host;                                       // the current host, or null (nobody, or a migration under way)
        Peer candidate;                                  // the player asked to take over
        int epoch;
        bool migrating;
        long migrationId;                                // identifies the running migration for its timeout
        readonly HashSet<Peer> hostJoins = new HashSet<Peer>();   // the connections that asked to host (join { host = true })

        public int Epoch { get { lock (hostGate) return epoch; } }
        public string HostPlayer { get { lock (hostGate) return (migrating ? candidate : host)?.Name; } }
        public bool Migrating { get { lock (hostGate) return migrating; } }
        public bool SessionEnded { get; private set; }
        bool HasHost { get { lock (hostGate) return host != null || migrating; } }

        bool IsHostJoin(Peer p) { lock (hostGate) return hostJoins.Contains(p); }

        /// <summary>A migration is waiting for this player (by name, without its #n): it may connect again as the host.</summary>
        bool IsAwaitedSuccessor(string baseName)
        {
            lock (hostGate) return migrating && candidate != null && string.Equals(BaseName(candidate.Name), baseName, StringComparison.OrdinalIgnoreCase);
        }

        void HostJoined(Peer p)
        {
            Peer h; bool first;
            // the awaited successor, back as the host (a second connection of the same name while its guest connection is still there)
            if (IsHostJoin(p) && IsAwaitedSuccessor(BaseName(p.Name)))
            {
                Peer[] others;
                lock (hostGate)
                {
                    host = p; candidate = null; migrating = false; migrationId++;
                    others = order.Where(q => q != p && !SameName(q, p)).ToArray();
                    order.Remove(p); order.Add(p);
                }
                Log.Ok(p.Name + " is the host now (reconnected)");
                ToHost(p, TunHost(p, true, ""));
                foreach (var q in others) AnnounceJoin(p, q);
                return;
            }

            lock (hostGate)
            {
                order.Remove(p);
                order.Add(p);
                first = host == null && !migrating && IsHostJoin(p);
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

        void HostLeft(Peer p)
        {
            bool wasHost, wasCandidate; Peer h;
            lock (hostGate)
            {
                order.Remove(p);
                hostJoins.Remove(p);
                wasHost = host == p;
                wasCandidate = migrating && candidate == p;
                if (wasHost) host = null;
                h = host;
            }
            if (wasHost)
            {
                if (opt.Migration) Migrate(p.Name, "left");
                else EndSession(p.Name);
            }
            else if (wasCandidate) Migrate(p.Name, "left");
            else if (h != null && !SameName(p, h)) ToHost(h, Msg.Make("tun_left", p.Name, "{[\"name\"]=" + LuaLit.Quote(p.Name) + "}"));
        }

        static bool SameName(Peer a, Peer b) => string.Equals(BaseName(a.Name), BaseName(b.Name), StringComparison.OrdinalIgnoreCase);

        /// <summary>The host is gone and nobody takes over: every player is disconnected, as when a host of its own quits.</summary>
        void EndSession(string prev)
        {
            Log.Warn("The host " + prev + " left: session ended");
            SessionEnded = true;
            lock (hostGate) { migrating = false; candidate = null; }
            foreach (var q in relay.Admitted()) { q.NoWait = true; NetAddr.Cut(q.Tcp); }
        }

        Msg TunHost(Peer p, bool migrate, string prev)
        {
            int ep; lock (hostGate) ep = epoch;
            return Msg.Make("tun_host", HostName, "{[\"you\"]=" + LuaLit.Quote(p.Name) + ",[\"epoch\"]=" + ep + ",[\"migrate\"]=" + (migrate ? "true" : "false")
                + ",[\"prev\"]=" + LuaLit.Quote(prev) + "}");
        }

        /// <summary>The host is gone (or its successor did not answer): ask the next player to take over.</summary>
        void Migrate(string prev, string why)
        {
            Peer next; long id;
            lock (hostGate)
            {
                if (why == "timeout" && candidate != null && order.Remove(candidate)) order.Add(candidate);   // it goes last
                next = order.FirstOrDefault();
                if (next == null) { migrating = false; candidate = null; host = null; return; }
                migrating = true;
                candidate = next;
                epoch++;
                id = ++migrationId;
            }
            Log.Warn("The host " + prev + " is gone (" + why + "): " + next.Name + " is asked to take over");
            ToHost(next, TunHost(next, true, prev));
            int seconds = opt.MigrationTimeoutSeconds;
            new Thread(() =>
            {
                Thread.Sleep(TimeSpan.FromSeconds(seconds));
                bool stale;
                lock (hostGate) stale = !migrating || migrationId != id;
                if (stale) return;
                Log.Warn(next.Name + " did not answer in " + seconds + " s");
                Migrate(next.Name, "timeout");
            }) { IsBackground = true, Name = "migration timeout" }.Start();
        }

        /// <summary>The successor's game was reloaded as the host: the other players are announced to it.</summary>
        void OnHostReady(Msg m, Peer from)
        {
            Peer[] others;
            lock (hostGate)
            {
                int ep = LuaLit.Parse(m.Payload) is Dictionary<object, object> t && t.TryGetValue("epoch", out var ev) && ev is double ed ? (int)ed : -1;
                if (!migrating || from != candidate || ep != epoch) { Log.Dim(from.Name + ": host_ready ignored (not the awaited one)"); return; }
                host = candidate; candidate = null; migrating = false;
                migrationId++;
                others = order.Where(q => q != host).ToArray();
            }
            Log.Ok(from.Name + " is the host now");
            foreach (var q in others) AnnounceJoin(from, q);
        }
    }
}
