import Foundation

/// Centralised media-type detection + size caps. Shared by ChatStore
/// (upload validation) and any UI surface that needs to know whether a
/// dropped URL is supported before sending it across the bridge.
///
/// Size caps mirror `backend/internal/usecase/chat/attach_file.go` —
/// keep both in sync.
enum MediaTypeDetector {

    enum Kind: String, Equatable {
        case image
        case pdf
        case text
    }

    struct Resolved: Equatable {
        let kind: Kind
        let mediaType: String   // RFC 6838 form, e.g. "image/png"
    }

    /// Returns nil for unsupported extensions — callers should surface a
    /// "Định dạng không hỗ trợ" toast.
    static func detect(url: URL) -> Resolved? {
        let ext = url.pathExtension.lowercased()
        if let res = imageMap[ext] {
            return Resolved(kind: .image, mediaType: res)
        }
        if ext == "pdf" {
            return Resolved(kind: .pdf, mediaType: "application/pdf")
        }
        if textExtensions.contains(ext) {
            return Resolved(kind: .text, mediaType: "text/plain")
        }
        return nil
    }

    /// Size cap in bytes for the given kind. Matches the backend caps in
    /// `chat.attach_file.go`; do not relax one side without the other.
    static func sizeCap(for kind: Kind) -> Int64 {
        switch kind {
        case .image: return 5 * 1024 * 1024
        case .pdf:   return 20 * 1024 * 1024
        case .text:  return 256 * 1024
        }
    }

    static func sizeCapMB(for kind: Kind) -> Int {
        Int(sizeCap(for: kind) / 1_048_576)
    }

    /// Filename → MediaType for the clipboard-paste flow where we
    /// fabricate a name ("clipboard-1700000000.png").
    static func mediaType(forFilename name: String) -> String {
        let url = URL(fileURLWithPath: name)
        return detect(url: url)?.mediaType ?? "application/octet-stream"
    }

    // MARK: - Tables

    private static let imageMap: [String: String] = [
        "png":  "image/png",
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "gif":  "image/gif",
        "webp": "image/webp",
        "heic": "image/heic",
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json",
        "go", "swift", "py", "ts", "tsx", "js", "jsx",
        "rs", "java", "kt", "kts",
        "c", "h", "cpp", "hpp", "cc",
        "sh", "bash", "zsh",
        "yml", "yaml", "toml", "ini", "cfg",
        "html", "css", "scss", "sass",
        "sql", "graphql", "proto",
    ]
}
