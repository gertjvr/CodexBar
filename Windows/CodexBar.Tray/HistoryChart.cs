using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace CodexBar.Tray;

internal sealed class HistoryChart : StackPanel
{
    private readonly Canvas plot = new();
    private readonly TextBlock detail = Theme.Text("Hover a bar for details", 12, muted: true);
    private readonly TextBlock services = Theme.Text(" ", 12, muted: true);
    private readonly List<(string Day, double Value, List<(string Service, double Value)> Segments)> days = [];
    private readonly bool compact;
    private readonly string accent;
    private static readonly string[] Colors = ["398FF5", "76C25E", "F4C34B", "39BBD0", "C46BDD"];
    private readonly List<string> names = [];
    public HistoryChart(JsonElement source, bool cost, bool compact = false, string accent = "49A7B6")
    {
        this.compact = compact; this.accent = accent;
        foreach (var day in source.ValueKind == JsonValueKind.Array ? source.EnumerateArray().ToArray() : [])
        {
            var segments = day.Rows("services").Select(s => (s.Text("service"), s.Number("creditsUsed") ?? 0)).ToList();
            foreach (var (name, _) in segments) if (!names.Contains(name)) names.Add(name);
            days.Add((day.Text(cost ? "date" : "day"), day.Number(cost ? "totalCost" : "totalCreditsUsed") ?? 0, segments));
        }
        plot.Height = compact ? 64 : 138; plot.Background = Theme.Brush("00000000");
        Children.Add(plot);
        plot.SizeChanged += (_, _) => Draw(-1);
        plot.PointerMoved += (_, e) => { if (days.Count > 0) Draw(Math.Clamp((int)(e.GetCurrentPoint(plot).Position.X / Math.Max(1, plot.ActualWidth) * days.Count), 0, days.Count - 1)); };
        plot.PointerExited += (_, _) => Draw(-1);
        if (!compact)
        {
            Children.Add(Theme.Pair(Theme.Text(DayLabel(days.FirstOrDefault().Day), 11, muted: true), Theme.Text(DayLabel(days.LastOrDefault().Day), 11, muted: true), 4));
            detail.Margin = new(0, 16, 0, 0); Children.Add(detail); Children.Add(services);
            var legend = new Grid { Margin = new(0, 14, 0, 0), ColumnSpacing = 20, RowSpacing = 9 };
            legend.ColumnDefinitions.Add(new()); legend.ColumnDefinitions.Add(new());
            for (var i = 0; i < names.Count; i++)
            {
                if (i % 2 == 0) legend.RowDefinitions.Add(new() { Height = GridLength.Auto });
                var entry = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
                entry.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Theme.Brush(Colors[i % Colors.Length]), VerticalAlignment = VerticalAlignment.Center });
                entry.Children.Add(Theme.Text(names[i], 12, true, true)); Grid.SetRow(entry, i / 2); Grid.SetColumn(entry, i % 2); legend.Children.Add(entry);
            }
            Children.Add(legend);
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, cost ? "Daily cost history" : "Usage breakdown by day and service");
    }
    private static string DayLabel(string? day) => DateOnly.TryParse(day, out var date) ? date.ToString("d MMM") : day ?? "";
    private void Draw(int selected)
    {
        plot.Children.Clear(); if (days.Count == 0) return;
        var width = Math.Max(1, plot.ActualWidth) / days.Count;
        var max = Math.Max(1, days.Max(d => d.Value));
        for (var i = 0; i < days.Count; i++)
        {
            if (i == selected) Add(i * width, 0, width, plot.Height, "30495C");
            var y = plot.Height;
            if (!compact && days[i].Segments.Count > 0)
            {
                foreach (var (name, value) in days[i].Segments)
                { var h = Math.Max(0, value / max * plot.Height); y -= h; Add(i * width, y, width * .72, h, Colors[names.IndexOf(name) % Colors.Length]); }
            }
            else { var h = Math.Max(0, days[i].Value / max * plot.Height); Add(i * width, plot.Height - h, width * .72, h, accent); }
        }
        detail.Text = selected < 0 ? "Hover a bar for details" : $"{DayLabel(days[selected].Day)}: {days[selected].Value:N2}";
        if (compact) ToolTipService.SetToolTip(plot, selected < 0 ? "Daily costs" : detail.Text);
        services.Text = selected < 0 ? " " : string.Join(" · ", days[selected].Segments.Select(s => $"{s.Service} {s.Value:N2}"));
    }
    private void Add(double x, double y, double width, double height, string color)
    {
        var bar = new Rectangle { Width = Math.Max(0, width), Height = Math.Max(0, height), RadiusX = 1.5, RadiusY = 1.5, Fill = Theme.Brush(color) };
        Canvas.SetLeft(bar, x); Canvas.SetTop(bar, y); plot.Children.Add(bar);
    }
}
