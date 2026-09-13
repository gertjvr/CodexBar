import Foundation
#if os(Windows)
import ucrt
import WinSDK
#endif

/// Compiled with the production helpers, independently of the unfinished Windows CLI port.
@main
struct PortabilitySmoke {
    static func main() async throws {
        #if os(Windows)
        if try WindowsProcessSmoke.runFixtureIfRequested() { return }
        let environmentKey = "CODEXBAR_PORTABILITY_SMOKE"
        let previousValue = ProcessInfo.processInfo.environment[environmentKey]
        precondition(_putenv_s(environmentKey, "fixture") == 0)
        defer { _ = _putenv_s(environmentKey, previousValue ?? "") }
        precondition(ProcessInfo.processInfo.environment[environmentKey] == "fixture")
        #endif
        let pooledValue = autoreleasepool { 17 }
        precondition(pooledValue == 17, "Autorelease compatibility must preserve return values")
        let json = Data("[true,false,0,1,0.0,1.0,-1,1.5]".utf8)
        guard let values = try JSONSerialization.jsonObject(with: json) as? [NSNumber] else {
            preconditionFailure("Expected boxed JSON values")
        }
        for (index, value) in values.enumerated() {
            precondition(JSONNumber.isBoolean(value) == (index < 2), "JSON boolean/number classification changed")
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codexbar-portability-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("usage café 测试.jsonl")
        precondition(UsageFileMetadata.read(at: file) == nil, "Missing file must have no metadata")
        try Data("abc".utf8).write(to: file)
        let modified = Date(timeIntervalSince1970: 1_735_689_600.125)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let initial = try self.metadata(at: file)
        precondition(initial.size == 3)
        precondition(initial.isRegularFile)
        precondition(abs(initial.mtimeUnixMs - 1_735_689_600_125) <= 1, "Incorrect timestamp epoch or precision")
        precondition(abs(initial.modifiedNanoseconds - 125_000_000) <= 1000)

        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        #if os(Windows)
        precondition(UsageFileMetadata.read(from: writer)?.fileID == initial.fileID)
        #endif
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("def".utf8))
        try writer.synchronize()
        let appended = try self.metadata(at: file)
        precondition(appended.size == 6, "Metadata must remain readable while history is being written")
        precondition(appended.fileID == initial.fileID, "Appending must preserve file identity")
        try writer.truncate(atOffset: 2)
        try writer.synchronize()
        let truncated = try self.metadata(at: file)
        precondition(truncated.size == 2)
        precondition(truncated.fileID == initial.fileID)
        try writer.close()

        let moved = root.appendingPathComponent("renamed.jsonl")
        try fm.moveItem(at: file, to: moved)
        let renamed = try self.metadata(at: moved)
        precondition(renamed.fileID == initial.fileID, "Renaming must preserve file identity")
        // Keep the original alive so the filesystem cannot reuse its ID for the replacement.
        try Data("xyz".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let replaced = try self.metadata(at: file)
        precondition(replaced.size == initial.size)
        precondition(replaced.mtimeUnixMs == initial.mtimeUnixMs)
        precondition(replaced.fileID != initial.fileID, "Same-size replacement must invalidate cached identity")
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let directoryMetadata = try self.metadata(at: empty)
        precondition(!directoryMetadata.isRegularFile)
        let names = try self.directoryNames(at: root)
        precondition(names == [file.lastPathComponent, moved.lastPathComponent, empty.lastPathComponent])
        let emptyNames = try self.directoryNames(at: empty)
        precondition(emptyNames.isEmpty)
        try self.checkLock(at: root.appendingPathComponent("fixture.lock"))
        try CredentialFileSmoke.run(in: root)
        #if os(Windows)
        try WindowsProcessSmoke.run(in: root)
        try WindowsDashboardOutputSmoke.run(in: root)
        try await WindowsSubprocessSmoke.run(in: root)
        try WindowsCommandScriptSmoke.run(in: root)
        try await WindowsRPCSmoke.run()
        try WindowsEnvironmentSmoke.run(in: root)
        try WindowsCLIControlSmoke.run()
        try WindowsPTYSmoke.run()
        #endif
        print("Portability smoke passed: JSON types, file metadata, directory iteration, and cache invalidation")
    }

    private static func metadata(at url: URL) throws -> UsageFileMetadata {
        guard let metadata = UsageFileMetadata.read(at: url) else {
            throw NSError(domain: "PortabilitySmoke", code: 1, userInfo: [NSFilePathErrorKey: url.path])
        }
        return metadata
    }

    private static func directoryNames(at url: URL) throws -> Set<String> {
        guard let cursor = UsageDirectoryCursor(directoryURL: url) else {
            throw NSError(domain: "PortabilitySmoke", code: 2, userInfo: [NSFilePathErrorKey: url.path])
        }
        var names = Set<String>()
        while let name = cursor.nextName() {
            if name != ".", name != ".." { names.insert(name) }
        }
        return names
    }

    private struct LockProbeError: Error {}

    private static func checkLock(at url: URL) throws {
        do {
            try InterprocessFileLock.withLock(at: url) {
                #if os(Windows)
                let competing = try FileHandle(forUpdating: url)
                defer { try? competing.close() }
                var position = OVERLAPPED()
                let acquired = LockFileEx(
                    competing._handle,
                    DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY),
                    0,
                    1,
                    0,
                    &position)
                let error = GetLastError()
                if acquired { _ = UnlockFileEx(competing._handle, 0, 1, 0, &position) }
                precondition(!acquired && error == DWORD(ERROR_LOCK_VIOLATION), "Competing handle bypassed lock")
                #endif
                throw LockProbeError()
            }
        } catch is LockProbeError {}
        let result = try InterprocessFileLock.withLock(at: url) { "released" }
        precondition(result == "released", "Thrown operations must release the lock")
    }
}
