import SwiftUI

/// Confirms an uninstall: loads the app's leftover support files, lets the user
/// tick which to also remove, shows the total reclaim, and moves everything to
/// the Trash (recoverable). The .app bundle itself is always included.
struct AppUninstallSheet: View {
    @ObservedObject var store: InstalledAppsStore
    let palette: BriefingPalette
    let app: InstalledApp
    @Environment(\.dismiss) private var dismiss

    @State private var related: [RelatedFile] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var working = false

    private var total: Int64 {
        (app.sizeBytes ?? 0) + related.filter { selected.contains($0.id) }.map(\.sizeBytes).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gỡ \(app.name)").font(.system(size: 15, weight: .semibold)).foregroundColor(palette.ink)
                    Text(app.url.path).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.ink3).lineLimit(1).truncationMode(.middle)
                }
            }

            bundleRow
            relatedSection

            Text("Tất cả được chuyển vào Thùng rác — khôi phục được nếu lỡ tay.")
                .font(.system(size: 10.5)).foregroundColor(palette.ink3)

            HStack {
                Text("Giải phóng ~\(ByteFormat.string(total))")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Button("Huỷ") { dismiss() }.disabled(working)
                Button(role: .destructive) { runUninstall() } label: {
                    if working { ProgressView().controlSize(.small) }
                    else { Text("Vào Thùng rác").font(.system(size: 12, weight: .semibold)) }
                }
                .buttonStyle(.borderedProminent).tint(palette.coral).disabled(working)
            }
        }
        .padding(18)
        .frame(width: 480)
        .task {
            related = await store.relatedFiles(for: app)
            selected = Set(related.map(\.id))
            loading = false
        }
    }

    private var bundleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.fill").font(.system(size: 11)).foregroundColor(palette.moss)
            Text("App bundle").font(.system(size: 12)).foregroundColor(palette.ink)
            Spacer()
            Text(ByteFormat.string(app.sizeBytes ?? 0))
                .font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink2)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2.opacity(0.5)))
    }

    @ViewBuilder private var relatedSection: some View {
        if loading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang tìm file liên quan…").font(.system(size: 11)).foregroundColor(palette.ink3) }
        } else if related.isEmpty {
            Text("Không tìm thấy file phụ trợ nào.").font(.system(size: 11)).foregroundColor(palette.ink3)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(related) { f in
                    Toggle(isOn: Binding(
                        get: { selected.contains(f.id) },
                        set: { on in if on { selected.insert(f.id) } else { selected.remove(f.id) } }
                    )) {
                        HStack(spacing: 6) {
                            Text(f.category).font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(palette.ink3.opacity(0.15))).foregroundColor(palette.ink2)
                            Text(f.url.lastPathComponent).font(.system(size: 11)).foregroundColor(palette.ink).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(f.sizeBytes)).font(.system(size: 10.5, design: .monospaced)).foregroundColor(palette.ink3)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func runUninstall() {
        working = true
        let chosen = related.filter { selected.contains($0.id) }
        Task {
            _ = await store.uninstall(app, alsoTrash: chosen)
            working = false
            dismiss()
        }
    }
}
