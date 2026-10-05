import Foundation
import Testing
@testable import CodexBarCore

struct UsageFileMetadataTests {
    @Test
    func `an opened usage handle retains the original file after pathname replacement`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.jsonl")
        let original = Data("original usage\n".utf8)
        try original.write(to: file)
        let metadata = try #require(UsageFileMetadata.read(at: file, followingSymlinks: false))
        let handle = try UsageFileMetadata.openRegularFile(at: file)
        defer { try? handle.close() }

        try FileManager.default.removeItem(at: file)
        try Data("replacement usage\n".utf8).write(to: file)

        #expect(UsageFileMetadata.read(from: handle)?.fileID == metadata.fileID)
        #if os(Windows)
        #expect(UsageFileMetadata.read(fromNativeWindowsHandle: handle._handle)?.fileID == metadata.fileID)
        #endif
        #expect(UsageFileMetadata.read(at: file)?.fileID != metadata.fileID)
        #expect(try handle.readToEnd() == original)
        #expect(metadata.isRegularFile)
        #expect(metadata.size == Int64(original.count))
        #expect(metadata.modifiedSeconds > 0)
        #expect(metadata.changedSeconds > 0)
    }

    @Test
    func `regular usage opening rejects directories`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            try UsageFileMetadata.openRegularFile(at: root)
        }
    }

    #if !os(Windows)
    @Test
    func `no follow usage opening rejects a symlink while ordinary metadata follows it`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.jsonl")
        try Data("usage\n".utf8).write(to: file)
        let link = root.appendingPathComponent("usage-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(UsageFileMetadata.read(at: link)?.fileID == UsageFileMetadata.read(at: file)?.fileID)
        #expect(UsageFileMetadata.read(at: link, followingSymlinks: false) == nil)
        #expect(throws: (any Error).self) {
            try UsageFileMetadata.openRegularFile(at: link)
        }
    }
    #endif

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-usage-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
