using System.Text.Json;

namespace CodexBar.Tray;

internal sealed class Preferences
{
    public bool ShowRemaining { get; set; } = true;
    public bool ShowPace { get; set; } = true;
    public bool ShowCosts { get; set; } = true;
    public NotificationOptions Notifications { get; set; } = new();
    public bool ShowWarningMarkers { get; set; } = true;
    public int HistoryDays { get; set; } = 30;
    public bool CheckStatus { get; set; } = true;
    public bool ShowCredits { get; set; } = true;
    public bool ResetAsDate { get; set; }
    public bool RedactIdentity { get; set; }
    public bool RefreshOnOpen { get; set; }
    public int RefreshMinutes { get; set; } = 2;
    public string SettingsPage { get; set; } = "General";
    public int SettingsWidth { get; set; } = 1000;
    public int SettingsHeight { get; set; } = 740;
    public Dictionary<string, HashSet<string>> HiddenItems { get; set; } = new();
    public Dictionary<string, string> Accents { get; set; } = new();
    public bool Visible(string provider, string item) => !HiddenItems.TryGetValue(provider, out var items) || !items.Contains(item);
    public void SetVisible(string provider, string item, bool visible)
    {
        if (!HiddenItems.TryGetValue(provider, out var items)) HiddenItems[provider] = items = new();
        if (visible) items.Remove(item); else items.Add(item);
    }
    public string Accent(string provider) => Accents.TryGetValue(provider, out var hex) && hex.Length == 6 && hex.All(Uri.IsHexDigit)
        ? hex : provider == "claude" ? "CC7C5E" : "49A3B0";
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexBar", "tray-preferences.json");
    public static Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
}
