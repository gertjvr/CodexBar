using System.Text.Json;

namespace CodexBar.Tray;

internal static class CostHistory
{
    // Retain empty calendar days so a newly installed account does not become a single wide bar.
    // Missing buckets remain unknown rather than acquiring an invented zero price.
    public static JsonElement[] Calendar(JsonElement cost, DateTimeOffset now)
    {
        var count = Math.Clamp((int)(cost.Number("historyDays") ?? 30), 1, 365);
        var rows = cost.Object("history").Rows("daily").GroupBy(d => d.Text("date")).ToDictionary(g => g.Key, g => g.Last());
        return Enumerable.Range(1 - count, count).Select(offset =>
        {
            var key = now.AddDays(offset).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            return rows.TryGetValue(key, out var value) ? value : JsonSerializer.SerializeToElement(new { date = key });
        }).ToArray();
    }
}
