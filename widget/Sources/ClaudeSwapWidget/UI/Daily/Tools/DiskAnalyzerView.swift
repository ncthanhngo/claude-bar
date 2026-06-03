import SwiftUI

/// Disk tab — mounted volumes as used/total bars, plus a folder breakdown into
/// its biggest top-level children. Read-only.
struct DiskAnalyzerView: View {
    @ObservedObject var store: DiskAnalyzer
    let palette: BriefingPalette

    private var maxDir: Int64 { store.dirs.map(\.sizeBytes).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                AIAskButton(palette: palette) {
                    if let (s, p) = aiBuild() {
                        AIChatWindowController.shared.present(palette: palette, title: "AI gợi ý dọn ổ đĩa",
                            system: s, context: p,
                            suggestions: ["Nên dọn ở đâu?", "Thư mục nào đáng xem?", "Cách giải phóng nhiều nhất?"])
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
        guard !store.volumes.isEmpty || !store.dirs.isEmpty else { return nil }
        let system = """
        Bạn là trợ lý phân tích đĩa macOS. Trả lời tiếng Việt, súc tích, gạch đầu dòng. \
        Dựa trên dung lượng ổ đĩa và các thư mục ngốn chỗ, gợi ý nên xem/dọn ở đâu để \
        giải phóng dung lượng. CHỉ dựa trên số liệu đưa ra, không bịa đường dẫn.
        """
        let vols = store.volumes.map {
            "- Ổ \($0.name): dùng \(ByteFormat.string($0.used))/\(ByteFormat.string($0.total)), trống \(ByteFormat.string($0.free))"
        }.joined(separator: "\n")
        let dirs = store.dirs.prefix(20).map {
            "- \($0.url.lastPathComponent): \(ByteFormat.string($0.sizeBytes)) (\($0.url.path))"
        }.joined(separator: "\n")
        let body = [vols.isEmpty ? nil : "Ổ đĩa:\n\(vols)",
                    dirs.isEmpty ? nil : "Thư mục ngốn chỗ:\n\(dirs)"]
            .compactMap { $0 }.joined(separator: "\n\n")
        return (system, "\(body)\n\nNên dọn ở đâu?")
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
                    .foregroundColor(palette.ink3).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                Button { store.chooseFolder() } label: { Image(systemName: "folder") }.buttonStyle(.plain).foregroundColor(palette.ink2)
                if store.isScanning { ProgressView().controlSize(.small) }
                Button { store.scanDirs() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(palette.ink2).disabled(store.isScanning)
            }
            if store.dirs.isEmpty {
                Text(store.isScanning ? "Đang quét…" : "Bấm ↻ để phân tích thư mục này.")
                    .font(.system(size: 11)).foregroundColor(palette.ink3).padding(.vertical, 8)
            } else {
                ForEach(store.dirs) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: d.url.path)).resizable().frame(width: 16, height: 16)
                            Text(d.url.lastPathComponent).font(.system(size: 12)).foregroundColor(palette.ink).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(d.sizeBytes)).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink2)
                        }
                        bar(fraction: Double(d.sizeBytes) / Double(maxDir), color: palette.gold)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
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
