#if os(Windows)
import Foundation
import WinSDK

/// Presentation-only drawing. Native child windows retain names, focus, and command routing.
final class WindowsTrayDrawing {
    enum Role {
        case action
        case provider(id: String, selected: Bool)
        case meter(fraction: Double, accent: COLORREF)
        case separator
    }

    static let surface: COLORREF = 0x00FA_F8F7
    static let text: COLORREF = 0x002C_2928
    static let secondary: COLORREF = 0x0081_7B78
    private static let selection: COLORREF = 0x00F6_7834
    private static let track: COLORREF = 0x00E6_E1DE
    private var roles: [UInt: Role] = [:]
    private var muted: Set<UInt> = []
    let background = CreateSolidBrush(WindowsTrayDrawing.surface)

    deinit { if let background { _ = DeleteObject(background) } }

    func clear() {
        self.roles.removeAll()
        self.muted.removeAll()
    }

    func register(_ window: HWND?, role: Role) {
        if let window { self.roles[UInt(bitPattern: window)] = role }
    }

    func secondary(_ window: HWND?) {
        if let window { self.muted.insert(UInt(bitPattern: window)) }
    }

    func textColor(_ window: HWND?) -> COLORREF {
        guard let window else { return Self.text }
        return self.muted.contains(UInt(bitPattern: window)) ? Self.secondary : Self.text
    }

    func draw(_ value: LPARAM, scale: Double) -> Bool {
        guard let item = UnsafePointer<DRAWITEMSTRUCT>(bitPattern: Int(value))?.pointee,
              let window = item.hwndItem, let context = item.hDC,
              let role = self.roles[UInt(bitPattern: window)] else { return false }
        let saved = SaveDC(context)
        defer { _ = RestoreDC(context, saved) }
        var rect = item.rcItem
        _ = FillRect(context, &rect, self.background)
        _ = SetBkMode(context, TRANSPARENT)
        let font = SendMessageW(window, UINT(WM_GETFONT), 0, 0)
        if let font = HFONT(bitPattern: Int(font)) { _ = SelectObject(context, font) }
        let pressed = item.itemState & UINT(ODS_SELECTED) != 0
        let focused = item.itemState & UINT(ODS_FOCUS) != 0
        let disabled = item.itemState & UINT(ODS_DISABLED) != 0
        let radius = Int32((8 * scale).rounded())
        switch role {
        case .action:
            if pressed || focused { self.rounded(context, rect: rect, radius: radius, color: 0x00ED_E7E2) }
            rect.left += Int32(8 * scale)
            self.drawTitle(window, context: context, rect: rect, color: disabled ? Self.secondary : Self.text)
        case let .provider(id, selected):
            if selected || pressed || focused {
                self.rounded(context, rect: rect, radius: radius, color: selected ? Self.selection : 0x00ED_E7E2)
            }
            let iconSize = Int32(25 * scale)
            let iconX = rect.left + (rect.right - rect.left - iconSize) / 2
            let iconY = rect.top + Int32(7 * scale)
            let resource = "PROVIDER_\(id)_\(selected ? "SELECTED" : "NORMAL")"
                .replacingOccurrences(of: "-", with: "_").uppercased()
            let icon = resource.withCString(encodedAs: UTF16.self) {
                LoadImageW(GetModuleHandleW(nil), $0, UINT(IMAGE_ICON), iconSize, iconSize, UINT(LR_SHARED))
            }
            if let icon {
                let handle = icon.assumingMemoryBound(to: HICON__.self)
                _ = DrawIconEx(context, iconX, iconY, handle, iconSize, iconSize, 0, nil, UINT(DI_NORMAL))
            } else {
                var symbolRect = RECT(left: iconX, top: iconY, right: iconX + iconSize, bottom: iconY + iconSize)
                let symbol = self.title(window).prefix(1)
                _ = SetTextColor(context, selected ? 0x00FF_FFFF : Self.secondary)
                String(symbol).withCString(encodedAs: UTF16.self) {
                    _ = DrawTextW(context, $0, -1, &symbolRect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
                }
            }
            rect.top += Int32(35 * scale)
            rect.bottom -= Int32(3 * scale)
            self.drawTitle(
                window,
                context: context,
                rect: rect,
                color: selected ? 0x00FF_FFFF : Self.secondary,
                center: true)
        case let .meter(fraction, accent):
            let radius = max(1, rect.bottom - rect.top)
            self.rounded(context, rect: rect, radius: radius, color: Self.track)
            let width = rect.right - rect.left
            if fraction > 0 {
                rect.right = rect.left + min(width, max(radius, Int32(Double(width) * fraction)))
                self.rounded(context, rect: rect, radius: radius, color: accent)
            }
        case .separator:
            _ = SetDCBrushColor(context, 0x00D6_D0CD)
            let brush = GetStockObject(DC_BRUSH)?.assumingMemoryBound(to: HBRUSH__.self)
            _ = FillRect(context, &rect, brush)
        }
        return true
    }

    private func title(_ window: HWND) -> String {
        var text = [WCHAR](repeating: 0, count: Int(GetWindowTextLengthW(window)) + 1)
        _ = GetWindowTextW(window, &text, Int32(text.count))
        return String(decoding: text.prefix { $0 != 0 }, as: UTF16.self)
    }

    private func drawTitle(
        _ window: HWND, context: HDC, rect: RECT, color: COLORREF, center: Bool = false)
    {
        var rect = rect
        _ = SetTextColor(context, color)
        self.title(window).withCString(encodedAs: UTF16.self) {
            _ = DrawTextW(
                context,
                $0,
                -1,
                &rect,
                UINT(DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX) | (center ? UINT(DT_CENTER) : 0))
        }
    }

    private func rounded(_ context: HDC, rect: RECT, radius: Int32, color: COLORREF) {
        _ = SelectObject(context, GetStockObject(DC_BRUSH))
        _ = SelectObject(context, GetStockObject(NULL_PEN))
        _ = SetDCBrushColor(context, color)
        _ = RoundRect(context, rect.left, rect.top, rect.right, rect.bottom, radius, radius)
    }
}
#endif
