import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCostCachePortabilityTests {
    @Test
    func `streamed Claude cache replaces Unicode artifacts and keeps identical content stamps`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Claude cache café \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await CostUsageClaudeCacheIO.withIsolatedCachesForTesting {
            let source = root.appendingPathComponent("session café.jsonl").path
            var cache = CostUsageClaudeCache()
            cache.usage.files[source] = CostUsageFileUsage(
                mtimeUnixMs: 1000,
                size: 50,
                days: ["2026-08-01": ["claude-sonnet-4-6": [10, 2, 0, 3]]])
            let first = try #require(try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root))
            var updated = cache
            updated.usage.files[source]?.days = ["2026-08-01": ["claude-sonnet-4-6": [20, 2, 0, 3]]]
            let second = try #require(try CostUsageClaudeCacheIO.save(
                provider: .claude, cache: updated, cacheRoot: root))
            #expect(second != first)
            let artifact = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
            CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: artifact)
            let reopened = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: root)
            #expect(reopened.usage.files[source]?.days == updated.usage.files[source]?.days)
            let bytes = try Data(contentsOf: artifact)
            let third = try #require(try CostUsageClaudeCacheIO.save(
                provider: .claude, cache: reopened, cacheRoot: root))
            #expect(third == second)
            #expect(try Data(contentsOf: artifact) == bytes)
            var cancelled = reopened
            cancelled.usage.files[source]?.size += 1
            var cancellationChecks = 0
            #expect(throws: CancellationError.self) {
                try CostUsageClaudeCacheIO.save(
                    provider: .claude, cache: cancelled, cacheRoot: root, checkCancellation: {
                        cancellationChecks += 1
                        if cancellationChecks == 2 { throw CancellationError() }
                    })
            }
            #expect(cancellationChecks == 2)
            #expect(CostUsageClaudeFileStamp.read(at: artifact) == second)
            #expect(try Data(contentsOf: artifact) == bytes)
            let names = try FileManager.default.contentsOfDirectory(atPath: artifact.deletingLastPathComponent().path)
            #expect(!names.contains { $0.hasPrefix(".claude-cache-") })
            #expect(try CostUsageClaudeCacheIO.save(provider: .claude, cache: cancelled, cacheRoot: root) != nil)
        }
    }
}
