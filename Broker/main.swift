import Foundation
import BenSyncCore
import Security
import Darwin
import os

/// The broker is a private, unsandboxed XPC service, embedded separately in
/// the app and extension. OpenSSH cannot operate inside File Provider's
/// sandbox with arbitrary SSH config Includes, identity agents, and jump hosts.
final class Broker: NSObject, RemoteBrokerProtocol {
    private let stateLock = NSLock()
    private let operations = ServiceOperationTracker()
    private var queues: [String: DispatchQueue] = [:]
    private var engines: [String: DestinationEngine] = [:] // accessed under per-destination queues
    private let engineLock = NSLock()
    private let storageLock = NSLock()
    private var cachedStorage: Storage?
    private let administrativeQueue = DispatchQueue(label: "broker.configuration", qos: .userInitiated)
    private let logger = Logger(subsystem: "app.benSync", category: "service")

    func cancel(_ operationID: UUID) {
        operations.cancel(id: operationID)
    }
    func execute(_ data: Data, operationID: UUID, progress endpoint: NSXPCListenerEndpoint?, reply: @escaping (Data) -> Void) {
        var request: BrokerRequest
        do { request = try JSONDecoder().decode(BrokerRequest.self, from: data) }
        catch { reply(encoded(failure(error))); return }
        guard let progress = operations.register(id: operationID, destinationID: request.destinationID) else {
            reply(encoded(failure(BackendError(.invalid, "This operation is already active."))))
            return
        }
        logger.debug("operation_started operation=\(request.operation.rawValue, privacy: .public)")
        let queue: DispatchQueue
        // Downloads have a separate queue/connection so a metadata crawl or
        // another large download cannot block opening a file in Finder.
        if request.operation == .download { queue = DispatchQueue.global(qos: .userInitiated) }
        else if let id = request.destinationID {
            stateLock.lock(); let key = id.uuidString + (request.operation == .scan ? "-scan" : "-mutations")
            if queues[key] == nil { queues[key] = DispatchQueue(label: "broker." + key, qos: .utility) }
            queue = queues[key]!; stateLock.unlock()
        } else { queue = administrativeQueue }
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var operationStorage: Storage?
            var progressConnection: NSXPCConnection?
            var timer: DispatchSourceTimer?
            if let endpoint {
                let c = NSXPCConnection(listenerEndpoint: endpoint)
                c.remoteObjectInterface = NSXPCInterface(with: TransferProgressProtocol.self); c.resume()
                progressConnection = c
                let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                ticker.schedule(deadline: .now(), repeating: .milliseconds(250))
                ticker.setEventHandler {
                    (c.remoteObjectProxyWithErrorHandler { _ in } as? TransferProgressProtocol)?.update(completed: progress.completedUnitCount, total: progress.totalUnitCount)
                }
                ticker.resume(); timer = ticker
            }
            defer { timer?.cancel(); progressConnection?.invalidate() }
            do {
                let storage = try sharedStorage()
                operationStorage = storage
                // The service takes ownership of cloned upload input only
                // after execute has been sent. Clean it even if cancellation
                // arrives while this request was queued or validation fails.
                defer {
                    if request.operation == .create || request.operation == .modify,
                       let token = request.token, let url = try? storage.transferURL(token) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                if progress.isCancelled { throw BackendError(.cancelled, "Operation cancelled.") }
                let response = try handle(request, operationID: operationID, storage: storage, progress: progress)
                recordMetrics(request, response: response, error: nil, started: started, progress: progress, storage: storage)
                logger.debug("operation_finished operation=\(request.operation.rawValue, privacy: .public) outcome=success")
                finish(operationID, response: response, reply: reply)
            } catch {
                if let operationStorage { recordMetrics(request, response: nil, error: error, started: started, progress: progress, storage: operationStorage) }
                let category = (error as? BackendError)?.kind.rawValue ?? "internalError"
                logger.error("operation_finished operation=\(request.operation.rawValue, privacy: .public) outcome=\(category, privacy: .public)")
                finish(operationID, response: failure(error), reply: reply)
            }
        }
    }
    private func failure(_ error: Error) -> BrokerResponse {
        var response = BrokerResponse()
        response.error = (error as? BackendError) ?? BackendError(.internalError, error.localizedDescription)
        return response
    }
    private func recordMetrics(_ request: BrokerRequest, response: BrokerResponse?, error: Error?, started: UInt64, progress: Progress, storage: Storage) {
        guard let operation = DiagnosticOperation(rawValue: request.operation.rawValue) else { return }
        let transfersContent = operation == .download || ((operation == .create || operation == .modify) && request.token != nil)
        let bytes = transfersContent ? max(0, progress.completedUnitCount) : 0
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let category: BackendError.Kind? = error.map { ($0 as? BackendError)?.kind ?? .internalError }
        do {
            try storage.recordDiagnostic(.init(operation: operation, errorKind: category, durationMilliseconds: elapsed,
                                              transferredBytes: bytes, itemCount: response?.scan?.itemCount))
        } catch {
            // Diagnostic persistence must never turn a successful remote
            // mutation into an ambiguous failure and cause it to be replayed.
            logger.error("diagnostics_write_failed")
        }
    }
    private func sharedStorage() throws -> Storage {
        storageLock.lock(); defer { storageLock.unlock() }
        if let cachedStorage { return cachedStorage }
        let storage = try AppEnvironment.storage(); cachedStorage = storage; return storage
    }
    private func finish(_ id: UUID, response: BrokerResponse, reply: (Data) -> Void) {
        operations.finish(id: id)
        reply(encoded(response))
    }
    private func encoded(_ response: BrokerResponse) -> Data {
        // These message types contain no non-encodable values.
        (try? JSONEncoder().encode(response)) ?? Data("{\"error\":{\"kind\":\"internalError\",\"message\":\"Cannot encode service response.\"}}".utf8)
    }
    private func engine(_ destination: Destination, storage: Storage, separate: Bool = false, scan: Bool = false, interactive: Bool = false) throws -> DestinationEngine {
        engineLock.lock(); defer { engineLock.unlock() }
        let key = destination.id.uuidString + (scan ? "-scan" : "-mutations")
        if !separate, !interactive, let value = engines[key], value.destination == destination { return value }
        let control = try controlDirectory()
        let askpass = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("benSyncAskPass")
        let options = SSHSessionOptions(askpassExecutable: askpass, allowInteraction: interactive, controlDirectory: control)
        let backend: RemoteBackend
        switch destination.backend { case .ssh(let configuration): backend = SFTPBackend(profile: configuration.profile, options: options) }
        let value = try DestinationEngine(destination: destination, storage: storage, backend: backend)
        if !separate { engines[key] = value }
        return value
    }
    private func controlDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/benSync/SSH")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw BackendError(.permission, "The SSH connection cache must be a private directory owned by your account.")
        }
        return directory
    }
    private func handle(_ request: BrokerRequest, operationID: UUID, storage: Storage, progress: Progress) throws -> BrokerResponse {
        var response = BrokerResponse()
        switch request.operation {
        case .profiles: response.profiles = try SSHProfiles.discover(); return response
        case .destinations: response.destinations = try storage.destinations(); return response
        case .save:
            guard let destination = request.destination else { throw BackendError(.invalid, "Missing destination.") }
            try storage.save(destination); return response
        case .remove:
            guard let id = request.destinationID else { throw BackendError(.invalid, "Missing destination.") }
            try storage.remove(id)
            operations.cancel(destinationID: id, excluding: operationID)
            engineLock.lock()
            let keys = engines.keys.filter { $0.hasPrefix(id.uuidString + "-") }
            // Removing a cache reference must not close a backend while a
            // scanner still holds and uses that engine. Its operation owns the
            // final reference until it observes cancellation and exits.
            for key in keys { engines.removeValue(forKey: key) }
            engineLock.unlock()
            return response
        default: break
        }
        guard let id = request.destinationID else { throw BackendError(.invalid, "Missing destination.") }
        let destination = try storage.destination(id)
        let engine = try engine(destination, storage: storage, separate: request.operation == .download,
                                scan: request.operation == .scan, interactive: request.allowInteraction)
        do {
            switch request.operation {
            case .scan: response.scan = try engine.scan(progress: progress, minimumAge: request.forceRefresh || request.allowInteraction ? 0 : 60)
            case .download:
                guard let itemID = request.itemID else { throw BackendError(.invalid, "Missing item.") }
                let token = UUID().uuidString, url = try storage.transferURL(token)
                do { response.node = try engine.download(itemID, to: url, progress: progress); response.token = token }
                catch { try? FileManager.default.removeItem(at: url); throw error }
                engine.disconnect()
            case .create:
                guard let parent = request.parentID, let name = request.name, let kind = request.kind, let creationID = request.creationID else { throw BackendError(.invalid, "Missing creation parameters.") }
                let contents = try request.token.map(storage.transferURL)
                response.node = try engine.create(parentID: parent, name: name, kind: kind, contents: contents, creationID: creationID, progress: progress)
            case .modify:
                guard let item = request.itemID else { throw BackendError(.invalid, "Missing item.") }
                let contents = try request.token.map(storage.transferURL)
                response.node = try engine.modify(id: item, version: request.version, name: request.name, parentID: request.parentID, contents: contents,
                                                 tags: request.tags, changeTags: request.changeTags, favoriteRank: request.favoriteRank, changeFavorite: request.changeFavorite,
                                                 lastUsed: request.lastUsed, changeLastUsed: request.changeLastUsed, progress: progress)
            case .delete:
                guard let item = request.itemID else { throw BackendError(.invalid, "Missing item.") }
                try engine.delete(id: item, version: request.version, progress: progress)
            default: throw BackendError(.invalid, "Invalid operation.")
            }
        } catch { engine.disconnect(); throw error }
        return response
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let allowed = Bundle.main.object(forInfoDictionaryKey: "AllowedClientIdentifiers") as? [String], !allowed.isEmpty else { return false }
        // Pin both bundle identity and team. The check is performed by XPC
        // against the connection's audit token, avoiding PID reuse races.
        let identities = allowed.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        let team = Bundle.main.object(forInfoDictionaryKey: "SigningTeam") as? String ?? ""
        #if DEBUG
        let requirement = team.isEmpty ? "(\(identities))" : "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(identities))"
        #else
        guard !team.isEmpty else { return false }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(identities))"
        #endif
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: RemoteBrokerProtocol.self)
        connection.exportedObject = Broker()
        connection.resume(); return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
