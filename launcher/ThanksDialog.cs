using System;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>Shown over the launcher once the game is closed: thanks, and the ways to support, rate or report. Escape or
    /// « Close » keeps the launcher open (Cancel), « Quit MPFever » closes everything (Abort), « Report a problem » asks the
    /// launcher for a report (Retry). Starting the game again is the launcher window's own button (issue #94). The links open
    /// in the browser and leave the window as it is.</summary>
    sealed class ThanksDialog : Form
    {
        public const string KofiUrl = "https://ko-fi.com/knighthd";
        public const string NexusUrl = "https://www.nexusmods.com/transportfever3/mods/4?tab=posts";
        public const string GitHubUrl = "https://github.com/dkdknight/MPFever";
        public const string DiscordUrl = "https://discord.gg/DfMxFUQZCR";

        public ThanksDialog()
        {
            var S = (Func<int, int>)Theme.S;
            Text = "MPFever";
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
            ClientSize = new Size(S(780), S(250));

            var card = new Card { Dock = DockStyle.Fill, Padding = new Padding(S(22), S(18), S(22), S(18)) };
            var title = new Label { Text = T("Merci d'avoir joué avec MPFever !", "Thanks for playing with MPFever!"), AutoSize = false, Height = S(34), Font = Theme.Semibold(13f), ForeColor = Theme.Text };
            var text = new Label
            {
                Text = T("MPFever est gratuit et développé sur mon temps libre. Un don, un commentaire ou un « j'aime » m'aide beaucoup à le faire avancer.",
                    "MPFever is free and made on my free time. A tip, a comment or a like helps me a lot to keep it going."),
                AutoSize = false, Height = S(48), ForeColor = Theme.Muted, Font = Theme.Ui(9.75f),
            };

            var kofi = Btn(ButtonKind.Primary, T("♥ Soutenir sur Ko-fi", "♥ Support on Ko-fi"), () => Open(KofiUrl));
            var discord = Btn(ButtonKind.Secondary, "Discord", () => Open(DiscordUrl));
            var nexus = Btn(ButtonKind.Secondary, T("Avis sur Nexus", "Rate on Nexus"), () => Open(NexusUrl));
            var github = Btn(ButtonKind.Secondary, T("Étoile sur GitHub", "Star on GitHub"), () => Open(GitHubUrl));
            var report = Btn(ButtonKind.Secondary, T("Signaler un problème", "Report a problem"), () => DialogResult = DialogResult.Retry);
            var links = Row(S(40), FlowDirection.LeftToRight, kofi, discord, nexus, github, report);

            var close = Btn(ButtonKind.Secondary, T("Fermer", "Close"), () => DialogResult = DialogResult.Cancel);
            var quit = Btn(ButtonKind.Ghost, T("Tout fermer", "Quit MPFever"), () => DialogResult = DialogResult.Abort);
            var bottom = Row(S(40), FlowDirection.RightToLeft, close, quit);
            bottom.Dock = DockStyle.Bottom;

            card.Controls.Add(bottom);
            Ui.StackTop(card, title, text, links);
            var outer = new Panel { Dock = DockStyle.Fill, Padding = new Padding(S(14)) };
            outer.Controls.Add(card);
            Controls.Add(outer);
            CancelButton = close;
        }

        static ModernButton Btn(ButtonKind kind, string label, Action click)
        {
            var b = new ModernButton(kind) { Text = label };
            b.Fit();
            b.Margin = new Padding(0, 0, Theme.S(8), 0);
            b.Click += (s, e) => click();
            return b;
        }

        static FlowLayoutPanel Row(int height, FlowDirection dir, params Control[] items)
        {
            var p = new FlowLayoutPanel { Height = height, FlowDirection = dir, WrapContents = false, Margin = Padding.Empty, Padding = Padding.Empty };
            p.Controls.AddRange(items);
            return p;
        }

        static void Open(string url)
        {
            try { Process.Start(url); }
            catch (Exception ex) { Log.W(ex.Message); }
        }
    }
}
