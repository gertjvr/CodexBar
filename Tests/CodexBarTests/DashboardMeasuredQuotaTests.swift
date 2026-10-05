import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardMeasuredQuotaTests {
    @Test
    func `dashboard omits unknown quotas while keeping measured zero usage`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let measured = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        let usage = UsageSnapshot(
            primary: placeholder,
            secondary: measured,
            tertiary: placeholder,
            extraRateWindows: [
                NamedRateWindow(id: "unknown", title: "Unknown", window: measured, usageKnown: false),
                NamedRateWindow(id: "placeholder", title: "Placeholder", window: placeholder),
                NamedRateWindow(id: "measured", title: "Measured", window: measured),
            ],
            updatedAt: now)
        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "fixture",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .none,
            generatedAt: now,
            refreshInterval: 60,
            codexBarVersion: nil)
        let windows = try #require(snapshot.providers.first?.windows)
        #expect(windows.map(\.kind) == ["weekly", "measured"])
        #expect(windows.allSatisfy { $0.usedPercent == 0 && $0.remainingPercent == 100 })
    }
}
