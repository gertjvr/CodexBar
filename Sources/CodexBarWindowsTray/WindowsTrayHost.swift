#if os(Windows)
import Foundation
import WinSDK

private func trayWindowProcedure(_ window: HWND?, _ message: UINT, _ word: WPARAM, _ value: LPARAM) -> LRESULT {
    WindowsTrayHost.shared.handle(window, message: message, word: word, value: value)
}

/// Window state belongs to the message-loop thread. Background refreshes communicate only
/// through the locked pending update and PostMessage; they never touch controls or presentation state.
final class WindowsTrayHost: @unchecked Sendable {
    static let shared = WindowsTrayHost()
    private static let trayMessage = UINT(WM_APP + 1)
    private static let taskbarCreatedMessage = "TaskbarCreated".withCString(encodedAs: UTF16.self) {
        RegisterWindowMessageW($0)
    }

    private static let settingsMessage = UINT(WM_APP + 3)
    private static let updateMessage = UINT(WM_APP + 2)
    private let pendingLock = NSLock()
    private var pending: Result<TraySnapshot, TrayRefreshFailure>?
    private var pendingSettings: Result<[TrayProviderConfiguration], TrayRefreshFailure>?
    private var settingsAction: (@Sendable (TrayProviderChange?) async throws -> [TrayProviderConfiguration])?
    private var settingsTask: Task<Void, Never>?
    private var settingsRows: [TrayProviderConfiguration] = []
    private var settingsError: String?
    private var settingsVisible = false
    private var selectedSettingsProvider: String?
    private var window: HWND?
    private var state = TrayPresentationState()
    private struct Control {
        let window: HWND
        let x: Int32
        let y: Int32
    }

    private let drawing = WindowsTrayDrawing()
    private var controls: [Control] = []
    private var scrollOffset: Int32 = 0
    private var viewportHeight: Int32 = 360
    private var viewportWidth: Int32 = 360
    private var fonts: [HFONT] = []
    private var icon = NOTIFYICONDATAW()
    private var scale = 1.0
    private var height: Int32 = 360
    private var refreshTask: Task<Void, Never>?
    private var refreshAction: (@Sendable () async throws -> TraySnapshot)?
    private var configurationAction: (() throws -> Void)?
    private var smoke = false
    private var menuAccountIDs: [String] = []
    private var menuProviderID: String?

    struct TrayRefreshFailure: Error, Sendable {
        let message: String
    }

