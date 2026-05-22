import SwiftUI

/// Search field anchored at the bottom of the rail. Filters the in-memory
/// list client-side by substring of title (case-insensitive). Heavier FTS5
/// search lives in chatStore.searchMessages — exposed in a future "global
/// search" surface; this bar just trims the rail list.
struct ChatRailSearchBar: View {
    @Binding var query: String
    let palette: BriefingPalette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("✱")
                .font(.system(size: 11))
                .foregroundColor(palette.ink3)
            TextField("Tìm kiếm chat…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .serif).italic())
                .foregroundColor(palette.ink)
                .focused($focused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.paper2)
        .overlay(Divider().background(palette.line), alignment: .top)
    }
}
