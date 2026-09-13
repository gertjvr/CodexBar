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

struct UsageFileMetadata: Sendable {
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let size: Int64
    let fileID: String
    let isRegularFile: Bool

    var mtimeUnixMs: Int64 {
        self.modifiedSeconds * 1000 + self.modifiedNanoseconds / 1_000_000
    }

    static func read(at url: URL) -> Self? {
        #if os(Windows)
        return self.readWindows(at: url)
        #else
        var info = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #endif
        return Self(
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            size: Int64(info.st_size),
            fileID: "\(info.st_dev):\(info.st_ino)",
            isRegularFile: info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #endif
    }

    #if os(Windows)
    private static func readWindows(at url: URL) -> Self? {
        let path = Array(url.path.utf16) + [0]
        // Query metadata only; do not prevent the provider from writing, renaming, or deleting its history.
        let handle = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                0,
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { _ = CloseHandle(handle) }
        return self.readWindows(handle: handle)
    }

    static func read(from handle: FileHandle) -> Self? {
        // Foundation exposes its native Windows handle; no owning CRT descriptor conversion is needed.
        self.readWindows(handle: handle._handle)
    }

    private static func readWindows(handle: HANDLE) -> Self? {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        var identity = FILE_ID_INFO()
        // ReFS needs the full 128-bit identifier; the legacy 64-bit file index can collide.
        guard GetFileInformationByHandleEx(handle, FileIdInfo, &identity, DWORD(MemoryLayout<FILE_ID_INFO>.size))
        else { return nil }
        let fileID = withUnsafeBytes(of: identity.FileId.Identifier) {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        let byteCount = UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow)
        guard let size = Int64(exactly: byteCount) else { return nil }
        let ticks = UInt64(info.ftLastWriteTime.dwHighDateTime) << 32 | UInt64(info.ftLastWriteTime.dwLowDateTime)
        // FILETIME counts 100 ns intervals since 1601; retain its full precision for cache stamps.
        return Self(
            modifiedSeconds: Int64(ticks / 10_000_000) - 11_644_473_600,
            modifiedNanoseconds: Int64(ticks % 10_000_000) * 100,
            size: size,
            fileID: "\(identity.VolumeSerialNumber):\(fileID)",
            isRegularFile: info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
                && GetFileType(handle) == DWORD(FILE_TYPE_DISK))
    }
    #endif
}
