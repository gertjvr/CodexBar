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

enum InterprocessFileLock {
    /// The caller creates the parent directory and keeps the lock file at a stable path.
    static func withLock<T>(at url: URL, operation: () throws -> T) throws -> T {
        #if os(Windows)
        let path = Array(url.path.utf16) + [0]
        let handle = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw self.windowsError(at: url) }
        defer { _ = CloseHandle(handle) }
        var position = OVERLAPPED()
        // A synchronous handle waits for the lock, matching flock's blocking behavior.
        // Every participant locks the first byte, including when the lock file is empty.
        guard LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &position) else {
            throw self.windowsError(at: url)
        }
        defer { _ = UnlockFileEx(handle, 0, 1, 0, &position) }
        return try operation()
        #else
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try operation()
        #endif
    }

    #if os(Windows)
    private static func windowsError(at url: URL) -> NSError {
        NSError(domain: "Win32", code: Int(GetLastError()), userInfo: [NSFilePathErrorKey: url.path])
    }
    #endif
}
