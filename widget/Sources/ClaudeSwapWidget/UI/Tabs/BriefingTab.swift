import SwiftUI

// Thin wrapper around the existing standalone BriefingSettingsView so it
// composes cleanly inside the tabbed popover.
struct BriefingTab: View {
    var body: some View {
        ScrollView {
            BriefingSettingsView()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}
