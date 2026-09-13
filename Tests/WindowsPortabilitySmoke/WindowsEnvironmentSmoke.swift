#if os(Windows)
import Foundation

enum WindowsEnvironmentSmoke {
    static func run(in root: URL) throws {
        let block = try WindowsProcessArguments.environmentBlock(["=c:": "C:\\fixture", "Path": "old", "PATH": "new"])
        precondition(String(decoding: block, as: UTF16.self) == "=C:=C:\\fixture\0PATH=new\0\0")
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin café 测试")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("fixture.EXE")
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
        // npm installs both Unix and Windows shims. PATHEXT candidates must precede the Unix file.
        try Data("unix fixture shim".utf8).write(to: bin.appendingPathComponent("fixture"))
        try Data("batch fixture shim".utf8).write(to: bin.appendingPathComponent("fixture.CMD"))
        var environment = ProcessInfo.processInfo.environment
        let inherited = WindowsEnvironment.value("PATH", in: environment) ?? ""
        environment["Path"] = "C:\\not-the-explicit-override"
        environment["PATH"] = "\"\(bin.path)\";\(inherited)"
        environment["PathExt"] = ".EXE;.CMD"
        environment.removeValue(forKey: "PATHEXT")
        let effective = WindowsEnvironment.effectivePATH(environment: environment)
        precondition(effective.hasPrefix(bin.path + ";"))
        precondition(!effective.contains("not-the-explicit-override"))
        precondition(WindowsEnvironment.pathEntries("C:\\one;\"D:\\two words\";;") == ["C:\\one", "D:\\two words"])
        precondition(WindowsEnvironment.effectivePATH(environment: ["Path": "C:\\one;c:\\ONE;D:\\two"])
            == "C:\\one;D:\\two")
        let paths = WindowsEnvironment.pathEntries(effective)
        guard let found = WindowsEnvironment.findExecutable("fixture", paths: paths, environment: environment) else {
            preconditionFailure("PATHEXT executable lookup failed")
        }
        precondition(URL(fileURLWithPath: found).lastPathComponent == "fixture.EXE")
        let rejected = WindowsEnvironment
            .findExecutable("fixture", paths: [bin.path], environment: environment) { _, _ in
                false
            }
        precondition(rejected == nil, "Launch candidate filter was bypassed")
        let result = try WindowsSubprocessRunner.runSynchronously(
            binary: found,
            arguments: ["--process-echo", "discovered fixture"],
            environment: environment,
            timeout: 5)
        precondition(result.stderr == "fixture stderr", "Discovered executable did not launch with merged PATH")
        print("Windows environment smoke passed: PATH overrides, delimiters, PATHEXT, and discovered executable launch")
    }
}
#endif
