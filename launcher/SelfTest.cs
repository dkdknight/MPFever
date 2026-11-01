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
            Log.W(ok ? "SELFTEST OK" : "SELFTEST FAILED");
            return ok ? 0 : 1;
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
            Check(Mods.Judge("devers_1", Mods.Sim).Level == "bad", "mods: Real Track Cant (devers_1) incompatible");
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
