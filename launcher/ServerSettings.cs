using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>(0.6.13) The game options the feature modules declare, for the server window's settings: launcher/gameopts.json,
    /// made by tools/gen_gameopts.py from mod/mpfever_1/content/mpfever_feat_*.lua (tests/test_serversettings.py checks it is up
    /// to date). Texts in French and English; the other languages through T (lang.json, keyed by the English text).</summary>
    static class GameOptsCatalog
    {
        public sealed class Value { public string V, Fr, En; }
        public sealed class Param { public string Id, Default; public string[] Label; public bool PerPlayer; public List<Value> Values = new List<Value>(); }
        public sealed class Option { public string Id, Module, Modes; public string[] Title, Desc; public List<Param> Params = new List<Param>(); }

        static List<Option> all;

        public static List<Option> All
        {
            get
            {
                if (all != null) return all;
                var list = new List<Option>();
                try
                {
                    using (var st = typeof(GameOptsCatalog).Assembly.GetManifestResourceStream("gameopts.json"))
                    using (var r = new StreamReader(st, Encoding.UTF8))
                    {
                        var root = Json.Parse(r.ReadToEnd()) as Dictionary<string, object>;
                        foreach (var o in (root?["options"] as List<object>) ?? new List<object>())
                        {
                            if (!(o is Dictionary<string, object> d)) continue;
                            var opt = new Option { Id = S(d, "id"), Module = S(d, "module"), Modes = S(d, "modes"), Title = Pair(d, "title"), Desc = Pair(d, "desc") };
                            foreach (var p in (d.TryGetValue("params", out var pv) ? pv as List<object> : null) ?? new List<object>())
                            {
                                if (!(p is Dictionary<string, object> pd)) continue;
                                var par = new Param { Id = S(pd, "id"), Default = S(pd, "default"), Label = Pair(pd, "label"), PerPlayer = pd.TryGetValue("perPlayer", out var pp) && pp is bool b && b };
                                foreach (var v in (pd.TryGetValue("values", out var vv) ? vv as List<object> : null) ?? new List<object>())
                                    if (v is Dictionary<string, object> vd) par.Values.Add(new Value { V = S(vd, "v"), Fr = S(vd, "fr"), En = S(vd, "en") });
                                if (par.Id != "" && par.Values.Count > 0) opt.Params.Add(par);
                            }
                            if (opt.Id != "") list.Add(opt);
                        }
                    }
                }
                catch (Exception e) { Log.W("gameopts.json: " + e.Message); }
                all = list;
                return all;
            }
        }

        static string S(Dictionary<string, object> d, string k) => d.TryGetValue(k, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
        static string[] Pair(Dictionary<string, object> d, string k)
        {
            if (!d.TryGetValue(k, out var v) || !(v is List<object> l) || l.Count < 2) return null;
            return new[] { Convert.ToString(l[0], CultureInfo.InvariantCulture), Convert.ToString(l[1], CultureInfo.InvariantCulture) };
        }

        /// <summary>The options a dedicated server offers in a company mode: the modes allowed, without the public games' (a server
        /// has its own list and admission, see ServerConfig).</summary>
        public static List<Option> ForServer(string companyMode) =>
            All.Where(o => o.Module != "public" && (o.Modes == "" || o.Modes == "both" || o.Modes == companyMode)).ToList();
    }

    /// <summary>(0.6.13) The dedicated server's settings, in a window instead of mpfever_server.properties opened in Notepad (the
    /// user's request, 2026-11-05): every setting of the file in sections, the savegames of this PC to pick the world from (with
    /// their picture, mods, DLCs and computer companies), the computer companies of the world and the game options. « Save »
    /// writes the file (ServerConfig.Save); the server reads it at its next start or « Restart the world ».</summary>
    sealed class ServerSettingsDialog : Form
    {
        public static readonly Color[] Palette =
        {
            Rgb(0.86, 0.20, 0.20), Rgb(0.20, 0.45, 0.90), Rgb(0.20, 0.72, 0.30), Rgb(0.98, 0.62, 0.10),
            Rgb(0.62, 0.30, 0.82), Rgb(0.10, 0.75, 0.80), Rgb(0.95, 0.88, 0.15), Rgb(0.95, 0.45, 0.70),
            Rgb(0.55, 0.35, 0.18), Rgb(0.55, 0.85, 0.15), Rgb(0.15, 0.30, 0.55), Rgb(0.62, 0.62, 0.62),
        };
        static Color Rgb(double r, double g, double b) => Color.FromArgb((int)(r * 255), (int)(g * 255), (int)(b * 255));

        /// <summary>The settings being edited (written by « Save » only).</summary>
        public readonly ServerConfig Config;
        /// <summary>« Save and restart the world » was pressed (the server runs).</summary>
        public bool RestartAsked;

        readonly string path;
        readonly bool running;
        readonly int W;   // width of a page's rows
        readonly List<ModernButton> navButtons = new List<ModernButton>();
        readonly List<Control> pages = new List<Control>();
        readonly Panel content;
        readonly List<Action> modeChanged = new List<Action>();

        public ServerSettingsDialog(string path, bool running)
        {
            this.path = path;
            this.running = running;
            var problems = new List<string>();
            try { Config = ServerConfig.Load(path, problems, out _); }
            catch (Exception e) { Config = new ServerConfig(); Log.W(ServerConfig.FileName + ": " + e.Message); }

            var S = (Func<int, int>)Theme.S;
            Text = "MPFever – " + T("Réglages du serveur", "Server settings");
            FormBorderStyle = FormBorderStyle.Sizable;
            MaximizeBox = true; MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            Font = Theme.Ui(9.75f);
            var icon = Theme.AppIcon();
            if (icon != null) Icon = icon;
            HandleCreated += (s, e) => Theme.DarkTitleBar(Handle);
            ClientSize = new Size(S(1040), S(720));
            MinimumSize = new Size(S(900), S(560));
            W = S(1040) - S(230) - S(70);

            // ---- the sections on the left
            var nav = new Panel { Dock = DockStyle.Left, Width = S(230), Padding = new Padding(S(14), S(16), S(10), S(16)), BackColor = Theme.Bg };
            var navTitle = new Label { Text = T("Réglages du serveur", "Server settings"), Dock = DockStyle.Top, Height = S(34), Font = Theme.Semibold(12f), ForeColor = Theme.Text };
            var navHelp = new Label
            {
                Text = problems.Count > 0 ? F("{0} ligne(s) du fichier ignorée(s) : valeur par défaut gardée.", "{0} line(s) of the file ignored: default value kept.", problems.Count)
                                          : T("Enregistrés dans mpfever_server.properties.", "Saved in mpfever_server.properties."),
                Dock = DockStyle.Top, Height = S(40), Font = Theme.Ui(8.5f), ForeColor = problems.Count > 0 ? Theme.Warning : Theme.Faint,
            };

            content = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg, Padding = new Padding(S(8), S(10), S(14), S(6)) };

            AddPage(T("Serveur", "Server"), BuildServerPage());
            AddPage(T("Monde", "World"), BuildWorldPage());
            AddPage(T("Entreprises", "Companies"), BuildCompaniesPage());
            AddPage(T("Entreprises de l'ordinateur", "Computer companies"), BuildAiPage());
            AddPage(T("Options de partie", "Game options"), BuildOptionsPage());
            AddPage(T("Fonctionnement", "Running"), BuildRunningPage());

            var navList = new FlowLayoutPanel { Dock = DockStyle.Top, FlowDirection = FlowDirection.TopDown, WrapContents = false, Height = navButtons.Count * S(46), BackColor = Theme.Bg };
            foreach (var b in navButtons) navList.Controls.Add(b);
            nav.Controls.Add(navList);
            nav.Controls.Add(navHelp);
            nav.Controls.Add(navTitle);

            // ---- the buttons at the bottom
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = S(60), FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(S(14), S(11), S(14), S(11)), BackColor = Theme.Bg };
            var saveBtn = Btn(ButtonKind.Primary, T("Enregistrer", "Save"));
            saveBtn.Click += (s, e) => { if (SaveFile()) { DialogResult = DialogResult.OK; Close(); } };
            var cancel = Btn(ButtonKind.Secondary, T("Annuler", "Cancel"));
            cancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
            if (running)
            {
                var restart = Btn(ButtonKind.Secondary, T("Enregistrer et redémarrer le monde", "Save and restart the world"));
                restart.Click += (s, e) =>
                {
                    if (!SaveFile()) return;
                    RestartAsked = true;
                    DialogResult = DialogResult.OK;
                    Close();
                };
                buttons.Controls.Add(saveBtn);
                buttons.Controls.Add(restart);
                buttons.Controls.Add(cancel);
            }
            else
            {
                buttons.Controls.Add(saveBtn);
                buttons.Controls.Add(cancel);
            }
            var note = new Label
            {
                Dock = DockStyle.Bottom, Height = S(24), TextAlign = ContentAlignment.MiddleCenter, Font = Theme.Ui(8.5f), ForeColor = Theme.Faint,
                Text = running ? T("Le serveur tourne : les réglages s'appliquent au prochain redémarrage du monde.", "The server runs: the settings apply when the world restarts.")
                               : T("Les réglages s'appliquent au prochain démarrage du serveur.", "The settings apply the next time the server starts."),
            };

            Controls.Add(content);
            Controls.Add(nav);
            Controls.Add(note);
            Controls.Add(buttons);
            CancelButton = cancel;
            ShowPage(0);
        }

        // ---------------------------------------------------------------- layout helpers

        static ModernButton Btn(ButtonKind kind, string text)
        {
            var b = new ModernButton(kind) { Text = text };
            b.Fit(36);
            b.Margin = new Padding(Theme.S(10), 0, 0, 0);
            return b;
        }

        void AddPage(string title, Control page)
        {
            int i = pages.Count;
            var b = new ModernButton(ButtonKind.Segment) { Text = title, Width = Theme.S(200), Height = Theme.S(40), Margin = new Padding(0, 0, 0, Theme.S(6)) };
            b.Click += (s, e) => ShowPage(i);
            navButtons.Add(b);
            page.Dock = DockStyle.Fill;
            page.Visible = false;
            pages.Add(page);
            content.Controls.Add(page);
        }

        void ShowPage(int i)
        {
            for (int k = 0; k < pages.Count; k++) { pages[k].Visible = k == i; navButtons[k].Active = k == i; }
        }

        /// <summary>A page: a column of rows that scrolls.</summary>
        FlowLayoutPanel Page(string title, string help)
        {
            var p = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, BackColor = Theme.Bg, Padding = new Padding(Theme.S(6), 0, Theme.S(6), Theme.S(10)) };
            p.HandleCreated += (s, e) => Theme.DarkScrollBars(p);
            p.Controls.Add(new Label { Text = title, AutoSize = false, Width = W, Height = Theme.S(36), Font = Theme.Semibold(14f), ForeColor = Theme.Text });
            if (!string.IsNullOrEmpty(help)) p.Controls.Add(Note(help, Theme.Muted));
            p.Controls.Add(Gap(6));
            return p;
        }

        Label Note(string text, Color color, int width = 0)
        {
            int w = width > 0 ? width : W;
            var l = new Label { Text = text, AutoSize = false, Width = w, Font = Theme.Ui(8.75f), ForeColor = color, Margin = new Padding(0, 0, 0, Theme.S(4)) };
            l.Height = TextRenderer.MeasureText(text, l.Font, new Size(w, 0), TextFormatFlags.WordBreak).Height + Theme.S(4);
            return l;
        }

        Control Gap(int px) => new Panel { Width = W, Height = Theme.S(px), Margin = Padding.Empty };

        Label Heading(string text) => new Label { Text = text.ToUpperInvariant(), AutoSize = false, Width = W, Height = Theme.S(30), Font = Theme.Semibold(8.5f), ForeColor = Theme.Accent, TextAlign = ContentAlignment.BottomLeft };

        /// <summary>A row: its label and help on the left, its input on the right.</summary>
        Control Row(string label, string help, Control input, int inputWidth = 0)
        {
            int iw = inputWidth > 0 ? inputWidth : Theme.S(340);
            int lw = W - iw - Theme.S(20);
            var row = new Panel { Width = W, Margin = new Padding(0, 0, 0, Theme.S(8)) };
            var l = new Label { Text = label, AutoSize = false, Width = lw, Height = Theme.S(24), Font = Theme.Semibold(9.75f), ForeColor = Theme.Text, Location = new Point(0, Theme.S(2)) };
            row.Controls.Add(l);
            int h = l.Height;
            if (!string.IsNullOrEmpty(help))
            {
                var hl = new Label { Text = help, AutoSize = false, Width = lw, Font = Theme.Ui(8.5f), ForeColor = Theme.Muted, Location = new Point(0, Theme.S(26)) };
                hl.Height = TextRenderer.MeasureText(help, hl.Font, new Size(lw, 0), TextFormatFlags.WordBreak).Height + Theme.S(2);
                row.Controls.Add(hl);
                h = Theme.S(26) + hl.Height;
            }
            input.Location = new Point(W - iw, 0);
            input.Width = iw;
            row.Controls.Add(input);
            row.Height = Math.Max(h, input.Height) + Theme.S(4);
            return row;
        }

        Control TextField(string value, Action<string> set, bool secret = false, string cue = null)
        {
            var tb = new TextBox { Text = value ?? "", UseSystemPasswordChar = secret };
            tb.TextChanged += (s, e) => set(tb.Text);
            if (cue != null) tb.HandleCreated += (s, e) => SetCue(tb, cue);
            return new InputBox(tb) { Height = Theme.S(36) };
        }

        Control NumberField(long value, long min, long max, long step, Action<long> set)
        {
            var n = new NumericUpDown { Minimum = min, Maximum = max, Increment = step, ThousandsSeparator = max >= 10000, Value = Math.Max(min, Math.Min(max, value)), TextAlign = HorizontalAlignment.Left };
            n.ValueChanged += (s, e) => set((long)n.Value);
            return new InputBox(n) { Height = Theme.S(36) };
        }

        CheckBox Check(bool value, Action<bool> set, string text = null)
        {
            var cb = new CheckBox { Text = text ?? T("Activé", "On"), Checked = value, AutoSize = false, Height = Theme.S(30), Font = Theme.Ui(9.75f), ForeColor = Theme.Text };
            cb.CheckedChanged += (s, e) => set(cb.Checked);
            return cb;
        }

        /// <summary>Segment buttons, one per value, the current one lit.</summary>
        Control Choice(IList<KeyValuePair<string, string>> options, string current, Action<string> set)
        {
            var p = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Height = Theme.S(40), BackColor = Theme.Bg, Margin = Padding.Empty };
            var bs = new List<ModernButton>();
            foreach (var o in options)
            {
                var b = new ModernButton(ButtonKind.Segment) { Text = o.Value, Active = o.Key == current, Margin = new Padding(0, 0, Theme.S(6), Theme.S(4)) };
                b.Fit(24);
                var key = o.Key;
                b.Click += (s, e) => { foreach (var x in bs) x.Active = x == b; set(key); };
                bs.Add(b);
                p.Controls.Add(b);
            }
            p.Layout += (s, e) =>
            {
                // (as many lines as the buttons take)
                int rows = 1, x = 0;
                foreach (var b in bs) { if (x > 0 && x + b.Width > p.Width) { rows++; x = 0; } x += b.Width + Theme.S(6); }
                int h = rows * (Theme.S(38) + Theme.S(4));
                if (p.Height != h) p.Height = h;
            };
            return p;
        }

        static KeyValuePair<string, string> KV(string k, string v) => new KeyValuePair<string, string>(k, v);

        /// <summary>A value among several: a button with the current one, its menu (the launcher's dark menus) lists them all.</summary>
        sealed class Picker : ModernButton
        {
            readonly List<KeyValuePair<string, string>> items;
            readonly Action<string> set;
            public string Key { get; private set; }

            public Picker(IEnumerable<KeyValuePair<string, string>> items, string current, Action<string> set) : base(ButtonKind.Secondary)
            {
                this.items = items.ToList();
                this.set = set;
                Height = Theme.S(36);
                Pick(this.items.Any(x => x.Key == current) ? current : (this.items.Count > 0 ? this.items[0].Key : ""), false);
                Click += (s, e) =>
                {
                    var menu = new ContextMenuStrip { Renderer = new DarkMenuRenderer(), ShowImageMargin = false, ShowCheckMargin = true, Font = Theme.Ui(9.75f) };
                    foreach (var it in this.items)
                    {
                        var key = it.Key;
                        var mi = new ToolStripMenuItem(it.Value) { Checked = key == Key, ForeColor = Theme.Text };
                        mi.Click += (s2, e2) => Pick(key, true);
                        menu.Items.Add(mi);
                    }
                    menu.Closed += (s2, e2) => BeginInvoke((Action)menu.Dispose);
                    menu.Show(this, new Point(0, Height));
                };
            }

            /// <summary>Shows that value (no change told).</summary>
            public void Set(string key) { if (items.Any(x => x.Key == key)) Pick(key, false); }

            void Pick(string key, bool tell)
            {
                Key = key;
                Text = (items.FirstOrDefault(x => x.Key == key).Value ?? "") + "   \u25BE";
                if (tell) set(key);
            }
        }

        static Picker Combo(IEnumerable<KeyValuePair<string, string>> items, string current, Action<string> set) => new Picker(items, current, set);

        static string Money(long n)
        {
            if (n >= 1000000 && n % 100000 == 0) return (n / 1000000.0).ToString("0.#", CultureInfo.CurrentCulture) + " M";
            if (n >= 1000 && n % 1000 == 0) return (n / 1000).ToString(CultureInfo.CurrentCulture) + " k";
            return n.ToString("N0", CultureInfo.CurrentCulture);
        }

        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
        static void SetCue(TextBox box, string text) { try { SendMessage(box.Handle, 0x1501, (IntPtr)1, text); } catch { } }

        /// <summary>A block on or off (a setting of the other company mode): its inputs disabled, its texts faded (a disabled label
        /// is drawn in the system's grey, unreadable on the dark theme). Each label's own colour is kept in its Tag.</summary>
        static void Shade(Control c, bool on)
        {
            foreach (Control x in c.Controls)
            {
                if (x is Label l)
                {
                    if (!(l.Tag is Color)) l.Tag = l.ForeColor;
                    l.ForeColor = on ? (Color)l.Tag : Theme.Faint;
                }
                else if (x is Panel && !(x is InputBox)) Shade(x, on);
                else x.Enabled = on;
            }
        }

        // ---------------------------------------------------------------- the pages

        Control BuildServerPage()
        {
            var p = Page(T("Serveur", "Server"), T("Ce que les joueurs voient du serveur, et comment ils le rejoignent.", "What the players see of the server, and how they join it."));
            var c = Config;
            p.Controls.Add(Row(T("Nom du serveur", "Server name"), T("Affiché aux joueurs (fenêtre MPFever, discussion) et dans la liste publique.", "Shown to the players (MPFever window, chat) and in the public list."),
                TextField(c.Name, v => c.Name = v)));
            p.Controls.Add(Row(T("Message de bienvenue", "Welcome message"), T("Envoyé dans la discussion de chaque joueur qui arrive (vide : aucun).", "Sent in the chat of every player who arrives (empty: none)."),
                TextField(c.Motd, v => c.Motd = v)));
            var pwBox = TextField(c.Password, v => c.Password = v, true, T("aucun", "none"));
            p.Controls.Add(Row(T("Mot de passe", "Password"), T("Les joueurs le tapent dans la fenêtre MPFever pour rejoindre (vide : pas de mot de passe).", "The players type it in the MPFever window to join (empty: no password)."), pwBox));
            var show = Check(false, on => { if (pwBox is InputBox ib && ib.Inner is TextBox tb) tb.UseSystemPasswordChar = !on; }, T("Afficher le mot de passe", "Show the password"));
            p.Controls.Add(Row("", "", show));
            p.Controls.Add(Row(T("Joueurs au maximum", "Players at most"), T("Le serveur lui-même n'est pas compté.", "The server itself is not counted."),
                NumberField(c.MaxPlayers, 1, 64, 1, v => c.MaxPlayers = (int)v), Theme.S(140)));
            p.Controls.Add(Heading(T("Réseau", "Network")));
            p.Controls.Add(Row(T("Port TCP", "TCP port"), T("Le port que les joueurs rejoignent : à rediriger vers ce PC sur la box pour jouer par Internet.", "The port the players join: forward it to this PC on the router to play over the Internet."),
                NumberField(c.Port, 1024, 65535, 1, v => c.Port = (int)v), Theme.S(140)));
            p.Controls.Add(Row(T("Serveur public", "Public server"), T("Montré dans la liste publique des serveurs de la page Multijoueur, tant que son monde tourne.", "Shown in the public server list of the Multiplayer page, while its world runs."),
                Check(c.Public, v => c.Public = v)));
            p.Controls.Add(Row(T("Adresse publique", "Public address"), T("L'adresse que la liste montre (un nom de domaine, nom:port). Vide : l'adresse IP publique que la liste voit.", "The address the list shows (a domain name, name:port). Empty: the public IP address the list sees."),
                TextField(c.PublicAddress, v => c.PublicAddress = v, false, T("automatique", "automatic"))));
            return p;
        }

        // ---- the world: the savegames of this PC

        sealed class SaveItem
        {
            public string Name, File;
            public DateTime When;
            public long Size;
            public override string ToString() => Name;
        }

        sealed class SaveDetails
        {
            public List<SaveInfo.SaveMod> Mods;
            public SaveInfo.Marks Marks;
            public bool Done;
        }

        readonly Dictionary<string, SaveDetails> details = new Dictionary<string, SaveDetails>(StringComparer.OrdinalIgnoreCase);
        Label worldNow, detTitle, detInfo;
        PictureBox detPic;
        ListBox saveList;
        ModernButton useBtn;
        CheckBox showAuto;
        SaveItem shown;
        Action aiFromSave;

        Control BuildWorldPage()
        {
            var S = (Func<int, int>)Theme.S;
            var root = new Panel { BackColor = Theme.Bg };
            var head = Page(T("Monde", "World"), T("La sauvegarde que le serveur héberge : il la charge, la sauvegarde sous ce nom et la recharge après un redémarrage.",
                "The savegame the server hosts: it loads it, saves it under this name and loads it again after a restart."));
            head.AutoScroll = false;
            head.Dock = DockStyle.Top;
            worldNow = new Label { AutoSize = false, Width = W, Height = S(30), Font = Theme.Semibold(11f), ForeColor = Theme.Text };
            head.Controls.Add(worldNow);
            head.Height = head.Controls.Cast<Control>().Sum(x => x.Height + x.Margin.Vertical) + S(4);

            var bar = new Panel { Dock = DockStyle.Top, Height = S(42), BackColor = Theme.Bg };
            showAuto = new CheckBox { Text = T("Afficher les sauvegardes automatiques", "Show the autosaves"), AutoSize = false, Width = S(360), Height = S(30), Location = new Point(S(6), S(4)), ForeColor = Theme.Text, Font = Theme.Ui(9.25f) };
            var refresh = new ModernButton(ButtonKind.Secondary) { Text = T("Actualiser", "Refresh") };
            refresh.Fit();
            refresh.Location = new Point(S(380), 0);
            bar.Controls.Add(showAuto);
            bar.Controls.Add(refresh);

            var split = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg, Padding = new Padding(S(6), 0, 0, 0) };
            saveList = new ListBox
            {
                Dock = DockStyle.Left, Width = S(380), DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = S(48), BorderStyle = BorderStyle.None,
                BackColor = Theme.Surface, ForeColor = Theme.Text, IntegralHeight = false,
            };
            saveList.HandleCreated += (s, e) => Theme.DarkScrollBars(saveList);
            saveList.DrawItem += DrawSave;
            var detail = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg, Padding = new Padding(S(16), 0, 0, 0) };
            detPic = new PictureBox { Dock = DockStyle.Top, Height = S(220), SizeMode = PictureBoxSizeMode.Zoom, BackColor = Theme.Surface };
            detPic.Paint += (s, e) =>
            {
                if (detPic.Image != null) return;
                TextRenderer.DrawText(e.Graphics, T("Pas d'image pour cette sauvegarde", "No picture for this savegame"), Font, detPic.ClientRectangle, Theme.Faint,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            };
            detTitle = new Label { Dock = DockStyle.Top, Height = S(34), Font = Theme.Semibold(12f), ForeColor = Theme.Text, TextAlign = ContentAlignment.BottomLeft };
            detInfo = new Label { Dock = DockStyle.Top, Height = S(170), Font = Theme.Ui(9.25f), ForeColor = Theme.Muted };
            useBtn = new ModernButton(ButtonKind.Primary) { Text = T("Héberger ce monde", "Host this world"), Dock = DockStyle.Top };
            useBtn.Click += (s, e) => { if (shown != null) { Config.World = shown.Name; UpdateWorldNow(); saveList.Invalidate(); } };
            Ui.StackTop(detail, detPic, detTitle, detInfo, useBtn);
            split.Controls.Add(detail);
            split.Controls.Add(saveList);

            root.Controls.Add(split);
            root.Controls.Add(bar);
            root.Controls.Add(head);

            saveList.SelectedIndexChanged += (s, e) => ShowSave(saveList.SelectedItem as SaveItem);
            showAuto.CheckedChanged += (s, e) => FillSaves();
            refresh.Click += (s, e) => { lock (details) details.Clear(); FillSaves(); };
            HandleCreated += (s, e) => FillSaves();
            UpdateWorldNow();
            return root;
        }

        void UpdateWorldNow()
        {
            bool found = Config.World != "" && GameInstall.FindSave(Config.World) != null;
            worldNow.Text = Config.World == "" ? T("Aucun monde choisi : choisissez une sauvegarde ci-dessous.", "No world chosen: pick a savegame below.")
                : F("Monde hébergé : {0}", "Hosted world: {0}", Config.World) + (found ? "" : T("  (introuvable sur ce PC)", "  (not found on this PC)"));
            worldNow.ForeColor = Config.World != "" && found ? Theme.Success : Theme.Warning;
        }

        static bool Hidden(string name) =>
            name.StartsWith("MPFever resync", StringComparison.Ordinal) || name.StartsWith("crash_", StringComparison.Ordinal)
            || name.StartsWith("recplay", StringComparison.Ordinal) || name == "bridgeprobe";

        void FillSaves()
        {
            var list = new List<SaveItem>();
            try
            {
                foreach (var d in GameInstall.SaveDirs())
                    foreach (var f in Directory.GetFiles(d, "*.sav"))
                    {
                        var n = Path.GetFileNameWithoutExtension(f);
                        if (Hidden(n) || (!showAuto.Checked && n.StartsWith("autosave_", StringComparison.Ordinal))) continue;
                        if (list.Any(x => string.Equals(x.Name, n, StringComparison.OrdinalIgnoreCase))) continue;
                        var fi = new FileInfo(f);
                        list.Add(new SaveItem { Name = n, File = f, When = fi.LastWriteTime, Size = fi.Length });
                    }
            }
            catch (Exception e) { Log.W("savegames: " + e.Message); }
            list = list.OrderByDescending(x => x.When).ToList();
            saveList.BeginUpdate();
            saveList.Items.Clear();
            foreach (var x in list) saveList.Items.Add(x);
            saveList.EndUpdate();
            int sel = list.FindIndex(x => string.Equals(x.Name, Config.World, StringComparison.OrdinalIgnoreCase));
            if (sel >= 0) saveList.SelectedIndex = sel;
            else if (list.Count > 0) saveList.SelectedIndex = 0;
            else ShowSave(null);
        }

        void DrawSave(object sender, DrawItemEventArgs e)
        {
            var g = e.Graphics;
            if (e.Index < 0) { using (var bg = new SolidBrush(Theme.Surface)) g.FillRectangle(bg, e.Bounds); return; }
            var it = (SaveItem)saveList.Items[e.Index];
            bool sel = (e.State & DrawItemState.Selected) != 0;
            bool world = string.Equals(it.Name, Config.World, StringComparison.OrdinalIgnoreCase);
            using (var b = new SolidBrush(sel ? Theme.Mix(Theme.Surface, Theme.Accent, 0.22f) : (e.Index % 2 == 0 ? Theme.Surface : Theme.Mix(Theme.Surface, Theme.Raised, 0.5f))))
                g.FillRectangle(b, e.Bounds);
            if (world) using (var b = new SolidBrush(Theme.Success)) g.FillRectangle(b, e.Bounds.X, e.Bounds.Y + Theme.S(6), Theme.S(4), e.Bounds.Height - Theme.S(12));
            var x = e.Bounds.X + Theme.S(14);
            var flags = TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            using (var f1 = Theme.Semibold(10f))
                TextRenderer.DrawText(g, it.Name, f1, new Rectangle(x, e.Bounds.Y + Theme.S(6), e.Bounds.Width - x - Theme.S(8), Theme.S(20)), sel ? Theme.AccentHover : Theme.Text, flags);
            using (var f2 = Theme.Ui(8.5f))
                TextRenderer.DrawText(g, it.When.ToString("g", CultureInfo.CurrentCulture) + "  ·  " + (it.Size / 1048576.0).ToString("0", CultureInfo.CurrentCulture) + " " + T("Mo", "MB")
                    + (world ? "  ·  " + T("monde hébergé", "hosted world") : ""), f2,
                    new Rectangle(x, e.Bounds.Y + Theme.S(27), e.Bounds.Width - x - Theme.S(8), Theme.S(16)), world ? Theme.Success : Theme.Muted, flags);
        }

        void ShowSave(SaveItem it)
        {
            shown = it;
            useBtn.Enabled = it != null;
            var old = detPic.Image;
            detPic.Image = null;
            old?.Dispose();
            if (it == null) { detTitle.Text = T("Aucune sauvegarde", "No savegame"); detInfo.Text = T("Aucune sauvegarde trouvée sur ce PC : jouez une partie et sauvegardez-la.", "No savegame found on this PC: play a game and save it."); return; }
            detTitle.Text = it.Name;
            try
            {
                var jpg = Path.ChangeExtension(it.File, ".jpg");
                if (File.Exists(jpg)) using (var ms = new MemoryStream(File.ReadAllBytes(jpg))) detPic.Image = new Bitmap(Image.FromStream(ms));
            }
            catch { }
            SaveDetails d;
            lock (details) details.TryGetValue(it.File, out d);
            if (d == null)
            {
                d = new SaveDetails();
                lock (details) details[it.File] = d;
                var file = it.File;
                new Thread(() =>
                {
                    // (the mods from the file's start, at once; the companies need the whole file: a big savegame takes seconds)
                    var mods = SaveInfo.Mods(file);
                    lock (details) d.Mods = mods;
                    try { BeginInvoke((Action)(() => { if (shown?.File == file) ShowDetails(); })); } catch { }
                    var marks = SaveInfo.Read(file, true);
                    lock (details) { d.Marks = marks; d.Done = true; }
                    try { BeginInvoke((Action)(() => { if (shown?.File == file) ShowDetails(); })); } catch { }
                }) { IsBackground = true, Name = "Savegame details" }.Start();
            }
            ShowDetails();
        }

        void ShowDetails()
        {
            var it = shown;
            if (it == null) return;
            SaveDetails d;
            lock (details) details.TryGetValue(it.File, out d);
            var lines = new List<string> { it.When.ToString("f", CultureInfo.CurrentCulture) + "  ·  " + (it.Size / 1048576.0).ToString("0", CultureInfo.CurrentCulture) + " " + T("Mo", "MB") };
            List<SaveInfo.SaveMod> mods; SaveInfo.Marks marks; bool done;
            lock (details) { mods = d?.Mods; marks = d?.Marks; done = d?.Done ?? false; }
            if (mods == null) lines.Add(done ? T("Mods : illisibles", "Mods: unreadable") : T("Lecture de la sauvegarde...", "Reading the savegame..."));
            else
            {
                var dl = mods.Where(m => m.Source.Equals("DLC", StringComparison.OrdinalIgnoreCase)).Select(m => Mods.DlcName(m.Id)).ToList();
                var other = mods.Where(m => !m.Source.Equals("DLC", StringComparison.OrdinalIgnoreCase) && m.Id != "mpfever_1").Select(m => m.Name).ToList();
                lines.Add(T("DLC : ", "DLCs: ") + (dl.Count == 0 ? T("aucun", "none") : string.Join(", ", dl)));
                lines.Add(F("Mods ({0}) : ", "Mods ({0}): ", other.Count) + (other.Count == 0 ? T("aucun", "none") : string.Join(", ", other.Take(12)) + (other.Count > 12 ? "…" : "")));
                if (dl.Count > 0) lines.Add(T("Les joueurs sans ces DLC peuvent désynchroniser la partie : désactivez-les dans les mods de la sauvegarde pour l'éviter.", "Players without these DLCs may desynchronise the game: switch them off in the savegame's mods to avoid it."));
            }
            if (marks != null)
            {
                lines.Add(marks.Separate ? T("Jouée avec une entreprise par joueur", "Played with one company per player") : T("Jouée avec une entreprise pour tous (ou en solo)", "Played with one company for everybody (or alone)"));
                if (marks.Ai != null && marks.Ai.Count > 0)
                    lines.Add(F("{0} entreprise(s) de l'ordinateur : ", "{0} computer company(ies): ", marks.Ai.Count) + string.Join(", ", marks.Ai.Select(a => a.Name != "" ? a.Name : F("Ordinateur {0}", "Computer {0}", a.Number))));
            }
            else if (!done && mods != null) lines.Add(T("Lecture des entreprises...", "Reading the companies..."));
            detInfo.Text = string.Join("\n", lines);
            useBtn.Text = string.Equals(it.Name, Config.World, StringComparison.OrdinalIgnoreCase) ? T("✓ Monde hébergé", "✓ Hosted world") : T("Héberger ce monde", "Host this world");
            aiFromSave?.Invoke();
        }

        /// <summary>The computer companies of the chosen world's savegame, when read (null else).</summary>
        List<SaveInfo.Company> WorldAi()
        {
            var f = Config.World == "" ? null : GameInstall.FindSave(Config.World);
            if (f == null) return null;
            lock (details) return details.TryGetValue(f, out var d) && d.Marks != null ? d.Marks.Ai : null;
        }

        // ---- companies

        Control BuildCompaniesPage()
        {
            var p = Page(T("Entreprises", "Companies"), T("Une entreprise pour tout le monde, ou une par joueur avec ses règles.", "One company for everybody, or one per player with its rules."));
            var c = Config;
            var separateOnly = new List<Control>();
            p.Controls.Add(Row(T("Mode des entreprises", "Company mode"), T("Une pour tous : tout le monde construit avec le même argent. Une par joueur : chacun son argent, son réseau et sa couleur.", "One for everybody: everybody builds with the same money. One per player: everyone has their own money, network and colour."),
                Choice(new[] { KV("shared", T("Une pour tous", "One for everybody")), KV("separate", T("Une par joueur", "One per player")) }, c.CompanyMode, v =>
                {
                    c.CompanyMode = v;
                    foreach (var a in modeChanged) a();
                })));
            p.Controls.Add(Heading(T("Une entreprise par joueur", "One company per player")));
            var rows = new List<Control>
            {
                Row(T("Propriétaire de la sauvegarde", "The savegame's owner"), T("Le joueur qui reprend l'entreprise de la sauvegarde (son pseudo). Vide : personne ne la joue.", "The player who gets the savegame's company (their name). Empty: nobody plays it."),
                    TextField(c.Owner, v => c.Owner = v, false, T("personne", "nobody"))),
                Row(T("Argent de départ", "Start money"), T("Celui de chaque nouvelle entreprise : un joueur qui arrive, une entreprise repartie après une faillite.", "That of every new company: a player who arrives, a company started again after a bankruptcy."),
                    NumberField(c.StartMoney, 0, 10000000000L, 500000, v => c.StartMoney = v), Theme.S(200)),
                Row(T("Règles de partage", "Sharing rules"), T("Activées : chaque entreprise décide si ses voies, gares, arrêts et dépôts sont privés, ouverts ou payants. Désactivées : tout est ouvert et gratuit.",
                    "On: each company decides whether its tracks, stations, stops and depots are private, open or paying. Off: everything is open and free."), Check(c.ShareRules, v => c.ShareRules = v)),
                Row(T("Faillite", "Bankruptcy"), T("Les mois d'endettement avant la faillite d'une entreprise (ses biens vendus aux autres, ses joueurs repartent avec une nouvelle).", "The months in debt before a company goes bankrupt (its assets sold to the others, its players start again with a new one)."),
                    Choice(new[] { KV("0", T("Jamais", "Never")), KV("3", "3"), KV("6", "6"), KV("12", "12"), KV("24", "24") }.Select(kv => kv.Key == "0" ? kv : KV(kv.Key, F("{0} mois", "{0} months", kv.Value))).ToList(),
                        c.BankruptMonths.ToString(CultureInfo.InvariantCulture), v => c.BankruptMonths = int.Parse(v, CultureInfo.InvariantCulture)), Theme.S(470)),
            };
            foreach (var r in rows) { p.Controls.Add(r); separateOnly.Add(r); }
            var off = Note(T("Ces règles ne servent qu'avec une entreprise par joueur.", "These rules only apply with one company per player."), Theme.Faint);
            p.Controls.Add(off);
            Action upd = () => { foreach (var r in separateOnly) Shade(r, c.CompanyMode == "separate"); off.Visible = c.CompanyMode != "separate"; };
            modeChanged.Add(upd);
            upd();
            return p;
        }

        // ---- computer companies

        sealed class Ai { public int N, Color, Level = 2; public long Money = -1; }
        readonly List<Ai> ais = new List<Ai>();
        FlowLayoutPanel aiPage;
        readonly List<Control> aiRows = new List<Control>();
        ModernButton aiAdd, aiTake;
        Label aiOff;

        void ReadAis()
        {
            ais.Clear();
            foreach (var part in (Config.AiCompanies ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var f = part.Split(':');
                if (f.Length < 3) continue;
                var a = new Ai { N = int.Parse(f[0], CultureInfo.InvariantCulture), Color = int.Parse(f[1], CultureInfo.InvariantCulture), Level = int.Parse(f[2], CultureInfo.InvariantCulture) };
                if (f.Length > 3) a.Money = long.Parse(f[3], CultureInfo.InvariantCulture);
                ais.Add(a);
            }
        }

        void WriteAis()
        {
            Config.AiCompanies = ServerConfig.AiCanon(string.Join(",", ais.Select(a => a.N + ":" + a.Color + ":" + a.Level + (a.Money >= 0 ? ":" + a.Money : "")))) ?? "";
        }

        int FreeColor(Ai except)
        {
            // (from the end of the palette, as the lobby: the players' first picks are its first colours)
            for (int i = 12; i >= 1; i--) if (!ais.Any(a => a != except && a.Color == i)) return i;
            return 0;
        }

        Control BuildAiPage()
        {
            aiPage = Page(T("Entreprises de l'ordinateur", "Computer companies"), T("Gérées par le jeu du serveur (expérimental) : bus, camions de marchandises et livraisons des villes. Plus le niveau est élevé, plus elles grandissent vite.",
                "Run by the server's game (experimental): buses, freight trucks and deliveries to the towns. The higher the level, the faster they grow."));
            ReadAis();
            aiOff = Note(T("Les entreprises de l'ordinateur ne jouent qu'avec une entreprise par joueur (page « Entreprises »).", "Computer companies only play with one company per player (« Companies » page)."), Theme.Warning);
            aiPage.Controls.Add(aiOff);
            var bar = new FlowLayoutPanel { Width = W, Height = Theme.S(46), FlowDirection = FlowDirection.LeftToRight, WrapContents = false, BackColor = Theme.Bg };
            aiAdd = new ModernButton(ButtonKind.Primary) { Text = "+  " + T("Ajouter une entreprise de l'ordinateur", "Add a computer company") };
            aiAdd.Fit();
            aiAdd.Margin = new Padding(0, 0, Theme.S(10), 0);
            aiAdd.Click += (s, e) =>
            {
                if (ais.Count >= 8) return;
                int n = 1;
                while (ais.Any(a => a.N == n)) n++;
                int col = FreeColor(null);
                if (col == 0) return;
                ais.Add(new Ai { N = n, Color = col });
                ais.Sort((a, b) => a.N.CompareTo(b.N));
                WriteAis();
                RebuildAi();
            };
            aiTake = new ModernButton(ButtonKind.Secondary) { Text = T("Reprendre celles de la sauvegarde", "Take the savegame's ones") };
            aiTake.Fit();
            aiTake.Click += (s, e) =>
            {
                var w = WorldAi();
                if (w == null || w.Count == 0) return;
                foreach (var c in w)
                {
                    if (ais.Any(a => a.N == c.Number) || ais.Count >= 8) continue;
                    var a = new Ai { N = c.Number, Color = c.Color >= 1 && c.Color <= 12 && !ais.Any(x => x.Color == c.Color) ? c.Color : 0 };
                    if (a.Color == 0) a.Color = FreeColor(a);
                    if (a.Color == 0) continue;
                    ais.Add(a);
                }
                ais.Sort((a, b) => a.N.CompareTo(b.N));
                WriteAis();
                RebuildAi();
            };
            bar.Controls.Add(aiAdd);
            bar.Controls.Add(aiTake);
            aiPage.Controls.Add(bar);
            bool named = false;
            aiFromSave = () =>
            {
                var w = WorldAi();
                aiTake.Visible = w != null && w.Count > 0;
                // (the savegame's names of its computer companies, once read)
                if (w != null && !named && ais.Count > 0) { named = true; RebuildAi(); }
            };
            modeChanged.Add(UpdateAiMode);
            RebuildAi();
            return aiPage;
        }

        void UpdateAiMode()
        {
            bool sep = Config.CompanyMode == "separate";
            aiOff.Visible = !sep;
            aiAdd.Enabled = sep && ais.Count < 8;
            aiTake.Enabled = sep;
            foreach (var r in aiRows) Shade(r, sep);
        }

        void RebuildAi()
        {
            aiPage.SuspendLayout();
            foreach (var r in aiRows) { aiPage.Controls.Remove(r); r.Dispose(); }
            aiRows.Clear();
            if (ais.Count == 0) aiRows.Add(Note(T("Aucune entreprise de l'ordinateur : le monde n'a que ses joueurs.", "No computer company: the world has only its players."), Theme.Muted));
            var worldAi = WorldAi();
            foreach (var a in ais)
            {
                var ai = a;
                var card = new Card { Width = W, Height = Theme.S(206), Margin = new Padding(0, 0, 0, Theme.S(10)), Padding = new Padding(Theme.S(14), Theme.S(10), Theme.S(14), Theme.S(10)) };
                var name = worldAi?.FirstOrDefault(c => c.Number == a.N)?.Name;
                int lx = Theme.S(16), vx = Theme.S(170);
                var swatch = new Panel { Location = new Point(lx, Theme.S(15)), Size = new Size(Theme.S(22), Theme.S(22)), BackColor = Palette[a.Color - 1] };
                var title = new Label { Text = !string.IsNullOrEmpty(name) ? name : F("Ordinateur {0}", "Computer {0}", a.N), Location = new Point(Theme.S(48), Theme.S(12)), AutoSize = false, Width = W - Theme.S(200), Height = Theme.S(28), Font = Theme.Semibold(11f), ForeColor = Theme.Text, BackColor = Theme.Surface };
                var del = new ModernButton(ButtonKind.Ghost) { Text = T("Retirer", "Remove") };
                del.Fit();
                del.Location = new Point(W - del.Width - Theme.S(18), Theme.S(10));
                del.Click += (s, e) => { ais.Remove(ai); WriteAis(); RebuildAi(); };
                Label Lab(string t, int y) => new Label { Text = t, Location = new Point(lx, y), Width = vx - lx - Theme.S(8), Height = Theme.S(24), ForeColor = Theme.Muted, BackColor = Theme.Surface };
                var lvLabel = Lab(T("Niveau", "Level"), Theme.S(58));
                var levels = new FlowLayoutPanel { Location = new Point(vx, Theme.S(50)), Size = new Size(W - vx - Theme.S(30), Theme.S(40)), BackColor = Theme.Surface, WrapContents = false };
                var lvButtons = new List<ModernButton>();
                string[] names = { T("Facile", "Easy"), T("Normal", "Normal"), T("Difficile", "Hard") };
                for (int lv = 1; lv <= 3; lv++)
                {
                    int pick = lv;
                    var b = new ModernButton(ButtonKind.Segment) { Text = names[lv - 1], Active = a.Level == lv, Margin = new Padding(0, 0, Theme.S(6), 0) };
                    b.Fit(26);
                    b.Click += (s, e) => { ai.Level = pick; foreach (var x in lvButtons) x.Active = x == b; WriteAis(); };
                    lvButtons.Add(b);
                    levels.Controls.Add(b);
                }
                var colLabel = Lab(T("Couleur", "Colour"), Theme.S(104));
                var colours = new FlowLayoutPanel { Location = new Point(vx, Theme.S(98)), Size = new Size(W - vx - Theme.S(30), Theme.S(36)), BackColor = Theme.Surface, WrapContents = false };
                for (int ix = 1; ix <= 12; ix++)
                {
                    int pick = ix;
                    bool taken = ais.Any(o => o != ai && o.Color == ix);
                    var sw = new SwatchButton(Palette[ix - 1]) { Selected = a.Color == ix, Taken = taken, Margin = new Padding(0, 0, Theme.S(6), 0) };
                    sw.Click += (s, e) =>
                    {
                        if (ais.Any(o => o != ai && o.Color == pick)) return;
                        ai.Color = pick; WriteAis(); RebuildAi();
                    };
                    colours.Controls.Add(sw);
                }
                var moLabel = Lab(T("Argent de départ", "Start money"), Theme.S(152));
                var moneys = new long[] { -1, 500000, 1000000, 2000000, 5000000, 10000000, 20000000 };
                var mo = Combo(moneys.Select(m => KV(m.ToString(CultureInfo.InvariantCulture), m < 0 ? T("Comme les joueurs", "As the players") : Money(m))), a.Money.ToString(CultureInfo.InvariantCulture), v => { ai.Money = long.Parse(v, CultureInfo.InvariantCulture); WriteAis(); });
                mo.Location = new Point(vx, Theme.S(146));
                mo.Width = Theme.S(260);
                card.Controls.AddRange(new Control[] { swatch, title, del, lvLabel, levels, moLabel, mo, colLabel, colours });
                aiRows.Add(card);
            }
            if (ais.Count > 0)
                aiRows.Add(Note(T("Les couleurs prises par les joueurs dans la partie restent les leurs : choisissez-en d'autres pour l'ordinateur.", "The colours the players take in the game stay theirs: pick others for the computer."), Theme.Faint));
            foreach (var r in aiRows) aiPage.Controls.Add(r);
            aiPage.ResumeLayout();
            UpdateAiMode();
        }

        /// <summary>A colour of the palette, a ring when it is the one chosen, faded when another company has it.</summary>
        sealed class SwatchButton : Control
        {
            readonly Color color;
            public bool Selected, Taken;
            public SwatchButton(Color c)
            {
                color = c;
                Size = new Size(Theme.S(30), Theme.S(30));
                Cursor = Cursors.Hand;
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.Clear(Parent?.BackColor ?? Theme.Surface);
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                int pad = Theme.S(4);
                using (var b = new SolidBrush(Taken ? Theme.Mix(Theme.Surface, color, 0.25f) : color))
                    g.FillEllipse(b, pad, pad, Width - 2 * pad - 1, Height - 2 * pad - 1);
                if (Selected) using (var pen = new Pen(Theme.Text, 2f * Theme.Scale)) g.DrawEllipse(pen, 1, 1, Width - 3, Height - 3);
            }
        }

        // ---- game options

        FlowLayoutPanel optsPage;
        readonly List<Control> optRows = new List<Control>();

        Control BuildOptionsPage()
        {
            optsPage = Page(T("Options de partie", "Game options"), T("Les options de la partie (0.6), toutes désactivées par défaut. Elles sont gardées dans la sauvegarde du monde.",
                "The game's options (0.6), all off by default. They are kept in the world's savegame."));
            modeChanged.Add(RebuildOptions);
            RebuildOptions();
            return optsPage;
        }

        void RebuildOptions()
        {
            optsPage.SuspendLayout();
            foreach (var r in optRows) { optsPage.Controls.Remove(r); r.Dispose(); }
            optRows.Clear();
            var opts = GameOptsCatalog.ForServer(Config.CompanyMode);
            // (an option of the other mode, on in the file: kept in the file, shown here as such)
            var map = GameOpts.Parse(GameOpts.Canon(Config.GameOptions ?? ""));
            if (opts.Count == 0) optRows.Add(Note(T("Aucune option de partie dans ce mode.", "No game option in this mode."), Theme.Muted));
            string module = null;
            foreach (var o in opts)
            {
                if (o.Module != module)
                {
                    module = o.Module;
                    optRows.Add(Heading(ModuleName(module)));
                }
                var opt = o;
                bool on = map.TryGetValue(o.Id, out var ov) && ov == "1";
                var card = new Card { Width = W, Margin = new Padding(0, 0, 0, Theme.S(8)), Padding = new Padding(Theme.S(14), Theme.S(8), Theme.S(14), Theme.S(8)) };
                var cb = new CheckBox { Text = Tx(o.Title, o.Id), Checked = on, AutoSize = false, Width = W - Theme.S(40), Height = Theme.S(28), Font = Theme.Semibold(10f), ForeColor = Theme.Text, BackColor = Theme.Surface, Location = new Point(Theme.S(12), Theme.S(8)) };
                card.Controls.Add(cb);
                int y = Theme.S(38);
                if (o.Desc != null)
                {
                    var d = Tx(o.Desc, "");
                    var dl = new Label { Text = d, AutoSize = false, Width = W - Theme.S(60), Location = new Point(Theme.S(34), y), Font = Theme.Ui(8.5f), ForeColor = Theme.Muted, BackColor = Theme.Surface };
                    dl.Height = TextRenderer.MeasureText(d, dl.Font, new Size(dl.Width, 0), TextFormatFlags.WordBreak).Height + Theme.S(2);
                    card.Controls.Add(dl);
                    y += dl.Height + Theme.S(4);
                }
                var paramBoxes = new List<Control>();
                foreach (var p in o.Params)
                {
                    var par = p;
                    var cur = map.TryGetValue(o.Id + "." + p.Id, out var pv) ? pv : p.Default;
                    var pl = new Label { Text = Tx(p.Label, p.Id), AutoSize = false, Width = Theme.S(300), Height = Theme.S(24), Location = new Point(Theme.S(34), y + Theme.S(7)), ForeColor = Theme.Text, BackColor = Theme.Surface };
                    var combo = Combo(p.Values.Select(v => KV(v.V, T(v.Fr, v.En))), cur, v =>
                    {
                        var s2 = GameOpts.Apply(Config.GameOptions ?? "", opt.Id + "." + par.Id + "=" + v, out _);
                        if (s2 != null) Config.GameOptions = s2;
                    });
                    combo.Location = new Point(Theme.S(340), y);
                    combo.Width = Math.Min(Theme.S(380), W - Theme.S(380));
                    card.Controls.Add(pl);
                    card.Controls.Add(combo);
                    paramBoxes.Add(pl); paramBoxes.Add(combo);
                    y += Theme.S(42);
                }
                card.Height = y + Theme.S(8);
                Action shade = () =>
                {
                    foreach (var x in paramBoxes)
                    {
                        // (a disabled label is drawn in the system's grey, unreadable on the dark card: only its colour changes)
                        if (x is Label lb) lb.ForeColor = cb.Checked ? Theme.Text : Theme.Muted;
                        else x.Enabled = cb.Checked;
                    }
                };
                shade();
                cb.CheckedChanged += (s, e) =>
                {
                    var s2 = GameOpts.Apply(Config.GameOptions ?? "", opt.Id + "=" + (cb.Checked ? "1" : "0"), out _);
                    if (s2 != null) Config.GameOptions = s2;
                    shade();
                    // (switched off, the string forgot its parameters: their defaults again, as the lobby shows them)
                    if (!cb.Checked)
                    {
                        var pickers = paramBoxes.OfType<Picker>().ToList();
                        for (int k = 0; k < opt.Params.Count && k < pickers.Count; k++) pickers[k].Set(opt.Params[k].Default);
                    }
                };
                optRows.Add(card);
            }
            foreach (var r in optRows) optsPage.Controls.Add(r);
            optsPage.ResumeLayout();
        }

        static string Tx(string[] pair, string fallback) => pair == null ? fallback : T(pair[0], pair[1]);

        static string ModuleName(string m)
        {
            switch (m)
            {
                case "journal": return T("Journal et vues", "Journal and views");
                case "stats": return T("Objectif et classement", "Goal and ranking");
                case "market": return T("Concurrence", "Competition");
                case "territory": return T("Territoires et handicaps", "Territories and handicaps");
                case "tenders": return T("Appels d'offres", "Tenders");
                case "perms": return T("Équipes", "Teams");
                case "trade": return T("Commerce entre entreprises", "Trade between companies");
                case "stock": return T("Bourse", "Stock market");
            }
            return m;
        }

        // ---- running

        Control BuildRunningPage()
        {
            var p = Page(T("Fonctionnement", "Running"), T("La vitesse, les pauses, les sauvegardes et le redémarrage automatique du monde.", "The speed, the pauses, the saves and the automatic restart of the world."));
            var c = Config;
            p.Controls.Add(Row(T("Vitesse au démarrage", "Speed at the start"), T("La vitesse du jeu quand le monde démarre.", "The game's speed when the world starts."),
                Choice(new[] { KV("1", "x1"), KV("2", "x2"), KV("4", "x4") }, c.StartSpeed.ToString(CultureInfo.InvariantCulture), v => c.StartSpeed = int.Parse(v, CultureInfo.InvariantCulture))));
            p.Controls.Add(Row(T("Pause quand le serveur est vide", "Pause when the server is empty"), T("Le monde s'arrête tant que personne n'est connecté (comme Satisfactory ou Factorio).", "The world stops while nobody is connected (as in Satisfactory or Factorio)."),
                Check(c.PauseWhenEmpty, v => c.PauseWhenEmpty = v)));
            p.Controls.Add(Row(T("Les joueurs règlent la vitesse", "The players set the speed"), T("Les joueurs peuvent mettre en pause et changer la vitesse. Sinon, seule la console du serveur le peut.", "The players may pause and change the speed. Otherwise, only the server console may."),
                Check(c.PlayerSpeedControl, v => c.PlayerSpeedControl = v)));
            p.Controls.Add(Heading(T("Sauvegardes", "Saves")));
            p.Controls.Add(Row(T("Sauvegarde automatique (minutes)", "Autosave (minutes)"), T("0 : jamais. Le monde s'arrête quelques secondes pendant la sauvegarde.", "0: never. The world stops for a few seconds while it is saved."),
                NumberField(c.AutosaveMinutes, 0, 1440, 5, v => c.AutosaveMinutes = (int)v), Theme.S(140)));
            p.Controls.Add(Row(T("Copies gardées", "Copies kept"), T("Copies du monde gardées dans server\\backups après chaque sauvegarde (0 : aucune).", "Copies of the world kept in server\\backups after each save (0: none)."),
                NumberField(c.Backups, 0, 1000, 1, v => c.Backups = (int)v), Theme.S(140)));
            p.Controls.Add(Heading(T("En cas de problème", "When something goes wrong")));
            p.Controls.Add(Row(T("Relancer le jeu s'il se ferme", "Start the game again when it closes"), T("Au plus 3 fois en 15 minutes.", "At most 3 times in 15 minutes."),
                Check(c.RestartOnCrash, v => c.RestartOnCrash = v)));
            p.Controls.Add(Row(T("Délai sans réponse (secondes)", "Time without an answer (seconds)"), T("Le jeu est relancé s'il ne donne plus signe de vie pendant ce temps (0 : jamais, 30 au moins).", "The game is started again when it gives no sign of life for this long (0: never, 30 at least)."),
                NumberField(c.WatchdogSeconds, 0, 86400, 30, v => c.WatchdogSeconds = (int)v), Theme.S(140)));
            return p;
        }

        /// <summary>(--serversettings --shots: to look at the window) a picture of each page in folder, then the window closes. The
        /// savegames' details are waited for (a few seconds) before the world's page is taken.</summary>
        public void SaveShots(string folder)
        {
            var timer = new System.Windows.Forms.Timer { Interval = 400 };
            int step = 0, waited = 0;
            timer.Tick += (s, e) =>
            {
                try
                {
                    Directory.CreateDirectory(folder);
                    if (step == 1)
                    {
                        // (the world's page: its savegame's details read)
                        SaveDetails d = null;
                        if (shown != null) lock (details) details.TryGetValue(shown.File, out d);
                        bool done; lock (details) done = d == null || d.Done;
                        if (!done && waited++ < 60) return;
                    }
                    if (step >= pages.Count) { timer.Stop(); Close(); return; }
                    ShowPage(step);
                    Application.DoEvents();
                    using (var bmp = new Bitmap(Width, Height))
                    {
                        DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                        bmp.Save(Path.Combine(folder, "page" + step + ".png"), System.Drawing.Imaging.ImageFormat.Png);
                    }
                    step++;
                    if (step < pages.Count) ShowPage(step);
                }
                catch (Exception ex) { Log.W("shots: " + ex.Message); timer.Stop(); Close(); }
            };
            timer.Start();
        }

        // ---------------------------------------------------------------- saving

        bool SaveFile()
        {
            var c = Config;
            if (c.WatchdogSeconds > 0 && c.WatchdogSeconds < 30) c.WatchdogSeconds = 30;
            if (string.IsNullOrWhiteSpace(c.Name)) c.Name = "MPFever Server";
            if (c.Name.Length > 40) c.Name = c.Name.Substring(0, 40);
            c.GameOptions = GameOpts.Canon(c.GameOptions ?? "");
            try
            {
                c.Save(path);
                Log.Ok(F("Paramètres du serveur enregistrés : monde « {0} », {1}.", "Server settings saved: world « {0} », {1}.", c.World, c.CompanyMode == "separate"
                    ? F("une entreprise par joueur, {0} entreprise(s) de l'ordinateur", "one company per player, {0} computer company(ies)", ais.Count) : T("une entreprise pour tous", "one company for everybody")));
                return true;
            }
            catch (Exception e)
            {
                MessageBox.Show(this, T("Impossible d'enregistrer les paramètres : ", "Cannot save the settings: ") + e.Message, "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }
    }
}
