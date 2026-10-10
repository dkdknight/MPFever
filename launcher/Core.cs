using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace MPFever
{
    /// <summary>Launcher language. The French and English texts are written in the code as T("français", "English");
    /// the other languages come from lang.json (embedded in MPFever.exe), keyed by the English text.
    /// The language is the one chosen in the launcher, else the game's language, else Windows', else English.</summary>
    static class L
    {
        public sealed class Language
        {
            public readonly string Code, Name;
            public Language(string code, string name) { Code = code; Name = name; }
        }

        /// <summary>The languages of Transport Fever 3, each named in its own language.</summary>
        public static readonly Language[] All =
        {
            new Language("de", "Deutsch"), new Language("en", "English"), new Language("es", "Español"),
            new Language("fr", "Français"), new Language("it", "Italiano"), new Language("nl", "Nederlands"),
            new Language("pl", "Polski"), new Language("pt-BR", "Português (Brasil)"), new Language("ru", "Русский"),
            new Language("ja", "日本語"), new Language("ko", "한국어"), new Language("zh-CN", "简体中文"),
            new Language("zh-TW", "繁體中文"),
        };

        public static string Code { get; private set; } = "en";
        public static bool Fr => Code == "fr";
        public static string Name => All.First(l => l.Code == Code).Name;
        public static string NameOf(string code) => All.FirstOrDefault(l => l.Code == code)?.Name ?? code;
        static volatile Dictionary<string, string> table = new Dictionary<string, string>();

        /// <summary>Raised after the language changed (on the thread that changed it).</summary>
        public static event Action Changed;

        public static string T(string fr, string en)
        {
            var c = Code;
            if (c == "fr") return fr;
            if (c == "en") return en;
            return table.TryGetValue(en, out var v) ? v : en;
        }

        /// <summary>T with {0} {1}... placeholders.</summary>
        public static string F(string fr, string en, params object[] args)
        {
            try { return string.Format(T(fr, en), args); }
            catch (FormatException) { return string.Format(Fr ? fr : en, args); }   // a broken translation
        }

        public static void Set(string code)
        {
            if (!All.Any(l => l.Code == code)) code = "en";
            table = Load(code);
            Code = code;
            Changed?.Invoke();
        }

        static Dictionary<string, object> texts;

        /// <summary>The translations of one language from lang.json: { "texts": { "English": { "de": "...", ... } } }.</summary>
        static Dictionary<string, string> Load(string code)
        {
            var d = new Dictionary<string, string>();
            if (code == "en" || code == "fr") return d;
            try
            {
                if (texts == null)
                {
                    using (var st = typeof(L).Assembly.GetManifestResourceStream("lang.json"))
                    using (var r = new StreamReader(st, Encoding.UTF8))
                    {
                        var root = Json.Parse(r.ReadToEnd()) as Dictionary<string, object>;
                        texts = root != null && root.TryGetValue("texts", out var t) ? t as Dictionary<string, object> : null;
                    }
                }
                if (texts == null) return d;
                foreach (var kv in texts)
                    if (kv.Value is Dictionary<string, object> tr && tr.TryGetValue(code, out var v) && v is string s && s.Length > 0)
                        d[kv.Key] = s;
            }
            catch (Exception e) { Log.W("lang.json: " + e.Message); }
            return d;
        }

        /// <summary>The table for the mod (lang.txt in each game's session folder): "@lang TAB code", then
        /// "English TAB translation" lines (the mod's Lua code looks its texts up by their English version).</summary>
        public static string ModTable()
        {
            var sb = new StringBuilder("@lang\t" + Code + "\n");
            foreach (var kv in table)
                if (kv.Key.IndexOfAny(new[] { '\t', '\n', '\r' }) < 0 && kv.Value.IndexOfAny(new[] { '\t', '\n', '\r' }) < 0)
                    sb.Append(kv.Key).Append('\t').Append(kv.Value).Append('\n');
            return sb.ToString();
        }

        /// <summary>A language code from a Steam language name ("german"), a game setting ("de", "de_DE") or a Windows
        /// culture ("de-DE"); null when it is none of the game's languages.</summary>
        public static string Normalize(string s)
        {
            if (string.IsNullOrWhiteSpace(s)) return null;
            s = s.Trim().ToLowerInvariant().Replace('_', '-');
            switch (s)
            {
                case "german": case "deutsch": return "de";
                case "english": return "en";
                case "french": case "francais": case "français": return "fr";
                case "italian": return "it";
                case "spanish": case "latam": return "es";
                case "dutch": return "nl";
                case "polish": return "pl";
                case "russian": return "ru";
                case "japanese": case "jp": return "ja";
                case "korean": case "koreana": case "kr": return "ko";
                case "brazilian": case "portuguese": case "pt": return "pt-BR";
                case "schinese": case "chinese": case "cn": case "zh": return "zh-CN";
                case "tchinese": case "tw": return "zh-TW";
            }
            if (s.StartsWith("zh")) return s.Contains("tw") || s.Contains("hk") || s.Contains("mo") || s.Contains("hant") ? "zh-TW" : "zh-CN";
            if (s.StartsWith("pt")) return "pt-BR";
            var two = s.Length >= 2 ? s.Substring(0, 2) : s;
            return All.Any(l => l.Code == two) && (s.Length == 2 || s[2] == '-') ? two : null;
        }

        /// <summary>The language to use and where it comes from: the launcher's setting ("auto" or empty: none),
        /// else the game's, else Windows', else English.</summary>
        public static string Detect(string saved, out string source)
        {
            var c = Normalize(saved);
            if (c != null) { source = "setting"; return c; }
            try
            {
                c = Normalize(GameInstall.GameLanguage(out var where));
                if (c != null) { source = where; return c; }
            }
            catch { }
            c = Normalize(CultureInfo.CurrentUICulture.Name);
            if (c != null) { source = "windows"; return c; }
            source = "default";
            return "en";
        }
    }

    /// <summary>Minimal JSON reader (objects, arrays, strings, numbers, true/false/null) for lang.json: keys and values
    /// are kept exactly as written, spaces included.</summary>
    static class Json
    {
        public static object Parse(string s)
        {
            int i = 0;
            var v = Value(s, ref i);
            Skip(s, ref i);
            if (i < s.Length) throw new FormatException("JSON: unexpected text at " + i);
            return v;
        }

        static void Skip(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static object Value(string s, ref int i)
        {
            Skip(s, ref i);
            if (i >= s.Length) throw new FormatException("JSON: unexpected end");
            char c = s[i];
            if (c == '{')
            {
                var d = new Dictionary<string, object>();
                i++; Skip(s, ref i);
                if (s[i] == '}') { i++; return d; }
                while (true)
                {
                    Skip(s, ref i);
                    var k = Str(s, ref i);
                    Skip(s, ref i);
                    if (s[i++] != ':') throw new FormatException("JSON: ':' expected at " + (i - 1));
                    d[k] = Value(s, ref i);
                    Skip(s, ref i);
                    if (s[i] == ',') { i++; continue; }
                    if (s[i++] == '}') return d;
                    throw new FormatException("JSON: ',' or '}' expected at " + (i - 1));
                }
            }
            if (c == '[')
            {
                var l = new List<object>();
                i++; Skip(s, ref i);
                if (s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Value(s, ref i));
                    Skip(s, ref i);
                    if (s[i] == ',') { i++; continue; }
                    if (s[i++] == ']') return l;
                    throw new FormatException("JSON: ',' or ']' expected at " + (i - 1));
                }
            }
            if (c == '"') return Str(s, ref i);
            if (string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(s, i, "null", 0, 4) == 0) { i += 4; return null; }
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (i == start) throw new FormatException("JSON: unexpected '" + c + "' at " + i);
            return double.Parse(s.Substring(start, i - start), CultureInfo.InvariantCulture);
        }

        static string Str(string s, ref int i)
        {
            if (s[i] != '"') throw new FormatException("JSON: string expected at " + i);
            var sb = new StringBuilder();
            for (i++; s[i] != '"'; i++)
            {
                if (s[i] != '\\') { sb.Append(s[i]); continue; }
                char e = s[++i];
                switch (e)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'u': sb.Append((char)Convert.ToInt32(s.Substring(i + 1, 4), 16)); i += 4; break;
                    default: sb.Append(e); break;   // \" \\ \/
                }
            }
            i++;
            return sb.ToString();
        }
    }

    enum LogLevel { Auto, Muted, Success, Warning, Error, Section }

    static class Log
    {
        static readonly object Gate = new object();
        static string file;
        public static event Action<string> Line;
        /// <summary>Each line with its kind (colours of the launcher's log).</summary>
        public static event Action<string, LogLevel> Entry;

        public static void Init(string dir)
        {
            Directory.CreateDirectory(dir);
            file = Path.Combine(dir, "launcher-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
        }

        public static void W(string s) => Write(s, LogLevel.Auto);
        public static void Ok(string s) => Write(s, LogLevel.Success);
        public static void Warn(string s) => Write(s, LogLevel.Warning);
        public static void Err(string s) => Write(s, LogLevel.Error);
        public static void Dim(string s) => Write(s, LogLevel.Muted);

        public static void Write(string s, LogLevel level)
        {
            var l = DateTime.Now.ToString("HH:mm:ss.fff") + " " + s;
            lock (Gate) { try { if (file != null) File.AppendAllText(file, l + Environment.NewLine); } catch { } }
            Line?.Invoke(l);
            Entry?.Invoke(l, level);
        }
    }

    /// <summary>One protocol message: kind TAB from TAB payload (payload = single-line Lua table literal).</summary>
    sealed class Msg
    {
        public string Kind, From, Payload;

        public static Msg Parse(string line)
        {
            if (string.IsNullOrEmpty(line)) return null;
            var p = line.Split(new[] { '\t' }, 3);
            if (p.Length < 3) return null;
            return new Msg { Kind = p[0], From = p[1], Payload = p[2] };
        }

        public static Msg Make(string kind, string from, string payload = "{}") => new Msg { Kind = kind, From = from, Payload = payload };

        public override string ToString() => Kind + "\t" + From + "\t" + Payload;
    }

    /// <summary>Tiny parser for the Lua table literals produced by the mod serializer.</summary>
    static class LuaLit
    {
        public static object Parse(string s)
        {
            int i = 0;
            var v = Value(s, ref i);
            return v;
        }

        static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static object Value(string s, ref int i)
        {
            Ws(s, ref i);
            if (i >= s.Length) return null;
            char c = s[i];
            if (c == '{') return Table(s, ref i);
            if (c == '"') return Str(s, ref i);
            if (s.Substring(i).StartsWith("true")) { i += 4; return true; }
            if (s.Substring(i).StartsWith("false")) { i += 5; return false; }
            if (s.Substring(i).StartsWith("nil")) { i += 3; return null; }
            int st = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            double.TryParse(s.Substring(st, i - st), NumberStyles.Float, CultureInfo.InvariantCulture, out var d);
            return d;
        }

        static Dictionary<object, object> Table(string s, ref int i)
        {
            var t = new Dictionary<object, object>();
            i++; // {
            while (true)
            {
                Ws(s, ref i);
                if (i >= s.Length) return t;
                if (s[i] == '}') { i++; return t; }
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '[')
                {
                    i++;
                    var k = Value(s, ref i);
                    Ws(s, ref i);
                    if (i < s.Length && s[i] == ']') i++;
                    Ws(s, ref i);
                    if (i < s.Length && s[i] == '=') i++;
                    var v = Value(s, ref i);
                    if (k != null) t[Norm(k)] = v;
                }
                else { Value(s, ref i); }
            }
        }

        static object Norm(object k) => k is double d && d == Math.Floor(d) ? (object)(long)d : k;

        static string Str(string s, ref int i)
        {
            var sb = new StringBuilder();
            i++; // opening quote
            while (i < s.Length && s[i] != '"')
            {
                if (s[i] == '\\' && i + 1 < s.Length)
                {
                    i++;
                    char e = s[i];
                    if (e == 'n') sb.Append('\n');
                    else if (e == 'r') sb.Append('\r');
                    else if (char.IsDigit(e))
                    {
                        int st = i;
                        while (i < s.Length && i - st < 3 && char.IsDigit(s[i])) i++;
                        sb.Append((char)int.Parse(s.Substring(st, i - st)));
                        continue;
                    }
                    else sb.Append(e);
                    i++;
                }
                else { sb.Append(s[i]); i++; }
            }
            i++; // closing quote
            return sb.ToString();
        }

        public static string Show(object v)
        {
            if (v == null) return "nil";
            if (v is double d) return d.ToString("R", CultureInfo.InvariantCulture);
            if (v is Dictionary<object, object> t)
                return "{" + string.Join(",", t.OrderBy(kv => kv.Key.ToString(), StringComparer.Ordinal).Select(kv => kv.Key + "=" + Show(kv.Value))) + "}";
            return v.ToString();
        }

        public static string Quote(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (var c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c == '\n') sb.Append("\\n");
                else if (c < 32) sb.Append('\\').Append(((int)c).ToString("000"));
                else sb.Append(c);
            }
            return sb.Append('"').ToString();
        }
    }

    /// <summary>File link with one game instance: in.log (launcher to game) and out.log (game to launcher).</summary>
    sealed class GameLink : IDisposable
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        public readonly string Dir;
        public string Name { get; private set; }
        public string Role { get; private set; }
        /// <summary>The game has loaded a savegame and its bridge said hello (false while it shows the main menu).</summary>
        public volatile bool InGame;
        readonly string inPath, outPath;
        readonly object writeGate = new object();
        long outOff;
        volatile bool stop;
        Thread poll;
        Process proc;

        public event Action<GameLink, Msg> FromGame;

        public GameLink(string name, string role)
        {
            Name = name;
            Role = role;
            Dir = Path.Combine(Path.GetTempPath(), "mpfever", name + "-" + DateTime.Now.ToString("HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(Dir);
            inPath = Path.Combine(Dir, "in.log");
            outPath = Path.Combine(Dir, "out.log");
            File.WriteAllText(inPath, "");
            File.WriteAllText(outPath, "");
            poll = new Thread(Poll) { IsBackground = true, Name = "GameLink " + name };
            poll.Start();
        }

        public bool GameRunning => proc != null && !proc.HasExited;

        /// <summary>Name and role chosen in the main menu, read by the mod when the game loads (identity.txt).</summary>
        public void SetIdentity(string name, string role)
        {
            Name = name;
            Role = role;
            File.WriteAllText(Path.Combine(Dir, "identity.txt"), "name=" + name + "\nrole=" + role + "\n", Utf8);
        }

        /// <summary>State shown by the MPFever window of the game's main menu (menu_state.txt, key=value lines).</summary>
        /// <summary>The texts of the current language for the mod (lang.txt, read by its Lua code).</summary>
        public void WriteLang()
        {
            try { lock (writeGate) File.WriteAllText(Path.Combine(Dir, "lang.txt"), L.ModTable(), Utf8); }
            catch (Exception e) { Log.W("lang.txt: " + e.Message); }
        }

        public void WriteMenuState(IDictionary<string, string> st)
        {
            var sb = new StringBuilder();
            foreach (var kv in st) sb.Append(kv.Key).Append('=').Append((kv.Value ?? "").Replace("\r", " ").Replace("\n", " ")).Append('\n');
            var tmp = Path.Combine(Dir, "menu_state.tmp");
            var dst = Path.Combine(Dir, "menu_state.txt");
            lock (writeGate)
            {
                File.WriteAllText(tmp, sb.ToString(), Utf8);
                try { if (File.Exists(dst)) File.Replace(tmp, dst, null); else File.Move(tmp, dst); }
                catch { File.Copy(tmp, dst, true); }
            }
        }

        /// <summary>The last request of the main menu's MPFever window: seq, command, argument, player name (or null).</summary>
        public string[] ReadMenuRequest()
        {
            try
            {
                var f = Path.Combine(Dir, "menu_req.txt");
                if (!File.Exists(f)) return null;
                var line = File.ReadAllText(f, Utf8).Trim('\r', '\n');
                var parts = line.Split('\t');
                return parts.Length >= 4 ? parts : null;
            }
            catch { return null; }
        }

        public event Action Exited;

        public void ToGame(Msg m)
        {
            lock (writeGate)
            {
                var b = Utf8.GetBytes(m + "\n");
                using (var fs = new FileStream(inPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                    fs.Write(b, 0, b.Length);
            }
        }

        /// <summary>Autotest: savegame loaded by the autopilot script (null = the player loads one).</summary>
        public static string AutoSave;

        public void Kill()
        {
            try { if (proc != null && !proc.HasExited) proc.Kill(); } catch { }
        }

        public void Launch(string gameDir)
        {
            var exe = Path.Combine(gameDir, "TransportFever3.exe");
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = gameDir };
            psi.EnvironmentVariables["MPFEVER_DIR"] = Dir;
            psi.EnvironmentVariables["MPFEVER_NAME"] = Name;
            psi.EnvironmentVariables["MPFEVER_ROLE"] = Role;
            psi.EnvironmentVariables["MPFEVER_LANG"] = L.Code;
            WriteLang();
            // application script: starts the host's savegame after a resynchronisation (and loads the autotest save)
            psi.Arguments = "--script mpfever_1::/mpfever_auto.lua";
            if (AutoSave != null) psi.EnvironmentVariables["MPFEVER_SAVE"] = AutoSave;
            proc = Process.Start(psi);
            proc.EnableRaisingEvents = true;
            proc.Exited += (s, e) => Exited?.Invoke();
            // experiment (MPFEVER_AFFINITY=mask): pin the game to some CPU cores
            var aff = Environment.GetEnvironmentVariable("MPFEVER_AFFINITY");
            if (!string.IsNullOrEmpty(aff)) try { proc.ProcessorAffinity = (IntPtr)Convert.ToInt64(aff, 16); } catch (Exception e) { Log.W("affinity: " + e.Message); }
            Log.W(L.F("[{0}] jeu lancé (pid {1}), session {2}", "[{0}] game started (pid {1}), session {2}", Name, proc.Id, Dir));
        }

        void Poll()
        {
            // two producers inside the game: the game-script bridge (out.log) and the UI hook (ui.log)
            var sources = new[] { new Tail(outPath) }; // the game script forwards the UI hook's actions itself, in order with its clock
            while (!stop)
            {
                foreach (var src in sources)
                {
                    try
                    {
                        foreach (var line in src.ReadLines())
                        {
                            var m = Msg.Parse(line);
                            if (m != null) FromGame?.Invoke(this, m);
                        }
                    }
                    catch (Exception e) { Log.W($"[{Name}] lecture {Path.GetFileName(src.Path)} : {e.Message}"); Thread.Sleep(500); }
                }
                Thread.Sleep(5);
            }
        }

        sealed class Tail
        {
            public readonly string Path;
            long off;
            readonly List<byte> pending = new List<byte>();
            public Tail(string path) { Path = path; }

            public IEnumerable<string> ReadLines()
            {
                var lines = new List<string>();
                if (!File.Exists(Path)) return lines;
                using (var fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length < off) { off = 0; pending.Clear(); }
                    if (fs.Length > off)
                    {
                        fs.Seek(off, SeekOrigin.Begin);
                        var buf = new byte[fs.Length - off];
                        int n = fs.Read(buf, 0, buf.Length);
                        off += n;
                        for (int k = 0; k < n; k++)
                        {
                            if (buf[k] == 10) { lines.Add(Utf8.GetString(pending.ToArray()).TrimEnd((char)13)); pending.Clear(); }
                            else pending.Add(buf[k]);
                        }
                    }
                }
                return lines;
            }
        }

        public void Dispose() { stop = true; }
    }

    sealed class Peer
    {
        public int Id;
        public string Name;
        public TcpClient Tcp;
        public StreamWriter Writer;
        public readonly object Gate = new object();
    }

    /// <summary>Host side: accepts TCP clients and relays every message to everybody else.</summary>
    sealed class Relay : IDisposable
    {
        TcpListener listener;
        readonly List<Peer> peers = new List<Peer>();
        int nextId = 1;
        volatile bool stop;

        public event Action<Peer, Msg> Received;
        public event Action<Peer> Joined, Left;

        public int Count { get { lock (peers) return peers.Count; } }

        public void Start(int port)
        {
            listener = new TcpListener(IPAddress.Any, port);
            listener.Start();
            new Thread(AcceptLoop) { IsBackground = true, Name = "Relay accept" }.Start();
            Log.W(L.F("Hôte : écoute TCP sur le port {0}", "Host: listening on TCP port {0}", port));
        }

        void AcceptLoop()
        {
            while (!stop)
            {
                try
                {
                    var c = listener.AcceptTcpClient();
                    c.NoDelay = true;
                    var p = new Peer { Id = nextId++, Tcp = c, Writer = new StreamWriter(c.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true } };
                    p.Name = "joueur" + p.Id;
                    lock (peers) peers.Add(p);
                    Log.Dim(L.F("Connexion entrante de {0} (id {1})", "Incoming connection from {0} (id {1})", c.Client.RemoteEndPoint, p.Id));
                    new Thread(() => ReadLoop(p)) { IsBackground = true, Name = "Relay peer " + p.Id }.Start();
                }
                catch (Exception e) { if (!stop) Log.W("accept: " + e.Message); }
            }
        }

        void ReadLoop(Peer p)
        {
            try
            {
                var r = new StreamReader(p.Tcp.GetStream(), new UTF8Encoding(false));
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    var m = Msg.Parse(line);
                    if (m == null) continue;
                    if (m.Kind == "join")
                    {
                        p.Name = Sanitize(m.From) + "#" + p.Id;
                        Joined?.Invoke(p);
                        continue;
                    }
                    m.From = p.Name; // the relay decides who is speaking; the host decides who receives it
                    Received?.Invoke(p, m);
                }
            }
            catch (Exception e) { if (!stop) Log.W($"{p.Name} : {e.Message}"); }
            lock (peers) peers.Remove(p);
            Left?.Invoke(p);
        }

        static string Sanitize(string s)
        {
            var t = new string((s ?? "").Where(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '-').ToArray());
            return t.Length == 0 ? "joueur" : (t.Length > 24 ? t.Substring(0, 24) : t);
        }

        /// <summary>A player who comes back (reconnection) under the same name: the old connection, which may still look
        /// alive after a network cut, is closed.</summary>
        public void DropOlder(Peer p)
        {
            string Base(string n) { int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }
            Peer[] all;
            lock (peers) all = peers.ToArray();
            foreach (var o in all)
                if (o != p && Base(o.Name) == Base(p.Name))
                {
                    Log.Warn(L.F("{0} : ancienne connexion fermée (reconnexion)", "{0}: old connection closed (reconnection)", o.Name));
                    try { o.Tcp.Close(); } catch { }
                }
        }

        public void Send(Peer p, Msg m)
        {
            try { lock (p.Gate) p.Writer.WriteLine(m.ToString()); }
            catch (Exception e) { Log.Warn(L.F("envoi vers {0} : {1}", "sending to {0}: {1}", p.Name, e.Message)); }
        }

        public void Broadcast(Msg m, Peer except = null)
        {
            Peer[] all;
            lock (peers) all = peers.ToArray();
            foreach (var p in all) if (p != except) Send(p, m);
        }

        public void Dispose()
        {
            stop = true;
            try { listener?.Stop(); } catch { }
            lock (peers) foreach (var p in peers) try { p.Tcp.Close(); } catch { }
        }
    }

    /// <summary>Client side: one TCP connection to the host.</summary>
    sealed class Client : IDisposable
    {
        TcpClient tcp;
        StreamWriter writer;
        readonly object gate = new object();
        volatile bool stop;
        public event Action<Msg> Received;
        public event Action Closed;

        public void Connect(string host, int port, string name)
        {
            tcp = new TcpClient { NoDelay = true };
            tcp.Connect(host, port);
            writer = new StreamWriter(tcp.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
            Send(Msg.Make("join", name));
            new Thread(ReadLoop) { IsBackground = true, Name = "Client read" }.Start();
            Log.Ok(L.F("Client : connecté à {0}:{1}", "Client: connected to {0}:{1}", host, port));
        }

        void ReadLoop()
        {
            try
            {
                var r = new StreamReader(tcp.GetStream(), new UTF8Encoding(false));
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    var m = Msg.Parse(line);
                    if (m != null) Received?.Invoke(m);
                }
            }
            catch (Exception e) { if (!stop) Log.W("client : " + e.Message); }
            Closed?.Invoke();
        }

        public void Send(Msg m)
        {
            try { lock (gate) writer.WriteLine(m.ToString()); }
            catch (Exception e) { Log.Warn(L.T("envoi vers l'hôte : ", "sending to the host: ") + e.Message); }
        }

        public void Dispose() { stop = true; try { tcp?.Close(); } catch { } }
    }

    static class GameInstall
    {
        public const string AppId = "3493540";

        public static string FindGameDir()
        {
            // 1. launcher placed inside the game folder (MPFever\...)
            var d = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (d != null)
            {
                if (File.Exists(Path.Combine(d.FullName, "TransportFever3.exe"))) return d.FullName;
                d = d.Parent;
            }
            // 2. Steam libraries
            foreach (var lib in SteamLibraries())
            {
                var p = Path.Combine(lib, "steamapps", "common", "Transport Fever 3");
                if (File.Exists(Path.Combine(p, "TransportFever3.exe"))) return p;
            }
            return null;
        }

        /// <summary>The game's language as written by the game or Steam (raw value, see L.Normalize), and where it was
        /// found: "game" (the language chosen in the game's options: profile.lua, language = { code = "de" }) or "steam"
        /// (the language Steam uses for the game, appmanifest_3493540.acf). Null when neither has one.</summary>
        public static string GameLanguage(out string where)
        {
            where = null;
            var steam = SteamPath();
            if (steam == null) return null;
            // 1. the game's own option: the most recently written profile.lua of the Steam users of this computer
            try
            {
                var userdata = Path.Combine(steam, "userdata");
                if (Directory.Exists(userdata))
                {
                    var files = Directory.GetDirectories(userdata)
                        .SelectMany(u => new[] { Path.Combine(u, AppId, "local", "profile.lua"), Path.Combine(u, AppId, "local", "settings.lua") })
                        .Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).ToList();
                    foreach (var f in files)
                    {
                        var code = LanguageInLua(File.ReadAllText(f));
                        if (code != null) { where = "game"; return code; }
                    }
                }
            }
            catch { }
            // 2. Steam's language for the game (Properties > General > Language)
            foreach (var lib in SteamLibraries())
            {
                try
                {
                    var acf = Path.Combine(lib, "steamapps", "appmanifest_" + AppId + ".acf");
                    if (!File.Exists(acf)) continue;
                    var m = System.Text.RegularExpressions.Regex.Match(File.ReadAllText(acf), @"""language""\s+""([^""]+)""");
                    if (m.Success) { where = "steam"; return m.Groups[1].Value; }
                }
                catch { }
            }
            return null;
        }

        /// <summary>The language code in the game's profile.lua (language = { code = "de", mod = { "" } }), or a plain
        /// language = "de" line; null when there is none.</summary>
        public static string LanguageInLua(string text)
        {
            var m = System.Text.RegularExpressions.Regex.Match(text, @"(?s)\blanguage\s*=\s*\{.{0,300}?\bcode\s*=\s*""([^""]+)""");
            if (!m.Success) m = System.Text.RegularExpressions.Regex.Match(text, @"(?m)^\s*(?:language|lang|locale)\s*=\s*""([^""]+)""");
            return m.Success && L.Normalize(m.Groups[1].Value) != null ? m.Groups[1].Value : null;
        }

        public static string SteamPath()
        {
            try { return (Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string)?.Replace('/', Path.DirectorySeparatorChar); }
            catch { return null; }
        }

        static IEnumerable<string> SteamLibraries()
        {
            var steam = SteamPath();
            if (steam == null) yield break;
            yield return steam;
            var vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf)) yield break;
            foreach (var line in File.ReadAllLines(vdf))
            {
                var t = line.Trim();
                if (!t.StartsWith("\"path\"")) continue;
                var parts = t.Split('"');
                if (parts.Length >= 4) yield return parts[3].Replace(@"\\", @"\");
            }
        }

        /// <summary>Allows direct launches (and several instances) without Steam restarting the game.</summary>
        public static void EnsureSteamAppId(string gameDir)
        {
            var f = Path.Combine(gameDir, "steam_appid.txt");
            if (!File.Exists(f)) { File.WriteAllText(f, AppId); Log.W(L.T("steam_appid.txt créé dans le dossier du jeu", "steam_appid.txt created in the game folder")); }
        }

        public static string FindModSource()
        {
            var d = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (d != null)
            {
                var m = Path.Combine(d.FullName, "mod", "mpfever_1");
                if (File.Exists(Path.Combine(m, "mod.json"))) return m;
                d = d.Parent;
            }
            return null;
        }

        /// <summary>Copies the mod into every Steam user's TF3 mods folder.</summary>
        public static int InstallMod()
        {
            var src = FindModSource();
            var steam = SteamPath();
            if (src == null || steam == null) { Log.Err(L.T("Mod ou Steam introuvable, installation du mod ignorée", "Mod or Steam not found, mod installation skipped")); return 0; }
            int n = 0;
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return 0;
            foreach (var u in Directory.GetDirectories(userdata))
            {
                var local = Path.Combine(u, AppId, "local");
                if (!Directory.Exists(local)) continue;
                var dst = Path.Combine(local, "mods", "mpfever_1");
                if (Directory.Exists(dst)) Directory.Delete(dst, true); // mirror: drop files removed from the mod
                CopyDir(src, dst);
                n++;
                Log.Ok(L.T("Mod installé dans ", "Mod installed in ") + dst);
            }
            return n;
        }

        /// <summary>Adds the mod to the game's default mod selection (settings.lua, mainMenuState.activeModsState), so
        /// that every new game includes it. Only while the game is closed (it rewrites settings.lua on exit).</summary>
        public static void EnsureModActive()
        {
            if (Process.GetProcessesByName("TransportFever3").Length > 0) return;
            var steam = SteamPath();
            if (steam == null) return;
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return;
            foreach (var u in Directory.GetDirectories(userdata))
            {
                var f = Path.Combine(u, AppId, "local", "settings.lua");
                if (!File.Exists(f)) continue;
                var s = File.ReadAllText(f);
                int i = s.IndexOf("activeModsState = {", StringComparison.Ordinal);
                if (i < 0) continue;
                int open = s.IndexOf('{', i), close = s.IndexOf('}', open);
                if (close < 0) continue;
                if (s.Substring(open, close - open).Contains("\"mpfever_1\"")) continue;
                var bak = f + ".bak_mpfever";
                if (!File.Exists(bak)) File.Copy(f, bak);
                s = s.Substring(0, open + 1) + " \"mpfever_1\"," + s.Substring(open + 1);
                File.WriteAllText(f, s);
                Log.Ok(L.T("Mod activé pour les nouvelles parties (", "Mod enabled for new games (") + f + ")");
            }
        }

        /// <summary>Puts the native module next to the game as winhttp.dll: the game imports WINHTTP.dll and Windows
        /// looks in the game folder first, so the game loads the module itself at startup (it relays every WinHTTP
        /// call to the system library, and stays inert unless the game was started by MPFever).</summary>
        public static void InstallNative(string gameDir)
        {
            var src = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "winhttp.dll");
            var dst = Path.Combine(gameDir, "winhttp.dll");
            // a game started by Steam from an MPFever invitation starts MPFever.exe from this path
            try { File.WriteAllText(Path.Combine(gameDir, "mpfever_path.txt"), System.Reflection.Assembly.GetExecutingAssembly().Location, Encoding.Unicode); } catch (Exception e) { Log.W("mpfever_path.txt: " + e.Message); }
            if (!File.Exists(src)) { Log.Warn(L.T("winhttp.dll absent à côté de MPFever.exe : module natif non installé", "winhttp.dll missing next to MPFever.exe: native module not installed")); return; }
            if (File.Exists(dst))
            {
                var cur = File.ReadAllBytes(dst);
                if (cur.SequenceEqual(File.ReadAllBytes(src))) return;
                if (Encoding.ASCII.GetString(cur).IndexOf("mpfever_native", StringComparison.Ordinal) < 0)
                {
                    Log.Warn(L.T("Un autre winhttp.dll (autre mod ?) est déjà dans le dossier du jeu : module natif non installé", "Another winhttp.dll (another mod?) is already in the game folder: native module not installed"));
                    return;
                }
            }
            try
            {
                File.Copy(src, dst, true);
                Log.Ok(L.T("Module natif installé : ", "Native module installed: ") + dst);
            }
            catch (IOException) { Log.Warn(L.T("Module natif : fermez Transport Fever 3 puis relancez MPFever pour le mettre à jour", "Native module: close Transport Fever 3, then restart MPFever to update it")); }
        }

        /// <summary>The savegame folders of every Steam user of this PC (created if missing).</summary>
        public static List<string> SaveDirs()
        {
            var dirs = new List<string>();
            var steam = SteamPath();
            if (steam == null) return dirs;
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return dirs;
            foreach (var u in Directory.GetDirectories(userdata))
            {
                var local = Path.Combine(u, AppId, "local");
                if (!Directory.Exists(local)) continue;
                var save = Path.Combine(local, "save");
                Directory.CreateDirectory(save);
                dirs.Add(save);
            }
            return dirs;
        }

        /// <summary>The most recent file of a savegame (name.sav), or null.</summary>
        public static string FindSave(string name)
        {
            return SaveDirs().Select(d => Path.Combine(d, name + ".sav")).Where(File.Exists)
                .OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
        }

        static void CopyDir(string src, string dst)
        {
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true);
            foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
        }
    }
}
