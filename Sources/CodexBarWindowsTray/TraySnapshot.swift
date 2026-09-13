import Foundation

/// A display-only projection of the shared CLI's dashboard-v1 contract.
/// Provider fetching, authentication, parsing, and configuration remain owned by CodexBarCLI.
struct TraySnapshot: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let staleAfterSeconds: Int
    let host: Host
    let providers: [Provider]

    struct Host: Decodable, Equatable, Sendable {
        let codexBarVersion: String?
        let refreshIntervalSeconds: Int
    }

    struct Provider: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let enabled: Bool
        let source: String
        let status: Status?
        let identity: Identity?
        let windows: [Window]
        let credits: Credits?
        let cost: Cost?
        let display: Display
        let error: ProviderError?
        let updatedAt: Date?
        let accounts: [Account]?
        let accountsError: String?
    }

    struct Status: Decodable, Equatable, Sendable {
        let level: String
        let label: String
        let updatedAt: Date?
    }

    struct Identity: Decodable, Equatable, Sendable {
        let accountEmail: String?
        let plan: String?
    }

    struct Window: Decodable, Equatable, Sendable {
        let kind: String
        let label: String
        let usedPercent: Double
        let remainingPercent: Double
        let resetAt: Date?
        let idle: Bool?

        var filledFraction: Double {
            guard self.usedPercent.isFinite else { return 0 }
            return min(1, max(0, self.usedPercent / 100))
        }
    }

    struct Credits: Decodable, Equatable, Sendable {
        let remaining: Double
        let unit: String
    }

    struct Cost: Decodable, Equatable, Sendable {
        let todayUSD: Double?
        let last30DaysUSD: Double?
    }

    struct Display: Decodable, Equatable, Sendable {
        let accentColor: String
        let sortKey: Int
        let priority: String
    }

    struct ProviderError: Decodable, Equatable, Sendable {
        let code: Int32
        let message: String
        let kind: String?
    }

    struct Account: Decodable, Equatable, Sendable {
        let id: String
        let label: String
        let active: Bool
        let identity: Identity?
        let windows: [Window]
        let error: String?
        let updatedAt: Date?
    }

    enum DecodeError: LocalizedError {
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                "This tray version does not support dashboard schema \(version)."
            }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Self.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw DecodeError.unsupportedSchema(snapshot.schemaVersion) }
        return snapshot
    }
}
