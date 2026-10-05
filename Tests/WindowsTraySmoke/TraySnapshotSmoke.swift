import Foundation

@main
enum TraySnapshotSmoke {
    static func main() throws {
        var state = TrayPresentationState()
        let snapshot = try TraySnapshot.decode(self.fixture())
        state.accept(snapshot)
        precondition(state.selectedProviderID == "codex")
        precondition(state.identity?.accountEmail == "codex@example.test")
        precondition(state.windows.count == 1, "Idle and unknown model windows must stay hidden")
        precondition(state.windows[0].usedPercent == 125 && state.windows[0].filledFraction == 1)
        precondition(state.displayError == "Ambient account failure")
        precondition(state.selectAccount("account"))
        precondition(state.displayError == nil, "Selected account must not inherit the ambient account error")
        precondition(state.identity == nil, "Account without identity must not inherit the ambient account")
        precondition(state.selectProvider("claude"))
        precondition(state.selectedAccountID == nil, "Account selection leaked across providers")
        precondition(state.identity == nil, "Provider identity leaked across providers")
        precondition(!state.selectProvider("disabled"))
        precondition(!state.selectAccount("missing"))
        state.failed("Fixture refresh failed")
        precondition(state.snapshot == snapshot && state.refreshError != nil)
        state.accept(snapshot)
        precondition(state.selectedProviderID == "claude" && state.refreshError == nil)

        precondition(state.selectProvider("codex"))
        try state.accept(TraySnapshot.decode(self.fixture(identityEmail: "redacted@example.test")))
        precondition(state.identity?.accountEmail == "redacted@example.test", "CLI identity redaction was discarded")
        try state.accept(TraySnapshot.decode(self.fixture(identityEmail: nil)))
        precondition(state.identity == nil, "A privacy-filtered snapshot retained previous personal information")
        try self.checkCostPresentation()
        try self.checkUnknownWindowPresentation()

        let empty = try TraySnapshot.decode(self.fixture(providers: false))
        state.accept(empty)
        precondition(state.provider == nil && state.identity == nil && state.windows.isEmpty)
        do {
            _ = try TraySnapshot.decode(self.fixture(version: 2))
            preconditionFailure("Unsupported dashboard schema was accepted")
        } catch TraySnapshot.DecodeError.unsupportedSchema(2) {}
        print(
            "Tray snapshot checks passed: dashboard JSON, unknown quotas, partial costs, privacy, " +
                "account isolation, and refresh state")
    }

    private static func checkUnknownWindowPresentation() throws {
        var state = TrayPresentationState()
        let mixed = try TraySnapshot.decode(self.fixture())
        state.accept(mixed)
        let provider = try self.requireProvider(state)
        precondition(provider.windows.first?.usageKnown == false)
        precondition(provider.windows.first?.remainingPercent == 100)
        precondition(
            state.windows.count == 1 && state.windows.first?.usageKnown == nil,
            "Legacy quota windows with no usageKnown field must remain visible")
        precondition(
            provider.windows.first(where: \.isDisplayable) == state.windows.first,
            "Provider selection bars and selected provider details must use the same known quota")
        precondition(state.selectAccount("account"))
        precondition(
            state.windows.count == 1 && state.windows.first?.usageKnown == nil,
            "Selected accounts must hide unknown quota lanes too")

        try state.accept(TraySnapshot.decode(self.fixture(includeKnownWindows: false)))
        precondition(state.windows.isEmpty, "An unknown quota must not become 100 percent remaining")
        let unknownProvider = try self.requireProvider(state)
        precondition(!unknownProvider.windows.contains(where: \.isDisplayable))
        precondition(
            state.selectAccount(nil) && state.windows.isEmpty,
            "Returning to the ambient account must not reveal an unknown quota")

        let decoder = JSONDecoder()
        let knownZero = try decoder.decode(TraySnapshot.Window.self, from: JSONSerialization.data(withJSONObject: [
            "kind": "extra", "label": "Known zero usage", "usedPercent": 0,
            "remainingPercent": 100, "usageKnown": true,
        ]))
        precondition(
            knownZero.isDisplayable && knownZero.remainingPercent == 100,
            "A genuinely known unused quota must remain visible")
        let unknown = try decoder.decode(TraySnapshot.Window.self, from: JSONSerialization.data(withJSONObject: [
            "kind": "extra", "label": "Unknown usage", "usedPercent": 75,
            "remainingPercent": 25, "usageKnown": false,
        ]))
        precondition(
            !unknown.isDisplayable && unknown.filledFraction == 0,
            "Unknown quota values must not contribute to usage icons or bars")
    }

    private static func requireProvider(_ state: TrayPresentationState) throws -> TraySnapshot.Provider {
        guard let provider = state.provider else { throw CocoaError(.fileReadCorruptFile) }
        return provider
    }

