using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using static MPFever.L;

namespace MPFever
{
    /// <summary>"Report a problem": every file a bug report needs, in one zip, and a GitHub issue ready to send.
    /// The zip goes to reports\ next to MPFever.exe and is shown in the Explorer; the browser opens a new issue of
    /// github.com/dkdknight/MPFever with its title and text filled in (version, game build, company mode, players, sync
    /// state, processor), and the text is also put on the clipboard. The player drags the zip into the issue and sends it:
    /// GitHub lets nobody create an issue or attach a file without an account of their own (a key shipped in MPFever would
    /// let anyone post anything in the project's name), so the last click is theirs.
    /// The game rewrites its log (stdout.txt) each time it starts: MPFever copies it into the session folder when the game
    /// closes, and the previous one into logs\ before it starts the game.</summary>
    static class Reporter
    {
        public static string ReportsDir => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "reports");
        public static string LogsDir => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs");
        /// <summary>GitHub's limit for a file attached to an issue.</summary>
        const long AttachLimit = 25L * 1024 * 1024;
        /// <summary>Files larger than this are left out of the zip (savegames, census dumps): the text says so.</summary>
        const long FileLimit = 20L * 1024 * 1024;
        /// <summary>Text logs larger than FileLimit: their last TextTailLimit bytes go in (up to TextReadLimit; larger ones are left out).</summary>
        const long TextTailLimit = 60L * 1024 * 1024;
        const long TextReadLimit = 2048L * 1024 * 1024;

        /// <summary>The game's crash_dump folders (one per Steam account that played it), the newest first.</summary>
        public static List<string> CrashDumpDirs()
        {
            var list = new List<string>();
            try
            {
                var steam = GameInstall.SteamPath();
                var userdata = steam == null ? null : Path.Combine(steam, "userdata");
                if (userdata != null && Directory.Exists(userdata))
                    foreach (var u in Directory.GetDirectories(userdata))
                    {
                        var d = Path.Combine(u, GameInstall.AppId, "local", "crash_dump");
                        if (Directory.Exists(d)) list.Add(d);
                    }
                // (next to the savegame folders the game gave, wherever it keeps its data: issue #80's report had no game log)
                lock (GameInstall.GameSaveDirs)
                    foreach (var s in GameInstall.GameSaveDirs)
                    {
                        var parent = Path.GetDirectoryName(s.TrimEnd('\\', '/'));
                        var d = parent == null ? null : Path.Combine(parent, "crash_dump");
                        if (d != null && Directory.Exists(d) && !list.Any(x => string.Equals(Path.GetFullPath(x), Path.GetFullPath(d), StringComparison.OrdinalIgnoreCase))) list.Add(d);
                    }
            }
            catch { }
            return list.OrderByDescending(d => LastWrite(Path.Combine(d, "stdout.txt"))).ToList();
        }

        static DateTime LastWrite(string f) { try { return File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue; } catch { return DateTime.MinValue; } }

        /// <summary>The game's log as it is now (the newest stdout.txt), or null.</summary>
        /// <summary>(0.7.3) Waits (at most `seconds`) until a file the game is writing is done: not empty, and the same size for a
        /// second.</summary>
        public static void WaitWritten(string path, int seconds)
        {
            var end = DateTime.UtcNow.AddSeconds(seconds);
            long last = -1;
            while (DateTime.UtcNow < end)
            {
                long len = 0;
                try { len = new FileInfo(path).Length; } catch { return; }
                if (len > 0 && len == last) return;
                last = len;
                System.Threading.Thread.Sleep(1000);
            }
        }

        public static string GameLog() =>CrashDumpDirs().Select(d => Path.Combine(d, "stdout.txt")).FirstOrDefault(File.Exists);

        /// <summary>Before the game starts: the log of its previous run is kept (logs\stdout-previous.txt), the game
        /// rewrites stdout.txt at its start.</summary>
        public static void KeepPreviousGameLog()
        {
            try
            {
                var f = GameLog();
                if (f == null) return;
                Directory.CreateDirectory(LogsDir);
                File.Copy(f, Path.Combine(LogsDir, "stdout-previous.txt"), true);
            }
            catch (Exception e) { Log.Dim("report: " + e.Message); }
        }

