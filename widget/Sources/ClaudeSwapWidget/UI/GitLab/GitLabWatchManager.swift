import SwiftUI

/// Inline add form for a watched GitLab project. Lists the configured GitLab
/// instances (via `csw gitlab list`) and adds a `GitLabWatch` to `PipelineStore`.
struct GitLabWatchManager: View {
    /// Called after a watch is added so the parent can collapse the form.
    var onAdded: () -> Void = {}

    @EnvironmentObject private var pipelineStore: PipelineStore
    @State private var instances: [CswClient.GitLabInstanceDTO] = []
    @State private var selectedInstanceID: String = ""
    @State private var project: String = ""
    @State private var ref: String = ""
    @State private var loadError: String?

    private let client = CswClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watch a project")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if instances.isEmpty {
                Text(loadError ?? "No GitLab instance configured. Add one in Settings → MCP → GitLab first.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if instances.count > 1 {
                    Picker("Instance", selection: $selectedInstanceID) {
                        ForEach(instances) { inst in
                            Text(inst.name).tag(inst.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                TextField("group/project", text: $project)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextField("branch (optional)", text: $ref)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button {
                    addWatch()
                } label: {
                    Label("Add watch", systemImage: "plus.circle.fill")
                        .font(.system(size: 12))
                }
                .disabled(isInvalid)
            }
        }
        .task { await loadInstances() }
    }

    private var isInvalid: Bool {
        selectedInstanceID.isEmpty || project.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadInstances() async {
        do {
            let list = try await client.gitlabList()
            instances = list
            if selectedInstanceID.isEmpty {
                selectedInstanceID = list.first?.id ?? ""
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func addWatch() {
        guard let inst = instances.first(where: { $0.id == selectedInstanceID }) else { return }
        let trimmedProject = project.trimmingCharacters(in: .whitespaces)
        let trimmedRef = ref.trimmingCharacters(in: .whitespaces)
        pipelineStore.addWatch(GitLabWatch(
            instanceID: inst.id,
            instanceName: inst.name,
            project: trimmedProject,
            ref: trimmedRef.isEmpty ? nil : trimmedRef
        ))
        project = ""
        ref = ""
        onAdded()
    }
}
