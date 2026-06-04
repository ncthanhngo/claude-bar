import SwiftUI

/// Disk tab — mounted volumes as used/total bars, plus a folder breakdown into
/// its biggest top-level children. Read-only.
struct DiskAnalyzerView: View {
    @ObservedObject var store: DiskAnalyzer
    let palette: BriefingPalette

    private var shownDirs: [DirUsage] { store.deepMode ? store.deepDirs : store.dirs }
    private var maxDir: Int64 { shownDirs.map(\.sizeBytes).max() ?? 1 }
    private var scanning: Bool { store.deepMode ? store.isDeepScanning : store.isScanning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                AIAskButton(palette: palette) {
                    if let (s, p) = aiBuild() {
                        AIChatWindowController.shared.present(palette: palette, title: "AI gợi ý dọn ổ đĩa",
                            system: s, context: p,
                            suggestions: ["Thư mục nào an toàn để xoá?", "Cách giải phóng nhiều nhất?",
                                          "Đường dẫn nào là cache/tạm?"])
                    }
                }.disabled(aiBuild() == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    volumesSection
                    breakdownSection
                }
            }
        }
        .onAppear { if store.volumes.isEmpty { store.loadVolumes() } }
    }

    private func aiBuild() -> (system: String, prompt: String)? {
        let scanned = store.deepMode ? store.deepDirs : store.dirs
        guard !store.volumes.isEmpty || !scanned.isEmpty else { return nil }
        let system = """
        Bạn là trợ lý phân tích đĩa macOS. Trả lời tiếng Việt, súc tích, gạch đầu dòng. \
        Dựa trên dung lượng ổ đĩa và các thư mục ngốn chỗ, gợi ý nên xem/dọn ở đâu để \
        giải phóng dung lượng. Chỉ rõ thư mục nào thường an toàn để xoá (cache, log, \
        build/DerivedData, node_modules, tệp tạm) và thư mục nào cần thận trọng. \
        CHỈ dựa trên số liệu đưa ra, không bịa đường dẫn.
        """
        let vols = store.volumes.map {
            "- Ổ \($0.name): dùng \(ByteFormat.string($0.used))/\(ByteFormat.string($0.total)), trống \(ByteFormat.string($0.free))"
        }.joined(separator: "\n")
        let dirs = scanned.prefix(25).map {
            "- \(ByteFormat.string($0.sizeBytes)) — \($0.url.path)"
        }.joined(separator: "\n")
        let label = store.deepMode ? "Thư mục lớn (quét sâu)" : "Thư mục ngốn chỗ"
        let body = [vols.isEmpty ? nil : "Ổ đĩa:\n\(vols)",
                    dirs.isEmpty ? nil : "\(label):\n\(dirs)"]
            .compactMap { $0 }.joined(separator: "\n\n")
        return (system, "\(body)\n\nNên dọn ở đâu để an toàn giải phóng nhiều dung lượng nhất?")
    }

    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ổ đĩa").font(.system(size: 14, weight: .semibold)).foregroundColor(palette.ink)
            ForEach(store.volumes) { v in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: "internaldrive").font(.system(size: 11)).foregroundColor(palette.ink2)
                        Text(v.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(palette.ink)
                        Spacer()
                        Text("\(ByteFormat.string(v.used)) / \(ByteFormat.string(v.total)) · trống \(ByteFormat.string(v.free))")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundColor(palette.ink3)
                    }
                    bar(fraction: v.usedFraction, color: v.usedFraction > 0.9 ? palette.coral : palette.moss)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
            }
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Thư mục ngốn chỗ").font(.system(size: 14, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Text(store.rootPath).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(palette.ink3).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .trailing)
                Button { store.chooseFolder() } label: { Image(systemName: "folder") }.buttonStyle(.plain).foregroundColor(palette.ink2)
                if scanning { ProgressView().controlSize(.small) }
                Button { store.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(palette.ink2).disabled(scanning)
            }
            modePicker
            if shownDirs.isEmpty {
                Text(scanning ? (store.deepMode ? "Đang quét sâu… (có thể mất một lúc với thư mục lớn)" : "Đang quét…")
                              : "Bấm ↻ để \(store.deepMode ? "quét sâu toàn bộ cây thư mục" : "phân tích thư mục này").")
                    .font(.system(size: 11)).foregroundColor(palette.ink3).padding(.vertical, 8)
            } else {
                ForEach(shownDirs) { d in dirRow(d) }
            }
        }
    }

    /// Cấp 1 = top-level children (fast). Quét sâu = largest folders at any
    /// depth under the root. Switching auto-runs that mode's scan if empty.
    private var modePicker: some View {
        Picker("", selection: $store.deepMode) {
            Text("Cấp 1").tag(false)
            Text("Quét sâu").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 220)
        .onChange(of: store.deepMode) { _, _ in if shownDirs.isEmpty && !scanning { store.rescan() } }
    }

    private func dirRow(_ d: DirUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: d.url.path)).resizable().frame(width: 16, height: 16)
                Text(store.deepMode ? rel(d.url) : d.url.lastPathComponent)
                    .font(.system(size: 12, design: store.deepMode ? .monospaced : .default))
                    .foregroundColor(palette.ink).lineLimit(1).truncationMode(.middle)
                    .help(d.url.path)
                Spacer()
                Text(ByteFormat.string(d.sizeBytes)).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink2)
            }
            bar(fraction: Double(d.sizeBytes) / Double(maxDir), color: palette.gold)
        }
        .padding(.vertical, 5)
    }

    /// Path relative to the scanned root, so a deep hit reads as
    /// "Library/Caches/foo" instead of the full absolute path.
    private func rel(_ url: URL) -> String {
        let root = store.rootPath
        if url.path.hasPrefix(root + "/") { return String(url.path.dropFirst(root.count + 1)) }
        return url.lastPathComponent
    }

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.line).frame(height: 7)
                Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(min(1, fraction))), height: 7)
            }
        }
        .frame(height: 7)
    }
}
