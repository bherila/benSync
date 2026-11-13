import Foundation
import Testing
@testable import BenSyncCore

@Suite("Persistent offline catalogue")
struct CatalogueTests {
    private func make(_ temporary: TemporaryDirectory) throws -> Catalogue {
        try Catalogue(url: temporary.url.appendingPathComponent("catalogue.sqlite"), name: "Synthetic Files")
    }
    private func root(_ catalogue: Catalogue) throws -> Node { try #require(try catalogue.node(Node.rootID)) }

    @Test func canonicallyEquivalentRemoteNamesRemainDistinctAcrossRefreshes() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let names = ["\u{e9}.txt", "e\u{301}.txt"]
        let entries = names.map { RemoteEntry(name: $0, kind: .file) }
        try catalogue.reconcile(parent: root(catalogue), entries: entries, exclusions: Exclusions([]))
        let original = try catalogue.children(Node.rootID), anchor = try catalogue.anchor()
        #expect(original.count == 2)
        #expect(Set(original.map { Data($0.entry.name.utf8) }).count == 2)
        try catalogue.reconcile(parent: root(catalogue), entries: entries.reversed(), exclusions: Exclusions([]))
        #expect(try catalogue.children(Node.rootID) == original)
        #expect(try catalogue.anchor() == anchor)
    }

