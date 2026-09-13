import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
enum WindowsHTTPServerSmoke {
    static func main() async throws {
        let body = Data(("café 测试 " + String(repeating: "x", count: 300_000)).utf8)
        // Repeated lifetimes catch cleanup that makes the next listener unusable.
        for _ in 0..<2 {
            let server = CLILocalHTTPServer(host: "127.0.0.1", port: 0) { _ in
                CLILocalHTTPResponse(status: .ok, body: body, extraHeaders: [("X-Fixture", "native")])
            }
            let task = Task.detached { try await server.run() }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while server.listeningPort == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let port = server.listeningPort else {
                    throw NSError(domain: "HTTPFixture", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP listener did not become ready",
                    ])
                }
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let url = URL(string: "http://127.0.0.1:\(port)/fixture")!
                var request = URLRequest(url: url, timeoutInterval: 5)
                let (data, response) = try await session.data(for: request)
                precondition(data == body, "Response body changed during socket transmission")
                precondition((response as? HTTPURLResponse)?.statusCode == 200)
                precondition((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Fixture") == "native")
                request.setValue("evil.test", forHTTPHeaderField: "Host")
                let (_, forbidden) = try await session.data(for: request)
                precondition((forbidden as? HTTPURLResponse)?.statusCode == 403, "Host allowlist was bypassed")
                server.stop()
                try await task.value
            } catch {
                server.stop()
                _ = try? await task.value
                throw error
            }
        }
        print("HTTP server checks passed: ephemeral bind, Unicode body, headers, Host allowlist, and restart")
    }
}
