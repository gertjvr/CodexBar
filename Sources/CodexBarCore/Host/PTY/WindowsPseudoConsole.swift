#if os(Windows)
import Foundation
import WinSDK

/// Drains terminal output independently of input writes and ClosePseudoConsole's final frame.
final class WindowsPseudoConsole: @unchecked Sendable {
    private final class OutputReader: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var data = Data()
        private var failure: Error?
        private var ended = false
        private let limit = 1024 * 1024

        init(handle: FileHandle) {
            self.handle = handle
        }

        func run() {
            defer {
                try? self.handle.close()
                self.lock.withLock { self.ended = true }
            }
            do {
                var bytes = [UInt8](repeating: 0, count: 16384)
                while true {
                    var count: DWORD = 0
                    let succeeded = bytes.withUnsafeMutableBytes {
                        ReadFile(self.handle._handle, $0.baseAddress, DWORD($0.count), &count, nil)
                    }
                    if !succeeded {
                        let code = GetLastError()
                        if code == DWORD(ERROR_BROKEN_PIPE) { break }
                        throw NSError(domain: "Win32", code: Int(code))
                    }
                    if count == 0 { break }
                    let chunk = Data(bytes.prefix(Int(count)))
                    self.lock.withLock {
                        guard self.failure == nil else { return }
                        guard chunk.count <= self.limit - self.data.count else {
                            self.failure = SubprocessRunnerError.outputTooLarge("Windows terminal output")
                            return
                        }
                        self.data.append(chunk)
                    }
                }
            } catch {
                self.lock.withLock { self.failure = error }
            }
        }

        func take() throws -> (data: Data, ended: Bool) {
            try self.lock.withLock {
                if let failure = self.failure { throw failure }
                let result = self.data
                self.data.removeAll(keepingCapacity: true)
                return (result, self.ended)
            }
        }
    }

    private final class InputWriter: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.steipete.codexbar.windows-terminal-input")
        private let handle: FileHandle
        private var closed = false
        private var pendingBytes = 0
        private var failure: Error?

        init(handle: FileHandle) {
            self.handle = handle
        }

        func send(_ data: Data) throws {
            try self.lock.withLock {
                if let failure = self.failure { throw failure }
                guard !self.closed else { throw CocoaError(.fileWriteUnknown) }
                guard data.count <= 65536 - self.pendingBytes else {
                    throw SubprocessRunnerError.outputTooLarge("Windows terminal input")
                }
                self.pendingBytes += data.count
                self.queue.async {
                    defer { self.lock.withLock { self.pendingBytes -= data.count } }
                    do { try self.handle.write(contentsOf: data) } catch {
                        self.lock.withLock { self.failure = error }
                    }
                }
            }
        }

        func close() {
            self.lock.withLock {
                guard !self.closed else { return }
                self.closed = true
                self.queue.async { try? self.handle.close() }
            }
        }
    }

    private let lock = NSLock()
    private var handle: HPCON?
    private let input = Pipe()
    private let output = Pipe()
    private let reader: OutputReader
    private let writer: InputWriter

    init(rows: UInt16, columns: UInt16) throws {
        self.reader = OutputReader(handle: self.output.fileHandleForReading)
        self.writer = InputWriter(handle: self.input.fileHandleForWriting)
        let size = try Self.size(rows: rows, columns: columns)
        var handle: HPCON?
        let status = CreatePseudoConsole(
            size, self.input.fileHandleForReading._handle, self.output.fileHandleForWriting._handle, 0, &handle)
        guard status >= 0, let handle else { throw Self.error(status) }
        self.handle = handle
        let reader = self.reader
        Thread.detachNewThread { reader.run() }
    }

    deinit { self.close() }

    func withHandle<T>(_ body: (HPCON) throws -> T) throws -> T {
        try self.lock.withLock {
            guard let handle = self.handle else { throw CocoaError(.executableLoad) }
            return try body(handle)
        }
    }

    /// Called after the hosted process attaches, releasing the parent's copies of ConPTY's ends.
    func didLaunch() throws {
        try self.input.fileHandleForReading.close()
        try self.output.fileHandleForWriting.close()
    }

    func send(_ text: String) throws {
        try self.send(Data(text.utf8))
    }

    func send(_ data: Data) throws {
        try self.writer.send(data)
    }

    func readAvailable() throws -> (data: Data, ended: Bool) {
        try self.reader.take()
    }

    func resize(rows: UInt16, columns: UInt16) throws {
        let size = try Self.size(rows: rows, columns: columns)
        try self.withHandle {
            let result = ResizePseudoConsole($0, size)
            guard result >= 0 else { throw Self.error(result) }
        }
    }

    func close() {
        let handle = self.lock.withLock {
            let value = self.handle
            self.handle = nil
            return value
        }
        guard let handle else { return }
        // The reader remains alive throughout this call, including its final output frame.
        ClosePseudoConsole(handle)
        try? self.input.fileHandleForReading.close()
        try? self.output.fileHandleForWriting.close()
        self.writer.close()
    }

    private static func size(rows: UInt16, columns: UInt16) throws -> COORD {
        guard rows > 0, columns > 0, rows <= UInt16(Int16.max), columns <= UInt16(Int16.max) else {
            throw CocoaError(.coderInvalidValue)
        }
        return COORD(X: Int16(columns), Y: Int16(rows))
    }

    private static func error(_ status: HRESULT) -> NSError {
        NSError(domain: "HRESULT", code: Int(status))
    }
}
#endif
