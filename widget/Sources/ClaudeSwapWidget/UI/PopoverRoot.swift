import SwiftUI

/// Thin wrapper that selects which popover layout to render based on the
/// user's preference. Lives at the MenuBarExtra root so toggling
/// "Popover layout" in Settings swaps the body instantly — SwiftUI sees a
/// different concrete view type and rebuilds the popover with the new
/// frame size, no app restart.
///
/// The two layouts share every environment object (AppStore,
/// UpdateController, …) wired by ClaudeSwapWidgetApp, so the switch is
/// purely visual. No data path differs between them.
struct PopoverRoot: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            switch settings.popoverLayout {
            case .full:     WidgetTabbedPopover()
            case .standard: MediumPopoverView()
            case .tiny:     TinyPopoverView()
            }
        }
        // MenuBarExtra re-renders its content view each time the popover
        // opens, so `.onAppear` fires on every open. Used by AppStore to
        // record the popover-open timestamp (boosts polling cadence for a
        // short window) and to trigger an immediate refresh so the user
        // doesn't see a minutes-old snapshot at glance.
        .onAppear { store.notePopoverOpened() }
    }
}
