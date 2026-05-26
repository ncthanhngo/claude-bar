import SwiftUI

// LocalMCPSettingsView already wraps its content in `SettingsPage` (which
// owns the ScrollView + 24/20 gutters). Wrapping it again here added a
// nested ScrollView and a tighter 16/14 gutter — the look-and-feel drift
// you could spot by tabbing between Local MCP and any other settings page.
struct MCPTab: View {
    var body: some View {
        LocalMCPSettingsView()
    }
}
