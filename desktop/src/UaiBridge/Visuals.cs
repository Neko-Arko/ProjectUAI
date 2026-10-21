using System.Drawing.Drawing2D;
using System.ComponentModel;

namespace ProjectUai.Bridge;

internal static class Palette
{
    public static readonly Color Canvas = Color.FromArgb(247, 248, 244);
    public static readonly Color Ink = Color.FromArgb(25, 43, 35);
    public static readonly Color Muted = Color.FromArgb(99, 115, 104);
    public static readonly Color Line = Color.FromArgb(222, 229, 219);
    public static readonly Color Accent = Color.FromArgb(210, 242, 164);
    public static readonly Color Dark = Color.FromArgb(23, 44, 35);
    public static readonly Color Green = Color.FromArgb(43, 103, 70);
    public static readonly Color DarkText = Color.FromArgb(207, 222, 210);
    public static readonly Color DarkMuted = Color.FromArgb(161, 187, 164);
    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90); path.CloseFigure();
        return path;
    }
}

internal sealed class DashboardScrollPanel : Panel
{
    // Resizing the dashboard changes its native canvas, including the scrollbar
    // ranges. Recalculate those ranges after the child layout has settled.
    public void RefreshExtent() => AdjustFormScrollbars(true);
}

internal sealed class SurfacePanel : Panel
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color Fill { get; set; } = Color.White;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color Border { get; set; } = Palette.Line;
    public SurfacePanel() { DoubleBuffered = true; BackColor = Palette.Canvas; }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = Palette.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 18 * DeviceDpi / 96f);
        using var fill = new SolidBrush(Fill); using var edge = new Pen(Border);
        e.Graphics.FillPath(fill, shape); e.Graphics.DrawPath(edge, shape);
    }
}

// The brand is drawn locally, so the native window needs no image downloads.
internal sealed class BrandMark : Control
{
    public BrandMark() { DoubleBuffered = true; BackColor = Palette.Canvas; AccessibleRole = AccessibleRole.Graphic; AccessibleName = "Project UAI"; }
    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float size = Math.Min(Width, Height), x = (Width - size) / 2f, y = (Height - size) / 2f;
        using var shape = Palette.Round(new RectangleF(x, y, size - 1, size - 1), size * 0.27f);
        using var fill = new SolidBrush(Palette.Dark); e.Graphics.FillPath(fill, shape);
        using var stroke = new Pen(Palette.Accent, size * 0.09f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        e.Graphics.DrawLines(stroke, new[] { new PointF(x + size * 0.29f, y + size * 0.36f), new PointF(x + size * 0.29f, y + size * 0.64f),
            new PointF(x + size * 0.50f, y + size * 0.64f), new PointF(x + size * 0.50f, y + size * 0.36f) });
        e.Graphics.DrawLine(stroke, x + size * 0.70f, y + size * 0.36f, x + size * 0.70f, y + size * 0.64f);
    }
}

// Keep CheckBox semantics for keyboard navigation and screen readers while
// drawing a generous native switch target. Space toggles it, just like a checkbox.
internal sealed class ToggleSwitch : CheckBox
{
    public ToggleSwitch()
    {
        AutoSize = false; Size = new Size(52, 32); Cursor = Cursors.Hand;
        AccessibleRole = AccessibleRole.CheckButton; BackColor = Color.White;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
    protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = DeviceDpi / 96f;
        float width = 42 * scale, height = 24 * scale, x = (Width - width) / 2, y = (Height - height) / 2;
        Color fill = Checked ? Palette.Green : Color.FromArgb(217, 224, 215);
        if (!Enabled) fill = Checked ? Color.FromArgb(128, 161, 130) : Palette.Line;
        using var track = Palette.Round(new RectangleF(x, y, width, height), height / 2);
        using var brush = new SolidBrush(fill); e.Graphics.FillPath(brush, track);
        float knob = 18 * scale, inset = 3 * scale;
        using var white = new SolidBrush(Color.White);
        e.Graphics.FillEllipse(white, Checked ? x + width - knob - inset : x + inset, y + inset, knob, knob);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -1, -1));
    }
}

internal sealed class StatusPill : Control
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Active { get; set; }
    public StatusPill() { DoubleBuffered = true; BackColor = Color.White; Font = new Font("Segoe UI", 8, FontStyle.Bold); AccessibleRole = AccessibleRole.StaticText; }
    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 2 || Height < 4) return;
        e.Graphics.Clear(BackColor); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = Palette.Round(new RectangleF(0, 1, Width - 1, Height - 3), 8 * DeviceDpi / 96f);
        using var brush = new SolidBrush(Active ? Color.FromArgb(231, 242, 220) : Color.FromArgb(241, 244, 237));
        e.Graphics.FillPath(brush, shape);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Active ? Palette.Green : Palette.Muted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

