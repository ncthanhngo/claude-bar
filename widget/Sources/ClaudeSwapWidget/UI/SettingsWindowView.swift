import SwiftUI

// Legacy host. Content was lifted into the menu-bar popover (see
// `WidgetTabbedPopover` + `UI/Tabs/*`). The App scene no longer instantiates
// this view, so the body is intentionally empty — kept around only so existing
// tooling references resolve. Safe to delete once tooling is updated.
struct SettingsWindowView: View {
    var body: some View {
        EmptyView()
    }
}
