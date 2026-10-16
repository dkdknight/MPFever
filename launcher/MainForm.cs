using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
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
            bool auto = args.Length > 0 && args[0] == "--autotest";
            MainForm.Dev = auto || args.Contains("--dev");
            // default: the game starts at once and the session is set up from its main menu (MPFever window)
            MainForm.MenuModeDefault = !MainForm.Dev;
            if (auto) GameLink.AutoSave = args.Length > 1 ? args[1] : "test multi";
            // started by the game from a Steam invitation: join that host at once
            int j = Array.IndexOf(args, "--join");
            if (j >= 0 && j + 1 < args.Length) MainForm.JoinAtStart = args[j + 1];
            // dedicated server: this PC's game runs the world for the players, nobody plays on it (mpfever_server.properties)
            MainForm.ServerMode = !auto && args.Contains("--server");
            Application.Run(new MainForm(auto));
            return 0;
        }
    }

    sealed partial class MainForm : Form
    {
        public const string Version = "0.3.12-experimental";
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
        volatile bool clientCancelled;
        // ---- lobby: the host's session is open in the main menu, players join it there, and the host starts the game for
        // everybody at once (each game loads the host's savegame at the same time); a player may still join a running game
        volatile bool lobbyOpen, lobbyStarting;
        string lobbySave = "", lobbyPlayers = "";
        const long Step = 200;                 // game time units per simulation step
        const double UnitsPerSecond = 1000;    // game time units per real second at x1
        const double HashEverySeconds = 10;

        readonly TextBox nameBox = new TextBox { Text = SavedName() };
        readonly TextBox hostBox = new TextBox { Text = "127.0.0.1" };
        readonly NumericUpDown portBox = new NumericUpDown { Minimum = 1024, Maximum = 65535, Value = 28090 };
        readonly ModernButton hostBtn = new ModernButton(ButtonKind.Primary);
        readonly ModernButton joinBtn = new ModernButton(ButtonKind.Secondary);
        readonly ModernButton localBtn = new ModernButton(ButtonKind.Ghost);
        readonly ModernButton startBtn = new ModernButton(ButtonKind.Primary) { Enabled = false };
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
        GameLink hostGame;
        bool running;
        Action<GameLink, Msg> hostFromGame, clientFromGame;   // the session's handlers on the game's messages (removed at its end)
        int sessionGen;
        int censusN;                                         // autotest: census taken so far                                      // a new session: the threads of the previous one stop

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
        long actSeq;
        int hashN;
        readonly Dictionary<int, Dictionary<string, Dictionary<object, object>>> hashes = new Dictionary<int, Dictionary<string, Dictionary<object, object>>>();
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
        const int ResyncChunk = 256 * 1024;
        volatile bool resyncing;
        double lastResync = -1e9;
        int resyncId;
        readonly HashSet<string> resyncWaiting = new HashSet<string>();
        Dictionary<object, object> saveDone;
        string lastDiffKeys = "";
        int diffStreak;
        readonly Dictionary<string, int> partStreak = new Dictionary<string, int>();
        int postResyncHashN = -1;
        readonly HashSet<string> ignoredParts = new HashSet<string>();
        // parts every game corrects by itself from the host's values (not a reason to reload)
        static readonly HashSet<string> CorrectedParts = new HashSet<string> { "money" };
        // game state that is never a local measure, even when it differs right after a reload (a company a game missed must be seen)
        static readonly HashSet<string> NeverLocalParts = new HashSet<string> { "companies", "money", "owners", "loans", "edges", "constructions", "lines" };
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

        public MainForm(bool autotest = false)
        {
            this.autotest = autotest;
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
                                                       : T(" – multijoueur Transport Fever 3 (expérimental)", " – Transport Fever 3 multiplayer (experimental)"));
            hostBtn.Text = T("Héberger une partie", "Host a game");
            joinBtn.Text = T("Rejoindre par IP", "Join by IP");
            localBtn.Text = T("Test local (2 jeux)", "Local test (2 games)");
            startBtn.Text = T("▶  Démarrer la partie", "▶  Start the game");
            pauseBtn.Text = "❚❚  " + T("Pause", "Pause");
            detBtn.Text = T("Test déterminisme", "Determinism test");
            langBtn.Text = L.Name + "  ▾";
            foreach (var b in new[] { hostBtn, joinBtn, localBtn, startBtn, pauseBtn, x1Btn, x2Btn, x4Btn, detBtn, langBtn }) b.ResetFont();
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
            // a dedicated server: its settings and its buttons instead of host / join
            Ui.StackTop(left, ServerMode ? BuildServerCard() : conn, Ui.Gap(14));

            // ---- right column: session controls, dashboard, log
            var session = new Card { Height = S(74), Padding = new Padding(S(16), S(17), S(16), S(16)) };
            var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = Padding.Empty, Padding = Padding.Empty };
            startBtn.Fit(40); startBtn.Margin = new Padding(0, 0, S(18), 0);
            var speedLabel = new Label { Text = T("VITESSE", "SPEED"), AutoSize = true, Font = Theme.Semibold(8f), ForeColor = Theme.Muted, Margin = new Padding(0, S(12), S(10), 0) };
            pauseBtn.Fit(30); pauseBtn.Margin = new Padding(0, 0, S(4), 0);
            foreach (var b in new[] { x1Btn, x2Btn, x4Btn }) { b.Width = S(52); b.Margin = new Padding(0, 0, S(4), 0); }
            bar.Controls.AddRange(new Control[] { startBtn, speedLabel, pauseBtn, x1Btn, x2Btn, x4Btn });
            startBtn.Visible = !ServerMode;   // (a server starts its world by itself)
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
            foreach (var b in new[] { folderBtn, copyBtn, clearBtn }) { b.Margin = new Padding(S(6), 0, 0, 0); tools.Controls.Add(b); }
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
            footer.Controls.Add(status);
            footer.Controls.Add(gameLabel);
            footer.Controls.Add(by);
            footer.Controls.Add(credit);   // docked first: rightmost

            Controls.Add(body);
            Controls.Add(footer);
            header.Dock = DockStyle.Top;
            Controls.Add(header);

            UpdateDashboard();
        }

        // ---------------------------------------------------------------- language

        /// <summary>Before the window: the language saved in mpfever_settings.txt (lang=), else the game's, else Windows'.</summary>
        public static void InitLanguage()
        {
            LoadSettings().TryGetValue("lang", out var saved);
            var code = L.Detect(saved, out var source);
            L.Set(code);
            Log.W(T("Langue : ", "Language: ") + L.Name + " (" + SourceText(source) + ")");
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
                h = T("Transport Fever 3 est introuvable. Vérifiez que le jeu est installé via Steam.", "Transport Fever 3 was not found. Check that the game is installed through Steam.");
            else if (ServerMode && st) h = F("Le serveur héberge son monde. Les joueurs le rejoignent depuis la fenêtre MPFever de leur jeu avec l'adresse de ce PC, port {0}.\n\nTapez help sous le journal pour les commandes du serveur.",
                                             "The server hosts its world. Players join it from the MPFever window of their game with this PC's address, port {0}.\n\nType help under the log for the server commands.", server?.Port ?? 28090);
            else if (ServerMode) h = (menuText ?? "") + T("\n\nTapez help sous le journal pour les commandes du serveur.", "\n\nType help under the log for the server commands.");
            else if (menuMode && !string.IsNullOrEmpty(menuText)) h = menuText;
            else if (menuMode) h = T("Le jeu démarre. Choisissez « Multijoueur (MPFever) » dans son menu principal pour héberger ou rejoindre une partie.",
                                     "The game is starting. Choose « Multiplayer (MPFever) » in its main menu to host or join a game.");
            else if (host && !st) h = T("Chargez exactement la même sauvegarde dans chaque jeu, puis cliquez sur « Démarrer la partie ».",
                                        "Load exactly the same savegame in every game, then click « Start the game ».");
            else if (host) h = T("Partie en cours. La vitesse choisie s'applique à tous les joueurs ; la synchronisation est vérifiée toutes les 10 s.",
                                 "Game running. The speed you choose applies to every player; sync is checked every 10 s.");
            else if (client) h = T("Connecté. L'hôte démarre la partie et règle la vitesse.", "Connected. The host starts the game and sets the speed.");
            else h = T("Hébergez une partie ou rejoignez un ami avec son adresse IP.\n\nPort par défaut : 28090 (TCP). Pour jouer par Internet, l'hôte doit rediriger ce port sur sa box.", "Host a game, or join a friend with their IP address.\n\nDefault port: 28090 (TCP). To play over the Internet, the host must forward this port on their router.");
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
            if (autotest || Dev || JoinAtStart != null || !Updater.Enabled) { Init(); return; }
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
                    using (var dlg = new UpdateDialog(u)) choice = dlg.ShowDialog(this);
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

        void Init()
        {
            gameDir = GameInstall.FindGameDir();
            if (gameDir == null) { gameMissing = true; Log.Err(T("Transport Fever 3 introuvable.", "Transport Fever 3 not found.")); status.Text = T("Jeu introuvable", "Game not found"); return; }
            Log.W(T("Jeu : ", "Game: ") + gameDir);
            try { GameInstall.EnsureSteamAppId(gameDir); } catch (Exception e) { Log.W("steam_appid.txt : " + e.Message); }
            try { GameInstall.InstallNative(gameDir); } catch (Exception e) { Log.W("winhttp.dll: " + e.Message); }
            try { GameInstall.EnsureModActive(); } catch (Exception e) { Log.W("settings.lua: " + e.Message); }
            try { GameInstall.InstallMod(); } catch (Exception e) { Log.Warn(T("Installation du mod : ", "Mod installation: ") + e.Message); }
            if (ServerMode)
            {
                StartServerMode();
                return;
            }
            if (MenuModeDefault && !autotest)
            {
                StartMenuMode();
                return;
            }
            if (autotest)
            {
                Guard(StartLocalTest);
                new Thread(AutoTest) { IsBackground = true, Name = "Autotest" }.Start();
            }
        }

        // ---------------------------------------------------------------- main menu mode

        static string SettingsFile => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mpfever_settings.txt");

        internal static Dictionary<string, string> LoadSettings()
        {
            var d = new Dictionary<string, string>();
            try { foreach (var l in File.ReadAllLines(SettingsFile)) { int i = l.IndexOf('='); if (i > 0) d[l.Substring(0, i)] = l.Substring(i + 1); } } catch { }
            return d;
        }

        internal static void SaveSetting(string k, string v)
        {
            var d = LoadSettings();
            d[k] = v;
            try { File.WriteAllLines(SettingsFile, d.Select(kv => kv.Key + "=" + kv.Value)); } catch { }
        }

        /// <summary>The player name kept from the last host or join in the MPFever window (name= in mpfever_settings.txt),
        /// else the Windows user name. The game and the launcher window both start with it.</summary>
        static string SavedName() => LoadSettings().TryGetValue("name", out var n) && n != "" ? n : Environment.UserName;

        /// <summary>MPFever.exe started normally: the game starts at once; hosting or joining is chosen in the MPFever
        /// window of its main menu.</summary>
        void StartMenuMode()
        {
            menuMode = true;
            running = true;
            hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false;
            menuGame = new GameLink(SavedName(), "menu");
            games.Add(menuGame);
            menuGame.Exited += () => { Log.W(T("Transport Fever 3 fermé : fin de MPFever.", "Transport Fever 3 closed: MPFever exits.")); try { BeginInvoke((Action)Close); } catch { } };
            MenuStatus();
            menuGame.Launch(gameDir);
            WindowState = FormWindowState.Minimized;
            Log.W(T("Le jeu démarre : choisissez « Multijoueur (MPFever) » dans son menu principal.", "The game is starting: choose « Multiplayer (MPFever) » in its main menu."));
            new Thread(MenuLoop) { IsBackground = true, Name = "Menu link" }.Start();
            if (JoinAtStart != null)
            {
                var addr = JoinAtStart;
                new Thread(() => { Thread.Sleep(1000); OnMenuRequest("join", addr, menuGame.Name); }) { IsBackground = true }.Start();
            }
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
                menuGame.WriteMenuState(new Dictionary<string, string>
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
                    ["invite"] = steamConnect != null ? "1" : "",
                    ["lang"] = L.Code,
                });
            }
            catch (Exception e) { Log.W("menu_state: " + e.Message); }
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
            name = new string((name ?? "").Trim().Where(c => char.IsLetterOrDigit(c) || c == '_' || c == '-').ToArray());
            if (name == "") name = new string(Environment.UserName.Where(char.IsLetterOrDigit).ToArray());
            if (name == "") name = "Player";
            Log.Dim(F("Menu : {0} {1} ({2})", "Menu: {0} {1} ({2})", cmd, arg, name));
            // a dedicated server's game: nobody hosts or joins from its menu (the console drives the server)
            if (server != null) { ServerMenuRequest(cmd); return; }
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
                if (companyMode == "separate")
                    Log.Warn(T("« Une entreprise par joueur » est en cours de développement : il reste énormément de bugs. À utiliser surtout pour tester et aider au développement du mod.",
                               "\"One company per player\" is still in development: many bugs remain. Use it mainly to test it and help the development of the mod."));
                menuGame.SetIdentity(name, "host");
                int port = (int)portBox.Value;
                try { StartHost(name, false, menuGame); }
                catch (Exception e) { menuPhase = "error"; menuText = T("Impossible d'héberger : ", "Cannot host: ") + e.Message; MenuStatus(); return; }
                // the lobby opens: the savegame is loaded once the host starts the game (see StartLobbyGame), by every game at once
                lobbySave = arg; lobbyOpen = true; lobbyStarting = false;
                // Steam: friends can join from their friends list or an invitation
                new Thread(() =>
                {
                    // the public IPv4 and, when this PC has one, its IPv6 (behind DS-Lite only the IPv6 reaches it)
                    var v6 = LoadSettings().TryGetValue("ipv6", out var i6) && i6.Trim() == "0" ? new List<string>() : NetAddr.PublicIPv6List();
                    steamConnect = "+mpfever_connect " + PublicAddress() + ":" + port + string.Concat(v6.Select(a => "," + NetAddr.Show(a, port)));
                    SteamCtl("presence", steamConnect);
                    Log.Ok(T("Steam : invitations possibles (", "Steam: invitations enabled (") + steamConnect + ")");
                    MenuStatus();
                }) { IsBackground = true, Name = "Steam presence" }.Start();
                menuPhase = "lobby";
                menuText = F("Salon ouvert (« {0} »). Les autres joueurs rejoignent avec votre adresse IP, port {1} (TCP, à rediriger sur votre box pour Internet). Adresse locale : {2}. Lancez la partie quand tout le monde est là.", "Lobby open (« {0} »). Other players join with your IP address, port {1} (TCP, to forward on your router for the Internet). Local address: {2}. Start the game when everybody is here.", arg, port, LocalAddresses() + string.Concat(NetAddr.PublicIPv6List().Select(a6 => ", " + NetAddr.Show(a6, port))));
                MenuStatus();
            }
            else if (cmd == "start")
            {
                if (!lobbyOpen || hostGame == null) return;
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
                int port = (int)portBox.Value;
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
                    return;
                }
                // (a host that refused this player already said why)
                if (!clientCancelled) { menuPhase = "connected"; menuText = T("Connecté. L'hôte prépare sa partie...", "Connected. The host is preparing its game..."); MenuStatus(); }
            }
            else if (cmd == "invite")
            {
                if (steamConnect != null) SteamCtl("invite", steamConnect);
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
            else if (cmd == "leave")
            {
                // the player went back to the game's main menu: the session ends here (not during a resynchronisation)
                if (resyncing) { Log.Warn(T("Retour au menu pendant une resynchronisation : session conservée.", "Back to the menu during a resynchronisation: session kept.")); return; }
                EndSession();
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

        /// <summary>The player left the game for the main menu: connections closed, the session's state cleared, the files the
        /// game and MPFever.exe exchange emptied (the next game must not read the previous session's messages). The game
        /// keeps running: the MPFever window of its main menu can host or join again.</summary>
        void EndSession(string why = null)
        {
            Log.W(why ?? T("=== Retour au menu principal : fin de la session ===", "=== Back to the main menu: the session ends ==="));
            sessionGen++;
            clientCancelled = true;
            foreach (var cl in clients.ToList()) try { cl.Dispose(); } catch { }
            lock (clients) clients.Clear();
            var r = relay; relay = null;
            if (r != null) try { r.Dispose(); } catch { }
            if (hostGame != null && hostFromGame != null) hostGame.FromGame -= hostFromGame;
            if (menuGame != null && clientFromGame != null) menuGame.FromGame -= clientFromGame;
            hostFromGame = clientFromGame = null;
            hostGame = null;
            hostName = null;
            lock (sessionGate) { started = false; speed = 0; pauseAt = null; }
            lock (players) players.Clear();
            lock (clocks) clocks.Clear();
            lock (hashes) hashes.Clear();
            lock (chatLog) { chatLog.Clear(); chatId = 0; }
            lock (resyncParts) resyncParts.Clear();   // a host game half received in the session that ends
            hashN = 0; syncText = "—"; actsRelayed = actRefused = actFails = desyncs = 0;
            resyncing = false; resyncDropping = false; resyncWaiting.Clear(); ignoredParts.Clear(); postResyncHashN = -1; driftSince = -1; diffStreak = 0; lastDiffKeys = ""; lock (partStreak) partStreak.Clear();
            joinPending = false;
            lobbyOpen = lobbyStarting = false; lobbySave = ""; lobbyPlayers = "";
            joinedAddr = null;
            if (steamConnect != null) { steamConnect = null; SteamCtl("clear", null); }
            if (menuGame != null)
            {
                menuGame.InGame = false;
                foreach (var f in new[] { "in.log", "out.log", "ui.log", "started.txt", "results.log", "native_events.log", "resync_claims.txt",
                                          "resync_pending.txt", "bindings.log", "captured.txt", "companies.txt", "shares.txt",
                                          "chat.txt", "chat_out.txt" })
                    try { var p = Path.Combine(menuGame.Dir, f); if (File.Exists(p)) File.WriteAllText(p, ""); } catch { }
            }
            menuPhase = "idle"; menuText = ""; menuLoad = ""; menuLoadSeq = "";
            MenuStatus();
        }

        /// <summary>The players in the host's lobby: the host first, then those connected (names without their number).</summary>
        string LobbyList()
        {
            var names = new List<string> { BaseName(hostName ?? "") };
            foreach (var n in relay?.PeerNames() ?? new string[0]) names.Add(BaseName(n));
            return string.Join(", ", names.Where(x => x != ""));
        }

        /// <summary>Tells the players in the lobby who is there (shown in their MPFever window).</summary>
        void BroadcastLobby()
        {
            if (!lobbyOpen || relay == null) return;
            relay.Broadcast(Msg.Make("lobby", hostName, "{[\"players\"]=" + LuaLit.Quote(LobbyList()) + ",[\"save\"]=" + LuaLit.Quote(lobbySave)
                + ",[\"host\"]=" + LuaLit.Quote(BaseName(hostName ?? "")) + "}"));
        }

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
                lobbyStarting = true;
                lobbyOpen = false;
                int id = Interlocked.Increment(ref resyncId);
                string[] peers = relay?.PeerNames() ?? new string[0];
                lock (resyncWaiting) { resyncWaiting.Clear(); resyncWaiting.Add(hostName); foreach (var p in peers) resyncWaiting.Add(p); }
                Log.W(F("=== Lancement de la partie « {0} » pour {1} joueur(s) : envoi de la sauvegarde ({2:0.0} Mo) ===", "=== Starting the game « {0} » for {1} player(s): sending the savegame ({2:0.0} MB) ===", lobbySave, peers.Length + 1, bytes.Length / 1048576.0));
                HostChat("msg", "MPFever", T("L'hôte lance la partie : chargement...", "The host starts the game: loading..."));
                int parts = (bytes.Length + ResyncChunk - 1) / ResyncChunk;
                for (int i = 0; i < parts; i++)
                {
                    int len = Math.Min(ResyncChunk, bytes.Length - i * ResyncChunk);
                    relay?.Broadcast(Msg.Make("resync_file", hostName,
                        "{[\"id\"]=" + id + ",[\"i\"]=" + i + ",[\"n\"]=" + parts + ",[\"data\"]=\"" + Convert.ToBase64String(bytes, i * ResyncChunk, len) + "\"}"));
                }
                // the host's own game loads the savegame from the main menu (mpfever_auto.lua)
                lastLoadOrder = Now;
                menuLoad = lobbySave; menuLoadSeq = "h" + DateTime.Now.Ticks;
                menuPhase = "loading"; menuText = T("Chargement de la partie...", "Loading the game...");
                MenuStatus();
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

        bool WaitUntil(Func<bool> cond, double seconds)
        {
            var end = Now + seconds;
            while (Now < end) { if (cond()) return true; Thread.Sleep(500); }
            return cond();
        }

        void AutoTest()
        {
            try
            {
                AutoLine("savegame: " + GameLink.AutoSave);
                bool ready = WaitUntil(() =>
                {
                    int n; lock (players) n = players.Count;
                    lock (clocks) return n >= 2 && clocks.Count >= 2 && clocks.Values.Select(c => c.T).Distinct().Count() == 1;
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
                StartSession();
                Thread.Sleep(8000);
                var scenarios = (Environment.GetEnvironmentVariable("MPFEVER_SCENARIO") ?? "newroad,upgrade").Split(',');
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
                    if (scenario == "resync")
                    {
                        // every game reloads the host's savegame (as when a player joins): the companies must come back as they were
                        if (role == "host") { resyncing = true; AutoLine("resynchronisation requested"); Resync("autotest"); Thread.Sleep(8000); }
                        continue;
                    }
                    lock (autoDone) autoDone.Remove(role);
                    AutoLine("scenario " + scenario + " by " + role);
                    HostSend(Msg.Make(scenario, hostName, "{[\"role\"]=\"" + role + "\",[\"offset\"]=" + (role == "host" ? 0 : 7) + (role == "host" ? ",[\"ab\"]=true" : "") + "}"));
                    bool done = WaitUntil(() => { lock (autoDone) return autoDone.ContainsKey(role); }, 180);
                    lock (autoDone) AutoLine(role + " scenario: " + (done ? autoDone[role] : "TIMEOUT"));
                    Thread.Sleep(5000);
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

        void StartHost(string name, bool launch, GameLink existing = null)
        {
            hostName = name;
            relay = new Relay();
            // a dedicated server lets in only the players with its password and its version, up to its number of players
            if (server != null) { var r = relay; relay.Admit = (p, m) => ServerAdmit(r, p, m); }
            relay.Joined += p =>
            {
                Log.Ok(F("{0} a rejoint la session", "{0} joined the session", p.Name));
                lock (leftAt) leftAt.Remove(BaseName(p.Name));
                relay.DropOlder(p);
                relay.Send(p, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(p.Name) + ",[\"role\"]=\"client\"}"));
                Msg[] history; lock (chatLog) history = chatLog.ToArray();
                foreach (var c in history) relay.Send(p, c);   // the chat so far (a reconnecting player skips what it has)
                HostChat("join", BaseName(p.Name), "");
                BroadcastSession();
                // started from the main menu: the new player receives the host's game (every game reloads it); in the lobby, it
                // waits there for the host to start the game
                if (menuMode) { if (lobbyOpen) BroadcastLobby(); else joinPending = true; MenuStatus(); }
            };
            relay.Left += p =>
            {
                Log.Warn(F("{0} a quitté la session", "{0} left the session", p.Name));
                lock (leftAt) leftAt[BaseName(p.Name)] = Now;
                HostChat("left", BaseName(p.Name), "");
                lock (players) players.Remove(p.Name);
                lock (clocks) clocks.Remove(p.Name);
                HostSend(Msg.Make("peerleft", hostName, "{[\"name\"]=" + LuaLit.Quote(p.Name) + "}"));
                // (a player gone from the lobby, or while the lobby's games load: nobody waits for it)
                lock (resyncWaiting) if (lobbyStarting) resyncWaiting.Remove(p.Name);
                if (lobbyOpen) { BroadcastLobby(); MenuStatus(); }
                if (server != null) ServerPlayerLeft(p);
            };
            relay.Received += (p, m) => OnHostMessage(m, p);
            relay.Start(server != null ? server.Port : (int)portBox.Value);

            hostGame = existing ?? new GameLink(name, "host");
            if (!games.Contains(hostGame)) games.Add(hostGame);
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
            int gen = sessionGen;
            new Thread(() => HostLoop(gen)) { IsBackground = true, Name = "Host loop" }.Start();
        }

        void StartClient(string name, string host, int port, bool launch, GameLink existing = null, string password = null)
        {
            var game = existing ?? new GameLink(name, "client");
            if (!games.Contains(game)) games.Add(game);
            Client current = null;
            clientCancelled = false;
            // a reconnect thread of an earlier session must not wake up in this one (issue #13)
            int gen = sessionGen;
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
                current?.Send(m);
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
                client.Received += m =>
                {
                    if (m.Kind == "resync_file") { OnResyncFile(game, m); return; }
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
                        myId = youName;
                    game.ToGame(m);
                    if (m.Kind == "act") Log.Dim(F("[{0}] reçu {1} de {2}", "[{0}] received {1} from {2}", name, m.Kind, m.From));
                };
                client.Closed += () =>
                {
                    lock (clients) clients.Remove(client);
                    if (current == client) current = null;   // nothing is sent until reconnected
                    Log.Warn(F("[{0}] connexion à l'hôte perdue", "[{0}] connection to the host lost", name));
                    ClientStatus(deniedText != null ? "denied" : "lost", 0);
                    game.ToGame(Msg.Make("session", "MPFever", "{[\"started\"]=false,[\"speed\"]=0}"));
                    if (!menuMode || clientCancelled || gen != sessionGen) return;
                    // a host game half received over this connection never completes (the host sends it again under a
                    // new number), and a host whose MPFever restarted counts from 1 again: its parts must not be mixed
                    // with the old ones (issue #29)
                    lock (resyncParts) resyncParts.Clear();
                    // the connection dropped: try again for 5 minutes; back with the host, this game receives its
                    // game again like any player who joins
                    new Thread(() =>
                    {
                        var end = DateTime.UtcNow.AddMinutes(5);
                        for (int attempt = 1; DateTime.UtcNow < end && !clientCancelled && gen == sessionGen; attempt++)
                        {
                            menuPhase = "connecting";
                            menuText = F("Connexion à l'hôte perdue : reconnexion (essai {0})...", "Connection to the host lost: reconnecting (attempt {0})...", attempt);
                            MenuStatus();
                            ClientStatus("lost", attempt);
                            Thread.Sleep(5000);
                            if (clientCancelled || gen != sessionGen) return;
                            var c = new Client();
                            try
                            {
                                wire(c);
                                c.Connect(host, port, name, password);
                                lock (clients) clients.Add(c);
                                current = c;
                                Log.Ok(F("[{0}] reconnecté à l'hôte", "[{0}] reconnected to the host", name));
                                menuPhase = "connected"; menuText = T("Reconnecté. L'hôte renvoie sa partie...", "Reconnected. The host sends its game again..."); MenuStatus();
                                return;
                            }
                            catch (Exception e) { Log.Warn(T("Reconnexion : ", "Reconnecting: ") + e.Message); }
                        }
                        if (!clientCancelled && gen == sessionGen) { menuPhase = "error"; menuText = T("Connexion à l'hôte perdue (reconnexion impossible).", "Connection to the host lost (could not reconnect)."); MenuStatus(); ClientStatus("gone", 0); }
                    }) { IsBackground = true, Name = "Reconnect" }.Start();
                };
            };
            var first = new Client();
            wire(first);
            first.Connect(host, port, name, password);
            lock (clients) clients.Add(first);
            current = first;
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
            if (launch) game.Launch(gameDir);
        }

        void StartLocalTest()
        {
            StartHost("Host", true);
            Log.W(T("Lancement du second jeu dans 20 s...", "Starting the second game in 20 s..."));
            var t = new System.Windows.Forms.Timer { Interval = autotest ? 8000 : 20000 };
            t.Tick += (s, e) =>
            {
                t.Stop();
                try { StartClient("Client", "127.0.0.1", (int)portBox.Value, true); }
                catch (Exception ex) { Log.Warn(T("Client local : ", "Local client: ") + ex.Message); }
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
            Kv("started", st ? 1 : 0);
            Kv("speed", paused ? 0 : sp);
            Kv("sync", resyncing ? "resync" : syncState == 1 ? "ok" : syncState == 2 ? "drift" : syncState == 3 ? "desync" : "none");
            Kv("parts", syncParts);
            Kv("age", lastSyncAt < 0 ? -1 : (int)(Now - lastSyncAt));
            Kv("desyncs", desyncs);
            Kv("resyncs", resyncId);
            Kv("invite", steamConnect != null ? 1 : 0);

            string[] ready; lock (players) ready = players.ToArray();
            var connected = relay?.PeerNames() ?? new string[0];
            HashSet<string> waiting; lock (resyncWaiting) waiting = new HashSet<string>(resyncWaiting);
            Dictionary<string, PlayerClock> cl; lock (clocks) cl = new Dictionary<string, PlayerClock>(clocks);
            double lead = cl.Count == 0 ? 0 : cl.Values.Max(Estimate);
            var present = new HashSet<string>();
            void P(string id, string state, long lag)
            {
                present.Add(BaseName(id));
                sb.Append("p=").Append(id).Append('\t').Append(BaseName(id)).Append('\t').Append(state).Append('\t')
                  .Append(lag).Append('\t').Append(id == hostName ? (server != null ? "server" : "host") : "").Append('\n');
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
            hostGame?.WriteStatus(text + "me=" + hostName + "\nconn=ok\nattempt=0\nt=" + UnixNow() + "\n");
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

        /// <summary>Starting capital of a new company: MPFEVER_COMPANY_START, else (dedicated server) start-money in
        /// mpfever_server.properties, else companystart=N in mpfever_settings.txt, else 2,000,000.</summary>
        string StartMoney()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_COMPANY_START");
            if (string.IsNullOrEmpty(v) && server != null) v = server.StartMoney.ToString(CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(v)) LoadSettings().TryGetValue("companystart", out v);
            return long.TryParse(v ?? "", out long n) && n >= 0 ? n.ToString() : "2000000";
        }

        string SessionPayload()
        {
            lock (sessionGate)
                return "{[\"started\"]=" + (started ? "true" : "false") + ",[\"speed\"]=" + speed +
                       (pauseAt.HasValue ? ",[\"pauseAt\"]=" + pauseAt.Value : "") +
                       ",[\"cmode\"]=\"" + companyMode + "\"" +
                       (companyMode == "separate" ? ",[\"cstart\"]=" + StartMoney() : "") +
                       // a dedicated server plays no company: the savegame's company goes to its owner (owner=, else nobody)
                       (companyMode == "separate" && server != null ? ",[\"owner\"]=" + LuaLit.Quote(OwnerKey()) : "") + "}";
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
            if (p.HasValue && MaxClock() >= p.Value)
            {
                // the games may have stopped a batch apart: the check is taken at the latest of their times (the others
                // catch up to it)
                long at; lock (clocks) at = Math.Max(p.Value, clocks.Count == 0 ? 0 : clocks.Values.Max(c => c.T));
                HostSend(Msg.Make("hash", hostName, "{[\"n\"]=" + n + ",[\"at\"]=" + at + ",[\"paused\"]=true}"));
            }
            else
                HostSend(Msg.Make("hash", hostName, "{[\"n\"]=" + n + ",[\"at\"]=" + FutureStamp() + "}"));
        }

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

        void OnHostMessage(Msg m, Peer from)
        {
            // a dedicated server: a player whose game is not in this session's world yet (it reconnected after a restart of
            // the server, still in its old world) only counts once its game has loaded the server's world: its clock,
            // actions and checks are those of another world
            if (server != null && from != null && m.Kind != "hello" && m.Kind != "chat")
            {
                bool ready; lock (players) ready = players.Contains(m.From);
                if (!ready) return;
            }
            switch (m.Kind)
            {
                case "hello":
                    lock (players) players.Add(m.From);
                    Log.W(F("{0} : jeu prêt {1}", "{0}: game ready {1}", m.From, m.Payload));
                    // a game started again (resynchronisation): it needs its identity again
                    if (from != null) relay.Send(from, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(from.Name) + ",[\"role\"]=\"client\"}"));
                    lock (resyncWaiting) resyncWaiting.Remove(m.From);
                    if (from != null && server != null) ServerGreet(from);
                    break;

                case "replay_failed":
                    {
                        // a game could not reproduce a build of another player: the games differ for sure, no need to wait
                        // for the next checkpoints (and for the long cooldown) before reloading the host's game
                        Log.Warn(F("{0} : une construction n'a pas pu être reproduite {1}", "{0}: a build could not be reproduced {1}", m.From, m.Payload));
                        int others; lock (players) others = players.Count(p => p != hostName);
                        if (started && !resyncing && !autotest && others > 0 && Now - lastResync > 15)
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
                            var pc = Msg.Make("peerclock", hostName, "{[\"name\"]=" + LuaLit.Quote(m.From) + ",[\"t\"]=" + (long)td + ",[\"ah\"]=" + ah
                                + (tl > 0 ? ",[\"tl\"]=" + tl : "") + (bl > 0 ? ",[\"bl\"]=" + bl : "") + "}");
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
                        if (resyncDropping)
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
                    // something every player must know, told in the chat (it shows for a few seconds on every game)
                    if (m.Payload.Contains("tutorial"))
                    {
                        string text = T("Le tutoriel n'est pas pris en charge en multijoueur : ses missions se valident sur chaque jeu séparément et les parties divergent. Jouez une partie sans tutoriel.",
                                        "The tutorial is not supported in multiplayer: its missions are validated on each game separately and the games diverge. Play a game without the tutorial.");
                        Log.Warn(text);
                        HostChat("msg", "MPFever", text);
                    }
                    break;

                default:
                    if (resyncDropping && m.Kind == "nat_pending") break;   // (its build is dropped, see "act")
                    lock (sendGate)
                    {
                        if (from != null) hostGame?.ToGame(m);
                        relay.Broadcast(m, from);
                    }
                    if (m.Kind != "chat") Log.W($"{m.From} : {m.Kind} {m.Payload}");
                    break;
            }
        }

        // a difference line is "name: values"; names may contain ':' themselves (script:mission)
        static string DiffKey(string d) { int i = d.IndexOf(": ", StringComparison.Ordinal); return i < 0 ? d : d.Substring(0, i); }

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
            lock (hashes)
            {
                if (!hashes.TryGetValue(n, out var d)) return;
                d[m.From] = parts;
                if (d.Count >= expected) { got = d; hashes.Remove(n); }
                foreach (var old in hashes.Keys.Where(k => k < n - 20).ToList()) hashes.Remove(old);
            }
            if (got == null) return;
            lastSyncAt = Now;
            var names = got.Keys.OrderBy(k => k).ToList();
            var keys = got.Values.Where(v => v != null).SelectMany(v => v.Keys.Select(k => k.ToString())).Distinct().OrderBy(k => k).ToList();
            var diffs = new List<string>();
            foreach (var k in keys)
            {
                var vals = names.Select(nm => got[nm] != null && got[nm].TryGetValue(k, out var v) ? LuaLit.Show(v) : "absent").ToList();
                if (vals.Distinct().Count() > 1) diffs.Add($"{k}: " + string.Join(" | ", names.Select((nm, i) => nm + "=" + vals[i])));
            }
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
                pending = partStreak.Keys.Where(k => !CorrectedParts.Contains(k) && !ignoredParts.Contains(k)).ToList();
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
            else if (diffKeys.Where(d => !ignoredParts.Contains(d) && !CorrectedParts.Contains(d)).All(DriftParts.Contains))
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
            int prevSpeed; lock (sessionGate) prevSpeed = Math.Max(1, speed);
            var t0 = DateTime.UtcNow;
            try
            {
                Log.W(F("=== Resynchronisation n°{0} sur la partie de l'hôte (écart : {1}) ===", "=== Resynchronisation #{0} on the host's game (difference: {1}) ===", id, reason));
                // 1. every game stops at the same time
                Pause(T("resynchronisation", "resynchronisation"));
                long at; lock (sessionGate) at = pauseAt ?? 0;
                bool stopped = WaitUntil(() => { lock (clocks) return clocks.Values.All(c => c.T >= at && c.Sp == 0); }, 120);
                if (!stopped) { Log.Err(T("Resynchronisation abandonnée : les jeux ne se sont pas arrêtés.", "Resynchronisation cancelled: the games did not stop.")); return; }
                // 2. the host saves
                saveDone = null;
                resyncDropping = true;
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
                int parts = (bytes.Length + ResyncChunk - 1) / ResyncChunk;
                for (int i = 0; i < parts; i++)
                {
                    int len = Math.Min(ResyncChunk, bytes.Length - i * ResyncChunk);
                    string data = Convert.ToBase64String(bytes, i * ResyncChunk, len);
                    relay?.Broadcast(Msg.Make("resync_file", hostName,
                        "{[\"id\"]=" + id + ",[\"i\"]=" + i + ",[\"n\"]=" + parts + ",[\"data\"]=\"" + data + "\"}"));
                }
                lastLoadOrder = Now;
                hostGame.ToGame(Msg.Make("resync_load", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(ResyncSaveName) + "}"));
                bool back = WaitUntil(() => { lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);
                if (!back) { lock (resyncWaiting) Log.Warn(T("Resynchronisation : sans nouvelles de ", "Resynchronisation: no news from ") + string.Join(", ", resyncWaiting) + T(" (on reprend quand même).", " (resuming anyway).")); }
                resyncDropping = false;
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
                lock (partStreak) partStreak.Clear();
                resyncDropping = false;
                resyncing = false;
                SetSpeed(prevSpeed, T("fin de resynchronisation", "end of resynchronisation"));
            }
        }

        // client side: the host's savegame arrives in pieces; once complete it is written next to this player's
        // savegames and the game loads it
        readonly Dictionary<int, string[]> resyncParts = new Dictionary<int, string[]>();

        void OnResyncFile(GameLink game, Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null) return;
            int id = (int)(double)t["id"], i = (int)(double)t["i"], n = (int)(double)t["n"];
            string[] got;
            lock (resyncParts)
            {
                if (!resyncParts.TryGetValue(id, out got)) resyncParts[id] = got = new string[n];
                got[i] = t["data"] as string;
                if (got.Any(x => x == null))
                {
                    if (menuMode && !game.InGame) { menuPhase = "downloading"; menuText = F("Réception de la partie de l'hôte : {0} %", "Receiving the host's game: {0} %", 100 * got.Count(x => x != null) / n); MenuStatus(); }
                    return;
                }
                resyncParts.Remove(id);
            }
            try
            {
                var bytes = got.SelectMany(Convert.FromBase64String).ToArray();
                string name = ResyncSaveName + " " + new string(game.Name.Where(char.IsLetterOrDigit).ToArray());
                foreach (var d in GameInstall.SaveDirs()) File.WriteAllBytes(Path.Combine(d, name + ".sav"), bytes);
                Log.W(F("[{0}] partie de l'hôte reçue ({1:0.0} Mo) : chargement...", "[{0}] host game received ({1:0.0} MB): loading...", game.Name, bytes.Length / 1048576.0));
                // the host's numbers start again at 1 when its MPFever restarts, while this MPFever and its game remember
                // the loads they did (menu_loaded.txt, resync_claims.txt) and skipped the host's game as already loaded:
                // each game received has a number of its own (issue #29)
                string seq = id + "-" + DateTime.Now.Ticks;
                if (menuMode && !game.InGame)
                {
                    // still in the main menu: its MPFever window loads the savegame
                    menuPhase = "loading"; menuText = T("Chargement de la partie de l'hôte...", "Loading the host's game..."); menuLoad = name; menuLoadSeq = "r" + seq;
                    MenuStatus();
                    return;
                }
                lastLoadOrder = Now;
                game.ToGame(Msg.Make("resync_load", m.From, "{[\"id\"]=" + LuaLit.Quote(seq) + ",[\"name\"]=" + LuaLit.Quote(name) + "}"));
            }
            catch (Exception e) { Log.Warn(F("[{0}] partie de l'hôte : {1}", "[{0}] host game: {1}", game.Name, e.Message)); }
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
            base.OnFormClosed(e);
        }
    }
}
