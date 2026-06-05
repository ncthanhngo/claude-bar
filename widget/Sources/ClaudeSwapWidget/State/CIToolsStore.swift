import Foundation

/// Drives the Daily → Tools "Theo dõi CI" page. Wraps the `citools` backend
/// RPCs: inspect install state, run the one-click install, and (when no GitLab
/// MCP token exists yet) add an instance inline so the user can fill it right
/// here in Daily → Tools. PATs go straight to the backend Keychain via
/// `gitlabAdd` — never held in this store beyond the submit.
@MainActor
final class CIToolsStore: ObservableObject {
    @Published var status: CswClient.CIToolsStatusDTO?
    @Published var instances: [CswClient.GitLabInstanceDTO] = []
    @Published var installLog: [String] = []
    @Published var busy: Bool = false
    @Published var lastError: String?

    // Inline "fill GitLab token" form (shown when no instance is configured).
    @Published var formName = ""
    @Published var formBaseURL = ""
    @Published var formPAT = ""

    private let client: CswClient
    init(client: CswClient = CswClient()) { self.client = client }

    /// True once at least one GitLab MCP instance/token exists.
    var hasToken: Bool { (status?.instances ?? instances.count) > 0 }

    var canSubmitForm: Bool {
        !formName.trimmingCharacters(in: .whitespaces).isEmpty
            && formBaseURL.hasPrefix("https://")
            && !formPAT.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func load() async {
        busy = true; defer { busy = false }
        do {
            async let s = client.citoolsStatus()
            async let i = client.gitlabList()
            status = try await s
            instances = try await i
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func install() async {
        busy = true; defer { busy = false }
        do {
            let r = try await client.citoolsInstall()
            installLog = r.log
            status = r.status
            instances = try await client.gitlabList()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Persist a GitLab instance + PAT (the MCP token) from the inline form,
    /// then refresh. The token lands in the same Keychain slot the MCP GitLab
    /// connector uses, so `install()` can immediately bootstrap glab auth.
    func saveTokenForm() async {
        guard canSubmitForm else { return }
        busy = true; defer { busy = false }
        do {
            try await client.gitlabAdd(
                name: formName.trimmingCharacters(in: .whitespaces),
                baseURL: formBaseURL.trimmingCharacters(in: .whitespaces),
                note: "",
                pat: formPAT
            )
            formName = ""; formBaseURL = ""; formPAT = ""
            lastError = nil
            await load()
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }
}
