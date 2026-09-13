using System.Text.Json;
using CodexBar.Tray;

static JsonElement Json(string value) { using var doc = JsonDocument.Parse(value); return doc.RootElement.Clone(); }
static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var now = DateTimeOffset.Parse("2026-09-13T12:00:00Z");
var usage = Json("""
{"provider":"codex","usage":{"identity":{"providerID":"codex","accountEmail":"codex@example.test","loginMethod":"Pro"},"updatedAt":"2026-09-13T10:00:00Z","secondary":{"usedPercent":72},"extraRateWindows":[{"id":"spark","title":"Codex Spark","window":{"usedPercent":0}},{"id":"unknown","usageKnown":false,"window":{"usedPercent":100}}],"codexResetCredits":{"credits":[{"status":"available","expires_at":"2026-09-14T00:00:00Z"},{"status":"available","expires_at":"2026-09-12T00:00:00Z"},{"status":"redeemed"}]}},"pace":{"secondary":{"expectedUsedPercent":11,"summary":"61% in deficit"}},"openaiDashboard":{"accountID":"must-not-copy","codeReviewRemainingPercent":29}}
""");
var costs = Json("""
{"provider":"codex","sessionTokens":18000000,"last30DaysTokens":350000000,"last30DaysCostUSD":123,"historyCoverageIsEstablished":true,"daily":[{"date":"2026-08-01","totalCost":999},{"date":"2026-09-12","totalCost":4},{"date":"2026-09-14","totalCost":999}]}
""");
var projected = CliSnapshot.Project("codex", "Codex", usage, costs, default, now);
Check(projected.Rows("windows").Count() == 2, "Unknown named windows must not become exhausted quotas");
Check(projected.Rows("windows").First().Number("remainingPercent") == 28, "Remaining quota must preserve the CLI semantics");
Check(projected.Object("presentation").Object("pace").Object("secondary").Text("summary") == "61% in deficit", "Reuse the CLI pace");
Check(projected.Object("presentation").Rows("resetCreditExpiries").Count() == 1, "Exclude expired/redeemed reset credits");
Check(!projected.GetRawText().Contains("must-not-copy"), "Do not copy raw dashboard account identifiers");
Check(projected.Object("cost").Number("todayUSD") == 0, "Established history with no today row means zero");
Check(projected.Object("cost").Object("history").Rows("daily").Count() == 1, "Limit history to the current 30-day window");
var unknown = CliSnapshot.Project("codex", "Codex", usage, Json("""{"provider":"codex","daily":[]} """), default, now);
Check(unknown.Object("cost").Number("todayUSD") == null, "Unknown history must not become zero spending");
var stale = CliSnapshot.Project("codex", "Codex", default, default, projected, now, "Offline", "Cost offline");
Check(stale.Object("identity").Text("accountEmail") == "codex@example.test" && stale.Text("updatedAt") == "2026-09-13T10:00:00Z", "Retain last data and timestamp on failure");
Check(stale.Object("error").Text("message") == "Offline" && stale.Text("costError") == "Cost offline", "Mark retained data as stale");
var claude = CliSnapshot.Project("claude", "Claude", Json("""{"provider":"claude","usage":{"identity":{"providerID":"codex","accountEmail":"wrong@example.test"}},"openaiDashboard":{"codeReviewRemainingPercent":29}}"""), default, projected, now);
Check(claude.Object("identity").Text("accountEmail") == "" && claude.Object("cost").ValueKind == JsonValueKind.Undefined, "Never reuse another provider's identity or costs");
Check(claude.Object("presentation").Number("codeReviewRemainingPercent") == null, "Codex extras must not leak into Claude");
try { CliSnapshot.Project("claude", "Claude", usage, default, default, now); throw new Exception("Accepted wrong provider"); }
catch (InvalidDataException) { }
var hiddenBalance = CliSnapshot.Project("codex", "Codex", Json("""{"provider":"codex","usage":{},"credits":{"remaining":0,"balanceReadSucceeded":false}}"""), default, default, now);
Check(hiddenBalance.Object("credits").Number("remaining") == null, "An unread balance must not become zero credits");
Console.WriteLine("PASS: CLI projection, history coverage, optional fields, stale data and provider isolation.");

