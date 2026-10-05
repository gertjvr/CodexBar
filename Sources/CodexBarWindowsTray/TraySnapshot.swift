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
        let usageKnown: Bool?

        var isDisplayable: Bool {
            self.idle != true && self.usageKnown != false
        }

        var filledFraction: Double {
            guard self.isDisplayable, self.usedPercent.isFinite else { return 0 }
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
        let todayIncompleteRequestCount: Int?
        let last30DaysIncompleteRequestCount: Int?
        let historyScanIsPartial: Bool?

        struct Row: Equatable, Sendable {
            let text: String
            let warning: String?
            let historyWarning: String?
        }

        var displayRows: [Row] {
            [
                Self.row(
                    label: "Today",
                    amount: self.todayUSD,
                    incompleteCount: self.todayIncompleteRequestCount,
                    historyScanIsPartial: self.historyScanIsPartial == true),
                Self.row(
                    label: "Last 30 days",
                    amount: self.last30DaysUSD,
                    incompleteCount: self.last30DaysIncompleteRequestCount,
                    historyScanIsPartial: self.historyScanIsPartial == true),
            ].compactMap(\.self)
        }

        private static func row(
            label: String,
            amount: Double?,
            incompleteCount: Int?,
            historyScanIsPartial: Bool) -> Row?
        {
            let knownAmount = amount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let missingRequests = max(0, incompleteCount ?? 0)
            guard knownAmount != nil || missingRequests > 0 || historyScanIsPartial else { return nil }
            let amountText: String
            if let knownAmount {
                let prefix = missingRequests > 0 || historyScanIsPartial ? "At least " : ""
                amountText = prefix + String(format: "$%.2f", knownAmount)
            } else {
                amountText = "Unavailable"
            }
            let warning = missingRequests > 0
                ? "\(missingRequests) request\(missingRequests == 1 ? "" : "s") missing token usage"
                : nil
            return Row(
                text: "\(label): \(amountText)",
                warning: warning,
                historyWarning: historyScanIsPartial ? "Partial local history" : nil)
        }
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
