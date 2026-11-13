import AppKit
import SwiftUI
import BenSyncCore

struct DestinationEditor: View {
    @ObservedObject var model: AppModel
    let destination: Destination?
    let close: () -> Void
    @State private var profiles = [SSHProfile]()
    @State private var search = ""
    @State private var selected: String?
    @State private var name = ""
    @State private var root = "."
    @State private var exclusions = "node_modules\n.git"
    @State private var minutes = 5
    @State private var paused = false
    @State private var saving = false
    @State private var loadingProfiles = false
    @State private var error: String?
    private var filtered: [SSHProfile] { profiles.filter { search.isEmpty || $0.alias.localizedCaseInsensitiveContains(search) } }
    private let commonExclusions = ["node_modules", ".git", ".build", "DerivedData", ".venv", "__pycache__"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 32)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination == nil ? "Add an SSH destination" : "Destination settings").font(.title2.weight(.semibold))
                    Text(destination == nil ? "Choose a profile from your SSH configuration." : "Control what syncs and how often it refreshes.")
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if destination == nil {
                        HStack {
                            TextField("Search SSH profiles", text: $search).textFieldStyle(.roundedBorder)
                            Button { Task { await loadProfiles() } } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(loadingProfiles).help("Reload SSH profiles").accessibilityLabel("Reload SSH profiles")
                        }
                        List(filtered, selection: $selected) { profile in
                            HStack {
                                Image(systemName: "terminal")
                                Text(profile.alias).fontWeight(.medium)
                                Spacer()
                                Text((profile.source as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                            }.tag(profile.alias).padding(.vertical, 3)
                        }.frame(height: 155).border(.quaternary)
                        if loadingProfiles { ProgressView("Reading SSH profiles…").controlSize(.small) }
                        else if profiles.isEmpty {
                            Text("No named profiles found. Add a Host alias to ~/.ssh/config, then reload the profiles.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow { Text("Display name"); TextField("Destination name", text: $name).textFieldStyle(.roundedBorder) }
                        if destination == nil {
                            GridRow { Text("Remote folder"); TextField(". (home directory)", text: $root).textFieldStyle(.roundedBorder) }
                        } else {
                            GridRow { Text("SSH profile"); Text(destination!.sshProfile).foregroundStyle(.secondary).textSelection(.enabled) }
                            GridRow { Text("Remote folder"); Text(destination!.root).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        GridRow { Text("Refresh every"); HStack { Stepper("\(minutes) minutes", value: $minutes, in: 1...1440); Spacer() } }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Excluded directories").font(.headline)
                            Spacer()
                            Menu("Add common exclusion") {
                                ForEach(commonExclusions, id: \.self) { entry in Button(entry) { addExclusion(entry) } }
                            }.fixedSize().controlSize(.small)
                        }
                        TextEditor(text: $exclusions).font(.system(.body, design: .monospaced)).frame(height: 95)
                            .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text("One name or glob per line. Names match at any depth; paths match relative to the remote folder. Excluded directories stay on the server.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Pause syncing for this destination", isOn: $paused)
                        Text("Downloaded files and the cached catalogue remain available. New network operations wait until syncing resumes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if destination == nil {
                        Text("Uses your existing SSH keys, agent, jump hosts, and known hosts. You'll be prompted if a password, key passphrase, or server verification is needed. File contents download only when opened or kept offline.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(.trailing, 4)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(saving)
                Button(destination == nil ? "Add Destination" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(saving || (destination == nil && selected == nil) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24)
        .onChange(of: selected) { oldValue, value in
            if name.isEmpty || name == oldValue { name = value ?? "" }
        }
        .task {
            if let destination {
                name = destination.name; root = destination.root; selected = destination.sshProfile
                exclusions = destination.exclusions.joined(separator: "\n"); minutes = max(1, Int(destination.refreshInterval / 60)); paused = destination.paused
            } else {
                root = UserDefaults.standard.string(forKey: AppPreferences.defaultRemoteFolder) ?? "."
                minutes = min(1440, max(1, UserDefaults.standard.integer(forKey: AppPreferences.defaultRefreshMinutes)))
                exclusions = UserDefaults.standard.string(forKey: AppPreferences.defaultExclusions) ?? "node_modules\n.git"
                await loadProfiles()
            }
        }
    }
    private func loadProfiles() async {
        loadingProfiles = true
        defer { loadingProfiles = false }
        do { profiles = try await Task.detached(priority: .userInitiated) { try SSHProfiles.discover() }.value }
        catch { self.error = error.localizedDescription }
    }
    private func addExclusion(_ entry: String) {
        var entries = Exclusions(exclusions.components(separatedBy: .newlines)).patterns
        if !entries.contains(entry) { entries.append(entry) }
        exclusions = entries.joined(separator: "\n")
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                var value = destination ?? Destination(name: name, sshProfile: selected ?? "", root: root)
                value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                value.exclusions = Exclusions(exclusions.components(separatedBy: .newlines)).patterns
                value.refreshInterval = TimeInterval(minutes * 60); value.paused = paused
                try await model.save(value, isNew: destination == nil)
                close()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}
