import AppKit
import SwiftUI

/// Account rename UI hosted in a floating NSWindow.
///
/// Earlier versions used `NSAlert.runModal()` (commit 40d80e2) because a
/// SwiftUI `.sheet` attached to the menu-bar popover dismissed mid-flow.
/// NSAlert improved that, but the SwiftUI `Menu` (the ellipsis on each
/// account row) → action handler → `runModal()` chain still races with the
/// MenuBarExtra popover dismissing on focus loss: the first Save click
/// closed both popovers without firing the rename. Repeating worked.
///
/// `FloatingWindow` (same pattern as the Add-account wizard) decouples the
/// rename form from the popover entirely. The form owns its own `@State`
/// for the text field, the save closure captures a strong reference to the
/// `AppStore`, and the rename `Task` is dispatched from the form's button
/// action — independent of whether the popover is still alive.
@MainActor
final class RenameAccountCoordinator {
    static let shared = RenameAccountCoordinator()

    private let window = FloatingWindow<AnyView>()

    private init() {}

    /// Presents the rename form for `account`. `onCommit` fires with the
    /// new nickname (empty string clears it back to the email). The window
    /// is closed before `onCommit` runs so the caller can dispatch its
    /// rename `Task` without racing the window-close animation.
    func present(for account: AccountViewDTO, onCommit: @escaping (String) -> Void) {
        let close: () -> Void = { [window] in window.close() }
        window.show(title: "Rename profile", size: NSSize(width: 360, height: 190)) {
            AnyView(
                RenameAccountForm(
                    initialName: account.account.nickname ?? "",
                    email: account.account.email,
                    onCancel: close,
                    onClear: {
                        close()
                        onCommit("")
                    },
                    onSave: { newName in
                        close()
                        onCommit(newName)
                    }
                )
            )
        }
        // SwiftUI MenuBarExtra dismisses its popover whenever any other
        // window in the app becomes key — including the Rename sheet we
        // just showed. There is no documented hook to override that
        // dismissal (NSPopover.behavior isn't reachable through the
        // MenuBarExtra abstraction). Re-open the popover on the next
        // runloop tick so the user sees both at once: the Rename window
        // at popUpMenu+2 on top, the menu-bar popover at .floating
        // behind it. Without this, every Rename click yanked the user
        // out of the account list they were just looking at.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MenuBarPopoverToggle.openIfClosed()
        }
    }
}

private struct RenameAccountForm: View {
    let initialName: String
    let email: String
    let onCancel: () -> Void
    let onClear: () -> Void
    let onSave: (String) -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(
        initialName: String,
        email: String,
        onCancel: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.initialName = initialName
        self.email = email
        self.onCancel = onCancel
        self.onClear = onClear
        self.onSave = onSave
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename profile")
                    .font(.system(size: 14, weight: .semibold))
                Text(email)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)
            Spacer(minLength: 0)
            HStack {
                Button("Clear", action: onClear)
                    .disabled(initialName.isEmpty)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func commit() {
        let value = trimmed
        guard !value.isEmpty else { return }
        onSave(value)
    }
}
