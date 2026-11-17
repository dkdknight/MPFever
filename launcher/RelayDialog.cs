using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The relay settings of a player, in a window instead of relay=, relaypw= and relaykey= typed in
    /// mpfever_settings.txt (as the dedicated server's settings have theirs, ServerSettings.cs): the address, the password and the key
    /// that lets the relay keep the session's save. « Save » writes the three lines; the next game this player hosts uses them. «
    /// Resume the relay's saved game » saves them, closes the window and fetches the save the relay keeps (MainForm.ResumeFromRelay).</summary>
    sealed class RelayDialog : Form
    {
        /// <summary>« Resume the relay's saved game » was pressed (the settings were saved first).</summary>
        public bool ResumeAsked;

        readonly TextBox addressBox = new TextBox();
        readonly TextBox passwordBox = new TextBox { UseSystemPasswordChar = true };
        readonly TextBox keyBox = new TextBox { UseSystemPasswordChar = true };

        public RelayDialog()
        {
            var S = (Func<int, int>)Theme.S;
            Text = "MPFever – " + T("Relais", "Relay");
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            Font = Theme.Ui(9.75f);
            var icon = Theme.AppIcon();
            if (icon != null) Icon = icon;
            HandleCreated += (s, e) => Theme.DarkTitleBar(Handle);
            ClientSize = new Size(S(520), S(520));

            var settings = MainForm.LoadSettings();
            addressBox.Text = MainForm.RelayConf(settings, "relay");
            passwordBox.Text = MainForm.RelayConf(settings, "relaypw");
            keyBox.Text = MainForm.RelayConf(settings, "relaykey");

            var content = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg, Padding = new Padding(S(24), S(20), S(24), S(8)) };
            Control Hint(string text, int lines = 2) => new Label
            {
                Text = text, AutoSize = false, Height = S(16 * lines + 4), ForeColor = Theme.Faint, Font = Theme.Ui(8.5f),
            };
            var title = new Label { Text = T("Relais", "Relay"), AutoSize = false, Height = S(34), Font = Theme.Semibold(12f), ForeColor = Theme.Text };
            var intro = new Label
            {
                Text = T("Hébergez par un petit relais toujours allumé : pas de port à ouvrir, et une seule adresse pour tous les joueurs.",
                         "Host through a small relay that is always on: no port to open, and one address for every player."),
                AutoSize = false, Height = S(40), ForeColor = Theme.Muted, Font = Theme.Ui(9f),
            };
            Ui.StackTop(content,
                title, intro, Ui.Gap(10),
                Ui.Field(T("Adresse du relais", "Relay address"), addressBox),
                Hint(T("Laissez vide pour héberger vous-même, comme d'habitude. Les joueurs rejoignent cette adresse.", "Leave empty to host yourself, as usual. Players join this address.")),
                Ui.Gap(6),
                Ui.Field(T("Mot de passe du relais", "Relay password"), passwordBox),
                Hint(T("Celui de --password du relais ; vide s'il n'en a pas.", "The relay's --password; empty if it has none."), 1),
                Ui.Gap(6),
                Ui.Field(T("Clé de sauvegarde (expérimental)", "Save key (experimental)"), keyBox),
                Hint(T("Le relais garde la dernière sauvegarde de la partie : cette clé permet de l'envoyer et de la reprendre.",
                       "The relay keeps the latest save of the session: this key lets you send it and resume from it."), 3));

            var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = S(60), FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(S(14), S(11), S(14), S(11)), BackColor = Theme.Bg };
            var saveBtn = Btn(ButtonKind.Primary, T("Enregistrer", "Save"));
            saveBtn.Click += (s, e) => { Save(); DialogResult = DialogResult.OK; Close(); };
            var cancel = Btn(ButtonKind.Secondary, T("Annuler", "Cancel"));
            cancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
            var resume = Btn(ButtonKind.Secondary, T("Reprendre la partie du relais", "Resume the relay's saved game"));
            resume.Click += (s, e) =>
            {
                if (addressBox.Text.Trim() == "" || keyBox.Text.Trim() == "")
                {
                    MessageBox.Show(this, T("Pour reprendre, indiquez l'adresse du relais et la clé de sauvegarde.", "To resume, enter the relay address and the save key."), "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Save(); ResumeAsked = true; DialogResult = DialogResult.OK; Close();
            };
            buttons.Controls.Add(saveBtn);
            buttons.Controls.Add(cancel);
            buttons.Controls.Add(resume);
            var note = new Label
            {
                Dock = DockStyle.Bottom, Height = S(24), TextAlign = ContentAlignment.MiddleCenter, Font = Theme.Ui(8.5f), ForeColor = Theme.Faint,
                Text = T("S'applique à la prochaine partie que vous hébergez.", "Applies to the next game you host."),
            };

            Controls.Add(content);
            Controls.Add(note);
            Controls.Add(buttons);
            CancelButton = cancel;
            AcceptButton = saveBtn;
        }

        static ModernButton Btn(ButtonKind kind, string text)
        {
            var b = new ModernButton(kind) { Text = text };
            b.Fit(36);
            b.Margin = new Padding(Theme.S(10), 0, 0, 0);
            return b;
        }

        void Save()
        {
            MainForm.SaveSetting("relay", addressBox.Text.Trim());
            // (the password and the key are written protected by Windows: SecretStore.cs)
            MainForm.SaveSetting("relaypw", SecretStore.Protect(passwordBox.Text.Trim()));
            MainForm.SaveSetting("relaykey", SecretStore.Protect(keyBox.Text.Trim()));
            // (the names the first versions wrote: emptied, or they would be read again when a field is cleared here)
            foreach (var k in new[] { "relay", "relaypw", "relaykey" }) MainForm.SaveSetting(MainForm.LegacyRelayKey(k), "");
        }

        /// <summary>(--relaysettings --shots folder, to look at it) saves a picture of the window and closes it.</summary>
        public void SaveShot(string folder)
        {
            var timer = new System.Windows.Forms.Timer { Interval = 500 };
            timer.Tick += (s, e) =>
            {
                timer.Stop();
                try
                {
                    Directory.CreateDirectory(folder);
                    using (var bmp = new Bitmap(Width, Height))
                    {
                        DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                        bmp.Save(Path.Combine(folder, "relay-settings.png"), System.Drawing.Imaging.ImageFormat.Png);
                    }
                }
                catch (Exception ex) { Log.W("shot: " + ex.Message); }
                Close();
            };
            timer.Start();
        }
    }
}
