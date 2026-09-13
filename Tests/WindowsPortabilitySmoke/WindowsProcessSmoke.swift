#if os(Windows)
import Foundation
import WinSDK

enum WindowsProcessSmoke {
    static func runFixtureIfRequested() throws -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first, mode.hasPrefix("--process-") else { return false }
        switch mode {
        case "--process-control":
            try WindowsCLIControlSmoke.runFixture()
        case "--process-pty":
            try WindowsPTYSmoke.runFixture()
        case "--process-pipe-idle":
            try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
            try FileHandle.standardError.write(contentsOf: Data("diagnostic\n".utf8))
            Thread.sleep(forTimeInterval: 30)
        case "--process-stream-order":
            try FileHandle.standardError.write(contentsOf: Data("first\n".utf8))
            try FileHandle.standardOutput.write(contentsOf: Data("second\n".utf8))
            try FileHandle.standardError.write(contentsOf: Data("third\n".utf8))
        case "--process-echo":
            precondition(!CLIWindowsConsole.isTerminal(STD_OUTPUT_HANDLE))
            precondition(!CLIWindowsConsole.enableOutputColor())
            precondition(CLIWindowsConsole.columnCount() == nil)
            guard let executable = CLIWindowsConsole.executablePath() else {
                preconditionFailure("Executable path unavailable")
            }
            precondition(UsageFileMetadata.read(at: URL(fileURLWithPath: executable))?.fileID
                == UsageFileMetadata.read(at: URL(fileURLWithPath: CommandLine.arguments[0]))?.fileID)
            let value: [String: Any] = [
                "arguments": Array(arguments.dropFirst()),
                "environment": ProcessInfo.processInfo.environment["CODEXBAR_CHILD_FIXTURE"] ?? "missing",
                "directory": FileManager.default.currentDirectoryPath,
            ]
            try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: value))
            try FileHandle.standardError.write(contentsOf: Data("fixture stderr".utf8))
        case "--process-tree", "--process-orphan":
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--process-sleep"]
            try child.run()
            try Data(String(child.processIdentifier).utf8).write(to: URL(fileURLWithPath: arguments[1]))
            if mode == "--process-tree" { Thread.sleep(forTimeInterval: 30) }
        case "--process-rpc":
            var buffer = Data()
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        preconditionFailure("Invalid RPC fixture request")
                    }
                    var reply = try JSONSerialization.data(withJSONObject: [
                        "id": request["id"] ?? 0,
                        "result": request["params"] ?? [:],
                    ])
                    reply.append(0x0A)
                    try FileHandle.standardOutput.write(contentsOf: reply)
                }
            }
        case "--process-flood":
            let chunk = Data(repeating: 120, count: 4096)
            for _ in 0..<512 {
                try FileHandle.standardOutput.write(contentsOf: chunk)
                try FileHandle.standardError.write(contentsOf: chunk)
            }
        case "--process-exit":
            try FileHandle.standardError.write(contentsOf: Data("fixture failure".utf8))
            ExitProcess(7)
        case "--process-sleep":
            Thread.sleep(forTimeInterval: 30)
        default:
            preconditionFailure("Unknown process fixture")
        }
        return true
    }

    static func run(in root: URL) throws {
        let executable = CommandLine.arguments[0]
        let arguments = ["", "two words", "café 测试", "quote\"inside", "trailing\\", "\\\\\"", "&|<>^%!()"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_CHILD_FIXTURE"] = "unicode 测试=value"
        environment["codexbar_child_fixture"] = "inherited value must not override explicit uppercase key"
        let output = Pipe()
        let errorOutput = Pipe()
        let child = try WindowsChildProcess.launch(
            binary: executable,
            arguments: ["--process-echo"] + arguments,
            environment: environment,
            currentDirectoryURL: root,
            stdout: output,
            stderr: errorOutput)
        try output.fileHandleForWriting.close()
        try errorOutput.fileHandleForWriting.close()
        precondition(child.wait(milliseconds: 5000), "Echo child did not exit")
        precondition(child.terminationStatus == 0)
        let captured = try output.fileHandleForReading.readToEnd() ?? Data()
        let capturedError = try errorOutput.fileHandleForReading.readToEnd() ?? Data()
        guard let decoded = try JSONSerialization.jsonObject(with: captured) as? [String: Any],
              let workingDirectory = decoded["directory"] as? String
        else { preconditionFailure("Invalid fixture output") }
        precondition(decoded["arguments"] as? [String] == arguments, "Argument quoting changed argv")
        precondition(decoded["environment"] as? String == "unicode 测试=value")
        let directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        guard let actual = UsageFileMetadata.read(at: directory), let expected = UsageFileMetadata.read(at: root) else {
            preconditionFailure("Cannot inspect working directory: \(workingDirectory), expected \(root.path)")
        }
        precondition(
            actual.fileID == expected.fileID,
            "Wrong working directory: \(workingDirectory), expected \(root.path)")
        precondition(String(data: capturedError, encoding: .utf8) == "fixture stderr")
        try self.checkTree(in: root, mode: "--process-tree", environment: environment)
        try self.checkTree(in: root, mode: "--process-orphan", environment: environment)
        print("Windows process smoke passed: argv, environment, cwd, output, and descendant cleanup")
    }

    private static func checkTree(in root: URL, mode: String, environment: [String: String]) throws {
        let pidFile = root.appendingPathComponent("\(mode).pid")
        let unrelated = Pipe()
        precondition(SetHandleInformation(
            unrelated.fileHandleForWriting._handle,
            DWORD(HANDLE_FLAG_INHERIT),
            DWORD(HANDLE_FLAG_INHERIT)))
        let output = Pipe()
        let errorOutput = Pipe()
        var child: WindowsChildProcess? = try WindowsChildProcess.launch(
            binary: CommandLine.arguments[0],
            arguments: [mode, pidFile.path],
            environment: environment,
            stdout: output,
            stderr: errorOutput)
        defer { try? child?.terminate() }
        try unrelated.fileHandleForWriting.close()
        var available: DWORD = 0
        let hasWriter = PeekNamedPipe(unrelated.fileHandleForReading._handle, nil, 0, nil, &available, nil)
        precondition(!hasWriter && GetLastError() == DWORD(ERROR_BROKEN_PIPE), "Unlisted pipe leaked into child")
        let deadline = Date().addingTimeInterval(5)
        var pid: DWORD?
        while pid == nil, Date() < deadline {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(DWORD.init)
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let pid, let descendant = OpenProcess(DWORD(SYNCHRONIZE), false, pid) else {
            preconditionFailure("Grandchild did not start")
        }
        defer { _ = CloseHandle(descendant) }
        precondition(WaitForSingleObject(descendant, 0) == DWORD(WAIT_TIMEOUT))
        precondition(child!.descendantIdentifiers().contains(pid), "Owned job enumeration missed the grandchild")
        precondition(!child!.descendantIdentifiers().contains(child!.processIdentifier))
        guard let identity = WindowsProcessIdentity.read(pid: Int32(bitPattern: pid)),
              let parent = WindowsProcessIdentity.read(pid: WindowsProcessIdentity.currentProcessID),
              let owner = WindowsProcessIdentity.currentUserSID,
              let childFile = UsageFileMetadata.read(at: URL(fileURLWithPath: identity.executablePath)),
              let fixtureFile = UsageFileMetadata.read(at: URL(fileURLWithPath: CommandLine.arguments[0]))
        else { preconditionFailure("Missing native process identity") }
        precondition(childFile.fileID == fixtureFile.fileID, "Process image identity changed")
        precondition(identity.creationTicks >= parent.creationTicks)
        precondition(owner.hasPrefix("S-"))
        precondition(WindowsProcessIdentity.ownerSID(pid: Int32(bitPattern: pid)) == owner)
        precondition(WindowsProcessIdentity.read(pid: 0) == nil)
        precondition(WindowsProcessIdentity.ownerSID(pid: 0) == nil)

        if mode == "--process-tree" {
            try child!.terminate()
            precondition(child!.wait(milliseconds: 5000), "Terminated root remained running")
        } else {
            precondition(child!.wait(milliseconds: 5000), "Orphan fixture root did not exit")
            child = nil
        }
        precondition(WaitForSingleObject(descendant, 5000) == DWORD(WAIT_OBJECT_0), "Descendant escaped job cleanup")
    }
}
#endif
