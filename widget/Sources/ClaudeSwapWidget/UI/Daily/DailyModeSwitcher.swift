import SwiftUI

/// Editorial Plan / chat switcher rendered as two serif-italic labels with a
/// coral underline that slides between them via `matchedGeometryEffect`.
/// Not a native SegmentedControl — by design.
struct DailyModeSwitcher: View {
    @Binding var mode: DailyMode
    let palette: BriefingPalette

    @Namespace private var underline

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 24) {
            ForEach(DailyMode.allCases) { item in
                labelButton(for: item)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: mode)
    }

    @ViewBuilder
    private func labelButton(for item: DailyMode) -> some View {
        Button {
            guard mode != item else { return }
            mode = item
        } label: {
            VStack(alignment: .center, spacing: 4) {
                Text(item.label)
                    .font(.system(size: 22, weight: .regular, design: .serif).italic())
                    .foregroundColor(mode == item ? palette.ink : palette.ink3)
                    .lineLimit(1)
                ZStack(alignment: .center) {
                    Rectangle().fill(Color.clear).frame(height: 2)
                    if mode == item {
                        Capsule()
                            .fill(palette.coral)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "daily-mode-underline", in: underline)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Trò chuyện với Claude (⌘2)")
    }
}
