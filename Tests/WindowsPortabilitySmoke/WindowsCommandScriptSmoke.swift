#if os(Windows)
import Foundation

enum WindowsCommandScriptSmoke {
    static func run(in root: URL) throws {
        let directory = root.appendingPathComponent("command scripts café 测试", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: CommandLine.arguments[0]), to: directory.appendingPathComponent("fixture.exe"))
        let script = directory.appendingPathComponent("fixture.cmd")
        try Data("@echo off\r\n\"%~dp0fixture.exe\" %*\r\n".utf8).write(to: script)
        let arguments = ["", "two words", "café 测试", "quote\"inside", "trailing\\", "\\\\\"", "&|<>^%!()", "%PATH%"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_CHILD_FIXTURE"] = "command script fixture"
        let result = try WindowsSubprocessRunner.runSynchronously(
            binary: script.path,
            arguments: ["--process-echo"] + arguments,
            environment: environment,
            timeout: 5)
        let value = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        precondition(value?["arguments"] as? [String] == arguments, "Command script changed literal arguments")
        precondition(value?["environment"] as? String == "command script fixture")
        precondition(result.stderr == "fixture stderr")
        do {
            _ = try WindowsSubprocessRunner.runSynchronously(
                binary: script.path, arguments: ["--process-exit"], environment: environment, timeout: 5)
            preconditionFailure("Command script lost its exit status")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            precondition(code == 7 && stderr == "fixture failure")
        }
        do {
            _ = try WindowsSubprocessRunner.runSynchronously(
                binary: script.path, arguments: ["--process-sleep"], environment: environment, timeout: 0.05)
            preconditionFailure("Command script did not time out")
        } catch SubprocessRunnerError.timedOut {}
        do {
            _ = try WindowsProcessLaunch.prepare(
                binary: script.path,
                arguments: ["line\nbreak"],
                environment: environment)
            preconditionFailure("Command script accepted an unrepresentable argument")
        } catch SubprocessRunnerError.launchFailed {}
        print("Windows command scripts passed: Unicode paths, literal argv, exit status, and timeout")
    }
}
#endif
