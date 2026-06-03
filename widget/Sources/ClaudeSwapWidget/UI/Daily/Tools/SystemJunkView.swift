import SwiftUI

/// System Junk tab — scan curated cache/log/build-artifact locations, tick which
/// to clean, move them to the Trash. Everything listed regenerates on next use.
struct SystemJunkView: View {
    @ObservedObject var store: JunkScanner
    let palette: BriefingPalette

    @State private var selected: Set<String> = []
    @State private var confirm = false

    private var selectedItems: [JunkItem] { store.items.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.map(\.sizeBytes).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let err = store.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(palette.coral)
            }
            if store.items.isEmpty && !store.isScanning {
                empty
            } else {
                list
                footer
            }
        }
        .onAppear { if store.items.isEmpty { store.scan() } }
        .confirmationDialog("Dọn \(selectedItems.count) mục (~\(ByteFormat.string(selectedBytes)))?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Vào Thùng rác", role: .destructive) {
                let items = selectedItems
                Task { _ = await store.clean(items); selected.removeAll() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Chuyển vào Thùng rác — khôi phục được. Các cache/log này sẽ tự tạo lại khi dùng app.")
        }
    }

    /// Builds the AI prompt from the current junk scan, or nil when empty.
    private func aiBuild() -> (system: String, prompt: String)? {
        guard !store.items.isEmpty else { return nil }
        let system = """
        Bạn là trợ lý dọn dẹp macOS. Trả lời tiếng Việt, súc tích, gạch đầu dòng. \
        Người dùng đưa danh sách mục rác kèm nhãn an toàn (An toàn = tự tạo lại được; \
        Cân nhắc = có thể chứa dữ liệu hoặc tốn công tạo lại). Khuyên nên xoá mục nào, \
        giữ/cẩn thận mục nào và vì sao. CHỈ nói về các mục trong danh sách, không bịa.
        """
        let lines = store.items.map {
            "- [\($0.safety.label)] \($0.label) (\(ByteFormat.string($0.sizeBytes))) — \($0.url.path)"
        }.joined(separator: "\n")
        return (system, "Danh sách rác quét được:\n\(lines)\n\nNên dọn gì, giữ gì?")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Cache · log · build artifact").font(.system(size: 12)).foregroundColor(palette.ink2)
            Spacer()
            Text("tổng \(ByteFormat.string(store.total))").font(.system(size: 11)).foregroundColor(palette.ink3)
            AIAskButton(palette: palette) {
                if let (s, p) = aiBuild() {
                    AIChatWindowController.shared.present(palette: palette, title: "AI tư vấn dọn rác",
                        system: s, context: p,
                        suggestions: ["Nên dọn gì, giữ gì?", "Mục nào rủi ro?", "Dọn an toàn tối đa được bao nhiêu?"])
                }
            }.disabled(aiBuild() == nil)
            if store.isScanning { ProgressView().controlSize(.small) }
            Button { store.scan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundColor(palette.ink2).disabled(store.isScanning)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.items) { item in
                    row(item)
                    Divider().overlay(palette.line)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func row(_ item: JunkItem) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(item.id) },
            set: { on in if on { selected.insert(item.id) } else { selected.remove(item.id) } }
        )) {
            HStack(spacing: 8) {
                SafetyBadge(safety: item.safety, palette: palette)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label).font(.system(size: 12.5, weight: .medium)).foregroundColor(palette.ink)
                    Text(item.url.path).font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(palette.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.string(item.sizeBytes))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundColor(palette.ink2)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 8).padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack {
            Button(selected.count == store.items.count ? "Bỏ chọn hết" : "Chọn hết") {
                selected = selected.count == store.items.count ? [] : Set(store.items.map(\.id))
            }
            .buttonStyle(.plain).foregroundColor(palette.ink2).font(.system(size: 12))
            Button("Chỉ mục an toàn") {
                selected = Set(store.items.filter { $0.safety == .safe }.map(\.id))
            }
            .buttonStyle(.plain).foregroundColor(palette.moss).font(.system(size: 12))
            Spacer()
            Text("Chọn \(selectedItems.count) · ~\(ByteFormat.string(selectedBytes))")
                .font(.system(size: 11)).foregroundColor(palette.ink3)
            Button { confirm = true } label: {
                Label("Dọn", systemImage: "trash").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).tint(palette.coral).disabled(selected.isEmpty)
        }
    }

    private var empty: some View {
        Text("Không tìm thấy rác đáng kể. 🎉")
            .font(.system(size: 12)).foregroundColor(palette.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
