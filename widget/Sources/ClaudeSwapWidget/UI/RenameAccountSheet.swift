import AppKit
import SwiftUI

/// Account rename prompt. Built on `NSAlert` instead of a SwiftUI `.sheet`
/// because the menu-bar popover (`MenuBarExtra .window`) dismisses itself the
/// moment a SwiftUI sheet attached to its hosting panel takes focus on Save —
/// the click registers, the sheet starts dismissing, the popover then collapses
/// and the in-flight `Task { await store.rename(...) }` races with the view
/// tear-down. Users see "popover closed, nothing renamed" and have to retry.
///
/// `NSAlert.runModal()` runs in its own modal window (same pattern as the
/// "Claude is busy" warning in AccountRowView). The popover stays open across
/// the modal, Save returns synchronously with the new name, and the rename
/// `Task` is dispatched from the calling coordinator method after the modal
/// closes — no view-tree race.
@MainActor
enum AccountRenamePrompt {
    /// Show the rename modal for `account` and call `apply(newName)` when the
    /// user commits. Empty string means "clear nickname" (revert to email).
    /// No-op when the user cancels.
    static func run(for account: AccountViewDTO, apply: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Rename profile"
        alert.informativeText = account.account.email
        alert.alertStyle = .informational

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Profile name"
        field.stringValue = account.account.nickname ?? ""
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")         // .alertSecondButtonReturn
        let clearButton = alert.addButton(withTitle: "Clear")  // .alertThirdButtonReturn
        clearButton.isEnabled = !(account.account.nickname ?? "").isEmpty

        // Focus the text field so the user can type immediately and press
        // Return to commit (Return triggers the default Save button).
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            apply(trimmed)
        case .alertThirdButtonReturn:
            apply("")
        default:
            return
        }
    }
}
