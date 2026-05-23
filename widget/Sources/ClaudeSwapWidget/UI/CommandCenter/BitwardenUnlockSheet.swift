import SwiftUI

/// Native passphrase prompt for `bw unlock`. The passphrase is piped to
/// the csw subprocess on stdin (never argv, never logged). The widget
/// only ever sees the user-typed string — the resulting BW_SESSION token
/// stays in the backend.
struct BitwardenUnlockSheet: View {
    let onUnlock: (_ passphrase: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "lock.shield").foregroundColor(.orange)
                Text("Unlock Bitwarden vault").font(.headline)
            }
            Text("The session lives in memory until the 15-minute idle window expires. The passphrase is never logged.")
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("Master passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Unlock") {
                    onUnlock(passphrase)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
