#if os(Windows)
import Foundation
import WinSDK

struct WindowsProcessIdentity {
    let executablePath: String
    let creationTicks: UInt64

    var startEpoch: TimeInterval {
        Double(self.creationTicks) / 10_000_000 - 11_644_473_600
    }

    static var currentProcessID: Int32 {
        Int32(bitPattern: GetCurrentProcessId())
    }

    static var currentUserSID: String? {
        self.ownerSID(process: GetCurrentProcess())
    }

    static func read(pid: Int32) -> Self? {
        guard pid != 0,
              let process = OpenProcess(
                  DWORD(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE), false, DWORD(bitPattern: pid))
        else { return nil }
        defer { _ = CloseHandle(process) }
        guard WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT) else { return nil }
        var path = [WCHAR](repeating: 0, count: 32768)
        var length = DWORD(path.count)
        guard QueryFullProcessImageNameW(process, 0, &path, &length), length > 0 else { return nil }
        var creation = FILETIME()
        var exit = FILETIME()
        var kernel = FILETIME()
        var user = FILETIME()
        guard GetProcessTimes(process, &creation, &exit, &kernel, &user) else { return nil }
        return Self(
            executablePath: String(decoding: path.prefix(Int(length)), as: UTF16.self),
            creationTicks: UInt64(creation.dwHighDateTime) << 32 | UInt64(creation.dwLowDateTime))
    }

    static func ownerSID(pid: Int32) -> String? {
        guard pid != 0,
              let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid))
        else { return nil }
        defer { _ = CloseHandle(process) }
        return self.ownerSID(process: process)
    }

    private static func ownerSID(process: HANDLE?) -> String? {
        var token: HANDLE?
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else { return nil }
        defer { _ = CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard GetLastError() == DWORD(ERROR_INSUFFICIENT_BUFFER), size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size) else { return nil }
        var text: LPWSTR?
        guard ConvertSidToStringSidW(buffer.load(as: TOKEN_USER.self).User.Sid, &text), let text else { return nil }
        defer { _ = LocalFree(text) }
        return String(decodingCString: text, as: UTF16.self)
    }
}
#endif
