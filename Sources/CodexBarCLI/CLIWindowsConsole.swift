#if os(Windows)
import WinSDK

enum CLIWindowsConsole {
    static func executablePath() -> String? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard count > 0, count < buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
    }

    static func isTerminal(_ standardHandle: DWORD) -> Bool {
        guard let handle = GetStdHandle(standardHandle), handle != INVALID_HANDLE_VALUE else { return false }
        var mode: DWORD = 0
        return GetConsoleMode(handle, &mode)
    }

    static func enableOutputColor() -> Bool {
        guard let handle = GetStdHandle(STD_OUTPUT_HANDLE), handle != INVALID_HANDLE_VALUE else { return false }
        var mode: DWORD = 0
        guard GetConsoleMode(handle, &mode) else { return false }
        return SetConsoleMode(handle, mode | DWORD(ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING))
    }

    static func columnCount() -> Int? {
        guard let handle = GetStdHandle(STD_OUTPUT_HANDLE), handle != INVALID_HANDLE_VALUE else { return nil }
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        guard GetConsoleScreenBufferInfo(handle, &info) else { return nil }
        let columns = Int(info.srWindow.Right) - Int(info.srWindow.Left) + 1
        return columns > 0 ? columns : nil
    }

    static var isInteractive: Bool {
        self.isTerminal(STD_INPUT_HANDLE) && self.isTerminal(STD_ERROR_HANDLE)
    }
}
#endif
