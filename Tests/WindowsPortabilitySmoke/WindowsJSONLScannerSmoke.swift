import Foundation

@main
enum WindowsJSONLScannerSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.jsonl")
        let first = "{\"text\":\"café 测试\"}\n"
        let long = "{\"text\":\"" + String(repeating: "x", count: 300_000) + "\"}\n"
        let tail = "{\"complete\":true}"
        let contents = Data((first + long + tail).utf8)
        try contents.write(to: file)
        var lines: [CostUsageJsonl.Line] = []
        var state: CostUsageJsonl.ResumeState?
        var offset: Int64 = 0
        repeat {
            let progress = try CostUsageJsonl.scanBounded(
                fileURL: file,
                offset: offset,
                maxLineBytes: 1024,
                prefixBytes: 64,
                maxBytesToRead: 4093,
                resumeState: state,
                onLine: { lines.append($0) })
            precondition(progress.readOffset > offset)
            offset = progress.readOffset
            // Exercise the persisted checkpoint contract used by incremental usage scans.
            state = try progress.resumeState.map {
                try JSONDecoder().decode(CostUsageJsonl.ResumeState.self, from: JSONEncoder().encode($0))
            }
        } while offset < contents.count
        precondition(state == nil)
        precondition(lines.count == 3)
        precondition(lines[0].bytes == Data(first.dropLast().utf8))
        precondition(!lines[0].wasTruncated)
        precondition(lines[1].wasTruncated && lines[1].bytes.count == 64)
        precondition(lines[1].startOffset == first.utf8.count)
        precondition(lines[2].bytes == Data(tail.utf8))
        precondition(lines[2].endOffset == contents.count)

        try Data("{\"pending\":".utf8).write(to: file)
        var emitted = false
        let partial = try CostUsageJsonl.scanBounded(
            fileURL: file,
            maxLineBytes: 1024,
            prefixBytes: 64,
            maxBytesToRead: nil,
            resumeState: nil,
            onLine: { _ in emitted = true })
        precondition(!emitted && partial.committedOffset == 0 && partial.resumeState != nil)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("true}".utf8))
        try writer.close()
        let completed = try CostUsageJsonl.scanBounded(
            fileURL: file,
            maxLineBytes: 1024,
            prefixBytes: 64,
            maxBytesToRead: nil,
            resumeState: partial.resumeState,
            onLine: { line in
                precondition(line.bytes == Data("{\"pending\":true}".utf8))
                emitted = true
            })
        precondition(emitted && completed.resumeState == nil)
        print("Optimized JSONL scanner checks passed")
    }
}
