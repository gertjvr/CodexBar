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

var labeledWindows = CliSnapshot.Project("claude", "Claude", Json("""
{"provider":"claude","rateWindowLabels":{"primary":"Daily","secondary":"Monthly","tertiary":"Workspace"},"usage":{"primary":{"usedPercent":10},"secondary":{"usedPercent":20},"tertiary":{"usedPercent":30},"extraRateWindows":[{"id":"unknown","usageKnown":false,"window":{"usedPercent":0}},{"id":"placeholder","window":{"usedPercent":0,"isSyntheticPlaceholder":true}}]}}
"""), default, default, now);
Check(labeledWindows.Rows("windows").Select(w => w.Text("label")).SequenceEqual(new[] { "Daily", "Monthly", "Workspace" }), "Provider-issued quota labels apply to every standard window");
var placeholders = CliSnapshot.Project("claude", "Claude", Json("""
{"provider":"claude","usage":{"primary":{"usedPercent":0,"isSyntheticPlaceholder":true},"secondary":{"usedPercent":0,"isSyntheticPlaceholder":true},"tertiary":{"usedPercent":0,"isSyntheticPlaceholder":true},"extraRateWindows":[{"id":"available","title":"Available","window":{"usedPercent":0}}]}}
"""), default, default, now);
Check(placeholders.Rows("windows").Single().Text("kind") == "available", "Synthetic standard quotas stay hidden while a real zero-use extra remains visible");
Console.WriteLine("PASS: Provider labels, synthetic quotas and unavailable extras.");

foreach (var days in new[] { 7, 30, 90 })
{
    var payload = JsonSerializer.SerializeToElement(new { provider = "codex", historyDays = days, last30DaysCostUSD = 3, last30DaysTokens = 30, totals = new { totalCost = days * 2, totalTokens = days * 100 } });
    var period = CliSnapshot.Project("codex", "Codex", usage, payload, default, now).Object("cost");
    Check(Presentation.PeriodCost(period) == days * 2 && Presentation.PeriodTokens(period) == days * 100, $"The {days}-day presentation must use selected-period totals, even when the legacy thirty-day subtotal differs");
}
var unknownTotals = CliSnapshot.Project("codex", "Codex", usage, Json("""{"provider":"codex","historyDays":90,"last30DaysCostUSD":123,"totals":{"totalTokens":1500},"daily":[]}"""), default, now).Object("cost");
Check(Presentation.PeriodCost(unknownTotals) == null && Presentation.PeriodTokens(unknownTotals) == 1500, "An unknown selected-period price must not fall back to a thirty-day amount");
Check(Presentation.PeriodCost(Json("""{"historyDays":90,"last30DaysUSD":123}""")) == null, "A retained legacy ninety-day snapshot must not mislabel thirty-day costs");
Check(Presentation.PeriodCost(Json("""{"historyDays":30,"last30DaysUSD":0}""")) == 0, "Known zero remains zero for compatible retained snapshots");
var unpricedToday = CliSnapshot.Project("codex", "Codex", usage, Json("""{"provider":"codex","historyCoverageIsEstablished":true,"totals":{"totalCost":4},"daily":[{"date":"2026-09-13","totalTokens":1500}]}"""), default, now).Object("cost");
Check(unpricedToday.Number("todayUSD") == null, "A scanned token-only today row stays unpriced instead of becoming zero");
var partial = CliSnapshot.Project("codex", "Codex", usage, Json("""
{"provider":"codex","updatedAt":"2026-09-13T10:00:00Z","historyDays":90,"historyCoverageIsEstablished":true,"historyScanIsPartial":true,"historyLabel":"Last 90 days","reportingPeriod":"90d","provenance":"mixed","coverage":{"priced":3,"unpriced":2,"unmetered":1,"estimated":4},"incompleteRequestCount":5,"totals":{"totalCost":10,"totalTokens":1000,"incompleteRequestCount":5},"daily":[{"date":"2026-09-12","totalCost":10,"totalTokens":1000,"incompleteRequestCount":5,"modelBreakdowns":[{"modelName":"example-model","cost":10,"totalTokens":1000,"incompleteRequestCount":5}]}]}
"""), default, now).Object("cost");
Check(partial.Number("todayUSD") == null && partial.Object("historyScanIsPartial").ValueKind == JsonValueKind.True, "A partial scan cannot establish a zero-cost missing today bucket");
Check(partial.Object("coverage").Number("unpriced") == 2 && partial.Number("incompleteRequestCount") == 5 && partial.Object("totals").Number("incompleteRequestCount") == 5, "Retain window coverage and aggregate incomplete requests");
Check(partial.Object("history").Rows("daily").Single().Rows("modelBreakdowns").Single().Number("incompleteRequestCount") == 5, "Retain incomplete request markers on daily and model rows");
Check(Presentation.PeriodLabel(partial) == "Last 90 days" && Presentation.IsPartial(partial), "Use the supplied period label and mark partial totals");
Check(Presentation.Amount(partial, Presentation.PeriodCost(partial), Presentation.IsPartial(partial)) == "≥ $10.00", "Known partial amounts display a lower-bound marker");
Check(Presentation.Amount(partial, null, true) == "—" && Presentation.Tokens(null, true) == "—", "Partial unknown values must not become marked zeroes");
var note = Presentation.CostNote(partial);
Check(note.Contains("Metered spend and list-price estimates") && note.Contains("history scan is partial") && note.Contains("2 unpriced") && note.Contains("1 unmetered") && note.Contains("5 incomplete requests"), "Explain provenance and each missing-data category");
Check(Presentation.CostNote(Json("""{"provenance":"vendorMetered"}""" )).StartsWith("Vendor-reported metered spend"), "Metered spend must not be described as a token estimate");
Check(Presentation.DailyValue(Json("""{"totalTokens":1500}"""), true) == "—", "Cost chart hover must keep unpriced buckets unknown");
Check(Presentation.DailyValue(Json("""{"totalCost":0}"""), true) == "$0.00", "Cost chart hover preserves a real zero");
Check(Presentation.DailyValue(Json("""{"totalCost":2,"incompleteRequestCount":3}"""), true).Contains("3 incomplete requests"), "Cost chart hover explains incomplete rows");
Console.WriteLine("PASS: Selected-period totals, unknown prices, partial scans, provenance and incomplete requests.");

