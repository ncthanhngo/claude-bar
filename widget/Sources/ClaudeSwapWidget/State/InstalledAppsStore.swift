import AppKit
import Foundation
import SwiftUI

/// One installed `.app` bundle plus the metadata the App Management tab shows.
/// Size is filled in asynchronously after the initial fast listing, so the list
/// appears instantly and sizes stream in.
struct InstalledApp: Identifiable, Hashable {
    let id: String          // bundle path (stable identity)
    let name: String
    let bundleID: String
    let version: String
    let url: URL
    var sizeBytes: Int64?   // nil until computed
    let lastUsed: Date?
    /// Apple-shipped app (com.apple.*) — uninstalling could break the OS, so the
    /// UI locks these.
    let isAppleSystem: Bool

    static func == (l: InstalledApp, r: InstalledApp) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A leftover support file an uninstall would also remove (cache, preference,
/// container…). Listed with its size so the user sees exactly what gets trashed.
struct RelatedFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let category: String
    let sizeBytes: Int64
}

/// Scans /Applications (+ ~/Applications) for installed apps, computes sizes,
/// finds each app's leftover support files, and uninstalls by moving the bundle
/// and selected leftovers to the Trash (recoverable — never a hard delete).
@MainActor
final class InstalledAppsStore: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning = false
    @Published var lastError: String?
    /// Transient success line shown after an uninstall (freed space). Cleared by
    /// the view after a couple of seconds.
    @Published var banner: String?

    private let fm = FileManager.default

    private var appDirs: [URL] {
        var dirs = [URL(fileURLWithPath: "/Applications")]
        if let home = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            dirs.append(home)
        }
        return dirs
    }

    private var libraryURL: URL {
        fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
    }

    // MARK: scan

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let dirs = appDirs
        Task {
            let found = await Self.enumerate(dirs)
            self.apps = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.isScanning = false
            await self.computeSizes()
        }
    }

    private nonisolated static func enumerate(_ dirs: [URL]) async -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentAccessDateKey], options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "app" {
                if seen.contains(url.path) { continue }
                seen.insert(url.path)
                guard let b = Bundle(url: url) else { continue }
                let info = b.infoDictionary ?? [:]
                let name = (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let bid = (info["CFBundleIdentifier"] as? String) ?? ""
                let ver = (info["CFBundleShortVersionString"] as? String)
                    ?? (info["CFBundleVersion"] as? String) ?? ""
                let used = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                out.append(InstalledApp(
                    id: url.path, name: name, bundleID: bid, version: ver, url: url,
                    sizeBytes: nil, lastUsed: used,
                    isAppleSystem: bid.hasPrefix("com.apple.")
                ))
            }
        }
        return out
    }

    private func computeSizes() async {
        for app in apps {
            let url = app.url
            let size = await Task.detached { InstalledAppsStore.directorySize(url) }.value
            if let i = apps.firstIndex(where: { $0.id == app.id }) {
                apps[i].sizeBytes = size
            }
        }
    }

    /// Synchronous on purpose (the `DirectoryEnumerator` iterator can't be driven
    /// from an async context under Swift 6). Callers run it via `Task.detached`
    /// to keep the walk off the main actor.
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return 0 }
        while let f = en.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: keys)
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    // MARK: related files

    /// Library locations an uninstall should sweep, matched by bundle id (exact
    /// dir/file) and by app name (Application Support / Logs use names too).
    func relatedFiles(for app: InstalledApp) async -> [RelatedFile] {
        let lib = libraryURL
        let bid = app.bundleID
        let name = app.name
        var candidates: [(URL, String)] = []
        func add(_ rel: String, _ cat: String) { candidates.append((lib.appendingPathComponent(rel), cat)) }
        if !bid.isEmpty {
            add("Caches/\(bid)", "Cache")
            add("Preferences/\(bid).plist", "Preference")
            add("Containers/\(bid)", "Container")
            add("Saved Application State/\(bid).savedState", "Saved state")
            add("HTTPStorages/\(bid)", "HTTP storage")
            add("WebKit/\(bid)", "WebKit")
            add("Application Support/\(bid)", "Support")
        }
        add("Application Support/\(name)", "Support")
        add("Logs/\(name)", "Logs")
        add("Caches/\(name)", "Cache")

        var out: [RelatedFile] = []
        var seen = Set<String>()
        for (url, cat) in candidates where fm.fileExists(atPath: url.path) && !seen.contains(url.path) {
            seen.insert(url.path)
            let size = await Task.detached { InstalledAppsStore.directorySize(url) }.value
            out.append(RelatedFile(url: url, category: cat, sizeBytes: size))
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: uninstall

    /// Moves the app bundle and the chosen leftovers to the Trash. Items the
    /// user can't move (root-owned App Store apps, protected support dirs) are
    /// retried in one admin-elevated batch (single password prompt) that moves
    /// them into the user's Trash — still recoverable, never a hard delete.
    /// Returns bytes reclaimed.
    @discardableResult
    func uninstall(_ app: InstalledApp, alsoTrash related: [RelatedFile]) async -> Int64 {
        var freed: Int64 = 0
        var adminRetry: [(URL, Int64)] = []
        let targets: [(URL, Int64)] = [(app.url, app.sizeBytes ?? 0)] + related.map { ($0.url, $0.sizeBytes) }
        for (url, size) in targets {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                freed += size
            } catch {
                adminRetry.append((url, size))
            }
        }
        if !adminRetry.isEmpty {
            let ok = await Self.adminTrash(adminRetry.map(\.0))
            if ok { freed += adminRetry.map(\.1).reduce(0, +) }
        }

        // Decide outcome from reality: did the bundle actually go away?
        let removed = !fm.fileExists(atPath: app.url.path)
        if removed {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                apps.removeAll { $0.id == app.id }
            }
            banner = "🗑 Đã gỡ \(app.name) · giải phóng \(ByteFormat.string(freed))"
            lastError = nil
        } else {
            lastError = "Không gỡ được \(app.name) — thiếu quyền (huỷ nhập mật khẩu?) hoặc app đang chạy. Thoát app rồi thử lại."
        }
        return freed
    }

    /// Move the given paths into the user's Trash with admin rights in one
    /// privileged shell call. `$HOME` is root's under elevation, so the user's
    /// Trash path is hard-coded from NSHomeDirectory(); names are timestamp-
    /// suffixed to dodge collisions with items already in the Trash.
    nonisolated static func adminTrash(_ urls: [URL]) async -> Bool {
        guard !urls.isEmpty else { return true }
        let trash = NSHomeDirectory() + "/.Trash"
        // Collect into one timestamped subfolder so original names survive and
        // nothing collides with items already in the Trash.
        let sources = urls
            .map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let cmd = "d=\"\(trash)/removed-$(date +%s)\"; /bin/mkdir -p \"$d\"; /bin/mv -f \(sources) \"$d/\""
        return await Task.detached { Shell.admin(cmd) }.value
    }
}

/// Human-readable byte size — shared by the Tools tabs.
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
