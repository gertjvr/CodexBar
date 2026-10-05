#if os(Windows)
import Foundation
import WinSDK

enum WindowsSubprocessRunner {
    static func runSynchronously(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        mergeStandardError: Bool = false) throws -> SubprocessResult
    {
        try self.execute(
            binary: binary,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            maxOutputBytes: nil,
            standardInput: nil,
            currentDirectoryURL: nil,
            acceptsNonZeroExit: false,
            label: binary,
            cancellation: Cancellation(),
            mergeStandardError: mergeStandardError)
    }

    static func standardInputHandle(_ value: Any?) throws -> FileHandle? {
        if let pipe = value as? Pipe { return pipe.fileHandleForReading }
        if let handle = value as? FileHandle { return handle === FileHandle.nullDevice ? nil : handle }
        guard value == nil else { throw SubprocessRunnerError.launchFailed("Unsupported standard input type") }
        let inherited = FileHandle.standardInput
        return inherited._handle == INVALID_HANDLE_VALUE ? nil : inherited
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var child: WindowsChildProcess?

        var isCancelled: Bool {
            self.lock.withLock { self.cancelled }
        }

        func install(_ child: WindowsChildProcess?) {
            let shouldTerminate = self.lock.withLock {
                self.child = child
                return self.cancelled
            }
            if shouldTerminate { try? child?.terminate() }
        }

        func cancel() {
            let child = self.lock.withLock {
                self.cancelled = true
                return self.child
            }
            try? child?.terminate()
        }
    }

    static func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maxOutputBytes: Int? = nil,
        standardInput: FileHandle? = nil,
        currentDirectoryURL: URL? = nil,
        acceptsNonZeroExit: Bool = false,
        label: String) async throws -> SubprocessResult
    {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Native pipe polling and waits must not block Swift's cooperative executor.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try self.execute(
                            binary: binary,
                            arguments: arguments,
                            environment: environment,
                            timeout: timeout,
                            maxOutputBytes: maxOutputBytes,
                            standardInput: standardInput,
                            currentDirectoryURL: currentDirectoryURL,
                            acceptsNonZeroExit: acceptsNonZeroExit,
                            label: label,
                            cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // Mirrors the shared runner's parameters, with explicit cancellation ownership for the worker.
    // swiftlint:disable:next function_parameter_count
    private static func execute(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maxOutputBytes: Int?,
        standardInput: FileHandle?,
        currentDirectoryURL: URL?,
        acceptsNonZeroExit: Bool,
        label: String,
        cancellation: Cancellation,
        mergeStandardError: Bool = false) throws -> SubprocessResult
    {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard FileManager.default.fileExists(atPath: binary) else {
            throw SubprocessRunnerError.binaryNotFound(binary)
        }
        let output = Pipe()
        let errorOutput = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errorOutput.fileHandleForReading.close()
            try? errorOutput.fileHandleForWriting.close()
        }
        let child: WindowsChildProcess
        do {
            child = try WindowsChildProcess.launch(
                binary: binary,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                standardInput: standardInput,
                stdout: output,
                stderr: mergeStandardError ? output : errorOutput)
        } catch {
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }
        cancellation.install(child)
        defer {
            try? child.terminate()
            _ = child.wait(milliseconds: 5000)
            cancellation.install(nil)
        }
        try output.fileHandleForWriting.close()
        try errorOutput.fileHandleForWriting.close()
        var stdout = Data()
        var stderr = Data()
        var stdoutEOF = false
        var stderrEOF = false
        var exitObserved: UInt64?
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = max(0, maxOutputBytes ?? 1 * 1024 * 1024)
        while true {
            guard !cancellation.isCancelled else { throw CancellationError() }
            let now = DispatchTime.now().uptimeNanoseconds
            if child.isRunning, timeout.isFinite, Double(now - started) / 1_000_000_000 >= max(0, timeout) {
                throw SubprocessRunnerError.timedOut(label)
            }
            if !child.isRunning, exitObserved == nil {
                exitObserved = now
                // A helper may retain stdout after the root exits. End the owned tree before draining EOF.
                try child.terminate()
            }
            let outputChunk = try self.readAvailable(output.fileHandleForReading, eof: &stdoutEOF)
            let errorChunk = try self.readAvailable(errorOutput.fileHandleForReading, eof: &stderrEOF)
            for (currentCount, chunk) in [(stdout.count, outputChunk), (stderr.count, errorChunk)] {
                if maxOutputBytes != nil, chunk.count > limit - currentCount {
                    throw SubprocessRunnerError.outputTooLarge(label)
                }
            }
            stdout.append(outputChunk.prefix(limit - stdout.count))
            stderr.append(errorChunk.prefix(limit - stderr.count))
            if let exitObserved {
                if stdoutEOF, stderrEOF { break }
                if Double(now - exitObserved) / 1_000_000_000 > 1 {
                    throw SubprocessRunnerError.launchFailed("Child output did not close after process cleanup")
                }
            }
            if outputChunk.isEmpty, errorChunk.isEmpty { Sleep(5) }
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let status = child.terminationStatus else {
            throw SubprocessRunnerError.launchFailed("Child exit status is unavailable")
        }
        let errorText = String(data: stderr, encoding: .utf8) ?? ""
        guard status == 0 || acceptsNonZeroExit else {
            throw SubprocessRunnerError.nonZeroExit(code: status, stderr: errorText)
        }
        return SubprocessResult(stdout: String(data: stdout, encoding: .utf8) ?? "", stderr: errorText)
    }

    private static func readAvailable(_ handle: FileHandle, eof: inout Bool) throws -> Data {
        guard !eof else { return Data() }
        var available: DWORD = 0
        guard PeekNamedPipe(handle._handle, nil, 0, nil, &available, nil) else {
            let code = GetLastError()
            if code == DWORD(ERROR_BROKEN_PIPE) {
                eof = true
                return Data()
            }
            throw NSError(domain: "Win32", code: Int(code))
        }
        guard available > 0 else { return Data() }
        var data = Data(count: min(Int(available), 16384))
        var count: DWORD = 0
        let succeeded = data.withUnsafeMutableBytes {
            ReadFile(handle._handle, $0.baseAddress, DWORD($0.count), &count, nil)
        }
        guard succeeded else { throw NSError(domain: "Win32", code: Int(GetLastError())) }
        data.count = Int(count)
        return data
    }
}
#endif
