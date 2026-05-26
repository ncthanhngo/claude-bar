import SwiftUI

/// Sentinel ID for the invisible anchor at the very top of a
/// `SettingsPage`. Lives at file scope because Swift forbids `static`
/// stored properties inside a generic type.
private let settingsPageTopAnchorID = "settings-page-top"

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Belt-and-suspenders for the "MCP opens scrolled mid-page" bug:
        //
        //   1. `defaultScrollAnchor(.top)` makes async content growth
        //      (MCP connector list inflating after `coordinator.refresh()`)
        //      keep the top edge pinned instead of sliding the page down.
        //   2. `ScrollViewReader` + a sentinel `"top"` view + explicit
        //      `scrollTo("top")` on appear forces the scroll offset back
        //      to zero. Without this, SwiftUI on macOS sometimes lands
        //      the ScrollView's first paint at a non-zero offset — when
        //      a Button inside the content holds keyboard focus on
        //      appear, AppKit auto-scrolls it into view.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 0).id(settingsPageTopAnchorID)
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .onAppear {
                // First frame: snap to top immediately. The async
                // dispatch handles the case where async data inflates
                // the page after first paint and re-shifts the offset.
                proxy.scrollTo(settingsPageTopAnchorID, anchor: .top)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(settingsPageTopAnchorID, anchor: .top)
                }
            }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
        .groupBoxStyle(.automatic)
    }
}

struct SettingsToggleLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

