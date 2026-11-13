import Foundation
import Testing
@testable import BenSyncCore

@Suite("Destination sync behavior")
struct DestinationEngineTests {
    @Test func scanEnumeratesOnlyMetadataAndSkipsExcludedTrees() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/src")
        f.backend.addFile("/remote/src/main.swift", text: "synthetic")
        f.backend.addDirectory("/remote/node_modules")
        f.backend.addFile("/remote/node_modules/package.js", text: "never transfer")
        f.backend.addDirectory("/remote/src/.git")
        f.backend.addFile("/remote/src/.git/config", text: "never enumerate")
        let result = try f.engine.scan()
        #expect(result.complete)
        #expect(result.itemCount == 2)
        #expect(Set(f.backend.lists) == ["/remote", "/remote/src"])
        #expect(f.backend.downloads.isEmpty)
        #expect(f.backend.uploads.isEmpty)
        #expect(f.backend.removals.isEmpty)
        #expect(try f.engine.catalogue.atPath("node_modules") == nil)
        #expect(try f.engine.catalogue.atPath("src/main.swift") != nil)
    }

    @Test func unchangedScanDoesNotGrowTheChangeJournal() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "same bytes")
        _ = try f.engine.scan()
        let anchor = try f.engine.catalogue.anchor()
        let result = try f.engine.scan()
        #expect(!result.changed)
        #expect(try f.engine.catalogue.anchor() == anchor)
        #expect(f.backend.downloads.isEmpty)
    }

    @Test func recentCatalogueSuppressesRedundantBackgroundRemoteListings() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addFile("/remote/folder/notes.txt", text: "same")
        let first = try f.engine.scan()
        let lists = f.backend.lists, anchor = try f.engine.catalogue.anchor()
        f.backend.offline = true
        let cached = try f.engine.scan(minimumAge: 300)
        #expect(cached.complete)
        #expect(!cached.changed)
        #expect(cached.itemCount == first.itemCount)
        #expect(cached.date == first.date || abs(cached.date.timeIntervalSince(first.date)) < 0.001)
        #expect(f.backend.lists == lists)
        #expect(try f.engine.catalogue.anchor() == anchor)
    }

    @Test func explicitRefreshBypassesTheRecentCatalogueSuppression() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/old.txt", text: "old")
        _ = try f.engine.scan()
        let lists = f.backend.lists.count
        f.backend.addFile("/remote/new.txt", text: "new")
        let refreshed = try f.engine.scan(minimumAge: 0)
        #expect(refreshed.changed)
        #expect(f.backend.lists.count > lists)
        #expect(try f.engine.catalogue.atPath("new.txt") != nil)
    }

    @Test func expiredCatalogueRefreshesEvenWhenMinimumAgeIsSpecified() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "first", version: "v1")
        _ = try f.engine.scan()
        let lists = f.backend.lists.count
        try f.engine.catalogue.setState("lastScan", String(Date().addingTimeInterval(-3600).timeIntervalSince1970))
        f.backend.addFile("/remote/notes.txt", text: "updated", version: "v2")
        let refreshed = try f.engine.scan(minimumAge: 300)
        #expect(refreshed.changed)
        #expect(f.backend.lists.count > lists)
        #expect(try f.engine.catalogue.atPath("notes.txt")?.entry.version == "v2")
    }

    @Test func suppressedScanDoesNotHideTheLatestPartialRefresh() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addFile("/remote/folder/notes.txt", text: "cached")
        #expect(try f.engine.scan().complete)
        f.backend.failures["/remote/folder"] = BackendError(.permission, "Fixture access denied.")
        #expect(try !f.engine.scan().complete)
        let lists = f.backend.lists
        let cached = try f.engine.scan(minimumAge: 300)
        #expect(!cached.complete)
        #expect(f.backend.lists == lists)
        #expect(try f.engine.catalogue.atPath("folder/notes.txt") != nil)
    }

    @Test func unreadableBranchPreservesItsPreviouslyCachedChildren() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/private-folder")
        f.backend.addFile("/remote/private-folder/offline.txt", text: "cached metadata")
        _ = try f.engine.scan()
        let old = try #require(try f.engine.catalogue.atPath("private-folder/offline.txt"))
        f.backend.failures["/remote/private-folder"] = BackendError(.permission, "Fixture access denied.")
        let result = try f.engine.scan()
        #expect(!result.complete)
        #expect(result.warnings.count == 1)
        #expect(try f.engine.catalogue.node(old.id) == old)
        #expect(f.backend.removals.isEmpty)
    }

    @Test func disconnectKeepsTheCompleteNamespaceBrowsableOffline() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addFile("/remote/folder/notes.txt", text: "cached file")
        _ = try f.engine.scan()
        let old = try #require(try f.engine.catalogue.atPath("folder/notes.txt"))
        f.backend.offline = true
        expectBackendError(.offline) { _ = try f.engine.scan() }
        #expect(try f.engine.catalogue.node(old.id) == old)
        #expect(try f.engine.catalogue.count() == 2)
        let reopened = try f.storage.catalogue(f.engine.destination)
        #expect(try reopened.atPath("folder/notes.txt")?.id == old.id)
    }

    @Test func explicitHydrationStreamsOnlyTheRequestedFile() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/first.txt", text: "requested bytes")
        f.backend.addFile("/remote/second.txt", text: "not requested")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("first.txt"))
        let target = f.directory.url.appendingPathComponent("hydrated")
        let result = try f.engine.download(node.id, to: target, progress: Progress(totalUnitCount: -1))
        #expect(try Data(contentsOf: target) == Data("requested bytes".utf8))
        #expect(result.id == node.id)
        #expect(f.backend.downloads == ["/remote/first.txt"])
        #expect(f.backend.uploads.isEmpty)
    }

    @Test func excludedCreatesAndRenamesNeverWriteToTheRemote() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/visible")
        _ = try f.engine.scan()
        expectBackendError(.permission) {
            _ = try f.engine.create(parentID: Node.rootID, name: "node_modules", kind: .directory,
                                    contents: nil, creationID: "excluded-create", progress: Progress(totalUnitCount: 1))
        }
        let visible = try #require(try f.engine.catalogue.atPath("visible"))
        expectBackendError(.permission) { _ = try f.modify(visible, name: "node_modules") }
        #expect(f.backend.entries["/remote/node_modules"] == nil)
        #expect(f.backend.moves.isEmpty)
        #expect(f.backend.uploads.isEmpty)
    }

    @Test func remoteVersionChangeRejectsOfflineEditsAndRetainsBothCopies() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "base", version: "base-version")
        _ = try f.engine.scan()
        let old = try #require(try f.engine.catalogue.atPath("notes.txt"))
        let local = try f.directory.write("local-edits", "local offline changes")
        f.backend.addFile("/remote/notes.txt", text: "remote changes", version: "remote-version")
        expectBackendError(.conflict) { _ = try f.modify(old, contents: local) }
        #expect(f.backend.bytes["/remote/notes.txt"] == Data("remote changes".utf8))
        #expect(try Data(contentsOf: local) == Data("local offline changes".utf8))
        #expect(f.backend.uploads.isEmpty)
        #expect(try f.engine.catalogue.node(old.id)?.entry.version == "remote-version")
    }

    @Test func staleFinderVersionCannotOverwriteAfterACatalogueRefresh() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "old", version: "v1")
        _ = try f.engine.scan()
        let old = try #require(try f.engine.catalogue.atPath("notes.txt"))
        f.backend.addFile("/remote/notes.txt", text: "new", version: "v2")
        _ = try f.engine.scan()
        let local = try f.directory.write("local", "offline edit")
        expectBackendError(.conflict) { _ = try f.modify(old, contents: local, version: old.contentVersion) }
        #expect(f.backend.uploads.isEmpty)
        #expect(f.backend.bytes["/remote/notes.txt"] == Data("new".utf8))
    }

    @Test func successfulOfflineEditReplayPreservesIdentifierAndUpdatesVersion() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "base")
        _ = try f.engine.scan()
        let old = try #require(try f.engine.catalogue.atPath("notes.txt"))
        let local = try f.directory.write("local", "saved while offline")
        f.backend.offline = true
        expectBackendError(.offline) { _ = try f.modify(old, contents: local) }
        #expect(try Data(contentsOf: local) == Data("saved while offline".utf8))
        f.backend.offline = false
        let updated = try f.modify(old, contents: local)
        #expect(updated.id == old.id)
        #expect(updated.contentVersion != old.contentVersion)
        #expect(f.backend.bytes["/remote/notes.txt"] == Data("saved while offline".utf8))
    }

    @Test func movingDirectoryPreservesAllCachedDescendantIdentifiers() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/old")
        f.backend.addDirectory("/remote/old/nested")
        f.backend.addFile("/remote/old/nested/notes.txt", text: "same")
        _ = try f.engine.scan()
        let folder = try #require(try f.engine.catalogue.atPath("old"))
        let child = try #require(try f.engine.catalogue.atPath("old/nested/notes.txt"))
        let moved = try f.modify(folder, name: "new")
        #expect(moved.id == folder.id)
        #expect(try f.engine.catalogue.atPath("new/nested/notes.txt")?.id == child.id)
        #expect(f.backend.downloads.isEmpty)
        #expect(f.backend.uploads.isEmpty)
    }

    @Test func movingFolderInsideItselfIsRejectedBeforeRemoteMutation() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addDirectory("/remote/folder/child")
        _ = try f.engine.scan()
        let folder = try #require(try f.engine.catalogue.atPath("folder"))
        let child = try #require(try f.engine.catalogue.atPath("folder/child"))
        expectBackendError(.invalid) { _ = try f.modify(folder, parentID: child.id) }
        #expect(f.backend.moves.isEmpty)
    }

    @Test func caseInsensitiveCollisionIsRejectedBeforeRemoteMutation() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/one.txt", text: "one")
        f.backend.addFile("/remote/other.txt", text: "two")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("other.txt"))
        expectBackendError(.collision) { _ = try f.modify(node, name: "ONE.TXT") }
        #expect(f.backend.moves.isEmpty)
    }

    @Test func creationReplayDoesNotUploadTheSameFileAgain() throws {
        let f = try EngineFixture(), contents = try f.directory.write("new-file", "created content")
        let first = try f.engine.create(parentID: Node.rootID, name: "new.txt", kind: .file, contents: contents,
                                        creationID: "stable-operation", progress: Progress(totalUnitCount: -1))
        let replay = try f.engine.create(parentID: Node.rootID, name: "new.txt", kind: .file, contents: contents,
                                         creationID: "stable-operation", progress: Progress(totalUnitCount: -1))
        #expect(replay.id == first.id)
        #expect(f.backend.uploads.count == 1)
    }

    @Test func completedCreationReceiptSurvivesEngineAndCatalogueReopening() throws {
        let f = try EngineFixture(), contents = try f.directory.write("new-source", "new content")
        let first = try f.engine.create(parentID: Node.rootID, name: "new.txt", kind: .file, contents: contents,
                                        creationID: "reopened-operation", progress: Progress(totalUnitCount: -1))
        let reopened = try DestinationEngine(destination: f.engine.destination, storage: f.storage, backend: f.backend)
        let replay = try reopened.create(parentID: Node.rootID, name: "new.txt", kind: .file, contents: contents,
                                         creationID: "reopened-operation", progress: Progress(totalUnitCount: -1))
        #expect(replay.id == first.id)
        #expect(f.backend.uploads.count == 1)
        #expect(try reopened.catalogue.atPath("new.txt")?.id == first.id)
    }

    @Test func readonlyBackendExposesMetadataButRefusesRemoteMutations() throws {
        let f = try EngineFixture()
        f.backend.capabilities = []
        f.backend.addFile("/remote/snapshot.txt", text: "immutable")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("snapshot.txt"))
        let local = try f.directory.write("incoming", "must not upload")
        expectBackendError(.permission) {
            _ = try f.engine.create(parentID: Node.rootID, name: "new.txt", kind: .file, contents: local,
                                    creationID: "readonly-create", progress: Progress(totalUnitCount: -1))
        }
        expectBackendError(.permission) { _ = try f.modify(node, contents: local) }
        expectBackendError(.permission) { _ = try f.modify(node, name: "renamed.txt") }
        expectBackendError(.permission) { try f.engine.delete(id: node.id, version: node.contentVersion) }
        #expect(f.backend.uploads.isEmpty)
        #expect(f.backend.moves.isEmpty)
        #expect(f.backend.removals.isEmpty)
        #expect(f.backend.bytes["/remote/snapshot.txt"] == Data("immutable".utf8))
    }

    @Test func deletingDirectoryRemovesItsVerifiedCachedTreePostorder() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addFile("/remote/folder/child.txt", text: "keep")
        _ = try f.engine.scan()
        let folder = try #require(try f.engine.catalogue.atPath("folder"))
        let child = try #require(try f.engine.catalogue.atPath("folder/child.txt"))
        try f.engine.delete(id: folder.id, version: folder.contentVersion)
        #expect(f.backend.removals == ["/remote/folder/child.txt", "/remote/folder"])
        #expect(f.backend.bytes["/remote/folder/child.txt"] == nil)
        #expect(try f.engine.catalogue.node(child.id) == nil)
        #expect(try f.engine.catalogue.node(folder.id) == nil)
    }

    @Test func unseenRemoteDirectoryChildPreventsAnyRecursiveDeletion() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addFile("/remote/folder/cached.txt", text: "keep cached")
        _ = try f.engine.scan()
        let folder = try #require(try f.engine.catalogue.atPath("folder"))
        f.backend.addFile("/remote/folder/unseen.txt", text: "keep unseen", version: "unseen")
        expectBackendError(.conflict) { try f.engine.delete(id: folder.id, version: folder.contentVersion) }
        #expect(f.backend.removals.isEmpty)
        #expect(f.backend.bytes["/remote/folder/cached.txt"] == Data("keep cached".utf8))
        #expect(f.backend.bytes["/remote/folder/unseen.txt"] == Data("keep unseen".utf8))
        #expect(try f.engine.catalogue.node(folder.id) != nil)
    }

    @Test func changedNestedChildPreventsDeletingEarlierSiblings() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addDirectory("/remote/folder/nested")
        f.backend.addFile("/remote/folder/first.txt", text: "keep first")
        f.backend.addFile("/remote/folder/nested/last.txt", text: "base", version: "base")
        _ = try f.engine.scan()
        let folder = try #require(try f.engine.catalogue.atPath("folder"))
        f.backend.addFile("/remote/folder/nested/last.txt", text: "new remote bytes", version: "changed")
        expectBackendError(.conflict) { try f.engine.delete(id: folder.id, version: folder.contentVersion) }
        #expect(f.backend.removals.isEmpty)
        #expect(f.backend.bytes["/remote/folder/first.txt"] == Data("keep first".utf8))
        #expect(try f.engine.catalogue.node(folder.id) != nil)
    }

    @Test func descendantDisappearingDuringPreflightDoesNotDeleteTheEntireCatalogueBranch() throws {
        let f = try EngineFixture()
        f.backend.addDirectory("/remote/folder")
        f.backend.addFile("/remote/folder/vanishing.txt", text: "old")
        f.backend.addFile("/remote/folder/survivor.txt", text: "keep survivor")
        _ = try f.engine.scan()
        let folder = try #require(try f.engine.catalogue.atPath("folder"))
        let survivor = try #require(try f.engine.catalogue.atPath("folder/survivor.txt"))
        f.backend.statHook = { path in
            if path == "/remote/folder/vanishing.txt" { throw BackendError(.notFound, "Fixture concurrent remote deletion.") }
        }
        do { try f.engine.delete(id: folder.id, version: folder.contentVersion) }
        catch { /* Any safe refusal is acceptable; catalogue must survive. */ }
        #expect(try f.engine.catalogue.node(folder.id) != nil)
        #expect(try f.engine.catalogue.node(survivor.id) != nil)
        #expect(f.backend.removals.isEmpty)
        #expect(f.backend.bytes["/remote/folder/survivor.txt"] == Data("keep survivor".utf8))
    }

    @Test func combinedRenameAndContentUploadPlacesNewBytesOnlyAtTheFinalName() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/document.txt", text: "plain text")
        _ = try f.engine.scan()
        let original = try #require(try f.engine.catalogue.atPath("document.txt"))
        let replacement = try f.directory.write("replacement", "synthetic structured bytes")
        let result = try f.modify(original, name: "document.json", contents: replacement)
        #expect(result.id == original.id)
        #expect(result.path == "document.json")
        #expect(f.backend.uploads == ["/remote/document.json"])
        #expect(f.backend.bytes["/remote/document.txt"] == nil)
        #expect(f.backend.bytes["/remote/document.json"] == Data("synthetic structured bytes".utf8))
        #expect(try f.engine.catalogue.atPath("document.json")?.id == original.id)
    }

    @Test func failedCombinedRenameRetainsOriginalBytesUnderOriginalExtension() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/document.txt", text: "original plain text")
        _ = try f.engine.scan()
        let original = try #require(try f.engine.catalogue.atPath("document.txt"))
        let replacement = try f.directory.write("replacement", "synthetic new-format bytes")
        f.backend.removeFailures["/remote/document.txt"] = BackendError(.permission, "Fixture source is not removable.")
        expectBackendError(.permission) { _ = try f.modify(original, name: "document.json", contents: replacement) }
        #expect(f.backend.bytes["/remote/document.txt"] == Data("original plain text".utf8))
        #expect(f.backend.bytes["/remote/document.json"] == Data("synthetic new-format bytes".utf8))
        #expect(try Data(contentsOf: replacement) == Data("synthetic new-format bytes".utf8))
        #expect(try f.engine.catalogue.node(original.id)?.path == "document.txt")
    }

    @Test func deletionConflictDoesNotRemoveRemoteOrCachedVersion() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "old", version: "old")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("notes.txt"))
        f.backend.addFile("/remote/notes.txt", text: "changed remotely", version: "new")
        expectBackendError(.conflict) { try f.engine.delete(id: node.id, version: node.contentVersion) }
        #expect(f.backend.removals.isEmpty)
        #expect(try f.engine.catalogue.node(node.id) != nil)
    }

    @Test func metadataOnlyChangesWorkOfflineWithoutRemoteIO() throws {
        let f = try EngineFixture()
        f.backend.addFile("/remote/notes.txt", text: "bytes")
        _ = try f.engine.scan()
        let node = try #require(try f.engine.catalogue.atPath("notes.txt")), lists = f.backend.lists.count
        f.backend.offline = true
        let result = try f.engine.modify(id: node.id, version: node.contentVersion, name: nil, parentID: nil, contents: nil,
                                         tags: Data("tag".utf8), changeTags: true, favoriteRank: nil, changeFavorite: false,
                                         lastUsed: nil, changeLastUsed: false, progress: Progress(totalUnitCount: 1))
        #expect(result.tagData == Data("tag".utf8))
        #expect(result.contentVersion == node.contentVersion)
        #expect(f.backend.lists.count == lists)
        #expect(f.backend.uploads.isEmpty)
        #expect(f.backend.downloads.isEmpty)
    }
}
