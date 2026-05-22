import SwiftUI

/// One row in the conversation rail. Editorial-style: serif italic title,
/// system meta below, no card shadow. Active row gets a `cream` background
/// and a 2pt coral left bar.
struct ChatRailItem: View {
    let conversation: ConversationDTO
    let isActive: Bool
    let palette: BriefingPalette
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isActive ? palette.coral : Color.clear)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 14, design: .serif).italic())
                        .foregroundColor(palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(ChatTimeFormatter.relative(conversation.updatedAt))
                            .font(.system(size: 11))
                            .foregroundColor(palette.ink3)
                        Text("·").foregroundColor(palette.line2)
                        Text(conversation.model)
                            .font(.system(size: 11))
                            .foregroundColor(palette.ink3)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? palette.cream : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Đổi tên", action: onRename)
            Button("Xoá", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("\(displayTitle), \(ChatTimeFormatter.relative(conversation.updatedAt))")
        .overlay(Divider().background(palette.hairlineColor), alignment: .bottom)
    }

    private var displayTitle: String {
        let trimmed = conversation.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Đoạn chat mới" : trimmed
    }
}
