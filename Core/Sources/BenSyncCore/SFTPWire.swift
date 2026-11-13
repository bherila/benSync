import Foundation
import Darwin

public struct SSHSessionOptions {
    public var askpassExecutable: URL?
    public var allowInteraction: Bool
    public var controlDirectory: URL?
    public var isCancelled: (() -> Bool)?
    public init(askpassExecutable: URL? = nil, allowInteraction: Bool = false, controlDirectory: URL? = nil) {
        self.askpassExecutable = askpassExecutable; self.allowInteraction = allowInteraction; self.controlDirectory = controlDirectory
    }
}

struct Packet {
    var data = Data()
    var offset = 0
    init(_ data: Data = Data()) { self.data = data }
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) { var n = value.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    mutating func uint64(_ value: UInt64) { var n = value.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    mutating func bytes(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw malformed() }
        defer { offset += 1 }; return data[offset]
    }
    mutating func read32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw malformed() }
        defer { offset += 4 }; return data[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    mutating func read64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw malformed() }
        defer { offset += 8 }; return data[offset..<offset+8].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func readBytes() throws -> Data {
        let count = Int(try read32())
        guard count <= data.count - offset else { throw malformed() }
        defer { offset += count }; return data.subdata(in: offset..<offset+count)
    }
    mutating func readString() throws -> String {
        guard let result = String(data: try readBytes(), encoding: .utf8) else { throw malformed() }
        return result
    }
    func malformed() -> BackendError { BackendError(.invalid, "The SFTP server returned a malformed packet.") }
}

/// A session uses one OpenSSH process for all requests. It inherits the user's
/// config, agent, jump hosts and identity selection without copying private keys.
/// Only the unsandboxed, private XPC broker instantiates this transport.
final class SFTPWire {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var nextID: UInt32 = 0
    private var pending: [UInt32: (UInt8, Packet)] = [:]
    private let errorLock = NSLock()
    private var errorTail = Data()
    private var negotiated = false
    private let handshakeTimeout: TimeInterval
    private(set) var extensions: [String: String] = [:]
    var isCancelled: (() -> Bool)?

