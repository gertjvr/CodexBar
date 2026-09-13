import Foundation

@main
enum TraySnapshotSmoke {
    static func main() throws {
        var state = TrayPresentationState()
        let snapshot = try TraySnapshot.decode(self.fixture())
        state.accept(snapshot)
        precondition(state.selectedProviderID == "codex")
        precondition(state.identity?.accountEmail == "codex@example.test")
        precondition(state.windows.count == 1, "Idle model windows must stay hidden")
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

        let empty = try TraySnapshot.decode(self.fixture(providers: false))
        state.accept(empty)
        precondition(state.provider == nil && state.identity == nil && state.windows.isEmpty)
        do {
            _ = try TraySnapshot.decode(self.fixture(version: 2))
            preconditionFailure("Unsupported dashboard schema was accepted")
        } catch TraySnapshot.DecodeError.unsupportedSchema(2) {}
        print(
            "Tray snapshot checks passed: dashboard JSON, idle windows, provider/account isolation, and refresh state")
    }

    private static func fixture(version: Int = 1, providers: Bool = true) throws -> Data {
        let window: [String: Any] = [
            "kind": "primary", "label": "Session", "usedPercent": 125, "remainingPercent": 0,
        ]
        var idleWindow = window
        idleWindow["idle"] = true
        let account: [String: Any] = ["id": "account", "label": "Fixture", "active": false, "windows": [window]]
        let rows: [[String: Any]] = ["codex", "claude", "disabled"].enumerated().map { index, id in
            var row: [String: Any] = [
                "id": id, "name": id.capitalized, "enabled": id != "disabled", "source": "fixture",
                "windows": [window, idleWindow], "accounts": [account],
                "display": ["accentColor": "#2468AC", "sortKey": index, "priority": "primary"],
                "futureAdditiveField": "ignored",
            ]
            if id == "codex" {
                row["identity"] = ["accountEmail": "codex@example.test", "plan": "Fixture"]
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
