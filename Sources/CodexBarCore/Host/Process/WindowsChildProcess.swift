#if os(Windows)
import Foundation
import WinSDK

/// Owns the entire child tree before its first instruction runs. Handles never escape this owner.
final class WindowsChildProcess: @unchecked Sendable {
    let processIdentifier: DWORD
    private let process: HANDLE
    private let job: HANDLE

    private init(process: HANDLE, job: HANDLE, identifier: DWORD) {
        self.process = process
        self.job = job
        self.processIdentifier = identifier
    }

    deinit {
        // KILL_ON_JOB_CLOSE also covers descendants whose parent has already exited.
        _ = CloseHandle(self.job)
        _ = CloseHandle(self.process)
    }

    var isRunning: Bool {
        WaitForSingleObject(self.process, 0) == DWORD(WAIT_TIMEOUT)
    }

    var terminationStatus: Int32? {
        guard WaitForSingleObject(self.process, 0) == DWORD(WAIT_OBJECT_0) else { return nil }
        var status: DWORD = 0
        guard GetExitCodeProcess(self.process, &status) else { return nil }
        return Int32(bitPattern: status)
    }

    /// Enumerate the owned job, including nested jobs, without scanning unrelated host processes.
    func descendantIdentifiers() -> [DWORD] {
        var capacity = 16
        while capacity <= 65536 {
            guard let offset = MemoryLayout<JOBOBJECT_BASIC_PROCESS_ID_LIST>.offset(of: \.ProcessIdList)
            else { return [] }
            let bytes = offset + capacity * MemoryLayout<ULONG_PTR>.stride
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: bytes, alignment: MemoryLayout<JOBOBJECT_BASIC_PROCESS_ID_LIST>.alignment)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            let succeeded = QueryInformationJobObject(
                self.job, JobObjectBasicProcessIdList, buffer, DWORD(bytes), nil)
            let header = buffer.load(as: JOBOBJECT_BASIC_PROCESS_ID_LIST.self)
            if !succeeded {
                guard GetLastError() == DWORD(ERROR_MORE_DATA) else { return [] }
                capacity = max(capacity * 2, Int(header.NumberOfAssignedProcesses))
                continue
            }
            let count = Int(header.NumberOfProcessIdsInList)
            guard count <= capacity else { return [] }
            if count < Int(header.NumberOfAssignedProcesses) {
                capacity = max(capacity * 2, Int(header.NumberOfAssignedProcesses))
                continue
            }
            let ids = buffer.advanced(by: offset).assumingMemoryBound(to: ULONG_PTR.self)
            return UnsafeBufferPointer(start: ids, count: count).compactMap { value in
                guard let pid = DWORD(exactly: value), pid != self.processIdentifier else { return nil }
                return pid
            }
        }
        return []
    }

    @discardableResult
    func wait(milliseconds: DWORD) -> Bool {
        WaitForSingleObject(self.process, milliseconds) == DWORD(WAIT_OBJECT_0)
    }

    func terminate() throws {
        guard TerminateJobObject(self.job, 1) else { throw Self.windowsError() }
    }

    static func launch(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        standardInput: FileHandle? = nil,
        stdout: Pipe,
        stderr: Pipe) throws -> WindowsChildProcess
    {
        try self.launch(
            binary: binary,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            standardInput: standardInput,
            stdout: stdout,
            stderr: stderr,
            console: nil)
    }

    static func launchPTY(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        console: WindowsPseudoConsole) throws -> WindowsChildProcess
    {
        let child = try console.withHandle { handle in
            try self.launch(
                binary: binary,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                standardInput: nil,
                stdout: nil,
                stderr: nil,
                console: handle)
        }
        do { try console.didLaunch() } catch {
            try? child.terminate()
            throw error
        }
        return child
    }

    // Shared CreateProcess implementation for pipe and pseudoconsole launch adapters.
    // swiftlint:disable:next function_parameter_count
    private static func launch(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        standardInput: FileHandle?,
        stdout: Pipe?,
        stderr: Pipe?,
        console: HPCON?) throws -> WindowsChildProcess
    {
        let launch = try WindowsProcessLaunch.prepare(binary: binary, arguments: arguments, environment: environment)
        var commandLine = launch.commandLine
        var environmentBlock = try WindowsProcessArguments.environmentBlock(environment)
        guard let job = CreateJobObjectW(nil, nil) else { throw self.windowsError() }
        var transferred = false
        defer { if !transferred { _ = CloseHandle(job) } }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        guard SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &limits,
            DWORD(MemoryLayout.size(ofValue: limits)))
        else { throw self.windowsError() }

        var inherited: [HANDLE] = []
        defer { for handle in inherited {
            _ = CloseHandle(handle)
        } }
        if console == nil {
            guard let stdout, let stderr else { throw CocoaError(.executableLoad) }
            let input: HANDLE
            if let standardInput {
                input = try self.inheritableDuplicate(standardInput._handle)
            } else {
                let name = Array("NUL".utf16) + [0]
                var attributes = SECURITY_ATTRIBUTES(
                    nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                    lpSecurityDescriptor: nil,
                    bInheritHandle: true)
                let handle = name.withUnsafeBufferPointer {
                    CreateFileW(
                        $0.baseAddress,
                        DWORD(GENERIC_READ),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                        &attributes,
                        DWORD(OPEN_EXISTING),
                        DWORD(FILE_ATTRIBUTE_NORMAL),
                        nil)
                }
                guard let handle, handle != INVALID_HANDLE_VALUE else { throw self.windowsError() }
                input = handle
            }
            inherited.append(input)
            let output = try self.inheritableDuplicate(stdout.fileHandleForWriting._handle)
            inherited.append(output)
            let errorOutput = try self.inheritableDuplicate(stderr.fileHandleForWriting._handle)
            inherited.append(errorOutput)
        }
        var handles = inherited.map(Optional.some)

        var attributeSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeSize)
        guard attributeSize > 0 else { throw self.windowsError() }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(attributeSize), alignment: 16)
        defer { storage.deallocate() }
        let attributeList = OpaquePointer(storage)
        guard InitializeProcThreadAttributeList(attributeList, 1, 0, &attributeSize) else {
            throw self.windowsError()
        }
        defer { DeleteProcThreadAttributeList(attributeList) }
        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        // ConPTY needs explicit null standard handles when the host's streams are redirected.
        // Otherwise Windows can duplicate the host's pipes instead of connecting terminal handles.
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        if console == nil {
            startup.StartupInfo.hStdInput = inherited[0]
            startup.StartupInfo.hStdOutput = inherited[1]
            startup.StartupInfo.hStdError = inherited[2]
        }
        startup.lpAttributeList = attributeList
        var information = PROCESS_INFORMATION()
        let application = Array(launch.executable.utf16) + [0]
        let directory = Array((currentDirectoryURL?.path ?? FileManager.default.currentDirectoryPath).utf16) + [0]
        let created = try handles.withUnsafeMutableBytes { inherited in
            if let console {
                // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE from processthreadsapi.h.
                guard UpdateProcThreadAttribute(
                    attributeList, 0, 0x0002_0016, console, SIZE_T(MemoryLayout<HPCON>.size), nil, nil)
                else { throw self.windowsError() }
            } else {
                // PROC_THREAD_ATTRIBUTE_HANDLE_LIST is a compound SDK macro not exposed by Swift.
                guard UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    0x0002_0002,
                    inherited.baseAddress,
                    SIZE_T(inherited.count),
                    nil,
                    nil)
                else { throw self.windowsError() }
            }
            return application.withUnsafeBufferPointer { application in
                directory.withUnsafeBufferPointer { directory in
                    commandLine.withUnsafeMutableBufferPointer { command in
                        environmentBlock.withUnsafeMutableBytes { environment in
                            withUnsafeMutablePointer(to: &startup) { startup in
                                startup.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) {
                                    CreateProcessW(
                                        application.baseAddress,
                                        command.baseAddress,
                                        nil,
                                        nil,
                                        console == nil,
                                        DWORD(CREATE_SUSPENDED) | DWORD(CREATE_UNICODE_ENVIRONMENT)
                                            | DWORD(EXTENDED_STARTUPINFO_PRESENT)
                                            | (console == nil ? DWORD(CREATE_NO_WINDOW) : 0),
                                        environment.baseAddress,
                                        directory.baseAddress,
                                        $0,
                                        &information)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard created, let process = information.hProcess, let thread = information.hThread else {
            throw self.windowsError()
        }
        defer { _ = CloseHandle(thread) }
        do {
            guard AssignProcessToJobObject(job, process) else { throw self.windowsError() }
            guard ResumeThread(thread) != DWORD.max else { throw self.windowsError() }
        } catch {
            _ = TerminateProcess(process, 1)
            _ = WaitForSingleObject(process, 5000)
            _ = CloseHandle(process)
            throw error
        }
        transferred = true
        return WindowsChildProcess(process: process, job: job, identifier: information.dwProcessId)
    }

    private static func inheritableDuplicate(_ handle: HANDLE) throws -> HANDLE {
        var duplicate: HANDLE?
        guard DuplicateHandle(
            GetCurrentProcess(),
            handle,
            GetCurrentProcess(),
            &duplicate,
            0,
            true,
            DWORD(DUPLICATE_SAME_ACCESS)), let duplicate
        else { throw self.windowsError() }
        return duplicate
    }

    private static func windowsError() -> NSError {
        NSError(domain: "Win32", code: Int(GetLastError()))
    }
}
#endif
