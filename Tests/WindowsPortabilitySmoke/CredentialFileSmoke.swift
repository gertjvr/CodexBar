import Foundation
#if os(Windows)
import WinSDK
#endif

enum CredentialFileSmoke {
    private struct Rejected: Error {}

    static func run(in root: URL) throws {
        let url = root.appendingPathComponent("credentials café.json")
        let original = Data("{\"fixture\":1}".utf8)
        let replacement = Data("{\"fixture\":2}".utf8)
        try CredentialFileWriter.writePrivate(original, to: url) { staged in
            try self.checkPermissions(at: staged)
        }
        let firstRead = try Data(contentsOf: url)
        precondition(firstRead == original)
        #if os(Windows)
        do {
            try WindowsPrivateFile.write(replacement, to: url)
            preconditionFailure("Exclusive staging must reject an existing file")
        } catch {
            let afterCollision = try Data(contentsOf: url)
            precondition(afterCollision == original, "Staging collision damaged an existing file")
        }
        #endif
        do {
            try CredentialFileWriter.writePrivate(replacement, to: url) { staged in
                try self.checkPermissions(at: staged)
                throw Rejected()
            }
            preconditionFailure("Rejected write must throw")
        } catch is Rejected {}
        let afterRejection = try Data(contentsOf: url)
        precondition(afterRejection == original, "Rejected write replaced original")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(!names.contains { $0.contains(".codexbar-staged-") }, "Staged file leaked after failure")
        try CredentialFileWriter.writePrivate(replacement, to: url)
        let afterReplacement = try Data(contentsOf: url)
        precondition(afterReplacement == replacement)
        try self.checkPermissions(at: url)
        #if os(Windows)
        // Synthetic fixture only: emulate a file written with an overly broad ACL.
        let sddl = Array("D:P(A;;FA;;;WD)".utf16) + [0]
        var descriptor: PSECURITY_DESCRIPTOR?
        precondition(sddl.withUnsafeBufferPointer {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                $0.baseAddress, DWORD(SDDL_REVISION_1), &descriptor, nil)
        })
        defer { _ = LocalFree(descriptor) }
        var acl: PACL?
        var present: WindowsBool = false
        var defaulted: WindowsBool = false
        precondition(GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted))
        var path = Array(url.path.utf16) + [0]
        let broadened = path.withUnsafeMutableBufferPointer {
            SetNamedSecurityInfoW($0.baseAddress, SE_FILE_OBJECT, DWORD(DACL_SECURITY_INFORMATION), nil, nil, acl, nil)
        }
        precondition(broadened == DWORD(ERROR_SUCCESS))
        #else
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #endif
        CredentialFileWriter.repairPermissions(at: url)
        try self.checkPermissions(at: url)
    }

    private static func checkPermissions(at url: URL) throws {
        #if os(Windows)
        var path = Array(url.path.utf16) + [0]
        var owner: PSID?
        var acl: PACL?
        var descriptor: PSECURITY_DESCRIPTOR?
        let result = path.withUnsafeMutableBufferPointer {
            GetNamedSecurityInfoW(
                $0.baseAddress,
                SE_FILE_OBJECT,
                DWORD(OWNER_SECURITY_INFORMATION) | DWORD(DACL_SECURITY_INFORMATION),
                &owner,
                nil,
                &acl,
                nil,
                &descriptor)
        }
        guard result == DWORD(ERROR_SUCCESS), let descriptor, let owner, let acl else {
            throw NSError(domain: "Win32", code: Int(result))
        }
        defer { _ = LocalFree(descriptor) }
        var control: SECURITY_DESCRIPTOR_CONTROL = 0
        var revision: DWORD = 0
        precondition(GetSecurityDescriptorControl(descriptor, &control, &revision))
        precondition(control & SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED) != 0)
        precondition(acl.pointee.AceCount == 1, "Credential file grants access to more than its owner")
        var entry: UnsafeMutableRawPointer?
        precondition(GetAce(acl, 0, &entry))
        let ace = entry!.assumingMemoryBound(to: ACCESS_ALLOWED_ACE.self)
        precondition(ace.pointee.Header.AceType == BYTE(ACCESS_ALLOWED_ACE_TYPE))
        // FILE_ALL_ACCESS from winnt.h is a compound macro that Swift does not import.
        let fileAllAccess: DWORD = 0x001F_01FF
        precondition(ace.pointee.Mask == fileAllAccess)
        let matchesOwner = withUnsafeMutablePointer(to: &ace.pointee.SidStart) { EqualSid($0, owner) }
        precondition(matchesOwner, "Credential access must belong to the file owner")
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        #endif
    }
}
