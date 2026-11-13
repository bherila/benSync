import Foundation

/// A service connection may report a reply, a proxy error, and an interruption
/// for the same request. Exactly one of those events may complete its caller.
/// Old-connection events must never drain requests on a replacement connection.
public final class ServiceRequestRegistry<Value>: @unchecked Sendable {
    public typealias Completion = (Result<Value, Error>) -> Void
    private struct Entry {
        var generation: UUID
        var completion: Completion
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    public init() {}

    @discardableResult
    public func insert(id: UUID, generation: UUID, completion: @escaping Completion) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[id] == nil else { return false }
        entries[id] = Entry(generation: generation, completion: completion)
        return true
    }

    public func contains(id: UUID, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.generation == generation
    }

    @discardableResult
    public func complete(id: UUID, generation: UUID, result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard entries[id]?.generation == generation, let entry = entries.removeValue(forKey: id) else {
            lock.unlock(); return false
        }
        lock.unlock()
        // Call outside the lock: a caller may immediately start another request.
        entry.completion(result)
        return true
    }

    @discardableResult
    public func fail(generation: UUID, error: Error) -> Int {
        lock.lock()
        let keys = entries.filter { $0.value.generation == generation }.map(\.key)
        let callbacks = keys.compactMap { entries.removeValue(forKey: $0)?.completion }
        lock.unlock()
        callbacks.forEach { $0(.failure(error)) }
        return callbacks.count
    }

    @discardableResult
    public func failAll(error: Error) -> Int {
        lock.lock()
        let callbacks = entries.values.map(\.completion)
        entries.removeAll()
        lock.unlock()
        callbacks.forEach { $0(.failure(error)) }
        return callbacks.count
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }; return entries.count
    }
}

/// XPC may dispatch cancellation before the execute method registers an
/// operation. Remember a bounded number of early cancellations so a cancelled
/// request cannot start a remote write merely because those messages raced.
public final class ServiceOperationTracker: @unchecked Sendable {
    private struct Entry {
        var destinationID: UUID?
        var progress: Progress
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var earlyCancellations = Set<UUID>()
    private var cancellationOrder = [UUID]()
    private let maximumEarlyCancellations: Int

    public init(maximumEarlyCancellations: Int = 512) {
        self.maximumEarlyCancellations = max(1, maximumEarlyCancellations)
    }

    /// A duplicate operation ID is refused rather than replacing active state.
    public func register(id: UUID, destinationID: UUID?) -> Progress? {
        lock.lock()
        guard entries[id] == nil else { lock.unlock(); return nil }
        let progress = Progress(totalUnitCount: -1)
        entries[id] = Entry(destinationID: destinationID, progress: progress)
        let cancelled = earlyCancellations.remove(id) != nil
        lock.unlock()
        if cancelled { progress.cancel() }
        return progress
    }

    public func cancel(id: UUID) {
        lock.lock()
        let progress = entries[id]?.progress
        if progress == nil, earlyCancellations.insert(id).inserted {
            cancellationOrder.append(id)
            while cancellationOrder.count > maximumEarlyCancellations {
                earlyCancellations.remove(cancellationOrder.removeFirst())
            }
        }
        lock.unlock()
        progress?.cancel()
    }

    public func cancel(destinationID: UUID, excluding excluded: UUID? = nil) {
        lock.lock()
        let progress = entries.filter { $0.key != excluded && $0.value.destinationID == destinationID }.map { $0.value.progress }
        lock.unlock()
        progress.forEach { $0.cancel() }
    }

    public func finish(id: UUID) {
        lock.lock(); entries[id] = nil; lock.unlock()
    }
}
