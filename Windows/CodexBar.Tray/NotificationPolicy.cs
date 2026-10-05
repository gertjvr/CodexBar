using System.Text.Json;

namespace CodexBar.Tray;

internal sealed class NotificationOptions
{
    public bool SessionTransitions { get; set; } = true;
    public bool ThresholdWarnings { get; set; }
    public bool PredictiveWarnings { get; set; }
    public bool Sound { get; set; } = true;
    public bool OnScreen { get; set; }
    public bool SessionEnabled { get; set; } = true;
    public bool WeeklyEnabled { get; set; } = true;
    public int[] SessionThresholds { get; set; } = [50, 20];
    public int[] WeeklyThresholds { get; set; } = [50, 20];
    public Dictionary<string, WarningOverride> Overrides { get; set; } = new();
    public int[] Thresholds(string provider, string lane)
    {
        var enabled = lane == "primary" ? SessionEnabled : WeeklyEnabled;
        var values = lane == "primary" ? SessionThresholds : WeeklyThresholds;
        if (Overrides.TryGetValue(provider + ":" + lane, out var custom))
        {
            if (custom.Mode == "off") return [];
            if (custom.Mode == "custom") { enabled = true; values = custom.Thresholds; }
        }
        return enabled ? Sanitize(values) : [];
    }
    public static int[] Sanitize(IEnumerable<int>? values) => (values ?? []).Where(v => v is > 0 and < 100).Distinct().OrderDescending().ToArray();
}
internal sealed class WarningOverride
{
    public string Mode { get; set; } = "global";
    public int[] Thresholds { get; set; } = [50, 20];
}
internal sealed record QuotaAlert(string Provider, string Title, string Message, bool Warning);

