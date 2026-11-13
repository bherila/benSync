import FileProvider
import Foundation
import Combine

/// Observe system-wide transfer progress for this domain, without polling
/// files or running a second filesystem watcher.
@MainActor
final class NativeSyncProgress: ObservableObject {
    @Published private(set) var upload: Double?
    @Published private(set) var download: Double?
    private let uploads: Progress
    private let downloads: Progress
    private var observations = [NSKeyValueObservation]()

    init(manager: NSFileProviderManager) {
        uploads = manager.globalProgress(for: .uploading)
        downloads = manager.globalProgress(for: .downloading)
        for progress in [uploads, downloads] {
            observations.append(progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.update() }
            })
        }
    }
    private func update() {
        upload = uploads.isFinished ? nil : min(1, max(0, uploads.fractionCompleted))
        download = downloads.isFinished ? nil : min(1, max(0, downloads.fractionCompleted))
    }
}
