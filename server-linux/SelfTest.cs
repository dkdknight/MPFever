using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace MPFever.LinuxServer
{
    /// <summary>mpfever-relay --selftest: real clients (the launcher's own Client class) against the server, no game. Exit code 0 when
    /// every check passes.</summary>
    static class SelfTest
    {
        static int failed, passed;

        sealed class Player : IDisposable
        {
            public readonly Client C = new Client();
            public readonly List<Msg> Got = new List<Msg>();
            public string DeniedReason;
            public volatile bool Closed;
            public Player(int port, string name, string pw = null, bool asHost = false)
            {
                C.Received += m => { lock (Got) Got.Add(m); };
                C.Denied += d => { DeniedReason = d.TryGetValue("reason", out var r) ? r as string : "?"; };
                C.Closed += () => Closed = true;
                C.Connect("127.0.0.1", port, name, pw, false, asHost);
            }
            public Msg[] Of(string kind) { lock (Got) return Got.Where(m => m.Kind == kind).ToArray(); }
            public bool Wait(Func<bool> cond, int ms = 4000)
            {
                var end = Environment.TickCount64 + ms;
                while (Environment.TickCount64 < end) { if (cond()) return true; Thread.Sleep(20); }
                return cond();
            }
            public string Me => Field(Of("tun_host").Length > 0 ? Of("tun_host")[0] : Of("welcome")[0], "you");
            public void Dispose() { try { C.Dispose(); } catch { } }
        }

        static void Check(string what, bool ok)
        {
            if (ok) { passed++; Console.WriteLine("  ok    " + what); }
            else { failed++; Console.WriteLine("  FAIL  " + what); }
        }

        static string Field(Msg m, string key)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            return t != null && t.TryGetValue(key, out var v) ? LuaLit.Show(v) : null;
        }

        static void Pause() => Thread.Sleep(300);

        public static int Run()
        {
            Tunnel();
            Remote();
            Migration();
            MigrationReconnect();
            Console.WriteLine();
            Console.WriteLine(failed == 0 ? "ALL " + passed + " CHECKS PASSED" : failed + " FAILED, " + passed + " passed");
            return failed == 0 ? 0 : 1;
        }

        static void Tunnel()
        {
            Console.WriteLine("admission");
            var opt = new ServerOptions { Password = "pw", MaxPlayers = 3 };
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, opt);
                relay.Start(0);
                int port = relay.Port;

                using (var bad = new Player(port, "Eve", "wrong"))
                {
                    Check("a wrong password is refused, with its reason", bad.Wait(() => bad.DeniedReason != null) && bad.DeniedReason == "password");
                    Check("and gets nothing else", bad.Of("welcome").Length == 0 && bad.Of("tun_host").Length == 0);
                }
                using (var none = new Player(port, "Old", null))
                    Check("no password is refused as well", none.Wait(() => none.DeniedReason != null) && none.DeniedReason == "password");

                using (var early = new Player(port, "Early", "pw"))
                    Check("a player is refused while nobody hosts", early.Wait(() => early.DeniedReason != null) && early.DeniedReason == "nohost");
                var h = new Player(port, "Hank", "pw", true);
                Check("the first player is told it is the host", h.Wait(() => h.Of("tun_host").Length == 1) && core.HostPlayer == h.Me);
                using (var h2 = new Player(port, "Hugo", "pw", true))
                    Check("a second host is refused", h2.Wait(() => h2.DeniedReason != null) && h2.DeniedReason == "hosted");
                var b = new Player(port, "Bob", "pw");
                var c = new Player(port, "Cat", "pw");
                try
                {
                    Check("the host is told of each player that comes in", h.Wait(() => h.Of("tun_join").Length == 2));
                    var bn = Field(h.Of("tun_join")[0], "name");
                    var cn = Field(h.Of("tun_join")[1], "name");
                    Check("with its name and address", bn.StartsWith("Bob#") && Field(h.Of("tun_join")[0], "addr") != "");
                    Check("a player gets nothing until the host speaks", b.Of("welcome").Length == 0 && b.Of("tun_join").Length == 0);

                    using (var d = new Player(port, "Dan", "pw"))
                        Check("a fourth player is refused when the server is full", d.Wait(() => d.DeniedReason != null) && d.DeniedReason == "full");

                    Console.WriteLine("messages to the host");
                    b.C.Send(Msg.Make("hello", "x", "{[\"role\"]=\"client\"}"));
                    Check("a player's message reaches the host", h.Wait(() => h.Of("hello").Length == 1));
                    Check("with the player's name as sender", h.Of("hello").Length > 0 && h.Of("hello")[0].From == bn);
                    Pause();
                    Check("and nobody else", c.Of("hello").Length == 0);
                    for (int i = 1; i <= 5; i++) c.C.Send(Msg.Make("act", "x", "{[\"i\"]=" + i + "}"));
                    Check("actions reach the host in order", h.Wait(() => h.Of("act").Length == 5) && h.Of("act").Select(m => Field(m, "i")).SequenceEqual(new[] { "1", "2", "3", "4", "5" }));
                    Pause();
                    Check("and are not sent to the other players by the server", b.Of("act").Length == 0);

                    Console.WriteLine("messages from the host");
                    h.C.Send(Msg.Make("@" + bn + ":welcome", "x", "{[\"you\"]=\"" + bn + "\",[\"role\"]=\"client\",[\"rtok\"]=\"\"}"));
                    Check("a message for one player reaches that player", b.Wait(() => b.Of("welcome").Length == 1));
                    Pause();
                    Check("and nobody else", c.Of("welcome").Length == 0);
                    Check("with the host's name as sender, without its #n", b.Of("welcome").Length > 0 && b.Of("welcome")[0].From == "Hank");
                    Check("a welcome carries the player's own link with the server", b.Of("welcome").Length > 0 && (Field(b.Of("welcome")[0], "rtok") ?? "").Length > 5);
                    h.C.Send(Msg.Make("session", "x", "{[\"started\"]=true,[\"speed\"]=1}"));
                    Check("a message to everybody reaches every player", b.Wait(() => b.Of("session").Length == 1) && c.Wait(() => c.Of("session").Length == 1));
                    Pause();
                    Check("but not the host itself", h.Of("session").Length == 0);
                    var data = Enumerable.Range(0, 5000).Select(i => (byte)(i * 7)).ToArray();
                    h.C.Send(Msg.MakeBinary("@" + cn + ":resync_bin", "x", "[\"id\"]=1,[\"i\"]=0,[\"n\"]=1", data, 0, data.Length));
                    Check("a binary message (a savegame part) goes through intact",
                        c.Wait(() => c.Of("resync_bin").Length == 1) && c.Of("resync_bin")[0].Data != null && c.Of("resync_bin")[0].Data.SequenceEqual(data));

                    Console.WriteLine("kick and leave");
                    h.C.Send(Msg.Make("tun_kick", "x", "{[\"name\"]=\"" + bn + "\",[\"payload\"]=\"{[\\\"reason\\\"]=\\\"kicked\\\"}\"}"));
                    Check("the host can refuse a player", b.Wait(() => b.DeniedReason == "kicked"));
                    c.C.Leave();
                    Check("the host is told when a player leaves", h.Wait(() => h.Of("tun_left").Any(m => Field(m, "name") == cn)));
                    var e = new Player(port, "Eli", "pw");
                    Check("a place freed by a player can be taken", h.Wait(() => h.Of("tun_join").Any(m => (Field(m, "name") ?? "").StartsWith("Eli#"))));
                    h.C.Leave();
                    Check("the session ends when the host leaves (no migration)", h.Wait(() => core.SessionEnded));
                    Check("and the players still there are disconnected", e.Wait(() => e.Closed));
                    e.Dispose();
                }
                finally { h.Dispose(); b.Dispose(); c.Dispose(); }
            }
        }


        /// <summary>The launcher's side: a RemoteRelay (what MainForm uses as its relay) against the server, with ordinary clients as the players.</summary>
        static void Remote()
        {
            Console.WriteLine("remote relay (the host's launcher side)");
            using (var srv = new Relay())
            {
                var core = new SessionCore(srv, new ServerOptions { Password = "pw" });
                srv.Start(0);
                int port = srv.Port;
                var host = new RemoteRelay();
                var joined = new List<Peer>(); var left = new List<Peer>(); var got = new List<KeyValuePair<Peer, Msg>>();
                host.Joined += p => { lock (joined) joined.Add(p); };
                host.Left += p => { lock (left) left.Add(p); };
                host.Received += (p, m) => { lock (got) got.Add(new KeyValuePair<Peer, Msg>(p, m)); };
                bool Wait(Func<bool> f, int ms = 4000) { var end = Environment.TickCount64 + ms; while (Environment.TickCount64 < end) { if (f()) return true; Thread.Sleep(20); } return f(); }
                try
                {
                    host.Connect("127.0.0.1", port, "Hank", "pw");
                    Check("the host connects and learns its name", host.Me != null && host.Me.StartsWith("Hank#"));
                    var b = new Player(port, "Bob", "pw");
                    var c = new Player(port, "Cat", "pw");
                    Check("players that come in raise Joined", Wait(() => { lock (joined) return joined.Count == 2; }));
                    Check("and are listed like a Relay lists them", host.AdmittedCount == 2 && host.PeerNames().Length == 2 && host.Find(joined[0].Name) == joined[0] && joined[0].Admitted);
                    b.C.Send(Msg.Make("hello", "x", "{}"));
                    Check("a player's message raises Received with that player", Wait(() => { lock (got) return got.Any(g => g.Value.Kind == "hello" && g.Key == joined[0]); }));
                    host.Send(joined[0], Msg.Make("welcome", "Hank", "{[\"you\"]=\"x\",[\"rtok\"]=\"\"}"));
                    Check("Send reaches that player only", b.Wait(() => b.Of("welcome").Length == 1));
                    Pause();
                    Check("and nobody else", c.Of("welcome").Length == 0);
                    host.Broadcast(Msg.Make("session", "Hank", "{[\"started\"]=true}"), joined[0]);
                    Check("Broadcast with an exception skips it", c.Wait(() => c.Of("session").Length == 1));
                    Pause();
                    Check("the excepted player gets nothing", b.Of("session").Length == 0);
                    host.Broadcast(Msg.Make("lobby", "Hank", "{}"));
                    Check("Broadcast reaches everybody", b.Wait(() => b.Of("lobby").Length == 1) && c.Wait(() => c.Of("lobby").Length == 1));
                    var data = Enumerable.Range(0, 3000).Select(i => (byte)(i * 3)).ToArray();
                    Check("TrySend of a binary message succeeds", host.TrySend(joined[1], Msg.MakeBinary("resync_bin", "Hank", "[\"id\"]=1,[\"i\"]=0,[\"n\"]=1", data, 0, data.Length)));
                    Check("and the savegame part arrives intact", c.Wait(() => c.Of("resync_bin").Length == 1) && c.Of("resync_bin")[0].Data.SequenceEqual(data));
                    Check("Kick finds a player by its name without #n", host.Kick("Bob", "{[\"reason\"]=\"kicked\"}") == 1 && b.Wait(() => b.DeniedReason == "kicked"));
                    Check("a player that is gone raises Left", Wait(() => { lock (left) return left.Any(p => p == joined[0]); }));
                    c.C.Leave();
                    Check("also when it leaves by itself", Wait(() => { lock (left) return left.Count == 2; }));
                    using (var second = new RemoteRelay())
                    {
                        bool refused = false;
                        try { second.Connect("127.0.0.1", port, "Hugo", "pw"); } catch (InvalidOperationException e) { refused = e.Message == "hosted"; }
                        Check("a second host is refused", refused);
                    }
                    var d = new Player(port, "Dan", "pw");
                    Wait(() => { lock (joined) return joined.Count == 3; });
                    host.Dispose();
                    Check("when the host goes, the players are disconnected", d.Wait(() => d.Closed) && core.SessionEnded);
                    d.Dispose(); b.Dispose(); c.Dispose();
                }
                finally { host.Dispose(); }
            }
        }

        /// <summary>The successor takes over by connecting again as the host (what the launcher does after reloading as the host).</summary>
        static void MigrationReconnect()
        {
            Console.WriteLine("the successor reconnects as the host");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new ServerOptions { MaxPlayers = 4, Migration = true, MigrationTimeoutSeconds = 30 });
                relay.Start(0);
                int port = relay.Port;
                var a = new Player(port, "Ann", null, true);
                a.Wait(() => a.Of("tun_host").Length == 1);
                var b = new Player(port, "Bob");
                var c = new Player(port, "Cat");
                a.Wait(() => a.Of("tun_join").Length >= 2);
                Player nb = null;
                try
                {
                    var cn = Field(a.Of("tun_join")[1], "name");
                    a.C.Leave();
                    Check("the next player is asked to take over", b.Wait(() => b.Of("tun_host").Length == 1));
                    using (var eve = new Player(port, "Eve", null, true))
                        Check("another player cannot take over", eve.Wait(() => eve.DeniedReason != null) && eve.DeniedReason == "hosted");
                    nb = new Player(port, "Bob", null, true);
                    Check("the successor, connecting again as the host, is accepted", nb.Wait(() => nb.Of("tun_host").Length == 1 && core.HostPlayer == nb.Me));
                    Check("the migration is over", !core.Migrating && !core.SessionEnded);
                    Check("the other players are announced to it", nb.Wait(() => nb.Of("tun_join").Any(m => Field(m, "name") == cn)));
                    Pause();
                    Check("but not the successor's own guest connection", nb.Of("tun_join").All(m => !(Field(m, "name") ?? "").StartsWith("Bob#")));
                    c.C.Send(Msg.Make("hello", "x", "{}"));
                    Check("messages go to the new host", nb.Wait(() => nb.Of("hello").Length == 1));
                    nb.C.Send(Msg.Make("session", "x", "{[\"started\"]=true}"));
                    Check("and its messages reach the players", c.Wait(() => c.Of("session").Length == 1));
                    Pause();
                    Check("the successor's old guest connection is closed without a new migration", core.HostPlayer == nb.Me && !core.Migrating);
                }
                finally { a.Dispose(); b.Dispose(); c.Dispose(); nb?.Dispose(); }
            }
        }

        static void Migration()
        {
            Console.WriteLine("host migration");
            var opt = new ServerOptions { MaxPlayers = 4, Migration = true, MigrationTimeoutSeconds = 2 };
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, opt);
                relay.Start(0);
                int port = relay.Port;
                var a = new Player(port, "Ann", null, true);
                a.Wait(() => a.Of("tun_host").Length == 1);
                var b = new Player(port, "Bob");
                var c = new Player(port, "Cat");
                b.Wait(() => a.Of("tun_join").Length >= 1);
                c.Wait(() => a.Of("tun_join").Length >= 2);
                try
                {
                    var bn = Field(a.Of("tun_join")[0], "name");
                    var cn = Field(a.Of("tun_join")[1], "name");
                    a.C.Leave();
                    Check("the next player is asked to take over", b.Wait(() => b.Of("tun_host").Length == 1 && Field(b.Of("tun_host")[0], "migrate") == "True"));
                    Check("with the epoch and the previous host", Field(b.Of("tun_host")[0], "prev").StartsWith("Ann#"));
                    Check("the session is not ended", !core.SessionEnded && core.Migrating);
                    var ep = int.Parse(Field(b.Of("tun_host")[0], "epoch"));
                    b.C.Send(Msg.Make("host_ready", "x", "{[\"epoch\"]=" + (ep + 5) + "}"));
                    Pause();
                    Check("a host_ready of another epoch is ignored", core.Migrating);
                    c.C.Send(Msg.Make("host_ready", "x", "{[\"epoch\"]=" + ep + "}"));
                    Pause();
                    Check("a host_ready from another player is ignored", core.Migrating);
                    b.C.Send(Msg.Make("host_ready", "x", "{[\"epoch\"]=" + ep + "}"));
                    Check("the new host's host_ready ends the migration", b.Wait(() => !core.Migrating && core.HostPlayer == bn));
                    Check("the others are announced to the new host", b.Wait(() => b.Of("tun_join").Any(m => Field(m, "name") == cn)));
                    c.C.Send(Msg.Make("hello", "x", "{}"));
                    Check("messages now go to the new host", b.Wait(() => b.Of("hello").Length == 1));
                    b.C.Send(Msg.Make("session", "x", "{[\"started\"]=true}"));
                    Check("and the new host's messages reach the players", c.Wait(() => c.Of("session").Length == 1));

                    Console.WriteLine("a successor that does not answer");
                    var d = new Player(port, "Dan");
                    b.Wait(() => b.Of("tun_join").Any(m => (Field(m, "name") ?? "").StartsWith("Dan#")));
                    b.C.Leave();
                    Check("the oldest remaining player is asked first", c.Wait(() => c.Of("tun_host").Length == 1));
                    Check("after the timeout the next one is asked", d.Wait(() => d.Of("tun_host").Length == 1, 8000));
                    var ep2 = int.Parse(Field(d.Of("tun_host")[0], "epoch"));
                    d.C.Send(Msg.Make("host_ready", "x", "{[\"epoch\"]=" + ep2 + "}"));
                    Check("it takes over", d.Wait(() => !core.Migrating && core.HostPlayer == d.Me));
                    d.C.Leave();
                    c.C.Leave();
                    Check("nobody left: no host", new Func<bool>(() => { for (int i = 0; i < 100 && core.HostPlayer != null; i++) Thread.Sleep(50); return core.HostPlayer == null; })());
                }
                finally { a.Dispose(); b.Dispose(); c.Dispose(); }
            }
        }
    }
}
