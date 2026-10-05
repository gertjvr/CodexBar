#if os(Windows)
import CodexBarCore
import Foundation
import WinSDK

@main
enum WindowsTrayMain {
    static func main() {
        do {
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--smoke-dashboard" {
                let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
                let snapshot = try TraySnapshot.decode(Data(contentsOf: fixture))
                try WindowsTrayHost.shared.run(initialSnapshot: snapshot, smoke: true)
                return
            }
            let directory = try self.executableDirectory()
            let binary = directory.appendingPathComponent("codexbar.exe").path
            let environment = ProcessInfo.processInfo.environment
            let smokeCLI = CommandLine.arguments == [CommandLine.arguments[0], "--smoke-cli"]
            if smokeCLI {
                guard environment["CODEXBAR_CONFIG"]?.isEmpty == false,
                      environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
                      environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] == "1",
                      environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
                else { throw CocoaError(.fileReadNoPermission) }
            }
            try WindowsTrayHost.shared.run(
                smoke: smokeCLI,
                refresh: {
                    if smokeCLI {
                        let settings = try await SubprocessRunner.run(
                            binary: binary,
                            arguments: ["config", "providers", "--json"],
                            environment: environment,
                            timeout: 15,
                            maxOutputBytes: 1024 * 1024,
                            label: "windows-tray-smoke-settings")
                        let providers = try JSONDecoder().decode(
                            [TrayProviderConfiguration].self, from: Data(settings.stdout.utf8))
                        guard !providers.isEmpty, providers.allSatisfy({ !$0.enabled }) else {
                            throw CocoaError(.fileReadNoPermission)
                        }
                    }
                    let result = try await SubprocessRunner.run(
                        binary: binary,
                        arguments: ["dashboard", "--timeout", "30"],
                        environment: environment,
                        timeout: 45,
                        maxOutputBytes: 4 * 1024 * 1024,
                        label: "windows-tray-dashboard")
                    return try TraySnapshot.decode(Data(result.stdout.utf8))
                }, configuration: {
                    let store = CodexBarConfigStore()
                    _ = try store.loadOrCreateDefault()
                    let argument = "\"\(store.fileURL.path)\""
                    var systemDirectory = [WCHAR](repeating: 0, count: 32768)
                    let count = GetSystemDirectoryW(&systemDirectory, UINT(systemDirectory.count))
                    guard count > 0, count < systemDirectory.count else { throw CocoaError(.fileReadUnknown) }
                    let editorPath = URL(fileURLWithPath: String(
                        decoding: systemDirectory.prefix(Int(count)), as: UTF16.self))
                        .appendingPathComponent("notepad.exe").path
                    let launched = editorPath.withCString(encodedAs: UTF16.self) { editor in
                        argument.withCString(encodedAs: UTF16.self) { argument in
                            ShellExecuteW(nil, nil, editor, argument, nil, SW_SHOWNORMAL)
                        }
                    }
                    guard Int(bitPattern: launched) > 32 else {
                        throw CocoaError(.executableLoad, userInfo: [
                            NSLocalizedDescriptionKey: "Could not open the configuration in Notepad.",
                        ])
                    }
                }, settings: { change in
                    if let change {
                        _ = try await SubprocessRunner.run(
                            binary: binary,
                            arguments: [
                                "config",
                                change.enabled ? "enable" : "disable",
                                "--provider",
                                change.provider,
                                "--json",
                            ],
                            environment: environment,
                            timeout: 15,
                            maxOutputBytes: 1024 * 1024,
                            label: "windows-tray-provider-setting")
                    }
                    let result = try await SubprocessRunner.run(
                        binary: binary,
                        arguments: ["config", "providers", "--json"],
                        environment: environment,
                        timeout: 15,
                        maxOutputBytes: 1024 * 1024,
                        label: "windows-tray-provider-settings")
                    return try JSONDecoder().decode([TrayProviderConfiguration].self, from: Data(result.stdout.utf8))
                })
        } catch {
            if CommandLine.arguments.contains("--smoke-dashboard") || CommandLine.arguments.contains("--smoke-cli") {
                ExitProcess(1)
            }
            let message = "CodexBar could not start: \(error.localizedDescription)"
            message.withCString(encodedAs: UTF16.self) { message in
                "CodexBar".withCString(encodedAs: UTF16.self) { title in
                    _ = MessageBoxW(nil, message, title, UINT(MB_OK | MB_ICONERROR))
                }
            }
            ExitProcess(1)
        }
    }

    private static func executableDirectory() throws -> URL {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard count > 0, count < buffer.count else { throw CocoaError(.fileReadUnknown) }
        return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(count)), as: UTF16.self))
            .deletingLastPathComponent()
    }
}
#endif
