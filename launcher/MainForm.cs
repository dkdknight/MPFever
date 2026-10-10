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
        [STAThread]
        static int Main(string[] args)
        {
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
            bool auto = args.Length > 0 && args[0] == "--autotest";
            MainForm.Dev = auto || args.Contains("--dev");
            // default: the game starts at once and the session is set up from its main menu (MPFever window)
            MainForm.MenuModeDefault = !MainForm.Dev;
            if (auto) GameLink.AutoSave = args.Length > 1 ? args[1] : "test multi";
            // started by the game from a Steam invitation: join that host at once
            int j = Array.IndexOf(args, "--join");
            if (j >= 0 && j + 1 < args.Length) MainForm.JoinAtStart = args[j + 1];
            Application.Run(new MainForm(auto));
            return 0;
        }
    }

    sealed class MainForm : Form
    {
        public const string Version = "0.3.4-experimental";
        /// <summary>Developer mode (MPFever.exe --dev): local two-game test and determinism test buttons.</summary>
        public static bool Dev;
        public static bool MenuModeDefault;
        public static string JoinAtStart;
        string steamConnect, lastSteamJoin;
        int steamSeq;
        bool menuMode;

        // ---- main menu mode: the game's MPFever window drives the session
        GameLink menuGame;
        string menuPhase = "idle", menuText = "", menuLoad = "", menuLoadSeq = "", lastMenuReq;
        volatile bool joinPending;
        volatile bool clientCancelled;
        const long Step = 200;                 // game time units per simulation step
        const double UnitsPerSecond = 1000;    // game time units per real second at x1
        const double HashEverySeconds = 10;

        readonly TextBox nameBox = new TextBox { Text = Environment.UserName };
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

        string gameDir;
        Relay relay;
        readonly List<GameLink> games = new List<GameLink>();
        readonly List<Client> clients = new List<Client>();
        string hostName;
        GameLink hostGame;
        bool running;

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
        int postResyncHashN = -1;
        readonly HashSet<string> ignoredParts = new HashSet<string>();
        // parts every game corrects by itself from the host's values (not a reason to reload)
        static readonly HashSet<string> CorrectedParts = new HashSet<string> { "money" };
        // game state that is never a local measure, even when it differs right after a reload (a company a game missed must be seen)
        static readonly HashSet<string> NeverLocalParts = new HashSet<string> { "companies", "money", "owners", "loans", "edges", "constructions", "lines" };
        // slow drift of the engine's own simulation (passengers boarding, vehicle positions, the town statistics that
        // follow): not caused by a missed action; reloaded only when it lasts, so that players are not interrupted
        // every two minutes
        static readonly HashSet<string> DriftParts = new HashSet<string> { "vehicles", "onboard", "persons", "stocks",
            "script:towns", "script:towncargo", "script:celebrations", "script:progression", "script:industries",
            // (not the engine's drift: lane connections, crosswalks and traffic lights of the road nodes. New and little
            // proven as a check, so it only reloads when it lasts)
            "nodeConfigs" };
        const double DriftResyncSeconds = 300;
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

            Shown += (s, e) => Init();
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
            Text = "MPFever " + Version + T(" – multijoueur Transport Fever 3 (expérimental)", " – Transport Fever 3 multiplayer (experimental)");
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
            Ui.StackTop(left, conn, Ui.Gap(14));

            // ---- right column: session controls, dashboard, log
            var session = new Card { Height = S(74), Padding = new Padding(S(16), S(17), S(16), S(16)) };
            var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = Padding.Empty, Padding = Padding.Empty };
            startBtn.Fit(40); startBtn.Margin = new Padding(0, 0, S(18), 0);
            var speedLabel = new Label { Text = T("VITESSE", "SPEED"), AutoSize = true, Font = Theme.Semibold(8f), ForeColor = Theme.Muted, Margin = new Padding(0, S(12), S(10), 0) };
            pauseBtn.Fit(30); pauseBtn.Margin = new Padding(0, 0, S(4), 0);
            foreach (var b in new[] { x1Btn, x2Btn, x4Btn }) { b.Width = S(52); b.Margin = new Padding(0, 0, S(4), 0); }
            bar.Controls.AddRange(new Control[] { startBtn, speedLabel, pauseBtn, x1Btn, x2Btn, x4Btn });
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

            if (host) header.SetRole(T("HÔTE", "HOST"), Theme.Accent);
            else if (client) header.SetRole(T("CLIENT", "CLIENT"), Theme.Info);
            else if (menuMode) header.SetRole(T("MENU DU JEU", "GAME MENU"), Theme.Success);
            else header.SetRole(T("PRÊT", "READY"), Theme.Muted);

            // players
            if (host)
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
            if (gameMissing)
                h = T("Transport Fever 3 est introuvable. Vérifiez que le jeu est installé via Steam.", "Transport Fever 3 was not found. Check that the game is installed through Steam.");
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

        string PlayerName() => string.IsNullOrWhiteSpace(nameBox.Text) ? "joueur" : nameBox.Text.Trim();
        double Now => clockWatch.Elapsed.TotalSeconds;

        void Guard(Action a)
        {
            if (running) { Log.Warn(T("Une session est déjà en cours : relancer MPFever pour en ouvrir une autre.", "A session is already running: restart MPFever to open another one.")); return; }
            try { a(); running = true; hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false; }
            catch (Exception e) { Log.Err(T("Erreur : ", "Error: ") + e.Message); MessageBox.Show(this, e.Message, "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Error); }
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

        /// <summary>MPFever.exe started normally: the game starts at once; hosting or joining is chosen in the MPFever
        /// window of its main menu.</summary>
        void StartMenuMode()
        {
            menuMode = true;
            running = true;
            hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false;
            var st = LoadSettings();
            menuGame = new GameLink(st.TryGetValue("name", out var n) && n != "" ? n : Environment.UserName, "menu");
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
            if (hostGame != null || clients.Count > 0) { Log.Warn(T("Déjà dans une session : invitation ignorée.", "Already in a session: invitation ignored.")); return; }
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
            if (hostGame != null && relay != null)
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
            if (name == "") name = "joueur";
            Log.Dim(F("Menu : {0} {1} ({2})", "Menu: {0} {1} ({2})", cmd, arg, name));
            SaveSetting("name", name);
            if (cmd == "host")
            {
                if (hostGame != null || clients.Count > 0) return;
                // the host's choice: everybody plays one company ("shared") or each player has its own ("separate")
                if (Environment.GetEnvironmentVariable("MPFEVER_COMPANIES") == null) companyMode = option == "separate" ? "separate" : "shared";
                Log.W(F("Mode des entreprises : {0}", "Company mode: {0}", companyMode));
                menuGame.SetIdentity(name, "host");
                int port = (int)portBox.Value;
                try { StartHost(name, false, menuGame); }
                catch (Exception e) { menuPhase = "error"; menuText = T("Impossible d'héberger : ", "Cannot host: ") + e.Message; MenuStatus(); return; }
                menuLoad = arg; menuLoadSeq = "h" + DateTime.Now.Ticks;   // the game loads the chosen savegame
                // Steam: friends can join from their friends list or an invitation
                new Thread(() =>
                {
                    steamConnect = "+mpfever_connect " + PublicAddress() + ":" + port;
                    SteamCtl("presence", steamConnect);
                    Log.Ok(T("Steam : invitations possibles (", "Steam: invitations enabled (") + steamConnect + ")");
                    MenuStatus();
                }) { IsBackground = true, Name = "Steam presence" }.Start();
                menuPhase = "hosting";
                menuText = F("Partie hébergée (« {0} »). Les autres joueurs rejoignent avec votre adresse IP, port {1} (TCP, à rediriger sur votre box pour Internet). Adresse locale : {2}", "Game hosted (« {0} »). Other players join with your IP address, port {1} (TCP, to forward on your router for the Internet). Local address: {2}", arg, port, LocalAddresses());
                MenuStatus();
            }
            else if (cmd == "join")
            {
                if (hostGame != null || clients.Count > 0) return;
                string host = arg.Trim();
                int port = (int)portBox.Value;
                int c = host.LastIndexOf(':');
                if (c > 0 && int.TryParse(host.Substring(c + 1), out int p2)) { port = p2; host = host.Substring(0, c); }
                SaveSetting("addr", arg.Trim());
                menuGame.SetIdentity(name, "client");
                menuPhase = "connecting"; menuText = F("Connexion à {0}:{1}...", "Connecting to {0}:{1}...", host, port); MenuStatus();
                try { StartClient(name, host, port, false, menuGame); }
                catch (Exception e)
                {
                    clients.Clear();
                    games.Remove(menuGame); games.Add(menuGame);
                    menuPhase = "error"; menuText = F("Connexion impossible à {0}:{1} : ", "Cannot connect to {0}:{1}: ", host, port) + e.Message; MenuStatus();
                    return;
                }
                menuPhase = "connected"; menuText = T("Connecté. L'hôte prépare sa partie...", "Connected. The host is preparing its game..."); MenuStatus();
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
            else if (cmd == "cancel")
            {
                clientCancelled = true;
                foreach (var cl in clients.ToList()) cl.Dispose();
                clients.Clear();
                menuPhase = "idle"; menuText = ""; MenuStatus();
            }
        }

        /// <summary>Host started from the menu: the session starts as soon as its game runs the savegame.</summary>
        void AutoStart()
        {
            WaitUntil(() => { lock (clocks) return hostName != null && clocks.ContainsKey(hostName); }, 120);
            Thread.Sleep(1000);
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
            relay.Joined += p =>
            {
                Log.Ok(F("{0} a rejoint la session", "{0} joined the session", p.Name));
                relay.DropOlder(p);
                relay.Send(p, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(p.Name) + ",[\"role\"]=\"client\"}"));
                BroadcastSession();
                // started from the main menu: the new player receives the host's game (every game reloads it)
                if (menuMode) { joinPending = true; MenuStatus(); }
            };
            relay.Left += p =>
            {
                Log.Warn(F("{0} a quitté la session", "{0} left the session", p.Name));
                lock (players) players.Remove(p.Name);
                lock (clocks) clocks.Remove(p.Name);
                HostSend(Msg.Make("peerleft", hostName, "{[\"name\"]=" + LuaLit.Quote(p.Name) + "}"));
            };
            relay.Received += (p, m) => OnHostMessage(m, p);
            relay.Start((int)portBox.Value);

            hostGame = existing ?? new GameLink(name, "host");
            if (!games.Contains(hostGame)) games.Add(hostGame);
            hostGame.FromGame += (g, m) =>
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
            new Thread(HostLoop) { IsBackground = true, Name = "Host loop" }.Start();
        }

        void StartClient(string name, string host, int port, bool launch, GameLink existing = null)
        {
            var game = existing ?? new GameLink(name, "client");
            if (!games.Contains(game)) games.Add(game);
            Client current = null;
            clientCancelled = false;
            game.FromGame += (g, m) =>
            {
                if (m.Kind == "hello") { g.InGame = true; if (menuMode) { menuPhase = "ingame"; menuText = T("En partie.", "In game."); MenuStatus(); } }
                current?.Send(m);
            };
            Action<Client> wire = null;
            wire = client =>
            {
                client.Received += m =>
                {
                    if (m.Kind == "resync_file") { OnResyncFile(game, m); return; }
                    game.ToGame(m);
                    if (m.Kind == "act") Log.Dim(F("[{0}] reçu {1} de {2}", "[{0}] received {1} from {2}", name, m.Kind, m.From));
                };
                client.Closed += () =>
                {
                    lock (clients) clients.Remove(client);
                    if (current == client) current = null;   // nothing is sent until reconnected
                    Log.Warn(F("[{0}] connexion à l'hôte perdue", "[{0}] connection to the host lost", name));
                    game.ToGame(Msg.Make("session", "MPFever", "{[\"started\"]=false,[\"speed\"]=0}"));
                    if (!menuMode || clientCancelled) return;
                    // the connection dropped: try again for 5 minutes; back with the host, this game receives its
                    // game again like any player who joins
                    new Thread(() =>
                    {
                        var end = DateTime.UtcNow.AddMinutes(5);
                        for (int attempt = 1; DateTime.UtcNow < end && !clientCancelled; attempt++)
                        {
                            menuPhase = "connecting";
                            menuText = F("Connexion à l'hôte perdue : reconnexion (essai {0})...", "Connection to the host lost: reconnecting (attempt {0})...", attempt);
                            MenuStatus();
                            Thread.Sleep(5000);
                            if (clientCancelled) return;
                            var c = new Client();
                            try
                            {
                                wire(c);
                                c.Connect(host, port, name);
                                lock (clients) clients.Add(c);
                                current = c;
                                Log.Ok(F("[{0}] reconnecté à l'hôte", "[{0}] reconnected to the host", name));
                                menuPhase = "connected"; menuText = T("Reconnecté. L'hôte renvoie sa partie...", "Reconnected. The host sends its game again..."); MenuStatus();
                                return;
                            }
                            catch (Exception e) { Log.Warn(T("Reconnexion : ", "Reconnecting: ") + e.Message); }
                        }
                        if (!clientCancelled) { menuPhase = "error"; menuText = T("Connexion à l'hôte perdue (reconnexion impossible).", "Connection to the host lost (could not reconnect)."); MenuStatus(); }
                    }) { IsBackground = true, Name = "Reconnect" }.Start();
                };
            };
            var first = new Client();
            wire(first);
            first.Connect(host, port, name);
            lock (clients) clients.Add(first);
            current = first;
            if (launch) game.Launch(gameDir);
        }

        void StartLocalTest()
        {
            StartHost("Hote", true);
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

        /// <summary>Starting capital of a new company: MPFEVER_COMPANY_START, else companystart=N in mpfever_settings.txt, else 2,000,000.</summary>
        static string StartMoney()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_COMPANY_START");
            if (string.IsNullOrEmpty(v)) LoadSettings().TryGetValue("companystart", out v);
            return long.TryParse(v ?? "", out long n) && n >= 0 ? n.ToString() : "2000000";
        }

        string SessionPayload()
        {
            lock (sessionGate)
                return "{[\"started\"]=" + (started ? "true" : "false") + ",[\"speed\"]=" + speed +
                       (pauseAt.HasValue ? ",[\"pauseAt\"]=" + pauseAt.Value : "") +
                       ",[\"cmode\"]=\"" + companyMode + "\"" +
                       (companyMode == "separate" ? ",[\"cstart\"]=" + StartMoney() : "") + "}";
        }

        void BroadcastSession() => HostSend(Msg.Make("session", hostName ?? "hote", SessionPayload()));

        void StartSession()
        {
            List<long> times; int n;
            lock (clocks) times = clocks.Values.Select(c => c.T).Distinct().ToList();
            lock (players) n = players.Count;
            if (n < 1) { Log.Warn(T("Aucun jeu prêt.", "No game is ready.")); return; }
            if (times.Count > 1) { Log.Warn(T("Les jeux ne sont pas au même temps (", "The games are not at the same time (") + string.Join(", ", times) + T(") : chargez exactement la même sauvegarde partout.", "): load exactly the same savegame everywhere.")); return; }
            lock (sessionGate) { started = true; speed = 0; pauseAt = times.Count == 1 ? times[0] : (long?)null; }
            Log.W(F("=== Partie démarrée avec {0} jeu(x) au temps {1} : vérification initiale... ===", "=== Game started with {0} game(s) at time {1}: initial check... ===", n, times.FirstOrDefault()));
            BroadcastSession();
            // every game just loaded the same savegame: a part already different now is a local measure
            postResyncHashN = hashN + 1;
            RequestHash();
            new Thread(() => { Thread.Sleep(1500); SetSpeed(1, T("démarrage", "start")); }) { IsBackground = true }.Start();
        }

        void SetSpeed(int s, string who)
        {
            if (!started) return;
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

        void HostLoop()
        {
            double lastHash = Now, lastSession = Now;
            while (true)
            {
                Thread.Sleep(250);
                if (hostGame == null) continue;
                PlayerClock hc;
                lock (clocks) clocks.TryGetValue(hostName, out hc);

                if (Now - lastSession > 3) { lastSession = Now; BroadcastSession(); }   // late joiners and lost messages
                bool paused; lock (sessionGate) paused = pauseAt.HasValue;
                if (started && !paused && !detRunning && !resyncing && Now - lastHash > HashEverySeconds) { lastHash = Now; RequestHash(); }
            }
        }

        // ---------------------------------------------------------------- host-side message handling

        void OnHostMessage(Msg m, Peer from)
        {
            switch (m.Kind)
            {
                case "hello":
                    lock (players) players.Add(m.From);
                    Log.W(F("{0} : jeu prêt {1}", "{0}: game ready {1}", m.From, m.Payload));
                    // a game started again (resynchronisation): it needs its identity again
                    if (from != null) relay.Send(from, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(from.Name) + ",[\"role\"]=\"client\"}"));
                    lock (resyncWaiting) resyncWaiting.Remove(m.From);
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
                            var pc = Msg.Make("peerclock", hostName, "{[\"name\"]=" + LuaLit.Quote(m.From) + ",[\"t\"]=" + (long)td + ",[\"ah\"]=" + ah + "}");
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
                        // already stamped by its originator: relay it, in order, to every other game
                        lock (sendGate)
                        {
                            if (from != null) hostGame?.ToGame(m);
                            relay.Broadcast(m, from);
                        }
                        actsRelayed++;
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

                default:
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
            CheckResync(diffs.Select(d => DiffKey(d)).Where(k => !CorrectedParts.Contains(k)).ToList(), n);
            if (diffs.Count == 0)
            {
                bool changed = syncState != 1;
                syncState = 1;
                syncText = "SYNC ✔";
                if (changed || n % 6 == 1) Log.Ok(F("Synchronisation n°{0} (temps {1}) : IDENTIQUE sur {2} jeux ({3} mesures)", "Sync check #{0} (time {1}): IDENTICAL on {2} games ({3} measures)", n, time, names.Count, keys.Count));
            }
            else if (diffKeys.Where(d => !ignoredParts.Contains(d) && !CorrectedParts.Contains(d)).All(DriftParts.Contains))
            {
                // simulation drift (or money, corrected at once): no alarm, a line per minute
                bool changed = syncState != 2;
                syncState = 2;
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
                if (Now - driftSince < DriftResyncSeconds || Now - lastResync < ResyncCooldownSeconds) return;
                driftSince = -1;
                int others; lock (players) others = players.Count(p => p != hostName);
                if (others == 0) return;
                resyncing = true;
                new Thread(() => Resync(T("dérive de la simulation : ", "simulation drift: ") + k)) { IsBackground = true, Name = "Resync" }.Start();
                return;
            }
            driftSince = -1;
            diffStreak = k == lastDiffKeys ? diffStreak + 1 : 1;
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
                hostGame.ToGame(Msg.Make("resync_load", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(ResyncSaveName) + "}"));
                bool back = WaitUntil(() => { lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);
                if (!back) { lock (resyncWaiting) Log.Warn(T("Resynchronisation : sans nouvelles de ", "Resynchronisation: no news from ") + string.Join(", ", resyncWaiting) + T(" (on reprend quand même).", " (resuming anyway).")); }
                // 4. all games run the same savegame: check, then resume
                Thread.Sleep(3000);
                postResyncHashN = hashN + 1;
                RequestHash();
                Thread.Sleep(2000);
                Log.W(F("=== Resynchronisation n°{0} terminée en {1:0} s ===", "=== Resynchronisation #{0} done in {1:0} s ===", id, (DateTime.UtcNow - t0).TotalSeconds));
            }
            catch (Exception e) { Log.W("Resynchronisation : " + e.Message); }
            finally
            {
                lastResync = Now;
                diffStreak = 0;
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
                if (menuMode && !game.InGame)
                {
                    // still in the main menu: its MPFever window loads the savegame
                    menuPhase = "loading"; menuText = T("Chargement de la partie de l'hôte...", "Loading the host's game..."); menuLoad = name; menuLoadSeq = "r" + id;
                    MenuStatus();
                    return;
                }
                game.ToGame(Msg.Make("resync_load", m.From, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(name) + "}"));
            }
            catch (Exception e) { Log.Warn(F("[{0}] partie de l'hôte : {1}", "[{0}] host game: {1}", game.Name, e.Message)); }
        }

        void RunDeterminism()
        {
            if (started) { Log.W("Test déterminisme : à lancer avant « Démarrer la partie »."); return; }
            int[] schedule = { 0, 100, 500, 1500, 3000 };
            int expected;
            lock (players) expected = players.Count;
            if (expected < 2) { Log.W($"Test déterminisme : il faut au moins 2 jeux prêts (actuellement {expected})."); return; }
            detRunning = true;
            try
            {
                Log.W($"=== Test déterminisme sur {expected} jeux ===");
                int total = 0;
                for (int round = 0; round < schedule.Length; round++)
                {
                    int steps = schedule[round];
                    lock (detGate) { detRound = round; detHashes = new Dictionary<string, Dictionary<object, object>>(); }
                    HostSend(Msg.Make("det_run", hostName, "{[\"round\"]=" + round + ",[\"steps\"]=" + steps + "}"));
                    total += steps;
                    var deadline = DateTime.UtcNow.AddSeconds(300);
                    Dictionary<string, Dictionary<object, object>> got;
                    lock (detGate)
                    {
                        while (detHashes.Count < expected && DateTime.UtcNow < deadline) Monitor.Wait(detGate, 1000);
                        got = new Dictionary<string, Dictionary<object, object>>(detHashes);
                    }
                    if (got.Count < expected) { Log.W($"Tour {round} : réponses manquantes ({got.Count}/{expected}), test arrêté."); return; }
                    var names = got.Keys.OrderBy(k => k).ToList();
                    var keys = got.Values.Where(v => v != null).SelectMany(v => v.Keys.Select(k => k.ToString())).Distinct().OrderBy(k => k).ToList();
                    var diffs = new List<string>();
                    foreach (var k in keys)
                    {
                        var vals = names.Select(n => got[n] != null && got[n].TryGetValue(k, out var v) ? LuaLit.Show(v) : "absent").ToList();
                        if (vals.Distinct().Count() > 1) diffs.Add($"{k}: " + string.Join(" | ", names.Select((n, i) => n + "=" + vals[i])));
                    }
                    if (diffs.Count == 0) Log.W($"Tour {round} (+{steps} pas, total {total}) : IDENTIQUE sur {keys.Count} mesures");
                    else
                    {
                        Log.W($"Tour {round} (+{steps} pas, total {total}) : {diffs.Count} DIFFÉRENCE(S)");
                        foreach (var d in diffs) Log.W("    " + d);
                    }
                }
                Log.W("=== Fin du test déterminisme ===");
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
