using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    static class Program
    {
        /// <summary>The arguments MPFever was started with (given again to the new MPFever.exe after an update).</summary>
        public static string[] Args = new string[0];

        [STAThread]
        static int Main(string[] args)
        {
            // --updated: started by the previous MPFever.exe right after it installed an update
            bool updated = args.Contains("--updated");
            args = args.Where(a => a != "--updated").ToArray();
            Args = args;
            // --modscan: each installed mod, whether it is personal (only this player's interface) and why not (diagnostics)
            if (args.Length > 0 && args[0] == "--modscan")
            {
                Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
                foreach (var row in Mods.ScanReport()) Console.WriteLine(row);
                return 0;
            }
            // --savecompanies <savegame file>: the computer companies a savegame holds, as the host's lobby takes them (diagnostics)
            if (args.Length > 1 && args[0] == "--savecompanies")
            {
                Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
                foreach (var c in SaveInfo.AiCompanies(args[1])) Console.WriteLine("ai:" + c.Number + " colour " + c.Color + " " + c.Name);
                return 0;
            }
            // --savemods <savegame file>: the mods a savegame lists, read from its start (0.7.0, diagnostics)
            if (args.Length > 1 && args[0] == "--savemods")
            {
                Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
                var t0 = DateTime.UtcNow;
                var mods = SaveInfo.Mods(args[1]);
                if (mods == null) Console.WriteLine("no mods list found");
                else foreach (var m in mods) Console.WriteLine(m.Id + " | " + m.Source + " | " + m.Hub + " | " + m.Name);
                Console.WriteLine(F("({0:0.00} s)", "({0:0.00} s)", (DateTime.UtcNow - t0).TotalSeconds));
                return 0;
            }
            if (args.Length > 0 && args[0] == "--selftest")
            {
                Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
                Log.Line += l => Console.WriteLine(l);
                return SelfTest.Run();
            }
            Theme.InitDpi();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
            MainForm.InitLanguage();
            MainForm.JustUpdated = updated;
            // --thanks: the thanks window alone (to look at it)
            // --settings: the settings window alone (to look at it)
            if (args.Length > 0 && args[0] == "--settings") { using (var t = new OptionsDialog(args.Contains("--guest"))) { t.StartPosition = FormStartPosition.CenterScreen; t.ShowInTaskbar = true; t.ShowDialog(); } return 0; }
            if (args.Length > 0 && args[0] == "--thanks") { using (var t = new ThanksDialog()) { t.StartPosition = FormStartPosition.CenterScreen; t.ShowInTaskbar = true; t.ShowDialog(); } return 0; }
            // --serversettings [file] [--shots <folder>]: the dedicated server's settings window alone (0.7.0, to look at it): the settings
            // file given (else mpfever_server.properties here); --shots saves a picture of each of its pages there and closes it
            if (args.Length > 0 && args[0] == "--serversettings")
            {
                var file = args.Length > 1 && !args[1].StartsWith("--", StringComparison.Ordinal) ? Path.GetFullPath(args[1]) : ServerConfig.DefaultPath;
                int si = Array.IndexOf(args, "--shots");
                using (var t = new ServerSettingsDialog(file, args.Contains("--running")))
                {
                    t.StartPosition = FormStartPosition.CenterScreen; t.ShowInTaskbar = true;
                    if (si >= 0 && si + 1 < args.Length) t.Shown += (s, e) => t.SaveShots(args[si + 1]);
                    t.ShowDialog();
                }
                return 0;
            }
            bool auto = args.Length > 0 && args[0] == "--autotest";
            MainForm.Dev = auto || args.Contains("--dev");
            // default: the game starts at once and the session is set up from its main menu (MPFever window)
            MainForm.MenuModeDefault = !MainForm.Dev;
            if (auto) GameLink.AutoSave = args.Length > 1 ? args[1] : "test multi";
            // started by the game from a Steam invitation: join that host at once
            int j = Array.IndexOf(args, "--join");
            if (j >= 0 && j + 1 < args.Length) MainForm.JoinAtStart = args[j + 1];
            // dedicated server: this PC's game runs the world for the players, nobody plays on it (mpfever_server.properties);
            // the server's archive opens its window by itself (server-edition.txt next to MPFever.exe)
            MainForm.ServerMode = !auto && (args.Contains("--server") || File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, MainForm.ServerEditionFile)));
            if (MainForm.ServerMode) MainForm.ServerArgs(args, updated);
            bool timer = FineTimer.Begin();
            try { Application.Run(new MainForm(auto)); }
            finally { if (timer) FineTimer.End(); }
            return 0;
        }
    }

    /// <summary>(0.6.12) Windows' timer at 1 ms while MPFever runs: without it every Thread.Sleep(5) of the links between the game and
    /// the network (out.log read, in.log written) lasts a timer tick, 15.6 ms, at each of the two launchers a build goes through
    /// (seen in TPF3-MP's measures, 2026-10-31). MPFEVER_TIMER1MS=0: the system's timer, as before.</summary>
    static class FineTimer
    {
        [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
        [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
        internal static bool Wanted() => Environment.GetEnvironmentVariable("MPFEVER_TIMER1MS") != "0";
        public static bool Begin()
        {
            if (!Wanted()) return false;
            try { return timeBeginPeriod(1) == 0; } catch { return false; }
        }
        public static void End() { try { timeEndPeriod(1); } catch { } }
    }

    sealed partial class MainForm : Form
    {
        public const string Version = "0.8.5";
        /// <summary>Developer mode (MPFever.exe --dev): local two-game test and determinism test buttons.</summary>
        public static bool Dev;
        public static bool MenuModeDefault;
        public static string JoinAtStart;
        /// <summary>Started by the previous MPFever.exe after an update (--updated).</summary>
        public static bool JustUpdated;
        string steamConnect, lastSteamJoin;
        int steamSeq;
        bool menuMode;

        // ---- main menu mode: the game's MPFever window drives the session
        GameLink menuGame;
        string menuPhase = "idle", menuText = "", menuLoad = "", menuLoadSeq = "", lastMenuReq;
        volatile bool joinPending;
        // (0.7.0, the host) the players who look at the game's mods and DLCs before joining a game already running (see the join
        // review): they get the game once they say so (joinready). MPFEVER_JOINREVIEW=0: a player gets the game at once, as before
        readonly HashSet<string> reviewing = new HashSet<string>();
        static bool JoinReviewOn => Environment.GetEnvironmentVariable("MPFEVER_JOINREVIEW") != "0";
        // (0.7.0, a player) the join waiting for the player's word (its page's « Join the game »): sends joinready and resync_have;
        // and what the player accepted (host run, mods, DLCs): the same again after a cut joins without asking
        volatile Action reviewSend;
        volatile string reviewAccepted;
        volatile bool clientCancelled;
        // ---- lobby: the host's session is open in the main menu, players join it there, and the host starts the game for
        // everybody at once (each game loads the host's savegame at the same time); a player may still join a running game
        volatile bool lobbyOpen, lobbyStarting;
        string lobbySave = "", lobbyPlayers = "";
        volatile bool lobbySaveSeparate;   // (0.6.8) the lobby's savegame was played with one company per player (SaveInfo.SeparateOf)
        // one company per player: the colour each player of the lobby picked (palette index, by name without its number), kept by
        // the host and sent with the lobby; a player who joins sees them as lobbyColors ("name:index,...") and the host's mode
        readonly Dictionary<string, int> lobbyColorOf = new Dictionary<string, int>();
        string lobbyColors = "", lobbyMode = "";
        string hostCompanyMode = "";   // (a player) the host's company mode, from its "session" messages: see ReportCompanyMode
        // one company per player: the computer companies of the host's lobby (experimental, 0.5.12), by number n of their key
        // "ai:<n>" in the companies' registry: their colour (palette index) and name (a savegame's, "" for a new one). Those of the
        // lobby's savegame are there from the start (SaveInfo.AiCompanies); the host adds, removes and colours them. Sent to the
        // games with the session (ai= "n:colour,..."), the host's game runs them (mpfever_ai.lua); a player who joins the lobby
        // sees them (lobbyAiText, "n:colour:level:name;..."). Level (0.5.13): 1 easy, 2 normal (the default), 3 hard
        // (Money, 0.5.14: its start money, -1 = the players')
        sealed class LobbyAi { public int Color; public string Name = ""; public int Level = 2; public long Money = -1; }
        readonly SortedDictionary<int, LobbyAi> lobbyAi = new SortedDictionary<int, LobbyAi>();
        string lobbyAiText = "", lobbyRulesText = "";
        // (0.6) a player in a host's lobby: the host's game options (see GameOpts)
        string lobbyOptsText = "";
        // the mods of the lobby's savegame ("id|name|origin" entries separated by ";;", see mpfever_menu.lua): written by the
        // host's menu (host_mods.txt), sent to the players of the lobby, shown by their menu with those missing on their PC
        string lobbyMods = "";
        // (a player) the host's mods compared with this PC's (see Mods.Compare): a mod in another version blocks the load
        Mods.Check modCheck;
        // (the host) the players whose mods are not the host's version, and which ones
        readonly Dictionary<string, string> modIssues = new Dictionary<string, string>();
        // (0.6.9) the players whose DLCs are not the host's: the warning for each (see Mods.DlcWarning); this player's own warning
        // when it is in another host's lobby or session
        readonly Dictionary<string, string> dlcIssues = new Dictionary<string, string>();
        string dlcWarn = "";
        // (0.7.0) the savegame's mods are known (host_mods.txt written by the host's menu, or read from a dedicated server's
        // world): the session's DLCs are then the savegame's (see SessionDlcs), the host may have switched one off in it
        bool lobbyModsKnown;
        // (0.7.0, a player) the host's DLCs for the menu's DLC list: "id|name|state|store;..." (state: both, host = the host's game
        // uses it and this PC lacks it, mine = this PC has it and the host's game does not), see DlcListView
        string dlcListView = "";
        // Mods a player lacks that no Mod Hub has (the host's own local mods, see Mods): the host is asked whether to send them
        // from its PC (with their size), the player whether to take them (they hold code its game will run).
        // (the host) the players' missing ones: player -> ids; its answer given: player -> "sent" / "refused"
        readonly Dictionary<string, string> modAsks = new Dictionary<string, string>();
        readonly Dictionary<string, string> modAskDone = new Dictionary<string, string>();
        string modSendText = "";
        // (a player) the host's offer ("ids|MB"), where the player's ask stands ("waiting", "refused") and what came
        string modOffer = "", modAskState = "", modRecvText = "";
        readonly Dictionary<string, string[]> modParts = new Dictionary<string, string[]>();
        // (a player) the mods of the offer this player took: the only ones it installs (lock modParts)
        readonly HashSet<string> modTaken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // the host's addresses shown in its lobby: public (Internet, "" while looked up, "?" when unknown) and local network
        string lobbyPublic = "", lobbyLocal = "";
        int lobbyPort;
        // (0.6) the session's game options are GameOptions(): the string the lobby's "Game settings" edit ("id=1;id.param=v;...",
        // docs/FEATURES-0.6.md), read through OptValue by MPFever.exe's own options (the public games: PublicGames.cs). Kept in
        // memory (KeptGameOptions): read once from mpfever_settings.txt, then changed only by SaveSetting("gameopts"); the status,
        // the session and the public games read them every second or so, and a read that failed (the file written by another
        // request at that moment, an antivirus) turned every option off in every game for 10 s. (autotests, the scenario pubtest:
        // the scenario's own options, never written into mpfever_settings.txt)
        static volatile string gameOptsKept;
        volatile string gameOptsTest;

        /// <summary>One value of an options string "id=1;id.param=v;..." (the key "id" or "id.param"), or null when absent.</summary>
        internal static string OptValue(string opts, string key)
        {
            foreach (var part in (opts ?? "").Split(';'))
            {
                int i = part.IndexOf('=');
                if (i > 0 && part.Substring(0, i).Trim() == key) return part.Substring(i + 1).Trim();
            }
            return null;
        }
        const long Step = 200;                 // game time units per simulation step
        const double UnitsPerSecond = 1000;    // game time units per real second at x1
        const double HashEverySeconds = 10;

        readonly TextBox nameBox = new TextBox { Text = SavedName() };
        readonly TextBox hostBox = new TextBox { Text = "127.0.0.1" };
        // ((0.7.13) the « Connection » card that showed it is gone from a player's window, see ConnCard: port= in
        // mpfever_settings.txt instead, 28090 without it as before)
        readonly NumericUpDown portBox = new NumericUpDown { Minimum = 1024, Maximum = 65535, Value = SavedPort() };
        readonly ModernButton hostBtn = new ModernButton(ButtonKind.Primary);
        readonly ModernButton joinBtn = new ModernButton(ButtonKind.Secondary);
        readonly ModernButton localBtn = new ModernButton(ButtonKind.Ghost);
        readonly ModernButton startBtn = new ModernButton(ButtonKind.Primary) { Enabled = false };
        // (issue #94: shown in place of startBtn once the game is closed)
        readonly ModernButton againBtn = new ModernButton(ButtonKind.Primary) { Visible = false };
        bool gameClosed, updateInstalled;
        // (0.7.4) The game no longer starts by itself: the player sets MPFever up first, then clicks « Start Transport Fever 3 »;
        // the box makes it start by itself next time (off for everybody at first, autolaunch=1 in mpfever_settings.txt once
        // ticked). A Steam invitation and « Start Transport Fever 3 again » start it at once, as before.
        readonly ModernButton launchBtn = new ModernButton(ButtonKind.Primary) { Visible = false };
        readonly CheckBox autoLaunchBox = new CheckBox { Visible = false, AutoSize = true };
        // (0.7.4) The mod put into the game (InstallMod and the rest of Init) runs beside the window now: the window said "not
        // responding" for those seconds. A moving bar says to wait meanwhile.
        readonly ProgressBar busyBar = new ProgressBar { Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30, Visible = false };
        volatile bool waitingLaunch, installing;
        readonly ModernButton pauseBtn = new ModernButton(ButtonKind.Segment) { Enabled = false };
        readonly ModernButton x1Btn = new ModernButton(ButtonKind.Segment) { Text = "x1", Enabled = false };
        readonly ModernButton x2Btn = new ModernButton(ButtonKind.Segment) { Text = "x2", Enabled = false };
        readonly ModernButton x4Btn = new ModernButton(ButtonKind.Segment) { Text = "x4", Enabled = false };
        readonly ModernButton detBtn = new ModernButton(ButtonKind.Ghost) { Enabled = false };
        readonly ModernButton langBtn = new ModernButton(ButtonKind.Ghost) { Globe = true };
        readonly RichTextBox logBox = new RichTextBox { ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = RichTextBoxScrollBars.Vertical, Dock = DockStyle.Fill, Font = Theme.Mono(9f), BackColor = Theme.Surface, ForeColor = Theme.Text, DetectUrls = false, WordWrap = true };
        readonly Label status = new Label { AutoSize = false, AutoEllipsis = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Text = T("Prêt.", "Ready."), ForeColor = Theme.Muted };

        // ---- dashboard (display only)
        HeaderBar header;
        StatTile playersTile, speedTile, actionsTile, syncTile;
        readonly Label hint = new Label { Dock = DockStyle.Fill, ForeColor = Theme.Text, AutoSize = false };
        readonly Label gameLabel = new Label { Dock = DockStyle.Right, AutoSize = false, AutoEllipsis = true, Width = 0, TextAlign = ContentAlignment.MiddleRight, ForeColor = Theme.Faint };
        int logLines;
        bool gameMissing;
        int syncState;   // 0 not checked, 1 identical, 2 slight drift, 3 out of sync

        // ---- session status for the in-game MPFever window (players, links, sync)
        readonly Dictionary<string, double> leftAt = new Dictionary<string, double>();   // player (without #id) -> when it left
        string syncParts = "";
        double lastSyncAt = -1;
        bool statusFailed;

        string gameDir;
        Relay relay;
        readonly List<GameLink> games = new List<GameLink>();
        readonly List<Client> clients = new List<Client>();
        string hostName;
        /// <summary>The host's Steam id once its game's module carries Steam connections to the Relay (SteamNet), else null.</summary>
        volatile string hostSteamId;
        GameLink hostGame;
        bool running;
        Action<GameLink, Msg> hostFromGame, clientFromGame;   // the session's handlers on the game's messages (removed at its end)
        int sessionGen;
        int censusN;                                         // autotest: census taken so far                                      // a new session: the threads of the previous one stop
        // (a player) joins and reconnections under way: StartClient's first connection, a Reconnect thread (see LeaveOnGameExit)
        int clientJoins;
        // the session as a problem report describes it, taken when the game closed (see LeaveOnGameExit): a report made after that
        // (the crash question, the thanks window's Report) still tells the role and the players of the session that ran
        string leftSession;

        // ---- host session state
        readonly object sendGate = new object();   // every host broadcast goes through this lock: same order for everybody
        readonly object sessionGate = new object();
        readonly Stopwatch clockWatch = Stopwatch.StartNew();
        sealed class PlayerClock { public long T; public int Sp; public double At; }
        readonly Dictionary<string, PlayerClock> clocks = new Dictionary<string, PlayerClock>();
        readonly HashSet<string> players = new HashSet<string>();
        bool started;
        int speed;            // session speed
        long? pauseAt;        // session paused at this game time
        int hashN;
        readonly Dictionary<int, Dictionary<string, Dictionary<object, object>>> hashes = new Dictionary<int, Dictionary<string, Dictionary<object, object>>>();
        // (the turns of the pause each game had applied at a check, by check number: see OnSyncHash; under the hashes lock)
        readonly Dictionary<int, Dictionary<string, double>> hashTurns = new Dictionary<int, Dictionary<string, double>>();
        string syncText = "—";
        int actsRelayed, actRefused, actFails, desyncs;
        double lastLoadOrder = -1000;   // when this machine's game was last told to load a game (a load may pass through the main menu)
        volatile bool resyncDropping;   // from the host's save to the end of the loads: actions are not relayed
        double lastActRelayed;   // when the last action was relayed (the checks of a paused session wait for quiet)
        string joinedAddr;   // the host this menu joined (a second request for it is ignored)
        volatile bool detRunning;

        // ---- determinism test
        readonly object detGate = new object();
        Dictionary<string, Dictionary<object, object>> detHashes;
        int detRound = -1;

        // ---- host authority: resynchronisation by the host's savegame
        const double ResyncCooldownSeconds = 120;   // at most one resynchronisation every 2 minutes
        const string ResyncSaveName = "MPFever resync";
        // (64 KB since 0.5.0: each player gets its parts by itself, and a part holds that player's other messages while it goes)
        const int ResyncChunk = 64 * 1024;
        volatile bool resyncing;
        volatile bool resyncSending;   // from the list of the games that reload the host's game to the end of a resynchronisation
        double lastResync = -1e9;
        int resyncId;
        readonly HashSet<string> resyncWaiting = new HashSet<string>();
        Dictionary<object, object> saveDone;
        string lastDiffKeys = "";
        int diffStreak;
        readonly Dictionary<string, int> partStreak = new Dictionary<string, int>();
        int postResyncHashN = -1;
        readonly HashSet<string> ignoredParts = new HashSet<string>();
        // (0.6.5, #111) parts a game does not measure, told once (see NotMeasured)
        readonly HashSet<string> unmeasuredParts = new HashSet<string>();
        /// <summary>(0.6.5, #111) The value a game gives for a part it does not measure: "off" (ages without the native module's
        /// tick epochs), "none" (a component the game has not got), "absent" (a key of a newer version).</summary>
        internal static bool NotMeasured(string shown) => shown == "off" || shown == "none" || shown == "absent";
        // parts every game corrects by itself from the host's values (not a reason to reload)
        // ("names": the default names of new vehicles, lines and stations are in each game's language, and the host's game sends
        // its names after each check (namesync, 0.5.14). Bought in a row, the vehicles kept the part different from one check to
        // the next: "OUT OF SYNC" at every purchase and a reload, #101/#102. MPFEVER_NAMESCHECK=1: a reason to reload, as before)
        static readonly HashSet<string> CorrectedParts = Environment.GetEnvironmentVariable("MPFEVER_NAMESCHECK") == "1"
            ? new HashSet<string> { "money" } : new HashSet<string> { "money", "names" };
        // parts only logged, never a reason to reload: "buildIds" reads a build's new ids by place a little after the build, and at
        // a speed above 1 the games read it at different steps (one after the next build had replaced the segment): the friends'
        // session of 2026-10-25 22:32 reloaded for nothing (every action's result was the same on both games)
        // ((0.7.13, #150/#166: the persons' drift showed only minutes later, through the towns and the fares) "personsDigest", one
        // person in eight by where it is and where it goes, tells when the persons went otherwise first; the bridge's
        // MPFEVER_PERSONDIGEST=0 gives "off", not compared)
        // ((0.8.3) "stepsDigest": the native module's digest of 50 simulation steps (the free-id queue, the entities made and taken
        // away), see StepsWindow; at the first check where it differs, every game keeps its drift rings, see stepsDumped)
        static readonly HashSet<string> DiagnosticParts = new HashSet<string> { "buildIds", "personsDigest", "stepsDigest" };
        // (0.8.3) the drift rings asked for once per run at the first check whose steps' digests differ (a reload starts a new run)
        bool stepsDumped;
        // (0.8.4) the risky personal mods of this player's load last told in the chat (see Mods.RiskyPlan), once per session
        string riskyAnnounced = "";
        string lastDiagDiffs = "";
        // game state that is never a local measure, even when it differs right after a reload (a company a game missed must be seen)
        // ((0.7.5) "edges2": the segments' second half, see the checks' halves in the bridge's simHash)
        // ((0.7.13) "personsDigest", a diagnostic: still logged after a reload, never "a local measure")
        static readonly HashSet<string> NeverLocalParts = new HashSet<string> { "companies", "money", "owners", "loans", "edges", "edges2", "ages", "buildIds", "constructions", "lines", "personsDigest", "stepsDigest" };
        // the simulation's own state (passengers boarding, vehicle positions, the towns and what follows them): it used to drift
        // by itself (the game's Lua walked its tables in a different order on every PC, fixed in 0.3.4), so it was only reloaded
        // when it lasted. The games now stay identical: a difference there comes from an action applied differently and must be
        // corrected soon (a game that goes on with other towns can crash at the next build the others make).
        static readonly HashSet<string> DriftParts = new HashSet<string> { "vehicles", "onboard", "persons", "stocks",
            "script:towns", "script:towncargo", "script:celebrations", "script:progression", "script:industries",
            // (not the engine's drift: lane connections, crosswalks and traffic lights of the road nodes. New and little
            // proven as a check, so it only reloads when it lasts)
            "nodeConfigs" };
        const double DriftResyncSeconds = 30;
        // the crosswalk order of a few road nodes differs between games by itself (no effect seen): reloaded only when it lasts
        const double NodeConfigsResyncSeconds = 300;
        double driftSince = -1;
        double lastNotStartedLog = -1e9;

        readonly bool autotest;
        readonly List<string> autoReport = new List<string>();
        readonly Dictionary<string, string> autoDone = new Dictionary<string, string>();
        volatile bool recplayStart;

        public MainForm(bool autotest = false)
        {
            this.autotest = autotest;
            // (MPFEVER_OPTIONS=1: an autotest of the settings themselves, their file decides)
            Options.Disabled = autotest && Environment.GetEnvironmentVariable("MPFEVER_OPTIONS") != "1";
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            var work = Screen.PrimaryScreen.WorkingArea;
            Size = new Size(Math.Min(Theme.S(1220), work.Width), Math.Min(Theme.S(780), work.Height));
            MinimumSize = new Size(Math.Min(Theme.S(960), work.Width), Math.Min(Theme.S(640), work.Height));
            StartPosition = FormStartPosition.CenterScreen;
            var icon = Theme.AppIcon();
            if (icon != null) Icon = icon;
            HandleCreated += (s, e) => Theme.DarkTitleBar(Handle);
            logBox.HandleCreated += (s, e) => Theme.DarkScrollBars(logBox);
            BuildUi();

            Log.Entry += (l, level) => { try { BeginInvoke((Action)(() => AppendLog(l, level))); } catch { } };
            langBtn.Click += (s, e) => ShowLanguageMenu();
            L.Changed += () => { try { BeginInvoke((Action)OnLanguageChanged); } catch { } };

            hostBtn.Click += (s, e) => Guard(() => StartHost(PlayerName(), true));
            joinBtn.Click += (s, e) => Guard(() => StartClient(PlayerName(), hostBox.Text.Trim(), (int)portBox.Value, true));
            localBtn.Click += (s, e) => Guard(StartLocalTest);
            startBtn.Click += (s, e) => StartSession();
            againBtn.Click += (s, e) => StartAgain(updateInstalled);
            launchBtn.Click += (s, e) => LaunchFromButton();
            autoLaunchBox.CheckedChanged += (s, e) => { if (autoLaunchShown) SaveSetting("autolaunch", autoLaunchBox.Checked ? "1" : "0"); };
            pauseBtn.Click += (s, e) => Pause(T("hôte", "host"));
            x1Btn.Click += (s, e) => SetSpeed(1, T("hôte", "host"));
            x2Btn.Click += (s, e) => SetSpeed(2, T("hôte", "host"));
            x4Btn.Click += (s, e) => SetSpeed(4, T("hôte", "host"));
            detBtn.Click += (s, e) => new Thread(RunDeterminism) { IsBackground = true }.Start();

            Shown += (s, e) => CheckUpdateThenInit();
            var uiTimer = new System.Windows.Forms.Timer { Interval = 500 };
            uiTimer.Tick += (s, e) => RefreshStatus();
            uiTimer.Start();
        }

        // ---------------------------------------------------------------- window layout (display only)

        void BuildUi()
        {
            var S = (Func<int, int>)Theme.S;
            Theme.SetLanguage(L.Code);
            Font = Theme.Ui(9.75f);
            Text = "MPFever " + Version + (ServerMode ? T(" – serveur dédié Transport Fever 3", " – Transport Fever 3 dedicated server")
                                                       : T(" – multijoueur Transport Fever 3", " – Transport Fever 3 multiplayer"));
            hostBtn.Text = T("Héberger une partie", "Host a game");
            joinBtn.Text = T("Rejoindre par IP", "Join by IP");
            localBtn.Text = T("Test local (2 jeux)", "Local test (2 games)");
            startBtn.Text = T("▶  Démarrer la partie", "▶  Start the game");
            againBtn.Text = T("Relancer Transport Fever 3", "Start Transport Fever 3 again");
            launchBtn.Text = T("▶  Lancer Transport Fever 3", "▶  Start Transport Fever 3");
            autoLaunchShown = false;
            autoLaunchBox.Text = T("Lancer le jeu automatiquement à l'ouverture de MPFever", "Start the game by itself when MPFever opens");
            autoLaunchBox.Checked = AutoLaunchSetting();
            autoLaunchShown = true;
            autoLaunchBox.Font = Theme.Ui(9.5f);
            autoLaunchBox.ForeColor = Theme.Text;
            autoLaunchBox.BackColor = Color.Transparent;
            pauseBtn.Text = "❚❚  " + T("Pause", "Pause");
            detBtn.Text = T("Test déterminisme", "Determinism test");
            langBtn.Text = L.Name + "  ▾";
            foreach (var b in new[] { hostBtn, joinBtn, localBtn, startBtn, againBtn, launchBtn, pauseBtn, x1Btn, x2Btn, x4Btn, detBtn, langBtn }) b.ResetFont();
            logBox.Font = Theme.Mono(9f);

            header = new HeaderBar(T("Multijoueur pour Transport Fever 3", "Multiplayer for Transport Fever 3"), "v" + Version, langBtn);

            // ---- left column: connection + contextual help
            var conn = new Card { };
            var hostRow = new TableLayoutPanel { Height = S(62), ColumnCount = 2, RowCount = 1, Margin = Padding.Empty, Padding = Padding.Empty };
            hostRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            hostRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, S(104)));
            var hostField = Ui.Field(T("Adresse de l'hôte", "Host address"), hostBox);
            var portField = Ui.Field(T("Port", "Port"), portBox);
            hostField.Dock = portField.Dock = DockStyle.Fill;
            hostField.Margin = new Padding(0, 0, S(10), 0);
            portField.Margin = Padding.Empty;
            hostRow.Controls.Add(hostField, 0, 0);
            hostRow.Controls.Add(portField, 1, 0);
            var connItems = new List<Control> {
                Ui.Caption(T("Connexion", "Connection")),
                Ui.Field(T("Votre nom", "Your name"), nameBox),
                Ui.Gap(8), hostRow, Ui.Gap(16), hostBtn, Ui.Gap(8), joinBtn };
            if (Dev) connItems.AddRange(new Control[] { Ui.Gap(8), localBtn });
            Ui.StackTop(conn, connItems.ToArray());
            Ui.FitHeight(conn);

            var info = new Card();
            hint.Font = Theme.Ui(9.75f);
            info.Controls.Add(hint);
            Ui.StackTop(info, Ui.Caption(T("Que faire ?", "What next?")));

            var left = new Panel { Dock = DockStyle.Left, Width = S(340), Padding = new Padding(0, 0, S(16), 0) };
            info.Dock = DockStyle.Fill;
            left.Controls.Add(info);
            // a dedicated server: its settings and its buttons instead of host / join; (0.7.13) a player: the settings window,
            // Ko-fi and Discord instead of host / join, which the game's Multiplayer page does (the old card: --dev, MPFEVER_CONNCARD=1)
            Ui.StackTop(left, ServerMode ? BuildServerCard() : ConnCardOn ? conn : BuildLinksCard(), Ui.Gap(14));

            // ---- right column: session controls, dashboard, log
            var session = new Card { Height = S(74), Padding = new Padding(S(16), S(17), S(16), S(16)) };
            var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = Padding.Empty, Padding = Padding.Empty };
            startBtn.Fit(40); startBtn.Margin = new Padding(0, 0, S(18), 0);
            againBtn.Fit(40); againBtn.Margin = new Padding(0, 0, S(18), 0);
            launchBtn.Fit(40); launchBtn.Margin = new Padding(0, 0, S(14), 0);
            autoLaunchBox.Margin = new Padding(0, S(10), S(14), 0);
            busyBar.Width = S(160); busyBar.Height = S(14); busyBar.Margin = new Padding(0, S(13), S(14), 0);
            speedLabel = new Label { Text = T("VITESSE", "SPEED"), AutoSize = true, Font = Theme.Semibold(8f), ForeColor = Theme.Muted, Margin = new Padding(0, S(12), S(10), 0) };
            pauseBtn.Fit(30); pauseBtn.Margin = new Padding(0, 0, S(4), 0);
            foreach (var b in new[] { x1Btn, x2Btn, x4Btn }) { b.Width = S(52); b.Margin = new Padding(0, 0, S(4), 0); }
            bar.Controls.AddRange(new Control[] { busyBar, launchBtn, autoLaunchBox, startBtn, againBtn, speedLabel, pauseBtn, x1Btn, x2Btn, x4Btn });
            ShowLaunchControls();
            if (Dev) { detBtn.Height = S(38); detBtn.Fit(); detBtn.Margin = new Padding(S(14), 0, 0, 0); bar.Controls.Add(detBtn); }
            session.Controls.Add(bar);

            playersTile = new StatTile(T("Joueurs", "Players"));
            speedTile = new StatTile(T("Vitesse", "Speed"));
            actionsTile = new StatTile(T("Actions relayées", "Actions relayed"));
            syncTile = new StatTile(T("Synchronisation", "Sync"));
            var tiles = new TableLayoutPanel { Height = S(96), ColumnCount = 4, RowCount = 1, Margin = Padding.Empty, Padding = Padding.Empty };
            var tileList = new[] { playersTile, speedTile, actionsTile, syncTile };
            for (int i = 0; i < tileList.Length; i++)
            {
                tiles.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25));
                tileList[i].Dock = DockStyle.Fill;
                tileList[i].Margin = new Padding(0, 0, i < tileList.Length - 1 ? S(12) : 0, 0);
                tiles.Controls.Add(tileList[i], i, 0);
            }

            var logCard = new Card { Dock = DockStyle.Fill, Padding = new Padding(S(18), S(12), S(8), S(10)) };
            var logHead = new Panel { Height = S(40) };
            var logTitle = Ui.Caption(T("Journal", "Log"));
            logTitle.Dock = DockStyle.Left; logTitle.Width = S(160); logTitle.Padding = new Padding(0, S(8), 0, 0);
            var tools = new FlowLayoutPanel { Dock = DockStyle.Right, AutoSize = true, WrapContents = false, Padding = new Padding(0, 0, S(8), 0) };
            var clearBtn = new ModernButton(ButtonKind.Ghost) { Text = T("Effacer", "Clear") }.Fit();
            var copyBtn = new ModernButton(ButtonKind.Ghost) { Text = T("Copier", "Copy") }.Fit();
            var folderBtn = new ModernButton(ButtonKind.Ghost) { Text = T("Dossier des journaux", "Logs folder") }.Fit();
            var reportBtn = new ModernButton(ButtonKind.Ghost) { Text = T("Signaler un problème", "Report a problem") }.Fit();
            reportBtn.Click += (s, e) => new Thread(() => Report(false)) { IsBackground = true, Name = "Report" }.Start();
            foreach (var b in new[] { reportBtn, folderBtn, copyBtn, clearBtn }) { b.Margin = new Padding(S(6), 0, 0, 0); tools.Controls.Add(b); }
            logHead.Controls.Add(logTitle);
            logHead.Controls.Add(tools);
            logCard.Controls.Add(logBox);
            if (ServerMode)
            {
                // the server console, under the log
                logCard.Controls.Add(new Panel { Dock = DockStyle.Bottom, Height = S(8) });
                logCard.Controls.Add(BuildCommandLine());
            }
            Ui.StackTop(logCard, logHead, Ui.Gap(4));
            clearBtn.Click += (s, e) => { logBox.Clear(); logLines = 0; };
            copyBtn.Click += (s, e) => { try { if (logBox.TextLength > 0) Clipboard.SetText(logBox.Text); } catch { } };
            folderBtn.Click += (s, e) =>
            {
                try { Process.Start("explorer.exe", "\"" + Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs") + "\""); }
                catch (Exception ex) { Log.W(ex.Message); }
            };

            var right = new Panel { Dock = DockStyle.Fill };
            right.Controls.Add(logCard);
            Ui.StackTop(right, session, Ui.Gap(14), tiles, Ui.Gap(14));

            var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(S(20), S(18), S(20), S(16)) };
            body.Controls.Add(right);
            body.Controls.Add(left);

            // ---- status bar
            var footer = new Panel { Dock = DockStyle.Bottom, Height = S(32), BackColor = Theme.Surface, Padding = new Padding(S(20), 0, S(20), 0) };
            footer.Paint += (s, e) => { using (var p = new Pen(Theme.Border)) e.Graphics.DrawLine(p, 0, 0, footer.Width, 0); };
            status.Font = Theme.Ui(9f);
            gameLabel.Font = Theme.Ui(8.5f);
            const string author = "dkdknight";
            var creditFont = Theme.Ui(8.5f);
            var by = new Label { Text = "© by", AutoSize = false, Dock = DockStyle.Right, TextAlign = ContentAlignment.MiddleRight, Font = creditFont, ForeColor = Theme.Faint };
            by.Width = TextRenderer.MeasureText(by.Text, creditFont).Width + S(16);
            var linkFont = Theme.Ui(8.5f, FontStyle.Underline);
            var credit = new Label
            {
                Text = author, AutoSize = false, Dock = DockStyle.Right, TextAlign = ContentAlignment.MiddleLeft,
                Font = creditFont, ForeColor = Theme.Accent, Cursor = Cursors.Hand,
            };
            credit.Padding = new Padding(S(3), 0, 0, 0);
            credit.Width = TextRenderer.MeasureText(author, linkFont).Width + S(8);
            new ToolTip().SetToolTip(credit, "github.com/dkdknight/MPFever");
            credit.MouseEnter += (s, e) => { credit.Font = linkFont; credit.ForeColor = Theme.AccentHover; };
            credit.MouseLeave += (s, e) => { credit.Font = creditFont; credit.ForeColor = Theme.Accent; };
            credit.Click += (s, e) =>
            {
                try { Process.Start("https://github.com/dkdknight/MPFever"); }
                catch (Exception ex) { Log.W(ex.Message); }
            };
            // the settings window (session settings read only for a guest once joined)
            var settingsText = T("⚙ Réglages", "⚙ Settings");
            var settingsLink = new Label
            {
                Text = settingsText, AutoSize = false, Dock = DockStyle.Right, TextAlign = ContentAlignment.MiddleRight,
                Font = creditFont, ForeColor = Theme.Accent, Cursor = Cursors.Hand,
            };
            settingsLink.Width = TextRenderer.MeasureText(settingsText, linkFont).Width + S(16);
            settingsLink.MouseEnter += (s, e) => { settingsLink.Font = linkFont; settingsLink.ForeColor = Theme.AccentHover; };
            settingsLink.MouseLeave += (s, e) => { settingsLink.Font = creditFont; settingsLink.ForeColor = Theme.Accent; };
            settingsLink.Click += (s, e) => OpenSettings();
            var kofiText = T("♥ Soutenir MPFever", "♥ Support MPFever");
            var kofi = new Label
            {
                Text = kofiText, AutoSize = false, Dock = DockStyle.Right, TextAlign = ContentAlignment.MiddleRight,
                Font = creditFont, ForeColor = Theme.Accent, Cursor = Cursors.Hand,
            };
            kofi.Width = TextRenderer.MeasureText(kofiText, linkFont).Width + S(16);
            new ToolTip().SetToolTip(kofi, "ko-fi.com/knighthd");
            kofi.MouseEnter += (s, e) => { kofi.Font = linkFont; kofi.ForeColor = Theme.AccentHover; };
            kofi.MouseLeave += (s, e) => { kofi.Font = creditFont; kofi.ForeColor = Theme.Accent; };
            kofi.Click += (s, e) =>
            {
                try { Process.Start("https://ko-fi.com/knighthd"); }
                catch (Exception ex) { Log.W(ex.Message); }
            };
            // the community: players, help and news
            const string discordText = "Discord";
            var discord = new Label
            {
                Text = discordText, AutoSize = false, Dock = DockStyle.Right, TextAlign = ContentAlignment.MiddleRight,
                Font = creditFont, ForeColor = Theme.Accent, Cursor = Cursors.Hand,
            };
            discord.Width = TextRenderer.MeasureText(discordText, linkFont).Width + S(16);
            new ToolTip().SetToolTip(discord, ThanksDialog.DiscordUrl.Replace("https://", ""));
            discord.MouseEnter += (s, e) => { discord.Font = linkFont; discord.ForeColor = Theme.AccentHover; };
            discord.MouseLeave += (s, e) => { discord.Font = creditFont; discord.ForeColor = Theme.Accent; };
            discord.Click += (s, e) =>
            {
                try { Process.Start(ThanksDialog.DiscordUrl); }
                catch (Exception ex) { Log.W(ex.Message); }
            };
            footer.Controls.Add(status);
            footer.Controls.Add(gameLabel);
            footer.Controls.Add(settingsLink);
            footer.Controls.Add(discord);
            footer.Controls.Add(kofi);
            footer.Controls.Add(by);
            footer.Controls.Add(credit);   // docked first: rightmost

            Controls.Add(body);
            Controls.Add(footer);
            header.Dock = DockStyle.Top;
            Controls.Add(header);

            UpdateDashboard();
        }

        /// <summary>(0.7.13, asked by the user 2026-11-09) Whether the window shows the old « Connection » card (name, host address,
        /// port, « Host a game », « Join by IP », and « Local test » in developer mode): only in developer mode (--dev and the
        /// autotests, which have no game menu: those buttons start their sessions) or with MPFEVER_CONNCARD=1. A player hosts and
        /// joins on the game's Multiplayer page (its lobby, the server list, Steam invitations, +mpfever_connect) since 0.3.18; the
        /// card's buttons, still clickable until the game was started, opened a session without the menu's lobby (and a second
        /// game with « Start Transport Fever 3 »), and players took them for the way to play.</summary>
        internal static bool ConnCard(bool dev, string env) => dev || env == "1";
        static bool ConnCardOn => ConnCard(Dev, Environment.GetEnvironmentVariable("MPFEVER_CONNCARD"));

        /// <summary>(0.7.13) A player's left card in place of the « Connection » card: the settings window (as « ⚙ Settings » of the
        /// bottom bar), Ko-fi and Discord (as the bottom bar's links and the thanks window's buttons), and where to host or join.</summary>
        Card BuildLinksCard()
        {
            var card = new Card();
            var settingsBtn = new ModernButton(ButtonKind.Primary) { Text = T("⚙ Réglages", "⚙ Settings") };
            var supportBtn = new ModernButton(ButtonKind.Secondary) { Text = T("♥ Soutenir MPFever", "♥ Support MPFever") };
            var discordBtn = new ModernButton(ButtonKind.Secondary) { Text = "Discord" };
            settingsBtn.Click += (s, e) => OpenSettings();
            supportBtn.Click += (s, e) => ThanksDialog.Open(ThanksDialog.KofiUrl);
            discordBtn.Click += (s, e) => ThanksDialog.Open(ThanksDialog.DiscordUrl);
            var tips = new ToolTip();
            tips.SetToolTip(supportBtn, ThanksDialog.KofiUrl.Replace("https://", ""));
            tips.SetToolTip(discordBtn, ThanksDialog.DiscordUrl.Replace("https://", ""));
            var where = new Label { Text = PlayWhereText(), AutoSize = false, ForeColor = Theme.Muted, Font = Theme.Ui(9f) };
            // (as high as its lines need at the card's width: the left column's, less its margin and the card's padding)
            where.Height = TextRenderer.MeasureText(where.Text, where.Font, new Size(Theme.S(340 - 16 - 36), int.MaxValue), TextFormatFlags.WordBreak).Height + Theme.S(4);
            Ui.StackTop(card, Ui.Caption(T("Réglages et communauté", "Settings and community")), settingsBtn, Ui.Gap(8), supportBtn, Ui.Gap(8), discordBtn, Ui.Gap(12), where);
            Ui.FitHeight(card);
            return card;
        }

        /// <summary>(0.7.13) Where a player hosts and joins: a player's left card, and the help before the game starts.</summary>
        static string PlayWhereText() => T("Pour héberger ou rejoindre une partie : la page « Multijoueur (MPFever) » du menu principal du jeu, la liste des serveurs ou une invitation Steam.",
            "To host or join a game: the « Multiplayer (MPFever) » page of the game's main menu, the server list or a Steam invitation.");

        /// <summary>The settings window (the session settings read only for a guest once joined), then every game gets them: the
        /// bottom bar's « ⚙ Settings » and (0.7.13) a player's left card.</summary>
        void OpenSettings()
        {
            bool guest = relay == null && clients.Count > 0 && Options.HostSession != null;
            using (var d = new OptionsDialog(guest)) d.ShowDialog(this);
            foreach (var g in games.ToList()) g.WriteSettings();
        }

        // ---------------------------------------------------------------- language

        /// <summary>Before the window: the language saved in mpfever_settings.txt (lang=), else the game's, else Windows'.</summary>
        public static void InitLanguage()
        {
            LoadPersonalMods();
            LoadSettings().TryGetValue("lang", out var saved);
            var code = L.Detect(saved, out var source);
            L.Set(code);
            Log.W(T("Langue : ", "Language: ") + L.Name + " (" + SourceText(source) + ")");
        }

        /// <summary>This player's choices of personal mods (see Mods): taken for personal by hand, and found personal but off.</summary>
        static void LoadPersonalMods()
        {
            var st = LoadSettings();
            HashSet<string> Set(string k) => new HashSet<string>((st.TryGetValue(k, out var v) ? v : "").Split(',').Select(x => x.Trim()).Where(x => x != ""), StringComparer.OrdinalIgnoreCase);
            Mods.Forced = Set("personal.forced");
            Mods.Off = Set("personal.off");
        }

        static void SavePersonalMods()
        {
            SaveSetting("personal.forced", string.Join(",", Mods.Forced));
            SaveSetting("personal.off", string.Join(",", Mods.Off));
        }

        static string SourceText(string source)
        {
            switch (source)
            {
                case "setting": return T("choisie dans MPFever", "chosen in MPFever");
                case "game": return T("langue du jeu", "the game's language");
                case "steam": return T("langue du jeu dans Steam", "the game's language in Steam");
                case "windows": return T("langue de Windows", "the Windows language");
                default: return T("par défaut", "default");
            }
        }

        /// <summary>The language menu of the title bar: automatic (the game's language) or one of the game's languages.</summary>
        void ShowLanguageMenu()
        {
            var menu = new ContextMenuStrip { Renderer = new DarkMenuRenderer(), ShowImageMargin = false, ShowCheckMargin = true, Font = Theme.Ui(9.75f) };
            LoadSettings().TryGetValue("lang", out var saved);
            bool auto = L.Normalize(saved) == null;
            var autoCode = L.Detect("", out var autoSource);
            var autoItem = new ToolStripMenuItem(T("Automatique", "Automatic") + "  –  " + L.NameOf(autoCode) + " (" + SourceText(autoSource) + ")") { Checked = auto };
            autoItem.Click += (s, e) => ChooseLanguage("auto");
            menu.Items.Add(autoItem);
            menu.Items.Add(new ToolStripSeparator());
            foreach (var lang in L.All)
            {
                var code = lang.Code;
                var item = new ToolStripMenuItem(lang.Name) { Checked = !auto && code == L.Code };
                item.Click += (s, e) => ChooseLanguage(code);
                menu.Items.Add(item);
            }
            menu.Closed += (s, e) => BeginInvoke((Action)menu.Dispose);
            menu.Show(langBtn, new Point(langBtn.Width, langBtn.Height + Theme.S(4)), ToolStripDropDownDirection.BelowLeft);
        }

        void ChooseLanguage(string choice)
        {
            SaveSetting("lang", choice);
            var code = L.Detect(choice == "auto" ? "" : choice, out var source);
            if (code == L.Code) return;
            L.Set(code);
            Log.W(T("Langue : ", "Language: ") + L.Name + " (" + SourceText(source) + ")");
        }

        /// <summary>The window is rebuilt in the new language; the games get the new texts (the MPFever window of the main
        /// menu changes at once, the texts inside a running game with the next loaded game).</summary>
        void OnLanguageChanged()
        {
            SuspendLayout();
            var rtf = logBox.Rtf;   // moving the log to its new card may recreate it without its colours
            var old = Controls.Cast<Control>().ToList();
            Controls.Clear();
            BuildUi();
            ResumeLayout(true);
            try { if (logBox.Rtf != rtf) { logBox.ReadOnly = false; logBox.Rtf = rtf; logBox.ReadOnly = true; } } catch { }
            Theme.ScrollToEnd(logBox);
            foreach (var c in old) c.Dispose();
            if (relay == null && clients.Count == 0) status.Text = gameMissing ? T("Jeu introuvable", "Game not found") : T("Prêt.", "Ready.");
            foreach (var g in games.ToList()) g.WriteLang();
            if (menuMode) MenuStatus();
        }

        static Color LogColor(string s, LogLevel level)
        {
            switch (level)
            {
                case LogLevel.Muted: return Theme.Muted;
                case LogLevel.Success: return Theme.Success;
                case LogLevel.Warning: return Theme.Warning;
                case LogLevel.Error: return Theme.Danger;
                case LogLevel.Section: return Theme.Accent;
            }
            // the kind written in the text itself
            if (s.StartsWith("!!!")) return Theme.Danger;
            if (s.StartsWith("===")) return Theme.Accent;
            if (s.StartsWith("    ~")) return Theme.Warning;
            if (s.StartsWith("    ")) return Theme.Muted;
            return Theme.Text;
        }

        void AppendLog(string l, LogLevel level)
        {
            // "HH:mm:ss.fff text": the time in a quieter colour
            bool timed = l.Length > 13 && l[2] == ':' && l[12] == ' ';
            string text = timed ? l.Substring(13) : l;
            logBox.SelectionStart = logBox.TextLength;
            logBox.SelectionLength = 0;
            if (timed)
            {
                logBox.SelectionColor = Theme.Faint;
                logBox.AppendText(l.Substring(0, 8) + "  ");
            }
            logBox.SelectionColor = LogColor(text, level);
            logBox.AppendText(text + "\n");
            if (++logLines > 6000)
            {
                // keep the window light; the full log stays in logs\
                logBox.ReadOnly = false;
                logBox.Select(0, logBox.GetFirstCharIndexFromLine(1000));
                logBox.SelectedText = "";
                logBox.ReadOnly = true;
                logLines -= 1000;
            }
            Theme.ScrollToEnd(logBox);
        }

        /// <summary>The tiles, header badge and help text, from the session state (every 500 ms).</summary>
        void UpdateDashboard()
        {
            if (header == null) return;
            bool host = relay != null, client = !host && clients.Count > 0;
            bool st, paused; int sp;
            lock (sessionGate) { st = started; paused = pauseAt.HasValue; sp = speed; }

            if (ServerMode) header.SetRole(T("SERVEUR", "SERVER"), host ? Theme.Accent : Theme.Muted);
            else if (host) header.SetRole(T("HÔTE", "HOST"), Theme.Accent);
            else if (client) header.SetRole(T("CLIENT", "CLIENT"), Theme.Info);
            else if (menuMode) header.SetRole(T("MENU DU JEU", "GAME MENU"), Theme.Success);
            else header.SetRole(T("PRÊT", "READY"), Theme.Muted);

            // players
            if (host && server != null)
            {
                // a dedicated server: the players only, not its own game
                string[] names; lock (players) names = players.Where(x => x != hostName).Select(BaseName).OrderBy(x => x).ToArray();
                playersTile.Set(names.Length + " / " + server.MaxPlayers, names.Length == 0 ? T("personne n'est connecté", "nobody is connected") : string.Join(", ", names),
                    names.Length > 0 ? Theme.Success : Theme.Faint);
            }
            else if (host)
            {
                string[] names; lock (players) names = players.OrderBy(x => x).ToArray();
                playersTile.Set(names.Length.ToString(), names.Length == 0 ? T("en attente des jeux", "waiting for games") : string.Join(", ", names),
                    names.Length > 1 ? Theme.Success : names.Length == 1 ? Theme.Info : Theme.Faint);
            }
            else if (client) playersTile.Set("✔", T("connecté à l'hôte", "connected to the host"), Theme.Info);
            else playersTile.Set("—", T("pas de session", "no session"), Theme.Faint);

            // speed
            string spread = "";
            lock (clocks) if (clocks.Count > 1) { var est = clocks.Values.Select(Estimate).ToList(); spread = F("écart {0:0} pas", "gap {0:0} steps", (est.Max() - est.Min()) / Step); }
            if (!host) speedTile.Set("—", client ? T("réglée par l'hôte", "set by the host") : T("non démarrée", "not started"), Theme.Faint);
            else if (!st) speedTile.Set("—", T("non démarrée", "not started"), Theme.Faint);
            else if (paused) speedTile.Set(T("Pause", "Pause"), spread, Theme.Warning);
            else speedTile.Set("x" + sp, spread, Theme.Success);

            // actions
            if (host) actionsTile.Set(actsRelayed.ToString("N0"), F("refusées {0} · échecs {1}", "refused {0} · failed {1}", actRefused, actFails),
                actFails > 0 ? Theme.Warning : actsRelayed > 0 ? Theme.Info : Theme.Faint);
            else actionsTile.Set("—", "", Theme.Faint);

            // sync
            var s = syncText ?? "—";
            int open = s.IndexOf('(');
            string why = open >= 0 ? s.Substring(open + 1).TrimEnd(')') : "";
            string total = desyncs > 0 ? F("{0} désynchronisation(s) au total", "{0} desync(s) in total", desyncs) : T("aucune désynchronisation", "no desync so far");
            if (resyncing) syncTile.Set(T("Resynchro…", "Resyncing…"), T("rechargement de la partie de l'hôte", "reloading the host's game"), Theme.Info, true);
            else if (!host) syncTile.Set("—", client ? T("vérifiée par l'hôte", "checked by the host") : "", Theme.Faint);
            else if (syncState == 1) syncTile.Set(T("Synchrone", "In sync"), total, Theme.Success, true);
            else if (syncState == 2) syncTile.Set(T("Légère dérive", "Slight drift"), why, Theme.Warning, true);
            else if (syncState == 0) syncTile.Set("—", T("pas encore vérifiée", "not checked yet"), Theme.Faint);
            else syncTile.Set(T("Désynchronisé", "Out of sync"), why, Theme.Danger, true);

            // speed buttons show what is in effect
            pauseBtn.Active = host && st && paused;
            x1Btn.Active = host && st && !paused && sp == 1;
            x2Btn.Active = host && st && !paused && sp == 2;
            x4Btn.Active = host && st && !paused && sp == 4;

            // what to do now
            string h;
            if (ServerMode) UpdateServerCard();
            if (gameMissing)
                h = T("Transport Fever 3 est introuvable. Relancez MPFever pour choisir le fichier TransportFever3.exe du jeu.", "Transport Fever 3 was not found. Start MPFever again to choose the game's TransportFever3.exe file.");
            else if (ServerMode && st) h = F("Le serveur héberge son monde. Les joueurs le rejoignent depuis la fenêtre MPFever de leur jeu avec l'adresse de ce PC, port {0}.\n\nTapez help sous le journal pour les commandes du serveur.",
                                             "The server hosts its world. Players join it from the MPFever window of their game with this PC's address, port {0}.\n\nType help under the log for the server commands.", server?.Port ?? 28090);
            else if (ServerMode) h = (menuText ?? "") + T("\n\nTapez help sous le journal pour les commandes du serveur.", "\n\nType help under the log for the server commands.");
            else if (gameClosed) h = T("Transport Fever 3 est fermé. Cliquez sur « Relancer Transport Fever 3 » pour jouer à nouveau.",
                                       "Transport Fever 3 is closed. Click « Start Transport Fever 3 again » to play again.");
            else if (installing) h = T("MPFever met son mod en place dans le jeu. Patientez quelques secondes : la barre bouge tant que ce n'est pas fini.",
                                       "MPFever is putting its mod into the game. Wait a few seconds: the bar moves until it is done.");
            else if (waitingLaunch) h = T("Le jeu ne se lance plus tout seul : réglez d'abord MPFever si vous le souhaitez (⚙ Réglages, en bas à droite), puis cliquez sur « Lancer Transport Fever 3 ».\n\nCochez « Lancer le jeu automatiquement » pour que le jeu démarre tout seul à l'ouverture de MPFever les prochaines fois.",
                                          "The game no longer starts by itself: set MPFever up first if you wish (⚙ Settings, bottom right), then click « Start Transport Fever 3 ».\n\nTick « Start the game by itself » to have the game start as soon as MPFever opens next time.");
            else if (menuMode && !string.IsNullOrEmpty(menuText)) h = menuText;
            else if (menuMode) h = T("Le jeu démarre. Choisissez « Multijoueur (MPFever) » dans son menu principal pour héberger ou rejoindre une partie.",
                                     "The game is starting. Choose « Multiplayer (MPFever) » in its main menu to host or join a game.");
            else if (host && !st) h = T("Chargez exactement la même sauvegarde dans chaque jeu, puis cliquez sur « Démarrer la partie ».",
                                        "Load exactly the same savegame in every game, then click « Start the game ».");
            else if (host) h = T("Partie en cours. La vitesse choisie s'applique à tous les joueurs ; la synchronisation est vérifiée toutes les 10 s.",
                                 "Game running. The speed you choose applies to every player; sync is checked every 10 s.");
            else if (client) h = T("Connecté. L'hôte démarre la partie et règle la vitesse.", "Connected. The host starts the game and sets the speed.");
            // ((0.7.13) a player's window has no host / join buttons any more: where to play; the old text with the old card)
            else h = !ConnCardOn ? PlayWhereText() : T("Hébergez une partie ou rejoignez un ami avec son adresse IP.\n\nPort par défaut : 28090 (TCP). Pour jouer par Internet, l'hôte doit rediriger ce port sur sa box.", "Host a game, or join a friend with their IP address.\n\nDefault port: 28090 (TCP). To play over the Internet, the host must forward this port on their router.");
            if (hint.Text != h) hint.Text = h;

            string g = gameDir != null ? "Transport Fever 3 · " + gameDir : "";
            if (gameLabel.Text != g) { gameLabel.Text = g; gameLabel.Width = g == "" ? 0 : TextRenderer.MeasureText(g, gameLabel.Font).Width + Theme.S(8); }
        }

        string PlayerName() => string.IsNullOrWhiteSpace(nameBox.Text) ? "Player" : nameBox.Text.Trim();
        double Now => clockWatch.Elapsed.TotalSeconds;

        void Guard(Action a)
        {
            if (running) { Log.Warn(T("Une session est déjà en cours : relancer MPFever pour en ouvrir une autre.", "A session is already running: restart MPFever to open another one.")); return; }
            try { a(); running = true; hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false; }
            catch (Exception e) { Log.Err(T("Erreur : ", "Error: ") + e.Message); MessageBox.Show(this, e.Message, "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }

        /// <summary>Before the game starts: a newer MPFever on GitHub (github.com/dkdknight/MPFever/releases) is offered
        /// in a window, to update now or to go on without updating. The game starts after the answer, or at once when
        /// GitHub does not answer within a few seconds. No check in developer mode, nor when the game started MPFever for a
        /// Steam invitation (the game is already running), nor with autoupdate=0 in mpfever_settings.txt.</summary>
        void CheckUpdateThenInit()
        {
            Updater.CleanUp(JustUpdated);
            ShowPrivacyOnce();
            if (autotest || Dev || JoinAtStart != null || !Updater.Enabled) { Init(); StartUpdateWatch(); return; }
            if (!Updater.InReleaseFolder)
            {
                Log.Dim(T("Mises à jour non vérifiées : MPFever.exe n'est pas dans un dossier de version (mod\\mpfever_1 absent)", "Updates not checked: MPFever.exe is not in a release folder (no mod\\mpfever_1)"));
                Init();
                return;
            }
            status.Text = T("Recherche de mises à jour…", "Checking for updates…");
            bool answered = false;
            var timeout = new System.Windows.Forms.Timer { Interval = Updater.CheckTimeoutMs + 1000 };
            Action<UpdateInfo, string> answer = (u, error) =>
            {
                if (answered) return;
                answered = true;
                timeout.Dispose();
                status.Text = T("Prêt.", "Ready.");
                if (error != null) Log.Dim(F("Recherche de mises à jour impossible : {0}", "Could not check for updates: {0}", error));
                else if (u == null) Log.Dim(T("MPFever est à jour.", "MPFever is up to date."));
                else
                {
                    Log.Ok(F("Nouvelle version disponible : MPFever {0}", "New version available: MPFever {0}", u.Version));
                    DialogResult choice;
                    // (autoupdate=1, the default: installed at once; autoupdate=ask: offered first)
                    using (var dlg = new UpdateDialog(u, !Updater.Ask)) choice = dlg.ShowDialog(this);
                    if (choice == DialogResult.OK)
                    {
                        try { Updater.Restart(Program.Args); }
                        catch (Exception e)
                        {
                            Log.Err(e.Message);
                            MessageBox.Show(this, F("MPFever {0} est installé mais n'a pas pu être relancé : {1}\nRelancez MPFever.", "MPFever {0} is installed but could not be restarted: {1}\nPlease start MPFever again.", u.Version, e.Message),
                                "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        }
                        Close();
                        return;
                    }
                    Log.W(F("Mise à jour ignorée : MPFever {0} reste installé", "Update skipped: MPFever {0} stays installed", Version));
                }
                Init();
                StartUpdateWatch();
            };
            timeout.Tick += (s, e) => answer(null, T("pas de réponse de GitHub", "no answer from GitHub"));
            timeout.Start();
            new Thread(() =>
            {
                UpdateInfo u = null;
                string error = null;
                try { u = Updater.Check(); }
                catch (Exception e) { error = Updater.Describe(e); }
                try { BeginInvoke((Action)(() => answer(u, error))); } catch { }
            }) { IsBackground = true, Name = "Update check" }.Start();
        }

        /// <summary>A release published on GitHub while this launcher is open (checked every 30 minutes): installed when the
        /// game closes (a player's launcher), or by a dedicated server once nobody is connected (see ServerTick).</summary>
        volatile UpdateInfo pendingUpdate;
        DateTime gameStartedAt = DateTime.Now;
        System.Threading.Timer updateWatch;

        void StartUpdateWatch()
        {
            if (updateWatch != null || autotest || Dev || !Updater.Enabled || !Updater.InReleaseFolder) return;
            var period = TimeSpan.FromMinutes(Updater.RecheckMinutes);
            updateWatch = new System.Threading.Timer(_ =>
            {
                try
                {
                    var u = Updater.Check();
                    if (u == null) return;
                    var known = pendingUpdate;
                    if (known != null && Updater.CompareVersions(Updater.ParseVersion(u.Version), Updater.ParseVersion(known.Version)) <= 0) return;
                    pendingUpdate = u;
                    if (ServerMode && !serverStarted)
                    {
                        // (a stopped server: nobody to wait for)
                        Log.Ok(F("MPFever {0} est publié : le serveur arrêté l'installe maintenant.", "MPFever {0} is published: the stopped server installs it now.", u.Version));
                        try { BeginInvoke((Action)(() => ServerSelfUpdate(u))); } catch { }
                    }
                    else if (ServerMode)
                        Log.Ok(F("MPFever {0} est publié : le serveur l'installera et redémarrera dès que personne n'est connecté.", "MPFever {0} is published: the server installs it and restarts as soon as nobody is connected.", u.Version));
                    else
                    {
                        Log.Ok(F("MPFever {0} est publié : il sera installé à la fermeture du jeu.", "MPFever {0} is published: it is installed when the game closes.", u.Version));
                        // (the host tells every player of its session, in the chat)
                        if (hostGame != null)
                            HostChat("msg", "MPFever", F("MPFever {0} est disponible : il s'installera à la fermeture du jeu (tous les joueurs doivent avoir la même version).", "MPFever {0} is available: it installs when you close the game (every player needs the same version).", u.Version));
                    }
                }
                catch (Exception e) { Log.Dim(F("Recherche de mises à jour impossible : {0}", "Could not check for updates: {0}", Updater.Describe(e))); }
            }, null, period, period);
        }

        /// <summary>The game closed: its log is kept in the session folder; after a crash a problem report is offered; a
        /// release found meanwhile is installed now (no restart: it starts with the next launch).</summary>
        void InstallPendingUpdateThenClose()
        {
            if (menuGame != null) Reporter.KeepGameLog(menuGame.Dir);
            if (!ServerMode && !autotest && Reporter.CrashedSince(gameStartedAt, menuGame?.Dir, menuGame?.ExitCode, menuGame != null && menuGame.OtherGameSeen))
            {
                Log.Err(T("Transport Fever 3 s'est arrêté brutalement (fichier de crash écrit).", "Transport Fever 3 crashed (a crash dump was written)."));
                // (the window was minimised while the game ran: the question must be seen)
                try { WindowState = FormWindowState.Normal; Activate(); } catch { }
                var answer = MessageBox.Show(this, T("Transport Fever 3 s'est arrêté brutalement.\n\nPréparer un rapport de problème ? MPFever rassemble les journaux dans un fichier zip et ouvre la page d'une nouvelle issue GitHub, où il suffit de glisser ce fichier.",
                    "Transport Fever 3 crashed.\n\nPrepare a problem report? MPFever puts the logs into a zip file and opens a new GitHub issue, where you just drag that file."),
                    "MPFever", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (answer == DialogResult.Yes) Report(true);
            }
            var u = pendingUpdate;
            bool installed = false;
            if (u != null && !ServerMode && Updater.Enabled)
            {
                pendingUpdate = null;
                try
                {
                    using (var dlg = new UpdateDialog(u, true))
                        if (dlg.ShowDialog(this) == DialogResult.OK)
                        {
                            installed = true;
                            Log.Ok(F("MPFever {0} installé : il démarrera la prochaine fois.", "MPFever {0} installed: it starts next time.", u.Version));
                        }
                }
                catch (Exception e) { Log.Err(e.Message); }
            }
            if (ServerMode || autotest) { Close(); return; }
            // (the launcher stays open behind a small thanks window: Close keeps it, Quit closes everything; the launcher's own
            // window then offers to start the game again in place of "Start the game", issue #94)
            gameClosed = true;
            updateInstalled = installed;
            startBtn.Visible = false;
            againBtn.Visible = true;
            try { WindowState = FormWindowState.Normal; Activate(); } catch { }
            DialogResult r;
            using (var dlg = new ThanksDialog()) r = dlg.ShowDialog(this);
            if (r == DialogResult.Abort) Close();
            else if (r == DialogResult.Retry) Report(false);
        }

        /// <summary>Issue #94: the game closed, the player wants to play again. A new MPFever.exe starts it (this one's session,
        /// connections and native settings are those of the game that closed: a fresh launcher starts from nothing, as when the
        /// player starts MPFever.exe by hand), then this one closes. With the update just installed, the new one is that version.</summary>
        void StartAgain(bool updated)
        {
            try
            {
                var exe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "MPFever.exe");
                Log.W(T("Relance de MPFever et de Transport Fever 3...", "Starting MPFever and Transport Fever 3 again..."));
                // (0.7.4: --launch, the game starts at once, whatever the box « start the game by itself » says)
                Process.Start(new ProcessStartInfo(exe, updated ? "--updated --launch" : "--launch") { UseShellExecute = false, WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory });
                Close();
            }
            catch (Exception e)
            {
                Log.Err(F("Relance impossible : {0}. Relancez MPFever.exe vous-même.", "Could not start again: {0}. Start MPFever.exe yourself.", e.Message));
            }
        }

        /// <summary>A problem report: the logs in a zip (reports\), shown in the Explorer, and a new GitHub issue opened in
        /// the browser with what the session was (see Reporter). The in-game window is told where the zip is.</summary>
        int reportBusy;

        /// <summary>The answer to "Report a problem" in report.txt of every game of this MPFever (the window of the game
        /// whose button was clicked, which may not be the menu's game, shows it under the button).</summary>
        void ReportAnswer(string text)
        {
            var dirs = games.Select(g => g.Dir).ToList();
            if (menuGame != null) dirs.Add(menuGame.Dir);
            foreach (var d in dirs.Where(x => x != null).Distinct())
                try { File.WriteAllText(Path.Combine(d, "report.txt"), DateTime.Now.Ticks + "\t" + text + "\n"); } catch { }
        }

        // (0.7.9) Report(bool crashed): see ReportShare.cs

        /// <summary>The session as a problem report describes it, two lines: the company mode and this MPFever's role (with the
        /// host), then the players and whether the game runs. joining: a player whose join or reconnection is under way, with no
        /// connection to the host right now (a "client", not "no session").</summary>
        /// <summary>(0.6.12, #125) The company mode a problem report names. companyMode is the host's own choice (its lobby, the
        /// dedicated server's settings): a player's launcher never sets it, and every player's report said "shared company"
        /// (#110, #113, #115, #125, all separate). A player names the host's mode, from its "session" messages, else from its
        /// lobby. MPFEVER_REPORTMODE=0: companyMode, as before.</summary>
        string ReportCompanyMode() => ModeForReport(hostGame != null || server != null, companyMode, hostCompanyMode, lobbyMode);

        internal static string ModeForReport(bool ownsSession, string own, string fromHost, string fromLobby)
        {
            if (ownsSession || Environment.GetEnvironmentVariable("MPFEVER_REPORTMODE") == "0") return own;
            if (fromHost == "separate" || fromHost == "shared") return fromHost;
            if (fromLobby == "separate" || fromLobby == "shared") return fromLobby;
            return own;
        }

        /// <summary>The company mode of a host's "session" message (its "cmode"), or "".</summary>
        internal static string SessionMode(string payload)
        {
            try
            {
                var d = LuaLit.Parse(payload) as Dictionary<object, object>;
                return d != null && d.TryGetValue("cmode", out var v) && v is string s ? s : "";
            }
            catch { return ""; }
        }

        string SessionLines(bool joining)
        {
            bool st; lock (sessionGate) st = started;
            string role = server != null ? "dedicated server" : hostGame != null ? "host" : clients.Count > 0 ? "client" : joining ? "client (not connected)" : "no session";
            string[] ready; lock (players) ready = players.ToArray();
            string running = st ? "yes" : "no";
            // (0.7.7) a player's launcher keeps no lobby of its own: its report said "Players: -; game running: no" in a game that ran
            // (the user's and #135's reports, 2026-11-08). The players and the game's state as the host's messages say them.
            // MPFEVER_REPORTCLIENT=0: as before
            if (server == null && hostGame == null && (clients.Count > 0 || joining) && Environment.GetEnvironmentVariable("MPFEVER_REPORTCLIENT") != "0")
            {
                lock (clientPeers) ready = clientPeers.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToArray();
                running = HostRunningText(hostStartedSeen);
            }
            return "Company mode: " + (ReportCompanyMode() == "separate" ? "one company per player" : "one company for everybody") + "; role: " + role
                + (hostName != null ? " (host " + BaseName(hostName) + ")" : "") + Environment.NewLine
                + "Players: " + (ready.Length > 0 ? string.Join(", ", ready.Select(BaseName)) : "-") + "; game running: " + running;
        }

        // (0.7.7) the games that reported a build they could not reproduce, by the build's uid (see "replay_failed")
        readonly Dictionary<string, HashSet<string>> failedBy = new Dictionary<string, HashSet<string>>();

        /// <summary>(0.7.7) The uid of a "replay_failed" report, or null.</summary>
        internal static string FailedUid(string payload)
        {
            try
            {
                var d = LuaLit.Parse(payload) as Dictionary<object, object>;
                return d != null && d.TryGetValue("uid", out var v) && v is string s && s.Length > 0 ? s : null;
            }
            catch { return null; }
        }

        /// <summary>(0.7.7) Whether a build was refused on every game, its builder's own too (its uid: "builder:n"): then no
        /// game built it and the games did not part.</summary>
        internal static bool RefusedEverywhere(string uid, ICollection<string> refusedBy, IEnumerable<string> players)
        {
            if (string.IsNullOrEmpty(uid) || refusedBy == null || players == null) return false;
            int c = uid.LastIndexOf(':');
            if (c <= 0) return false;
            var builder = BaseName(uid.Substring(0, c));
            var set = new HashSet<string>(refusedBy.Select(BaseName), StringComparer.OrdinalIgnoreCase);
            if (!set.Contains(builder)) return false;
            int n = 0;
            foreach (var p in players) { n++; if (!set.Contains(BaseName(p))) return false; }
            return n > 0;
        }

        // (0.7.7) a player's view of the session, for its reports: the names the host's messages came with (the host and the
        // players it relays) and whether the host's game runs (its "session" messages: -1 none yet, 0 no, 1 yes)
        readonly HashSet<string> clientPeers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        volatile int hostStartedSeen = -1;
        internal static string HostRunningText(int seen) => seen == 1 ? "yes" : seen == 0 ? "no" : "? (no word from the host yet)";

        /// <summary>(0.7.7) The host's "started" in a "session" message, or null.</summary>
        internal static bool? SessionStarted(string payload)
        {
            try
            {
                var d = LuaLit.Parse(payload) as Dictionary<object, object>;
                return d != null && d.TryGetValue("started", out var v) && v is bool b ? b : (bool?)null;
            }
            catch { return null; }
        }

        /// <summary>(0.7.7) What a message from the host tells a player's report: who plays, whether the game runs.</summary>
        internal static bool NotesPeer(string kind, string from) =>
            !string.IsNullOrEmpty(from) && from != "MPFever"
            && (kind == "peerclock" || kind == "act" || kind == "session" || kind == "hash" || kind == "welcome" || kind == "hello");

        void NoteFromHost(Msg m, string me)
        {
            if (m.Kind == "session") { var s = SessionStarted(m.Payload); if (s.HasValue) hostStartedSeen = s.Value ? 1 : 0; }
            if (NotesPeer(m.Kind, m.From))
                lock (clientPeers)
                {
                    clientPeers.Add(BaseName(m.From));
                    if (!string.IsNullOrEmpty(me)) clientPeers.Add(BaseName(me));
                }
        }

        /// <summary>What MPFever contacts by itself and how to turn each off (docs/PRIVACY.txt, in the archive): told once, in a
        /// window, before the first update check. Not for a dedicated server (a window would hold a server that starts with
        /// Windows: its console tells its part at each start, see ServerListAnnounceLoop), nor when the game started MPFever for
        /// a Steam invitation (the window would open behind the game: it waits for the next start), nor in tests.</summary>
        void ShowPrivacyOnce()
        {
            if (autotest || Dev || ServerMode || JoinAtStart != null) return;
            if (LoadSettings().TryGetValue("privacyShown", out var v) && v == "1") return;
            SaveSetting("privacyShown", "1");
            MessageBox.Show(this, T("MPFever contacte de lui-même :\n- GitHub, pour chercher les mises à jour (autoupdate=0 pour l'arrêter) ;\n- api.ipify.org, pour connaître l'adresse publique d'un hôte (lookupip=0) ;\n- votre box, pour y ouvrir le port de la partie quand vous hébergez (upnp=0) ;\n- mpfever.knight-hd.fr, la liste des serveurs publics (serverlist=0), où un serveur dédié s'annonce avec son nom, son monde, ses joueurs, son adresse et son identifiant Steam (public=false dans mpfever_server.properties).\n\nCes réglages sont dans la fenêtre ⚙ Réglages ou dans mpfever_settings.txt, à côté de MPFever.exe. MPFever n'envoie rien d'autre sans que vous le demandiez (jouer ensemble, installer les mods manquants, signaler un problème). Détails : PRIVACY.txt.",
                "MPFever contacts by itself:\n- GitHub, to look for updates (autoupdate=0 turns it off);\n- api.ipify.org, to find a host's public address (lookupip=0);\n- your router, to open the game's port when you host (upnp=0);\n- mpfever.knight-hd.fr, the list of public servers (serverlist=0), where a dedicated server announces itself with its name, world, players, address and Steam ID (public=false in mpfever_server.properties).\n\nThese settings are in the ⚙ Settings window or in mpfever_settings.txt, next to MPFever.exe. MPFever sends nothing else unless you ask for it (playing together, installing missing mods, reporting a problem). Details: PRIVACY.txt."),
                T("MPFever : confidentialité", "MPFever: privacy"), MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        /// <summary>(0.7.4) The box « start the game by itself » is set (autolaunch=1): off until the player ticks it.</summary>
        internal static bool AutoLaunchSetting() => LoadSettings().TryGetValue("autolaunch", out var v) && v == "1";
        bool autoLaunchShown;
        // (0.7.4) the speed controls' title: hidden with them while the game waits for its launch (see ShowLaunchControls)
        Label speedLabel;

        /// <summary>(0.7.4) Whether the game starts by itself now: the box ticked, a Steam invitation (the game started MPFever
        /// for it), « Start Transport Fever 3 again » (--launch). MPFEVER_AUTOLAUNCH=1: always, as before 0.7.4.</summary>
        internal static bool LaunchAtStart(bool boxTicked, bool steamJoin, string[] args) =>
            boxTicked || steamJoin || args.Contains("--launch") || Environment.GetEnvironmentVariable("MPFEVER_AUTOLAUNCH") == "1";

        /// <summary>(0.7.4) The launch controls as the state says: the moving bar while the mod is put in the game, the button and
        /// its box while the game waits for the player.</summary>
        void ShowLaunchControls()
        {
            bool player = !ServerMode && !autotest;
            busyBar.Visible = player && installing;
            launchBtn.Visible = player && waitingLaunch && !gameClosed;
            launchBtn.Enabled = !installing;
            autoLaunchBox.Visible = player && MenuModeDefault && (waitingLaunch || installing) && !gameClosed;
            startBtn.Visible = !ServerMode && !gameClosed && !waitingLaunch && !installing;   // (a server starts its world by itself)
            againBtn.Visible = !ServerMode && gameClosed;
            // (0.7.4: no game yet, the speed controls (off until a session starts) leave the room to the launch button and its box;
            // with them the bar was too long and x2 and x4 went out of it)
            bool speed = !(player && (waitingLaunch || installing) && !gameClosed);
            if (speedLabel != null) speedLabel.Visible = speed;
            pauseBtn.Visible = x1Btn.Visible = x2Btn.Visible = x4Btn.Visible = speed;
        }

        void LaunchFromButton()
        {
            if (!waitingLaunch || installing) return;
            waitingLaunch = false;
            ShowLaunchControls();
            StartMenuMode();
        }

        void Init()
        {
            // (0.7.4) the slow part (the mod put into the game, the native module, the mods' check) beside the window, the bar
            // moving; the rest back on the window's thread. MPFEVER_INITSYNC=1 (and the autotests): all at once, as before
            if (!autotest && !ServerMode && Environment.GetEnvironmentVariable("MPFEVER_INITSYNC") != "1")
            {
                if (!InitFindGame()) return;
                installing = true;
                ShowLaunchControls();
                status.Text = T("Mise en place du mod dans le jeu, patientez…", "Putting the mod into the game, please wait…");
                Log.W(T("Mise en place du mod dans le jeu : patientez quelques secondes.", "Putting the mod into the game: wait a few seconds."));
                new Thread(() =>
                {
                    try { InitInstall(); }
                    catch (Exception e) { Log.Warn(T("Installation du mod : ", "Mod installation: ") + e.Message); }
                    try { BeginInvoke((Action)(() => { installing = false; status.Text = T("Prêt.", "Ready."); InitFinish(); })); } catch { }
                }) { IsBackground = true, Name = "Mod install" }.Start();
                return;
            }
            if (!InitFindGame()) return;
            InitInstall();
            InitFinish();
        }

        /// <summary>The game's folder (asked when not found): false when there is none.</summary>
        bool InitFindGame()
        {
            // (0.6.3) the folder the player chose for a game MPFever does not find itself (GOG, a folder of its own)
            try { if (LoadSettings().TryGetValue("gamedir", out var gd)) GameInstall.ChosenDir = gd; } catch { }
            // (0.8.0) several copies of the game on this PC (Steam, GOG, Epic) and none chosen yet: the player chooses once (kept in
            // the settings, changed in ⚙ Settings). MPFEVER_ASKCOPY=0: not asked, the first found as before
            if (!autotest && !ServerMode && !GameInstall.IsGameDir(GameInstall.ChosenDir) && Environment.GetEnvironmentVariable("MPFEVER_ASKCOPY") != "0"
                && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MPFEVER_GAMEDIR")))
                try
                {
                    var copies = GameInstall.AllCopies();
                    if (copies.Count > 1) ChooseCopy(copies, this);
                }
                catch (Exception e) { Log.W("copies: " + e.Message); }
            gameDir = GameInstall.FindGameDir();
            if (gameDir == null && !autotest && !ServerMode) gameDir = AskGameDir();
            if (gameDir == null) { gameMissing = true; Log.Err(T("Transport Fever 3 introuvable.", "Transport Fever 3 not found.")); status.Text = T("Jeu introuvable", "Game not found"); return false; }
            var platform = GameInstall.PlatformOf(gameDir);
            Log.W(T("Jeu : ", "Game: ") + gameDir + (platform != "" ? " (" + platform + ")" : ""));
            return true;
        }

        /// <summary>The files put into the game: the Steam id, the native module, the mod (beside the window since 0.7.4).</summary>
        // (0.7.11, #153) one install at a time on this PC: MPFever started twice at the same moment (a double click, janik
        // 2026-11-08 17:52:24) copied the mod into the same folder twice at once, two files were refused ("access denied"), and
        // the game found the mod half copied ("Mod was not cached in filesystem: mpfever_1::/mpfever_auto.lua") and stopped.
        // The second one now waits for the first one's install (60 s at most), then installs as usual. MPFEVER_INSTALLLOCK=0:
        // as before
        void InitInstall()
        {
            System.Threading.Mutex gate = null;
            bool held = false;
            if (Environment.GetEnvironmentVariable("MPFEVER_INSTALLLOCK") != "0")
                try
                {
                    gate = new System.Threading.Mutex(false, @"Local\MPFever.Install");
                    try { held = gate.WaitOne(TimeSpan.FromSeconds(60)); }
                    catch (System.Threading.AbandonedMutexException) { held = true; }
                    if (!held) Log.W(T("Une autre installation de MPFever ne finit pas : la mise en place continue sans l'attendre.", "Another MPFever install does not end: going on without waiting for it."));
                }
                catch (Exception e) { Log.W("install lock: " + e.Message); }
            try { InitInstallLocked(); }
            finally { if (held) try { gate.ReleaseMutex(); } catch { } gate?.Dispose(); }
        }

        void InitInstallLocked()
        {
            if (GameInstall.NotSteamCopy(gameDir))
                Log.Warn(T("Copie du jeu hors Steam (GOG ?) : prise en charge expérimentale. Rejoindre par Steam n'y est pas possible, utilisez l'adresse de l'hôte.",
                           "A copy of the game not installed by Steam (GOG?): experimental support. Joining through Steam is not possible there, use the host's address."));
            else try { GameInstall.EnsureSteamAppId(gameDir); } catch (Exception e) { Log.W("steam_appid.txt : " + e.Message); }
            try { GameInstall.InstallNative(gameDir); } catch (Exception e) { Log.W("winhttp.dll: " + e.Message); }
            if (GameInstall.DiagOn())
                Log.Warn(T("Version de diagnostic : journaux détaillés (file des identifiants, état à chaque contrôle). Après une resynchronisation, envoyez le rapport de chaque joueur.",
                           "Diagnostic build: detailed logs (the free-id queue, the state at every check). After a resynchronisation, send every player's report."));
            try { GameInstall.EnsureModActive(); } catch (Exception e) { Log.W("settings.lua: " + e.Message); }
            try { GameInstall.InstallMod(); } catch (Exception e) { Log.Warn(T("Installation du mod : ", "Mod installation: ") + e.Message); }
            // (0.7.9, #136) another copy of the mod in the game's folders, which the game would take (see ModCopies)
            if (!autotest) FindStaleMods();
            if (!autotest && !ServerMode) WarnIncompatibleMods();
            try { if (LoadSettings().TryGetValue("savedirs", out var sd)) GameInstall.AddGameSaveDirs(sd.Split('|')); } catch { }
        }

        /// <summary>Back on the window's thread: the warnings, then the server's window, the game started (or waiting for the
        /// player's click, 0.7.4), or the autotest.</summary>
        void InitFinish()
        {
            if (!autotest) WarnNativeMissing();
            if (!autotest) WarnSmartAppControl();
            OfferStaleMods();
            if (ServerMode)
            {
                OpenServerWindow();
                return;
            }
            if (MenuModeDefault && !autotest)
            {
                if (LaunchAtStart(AutoLaunchSetting(), JoinAtStart != null, Program.Args)) { ShowLaunchControls(); StartMenuMode(); return; }
                waitingLaunch = true;
                ShowLaunchControls();
                Log.Ok(T("Prêt : réglez MPFever si besoin (⚙ Réglages en bas), puis cliquez sur « Lancer Transport Fever 3 ».",
                         "Ready: set MPFever up if needed (⚙ Settings at the bottom), then click « Start Transport Fever 3 »."));
                return;
            }
            ShowLaunchControls();
            if (autotest)
            {
                Guard(StartLocalTest);
                new Thread(AutoTest) { IsBackground = true, Name = "Autotest" }.Start();
            }
        }

        /// <summary>(0.6.5, #111) MPFever.exe copied alone, without winhttp.dll next to it: the native module in the game folder
        /// stays an old one (or none), and the sessions with the others reloaded every two minutes (the "ages" measure off on
        /// that game). Said plainly before the game starts (a line of the log only before); a dedicated server: in its log.
        /// MPFEVER_NATIVEWARN=0: the log line only, as before.</summary>
        void WarnNativeMissing()
        {
            if (GameInstall.NativeStatus != "missing" || Environment.GetEnvironmentVariable("MPFEVER_NATIVEWARN") == "0") return;
            Log.Err(T("Le fichier winhttp.dll de MPFever manque à côté de MPFever.exe : réinstallez MPFever en extrayant toute l'archive dans le même dossier.",
                      "MPFever's file winhttp.dll is missing next to MPFever.exe: reinstall MPFever, extracting the whole archive into the same folder."));
            if (ServerMode) return;
            MessageBox.Show(this, T("Le fichier winhttp.dll de MPFever manque à côté de MPFever.exe : MPFever a été copié sans les autres fichiers de l'archive.\n\nSans lui, le module natif du jeu reste ancien ou absent, et les parties avec les autres joueurs se resynchronisent sans cesse (mesure « ages »).\n\nFermez MPFever, extrayez toute l'archive MPFever-x.y.z.zip (tous ses fichiers) dans le même dossier, puis relancez-le.",
                                    "MPFever's file winhttp.dll is missing next to MPFever.exe: MPFever was copied without the other files of the archive.\n\nWithout it, the game's native module stays an old one or missing, and the sessions with the other players resynchronise again and again (the \"ages\" measure).\n\nClose MPFever, extract the whole archive MPFever-x.y.z.zip (all its files) into the same folder, then start it again."),
                            "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        /// <summary>(0.6.4) Windows' Smart App Control is on: it blocks MPFever's winhttp.dll and the game shows nothing but
        /// "Bad Image ... 0xc0e90002" (a German player's screenshot, 2026-10-31). Said plainly before the game starts, with the
        /// way to turn it off; Windows Security opens on its page when the player wants. A dedicated server: in its log only.</summary>
        void WarnSmartAppControl()
        {
            if (!GameInstall.SmartAppControlBlocks()) return;
            var text = T("Le contrôle intelligent des applications de Windows (Smart App Control) est activé. Il bloque le fichier winhttp.dll de MPFever : le jeu affiche alors « Image incorrecte ... winhttp.dll ... 0xc0e90002 » et MPFever ne peut pas fonctionner.\n\nPour jouer avec MPFever, désactivez-le : Sécurité Windows > Contrôle des applications et du navigateur > Paramètres du contrôle intelligent des applications > Désactivé. L'antivirus de Windows reste actif.\n\nAttention : sur certaines versions de Windows, il ne peut plus être réactivé ensuite sans réinstaller Windows.\n\nOuvrir la Sécurité Windows maintenant ?",
                         "Windows' Smart App Control is on. It blocks MPFever's file winhttp.dll: the game then shows \"Bad Image ... winhttp.dll ... 0xc0e90002\" and MPFever cannot work.\n\nTo play with MPFever, turn it off: Windows Security > App & browser control > Smart App Control settings > Off. Windows' antivirus stays on.\n\nNote: on some versions of Windows, it cannot be turned back on afterwards without reinstalling Windows.\n\nOpen Windows Security now?");
            Log.Err(T("Le contrôle intelligent des applications de Windows bloque MPFever (erreur 0xc0e90002 du jeu) : désactivez-le dans Sécurité Windows > Contrôle des applications et du navigateur.",
                      "Windows' Smart App Control blocks MPFever (the game's error 0xc0e90002): turn it off in Windows Security > App & browser control."));
            if (ServerMode) return;
            if (MessageBox.Show(this, text, "MPFever", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            try { Process.Start(new ProcessStartInfo("windowsdefender://appbrowser") { UseShellExecute = true }); }
            catch (Exception e) { Log.W("Windows Security: " + e.Message); }
        }

        /// <summary>(0.8.0) The player chooses which copy of the game MPFever uses (Steam, GOG, Epic), kept in the settings (gamedir);
        /// null when cancelled.</summary>
        internal static string ChooseCopy(List<string> copies, IWin32Window owner)
        {
            using (var f = new Form { Text = "MPFever", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
                StartPosition = FormStartPosition.CenterScreen, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(16) })
            {
                var panel = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Dock = DockStyle.Fill, WrapContents = false };
                panel.Controls.Add(new Label { AutoSize = true, MaximumSize = new Size(520, 0), Padding = new Padding(0, 0, 0, 8),
                    Text = T("Plusieurs copies de Transport Fever 3 sont installées sur ce PC. Laquelle MPFever doit-il utiliser ? (Modifiable ensuite dans ⚙ Réglages.)",
                             "Several copies of Transport Fever 3 are installed on this PC. Which one should MPFever use? (You can change it later in ⚙ Settings.)") });
                var radios = new List<RadioButton>();
                foreach (var c in copies)
                {
                    var plat = GameInstall.PlatformOf(c);
                    var r = new RadioButton { AutoSize = true, Text = (plat != "" ? plat + " : " : "") + c, Tag = c,
                        Checked = string.Equals(c, GameInstall.ChosenDir, StringComparison.OrdinalIgnoreCase) || (radios.Count == 0 && !GameInstall.IsGameDir(GameInstall.ChosenDir)) };
                    radios.Add(r);
                    panel.Controls.Add(r);
                }
                var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, AutoSize = true };
                panel.Controls.Add(ok);
                f.AcceptButton = ok;
                f.Controls.Add(panel);
                if (f.ShowDialog(owner) != DialogResult.OK) return null;
                var pick = radios.FirstOrDefault(r => r.Checked)?.Tag as string;
                if (!GameInstall.IsGameDir(pick)) return null;
                GameInstall.ChosenDir = pick;
                SaveSetting("gamedir", pick);
                Log.W(T("Copie du jeu choisie : ", "Copy of the game chosen: ") + pick);
                return pick;
            }
        }

        /// <summary>(0.6.3) The game not found (a GOG copy, a folder of its own): the player shows MPFever the game's
        /// TransportFever3.exe, kept in the settings (gamedir). Null when cancelled. MPFEVER_GOG=0: not asked.</summary>
        string AskGameDir()
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_GOG") == "0") return null;
            var answer = MessageBox.Show(this, T("Transport Fever 3 est introuvable dans Steam et GOG.\n\nSi le jeu est installé ailleurs, montrez à MPFever le fichier TransportFever3.exe de son dossier. Choisir ce fichier maintenant ?",
                                                 "Transport Fever 3 was not found in Steam or GOG.\n\nIf the game is installed elsewhere, show MPFever the TransportFever3.exe file of its folder. Choose that file now?"),
                                         "MPFever", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return null;
            using (var dlg = new OpenFileDialog { Title = T("Choisissez TransportFever3.exe", "Choose TransportFever3.exe"), Filter = "TransportFever3.exe|TransportFever3.exe", CheckFileExists = true })
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return null;
                var dir = Path.GetDirectoryName(dlg.FileName);
                if (!GameInstall.IsGameDir(dir)) return null;
                GameInstall.ChosenDir = dir;
                SaveSetting("gamedir", dir);
                return dir;
            }
        }

        /// <summary>The savegame folders the game gave to the MPFever page (save_dirs.txt): looked in for the host's savegame,
        /// the one received from the host and the resynchronisations, and kept for the next start (issue #76: a game not
        /// installed through Steam, whose savegames were never found).</summary>
        void ReadGameSaveDirs()
        {
            try
            {
                var f = menuGame == null ? null : Path.Combine(menuGame.Dir, "save_dirs.txt");
                if (f == null || !File.Exists(f)) return;
                if (!GameInstall.AddGameSaveDirs(File.ReadAllLines(f, System.Text.Encoding.UTF8))) return;
                lock (GameInstall.GameSaveDirs)
                {
                    Log.Dim(T("Dossiers des sauvegardes du jeu : ", "The game's savegame folders: ") + string.Join(", ", GameInstall.GameSaveDirs));
                    SaveSetting("savedirs", string.Join("|", GameInstall.GameSaveDirs));
                }
            }
            catch (Exception e) { Log.W("save_dirs: " + e.Message); }
        }

        /// <summary>Another multiplayer mod installed on this PC (TPF3-MP): told at start, in a window, since a savegame where it
        /// is active desynchronises all the time with MPFever.</summary>
        void WarnIncompatibleMods()
        {
            new Thread(() =>
            {
                string dir = null;
                try { dir = Mods.Dir("tpf3mp_1"); } catch { }
                if (dir == null) return;
                var text = T("TPF3-MP (un autre mod multijoueur) est installé sur ce PC.\n\nIl est INCOMPATIBLE avec MPFever : il modifie les mêmes choses que lui, et une partie où il est actif se désynchronise sans cesse.\n\nDésactivez-le dans les mods de vos sauvegardes (au chargement de la partie) avant de jouer avec MPFever, ou désinstallez-le.",
                    "TPF3-MP (another multiplayer mod) is installed on this PC.\n\nIt is INCOMPATIBLE with MPFever: it changes the same things, and a game where it is active keeps desynchronising.\n\nTurn it off in your savegames' mods (when loading the game) before playing with MPFever, or uninstall it.");
                Log.Err(T("TPF3-MP est installé : il est incompatible avec MPFever, désactivez-le dans vos parties multijoueur (", "TPF3-MP is installed: it is incompatible with MPFever, turn it off in your multiplayer games (") + dir + ")");
                // (the window once per version of MPFever: a player may keep it for other games)
                if (LoadSettings().TryGetValue("tpf3mpWarned", out var v) && v == Version) return;
                SaveSetting("tpf3mpWarned", Version);
                try { BeginInvoke((Action)(() => MessageBox.Show(this, text, "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Warning))); } catch { }
            }) { IsBackground = true, Name = "Incompatible mods" }.Start();
        }

        // ---------------------------------------------------------------- main menu mode

        // (the self-test's own file: never the player's)
        internal static string SettingsFileForTest;
        static string SettingsFile => SettingsFileForTest ?? Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mpfever_settings.txt");
        static readonly object settingsWrite = new object();

        internal static Dictionary<string, string> LoadSettings() => LoadSettings(out _);

        /// <summary>The settings; ok false when the file is there but could not be read (written by another request at that moment, an
        /// antivirus), after three tries 20 ms apart: the dictionary is then empty, not the player's settings.</summary>
        internal static Dictionary<string, string> LoadSettings(out bool ok)
        {
            var d = new Dictionary<string, string>();
            ok = true;
            for (int tries = 0; ; tries++)
            {
                try
                {
                    d.Clear();
                    foreach (var l in File.ReadAllLines(SettingsFile)) { int i = l.IndexOf('='); if (i > 0) d[l.Substring(0, i)] = l.Substring(i + 1); }
                    return d;
                }
                catch (FileNotFoundException) { d.Clear(); return d; }
                catch (DirectoryNotFoundException) { d.Clear(); return d; }
                catch (Exception)
                {
                    if (tries >= 2) { d.Clear(); ok = false; return d; }
                    Thread.Sleep(20);
                }
            }
        }

        internal static void SaveSetting(string k, string v)
        {
            // (0.6) the game options in memory first: the session's from now on, even if the file cannot be written
            if (k == "gameopts") gameOptsKept = GameOpts.Canon(v ?? "");
            lock (settingsWrite)
            {
                var d = LoadSettings(out bool ok);
                // (0.6: a file that could not be read is not written again with this one setting only: the others were lost)
                if (!ok) { Log.W("settings: mpfever_settings.txt could not be read, " + k + " not saved"); return; }
                d[k] = v;
                try { File.WriteAllLines(SettingsFile, d.Select(kv => kv.Key + "=" + kv.Value)); } catch { }
            }
        }

        /// <summary>(0.6) The game options kept in memory (see gameOptsKept): read from the settings the first time, again only while
        /// the file cannot be read (then none, never a game's options turned off by a failed read once they are known).</summary>
        internal static string KeptGameOptions()
        {
            var kept = gameOptsKept;
            if (kept != null) return kept;
            var d = LoadSettings(out bool ok);
            d.TryGetValue("gameopts", out var v);
            var s = GameOpts.Canon(v ?? "");
            if (ok) gameOptsKept = s;
            return s;
        }

        /// <summary>(the self-test) the game options read from the settings file again, as at MPFever.exe's start.</summary>
        internal static void ForgetGameOptions() { gameOptsKept = null; }

        /// <summary>The player name kept from the last host or join in the MPFever window (name= in mpfever_settings.txt),
        /// else the Windows user name. The game and the launcher window both start with it.</summary>
        static string SavedName() => LoadSettings().TryGetValue("name", out var n) && n != "" ? n : Environment.UserName;

        /// <summary>(0.7.13) The port a player's lobby listens on, and the port of an address given without one: port= in
        /// mpfever_settings.txt, else 28090 as before (the launcher's « Port » field went with its « Connection » card).</summary>
        static int SavedPort() => PortSetting(LoadSettings().TryGetValue("port", out var p) ? p : null);
        internal static int PortSetting(string v) =>
            int.TryParse((v ?? "").Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int n) && n >= 1024 && n <= 65535 ? n : 28090;

        /// <summary>(0.7.13, a hardening of the review) The port of an address joined without one (the game's Multiplayer page, a
        /// Steam invitation, --join: OnMenuRequest "join"): 28090, the usual port of a lobby, whatever port= in mpfever_settings.txt
        /// says (the port this player's own lobby listens on: a friend's does not share it, and nothing on screen shows it); with
        /// the old « Connection » card (--dev, MPFEVER_CONNCARD=1) its « Port » field, shown next to the address, as before.</summary>
        internal static int JoinPort(bool connCard, int field) => connCard ? field : 28090;

        /// <summary>MPFever.exe started normally: the game starts at once; hosting or joining is chosen in the MPFever
        /// window of its main menu.</summary>
        void StartMenuMode()
        {
            menuMode = true;
            running = true;
            hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false;
            menuGame = new GameLink(SavedName(), "menu");
            games.Add(menuGame);
            // a savegame loaded without a lobby (from the game's own menu): its mod keeps nothing for other players, and the native
            // module holds no tool build for a lobby (issue #82: the frame rate fell with each module of a train station)
            menuGame.FromGame += (g, m) =>
            {
                if (m.Kind != "hello" || hostFromGame != null || clientFromGame != null) return;
                g.ToGame(Msg.Make("solo", g.Name));
                NativeHoldOff(g);
            };
            menuGame.Exited += () =>
            {
                // ((0.7.5) with its exit code, and whether another game shared its log)
                var g = menuGame;
                string code = g?.ExitCode == null ? "?" : (g.ExitCode.Value < 0 || g.ExitCode.Value > 0xFFFF ? "0x" + g.ExitCode.Value.ToString("X8") : g.ExitCode.Value.ToString());
                Log.W(F("Transport Fever 3 fermé (code {0}{1}).", "Transport Fever 3 closed (code {0}{1}).", code,
                    g != null && g.OtherGameSeen ? T(", un autre jeu sur ce PC", ", another game on this PC") : ""));
                // (0.8.4, #254) code 53 within seconds: the game did not reach Steam (SteamAPI_Init); the bare code told the player nothing
                if (SteamUnreachableExit(g?.ExitCode, DateTime.Now - gameStartedAt) && Environment.GetEnvironmentVariable("MPFEVER_STEAMHINT") != "0")
                    Log.Warn(T("Le jeu n'a pas pu joindre Steam et s'est fermé tout de suite. Lancez Steam et connectez-vous, puis relancez MPFever. Steam et MPFever doivent tourner avec les mêmes droits : aucun des deux « en tant qu'administrateur », ou les deux.",
                               "The game could not reach Steam and closed at once. Start Steam and sign in, then start MPFever again. Steam and MPFever must run with the same rights: neither « as administrator », or both."));
                LeaveOnGameExit(); try { BeginInvoke((Action)InstallPendingUpdateThenClose); } catch { }
            };
            MenuStatus();
            // (the game rewrites its log at its start: the previous run's is kept for a report)
            if (JoinAtStart == null) Reporter.KeepPreviousGameLog();
            gameStartedAt = DateTime.Now;
            menuGame.Launch(gameDir);
            WindowState = FormWindowState.Minimized;
            Log.W(T("Le jeu démarre : choisissez « Multijoueur (MPFever) » dans son menu principal.", "The game is starting: choose « Multiplayer (MPFever) » in its main menu."));
            new Thread(MenuLoop) { IsBackground = true, Name = "Menu link" }.Start();
            new Thread(ServerListFetchLoop) { IsBackground = true, Name = "Server list" }.Start();
            // (0.6: a host's game in the public list, Steam friends only; idle while those options are off, see PublicGames.cs)
            new Thread(PublicGameLoop) { IsBackground = true, Name = "Public game" }.Start();
            if (JoinAtStart != null)
            {
                var addr = JoinAtStart;
                new Thread(() => { Thread.Sleep(1000); OnMenuRequest("join", addr, menuGame.Name); }) { IsBackground = true }.Start();
            }
        }

        /// <summary>(0.8.4, #254) The game closed with code 53 less than 30 s after its start: SteamAPI_Init failed (Steam not running,
        /// or Steam and the game with different rights). A game closed later with 53 is not explained this way.</summary>
        internal static bool SteamUnreachableExit(int? code, TimeSpan lived) => code == 53 && lived < TimeSpan.FromSeconds(30);

        /// <summary>The native module of this game holds the tools' builds no more (native_ctl.txt "enable 0"): the mod of a session
        /// turned it on, and nobody releases them once the session is over (a savegame loaded afterwards: no build went through).</summary>
        static void NativeHoldOff(GameLink g)
        {
            try
            {
                using (var f = new FileStream(Path.Combine(g.Dir, "native_ctl.txt"), FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                {
                    var b = System.Text.Encoding.ASCII.GetBytes("enable 0\n");
                    f.Write(b, 0, b.Length);
                }
            }
            catch (Exception e) { Log.Dim("native_ctl: " + e.Message); }
        }

        /// <summary>Command for the native module's Steam part (steam_ctl.txt): presence / invite / clear.</summary>
        void SteamCtl(string cmd, string arg)
        {
            try { File.WriteAllText(Path.Combine(menuGame.Dir, "steam_ctl.txt"), (++steamSeq) + "-" + DateTime.Now.Ticks + " " + cmd + (arg != null ? " " + arg : "") + "\n"); }
            catch (Exception e) { Log.W("steam_ctl: " + e.Message); }
        }

        /// <summary>The address friends use to reach this host: its public IP (asked to api.ipify.org, unless
        /// lookupip=0 is written in mpfever_settings.txt), else its local address.</summary>
        static string PublicAddress()
        {
            var st = LoadSettings();
            if (st.TryGetValue("lookupip", out var lk) && lk.Trim() == "0")
                return LocalAddresses().Split(',')[0].Trim();
            try
            {
                var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create("https://api.ipify.org");
                req.Timeout = 5000;
                using (var resp = req.GetResponse())
                using (var r = new StreamReader(resp.GetResponseStream()))
                {
                    var ip = r.ReadToEnd().Trim();
                    if (System.Net.IPAddress.TryParse(ip, out _)) return ip;
                }
            }
            catch (Exception e) { Log.Warn(T("Adresse IP publique inconnue : ", "Public IP address unknown: ") + e.Message); }
            return LocalAddresses().Split(',')[0].Trim();
        }

        /// <summary>A friend accepted an invitation, or clicked « Join game » in Steam (steam_join.txt).</summary>
        void CheckSteamJoin()
        {
            var f = Path.Combine(menuGame.Dir, "steam_join.txt");
            if (!File.Exists(f)) return;
            string line;
            try { line = File.ReadAllText(f).Trim(); } catch { return; }
            if (line == "" || line == lastSteamJoin) return;
            lastSteamJoin = line;
            var parts = line.Split('\t');
            var connect = parts.Length > 1 ? parts[1] : parts[0];
            int k = connect.IndexOf("+mpfever_connect", StringComparison.Ordinal);
            if (k < 0) return;
            var addr = connect.Substring(k + "+mpfever_connect".Length).Trim();
            Log.Ok(T("Invitation Steam acceptée : ", "Steam invitation accepted: ") + addr);
            // in the main menu, a session left behind does not stop an invitation (the join ends it, issue #13)
            if (hostGame != null || (clients.Count > 0 && menuGame.InGame)) { Log.Warn(T("Déjà dans une session : invitation ignorée.", "Already in a session: invitation ignored.")); return; }
            OnMenuRequest("join", addr, menuGame.Name);
        }

        /// <summary>The mods of the savegame the host chose, as its menu wrote them just before asking to host.</summary>
        string ReadHostMods()
        {
            try
            {
                var f = Path.Combine(menuGame.Dir, "host_mods.txt");
                // (0.7.0: written by the menu when the host picks the savegame, its DLCs among its mods, see SessionDlcs)
                lobbyModsKnown = File.Exists(f);
                var mods = File.Exists(f) ? File.ReadAllText(f).Trim() : "";
                var names = ModNames(mods);
                if (names.Count > 0)
                {
                    Log.W(F("Mods de la sauvegarde ({0}) : ", "Mods of the savegame ({0}): ", names.Count) + string.Join(", ", names));
                    Log.Warn(T("MPFever n'est pas encore prévu pour les mods : certains peuvent désynchroniser la partie.", "MPFever is not made for mods yet: some can desynchronise the game."));
                }
                return mods;
            }
            catch (Exception e) { Log.W("host_mods: " + e.Message); return ""; }
        }

        static List<string> ModNames(string mods)
        {
            var names = new List<string>();
            foreach (var e in (mods ?? "").Split(new[] { ";;" }, StringSplitOptions.RemoveEmptyEntries))
            {
                var f = e.Split('|');
                names.Add(f.Length > 1 && f[1].Trim() != "" ? f[1].Trim() : f[0].Trim());
            }
            return names;
        }

        /// <summary>(a player) The host's mods, from its lobby or its welcome: compared with this PC's, the differences logged
        /// and told to the host (shown next to this player's name in its lobby).</summary>
        void SetHostMods(string mods, Client client, string name)
        {
            if (mods == lobbyMods && modCheck != null) return;
            lobbyMods = mods;
            var c = Mods.Compare(mods, false);
            modCheck = c;
            var names = ModNames(mods);
            if (names.Count > 0) Log.W(F("Mods de la partie de l'hôte ({0}) : ", "Mods of the host's game ({0}): ", names.Count) + string.Join(", ", names));
            if (c.Differs.Count > 0)
                Log.Err(F("Ces mods ne sont pas dans la même version que chez l'hôte ({0}) : {1}. Mettez-les à jour avant que l'hôte lance la partie.", "These mods are not the same version as the host's ({0}): {1}. Update them before the host starts the game.", c.Differs.Count, string.Join(", ", c.Differs)));
            if (c.Bad.Count > 0)
                Log.Err(F("La partie de l'hôte contient des mods INCOMPATIBLES avec MPFever : {0}. Demandez à l'hôte de les désactiver, sinon la partie se désynchronisera sans cesse.", "The host's game has mods INCOMPATIBLE with MPFever: {0}. Ask the host to turn them off, or the game will keep desynchronising.", string.Join(", ", c.Bad)));
            // (the missing ones no Mod Hub has: the host may send them, see modAsks)
            var hubs = Mods.Parse(mods).ToDictionary(e => e.Id, e => e.Hub, StringComparer.OrdinalIgnoreCase);
            // (0.6.7) a mod of the host's PC only (StagingArea...) is the host's to send even when the game gave it a Mod Hub number
            // (a mod being prepared for upload), see Mods.LocalSource. MPFEVER_LOCALMODS=0: by the Mod Hub number only, as before
            var srcs = Mods.Parse(mods).ToDictionary(e => e.Id, e => e.Source, StringComparer.OrdinalIgnoreCase);
            bool localOn = Environment.GetEnvironmentVariable("MPFEVER_LOCALMODS") != "0";
            var noHub = c.MissingIds.Where(id => !hubs.TryGetValue(id, out var hb) || hb == ""
                || (localOn && srcs.TryGetValue(id, out var sv) && Mods.LocalSource(sv))).ToList();
            if (noHub.Count == 0) { modAskState = ""; modOffer = ""; }
            else if (modAskState == "") modAskState = "waiting";
            try { client?.Send(Msg.Make("modcheck", name, "{[\"differs\"]=" + LuaLit.Quote(string.Join(", ", c.Differs)) + ",[\"nohub\"]=" + LuaLit.Quote(string.Join(",", noHub)) + "}")); } catch { }
            MenuStatus();
        }

        string lastHostDlcs = null;
        /// <summary>(0.6.9) This player's DLCs against the host's (in its lobby and its welcome; "" from an older MPFever: nothing
        /// said): a warning here and in the lobby, and this player's list sent to the host (dlccheck), which shows it in its own.</summary>
        void CheckHostDlcs(string hostList, Client client, string name)
        {
            if (hostList == lastHostDlcs) return;
            lastHostDlcs = hostList;
            var mine = Mods.InstalledDlcs();
            var (hostOnly, mineOnly) = Mods.DlcDiff(hostList, mine);
            dlcsDiffer = !string.IsNullOrEmpty(hostList) && (hostOnly.Count > 0 || mineOnly.Count > 0);
            var parts = new List<string>();
            if (mineOnly.Count > 0 && !DlcSessionOn()) parts.Add(F("vous avez {0}, pas la partie de l'hôte", "you have the {0}, the host's game does not", string.Join(", ", mineOnly)));
            if (hostOnly.Count > 0 && !DlcSessionOn()) parts.Add(F("la partie de l'hôte utilise {0}, vous ne l'avez pas", "the host's game uses the {0}, you do not have it", string.Join(", ", hostOnly)));
            // (0.7.0: the advice instead of "every player needs the same DLCs"; the game can still be played)
            dlcWarn = Mods.DlcWarningText(parts);
            dlcListView = Mods.DlcListView(hostList, mine);
            if (dlcWarn != "") Log.Err(dlcWarn);
            try { client?.Send(Msg.Make("dlccheck", name, "{[\"dlcs\"]=" + LuaLit.Quote(mine) + "}")); } catch { }
            MenuStatus();
        }

        /// <summary>(0.7.0, a player) Nothing to look at before joining a game already running: the host's mods are all here in its
        /// version (or taken for personal), none is incompatible, and the DLCs are the same.</summary>
        bool JoinReviewClear()
        {
            var c = modCheck;
            bool mods = c == null || (c.Missing.Count == 0 && c.Differs.Count == 0 && c.Bad.Count == 0);
            // (0.7.10, a regression of 0.7.8) different DLCs open the join review again: 0.7.8 dropped the "different DLCs"
            // warning (an unused DLC does nothing, a used one is switched off for the session), and the review, which opened on
            // that warning, no longer showed for most players (the host's DLCs rarely are every player's). MPFEVER_REVIEWDLC=0:
            // as 0.7.8
            bool dlcs = !dlcsDiffer || Environment.GetEnvironmentVariable("MPFEVER_REVIEWDLC") == "0";
            return mods && dlcs && string.IsNullOrEmpty(PlayerDlcWarn());
        }
        /// <summary>(0.7.10) This PC's DLCs are not the host's game's (either way), whatever the warnings say.</summary>
        bool dlcsDiffer;

        /// <summary>(0.6.9, the host) The DLC warnings of the players whose DLCs are not the host's, for the lobby.</summary>
        string HostDlcWarn()
        {
            string d; lock (dlcIssues) d = Mods.DlcWarningText(dlcIssues.Values.ToList());
            string b; lock (buildIssues) b = string.Join(" ", buildIssues.Values);
            return string.Join(" ", new[] { d, b }.Where(x => !string.IsNullOrEmpty(x)));
        }

        // (0.7.7) a game build other than the host's, like the DLCs: a warning in the lobby, the join review and the report, never
        // a refusal (issue #135: a GOG copy, build 40393, with a host on Steam's 40425, reloaded every 3 to 5 minutes). The host
        // tells its build (Reporter.BuildTag, "gbuild" in its lobby and welcome), each player compares and tells its own
        // (buildcheck), the host shows the players' in its lobby. MPFEVER_BUILDWARN=0: nothing, as before
        string buildWarn = "", lastHostBuild = null;
        readonly Dictionary<string, string> buildIssues = new Dictionary<string, string>();
        string PlayerDlcWarn() => string.Join(" ", new[] { dlcWarn, buildWarn }.Where(x => !string.IsNullOrEmpty(x)));

        void CheckHostBuild(string hostTag, Client client, string name)
        {
            if (string.IsNullOrEmpty(hostTag) || hostTag == lastHostBuild || Environment.GetEnvironmentVariable("MPFEVER_BUILDWARN") == "0") return;
            lastHostBuild = hostTag;
            var mine = Reporter.BuildTag(gameDir);
            buildWarn = BuildWarning(null, hostTag, mine);
            if (buildWarn != "") Log.Err(buildWarn);
            try { client?.Send(Msg.Make("buildcheck", name, "{[\"gbuild\"]=" + LuaLit.Quote(mine) + "}")); } catch { }
            MenuStatus();
        }

        /// <summary>(0.7.7) The warning for a game build other than the host's ("" when the same; player null: this PC's own view).
        /// A tag is "stamp|build|store" (Reporter.BuildTag): the stamp tells the builds apart, the number and the store are shown.</summary>
        internal static string BuildWarning(string player, string hostTag, string theirTag)
        {
            if (string.IsNullOrEmpty(hostTag) || string.IsNullOrEmpty(theirTag)) return "";
            var h = hostTag.Split('|'); var t = theirTag.Split('|');
            if (h[0] == t[0]) return "";
            string Show(string[] x) => (x.Length > 1 && x[1] != "?" ? x[1] : x[0]) + (x.Length > 2 && x[2] == "other" ? " (" + T("pas une copie Steam", "not a Steam copy") + ")" : "");
            return player == null
                ? F("Version du jeu différente : vous avez la version {0}, l'hôte la version {1}. Deux versions différentes ne simulent pas la partie de la même façon : des désynchronisations sont probables. Ayez la même version (Steam : Propriétés > Fichiers installés > Vérifier l'intégrité). La partie peut tout de même être lancée.",
                    "Different game build: you have build {0}, the host build {1}. Two different builds do not simulate the game alike: desyncs are likely. Get the same build (Steam: Properties > Installed Files > Verify integrity). The game can still be played.", Show(t), Show(h))
                : F("{0} a la version {1} du jeu, l'hôte la version {2} : des désynchronisations sont probables. La partie peut tout de même être lancée.",
                    "{0} has build {1} of the game, the host build {2}: desyncs are likely. The game can still be played.", player, Show(t), Show(h));
        }

        /// <summary>(0.7.0) The DLCs of this session as the host tells them to its players: its savegame's when its mods are known
        /// (the host may have switched a DLC off in them), else the DLCs installed on the host's PC. MPFEVER_SAVEDLCS=0: always
        /// the installed ones, as 0.6.9 to 0.6.12.</summary>
        string SessionDlcs()
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_SAVEDLCS") == "0") return Mods.InstalledDlcs();
            var all = Mods.SaveDlcs(lobbyMods, lobbyModsKnown) ?? Mods.InstalledDlcs();
            // (0.7.7: without the DLCs switched off for this session, see ApplyDlcOff)
            string[] off; lock (sessionDlcOff) off = sessionDlcOff.ToArray();
            return Mods.DlcMinus(all, off);
        }

        // (0.7.7) A DLC works like a mod of the savegame: a game loads its models, its game script (the Deluxe pack's balloon,
        // math.random in the simulation) and its animals only when the savegame's mods name it; installed and not named, it does
        // nothing (4404 models known on two PCs, one with both packs and one with none; 4433 with the Deluxe pack named). A
        // savegame naming a DLC that a player lacks was loaded with it on the others and without it on that player's game: the
        // games parted. The host now decides, for the whole session, the DLCs of the savegame that some game lacks
        // (sessionDlcOff, only growing until the session ends); every load of the session leaves them out, the host's own and its
        // reloads included (dlc_drop.txt next to the game, "dlcoff" to the players, read by mpfever_auto.lua and C.loadWithPlan).
        // MPFEVER_DLCSESSION=0: as before (warnings only, a player lacking a DLC loads without it alone)
        readonly HashSet<string> sessionDlcOff = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, string> playerDlcs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        static bool DlcSessionOn() => Environment.GetEnvironmentVariable("MPFEVER_DLCSESSION") != "0";

        /// <summary>(0.7.7, the host) Before a load of the session (the lobby's start, a resynchronisation): the savegame's DLCs that
        /// the host's PC or one of these players lacks are switched off for the session, the host's own load is told (dlc_drop.txt)
        /// and the players too ("dlcoff", before the savegame they load).</summary>
        void ApplyDlcOff(IEnumerable<string> names, string why)
        {
            if (!DlcSessionOn()) return;
            try
            {
                var save = Mods.SaveDlcs(lobbyMods, lobbyModsKnown) ?? Mods.InstalledDlcs();
                var lists = new List<string> { Mods.InstalledDlcs() };
                var lacking = new List<string>();
                lock (playerDlcs)
                    foreach (var n in names ?? new string[0])
                        if (playerDlcs.TryGetValue(BaseName(n), out var l)) lists.Add(l);
                var off = Mods.DlcOff(save, lists);
                List<string> added;
                lock (sessionDlcOff) { added = off.Where(x => sessionDlcOff.Add(x)).ToList(); off = sessionDlcOff.ToList(); }
                foreach (var d in added)
                {
                    var who = new List<string>();
                    if (!Mods.DlcIn(Mods.InstalledDlcs(), d)) who.Add(BaseName(hostName ?? ""));
                    lock (playerDlcs) foreach (var kv in playerDlcs) if (!Mods.DlcIn(kv.Value, d)) who.Add(kv.Key);
                    var text = F("{0} désactivé pour cette session ({1}) : {2} ne l'a pas. Toutes les parties tournent sans lui, pour rester identiques ; la sauvegarde d'origine le garde.",
                        "{0} switched off for this session ({1}): {2} does not have it. Every game runs without it, to stay alike; the original savegame keeps it.", Mods.DlcName(d), why, string.Join(", ", who.Distinct()));
                    Log.Warn(text);
                    HostChat("msg", "MPFever", text);
                }
                var host = hostGame ?? menuGame;
                if (host != null) WriteDlcDrop(host.Dir, off);
                HostSend(Msg.Make("dlcoff", hostName ?? "", "{[" + "\"ids\"" + "]=" + LuaLit.Quote(string.Join(",", off)) + "}"));
            }
            catch (Exception e) { Log.W("dlcoff: " + e.Message); }
        }

        /// <summary>(0.7.7) The DLCs a game of this session leaves out at its loads (dlc_drop.txt, "off TAB id" lines; always
        /// written, empty when none: a session folder lives as long as the game).</summary>
        internal static void WriteDlcDrop(string dir, IEnumerable<string> ids)
        {
            try
            {
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
                File.WriteAllText(Path.Combine(dir, "dlc_drop.txt"), string.Concat((ids ?? new string[0]).Select(x => "off\t" + x + "\n")));
            }
            catch (Exception e) { Log.W("dlc_drop.txt: " + e.Message); }
        }

        /// <summary>(the host) What MPFever knows of each mod of the savegame, in the log.</summary>
        void LogModVerdicts(string described, double seconds)
        {
            var rows = Mods.Compare(described, true).View.Split(new[] { ";;" }, StringSplitOptions.RemoveEmptyEntries).Select(e => e.Split('|')).ToList();
            if (rows.Count == 0) return;
            var bad = rows.Where(f => f.Length > 4 && f[4] == "bad").Select(f => f[1]).ToList();
            var caution = rows.Where(f => f.Length > 4 && f[4] == "caution").Select(f => f[1]).ToList();
            var fixedOnes = rows.Where(f => f.Length > 4 && f[4] == "fixed").Select(f => f[1]).ToList();
            Log.W(F("Mods examinés en {0:0.0} s : {1} sans risque connu, {2} rendus compatibles, {3} non testés, {4} incompatibles", "Mods checked in {0:0.0} s: {1} with no known risk, {2} made compatible, {3} untested, {4} incompatible",
                seconds, rows.Count - bad.Count - caution.Count - fixedOnes.Count, fixedOnes.Count, caution.Count, bad.Count));
            if (fixedOnes.Count > 0) Log.Ok(T("Rendus compatibles par MPFever : ", "Made compatible by MPFever: ") + string.Join(", ", fixedOnes));
            if (caution.Count > 0) Log.Warn(T("Scripts qui agissent sur la partie, pas encore testés : ", "Scripts acting on the game, not tested yet: ") + string.Join(", ", caution));
            if (bad.Count > 0) Log.Err(T("INCOMPATIBLES avec MPFever : ", "INCOMPATIBLE with MPFever: ") + string.Join(", ", bad)
                + T(". Désactivez-les dans les mods de la sauvegarde (au chargement de la partie) avant de jouer : la partie se désynchroniserait sans cesse.", ". Turn them off in the savegame's mods (when loading the game) before playing: the game would keep desynchronising."));
        }

        /// <summary>The host's game was not loaded: mods of it are missing on this PC (missing_mods.txt, written by
        /// mpfever_auto.lua). The session ends and the MPFever page of the menu lists them.</summary>
        /// <summary>(0.7.4, RESYNCLEFT) The seconds a player gone during a resynchronisation has to come back.</summary>
        internal const int ResyncLeftSeconds = 20;

        /// <summary>(0.7.4, RESYNCLEFT) A player gone during a resynchronisation is no longer waited for, unless a connection of
        /// the same player (its base name: dickj#55 for dickj#53) is there again. Returns how many names were dropped.</summary>
        internal static int DropDeparted(HashSet<string> waiting, string gone, IEnumerable<string> connected)
        {
            string b = BaseName(gone);
            if (connected.Any(n => BaseName(n) == b)) return 0;
            return waiting.RemoveWhere(w => w == gone || BaseName(w) == b);
        }

        /// <summary>(0.7.6, RESYNCLEFTNAME) Whether a resynchronisation waits for this player, under this connection's name or
        /// another of the same player. The user's server, 2026-11-07 20:02: chris#10 left while the game was on its way, came back
        /// 17 s later as chris#12 (so chris#10 stayed waited for), and left again: the wait looked for "chris#12", found nothing
        /// and never dropped chris#10: every game stood 600 s. exact (MPFEVER_RESYNCLEFTNAME=0): this name only, as before.</summary>
        internal static bool WaitedFor(HashSet<string> waiting, string name, bool exact)
        {
            if (exact) return waiting.Contains(name);
            string b = BaseName(name);
            return waiting.Any(w => w == name || BaseName(w) == b);
        }

        /// <summary>(0.7.6, JOINMIDRESYNC) What becomes of a player who joins (its look at the mods and DLCs done) while a
        /// resynchronisation runs: "pending", a resynchronisation of its own afterwards (as before: no resynchronisation, or its
        /// game not saved yet, or its wait over); "send", the game being sent now goes to it too and is waited for (chris#12 on
        /// the user's server, 2026-11-07 20:03:16, got nothing: the game was on its way to the others, and nothing was left to do
        /// for it afterwards either). old (MPFEVER_JOINMIDRESYNC=0): as before ("none" during a resynchronisation).</summary>
        internal static string JoinDuringResync(bool resyncing, bool hasBytes, bool sending, int bytesId, int cancelled, bool old)
        {
            if (!resyncing || !hasBytes) return "pending";
            if (old) return "none";
            return sending && cancelled < bytesId ? "send" : "pending";
        }

        /// <summary>(0.7.4, MODRETRY) A dedicated server whose own world needs a mod the game does not see yet tries again: the
        /// user's server, 2026-11-06 23:20, "PYT - Mega Warehouse (mod.io)" missing 2 s after the menu, there at 21:04 (mod.io was
        /// updating it). Its game is started again after 30 s, three times at most, before giving up. MPFEVER_MODRETRY=0: as
        /// before (the session ends at once).</summary>
        int serverModRetries;
        internal const int ServerModRetryMax = 3, ServerModRetrySeconds = 30;
        internal static bool ServerModRetry(bool serverMode, bool anyLocal, int done) =>
            serverMode && !anyLocal && done < ServerModRetryMax && Environment.GetEnvironmentVariable("MPFEVER_MODRETRY") != "0";

        void CheckMissingMods()
        {
            var f = Path.Combine(menuGame.Dir, "missing_mods.txt");
            if (!File.Exists(f) || new FileInfo(f).Length == 0) return;
            string[] lines;
            try { lines = File.ReadAllLines(f, System.Text.Encoding.UTF8); File.WriteAllText(f, ""); } catch { return; }
            var rows = lines.Select(l => l.Split('\t')).Where(x => x[0].Trim() != "").ToList();
            var names = rows.Select(x => (x.Length > 1 && x[1].Trim() != "" ? x[1].Trim() : x[0].Trim()) + (x.Length > 2 && x[2].Trim() != "" ? " (" + x[2].Trim() + ")" : "")).ToList();
            if (names.Count == 0) return;
            // (0.6.7) a mod of the host's PC only is on no Mod Hub: only the host can send it, from its Multiplayer page
            bool anyLocal = rows.Any(x => x.Length > 2 && Mods.LocalSource(x[2]));
            var text = F("Mods manquants ({0}) : ", "Missing mods ({0}): ", names.Count) + string.Join(", ", names)
                + (anyLocal
                    ? T(". Certains sont des mods locaux de l'hôte, publiés nulle part : l'hôte doit vous les envoyer (bouton Envoyer de sa page Multijoueur, avant de lancer la partie), les autres s'installent depuis le Steam Workshop ou mod.io. Puis rejoignez à nouveau.",
                        ". Some are the host's local mods, published nowhere: the host must send them to you (Send button of its Multiplayer page, before it starts the game); install the others from the Steam Workshop or mod.io. Then join again.")
                    : T(". Installez-les (Steam Workshop ou mod.io), puis rejoignez à nouveau.", ". Install them (Steam Workshop or mod.io), then join again."));
            if (ServerModRetry(ServerMode, anyLocal, serverModRetries))
            {
                int k = ++serverModRetries;
                Log.Warn(F("Le monde du serveur n'a pas été chargé : mods introuvables pour l'instant ({0}). Steam ou mod.io les met peut-être à jour : nouvel essai dans {1} s ({2}/{3}).",
                    "The server's world was not loaded: mods not found yet ({0}). Steam or mod.io may be updating them: trying again in {1} s ({2}/{3}).",
                    string.Join(", ", names), ServerModRetrySeconds, k, ServerModRetryMax));
                new Thread(() =>
                {
                    Thread.Sleep(ServerModRetrySeconds * 1000);
                    if (serverStopping) return;
                    if (menuGame.GameRunning) { restartRequested = true; menuGame.Kill(); }
                    else { EndSession(); BeginServerWorld(true); }
                }) { IsBackground = true, Name = "Server mod retry" }.Start();
                return;
            }
            // (and the host hears why this player is gone)
            try { clients.FirstOrDefault()?.Send(Msg.Make("modmissing", menuGame.Name, "{[\"mods\"]=" + LuaLit.Quote(string.Join(", ", names)) + "}")); } catch { }
            Log.Err(T("La partie de l'hôte n'a pas été chargée. ", "The host's game was not loaded. ") + text);
            EndSession(T("=== Mods manquants : fin de la session ===", "=== Missing mods: the session ends ==="));
            menuPhase = "error"; menuText = text; MenuStatus();
        }

        /// <summary>Writes the state shown by the game's MPFever window.</summary>
        void MenuStatus()
        {
            if (menuGame == null) return;
            var st = LoadSettings();
            string list;
            int known;
            lock (players) { list = string.Join(", ", players); known = players.Count; }
            if ((lobbyOpen || lobbyStarting) && relay != null) list = LobbyList();
            else if (lobbyPlayers != "" && hostGame == null && !menuGame.InGame) list = lobbyPlayers;   // a player in a host's lobby
            else if (hostGame != null && relay != null)
            {
                if (list == "") list = hostName;
                int connecting = relay.Count - Math.Max(0, known - 1);
                if (connecting > 0) list += F(" (+{0} en connexion)", " (+{0} connecting)", connecting);
            }
            try
            {
                var ms = new Dictionary<string, string>
                {
                    ["phase"] = menuPhase,
                    ["text"] = menuText,
                    ["name"] = menuGame.Name,
                    ["addr"] = st.TryGetValue("addr", out var a) ? a : "",
                    ["players"] = list,
                    ["load"] = menuLoad,
                    ["loadSeq"] = menuLoadSeq,
                    ["lobby"] = lobbyOpen ? "host" : (menuPhase == "lobby" ? "client" : ""),
                    ["lobbySave"] = lobbyOpen ? lobbySave : "",
                    ["hostMods"] = lobbyOpen ? Mods.Compare(lobbyMods, true).View : (modCheck?.View ?? ""),
                    ["publicAddr"] = lobbyOpen ? (lobbyPublic == "" ? "..." : lobbyPublic) : "",
                    ["localAddr"] = lobbyOpen ? lobbyLocal : "",
                    ["port"] = lobbyOpen ? lobbyPort.ToString(CultureInfo.InvariantCulture) : "",
                    ["invite"] = steamConnect != null ? "1" : "",
                    ["lang"] = L.Code,
                    ["colors"] = lobbyOpen ? LobbyColors() : lobbyColors,
                    ["cmode"] = lobbyOpen ? companyMode : lobbyMode,
                    ["saveSeparate"] = lobbyOpen && lobbySaveSeparate && companyMode != "separate" ? "1" : "",
                    ["bankrupt"] = lobbyOpen ? BankruptMonths() : "",
                    ["ai"] = lobbyOpen ? (companyMode == "separate" ? LobbyAiView() : "") : lobbyAiText,
                    ["rules"] = lobbyOpen ? (companyMode == "separate" ? LobbyRulesView() : "") : lobbyRulesText,
                    // (0.6) the game options of the lobby, in both company modes (mpfever_menu.lua's "Game settings")
                    ["opts"] = lobbyOpen ? GameOptions() : lobbyOptsText,
                    ["myMods"] = SafeMineView(),
                    ["autoMods"] = st.TryGetValue("automods", out var am) && am == "0" ? "0" : "1",
                    ["modAsk"] = lobbyOpen ? ModAskView() : "",
                    ["modSend"] = lobbyOpen ? modSendText : "",
                    // (0.6.9) players whose DLCs are not the host's (the host's lobby), or this player's own difference
                    ["dlcWarn"] = (lobbyOpen || hostGame != null) ? HostDlcWarn() : PlayerDlcWarn(),
                    // (0.7.0, a player) the host's DLCs and this PC's, for the list of the lobby and of the join review
                    ["dlcList"] = (lobbyOpen || hostGame != null) ? "" : dlcListView,
                    ["modOffer"] = lobbyOpen ? "" : modOffer,
                    ["modAskState"] = lobbyOpen ? "" : modAskState,
                    ["modRecv"] = lobbyOpen ? "" : modRecvText,
                    ["hostSave"] = lobbyOpen || hostSaveState == "" ? "" : hostSaveState + "|" + hostSaveName + "|" + (hostSaveSize / 1048576.0).ToString("0", CultureInfo.InvariantCulture),
                    // the public server list (ServerList.cs): its tab shows only when a list is known
                    ["serversOn"] = ServerMode || ServerListUrl() == "" ? "" : "1",
                    ["servers"] = serverListView,
                    ["version"] = Version,
                };
                // (0.6) the public games: the list's state, the arrivals waiting for the host, the ban list (PublicGames.cs)
                try { PublicMenuState(ms); } catch (Exception e) { Log.W("public game: " + e.Message); }
                menuGame.WriteMenuState(ms);
            }
            catch (Exception e) { Log.W("menu_state: " + e.Message); }
        }

        /// <summary>(the host) The players' missing mods no Mod Hub has, for the menu: "player|ids|MB" entries.</summary>
        string ModAskView()
        {
            lock (modAsks)
                return string.Join(";;", modAsks.Select(kv => BaseName(kv.Key) + "|" + kv.Value + "|"
                    + kv.Value.Split(',').Sum(x => double.TryParse(Mods.SizeMb(x), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0).ToString("0.0", CultureInfo.InvariantCulture)));
        }

        /// <summary>(the host) Each mod's folder, zipped, to one player in parts (as the savegame goes).</summary>
        void SendMods(Peer peer, List<string> ids)
        {
            int sent = 0;
            foreach (var id in ids)
            {
                var dir = Mods.Dir(id);
                if (dir == null) continue;
                string tmp = Path.Combine(Path.GetTempPath(), "mpfever-mod-" + Guid.NewGuid().ToString("N") + ".zip");
                try
                {
                    ZipFile.CreateFromDirectory(dir, tmp, CompressionLevel.Optimal, false);
                    var bytes = File.ReadAllBytes(tmp);
                    int parts = (bytes.Length + ResyncChunk - 1) / ResyncChunk;
                    for (int i = 0; i < parts; i++)
                    {
                        int len = Math.Min(ResyncChunk, bytes.Length - i * ResyncChunk);
                        relay?.Send(peer, Msg.Make("modfile", hostName, "{[\"id\"]=" + LuaLit.Quote(id) + ",[\"i\"]=" + i + ",[\"n\"]=" + parts
                            + ",[\"data\"]=\"" + Convert.ToBase64String(bytes, i * ResyncChunk, len) + "\"}"));
                    }
                    sent++;
                    modSendText = F("Mods envoyés à {0} : {1} sur {2}", "Mods sent to {0}: {1} of {2}", BaseName(peer.Name), sent, ids.Count);
                    Log.W(F("Mod {0} envoyé à {1} ({2:0.0} Mo)", "Mod {0} sent to {1} ({2:0.0} MB)", id, BaseName(peer.Name), bytes.Length / 1048576.0));
                    MenuStatus();
                }
                catch (Exception e) { Log.Warn(F("Mod {0} : envoi impossible ({1})", "Mod {0}: cannot be sent ({1})", id, e.Message)); }
                finally { try { File.Delete(tmp); } catch { } }
            }
        }

        /// <summary>(a player) A mod the host sends, in parts: once complete, unpacked into this player's own mods (never over a
        /// mod already there, never outside its folder).</summary>
        void OnModFile(Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null) return;
            string id = t.TryGetValue("id", out var iv) && iv is string ids ? ids : "";
            if (!(t.TryGetValue("i", out var io) && io is double di) || !(t.TryGetValue("n", out var no) && no is double dn)) return;
            int i = (int)di, n = (int)dn;
            // (only a mod this player was offered and took, with a plain folder name)
            if (id == "" || n < 1 || n > 20000 || i < 0 || i >= n || !System.Text.RegularExpressions.Regex.IsMatch(id, "^[A-Za-z0-9_.-]+$") || id.Contains("..")) return;
            string[] got;
            lock (modParts)
            {
                // (a mod is code: one the player did not take is never installed, whoever sends it)
                if (!modTaken.Contains(id))
                {
                    if (i == 0) Log.Warn(F("Mod {0} reçu sans avoir été accepté : ignoré.", "Mod {0} received without being accepted: ignored.", id));
                    return;
                }
                if (!modParts.TryGetValue(id, out got) || got.Length != n) modParts[id] = got = new string[n];
                got[i] = t["data"] as string;
                if (got.Any(x => x == null)) { modRecvText = F("Réception du mod {0} : {1} %", "Receiving the mod {0}: {1} %", id, 100 * got.Count(x => x != null) / n); MenuStatus(); return; }
                modParts.Remove(id);
                modTaken.Remove(id);
            }
            try
            {
                var save = GameInstall.SaveDirs().FirstOrDefault(Directory.Exists);
                if (save == null) throw new Exception(T("dossier des mods introuvable", "mods folder not found"));
                var root = Path.Combine(Path.GetDirectoryName(save), "mods");
                var target = Path.GetFullPath(Path.Combine(root, id));
                if (Directory.Exists(target) || Mods.Dir(id) != null) { modRecvText = F("Le mod {0} est déjà installé : non remplacé.", "The mod {0} is already installed: not replaced.", id); MenuStatus(); return; }
                var bytes = got.SelectMany(Convert.FromBase64String).ToArray();
                using (var z = new ZipArchive(new MemoryStream(bytes), ZipArchiveMode.Read))
                {
                    foreach (var e in z.Entries)
                    {
                        var dest = Path.GetFullPath(Path.Combine(target, e.FullName));
                        if (!dest.StartsWith(target + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new Exception("bad path " + e.FullName);
                        if (e.FullName.EndsWith("/") || e.FullName.EndsWith("\\")) { Directory.CreateDirectory(dest); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        e.ExtractToFile(dest, false);
                    }
                }
                Mods.Rescan();
                modRecvText = F("Mod {0} reçu de l'hôte et installé. S'il reste « manquant », redémarrez le jeu.", "Mod {0} received from the host and installed. If it stays « missing », restart the game.", id);
                Log.Ok(F("Mod {0} reçu de l'hôte : installé dans {1}", "Mod {0} received from the host: installed in {1}", id, target));
                var hm = lobbyMods; lobbyMods = ""; modCheck = null; lastHostDlcs = null; dlcWarn = ""; dlcsDiffer = false; lastHostBuild = null; buildWarn = "";
                SetHostMods(hm, clients.FirstOrDefault(), menuGame?.Name ?? "");
            }
            catch (Exception e) { modRecvText = F("Mod {0} : installation impossible ({1})", "Mod {0}: cannot be installed ({1})", id, e.Message); Log.Warn(modRecvText); }
            MenuStatus();
        }

        string mineView = ""; DateTime mineAt = DateTime.MinValue;
        /// <summary>This player's personal mods for the menu (scanned at most every 20 s: the menu state is written often).</summary>
        string SafeMineView()
        {
            if ((DateTime.UtcNow - mineAt).TotalSeconds < 20) return mineView;
            mineAt = DateTime.UtcNow;
            try { mineView = Mods.MineView(); } catch (Exception e) { Log.W("personal mods: " + e.Message); }
            return mineView;
        }

        static string LocalAddresses()
        {
            try
            {
                return string.Join(", ", System.Net.Dns.GetHostAddresses(System.Net.Dns.GetHostName())
                    .Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !System.Net.IPAddress.IsLoopback(a))
                    .Select(a => a.ToString()));
            }
            catch { return "?"; }
        }

        void MenuLoop()
        {
            while (true)
            {
                Thread.Sleep(300);
                try
                {
                    CheckSteamJoin();
                    CheckMissingMods();
                    var req = menuGame.ReadMenuRequest();
                    if (req != null && req[0] != lastMenuReq)
                    {
                        bool first = lastMenuReq == null && File.GetLastWriteTimeUtc(Path.Combine(menuGame.Dir, "menu_req.txt")) < DateTime.UtcNow.AddSeconds(-30);
                        lastMenuReq = req[0];
                        if (!first) OnMenuRequest(req[1], req[2], req[3], req.Length > 4 ? req[4] : "");
                    }
                    if (joinPending && started && !resyncing)
                    {
                        joinPending = false;
                        resyncing = true;
                        new Thread(() => Resync(T("nouveau joueur", "new player"))) { IsBackground = true, Name = "Resync" }.Start();
                    }
                }
                catch (Exception e) { Log.W("menu: " + e.Message); }
            }
        }

        void OnMenuRequest(string cmd, string arg, string name, string option = "")
        {
            // (the « Servers » tab opened or its refresh button: the public list read again now, see ServerListFetchLoop)
            if (cmd == "servers") { serverListWanted = true; return; }
            name = new string((name ?? "").Trim().Where(c => char.IsLetterOrDigit(c) || c == '_' || c == '-').ToArray());
            if (name == "") name = new string(Environment.UserName.Where(char.IsLetterOrDigit).ToArray());
            if (name == "") name = "Player";
            Log.Dim(F("Menu : {0} {1} ({2})", "Menu: {0} {1} ({2})", cmd, arg, name));
            ReadGameSaveDirs();
            // a dedicated server's game: nobody hosts or joins from its menu (the console drives the server)
            if (server != null) { ServerMenuRequest(cmd); return; }
            // (0.6) the public games: the game's name, the host's answer to an arrival, kick, ban (PublicGames.cs)
            if (PublicMenuRequest(cmd, arg)) return;
            // the name typed in the MPFever window is kept for next time and shown in the launcher window (the other
            // requests do not send one)
            if (cmd == "host" || cmd == "join")
            {
                SaveSetting("name", name);
                try { BeginInvoke((Action)(() => nameBox.Text = name)); } catch { }
            }
            if (cmd == "host")
            {
                if (hostGame != null || clients.Count > 0) return;
                // the host's choice: everybody plays one company ("shared") or each player has its own ("separate")
                if (Environment.GetEnvironmentVariable("MPFEVER_COMPANIES") == null) companyMode = option == "separate" ? "separate" : "shared";
                Log.W(F("Mode des entreprises : {0}", "Company mode: {0}", companyMode));
                menuGame.SetIdentity(name, "host");
                // (the host plays its own savegame's mods: no plan left from a game this player joined before)
                try { File.Delete(Path.Combine(menuGame.Dir, "load_mods.txt")); } catch { }
                int port = (int)portBox.Value;
                try { StartHost(name, false, menuGame); }
                catch (Exception e) { menuPhase = "error"; menuText = T("Impossible d'héberger : ", "Cannot host: ") + e.Message; MenuStatus(); return; }
                // the lobby opens: the savegame is loaded once the host starts the game (see StartLobbyGame), by every game at once
                // (0.6: a new lobby for the savegame's game options, see ApplySaveOpts)
                int optsGen;
                lock (saveOptsLock) { optsGen = ++lobbyGen; lobbyOptsAtOpen = GameOptions(); }
                lobbySave = arg; lobbyOpen = true; lobbyStarting = false; lobbySaveSeparate = false;
                // (one company per player: the savegame's computer companies, in the lobby from the start; its rules and its game
                // options from the same reading)
                lock (lobbyAi) lobbyAi.Clear();
                if (companyMode == "separate") LoadLobbyAi(arg, optsGen);
                bool optsHere = companyMode != "separate";
                // its fingerprint, for the players who already have it (copied by hand before joining: nothing to send them)
                lobbySaveSha = ""; lobbySaveSize = 0;
                lock (saveHave) saveHave.Clear();
                string fpSave = arg;
                new Thread(() =>
                {
                    try
                    {
                        var f = GameInstall.FindSave(fpSave);
                        if (f == null) return;
                        var sha = Sha256File(f);
                        if (lobbySave != fpSave) return;
                        lobbySaveSize = new FileInfo(f).Length; lobbySaveSha = sha;
                        BroadcastLobby();
                        // (0.6: the game options the savegame was played with; one company per player: read with its computer
                        // companies, see LoadLobbyAi. MPFEVER_SAVEOPTS=0: never, the savegame is not decompressed here, as in 0.5.14)
                        // (0.6.8, #115: the same reading tells a savegame played with one company per player, hosted here with
                        // one company for everybody: the host is told, in the log and in the lobby. MPFEVER_SAVEMODE=0: not told)
                        bool modeCheck = Environment.GetEnvironmentVariable("MPFEVER_SAVEMODE") != "0";
                        if (optsHere && (!SaveOptsOff || modeCheck))
                            try
                            {
                                var mk = SaveInfo.Read(f, false);
                                if (!SaveOptsOff) ApplySaveOpts(optsGen, mk?.Opts);
                                if (modeCheck && mk != null && mk.Separate && lobbySave == fpSave)
                                {
                                    lobbySaveSeparate = true;
                                    Log.Warn(F("Cette sauvegarde a été jouée avec une entreprise par joueur : en « une entreprise pour tous », les entreprises des autres joueurs ne servent pas. Choisissez « Une entreprise par joueur » avant la sauvegarde pour les retrouver.",
                                        "This savegame was played with one company per player: with one company for everybody, the other players' companies are not used. Choose \"One company per player\" before the savegame to get them back."));
                                    MenuStatus();
                                }
                            }
                            catch (Exception e) { Log.W("savegame options: " + e.Message); }
                    }
                    catch (Exception e) { Log.W("savegame fingerprint: " + e.Message); }
                }) { IsBackground = true, Name = "Savegame fingerprint" }.Start();
                var t0 = DateTime.UtcNow;
                lobbyMods = Mods.Describe(ReadHostMods());
                LogModVerdicts(lobbyMods, (DateTime.UtcNow - t0).TotalSeconds);
                lobbyPort = port; lobbyPublic = "";
                lobbyLocal = string.Join(", ", LocalAddresses().Split(',').Select(a => a.Trim()).Where(a => a != "" && a != "?").Select(a => a + ":" + port));
                // Steam: friends can join from their friends list or an invitation
                new Thread(() =>
                {
                    // the public IPv4 and, when this PC has one, its IPv6 (behind DS-Lite only the IPv6 reaches it)
                    var v6 = LoadSettings().TryGetValue("ipv6", out var i6) && i6.Trim() == "0" ? new List<string>() : NetAddr.PublicIPv6List();
                    var pub = PublicAddress();
                    // (PublicAddress falls back to a local address when the lookup fails or is turned off)
                    bool known = !LocalAddresses().Split(',').Select(a => a.Trim()).Contains(pub);
                    var shown = new List<string>();
                    if (known) shown.Add(pub + ":" + port);
                    shown.AddRange(v6.Select(a => NetAddr.Show(a, port)));
                    lobbyPublic = shown.Count > 0 ? string.Join(", ", shown) : "?";
                    // (through Steam first: no port to open; the host's Steam id is known once its game's module is ready)
                    for (int w = 0; w < 40 && hostSteamId == null && SteamNet.Enabled; w++) Thread.Sleep(250);
                    var viaSteam = hostSteamId != null ? "steam:" + hostSteamId + "," : "";
                    steamConnect = "+mpfever_connect " + viaSteam + pub + ":" + port + string.Concat(v6.Select(a => "," + NetAddr.Show(a, port)));
                    SteamCtl("presence", steamConnect);
                    Log.Ok(T("Steam : invitations possibles (", "Steam: invitations enabled (") + steamConnect + ")");
                    MenuStatus();
                }) { IsBackground = true, Name = "Steam presence" }.Start();
                menuPhase = "lobby";
                // (the addresses to give: on the page, from publicAddr / localAddr)
                menuText = F("Salon ouvert (« {0} »). Lancez la partie quand tout le monde est là.", "Lobby open (« {0} »). Start the game when everybody is here.", arg);
                MenuStatus();
            }
            else if (cmd == "start")
            {
                if (!lobbyOpen || hostGame == null) return;
                // (0.7.0) players of other DLCs: the lobby shows the warning and the advice, the start goes on (the user's choice,
                // 2026-11-05: no second press); said once more in the log
                var dw = HostDlcWarn();
                if (dw != "") Log.Warn(T("Lancement avec des DLC différents : ", "Starting with different DLCs: ") + dw);
                new Thread(StartLobbyGame) { IsBackground = true, Name = "Lobby start" }.Start();
            }
            else if (cmd == "join")
            {
                if (hostGame != null) return;
                string host = arg.Trim();   // one address or several (IPv4 and IPv6), each with or without its port
                if (clients.Count > 0 || menuGame.InGame)
                {
                    // the same host asked twice (at startup, the command line and a Steam invitation)
                    if (clients.Count > 0 && !menuGame.InGame && host == joinedAddr) return;
                    // this window only shows in the main menu: what is left of an earlier session is stale (a game sent
                    // by the host would go to the in-game scripts, which do not run here, issue #13)
                    EndSession(T("=== Nouvelle connexion : fin de la session précédente ===", "=== New connection: the previous session ends ==="));
                }
                joinedAddr = host;
                // ((0.7.13) an address without its port: 28090, not port= of this player's own lobby; the old card's field with it)
                int port = JoinPort(ConnCardOn, (int)portBox.Value);
                SaveSetting("addr", arg.Trim());
                menuGame.SetIdentity(name, "client");
                menuPhase = "connecting"; menuText = F("Connexion à {0}...", "Connecting to {0}...", NetAddr.First(host, port)); MenuStatus();
                // (option: the password of a dedicated server, typed in the MPFever window)
                try { StartClient(name, host, port, false, menuGame, string.IsNullOrEmpty(option) ? null : option); }
                catch (Exception e)
                {
                    clients.Clear();
                    games.Remove(menuGame); games.Add(menuGame);
                    menuPhase = "error"; menuText = F("Connexion impossible à {0} : ", "Cannot connect to {0}: ", NetAddr.First(host, port)) + e.Message; MenuStatus();
                    // (0.6.7: in the log too, the reports had only the menu's word for it)
                    Log.Err(menuText);
                    return;
                }
                // (a host that refused this player already said why)
                // (0.7.0: unless the welcome came first and asks the player to look at the game's mods and DLCs)
                if (!clientCancelled && menuPhase != "review") { menuPhase = "connected"; menuText = T("Connecté. L'hôte prépare sa partie...", "Connected. The host is preparing its game..."); MenuStatus(); }
            }
            else if (cmd == "color")
            {
                // the colour of the player's company, picked in the lobby: the host keeps it (when nobody else has it) and tells
                // the lobby; a player who joins asks the host
                if (!int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out int ix) || ix < 1 || ix > 12) return;
                if (lobbyOpen && hostName != null) { SetLobbyColor(BaseName(hostName), ix); }
                else foreach (var cl in clients.ToList()) { try { cl.Send(Msg.Make("lobbycolor", name, "{[\"ix\"]=" + ix + "}")); } catch { } }
            }
            else if (cmd == "startmoney" || cmd == "share")
            {
                // (0.5.14, the host, in the lobby or in its game's MPFever window) the start money of a new company, the sharing rules
                // between companies on or off: every game takes them with the session, the host's game puts them into the game (and
                // its savegame, see mpfever_eco.lua's co_rules)
                if (cmd == "startmoney")
                {
                    if (!long.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out long mo) || mo < 0 || mo > 10000000000L) return;
                    SaveSetting("companystart", mo.ToString(CultureInfo.InvariantCulture));
                    Log.W(F("Argent de départ d'une nouvelle entreprise : {0:N0}", "Start money of a new company: {0:N0}", mo));
                }
                else
                {
                    if (arg != "0" && arg != "1") return;
                    SaveSetting("share", arg);
                    Log.W(arg == "1" ? T("Règles de partage entre entreprises : activées", "Sharing rules between companies: on")
                        : T("Règles de partage entre entreprises : désactivées (tout est ouvert et gratuit)", "Sharing rules between companies: off (everything open and free)"));
                }
                if (relay != null) BroadcastSession();
                BroadcastLobby();
                MenuStatus();
            }
            else if (cmd == "opt")
            {
                // (0.6, the host, in its lobby's "Game settings" or in its game's MPFever window) a game option on or off ("id=1",
                // "id=0") or one of its parameters ("id.param=value"): every game takes them with the session, the host's game puts
                // them into the game (f_opts, kept in its savegame); kept for the host's next lobby. A player's MPFever.exe hosts
                // nothing: its request is not taken. (A dedicated server's come from mpfever_server.properties.)
                if (!lobbyOpen && hostGame == null) return;
                if (server != null) { Log.W(T("Options de partie : celles de mpfever_server.properties (game-options)", "Game options: those of mpfever_server.properties (game-options)")); return; }
                var now = GameOptions();
                var next = GameOpts.Apply(now, arg, out string why);
                if (next == null) { Log.W(F("Option de partie refusée ({0}) : {1}", "Game option refused ({0}): {1}", why, arg)); return; }
                if (next == now) return;
                SaveSetting("gameopts", next);
                Log.W(F("Options de partie choisies par l'hôte : {0}", "Game options chosen by the host: {0}", next == "" ? T("aucune", "none") : next));
                if (relay != null) BroadcastSession();
                BroadcastLobby();
                MenuStatus();
            }
            else if (cmd == "aiadd" || cmd == "aidel" || cmd == "aicolor" || cmd == "ailevel" || cmd == "aimoney")
            {
                // (the host, one company per player) the lobby's computer companies
                LobbyAiRequest(cmd.Substring(2), arg);
            }
            else if (cmd == "bankrupt")
            {
                // (the host, in the lobby or in its game's MPFever page) months in debt before a bankruptcy: every game takes it
                // with the session (the host's game puts it into the game, see mpfever_eco.lua)
                if (!int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out int mo) || !(mo == 0 || mo == 3 || mo == 6 || mo == 12 || mo == 24)) return;
                SaveSetting("bankrupt", mo.ToString(CultureInfo.InvariantCulture));
                Log.W(mo == 0 ? T("Faillite : jamais", "Bankruptcy: never") : F("Faillite après {0} mois de dette", "Bankruptcy after {0} months in debt", mo));
                if (relay != null) BroadcastSession();
                // (the players' lobbies show the rules too: their summary kept the old months)
                BroadcastLobby();
                MenuStatus();
            }
            else if (cmd == "auction")
            {
                // (0.7.4, the host, in the lobby or in its game's MPFever page) the auction of a bankrupt company: every game takes it
                // with the session (the host's game puts it into the game, see mpfever_eco.lua's co_rules)
                if (!ValidAuction(arg)) return;
                SaveSetting("auction", arg);
                Log.W(F("Enchères d'une faillite : {0}", "Auction of a bankruptcy: {0}", arg));
                if (relay != null) BroadcastSession();
                BroadcastLobby();
                MenuStatus();
            }
            else if (cmd == "invite")
            {
                if (steamConnect != null) SteamCtl("invite", steamConnect);
            }
            else if (cmd == "resync")
            {
                // (the host, from its game's MPFever window) every game reloads the host's game now. Only while a session runs
                // with other players, no resynchronisation is under way and the cooldown is over (the window shows how long is
                // left: resyncin= in mp_status.txt), so that a host cannot start reload after reload.
                // MPFEVER_RESYNCBUTTON=0: refused, as before (there was no such request)
                string why = null;
                int others; lock (players) others = players.Count(p => p != hostName);
                double left = ResyncCooldownSeconds - (Now - lastResync);
                if (Environment.GetEnvironmentVariable("MPFEVER_RESYNCBUTTON") == "0") why = "MPFEVER_RESYNCBUTTON=0";
                else if (hostGame == null || !started) why = T("pas de session en cours", "no session running");
                else if (resyncing) why = T("une resynchronisation est déjà en cours", "a resynchronisation is already under way");
                else if (others == 0) why = T("aucun autre joueur", "no other player");
                else if (left > 0) why = F("encore {0:0} s d'attente", "{0:0} s to wait", left);
                if (why != null)
                {
                    Log.W(F("Resynchronisation demandée par l'hôte : impossible pour l'instant ({0}).", "Resynchronisation asked by the host: not possible now ({0}).", why));
                    return;
                }
                resyncing = true;
                new Thread(() => Resync(T("demandée par l'hôte", "asked by the host"))) { IsBackground = true, Name = "Resync" }.Start();
            }
            else if (cmd == "sendmods")
            {
                // (the host) "sendmods <player>" with option 1: offer the player its missing mods; 0: say no
                string who;
                lock (modAsks) who = modAsks.Keys.FirstOrDefault(k => k == arg) ?? modAsks.Keys.FirstOrDefault(k => BaseName(k) == arg);
                if (who == null) return;
                string ids; lock (modAsks) { ids = modAsks[who]; modAsks.Remove(who); modAskDone[who] = option == "1" ? "offered:" + ids : "refused"; }
                var peer = relay?.Find(who);
                if (peer == null) return;
                if (option == "1")
                {
                    double mb = ids.Split(',').Sum(x => double.TryParse(Mods.SizeMb(x), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0);
                    relay.Send(peer, Msg.Make("modoffer", hostName, "{[\"ids\"]=" + LuaLit.Quote(ids) + ",[\"mb\"]=" + mb.ToString("0.0", CultureInfo.InvariantCulture) + "}"));
                    modSendText = F("Mods proposés à {0} : il doit accepter.", "Mods offered to {0}: they must accept.", BaseName(who));
                }
                else
                {
                    relay.Send(peer, Msg.Make("modoffer", hostName, "{[\"no\"]=true}"));
                    modSendText = "";
                }
                MenuStatus();
            }
            else if (cmd == "takemods")
            {
                // (a player) "takemods" with option 1: take the host's offer; 0: refuse it
                bool yes = option == "1";
                lock (modParts)
                {
                    modTaken.Clear();
                    if (yes) foreach (var x in modOffer.Split('|')[0].Split(',')) if (x.Trim() != "") modTaken.Add(x.Trim());
                }
                foreach (var cl in clients.ToList()) { try { cl.Send(Msg.Make("modaccept", name, "{[\"yes\"]=" + (yes ? "true" : "false") + "}")); } catch { } }
                modRecvText = yes ? T("Réception des mods de l'hôte...", "Receiving the host's mods...") : "";
                if (!yes) modAskState = "refused";
                modOffer = "";
                MenuStatus();
            }
            else if (cmd == "modoldcopy")
            {
                // (0.8.1, MODOLDCOPY) "modoldcopy <id>": this player's copy of the mod in local\mods, which the game takes in place of
                // the Mod Hub's, moved out of the game's reach (see Mods.MoveLocalCopy); the game must be started again
                var id = (arg ?? "").Trim();
                if (id == "" || Environment.GetEnvironmentVariable("MPFEVER_MODOLDCOPY") == "0") return;
                try
                {
                    var to = Mods.MoveLocalCopy(id);
                    Log.Ok(F("Ancienne copie du mod {0} déplacée dans {1}. Fermez le jeu et relancez-le par MPFever : il garde la copie trouvée à son démarrage.",
                        "Old copy of the mod {0} moved to {1}. Close the game and start it again through MPFever: it keeps the copy it found when it started.", id, to));
                }
                catch (Exception e)
                {
                    Log.Err(F("Copie du mod {0} impossible à déplacer ({1}) : fermez le jeu et déplacez-la vous-même hors du dossier mods.",
                        "Could not move the copy of the mod {0} ({1}): close the game and move it out of the mods folder yourself.", id, e.Message));
                }
                if (!lobbyOpen && lobbyMods != "")
                {
                    var hm = lobbyMods; lobbyMods = ""; modCheck = null; lastHostDlcs = null; dlcWarn = ""; dlcsDiffer = false; lastHostBuild = null; buildWarn = "";
                    SetHostMods(hm, clients.FirstOrDefault(), name);
                }
                MenuStatus();
            }
            else if (cmd == "modpersonal" || cmd == "modmine")
            {
                // personal mods (see Mods): "modpersonal <id> 1|0" takes a mod for personal by hand (or no longer), "modmine
                // <id> 1|0" turns one of this player's personal mods on or off
                var parts = (arg ?? "").Split(' ');
                if (parts.Length < 2 || parts[0].Trim() == "") return;
                string id = parts[0].Trim();
                bool on = parts[1].Trim() == "1";
                if (cmd == "modpersonal") { if (on) Mods.Forced.Add(id); else Mods.Forced.Remove(id); }
                else if (on) { Mods.Off.Remove(id); }
                else { Mods.Off.Add(id); Mods.Forced.Remove(id); }
                SavePersonalMods();
                mineAt = DateTime.MinValue;
                Log.W(F("Mod {0} : {1}", "Mod {0}: {1}", id, cmd == "modpersonal" ? (on ? T("pris pour personnel (il peut désynchroniser la partie)", "taken for personal (it may desynchronise the game)") : T("de nouveau partagé", "shared again"))
                    : (on ? T("mod personnel activé", "personal mod on") : T("mod personnel désactivé", "personal mod off"))));
                // (0.7.11, #151: tsuhr took 9 of the host's mods for personal, vehicle and aircraft packs among them; the game loaded
                // the host's game without them and stopped right after, on a model it could not find, a game bug the missing models
                // trigger) a mod of objects the host's game uses, taken for personal: said plainly. MPFEVER_PERSONALWARN=0: not said
                if (cmd == "modpersonal" && on && Environment.GetEnvironmentVariable("MPFEVER_PERSONALWARN") != "0")
                {
                    var me = Mods.Parse(lobbyMods).FirstOrDefault(x => string.Equals(x.Id, id, StringComparison.OrdinalIgnoreCase));
                    if (me != null && me.Kind == Mods.Assets)
                        Log.Warn(F("{0} ajoute des véhicules, bâtiments ou objets que la partie de l'hôte utilise : sans lui, ils manquent sur ce PC et le jeu peut planter en chargeant la partie de l'hôte. Installez-le plutôt que de le prendre pour personnel.",
                            "{0} adds vehicles, buildings or objects the host's game uses: without it they are missing on this PC and the game may crash while it loads the host's game. Install it rather than take it for personal.", me.Name));
                }
                if (lobbyOpen)
                {
                    // the host's own: its list as the players see it changes
                    lobbyMods = Mods.Describe(ReadHostMods());
                    BroadcastLobby();
                }
                else if (lobbyMods != "")
                {
                    var hm = lobbyMods; lobbyMods = ""; modCheck = null; lastHostDlcs = null; dlcWarn = ""; dlcsDiffer = false; lastHostBuild = null; buildWarn = "";
                    SetHostMods(hm, clients.FirstOrDefault(), name);
                }
                MenuStatus();
            }
            else if (cmd == "report")
            {
                // "Report a problem" in the in-game MPFever window
                // (0.6.8) one report at a time: a click while one is being made (some 20 s) makes no other zip.
                // MPFEVER_REPORTBUSY=0: a report per click, as before
                if (System.Threading.Interlocked.CompareExchange(ref reportBusy, 1, 0) != 0 && Environment.GetEnvironmentVariable("MPFEVER_REPORTBUSY") != "0")
                    Log.W(F("Rapport déjà en cours de création : demande ignorée.", "A report is already being made: request ignored."));
                else
                    new Thread(() => { try { Report(false); } finally { System.Threading.Interlocked.Exchange(ref reportBusy, 0); } }) { IsBackground = true, Name = "Report" }.Start();
            }
            else if (cmd == "discord")
            {
                // "Discord" in the in-game MPFever window
                try { Process.Start(ThanksDialog.DiscordUrl); }
                catch (Exception ex) { Log.W(ex.Message); }
            }
            else if (cmd == "dropnet")
            {
                // test only: cuts the connection to the host as a network failure would
                foreach (var cl in clients.ToList()) cl.Dispose();
            }
            else if (cmd == "menu")
            {
                // the game's main menu shows: a session whose game was running is over (not while a host game is loaded, which
                // may pass through the menu)
                if (menuGame.InGame && !resyncing && Now - lastLoadOrder > 120) EndSession();
                else Log.W(F("Menu principal affiché (session conservée : en jeu {0}, resynchronisation {1})", "Main menu shown (session kept: in game {0}, resynchronisation {1})", menuGame.InGame, resyncing));
            }
            else if (cmd == "opensaves")
            {
                // (a player) the folder where to put the host's savegame copied by hand
                var dir = GameInstall.SaveDirs().FirstOrDefault();
                if (dir != null) try { Process.Start("explorer.exe", "\"" + dir + "\""); } catch (Exception e) { Log.W("open: " + e.Message); }
            }
            else if (cmd == "recheck")
            {
                // (a player) the savegame was copied: look again
                var cl = clients.FirstOrDefault();
                if (hostSaveSha != "") CheckHostSave(hostSaveSha, hostSaveSize, hostSaveName, cl, menuGame?.Name ?? name, true);
            }
            else if (cmd == "leave")
            {
                // the player went back to the game's main menu: the session ends here (not during a resynchronisation)
                if (resyncing) { Log.Warn(T("Retour au menu pendant une resynchronisation : session conservée.", "Back to the menu during a resynchronisation: session kept.")); return; }
                EndSession();
            }
            else if (cmd == "joinready")
            {
                // (0.7.0) « Join the game » of the join review: the host sends its game now
                var go = reviewSend;
                if (go == null) return;
                Log.W(T("Vous rejoignez la partie : l'hôte envoie sa partie.", "You join the game: the host sends its game."));
                menuPhase = "connected"; menuText = T("Vous rejoignez la partie : l'hôte envoie sa partie...", "You join the game: the host sends its game...");
                go();
                MenuStatus();
            }
            else if (cmd == "dlcstore")
            {
                // (0.7.0) a DLC's Steam store page (only the pages MPFever knows, from the DLC's id, see Mods.DlcStoreUrl)
                var url = Mods.DlcStoreUrl(arg ?? "");
                Log.W(F("Page Steam du DLC {0} : {1}", "Steam page of the DLC {0}: {1}", Mods.DlcName(arg ?? ""), url));
                try { Process.Start(url); }
                catch (Exception e) { try { Process.Start(url.Replace("steam://store/", "https://store.steampowered.com/app/")); } catch { Log.W(e.Message); } }
            }
            else if (cmd == "cancel")
            {
                // the whole session state goes: a stale "in game" flag sent the next host game to the in-game scripts,
                // which do not run in the main menu (issue #13)
                if (resyncing) { Log.Warn(T("Annulation pendant une resynchronisation : session conservée.", "Cancel during a resynchronisation: session kept.")); return; }
                // (the players in the host's lobby are told, so that they do not try to reconnect)
                if (lobbyOpen && relay != null) { relay.Broadcast(Msg.Make("lobby", hostName, "{[\"closed\"]=true}")); Thread.Sleep(300); }
                EndSession(T("=== Annulé : fin de la session ===", "=== Cancelled: the session ends ==="));
            }
        }

        /// <summary>The game closed (or crashed): this MPFever leaves its session at once, the session's files kept for a report.
        /// Kept, a player's MPFever went on reconnecting to the host with no game behind it; the player started MPFever again, and
        /// the old one and the new one took each other's place every 5 s (the host closes the old connection of a name that comes
        /// back), with a resynchronisation each time. MPFEVER_EXITKEEPSESSION=1: as before.</summary>
        static bool CrashNoticeOn() => Environment.GetEnvironmentVariable("MPFEVER_CRASHNOTICE") != "0";

        /// <summary>(0.8.4, #263, the host) A player's game crashed (its MPFever said so before leaving): every other player is
        /// asked in the chat to send a report now, while their games still hold what happened; said in the host's log too.</summary>
        void OnPlayerCrashed(string who)
        {
            if (!CrashNoticeOn() || string.IsNullOrEmpty(who)) return;
            var text = F("Le jeu de {0} a planté. Pour aider à trouver pourquoi, chaque joueur peut envoyer « Signaler un problème » maintenant, avant de quitter la session.",
                "{0}'s game crashed. To help find why, every player please send « Report a problem » now, before leaving the session.", who);
            Log.Warn(text);
            HostChat("msg", "MPFever", text);
        }

        void LeaveOnGameExit()
        {
            if (ServerMode || Environment.GetEnvironmentVariable("MPFEVER_EXITKEEPSESSION") == "1") return;
            // A player whose connection had dropped has none to close, but its reconnection goes on for 5 minutes: it is stopped
            // too, like a join still connecting. Left alone, it found the host again when the host's MPFever came back (after a
            // crash of the host's game, say): the same MPFever with no game behind it, a phantom player in the host's session, and
            // the same swaps every 5 s once the player started MPFever again. A connection made while the session is being left
            // is closed instead of kept (see StartClient). MPFEVER_STALEJOIN=0: as before.
            bool stopJoin = Environment.GetEnvironmentVariable("MPFEVER_STALEJOIN") != "0";
            bool joining = stopJoin && Volatile.Read(ref clientJoins) > 0 && !clientCancelled;
            bool live = clients.Count > 0 || relay != null || joining;
            // The session is described now, before it goes: a problem report made afterwards (the crash question, the thanks
            // window's Report) told "no session" for a player, whose connection is closed here, and only the host among the
            // players for a host, whose relay is closed here. MPFEVER_EXITREPORT=0: as before.
            if (live && Environment.GetEnvironmentVariable("MPFEVER_EXITREPORT") != "0")
                leftSession = SessionLines(joining) + "; session left when the game closed";
            if (!live && !stopJoin) return;
            sessionGen++;
            clientCancelled = true;
            if (!live) return;
            Log.W(T("Le jeu est fermé : MPFever quitte la session.", "The game closed: MPFever leaves the session."));
            // (taken and emptied at once: a reconnection that adds its connection in between finds the session left, see
            // StartClient, or has its connection closed here)
            Client[] gone; lock (clients) { gone = clients.ToArray(); clients.Clear(); }
            // (0.8.4, #263) a player's game crashed: its report has its own logs only, its connection is closed here before the
            // report is made and the others' reports cannot be asked for any more (gs_as's crash: nothing of the host's game). The
            // host is told first, and asks every player in the chat to send a report now. MPFEVER_CRASHNOTICE=0: as before
            if (gone.Length > 0 && CrashNoticeOn())
                try
                {
                    if (Reporter.CrashedSince(gameStartedAt, menuGame?.Dir, menuGame?.ExitCode, menuGame != null && menuGame.OtherGameSeen))
                        foreach (var cl in gone) try { cl.Send(Msg.Make("game_crashed", reportMe ?? menuGame?.Name ?? "", "{}")); } catch { }
                }
                catch { }
            foreach (var cl in gone) try { cl.Leave(); } catch { }
            var r = relay; relay = null;
            if (r != null) { try { r.Dispose(); } catch { } PortMap.Close(); }
        }

        /// <summary>The player left the game for the main menu: connections closed, the session's state cleared, the files the
        /// game and MPFever.exe exchange emptied (the next game must not read the previous session's messages). The game
        /// keeps running: the MPFever window of its main menu can host or join again.</summary>
        void EndSession(string why = null)
        {
            Log.W(why ?? T("=== Retour au menu principal : fin de la session ===", "=== Back to the main menu: the session ends ==="));
            Log.W(T("Ce mod vous plaît ? Soutenez le projet ou remerciez son auteur sur ko-fi.com/knighthd",
                "Enjoying MPFever? Support the project or thank its author at ko-fi.com/knighthd"));
            Log.W(T("Des joueurs, de l'aide et les nouveautés : rejoignez le Discord de MPFever sur discord.gg/DfMxFUQZCR",
                "Players, help and news: join the MPFever Discord at discord.gg/DfMxFUQZCR"));
            sessionGen++;
            clientCancelled = true;
            Options.HostSession = null;
            foreach (var g in games.ToList()) { g.WriteSettings(); NativeHoldOff(g); }
            Client[] gone; lock (clients) { gone = clients.ToArray(); clients.Clear(); }
            foreach (var cl in gone) try { cl.Leave(); } catch { }
            var r = relay; relay = null;
            if (r != null) { try { r.Dispose(); } catch { } PortMap.Close(); }
            // (the host's game no longer takes Steam connections for this session)
            if (hostGame != null && hostSteamId != null) try { SteamNet.Cmd(hostGame.Dir, "unhost"); } catch { }
            hostSteamId = null;
            // (0.6) out of the public list, arrivals still waiting for the host refused (PublicGames.cs)
            PublicSessionEnd();
            if (hostGame != null && hostFromGame != null) hostGame.FromGame -= hostFromGame;
            if (menuGame != null && clientFromGame != null) menuGame.FromGame -= clientFromGame;
            hostFromGame = clientFromGame = null;
            hostGame = null;
            hostName = null;
            lock (sessionGate) { started = false; speed = 0; pauseAt = null; }
            // (0.6.7) the answers about mods belong to this session: a player refused once was never asked again, in any later one
            lock (modAsks) { modAsks.Clear(); modAskDone.Clear(); }
            lock (players) players.Clear();
            lock (clocks) clocks.Clear();
            lock (hashes) hashes.Clear();
            lock (chatLog) { chatLog.Clear(); chatId = 0; }
            lock (resyncParts) resyncParts.Clear();   // a host game half received in the session that ends
            hostSaveSha = ""; hostSaveState = ""; hostSaveLocal = null;   // (a lobby opened again is looked at again)
            hashN = 0; syncText = "—"; actsRelayed = actRefused = actFails = desyncs = 0;
            resyncing = false; resyncDropping = false; resyncSending = false; resyncWaiting.Clear(); ignoredParts.Clear(); unmeasuredParts.Clear(); postResyncHashN = -1; driftSince = -1; diffStreak = 0; lastDiffKeys = ""; stepsDumped = false; lock (partStreak) partStreak.Clear();
            joinPending = false; riskyAnnounced = "";
            lock (reviewing) reviewing.Clear();
            reviewSend = null; reviewAccepted = null;
            lock (lobbyColorOf) lobbyColorOf.Clear();
            lobbyColors = ""; lobbyMode = "";
            lock (lobbyAi) lobbyAi.Clear();
            lobbyAiText = ""; lobbyRulesText = ""; lobbyOptsText = "";
            lock (sessionDlcOff) sessionDlcOff.Clear(); lock (playerDlcs) playerDlcs.Clear();
            lobbyOpen = lobbyStarting = false; lobbySave = ""; lobbyPlayers = ""; lobbyPublic = ""; lobbyLocal = ""; lobbyMods = ""; modCheck = null; lastHostDlcs = null; dlcWarn = ""; dlcsDiffer = false; lastHostBuild = null; buildWarn = ""; lobbyModsKnown = false; dlcListView = "";
            lock (modIssues) modIssues.Clear();
            lock (dlcIssues) dlcIssues.Clear();
            joinedAddr = null;
            if (steamConnect != null) { steamConnect = null; SteamCtl("clear", null); }
            if (menuGame != null)
            {
                menuGame.InGame = false;
                foreach (var f in new[] { "in.log", "out.log", "ui.log", "sim_mods.log", "started.txt", "results.log", "native_events.log", "resync_claims.txt",
                                          "resync_pending.txt", "bindings.log", "captured.txt", "companies.txt", "shares.txt",
                                          "chat.txt", "chat_out.txt", "load_id.txt", "ai_journal.txt" })
                    try { var p = Path.Combine(menuGame.Dir, f); if (File.Exists(p)) File.WriteAllText(p, ""); } catch { }
            }
            menuPhase = "idle"; menuText = ""; menuLoad = ""; menuLoadSeq = "";
            MenuStatus();
        }

        /// <summary>The players in the host's lobby: the host first, then those connected (names without their number).</summary>
        string LobbyList()
        {
            var names = new List<string> { BaseName(hostName ?? "") };
            foreach (var n in relay?.PeerNames() ?? new string[0])
            {
                bool bad;
                lock (modIssues) bad = modIssues.ContainsKey(BaseName(n));
                bool dlc;
                lock (dlcIssues) dlc = dlcIssues.ContainsKey(BaseName(n));
                names.Add(BaseName(n) + (bad ? T(" (mods différents)", " (different mods)") : "") + (dlc ? T(" (DLC différents)", " (different DLCs)") : ""));
            }
            return string.Join(", ", names.Where(x => x != ""));
        }

        /// <summary>A player of the lobby takes a colour for its company, unless another player or a computer company has it.</summary>
        void SetLobbyColor(string who, int ix)
        {
            lock (lobbyAi) if (lobbyAi.Values.Any(a => a.Color == ix)) return;
            lock (lobbyColorOf)
            {
                foreach (var kv in lobbyColorOf) if (kv.Value == ix && kv.Key != who) return;
                lobbyColorOf[who] = ix;
            }
            BroadcastLobby();
            MenuStatus();
        }

        /// <summary>The lobby's colours, "name:index,...", for the players still there.</summary>
        string LobbyColors()
        {
            var here = new HashSet<string> { BaseName(hostName ?? "") };
            foreach (var n in relay?.PeerNames() ?? new string[0]) here.Add(BaseName(n));
            lock (lobbyColorOf) return string.Join(",", lobbyColorOf.Where(kv => here.Contains(kv.Key)).Select(kv => kv.Key + ":" + kv.Value));
        }

        /// <summary>The lobby's computer companies for the menus: "n:colour:level:money:name;..." (names without ';' and ':'; money
        /// -1: the players', 0.5.14).</summary>
        string LobbyAiView()
        {
            lock (lobbyAi) return string.Join(";", lobbyAi.Select(kv => kv.Key.ToString(CultureInfo.InvariantCulture) + ":" + kv.Value.Color.ToString(CultureInfo.InvariantCulture)
                + ":" + kv.Value.Level.ToString(CultureInfo.InvariantCulture) + ":" + kv.Value.Money.ToString(CultureInfo.InvariantCulture)
                + ":" + (kv.Value.Name ?? "").Replace(";", " ").Replace(":", " ")));
        }

        /// <summary>The computer companies the host's game runs: "n:colour:level,..." (the session's ai=), "" without any.</summary>
        string AiPayload()
        {
            if (companyMode != "separate") return "";
            lock (lobbyAi)
            {
                // (the tests, without a lobby: MPFEVER_AI="n:colour,..." stands for the host's choice)
                var env = Environment.GetEnvironmentVariable("MPFEVER_AI") ?? "";
                if (lobbyAi.Count == 0 && env.Contains(":")) return env;
                // (0.7.0) a dedicated server has no lobby: the computer companies of its settings (ai-companies, its window's list)
                if (lobbyAi.Count == 0 && server != null) return server.AiCompanies ?? "";
                // (":money", 0.5.14: only when the host chose one for it, else the players')
                return string.Join(",", lobbyAi.Select(kv => kv.Key.ToString(CultureInfo.InvariantCulture) + ":" + kv.Value.Color.ToString(CultureInfo.InvariantCulture)
                    + ":" + kv.Value.Level.ToString(CultureInfo.InvariantCulture) + (kv.Value.Money >= 0 ? ":" + kv.Value.Money.ToString(CultureInfo.InvariantCulture) : "")));
            }
        }

        /// <summary>The first palette index no player of the lobby and no other computer company has (0: none left).</summary>
        int FreeLobbyColor(int exceptAi)
        {
            var used = new HashSet<int>();
            lock (lobbyColorOf) foreach (var v in lobbyColorOf.Values) used.Add(v);
            lock (lobbyAi) foreach (var kv in lobbyAi) if (kv.Key != exceptAi) used.Add(kv.Value.Color);
            // (from the end of the palette: the players' first picks are its first colours)
            for (int i = 12; i >= 1; i--) if (!used.Contains(i)) return i;
            return 0;
        }

        /// <summary>(the host, one company per player) the lobby's computer companies: "add", "del" n, "color" "n:index", "level" "n:1-3".</summary>
        void LobbyAiRequest(string what, string arg)
        {
            if (!lobbyOpen || companyMode != "separate") return;
            if (what == "add")
            {
                int n;
                lock (lobbyAi)
                {
                    if (lobbyAi.Count >= 8) return;
                    n = 1;
                    while (lobbyAi.ContainsKey(n)) n++;
                }
                int ix = FreeLobbyColor(n);
                if (ix == 0) return;
                lock (lobbyAi) lobbyAi[n] = new LobbyAi { Color = ix };
                Log.W(F("Entreprise de l'ordinateur {0} ajoutée (couleur {1})", "Computer company {0} added (colour {1})", n, ix));
            }
            else if (what == "del")
            {
                if (!int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out int n)) return;
                lock (lobbyAi) if (!lobbyAi.Remove(n)) return;
                Log.W(F("Entreprise de l'ordinateur {0} retirée", "Computer company {0} removed", n));
            }
            else if (what == "color")
            {
                var parts = (arg ?? "").Split(':');
                if (parts.Length != 2 || !int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int n)
                    || !int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out int ix) || ix < 1 || ix > 12) return;
                lock (lobbyColorOf) if (lobbyColorOf.Values.Contains(ix)) return;
                lock (lobbyAi)
                {
                    if (!lobbyAi.TryGetValue(n, out var a) || lobbyAi.Any(kv => kv.Key != n && kv.Value.Color == ix)) return;
                    a.Color = ix;
                }
            }
            else if (what == "level")
            {
                var parts = (arg ?? "").Split(':');
                if (parts.Length != 2 || !int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int n)
                    || !int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out int lv) || lv < 1 || lv > 3) return;
                lock (lobbyAi)
                {
                    if (!lobbyAi.TryGetValue(n, out var a)) return;
                    a.Level = lv;
                }
                Log.W(F("Entreprise de l'ordinateur {0} : niveau {1}", "Computer company {0}: level {1}", n, lv));
            }
            else if (what == "money")
            {
                // (0.5.14) "n:amount": its start money, -1 = the players'
                var parts = (arg ?? "").Split(':');
                if (parts.Length != 2 || !int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int n)
                    || !long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out long mo) || mo < -1 || mo > 10000000000L) return;
                lock (lobbyAi)
                {
                    if (!lobbyAi.TryGetValue(n, out var a)) return;
                    a.Money = mo;
                }
                Log.W(mo < 0 ? F("Entreprise de l'ordinateur {0} : argent de départ des joueurs", "Computer company {0}: the players' start money", n)
                    : F("Entreprise de l'ordinateur {0} : argent de départ {1:N0}", "Computer company {0}: start money {1:N0}", n, mo));
            }
            BroadcastLobby();
            MenuStatus();
        }

        /// <summary>(the host, one company per player) the computer companies of the lobby's savegame, read from it: in the lobby from
        /// the start, with their colour (another free one when a player has it).</summary>
        void LoadLobbyAi(string save, int optsGen)
        {
            new Thread(() =>
            {
                try
                {
                    var f = GameInstall.FindSave(save);
                    if (f == null) return;
                    var t0 = DateTime.UtcNow;
                    // (0.6: its companies, its rules and its game options from one decompression; before, one each)
                    var marks = SaveInfo.Read(f, true);
                    var list = marks?.Ai ?? new List<SaveInfo.Company>();
                    // (0.5.14: the savegame's rules too, the lobby starts with them)
                    if (lobbySave != save || !lobbyOpen) return;
                    foreach (var c in list)
                    {
                        lock (lobbyAi) { if (lobbyAi.ContainsKey(c.Number)) continue; lobbyAi[c.Number] = new LobbyAi { Color = 0, Name = c.Name }; }
                        int ix = c.Color;
                        bool taken;
                        lock (lobbyColorOf) taken = lobbyColorOf.Values.Contains(ix);
                        lock (lobbyAi) taken = taken || ix < 1 || lobbyAi.Any(kv => kv.Key != c.Number && kv.Value.Color == ix);
                        if (taken) ix = FreeLobbyColor(c.Number);
                        lock (lobbyAi) lobbyAi[c.Number].Color = ix;
                    }
                    try { LoadSaveRules(save, marks?.Rules); } catch (Exception e) { Log.W("savegame rules: " + e.Message); }
                    if (!SaveOptsOff) try { ApplySaveOpts(optsGen, marks?.Opts); } catch (Exception e) { Log.W("savegame options: " + e.Message); }
                    if (list.Count > 0)
                        Log.W(F("Sauvegarde : {0} entreprise(s) de l'ordinateur reprise(s) ({1:0.0} s)", "Savegame: {0} computer company(ies) taken again ({1:0.0} s)", list.Count, (DateTime.UtcNow - t0).TotalSeconds));
                    BroadcastLobby();
                    MenuStatus();
                }
                catch (Exception e) { Log.W("savegame companies: " + e.Message); }
            }) { IsBackground = true, Name = "Savegame companies" }.Start();
        }

        /// <summary>Tells the players in the lobby who is there (shown in their MPFever window).</summary>
        void BroadcastLobby()
        {
            if (!lobbyOpen || relay == null) return;
            relay.Broadcast(Msg.Make("lobby", hostName, "{[\"players\"]=" + LuaLit.Quote(LobbyList()) + ",[\"save\"]=" + LuaLit.Quote(lobbySave)
                + (lobbySaveSha != "" ? ",[\"sha\"]=" + LuaLit.Quote(lobbySaveSha) + ",[\"size\"]=" + lobbySaveSize : "")
                + ",[\"host\"]=" + LuaLit.Quote(BaseName(hostName ?? "")) + ",[\"mods\"]=" + LuaLit.Quote(lobbyMods) + ",[\"dlcs\"]=" + LuaLit.Quote(SessionDlcs())
                + ",[\"gbuild\"]=" + LuaLit.Quote(Reporter.BuildTag(gameDir))
                + ",[\"colors\"]=" + LuaLit.Quote(LobbyColors()) + ",[\"cmode\"]=" + LuaLit.Quote(companyMode)
                + ",[\"ai\"]=" + LuaLit.Quote(companyMode == "separate" ? LobbyAiView() : "")
                // (0.5.14: the game's rules, shown to the players of the lobby)
                + ",[\"rules\"]=" + LuaLit.Quote(companyMode == "separate" ? LobbyRulesView() : "")
                // (0.6: the game options, in both modes)
                + ",[\"opts\"]=" + LuaLit.Quote(GameOptions()) + "}"));
        }

        /// <summary>The game's rules for the menus (0.5.14, one company per player): "start money|share 1/0|bankruptcy months".</summary>
        string LobbyRulesView() => StartMoney() + "|" + ShareRules() + "|" + BankruptMonths() + "|" + AuctionRule();

        /// <summary>The host starts the game from its lobby: every player in it receives the host's savegame and every game
        /// (the host's too) loads it at once; the session starts when they are all ready, as after a resynchronisation. A
        /// player who joins from now on gets the game the usual way (a resynchronisation once the session runs).</summary>
        void StartLobbyGame()
        {
            try
            {
                string file = GameInstall.FindSave(lobbySave);
                if (file == null) { menuPhase = "error"; menuText = F("Sauvegarde « {0} » introuvable.", "Savegame « {0} » not found.", lobbySave); MenuStatus(); return; }
                byte[] bytes = File.ReadAllBytes(file);
                // (0.6) the savegame's game options not settled yet (its reading still under way, a big savegame): read now from these
                // bytes, before the session carries the options (else the host's game would switch the savegame's off at once)
                if (!SaveOptsOff)
                {
                    int gen; bool settled;
                    lock (saveOptsLock) { gen = lobbyGen; settled = saveOptsGen == gen; }
                    if (!settled)
                    {
                        string o = null;
                        try { o = SaveInfo.OptsOf(Zstd.Decompress(bytes)); } catch (Exception e) { Log.W("savegame options: " + e.Message); }
                        ApplySaveOpts(gen, o);
                    }
                }
                lobbyStarting = true;
                lobbyOpen = false;
                int id = Interlocked.Increment(ref resyncId);
                string[] peers = relay?.PeerNames() ?? new string[0];
                lock (resyncWaiting) { resyncWaiting.Clear(); resyncWaiting.Add(hostName); foreach (var p in peers) resyncWaiting.Add(p); }
                Log.W(F("=== Lancement de la partie « {0} » pour {1} joueur(s) : envoi de la sauvegarde ({2:0.0} Mo) ===", "=== Starting the game « {0} » for {1} player(s): sending the savegame ({2:0.0} MB) ===", lobbySave, peers.Length + 1, bytes.Length / 1048576.0));
                HostChat("msg", "MPFever", T("L'hôte lance la partie : chargement...", "The host starts the game: loading..."));
                resyncBytes = bytes; resyncBytesId = id; resyncSentUpTo = 0;
                // (the bytes read now: the file may have changed since the lobby took its fingerprint)
                string sha = Sha256(bytes);
                if (lobbySaveSha != "" && sha != lobbySaveSha) { Log.W("the lobby's savegame changed since it opened: sent to everybody"); lock (saveHave) saveHave.Clear(); }
                resyncBytesSha = sha;
                // the host's own game loads the savegame from the main menu (mpfever_auto.lua), while the players receive it
                lastLoadOrder = Now;
                // (0.7.7: the DLCs some game lacks, off for the session, before the host's load and the players', see ApplyDlcOff)
                ApplyDlcOff(peers, T("lancement", "start"));
                menuLoad = lobbySave; menuLoadSeq = "h" + DateTime.Now.Ticks;
                WriteLoadId(menuGame, id);
                menuPhase = "loading"; menuText = T("Chargement de la partie...", "Loading the game...");
                MenuStatus();
                SendSave(id, bytes, sha, peers);
                KeepDeltaBase(bytes, sha);
            }
            catch (Exception e)
            {
                lobbyStarting = false;
                Log.Err(T("Lancement de la partie : ", "Starting the game: ") + e.Message);
                menuPhase = "error"; menuText = T("Lancement de la partie : ", "Starting the game: ") + e.Message; MenuStatus();
            }
        }

        /// <summary>Host started from the menu: the session starts as soon as its game runs the savegame (started from a
        /// lobby: once every game of the lobby runs it).</summary>
        void AutoStart()
        {
            WaitUntil(() => { lock (clocks) return hostName != null && clocks.ContainsKey(hostName); }, 120);
            Thread.Sleep(1000);
            if (lobbyStarting)
            {
                bool all = WaitUntil(() => { lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);
                if (!all) { lock (resyncWaiting) Log.Warn(T("Lancement : sans nouvelles de ", "Start: no news from ") + string.Join(", ", resyncWaiting) + T(" (la partie démarre quand même).", " (the game starts anyway).")); }
                saveCancel = resyncBytesId;
                lock (resyncWaiting) resyncWaiting.Clear();
                lobbyStarting = false;
                Thread.Sleep(1000);
            }
            if (started) return;
            StartSession();
            menuPhase = "ingame";
            menuText = T("Partie en cours.", "Game running."); MenuStatus();
        }

        // ---------------------------------------------------------------- autotest (MPFever.exe --autotest [savegame])

        void AutoLine(string s) { lock (autoReport) autoReport.Add(s); Log.W("AUTOTEST " + s); }

        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out WinRect r);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        struct WinRect { public int L, T, R, B; }
        /// <summary>(autotests) the mouse over a game window, a little elsewhere each second, as a player looking around.</summary>
        static void AutoHover(IntPtr w, int s)
        {
            if (w == IntPtr.Zero || !GetWindowRect(w, out var r) || r.R - r.L < 100) return;
            // (the game reads the mouse only in the window in front)
            if (s % 10 == 0) SetForegroundWindow(w);
            int cx = (r.L + r.R) / 2, cy = (r.T + r.B) / 2;
            SetCursorPos(cx + ((s * 37) % 200) - 100, cy + ((s * 53) % 160) - 80);
        }

        bool WaitUntil(Func<bool> cond, double seconds)
        {
            var end = Now + seconds;
            while (Now < end) { if (cond()) return true; Thread.Sleep(500); }
            return cond();
        }

        // autotest: the games that closed or stopped (crashed) during the test; their test cannot say "in sync" (the Leawood runs
        // of 0.3.13: a game crashed on a bulldoze, the other waited for it and the test still ended "IN SYNC"). A crashed game can
        // stay open after writing its crash save: a game that sent no clock for 120 s counts as stopped too.
        string ClosedGames()
        {
            var l = new List<string>();
            lock (games) l.AddRange(games.Where(g => g.Role != "menu" && !g.GameRunning).Select(g => g.Name + " (closed)"));
            lock (clocks) l.AddRange(clocks.Where(c => Now - c.Value.At > 120).Select(c => c.Key + " (no clock for " + (int)(Now - c.Value.At) + " s)"));
            return string.Join(", ", l);
        }

        void AutoTest()
        {
            try
            {
                AutoLine("savegame: " + GameLink.AutoSave);
                bool ready = WaitUntil(() =>
                {
                    int n; lock (players) n = players.Count;
                    // (0.7.18: three games with MPFEVER_CLIENT2=1)
                    int want = Environment.GetEnvironmentVariable("MPFEVER_CLIENT2") == "1" ? 3 : 2;
                    lock (clocks) return n >= want && clocks.Count >= want && clocks.Values.Select(c => c.T).Distinct().Count() == 1;
                }, 600);
                if (!ready) { AutoLine("FAILED: the two games did not get ready with the same save"); return; }
                AutoLine("both games ready");
                Thread.Sleep(3000);
                if (Environment.GetEnvironmentVariable("MPFEVER_SCENARIO") == "det")
                {
                    // exact simulation steps on every game, paused (no real-time pacing involved)
                    RunDeterminism();
                    return;
                }
                // (recplay: the session stays paused at the savegame's time, the replay sets the speed)
                recplayStart = Environment.GetEnvironmentVariable("MPFEVER_SCENARIO") == "recplay";
                StartSession();
                Thread.Sleep(8000);
                var scenarios = (Environment.GetEnvironmentVariable("MPFEVER_SCENARIO") ?? "newroad,upgrade").Split(',');
                if (scenarios[0] == "recplay")
                {
                    RunRecPlay();
                    RequestHash();
                    Thread.Sleep(12000);
                    AutoLine("sync: " + syncText + " (desyncs " + desyncs + ", refused " + actRefused + ")");
                    return;
                }
                if (scenarios[0] == "soak")
                {
                    // endurance: the games only run; the regular checkpoints show what drifts
                    int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SOAK_SPEED") ?? "1", out int sp);
                    int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SOAK_SECONDS") ?? "120", out int secs);
                    SetSpeed(Math.Max(1, sp), "autotest");
                    var cam = Environment.GetEnvironmentVariable("MPFEVER_CAMTOUR");
                    if (!string.IsNullOrEmpty(cam)) HostSend(Msg.Make("camtour", hostName, "{[\"role\"]=\"" + cam + "\"}"));
                    Thread.Sleep(Math.Max(10, secs) * 1000);
                    AutoLine("sync: " + syncText + " (desyncs " + desyncs + ")");
                    return;
                }
                // MPFEVER_SPEED=n: the scenarios run at that speed
                if (int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SPEED") ?? "", out int scenSpeed) && scenSpeed > 0) { SetSpeed(scenSpeed, "autotest"); Thread.Sleep(3000); }
                // MPFEVER_PAUSED=1: the scenarios run with the session paused (actions applied while paused)
                if (Environment.GetEnvironmentVariable("MPFEVER_PAUSED") == "1") { Pause("autotest"); Thread.Sleep(4000); }
                foreach (var scenario in scenarios)
                foreach (var role in new[] { "host", "client" })
                {
                    if (ClosedGames() != "") break;
                    if (scenario == "report")
                    {
                        // (0.7.9) the players' reports in one: asked by the host, then by the client (two games, one MPFever)
                        var notes = new List<string>();
                        var got = GatherOthers(notes, role == "client");
                        AutoLine("report " + role + ": " + got.Count + " report(s) " + string.Join(",", got.Select(kv => kv.Key + "=" + kv.Value.Length))
                            + " | " + string.Join(" / ", notes));
                        try
                        {
                            var zip = Reporter.Collect(games.Select(x => x.Dir).ToList(), "autotest " + role, out _);
                            Reporter.AddPlayers(zip, got, notes);
                            using (var z = System.IO.Compression.ZipFile.OpenRead(zip))
                                AutoLine("report " + role + " zip: " + z.Entries.Count(e => e.FullName.StartsWith("players/", StringComparison.Ordinal)) + " entries under players/");
                        }
                        catch (Exception e) { AutoLine("report " + role + " zip FAILED: " + e.Message); }
                        Thread.Sleep(3000);
                        continue;
                    }
                    if (scenario == "census")
                    {
                        // every game, paused at the same time, writes its census (MPFEVER_CENSUS): compared afterwards
                        if (role == "host")
                        {
                            Pause("autotest"); Thread.Sleep(8000);
                            HostSend(Msg.Make("census_now", hostName, "{[\"tag\"]=\"s" + (++censusN) + "\"}"));
                            AutoLine("census s" + censusN);
                            Thread.Sleep(150000);
                            SetSpeed(1, "autotest");
                        }
                        continue;
                    }
                    if (scenario == "soak")
                    {
                        // (after other scenarios) the games only run, MPFEVER_SOAK_SPEED / MPFEVER_SOAK_SECONDS
                        if (role == "host")
                        {
                            int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SOAK_SPEED") ?? "1", out int ssp);
                            int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_SOAK_SECONDS") ?? "120", out int ssecs);
                            SetSpeed(Math.Max(1, ssp), "autotest");
                            AutoLine("soak " + ssecs + " s at x" + Math.Max(1, ssp));
                            Thread.Sleep(Math.Max(10, ssecs) * 1000);
                            AutoLine("soak over: " + syncText + " (desyncs " + desyncs + ")");
                        }
                        continue;
                    }
                    if (scenario == "resyncbuild")
                    {
                        // a build made by the client while a resynchronisation is under way (issue #81): its game refuses it
                        // (nothing kept anywhere), and the games stay alike after the resynchronisation
                        if (role == "host")
                        {
                            resyncing = true; AutoLine("resynchronisation requested (the client builds during it)");
                            var rt = new Thread(() => Resync("autotest")) { IsBackground = true, Name = "Resync" };
                            rt.Start();
                            WaitUntil(() => resyncDropping, 60);
                            Thread.Sleep(3000);
                            lock (autoDone) autoDone.Remove("client");
                            HostSend(Msg.Make("newroad", hostName, "{[\"role\"]=\"client\",[\"offset\"]=11}"));
                            bool cd = WaitUntil(() => { lock (autoDone) return autoDone.ContainsKey("client"); }, 120);
                            lock (autoDone) AutoLine("client build during the resynchronisation: " + (cd ? autoDone["client"] : "TIMEOUT"));
                            rt.Join(TimeSpan.FromMinutes(10));
                            Thread.Sleep(8000);
                        }
                        continue;
                    }
                    if (scenario == "toshared")
                    {
                        // (crash 2026-10-28: a game that played one company per player, then a session with one company for
                        // everybody in the same run of the game) both games back to the game's main menu, the test's savegame loaded
                        // again from there, a shared session; the mouse over the client's world for a minute (the crash came from
                        // the interface's tool that shows what the mouse is over)
                        if (role == "host")
                        {
                            AutoLine("company mode " + companyMode + " -> shared: both games back to the main menu, '" + GameLink.AutoSave + "' loaded again");
                            resyncing = true;
                            lock (players) players.Clear();
                            lock (clocks) clocks.Clear();
                            lock (sessionGate) { started = false; pauseAt = null; speed = 0; }
                            HostSend(Msg.Make("tomenu", hostName, "{[\"seq\"]=" + DateTime.Now.Ticks + "}"));
                            companyMode = "shared";
                            // ((0.7.5) both games said hello again: their clocks come only once the session is started, so
                            // the test waited 600 s for them and never started it)
                            bool back = WaitUntil(() => { int n; lock (players) n = players.Count; return n >= 2; }, 600);
                            resyncing = false;
                            AutoLine(back ? "both games back with the savegame: shared session" : "FAILED: the games did not come back from the main menu");
                            if (back)
                            {
                                Thread.Sleep(3000);
                                StartSession();
                                var cw = games.FirstOrDefault(x => x.Role == "client")?.Window ?? IntPtr.Zero;
                                for (int s = 0; s < 60 && ClosedGames() == ""; s++) { AutoHover(cw, s); Thread.Sleep(1000); }
                            }
                            AutoLine("after the switch: " + (ClosedGames() == "" ? "both games running" : "CLOSED " + ClosedGames()));
                        }
                        continue;
                    }
                    if (scenario == "tomenustale")
                    {
                        // (0.7.13, #171: MrWhiskey1, a client cut from its host, left its last control lines unread, joined again
                        // from the main menu, and its native module took the company of the game before after the load: the
                        // interface read an entity the new world does not have, and the engine closed the game) as "toshared",
                        // the company mode kept: both games back to the game's main menu, where mpfever_auto.lua says their last
                        // player lines again, unread (no command is added there), the test's savegame loaded again; the mouse
                        // over the client's world from the order until a minute after the start (the crash came at "Game is
                        // ready", from the interface's tool that shows what the mouse is over). MPFEVER_CTLSTALE=1: the crash's way
                        if (role == "host")
                        {
                            AutoLine("company mode " + companyMode + " kept: both games back to the main menu, their last control lines said again there, '" + GameLink.AutoSave + "' loaded again");
                            resyncing = true;
                            lock (players) players.Clear();
                            lock (clocks) clocks.Clear();
                            lock (sessionGate) { started = false; pauseAt = null; speed = 0; }
                            HostSend(Msg.Make("tomenu", hostName, "{[\"seq\"]=" + DateTime.Now.Ticks + ",[\"stale\"]=true}"));
                            Func<IntPtr> clientWin = () => { lock (games) return games.FirstOrDefault(x => x.Role == "client")?.Window ?? IntPtr.Zero; };
                            int hk = 0;
                            bool back = false;
                            for (var until = Now + 600; Now < until; )
                            {
                                lock (players) back = players.Count >= 2;
                                if (back) break;
                                AutoHover(clientWin(), hk++); Thread.Sleep(250);
                            }
                            resyncing = false;
                            AutoLine(back ? "both games back with the savegame: " + companyMode + " session" : "FAILED: the games did not come back from the main menu");
                            if (back)
                            {
                                for (var until = Now + 3; Now < until; ) { AutoHover(clientWin(), hk++); Thread.Sleep(250); }
                                StartSession();
                                for (var until = Now + 60; Now < until && ClosedGames() == ""; ) { AutoHover(clientWin(), hk++); Thread.Sleep(250); }
                            }
                            AutoLine("after the reload: " + (ClosedGames() == "" ? "both games running" : "CLOSED " + ClosedGames()));
                        }
                        continue;
                    }
                    if (scenario == "pubtest")
                    {
                        // (0.6) the public games' options in a session of two games, both at once (PublicGames.cs's RunPubTest)
                        if (role == "host") RunPubTest();
                        continue;
                    }
                    if (scenario == "resync")
                    {
                        // every game reloads the host's savegame (as when a player joins): the companies must come back as they were
                        if (role == "host") { resyncing = true; AutoLine("resynchronisation requested"); Resync("autotest"); Thread.Sleep(8000); }
                        continue;
                    }
                    // MPFEVER_TOGETHER=1: both games run the scenario at the same time (builds made at once by two players)
                    if (Environment.GetEnvironmentVariable("MPFEVER_TOGETHER") == "1")
                    {
                        if (role != "host") continue;
                        lock (autoDone) { autoDone.Remove("host"); autoDone.Remove("client"); }
                        AutoLine("scenario " + scenario + " by both games at once");
                        foreach (var r in new[] { "host", "client" })
                            HostSend(Msg.Make(scenario, hostName, "{[\"role\"]=\"" + r + "\",[\"offset\"]=" + (r == "host" ? 0 : 7) + "}"));
                        WaitUntil(() => { lock (autoDone) return (autoDone.ContainsKey("host") && autoDone.ContainsKey("client")) || ClosedGames() != ""; }, 300);
                        lock (autoDone) foreach (var r in new[] { "host", "client" }) AutoLine(r + " scenario: " + (autoDone.ContainsKey(r) ? autoDone[r] : "TIMEOUT"));
                        if (ClosedGames() != "") break;
                        Thread.Sleep(5000);
                        continue;
                    }
                    lock (autoDone) autoDone.Remove(role);
                    AutoLine("scenario " + scenario + " by " + role);
                    HostSend(Msg.Make(scenario, hostName, "{[\"role\"]=\"" + role + "\",[\"offset\"]=" + (role == "host" ? 0 : 7) + (role == "host" ? ",[\"ab\"]=true" : "") + "}"));
                    bool done = WaitUntil(() => { lock (autoDone) return autoDone.ContainsKey(role) || ClosedGames() != ""; }, 180);
                    lock (autoDone) AutoLine(role + " scenario: " + (autoDone.ContainsKey(role) ? autoDone[role] : "TIMEOUT"));
                    if (ClosedGames() != "") break;
                    Thread.Sleep(5000);
                }
                string closed = ClosedGames();
                if (closed != "")
                {
                    AutoLine("GAME CLOSED during the test: " + closed);
                    AutoLine("sync: FAILED (a game closed) (desyncs " + desyncs + ", refused " + actRefused + ")");
                    return;
                }
                Thread.Sleep(5000);
                RequestHash();
                Thread.Sleep(12000);
                HostSend(Msg.Make("area_dump", hostName, "{}"));
                Thread.Sleep(10000);
                AutoLine("sync: " + syncText + " (desyncs " + desyncs + ", refused " + actRefused + ")");
            }
            catch (Exception e) { AutoLine("ERROR " + e); }
            finally
            {
                AutoLine("sessions: " + string.Join(" ; ", games.Select(g => g.Dir)));
                // (0.8.1, LUAERRGATE) a Lua error in a game's logs fails the test, even when the games stayed in sync: the regression
                // of 0.7.17 ("attempt to index global 'SIM'", 190 times in one autotest of 2026-11-10) was in the logs of autotests
                // judged "in sync". MPFEVER_LUAERRGATE=0: not looked at
                if (Environment.GetEnvironmentVariable("MPFEVER_LUAERRGATE") != "0")
                {
                    int total = 0;
                    foreach (var g in games)
                    {
                        var errs = LuaErrorLines(g.Dir, 3, out int n);
                        total += n;
                        foreach (var l in errs) AutoLine("LUA ERROR [" + g.Name + "] " + l);
                    }
                    AutoLine(total == 0 ? "lua: clean" : "lua: FAILED (" + total + " Lua error line(s) in the games' logs)");
                }
                try { File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "autotest_result.txt"), autoReport); } catch { }
                foreach (var g in games) g.Kill();
                Thread.Sleep(1000);
                Environment.Exit(0);
            }
        }

        DateTime lastAudit = DateTime.MinValue;

        /// <summary>Every 30 s, the command audit of each local game (how many commands of each kind its simulation applied,
        /// written by the native module in native.log) is copied to logs/audit-NAME.txt, to find actions that one game
        /// applied and the other never did.</summary>
        void AuditSnapshot()
        {
            if ((DateTime.Now - lastAudit).TotalSeconds < 30) return;
            lastAudit = DateTime.Now;
            var list = new List<GameLink>();
            try { lock (games) list.AddRange(games); } catch { }
            if (hostGame != null) list.Add(hostGame);
            if (menuGame != null) list.Add(menuGame);
            foreach (var g in list.GroupBy(x => x.Dir).Select(x => x.First()))
            {
                try
                {
                    var f = Path.Combine(g.Dir, "native.log");
                    if (!File.Exists(f)) continue;
                    var last = new SortedDictionary<int, string>();
                    using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        if (fs.Length > 400000) fs.Seek(-400000, SeekOrigin.End);
                        using (var r = new StreamReader(fs))
                        {
                            string l;
                            while ((l = r.ReadLine()) != null)
                            {
                                int i = l.IndexOf("audit kind ", StringComparison.Ordinal);
                                if (i < 0) continue;
                                var p = l.Substring(i + 11).Split(' ');
                                if (p.Length >= 5 && int.TryParse(p[0], out var k)) last[k] = "kind " + p[0] + " loop " + p[2] + " direct " + p[4];
                            }
                        }
                    }
                    if (last.Count > 0)
                        File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs", "audit-" + (g.Name ?? "game") + ".txt"), last.Values);
                }
                catch { }
            }
        }

        void RefreshStatus()
        {
            AuditSnapshot();
            if (menuMode) MenuStatus();
            UpdateDashboard();
            if (relay == null) { if (clients.Count > 0) status.Text = T("Client connecté", "Connected to the host"); return; }
            int n; lock (players) n = players.Count;
            string sp; lock (sessionGate) sp = pauseAt.HasValue ? T("pause", "paused") : "x" + speed;
            string spread = "";
            lock (clocks) if (clocks.Count > 1) { var est = clocks.Values.Select(Estimate).ToList(); spread = F(" · écart {0:0} pas", " · gap {0:0} steps", (est.Max() - est.Min()) / Step); }
            status.Text = started
                ? F("{0} · {1} jeu(x){2} · actions {3} (refus {4}, échecs {5}) · {6}", "{0} · {1} game(s){2} · actions {3} (refused {4}, failed {5}) · {6}", sp, n, spread, actsRelayed, actRefused, actFails, syncText)
                : F("{0} jeu(x) prêt(s) – chargez la même sauvegarde partout puis « Démarrer »", "{0} game(s) ready – load the same savegame everywhere, then « Start »", n);
            startBtn.Enabled = !started;
            pauseBtn.Enabled = x1Btn.Enabled = x2Btn.Enabled = x4Btn.Enabled = started;
            detBtn.Enabled = true;
        }

        // ---------------------------------------------------------------- sessions

        /// <summary>Relay.Admit of a player's own game: its version (unless anyVersion), then the public games' rules (PublicAdmit).</summary>
        internal static Func<Peer, Msg, string> HostAdmit(bool anyVersion, Func<Msg, string> version, Func<Peer, string> pub)
            => (p, m) => (anyVersion ? null : version(m)) ?? pub(p);

        void StartHost(string name, bool launch, GameLink existing = null)
        {
            leftSession = null;   // (a report describes this session now)
            hostName = name;
            relay = new Relay();
            // a dedicated server lets in only the players with its password and its version, up to its number of players
            if (server != null) { var r = relay; relay.Admit = (p, m) => ServerAdmit(r, p, m); }
            // a player's own game lets in only the players with its version: a guest on another version replays the builds its
            // own way and the games go apart (issue #73: a host on 0.3.20, its guest on 0.3.22). MPFEVER_ANYVERSION=1 lets everybody in.
            // (0.6: then the host's ban list, a free place in a public game and the host's answer to every arrival, when its game
            // options ask for them: PublicGames.cs; none of them by default. MPFEVER_ANYVERSION=1 skips the version check only: the
            // ban list, the places and the host's answer still hold, else a banned player came in with that switch)
            else { var r = relay; relay.Admit = HostAdmit(Environment.GetEnvironmentVariable("MPFEVER_ANYVERSION") == "1", m => VersionAdmit(m.Payload), p => PublicAdmit(r, p)); }
            relay.Joined += p =>
            {
                Log.Ok(F("{0} a rejoint la session", "{0} joined the session", p.Name));
                lock (leftAt) leftAt.Remove(BaseName(p.Name));
                relay.DropOlder(p);
                // (0.7.0) a game already running (no lobby: a player's game started, a dedicated server): the player sees its mods and
                // DLCs on its page first, gets what it lacks, and says when it joins (joinready); only then does it get the game
                bool review = menuMode && !lobbyOpen && JoinReviewOn;
                relay.Send(p, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(p.Name) + ",[\"role\"]=\"client\",[\"v\"]=" + LuaLit.Quote(Version) + ",[\"run\"]=" + LuaLit.Quote(myRun) + ",[\"opts\"]=" + LuaLit.Quote(Options.SessionPayload()) + ",[\"mods\"]=" + LuaLit.Quote(lobbyMods) + ",[\"dlcs\"]=" + LuaLit.Quote(SessionDlcs()) + ",[\"gbuild\"]=" + LuaLit.Quote(Reporter.BuildTag(gameDir))
                    + ",[\"rtok\"]=" + LuaLit.Quote(p.Link?.Token ?? "") + (hostSteamId != null ? ",[\"sid\"]=" + LuaLit.Quote(hostSteamId) : "") + (review ? ",[\"review\"]=true" : "") + "}"));
                Msg[] history; lock (chatLog) history = chatLog.ToArray();
                foreach (var c in history) relay.Send(p, c);   // the chat so far (a reconnecting player skips what it has)
                HostChat("join", BaseName(p.Name), "");
                BroadcastSession();
                // started from the main menu: the new player receives the host's game (every game reloads it); in the lobby, it
                // waits there for the host to start the game
                // (during a resynchronisation, a player back after a cut says what it already has: resync_have)
                if (menuMode)
                {
                    if (lobbyOpen) BroadcastLobby();
                    else if (review)
                    {
                        lock (reviewing) reviewing.Add(p.Name);
                        Log.W(F("{0} regarde les mods et les DLC de la partie avant de la rejoindre", "{0} looks at the game's mods and DLCs before joining it", BaseName(p.Name)));
                    }
                    else if (!resyncing || resyncBytes == null) joinPending = true;
                    MenuStatus();
                }
            };
            relay.Left += p =>
            {
                Log.Warn(F("{0} a quitté la session", "{0} left the session", p.Name));
                lock (reviewing) reviewing.Remove(p.Name);
                lock (leftAt) leftAt[BaseName(p.Name)] = Now;
                HostChat("left", BaseName(p.Name), "");
                lock (players) players.Remove(p.Name);
                lock (clocks) clocks.Remove(p.Name);
                HostSend(Msg.Make("peerleft", hostName, "{[\"name\"]=" + LuaLit.Quote(p.Name) + "}"));
                // (a player gone from the lobby, or while the lobby's games load: nobody waits for it)
                lock (resyncWaiting) if (lobbyStarting) resyncWaiting.Remove(p.Name);
                // (0.7.4) A player gone during a resynchronisation was waited for until its end, 600 s, every game frozen: dickj on the
                // user's server, 2026-11-06 23:17 (0.7.3 waits for the players who join, and dickj left while the game was on its
                // way). Now one that is not back within 20 s (back, under another name, it says so with "hello" or "resync_have")
                // is no longer waited for. MPFEVER_RESYNCLEFT=0: as before
                if (!lobbyStarting && resyncing && Environment.GetEnvironmentVariable("MPFEVER_RESYNCLEFT") != "0")
                {
                    bool waited; lock (resyncWaiting) waited = WaitedFor(resyncWaiting, p.Name, Environment.GetEnvironmentVariable("MPFEVER_RESYNCLEFTNAME") == "0");
                    if (waited)
                    {
                        var gone = p.Name;
                        var r = relay;
                        new Thread(() =>
                        {
                            Thread.Sleep(ResyncLeftSeconds * 1000);
                            int n; lock (resyncWaiting) n = DropDeparted(resyncWaiting, gone, r?.PeerNames() ?? new string[0]);
                            if (n > 0) Log.Warn(F("Resynchronisation : {0} n'est pas revenu depuis {1} s, on ne l'attend plus", "Resynchronisation: {0} has not come back for {1} s, no longer waited for", BaseName(gone), ResyncLeftSeconds));
                        }) { IsBackground = true, Name = "Resync left" }.Start();
                    }
                }
                if (lobbyOpen) { BroadcastLobby(); MenuStatus(); }
                if (server != null) ServerPlayerLeft(p);
            };
            // a player whose connection dropped during the game is waited for (SessionLink.Grace, 60 s): every game stops where
            // its clock stopped (the games' barrier keeps its last clock), and back in time it gets what it missed and the
            // session goes on, with no reload. Not in the lobby, nor during a resynchronisation (its world is replaced anyway).
            relay.Grace = SessionLink.Grace;
            relay.MayWait = p => started && !resyncing && !lobbyStarting;
            relay.Away += p =>
            {
                Log.Warn(F("{0} a perdu la connexion : la partie l'attend ({1:0} s au plus)", "{0} lost the connection: the game waits for them ({1:0} s at most)", p.Name, relay?.Grace ?? 0));
                lock (clocks) if (clocks.TryGetValue(p.Name, out var c)) { c.At = Now; c.Sp = 0; }
                HostChat("away", BaseName(p.Name), "");
                if (lobbyOpen) { BroadcastLobby(); MenuStatus(); }
            };
            relay.Resumed += (p, away, n) =>
            {
                HostChat("back", BaseName(p.Name), "");
                BroadcastSession();
            };
            relay.Received += (p, m) => OnHostMessage(m, p);
            int listenPort = server != null ? server.Port : (int)portBox.Value;
            relay.Start(listenPort);
            // the port opened on the router by itself (UPnP / NAT-PMP), not for a local test
            if (!autotest && !Dev) PortMap.OpenAsync(listenPort, r =>
            {
                if (!lobbyOpen) return;
                // (0.6.7: the method used, and no claim the Internet reaches this PC when the router's address says it cannot; a
                // failure is told too, with what to forward)
                if (r.Method == null) menuText += " " + T("Le port n'a pas pu être ouvert automatiquement : ", "The port could not be opened by itself: ") + (r.Error ?? "");
                else if (r.Problem != null) menuText += " " + r.Problem;
                else menuText += " " + F("Le port a été ouvert automatiquement sur votre box ({0}).", "The port was opened on your router by itself ({0}).", r.Method);
                MenuStatus();
            });

            hostGame = existing ?? new GameLink(name, "host");
            if (!games.Contains(hostGame)) games.Add(hostGame);
            // (the host's own settings: the session's are sent to every player in the welcome)
            Options.HostSession = null;
            hostGame.WriteSettings();
            hostGame.FromGame += hostFromGame = (g, m) =>
            {
                m.From = hostName;
                if (m.Kind == "hello")
                {
                    g.InGame = true;
                    g.ToGame(Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(hostName) + ",[\"role\"]=\"host\"}"));
                    BroadcastSession();
                    if (menuMode && !started) new Thread(AutoStart) { IsBackground = true, Name = "Auto start" }.Start();
                }
                OnHostMessage(m, null);
            };
            if (launch) hostGame.Launch(gameDir);
            // players can come through Steam (no port to open): once the host's game's module is ready, it listens on Steam and
            // tunnels each connection to the Relay with this session's secret
            if (SteamNet.Enabled)
            {
                var steamGame = hostGame; var steamRelay = relay;
                new Thread(() =>
                {
                    if (!SteamNet.WaitReady(steamGame.Dir, 600, out string sid, out string why))
                    {
                        Log.W(T("Steam : les joueurs ne peuvent pas se connecter par Steam (", "Steam: players cannot connect through Steam (") + why + ")");
                        return;
                    }
                    if (relay != steamRelay) return;
                    var secret = SessionLink.NewToken();
                    steamRelay.SteamSecret = secret;
                    try
                    {
                        // (0.6: " friends" when the host keeps its private game's Steam connections to its Steam friends)
                        SteamNet.Cmd(steamGame.Dir, SteamHostCommand(steamGame.Dir, listenPort, secret));
                        if (SteamNet.TestIpPort > 0) SteamNet.Cmd(steamGame.Dir, "ipmode listen 127.0.0.1:" + SteamNet.TestIpPort);
                    }
                    catch (Exception e) { Log.W("steamnet: " + e.Message); return; }
                    hostSteamId = sid;
                    Log.Ok(F("Steam : les joueurs peuvent rejoindre par Steam, sans port à ouvrir (steam:{0})", "Steam: players can join through Steam, with no port to open (steam:{0})", sid));
                }) { IsBackground = true, Name = "Steam host" }.Start();
            }
            int gen = sessionGen;
            new Thread(() => HostLoop(gen)) { IsBackground = true, Name = "Host loop" }.Start();
        }

        void StartClient(string name, string host, int port, bool launch, GameLink existing = null, string password = null)
        {
            var game = existing ?? new GameLink(name, "client");
            if (!games.Contains(game)) games.Add(game);
            // (0.7.7: a new session's players, for the reports, see NoteFromHost)
            lock (clientPeers) clientPeers.Clear();
            hostStartedSeen = -1;
            WriteDlcDrop(game.Dir, null);
            Client current = null;
            string hostSid = null;   // the host's Steam id, from its welcome
            string Targets() => hostSid == null || host.IndexOf("steam:", StringComparison.OrdinalIgnoreCase) >= 0 ? host : host + ",steam:" + hostSid;
            // this player's session messages with the host, across its connections: after a cut, the host goes on with them
            // if it still waits for this player (SessionLink)
            var link = new SessionLink();
            bool CanResume() => SessionLink.Grace > 0 && !string.IsNullOrEmpty(link.Token) && !link.Broken && game.InGame;
            // (the game's messages while cut, for the connection that takes over: sent in order before any newer one)
            var waiting = new List<Msg>();
            // (0.7.4: 1 while a reconnection runs, see Closed)
            int reconnecting = 0;
            clientCancelled = false;
            leftSession = null;   // (a report describes this session now)
            // a reconnect thread of an earlier session must not wake up in this one (issue #13)
            int gen = sessionGen;
            // A connection made once the session was left (LeaveOnGameExit when the game closed, EndSession) is closed instead of
            // added: Connect may take 20 s, and the session's end found nothing to close meanwhile. Added, it was a player with
            // no game behind it, in the host's session until this MPFever was quit (see LeaveOnGameExit). The same when the game
            // of the MPFever window closed before this join even started. MPFEVER_STALEJOIN=0: as before.
            // (the game's end counts only where it ends the session: not on a dedicated server, nor with MPFEVER_EXITKEEPSESSION=1)
            bool staleCheck = Environment.GetEnvironmentVariable("MPFEVER_STALEJOIN") != "0";
            bool exitLeaves = !ServerMode && Environment.GetEnvironmentVariable("MPFEVER_EXITKEEPSESSION") != "1";
            bool SessionLeft() => staleCheck && (gen != sessionGen || (exitLeaves && menuMode && game == menuGame && !game.GameRunning));
            // (the session's number checked and the connection added under the lock: LeaveOnGameExit and EndSession take and empty
            // the list under it, after they marked the session left, so a connection is either closed by them or never added. The
            // game's end is read before the lock: Process.HasExited may run the game's Exited handlers, LeaveOnGameExit among them,
            // under the Process's own lock, and LeaveOnGameExit takes this one: read under it, the two threads could wait on each
            // other for ever)
            bool AddUnlessLeft(Client c)
            {
                bool left = SessionLeft();
                if (!left)
                    lock (clients)
                    {
                        left = staleCheck && gen != sessionGen;
                        if (!left)
                        {
                            clients.Add(c);
                            // (what the game sent while cut goes first; a link that does not go on drops it, see Client)
                            lock (waiting) { foreach (var w in waiting) c.Send(w); waiting.Clear(); current = c; }
                        }
                    }
                if (!left) return true;
                Log.W(F("[{0}] session quittée pendant la connexion : la connexion à l'hôte est refermée", "[{0}] session left while connecting: the connection to the host is closed again", name));
                try { c.Dispose(); } catch { }
                return false;
            }
            // the in-game MPFever window: the host's view of the session, and this game's own link to the host
            string myId = name, hostStatus = "", deniedText = null;
            long lastChatId = 0;   // the host sends its chat history again on a reconnection
            void ClientStatus(string conn, int attempt)
            {
                try { game.WriteStatus(hostStatus + "me=" + myId + "\nconn=" + conn + "\nattempt=" + attempt + "\nt=" + UnixNow() + "\n"
                    + (deniedText != null ? "denied=" + deniedText.Replace("\r", " ").Replace("\n", " ") + "\n" : "")); }
                catch { }
            }
            game.FromGame += clientFromGame = (g, m) =>
            {
                if (m.Kind == "hello") { g.InGame = true; if (menuMode) { menuPhase = "ingame"; menuText = T("En partie.", "In game."); MenuStatus(); } }
                // (0.7.13, #161/#166: this game's memory once loaded, see GameLink.LogMemoryNow; aside, the game's messages go on)
                if (m.Kind == "hello") ThreadPool.QueueUserWorkItem(_ => g.LogMemoryNow("game ready"));
                lock (waiting)
                {
                    var to = current;
                    if (to != null) to.Send(m);
                    else if (CanResume() && waiting.Count < 100000) waiting.Add(m);   // (cut: kept for the host, see AddUnlessLeft)
                }
            };
            Action<Client> wire = null;
            wire = client =>
            {
                // the host does not let this player in (a dedicated server: password, full, other version, kicked): no
                // reconnection, the player is told why
                client.Denied += d =>
                {
                    clientCancelled = true;
                    var text = DeniedText(d);
                    deniedText = text;
                    Log.Err(text);
                    ClientStatus("denied", 0);
                    game.AppendChat(0, UnixNow(), "msg", "MPFever", text);
                    if (menuMode) { menuPhase = "error"; menuText = text; MenuStatus(); }
                };
                // (0.6) the host lets every arrival in by hand: the page says so until it answers
                client.Waiting += () =>
                {
                    if (!menuMode || game.InGame) return;
                    menuPhase = "connected"; menuText = T("En attente de l'accord de l'hôte...", "Waiting for the host to let you in..."); MenuStatus();
                };
                bool haveSent = false;   // resync_have: once per connection, at its first welcome
                client.Resumed += () =>
                {
                    haveSent = true;   // (no resync_have: the host goes on with this player as it was)
                    Log.Ok(F("[{0}] reconnecté à l'hôte : la session continue", "[{0}] reconnected to the host: the session goes on", name));
                    ClientStatus("ok", 0);
                    if (menuMode) { menuPhase = "ingame"; menuText = T("Reconnecté : la partie continue.", "Reconnected: the game goes on."); MenuStatus(); }
                };
                client.ResumeRefused += () =>
                {
                    if (menuMode) { menuPhase = "connected"; menuText = T("Reconnecté. L'hôte renvoie sa partie...", "Reconnected. The host sends its game again..."); MenuStatus(); return; }
                    // (outside the main menu nobody sends this game the host's: it stops rather than play on a world of its own)
                    clientCancelled = true;
                    game.ToGame(Msg.Make("session", "MPFever", "{[\"started\"]=false,[\"speed\"]=0}"));
                    ClientStatus("gone", 0);
                    new Thread(() => { try { client.Dispose(); } catch { } }) { IsBackground = true }.Start();
                };
                client.Received += m =>
                {
                    // (0.6.12, #125: the host's company mode, for this player's problem reports; the message goes on to the game)
                    if (m.Kind == "session") { var cm = SessionMode(m.Payload); if (cm != "") hostCompanyMode = cm; }
                    // (0.7.7: who plays and whether the game runs, for this player's reports)
                    try { NoteFromHost(m, name); } catch { }
                    // (0.7.7) the DLCs off for this session, before the host's savegame comes (see ApplyDlcOff)
                    if (m.Kind == "dlcoff")
                    {
                        var dd = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        var ids = dd != null && dd.TryGetValue("ids", out var iv) && iv is string ivs ? ivs : "";
                        if (DlcSessionOn()) { WriteDlcDrop(game.Dir, ids.Split(',').Select(x => x.Trim()).Where(x => x != "")); if (ids != "") Log.W(F("DLC désactivés pour cette session par l'hôte : {0}", "DLCs switched off for this session by the host: {0}", ids)); }
                        return;
                    }
                    if (m.Kind == "resync_file" || m.Kind == "resync_bin") { OnResyncFile(game, m); return; }
                    // (0.7.9) the reports of every player of the session in one (see ReportShare)
                    if (OnReportMessage(m, client)) return;
                    if (m.Kind == "resync_use") { OnResyncUse(game, client, name, m); return; }
                    if (m.Kind == "delta_bin") { OnDeltaFile(game, client, name, m); return; }
                    if (m.Kind == "modfile") { OnModFile(m); return; }
                    if (m.Kind == "modoffer")
                    {
                        // the host offers its mods no Mod Hub has: the player decides (the menu shows the offer)
                        var mo = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        string ids = mo.TryGetValue("ids", out var iv) && iv is string iss ? iss : "";
                        string mb = mo.TryGetValue("mb", out var mv) ? Convert.ToString(mv, CultureInfo.InvariantCulture) : "";
                        if (mo.TryGetValue("no", out var nov) && nov is bool nob && nob) { modOffer = ""; modAskState = "refused"; }
                        else { modOffer = ids + "|" + mb; modAskState = ""; Log.Warn(F("L'hôte propose de vous envoyer ses mods : {0} ({1} Mo). Acceptez ou refusez dans la page Multijoueur.", "The host offers to send you its mods: {0} ({1} MB). Accept or refuse on the Multiplayer page.", ids, mb)); }
                        MenuStatus();
                        return;
                    }
                    if (m.Kind == "lobby")
                    {
                        // the host's lobby: who is there, until the host starts the game (or closes the lobby)
                        var lb = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        string S(string k) => lb.TryGetValue(k, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
                        if (lb.TryGetValue("closed", out var cl) && cl is bool closed && closed)
                        {
                            Log.Warn(T("L'hôte a fermé le salon.", "The host closed the lobby."));
                            new Thread(() =>
                            {
                                EndSession(T("=== L'hôte a fermé le salon : fin de la session ===", "=== The host closed the lobby: the session ends ==="));
                                menuPhase = "error"; menuText = T("L'hôte a fermé le salon.", "The host closed the lobby."); MenuStatus();
                            }) { IsBackground = true, Name = "Lobby closed" }.Start();
                            return;
                        }
                        if (menuMode && !game.InGame && menuPhase != "downloading" && menuPhase != "loading")
                        {
                            lobbyPlayers = S("players");
                            lobbyColors = S("colors");
                            lobbyMode = S("cmode");
                            lobbyAiText = S("ai");
                            lobbyRulesText = S("rules");
                            // (0.6) the host's game options, logged when they change
                            var lo = GameOpts.Canon(S("opts"));
                            if (lo != lobbyOptsText && lo != "") Log.W(F("Options de partie choisies par l'hôte : {0}", "Game options chosen by the host: {0}", lo));
                            lobbyOptsText = lo;
                            SetHostMods(S("mods"), client, name);
                            CheckHostDlcs(S("dlcs"), client, name);
                            CheckHostBuild(S("gbuild"), client, name);
                            // the host's savegame: maybe on this PC already (copied by hand): then nothing to download
                            if (S("sha") != "" && long.TryParse(S("size"), NumberStyles.Integer, CultureInfo.InvariantCulture, out long hsz)) CheckHostSave(S("sha"), hsz, S("save"), client, name);
                            menuPhase = "lobby";
                            menuText = F("Dans le salon de {0} (« {1} ») : l'hôte lance la partie quand tout le monde est là.", "In {0}'s lobby (« {1} »): the host starts the game when everybody is here.", S("host"), S("save"));
                            MenuStatus();
                        }
                        return;
                    }
                    if (m.Kind == "mpstatus")
                    {
                        if (LuaLit.Parse(m.Payload) is Dictionary<object, object> st && st.TryGetValue("text", out var tx) && tx is string text)
                        {
                            hostStatus = text;
                            ClientStatus("ok", 0);
                        }
                        return;
                    }
                    if (m.Kind == "chatmsg")
                    {
                        if (LuaLit.Parse(m.Payload) is Dictionary<object, object> c && c.TryGetValue("id", out var iv) && iv is double id && (long)id > lastChatId)
                        {
                            lastChatId = (long)id;
                            string S(string k) => c.TryGetValue(k, out var v) ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
                            long.TryParse(S("t"), out long ct);
                            game.AppendChat((long)id, ct, S("kind"), S("name"), S("text"));
                        }
                        return;
                    }
                    if (m.Kind == "welcome" && LuaLit.Parse(m.Payload) is Dictionary<object, object> w && w.TryGetValue("you", out var you) && you is string youName)
                    {
                        myId = youName;
                        reportMe = youName;   // (0.7.9) the name the players' reports come back to (see ReportShare)
                        // a host on another version (before 0.3.23 its welcome says none: older than this one): the player leaves
                        // at once rather than play apart (issue #73)
                        var hv = w.TryGetValue("v", out var hvo) && hvo is string hvs ? hvs : "";
                        if (hv != Version && Environment.GetEnvironmentVariable("MPFEVER_ANYVERSION") != "1")
                        {
                            clientCancelled = true;
                            var text = hv == ""
                                ? F("L'hôte utilise une version plus ancienne de MPFever, et vous {0} : tous les joueurs doivent installer la même version.", "The host runs an older version of MPFever, and you run {0}: every player needs the same version.", Version)
                                : DeniedText(new Dictionary<object, object> { ["reason"] = "version", ["v"] = hv });
                            deniedText = text;
                            Log.Err(text);
                            ClientStatus("denied", 0);
                            game.AppendChat(0, UnixNow(), "msg", "MPFever", text);
                            if (menuMode) { menuPhase = "error"; menuText = text; MenuStatus(); }
                            new Thread(() => { try { client.Dispose(); } catch { } }) { IsBackground = true }.Start();
                            return;
                        }
                        // the host's game half received before the connection dropped: kept if the host's MPFever is the same run
                        // (a host that restarted numbers its games from 1 again, issue #29), and the host is told what is
                        // missing, so that it sends only that instead of the whole game again (issue #60: a 51 MB game sent
                        // again at every reconnection, every 20 s)
                        // the host's session settings (settings window): the same on every game, applied when the game loads
                        if (!Options.Disabled && w.TryGetValue("opts", out var ov) && ov is string os)
                        {
                            Options.HostSession = Options.ParsePayload(os);
                            game.WriteSettings();
                            if (!haveSent) Log.W(F("Réglages de la partie choisis par l'hôte : {0}", "Game settings chosen by the host: {0}", Options.Changed()));
                        }
                        if (w.TryGetValue("mods", out var mv0) && mv0 is string ms0) SetHostMods(ms0, client, name);
                        if (w.TryGetValue("dlcs", out var dv0) && dv0 is string ds0) CheckHostDlcs(ds0, client, name);
                        if (w.TryGetValue("gbuild", out var gb0) && gb0 is string gbs0) CheckHostBuild(gbs0, client, name);
                        if (w.TryGetValue("sid", out var sv) && sv is string ss && SteamNet.IsSteamId("steam:" + ss, out _)) hostSid = ss;
                        var run = w.TryGetValue("run", out var rv) && rv is string rs ? rs : "";
                        string have = "{[\"id\"]=0}";
                        lock (resyncParts)
                        {
                            if (run == "" || run != hostRun) resyncParts.Clear();
                            hostRun = run;
                            foreach (var kv in resyncParts)
                            {
                                var miss = Enumerable.Range(0, kv.Value.Length).Where(k => kv.Value[k] == null).ToArray();
                                if (miss.Length == 0 || miss.Length == kv.Value.Length) continue;
                                have = "{[\"id\"]=" + kv.Key + ",[\"n\"]=" + kv.Value.Length + ",[\"missing\"]=" + LuaLit.Quote(string.Join(",", miss)) + "}";
                                Log.W(F("[{0}] partie de l'hôte reçue en partie ({1}/{2}) : seule la suite est demandée", "[{0}] host game partly received ({1}/{2}): only the rest is asked for", name, kv.Value.Length - miss.Length, kv.Value.Length));
                            }
                        }
                        // (0.7.0) a game already running asks this player to look at its mods and DLCs first (see the join review):
                        // nothing to look at (the same mods and DLCs), or what this player accepted already (back after a cut), joins
                        // at once; else the page shows them with « Join the game », and the host's game comes after it
                        bool review = w.TryGetValue("review", out var rvo) && rvo is bool rvb && rvb && menuMode && !game.InGame;
                        if (!haveSent)
                        {
                            var key = hostRun + "|" + lobbyMods + "|" + lastHostDlcs;
                            Action<bool> send = asked =>
                            {
                                if (haveSent) return;
                                haveSent = true;
                                reviewSend = null;
                                try
                                {
                                    if (review) client.Send(Msg.Make("joinready", name, "{[\"asked\"]=" + (asked ? "true" : "false") + "}"));
                                    client.Send(Msg.Make("resync_have", name, have));
                                }
                                catch { }
                            };
                            // (0.7.10, the user 2026-11-08: « je souhaite que la page du salon s'ouvre systématiquement ») every join of
                            // a game already running shows its mods and DLCs first, the same ones too; a player who accepted already
                            // (back after a cut, the same game) is not asked again. MPFEVER_REVIEWALWAYS=0: only when something differs
                            bool always = Environment.GetEnvironmentVariable("MPFEVER_REVIEWALWAYS") != "0";
                            if (review && (always || !JoinReviewClear()) && reviewAccepted != key)
                            {
                                reviewSend = () => { reviewAccepted = key; send(true); };
                                menuPhase = "review";
                                menuText = T("Cette partie est déjà en cours. Vérifiez ses mods et ses DLC ci-dessous, installez ce qui vous manque, puis cliquez sur « Rejoindre la partie ».",
                                    "This game is already running. Check its mods and DLCs below, get what you lack, then click « Join the game ».");
                                Log.Warn(T("La partie de l'hôte a d'autres mods ou DLC que ce PC : rien n'est chargé avant « Rejoindre la partie » dans la page Multijoueur.",
                                    "The host's game has other mods or DLCs than this PC: nothing is loaded before « Join the game » on the Multiplayer page."));
                                MenuStatus();
                            }
                            else send(false);
                        }
                    }
                    game.ToGame(m);
                    if (m.Kind == "act") Log.Dim(F("[{0}] reçu {1} de {2}", "[{0}] received {1} from {2}", name, m.Kind, m.From));
                };
                client.Closed += () =>
                {
                    // (0.7.4) A connection replaced by a newer one (the host closes the older connection of a player who comes back,
                    // "ancienne connexion fermée (reconnexion)") started a reconnection of its own, which replaced the newer one, and so
                    // on: dickj on the user's server, 2026-11-06 23:17, a new connection every 5 s for two minutes. Now a superseded
                    // connection does not reconnect, and only one reconnection runs at a time. MPFEVER_RECONNECTOLD=1: as before
                    bool oldWay = Environment.GetEnvironmentVariable("MPFEVER_RECONNECTOLD") == "1";
                    bool superseded = current != null && current != client;
                    lock (clients) clients.Remove(client);
                    if (current == client) current = null;   // nothing is sent until reconnected
                    if (!oldWay && superseded)
                    {
                        Log.W(F("[{0}] ancienne connexion à l'hôte fermée (une plus récente la remplace)", "[{0}] older connection to the host closed (a newer one replaces it)", name));
                        return;
                    }
                    Log.Warn(F("[{0}] connexion à l'hôte perdue", "[{0}] connection to the host lost", name));
                    ClientStatus(deniedText != null ? "denied" : "lost", 0);
                    game.ToGame(Msg.Make("session", "MPFever", "{[\"started\"]=false,[\"speed\"]=0}"));
                    // (nor when the session was left: a connection closed by AddUnlessLeft once the game had closed, say)
                    // (outside the main menu's sessions - the launcher's own window, the tests -: only to go on with the link)
                    bool resumable = CanResume();
                    if (!resumable && SessionLink.Grace > 0)
                        Log.W(F("[{0}] la session ne peut pas continuer après cette coupure (lien {1}, {2}, jeu {3})", "[{0}] the session cannot go on after this cut (link {1}, {2}, game {3})", name,
                            string.IsNullOrEmpty(link.Token) ? T("sans nom", "unnamed") : T("nommé", "named"), link.Broken ? T("trop de messages en attente", "too many messages waiting") : "ok",
                            game.InGame ? T("en partie", "in game") : T("pas en partie", "not in game")));
                    if (clientCancelled || gen != sessionGen || SessionLeft() || (!menuMode && !resumable)) return;
                    // (a host game half received is kept: back with the same host, only the rest is asked for; see "welcome")
                    // the connection dropped: try again for 5 minutes; back with the host, the session goes on if the host still
                    // waits for this player (soon: after 1 s, 2 s, then every 5 s), else this game receives its game again like
                    // any player who joins
                    if (!oldWay && Interlocked.CompareExchange(ref reconnecting, 1, 0) != 0)
                    {
                        Log.W(F("[{0}] une reconnexion est déjà en cours", "[{0}] a reconnection is already under way", name));
                        return;
                    }
                    Interlocked.Increment(ref clientJoins);
                    new Thread(() =>
                    {
                        try
                        {
                            var end = DateTime.UtcNow.AddMinutes(menuMode ? 5 : (SessionLink.Grace + 10) / 60);
                            for (int attempt = 1; DateTime.UtcNow < end && !clientCancelled && gen == sessionGen; attempt++)
                            {
                                bool claim = CanResume();
                                if (!menuMode && !claim) return;
                                menuPhase = "connecting";
                                menuText = F("Connexion à l'hôte perdue : reconnexion (essai {0})...", "Connection to the host lost: reconnecting (attempt {0})...", attempt);
                                MenuStatus();
                                ClientStatus("lost", attempt);
                                Thread.Sleep(claim && attempt <= 2 ? attempt * 1000 : 5000);
                                if (clientCancelled || gen != sessionGen) return;
                                var c = new Client(link) { SteamDir = game.Dir };
                                try
                                {
                                    wire(c);
                                    c.Connect(Targets(), port, name, password, claim);
                                    if (!AddUnlessLeft(c)) return;
                                    Log.Ok(F("[{0}] reconnecté à l'hôte", "[{0}] reconnected to the host", name));
                                    if (!claim) { menuPhase = "connected"; menuText = T("Reconnecté. L'hôte renvoie sa partie...", "Reconnected. The host sends its game again..."); MenuStatus(); }
                                    return;
                                }
                                catch (Exception e) { Log.Warn(T("Reconnexion : ", "Reconnecting: ") + e.Message); }
                            }
                            if (!clientCancelled && gen == sessionGen) { menuPhase = "error"; menuText = T("Connexion à l'hôte perdue (reconnexion impossible).", "Connection to the host lost (could not reconnect)."); MenuStatus(); ClientStatus("gone", 0); }
                        }
                        finally { Interlocked.Decrement(ref clientJoins); Interlocked.Exchange(ref reconnecting, 0); }
                    }) { IsBackground = true, Name = "Reconnect" }.Start();
                };
            };
            var first = new Client(link) { SteamDir = game.Dir };
            wire(first);
            bool added;
            // (through Steam, the game's module carries the connection: the game first)
            bool launched = launch && host.IndexOf("steam:", StringComparison.OrdinalIgnoreCase) >= 0;
            if (launched) game.Launch(gameDir);
            Interlocked.Increment(ref clientJoins);
            try
            {
                first.Connect(host, port, name, password);
                added = AddUnlessLeft(first);
            }
            finally { Interlocked.Decrement(ref clientJoins); }
            if (!added) return;
            // the in-game chat: this player's messages go to the host, which sends them to everybody. Started once the
            // connection is up, and only one at a time: a join that failed before (timeout, wrong address) must not leave
            // a reader behind that takes the messages and marks them unsent
            int chatGen = sessionGen, chatMine = ++chatReaders;
            new Thread(() =>
            {
                while (chatGen == sessionGen && chatMine == chatReaders && !clientCancelled)
                {
                    Thread.Sleep(250);
                    foreach (var line in game.ReadChatOut())
                    {
                        var text = ChatClean(line);
                        if (text.Length == 0) continue;
                        var to = current;
                        if (to != null) to.Send(Msg.Make("chat", name, "{[\"text\"]=" + LuaLit.Quote(text) + "}"));
                        else game.AppendChat(0, UnixNow(), "unsent", BaseName(myId), text);
                    }
                }
            }) { IsBackground = true, Name = "Chat" }.Start();
            if (launch && !launched) game.Launch(gameDir);
        }

        void StartLocalTest()
        {
            StartHost("Host", true);
            Log.W(T("Lancement du second jeu dans 20 s...", "Starting the second game in 20 s..."));
            var t = new System.Windows.Forms.Timer { Interval = autotest ? 8000 : 20000 };
            t.Tick += (s, e) =>
            {
                t.Stop();
                // (tests: MPFEVER_LOCALSTEAM=1, the second game joins through the host's Steam, see SteamNet)
                if (Environment.GetEnvironmentVariable("MPFEVER_LOCALSTEAM") == "1")
                {
                    new Thread(() =>
                    {
                        WaitUntil(() => hostSteamId != null, 600);
                        try { StartClient("Client", "steam:" + (hostSteamId ?? "0"), (int)portBox.Value, true); }
                        catch (Exception ex) { Log.Warn(T("Client local : ", "Local client: ") + ex.Message); }
                    }) { IsBackground = true, Name = "Local client through Steam" }.Start();
                    return;
                }
                try { StartClient("Client", "127.0.0.1", (int)portBox.Value, true); }
                catch (Exception ex) { Log.Warn(T("Client local : ", "Local client: ") + ex.Message); }
                // (0.7.18, tests of three games, e.g. Steam + Epic + GOG: MPFEVER_CLIENT2=1, a third game "Client2", 15 s later;
                // its copy of the game by MPFEVER_GAMEDIR_CLIENT2)
                if (Environment.GetEnvironmentVariable("MPFEVER_CLIENT2") == "1")
                    new Thread(() =>
                    {
                        Thread.Sleep(15000);
                        try { StartClient("Client2", "127.0.0.1", (int)portBox.Value, true); }
                        catch (Exception ex) { Log.Warn(T("Client local : ", "Local client: ") + ex.Message); }
                    }) { IsBackground = true, Name = "Local client 2" }.Start();
            };
            t.Start();
            Log.W(T("Chargez LA MÊME sauvegarde dans les deux jeux, puis cliquez sur « Démarrer la partie ».", "Load THE SAME savegame in both games, then click « Start the game »."));
        }

        // ---------------------------------------------------------------- session status for the in-game MPFever window

        /// <summary>A player's name without the connection number the relay adds (Lena#3 -> Lena).</summary>
        static string BaseName(string n)
        {
            if (n == null) return "";
            int i = n.LastIndexOf('#');
            return i < 0 ? n : n.Substring(0, i);
        }

        static long UnixNow() => (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;

        /// <summary>The host's view of the session: sync state, and every player with its link and how far its game is
        /// behind (steps). Lines "key=value", and "p=id TAB name TAB state TAB lag TAB role" per player, the state being
        /// ok, slow, noresp (no clock for 8 s), loading (resynchronisation), joining (connected, game not ready) or left.</summary>
        string BuildStatus()
        {
            var sb = new System.Text.StringBuilder();
            void Kv(string k, object v) => sb.Append(k).Append('=').Append(Convert.ToString(v, CultureInfo.InvariantCulture).Replace("\r", " ").Replace("\n", " ")).Append('\n');
            bool st, paused; int sp;
            lock (sessionGate) { st = started; paused = pauseAt.HasValue; sp = speed; }
            Kv("v", 1);
            Kv("host", BaseName(hostName));
            // a dedicated server: the in-game window names it and leaves it out of the players
            if (server != null) { Kv("server", 1); Kv("title", server.Name); }
            Kv("mode", companyMode);
            // (0.6) the session's game options: the in-game window's Game tab lists them, the host switches them there
            Kv("opts", GameOptions());
            Kv("started", st ? 1 : 0);
            Kv("speed", paused ? 0 : sp);
            Kv("sync", resyncing ? "resync" : syncState == 1 ? "ok" : syncState == 2 ? "drift" : syncState == 3 ? "desync" : "none");
            Kv("parts", syncParts);
            Kv("age", lastSyncAt < 0 ? -1 : (int)(Now - lastSyncAt));
            Kv("desyncs", desyncs);
            Kv("resyncs", resyncId);
            // (seconds before a resynchronisation may start again: the host's [Resynchronise] button in its game waits that long)
            Kv("resyncin", (int)Math.Ceiling(Math.Max(0, ResyncCooldownSeconds - (Now - lastResync))));
            Kv("invite", steamConnect != null ? 1 : 0);

            string[] ready; lock (players) ready = players.ToArray();
            var connected = relay?.PeerNames() ?? new string[0];
            var away = relay?.AwayNames() ?? new Dictionary<string, double>();
            HashSet<string> waiting; lock (resyncWaiting) waiting = new HashSet<string>(resyncWaiting);
            Dictionary<string, PlayerClock> cl; lock (clocks) cl = new Dictionary<string, PlayerClock>(clocks);
            double lead = cl.Count == 0 ? 0 : cl.Values.Max(Estimate);
            var present = new HashSet<string>();
            void P(string id, string state, long lag)
            {
                present.Add(BaseName(id));
                // (0.7.4: and the percent of the host's game it has received, while one is on its way; empty otherwise)
                int pct = (state == "joining" || state == "loading") ? SendPctOf(id) : -1;
                sb.Append("p=").Append(id).Append('\t').Append(BaseName(id)).Append('\t').Append(state).Append('\t')
                  .Append(lag).Append('\t').Append(id == hostName ? (server != null ? "server" : "host") : "")
                  .Append('\t').Append(pct >= 0 ? pct.ToString(CultureInfo.InvariantCulture) : "").Append('\n');
            }
            if (hostName != null && !ready.Contains(hostName)) P(hostName, "joining", 0);   // the host's own game is loading
            foreach (var n in ready.OrderBy(n => n == hostName ? 0 : 1).ThenBy(n => n, StringComparer.OrdinalIgnoreCase))
            {
                long lag = 0;
                string state = "ok";
                if (cl.TryGetValue(n, out var c))
                {
                    lag = (long)Math.Max(0, Math.Round((lead - Estimate(c)) / Step));
                    if (st && Now - c.At > 8) state = "noresp";
                    else if (st && lag > 10) state = "slow";
                }
                if (resyncing && waiting.Contains(n)) state = "loading";
                // (its connection dropped, the host waits for it: the seconds since)
                if (away.TryGetValue(n, out double awayS)) { state = "away"; lag = (long)awayS; }
                P(n, state, lag);
            }
            foreach (var n in connected.Where(n => !ready.Contains(n)).OrderBy(n => n, StringComparer.OrdinalIgnoreCase)) P(n, "joining", 0);
            lock (leftAt)
            {
                foreach (var k in leftAt.Where(kv => Now - kv.Value > 120).Select(kv => kv.Key).ToList()) leftAt.Remove(k);
                foreach (var kv in leftAt.OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)) if (!present.Contains(kv.Key)) P(kv.Key, "left", 0);
            }
            return sb.ToString();
        }

        // ---------------------------------------------------------------- in-game chat

        int chatReaders;   // the chat reader of the latest client session (a newer join stops the older one)
        readonly List<Msg> chatLog = new List<Msg>();   // the last messages, for players who join later
        long chatId;

        /// <summary>A chat line as players may write it: no control characters, at most 300 characters.</summary>
        static string ChatClean(string s)
        {
            if (s == null) return "";
            var sb = new System.Text.StringBuilder();
            foreach (var ch in s) sb.Append(char.IsControl(ch) ? ' ' : ch);
            var t = sb.ToString().Trim();
            if (t.Length > 300) t = t.Substring(0, char.IsHighSurrogate(t[299]) ? 299 : 300);
            return t;
        }

        /// <summary>The host numbers every chat line (a player's message, or a player who joined or left) and sends it to
        /// every game: its own (chat.txt) and the clients' ("chatmsg").</summary>
        /// <summary>The game builds MPFever was made and checked for (an update of the game changes the engine's code: until
        /// MPFever follows, its fixes may not all work there).</summary>
        static readonly string[] KnownBuilds = { "40408", "40420", "40423", "40425" };   // (40425: the places found by signature, checked 2026-10-24/25)
        readonly HashSet<string> buildsWarned = new HashSet<string>();

        /// <summary>A game ready on a build MPFever does not know (the game was updated): every player is told, once.</summary>
        void WarnUnknownBuild(string payload)
        {
            try
            {
                var h = LuaLit.Parse(payload) as Dictionary<object, object>;
                var build = h != null && h.TryGetValue("build", out var b) ? Convert.ToString(b, CultureInfo.InvariantCulture) : null;
                if (string.IsNullOrEmpty(build) || KnownBuilds.Contains(build)) return;
                lock (buildsWarned) if (!buildsWarned.Add(build)) return;
                var text = F("Transport Fever 3 a été mis à jour (version {0}) : MPFever n'est pas encore adapté à cette version et des désynchronisations peuvent se produire. Une mise à jour de MPFever va suivre.",
                    "Transport Fever 3 was updated (build {0}): MPFever is not adapted to this build yet, and desyncs may happen. An update of MPFever will follow.", build);
                Log.Warn(text);
                HostChat("msg", "MPFever", text);
            }
            catch { }
        }

        /// <summary>A player whose game is another build than the host's (issue #78: one PC updated by Steam, the other not): the
        /// two builds do not simulate the world alike, so the games drift apart by themselves. Said in the chat and the log.</summary>
        readonly Dictionary<string, string> buildOf = new Dictionary<string, string>();
        void WarnOtherBuild(string who, string payload)
        {
            try
            {
                var h = LuaLit.Parse(payload) as Dictionary<object, object>;
                var build = h != null && h.TryGetValue("build", out var b) ? Convert.ToString(b, CultureInfo.InvariantCulture) : null;
                if (string.IsNullOrEmpty(build)) return;
                string hostBuild;
                lock (buildOf)
                {
                    buildOf[BaseName(who)] = build;
                    if (!buildOf.TryGetValue(BaseName(hostName ?? ""), out hostBuild)) return;
                }
                lock (buildOf)
                    foreach (var kv in buildOf.ToList())
                    {
                        if (kv.Value == hostBuild) continue;
                        lock (buildsWarned) if (!buildsWarned.Add("other:" + kv.Key + ":" + kv.Value)) continue;
                        var text = F("{0} a la version {1} de Transport Fever 3, l'hôte la version {2} : deux versions différentes ne simulent pas la partie de la même façon et vont se désynchroniser. Mettez le jeu à jour dans Steam (Propriétés > Fichiers installés > Vérifier l'intégrité) pour avoir la même version.",
                            "{0} has build {1} of Transport Fever 3, the host build {2}: two different builds do not simulate the game alike and will desync. Update the game in Steam (Properties > Installed Files > Verify integrity) to have the same build.", kv.Key, kv.Value, hostBuild);
                        Log.Err(text);
                        HostChat("msg", "MPFever", text);
                    }
            }
            catch { }
        }

        void HostChat(string kind, string name, string text)
        {
            text = ChatClean(text);
            if (kind == "msg" && text.Length == 0) return;
            long id, t = UnixNow();
            Msg m;
            lock (chatLog)
            {
                id = ++chatId;
                m = Msg.Make("chatmsg", hostName ?? "", "{[\"id\"]=" + id + ",[\"t\"]=" + t + ",[\"kind\"]=" + LuaLit.Quote(kind)
                    + ",[\"name\"]=" + LuaLit.Quote(name ?? "") + ",[\"text\"]=" + LuaLit.Quote(text) + "}");
                chatLog.Add(m);
                if (chatLog.Count > 50) chatLog.RemoveAt(0);
            }
            hostGame?.AppendChat(id, t, kind, name, text);
            relay?.Broadcast(m);
            if (kind == "msg") Log.Dim("[chat] " + name + ": " + text);
        }

        /// <summary>Every second: the status to the host's own game (mp_status.txt) and to every client.</summary>
        void PublishStatus()
        {
            var text = BuildStatus();
            // (0.6: the host's own lines, not sent to the players: the arrivals waiting for its answer, kick and ban)
            string own = "";
            try { own = PublicHostStatus(); } catch (Exception e) { Log.W("public game: " + e.Message); }
            hostGame?.WriteStatus(text + own + "me=" + hostName + "\nconn=ok\nattempt=0\nt=" + UnixNow() + "\n");
            relay?.Broadcast(Msg.Make("mpstatus", hostName, "{[\"text\"]=" + LuaLit.Quote(text) + "}"));
        }

        /// <summary>Every host broadcast goes through here so that all games receive messages in the same order.</summary>
        void HostSend(Msg m)
        {
            lock (sendGate)
            {
                hostGame?.ToGame(m);
                relay?.Broadcast(m);
            }
        }

        // ---------------------------------------------------------------- clock and stamps

        double Estimate(PlayerClock c) => c.T + (Now - c.At) * c.Sp * UnitsPerSecond;

        long MaxClock()
        {
            lock (clocks) return clocks.Count == 0 ? 0 : (long)clocks.Values.Max(Estimate);
        }

        static long RoundUpToStep(double t) => (long)Math.Ceiling(t / Step) * Step;

        /// <summary>A stamp every game reaches after receiving the message: ahead of the fastest clock.</summary>
        long FutureStamp()
        {
            int sp; lock (sessionGate) sp = Math.Max(1, speed);
            return RoundUpToStep(MaxClock() + Step * (4 + 2 * sp));
        }

        /// <summary>"shared" (everybody plays the same company) or "separate" (one company per player), chosen by the host
        /// when it hosts (MPFEVER_COMPANIES=separate for the developer tests).</summary>
        string companyMode = Environment.GetEnvironmentVariable("MPFEVER_COMPANIES") == "separate" ? "separate" : "shared";

        /// <summary>Months in debt before a company goes bankrupt (one company per player, 0.5.0): MPFEVER_BANKRUPT, else the
        /// host's choice in the lobby (setting bankrupt=), else 12; 0: never. One of 0, 3, 6, 12, 24.</summary>
        string BankruptMonths()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_BANKRUPT");
            // (0.7.0) a dedicated server: bankruptcy-months of its settings
            if (string.IsNullOrEmpty(v) && server != null) v = server.BankruptMonths.ToString(CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(v)) LoadSettings().TryGetValue("bankrupt", out v);
            return int.TryParse(v ?? "", NumberStyles.Integer, CultureInfo.InvariantCulture, out int n) && (n == 0 || n == 3 || n == 6 || n == 12 || n == 24)
                ? n.ToString(CultureInfo.InvariantCulture) : "12";
        }

        /// <summary>(0.7.4) The auction of a bankrupt company (one company per player), "mode:minutes": every lot at once
        /// ("assets", the default), the whole company in one lot ("company"), or one lot after the other as in 0.7.3 ("serial");
        /// 3, 5 or 10 minutes. MPFEVER_AUCTION, else the host's choice (setting auction=), else "assets:5"; MPFEVER_OLDAUCTION=1:
        /// "serial", as before.</summary>
        internal static string AuctionRuleOf(string env, string old, string saved)
        {
            if (old == "1") return "serial:5";
            foreach (var v in new[] { env, saved })
                if (ValidAuction(v)) return v;
            return "assets:5";
        }
        internal static bool ValidAuction(string v)
        {
            if (string.IsNullOrEmpty(v)) return false;
            var p = v.Split(':');
            return p.Length == 2 && (p[0] == "assets" || p[0] == "company" || p[0] == "serial") && (p[1] == "3" || p[1] == "5" || p[1] == "10");
        }
        string AuctionRule()
        {
            LoadSettings().TryGetValue("auction", out var saved);
            return AuctionRuleOf(Environment.GetEnvironmentVariable("MPFEVER_AUCTION"), Environment.GetEnvironmentVariable("MPFEVER_OLDAUCTION"), saved);
        }

        /// <summary>Starting capital of a new company: MPFEVER_COMPANY_START, else (dedicated server) start-money in
        /// mpfever_server.properties, else companystart=N in mpfever_settings.txt, else 2,000,000.</summary>
        string StartMoney()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_COMPANY_START");
            if (string.IsNullOrEmpty(v) && server != null) v = server.StartMoney.ToString(CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(v)) LoadSettings().TryGetValue("companystart", out v);
            return long.TryParse(v ?? "", out long n) && n >= 0 ? n.ToString() : "2000000";
        }

        /// <summary>The sharing rules between companies (0.5.14, one company per player): "1" on (each company's rules for its
        /// tracks, stations, stops and depots), "0" off (everything open and free). MPFEVER_SHARE, else (dedicated server)
        /// sharing-rules in mpfever_server.properties, else share= in mpfever_settings.txt (the host's choice), else on.</summary>
        string ShareRules()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_SHARE");
            if (string.IsNullOrEmpty(v) && server != null) v = server.ShareRules ? "1" : "0";
            if (string.IsNullOrEmpty(v)) LoadSettings().TryGetValue("share", out v);
            return v == "0" ? "0" : "1";
        }

        /// <summary>The session's game options (0.6, see GameOpts and docs/FEATURES-0.6.md): (dedicated server) game-options in
        /// mpfever_server.properties, else gameopts= in mpfever_settings.txt (the host's last choice, or its savegame's), else none.</summary>
        string GameOptions()
        {
            string v = server != null ? server.GameOptions : null;
            if (v != null) return GameOpts.Canon(v);
            var test = gameOptsTest;
            if (test != null) return GameOpts.Canon(test);
            // (kept in memory: read every second by the status, the session and the public games)
            return KeptGameOptions();
        }

        // (0.6) the savegame's game options in the lobby: lobbyGen counts the lobbies opened, saveOptsGen is the last one whose
        // savegame's options were settled (taken, or none to take), lobbyOptsAtOpen the options when it opened. MPFEVER_SAVEOPTS=0:
        // never read from the savegame (the host's last choice only; no decompression of a savegame in a co-op lobby, as in 0.5.14)
        readonly object saveOptsLock = new object();
        int lobbyGen, saveOptsGen = -1;
        string lobbyOptsAtOpen = "";
        static bool SaveOptsOff => Environment.GetEnvironmentVariable("MPFEVER_SAVEOPTS") == "0" || Environment.GetEnvironmentVariable("MPFEVER_FEAT") == "0";

        /// <summary>(0.6) What the lobby takes of its savegame's options: the savegame's (canon), or null to keep the session's. None
        /// when the savegame has none (no option was ever on in it), or when the host chose other options since the lobby opened
        /// (its choice, made while the savegame was read, wins).</summary>
        internal static string SaveOptsToTake(string saveOpts, string now, string atOpen)
        {
            if (saveOpts == null || now != atOpen) return null;
            var o = GameOpts.Canon(saveOpts);
            return o == now ? null : o;
        }

        /// <summary>(the host) the game options a savegame was played with (the text "mpfopts:...;" its game keeps, see mpfever_feat.lua's
        /// applyOpts), read when a lobby opens on it: the lobby starts with them. A savegame without them leaves the host's last choice.
        /// Once per lobby (gen): from the reading of the lobby's savegame, or from StartLobbyGame when the host starts before it ended
        /// (then before the session carries the options: the game would otherwise switch the savegame's off).</summary>
        void ApplySaveOpts(int gen, string saveOpts)
        {
            string o;
            lock (saveOptsLock)
            {
                if (gen != lobbyGen || saveOptsGen == gen || !lobbyOpen) return;
                saveOptsGen = gen;
                var now = GameOptions();
                o = SaveOptsToTake(saveOpts, now, lobbyOptsAtOpen);
                if (saveOpts != null && now != lobbyOptsAtOpen) Log.W("savegame options: the host chose others meanwhile, its choice kept");
                if (o == null) return;
                SaveSetting("gameopts", o);
            }
            Log.W(F("Options de partie de la sauvegarde reprises : {0}", "The savegame's game options taken again: {0}", o == "" ? T("aucune", "none") : o));
            BroadcastLobby();
            MenuStatus();
        }

        /// <summary>(the host) the game's rules of a savegame, read from it when a lobby opens on it (0.5.14: the text "mpfrules:..."
        /// the game keeps, see mpfever_eco.lua's co_rules): the lobby starts with them. A savegame without them leaves the host's
        /// last choices.</summary>
        void LoadSaveRules(string save, Dictionary<string, string> r)
        {
            if (r == null || lobbySave != save || !lobbyOpen) return;
            var said = new List<string>();
            if (r.TryGetValue("bankrupt", out var b) && int.TryParse(b, NumberStyles.Integer, CultureInfo.InvariantCulture, out int mo) && (mo == 0 || mo == 3 || mo == 6 || mo == 12 || mo == 24))
            { SaveSetting("bankrupt", b); said.Add(F("faillite {0}", "bankruptcy {0}", mo == 0 ? T("jamais", "never") : mo + T(" mois", " months"))); }
            // (0.7.4) the auction of a bankrupt company
            if (r.TryGetValue("auction", out var au) && ValidAuction(au))
            { SaveSetting("auction", au); said.Add(F("enchères {0}", "auction {0}", au)); }
            if (r.TryGetValue("share", out var sh) && (sh == "0" || sh == "1"))
            { SaveSetting("share", sh); said.Add(sh == "1" ? T("règles de partage activées", "sharing rules on") : T("règles de partage désactivées", "sharing rules off")); }
            if (r.TryGetValue("start", out var s0) && long.TryParse(s0, NumberStyles.Integer, CultureInfo.InvariantCulture, out long st0) && st0 >= 0)
            { SaveSetting("companystart", st0.ToString(CultureInfo.InvariantCulture)); said.Add(F("argent de départ {0:N0}", "start money {0:N0}", st0)); }
            // (the computer companies of the savegame, already in the lobby: their level and start money, "n:colour:level[:money],...")
            if (r.TryGetValue("ai", out var ais) && ais != "")
            {
                int n0 = 0;
                foreach (var part in ais.Split(','))
                {
                    var f = part.Split(':');
                    if (f.Length < 3 || !int.TryParse(f[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int n)
                        || !int.TryParse(f[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out int lv) || lv < 1 || lv > 3) continue;
                    long aiMoney = -1;
                    if (f.Length >= 4 && (!long.TryParse(f[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out aiMoney) || aiMoney < -1)) aiMoney = -1;
                    lock (lobbyAi) { if (lobbyAi.TryGetValue(n, out var a)) { a.Level = lv; a.Money = aiMoney; n0++; } }
                }
                if (n0 > 0) said.Add(F("{0} entreprise(s) de l'ordinateur avec leur niveau", "{0} computer company(ies) with their level", n0));
            }
            if (said.Count > 0) Log.W(F("Règles de la sauvegarde reprises : {0}", "The savegame's rules taken again: {0}", string.Join(", ", said)));
        }

        string SessionPayload()
        {
            lock (sessionGate)
                return "{[\"started\"]=" + (started ? "true" : "false") + ",[\"speed\"]=" + speed +
                       (pauseAt.HasValue ? ",[\"pauseAt\"]=" + pauseAt.Value : "") +
                       ",[\"cmode\"]=\"" + companyMode + "\"" +
                       (companyMode == "separate" ? ",[\"cstart\"]=" + StartMoney() + ",[\"bankrupt\"]=" + BankruptMonths() + ",[\"share\"]=" + (ShareRules() == "1" ? "true" : "false")
                           + ",[\"auction\"]=" + LuaLit.Quote(AuctionRule()) : "") +
                       // the computer companies the host's game runs (its lobby's choice, "n:colour,...")
                       (AiPayload() != "" ? ",[\"ai\"]=" + LuaLit.Quote(AiPayload()) : "") +
                       // a dedicated server plays no company: the savegame's company goes to its owner (owner=, else nobody)
                       (companyMode == "separate" && server != null ? ",[\"owner\"]=" + LuaLit.Quote(OwnerKey()) : "") +
                       // (0.6) the game options, in both company modes: the host's game puts them into the game (f_opts), every game
                       // applies them at the same step; empty: all off, as 0.5.14
                       ",[\"opts\"]=" + LuaLit.Quote(GameOptions()) +
                       // a resynchronisation is under way: every game refuses its player's builds until it ends (issue #81: a player
                       // whose game had already loaded the host's built a station there, which the others never received)
                       (resyncDropping ? ",[\"resync\"]=true" : "") + "}";
        }

        void BroadcastSession() => HostSend(Msg.Make("session", hostName ?? "Host", SessionPayload()));

        void StartSession()
        {
            List<long> times; int n;
            lock (clocks) times = clocks.Values.Select(c => c.T).Distinct().ToList();
            lock (players) n = players.Count;
            if (n < 1) { Log.Warn(T("Aucun jeu prêt.", "No game is ready.")); return; }
            // a game often runs a few steps after loading before it pauses (issue #4): up to 10 steps apart is the same
            // savegame. The session pauses at the earliest time, as when the games overshoot a pause: the first check is
            // taken at the latest, and the games behind catch up to it.
            if (times.Count > 1 && times.Max() - times.Min() > 10 * Step) { Log.Warn(T("Les jeux ne sont pas au même temps (", "The games are not at the same time (") + string.Join(", ", times) + T(") : chargez exactement la même sauvegarde partout.", "): load exactly the same savegame everywhere.")); return; }
            lock (sessionGate) { started = true; speed = 0; pauseAt = times.Count > 0 ? times.Min() : (long?)null; }
            Log.W(F("=== Partie démarrée avec {0} jeu(x) au temps {1} : vérification initiale... ===", "=== Game started with {0} game(s) at time {1}: initial check... ===", n, times.FirstOrDefault()));
            BroadcastSession();
            // every game just loaded the same savegame: a part already different now is a local measure
            postResyncHashN = hashN + 1;
            RequestHash();
            new Thread(() =>
            {
                Thread.Sleep(1500);
                // a dedicated server starts at its own speed, or stays paused while nobody is connected
                if (server != null && ServerStartsPaused()) return;
                if (recplayStart) return;
                SetSpeed(server != null ? server.StartSpeed : 1, T("démarrage", "start"));
            }) { IsBackground = true }.Start();
        }

        void SetSpeed(int s, string who)
        {
            if (!started) return;
            // (a resynchronisation holds the games paused until it ends: a speed asked meanwhile, by a player or by the start of the
            // session 1.5 s after it, cleared that pause and the resynchronisation waited for nothing; a player joining then never
            // got the host's game)
            if (resyncing) { Log.W(F("Vitesse x{0} demandée par {1} : ignorée pendant la resynchronisation", "Speed x{0} asked by {1}: ignored during the resynchronisation", s, who)); return; }
            lock (sessionGate) { speed = Math.Max(1, Math.Min(4, s)); pauseAt = null; }
            Log.W(F("Vitesse : x{0} (demandée par {1})", "Speed: x{0} (asked by {1})", speed, who));
            BroadcastSession();
        }

        void Pause(string who)
        {
            if (!started) return;
            long at = FutureStamp();
            lock (sessionGate) pauseAt = at;
            Log.W(F("Pause au temps {0} (demandée par {1})", "Pause at time {0} (asked by {1})", at, who));
            BroadcastSession();
        }

        void RequestHash()
        {
            int n = Interlocked.Increment(ref hashN);
            lock (hashes) hashes[n] = new Dictionary<string, Dictionary<object, object>>();
            long? p; lock (sessionGate) p = pauseAt;
            // (0.7.7: after a difference, this check's dump whole on every game, see WantsWorldDump; MPFEVER_SDUMPAFTER=0: not)
            string world = "";
            if (worldDumpNext) { worldDumpNext = false; if (Environment.GetEnvironmentVariable("MPFEVER_SDUMPAFTER") != "0") world = ",[\"world\"]=true"; }
            if (p.HasValue && MaxClock() >= p.Value)
            {
                // the games may have stopped a batch apart: the check is taken at the latest of their times (the others
                // catch up to it)
                long at; lock (clocks) at = Math.Max(p.Value, clocks.Count == 0 ? 0 : clocks.Values.Max(c => c.T));
                HostSend(Msg.Make("hash", hostName, "{[\"n\"]=" + n + ",[\"at\"]=" + at + ",[\"paused\"]=true" + world + "}"));
            }
            else
                HostSend(Msg.Make("hash", hostName, "{[\"n\"]=" + n + ",[\"at\"]=" + FutureStamp() + world + "}"));
        }

        // (0.7.7) set by a check that found the simulation apart: the next check's dump is whole on every game
        volatile bool worldDumpNext;

        /// <summary>(0.7.7) Whether a part that differs asks for the whole dump at the next check: the simulation's parts, not money
        /// (corrected from the host at once), the names (a language's default names) nor the diagnostic ones.</summary>
        internal static bool WantsWorldDump(string part) =>
            !string.IsNullOrEmpty(part) && part != "money" && part != "names" && part != "loans" && !DiagnosticParts.Contains(part);

        void HostLoop(int gen)
        {
            double lastHash = Now, lastSession = Now, lastStatus = 0;
            int actsAtHash = actsRelayed;
            while (gen == sessionGen)
            {
                Thread.Sleep(250);
                if (hostGame == null) continue;
                foreach (var line in hostGame.ReadChatOut()) HostChat("msg", BaseName(hostName), line);
                if (Now - lastStatus >= 1)
                {
                    lastStatus = Now;
                    try { PublishStatus(); statusFailed = false; }
                    catch (Exception e) { if (!statusFailed) Log.W("mp_status: " + e.Message); statusFailed = true; }
                }
                PlayerClock hc;
                lock (clocks) clocks.TryGetValue(hostName, out hc);

                if (Now - lastSession > 3) { lastSession = Now; BroadcastSession(); }   // late joiners and lost messages
                HostAutosaveTick();   // (0.7.7, a player's own game hosting: the session's autosave at a pause of every game)
                bool paused; long? pausedAt; lock (sessionGate) { paused = pauseAt.HasValue; pausedAt = pauseAt; }
                // paused: builds and actions still apply, so the games are checked when actions went through since the last
                // check, once every game has stopped (issue #12: 9 minutes of builds in a pause went unchecked)
                // (every game at the same time and no action for 5 s: a check taken while an action is still on its way to a
                // game is a false difference, and its money would be corrected wrongly)
                bool allStopped; lock (clocks) allStopped = clocks.Count > 0 && clocks.Values.Select(c => c.T).Distinct().Count() == 1;
                bool pausedWork = paused && actsRelayed != actsAtHash && pausedAt.HasValue && MaxClock() >= pausedAt.Value
                    && allStopped && Now - lastActRelayed > 5;
                if (started && (!paused || pausedWork) && !detRunning && !resyncing && Now - lastHash > HashEverySeconds)
                {
                    lastHash = Now; actsAtHash = actsRelayed; RequestHash();
                }
            }
        }

        // ---------------------------------------------------------------- host-side message handling

        // What only the host sends (its savegame, mods, lobby, settings, chat, status, resynchronisations, checks): from a player it is never passed on.
        // Relayed, a player could have sent the others a mod (code) or a savegame in the host's place.
        static readonly HashSet<string> HostOnlyKinds = new HashSet<string> { "modfile", "modoffer", "resync_file", "resync_bin",
            "resync_use", "delta_bin", "lobby", "mpstatus", "chatmsg", "welcome", "session", "peerclock", "auth", "aijournal", "namesync",
            "resync_save", "resync_load", "hash", "peerleft", "solo", "det_run", "test_save", "census_now", "tomenu", "camtour", "area_dump",
            "report_req", "report_plan" };
        DateTime hostOnlyWarned;

        void OnHostMessage(Msg m, Peer from)
        {
            if (from != null && HostOnlyKinds.Contains(m.Kind) && Environment.GetEnvironmentVariable("MPFEVER_HOSTONLY") != "0")
            {
                if (DateTime.UtcNow - hostOnlyWarned > TimeSpan.FromSeconds(10))
                {
                    hostOnlyWarned = DateTime.UtcNow;
                    Log.Warn(F("{0} a envoyé un message « {1} » que seul l'hôte envoie : ignoré.", "{0} sent a « {1} » message only the host sends: ignored.", m.From, m.Kind));
                }
                return;
            }
            // a dedicated server: a player whose game is not in this session's world yet (it reconnected after a restart of
            // the server, still in its old world) only counts once its game has loaded the server's world: its clock,
            // actions and checks are those of another world
            // (0.7.0: but its word after the join review, and its DLCs, come before its game loads: they are about joining)
            if (server != null && from != null && m.Kind != "hello" && m.Kind != "chat" && m.Kind != "joinready" && m.Kind != "dlccheck" && m.Kind != "buildcheck")
            {
                bool ready; lock (players) ready = players.Contains(m.From);
                if (!ready) return;
            }
            // (0.7.9) a player's report asked for, or sent to whoever asked: never passed on to every game (see ReportShare)
            if (OnHostReportMessage(m, from)) return;
            // (0.8.4, #263) a player's game crashed: never passed on to the games; the session is told to send reports now
            if (m.Kind == "game_crashed") { if (from != null) OnPlayerCrashed(BaseName(from.Name)); return; }
            switch (m.Kind)
            {
                case "hello":
                    lock (players) players.Add(m.From);
                    WarnModVersion(m.From, m.Payload);
                    WarnNative(m.From, m.Payload);
                    // (0.7.4, MODRETRY: the server's world is loaded, its mods were all there)
                    if (m.From == hostName) serverModRetries = 0;
                    Log.W(F("{0} : jeu prêt {1}", "{0}: game ready {1}", m.From, m.Payload));
                    WarnUnknownBuild(m.Payload);
                    WarnOtherBuild(m.From, m.Payload);
                    // a game started again (resynchronisation): it needs its identity again
                    if (from != null) relay.Send(from, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(from.Name) + ",[\"role\"]=\"client\",[\"v\"]=" + LuaLit.Quote(Version) + ",[\"run\"]=" + LuaLit.Quote(myRun) + ",[\"opts\"]=" + LuaLit.Quote(Options.SessionPayload()) + ",[\"mods\"]=" + LuaLit.Quote(lobbyMods) + ",[\"dlcs\"]=" + LuaLit.Quote(SessionDlcs()) + ",[\"gbuild\"]=" + LuaLit.Quote(Reporter.BuildTag(gameDir))
                        + ",[\"rtok\"]=" + LuaLit.Quote(from.Link?.Token ?? "") + (hostSteamId != null ? ",[\"sid\"]=" + LuaLit.Quote(hostSteamId) : "") + "}"));
                    // (a player who reconnected during the resynchronisation answers under its new name: Philippe#2 for Philippe#1)
                    lock (resyncWaiting) resyncWaiting.RemoveWhere(w => w == m.From || BaseName(w) == BaseName(m.From));
                    if (from != null && server != null) ServerGreet(from);
                    // (0.7.13, #161/#166: the host's game's memory once loaded, see GameLink.LogMemoryNow; aside, the game's messages go on)
                    if (from == null && hostGame != null) { var hg = hostGame; ThreadPool.QueueUserWorkItem(_ => hg.LogMemoryNow("game ready")); }
                    break;

                case "modcheck":
                    {
                        // a player's mods compared with the host's (see SetHostMods): shown next to its name in the lobby
                        if (from == null) break;
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        var differs = h.TryGetValue("differs", out var dv) && dv is string ds ? ds : "";
                        lock (modIssues) { if (differs != "") modIssues[BaseName(from.Name)] = differs; else modIssues.Remove(BaseName(from.Name)); }
                        var nohub = h.TryGetValue("nohub", out var nv) && nv is string ns ? ns : "";
                        lock (modAsks)
                        {
                            // (only mods of this savegame installed here: nothing else is ever sent)
                            var ids = nohub.Split(',').Select(x => x.Trim()).Where(x => x != "" && Mods.Dir(x) != null && Mods.Parse(lobbyMods).Any(e => e.Id.Equals(x, StringComparison.OrdinalIgnoreCase))).ToList();
                            // (0.6.7) a missing mod this PC cannot send is said, never dropped silently (the host saw nothing on 2026-11-01)
                            var unsendable = nohub.Split(',').Select(x => x.Trim()).Where(x => x != "" && !ids.Contains(x)).ToList();
                            if (unsendable.Count > 0)
                                Log.Err(F("{0} n'a pas ces mods de la partie et ce PC ne les trouve pas pour les lui envoyer : {1} (cherchés dans les mods, staging_area, mod.io, Steam Workshop et le jeu). Ce joueur ne pourra pas charger la partie.",
                                    "{0} lacks these mods of the game and this PC cannot find them to send them: {1} (looked for in mods, staging_area, mod.io, Steam Workshop and the game). That player cannot load the game.", BaseName(from.Name), string.Join(", ", unsendable)));
                            if (ids.Count > 0 && !modAskDone.ContainsKey(from.Name))
                            {
                                modAsks[from.Name] = string.Join(",", ids);
                                Log.Warn(F("{0} n'a pas {1} mod(s) qu'aucun Mod Hub n'a : {2}. Vous pouvez les lui envoyer depuis la page Multijoueur.", "{0} lacks {1} mod(s) no Mod Hub has: {2}. You can send them from the Multiplayer page.", BaseName(from.Name), ids.Count, string.Join(", ", ids)));
                            }
                            else if (ids.Count == 0) modAsks.Remove(from.Name);
                        }
                        if (differs != "") Log.Warn(F("{0} n'a pas la même version que vous de ces mods : {1}. Il ne pourra pas charger la partie tant qu'il ne les a pas mis à jour.", "{0} does not have your version of these mods: {1}. They cannot load the game until they update them.", BaseName(from.Name), differs));
                        BroadcastLobby();
                        MenuStatus();
                    }
                    break;

                case "buildcheck":
                    {
                        // (0.7.7) a player's game build compared with the host's (see CheckHostBuild): in the log and the lobby
                        if (from == null || Environment.GetEnvironmentVariable("MPFEVER_BUILDWARN") == "0") break;
                        var hb = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        var theirB = hb.TryGetValue("gbuild", out var gv) && gv is string gs ? gs : "";
                        var whoB = BaseName(from.Name);
                        var warnB = BuildWarning(whoB, Reporter.BuildTag(gameDir), theirB);
                        bool changedB;
                        lock (buildIssues)
                        {
                            buildIssues.TryGetValue(whoB, out var wasB);
                            changedB = (wasB ?? "") != warnB;
                            if (warnB != "") buildIssues[whoB] = warnB; else buildIssues.Remove(whoB);
                        }
                        if (changedB && warnB != "") Log.Err(warnB);
                        if (changedB) { BroadcastLobby(); MenuStatus(); }
                    }
                    break;

                case "dlccheck":
                    {
                        // (0.6.9) a player's DLCs compared with the host's (see CheckHostDlcs): said in the log and in the lobby
                        if (from == null) break;
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        var theirs = h.TryGetValue("dlcs", out var dv) && dv is string dls ? dls : "";
                        var who = BaseName(from.Name);
                        lock (playerDlcs) playerDlcs[who] = theirs;
                        var warn = Mods.DlcWarning(who, SessionDlcs(), theirs);
                        bool changed;
                        lock (dlcIssues)
                        {
                            dlcIssues.TryGetValue(who, out var was);
                            changed = (was ?? "") != warn;
                            if (warn != "") dlcIssues[who] = warn; else dlcIssues.Remove(who);
                        }
                        if (changed && warn != "") Log.Err(warn);
                        if (changed) { BroadcastLobby(); MenuStatus(); }
                    }
                    break;

                case "modmissing":
                    {
                        // (0.6.7) a player's game did not load the host's game: mods of it are missing there
                        if (from == null) break;
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        var mm = h.TryGetValue("mods", out var mv) && mv is string ms2 ? ms2 : "";
                        Log.Err(F("{0} n'a pas pu charger la partie, mods manquants chez lui : {1}", "{0} could not load the game, mods missing there: {1}", BaseName(from.Name), mm));
                    }
                    break;

                case "modaccept":
                    {
                        // the player takes the mods the host offered: sent to it alone
                        if (from == null) break;
                        string ids; lock (modAsks) { modAskDone.TryGetValue(from.Name, out ids); }
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        bool yes = h.TryGetValue("yes", out var yv) && yv is bool yb && yb;
                        if (!yes) { Log.W(F("{0} ne prend pas les mods proposés.", "{0} does not take the mods offered.", BaseName(from.Name))); modSendText = F("{0} ne prend pas les mods.", "{0} does not take the mods.", BaseName(from.Name)); MenuStatus(); break; }
                        if (ids == null || !ids.StartsWith("offered:")) break;
                        var list = ids.Substring(8).Split(',').Where(x => x != "").ToList();
                        lock (modAsks) modAskDone[from.Name] = "sent";
                        var peer = from;
                        new Thread(() => SendMods(peer, list)) { IsBackground = true, Name = "Send mods" }.Start();
                    }
                    break;

                case "lobbycolor":
                    {
                        if (from == null || !lobbyOpen) break;
                        var lc = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        int ix = lc.TryGetValue("ix", out var iv) && iv is double id ? (int)id : 0;
                        if (ix >= 1 && ix <= 12) SetLobbyColor(BaseName(from.Name), ix);
                    }
                    break;

                case "savehave":
                    {
                        // (a player) whether it has the lobby's savegame already (its fingerprint): then nothing is sent to it
                        if (from == null) break;
                        var sh = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        string hsha = sh.TryGetValue("sha", out var sv) && sv is string ss ? ss : "";
                        bool has = sh.TryGetValue("have", out var hv) && hv is bool hb && hb;
                        lock (saveHave) { if (has && hsha != "") saveHave[BaseName(from.Name)] = hsha; else saveHave.Remove(BaseName(from.Name)); }
                        Log.W(has ? F("{0} a déjà la sauvegarde du salon : elle ne lui sera pas envoyée.", "{0} already has the lobby's savegame: it will not be sent to them.", from.Name)
                                  : F("{0} n'a pas la sauvegarde du salon : elle lui sera envoyée au lancement.", "{0} does not have the lobby's savegame: it will be sent to them at the start.", from.Name));
                    }
                    break;

                case "savebase":
                    {
                        // (a player) the host's game it loaded last (its fingerprint): the base of the next one's differences
                        if (from == null) break;
                        var sb = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        string bsha = sb.TryGetValue("sha", out var bv) && bv is string bs ? bs : "";
                        lock (peerBase) { if (bsha != "") peerBase[BaseName(from.Name)] = bsha; else peerBase.Remove(BaseName(from.Name)); }
                    }
                    break;

                case "resync_need":
                    {
                        // (a player told to use its own copy, which it does not find any more): it gets the game after all
                        if (from == null) break;
                        var bytes = resyncBytes;
                        var nd = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        int nid = nd.TryGetValue("id", out var niv) && niv is double nn ? (int)nn : 0;
                        if (bytes == null || nid != resyncBytesId) break;
                        lock (saveHave) saveHave.Remove(BaseName(from.Name));
                        SendSave(nid, bytes, resyncBytesSha ?? Sha256(bytes), new[] { from.Name });
                    }
                    break;

                case "joinready":
                    {
                        // (0.7.0) a player who looked at the game's mods and DLCs (see the join review) joins: it gets the game now
                        if (from == null) break;
                        bool was;
                        lock (reviewing) was = reviewing.Remove(from.Name);
                        if (!was) break;
                        var jr = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        bool asked = jr.TryGetValue("asked", out var av) && av is bool ab && ab;
                        Log.Ok(asked ? F("{0} a vérifié les mods et les DLC : il rejoint la partie", "{0} checked the mods and DLCs: they join the game", BaseName(from.Name))
                                     : F("{0} a les mêmes mods et DLC : il rejoint la partie", "{0} has the same mods and DLCs: they join the game", BaseName(from.Name)));
                        var bytesNow = resyncBytes;
                        string jd = JoinDuringResync(resyncing, bytesNow != null, resyncSending, resyncBytesId, saveCancel,
                            Environment.GetEnvironmentVariable("MPFEVER_JOINMIDRESYNC") == "0");
                        if (jd == "pending") joinPending = true;
                        else if (jd == "send")
                        {
                            lock (resyncWaiting) { resyncWaiting.RemoveWhere(w => BaseName(w) == BaseName(from.Name)); resyncWaiting.Add(from.Name); }
                            Log.W(F("{0} rejoint pendant la resynchronisation : la partie lui est envoyée aussi", "{0} joins during the resynchronisation: the game is sent to them too", BaseName(from.Name)));
                            SendSave(resyncBytesId, bytesNow, resyncBytesSha ?? Sha256(bytesNow), new[] { from.Name });
                        }
                        MenuStatus();
                    }
                    break;

                case "resync_have":
                    {
                        // a player back after a cut while the host's game was being sent: only its missing parts (issue #60);
                        // anything else (another game, nothing received) is a new player: a resynchronisation, as before
                        if (from == null) break;
                        var h = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        int hid = h.TryGetValue("id", out var hiv) && hiv is double hd ? (int)hd : 0;
                        var bytes = resyncBytes;
                        if (!resyncing) break;
                        // (nothing to resume while the resynchronisation has not listed its games yet, often the one this
                        // player's arrival started: it is listed with them and receives the host's game then. Counted as
                        // another new player, it got a second whole resynchronisation right after: a test, 185 s then 161 s)
                        if (hid == 0 && !resyncSending) break;
                        if (bytes == null || hid != resyncBytesId || hid == 0 || !(h.TryGetValue("missing", out var mv) && mv is string ms))
                        {
                            joinPending = true;
                            break;
                        }
                        int parts = (bytes.Length + ResyncChunk - 1) / ResyncChunk;
                        int upTo = resyncSentUpTo;
                        var miss = ms.Split(',').Select(x => int.TryParse(x, out int k) ? k : -1).Where(k => k >= 0 && k < parts && k < upTo).ToArray();
                        Log.W(F("{0} : de retour pendant l'envoi de la partie, {1} morceau(x) sur {2} renvoyé(s)", "{0}: back while the game was being sent, {1} part(s) of {2} sent again", from.Name, miss.Length, parts));
                        lock (resyncWaiting) { resyncWaiting.RemoveWhere(w => BaseName(w) == BaseName(from.Name)); resyncWaiting.Add(from.Name); }
                        string rsha = resyncBytesSha ?? "";
                        new Thread(() =>
                        {
                            foreach (int k in miss)
                            {
                                int len = Math.Min(ResyncChunk, bytes.Length - k * ResyncChunk);
                                if (relay == null || !relay.TrySend(from, Msg.MakeBinary("resync_bin", hostName,
                                    "[\"id\"]=" + hid + ",[\"i\"]=" + k + ",[\"n\"]=" + parts + ",[\"sha\"]=" + LuaLit.Quote(rsha), bytes, k * ResyncChunk, len))) break;
                            }
                        }) { IsBackground = true, Name = "Resync resume" }.Start();
                    }
                    break;

                case "replay_failed":
                    {
                        // a game could not reproduce a build of another player: the games differ for sure, no need to wait
                        // for the next checkpoints (and for the long cooldown) before reloading the host's game
                        Log.Warn(F("{0} : une construction n'a pas pu être reproduite {1}", "{0}: a build could not be reproduced {1}", m.From, m.Payload));
                        int others; lock (players) others = players.Count(p => p != hostName);
                        // (0.7.7) a build refused on every game, its builder's own replay too (a computer company's builds are
                        // replayed on the host's game as well): the games did not part, nobody built it. A garage of the AI
                        // refused everywhere (Test Gameplay, 2026-11-08 01:30) reloaded every game for nothing, and in the
                        // autotests (no reload) the players' games left the next builds out, waiting for a reload that never
                        // came. The reports are waited for 1.5 s, as before; refused everywhere, every game is told
                        // (replay_alike) and nothing is reloaded. MPFEVER_FAILALIKE=0: reloaded as before
                        string fuid = FailedUid(m.Payload);
                        bool alikeOn = Environment.GetEnvironmentVariable("MPFEVER_FAILALIKE") != "0" && fuid != null;
                        bool first = false;
                        if (alikeOn)
                            lock (failedBy)
                            {
                                if (!failedBy.TryGetValue(fuid, out var who)) { failedBy[fuid] = who = new HashSet<string>(StringComparer.OrdinalIgnoreCase); first = true; }
                                who.Add(BaseName(m.From));
                                while (failedBy.Count > 64) failedBy.Remove(failedBy.Keys.First());
                            }
                        if (alikeOn && first)
                        {
                            new Thread(() =>
                            {
                                Thread.Sleep(1500);
                                HashSet<string> who; lock (failedBy) who = failedBy.TryGetValue(fuid, out var w) ? new HashSet<string>(w, StringComparer.OrdinalIgnoreCase) : new HashSet<string>();
                                string[] all; lock (players) all = players.ToArray();
                                bool everywhere = RefusedEverywhere(fuid, who, all.Select(BaseName));
                                // (0.7.17, #193: BaumEdePiep's vehicle sold twice, 20:43) the three games refused the second sale alike,
                                // but their reports came 19.0, 21.0 and 21.7 s: after 1.5 s only one had come, and every game was
                                // reloaded for nothing. The reports are now waited for up to 5 s in all (looked at every 0.25 s); a
                                // build refused on one game only still reloads, 3.5 s later at most. MPFEVER_FAILWAIT=0: 1.5 s, as before
                                if (!everywhere && Environment.GetEnvironmentVariable("MPFEVER_FAILWAIT") != "0")
                                    for (int fw = 0; fw < FailWaitTicks && !everywhere; fw++)
                                    {
                                        Thread.Sleep(250);
                                        lock (failedBy) who = failedBy.TryGetValue(fuid, out var w2) ? new HashSet<string>(w2, StringComparer.OrdinalIgnoreCase) : new HashSet<string>();
                                        lock (players) all = players.ToArray();
                                        everywhere = RefusedEverywhere(fuid, who, all.Select(BaseName));
                                    }
                                if (everywhere)
                                {
                                    Log.Ok(F("{0} : refusée sur tous les jeux, celui de son constructeur aussi : les parties sont restées identiques, pas de resynchronisation",
                                        "{0}: refused on every game, its builder's too: the games stayed alike, no resynchronisation", fuid));
                                    var alike = Msg.Make("replay_alike", hostName ?? "", "{[\"uid\"]=" + LuaLit.Quote(fuid) + "}");
                                    lock (sendGate) { hostGame?.ToGame(alike); relay.Broadcast(alike, null); }
                                    return;
                                }
                                int oth; lock (players) oth = players.Count(p => p != hostName);
                                if (started && !resyncing && !autotest && oth > 0 && Now - lastResync > 15)
                                {
                                    resyncing = true;
                                    Resync(T("construction non reproduite", "build not reproduced"));
                                }
                            }) { IsBackground = true, Name = "Resync" }.Start();
                        }
                        else if (!alikeOn && started && !resyncing && !autotest && others > 0 && Now - lastResync > 15)
                        {
                            resyncing = true;
                            new Thread(() => { Thread.Sleep(1500); Resync(T("construction non reproduite", "build not reproduced")); }) { IsBackground = true, Name = "Resync" }.Start();
                        }
                        break;
                    }

                case "save_done":
                    {
                        // a save of a dedicated server's world (its own numbers), not the save of a resynchronisation
                        var sd = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                        if (sd.TryGetValue("id", out var sid) && sid is double sidd && sidd >= ServerSaveIdBase) { serverSaveDone = sd; break; }
                    }
                    saveDone = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                    Log.W(F("{0} : sauvegarde de resynchronisation terminée {1}", "{0}: resynchronisation save done {1}", m.From, m.Payload));
                    break;

                case "clock":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        if (t != null && t.TryGetValue("t", out var tv) && tv is double td)
                        {
                            int sp = t.TryGetValue("sp", out var sv) && sv is double sd ? (int)sd : 0;
                            lock (clocks) clocks[m.From] = new PlayerClock { T = (long)td, Sp = sp, At = Now };
                            // every other game uses it as a barrier: none may run past the slowest player
                            int ah = t.TryGetValue("ah", out var av) && av is double ad ? (int)ad : 3;
                            // tl: that player has a terrain tool in hand (1, 2 when used in the last seconds), the others stay behind its game
                            int tl = t.TryGetValue("tl", out var lv) && lv is double ld ? (int)ld : 0;
                            // bl (MPFEVER_BUILDLEAD): that game takes part in the builder's lead (1), and follows another game's lead (2)
                            int bl = t.TryGetValue("bl", out var bv) && bv is double bd ? (int)bd : 0;
                            // ns: that game keeps its stop points natively (0.5.10), the others may stamp their builds closer
                            bool ns = t.TryGetValue("ns", out var nv) && nv is double nd && nd == 1;
                            var pc = Msg.Make("peerclock", hostName, "{[\"name\"]=" + LuaLit.Quote(m.From) + ",[\"t\"]=" + (long)td + ",[\"ah\"]=" + ah
                                + (tl > 0 ? ",[\"tl\"]=" + tl : "") + (bl > 0 ? ",[\"bl\"]=" + bl : "") + (ns ? ",[\"ns\"]=1" : "") + "}");
                            lock (sendGate)
                            {
                                if (from != null) hostGame?.ToGame(pc);
                                relay.Broadcast(pc, from);
                            }
                        }
                        break;
                    }

                case "act":
                    {
                        // a build made between the host's save and the end of the loads: every game drops it (its sender's own
                        // load undoes it; relayed, the others kept it and the games differed, issue #17)
                        // (except a player announcing its company, one company per player: its own game takes it in at once, so
                        // dropped it left that company on that game only and the checks differed until the next resynchronisation)
                        bool coJoin = m.Payload != null && m.Payload.Contains("\"mpfCoJoin\"");
                        if (resyncDropping && !coJoin)
                        {
                            Log.Warn(F("{0} : action pendant la resynchronisation, non conservée", "{0}: action during the resynchronisation, not kept", m.From));
                            HostChat("msg", "MPFever", F("Construction de {0} pendant la resynchronisation : non conservée, refaites-la.", "{0}'s build during the resynchronisation: not kept, please build it again.", BaseName(m.From)));
                            break;
                        }
                        // already stamped by its originator: relay it, in order, to every other game
                        lock (sendGate)
                        {
                            if (from != null) hostGame?.ToGame(m);
                            relay.Broadcast(m, from);
                        }
                        actsRelayed++;
                        lastActRelayed = Now;
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string fn = t != null && t.TryGetValue("fn", out var f) ? f.ToString() : "?";
                        string at = t != null && t.TryGetValue("at", out var a) ? LuaLit.Show(a) : "?";
                        string native = t != null && t.ContainsKey("native") ? T(" (construction native)", " (native build)") : "";
                        Log.Dim(F("Action {0} de {1} au temps {2}{3} ({4} octets)", "Action {0} by {1} at time {2}{3} ({4} bytes)", fn, m.From, at, native, m.Payload.Length));
                        break;
                    }

                case "act_fail":
                    actFails++;
                    Log.Warn(F("ATTENTION {0} : action non retransmise {1}", "WARNING {0}: action not relayed {1}", m.From, m.Payload));
                    break;

                case "act_refused":
                    actRefused++;
                    Log.Warn(F("{0} : action refusée par le moteur {1}", "{0}: action refused by the engine {1}", m.From, m.Payload));
                    break;

                case "speed_req":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        if (t != null && t.TryGetValue("speed", out var sv) && sv is double d)
                        {
                            if (!started) { if (Now - lastNotStartedLog < 10) break; lastNotStartedLog = Now; Log.Warn(F("{0} demande la vitesse {1} : la partie n'est pas démarrée", "{0} asks for speed {1}: the game is not started", m.From, d)); break; }
                            // a dedicated server may keep the speed for itself (player-speed-control=false), and holds it while it saves
                            if (server != null && from != null && (!server.PlayerSpeedControl || serverSaving)) { Log.Dim(F("{0} demande la vitesse {1} : réservée au serveur", "{0} asks for speed {1}: kept by the server", m.From, d)); break; }
                            // a request for the speed already in effect changes nothing (and must not echo back)
                            bool same; lock (sessionGate) same = d > 0 && !pauseAt.HasValue && (int)d == speed || d <= 0 && pauseAt.HasValue;
                            if (same) break;
                            if (d <= 0) Pause(m.From); else SetSpeed((int)d, m.From);
                        }
                        break;
                    }

                case "sync_hash":
                    OnSyncHash(m);
                    break;

                case "chat":
                    // a player's chat message: the host numbers it and sends it to everybody (the sender included)
                    if (from != null && LuaLit.Parse(m.Payload) is Dictionary<object, object> ct && ct.TryGetValue("text", out var ctx) && ctx is string ctext)
                        HostChat("msg", BaseName(from.Name), ctext);
                    break;

                case "autotest_done":
                    {
                        lock (sendGate)
                        {
                            if (from != null) hostGame?.ToGame(m);
                            relay.Broadcast(m, from);
                        }
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string role = t != null && t.TryGetValue("role", out var r) ? r.ToString() : "?";
                        lock (autoDone) autoDone[role] = m.Payload;
                        break;
                    }

                case "det_hash":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        lock (detGate)
                        {
                            if (t != null && detHashes != null && t.TryGetValue("round", out var r) && r is double rd && (int)rd == detRound)
                            {
                                detHashes[m.From] = t.TryGetValue("parts", out var parts) ? parts as Dictionary<object, object> : null;
                                Monitor.PulseAll(detGate);
                            }
                        }
                        break;
                    }

                case "notice":
                    {
                        // what happens to the companies (bankruptcy, auction, joining, merging: see mpfever_eco.lua), told by the
                        // host's game (its text is the players' names and company names: not looked into below)
                        var nt = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string what = nt != null && nt.TryGetValue("what", out var wv) && wv is string ws ? ws : "";
                        if (what == "cochat")
                        {
                            if (from == null && nt.TryGetValue("text", out var coText) && coText is string coChat && coChat != "") HostChat("msg", "MPFever", coChat);
                            break;
                        }
                    }
                    // something every player must know, told in the chat (it shows for a few seconds on every game)
                    if (m.Payload.Contains("tutorial"))
                    {
                        string text = T("Le tutoriel n'est pas pris en charge en multijoueur : ses missions se valident sur chaque jeu séparément et les parties divergent. Jouez une partie sans tutoriel.",
                                        "The tutorial is not supported in multiplayer: its missions are validated on each game separately and the games diverge. Play a game without the tutorial.");
                        Log.Warn(text);
                        HostChat("msg", "MPFever", text);
                    }
                    // a player's build refused by its own game during a resynchronisation (see SessionPayload)
                    if (m.Payload.Contains("resyncbuild"))
                        HostChat("msg", "MPFever", F("Construction de {0} pendant la resynchronisation : annulée, refaites-la dans un instant.", "{0}'s build during the resynchronisation: cancelled, please build it again in a moment.", BaseName(m.From)));
                    break;

                default:
                    if (resyncDropping && m.Kind == "nat_pending") break;   // (its build is dropped, see "act")
                    lock (sendGate)
                    {
                        if (from != null) hostGame?.ToGame(m);
                        relay.Broadcast(m, from);
                    }
                    if (m.Kind != "chat" && m.Kind != "preview" && m.Kind != "aijournal" && m.Kind != "namesync" && m.Kind != "ping") Log.W($"{m.From} : {m.Kind} {m.Payload}");
                    break;
            }
        }

        /// <summary>(0.7.17, #193) the 0.25 s looks after the first 1.5 s for the other games' reports of a refused build (5 s in all)</summary>
        internal const int FailWaitTicks = 14;
        int timeSkips;   // (0.7.17, #188) sync checks in a row not compared for their games' different times

        // a difference line is "name: values"; names may contain ':' themselves (script:mission)
        static string DiffKey(string d) { int i = d.IndexOf(": ", StringComparison.Ordinal); return i < 0 ? d : d.Substring(0, i); }

        /// <summary>(0.7.17, #188) whether the games of a check gave different game times (a game without a time is not counted)</summary>
        internal static bool DifferentTimes(Dictionary<string, Dictionary<object, object>> got)
        {
            var times = new HashSet<string>();
            foreach (var v in got.Values)
                if (v != null && v.TryGetValue("time", out var tv) && tv != null) times.Add(LuaLit.Show(tv));
            return times.Count > 1;
        }

        void OnSyncHash(Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null || !t.TryGetValue("n", out var nv) || !(nv is double nd)) return;
            int n = (int)nd;
            var parts = t.TryGetValue("parts", out var p) ? p as Dictionary<object, object> : null;
            if (t.TryGetValue("cost", out var cost) && cost is double c && c > 0.1) Log.Warn(F("{0} : empreinte coûteuse ({1:0.00} s)", "{0}: expensive checksum ({1:0.00} s)", m.From, c));
            // host authority: the host's values at this checkpoint go to every other game, which corrects itself
            if (m.From == hostName && t.TryGetValue("auth", out var av) && av is Dictionary<object, object> auth)
            {
                var sb = new System.Text.StringBuilder("{[\"n\"]=" + n);
                foreach (var kv in auth) if (kv.Value is double) sb.Append(",[" + LuaLit.Quote(kv.Key.ToString()) + "]=" + LuaLit.Show(kv.Value));
                relay?.Broadcast(Msg.Make("auth", hostName, sb.Append("}").ToString()));
            }
            Dictionary<string, Dictionary<object, object>> got = null;
            int expected; lock (players) expected = players.Count;
            Dictionary<string, double> turns = null;
            lock (hashes)
            {
                if (!hashes.TryGetValue(n, out var d)) return;
                d[m.From] = parts;
                // (a check taken in a pause: the turns of the paused builds and actions each game had applied, see below)
                if (t.TryGetValue("ptd", out var ptv) && ptv is double ptd)
                {
                    if (!hashTurns.TryGetValue(n, out var tn)) hashTurns[n] = tn = new Dictionary<string, double>();
                    tn[m.From] = ptd;
                }
                if (d.Count >= expected) { got = d; hashes.Remove(n); hashTurns.TryGetValue(n, out turns); hashTurns.Remove(n); }
                foreach (var old in hashes.Keys.Where(k => k < n - 20).ToList()) hashes.Remove(old);
                foreach (var old in hashTurns.Keys.Where(k => k < n - 20).ToList()) hashTurns.Remove(old);
            }
            if (got == null) return;
            // In a pause every game applies the builds and actions in the host's turns, each when it has them: a check taken
            // while one game had applied a turn the other had not yet compared two different moments, and a player building on
            // and on in a pause kept the difference there check after check (nodeConfigs, then a reload: most likely 2026-10-25
            // 21:45, 400 builds in one pause). Games at different turns are not compared; the next check is. MPFEVER_TURNCHECK=0:
            // as before.
            if (turns != null && turns.Count == got.Count && turns.Values.Distinct().Count() > 1 && Environment.GetEnvironmentVariable("MPFEVER_TURNCHECK") != "0")
            {
                Log.Dim(F("Synchronisation n°{0} : pas comparée (jeux à des tours différents de la pause : {1})", "Sync check #{0}: not compared (games at different turns of the pause: {1})",
                    n, string.Join(", ", turns.OrderBy(x => x.Key).Select(x => x.Key + "=" + x.Value))));
                return;
            }
            // (0.7.17, #188: olihf and Tezla, 19:17:28) a check whose games stood at different game times (27534600 and 27535800,
            // 6 steps apart: a build applied by one and not yet by the other) compared two moments: "OUT OF SYNC" (money, towns,
            // stocks, vehicles... and time) though nothing had parted. Games at different times are not compared; the next check
            // is; after 3 such checks in a row (a game that keeps another time), compared again. MPFEVER_TIMECHECK=0: compared, as before
            bool timesDiffer = Environment.GetEnvironmentVariable("MPFEVER_TIMECHECK") != "0" && DifferentTimes(got);
            timeSkips = timesDiffer ? timeSkips + 1 : 0;
            if (timesDiffer && timeSkips <= 3)
            {
                Log.Dim(F("Synchronisation n°{0} : pas comparée (jeux à des temps différents : {1})", "Sync check #{0}: not compared (games at different game times: {1})",
                    n, string.Join(", ", got.OrderBy(x => x.Key).Select(x => x.Key + "=" + (x.Value != null && x.Value.TryGetValue("time", out var xt) ? LuaLit.Show(xt) : "?")))));
                return;
            }
            lastSyncAt = Now;
            var names = got.Keys.OrderBy(k => k).ToList();
            var keys = got.Values.Where(v => v != null).SelectMany(v => v.Keys.Select(k => k.ToString())).Distinct().OrderBy(k => k).ToList();
            var diffs = new List<string>();
            foreach (var k in keys)
            {
                var vals = names.Select(nm => got[nm] != null && got[nm].TryGetValue(k, out var v) ? LuaLit.Show(v) : "absent").ToList();
                // (0.6.5, #111) a part a game does not measure is no difference: "off" (ages: its native module is an older one or
                // absent, MPFever.exe copied alone without winhttp.dll), "none", "absent" (a key of a newer version). Compared as
                // texts, "off" against the others' values reloaded the host's game every two minutes (24 checks, 3 reloads in
                // 10 minutes). Said once per session, with what to do, and left out from then on. MPFEVER_UNMEASURED=0: as before
                if (Environment.GetEnvironmentVariable("MPFEVER_UNMEASURED") != "0")
                {
                    var who = names.Where((nm, i) => NotMeasured(vals[i])).ToList();
                    if (who.Count > 0 && who.Count < names.Count)
                    {
                        // ((0.7.13) a diagnostic part not measured on a game, "personsDigest" off there or a game of an older
                        // version: left out the same, without that advice, which is about the native module)
                        if (unmeasuredParts.Add(k) && !DiagnosticParts.Contains(k))
                            Log.Warn(F("Mesure « {0} » non faite chez {1} (module natif de MPFever absent ou ancien : réinstallez MPFever en extrayant toute l'archive, winhttp.dll compris) : non comparée",
                                       "Measure \"{0}\" not made on {1} (MPFever's native module missing or an old one: reinstall MPFever, extracting the whole archive, winhttp.dll included): not compared", k, string.Join(", ", who)));
                        continue;
                    }
                }
                if (vals.Distinct().Count() > 1) diffs.Add($"{k}: " + string.Join(" | ", names.Select((nm, i) => nm + "=" + vals[i])));
            }
            // (0.6.2, #105) the lines and the vehicles' lines are compared by their names: while the names differ (a default name
            // in another language, a rename the host's names have not reached yet; corrected from the host, see CorrectedParts),
            // so do they, and every purchase in a game of players in two languages said "OUT OF SYNC (lines, names, vehicleState)"
            // for one check. Not counted while the names differ: once the names are equal again, a difference of theirs is one.
            // MPFEVER_NAMESCHECK=1: counted, as before
            if (Environment.GetEnvironmentVariable("MPFEVER_NAMESCHECK") != "1" && diffs.Any(d => DiffKey(d) == "names"))
                diffs = diffs.Where(d => DiffKey(d) != "lines" && DiffKey(d) != "vehicleState").ToList();
            string time = got[names[0]] != null && got[names[0]].TryGetValue("time", out var tv) ? LuaLit.Show(tv) : "?";
            // right after a resynchronisation every game runs the same loaded savegame: a part that still differs is a
            // local measure (display, cache...), not game state; it is left out from then on
            var diffKeys = diffs.Select(d => DiffKey(d)).ToList();
            if (n == postResyncHashN && diffKeys.Count > 0)
            {
                var local = diffKeys.Where(k => !NeverLocalParts.Contains(k)).ToList();
                foreach (var k in local) ignoredParts.Add(k);
                if (local.Count > 0) Log.Warn(T("Mesures propres à chaque jeu (ignorées désormais) : ", "Local measures (ignored from now on): ") + string.Join(", ", local));
            }
            diffs = diffs.Where(d => !ignoredParts.Contains(DiffKey(d))).ToList();
            // the diagnostic parts go to the log only, muted and once until they change: they are no drift, and the players
            // saw "slight drift (buildIds)" check after check for nothing (test of 2026-10-27, the host's list stayed at 88)
            var diag = diffs.Where(d => DiagnosticParts.Contains(DiffKey(d))).ToList();
            string diagNow = string.Join(";", diag);
            if (diagNow != lastDiagDiffs) foreach (var d in diag) Log.Dim("    (diagnostic) " + d);
            lastDiagDiffs = diagNow;
            // (0.8.3) the steps' digests differ: the games' entities parted within the last minute; every game keeps its drift
            // rings at the next check (forced, as after a difference), while they still hold the step where it began. Once per
            // run. MPFEVER_STEPSDUMP=0: not asked for
            if (!stepsDumped && diag.Any(d => DiffKey(d) == "stepsDigest") && Environment.GetEnvironmentVariable("MPFEVER_STEPSDUMP") != "0")
            {
                stepsDumped = true;
                worldDumpNext = true;
                // (a line for the reports, as the other diagnostic lines: not translated)
                Log.Dim("    (diagnostic) stepsDigest: the simulation's steps differ, every game keeps its drift rings at the next check");
            }
            diffs = diffs.Where(d => !DiagnosticParts.Contains(DiffKey(d))).ToList();
            // (0.7.7) a difference of the simulation (not money, which the host corrects, nor the names): the next check asks every
            // game for the whole dump, every vehicle with its whole state, at the same moment (see RequestHash, SDUMP.forceWorld)
            if (diffs.Any(d => WantsWorldDump(DiffKey(d)))) worldDumpNext = true;
            // the expensive parts take turns (issue #32): a part checked at this checkpoint is equal or different (its streak:
            // how many of its own checks in a row differed); a part not checked keeps its state until it is checked again
            var nowDiff = new HashSet<string>(diffs.Select(d => DiffKey(d)));
            List<string> pending;
            lock (partStreak)
            {
                foreach (var k in keys)
                {
                    if (nowDiff.Contains(k)) partStreak[k] = (partStreak.TryGetValue(k, out var s) ? s : 0) + 1;
                    else partStreak.Remove(k);
                }
                pending = partStreak.Keys.Where(k => !CorrectedParts.Contains(k) && !DiagnosticParts.Contains(k) && !ignoredParts.Contains(k)).ToList();
            }
            CheckResync(pending, n);
            // (a difference not checked again at this checkpoint: the sync state stays as it was)
            if (diffs.Count == 0 && pending.Count > 0) return;
            if (diffs.Count == 0)
            {
                bool changed = syncState != 1;
                syncState = 1;
                syncParts = "";
                syncText = T("SYNCHRONE ✔", "IN SYNC ✔");
                if (changed || n % 6 == 1) Log.Ok(F("Synchronisation n°{0} (temps {1}) : IDENTIQUE sur {2} jeux ({3} mesures)", "Sync check #{0} (time {1}): IDENTICAL on {2} games ({3} measures)", n, time, names.Count, keys.Count));
            }
            else if (diffKeys.Where(d => !ignoredParts.Contains(d) && !CorrectedParts.Contains(d) && !DiagnosticParts.Contains(d)).All(DriftParts.Contains))
            {
                // simulation drift (or money, corrected at once): no alarm, a line per minute
                bool changed = syncState != 2;
                syncState = 2;
                syncParts = string.Join(",", diffs.Select(d => DiffKey(d)));
                syncText = T("SYNC ~ (légère dérive : ", "SYNC ~ (slight drift: ") + string.Join(",", diffs.Select(d => DiffKey(d))) + ")";
                if (changed || n % 6 == 1)
                {
                    Log.Warn(F("Synchronisation n°{0} (temps {1}) : légère dérive de la simulation ({2}), corrigée si elle dure", "Sync check #{0} (time {1}): slight simulation drift ({2}), corrected if it lasts", n, time, string.Join(", ", diffs.Select(d => DiffKey(d)))));
                    foreach (var d in diffs) Log.W("    ~ " + d);
                }
            }
            else
            {
                desyncs++;
                syncState = 3;
                syncParts = string.Join(",", diffs.Select(d => DiffKey(d)));
                syncText = T("DÉSYNCHRONISÉ ✖ (", "OUT OF SYNC ✖ (") + string.Join(",", diffs.Select(d => DiffKey(d))) + ")";
                Log.W(F("!!! DÉSYNCHRONISATION n°{0} (temps {1}) : {2} différence(s)", "!!! OUT OF SYNC #{0} (time {1}): {2} difference(s)", n, time, diffs.Count));
                foreach (var d in diffs) Log.W("    " + d);
            }
        }

        // ---------------------------------------------------------------- host authority: resynchronisation

        /// <summary>A difference the games cannot correct by themselves, seen at two checkpoints in a row: every game
        /// reloads the host's savegame.</summary>
        void CheckResync(List<string> keys, int n)
        {
            if (resyncing || autotest) return;
            string k = string.Join(",", keys.OrderBy(x => x));
            if (keys.Count == 0) { diffStreak = 0; lastDiffKeys = ""; driftSince = -1; return; }
            if (keys.All(DriftParts.Contains))
            {
                // simulation drift only: reload once it has lasted DriftResyncSeconds
                diffStreak = 0; lastDiffKeys = "";
                if (driftSince < 0) driftSince = Now;
                double wait = keys.All(x => x == "nodeConfigs") ? NodeConfigsResyncSeconds : DriftResyncSeconds;
                if (Now - driftSince < wait || Now - lastResync < ResyncCooldownSeconds) return;
                driftSince = -1;
                int others; lock (players) others = players.Count(p => p != hostName);
                if (others == 0) return;
                resyncing = true;
                new Thread(() => Resync(T("dérive de la simulation : ", "simulation drift: ") + k)) { IsBackground = true, Name = "Resync" }.Start();
                return;
            }
            driftSince = -1;
            // the longest run of checks in a row where one part differed (each part counts its own checks, see OnSyncHash)
            lock (partStreak) diffStreak = keys.Where(x => !DriftParts.Contains(x)).Select(x => partStreak.TryGetValue(x, out var s) ? s : 0).DefaultIfEmpty(0).Max();
            lastDiffKeys = k;
            if (diffStreak < 2) return;
            if (Now - lastResync < ResyncCooldownSeconds)
            {
                if (diffStreak == 2) Log.Warn(F("Écart persistant ({0}) : resynchronisation possible dans {1:0} s", "Persistent difference ({0}): resynchronisation possible in {1:0} s", k, ResyncCooldownSeconds - (Now - lastResync)));
                return;
            }
            int remote; lock (players) remote = players.Count(p => p != hostName);
            if (remote == 0) return;
            resyncing = true;
            new Thread(() => Resync(k)) { IsBackground = true, Name = "Resync" }.Start();
        }

        void Resync(string reason)
        {
            // (one at a time with a dedicated server's save of its world)
            lock (worldGate) ResyncLocked(reason);
        }

        void ResyncLocked(string reason)
        {
            int id = Interlocked.Increment(ref resyncId);
            resyncAbort = false;
            int prevSpeed; lock (sessionGate) prevSpeed = Math.Max(1, speed);
            var t0 = DateTime.UtcNow;
            try
            {
                Log.W(F("=== Resynchronisation n°{0} sur la partie de l'hôte (écart : {1}) ===", "=== Resynchronisation #{0} on the host's game (difference: {1}) ===", id, reason));
                // (0.7.13, #161/#166: the differences of a 274 MB savegame took 9 s to work out after the save: the base decompressed,
                // then the new savegame, then both compared) The base is decompressed from now on, while the games stop and the host
                // saves, when a player may get the differences; SendDeltas takes it only if it is still the base it compares with.
                // MPFEVER_DELTAEARLY=0: as before
                var baseEarly = EarlyDeltaBase(out string earlySha, out string earlyPath);
                // (the players the host waits for leave: their world is replaced, they join again and get the host's game)
                relay?.FinalizeAway(T("resynchronisation", "resynchronisation"));
                // 1. every game stops at the same time
                Pause(T("resynchronisation", "resynchronisation"));
                long at; lock (sessionGate) at = pauseAt ?? 0;
                bool stopped = WaitUntil(() => { lock (clocks) return clocks.Values.All(c => c.T >= at && c.Sp == 0); }, 120);
                if (!stopped) { Log.Err(T("Resynchronisation abandonnée : les jeux ne se sont pas arrêtés.", "Resynchronisation cancelled: the games did not stop.")); return; }
                // (0.7.7: the DLCs some game of the session lacks, off before the save that every game reloads, see ApplyDlcOff)
                { string[] dlcAll; lock (players) dlcAll = players.ToArray(); ApplyDlcOff(dlcAll, T("resynchronisation", "resynchronisation")); }
                // 2. the host saves
                saveDone = null;
                resyncDropping = true;
                BroadcastSession();
                hostGame.ToGame(Msg.Make("resync_save", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(ResyncSaveName) + "}"));
                if (!WaitUntil(() => saveDone != null, 180)) { Log.Err(T("Resynchronisation abandonnée : l'hôte n'a pas sauvegardé.", "Resynchronisation cancelled: the host did not save.")); return; }
                if (!(saveDone.TryGetValue("ok", out var okv) && okv is bool ok && ok)) { Log.Err(T("Resynchronisation abandonnée : sauvegarde refusée.", "Resynchronisation cancelled: save refused.")); return; }
                Thread.Sleep(1000);   // the file is closed by the game after its callback
                string file = GameInstall.FindSave(ResyncSaveName);
                if (file == null || File.GetLastWriteTimeUtc(file) < t0.AddSeconds(-5))
                {
                    Log.Err(F("Resynchronisation abandonnée : fichier « {0}.sav » introuvable.", "Resynchronisation cancelled: file « {0}.sav » not found.", ResyncSaveName));
                    return;
                }
                byte[] bytes = File.ReadAllBytes(file);
                Log.W(F("Sauvegarde de l'hôte : {0:0.0} Mo, envoi aux autres joueurs...", "Host savegame: {0:0.0} MB, sending it to the other players...", bytes.Length / 1048576.0));
                // 3. every game (the host's too) reloads it; the others receive the file first
                lock (resyncWaiting) { resyncWaiting.Clear(); lock (players) foreach (var p in players) resyncWaiting.Add(p); }
                resyncSending = true;
                resyncBytes = bytes; resyncBytesId = id; resyncSentUpTo = 0;
                string sha = Sha256(bytes);
                resyncBytesSha = sha;
                // (the host's game reloads while the players receive it: each player by itself, a slow one no longer holds the
                // others up)
                lastLoadOrder = Now;
                hostGame.ToGame(Msg.Make("resync_load", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(ResyncSaveName) + "}"));
                // (0.7.13, #161/#166: the game's memory as it starts reloading, see GameLink.LogMemoryNow)
                hostGame.LogMemoryNow("resync load");
                var all = relay?.PeerNames() ?? new string[0];
                // (0.7.0: not to a player still looking at the game's mods and DLCs: it gets the game when it joins, see joinready)
                lock (reviewing) all = all.Where(n => !reviewing.Contains(n)).ToArray();
                // (0.7.3) The players who are joining are waited for too: the list above holds the games already in the session
                // only, so a joining player (a dedicated server's newcomer, not in its world yet) was not waited for. The
                // resynchronisation made for them ended as soon as the others had reloaded, the game still on its way to them was
                // cancelled half sent (saveCancel), and they never loaded it: Roman on the user's server, 2026-11-06 20:44 and
                // 20:46, twice "il rejoint la partie", the game sent to Knight-HD2 only, done in 35 s, then Roman left.
                // MPFEVER_WAITJOINERS=0: as before
                if (Environment.GetEnvironmentVariable("MPFEVER_WAITJOINERS") != "0")
                {
                    string[] joining; lock (players) joining = all.Where(n => !players.Contains(n)).ToArray();
                    if (joining.Length > 0)
                    {
                        lock (resyncWaiting) foreach (var n in joining) resyncWaiting.Add(n);
                        Log.W(F("Resynchronisation : on attend aussi {0}, qui rejoint la partie", "Resynchronisation: also waiting for {0}, who is joining", string.Join(", ", joining)));
                    }
                }
                // (the whole game to the others at once; the differences worked out meanwhile)
                var viaDelta = DeltaPeers(all);
                SendSave(id, bytes, sha, all.Where(n => !viaDelta.Contains(n)));
                SendDeltas(id, bytes, sha, viaDelta, Taken(ref baseEarly), earlySha, earlyPath);
                KeepDeltaBase(bytes, sha);
                bool back = WaitUntil(() => { if (resyncAbort) return true; lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);
                if (resyncAbort) { lock (resyncWaiting) if (resyncWaiting.Count > 0) Log.Warn(T("Resynchronisation interrompue (arrêt ou redémarrage du serveur) : on n'attend plus ", "Resynchronisation cut short (the server stops or restarts): no longer waiting for ") + string.Join(", ", resyncWaiting)); }
                else if (!back) { lock (resyncWaiting) Log.Warn(T("Resynchronisation : sans nouvelles de ", "Resynchronisation: no news from ") + string.Join(", ", resyncWaiting) + T(" (on reprend quand même).", " (resuming anyway).")); }
                saveCancel = id;   // (a player still receiving it would hold everybody's messages up: it gets the next one)
                resyncDropping = false;
                BroadcastSession();
                // 4. all games run the same savegame: check, then resume
                Thread.Sleep(3000);
                postResyncHashN = hashN + 1;
                RequestHash();
                Thread.Sleep(2000);
                Log.W(F("=== Resynchronisation n°{0} terminée en {1:0} s ===", "=== Resynchronisation #{0} done in {1:0} s ===", id, (DateTime.UtcNow - t0).TotalSeconds));
            }
            catch (Exception e) { Log.Err(T("Resynchronisation : ", "Resynchronisation: ") + e.Message); }
            finally
            {
                lastResync = Now;
                diffStreak = 0;
                stepsDumped = false;
                lock (partStreak) partStreak.Clear();
                bool wasDropping = resyncDropping;
                resyncDropping = false;
                resyncSending = false;
                resyncing = false;
                if (wasDropping) BroadcastSession();
                SetSpeed(prevSpeed, T("fin de resynchronisation", "end of resynchronisation"));
            }
        }

        /// <summary>(the host) Sends its savegame (id) to these players, each by its own thread (a slow player no longer
        /// holds the others up), in binary parts; a player who already has the very same file (its fingerprint, see
        /// "savehave") is told to load its own copy.</summary>
        void SendSave(int id, byte[] bytes, string sha, IEnumerable<string> names)
        {
            int parts = (bytes.Length + ResyncChunk - 1) / ResyncChunk;
            resyncSentUpTo = parts;   // (every part may be sent again to a player back after a cut, see resync_have)
            foreach (var name in names)
            {
                var peer = relay?.Find(name);
                if (peer == null) continue;
                string has; lock (saveHave) saveHave.TryGetValue(BaseName(name), out has);
                if (has == sha)
                {
                    relay.Send(peer, Msg.Make("resync_use", hostName, "{[\"id\"]=" + id + ",[\"sha\"]=" + LuaLit.Quote(sha) + "}"));
                    Log.W(F("{0} a déjà cette partie : rien à lui envoyer.", "{0} already has this game: nothing to send them.", name));
                    continue;
                }
                var p = peer;
                new Thread(() =>
                {
                    var t0 = DateTime.UtcNow;
                    // (a newer game is being sent, or this one's wait is over: the rest would only hold the others up)
                    if (!SendParts(p, id, bytes.Length, i =>
                    {
                        int len = Math.Min(ResyncChunk, bytes.Length - i * ResyncChunk);
                        return Msg.MakeBinary("resync_bin", hostName, "[\"id\"]=" + id + ",[\"i\"]=" + i + ",[\"n\"]=" + parts + ",[\"sha\"]=" + LuaLit.Quote(sha), bytes, i * ResyncChunk, len);
                    }, out int links)) return;
                    double s = Math.Max(0.1, (DateTime.UtcNow - t0).TotalSeconds);
                    lock (peerSpeed) peerSpeed[BaseName(p.Name)] = bytes.Length / 1048576.0 / s;
                    Log.W(F("{0} : partie envoyée ({1:0.0} Mo en {2:0} s, {3:0.0} Mo/s)", "{0}: game sent ({1:0.0} MB in {2:0} s, {3:0.0} MB/s)", p.Name, bytes.Length / 1048576.0, s, bytes.Length / 1048576.0 / s)
                        + (links > 0 ? F(" par {0} connexions Steam", " over {0} Steam connections", links) : ""));
                }) { IsBackground = true, Name = "Save to " + p.Name }.Start();
            }
        }

        /// <summary>(the host) At a resynchronisation, the players whose last game from this host is the base it kept get only the
        /// differences (SaveDelta: what changed in the decompressed savegame, deflated: 9 to 15 % of the savegame in tests, worked
        /// out in about 5 s), when they are worth it: a connection slower than 25 MB/s (or not measured yet: not a local
        /// network), and differences under 70 % of the savegame. MPFEVER_DELTA=1: always, 0: never.</summary>
        HashSet<string> DeltaPeers(IEnumerable<string> names)
        {
            var served = new HashSet<string>();
            string mode = Environment.GetEnvironmentVariable("MPFEVER_DELTA") ?? "";
            if (mode == "0" || deltaBaseSha == null || deltaBasePath == null || !File.Exists(deltaBasePath)) return served;
            foreach (var name in names)
            {
                string b; lock (peerBase) peerBase.TryGetValue(BaseName(name), out b);
                if (b != deltaBaseSha) continue;
                double speed; lock (peerSpeed) if (!peerSpeed.TryGetValue(BaseName(name), out speed)) speed = 0;
                if (mode != "1" && speed >= 25) continue;
                if (relay?.Find(name) != null) served.Add(name);
            }
            return served;
        }

        /// <summary>(0.7.13, DELTAEARLY, see ResyncLocked) The base of the differences decompressed in the background from the
        /// start of a resynchronisation, with its fingerprint and file then; null when off, without a base, or when no player can
        /// get the differences now (DeltaPeers, the players looking at the game's mods left out as for the sending).</summary>
        System.Threading.Tasks.Task<byte[]> EarlyDeltaBase(out string sha, out string path)
        {
            sha = deltaBaseSha; path = deltaBasePath;
            try
            {
                if (!DeltaEarlyOn() || sha == null || path == null) return null;
                var names = relay?.PeerNames() ?? new string[0];
                lock (reviewing) names = names.Where(n => !reviewing.Contains(n)).ToArray();
                if (DeltaPeers(names).Count == 0) return null;
                string file = path;
                return System.Threading.Tasks.Task.Run(() => Zstd.DecompressFile(file));
            }
            catch (Exception e) { Log.W("differences' base: " + e.Message); return null; }
        }

        /// <summary>(0.7.13) The value of v, v emptied (nothing of the caller's keeps a big array alive while it is collected).</summary>
        static T Taken<T>(ref T v) where T : class { var x = v; v = null; return x; }

        /// <summary>(the host) The differences to these players (see DeltaPeers); the whole game when they cannot be worked out
        /// or are not worth it. (0.7.13) baseEarly: the base being decompressed since the resynchronisation began (see
        /// EarlyDeltaBase), from the base earlySha at earlyPath.</summary>
        void SendDeltas(int id, byte[] bytes, string sha, HashSet<string> names, System.Threading.Tasks.Task<byte[]> baseEarly = null, string earlySha = null, string earlyPath = null)
        {
            if (names.Count == 0) return;
            string mode = Environment.GetEnvironmentVariable("MPFEVER_DELTA") ?? "";
            var want = names.Select(n => relay?.Find(n)).Where(p => p != null).ToList();
            // (the base these differences are from, taken now: the game sent now becomes the next base at once, see KeepDeltaBase,
            // and a sender reading it later named the new one: the player refused the differences and got the whole game)
            string baseSha = deltaBaseSha ?? "";
            byte[] delta = null;
            // (0.7.13, RESYNCGC: out of the try, to be given back before the sending, see below)
            byte[] baseRaw = null, newRaw = null;
            try
            {
                var t0 = DateTime.UtcNow;
                if (DeltaEarlyOn())
                {
                    // (0.7.13, DELTAEARLY) the base decompressed since the resynchronisation began when it is still the one compared
                    // with (else decompressed now), the new savegame decompressed at the same time
                    string basePath = deltaBasePath;
                    bool early = baseEarly != null && earlySha == baseSha && earlyPath == basePath;
                    try
                    {
                        System.Threading.Tasks.Parallel.Invoke(
                            () => baseRaw = early ? baseEarly.GetAwaiter().GetResult() : Zstd.DecompressFile(basePath),
                            () => newRaw = Zstd.Decompress(bytes));
                    }
                    catch (AggregateException ae) { System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(ae.Flatten().InnerExceptions[0]).Throw(); }
                    if (early) Log.Dim("differences: the base was decompressed during the save");
                }
                else
                {
                    baseRaw = Zstd.DecompressFile(deltaBasePath);
                    newRaw = Zstd.Decompress(bytes);
                }
                var t1 = DateTime.UtcNow;
                delta = SaveDelta.Make(baseRaw, newRaw);
                var t2 = DateTime.UtcNow;
                Log.W(F("Différences avec la partie précédente : {0:0.0} Mo au lieu de {1:0.0} Mo ({2:0} s de calcul)", "Differences from the previous game: {0:0.0} MB instead of {1:0.0} MB ({2:0} s to work out)",
                    delta.Length / 1048576.0, bytes.Length / 1048576.0, (t2 - t0).TotalSeconds)
                    + F(" (décompression {0:0.0} s, comparaison {1:0.0} s)", " (decompressing {0:0.0} s, comparing {1:0.0} s)", (t1 - t0).TotalSeconds, (t2 - t1).TotalSeconds));
            }
            catch (Exception e) { Log.W("differences: " + e.Message); delta = null; }
            // (0.7.13, #161/#166: the base and the new savegame decompressed, 948 MB each, stayed in the launcher's memory, never
            // collected, while the host's game loaded) given back now, before the sending. MPFEVER_RESYNCGC=0: not collected, as before
            baseRaw = newRaw = null; baseEarly = null;
            FreeResyncMemory("differences made");
            if (delta == null || (mode != "1" && delta.Length > bytes.Length * 0.7))
            {
                SendSave(id, bytes, sha, names);
                return;
            }
            int parts = (delta.Length + ResyncChunk - 1) / ResyncChunk;
            foreach (var peer in want)
            {
                var p = peer;
                new Thread(() =>
                {
                    var t0 = DateTime.UtcNow;
                    if (!SendParts(p, id, delta.Length, i =>
                    {
                        int len = Math.Min(ResyncChunk, delta.Length - i * ResyncChunk);
                        return Msg.MakeBinary("delta_bin", hostName, "[\"id\"]=" + id + ",[\"i\"]=" + i + ",[\"n\"]=" + parts + ",[\"sha\"]=" + LuaLit.Quote(sha) + ",[\"base\"]=" + LuaLit.Quote(baseSha), delta, i * ResyncChunk, len);
                    }, out int links)) return;
                    Log.W(F("{0} : différences envoyées ({1:0.0} Mo en {2:0} s)", "{0}: differences sent ({1:0.0} MB in {2:0} s)", p.Name, delta.Length / 1048576.0, (DateTime.UtcNow - t0).TotalSeconds)
                        + (links > 0 ? F(" par {0} connexions Steam", " over {0} Steam connections", links) : ""));
                }) { IsBackground = true, Name = "Delta to " + p.Name }.Start();
            }
        }

        /// <summary>(the host) The parts of a game (or of its differences) to one player: over its Steam bulk connections when it
        /// has some (all at once, each taking the next part: Steam limits each connection's rate), else over its connection. A part
        /// a dying bulk connection could not send goes over the others, then over the main connection. The player puts the parts
        /// together by their numbers. False when the sending stopped (a newer game, this one's wait over, the player gone).</summary>
        /// <summary>(0.7.4) How much of the host's game each player has received so far, in percent (by its name): the in-game
        /// window shows it next to a player who joins or reloads ("receiving the host's game: 45 %").</summary>
        readonly Dictionary<string, int> sendPct = new Dictionary<string, int>();

        /// <summary>The percent of the game sent to a player, -1 when none is on its way.</summary>
        internal int SendPctOf(string name) { lock (sendPct) return sendPct.TryGetValue(name, out int v) ? v : -1; }

        /// <summary>(0.7.4) The percent of a game of `parts` parts once `done` of them are sent (never 100 before the last).</summary>
        internal static int PartsPct(int done, int parts) => parts <= 0 ? 100 : done >= parts ? 100 : Math.Min(99, done * 100 / parts);

        bool SendParts(Peer p, int id, int size, Func<int, Msg> part, out int linksUsed)
        {
            bool shown = Environment.GetEnvironmentVariable("MPFEVER_SENDPCT") != "0";
            try { return SendPartsCounted(p, id, size, part, out linksUsed, shown); }
            finally { if (shown) lock (sendPct) sendPct.Remove(p.Name); }
        }

        bool SendPartsCounted(Peer p, int id, int size, Func<int, Msg> part, out int linksUsed, bool shown)
        {
            int parts = (size + ResyncChunk - 1) / ResyncChunk;
            int done = 0;
            void Tick()
            {
                if (!shown) return;
                int pct = PartsPct(Interlocked.Increment(ref done), parts);
                lock (sendPct) sendPct[p.Name] = pct;
            }
            if (shown) lock (sendPct) sendPct[p.Name] = 0;
            bool Stopped() => saveCancel >= id || resyncBytesId != id || relay == null;
            var links = relay?.BulkOf(p) ?? new BulkLink[0];
            linksUsed = links.Length;
            int next = -1;
            var again = new System.Collections.Concurrent.ConcurrentQueue<int>();
            if (links.Length > 0)
            {
                var threads = links.Select(b => new Thread(() =>
                {
                    while (!Stopped() && !b.Dead)
                    {
                        if (!again.TryDequeue(out int i)) { i = Interlocked.Increment(ref next); if (i >= parts) return; }
                        try { lock (b.Gate) part(i).WriteTo(b.Writer); Tick(); }
                        catch { again.Enqueue(i); b.Dead = true; return; }
                    }
                }) { IsBackground = true, Name = "Parts to " + p.Name + " #" + b.Index }).ToList();
                foreach (var t in threads) t.Start();
                foreach (var t in threads) t.Join();
            }
            // (the rest, or all of it without bulk connections: over the main connection, in order)
            var rest = again.ToList();
            for (int i = Math.Min(parts, Volatile.Read(ref next) + 1); i < parts; i++) rest.Add(i);
            rest.Sort();
            foreach (int i in rest)
            {
                if (Stopped()) return false;
                if (!relay.TrySend(p, part(i))) return false;
                Tick();
            }
            return true;
        }

        /// <summary>(the host) The game every player loads now: the base of the next resynchronisation's differences.</summary>
        void KeepDeltaBase(byte[] bytes, string sha)
        {
            try
            {
                var dir = hostGame?.Dir;
                if (dir == null) return;
                deltaBasePath = Path.Combine(dir, "delta_base.sav");
                File.WriteAllBytes(deltaBasePath, bytes);
                deltaBaseSha = sha;
            }
            catch (Exception e) { deltaBaseSha = null; Log.W("differences' base: " + e.Message); }
        }

        static string Sha256(byte[] data) { using (var h = SHA256.Create()) return BitConverter.ToString(h.ComputeHash(data)).Replace("-", ""); }
        static string Sha256File(string path) { using (var h = SHA256.Create()) using (var f = File.OpenRead(path)) return BitConverter.ToString(h.ComputeHash(f)).Replace("-", ""); }

        // (0.7.13, #161/#166) MPFEVER_RESYNCGC=0, MPFEVER_DELTAPREREAD=0, MPFEVER_DELTAEARLY=0: as before (see FreeResyncMemory,
        // OnDeltaFile, EarlyDeltaBase)
        internal static bool ResyncGcOn() => Environment.GetEnvironmentVariable("MPFEVER_RESYNCGC") != "0";
        internal static bool DeltaPreReadOn() => Environment.GetEnvironmentVariable("MPFEVER_DELTAPREREAD") != "0";
        internal static bool DeltaEarlyOn() => Environment.GetEnvironmentVariable("MPFEVER_DELTAEARLY") != "0";

#pragma warning disable CS0649   // (filled by GlobalMemoryStatusEx)
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct MemStatusEx
        {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }
#pragma warning restore CS0649
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemStatusEx m);

        static long LauncherPrivateMb() { using (var p = Process.GetCurrentProcess()) return p.PrivateMemorySize64 >> 20; }

        /// <summary>(0.7.13, #161/#166) The launcher's own memory and the PC's free memory, for the log: "launcher 3120 MB private,
        /// RAM free 4210 of 16310 MB".</summary>
        internal static string MemNow() => MemText(LauncherPrivateMb());

        static string MemText(long privateMb)
        {
            string ram = "RAM free ?";
            try
            {
                var m = new MemStatusEx { Length = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(MemStatusEx)) };
                if (GlobalMemoryStatusEx(ref m)) ram = "RAM free " + (m.AvailPhys >> 20) + " of " + (m.TotalPhys >> 20) + " MB";
            }
            catch { }
            return "launcher " + privateMb + " MB private, " + ram;
        }

        /// <summary>(0.7.13, #161/#166: a resynchronisation lasts until the slowest PC's game has loaded the savegame, 248 s on a
        /// PC of 16 GB whose game ran half in the page file, and the launcher kept 2.5 to 2.9 GB of arrays it no longer used
        /// during that load: the savegame received, the base and the new savegame decompressed, the differences; nothing ever
        /// collected them) The big arrays of a resynchronisation, once used, are given back to Windows at once (the caller drops
        /// them first; never inside a lock), and the log says the memory before and after ("memory (where): ... -> ..."), with
        /// MPFEVER_RESYNCGC=0 too (nothing collected then, as before). The MB given back, -1 when nothing was collected.</summary>
        internal static long FreeResyncMemory(string where)
        {
            try
            {
                long before = LauncherPrivateMb();
                string b = MemText(before);
                bool on = ResyncGcOn();
                // (no compaction of the large objects: the pause stays short)
                if (on) { GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect(); }
                long after = LauncherPrivateMb();
                Log.Dim("memory (" + where + "): " + b + " -> " + MemText(after));
                return on ? before - after : -1;
            }
            catch { return -1; }
        }

        // (the host) the sends of a game up to this id are over (see SendSave)
        volatile int saveCancel;
        /// <summary>(0.7.6, STOPRESYNC) The dedicated server stops or restarts: a resynchronisation under way waits for nobody
        /// any more (see ResyncLocked). The user's server, 2026-11-07 20:07 and 20:09: "restart" then "stop" only wrote their
        /// message in the chat, the world's save waited behind a resynchronisation stuck for 600 s; the server was closed by
        /// hand and started again from an older save.</summary>
        volatile bool resyncAbort;
        // (the host) the base of the differences (SendDeltas), each player's last game (its fingerprint) and measured speed (MB/s)
        string deltaBaseSha, deltaBasePath;
        readonly Dictionary<string, string> peerBase = new Dictionary<string, string>();
        readonly Dictionary<string, double> peerSpeed = new Dictionary<string, double>();
        // (the host) the lobby savegame's fingerprint; the players who have it already (base name -> fingerprint)
        volatile string lobbySaveSha = "";
        long lobbySaveSize;
        string resyncBytesSha;
        readonly Dictionary<string, string> saveHave = new Dictionary<string, string>();
        // (a player) the lobby's savegame on this PC: its fingerprint, the file found, and "checking", "have" or "missing"
        string hostSaveSha = "", hostSaveName = "", hostSaveLocal, hostSaveState = "";
        long hostSaveSize;
        // (a player) the host's savegame this game loaded last, by its fingerprint (the base of the next one, see SaveDelta)
        string lastSaveSha, lastSavePath;

        /// <summary>(a player) Looks among this PC's savegames for the lobby's (same size, then same fingerprint) and tells
        /// the host.</summary>
        void CheckHostSave(string sha, long size, string save, Client client, string me, bool force = false)
        {
            if (!force && sha == hostSaveSha && hostSaveState != "") return;
            hostSaveSha = sha; hostSaveSize = size; hostSaveName = save; hostSaveLocal = null; hostSaveState = "checking";
            MenuStatus();
            new Thread(() =>
            {
                string found = null;
                try
                {
                    foreach (var d in GameInstall.SaveDirs())
                    {
                        if (found != null) break;
                        foreach (var f in Directory.GetFiles(d, "*.sav"))
                        {
                            try { if (new FileInfo(f).Length == size && Sha256File(f) == sha) { found = f; break; } } catch { }
                        }
                    }
                }
                catch (Exception e) { Log.W("savegame check: " + e.Message); }
                if (sha != hostSaveSha) return;
                hostSaveLocal = found; hostSaveState = found != null ? "have" : "missing";
                if (found != null) Log.Ok(F("La sauvegarde de l'hôte est déjà sur ce PC ({0}) : elle ne sera pas téléchargée.", "The host's savegame is already on this PC ({0}): it will not be downloaded.", Path.GetFileName(found)));
                try { client?.Send(Msg.Make("savehave", me, "{[\"sha\"]=" + LuaLit.Quote(sha) + ",[\"have\"]=" + (found != null ? "true" : "false") + "}")); } catch { }
                MenuStatus();
            }) { IsBackground = true, Name = "Savegame check" }.Start();
        }

        // client side: the host's savegame arrives in pieces; once complete it is written next to this player's
        // savegames and the game loads it
        readonly Dictionary<int, byte[][]> resyncParts = new Dictionary<int, byte[][]>();
        /// <summary>Client: the host MPFever's run (its welcome) the parts in resyncParts come from.</summary>
        string hostRun;
        /// <summary>Host: this MPFever's run (in its welcome), and the host's game sent last, for a player who reconnects
        /// while receiving it (resync_have).</summary>
        readonly string myRun = Guid.NewGuid().ToString("N").Substring(0, 8);
        byte[] resyncBytes;
        int resyncBytesId;
        volatile int resyncSentUpTo;   // the parts of resyncBytes broadcast so far (the rest reaches a player back after a cut anyway)

        void OnResyncFile(GameLink game, Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null) return;
            int id = (int)(double)t["id"], i = (int)(double)t["i"], n = (int)(double)t["n"];
            if (n <= 0 || n > 100000 || i < 0 || i >= n) return;
            string sha = t.TryGetValue("sha", out var shv) && shv is string shs ? shs : null;
            byte[][] got;
            lock (resyncParts)
            {
                if (!resyncParts.TryGetValue(id, out got) || got.Length != n) resyncParts[id] = got = new byte[n][];
                got[i] = m.Data ?? (t.TryGetValue("data", out var dv) && dv is string ds ? Convert.FromBase64String(ds) : null);
                if (got.Any(x => x == null))
                {
                    if (menuMode && !game.InGame)
                    {
                        // (written again only when the percentage changes: one write a part made the menu read it half written)
                        string pct = F("Réception de la partie de l'hôte : {0} %", "Receiving the host's game: {0} %", 100 * got.Count(x => x != null) / n);
                        if (menuPhase != "downloading" || menuText != pct) { menuPhase = "downloading"; menuText = pct; MenuStatus(); }
                    }
                    return;
                }
                resyncParts.Remove(id);
            }
            if (StopIfModsDiffer(game)) return;
            try
            {
                var all = new byte[got.Sum(x => (long)x.Length)];
                long at = 0;
                foreach (var x in got) { Buffer.BlockCopy(x, 0, all, (int)at, x.Length); at += x.Length; }
                // (0.7.13, DELTAPREREAD: a base read for differences that never came is let go, and never read while this is written)
                DropPreRead();
                LoadReceivedSave(game, m, id, all, sha);
                // (0.7.13, #161/#166, RESYNCGC: the game received and its parts given back while the game loads it)
                all = null; got = null;
                FreeResyncMemory("game received");
            }
            catch (Exception e) { Log.Warn(F("[{0}] partie de l'hôte : {1}", "[{0}] host game: {1}", game.Name, e.Message)); }
        }

        static readonly System.Text.RegularExpressions.Regex LuaError = new System.Text.RegularExpressions.Regex(
            @"attempt to (index|call|perform arithmetic|compare|concatenate|get length)|simulation apply failed");

        /// <summary>(0.8.1, LUAERRGATE) The Lua error lines of a game's session logs (*.log): the first `max`, and how many in all.</summary>
        internal static List<string> LuaErrorLines(string dir, int max, out int count)
        {
            var found = new List<string>();
            count = 0;
            try
            {
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return found;
                foreach (var f in Directory.GetFiles(dir, "*.log"))
                    foreach (var l in File.ReadLines(f))
                        if (LuaError.IsMatch(l))
                        {
                            count++;
                            if (found.Count < max) found.Add(Path.GetFileName(f) + ": " + (l.Length > 300 ? l.Substring(0, 300) : l));
                        }
            }
            catch { }
            return found;
        }

        /// <summary>(a player, in the main menu) Another version of a mod than the host's: this game would never match the host's,
        /// it is not loaded and the session ends.</summary>
        bool StopIfModsDiffer(GameLink game)
        {
            if (!(menuMode && !game.InGame && modCheck != null && modCheck.Differs.Count > 0)) return false;
            var text = F("Ces mods ne sont pas dans la même version que chez l'hôte ({0}) : {1}. Mettez-les à jour (mod.io ou Steam Workshop) pour avoir la même version que l'hôte, puis rejoignez à nouveau.",
                "These mods are not the same version as the host's ({0}): {1}. Update them (mod.io or Steam Workshop) to have the host's version, then join again.", modCheck.Differs.Count, string.Join(", ", modCheck.Differs));
            Log.Err(T("La partie de l'hôte n'a pas été chargée. ", "The host's game was not loaded. ") + text);
            new Thread(() =>
            {
                EndSession(T("=== Mods différents de ceux de l'hôte : fin de la session ===", "=== Mods differ from the host's: the session ends ==="));
                menuPhase = "error"; menuText = text; MenuStatus();
            }) { IsBackground = true, Name = "Mods differ" }.Start();
            return true;
        }

        /// <summary>(a player) The differences between its last game from the host and the new one, in parts: applied to its last
        /// game (decompressed), written as a savegame (not compressed: the game reads it all the same), loaded. When they do not
        /// apply (another base, a fingerprint that differs), the host is asked for the whole game.</summary>
        void OnDeltaFile(GameLink game, Client client, string me, Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null) return;
            int id = (int)(double)t["id"], i = (int)(double)t["i"], n = (int)(double)t["n"];
            if (n <= 0 || n > 100000 || i < 0 || i >= n || m.Data == null) return;
            string sha = t.TryGetValue("sha", out var shv) && shv is string shs ? shs : null;
            string bsha = t.TryGetValue("base", out var bv) && bv is string bs ? bs : null;
            byte[][] got;
            lock (deltaParts)
            {
                if (!deltaParts.TryGetValue(id, out got) || got.Length != n)
                {
                    deltaParts[id] = got = new byte[n][];
                    // (0.7.13, #161/#166: a player's base, its last game from the host, was read and decompressed only once the
                    // differences' last part had come: 6 to 15 s more before its game could start loading) It is read while the
                    // differences arrive, when they are from the base this PC has (checked again when they are applied).
                    // MPFEVER_DELTAPREREAD=0: as before
                    if (DeltaPreReadOn() && bsha != null && bsha == lastSaveSha && lastSavePath != null && File.Exists(lastSavePath))
                    {
                        string file = lastSavePath;
                        deltaPre = new DeltaPreRead { Id = id, SavePath = file, Read = System.Threading.Tasks.Task.Run(() => Zstd.ReadSaveRaw(file)) };
                    }
                }
                got[i] = m.Data;
                if (got.Any(x => x == null)) return;
                deltaParts.Remove(id);
            }
            if (StopIfModsDiffer(game)) return;
            new Thread(() =>
            {
                try
                {
                    if (bsha == null || bsha != lastSaveSha || lastSavePath == null || !File.Exists(lastSavePath)) throw new InvalidDataException("not the base this PC has");
                    var t0 = DateTime.UtcNow;
                    var delta = new byte[got.Sum(x => (long)x.Length)];
                    long at = 0;
                    foreach (var x in got) { Buffer.BlockCopy(x, 0, delta, (int)at, x.Length); at += x.Length; }
                    // (0.7.13, DELTAPREREAD: the base read while the differences came; MPFEVER_DELTAPREREAD=0: read now, as before)
                    var baseRaw = DeltaPreReadOn() ? PreReadBase(id) : Zstd.DecompressFile(lastSavePath);
                    var newRaw = SaveDelta.Apply(baseRaw, delta);
                    Log.W(F("[{0}] différences de la partie de l'hôte appliquées ({1:0.0} Mo reçus, {2:0} s)", "[{0}] differences of the host's game applied ({1:0.0} MB received, {2:0} s)",
                        game.Name, delta.Length / 1048576.0, (DateTime.UtcNow - t0).TotalSeconds));
                    LoadReceivedSave(game, m, id, null, sha, newRaw);
                    // (0.7.13, #161/#166, RESYNCGC: the base, the differences and the new savegame, 2 to 3 GB, given back while the game
                    // loads it)
                    newRaw = null; baseRaw = null; delta = null; got = null;
                    FreeResyncMemory("differences applied");
                }
                catch (Exception e)
                {
                    Log.Warn(F("[{0}] différences inutilisables ({1}) : la partie entière est demandée à l'hôte.", "[{0}] differences not usable ({1}): asking the host for the whole game.", game.Name, e.Message));
                    try { client?.Send(Msg.Make("resync_need", me, "{[\"id\"]=" + id + "}")); } catch { }
                    // (0.7.13, DELTAPREREAD: a base read for them is not kept)
                    DropPreRead();
                }
            }) { IsBackground = true, Name = "Apply differences" }.Start();
        }
        readonly Dictionary<int, byte[][]> deltaParts = new Dictionary<int, byte[][]>();

        /// <summary>(0.7.13, DELTAPREREAD) The base being read for the differences Id, from SavePath (see OnDeltaFile).</summary>
        sealed class DeltaPreRead { public int Id; public string SavePath; public System.Threading.Tasks.Task<byte[]> Read; }
        DeltaPreRead deltaPre;   // (under lock (deltaParts))

        /// <summary>(0.7.13, DELTAPREREAD) The base of the differences id: the one read while they arrived when it is still this
        /// PC's last game from the host, else read now (Zstd.ReadSaveRaw: the same bytes as DecompressFile).</summary>
        byte[] PreReadBase(int id)
        {
            string path = lastSavePath;
            DeltaPreRead pre;
            lock (deltaParts) { pre = deltaPre; deltaPre = null; }
            if (pre != null)
            {
                try
                {
                    var b = pre.Read.GetAwaiter().GetResult();
                    if (pre.Id == id && pre.SavePath == path) { Log.Dim("differences: the base was read while they arrived"); return b; }
                }
                // (it could not be read then: read again now, as before)
                catch (Exception e) { Log.Dim("differences: the base read beforehand: " + e.Message); }
            }
            return Zstd.ReadSaveRaw(path);
        }

        /// <summary>(0.7.13, DELTAPREREAD) A base read beforehand let go, once its reading is over (the file is written again right
        /// after: never while it is being read). Nothing to do with MPFEVER_DELTAPREREAD=0.</summary>
        void DropPreRead()
        {
            DeltaPreRead pre;
            lock (deltaParts) { pre = deltaPre; deltaPre = null; }
            if (pre != null) try { pre.Read.Wait(); } catch { }
        }

        /// <summary>(a player) The host says this player has its game already (the lobby's savegame, found on this PC): it is
        /// loaded as if received; if it is not there any more, the host is asked to send it.</summary>
        void OnResyncUse(GameLink game, Client client, string me, Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
            int id = t.TryGetValue("id", out var iv) && iv is double d ? (int)d : 0;
            string sha = t.TryGetValue("sha", out var sv) && sv is string ss ? ss : "";
            try
            {
                if (StopIfModsDiffer(game)) return;
                if (hostSaveLocal != null && sha == hostSaveSha && File.Exists(hostSaveLocal))
                {
                    var bytes = File.ReadAllBytes(hostSaveLocal);
                    if (Sha256(bytes) == sha)
                    {
                        Log.Ok(F("[{0}] partie de l'hôte prise sur ce PC ({1}) : rien à télécharger.", "[{0}] host game taken from this PC ({1}): nothing to download.", game.Name, Path.GetFileName(hostSaveLocal)));
                        // (0.7.13, DELTAPREREAD: as in OnResyncFile)
                        DropPreRead();
                        LoadReceivedSave(game, m, id, bytes, sha);
                        // (0.7.13, #161/#166, RESYNCGC: the copy read, given back while the game loads it)
                        bytes = null;
                        FreeResyncMemory("own copy loaded");
                        return;
                    }
                }
            }
            catch (Exception e) { Log.W("own copy: " + e.Message); }
            Log.Warn(F("[{0}] la copie de la partie de l'hôte n'est plus là : elle est demandée à l'hôte.", "[{0}] the copy of the host's game is gone: asking the host for it.", game.Name));
            try { client?.Send(Msg.Make("resync_need", me, "{[\"id\"]=" + id + "}")); } catch { }
        }

        /// <summary>(a player) The host's game is here (received, or this PC's own copy): written next to the savegames, then
        /// loaded by the game.</summary>
        /// <summary>The number of the resynchronisation (or lobby start) whose savegame a game loads from the main menu, for the
        /// game's mod (load_id.txt, read at its first start in the session): a game loaded in the game gets it from its order to
        /// load (resync_load). A build made after its builder loaded the same savegame cannot be in it (see the bridge's
        /// G.alreadyBuilt).</summary>
        static void WriteLoadId(GameLink game, int id)
        {
            try { if (game != null) File.WriteAllText(Path.Combine(game.Dir, "load_id.txt"), id.ToString(System.Globalization.CultureInfo.InvariantCulture)); } catch { }
        }

        void LoadReceivedSave(GameLink game, Msg m, int id, byte[] bytes, string sha, byte[] raw = null)
        {
            try
            {
                string name = ResyncSaveName + " " + new string(game.Name.Where(char.IsLetterOrDigit).ToArray());
                string written = null;
                foreach (var d in GameInstall.SaveDirs())
                {
                    written = Path.Combine(d, name + ".sav");
                    if (raw != null)
                    {
                        // (690 MB: written beside it first, so that a write cut short never leaves a broken savegame)
                        var part = written + ".part";
                        Zstd.WriteRawFrame(part, raw);
                        if (File.Exists(written)) File.Delete(written);
                        File.Move(part, written);
                    }
                    else File.WriteAllBytes(written, bytes);
                }
                lastSaveSha = sha ?? Sha256(bytes); lastSavePath = written;
                // (the host is told which game this PC has: the base of the next differences, see SendDeltas)
                try { clients.FirstOrDefault()?.Send(Msg.Make("savebase", game.Name, "{[\"sha\"]=" + LuaLit.Quote(lastSaveSha) + "}")); } catch { }
                Log.W(F("[{0}] partie de l'hôte reçue ({1:0.0} Mo) : chargement...", "[{0}] host game received ({1:0.0} MB): loading...", game.Name, (raw != null ? raw.Length : bytes.Length) / 1048576.0));
                // the mods of this load: the host's personal ones left out, this player's own added (read by mpfever_auto.lua)
                try
                {
                    var plan = Mods.LoadPlan(lobbyMods);
                    File.WriteAllText(Path.Combine(game.Dir, "load_mods.txt"), plan);
                    // (0.6.7) the savegame's mods for the mod in this game (the host's has host_mods.txt): a "no costs" mod turns the
                    // refund bookings off (see REFUND.freeBuilds in the bridge)
                    File.WriteAllText(Path.Combine(game.Dir, "session_mods.txt"), lobbyMods ?? "");
                    if (plan != "") Log.W(F("[{0}] mods personnels : {1}", "[{0}] personal mods: {1}", game.Name, plan.Trim().Replace("\n", ", ").Replace("\t", " ")));
                    // (0.8.4, #233 #251: the user's choice, warn everybody) mods taken for personal by hand that this game runs
                    // without (or with, alone): told to every player in the session's chat, once per session and per list
                    var risky = Mods.RiskyPlan(lobbyMods);
                    string riskKey = string.Join(",", risky);
                    if (risky.Count > 0 && riskKey != riskyAnnounced)
                    {
                        riskyAnnounced = riskKey;
                        var without = risky.Where(x => x.StartsWith("-")).Select(x => x.Substring(1)).ToList();
                        var with = risky.Where(x => x.StartsWith("+")).Select(x => x.Substring(1)).ToList();
                        string a = string.Join(", ", without), b = string.Join(", ", with);
                        string warn = with.Count == 0
                            ? F("MPFever : ce jeu tourne SANS {0} (mods pris pour personnels à la main). S'ils changent la partie, les jeux vont se désynchroniser : tout le monde doit avoir les mêmes mods.",
                                "MPFever: this game runs WITHOUT {0} (mods taken for personal by hand). If they change the game, the games will desync: everybody needs the same mods.", a)
                            : without.Count == 0
                            ? F("MPFever : ce jeu tourne AVEC {0} en plus (mods pris pour personnels à la main). S'ils changent la partie, les jeux vont se désynchroniser : tout le monde doit avoir les mêmes mods.",
                                "MPFever: this game runs WITH {0} too (mods taken for personal by hand). If they change the game, the games will desync: everybody needs the same mods.", b)
                            : F("MPFever : ce jeu tourne SANS {0} et AVEC {1} en plus (mods pris pour personnels à la main). S'ils changent la partie, les jeux vont se désynchroniser : tout le monde doit avoir les mêmes mods.",
                                "MPFever: this game runs WITHOUT {0} and WITH {1} too (mods taken for personal by hand). If they change the game, the games will desync: everybody needs the same mods.", a, b);
                        Log.W("[" + game.Name + "] " + warn);
                        try { clients.FirstOrDefault()?.Send(Msg.Make("chat", game.Name, "{[\"text\"]=" + LuaLit.Quote(warn) + "}")); } catch { }
                    }
                }
                catch (Exception e) { Log.W("load_mods: " + e.Message); }
                // the host's numbers start again at 1 when its MPFever restarts, while this MPFever and its game remember
                // the loads they did (menu_loaded.txt, resync_claims.txt) and skipped the host's game as already loaded:
                // each game received has a number of its own (issue #29)
                string seq = id + "-" + DateTime.Now.Ticks;
                if (menuMode && !game.InGame)
                {
                    WriteLoadId(game, id);
                    // still in the main menu: its MPFever window loads the savegame
                    menuPhase = "loading"; menuText = T("Chargement de la partie de l'hôte...", "Loading the host's game..."); menuLoad = name; menuLoadSeq = "r" + seq;
                    MenuStatus();
                    return;
                }
                lastLoadOrder = Now;
                game.ToGame(Msg.Make("resync_load", m.From, "{[\"id\"]=" + LuaLit.Quote(seq) + ",[\"name\"]=" + LuaLit.Quote(name) + "}"));
                // (0.7.13, #161/#166: the game's memory as it starts reloading, see GameLink.LogMemoryNow)
                game.LogMemoryNow("resync load");
            }
            catch (Exception e) { Log.Warn(F("[{0}] partie de l'hôte : {1}", "[{0}] host game: {1}", game.Name, e.Message)); }
        }

        /// <summary>Autotest "recplay" (MPFEVER_SCENARIO=recplay, MPFEVER_RECPLAY=events file, made by tools\recplay.py from a
        /// session's logs): replays a real session's actions on the two games of the test, as another player's actions (both
        /// games replay them, as a player who received them did), at their own game times. One event per line, TAB separated:
        /// msg kind from payload (sent to every game), waitact uid seconds (until every game applied it), pauseat t (the games
        /// stop exactly at t), speed n, run seconds, rununtil t, save role name (that game saves, as its autosave would), hash,
        /// log text.</summary>
        void RunRecPlay()
        {
            var path = Environment.GetEnvironmentVariable("MPFEVER_RECPLAY") ?? Path.Combine(GameLink.SessionRoot(), "recplay.txt");
            var lines = File.ReadAllLines(path);
            AutoLine("recplay: " + lines.Length + " event(s) from " + path);
            // (every game's mod.log, read again from where it was read last: the acts it applied)
            var seen = new Dictionary<string, long>();
            var logText = new Dictionary<string, System.Text.StringBuilder>();
            Func<string, bool> appliedEverywhere = uid =>
            {
                List<GameLink> gl; lock (games) gl = games.Where(g => g.Role != "menu").ToList();
                foreach (var g in gl)
                {
                    var f = Path.Combine(g.Dir, "mod.log");
                    if (!logText.TryGetValue(g.Dir, out var sb)) logText[g.Dir] = sb = new System.Text.StringBuilder();
                    try
                    {
                        using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        {
                            seen.TryGetValue(g.Dir, out long off);
                            if (fs.Length > off) { fs.Seek(off, SeekOrigin.Begin); var buf = new byte[fs.Length - off]; int n = fs.Read(buf, 0, buf.Length); sb.Append(System.Text.Encoding.UTF8.GetString(buf, 0, n)); seen[g.Dir] = off + n; }
                        }
                    }
                    catch { return false; }
                    bool done = false;
                    foreach (var l in sb.ToString().Split('\n'))
                        if (l.Contains(uid + " ") || l.Contains(uid + ":"))
                            if (l.Contains("-> OK") || l.Contains(" BUILT") || l.Contains("failed") || l.Contains("FAILED") || l.Contains("REFUSED") || l.Contains("refused")
                                || l.Contains("already") || l.Contains("-> ") || l.Contains("not built") || l.Contains("applied")) { done = true; break; }
                    if (!done) return false;
                }
                return true;
            };
            // (the regular checks of the session: every change of their result, with the game time it was seen at)
            bool replaying = true;
            new Thread(() =>
            {
                string lastSync = null;
                while (replaying)
                {
                    Thread.Sleep(1000);
                    string s = syncText;
                    if (s != lastSync) { lastSync = s; AutoLine("recplay: t=" + MaxClock() + " check: " + s); }
                }
            }) { IsBackground = true, Name = "RecplayWatch" }.Start();
            try { RecPlayEvents(lines, appliedEverywhere); }
            finally { replaying = false; }
        }

        void RecPlayEvents(string[] lines, Func<string, bool> appliedEverywhere)
        {
            // (an action stamped again: the vehicles and lines it made are bound here under its new time, "V<uid>@<time>", and the
            // later actions name them by the session's: those keys are written with the new time too. Without it every vehicle
            // bought in a pause the games stopped a step later was "unresolved" for the rest of the replay)
            var restamped = new Dictionary<string, KeyValuePair<long, long>>();
            for (int li = 0; li < lines.Length; li++)
            {
                var raw = lines[li];
                if (ClosedGames() != "") { AutoLine("recplay: a game closed: " + ClosedGames()); break; }
                var p = raw.Split('\t');
                if (p.Length == 0 || p[0] == "" || p[0].StartsWith("#")) continue;
                switch (p[0])
                {
                    case "msg":
                        {
                            // (an action of a pause, or its announcement, stamped as the games stamp theirs: at the latest of
                            // their times, the others catch up to it; the session's time may be behind a game that stopped a
                            // batch later, which would apply it at once, at another time than the others)
                            // (a running one: no sooner than a time every game can still reach, as FutureStamp gives the session's)
                            string payload = p[3];
                            var mt = System.Text.RegularExpressions.Regex.Match(payload, @"\[""at""\]=(\d+)");
                            if (mt.Success && long.TryParse(mt.Groups[1].Value, out long was))
                            {
                                long want;
                                if (payload.Contains("[\"paused\"]=true")) lock (clocks) want = clocks.Count == 0 ? 0 : clocks.Values.Max(c => c.T);
                                else want = FutureStamp();
                                if (want > was)
                                {
                                    payload = payload.Substring(0, mt.Groups[1].Index) + want + payload.Substring(mt.Groups[1].Index + mt.Groups[1].Length);
                                    var mu = System.Text.RegularExpressions.Regex.Match(payload, @"\[""uid""\]=""([^""]+)""");
                                    if (mu.Success) restamped[mu.Groups[1].Value] = new KeyValuePair<long, long>(was, want);
                                }
                            }
                            // (a key is one letter, V for a vehicle or L for a line, the uid and the time)
                            payload = System.Text.RegularExpressions.Regex.Replace(payload, @"(\[""key""\]=""[A-Z])([^""@]+)@(\d+)""", m =>
                                restamped.TryGetValue(m.Groups[2].Value, out var s) && m.Groups[3].Value == s.Key.ToString(CultureInfo.InvariantCulture)
                                    ? m.Groups[1].Value + m.Groups[2].Value + "@" + s.Value.ToString(CultureInfo.InvariantCulture) + "\"" : m.Value);
                            HostSend(Msg.Make(p[1], p[2], payload));
                            break;
                        }
                    case "waitact":
                        {
                            double secs = p.Length > 2 ? double.Parse(p[2], CultureInfo.InvariantCulture) : 60;
                            if (!WaitUntil(() => appliedEverywhere(p[1]), secs)) AutoLine("recplay: " + p[1] + " NOT applied everywhere in " + secs + " s");
                            Thread.Sleep(500);
                            break;
                        }
                    case "pauseat":
                        {
                            long at = long.Parse(p[1], CultureInfo.InvariantCulture);
                            // (a time the games already passed: they stop at the next time every game can still reach)
                            // (as the session's own pauses: no closer than FutureStamp, the games run several steps between two
                            // of their clocks at x4; a game already past the time cannot come back: no waiting then)
                            // (already the pause the games run to, set when they were resumed: nothing to move)
                            long? cur; lock (sessionGate) cur = pauseAt;
                            bool past = false;
                            if (cur != at)
                            {
                                long ahead = FutureStamp();
                                past = at < ahead;
                                if (past) at = ahead;
                                lock (sessionGate) pauseAt = at;
                                BroadcastSession();
                            }
                            bool ok = WaitUntil(() => { lock (clocks) return clocks.Count >= 2 && (clocks.Values.All(c => c.T == at) || clocks.Values.Any(c => c.T > at)); }, 300);
                            lock (clocks) ok = ok && clocks.Values.All(c => c.T == at);
                            AutoLine("recplay: paused at " + at + (past ? " (asked " + p[1] + ", already passed)" : "") + (ok ? "" : " NOT REACHED (" + string.Join(",", clocks.Values.Select(c => c.T)) + ")"));
                            break;
                        }
                    case "speed":
                        lock (sessionGate) { speed = Math.Max(1, Math.Min(4, int.Parse(p[1]))); pauseAt = null; }
                        BroadcastSession();
                        break;
                    case "run":
                        Thread.Sleep((int)(double.Parse(p[1], CultureInfo.InvariantCulture) * 1000));
                        break;
                    case "rununtil":
                        {
                            long at = long.Parse(p[1], CultureInfo.InvariantCulture);
                            if (!WaitUntil(() => MaxClock() >= at, 1800)) AutoLine("recplay: t=" + at + " not reached");
                            break;
                        }
                    case "save":
                        HostSend(Msg.Make("test_save", hostName, "{[\"role\"]=" + LuaLit.Quote(p[1]) + ",[\"name\"]=" + LuaLit.Quote(p.Length > 2 ? p[2] : "recplay " + p[1]) + "}"));
                        Thread.Sleep(6000);
                        break;
                    case "hash":
                        RequestHash();
                        Thread.Sleep(12000);
                        AutoLine("recplay: check: " + syncText);
                        break;
                    case "log":
                        AutoLine("recplay: " + (p.Length > 1 ? p[1] : ""));
                        break;
                    default:
                        AutoLine("recplay: unknown event " + p[0]);
                        break;
                }
            }
        }

        void RunDeterminism()
        {
            if (started) { Log.Warn(T("Test déterminisme : à lancer avant « Démarrer la partie ».", "Determinism test: run it before « Start the game ».")); return; }
            int[] schedule = { 0, 100, 500, 1500, 3000 };
            // MPFEVER_DET_SCHEDULE=0,300,300,...: the steps of each round (diagnostic: find the first step where the games differ)
            var ds = Environment.GetEnvironmentVariable("MPFEVER_DET_SCHEDULE");
            if (!string.IsNullOrEmpty(ds)) schedule = ds.Split(',').Select(x => int.Parse(x.Trim())).ToArray();
            int expected;
            lock (players) expected = players.Count;
            if (expected < 2) { Log.Warn(F("Test déterminisme : il faut au moins 2 jeux prêts (actuellement {0}).", "Determinism test: at least 2 games must be ready (now {0}).", expected)); return; }
            detRunning = true;
            try
            {
                Log.W(F("=== Test déterminisme sur {0} jeux ===", "=== Determinism test on {0} games ===", expected));
                int total = 0;
                for (int round = 0; round < schedule.Length; round++)
                {
                    int steps = schedule[round];
                    lock (detGate) { detRound = round; detHashes = new Dictionary<string, Dictionary<object, object>>(); }
                    // MPFEVER_DET_PAUSE=s: the games stay paused that long before each round (does real time change the simulation?)
                    if (int.TryParse(Environment.GetEnvironmentVariable("MPFEVER_DET_PAUSE") ?? "", out int detPause) && detPause > 0 && round > 0) Thread.Sleep(detPause * 1000);
                    HostSend(Msg.Make("det_run", hostName, "{[\"round\"]=" + round + ",[\"steps\"]=" + steps + "}"));
                    total += steps;
                    var deadline = DateTime.UtcNow.AddSeconds(Environment.GetEnvironmentVariable("MPFEVER_CENSUS") != null ? 1800 : 300);
                    Dictionary<string, Dictionary<object, object>> got;
                    lock (detGate)
                    {
                        while (detHashes.Count < expected && DateTime.UtcNow < deadline) Monitor.Wait(detGate, 1000);
                        got = new Dictionary<string, Dictionary<object, object>>(detHashes);
                    }
                    if (got.Count < expected) { Log.Err(F("Tour {0} : réponses manquantes ({1}/{2}), test arrêté.", "Round {0}: answers missing ({1}/{2}), test stopped.", round, got.Count, expected)); return; }
                    var names = got.Keys.OrderBy(k => k).ToList();
                    var keys = got.Values.Where(v => v != null).SelectMany(v => v.Keys.Select(k => k.ToString())).Distinct().OrderBy(k => k).ToList();
                    var diffs = new List<string>();
                    foreach (var k in keys)
                    {
                        var vals = names.Select(n => got[n] != null && got[n].TryGetValue(k, out var v) ? LuaLit.Show(v) : "absent").ToList();
                        if (vals.Distinct().Count() > 1) diffs.Add($"{k}: " + string.Join(" | ", names.Select((n, i) => n + "=" + vals[i])));
                    }
                    if (diffs.Count == 0) Log.Ok(F("Tour {0} (+{1} pas, total {2}) : IDENTIQUE sur {3} mesures", "Round {0} (+{1} steps, total {2}): IDENTICAL on {3} measures", round, steps, total, keys.Count));
                    else
                    {
                        Log.Err(F("Tour {0} (+{1} pas, total {2}) : {3} DIFFÉRENCE(S)", "Round {0} (+{1} steps, total {2}): {3} DIFFERENCE(S)", round, steps, total, diffs.Count));
                        foreach (var d in diffs) Log.W("    " + d);
                    }
                }
                Log.W(T("=== Fin du test déterminisme ===", "=== End of the determinism test ==="));
                if (Environment.GetEnvironmentVariable("MPFEVER_CENSUS") != null) Thread.Sleep(150000);   // the last census is still being written
            }
            finally { detRunning = false; }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            foreach (var g in games) g.Dispose();
            foreach (var c in clients) c.Dispose();
            relay?.Dispose();
            PortMap.Close();
            // (0.6: a public game leaves the list now, else after 90 s; the list gets 2 s at most)
            if (pubListId != null) { var t = new Thread(PublicGameRemove) { IsBackground = true }; t.Start(); t.Join(2000); }
            base.OnFormClosed(e);
        }
    }
}
