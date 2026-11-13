import Foundation

public final class SFTPBackend: RemoteBackend {
    public let capabilities: BackendCapabilities = [.write, .move, .delete]
    private let profile: String?
    private let localServer: URL?
    private var options: SSHSessionOptions
    private var wire: SFTPWire?
    private var root: String?
    private let chunkSize = 32 * 1024
    private let pipelineDepth = 16

    public init(profile: String, options: SSHSessionOptions = .init()) { self.profile = profile; localServer = nil; self.options = options }
    /// Integration tests use the real system SFTP server over pipes, with no
    /// network listener, credentials, or access to a user's remote destinations.
    public init(localServer: URL) { profile = nil; self.localServer = localServer; self.options = .init() }
    public func disconnect() { wire?.disconnect(); wire = nil }
    public func prepare(progress: Progress) {
        options.isCancelled = { progress.isCancelled }
        wire?.isCancelled = options.isCancelled
    }
    private func session() throws -> SFTPWire {
        if let wire, wire.process.isRunning { return wire }
        let currentOptions = options
        options.allowInteraction = false // Permission to prompt is single-use.
        let new = try SFTPWire(profile: profile, localServer: localServer, options: currentOptions); wire = new; return new
    }
    private func realpath(_ path: String) throws -> String {
        let wire = try session()
        var reply = try wire.expect(104, wire.request(16) { $0.string(path) })
        guard try reply.read32() == 1 else { throw BackendError(.invalid, "Invalid canonical path reply.") }
        return try reply.readString()
    }
    public func canonicalRoot(_ path: String) throws -> String {
        let resolved = try realpath(path)
        guard try stat(resolved).kind == .directory else { throw BackendError(.invalid, "The remote root must be a directory.") }
        root = resolved
        return resolved
    }
    private func confined(_ path: String, parentOnly: Bool = false) throws {
        guard let root else { throw BackendError(.invalid, "The destination root has not been resolved.") }
        let canonical = try realpath(parentOnly ? (path as NSString).deletingLastPathComponent : path)
        guard root == "/" || canonical == root || canonical.hasPrefix(root + "/") else {
            throw BackendError(.permission, "A symbolic link leads outside the destination root.")
        }
    }
    private func attributes(_ packet: inout Packet, name: String) throws -> RemoteEntry? {
        let flags = try packet.read32()
        var size: Int64 = 0, permissions: UInt32 = 0, modified: Int64 = 0
        if flags & 1 != 0 { let raw = try packet.read64(); guard raw <= UInt64(Int64.max) else { throw packet.malformed() }; size = Int64(raw) }
        if flags & 2 != 0 { _ = try packet.read32(); _ = try packet.read32() }
        if flags & 4 != 0 { permissions = try packet.read32() }
        if flags & 8 != 0 { _ = try packet.read32(); modified = Int64(try packet.read32()) }
        if flags & 0x80000000 != 0 {
            let count = try packet.read32()
            guard count <= 1024 else { throw packet.malformed() }
            for _ in 0..<count { _ = try packet.readBytes(); _ = try packet.readBytes() }
        }
        let type = permissions & 0o170000
        // No symlink traversal, devices, sockets, or FIFOs in a sync tree.
        guard type == 0o040000 || type == 0o100000 else { return nil }
        return RemoteEntry(name: name, kind: type == 0o040000 ? .directory : .file,
                           size: size, modified: modified, permissions: permissions)
    }
    public func stat(_ path: String) throws -> RemoteEntry {
        let wire = try session()
        var packet = try wire.expect(105, wire.request(7) { $0.string(path) }) // LSTAT, never follows final symlink
        guard let entry = try attributes(&packet, name: (path as NSString).lastPathComponent) else {
            throw BackendError(.unsupported, "Symbolic links and special files are excluded from syncing.")
        }
        return entry
    }
    public func list(_ path: String) throws -> [RemoteEntry] {
        try confined(path)
        let wire = try session()
        var opened = try wire.expect(102, wire.request(11) { $0.string(path) })
        let handle = try opened.readBytes()
        defer { _ = try? wire.status(wire.request(4) { $0.bytes(handle) }) }
        var entries = [RemoteEntry]()
        while true {
            let reply = try wire.request(12) { $0.bytes(handle) }
            if reply.0 == 101 { if try !wire.status(reply, eofAllowed: true) { break } }
            var packet = try wire.expect(104, reply)
            let count = try packet.read32()
            guard count <= 100_000 else { throw packet.malformed() }
            for _ in 0..<count {
                let name = try packet.readString(); _ = try packet.readBytes() // longname is not parsed
                let entry = try attributes(&packet, name: name)
                if name == "." || name == ".." { continue }
                try RemotePath.validateName(name)
                if let entry { entries.append(entry) }
            }
        }
        return entries
    }
    private func open(_ path: String, flags: UInt32, permissions: UInt32? = nil) throws -> Data {
        let wire = try session()
        var reply = try wire.expect(102, wire.request(3) {
            $0.string(path); $0.uint32(flags)
            if let permissions { $0.uint32(4); $0.uint32(permissions & 0o777) }
            else { $0.uint32(0) }
        })
        return try reply.readBytes()
    }
    private func check(_ progress: Progress) throws {
        if progress.isCancelled { disconnect(); throw BackendError(.cancelled, "Transfer cancelled.") }
    }
    public func download(_ path: String, to url: URL, progress: Progress) throws {
        try confined(path)
        let entry = try stat(path), wire = try session()
        wire.isCancelled = { progress.isCancelled }; defer { wire.isCancelled = nil }
        guard entry.kind == .file else { throw BackendError(.invalid, "Only regular files can be downloaded.") }
        progress.totalUnitCount = entry.size
        let handle = try open(path, flags: 1)
        defer { _ = try? wire.status(wire.request(4) { $0.bytes(handle) }) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BackendError(.internalError, "Cannot create the temporary download.")
        }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        var succeeded = false; defer { if !succeeded { try? FileManager.default.removeItem(at: url) } }
        var offset: Int64 = 0
        while offset < entry.size {
            try check(progress)
            var requests = [(UInt32, Int)]()
            for _ in 0..<pipelineDepth where offset < entry.size {
                let size = Int(min(Int64(chunkSize), entry.size - offset)), at = offset
                let id = try wire.send(5) { $0.bytes(handle); $0.uint64(UInt64(at)); $0.uint32(UInt32(size)) }
                requests.append((id, size)); offset += Int64(size)
            }
            for (id, expected) in requests {
                try check(progress)
                var reply = try wire.expect(103, wire.receive(id))
                let bytes = try reply.readBytes()
                // A short read is legal in SFTP. Retry the remaining range,
                // without losing byte order or accepting a truncated file.
                guard !bytes.isEmpty, bytes.count <= expected else { throw BackendError(.conflict, "The remote file changed during download.") }
                try file.write(contentsOf: bytes); progress.completedUnitCount += Int64(bytes.count)
                var remaining = expected - bytes.count
                while remaining > 0 {
                    try check(progress)
                    var part = try wire.expect(103, wire.request(5) {
                        $0.bytes(handle); $0.uint64(UInt64(progress.completedUnitCount)); $0.uint32(UInt32(remaining))
                    })
                    let extra = try part.readBytes()
                    guard !extra.isEmpty, extra.count <= remaining else { throw BackendError(.conflict, "The remote file changed during download.") }
                    try file.write(contentsOf: extra); progress.completedUnitCount += Int64(extra.count); remaining -= extra.count
                }
            }
        }
        guard try stat(path).version == entry.version else { throw BackendError(.conflict, "The remote file changed during download. Retry to fetch the current version.") }
        succeeded = true
    }
    private func existing(_ path: String) throws -> RemoteEntry? {
        do { return try stat(path) } catch let error as BackendError where error.kind == .notFound { return nil }
    }
    public func upload(_ url: URL, to path: String, replacing version: String?, progress: Progress) throws {
        try confined(path, parentOnly: true)
        let wire = try session()
        let previous = try existing(path)
        wire.isCancelled = { progress.isCancelled }; defer { wire.isCancelled = nil }
        if let version {
            guard previous?.version == version else { throw BackendError(.conflict, "The remote file changed. Your local edits are retained in Finder.") }
            guard wire.extensions["posix-rename@openssh.com"] != nil else {
                throw BackendError(.unsupported, "Safe replacement requires the OpenSSH atomic rename extension.")
            }
        } else if previous != nil { throw BackendError(.collision, "An item with this name already exists on the destination.") }
        let temp = RemotePath.append((path as NSString).deletingLastPathComponent, ".bensync-upload-" + UUID().uuidString)
        var committed = false
        defer { if !committed { _ = try? wire.status(wire.request(13) { $0.string(temp) }) } }
        let handle = try open(temp, flags: 2 | 8 | 32, permissions: previous?.permissions ?? 0o600) // WRITE|CREAT|EXCL
        var closed = false
        defer { if !closed { _ = try? wire.status(wire.request(4) { $0.bytes(handle) }) } }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        progress.totalUnitCount = Int64(try file.seekToEnd()); try file.seek(toOffset: 0)
        var offset: UInt64 = 0, eof = false
        while !eof {
            try check(progress)
            var requests = [(UInt32, Int)]()
            for _ in 0..<pipelineDepth {
                guard let data = try file.read(upToCount: chunkSize), !data.isEmpty else { eof = true; break }
                let at = offset
                let id = try wire.send(6) { $0.bytes(handle); $0.uint64(at); $0.bytes(data) }
                requests.append((id, data.count)); offset += UInt64(data.count)
            }
            for (id, size) in requests { try check(progress); _ = try wire.status(wire.receive(id)); progress.completedUnitCount += Int64(size) }
        }
        if wire.extensions["fsync@openssh.com"] != nil {
            _ = try wire.status(wire.request(200) { $0.string("fsync@openssh.com"); $0.bytes(handle) })
        }
        _ = try wire.status(wire.request(4) { $0.bytes(handle) }); closed = true
        try check(progress)
        if let version {
            guard try existing(path)?.version == version else { throw BackendError(.conflict, "The remote file changed during upload. Your local edits are retained.") }
            _ = try wire.status(wire.request(200) { $0.string("posix-rename@openssh.com"); $0.string(temp); $0.string(path) })
        } else {
            // v3 RENAME fails if the target already exists.
            _ = try wire.status(wire.request(18) { $0.string(temp); $0.string(path) })
        }
        committed = true
    }
    public func createDirectory(_ path: String) throws {
        try confined(path, parentOnly: true)
        if try existing(path) != nil { throw BackendError(.collision, "This folder already exists.") }
        let wire = try session()
        _ = try wire.status(wire.request(14) { $0.string(path); $0.uint32(4); $0.uint32(0o755) })
    }
    public func move(_ from: String, to: String) throws {
        try confined(from); try confined(to, parentOnly: true)
        if try existing(to) != nil { throw BackendError(.collision, "An item with this name already exists.") }
        let wire = try session()
        _ = try wire.status(wire.request(18) { $0.string(from); $0.string(to) })
    }
    public func remove(_ path: String, kind: NodeKind) throws {
        try confined(path)
        let wire = try session()
        // RMDIR deliberately refuses non-empty folders. File Provider sends
        // child deletions first; an unseen server-side child must survive.
        _ = try wire.status(wire.request(kind == .directory ? 15 : 13) { $0.string(path) })
    }
}
