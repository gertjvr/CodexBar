import Foundation

struct TrayPresentationState {
    private(set) var snapshot: TraySnapshot?
    private(set) var selectedProviderID: String?
    private(set) var selectedAccountID: String?
    private(set) var refreshError: String?

    var providers: [TraySnapshot.Provider] {
        self.snapshot?.providers.filter(\.enabled) ?? []
    }

    var provider: TraySnapshot.Provider? {
        self.providers.first { $0.id == self.selectedProviderID }
    }

    var account: TraySnapshot.Account? {
        guard let selectedAccountID else { return nil }
        return self.provider?.accounts?.first { $0.id == selectedAccountID }
    }

    var identity: TraySnapshot.Identity? {
        if let account = self.account { return account.identity }
        return self.provider?.identity
    }

    var updatedAt: Date? {
        if let account = self.account { return account.updatedAt }
        return self.provider?.updatedAt
    }

    var displayError: String? {
        if let account = self.account { return account.error }
        return self.provider?.error?.message
    }

    var windows: [TraySnapshot.Window] {
        let windows = self.account?.windows ?? self.provider?.windows ?? []
        return windows.filter { $0.idle != true }
    }

    mutating func accept(_ snapshot: TraySnapshot) {
        self.snapshot = snapshot
        self.refreshError = nil
        if !self.providers.contains(where: { $0.id == self.selectedProviderID }) {
            self.selectedProviderID = self.providers.first?.id
            self.selectedAccountID = nil
        }
        if self.account == nil { self.selectedAccountID = nil }
    }

    mutating func failed(_ message: String) {
        // Retain the last successful snapshot, with an explicit refresh error for the UI.
        self.refreshError = message
    }

    @discardableResult
    mutating func selectProvider(_ id: String) -> Bool {
        guard self.providers.contains(where: { $0.id == id }) else { return false }
        if self.selectedProviderID != id {
            self.selectedProviderID = id
            self.selectedAccountID = nil
        }
        return true
    }

    @discardableResult
    mutating func selectAccount(_ id: String?) -> Bool {
        if let id, self.provider?.accounts?.contains(where: { $0.id == id }) != true { return false }
        self.selectedAccountID = id
        return true
    }
}
