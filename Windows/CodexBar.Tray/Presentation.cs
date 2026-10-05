using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexBar.Tray;

internal static class Presentation
{
    public static string Text(string value, bool redactIdentity)
    {
        if (!redactIdentity || !value.Contains('@')) return value;
        // Match the dashboard's bounded address handling, including quoted local parts,
        // apostrophes, internal domains and IPv6 domain literals.
        var output = new StringBuilder();
        var cursor = 0;
        var search = 0;
        while (value.IndexOf('@', search) is var at && at >= 0)
        {
            var start = at;
            var quoted = false;
            while (start > 0)
            {
                var character = value[start - 1];
                if (character == '"') { quoted = !quoted; start--; continue; }
                if (!quoted && EmailBoundary(character)) break;
                start--;
            }
            start = Math.Max(start, cursor);
            var end = at + 1;
            if (end < value.Length && value[end] == '[')
            {
                while (end < value.Length) if (value[end++] == ']') break;
            }
            else while (end < value.Length && !EmailBoundary(value[end])) end++;
            if (start < at && end > at + 1)
            {
                output.Append(value, cursor, start - cursor);
                cursor = end;
                search = end;
            }
            else search = at + 1;
        }
        output.Append(value, cursor, value.Length - cursor);
        var redacted = output.ToString();
        redacted = Regex.Replace(redacted, @"\s+([:.,;])", "$1");
        return Regex.Replace(redacted, @"\s{2,}", " ").Trim();
    }

    private static bool EmailBoundary(char character) => char.IsWhiteSpace(character) || "()<>:,;·/".Contains(character);

    public static JsonElement Details(JsonElement details, bool redactIdentity)
    {
        if (!redactIdentity || details.ValueKind != JsonValueKind.Array) return details;
        var clone = JsonNode.Parse(details.GetRawText())!;
        Redact(clone);
        return JsonSerializer.SerializeToElement(clone);
    }

    private static void Redact(JsonNode node)
    {
        if (node is JsonArray array)
        {
            foreach (var child in array) if (child != null) Redact(child);
        }
        else if (node is JsonObject item)
        {
            foreach (var (key, child) in item.ToArray())
            {
                if (child is JsonValue value && value.TryGetValue<string>(out var text) && key != "id")
                    item[key] = Text(text, true);
                else if (child != null) Redact(child);
            }
        }
    }

    public static double? PeriodCost(JsonElement cost) => cost.Object("totals").ValueKind == JsonValueKind.Object
        ? cost.Object("totals").Number("totalCost") : cost.Object("periodCostUSD").ValueKind != JsonValueKind.Undefined
        ? cost.Number("periodCostUSD") : (cost.Number("historyDays") ?? 30) <= 30 ? cost.Number("last30DaysUSD") : null;

    public static double? PeriodTokens(JsonElement cost) => cost.Object("totals").ValueKind == JsonValueKind.Object
        ? cost.Object("totals").Number("totalTokens") : cost.Object("periodTokens").ValueKind != JsonValueKind.Undefined
        ? cost.Number("periodTokens") : (cost.Number("historyDays") ?? 30) <= 30 ? cost.Object("history").Number("last30DaysTokens") : null;

    public static string PeriodLabel(JsonElement cost) => cost.Text("historyLabel") is { Length: > 0 } label ? label : $"Last {cost.Number("historyDays") ?? 30:0} days";

    public static string TodayLabel(JsonElement cost, DateTimeOffset now)
    {
        var asOf = cost.Text("asOfDate");
        if (asOf == "" && DateTimeOffset.TryParse(cost.Text("updatedAt"), out var updatedAt))
            asOf = updatedAt.ToOffset(now.Offset).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        return asOf == "" || asOf == now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) ? "Today" : "As of " + DayLabel(asOf);
    }

    public static string DayLabel(string? day) => DateOnly.TryParse(day, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date.ToString("d MMM", CultureInfo.InvariantCulture) : day ?? "";

    public static bool IsPartial(JsonElement cost) => cost.Object("historyCoverageIsEstablished").ValueKind == JsonValueKind.False ||
        cost.Object("historyScanIsPartial").ValueKind == JsonValueKind.True || cost.Number("incompleteRequestCount") > 0 ||
        cost.Object("coverage").Number("unpriced") > 0 || cost.Object("coverage").Number("unmetered") > 0;

    public static bool CountsArePartial(JsonElement cost) => cost.Object("historyCoverageIsEstablished").ValueKind == JsonValueKind.False ||
        cost.Object("historyScanIsPartial").ValueKind == JsonValueKind.True || cost.Number("incompleteRequestCount") > 0;

    public static bool ScanIsPartial(JsonElement cost) => cost.Object("historyCoverageIsEstablished").ValueKind == JsonValueKind.False ||
        cost.Object("historyScanIsPartial").ValueKind == JsonValueKind.True;

    private static double IncompleteRequests(JsonElement row) => row.Number("incompleteRequestCount") is double count
        ? Math.Max(0, count) : row.Rows("daily").Sum(day => Math.Max(0, day.Number("incompleteRequestCount") ?? 0));

    public static bool RowIsPartial(JsonElement cost, JsonElement row) => ScanIsPartial(cost) || IncompleteRequests(row) > 0;

    private static string IncompleteNote(JsonElement row) => IncompleteRequests(row) is > 0 and var incomplete ? $" · {incomplete:0} incomplete requests" : "";

    public static string RowValues(JsonElement cost, JsonElement row, string costKey = "totalCost") =>
        Amount(cost, row.Number(costKey), RowIsPartial(cost, row)) + " · " +
        Tokens(row.Number("totalTokens"), RowIsPartial(cost, row)) + " tokens" + IncompleteNote(row);

    public static string Tokens(double? value, bool partial = false) => (value.HasValue && partial ? "≥ " : "") + Data.Tokens(value);

    public static string Amount(JsonElement cost, double? amount, bool partial = false)
    {
        if (!amount.HasValue) return "—";
        var currency = cost.Text("currencyCode", "USD");
        return (partial ? "≥ " : "") + (currency == "USD" ? "$" : currency + " ") + amount.Value.ToString("N2", CultureInfo.InvariantCulture);
    }

    public static string CostNote(JsonElement cost)
    {
        var basis = cost.Text("provenance") switch
        {
            "vendorMetered" => "Vendor-reported metered spend",
            "mixed" => "Metered spend and list-price estimates",
            "listPriceEstimate" => "Estimated from token usage",
            _ => "Cost source not established"
        };
        var notes = new List<string> { basis, "not a subscription bill" };
        if (cost.Object("historyCoverageIsEstablished").ValueKind == JsonValueKind.False || cost.Object("historyScanIsPartial").ValueKind == JsonValueKind.True)
            notes.Add("history scan is partial");
        if (cost.Object("coverage").Number("unpriced") is > 0 and var unpriced) notes.Add($"{unpriced:0} unpriced");
        if (cost.Object("coverage").Number("unmetered") is > 0 and var unmetered) notes.Add($"{unmetered:0} unmetered");
        if (cost.Number("incompleteRequestCount") is > 0 and var incomplete) notes.Add($"{incomplete:0} incomplete requests");
        return string.Join(" · ", notes);
    }

    public static string DailyValue(JsonElement day, bool cost, JsonElement currency = default)
    {
        var value = day.Number(cost ? "totalCost" : "totalCreditsUsed");
        var text = cost ? Amount(currency, value, RowIsPartial(currency, day)) : value?.ToString("N2", CultureInfo.InvariantCulture) ?? "—";
        return text + IncompleteNote(day);
    }
}
