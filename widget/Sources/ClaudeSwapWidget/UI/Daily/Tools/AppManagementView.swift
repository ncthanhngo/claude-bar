import SwiftUI

/// App Management tab — lists installed apps with size + last-used, and starts
/// an uninstall that also sweeps the app's leftover support files (to Trash).
struct AppManagementView: View {
    @ObservedObject var store: InstalledAppsStore
    let palette: BriefingPalette

    @State private var query = ""
    @State private var sort: Sort = .size
    @State private var uninstalling: InstalledApp?

    enum Sort: String, CaseIterable, Identifiable {
        case size, name, lastUsed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .size: return "Dung lượng"
            case .name: return "Tên"
            case .lastUsed: return "Ít dùng"
            }
        }
    }

    private var filtered: [InstalledApp] {
        let base = query.isEmpty ? store.apps
            : store.apps.filter { $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .size: return base.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed: return base.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let err = store.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(palette.coral)
            }
            list
        }
        .onAppear { if store.apps.isEmpty { store.scan() } }
        .sheet(item: $uninstalling) { app in
            AppUninstallSheet(store: store, palette: palette, app: app)
        }
        .overlay(alignment: .top) { toast }
        .task(id: store.banner) {
            guard store.banner != nil else { return }
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            withAnimation { store.banner = nil }
        }
    }

    @ViewBuilder private var toast: some View {
        if let b = store.banner {
            Text(b)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(palette.moss))
                .shadow(color: palette.ink.opacity(0.18), radius: 8, y: 3)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(palette.ink3)
            TextField("Tìm app…", text: $query)
                .textFieldStyle(.plain).frame(width: 180)
            Picker("", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Spacer()
            Text("\(filtered.count) app").font(.system(size: 11)).foregroundColor(palette.ink3)
            if store.isScanning { ProgressView().controlSize(.small) }
            Button { store.scan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundColor(palette.ink2).disabled(store.isScanning)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { app in
                    VStack(spacing: 0) {
                        AppRow(app: app, palette: palette) { uninstalling = app }
                        Divider().overlay(palette.line)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.apps)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }
}

/// One app row: icon · name + bundle id · last used · size · uninstall.
private struct AppRow: View {
    let app: InstalledApp
    let palette: BriefingPalette
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                    if app.isAppleSystem {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(palette.ink3)
                    }
                }
                Text("\(app.bundleID.isEmpty ? "—" : app.bundleID) · dùng \(usedLabel)")
                    .font(.system(size: 10.5)).foregroundColor(palette.ink3).lineLimit(1)
            }
            Spacer()
            Text(app.sizeBytes.map(ByteFormat.string) ?? "…")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(palette.ink2).frame(width: 72, alignment: .trailing)
            Button(role: .destructive, action: onUninstall) {
                Text("Gỡ").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered).tint(palette.coral)
            .disabled(app.isAppleSystem)
            .help(app.isAppleSystem ? "App hệ thống của Apple — không gỡ ở đây" : "Gỡ \(app.name) + file liên quan")
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
    }

    private var usedLabel: String {
        guard let d = app.lastUsed else { return "—" }
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        if days <= 0 { return "hôm nay" }
        if days < 30 { return "\(days) ngày trước" }
        let months = days / 30
        return months < 12 ? "\(months) tháng trước" : "\(months / 12) năm trước"
    }
}
