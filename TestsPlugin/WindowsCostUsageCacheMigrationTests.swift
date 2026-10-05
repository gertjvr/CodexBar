import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct WindowsCostUsageCacheMigrationTests {
    private static let shippedParserHash = "47443f6ee10929b9"

    @Test
    func `an unsupported SQLite file control must preserve stored history`() {
        #expect(!CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.sqlite(SQLITE_NOTFOUND)))
    }

    @Test
    func `Windows cost store reuses its held database across repeated writes and reopen`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Windows cost reuse \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CostUsageStore(cacheRoot: root)
        for index in 1...3 {
            var aggregate = CostUsageStoreDayAggregate.zero(day: "2026-08-01", model: "gpt-5.4")
            aggregate.inputTokens = Int64(index)
            #expect(await store.mergeDayAggregates([aggregate]))
            #expect(await store.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        }
        let before = await store.readSnapshot()
        #expect(before.dayAggregates.count == 1)
        #expect(before.dayAggregates.first?.inputTokens == 6)
        #expect(await store.rebuildCount == 0)
        await store.closeConnectionForTesting()
        let reopened = CostUsageStore(cacheRoot: root)
        #expect(await reopened.readSnapshot() == before)
        #expect(await reopened.rebuildCount == 0)
        await reopened.closeConnectionForTesting()
    }

    @Test
    func `shipped Windows cache keeps legacy rows after source logs are deleted`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Windows cost migration \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archived session.jsonl")
        try Data("archived history\n".utf8).write(to: source)
        // The shipped fork and upstream have identical v3 SQLite tables. These payloads retain
        // the shipped row/details shape, before optional fork accounting and request-ledger fields.
        #expect(CostUsageStore.baseSchemaVersion == 3)
        let predecessor = CostUsageStore(
            cacheRoot: root,
            schemaVersion: CostUsageStore.combinedSchemaVersion(base: 3, parserHash: Self.shippedParserHash),
            parserHash: Self.shippedParserHash)
        let details = Data(#"""
        {"hasRows":true,"hasTurnIDs":true,"hasTokenSnapshots":true,"hasSeenRawTotals":false,
         "costCacheComplete":true,"parserRevision":2,"hasExactUsageRowIndex":true}
        """#.utf8)
        let legacyRow = Data(#"""
        {"day":"2026-08-01","model":"gpt-5.4","rawModel":"gpt-5.4","turnID":"retained-turn",
         "eventIndex":0,"timestampUnixMs":1785585600000,"input":100,"cached":20,"output":30,
         "reasoning":10,"knownCostNanos":5000,"pricingModel":"gpt-5.4","pricingMode":"priority"}
        """#.utf8)
        let file = CostUsageStoreFile(
            path: source.path,
            inode: nil,
            mtimeUnixMs: 1_785_585_600_000,
            size: 17,
            parsedBytes: 17,
            anchor: nil,
            scanState: .init(
                targetSize: 17,
                isComplete: true,
                resumePayload: nil,
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: 1,
                lastModel: "gpt-5.4",
                lastTurnID: "retained-turn",
                fileIdentity: "synthetic-volume:synthetic-file",
                detailsPayload: details),
            sessionID: "retained-session",
            coverageSinceDay: "2026-08-01",
            coverageUntilDay: "2026-08-01",
            updatedAtUnixMs: 1_785_585_600_000)
        let row = CostUsageStoreUsageRow(path: source.path, rowIndex: 0, payload: legacyRow)
        let totals = CostUsageStoreTotals(input: 100, cached: 20, output: 30, reasoning: 10)
        let token = CostUsageStoreTokenSnapshot(
            path: source.path,
            eventIndex: 0,
            timestamp: "2026-08-01T12:00:00Z",
            timestampUnixMs: 1_785_585_600_000,
            day: "2026-08-01",
            last: totals,
            total: totals,
            endOffset: 17)
        var aggregate = CostUsageStoreDayAggregate.zero(day: "2026-08-01", model: "gpt-5.4")
        aggregate.inputTokens = 100
        aggregate.cachedTokens = 20
        aggregate.outputTokens = 30
        aggregate.reasoningTokens = 10
        aggregate.requestCount = 1
        aggregate.authoritativeCostNanos = 5000
        aggregate.priorityInputTokens = 100
        aggregate.priorityCachedTokens = 20
        aggregate.priorityOutputTokens = 30
        aggregate.priorityTokens = 130
        #expect(await predecessor.upsertFile(file))
        #expect(await predecessor.replaceUsageRows(path: source.path, rows: [row]))
        #expect(await predecessor.appendTokenSnapshots([token]))
        #expect(await predecessor.replaceFileDayAggregates(path: source.path, aggregates: [aggregate]))
        #expect(await predecessor.mergeDayAggregates([aggregate]))
        let before = await predecessor.readSnapshot()
        await predecessor.closeConnectionForTesting()
        try FileManager.default.removeItem(at: source)

        for _ in 0..<2 {
            let current = CostUsageStore(cacheRoot: root)
            #expect(await current.readSnapshot() == before)
            #expect(await current.rebuildCount == 0)
            #expect(await current.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
            let cache = current.syncLoadCodexCache(calendar: .current)
            let restored = try #require(cache.files[source.path])
            let expectedRow = try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: legacyRow)
            #expect(restored.codexRows == [expectedRow])
            #expect(restored.codexRows?.first?.responseID == nil)
            #expect(restored.codexRequestLedgerState == nil)
            #expect(restored.codexForkAccountingState == nil)
            #expect(restored.codexParserRevision == 2)
            #expect(restored.hasCurrentCodexParser == false)
            #expect(restored.codexTokenSnapshots?.count == 1)
            #expect(restored.days["2026-08-01"]?["gpt-5.4"] == [100, 20, 30])
            #expect(!FileManager.default.fileExists(atPath: source.path))
            await current.closeConnectionForTesting()
        }
    }

    @Test
    func `shipped hash cannot authorize a different SQLite schema version`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Windows incompatible cost migration \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let version = CostUsageStore.combinedSchemaVersion(base: 3, parserHash: Self.shippedParserHash)
        let predecessor = CostUsageStore(
            cacheRoot: root,
            schemaVersion: version + 1,
            parserHash: Self.shippedParserHash)
        #expect(await predecessor.mergeDayAggregates([.zero(day: "2026-08-01", model: "gpt-5.4")]))
        await predecessor.closeConnectionForTesting()
        let current = CostUsageStore(cacheRoot: root)
        #expect(await current.readSnapshot().dayAggregates.isEmpty)
        #expect(await current.rebuildCount == 1)
        await current.closeConnectionForTesting()
    }
}
