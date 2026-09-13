#if os(Windows)
import Foundation
import WinSDK

private func handleCLIWindowsControl(_ event: DWORD) -> WindowsBool {
    CLIWindowsControlMonitor.dispatch(event) ? true : false
}

final class CLIWindowsControlMonitor: @unchecked Sendable {
    private struct Callbacks: Sendable {
        let onSignal: @Sendable (Int32) -> Void
        let onClose: @Sendable () -> Void
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var callbacks: [Foundation.UUID: Callbacks] = [:]
    }

    private static let registry = Registry()
    private let identifier: Foundation.UUID

    init(onSignal: @escaping @Sendable (Int32) -> Void, onClose: @escaping @Sendable () -> Void) throws {
        let identifier = Foundation.UUID()
        try Self.registry.lock.withLock {
            if Self.registry.callbacks.isEmpty, !SetConsoleCtrlHandler(handleCLIWindowsControl, true) {
                throw NSError(domain: "Win32", code: Int(GetLastError()), userInfo: [
                    NSLocalizedDescriptionKey: "Could not install the Windows console shutdown handler",
                ])
            }
            Self.registry.callbacks[identifier] = Callbacks(onSignal: onSignal, onClose: onClose)
        }
        self.identifier = identifier
    }

    func cancel() {
        Self.registry.lock.withLock {
            guard Self.registry.callbacks.removeValue(forKey: self.identifier) != nil else { return }
            if Self.registry.callbacks.isEmpty {
                _ = SetConsoleCtrlHandler(handleCLIWindowsControl, false)
            }
        }
    }

    deinit {
        self.cancel()
    }

    fileprivate static func dispatch(_ event: DWORD) -> Bool {
        let signal: Int32
        let closing: Bool
        switch event {
        case DWORD(CTRL_C_EVENT), DWORD(CTRL_BREAK_EVENT):
            signal = 2
            closing = false
        case DWORD(CTRL_CLOSE_EVENT), DWORD(CTRL_LOGOFF_EVENT), DWORD(CTRL_SHUTDOWN_EVENT):
            signal = 15
            closing = true
        default:
            return false
        }
        let callbacks = Self.registry.lock.withLock { Array(Self.registry.callbacks.values) }
        guard !callbacks.isEmpty else { return false }
        // Console control callbacks execute on a Windows-created thread. Invoke outside the lock,
        // allowing callbacks to cancel monitors or finish a command without blocking registration.
        // Closing the console terminates the process as soon as this handler returns, so drain
        // owned helpers synchronously before signalling the command's asynchronous shutdown path.
        for callback in callbacks {
            if closing { callback.onClose() }
            callback.onSignal(signal)
        }
        return true
    }
}
#endif
