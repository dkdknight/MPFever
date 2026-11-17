using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;

namespace MPFever.StandaloneRelay
{
    /// <summary>mpfever-relay --selftest: real clients (the launcher's own Client class) against the relay, no game. Exit code 0 when
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
            public Player(int port, string name, string pw = null, bool asHost = false, bool canTakeOver = false, string token = null)
            {
                C.Received += m => { lock (Got) Got.Add(m); };
                C.Denied += d => { DeniedReason = d.TryGetValue("reason", out var r) ? r as string : "?"; };
                C.Closed += () => Closed = true;
                C.Connect("127.0.0.1", port, name, pw, false, asHost, canTakeOver, token);
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
            Parser();
            Environment_();
            Compat();
            CheckpointPersistence();
            CheckpointOverTheRelay();
            VersionBetweenPlayers();
            Hardening();
            Races();
            Load();
            Robustness();
            Console.WriteLine();
            Console.WriteLine(failed == 0 ? "ALL " + passed + " CHECKS PASSED" : failed + " FAILED, " + passed + " passed");
            return failed == 0 ? 0 : 1;
        }

        /// <summary>The secrets may come from the environment (containers), and the command line wins.</summary>
        static void Environment_()
        {
            var env = new System.Collections.Generic.Dictionary<string, string>
            {
                ["MPFEVER_RELAY_PASSWORD"] = "from-env", ["MPFEVER_RELAY_CHECKPOINT_OWNER_KEY"] = "owner-env", ["MPFEVER_RELAY_RESUME_WITHOUT_HOST"] = "resume-env"
            };
            Func<string, string> get = k => env.TryGetValue(k, out var v) ? v : null;
            var o = new RelayOptions();
            Program.ApplyEnvironment(o, get);
            Check("the password, the owner key and the recovery key can come from the environment",
                o.Password == "from-env" && o.CheckpointOwnerKey == "owner-env" && o.CheckpointRecoveryKey == "resume-env" && o.ResumeWithoutHost);
            var none = new RelayOptions();
            Program.ApplyEnvironment(none, k => null);
            Check("without them the settings are as before (no password, no recovery)",
                none.Password == "" && none.CheckpointOwnerKey == "" && none.CheckpointRecoveryKey == "" && !none.ResumeWithoutHost);
            var empty = new RelayOptions { Password = "kept" };
            Program.ApplyEnvironment(empty, k => "");
            Check("an empty variable changes nothing", empty.Password == "kept" && !empty.ResumeWithoutHost);
        }

        static void CheckpointPersistence()
        {
            Console.WriteLine("persistent checkpoint storage");
            string dir = Path.Combine(Path.GetTempPath(), "mpfever-checkpoint-" + Guid.NewGuid().ToString("N"));
            var first = new byte[RelayCheckpoint.ChunkSize + 23];
            var next = new byte[80];
            var random = new Random(334);
            random.NextBytes(first);
            random.NextBytes(next);
            byte[] firstHash = SHA256.HashData(first), nextHash = SHA256.HashData(next);

            bool Matches(RelayCheckpoint store, byte[] expected, byte[] digest)
            {
                using var file = store.Open(out var size, out var sha);
                if (file == null || size != expected.Length || !string.Equals(sha, Convert.ToHexString(digest), StringComparison.OrdinalIgnoreCase))
                    return false;
                var actual = new byte[expected.Length];
                file.ReadExactly(actual);
                return actual.SequenceEqual(expected);
            }

            try
            {
                using (var store = new RelayCheckpoint(dir))
                {
                    using (var missing = store.Open(out var size, out _))
                        Check("a new store does not report a save", missing == null && size == 0);
                    store.Begin(first.Length, firstHash);
                    Check("a chunk larger than the transfer limit is refused", !store.Append(first));
                    Check("a complete save can be committed from multiple chunks",
                        store.Append(first.Take(RelayCheckpoint.ChunkSize).ToArray()) &&
                        store.Append(first.Skip(RelayCheckpoint.ChunkSize).ToArray()) && store.Complete());

                    bool locked = false;
                    try { using var duplicate = new RelayCheckpoint(dir); }
                    catch (IOException) { locked = true; }
                    Check("two relays cannot write the same checkpoint directory", locked);

                    store.Begin(next.Length, nextHash);
                    store.Append(next.Take(8).ToArray());
                    Check("an in-flight upload leaves the previous save readable", Matches(store, first, firstHash));
                    Check("an incomplete upload cannot replace the previous save", !store.Complete() && Matches(store, first, firstHash));

                    store.Begin(next.Length, firstHash);
                    store.Append(next);
                    Check("a checksum mismatch cannot replace the previous save", !store.Complete() && Matches(store, first, firstHash));
                    store.Begin(next.Length, nextHash);
                    store.Append(next.Take(8).ToArray());
                }

                // A forced process exit can leave an unfinished file in the directory.
                var partial = Path.Combine(dir, "checkpoint.partial");
                File.WriteAllBytes(partial, next);
                using (var store = new RelayCheckpoint(dir))
                {
                    Check("restart ignores an abandoned temporary file", !File.Exists(partial) && Matches(store, first, firstHash));
                    store.Begin(next.Length, nextHash);
                    Check("a later verified upload replaces the previous save",
                        store.Append(next) && store.Complete() && Matches(store, next, nextHash));
                }
            }
            finally
            {
                if (Directory.Exists(dir))
                {
                    foreach (var name in new[] { "checkpoint.partial", "checkpoint.bin", "checkpoint.lock" })
                        File.Delete(Path.Combine(dir, name));
                    Directory.Delete(dir);
                }
            }
        }

