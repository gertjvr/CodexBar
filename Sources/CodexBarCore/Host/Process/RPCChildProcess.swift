import Foundation

/// Owns a long-lived stdio process independently of the provider's RPC protocol.
package final class RPCChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    #if os(Windows)
    private var child: WindowsChildProcess?
    #else
    private let process = Process()
    #endif

    package init() {}

    package var isRunning: Bool {
        self.lock.withLock {
            #if os(Windows)
            self.child?.isRunning ?? false
            #else
            self.process.isRunning
            #endif
        }
    }

    // Keep the three stream owners explicit at the process boundary.
    // swiftlint:disable:next function_parameter_count
    package func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Pipe,
        stdout: Pipe,
        stderr: Pipe) throws
    {
        try self.lock.withLock {
            guard !self.started, !self.stopped else { throw CocoaError(.executableLoad) }
            self.started = true
            #if os(Windows)
            let child = try WindowsChildProcess.launch(
                binary: executable,
                arguments: arguments,
                environment: environment,
                standardInput: stdin.fileHandleForReading,
                stdout: stdout,
                stderr: stderr)
            self.child = child
            do {
                try stdin.fileHandleForReading.close()
                try stdout.fileHandleForWriting.close()
                try stderr.fileHandleForWriting.close()
            } catch {
                try? child.terminate()
                throw error
            }
            #else
            self.process.environment = environment
            self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            self.process.arguments = [executable] + arguments
            self.process.standardInput = stdin
            self.process.standardOutput = stdout
            self.process.standardError = stderr
            try self.process.run()
            #endif
        }
    }

    package func stop() {
        #if os(Windows)
        let child = self.lock.withLock {
            self.stopped = true
            return self.child
        }
        try? child?.terminate()
        _ = child?.wait(milliseconds: 5000)
        #else
        self.lock.withLock {
            self.stopped = true
            SubprocessRunner.terminateProcess(self.process, processGroup: nil)
        }
        #endif
    }
}
