import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import ucrt
import WinSDK
#endif

struct UsageFileMetadata: Sendable {
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let size: Int64
    let fileID: String
    let isRegularFile: Bool

    var mtimeUnixMs: Int64 {
        self.modifiedSeconds * 1000 + self.modifiedNanoseconds / 1_000_000
    }

    static func read(at url: URL, followingSymlinks: Bool = true) -> Self? {
        #if os(Windows)
        return self.readWindows(at: url, followingSymlinks: followingSymlinks)
        #else
        var info = stat()
        let flags = followingSymlinks ? 0 : AT_SYMLINK_NOFOLLOW
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, flags) }) == 0,
              followingSymlinks || info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
        else { return nil }
        return self.readUnix(info)
        #endif
    }

    static func read(from handle: FileHandle) -> Self? {
        #if os(Windows)
        // Foundation exposes its native Windows handle; metadata queries do not transfer its ownership.
        return self.readWindows(handle: handle._handle)
        #else
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return self.readUnix(info)
        #endif
    }

    /// Open only the final regular file, without following a symlink or Windows reparse point.
    static func openRegularFile(at url: URL) throws -> FileHandle {
        #if os(Windows)
        let path = Array(url.path.utf16) + [0]
        let handle = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS),
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw NSError(domain: "Win32", code: Int(GetLastError()), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard self.readWindows(handle: handle, followingSymlinks: false)?.isRegularFile == true else {
            _ = CloseHandle(handle)
            throw self.invalidFile(at: url)
        }
        let descriptor = _open_osfhandle(Int(bitPattern: handle), _O_RDONLY | _O_BINARY)
        guard descriptor >= 0 else {
            _ = CloseHandle(handle)
            throw self.invalidFile(at: url)
        }
        // FileHandle's owning initializer duplicates the native handle and closes this CRT descriptor.
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard self.read(from: handle)?.isRegularFile == true else {
            try? handle.close()
            throw self.invalidFile(at: url)
        }
        return handle
        #endif
    }

    private static func invalidFile(at url: URL) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSFilePathErrorKey: url.path])
    }

    #if !os(Windows)
    private static func readUnix(_ info: stat) -> Self {
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        let changedSeconds = Int64(info.st_ctim.tv_sec)
        let changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        let changedSeconds = Int64(info.st_ctimespec.tv_sec)
        let changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #endif
        return Self(
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            changedSeconds: changedSeconds,
            changedNanoseconds: changedNanoseconds,
            size: Int64(info.st_size),
            fileID: "\(info.st_dev):\(info.st_ino)",
            isRegularFile: info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
    }
    #endif

    #if os(Windows)
    /// Borrow a native handle for metadata only; its owner retains responsibility for closing it.
    static func read(fromNativeWindowsHandle handle: HANDLE) -> Self? {
        self.readWindows(handle: handle, followingSymlinks: false)
    }

    private static func readWindows(at url: URL, followingSymlinks: Bool) -> Self? {
        let path = Array(url.path.utf16) + [0]
        let flags = DWORD(FILE_FLAG_BACKUP_SEMANTICS)
            | (followingSymlinks ? 0 : DWORD(FILE_FLAG_OPEN_REPARSE_POINT))
        // Query metadata only; do not prevent the provider from writing, renaming, or deleting its history.
        let handle = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                0,
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                flags,
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { _ = CloseHandle(handle) }
        return self.readWindows(handle: handle, followingSymlinks: followingSymlinks)
    }

    private static func readWindows(handle: HANDLE, followingSymlinks: Bool = true) -> Self? {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info),
              followingSymlinks || info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
        else { return nil }
        var basic = FILE_BASIC_INFO()
        guard GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, DWORD(MemoryLayout<FILE_BASIC_INFO>.size)),
              basic.ChangeTime.QuadPart >= 0
        else { return nil }
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
        let changedTicks = UInt64(basic.ChangeTime.QuadPart)
        // FILETIME counts 100 ns intervals since 1601; retain its full precision for cache stamps.
        return Self(
            modifiedSeconds: Int64(ticks / 10_000_000) - 11_644_473_600,
            modifiedNanoseconds: Int64(ticks % 10_000_000) * 100,
            changedSeconds: Int64(changedTicks / 10_000_000) - 11_644_473_600,
            changedNanoseconds: Int64(changedTicks % 10_000_000) * 100,
            size: size,
            fileID: "\(identity.VolumeSerialNumber):\(fileID)",
            isRegularFile: info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
                && GetFileType(handle) == DWORD(FILE_TYPE_DISK))
    }
    #endif
}
