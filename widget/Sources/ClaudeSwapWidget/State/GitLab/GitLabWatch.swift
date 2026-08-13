import Foundation

/// One project whose latest pipeline Claude Bar watches. Persisted as JSON in
/// `AppSettings.gitlabWatchesJSON`; the menu-bar indicator and the GitLab
/// popover pane both read from these.
struct GitLabWatch: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// GitLab instance id from `csw gitlab list`. Passed as `--instance`
    /// (the backend resolver accepts id or name).
    var instanceID: String
    /// Instance display name, kept for the row label without a second lookup.
    var instanceName: String
    /// Project path (`group/repo`) or numeric project id.
    var project: String
    /// Optional branch/tag filter; nil watches the project's default ordering.
    var ref: String?
    /// Optional label override; falls back to the project path.
    var displayName: String?

    init(
        id: String = UUID().uuidString,
        instanceID: String,
        instanceName: String,
        project: String,
        ref: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.instanceID = instanceID
        self.instanceName = instanceName
        self.project = project
        self.ref = ref
        self.displayName = displayName
    }

    var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return project
    }
}