    init(profile: String? = nil, localServer: URL? = nil, options: SSHSessionOptions = .init()) throws {
        handshakeTimeout = options.allowInteraction ? 180 : 40
        isCancelled = options.isCancelled
        if let localServer { process.executableURL = localServer; process.arguments = [] }
        else {
            guard let profile, !profile.isEmpty, !profile.hasPrefix("-"), !profile.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
                throw BackendError(.invalid, "Invalid SSH profile.")
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var arguments = ["-T", options.allowInteraction ? "-oBatchMode=no" : "-oBatchMode=yes",
                             options.allowInteraction ? "-oStrictHostKeyChecking=ask" : "-oStrictHostKeyChecking=yes",
                             "-oPermitLocalCommand=no", "-oNumberOfPasswordPrompts=1",
                             "-oConnectTimeout=10", "-oServerAliveInterval=15", "-oServerAliveCountMax=2"]
            if let directory = options.controlDirectory {
                arguments += ["-oControlMaster=auto", "-oControlPersist=300", "-oControlPath=" + directory.appendingPathComponent("%C").path]
            }
            if options.allowInteraction { arguments += ["-oAddKeysToAgent=yes"] }
            arguments += ["-s", "--", profile, "sftp"]
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS_REQUIRE"] = options.allowInteraction ? "force" : "never"
            if let askpass = options.askpassExecutable { environment["SSH_ASKPASS"] = askpass.path }
            // A background service inherits launchd's SSH_AUTH_SOCK, matching
            // the default macOS Terminal agent. Custom per-terminal agents are
            // selected through IdentityAgent in the user's SSH config.
            process.environment = environment
        }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.errorLock.lock(); defer { self.errorLock.unlock() }
            self.errorTail.append(data)
            if self.errorTail.count > 4096 { self.errorTail = self.errorTail.suffix(4096) }
        }
        do {
            try process.run()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            var initialize = Packet(); initialize.byte(1); initialize.uint32(3)
            try writeFrame(initialize.data)
            var version = Packet(try readFrame())
            guard try version.readByte() == 2, try version.read32() == 3 else { throw BackendError(.unsupported, "This server does not support SFTP version 3.") }
            while version.offset < version.data.count {
                let name = try version.readString(); extensions[name] = try version.readString()
            }
            negotiated = true
        } catch { disconnect(); throw error }
    }
    deinit { disconnect() }
    func disconnect() {
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
    func failure() -> BackendError {
        errorLock.lock(); defer { errorLock.unlock() }
        let detail = String(data: errorTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detail.contains("Permission denied") { return BackendError(.permission, "SSH authentication failed. Unlock your key in the SSH agent, then retry.") }
        if detail.contains("Host key verification failed") || detail.contains("REMOTE HOST IDENTIFICATION") {
            return BackendError(.permission, "SSH host key verification failed. Verify this host in Terminal before connecting.")
        }
        return BackendError(.offline, "The SSH destination is unreachable. Cached files remain available.")
    }
    func send(_ type: UInt8, _ body: (inout Packet) -> Void = { _ in }) throws -> UInt32 {
        nextID &+= 1
        var packet = Packet(); packet.byte(type); packet.uint32(nextID); body(&packet)
        try writeFrame(packet.data)
        return nextID
    }
    func receive(_ id: UInt32) throws -> (UInt8, Packet) {
        if let packet = pending.removeValue(forKey: id) { return packet }
        while true {
            var packet = Packet(try readFrame())
            let type = try packet.readByte(), receivedID = try packet.read32()
            if receivedID == id { return (type, packet) }
            guard pending.count < 128 else { throw BackendError(.invalid, "Too many unexpected SFTP replies.") }
            pending[receivedID] = (type, packet)
        }
    }
    func request(_ type: UInt8, _ body: (inout Packet) -> Void = { _ in }) throws -> (UInt8, Packet) { try receive(send(type, body)) }
    func status(_ reply: (UInt8, Packet), eofAllowed: Bool = false) throws -> Bool {
        guard reply.0 == 101 else { throw BackendError(.invalid, "Unexpected SFTP status reply.") }
        var packet = reply.1
        let code = try packet.read32()
        if code == 0 { return true }
        if code == 1 && eofAllowed { return false }
        switch code {
        case 2: throw BackendError(.notFound, "The remote item no longer exists.")
        case 3: throw BackendError(.permission, "The SSH account does not have permission for this operation.")
        case 6, 7: throw BackendError(.offline, "The SFTP connection was lost.")
        case 8: throw BackendError(.unsupported, "The SFTP server does not support this operation.")
        default: throw BackendError(.internalError, "The SFTP server refused the operation (status \(code)).")
        }
    }
    func expect(_ type: UInt8, _ reply: (UInt8, Packet)) throws -> Packet {
        if reply.0 == 101 { _ = try status(reply) }
        guard reply.0 == type else { throw BackendError(.invalid, "Unexpected SFTP reply.") }
        return reply.1
    }
    private func writeFrame(_ data: Data) throws {
        var frame = Packet(); frame.uint32(UInt32(data.count)); frame.data.append(data)
        do { try input.fileHandleForWriting.write(contentsOf: frame.data) } catch { throw failure() }
    }
    private func readFrame() throws -> Data {
        var header = Packet(try readExact(4)); let size = Int(try header.read32())
        guard size > 0, size <= 16 * 1024 * 1024 else { throw BackendError(.invalid, "Invalid SFTP frame size.") }
        return try readExact(size)
    }
    private func readExact(_ count: Int) throws -> Data {
        var data = Data(count: count), position = 0
        // Host trust / password dialogs need time for deliberate user input.
        let deadline = Date().addingTimeInterval(negotiated ? 40 : handshakeTimeout)
        try data.withUnsafeMutableBytes { bytes in
            while position < count {
                if isCancelled?() == true { if process.isRunning { process.terminate() }; throw BackendError(.cancelled, "Transfer cancelled.") }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let wait = poll(&descriptor, 1, 250)
                if wait < 0 && errno == EINTR { continue }
                guard wait >= 0, Date() < deadline else { if process.isRunning { process.terminate() }; throw failure() }
                if wait == 0 { continue }
                let n = Darwin.read(descriptor.fd, bytes.baseAddress!.advanced(by: position), count - position)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure() }
                position += n
            }
        }
        return data
    }
}
