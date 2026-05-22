import SwiftUI

/// Three-step Add Account wizard.
/// Hosted inside a floating NSWindow (see FloatingWindow) so it survives
/// the user clicking Terminal or the browser mid-flow.
struct AddAccountSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Claude account").font(.title2).fontWeight(.semibold)
            Text("Snapshot a logged-in Claude account into the widget.")
                .font(.subheadline).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loginCoordinator.step {
        case .intro:        introStep
        case .terminalSpawned: terminalStep
        case .snapshotting: ProgressView("Reading Keychain…")
        case .done(let name, let dup, let dupOf): doneStep(name: name, wasDuplicate: dup, dupOf: dupOf)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(msg, systemImage: "xmark.octagon.fill").foregroundColor(.red)
                Text("Verify `claude /login` succeeded, then click Try again.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepRow(1, "Pick a profile name (optional, can be renamed later).")
            TextField("e.g. Personal, Work, Side project", text: $loginCoordinator.pendingNickname)
                .textFieldStyle(.roundedBorder)
            stepRow(2, "We’ll open a Terminal window with `claude` ready to go.")
            stepRow(3, "Run `/login` in that terminal, finish the browser OAuth.")
            stepRow(4, "Return here and click \"I’m logged in\".")
            Label(
                "Always add new accounts through this wizard — running `claude /login` outside it can invalidate the active account's saved login.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var terminalStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Terminal is open", systemImage: "terminal.fill").foregroundColor(.accentColor)
            Text("In that Terminal window:")
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Type:").font(.caption).foregroundColor(.secondary)
                Text("claude").font(.system(.body, design: .monospaced)).padding(4)
                    .background(Color.secondary.opacity(0.1)).cornerRadius(4)
                Text("2. Then type:").font(.caption).foregroundColor(.secondary)
                Text("/login").font(.system(.body, design: .monospaced)).padding(4)
                    .background(Color.secondary.opacity(0.1)).cornerRadius(4)
                Text("3. Finish login in the browser.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func doneStep(name: String, wasDuplicate: Bool, dupOf: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Added \(name)", systemImage: "checkmark.seal.fill").foregroundColor(.green)
            if wasDuplicate, let dupOf {
                Text("⚠ This identity already existed as Account-\(dupOf). Backup credentials were refreshed.")
                    .font(.caption).foregroundColor(.orange)
            }
            Text("You can rename it any time from the menu.").font(.caption).foregroundColor(.secondary)
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").font(.callout).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel") { loginCoordinator.dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            switch loginCoordinator.step {
            case .intro:
                Button("Open Terminal") {
                    Task { await loginCoordinator.spawnTerminal(client: store.client) }
                }
                .keyboardShortcut(.defaultAction)
            case .terminalSpawned:
                Button("I’m logged in") {
                    Task { await loginCoordinator.performSnapshot(client: store.client) }
                }
                .keyboardShortcut(.defaultAction)
            case .snapshotting: EmptyView()
            case .done:
                Button("Done") { loginCoordinator.dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Try again") {
                    Task { await loginCoordinator.performSnapshot(client: store.client) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
