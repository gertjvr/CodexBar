#if os(Windows)
import Foundation

enum WindowsRPCSmoke {
    static func run() async throws {
        let process = RPCChildProcess()
        let input = RPCChildProcessInput()
        let output = Pipe()
        let errors = Pipe()
        try process.launch(
            executable: CommandLine.arguments[0],
            arguments: ["--process-rpc"],
            environment: ProcessInfo.processInfo.environment,
            stdin: input.pipe,
            stdout: output,
            stderr: errors)
        defer { RPCChildProcessTeardown.terminate(process: process, stdin: input) }
        precondition(process.isRunning)
        let stream = AsyncStream<Data>.makeStream()
        let lines = BoundedLineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stream.continuation.finish()
                return
            }
            let result = lines.appendAndDrainLines(chunk)
            precondition(!result.didExceedLimit)
            for line in result.lines {
                stream.continuation.yield(line)
            }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        for identifier in 1...2 {
            var request = try JSONSerialization.data(withJSONObject: [
                "id": identifier,
                "method": "fixture/read",
                "params": ["message": "café 测试"],
            ])
            request.append(0x0A)
            try input.write(request)
            let response = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    for await line in stream.stream {
                        return line
                    }
                    throw CocoaError(.fileReadUnknown)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CocoaError(.fileReadUnknown)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let result = decoded["result"] as? [String: String]
            else { preconditionFailure("Malformed RPC fixture response") }
            precondition(decoded["id"] as? Int == identifier)
            precondition(result["message"] == "café 测试")
        }
        RPCChildProcessTeardown.terminate(process: process, stdin: input)
        precondition(!process.isRunning, "RPC shutdown left its child running")
        do {
            try input.write(Data("after shutdown".utf8))
            preconditionFailure("Closed RPC input accepted another request")
        } catch is CocoaError {}
        print("Windows RPC smoke passed: repeated requests, streamed responses, and shutdown")
    }
}
#endif
