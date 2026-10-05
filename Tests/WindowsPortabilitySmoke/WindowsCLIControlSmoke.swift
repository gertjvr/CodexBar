#if os(Windows)
import Foundation
import WinSDK

enum WindowsCLIControlSmoke {
    private final class Recorder: @unchecked Sendable {
        let signal = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            self.lock.withLock { self.value }
        }

        func record(_ number: Int32) {
            precondition(number == 2)
            self.lock.withLock { self.value += 1 }
            self.signal.signal()
        }
    }

    static func runFixture() throws {
        let first = Recorder()
        let second = Recorder()
        let firstMonitor = try CLIWindowsControlMonitor(onSignal: { first.record($0) }, onClose: {
            preconditionFailure("Ctrl+Break was mistaken for console close")
        })
        let secondMonitor = try CLIWindowsControlMonitor(onSignal: { second.record($0) }, onClose: {
            preconditionFailure("Ctrl+Break was mistaken for console close")
        })
        precondition(GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), 0))
        precondition(first.signal.wait(timeout: .now() + 5) == .success)
        precondition(second.signal.wait(timeout: .now() + 5) == .success)
        firstMonitor.cancel()
        firstMonitor.cancel()
        precondition(GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), 0))
        precondition(second.signal.wait(timeout: .now() + 5) == .success)
        precondition(first.count == 1 && second.count == 2)
        secondMonitor.cancel()
        // With the final monitor removed, Windows' default handler must terminate this child.
        precondition(GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), 0))
        Thread.sleep(forTimeInterval: 5)
        preconditionFailure("Cancelling the last monitor did not restore default control handling")
    }

    static func run() throws {
        // A separate pseudoconsole keeps generated control events away from the test runner.
        let console = try WindowsPseudoConsole(rows: 30, columns: 100)
        defer { console.close() }
        let child = try WindowsChildProcess.launchPTY(
            binary: CommandLine.arguments[0],
            arguments: ["--process-control"],
            environment: ProcessInfo.processInfo.environment,
            console: console)
        defer { try? child.terminate() }
        precondition(child.wait(milliseconds: 15000), "Console control fixture hung")
        precondition(child.terminationStatus == Int32(bitPattern: 0xC000_013A), "Unexpected control fixture exit")
        print("Windows CLI control handling passed: callbacks, cancellation, and default handler restoration")
    }
}
#endif