        /// <summary>The game closed: its log goes into the session folder (complete only now).</summary>
        public static void KeepGameLog(string sessionDir)
        {
            try
            {
                var f = GameLog();
                if (f != null && sessionDir != null && Directory.Exists(sessionDir)) File.Copy(f, Path.Combine(sessionDir, "stdout.txt"), true);
            }
            catch (Exception e) { Log.Dim("report: " + e.Message); }
        }

        /// <summary>Did the game crash after <paramref name="since"/>? (a crash dump written since, and its log does not end with
        /// the game's normal shutdown: the game writes dumps of its own while it loads, at Steam events and when it quits,
        /// and every normal close was reported as a crash)</summary>
        public static bool CrashedSince(DateTime since, string sessionDir = null, int? exitCode = null, bool otherGame = false)
        {
            // (0.7.5) Two games of one Steam account on one PC write one log (the game's stdout.txt in its crash_dump folder),
            // and the game writes dumps of its own (at its load, at Steam events): the user's client game, closed normally on
            // 2026-10-29 08:45:57 while the host's game on the same PC still ran, was reported as crashed (the log's last lines
            // were the host's, no "Normal shutdown" yet; a dump of its load). A game that ended with code 0 while another game
            // ran beside it is not taken for a crash. MPFEVER_SHAREDLOGOLD=1: as before
            if (otherGame && exitCode == 0 && Environment.GetEnvironmentVariable("MPFEVER_SHAREDLOGOLD") != "1")
            {
                Log.Dim("report: the game ended with code 0, another game ran on this PC (one log for both): not a crash");
                return false;
            }
            bool dump = false;
            foreach (var d in CrashDumpDirs())
                try { if (Directory.GetFiles(d, "*.dmp").Any(f => File.GetLastWriteTime(f) > since)) dump = true; } catch { }
            if (!dump) return false;
            try
            {
                var log = sessionDir != null ? Path.Combine(sessionDir, "stdout.txt") : null;
                if (log == null || !File.Exists(log)) log = GameLog();
                if (log != null && File.Exists(log) && File.GetLastWriteTime(log) > since)
                {
                    using (var fs = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        long from = Math.Max(0, fs.Length - 4096);
                        fs.Seek(from, SeekOrigin.Begin);
                        var buf = new byte[fs.Length - from];
                        int n = fs.Read(buf, 0, buf.Length);
                        if (Encoding.UTF8.GetString(buf, 0, n).Contains("Normal shutdown")) return false;
                    }
                }
            }
            catch { }
            return true;
        }

        /// <summary>(0.7.5) How many Transport Fever 3 processes run on this PC besides the one of id `exceptPid` (-1: none).</summary>
        public static int OtherGamesRunning(int exceptPid)
        {
            try
            {
                int n = 0;
                foreach (var p in System.Diagnostics.Process.GetProcessesByName("TransportFever3"))
                    try { if (p.Id != exceptPid && !p.HasExited) n++; } catch { } finally { p.Dispose(); }
                return n;
            }
            catch { return 0; }
        }

        [DllImport("kernel32.dll")] static extern bool IsProcessorFeaturePresent(int feature);

