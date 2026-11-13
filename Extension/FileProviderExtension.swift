import FileProvider
import Foundation
import BenSyncCore

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    private let domain: NSFileProviderDomain
    private let broker = BrokerClient()
    private let queue = DispatchQueue(label: "provider.local", qos: .userInitiated)
    private let stateLock = NSLock()
    private var refreshing = false
    private var nextRefresh = Date.distantPast
    private var stopped = false
    private var storage: Storage?
    private var catalogue: Catalogue?
    private var setupError: Error?
    private var destination: Destination?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        do {
            let store = try AppEnvironment.storage()
            guard let id = UUID(uuidString: domain.identifier.rawValue) else { throw BackendError(.invalid, "Invalid destination identifier.") }
            let destination = try store.destination(id)
            self.storage = store; self.catalogue = try store.catalogue(destination); self.destination = destination
        } catch { setupError = error }
        // Prevent background indexers from downloading the entire working
        // set. User-initiated opens and Quick Look continue to hydrate normally.
        UserDefaults.standard.register(defaults: ["NSFileProviderExtensionNonMaterializingProcessNames": ["mdworker", "mdworker_shared", "mds", "mds_stores"]])
    }
    func invalidate() { stateLock.lock(); stopped = true; stateLock.unlock() }
    private func local() throws -> (Storage, Catalogue, Destination) {
        if let setupError { throw setupError }
        guard let storage, let catalogue, let destination else { throw BackendError(.internalError, "The destination is not configured.") }
        // The extension can outlive edits made in the containing app.
        // Refresh policy before applying exclusions or scheduling network work.
        return (storage, catalogue, try storage.destination(destination.id))
    }
    private func signal() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
    private func providerItem(_ node: Node) -> ProviderItem {
        ProviderItem(node, capabilities: destination?.backend.capabilities ?? [])
    }
    private func refreshIfNeeded() {
        guard let (_, _, destination) = try? local(), !destination.paused else { return }
        stateLock.lock()
        guard !stopped, !refreshing, Date() >= nextRefresh else { stateLock.unlock(); return }
        refreshing = true; nextRefresh = Date().addingTimeInterval(destination.refreshInterval); stateLock.unlock()
        broker.perform(BrokerRequest(.scan, destinationID: destination.id)) { [weak self] result in
            guard let self else { return }
            self.stateLock.lock(); self.refreshing = false
            if case .failure = result { self.nextRefresh = Date().addingTimeInterval(60) }
            self.stateLock.unlock()
            // A cancelled/failed crawl may already have committed earlier
            // directories. Signal even on failure so those journal entries
            // cannot be stranded behind an unchanged subsequent scan.
            self.signal()
        }
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let (_, catalogue, destination) = try local()
        if containerItemIdentifier == .trashContainer { throw CocoaError(.featureUnsupported) }
        return ProviderEnumerator(catalogue: catalogue, container: containerItemIdentifier, capabilities: destination.backend.capabilities, refresh: { [weak self] in self?.refreshIfNeeded() })
    }
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        queue.async { [self] in
            do {
                let (_, catalogue, _) = try local()
                if progress.isCancelled { throw BackendError(.cancelled, "Lookup cancelled.") }
                guard let node = try catalogue.node(catalogueID(identifier)) else { throw BackendError(.notFound, "Item not found.") }
                completionHandler(providerItem(node), nil); progress.completedUnitCount = 1
            } catch { completionHandler(nil, providerError(error)) }
        }
        return progress
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        do {
            let (storage, _, destination) = try local()
            var message = BrokerRequest(.download, destinationID: destination.id); message.itemID = catalogueID(itemIdentifier)
            broker.perform(message, progress: progress) { [self] result in
                do {
                    let response = try result.get()
                    guard let token = response.token, let node = response.node, let manager = NSFileProviderManager(for: domain) else { throw BackendError(.internalError, "Missing download result.") }
                    let source = try storage.transferURL(token)
                    defer { try? FileManager.default.removeItem(at: source) }
                    if progress.isCancelled { throw BackendError(.cancelled, "Download cancelled.") }
                    let target = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                    try FileManager.default.moveItem(at: source, to: target)
                    completionHandler(target, providerItem(node), nil)
                } catch { completionHandler(nil, nil, providerError(error)) }
            }
        } catch { completionHandler(nil, nil, providerError(error)) }
        return progress
    }
    private func stage(_ contents: URL?, storage: Storage) throws -> String? {
        guard let contents else { return nil }
        let token = UUID().uuidString, target = try storage.transferURL(token)
        // copyfile's clone path avoids duplicating large uploads on APFS.
        let access = contents.startAccessingSecurityScopedResource(); defer { if access { contents.stopAccessingSecurityScopedResource() } }
        if copyfile(contents.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return token
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents: URL?,
                    options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        queue.async { [self] in
            do {
                let (storage, _, destination) = try local()
                var message = BrokerRequest(.create, destinationID: destination.id)
                message.parentID = catalogueID(itemTemplate.parentItemIdentifier); message.name = itemTemplate.filename
                guard itemTemplate.contentType != .symbolicLink else { throw BackendError(.unsupported, "Symbolic links are excluded from syncing.") }
                message.kind = itemTemplate.contentType == .folder ? .directory : .file
                let relativeParent = try catalogue?.node(message.parentID!)?.path ?? ""
                if Exclusions(destination.exclusions).excludes(RemotePath.append(relativeParent, itemTemplate.filename), kind: message.kind!) {
                    throw NSFileProviderError(.excludedFromSync)
                }
                message.creationID = itemTemplate.itemIdentifier.rawValue
                message.token = try stage(contents, storage: storage)
                broker.perform(message, progress: progress) { [self] result in
                    do { let response = try result.get(); guard let node = response.node else { throw BackendError(.internalError, "Missing created item.") }; signal(); completionHandler(providerItem(node), [], false, nil) }
                    catch { signal(); completionHandler(nil, [], false, error is NSFileProviderError ? error : providerError(error)) }
                }
            } catch { completionHandler(nil, [], false, error is NSFileProviderError ? error : providerError(error)) }
        }
        return progress
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        queue.async { [self] in
            do {
                let (storage, _, destination) = try local()
                var message = BrokerRequest(.modify, destinationID: destination.id)
                message.itemID = catalogueID(item.itemIdentifier); message.version = version.contentVersion
                if changedFields.contains(.filename) { message.name = item.filename }
                if changedFields.contains(.parentItemIdentifier) { message.parentID = catalogueID(item.parentItemIdentifier) }
                if changedFields.contains(.contents) { message.token = try stage(newContents, storage: storage) }
                message.changeTags = changedFields.contains(.tagData); message.tags = item.tagData ?? nil
                message.changeLastUsed = changedFields.contains(.lastUsedDate); message.lastUsed = item.lastUsedDate ?? nil
                broker.perform(message, progress: progress) { [self] result in
                    do { let response = try result.get(); guard let node = response.node else { throw BackendError(.internalError, "Missing modified item.") }; signal(); completionHandler(providerItem(node), [], false, nil) }
                    catch { signal(); completionHandler(nil, [], false, providerError(error)) }
                }
            } catch { completionHandler(nil, [], false, providerError(error)) }
        }
        return progress
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let (_, _, destination) = try local()
            var message = BrokerRequest(.delete, destinationID: destination.id)
            message.itemID = catalogueID(identifier); message.version = version.contentVersion
            broker.perform(message, progress: progress) { [self] result in
                signal()
                switch result { case .success: progress.completedUnitCount = 1; completionHandler(nil)
                case .failure(let error): completionHandler(providerError(error)) }
            }
        } catch { completionHandler(providerError(error)) }
        return progress
    }
    func performAction(identifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers ids: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        queue.async { [self] in
            do {
                let (_, catalogue, _) = try local()
                let pin: Bool
                switch identifier.rawValue { case "keep-offline": pin = true; case "use-on-demand", "free-space": pin = false
                default: throw BackendError(.unsupported, "Unknown Finder action.") }
                try catalogue.pin(ids.map(catalogueID), value: pin)
                signal()
                if identifier.rawValue == "free-space", let manager = NSFileProviderManager(for: domain) {
                    Task {
                        do {
                            try await manager.signalEnumerator(for: .workingSet)
                            for id in ids {
                                // Policy ingestion is asynchronous. Retry only
                                // that race; unsynced edits and pinned children
                                // fail immediately, including while offline.
                                for attempt in 0..<15 {
                                    if progress.isCancelled { throw BackendError(.cancelled, "Eviction cancelled.") }
                                    do { try await manager.evictItem(identifier: id); break }
                                    catch {
                                        let error = error as NSError
                                        guard error.domain == NSFileProviderErrorDomain,
                                              error.code == NSFileProviderError.nonEvictable.rawValue,
                                              attempt < 14 else { throw error }
                                        try await Task.sleep(for: .milliseconds(200))
                                    }
                                }
                            }
                            progress.completedUnitCount = 1; completionHandler(nil)
                        } catch { completionHandler(error) }
                    }
                } else { progress.completedUnitCount = 1; completionHandler(nil) }
            } catch { completionHandler(providerError(error)) }
        }
        return progress
    }
}
