import SwiftUI
import AppKit

/// NSViewRepresentable wrapping an NSTextView so we can intercept the
/// Return key and route it to `onSend` instead of letting NSTextView
/// insert a newline (which is what plain SwiftUI TextEditor does).
///
/// Behaviour:
///   - ↩          → calls `onSend()` (if there's any text / pending attachments)
///   - ⇧↩         → inserts a newline (default chat pattern)
///   - ⌥↩, ⌘↩   → also insert a newline so power-users with muscle memory
///                  from prior versions don't lose their draft
struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    let palette: BriefingPalette
    let placeholder: String
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSend: onSend)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // Scrollbar hidden entirely — chat composer should feel like a soft
        // expanding textarea; the wheel still scrolls when content overflows.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed
        scroll.autohidesScrollers = true

        let textView = ReturnInterceptingTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14.5)
        textView.textColor = NSColor(palette.ink)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.allowsUndo = true
        // Generous internal padding so the text never hugs the card edge —
        // matches the soft feel of claude.ai's composer.
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ReturnInterceptingTextView else { return }
        // Keep the NSTextView's string in sync with the binding when the
        // parent mutates it (clears after send, suggestion insertion).
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        textView.coordinator = context.coordinator
        context.coordinator.onSend = onSend
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSend: () -> Void

        init(text: Binding<String>, onSend: @escaping () -> Void) {
            self._text = text
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text = textView.string
        }
    }
}

/// NSTextView subclass that hands the Return keypress (without Shift /
/// Option / Command) to its coordinator's onSend callback. Holding any of
/// the standard newline-extending modifiers falls back to default
/// behaviour, so the user can still construct multi-line drafts.
final class ReturnInterceptingTextView: NSTextView {
    weak var coordinator: ChatTextEditor.Coordinator?

    override func keyDown(with event: NSEvent) {
        if isPlainReturn(event) {
            coordinator?.onSend()
            return
        }
        super.keyDown(with: event)
    }

    private func isPlainReturn(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76 else { return false } // Return / numpad Enter
        let blockingMods: NSEvent.ModifierFlags = [.shift, .option, .command, .control]
        return event.modifierFlags.intersection(blockingMods).isEmpty
    }
}
