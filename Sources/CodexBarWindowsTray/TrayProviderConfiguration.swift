import Foundation

struct TrayProviderConfiguration: Decodable, Equatable, Sendable {
    let provider: String
    let displayName: String
    let enabled: Bool
    let defaultEnabled: Bool
}

struct TrayProviderChange: Sendable {
    let provider: String
    let enabled: Bool
}
