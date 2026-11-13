import FileProvider
import BenSyncCore

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let catalogue: Catalogue
    private let container: NSFileProviderItemIdentifier
    private let queue = DispatchQueue(label: "provider.enumeration", qos: .userInitiated)
    private let refresh: () -> Void
    private let capabilities: BackendCapabilities
    private var invalidated = false
    private let lock = NSLock()
    private struct Page: Codable { var after: String; var anchor: Int64 }

    init(catalogue: Catalogue, container: NSFileProviderItemIdentifier, capabilities: BackendCapabilities, refresh: @escaping () -> Void) {
        self.catalogue = catalogue; self.container = container; self.capabilities = capabilities; self.refresh = refresh
    }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    private func check() throws {
        lock.lock(); defer { lock.unlock() }
        if invalidated { throw BackendError(.cancelled, "Enumeration cancelled.") }
    }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        queue.async { [self] in
            do {
                try check()
                let cursor: Page
                if page.rawValue == NSFileProviderPage.initialPageSortedByName as Data || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data {
                    cursor = Page(after: "", anchor: try catalogue.anchor())
                } else { cursor = try JSONDecoder().decode(Page.self, from: page.rawValue) }
                guard cursor.anchor == (try catalogue.anchor()) else { throw NSFileProviderError(.pageExpired) }
                let parent = container == .workingSet ? nil : catalogueID(container)
                let nodes = try catalogue.page(parent: parent, after: cursor.after)
                observer.didEnumerate(nodes.map { ProviderItem($0, capabilities: capabilities) })
                if nodes.count == 250, let last = nodes.last {
                    observer.finishEnumerating(upTo: NSFileProviderPage(try JSONEncoder().encode(Page(after: last.id, anchor: cursor.anchor))))
                } else { observer.finishEnumerating(upTo: nil) }
                refresh()
            } catch { observer.finishEnumeratingWithError(error is NSFileProviderError ? error : providerError(error)) }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        queue.async { [self] in
            do { completionHandler(NSFileProviderSyncAnchor(Data(String(try catalogue.anchor()).utf8))) }
            catch { completionHandler(nil) }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        queue.async { [self] in
            do {
                try check()
                guard let text = String(data: anchor.rawValue, encoding: .utf8), let from = Int64(text), from >= 0 else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let end = try catalogue.anchor()
                guard from <= end else { throw NSFileProviderError(.syncAnchorExpired) }
                do {
                    try catalogue.validateAnchor(from)
                    if container == .workingSet { try catalogue.acknowledge(through: from) }
                } catch { throw NSFileProviderError(.syncAnchorExpired) }
                let changes = try catalogue.changes(after: from, through: end)
                // Coalesce only inside this page. Resolve the latest item
                // state so delete/recreate sequences cannot resurrect an ID.
                let resolved = try catalogue.resolveChanges(changes, inContainer: container == .workingSet ? nil : catalogueID(container))
                let updates = resolved.updated.map { ProviderItem($0, capabilities: capabilities) }
                let deletes = resolved.deleted.map(providerID)
                if !updates.isEmpty { observer.didUpdate(updates) }
                if !deletes.isEmpty { observer.didDeleteItems(withIdentifiers: deletes) }
                let next = changes.last?.sequence ?? end
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(String(next).utf8)), moreComing: next < end)
                refresh()
            } catch { observer.finishEnumeratingWithError(error is NSFileProviderError ? error : providerError(error)) }
        }
    }
}
