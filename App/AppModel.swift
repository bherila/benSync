import AppKit
import FileProvider
import BenSyncCore
import Network
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    struct Status: Sendable {
        var text = "Waiting to refresh"
        var symbol = "clock"
        var syncing = false
        var count: Int?
        var detail: String?
        var nextRefresh = Date.distantPast
        var failures = 0
    }
    private struct Scan {
        var token: UUID
        var progress: Progress
    }
    private struct RefreshIntent {
        var allowInteraction: Bool
        var force: Bool
    }

    @Published var destinations = [Destination]()
    @Published var statuses = [UUID: Status]()
    @Published var transfers = [UUID: NativeSyncProgress]()
    @Published var error: String?
    @Published private(set) var networkAvailable = true
    @Published private(set) var exportingDiagnostics = false
    @Published private(set) var removing = Set<UUID>()
    @Published private(set) var saving = Set<UUID>()
    private let broker = BrokerClient()
    private let networkMonitor = NWPathMonitor()
    private var pollTask: Task<Void, Never>?
    private var editor: NSWindow?
    private var preferences: NSWindow?
    private var activeScans = [UUID: Scan]()
    private var pendingRefreshes = [UUID: RefreshIntent]()
    private var loadGeneration = UUID()

    init() {
        AppPreferences.registerDefaults()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.networkChanged(available: path.status == .satisfied) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "bensync.network", qos: .utility))
        Task { await load() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                guard networkAvailable else { continue }
                for destination in destinations where !destination.paused && (statuses[destination.id]?.nextRefresh ?? .distantPast) <= Date() {
                    refresh(destination, force: false)
                }
            }
        }
    }
    deinit { pollTask?.cancel(); networkMonitor.cancel() }

    private func domain(_ destination: Destination) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: .init(destination.id.uuidString), displayName: destination.name)
    }
    private func observeTransfers(_ destination: Destination) {
        if transfers[destination.id] == nil, let manager = NSFileProviderManager(for: domain(destination)) {
            transfers[destination.id] = NativeSyncProgress(manager: manager)
        }
    }
    private func current(_ id: UUID) -> Destination? { destinations.first { $0.id == id } }

    func load() async {
        guard saving.isEmpty, removing.isEmpty else { return }
        let generation = UUID(); loadGeneration = generation
        activeScans.values.forEach { $0.progress.cancel() }
        activeScans.removeAll(); pendingRefreshes.removeAll()
        do {
            let loaded = try await Task.detached(priority: .utility) {
                let storage = try AppEnvironment.storage(), destinations = try storage.destinations()
                var statuses = [UUID: Status]()
                for destination in destinations {
                    let catalogue = try storage.catalogue(destination)
                    var status = Status(); status.count = try catalogue.count()
                    if let last = try catalogue.state("lastScan"), let seconds = Double(last) {
                        status.text = "Catalogue cached · " + Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
                        status.symbol = "checkmark.circle"
                    }
                    statuses[destination.id] = status
                }
                return (destinations, statuses)
            }.value
            guard loadGeneration == generation else { return }
            destinations = loaded.0; statuses = loaded.1; error = nil
            let ids = Set(destinations.map(\.id))
            transfers = transfers.filter { ids.contains($0.key) }
            let registered = try await NSFileProviderManager.domains()
            guard loadGeneration == generation else { return }
            for destination in destinations {
                if !registered.contains(where: { $0.identifier.rawValue == destination.id.uuidString }) {
                    do { try await NSFileProviderManager.add(domain(destination)) }
                    catch {
                        guard loadGeneration == generation else { return }
                        statuses[destination.id]?.text = "Finder setup needed"
                        statuses[destination.id]?.symbol = "exclamationmark.triangle"
                        statuses[destination.id]?.detail = error.localizedDescription
                        self.error = error.localizedDescription
                        continue
                    }
                }
                guard loadGeneration == generation else { return }
                observeTransfers(destination)
                NSFileProviderManager(for: domain(destination))?.signalEnumerator(for: .workingSet) { _ in }
                if destination.paused { setPausedStatus(destination.id) }
                else { refresh(destination, force: false) }
            }
        } catch { if loadGeneration == generation { self.error = error.localizedDescription } }
    }

    func refresh(_ destination: Destination, allowInteraction: Bool = false, force: Bool = true) {
        guard let destination = current(destination.id), !removing.contains(destination.id), !saving.contains(destination.id) else { return }
        guard !destination.paused else { setPausedStatus(destination.id); return }
        guard networkAvailable else { setOfflineStatus(destination.id); return }
        if activeScans[destination.id] != nil {
            // A scheduled tick must not enqueue another complete scan behind
            // one already running. Explicit refresh/authentication can coalesce.
            guard force || allowInteraction else { return }
            let previous = pendingRefreshes[destination.id]
            pendingRefreshes[destination.id] = RefreshIntent(allowInteraction: allowInteraction || previous?.allowInteraction == true,
                                                           force: force || previous?.force == true)
            return
        }
        let token = UUID(), progress = Progress(totalUnitCount: -1)
        activeScans[destination.id] = Scan(token: token, progress: progress)
        var status = statuses[destination.id] ?? Status()
        status.syncing = true; status.text = allowInteraction ? "Connecting…" : "Refreshing catalogue…"
        status.symbol = "arrow.triangle.2.circlepath"; status.detail = nil
        statuses[destination.id] = status
        var request = BrokerRequest(.scan, destinationID: destination.id)
        request.allowInteraction = allowInteraction; request.forceRefresh = force
        broker.perform(request, progress: progress) { [weak self] result in
            Task { @MainActor [weak self] in self?.completeRefresh(destination.id, token: token, result: result) }
        }
    }

    private func completeRefresh(_ id: UUID, token: UUID, result: Result<BrokerResponse, Error>) {
        // Superseded/cancelled callbacks still may represent committed remote
        // directory reads; publish the journal before applying UI generation
        // checks. This is a local operation, including while offline.
        if let destination = current(id) {
            NSFileProviderManager(for: domain(destination))?.signalEnumerator(for: .workingSet) { _ in }
        }
        guard activeScans[id]?.token == token else { return }
        activeScans[id] = nil
        guard let destination = current(id), !removing.contains(id) else { pendingRefreshes[id] = nil; return }
        guard !destination.paused else { pendingRefreshes[id] = nil; setPausedStatus(id); return }
        var status = statuses[id] ?? Status(); status.syncing = false
        let validated: Result<BrokerResponse, Error> = result.flatMap { response in
            guard response.scan != nil else { return .failure(BackendError(.internalError, "The background service returned no catalogue result. Retry the refresh.")) }
            return .success(response)
        }
        switch validated {
        case .success(let response):
            status.failures = 0; status.count = response.scan?.itemCount
            status.nextRefresh = Date().addingTimeInterval(destination.refreshInterval)
            if response.scan?.complete == false {
                status.text = "Some folders need attention"; status.symbol = "exclamationmark.triangle"
                status.detail = response.scan?.warnings.prefix(3).joined(separator: "\n")
            } else {
                let date = response.scan?.date ?? Date()
                status.text = "Catalogue current · " + date.formatted(date: .omitted, time: .shortened)
                status.symbol = "checkmark.circle"; status.detail = nil
            }
            statuses[id] = status
            if let manager = NSFileProviderManager(for: domain(destination)) {
                Task { [weak self] in
                    do {
                        try await manager.signalErrorResolved(NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue))
                    } catch {
                        guard let self, self.current(id) != nil else { return }
                        self.error = "Finder needs attention: " + error.localizedDescription
                    }
                }
            }
        case .failure(let failure):
            if let problem = failure as? BackendError, problem.kind == .cancelled {
                status.text = "Refresh cancelled"; status.symbol = "pause.circle"; status.detail = nil
                status.nextRefresh = Date().addingTimeInterval(destination.refreshInterval)
            } else {
                status.failures += 1
                status.text = "Connection needs attention"; status.symbol = "exclamationmark.triangle"
                status.detail = failure.localizedDescription
                status.nextRefresh = Date().addingTimeInterval(RetryPolicy.delay(failures: status.failures))
                if let problem = failure as? BackendError, problem.kind == .offline {
                    status.text = "Offline · catalogue available"; status.symbol = "wifi.slash"
                }
            }
            statuses[id] = status
        }
        if let next = pendingRefreshes.removeValue(forKey: id) {
            refresh(destination, allowInteraction: next.allowInteraction, force: next.force)
        }
    }

    func cancelRefresh(_ destination: Destination) {
        pendingRefreshes[destination.id] = nil
        let scan = activeScans.removeValue(forKey: destination.id)
        scan?.progress.cancel()
        guard current(destination.id) != nil else { return }
        statuses[destination.id]?.syncing = false
        statuses[destination.id]?.text = "Refresh cancelled"
        statuses[destination.id]?.symbol = "pause.circle"
        statuses[destination.id]?.detail = nil
        statuses[destination.id]?.nextRefresh = Date().addingTimeInterval(destination.refreshInterval)
    }
    private func setPausedStatus(_ id: UUID) {
        var status = statuses[id] ?? Status()
        status.syncing = false; status.text = "Paused · offline files available"; status.symbol = "pause.circle"
        status.detail = nil; status.nextRefresh = .distantFuture; statuses[id] = status
    }
    private func setOfflineStatus(_ id: UUID) {
        var status = statuses[id] ?? Status()
        status.syncing = false; status.text = "Offline · catalogue available"; status.symbol = "wifi.slash"
        status.nextRefresh = .distantFuture; statuses[id] = status
    }
    private func networkChanged(available: Bool) {
        let recovered = !networkAvailable && available
        networkAvailable = available
        if !available {
            for destination in destinations where !destination.paused {
                cancelRefresh(destination); setOfflineStatus(destination.id)
            }
        } else if recovered {
            for destination in destinations where !destination.paused {
                statuses[destination.id]?.nextRefresh = Date().addingTimeInterval(destination.refreshInterval)
                if UserDefaults.standard.bool(forKey: AppPreferences.refreshOnReconnect) { refresh(destination, force: false) }
            }
        }
    }

    func setPaused(_ destination: Destination, paused: Bool) {
        guard var updated = current(destination.id) else { return }
        updated.paused = paused
        Task {
            do { try await save(updated, isNew: false) }
            catch { self.error = error.localizedDescription }
        }
    }
    func openFinder(_ destination: Destination) {
        guard let manager = NSFileProviderManager(for: domain(destination)) else { error = "Finder has not registered this destination yet."; return }
        Task {
            do { let url = try await manager.getUserVisibleURL(for: .rootContainer); NSWorkspace.shared.open(url) }
            catch { self.error = error.localizedDescription }
        }
    }
    func showEditor(destination: Destination? = nil) {
        editor?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: destination == nil ? 760 : 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = destination == nil ? "Add SSH Destination" : "Destination Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: destination == nil ? 640 : 490)
        window.contentView = NSHostingView(rootView: DestinationEditor(model: self, destination: destination, close: { [weak window] in window?.close() }))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        editor = window
    }
    func showPreferences() {
        if let preferences { preferences.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "benSync Settings"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView(model: self))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        preferences = window
    }
    func save(_ destination: Destination, isNew: Bool) async throws {
        guard !saving.contains(destination.id), !removing.contains(destination.id) else {
            throw BackendError(.invalid, "This destination is already being updated. Try again in a moment.")
        }
        try destination.validate()
        saving.insert(destination.id)
        defer { saving.remove(destination.id) }
        // Invalidate before touching persisted configuration: an old scanner
        // can finish while Finder is updating the domain's display name.
        cancelRefresh(destination)
        let old: Destination?
        do {
            old = try await Task.detached(priority: .userInitiated) {
                let storage = try AppEnvironment.storage()
                let previous = try storage.destinations().first { $0.id == destination.id }
                try storage.save(destination)
                return previous
            }.value
        } catch {
            if let existing = current(destination.id), !existing.paused {
                statuses[destination.id]?.nextRefresh = .distantPast
            }
            throw error
        }
        do { try await NSFileProviderManager.add(domain(destination)) }
        catch {
            try await Task.detached(priority: .userInitiated) {
                let storage = try AppEnvironment.storage()
                if let old { try storage.save(old) } else { try storage.remove(destination.id) }
            }.value
            if let old, !old.paused { statuses[old.id]?.nextRefresh = .distantPast }
            throw error
        }
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) { destinations[index] = destination }
        else { destinations.append(destination) }
        error = nil; observeTransfers(destination)
        if destination.paused { setPausedStatus(destination.id) }
        else {
            // Remove the save gate before starting the new scan. The defer is
            // still needed on all earlier failure paths.
            saving.remove(destination.id)
            refresh(destination, allowInteraction: isNew)
        }
    }
    func remove(_ destination: Destination) {
        guard !saving.contains(destination.id), !removing.contains(destination.id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(destination.name)?"
        alert.informativeText = "This removes its Finder location. Downloaded files and unsynced edits are preserved by macOS. No remote files are deleted."
        alert.addButton(withTitle: "Remove Destination"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removing.insert(destination.id); cancelRefresh(destination)
        Task {
            defer { removing.remove(destination.id) }
            do {
                let preserved = try await NSFileProviderManager.remove(domain(destination), mode: .preserveDownloadedUserData)
                _ = try await broker.perform(BrokerRequest(.remove, destinationID: destination.id))
                destinations.removeAll { $0.id == destination.id }; statuses[destination.id] = nil; transfers[destination.id] = nil
                if let preserved { NSWorkspace.shared.activateFileViewerSelecting([preserved]) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func revealConfiguration() {
        do {
            let url = try AppEnvironment.storage().root.appendingPathComponent("destinations.json")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = error.localizedDescription }
    }
    func exportDiagnostics() {
        guard !exportingDiagnostics else { return }
        exportingDiagnostics = true
        Task {
            defer { exportingDiagnostics = false }
            do {
                let data = try await Task.detached(priority: .utility) {
                    let snapshot = try AppEnvironment.storage().diagnosticsSnapshot()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    return try encoder.encode(snapshot)
                }.value
                let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "benSync-diagnostics.json"
                panel.title = "Export Redacted Diagnostics"
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
}
