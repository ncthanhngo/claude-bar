import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var globalMonitor: Any?
    private let store = UsageStore()
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    private static let popoverSize = NSSize(width: 380, height: 580)
    /// Extra gap below the menu bar / notch before the panel starts.
    private static let topGap: CGFloat = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "·· "
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Claude usage")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        panel = makePanel()

        // Label updates
        store.$labelText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.statusItem.button?.title = text
            }
            .store(in: &cancellables)

        // Kick off
        store.refresh()
        store.fetchWebUsage()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.fetchWebUsage() }
        }
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.popoverSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false

        // PopoverView already defines its own intrinsic size — just wrap it in
        // a rounded card background so it looks like a popover.
        let host = NSHostingController(rootView:
            PopoverView(store: store)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        host.view.frame = NSRect(origin: .zero, size: Self.popoverSize)
        p.contentView = host.view
        return p
    }

    // MARK: - Toggle / position

    @objc private func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // Status item button frame in screen coordinates.
        let buttonFrameOnScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        // Top of safe area = below the notch on notched MacBooks, else just
        // below the menu bar. Use the smaller of (button bottom, safe-top)
        // so the panel starts below whichever extends further down.
        let safeTop = screen.visibleFrame.maxY
        let panelTopY = min(buttonFrameOnScreen.minY, safeTop) - Self.topGap

        // Centre horizontally on the button, but clamp inside the visible
        // frame so we don't run off the screen edges.
        var x = buttonFrameOnScreen.midX - Self.popoverSize.width / 2
        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - Self.popoverSize.width - 8
        x = max(minX, min(maxX, x))

        let originY = panelTopY - Self.popoverSize.height
        panel.setFrame(
            NSRect(x: x, y: originY,
                   width: Self.popoverSize.width, height: Self.popoverSize.height),
            display: true
        )
        panel.orderFrontRegardless()
        panel.makeKey()

        installDismissMonitor()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        removeDismissMonitor()
    }

    // MARK: - Click-outside dismissal (mimics NSPopover .transient)

    private func installDismissMonitor() {
        removeDismissMonitor()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func removeDismissMonitor() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }
}
