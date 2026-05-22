import SwiftUI

// Thin wrapper around the existing standalone LocalMCPSettingsView so it
// composes cleanly inside the tabbed popover. Padding matches the look of
// other tabs (SettingsPage applies its own padding internally).
struct MCPTab: View {
    var body: some View {
        ScrollView {
            LocalMCPSettingsView()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}
