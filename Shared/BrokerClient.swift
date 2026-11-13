import Foundation
import BenSyncCore
import os

final class ProgressListener: NSObject, NSXPCListenerDelegate, TransferProgressProtocol {
    let progress: Progress
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var connections = [NSXPCConnection]()
    private var invalidated = false
    init(_ progress: Progress) {
        self.progress = progress
        super.init(); listener.delegate = self; listener.resume()
    }
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return false }
        connection.exportedInterface = NSXPCInterface(with: TransferProgressProtocol.self)
        connection.exportedObject = self
        connections.append(connection); connection.resume(); return true
    }
    func update(completed: Int64, total: Int64) {
        guard !progress.isCancelled else { return }
        progress.totalUnitCount = total; progress.completedUnitCount = completed
    }
    func invalidate() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        let active = connections; connections.removeAll(); lock.unlock()
        listener.invalidate(); active.forEach { $0.invalidate() }
    }
}

final class BrokerClient {
    private struct ConnectionState {
        var generation: UUID
        var connection: NSXPCConnection
    }
    private let lock = NSRecursiveLock()
    private let requests = ServiceRequestRegistry<BrokerResponse>()
    private let logger = Logger(subsystem: "app.benSync", category: "service-client")
    private var current: ConnectionState?

    init() {}

    deinit {
        current?.connection.invalidate()
        requests.failAll(error: BackendError(.offline, "The background service connection closed. Retry the operation."))
    }

    /// Called with the client lock held. A replacement connection is used only
    /// by a later request; no ambiguous upload/delete is automatically replayed.
    private func connectionLocked() -> ConnectionState {
        if let current { return current }
        let connection = NSXPCConnection(serviceName: AppEnvironment.brokerIdentifier)
        let generation = UUID()
        connection.remoteObjectInterface = NSXPCInterface(with: RemoteBrokerProtocol.self)
        connection.interruptionHandler = { [weak self] in self?.connectionFailed(generation, reason: "interrupted") }
        connection.invalidationHandler = { [weak self] in self?.connectionFailed(generation, reason: "invalidated") }
        let state = ConnectionState(generation: generation, connection: connection)
        current = state; connection.resume()
        logger.debug("connection_opened")
        return state
    }

    private func connectionFailed(_ generation: UUID, reason: String) {
        lock.lock()
        let failed = current?.generation == generation ? current?.connection : nil
        if failed != nil { current = nil }
        lock.unlock()
        failed?.invalidate()
        let count = requests.fail(generation: generation, error: BackendError(.offline,
            "The background service restarted or became unavailable. Retry the operation; pending local edits are retained."))
        if count > 0 { logger.error("connection_failed reason=\(reason, privacy: .public) requests=\(count)") }
    }

    private func cancel(_ id: UUID, generation: UUID) {
        lock.lock()
        guard requests.contains(id: id, generation: generation) else { lock.unlock(); return }
        if let current, current.generation == generation {
            (current.connection.remoteObjectProxyWithErrorHandler { _ in } as? RemoteBrokerProtocol)?.cancel(id)
        }
        lock.unlock()
        requests.complete(id: id, generation: generation, result: .failure(BackendError(.cancelled, "Operation cancelled.")))
    }

    private func discardUnsentUpload(_ request: BrokerRequest) {
        guard request.operation == .create || request.operation == .modify,
              let token = request.token, let storage = try? AppEnvironment.storage(),
              let url = try? storage.transferURL(token) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func perform(_ request: BrokerRequest, progress: Progress? = nil, completion: @escaping (Result<BrokerResponse, Error>) -> Void) {
        let id = UUID()
        do {
            let data = try JSONEncoder().encode(request)
            let listener = progress.map(ProgressListener.init)
            lock.lock()
            let state = connectionLocked()
            let generation = state.generation
            requests.insert(id: id, generation: generation) { result in
                listener?.invalidate(); progress?.cancellationHandler = nil; completion(result)
            }
            progress?.cancellationHandler = { [weak self] in self?.cancel(id, generation: generation) }
            guard current?.generation == generation else {
                lock.unlock(); discardUnsentUpload(request)
                requests.complete(id: id, generation: generation,
                    result: .failure(BackendError(.offline, "The background service could not connect. Retry the operation.")))
                return
            }
            if progress?.isCancelled == true {
                lock.unlock()
                discardUnsentUpload(request)
                requests.complete(id: id, generation: generation, result: .failure(BackendError(.cancelled, "Operation cancelled.")))
                return
            }
            guard let proxy = state.connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.connectionFailed(generation, reason: "proxy-error")
            }) as? RemoteBrokerProtocol else {
                lock.unlock(); discardUnsentUpload(request); connectionFailed(generation, reason: "missing-proxy"); return
            }
            // Cancellation uses this same lock. Its message can only precede
            // execute if the progress was already cancelled, handled above.
            proxy.execute(data, operationID: id, progress: listener?.endpoint) { [weak self] data in
                let result: Result<BrokerResponse, Error>
                do {
                    let response = try JSONDecoder().decode(BrokerResponse.self, from: data)
                    if let error = response.error { result = .failure(error) } else { result = .success(response) }
                } catch { result = .failure(BackendError(.internalError, "The background service returned an invalid response.")) }
                self?.requests.complete(id: id, generation: generation, result: result)
            }
            lock.unlock()
        } catch { discardUnsentUpload(request); completion(.failure(error)) }
    }

    func perform(_ request: BrokerRequest) async throws -> BrokerResponse {
        let progress = Progress(totalUnitCount: -1)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                perform(request, progress: progress) { continuation.resume(with: $0) }
            }
        } onCancel: { progress.cancel() }
    }
}
