import Foundation
import Testing
@testable import CodexBarCore

struct MuseLocalUsagePortabilityTests {
    @Test
    func `local history reads Unicode paths and invalidates same size rotations`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Muse local history café \(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let directory = sessions.appendingPathComponent("2026/08/31/session café", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = directory.appendingPathComponent("session.jsonl")
        let first = Self.record(input: "10")
        try first.write(to: log, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        func report() throws -> MuseLocalUsageReader.DailyReportResult {
            try MuseLocalUsageReader.makeDailyReportWithStatus(
                context: .init(sessionsRoot: sessions), calendar: calendar, cacheRoot: cacheRoot)
        }
        let cold = try report()
        let warm = try report()
        #expect(cold.coverage == .complete)
        #expect(warm.coverage == .complete)
        #expect(cold.report.summary?.totalTokens == 30)
        #expect(warm.report.data == cold.report.data)
        let stamp = try #require(MuseLocalUsageCache.FileStamp.read(at: log))
        let modified = try #require(try FileManager.default
            .attributesOfItem(atPath: log.path)[.modificationDate] as? Date)
        let replacement = Self.record(input: "50")
        #expect(replacement.utf8.count == first.utf8.count)
        try replacement.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: log.path)
        let updatedStamp = try #require(MuseLocalUsageCache.FileStamp.read(at: log))
        #expect(updatedStamp.size == stamp.size)
        #expect(updatedStamp != stamp)
        let rotated = try report()
        #expect(rotated.coverage == .complete)
        #expect(rotated.report.summary?.totalTokens == 70)
        #expect(rotated.report.summary?.totalCostUSD == nil)
        let handle = try UsageFileMetadata.openRegularFile(at: log)
        defer { try? handle.close() }
        #expect(MuseLocalUsageCache.FileStamp.read(from: handle) == updatedStamp)
    }

    @Test(arguments: ["true", "false"])
    func `JSON booleans do not become measured Muse token counts`(counter: String) {
        #expect(MuseLocalUsageReader.parseLine(Data(Self.record(input: counter).utf8)) == .unrecognized)
    }

    private static func record(input: String) -> String {
        """
        {"schema_version":1,"id":"fixture-turn","stream":{"kind":"session","id":"fixture-session"},\
        "sequence":1,"recorded_at":1788177600000000,"record_type":"event","durability":"durable",\
        "payload_type":"runtime.session","payload_schema_version":1,"payload":{"kind":"run",\
        "run_id":"fixture-run","event":{"kind":"model_completed","model":"muse-example-model",\
        "usage":{"input_tokens":\(input),"output_tokens":20}}}}
        """
    }
}
