import Foundation
@testable import CodexBarCore

func makeAntigravitySnapshotDependencies(
    pollIntervalNanoseconds: UInt64,
    listeningPorts: @escaping @Sendable (Int, TimeInterval) async throws -> [Int],
    drainOutput: @escaping @Sendable () async -> Data,
    fetchSnapshot: @escaping @Sendable ([Int]) async throws -> AntigravityStatusSnapshot,
    now: @escaping @Sendable () -> Date = Date.init)
    -> AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies
{
    .init(
        pollIntervalNanoseconds: pollIntervalNanoseconds,
        listeningPorts: listeningPorts,
        drainOutput: drainOutput,
        fetchSnapshot: fetchSnapshot,
        now: now)
}

func makeAntigravityWarmDependencies(
    processInfos: @escaping @Sendable (TimeInterval) async throws -> [AntigravityStatusProbe.ProcessInfoResult],
    listeningPorts: @escaping @Sendable (Int, TimeInterval) async throws -> [Int],
    fetchSnapshot: @escaping @Sendable ([Int], TimeInterval) async throws -> AntigravityStatusSnapshot,
    processOwnerUserID: @escaping @Sendable (Int) -> String? = { _ in "0" },
    currentUserID: @escaping @Sendable () -> String = { "0" },
    ownedPID: @escaping @Sendable () async -> Int? = { nil },
    now: @escaping @Sendable () -> Date = Date.init)
    -> AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies
{
    .init(
        processInfos: processInfos,
        listeningPorts: listeningPorts,
        fetchSnapshot: fetchSnapshot,
        processOwnerUserID: processOwnerUserID,
        currentUserID: currentUserID,
        ownedPID: ownedPID,
        now: now)
}
