import SwiftUI
import AppKit
import BenSyncCore

@main
struct benSyncApp: App {
    @StateObject private var model = AppModel()
    @State private var destinationListHeight: CGFloat = 112
    var body: some Scene {
        MenuBarExtra("benSync", systemImage: "externaldrive.badge.icloud") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.icloud").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("benSync").font(.headline)
                        Text("Your remote files, at home in Finder").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.showPreferences() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                        .keyboardShortcut(",", modifiers: .command)
                }.padding(16)
                Divider()
                if model.destinations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect your first destination").font(.headline)
                        Text("Browse files instantly. Download when needed. Keep what you need offline.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(18)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.destinations) { destination in
                                DestinationRow(model: model, destination: destination)
                                if destination.id != model.destinations.last?.id { Divider().padding(.leading, 16) }
                            }
                        }
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: DestinationListHeight.self, value: proxy.size.height)
                        })
                    }
                    .frame(height: min(420, max(86, destinationListHeight)))
                    .onPreferenceChange(DestinationListHeight.self) { destinationListHeight = $0 }
                }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("benSync needs attention", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold))
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        HStack {
                            Button("Retry Setup") { Task { await model.load() } }
                                .disabled(!model.saving.isEmpty || !model.removing.isEmpty)
                            Button("Dismiss") { model.error = nil }
                        }.controlSize(.small)
                    }.padding(14)
                }
                Divider()
                HStack {
                    Button { model.showEditor() } label: { Label("Add Destination…", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                }.padding(14)
            }.frame(width: 390)
        }.menuBarExtraStyle(.window)
    }
}

private struct DestinationListHeight: PreferenceKey {
    static var defaultValue: CGFloat = 112
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DestinationRow: View {
    @ObservedObject var model: AppModel
    let destination: Destination
    @AppStorage(AppPreferences.showCachedCounts) private var showCachedCounts = true
    @AppStorage(AppPreferences.showTransferProgress) private var showTransferProgress = true
    @State private var showDetails = false
    private var status: AppModel.Status { model.statuses[destination.id] ?? AppModel.Status() }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: destination.paused ? "pause.circle" : "server.rack").font(.title3).foregroundStyle(.secondary)
                    .padding(.top, 2)
                Button { model.openFinder(destination) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(destination.name).font(.headline).lineLimit(1)
                        Label(status.text, systemImage: status.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if showCachedCounts, let count = status.count {
                            Text("\(count.formatted()) items in catalogue").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open in Finder")
                if status.syncing { ProgressView().controlSize(.small).padding(.top, 2) }
                Menu {
                    Button("Open in Finder") { model.openFinder(destination) }
                    if status.syncing { Button("Cancel Refresh") { model.cancelRefresh(destination) } }
                    else {
                        Button("Refresh Catalogue") { model.refresh(destination) }.disabled(destination.paused || !model.networkAvailable)
                        Button("Connect / Authenticate…") { model.refresh(destination, allowInteraction: true) }
                            .disabled(destination.paused || !model.networkAvailable)
                    }
                    Button(destination.paused ? "Resume Syncing" : "Pause Syncing") { model.setPaused(destination, paused: !destination.paused) }
                    Button("Settings…") { model.showEditor(destination: destination) }
                    Divider()
                    Button("Remove Destination…", role: .destructive) { model.remove(destination) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(destination.name)")
            }
            if showTransferProgress, let transfer = model.transfers[destination.id] {
                TransferProgressView(transfer: transfer).padding(.leading, 30)
            }
            if let detail = status.detail, !detail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.font(.caption).padding(.leading, 30)
                if !status.syncing && !destination.paused {
                    HStack {
                        Button("Retry") { model.refresh(destination) }
                        Button("Authenticate…") { model.refresh(destination, allowInteraction: true) }
                    }.controlSize(.small).padding(.leading, 30).disabled(!model.networkAvailable)
                }
            }
        }.padding(16).disabled(model.removing.contains(destination.id) || model.saving.contains(destination.id))
    }
}

private struct TransferProgressView: View {
    @ObservedObject var transfer: NativeSyncProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let value = transfer.upload {
                Label("Uploading · \(Int(value * 100))%", systemImage: "arrow.up.circle").font(.caption)
                ProgressView(value: value).controlSize(.mini)
            }
            if let value = transfer.download {
                Label("Downloading · \(Int(value * 100))%", systemImage: "arrow.down.circle").font(.caption)
                ProgressView(value: value).controlSize(.mini)
            }
        }
    }
}
