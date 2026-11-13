import Foundation
import BenSyncCore

enum AppEnvironment {
    static var appGroup: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SharedAppGroup") as? String, !value.isEmpty else {
            preconditionFailure("SharedAppGroup is missing from Info.plist")
        }
        return value
    }
    static var brokerIdentifier: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BrokerIdentifier") as? String, !value.isEmpty else {
            preconditionFailure("BrokerIdentifier is missing from Info.plist")
        }
        return value
    }
    static func storage() throws -> Storage {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw BackendError(.permission, "The shared app group is unavailable. Sign the app and extension with the same team and registered app group.")
        }
        return try Storage(root: group.appendingPathComponent("Library/Application Support/benSync"))
    }
}
