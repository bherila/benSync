import Foundation
import Testing
@testable import BenSyncCore

final class TemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("bensync-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }
}

func expectBackendError(_ kind: BackendError.Kind, _ body: () throws -> Void,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    do { try body(); Issue.record("Expected backend failure \(kind.rawValue).", sourceLocation: sourceLocation) }
    catch let error as BackendError { #expect(error.kind == kind, sourceLocation: sourceLocation) }
    catch { Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation) }
}

/// Synthetic in-memory backend. Its call counters distinguish metadata
/// refreshes from unwanted hydration or upload traffic.
final class MemoryBackend: RemoteBackend {
    var capabilities: BackendCapabilities = [.write, .move, .delete]
    var entries: [String: RemoteEntry] = ["/remote": .init(name: "remote", kind: .directory, permissions: 0o40755)]
    var bytes: [String: Data] = [:]
    var failures: [String: BackendError] = [:]
    var removeFailures: [String: BackendError] = [:]
    var offline = false
    var lists = [String]()
    var downloads = [String]()
    var uploads = [String]()
    var removals = [String]()
    var moves = [(String, String)]()
    var disconnects = 0
    var statHook: ((String) throws -> Void)?
    var listHook: ((String) throws -> Void)?

    func addDirectory(_ path: String) { entries[path] = .init(name: (path as NSString).lastPathComponent, kind: .directory, permissions: 0o40755) }
    func addFile(_ path: String, text: String, version: String = "v1") {
        bytes[path] = Data(text.utf8)
        entries[path] = .init(name: (path as NSString).lastPathComponent, kind: .file, size: Int64(text.utf8.count), modified: 1, version: version)
    }
    private func check(_ path: String) throws {
        if offline { throw BackendError(.offline, "Fixture offline.") }
        if let failure = failures[path] { throw failure }
    }
    func canonicalRoot(_ path: String) throws -> String { try check("/remote"); return "/remote" }
    func list(_ path: String) throws -> [RemoteEntry] {
        lists.append(path); try check(path)
        try listHook?(path)
        guard entries[path]?.kind == .directory else { throw BackendError(.notFound, "Fixture directory not found.") }
        return entries.filter { $0.key != path && ($0.key as NSString).deletingLastPathComponent == path }.map(\.value).sorted { $0.name < $1.name }
    }
    func stat(_ path: String) throws -> RemoteEntry {
        try check(path); try statHook?(path)
        guard let item = entries[path] else { throw BackendError(.notFound, "Fixture item not found.") }
        return item
    }
    func download(_ path: String, to url: URL, progress: Progress) throws {
        try check(path); downloads.append(path)
        guard let contents = bytes[path] else { throw BackendError(.notFound, "Fixture contents not found.") }
        try contents.write(to: url); progress.totalUnitCount = Int64(contents.count); progress.completedUnitCount = Int64(contents.count)
    }
    func upload(_ url: URL, to path: String, replacing version: String?, progress: Progress) throws {
        try check(path)
        if let version {
            guard entries[path]?.version == version else { throw BackendError(.conflict, "Fixture version changed.") }
        } else if entries[path] != nil { throw BackendError(.collision, "Fixture name collision.") }
        uploads.append(path); let data = try Data(contentsOf: url)
        bytes[path] = data
        entries[path] = .init(name: (path as NSString).lastPathComponent, kind: .file, size: Int64(data.count), modified: 2, version: "uploaded-\(uploads.count)")
        progress.totalUnitCount = Int64(data.count); progress.completedUnitCount = Int64(data.count)
    }
    func createDirectory(_ path: String) throws {
        try check(path)
        guard entries[path] == nil else { throw BackendError(.collision, "Fixture name collision.") }
        addDirectory(path)
    }
    func move(_ from: String, to: String) throws {
        try check(from); try check(to)
        guard entries[to] == nil else { throw BackendError(.collision, "Fixture name collision.") }
        moves.append((from, to))
        let affected = entries.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
        for (path, var value) in affected {
            let replacement = to + path.dropFirst(from.count)
            if path == from { value.name = (to as NSString).lastPathComponent }
            entries[path] = nil; entries[replacement] = value
            if let content = bytes.removeValue(forKey: path) { bytes[replacement] = content }
        }
    }
    func remove(_ path: String, kind: NodeKind) throws {
        try check(path)
        if let failure = removeFailures[path] { throw failure }
        guard entries[path] != nil else { throw BackendError(.notFound, "Fixture item not found.") }
        if kind == .directory && entries.keys.contains(where: { $0.hasPrefix(path + "/") }) {
            throw BackendError(.internalError, "Fixture directory is not empty.")
        }
        removals.append(path); entries[path] = nil; bytes[path] = nil
    }
    func disconnect() { disconnects += 1 }
}

struct EngineFixture {
    let directory: TemporaryDirectory
    let storage: Storage
    let backend: MemoryBackend
    let engine: DestinationEngine
    init(exclusions: [String] = ["node_modules", ".git"]) throws {
        let directory = try TemporaryDirectory()
        let storage = try Storage(root: directory.url.appendingPathComponent("state"))
        let backend = MemoryBackend()
        let destination = Destination(name: "Synthetic Server", sshProfile: "synthetic", root: "/remote", exclusions: exclusions)
        self.directory = directory; self.storage = storage; self.backend = backend
        try storage.save(destination)
        engine = try DestinationEngine(destination: destination, storage: storage, backend: backend)
    }
    func modify(_ node: Node, name: String? = nil, parentID: String? = nil, contents: URL? = nil,
                version: Data? = nil) throws -> Node {
        try engine.modify(id: node.id, version: version ?? node.contentVersion, name: name, parentID: parentID, contents: contents,
                          tags: nil, changeTags: false, favoriteRank: nil, changeFavorite: false,
                          lastUsed: nil, changeLastUsed: false, progress: Progress(totalUnitCount: -1))
    }
}
