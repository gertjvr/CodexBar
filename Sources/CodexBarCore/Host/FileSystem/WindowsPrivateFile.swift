#if os(Windows)
import Foundation
import WinSDK

/// Keeps the credential format unchanged while restricting access before the first write.
enum WindowsPrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let security = try self.securityDescriptor()
        defer { _ = LocalFree(security) }
        var attributes = SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
            lpSecurityDescriptor: security,
            bInheritHandle: false)
        let path = Array(url.path.utf16) + [0]
        let handle = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                DWORD(GENERIC_WRITE),
                0,
                &attributes,
                DWORD(CREATE_NEW),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw self.error(at: url) }
        var complete = false
        defer {
            _ = CloseHandle(handle)
            if !complete { try? FileManager.default.removeItem(at: url) }
        }
        // Some filesystems accept a security descriptor but cannot enforce it.
        var flags: DWORD = 0
        guard GetVolumeInformationByHandleW(handle, nil, 0, nil, nil, &flags, nil, 0) else {
            throw self.error(at: url)
        }
        guard flags & DWORD(FILE_PERSISTENT_ACLS) != 0 else {
            throw self.error(at: url, code: DWORD(ERROR_NOT_SUPPORTED))
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = DWORD(min(bytes.count - offset, Int(DWORD.max)))
                var written: DWORD = 0
                guard WriteFile(handle, bytes.baseAddress!.advanced(by: offset), count, &written, nil) else {
                    throw self.error(at: url)
                }
                guard written > 0 else { throw self.error(at: url, code: DWORD(ERROR_WRITE_FAULT)) }
                offset += Int(written)
            }
        }
        guard FlushFileBuffers(handle) else { throw self.error(at: url) }
        complete = true
    }

    static func publish(_ staged: URL, to url: URL) throws {
        let source = Array(staged.path.utf16) + [0]
        let destination = Array(url.path.utf16) + [0]
        let moved = source.withUnsafeBufferPointer { source in
            destination.withUnsafeBufferPointer { destination in
                MoveFileExW(
                    source.baseAddress,
                    destination.baseAddress,
                    DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else { throw self.error(at: url) }
    }

    static func repairPermissions(at url: URL) throws {
        let security = try self.securityDescriptor()
        defer { _ = LocalFree(security) }
        var present: WindowsBool = false
        var defaulted: WindowsBool = false
        var acl: PACL?
        guard GetSecurityDescriptorDacl(security, &present, &acl, &defaulted), present.boolValue, let acl else {
            throw self.error(at: url)
        }
        var path = Array(url.path.utf16) + [0]
        let result = path.withUnsafeMutableBufferPointer {
            SetNamedSecurityInfoW(
                $0.baseAddress,
                SE_FILE_OBJECT,
                DWORD(DACL_SECURITY_INFORMATION) | DWORD(PROTECTED_DACL_SECURITY_INFORMATION),
                nil,
                nil,
                acl,
                nil)
        }
        guard result == DWORD(ERROR_SUCCESS) else { throw self.error(at: url, code: result) }
    }

    private static func securityDescriptor() throws -> PSECURITY_DESCRIPTOR {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else {
            throw self.error()
        }
        defer { _ = CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard GetLastError() == DWORD(ERROR_INSUFFICIENT_BUFFER), size > 0 else { throw self.error() }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size) else { throw self.error() }
        var sidText: LPWSTR?
        guard ConvertSidToStringSidW(buffer.load(as: TOKEN_USER.self).User.Sid, &sidText), let sidText else {
            throw self.error()
        }
        defer { _ = LocalFree(sidText) }
        let sid = String(decodingCString: sidText, as: UTF16.self)
        // Protected DACL: only the current user gets file access; no inherited grants.
        let sddl = Array("O:\(sid)D:P(A;;FA;;;\(sid))".utf16) + [0]
        var descriptor: PSECURITY_DESCRIPTOR?
        let converted = sddl.withUnsafeBufferPointer {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                $0.baseAddress, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard converted, let descriptor else { throw self.error() }
        return descriptor
    }

    private static func error(at url: URL? = nil, code: DWORD = GetLastError()) -> NSError {
        NSError(domain: "Win32", code: Int(code), userInfo: url.map { [NSFilePathErrorKey: $0.path] })
    }
}
#endif
