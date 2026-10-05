#if os(Windows)
import Foundation

final class AntigravityWindowsProcessHandle: AntigravityCLIProcessHandle, @unchecked Sendable {
    private let process: WindowsManagedProcess
    private let console: WindowsPseudoConsole

    init(process: WindowsManagedProcess, console: WindowsPseudoConsole) {
        self.process = process
        self.console = console
    }

    var pid: Int32 {
        self.process.processIdentifier
    }

    var isRunning: Bool {
        self.process.isRunning
    }

    /// Job objects own the tree on Windows; there is no POSIX process group to assign.
    var processGroup: Int32? {
        nil
    }

    func assignProcessGroup() -> Int32? {
        nil
    }

    func sendExit() throws {
        try self.console.send("/exit\r")
    }

    func closePTY() {
        self.process.close()
    }

    func terminateRoot() {
        self.process.close()
    }

    func killRoot() {
        self.process.close()
    }

    func descendantPIDs() -> [Int32] {
        self.process.descendantIdentifiers()
    }

    func terminateTree(signal _: Int32, knownDescendants _: [Int32]) {
        self.process.close()
    }

    func killDescendants(_: [Int32]) {
        self.process.close()
    }

    func drainOutput() -> Data {
        do {
            return try self.console.readAvailable().data
        } catch {
            CodexBarLog.logger(LogCategories.provider(.antigravity)).warning(
                "Antigravity terminal read failed", metadata: ["error": error.localizedDescription])
            self.process.close()
            return Data()
        }
    }
}
#endif
