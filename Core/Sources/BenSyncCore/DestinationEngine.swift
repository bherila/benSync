import Foundation

public struct ScanResult: Codable, Sendable {
    public var itemCount: Int
    public var changed: Bool
    public var complete: Bool
    public var warnings: [String]
    public var date: Date
}

/// Short, per-directory interprocess locks serialize listing+commit with
/// mutations. A whole-tree crawl never monopolizes the destination lock.
public final class DestinationEngine {
    public let destination: Destination
    public let catalogue: Catalogue
    private let storage: Storage
    private let backend: RemoteBackend
    private var root: String?

    public init(destination: Destination, storage: Storage, backend: RemoteBackend) throws {
        self.destination = destination; self.storage = storage; self.backend = backend
        self.catalogue = try storage.catalogue(destination)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try storage.withLock(destination.id.uuidString) { try body() }
    }
    private func absolute(_ path: String) throws -> String {
        try requireActiveConfiguration()
        if root == nil { root = try backend.canonicalRoot(destination.root) }
        return try RemotePath.absolute(root: root!, relative: path)
    }
    public func disconnect() { backend.disconnect(); root = nil }
    private func requireActiveConfiguration() throws {
        let current = try storage.destination(destination.id)
        guard !current.paused else { throw BackendError(.offline, "Syncing is paused. Resume this destination to connect.") }
        guard current.backend == destination.backend, current.root == destination.root,
              current.exclusions == destination.exclusions else {
            throw BackendError(.cancelled, "Destination settings changed. Refresh with the current configuration.")
        }
    }
    public func scan(progress: Progress = Progress(totalUnitCount: -1), minimumAge: TimeInterval = 0) throws -> ScanResult {
        try requireActiveConfiguration()
        backend.prepare(progress: progress)
        return try storage.withLock(destination.id.uuidString + "-scan") {
            if minimumAge > 0, let last = try catalogue.state("lastScan"), let time = Double(last), Date().timeIntervalSince1970 - time < minimumAge {
                if let encoded = try catalogue.state("lastScanResult"), let data = encoded.data(using: .utf8) {
                    var cached = try JSONDecoder().decode(ScanResult.self, from: data)
                    cached.changed = false; cached.itemCount = try catalogue.count(); return cached
                }
                return ScanResult(itemCount: try catalogue.count(), changed: false,
                                  complete: false, warnings: [], date: Date(timeIntervalSince1970: time))
            }
            return try performScan(progress: progress)
        }
    }
    private func performScan(progress: Progress) throws -> ScanResult {
        let start = try catalogue.anchor(), exclusions = Exclusions(destination.exclusions)
        var queue = [Node.rootID], position = 0, warnings = [String]()
        while position < queue.count {
            if progress.isCancelled { throw BackendError(.cancelled, "Catalogue refresh cancelled.") }
            let id = queue[position]; position += 1
            do {
                try locked {
                    guard let parent = try catalogue.node(id) else { return }
                    let entries = try backend.list(absolute(parent.path)).filter { !$0.name.hasPrefix(".bensync-upload-") }
                    try catalogue.reconcile(parent: parent, entries: entries, exclusions: exclusions)
                    queue.append(contentsOf: try catalogue.children(parent.id).filter { $0.entry.kind == .directory }.map(\.id))
                }
                progress.completedUnitCount += 1
            } catch let error as BackendError where error.kind == .offline || error.kind == .cancelled || (position == 1 && (error.kind == .permission || error.kind == .notFound)) {
                disconnect(); throw error
            } catch {
                // Preserve an unreadable branch; never publish it as deleted.
                if warnings.count < 20 { warnings.append(error.localizedDescription) }
            }
        }
        let result = ScanResult(itemCount: try catalogue.count(), changed: try catalogue.anchor() != start,
                                complete: warnings.isEmpty, warnings: warnings, date: Date())
        try catalogue.transaction {
            try catalogue.setState("lastScan", String(result.date.timeIntervalSince1970))
            try catalogue.setState("lastScanResult", String(decoding: JSONEncoder().encode(result), as: UTF8.self))
            if result.complete { try catalogue.setState("initialScanComplete", "true") }
        }
        return result
    }
    public func download(_ id: String, to url: URL, progress: Progress) throws -> Node {
        try requireActiveConfiguration()
        backend.prepare(progress: progress)
        guard let node = try catalogue.node(id) else { throw BackendError(.notFound, "Item not found in the offline catalogue.") }
        do {
            // Downloads use their own connection and need no catalogue writer
            // lock. A version check binds the returned metadata to the bytes.
            let path = try absolute(node.path), before = try backend.stat(path)
            try backend.download(path, to: url, progress: progress)
            let after = try backend.stat(path)
            guard before == after else { try? FileManager.default.removeItem(at: url); throw BackendError(.conflict, "The remote file changed during download.") }
            return try locked {
                guard var current = try catalogue.node(id), current.path == node.path else {
                    throw BackendError(.conflict, "The item moved during download. Retry to use its current location.")
                }
                current.entry = after
                try catalogue.transaction { try catalogue.put(current) }
                return current
            }
        } catch { disconnect(); throw error }
    }
    private func require(_ id: String) throws -> Node {
        guard let node = try catalogue.node(id) else { throw BackendError(.notFound, "Item not found.") }; return node
    }
    private func validate(_ path: String, kind: NodeKind) throws {
        guard !Exclusions(destination.exclusions).excludes(path, kind: kind) else {
            throw BackendError(.permission, "This directory is excluded from syncing. Change the destination's exclusions to include it.")
        }
    }
    private func verify(_ node: Node, version: Data?) throws {
        if let version, version != node.contentVersion { throw BackendError(.conflict, "This item has a newer remote version. Your local changes are retained.") }
        let current = try backend.stat(absolute(node.path))
        guard current.version == node.entry.version, current.kind == node.entry.kind else {
            var updated = node; updated.entry = current
            try catalogue.transaction { try catalogue.put(updated) }
            throw BackendError(.conflict, "This item changed remotely. Your local changes are retained.")
        }
    }
    private func collision(parentID: String, name: String, except id: String? = nil) throws {
        if try catalogue.children(parentID).contains(where: { $0.id != id && $0.entry.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            throw BackendError(.collision, "An item with this name already exists.")
        }
    }
    public func create(parentID: String, name: String, kind: NodeKind, contents: URL?, creationID: String,
                       progress: Progress) throws -> Node {
        backend.prepare(progress: progress)
        return try locked {
            try requireActiveConfiguration()
            guard backend.capabilities.contains(.write) else { throw BackendError(.permission, "This destination is read-only.") }
            try RemotePath.validateName(name)
            let parent = try require(parentID), path = RemotePath.append(parent.path, name)
            guard parent.entry.kind == .directory else { throw BackendError(.invalid, "The parent must be a folder.") }
            try validate(path, kind: kind)
            // File Provider replays this same identifier after a crash. Reuse
            // a committed completion receipt rather than uploading it again.
            let receiptKey = "create:" + creationID
            if let stored = try catalogue.state(receiptKey), let existing = try catalogue.node(stored) { return existing }
            try collision(parentID: parentID, name: name)
            let remote = try absolute(path)
            if kind == .directory { try backend.createDirectory(remote) }
            else {
                guard let contents else { throw BackendError(.invalid, "The file has no contents to upload.") }
                try backend.upload(contents, to: remote, replacing: nil, progress: progress)
            }
            let node = Node(parentID: parentID, path: path, entry: try backend.stat(remote))
            try catalogue.transaction { try catalogue.put(node); try catalogue.setState(receiptKey, node.id) }
            return node
        }
    }
    public func modify(id: String, version: Data?, name: String?, parentID: String?, contents: URL?,
                       tags: Data?, changeTags: Bool, favoriteRank: Int64?, changeFavorite: Bool,
                       lastUsed: Date?, changeLastUsed: Bool, progress: Progress) throws -> Node {
        backend.prepare(progress: progress)
        return try locked {
            var node = try require(id)
            if contents != nil || name != nil || parentID != nil {
                try requireActiveConfiguration()
                guard id != Node.rootID else { throw BackendError(.permission, "This item is read-only.") }
                if contents != nil, !backend.capabilities.contains(.write) { throw BackendError(.permission, "This destination cannot upload files.") }
                if (name != nil || parentID != nil), !backend.capabilities.contains(.move) { throw BackendError(.permission, "This destination cannot move items.") }
                try verify(node, version: version)
                let newName = name ?? node.entry.name, newParent = try require(parentID ?? node.parentID)
                try RemotePath.validateName(newName)
                guard newParent.entry.kind == .directory else { throw BackendError(.invalid, "The parent must be a folder.") }
                let newPath = RemotePath.append(newParent.path, newName)
                guard !newPath.hasPrefix(node.path + "/") else { throw BackendError(.invalid, "A folder cannot contain itself.") }
                try validate(newPath, kind: node.entry.kind)
                try collision(parentID: newParent.id, name: newName, except: id)
                if let contents {
                    guard node.entry.kind == .file else { throw BackendError(.invalid, "Cannot upload file contents to a folder.") }
                    if newPath != node.path {
                        // Publish new bytes under their new extension first.
                        // Readers must never see new-format bytes under the
                        // old extension (or old bytes under the new one).
                        try backend.upload(contents, to: absolute(newPath), replacing: nil, progress: progress)
                        try verify(node, version: version)
                        try backend.remove(absolute(node.path), kind: .file)
                        node = try catalogue.transaction {
                            var moved = try catalogue.moveTree(id, to: newPath, parentID: newParent.id, name: newName)
                            moved.entry = try backend.stat(absolute(newPath)); try catalogue.put(moved); return moved
                        }
                    } else {
                        try backend.upload(contents, to: absolute(node.path), replacing: node.entry.version, progress: progress)
                        node.entry = try backend.stat(absolute(node.path))
                        try catalogue.transaction { try catalogue.put(node) }
                    }
                } else if newPath != node.path {
                    try backend.move(absolute(node.path), to: absolute(newPath))
                    node = try catalogue.transaction { try catalogue.moveTree(id, to: newPath, parentID: newParent.id, name: newName) }
                }
            }
            if changeTags { node.tagData = tags }
            if changeFavorite { node.favoriteRank = favoriteRank }
            if changeLastUsed { node.lastUsed = lastUsed }
            try catalogue.transaction { try catalogue.put(node) }
            return node
        }
    }
    public func delete(id: String, version: Data?, progress: Progress = Progress(totalUnitCount: 1)) throws {
        backend.prepare(progress: progress)
        try locked {
            try requireActiveConfiguration()
            guard backend.capabilities.contains(.delete), id != Node.rootID else { throw BackendError(.permission, "This item cannot be deleted.") }
            guard let node = try catalogue.node(id) else { return } // idempotent replay
            do {
                try verify(node, version: version)
            } catch let error as BackendError where error.kind == .notFound {
                try catalogue.transaction { try catalogue.removeTree(id) }; return
            }
            var plan = [Node]()
            func collect(_ item: Node) throws {
                if item.entry.kind == .directory {
                    let remote = try backend.list(absolute(item.path))
                    let local = try catalogue.children(item.id)
                    guard Set(remote.map(\.name)) == Set(local.map { $0.entry.name }) else {
                        throw BackendError(.conflict, "The folder has changed remotely. Refresh before deleting it.")
                    }
                    for child in local { try collect(child) }
                }
                try verify(item, version: item.contentVersion)
                plan.append(item)
            }
            try collect(node)
            for item in plan {
                if progress.isCancelled { throw BackendError(.cancelled, "Deletion cancelled.") }
                // Deleting children changes their parent's directory
                // mtime; files are rechecked, directories use safe RMDIR.
                if item.entry.kind == .file { try verify(item, version: item.contentVersion) }
                try backend.remove(absolute(item.path), kind: item.entry.kind)
            }
            try catalogue.transaction { try catalogue.removeTree(id) }
        }
    }
}
