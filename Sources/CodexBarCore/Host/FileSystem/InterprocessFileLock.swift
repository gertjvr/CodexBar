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
        guard let result = try self.withLock(
            at: url, wait: true, requireCurrentOwner: false, operation: operation)
        else { throw NSError(domain: "InterprocessFileLock", code: 1) }
        return result
    }

    /// Returns nil only when a nonblocking attempt encounters a competing holder.
    static func withLock<T>(
        at url: URL,
        wait: Bool,
        requireCurrentOwner: Bool,
        operation: () throws -> T) throws -> T?
    {
        #if os(Windows)
        let handle = try WindowsPrivateFile.openLock(at: url, requireCurrentOwner: requireCurrentOwner)
        defer { _ = CloseHandle(handle) }
        var position = OVERLAPPED()
        // A synchronous handle waits for the lock, matching flock's blocking behavior.
        // Every participant locks the first byte, including when the lock file is empty.
        let flags = DWORD(LOCKFILE_EXCLUSIVE_LOCK) | (wait ? 0 : DWORD(LOCKFILE_FAIL_IMMEDIATELY))
        guard LockFileEx(handle, flags, 0, 1, 0, &position) else {
            let code = GetLastError()
            if !wait, code == DWORD(ERROR_LOCK_VIOLATION) { return nil }
            throw self.windowsError(at: url, code: code)
        }
        defer { _ = UnlockFileEx(handle, 0, 1, 0, &position) }
        return try operation()
        #else
        let descriptor = open(
            url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              !requireCurrentOwner || metadata.st_uid == geteuid()
        else { throw POSIXError(.EINVAL) }
        while flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let code = errno
            if code == EINTR { continue }
            if !wait, code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
        #endif
    }

    #if os(Windows)
    private static func windowsError(at url: URL, code: DWORD = GetLastError()) -> NSError {
        NSError(domain: "Win32", code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
    #endif
}
