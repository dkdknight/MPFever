using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>A setting of the settings window. Session settings are chosen by the host and sent to every player (they
    /// decide how each game replays the others' builds: they must be the same everywhere); the others are this player's
    /// own. Each one is either a variable the mod reads (Env, through settings.txt in the session folder) or a line of
    /// mpfever_settings.txt the launcher reads (Launcher).</summary>
    sealed class Opt
    {
        public string Key;            // MPFEVER_... for the mod, or the mpfever_settings.txt key for the launcher
        public bool Launcher;         // a launcher setting (mpfever_settings.txt), not one of the mod
        public bool Session;          // chosen by the host, the same on every game
        public bool Expert;           // shown only with « Expert settings »
        public bool DefaultOn;
        public string OnValue = "", OffValue = "";   // what the mod reads (empty: the variable is not set)
        public bool Native;           // (0.7.10) also set in the game's environment when on (the native module reads it at its start)
        public Func<string> Name, Help;
    }

    static class Options
    {
        public static readonly Opt[] All =
        {
            // ---- session (the host's choice)
            new Opt { Key = "MPFEVER_BUILDLEAD", Session = true, DefaultOn = true, OnValue = "1",
                Name = () => T("Constructions réactives (expérimental)", "Responsive builds (experimental)"),
                Help = () => T("Vos constructions apparaissent tout de suite chez vous au lieu d'attendre les autres jeux : vous pouvez y raccrocher la suite aussitôt.", "Your builds show at once on your game instead of waiting for the other games: you can attach the next piece right away.") },
            new Opt { Key = "MPFEVER_NOWAIT", Session = true, DefaultOn = false, OnValue = "1",
                Name = () => T("Constructions des autres sans attente (expérimental)", "Other players' builds without waiting (experimental)"),
                Help = () => T("Votre jeu ne s'arrête plus à chaque construction d'un autre joueur pour attendre la réponse du moteur : elle est appliquée au même moment, sans pause.", "Your game no longer stops at every build of another player to wait for the engine's answer: it is applied at the same moment, without a pause.") },
            new Opt { Key = "MPFEVER_NOSTOP", Session = true, DefaultOn = false, OnValue = "1",
                Name = () => T("Plusieurs constructeurs sans arrêt (expérimental)", "Several players building without stopping (experimental)"),
                Help = () => T("Quand plusieurs joueurs construisent en même temps, les jeux ne s'arrêtent plus pour attendre les constructions des autres : chacune part dès le clic et chaque jeu vérifie à son heure que rien n'a changé là où elle se fait. Comprend l'option sans attente.", "When several players build at once, the games no longer stop to wait for each other's builds: each one goes at the click and every game checks at its time that nothing changed where it is made. Includes the no-wait setting.") },
            new Opt { Key = "MPFEVER_NOREFUND", Session = true, DefaultOn = true, OffValue = "1",
                Name = () => T("Remboursements équilibrés", "Balanced refunds"),
                Help = () => T("Une construction démolie juste après coûte la même chose sur tous les jeux.", "A build demolished right after costs the same on every game.") },
            new Opt { Key = "MPFEVER_REPLACEFREE", Session = true, DefaultOn = true, OffValue = "0",
                Name = () => T("Arrêts et signaux au prix de l'outil", "Stops and signals at the tool's price"),
                Help = () => T("Les autres jeux paient un arrêt ou un signal le prix qu'a payé son constructeur.", "The other games pay for a stop or a signal what its builder paid."),
            },
            new Opt { Key = "MPFEVER_PREVIEWS", Session = true, DefaultOn = true, OffValue = "0",
                Name = () => T("Voir ce que les autres construisent", "See what the others are building"),
                Help = () => T("Ce que l'outil d'un autre joueur montre avant son clic s'affiche au sol chez vous, à sa couleur.", "What another player's tool shows before their click shows on the ground in your game, in their colour.") },
            // ---- this player's own
            new Opt { Key = "MPFEVER_SMOOTH", DefaultOn = true, OffValue = "0",
                Name = () => T("Défilement fluide", "Smooth pacing"),
                Help = () => T("Lisse l'affichage quand les jeux s'attendent.", "Smooths the display while the games wait for each other.") },
            new Opt { Key = "MPFEVER_ADAPTAHEAD", DefaultOn = false, OnValue = "1",
                Name = () => T("Mode PC lent", "Slow PC mode"),
                Help = () => T("Donne plus de marge aux constructions quand ce PC est très chargé.", "Gives builds more room when this PC is very busy.") },
            // (0.7.10, test) the platform-order fixes of TPF3-MP ported in 0.5.0 and off since: every player of a session the same
            new Opt { Key = "MPFEVER_ORDER2", DefaultOn = false, OnValue = "1", Native = true,
                Name = () => T("Ordre des quais identique (test)", "Same platform order (test)"),
                Help = () => T("Test contre les véhicules qui divergent dans les gares : les véhicules choisissent leur quai ou leur terminal dans le même ordre sur chaque jeu. Tous les joueurs de la partie doivent l'activer, l'hôte aussi, puis relancer le jeu.",
                    "A test against vehicles drifting apart in stations: the vehicles pick their platform or terminal in the same order on every game. Every player of the game must turn it on, the host too, then start the game again.") },
            new Opt { Key = "MPFEVER_STEPLOG", DefaultOn = false, OnValue = "1",
                Name = () => T("Journaux détaillés", "Detailed logs"),
                Help = () => T("Plus de détails dans les rapports de problème (fichiers plus gros).", "More details in problem reports (bigger files).") },
            new Opt { Key = "autoupdate", Launcher = true, DefaultOn = true, OnValue = "1", OffValue = "0",
                Name = () => T("Mise à jour automatique", "Automatic update"),
                Help = () => T("Installe une nouvelle version de MPFever à la fermeture du jeu.", "Installs a new MPFever version when the game closes.") },
            new Opt { Key = "upnp", Launcher = true, DefaultOn = true, OnValue = "1", OffValue = "0",
                Name = () => T("Ouverture automatique du port (UPnP)", "Open the port by itself (UPnP)"),
                Help = () => T("Pour héberger : ouvre le port sur votre box.", "To host: opens the port on your router.") },
            new Opt { Key = "automods", Launcher = true, DefaultOn = true, OnValue = "1", OffValue = "0",
                Name = () => T("Installation automatique des mods manquants", "Install missing mods by themselves"),
                Help = () => T("En rejoignant : le Mod Hub du jeu installe les mods de l'hôte qui vous manquent.", "When joining: the game's Mod Hub installs the host's mods you lack.") },
            new Opt { Key = "lookupip", Launcher = true, DefaultOn = true, OnValue = "1", OffValue = "0",
                Name = () => T("Recherche de l'adresse IP publique", "Look up the public IP address"),
                Help = () => T("Pour héberger : affiche l'adresse à donner à vos amis.", "To host: shows the address to give to your friends.") },
            // ---- expert: the switches of recent fixes (session), to turn one off when asked to
            Fix("MPFEVER_JUNCTIONCON", "0", () => T("Échangeurs et ronds-points rejoués comme des constructions (0.3.23)", "Junctions and roundabouts replayed as constructions (0.3.23)")),
            Fix("MPFEVER_TOWNNATIVE", "0", () => T("Rues de ville améliorées rejouées comme l'outil (0.3.24)", "Upgraded town streets replayed as the tool's build (0.3.24)")),
            Fix("MPFEVER_TOWNUPGRADE", "0", () => T("Rues de ville améliorées par le moteur (0.3.21)", "Town streets upgraded by the engine (0.3.21)")),
            Fix("MPFEVER_STOPCLEANUP", "1", () => T("Arrêts rejoués sans remodeler la rue (0.3.21)", "Stops replayed without reshaping the street (0.3.21)")),
            Fix("MPFEVER_CONBYFILE", "0", () => T("Gares reconnues par leur fichier (0.3.21)", "Stations recognised by their file (0.3.21)")),
            Fix("MPFEVER_EDITFORMS", "1", () => T("Éditions de gare jamais reconstruites par script (0.3.21)", "Station edits never rebuilt by script (0.3.21)")),
            Fix("MPFEVER_REPLAYUNUSED", "0", () => T("Constructions refusées décomptées en pause (0.3.21)", "Refused builds uncounted while paused (0.3.21)")),
            Fix("MPFEVER_RANK1OWN", "0", () => T("Niveau du siège de l'entreprise de l'hôte (0.3.21)", "Host company's headquarters level (0.3.21)")),
            Fix("MPFEVER_MODHOST", "0", () => T("Noms, couleurs et terminaux de lignes des mods envoyés par l'hôte seul (0.4.0)", "Mods' line names, colours and terminals sent by the host only (0.4.0)")),
            Fix("MPFEVER_MODEVENTS", "0", () => T("Constructions rejouées signalées aux mods comme faites ailleurs (0.4.0)", "Replayed builds shown to mods as made elsewhere (0.4.0)")),
        };

        static Opt Fix(string key, string off, Func<string> name) => new Opt
        {
            Key = key, Session = true, Expert = true, DefaultOn = true, OffValue = off, Name = name,
            Help = () => T("Correctif récent : à désactiver seulement si on vous le demande.", "Recent fix: turn it off only when asked to."),
        };

        /// <summary>The autotests: their environment variables decide, settings.txt is not written.</summary>
        public static bool Disabled;

        /// <summary>The session settings received from the host (client), else null: this game uses its own.</summary>
        public static Dictionary<string, string> HostSession;

        static string StoreKey(Opt o) => o.Launcher ? o.Key : "opt." + o.Key;

        public static bool IsOn(Opt o)
        {
            if (MainForm.LoadSettings().TryGetValue(StoreKey(o), out var v))
            {
                v = v.Trim().ToLowerInvariant();
                if (o.Launcher) return v != "0";
                return v == "1";
            }
            return o.DefaultOn;
        }

        public static void Set(Opt o, bool on)
        {
            MainForm.SaveSetting(StoreKey(o), o.Launcher ? (on ? o.OnValue : o.OffValue) : (on ? "1" : "0"));
        }

        static string Value(Opt o, bool on) => on ? o.OnValue : o.OffValue;

        /// <summary>The session settings of this game as the host sends them ("KEY=value;..."), every one.</summary>
        public static string SessionPayload() => string.Join(";", All.Where(o => o.Session).Select(o => o.Key + "=" + Value(o, IsOn(o))));

        public static Dictionary<string, string> ParsePayload(string s)
        {
            var d = new Dictionary<string, string>();
            foreach (var part in (s ?? "").Split(';'))
            {
                int i = part.IndexOf('=');
                if (i > 0) d[part.Substring(0, i)] = part.Substring(i + 1);
            }
            return d;
        }

        /// <summary>(0.7.10) Whether this player turned « Same platform order (test) » on.</summary>
        public static bool Order2On() => All.Where(o => o.Key == "MPFEVER_ORDER2").Select(IsOn).FirstOrDefault();

        /// <summary>(0.7.10) This player's own settings the game's native module reads at its start: KEY=value of each one on.</summary>
        public static IEnumerable<KeyValuePair<string, string>> NativeEnv() =>
            All.Where(o => o.Native && !o.Session && IsOn(o) && o.OnValue != "").Select(o => new KeyValuePair<string, string>(o.Key, o.OnValue));

        /// <summary>settings.txt for the mod: the session settings (the host's when received) and this player's own.</summary>
        public static string ModFile()
        {
            var lines = new List<string>();
            foreach (var o in All.Where(x => !x.Launcher))
            {
                string v = o.Session && HostSession != null && HostSession.TryGetValue(o.Key, out var hv) ? hv : Value(o, IsOn(o));
                // (the diagnostic build: the detailed logs, whatever this player chose, see GameInstall.DiagOn)
                if (o.Key == "MPFEVER_STEPLOG" && GameInstall.DiagOn()) v = "1";
                lines.Add(o.Key + "=" + v);
            }
            return string.Join("\n", lines) + "\n";
        }

        /// <summary>settings_info.txt for the in-game MPFever window (its Settings tab, read only): every setting of the mod with
        /// its name in this player's language, its kind and whether it is on, one per line "KEY TAB name TAB session|own|expert
        /// TAB 1|0" (a session setting as the host chose it, once received).</summary>
        public static string InfoFile()
        {
            var lines = new List<string>();
            foreach (var o in All.Where(x => !x.Launcher))
            {
                bool on = IsOn(o);
                if (o.Session && HostSession != null && HostSession.TryGetValue(o.Key, out var hv)) on = hv == o.OnValue;
                string name = (o.Name?.Invoke() ?? o.Key).Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
                lines.Add(o.Key + "\t" + name + "\t" + (o.Expert ? "expert" : o.Session ? "session" : "own") + "\t" + (on ? "1" : "0"));
            }
            return string.Join("\n", lines) + "\n";
        }

        /// <summary>For problem reports: the settings that are not at their default ("none" else).</summary>
        public static string Changed()
        {
            var c = new List<string>();
            foreach (var o in All)
            {
                bool on = IsOn(o);
                if (o.Session && HostSession != null && HostSession.TryGetValue(o.Key, out var hv)) on = hv == o.OnValue;
                if (on != o.DefaultOn) c.Add(o.Key.Replace("MPFEVER_", "") + "=" + (on ? "on" : "off") + (o.Session && HostSession != null ? " (host)" : ""));
            }
            return c.Count == 0 ? "none" : string.Join(", ", c);
        }
    }

    /// <summary>The settings window: the session's (chosen by the host, read only on a guest's PC once joined), this
    /// player's own, and the expert ones (the switches of recent fixes), hidden until asked for.</summary>
    sealed class OptionsDialog : Form
    {
        public OptionsDialog(bool guest)
        {
            var S = (Func<int, int>)Theme.S;
            Text = "MPFever – " + T("Réglages", "Settings");
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            Font = Theme.Ui(9.75f);
            var icon = Theme.AppIcon();
            if (icon != null) Icon = icon;
            HandleCreated += (s, e) => Theme.DarkTitleBar(Handle);
            ClientSize = new Size(S(640), S(600));

            var list = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(S(18), S(12), S(18), S(12)) };
            int w = S(640) - S(60);
            var boxes = new List<KeyValuePair<Opt, CheckBox>>();
            var expertRows = new List<Control>();

            Label Heading(string t) => new Label { Text = t, AutoSize = false, Width = w, Height = S(30), Font = Theme.Semibold(11.5f), ForeColor = Theme.Text, TextAlign = ContentAlignment.BottomLeft };
            Label Note(string t) => new Label { Text = t, AutoSize = false, Width = w, Height = S(34), Font = Theme.Ui(8.75f), ForeColor = Theme.Faint };
            Control Row(Opt o)
            {
                var p = new Panel { Width = w, Height = S(48) };
                var cb = new CheckBox { Text = o.Name(), Checked = Options.IsOn(o), AutoSize = false, Width = w, Height = S(24), Font = Theme.Ui(9.75f), ForeColor = Theme.Text, Location = new Point(0, 0) };
                var help = new Label { Text = o.Help(), AutoSize = false, Width = w - S(20), Height = S(22), Location = new Point(S(20), S(24)), Font = Theme.Ui(8.5f), ForeColor = Theme.Muted };
                if (o.Session && guest)
                {
                    cb.Enabled = false;
                    if (Options.HostSession != null && Options.HostSession.TryGetValue(o.Key, out var hv)) cb.Checked = hv == o.OnValue;
                }
                cb.CheckedChanged += (s, e) => { if (cb.Enabled) Options.Set(o, cb.Checked); };
                p.Controls.Add(cb);
                p.Controls.Add(help);
                boxes.Add(new KeyValuePair<Opt, CheckBox>(o, cb));
                return p;
            }

            list.Controls.Add(Heading(T("Réglages de la partie", "Game settings")));
            list.Controls.Add(Note(guest
                ? T("Choisis par l'hôte de la partie : ils sont les mêmes sur tous les jeux.", "Chosen by the game's host: they are the same on every game.")
                : T("Si vous hébergez, ils sont envoyés aux autres joueurs : ils sont les mêmes sur tous les jeux.", "When you host, they are sent to the other players: they are the same on every game.")));
            foreach (var o in Options.All.Where(x => x.Session && !x.Expert)) list.Controls.Add(Row(o));
            list.Controls.Add(Heading(T("Réglages personnels", "Your settings")));
            foreach (var o in Options.All.Where(x => !x.Session)) list.Controls.Add(Row(o));

            var showExpert = new CheckBox { Text = T("Afficher les réglages experts", "Show the expert settings"), AutoSize = false, Width = w, Height = S(34), Font = Theme.Semibold(10f), ForeColor = Theme.Warning };
            list.Controls.Add(showExpert);
            var expertNote = Note(T("Correctifs récents : ne les désactivez que si on vous le demande dans une issue GitHub. Choisis par l'hôte.", "Recent fixes: turn them off only when asked to in a GitHub issue. Chosen by the host."));
            expertRows.Add(expertNote);
            list.Controls.Add(expertNote);
            foreach (var o in Options.All.Where(x => x.Expert)) { var r = Row(o); expertRows.Add(r); list.Controls.Add(r); }
            foreach (var r in expertRows) r.Visible = false;
            showExpert.CheckedChanged += (s, e) => { foreach (var r in expertRows) r.Visible = showExpert.Checked; };

            var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = S(56), FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(S(14), S(10), S(14), S(10)) };
            var close = new ModernButton(ButtonKind.Primary) { Text = T("Fermer", "Close") };
            close.Fit(40);
            close.Click += (s, e) => Close();
            var reset = new ModernButton(ButtonKind.Secondary) { Text = T("Valeurs par défaut", "Default values") };
            reset.Fit();
            reset.Margin = new Padding(0, 0, S(10), 0);
            reset.Click += (s, e) =>
            {
                foreach (var kv in boxes)
                    if (kv.Value.Enabled) { kv.Value.Checked = kv.Key.DefaultOn; Options.Set(kv.Key, kv.Key.DefaultOn); }
            };
            buttons.Controls.Add(close);
            buttons.Controls.Add(reset);
            var note = new Label { Dock = DockStyle.Bottom, Height = S(24), TextAlign = ContentAlignment.MiddleCenter, Font = Theme.Ui(8.5f), ForeColor = Theme.Faint,
                Text = T("Les réglages s'appliquent au prochain chargement d'une partie.", "The settings apply from the next time a game loads.") };

            Controls.Add(list);
            Controls.Add(note);
            Controls.Add(buttons);
            CancelButton = close;
        }
    }
}
