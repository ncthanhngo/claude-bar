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
    private static let topGap: CGFloat = 14

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "·· "
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Claude usage")
            button.imagePosition = .imageLeading
            // Listen to both buttons so right-click can open the quick-switch menu
            // while preserving left-click → panel toggle.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(statusBarClicked(_:))
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

        // Request notification permission up-front so manual + auto switches
        // can both post toasts without prompting at the inconvenient moment.
        AutoSwitcher.requestNotificationPermission()

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
        // `.floating` (3) keeps the panel above normal windows but below
        // `.modalPanel` (8) — so NSAlerts / login window can render *on top*
        // of the popover and remain interactive.
        p.level = .floating
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

    /// Splits left vs right click. Right-click (or control-click) opens the
    /// quick-switch NSMenu; left-click toggles the SwiftUI popover panel.
    @objc private func statusBarClicked(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showQuickSwitchMenu()
        } else {
            togglePanel(sender)
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Quick-switch menu

    private func showQuickSwitchMenu() {
        // Make sure the popover isn't covering the click target.
        if panel.isVisible { hidePanel() }
        guard let button = statusItem.button else { return }
        let menu = buildQuickSwitchMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    private func buildQuickSwitchMenu() -> NSMenu {
        let menu = NSMenu()

        if store.accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts saved",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Switch account",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for account in store.accounts {
                let title = accountMenuTitle(account)
                let item = NSMenuItem(title: title,
                                      action: #selector(quickSwitchSelected(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = account.id
                if store.config.activeAccountId == account.id {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let showItem = NSMenuItem(title: "Show usage…",
                                  action: #selector(showPanelFromMenu(_:)),
                                  keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func accountMenuTitle(_ account: Account) -> String {
        if let pct = account.lastSessionPercent {
            return "\(account.displayName) · \(Int(pct.rounded()))%"
        }
        return account.displayName
    }

    @objc private func quickSwitchSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let account = store.accounts.first(where: { $0.id == id }) else { return }
        SwitchAccountAction.confirmAndSwitch(store: store, account: account)
    }

    @objc private func showPanelFromMenu(_ sender: AnyObject?) {
        if !panel.isVisible { showPanel() }
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
