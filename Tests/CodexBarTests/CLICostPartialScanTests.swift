import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICostPartialScanTests {
    @Test(arguments: [true, false])
    func `CLI and dashboard preserve partial scans even without known money or excluded requests`(
        partial: Bool) throws
    {
        let now = Date(timeIntervalSince1970: 0)
        let history = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyScanIsPartial: partial,
            daily: [],
            updatedAt: now)
        let cost = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: history, error: nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cost)) as? [String: Any])
        #expect((object["historyScanIsPartial"] as? Bool) == (partial ? true : nil))
        #expect(object["incompleteRequestCount"] == nil)
        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "fixture",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [cost],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .none,
            generatedAt: now,
            refreshInterval: 60,
            codexBarVersion: nil)
        let projected = snapshot.providers.first?.cost
        #expect(projected?.historyScanIsPartial == (partial ? true : nil))
        #expect(projected?.todayUSD == nil)
        #expect(projected?.last30DaysUSD == nil)
        #expect((projected != nil) == partial)
    }
}