var projectCosts = Json("""
{"provider":"codex","currencyCode":"USD","daily":[{"date":"2026-09-12","totalTokens":1500,"modelBreakdowns":[{"modelName":"example-model","totalTokens":1500}]}],"projects":[{"name":"Example","path":"C:/example","totalTokens":1500,"sources":[{"name":"Worktree","totalTokens":1500}]}]}
""");
var fullCost = CliSnapshot.Project("codex", "Codex", usage, projectCosts, default, now).Object("cost");
Check(fullCost.Rows("projects").Single().Rows("sources").Single().Number("totalTokens") == 1500, "Preserve nested project sources for the cost flyout");
Check(fullCost.Object("history").Rows("daily").Single().Rows("modelBreakdowns").Single().Number("cost") == null, "Token-only model activity must not acquire a zero price");
Console.WriteLine("PASS: Cost flyout projects and unpriced model activity.");

var sevenDays = CliSnapshot.Project("codex", "Codex", usage, Json("""{"provider":"codex","historyDays":7,"daily":[{"date":"2026-09-01","totalCost":50},{"date":"2026-09-12","totalCost":2}]}"""), default, now).Object("cost");
Check(sevenDays.Number("historyDays") == 7 && sevenDays.Object("history").Rows("daily").Count() == 1, "Use the returned history window, not a hard-coded thirty days");
var preferences = new Preferences();
preferences.SetVisible("codex", "secondary", false);
preferences.Accents["codex"] = "invalid";
var restored = JsonSerializer.Deserialize<Preferences>(JsonSerializer.Serialize(preferences))!;
Check(!restored.Visible("codex", "secondary") && restored.Visible("claude", "secondary"), "Saved visibility must remain provider-specific");
Check(restored.Accent("codex") == "49A3B0", "Invalid saved colors fall back safely");
Console.WriteLine("PASS: Selected history window and provider preference persistence.");

var calendar = CostHistory.Calendar(sevenDays, now);
Check(calendar.Length == 7 && calendar[0].Text("date") == "2026-09-07" && calendar[^1].Text("date") == "2026-09-13", "Sparse history keeps calendar spacing and requested range");
Check(calendar[0].Number("totalCost") == null && calendar[^2].Number("totalCost") == 2, "Missing days stay unknown while recorded values survive");
Console.WriteLine("PASS: Sparse calendar history and unknown buckets.");

