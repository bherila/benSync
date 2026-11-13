import Foundation
import Testing
@testable import BenSyncCore

@Suite("Quality and failure boundaries")
struct QualityTests {
    @Test func destinationDefaultsAndOlderConfigurationRemainCompatible() throws {
        let original = Destination(name: "Synthetic", sshProfile: "synthetic")
        #expect(!original.paused)
        #expect(original.root == ".")
        #expect(original.refreshInterval == 300)
        #expect(original.exclusions == ["node_modules", ".git"])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "paused")
        let decoded = try JSONDecoder().decode(Destination.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original)
        #expect(!decoded.paused)
    }

    @Test func pauseRoundTripsThroughSharedStorageAndKeepsCatalogueIdentifiers() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/offline.txt", text: "cached")
        _ = try f.engine.scan()
        let item = try #require(try f.engine.catalogue.atPath("offline.txt"))
        var configuration = f.engine.destination
        configuration.paused = true
        try f.storage.save(configuration)
        let reopened = try Storage(root: f.storage.root)
        #expect(try reopened.destination(configuration.id).paused)
        #expect(try reopened.catalogue(configuration).node(item.id)?.id == item.id)
        configuration.paused = false
        try reopened.save(configuration)
        #expect(try !f.storage.destination(configuration.id).paused)
    }

    @Test func malformedSharedConfigurationIsNotReplacedWithAnEmptyDefault() throws {
        let temporary = try TemporaryDirectory(), storage = try Storage(root: temporary.url)
        let url = temporary.url.appendingPathComponent("destinations.json")
        let corrupt = Data("{invalid synthetic json".utf8)
        try corrupt.write(to: url)
        #expect(throws: DecodingError.self) { try storage.destinations() }
        #expect(throws: DecodingError.self) { try storage.save(Destination(name: "Synthetic", sshProfile: "synthetic")) }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func invalidPauseValueDoesNotSilentlyResumeTheDestination() throws {
        var original = Destination(name: "Synthetic", sshProfile: "synthetic")
        original.paused = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["paused"] = "true"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Destination.self, from: data) }
    }

    @Test func persistedPauseBlocksEveryNewRemoteOperationEvenInAnExistingEngine() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/offline.txt", text: "cached")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("offline.txt"))
        var configuration = f.engine.destination
        configuration.paused = true
        try f.storage.save(configuration)
        let listed = f.backend.lists
        f.backend.statHook = { _ in Issue.record("A paused destination attempted remote metadata access.") }
        let input = try f.directory.write("local-change.txt", "pending local edit")
        expectBackendError(.offline) { _ = try f.engine.scan(minimumAge: 300) }
        expectBackendError(.offline) { _ = try f.engine.download(node.id, to: f.directory.url.appendingPathComponent("download"), progress: Progress(totalUnitCount: -1)) }
        expectBackendError(.offline) { _ = try f.engine.create(parentID: Node.rootID, name: "new.txt", kind: .file, contents: input, creationID: "paused-create", progress: Progress(totalUnitCount: -1)) }
        expectBackendError(.offline) { _ = try f.modify(node, contents: input) }
        expectBackendError(.offline) { _ = try f.modify(node, name: "renamed.txt") }
        expectBackendError(.offline) { try f.engine.delete(id: node.id, version: node.contentVersion) }
        #expect(f.backend.lists == listed)
        #expect(f.backend.downloads.isEmpty)
        #expect(f.backend.uploads.isEmpty)
        #expect(f.backend.moves.isEmpty)
        #expect(f.backend.removals.isEmpty)
        #expect(f.backend.bytes["/remote/offline.txt"] == Data("cached".utf8))
    }

    @Test func pausedDestinationStillAcceptsLocalMetadataAndResumesWithoutRebuildingItsCatalogue() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/offline.txt", text: "cached")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("offline.txt"))
        var configuration = f.engine.destination
        configuration.paused = true
        try f.storage.save(configuration)
        f.backend.offline = true
        let updated = try f.engine.modify(id: node.id, version: node.contentVersion, name: nil, parentID: nil, contents: nil,
                                          tags: Data("synthetic-tag".utf8), changeTags: true,
                                          favoriteRank: 7, changeFavorite: true, lastUsed: Date(timeIntervalSince1970: 42),
                                          changeLastUsed: true, progress: Progress(totalUnitCount: 1))
        #expect(updated.tagData == Data("synthetic-tag".utf8))
        #expect(updated.favoriteRank == 7)
        #expect(updated.lastUsed == Date(timeIntervalSince1970: 42))
        #expect(updated.contentVersion == node.contentVersion)
        configuration.paused = false
        try f.storage.save(configuration)
        f.backend.offline = false
        f.backend.addFile("/remote/new.txt", text: "new")
        #expect(try f.engine.scan().changed)
        #expect(try f.engine.catalogue.atPath("offline.txt")?.id == node.id)
        #expect(try f.engine.catalogue.atPath("new.txt") != nil)
        #expect(f.backend.downloads.isEmpty)
    }

    @Test func removalPreventsAnOldEngineFromOpeningFurtherConnections() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/offline.txt", text: "cached")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("offline.txt"))
        let listed = f.backend.lists
        try f.storage.remove(f.engine.destination.id)
        expectBackendError(.notFound) { _ = try f.engine.scan() }
        expectBackendError(.notFound) { _ = try f.engine.download(node.id, to: f.directory.url.appendingPathComponent("download"), progress: Progress(totalUnitCount: -1)) }
        #expect(f.backend.lists == listed)
        #expect(f.backend.downloads.isEmpty)
        #expect(try f.storage.destinations().isEmpty)
        #expect(try f.engine.catalogue.node(node.id) != nil)
    }

    @Test func changedExclusionsStopAnInflightScanBeforeEnteringItsOldQueuedSubtrees() throws {
        let f = try EngineFixture(exclusions: [])
        f.backend.addDirectory("/remote/excluded")
        f.backend.addFile("/remote/excluded/file.txt", text: "never transfer")
        var configuration = f.engine.destination
        configuration.exclusions = ["excluded"]
        f.backend.listHook = { path in
            if path == "/remote" { try f.storage.save(configuration) }
        }
        expectBackendError(.cancelled) { _ = try f.engine.scan() }
        #expect(f.backend.lists == ["/remote"])
        f.backend.listHook = nil
        let refreshed = try DestinationEngine(destination: configuration, storage: f.storage, backend: f.backend)
        #expect(try refreshed.scan().complete)
        #expect(try refreshed.catalogue.atPath("excluded") == nil)
        #expect(f.backend.downloads.isEmpty)
    }

    @Test func retryDelaysAreBoundedForNegativeAndExtremeFailureCounts() {
        #expect(RetryPolicy.delay(failures: -1) == 30)
        #expect(RetryPolicy.delay(failures: 0) == 30)
        #expect(RetryPolicy.delay(failures: 1) == 60)
        #expect(RetryPolicy.delay(failures: 2) == 120)
        #expect(RetryPolicy.delay(failures: 5) == 960)
        #expect(RetryPolicy.delay(failures: 6) == 1800)
        #expect(RetryPolicy.delay(failures: .max) == 1800)
        #expect(RetryPolicy.delay(failures: .min) == 30)
    }

    @Test func diagnosticsTrackBoundedEventsAndCumulativeCountersAcrossReopening() throws {
        let temporary = try TemporaryDirectory(), url = temporary.url.appendingPathComponent("metrics.sqlite")
        let store = try DiagnosticsStore(url: url)
        for index in 0..<250 {
            try store.record(.init(operation: .download, durationMilliseconds: 2, transferredBytes: Int64(index), itemCount: index))
        }
        let reopened = try DiagnosticsStore(url: url), snapshot = try reopened.snapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.recent.count == 200)
        #expect(snapshot.recent.first?.itemCount == 249)
        #expect(snapshot.recent.last?.itemCount == 50)
        #expect(Set(snapshot.recent.map(\.id)).count == 200)
        #expect(snapshot.totals.operationCount == 250)
        #expect(snapshot.totals.downloadedBytes == Int64((0..<250).reduce(0, +)))
        #expect(snapshot.totals.totalDurationMilliseconds == 500)
    }

    @Test func diagnosticsDisabledStateClearsDataAndIsHonoredByAnotherOpenStore() throws {
        let temporary = try TemporaryDirectory(), url = temporary.url.appendingPathComponent("metrics.sqlite")
        let first = try DiagnosticsStore(url: url), second = try DiagnosticsStore(url: url)
        try first.record(.init(operation: .download, durationMilliseconds: 3, transferredBytes: 20))
        try second.setEnabled(false)
        try first.record(.init(operation: .create, durationMilliseconds: 5, transferredBytes: 40))
        let disabled = try first.snapshot()
        #expect(!disabled.isEnabled)
        #expect(disabled.recent.isEmpty)
        #expect(disabled.totals.operationCount == 0)
        #expect(disabled.totals.downloadedBytes == 0)
        #expect(disabled.totals.uploadedBytes == 0)
        try first.setEnabled(true)
        try second.record(.init(operation: .modify, durationMilliseconds: 1, transferredBytes: 7))
        let enabled = try first.snapshot()
        #expect(enabled.isEnabled)
        #expect(enabled.recent.count == 1)
        #expect(enabled.totals.uploadedBytes == 7)
    }

    @Test func diagnosticsClassifyTrafficErrorsAndCancellationWithoutFreeText() throws {
        let temporary = try TemporaryDirectory(), store = try DiagnosticsStore(url: temporary.url.appendingPathComponent("metrics.sqlite"))
        try store.record(.init(operation: .create, durationMilliseconds: 2, transferredBytes: 4))
        try store.record(.init(operation: .modify, errorKind: .offline, durationMilliseconds: 3, transferredBytes: 8))
        try store.record(.init(operation: .download, errorKind: .cancelled, durationMilliseconds: 5, transferredBytes: 16))
        try store.record(.init(operation: .scan, durationMilliseconds: 7, itemCount: 12))
        let snapshot = try store.snapshot()
        #expect(snapshot.totals.operationCount == 4)
        #expect(snapshot.totals.errorCount == 1)
        #expect(snapshot.totals.uploadedBytes == 12)
        #expect(snapshot.totals.downloadedBytes == 16)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(Set(json.keys) == ["schemaVersion", "recordedAt", "isEnabled", "totals", "recent"])
        let recent = try #require(json["recent"] as? [[String: Any]])
        let allowed: Set<String> = ["id", "recordedAt", "operation", "errorKind", "durationMilliseconds", "transferredBytes", "itemCount"]
        #expect(recent.allSatisfy { Set($0.keys).isSubset(of: allowed) })
    }

    @Test func invalidDiagnosticMetricsFailBeforeWritingAnything() throws {
        let temporary = try TemporaryDirectory(), store = try DiagnosticsStore(url: temporary.url.appendingPathComponent("metrics.sqlite"))
        for duration in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            expectBackendError(.invalid) { try store.record(.init(operation: .scan, durationMilliseconds: duration)) }
        }
        expectBackendError(.invalid) { try store.record(.init(operation: .download, durationMilliseconds: 1, transferredBytes: -1)) }
        expectBackendError(.invalid) { try store.record(.init(operation: .scan, durationMilliseconds: 1, itemCount: -1)) }
        #expect(try store.snapshot().totals.operationCount == 0)
        #expect(try store.snapshot().recent.isEmpty)
    }

    @Test func diagnosticCountersSaturateInsteadOfOverflowing() throws {
        let temporary = try TemporaryDirectory(), store = try DiagnosticsStore(url: temporary.url.appendingPathComponent("metrics.sqlite"))
        for _ in 0..<2 {
            try store.record(.init(operation: .download, durationMilliseconds: .greatestFiniteMagnitude, transferredBytes: .max))
        }
        let totals = try store.snapshot().totals
        #expect(totals.downloadedBytes == .max)
        #expect(totals.totalDurationMilliseconds == .greatestFiniteMagnitude)
        #expect(totals.operationCount == 2)
    }

    @Test func diagnosticWritersShareAtomicCumulativeCounters() throws {
        let temporary = try TemporaryDirectory(), url = temporary.url.appendingPathComponent("metrics.sqlite")
        let stores = [try DiagnosticsStore(url: url), try DiagnosticsStore(url: url)]
        let lock = NSLock()
        var failures = [Error]()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do { try stores[index % 2].record(.init(operation: .download, durationMilliseconds: 1, transferredBytes: 2)) }
            catch { lock.lock(); failures.append(error); lock.unlock() }
        }
        #expect(failures.isEmpty)
        let snapshot = try stores[0].snapshot()
        #expect(snapshot.totals.operationCount == 40)
        #expect(snapshot.totals.downloadedBytes == 80)
        #expect(snapshot.recent.count == 40)
    }

    @Test func malformedSFTPStringsRejectTruncationAndOversizedLengthsWithoutAllocating() throws {
        for bytes: [UInt8] in [[], [0], [0, 0, 0], [0, 0, 0, 3, 65, 66], [255, 255, 255, 255]] {
            var packet = Packet(Data(bytes))
            expectBackendError(.invalid) { _ = try packet.readBytes() }
        }
    }

    @Test func malformedSFTPNumbersRejectTruncatedFrames() throws {
        for size in 0..<4 {
            var packet = Packet(Data(repeating: 1, count: size))
            expectBackendError(.invalid) { _ = try packet.read32() }
        }
        for size in 0..<8 {
            var packet = Packet(Data(repeating: 1, count: size))
            expectBackendError(.invalid) { _ = try packet.read64() }
        }
        var empty = Packet()
        expectBackendError(.invalid) { _ = try empty.readByte() }
    }

    @Test func malformedSFTPTextRejectsInvalidUTF8() throws {
        var packet = Packet(Data([0, 0, 0, 2, 0xc3, 0x28]))
        expectBackendError(.invalid) { _ = try packet.readString() }
    }

    @Test func SFTPPacketFieldsRemainSeparatedWhenStringsContainUnicodeAndNewlines() throws {
        var encoded = Packet()
        encoded.uint32(0x01020304)
        encoded.string("👩🏽‍💻\nfile.txt")
        encoded.uint64(0x0102030405060708)
        var decoded = Packet(encoded.data)
        #expect(try decoded.read32() == 0x01020304)
        #expect(try decoded.readString() == "👩🏽‍💻\nfile.txt")
        #expect(try decoded.read64() == 0x0102030405060708)
        #expect(decoded.offset == encoded.data.count)
    }

    @Test func malformedSFTPServerFramesFailWithoutWaitingForTheHandshakeDeadline() throws {
        let cases: [([UInt8], BackendError.Kind)] = [
            ([0, 0], .offline),
            ([0, 0, 0, 0], .invalid),
            ([1, 0, 0, 1], .invalid),
            ([0, 0, 0, 10, 2, 0], .offline),
            ([0, 0, 0, 5, 2, 0, 0, 0, 99], .unsupported),
        ]
        for (bytes, expected) in cases {
            let temporary = try TemporaryDirectory()
            let response = bytes.map(String.init).joined(separator: ",")
            let executable = try temporary.write("synthetic-server", """
            #!/usr/bin/env python3
            import sys
            sys.stdin.buffer.read(9)
            sys.stdout.buffer.write(bytes([\(response)]))
            sys.stdout.buffer.flush()
            """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let began = Date()
            expectBackendError(expected) { _ = try SFTPWire(localServer: executable) }
            #expect(Date().timeIntervalSince(began) < 10)
        }
    }
}
