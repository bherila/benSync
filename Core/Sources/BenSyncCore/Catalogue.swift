import Foundation
import CSQLite

public struct CatalogueChange: Codable, Sendable {
    public var sequence: Int64
    public var id: String
    public var parentID: String
    public var deleted: Bool
}

public struct ResolvedChanges: Sendable {
    public var updated: [Node]
    public var deleted: [String]
}

/// One database per destination. WAL permits offline enumeration while a
/// different process refreshes it. All changes and tombstones commit together.
public final class Catalogue {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL, name: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw BackendError(.internalError, "Cannot open the offline catalogue.")
        }
        sqlite3_busy_timeout(db, 10_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, parent TEXT NOT NULL, path TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS nodes_parent ON nodes(parent, id)")
        try execute("CREATE TABLE IF NOT EXISTS changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, parent TEXT NOT NULL, deleted INTEGER NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS changes_item ON changes(id, seq)")
        try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try transaction {
            if var root = try node(Node.rootID) {
                root.entry.name = name; try put(root)
            } else {
                try put(Node(id: Node.rootID, parentID: Node.rootID, path: "", entry: .init(name: name, kind: .directory, permissions: 0o40755)))
            }
        }
    }
    deinit { sqlite3_close(db) }

    @discardableResult
    private func query<T>(_ sql: String, _ values: [String] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard value.withCString({ sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw databaseError() }
        }
        var result = [T]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError() }
            result.append(try row(statement))
        }
    }
    private func execute(_ sql: String, _ values: [String] = []) throws { try query(sql, values) { _ in () } }
    private func databaseError() -> BackendError { BackendError(.internalError, "Offline catalogue: \(String(cString: sqlite3_errmsg(db)))") }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String { String(cString: sqlite3_column_text(stmt, column)) }
    private func decode(_ stmt: OpaquePointer) throws -> Node {
        let size = Int(sqlite3_column_bytes(stmt, 0))
        guard let bytes = sqlite3_column_blob(stmt, 0) else { throw databaseError() }
        return try decoder.decode(Node.self, from: Data(bytes: bytes, count: size))
    }
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func node(_ id: String) throws -> Node? { try query("SELECT payload FROM nodes WHERE id=?", [id], row: decode).first }
    public func atPath(_ path: String) throws -> Node? { try query("SELECT payload FROM nodes WHERE path=?", [path], row: decode).first }
    public func children(_ id: String) throws -> [Node] { try query("SELECT payload FROM nodes WHERE parent=? AND id<>? ORDER BY id", [id, Node.rootID], row: decode) }
    public func page(parent: String?, after: String, limit: Int = 250) throws -> [Node] {
        if let parent {
            return try query("SELECT payload FROM nodes WHERE parent=? AND id<>? AND id>? ORDER BY id LIMIT ?", [parent, Node.rootID, after, String(limit)], row: decode)
        }
        return try query("SELECT payload FROM nodes WHERE id<>? AND id>? ORDER BY id LIMIT ?", [Node.rootID, after, String(limit)], row: decode)
    }
    public func count() throws -> Int { try query("SELECT COUNT(*) FROM nodes WHERE id<>?", [Node.rootID]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    public func anchor() throws -> Int64 {
        // sqlite_sequence survives journal pruning; MAX(seq) does not.
        try query("SELECT seq FROM sqlite_sequence WHERE name='changes'") { sqlite3_column_int64($0, 0) }.first ?? 0
    }
    public func validateAnchor(_ value: Int64) throws {
        let floor = Int64(try state("journalFloor") ?? "0") ?? 0
        guard value >= floor, value >= 0, value <= (try anchor()) else {
            throw BackendError(.invalid, "The change anchor has expired.")
        }
    }
    /// Only the working-set consumer calls this, with the anchor from its
    /// *next* request. A delivered page is not an acknowledged page.
    public func acknowledge(through value: Int64) throws {
        try validateAnchor(value)
        let floor = Int64(try state("journalFloor") ?? "0") ?? 0
        guard value - floor >= 5000 else { return }
        try transaction {
            let nextFloor = value - 1000
            try execute("DELETE FROM changes WHERE seq<=?", [String(nextFloor)])
            try setState("journalFloor", String(nextFloor))
        }
    }
    public func changes(after: Int64, through: Int64, limit: Int = 500) throws -> [CatalogueChange] {
        // Do not coalesce across the page boundary: an item can change twice.
        try query("SELECT seq,id,parent,deleted FROM changes WHERE seq>? AND seq<=? ORDER BY seq LIMIT ?", [String(after), String(through), String(limit)]) {
            CatalogueChange(sequence: sqlite3_column_int64($0, 0), id: string($0, 1), parentID: string($0, 2), deleted: sqlite3_column_int($0, 3) != 0)
        }
    }
    public func resolveChanges(_ changes: [CatalogueChange], inContainer container: String?) throws -> ResolvedChanges {
        let relevant = changes.filter { container == nil || $0.parentID == container || $0.id == container }
        let byID = Dictionary(relevant.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var updated = [Node](), deleted = [String]()
        for change in byID.values {
            if let item = try node(change.id), container == nil || item.parentID == container || item.id == container {
                updated.append(item)
            } else { deleted.append(change.id) }
        }
        return ResolvedChanges(updated: updated, deleted: deleted)
    }
    public func state(_ key: String) throws -> String? { try query("SELECT value FROM state WHERE key=?", [key]) { string($0, 0) }.first }
    public func setState(_ key: String, _ value: String) throws {
        guard try state(key) != value else { return }
        try execute("INSERT INTO state(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    /// Caller must be in a transaction if publishing more than one change.
    @discardableResult
    public func put(_ node: Node) throws -> Bool {
        let previous = try self.node(node.id)
        guard previous != node else { return false }
        let data = try encoder.encode(node)
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO nodes(id,parent,path,payload) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET parent=excluded.parent,path=excluded.path,payload=excluded.payload", -1, &stmt, nil) == SQLITE_OK, let stmt else { throw databaseError() }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in [node.id, node.parentID, node.path].enumerated() {
            _ = value.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        let result = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        if let previous, previous.parentID != node.parentID {
            try execute("INSERT INTO changes(id,parent,deleted) VALUES (?,?,1)", [node.id, previous.parentID])
        }
        try execute("INSERT INTO changes(id,parent,deleted) VALUES (?,?,0)", [node.id, node.parentID])
        return true
    }
    public func removeTree(_ id: String) throws {
        guard id != Node.rootID else { throw BackendError(.invalid, "Cannot remove the root.") }
        let nodes = try query("WITH RECURSIVE subtree(id) AS (SELECT id FROM nodes WHERE id=? UNION ALL SELECT n.id FROM nodes n JOIN subtree s ON n.parent=s.id WHERE n.id<>n.parent) SELECT payload FROM nodes WHERE id IN subtree", [id], row: decode)
        for node in nodes.reversed() {
            try execute("INSERT INTO changes(id,parent,deleted) VALUES (?,?,1)", [node.id, node.parentID])
            try execute("DELETE FROM nodes WHERE id=?", [node.id])
        }
    }
    public func moveTree(_ id: String, to newPath: String, parentID: String, name: String) throws -> Node {
        guard var node = try node(id), id != Node.rootID else { throw BackendError(.notFound, "Item not found.") }
        let oldPath = node.path
        guard !newPath.hasPrefix(oldPath + "/") else { throw BackendError(.invalid, "A folder cannot contain itself.") }
        let descendants = try query("SELECT payload FROM nodes WHERE substr(path,1,?)=?", [String(oldPath.unicodeScalars.count + 1), oldPath + "/"], row: decode)
        node.path = newPath; node.parentID = parentID; node.entry.name = name
        try put(node)
        for var child in descendants {
            child.path = newPath + child.path.dropFirst(oldPath.count)
            try put(child)
        }
        return node
    }
    /// Called only after a complete, successful READDIR. Failed reads never
    /// become an empty folder, and no-op scans produce zero change rows.
    public func reconcile(parent: Node, entries: [RemoteEntry], exclusions: Exclusions) throws {
        try transaction {
            let old = try children(parent.id)
            // Remote names are byte-exact. Swift String equality folds Unicode
            // canonical equivalents that can coexist on an SFTP filesystem.
            var byName = Dictionary(uniqueKeysWithValues: old.map { (Data($0.entry.name.utf8), $0) })
            for entry in entries {
                try RemotePath.validateName(entry.name)
                let path = RemotePath.append(parent.path, entry.name)
                if exclusions.excludes(path, kind: entry.kind) { continue }
                var node = byName.removeValue(forKey: Data(entry.name.utf8)) ?? Node(parentID: parent.id, path: path, entry: entry)
                if node.entry.kind != entry.kind {
                    try removeTree(node.id)
                    node = Node(parentID: parent.id, path: path, entry: entry)
                }
                node.entry = entry
                try put(node)
            }
            for removed in byName.values { try removeTree(removed.id) }
        }
    }
    public func pin(_ ids: [String], value: Bool) throws {
        try transaction {
            for id in ids {
                guard var node = try node(id) else { throw BackendError(.notFound, "Item not found.") }
                node.pinned = value; try put(node)
            }
        }
    }
}
