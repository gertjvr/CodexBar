using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Microsoft.UI.Text;

namespace CodexBar.Tray;

internal static class Theme
{
    public static SolidColorBrush Brush(string hex)
    {
        hex = hex.TrimStart('#');
        if (hex.Length == 6) hex = "FF" + hex;
        var value = Convert.ToUInt32(hex, 16);
        return new(Color.FromArgb((byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value));
    }
    public static readonly SolidColorBrush Foreground = Brush("D8DFE1"), Muted = Brush("9AA7AB"), Accent = Brush("49A7B6"), Track = Brush("203139"), Blue = Brush("087FFF");
    public static TextBlock Text(string text, double size = 13, bool bold = false, bool muted = false) => new()
    {
        Text = text,
        FontFamily = new("Segoe UI Variable Text"),
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = muted ? Muted : Foreground,
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center
    };
    // Display labels mirror CodexBarCore/Providers/Codex/CodexPlanFormatting.swift.
    public static string Plan(string provider, string raw) => provider == "codex" ? raw.Trim().ToLowerInvariant() switch
    {
        "pro" => "Pro 20x",
        "prolite" or "pro_lite" or "pro-lite" or "pro lite" => "Pro 5x",
        _ => raw
    } : raw;
    public static Border Divider(double top = 10, double bottom = 10) => new() { Height = 1, Background = Brush("394A51"), Margin = new(0, top, 0, bottom) };
    public static Grid Pair(FrameworkElement left, FrameworkElement right, double margin = 0)
    {
        var row = new Grid { Margin = new(0, margin, 0, 0), ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(left); Grid.SetColumn(right, 1); row.Children.Add(right); return row;
    }
    public static Canvas UsageDashboardIcon()
    {
        var icon = new Canvas { Width = 17, Height = 17, VerticalAlignment = VerticalAlignment.Center };
        icon.Children.Add(new Microsoft.UI.Xaml.Shapes.Polyline
        {
            Points = new() { new(2, 2), new(2, 15), new(16, 15) },
            Stroke = Foreground, StrokeThickness = 1.6
        });
        icon.Children.Add(new Microsoft.UI.Xaml.Shapes.Polyline
        {
            Points = new() { new(2, 11), new(6, 7), new(10, 9), new(15, 5) },
            Stroke = Foreground, StrokeThickness = 1.6
        });
        return icon;
    }
    public static Button Action(string label, string glyph, Action action, bool disclosure = false, FrameworkElement? icon = null)
    {
        var row = new Grid { ColumnSpacing = 9 };
        var hasIcon = icon != null || !string.IsNullOrEmpty(glyph);
        if (hasIcon) row.ColumnDefinitions.Add(new() { Width = new(17) });
        row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        if (hasIcon) row.Children.Add(icon ?? new FontIcon { Glyph = glyph, FontSize = 15, Foreground = Foreground });
        var title = Text(label, 14); Grid.SetColumn(title, hasIcon ? 1 : 0); row.Children.Add(title);
        if (disclosure) { var arrow = Text("›", 20); Grid.SetColumn(arrow, hasIcon ? 2 : 1); row.Children.Add(arrow); }
        var button = new Button { Content = row, Background = Brush("00000000"), BorderThickness = new(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new(4, 6, 4, 6), CornerRadius = new(4) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        button.Click += (_, _) => action(); return button;
    }
}
