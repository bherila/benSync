import Foundation

public struct BrokerRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case profiles, destinations, save, remove, scan, download, create, modify, delete
    }
    public var operation: Operation
    public var destinationID: UUID?
    public var destination: Destination?
    public var itemID: String?
    public var parentID: String?
    public var name: String?
    public var kind: NodeKind?
    public var token: String?
    public var version: Data?
    public var creationID: String?
    public var tags: Data?
    public var changeTags = false
    public var favoriteRank: Int64?
    public var changeFavorite = false
    public var lastUsed: Date?
    public var changeLastUsed = false
    public var allowInteraction = false
    public var forceRefresh = false
    public init(_ operation: Operation, destinationID: UUID? = nil) {
        self.operation = operation; self.destinationID = destinationID
    }
}
public struct BrokerResponse: Codable, Sendable {
    public var profiles: [SSHProfile]?
    public var destinations: [Destination]?
    public var node: Node?
    public var scan: ScanResult?
    public var token: String?
    public var error: BackendError?
    public init() {}
}
