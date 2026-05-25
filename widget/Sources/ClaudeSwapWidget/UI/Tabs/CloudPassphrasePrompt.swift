import AppKit
import SwiftUI

/// NSAlert-backed passphrase prompt for iCloud Sync. Built on `NSAlert` for
/// the same reason `AccountRenamePrompt` is: the menu-bar popover
/// (`MenuBarExtra .window`) dismisses the moment a SwiftUI sheet inside it
/// becomes key, tearing down its @State and leaving the sheet's bindings
/// pointing at dead storage. `NSAlert.runModal()` runs in its own modal
/// window and returns the field value synchronously, so the popover
/// can dismiss without invalidating any state the caller needs.
@MainActor
enum CloudPassphrasePrompt {
    /// Show the passphrase modal and return the user-entered value, or `nil`
    /// when the user cancels or submits an empty field. `initial` pre-fills
    /// the field — pass the locally-saved passphrase so repeat pushes don't
    /// require retyping.
    static func run(
        intent: CloudSyncCoordinator.PassphraseIntent,
        initial: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = intent == .pull ? "Restore from iCloud" : "iCloud Sync Passphrase"
        alert.informativeText = intent == .pull
            ? "Enter the passphrase you used on your other Mac. Accounts and connector tokens will be restored into this Mac's Keychain."
            : "Choose a passphrase to encrypt your accounts and connector tokens. You will need it on any new Mac."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Passphrase"
        field.stringValue = initial
        field.cell?.usesSingleLineMode = true
        alert.accessoryView = field

        alert.addButton(withTitle: intent == .pull ? "Continue…" : "Save & Push") // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")                                       // .alertSecondButtonReturn

        // Focus the field so the user can type immediately and press Return
        // to commit (Return triggers the default first button).
        alert.window.initialFirstResponder = field

        let response = PopoverModal.runAlert(alert)
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