var dated = CliSnapshot.Project("codex", "Codex", usage, Json("""
{"provider":"codex","updatedAt":"2026-09-10T12:00:00Z","historyDays":7,"totals":{"totalCost":6},"daily":[{"date":"2026-09-09","totalCost":4},{"date":"2026-09-10","totalCost":2},{"date":"2026-09-12","totalCost":99}]}
"""), default, now);
var retained = CliSnapshot.Project("codex", "Codex", default, default, dated, now.AddDays(10), "Offline", "Cost offline").Object("cost");
var retainedCalendar = CostHistory.Calendar(retained, now.AddDays(10));
Check(retainedCalendar[0].Text("date") == "2026-09-04" && retainedCalendar[^1].Text("date") == "2026-09-10" && retainedCalendar[^1].Number("totalCost") == 2, "Retained cost charts stay anchored to the source date instead of sliding to today");
Check(Presentation.TodayLabel(retained, now.AddDays(10)) == "As of 10 Sep" && retained.Text("updatedAt") == "2026-09-10T12:00:00Z", "Dated retained spending must not be presented as today's spending");
Check(Presentation.TodayLabel(Json("""{"updatedAt":"2026-09-10T12:00:00Z"}"""), now) == "As of 10 Sep", "Legacy retained cost snapshots also use their source date");
Console.WriteLine("PASS: Dated retained cost data and history calendar.");

var privateDetails = Json("""
[{"id":"stable-section","title":"Workspace owner@example.test","rows":[{"id":"stable-row","label":"Account owner@example.test","value":"Assigned to OWNER@example.test","secondaryValue":"Contact owner@example.test","progress":0.5},{"id":"numeric","label":"Count","value":3}],"chart":{"kind":"bar","title":"Quota owner@example.test","unit":"owner@example.test credits","points":[{"label":"owner@example.test monthly","value":42}]}}]
""");
var visibleDetails = Presentation.Details(privateDetails, false);
var redactedDetails = Presentation.Details(privateDetails, true);
Check(visibleDetails.GetRawText() == privateDetails.GetRawText() && !redactedDetails.GetRawText().Contains("@example.test", StringComparison.OrdinalIgnoreCase), "Privacy redacts headings, labels, values, secondary values and chart text only when enabled");
var redactedSection = redactedDetails.EnumerateArray().Single();
Check(redactedSection.Text("id") == "stable-section" && redactedSection.Rows("rows").First().Text("id") == "stable-row" && redactedSection.Rows("rows").First().Number("progress") == 0.5 && redactedSection.Object("chart").Rows("points").Single().Number("value") == 42, "Privacy preserves stable identifiers and numeric presentation data");
Check(privateDetails.GetRawText().Contains("owner@example.test") && redactedSection.Rows("rows").Last().Number("value") == 3, "Redaction leaves the original snapshot intact and preserves numeric row values");
Check(Presentation.Text("Owner owner@example.test : available", true) == "Owner: available" && Presentation.Text("100% available", true) == "100% available", "Inline privacy removes emails without erasing useful quota text");
Console.WriteLine("PASS: Privacy redaction for every detail text field and chart labels.");

