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
            // On notched MacBooks the camera housing extends ~38pt down from
            // the top of the screen while the menu bar is only ~24pt, so the
            // popover's top edge sits inside the notch's vertical range and
            // gets clipped wherever it overlaps horizontally. Push the anchor
            // down by (notchHeight - menuBarHeight) plus a small safety pad.
            let anchor = NSRect(x: 0, y: -notchClearance,
                                width: button.bounds.width,
                                height: button.bounds.height)
            popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private var notchClearance: CGFloat {
        guard #available(macOS 12.0, *) else { return 0 }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let notchTop = screen?.safeAreaInsets.top ?? 0
        guard notchTop > 0 else { return 0 }
        let menuBar = NSStatusBar.system.thickness
        return max(0, notchTop - menuBar) + 4
    }
}