        static void CheckpointOverTheRelay()
        {
            Console.WriteLine("the save kept by the relay, through the protocol");
            string dir = Path.Combine(Path.GetTempPath(), "mpfever-checkpoint-" + Guid.NewGuid().ToString("N"));
            var save = new byte[RelayCheckpoint.ChunkSize + 500];
            new Random(7).NextBytes(save);
            string sha = Convert.ToHexString(SHA256.HashData(save)).ToLowerInvariant();
            try
            {
                var opt = new RelayOptions { CheckpointDirectory = dir, CheckpointOwnerKey = "own", CheckpointRecoveryKey = "rec", ResumeWithoutHost = true };
                using (var srv = new Relay())
                {
                    var core = new SessionCore(srv, opt);
                    srv.Start(0);
                    int port = srv.Port;
                    int n = 0;
                    string Id() => (++n).ToString("x32");
                    Msg Reply(Player pl, string id) { Msg r = null; pl.Wait(() => (r = pl.Of(CheckpointWire.Reply).FirstOrDefault(m => Field(m, "id") == id)) != null); return r; }
                    string Ask(Player pl, string body)
                    {
                        string id = Id();
                        pl.C.Send(Msg.Make(CheckpointWire.Request, "Host", "{" + CheckpointWire.Field("id", id) + "," + body + "}"));
                        var r = Reply(pl, id);
                        return r == null ? "(no answer)" : Field(r, "status");
                    }
                    using (var host = new Player(port, "Host", null, true))
                    {
                        host.Wait(() => host.Of("tun_host").Length > 0);
                        Check("a host with the wrong key cannot store a save",
                            Ask(host, CheckpointWire.Field("op", "begin") + "," + CheckpointWire.Field("key", "nope") + "," + CheckpointWire.Field("size", save.Length) + "," + CheckpointWire.Field("sha", sha)) == "denied");
                        Check("the owner starts an upload",
                            Ask(host, CheckpointWire.Field("op", "begin") + "," + CheckpointWire.Field("key", "own") + "," + CheckpointWire.Field("size", save.Length) + "," + CheckpointWire.Field("sha", sha)) == "upload");
                        bool parts = true;
                        for (int off = 0; off < save.Length; off += RelayCheckpoint.ChunkSize)
                        {
                            var chunk = save.Skip(off).Take(RelayCheckpoint.ChunkSize).ToArray();
                            string id = Id();
                            host.C.Send(new Msg { Kind = CheckpointWire.Binary, From = "Host", Data = chunk, Payload = "{" + CheckpointWire.Field("id", id) + "," + CheckpointWire.Field("len", chunk.Length) + "}" });
                            var r = Reply(host, id);
                            parts &= r != null && Field(r, "status") == "part";
                        }
                        Check("every chunk is accepted", parts);
                        Check("the complete, verified save is stored", Ask(host, CheckpointWire.Field("op", "commit")) == "saved");
                    }
                    Thread.Sleep(300);
                    using (var next = new Player(port, "Next", null, true))
                    {
                        next.Wait(() => next.Of("tun_host").Length > 0);
                        Check("the owner's password alone does not read the save: a wrong key is denied", Ask(next, CheckpointWire.Field("op", "open") + "," + CheckpointWire.Field("key", "bad")) == "denied");
                        string id = Id();
                        next.C.Send(Msg.Make(CheckpointWire.Request, "Next", "{" + CheckpointWire.Field("id", id) + "," + CheckpointWire.Field("op", "open") + "," + CheckpointWire.Field("key", "rec") + "}"));
                        var open = Reply(next, id);
                        Check("the recovery key opens the save, with its size and hash", open != null && Field(open, "status") == "download"
                            && Field(open, "size") == save.Length.ToString() && Field(open, "sha") == sha);
                        var got = new List<byte>();
                        while (got.Count < save.Length)
                        {
                            string rid = Id();
                            next.C.Send(Msg.Make(CheckpointWire.Request, "Next", "{" + CheckpointWire.Field("id", rid) + "," + CheckpointWire.Field("op", "read") + "," + CheckpointWire.Field("offset", got.Count) + "}"));
                            Msg bin = null;
                            next.Wait(() => (bin = next.Of(CheckpointWire.Binary).FirstOrDefault(m => Field(m, "id") == rid)) != null);
                            if (bin == null || bin.Data == null) break;
                            got.AddRange(bin.Data);
                        }
                        Check("the save comes back byte for byte", got.Count == save.Length && got.SequenceEqual(save));
                        Check("the new host confirms it loaded it", Ask(next, CheckpointWire.Field("op", "loaded")) == "ready");
                    }
                }
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
            CheckpointThroughRemoteRelay();
            // a relay started without --checkpoint-dir says it keeps nothing (the launcher does not wait for an answer that never comes)
            using (var srv = new Relay())
            {
                var core = new SessionCore(srv, new RelayOptions());
                srv.Start(0);
                using (var a = new RemoteRelay())
                {
                    a.Connect("127.0.0.1", srv.Port, "Alice", null);
                    var t0 = Environment.TickCount64;
                    string status = a.UploadCheckpoint("anything", new byte[] { 1, 2, 3 });
                    Check("a relay without --checkpoint-dir answers that it keeps no save, at once", status == "empty" && Environment.TickCount64 - t0 < 5000);
                }
            }
        }

        /// <summary>The launcher's own side (RemoteRelay.UploadCheckpoint / DownloadCheckpoint) against the relay, with a 2.5 MB save.</summary>
        static void CheckpointThroughRemoteRelay()
        {
            Console.WriteLine("the launcher's side of the kept save");
            string dir = Path.Combine(Path.GetTempPath(), "mpfever-checkpoint-" + Guid.NewGuid().ToString("N"));
            var save = new byte[2 * RelayCheckpoint.ChunkSize + 4321];
            new Random(11).NextBytes(save);
            try
            {
                var opt = new RelayOptions { CheckpointDirectory = dir, CheckpointOwnerKey = "own", CheckpointRecoveryKey = "rec", ResumeWithoutHost = true };
                using (var srv = new Relay())
                {
                    var core = new SessionCore(srv, opt);
                    srv.Start(0);
                    using (var a = new RemoteRelay())
                    {
                        a.Connect("127.0.0.1", srv.Port, "Alice", null);
                        Check("a host with a wrong key cannot keep a save", a.UploadCheckpoint("nope", save) == "denied");
                        Check("a host with the owner key keeps a 2.5 MB save", a.UploadCheckpoint("own", save) == "saved");
                    }
                    Thread.Sleep(300);
                    using (var b = new RemoteRelay())
                    {
                        b.Connect("127.0.0.1", srv.Port, "Bella", null);
                        var none = b.DownloadCheckpoint("nope", out var status);
                        Check("a wrong key reads nothing", none == null && status == "denied");
                        var got = b.DownloadCheckpoint("rec", out status);
                        Check("the recovery key reads the save back, hash checked", got != null && got.SequenceEqual(save) && status == "ready");
                        Check("and may keep the save it goes on with", b.UploadCheckpoint("rec", new byte[] { 1, 2, 3, 4 }) == "saved");
                    }
                }
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void Tunnel()
        {
            Console.WriteLine("admission");
            var opt = new RelayOptions { Password = "pw", MaxPlayers = 3 };
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
                        Check("a fourth player is refused when the relay is full", d.Wait(() => d.DeniedReason != null) && d.DeniedReason == "full");

                    Console.WriteLine("messages to the host");
                    b.C.Send(Msg.Make("hello", "x", "{[\"role\"]=\"client\"}"));
                    Check("a player's message reaches the host", h.Wait(() => h.Of("hello").Length == 1));
                    Check("with the player's name as sender", h.Of("hello").Length > 0 && h.Of("hello")[0].From == bn);
                    Pause();
                    Check("and nobody else", c.Of("hello").Length == 0);
                    for (int i = 1; i <= 5; i++) c.C.Send(Msg.Make("act", "x", "{[\"i\"]=" + i + "}"));
                    Check("actions reach the host in order", h.Wait(() => h.Of("act").Length == 5) && h.Of("act").Select(m => Field(m, "i")).SequenceEqual(new[] { "1", "2", "3", "4", "5" }));
                    Pause();
                    Check("and are not sent to the other players by the relay", b.Of("act").Length == 0);

                    Console.WriteLine("messages from the host");
                    h.C.Send(Msg.Make("@" + bn + ":welcome", "x", "{[\"you\"]=\"" + bn + "\",[\"role\"]=\"client\",[\"rtok\"]=\"\"}"));
                    Check("a message for one player reaches that player", b.Wait(() => b.Of("welcome").Length == 1));
                    Pause();
                    Check("and nobody else", c.Of("welcome").Length == 0);
                    Check("with the host's name as sender, without its #n", b.Of("welcome").Length > 0 && b.Of("welcome")[0].From == "Hank");
                    Check("a welcome carries the player's own link with the relay", b.Of("welcome").Length > 0 && (Field(b.Of("welcome")[0], "rtok") ?? "").Length > 5);
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


        /// <summary>The launcher's side: a RemoteRelay (what MainForm uses as its relay) against the relay, with ordinary clients as the players.</summary>
        static void Remote()
        {
            Console.WriteLine("remote relay (the host's launcher side)");
            using (var srv = new Relay())
            {
                var core = new SessionCore(srv, new RelayOptions { Password = "pw" });
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

        // ---------------------------------------------------------------- hardening (review of the pull request)

        /// <summary>A raw TCP connection that says what it likes (a client that is not an MPFever).</summary>
        sealed class Raw : IDisposable
        {
            public readonly System.Net.Sockets.TcpClient T = new System.Net.Sockets.TcpClient();
            public Raw(int port) { T.Connect("127.0.0.1", port); T.NoDelay = true; }
            public void Send(byte[] b) { T.GetStream().Write(b, 0, b.Length); }
            public void Send(string s) { Send(System.Text.Encoding.UTF8.GetBytes(s)); }
            /// <summary>True when the relay closed the connection (within ms).</summary>
            public bool ClosedBy(int ms)
            {
                var end = Environment.TickCount64 + ms;
                while (Environment.TickCount64 < end)
                {
                    try
                    {
                        if (T.Client.Poll(50 * 1000, System.Net.Sockets.SelectMode.SelectRead) && T.Client.Available == 0) return true;
                        Send("A");   // (a closed connection fails on the second write at the latest)
                    }
                    catch (Exception) { return true; }
                }
                return false;
            }
            public void Dispose() { try { T.Close(); } catch { } }
        }

        /// <summary>The relay no longer compares MPFever versions: the host's own admission does (RemoteRelay.Admit), as for a host that listens itself.</summary>
        static void VersionBetweenPlayers()
        {
            Console.WriteLine("the version rule between players stays with the host");
            using (var srv = new Relay())
            {
                var core = new SessionCore(srv, new RelayOptions());
                srv.Start(0);
                int port = srv.Port;
                var host = new RemoteRelay();
                var joined = new List<Peer>();
                var seen = new List<string>();
                host.Joined += p => { lock (joined) joined.Add(p); };
                // the host's rule of the launcher: only players of its own version (MainForm.VersionAdmit), here "9.9.9"
                host.Admit = (p, m) =>
                {
                    var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                    var v = t != null && t.TryGetValue("v", out var vo) ? vo as string : "";
                    lock (seen) seen.Add(v);
                    return v == "9.9.9" ? null : "{[\"reason\"]=\"version\",[\"v\"]=\"9.9.9\"}";
                };
                try
                {
                    host.Connect("127.0.0.1", port, "Hank", null);
                    using (var good = new Raw(port))
                    {
                        good.Send("join\tGood\t{[\"v\"]=\"9.9.9\",[\"rp\"]=" + RelayProtocol.Number + "}\n");
                        var t0 = Environment.TickCount64; while (Environment.TickCount64 - t0 < 4000) { lock (joined) if (joined.Count == 1) break; Thread.Sleep(20); }
                        Check("a player of the host's version reaches Joined", new Func<bool>(() => { lock (joined) return joined.Count == 1 && joined[0].Name.StartsWith("Good#"); })());
                        Check("the host was given the version the player said", new Func<bool>(() => { lock (seen) return seen.Contains("9.9.9"); })());
                    }
                    var other = new Player(port, "Other");   // (its Client says MainForm.Version, which is not "9.9.9")
                    try
                    {
                        Check("a player of another MPFever version is refused by the host, with the host's own reason", other.Wait(() => other.DeniedReason != null) && other.DeniedReason == "version");
                        Thread.Sleep(300);
                        Check("and never reaches Joined", new Func<bool>(() => { lock (joined) return joined.All(p => !p.Name.StartsWith("Other#")); })());
                    }
                    finally { other.Dispose(); }
                }
                finally { host.Dispose(); }
            }
        }

        static void Hardening()
        {
            Console.WriteLine("hardening: messages a player must not be able to send");
            using (var srv = new Relay())
            {
                var core = new SessionCore(srv, new RelayOptions());
                srv.Start(0);
                int port = srv.Port;
                var host = new RemoteRelay();
                var gone = new List<Peer>(); var got = new List<Peer>();
                host.Left += p => { lock (gone) gone.Add(p); };
                host.Joined += p => { lock (got) got.Add(p); };
                try
                {
                    host.Connect("127.0.0.1", port, "Hank", null);
                    using (var b = new Player(port, "Bob"))
                    using (var c = new Player(port, "Cat"))
                    {
                        var t0 = Environment.TickCount64; while (host.AdmittedCount < 2 && Environment.TickCount64 - t0 < 4000) Thread.Sleep(20);
                        var names = host.PeerNames();
                        var cat = names.First(n => n.StartsWith("Cat#"));
                        b.C.Send(Msg.Make("tun_left", "x", "{[\"name\"]=\"" + cat + "\"}"));
                        b.C.Send(Msg.Make("tun_join", "x", "{[\"name\"]=\"Ghost#99\",[\"addr\"]=\"\"}"));
                        b.C.Send(Msg.Make("tun_host", "x", "{[\"you\"]=\"Bob#1\",[\"epoch\"]=9}"));
                        Pause(); Pause();
                        Check("a player cannot make the host forget another player (tun_left)", host.Find(cat) != null);
                        Check("a player cannot make the host believe in a player that is not there (tun_join)", host.Find("Ghost#99") == null);
                        Check("a player's control messages are dropped by the relay, not passed on", core.DroppedControl >= 3);
                        // (through a host that passes on what it does not know, "@Victim:tun_host" would reach Victim as a "tun_host")
                        int before = core.DroppedControl;
                        b.C.Send(Msg.Make("@" + cat + ":tun_host", "x", "{[\"you\"]=\"Cat#1\",[\"migrate\"]=true,[\"token\"]=\"x\"}"));
                        b.C.Send(Msg.Make("!" + cat + ":tun_host", "x", "{[\"migrate\"]=true}"));
                        Pause(); Pause();
                        Check("a player's routing prefixes are dropped by the relay, not passed on", core.DroppedControl >= before + 2 && !host.Find(cat).Equals(null));
                        Check("so no player receives a tun_host from another player", c.Of("tun_host").Length == 0 && b.Of("tun_host").Length == 0);
                        // (and a host's message that would deliver a reserved kind is not delivered either)
                        host.Broadcast(Msg.Make("@" + cat + ":tun_host", "Hank", "{[\"migrate\"]=true,[\"token\"]=\"x\"}"));
                        host.Broadcast(Msg.Make("!" + cat + ":tun_host", "Hank", "{[\"migrate\"]=true}"));
                        Pause(); Pause();
                        Check("a host's reserved kind behind a routing prefix is not delivered to a player", c.Of("tun_host").Length == 0 && b.Of("tun_host").Length == 0);
                    }
                }
                finally { host.Dispose(); }
            }

            Console.WriteLine("hardening: the successor is the one the relay asked");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 4, Migration = true, MigrationTimeoutSeconds = 30 });
                relay.Start(0);
                int port = relay.Port;
                var a = new Player(port, "Ann", null, true);
                a.Wait(() => a.Of("tun_host").Length == 1);
                var b = new Player(port, "Bob", null, false, true);
                var c = new Player(port, "Cat", null, false, true);
                a.Wait(() => a.Of("tun_join").Length >= 2);
                Player evil = null, real = null;
                try
                {
                    a.C.Leave();
                    Check("the successor is asked", b.Wait(() => b.Of("tun_host").Length == 1));
                    // another player of the relay, with the successor's name, connects as the host without having been asked
                    evil = new Player(port, "Bob", null, true);
                    Check("a connection that only has the successor's name is refused", evil.Wait(() => evil.DeniedReason != null || evil.Of("tun_host").Length > 0) && evil.DeniedReason == "hosted");
                    Check("and the relay still waits for the successor", core.Migrating && core.HostPlayer != null && core.HostPlayer.StartsWith("Bob#"));
                    var token = Field(b.Of("tun_host")[0], "token");
                    Check("the successor's request carries a token", !string.IsNullOrEmpty(token) && token.Length >= 16);
                    real = new Player(port, "Bob", null, true, false, token);
                    Check("the successor, with its token, takes over", real.Wait(() => real.Of("tun_host").Length == 1 && !core.Migrating));
                    using (var again = new Player(port, "Bob", null, true, false, token))
                        Check("a token cannot be used twice", again.Wait(() => again.DeniedReason != null) && again.DeniedReason == "hosted");
                }
                finally { a.Dispose(); b.Dispose(); c.Dispose(); evil?.Dispose(); real?.Dispose(); }
            }

            Console.WriteLine("hardening: a migration does not go on for ever");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 4, Migration = true, MigrationTimeoutSeconds = 1 });
                relay.Start(0);
                int port = relay.Port;
                var a = new Player(port, "Ann", null, true);
                a.Wait(() => a.Of("tun_host").Length == 1);
                var b = new Player(port, "Bob", null, false, true);   // (able to take over, but silent)
                var c = new Player(port, "Cat", null, false, true);
                var o = new Player(port, "Old");                        // (an MPFever that cannot take over: never asked)
                a.Wait(() => a.Of("tun_join").Length >= 3);
                try
                {
                    a.C.Leave();
                    Check("each able player is asked once", b.Wait(() => b.Of("tun_host").Length == 1) && c.Wait(() => c.Of("tun_host").Length == 1, 5000));
                    Check("when nobody answers the session ends", new Func<bool>(() => { for (int i = 0; i < 120 && !core.SessionEnded; i++) Thread.Sleep(50); return core.SessionEnded; })());
                    Thread.Sleep(1500);
                    Check("nobody is asked a second time", b.Of("tun_host").Length == 1 && c.Of("tun_host").Length == 1);
                    Check("a player that cannot take over is never asked", o.Of("tun_host").Length == 0);
                }
                finally { a.Dispose(); b.Dispose(); c.Dispose(); o.Dispose(); }
            }

            Console.WriteLine("hardening: a connection that is not let in");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { UnadmittedTimeoutSeconds = 2, MaxConnections = 4 });
                relay.Start(0);
                int port = relay.Port;
                using (var r1 = new Raw(port))
                {
                    r1.Send(new string('A', 200 * 1024));
                    Check("a line that never ends closes the connection", r1.ClosedBy(3000));
                }
                using (var r2 = new Raw(port))
                {
                    r2.Send("x_bin\t-\t{[\"len\"]=60000000}\n");
                    Check("a binary message before the player is let in closes the connection", r2.ClosedBy(3000));
                }
                using (var r3 = new Raw(port))
                    Check("a connection that says nothing is closed after a few seconds", r3.ClosedBy(6000));
                var raws = new List<Raw>();
                try
                {
                    for (int i = 0; i < 4; i++) raws.Add(new Raw(port));
                    Thread.Sleep(300);
                    bool extra;
                    using (var r5 = new Raw(port)) extra = r5.ClosedBy(1500);
                    Check("connections beyond the limit are refused", extra);
                }
                finally { foreach (var r in raws) r.Dispose(); }
                Check("the relay still works after all that", new Func<bool>(() => { using (var h = new Player(port, "Hank", null, true)) return h.Wait(() => h.Of("tun_host").Length == 1); })());
            }

            Console.WriteLine("hardening: wrong passwords");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { Password = "right", MaxPlayers = 4 });
                relay.Start(0);
                int port = relay.Port;
                for (int i = 0; i < 6; i++) using (var bad = new Player(port, "Eve" + i, "wrong")) bad.Wait(() => bad.DeniedReason != null);
                using (var good = new Player(port, "Hank", "right", true))
                    Check("after repeated wrong passwords the same address is refused for a while, even with the right one", good.Wait(() => good.DeniedReason != null || good.Of("tun_host").Length > 0) && good.DeniedReason == "password");
            }

            Console.WriteLine("hardening: a guest that drops is waited for");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 4, Grace = 10 });
                relay.Start(0);
                int port = relay.Port;
                var host = new RemoteRelay();
                var left = new List<Peer>(); var rx = new List<Msg>();
                host.Left += p => { lock (left) left.Add(p); };
                host.Received += (p, m) => { lock (rx) rx.Add(m); };
                var link = new SessionLink();
                var guest = new Client(link);
                var inbox = new List<Msg>();
                guest.Received += m => { lock (inbox) inbox.Add(m); };
                try
                {
                    host.Connect("127.0.0.1", port, "Hank", null);
                    guest.Connect("127.0.0.1", port, "Bob", null, false, false);
                    var t0 = Environment.TickCount64; while (host.AdmittedCount < 1 && Environment.TickCount64 - t0 < 4000) Thread.Sleep(20);
                    var bob = host.PeerNames()[0];
                    host.Send(host.Find(bob), Msg.Make("welcome", "Hank", "{[\"you\"]=\"" + bob + "\",[\"rtok\"]=\"\"}"));
                    t0 = Environment.TickCount64; while (string.IsNullOrEmpty(link.Token) && Environment.TickCount64 - t0 < 4000) Thread.Sleep(20);
                    guest.Dispose();   // the network drops: no goodbye
                    Thread.Sleep(1500);
                    Check("the host is not told that the guest left (the relay waits for it)", new Func<bool>(() => { lock (left) return left.Count == 0; })());
                    host.Send(host.Find(bob), Msg.Make("chatmsg", "Hank", "{[\"text\"]=\"while you were away\"}"));
                    var back = new Client(link);
                    back.Received += m => { lock (inbox) inbox.Add(m); };
                    back.Connect("127.0.0.1", port, "Bob", null, true, false);
                    t0 = Environment.TickCount64; while (Environment.TickCount64 - t0 < 4000) { lock (inbox) if (inbox.Any(m => m.Kind == "chatmsg")) break; Thread.Sleep(20); }
                    Check("back in time, the guest gets what it missed", new Func<bool>(() => { lock (inbox) return inbox.Any(m => m.Kind == "chatmsg"); })());
                    Check("and the host never heard of the cut", new Func<bool>(() => { lock (left) return left.Count == 0; })());
                    back.Dispose();
                }
                finally { host.Dispose(); guest.Dispose(); }
            }
        }

        /// <summary>A regular or dedicated host keeps the default reader limits, even when it has an Admit rule.</summary>
        static void Compat()
        {
            // the reader keeps a binary message of more than 1 MB in parts only when asked to (the Linux relay): the result is the same
            {
                var big = new byte[3 * 1024 * 1024 + 17];
                new Random(5).NextBytes(big);
                var wire = new List<byte>(System.Text.Encoding.UTF8.GetBytes("resync_bin\t-\t{[\"len\"]=" + big.Length + "}\n"));
                wire.AddRange(big);
                bool def = !new NetReader(new System.IO.MemoryStream(wire.ToArray())).ChunkLargeBinary;
                var plain = new NetReader(new System.IO.MemoryStream(wire.ToArray())).Read();
                var chunked = new NetReader(new System.IO.MemoryStream(wire.ToArray())) { ChunkLargeBinary = true }.Read();
                Check("the reader reads a large binary message straight by default, and in parts on request, with the same bytes",
                    def && plain != null && chunked != null && plain.Data.SequenceEqual(big) && chunked.Data.SequenceEqual(big));
            }
            Console.WriteLine("a regular Relay accepts large messages with its default settings");
            using (var relay = new Relay())
            {
                var got = new List<Msg>();
                relay.Received += (p, m) => { lock (got) got.Add(m); };
                relay.Start(0);
                using (var raw = new Raw(relay.Port))
                {
                    raw.Send("act\tx\t{[\"pad\"]=\"" + new string('p', 300 * 1024) + "\"}\n");
                    var data = new byte[3 * 1024 * 1024];
                    new Random(5).NextBytes(data);
                    raw.Send("resync_bin\t-\t{[\"len\"]=" + data.Length + "}\n");
                    raw.Send(data);
                    var end = Environment.TickCount64 + 5000;
                    while (Environment.TickCount64 < end) { lock (got) if (got.Count >= 2) break; Thread.Sleep(20); }
                    lock (got)
                    {
                        Check("a long text line is taken", got.Any(m => m.Kind == "act" && m.Payload.Length > 300 * 1024));
                        Check("a binary message of 3 MB is taken, byte for byte", got.Any(m => m.Kind == "resync_bin" && m.Data != null && m.Data.SequenceEqual(data)));
                    }
                }
            }
            using (var joined = new ManualResetEventSlim())
            using (var relay = new Relay())
            {
                string pad = new string('p', 300 * 1024);
                string join = "{[\"pad\"]=" + LuaLit.Quote(pad) + "}";
                relay.Admit = (p, m) => m.Payload == join ? null : "{[\"reason\"]=\"test\"}";
                relay.Joined += p => joined.Set();
                relay.Start(0);
                using (var raw = new Raw(relay.Port))
                {
                    var data = new byte[3 * 1024 * 1024];
                    raw.Send("resync_bin\t-\t{[\"len\"]=" + data.Length + "}\n");
                    raw.Send(data);
                    raw.Send("join\tGuest\t" + join + "\n");
                    Check("default Relay with Admit consumes 3 MB of binary then reads a 300 KB join before admission", joined.Wait(5000));
                }
            }
        }

        static bool SameLiteral(object left, object right)
        {
            if (left is Dictionary<object, object> table)
                return right is Dictionary<object, object> other && table.Count == other.Count
                    && table.All(kv => other.TryGetValue(kv.Key, out var value) && SameLiteral(kv.Value, value));
            return Equals(left, right);
        }

        static void ParserCompatibility()
        {
            var random = new Random(334);
            string[] scalars = { "true", "false", "nil", "-33", "1.25", "2E+3", "-7.3e-4", "\"é\\n\\r\\\"\\\\\\065\"" };
            string Scalar() => scalars[random.Next(scalars.Length)];

            string Table(int depth)
            {
                string Value() => depth > 0 && random.Next(4) == 0 ? Table(depth - 1) : Scalar();
                var fields = new List<string>();
                for (int i = 0, count = random.Next(1, 9); i < count; i++)
                {
                    string value = Value();
                    if (i % 3 == 0) fields.Add(value);
                    else fields.Add("[" + (i % 3 == 1 ? i.ToString() : "\"k" + i + "\"") + "] = " + value);
                }
                return "{ " + string.Join(" ,\t", fields) + " }";
            }

            const int count = 4096;
            int matches = 0;
            for (int i = 0; i < count; i++)
            {
                string input = Table(i % 6);
                if (SameLiteral(LegacyLuaLit.Parse(input), LuaLit.Parse(input))) matches++;
            }
            Check("generated valid tables match the 0.8.11 parser (" + matches + "/" + count + ")", matches == count);
        }

        /// <summary>The reader of Lua literals sees text from players: it must end, and not overflow the stack.</summary>
        static void Parser()
        {
            Console.WriteLine("the Lua-literal parser on hostile text");
            bool Quick(string text, out object result)
            {
                object r = null;
                var t = new Thread(() => { r = LuaLit.Parse(text); }, 16 * 1024 * 1024) { IsBackground = true };
                t.Start();
                bool done = t.Join(3000);
                result = r;
                return done;
            }
            object v;
            Check("text that is not Lua ends", Quick("{not lua at all", out v));
            Check("characters that start nothing end", Quick("{!!!@@@###$$$%%%^^^}", out v));
            Check("an unterminated string ends", Quick("{[\"a\"]=\"never closed", out v));
            Check("a table never closed ends", Quick("{[1]={[2]={[3]=", out v));
            Check("a line of 60000 opening braces ends (no stack overflow)", Quick(new string('{', 60000), out v));
            Check("a line of 30000 nested braces closed ends", Quick(new string('{', 30000) + new string('}', 30000), out v));
            Check("nested keys ends", Quick(string.Concat(Enumerable.Repeat("{[", 20000)), out v));
            Check("a backslash and a Unicode digit in a string do not throw", Quick("{[\"a\"]=\"x\\\u0661\u0662\"}", out v));
            Check("a normal message is still read as before", Quick("{[\"name\"]=\"Bob#2\",[\"n\"]=12.5,[\"t\"]={[\"a\"]=true,[\"b\"]=nil,[1]=\"x\"}}", out v)
                && v is Dictionary<object, object> d && (string)d["name"] == "Bob#2" && (double)d["n"] == 12.5 && d["t"] is Dictionary<object, object> t && (bool)t["a"] && (string)t[1L] == "x");
            ParserCompatibility();
        }

        /// <summary>The timer of an attempt and the successor's takeover can meet (review of the pull request): a takeover that slips in
        /// between the timer's check and its call to Migrate must not start another migration, nor end a healthy session.</summary>
        static void Races()
        {
            Console.WriteLine("races: the timer of an attempt meets the successor's takeover");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 4, Migration = true, MigrationTimeoutSeconds = 1 });
                relay.Start(0);
                int port = relay.Port;
                var held = new ManualResetEventSlim(false); var release = new ManualResetEventSlim(false);
                core.TestHookBeforeMigrate = () => { held.Set(); release.Wait(5000); };
                var a = new Player(port, "Ann", null, true);
                a.Wait(() => a.Of("tun_host").Length == 1);
                var b = new Player(port, "Bob", null, false, true);
                var c = new Player(port, "Cat", null, false, true);
                a.Wait(() => a.Of("tun_join").Length >= 2);
                Player nb = null;
                try
                {
                    a.C.Leave();
                    b.Wait(() => b.Of("tun_host").Length == 1);
                    bool fired = held.Wait(6000);                       // (the timer has decided that Bob is late, and waits)
                    Check("the timer fired for the late successor", fired);
                    nb = TakeOver(b, port, "Bob");                      // (Bob arrives at that very moment)
                    nb.Wait(() => nb.Of("tun_host").Length == 1 && core.HostPlayer == nb.Me);
                    Check("the successor took over", core.HostPlayer == nb.Me && !core.Migrating);
                    release.Set();                                      // (now the timer goes on)
                    Thread.Sleep(600);
                    Check("the late timer does not ask another player to take over", c.Of("tun_host").Length == 0);
                    Check("nor end the session", !core.SessionEnded);
                    Check("and the successor stays the host", core.HostPlayer == nb.Me && !core.Migrating);
                }
                finally { release.Set(); a.Dispose(); b.Dispose(); c.Dispose(); nb?.Dispose(); }
            }
        }

        /// <summary>A light load (not a benchmark): many players at once and a burst of host messages; the time is printed.</summary>
        static void Load()
        {
            Console.WriteLine("load: 60 players, a burst of messages");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 64, MaxConnections = 200 });
                relay.Start(0);
                int port = relay.Port;
                var host = new RemoteRelay();
                var guests = new List<Player>();
                try
                {
                    host.Connect("127.0.0.1", port, "Hank", null);
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    for (int i = 0; i < 60; i++) guests.Add(new Player(port, "G" + i));
                    var t0 = Environment.TickCount64; while (host.AdmittedCount < 60 && Environment.TickCount64 - t0 < 20000) Thread.Sleep(20);
                    var joinMs = sw.ElapsedMilliseconds;
                    Check("60 players join within 20 s (" + joinMs + " ms)", host.AdmittedCount == 60);
                    sw.Restart();
                    for (int i = 0; i < 300; i++) host.Broadcast(Msg.Make("peerclock", "Hank", "{[\"name\"]=\"x\",[\"t\"]=" + i + "}"));
                    t0 = Environment.TickCount64; while (guests.Any(g => g.Of("peerclock").Length < 300) && Environment.TickCount64 - t0 < 20000) Thread.Sleep(20);
                    var burstMs = sw.ElapsedMilliseconds;
                    Check("300 broadcasts reach all 60 players, in order, within 20 s (" + burstMs + " ms, 18000 deliveries)", guests.All(g => g.Of("peerclock").Length == 300)
                        && guests.All(g => Field(g.Of("peerclock")[299], "t") == "299"));
                    t0 = Environment.TickCount64; int heard = 0;
                    host.Received += (p, m) => { if (m.Kind == "clock") Interlocked.Increment(ref heard); };
                    for (int i = 0; i < 60; i++) guests[i].C.Send(Msg.Make("clock", "x", "{[\"t\"]=" + i + "}"));
                    while (heard < 60 && Environment.TickCount64 - t0 < 10000) Thread.Sleep(20);
                    Check("the host hears all 60 players", heard >= 60);
                    Console.WriteLine("    (memory of this process: " + (GC.GetTotalMemory(false) / 1048576) + " MB managed)");
                }
                finally { host.Dispose(); foreach (var g in guests) g.Dispose(); }
            }
        }

        static void Robustness()
        {
            Console.WriteLine("robustness: bad input does not stop the service");
            using (var srv = new Relay())
            {
                var core = new SessionCore(srv, new RelayOptions { Grace = 1 });
                srv.Start(0);
                int port = srv.Port;
                var host = new RemoteRelay();
                var joined = new List<Peer>(); var left = new List<Peer>(); var rx = new List<Msg>();
                host.Joined += p => { lock (joined) joined.Add(p); };
                host.Left += p => { lock (left) left.Add(p); };
                host.Received += (p, m) => { lock (rx) rx.Add(m); };
                try
                {
                    host.Connect("127.0.0.1", port, "Hank", null);
                    using (var ok = new Player(port, "Fine"))
                    {
                        // a client that is let in and then sends rubbish
                        using (var raw = new Raw(port))
                        {
                            raw.Send("join\tRude\t{[\"v\"]=\"x\",[\"rp\"]=" + RelayProtocol.Number + "}\n");
                            Thread.Sleep(400);
                            raw.Send("no tab at all\n\n\t\t\n" + "kind\tfrom\t{this is [not lua\n" + "@x:welcome\tx\t{}\n" + "\u0001\u0002\tx\t{}\n" + new string('k', 5000) + "\tx\t{}\n");
                            raw.Send("resync_bin\t-\t{[\"len\"]=5000}\n");
                            raw.Send(new byte[100]);   // (a savegame part that stops after 100 of 5000 bytes: the connection is cut)
                        }
                        Thread.Sleep(2500);
                        Check("a savegame part cut in the middle is never passed on", new Func<bool>(() => { lock (rx) return rx.All(m => m.Kind != "resync_bin"); })());
                        Check("the host is told that player left once its time is over", new Func<bool>(() => { lock (left) return left.Any(p => p.Name.StartsWith("Rude#")); })());
                        Check("the host did not take the targeted-looking kind for a targeted message", new Func<bool>(() => { lock (rx) return rx.All(m => m.Kind != "welcome" || m.From.StartsWith("Rude#")); })());
                        ok.C.Send(Msg.Make("hello", "x", "{}"));
                        Check("the other players and the service are fine", new Func<bool>(() => { for (int i = 0; i < 100; i++) { lock (rx) if (rx.Any(m => m.Kind == "hello")) return true; Thread.Sleep(30); } return false; })());
                    }
                    foreach (var protocol in new[] { "", ",[\"rp\"]=999", ",[\"rp\"]=1.5" })
                    {
                        using (var raw = new Raw(port))
                        {
                            raw.T.ReceiveTimeout = 3000;
                            raw.Send("join\tProtocol\t{[\"v\"]=\"x\"" + protocol + "}\n");
                            var denied = new NetReader(raw.T.GetStream()).Read();
                            Check("absent or different relay protocol is refused with reason relay (" + protocol + ")",
                                denied != null && denied.Kind == "denied" && Field(denied, "reason") == "relay"
                                && Field(denied, "rp") == RelayProtocol.Number.ToString() && raw.ClosedBy(3000));
                        }
                    }
                    using (var oldver = new Raw(port))
                    {
                        // (another MPFever version with the same relay protocol: the relay does not mind, the host decides)
                        oldver.Send("join\tOldMpfever\t{[\"v\"]=\"0.0.1\",[\"rp\"]=" + RelayProtocol.Number + "}\n");
                        Check("a join with another MPFever version but the same relay protocol is let in", new Func<bool>(() => { var end = Environment.TickCount64 + 4000; while (Environment.TickCount64 < end) { lock (joined) if (joined.Any(p => p.Name.StartsWith("OldMpfever#"))) return true; Thread.Sleep(20); } return false; })());
                    }
                    using (var bj = new Raw(port))
                    {
                        bj.Send("join\tBad\t{not lua at all\n");
                        Check("a join that is not even a table is refused and closed", bj.ClosedBy(3000));
                    }
                    // the host cannot speak with the relay's own kinds either
                    using (var p2 = new Player(port, "Other"))
                    {
                        // (the broadcast goes to the players the relay has let in: wait until the host has been told of this one)
                        var wait0 = Environment.TickCount64; while (!host.PeerNames().Any(n => n.StartsWith("Other#")) && Environment.TickCount64 - wait0 < 4000) Thread.Sleep(20);
                        host.Broadcast(Msg.Make("tun_join", "Hank", "{[\"name\"]=\"Zed#1\"}"));
                        host.Broadcast(Msg.Make("session", "Hank", "{[\"started\"]=true}"));
                        Check("the relay's kinds are not passed on from the host to the players", p2.Wait(() => p2.Of("session").Length == 1) && p2.Of("tun_join").Length == 0);
                    }
                }
                finally { host.Dispose(); }
            }
        }

        static string TokenOf(Player p) => Field(p.Of("tun_host").Last(), "token");

        /// <summary>The successor, asked on its guest connection, connects again as the host with its token.</summary>
        static Player TakeOver(Player guest, int port, string name)
        {
            guest.Wait(() => guest.Of("tun_host").Length >= 1);
            return new Player(port, name, null, true, false, TokenOf(guest));
        }

        static void Migration()
        {
            Console.WriteLine("host migration");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 6, Migration = true, MigrationTimeoutSeconds = 30 });
                relay.Start(0);
                int port = relay.Port;
                var a = new Player(port, "Ann", null, true);
                a.Wait(() => a.Of("tun_host").Length == 1);
                var b = new Player(port, "Bob", null, false, true);
                var c = new Player(port, "Cat", null, false, true);
                a.Wait(() => a.Of("tun_join").Length >= 2);
                Player nb = null;
                try
                {
                    var cn = Field(a.Of("tun_join")[1], "name");
                    a.C.Leave();
                    Check("the next player is asked to take over, with epoch, previous host and a token",
                        b.Wait(() => b.Of("tun_host").Length == 1 && Field(b.Of("tun_host")[0], "migrate") == "True" && Field(b.Of("tun_host")[0], "prev").StartsWith("Ann#") && (TokenOf(b) ?? "").Length >= 16));
                    Check("the session is not ended and waits for it", !core.SessionEnded && core.Migrating);
                    using (var eve = new Player(port, "Eve", null, true))
                        Check("another player cannot take over", eve.Wait(() => eve.DeniedReason != null) && eve.DeniedReason == "hosted");
                    var dan = new Player(port, "Dan", null, false, true);   // joins while the migration waits
                    nb = TakeOver(b, port, "Bob");
                    Check("the successor, connecting again with its token, is accepted", nb.Wait(() => nb.Of("tun_host").Length == 1 && core.HostPlayer == nb.Me));
                    Check("the migration is over", !core.Migrating && !core.SessionEnded);
                    Check("the players are announced to it, the one that joined meanwhile too", nb.Wait(() => nb.Of("tun_join").Any(m => Field(m, "name") == cn) && nb.Of("tun_join").Any(m => (Field(m, "name") ?? "").StartsWith("Dan#"))));
                    Check("it is told when the list is complete", nb.Wait(() => nb.Of("tun_players").Length == 1 && Field(nb.Of("tun_players")[0], "n") == "2"));
                    Check("but not its own old guest connection", nb.Of("tun_join").All(m => !(Field(m, "name") ?? "").StartsWith("Bob#")));
                    c.C.Send(Msg.Make("hello", "x", "{}"));
                    Check("messages go to the new host", nb.Wait(() => nb.Of("hello").Length == 1));
                    nb.C.Send(Msg.Make("session", "x", "{[\"started\"]=true}"));
                    Check("and its messages reach the players", c.Wait(() => c.Of("session").Length == 1));
                    dan.Dispose();
                }
                finally { a.Dispose(); b.Dispose(); c.Dispose(); nb?.Dispose(); }
            }

            Console.WriteLine("several migrations one after the other, and a successor that does not come");
            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, new RelayOptions { MaxPlayers = 6, Migration = true, MigrationTimeoutSeconds = 1 });
                relay.Start(0);
                int port = relay.Port;
                var h = new Player(port, "Ann", null, true);
                h.Wait(() => h.Of("tun_host").Length == 1);
                var guests = new List<Player>();
                foreach (var n in new[] { "Bob", "Cat", "Dan", "Eli" }) guests.Add(new Player(port, n, null, false, true));
                h.Wait(() => h.Of("tun_join").Length >= 4);
                var all = new List<Player>(guests) { h };
                try
                {
                    // 1. the oldest is silent: the next one is asked after the timeout and takes over
                    h.C.Leave();
                    Check("the oldest successor is asked first", guests[0].Wait(() => guests[0].Of("tun_host").Length == 1));
                    var host2 = TakeOver(guests[1], port, "Cat"); all.Add(host2);
                    Check("it did not come: the next one is asked, and takes over", host2.Wait(() => host2.Of("tun_host").Length == 1 && core.HostPlayer == host2.Me && !core.Migrating, 8000));
                    Check("the first one was not asked again", guests[0].Of("tun_host").Length == 1);
                    // 2. a second migration, at once
                    host2.C.Leave();
                    Check("a second migration asks a player that was not asked before", guests[2].Wait(() => guests[2].Of("tun_host").Length == 1 || guests[0].Of("tun_host").Length > 1, 4000));
                    // the host and the successor leave together: the next one is asked
                    guests[2].C.Leave();
                    var host3 = guests[3].Wait(() => guests[3].Of("tun_host").Length >= 1, 8000) ? new Player(port, "Eli", null, true, false, TokenOf(guests[3])) : null;
                    all.Add(host3);
                    Check("when the successor leaves too, the next one is asked and takes over", host3 != null && host3.Wait(() => host3.Of("tun_host").Length == 1 && core.HostPlayer == host3.Me));
                    // 3. the last host leaves with nobody able to take over
                    host3?.C.Leave();
                    Check("with nobody left able to take over, the session ends", new Func<bool>(() => { for (int i = 0; i < 100 && !core.SessionEnded; i++) Thread.Sleep(50); return core.SessionEnded; })());
                }
                finally { foreach (var x in all) x?.Dispose(); }
            }
        }
    }
}
