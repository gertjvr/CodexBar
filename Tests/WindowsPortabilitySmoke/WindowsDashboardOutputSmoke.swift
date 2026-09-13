#if os(Windows)
import Foundation
import WinSDK

enum WindowsDashboardOutputSmoke {
    static func run(in root: URL) throws {
        let destination = root.appendingPathComponent("dashboard café 测试.json")
        let staged = root.appendingPathComponent("dashboard-staged.json")
        let body = Data("{\"fixture\":\"café 测试\"}".utf8)
        try CLIWindowsDashboardOutput.write(body, to: destination, staged: staged)
        let created = try Data(contentsOf: destination)
        precondition(created == body)
        precondition(!FileManager.default.fileExists(atPath: staged.path))
        try CLIWindowsDashboardOutput.write(Data(), to: destination, staged: staged)
        let emptied = try Data(contentsOf: destination)
        precondition(emptied.isEmpty)
        try CLIWindowsDashboardOutput.write(body, to: destination, staged: staged)

        // A reader that denies delete sharing must make replacement fail without losing old data.
        let path = Array(destination.path.utf16) + [0]
        let held = path.withUnsafeBufferPointer {
            CreateFileW(
                $0.baseAddress,
                DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil)
        }
        guard let held, held != INVALID_HANDLE_VALUE else { preconditionFailure("Could not hold dashboard fixture") }
        defer { _ = CloseHandle(held) }
        do {
            try CLIWindowsDashboardOutput.write(Data("new".utf8), to: destination, staged: staged)
            preconditionFailure("Replaced a dashboard whose reader denied delete sharing")
        } catch {
            let retained = try Data(contentsOf: destination)
            precondition(retained == body)
            precondition(!FileManager.default.fileExists(atPath: staged.path))
        }
        try body.write(to: staged)
        do {
            try CLIWindowsDashboardOutput.write(Data(), to: destination, staged: staged)
            preconditionFailure("Reused an occupied staging file")
        } catch {
            let retained = try Data(contentsOf: staged)
            precondition(retained == body)
        }
        print("Windows dashboard output passed: Unicode, replacement, empty output, and failed-write preservation")
    }
}
#endif
