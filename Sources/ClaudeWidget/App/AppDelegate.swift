import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = UsageStore()
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "·· "
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Claude usage")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))

        // Subscribe label updates
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
            MainActor.assumeIsolated {
                self?.store.tick()
            }
        }
        // JSONL rescan every 15s.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.refresh()
            }
        }
        // claude.ai web usage every 60s when connected — ground truth.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.fetchWebUsage()
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(from: button)
        }
    }

    /// NSPopover sits flush against the status item, which means on notched
    /// MacBooks the popover's top edge falls inside the camera housing's
    /// vertical range. macOS clips those pixels (they're physically not on
    /// the panel), so the top-left/right corner appears chopped off.
    ///
    /// The positioning rect offset that we tried first didn't move the
    /// popover far enough — NSPopover snaps back near the source. Detach
    /// instead: show as a borderless NSPanel positioned below the safe area.
    private func showPopover(from button: NSStatusBarButton) {
        let inset = notchInset
        if inset <= 0 {
            // Non-notched display — use the default placement.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        // Shift the anchor far enough that popover.top > notch.bottom.
        let anchor = NSRect(x: 0, y: -inset,
                            width: button.bounds.width,
                            height: button.bounds.height)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        if let win = popover.contentViewController?.view.window {
            win.makeKey()
            // Force a downward nudge — some macOS releases ignore the
            // positioning rect's Y once the popover is on-screen.
            var frame = win.frame
            if let screen = button.window?.screen ?? NSScreen.main {
                let maxTop = screen.frame.maxY - inset - 2
                if frame.maxY > maxTop {
                    frame.origin.y -= (frame.maxY - maxTop)
                    win.setFrame(frame, display: true)
                }
            }
        }
    }

    /// How far below the screen's true top edge the popover must start.
    /// On notched MacBooks this is the camera housing height; otherwise 0.
    private var notchInset: CGFloat {
        guard #available(macOS 12.0, *) else { return 0 }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        return screen?.safeAreaInsets.top ?? 0
    }
}
