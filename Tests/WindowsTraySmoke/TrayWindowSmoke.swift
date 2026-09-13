#if os(Windows)
import Foundation
import WinSDK

@main
enum TrayWindowSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let snapshot = try TraySnapshot.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let settings = FixtureSettings(snapshot: snapshot)
        try WindowsTrayHost.shared.run(initialSnapshot: snapshot, smoke: true, configuration: {}, settings: { change in
            await settings.apply(change)
        })
        print("Native tray window smoke completed")
    }
}

private actor FixtureSettings {
    var rows: [TrayProviderConfiguration]

    init(snapshot: TraySnapshot) {
        self.rows = snapshot.providers.map {
            TrayProviderConfiguration(provider: $0.id, displayName: $0.name, enabled: $0.enabled, defaultEnabled: false)
        }
    }

    func apply(_ change: TrayProviderChange?) -> [TrayProviderConfiguration] {
        if let change {
            self.rows = self.rows.map { row in
                guard row.provider == change.provider else { return row }
                return TrayProviderConfiguration(
                    provider: row.provider,
                    displayName: row.displayName,
                    enabled: change.enabled,
                    defaultEnabled: row.defaultEnabled)
            }
        }
        return self.rows
    }
}
#endif
