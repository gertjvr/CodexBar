using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using Windows.Graphics;

namespace CodexBar.Tray;

internal sealed class SettingsWindow : Window
{
    private readonly Preferences preferences;
    private readonly Action changed;
    private readonly Func<JsonElement> snapshot;
    private readonly Func<Task> refresh;
    private readonly string? cli;
    private readonly Func<string> notificationStatus, testNotification;
    private readonly StackPanel pages = new() { Spacing = 4 };
    private readonly StackPanel detail = new() { Spacing = 16, MaxWidth = 780, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox search = new() { PlaceholderText = "Search providers", Margin = new(12) };
    private readonly TextBlock error = Theme.Text("", 12);
    private JsonElement[] catalog = [];
    private string selected;
    private bool closed;
    public SettingsWindow(Preferences preferences, Action changed, Func<JsonElement> snapshot, Func<Task> refresh, string? cli, Action quit, Func<string> notificationStatus, Func<string> testNotification)
    {
        this.preferences = preferences; this.changed = changed; this.snapshot = snapshot; this.refresh = refresh; this.cli = cli; this.notificationStatus = notificationStatus; this.testNotification = testNotification;
        selected = preferences.SettingsPage;
        SystemBackdrop = new MicaBackdrop();
        AppWindow.TitleBar.PreferredTheme = TitleBarTheme.Dark;
        var root = new Grid { RequestedTheme = ElementTheme.Dark, Background = Theme.Brush("292D2F") };
        root.ColumnDefinitions.Add(new() { Width = new(240) }); root.ColumnDefinitions.Add(new());
        var sidebar = new Grid { Background = Theme.Brush("243038") };
        sidebar.RowDefinitions.Add(new() { Height = GridLength.Auto }); sidebar.RowDefinitions.Add(new());
        sidebar.Children.Add(search);
        var list = new ScrollViewer { Content = pages, Padding = new(10), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(list, 1); sidebar.Children.Add(list); root.Children.Add(sidebar);
        var scroll = new ScrollViewer { Content = detail, Padding = new(28), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(scroll, 1); root.Children.Add(scroll); Content = root;
        AppWindow.Resize(new SizeInt32(Math.Clamp(preferences.SettingsWidth, 800, 1600), Math.Clamp(preferences.SettingsHeight, 540, 1200)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(area.X + Math.Max(0, (area.Width - AppWindow.Size.Width) / 2), area.Y + Math.Max(0, (area.Height - AppWindow.Size.Height) / 2)));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "codexbar.ico"));
        search.TextChanged += (_, _) => Sidebar();
        Closed += (_, _) => { closed = true; preferences.SettingsWidth = AppWindow.Size.Width; preferences.SettingsHeight = AppWindow.Size.Height; try { preferences.Save(); } catch (IOException) { } };
        Quit = quit; Sidebar(); Navigate(selected);
        root.Loaded += async (_, _) => await LoadCatalog();
    }
    private Action Quit { get; }
    public void Navigate(string page)
    {
        selected = page; preferences.SettingsPage = page; Title = page.StartsWith("provider:") ? page[9..] : page;
        detail.Children.Clear(); detail.Children.Add(Theme.Text(Title, 22, true)); detail.Children.Add(error); error.Text = "";
        switch (page)
        {
            case "General":
                Section("Refreshing");
                Choice("Refresh interval", ["1 minute", "2 minutes", "5 minutes", "15 minutes", "30 minutes", "Manual"], Array.IndexOf(new[] { 1, 2, 5, 15, 30, 0 }, preferences.RefreshMinutes), i => preferences.RefreshMinutes = new[] { 1, 2, 5, 15, 30, 0 }[i]);
                Toggle("Refresh when the menu opens", preferences.RefreshOnOpen, v => preferences.RefreshOnOpen = v);
                Toggle("Check provider status", preferences.CheckStatus, v => preferences.CheckStatus = v);
                detail.Children.Add(Theme.Action("Refresh now", "\uE72C", async () => await RefreshPage()));
                Section("Application"); detail.Children.Add(Theme.Action("Quit CodexBar", "\uE8BB", Quit)); break;
            case "Notifications":
                Section("Alerts");
                Toggle("Quota depleted & restored", preferences.Notifications.SessionTransitions, v => preferences.Notifications.SessionTransitions = v);
                detail.Children.Add(Theme.Text("Notifies when the session quota reaches zero and becomes available again.", 12, muted: true));
                Toggle("Threshold warnings", preferences.Notifications.ThresholdWarnings, v => preferences.Notifications.ThresholdWarnings = v, true);
                detail.Children.Add(Theme.Text("Warns when session or weekly quota remaining crosses configured thresholds.", 12, muted: true));
                Toggle("Pace warnings", preferences.Notifications.PredictiveWarnings, v => preferences.Notifications.PredictiveWarnings = v, true);
                detail.Children.Add(Theme.Text("Warns for Codex and Claude when session or weekly pace may run out before reset.", 12, muted: true));
                if (preferences.Notifications.ThresholdWarnings)
                {
                    Section("Global quota thresholds");
                    Toggle("Session warnings", preferences.Notifications.SessionEnabled, v => preferences.Notifications.SessionEnabled = v, true);
                    if (preferences.Notifications.SessionEnabled) ThresholdEditor("Session", preferences.Notifications.SessionThresholds, v => preferences.Notifications.SessionThresholds = v);
                    Toggle("Weekly warnings", preferences.Notifications.WeeklyEnabled, v => preferences.Notifications.WeeklyEnabled = v, true);
                    if (preferences.Notifications.WeeklyEnabled) ThresholdEditor("Weekly", preferences.Notifications.WeeklyThresholds, v => preferences.Notifications.WeeklyThresholds = v);
                }
                if (preferences.Notifications.ThresholdWarnings || preferences.Notifications.PredictiveWarnings)
                {
                    Section("Delivery");
                    Toggle("Play notification sound", preferences.Notifications.Sound, v => preferences.Notifications.Sound = v);
                    Toggle("Show on-screen text alert", preferences.Notifications.OnScreen, v => preferences.Notifications.OnScreen = v);
                }
                Section("Windows notifications");
                detail.Children.Add(Theme.Text(notificationStatus(), 12, muted: true));
                detail.Children.Add(Theme.Text("Quota alert rules currently support Codex and Claude. Windows controls banner visibility, sound and Do not disturb.", 12, muted: true));
                detail.Children.Add(Theme.Action("Send test notification", "", () => error.Text = testNotification()));
                detail.Children.Add(Theme.Action("Open Windows notification settings", "", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:notifications") { UseShellExecute = true })));
                break;
            case "Menu":
                Section("Usage");
                Choice("Usage bars fill", ["As remaining", "As used"], preferences.ShowRemaining ? 0 : 1, i => preferences.ShowRemaining = i == 0);
                Toggle("Show usage pace", preferences.ShowPace, v => preferences.ShowPace = v);
                Toggle("Show quota warning markers", preferences.ShowWarningMarkers, v => preferences.ShowWarningMarkers = v);
                Choice("Reset times", ["Countdown", "Date and time"], preferences.ResetAsDate ? 1 : 0, i => preferences.ResetAsDate = i == 1);
                Section("Content"); Toggle("Show credits and extra usage", preferences.ShowCredits, v => preferences.ShowCredits = v);
                Section("Cost summary"); Toggle("Show cost summary and submenu", preferences.ShowCosts, v => preferences.ShowCosts = v);
                var history = new NumberBox { Value = preferences.HistoryDays, Minimum = 1, Maximum = 365, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 160 };
                history.ValueChanged += (_, _) => { if (!double.IsFinite(history.Value)) return; preferences.HistoryDays = Math.Clamp((int)history.Value, 1, 365); Save(); };
                Card(Theme.Pair(Theme.Text("History window (days)"), history));
                detail.Children.Add(Theme.Text("The selected history window takes effect on the next refresh.", 12, muted: true)); break;
            case "Advanced":
                Section("Privacy"); Toggle("Hide account identities and project names and paths", preferences.RedactIdentity, v => preferences.RedactIdentity = v);
                Section("Command line"); detail.Children.Add(Theme.Text(cli ?? "Synthetic preview", 12, muted: true));
                if (cli != null) detail.Children.Add(Theme.Action("Validate provider configuration", "", async () => { try { var result = await Data.ReadCli(cli, "config", "validate", "--format", "json"); error.Text = result.ValueKind == JsonValueKind.Array && result.GetArrayLength() == 0 ? "Configuration is valid." : "Configuration has issues. Run codexbar config validate for details."; } catch (Exception) { error.Text = "Configuration validation failed."; } }));
                break;
            case "About":
                detail.Children.Add(Theme.Text("CodexBar for Windows", 18, true));
                detail.Children.Add(Theme.Text("Shared CodexBar CLI · Windows tray review build", 13, muted: true));
                detail.Children.Add(Theme.Text("CLI " + snapshot().Object("host").Text("codexBarVersion", "version not reported"), 12));
                detail.Children.Add(Theme.Action("GitHub", "", () => MenuWindow.OpenUrl("https://github.com/gertjvr/CodexBar")));
                detail.Children.Add(Theme.Action("Website", "", () => MenuWindow.OpenUrl("https://codexbar.app"))); break;
            default:
                if (page.StartsWith("provider:")) Provider(page[9..]);
                else { selected = "General"; Navigate(selected); } break;
        }
        Sidebar();
    }
    private void Section(string title) { detail.Children.Add(Theme.Text(title, 14, true)); }
    private void Save()
    {
        try { preferences.Save(); changed(); error.Text = ""; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { error.Text = "Unable to save settings. Check access to the CodexBar preferences folder."; }
    }
    private void Toggle(string title, bool value, Action<bool> update, bool rebuild = false)
    {
        var toggle = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", VerticalAlignment = VerticalAlignment.Center };
        toggle.Toggled += (_, _) => { update(toggle.IsOn); Save(); if (rebuild) Navigate(selected); };
        Card(Theme.Pair(Theme.Text(title), toggle));
    }
    private void Choice(string title, string[] values, int index, Action<int> update, bool rebuild = false)
    {
        var choice = new ComboBox { ItemsSource = values, SelectedIndex = Math.Max(0, index), MinWidth = 160 };
        choice.SelectionChanged += (_, _) => { if (choice.SelectedIndex >= 0) { update(choice.SelectedIndex); Save(); if (rebuild) Navigate(selected); } };
        Card(Theme.Pair(Theme.Text(title), choice));
    }
    private void Card(UIElement content) => detail.Children.Add(new Border { Background = Theme.Brush("303537"), BorderBrush = Theme.Brush("42484A"), BorderThickness = new(1), CornerRadius = new(6), Padding = new(12), Child = content });
    private async Task RefreshPage() { await refresh(); if (!closed) Navigate(selected); }
    private async Task LoadCatalog()
    {
        try
        {
            catalog = cli == null ? snapshot().Rows("providers").Select(p => JsonSerializer.SerializeToElement(new { provider = p.Text("id"), displayName = p.Text("name"), enabled = true })).ToArray() : (await Data.ReadCli(cli, "config", "providers", "--format", "json")).EnumerateArray().ToArray();
            if (!closed) Navigate(selected);
        }
        catch (Exception) { if (!closed) error.Text = "Provider catalog could not be loaded."; }
    }
    private void Sidebar()
    {
        pages.Children.Clear();
        foreach (var name in new[] { "General", "Notifications", "Menu", "Advanced", "About" }) AddPage(name, name);
        pages.Children.Add(Theme.Text($"Providers · {catalog.Count(p => p.Object("enabled").ValueKind == JsonValueKind.True)} on", 12, true, true));
        foreach (var provider in catalog.Where(p => p.Text("displayName").Contains(search.Text, StringComparison.OrdinalIgnoreCase)))
            AddPage("provider:" + provider.Text("provider"), provider.Text("displayName") + (provider.Object("enabled").ValueKind == JsonValueKind.True ? "  ●" : ""));
    }
    private void AddPage(string id, string label)
    {
        var button = Theme.Action(label, "", () => Navigate(id));
        if (id.StartsWith("provider:") && button.Content is Grid layout)
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", id[9..] + "-normal.png");
            if (File.Exists(path)) { layout.Children.RemoveAt(0); layout.Children.Add(new Image { Source = new BitmapImage(new Uri(path)), Width = 16, Height = 16 }); }
        }
        if (id == selected) button.Background = Theme.Blue;
        pages.Children.Add(button);
    }
    private void Provider(string id)
    {
        var config = catalog.FirstOrDefault(p => p.Text("provider") == id);
        var provider = snapshot().Rows("providers").FirstOrDefault(p => p.Text("id") == id);
        Title = config.Text("displayName", id); ((TextBlock)detail.Children[0]).Text = Title;
        var enabled = new ToggleSwitch { IsOn = config.Object("enabled").ValueKind == JsonValueKind.True, IsEnabled = cli != null, OnContent = "Enabled", OffContent = "Disabled" };
        enabled.Toggled += async (_, _) =>
        {
            var requested = enabled.IsOn; enabled.IsEnabled = false;
            try { await Data.ReadCli(cli!, "config", requested ? "enable" : "disable", "--provider", id, "--format", "json"); await refresh(); await LoadCatalog(); }
            catch (Exception) { error.Text = "Provider configuration could not be saved. Reopen this page to reload."; }
        };
        Card(enabled);
        detail.Children.Add(Theme.Action("Refresh", "\uE72C", async () => await RefreshPage()));
        var identity = provider.Object("identity");
        var info = new StackPanel { Spacing = 12 };
        foreach (var row in new[] { ("Source", provider.Text("source")), ("Updated", provider.Text("updatedAt")), ("Status", provider.Object("status").Text("label")), ("Account", preferences.RedactIdentity ? "Hidden" : identity.Text("accountEmail")), ("Plan", Theme.Plan(id, identity.Text("plan"))) })
            info.Children.Add(Theme.Pair(Theme.Text(row.Item1), Theme.Text(row.Item2, 12, muted: true)));
        Card(info); Section("Usage");
        foreach (var metric in provider.Rows("windows").Where(w => preferences.Visible(id, w.Text("kind"))))
        {
            var percent = metric.Number(preferences.ShowRemaining ? "remainingPercent" : "usedPercent");
            if (percent is not double value) continue;
            var usage = new StackPanel { Spacing = 6 }; usage.Children.Add(Theme.Text($"{metric.Text("label")} {value:0}% {(preferences.ShowRemaining ? "left" : "used")}", 13, true));
            usage.Children.Add(new ProgressBar { Value = value, Foreground = Theme.Brush(preferences.Accent(id)) }); Card(usage);
        }
        Section("Visible usage items");
        foreach (var metric in provider.Rows("windows")) VisibilityToggle(id, metric.Text("kind"), metric.Text("label"));
        foreach (var item in new[] { ("codeReview", "Code review"), ("resetCredits", "Limit Reset Credits"), ("credits", "Credits") })
            if (id == "codex" || item.Item1 == "credits") VisibilityToggle(id, item.Item1, item.Item2);
        detail.Children.Add(Theme.Action("Restore Defaults", "", () => { preferences.HiddenItems.Remove(id); Save(); Navigate(selected); }));
        if (id is "codex" or "claude")
        {
            Section("Quota warnings");
            foreach (var lane in new[] { ("primary", "Session"), ("secondary", "Weekly") })
            {
                var key = id + ":" + lane.Item1;
                var custom = preferences.Notifications.Overrides.TryGetValue(key, out var stored) ? stored : new WarningOverride();
                Choice(lane.Item2, ["Global", "Custom", "Off"], Array.IndexOf(new[] { "global", "custom", "off" }, custom.Mode), i =>
                {
                    custom.Mode = new[] { "global", "custom", "off" }[i]; preferences.Notifications.Overrides[key] = custom;
                }, true);
                if (custom.Mode == "custom") ThresholdEditor(lane.Item2, custom.Thresholds, v => { custom.Thresholds = v; preferences.Notifications.Overrides[key] = custom; });
                if (custom.Mode == "global") detail.Children.Add(Theme.Text("Inherited: " + string.Join(", ", preferences.Notifications.Thresholds(id, lane.Item1).Select(v => v + "%")), 12, muted: true));
            }
            detail.Children.Add(Theme.Text("Thresholds also control the menu's warning markers, even when notifications are off.", 12, muted: true));
        }
        Section("Accent color");
        var accent = new TextBox { Text = "#" + preferences.Accent(id), Header = "Hex color", MaxLength = 7 };
        detail.Children.Add(accent);
        detail.Children.Add(Theme.Action("Apply accent color", "", () => { var hex = accent.Text.Trim().TrimStart('#'); if (hex.Length != 6 || !hex.All(Uri.IsHexDigit)) { error.Text = "Enter a six-digit hex color."; return; } preferences.Accents[id] = hex; Save(); Navigate(selected); }));
    }
    private void ThresholdEditor(string label, int[] values, Action<int[]> update)
    {
        var active = NotificationOptions.Sanitize(values);
        var warning = new NumberBox { Header = label + " warning %", Minimum = 1, Maximum = 99, Value = active.FirstOrDefault(50), Width = 170, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var critical = new NumberBox { Header = label + " critical %", Minimum = 1, Maximum = 99, Value = active.Skip(1).FirstOrDefault(20), Width = 170, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        void Commit()
        {
            if (!double.IsFinite(warning.Value) || !double.IsFinite(critical.Value)) return;
            if (critical.Value >= warning.Value) { error.Text = "Critical remaining quota must be lower than the warning threshold."; return; }
            update([(int)warning.Value, (int)critical.Value]); Save();
        }
        warning.ValueChanged += (_, _) => Commit(); critical.ValueChanged += (_, _) => Commit();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 }; row.Children.Add(warning); row.Children.Add(critical); Card(row);
    }
    private void VisibilityToggle(string id, string key, string label)
    {
        var item = new CheckBox { Content = label, IsChecked = preferences.Visible(id, key) };
        item.Click += (_, _) => { preferences.SetVisible(id, key, item.IsChecked == true); Save(); Navigate(selected); };
        Card(item);
    }
}
