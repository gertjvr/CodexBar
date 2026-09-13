using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexBar.Tray;

// A frontend projection of the existing usage/cost JSON, not a new CLI contract.
internal static class CliSnapshot
{
    public static async Task<JsonElement> Read(string executable, JsonElement previous, Action<JsonElement>? progress = null, int historyDays = 30, bool checkStatus = true)
    {
        var catalog = await Data.ReadCli(executable, "config", "providers", "--format", "json");
        if (catalog.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid provider catalog.");
        var providers = catalog.EnumerateArray().Where(c => c.Object("enabled").ValueKind == JsonValueKind.True).Select(c =>
        {
            var old = previous.Rows("providers").FirstOrDefault(p => p.Text("id") == c.Text("provider"));
            return old.ValueKind == JsonValueKind.Object ? old : Project(c.Text("provider"), c.Text("displayName"), default, default, default, DateTimeOffset.Now);
        }).ToList();
        JsonElement Snapshot() => JsonSerializer.SerializeToElement(new { generatedAt = DateTimeOffset.Now, providers });
        progress?.Invoke(Snapshot());
        foreach (var config in catalog.EnumerateArray().Where(c => c.Object("enabled").ValueKind == JsonValueKind.True))
        {
            var id = config.Text("provider");
            var old = previous.Rows("providers").FirstOrDefault(p => p.Text("id") == id);
            JsonElement usage = default, cost = default;
            string? usageError = null, costError = null;
            try
            {
                var arguments = new List<string> { "usage", "--provider", id, "--format", "json", "--json-only" };
                if (checkStatus) arguments.Add("--status");
                var response = await Data.ReadCli(executable, arguments.ToArray());
                usage = Entries(response).FirstOrDefault(p => p.Text("provider") == id);
                if (usage.ValueKind != JsonValueKind.Object) throw new InvalidDataException("CLI returned no matching provider.");
            }
            catch (Exception) { usageError = "Refresh failed. Showing the last available usage."; }
            var index = providers.FindIndex(p => p.Text("id") == id);
            providers[index] = Project(id, config.Text("displayName", id), usage, default, old, DateTimeOffset.Now, usageError);
            progress?.Invoke(Snapshot());
            if (id is "codex" or "claude")
            {
                try
                {
                    var response = await Data.ReadCli(executable, "cost", "--provider", id, "--format", "json", "--days", Math.Clamp(historyDays, 1, 365).ToString(System.Globalization.CultureInfo.InvariantCulture));
                    cost = Entries(response).FirstOrDefault(p => p.Text("provider") == id);
                    if (cost.ValueKind != JsonValueKind.Object) throw new InvalidDataException("CLI returned no matching cost provider.");
                }
                catch (Exception) { costError = "Cost refresh failed. Showing the last available costs."; }
            }
            providers[index] = Project(id, config.Text("displayName", id), usage, cost, old, DateTimeOffset.Now, usageError, costError);
            progress?.Invoke(Snapshot());
        }
        return Snapshot();
    }

    private static IEnumerable<JsonElement> Entries(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Array => value.EnumerateArray().ToArray(),
        JsonValueKind.Object => [value],
        _ => throw new InvalidDataException("Invalid CLI response.")
    };

    public static JsonElement Project(string id, string name, JsonElement entry, JsonElement cost,
        JsonElement previous, DateTimeOffset now, string? usageError = null, string? costError = null)
    {
        if (entry.ValueKind == JsonValueKind.Object && entry.Text("provider") != id)
            throw new InvalidDataException("Usage provider mismatch.");
        if (cost.ValueKind == JsonValueKind.Object && cost.Text("provider") != id)
            throw new InvalidDataException("Cost provider mismatch.");
        if (previous.Text("id") != id) previous = default;
        var usage = entry.Object("usage");
        JsonObject result;
        if (usage.ValueKind != JsonValueKind.Object && previous.ValueKind == JsonValueKind.Object)
            result = JsonNode.Parse(previous.GetRawText())!.AsObject();
        else
        {
            var identity = usage.Object("identity");
            var identityProvider = identity.Text("providerID");
            var identityMatches = identityProvider == "" || identityProvider == id;
            var windows = new List<object>();
            foreach (var (key, label) in new[] { ("primary", "Session"), ("secondary", "Weekly"), ("tertiary", "Additional") })
                AddWindow(windows, key, label, usage.Object(key));
            foreach (var extra in usage.Rows("extraRateWindows"))
                if (extra.Object("usageKnown").ValueKind != JsonValueKind.False)
                    AddWindow(windows, extra.Text("id"), extra.Text("title"), extra.Object("window"));
            var dashboard = id == "codex" ? entry.Object("openaiDashboard") : default;
            var expiries = id == "codex" ? usage.Object("codexResetCredits").Rows("credits")
                .Where(c => c.Text("status") == "available" &&
                    (!DateTimeOffset.TryParse(c.Text("expires_at"), out var date) || date > now))
                .Select(c => c.Text("expires_at") is { Length: > 0 } expiry ? expiry : null)
                .OrderBy(d => d == null).ThenBy(d => d).ToArray() : [];
            result = JsonSerializer.SerializeToNode(new
            {
                id,
                name,
                enabled = true,
                source = entry.Text("source"),
                updatedAt = usage.Text("updatedAt"),
                identity = new
                {
                    accountEmail = identityMatches ? identity.Text("accountEmail", usage.Text("accountEmail")) : "",
                    plan = identityMatches ? identity.Text("loginMethod", usage.Text("loginMethod")) : ""
                },
                windows,
                presentation = new
                {
                    pace = Node(entry.Object("pace")),
                    resetCreditExpiries = expiries,
                    codeReviewRemainingPercent = dashboard.Number("codeReviewRemainingPercent"),
                    usageBreakdown = Node(dashboard.Object("usageBreakdown")),
                    subscriptionRenewsAt = dashboard.Text("subscriptionRenewsAt"),
                    creditsPurchaseURL = dashboard.Text("creditsPurchaseURL")
                },
                details = Node(usage.Object("details")),
                credits = CreditBalance(entry.Object("credits")),
                status = new { label = entry.Object("status").Text("description", entry.Object("status").Text("indicator")), indicator = entry.Object("status").Text("indicator"), updatedAt = entry.Object("status").Text("updatedAt"), url = entry.Object("status").Text("url"), components = Node(entry.Object("status").Object("components")) }
            })!.AsObject();
        }
        var error = usageError ?? (entry.Object("error").ValueKind == JsonValueKind.Object ? "Usage refresh failed. Check this provider's CLI sign-in and configuration." : null);
        result["error"] = error == null ? null : JsonSerializer.SerializeToNode(new { message = error });
        if (cost.ValueKind == JsonValueKind.Object && cost.Object("error").ValueKind != JsonValueKind.Object)
        {
            var todayKey = now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            var startKey = now.AddDays(1 - Math.Clamp((int)(cost.Number("historyDays") ?? 30), 1, 365)).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            var daily = cost.Rows("daily").Where(d => String.CompareOrdinal(d.Text("date"), startKey) >= 0 && String.CompareOrdinal(d.Text("date"), todayKey) <= 0)
                .OrderBy(d => d.Text("date")).ToArray();
            var today = daily.FirstOrDefault(d => d.Text("date") == todayKey).Number("totalCost");
            if (today == null && cost.Object("historyCoverageIsEstablished").ValueKind == JsonValueKind.True) today = 0;
            result["cost"] = JsonSerializer.SerializeToNode(new
            {
                todayUSD = today,
                last30DaysUSD = cost.Number("last30DaysCostUSD"),
                updatedAt = cost.Text("updatedAt"),
                historyDays = Math.Clamp((int)(cost.Number("historyDays") ?? 30), 1, 365),
                currencyCode = cost.Text("currencyCode", "USD"),
                projects = cost.Rows("projects").ToArray(),
                history = new { sessionTokens = cost.Number("sessionTokens"), last30DaysTokens = cost.Number("last30DaysTokens"), daily }
            });
        }
        else if (previous.Object("cost").ValueKind == JsonValueKind.Object) result["cost"] = Node(previous.Object("cost"));
        result["costError"] = costError ?? (cost.Object("error").ValueKind == JsonValueKind.Object ? "Cost refresh failed. Showing the last available costs." : null);
        return JsonSerializer.SerializeToElement(result);
    }

    private static object? CreditBalance(JsonElement credits)
    {
        if (credits.ValueKind != JsonValueKind.Object) return null;
        var read = credits.Object("balanceReadSucceeded").ValueKind != JsonValueKind.False;
        var workspace = read && credits.Object("balanceIsWorkspace").ValueKind == JsonValueKind.True;
        var remaining = workspace ? credits.Number("remaining") : credits.Object("codexCreditLimit").Number("remaining") ?? (read ? credits.Number("remaining") : null);
        return new { remaining };
    }

    private static JsonNode? Node(JsonElement value) => value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null ? null : JsonNode.Parse(value.GetRawText());
    private static void AddWindow(List<object> windows, string kind, string label, JsonElement value)
    {
        if (value.Number("usedPercent") is not double used || !double.IsFinite(used)) return;
        windows.Add(new { kind, label, usedPercent = Math.Clamp(used, 0, 100), remainingPercent = Math.Clamp(100 - used, 0, 100), resetAt = value.Text("resetsAt"), windowMinutes = value.Number("windowMinutes"), idle = false });
    }
}