var scanOnly = Json("""{"historyScanIsPartial":true,"incompleteRequestCount":0,"coverage":{"unpriced":0,"unmetered":0}}""");
var completeRow = Json("""{"totalCost":2,"cost":2,"totalTokens":1500,"incompleteRequestCount":0}""");
Check(Presentation.DailyValue(completeRow, true, scanOnly) == "≥ $2.00", "A partial scan marks daily chart values even when no requests were excluded from the row");
Check(Presentation.RowValues(scanOnly, completeRow).StartsWith("≥ $2.00 · ≥ ") && Presentation.RowValues(scanOnly, completeRow, "cost").StartsWith("≥ $2.00 · ≥ "), "A partial scan marks day, project, source and model amount and token subtotals with zero exclusions");
Check(Presentation.Tokens(1500, Presentation.ScanIsPartial(scanOnly)).StartsWith("≥ "), "Latest session tokens also carry the partial-scan lower bound");
Check(Presentation.RowValues(scanOnly, Json("""{"totalCost":0,"totalTokens":0}""")) == "≥ $0.00 · ≥ 0 tokens", "Observed zero amounts remain lower bounds when a scan is partial");
Check(Presentation.RowValues(scanOnly, Json("""{}""")) == "— · — tokens", "Partial scans never invent unknown row amounts or token counts");
var pricingOnly = Json("""{"coverage":{"unpriced":2}}""");
Check(Presentation.RowValues(pricingOnly, Json("""{"totalTokens":1500}""")) == "— · " + Data.Tokens(1500) + " tokens", "Unpriced costs alone do not downgrade established token counts");
Check(!Presentation.RowIsPartial(default, completeRow) && Presentation.RowValues(default, completeRow).StartsWith("$2.00 · "), "Complete rows retain exact presentation");
var excludedRow = Json("""{"totalCost":2,"totalTokens":1500,"incompleteRequestCount":3}""");
Check(Presentation.RowValues(default, excludedRow).StartsWith("≥ $2.00 · ≥ ") && Presentation.RowValues(default, excludedRow).EndsWith("3 incomplete requests"), "Per-row exclusions remain visible independently of the global scan flag");
var excludedProject = Json("""{"totalCost":2,"totalTokens":1500,"daily":[{"incompleteRequestCount":3}]}""");
Check(Presentation.RowValues(default, excludedProject).EndsWith("3 incomplete requests"), "Project and source coverage includes their own incomplete daily requests");
Console.WriteLine("PASS: Lower bounds for daily, model, project, source and session values.");

foreach (var address in new[] { "o'connor@example.test", "\"quoted local\"@internal", "worker@internal", "owner@[IPv6:2001:db8::1]" })
{
    var addressDetails = JsonSerializer.SerializeToElement(new[] { new { id = "section", title = address, rows = new[] { new { id = "row", label = address, value = address, secondaryValue = address } }, chart = new { title = address, unit = address, points = new[] { new { label = address, value = 42 } } } } });
    var protectedSection = Presentation.Details(addressDetails, true).EnumerateArray().Single();
    var protectedRow = protectedSection.Rows("rows").Single();
    var protectedChart = protectedSection.Object("chart");
    Check(protectedSection.Text("title") == "" && protectedRow.Text("label") == "" && protectedRow.Text("value") == "" && protectedRow.Text("secondaryValue") == "" && protectedChart.Text("title") == "" && protectedChart.Text("unit") == "" && protectedChart.Rows("points").Single().Text("label") == "", "Uncommon email shapes must be removed completely from every detail text field");
    Check(Presentation.Details(addressDetails, false).GetRawText() == addressDetails.GetRawText(), "Privacy disabled preserves uncommon email shapes");
    Check(Presentation.Text("Owner " + address + " : available", true) == "Owner: available", "Bounded redaction keeps surrounding detail text for uncommon email shapes");
}
Check(Presentation.Text("Primary a@internal; secondary \"unterminated@internal", true).IndexOf('@') == -1, "An unmatched quote after an earlier address cannot break or expose identity redaction");
Console.WriteLine("PASS: Complete bounded redaction for apostrophes, quoted addresses, internal domains and domain literals.");
