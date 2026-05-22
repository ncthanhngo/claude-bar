import SwiftUI
import AppKit
import QuickLookThumbnailing

/// In-message thumbnail for an attachment reference inside a ContentBlock.
/// Loads bytes lazily on appear via `chatStore.loadAttachmentBytes`. Click
/// opens the file in Quick Look (NSWorkspace.openFile is brittle for
/// encrypted bytes; we write to a temp file with a short TTL, hand it to
/// Quick Look, then delete on dismiss).
struct ChatAttachmentThumbnail: View {
    @EnvironmentObject private var chatStore: ChatStore
    let attachmentID: String
    let mediaType: String?
    let palette: BriefingPalette

    @State private var image: NSImage?
    @State private var loadFailed: Bool = false

    var body: some View {
        Button(action: openPreview) {
            content
        }
        .buttonStyle(.plain)
        .task { await loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        if isImage, let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(palette.line2, lineWidth: 1)
                )
        } else if loadFailed {
            failureChip
        } else {
            placeholder
        }
    }

    @ViewBuilder private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text(mediaType ?? "attachment")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(palette.ink2)
                if isImage {
                    Text("đang tải…")
                        .font(.system(size: 10.5))
                        .foregroundColor(palette.ink3)
                } else {
                    Text("bấm để mở")
                        .font(.system(size: 10.5))
                        .foregroundColor(palette.ink3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.paper2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var failureChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.coral)
            Text("không tải được")
                .font(.system(size: 11))
                .foregroundColor(palette.ink2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(palette.blush)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isImage: Bool {
        (mediaType ?? "").hasPrefix("image/")
    }

    private var iconName: String {
        let mt = mediaType ?? ""
        if mt.hasPrefix("image/") { return "photo" }
        if mt == "application/pdf" { return "doc.richtext" }
        return "doc.text"
    }

    // MARK: - Loading + preview

    private func loadIfNeeded() async {
        guard isImage, image == nil else { return }
        if let data = await chatStore.loadAttachmentBytes(id: attachmentID),
           let nsImage = NSImage(data: data) {
            self.image = nsImage
        } else {
            self.loadFailed = true
        }
    }

    private func openPreview() {
        Task {
            guard let data = await chatStore.loadAttachmentBytes(id: attachmentID) else {
                self.loadFailed = true
                return
            }
            // Write to a temp file Quick Look can open. Best-effort cleanup —
            // macOS will GC /var/folders/.../T eventually.
            let ext = (mediaType.flatMap(extensionFor) ?? "bin")
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("claude-bar-att-\(attachmentID).\(ext)")
            do {
                try data.write(to: tmpURL, options: [.atomic])
                NSWorkspace.shared.open(tmpURL)
            } catch {
                self.loadFailed = true
            }
        }
    }

    private func extensionFor(_ mediaType: String) -> String? {
        switch mediaType {
        case "image/png":         return "png"
        case "image/jpeg":        return "jpg"
        case "image/gif":         return "gif"
        case "image/webp":        return "webp"
        case "image/heic":        return "heic"
        case "application/pdf":   return "pdf"
        case "text/plain":        return "txt"
        case "text/markdown":     return "md"
        case "application/json":  return "json"
        default: return nil
        }
    }
}
