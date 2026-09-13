using System.Diagnostics;
using System.Text.Json;

namespace CodexBar.Tray;

internal static class Data
{
    public static readonly CancellationTokenSource Shutdown = new();
    public static string Text(this JsonElement e, string key, string fallback = "") =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;
    public static JsonElement Object(this JsonElement e, string key) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) ? v : default;
    public static double? Number(this JsonElement e, string key) => e.Object(key).ValueKind == JsonValueKind.Number ? e.Object(key).GetDouble() : null;
    public static IEnumerable<JsonElement> Rows(this JsonElement e, string key) =>
        e.Object(key).ValueKind == JsonValueKind.Array ? e.Object(key).EnumerateArray().ToArray() : [];
    public static string Money(double? value) => value.HasValue ? value.Value.ToString("$#,##0.00", System.Globalization.CultureInfo.InvariantCulture) : "—";
    public static string Tokens(double? value) => value switch { null => "—", >= 1e9 => $"{value / 1e9:0.##}B", >= 1e6 => $"{value / 1e6:0.##}M", >= 1e3 => $"{value / 1e3:0.##}K", _ => $"{value:0}" };
    public static string Countdown(string raw, DateTimeOffset now)
    {
        if (!DateTimeOffset.TryParse(raw, out var reset)) return "";
        var delta = reset - now;
        if (delta.TotalSeconds <= 0) return "now";
        return delta.TotalDays >= 1 ? $"{(int)delta.TotalDays}d {delta.Hours}h" : delta.TotalHours >= 1 ? $"{(int)delta.TotalHours}h {delta.Minutes}m" : $"{Math.Max(1, delta.Minutes)}m";
    }
    public static async Task<JsonElement> ReadCli(string executable, params string[] arguments)
    {
        using var process = new Process { StartInfo = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true } };
        foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
        process.Start();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(Shutdown.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(50));
        using var killOnCancel = timeout.Token.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
        });
        var output = ReadBounded(process.StandardOutput, timeout.Token);
        var errors = ReadBounded(process.StandardError, timeout.Token);
        try { await Task.WhenAll(output, errors, process.WaitForExitAsync(timeout.Token)).WaitAsync(timeout.Token); }
        catch
        {
            if (!process.HasExited) process.Kill(true);
            try { await Task.WhenAll(output, errors); } catch { }
            throw;
        }
        var json = await output;
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        // Usage/cost may return useful per-provider error payloads with a nonzero exit.
        if (process.ExitCode != 0 && !(arguments[0] is "usage" or "cost" && root.ValueKind == JsonValueKind.Array && root.EnumerateArray().All(e => e.Text("provider") != "")))
            throw new InvalidOperationException("The companion CLI command failed.");
        return root.Clone();
    }
    private static async Task<string> ReadBounded(StreamReader reader, CancellationToken cancellation)
    {
        var text = new System.Text.StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), cancellation)) > 0)
        {
            if (text.Length + count > 8 * 1024 * 1024) throw new InvalidDataException("CLI response is too large.");
            text.Append(buffer, 0, count);
        }
        return text.ToString();
    }
}
