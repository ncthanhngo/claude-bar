import SwiftUI

/// Chip stack above the textarea showing pending pre-send attachments. Each
/// chip is the filename + size + an × to remove. Backed by the composer's
/// local `pendingAttachments` binding.
struct ChatComposerAttachments: View {
    @Binding var items: [AttachmentDTO]
    let palette: BriefingPalette

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { att in
                        chip(for: att)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private func chip(for att: AttachmentDTO) -> some View {
        HStack(spacing: 7) {
            Image(systemName: iconName(for: att.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.coral)
            Text(att.filename)
                .font(.system(size: 11.5))
                .foregroundColor(palette.ink2)
                .lineLimit(1)
            Text("· \(formatSize(att.sizeBytes))")
                .font(.system(size: 10.5))
                .foregroundColor(palette.ink3)
            Button {
                items.removeAll(where: { $0.id == att.id })
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(palette.ink3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(palette.paper2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "pdf": return "doc.richtext"
        default:    return "doc.text"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.0f KB", kb)
    }
}
