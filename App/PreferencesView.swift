import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppPreferences.showCachedCounts) private var showCachedCounts = true
    @AppStorage(AppPreferences.showTransferProgress) private var showTransferProgress = true
    @AppStorage(AppPreferences.refreshOnReconnect) private var refreshOnReconnect = true
    @AppStorage(AppPreferences.defaultRefreshMinutes) private var defaultRefreshMinutes = 5
    @AppStorage(AppPreferences.defaultRemoteFolder) private var defaultRemoteFolder = "."
    @AppStorage(AppPreferences.defaultExclusions) private var defaultExclusions = "node_modules\n.git"
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var changingLogin = false
    @State private var loginError: String?
    @State private var diagnosticsEnabled = true
    @State private var loadingDiagnostics = true
    @State private var diagnosticsError: String?

    private var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch benSync at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    .disabled(changingLogin)
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow benSync in Login Items to finish enabling it.").font(.caption)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Refresh when the network reconnects", isOn: $refreshOnReconnect)
                Toggle("Show cached item counts", isOn: $showCachedCounts)
                Toggle("Show upload and download progress", isOn: $showTransferProgress)
            }
            Section("Defaults for New Destinations") {
                TextField("Remote folder", text: $defaultRemoteFolder)
                Stepper("Refresh every \(defaultRefreshMinutes) minutes", value: $defaultRefreshMinutes, in: 1...1440)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Excluded directories")
                    TextEditor(text: $defaultExclusions).font(.system(.body, design: .monospaced)).frame(height: 66)
                        .padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    Text("These defaults apply when adding a destination. Existing destinations keep their own settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Configuration and Diagnostics") {
                Text("App preferences use macOS defaults. Destinations are saved in a private shared configuration file used by the app and Finder extension.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Configuration") { model.revealConfiguration() }
                    Button("Export Redacted Diagnostics…") { model.exportDiagnostics() }
                        .disabled(model.exportingDiagnostics)
                }
                Toggle("Keep local diagnostic metrics", isOn: Binding(get: { diagnosticsEnabled }, set: setDiagnosticsEnabled))
                    .disabled(loadingDiagnostics)
                Text("Turning this off clears saved metrics. benSync does not send analytics to a remote service.")
                    .font(.caption).foregroundStyle(.secondary)
                if let diagnosticsError { Text(diagnosticsError).font(.caption).foregroundStyle(.red) }
                Text("Diagnostic exports contain operation counters, timings, and error categories. They omit hosts, paths, filenames, profiles, and credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore App Defaults") { AppPreferences.restoreDefaults() }
                Spacer()
                Text("benSync \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.secondary).font(.caption)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .task {
            do {
                diagnosticsEnabled = try await Task.detached(priority: .utility) {
                    try AppEnvironment.storage().diagnosticsSnapshot().isEnabled
                }.value
            } catch { diagnosticsError = error.localizedDescription }
            loadingDiagnostics = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }
    private func setLaunchAtLogin(_ enabled: Bool) {
        changingLogin = true; loginError = nil
        Task { @MainActor in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { loginError = error.localizedDescription }
            loginStatus = SMAppService.mainApp.status; changingLogin = false
        }
    }
    private func setDiagnosticsEnabled(_ enabled: Bool) {
        loadingDiagnostics = true; diagnosticsError = nil
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) { try AppEnvironment.storage().setDiagnosticsEnabled(enabled) }.value
                diagnosticsEnabled = enabled
            } catch { diagnosticsError = error.localizedDescription }
            loadingDiagnostics = false
        }
    }
}