        /// <summary>The processor, and whether it has AVX2 (the C library's maths then take their FMA3 versions: two players
        /// with and without them may compute some values a little differently).</summary>
        public static string Processor()
        {
            string name = "?";
            try { name = (Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", "?") as string ?? "?").Trim(); } catch { }
            string avx2 = "?";
            try { avx2 = IsProcessorFeaturePresent(40) ? "AVX2/FMA3 yes" : "AVX2/FMA3 no"; } catch { }
            return name + " (" + Environment.ProcessorCount + " threads, " + avx2 + ")";
        }

        /// <summary>Windows' name and build, from the registry (Environment.OSVersion says 6.2 to a program without a
        /// manifest, whatever the Windows).</summary>
        public static string WindowsVersion()
        {
            try
            {
                const string k = @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion";
                var name = Registry.GetValue(k, "ProductName", null) as string;
                var build = Registry.GetValue(k, "CurrentBuild", null) as string;
                var ubr = Registry.GetValue(k, "UBR", null);
                // (Windows 11 still names itself Windows 10 there: its builds start at 22000)
                if (name != null && int.TryParse(build, out var b) && b >= 22000) name = name.Replace("Windows 10", "Windows 11");
                if (name != null) return name + " (build " + build + (ubr != null ? "." + ubr : "") + ")";
            }
            catch { }
            return "Windows " + Environment.OSVersion.Version;
        }

        /// <summary>The game build: TransportFever3.exe's link timestamp, with its name when known.</summary>
        public static string GameBuild(string gameDir)
        {
            try
            {
                var exe = Path.Combine(gameDir ?? "", "TransportFever3.exe");
                if (!File.Exists(exe)) return "?";
                using (var f = File.OpenRead(exe))
                {
                    var b = new byte[1024];
                    f.Read(b, 0, b.Length);
                    int pe = BitConverter.ToInt32(b, 0x3c);
                    uint stamp = BitConverter.ToUInt32(b, pe + 8);
                    string known = stamp == 0x6ad9ce10 ? "40425" : stamp == 0x6ad0e4e5 ? "40423" : stamp == 0x6ac50427 ? "40420" : stamp == 0x6ab69fe5 ? "40408" : "unknown build";
                    // (0.7.7, issue #135: a GOG copy, build 40393, read "unknown build (6ab3eec7)": the game's own log says which,
                    // and whether Steam installed it. MPFEVER_REPORTBUILD=0: as before)
                    string extra = "";
                    if (Environment.GetEnvironmentVariable("MPFEVER_REPORTBUILD") != "0")
                    {
                        if (known == "unknown build") { var n = BuildInLog(GameLog()); if (n != null) extra += ", build " + n + " in the game's log"; }
                        if (GameInstall.NotSteamCopy(gameDir)) extra += ", NOT a Steam copy (GOG or another store)";
                    }
                    return known + " (" + stamp.ToString("x8") + extra + ")";
                }
            }
            catch { return "?"; }
        }

        /// <summary>(0.7.7) This game's build as the host and the players tell it to each other (MainForm.BuildWarning):
        /// "stamp|number|store", the exe's link stamp (what tells two builds apart), its build number (known stamps, else the
        /// game's log, else "?") and "steam" or "other" (a copy Steam did not install). "" when the game is not found. Kept
        /// while the exe does not change (it goes with every lobby message).</summary>
        internal static string BuildTag(string gameDir)
        {
            try
            {
                var exe = Path.Combine(gameDir ?? "", "TransportFever3.exe");
                if (!File.Exists(exe)) return "";
                var key = exe + "|" + File.GetLastWriteTimeUtc(exe).Ticks;
                lock (buildTagCache) if (buildTagCache.TryGetValue(key, out var hit)) return hit;
                uint stamp;
                using (var f = File.OpenRead(exe))
                {
                    var b = new byte[1024];
                    f.Read(b, 0, b.Length);
                    int pe = BitConverter.ToInt32(b, 0x3c);
                    stamp = BitConverter.ToUInt32(b, pe + 8);
                }
                string known = stamp == 0x6ad9ce10 ? "40425" : stamp == 0x6ad0e4e5 ? "40423" : stamp == 0x6ac50427 ? "40420" : stamp == 0x6ab69fe5 ? "40408" : null;
                var tag = stamp.ToString("x8") + "|" + (known ?? BuildInLog(GameLog()) ?? "?") + "|" + (GameInstall.NotSteamCopy(gameDir) ? "other" : "steam");
                // (an unknown build whose number the log does not give yet: not kept, the log may have it at the next call)
                if (!tag.Contains("|?|")) lock (buildTagCache) buildTagCache[key] = tag;
                return tag;
            }
            catch { return ""; }
        }
        static readonly Dictionary<string, string> buildTagCache = new Dictionary<string, string>();

        /// <summary>(0.7.7) The build the game's log names at its start ("Starting up build version: 40393"), or null.</summary>
        internal static string BuildInLog(string logPath)
        {
            try
            {
                if (string.IsNullOrEmpty(logPath) || !File.Exists(logPath)) return null;
                using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(fs))
                {
                    for (int i = 0; i < 60; i++)
                    {
                        var line = r.ReadLine();
                        if (line == null) break;
                        var m = System.Text.RegularExpressions.Regex.Match(line, @"Starting up build version: (\d+)");
                        if (m.Success) return m.Groups[1].Value;
                    }
                }
            }
            catch { }
            return null;
        }

        sealed class Entry { public string Path, Name; }

        /// <summary>Writes the zip: the session folders given (the current game's first), the launcher's logs of today and
        /// the previous run's, the game's log (and the previous one), its newest crash dump, and report.txt (what the zip
        /// is, the session's state). Returns the zip's path.</summary>
        public static string Collect(IEnumerable<string> sessionDirs, string summary, out List<string> left)
        {
            left = new List<string>();
            Directory.CreateDirectory(ReportsDir);
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            var zip = FreeName(Path.Combine(ReportsDir, "MPFever-report-" + stamp + ".zip"));
            var files = new List<Entry>();
            void Add(string path, string name)
            {
                try { if (File.Exists(path)) files.Add(new Entry { Path = path, Name = name.Replace('\\', '/') }); } catch { }
            }
            foreach (var dir in sessionDirs.Where(d => d != null && Directory.Exists(d)).Distinct())
                foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                    Add(f, "session/" + Path.GetFileName(dir) + "/" + f.Substring(dir.Length).TrimStart('\\', '/'));
            try
            {
                foreach (var f in Directory.GetFiles(LogsDir, "launcher-*.log").OrderByDescending(File.GetLastWriteTimeUtc).Take(3))
                    Add(f, "launcher/" + Path.GetFileName(f));
                Add(Path.Combine(LogsDir, "stdout-previous.txt"), "game/stdout-previous.txt");
            }
            catch { }
            var game = GameLog();
            if (game != null) Add(game, "game/stdout.txt");
            foreach (var d in CrashDumpDirs().Take(1))
                try
                {
                    var dmp = Directory.GetFiles(d, "*.dmp").OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
                    // (0.7.3) a report made right after the crash got the dump while the game was still writing it: 0 bytes in
                    // issue #130. Waited for until its size is not 0 and stays the same for a second (15 s at most).
                    // MPFEVER_DUMPWAIT=0: as before
                    if (dmp != null && Environment.GetEnvironmentVariable("MPFEVER_DUMPWAIT") != "0") WaitWritten(dmp, 15);
                    if (dmp != null && File.GetLastWriteTime(dmp) > DateTime.Now.AddDays(-2)) Add(dmp, "game/" + Path.GetFileName(dmp));
                }
                catch { }
            using (var z = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var e in files)
                {
                    if (!seen.Add(e.Name)) continue;
                    long size = 0;
                    try { size = new FileInfo(e.Path).Length; } catch { continue; }
                    // (a text log larger than that: its end, where the problem is; text packs about ten times smaller. The friends'
                    // reports lost in.log, 27 MB, the builds each game received)
                    bool tail = size > FileLimit && Redact.IsText(e.Name) && size <= TextReadLimit;
                    if (size > FileLimit && !tail) { left.Add(e.Name + " (" + (size >> 20) + " MB)"); continue; }
                    if (tail && size > TextTailLimit) left.Add(e.Name + " (" + (size >> 20) + " MB: only its last " + (TextTailLimit >> 20) + " MB)");
                    try
                    {
                        // (the game may still be writing its logs: read them shared)
                        using (var src = new FileStream(e.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        using (var dst = z.CreateEntry(e.Name, CompressionLevel.Optimal).Open())
                        {
                            if (tail && size > TextTailLimit) src.Seek(size - TextTailLimit, SeekOrigin.Begin);
                            // the text files without what tells who and where the player is (the issues are public)
                            if (Redact.IsText(e.Name)) Redact.Copy(src, dst);
                            else src.CopyTo(dst);
                        }
                    }
                    catch (Exception ex) { left.Add(e.Name + " (" + ex.Message + ")"); }
                }
                var info = z.CreateEntry("report.txt");
                using (var w = new StreamWriter(info.Open(), new UTF8Encoding(false)))
                {
                    w.WriteLine(Redact.Text(summary));
                    w.WriteLine();
                    w.WriteLine("Personal data removed from the text files: Windows account and PC names in paths, Steam account numbers, public IP addresses, e-mail addresses.");
                    if (left.Count > 0) { w.WriteLine(); w.WriteLine("Left out (too large or unreadable):"); foreach (var l in left) w.WriteLine("  " + l); }
                }
            }
            return zip;
        }

        /// <summary>(0.6.5, #109) A name no file has yet: the same one with -2, -3... before its extension. Two reports made in
        /// the same second (the button clicked twice) named the same zip, and the second failed on "the file already exists",
        /// leaving a truncated one (Kev1505in's report of 2026-10-31).</summary>
        public static string FreeName(string path)
        {
            if (!File.Exists(path)) return path;
            var dir = Path.GetDirectoryName(path) ?? "";
            var name = Path.GetFileNameWithoutExtension(path);
            var ext = Path.GetExtension(path);
            for (int i = 2; ; i++)
            {
                var p = Path.Combine(dir, name + "-" + i + ext);
                if (!File.Exists(p)) return p;
            }
        }

        /// <summary>The browser opens a new issue with this title and text; the text is cut to what a link can carry.</summary>
        public static void OpenIssue(string title, string body)
        {
            const int max = 6000;
            if (body.Length > max) body = body.Substring(0, max) + "\n…";
            var url = "https://github.com/" + Updater.Repo + "/issues/new?title=" + Uri.EscapeDataString(title) + "&body=" + Uri.EscapeDataString(body);
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception e) { Log.W("report: " + e.Message); }
        }

        public static void ShowInExplorer(string file)
        {
            try { Process.Start("explorer.exe", "/select,\"" + file + "\""); }
            catch (Exception e) { Log.W("report: " + e.Message); }
        }

        /// <summary>The issue's text (English: the issues are written in English).</summary>
        public static string IssueBody(string zipName, long zipSize, string summary, bool crashed)
        {
            summary = Redact.Text(summary);
            var sb = new StringBuilder();
            sb.AppendLine("### What happened");
            sb.AppendLine(crashed ? "The game crashed. What was I doing just before:" : "What I did just before (built a station, bulldozed a road, bought a vehicle...):");
            sb.AppendLine();
            sb.AppendLine("At what time (my clock): " + DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
            sb.AppendLine("Does it happen again:");
            sb.AppendLine();
            sb.AppendLine("### Logs");
            if (zipSize <= AttachLimit)
                sb.AppendLine("**Drag `" + zipName + "` here** (MPFever just showed it in the Explorer, in its `reports` folder). The other players can send theirs with the same button.");
            else
                sb.AppendLine("`" + zipName + "` is " + (zipSize >> 20) + " MB, over GitHub's 25 MB: link to it on Google Drive, Dropbox or WeTransfer.");
            sb.AppendLine("The savegame helps a lot too (over 25 MB: a link).");
            sb.AppendLine();
            sb.AppendLine("### Session");
            sb.AppendLine("```");
            sb.AppendLine(summary.Trim());
            sb.AppendLine("```");
            return sb.ToString();
        }
    }
}

namespace MPFever
{
    /// <summary>What a problem report must not show (the issues are public): the Windows account's and the PC's names in paths,
    /// the Steam account (its number in userdata, its 64-bit id: each becomes a short code, the same throughout one report, so
    /// that the logs can still be followed), public IP addresses (the local and private ones stay: they tell a LAN from the
    /// Internet) and e-mail addresses. The players' names stay: the logs are about them.</summary>
    static class Redact
    {
        static readonly string[] TextExt = { ".log", ".txt", ".lua", ".json", ".csv", ".cfg", ".ini", ".xml", ".md" };
        public static bool IsText(string name) => TextExt.Contains(Path.GetExtension(name).ToLowerInvariant());

