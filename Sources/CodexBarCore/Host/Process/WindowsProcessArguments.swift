import Foundation

enum WindowsProcessArguments {
    /// Microsoft C runtime argument quoting. This is for executables, not cmd.exe command text.
    static func commandLine(binary: String, arguments: [String]) throws -> [UInt16] {
        guard !binary.contains("\""), !binary.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
        let values = [binary] + arguments
        guard !values.contains(where: { $0.utf16.contains(0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let line = values.map(self.quote).joined(separator: " ")
        let encoded = Array(line.utf16) + [0]
        guard encoded.count <= 32767 else { throw CocoaError(.fileReadInvalidFileName) }
        return encoded
    }

    static func quote(_ value: String) -> String {
        var result = "\""
        var backslashes = 0
        for character in value {
            if character == "\\" {
                backslashes += 1
                continue
            }
            if character == "\"" {
                result += String(repeating: "\\", count: backslashes * 2 + 1)
            } else {
                result += String(repeating: "\\", count: backslashes)
            }
            backslashes = 0
            result.append(character)
        }
        result += String(repeating: "\\", count: backslashes * 2)
        return result + "\""
    }

    static func environmentBlock(_ environment: [String: String]) throws -> [UInt16] {
        let entries = try WindowsEnvironment.canonicalized(environment).sorted { $0.key < $1.key }.map { key, value in
            let bytes = Array(key.utf8)
            // Windows uses =C: entries to carry per-drive current directories.
            let isDriveDirectory = bytes.count == 3 && bytes[0] == 61 && (65...90).contains(bytes[1]) && bytes[2] == 58
            guard !key.isEmpty, !key.contains("=") || isDriveDirectory, !key.utf16.contains(0), !value.utf16.contains(0)
            else { throw CocoaError(.fileReadInvalidFileName) }
            return "\(key)=\(value)\0"
        }
        return Array(entries.joined().utf16) + (entries.isEmpty ? [0, 0] : [0])
    }
}
