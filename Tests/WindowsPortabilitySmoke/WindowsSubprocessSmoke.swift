#if os(Windows)
import Foundation
import WinSDK

enum WindowsSubprocessSmoke {
    static func run(in root: URL) async throws {
        let synchronous = try WindowsSubprocessRunner.runSynchronously(
            binary: CommandLine.arguments[0],
            arguments: ["--process-echo"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5)
        precondition(synchronous.stderr == "fixture stderr")
        let merged = try WindowsSubprocessRunner.runSynchronously(
            binary: CommandLine.arguments[0],
            arguments: ["--process-stream-order"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5,
            mergeStandardError: true)
        precondition(merged.stdout == "first\nsecond\nthird\n", "Merged streams lost child write order")
        precondition(merged.stderr.isEmpty)
        let result = try await self.execute("--process-flood")
        precondition(result.stdout.utf8.count == 1024 * 1024, "Legacy stdout capture limit changed")
        precondition(result.stderr.utf8.count == 1024 * 1024, "Legacy stderr capture limit changed")
        do {
            _ = try await self.execute("--process-flood", limit: 128)
            preconditionFailure("Explicit output limit must reject oversized output")
        } catch SubprocessRunnerError.outputTooLarge {}
        do {
            _ = try await self.execute("--process-exit")
            preconditionFailure("Nonzero exit must throw")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            precondition(code == 7 && stderr == "fixture failure")
        }
        let accepted = try await self.execute("--process-exit", acceptsNonZeroExit: true)
        precondition(accepted.stderr == "fixture failure")
        let start = ContinuousClock.now
        do {
            _ = try await self.execute("--process-sleep", timeout: 0.05)
            preconditionFailure("Sleeping child must time out")
        } catch SubprocessRunnerError.timedOut {}
        precondition(start.duration(to: .now) < .seconds(3), "Timeout cleanup was not bounded")
        try await self.checkCancellation(in: root)
        try await self.checkManagedPipeCapture()
        print("Windows subprocess smoke passed: bounded output, exit errors, timeouts, and cancellation")
    }

    private static func checkManagedPipeCapture() async throws {
        let output = Pipe()
        let errors = Pipe()
        let activity = DispatchSemaphore(value: 0)
        let outputCapture = ProcessPipeCapture(pipe: output, onData: { activity.signal() })
        let errorCapture = ProcessPipeCapture(pipe: errors)
        outputCapture.start()
        errorCapture.start()
        defer {
            outputCapture.stop()
            errorCapture.stop()
        }
        let process = try WindowsManagedProcess.launch(
            binary: CommandLine.arguments[0],
            arguments: ["--process-pipe-idle"],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: output,
            stderrPipe: errors)
        defer { process.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while outputCapture.currentSnapshot().isEmpty || errorCapture.currentSnapshot().isEmpty,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        WindowsManagedProcess.closeOwnedProcess(pid: WindowsProcessIdentity.currentProcessID)
        precondition(process.isRunning, "Idle fixture exited before capture")
        precondition(activity.wait(timeout: .now() + 1) == .success, "Pipe capture did not report activity")
        await process.terminate()
        precondition(!process.isRunning)
        await process.terminateResidualProcesses()
        let stdout = await outputCapture.finish(timeout: .seconds(1))
        let stderr = await errorCapture.finish(timeout: .seconds(1))
        await process.finish()
        precondition(process.terminationStatus == 1)
        precondition(String(data: stdout, encoding: .utf8) == "ready\n")
        precondition(String(data: stderr, encoding: .utf8) == "diagnostic\n")
        precondition(outputCapture.reachedEOF && errorCapture.reachedEOF)
        print("Windows managed pipe capture passed: live activity, bounded termination, and EOF")
    }

    private static func execute(
        _ mode: String,
        timeout: TimeInterval = 10,
        limit: Int? = nil,
        acceptsNonZeroExit: Bool = false) async throws -> SubprocessResult
    {
        try await WindowsSubprocessRunner.run(
            binary: CommandLine.arguments[0],
            arguments: [mode],
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout,
            maxOutputBytes: limit,
            acceptsNonZeroExit: acceptsNonZeroExit,
            label: "synthetic subprocess")
    }

    private static func checkCancellation(in root: URL) async throws {
        let pidFile = root.appendingPathComponent("cancelled-grandchild.pid")
        let task = Task {
            try await WindowsSubprocessRunner.run(
                binary: CommandLine.arguments[0],
                arguments: ["--process-tree", pidFile.path],
                environment: ProcessInfo.processInfo.environment,
                timeout: 10,
                label: "synthetic cancellation")
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pid: DWORD?
        while pid == nil, ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(DWORD.init)
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pid, let descendant = OpenProcess(DWORD(SYNCHRONIZE), false, pid) else {
            preconditionFailure("Cancellation fixture did not launch")
        }
        defer { _ = CloseHandle(descendant) }
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("Cancellation must throw")
        } catch is CancellationError {}
        precondition(WaitForSingleObject(descendant, 5000) == DWORD(WAIT_OBJECT_0), "Cancelled task leaked descendant")
    }
}
#endif
