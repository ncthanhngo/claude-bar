import SwiftUI

/// Settings → GitLab. One place to connect GitLab instances (base URL +
/// Personal Access Token, stored in the Keychain) and choose which projects'
/// pipelines to watch. The watched projects drive the GitLab popover tab and
/// the menu-bar pipeline indicator.
struct GitLabSettingsTab: View {
    @EnvironmentObject private var pipelineStore: PipelineStore

    @State private var instances: [CswClient.GitLabInstanceDTO] = []
    @State private var loading = true
    @State private var loadError: String?

    // Add-instance form.
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newPAT = ""
    @State private var adding = false
    @State private var addError: String?

    private let client = CswClient()

    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup("GitLab instances",
                              subtitle: "Connect a self-hosted or gitlab.com instance. The token is stored in your macOS Keychain, never on disk. Use a token with the `api` or `read_api` scope.") {
                    instancesList
                    Divider()
                    addInstanceForm
                }

                SettingsGroup("Watched projects",
                              subtitle: "Each project's latest pipeline shows in the GitLab popover tab, and the menu bar flips to a pipeline indicator while any watched pipeline is running.") {
                    watchesList
                    Divider()
                    GitLabWatchManager()
                }
            }
        }
        .task { await reload() }
    }

    // MARK: - Instances

    @ViewBuilder private var instancesList: some View {
        if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 12)).foregroundColor(.secondary)
            }
        } else if let loadError {
            Text(loadError).font(.system(size: 12)).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if instances.isEmpty {
            Text("No instance connected yet. Add one below.")
                .font(.system(size: 12)).foregroundColor(.secondary)
        } else {
            ForEach(instances) { inst in
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inst.name).font(.system(size: 13, weight: .medium))
                        Text(inst.baseUrl).font(.system(size: 11)).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await removeInstance(inst) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Remove this instance")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var addInstanceForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add instance")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("Display name (e.g. Work GitLab)", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Base URL — https://gitlab.example.com/api/v4", text: $newURL)
                .textFieldStyle(.roundedBorder)
            SecureField("Personal Access Token", text: $newPAT)
                .textFieldStyle(.roundedBorder)
            if let addError {
                Text(addError).font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if adding { ProgressView().controlSize(.small) }
                Button("Add instance") { Task { await addInstance() } }
                    .disabled(!canAdd || adding)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty &&
            newURL.hasPrefix("https://") &&
            !newPAT.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Watched projects

    @ViewBuilder private var watchesList: some View {
        if pipelineStore.watches.isEmpty {
            Text("No project watched yet. Add one below.")
                .font(.system(size: 12)).foregroundColor(.secondary)
        } else {
            ForEach(pipelineStore.watches) { watch in
                HStack(spacing: 10) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(watch.label).font(.system(size: 13, weight: .medium))
                        Text(watchSubtitle(watch)).font(.system(size: 11)).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        pipelineStore.removeWatch(id: watch.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Stop watching")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func watchSubtitle(_ watch: GitLabWatch) -> String {
        var parts = [watch.instanceName]
        if let ref = watch.ref, !ref.isEmpty { parts.append(ref) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        do {
            instances = try await client.gitlabList()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func addInstance() async {
        adding = true
        addError = nil
        do {
            try await client.gitlabAdd(
                name: newName.trimmingCharacters(in: .whitespaces),
                baseURL: newURL.trimmingCharacters(in: .whitespaces),
                note: "",
                pat: newPAT.trimmingCharacters(in: .whitespaces)
            )
            newName = ""; newURL = ""; newPAT = ""
            await reload()
        } catch {
            addError = error.localizedDescription
        }
        adding = false
    }

    private func removeInstance(_ inst: CswClient.GitLabInstanceDTO) async {
        do {
            try await client.gitlabRemove(id: inst.id)
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
