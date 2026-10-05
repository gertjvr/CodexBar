#if os(Windows)
import Foundation
import WinSDK

/// Keeps the credential format unchanged while restricting access before the first write.
enum WindowsPrivateFile {
    static func createDirectory(at url: URL) throws {
        let security = try self.securityDescriptor()
        defer { _ = LocalFree(security) }
        var attributes = SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
            lpSecurityDescriptor: security,
            bInheritHandle: false)
        let path = Array(url.path.utf16) + [0]
        guard path.withUnsafeBufferPointer({ CreateDirectoryW($0.baseAddress, &attributes) }) else {
            throw self.error(at: url)
        }
        do {
            let handle = path.withUnsafeBufferPointer {
                CreateFileW(
                    $0.baseAddress,
                    DWORD(FILE_READ_ATTRIBUTES),
                    DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                    nil,
                    DWORD(OPEN_EXISTING),
                    DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
                    nil)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else { throw self.error(at: url) }
            defer { _ = CloseHandle(handle) }
            var information = BY_HANDLE_FILE_INFORMATION()
            guard GetFileInformationByHandle(handle, &information),
                  information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
                  information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
            else { throw self.error(at: url, code: DWORD(ERROR_INVALID_DATA)) }
            try self.requirePersistentACLs(handle, at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func write(_ data: Data, to url: URL, beforeWrite: ((URL) throws -> Void)? = nil) throws {
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
        try self.requirePersistentACLs(handle, at: url)
        try beforeWrite?(url)
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

    /// Opens the lock without following a reparse point or allowing its identity to be replaced.
    static func openLock(at url: URL, requireCurrentOwner: Bool) throws -> HANDLE {
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
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE) | DWORD(READ_CONTROL),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                &attributes,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS),
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw self.error(at: url) }
        do {
            var information = BY_HANDLE_FILE_INFORMATION()
            guard GetFileType(handle) == DWORD(FILE_TYPE_DISK),
                  GetFileInformationByHandle(handle, &information),
                  information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0
            else { throw self.error(at: url, code: DWORD(ERROR_INVALID_DATA)) }
            try self.requirePersistentACLs(handle, at: url)
            if requireCurrentOwner {
                try self.requireMatchingOwner(handle, security: security, at: url)
            }
            return handle
        } catch {
            _ = CloseHandle(handle)
            throw error
        }
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

    private static func requirePersistentACLs(_ handle: HANDLE, at url: URL) throws {
        // Some filesystems accept a security descriptor but cannot enforce it.
        var flags: DWORD = 0
        guard GetVolumeInformationByHandleW(handle, nil, 0, nil, nil, &flags, nil, 0) else {
            throw self.error(at: url)
        }
        guard flags & DWORD(FILE_PERSISTENT_ACLS) != 0 else {
            throw self.error(at: url, code: DWORD(ERROR_NOT_SUPPORTED))
        }
    }

    private static func requireMatchingOwner(
        _ handle: HANDLE,
        security: PSECURITY_DESCRIPTOR,
        at url: URL) throws
    {
        var owner: PSID?
        var descriptor: PSECURITY_DESCRIPTOR?
        let result = GetSecurityInfo(
            handle, SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION), &owner, nil, nil, nil, &descriptor)
        guard result == DWORD(ERROR_SUCCESS), let descriptor else { throw self.error(at: url, code: result) }
        defer { _ = LocalFree(descriptor) }
        var expected: PSID?
        var defaulted: WindowsBool = false
        guard let owner, GetSecurityDescriptorOwner(security, &expected, &defaulted),
              let expected, EqualSid(owner, expected)
        else { throw self.error(at: url, code: DWORD(ERROR_ACCESS_DENIED)) }
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
