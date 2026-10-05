#if os(Windows)
import Foundation

/// Owns a registered Windows job, with an optional terminal, until explicit cleanup or app shutdown.
final class WindowsManagedProcess: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        private let lock = NSCondition()
        private var shuttingDown = false
        private var launchesInProgress = 0
        private var sessions: [ObjectIdentifier: WindowsManagedProcess] = [:]

        func beginLaunch() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.shuttingDown else { return false }
            self.launchesInProgress += 1
            return true
        }

        func endLaunch() {
            self.lock.lock()
            self.launchesInProgress -= 1
            precondition(self.launchesInProgress >= 0)
            self.lock.broadcast()
            self.lock.unlock()
        }

        func lookup(pid: Int32, acceptingLaunch: Bool = false) -> WindowsManagedProcess? {
            self.lock.withLock {
                guard !acceptingLaunch || !self.shuttingDown else { return nil }
                return self.sessions.values.first { $0.processIdentifier == pid }
            }
        }

        func launch(_ operation: () throws -> WindowsManagedProcess) throws -> WindowsManagedProcess {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.shuttingDown else {
                throw CocoaError(.userCancelled)
            }
            // Hold the fence through process creation so shutdown cannot miss a suspended child.
            let session = try operation()
            self.sessions[ObjectIdentifier(session)] = session
            return session
        }

        func remove(_ session: WindowsManagedProcess) {
            _ = self.lock.withLock { self.sessions.removeValue(forKey: ObjectIdentifier(session)) }
        }

        func shutdown() {
            let sessions = self.lock.withLock {
                self.shuttingDown = true
                while self.launchesInProgress > 0 {
                    self.lock.wait()
                }
                let sessions = Array(self.sessions.values)
                self.sessions.removeAll()
                return sessions
            }
            for session in sessions {
                session.close()
            }
        }
    }

    private static let registry = Registry()
    private let child: WindowsChildProcess
    private let console: WindowsPseudoConsole?
    private let lock = NSLock()
    private var observedExit: Date?

    private init(child: WindowsChildProcess, console: WindowsPseudoConsole?) {
        self.child = child
        self.console = console
    }

    static func launch(
        binary: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        console: WindowsPseudoConsole) throws -> WindowsManagedProcess
    {
        try self.registry.launch {
            let child = try WindowsChildProcess.launchPTY(
                binary: binary,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: workingDirectory,
                console: console)
            return WindowsManagedProcess(child: child, console: console)
        }
    }

    static func launch(
        binary: String,
        arguments: [String],
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe) throws -> WindowsManagedProcess
    {
        try self.registry.launch {
            let child = try WindowsChildProcess.launch(
                binary: binary,
                arguments: arguments,
                environment: environment,
                stdout: stdoutPipe,
                stderr: stderrPipe)
            do {
                try stdoutPipe.fileHandleForWriting.close()
                if stderrPipe !== stdoutPipe { try stderrPipe.fileHandleForWriting.close() }
            } catch {
                try? child.terminate()
                throw error
            }
            return WindowsManagedProcess(child: child, console: nil)
        }
    }

    var terminationStatus: Int32? {
        self.child.terminationStatus
    }

    func terminate() async {
        _ = await Task.detached { self.terminateSynchronously() }.value
    }

    func terminateResidualProcesses() async {
        await self.terminate()
    }

    func finish() async {
        await self.terminate()
    }

    var isRunning: Bool {
        self.lock.withLock {
            if self.child.isRunning { return true }
            if self.observedExit == nil { self.observedExit = Date() }
            return false
        }
    }

    var exitObservationDate: Date? {
        _ = self.isRunning
        return self.lock.withLock { self.observedExit }
    }

    @discardableResult
    func terminateSynchronously() -> Int32? {
        try? self.child.terminate()
        _ = self.child.wait(milliseconds: 5000)
        // ConPTY can retain the output pipe after the application exits. Closing it emits the final
        // frame while its dedicated reader continues draining, then exposes EOF to the shared runner.
        self.console?.close()
        return self.child.terminationStatus
    }

    func finishSynchronously() -> Int32? {
        self.terminateSynchronously()
    }

    func close() {
        self.terminateSynchronously()
        Self.registry.remove(self)
    }

    var processIdentifier: Int32 {
        Int32(bitPattern: self.child.processIdentifier)
    }

    func descendantIdentifiers() -> [Int32] {
        self.child.descendantIdentifiers().map { Int32(bitPattern: $0) }
    }

    static func beginLaunch() -> Bool {
        self.registry.beginLaunch()
    }

    static func endLaunch() {
        self.registry.endLaunch()
    }

    static func acceptsRegisteredProcess(pid: Int32) -> Bool {
        self.registry.lookup(pid: pid, acceptingLaunch: true) != nil
    }

    static func closeOwnedProcess(pid: Int32) {
        // Registry lookup returns the original owner and handle, never an OpenProcess result for a reused PID.
        self.registry.lookup(pid: pid)?.close()
    }

    static func ownedDescendants(pid: Int32) -> [Int32] {
        self.registry.lookup(pid: pid)?.descendantIdentifiers() ?? []
    }

    static func terminateActiveProcessesForAppShutdown() {
        self.registry.shutdown()
    }
}
#endif
