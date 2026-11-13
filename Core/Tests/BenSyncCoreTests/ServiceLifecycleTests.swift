import Foundation
import Testing
@testable import BenSyncCore

@Suite("Background service lifecycle")
struct ServiceLifecycleTests {
    @Test func replyAndLaterConnectionFailureCompleteOnlyOnce() {
        let requests = ServiceRequestRegistry<Int>(), generation = UUID(), id = UUID()
        var values = [Int]()
        requests.insert(id: id, generation: generation) { result in
            if case .success(let value) = result { values.append(value) }
            else { Issue.record("A completed write must not later become a connection failure.") }
        }
        #expect(requests.complete(id: id, generation: generation, result: .success(7)))
        #expect(!requests.complete(id: id, generation: generation, result: .success(8)))
        #expect(requests.fail(generation: generation, error: BackendError(.offline, "Synthetic restart")) == 0)
        #expect(values == [7])
        #expect(requests.count == 0)
    }

    @Test func interruptionCompletesAllOutstandingRequestsWithoutReplayingThem() {
        let requests = ServiceRequestRegistry<Int>(), generation = UUID()
        var failures = 0
        for _ in 0..<3 {
            requests.insert(id: UUID(), generation: generation) { result in
                if case .failure = result { failures += 1 }
                else { Issue.record("A disconnected request has no known successful result.") }
            }
        }
        #expect(requests.fail(generation: generation, error: BackendError(.offline, "Synthetic restart")) == 3)
        #expect(requests.fail(generation: generation, error: BackendError(.offline, "Late invalidation")) == 0)
        #expect(failures == 3)
        #expect(requests.count == 0)
    }

    @Test func lateOldConnectionFailureCannotDrainReplacementRequests() {
        let requests = ServiceRequestRegistry<Int>(), old = UUID(), replacement = UUID()
        let id = UUID()
        var value: Int?
        requests.insert(id: id, generation: replacement) { result in value = try? result.get() }
        #expect(requests.fail(generation: old, error: BackendError(.offline, "Old failure")) == 0)
        #expect(requests.contains(id: id, generation: replacement))
        #expect(!requests.complete(id: id, generation: old, result: .success(-1)))
        #expect(requests.complete(id: id, generation: replacement, result: .success(12)))
        #expect(value == 12)
    }

    @Test func simultaneousReplyAndFailureHaveExactlyOneWinner() {
        let requests = ServiceRequestRegistry<Int>(), generation = UUID(), id = UUID()
        let lock = NSLock()
        var count = 0
        requests.insert(id: id, generation: generation) { _ in lock.lock(); count += 1; lock.unlock() }
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            if iteration.isMultiple(of: 2) {
                requests.complete(id: id, generation: generation, result: .success(iteration))
            } else { requests.fail(generation: generation, error: BackendError(.offline, "Synthetic race")) }
        }
        #expect(count == 1)
        #expect(requests.count == 0)
    }

    @Test func callbackCanImmediatelyRegisterAnotherOperation() {
        let requests = ServiceRequestRegistry<Int>(), generation = UUID(), first = UUID(), second = UUID()
        var finalValue: Int?
        requests.insert(id: first, generation: generation) { _ in
            requests.insert(id: second, generation: generation) { result in finalValue = try? result.get() }
            requests.complete(id: second, generation: generation, result: .success(2))
        }
        requests.complete(id: first, generation: generation, result: .success(1))
        #expect(finalValue == 2)
    }

    @Test func duplicateRegistrationCannotReplaceAnOutstandingCallback() {
        let requests = ServiceRequestRegistry<Int>(), generation = UUID(), id = UUID()
        var originalCalled = false
        #expect(requests.insert(id: id, generation: generation) { _ in originalCalled = true })
        #expect(!requests.insert(id: id, generation: UUID()) { _ in Issue.record("Duplicate replaced the original callback.") })
        requests.failAll(error: BackendError(.offline, "Shutdown"))
        #expect(originalCalled)
        #expect(requests.count == 0)
    }

    @Test func cancellationBeforeExecuteRegistrationPreventsRemoteWork() throws {
        let tracker = ServiceOperationTracker(), id = UUID()
        tracker.cancel(id: id)
        let progress = try #require(tracker.register(id: id, destinationID: UUID()))
        #expect(progress.isCancelled)
        tracker.finish(id: id)
    }

    @Test func cancellationAfterRegistrationReachesTheSameProgress() throws {
        let tracker = ServiceOperationTracker(), id = UUID()
        let progress = try #require(tracker.register(id: id, destinationID: UUID()))
        #expect(!progress.isCancelled)
        tracker.cancel(id: id)
        #expect(progress.isCancelled)
    }

    @Test func removingDestinationCancelsItsOperationsWithoutCancellingRemovalOrOtherDestinations() throws {
        let tracker = ServiceOperationTracker(), destination = UUID(), removal = UUID()
        let scan = try #require(tracker.register(id: UUID(), destinationID: destination))
        let remove = try #require(tracker.register(id: removal, destinationID: destination))
        let unrelated = try #require(tracker.register(id: UUID(), destinationID: UUID()))
        tracker.cancel(destinationID: destination, excluding: removal)
        #expect(scan.isCancelled)
        #expect(!remove.isCancelled)
        #expect(!unrelated.isCancelled)
    }

    @Test func duplicateServerOperationCannotReplaceCancellationTarget() throws {
        let tracker = ServiceOperationTracker(), id = UUID()
        let original = try #require(tracker.register(id: id, destinationID: UUID()))
        #expect(tracker.register(id: id, destinationID: UUID()) == nil)
        tracker.cancel(id: id)
        #expect(original.isCancelled)
    }

    @Test func earlyCancellationMemoryIsBounded() throws {
        let tracker = ServiceOperationTracker(maximumEarlyCancellations: 2)
        let old = UUID(), recent = UUID(), newest = UUID()
        for id in [old, recent, newest] { tracker.cancel(id: id) }
        #expect(try !#require(tracker.register(id: old, destinationID: nil)).isCancelled)
        #expect(try #require(tracker.register(id: recent, destinationID: nil)).isCancelled)
        #expect(try #require(tracker.register(id: newest, destinationID: nil)).isCancelled)
    }
}
