import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

enum CostUsageJsonl {
    struct Line {
        let bytes: Data
        let wasTruncated: Bool
        let startOffset: Int64
        let endOffset: Int64

        init(
            bytes: Data,
            wasTruncated: Bool,
            startOffset: Int64 = 0,
            endOffset: Int64 = 0)
        {
            self.bytes = bytes
            self.wasTruncated = wasTruncated
            self.startOffset = startOffset
            self.endOffset = endOffset
        }
    }

    struct ResumeState: Codable, Equatable {
        let offset: Int64
        fileprivate let lineStartOffset: Int64
        fileprivate let prefix: Data
        fileprivate let lineBytes: Int
        fileprivate let truncated: Bool
        fileprivate let jsonTailState: JSONTailState
    }

    struct ScanProgress {
        let committedOffset: Int64
        let readOffset: Int64
        let resumeState: ResumeState?
    }

    fileprivate struct JSONTailState: Codable, Equatable {
        private enum ScalarState: Codable, Equatable {
            case notScalar
            case trueLiteral(Int)
            case falseLiteral(Int)
            case nullLiteral(Int)
            case number(NumberState)
            case invalid
        }

        private enum NumberState: Codable, Equatable {
            private enum ByteKind {
                case zero
                case digit
                case decimalPoint
                case exponentMarker
                case sign
                case whitespace
                case other

                init(_ byte: UInt8) {
                    switch byte {
                    case 0x30: self = .zero
                    case 0x31...0x39: self = .digit
                    case 0x2E: self = .decimalPoint
                    case 0x65, 0x45: self = .exponentMarker
                    case 0x2B, 0x2D: self = .sign
                    case 0x20, 0x09, 0x0A, 0x0D: self = .whitespace
                    default: self = .other
                    }
                }
            }

            case sign
            case zero
            case integer
            case decimalPoint
            case fraction
            case exponentMarker
            case exponentSign
            case exponentDigits
            case finished
            case invalid

            var canCommitAtEOF: Bool {
                switch self {
                case .finished, .invalid:
                    true
                case .sign, .zero, .integer, .decimalPoint, .fraction,
                     .exponentMarker, .exponentSign, .exponentDigits:
                    false
                }
            }

            func appending(_ byte: UInt8) -> Self {
                switch (self, ByteKind(byte)) {
                case (.invalid, _): .invalid
                case (.finished, .whitespace): .finished
                case (.sign, .zero): .zero
                case (.sign, .digit): .integer
                case (.zero, .decimalPoint): .decimalPoint
                case (.zero, .exponentMarker): .exponentMarker
                case (.integer, .zero), (.integer, .digit): .integer
                case (.integer, .decimalPoint): .decimalPoint
                case (.integer, .exponentMarker): .exponentMarker
                case (.decimalPoint, .zero), (.decimalPoint, .digit): .fraction
                case (.fraction, .zero), (.fraction, .digit): .fraction
                case (.fraction, .exponentMarker): .exponentMarker
                case (.exponentMarker, .sign): .exponentSign
                case (.exponentMarker, .zero), (.exponentMarker, .digit): .exponentDigits
                case (.exponentSign, .zero), (.exponentSign, .digit): .exponentDigits
                case (.exponentDigits, .zero), (.exponentDigits, .digit): .exponentDigits
                case (.zero, .whitespace),
                     (.integer, .whitespace),
                     (.fraction, .whitespace),
                     (.exponentDigits, .whitespace): .finished
                default: .invalid
                }
            }
        }

        private static let trueLiteral = Array("true".utf8)
        private static let falseLiteral = Array("false".utf8)
        private static let nullLiteral = Array("null".utf8)

        private var containerDepth = 0
        private var insideString = false
        private var escaping = false
        private var sawNonWhitespace = false
        private var scalarState = ScalarState.notScalar

        /// Persisted Codable checkpoints can contain unusual counters. Preserve the scalar updater
        /// when skipping could bypass checked depth arithmetic or literal indexing.
        func canSkipTerminatedSpanUpdates(count: Int) -> Bool {
            guard self.containerDepth >= 0, self.containerDepth <= Int.max - count else { return false }
            switch self.scalarState {
            case let .trueLiteral(matched), let .falseLiteral(matched), let .nullLiteral(matched):
                return matched >= 0
            case .notScalar, .number, .invalid:
                return true
            }
        }

        mutating func reset() {
            self = Self()
        }

        var isStructurallyComplete: Bool {
            guard self.sawNonWhitespace else { return false }
            switch self.scalarState {
            case .notScalar:
                return !self.insideString && self.containerDepth == 0
            case let .trueLiteral(matched):
                return matched == Self.trueLiteral.count
            case let .falseLiteral(matched):
                return matched == Self.falseLiteral.count
            case let .nullLiteral(matched):
                return matched == Self.nullLiteral.count
            case let .number(state):
                return state.canCommitAtEOF
            case .invalid:
                return true
            }
        }

        mutating func append(_ byte: UInt8) {
            if !self.sawNonWhitespace {
                self.start(byte)
                return
            }

            guard !self.appendScalar(byte) else { return }
            self.appendContainer(byte)
        }

        private mutating func start(_ byte: UInt8) {
            guard !Self.isWhitespace(byte) else { return }
            self.sawNonWhitespace = true
            switch byte {
            case 0x22:
                self.insideString = true
            case 0x7B, 0x5B:
                self.containerDepth = 1
            case 0x74:
                self.scalarState = .trueLiteral(1)
            case 0x66:
                self.scalarState = .falseLiteral(1)
            case 0x6E:
                self.scalarState = .nullLiteral(1)
            case 0x2D:
                self.scalarState = .number(.sign)
            case 0x30:
                self.scalarState = .number(.zero)
            case 0x31...0x39:
                self.scalarState = .number(.integer)
            default:
                self.scalarState = .invalid
            }
        }

        private mutating func appendScalar(_ byte: UInt8) -> Bool {
            switch self.scalarState {
            case let .trueLiteral(matched):
                self.scalarState = self.advanceLiteral(byte, expected: Self.trueLiteral, matched: matched)
                    .map(ScalarState.trueLiteral) ?? .invalid
                return true
            case let .falseLiteral(matched):
                self.scalarState = self.advanceLiteral(byte, expected: Self.falseLiteral, matched: matched)
                    .map(ScalarState.falseLiteral) ?? .invalid
                return true
            case let .nullLiteral(matched):
                self.scalarState = self.advanceLiteral(byte, expected: Self.nullLiteral, matched: matched)
                    .map(ScalarState.nullLiteral) ?? .invalid
                return true
            case let .number(state):
                self.scalarState = .number(state.appending(byte))
                return true
            case .invalid:
                return true
            case .notScalar:
                return false
            }
        }

        private mutating func appendContainer(_ byte: UInt8) {
            if self.insideString {
                if self.escaping {
                    self.escaping = false
                } else if byte == 0x5C {
                    self.escaping = true
                } else if byte == 0x22 {
                    self.insideString = false
                }
                return
            }

            switch byte {
            case 0x20, 0x09, 0x0D:
                return
            case 0x22:
                self.insideString = true
            case 0x7B, 0x5B:
                self.containerDepth += 1
            case 0x7D, 0x5D:
                self.containerDepth = max(0, self.containerDepth - 1)
            default:
                break
            }
        }

        private func advanceLiteral(
            _ byte: UInt8,
            expected: [UInt8],
            matched: Int) -> Int?
        {
            if matched < expected.count {
                return byte == expected[matched] ? matched + 1 : nil
            }
            return Self.isWhitespace(byte) ? matched : nil
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scan(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            maxBytesToRead: nil,
            checkCancellation: nil,
            onLine: onLine)
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        maxBytesToRead: Int64? = nil,
        checkCancellation: (() throws -> Void)? = nil,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scanBounded(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            maxBytesToRead: maxBytesToRead,
            resumeState: nil,
            shouldStop: nil,
            checkCancellation: checkCancellation,
            onLine: onLine).committedOffset
    }

    /// Keep scan state in one owner rather than mutable local captures shared by nested closures.
    /// Swift 6.3.3 on Windows fails SIL verification when optimizing the captured scalar boxes.
    private final class ScanState {
        var current: Data
        var lineBytes: Int
        var truncated: Bool
        var bytesRead: Int64 = 0
        var lineStartOffset: Int64
        var committedOffset: Int64
        var jsonTailState: JSONTailState
        let startOffset: Int64
        let maxLineBytes: Int
        let prefixBytes: Int

        init(startOffset: Int64, maxLineBytes: Int, prefixBytes: Int, resumeState: ResumeState?) {
            self.startOffset = startOffset
            self.maxLineBytes = maxLineBytes
            self.prefixBytes = prefixBytes
            self.current = resumeState?.prefix ?? Data()
            self.current.reserveCapacity(4 * 1024)
            self.lineBytes = resumeState?.lineBytes ?? 0
            self.truncated = resumeState?.truncated ?? false
            self.lineStartOffset = resumeState?.lineStartOffset ?? startOffset
            self.committedOffset = self.lineStartOffset
            self.jsonTailState = resumeState?.jsonTailState ?? JSONTailState()
        }

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            self.lineBytes += count
            if self.current.count < self.prefixBytes {
                let appendCount = min(self.prefixBytes - self.current.count, count)
                if appendCount > 0 {
                    self.current.append(bytes, count: appendCount)
                }
            }
            if self.lineBytes > self.maxLineBytes || self.lineBytes > self.prefixBytes {
                self.truncated = true
            }
        }

        func flushLine(endOffset: Int64, onLine: (Line) -> Void) {
            guard self.lineBytes > 0 else { return }
            let line = Line(
                bytes: self.current,
                wasTruncated: self.truncated,
                startOffset: self.lineStartOffset,
                endOffset: endOffset)
            onLine(line)
            self.current.removeAll(keepingCapacity: true)
            self.lineBytes = 0
            self.truncated = false
            self.jsonTailState.reset()
        }

        func currentResumeState() -> ResumeState? {
            guard self.lineBytes > 0 else { return nil }
            return ResumeState(
                offset: self.startOffset + self.bytesRead,
                lineStartOffset: self.lineStartOffset,
                prefix: self.current,
                lineBytes: self.lineBytes,
                truncated: self.truncated,
                jsonTailState: self.jsonTailState)
        }

        func hasCompleteJSONTail() -> Bool {
            guard self.jsonTailState.isStructurallyComplete else { return false }
            if self.truncated {
                // The full record is intentionally not retained. Its incremental state is enough
                // to keep incomplete containers, strings, literals, and numbers retriable.
                return true
            }
            guard self.lineBytes == self.current.count else { return false }
            return (try? JSONSerialization.jsonObject(with: self.current, options: [.fragmentsAllowed])) != nil
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func scanBounded(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        maxBytesToRead: Int64?,
        resumeState: ResumeState?,
        shouldStop: ((Int64) -> Bool)? = nil,
        checkCancellation: (() throws -> Void)? = nil,
        onLine: (Line) -> Void) throws -> ScanProgress
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = resumeState?.offset ?? max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        let state = ScanState(
            startOffset: startOffset, maxLineBytes: maxLineBytes, prefixBytes: prefixBytes, resumeState: resumeState)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .int64Value

        while true {
            try checkCancellation?()
            if state.bytesRead > 0, shouldStop?(state.bytesRead) == true {
                break
            }
            let remaining = maxBytesToRead.map { max(0, $0 - state.bytesRead) }
            if remaining == 0 {
                if let fileSize, startOffset + state.bytesRead >= fileSize, state.hasCompleteJSONTail() {
                    state.flushLine(endOffset: startOffset + state.bytesRead, onLine: onLine)
                    state.committedOffset = startOffset + state.bytesRead
                    state.lineStartOffset = state.committedOffset
                }
                break
            }
            let reachedEOF = try autoreleasepool {
                let readCount = min(256 * 1024, Int(remaining ?? Int64(256 * 1024)))
                let chunk = try handle.read(upToCount: readCount) ?? Data()
                if chunk.isEmpty {
                    if state.hasCompleteJSONTail() {
                        state.flushLine(endOffset: startOffset + state.bytesRead, onLine: onLine)
                        state.committedOffset = startOffset + state.bytesRead
                        state.lineStartOffset = state.committedOffset
                    }
                    return true
                }

                try checkCancellation?()
                state.bytesRead += Int64(chunk.count)
                let chunkStartOffset = startOffset + state.bytesRead - Int64(chunk.count)
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var segmentStart = 0
                    while segmentStart < rawBuffer.count {
                        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(ucrt)
                        guard let newline = memchr(
                            base.advanced(by: segmentStart),
                            0x0A,
                            rawBuffer.count - segmentStart) else { break }
                        let index = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
                        #else
                        var index = segmentStart
                        while index < rawBuffer.count, base[index] != 0x0A {
                            index += 1
                        }
                        guard index < rawBuffer.count else { break }
                        #endif
                        // A negative decoded line count can keep tail state alive across the flush.
                        if state.lineBytes < 0 || !state.jsonTailState
                            .canSkipTerminatedSpanUpdates(count: index - segmentStart)
                        {
                            for byteIndex in segmentStart..<index {
                                state.jsonTailState.append(base[byteIndex])
                            }
                        }
                        state.appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                        let lineEndOffset = chunkStartOffset + Int64(index + 1)
                        state.flushLine(endOffset: lineEndOffset, onLine: onLine)
                        state.committedOffset = lineEndOffset
                        state.lineStartOffset = state.committedOffset
                        segmentStart = index + 1
                    }
                    if segmentStart < rawBuffer.count {
                        for index in segmentStart..<rawBuffer.count {
                            state.jsonTailState.append(base[index])
                        }
                        state.appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                    }
                }
                return false
            }
            if reachedEOF {
                break
            }
            try checkCancellation?()
        }

        return ScanProgress(
            committedOffset: state.committedOffset,
            readOffset: startOffset + state.bytesRead,
            resumeState: state.currentResumeState())
    }
}
