import SwiftUI
import AppKit

/// Guided wizard for adding a new Claude account.
///
/// Flow: spawns Terminal running `claude logout && claude`, watches the
/// Keychain for a fresh OAuth blob, then prompts the user to label it.
/// Falls back to a one-click "snapshot current login" path for users who
/// already authenticated in Terminal themselves.
struct AddAccountSheet: View {
    @ObservedObject var store: UsageStore
    @Binding var isPresented: Bool
    var onChooseMagicLink: () -> Void = {}

    @State private var step: Step = .ready
    @State private var label: String = ""
    @State private var error: String?
    @State private var watcher = KeychainWatcher()
    @State private var saveIntent: SaveIntent = .new

    enum Step: Equatable {
        case ready
        case waiting
        case detected
    }

    /// `.new` = saving a freshly-logged-in account (close sheet after save).
    /// `.saveCurrentThenContinue` = user picked "Save current first" from the
    /// pre-logout warning; after save, return to step .ready so they can then
    /// kick off the login flow for the next account.
    enum SaveIntent {
        case new
        case saveCurrentThenContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .onDisappear { watcher.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: stepIcon).foregroundStyle(.blue)
            Text("Add Claude account").font(.headline)
            Spacer()
            Text(stepLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stepIcon: String {
        switch step {
        case .ready:    return "person.crop.circle.badge.plus"
        case .waiting:  return "hourglass"
        case .detected: return "checkmark.circle.fill"
        }
    }

    private var stepLabel: String {
        switch step {
        case .ready:    return "Step 1 of 2"
        case .waiting:  return "Step 1 of 2"
        case .detected: return "Step 2 of 2"
        }
    }

    // MARK: - Content per step

    @ViewBuilder
    private var content: some View {
        switch step {
        case .ready:    readyView
        case .waiting:  waitingView
        case .detected: detectedView
        }
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a login method").font(.subheadline).bold()
            HStack(alignment: .top, spacing: 4) {
                Text("•").foregroundStyle(.secondary)
                Text("**Open Claude login** — opens Terminal, runs `claude logout && claude`, you sign in via browser (Google, Apple, email magic link, SSO…).")
            }.font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 4) {
                Text("•").foregroundStyle(.secondary)
                Text("**Magic link** — you have a Claude Teams magic-link URL but no email access. Widget drives the OAuth flow automatically.")
            }.font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 4) {
                Text("•").foregroundStyle(.secondary)
                Text("**Snapshot current** — you already logged in via `claude` in Terminal; just save the current Keychain login.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var waitingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for login…").font(.subheadline).bold()
            }
            Text("Complete the `claude` sign-in in Terminal. Widget polls Keychain every 2s and finishes this wizard as soon as fresh credentials appear.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.08)))
    }

    private var detectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("New login detected").font(.subheadline).bold()
            }
            Text("Give this account a label so you can recognize it in the list.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("e.g. work, personal, client-X", text: $label)
                .textFieldStyle(.roundedBorder)
                .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.08)))
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Button("Cancel") { cancel() }
            Spacer()
            switch step {
            case .ready:
                Button("Magic link") { onChooseMagicLink() }
                    .buttonStyle(.bordered)
                Button("Snapshot current") { snapshot() }
                    .buttonStyle(.bordered)
                Button("Open Claude login") { startWizard() }
                    .buttonStyle(.borderedProminent)
            case .waiting:
                EmptyView()
            case .detected:
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Step transitions

    private func startWizard() {
        error = nil
        // Safety: if Keychain has an active login, warn before we let
        // `claude logout` erase it. User can save it as an account first.
        if keychainHasLogin() {
            switch showLogoutWarning() {
            case .saveFirst:
                saveIntent = .saveCurrentThenContinue
                label = ""
                step = .detected
                return
            case .continueAnyway:
                break
            case .cancel:
                return
            }
        }
        do {
            try TerminalLauncher.run(command: "claude logout && claude")
        } catch {
            self.error = (error as NSError).localizedDescription
            return
        }
        step = .waiting
        watcher.start { _ in step = .detected }
    }

    private func keychainHasLogin() -> Bool {
        guard let blob = try? ClaudeCodeCredentials.read() else { return false }
        return !blob.isEmpty
    }

    private enum WarningChoice { case saveFirst, continueAnyway, cancel }

    private func showLogoutWarning() -> WarningChoice {
        let alert = NSAlert()
        alert.messageText = "An active CLI login will be replaced"
        alert.informativeText = "`claude logout` erases the current Keychain credentials. If you haven't saved that login as an account in the widget yet, snapshot it first — otherwise it's gone for good."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save current first")
        alert.addButton(withTitle: "Continue — already saved")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .saveFirst
        case .alertSecondButtonReturn: return .continueAnyway
        default:                       return .cancel
        }
    }

    /// Fallback path: user already has a fresh login they want to capture.
    /// Same behavior as the legacy "Add" button — no Terminal spawn.
    private func snapshot() {
        error = nil
        label = ""
        step = .detected
    }

    private func save() {
        if let existing = store.findDuplicateForCurrentKeychain() {
            guard confirmDuplicate(existing: existing) else { return }
        }
        do {
            try store.addCurrentClaudeCodeAccount(label: label)
            switch saveIntent {
            case .saveCurrentThenContinue:
                // Current login is now saved — return to step 1 so user can
                // proceed to add the next account in the same sheet session.
                saveIntent = .new
                label = ""
                error = nil
                step = .ready
            case .new:
                isPresented = false
            }
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    /// Identity check matched an existing row. Ask whether to proceed anyway.
    private func confirmDuplicate(existing: Account) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This account is already saved"
        alert.informativeText = "These credentials match the row \"\(existing.displayName)\". Saving will create a second snapshot of the same identity.\n\nIf you actually intend a fresh entry, click Save anyway. Otherwise cancel and edit the existing row."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func cancel() {
        watcher.stop()
        isPresented = false
    }
}
