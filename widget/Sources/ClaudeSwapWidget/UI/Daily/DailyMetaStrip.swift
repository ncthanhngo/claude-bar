import SwiftUI

/// Date · cập nhật · kế tiếp metadata cluster shown only in Plan mode.
/// Lives between the mode switcher and the actions cluster in `DailyTopBar`.
struct DailyMetaStrip: View {
    let palette: BriefingPalette
    let dateLabel: String
    let lastGenerated: String
    let nextRun: String

    var body: some View {
        HStack(spacing: 18) {
            metaItem(label: nil, value: dateLabel, bold: true)
            metaItem(label: "cập nhật", value: lastGenerated)
            metaItem(label: "kế tiếp", value: nextRun)
        }
        .font(.system(size: 12))
        .foregroundColor(palette.ink2)
    }

    @ViewBuilder private func metaItem(label: String?, value: String, bold: Bool = false) -> some View {
        HStack(spacing: 4) {
            if let label {
                Text(label).foregroundColor(palette.ink3)
            }
            Text(value)
                .fontWeight(bold ? .semibold : .medium)
                .foregroundColor(palette.ink)
        }
    }
}

/// Chat-mode sibling of `DailyMetaStrip`: a single primary "Đoạn chat mới"
/// button + status hint, replacing the date/run metadata when the user is
/// in conversation context. `isReady` is false until phase 07 wires the
/// ChatStore — disables the button so users don't think it's broken.
struct DailyChatSubBar: View {
    let palette: BriefingPalette
    let isReady: Bool
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onNewChat) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Đoạn chat mới")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(palette.paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(isReady ? palette.coral : palette.ink3))
            .disabled(!isReady)
            .help(isReady ? "Bắt đầu một đoạn chat mới (⌘N)" : "Sắp đến — ChatStore wired ở phase 07")

            Text(isReady
                 ? "OAuth từ tài khoản active · ⌘N để bắt đầu nhanh"
                 : "OAuth từ tài khoản active · UI hoàn chỉnh ở phase 07")
                .font(.system(size: 11.5))
                .foregroundColor(palette.ink3)
        }
    }
}
