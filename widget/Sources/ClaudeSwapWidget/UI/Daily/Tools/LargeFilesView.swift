import SwiftUI

/// Large Files tab — pick a folder, scan for files ≥ a size threshold, tick the
/// space hogs, move them to the Trash.
struct LargeFilesView: View {
    @ObservedObject var store: LargeFilesScanner
    let palette: BriefingPalette

    @State private var selected: Set<String> = []
    @State private var confirm = false

    private var selectedFiles: [LargeFile] { store.files.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedFiles.map(\.sizeBytes).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if let err = store.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(palette.coral)
            }
            if store.files.isEmpty {
                empty
            } else {
                list
                footer
            }
        }
        .confirmationDialog("Xoá \(selectedFiles.count) file (~\(ByteFormat.string(selectedBytes)))?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Vào Thùng rác", role: .destructive) {
                let files = selectedFiles
                Task { _ = await store.trash(files); selected.removeAll() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Chuyển vào Thùng rác — khôi phục được. Kiểm tra kỹ: đây là file của bạn, không phải cache.")
        }
    }

    /// Builds the AI prompt from the largest files found (capped to keep it small).
    private func aiBuild() -> (system: String, prompt: String)? {
        guard !store.files.isEmpty else { return nil }
        let system = """
        Bạn là trợ lý dọn ổ đĩa macOS. Trả lời tiếng Việt, súc tích, gạch đầu dòng. \
        Người dùng đưa danh sách file lớn kèm nhãn an toàn. Gợi ý file nào có thể xoá \
        an toàn (cache/build/installer tải lại được) và file nào nên giữ (dữ liệu cá \
        nhân: tài liệu, ảnh, video, mã nguồn). CHỈ nói về file trong danh sách, không bịa.
        """
        let lines = store.files.prefix(40).map {
            "- [\($0.safety.label)] \($0.url.lastPathComponent) (\(ByteFormat.string($0.sizeBytes))) — \($0.url.path)"
        }.joined(separator: "\n")
        return (system, "File lớn tìm được (tối đa 40 mục lớn nhất):\n\(lines)\n\nXoá được cái nào?")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { store.chooseFolder() } label: {
                Label("Thư mục", systemImage: "folder").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            Text(store.rootPath).font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(palette.ink3).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
            Stepper(value: $store.minMB, in: 10...5000, step: 50) {
                Text("≥ \(store.minMB) MB").font(.system(size: 11)).foregroundColor(palette.ink2)
            }
            Spacer()
            AIAskButton(palette: palette) {
                if let (s, p) = aiBuild() {
                    AIChatWindowController.shared.present(palette: palette, title: "AI tư vấn file lớn",
                        system: s, context: p,
                        suggestions: ["File nào xoá được an toàn?", "Cái nào là dữ liệu cá nhân?", "Nên giữ lại gì?"])
                }
            }.disabled(aiBuild() == nil)
            if store.isScanning { ProgressView().controlSize(.small) }
            Button { store.scan() } label: {
                Label("Quét", systemImage: "magnifyingglass").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).tint(palette.moss).disabled(store.isScanning)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.files) { f in
                    row(f)
                    Divider().overlay(palette.line)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func row(_ f: LargeFile) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(f.id) },
            set: { on in if on { selected.insert(f.id) } else { selected.remove(f.id) } }
        )) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path))
                    .resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(f.url.lastPathComponent).font(.system(size: 12.5, weight: .medium)).foregroundColor(palette.ink).lineLimit(1)
                        SafetyBadge(safety: f.safety, palette: palette)
                    }
                    Text(f.url.deletingLastPathComponent().path).font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(palette.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.string(f.sizeBytes))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundColor(palette.ink2)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 7).padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack {
            Text("\(store.files.count) file (lớn nhất 300)").font(.system(size: 11)).foregroundColor(palette.ink3)
            Button("Chỉ file an toàn") {
                selected = Set(store.files.filter { $0.safety == .safe }.map(\.id))
            }
            .buttonStyle(.plain).foregroundColor(palette.moss).font(.system(size: 12))
            Spacer()
            Text("Chọn \(selectedFiles.count) · ~\(ByteFormat.string(selectedBytes))")
                .font(.system(size: 11)).foregroundColor(palette.ink3)
            Button { confirm = true } label: {
                Label("Xoá", systemImage: "trash").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).tint(palette.coral).disabled(selected.isEmpty)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.viewfinder").font(.system(size: 26)).foregroundColor(palette.ink3)
            Text(store.isScanning ? "Đang quét…" : "Chọn thư mục rồi bấm Quét để tìm file lớn.")
                .font(.system(size: 12)).foregroundColor(palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
