import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCodexCostPortabilityTests {
    @Test
    func `remote costs retain one protected SSH invocation and a remote Unix shell`() throws {
        let arguments = try RemoteCodexCostFetcher.arguments(host: "fixture@example.test", historyDays: 7, force: true)
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("ForwardAgent=no"))
        #expect(arguments.contains("ClearAllForwardings=yes"))
        let host = try #require(arguments.firstIndex(of: "fixture@example.test"))
        #expect(arguments[host - 1] == "--")
        #expect(Array(arguments[(host + 1)...].prefix(2)) == ["sh", "-lc"])
        let command = try #require(arguments.last)
        #expect(command.contains("--summary-only --provider-native-only --days 7 --refresh"))
        #expect(command.contains("then exec codexbar"))
        #expect(command.contains("else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"))
    }

    #if os(Windows)
    @Test
    func `SSH lookup uses quoted absolute PATH and PATHEXT without launching a fixture`() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = root.appendingPathComponent("preferred café", isDirectory: true)
        let fallback = root.appendingPathComponent("Windows/System32/OpenSSH", isDirectory: true)
        try FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        let executable = preferred.appendingPathComponent("ssh.EXE")
        try Data("synthetic executable selection only".utf8).write(to: executable)
        try Data("fallback selection only".utf8).write(to: fallback.appendingPathComponent("ssh.exe"))
        let environment = [
            "Path": ".;relative;C:drive-relative;\"\(preferred.path)\"",
            "PathExt": ".EXE;.CMD",
            "SystemRoot": root.appendingPathComponent("Windows").path,
        ]
        #expect(RemoteCodexCostFetcher.windowsSSHExecutable(environment: environment) == executable.path)
    }

    @Test
    func `SSH lookup falls back to SystemRoot and never searches the working directory`() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let systemRoot = root.appendingPathComponent("Windows", isDirectory: true)
        let directory = systemRoot.appendingPathComponent("System32/OpenSSH", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ssh.exe")
        try Data("synthetic executable selection only".utf8).write(to: executable)
        #expect(RemoteCodexCostFetcher.windowsSSHExecutable(environment: [
            "PATH": ".;relative;C:drive-relative;\\root-relative",
            "SYSTEMROOT": systemRoot.path,
        ]) == executable.path)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: false)
        #expect(RemoteCodexCostFetcher.windowsSSHExecutable(environment: ["SYSTEMROOT": systemRoot.path]) == nil)
    }

    @Test
    func `remote fetch preserves Windows SSH selectors and removes provider credentials`() async throws {
        let fetcher = RemoteCodexCostFetcher { arguments, environment in
            #expect(arguments.contains("fixture@example.test"))
            #expect(environment["PATH"] == "D:\\safe")
            #expect(environment["PATHEXT"] == ".EXE")
            #expect(environment["SYSTEMROOT"] == "D:\\Windows")
            #expect(environment["USERPROFILE"] == "D:\\Users\\fixture")
            #expect(environment["SSH_AUTH_SOCK"] == "synthetic-agent")
            #expect(environment["PROVIDER_API_KEY"] == nil)
            #expect(environment["HTTPS_PROXY"] == nil)
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            try await fetcher.fetch(host: "fixture@example.test", historyDays: 7, environment: [
                "Path": "C:\\ignored",
                "PATH": ".;relative;D:\\safe",
                "PathExt": ".EXE",
                "SystemRoot": "D:\\Windows",
                "UserProfile": "D:\\Users\\fixture",
                "SSH_AUTH_SOCK": "synthetic-agent",
                "PROVIDER_API_KEY": "synthetic-secret",
                "HTTPS_PROXY": "https://proxy.example.test",
            ])
        }
    }

    private static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Remote cost SSH café \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    #endif
}
