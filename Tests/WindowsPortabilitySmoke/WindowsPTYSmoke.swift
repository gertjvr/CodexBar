#if os(Windows)
import Foundation
import WinSDK

enum WindowsPTYSmoke {
    static func runFixture() throws {
        guard let input = GetStdHandle(STD_INPUT_HANDLE), let output = GetStdHandle(STD_OUTPUT_HANDLE) else {
            preconditionFailure("Missing console handles")
        }
        var mode: DWORD = 0
        precondition(GetConsoleMode(input, &mode), "Child stdin is not a terminal")
        precondition(GetConsoleMode(output, &mode), "Child stdout is not a terminal")
        precondition(CLIWindowsConsole.isInteractive)
        precondition(CLIWindowsConsole.enableOutputColor())
        try self.writeConsole("READY café 测试\r\n", to: output)
        for _ in 0..<2 {
            var buffer = [WCHAR](repeating: 0, count: 256)
            var count: DWORD = 0
            precondition(buffer.withUnsafeMutableBytes {
                ReadConsoleW(input, $0.baseAddress, 256, &count, nil)
            })
            let line = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var info = CONSOLE_SCREEN_BUFFER_INFO()
            precondition(GetConsoleScreenBufferInfo(output, &info))
            precondition(CLIWindowsConsole.columnCount() == Int(info.srWindow.Right - info.srWindow.Left + 1))
            try self.writeConsole("ECHO:\(line):\(info.dwSize.X)x\(info.dwSize.Y)\r\n", to: output)
        }
        try self.writeConsole("FINISHED\r\n", to: output)
    }

    static func run() throws {
        let console = try WindowsPseudoConsole(rows: 30, columns: 100)
        defer { console.close() }
        let child = try WindowsChildProcess.launchPTY(
            binary: CommandLine.arguments[0],
            arguments: ["--process-pty"],
            environment: ProcessInfo.processInfo.environment,
            console: console)
        defer { try? child.terminate() }
        var captured = Data()
        try self.waitFor("READY café 测试", console: console, captured: &captured)
        try console.send("first 测试\r")
        try self.waitFor("ECHO:first 测试:100x30", console: console, captured: &captured)
        try console.resize(rows: 40, columns: 120)
        try console.send("second\r")
        try self.waitFor("ECHO:second:120x40", console: console, captured: &captured)
        try self.waitFor("FINISHED", console: console, captured: &captured)
        precondition(child.wait(milliseconds: 5000), "Terminal child did not exit")
        precondition(child.terminationStatus == 0)
        let started = ContinuousClock.now
        console.close()
        precondition(started.duration(to: .now) < .seconds(3), "Pseudoconsole shutdown blocked")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var ended = false
        while !ended, ContinuousClock.now < deadline {
            ended = try console.readAvailable().ended
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(ended, "Terminal reader leaked after shutdown")
        try self.checkSessionOwnership()
        print("Windows PTY smoke passed: terminal detection, Unicode interaction, resize, and shutdown")
    }

    private static func checkSessionOwnership() throws {
        let console = try WindowsPseudoConsole(rows: 30, columns: 100)
        defer { console.close() }
        let session = try WindowsManagedProcess.launch(
            binary: CommandLine.arguments[0],
            arguments: ["--process-pty"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            console: console)
        defer { session.close() }
        precondition(session.isRunning)
        precondition(session.exitObservationDate == nil)
        var captured = Data()
        try self.waitFor("READY", console: console, captured: &captured)
        try console.send(Data("owned first\r".utf8))
        try self.waitFor("ECHO:owned first", console: console, captured: &captured)
        try console.send("owned second\r")
        try self.waitFor("FINISHED", console: console, captured: &captured)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(!session.isRunning)
        precondition(session.exitObservationDate != nil)
        precondition(session.finishSynchronously() == 0, "Session cleanup lost the child's exit status")
        session.close()

        let waitingConsole = try WindowsPseudoConsole(rows: 30, columns: 100)
        defer { waitingConsole.close() }
        let waitingSession = try WindowsManagedProcess.launch(
            binary: CommandLine.arguments[0],
            arguments: ["--process-pty"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            console: waitingConsole)
        defer { waitingSession.close() }
        captured.removeAll()
        try self.waitFor("READY", console: waitingConsole, captured: &captured)
        precondition(WindowsManagedProcess.beginLaunch())
        let shutdownFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            WindowsManagedProcess.terminateActiveProcessesForAppShutdown()
            shutdownFinished.signal()
        }
        let fenceDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while WindowsManagedProcess.acceptsRegisteredProcess(pid: waitingSession.processIdentifier),
              ContinuousClock.now < fenceDeadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(!WindowsManagedProcess.acceptsRegisteredProcess(pid: waitingSession.processIdentifier))
        precondition(shutdownFinished.wait(timeout: .now()) == .timedOut, "Shutdown missed an outstanding launch")
        WindowsManagedProcess.endLaunch()
        precondition(shutdownFinished.wait(timeout: .now() + 5) == .success)
        precondition(!WindowsManagedProcess.beginLaunch(), "Shutdown admitted another launch reservation")
        precondition(!waitingSession.isRunning, "Shutdown left a terminal child running")
        let rejectedConsole = try WindowsPseudoConsole(rows: 30, columns: 100)
        defer { rejectedConsole.close() }
        do {
            let unexpected = try WindowsManagedProcess.launch(
                binary: CommandLine.arguments[0],
                arguments: ["--process-pty"],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                console: rejectedConsole)
            unexpected.close()
            preconditionFailure("Shutdown fence allowed a new terminal child")
        } catch let error as CocoaError {
            precondition(error.code == .userCancelled)
        }
        print("Windows terminal session ownership and shutdown fence passed")
    }

    private static func waitFor(_ text: String, console: WindowsPseudoConsole, captured: inout Data) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let chunk = try console.readAvailable()
            captured.append(chunk.data)
            if String(data: captured, encoding: .utf8)?.contains(text) == true { return }
            if chunk.ended { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        preconditionFailure(
            "Missing terminal output '\(text)': \(String(data: captured, encoding: .utf8) ?? "invalid UTF8")")
    }

    private static func writeConsole(_ text: String, to handle: HANDLE) throws {
        let encoded = Array(text.utf16)
        var written: DWORD = 0
        let result = encoded.withUnsafeBufferPointer {
            WriteConsoleW(handle, $0.baseAddress, DWORD($0.count), &written, nil)
        }
        guard result, written == encoded.count else { throw NSError(domain: "Win32", code: Int(GetLastError())) }
    }
}
#endif