    @Test func unchangedReconciliationPreservesIdentifiersAndProducesNoJournalWrites() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let entries = [RemoteEntry(name: "notes.txt", kind: .file, size: 12, modified: 100), .init(name: "folder", kind: .directory)]
        try catalogue.reconcile(parent: root(catalogue), entries: entries, exclusions: Exclusions([]))
        let original = try catalogue.children(Node.rootID), anchor = try catalogue.anchor()
        try catalogue.reconcile(parent: root(catalogue), entries: entries.reversed(), exclusions: Exclusions([]))
        #expect(try catalogue.children(Node.rootID) == original)
        #expect(try catalogue.anchor() == anchor)
        #expect(try catalogue.changes(after: anchor, through: catalogue.anchor()).isEmpty)
    }

    @Test func reopeningPreservesMetadataPinsAndIdentifiers() throws {
        let temporary = try TemporaryDirectory()
        var first: Catalogue? = try make(temporary)
        try first!.reconcile(parent: root(first!), entries: [.init(name: "offline.txt", kind: .file, size: 7, modified: 100)], exclusions: Exclusions([]))
        let node = try #require(try first!.atPath("offline.txt"))
        try first!.pin([node.id], value: true)
        let anchor = try first!.anchor()
        first = nil
        let reopened = try make(temporary)
        let restored = try #require(try reopened.atPath("offline.txt"))
        #expect(restored.id == node.id)
        #expect(restored.offlinePolicy == .keep)
        #expect(restored.contentVersion == node.contentVersion)
        #expect(try reopened.anchor() == anchor)
    }

    @Test func pinTagsAndRenameChangeMetadataWithoutInvalidatingContent() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        var node = Node(parentID: Node.rootID, path: "document.txt", entry: .init(name: "document.txt", kind: .file, size: 5, modified: 100))
        try catalogue.transaction { try catalogue.put(node) }
        let bytesVersion = node.contentVersion, metadataVersion = node.metadataVersion
        try catalogue.pin([node.id], value: true)
        node = try #require(try catalogue.node(node.id))
        #expect(node.metadataVersion != metadataVersion)
        #expect(node.contentVersion == bytesVersion)
        node.tagData = Data("synthetic-tag".utf8)
        try catalogue.transaction { try catalogue.put(node) }
        let renamed = try catalogue.transaction { try catalogue.moveTree(node.id, to: "renamed.txt", parentID: Node.rootID, name: "renamed.txt") }
        #expect(renamed.contentVersion == bytesVersion)
        #expect(renamed.tagData == Data("synthetic-tag".utf8))
        try catalogue.pin([node.id], value: false)
        #expect(try catalogue.node(node.id)?.offlinePolicy == .onDemand)
    }

    @Test func malformedDirectoryListingRollsBackAllRowsAndTombstones() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        try catalogue.reconcile(parent: root(catalogue), entries: [.init(name: "existing", kind: .file)], exclusions: Exclusions([]))
        let before = try catalogue.children(Node.rootID), anchor = try catalogue.anchor()
        expectBackendError(.invalid) {
            try catalogue.reconcile(parent: root(catalogue), entries: [.init(name: "new", kind: .file), .init(name: "../escape", kind: .file)], exclusions: Exclusions([]))
        }
        #expect(try catalogue.children(Node.rootID) == before)
        #expect(try catalogue.anchor() == anchor)
    }

    @Test func addingAnExclusionRemovesOnlyTheCachedSubtree() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let initial = [RemoteEntry(name: "node_modules", kind: .directory), .init(name: "src", kind: .directory)]
        try catalogue.reconcile(parent: root(catalogue), entries: initial, exclusions: Exclusions([]))
        let excluded = try #require(try catalogue.atPath("node_modules"))
        try catalogue.reconcile(parent: excluded, entries: [.init(name: "package.js", kind: .file)], exclusions: Exclusions([]))
        let child = try #require(try catalogue.atPath("node_modules/package.js")), before = try catalogue.anchor()
        try catalogue.reconcile(parent: root(catalogue), entries: initial, exclusions: Exclusions(["node_modules"]))
        #expect(try catalogue.atPath("node_modules") == nil)
        #expect(try catalogue.node(child.id) == nil)
        #expect(try catalogue.atPath("src") != nil)
        let deleted = try catalogue.changes(after: before, through: catalogue.anchor()).filter(\.deleted)
        #expect(Set(deleted.map(\.id)) == [excluded.id, child.id])
    }

    @Test func movingAndRemovingSubtreesRetainsStableIDsAndJournalsEveryDeletion() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let folder = Node(parentID: Node.rootID, path: "old", entry: .init(name: "old", kind: .directory))
        let nested = Node(parentID: folder.id, path: "old/nested", entry: .init(name: "nested", kind: .directory))
        let child = Node(parentID: nested.id, path: "old/nested/file.txt", entry: .init(name: "file.txt", kind: .file))
        try catalogue.transaction { try catalogue.put(folder); try catalogue.put(nested); try catalogue.put(child) }
        try catalogue.transaction { try catalogue.moveTree(folder.id, to: "new", parentID: Node.rootID, name: "new") }
        #expect(try catalogue.atPath("new/nested/file.txt")?.id == child.id)
        #expect(try catalogue.atPath("old/nested/file.txt") == nil)
        let anchor = try catalogue.anchor()
        try catalogue.transaction { try catalogue.removeTree(folder.id) }
        #expect(try catalogue.count() == 0)
        #expect(Set(try catalogue.changes(after: anchor, through: catalogue.anchor()).filter(\.deleted).map(\.id)) == [folder.id, nested.id, child.id])
    }

    @Test func movingUnicodeSubtreeUpdatesAllDescendantPaths() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let folder = Node(parentID: Node.rootID, path: "👩🏽‍💻", entry: .init(name: "👩🏽‍💻", kind: .directory))
        let child = Node(parentID: folder.id, path: "👩🏽‍💻/notes.txt", entry: .init(name: "notes.txt", kind: .file))
        try catalogue.transaction { try catalogue.put(folder); try catalogue.put(child) }
        try catalogue.transaction { try catalogue.moveTree(folder.id, to: "renamed", parentID: Node.rootID, name: "renamed") }
        #expect(try catalogue.node(child.id)?.path == "renamed/notes.txt")
        #expect(try catalogue.atPath("renamed/notes.txt")?.id == child.id)
    }

    @Test func typeReplacementGetsNewIdentifierAndRemovesOldDescendants() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        try catalogue.reconcile(parent: root(catalogue), entries: [.init(name: "item", kind: .directory)], exclusions: Exclusions([]))
        let old = try #require(try catalogue.atPath("item"))
        try catalogue.reconcile(parent: old, entries: [.init(name: "child", kind: .file)], exclusions: Exclusions([]))
        try catalogue.reconcile(parent: root(catalogue), entries: [.init(name: "item", kind: .file)], exclusions: Exclusions([]))
        #expect(try catalogue.atPath("item")?.id != old.id)
        #expect(try catalogue.atPath("item/child") == nil)
        #expect(try catalogue.count() == 1)
    }

    @Test func keysetPaginationCoversEveryItemExactlyOnce() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        try catalogue.reconcile(parent: root(catalogue), entries: (0..<531).map { .init(name: "file-\($0)", kind: .file) }, exclusions: Exclusions([]))
        var after = "", collected = [String]()
        while true {
            let page = try catalogue.page(parent: Node.rootID, after: after)
            collected.append(contentsOf: page.map(\.id))
            guard let last = page.last else { break }; after = last.id
        }
        #expect(collected.count == 531)
        #expect(Set(collected).count == 531)
        #expect(collected == collected.sorted())
    }

    @Test func pinBatchIsAtomicWhenOneIdentifierIsMissing() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let node = Node(parentID: Node.rootID, path: "notes", entry: .init(name: "notes", kind: .file))
        try catalogue.transaction { try catalogue.put(node) }
        let anchor = try catalogue.anchor()
        expectBackendError(.notFound) { try catalogue.pin([node.id, "missing"], value: true) }
        #expect(try catalogue.node(node.id)?.pinned == false)
        #expect(try catalogue.anchor() == anchor)
    }

    @Test func journalCompactionRetainsUnacknowledgedChangesAndAllNodeMetadata() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        try catalogue.reconcile(parent: root(catalogue), entries: (0..<6500).map { .init(name: "file-\($0)", kind: .file) }, exclusions: Exclusions([]))
        let before = try catalogue.anchor(), acknowledged = before - 750
        let unacknowledged = try catalogue.changes(after: acknowledged, through: before, limit: 1000)
        try catalogue.acknowledge(through: acknowledged)
        #expect(try catalogue.anchor() == before)
        #expect(try catalogue.count() == 6500)
        let remaining = try catalogue.changes(after: acknowledged, through: before, limit: 1000)
        #expect(remaining.map(\.sequence) == unacknowledged.map(\.sequence))
        #expect(remaining.map(\.id) == unacknowledged.map(\.id))
        #expect(remaining.count == 750)
        let floor = acknowledged - 1000
        try catalogue.validateAnchor(floor)
        try catalogue.validateAnchor(acknowledged)
        try catalogue.validateAnchor(before)
        expectBackendError(.invalid) { try catalogue.validateAnchor(floor - 1) }
        #expect(try catalogue.changes(after: floor, through: before, limit: 10_000).count == 1750)
    }

    @Test func prunedCatalogueReopensWithAMonotonicAnchorAndContinuesJournaling() throws {
        let temporary = try TemporaryDirectory()
        var catalogue: Catalogue? = try make(temporary)
        try catalogue!.reconcile(parent: root(catalogue!), entries: (0..<5100).map { .init(name: "file-\($0)", kind: .file) }, exclusions: Exclusions([]))
        let before = try catalogue!.anchor()
        try catalogue!.acknowledge(through: before)
        catalogue = nil
        let reopened = try make(temporary)
        #expect(try reopened.anchor() == before)
        expectBackendError(.invalid) { try reopened.validateAnchor(0) }
        let new = Node(parentID: Node.rootID, path: "after-restart", entry: .init(name: "after-restart", kind: .file))
        try reopened.transaction { try reopened.put(new) }
        #expect(try reopened.anchor() == before + 1)
        #expect(try reopened.changes(after: before, through: reopened.anchor()).map(\.id) == [new.id])
    }

    @Test func smallAcknowledgementsLeaveOldAnchorsUsable() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        try catalogue.reconcile(parent: root(catalogue), entries: (0..<100).map { .init(name: "file-\($0)", kind: .file) }, exclusions: Exclusions([]))
        let anchor = try catalogue.anchor()
        try catalogue.acknowledge(through: anchor)
        try catalogue.validateAnchor(0)
        #expect(try catalogue.changes(after: 0, through: anchor, limit: 1000).count == Int(anchor))
        #expect(try catalogue.anchor() == anchor)
    }

    @Test func malformedOrFutureAnchorsAndAcknowledgementsCannotDiscardChanges() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let anchor = try catalogue.anchor()
        expectBackendError(.invalid) { try catalogue.validateAnchor(-1) }
        expectBackendError(.invalid) { try catalogue.validateAnchor(anchor + 1) }
        expectBackendError(.invalid) { try catalogue.acknowledge(through: -1) }
        expectBackendError(.invalid) { try catalogue.acknowledge(through: anchor + 1) }
        #expect(try catalogue.anchor() == anchor)
        try catalogue.validateAnchor(0)
    }

    @Test func moveNotifiesBothParentsWithoutDeletingTheStableWorkingSetIdentifier() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let source = Node(parentID: Node.rootID, path: "source", entry: .init(name: "source", kind: .directory))
        let target = Node(parentID: Node.rootID, path: "target", entry: .init(name: "target", kind: .directory))
        let unrelated = Node(parentID: Node.rootID, path: "unrelated", entry: .init(name: "unrelated", kind: .directory))
        let item = Node(parentID: source.id, path: "source/notes.txt", entry: .init(name: "notes.txt", kind: .file))
        try catalogue.transaction {
            try catalogue.put(source); try catalogue.put(target); try catalogue.put(unrelated); try catalogue.put(item)
        }
        let before = try catalogue.anchor()
        try catalogue.transaction { try catalogue.moveTree(item.id, to: "target/notes.txt", parentID: target.id, name: "notes.txt") }
        let changes = try catalogue.changes(after: before, through: catalogue.anchor())
        let oldParent = try catalogue.resolveChanges(changes, inContainer: source.id)
        #expect(oldParent.updated.isEmpty)
        #expect(oldParent.deleted == [item.id])
        let newParent = try catalogue.resolveChanges(changes, inContainer: target.id)
        #expect(newParent.updated.map(\.id) == [item.id])
        #expect(newParent.updated.first?.path == "target/notes.txt")
        #expect(newParent.deleted.isEmpty)
        let workingSet = try catalogue.resolveChanges(changes, inContainer: nil)
        #expect(workingSet.updated.map(\.id) == [item.id])
        #expect(workingSet.deleted.isEmpty)
        let outOfScope = try catalogue.resolveChanges(changes, inContainer: unrelated.id)
        #expect(outOfScope.updated.isEmpty)
        #expect(outOfScope.deleted.isEmpty)
    }

    @Test func metadataAndContentChangesStayWithinTheirContainingFolder() throws {
        let temporary = try TemporaryDirectory(), catalogue = try make(temporary)
        let first = Node(parentID: Node.rootID, path: "first", entry: .init(name: "first", kind: .directory))
        let second = Node(parentID: Node.rootID, path: "second", entry: .init(name: "second", kind: .directory))
        let tagged = Node(parentID: first.id, path: "first/tagged.txt", entry: .init(name: "tagged.txt", kind: .file))
        var edited = Node(parentID: second.id, path: "second/edited.txt", entry: .init(name: "edited.txt", kind: .file, version: "old"))
        try catalogue.transaction { try catalogue.put(first); try catalogue.put(second); try catalogue.put(tagged); try catalogue.put(edited) }
        let before = try catalogue.anchor()
        try catalogue.pin([tagged.id], value: true)
        edited.entry.version = "new-content-version"
        try catalogue.transaction { try catalogue.put(edited) }
        let changes = try catalogue.changes(after: before, through: catalogue.anchor())
        let firstChildren = try catalogue.resolveChanges(changes, inContainer: first.id)
        #expect(firstChildren.updated.map(\.id) == [tagged.id])
        #expect(firstChildren.deleted.isEmpty)
        let secondChildren = try catalogue.resolveChanges(changes, inContainer: second.id)
        #expect(secondChildren.updated.map(\.id) == [edited.id])
        #expect(secondChildren.deleted.isEmpty)
        let rootChildren = try catalogue.resolveChanges(changes, inContainer: Node.rootID)
        #expect(rootChildren.updated.isEmpty)
        #expect(rootChildren.deleted.isEmpty)
        let outOfScope = try catalogue.resolveChanges(changes, inContainer: "unrelated-container")
        #expect(outOfScope.updated.isEmpty)
        #expect(outOfScope.deleted.isEmpty)
        let global = try catalogue.resolveChanges(changes, inContainer: nil)
        #expect(Set(global.updated.map(\.id)) == [tagged.id, edited.id])
        #expect(global.deleted.isEmpty)
    }
}