    func run(
        initialSnapshot: TraySnapshot? = nil,
        smoke: Bool = false,
        refresh: (@Sendable () async throws -> TraySnapshot)? = nil,
        configuration: (() throws -> Void)? = nil,
        settings: (@Sendable (TrayProviderChange?) async throws -> [TrayProviderConfiguration])? = nil) throws
    {
        self.smoke = smoke
        self.refreshAction = refresh
        self.configurationAction = configuration
        self.settingsAction = settings
        if let initialSnapshot { self.state.accept(initialSnapshot) }
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
        var common = INITCOMMONCONTROLSEX()
        common.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
        common.dwICC = DWORD(ICC_PROGRESS_CLASS)
        guard InitCommonControlsEx(&common) else { throw Self.windowsError("Initialize controls") }
        let instance = GetModuleHandleW(nil)
        let className = "CodexBar.WindowsTray"
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = trayWindowProcedure
        windowClass.hInstance = instance
        windowClass.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))
            ?? LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        windowClass.hIconSm = windowClass.hIcon
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        windowClass.hbrBackground = self.drawing.background
        windowClass.style = UINT(CS_DROPSHADOW)
        let registered = className.withCString(encodedAs: UTF16.self) {
            windowClass.lpszClassName = $0
            return RegisterClassExW(&windowClass)
        }
        guard registered != 0 else { throw Self.windowsError("Register tray window") }
        defer {
            className.withCString(encodedAs: UTF16.self) { _ = UnregisterClassW($0, instance) }
            for font in self.fonts {
                _ = DeleteObject(font)
            }
            self.fonts.removeAll()
        }
        let created = className.withCString(encodedAs: UTF16.self) { name in
            "CodexBar".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(
                    DWORD(WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT),
                    name,
                    title,
                    DWORD(WS_POPUP) | DWORD(WS_VSCROLL),
                    0,
                    0,
                    360,
                    360,
                    nil,
                    nil,
                    instance,
                    nil)
            }
        }
        guard let created else { throw Self.windowsError("Create tray window") }
        self.pendingLock.withLock { self.window = created }
        defer { if IsWindow(created) { _ = DestroyWindow(created) } }
        self.scale = max(1, Double(GetDpiForWindow(created)) / 96)
        self.makeFonts()
        self.icon.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        self.icon.hWnd = created
        self.icon.uID = 1
        self.icon.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        self.icon.uCallbackMessage = Self.trayMessage
        self.icon.hIcon = windowClass.hIcon
        withUnsafeMutableBytes(of: &self.icon.szTip) { bytes in
            let target = bytes.bindMemory(to: WCHAR.self)
            for (index, value) in "CodexBar".utf16.enumerated() {
                target[index] = value
            }
        }
        guard Shell_NotifyIconW(DWORD(NIM_ADD), &self.icon) else { throw Self.windowsError("Add notification icon") }
        defer { _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &self.icon) }
        self.render()
        if smoke { try self.verifyControlFonts() }
        _ = SetTimer(created, 1, 120_000, nil)
        if smoke {
            self.show()
            _ = SetTimer(created, 2, 20000, nil)
        }
        self.refresh()
        var message = MSG()
        while true {
            if PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if message.message == UINT(WM_QUIT) { break }
                if IsDialogMessageW(created, &message) {
                    self.revealFocusedControl()
                } else {
                    _ = TranslateMessage(&message)
                    _ = DispatchMessageW(&message)
                }
            } else {
                guard WaitMessage() else { throw Self.windowsError("Wait for window message") }
            }
        }
    }

    fileprivate func handle(_ window: HWND?, message: UINT, word: WPARAM, value: LPARAM) -> LRESULT {
        switch message {
        case Self.taskbarCreatedMessage:
            if !Shell_NotifyIconW(DWORD(NIM_ADD), &self.icon) {
                self.state.failed("Could not restore the notification icon after Explorer restarted.")
            }
            return 0
        case UINT(WM_DRAWITEM):
            if self.drawing.draw(value, scale: self.scale) { return 1 }
            return 0
        case UINT(WM_CTLCOLORSTATIC):
            let context = HDC(bitPattern: UInt(word))
            _ = SetTextColor(context, self.drawing.textColor(HWND(bitPattern: Int(value))))
            _ = SetBkMode(context, TRANSPARENT)
            return LRESULT(Int(bitPattern: self.drawing.background))
        case Self.trayMessage:
            if value == LPARAM(WM_LBUTTONUP) || value == LPARAM(WM_RBUTTONUP) { self.show() }
            return 0
        case Self.settingsMessage:
            self.applySettingsUpdate()
            return 0
        case Self.updateMessage:
            self.applySnapshotUpdate()
            return 0
        case UINT(WM_COMMAND):
            self.command(Int(word & 0xFFFF))
            return 0
        case UINT(WM_TIMER):
            if word == 2 { _ = DestroyWindow(window) } else { self.refresh() }
            return 0
        case UINT(WM_CLOSE):
            _ = ShowWindow(window, SW_HIDE)
            return 0
        case UINT(WM_ACTIVATE):
            if !self.smoke, word & 0xFFFF == 0 { _ = ShowWindow(window, SW_HIDE) }
        case UINT(WM_DPICHANGED):
            self.changeDPI(word, suggestedBounds: value)
            return 0
        case UINT(WM_VSCROLL):
            self.scrollCommand(Int32(word & 0xFFFF))
            return 0
        case UINT(WM_MOUSEWHEEL):
            let delta = Int32(Int16(bitPattern: UInt16((word >> 16) & 0xFFFF)))
            self.scroll(to: self.scrollOffset - delta * self.px(36) / 120)
            return 0
        case UINT(WM_DESTROY):
            self.refreshTask?.cancel()
            self.settingsTask?.cancel()
            self.pendingLock.withLock { self.window = nil }
            PostQuitMessage(0)
            return 0
        default:
            break
        }
        return DefWindowProcW(window, message, word, value)
    }

    private func applySettingsUpdate() {
        self.settingsTask = nil
        if let update = self.pendingLock.withLock({
            let result = self.pendingSettings
            self.pendingSettings = nil
            return result
        }) {
            switch update {
            case let .success(rows):
                self.settingsRows = rows
                self.settingsError = nil
                if !rows.contains(where: { $0.provider == self.selectedSettingsProvider }) {
                    self.selectedSettingsProvider = rows.first?.provider
                }
            case let .failure(error): self.settingsError = error.message
            }
        }
        self.render()
    }

    private func applySnapshotUpdate() {
        self.refreshTask = nil
        if let update = self.pendingLock
            .withLock({ let result = self.pending; self.pending = nil; return result })
        {
            switch update {
            case let .success(snapshot):
                self.state.accept(snapshot)
                let interval = min(3600, max(30, snapshot.host.refreshIntervalSeconds))
                _ = SetTimer(self.window, 1, UINT(interval * 1000), nil)
            case let .failure(error): self.state.failed(error.message)
            }
        }
        self.render()
    }

    private func refresh() {
        guard !self.settingsVisible, self.refreshTask == nil, let refreshAction else { return }
        let refreshButton = GetDlgItem(self.window, 10)
        "Refreshing…".withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(refreshButton, $0) }
        _ = EnableWindow(refreshButton, false)
        self.refreshTask = Task.detached { [self] in
            let result: Result<TraySnapshot, TrayRefreshFailure>
            do {
                result = try await .success(refreshAction())
            } catch {
                result = .failure(TrayRefreshFailure(message: error.localizedDescription))
            }
            let target = self.pendingLock.withLock {
                self.pending = result
                return self.window
            }
            if let target { _ = PostMessageW(target, Self.updateMessage, 0, 0) }
        }
    }

    private func command(_ id: Int) {
        switch id {
        case 2:
            _ = ShowWindow(self.window, SW_HIDE)
        case 10:
            self.refresh()
        case 11:
            _ = DestroyWindow(self.window)
        case 12:
            self.editConfiguration()
        case 13:
            self.showAccounts()
        case 14:
            self.scrollOffset = 0
            self.settingsVisible = true
            self.loadSettings()
        case 15:
            guard self.settingsTask == nil else { return }
            self.scrollOffset = 0
            self.settingsVisible = false
            self.render()
            self.refresh()
        case 16:
            let index = Int(SendMessageW(GetDlgItem(self.window, 16), UINT(CB_GETCURSEL), 0, 0))
            if self.settingsRows.indices.contains(index) {
                self.selectedSettingsProvider = self.settingsRows[index].provider
                self.updateSettingsToggle()
            }
        case 17:
            guard let row = self.settingsRows.first(where: { $0.provider == self.selectedSettingsProvider }) else {
                return
            }
            self.loadSettings(TrayProviderChange(provider: row.provider, enabled: !row.enabled))
        case 100..<1000:
            let index = id - 100
            if self.state.providers.indices.contains(index) {
                self.scrollOffset = 0
                self.state.selectProvider(self.state.providers[index].id)
                self.render()
                _ = SetFocus(GetDlgItem(self.window, Int32(id)))
            }
        case 1000...:
            guard self.menuProviderID == self.state.selectedProviderID else { return }
            let index = id - 1001
            if id == 1000 {
                self.state.selectAccount(nil)
            } else if self.menuAccountIDs.indices.contains(index) {
                self.state.selectAccount(self.menuAccountIDs[index])
            }
            self.render()
        default:
            break
        }
    }

    private func editConfiguration() {
        do {
            try self.configurationAction?()
        } catch {
            if self.settingsVisible {
                self.settingsError = error.localizedDescription
            } else {
                self.state.failed(error.localizedDescription)
            }
            self.render()
        }
    }

    private func showAccounts() {
        guard let menu = CreatePopupMenu() else { return }
        defer { _ = DestroyMenu(menu) }
        self.menuProviderID = self.state.selectedProviderID
        self.menuAccountIDs = self.state.provider?.accounts?.map(\.id) ?? []
        "Current CLI account".withCString(encodedAs: UTF16.self) { _ = AppendMenuW(menu, UINT(MF_STRING), 1000, $0) }
        for (index, account) in (self.state.provider?.accounts ?? []).enumerated() {
            account.label.withCString(encodedAs: UTF16.self) {
                _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(1001 + index), $0)
            }
        }
        var point = POINT()
        _ = GetCursorPos(&point)
        _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, self.window, nil)
    }

    private func show() {
        guard let window = self.window else { return }
        var point = POINT()
        _ = GetCursorPos(&point)
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        _ = GetMonitorInfoW(MonitorFromPoint(point, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
        self.layoutViewport(availableHeight: monitor.rcWork.bottom - monitor.rcWork.top)
        let width = self.viewportWidth
        let height = self.viewportHeight
        let x = max(monitor.rcWork.left + 8, min(point.x - width + 24, monitor.rcWork.right - width - 8))
        let y = max(monitor.rcWork.top + 8, min(point.y - height - 12, monitor.rcWork.bottom - height - 8))
        _ = SetWindowPos(window, nil, x, y, width, height, UINT(SWP_NOZORDER | SWP_SHOWWINDOW))
        _ = SetForegroundWindow(window)
    }

    private func render() {
        guard self.window != nil else { return }
        self.clearControls()
        self.updateTooltip()
        if self.settingsVisible {
            self.renderSettings()
            return
        }
        var y = self.renderProviders(y: 16)
        if let provider = self.state.provider {
            self.separator(y: y)
            y += 18
            self.label(provider.name, y: y, heading: true)
            y += 28
            y = self.renderIdentity(y: y)
            self.separator(y: y)
            y += 20
            if let accounts = provider.accounts, !accounts.isEmpty {
                _ = self.control(
                    "BUTTON",
                    self.state.account?.label ?? "Accounts…",
                    id: 13,
                    frame: (16, y, 328, 28),
                    style: DWORD(WS_TABSTOP))
                y += 38
            }
            for metric in self.state.windows {
                self.label(metric.label, y: y, heading: true)
                y += 30
                self.usageBar(metric, accent: provider.display.accentColor, frame: (16, y, 328, 7))
                y += 17
                self.label(String(format: "%.0f%% used", metric.usedPercent), y: y, width: 125)
                if let reset = metric.resetAt { self.label(
                    Self.resetText(reset),
                    x: 145,
                    y: y,
                    width: 199,
                    secondary: true,
                    right: true) }
                y += 43
            }
            if self.state.account == nil {
                if let credits = provider.credits {
                    self.label(String(format: "Credits: %.2f %@", credits.remaining, credits.unit), y: y)
                    y += 28
                }
                if let cost = provider.cost {
                    self.separator(y: y)
                    y += 20
                    self.label("Cost", y: y, heading: true)
                    y += 26
                    if let today = cost.todayUSD { self.label(String(format: "Today: $%.2f", today), y: y); y += 23 }
                    if let month = cost.last30DaysUSD {
                        self.label(String(format: "Last 30 days: $%.2f", month), y: y)
                        y += 28
                    }
                }
            }
            if let error = provider.accountsError {
                self.label(error, y: y, height: 46)
                y += 52
            }
            if let status = provider.status { self.label(status.label, y: y); y += 25 }
            if let error = self.state.displayError {
                self.label(error, y: y, height: 60)
                y += 66
            }
        } else {
            self.label("CodexBar", y: y, heading: true)
            y += 34
            let emptyText = self.state.refreshError == nil ? "Loading usage…" : "Usage unavailable."
            self.label(self.state.snapshot == nil ? emptyText : "No providers enabled.", y: y)
            y += 40
        }
        if let error = self.state.refreshError { self.label(error, y: y, height: 60); y += 66 }
        self.separator(y: y)
        y += 16
        let refreshButton = self.control(
            "BUTTON",
            self.refreshTask == nil ? "Refresh" : "Refreshing…",
            id: 10,
            frame: (8, y, 344, 36),
            style: DWORD(WS_TABSTOP))
        _ = EnableWindow(refreshButton, self.refreshTask == nil)
        y += 38
        if self.configurationAction != nil || self.settingsAction != nil {
            _ = self.control(
                "BUTTON",
                self.settingsAction == nil ? "Edit configuration…" : "Settings…",
                id: self.settingsAction == nil ? 12 : 14,
                frame: (8, y, 344, 36),
                style: DWORD(WS_TABSTOP))
            y += 38
        }
        _ = self.control("BUTTON", "Quit", id: 11, frame: (8, y, 344, 36), style: DWORD(WS_TABSTOP))
        self.height = y + 48
        self.layoutViewport()
        _ = InvalidateRect(self.window, nil, true)
    }

    private func loadSettings(_ change: TrayProviderChange? = nil) {
        guard self.settingsTask == nil, let settingsAction else { return }
        self.settingsError = nil
        self.settingsTask = Task.detached { [self] in
            let result: Result<[TrayProviderConfiguration], TrayRefreshFailure>
            do {
                result = try await .success(settingsAction(change))
            } catch {
                result = .failure(TrayRefreshFailure(message: error.localizedDescription))
            }
            let target = self.pendingLock.withLock {
                self.pendingSettings = result
                return self.window
            }
            if let target { _ = PostMessageW(target, Self.settingsMessage, 0, 0) }
        }
        self.render()
    }

    private func renderSettings() {
        self.label("Settings", y: 18, heading: true)
        self.label("Providers", y: 60, heading: true)
        self.label("Choose which providers appear in CodexBar.", y: 87)
        let picker = self.control(
            "COMBOBOX",
            "",
            id: 16,
            frame: (16, 117, 328, 240),
            style: DWORD(CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP))
        for (index, row) in self.settingsRows.enumerated() {
            row.displayName.withCString(encodedAs: UTF16.self) {
                _ = SendMessageW(picker, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0)))
            }
            if row.provider == self.selectedSettingsProvider {
                _ = SendMessageW(picker, UINT(CB_SETCURSEL), WPARAM(index), 0)
            }
        }
        _ = self.control("BUTTON", "Loading…", id: 17, frame: (16, 154, 328, 30), style: DWORD(WS_TABSTOP))
        self.updateSettingsToggle()
        if let error = self.settingsError { self.label(error, y: 196, height: 62) }
        if self.configurationAction != nil {
            _ = self.control(
                "BUTTON", "Edit configuration…", id: 12, frame: (16, 270, 214, 30), style: DWORD(WS_TABSTOP))
        }
        _ = self.control("BUTTON", "Back", id: 15, frame: (242, 270, 102, 30), style: DWORD(WS_TABSTOP))
        self.height = 318
        self.layoutViewport()
        _ = InvalidateRect(self.window, nil, true)
    }

    private func updateSettingsToggle() {
        let row = self.settingsRows.first { $0.provider == self.selectedSettingsProvider }
        let button = GetDlgItem(self.window, 17)
        let title = self
            .settingsTask != nil ? "Saving…" : (row?.enabled == true ? "Disable provider" : "Enable provider")
        title.withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(button, $0) }
        _ = EnableWindow(button, row != nil && self.settingsTask == nil)
        _ = EnableWindow(GetDlgItem(self.window, 16), self.settingsTask == nil)
        _ = EnableWindow(GetDlgItem(self.window, 15), self.settingsTask == nil)
    }

    private func renderIdentity(y: Int32) -> Int32 {
        var y = y
        if let email = self.state.identity?.accountEmail { self.label(email, y: y, secondary: true); y += 24 }
        if let updatedAt = self.state.updatedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let age = max(0, Date().timeIntervalSince(updatedAt))
            let stale = age > Double(self.state.snapshot?.staleAfterSeconds ?? 180)
            self.label(
                age < 60 ? "Updated just now" : "Updated " + formatter
                    .string(from: updatedAt) + (stale ? " · Stale" : ""),
                y: y,
                width: 208,
                secondary: true)
        }
        if let plan = self.state.identity?.plan {
            self.label(plan, x: 232, y: y, width: 112, secondary: true, right: true)
        }
        if self.state.updatedAt != nil || self.state.identity?.plan != nil { y += 30 }
        return y
    }

    private func separator(y: Int32) {
        let line = self.control("STATIC", "", id: 0, frame: (16, y, 328, 1), style: DWORD(SS_OWNERDRAW))
        self.drawing.register(line, role: .separator)
    }

    private func renderProviders(y: Int32) -> Int32 {
        for (index, provider) in self.state.providers.enumerated() {
            let column = Int32(index % 4)
            let row = Int32(index / 4)
            let button = self.control(
                "BUTTON",
                provider.name,
                id: 100 + index,
                frame: (16 + column * 83, y + row * 80, 77, 64),
                style: DWORD(WS_TABSTOP))
            self.drawing.register(
                button,
                role: .provider(id: provider.id, selected: provider.id == self.state.selectedProviderID))
            if let metric = provider.windows.first(where: { $0.idle != true }) {
                self.usageBar(
                    metric,
                    accent: provider.display.accentColor,
                    frame: (16 + column * 83, y + row * 80 + 68, 77, 4))
            }
        }
        return y + Int32((self.state.providers.count + 3) / 4) * 80 + 8
    }

    private func usageBar(_ metric: TraySnapshot.Window, accent: String, frame: (Int32, Int32, Int32, Int32)) {
        let bar = self.control("STATIC", "", id: 0, frame: frame, style: DWORD(SS_OWNERDRAW))
        self.drawing.register(bar, role: .meter(fraction: metric.filledFraction, accent: Self.accentColor(accent)))
    }

    private func label(
        _ text: String,
        x: Int32 = 16,
        y: Int32,
        width: Int32 = 328,
        height: Int32 = 25,
        heading: Bool = false,
        secondary: Bool = false,
        right: Bool = false)
    {
        let control = self.control(
            "STATIC",
            text,
            id: 0,
            frame: (x, y, width, height),
            style: DWORD(SS_NOPREFIX | SS_ENDELLIPSIS) | (right ? DWORD(SS_RIGHT) : DWORD(SS_LEFT)))
        if secondary { self.drawing.secondary(control) }
        if heading, self.fonts.count > 1 {
            _ = SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: self.fonts[1])), 1)
        }
    }

    @discardableResult
    private func control(
        _ kind: String,
        _ text: String,
        id: Int,
        frame: (Int32, Int32, Int32, Int32),
        style: DWORD) -> HWND?
    {
        let child = kind.withCString(encodedAs: UTF16.self) { className in
            text.withCString(encodedAs: UTF16.self) { text in
                CreateWindowExW(
                    0,
                    className,
                    text,
                    DWORD(WS_CHILD | WS_VISIBLE) | style | (kind == "BUTTON" ? DWORD(BS_OWNERDRAW) : 0),
                    self.px(frame.0),
                    self.px(frame.1) - self.scrollOffset,
                    self.px(frame.2),
                    self.px(frame.3),
                    self.window,
                    HMENU(bitPattern: id),
                    GetModuleHandleW(nil),
                    nil)
            }
        }
        if let child {
            self.controls.append(Control(window: child, x: frame.0, y: frame.1))
            if kind == "BUTTON" { self.drawing.register(child, role: .action) }
            if let font = self.fonts
                .first { _ = SendMessageW(child, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), 1) }
        }
        return child
    }

    private var maximumScroll: Int32 {
        max(0, self.px(self.height) - self.viewportHeight)
    }

    private func layoutViewport(availableHeight: Int32? = nil) {
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        _ = GetMonitorInfoW(MonitorFromWindow(self.window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
        let available = availableHeight ?? (monitor.rcWork.bottom - monitor.rcWork.top)
        self.viewportHeight = min(self.px(self.height), max(self.px(100), available - self.px(16)))
        let overflow = self.maximumScroll > 0
        let scrollbar = overflow ? GetSystemMetricsForDpi(SM_CXVSCROLL, UINT(self.scale * 96)) : 0
        self.viewportWidth = self.px(360) + scrollbar
        _ = ShowScrollBar(self.window, SB_VERT, overflow)
        let region = CreateRoundRectRgn(0, 0, self.viewportWidth + 1, self.viewportHeight + 1, self.px(20), self.px(20))
        if SetWindowRgn(self.window, region, true) == 0, let region { _ = DeleteObject(region) }
        _ = SetWindowPos(
            self.window,
            nil,
            0,
            0,
            self.viewportWidth,
            self.viewportHeight,
            UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
        var info = SCROLLINFO()
        info.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        info.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS)
        info.nMax = max(0, self.px(self.height) - self.px(2) - 1)
        info.nPage = UINT(max(1, self.viewportHeight - self.px(2)))
        info.nPos = min(self.scrollOffset, self.maximumScroll)
        _ = SetScrollInfo(self.window, SB_VERT, &info, true)
        self.scroll(to: overflow ? self.scrollOffset : 0)
    }

    private func revealFocusedControl() {
        guard self.maximumScroll > 0,
              let focused = GetFocus(),
              let control = self.controls.first(where: { $0.window == focused })
        else { return }
        var bounds = RECT()
        guard GetWindowRect(focused, &bounds) else { return }
        let top = self.px(control.y)
        let bottom = top + bounds.bottom - bounds.top
        if top < self.scrollOffset {
            self.scroll(to: top - self.px(8))
        } else if bottom > self.scrollOffset + self.viewportHeight - self.px(2) {
            self.scroll(to: bottom - self.viewportHeight + self.px(8))
        }
    }

    private func scroll(to requested: Int32) {
        let position = max(0, min(requested, self.maximumScroll))
        guard position != self.scrollOffset else { return }
        self.scrollOffset = position
        _ = SetScrollPos(self.window, SB_VERT, position, true)
        for control in self.controls {
            _ = SetWindowPos(
                control.window,
                nil,
                self.px(control.x),
                self.px(control.y) - position,
                0,
                0,
                UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        }
        _ = InvalidateRect(self.window, nil, true)
    }

    private func scrollCommand(_ command: Int32) {
        var info = SCROLLINFO()
        info.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        info.fMask = UINT(SIF_TRACKPOS)
        _ = GetScrollInfo(self.window, SB_VERT, &info)
        let destination: Int32 = switch command {
        case SB_TOP: 0
        case SB_BOTTOM: self.maximumScroll
        case SB_LINEUP: self.scrollOffset - self.px(24)
        case SB_LINEDOWN: self.scrollOffset + self.px(24)
        case SB_PAGEUP: self.scrollOffset - self.viewportHeight
        case SB_PAGEDOWN: self.scrollOffset + self.viewportHeight
        case SB_THUMBTRACK, SB_THUMBPOSITION: info.nTrackPos
        default: self.scrollOffset
        }
        self.scroll(to: destination)
    }

    private func changeDPI(_ word: WPARAM, suggestedBounds: LPARAM) {
        let previousScale = self.scale
        self.scale = max(1, Double(word & 0xFFFF) / 96)
        self.scrollOffset = Int32(Double(self.scrollOffset) * self.scale / previousScale)
        if let bounds = UnsafePointer<RECT>(bitPattern: Int(suggestedBounds))?.pointee {
            _ = SetWindowPos(
                self.window,
                nil,
                bounds.left,
                bounds.top,
                bounds.right - bounds.left,
                bounds.bottom - bounds.top,
                UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        self.clearControls()
        for font in self.fonts {
            _ = DeleteObject(font)
        }
        self.fonts.removeAll()
        self.makeFonts()
        self.render()
    }

    private func updateTooltip() {
        let usage = self.state.windows.map { "\($0.label): " + String(format: "%.0f%% used", $0.usedPercent) }
        let lines = [self.state.provider?.name ?? "CodexBar"] + usage
        var units = Array(lines.joined(separator: "\n").utf16.prefix(127))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        withUnsafeMutableBytes(of: &self.icon.szTip) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            let target = bytes.bindMemory(to: WCHAR.self)
            for (index, unit) in units.enumerated() {
                target[index] = unit
            }
        }
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &self.icon)
    }

    private func clearControls() {
        self.drawing.clear()
        for control in self.controls {
            _ = DestroyWindow(control.window)
        }
        self.controls.removeAll()
    }
}

/// Font resources and measurements share the window lifecycle, independently of command routing.
extension WindowsTrayHost {
    private func makeFonts() {
        for (size, weight) in [(Int32(17), Int32(FW_NORMAL)), (Int32(20), Int32(FW_SEMIBOLD))] {
            let font = "Segoe UI Variable Text".withCString(encodedAs: UTF16.self) {
                CreateFontW(
                    -self.px(size),
                    0,
                    0,
                    0,
                    weight,
                    0,
                    0,
                    0,
                    DWORD(DEFAULT_CHARSET),
                    DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS),
                    DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH | FF_SWISS),
                    $0)
            }
            if let font {
                self.fonts.append(font)
                if self.smoke { self.reportFont(font, size: size, weight: weight) }
            }
        }
    }

    private func verifyControlFonts() throws {
        var checked = 0
        for control in self.controls {
            var className = [WCHAR](repeating: 0, count: 128)
            guard GetClassNameW(control.window, &className, Int32(className.count)) > 0 else {
                throw Self.windowsError("Read control class")
            }
            let name = String(decoding: className.prefix { $0 != 0 }, as: UTF16.self)
            guard ["static", "button"].contains(name.lowercased()) else { continue }
            // Etched separators are STATIC controls too, but do not render text or retain a font.
            guard GetWindowTextLengthW(control.window) > 0 else { continue }
            let result = SendMessageW(control.window, UINT(WM_GETFONT), 0, 0)
            guard let font = HFONT(bitPattern: Int(result)), self.fonts.contains(font) else {
                throw NSError(
                    domain: "CodexBar.WindowsTray",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(name) control did not retain its assigned font."])
            }
            checked += 1
        }
        guard checked > 0 else {
            throw NSError(
                domain: "CodexBar.WindowsTray",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No text controls were checked for assigned fonts."])
        }
        print("Native tray text controls retained their assigned fonts: \(checked)")
    }

    private func reportFont(_ font: HFONT, size: Int32, weight: Int32) {
        guard let context = GetDC(self.window) else { return }
        defer { _ = ReleaseDC(self.window, context) }
        guard let previous = SelectObject(context, font) else { return }
        defer { _ = SelectObject(context, previous) }
        var face = [WCHAR](repeating: 0, count: 128)
        guard GetTextFaceW(context, Int32(face.count), &face) > 0 else { return }
        let name = String(decoding: face.prefix { $0 != 0 }, as: UTF16.self)
        print("Tray font: size=\(size) weight=\(weight) face=\(name)")
    }

    private func px(_ value: Int32) -> Int32 {
        Int32((Double(value) * self.scale).rounded())
    }

    private static func accentColor(_ hex: String) -> COLORREF {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return GetSysColor(COLOR_HIGHLIGHT)
        }
        return (value >> 16) | (value & 0x00FF00) | ((value & 0xFF) << 16)
    }

    private static func resetText(_ date: Date) -> String {
        let minutes = Int(max(0, date.timeIntervalSinceNow) / 60)
        if minutes == 0 { return "Resetting…" }
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        return "Resets in \(minutes / 60)h \(minutes % 60)m"
    }

    private static func windowsError(_ operation: String) -> NSError {
        NSError(
            domain: "Win32",
            code: Int(GetLastError()),
            userInfo: [NSLocalizedDescriptionKey: operation + " failed"])
    }
}
#endif
