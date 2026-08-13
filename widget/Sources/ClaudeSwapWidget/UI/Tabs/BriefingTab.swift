import SwiftUI

// BriefingSettingsView owns its own SettingsPage scroll surface. The old
// wrapper added a second ScrollView + tighter gutter that broke parity
// with the other tabs (see also MCPTab).
struct BriefingTab: View {
    var body: some View {
        BriefingSettingsView()
    }
}
