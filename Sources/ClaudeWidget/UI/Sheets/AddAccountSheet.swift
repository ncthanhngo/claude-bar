import SwiftUI

/// Snapshot the current Claude Code keychain login as a named account.
struct AddAccountSheet: View {
    @ObservedObject var store: UsageStore
    @Binding var isPresented: Bool

    @State private var label: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            instructions
            VStack(alignment: .leading, spacing: 4) {
                Text("Label").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. work, personal", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(20)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.blue)
            Text("Add Claude account").font(.headline)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Before clicking Add:").font(.caption).bold()
            Text("1. Sign into Claude Code with this account (run `claude` and log in).").font(.caption)
            Text("2. Pick a label below — only used to identify this account in the list.").font(.caption)
            Text("This widget takes a copy of the current Keychain login. Your active session is unaffected.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
            Button("Add") { add() }
                .buttonStyle(.borderedProminent)
                .disabled(label.trimmingCharacters(in: .whitespaces).count < 1)
        }
    }

    private func add() {
        do {
            try store.addCurrentClaudeCodeAccount(label: label)
            isPresented = false
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }
}
