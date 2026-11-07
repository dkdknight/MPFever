using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The settings of a dedicated server: mpfever_server.properties next to MPFever.exe ("key=value" lines,
    /// "#" starts a comment line), written with every key and its default value the first time the server starts. Like
    /// Minecraft's server.properties, the server itself only reads it; the window's settings (0.7.0, ServerSettingsDialog)
    /// write it again, every key with its comment, from the values chosen there (Save).</summary>
    sealed class ServerConfig
    {
        public const string FileName = "mpfever_server.properties";

        public string Name = "MPFever Server";
        public string World = "";
        public int Port = 28090;
        public string Password = "";
        public int MaxPlayers = 8;
        public string CompanyMode = "shared";
        public string Owner = "";
        public long StartMoney = 2000000;
        public bool ShareRules = true;
        // (0.6) the game options, "id=1;id.param=v;..." (null: the line is absent, the host's last choice in the settings is used)
        public string GameOptions;
        public int StartSpeed = 1;
        public bool PauseWhenEmpty = true;
        public bool PlayerSpeedControl = true;
        public int AutosaveMinutes = 10;
        public int Backups = 10;
        public bool RestartOnCrash = true;
        public int WatchdogSeconds = 180;
        public string Motd = "";
        public bool Public = true;
        public string PublicAddress = "";
        // (0.7.0) separate only: months in debt before a company goes bankrupt (0 never, 3, 6, 12, 24), as the lobby's rules
        public int BankruptMonths = 12;
        // (0.7.0) separate only: the computer companies the server's game runs, "n:colour:level[:money],..." as the lobby sends them
        // (n 1-8, colour 1-12, level 1 easy 2 normal 3 hard, money: its start money, absent = the players')
        public string AiCompanies = "";

        public static string DefaultPath => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, FileName);

        /// <summary>The file written the first time: every setting with its default value and what it does.</summary>
        public static string Template() => new ServerConfig().Text();

        static string B(bool v) => v ? "true" : "false";
        static string I(long v) => v.ToString(CultureInfo.InvariantCulture);
        /// <summary>(a value on one line: no line break in a text typed in the window)</summary>
        static string One(string v) => (v ?? "").Replace("\r", " ").Replace("\n", " ").Trim();

        /// <summary>The file with these values, every setting with what it does (0.7.0: the window's settings write it).</summary>
        public string Text() => string.Join("\r\n", new[]
        {
            "# MPFever dedicated server (MPFever.exe --server)",
            "# The game runs the world on this PC, nobody plays on it. Players join it with its address, as they join a host.",
            "# Lines \"key=value\"; a line starting with # is a comment. Restart the server (or type \"restart\") after a change.",
            "",
            "# Name shown to the players (in-game MPFever window, chat).",
            "server-name=" + One(Name),
            "",
            "# The world: the name of a savegame of this PC, as shown in the game's load list. Required.",
            "# The server saves the world under this name (autosave) and loads it again after a restart.",
            "world=" + One(World),
            "",
            "# TCP port the players connect to (forward it on the router to play over the Internet).",
            "port=" + I(Port),
            "",
            "# Password the players type in the MPFever window when they join (empty: no password).",
            "password=" + One(Password),
            "",
            "# Players at most (the server itself not counted).",
            "max-players=" + I(MaxPlayers),
            "",
            "# shared: one company for everybody. separate: one company per player (still in development).",
            "company-mode=" + CompanyMode,
            "",
            "# separate only: the player name that gets the savegame's own company (empty: nobody plays it).",
            "owner=" + One(Owner),
            "",
            "# separate only: money of a new company.",
            "start-money=" + I(StartMoney),
            "",
            "# separate only: months in debt before a company goes bankrupt: 0 (never), 3, 6, 12 or 24.",
            "bankruptcy-months=" + I(BankruptMonths),
            "",
            "# separate only: the computer companies (experimental), \"n:colour:level[:money],...\": n 1 to 8, colour 1 to 12, level 1 (easy),",
            "# 2 (normal) or 3 (hard), money: its start money (absent: the players'). Empty: none.",
            "ai-companies=" + One(AiCompanies),
            "",
            "# separate only: true, each company decides whether its tracks, stations, stops and depots are private, open or paying;",
            "# false: everything is open and free for every company.",
            "sharing-rules=" + B(ShareRules),
            "",
            "# The game options (0.6), all off by default: \"id=1;id.param=value;...\" as the host's lobby makes them (its log names",
            "# them: \"Game options chosen by the host\"). Empty: none.",
            "game-options=" + GameOpts.Canon(GameOptions ?? ""),
            "",
            "# Game speed when the world starts: 1, 2 or 4.",
            "start-speed=" + I(StartSpeed),
            "",
            "# true: the world stops while nobody is connected (as in Satisfactory or Factorio). false: it always runs.",
            "pause-when-empty=" + B(PauseWhenEmpty),
            "",
            "# true: the players may pause the game and change its speed. false: only the server console may.",
            "player-speed-control=" + B(PlayerSpeedControl),
            "",
            "# Minutes between two saves of the world (0: no autosave). The world stops for a few seconds while it is saved.",
            "autosave-minutes=" + I(AutosaveMinutes),
            "",
            "# Copies of the world kept in server\\backups after each save (0: none).",
            "backups=" + I(Backups),
            "",
            "# true: the game is started again when it closes or crashes (at most 3 times in 15 minutes).",
            "restart-on-crash=" + B(RestartOnCrash),
            "",
            "# Seconds without any sign of life from the game before it is restarted (0: never).",
            "watchdog-seconds=" + I(WatchdogSeconds),
            "",
            "# Chat message every player receives when it joins (empty: none).",
            "motd=" + One(Motd),
            "",
            "# true: the server is shown in the public server list of MPFever's multiplayer page (its name, address, players,",
            "# world and motd), while its world runs. false: only those who know its address find it.",
            "public=" + B(Public),
            "",
            "# The address the list shows (a domain name, name:port). Empty: the public IP address the list sees, and port.",
            "public-address=" + One(PublicAddress),
            "",
        });

        /// <summary>Reads the settings. A missing file is written from the template (created = true). Lines that cannot be
        /// used are listed in problems and keep their default value.</summary>
        public static ServerConfig Load(string path, List<string> problems, out bool created)
        {
            var c = new ServerConfig();
            created = false;
            if (!File.Exists(path))
            {
                File.WriteAllText(path, Template(), new UTF8Encoding(false));
                created = true;
            }
            int n = 0;
            foreach (var raw in File.ReadAllLines(path, Encoding.UTF8))
            {
                n++;
                var line = raw.Trim();
                if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) { problems.Add(n + ": " + line); continue; }
                var key = line.Substring(0, eq).Trim().ToLowerInvariant();
                var val = line.Substring(eq + 1).Trim();
                if (!c.Set(key, val)) problems.Add(n + ": " + line);
            }
            return c;
        }

        bool Set(string key, string v)
        {
            switch (key)
            {
                case "server-name": Name = v.Length == 0 ? "MPFever Server" : (v.Length > 40 ? v.Substring(0, 40) : v); return true;
                case "world": World = v; return true;
                case "port": return Int(v, 1024, 65535, ref Port);
                case "password": Password = v; return true;
                case "max-players": return Int(v, 1, 64, ref MaxPlayers);
                case "company-mode":
                    if (v != "shared" && v != "separate") return false;
                    CompanyMode = v;
                    return true;
                case "owner": Owner = v; return true;
                case "start-money":
                    if (!long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out long money) || money < 0) return false;
                    StartMoney = money;
                    return true;
                case "sharing-rules": return Bool(v, ref ShareRules);
                case "game-options":
                    if (v.Length > GameOpts.MaxText) return false;
                    GameOptions = GameOpts.Canon(v);
                    return true;
                case "start-speed":
                    if (v != "1" && v != "2" && v != "4") return false;
                    StartSpeed = int.Parse(v, CultureInfo.InvariantCulture);
                    return true;
                case "pause-when-empty": return Bool(v, ref PauseWhenEmpty);
                case "player-speed-control": return Bool(v, ref PlayerSpeedControl);
                case "autosave-minutes": return Int(v, 0, 1440, ref AutosaveMinutes);
                case "backups": return Int(v, 0, 1000, ref Backups);
                case "restart-on-crash": return Bool(v, ref RestartOnCrash);
                case "watchdog-seconds":
                    if (!Int(v, 0, 86400, ref WatchdogSeconds)) return false;
                    if (WatchdogSeconds > 0 && WatchdogSeconds < 30) WatchdogSeconds = 30;   // (a save or a load takes some time)
                    return true;
                case "motd": Motd = v; return true;
                case "public": return Bool(v, ref Public);
                case "public-address": PublicAddress = v.Length > 80 ? v.Substring(0, 80) : v; return true;
                case "bankruptcy-months":
                    if (v != "0" && v != "3" && v != "6" && v != "12" && v != "24") return false;
                    BankruptMonths = int.Parse(v, CultureInfo.InvariantCulture);
                    return true;
                case "ai-companies":
                    {
                        var canon = AiCanon(v);
                        if (canon == null) return false;
                        AiCompanies = canon;
                        return true;
                    }
            }
            return false;
        }

        /// <summary>(0.7.0) The computer companies' text in its canonical form ("n:colour:level[:money]" sorted by n, each n and
        /// colour once, at most 8), or null when it does not read so.</summary>
        public static string AiCanon(string v)
        {
            var map = new SortedDictionary<int, string>();
            var colours = new HashSet<int>();
            foreach (var part in (v ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var f = part.Trim().Split(':');
                if (f.Length < 3 || f.Length > 4) return null;
                if (!int.TryParse(f[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int n) || n < 1 || n > 8 || map.ContainsKey(n)) return null;
                if (!int.TryParse(f[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out int col) || col < 1 || col > 12 || !colours.Add(col)) return null;
                if (!int.TryParse(f[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out int lv) || lv < 1 || lv > 3) return null;
                string money = "";
                if (f.Length == 4)
                {
                    if (!long.TryParse(f[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out long mo) || mo < -1 || mo > 10000000000L) return null;
                    if (mo >= 0) money = ":" + mo.ToString(CultureInfo.InvariantCulture);
                }
                map[n] = n.ToString(CultureInfo.InvariantCulture) + ":" + col.ToString(CultureInfo.InvariantCulture) + ":" + lv.ToString(CultureInfo.InvariantCulture) + money;
            }
            return string.Join(",", map.Values);
        }

        /// <summary>(0.7.0) Writes the settings (the window's « Save »): the whole file again, with its comments, through a temporary
        /// file (a crash never leaves half a file).</summary>
        public void Save(string path)
        {
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, Text() + "\r\n", new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
        }

        /// <summary>Whether a player who says "join" (its payload: { v = version, pw = password }) may come in, with
        /// `others` players already connected (not counting its own older connection): null, or the payload of the
        /// "denied" message (reason: version, password or full).</summary>
        public string Admission(string joinPayload, int others, out string reason)
        {
            var t = LuaLit.Parse(joinPayload ?? "") as Dictionary<object, object> ?? new Dictionary<object, object>();
            string S(string k) => t.TryGetValue(k, out var v) && v is string sv ? sv : "";
            reason = null;
            string extra = "";
            if (S("v") != MainForm.Version) { reason = "version"; extra = ",[\"v\"]=" + LuaLit.Quote(MainForm.Version); }
            else if (Password != "" && S("pw") != Password) reason = "password";
            else if (others >= MaxPlayers) { reason = "full"; extra = ",[\"max\"]=" + MaxPlayers; }
            return reason == null ? null : "{[\"reason\"]=" + LuaLit.Quote(reason) + extra + "}";
        }

        static bool Int(string v, int min, int max, ref int field)
        {
            if (!int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int x) || x < min || x > max) return false;
            field = x;
            return true;
        }

        static bool Bool(string v, ref bool field)
        {
            switch (v.ToLowerInvariant())
            {
                case "true": case "yes": case "on": case "1": field = true; return true;
                case "false": case "no": case "off": case "0": field = false; return true;
            }
            return false;
        }
    }

    /// <summary>Dedicated server (MPFever.exe of the server's archive, or MPFever.exe --server): the game of this PC loads
    /// the world and hosts it like a player hosts a savegame, but nobody plays on it. The window opens with the server
    /// stopped; it starts with one of its two buttons: with display (the game's window shows the world, as a player's game) or
    /// without (the game's window is hidden and the world is not drawn, see the native module's MPFEVER_HEADLESS), or by itself
    /// when the window opens if asked (serverautostart=1 in mpfever_settings.txt, in the last mode used). The world is saved
    /// regularly, the game is started again when it crashes, and the console under the log drives the server. What a player
    /// sees is unchanged: they join its address. Inspired by the servers of Minecraft (server.properties, console),
    /// Satisfactory and Factorio (the world waits while nobody is connected, autosave).</summary>
    sealed partial class MainForm
    {
        /// <summary>The server's window: MPFever.exe of the server's archive (server-edition.txt next to it) or --server.</summary>
        public static bool ServerMode;
        /// <summary>The file of the server's archive that makes its MPFever.exe open the server's window.</summary>
        public const string ServerEditionFile = "server-edition.txt";
        /// <summary>--server-start display|headless: the server starts at once in that mode (MPFever started again by an update
        /// installed while it ran), else null.</summary>
        static string serverStartAtOpen;
        /// <summary>--server-idle: MPFever started again with the server stopped (no automatic start).</summary>
        static bool serverIdleAsked;
        ServerConfig server;
        volatile bool serverStarted, serverStoppedByHand;
        bool serverHeadless;

        // saves of the world: their numbers are far above those of the resynchronisations (save_done tells them apart)
        const int ServerSaveIdBase = 1000000;
        const double WorldLoadTimeoutSeconds = 900;
        const double EmptyPauseSeconds = 5;
        readonly object worldGate = new object();   // a save of the world and a resynchronisation never run together
        readonly object beginGate = new object();
        volatile bool serverStopping, serverClosed, serverSaving, autoPaused, restartRequested;
        volatile Dictionary<object, object> serverSaveDone;
        int serverSaveSeq;
        int savedActs = -1;
        long savedClock = -1;
        DateTime? lastSavedAt;
        double emptySince = -1, lastAutosave, hostingSince = -1;
        bool worldMissing;
        string serverAddresses = "";
        readonly List<double> gameExits = new List<double>();
        readonly HashSet<string> greeted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // ---- server console (under the log)
        TextBox cmdBox;
        Label serverInfo;
        readonly List<string> cmdHistory = new List<string>();
        int cmdHistoryPos;

        static string ServerDir => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "server");

        /// <summary>The server's name as a player name (letters, digits, - and _), the name of its game in the session.</summary>
        string ServerPlayerName()
        {
            var n = new string((server?.Name ?? "").Where(c => char.IsLetterOrDigit(c) || c == '_' || c == '-').ToArray());
            if (n.Length > 24) n = n.Substring(0, 24);
            return n.Length == 0 ? "Server" : n;
        }

        // ---------------------------------------------------------------- start, stop, restart

        /// <summary>The arguments MPFever.exe was started with, for the server's window: whether the server starts at once.</summary>
        internal static void ServerArgs(string[] args, bool updated)
        {
            // (started again stopped - the stop button or the console's "stop", or an update of a stopped server: the box "Start the
            // server when MPFever opens" is for a window opened by the player, else the server started again right after its stop)
            serverIdleAsked = args.Contains("--server-idle");
            int i = Array.IndexOf(args, "--server-start");
            if (i >= 0 && i + 1 < args.Length && (args[i + 1] == "display" || args[i + 1] == "headless")) serverStartAtOpen = args[i + 1];
            // (MPFever 0.5.7's server started its world at once: its update, installed while the world ran, starts the new
            // version with "--server" only)
            else if (updated && args.Contains("--server") && !args.Contains("--server-idle")) serverStartAtOpen = "display";
            // (an update found when the window opens starts MPFever again with them)
            Program.Args = serverStartAtOpen != null ? new[] { "--server", "--server-start", serverStartAtOpen } : new[] { "--server", "--server-idle" };
        }

        /// <summary>The arguments of the next MPFever.exe (after an update, or a stop): the server running in its mode, or stopped.</summary>
        string[] ServerRunArgs() => serverStarted && !serverStoppedByHand
            ? new[] { "--server", "--server-start", serverHeadless ? "headless" : "display" }
            : new[] { "--server", "--server-idle" };

        static bool ServerAutoStart => LoadSettings().TryGetValue("serverautostart", out var v) && v == "1";
        static bool ServerLastHeadless => LoadSettings().TryGetValue("servermode", out var v) && v == "headless";

        /// <summary>The window is open: the settings are read, and the server starts if asked (an update installed while
        /// it ran, or the automatic start), else it waits for one of the two start buttons.</summary>
        void OpenServerWindow()
        {
            menuMode = true;
            hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false;
            Program.Args = ServerRunArgs();
            LoadServerConfig();
            new Thread(FindServerAddresses) { IsBackground = true, Name = "Server addresses" }.Start();
            string mode = serverStartAtOpen ?? (ServerAutoStart && !serverIdleAsked ? (ServerLastHeadless ? "headless" : "display") : null);
            if (mode != null)
            {
                if (serverStartAtOpen == null)
                    Log.W(T("Démarrage automatique du serveur (case cochée dans la fenêtre).", "The server starts by itself (box ticked in the window)."));
                StartServerMode(mode == "headless");
                return;
            }
            menuPhase = "idle";
            menuText = T("Le serveur est arrêté. Démarrez-le avec l'un des deux boutons :\n\n• avec affichage : la fenêtre du jeu montre le monde, comme chez un joueur ;\n• sans affichage : le jeu tourne caché, sans dessiner le monde ni faire de bruit (bien moins de ressources ; il faut tout de même une carte graphique).",
                "The server is stopped. Start it with one of the two buttons:\n\n• with display: the game's window shows the world, as on a player's PC;\n• without display: the game runs hidden, without drawing the world or making any sound (far fewer resources; a graphics card is still needed).");
            try { BeginInvoke((Action)UpdateServerButtons); } catch { }
        }

        /// <summary>A start button, the automatic start or the console's "start": the server's game starts and loads the world,
        /// with its window and its drawing, or without them (headless).</summary>
        void StartServerMode(bool headless)
        {
            if (serverStarted || serverStopping) return;
            if (gameMissing) { Log.Err(T("Transport Fever 3 est introuvable : le serveur ne peut pas démarrer.", "Transport Fever 3 was not found: the server cannot start.")); return; }
            serverStarted = true;
            serverHeadless = headless;
            SaveSetting("servermode", headless ? "headless" : "display");
            Program.Args = ServerRunArgs();
            running = true;
            Log.W(headless ? T("=== Démarrage du serveur sans affichage : le jeu tourne caché, sans dessiner le monde ===", "=== The server starts without display: the game runs hidden, without drawing the world ===")
                           : T("=== Démarrage du serveur avec affichage ===", "=== The server starts with display ==="));
            LoadServerConfig();   // (the file as it is now)
            menuGame = new GameLink(ServerPlayerName(), "menu") { Server = true, Headless = headless };
            games.Add(menuGame);
            menuGame.Exited += OnServerGameExited;
            new Thread(MenuLoop) { IsBackground = true, Name = "Menu link" }.Start();
            new Thread(ServerLoop) { IsBackground = true, Name = "Server" }.Start();
            new Thread(ServerListAnnounceLoop) { IsBackground = true, Name = "Server list" }.Start();
            if (!BeginServerWorld(true))
                Log.Warn(T("Le serveur attend : corrigez mpfever_server.properties puis tapez « restart ».", "The server is waiting: fix mpfever_server.properties, then type « restart »."));
            try { BeginInvoke((Action)(() => { UpdateServerButtons(); cmdBox?.Focus(); })); } catch { }
        }

        /// <summary>Reads mpfever_server.properties (written with its default values the first time).</summary>
        void LoadServerConfig()
        {
            var problems = new List<string>();
            try
            {
                server = ServerConfig.Load(ServerConfig.DefaultPath, problems, out bool created);
                if (created) Log.Warn(F("Paramètres du serveur créés : {0}. Indiquez la sauvegarde à héberger après world=.", "Server settings created: {0}. Write the savegame to host after world=.", ServerConfig.DefaultPath));
            }
            catch (Exception e)
            {
                server = server ?? new ServerConfig();
                Log.Err(ServerConfig.FileName + ": " + e.Message);
            }
            foreach (var p in problems) Log.Warn(F("{0} : ligne ignorée (valeur par défaut gardée) : {1}", "{0}: line ignored (default value kept): {1}", ServerConfig.FileName, p));
            companyMode = server.CompanyMode;
            Log.W(F("Serveur « {0} » : monde « {1} », port {2}, {3} joueurs au maximum, mot de passe {4}, entreprises : {5}", "Server « {0} »: world « {1} », port {2}, {3} players at most, password {4}, companies: {5}",
                server.Name, server.World, server.Port, server.MaxPlayers, server.Password == "" ? T("non", "no") : T("oui", "yes"), server.CompanyMode));
        }

        /// <summary>"restart": the settings are read again (port, password... of the next session) and the addresses with them.</summary>
        void ReloadServerConfig()
        {
            LoadServerConfig();
            new Thread(FindServerAddresses) { IsBackground = true, Name = "Server addresses" }.Start();
        }

        /// <summary>The owner= of the settings as the companies know a player: its name as the relay keeps it (letters,
        /// digits, - and _), in lower case as the mod's Lua makes it (ASCII letters only).</summary>
        string OwnerKey()
        {
            var n = new string((server?.Owner ?? "").Where(c => char.IsLetterOrDigit(c) || c == '_' || c == '-').ToArray());
            if (n.Length > 24) n = n.Substring(0, 24);
            return new string(n.Select(c => c < 128 ? char.ToLowerInvariant(c) : c).ToArray());
        }

        /// <summary>The world's savegame exists on this PC (else the savegames there are listed).</summary>
        bool CheckWorld()
        {
            bool found = false;
            try { found = !string.IsNullOrWhiteSpace(server.World) && GameInstall.FindSave(server.World) != null; } catch { }
            worldMissing = !found;
            if (!worldMissing) return true;
            if (string.IsNullOrWhiteSpace(server.World))
                Log.Err(F("Aucun monde choisi : écrivez le nom d'une sauvegarde après world= dans {0}.", "No world chosen: write the name of a savegame after world= in {0}.", ServerConfig.DefaultPath));
            else
                Log.Err(F("Sauvegarde « {0} » introuvable sur ce PC (le nom de la liste de chargement du jeu).", "Savegame « {0} » not found on this PC (the name in the game's load list).", server.World));
            try
            {
                var names = GameInstall.SaveDirs().SelectMany(d => Directory.GetFiles(d))
                    .Where(f => f.EndsWith(".sav", StringComparison.OrdinalIgnoreCase))
                    .Select(Path.GetFileNameWithoutExtension)
                    .Where(n => !n.StartsWith("MPFever resync", StringComparison.Ordinal) && !n.StartsWith("autosave_", StringComparison.Ordinal))
                    .Distinct().OrderBy(n => n, StringComparer.OrdinalIgnoreCase).Take(40).ToList();
                Log.W(T("Sauvegardes de ce PC : ", "Savegames on this PC: ") + (names.Count == 0 ? "—" : string.Join(", ", names)));
            }
            catch { }
            return false;
        }

        /// <summary>Opens the session and has the server's game load the world (at start, after a crash, on "restart").</summary>
        bool BeginServerWorld(bool launch)
        {
            // (a crash restart and the console's "restart" may ask at the same time: one session only)
            lock (beginGate) return BeginServerWorldLocked(launch);
        }

        bool BeginServerWorldLocked(bool launch)
        {
            if (serverStopping) return false;
            if (hostGame != null) return true;   // already open
            if (!CheckWorld()) { menuPhase = "error"; menuText = T("Monde introuvable.", "World not found."); MenuStatus(); return false; }
            var name = ServerPlayerName();
            menuGame.SetIdentity(name, "host");
            lock (greeted) greeted.Clear();
            autoPaused = false;
            emptySince = -1;
            savedActs = -1;
            savedClock = -1;
            try { StartHost(name, false, menuGame); }
            catch (Exception e)
            {
                Log.Err(T("Impossible d'héberger : ", "Cannot host: ") + e.Message);
                menuPhase = "error"; menuText = T("Impossible d'héberger : ", "Cannot host: ") + e.Message; MenuStatus();
                return false;
            }
            Log.W(F("=== Serveur dédié « {0} » : chargement du monde « {1} » ===", "=== Dedicated server « {0} »: loading the world « {1} » ===", server.Name, server.World));
            // (0.7.0) the world's mods and DLCs, read from its savegame: a player who joins sees them before joining (see the join
            // review), and installs the missing mods from there. Before, a server told its players none. MPFEVER_SERVERMODS=0: none
            if (Environment.GetEnvironmentVariable("MPFEVER_SERVERMODS") != "0")
                try
                {
                    var t0 = DateTime.UtcNow;
                    var sm = SaveInfo.Mods(GameInstall.FindSave(server.World));
                    if (sm != null)
                    {
                        lobbyMods = Mods.Describe(SaveInfo.MenuList(sm));
                        lobbyModsKnown = true;
                        LogModVerdicts(lobbyMods, (DateTime.UtcNow - t0).TotalSeconds);
                        Log.W(F("DLC du monde : {0}", "The world's DLCs: {0}", SessionDlcs() == "none" ? T("aucun", "none") : SessionDlcs()));
                    }
                    else Log.Warn(T("Mods du monde illisibles dans sa sauvegarde : les joueurs ne les verront pas avant de rejoindre.", "The world's mods could not be read from its savegame: the players will not see them before joining."));
                }
                catch (Exception e) { Log.W("world mods: " + e.Message); }
            if (launch && !menuGame.GameRunning) menuGame.Launch(gameDir);
            lastAutosave = Now;
            hostingSince = Now;
            lastLoadOrder = Now;
            // the application script of the game (mpfever_auto.lua) loads it as soon as the main menu is ready
            menuLoad = server.World;
            menuLoadSeq = "s" + DateTime.Now.Ticks;
            menuPhase = "hosting";
            menuText = F("Chargement du monde « {0} »...", "Loading the world « {0} »...", server.World);
            MenuStatus();
            return true;
        }

        /// <summary>The server's game closed (a crash, or closed by hand): it is started again with the last saved world,
        /// unless the server stops or it keeps crashing.</summary>
        void OnServerGameExited()
        {
            if (serverStopping) return;
            bool planned = restartRequested;
            restartRequested = false;
            bool again = planned || server.RestartOnCrash;
            int recent = 0;
            if (!planned)
            {
                lock (gameExits)
                {
                    gameExits.Add(Now);
                    gameExits.RemoveAll(x => Now - x > 900);
                    recent = gameExits.Count;
                }
                Log.Err(T("Le jeu du serveur s'est fermé.", "The server's game closed."));
                if (recent > 3) again = false;
            }
            new Thread(() =>
            {
                EndSession(T("=== Le jeu du serveur s'est fermé : fin de la session ===", "=== The server's game closed: the session ends ==="));
                if (!again)
                {
                    if (recent > 3) Log.Err(T("Le jeu du serveur s'est fermé plus de 3 fois en 15 minutes : il n'est plus relancé. Tapez « restart » pour réessayer.", "The server's game closed more than 3 times in 15 minutes: it is not started again. Type « restart » to try again."));
                    else Log.Warn(T("Pas de redémarrage automatique (restart-on-crash=false) : tapez « restart » pour relancer le monde.", "No automatic restart (restart-on-crash=false): type « restart » to start the world again."));
                    menuPhase = "error"; menuText = T("Le jeu du serveur s'est fermé.", "The server's game closed."); MenuStatus();
                    return;
                }
                if (!planned) Log.Warn(T("Le jeu du serveur redémarre dans 10 s...", "The server's game starts again in 10 s..."));
                Thread.Sleep(planned ? 2000 : 10000);
                if (planned) ReloadServerConfig();   // ("restart": the settings as they are now, read once the old session is over)
                if (!serverStopping) BeginServerWorld(true);
            }) { IsBackground = true, Name = "Server restart" }.Start();
        }

        /// <summary>The server's game is back at its main menu: an error, or somebody at the server's keyboard. Its menu
        /// does not host or join here; the world is opened again.</summary>
        void ServerMenuRequest(string cmd)
        {
            if (cmd == "menu" || cmd == "leave" || cmd == "cancel")
            {
                if (menuGame.InGame && !resyncing && !serverStopping && Now - lastLoadOrder > 120)
                {
                    Log.Warn(T("Le jeu du serveur est revenu au menu principal : le monde est rouvert.", "The server's game went back to its main menu: the world is opened again."));
                    new Thread(() => { EndSession(); Thread.Sleep(2000); BeginServerWorld(false); }) { IsBackground = true, Name = "Server reopen" }.Start();
                }
                return;
            }
            Log.Warn(T("Serveur dédié : son jeu n'héberge ni ne rejoint de partie depuis son menu. Utilisez la console du serveur (help).", "Dedicated server: its game neither hosts nor joins from its menu. Use the server console (help)."));
        }

        /// <summary>(0.7.6, STOPRESYNC) A stop or a restart during a resynchronisation: it waits for nobody any more and ends
        /// within seconds, then the world is saved (before, the save waited behind it, up to 600 s, and said nothing).
        /// MPFEVER_STOPRESYNC=0: as before.</summary>
        void CutResyncShort(string why)
        {
            if (!StopCutsResync(resyncing, Environment.GetEnvironmentVariable("MPFEVER_STOPRESYNC") == "0")) return;
            resyncAbort = true;
            Log.W(F("{0} : la resynchronisation en cours se termine d'abord (quelques secondes)", "{0}: the resynchronisation under way ends first (a few seconds)", why));
        }

        internal static bool StopCutsResync(bool resyncing, bool old) => resyncing && !old;

        /// <summary>"restart": the settings are read again, the world is saved, then the game starts again with it (the
        /// players are reconnected by their MPFever).</summary>
        void RestartWorld()
        {
            if (serverStopping) return;
            CutResyncShort(T("redémarrage", "restart"));
            new Thread(() =>
            {
                bool st; lock (sessionGate) st = started;
                if (st)
                {
                    HostChat("msg", server.Name, T("Le serveur redémarre : vous serez reconnecté automatiquement.", "The server restarts: you will be reconnected automatically."));
                    SaveWorld(T("redémarrage", "restart"), true, false, 600);
                }
                if (menuGame.GameRunning)
                {
                    restartRequested = true;
                    menuGame.Kill();   // OnServerGameExited reads the settings and starts the game again with the world
                }
                else
                {
                    EndSession();
                    lock (gameExits) gameExits.Clear();
                    ReloadServerConfig();
                    BeginServerWorld(true);
                }
            }) { IsBackground = true, Name = "Server restart" }.Start();
        }

        /// <summary>"stop" (or the window closed): the world is saved, the players are told and the game closes. Then the
        /// window closes, or (the stop button, the console's "stop") opens again with the server stopped: MPFever starts
        /// again, which leaves nothing of the stopped session behind.</summary>
        void StopServer(bool closeWindow)
        {
            if (serverStopping) return;
            serverStopping = true;
            serverStoppedByHand = true;
            CutResyncShort(T("arrêt", "stop"));
            new Thread(() =>
            {
                Log.W(T("=== Arrêt du serveur ===", "=== The server stops ==="));
                ServerListRemove();
                try
                {
                    bool st; lock (sessionGate) st = started;
                    if (st)
                    {
                        HostChat("msg", server.Name, T("Le serveur s'arrête.", "The server is shutting down."));
                        SaveWorld(T("arrêt", "stop"), true, false, 600);
                    }
                    // (told so that their MPFever does not try to reconnect for 5 minutes)
                    var r = relay;
                    if (r != null) foreach (var p in r.Admitted()) r.Deny(p, "{[\"reason\"]=\"stopped\"}");
                    EndSession(T("=== Serveur arrêté ===", "=== Server stopped ==="));
                }
                catch (Exception e) { Log.Err(e.Message); }
                menuGame?.Kill();
                Thread.Sleep(500);
                if (!closeWindow)
                    try
                    {
                        Process.Start(new ProcessStartInfo(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "MPFever.exe"), string.Join(" ", ServerRunArgs()))
                            { UseShellExecute = false, WorkingDirectory = Environment.CurrentDirectory });
                    }
                    catch (Exception e) { Log.Err(e.Message); }
                serverClosed = true;
                try { BeginInvoke((Action)Close); } catch { }
            }) { IsBackground = true, Name = "Server stop" }.Start();
        }

        double updateEmptySince = -1;

        /// <summary>A new release while nobody is connected (or while the server is stopped): the world is saved, the game
        /// closes, the update is installed and MPFever starts again as the server was (running in its mode, which loads the
        /// world again, or stopped). If the update fails, the same version starts again.</summary>
        void ServerSelfUpdate(UpdateInfo u)
        {
            if (serverStopping) return;
            serverStopping = true;
            pendingUpdate = null;
            new Thread(() =>
            {
                Log.W(F("=== Mise à jour du serveur vers MPFever {0} ===", "=== The server updates to MPFever {0} ===", u.Version));
                ServerListRemove();
                try
                {
                    bool st; lock (sessionGate) st = started;
                    if (st) SaveWorld(T("mise à jour", "update"), true, false, 600);
                    var r = relay;
                    if (r != null) foreach (var p in r.Admitted()) r.Deny(p, "{[\"reason\"]=\"stopped\"}");
                    if (serverStarted) EndSession(T("=== Serveur arrêté pour la mise à jour ===", "=== Server stopped for the update ==="));
                }
                catch (Exception e) { Log.Err(e.Message); }
                menuGame?.Kill();
                Thread.Sleep(1500);
                try { Updater.Run(u, null, null); }
                catch (Exception e) { Log.Err(F("Échec de la mise à jour : {0}", "Update failed: {0}", Updater.Describe(e))); }
                try { Updater.Restart(ServerRunArgs()); }
                catch (Exception e) { Log.Err(e.Message); }
                serverClosed = true;
                try { BeginInvoke((Action)Close); } catch { }
            }) { IsBackground = true, Name = "Server update" }.Start();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // closing the window of a running server stops it properly (the world is saved first)
            if (server != null && !serverClosed && e.CloseReason != CloseReason.WindowsShutDown && menuGame != null && menuGame.GameRunning)
            {
                e.Cancel = true;
                StopServer(true);
                return;
            }
            base.OnFormClosing(e);
        }

        // ---------------------------------------------------------------- every second

        void ServerLoop()
        {
            while (!serverStopping)
            {
                Thread.Sleep(1000);
                try { ServerTick(); }
                catch (Exception e) { Log.W("server: " + e.Message); }
            }
        }

        void ServerTick()
        {
            if (server == null || hostGame == null) return;
            bool st, paused; int sp;
            lock (sessionGate) { st = started; paused = pauseAt.HasValue; sp = speed; }
            if (!st)
            {
                // the world does not load (an error window of the game, a savegame it refuses...)
                if (hostingSince > 0 && Now - hostingSince > WorldLoadTimeoutSeconds && menuGame.GameRunning)
                {
                    hostingSince = -1;
                    Log.Err(F("Le monde ne s'est pas chargé en {0} minutes : le jeu du serveur redémarre.", "The world did not load in {0} minutes: the server's game starts again.", (int)(WorldLoadTimeoutSeconds / 60)));
                    menuGame.Kill();
                }
                return;
            }
            hostingSince = -1;
            if (resyncing || serverSaving) return;

            // 1. nobody connected: the world waits for its players
            if (autoPaused && !paused) autoPaused = false;   // resumed meanwhile (a player who joined, the console)
            int connected = relay?.AdmittedCount ?? 0;
            if (server.PauseWhenEmpty && connected == 0)
            {
                if (emptySince < 0) emptySince = Now;
                if (!paused && Now - emptySince >= EmptyPauseSeconds)
                {
                    autoPaused = true;
                    Log.W(T("Plus personne n'est connecté : le monde attend ses joueurs (pause).", "Nobody is connected any more: the world waits for its players (paused)."));
                    Pause(T("serveur vide", "empty server"));
                }
            }
            else
            {
                emptySince = -1;
                int ready; lock (players) ready = players.Count(p => p != hostName);
                if (autoPaused && paused && ready > 0)
                {
                    autoPaused = false;
                    SetSpeed(Math.Max(1, sp), T("joueur connecté", "player connected"));
                }
            }

            // 2. a release published meanwhile: installed once nobody has been connected for 2 minutes (the players' MPFever
            // installs it at its next start; a player with the old version is refused, "other MPFever version")
            if (connected > 0) updateEmptySince = -1; else if (updateEmptySince < 0) updateEmptySince = Now;
            if (pendingUpdate != null && connected == 0 && Now - updateEmptySince >= 120 && !serverStopping)
            {
                ServerSelfUpdate(pendingUpdate);
                return;
            }

            // 3. autosave
            if (server.AutosaveMinutes > 0 && Now - lastAutosave >= server.AutosaveMinutes * 60.0)
            {
                lastAutosave = Now;
                new Thread(() => SaveWorld(T("sauvegarde automatique", "autosave"), false)) { IsBackground = true, Name = "Autosave" }.Start();
            }

            // 4. watchdog: a game that stopped sending its clock is frozen
            if (server.WatchdogSeconds > 0)
            {
                PlayerClock hc; lock (clocks) clocks.TryGetValue(hostName ?? "", out hc);
                if (hc != null && Now - hc.At > server.WatchdogSeconds && menuGame.GameRunning)
                {
                    lock (clocks) clocks.Remove(hostName);
                    Log.Err(F("Le jeu du serveur ne répond plus depuis {0} s : il redémarre.", "The server's game has not answered for {0} s: it starts again.", server.WatchdogSeconds));
                    menuGame.Kill();
                }
            }
        }

        /// <summary>A session that starts with nobody connected stays paused (pause-when-empty).</summary>
        bool ServerStartsPaused()
        {
            lock (sessionGate) speed = server.StartSpeed;   // the speed it resumes at
            if (!server.PauseWhenEmpty || (relay?.AdmittedCount ?? 0) > 0) return false;
            autoPaused = true;
            Log.W(T("Monde chargé. Personne n'est connecté : il attend ses joueurs (pause).", "World loaded. Nobody is connected: it waits for its players (paused)."));
            BroadcastSession();
            return true;
        }

        // ---------------------------------------------------------------- saving the world

        /// <summary>Saves the world under its name: the session pauses, the server's game saves, the session resumes. A
        /// copy goes to server\backups. Nothing is done when nothing changed since the last save (unless forced).</summary>
        bool SaveWorld(string why, bool force, bool resume = true, int waitSeconds = 0)
        {
            if (server == null) return false;
            if (waitSeconds > 0) WaitUntil(() => !resyncing, waitSeconds);   // (a resynchronisation decided, not started yet)
            if (!Monitor.TryEnter(worldGate, TimeSpan.FromSeconds(waitSeconds)))
            {
                if (force) Log.Warn(T("Sauvegarde du monde impossible pour l'instant (resynchronisation en cours).", "The world cannot be saved right now (resynchronisation running)."));
                return false;
            }
            try
            {
                bool st; lock (sessionGate) st = started;
                if (!st || hostGame == null || !menuGame.GameRunning || resyncing)
                {
                    if (force) Log.Warn(T("Aucun monde chargé : rien à sauvegarder.", "No world loaded: nothing to save."));
                    return false;
                }
                int acts = actsRelayed;
                long clock = MaxClock();
                if (!force && acts == savedActs && clock == savedClock) return true;   // (paused all along, no build)
                serverSaving = true;
                var t0 = DateTime.UtcNow;
                bool wasRunning; int prevSpeed;
                lock (sessionGate) { wasRunning = !pauseAt.HasValue; prevSpeed = Math.Max(1, speed); }
                if (wasRunning) Pause(why);
                long at; lock (sessionGate) at = pauseAt ?? 0;
                // the server's game stops at the pause (the players' games are held there by it)
                if (!WaitUntil(() => { lock (clocks) return clocks.TryGetValue(hostName, out var c) && c.T >= at && c.Sp == 0; }, 60))
                    Log.Warn(T("Le jeu du serveur ne s'est pas arrêté : sauvegarde quand même.", "The server's game did not stop: saving anyway."));
                int id = ServerSaveIdBase + Interlocked.Increment(ref serverSaveSeq);
                // (without display the game saves a black picture with the world: the one there before is kept, see KeepPicture)
                byte[] picture = serverHeadless ? WorldPicture() : null;
                serverSaveDone = null;
                hostGame.ToGame(Msg.Make("resync_save", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(server.World) + "}"));
                bool answered = WaitUntil(() => serverSaveDone is Dictionary<object, object> d && d.TryGetValue("id", out var v) && v is double dv && (int)dv == id, 180);
                var done = serverSaveDone;
                bool ok = answered && done != null && done.TryGetValue("ok", out var okv) && okv is bool b && b;
                if (ok)
                {
                    Thread.Sleep(1000);   // the file is closed by the game after its callback
                    if (serverHeadless) KeepPicture(picture);
                    savedActs = acts;
                    savedClock = clock;
                    lastSavedAt = DateTime.Now;
                    Log.Ok(F("Monde « {0} » sauvegardé ({1}, {2:0.0} s).", "World « {0} » saved ({1}, {2:0.0} s).", server.World, why, (DateTime.UtcNow - t0).TotalSeconds));
                    BackupWorld();
                }
                else if (answered)
                    Log.Err(F("Sauvegarde du monde refusée par le jeu : {0}", "World save refused by the game: {0}", done != null && done.TryGetValue("err", out var err) ? Convert.ToString(err, CultureInfo.InvariantCulture) : "?"));
                else
                    Log.Err(T("Sauvegarde du monde : pas de réponse du jeu.", "World save: no answer from the game."));
                serverSaving = false;
                if (wasRunning && resume && !serverStopping) SetSpeed(prevSpeed, T("fin de la sauvegarde", "end of the save"));
                return ok;
            }
            catch (Exception e) { Log.Err(T("Sauvegarde du monde : ", "World save: ") + e.Message); return false; }
            finally
            {
                serverSaving = false;
                lastAutosave = Now;
                Monitor.Exit(worldGate);
            }
        }

        /// <summary>A copy of the world's files (name.sav and the files next to it) in server\backups\name, the newest kept.</summary>
        /// <summary>The picture of the world's savegame (the .jpg next to it, shown in the game's load list), or null when
        /// there is none or it is black (a save made without display).</summary>
        byte[] WorldPicture()
        {
            try
            {
                var file = GameInstall.FindSave(server.World);
                var jpg = file == null ? null : Path.ChangeExtension(file, ".jpg");
                if (jpg == null || !File.Exists(jpg)) return null;
                var bytes = File.ReadAllBytes(jpg);
                using (var ms = new MemoryStream(bytes))
                using (var bmp = new System.Drawing.Bitmap(ms))
                {
                    // (a few points across the picture: all dark, a picture of nothing)
                    int bright = 0;
                    for (int i = 1; i < 10; i++)
                        for (int j = 1; j < 10; j++)
                        {
                            var c = bmp.GetPixel(bmp.Width * i / 10, bmp.Height * j / 10);
                            if (c.R + c.G + c.B > 60) bright++;
                        }
                    return bright >= 8 ? bytes : null;
                }
            }
            catch { return null; }
        }

        /// <summary>After a save without display: the world's picture of before, else one made here (the server's name and its
        /// world on a dark background), instead of the black one the game wrote.</summary>
        void KeepPicture(byte[] before)
        {
            try
            {
                var file = GameInstall.FindSave(server.World);
                if (file == null) return;
                var jpg = Path.ChangeExtension(file, ".jpg");
                if (before != null) { File.WriteAllBytes(jpg, before); return; }
                using (var bmp = new System.Drawing.Bitmap(1280, 720))
                using (var g = System.Drawing.Graphics.FromImage(bmp))
                using (var bg = new System.Drawing.Drawing2D.LinearGradientBrush(new System.Drawing.Rectangle(0, 0, 1280, 720),
                    System.Drawing.Color.FromArgb(28, 38, 56), System.Drawing.Color.FromArgb(12, 16, 24), 90f))
                using (var big = new System.Drawing.Font("Segoe UI", 54, System.Drawing.FontStyle.Bold))
                using (var small = new System.Drawing.Font("Segoe UI", 28))
                using (var accent = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(240, 160, 48)))
                using (var white = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(230, 230, 230)))
                {
                    g.FillRectangle(bg, 0, 0, 1280, 720);
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
                    g.DrawString("MPFever", big, accent, 80, 230);
                    g.DrawString(server.Name, small, white, 84, 340);
                    g.DrawString(server.World + "  ·  " + DateTime.Now.ToString("g", CultureInfo.CurrentCulture), small, white, 84, 390);
                    bmp.Save(jpg, System.Drawing.Imaging.ImageFormat.Jpeg);
                }
            }
            catch (Exception e) { Log.Dim("world picture: " + e.Message); }
        }

        void BackupWorld()
        {
            if (server.Backups <= 0) return;
            try
            {
                var file = GameInstall.FindSave(server.World);
                if (file == null) return;
                var safe = new string(server.World.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c).ToArray());
                var dir = Path.Combine(ServerDir, "backups", safe);
                Directory.CreateDirectory(dir);
                var stamp = DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss", CultureInfo.InvariantCulture);
                var src = Path.GetFileName(file);
                foreach (var f in Directory.GetFiles(Path.GetDirectoryName(file)))
                {
                    var n = Path.GetFileName(f);
                    if (n.Equals(src, StringComparison.OrdinalIgnoreCase) || n.StartsWith(src + ".", StringComparison.OrdinalIgnoreCase))
                        File.Copy(f, Path.Combine(dir, stamp + " " + n), true);
                }
                var stamps = Directory.GetFiles(dir).Select(Path.GetFileName).Where(n => n.Length > 20 && n[19] == ' ')
                    .Select(n => n.Substring(0, 19)).Distinct().OrderByDescending(x => x, StringComparer.Ordinal).ToList();
                foreach (var old in stamps.Skip(server.Backups))
                    foreach (var f in Directory.GetFiles(dir).Where(f => Path.GetFileName(f).StartsWith(old + " ", StringComparison.Ordinal)))
                        File.Delete(f);
            }
            catch (Exception e) { Log.Warn(T("Copie de sauvegarde : ", "Backup copy: ") + e.Message); }
        }

        // ---------------------------------------------------------------- players

        /// <summary>Who may come in: the same MPFever version, the password, a free place (a player reconnecting keeps
        /// its own). Returns null, or the payload of the "denied" message.</summary>
        string ServerAdmit(Relay r, Peer p, Msg m)
        {
            var refused = server.Admission(m.Payload, OthersConnected(r, p), out var reason);
            if (refused != null) Log.Warn(F("{0} ({1}) refusé : {2}", "{0} ({1}) refused: {2}", BaseName(p.Name), p.Address, reason));
            return refused;
        }

        /// <summary>The players connected besides p (its own older connection, closed when it comes back, not counted).</summary>
        internal static int OthersConnected(Relay r, Peer p)
        {
            var me = BaseName(p.Name);
            return r.Admitted().Count(o => o != p && !string.Equals(BaseName(o.Name), me, StringComparison.OrdinalIgnoreCase));
        }

        /// <summary>A player's game is in the world: the message of the day, once per connection.</summary>
        void ServerGreet(Peer p)
        {
            lock (greeted) if (!greeted.Add(BaseName(p.Name))) return;
            if (string.IsNullOrWhiteSpace(server.Motd)) return;
            long id; lock (chatLog) id = ++chatId;   // (a number of its own, for this player only)
            relay?.Send(p, Msg.Make("chatmsg", hostName, "{[\"id\"]=" + id + ",[\"t\"]=" + UnixNow() + ",[\"kind\"]=\"msg\",[\"name\"]="
                + LuaLit.Quote(server.Name) + ",[\"text\"]=" + LuaLit.Quote(ChatClean(server.Motd)) + "}"));
        }

        void ServerPlayerLeft(Peer p)
        {
            lock (greeted) greeted.Remove(BaseName(p.Name));
        }

        /// <summary>A player's own game as host: a guest on another version is refused (the "denied" payload), else null.</summary>
        internal static string VersionAdmit(string joinPayload)
        {
            var t = LuaLit.Parse(joinPayload ?? "") as Dictionary<object, object>;
            var v = t != null && t.TryGetValue("v", out var vo) && vo is string vs ? vs : "";
            if (v == Version) return null;
            Log.Warn(F("Un joueur avec MPFever {0} a été refusé : cette partie utilise {1}.", "A player with MPFever {0} was refused: this game runs {1}.", v == "" ? "?" : v, Version));
            return "{[\"reason\"]=\"version\",[\"v\"]=" + LuaLit.Quote(Version) + "}";
        }

        /// <summary>Why a host refused this player (the "denied" message), in the player's language.</summary>
        internal static string DeniedText(Dictionary<object, object> d)
        {
            string S(string k) => d.TryGetValue(k, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
            // (0.6: a player's own game refused this player, not a dedicated server; see PublicGames.cs)
            bool game = d.TryGetValue("game", out var gv) && gv is bool gb && gb;
            switch (S("reason"))
            {
                case "password": return T("Mot de passe du serveur incorrect ou manquant : tapez-le dans la fenêtre MPFever, puis rejoignez à nouveau.", "Wrong or missing server password: type it in the MPFever window, then join again.");
                case "full":
                    if (game) return F("La partie est pleine ({0} joueurs au maximum).", "The game is full ({0} players at most).", S("max"));
                    return F("Le serveur est plein ({0} joueurs au maximum).", "The server is full ({0} players at most).", S("max"));
                case "version": return F("L'hôte utilise MPFever {0} et vous {1} : tous les joueurs doivent installer la même version.", "The host runs MPFever {0} and you run {1}: every player needs the same version.", S("v"), Version);
                case "kicked":
                    if (game) return T("L'hôte vous a exclu de la partie.", "The host kicked you from the game.");
                    return T("Vous avez été exclu du serveur.", "You were kicked from the server.");
                case "stopped": return T("Le serveur a été arrêté.", "The server was stopped.");
                case "banned": return T("L'hôte vous a banni de ses parties.", "The host banned you from their games.");
                case "refused": return T("L'hôte n'a pas accepté votre arrivée.", "The host did not let you in.");
            }
            return F("Connexion refusée par l'hôte ({0}).", "Connection refused by the host ({0}).", S("reason"));
        }

        /// <summary>The addresses players join with: public IPv4 (unless lookupip=0 in mpfever_settings.txt), local, IPv6.</summary>
        void FindServerAddresses()
        {
            try
            {
                int port = server.Port;
                var list = new List<string>();
                var pub = PublicAddress();
                if (!string.IsNullOrEmpty(pub)) list.Add(NetAddr.Show(pub, port));
                foreach (var a in LocalAddresses().Split(',').Select(x => x.Trim()).Where(x => x.Length > 0 && x != "?"))
                    if (!list.Contains(NetAddr.Show(a, port))) list.Add(NetAddr.Show(a, port));
                foreach (var a in NetAddr.PublicIPv6List()) list.Add(NetAddr.Show(a, port));
                serverAddresses = string.Join(", ", list);
                Log.Ok(F("Les joueurs rejoignent le serveur avec : {0} (port TCP {1} à rediriger sur la box pour Internet)", "Players join the server with: {0} (TCP port {1}, to forward on the router for the Internet)", serverAddresses, port));
            }
            catch (Exception e) { Log.W("addresses: " + e.Message); }
        }

        // ---------------------------------------------------------------- console

        static string ServerHelp() => T(
            "Commandes du serveur :\n  start [headless]  démarre le serveur (headless : sans affichage)\n  status            joueurs, vitesse, synchronisation, dernière sauvegarde\n  say <texte>       message dans la discussion de tous les joueurs\n  save              sauvegarde le monde maintenant\n  pause | resume    met le monde en pause ou le relance\n  speed <1|2|4>     vitesse du jeu\n  kick <joueur>     exclut un joueur (il peut revenir)\n  resync            recharge le monde du serveur chez tous les joueurs\n  restart           relit les paramètres, sauvegarde et redémarre le monde\n  stop              sauvegarde le monde et arrête le serveur (la fenêtre reste ouverte)",
            "Server commands:\n  start [headless]  starts the server (headless: without display)\n  status            players, speed, sync, last save\n  say <text>        message in every player's chat\n  save              saves the world now\n  pause | resume    pauses the world or runs it again\n  speed <1|2|4>     game speed\n  kick <player>     kicks a player (who may come back)\n  resync            reloads the server's world on every player's game\n  restart           reads the settings again, saves and restarts the world\n  stop              saves the world and stops the server (the window stays open)");

        void ServerCommand(string line)
        {
            line = (line ?? "").Trim();
            if (line.Length == 0) return;
            Log.Write("> " + line, LogLevel.Section);
            int sp = line.IndexOf(' ');
            var cmd = (sp < 0 ? line : line.Substring(0, sp)).ToLowerInvariant().TrimStart('/');
            var arg = sp < 0 ? "" : line.Substring(sp + 1).Trim();
            bool st; lock (sessionGate) st = started;
            // (the server stopped: only what needs no world)
            if (!serverStarted && cmd != "help" && cmd != "?" && cmd != "start" && cmd != "status" && cmd != "list" && cmd != "stop" && cmd != "exit" && cmd != "quit")
            {
                Log.Warn(T("Le serveur est arrêté : démarrez-le (un bouton, ou « start » / « start headless »).", "The server is stopped: start it (a button, or « start » / « start headless »)."));
                return;
            }
            switch (cmd)
            {
                case "start":
                    if (serverStarted) { Log.Warn(T("Le serveur est déjà démarré.", "The server is already running.")); break; }
                    if (arg != "" && arg != "headless" && arg != "display") { Log.Warn("start [display|headless]"); break; }
                    StartServerMode(arg == "headless");
                    break;
                case "help": case "?":
                    foreach (var l in ServerHelp().Split('\n')) Log.Dim(l);
                    break;
                case "status": case "list":
                    foreach (var l in ServerStatusLines()) Log.W(l);
                    break;
                case "say":
                    if (arg.Length == 0 || relay == null) break;
                    HostChat("msg", server.Name, arg);
                    break;
                case "save":
                    new Thread(() => SaveWorld(T("console", "console"), true)) { IsBackground = true, Name = "Save" }.Start();
                    break;
                case "pause":
                    if (!st) { Log.Warn(T("Aucun monde chargé.", "No world loaded.")); break; }
                    autoPaused = false;
                    Pause(T("console", "console"));
                    break;
                case "resume": case "run":
                    if (!st) { Log.Warn(T("Aucun monde chargé.", "No world loaded.")); break; }
                    int cur; lock (sessionGate) cur = speed;
                    SetSpeed(Math.Max(1, cur), T("console", "console"));
                    break;
                case "speed":
                    if (!st) { Log.Warn(T("Aucun monde chargé.", "No world loaded.")); break; }
                    if (arg == "1" || arg == "2" || arg == "4") SetSpeed(int.Parse(arg, CultureInfo.InvariantCulture), T("console", "console"));
                    else Log.Warn("speed 1 | 2 | 4");
                    break;
                case "kick":
                    {
                        if (relay == null || arg.Length == 0) { Log.Warn("kick <player>"); break; }
                        var who = arg.Split(' ')[0];
                        int n = relay.Kick(who, "{[\"reason\"]=\"kicked\"}");
                        if (n == 0) Log.Warn(F("Aucun joueur « {0} » connecté.", "No player « {0} » connected.", who));
                        else Log.W(F("{0} exclu du serveur.", "{0} kicked from the server.", who));
                        break;
                    }
                case "resync":
                    {
                        int others; lock (players) others = players.Count(p => p != hostName);
                        // ((0.7.6) a resynchronisation under way said "no player to resynchronise": the user's server, 2026-11-07 20:06)
                        if (resyncing && Environment.GetEnvironmentVariable("MPFEVER_RESYNCMSGOLD") != "1") { Log.Warn(T("Une resynchronisation est déjà en cours.", "A resynchronisation is already under way.")); break; }
                        if (!st || others == 0 || resyncing) { Log.Warn(T("Pas de joueur à resynchroniser.", "No player to resynchronise.")); break; }
                        resyncing = true;
                        new Thread(() => Resync(T("demandée par la console", "asked by the console"))) { IsBackground = true, Name = "Resync" }.Start();
                        break;
                    }
                case "restart": case "reload":
                    RestartWorld();
                    break;
                case "stop":
                    if (!serverStarted) { Log.Warn(T("Le serveur est déjà arrêté.", "The server is already stopped.")); break; }
                    StopServer(false);
                    break;
                case "exit": case "quit":
                    if (!serverStarted) { serverClosed = true; Close(); break; }
                    StopServer(true);
                    break;
                default:
                    Log.Warn(F("Commande inconnue « {0} » : tapez help.", "Unknown command « {0} »: type help.", cmd));
                    break;
            }
        }

        /// <summary>What "status" prints, also the server card of the window.</summary>
        List<string> ServerStatusLines()
        {
            var res = new List<string>();
            bool st, paused; int sp;
            lock (sessionGate) { st = started; paused = pauseAt.HasValue; sp = speed; }
            string state = !serverStarted ? T("serveur arrêté", "server stopped")
                : !st ? (worldMissing ? T("monde introuvable", "world not found") : T("chargement du monde", "loading the world"))
                : paused ? (autoPaused ? T("en pause, en attente de joueurs", "paused, waiting for players") : T("en pause", "paused"))
                : F("en marche, x{0}", "running, x{0}", sp);
            res.Add(F("Monde « {0} » : {1}", "World « {0} »: {1}", server.World, state)
                + (!serverStarted ? "" : serverHeadless ? T(" (sans affichage)", " (without display)") : T(" (avec affichage)", " (with display)")));
            var peers = relay?.Admitted() ?? new Peer[0];
            string[] ready; lock (players) ready = players.ToArray();
            res.Add(F("Joueurs : {0}/{1}", "Players: {0}/{1}", peers.Length, server.MaxPlayers));
            HashSet<string> looking; lock (reviewing) looking = new HashSet<string>(reviewing);
            foreach (var p in peers.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                res.Add("    " + BaseName(p.Name) + "  ·  " + (ready.Contains(p.Name) ? T("en jeu", "in game")
                    : looking.Contains(p.Name) ? T("regarde les mods et DLC avant de rejoindre", "looks at the mods and DLCs before joining") : T("se connecte", "connecting")) + "  ·  " + p.Address);
            res.Add(T("Synchronisation : ", "Sync: ") + (syncText ?? "—"));
            res.Add(lastSavedAt.HasValue ? F("Dernière sauvegarde : {0:HH:mm:ss}", "Last save: {0:HH:mm:ss}", lastSavedAt.Value) : T("Pas encore sauvegardé.", "Not saved yet."));
            return res;
        }

        // ---------------------------------------------------------------- window

        Card serverCard;
        Panel serverIdle, serverRunning;
        ModernButton serverStopBtn;
        CheckBox autoStartBox;

        /// <summary>The left card of the window in server mode: the settings in use and the server's buttons (the two start
        /// buttons and the automatic start while it is stopped; save, restart and stop while it runs).</summary>
        Card BuildServerCard()
        {
            var card = new Card();
            serverCard = card;
            serverInfo = new Label { AutoSize = false, Height = Theme.S(170), ForeColor = Theme.Text, Font = Theme.Ui(9.5f) };
            var startDisplayBtn = new ModernButton(ButtonKind.Primary) { Text = "▶  " + T("Démarrer avec affichage", "Start with display") };
            var startHeadlessBtn = new ModernButton(ButtonKind.Secondary) { Text = "▶  " + T("Démarrer sans affichage", "Start without display") };
            autoStartBox = new CheckBox
            {
                Text = T("Démarrer le serveur à l'ouverture de MPFever (dans le dernier mode choisi)", "Start the server when MPFever opens (in the last mode chosen)"),
                Checked = ServerAutoStart, AutoSize = false, Height = Theme.S(44), Font = Theme.Ui(9.25f), ForeColor = Theme.Text,
            };
            startDisplayBtn.Click += (s, e) => ServerCommand("start");
            startHeadlessBtn.Click += (s, e) => ServerCommand("start headless");
            autoStartBox.CheckedChanged += (s, e) =>
            {
                SaveSetting("serverautostart", autoStartBox.Checked ? "1" : "0");
                Log.W(autoStartBox.Checked ? T("Le serveur démarrera à l'ouverture de MPFever.", "The server will start when MPFever opens.")
                                           : T("Le serveur ne démarrera plus à l'ouverture de MPFever.", "The server will no longer start when MPFever opens."));
            };
            var saveBtn = new ModernButton(ButtonKind.Primary) { Text = T("Sauvegarder maintenant", "Save now") };
            var restartBtn = new ModernButton(ButtonKind.Secondary) { Text = T("Redémarrer le monde", "Restart the world") };
            var settingsBtn = new ModernButton(ButtonKind.Ghost) { Text = T("Paramètres du serveur…", "Server settings…") };
            var stopBtn = new ModernButton(ButtonKind.Ghost) { Text = T("Arrêter le serveur", "Stop the server") };
            serverStopBtn = stopBtn;
            saveBtn.Click += (s, e) => ServerCommand("save");
            restartBtn.Click += (s, e) =>
            {
                if (MessageBox.Show(this, T("Redémarrer le monde maintenant ? Il est sauvegardé d'abord, les joueurs sont reconnectés automatiquement.", "Restart the world now? It is saved first, the players are reconnected automatically."),
                    "MPFever", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) ServerCommand("restart");
            };
            stopBtn.Click += (s, e) =>
            {
                if (MessageBox.Show(this, T("Arrêter le serveur ? Le monde est sauvegardé d'abord, puis la fenêtre attend un nouveau démarrage.", "Stop the server? The world is saved first, then the window waits for a new start."),
                    "MPFever", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) ServerCommand("stop");
            };
            // (0.7.0) the settings window (ServerSettingsDialog) instead of the file in Notepad; MPFEVER_SERVERNOTEPAD=1: the file
            settingsBtn.Click += (s, e) =>
            {
                if (Environment.GetEnvironmentVariable("MPFEVER_SERVERNOTEPAD") == "1")
                {
                    try { Process.Start("notepad.exe", "\"" + ServerConfig.DefaultPath + "\""); }
                    catch (Exception ex) { Log.W(ex.Message); }
                    return;
                }
                OpenServerSettings();
            };
            serverIdle = new Panel();
            Ui.StackTop(serverIdle, startDisplayBtn, Ui.Gap(8), startHeadlessBtn, Ui.Gap(6), autoStartBox, Ui.Gap(4));
            serverRunning = new Panel { Visible = false };
            Ui.StackTop(serverRunning, saveBtn, Ui.Gap(8), restartBtn, Ui.Gap(8));
            foreach (var p in new[] { serverIdle, serverRunning }) p.Height = p.Controls.Cast<Control>().Sum(c => c.Height);
            Ui.StackTop(card, Ui.Caption(T("Serveur dédié", "Dedicated server")), serverInfo, Ui.Gap(8), serverIdle, serverRunning, settingsBtn, Ui.Gap(4), stopBtn);
            stopBtn.Visible = false;
            FitServerCard();
            UpdateServerCard();
            return card;
        }

        /// <summary>(0.7.0) The server's settings window: saved, the settings are read again at once while the server is stopped (the
        /// card and the addresses show them), or at the next restart of the world while it runs (« Save and restart the world » now).</summary>
        void OpenServerSettings()
        {
            bool on = serverStarted && !serverStopping;
            using (var d = new ServerSettingsDialog(ServerConfig.DefaultPath, on))
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                if (!on) { ReloadServerConfig(); UpdateServerCard(); return; }
                if (d.RestartAsked) ServerCommand("restart");
                else Log.W(T("Paramètres enregistrés : ils s'appliqueront au prochain redémarrage du monde (bouton « Redémarrer le monde » ou « restart »).",
                    "Settings saved: they will apply at the next restart of the world (« Restart the world » button or « restart »)."));
            }
        }

        /// <summary>The buttons of the server as it is: stopped (the start buttons) or running.</summary>
        void UpdateServerButtons()
        {
            if (serverCard == null) return;
            bool on = serverStarted && !serverStopping;
            if (serverIdle.Visible == !on && serverRunning.Visible == on) return;
            serverIdle.Visible = !on;
            serverRunning.Visible = on;
            serverStopBtn.Visible = on;
            FitServerCard();
        }

        /// <summary>The card's height from what it shows. (From the server's state, not from Visible: before the window is shown,
        /// Visible says false for every control, and the card of a stopped server was built empty, without its start buttons.)</summary>
        void FitServerCard()
        {
            bool on = serverStarted && !serverStopping;
            int h = serverCard.Padding.Vertical;
            foreach (Control x in serverCard.Controls)
            {
                if (x.Dock != DockStyle.Top) continue;
                if (x == serverIdle ? on : (x == serverRunning || x == serverStopBtn) ? !on : false) continue;
                h += x.Height;
            }
            serverCard.Height = h;
        }

        void UpdateServerCard()
        {
            UpdateServerButtons();
            if (serverInfo == null || server == null) return;
            string next = server.AutosaveMinutes <= 0 ? T("désactivée", "off")
                : F("toutes les {0} min", "every {0} min", server.AutosaveMinutes) + (lastSavedAt.HasValue ? F(" · dernière {0:HH:mm}", " · last {0:HH:mm}", lastSavedAt.Value) : "");
            var text = string.Join("\n", new[]
            {
                server.Name + (!serverStarted ? T(" · arrêté", " · stopped") : serverHeadless ? T(" · sans affichage", " · without display") : T(" · avec affichage", " · with display")),
                F("Monde : {0}", "World: {0}", server.World == "" ? "—" : server.World) + (worldMissing ? "  ✖" : ""),
                F("Port : {0} · mot de passe : {1}", "Port: {0} · password: {1}", server.Port, server.Password == "" ? T("non", "no") : T("oui", "yes")),
                F("Entreprises : {0} · {1} joueurs max.", "Companies: {0} · {1} players max.", server.CompanyMode == "separate" ? T("une par joueur", "one per player") : T("une pour tous", "one for everybody"), server.MaxPlayers),
                T("Sauvegarde auto : ", "Autosave: ") + next,
                serverAddresses,
            });
            if (serverInfo.Text != text) serverInfo.Text = text;
        }

        /// <summary>The console under the log: a command line with its history (up and down arrows).</summary>
        Control BuildCommandLine()
        {
            cmdBox = new TextBox();
            var field = new InputBox(cmdBox) { Dock = DockStyle.Bottom, Height = Theme.S(38) };
            cmdBox.Font = Theme.Mono(9.5f);
            cmdBox.HandleCreated += (s, e) => SetCue(cmdBox, T("Commande du serveur (help pour la liste)", "Server command (help for the list)"));
            cmdBox.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter)
                {
                    e.SuppressKeyPress = true;
                    var line = cmdBox.Text;
                    cmdBox.Clear();
                    if (line.Trim().Length == 0) return;
                    cmdHistory.Remove(line);
                    cmdHistory.Add(line);
                    cmdHistoryPos = cmdHistory.Count;
                    try { ServerCommand(line); } catch (Exception ex) { Log.Err(ex.Message); }
                }
                else if (e.KeyCode == Keys.Up && cmdHistory.Count > 0)
                {
                    e.SuppressKeyPress = true;
                    cmdHistoryPos = Math.Max(0, cmdHistoryPos - 1);
                    cmdBox.Text = cmdHistory[cmdHistoryPos];
                    cmdBox.SelectionStart = cmdBox.TextLength;
                }
                else if (e.KeyCode == Keys.Down && cmdHistory.Count > 0)
                {
                    e.SuppressKeyPress = true;
                    cmdHistoryPos = Math.Min(cmdHistory.Count, cmdHistoryPos + 1);
                    cmdBox.Text = cmdHistoryPos < cmdHistory.Count ? cmdHistory[cmdHistoryPos] : "";
                    cmdBox.SelectionStart = cmdBox.TextLength;
                }
            };
            return field;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

        /// <summary>The grey hint of an empty text box (EM_SETCUEBANNER).</summary>
        static void SetCue(TextBox box, string text)
        {
            try { SendMessage(box.Handle, 0x1501, (IntPtr)1, text); } catch { }
        }
    }
}
