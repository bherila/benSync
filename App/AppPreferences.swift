import Foundation

/// Destination settings belong to the shared configuration file. These are
/// presentation and authoring defaults for this Mac's containing app only.
enum AppPreferences {
    static let showCachedCounts = "showCachedCounts"
    static let showTransferProgress = "showTransferProgress"
    static let refreshOnReconnect = "refreshOnReconnect"
    static let defaultRefreshMinutes = "defaultRefreshMinutes"
    static let defaultRemoteFolder = "defaultRemoteFolder"
    static let defaultExclusions = "defaultExclusions"
    static let values: [String: Any] = [
        showCachedCounts: true,
        showTransferProgress: true,
        refreshOnReconnect: true,
        defaultRefreshMinutes: 5,
        defaultRemoteFolder: ".",
        defaultExclusions: "node_modules\n.git",
    ]
    static func registerDefaults() { UserDefaults.standard.register(defaults: values) }
    static func restoreDefaults() {
        for key in values.keys { UserDefaults.standard.removeObject(forKey: key) }
        registerDefaults()
    }
}