static JsonElement NotificationSample(double remaining, DateTimeOffset observed, DateTimeOffset? reset = null, string owner = "owner@example.test", double eta = 0, bool lasts = true, string source = "oauth", bool failed = false)
{
    return JsonSerializer.SerializeToElement(new { providers = new[] { new { id = "codex", name = "Codex", source, updatedAt = observed, identity = new { accountEmail = owner }, error = failed ? new { message = "Offline" } : null, windows = new[] { new { kind = "primary", label = "Session", remainingPercent = remaining, resetAt = reset, windowMinutes = 300 } }, presentation = new { pace = new { primary = new { etaSeconds = eta, willLastToReset = lasts } } } } } });
}
var notificationOptions = new NotificationOptions { ThresholdWarnings = true, SessionTransitions = false };
var policy = new NotificationPolicy();
Check(policy.Observe(NotificationSample(10, now), notificationOptions, now).Single().Message.Contains("20%"), "First low observation emits only the most critical crossed threshold");
Check(policy.Observe(NotificationSample(5, now.AddSeconds(1)), notificationOptions, now.AddSeconds(1)).Count == 0, "Repeated low observations do not repeat alerts");
Check(policy.Observe(NotificationSample(60, now.AddSeconds(2)), notificationOptions, now.AddSeconds(2)).Count == 0, "Recovery rearms thresholds without a warning");
Check(policy.Observe(NotificationSample(40, now.AddSeconds(3)), notificationOptions, now.AddSeconds(3)).Single().Message.Contains("50%"), "A recovered threshold can fire on a later crossing");
Check(policy.Observe(NotificationSample(0, now.AddSeconds(4), failed: true), notificationOptions, now.AddSeconds(4)).Count == 0, "Failed refreshes cannot trigger alerts");
Check(policy.Observe(NotificationSample(0, now), notificationOptions, now.AddSeconds(5)).Count == 0, "Out-of-order usage cannot trigger alerts");
Check(policy.Observe(NotificationSample(0, now.AddSeconds(5), owner: "other@example.test"), notificationOptions, now.AddSeconds(5)).Count == 0, "Account changes establish a new baseline");
var transitions = new NotificationPolicy();
var transitionOptions = new NotificationOptions();
Check(transitions.Observe(NotificationSample(0, now, now.AddHours(1)), transitionOptions, now).Single().Title.EndsWith("depleted"), "Initial depletion is reported");
Check(transitions.Observe(NotificationSample(100, now.AddMinutes(1), now.AddHours(6)), transitionOptions, now.AddMinutes(1)).Count == 0, "Codex restore cannot outrun the trusted reset boundary");
Check(transitions.Observe(NotificationSample(100, now.AddHours(1), now.AddHours(6)), transitionOptions, now.AddHours(1)).Single().Title.EndsWith("restored"), "A fresh advanced boundary confirms restoration after reset");
var ambiguous = new NotificationPolicy();
ambiguous.Observe(NotificationSample(0, now), transitionOptions, now);
Check(ambiguous.Observe(NotificationSample(80, now.AddSeconds(1)), transitionOptions, now.AddSeconds(1)).Count == 0, "Untrusted restore needs confirmation");
Check(ambiguous.Observe(NotificationSample(80, now.AddSeconds(2)), transitionOptions, now.AddSeconds(2)).Single().Title.EndsWith("restored"), "Two fresh positive observations confirm an ambiguous restore");
var predictive = new NotificationPolicy();
var predictiveOptions = new NotificationOptions { SessionTransitions = false, PredictiveWarnings = true };
Check(predictive.Observe(NotificationSample(30, now, now.AddHours(4), eta: 3600, lasts: false), predictiveOptions, now).Count == 1, "Reuse CLI exhaustion forecasts for pace warnings");
Check(predictive.Observe(NotificationSample(29, now.AddSeconds(1), now.AddHours(4).AddSeconds(1), eta: 3500, lasts: false), predictiveOptions, now.AddSeconds(1)).Count == 0, "Small reset-time corrections cannot repeat pace alerts");
Check(predictive.Observe(NotificationSample(80, now.AddSeconds(2), now.AddHours(4)), predictiveOptions, now.AddSeconds(2)).Count == 0, "Sustainable pace clears the warning latch");
Check(predictive.Observe(NotificationSample(20, now.AddSeconds(3), now.AddHours(4), eta: 3400, lasts: false), predictiveOptions, now.AddSeconds(3)).Count == 1, "Pace warnings rearm after recovery");
var overrides = new NotificationOptions();
overrides.Overrides["codex:primary"] = new WarningOverride { Mode = "off" };
Check(overrides.Thresholds("codex", "primary").Length == 0 && overrides.Thresholds("claude", "primary").SequenceEqual(new[] { 50, 20 }), "Provider overrides stay isolated");
Console.WriteLine("PASS: Notification transitions, thresholds, stale data, account isolation, restore confirmation and pace deduplication.");

var distinctClaude = CliSnapshot.Project("claude", "Claude", Json("""{"provider":"claude","usage":{"primary":{"usedPercent":75,"windowMinutes":300},"secondary":{"usedPercent":12,"windowMinutes":10080}},"status":{"description":"Partial degradation","updatedAt":"2026-09-13T00:00:00Z","components":[{"id":"api","name":"APIs","status":"operational","indicator":"none","children":[{"id":"child","name":"Service","status":"operational"}]}]}}"""), default, default, now);
Check(distinctClaude.Rows("windows").Single(w => w.Text("kind") == "primary").Number("remainingPercent") == 25, "Claude session remains distinct");
Check(distinctClaude.Rows("windows").Single(w => w.Text("kind") == "secondary").Number("remainingPercent") == 88, "Claude weekly must not reuse its five-hour value");
Check(distinctClaude.Object("status").Rows("components").Single().Rows("children").Single().Text("id") == "child", "Status groups preserve children");
Console.WriteLine("PASS: Distinct Claude windows and nested status details.");
