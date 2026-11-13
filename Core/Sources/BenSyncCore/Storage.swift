import Foundation
import Darwin

/// Private configuration and catalogue files are shared with the sandboxed
/// extension. Credentials stay in OpenSSH/Keychain, never in this directory.
public final class Storage {
    public let root: URL
    private let diagnosticsLock = NSLock()
    private var diagnostics: DiagnosticsStore?
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func catalogue(_ destination: Destination) throws -> Catalogue {
        try Catalogue(url: root.appendingPathComponent("Catalogues/\(destination.id.uuidString).sqlite"), name: destination.name)
    }
    public func destinations() throws -> [Destination] {
        let url = root.appendingPathComponent("destinations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Destination].self, from: Data(contentsOf: url))
    }
    public func destination(_ id: UUID) throws -> Destination {
        guard let item = try destinations().first(where: { $0.id == id }) else { throw BackendError(.notFound, "Destination not found.") }
        return item
    }
    public func save(_ destination: Destination) throws {
        try destination.validate()
        try withLock("configuration") {
            var values = try destinations()
            if let index = values.firstIndex(where: { $0.id == destination.id }) { values[index] = destination }
            else { values.append(destination) }
            try write(values)
        }
    }
    public func remove(_ id: UUID) throws {
        try withLock("configuration") { try write(destinations().filter { $0.id != id }) }
        // Keep catalogue until explicit cleanup: domain removal may preserve
        // downloaded data, and crash recovery must not lose its identifiers.
    }
    private func write(_ values: [Destination]) throws {
        let url = root.appendingPathComponent("destinations.json")
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func withLock<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let directory = root.appendingPathComponent("Locks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackendError(.internalError, "Cannot open destination lock.") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw BackendError(.internalError, "Cannot lock destination.") } }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    public func transferURL(_ token: String) throws -> URL {
        guard UUID(uuidString: token) != nil else { throw BackendError(.invalid, "Invalid transfer token.") }
        let directory = root.appendingPathComponent("Transfers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(token)
    }
    private func diagnosticsStore() throws -> DiagnosticsStore {
        diagnosticsLock.lock(); defer { diagnosticsLock.unlock() }
        if let diagnostics { return diagnostics }
        let value = try DiagnosticsStore(url: root.appendingPathComponent("Diagnostics.sqlite"))
        diagnostics = value; return value
    }
    public func diagnosticsSnapshot() throws -> DiagnosticsSnapshot { try diagnosticsStore().snapshot() }
    public func setDiagnosticsEnabled(_ enabled: Bool) throws { try diagnosticsStore().setEnabled(enabled) }
    public func recordDiagnostic(_ event: DiagnosticEvent) throws { try diagnosticsStore().record(event) }
}