        static Regex userPath, machine;
        static readonly Regex userdata = new Regex(@"(?i)(userdata[\\/]+)(\d{3,})", RegexOptions.Compiled);
        static readonly Regex steam64 = new Regex(@"\b7656119\d{10}\b", RegexOptions.Compiled);
        static readonly Regex ipv4 = new Regex(@"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d]|\.\d)", RegexOptions.Compiled);
        static readonly Regex ipv6 = new Regex(@"(?i)(?<![0-9a-f:])[23][0-9a-f]{3}(?::[0-9a-f]{0,4}){3,7}(?![0-9a-f:])", RegexOptions.Compiled);
        static readonly Regex mail = new Regex(@"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}", RegexOptions.Compiled);

        static void Init()
        {
            if (userPath != null) return;
            var names = new List<string>();
            try { names.Add(Environment.UserName); } catch { }
            try
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                names.Add(Path.GetFileName(home));
                var sb = new StringBuilder(520);
                if (GetShortPathName(home, sb, sb.Capacity) > 0) names.Add(Path.GetFileName(sb.ToString()));
            }
            catch { }
            var alts = names.Where(n => !string.IsNullOrEmpty(n)).Distinct(StringComparer.OrdinalIgnoreCase).Select(Regex.Escape).ToList();
            // C:\Users\<name>\..., C:/Users/<name>/..., C:\\Users\\<name> (in Lua strings)
            userPath = new Regex(@"(?i)([\\/]+users[\\/]+)(" + (alts.Count > 0 ? string.Join("|", alts) : "(?!x)x") + @")(?=[\\/""'\s]|$)", RegexOptions.Compiled | RegexOptions.Multiline);
            string m = null;
            try { m = Environment.MachineName; } catch { }
            machine = m != null && m.Length >= 4 ? new Regex(@"(?i)(?<![\w-])" + Regex.Escape(m) + @"(?![\w-])", RegexOptions.Compiled) : null;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern int GetShortPathName(string path, StringBuilder shortPath, int size);

