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

    /// <summary>One protocol message: kind TAB from TAB payload (payload = single-line Lua table literal). A message whose
    /// kind ends with "_bin" (0.5.0: the host's savegame) carries Data, raw bytes right after its line (their count in the
    /// payload's "len"): a quarter less to send than the base64 parts of before.</summary>
    sealed class Msg
    {
        public string Kind, From, Payload;
        public byte[] Data;
        public bool IsBinary => Kind != null && Kind.EndsWith("_bin", StringComparison.Ordinal);

        public static Msg Parse(string line)
        {
            if (string.IsNullOrEmpty(line)) return null;
            var p = line.Split(new[] { '\t' }, 3);
            if (p.Length < 3) return null;
            return new Msg { Kind = p[0], From = p[1], Payload = p[2] };
        }

        public static Msg Make(string kind, string from, string payload = "{}") => new Msg { Kind = kind, From = from, Payload = payload };

        /// <summary>A binary message: its payload gets the bytes' count ("len").</summary>
        public static Msg MakeBinary(string kind, string from, string fields, byte[] data, int offset, int count)
        {
            var d = new byte[count];
            Buffer.BlockCopy(data, offset, d, 0, count);
            return new Msg { Kind = kind, From = from, Payload = "{" + fields + (fields.Length > 0 ? "," : "") + "[\"len\"]=" + count + "}", Data = d };
        }

        public override string ToString() => Kind + "\t" + From + "\t" + Payload;

        /// <summary>Writes the message on a connection (its line, then its bytes for a binary one). The caller holds the
        /// connection's lock.</summary>
        public void WriteTo(StreamWriter w)
        {
            w.WriteLine(ToString());
            if (Data != null)
            {
                w.Flush();
                w.BaseStream.Write(Data, 0, Data.Length);
                w.BaseStream.Flush();
            }
        }
    }

    /// <summary>Reads a connection's messages: UTF-8 lines, and the raw bytes after the line of a binary message (a
    /// StreamReader cannot: its buffer takes them).</summary>
    sealed class NetReader
    {
        readonly Stream s;
        readonly byte[] buf = new byte[1 << 16];
        int pos, count;
        public NetReader(Stream s) { this.s = s; }

        bool Fill()
        {
            if (pos < count) return true;
            pos = 0;
            count = s.Read(buf, 0, buf.Length);
            return count > 0;
        }

        public string ReadLine()
        {
            var line = new MemoryStream();
            while (true)
            {
                // (a line the end of the connection cut is not a message: its sender still has it, and sends it again)
                if (!Fill()) return null;
                int start = pos;
                while (pos < count && buf[pos] != (byte)'\n') pos++;
                line.Write(buf, start, pos - start);
                if (pos < count) { pos++; break; }
            }
            var bytes = line.ToArray();
            int n = bytes.Length;
            if (n > 0 && bytes[n - 1] == (byte)'\r') n--;
            return Encoding.UTF8.GetString(bytes, 0, n);
        }

        public byte[] ReadBytes(int n)
        {
            if (n < 0 || n > 64 << 20) throw new IOException("binary message of " + n + " bytes");
            var d = new byte[n];
            int got = 0;
            while (got < n)
            {
                if (!Fill()) throw new IOException("connection closed in a binary message");
                int k = Math.Min(n - got, count - pos);
                Buffer.BlockCopy(buf, pos, d, got, k);
                pos += k; got += k;
            }
            return d;
        }

        /// <summary>The next message (null at the end of the connection; a line that is no message is skipped).</summary>
        public Msg Read()
        {
            while (true)
            {
                string line = ReadLine();
                if (line == null) return null;
                var m = Msg.Parse(line);
                if (m == null) continue;
                if (m.IsBinary)
                {
                    int len = LuaLit.Parse(m.Payload) is Dictionary<object, object> t && t.TryGetValue("len", out var lv) && lv is double ld ? (int)ld : -1;
                    m.Data = ReadBytes(len);
                }
                return m;
            }
        }
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
            // (compared in place: a copy of the rest of the text at every value made a station's 850 KB build take 30 s to read,
            // and the reader of that player's messages, their clock among them, stood still meanwhile: issue #54)
            if (string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(s, i, "nil", 0, 3) == 0) { i += 3; return null; }
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
        volatile bool stop;
        Thread poll;
        Process proc;

        public event Action<GameLink, Msg> FromGame;

        public GameLink(string name, string role)
        {
            Name = name;
            Role = role;
            // (the folder's name in ASCII as well: the player's name goes to the game in identity.txt)
            var folder = new string((name ?? "").Select(c => c < 128 && (char.IsLetterOrDigit(c) || c == '-' || c == '_') ? c : '_').ToArray());
            Dir = Path.Combine(SessionRoot(), folder + "-" + DateTime.Now.ToString("HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(Dir);
            inPath = Path.Combine(Dir, "in.log");
            outPath = Path.Combine(Dir, "out.log");
            File.WriteAllText(inPath, "");
            File.WriteAllText(outPath, "");
            poll = new Thread(Poll) { IsBackground = true, Name = "GameLink " + name };
            poll.Start();
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int GetShortPathNameW(string longPath, StringBuilder shortPath, int size);

        static bool IsAscii(string s) => s.All(c => c < 128);

        /// <summary>Folder of the session folders. The game's Lua cannot open a path with letters outside ASCII: with a
        /// Windows account named "Thöny" (the temporary folder is in the account's folder) no file of the session could be
        /// read or written by the mod, and the game had no multiplayer page (issue #59). Such a temporary folder is used by
        /// its short name (C:\Users\MAXEMI~1\...), or else replaced by an ASCII folder shared by the PC's accounts.</summary>
        public static string SessionRoot()
        {
            var temp = Path.Combine(Path.GetTempPath(), "mpfever");
            if (IsAscii(temp)) return temp;
            try
            {
                Directory.CreateDirectory(temp);
                var sb = new StringBuilder(1024);
                int n = GetShortPathNameW(temp, sb, sb.Capacity);
                if (n > 0 && n < sb.Capacity && IsAscii(sb.ToString())) return sb.ToString();
            }
            catch { }
            foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), Environment.GetEnvironmentVariable("PUBLIC") })
            {
                if (string.IsNullOrEmpty(root) || !IsAscii(root)) continue;
                try
                {
                    var dir = Path.Combine(root, "MPFever", "sessions");
                    Directory.CreateDirectory(dir);
                    File.WriteAllText(Path.Combine(dir, "write_test.txt"), "");
                    File.Delete(Path.Combine(dir, "write_test.txt"));
                    return dir;
                }
                catch { }
            }
            Log.Warn(L.T("Le dossier temporaire contient des lettres que le jeu ne sait pas lire : le mod risque de ne pas fonctionner (", "The temporary folder has letters the game cannot read: the mod may not work (") + temp + ")");
            return temp;
        }

        public bool GameRunning => proc != null && !proc.HasExited;
        /// <summary>The game's main window (0 when unknown): the autotests move the mouse over it.</summary>
        public IntPtr Window { get { try { if (proc == null || proc.HasExited) return IntPtr.Zero; proc.Refresh(); return proc.MainWindowHandle; } catch { return IntPtr.Zero; } } }

        /// <summary>The game of a dedicated server (MPFever.exe --server): the mod knows it from MPFEVER_SERVER=1 and plays
        /// no company of its own there.</summary>
        public bool Server;

        /// <summary>A dedicated server started without display: the native module hides the game's window, does not draw the
        /// world and silences it (MPFEVER_HEADLESS=1).</summary>
        public bool Headless;

        /// <summary>Name and role chosen in the main menu, read by the mod when the game loads (identity.txt).</summary>
        public void SetIdentity(string name, string role)
        {
            Name = name;
            Role = role;
            File.WriteAllText(Path.Combine(Dir, "identity.txt"), "name=" + name + "\nrole=" + role + "\n", Utf8);
        }

        /// <summary>State shown by the MPFever window of the game's main menu (menu_state.txt, key=value lines).</summary>
        /// <summary>The settings of the settings window for the mod (settings.txt, read when a game loads): the session's
        /// (the host's once received) and this player's own. Not written for the autotests (their variables decide).</summary>
        public void WriteSettings()
        {
            if (Options.Disabled) return;
            try { lock (writeGate) File.WriteAllText(Path.Combine(Dir, "settings.txt"), Options.ModFile(), Utf8); }
            catch (Exception e) { Log.W("settings.txt: " + e.Message); }
            // (their names in this player's language, for the Settings tab of the in-game MPFever window)
            try { lock (writeGate) File.WriteAllText(Path.Combine(Dir, "settings_info.txt"), Options.InfoFile(), Utf8); }
            catch (Exception e) { Log.W("settings_info.txt: " + e.Message); }
        }

        /// <summary>The texts of the current language for the mod (lang.txt, read by its Lua code).</summary>
        public void WriteLang()
        {
            try { lock (writeGate) File.WriteAllText(Path.Combine(Dir, "lang.txt"), L.ModTable(), Utf8); }
            catch (Exception e) { Log.W("lang.txt: " + e.Message); }
        }

        /// <summary>The session as the in-game MPFever window shows it (mp_status.txt: key=value lines and one
        /// "p=id TAB name TAB state TAB lag TAB role" line per player), replaced in one go.</summary>
        public void WriteStatus(string text)
        {
            var tmp = Path.Combine(Dir, "mp_status.tmp");
            var dst = Path.Combine(Dir, "mp_status.txt");
            lock (writeGate)
            {
                File.WriteAllText(tmp, text, Utf8);
                try { if (File.Exists(dst)) File.Replace(tmp, dst, null); else File.Move(tmp, dst); }
                catch { File.Copy(tmp, dst, true); }
            }
        }

        public void WriteMenuState(IDictionary<string, string> st)
        {
            var sb = new StringBuilder();
            foreach (var kv in st) sb.Append(kv.Key).Append('=').Append((kv.Value ?? "").Replace("\r", " ").Replace("\n", " ")).Append('\n');
            // the last line: the menu takes a state only when it reads it (a file read while being written is not taken)
            sb.Append("end=1\n");
            var tmp = Path.Combine(Dir, "menu_state.tmp");
            var dst = Path.Combine(Dir, "menu_state.txt");
            lock (writeGate)
            {
                File.WriteAllText(tmp, sb.ToString(), Utf8);
                // (the game may be reading it: a few tries of the swap, which the menu never sees half done, before a copy)
                for (int i = 0; ; i++)
                {
                    try { if (File.Exists(dst)) File.Replace(tmp, dst, null); else File.Move(tmp, dst); break; }
                    catch
                    {
                        if (i < 4) { Thread.Sleep(15); continue; }
                        File.Copy(tmp, dst, true);
                        break;
                    }
                }
            }
        }

        long chatOutOff;

        /// <summary>The messages written in the in-game chat since the last call (chat_out.txt, appended by the mod: one
        /// "seq TAB text" line per message).</summary>
        public List<string> ReadChatOut()
        {
            var res = new List<string>();
            try
            {
                var f = Path.Combine(Dir, "chat_out.txt");
                if (!File.Exists(f)) return res;
                using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length < chatOutOff) chatOutOff = 0;
                    if (fs.Length == chatOutOff) return res;
                    fs.Seek(chatOutOff, SeekOrigin.Begin);
                    var buf = new byte[fs.Length - chatOutOff];
                    int n = 0;
                    while (n < buf.Length) { int r = fs.Read(buf, n, buf.Length - n); if (r <= 0) break; n += r; }
                    int last = n > 0 ? Array.LastIndexOf(buf, (byte)'\n', n - 1) : -1;
                    if (last < 0) return res;   // a line still being written
                    chatOutOff += last + 1;
                    foreach (var raw in Utf8.GetString(buf, 0, last + 1).Split('\n'))
                    {
                        var line = raw.TrimEnd('\r');
                        int tab = line.IndexOf('\t');
                        if (tab >= 0) line = line.Substring(tab + 1);
                        if (line.Trim().Length > 0) res.Add(line);
                    }
                }
            }
            catch { }
            return res;
        }

        /// <summary>A line of the in-game chat (chat.txt, read by the mod): id TAB unix time TAB kind (msg, join, left,
        /// unsent) TAB player TAB text.</summary>
        public void AppendChat(long id, long time, string kind, string name, string text)
        {
            string Clean(string s) => (s ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
            try
            {
                lock (writeGate)
                    File.AppendAllText(Path.Combine(Dir, "chat.txt"), id + "\t" + time + "\t" + Clean(kind) + "\t" + Clean(name) + "\t" + Clean(text) + "\n", Utf8);
            }
            catch (Exception e) { Log.W("chat.txt: " + e.Message); }
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
            // the native module's places by signature, for a game build it does not know (made by tools/mksigs.py)
            var sigs = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mpfever_sigs.txt");
            if (File.Exists(sigs)) psi.EnvironmentVariables["MPFEVER_SIGS"] = sigs;
            if (Server) psi.EnvironmentVariables["MPFEVER_SERVER"] = "1";
            if (Headless) psi.EnvironmentVariables["MPFEVER_HEADLESS"] = "1";
            WriteLang();
            WriteSettings();
            // application script: starts the host's savegame after a resynchronisation (and loads the autotest save)
            psi.Arguments = "--script mpfever_1::/mpfever_auto.lua";
            if (AutoSave != null) psi.EnvironmentVariables["MPFEVER_SAVE"] = AutoSave;
            GameInstall.DiagEnv(psi.EnvironmentVariables);
            // tests: settings for one game only, MPFEVER_ENV_HOST / MPFEVER_ENV_CLIENT = "NAME=value;NAME=value"
            var roleEnv = Environment.GetEnvironmentVariable("MPFEVER_ENV_" + (Role ?? "").ToUpperInvariant());
            if (!string.IsNullOrEmpty(roleEnv))
                foreach (var kv in roleEnv.Split(';'))
                {
                    int eq = kv.IndexOf('=');
                    if (eq > 0) psi.EnvironmentVariables[kv.Substring(0, eq).Trim()] = kv.Substring(eq + 1);
                }
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
                    catch (Exception e) { Log.Warn(L.F("[{0}] lecture {1} : {2}", "[{0}] reading {1}: {2}", Name, Path.GetFileName(src.Path), e.Message)); src.Dispose(); Thread.Sleep(500); }
                }
                LogMemory();
                Thread.Sleep(5);
            }
            foreach (var src in sources) src.Dispose();
        }

        DateTime memAt = DateTime.MinValue;
        /// <summary>Every 5 minutes, the game's memory in the launcher's log: the frame rate of a long session fell by
        /// three quarters after the fifth resynchronisation (two games on one PC, issue #50), each reload of a 165 MB
        /// savegame may keep some of the game's memory.</summary>
        void LogMemory()
        {
            if ((DateTime.UtcNow - memAt).TotalMinutes < 5) return;
            memAt = DateTime.UtcNow;
            try
            {
                if (proc == null || proc.HasExited) return;
                proc.Refresh();
                Log.W(L.F("[{0}] mémoire du jeu : {1} Mo privés, {2} Mo en mémoire vive (pointe {3} Mo)", "[{0}] game memory: {1} MB private, {2} MB in RAM (peak {3} MB)",
                    Name, proc.PrivateMemorySize64 >> 20, proc.WorkingSet64 >> 20, proc.PeakWorkingSet64 >> 20));
            }
            catch { }
        }

        /// <summary>The lines a game appends to a file. The file stays open: an open of a file another program has just
        /// written waits for the antivirus to read it again (about 9 ms with Windows Defender, and its processor time), and
        /// this one is read 200 times a second.</summary>
        sealed class Tail : IDisposable
        {
            public readonly string Path;
            long off;
            FileStream fs;
            readonly List<byte> pending = new List<byte>();
            public Tail(string path) { Path = path; }

            public IEnumerable<string> ReadLines()
            {
                var lines = new List<string>();
                if (fs == null)
                {
                    if (!File.Exists(Path)) return lines;
                    fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                }
                long len = fs.Length;
                if (len < off) { off = 0; pending.Clear(); }
                if (len > off)
                {
                    fs.Seek(off, SeekOrigin.Begin);
                    var buf = new byte[len - off];
                    int n = fs.Read(buf, 0, buf.Length);
                    off += n;
                    for (int k = 0; k < n; k++)
                    {
                        if (buf[k] == 10) { lines.Add(Utf8.GetString(pending.ToArray()).TrimEnd((char)13)); pending.Clear(); }
                        else pending.Add(buf[k]);
                    }
                }
                return lines;
            }

            public void Dispose() { fs?.Dispose(); fs = null; }
        }

        public void Dispose() { stop = true; }
    }

    /// <summary>The session's messages between the host and one player, numbered at both ends, so that a player whose
    /// connection dropped for a while (Wi-Fi, a router, a Steam relay) comes back into the same session: each end keeps what
    /// it sent until the other says it has it ("~ack"), and a player back within the grace gets what it missed, in order,
    /// instead of the host's game sent again and loaded by everybody. "join", "denied", "resumed" and the link's own
    /// messages (kinds starting with "~") are not counted.</summary>
    sealed class SessionLink
    {
        /// <summary>Above this, waiting for the other end, the link cannot be resumed: the player joins again as before.</summary>
        public const long MaxOutBytes = 64L << 20;
        public string Token;
        long tx, rx, outBytes;
        readonly Queue<KeyValuePair<long, Msg>> outbox = new Queue<KeyValuePair<long, Msg>>();
        bool overflowed;
        /// <summary>More than MaxOutBytes wait for the other end now (or twice that once: then nothing more is kept).</summary>
        public bool Broken { get { lock (outbox) return overflowed || outBytes > MaxOutBytes; } }

        public static bool IsControl(string kind) => kind == "join" || kind == "denied" || kind == "resumed" || kind == "steamtun" || kind == "bulk"
            || (kind != null && kind.StartsWith("~", StringComparison.Ordinal));

        public static string NewToken()
        {
            var b = new byte[16];
            using (var r = System.Security.Cryptography.RandomNumberGenerator.Create()) r.GetBytes(b);
            return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant();
        }

        public long Rx => Interlocked.Read(ref rx);
        public long Tx { get { lock (outbox) return tx; } }
        public int Pending { get { lock (outbox) return outbox.Count; } }

        /// <summary>A message given to the link (written now, or later after a cut): numbered and kept until acknowledged.</summary>
        public void Sent(Msg m)
        {
            lock (outbox)
            {
                tx++;
                if (overflowed) return;
                outbox.Enqueue(new KeyValuePair<long, Msg>(tx, m));
                outBytes += Size(m);
                // (an end that never acknowledges: nothing kept from here on, the link cannot go on after a cut)
                if (outBytes > 2 * MaxOutBytes) { overflowed = true; outbox.Clear(); outBytes = 0; }
            }
        }

        public void Received() => Interlocked.Increment(ref rx);

        /// <summary>The other end has every message up to n.</summary>
        public void Ack(long n)
        {
            lock (outbox) while (outbox.Count > 0 && outbox.Peek().Key <= n) outBytes -= Size(outbox.Dequeue().Value);
        }

        /// <summary>The messages after n (the other end has those up to n), in order.</summary>
        public List<Msg> After(long n) { lock (outbox) return outbox.Where(kv => kv.Key > n).Select(kv => kv.Value).ToList(); }

        /// <summary>The link starts again from nothing (a player that joined again as a new one).</summary>
        public void Reset(string token)
        {
            lock (outbox) { tx = 0; outbox.Clear(); outBytes = 0; overflowed = false; }
            Interlocked.Exchange(ref rx, 0);
            Token = token;
        }

        static long Size(Msg m) => (m.Payload?.Length ?? 0) + (m.Data?.Length ?? 0) + 64;
        public static Msg AckMsg(long n) => Msg.Make("~ack", "-", "{[\"n\"]=" + n + "}");
        public static long ReadN(Msg m, string key = "n") => LuaLit.Parse(m.Payload) is Dictionary<object, object> t && t.TryGetValue(key, out var v) && v is double d ? (long)d : -1;

        /// <summary>How long a player whose connection dropped is waited for (MPFEVER_RESUMEGRACE, seconds; 0 or
        /// MPFEVER_RESUME=0: not waited for, it joins again as before).</summary>
        public static double Grace
        {
            get
            {
                if (Environment.GetEnvironmentVariable("MPFEVER_RESUME") == "0") return 0;
                return double.TryParse(Environment.GetEnvironmentVariable("MPFEVER_RESUMEGRACE"), NumberStyles.Float, CultureInfo.InvariantCulture, out var g) ? Math.Max(0, g) : 60;
            }
        }
    }

    /// <summary>One more Steam connection of a player, for the host's game only (savegame parts, SendParts): Steam limits each
    /// connection's rate, several carry it faster (design: 3.7). It carries no session message and is never a player.</summary>
    sealed class BulkLink
    {
        public TcpClient Tcp;
        public StreamWriter Writer;
        public readonly object Gate = new object();
        public volatile bool Dead;
        public int Index;
    }

    sealed class Peer
    {
        public int Id;
        public string Name;
        public TcpClient Tcp;
        public StreamWriter Writer;
        public readonly object Gate = new object();
        /// <summary>The player was let in (its "join" accepted): only then does it receive and send session messages.</summary>
        public volatile bool Admitted;
        public string Address;
        /// <summary>The session's messages with this player (numbered from its admission), see SessionLink.</summary>
        public SessionLink Link;
        /// <summary>Its connection dropped and the host waits for it to come back (Relay.Away): what is sent to it is kept.</summary>
        public volatile bool Away;
        public DateTime AwaySince;
        /// <summary>When it last sent anything; and whether it acknowledges (an older MPFever does not: no watchdog then).</summary>
        public long LastRecvTicks;
        public volatile bool Acks;
        /// <summary>Its connection is closed on purpose (refused, kicked, replaced by a new join): it is not waited for.</summary>
        public volatile bool NoWait;
        /// <summary>The connection the watchdog cut (once).</summary>
        public TcpClient CutTcp;
        /// <summary>The player came through Steam (its game's module tunnels it to the Relay): its Steam id.</summary>
        public string SteamId;
        /// <summary>A Steam bulk connection, not a player (its first lines: steamtun kind=bulk, then "bulk" with the player's link).</summary>
        public volatile bool IsBulk;
        /// <summary>This player's bulk connections (Steam), live ones.</summary>
        public readonly List<BulkLink> Bulk = new List<BulkLink>();
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
        /// <summary>A player's connection dropped and the host waits for it (MayWait said so): it stays a player, its clock
        /// holds every game where it stopped, and what is sent to it is kept. Back within the grace: Resumed (seconds away,
        /// messages it got again); else Left.</summary>
        public event Action<Peer> Away;
        public event Action<Peer, double, int> Resumed;
        public Func<Peer, bool> MayWait;
        public double Grace = 60;
        /// <summary>The secret the host's game module writes in the first line of every Steam tunnel it opens to this Relay
        /// (SteamNet): a connection that says "steamtun" is let in only from this PC with it. Null: no Steam tunnel.</summary>
        public string SteamSecret;

        /// <summary>Decides whether a player who says "join" may come in (a dedicated server checks its password, its
        /// version and the number of players): null lets it in, otherwise the payload of the "denied" message it receives
        /// before its connection is closed. Unset: everybody comes in.</summary>
        public Func<Peer, Msg, string> Admit;

        public int Count { get { lock (peers) return peers.Count; } }

        /// <summary>The players let in, connected right now.</summary>
        public int AdmittedCount { get { lock (peers) return peers.Count(p => p.Admitted); } }

        /// <summary>The players connected right now (name#id), including those whose game is not ready yet.</summary>
        public string[] PeerNames() { lock (peers) return peers.Where(p => In(p) && p.Name != null).Select(p => p.Name).ToArray(); }

        /// <summary>A connection that takes part in the session: every one, unless an Admit rule decides (then the players
        /// it let in only).</summary>
        bool In(Peer p) => p.Admitted || Admit == null;

        /// <summary>The players connected right now, with their address.</summary>
        public Peer[] Admitted() { lock (peers) return peers.Where(p => p.Admitted).ToArray(); }

        /// <summary>The player of this name (name#id) taking part in the session, or null.</summary>
        public Peer Find(string name) { lock (peers) return peers.FirstOrDefault(p => In(p) && p.Name == name); }

        /// <summary>(0.6, the autotest pubtest) the port it listens on; 0 before Start.</summary>
        public int Port { get { try { return (listener?.LocalEndpoint as IPEndPoint)?.Port ?? 0; } catch { return 0; } } }

        public void Start(int port)
        {
            // IPv4 and IPv6 on one socket (players behind DS-Lite, without a public IPv4 of their own, are reached over
            // IPv6); IPv4 only where the PC has no IPv6
            try
            {
                listener = new TcpListener(IPAddress.IPv6Any, port);
                listener.Server.DualMode = true;
                listener.Start();
            }
            catch (Exception)
            {
                try { listener?.Stop(); } catch { }
                listener = new TcpListener(IPAddress.Any, port);
                listener.Start();
            }
            new Thread(AcceptLoop) { IsBackground = true, Name = "Relay accept" }.Start();
            new Thread(LinkLoop) { IsBackground = true, Name = "Relay links" }.Start();
            Log.W(L.F("Hôte : écoute TCP sur le port {0}", "Host: listening on TCP port {0}", port));
        }

        /// <summary>Twice a second: every player is told what the host has received from it (at least every 2 s, which also
        /// shows the link is alive); a player silent for 15 s is cut (Windows takes 20 to 45 s to notice a dead link); a
        /// player away for longer than the grace leaves.</summary>
        void LinkLoop()
        {
            var told = new Dictionary<Peer, KeyValuePair<long, DateTime>>();
            while (!stop)
            {
                Thread.Sleep(500);
                var now = DateTime.UtcNow;
                Peer[] all;
                lock (peers) all = peers.Where(q => q.Admitted && q.Link != null).ToArray();
                foreach (var q in all)
                {
                    if (q.Away)
                    {
                        if ((now - q.AwaySince).TotalSeconds > Grace) Finalize(q, L.T("pas revenu à temps", "not back in time"));
                        continue;
                    }
                    if (q.Acks && (now.Ticks - Interlocked.Read(ref q.LastRecvTicks)) / TimeSpan.TicksPerSecond > 15 && q.Tcp != null && q.Tcp != q.CutTcp)
                    {
                        // (also frees a writer blocked on that connection)
                        Log.Warn(L.F("{0} : plus rien reçu depuis 15 s, connexion coupée", "{0}: nothing received for 15 s, connection cut", q.Name));
                        q.CutTcp = q.Tcp;
                        NetAddr.Cut(q.Tcp);
                        continue;
                    }
                    long rx = q.Link.Rx;
                    if ((!told.TryGetValue(q, out var t) || t.Key != rx || (now - t.Value).TotalSeconds >= 2) && Monitor.TryEnter(q.Gate))
                    {
                        // (a writer busy on this player's connection - a savegame part on a slow link - delays its ack, not the others')
                        try { if (!q.Away) { SessionLink.AckMsg(rx).WriteTo(q.Writer); told[q] = new KeyValuePair<long, DateTime>(rx, now); } }
                        catch { }
                        finally { Monitor.Exit(q.Gate); }
                    }
                }
                foreach (var q in told.Keys.Where(q => !all.Contains(q)).ToList()) told.Remove(q);
            }
        }

        /// <summary>A player the host waited for leaves the session (the grace ran out, a resynchronisation starts, or it
        /// joined again as a new player).</summary>
        public void Finalize(Peer q, string why)
        {
            lock (q.Gate) lock (peers) { if (!q.Away || !peers.Remove(q)) return; q.Away = false; q.NoWait = true; }
            Log.Warn(L.F("{0} : plus attendu ({1})", "{0}: no longer waited for ({1})", q.Name, why));
            Left?.Invoke(q);
        }

        /// <summary>Every player the host waits for leaves (a resynchronisation replaces their world: they join again).</summary>
        public void FinalizeAway(string why)
        {
            Peer[] away;
            lock (peers) away = peers.Where(q => q.Away).ToArray();
            foreach (var q in away) Finalize(q, why);
        }

        /// <summary>The players the host waits for, with the seconds since their connection dropped.</summary>
        public Dictionary<string, double> AwayNames()
        {
            lock (peers) return peers.Where(q => q.Away && q.Name != null).ToDictionary(q => q.Name, q => (DateTime.UtcNow - q.AwaySince).TotalSeconds);
        }

        void AcceptLoop()
        {
            while (!stop)
            {
                try
                {
                    var c = listener.AcceptTcpClient();
                    c.NoDelay = true;
                    NetAddr.KeepAlive(c);
                    var p = new Peer { Id = nextId++, Tcp = c, Writer = new StreamWriter(c.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true } };
                    p.Name = "Player" + p.Id;
                    try { p.Address = c.Client.RemoteEndPoint?.ToString(); } catch { }
                    lock (peers) peers.Add(p);
                    Log.Dim(L.F("Connexion entrante de {0} (id {1})", "Incoming connection from {0} (id {1})", c.Client.RemoteEndPoint, p.Id));
                    new Thread(() => ReadLoop(p)) { IsBackground = true, Name = "Relay peer " + p.Id }.Start();
                }
                catch (Exception e) { if (!stop) Log.W("accept: " + e.Message); }
            }
        }

        void ReadLoop(Peer first)
        {
            var p = first;           // the player this connection speaks for: another one once it resumes a player's link
            var tcp = first.Tcp;     // this connection
            string endWhy = null;
            try
            {
                var r = new NetReader(tcp.GetStream());
                Msg m;
                while ((m = r.Read()) != null)
                {
                    Interlocked.Exchange(ref p.LastRecvTicks, DateTime.UtcNow.Ticks);
                    if (m.Kind == "steamtun")
                    {
                        // a player through Steam: the host's own game module, which carries it (first line only)
                        if (p.Admitted || p.SteamId != null || !SteamTunnel(p, m)) break;
                        continue;
                    }
                    if (p.IsBulk)
                    {
                        // (a bulk connection: its one line names the player's link; it then only carries the host's savegame parts)
                        if (m.Kind == "bulk") { AttachBulk(p, tcp, m); return; }
                        break;
                    }
                    if (p.Tcp != tcp) break;   // (the player went on over a newer connection)
                    if (m.Kind == "~ack") { p.Acks = true; long n = SessionLink.ReadN(m); if (n >= 0) p.Link?.Ack(n); continue; }
                    // (the player leaves on purpose: not waited for)
                    if (m.Kind == "~bye") { p.NoWait = true; continue; }
                    if (m.Kind.StartsWith("~", StringComparison.Ordinal)) continue;
                    if (m.Kind == "join")
                    {
                        if (p.Admitted) continue;
                        var back = Resume(p, m);
                        if (back != null) { p = back; continue; }
                        p.Name = Sanitize(m.From) + "#" + p.Id;
                        string refused = null;
                        try { refused = Admit?.Invoke(p, m); }
                        catch (Exception e) { Log.W("admit: " + e.Message); }
                        if (refused != null) { Deny(p, refused); break; }
                        // (a player the host waited for, back as a new one: it left)
                        Peer[] waited;
                        lock (peers) waited = peers.Where(q => q != p && q.Away && BaseOf(q.Name) == BaseOf(p.Name)).ToArray();
                        foreach (var q in waited) Finalize(q, L.T("revenu comme un nouveau joueur", "back as a new player"));
                        p.Link = new SessionLink { Token = SessionLink.NewToken() };
                        p.Admitted = true;
                        Joined?.Invoke(p);
                        continue;
                    }
                    if (!In(p)) continue;   // nothing counts before the player is let in
                    m.From = p.Name; // the relay decides who is speaking; the host decides who receives it
                    // (counted under the player's lock, which a claim takes to move the player to its new connection)
                    if (p.Link != null) lock (p.Gate) { if (p.Tcp != tcp) break; p.Link.Received(); }
                    Received?.Invoke(p, m);
                }
            }
            catch (Exception e) { if (!stop && In(p)) Log.W($"{p.Name} : {e.Message}"); endWhy = e.Message; }
            // (0.6.7) a connection that ends before it joined said nothing: a join by Steam whose tunnel closed at once left only
            // "incoming connection from 127.0.0.1" in the host's log (2026-11-01 00:49:30). MPFEVER_QUIETCLOSE=1: as before
            if (!stop && p == first && !p.Admitted && !p.IsBulk && Environment.GetEnvironmentVariable("MPFEVER_QUIETCLOSE") != "1")
                Log.Warn(L.F("Connexion {0} (id {1}) fermée avant de rejoindre la session ({2})", "Connection {0} (id {1}) closed before joining the session ({2})",
                    p.Address, p.Id, endWhy ?? (p.SteamId == null ? L.T("rien reçu : pour Steam, voir native.log du jeu de l'hôte", "nothing received: for Steam, see the host game's native.log") : L.T("tunnel Steam ouvert, pas de demande de connexion", "Steam tunnel open, no join request"))));
            Ended(p, tcp);
        }

        /// <summary>The first line of a Steam tunnel: from this PC (the host's game module dials the Relay), with the session's
        /// secret; then the connection is that Steam player's (its join comes next). Anything else is closed.</summary>
        bool SteamTunnel(Peer p, Msg m)
        {
            var t = SteamNet.TunnelLine(m);
            bool local = false;
            try { var ep = p.Tcp.Client.RemoteEndPoint as IPEndPoint; local = ep != null && (IPAddress.IsLoopback(ep.Address) || (ep.Address.IsIPv4MappedToIPv6 && IPAddress.IsLoopback(ep.Address.MapToIPv4()))); } catch { }
            string k = t != null && t.TryGetValue("k", out var kv) ? kv as string : null;
            string kind = t != null && t.TryGetValue("kind", out var kd) ? kd as string : null;
            string who = m.From ?? "";
            bool idOk = SteamNet.IsSteamId("steam:" + who, out _) || (who.StartsWith("ip:", StringComparison.Ordinal) && SteamNet.TestIpPort > 0);
            var secret = SteamSecret;
            if (!local || secret == null || k == null || k.Length != secret.Length || !idOk || (kind != "main" && kind != "bulk")
                || !k.Select((c, i) => c == secret[i]).Aggregate(true, (a, b) => a & b))
            {
                Log.Warn(L.F("Connexion Steam refusée ({0})", "Steam connection refused ({0})", !local ? "not local" : secret == null ? "no secret" : !idOk ? "id" : kind != "main" ? "kind " + kind : "secret"));
                return false;
            }
            p.SteamId = who;
            p.IsBulk = kind == "bulk";
            p.Address = "steam:" + who + " (" + SteamNet.RouteText(t) + ")";
            Log.Dim(L.F("Connexion entrante par Steam de {0} ({1})", "Incoming connection through Steam from {0} ({1})", who, SteamNet.RouteText(t)));
            return true;
        }

        /// <summary>A Steam bulk connection named its player's link (tok): it joins that player's bulk connections until it ends.</summary>
        void AttachBulk(Peer conn, TcpClient tcp, Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            string tok = t != null && t.TryGetValue("tok", out var tv) ? tv as string : null;
            int index = t != null && t.TryGetValue("i", out var iv) && iv is double d ? (int)d : 0;
            Peer owner;
            lock (peers)
            {
                peers.Remove(conn);
                owner = string.IsNullOrEmpty(tok) ? null : peers.FirstOrDefault(q => q.Admitted && q.Link != null && q.Link.Token == tok);
            }
            if (owner == null) { Log.Warn(L.T("Connexion Steam supplémentaire refusée (joueur inconnu)", "Extra Steam connection refused (unknown player)")); NetAddr.Cut(tcp); return; }
            var b = new BulkLink { Tcp = tcp, Writer = conn.Writer, Index = index };
            lock (owner.Bulk) owner.Bulk.Add(b);
            Log.Dim(L.F("{0} : connexion Steam supplémentaire n°{1} pour les parties envoyées", "{0}: extra Steam connection #{1} for the games sent", owner.Name, index));
            try { var r = new NetReader(tcp.GetStream()); while (!stop && r.Read() != null) { } } catch { }
            b.Dead = true;
            lock (owner.Bulk) owner.Bulk.Remove(b);
            NetAddr.Cut(tcp);
        }

        /// <summary>A player's live bulk connections.</summary>
        public BulkLink[] BulkOf(Peer p) { lock (p.Bulk) return p.Bulk.Where(b => !b.Dead).ToArray(); }

        /// <summary>A connection ended. Its player is waited for when MayWait says so (Away), otherwise it leaves (Left);
        /// nothing when the player went on over a newer connection (it came back before this one was noticed dead).</summary>
        void Ended(Peer p, TcpClient tcp)
        {
            try { tcp.Close(); } catch { }
            bool wait = false, gone = false;
            lock (peers)
            {
                if (p.Tcp != tcp) return;
                if (!stop && !p.NoWait && p.Admitted && p.Link != null && !p.Link.Broken && Grace > 0 && MayWaitFor(p))
                {
                    if (!p.Away) p.AwaySince = DateTime.UtcNow;   // (still away: its connection back died while it was told what it missed)
                    p.Away = true;
                    wait = true;
                }
                else gone = peers.Remove(p);
            }
            if (wait) Away?.Invoke(p);
            else if (gone && In(p)) Left?.Invoke(p);
        }

        bool MayWaitFor(Peer p)
        {
            try { return MayWait != null && MayWait(p); }
            catch (Exception e) { Log.W("resume: " + e.Message); return false; }
        }

        /// <summary>A join that asks to go on with a link ("resume" = {tok, rx}): the player of that link takes this connection
        /// (the old one, if it still looked alive, is closed), is told what the host received from it ("resumed", rx), gets every
        /// message after the last it has, in order, and is a player of the session again; all under the player's lock, so that no
        /// message slips in between. Null: a plain join (unknown, gone, kicked, too much waiting, or more acknowledged than sent).
        /// If writing fails, the player is waited for again.</summary>
        Peer Resume(Peer conn, Msg join)
        {
            if (!(LuaLit.Parse(join.Payload) is Dictionary<object, object> t) || !t.TryGetValue("resume", out var rv) || !(rv is Dictionary<object, object> rc)) return null;
            string tok = rc.TryGetValue("tok", out var tv) ? tv as string : null;
            long rx = rc.TryGetValue("rx", out var xv) && xv is double xd ? (long)xd : -1;
            if (string.IsNullOrEmpty(tok) || rx < 0) return null;
            Peer old;
            lock (peers) old = peers.FirstOrDefault(q => q != conn && q.Admitted && q.Link != null && q.Link.Token == tok);
            string why = old == null ? L.T("inconnu ou parti", "unknown or gone") : null;
            TcpClient prev = null;
            int n = 0;
            double away = 0;
            if (old != null)
                lock (old.Gate)
                {
                    lock (peers)
                    {
                        if (!peers.Contains(old) || old.NoWait) why = L.T("inconnu ou parti", "unknown or gone");
                        else if (old.Link.Broken) why = L.T("trop de messages en attente", "too many messages waiting");
                        else if (rx > old.Link.Tx) why = "rx";
                        else { peers.Remove(conn); prev = old.Tcp; old.Tcp = conn.Tcp; }
                    }
                    if (why == null)
                    {
                        bool wasAway = old.Away;
                        old.Away = true;   // (until it has what it missed: what is sent to it meanwhile is only kept)
                        if (!wasAway) old.AwaySince = DateTime.UtcNow;
                        old.Writer = conn.Writer;
                        old.Address = conn.Address;
                        old.Acks = conn.Acks;
                        old.SteamId = conn.SteamId;
                        Interlocked.Exchange(ref old.LastRecvTicks, DateTime.UtcNow.Ticks);
                        away = wasAway ? (DateTime.UtcNow - old.AwaySince).TotalSeconds : 0;
                        old.Link.Ack(rx);
                        var missed = old.Link.After(rx);
                        Msg.Make("resumed", "MPFever", "{[\"rx\"]=" + old.Link.Rx + "}").WriteTo(old.Writer);
                        foreach (var m in missed) m.WriteTo(old.Writer);
                        n = missed.Count;
                        old.Away = false;
                    }
                }
            if (why != null)
            {
                Log.Warn(L.F("{0} : reprise de la session impossible ({1}), il la rejoint comme un nouveau joueur", "{0}: the session cannot go on ({1}), it joins it as a new player", Sanitize(join.From), why));
                return null;
            }
            if (prev != null && prev != old.Tcp) NetAddr.Cut(prev);   // (a connection that still looked alive: taken over)
            Log.Ok(L.F("{0} est revenu après {1:0} s : la session continue ({2} message(s) envoyé(s) à nouveau)", "{0} is back after {1:0} s: the session goes on ({2} message(s) sent again)", old.Name, away, n));
            Resumed?.Invoke(old, away, n);
            return old;
        }

        static string BaseOf(string n) { if (n == null) return ""; int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }

        /// <summary>Tells a player why it may not stay ("denied", payload: { reason = "...", ... }), then closes its
        /// connection (its MPFever does not reconnect).</summary>
        public void Deny(Peer p, string payload)
        {
            p.NoWait = true;
            Send(p, Msg.Make("denied", "MPFever", payload));
            try { p.Tcp.Client.Shutdown(SocketShutdown.Send); } catch { }
            Thread.Sleep(300);   // (closed at once, the message could be lost with the connection)
            try { p.Tcp.Close(); } catch { }
        }

        /// <summary>Closes the connections of a player known by its name (without #id, any case): it is told why first.
        /// Returns how many connections were closed.</summary>
        public int Kick(string name, string payload)
        {
            string Base(string n) { int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }
            var found = Admitted().Where(p => string.Equals(Base(p.Name), name, StringComparison.OrdinalIgnoreCase) || p.Name == name).ToList();
            foreach (var p in found)
            {
                // (a player the host waits for has no connection: it leaves now, and may not come back with its link)
                if (p.Away) { p.NoWait = true; Finalize(p, L.T("exclu", "kicked")); continue; }
                new Thread(() => Deny(p, payload)) { IsBackground = true, Name = "Kick " + p.Id }.Start();
            }
            return found.Count;
        }

        static string Sanitize(string s)
        {
            var t = new string((s ?? "").Where(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '-').ToArray());
            return t.Length == 0 ? "Player" : (t.Length > 24 ? t.Substring(0, 24) : t);
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
                    o.NoWait = true;
                    NetAddr.Cut(o.Tcp);
                }
        }

        public void Send(Peer p, Msg m) => TrySend(p, m);

        /// <summary>Sends, and says whether it went (a closed connection: false). A session message goes into the player's
        /// link first: to a player the host waits for, it is only kept there (it gets it when it comes back).</summary>
        public bool TrySend(Peer p, Msg m)
        {
            try
            {
                lock (p.Gate)
                {
                    bool counted = p.Link != null && !SessionLink.IsControl(m.Kind);
                    if (counted) p.Link.Sent(m);
                    if (p.Away) return counted;
                    m.WriteTo(p.Writer);
                }
                return true;
            }
            catch (Exception e) { if (!p.Away) Log.Warn(L.F("envoi vers {0} : {1}", "sending to {0}: {1}", p.Name, e.Message)); return false; }
        }

        public void Broadcast(Msg m, Peer except = null)
        {
            Peer[] all;
            lock (peers) all = peers.Where(In).ToArray();   // (a connection not let in gets nothing, a savegame least of all)
            foreach (var p in all) if (p != except) Send(p, m);
        }

        public void Dispose()
        {
            stop = true;
            try { listener?.Stop(); } catch { }
            lock (peers) foreach (var p in peers) NetAddr.Cut(p.Tcp);
        }
    }

    /// <summary>Client side: one TCP connection to the host.</summary>
    sealed class Client : IDisposable
    {
        TcpClient tcp;
        StreamWriter writer;
        readonly object gate = new object();
        volatile bool stop;
        /// <summary>This player's session messages with the host, kept across its connections (see SessionLink).</summary>
        public readonly SessionLink Link;
        /// <summary>The join asked the host to go on with the link: the session's messages wait until it answers.</summary>
        volatile bool claimPending;
        long lastRecvTicks = DateTime.UtcNow.Ticks;
        volatile bool hostAcks;
        public event Action<Msg> Received;
        public event Action Closed;
        /// <summary>The host went on with this player's link after a cut ("resumed"): no welcome, no reload.</summary>
        public event Action Resumed;
        /// <summary>The host answered a claim with a plain welcome: the link starts again from nothing (what waited is lost).</summary>
        public event Action ResumeRefused;

        public Client(SessionLink link = null) { Link = link ?? new SessionLink(); }
        /// <summary>The host refused this player (wrong password, server full, other version, kicked): raised with the
        /// "denied" payload, before Closed.</summary>
        public event Action<Dictionary<object, object>> Denied;
        /// <summary>(0.6) The host lets every arrival in by hand: this player waits for its answer ("admitwait", every 3 s
        /// before its welcome; not a message of the session's link).</summary>
        public event Action Waiting;

        /// <summary>Connects to the host. host may list several addresses (a Steam invitation gives the host's IPv4 and
        /// IPv6 addresses, "1.2.3.4:28090,[2a02:...]:28090"); each one may carry its port, else port. IPv6 is tried first:
        /// a host behind DS-Lite is only reachable that way. On a PC without IPv6 those attempts fail at once: the error
        /// then names the other attempts first and ends with one short note on IPv6 (issue #31).
        /// The password is the one of a dedicated server (none: null); the join also tells this MPFever's version
        /// (a dedicated server only lets in its own).</summary>
        public void Connect(string host, int port, string name, string password = null, bool resume = false)
        {
            // "steam:<id>" entries: through the host's Steam (the game's module, SteamNet), tried at the same time as the
            // addresses; a direct connection is taken when there is one (no rate limit), unless Steam was 1.5 s faster
            var specs = (host ?? "").Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).ToList();
            var steamIds = specs.Where(x => SteamNet.IsSteamId(x, out _)).Select(x => x.Substring(6)).Distinct().ToList();
            var plain = string.Join(",", specs.Where(x => !x.StartsWith("steam:", StringComparison.OrdinalIgnoreCase)));
            if (Environment.GetEnvironmentVariable("MPFEVER_JOINSTEAM") == "1" && steamIds.Count > 0) plain = "";   // (tests: Steam only)
            var errors = new List<string>();
            string used = null;
            bool trySteam = steamIds.Count > 0 && SteamDir != null && SteamNet.Enabled;
            if (steamIds.Count > 0 && !trySteam) errors.Add("Steam : " + (SteamNet.Enabled ? L.T("pas de jeu pour s'y connecter", "no game to connect through") : L.T("désactivé", "turned off")));
            if (!trySteam)
            {
                tcp = ConnectTcp(plain, port, errors, out used);
                if (tcp == null) throw new IOException(errors.Count > 0 ? string.Join("  |  ", errors) : L.T("adresse vide", "empty address"));
            }
            else
            {
                var tcpErrors = new List<string>();
                string tcpUsed = null, steamUsed = null, steamErr = null;
                var tcpTask = plain.Length == 0 ? null : System.Threading.Tasks.Task.Run(() => ConnectTcp(plain, port, tcpErrors, out tcpUsed));
                var steamTask = System.Threading.Tasks.Task.Run(() =>
                {
                    try { return ConnectSteam(steamIds[0], out steamUsed); }
                    catch (Exception e) { steamErr = e.Message; return null; }
                });
                DateTime? steamAt = null;
                while (true)
                {
                    bool tcpDone = tcpTask == null || tcpTask.IsCompleted, steamDone = steamTask.IsCompleted;
                    var tcpRes = tcpTask != null && tcpTask.IsCompleted ? tcpTask.Result : null;
                    var steamRes = steamDone ? steamTask.Result : null;
                    if (steamRes != null && steamAt == null) steamAt = DateTime.UtcNow;
                    if (tcpRes != null) { tcp = tcpRes; used = tcpUsed; break; }
                    if (steamRes != null && (tcpDone || (DateTime.UtcNow - steamAt.Value).TotalSeconds >= 1.5)) { tcp = steamRes; used = steamUsed; break; }
                    if (tcpDone && steamDone) break;
                    Thread.Sleep(50);
                }
                // (the other way goes, when it connects later too)
                var won = tcp;
                steamTask.ContinueWith(t => { if (t.Result != null && t.Result != won) { SteamCancel(); NetAddr.Cut(t.Result); } });
                if (tcpTask != null) tcpTask.ContinueWith(t => { if (t.Result != null && t.Result != won) NetAddr.Cut(t.Result); });
                if (tcp == null)
                {
                    errors.AddRange(tcpErrors);
                    errors.Add("Steam : " + (steamErr ?? "?"));
                    throw new IOException(string.Join("  |  ", errors));
                }
                if (!(steamTask.IsCompleted && steamTask.Result == tcp)) steamReader = null;
            }
            writer = new StreamWriter(tcp.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
            // (back after a cut, with the link of a session the host let this player into: the host goes on with it if it
            // still waits for this player)
            string claim = "";
            if (resume && !string.IsNullOrEmpty(Link.Token) && !Link.Broken)
            {
                claim = ",[\"resume\"]={[\"tok\"]=" + LuaLit.Quote(Link.Token) + ",[\"rx\"]=" + Link.Rx + "}";
                claimPending = true;
            }
            else Link.Reset(null);   // (a new player: the host counts from this join; what waited is dropped)
            myName = name;
            Send(Msg.Make("join", name, "{[\"v\"]=" + LuaLit.Quote(MainForm.Version)
                + (string.IsNullOrEmpty(password) ? "" : ",[\"pw\"]=" + LuaLit.Quote(password)) + claim + "}"));
            new Thread(ReadLoop) { IsBackground = true, Name = "Client read" }.Start();
            new Thread(LinkLoop) { IsBackground = true, Name = "Client link" }.Start();
            viaSteam = used != null && used.StartsWith("steam:", StringComparison.Ordinal);
            Log.Ok(L.F("Client : connecté à {0}", "Client: connected to {0}", used));
        }

        /// <summary>The first address of the list that answers (IPv6 first), or null with the errors.</summary>
        static TcpClient ConnectTcp(string host, int port, List<string> errors, out string usedText)
        {
            usedText = null;
            var targets = new List<IPEndPoint>();
            foreach (var t in NetAddr.Parse(host, port))
            {
                if (IPAddress.TryParse(t.Key, out var ip)) { targets.Add(new IPEndPoint(ip, t.Value)); continue; }
                try { foreach (var a in Dns.GetHostAddresses(t.Key)) targets.Add(new IPEndPoint(a, t.Value)); }
                catch (Exception e) { errors.Add(NetAddr.Show(t.Key, t.Value) + " : " + e.Message); }
            }
            targets = targets.Where(e => e.AddressFamily == AddressFamily.InterNetworkV6).Concat(targets.Where(e => e.AddressFamily != AddressFamily.InterNetworkV6)).ToList();
            bool noIPv6 = false;   // an IPv6 address failed because this PC has no IPv6
            foreach (var ep in targets)
            {
                TcpClient c = null;
                try
                {
                    c = new TcpClient(ep.AddressFamily) { NoDelay = true };   // fails at once on a PC without IPv6
                    var task = c.ConnectAsync(ep.Address, ep.Port);
                    if (!task.Wait(TimeSpan.FromSeconds(targets.Count > 1 ? 8 : 20))) throw new TimeoutException(L.T("pas de réponse", "no answer"));
                    NetAddr.KeepAlive(c);
                    usedText = NetAddr.Show(ep.Address.ToString(), ep.Port);
                    return c;
                }
                catch (Exception e)
                {
                    try { c?.Close(); } catch { }
                    var inner = e is AggregateException ae && ae.InnerException != null ? ae.InnerException : e;
                    // no route to IPv6 or IPv6 turned off: this PC has no IPv6, not an error of the host. Its long Windows
                    // message per address came first and hid the reason of the IPv4 attempt ("host unreachable" stays an
                    // error of the host)
                    if (ep.AddressFamily == AddressFamily.InterNetworkV6 && inner is SocketException se
                        && (se.SocketErrorCode == SocketError.NetworkUnreachable || se.SocketErrorCode == SocketError.AddressFamilyNotSupported))
                        noIPv6 = true;
                    else
                        errors.Add(NetAddr.Show(ep.Address.ToString(), ep.Port) + " : " + inner.Message);
                }
            }
            // (after the other errors, and kept: for a host only reachable over IPv6 it is the reason)
            if (noIPv6) errors.Add(L.T("IPv6 : indisponible sur ce PC", "IPv6: not available on this PC"));
            return null;
        }

        /// <summary>The game whose module carries this player's Steam connection (its session folder), or null.</summary>
        public string SteamDir;
        NetReader steamReader;
        string steamCid, steamSid, myName;
        static int steamCids;
        readonly List<TcpClient> bulk = new List<TcpClient>();

        /// <summary>How many extra Steam connections a player opens for the host's savegame (MPFEVER_STEAMBULK, 0 to 8; 4).</summary>
        static int BulkWanted => int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_STEAMBULK"), out int k) ? Math.Max(0, Math.Min(8, k)) : 4;

        /// <summary>Through Steam, once the host named this player's link: the extra connections that carry the host's game
        /// (each Steam connection has its own rate: four together are about four times as fast). Their messages go to Received
        /// like the main connection's; they are not counted in the link.</summary>
        void OpenBulk()
        {
            if (steamSid == null || SteamDir == null || BulkWanted == 0 || string.IsNullOrEmpty(Link.Token)) return;
            lock (bulk) { bulk.RemoveAll(c => !c.Connected); if (bulk.Count > 0) return; }
            string tok = Link.Token;
            for (int i = 0; i < BulkWanted; i++)
            {
                int index = i;
                new Thread(() =>
                {
                    try
                    {
                        var c = ConnectSteamTunnel(steamSid, SteamNet.MainPort + 1, "bulk", out var reader, out _, out _);
                        if (stop) { NetAddr.Cut(c); return; }
                        lock (bulk) bulk.Add(c);
                        var w = new StreamWriter(c.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
                        Msg.Make("bulk", myName ?? "", "{[\"tok\"]=" + LuaLit.Quote(tok) + ",[\"i\"]=" + index + "}").WriteTo(w);
                        Msg m;
                        while (!stop && (m = reader.Read()) != null)
                            if (m.IsBinary) Received?.Invoke(m);
                    }
                    catch (Exception e) { if (!stop) Log.W(L.F("Client : connexion Steam supplémentaire n°{0} : {1}", "Client: extra Steam connection #{0}: {1}", index, e.Message)); }
                }) { IsBackground = true, Name = "Client bulk " + index }.Start();
            }
        }

        /// <summary>A connection to the host's Steam id through this PC's game: its module connects over Steam (P2P or Steam's
        /// relays) and dials a one-shot loopback listener here, whose first line carries the nonce given to it.</summary>
        TcpClient ConnectSteam(string sid, out string usedText)
        {
            // (0.6.7) tried three times: a tunnel the host's game closed at once (its dial-back timed out, see Since in
            // mpf_steamnet.cpp) failed the join, with no line in the log and no second try (2026-11-01). MPFEVER_STEAMTRIES=1: once
            int tries = int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_STEAMTRIES"), out var nt) && nt >= 1 ? nt : 3;
            TcpClient c = null; NetReader reader = null; string cid = null;
            // (only a tunnel that failed quickly is tried again: one that waited for an answer in vain would only wait again)
            for (int a = 1; ; a++)
            {
                var t0 = DateTime.UtcNow;
                try { c = ConnectSteamTunnel(sid, SteamNet.MainPort, "main", out reader, out usedText, out cid); break; }
                catch (Exception e) when (a < tries && !stop && (DateTime.UtcNow - t0).TotalSeconds < 15)
                {
                    Log.Warn(L.F("Client : connexion par Steam, essai {0} sur {1} : {2}", "Client: connection through Steam, attempt {0} of {1}: {2}", a, tries, e.Message));
                    Thread.Sleep(1000);
                }
            }
            steamReader = reader;
            steamCid = cid;
            steamSid = sid;
            return c;
        }

        TcpClient ConnectSteamTunnel(string sid, int vport, string kind, out NetReader readerOut, out string usedText, out string cidOut)
        {
            usedText = null; readerOut = null; cidOut = null;
            if (!SteamNet.WaitReady(SteamDir, 120, out _, out string why)) throw new IOException(why);
            // (tests on one PC: the module's IP mode, once, by the main connection; a bulk one asking it again cut another's)
            int ipPort = SteamNet.TestIpPort;
            if (ipPort > 0 && kind == "main") SteamNet.Cmd(SteamDir, "ipmode connect 127.0.0.1:" + ipPort);
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            try
            {
                int local = ((IPEndPoint)listener.LocalEndpoint).Port;
                string nonce = SessionLink.NewToken();
                string cid = "c" + Process.GetCurrentProcess().Id + "-" + Interlocked.Increment(ref steamCids);
                cidOut = cid;
                SteamNet.Cmd(SteamDir, "connect " + cid + " " + sid + " " + vport + " " + local + " " + nonce + " " + kind);
                var accept = listener.AcceptTcpClientAsync();
                var end = DateTime.UtcNow.AddSeconds(45);
                while (!accept.Wait(250))
                {
                    var t = SteamNet.Tunnel(SteamDir, cid);
                    if (t != null && t.TryGetValue("state", out var state) && state == "closed")
                        throw new IOException(L.F("Steam a refusé ou perdu la connexion ({0} {1})", "Steam refused or lost the connection ({0} {1})",
                            t.TryGetValue("code", out var code) ? code : "?", t.TryGetValue("why", out var w) ? w : ""));
                    if (DateTime.UtcNow > end) { SteamNet.Cmd(SteamDir, "close " + cid); throw new TimeoutException(L.T("pas de réponse par Steam", "no answer through Steam")); }
                }
                var c = accept.Result;
                c.NoDelay = true;
                var reader = new NetReader(c.GetStream());
                var first = reader.Read();
                var f = SteamNet.TunnelLine(first);
                if (f == null || first.From != cid || !(f.TryGetValue("n", out var n) && n as string == nonce))
                {
                    NetAddr.Cut(c);
                    throw new IOException(L.T("tunnel Steam inattendu", "unexpected Steam tunnel"));
                }
                readerOut = reader;
                usedText = "steam:" + sid + " (" + SteamNet.RouteText(f) + ")";
                return c;
            }
            finally { try { listener.Stop(); } catch { } }
        }

        /// <summary>The Steam connection of this client, given up (another way won, or the client is closed).</summary>
        void SteamCancel()
        {
            var cid = steamCid;
            if (cid != null && SteamDir != null) try { SteamNet.Cmd(SteamDir, "close " + cid); } catch { }
        }

        void ReadLoop()
        {
            try
            {
                // (through Steam, the reader that took the tunnel's first line goes on: it may hold what came after it)
                var r = steamReader ?? new NetReader(tcp.GetStream());
                Msg m;
                while ((m = r.Read()) != null)
                {
                    Interlocked.Exchange(ref lastRecvTicks, DateTime.UtcNow.Ticks);
                    if (m.Kind == "~ack") { hostAcks = true; long n = SessionLink.ReadN(m); if (n >= 0) Link.Ack(n); continue; }
                    if (m.Kind.StartsWith("~", StringComparison.Ordinal)) continue;
                    if (m.Kind == "denied")
                    {
                        Denied?.Invoke(LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>());
                        continue;
                    }
                    if (m.Kind == "admitwait") { Waiting?.Invoke(); continue; }
                    if (m.Kind == "resumed")
                    {
                        // the host has this player's messages up to rx: the others, and those kept while the link was cut, go now
                        long rx = SessionLink.ReadN(m, "rx");
                        int n;
                        lock (gate)
                        {
                            Link.Ack(rx);
                            var again = Link.After(rx);
                            foreach (var x in again) x.WriteTo(writer);
                            n = again.Count;
                            claimPending = false;
                        }
                        Log.Ok(L.F("Client : la session continue ({0} message(s) envoyé(s) à nouveau)", "Client: the session goes on ({0} message(s) sent again)", n));
                        Resumed?.Invoke();
                        OpenBulk();
                        continue;
                    }
                    if (m.Kind == "welcome")
                    {
                        // a welcome names the link (after a claim the host could not take, it starts again from nothing: the
                        // messages kept for the host were never sent on this connection)
                        string tok = LuaLit.Parse(m.Payload) is Dictionary<object, object> w && w.TryGetValue("rtok", out var tv) ? tv as string : null;
                        bool refused;
                        lock (gate)
                        {
                            refused = claimPending;
                            if (refused) Link.Reset(tok);
                            else if (!string.IsNullOrEmpty(tok)) Link.Token = tok;   // (the welcomes after a world's load name none)
                            claimPending = false;
                        }
                        if (refused) { Log.Warn(L.T("Client : l'hôte n'attendait plus ce joueur : il rejoint la session comme un nouveau joueur", "Client: the host no longer waited for this player: it joins the session as a new player")); ResumeRefused?.Invoke(); }
                        OpenBulk();
                    }
                    // (a claim the host could not take: it let this player in as a new one, and a broadcast came before its welcome)
                    if (claimPending && !SessionLink.IsControl(m.Kind))
                    {
                        lock (gate) { Link.Reset(null); claimPending = false; }
                        Log.Warn(L.T("Client : l'hôte n'attendait plus ce joueur : il rejoint la session comme un nouveau joueur", "Client: the host no longer waited for this player: it joins the session as a new player"));
                        ResumeRefused?.Invoke();
                    }
                    Link.Received();
                    Received?.Invoke(m);
                }
            }
            catch (Exception e) { if (!stop) Log.W("client : " + e.Message); }
            stop = true;
            lock (bulk) { foreach (var c in bulk) NetAddr.Cut(c); bulk.Clear(); }
            Closed?.Invoke();
        }

        static int connections;
        bool viaSteam;

        /// <summary>(0.6.8, #115) How long the host may stay silent before the connection is cut: 15 s, 40 s through Steam.
        /// The Steam tunnel lives in the host's game, which can stay busy longer than 15 s with a world of 300 MB and more
        /// (saving it, sending it): a player was cut again and again while the host's game came down and after each reload.
        /// MPFEVER_SILENTCUT=s: s seconds; MPFEVER_STEAMSILENT=0: 15 s through Steam too, as before.</summary>
        internal static int SilentLimit(bool steam)
        {
            if (int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SILENTCUT"), NumberStyles.Integer, CultureInfo.InvariantCulture, out int s) && s > 0) return s;
            return steam && Environment.GetEnvironmentVariable("MPFEVER_STEAMSILENT") != "0" ? 40 : 15;
        }

        /// <summary>Twice a second the host is told what this player has received (at least every 2 s: the link is alive);
        /// a host silent for 15 s is cut. MPFEVER_TEST_CUT=s (tests): every connection is cut s seconds after it was made, the
        /// first one after MPFEVER_TEST_CUT_FIRST seconds (once the session runs).</summary>
        void LinkLoop()
        {
            long told = -1;
            var toldAt = DateTime.MinValue;
            var start = DateTime.UtcNow;
            double.TryParse(Environment.GetEnvironmentVariable("MPFEVER_TEST_CUT"), NumberStyles.Float, CultureInfo.InvariantCulture, out double cut);
            if (cut > 0 && Interlocked.Increment(ref connections) == 1
                && double.TryParse(Environment.GetEnvironmentVariable("MPFEVER_TEST_CUT_FIRST"), NumberStyles.Float, CultureInfo.InvariantCulture, out double first))
                cut = Math.Max(cut, first);
            while (!stop)
            {
                Thread.Sleep(500);
                var now = DateTime.UtcNow;
                long rx = Link.Rx;
                if (rx != told || (now - toldAt).TotalSeconds >= 2)
                {
                    told = rx; toldAt = now;
                    try { lock (gate) SessionLink.AckMsg(rx).WriteTo(writer); } catch { }
                }
                int silent = SilentLimit(viaSteam);
                if (hostAcks && (now.Ticks - Interlocked.Read(ref lastRecvTicks)) / TimeSpan.TicksPerSecond > silent)
                {
                    Log.Warn(L.F("Client : plus rien reçu de l'hôte depuis {0} s, connexion coupée", "Client: nothing received from the host for {0} s, connection cut", silent));
                    NetAddr.Cut(tcp);
                    break;
                }
                if (cut > 0 && (now - start).TotalSeconds >= cut)
                {
                    Log.Warn(L.F("Client : connexion coupée pour le test (MPFEVER_TEST_CUT={0})", "Client: connection cut for the test (MPFEVER_TEST_CUT={0})", cut));
                    NetAddr.Cut(tcp);
                    start = DateTime.MaxValue;
                }
            }
        }

        /// <summary>Sends a message to the host. A session message goes into the link first, and waits there while the host
        /// has not answered a claim (it goes after its "resumed", or is dropped by its plain welcome).</summary>
        public void Send(Msg m)
        {
            try
            {
                lock (gate)
                {
                    bool counted = !SessionLink.IsControl(m.Kind);
                    if (counted) Link.Sent(m);
                    if (counted && claimPending) return;
                    m.WriteTo(writer);
                }
            }
            catch (Exception e) { Log.Warn(L.T("envoi vers l'hôte : ", "sending to the host: ") + e.Message); }
        }

        /// <summary>Leaves the session on purpose: the host is told ("~bye"), it does not wait for this player.</summary>
        public void Leave()
        {
            try { lock (gate) Msg.Make("~bye", "-", "{}").WriteTo(writer); } catch { }
            Dispose();
        }

        public void Dispose()
        {
            stop = true;
            NetAddr.Cut(tcp);
            lock (bulk) { foreach (var c in bulk) NetAddr.Cut(c); bulk.Clear(); }
        }
    }

    /// <summary>MPFever's connections over Steam, carried by the game's own Steam (the native module, mpf_steamnet.cpp): no port to
    /// open on a router. The module tunnels each Steam connection to a loopback TCP connection it dials itself, whose first line is
    /// "steamtun": on the host, to the Relay's port with the session's secret; on a player's PC, to a one-shot listener of its
    /// Client with a nonce. Commands are appended to steamnet_cmd.txt in the game's session folder; the module rewrites
    /// steamnet_status.txt every 500 ms. MPFEVER_STEAMNET=0: no Steam connection (the module stays off too).
    /// MPFEVER_STEAMNET_IP=&lt;port&gt; (tests on one PC, where both games are one Steam account): the same tunnels over UDP on
    /// 127.0.0.1:&lt;port&gt; (Steam's own sockets, "ipmode").</summary>
    static class SteamNet
    {
        public const int MainPort = 28090;
        static long seq;
        static readonly object cmdGate = new object();
        public static bool Enabled => Environment.GetEnvironmentVariable("MPFEVER_STEAMNET") != "0";
        public static int TestIpPort => int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_STEAMNET_IP"), out int p) && p > 0 && p < 65535 ? p : 0;

        public static void Cmd(string dir, string line)
        {
            var path = Path.Combine(dir, "steamnet_cmd.txt");
            var text = Environment.TickCount + "-" + Interlocked.Increment(ref seq) + "\t" + line + "\r\n";
            var b = new UTF8Encoding(false).GetBytes(text);
            // (one writer at a time: FileMode.Append seeks to the end when the file opens, so two lines written at once - the
            // bulk connections are asked for together - landed on the same place and one was lost)
            lock (cmdGate)
                using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) fs.Write(b, 0, b.Length);
        }

        /// <summary>The module's status lines (the file is complete once its line "end=1" is read), or null.</summary>
        public static List<string> Status(string dir)
        {
            try
            {
                var path = Path.Combine(dir, "steamnet_status.txt");
                if (!File.Exists(path) || (DateTime.UtcNow - File.GetLastWriteTimeUtc(path)).TotalSeconds > 5) return null;
                string text;
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(fs, Encoding.UTF8)) text = r.ReadToEnd();
                var lines = text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).ToList();
                int end = lines.IndexOf("end=1");
                return end < 0 ? null : lines.Take(end).ToList();
            }
            catch { return null; }
        }

        /// <summary>The fields of a status line ("a=1 b=2 ... why=text to the end of the line").</summary>
        public static Dictionary<string, string> Fields(string line)
        {
            var d = new Dictionary<string, string>();
            int w = line.IndexOf(" why=", StringComparison.Ordinal);
            if (w >= 0) { d["why"] = line.Substring(w + 5); line = line.Substring(0, w); }
            else if (line.StartsWith("why=", StringComparison.Ordinal)) { d["why"] = line.Substring(4); line = ""; }
            foreach (var kv in line.Split(' '))
            {
                int e = kv.IndexOf('=');
                if (e > 0) d[kv.Substring(0, e)] = kv.Substring(e + 1);
            }
            return d;
        }

        /// <summary>This game's Steam networking: ready (its Steam id), or not (why), within the seconds given.</summary>
        public static bool WaitReady(string dir, double seconds, out string sid, out string why)
        {
            sid = null; why = L.T("le jeu ne répond pas (Steam pas encore prêt dans le jeu)", "the game does not answer (Steam not ready in the game yet)");
            var end = DateTime.UtcNow.AddSeconds(seconds);
            while (true)
            {
                var st = Status(dir);
                if (st != null && st.Count > 0)
                {
                    var f = Fields(st[0]);
                    if (f.TryGetValue("ready", out var rd))
                    {
                        if (rd == "1" && f.TryGetValue("sid", out sid) && sid.Length > 0) return true;
                        if (rd == "-1") { why = f.TryGetValue("why", out var w) ? w : "off"; return false; }
                    }
                }
                if (DateTime.UtcNow >= end) return false;
                Thread.Sleep(250);
            }
        }

        /// <summary>A tunnel's status line (t=&lt;id&gt;), or null.</summary>
        public static Dictionary<string, string> Tunnel(string dir, string id)
        {
            var st = Status(dir);
            var line = st?.FirstOrDefault(l => l.StartsWith("t=" + id + " ", StringComparison.Ordinal));
            return line == null ? null : Fields(line);
        }

        /// <summary>A Steam id as a player gives it: "steam:7656119..." (an individual account of the public universe).</summary>
        public static bool IsSteamId(string s, out ulong sid)
        {
            sid = 0;
            if (s == null || !s.StartsWith("steam:", StringComparison.OrdinalIgnoreCase)) return false;
            if (!ulong.TryParse(s.Substring(6), NumberStyles.None, CultureInfo.InvariantCulture, out sid)) return false;
            return ((sid >> 52) & 0xF) == 1 && (sid >> 56) == 1;
        }

        /// <summary>The "steamtun" first line of a tunnel: its fields, or null.</summary>
        public static Dictionary<object, object> TunnelLine(Msg m) => m != null && m.Kind == "steamtun" ? LuaLit.Parse(m.Payload) as Dictionary<object, object> : null;

        /// <summary>"relay, 35 ms" for a tunnel's first line.</summary>
        public static string RouteText(Dictionary<object, object> t)
        {
            string route = t.TryGetValue("route", out var r) ? Convert.ToString(r, CultureInfo.InvariantCulture) : "?";
            string ping = t.TryGetValue("ping", out var p) ? Convert.ToString(p, CultureInfo.InvariantCulture) : "?";
            return route + ", " + ping + " ms";
        }
    }

    /// <summary>Host addresses as players type them: "1.2.3.4:28090", "[2a02:8071::1]:28090", "2a02:8071::1" (IPv6 without
    /// port), "name:28090", several separated by commas.</summary>
    static class NetAddr
    {
        /// <summary>Closes a connection so that its own reading thread ends at once and the other end sees it closed: a
        /// TcpClient only closed left its blocked read waiting (2 minutes, until Windows' keepalive gave up, in the test of
        /// 2026-10-25), and the other end was not told.</summary>
        public static void Cut(TcpClient c)
        {
            if (c == null) return;
            try { c.Client?.Shutdown(SocketShutdown.Both); } catch { }
            try { c.Client?.Close(); } catch { }
            try { c.Close(); } catch { }
        }

        /// <summary>TCP keepalive after 15 s of silence, every 3 s: a connection that died without a word (a router, a lost
        /// Wi-Fi) is noticed within about half a minute instead of hours. Issue #60: the host kept a player's dead connection
        /// until the player came back on a new one.</summary>
        public static void KeepAlive(TcpClient c)
        {
            try
            {
                c.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                var v = new byte[12];
                BitConverter.GetBytes(1u).CopyTo(v, 0);
                BitConverter.GetBytes(15000u).CopyTo(v, 4);
                BitConverter.GetBytes(3000u).CopyTo(v, 8);
                c.Client.IOControl(IOControlCode.KeepAliveValues, v, null);
            }
            catch (Exception e) { Log.W("keepalive: " + e.Message); }
        }

        public static List<KeyValuePair<string, int>> Parse(string spec, int defaultPort)
        {
            var res = new List<KeyValuePair<string, int>>();
            foreach (var raw in (spec ?? "").Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var s = raw.Trim();
                string host = s;
                int port = defaultPort;
                if (s.StartsWith("["))
                {
                    int close = s.IndexOf(']');
                    if (close < 0) { host = s.Trim('['); }
                    else
                    {
                        host = s.Substring(1, close - 1);
                        var rest = s.Substring(close + 1);
                        if (rest.StartsWith(":") && int.TryParse(rest.Substring(1), out int p)) port = p;
                    }
                }
                else if (s.Count(ch => ch == ':') == 1)
                {
                    int c = s.IndexOf(':');
                    if (int.TryParse(s.Substring(c + 1), out int p)) { port = p; host = s.Substring(0, c); }
                }
                if (host.Length > 0) res.Add(new KeyValuePair<string, int>(host, port));
            }
            return res;
        }

        public static string Show(string host, int port) => (host.Contains(":") ? "[" + host + "]" : host) + ":" + port;

        /// <summary>The first address of a list, to show it: "1.2.3.4:28090".</summary>
        public static string First(string spec, int defaultPort)
        {
            var l = Parse(spec, defaultPort);
            return l.Count == 0 ? (spec ?? "") : Show(l[0].Key, l[0].Value);
        }

        /// <summary>This PC's public IPv6 addresses for invitations, the best first, or an empty list. First the address
        /// Windows uses for its own connections to the Internet (often a temporary one): routers that open a port per
        /// device (Vodafone Station "IPv6 Host Exposure") open it for the address they see that device use. Then the
        /// most stable one, when it is another.</summary>
        public static List<string> PublicIPv6List()
        {
            var res = new List<string>();
            try
            {
                // the source address of a route to a public IPv6 address (UDP "connect": nothing is sent)
                using (var u = new Socket(AddressFamily.InterNetworkV6, SocketType.Dgram, ProtocolType.Udp))
                {
                    u.Connect(IPAddress.Parse("2001:4860:4860::8888"), 53);
                    var a = ((IPEndPoint)u.LocalEndPoint).Address;
                    var b = a.GetAddressBytes();
                    if ((b[0] & 0xE0) == 0x20 && !(b[0] == 0x20 && b[1] == 0x02) && !a.IsIPv6Teredo) { a.ScopeId = 0; res.Add(a.ToString()); }
                }
            }
            catch { }
            var stable = PublicIPv6();
            if (stable != null && !res.Contains(stable)) res.Add(stable);
            return res;
        }

        /// <summary>This PC's public IPv6 address (global, the most stable one: given by the router's DHCPv6, else not a
        /// temporary one), or null.</summary>
        public static string PublicIPv6()
        {
            try
            {
                var found = new List<KeyValuePair<int, IPAddress>>();
                foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback
                        || nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Tunnel) continue;
                    foreach (var u in nic.GetIPProperties().UnicastAddresses)
                    {
                        var a = u.Address;
                        if (a.AddressFamily != AddressFamily.InterNetworkV6) continue;
                        var b = a.GetAddressBytes();
                        if ((b[0] & 0xE0) != 0x20 || (b[0] == 0x20 && b[1] == 0x02) || a.IsIPv6Teredo) continue;   // global unicast, not 6to4 / Teredo
                        int rank = 2;
                        try
                        {
                            if (u.PrefixOrigin == System.Net.NetworkInformation.PrefixOrigin.Dhcp) rank = 0;
                            else if (u.SuffixOrigin != System.Net.NetworkInformation.SuffixOrigin.Random) rank = 1;
                            else if (u.AddressPreferredLifetime < 86400 * 2) rank = 3;   // a temporary address
                        }
                        catch { }
                        found.Add(new KeyValuePair<int, IPAddress>(rank, a));
                    }
                }
                return found.Count == 0 ? null : found.OrderBy(kv => kv.Key).First().Value.ToString();
            }
            catch { return null; }
        }
    }

    static class GameInstall
    {
        public const string AppId = "3493540";

        /// <summary>(0.6.3) The game folder the player chose by hand (setting "gamedir"), for a game MPFever does not find itself (a
        /// GOG copy, a folder of its own): looked at after the usual places only. MPFEVER_GOG=0: not.</summary>
        public static string ChosenDir;

        public static bool IsGameDir(string d)
        {
            try { return !string.IsNullOrEmpty(d) && File.Exists(Path.Combine(d, "TransportFever3.exe")); } catch { return false; }
        }

        /// <summary>A copy of the game that Steam did not install (GOG, a folder of its own): not in a Steam library's
        /// steamapps\common. Its mods folder is not Steam's userdata, MPFever puts its mod into the game's mods\release.</summary>
        public static bool NotSteamCopy(string gameDir)
        {
            if (string.IsNullOrEmpty(gameDir) || Environment.GetEnvironmentVariable("MPFEVER_GOG") == "0") return false;
            var d = gameDir.Replace('/', '\\').TrimEnd('\\') + "\\";
            return d.IndexOf(@"\steamapps\common\", StringComparison.OrdinalIgnoreCase) < 0;
        }

        /// <summary>(0.6.4.1) The diagnostic build sent to the players whose sessions resync without a known cause (#107, #109): a
        /// file diag.txt next to MPFever.exe (or MPFEVER_DIAG=1) turns on, in every game this launcher starts, the logs that tell
        /// where two games part: the free-id queue at every 50th step (native.log, "freeq step ...", compared by
        /// tools/freeq_diff.py: the first step where the games give new entities other ids), a dump of the state at every
        /// check (sdump rings) and the detailed logs. Off without that file: nothing changes for the other players.</summary>
        public static bool DiagOn()
            => Environment.GetEnvironmentVariable("MPFEVER_DIAG") == "1"
               || File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "diag.txt"));

        /// <summary>(0.6.4.1) The diagnostic build's variables for a game (see DiagOn); a test's own values are kept.</summary>
        public static void DiagEnv(System.Collections.Specialized.StringDictionary env)
        {
            if (!DiagOn()) return;
            foreach (var kv in new[] { ("MPFEVER_FREEQLOG", "1"), ("MPFEVER_SDUMP", "all"), ("MPFEVER_STEPLOG", "1") })
                if (string.IsNullOrEmpty(env[kv.Item1])) env[kv.Item1] = kv.Item2;
        }

        /// <summary>(0.6.4) Windows 11's Smart App Control (Defender's "Intelligent App Control"): 0 off, 1 on, 2 evaluation, -1
        /// unknown (an older Windows). When on, it blocks every file not signed by a known publisher: MPFever's winhttp.dll is
        /// not, and the game only says "Bad Image ... winhttp.dll ... error status 0xc0e90002", which the players could not
        /// understand. MPFEVER_SACSTATE=n: that state (tests).</summary>
        public static int SmartAppControlState()
        {
            if (int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SACSTATE"), out var forced)) return forced;
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\CI\Policy"))
                    if (k?.GetValue("VerifiedAndReputablePolicyState") is int v) return v;
            }
            catch { }
            return -1;
        }

        /// <summary>(0.6.4) Whether Smart App Control blocks MPFever's winhttp.dll: on only (in evaluation it blocks nothing).
        /// MPFEVER_SACWARN=0: never told, as before.</summary>
        public static bool SmartAppControlBlocks()
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_SACWARN") == "0") return false;
            return SmartAppControlState() == 1;
        }

        /// <summary>(0.6.3) Where GOG installs the game: the folders its installer writes in the registry, then GOG's usual folders.</summary>
        public static IEnumerable<string> GogDirs()
        {
            var found = new List<string>();
            foreach (var root in new[] { @"SOFTWARE\WOW6432Node\GOG.com\Games", @"SOFTWARE\GOG.com\Games" })
            {
                try
                {
                    using (var k = Registry.LocalMachine.OpenSubKey(root))
                        if (k != null)
                            foreach (var id in k.GetSubKeyNames())
                                try { using (var g = k.OpenSubKey(id)) if (g?.GetValue("path") is string p) found.Add(p); } catch { }
                }
                catch { }
            }
            try
            {
                foreach (var drive in DriveInfo.GetDrives())
                {
                    if (drive.DriveType != DriveType.Fixed) continue;
                    var r = drive.RootDirectory.FullName;
                    found.Add(Path.Combine(r, "GOG Games", "Transport Fever 3"));
                    found.Add(Path.Combine(r, "Program Files (x86)", "GOG Galaxy", "Games", "Transport Fever 3"));
                    found.Add(Path.Combine(r, "Program Files", "GOG Galaxy", "Games", "Transport Fever 3"));
                    found.Add(Path.Combine(r, "Games", "Transport Fever 3"));
                }
            }
            catch { }
            return found;
        }

        public static string FindGameDir()
        {
            // 0. tests: the folder given (MPFEVER_GAMEDIR)
            var envDir = Environment.GetEnvironmentVariable("MPFEVER_GAMEDIR");
            if (IsGameDir(envDir)) return envDir;
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
            if (Environment.GetEnvironmentVariable("MPFEVER_GOG") == "0") return null;
            // 3. (0.6.3) the folder the player chose, 4. GOG
            if (IsGameDir(ChosenDir)) return ChosenDir;
            foreach (var p in GogDirs())
                if (IsGameDir(p)) return p;
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
            // The user's SteamPath can be stale (Steam reinstalled elsewhere: it still named the old folder, where only a
            // library was left, so the mod went nowhere and no savegame was found): the first of these that holds steam.exe,
            // then the running Steam's folder
            var cands = new List<string>();
            try { cands.Add(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string); } catch { }
            try { cands.Add(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string); } catch { }
            try { cands.Add(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath", null) as string); } catch { }
            try { cands.Add(Path.GetDirectoryName(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamExe", null) as string ?? "")); } catch { }
            try { foreach (var p in System.Diagnostics.Process.GetProcessesByName("steam")) try { cands.Add(Path.GetDirectoryName(p.MainModule.FileName)); } catch { } } catch { }
            foreach (var c in cands)
            {
                if (string.IsNullOrEmpty(c)) continue;
                var d = c.Replace('/', Path.DirectorySeparatorChar);
                try { if (File.Exists(Path.Combine(d, "steam.exe")) && Directory.Exists(Path.Combine(d, "userdata"))) return d; } catch { }
            }
            return cands.FirstOrDefault(c => !string.IsNullOrEmpty(c))?.Replace('/', Path.DirectorySeparatorChar);
        }

        public static IEnumerable<string> SteamLibraries()
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

        /// <summary>Running under Wine or Proton (Linux, Steam Deck): Wine keeps its own key in the registry it emulates.</summary>
        public static bool UnderWine()
        {
            try { using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Wine")) return k != null; } catch { return false; }
        }

        /// <summary>Copies the mod into every Steam user's TF3 mods folder. Under Wine or Proton (issue #93) also into the game's
        /// mods\release folder, where the game finds it there: each update of MPFever then reaches it too (MPFEVER_WINEMODS=0: not).</summary>
        public static int InstallMod()
        {
            var src = FindModSource();
            int w = 0;
            string game = null;
            try { game = FindGameDir(); } catch { }
            // (0.6.3) a copy Steam did not install (GOG): the same folder, where the game finds it too
            bool notSteam = NotSteamCopy(game);
            if (src != null && ((UnderWine() && Environment.GetEnvironmentVariable("MPFEVER_WINEMODS") != "0") || notSteam))
            {
                try
                {
                    var g = game;
                    var rel = g == null ? null : Path.Combine(g, "mods", "release");
                    if (rel != null && Directory.Exists(rel))
                    {
                        var dst = Path.Combine(rel, "mpfever_1");
                        if (Directory.Exists(dst)) Directory.Delete(dst, true);
                        CopyDir(src, dst);
                        w = 1;
                        Log.Ok(L.T("Mod installé dans ", "Mod installed in ") + dst + (notSteam ? "" : " (Wine/Proton)"));
                    }
                }
                catch (Exception e) { Log.W("mods\\release: " + e.Message); }
            }
            var steam = SteamPath();
            if (src == null || steam == null) { if (w == 0) Log.Err(L.T("Mod ou Steam introuvable, installation du mod ignorée", "Mod or Steam not found, mod installation skipped")); return w; }
            int n = w;
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
        public static void InstallNative(string gameDir) { NativeStatus = InstallNative(gameDir, AppDomain.CurrentDomain.BaseDirectory); }

        /// <summary>(0.6.5, #111) What InstallNative found: null (installed or up to date), "missing" (no winhttp.dll next to
        /// MPFever.exe: the archive not wholly extracted), "other" (another mod's dll in the game folder), "busy" (the game's
        /// is an old one and the game is running).</summary>
        public static string NativeStatus;

        /// <summary>InstallNative with the folder of MPFever's own winhttp.dll given (the self-test); the status, see NativeStatus.</summary>
        public static string InstallNative(string gameDir, string srcDir)
        {
            var src = Path.Combine(srcDir, "winhttp.dll");
            var dst = Path.Combine(gameDir, "winhttp.dll");
            // a game started by Steam from an MPFever invitation starts MPFever.exe from this path
            try { File.WriteAllText(Path.Combine(gameDir, "mpfever_path.txt"), System.Reflection.Assembly.GetExecutingAssembly().Location, Encoding.Unicode); } catch (Exception e) { Log.W("mpfever_path.txt: " + e.Message); }
            if (!File.Exists(src)) { Log.Warn(L.T("winhttp.dll absent à côté de MPFever.exe : module natif non installé", "winhttp.dll missing next to MPFever.exe: native module not installed")); return "missing"; }
            if (File.Exists(dst))
            {
                var cur = File.ReadAllBytes(dst);
                if (cur.SequenceEqual(File.ReadAllBytes(src))) return null;
                if (Encoding.ASCII.GetString(cur).IndexOf("mpfever_native", StringComparison.Ordinal) < 0)
                {
                    Log.Warn(L.T("Un autre winhttp.dll (autre mod ?) est déjà dans le dossier du jeu : module natif non installé", "Another winhttp.dll (another mod?) is already in the game folder: native module not installed"));
                    return "other";
                }
            }
            try
            {
                File.Copy(src, dst, true);
                Log.Ok(L.T("Module natif installé : ", "Native module installed: ") + dst);
                return null;
            }
            catch (IOException) { Log.Warn(L.T("Module natif : fermez Transport Fever 3 puis relancez MPFever pour le mettre à jour", "Native module: close Transport Fever 3, then restart MPFever to update it")); return "busy"; }
        }

        /// <summary>The savegame folders the game itself gave (save_dirs.txt of the MPFever page, kept in the settings): a
        /// game not installed through Steam keeps its savegames elsewhere than Steam's userdata (issue #76).</summary>
        public static readonly List<string> GameSaveDirs = new List<string>();

        /// <summary>Adds the folders of a save_dirs.txt; true when one was new.</summary>
        public static bool AddGameSaveDirs(IEnumerable<string> lines)
        {
            bool added = false;
            lock (GameSaveDirs)
                foreach (var l in lines)
                {
                    var d = (l ?? "").Trim().Replace('/', Path.DirectorySeparatorChar);
                    try
                    {
                        if (d == "" || !Path.IsPathRooted(d) || !Directory.Exists(d)) continue;
                        d = Path.GetFullPath(d).TrimEnd(Path.DirectorySeparatorChar);
                    }
                    catch { continue; }
                    if (GameSaveDirs.Any(x => string.Equals(x, d, StringComparison.OrdinalIgnoreCase))) continue;
                    GameSaveDirs.Add(d);
                    added = true;
                }
            return added;
        }

        /// <summary>The savegame folders of every Steam user of this PC (created if missing), then those the game gave.</summary>
        public static List<string> SaveDirs()
        {
            var dirs = new List<string>();
            var steam = SteamPath();
            var userdata = steam == null ? null : Path.Combine(steam, "userdata");
            if (userdata != null && Directory.Exists(userdata))
                foreach (var u in Directory.GetDirectories(userdata))
                {
                    var local = Path.Combine(u, AppId, "local");
                    if (!Directory.Exists(local)) continue;
                    var save = Path.Combine(local, "save");
                    Directory.CreateDirectory(save);
                    dirs.Add(save);
                }
            lock (GameSaveDirs)
                foreach (var d in GameSaveDirs)
                    if (!dirs.Any(x => string.Equals(Path.GetFullPath(x).TrimEnd(Path.DirectorySeparatorChar), d, StringComparison.OrdinalIgnoreCase)))
                        dirs.Add(d);
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
