import AppKit
import Foundation

/// Owns the on-disk avatar PNG shown in the Daily window's profile chip.
/// Pick a file → decode via `NSImage` → re-encode as PNG → write atomically
/// to `~/Library/Application Support/claude-swap-widget/avatar.png`. Storing
/// a normalised PNG (instead of the raw user file) means we don't have to
/// worry about HEIC/SVG/giant TIFFs leaking into the UI layer.
enum ProfileAvatarStore {
    static var avatarURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("claude-swap-widget", isDirectory: true)
            .appendingPathComponent("avatar.png")
    }

    /// Read the PNG into an `NSImage`, returning nil when the file is missing
    /// or unreadable. Callers should fall back to the initial-letter chip.
    static func load() -> NSImage? {
        let url = avatarURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Re-encode `image` as PNG (downscaled so we never persist 4K originals)
    /// and atomically replace the stored avatar. Returns the destination URL
    /// on success.
    @discardableResult
    static func save(_ image: NSImage) -> URL? {
        guard let png = pngData(from: image) else { return nil }
        let url = avatarURL
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            print("[ProfileAvatarStore] save failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: avatarURL)
    }

    private static let maxEdge: CGFloat = 256

    private static func pngData(from image: NSImage) -> Data? {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let scale = min(1, maxEdge / max(originalSize.width, originalSize.height))
        let targetSize = NSSize(
            width: max(1, floor(originalSize.width * scale)),
            height: max(1, floor(originalSize.height * scale))
        )
        let pixelW = Int(targetSize.width)
        let pixelH = Int(targetSize.height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero, operation: .copy, fraction: 1
        )
        return rep.representation(using: .png, properties: [:])
    }
}