        static string Code(string what, string v)
        {
            uint h = 2166136261;
            foreach (char c in v) { h ^= c; h *= 16777619; }
            return what + (h % 0xFFFFFF).ToString("x6", CultureInfo.InvariantCulture);
        }

        static bool KeepIp(int a, int b, int c, int d)
        {
            if (a > 255 || b > 255 || c > 255 || d > 255) return true;    // not an address (a version number...)
            if (a == 127 || a == 10 || a == 0 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254)) return true;
            if (a == 100 && b >= 64 && b <= 127) return true;               // the provider's shared space (CGNAT): not the player's
            if (a >= 224) return true;                                       // multicast, broadcast
            return false;
        }

        public static string Text(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            Init();
            s = userPath.Replace(s, x => x.Groups[1].Value + "user");
            if (machine != null) s = machine.Replace(s, "pc");
            s = userdata.Replace(s, x => x.Groups[1].Value + Code("account-", x.Groups[2].Value));
            s = steam64.Replace(s, x => Code("steam-", x.Value));
            s = ipv4.Replace(s, x => KeepIp(int.Parse(x.Groups[1].Value), int.Parse(x.Groups[2].Value), int.Parse(x.Groups[3].Value), int.Parse(x.Groups[4].Value))
                ? x.Value : Code("ip-", x.Value));
            s = ipv6.Replace(s, x => Code("ipv6-", x.Value.ToLowerInvariant()));
            s = mail.Replace(s, "mail");
            return s;
        }

        /// <summary>A text file (read as UTF-8, else as Windows-1252), written back as UTF-8 without the personal data.</summary>
        public static void Copy(Stream src, Stream dst)
        {
            var ms = new MemoryStream();
            src.CopyTo(ms);
            var bytes = ms.ToArray();
            string text;
            try { text = new UTF8Encoding(false, true).GetString(bytes); }
            catch { text = Encoding.GetEncoding(1252).GetString(bytes); }
            var outBytes = new UTF8Encoding(false).GetBytes(Text(text));
            dst.Write(outBytes, 0, outBytes.Length);
        }
    }
}
