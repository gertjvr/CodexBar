using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using Windows.System;

namespace CodexBar.Tray;

internal sealed class MenuWindow : Window
{
    private JsonElement snapshot;
    private NativeTray? tray;
    private NotificationDelivery? notifications;
    private readonly NotificationPolicy notificationPolicy = new();
    private bool active = true, popupOpen;
    private readonly Preferences preferences = Preferences.Load();
    private string selected = "codex";
    private readonly string? cli;
    private readonly bool fixture;
    private bool refreshing;
    private string? refreshError;
    private readonly StackPanel body = new() { Spacing = 0 };
    private readonly Border surface;
    private readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromMinutes(2) };
    private DateTimeOffset Now => fixture && DateTimeOffset.TryParse(snapshot.Text("generatedAt"), out var date) ? date : DateTimeOffset.Now;
    public MenuWindow(string[] args)
    {
        Title = "CodexBar";
        fixture = args.Contains("--fixture");
        if (!fixture)
        {
            var i = Array.IndexOf(args, "--cli");
            cli = i >= 0 ? args.ElementAtOrDefault(i + 1) ?? throw new ArgumentException("Missing companion CLI path.") : Path.Combine(AppContext.BaseDirectory, "CLI", "codexbar.exe");
        }
        SystemBackdrop = new DesktopAcrylicBackdrop();
        var scroll = new ScrollViewer { IsTabStop = false, Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new(12, 2, 12, 8) };
        surface = new Border { Background = Theme.Brush("D9091B24"), BorderBrush = Theme.Brush("647984"), BorderThickness = new(1), CornerRadius = new(12), Child = scroll, RequestedTheme = ElementTheme.Dark };
        surface.KeyDown += (_, e) => { if (e.Key == VirtualKey.Escape && !popupOpen) { AppWindow.Hide(); e.Handled = true; } };
        body.Children.Add(Theme.Text("Loading usage…", 14, true));
        Content = surface;
        var presenter = (OverlappedPresenter)AppWindow.Presenter;
        presenter.SetBorderAndTitleBar(false, false); presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
        AppWindow.IsShownInSwitchers = false;
        Activated += (_, e) =>
        {
            active = e.WindowActivationState != WindowActivationState.Deactivated;
            if (!active && !popupOpen) AppWindow.Hide();
        };
        AppWindow.Resize(new SizeInt32(330, 940));
        AppWindow.Move(new PointInt32(650, 35));
        surface.Loaded += async (_, _) =>
        {
            tray ??= new NativeTray(this, async () => { Position(); AppWindow.Show(); Activate(); if (preferences.RefreshOnOpen) await Refresh(); });
            if (!fixture) notifications ??= new NotificationDelivery(this, () => { Position(); AppWindow.Show(); Activate(); });
            Position();
            await Refresh();
        };
        refreshTimer.Tick += async (_, _) => await Refresh();
        ApplyPreferences();
        Closed += (_, _) => { refreshTimer.Stop(); settingsWindow?.Close(); notifications?.Dispose(); Data.Shutdown.Cancel(); tray?.Dispose(); };
    }
    private void Position()
    {
        var scale = surface.XamlRoot.RasterizationScale;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        body.Measure(new Windows.Foundation.Size(284, double.PositiveInfinity));
        var height = Math.Min(Math.Max((int)((body.DesiredSize.Height + 16) * scale), (int)(130 * scale)), area.Height - 24);
        AppWindow.Resize(new SizeInt32((int)(310 * scale), height));
        AppWindow.Move(new PointInt32(area.X + area.Width - AppWindow.Size.Width - 18, area.Y + area.Height - height - 12));
    }
    private async Task Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        refreshError = null;
        try
        {
            var incoming = fixture ? JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "fixture.json"))).RootElement.Clone() : await CliSnapshot.Read(cli!, snapshot, partial => { snapshot = partial; Render(); }, preferences.HistoryDays, preferences.CheckStatus);
            snapshot = incoming; Render();
        }
        catch (Exception) { refreshError = "Refresh failed. Check the companion CLI installation and configuration."; if (snapshot.ValueKind != JsonValueKind.Object) { body.Children.Clear(); body.Children.Add(Theme.Text(refreshError, 12, muted: true)); } }
        finally { refreshing = false; if (snapshot.ValueKind == JsonValueKind.Object) Render(); }
    }
    private void Render()
    {
        if (!fixture && notifications != null)
            foreach (var alert in notificationPolicy.Observe(snapshot, preferences.Notifications, DateTimeOffset.Now)) notifications.Send(alert, preferences.Notifications);
        body.Children.Clear();
        var providers = snapshot.Rows("providers").ToArray();
        if (!providers.Any(p => p.Text("id") == selected) && selected != "overview") selected = providers.FirstOrDefault().Text("id");
        var tabs = new Grid { ColumnSpacing = 3, Margin = new(-4, 0, -4, 0) };
        var choices = new List<(string Id, string Name)> { ("overview", "Overview") };
        choices.AddRange(providers.Select(p => (p.Text("id"), p.Text("name"))));
        for (var i = 0; i < choices.Count; i++)
        {
            var choice = choices[i]; tabs.ColumnDefinitions.Add(new());
            var tabContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
            if (choice.Id == "overview") tabContent.Children.Add(new FontIcon { Glyph = "\uE80A", FontSize = 12 });
            else
            {
                var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", $"{choice.Id}-{(choice.Id == selected ? "selected" : "normal")}.png");
                if (File.Exists(iconPath)) tabContent.Children.Add(new Image { Source = new BitmapImage(new Uri(iconPath)), Width = 14, Height = 14 });
            }
            tabContent.Children.Add(Theme.Text(choice.Name, 12, true, choice.Id != selected));
            var tabLayout = new StackPanel { Spacing = 5 }; tabLayout.Children.Add(tabContent);
            var tabProvider = providers.FirstOrDefault(p => p.Text("id") == choice.Id);
            if (tabProvider.Rows("windows").FirstOrDefault().Number("remainingPercent") is double tabPercent)
                tabLayout.Children.Add(Meter(tabPercent, preferences.Accent(choice.Id)));
            var tab = new Button { Content = tabLayout, Padding = new(4, 8, 4, 8), HorizontalAlignment = HorizontalAlignment.Stretch, Background = choice.Id == selected ? Theme.Blue : Theme.Brush("00000000"), BorderThickness = new(0), CornerRadius = new(7) };
            tab.Click += (_, _) => { selected = choice.Id; Render(); }; Grid.SetColumn(tab, i); tabs.Children.Add(tab);
        }
        tabs.MinWidth = Math.Max(280, choices.Count * 85);
        body.Children.Add(new ScrollViewer { Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, IsTabStop = false }); body.Children.Add(Theme.Divider(7, 12));
        if (selected == "overview") foreach (var provider in providers) { Provider(provider); body.Children.Add(Theme.Divider()); }
        else { var provider = providers.FirstOrDefault(p => p.Text("id") == selected); if (provider.ValueKind == JsonValueKind.Object) Provider(provider); }
        body.Children.Add(Theme.Divider(10, 4));
        if (refreshError != null) body.Children.Add(Theme.Text(refreshError, 12, muted: true));
        if (refreshing) body.Children.Add(Theme.Text("Refreshing…", 11, muted: true));
        body.Children.Add(Theme.Action("Refresh", "\uE72C", async () => await Refresh()));
        body.Children.Add(Theme.Action("Settings…", "\uE713", Settings));
        body.Children.Add(Theme.Action("About CodexBar", "\uE946", () => OpenSettings("About")));
        body.Children.Add(Theme.Action("Quit", "\uE8BB", () => Close()));
        Position();
    }
    private void Provider(JsonElement provider)
    {
        var cardStart = body.Children.Count;
        var identity = provider.Object("identity");
        var account = new Button { Content = Theme.Text((preferences.RedactIdentity ? "Account" : identity.Text("accountEmail")) + (identity.Text("accountEmail") != "" ? " ›" : ""), 12, true, true), Padding = new(0), Background = Theme.Brush("00000000"), BorderThickness = new(0), MaxWidth = 200 };
        account.Click += (_, _) => OpenSettings("provider:" + provider.Text("id"));
        account.Visibility = identity.Text("accountEmail") == "" ? Visibility.Collapsed : Visibility.Visible;
        var header = Theme.Pair(Theme.Text(provider.Text("name"), 14, true), account);
        body.Children.Add(header);
        body.Children.Add(Theme.Pair(Theme.Text(Updated(provider.Text("updatedAt")), 11, true, true), Theme.Text(Theme.Plan(provider.Text("id"), identity.Text("plan")), 11, true, true), 4));
        body.Children.Add(Theme.Divider(7, 13));
        var detail = provider.Object("presentation");
        foreach (var metric in provider.Rows("windows").Where(w => w.Object("idle").ValueKind != JsonValueKind.True && preferences.Visible(provider.Text("id"), w.Text("kind"))))
        {
            var percent = metric.Number(preferences.ShowRemaining ? "remainingPercent" : "usedPercent");
            if (percent == null) continue;
            body.Children.Add(Theme.Text($"{metric.Text("label")} {percent:0}% {(preferences.ShowRemaining ? "left" : "used")}", 14, true));
            var reset = Data.Countdown(metric.Text("resetAt"), Now);
            if (reset != "") { var text = Theme.Text(preferences.ResetAsDate && DateTimeOffset.TryParse(metric.Text("resetAt"), out var resetAt) ? "Resets " + resetAt.LocalDateTime.ToString("g") : "Resets in " + reset, 11, true, true); text.HorizontalAlignment = HorizontalAlignment.Right; text.Margin = new(0, 3, 0, 3); body.Children.Add(text); }
            var pace = preferences.ShowPace ? detail.Object("pace").Object(metric.Text("kind")) : default;
            body.Children.Add(Meter(percent.Value, preferences.Accent(provider.Text("id")), pace.Number("expectedUsedPercent"), preferences.ShowRemaining, preferences.ShowWarningMarkers && provider.Text("id") is "codex" or "claude" ? preferences.Notifications.Thresholds(provider.Text("id"), metric.Text("kind") == "primary" ? "primary" : "secondary") : []));
            if (pace.Text("summary") != "") { var text = Theme.Text(string.Join(" · ", pace.Text("summary").Split('|').Select(part => part.Trim()).Where(part => !part.StartsWith("Expected ", StringComparison.Ordinal))), 11, true, true); text.Margin = new(0, 5, 0, 0); body.Children.Add(text); }
            body.Children.Add(new Border { Height = 14 });
        }
        if (preferences.ShowCredits && preferences.Visible(provider.Text("id"), "codeReview") && detail.Number("codeReviewRemainingPercent") is double codeReview)
        { body.Children.Add(Theme.Text($"Code review {(preferences.ShowRemaining ? codeReview : 100 - codeReview):0}% {(preferences.ShowRemaining ? "left" : "used")}", 14, true)); body.Children.Add(Meter(preferences.ShowRemaining ? codeReview : 100 - codeReview, preferences.Accent(provider.Text("id")))); body.Children.Add(new Border { Height = 12 }); }
        var resetCredits = detail.Rows("resetCreditExpiries").ToArray();
        if (preferences.ShowCredits && preferences.Visible(provider.Text("id"), "resetCredits") && resetCredits.Length > 0)
        {
            body.Children.Add(Theme.Divider(0, 12)); body.Children.Add(Theme.Text("Limit Reset Credits", 14, true));
            var dates = resetCredits.Select(v => v.ValueKind == JsonValueKind.String ? Data.Countdown(v.GetString()!, Now) : "No expiry");
            body.Children.Add(Theme.Pair(Theme.Text($"{resetCredits.Length} available", 12, true), Theme.Text("◷ " + string.Join(" · ", dates), 11, true, true), 4));
        }
        var cost = provider.Object("cost");
        if (preferences.ShowCosts && cost.ValueKind == JsonValueKind.Object)
        {
            var history = cost.Object("history");
            var summary = new Grid { Margin = new(0, 14, 0, 10), ColumnSpacing = 24 };
            summary.ColumnDefinitions.Add(new()); summary.ColumnDefinitions.Add(new());
            var left = new StackPanel(); left.Children.Add(Theme.Text("Today", 11, true, true)); left.Children.Add(Theme.Text(Data.Money(cost.Number("todayUSD")), 15, true)); left.Children.Add(Theme.Text("Latest tokens", 11, true, true)); left.Children.Add(Theme.Text(Data.Tokens(history.Number("sessionTokens")), 13, true));
            var right = new StackPanel(); right.Children.Add(Theme.Text($"{cost.Number("historyDays") ?? 30:0}d", 11, true, true)); right.Children.Add(Theme.Text(Data.Money(cost.Number("last30DaysUSD")), 15, true)); right.Children.Add(Theme.Text($"{cost.Number("historyDays") ?? 30:0}d tokens", 11, true, true)); right.Children.Add(Theme.Text(Data.Tokens(history.Number("last30DaysTokens")), 13, true));
            summary.Children.Add(left); Grid.SetColumn(right, 1); summary.Children.Add(right); body.Children.Add(summary);
            if (history.Rows("daily").Any())
            {
                var chart = new HistoryChart(JsonSerializer.SerializeToElement(CostHistory.Calendar(cost, Now)), true, true, preferences.Accent(provider.Text("id"))); body.Children.Add(chart);
                var models = history.Rows("daily").SelectMany(d => d.Rows("modelsUsed")).Where(m => m.ValueKind == JsonValueKind.String).Select(m => m.GetString()).Distinct();
                var top = history.Rows("daily").SelectMany(d => d.Rows("modelBreakdowns")).GroupBy(m => m.Text("modelName")).OrderByDescending(g => g.Sum(m => m.Number("cost") ?? 0)).FirstOrDefault()?.Key;
                body.Children.Add(Theme.Text(top != null ? "Top model: " + top : "Models: " + string.Join(", ", models.Take(3)), 11, true, true));
                body.Children.Add(Theme.Text("Estimated from token usage · not a subscription bill", 11, true, true));
            }
        }
        if (DateTimeOffset.TryParse(detail.Text("subscriptionRenewsAt"), out var renewal)) { var renew = Theme.Text($"Renews: {renewal:dd MMM yyyy}", 11, true, true); renew.Margin = new(0, 12, 0, 0); body.Children.Add(renew); }
        var breakdown = detail.Object("usageBreakdown");
        var hasPlanUsage = breakdown.ValueKind == JsonValueKind.Array && breakdown.GetArrayLength() > 0;
        var hasCostHistory = preferences.ShowCosts && cost.Object("history").Rows("daily").Any();
        if (hasPlanUsage || hasCostHistory)
        {
            var content = new StackPanel();
            while (body.Children.Count > cardStart)
            {
                var child = body.Children[cardStart]; body.Children.RemoveAt(cardStart); content.Children.Add(child);
            }
            var card = new ProviderCard(content, provider.Text("name"));
            AttachSubmenu(card, () =>
            {
                if (hasPlanUsage) ShowChart(card, breakdown, false);
                else OpenFlyout(new CostFlyout(cost, preferences, provider.Text("id"), Now), card);
            });
            body.Children.Add(card);
        }
        if (preferences.ShowCredits && preferences.Visible(provider.Text("id"), "credits") && provider.Object("credits").Number("remaining") is double credits)
        {
            body.Children.Add(Theme.Divider(12, 12)); body.Children.Add(Theme.Text("Credits", 14, true));
            if (credits == 0) body.Children.Add(Meter(0));
            body.Children.Add(Theme.Text($"{credits:N0} left", 12));
            if (Uri.TryCreate(detail.Text("creditsPurchaseURL"), UriKind.Absolute, out var purchase) && purchase.Scheme == "https")
                body.Children.Add(Theme.Action("Buy Credits…", "\uE710", () => OpenUrl(purchase.AbsoluteUri)));
        }
        if (hasPlanUsage)
        {
            var usage = Theme.Action("Plan Usage", "", () => { }, true); AttachSubmenu(usage, () => ShowChart(usage, breakdown, false)); body.Children.Add(Theme.Divider()); body.Children.Add(usage);
        }
        if (preferences.ShowCosts && cost.Object("history").Rows("daily").Any())
        {
            var button = Theme.Action("Cost", "", () => { }, true); AttachSubmenu(button, () => OpenFlyout(new ScrollViewer { Content = new CostFlyout(cost, preferences, provider.Text("id"), Now), MaxHeight = Math.Max(240, DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea.Height / surface.XamlRoot.RasterizationScale - 80), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, button)); body.Children.Add(button);
        }
        foreach (var section in provider.Rows("details"))
        {
            body.Children.Add(Theme.Text(section.Text("title"), 14, true));
            foreach (var row in section.Rows("rows"))
                body.Children.Add(Theme.Pair(Theme.Text(row.Text("label"), 12), Theme.Text(row.Text("value") + " " + row.Text("secondaryValue"), 12, muted: true), 4));
        }
        if (provider.Text("costError") is { Length: > 0 } costError) body.Children.Add(Theme.Text(costError, 12, muted: true));
        if (provider.Object("error").Text("message") is { Length: > 0 } error) body.Children.Add(Theme.Text(error, 12, muted: true));
        body.Children.Add(Theme.Divider(10, 4));
        if (provider.Text("id") is "codex" or "claude")
            body.Children.Add(Theme.Action("Usage Dashboard", "", () => OpenUrl(provider.Text("id") == "codex" ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage"), icon: Theme.UsageDashboardIcon()));
        var statusButton = Theme.Action("Status Page", "\uE9D9", () => { }, true);
        AttachSubmenu(statusButton, () => OpenFlyout(StatusPanel(provider), statusButton));
        body.Children.Add(statusButton);
        var status = provider.Object("status");
        if (status.Text("label") is { Length: > 0 } statusLabel)
            body.Children.Add(Theme.Text(statusLabel + (status.Text("updatedAt") == "" ? "" : " · " + Updated(status.Text("updatedAt"))), 11, true, true));

    }
    private string Updated(string raw)
    {
        if (!DateTimeOffset.TryParse(raw, out var at)) return fixture ? "Preview data" : "Not refreshed";
        var age = Now - at;
        return age.TotalMinutes < 1 ? "Updated just now" : age.TotalHours < 1 ? $"Updated {(int)age.TotalMinutes}m ago" : $"Updated {at.LocalDateTime:g}";
    }
    private static Grid Meter(double percent, string accent = "49A7B6", double? expected = null, bool remaining = true, int[]? thresholds = null)
    {
        var grid = new Grid { Height = 6, Margin = new(0, 5, 0, 0), Background = Theme.Track, CornerRadius = new(3) };
        var fill = new Border { Tag = "UsageFill", Background = Theme.Brush(accent), CornerRadius = new(3), HorizontalAlignment = HorizontalAlignment.Left };
        grid.Children.Add(fill); grid.SizeChanged += (_, _) => fill.Width = grid.ActualWidth * Math.Clamp(percent / 100, 0, 1);
        if (expected.HasValue) { var tick = new Border { Width = 2, Background = Theme.Muted, HorizontalAlignment = HorizontalAlignment.Left }; grid.Children.Add(tick); grid.SizeChanged += (_, _) => tick.Margin = new(grid.ActualWidth * Math.Clamp(remaining ? 1 - expected.Value / 100 : expected.Value / 100, 0, 1), 0, 0, 0); }
        foreach (var threshold in thresholds ?? [])
        {
            var marker = new Border { Width = 2, Background = Theme.Brush(threshold == thresholds!.Min() ? "FF6262" : "B8C0C3"), HorizontalAlignment = HorizontalAlignment.Left };
            grid.Children.Add(marker); grid.SizeChanged += (_, _) => marker.Margin = new(grid.ActualWidth * (remaining ? threshold / 100.0 : 1 - threshold / 100.0), 0, 0, 0);
        }
        return grid;
    }
    private void ShowChart(FrameworkElement target, JsonElement daily, bool cost)
    {
        var panel = new StackPanel { Width = 276, Spacing = 8 };
        var rows = daily.ValueKind == JsonValueKind.Array ? daily.EnumerateArray().ToArray() : [];
        var today = rows.FirstOrDefault(d => d.Text(cost ? "date" : "day") == Now.ToString("yyyy-MM-dd")).Number(cost ? "totalCost" : "totalCreditsUsed") ?? 0;
        var total = rows.Sum(d => d.Number(cost ? "totalCost" : "totalCreditsUsed") ?? 0);
        panel.Children.Add(Theme.Pair(Theme.Text("Today\n" + (cost ? Data.Money(today) : $"{today:N2} credits"), 12, true), Theme.Text("Last 30 days\n" + (cost ? Data.Money(total) : $"{total:N2} credits"), 12, true)));
        panel.Children.Add(new HistoryChart(daily, cost));
        OpenFlyout(panel, target, FlyoutPlacementMode.Left);
    }
    private Style PopupStyle()
    {
        var style = new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Theme.Brush("F0091B24")));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Theme.Brush("647984")));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(12)));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(16)));
        style.Setters.Add(new Setter(FrameworkElement.MaxHeightProperty, Math.Min(720, Math.Max(160, DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea.Height / surface.XamlRoot.RasterizationScale - 48))));
        style.Setters.Add(new Setter(ScrollViewer.VerticalScrollModeProperty, ScrollMode.Enabled));
        style.Setters.Add(new Setter(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto));
        return style;
    }
    private void ShowInfo(string title, string message)
    {
        var panel = new StackPanel { Width = 250, Spacing = 10 }; panel.Children.Add(Theme.Text(title, 15, true)); panel.Children.Add(Theme.Text(message, 12));
        OpenFlyout(panel, surface);
    }
    private bool openingFromHover;
    private int changingFlyouts;
    private readonly Dictionary<Flyout, (FrameworkElement Target, int Level, Flyout? Parent)> openFlyouts = new();
    private void AttachSubmenu(FrameworkElement button, Action show)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        timer.Tick += (_, _) => { timer.Stop(); openingFromHover = true; try { show(); } finally { openingFromHover = false; } };
        button.PointerEntered += (_, _) => { timer.Stop(); timer.Start(); };
        button.PointerExited += (_, _) => timer.Stop();
        button.Unloaded += (_, _) => timer.Stop();
        if (button is Button action) action.Click += (_, _) => { timer.Stop(); show(); };
        else button.Tapped += (_, args) =>
        {
            // Keep nested account/settings buttons independent of the summary action.
            for (var node = args.OriginalSource as DependencyObject; node != null && node != button; node = VisualTreeHelper.GetParent(node))
                if (node is Button) return;
            timer.Stop(); show(); args.Handled = true;
        };
        button.KeyDown += (_, args) =>
        {
            if (args.Key is Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Left || button is ProviderCard && args.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space)
            { timer.Stop(); show(); args.Handled = true; }
        };
    }
    private StackPanel StatusPanel(JsonElement provider)
    {
        var status = provider.Object("status");
        var panel = StatusComponents(status.Rows("components"));
        if (!status.Rows("components").Any()) panel.Children.Add(Theme.Text(status.Text("label", "Status details unavailable"), 13));
        var url = status.Text("url");
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme != "https")
            url = provider.Text("id") switch { "codex" => "https://status.openai.com/", "claude" => "https://status.claude.com/", _ => "" };
        if (url != "") { panel.Children.Add(Theme.Divider()); panel.Children.Add(Theme.Action("Open Status Page", "\uE9D9", () => OpenUrl(url))); }
        return panel;
    }
    private StackPanel StatusComponents(IEnumerable<JsonElement> components, int level = 0)
    {
        var panel = new StackPanel { Width = 310, Spacing = 4 };
        foreach (var component in components)
        {
            var children = component.Rows("children").ToArray();
            var label = component.Text("status") switch
            {
                "operational" => "Operational", "degraded_performance" => "Degraded performance",
                "partial_outage" => "Partial outage", "major_outage" or "full_outage" => "Major outage",
                "under_maintenance" => "Maintenance", _ => "Status unknown"
            };
            var dot = Theme.Text("●", 12);
            dot.Foreground = Theme.Brush(component.Text("indicator") switch { "none" => "2ECC71", "minor" => "F5C518", "major" or "critical" => "FF6262", "maintenance" => "49A3B0", _ => "98A4A9" });
            var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            name.Children.Add(dot); name.Children.Add(Theme.Text(component.Text("name") + (children.Length > 0 ? "  ›" : ""), 13, true));
            var row = new Button { Content = Theme.Pair(name, Theme.Text(label, 12, muted: true)), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = Theme.Brush("00000000"), BorderThickness = new(0), Padding = new(4, 6, 4, 6) };
            if (children.Length > 0) AttachSubmenu(row, () => OpenFlyout(StatusComponents(children, level + 1), row, level: level + 1));
            else row.IsTabStop = false;
            panel.Children.Add(row);
        }
        return panel;
    }
    private void OpenFlyout(UIElement content, FrameworkElement target, FlyoutPlacementMode placement = FlyoutPlacementMode.Left, int level = 0)
    {
        if (openingFromHover && openFlyouts.Values.Any(value => value.Target == target)) return;
        changingFlyouts++;
        try { foreach (var previous in openFlyouts.Where(item => item.Value.Level >= level).Select(item => item.Key).ToArray()) previous.Hide(); }
        finally { changingFlyouts--; }
        // FlyoutPresenter owns scrolling. A second viewport inside it can clip the last rows.
        if (content is ScrollViewer scroll) { content = (UIElement)scroll.Content; scroll.Content = null; }
        var flyout = new Flyout { Content = content, Placement = placement, ShouldConstrainToRootBounds = false, FlyoutPresenterStyle = PopupStyle(), OverlayInputPassThroughElement = surface, ShowMode = openingFromHover ? FlyoutShowMode.TransientWithDismissOnPointerMoveAway : FlyoutShowMode.Standard };
        flyout.Closed += (_, _) =>
        {
            if (target is ProviderCard closedCard) closedCard.SetSubmenuOpen(false);
            openFlyouts.Remove(flyout); popupOpen = openFlyouts.Count > 0;
            changingFlyouts++;
            try { foreach (var child in openFlyouts.Where(item => item.Value.Parent == flyout).Select(item => item.Key).ToArray()) child.Hide(); }
            finally { changingFlyouts--; }
            popupOpen = openFlyouts.Count > 0;
            if (!popupOpen && !active && changingFlyouts == 0) AppWindow.Hide();
        };
        var parent = openFlyouts.FirstOrDefault(item => item.Value.Level == level - 1).Key;
        openFlyouts.Add(flyout, (target, level, parent)); popupOpen = true;
        if (target is ProviderCard openedCard) openedCard.SetSubmenuOpen(true);
        flyout.ShowAt(target);
    }
    private SettingsWindow? settingsWindow;
    private void Settings() => OpenSettings(null);
    private void OpenSettings(string? page)
    {
        settingsWindow ??= CreateSettings();
        if (page != null) settingsWindow.Navigate(page);
        settingsWindow.Activate();
        AppWindow.Hide();
    }
    private SettingsWindow CreateSettings()
    {
        var window = new SettingsWindow(preferences, ApplyPreferences, () => snapshot, Refresh, fixture ? null : cli, Close, () => notifications?.Status ?? "Notifications are disabled in the synthetic preview.",
            () => notifications?.Send(new QuotaAlert("test", "CodexBar test notification", "Quota warnings and pace alerts will appear here.", true), preferences.Notifications) ?? "Use the installed live build to test Windows notifications.");
        window.Closed += (_, _) => settingsWindow = null;
        return window;
    }
    private void ApplyPreferences()
    {
        refreshTimer.Stop();
        if (!fixture && preferences.RefreshMinutes > 0)
        {
            refreshTimer.Interval = TimeSpan.FromMinutes(Math.Clamp(preferences.RefreshMinutes, 1, 30));
            refreshTimer.Start();
        }
        if (snapshot.ValueKind == JsonValueKind.Object) Render();
    }
    internal static void OpenUrl(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "https")
            Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }
}
