import FileProvider
import UniformTypeIdentifiers
import BenSyncCore

func providerID(_ value: String) -> NSFileProviderItemIdentifier { value == Node.rootID ? .rootContainer : .init(value) }
func catalogueID(_ value: NSFileProviderItemIdentifier) -> String { value == .rootContainer ? Node.rootID : value.rawValue }

final class ProviderItem: NSObject, NSFileProviderItem {
    let node: Node
    private let backendCapabilities: BackendCapabilities
    init(_ node: Node, capabilities: BackendCapabilities) { self.node = node; backendCapabilities = capabilities }
    var itemIdentifier: NSFileProviderItemIdentifier { providerID(node.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { providerID(node.parentID) }
    var filename: String { node.entry.name }
    var contentType: UTType {
        node.entry.kind == .directory ? .folder : (UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data)
    }
    var documentSize: NSNumber? { node.entry.kind == .file ? NSNumber(value: node.entry.size) : nil }
    var contentModificationDate: Date? { Date(timeIntervalSince1970: TimeInterval(node.entry.modified)) }
    var itemVersion: NSFileProviderItemVersion { .init(contentVersion: node.contentVersion, metadataVersion: node.metadataVersion) }
    // Catalogue entries describe committed remote state. Local pending edits
    // remain owned and protected by File Provider until our callback succeeds.
    var isUploaded: Bool { true }
    var tagData: Data? { node.tagData }
    var lastUsedDate: Date? { node.lastUsed }
    var capabilities: NSFileProviderItemCapabilities {
        var result: NSFileProviderItemCapabilities = [.allowsReading]
        if node.id != Node.rootID {
            if backendCapabilities.contains(.move) { result.formUnion([.allowsRenaming, .allowsReparenting]) }
            if backendCapabilities.contains(.delete) { result.insert(.allowsDeleting) }
        }
        if backendCapabilities.contains(.write), node.entry.permissions & 0o222 != 0 {
            result.insert(node.entry.kind == .directory ? .allowsAddingSubItems : .allowsWriting)
        }
        return result
    }
    var contentPolicy: NSFileProviderContentPolicy {
        switch node.offlinePolicy {
        case .keep: return .downloadEagerlyAndKeepDownloaded
        case .onDemand: return .downloadLazily
        case .inherited: return node.id == Node.rootID ? .downloadLazily : .inherited
        }
    }
    @available(macOS 27.0, *)
    var namespacePolicy: NSFileProviderNamespacePolicy {
        // Cache the namespace independently of downloading file contents.
        node.id == Node.rootID ? .materializeEagerly : .inherited
    }
}

func providerError(_ error: Error) -> NSError {
    guard let error = error as? BackendError else {
        return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
                       userInfo: [NSLocalizedDescriptionKey: error.localizedDescription, NSUnderlyingErrorKey: error])
    }
    let code: NSFileProviderError.Code
    switch error.kind {
    case .offline: code = .serverUnreachable
    case .notFound: code = .noSuchItem
    case .collision: code = .filenameCollision
    case .conflict: code = .localVersionConflictingWithServer
    case .permission: return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSLocalizedDescriptionKey: error.message])
    case .cancelled: return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: error.message])
    case .unsupported, .invalid, .internalError:
        return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: error.message])
    }
    return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: error.message])
}
