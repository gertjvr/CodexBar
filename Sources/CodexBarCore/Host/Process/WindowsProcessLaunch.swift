#if os(Windows)
import Foundation
import WinSDK

struct WindowsProcessLaunch {
    let executable: String
    let commandLine: [UInt16]

    static func prepare(binary: String, arguments: [String], environment: [String: String]) throws -> Self {
        let direct = try WindowsProcessArguments.commandLine(binary: binary, arguments: arguments)
        guard ["cmd", "bat"].contains(URL(fileURLWithPath: binary).pathExtension.lowercased()) else {
            return Self(executable: binary, commandLine: direct)
        }
        guard !([binary] + arguments).contains(where: { $0.contains("\r") || $0.contains("\n") }) else {
            throw SubprocessRunnerError.launchFailed("Windows command scripts cannot accept newline arguments")
        }
        let configured = WindowsEnvironment.value("COMSPEC", in: environment)
        let interpreter = try configured.flatMap { $0.isEmpty ? nil : $0 } ?? self.systemInterpreter()
        let prefix = try WindowsProcessArguments.commandLine(binary: interpreter, arguments: [])
        let script = URL(fileURLWithPath: binary).standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
        var parts = [self.escapeMetaCharacters(script)]
        for argument in arguments {
            // A batch shim forwards %* through a second command parse. Preserve CRT quotes and backslashes
            // through both parses, as npm's Windows spawn implementation does for .cmd/.bat entry points.
            let quoted = WindowsProcessArguments.quote(argument)
            parts.append(self.escapeMetaCharacters(self.escapeMetaCharacters(quoted)))
        }
        let command = String(decoding: prefix.dropLast(), as: UTF16.self)
            + " /d /s /v:off /c \"" + parts.joined(separator: " ") + "\""
        guard command.utf16.count <= 8191 else {
            throw SubprocessRunnerError.launchFailed("Windows command-script command line exceeds 8191 characters")
        }
        return Self(executable: interpreter, commandLine: Array(command.utf16) + [0])
    }

    private static func escapeMetaCharacters(_ value: String) -> String {
        let special = Set("()[]%!^`\"<>&|;, *?")
        return value.reduce(into: "") { output, character in
            if special.contains(character) { output.append("^") }
            output.append(character)
        }
    }

    private static func systemInterpreter() throws -> String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = GetSystemDirectoryW(&buffer, UINT(buffer.count))
        guard count > 0, count < buffer.count else {
            throw SubprocessRunnerError.launchFailed("Windows command interpreter is unavailable")
        }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self) + "\\cmd.exe"
    }
}
#endif
