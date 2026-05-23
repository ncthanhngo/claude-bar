import AppKit
import SwiftUI
import Combine

/// Owns the borderless NSWindow that hosts BriefingView and animates it open
/// "expanding from the menu bar" → center of screen.
///
/// macOS does not expose the MenuBarExtra status item frame via public API.
/// We approximate by starting the window as a thin pill in the top-right
/// corner (where most users' menu-bar icons live) and expanding to a near-
/// fullscreen frame with a spring curve.
@MainActor
final class BriefingWindowController: NSObject, NSWindowDelegate {
    static let shared = BriefingWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var coordinatorObserver: AnyCancellable?
    private weak var coordinator: BriefingCoordinator?
    private weak var store: AppStore?
    private weak var chatStore: ChatStore?
    private weak var newsCoord: NewsFeedCoordinator?

    // MARK: - Public API

    /// `true` only when the briefing window is BOTH visible and the current
    /// key window — i.e. genuinely in the foreground in front of every other
    /// app. Lets `BriefingCoordinator.toggle()` decide "bring to front" vs
    /// "close" instead of toggling blindly on `isWindowOpen`, which is just a
    /// logical "should be shown" flag and can't tell that the window is
    /// buried behind Chrome / Xcode / etc.
    var isKeyAndVisible: Bool {
        guard let w = window else { return false }
        return w.isVisible && w.isKeyWindow
    }

    /// Raise the briefing window above every other app and make it key. Used
    /// by the global hotkey when Daily is open-but-buried so a single press
    /// pulls it forward instead of dismissing it. Also dismisses the menu-bar
    /// popover so the two never overlap.
    func bringToFront() {
        MenuBarPopoverToggle.closeIfOpen()
        guard let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }


    /// Attach to a coordinator's `isWindowOpen` flag — opening / closing the
    /// window is driven from the @Published binding, so any caller (hotkey,
    /// menu link, Telegram callback) just flips `coord.show()` / `close()`.
    /// All shared coordinators are injected so the Daily UI can read state
    /// directly via @EnvironmentObject.
    func attach(
        coordinator: BriefingCoordinator,
        store: AppStore,
        chatStore: ChatStore,
        newsCoord: NewsFeedCoordinator
    ) {
        self.coordinator = coordinator
        self.store = store
        self.chatStore = chatStore
        self.newsCoord = newsCoord
        coordinatorObserver = coordinator.$isWindowOpen.sink { [weak self] open in
            guard let self else { return }
            Task { @MainActor in
                if open { self.present(with: coordinator) }
                else    { self.dismiss() }
            }
        }
    }

    // MARK: - Window plumbing

    private func present(with coordinator: BriefingCoordinator) {
        // Collapse the menu-bar popover back into the status item so it
        // doesn't sit on top of the Daily window. `NSApp.activate` below would
        // dismiss it on focus loss anyway, but in practice the dismissal is
        // unreliable when activate races with the popover's own click handler,
        // so click the status button explicitly when it's still on.
        MenuBarPopoverToggle.closeIfOpen()
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // attach(coordinator:store:) wires both before any hotkey can fire.
        // If this assertion ever trips, the hotkey path opened the window
        // before app start-up finished — fix the caller, never spin up a
        // phantom AppStore here (would split swappingTo / snapshot state).
        guard let store, let chatStore, let newsCoord else {
            assertionFailure("BriefingWindowController.present called before attach(...)")
            return
        }
        // Refresh news on every open so the user always sees fresh headlines.
        newsCoord.refresh()
        let view = BriefingView()
            .environmentObject(coordinator)
            .environmentObject(store)
            .environmentObject(chatStore)
            .environmentObject(newsCoord)
        let host = NSHostingController(rootView: AnyView(view))
        self.hostingController = host

        let w = makeWindow()
        w.contentViewController = host
        w.delegate = self
        self.window = w

        animateOpen(window: w)
    }

    private func dismiss() {
        guard let w = window else { return }
        animateClose(window: w) { [weak self] in
            self?.window = nil
            self?.hostingController = nil
        }
    }