    private static func checkCostPresentation() throws {
        let exact = try self.cost(["todayUSD": 0, "last30DaysUSD": 23.6])
        precondition(exact.displayRows.map(\.text) == ["Today: $0.00", "Last 30 days: $23.60"])
        precondition(exact.displayRows.allSatisfy { $0.warning == nil })

        let partial = try self.cost([
            "todayUSD": 0.34,
            "last30DaysUSD": 23.6,
            "todayIncompleteRequestCount": 1,
            "last30DaysIncompleteRequestCount": 5,
        ])
        precondition(partial.displayRows.map(\.text) == ["Today: At least $0.34", "Last 30 days: At least $23.60"])
        precondition(partial.displayRows.map(\.warning) == [
            "1 request missing token usage", "5 requests missing token usage",
        ])

        let unknown = try self.cost([
            "todayUSD": NSNull(), "last30DaysUSD": NSNull(),
            "todayIncompleteRequestCount": 2, "last30DaysIncompleteRequestCount": 7,
        ])
        precondition(unknown.todayUSD == nil && unknown.last30DaysUSD == nil)
        precondition(unknown.displayRows.map(\.text) == ["Today: Unavailable", "Last 30 days: Unavailable"])
        precondition(unknown.displayRows.allSatisfy { !$0.text.contains("$0.00") })

        let independentPeriods = try self.cost([
            "todayUSD": 1.2, "last30DaysUSD": 12.3, "last30DaysIncompleteRequestCount": 3,
        ])
        precondition(independentPeriods.displayRows.map(\.text) == ["Today: $1.20", "Last 30 days: At least $12.30"])
        precondition(independentPeriods.displayRows.first?.warning == nil)
        let partialScan = try self.cost([
            "todayUSD": 0.5, "last30DaysUSD": 8.75, "historyScanIsPartial": true,
        ])
        precondition(partialScan.displayRows.map(\.text) == ["Today: At least $0.50", "Last 30 days: At least $8.75"])
        precondition(partialScan.displayRows.allSatisfy { $0.historyWarning == "Partial local history" })
        precondition(partialScan.displayRows.allSatisfy { $0.warning == nil })
        let unknownPartialScan = try self.cost([
            "todayUSD": NSNull(), "last30DaysUSD": NSNull(), "historyScanIsPartial": true,
        ])
        precondition(unknownPartialScan.todayUSD == nil && unknownPartialScan.last30DaysUSD == nil)
        precondition(unknownPartialScan.displayRows.map(\.text) == ["Today: Unavailable", "Last 30 days: Unavailable"])
        precondition(unknownPartialScan.displayRows.allSatisfy { $0.historyWarning == "Partial local history" })
        let fullScan = try self.cost([
            "todayUSD": 0.5, "last30DaysUSD": 8.75, "historyScanIsPartial": false,
        ])
        precondition(fullScan.displayRows.map(\.text) == ["Today: $0.50", "Last 30 days: $8.75"])
        precondition(fullScan.displayRows.allSatisfy { $0.historyWarning == nil })
        let unavailable = try self.cost(["todayUSD": NSNull(), "last30DaysUSD": NSNull()])
        precondition(unavailable.displayRows.isEmpty)
    }

    private static func cost(_ values: [String: Any]) throws -> TraySnapshot.Cost {
        let snapshot = try TraySnapshot.decode(self.fixture(cost: values))
        guard let cost = snapshot.providers.first?.cost else { throw CocoaError(.fileReadCorruptFile) }
        return cost
    }

    private static func fixture(
        version: Int = 1,
        providers: Bool = true,
        identityEmail: String? = "codex@example.test",
        cost: [String: Any]? = nil,
        includeKnownWindows: Bool = true) throws -> Data
    {
        let window: [String: Any] = [
            "kind": "primary", "label": "Session", "usedPercent": 125, "remainingPercent": 0,
        ]
        var idleWindow = window
        idleWindow["idle"] = true
        let unknownWindow: [String: Any] = [
            "kind": "extra", "label": "Unknown model quota", "usedPercent": 0,
            "remainingPercent": 100, "usageKnown": false,
        ]
        let windows = includeKnownWindows ? [unknownWindow, window, idleWindow] : [unknownWindow, idleWindow]
        let account: [String: Any] = [
            "id": "account", "label": "Fixture", "active": false,
            "windows": includeKnownWindows ? [unknownWindow, window] : [unknownWindow],
        ]
        let rows: [[String: Any]] = ["codex", "claude", "disabled"].enumerated().map { index, id in
            var row: [String: Any] = [
                "id": id, "name": id.capitalized, "enabled": id != "disabled", "source": "fixture",
                "windows": windows, "accounts": [account],
                "display": ["accentColor": "#2468AC", "sortKey": index, "priority": "primary"],
                "futureAdditiveField": "ignored",
            ]
            if id == "codex" {
                if let identityEmail { row["identity"] = ["accountEmail": identityEmail, "plan": "Fixture"] }
                if let cost { row["cost"] = cost }
                row["error"] = ["code": 1, "message": "Ambient account failure"]
            }
            return row
        }
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": version,
            "generatedAt": "2026-09-12T00:00:00Z",
            "staleAfterSeconds": 180,
            "host": ["codexBarVersion": "fixture", "refreshIntervalSeconds": 120],
            "providers": providers ? rows : [],
        ])
    }
}
