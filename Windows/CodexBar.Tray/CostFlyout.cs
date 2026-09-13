using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;

namespace CodexBar.Tray;

internal sealed class CostFlyout : StackPanel
{
    private readonly JsonElement cost;
    private readonly JsonElement[] days;
    private readonly Preferences preferences;
    private readonly string accent;
    private readonly Canvas plot = new() { Height = 160, Background = Theme.Brush("00000000") };
    private readonly StackPanel detail = new() { Spacing = 6 };
    private readonly TextBlock scale = Theme.Text("", 11, true, true);
    private bool tokens = true;
    private int selected;
    public CostFlyout(JsonElement cost, Preferences preferences, string provider, DateTimeOffset now)
    {
        this.cost = cost; this.preferences = preferences; accent = preferences.Accent(provider);
        days = CostHistory.Calendar(cost, now);
        selected = days.Length - 1; Width = 292; Spacing = 12;
        var chart = new Grid { ColumnSpacing = 8 }; chart.ColumnDefinitions.Add(new() { Width = new(44) }); chart.ColumnDefinitions.Add(new());
        chart.Children.Add(scale); Grid.SetColumn(plot, 1); chart.Children.Add(plot); Children.Add(chart);
        Children.Add(Theme.Pair(Theme.Text(days.Length == 0 ? "" : Day(days[0]), 11, muted: true), Theme.Text(days.Length == 0 ? "" : Day(days[^1]), 11, muted: true)));
        var modes = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 4 };
        var token = new ToggleButton { Content = "Token", IsChecked = true, Width = 78 };
        var money = new ToggleButton { Content = "Cost", Width = 78 };
        token.Click += (_, _) => { tokens = true; token.IsChecked = true; money.IsChecked = false; Draw(); };
        money.Click += (_, _) => { tokens = false; money.IsChecked = true; token.IsChecked = false; Draw(); };
        modes.Children.Add(token); modes.Children.Add(money); Children.Add(modes); Children.Add(detail);
        Children.Add(Theme.Text($"Est. total (Last {cost.Number("historyDays") ?? 30:0} days): " + Money(cost.Number("last30DaysUSD")), 12, true, true));
        Children.Add(Theme.Text("Estimated from token usage · not a subscription bill", 11, true, true));
        var projects = cost.Rows("projects").ToArray();
        if (projects.Length > 0)
        {
            Children.Add(Theme.Text("Projects", 12, true, true));
            for (var i = 0; i < projects.Length; i++)
            {
                var project = projects[i]; Children.Add(ProjectRow(project, i + 1, false));
                var sources = project.Rows("sources").ToArray();
                for (var j = 0; j < Math.Min(3, sources.Length); j++) Children.Add(ProjectRow(sources[j], j + 1, true));
                if (sources.Length > 3)
                {
                    var rest = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
                    for (var j = 3; j < sources.Length; j++) rest.Children.Add(ProjectRow(sources[j], j + 1, true));
                    var more = new Button { Content = $"+ {sources.Length - 3} more", Margin = new(10, 0, 0, 0) };
                    more.Click += (_, _) => { rest.Visibility = rest.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible; more.Content = rest.Visibility == Visibility.Visible ? "Show fewer" : $"+ {sources.Length - 3} more"; };
                    Children.Add(more); Children.Add(rest);
                }
            }
        }
        var keyboard = new Button { Content = "Select day with ← / →", HorizontalAlignment = HorizontalAlignment.Stretch };
        keyboard.KeyDown += (_, e) =>
        {
            if (days.Length == 0 || e.Key is not (VirtualKey.Left or VirtualKey.Right or VirtualKey.Home or VirtualKey.End)) return;
            selected = e.Key == VirtualKey.Home ? 0 : e.Key == VirtualKey.End ? days.Length - 1 : Math.Clamp(selected + (e.Key == VirtualKey.Right ? 1 : -1), 0, days.Length - 1);
            Draw(); e.Handled = true;
        };
        Children.Add(keyboard);
        plot.SizeChanged += (_, _) => Draw();
        plot.PointerMoved += (_, e) => { if (days.Length > 0) { selected = Math.Clamp((int)(e.GetCurrentPoint(plot).Position.X / Math.Max(1, plot.ActualWidth) * days.Length), 0, days.Length - 1); Draw(); } };
        Draw();
    }
    private string Money(double? value) => value.HasValue ? (cost.Text("currencyCode", "USD") == "USD" ? "$" : cost.Text("currencyCode") + " ") + value.Value.ToString("N2") : "—";
    private static string Day(JsonElement day) => DateOnly.TryParse(day.Text("date"), out var value) ? value.ToString("d MMM") : day.Text("date");
    private UIElement ProjectRow(JsonElement item, int ordinal, bool source)
    {
        var row = new StackPanel { Margin = new(source ? 10 : 0, 2, 0, 0), Spacing = 2 };
        row.Children.Add(Theme.Pair(Theme.Text(preferences.RedactIdentity ? $"{(source ? "Source" : "Project")} {ordinal}" : item.Text("name"), 11, true, true), Theme.Text(Money(item.Number("totalCost")) + " · " + Data.Tokens(item.Number("totalTokens")) + " tokens", 11, true, true)));
        if (!preferences.RedactIdentity && item.Text("path") != "")
        {
            var path = Theme.Text(item.Text("path"), 10, muted: true); path.TextWrapping = TextWrapping.NoWrap; path.TextTrimming = TextTrimming.CharacterEllipsis;
            ToolTipService.SetToolTip(path, item.Text("path")); row.Children.Add(path);
        }
        return row;
    }
    private void Draw()
    {
        plot.Children.Clear(); detail.Children.Clear();
        if (days.Length == 0) { detail.Children.Add(Theme.Text("No cost history available", 12, muted: true)); return; }
        var key = tokens ? "totalTokens" : "totalCost";
        var maximum = days.Max(d => d.Number(key) ?? 0);
        scale.Text = (tokens ? Data.Tokens(maximum) : Money(maximum)) + "\n\n\n" + (tokens ? Data.Tokens(maximum / 2) : Money(maximum / 2)) + "\n\n\n0";
        var width = Math.Max(1, plot.ActualWidth) / days.Length;
        for (var i = 0; i < days.Length; i++)
        {
            var height = maximum > 0 ? Math.Clamp((days[i].Number(key) ?? 0) / maximum, 0, 1) * plot.Height : 0;
            var bar = new Rectangle { Width = width * .68, Height = height, RadiusX = 2, RadiusY = 2, Fill = Theme.Brush(accent) };
            Canvas.SetLeft(bar, i * width); Canvas.SetTop(bar, plot.Height - height); plot.Children.Add(bar);
            if (i == selected && height > 0)
            {
                var cap = new Rectangle { Width = width * .68, Height = Math.Min(5, height), Fill = Theme.Brush("FFE000"), RadiusX = 2, RadiusY = 2 };
                Canvas.SetLeft(cap, i * width); Canvas.SetTop(cap, plot.Height - height); plot.Children.Add(cap);
            }
        }
        var day = days[selected]; detail.Children.Add(Theme.Text($"{Day(day)}: {Money(day.Number("totalCost"))} · {Data.Tokens(day.Number("totalTokens"))} tokens", 12, true, true));
        foreach (var model in day.Rows("modelBreakdowns"))
        {
            var text = new StackPanel { Spacing = 3 }; text.Children.Add(Theme.Text(model.Text("modelName"), 12, true, true));
            text.Children.Add(Theme.Text((model.Number("cost") is double amount ? Money(amount) + " · " : "") + Data.Tokens(model.Number("totalTokens")), 11, true, true));
            detail.Children.Add(new Border { BorderBrush = Theme.Brush(accent), BorderThickness = new(2, 0, 0, 0), Padding = new(8, 0, 0, 0), Child = text });
        }
    }
}