internal sealed class ActionButton : Button
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Primary { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool OnDark { get; set; }
    private bool hovering, pressed;
    public ActionButton()
    {
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand; UseVisualStyleBackColor = false; DoubleBuffered = true;
        Font = new Font("Segoe UI", 10, FontStyle.Bold);
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
    protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovering = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { pressed = e.Button == MouseButtons.Left; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) { pressed = true; Invalidate(); } base.OnKeyDown(e); }
    protected override void OnKeyUp(KeyEventArgs e) { pressed = false; Invalidate(); base.OnKeyUp(e); }
    protected override void OnLostFocus(EventArgs e) { pressed = false; Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { pressed = false; Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(BackColor);
        Color fill = Primary ? (OnDark ? Palette.Accent : Palette.Dark) : OnDark ? Color.FromArgb(42, 64, 52) : Color.FromArgb(241, 245, 237);
        if (hovering && Enabled) fill = ControlPaint.Light(fill, 0.12f);
        if (pressed && Enabled) fill = ControlPaint.Dark(fill, 0.05f);
        Color ink = Primary ? (OnDark ? Palette.Dark : Color.White) : OnDark ? Color.White : Palette.Ink;
        if (!Enabled) { fill = OnDark ? Color.FromArgb(37, 59, 52) : Color.FromArgb(239, 241, 237); ink = OnDark ? Color.FromArgb(138, 158, 148) : Palette.Muted; }
        using var shape = Palette.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 9 * DeviceDpi / 96f);
        using var brush = new SolidBrush(fill); e.Graphics.FillPath(brush, shape);
        if (!Primary && Enabled)
        {
            using var edge = new Pen(OnDark ? Color.FromArgb(67, 89, 72) : Palette.Line);
            e.Graphics.DrawPath(edge, shape);
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -5, -5), ink, fill);
    }
}

// A compact connection diagram, with the live status also supplied to readers.
internal sealed class ConnectionStrip : Control
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Running { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Connected { get; set; }
    public ConnectionStrip() { DoubleBuffered = true; BackColor = Palette.Dark; Font = new Font("Segoe UI", 8.5f); AccessibleRole = AccessibleRole.StaticText; }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Width < 3 || Height < 3) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = DeviceDpi / 96f, tile = Math.Min(88 * scale, Width / 3f - 10 * scale);
        if (tile <= 0) return;
        int[] centers = { (int)(tile / 2 + 1), Width / 2, (int)(Width - tile / 2 - 1) };
        using var line = new Pen(Color.FromArgb(67, 92, 72), 1.5f * scale);
        e.Graphics.DrawLine(line, centers[0], 26 * scale, centers[2], 26 * scale);
        string[] labels = { "Desktop", "Bridge", "Roblox" };
        string[] states = { "Ready", Running ? "Running" : "Stopped", Connected ? "Connected" : "Waiting" };
        for (int i = 0; i < 3; i++)
        {
            bool on = i == 0 || (i == 1 ? Running : Connected);
            using var shape = Palette.Round(new RectangleF(centers[i] - tile / 2, 1, tile, Math.Min(Height - 2, 87 * scale)), 12 * scale);
            using var fill = new SolidBrush(on ? Color.FromArgb(33, 56, 41) : Palette.Dark);
            using var edge = new Pen(on ? Color.FromArgb(80, 111, 71) : Color.FromArgb(53, 77, 59));
            e.Graphics.FillPath(fill, shape); e.Graphics.DrawPath(edge, shape);
            using var dot = new SolidBrush(on ? Palette.Accent : Color.FromArgb(104, 129, 109));
            e.Graphics.FillEllipse(dot, centers[i] - 4 * scale, 20 * scale, 8 * scale, 8 * scale);
            int left = (int)(centers[i] - tile / 2), width = (int)tile;
            TextRenderer.DrawText(e.Graphics, labels[i], Font, new Rectangle(left, (int)(38 * scale), width, (int)(20 * scale)),
                on ? Palette.DarkText : Palette.DarkMuted, TextFormatFlags.Top | TextFormatFlags.HorizontalCenter | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, states[i], Font, new Rectangle(left, (int)(60 * scale), width, (int)(20 * scale)),
                on ? Palette.Accent : Palette.DarkMuted, TextFormatFlags.Top | TextFormatFlags.HorizontalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}
