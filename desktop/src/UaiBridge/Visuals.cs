using System.Drawing.Drawing2D;
using System.ComponentModel;

namespace ProjectUai.Bridge;

internal static class Palette
{
    public static readonly Color Canvas = Color.FromArgb(245, 245, 240);
    public static readonly Color Ink = Color.FromArgb(31, 46, 42);
    public static readonly Color Muted = Color.FromArgb(105, 119, 112);
    public static readonly Color Line = Color.FromArgb(224, 230, 221);
    public static readonly Color Accent = Color.FromArgb(205, 239, 160);
    public static readonly Color Dark = Color.FromArgb(29, 53, 45);
    public static readonly Color Green = Color.FromArgb(50, 107, 72);
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
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = Palette.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 16 * DeviceDpi / 96f);
        using var fill = new SolidBrush(Fill); using var edge = new Pen(Border);
        e.Graphics.FillPath(fill, shape); e.Graphics.DrawPath(edge, shape);
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
        if (!Enabled) fill = Checked ? Color.FromArgb(151, 175, 151) : Palette.Line;
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
        e.Graphics.Clear(BackColor); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = Palette.Round(new RectangleF(0, 1, Width - 1, Height - 3), 8 * DeviceDpi / 96f);
        using var brush = new SolidBrush(Active ? Color.FromArgb(231, 242, 220) : Color.FromArgb(241, 243, 237));
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
    private bool hovering;
    public ActionButton()
    {
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand; UseVisualStyleBackColor = false; DoubleBuffered = true;
        Font = new Font("Segoe UI", 10, FontStyle.Bold);
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
    protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovering = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(BackColor);
        Color fill = Primary ? (OnDark ? Palette.Accent : Palette.Dark) : OnDark ? Color.FromArgb(42, 66, 59) : Color.FromArgb(242, 245, 240);
        if (hovering && Enabled) fill = ControlPaint.Light(fill, 0.12f);
        Color ink = Primary ? (OnDark ? Palette.Dark : Color.White) : OnDark ? Color.White : Palette.Ink;
        if (!Enabled) { fill = OnDark ? Color.FromArgb(37, 59, 52) : Color.FromArgb(239, 241, 237); ink = OnDark ? Color.FromArgb(138, 158, 148) : Palette.Muted; }
        using var shape = Palette.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 9 * DeviceDpi / 96f);
        using var brush = new SolidBrush(fill); e.Graphics.FillPath(brush, shape);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -5, -5), ink, fill);
    }
}

// A compact connection diagram, with text labels supplied as accessible content.
internal sealed class ConnectionStrip : Control
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Running { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Connected { get; set; }
    public ConnectionStrip() { DoubleBuffered = true; BackColor = Palette.Dark; AccessibleRole = AccessibleRole.StaticText; }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = DeviceDpi / 96f, y = 12 * scale;
        int[] centers = { (int)(Width * 0.12f), Width / 2, (int)(Width * 0.88f) };
        using var line = new Pen(Color.FromArgb(70, 99, 85), 1.5f * scale) { DashStyle = DashStyle.Dash };
        e.Graphics.DrawLine(line, centers[0], y, centers[2], y);
        for (int i = 0; i < 3; i++)
        {
            bool on = i == 0 || (i == 1 ? Running : Connected);
            using var dot = new SolidBrush(on ? Palette.Accent : Color.FromArgb(77, 103, 90));
            using var halo = new SolidBrush(Palette.Dark);
            e.Graphics.FillEllipse(halo, centers[i] - 11 * scale, y - 11 * scale, 22 * scale, 22 * scale);
            e.Graphics.FillEllipse(dot, centers[i] - 5 * scale, y - 5 * scale, 10 * scale, 10 * scale);
            string text = new[] { "Desktop", "Bridge", "Roblox" }[i];
            TextRenderer.DrawText(e.Graphics, text, Font, new Rectangle(centers[i] - (int)(48 * scale), (int)(29 * scale), (int)(96 * scale), Height - (int)(29 * scale)),
                on ? Color.FromArgb(222, 237, 228) : Color.FromArgb(151, 173, 159), TextFormatFlags.Top | TextFormatFlags.HorizontalCenter);
        }
    }
}