    // MARK: - Frames

    private func makeWindow() -> NSWindow {
        // KeyableBorderlessWindow overrides canBecomeKey/Main so TextEditor
        // and TextField inside Chat mode actually receive keystrokes — a
        // plain borderless NSWindow returns canBecomeKey=false by default
        // and silently swallows every keypress.
        let w = KeyableBorderlessWindow(
            contentRect: startFrame,
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Plain `.normal` level — sitting above status bar (`statusBar+1`)
        // makes the popover appear behind the Daily window, and forces macOS
        // to treat this as system UI which blocks horizontal Mission-Control
        // swipes between Spaces. With `.normal` the popover (popUpMenu level)
        // overlays Daily naturally and Spaces work like with any other window.
        w.level = .normal
        // Tie the window to whichever Space it was opened on. Omitting
        // `.moveToActiveSpace` means swiping to another Space leaves Daily
        // behind on its original Space instead of dragging it along — the
        // behaviour the user expects from a normal app window.
        w.collectionBehavior = []
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.hasShadow = true
        w.backgroundColor = .clear
        w.isOpaque = false
        // Soft rounded chrome — NSVisualEffectView would clip our SwiftUI bg;
        // keep the SwiftUI background and just round the window corners.
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 22
        w.contentView?.layer?.masksToBounds = true
        return w
    }

    /// Small rect anchored to the Claude Bar status item — gives the animation
    /// an honest origin so the window "grows out of the menu bar icon".
    /// Falls back to a top-right pill when the status item can't be located.
    private var startFrame: NSRect {
        if let icon = MenuBarPopoverToggle.statusItemScreenFrame() {
            let pad: CGFloat = 6
            let w: CGFloat = max(icon.width + pad * 2, 36)
            let h: CGFloat = max(icon.height, 22)
            let x = icon.midX - w / 2
            let y = icon.minY
            return NSRect(x: x, y: y, width: w, height: h)
        }
        guard let screen = NSScreen.main else { return NSRect(x: 0, y: 0, width: 36, height: 22) }
        let v = screen.visibleFrame
        return NSRect(x: v.maxX - 240, y: v.maxY - 22, width: 36, height: 22)
    }

    /// Near-fullscreen, centered, with 32px inset on each side.
    private var endFrame: NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 1400, height: 900)
        }
        let v = screen.visibleFrame
        let inset: CGFloat = 32
        return v.insetBy(dx: inset, dy: inset)
    }

    // MARK: - Animation

    private func animateOpen(window w: NSWindow) {
        w.setFrame(startFrame, display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Use NSAnimationContext for smooth resize + fade-in.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.55
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1.0) // easeOutExpo-ish
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(endFrame, display: true, animate: true)
            w.animator().alphaValue = 1.0
        })

        // Light beam projects from the icon onto the briefing — drop in
        // partway through the open animation so the user sees the page
        // arriving inside the cone of light, not after. Beam color matches
        // the menu-bar icon tint so the light visibly comes from the icon.
        let beamColor = AppSettings.shared.menuBarIconColor.color ?? Color.primary
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak w] in
            guard let w else { return }
            TetherWindowController.shared.show(below: w, beamColor: beamColor)
        }
    }

    private func animateClose(window w: NSWindow, completion: @escaping @MainActor @Sendable () -> Void) {
        TetherWindowController.shared.hide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.7, 0.2) // easeInQuint-ish
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(startFrame, display: true, animate: true)
            w.animator().alphaValue = 0
        }, completionHandler: {
            // NSAnimationContext's completionHandler is @Sendable; orderOut +
            // user completion are main-actor operations. Hop explicitly.
            Task { @MainActor in
                w.orderOut(nil)
                completion()
            }
        })
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator?.close()
        return false // we drive close via the coordinator binding
    }
}

/// Borderless NSWindow that can become key + main. AppKit defaults both
/// flags to false for `.borderless` style mask, which silently disables
/// every TextField / TextEditor inside the window — keystrokes never reach
/// SwiftUI because the window can't take first responder.
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
