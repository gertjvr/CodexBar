#if os(Windows)
import Foundation
import WinSDK

enum CLIWindowsDashboardOutput {
    static func write(_ data: Data, to destination: URL, staged: URL) throws {
        let path = Array(staged.path.utf16) + [0]
        let handle = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                DWORD(GENERIC_WRITE),
                0,
                nil,
                DWORD(CREATE_NEW),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw self.error(at: staged) }
        var open = true
        var published = false
        defer {
            if open { _ = CloseHandle(handle) }
            if !published { try? FileManager.default.removeItem(at: staged) }
        }
        // Dashboard exports inherit the directory's Windows ACL; credential files use a
        // separate current-user-only writer. Never truncate the destination before publishing.
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = DWORD(min(bytes.count - offset, Int(DWORD.max)))
                var written: DWORD = 0
                guard WriteFile(handle, bytes.baseAddress!.advanced(by: offset), count, &written, nil) else {
                    throw self.error(at: staged)
                }
                guard written > 0 else { throw self.error(at: staged, code: DWORD(ERROR_WRITE_FAULT)) }
                offset += Int(written)
            }
        }
        guard FlushFileBuffers(handle) else { throw self.error(at: staged) }
        guard CloseHandle(handle) else { throw self.error(at: staged) }
        open = false
        let target = Array(destination.path.utf16) + [0]
        let moved = path.withUnsafeBufferPointer { source in
            target.withUnsafeBufferPointer { target in
                MoveFileExW(
                    source.baseAddress,
                    target.baseAddress,
                    DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else { throw self.error(at: destination) }
        published = true
    }

    private static func error(at url: URL, code: DWORD = GetLastError()) -> NSError {
        NSError(domain: "Win32", code: Int(code), userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "Could not write --output file \(url.path) (Windows error \(code))",
        ])
    }
}
#endif
