using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>A published MPFever release and its zip.</summary>
    sealed class UpdateInfo
    {
        public string Tag, Version, PageUrl, ZipUrl, Sha256;
        public long ZipSize;
    }

    /// <summary>Automatic update from the GitHub releases of MPFever (github.com/dkdknight/MPFever/releases).
    /// At startup, before the game starts, the launcher asks GitHub for the newest release. When it is newer than this
    /// launcher, a window offers to update or to go on without updating. The update downloads the release's zip, checks
    /// its size and SHA-256, puts its files into MPFever's folder and starts the new MPFever.exe (which then installs the
    /// new mod and native module as usual). The files it replaces wait in .update_old until the next start: the running
    /// MPFever.exe and a loaded winhttp.dll can be moved, not overwritten. On an error they are put back. The player's
    /// own files (mpfever_settings.txt, logs) are kept. autoupdate=0 in mpfever_settings.txt turns the check off.</summary>
    static class Updater
    {
        public const string Repo = "dkdknight/MPFever";
        public const string ReleasesPage = "https://github.com/" + Repo + "/releases";
        const string Api = "https://api.github.com/repos/" + Repo + "/releases?per_page=30";
        /// <summary>How long the start of the game waits at most for GitHub's answer.</summary>
        public const int CheckTimeoutMs = 6000;
        const string OldDirName = ".update_old";
        /// <summary>Files of the player that an update never replaces.</summary>
        static readonly HashSet<string> Keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "mpfever_settings.txt", "mpfever_server.properties" };

        public static string AppDir => AppDomain.CurrentDomain.BaseDirectory;
        static string TempDir => Path.Combine(Path.GetTempPath(), "mpfever_update");

        /// <summary>Off with autoupdate=0 in mpfever_settings.txt.</summary>
        public static bool Enabled => !(MainForm.LoadSettings().TryGetValue("autoupdate", out var v) && v.Trim() == "0");

        /// <summary>MPFever.exe runs from an unpacked release (mod\mpfever_1 next to it), not from a build folder.</summary>
        public static bool InReleaseFolder => File.Exists(Path.Combine(AppDir, "mod", "mpfever_1", "mod.json"));

        // ---------------------------------------------------------------- versions

        /// <summary>The numbers of the first version in a text ("0.3.10-experimental", "MPFever0.2.0", "v1.2"), or null.</summary>
        public static int[] ParseVersion(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            var m = Regex.Match(s, @"\d+(?:\.\d+)+");
            if (!m.Success) return null;
            try { return m.Value.Split('.').Select(x => int.Parse(x, NumberStyles.None, CultureInfo.InvariantCulture)).ToArray(); }
            catch (OverflowException) { return null; }
        }

        /// <summary>Compares two versions number by number (0.3.10 is newer than 0.3.9; 0.3 equals 0.3.0).</summary>
        public static int CompareVersions(int[] a, int[] b)
        {
            for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
            {
                int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
                if (x != y) return x.CompareTo(y);
            }
            return 0;
        }

        static object Get(Dictionary<string, object> d, string k) => d.TryGetValue(k, out var v) ? v : null;
        static string Str(Dictionary<string, object> d, string k) => Get(d, k) as string ?? "";

        /// <summary>From GitHub's list of releases: the newest published one (no draft, no pre-release) that has an
        /// MPFever zip, when it is newer than <paramref name="current"/>; else null.</summary>
        public static UpdateInfo Newest(string json, string current)
        {
            var cur = ParseVersion(current) ?? new[] { 0 };
            if (!(Json.Parse(json) is List<object> releases)) return null;
            UpdateInfo best = null;
            int[] bestV = null;
            foreach (var r in releases.OfType<Dictionary<string, object>>())
            {
                if (Get(r, "draft") is bool draft && draft) continue;
                if (Get(r, "prerelease") is bool pre && pre) continue;
                var zip = (Get(r, "assets") as List<object> ?? new List<object>()).OfType<Dictionary<string, object>>().FirstOrDefault(a =>
                    Str(a, "name").StartsWith("MPFever", StringComparison.OrdinalIgnoreCase) && Str(a, "name").EndsWith(".zip", StringComparison.OrdinalIgnoreCase)
                    && Str(a, "browser_download_url").StartsWith("https://", StringComparison.OrdinalIgnoreCase));
                if (zip == null) continue;
                // the version of the tag (0.3.10, MPFever0.2.0), else of the title or of the zip's name
                var v = ParseVersion(Str(r, "tag_name")) ?? ParseVersion(Str(r, "name")) ?? ParseVersion(Str(zip, "name"));
                if (v == null || (bestV != null && CompareVersions(v, bestV) <= 0)) continue;
                var digest = Str(zip, "digest");
                best = new UpdateInfo
                {
                    Tag = Str(r, "tag_name"),
                    Version = string.Join(".", v),
                    PageUrl = Str(r, "html_url") != "" ? Str(r, "html_url") : ReleasesPage,
                    ZipUrl = Str(zip, "browser_download_url"),
                    ZipSize = Get(zip, "size") is double size ? (long)size : 0,
                    Sha256 = digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) ? digest.Substring(7).ToLowerInvariant() : null,
                };
                bestV = v;
            }
            return best != null && CompareVersions(bestV, cur) > 0 ? best : null;
        }

        // ---------------------------------------------------------------- GitHub

        static HttpWebRequest Request(string url, int timeoutMs)
        {
            // .NET 4.8 uses the TLS versions of Windows (SystemDefault); an older explicit setting gets TLS 1.2 added for GitHub
            try { if (ServicePointManager.SecurityProtocol != SecurityProtocolType.SystemDefault) ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = "MPFever-Launcher/" + MainForm.Version;   // GitHub refuses requests without one
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            return req;
        }

        /// <summary>The newest release when it is newer than this launcher, else null (throws when GitHub cannot be reached).</summary>
        public static UpdateInfo Check()
        {
            var req = Request(Api, CheckTimeoutMs);
            req.Accept = "application/vnd.github+json";
            req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            using (var resp = req.GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return Newest(r.ReadToEnd(), MainForm.Version);
        }

        /// <summary>Downloads the update, puts its files into MPFever's folder (see <see cref="Install"/>).
        /// <paramref name="progress"/>: bytes received and expected; <paramref name="installing"/>: download finished.</summary>
        public static void Run(UpdateInfo u, Action<long, long> progress, Action installing)
        {
            var work = Path.Combine(TempDir, Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
            if (Directory.Exists(work)) Directory.Delete(work, true);
            Directory.CreateDirectory(work);
            var zip = Path.Combine(work, "update.zip");
            Log.W(F("Téléchargement de MPFever {0} : {1}", "Downloading MPFever {0}: {1}", u.Version, u.ZipUrl));
            Download(u, zip, progress);
            installing?.Invoke();
            var files = Path.Combine(work, "files");
            Unpack(zip, files);
            Install(files, AppDir);
            Log.Ok(F("MPFever {0} installé : redémarrage", "MPFever {0} installed: restarting", u.Version));
        }

        /// <summary>The zip of the release, checked against the size and SHA-256 given by GitHub.</summary>
        static void Download(UpdateInfo u, string zip, Action<long, long> progress)
        {
            var req = Request(u.ZipUrl, 30000);
            using (var resp = req.GetResponse())
            using (var src = resp.GetResponseStream())
            using (var dst = File.Create(zip))
            using (var sha = SHA256.Create())
            {
                long total = u.ZipSize > 0 ? u.ZipSize : resp.ContentLength, done = 0;
                var buf = new byte[81920];
                int n;
                while ((n = src.Read(buf, 0, buf.Length)) > 0)
                {
                    dst.Write(buf, 0, n);
                    sha.TransformBlock(buf, 0, n, null, 0);
                    done += n;
                    progress?.Invoke(done, total);
                }
                sha.TransformFinalBlock(buf, 0, 0);
                if (u.ZipSize > 0 && done != u.ZipSize)
                    throw new IOException(F("le fichier téléchargé n'a pas la bonne taille ({0} octets au lieu de {1})", "the downloaded file has the wrong size ({0} bytes instead of {1})", done, u.ZipSize));
                var hex = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                if (u.Sha256 != null && hex != u.Sha256)
                    throw new IOException(T("le fichier téléchargé est endommagé (somme SHA-256 différente)", "the downloaded file is damaged (SHA-256 checksum differs)"));
            }
        }

        /// <summary>Unpacks the zip into <paramref name="dst"/>. The release zip holds one folder (MPFever\...): its
        /// content is what goes into MPFever's folder. Entries written with \ or / are both accepted.</summary>
        public static void Unpack(string zip, string dst)
        {
            Directory.CreateDirectory(dst);
            var root = Path.GetFullPath(dst).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            using (var z = ZipFile.OpenRead(zip))
            {
                var names = z.Entries.Select(e => e.FullName.Replace('\\', '/')).Where(x => x != "").ToList();
                string prefix = "";
                var tops = names.Select(x => x.Split('/')[0]).Distinct().ToList();
                if (tops.Count == 1 && names.All(x => x.StartsWith(tops[0] + "/", StringComparison.Ordinal))) prefix = tops[0] + "/";
                foreach (var e in z.Entries)
                {
                    var name = e.FullName.Replace('\\', '/');
                    if (prefix != "" && name.StartsWith(prefix, StringComparison.Ordinal)) name = name.Substring(prefix.Length);
                    if (name == "" || name.EndsWith("/", StringComparison.Ordinal)) continue;   // a folder
                    var path = Path.GetFullPath(Path.Combine(dst, name.Replace('/', Path.DirectorySeparatorChar)));
                    if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new IOException("zip entry outside the folder: " + e.FullName);
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    e.ExtractToFile(path, true);
                }
            }
            if (!File.Exists(Path.Combine(dst, "MPFever.exe")))
                throw new IOException(T("MPFever.exe manque dans la mise à jour", "MPFever.exe is missing from the update"));
        }

        /// <summary>Puts the unpacked files into <paramref name="appDir"/>. Each file or folder it replaces is first moved
        /// to .update_old (Windows lets a running exe or a loaded DLL be moved, not overwritten); a folder of the release
        /// (mod\) replaces the old one as a whole, so files removed from the mod go too. Files of the player (settings,
        /// logs) are not touched. On an error everything is put back as it was, then the error is thrown again.</summary>
        public static void Install(string files, string appDir)
        {
            var oldRoot = Path.Combine(appDir, OldDirName);
            try { if (Directory.Exists(oldRoot)) Directory.Delete(oldRoot, true); } catch { }   // left by an earlier update
            var old = Path.Combine(oldRoot, DateTime.Now.Ticks.ToString(CultureInfo.InvariantCulture));
            Directory.CreateDirectory(old);
            try { new DirectoryInfo(oldRoot).Attributes |= FileAttributes.Hidden; } catch { }
            var moved = new List<KeyValuePair<string, string>>();   // original path -> where it was moved
            var added = new List<string>();
            try
            {
                foreach (var src in Directory.GetFileSystemEntries(files))
                {
                    var name = Path.GetFileName(src);
                    var target = Path.Combine(appDir, name);
                    bool isDir = Directory.Exists(src);
                    if (!isDir && Keep.Contains(name) && File.Exists(target)) continue;
                    if (File.Exists(target) || Directory.Exists(target))
                    {
                        var aside = Path.Combine(old, name);
                        if (Directory.Exists(target)) Directory.Move(target, aside); else File.Move(target, aside);
                        moved.Add(new KeyValuePair<string, string>(target, aside));
                    }
                    added.Add(target);
                    if (isDir) CopyDir(src, target); else File.Copy(src, target);
                }
            }
            catch
            {
                for (int i = added.Count - 1; i >= 0; i--)
                    try { if (Directory.Exists(added[i])) Directory.Delete(added[i], true); else if (File.Exists(added[i])) File.Delete(added[i]); } catch { }
                for (int i = moved.Count - 1; i >= 0; i--)
                    try { if (Directory.Exists(moved[i].Value)) Directory.Move(moved[i].Value, moved[i].Key); else File.Move(moved[i].Value, moved[i].Key); } catch { }
                Log.Warn(T("Mise à jour annulée : les fichiers d'origine sont remis en place", "Update cancelled: the original files are put back"));
                throw;
            }
        }

        static void CopyDir(string src, string dst)
        {
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true);
            foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
        }

        /// <summary>Starts the new MPFever.exe with the same arguments and --updated (this launcher then closes).</summary>
        public static void Restart(string[] args)
        {
            var exe = Path.Combine(AppDir, "MPFever.exe");
            var line = string.Join(" ", args.Where(a => a != "--updated").Concat(new[] { "--updated" }).Select(Quote));
            Process.Start(new ProcessStartInfo(exe, line) { UseShellExecute = false, WorkingDirectory = Environment.CurrentDirectory });
        }

        static string Quote(string a) => a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0 ? a : "\"" + a.Replace("\"", "\\\"") + "\"";

        /// <summary>At startup: the files replaced by the last update and its download are deleted (the old MPFever.exe
        /// may still be closing, so it tries again for a few seconds).</summary>
        public static void CleanUp(bool justUpdated)
        {
            if (justUpdated) Log.Ok(F("Mise à jour installée : MPFever {0}", "Update installed: MPFever {0}", MainForm.Version));
            var old = Path.Combine(AppDir, OldDirName);
            var tmp = TempDir;
            if (!Directory.Exists(old) && !Directory.Exists(tmp)) return;
            new Thread(() =>
            {
                for (int i = 0; i < 20 && (Directory.Exists(old) || Directory.Exists(tmp)); i++)
                {
                    try { if (Directory.Exists(old)) Directory.Delete(old, true); } catch { }
                    try { if (Directory.Exists(tmp)) Directory.Delete(tmp, true); } catch { }
                    Thread.Sleep(500);
                }
            }) { IsBackground = true, Name = "Update cleanup" }.Start();
        }

        /// <summary>The reason of a failed check or update, for the player.</summary>
        public static string Describe(Exception e)
        {
            if (e is UnauthorizedAccessException) return F("pas de droit d'écriture dans {0}", "no write access to {0}", AppDir.TrimEnd('\\', '/'));
            if (e is WebException we && we.Response is HttpWebResponse hr) return "HTTP " + (int)hr.StatusCode + " " + hr.StatusDescription;
            return e.Message;
        }
    }

    /// <summary>The window "New update available": update now, or go on with this version.</summary>
    sealed class UpdateDialog : Form
    {
        readonly UpdateInfo update;
        readonly ModernButton updateBtn = new ModernButton(ButtonKind.Primary);
        readonly ModernButton skipBtn = new ModernButton(ButtonKind.Secondary);
        readonly ProgressLine bar = new ProgressLine { Visible = false };
        readonly Label progressText = new Label { AutoSize = false, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
        readonly ToolTip tip = new ToolTip();
        bool busy;
        int shownPercent = -1;

        public UpdateDialog(UpdateInfo u)
        {
            update = u;
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
            ClientSize = new Size(S(540), S(250));

            var card = new Card { Dock = DockStyle.Fill, Padding = new Padding(S(22), S(18), S(22), S(18)) };
            var title = new Label { Text = T("Nouvelle mise à jour disponible", "New update available"), AutoSize = false, Height = S(34), Font = Theme.Semibold(13f), ForeColor = Theme.Text };
            var text = new Label
            {
                Text = F("MPFever {0} est disponible. Version installée : {1}.", "MPFever {0} is available. Installed version: {1}.", u.Version, MainForm.Version),
                AutoSize = false, Height = S(44), ForeColor = Theme.Muted, Font = Theme.Ui(9.75f),
            };
            var linkFont = Theme.Ui(9.25f, FontStyle.Underline);
            var notes = new Label { Text = T("Voir les nouveautés", "See what's new"), AutoSize = false, Height = S(24), Font = Theme.Ui(9.25f), ForeColor = Theme.Accent, Cursor = Cursors.Hand };
            notes.Width = TextRenderer.MeasureText(notes.Text, linkFont).Width + S(8);
            notes.MouseEnter += (s, e) => { notes.Font = linkFont; notes.ForeColor = Theme.AccentHover; };
            notes.MouseLeave += (s, e) => { notes.Font = Theme.Ui(9.25f); notes.ForeColor = Theme.Accent; };
            notes.Click += (s, e) => { try { Process.Start(update.PageUrl); } catch (Exception ex) { Log.W(ex.Message); } };
            var notesRow = new Panel { Height = S(24) };
            notes.Dock = DockStyle.Left;
            notesRow.Controls.Add(notes);

            progressText.Font = Theme.Ui(9f);
            progressText.ForeColor = Theme.Muted;
            progressText.Height = S(22);
            bar.Height = S(6);

            updateBtn.Text = T("Mettre à jour", "Update");
            skipBtn.Text = T("Continuer sans mettre à jour", "Continue without updating");
            updateBtn.Fit(40);
            skipBtn.Fit();
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = S(40), FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Margin = Padding.Empty, Padding = Padding.Empty };
            updateBtn.Margin = Padding.Empty;
            skipBtn.Margin = new Padding(0, 0, S(10), 0);
            buttons.Controls.Add(updateBtn);
            buttons.Controls.Add(skipBtn);

            // docked from the last added: the buttons at the very bottom, the progress above them, the texts at the top
            var progressBox = new Panel { Dock = DockStyle.Bottom, Height = S(40) };
            Ui.StackTop(progressBox, progressText, Ui.Gap(4), bar);
            card.Controls.Add(progressBox);
            card.Controls.Add(buttons);
            Ui.StackTop(card, title, text, notesRow);

            var outer = new Panel { Dock = DockStyle.Fill, Padding = new Padding(S(14)) };
            outer.Controls.Add(card);
            Controls.Add(outer);

            AcceptButton = updateBtn;
            CancelButton = skipBtn;
            skipBtn.Click += (s, e) => DialogResult = DialogResult.Cancel;
            updateBtn.Click += (s, e) => StartUpdate();
            // no closing while the files are being replaced
            FormClosing += (s, e) => { if (busy) e.Cancel = true; };
            FormClosed += (s, e) => tip.Dispose();
        }

        void OnUi(Action a)
        {
            try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { }
        }

        void SetStatus(string s, Color c)
        {
            progressText.Text = s;
            progressText.ForeColor = c;
            tip.SetToolTip(progressText, s);   // the whole text when it is cut
        }

        void StartUpdate()
        {
            busy = true;
            updateBtn.Enabled = skipBtn.Enabled = false;
            bar.Visible = true;
            bar.Value = 0;
            shownPercent = -1;
            SetStatus(F("Téléchargement… {0}", "Downloading… {0}", "0 %"), Theme.Muted);
            new Thread(() =>
            {
                try
                {
                    Updater.Run(update,
                        (done, total) =>
                        {
                            int pct = total > 0 ? (int)Math.Min(100, done * 100 / total) : -1;
                            if (pct == shownPercent) return;
                            shownPercent = pct;
                            var shown = pct >= 0 ? pct + " %" : (done / 1048576.0).ToString("0.0", CultureInfo.CurrentCulture) + " MB";
                            OnUi(() => { bar.Value = pct >= 0 ? pct / 100f : 0; SetStatus(F("Téléchargement… {0}", "Downloading… {0}", shown), Theme.Muted); });
                        },
                        () => OnUi(() => { bar.Value = 1; SetStatus(T("Installation…", "Installing…"), Theme.Muted); }));
                    OnUi(() =>
                    {
                        SetStatus(T("Redémarrage de MPFever…", "Restarting MPFever…"), Theme.Success);
                        busy = false;
                        DialogResult = DialogResult.OK;   // closes the window: the launcher restarts
                    });
                }
                catch (Exception e)
                {
                    var why = Updater.Describe(e);
                    Log.Err(F("Échec de la mise à jour : {0}", "Update failed: {0}", why));
                    OnUi(() =>
                    {
                        busy = false;
                        bar.Visible = false;
                        SetStatus(F("Échec de la mise à jour : {0}", "Update failed: {0}", why), Theme.Danger);
                        updateBtn.Text = T("Réessayer", "Try again");
                        updateBtn.Fit(40);
                        updateBtn.Enabled = skipBtn.Enabled = true;
                    });
                }
            }) { IsBackground = true, Name = "Update" }.Start();
        }
    }

    /// <summary>Thin rounded progress bar in the accent colour.</summary>
    sealed class ProgressLine : Control
    {
        float fraction;

        public float Value { get => fraction; set { fraction = Math.Max(0f, Math.Min(1f, value)); Invalidate(); } }

        public ProgressLine()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Height = Theme.S(6);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Theme.Box(e.Graphics, this, Theme.BackOf(this), Theme.Raised, Color.Transparent, Height / 2);
            float w = (Width - 1.5f) * fraction;
            if (w <= 0) return;
            using (var path = Theme.Round(new RectangleF(0.5f, 0.5f, Math.Max(Height - 1.5f, w), Height - 1.5f), Height / 2f))
            using (var b = new SolidBrush(Theme.Accent))
                e.Graphics.FillPath(b, path);
        }
    }
}