// UI notification policy mirrors SessionQuotaNotifications.swift and PredictivePaceWarnings.swift.
// Provider fetching and pace calculations remain in the companion CLI.
internal sealed class NotificationPolicy
{
    private sealed class State
    {
        public string Owner = "", Source = "";
        public double Remaining;
        public DateTimeOffset Observed;
        public DateTimeOffset? Reset, PendingRestore, PaceReset;
        public HashSet<int> Fired = [];
        public bool PaceWarned;
    }
    private readonly Dictionary<string, State> states = new();
    public IReadOnlyList<QuotaAlert> Observe(JsonElement snapshot, NotificationOptions options, DateTimeOffset now)
    {
        var alerts = new List<QuotaAlert>();
        foreach (var provider in snapshot.Rows("providers"))
        {
            var id = provider.Text("id");
            // Other providers can expose balances as primary limits. Port their explicit Mac
            // notification lane rules before treating those numbers as session quota.
            if (id is not ("codex" or "claude") || provider.Object("error").ValueKind == JsonValueKind.Object ||
                !DateTimeOffset.TryParse(provider.Text("updatedAt"), out var observed) || observed > now.AddMinutes(5)) continue;
            var owner = provider.Object("identity").Text("accountEmail").Trim().ToLowerInvariant();
            var source = provider.Text("source");
            foreach (var window in provider.Rows("windows"))
            {
                var kind = window.Text("kind");
                var extra = id == "claude" && (kind.StartsWith("claude-weekly-scoped-", StringComparison.Ordinal) || kind == "claude-routines");
                if (kind is not ("primary" or "secondary") && !extra) continue;
                if (window.Number("remainingPercent") is not double remaining || !double.IsFinite(remaining)) continue;
                remaining = Math.Clamp(remaining, 0, 100);
                var reset = DateTimeOffset.TryParse(window.Text("resetAt"), out var at) ? at : (DateTimeOffset?)null;
                var key = id + ":" + kind;
                states.TryGetValue(key, out var prior);
                if (prior != null && observed <= prior.Observed) continue;
                var ownerChanged = prior != null && (prior.Owner != owner || prior.Source != source);
                if (prior == null || ownerChanged)
                {
                    var first = new State { Owner = owner, Source = source, Observed = observed, Remaining = remaining, Reset = reset > now && reset > observed ? reset : null };
                    states[key] = first;
                    if (ownerChanged) continue;
                    if (kind == "primary" && options.SessionTransitions && remaining <= .0001)
                        alerts.Add(new(id, provider.Text("name") + " session depleted", "Your session quota is exhausted. You will be notified when it becomes available again.", false));
                    EvaluateWarnings(provider, window, first, null, options, alerts);
                    continue;
                }
                var previousRemaining = prior!.Remaining;
                if (kind == "primary" && options.SessionTransitions)
                {
                    if (previousRemaining > .0001 && remaining <= .0001)
                        alerts.Add(new(id, provider.Text("name") + " session depleted", "Your session quota is exhausted. You will be notified when it becomes available again.", false));
                    if (previousRemaining <= .0001 && remaining > .0001)
                    {
                        var restored = id != "codex";
                        if (id == "codex")
                        {
                            var boundaryPassed = prior.Reset == null || (now >= prior.Reset && observed >= prior.Reset);
                            var advanced = prior.Reset != null && reset >= prior.Reset.Value.AddSeconds(120) && reset > now && reset > observed;
                            restored = boundaryPassed && (advanced || (prior.PendingRestore != null && observed > prior.PendingRestore));
                            if (boundaryPassed && !restored) prior.PendingRestore = observed;
                        }
                        if (restored)
                        {
                            alerts.Add(new(id, provider.Text("name") + " session restored", "Your session quota is available again.", false));
                            prior.PendingRestore = null;
                        }
                        else { prior.Observed = observed; continue; }
                    }
                }
                else prior.PendingRestore = null;
                prior.Observed = observed;
                prior.Remaining = remaining;
                if (reset > now && reset > observed && (prior.Reset == null || reset > prior.Reset)) prior.Reset = reset;
                EvaluateWarnings(provider, window, prior, previousRemaining, options, alerts);
            }
        }
        return alerts;
    }
    private static void EvaluateWarnings(JsonElement provider, JsonElement window, State state, double? previous, NotificationOptions options, List<QuotaAlert> alerts)
    {
        var id = provider.Text("id"); var kind = window.Text("kind");
        if (!options.ThresholdWarnings) state.Fired.Clear();
        else
        {
            var thresholds = options.Thresholds(id, kind == "primary" ? "primary" : "secondary");
            state.Fired.RemoveWhere(t => state.Remaining > t);
            var crossed = thresholds.Where(t => state.Remaining <= t && !state.Fired.Contains(t) && (previous == null || previous > t)).Cast<int?>().Min();
            if (crossed is int threshold)
            {
                state.Fired.UnionWith(thresholds.Where(t => t >= threshold));
                alerts.Add(new(id, provider.Text("name") + " " + window.Text("label") + " quota warning", $"{state.Remaining:0}% remaining. Your {threshold}% warning threshold was reached.", true));
            }
        }
        if (!options.PredictiveWarnings) { state.PaceWarned = false; return; }
        if (kind is not ("primary" or "secondary") || state.Owner == "") return;
        var pace = provider.Object("presentation").Object("pace").Object(kind);
        if (!DateTimeOffset.TryParse(window.Text("resetAt"), out var reset)) return;
        var minutes = window.Number("windowMinutes");
        var tolerance = minutes.HasValue ? Math.Max(minutes.Value * 30, 300) : 300;
        if (state.PaceReset.HasValue && Math.Abs((reset - state.PaceReset.Value).TotalSeconds) >= tolerance) state.PaceWarned = false;
        state.PaceReset = reset;
        if (pace.Object("willLastToReset").ValueKind == JsonValueKind.True) { state.PaceWarned = false; return; }
        if (pace.Object("willLastToReset").ValueKind != JsonValueKind.False || pace.Number("etaSeconds") is not double eta || eta <= 0 || !double.IsFinite(eta) || (pace.Number("runOutProbability") ?? 1) < .5 || state.PaceWarned) return;
        state.PaceWarned = true;
        alerts.Add(new(id, provider.Text("name") + " " + window.Text("label") + " pace warning", "At this pace, quota may run out in " + (eta >= 3600 ? $"{(int)(eta / 3600)}h {(int)(eta % 3600 / 60)}m" : $"{Math.Max(1, (int)(eta / 60))}m") + " before reset.", true));
    }
}
