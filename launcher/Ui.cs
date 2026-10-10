using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MPFever
{
    /// <summary>Colours, fonts and helpers of the launcher's dark theme.</summary>
    static class Theme
    {
        public static readonly Color Bg = Color.FromArgb(16, 17, 21);
        public static readonly Color Surface = Color.FromArgb(26, 28, 34);
        public static readonly Color Raised = Color.FromArgb(36, 39, 47);
        public static readonly Color RaisedHover = Color.FromArgb(45, 49, 59);
        public static readonly Color Border = Color.FromArgb(44, 48, 58);
        public static readonly Color Text = Color.FromArgb(233, 235, 240);
        public static readonly Color Muted = Color.FromArgb(146, 152, 166);
        public static readonly Color Faint = Color.FromArgb(94, 100, 114);
        public static readonly Color Accent = Color.FromArgb(255, 138, 61);
        public static readonly Color AccentHover = Color.FromArgb(255, 160, 96);
        public static readonly Color AccentPressed = Color.FromArgb(228, 116, 44);
        public static readonly Color OnAccent = Color.FromArgb(28, 17, 8);
        public static readonly Color Success = Color.FromArgb(52, 211, 153);
        public static readonly Color Warning = Color.FromArgb(251, 191, 36);
        public static readonly Color Danger = Color.FromArgb(248, 113, 113);
        public static readonly Color Info = Color.FromArgb(96, 165, 250);

        /// <summary>Screen DPI / 96: every pixel size of the window goes through <see cref="S"/>.</summary>
        public static float Scale = 1f;
        public static int S(int px) => (int)Math.Round(px * Scale);

        /// <summary>The interface font: Segoe UI, or Windows' own font for the Japanese, Korean and Chinese scripts.</summary>
        public static string UiFamily = "Segoe UI";

        public static void SetLanguage(string code)
        {
            switch (code)
            {
                case "ja": UiFamily = "Yu Gothic UI"; break;
                case "ko": UiFamily = "Malgun Gothic"; break;
                case "zh-CN": UiFamily = "Microsoft YaHei UI"; break;
                case "zh-TW": UiFamily = "Microsoft JhengHei UI"; break;
                default: UiFamily = "Segoe UI"; break;
            }
        }

        public static Font Ui(float pt, FontStyle st = FontStyle.Regular) => Pick(pt, st, UiFamily, "Segoe UI");
        public static Font Semibold(float pt) =>
            (UiFamily == "Segoe UI" ? TryFont("Segoe UI Semibold", pt, FontStyle.Regular) : null) ?? Ui(pt, FontStyle.Bold);
        public static Font Mono(float pt) => Pick(pt, FontStyle.Regular, "Cascadia Mono", "Consolas");

        static Font TryFont(string name, float pt, FontStyle st)
        {
            var f = new Font(name, pt, st);
            if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return f;
            f.Dispose();
            return null;
        }

        static Font Pick(float pt, FontStyle st, params string[] names)
        {
            foreach (var n in names) { var f = TryFont(n, pt, st); if (f != null) return f; }
            return new Font(FontFamily.GenericSansSerif, pt, st);
        }

        public static Color Mix(Color a, Color b, float t) =>
            Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));

        public static GraphicsPath Round(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        /// <summary>Rounded box with an optional 1 px border, drawn over the parent's colour.</summary>
        public static void Box(Graphics g, Control c, Color back, Color fill, Color border, int radius)
        {
            g.Clear(back);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new RectangleF(0.5f, 0.5f, c.Width - 1.5f, c.Height - 1.5f);
            using (var path = Round(r, radius))
            {
                if (fill.A > 0) using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                if (border.A > 0) using (var pen = new Pen(border)) g.DrawPath(pen, path);
            }
        }

        public static Color BackOf(Control c) => c.Parent?.BackColor ?? Bg;

        // ---------------------------------------------------------------- Windows integration

        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);

        public static void InitDpi()
        {
            try { SetProcessDPIAware(); } catch { }
            try { using (var g = Graphics.FromHwnd(IntPtr.Zero)) Scale = Math.Max(1f, g.DpiX / 96f); } catch { }
        }

        /// <summary>Dark title bar (Windows 10 1809+ / 11) in the window's background colour (Windows 11).</summary>
        public static void DarkTitleBar(IntPtr h)
        {
            try
            {
                int on = 1;
                if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4);
                int caption = ColorTranslator.ToWin32(Bg);
                DwmSetWindowAttribute(h, 35, ref caption, 4);
            }
            catch { }
        }

        /// <summary>Dark scroll bars on a control (Windows 10 1809+).</summary>
        public static void DarkScrollBars(Control c)
        {
            try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { }
        }

        public static void ScrollToEnd(Control c)
        {
            try { SendMessage(c.Handle, 0x115 /* WM_VSCROLL */, (IntPtr)7 /* SB_BOTTOM */, IntPtr.Zero); } catch { }
        }

        /// <summary>The window icon: the one embedded in MPFever.exe (app.ico).</summary>
        public static Icon AppIcon()
        {
            try
            {
                var exe = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (exe != null && exe.Width > 0) return exe;
            }
            catch { }
            return null;
        }
    }

    enum ButtonKind { Primary, Secondary, Ghost, Segment }

    /// <summary>Flat button with rounded corners, hover and pressed states.</summary>
    sealed class ModernButton : Button
    {
        public readonly ButtonKind Kind;
        bool hover, down, active;

        /// <summary>Segment buttons: the option currently in effect.</summary>
        public bool Active { get => active; set { if (active != value) { active = value; Invalidate(); } } }

        /// <summary>A small globe in front of the text (language button).</summary>
        public bool Globe;

        public ModernButton(ButtonKind kind)
        {
            Kind = kind;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand;
            ResetFont();
            Height = Theme.S(kind == ButtonKind.Ghost ? 30 : 38);
            UseVisualStyleBackColor = false;
        }

        /// <summary>The theme's font (after a change of language).</summary>
        public new void ResetFont() => Font = Kind == ButtonKind.Primary ? Theme.Semibold(9.75f) : Theme.Ui(9.75f);

        int GlobeSpace => Globe ? Theme.S(20) : 0;

        /// <summary>Width fitted to the text.</summary>
        public ModernButton Fit(int extra = 28)
        {
            Width = TextRenderer.MeasureText(Text, Font).Width + GlobeSpace + Theme.S(extra);
            return this;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { if (!Enabled) hover = down = false; Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            bool en = Enabled;
            Color fill, fore, border = Color.Transparent;
            switch (Kind)
            {
                case ButtonKind.Primary:
                    fill = !en ? Theme.Raised : down ? Theme.AccentPressed : hover ? Theme.AccentHover : Theme.Accent;
                    fore = en ? Theme.OnAccent : Theme.Faint;
                    break;
                case ButtonKind.Segment:
                    if (active && en)
                    {
                        fill = Theme.Mix(Theme.Raised, Theme.Accent, hover ? 0.30f : 0.22f);
                        fore = Theme.AccentHover;
                        border = Theme.Mix(Theme.Raised, Theme.Accent, 0.6f);
                    }
                    else
                    {
                        fill = !en ? Theme.Mix(Theme.Surface, Theme.Raised, 0.5f) : down ? Theme.Border : hover ? Theme.RaisedHover : Theme.Raised;
                        fore = en ? Theme.Text : Theme.Faint;
                    }
                    break;
                case ButtonKind.Ghost:
                    fill = en && (hover || down) ? Theme.Raised : Color.Transparent;
                    fore = !en ? Theme.Faint : hover ? Theme.Text : Theme.Muted;
                    border = Theme.Border;
                    break;
                default:
                    fill = !en ? Theme.Mix(Theme.Surface, Theme.Raised, 0.5f) : down ? Theme.Border : hover ? Theme.RaisedHover : Theme.Raised;
                    fore = en ? Theme.Text : Theme.Faint;
                    border = en ? Theme.Border : Color.Transparent;
                    break;
            }
            if (Focused && ShowFocusCues && en) border = Theme.Accent;
            Theme.Box(e.Graphics, this, Theme.BackOf(this), fill, border, Theme.S(7));
            var area = ClientRectangle;
            if (Globe)
            {
                // centred together with the text
                int tw = TextRenderer.MeasureText(Text, Font).Width;
                int d = Theme.S(13), x = Math.Max(Theme.S(8), (Width - tw - GlobeSpace) / 2), y = (Height - d) / 2;
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var pen = new Pen(fore, Math.Max(1f, Theme.Scale)))
                {
                    g.DrawEllipse(pen, x, y, d, d);
                    g.DrawEllipse(pen, x + d * 0.28f, y, d * 0.44f, d);
                    g.DrawLine(pen, x, y + d / 2f, x + d, y + d / 2f);
                }
                area = new Rectangle(x + GlobeSpace, 0, Width - x - GlobeSpace, Height);
                TextRenderer.DrawText(e.Graphics, Text, Font, area, fore, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                return;
            }
            TextRenderer.DrawText(e.Graphics, Text, Font, area, fore,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    /// <summary>Rounded panel with a thin border.</summary>
    class Card : Panel
    {
        public Card()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Surface;
            ForeColor = Theme.Text;
            Padding = new Padding(Theme.S(18), Theme.S(16), Theme.S(18), Theme.S(18));
        }

        protected override void OnPaintBackground(PaintEventArgs e) =>
            Theme.Box(e.Graphics, this, Theme.BackOf(this), Theme.Surface, Theme.Border, Theme.S(12));
    }

    /// <summary>A borderless text box or number box inside a rounded field that lights up when focused.</summary>
    sealed class InputBox : Panel
    {
        public readonly Control Inner;
        bool focused;

        public InputBox(Control inner)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Raised;
            Height = Theme.S(38);
            Padding = new Padding(Theme.S(11), 0, Theme.S(8), 0);
            Cursor = Cursors.IBeam;
            Inner = inner;
            inner.BackColor = Theme.Raised;
            inner.ForeColor = Theme.Text;
            inner.Font = Theme.Ui(10f);
            if (inner is TextBox tb) tb.BorderStyle = BorderStyle.None;
            if (inner is NumericUpDown nud)
            {
                nud.BorderStyle = BorderStyle.None;
                // the arrows are hidden (wheel and arrow keys still work)
                foreach (Control c in nud.Controls) if (!(c is TextBoxBase) && c.GetType().Name.IndexOf("Edit", StringComparison.Ordinal) < 0 && c.GetType().Name.IndexOf("TextBox", StringComparison.Ordinal) < 0) c.Visible = false;
            }
            Controls.Add(inner);
            inner.GotFocus += (s, e) => { focused = true; Invalidate(); };
            inner.LostFocus += (s, e) => { focused = false; Invalidate(); };
            Click += (s, e) => inner.Focus();
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (Inner == null) return;
            int h = Inner.PreferredSize.Height;
            if (h < Inner.Font.Height) h = Inner.Font.Height + Theme.S(4);
            Inner.SetBounds(Padding.Left, Math.Max(0, (Height - h) / 2), Math.Max(10, Width - Padding.Horizontal), h);
        }

        protected override void OnPaintBackground(PaintEventArgs e) =>
            Theme.Box(e.Graphics, this, Theme.BackOf(this), Theme.Raised, focused ? Theme.Accent : Theme.Border, Theme.S(7));
    }

    /// <summary>Dashboard tile: a title, a big value and a detail line.</summary>
    sealed class StatTile : Control
    {
        readonly string title;
        string value = "—", detail = "";
        Color dot = Theme.Faint, valueColor = Theme.Text;
        readonly Font titleFont = Theme.Semibold(8f), valueFont = Theme.Semibold(16f), detailFont = Theme.Ui(8.5f);

        public StatTile(string title)
        {
            this.title = title.ToUpperInvariant();
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        public void Set(string value, string detail, Color dot, bool colorValue = false)
        {
            var vc = colorValue ? dot : Theme.Text;
            if (value == this.value && detail == this.detail && dot == this.dot && vc == valueColor) return;
            this.value = value; this.detail = detail; this.dot = dot; valueColor = vc;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            Theme.Box(g, this, Theme.BackOf(this), Theme.Surface, Theme.Border, Theme.S(12));
            int x = Theme.S(16), w = Width - x - Theme.S(12);
            int d = Theme.S(8);
            using (var b = new SolidBrush(dot)) g.FillEllipse(b, x, Theme.S(17), d, d);
            var flags = TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            TextRenderer.DrawText(g, title, titleFont, new Rectangle(x + d + Theme.S(8), Theme.S(12), w - d - Theme.S(8), Theme.S(18)), Theme.Muted, flags | TextFormatFlags.VerticalCenter);
            TextRenderer.DrawText(g, value, valueFont, new Rectangle(x, Theme.S(34), w, Theme.S(32)), valueColor, flags);
            TextRenderer.DrawText(g, detail, detailFont, new Rectangle(x, Height - Theme.S(28), w, Theme.S(18)), Theme.Faint, flags);
        }
    }

    /// <summary>Top bar: logo, title, role and version badges.</summary>
    sealed class HeaderBar : Control
    {
        readonly string subtitle, version;
        readonly Control tool;
        string role = ""; Color roleColor = Theme.Faint;
        readonly Font titleFont = Theme.Semibold(15f), subFont = Theme.Ui(9f), badgeFont = Theme.Semibold(8f), logoFont = Theme.Semibold(11f);

        public HeaderBar(string subtitle, string version, Control tool = null)
        {
            this.subtitle = subtitle; this.version = version; this.tool = tool;
            if (tool != null) Controls.Add(tool);
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Height = Theme.S(76);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (tool is ModernButton b) b.Fit(24);
            if (tool != null) tool.Location = new Point(Width - Theme.S(22) - tool.Width, (Height - tool.Height) / 2);
        }

        public void SetRole(string text, Color color)
        {
            if (text == role && color == roleColor) return;
            role = text; roleColor = color; Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Theme.Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int pad = Theme.S(22), logo = Theme.S(42);
            var lr = new Rectangle(pad, (Height - logo) / 2, logo, logo);
            using (var path = Theme.Round(lr, Theme.S(11)))
            using (var b = new LinearGradientBrush(lr, Theme.AccentHover, Theme.AccentPressed, 45f))
                g.FillPath(b, path);
            TextRenderer.DrawText(g, "MP", logoFont, lr, Theme.OnAccent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

            int tx = lr.Right + Theme.S(14);
            var flags = TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;
            TextRenderer.DrawText(g, "MPFever", titleFont, new Point(tx, Height / 2 - Theme.S(23)), Theme.Text, flags);
            TextRenderer.DrawText(g, subtitle, subFont, new Point(tx + Theme.S(1), Height / 2 + Theme.S(4)), Theme.Muted, flags);

            int right = tool != null ? tool.Left - Theme.S(10) : Width - pad;
            right = Badge(g, version, right, Theme.Muted, Theme.Raised, Theme.Border) - Theme.S(8);
            if (role != "") Badge(g, role, right, roleColor, Theme.Mix(Theme.Bg, roleColor, 0.14f), Theme.Mix(Theme.Bg, roleColor, 0.45f));

            using (var pen = new Pen(Theme.Border)) g.DrawLine(pen, 0, Height - 1, Width, Height - 1);
        }

        /// <summary>Pill ending at <paramref name="right"/>; returns its left edge.</summary>
        int Badge(Graphics g, string text, int right, Color fore, Color fill, Color border)
        {
            var size = TextRenderer.MeasureText(text, badgeFont, Size.Empty, TextFormatFlags.NoPadding);
            int h = Theme.S(26), w = size.Width + Theme.S(22);
            var r = new Rectangle(right - w, (Height - h) / 2, w, h);
            using (var path = Theme.Round(r, h / 2f))
            {
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                using (var pen = new Pen(border)) g.DrawPath(pen, path);
            }
            TextRenderer.DrawText(g, text, badgeFont, r, fore, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            return r.Left;
        }
    }

    /// <summary>Layout helpers.</summary>
    static class Ui
    {
        /// <summary>Docks the controls at the top of <paramref name="parent"/>, in the order given.</summary>
        public static void StackTop(Control parent, params Control[] items)
        {
            for (int i = items.Length - 1; i >= 0; i--) { items[i].Dock = DockStyle.Top; parent.Controls.Add(items[i]); }
        }

        public static Control Gap(int px) => new Panel { Height = Theme.S(px) };

        public static Label Caption(string text) => new Label
        {
            Text = text.ToUpperInvariant(), AutoSize = false, Height = Theme.S(26),
            Font = Theme.Semibold(8f), ForeColor = Theme.Muted, TextAlign = ContentAlignment.TopLeft,
        };

        /// <summary>A label above an input.</summary>
        public static Control Field(string label, Control input)
        {
            var p = new Panel { Height = Theme.S(62) };
            var box = new InputBox(input) { Height = Theme.S(38) };
            var l = new Label { Text = label, AutoSize = false, Height = Theme.S(22), ForeColor = Theme.Muted, Font = Theme.Ui(9f) };
            StackTop(p, l, box);
            l.Click += (s, e) => input.Focus();
            return p;
        }

        /// <summary>Sets the height of a card from its docked content.</summary>
        public static void FitHeight(Card c)
        {
            int h = c.Padding.Vertical;
            foreach (Control x in c.Controls) if (x.Dock == DockStyle.Top) h += x.Height;
            c.Height = h;
        }
    }

    /// <summary>Dark look for context menus.</summary>
    sealed class DarkMenuRenderer : ToolStripProfessionalRenderer
    {
        public DarkMenuRenderer() : base(new Colors()) { RoundedEdges = false; }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using (var b = new SolidBrush(Theme.Raised)) e.Graphics.FillRectangle(b, e.AffectedBounds);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e)
        {
            using (var b = new SolidBrush(Theme.Raised)) e.Graphics.FillRectangle(b, e.AffectedBounds);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = e.Item.Enabled ? Theme.Text : Theme.Faint;
            base.OnRenderItemText(e);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = e.ImageRectangle;
            using (var pen = new Pen(Theme.Accent, 2f * Theme.Scale))
                g.DrawLines(pen, new[] {
                    new PointF(r.Left + r.Width * 0.2f, r.Top + r.Height * 0.55f),
                    new PointF(r.Left + r.Width * 0.42f, r.Top + r.Height * 0.75f),
                    new PointF(r.Left + r.Width * 0.8f, r.Top + r.Height * 0.3f) });
        }

        sealed class Colors : ProfessionalColorTable
        {
            public override Color ToolStripDropDownBackground => Theme.Raised;
            public override Color MenuBorder => Theme.Border;
            public override Color MenuItemBorder => Theme.RaisedHover;
            public override Color MenuItemSelected => Theme.RaisedHover;
            public override Color MenuItemSelectedGradientBegin => Theme.RaisedHover;
            public override Color MenuItemSelectedGradientEnd => Theme.RaisedHover;
            public override Color ImageMarginGradientBegin => Theme.Raised;
            public override Color ImageMarginGradientMiddle => Theme.Raised;
            public override Color ImageMarginGradientEnd => Theme.Raised;
            public override Color CheckBackground => Theme.Raised;
            public override Color CheckSelectedBackground => Theme.RaisedHover;
            public override Color CheckPressedBackground => Theme.RaisedHover;
            public override Color SeparatorDark => Theme.Border;
            public override Color SeparatorLight => Theme.Raised;
        }
    }
}
