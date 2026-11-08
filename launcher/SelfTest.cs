using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace MPFever
{
    /// <summary>Headless check of relay + client + file links, simulating two games (MPFever.exe --selftest).</summary>
    static class SelfTest
    {
        static void GameWrites(GameLink g, string line)
        {
            File.AppendAllText(Path.Combine(g.Dir, "out.log"), line + "\n", new UTF8Encoding(false));
        }

        public static int Run()
        {
            int port = 28191;
            var relay = new Relay();
            var hostGame = new GameLink("Host", "host");
            var clientGame = new GameLink("Client", "client");
            relay.Received += (p, m) => hostGame.ToGame(m);
            relay.Joined += p => relay.Send(p, Msg.Make("welcome", "Host", "{[\"you\"]=\"" + p.Name + "\"}"));
            hostGame.FromGame += (g, m) => { m.From = "Host"; relay.Broadcast(m); };
            relay.Start(port);

            var client = new Client();
            client.Received += m => clientGame.ToGame(m);
            clientGame.FromGame += (g, m) => client.Send(m);
            client.Connect("127.0.0.1", port, "Client");

            GameWrites(hostGame, "hello\tHost\t{[\"name\"]=\"Host\"}");
            GameWrites(clientGame, "det_hash\tClient\t{[\"round\"]=0,[\"parts\"]={[\"time\"]=123,[\"txt\"]=\"a\\\"b\"}}");
            File.AppendAllText(Path.Combine(clientGame.Dir, "out.log"), "act_req" + (char)9 + "Client" + (char)9 + "{}" + (char)10, new UTF8Encoding(false));
            Thread.Sleep(800);

            var hostIn = File.ReadAllText(Path.Combine(hostGame.Dir, "in.log"));
            var clientIn = File.ReadAllText(Path.Combine(clientGame.Dir, "in.log"));
            Log.W("host in.log  : " + hostIn.Replace("\n", " | "));
            Log.W("client in.log: " + clientIn.Replace("\n", " | "));
            var parsed = LuaLit.Show(LuaLit.Parse("{[\"round\"]=0,[\"parts\"]={[\"time\"]=123,[\"txt\"]=\"a\\\"b\"}}"));
            Log.W("parse: " + parsed);
            bool ok = hostIn.Contains("act_req" + (char)9 + "Client#1") && hostIn.Contains("det_hash\tClient#1\t") && clientIn.Contains("welcome\tHost") && clientIn.Contains("hello\tHost") && parsed == "{parts={time=123,txt=a\"b},round=0}";
            client.Dispose(); relay.Dispose();
            Log.W("transport: " + (ok ? "ok" : "FAILED"));
            ok &= RunResume();
            ok &= RunServer();
            ok &= RunGameOpts();
            ok &= RunOptsKept();
            ok &= RunPublic();
            ok &= RunUpdater();
            ok &= RunPortMap();
            ok &= RunRedact();
            ok &= RunGameDir();
            ok &= RunSmartAppControl();
            ok &= RunDiag();
            ok &= RunIssue111();
            ok &= RunSession067();
            ok &= RunDlcs();
            ok &= RunSaveMods();
            ok &= RunServerConfig();
            ok &= RunReportMode();
            ok &= RunFineTimer();
            ok &= RunServerJoin074();
            ok &= RunSharedLog075();
            ok &= RunServer076();
            ok &= RunReport077();
            Log.W(ok ? "SELFTEST OK" : "SELFTEST FAILED");
            return ok ? 0 : 1;
        }

        /// <summary>(0.7.7) A player's report says who plays and whether the game runs (from the host's messages: it read
        /// "Players: -; game running: no" in a running game), and the build of a game MPFever does not know (issue #135: a GOG copy,
        /// build 40393, read "unknown build").</summary>
        static bool RunReport077()
        {
            bool ok = true;
            void C(bool c, string what) { Log.W((c ? "ok    " : "FAIL  ") + "0.7.7 report: " + what); ok &= c; }
            C(MainForm.SessionStarted("{[\"started\"]=true,[\"speed\"]=4,[\"cmode\"]=\"shared\"}") == true, "the host's session message: the game runs");
            C(MainForm.SessionStarted("{[\"started\"]=false,[\"speed\"]=0}") == false, "  or not");
            C(MainForm.SessionStarted("{[\"speed\"]=0}") == null && MainForm.SessionStarted("not lua") == null, "  nothing said: unknown");
            C(MainForm.HostRunningText(1) == "yes" && MainForm.HostRunningText(0) == "no" && MainForm.HostRunningText(-1).StartsWith("?"), "  written yes / no / ?");
            C(MainForm.NotesPeer("peerclock", "Kai") && MainForm.NotesPeer("act", "Eric#3") && !MainForm.NotesPeer("session", "MPFever")
                && !MainForm.NotesPeer("chatmsg", "Kai") && !MainForm.NotesPeer("act", ""), "the players: the names the host's messages come with, not MPFever's own");
            var f = Path.Combine(Path.GetTempPath(), "mpfever-selftest-stdout-" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                File.WriteAllText(f, "[2026-11-07 21:29:09Z - MESSAGE  - Main             - Main           ]  Application startup. Hello!\n"
                    + "[2026-11-07 21:29:09Z - MESSAGE  - Main             - Main           ]  Starting up build version: 40393, build name \"Build\"\n");
                C(Reporter.BuildInLog(f) == "40393", "the build the game's log names (a GOG copy, #135)");
                File.WriteAllText(f, "nothing here\n");
                C(Reporter.BuildInLog(f) == null && Reporter.BuildInLog(f + ".none") == null && Reporter.BuildInLog(null) == null, "  none named, or no log: none");
            }
            catch (Exception e) { C(false, "the game's log: " + e.Message); }
            finally { try { File.Delete(f); } catch { } }
            // (FAILALIKE) a build refused on every game, its builder's own too: the games did not part
            C(MainForm.FailedUid("{[\"why\"]=\"native construction refused\",[\"uid\"]=\"Host:58\"}") == "Host:58" && MainForm.FailedUid("{}") == null,
                "a failed replay's uid");
            C(MainForm.RefusedEverywhere("Host:58", new[] { "Client", "Host" }, new[] { "Host", "Client#1" }),
                "refused on every game, the builder's (the host, an AI's build) too: alike, no reload");
            C(!MainForm.RefusedEverywhere("Host:58", new[] { "Client" }, new[] { "Host", "Client#1" }),
                "  the builder's game built it (a player's own build, or its report not there yet): reloaded, as before");
            C(!MainForm.RefusedEverywhere("Bence#11:3", new[] { "Bence", "yoyo" }, new[] { "yoyo", "Bence#11", "YkeWoudstra#2" }),
                "  a game that did not say it refused: reloaded");
            C(MainForm.RefusedEverywhere("Bence#11:3", new[] { "Bence#11", "yoyo", "YkeWoudstra#2" }, new[] { "yoyo", "Bence#11", "YkeWoudstra#2" })
                && !MainForm.RefusedEverywhere("nocolon", new[] { "a" }, new[] { "a" }) && !MainForm.RefusedEverywhere("a:1", new[] { "a" }, new string[0]),
                "  a player's build refused everywhere: alike; nothing known: reloaded");
            // (BUILDWARN) another game build than the host's: a warning, never a refusal
            C(MainForm.BuildWarning(null, "6ad9ce10|40425|steam", "6ad9ce10|40425|steam") == "", "the same game build: no warning");
            var bw = MainForm.BuildWarning(null, "6ad9ce10|40425|steam", "6ab3eec7|40393|other");
            C(bw.Contains("40393") && bw.Contains("40425"), "a player on another build (a GOG copy, #135): warned with both numbers (" + bw + ")");
            var hw = MainForm.BuildWarning("Til", "6ad9ce10|40425|steam", "6ab3eec7|?|other");
            C(hw.StartsWith("Til") && hw.Contains("6ab3eec7") && hw.Contains("40425"), "  the host's view: the player named, an unknown number shown by its stamp");
            C(MainForm.BuildWarning(null, "", "6ab3eec7|40393|other") == "" && MainForm.BuildWarning("x", "6ad9ce10|40425|steam", "") == "",
                "  an older MPFever that says nothing: no warning");
            // (DLCSESSION) the savegame's DLCs some game lacks: off for the whole session
            var off = Mods.DlcOff("urbangames_deluxe_upgrade_pack", new[] { "urbangames_deluxe_upgrade_pack,urbangames_preorder_pack", "none" });
            C(off.Count == 1 && off[0] == "urbangames_deluxe_upgrade_pack", "a DLC of the savegame a player lacks: off for the session");
            C(Mods.DlcOff("urbangames_deluxe_upgrade_pack", new[] { "urbangames_deluxe_upgrade_pack", "urbangames_deluxe_upgrade_pack" }).Count == 0,
                "  every game has it: kept");
            C(Mods.DlcOff("none", new[] { "none" }).Count == 0 && Mods.DlcOff("urbangames_deluxe_upgrade_pack", new[] { "", "urbangames_deluxe_upgrade_pack" }).Count == 0,
                "  a savegame without DLC, or a list not known (an older MPFever): nothing off");
            C(Mods.DlcMinus("urbangames_deluxe_upgrade_pack,urbangames_preorder_pack", new[] { "urbangames_preorder_pack" }) == "urbangames_deluxe_upgrade_pack"
                && Mods.DlcMinus("urbangames_preorder_pack", new[] { "urbangames_preorder_pack" }) == "none", "  the session's DLCs said without those off");
            C(Mods.DlcWarning("Til", "urbangames_deluxe_upgrade_pack", "none") == "" && Mods.DlcWarning("Til", "none", "urbangames_deluxe_upgrade_pack") == "",
                "  no more 'desyncs possible' warnings: an unused DLC does nothing, a used one some player lacks is switched off");
            // (MODLOCALFIRST) a mod installed twice: the local copy the game runs is named in the "other version" message
            C(Mods.DiffersName("Industry Evolution", null) == "Industry Evolution", "a mod of another version: its name");
            C(Mods.DiffersName("Industry Evolution", @"E:\Steam\userdata\1\3493540\local\mods\spy_industry_evolution").Contains(@"local\mods\spy_industry_evolution"),
                "  installed twice: the local copy that replaces the Mod Hub's named");
            // (SDUMPAFTER) the check after a difference of the simulation: the whole dump on every game
            C(MainForm.WantsWorldDump("vehicles") && MainForm.WantsWorldDump("script:towns") && MainForm.WantsWorldDump("edges"),
                "a difference of the simulation: the next check's dump whole");
            C(!MainForm.WantsWorldDump("money") && !MainForm.WantsWorldDump("names") && !MainForm.WantsWorldDump("buildIds") && !MainForm.WantsWorldDump(""),
                "  not for money, names or a diagnostic part");
            return ok;
        }

        /// <summary>(0.7.6) The user's server, 2026-11-07 20:02-20:10: a player gone during a resynchronisation is found in its
        /// wait under any of its connections' names (RESYNCLEFTNAME); a player who joins during a resynchronisation gets the game
        /// being sent (JOINMIDRESYNC); a stop or a restart cuts a resynchronisation short (STOPRESYNC).</summary>
        static bool RunServer076()
        {
            bool ok = true;
            void C(bool c, string what) { Log.W((c ? "ok    " : "FAIL  ") + "0.7.6 server: " + what); ok &= c; }
            var w = new HashSet<string> { "Knight-HD#2", "chris#10" };
            C(MainForm.WaitedFor(w, "chris#12", false), "chris#12 gone: the wait for chris#10 is his (the same player)");
            C(!MainForm.WaitedFor(w, "chris#12", true), "  MPFEVER_RESYNCLEFTNAME=0: this name only, as before (not found)");
            C(MainForm.WaitedFor(w, "chris#10", true) && MainForm.WaitedFor(w, "chris#10", false), "  its own name: found both ways");
            C(!MainForm.WaitedFor(w, "chrisB#4", false) && !MainForm.WaitedFor(new HashSet<string>(), "chris#12", false), "  another player, or nobody waited for: no");
            // (then the 20 s wait drops chris#10 once no connection of chris is there: DropDeparted, 0.7.4)
            C(MainForm.DropDeparted(w, "chris#12", new[] { "Knight-HD#2" }) == 1 && !w.Contains("chris#10"), "  chris gone for good: chris#10 no longer waited for");
            C(MainForm.JoinDuringResync(false, true, false, 3, 0, false) == "pending", "join, no resynchronisation: one of its own, as before");
            C(MainForm.JoinDuringResync(true, false, false, 0, 0, false) == "pending", "join before the game is saved: as before");
            C(MainForm.JoinDuringResync(true, true, true, 3, 2, false) == "send", "join while the game is being sent: it gets it too");
            C(MainForm.JoinDuringResync(true, true, true, 3, 3, false) == "pending", "join once the wait is over: a resynchronisation of its own afterwards");
            C(MainForm.JoinDuringResync(true, true, false, 3, 2, false) == "pending", "join after the sending: one of its own afterwards");
            C(MainForm.JoinDuringResync(true, true, true, 3, 2, true) == "none", "MPFEVER_JOINMIDRESYNC=0: nothing, as before");
            C(MainForm.StopCutsResync(true, false) && !MainForm.StopCutsResync(false, false) && !MainForm.StopCutsResync(true, true),
                "a stop or restart cuts a resynchronisation short (MPFEVER_STOPRESYNC=0: not)");
            // (MODIOROOT) the folders mod.io keeps the Mod Hub mods in, as its settings move them
            var dir = Path.Combine(Path.GetTempPath(), "mpfever-selftest-modio-" + Guid.NewGuid().ToString("N"));
            try
            {
                var lad = Path.Combine(dir, "local");
                Directory.CreateDirectory(Path.Combine(lad, "mod.io", "10640", "u2"));
                Directory.CreateDirectory(Path.Combine(lad, "mod.io", "10640", "u1"));
                File.WriteAllText(Path.Combine(lad, "mod.io", "10640", "u1", "user.json"), "{\"OAuth\":{\"token\":\"secret\"},\"RootLocalStoragePath\":\"E:\\\\Games\\\\modio\"}");
                File.WriteAllText(Path.Combine(lad, "mod.io", "10640", "u2", "user.json"), "{\"RootLocalStoragePath\":\"\"}");
                File.WriteAllText(Path.Combine(lad, "mod.io", "globalsettings.json"), "{ \"RootLocalStoragePath\" : \"D:/mods/modio\" }");
                var got = Mods.ModioStorages(lad, @"C:\Users\Public", false);
                C(got.Count == 3 && got[0] == @"E:\Games\modio" && got[1] == "D:/mods/modio" && got[2] == @"C:\Users\Public\mod.io",
                    "mod.io: a user's folder, then mod.io's settings, then the default (" + string.Join(" | ", got) + ")");
                File.WriteAllText(Path.Combine(lad, "mod.io", "globalsettings.json"), "{\"RootLocalStoragePath\":\"relative\\\\x\"}");
                File.Delete(Path.Combine(lad, "mod.io", "10640", "u1", "user.json"));
                got = Mods.ModioStorages(lad, @"C:\Users\Public", false);
                C(got.Count == 1 && got[0] == @"C:\Users\Public\mod.io", "mod.io: an empty or relative folder moves nothing (" + string.Join(" | ", got) + ")");
                File.WriteAllText(Path.Combine(lad, "mod.io", "globalsettings.json"), "{\"RootLocalStoragePath\":\"C:\\\\Users\\\\Public\\\\mod.io\\\\\"}");
                got = Mods.ModioStorages(lad, @"C:\Users\Public", false);
                C(got.Count == 1, "mod.io: the default named again: once");
                got = Mods.ModioStorages(Path.Combine(dir, "nothing"), @"C:\Users\Public", false);
                C(got.Count == 1 && got[0] == @"C:\Users\Public\mod.io", "mod.io: no settings: the default");
                File.WriteAllText(Path.Combine(lad, "mod.io", "globalsettings.json"), "{\"RootLocalStoragePath\":\"D:\\\\m\"}");
                got = Mods.ModioStorages(lad, @"C:\Users\Public", true);
                C(got.Count == 1 && got[0] == @"C:\Users\Public\mod.io", "mod.io: MPFEVER_MODIOROOT=0, the default only, as before");
            }
            catch (Exception e) { C(false, "mod.io: " + e.Message); }
            finally { try { Directory.Delete(dir, true); } catch { } }
            return ok;
        }

        /// <summary>(0.7.5) Two games of one Steam account on one PC share one game log: a game that ended with code 0 while
        /// another game ran is not taken for a crash (MPFEVER_SHAREDLOGOLD=1: as before).</summary>
        static bool RunSharedLog075()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var kept = Environment.GetEnvironmentVariable("MPFEVER_SHAREDLOGOLD");
            try
            {
                Environment.SetEnvironmentVariable("MPFEVER_SHAREDLOGOLD", null);
                Check(!Reporter.CrashedSince(DateTime.MinValue, null, 0, true), "shared log: code 0 with another game on the PC is no crash");
                Check(Reporter.OtherGamesRunning(-1) >= 0, "shared log: the other games counted");
                // (the other cases read this PC's own crash dumps: the same answer as the call of before)
                Check(Reporter.CrashedSince(DateTime.MaxValue, null, 0, false) == Reporter.CrashedSince(DateTime.MaxValue), "shared log: alone, as before");
                Check(Reporter.CrashedSince(DateTime.MaxValue, null, unchecked((int)0xC0000005), true) == Reporter.CrashedSince(DateTime.MaxValue), "shared log: another exit code, as before");
                Environment.SetEnvironmentVariable("MPFEVER_SHAREDLOGOLD", "1");
                Check(Reporter.CrashedSince(DateTime.MaxValue, null, 0, true) == Reporter.CrashedSince(DateTime.MaxValue), "shared log: MPFEVER_SHAREDLOGOLD=1, as before");
            }
            catch (Exception e) { Check(false, "shared log: " + e.Message); }
            finally { Environment.SetEnvironmentVariable("MPFEVER_SHAREDLOGOLD", kept); }
            return ok;
        }

        /// <summary>(0.7.4) The user's server, 2026-11-06 23:13: a player gone during a resynchronisation is no longer waited for
        /// once not back (RESYNCLEFT); a dedicated server tries its world again when a published mod is missing, not a local one,
        /// three times (MODRETRY); a player's MPFever never cuts itself for silence while it handles a message (BUSYCUT).</summary>
        static bool RunServerJoin074()
        {
            bool ok = true;
            void C(bool c, string what) { Log.W((c ? "ok    " : "FAIL  ") + "0.7.4 server: " + what); ok &= c; }
            var w = new HashSet<string> { "Ann#2", "dickj#53", "Bob#3" };
            C(MainForm.DropDeparted(w, "dickj#53", new[] { "Ann#2", "Bob#3" }) == 1 && !w.Contains("dickj#53") && w.Count == 2, "a player gone and not back: no longer waited for");
            w = new HashSet<string> { "Ann#2", "dickj#53" };
            C(MainForm.DropDeparted(w, "dickj#53", new[] { "Ann#2", "dickj#55" }) == 0 && w.Contains("dickj#53"), "back under another connection: still waited for (it says so itself)");
            w = new HashSet<string> { "Ann#2" };
            C(MainForm.DropDeparted(w, "dickj#53", new string[0]) == 0 && w.Count == 1, "a player nobody waited for: nothing changes");
            C(MainForm.ServerModRetry(true, false, 0) && MainForm.ServerModRetry(true, false, 2) && !MainForm.ServerModRetry(true, false, 3), "a server tries its world again three times");
            C(!MainForm.ServerModRetry(true, true, 0), "a local mod of the host: no try again (nobody can install it)");
            C(!MainForm.ServerModRetry(false, false, 0), "a player's game: never (it is told to install the mods)");
            Environment.SetEnvironmentVariable("MPFEVER_MODRETRY", "0");
            C(!MainForm.ServerModRetry(true, false, 0), "MPFEVER_MODRETRY=0: as before");
            Environment.SetEnvironmentVariable("MPFEVER_MODRETRY", null);
            C(Client.BusyHolds(DateTime.UtcNow.Ticks) && !Client.BusyHolds(0), "a message being handled: no silence cut; none: the usual cut");
            Environment.SetEnvironmentVariable("MPFEVER_BUSYCUT", "1");
            C(!Client.BusyHolds(DateTime.UtcNow.Ticks), "MPFEVER_BUSYCUT=1: as before");
            Environment.SetEnvironmentVariable("MPFEVER_BUSYCUT", null);
            // (0.7.4, the launcher) the game starts by itself only when asked; the percent of a game sent
            C(!MainForm.LaunchAtStart(false, false, new string[0]), "launcher: the game waits for the player's click by default");
            C(MainForm.LaunchAtStart(true, false, new string[0]), "launcher: the box ticked, the game starts by itself");
            C(MainForm.LaunchAtStart(false, true, new string[0]), "launcher: a Steam invitation starts it at once");
            C(MainForm.LaunchAtStart(false, false, new[] { "--updated", "--launch" }), "launcher: « Start Transport Fever 3 again » (--launch) starts it at once");
            Environment.SetEnvironmentVariable("MPFEVER_AUTOLAUNCH", "1");
            C(MainForm.LaunchAtStart(false, false, new string[0]), "launcher: MPFEVER_AUTOLAUNCH=1, always, as before");
            Environment.SetEnvironmentVariable("MPFEVER_AUTOLAUNCH", null);
            C(MainForm.PartsPct(0, 1282) == 0 && MainForm.PartsPct(641, 1282) == 50 && MainForm.PartsPct(1281, 1282) == 99 && MainForm.PartsPct(1282, 1282) == 100,
                "the percent of a game sent: 0, 50, never 100 before its last part, 100");
            return ok;
        }

        /// <summary>A player's connection cut while both sides keep sending (the host to a player it waits for, the player into
        /// its link while it has no connection): back with its link, every message arrives once and in order on both sides,
        /// with no new welcome; a claim the host does not know gets a plain welcome; a player not back within the grace leaves.</summary>
        static bool RunResume()
        {
            int port = 28192;
            var relay = new Relay { Grace = 4, MayWait = _ => true };
            var fromClient = new List<int>();
            int welcomes = 0, aways = 0, resumes = 0, lefts = 0;
            Peer peer = null;
            relay.Joined += p => { peer = p; relay.Send(p, Msg.Make("welcome", "Host", "{[\"you\"]=\"" + p.Name + "\",[\"rtok\"]=\"" + p.Link.Token + "\"}")); };
            relay.Received += (p, m) => { if (m.Kind == "t") lock (fromClient) fromClient.Add((int)SessionLink.ReadN(m, "i")); };
            relay.Away += p => Interlocked.Increment(ref aways);
            relay.Resumed += (p, s, n) => Interlocked.Increment(ref resumes);
            relay.Left += p => Interlocked.Increment(ref lefts);
            relay.Start(port);
            var link = new SessionLink();
            var fromHost = new List<int>();
            Client current = null;
            Client Wire(Client c)
            {
                c.Received += m =>
                {
                    if (m.Kind == "welcome") Interlocked.Increment(ref welcomes);
                    if (m.Kind == "t") lock (fromHost) fromHost.Add((int)SessionLink.ReadN(m, "i"));
                };
                return c;
            }
            int hostN = 0, clientN = 0;
            void Exchange(int n)
            {
                for (int k = 0; k < n; k++)
                {
                    if (peer != null) relay.Send(peer, Msg.Make("t", "Host", "{[\"i\"]=" + (++hostN) + "}"));
                    var m = Msg.Make("t", "Client", "{[\"i\"]=" + (++clientN) + "}");
                    var to = current;
                    if (to != null) to.Send(m); else link.Sent(m);
                }
            }
            bool Wait(Func<bool> f) { for (int i = 0; i < 100 && !f(); i++) Thread.Sleep(50); return f(); }
            bool InOrder(List<int> l, int n) { lock (l) return l.Count == n && l.Select((v, i) => v == i + 1).All(x => x); }
            bool ok = true;
            try
            {
                current = Wire(new Client(link));
                current.Connect("127.0.0.1", port, "Client");
                ok &= Wait(() => welcomes == 1 && link.Token != null);
                Exchange(300);
                // (the welcome a host sends when the player's game has loaded a world names no link: the link goes on)
                relay.Send(peer, Msg.Make("welcome", "Host", "{}"));
                ok &= Wait(() => welcomes == 2) && link.Token != null;
                // a cut with messages on their way, both sides going on while it lasts
                var old = current; current = null; old.Dispose();
                ok &= Wait(() => aways == 1);
                Exchange(200);
                current = Wire(new Client(link));
                current.Connect("127.0.0.1", port, "Client", null, true);
                ok &= Wait(() => resumes == 1);
                Exchange(100);
                ok &= Wait(() => InOrder(fromClient, clientN) && InOrder(fromHost, hostN));
                Log.W("resume: " + fromHost.Count + "/" + hostN + " from the host, " + fromClient.Count + "/" + clientN + " from the player in order, welcomes " + welcomes + ", away " + aways + ", resumed " + resumes + ", left " + lefts);
                ok &= welcomes == 2 && lefts == 0 && InOrder(fromClient, clientN) && InOrder(fromHost, hostN);
                // an unknown claim: a plain welcome (the player is a new one), and the player waited for under that name leaves
                link.Token = "0123456789abcdef0123456789abcdef";
                var old2 = current; current = null; old2.Dispose();
                ok &= Wait(() => aways == 2);
                current = Wire(new Client(link));
                current.Connect("127.0.0.1", port, "Client", null, true);
                ok &= Wait(() => welcomes == 3 && lefts == 1);
                // a player not back within the grace leaves
                var old3 = current; current = null; old3.Dispose();
                ok &= Wait(() => aways == 3);
                ok &= Wait(() => lefts == 2);
                Log.W("resume: a claim the host does not know gets a welcome (" + welcomes + "), the player away " + aways + " time(s), left " + lefts + " time(s)");
            }
            catch (Exception e) { Log.Err("resume: " + e.Message); ok = false; }
            try { current?.Dispose(); } catch { }
            relay.Dispose();
            Log.W("resume: " + (ok ? "ok" : "FAILED"));
            return ok;
        }

        /// <summary>Automatic update: which release of GitHub's list is taken (newest published one with a zip, the players' or
        /// the server's archive), and the files put into a folder from a release zip (the player's settings kept).</summary>
        static bool RunUpdater()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            string Asset(string name) => "{\"name\":\"" + name + "\",\"size\":10,\"digest\":\"sha256:AB\",\"browser_download_url\":\"https://github.com/x/" + name + "\"}";
            string Rel(string tag, bool draft, bool pre, params string[] assets) =>
                "{\"tag_name\":\"" + tag + "\",\"draft\":" + (draft ? "true" : "false") + ",\"prerelease\":" + (pre ? "true" : "false")
                + ",\"html_url\":\"https://github.com/x/" + tag + "\",\"assets\":[" + string.Join(",", assets) + "]}";
            var json = "[" + string.Join(",",
                Rel("0.3.20", true, false, Asset("MPFever-0.3.20.zip")),
                Rel("0.3.19", false, true, Asset("MPFever-0.3.19.zip")),
                Rel("0.3.15", false, false, Asset("MPFever-0.3.15-experimental-server.zip"), Asset("MPFever-0.3.15-experimental.zip")),
                Rel("0.3.14", false, false, Asset("MPFever-0.3.14-experimental.zip")),
                Rel("0.3.16", false, false, Asset("notes.txt"))) + "]";
            var u = Updater.Newest(json, "0.3.14-experimental");
            Check(u != null && u.Version == "0.3.15" && u.ZipUrl.EndsWith("MPFever-0.3.15-experimental.zip") && u.Sha256 == "ab",
                "update: newest published release with a zip, the players' archive (" + (u == null ? "none" : u.Version + " " + u.ZipUrl) + ")");
            var us = Updater.Newest(json, "0.3.14-experimental", true);
            Check(us != null && us.ZipUrl.EndsWith("-server.zip"), "update: a dedicated server takes the server's archive");
            Check(Updater.Newest(json, "0.3.15-experimental") == null, "update: nothing newer than 0.3.15");
            Check(Updater.CompareVersions(Updater.ParseVersion("0.3.10"), Updater.ParseVersion("0.3.9")) > 0, "update: 0.3.10 is newer than 0.3.9");
            Check(Updater.CompareVersions(Updater.ParseVersion("0.4.0"), Updater.ParseVersion("0.3.25")) > 0, "update: 0.4.0 is newer than 0.3.25");
            // (from 0.3.22 the archives lose "-experimental": the older launchers must still take them)
            var json2 = "[" + Rel("0.3.22", false, false, Asset("MPFever-0.3.22-server.zip"), Asset("MPFever-0.3.22.zip")) + ","
                + Rel("0.3.21", false, false, Asset("MPFever-0.3.21-experimental-server.zip"), Asset("MPFever-0.3.21-experimental.zip")) + "]";
            var u2 = Updater.Newest(json2, "0.3.21-experimental");
            Check(u2 != null && u2.Version == "0.3.22" && u2.ZipUrl.EndsWith("/MPFever-0.3.22.zip"), "update: 0.3.21-experimental takes MPFever-0.3.22.zip");
            var us2 = Updater.Newest(json2, "0.3.21-experimental", true);
            Check(us2 != null && us2.ZipUrl.EndsWith("/MPFever-0.3.22-server.zip"), "update: a 0.3.21-experimental server takes MPFever-0.3.22-server.zip");
            Check(Updater.Newest(json2, "0.3.22") == null, "update: nothing newer than 0.3.22");

            var root = Path.Combine(Path.GetTempPath(), "mpfever_selftest_update_" + System.Diagnostics.Process.GetCurrentProcess().Id);
            try
            {
                if (Directory.Exists(root)) Directory.Delete(root, true);
                var app = Path.Combine(root, "app");
                Directory.CreateDirectory(Path.Combine(app, "mod", "mpfever_1", "old"));
                File.WriteAllText(Path.Combine(app, "MPFever.exe"), "old");
                File.WriteAllText(Path.Combine(app, "mpfever_settings.txt"), "name=me");
                File.WriteAllText(Path.Combine(app, "mod", "mpfever_1", "old", "gone.lua"), "x");
                var zip = Path.Combine(root, "u.zip");
                using (var z = System.IO.Compression.ZipFile.Open(zip, System.IO.Compression.ZipArchiveMode.Create))
                {
                    void Add(string name, string text) { using (var w = new StreamWriter(z.CreateEntry(name).Open())) w.Write(text); }
                    Add("MPFever/MPFever.exe", "new");
                    Add("MPFever/mpfever_settings.txt", "name=default");
                    Add("MPFever/mod/mpfever_1/mod.json", "{}");
                }
                var files = Path.Combine(root, "files");
                Updater.Unpack(zip, files);
                Updater.Install(files, app);
                Check(File.ReadAllText(Path.Combine(app, "MPFever.exe")) == "new", "update: files replaced");
                Check(File.ReadAllText(Path.Combine(app, "mpfever_settings.txt")) == "name=me", "update: the player's settings kept");
                Check(File.Exists(Path.Combine(app, "mod", "mpfever_1", "mod.json")) && !Directory.Exists(Path.Combine(app, "mod", "mpfever_1", "old")),
                    "update: the mod folder replaced as a whole");
                // (#103) the cleanup after an update spares the download of this MPFever (it updated itself, then found a newer one)
                var dl = Path.Combine(root, "dl");
                Directory.CreateDirectory(Path.Combine(dl, "111"));
                Directory.CreateDirectory(Path.Combine(dl, "222"));
                var others = Updater.OldDownloads(dl, Path.Combine(dl, "222") + Path.DirectorySeparatorChar);
                Check(others.Count == 1 && Path.GetFileName(others[0]) == "111", "update: the cleanup leaves this MPFever's download alone");
            }
            catch (Exception e) { Check(false, "update: " + e.Message); }
            finally { try { Directory.Delete(root, true); } catch { } }
            return ok;
        }

        /// <summary>(0.6.3) A game MPFever does not find itself (GOG, a folder of its own): the folder chosen by hand, GOG's
        /// folders, a copy Steam did not install; MPFEVER_GOG=0: as before.</summary>
        static bool RunGameDir()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var root = Path.Combine(Path.GetTempPath(), "mpfever_gamedir_" + Guid.NewGuid().ToString("N"));
            var keptChosen = GameInstall.ChosenDir;
            try
            {
                var game = Path.Combine(root, "GOG Games", "Transport Fever 3");
                Directory.CreateDirectory(game);
                Check(!GameInstall.IsGameDir(game), "game folder: a folder without TransportFever3.exe is not one");
                File.WriteAllText(Path.Combine(game, "TransportFever3.exe"), "");
                Check(GameInstall.IsGameDir(game), "game folder: a folder with TransportFever3.exe is one");
                Check(!GameInstall.NotSteamCopy(@"E:\SteamLibrary\steamapps\common\Transport Fever 3"), "game folder: a Steam library's copy is Steam's");
                Check(!GameInstall.NotSteamCopy(@"C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3\"), "game folder: Steam's own library too");
                Check(GameInstall.NotSteamCopy(game), "game folder: a GOG folder is not Steam's");
                Check(GameInstall.GogDirs().Any(d => d.EndsWith(Path.Combine("GOG Games", "Transport Fever 3"))), "game folder: GOG's usual folder looked at");
                Environment.SetEnvironmentVariable("MPFEVER_GAMEDIR", game);
                Check(GameInstall.FindGameDir() == game, "game folder: MPFEVER_GAMEDIR used");
                Environment.SetEnvironmentVariable("MPFEVER_GAMEDIR", null);
                // the chosen folder after the usual places only: here when the game is found nowhere else, never before Steam's copy
                GameInstall.ChosenDir = game;
                var found = GameInstall.FindGameDir();
                Check(found == game || (found != null && !GameInstall.NotSteamCopy(found)), "game folder: the chosen one, after Steam's (" + found + ")");
                Environment.SetEnvironmentVariable("MPFEVER_GOG", "0");
                Check(GameInstall.FindGameDir() != game, "game folder: MPFEVER_GOG=0, the chosen one not looked at");
                Check(!GameInstall.NotSteamCopy(game), "game folder: MPFEVER_GOG=0, any copy taken for Steam's, as before");
            }
            catch (Exception e) { Check(false, "game folder: " + e.Message); }
            finally
            {
                Environment.SetEnvironmentVariable("MPFEVER_GAMEDIR", null);
                Environment.SetEnvironmentVariable("MPFEVER_GOG", null);
                GameInstall.ChosenDir = keptChosen;
                try { Directory.Delete(root, true); } catch { }
            }
            return ok;
        }

        /// <summary>(0.6.4.1) The diagnostic build: its logs on in every game it starts (MPFEVER_DIAG=1 here, diag.txt for the
        /// players), a test's own values kept, nothing without it.</summary>
        /// <summary>(0.6.9) The game's DLCs compared between the host and a player (AMD and keviK, 2026-11-02: keviK with the
        /// Deluxe and pre-order packs, AMD with none, 7 reloads): the list of this PC, what differs, the warnings of both sides,
        /// nothing when one side is an older MPFever.</summary>
        static bool RunDlcs()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var kept = Environment.GetEnvironmentVariable("MPFEVER_DLCS");
            // (0.7.7: the 0.6.9-0.7.6 warnings, still given with MPFEVER_DLCSESSION=0; RunReport077 checks the session's DLC set)
            var keptSession = Environment.GetEnvironmentVariable("MPFEVER_DLCSESSION");
            Environment.SetEnvironmentVariable("MPFEVER_DLCSESSION", "0");
            try
            {
                const string D = "urbangames_deluxe_upgrade_pack", P = "urbangames_preorder_pack";
                Environment.SetEnvironmentVariable("MPFEVER_DLCS", P + "," + D);
                Check(Mods.InstalledDlcs() == D + "," + P, "dlcs: this PC's list, sorted");
                Environment.SetEnvironmentVariable("MPFEVER_DLCS", " ");
                Check(Mods.InstalledDlcs() == "none", "dlcs: none said so");
                var (a, b) = Mods.DlcDiff("none", D + "," + P);
                Check(a.Count == 0 && b.Count == 2 && b[0] == Mods.DlcName(D), "dlcs: the player has two packs the host has not");
                Check(Mods.DlcWarning("keviK", "none", D + "," + P).Contains("keviK") && Mods.DlcWarning("keviK", "none", D).Contains(Mods.DlcName(D)), "dlcs: the host's warning names the player and the pack");
                Check(Mods.DlcWarning("AMD", D, "none").Contains(Mods.DlcName(D)), "dlcs: a pack of the host's only is said too");
                Check(Mods.DlcWarning("x", D + "," + P, P + "," + D) == "", "dlcs: the same packs: no warning");
                Check(Mods.DlcWarning("x", "", D) == "" && Mods.DlcWarning("x", D, "") == "", "dlcs: an older MPFever (no list): nothing said");
                // (0.7.0) the warning: every player's differences, then the advice once (switch them off in the savegame, or get them;
                // the game can still be started); nothing when the DLCs are alike
                var two = Mods.DlcWarningText(new List<string> { Mods.DlcWarning("keviK", D, "none"), Mods.DlcWarning("AMD", D, P + "," + D) });
                Check(two.Contains("keviK") && two.Contains("AMD") && two.Split(new[] { Mods.DlcAdvice().Trim() }, StringSplitOptions.None).Length == 2, "dlc warning: both players, the advice once");
                Check(Mods.DlcWarningText(new List<string> { "", Mods.DlcWarning("x", D, D) }) == "", "dlc warning: the same DLCs: none");
                // (0.7.0) the session's DLCs are the savegame's when its mods are known (the host switched the pack off in it)
                Check(Mods.SaveDlcs("mpfever_1|MPFever|UserMods;;" + D + "|Deluxe|DLC", true) == D, "session dlcs: the savegame's");
                Check(Mods.SaveDlcs("auto_signals_1|x|UserMods", true) == "none", "session dlcs: a savegame without DLC uses none");
                Check(Mods.SaveDlcs("", false) == null, "session dlcs: unknown mods: the installed ones are said");
                // (0.7.0) the DLC list of the join review: the host's first, what this PC lacks with the Deluxe's store page
                var view = Mods.DlcListView(D, P);
                Check(view.StartsWith(D + "|") && view.Contains("|host|steam://store/3979620") && view.Contains(P + "|") && view.Contains("|mine|"), "dlc list: host's pack to get, this PC's own");
                Check(Mods.DlcListView(D, D).Contains("|both|") && Mods.DlcListView("", D) == "", "dlc list: alike; an older MPFever: none");
            }
            catch (Exception e) { Check(false, "dlcs: " + e.Message); }
            finally { Environment.SetEnvironmentVariable("MPFEVER_DLCS", kept); Environment.SetEnvironmentVariable("MPFEVER_DLCSESSION", keptSession); }
            return ok;
        }

        /// <summary>(0.7.0) The dedicated server's settings written by its window (ServerConfig.Save) and read back by the server: every
        /// value kept, the comments there, the new keys (bankruptcy months, computer companies) read and checked, the game options'
        /// catalog of the window loaded.</summary>
        static bool RunServerConfig()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var file = Path.Combine(Path.GetTempPath(), "mpfever_selftest_server.properties");
            try
            {
                if (File.Exists(file)) File.Delete(file);
                var c = new ServerConfig { Name = "Serveur de test", World = "Test Monde", Port = 28111, Password = "pw", MaxPlayers = 5, CompanyMode = "separate", Owner = "Knight",
                    StartMoney = 5000000, ShareRules = false, GameOptions = "stats=1;goal=1;goal.target=x", StartSpeed = 2, PauseWhenEmpty = false, PlayerSpeedControl = false,
                    AutosaveMinutes = 15, Backups = 3, RestartOnCrash = false, WatchdogSeconds = 240, Motd = "Bonjour\nà tous", Public = false, PublicAddress = "mp.example.org:28111",
                    BankruptMonths = 6, AiCompanies = "2:11:3:5000000,1:12:1" };
                c.AiCompanies = ServerConfig.AiCanon(c.AiCompanies);
                c.Save(file);
                var problems = new List<string>();
                var r = ServerConfig.Load(file, problems, out bool created);
                Check(!created && problems.Count == 0, "server config: written and read back without a problem");
                Check(r.Name == c.Name && r.World == c.World && r.Port == 28111 && r.Password == "pw" && r.MaxPlayers == 5 && r.CompanyMode == "separate" && r.Owner == "Knight", "server config: the server's values");
                Check(r.StartMoney == 5000000 && !r.ShareRules && r.BankruptMonths == 6 && r.AiCompanies == "1:12:1,2:11:3:5000000", "server config: the companies' rules and the computer companies");
                Check(r.GameOptions == "goal=1;goal.target=x;stats=1" && r.StartSpeed == 2 && !r.PauseWhenEmpty && !r.PlayerSpeedControl, "server config: the game options and the speed");
                Check(r.AutosaveMinutes == 15 && r.Backups == 3 && !r.RestartOnCrash && r.WatchdogSeconds == 240 && r.Motd == "Bonjour à tous" && !r.Public && r.PublicAddress == "mp.example.org:28111", "server config: the rest, a line break of the motd made a space");
                var text = File.ReadAllText(file);
                Check(text.Contains("# The world: the name of a savegame") && text.Contains("bankruptcy-months=6") && text.Contains("# separate only: the computer companies"), "server config: the comments are in the file");
                Check(ServerConfig.AiCanon("1:12:2,1:11:2") == null && ServerConfig.AiCanon("1:12:2,2:12:2") == null && ServerConfig.AiCanon("9:1:2") == null && ServerConfig.AiCanon("1:1:4") == null,
                    "server config: a computer company twice, a colour twice, a number or a level out of range: refused");
                Check(ServerConfig.AiCanon("") == "" && ServerConfig.AiCanon("3:5:2:-1") == "3:5:2", "server config: none; the players' money said by no amount");
                Check(new ServerConfig().Text() == ServerConfig.Template() && ServerConfig.Template().Contains("world=\r\n"), "server config: the template is the defaults' text");
                var cat = GameOptsCatalog.All;
                Check(cat.Count >= 10 && cat.Any(o => o.Id == "goal" && o.Params.Any(p => p.Id == "target" && p.Values.Count > 1)), "server window: the game options' catalog");
                Check(GameOptsCatalog.ForServer("shared").All(o => o.Module != "public" && o.Modes != "separate") && GameOptsCatalog.ForServer("separate").Any(o => o.Id == "goal"), "server window: the options of a mode, without the public games'");
            }
            catch (Exception e) { Check(false, "server config: " + e.Message); }
            finally { try { File.Delete(file); } catch { } }
            return ok;
        }

        /// <summary>(0.7.0) A savegame's mods read from the start of its file (a dedicated server's world, the server window's list):
        /// the list as the game writes it found after other bytes, its DLC, a mod.io number, MPFever's own left out of the menu's list;
        /// only the head decompressed; nothing found in other data.</summary>
        static bool RunSaveMods()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            try
            {
                var ms = new MemoryStream();
                var w = new BinaryWriter(ms);
                w.Write(Encoding.ASCII.GetBytes("tf**")); w.Write(605); w.Write(new byte[81]);
                void Str(string s) { var b = Encoding.UTF8.GetBytes(s); w.Write(b.Length); w.Write(b); }
                w.Write(3);
                Str("urbangames_deluxe_upgrade_pack"); Str("DLC"); Str("DLC,urbangames_deluxe_upgrade_pack"); Str("Mise à niveau Deluxe"); Str(""); w.Write(1);
                Str("timetables_1"); Str("mod.io"); Str("6037864"); Str("Timetables"); Str("https://mod.io"); w.Write(0);
                Str("mpfever_1"); Str("UserMods"); Str("UserMods,mpfever_1"); Str("MPFever Multiplayer"); Str(""); w.Write(0);
                w.Write(new byte[3 << 20]);   // (the world after it: not decompressed)
                var file = Path.Combine(Path.GetTempPath(), "mpfever_selftest_mods.sav");
                Zstd.WriteRawFrame(file, ms.ToArray());
                var head = Zstd.DecompressHead(file, 1 << 20);
                Check(head.Length == 1 << 20, "save mods: only the head decompressed");
                var mods = SaveInfo.Mods(file);
                Check(mods != null && mods.Count == 3 && mods[0].Source == "DLC" && mods[0].Name == "Mise à niveau Deluxe" && mods[1].Hub == "6037864" && mods[2].Hub == "", "save mods: the list, its DLC and a mod.io number");
                var list = SaveInfo.MenuList(mods);
                Check(list.StartsWith("urbangames_deluxe_upgrade_pack|Mise à niveau Deluxe|DLC|;;timetables_1|Timetables|mod.io|6037864") && !list.Contains("mpfever_1"), "save mods: the menu's list without MPFever");
                Check(Mods.SaveDlcs(Mods.Describe(list), true) == "urbangames_deluxe_upgrade_pack", "save mods: the world's DLCs");
                Check(SaveInfo.ModsOf(new byte[70000]) == null, "save mods: none in other data");
                File.Delete(file);
            }
            catch (Exception e) { Check(false, "save mods: " + e.Message); }
            return ok;
        }

        /// <summary>(0.6.12, #125) The company mode a player's problem report names: the host's, from its "session" message, then
        /// its lobby; the host's own report names its choice; MPFEVER_REPORTMODE=0 as before.</summary>
        static bool RunReportMode()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var kept = Environment.GetEnvironmentVariable("MPFEVER_REPORTMODE");
            try
            {
                Environment.SetEnvironmentVariable("MPFEVER_REPORTMODE", null);
                Check(MainForm.SessionMode("{[\"started\"]=true,[\"speed\"]=1,[\"cmode\"]=\"separate\",[\"cstart\"]=2000000}") == "separate", "report mode: read from the host's session message");
                Check(MainForm.SessionMode("{[\"started\"]=false,[\"speed\"]=0}") == "" && MainForm.SessionMode("garbage{") == "", "report mode: none in MPFever's own stop message, nor in garbage");
                Check(MainForm.ModeForReport(false, "shared", "separate", "") == "separate", "report mode: a player names the host's separate companies (#125: it said shared)");
                Check(MainForm.ModeForReport(false, "shared", "", "separate") == "separate", "report mode: else its lobby's");
                Check(MainForm.ModeForReport(false, "shared", "", "") == "shared", "report mode: nothing known: as before");
                Check(MainForm.ModeForReport(true, "separate", "shared", "shared") == "separate", "report mode: the host names its own choice");
                Environment.SetEnvironmentVariable("MPFEVER_REPORTMODE", "0");
                Check(MainForm.ModeForReport(false, "shared", "separate", "separate") == "shared", "report mode: MPFEVER_REPORTMODE=0 as before");
            }
            catch (Exception e) { Check(false, "report mode: " + e.Message); }
            finally { Environment.SetEnvironmentVariable("MPFEVER_REPORTMODE", kept); }
            return ok;
        }

        /// <summary>(0.6.12) The 1 ms timer: asked and given back, measured on a Thread.Sleep(5); MPFEVER_TIMER1MS=0 asks nothing.</summary>
        static bool RunFineTimer()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var kept = Environment.GetEnvironmentVariable("MPFEVER_TIMER1MS");
            try
            {
                Environment.SetEnvironmentVariable("MPFEVER_TIMER1MS", null);
                bool on = FineTimer.Begin();
                Check(on, "timer: 1 ms asked");
                var sw = System.Diagnostics.Stopwatch.StartNew();
                for (int i = 0; i < 20; i++) System.Threading.Thread.Sleep(5);
                double avg = sw.Elapsed.TotalMilliseconds / 20;
                if (on) FineTimer.End();
                Check(avg < 10, "timer: Thread.Sleep(5) lasts " + avg.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " ms (15.6 with the system's timer)");
                Environment.SetEnvironmentVariable("MPFEVER_TIMER1MS", "0");
                Check(!FineTimer.Begin(), "timer: MPFEVER_TIMER1MS=0 asks nothing");
            }
            catch (Exception e) { Check(false, "timer: " + e.Message); }
            finally { Environment.SetEnvironmentVariable("MPFEVER_TIMER1MS", kept); }
            return ok;
        }

        static bool RunDiag()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var kept = Environment.GetEnvironmentVariable("MPFEVER_DIAG");
            try
            {
                bool file = File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "diag.txt"));
                Environment.SetEnvironmentVariable("MPFEVER_DIAG", null);
                var env = new System.Collections.Specialized.StringDictionary();
                GameInstall.DiagEnv(env);
                Check(file || env.Count == 0, "diagnostic: off without diag.txt, no variable set");
                Environment.SetEnvironmentVariable("MPFEVER_DIAG", "1");
                Check(GameInstall.DiagOn(), "diagnostic: MPFEVER_DIAG=1 turns it on");
                env = new System.Collections.Specialized.StringDictionary();
                env["MPFEVER_SDUMP"] = "0";
                GameInstall.DiagEnv(env);
                Check(env["MPFEVER_FREEQLOG"] == "1" && env["MPFEVER_STEPLOG"] == "1", "diagnostic: the free-id log and the detailed logs on");
                Check(env["MPFEVER_SDUMP"] == "0", "diagnostic: a test's own value kept");
                Check(Options.ModFile().Contains("MPFEVER_STEPLOG=1"), "diagnostic: the mod's settings ask for the detailed logs");
            }
            catch (Exception e) { Check(false, "diagnostic: " + e.Message); }
            finally { Environment.SetEnvironmentVariable("MPFEVER_DIAG", kept); }
            return ok;
        }

        /// <summary>(0.6.7) The session of 2026-11-01: a local mod (StagingArea) is the host's to send, found in staging_area; Real
        /// Track Cant judged incompatible, the game's No costs made compatible.</summary>
        static bool RunSession067()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            Check(Mods.LocalSource("StagingArea") && Mods.LocalSource("Local") && Mods.LocalSource("user"), "mods: StagingArea, Local, User are local origins");
            Check(!Mods.LocalSource("Workshop") && !Mods.LocalSource("ModIo") && !Mods.LocalSource("BuiltIn") && !Mods.LocalSource(""), "mods: Workshop, mod.io, the game's are not");
            // (0.7.0: no longer incompatible, its automatic builds go from one game only; to confirm in a session)
            Check(Mods.Judge("devers_1", Mods.Sim).Level == "caution", "mods: Real Track Cant (devers_1) to confirm (0.7.0)");
            // (0.7.0: the script mods read one by one)
            Check(Mods.Judge("parallel_tracks_1", Mods.Sim).Level == "ok", "mods: Parallel Tracks read, works");
            Check(Mods.Judge("line_role_renamer", Mods.Sim).Level == "fixed", "mods: Line Roles made compatible (0.7.0)");
            Check(Mods.Judge("stombor_zoning", Mods.Sim).Level == "caution", "mods: Town Zoning still to check");
            Check(Mods.Judge("some_unknown_mod", Mods.Sim).Level == "caution" && Mods.Judge("some_unknown_mod", Mods.Assets).Level == "ok", "mods: an unknown mod judged by its files, as before");
            Check(Mods.Judge("urbangames_no_costs_1", Mods.Load).Level == "fixed", "mods: the game's No costs made compatible");
            var roots = Mods.LocalRoots(@"C:\x\local");
            Check(roots.Contains(Path.Combine(@"C:\x\local", "mods")) && roots.Contains(Path.Combine(@"C:\x\local", "staging_area")), "mods: local\\mods and local\\staging_area searched");
            return ok;
        }

        /// <summary>(0.6.5, #111, #109) MPFever.exe copied alone: InstallNative says "missing" (then installs when the file is there,
        /// nothing when it is the same); a part a game does not measure ("off", "none", "absent") is no difference; a report's
        /// zip never takes the name of one that exists.</summary>
        static bool RunIssue111()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var tmp = Path.Combine(Path.GetTempPath(), "mpfever-selftest-111-" + Guid.NewGuid().ToString("N"));
            try
            {
                var game = Path.Combine(tmp, "game");
                var app = Path.Combine(tmp, "app");
                Directory.CreateDirectory(game);
                Directory.CreateDirectory(app);
                Check(GameInstall.InstallNative(game, app) == "missing", "#111: no winhttp.dll next to MPFever.exe: \"missing\"");
                Check(!File.Exists(Path.Combine(game, "winhttp.dll")), "#111: nothing put in the game folder then");
                File.WriteAllText(Path.Combine(app, "winhttp.dll"), "mpfever_native test 1");
                Check(GameInstall.InstallNative(game, app) == null && File.ReadAllText(Path.Combine(game, "winhttp.dll")) == "mpfever_native test 1", "#111: the file there: installed");
                Check(GameInstall.InstallNative(game, app) == null, "#111: the same file: nothing to do");
                File.WriteAllText(Path.Combine(game, "winhttp.dll"), "some other dll");
                Check(GameInstall.InstallNative(game, app) == "other", "#111: another mod's dll in the game folder: \"other\", left alone");
                Check(MainForm.NotMeasured("off") && MainForm.NotMeasured("none") && MainForm.NotMeasured("absent"), "#111: off/none/absent are no measure");
                Check(!MainForm.NotMeasured("459/1535190763") && !MainForm.NotMeasured("0") && !MainForm.NotMeasured(""), "#111: a value is one");
                var zip = Path.Combine(tmp, "MPFever-report-20261031-164508.zip");
                Check(Reporter.FreeName(zip) == zip, "#109: a free name is kept");
                File.WriteAllText(zip, "x");
                Check(Reporter.FreeName(zip) == Path.Combine(tmp, "MPFever-report-20261031-164508-2.zip"), "#109: a taken name gets -2");
                File.WriteAllText(Path.Combine(tmp, "MPFever-report-20261031-164508-2.zip"), "x");
                Check(Reporter.FreeName(zip) == Path.Combine(tmp, "MPFever-report-20261031-164508-3.zip"), "#109: then -3");
            }
            catch (Exception e) { Check(false, "#111: " + e.Message); }
            finally { try { Directory.Delete(tmp, true); } catch { } }
            return ok;
        }

        /// <summary>(0.6.4) Windows' Smart App Control: told only when it is on (1), not off (0), in evaluation (2) or unknown
        /// (-1); MPFEVER_SACWARN=0: never, as before. The state read from the registry here is whatever this PC has.</summary>
        static bool RunSmartAppControl()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            try
            {
                foreach (var c in new[] { (1, true), (0, false), (2, false), (-1, false) })
                {
                    Environment.SetEnvironmentVariable("MPFEVER_SACSTATE", c.Item1.ToString());
                    Check(GameInstall.SmartAppControlState() == c.Item1 && GameInstall.SmartAppControlBlocks() == c.Item2,
                          "smart app control: state " + c.Item1 + (c.Item2 ? " told" : " not told"));
                }
                Environment.SetEnvironmentVariable("MPFEVER_SACSTATE", "1");
                Environment.SetEnvironmentVariable("MPFEVER_SACWARN", "0");
                Check(!GameInstall.SmartAppControlBlocks(), "smart app control: MPFEVER_SACWARN=0, never told");
                Environment.SetEnvironmentVariable("MPFEVER_SACSTATE", null);
                Environment.SetEnvironmentVariable("MPFEVER_SACWARN", null);
                var here = GameInstall.SmartAppControlState();
                Check(here >= -1 && here <= 2, "smart app control: this PC's state read (" + here + ")");
            }
            catch (Exception e) { Check(false, "smart app control: " + e.Message); }
            finally
            {
                Environment.SetEnvironmentVariable("MPFEVER_SACSTATE", null);
                Environment.SetEnvironmentVariable("MPFEVER_SACWARN", null);
            }
            return ok;
        }

        /// <summary>Problem reports: what tells who and where the player is taken out of the text (see Redact).</summary>
        static bool RunRedact()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            string user = Environment.UserName;
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string a = Redact.Text("save " + home + "\\AppData\\Local\\Temp\\mpfever\\x.txt and " + home.Replace('\\', '/') + "/y");
            Check(!a.Contains(Path.GetFileName(home)) && a.Contains("\\Users\\user\\AppData") && a.Contains("/Users/user/y"), "report: the Windows account in paths (" + a + ")");
            string lua = Redact.Text("C:\\\\Users\\\\" + user + "\\\\AppData");
            Check(!lua.Contains(user) || user.Length < 2, "report: the Windows account in a Lua string (" + lua + ")");
            string b = Redact.Text("Knight-HD joined; E:/Steam/userdata/55376607/3493540/local/save and sid 76561198015642335 again 76561198015642335");
            Check(b.Contains("Knight-HD joined") && !b.Contains("55376607") && !b.Contains("76561198015642335") && b.Contains("userdata/account-"), "report: Steam account numbers (" + b + ")");
            int i1 = b.IndexOf("steam-", StringComparison.Ordinal), i2 = b.LastIndexOf("steam-", StringComparison.Ordinal);
            Check(i1 >= 0 && i2 > i1 && b.Substring(i1, 12) == b.Substring(i2, 12), "report: one Steam id gives one code");
            string c = Redact.Text("public 89.88.206.99:28090, lan 192.168.1.20, 10.0.0.2, 127.0.0.1:28090, cgnat 100.80.1.2, Windows 10.0.26200.6584, v 0.4.6, 2a01:cb00:1234:5600::1 fe80::1");
            Check(!c.Contains("89.88.206.99") && c.Contains(":28090") && c.Contains("192.168.1.20") && c.Contains("10.0.0.2") && c.Contains("127.0.0.1")
                && c.Contains("100.80.1.2") && c.Contains("10.0.26200.6584") && c.Contains("0.4.6") && !c.Contains("2a01:cb00") && c.Contains("fe80::1"), "report: public addresses only (" + c + ")");
            string d = Redact.Text("mail me at someone.name@example.org please, time 21:34:08");
            Check(!d.Contains("example.org") && d.Contains("21:34:08"), "report: e-mail addresses (" + d + ")");

            // the savegame's differences (0.5.0): a raw zstd frame reads back, and a changed copy is rebuilt from its base
            try
            {
                var rnd = new Random(7);
                var baseData = new byte[3_000_000];
                for (int k = 0; k < baseData.Length; k++) baseData[k] = (byte)(k % 251 < 200 ? (k / 977) : rnd.Next(256));
                var newData = new List<byte>(baseData);
                newData.InsertRange(1_000_000, new byte[] { 1, 2, 3, 4, 5, 6, 7 });
                for (int k = 2_000_000; k < 2_000_400; k++) newData[k] ^= 0x5a;
                var nd = newData.ToArray();
                string tmp = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N") + ".sav");
                Zstd.WriteRawFrame(tmp, nd);
                var back = Zstd.DecompressFile(tmp);
                File.Delete(tmp);
                var delta = SaveDelta.Make(baseData, nd);
                var rebuilt = SaveDelta.Apply(baseData, delta);
                Check(back.SequenceEqual(nd) && rebuilt.SequenceEqual(nd) && delta.Length < nd.Length / 10,
                    "savegame differences: raw frame read back, rebuilt from its base (" + delta.Length + " bytes for " + nd.Length + ")");
                bool refused = false;
                try { SaveDelta.Apply(nd, delta); } catch (InvalidDataException) { refused = true; }
                Check(refused, "savegame differences: refused on another base");
            }
            catch (Exception e) { Check(false, "savegame differences: " + e.Message); }

            // the game's rules kept in a savegame (0.5.14): the text "mpfrules:..." of mpfever_eco.lua's co_rules, a Lua string
            // of the game's state (its length right before it), read back for the lobby opened on that savegame
            try
            {
                byte[] Lua(string s)
                {
                    var t = Encoding.ASCII.GetBytes(s);
                    return BitConverter.GetBytes(t.Length).Concat(t).ToArray();
                }
                var junk = Enumerable.Range(0, 5000).Select(k => (byte)(k * 7 % 256)).ToArray();
                var save = junk.Concat(Lua("mpfrules:bankrupt=6;share=0;start=5000000;ai=1:7:3:1000000,2:3:1:-1;")).Concat(junk).ToArray();
                string tmp = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N") + ".sav");
                Zstd.WriteRawFrame(tmp, save);
                var r = SaveInfo.Rules(tmp);
                Zstd.WriteRawFrame(tmp, junk);
                var none = SaveInfo.Rules(tmp);
                File.Delete(tmp);
                Check(r != null && r.Count == 4 && r["bankrupt"] == "6" && r["share"] == "0" && r["start"] == "5000000" && r["ai"] == "1:7:3:1000000,2:3:1:-1",
                    "savegame rules: read back (" + (r == null ? "none" : string.Join(";", r.Select(kv => kv.Key + "=" + kv.Value))) + ")");
                Check(none == null, "savegame rules: none in a savegame without them");
            }
            catch (Exception e) { Check(false, "savegame rules: " + e.Message); }
            return ok;
        }

        /// <summary>Port mapping: a router's description read, and the SOAP requests a fake router on this PC receives.</summary>
        static bool RunPortMap()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var desc = "<root><URLBase>http://192.168.1.1:5000/</URLBase><device><serviceList>"
                + "<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/l3f</controlURL></service>"
                + "<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL></service>"
                + "</serviceList></device></root>";
            var igd = PortMap.FromDescription("http://192.168.1.1:5000/rootDesc.xml", desc);
            Check(igd != null && igd.ControlUrl == "http://192.168.1.1:5000/ctl/IPConn" && igd.ServiceType.EndsWith("WANIPConnection:1"), "upnp: WAN connection service of a description");
            Check(PortMap.ProblemOf("100.72.3.4") != null && PortMap.ProblemOf("192.168.0.2") != null && PortMap.ProblemOf("82.64.10.20") == null, "upnp: CGNAT and private router addresses recognised");

            // a fake router: answers every SOAP request, keeps what it was asked
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var asked = new List<string>();
            var server = new Thread(() =>
            {
                try
                {
                    for (int i = 0; i < 3; i++)
                    {
                        using (var c = listener.AcceptTcpClient())
                        using (var st = c.GetStream())
                        {
                            var buf = new byte[8192]; int n = 0; string text = "";
                            st.ReadTimeout = 3000;
                            // (headers, then the body announced by Content-Length)
                            while (true)
                            {
                                int k = st.Read(buf, n, buf.Length - n); if (k <= 0) break; n += k;
                                text = Encoding.UTF8.GetString(buf, 0, n);
                                int he = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                                if (he < 0) continue;
                                var cl = System.Text.RegularExpressions.Regex.Match(text, @"Content-Length:\s*(\d+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                                if (!cl.Success || n - he - 4 >= int.Parse(cl.Groups[1].Value)) break;
                            }
                            lock (asked) asked.Add(text);
                            var body = text.Contains("GetExternalIPAddress") ? "<NewExternalIPAddress>100.80.1.2</NewExternalIPAddress>" : "<ok/>";
                            var resp = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body;
                            var rb = Encoding.UTF8.GetBytes(resp);
                            st.Write(rb, 0, rb.Length);
                        }
                    }
                }
                catch { }
            }) { IsBackground = true };
            server.Start();
            var fake = new PortMap.Igd { Host = "127.0.0.1", ControlUrl = "http://127.0.0.1:" + port + "/ctl/IPConn", ServiceType = "urn:schemas-upnp-org:service:WANIPConnection:1" };
            string ext = null;
            try
            {
                ext = fake.ExternalAddress();
                fake.AddMapping(28190, "192.168.1.20");
                fake.DeleteMapping(28190);
            }
            catch (Exception e) { Check(false, "upnp: SOAP " + e.Message); }
            server.Join(5000);
            listener.Stop();
            string all; lock (asked) all = string.Join("\n----\n", asked);
            Check(ext == "100.80.1.2", "upnp: the router's public address read (" + ext + ")");
            Check(all.Contains("SOAPAction: \"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"") && all.Contains("<NewExternalPort>28190</NewExternalPort>")
                && all.Contains("<NewInternalClient>192.168.1.20</NewInternalClient>") && all.Contains("<NewProtocol>TCP</NewProtocol>"), "upnp: AddPortMapping sent as a router expects it");
            Check(all.Contains("#DeletePortMapping\""), "upnp: the mapping removed");

            // (0.6.7) every WAN service of a description, in its order
            var two = "<root><device><serviceList>"
                + "<service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/ppp</controlURL></service>"
                + "<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ip</controlURL></service>"
                + "</serviceList></device></root>";
            var both = PortMap.FromDescriptionAll("http://192.168.1.1:49000/igd.xml", two);
            Check(both.Count == 2 && both[0].ControlUrl.EndsWith("/ppp") && both[1].ControlUrl.EndsWith("/ip"), "upnp: every WAN service of a description, in order");
            // (0.6.7) a router's 718 (the port mapped already): the mapping removed and asked again; its code read from the fault
            var l2 = new TcpListener(IPAddress.Loopback, 0);
            l2.Start();
            int port2 = ((IPEndPoint)l2.LocalEndpoint).Port;
            var asked2 = new List<string>();
            var server2 = new Thread(() =>
            {
                try
                {
                    for (int i = 0; i < 3; i++)
                    {
                        using (var c = l2.AcceptTcpClient())
                        using (var st = c.GetStream())
                        {
                            var buf = new byte[8192]; int n = 0; string text = "";
                            st.ReadTimeout = 3000;
                            while (true)
                            {
                                int k = st.Read(buf, n, buf.Length - n); if (k <= 0) break; n += k;
                                text = Encoding.UTF8.GetString(buf, 0, n);
                                int he = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                                if (he < 0) continue;
                                var cl = System.Text.RegularExpressions.Regex.Match(text, @"Content-Length:\s*(\d+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                                if (!cl.Success || n - he - 4 >= int.Parse(cl.Groups[1].Value)) break;
                            }
                            lock (asked2) asked2.Add(text);
                            bool fault = i == 0;
                            var body = fault ? "<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>718</errorCode><errorDescription>ConflictInMappingEntry</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>" : "<ok/>";
                            var resp = (fault ? "HTTP/1.1 500 Internal Server Error" : "HTTP/1.1 200 OK") + "\r\nContent-Type: text/xml\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body;
                            var rb = Encoding.UTF8.GetBytes(resp);
                            st.Write(rb, 0, rb.Length);
                        }
                    }
                }
                catch { }
            }) { IsBackground = true };
            server2.Start();
            var fake2 = new PortMap.Igd { Host = "127.0.0.1", ControlUrl = "http://127.0.0.1:" + port2 + "/ctl/IPConn", ServiceType = "urn:schemas-upnp-org:service:WANIPConnection:1" };
            int lease2 = -1;
            try { lease2 = fake2.AddMapping(28190, "192.168.1.20"); } catch (Exception e) { Check(false, "upnp 718: " + e.Message); }
            server2.Join(5000);
            l2.Stop();
            string all2; lock (asked2) all2 = string.Join("\n----\n", asked2);
            Check(lease2 == 0 && asked2.Count == 3 && asked2[1].Contains("#DeletePortMapping\"") && asked2[2].Contains("#AddPortMapping\""), "upnp: 718 read from the fault, the old mapping removed, asked again (" + asked2.Count + " requests)");

            // (0.6.7) PCP's MAP request and answer (RFC 6887)
            var nonce = new byte[12]; for (int i = 0; i < 12; i++) nonce[i] = (byte)(i + 1);
            var q = PortMap.Pcp.Request(IPAddress.Parse("192.168.1.20"), 28090, 7200, nonce);
            Check(q.Length == 60 && q[0] == 2 && q[1] == 1 && q[36] == 6 && ((q[40] << 8) | q[41]) == 28090 && q[20] == 192 && q[23] == 20 && q[18] == 0xff && q[24] == 1, "pcp: MAP request (version, opcode, TCP, port, client ::ffff:a.b.c.d, nonce)");
            var a = (byte[])q.Clone(); a[1] = 0x81; a[3] = 0; a[56] = 82; a[57] = 64; a[58] = 10; a[59] = 20;
            Check(PortMap.Pcp.Parse(a, nonce, out int ep, out var ea, out int life, out _) && ep == 28090 && ea.ToString() == "82.64.10.20" && life == 7200, "pcp: MAP answer read (port, public address, lifetime)");
            a[3] = 2;
            Check(!PortMap.Pcp.Parse(a, nonce, out _, out _, out _, out var w2) && w2.Contains("2"), "pcp: a refusal read with its code");
            var other = (byte[])nonce.Clone(); other[0] = 99; a[3] = 0;
            Check(!PortMap.Pcp.Parse(a, other, out _, out _, out _, out _), "pcp: an answer to another request ignored");
            return ok;
        }

        /// <summary>(0.6) The game options' string (GameOpts): its canon, the host's requests, the server's setting and the text a
        /// savegame keeps (SaveInfo.Opts).</summary>
        static bool RunGameOpts()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            Check(GameOpts.Canon("b=1;a.x=2;a=1;c=0;c.y=3;BAD=1;d=1;d.z=A B") == "a=1;a.x=2;b=1;d=1", "game options: canon (sorted, the options on and their parameters, syntax)");
            Check(GameOpts.Canon("") == "" && GameOpts.Canon(new string('a', GameOpts.MaxText + 1) + "=1") == "", "game options: empty, too long");
            Check(GameOpts.Apply("", "goal=1", out _) == "goal=1", "game options: an option on");
            Check(GameOpts.Apply("goal=1", "goal.years=30", out _) == "goal=1;goal.years=30", "game options: a parameter");
            Check(GameOpts.Apply("goal=1;goal.years=30;stock=1", "goal=0", out _) == "stock=1", "game options: off forgets its parameters");
            Check(GameOpts.Apply("", "goal.years=30", out var e1) == null && e1 == "option off", "game options: no parameter for an option off");
            Check(GameOpts.Apply("", "Goal=1", out var e2) == null && e2 == "syntax" && GameOpts.Apply("", "goal=2", out var e3) == null && e3 == "value"
                  && GameOpts.Apply("", "goal=1;x=1", out _) == null && GameOpts.Apply("", "goal.y.z=1", out _) == null, "game options: requests of another syntax refused");
            var dir = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(dir);
            try
            {
                // the server's line
                var path = Path.Combine(dir, ServerConfig.FileName);
                var problems = new List<string>();
                var c = ServerConfig.Load(path, problems, out _);
                Check(c.GameOptions == "" && problems.Count == 0, "game options: the server's template has none");
                File.WriteAllText(path, "game-options=stock=1;goal.years=30;goal=1\n", new UTF8Encoding(false));
                c = ServerConfig.Load(path, problems, out _);
                Check(c.GameOptions == "goal=1;goal.years=30;stock=1", "game options: the server's line (" + c.GameOptions + ")");
                // a savegame's text: a Lua string of the game's state (type 3, its length, its bytes)
                byte[] Save(string text)
                {
                    var b = new List<byte>(Encoding.ASCII.GetBytes("....some state...."));
                    if (text != null)
                    {
                        b.AddRange(BitConverter.GetBytes(3));
                        b.AddRange(BitConverter.GetBytes(text.Length));
                        b.AddRange(Encoding.ASCII.GetBytes(text));
                    }
                    b.AddRange(Encoding.ASCII.GetBytes("....more state...."));
                    return b.ToArray();
                }
                string Read(string text)
                {
                    var f = Path.Combine(dir, "save.sav");
                    Zstd.WriteRawFrame(f, Save(text));
                    return SaveInfo.Opts(f);
                }
                Check(Read("mpfopts:goal=1;goal.years=30;") == "goal=1;goal.years=30", "game options: read back from a savegame");
                Check(Read("mpfopts:;") == "" && Read(null) == null, "game options: a savegame with them all off, one without");
            }
            catch (Exception e) { Check(false, "game options: " + e.Message); }
            finally { try { Directory.Delete(dir, true); } catch { } }
            return ok;
        }

        /// <summary>(0.6, review of 2026-10-30) The game options kept in memory (a settings file that cannot be read never turns them
        /// off, nor loses the other settings), the lobby's one reading of its savegame (computer companies, rules and options at once;
        /// the host's choice made meanwhile wins), the public games' rules with MPFEVER_ANYVERSION=1, and the server list read once a
        /// cycle from an older list (404 on /api/games) and not twice when it does not answer.</summary>
        static bool RunOptsKept()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var dir = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(dir);
            var keepFile = MainForm.SettingsFileForTest;
            try
            {
                // the options in memory
                var file = Path.Combine(dir, "mpfever_settings.txt");
                File.WriteAllText(file, "name=me\ngameopts=stock=1;goal=1\n", new UTF8Encoding(false));
                MainForm.SettingsFileForTest = file;
                MainForm.ForgetGameOptions();
                Check(MainForm.KeptGameOptions() == "goal=1;stock=1", "options kept: read from the settings the first time");
                using (new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                {
                    Check(MainForm.KeptGameOptions() == "goal=1;stock=1", "options kept: the file locked (written by another request), still on");
                    MainForm.SaveSetting("bankrupt", "6");
                }
                var after = File.ReadAllText(file);
                Check(after.Contains("name=me") && after.Contains("gameopts=") && !after.Contains("bankrupt"), "settings: a file that could not be read is not written again with one setting only");
                MainForm.SaveSetting("gameopts", "goal=1");
                Check(MainForm.KeptGameOptions() == "goal=1" && File.ReadAllText(file).Contains("gameopts=goal=1"), "options kept: a choice saved, in memory and in the file");
                MainForm.ForgetGameOptions();
                using (new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    Check(MainForm.KeptGameOptions() == "", "options kept: unreadable at the first reading, none (not kept)");
                Check(MainForm.KeptGameOptions() == "goal=1", "options kept: read again once the file can be read");

                // the lobby's savegame: one reading for its companies, its rules and its options
                byte[] Lua(string s)
                {
                    var t = Encoding.ASCII.GetBytes(s);
                    return BitConverter.GetBytes(3).Concat(BitConverter.GetBytes(t.Length)).Concat(t).ToArray();
                }
                var junk = Enumerable.Range(0, 3000).Select(k => (byte)(k * 7 % 256)).ToArray();
                var save = Path.Combine(dir, "save.sav");
                Zstd.WriteRawFrame(save, junk.Concat(Lua("mpfrules:bankrupt=6;share=0;")).Concat(junk).Concat(Lua("mpfopts:goal=1;")).Concat(junk).ToArray());
                var mk = SaveInfo.Read(save, true);
                Check(mk != null && mk.Ai != null && mk.Ai.Count == 0 && mk.Rules != null && mk.Rules["bankrupt"] == "6" && mk.Opts == "goal=1",
                    "savegame: its companies, rules and options from one decompression");
                Check(SaveInfo.Read(save, false).Ai == null && SaveInfo.Read(Path.Combine(dir, "none.sav"), true) == null, "savegame: no companies unless asked; none when unreadable");
                Check(MainForm.SaveOptsToTake("goal=1", "", "") == "goal=1" && MainForm.SaveOptsToTake(null, "", "") == null
                      && MainForm.SaveOptsToTake("goal=1", "goal=1", "goal=1") == null, "savegame options: taken, none, already the session's");
                Check(MainForm.SaveOptsToTake("goal=1", "stock=1", "") == null, "savegame options: the host chose others since the lobby opened: its choice kept");

                // the public games' rules with MPFEVER_ANYVERSION=1
                int versionAsked = 0;
                var admit = MainForm.HostAdmit(true, m => { versionAsked++; return "old"; }, p => p.Name == "banned" ? "banned" : null);
                Check(admit(new Peer { Name = "banned" }, Msg.Make("join", "x")) == "banned" && admit(new Peer { Name = "bob" }, Msg.Make("join", "x")) == null && versionAsked == 0,
                    "MPFEVER_ANYVERSION=1: no version check, the ban list still");
                var admit2 = MainForm.HostAdmit(false, m => "old", p => null);
                Check(admit2(new Peer { Name = "bob" }, Msg.Make("join", "x")) == "old", "without it: the version first");

                // the server list: an older list (404 on /api/games), a list that does not answer
                var listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Start();
                int lport = ((IPEndPoint)listener.LocalEndpoint).Port;
                var asked = new List<string>();
                var server = new Thread(() =>
                {
                    try
                    {
                        while (true)
                        {
                            using (var c = listener.AcceptTcpClient())
                            {
                                var s = c.GetStream();
                                var buf = new byte[4096];
                                var head = new StringBuilder();
                                while (!head.ToString().Contains("\r\n\r\n")) { int n = s.Read(buf, 0, buf.Length); if (n <= 0) break; head.Append(Encoding.ASCII.GetString(buf, 0, n)); }
                                var path = head.ToString().Split(' ').Skip(1).FirstOrDefault() ?? "";
                                lock (asked) asked.Add(path);
                                var body = path == "/api/servers" ? "{\"servers\":[{\"name\":\"S\"}]}" : "";
                                var status = path == "/api/servers" ? "200 OK" : "404 Not Found";
                                var bytes = Encoding.UTF8.GetBytes(body);
                                var resp = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nContent-Type: application/json\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n");
                                s.Write(resp, 0, resp.Length);
                                s.Write(bytes, 0, bytes.Length);
                            }
                        }
                    }
                    catch { }
                }) { IsBackground = true };
                server.Start();
                var until = DateTime.MinValue;
                var url = "http://127.0.0.1:" + lport;
                var l1 = MainForm.FetchList(url, true, ref until);
                var l2 = MainForm.FetchList(url, true, ref until);
                listener.Stop();
                lock (asked)
                    Check(l1 != null && l1.Count == 1 && l2 != null && l2.Count == 1 && asked.Count == 3 && asked[0] == "/api/games" && asked[1] == "/api/servers" && asked[2] == "/api/servers",
                        "server list: an older list, /api/games once, then /api/servers only (" + string.Join(" ", asked) + ")");
                var until2 = DateTime.MinValue;
                bool threw = false;
                try { MainForm.FetchList(url, true, ref until2); } catch (WebException) { threw = true; }
                Check(threw && until2 == DateTime.MinValue, "server list: a list that does not answer: the error at once, not taken as an older list");
            }
            catch (Exception e) { Check(false, "options kept: " + e.Message); }
            finally
            {
                MainForm.SettingsFileForTest = keepFile;
                MainForm.ForgetGameOptions();
                try { Directory.Delete(dir, true); } catch { }
            }
            return ok;
        }

        /// <summary>Dedicated server: its settings file, and who its relay lets in (password, version, places), over TCP.</summary>
        static bool RunServer()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }

            // 1. the settings: the file written the first time reads back as the defaults; values, and lines that are ignored
            var dir = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, ServerConfig.FileName);
            var problems = new List<string>();
            var c = ServerConfig.Load(path, problems, out bool created);
            Check(created && problems.Count == 0 && c.Port == 28090 && c.World == "" && c.Password == "" && c.MaxPlayers == 8
                  && c.CompanyMode == "shared" && c.PauseWhenEmpty && c.AutosaveMinutes == 10 && c.RestartOnCrash && c.ShareRules, "settings: template = defaults");
            File.WriteAllText(path, "# comment\nworld=My Map 2\nport=28100\npassword=s3cr#t = x\nmax-players=1\ncompany-mode=separate\nowner=Lena\n"
                + "start-speed=3\nwatchdog-seconds=5\nstart-money=abc\npause-when-empty=no\nsharing-rules=false\nbogus\n", new UTF8Encoding(false));
            problems.Clear();
            c = ServerConfig.Load(path, problems, out created);
            // (0.5.14: sharing-rules=false, everything open and free between the companies)
            Check(!created && c.World == "My Map 2" && c.Port == 28100 && c.Password == "s3cr#t = x" && c.MaxPlayers == 1 && c.CompanyMode == "separate"
                  && c.Owner == "Lena" && c.StartSpeed == 1 && c.WatchdogSeconds == 30 && c.StartMoney == 2000000 && !c.PauseWhenEmpty && !c.ShareRules && problems.Count == 3,
                  "settings: values, " + problems.Count + " line(s) ignored");
            try { Directory.Delete(dir, true); } catch { }

            // 2. who comes in
            int port = 28192;
            var relay = new Relay();
            relay.Admit = (p, m) => c.Admission(m.Payload, MainForm.OthersConnected(relay, p), out _);
            relay.Start(port);

            Dictionary<object, object> Join(string name, string pw, out Client cl, out List<Msg> got)
            {
                Dictionary<object, object> denied = null;
                var closed = new ManualResetEvent(false);
                var list = new List<Msg>();
                cl = new Client();
                cl.Denied += d => denied = d;
                cl.Closed += () => closed.Set();
                cl.Received += m => { lock (list) list.Add(m); };
                cl.Connect("127.0.0.1", port, name, pw);
                closed.WaitOne(1500);
                got = list;
                return denied;
            }
            string Reason(Dictionary<object, object> d) => d != null && d.TryGetValue("reason", out var r) ? r as string : null;

            var d1 = Join("Lena", "wrong", out var c1, out _);
            Check(Reason(d1) == "password", "wrong password refused (" + Reason(d1) + ")");
            var d2 = Join("Lena", null, out var c2, out _);
            Check(Reason(d2) == "password", "missing password refused (" + Reason(d2) + ")");

            // an older MPFever (no version in its join) is refused
            string oldReply = null;
            using (var raw = new TcpClient("127.0.0.1", port))
            {
                var w = new StreamWriter(raw.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
                w.WriteLine("join\tOld\t{}");
                raw.ReceiveTimeout = 1500;
                try { oldReply = new StreamReader(raw.GetStream()).ReadLine(); } catch { }
            }
            Check(oldReply != null && oldReply.StartsWith("denied\t") && oldReply.Contains("\"version\""), "other version refused (" + oldReply + ")");

            var d3 = Join("Lena", "s3cr#t = x", out var lena, out var lenaGot);
            Check(d3 == null && relay.AdmittedCount == 1, "right password let in");
            var d4 = Join("Max", "s3cr#t = x", out var c4, out _);
            Check(Reason(d4) == "full" && relay.AdmittedCount == 1, "server full (" + Reason(d4) + ")");

            // the same player coming back (a reconnection) keeps its place
            var d5 = Join("lena", "s3cr#t = x", out var lena2, out _);
            Check(d5 == null, "reconnection of a player keeps its place");
            lena2.Dispose();
            Thread.Sleep(300);

            // a binary message (the host's savegame, 0.5.0): its bytes arrive whole, and the text messages around it too
            {
                var data = new byte[300000];
                for (int k = 0; k < data.Length; k++) data[k] = (byte)(k * 31 + 7);
                var pl = relay.Admitted().FirstOrDefault();
                if (pl != null)
                {
                    relay.Send(pl, Msg.Make("chat", "Server", "{[\"text\"]=\"before\"}"));
                    relay.Send(pl, Msg.MakeBinary("resync_bin", "Server", "[\"id\"]=1,[\"i\"]=0,[\"n\"]=1", data, 0, data.Length));
                    relay.Send(pl, Msg.Make("chat", "Server", "{[\"text\"]=\"after\"}"));
                    Thread.Sleep(800);
                    Msg bin; bool after;
                    lock (lenaGot) { bin = lenaGot.LastOrDefault(m => m.Kind == "resync_bin"); after = lenaGot.Any(m => m.Kind == "chat" && m.Payload.Contains("after")); }
                    Check(bin != null && bin.Data != null && bin.Data.Length == data.Length && bin.Data.SequenceEqual(data) && after, "binary message: " + (bin?.Data?.Length ?? -1) + " bytes, the text after it too");
                }
                else Check(false, "binary message: nobody to send it to");
            }

            // a connection not let in gets nothing of the session
            using (var idle = new TcpClient("127.0.0.1", port))
            {
                Thread.Sleep(200);
                relay.Broadcast(Msg.Make("session", "Server", "{[\"started\"]=true}"));
                Thread.Sleep(400);
                idle.ReceiveTimeout = 300;
                bool leaked = false;
                try { leaked = idle.GetStream().ReadByte() >= 0; } catch { }
                bool lenaGets; lock (lenaGot) lenaGets = lenaGot.Any(m => m.Kind == "session");
                Check(!leaked && lenaGets, "broadcast: to the players let in only");
            }

            // kicked: told why, and not reconnected
            Dictionary<object, object> kicked = null;
            var gone = new ManualResetEvent(false);
            lena.Denied += d => kicked = d;
            lena.Closed += () => gone.Set();
            int n = relay.Kick("lena", "{[\"reason\"]=\"kicked\"}");
            gone.WaitOne(2000);
            Check(n == 1 && Reason(kicked) == "kicked", "kick");
            Check(MainForm.DeniedText(new Dictionary<object, object> { ["reason"] = "full", ["max"] = 8.0 }).Contains("8"), "refusal told to the player");

            foreach (var x in new[] { c1, c2, lena, c4 }) x.Dispose();
            relay.Dispose();
            return ok;
        }

        sealed class Joiner
        {
            public Client C;
            public volatile Dictionary<object, object> Denied;
            public int Waits;
        }

        /// <summary>(0.6, public games) A player's own game: who its relay lets in when the host's game options ask for it (the
        /// ban list kept in its file, a public game's places, the host's answer to every arrival, told to the arrival while it
        /// waits), and that nothing changes while those options are off; the refusals' texts.</summary>
        static bool RunPublic()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            bool Wait(Func<bool> f, int ms = 4000) { for (int i = 0; i < ms / 50 && !f(); i++) Thread.Sleep(50); return f(); }

            // 1. the game options' string, as the lobby gives it
            var o = "public=1;public.max=6; join_bans=0;public.ip=1";
            Check(MainForm.OptValue(o, "public") == "1" && MainForm.OptValue(o, "public.max") == "6" && MainForm.OptValue(o, "join_bans") == "0"
                  && MainForm.OptValue(o, "public.ip") == "1" && MainForm.OptValue(o, "join_approve") == null && MainForm.OptValue("", "public") == null, "options: values read");

            // 2. the ban list, kept in its file
            var dir = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(dir);
            string opts = "";
            var gate = new PublicGate { BanFile = Path.Combine(dir, "mpfever_bans.txt"), AskSeconds = 30, Options = () => opts };
            // (the lobby's string, as GameOpts keeps it: a parameter left at its default may be absent)
            opts = GameOpts.Canon("public=1;join_bans=0");
            int max8 = gate.MaxPlayers;
            opts = GameOpts.Apply(opts, "public.max=3", out _);
            int max3 = gate.MaxPlayers;
            opts = GameOpts.Apply(opts, "public=0", out _);
            Check(max8 == 8 && max3 == 3 && gate.MaxPlayers == 0 && opts == "", "options: the lobby's string read (" + max8 + ", " + max3 + ", " + gate.MaxPlayers + ")");
            gate.AddBan("Lena", "76561198000000002", "");
            gate.AddBan("Troll", "", "203.0.113.9");
            var again = new PublicGate { BanFile = gate.BanFile };
            Check(again.Bans().Count == 2 && again.BannedAs("lena", "", "") != null && again.BannedAs("Other", "76561198000000002", "") != null
                  && again.BannedAs("Other", "", "203.0.113.9") != null && again.BannedAs("Other", "1", "203.0.113.10") == null, "bans: kept in the file, by name, Steam id or address");

            // 3. who comes in, over TCP
            int port = 28193;
            var relay = new Relay();
            relay.Admit = (p, m) => MainForm.VersionAdmit(m.Payload) ?? gate.Admit(p, () => MainForm.OthersConnected(relay, p), q => relay.TrySend(q, Msg.Make("admitwait", "MPFever", "{}")));
            relay.Start(port);
            var all = new List<Joiner>();
            Joiner Join(string name)
            {
                var j = new Joiner { C = new Client() };
                j.C.Denied += d => j.Denied = d;
                j.C.Waiting += () => Interlocked.Increment(ref j.Waits);
                j.C.Connect("127.0.0.1", port, name);
                all.Add(j);
                return j;
            }
            string Reason(Joiner j) => j.Denied != null && j.Denied.TryGetValue("reason", out var r) ? r as string : null;
            bool Leave(Joiner j) { j.C.Dispose(); return Wait(() => relay.AdmittedCount == 0); }
            try
            {
                // options off: a banned player comes in, as in 0.5.14
                var lena = Join("Lena");
                Check(Wait(() => relay.AdmittedCount == 1) && lena.Denied == null && lena.Waits == 0, "options off: everybody comes in (the ban list not read)");
                Leave(lena);

                opts = "join_bans=1";
                var lena2 = Join("LENA");
                Check(Wait(() => lena2.Denied != null) && Reason(lena2) == "banned" && lena2.Denied.ContainsKey("game"), "ban list on: a banned name refused (" + Reason(lena2) + ")");
                var max = Join("Max");
                Check(Wait(() => relay.AdmittedCount == 1) && max.Denied == null, "ban list on: the others come in");

                // a public game: 2 players at most here, the host counted
                opts = "join_bans=1;public=1;public.max=2";
                var zoe = Join("Zoe");
                Check(Wait(() => zoe.Denied != null) && Reason(zoe) == "full" && Convert.ToString(zoe.Denied["max"]) == "2", "public game: full (" + Reason(zoe) + ")");
                Leave(max);

                // the host lets every arrival in by hand: the arrival waits, told so, and is not a player before the answer
                opts = "join_approve=1";
                var ann = Join("Ann");
                Check(Wait(() => gate.Waiting().Length == 1 && ann.Waits > 0) && relay.AdmittedCount == 0 && gate.Waiting()[0].StartsWith("Ann#"), "approval: the arrival waits, told so");
                Check(gate.Answer("Ann", true) && Wait(() => relay.AdmittedCount == 1) && ann.Denied == null && gate.Waiting().Length == 0, "approval: let in");
                // (the waiting notices are not session messages: the link counts from the admission)
                Check(ann.C.Link.Rx == 0, "approval: the notices not counted in the session link (" + ann.C.Link.Rx + ")");
                var bob = Join("Bob");
                Check(Wait(() => gate.Waiting().Length == 1) && gate.Answer(gate.Waiting()[0], false) && Wait(() => bob.Denied != null) && Reason(bob) == "refused", "approval: refused (" + Reason(bob) + ")");
                // a player let in that comes back is not asked again
                Leave(ann);
                var ann2 = Join("Ann");
                Check(Wait(() => relay.AdmittedCount == 1) && gate.Waiting().Length == 0 && ann2.Waits == 0, "approval: a player let in comes back without asking");
                // the places of a public game are checked before asking
                opts = "join_approve=1;public=1;public.max=2";
                var dan = Join("Dan");
                Check(Wait(() => dan.Denied != null) && Reason(dan) == "full" && dan.Waits == 0, "approval: a full game refuses before asking");
                Leave(ann2);
                // a player kicked is asked again
                gate.Forget("ann");
                var ann3 = Join("Ann");
                Check(Wait(() => gate.Waiting().Length == 1) && gate.Answer("Ann", false) && Wait(() => ann3.Denied != null), "approval: a kicked player is asked again");
                // no answer in time: refused; the session's end refuses those still waiting
                opts = "join_approve=1";
                gate.AskSeconds = 1;
                var cid = Join("Cid");
                Check(Wait(() => cid.Denied != null) && Reason(cid) == "refused", "approval: no answer in time, refused");
                gate.AskSeconds = 30;
                var eve = Join("Eve");
                Check(Wait(() => gate.Waiting().Length == 1), "approval: waiting again");
                gate.EndSession();
                Check(Wait(() => eve.Denied != null) && Reason(eve) == "refused" && gate.Waiting().Length == 0, "approval: the session's end refuses those waiting");
            }
            finally
            {
                foreach (var j in all) try { j.C.Dispose(); } catch { }
                relay.Dispose();
            }

            // 4. the ban taken back; the refusals told to the player
            Check(gate.RemoveBan("lena") && gate.BannedAs("Lena", "", "") == null && gate.Bans().Count == 1, "bans: one taken back");
            try { Directory.Delete(dir, true); } catch { }
            string Text(string reason, bool game) => MainForm.DeniedText(new Dictionary<object, object> { ["reason"] = reason, ["max"] = 4.0, ["game"] = game });
            string fallback = Text("nothing", true);
            Check(new[] { Text("banned", true), Text("refused", true), Text("kicked", true), Text("full", true) }.All(t => t != fallback && t.Length > 10)
                  && Text("kicked", true) != Text("kicked", false) && Text("full", true).Contains("4") && Text("full", true) != Text("full", false), "refusals of a player's game told to the player");
            return ok;
        }
    }
}
