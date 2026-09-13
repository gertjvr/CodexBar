import Foundation

extension TTYCommandRunner {
    public struct Result: Sendable {
        public enum Completion: Sendable, Equatable {
            case processExited(status: Int32)
            case idleTimeout
            case outputCondition
            case deadlineExceeded
        }

        public let text: String
        public let completion: Completion
    }

    public struct Options: Sendable {
        public var rows: UInt16 = 50
        public var cols: UInt16 = 160
        public var timeout: TimeInterval = 20.0
        /// Stop early once output has been idle for this long (only for non-Codex flows).
        /// Useful for interactive TUIs that render once and then wait for input indefinitely.
        public var idleTimeout: TimeInterval?
        public var workingDirectory: URL?
        public var extraArgs: [String] = []
        public var baseEnvironment: [String: String]?
        public var initialDelay: TimeInterval = 0.4
        public var sendEnterEvery: TimeInterval?
        public var sendOnSubstrings: [String: String]
        public var stopOnURL: Bool
        public var stopOnSubstrings: [String]
        public var settleAfterStop: TimeInterval
        public var forceCodexStatusMode: Bool
        public var useProviderProbeWorkingDirectory: Bool
        public var returnOnEmptyProcessExit: Bool
        public var cancellationCheck: @Sendable () -> Bool

        public init(
            rows: UInt16 = 50,
            cols: UInt16 = 160,
            timeout: TimeInterval = 20.0,
            idleTimeout: TimeInterval? = nil,
            workingDirectory: URL? = nil,
            extraArgs: [String] = [],
            baseEnvironment: [String: String]? = nil,
            initialDelay: TimeInterval = 0.4,
            sendEnterEvery: TimeInterval? = nil,
            sendOnSubstrings: [String: String] = [:],
            stopOnURL: Bool = false,
            stopOnSubstrings: [String] = [],
            settleAfterStop: TimeInterval = 0.25,
            forceCodexStatusMode: Bool = false,
            useProviderProbeWorkingDirectory: Bool = false,
            returnOnEmptyProcessExit: Bool = false,
            cancellationCheck: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled })
        {
            self.rows = rows
            self.cols = cols
            self.timeout = timeout
            self.idleTimeout = idleTimeout
            self.workingDirectory = workingDirectory
            self.extraArgs = extraArgs
            self.baseEnvironment = baseEnvironment
            self.initialDelay = initialDelay
            self.sendEnterEvery = sendEnterEvery
            self.sendOnSubstrings = sendOnSubstrings
            self.stopOnURL = stopOnURL
            self.stopOnSubstrings = stopOnSubstrings
            self.settleAfterStop = settleAfterStop
            self.forceCodexStatusMode = forceCodexStatusMode
            self.useProviderProbeWorkingDirectory = useProviderProbeWorkingDirectory
            self.returnOnEmptyProcessExit = returnOnEmptyProcessExit
            self.cancellationCheck = cancellationCheck
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case binaryNotFound(String)
        case launchFailed(String)
        case timedOut
        case outputTooLarge

        public var errorDescription: String? {
            switch self {
            case let .binaryNotFound(bin):
                "Missing CLI '\(bin)'. Install it (e.g. npm i -g @openai/codex) or add it to PATH."
            case let .launchFailed(msg): "Failed to launch process: \(msg)"
            case .timedOut: "PTY command timed out."
            case .outputTooLarge: "PTY command produced more output than CodexBar can safely process."
            }
        }
    }
}
