import Foundation
import Combine

/// Per-card state for the Workspace feed: drives the expandable AI draft and the
/// approve→execute flow for one signal. One instance per visible card.
@MainActor
final class WorkspaceCardModel: ObservableObject {
    @Published var expanded = false
    @Published var draft = ""
    @Published var rationale: String?
    @Published var isDrafting = false
    @Published var isExecuting = false
    @Published var error: String?
    /// Set once the action has been sent — the card collapses to a done state
    /// until the next feed refresh drops it.
    @Published var executed = false

    private let client = CswClient()

    /// Expand and draft on first open; collapse on second tap.
    func toggle(_ signal: WorkspaceSignalDTO) {
        if expanded {
            expanded = false
            return
        }
        expanded = true
        if draft.isEmpty && !isDrafting {
            Task { await draftNow(signal) }
        }
    }

    /// Generate (or regenerate / refine) the draft. A non-empty `instruction`
    /// refines the current draft instead of starting fresh.
    func draftNow(_ signal: WorkspaceSignalDTO, instruction: String = "") async {
        guard !isDrafting else { return }
        isDrafting = true
        error = nil
        defer { isDrafting = false }
        do {
            let d = try await client.workspaceDraft(
                signal: signal,
                instruction: instruction,
                previousDraft: instruction.isEmpty ? "" : draft
            )
            draft = d.draft
            rationale = d.rationale
        } catch {
            self.error = CswError.redact(error.localizedDescription)
        }
    }

    /// Send the (possibly edited) draft via the provider write tool.
    func execute(_ signal: WorkspaceSignalDTO) async {
        guard !isExecuting, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isExecuting = true
        error = nil
        defer { isExecuting = false }
        do {
            let res = try await client.workspaceExecute(signal: signal, text: draft)
            if res.ok {
                executed = true
                expanded = false
            } else {
                error = res.detail ?? "Không gửi được"
            }
        } catch {
            self.error = CswError.redact(error.localizedDescription)
        }
    }
}
