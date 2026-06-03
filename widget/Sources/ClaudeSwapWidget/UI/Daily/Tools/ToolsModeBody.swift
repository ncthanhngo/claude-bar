import SwiftUI

/// Tools mode. Top-level tools (App · Netbird) are a HORIZONTAL menu; the active
/// tool's features live in a left sidebar (App) or take the full width (Netbird,
/// which has its own internal layout and benefits from the extra room).
///
/// All cleanup stores live here so scan results survive page switches, and both
/// tool surfaces are kept alive (opacity) so switching never re-fetches/-scans.
struct ToolsModeBody: View {
    let palette: BriefingPalette
    @State private var tool: ToolsTab = .app
    @State private var page: ToolsPage = .uninstall

    @StateObject private var apps = InstalledAppsStore()
    @StateObject private var junk = JunkScanner()
    @StateObject private var large = LargeFilesScanner()
    @StateObject private var health = SystemHealthChecker()
    @StateObject private var disk = DiskAnalyzer()
    @StateObject private var maintenance = MaintenanceRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolMenu
            Divider().overlay(palette.line)
            ZStack {
                appLayout
                    .opacity(tool == .app ? 1 : 0)
                    .allowsHitTesting(tool == .app)
                NetbirdModeBody(palette: palette)
                    .opacity(tool == .netbird ? 1 : 0)
                    .allowsHitTesting(tool == .netbird)
            }
        }
        .padding(EdgeInsets(top: 2, leading: 10, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: horizontal tool menu

    private var toolMenu: some View {
        HStack(spacing: 8) {
            ForEach(ToolsTab.allCases) { t in toolTab(t) }
            Spacer()
        }
    }

    private func toolTab(_ t: ToolsTab) -> some View {
        let active = tool == t
        return Button { tool = t } label: {
            Label(t.label, systemImage: t.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(active ? palette.ink : palette.ink3)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(active ? palette.ink.opacity(0.08) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? palette.line2 : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: App tool (sidebar + detail)

    private var appLayout: some View {
        HStack(spacing: 0) {
            ToolsSidebar(page: $page, palette: palette)
            Rectangle().fill(palette.line).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 22)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.label)
                        .font(.system(size: 21, weight: .semibold, design: .serif)).foregroundColor(palette.ink)
                    Text(page.subtitle).font(.system(size: 11.5)).foregroundColor(palette.ink3)
                }
                Spacer()
                Button { openFullDiskAccess() } label: {
                    Label("Full Disk Access", systemImage: "lock.open").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .help("Mở System Settings để bật Full Disk Access cho app — giúp đọc/dọn file của app khác mà không bị macOS chặn. (App root-owned vẫn cần nhập mật khẩu admin khi gỡ.)")
            }
            Divider().overlay(palette.line)
            appContent
        }
    }

    @ViewBuilder private var appContent: some View {
        switch page {
        case .uninstall:   AppManagementView(store: apps, palette: palette)
        case .junk:        SystemJunkView(store: junk, palette: palette)
        case .largeFiles:  LargeFilesView(store: large, palette: palette)
        case .disk:        DiskAnalyzerView(store: disk, palette: palette)
        case .health:      SystemHealthView(store: health, palette: palette)
        case .maintenance: MaintenanceView(runner: maintenance, palette: palette)
        }
    }

    private func openFullDiskAccess() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// Top-level tools shown as the horizontal menu.
enum ToolsTab: String, CaseIterable, Identifiable {
    case app
    case netbird

    var id: String { rawValue }
    var label: String { self == .app ? "App" : "Netbird" }
    var icon: String { self == .app ? "macwindow.on.rectangle" : "point.3.connected.trianglepath.dotted" }
}
