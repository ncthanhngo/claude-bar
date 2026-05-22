import SwiftUI

/// Chat mode root: 320pt rail on the left, thread + composer on the right.
/// Reads chatStore + appStore from the environment — both are injected by
/// BriefingWindowController.
struct ChatModeBody: View {
    let palette: BriefingPalette

    var body: some View {
        HStack(spacing: 0) {
            ChatRailView(palette: palette)
                .frame(width: 320)
                .overlay(Divider().background(palette.line), alignment: .trailing)
            ChatThreadView(palette: palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
