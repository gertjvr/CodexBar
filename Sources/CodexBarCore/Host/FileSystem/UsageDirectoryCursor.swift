import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// A single-owner directory iterator. Callers retain their own lock and logical paging offset.
final class UsageDirectoryCursor {
    #if os(Windows)
    private let handle: HANDLE
    private var entry: WIN32_FIND_DATAW
    private var hasEntry = true
    #elseif os(Linux)
    private let handle: OpaquePointer
    #else
    private let handle: UnsafeMutablePointer<DIR>
    #endif

    init?(directoryURL: URL) {
        #if os(Windows)
        var entry = WIN32_FIND_DATAW()
        let pattern = Array(directoryURL.appendingPathComponent("*").path.utf16) + [0]
        let handle = pattern.withUnsafeBufferPointer { FindFirstFileW($0.baseAddress, &entry) }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        self.handle = handle
        self.entry = entry
        #else
        guard let handle = opendir(directoryURL.path) else { return nil }
        self.handle = handle
        #endif
    }

    deinit {
        #if os(Windows)
        _ = FindClose(self.handle)
        #else
        closedir(self.handle)
        #endif
    }

    func nextName() -> String? {
        #if os(Windows)
        guard self.hasEntry else { return nil }
        let name = withUnsafePointer(to: self.entry.cFileName) {
            $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
                String(decodingCString: $0, as: UTF16.self)
            }
        }
        self.hasEntry = FindNextFileW(self.handle, &self.entry)
        return name
        #else
        guard let entry = readdir(self.handle) else { return nil }
        return withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
        }
        #endif
    }
}
