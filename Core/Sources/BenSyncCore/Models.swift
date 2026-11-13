import Foundation
import CryptoKit

public enum BackendKind: String, Codable, Sendable { case ssh }

public struct SSHConfiguration: Codable, Equatable, Sendable {
    public var profile: String
    public init(profile: String) { self.profile = profile }
}
public enum BackendConfiguration: Codable, Equatable, Sendable {
    case ssh(SSHConfiguration)
    public var kind: BackendKind { switch self { case .ssh: return .ssh } }
    public var capabilities: BackendCapabilities {
        switch self { case .ssh: return [.write, .move, .delete] }
    }
}

/// Backend-specific configuration stays out of the catalogue and File Provider.
/// New backends add a configuration case and a factory registration.
public struct Destination: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var backend: BackendConfiguration
    public var kind: BackendKind { backend.kind }
    public var sshProfile: String { switch backend { case .ssh(let config): return config.profile } }
    public var root: String
    public var exclusions: [String]
    public var refreshInterval: TimeInterval
    public var paused: Bool

    public init(id: UUID = UUID(), name: String, sshProfile: String, root: String = ".",
                exclusions: [String] = ["node_modules", ".git"], refreshInterval: TimeInterval = 300, paused: Bool = false) {
        self.id = id; self.name = name; self.backend = .ssh(.init(profile: sshProfile))
        self.root = root; self.exclusions = exclusions; self.refreshInterval = refreshInterval
        self.paused = paused
    }

    private enum CodingKeys: String, CodingKey { case id, name, backend, root, exclusions, refreshInterval, paused }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(UUID.self, forKey: .id)
        name = try value.decode(String.self, forKey: .name)
        backend = try value.decode(BackendConfiguration.self, forKey: .backend)
        root = try value.decode(String.self, forKey: .root)
        exclusions = try value.decode([String].self, forKey: .exclusions)
        refreshInterval = try value.decode(TimeInterval.self, forKey: .refreshInterval)
        paused = try value.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        try validate()
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sshProfile.isEmpty, !sshProfile.hasPrefix("-"),
              !sshProfile.contains(where: { $0.isWhitespace || $0 == "\0" }),
              !root.isEmpty, !root.contains("\0"), refreshInterval.isFinite, (60...86_400).contains(refreshInterval) else {
            throw BackendError(.invalid, "Enter a name, an SSH profile, a remote folder, and a refresh interval of at least one minute.")
        }
        try Exclusions(exclusions).validate()
    }
}

public enum NodeKind: String, Codable, Sendable { case file, directory }
public enum OfflinePolicy: String, Codable, Sendable { case inherited, keep, onDemand }

public struct RemoteEntry: Codable, Equatable, Sendable {
    public var name: String
    public var kind: NodeKind
    public var size: Int64
    public var modified: Int64
    public var permissions: UInt32
    /// Opaque remote version. SFTP v3 uses size + second-resolution mtime.
    /// An object-store adapter must use its ETag/version ID, never that heuristic.
    public var version: String

    public init(name: String, kind: NodeKind, size: Int64 = 0, modified: Int64 = 0,
                permissions: UInt32 = 0o100644, version: String? = nil) {
        self.name = name; self.kind = kind; self.size = size; self.modified = modified
        self.permissions = permissions
        self.version = version ?? "\(size):\(modified)"
    }
}

public struct Node: Codable, Equatable, Identifiable, Sendable {
    public static let rootID = "root"
    public var id: String
    public var parentID: String
    public var path: String
    public var entry: RemoteEntry
    public var offlinePolicy: OfflinePolicy
    public var pinned: Bool {
        get { offlinePolicy == .keep }
        set { offlinePolicy = newValue ? .keep : .onDemand }
    }
    public var tagData: Data?
    public var favoriteRank: Int64?
    public var lastUsed: Date?

    public init(id: String = UUID().uuidString, parentID: String, path: String,
                entry: RemoteEntry, pinned: Bool = false) {
        self.id = id; self.parentID = parentID; self.path = path; self.entry = entry; self.offlinePolicy = pinned ? .keep : .inherited
    }

    public var metadataVersion: Data {
        // Metadata changes must not invalidate downloaded bytes.
        let value = "\(parentID)|\(entry.name)|\(entry.permissions)|\(offlinePolicy.rawValue)|\(tagData?.base64EncodedString() ?? "")|\(favoriteRank ?? 0)|\(lastUsed?.timeIntervalSince1970 ?? 0)"
        return Data(SHA256.hash(data: Data(value.utf8)))
    }
    public var contentVersion: Data { Data(entry.version.utf8) }
}

public struct BackendCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let write = Self(rawValue: 1 << 0)
    public static let move = Self(rawValue: 1 << 1)
    public static let delete = Self(rawValue: 1 << 2)
}

/// No Finder, SSH, S3, or backup-specific types cross this boundary.
/// Implementations stream content to disk; callers never buffer whole files.
public protocol RemoteBackend: AnyObject {
    var capabilities: BackendCapabilities { get }
    func prepare(progress: Progress)
    func canonicalRoot(_ path: String) throws -> String
    func list(_ path: String) throws -> [RemoteEntry]
    func stat(_ path: String) throws -> RemoteEntry
    func download(_ path: String, to url: URL, progress: Progress) throws
    func upload(_ url: URL, to path: String, replacing version: String?, progress: Progress) throws
    func createDirectory(_ path: String) throws
    func move(_ from: String, to: String) throws
    func remove(_ path: String, kind: NodeKind) throws
    func disconnect()
}

public extension RemoteBackend {
    func prepare(progress: Progress) {}
}

public struct BackendError: Error, Codable, LocalizedError, Sendable {
    public enum Kind: String, Codable, Sendable {
        case offline, notFound, permission, conflict, collision, unsupported, invalid, cancelled, internalError
    }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var errorDescription: String? { message }
}

public enum RemotePath {
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw BackendError(.invalid, "Invalid remote filename.")
        }
    }
    public static func append(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : (parent == "/" ? "/" + name : parent + "/" + name)
    }
    public static func absolute(root: String, relative: String) throws -> String {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\0") else {
            throw BackendError(.invalid, "A path escapes the destination root.")
        }
        return relative.isEmpty ? root : append(root, relative)
    }
}
